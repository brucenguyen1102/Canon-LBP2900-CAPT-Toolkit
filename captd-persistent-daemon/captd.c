/*
 * captd.c - persistent USB session holder for the Canon LBP2900 CAPT printer.
 *
 * Empirically established (2026-07-14): a standalone test holding ONE
 * continuous libusb session open across 24+ bare Reserve/Release cycles
 * (no real print data) never wedged. But that turned out to be an
 * incomplete picture: this daemon, holding that exact same kind of
 * continuous session open across REAL CUPS print jobs, still wedged
 * ("ReserveUnit failed 0x8c") at exactly the 5th real job -- identical to
 * every previous test using the old fresh-open-per-job architecture.
 * USB autosuspend was checked and ruled out (power/control=on, not
 * auto). So connection persistence alone is NOT sufficient for real
 * print jobs -- something about the real print sequence itself (data
 * transfer, StartPrint, paper handling) matters, not just whether the
 * USB handle stays open. The next hypothesis being tested: idle-time
 * status polling (GetExtendedStatus/GetInputStatus every ~200ms, which
 * is what the genuine Windows driver does during every gap between
 * jobs) combined with the persistent connection -- see do_idle_poll_once()
 * below, run from the main accept loop whenever no client is connected.
 *
 * This daemon opens the printer via libusb ONCE at startup and keeps the
 * interface claimed indefinitely. It listens on a Unix domain socket;
 * each connecting client (one per CUPS job, via the capt-backend CUPS
 * backend) gets its bytes relayed to/from the USB bulk endpoints. captd
 * does not parse or understand the CAPT protocol itself -- it only knows
 * a tiny generic framing/ack envelope (below), not CAPT command semantics.
 * Only one client is expected at a time (CUPS serializes jobs per
 * destination); a second concurrent connection attempt is rejected rather
 * than silently corrupting an in-flight job.
 *
 * Wire protocol (bidirectional over one Unix SOCK_STREAM connection):
 *   client -> daemon: repeated frames of [u32 LE length][length bytes].
 *     Each frame is bulk-transferred to the USB OUT endpoint in full,
 *     then acknowledged (see below) -- this lets the client know for
 *     certain that everything it has sent so far has actually reached
 *     the device, which is exactly what CUPS's CUPS_SC_CMD_DRAIN_OUTPUT
 *     side-channel request needs to answer correctly. Getting this wrong
 *     (acking before the USB transfer actually completes) was the root
 *     cause of a real failure during testing: the filter believed its
 *     output was flushed and started waiting for a reply that the
 *     printer wasn't ready to send yet, and timed out.
 *   daemon -> client: tagged messages:
 *     'K' (1 byte total): acknowledges one fully-completed OUT frame.
 *     'D' + [u32 LE length] + [length bytes]: data relayed from the USB
 *       IN endpoint (arrives asynchronously, independent of OUT frames).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/resource.h>
#include <libusb-1.0/libusb.h>

#define VENDOR_ID  0x04a9
#define PRODUCT_ID 0x2676
#define DEFAULT_SOCK_PATH "/run/captd/lbp2900.sock"

#define CAPT_GET_INPUT_STATUS    0xA0A1
#define CAPT_GET_EXTENDED_STATUS 0xA0A8

static libusb_device_handle *devh;
static unsigned char ep_out = 0, ep_in = 0;
static volatile sig_atomic_t g_running = 1;
static pthread_mutex_t g_client_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_client_active = 0;

static void handle_signal(int sig)
{
	(void) sig;
	g_running = 0;
}

static int find_endpoints(libusb_device *dev)
{
	struct libusb_config_descriptor *cfg;
	int r = libusb_get_active_config_descriptor(dev, &cfg);
	if (r != 0)
		return r;
	for (int i = 0; i < cfg->bNumInterfaces; i++) {
		const struct libusb_interface *intf = &cfg->interface[i];
		for (int j = 0; j < intf->num_altsetting; j++) {
			const struct libusb_interface_descriptor *id = &intf->altsetting[j];
			for (int k = 0; k < id->bNumEndpoints; k++) {
				const struct libusb_endpoint_descriptor *ep = &id->endpoint[k];
				if ((ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK)
					continue;
				if ((ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_OUT)
					ep_out = ep->bEndpointAddress;
				else
					ep_in = ep->bEndpointAddress;
			}
		}
	}
	libusb_free_config_descriptor(cfg);
	return 0;
}

/* Sends one GetExtendedStatus + GetInputStatus pair -- mirrors the
 * genuine Windows CAPT driver's observed idle-time behavior (a poll pair
 * roughly every ~200ms during every gap between jobs, confirmed to span
 * gaps from ~4s up to ~99s in live USB captures). Only called from the
 * main loop while no client is connected, so it never races with a job's
 * relay threads. */
static void do_idle_poll_once(void)
{
	uint16_t cmds[2] = { CAPT_GET_EXTENDED_STATUS, CAPT_GET_INPUT_STATUS };
	for (int i = 0; i < 2; i++) {
		uint8_t cmd_buf[4];
		uint8_t reply_buf[256];
		int actual = 0;

		cmd_buf[0] = (uint8_t) (cmds[i] & 0xFF);
		cmd_buf[1] = (uint8_t) ((cmds[i] >> 8) & 0xFF);
		cmd_buf[2] = 4;
		cmd_buf[3] = 0;
		int r = libusb_bulk_transfer(devh, ep_out, cmd_buf, 4, &actual, 2000);
		if (r != 0) {
			fprintf(stderr, "captd: idle-poll OUT error: %s\n", libusb_error_name(r));
			return;
		}
		r = libusb_bulk_transfer(devh, ep_in, reply_buf, sizeof(reply_buf), &actual, 2000);
		if (r != 0) {
			fprintf(stderr, "captd: idle-poll IN error: %s\n", libusb_error_name(r));
			return;
		}
		usleep(100000);
	}
}

/* Flush any bytes the printer has queued but nobody has read yet, e.g.
 * left over from a previous captd instance that was killed mid-exchange.
 * Loops until a read genuinely times out. */
static void drain_stale(void)
{
	int rounds = 0;
	for (;;) {
		uint8_t junk[256];
		int actual = 0;
		int r = libusb_bulk_transfer(devh, ep_in, junk, sizeof(junk), &actual, 300);
		if (r == LIBUSB_ERROR_TIMEOUT || actual == 0)
			break;
		if (r != 0)
			break;
		rounds++;
		fprintf(stderr, "captd: drained %d stale byte(s) (round %d)\n", actual, rounds);
		if (rounds > 50)
			break;
	}
}

struct relay_ctx {
	int sock;
	volatile int stop;
	pthread_mutex_t write_lock;
};

/* Loops recv() until exactly `want` bytes are collected, or the
 * connection closes/errors. Returns 0 on success, -1 on failure. */
static int recv_exact(int sock, void *buf, size_t want)
{
	size_t got = 0;
	while (got < want) {
		ssize_t n = recv(sock, (uint8_t *) buf + got, want - got, 0);
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
		ssize_t sent = send(sock, (const uint8_t *) buf + off, n - off, MSG_NOSIGNAL);
		if (sent <= 0)
			return -1;
		off += (size_t) sent;
	}
	return 0;
}

static void *out_relay_thread(void *arg)
{
	struct relay_ctx *ctx = arg;
	uint8_t buf[65536];
	while (!ctx->stop) {
		uint32_t len_le;
		if (recv_exact(ctx->sock, &len_le, 4) != 0) {
			ctx->stop = 1;
			break;
		}
		uint32_t len = len_le; /* host is little-endian (x86_64) */
		if (len == 0 || len > sizeof(buf)) {
			fprintf(stderr, "captd: ERROR: bogus frame length %u\n", (unsigned) len);
			ctx->stop = 1;
			break;
		}
		if (recv_exact(ctx->sock, buf, len) != 0) {
			ctx->stop = 1;
			break;
		}

		size_t off = 0;
		int failed = 0;
		while (off < len) {
			int chunk = (int) ((len - off > 16384) ? 16384 : (len - off));
			int actual = 0;
			int r = libusb_bulk_transfer(devh, ep_out, buf + off, chunk, &actual, 5000);
			if (r != 0) {
				fprintf(stderr, "captd: USB OUT error: %s\n", libusb_error_name(r));
				failed = 1;
				break;
			}
			off += (size_t) actual;
		}
		if (failed) {
			ctx->stop = 1;
			break;
		}

		uint8_t ack = 'K';
		pthread_mutex_lock(&ctx->write_lock);
		int wr = send_all(ctx->sock, &ack, 1);
		pthread_mutex_unlock(&ctx->write_lock);
		if (wr != 0) {
			ctx->stop = 1;
			break;
		}
	}
	return NULL;
}

static void *in_relay_thread(void *arg)
{
	struct relay_ctx *ctx = arg;
	uint8_t buf[16384];
	while (!ctx->stop) {
		int actual = 0;
		/* Short timeout so we periodically re-check ctx->stop even
		 * when the printer has nothing to say. Kept tight (not 500ms)
		 * because when a client disconnects, handle_client() blocks in
		 * pthread_join() on this thread until its CURRENT bulk_transfer
		 * call returns -- a long timeout here directly delays how fast
		 * the main loop's idle status-polling resumes after a job ends,
		 * which was empirically observed (2026-07-14) to open an ~0.8s
		 * silent gap right before a wedge on real hardware. */
		int r = libusb_bulk_transfer(devh, ep_in, buf, sizeof(buf), &actual, 50);
		if (r == LIBUSB_ERROR_TIMEOUT)
			continue;
		if (r != 0) {
			fprintf(stderr, "captd: USB IN error: %s\n", libusb_error_name(r));
			ctx->stop = 1;
			break;
		}
		if (actual > 0) {
			uint8_t hdr[5];
			hdr[0] = 'D';
			uint32_t len = (uint32_t) actual;
			memcpy(hdr + 1, &len, 4);
			pthread_mutex_lock(&ctx->write_lock);
			int wr = send_all(ctx->sock, hdr, 5);
			if (wr == 0)
				wr = send_all(ctx->sock, buf, (size_t) actual);
			pthread_mutex_unlock(&ctx->write_lock);
			if (wr != 0) {
				ctx->stop = 1;
				break;
			}
		}
	}
	return NULL;
}

static void handle_client(int csock)
{
	pthread_mutex_lock(&g_client_lock);
	if (g_client_active) {
		pthread_mutex_unlock(&g_client_lock);
		fprintf(stderr, "captd: rejecting second concurrent client\n");
		close(csock);
		return;
	}
	g_client_active = 1;
	pthread_mutex_unlock(&g_client_lock);

	fprintf(stderr, "captd: client connected -- USB session already open, relaying\n");
	drain_stale();

	struct relay_ctx ctx;
	ctx.sock = csock;
	ctx.stop = 0;
	pthread_mutex_init(&ctx.write_lock, NULL);
	pthread_t t_out, t_in;
	pthread_create(&t_out, NULL, out_relay_thread, &ctx);
	pthread_create(&t_in, NULL, in_relay_thread, &ctx);
	pthread_join(t_out, NULL);
	ctx.stop = 1;
	pthread_join(t_in, NULL);
	pthread_mutex_destroy(&ctx.write_lock);
	close(csock);

	pthread_mutex_lock(&g_client_lock);
	g_client_active = 0;
	pthread_mutex_unlock(&g_client_lock);
	fprintf(stderr, "captd: client disconnected -- USB session stays open for next job\n");
}

int main(int argc, char **argv)
{
	const char *sock_path = argc > 1 ? argv[1] : DEFAULT_SOCK_PATH;

	{
		struct sigaction sa;
		memset(&sa, 0, sizeof(sa));
		sa.sa_handler = handle_signal;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0; /* no SA_RESTART: let accept() return EINTR so we can check g_running */
		sigaction(SIGTERM, &sa, NULL);
		sigaction(SIGINT, &sa, NULL);
	}
	signal(SIGPIPE, SIG_IGN);

	/* Boost scheduling priority: this daemon's idle-time status polling
	 * must keep a tight, uninterrupted cadence even while the system is
	 * busy rendering the NEXT job (ghostscript etc. can be CPU-heavy).
	 * Getting descheduled during the gap between two jobs was observed
	 * (2026-07-14) to open silent multi-hundred-ms polling gaps right
	 * before a wedge. Runs as root, so this should succeed. */
	if (setpriority(PRIO_PROCESS, 0, -10) != 0)
		fprintf(stderr, "captd: WARNING: could not raise scheduling priority: %s\n", strerror(errno));

	libusb_context *usb_ctx;
	libusb_init(&usb_ctx);

	devh = libusb_open_device_with_vid_pid(usb_ctx, VENDOR_ID, PRODUCT_ID);
	if (!devh) {
		fprintf(stderr, "captd: ERROR: printer %04x:%04x not found\n", VENDOR_ID, PRODUCT_ID);
		return 1;
	}
	libusb_device *dev = libusb_get_device(devh);
	find_endpoints(dev);
	if (!ep_out || !ep_in) {
		fprintf(stderr, "captd: ERROR: could not find bulk endpoints\n");
		return 1;
	}
	if (libusb_kernel_driver_active(devh, 0) == 1)
		libusb_detach_kernel_driver(devh, 0);
	if (libusb_claim_interface(devh, 0) != 0) {
		fprintf(stderr, "captd: ERROR: claim_interface failed\n");
		return 1;
	}
	fprintf(stderr, "captd: USB device opened and claimed ONCE (pid %d). OUT=0x%02x IN=0x%02x\n",
		(int) getpid(), ep_out, ep_in);
	drain_stale();

	/* Best-effort: create parent dir of the socket if it doesn't exist. */
	{
		char dirpath[256];
		strncpy(dirpath, sock_path, sizeof(dirpath) - 1);
		dirpath[sizeof(dirpath) - 1] = '\0';
		char *slash = strrchr(dirpath, '/');
		if (slash && slash != dirpath) {
			*slash = '\0';
			mkdir(dirpath, 0755);
		}
	}

	unlink(sock_path);
	int lsock = socket(AF_UNIX, SOCK_STREAM, 0);
	if (lsock < 0) {
		fprintf(stderr, "captd: ERROR: socket() failed: %s\n", strerror(errno));
		return 1;
	}
	struct sockaddr_un addr;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = AF_UNIX;
	strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
	if (bind(lsock, (struct sockaddr *) &addr, sizeof(addr)) != 0) {
		fprintf(stderr, "captd: ERROR: bind(%s) failed: %s\n", sock_path, strerror(errno));
		return 1;
	}
	chmod(sock_path, 0666);
	if (listen(lsock, 4) != 0) {
		fprintf(stderr, "captd: ERROR: listen() failed: %s\n", strerror(errno));
		return 1;
	}
	fprintf(stderr, "captd: listening on %s\n", sock_path);

	fprintf(stderr, "captd: idle-time active status polling DISABLED (found to cause occasional USB reply desync); connection persistence only\n");
	struct timespec last_activity;
	clock_gettime(CLOCK_MONOTONIC, &last_activity);
	while (g_running) {
		fd_set rfds;
		FD_ZERO(&rfds);
		FD_SET(lsock, &rfds);
		struct timeval tv;
		tv.tv_sec = 0;
		tv.tv_usec = 100000; /* 100ms: matches Windows' observed poll cadence */
		int r = select(lsock + 1, &rfds, NULL, NULL, &tv);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (r == 0) {
			/* Timed out: no job waiting to connect right now.
			 *
			 * Active idle-time polling (do_idle_poll_once()) is
			 * DISABLED here as of 2026-07-14: it was found to
			 * occasionally leave a stray reply fragment on the USB IN
			 * endpoint that got misattributed to the next job's first
			 * status read (a "bad reply from printer" desync), and
			 * separately, polling+heartbeat combined had ALREADY been
			 * proven on real hardware not to prevent the reservation
			 * wedge by itself. The connection is still held open
			 * continuously (never closed) -- only the ACTIVE polling
			 * traffic during idle gaps is removed. (void)last_activity
			 * kept for future gap-timing diagnostics if reintroduced. */
			(void) last_activity;
			continue;
		}
		if (!FD_ISSET(lsock, &rfds))
			continue;
		int csock = accept(lsock, NULL, NULL);
		if (csock < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		handle_client(csock);
		clock_gettime(CLOCK_MONOTONIC, &last_activity);
	}

	fprintf(stderr, "captd: shutting down\n");
	close(lsock);
	unlink(sock_path);
	libusb_release_interface(devh, 0);
	libusb_close(devh);
	libusb_exit(usb_ctx);
	return 0;
}
