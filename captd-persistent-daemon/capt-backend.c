/*
 * capt-backend.c - thin CUPS backend for the Canon LBP2900 CAPT printer.
 *
 * Unlike CUPS's stock "usb" backend, this backend does NOT open or close
 * the USB device itself for each job. It connects to captd, a small
 * persistent daemon that holds ONE continuous libusb session to the
 * printer open at all times, and simply relays bytes to/from it over a
 * Unix domain socket. This avoids the engine wedge ("ReserveUnit failed
 * 0x8c") that reliably reproduces after 4 successful reservations when
 * the USB device is closed and reopened between every job -- which is
 * exactly what the stock usb backend does, and exactly what a standalone
 * libusb test proved is unnecessary: a single continuous session survived
 * 24+ consecutive Reserve/Release cycles with zero wedges.
 *
 * The upstream filter (rastertocapt) is completely unmodified -- it still
 * just writes CAPT commands to stdout and reads replies via
 * cupsBackChannelRead()/cupsSideChannelDoRequest(), exactly as it always
 * has. Only the backend underneath it changes.
 *
 * Device URI: capt:/path/to/captd/socket   e.g. capt:/run/captd/lbp2900.sock
 *
 * Wire protocol with captd (see captd.c for the authoritative description):
 *   backend -> captd: frames of [u32 LE length][length bytes] (data meant
 *     for the USB OUT endpoint).
 *   captd -> backend: 'K' (ack of one OUT frame) or
 *     'D'+[u32 LE length][length bytes] (data from the USB IN endpoint).
 * CUPS_SC_CMD_DRAIN_OUTPUT must not answer OK until every frame sent so
 * far has actually been acked by captd -- otherwise the filter believes
 * its command has reached the printer before it really has, and can time
 * out waiting for a reply the printer isn't ready to send yet. This
 * exact race caused a real job failure during development/testing.
 */

#include <cups/cups.h>
#include <cups/sidechannel.h>
#include <cups/backend.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <time.h>

#define DEFAULT_SOCK_PATH "/run/captd/lbp2900.sock"

/* Fixed IEEE1284 device ID for this printer, captured verbatim from a live
 * USB trace of the genuine device (2026-07-14). This never changes for a
 * given physical printer, so hardcoding it avoids needing captd to
 * understand CAPT semantics at all -- it stays a pure byte relay. */
static const char *g_ieee1284_id =
	"MFG:Canon;MDL:LBP2900;CMD:CAPT;VER:2.1;CLS:PRINTER;DES:Canon LBP2900";

static int connect_captd(const char *path)
{
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
	if (connect(s, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		close(s);
		return -1;
	}
	return s;
}

static int recv_exact(int sock, void *buf, size_t want)
{
	size_t got = 0;
	while (got < want) {
		ssize_t n = recv(sock, (unsigned char *) buf + got, want - got, 0);
		if (n <= 0)
			return -1;
		got += (size_t) n;
	}
	return 0;
}

static int send_all(int sock, const void *buf, size_t n)
{
	size_t off = 0;
	while (off < n) {
		ssize_t sent = send(sock, (const unsigned char *) buf + off, n - off, MSG_NOSIGNAL);
		if (sent <= 0)
			return -1;
		off += (size_t) sent;
	}
	return 0;
}

/* Sends one [len][payload] frame to captd (data destined for USB OUT). */
static int send_frame(int sock, const void *buf, size_t n)
{
	uint32_t len = (uint32_t) n;
	if (send_all(sock, &len, 4) != 0)
		return -1;
	return send_all(sock, buf, n);
}

/* Reads exactly one tagged message from captd. On 'K', increments
 * *acked_frames. On 'D', relays the payload via cupsBackChannelWrite.
 * Returns 0 on success, -1 on disconnect/error. */
static int process_one_daemon_message(int sock, unsigned long *acked_frames)
{
	uint8_t tag;
	if (recv_exact(sock, &tag, 1) != 0)
		return -1;
	if (tag == 'K') {
		(*acked_frames)++;
		return 0;
	}
	if (tag == 'D') {
		uint32_t len;
		if (recv_exact(sock, &len, 4) != 0)
			return -1;
		if (len > 0) {
			char *payload = malloc(len);
			if (!payload)
				return -1;
			if (recv_exact(sock, payload, len) != 0) {
				free(payload);
				return -1;
			}
			cupsBackChannelWrite(payload, len, 1.0);
			free(payload);
		}
		return 0;
	}
	fprintf(stderr, "ERROR: capt-backend: unknown tag 0x%02x from captd\n", tag);
	return -1;
}

int main(int argc, char *argv[])
{
	if (argc == 1) {
		/* CUPS calls with no arguments to enumerate discoverable devices. */
		puts("direct capt:" DEFAULT_SOCK_PATH " \"Canon LBP2900\" \"Canon LBP2900 (persistent CAPT link)\"");
		return 0;
	}

	if (argc < 6 || argc > 7) {
		fprintf(stderr, "ERROR: Usage: %s job-id user title copies options [file]\n", argv[0]);
		return CUPS_BACKEND_FAILED;
	}

	const char *device_uri = getenv("DEVICE_URI");
	const char *sock_path = DEFAULT_SOCK_PATH;
	if (device_uri) {
		const char *p = strchr(device_uri, ':');
		if (p && p[1])
			sock_path = p + 1;
	}

	int print_fd = 0;
	if (argc == 7) {
		print_fd = open(argv[6], O_RDONLY);
		if (print_fd < 0) {
			fprintf(stderr, "ERROR: unable to open \"%s\": %s\n", argv[6], strerror(errno));
			return CUPS_BACKEND_FAILED;
		}
	}

	signal(SIGPIPE, SIG_IGN);

	fprintf(stderr, "DEBUG: capt-backend: connecting to captd at %s\n", sock_path);
	int dsock = -1;
	for (int i = 0; i < 15 && dsock < 0; i++) {
		dsock = connect_captd(sock_path);
		if (dsock < 0) {
			fprintf(stderr, "DEBUG: capt-backend: captd not ready (%s), retrying...\n", strerror(errno));
			sleep(1);
		}
	}
	if (dsock < 0) {
		fprintf(stderr, "ERROR: capt-backend: cannot connect to captd at %s: %s\n", sock_path, strerror(errno));
		return CUPS_BACKEND_FAILED;
	}
	fprintf(stderr, "DEBUG: capt-backend: connected to captd (persistent USB session)\n");

	struct stat sc_stat;
	int have_sidechannel = (fstat(CUPS_SC_FD, &sc_stat) == 0);

	int print_eof = 0;
	int result = CUPS_BACKEND_OK;
	unsigned long frames_sent = 0;
	unsigned long frames_acked = 0;

	for (;;) {
		fd_set rfds;
		FD_ZERO(&rfds);
		int maxfd = 0;

		if (!print_eof) {
			FD_SET(print_fd, &rfds);
			if (print_fd > maxfd)
				maxfd = print_fd;
		}
		FD_SET(dsock, &rfds);
		if (dsock > maxfd)
			maxfd = dsock;
		if (have_sidechannel) {
			FD_SET(CUPS_SC_FD, &rfds);
			if (CUPS_SC_FD > maxfd)
				maxfd = CUPS_SC_FD;
		}

		struct timeval tv;
		tv.tv_sec = 1;
		tv.tv_usec = 0;
		int r = select(maxfd + 1, &rfds, NULL, NULL, &tv);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			fprintf(stderr, "ERROR: select() failed: %s\n", strerror(errno));
			result = CUPS_BACKEND_FAILED;
			break;
		}

		if (have_sidechannel && FD_ISSET(CUPS_SC_FD, &rfds)) {
			cups_sc_command_t command;
			cups_sc_status_t status;
			char data[2048];
			int datalen = sizeof(data);
			if (cupsSideChannelRead(&command, &status, data, &datalen, 1.0) == 0) {
				switch (command) {
				case CUPS_SC_CMD_DRAIN_OUTPUT: {
					/* Do not answer OK until captd has acked every
					 * frame we've sent so far -- i.e. until we know
					 * for certain the bytes have actually reached the
					 * USB OUT endpoint, not just captd's socket queue. */
					cups_sc_status_t drain_status = CUPS_SC_STATUS_OK;
					time_t deadline = time(NULL) + 20;
					while (frames_acked < frames_sent) {
						fd_set drfds;
						FD_ZERO(&drfds);
						FD_SET(dsock, &drfds);
						struct timeval dtv;
						dtv.tv_sec = 1;
						dtv.tv_usec = 0;
						int dr = select(dsock + 1, &drfds, NULL, NULL, &dtv);
						if (dr > 0 && FD_ISSET(dsock, &drfds)) {
							if (process_one_daemon_message(dsock, &frames_acked) != 0) {
								fprintf(stderr, "ERROR: capt-backend: captd connection lost while draining\n");
								drain_status = CUPS_SC_STATUS_IO_ERROR;
								break;
							}
						}
						if (time(NULL) > deadline) {
							fprintf(stderr, "ERROR: capt-backend: timed out waiting for captd to drain output\n");
							drain_status = CUPS_SC_STATUS_IO_ERROR;
							break;
						}
					}
					cupsSideChannelWrite(command, drain_status, NULL, 0, 1.0);
					if (drain_status != CUPS_SC_STATUS_OK) {
						result = CUPS_BACKEND_FAILED;
						goto done;
					}
					break;
				}
				case CUPS_SC_CMD_GET_DEVICE_ID:
					cupsSideChannelWrite(command, CUPS_SC_STATUS_OK,
						g_ieee1284_id, (int) strlen(g_ieee1284_id), 1.0);
					break;
				default:
					cupsSideChannelWrite(command, CUPS_SC_STATUS_NOT_IMPLEMENTED, NULL, 0, 1.0);
					break;
				}
			}
		}

		if (!print_eof && FD_ISSET(print_fd, &rfds)) {
			char buf[16384];
			ssize_t n = read(print_fd, buf, sizeof(buf));
			if (n < 0) {
				if (errno != EINTR) {
					fprintf(stderr, "ERROR: read from print data failed: %s\n", strerror(errno));
					result = CUPS_BACKEND_FAILED;
					break;
				}
			} else if (n == 0) {
				print_eof = 1;
				fprintf(stderr, "DEBUG: capt-backend: print data EOF, job's commands fully sent\n");
			} else {
				if (send_frame(dsock, buf, (size_t) n) != 0) {
					fprintf(stderr, "ERROR: send to captd failed: %s\n", strerror(errno));
					result = CUPS_BACKEND_FAILED;
					goto done;
				}
				frames_sent++;
			}
		}

		if (FD_ISSET(dsock, &rfds)) {
			if (process_one_daemon_message(dsock, &frames_acked) != 0) {
				fprintf(stderr, "DEBUG: capt-backend: captd closed the connection\n");
				break;
			}
		}

		/* print_fd EOF only happens once rastertocapt has exited, and it
		 * only exits after every command it sent has already received its
		 * reply via cupsBackChannelRead -- so once we reach EOF there is
		 * nothing further to relay in either direction. */
		if (print_eof)
			break;
	}

done:
	if (print_fd > 0)
		close(print_fd);
	close(dsock);
	return result;
}
