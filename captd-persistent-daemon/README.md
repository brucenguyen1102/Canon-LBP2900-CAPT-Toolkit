# captd — persistent-connection fix for the "ReserveUnit failed 0x8c" engine wedge

The open-source `captdriver` (ValdikSS fork) reliably wedges the Canon LBP2900's
print engine — `CAPT: ReserveUnit failed (0x8c) after error recovery — aborting`
— on exactly the 5th print job since power-on, requiring a physical power cycle
to clear. This happens because `rastertocapt` is a CUPS *filter*, not a
backend, so CUPS's stock `usb://` backend opens and closes the USB connection
fresh for every single job. Genuine Canon drivers (Windows and Canon's own
official, closed-source Linux driver) never hit this, because their
architecture keeps one persistent USB session open across all jobs.

Root-caused 2026-07-14 by installing Canon's own official (old, 2017,
closed-source) Linux driver, capturing its real USB traffic via Linux
`usbmon`, and diffing it byte-for-byte against our own driver's traffic for
the same test file. Full write-up of the investigation and fix is in the
project's `README.md`.

## What's here

- `captd.c` — a small daemon that opens the printer via libusb **once** and
  keeps the connection open indefinitely, instead of the per-job open/close
  that CUPS's stock backend does. Listens on a Unix socket and relays raw
  bytes to/from the USB bulk endpoints for whichever job is currently
  connected — it does not parse the CAPT protocol itself.
- `capt-backend.c` — a thin CUPS backend (`capt:/path/to/socket` device URI)
  that replaces the stock `usb://` backend: instead of opening the USB device
  itself, it connects to `captd` over the Unix socket for each job.
- `capt-status.c`, `capt-status.h`, `generic-ops.c` — the engine-hardening
  changes (bounded status-wait loops instead of loops that can hang forever,
  more detailed diagnostic logging); the same content as
  `captdriver-engine-hardening.patch`, regenerated against current upstream.
  These live here rather than pre-applied inside
  `captdriver-valdikss-val.tar.gz` because a GitHub Action refreshes that
  tarball from upstream daily and silently overwrote the hardening (noticed
  2026-07-22). Keeping every local change in this directory makes the build
  independent of whatever state the bundled tarball happens to be in.
- `prn_lbp2900.c`, `printer.h`, `capt-command.h`, `capt-command.c` — the
  patched captdriver filter sources (drop-in replacements for the same files in
  captdriver's `src/`), with the following fixes on top of upstream:
  - Send `SetJobInfo2(flag=CONT)` repeatedly (~every 500ms) throughout the
    entire physical print duration, not just once — matches the genuine
    Canon Linux driver's observed heartbeat cadence.
  - Send `GetExtendedStatus` (0xA0A8) **twice**, unconditionally, immediately
    before every `ReserveUnit` — matches the genuine Canon Linux driver
    exactly (it never uses `GetBasicStatus` in this position).
  - Corrected a few `SetJobInfo2`/`IC_BEGIN_PAGE` payload bytes that had
    drifted from both the Windows and Linux reference captures (two mode
    flag bits, a non-uniform TonerDensity field, and the job-end flag value
    — use `3`, the real Linux-driver convention, not `6`).
  - Note: `ReserveUnit`'s payload should stay all-zero — that was already
    correct; an earlier hypothesis about a non-zero Windows-only byte was a
    dead end.
  - **Reply-stream resync (`capt-command.c`, added 2026-07-22)** — fixes the
    follow-up desync bug listed below. `capt_sendrecv()` no longer calls
    `exit(1)` when a reply header does not match the command it just sent;
    it slides the read window forward one byte at a time (bounded, 256 bytes)
    until the expected command word appears, discarding the stale reply and
    continuing the job. Also makes `capt_recv_buf()` loop until it has all the
    bytes it asked for, since `cupsBackChannelRead()` may legally return a
    short read (defensive — this path was never observed to trigger here).

## Result

**Original engine wedge: fixed.** Previously the printer wedged on *exactly*
job 5 in every single test. With this combination it ran 58 jobs in one
power-on session with zero wedges, including several unbroken runs of 10–15.

**Follow-up desync bug: also fixed** (2026-07-22). The remaining
"`bad reply from printer, expected A1 A0 xx xx xx xx, got D0 00 00 02 B0 09`"
failure was diagnosed: because `captd` deliberately keeps one USB session open
across jobs, a reply the printer was still emitting when the *previous* job's
filter exited stays queued, so the next job's first read gets the tail of the
old reply and every read after it is shifted by that offset. It killed ~1 job
in 8 before the fix.

Two changes address it, and the second is the one that actually makes it safe:

1. `captd` now drains the endpoint on client *disconnect* (after a 400ms
   settle) as well as on connect. This narrows the window a lot — measured
   2 failures in 15 jobs before, 1 in 40 after — but a time-based drain is
   inherently racy and did **not** eliminate it.
2. The filter now *resynchronises* instead of dying (see `capt-command.c`
   above). This is deterministic rather than timing-dependent.

Verified by injecting a deliberate 3-byte offset into the stream: the filter
logged `reply stream out of sync … got D0 00 00 A1 A1 38` (the real `A1 A1`
header visibly shifted 3 bytes in), then
`resynchronised after discarding 3 stale byte(s) -- job continues`, and the
job printed normally. 20 further real jobs afterwards: no desync, no wedge.

## Installing

**The project's `may-in-lbp2900.sh` (option 1) now does all of this
automatically** — that is the normal way to install it. Before 2026-07-22 the
script did *not*: these sources sat here unused while the script built stock
captdriver against the `usb://` backend, so every install still wedged on job
5. If you are doing it by hand:

1. Build `captd` (needs `libusb-1.0-dev`, `-lpthread`) and run it as a
   persistent service (root, for USB access) — see the comment at the top of
   `captd.c` for the wire protocol if you want to adapt it.
2. Copy the 7 patched sources over the matching files in captdriver's `src/`
   and rebuild `rastertocapt` as usual.
3. Build `capt-backend` (needs `libcups2-dev`) and install it to
   `/usr/lib/cups/backend/capt` (root-owned, mode 0700, matching CUPS's
   backend security requirements).
4. Point the printer's CUPS device-uri at `capt:/run/captd/lbp2900.sock` (or
   wherever you run `captd`'s socket) instead of `usb://...`.
