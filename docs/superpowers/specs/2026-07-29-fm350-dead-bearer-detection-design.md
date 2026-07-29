# FM350 dead-bearer detection & tiered recovery — design

**Date:** 2026-07-29
**Status:** approved, implemented
**Repos:** `openwrt-H5000M-plugins` (code/tests), `openwrt-H5000M` (docs)

## Problem

On the live H5000M (China Telecom, FM350-GL) the cellular WAN silently blackholes IPv4 while
the modem stays registered. Root-caused on hardware 2026-07-28/29:

- The carrier tears down the data bearer, but the FM350 **keeps reporting the stale IPv4 via
  `AT+CGPADDR`** indefinitely (verified: `AT+CGPADDR=2` returned the dead `100.98.157.29` for
  ~1.5 h while `ping -I eth2` was 100% loss and `AT+CGACT?` listed no active context).
- `fm350-dialer`'s only liveness test was *"does `CGPADDR=aid` still return an IPv4?"*
  (`ipv4_of`). Because the IP never changes, the dialer believed the link healthy and never
  re-dialed. Its one dead-bearer signal — a tx-rising/rx-flat heuristic — was **log-only**,
  and was additionally dormant in the incident because a Wi-Fi failover had pulled the default
  route off `eth2`, so `eth2` wasn't even transmitting.
- `ifup cellular` (fresh `AT+EAPNACT` → new bearer/IP) fixes it — until the carrier drops it
  again. Hence "press reconnect and it works," but only a human triggers it.

This is a known class of failure: ModemManager itself only *reports* ISP-triggered
disconnects; something above the modem must detect and act. The recovery plumbing already
existed (`proto_notify_error BEARER_LOST; exit 1` → netifd respawns → fresh re-dial); only
**detection** was missing.

## Approach

Add an **active data-path probe** to the dialer's monitor loop and a unified `bearer_recover`
decision point that drives a cyclic, guarded **re-dial → modem-reset → reboot** ladder. The
logic lives in a sourceable library, `fm350-watchdog.sh`, so it is unit-testable without
hardware.

### Detection
- In the steady-state monitor loop (after `publish`, so the route is installed — no deadlock
  with the original "a probe would need the route publishing installs" concern), probe
  `ping -I "$MODEM_NETDEV" -c1 -W<t> <target>` per cycle. `-I <netdev>` forces egress out the
  modem regardless of default-route/metric, so it stays correct under Wi-Fi failover, and
  never hard-codes `eth2`.
- Multi-target (`1.1.1.1 8.8.8.8 9.9.9.9`), **all-must-fail**: a cycle is "down" only if every
  target fails, so one dead anycast node can't trip recovery.
- Consecutive failed cycles → after `probe_fails`, declare the bearer dead. Any success resets
  the streak. This coexists with the pre-existing `CGPADDR`-empty detector (kept — it catches a
  clean drop faster); either detector enters the same ladder.

### Recovery ladder (`bearer_recover`)
A restart-surviving counter at `/var/run/fm350-<iface>.recov` (tmpfs: survives netifd respawn,
resets on reboot) selects the tier for the R-th consecutive recovery attempt, with
`cycle = redial_limit + modem_reset_limit` and `pos = (R-1) mod (cycle+1)`:
- `pos < redial_limit` → **Tier 1 re-dial**: `proto_notify_error BEARER_LOST; exit 1`.
- `pos < cycle` → **Tier 2 modem reset**: `fm350-usb-reset --wait` (AT endpoint usable ~70 s
  later, which the respawned dialer's modem-wait already handles), then exit → re-dial.
- else → **Tier 3 reboot, guarded** (below).

### Recovery confirmation (breaks the loops)
"Healthy" is counter-based, never wall-clock (RTC-less board): after a re-dial publishes, the
bearer is declared *recovered* only once the probe has passed for
`ceil(healthy_hold / probe_interval)` consecutive cycles. On that event both counters reset.
An isolated hours-later drop therefore never climbs the ladder; only a *stuck* state does.

### Reboot-loop guard (persistent)
A reboot wipes `/var/run`, so Tier 3 needs its own persistent counter:
`/etc/h5000m/fm350-<iface>.reboot-guard` (overlay; written only during recovery, `sync`'d
before the reboot), mirroring `fm350-radio`'s file-based `simslot.pending` `BOOTS=N` prior art
and kept across sysupgrade via `keep.d`. Before rebooting: if `guard >= reboot_limit`, **do not
reboot** — log loudly, reset the cycle, keep cycling tiers 1–2 (a degraded-but-alive box beats
a reboot-looping brick). The `healthy_hold` confirmation resets the guard, so a reboot that
*works* clears it. `reboot_limit=0` disables Tier 3 entirely.

## Config surface (UCI, on the `cellular` interface)
`watchdog` (default 1), `probe_targets` (`1.1.1.1 8.8.8.8 9.9.9.9`), `probe_interval` (15),
`probe_timeout` (2), `probe_fails` (4), `redial_limit` (3), `modem_reset_limit` (2),
`reboot_limit` (2), `healthy_hold` (120). Declared via `proto_config_add_*` in `fm350.sh` and
passed to the dialer with UCI-or-default values (never empty).

## Files
- `package/h5000m-fm350/files/usr/lib/h5000m/fm350-watchdog.sh` — new library (probe, counters,
  `ladder_tier`, `bearer_recover`).
- `package/h5000m-fm350/files/usr/sbin/fm350-dialer` — source the library, parse the tunables,
  probe-integrated monitor loop, header carve-out.
- `package/h5000m-fm350/files/lib/netifd/proto/fm350.sh` — option plumbing.
- `package/h5000m-fm350/{Makefile, files/lib/upgrade/keep.d/h5000m-fm350}` — install + persist.
- `tests/test-fm350-recovery-ladder.sh` — 39 assertions with negative controls; wired into CI.

## Testing / verification
- Host: `sh tests/test-fm350-recovery-ladder.sh` (ladder mapping, counter transitions, guard
  exhaustion, `reboot_limit=0` kill-switch, probe all-must-fail, healthy-hold reset, corrupt
  counter). Negative-controlled per repo convention.
- Hardware (`192.168.10.1`): induce a dead bearer by blocking the probe targets out `eth2`
  while `CGPADDR` stays populated (the exact incident shape); confirm Tier-1 re-dial recovers
  and the counter clears after `healthy_hold`; force escalation to confirm Tier-2/Tier-3 and
  guard exhaustion; confirm `watchdog=0` restores the old behavior.

## Out of scope
- No mwan3 coupling — the probe is self-contained so it works with or without mwan3.
- A dedicated flap policy (bearer that comes up, holds < `healthy_hold`, dies) — handled by
  re-dial without escalation; not separately governed.
