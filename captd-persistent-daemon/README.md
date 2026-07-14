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
- `prn_lbp2900.c`, `printer.h`, `capt-command.h` — the patched captdriver
  filter sources (drop-in replacements for the same files in captdriver's
  `src/`), with the following fixes on top of upstream:
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

## Result

14 consecutive real print jobs succeeded in one power-cycle session with this
combination (previously **always** failed on job 5, in every test across the
whole investigation). One occasional, self-recovering USB reply desync bug
remains in the `captd`/`capt-backend` relay (not the original engine wedge) —
tracked as a follow-up, not yet fixed.

## Installing

1. Build `captd` (needs `libusb-1.0-dev`, `-lpthread`) and run it as a
   persistent service (root, for USB access) — see the comment at the top of
   `captd.c` for the wire protocol if you want to adapt it.
2. Copy the 3 patched sources over the matching files in captdriver's `src/`
   and rebuild `rastertocapt` as usual.
3. Build `capt-backend` (needs `libcups2-dev`) and install it to
   `/usr/lib/cups/backend/capt` (root-owned, mode 0700, matching CUPS's
   backend security requirements).
4. Point the printer's CUPS device-uri at `capt:/run/captd/lbp2900.sock` (or
   wherever you run `captd`'s socket) instead of `usb://...`.
