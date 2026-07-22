/*
 * Copyright (C) 2013 Alexey Galakhov <agalakhov@gmail.com>
 *
 * Licensed under the GNU General Public License Version 3
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#include "capt-status.h"

#include "std.h"
#include "word.h"
#include "capt-command.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static struct capt_status_s status;

static inline char bit(enum capt_flags flag)
{
	return FLAG(&status, flag) ? '1' : '0';
}

static inline char bitof(const struct capt_status_s *s, enum capt_flags flag)
{
	return FLAG(s, flag) ? '1' : '0';
}

#ifdef DEBUG
static void print_status(void)
{
	fprintf(stderr, "DEBUG: CAPT: printer status P1=%c P2=%c B=%c B0=%c B1=%c nE=%c\n",
		bit(CAPT_FL_NOTREADY), bit(CAPT_FL_NOPAPER2),
		bit(CAPT_FL_BUTTON_ON),
		bit(CAPT_FL_BUTTON), bit(CAPT_FL_BUTTON1),
		bit(CAPT_FL_nERROR)
	);
	fprintf(stderr, "DEBUG: CAPT: pages %u/%u/%u/%u\n",
		status.page_decoding,
		status.page_printing,
		status.page_out,
		status.page_completed
	);
}
#endif

static void decode_status(const uint8_t *s, size_t size)
{
	status.status[0] = WORD(s[0], s[1]);

	if (size <= 2)
		return;

	/* BufLevel low byte is at payload byte 5 (0-indexed: s[4]), byte 6 = s[5].
	 * Parse it whenever we have at least 6 payload bytes (total size > 8). */
	if (size > 8)
		status.buf_level = s[4];  /* CAPT_BSTAT_BUF_LO / CAPT_XSTAT_BUF_LO */

	status.status[1] = WORD(s[8], s[9]);

	if (size <= 10)
		return;

	status.aux            = s[CAPT_XSTAT_AUX];    /* byte 9:  Aux auxiliary engine status */
	status.xstat_cnt      = s[CAPT_XSTAT_CNT];    /* byte 10: Cnt engine flags */
	status.xstat_pap      = s[CAPT_XSTAT_PAP];    /* byte 11: Pap paper availability */
	status.xstat_eng      = WORD(s[CAPT_XSTAT_ENG_LO], s[CAPT_XSTAT_ENG_HI]); /* bytes 13-14: Eng engine error flags */

	status.status[2] = WORD(s[10], s[11]);
	status.status[3] = WORD(s[12], s[13]);

	status.page_decoding  = WORD(s[14], s[15]);
	status.page_printing  = WORD(s[16], s[17]);
	status.page_out       = WORD(s[18], s[19]);
	status.page_completed = WORD(s[20], s[21]);
	status.page_received  = WORD(s[34], s[35]);

	status.status[4] = WORD(s[24], s[25]);

	status.status[5] = WORD(s[30], s[31]);

	status.status[6] = WORD(s[38], s[39]);
}

static void download_status(uint16_t cmd)
{
	uint8_t buf[0x10000];
	size_t size = sizeof(buf);
	capt_sendrecv(cmd, NULL, 0, buf, &size);
	decode_status(buf, size);
}

void capt_init_status(void)
{
	memset(&status, 0, sizeof(status));
}

const struct capt_status_s *capt_get_status(void)
{
	download_status(CAPT_GET_BASIC_STATUS);
	return &status;
}

const struct capt_status_s *capt_get_xstatus_only(void)
{
	download_status(CAPT_GET_EXTENDED_STATUS);
#ifdef DEBUG
	print_status();
#endif
	if (FLAG(&status, CAPT_FL_NEED_INPUT_STATUS)) {
		capt_sendrecv(CAPT_GET_INPUT_STATUS, NULL, 0, NULL, 0);
	}

	return &status;
}

const struct capt_status_s *capt_get_xstatus(void)
{
	/* Fix 8: GetBasicStatus first, then check byte-2 flags (protocol §2.4):
	 *   CAPT_FL2_XSTATUS_CHANGED (0x01) → call GetExtendedStatus
	 *   CAPT_FL2_NEED_INPUT_STATUS (0x02) → call GetInputStatus */
	download_status(CAPT_GET_BASIC_STATUS);
	if (FLAG(&status, CAPT_FL_XSTATUS_CHANGED))
		capt_get_xstatus_only();
	if (FLAG(&status, CAPT_FL_NEED_INPUT_STATUS))
		capt_sendrecv(CAPT_GET_INPUT_STATUS, NULL, 0, NULL, 0);
	return &status;
}

/*
 * Rich, single-line status dump for forensic correlation of engine wedges:
 * decodes BufLevel and the Aux/Cnt/Pap/Eng engine bytes plus the key
 * CAPT_FL_* bits from a GetBasicStatus/GetExtendedStatus reply.  Used at
 * ReserveUnit failure/recovery points and at the bounded-wait timeouts below
 * so a future incident leaves more than a single collapsed status byte in
 * the log.
 */
void capt_log_status(const char *tag, const struct capt_status_s *s)
{
	fprintf(stderr,
		"%s: status=0x%04x [ERR=%c OFFLINE=%c BUSY=%c IMBUSY=%c NOTRDY=%c FREE=%c UFREE=%c] "
		"buf=%u aux=0x%02x cnt=0x%02x pap=0x%02x eng=0x%04x\n",
		tag, s->status[0],
		bitof(s, CAPT_FL_ERROR), bitof(s, CAPT_FL_OFFLINE), bitof(s, CAPT_FL_CMD_BUSY),
		bitof(s, CAPT_FL_IM_DATA_BUSY), bitof(s, CAPT_FL_NOTREADY), bitof(s, CAPT_FL_PRINTER_FREE),
		bitof(s, CAPT_FL_UNIT_FREE),
		CAPT_BUFLEVEL_SLOTS(s->buf_level), s->aux, s->xstat_cnt, s->xstat_pap, s->xstat_eng);
}

/*
 * Shared bounded wait for CMD_BUSY to clear, used by capt_wait_ready(),
 * capt_wait_xready() and capt_wait_xready_only().  These used to loop
 * forever on CMD_BUSY alone and never looked at CAPT_FL_ERROR: a wedge
 * where CMD_BUSY never clears would hang the backend process indefinitely
 * with zero visibility, and one that clears while ERROR is also set would
 * go unnoticed.  Logs once (edge-triggered) if ERROR appears mid-wait, and
 * bounds the loop so a genuine wedge is reported instead of hanging.
 */
static void capt_wait_busy_clear(const struct capt_status_s *(*getter)(void), const char *name)
{
	unsigned waited_ms = 0;
	bool err_logged = false;
	const struct capt_status_s *s;

	while (1) {
		s = getter();
		if (!FLAG(s, CAPT_FL_CMD_BUSY))
			return;
		if (FLAG(s, CAPT_FL_ERROR) && !err_logged) {
			capt_log_status(name, s);
			err_logged = true;
		}
		if (waited_ms >= CAPT_WAIT_READY_TIMEOUT_MS) {
			fprintf(stderr, "ERROR: CAPT: %s: timed out after %ums, CMD_BUSY still set\n",
				name, (unsigned) CAPT_WAIT_READY_TIMEOUT_MS);
			capt_log_status(name, s);
			return;
		}
		usleep(100000);
		waited_ms += 100;
	}
}

void capt_wait_ready(void)
{
	/* Fix 7: Poll GetBasicStatus; wait until CMD_BUSY (0x04) clears.
	 * CAPT_FL_CMD_BUSY = _FL(0,2) = 0x04 = CMD_BUSY per protocol §2.4.
	 * Before Phase 1 this was CAPT_FL_BUSY which mapped to ERROR_BIT (0x80)
	 * and was therefore waiting for errors to clear, not command completion. */
	capt_wait_busy_clear(capt_get_status, "capt_wait_ready");
}

void capt_wait_xready(void)
{
	capt_wait_busy_clear(capt_get_xstatus, "capt_wait_xready");
}

void capt_wait_xready_only(void)
{
	capt_wait_busy_clear(capt_get_xstatus_only, "capt_wait_xready_only");
}

/*
 * Wait for TRUE engine idle: CMD_BUSY, IM_DATA_BUSY and ERROR all clear, and
 * RCF_PAPER_DELIVERY (Aux byte 9 bit 0x04, last sheet still physically
 * feeding) also clear.  Used at job end (see lbp2900_job_epilogue()) instead
 * of polling RCF_PAPER_DELIVERY alone, so the next job's ReserveUnit does
 * not race into an engine that is still internally draining or already in
 * an error state.  Mirrors the interleaved GetInputStatus + GetExtendedStatus
 * polling the epilogue always used.  Bounded: returns false without aborting
 * if the engine never reaches idle within timeout_ms, so the caller can log
 * and decide -- a real wedge here cannot be fixed by waiting longer.
 */
bool capt_wait_engine_idle(unsigned timeout_ms)
{
	unsigned waited_ms = 0;
	const struct capt_status_s *s;

	while (1) {
		capt_sendrecv(CAPT_GET_INPUT_STATUS, NULL, 0, NULL, 0);
		s = capt_get_xstatus_only();

		if (!FLAG(s, CAPT_FL_CMD_BUSY)
				&& !FLAG(s, CAPT_FL_IM_DATA_BUSY)
				&& !FLAG(s, CAPT_FL_ERROR)
				&& !(s->aux & CAPT_AUX_PAPER_DELIVERY))
			return true;

		if (waited_ms >= timeout_ms)
			return false;

		usleep(100000);
		waited_ms += 100;
	}
}
