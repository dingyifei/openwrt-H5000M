# openwrt-H5000M

Reproducible build of the **official OpenWrt/ImmortalWrt base image** for the **Hiveton
H5000M** (MediaTek filogic router with a **Fibocom FM350-GL** modem). This repo produces the
base firmware; the custom feature packages (FM350 uplink stack, LuCI apps, SMS/eSIM/TTL) live
in the sibling repo **`openwrt-H5000M-plugins`** and are layered on top.

## Start here
- **`FM350-GL-SETUP.md`** (repo root) — the canonical device + AT-command reference and
  troubleshooting guide. Read it before touching anything modem-related.
- `docs/H5000M-hardware-notes.md`, `docs/at-capture-2026-07-28.md`, `docs/apn-reference.md`.
- `ROADMAP.md` — current work and status. `docs/superpowers/specs/` — design specs.

## The device
`192.168.10.1`, root SSH **key auth works** (no password). It is a **recoverable test device**
— you may run diagnostics *and* sensitive/destructive operations on it directly (reflash,
reboot, AT writes, modem reset). This supersedes any older "never touch 192.168.10.1" posture.
On-device verification and committing are still the lead's call, but you are cleared to operate
the box.

## Working with the modem (on-device)
- Use **`atq`** / `atq -b` for AT commands — the sanctioned locked path (via
  `/usr/lib/h5000m/atio.sh`), not raw `tom_modem`. For manual raw work use `/dev/ttyUSB1`
  (never QModem's poller port), and **never `AT+COPS=?`** — it blocks the AT port for minutes.
- The current image uses the custom **`fm350-dialer`** (netifd proto `fm350`), not QModem — old
  QModem-era notes in `FM350-GL-SETUP.md` are marked as historical.

## Hard constraints (don't fight these)
- **No RTC** on this board — never build timeouts from the wall clock (`date +%s`); use
  counters or `/proc/uptime`.
- `cid 1` is **IMS** on China Telecom; the internet context is a modem-chosen `aid` via
  `AT+EAPNACT`. RNDIS bridges exactly one active context.
- The modem keeps reporting a **stale `CGPADDR` after the carrier drops the data bearer** — a
  live IP is not proof of connectivity (`ping -I eth2 …` is the real test). The dialer's
  watchdog exists for exactly this.

## Build
- `scripts/build-official-base-docker.sh` / `build-official-base-local.sh` build the base image.
- `configs/` holds the **locked** feed/package/manifest snapshots; package availability is
  authoritative from those locked feed indexes, not live upstream listings.
- CI (`.github/workflows/build.yml`) builds the base image; there is no test suite in this repo
  (the plugin repo carries the tests).
