# FM350-GL Cellular Modem — Setup & Reference (H5000M)

Getting internet working through the **Fibocom FM350-GL 5G modem** on the **Hiveton H5000M**,
running the **clean official OpenWrt/mt76 base** this project ships. Management is the custom
**`fm350-dialer`** (netifd proto `fm350`), *not* QModem. The QModem-era recipe is kept as a
short appendix at the end.

> **Names renumber — never hard-code them.** The data netdev (`eth2` in older notes) and the
> `ttyUSB*` nodes are assigned by enumeration order and change between boots and firmware. Use
> `modem-ports` to discover them and the `cellular` UCI interface to drive the link.

---

## 1. Hardware & firmware facts (do not fight these)

| Thing | Value |
|---|---|
| Router | Hiveton H5000M — official base, target `mediatek/filogic`, aarch64 |
| Modem | Fibocom FM350-GL (MediaTek T700/M80), 5G, on the **USB** bus |
| USB ID | `0e8d:7127` — RNDIS composition (`GTUSBMODE 41`) |
| Data path | single **RNDIS** netdev via `rndis_host` (name renumbers) |
| AT access | `atq` / `atq -b` (sanctioned, locked); published ports `/dev/modem-at0` / `/dev/modem-at1` |
| Packages | `kmod-usb-serial-option`, `kmod-usb-net-rndis`, `464xlat`+`kmod-nat46` (IPv6-only carriers), `coreutils-stty`; glue `h5000m-modem-atd` (AT broker) + `h5000m-fm350` (proto + dialer) |

**Firmware constraints (verified):**
- `AT+GTUSBMODE=?` returns only `(40,41)` — **both are RNDIS**. There is **no MBIM or QMI over
  USB** on any FM350-GL firmware (MBIM exists only over PCIe with `mtk_t7xx`, unused here).
  Do not try to reflash for MBIM/QMI; it only risks bricking. Firmware is MediaTek secure-boot signed.
- `AT+GTRNDIS` → `+CME ERROR: 100` is **normal** — MediaTek FM350 brings the data plane up with
  `+EAPNACT`/`+CGACT`, not `GTRNDIS`.
- `AT+EIAAPN` (initial/attach APN) and `AT+CGAUTH` **do not exist on this firmware**, so there is
  no attach-APN knob and `auth` can only ever be `none`.
- **No RTC on this board** — never build a timeout from the wall clock (`date +%s`); the clock
  steps forward when the network comes up. Count down with `/proc/uptime` or a counter instead.
- **The modem keeps its APN in its own NVRAM across a router reflash.** A clean image does not
  imply a clean modem — context 1 may still hold the vendor's `ctnet`.

---

## 2. Connect & health check

```
ssh root@192.168.10.1        # key auth works, no password
```
All commands run **on the router** unless stated otherwise.

```
cat /etc/openwrt_release          # confirm the base
lsusb | grep -i fibocom           # modem detected
modem-ports                       # discovered AT ports + data netdev
```

---

## 3. AT access — the sanctioned path

`atq` runs one command on the leased AT port; `atq -b` runs several under a single acquisition:

```
atq 'AT+CSQ'
atq -b 'AT+CESQ' 'AT+COPS?' 'AT+CEREG?' 'AT+CGACT?'
```

`atq -b` emits an attributable stream (`@@CMD …` / reply / `@@RC 0`) and is far cheaper than four
separate acquisitions. For a foreign tool that must own the port for its whole lifetime, use
`at-lease` (e.g. `at-lease lpac chip info`).

**Discovery.** `option` binds the seven `ff/00/00` interfaces to `ttyUSB0..6`, but **only one of
them runs an AT parser** (interface 6, `ttyUSB3` on one boot — it renumbers). The rest are
MediaTek binary channels (DIAG/GNSS/coredump) that answer with silence, not errors. Discovery
walks sysfs for `0e8d:7127`, probes candidates in order `6 3 7 8 9 4 2`, and publishes
`/dev/modem-at0` / `/dev/modem-at1`. Locks are keyed on the stable USB path (`2-1`) + interface
number, never on the tty name.

```
modem-ports --rescan        # re-probe (~1s; MODEM_DEEP_SCAN=1 probes all, ~26s)
```

**Denylist — `atq` refuses these on purpose:**
- **`AT+COPS=?`** — a network scan blocks the single AT port for ~71 s.
- **`AT+CFUN=`** and **`AT+CGDCONT=1,`** — dialer-owned state.
- **`AT+GTACT=`** / **`AT+GTDUALSIM=`** — radio-guard-owned writes (`=?` test form is still allowed).

**Priorities.** Four consumers contend for the one port; each declares `AT_PRIO`:

| consumer | `AT_PRIO` |
|---|---|
| `fm350-dialer` (bearer health) | 30 |
| `h5000m-sms`, `h5000m-esim` (user-initiated) | 20 |
| `atq` (interactive) | 10 |
| `luci-app-fm350` status poll (cosmetic) | 1 |

Waiters record intent in `<lockfile>.want` and decline to race when something higher is queued.
This is **approximate** priority (`flock` has no ordering), enough to stop a UI poll starving the
dialer — not a scheduling guarantee.

---

## 4. Verify the SIM & radio first

```
atq -b 'AT+CPIN?' 'AT+CIMI' 'AT+CESQ' 'AT+CEREG?' 'AT+COPS?'
```
- `+CPIN: READY` → SIM OK. Anything else → locked/missing; stop here.
- `+CEREG: 0,1` or `0,5` → registered; proceed. `0,2` → searching (radio/coverage/SIM, **not** a
  config problem — fix the radio first).
- **Signal:** ignore `AT+CSQ` (reports `99,99` here). Use `AT+CESQ` — see §6 for RAT-dependent
  field decoding.

**Carrier by IMSI prefix (`AT+CIMI` first 5 digits):**

| Prefix | Carrier | Internet APN |
|---|---|---|
| 46003, 46005, 46011 | China Telecom | `ctnet` |
| 46000/02/04/07/08 | China Mobile | `cmnet` |
| 46001/06/09 | China Unicom | `3gnet` |
| 46015 | China Broadnet | `cbnet` |

Auth is `none` for every Chinese carrier. `46012` is **not** an allocated MNC (it propagates
through copied lists online) — do not use it.

> **Prefer a blank APN over the table.** `""` requests the subscription default (TS 27.007
> §10.1.1) and is self-correcting across every carrier, MVNO and travel eSIM. A *wrong* APN
> attaches to the wrong PGW and silently black-holes traffic while still reporting `+CEREG: 0,1`.
> Use the table only as an optimisation after a blank attach.
>
> **Never reuse an IoT APN on a consumer SIM** (`cmiot`, `scuiot`/`cuiot`/`unim2m.*`, `ctiot`).
> Chinese IoT SIMs broadcast the same MCC-MNC as consumer SIMs, so an IMSI table cannot tell them
> apart. Full China + US + travel-eSIM table with per-row confidence lives in
> [`docs/apn-reference.md`](docs/apn-reference.md).

Two carrier-side facts worth knowing:
- **A single-family grant is SUCCESS.** Requesting `IPV4V6` and getting IPv4-only or IPv6-only is
  an *accept* (ESM cause #50/#51/#52), not a reject — do not build PDP-type retry logic.
- **T-Mobile US is IPv6-only** and the FM350 does not run CLAT; without `464xlat` + `kmod-nat46`
  on the router, IPv4 silently fails and looks like a wrong APN.

---

## 5. Data bring-up — how it works

**The rule: exactly one PDP context may be active, and you activate it with `+EAPNACT`.** The
dialer does this automatically; the manual sequence below is for debugging.

Why this shape:
- **`+EAPNACT` activates by APN name + type; the modem picks the aid.** It never returns the
  `5847` refusal that `AT+CGACT=1,1` hits.
- **`AT+CGACT=1,1` cannot work on China Telecom** — cid 1 is auto-provisioned as **IMS**
  (`IM_CN_Signalling_Flag_Ind = 1`, IPv6-only) and the network holds it. The internet bearer is a
  modem-chosen aid, not cid 1.
- **RNDIS forwards only when exactly one context is active.** With two or more live, `tx` climbs
  and `rx` stays 0 (the black-hole signature) regardless of cid number. Deactivate all, activate
  one.
- **`arp off` is required** — the generic `rndis_host` profile lacks `NOARP` for this device
  (OpenWrt PR #24196). Necessary but not sufficient on its own.

**Manual sequence (debugging):**
```
atq -b 'AT+EAPNACT=0,<aid>' ...        # deactivate every currently-active aid first
atq 'AT+EAPNACT=1,"ctnet","default"'   # -> +CGEV: ME PDN ACT <aid>,<n>  (modem picks the aid)
atq 'AT+CGPADDR=<aid>'                  # -> the IPv4 for that aid
# then, on the discovered data netdev (NETDEV=$(modem-ports ...)):
ip link set $NETDEV arp off up
ip addr add <ip>/24 dev $NETDEV
ip route replace default via <ip-with-.1> dev $NETDEV
```
Verify: `ping -I $NETDEV -c3 1.1.1.1` and a `curl -4 --interface $NETDEV https://www.baidu.com`
should return HTTP 200; `rx_packets` should climb.

> **Parsing trap:** `AT+CGPADDR` returns the IPv6 address as **sixteen** dotted octets, which a
> naive `[0-9.]+` regex matches as if it were IPv4. Select the field with exactly four octets.

**The dialer.** `fm350-dialer` (proto `fm350`, UCI interface `cellular`) waits for the modem to
enumerate and for `AT+CPIN?` to report `READY`, then: deactivates all aids, `+EAPNACT`s exactly
one, parses the aid from `+CGEV: ME PDN ACT <aid>,<n>`, reads `CGPADDR=<aid>` (four-octet field),
sets `arp off`, and publishes the address via netifd. It **ladders over the APN** (configured →
blank) **and over the APN type** (configured → `default` → `net` → `tethering`), because the type
that a carrier accepts is not stable and a refusal carries no reason (`AT+CEER` → `0,NONE`). It
re-publishes address changes rather than re-dialing, and never sets `proto_set_keep` (that would
leave a stale address attached and kill the uplink silently).

> Both waits are load-bearing: the AT port answers before the SIM initialises, and inserting a SIM
> makes the modem rerun carrier config (`+EDSBP`/`+EONSNWNAME` URCs) before CPIN settles. The
> modem also enumerates on USB strictly *before* it finishes booting, and it self-resets (all
> `ttyUSB` nodes vanish for ~90 s) with no host involvement — so **one failed probe is not "no
> modem"**. The dialer polls up to ~2 min before declaring `NO_MODEM`; failing slowly is the safe
> behaviour here because netifd respawns a proto command that exits.

### Making the SIM the primary WAN
The router may also have a Wi-Fi client default route. Linux prefers the **lowest metric**; give
`cellular` a lower metric than Wi-Fi (or bring Wi-Fi down), and ensure the interface is in the
`wan` firewall zone so LAN clients are NAT'd out.

---

## 6. The dead-but-addressed bearer, and the watchdog

**Symptom:** clients lose cellular internet, but the interface shows up with an IP, `AT+CPIN?` is
`READY`, `AT+CEREG?` is registered, and a manual `ifup cellular` fixes it — for a while.

**Cause:** the carrier tears down the data bearer, but the FM350 **keeps advertising the old IPv4
via `AT+CGPADDR` indefinitely** (observed: a dead address reported for ~1.5 h while the link
passed zero packets; `AT+CGACT?` listed no active context). **A live IP is not proof data flows.**

**Discriminator (one command):**
```
ping -I $NETDEV -c3 1.1.1.1        # forces egress out the modem regardless of default route
```
100% loss while `AT+CGPADDR` still returns an IPv4 = dead-but-addressed.

**Fix (shipped):** `fm350-watchdog.sh` actively probes the data path (`ping -I $netdev` to
`1.1.1.1 8.8.8.8 9.9.9.9`; a cycle is down only if *all* fail) and, after `probe_fails` consecutive
failures, climbs **re-dial → modem reset (`fm350-usb-reset`) → reboot**, with a persistent guard
that caps reboots so a genuinely-down carrier can't reboot-loop the router. Counters clear only
after data has *held* for `healthy_hold` seconds. All knobs are UCI options on the `cellular`
interface: `watchdog`, `probe_targets`, `probe_interval`, `probe_timeout`, `probe_fails`,
`redial_limit`, `modem_reset_limit`, `reboot_limit`, `healthy_hold`. `watchdog=0` disables it;
`reboot_limit=0` keeps the ladder but never reboots. Timing is counter-based (no RTC).

---

## 7. Radio control & status

### Signal — `AT+CESQ` (not `AT+CSQ`)
`AT+CSQ` reports `99,99` and is useless. `AT+CESQ` is the source, but **which fields carry data
depends on the RAT** and this unit moves between them:

```
NR  : +CESQ: 99,99,255,255,255,255,83,73,77    <- fields 7,8,9 live
LTE : +CESQ: 27,99,255,255,16,44,255,255,255   <- fields 5,6 live
```
`255` = not available. Decide from which set is populated (cross-check `AT+COPS?` access tech:
**7 = LTE, 11 = NR**). Do **not** use `AT+C5GREG?` for a status display — it returns a bare
`+C5GREG: 0` and shows "not registered" while `COPS` reports NR.

| metric | field | formula | example |
|---|---|---|---|
| LTE RSRP | 6 | `value − 140` dBm | 42 → −98 |
| LTE RSRQ | 5 | `(value/2) − 19.5` dB | 18 → −10.5 |
| NR SS-RSRP | 7 | `value − 156` dBm | 83 → −73 |
| NR SS-RSRQ | 8 | `(value/2) − 43` dB | 73 → −6.5 |
| NR SS-SINR | 9 | `(value/2) − 23` dB | 77 → +15.5 |

### What exists, what does not

| Want | Command | State |
|---|---|---|
| Lock to bands | `AT+GTACT` §11.1.14 | ✅ drives the UI |
| Nearby cells | `AT+GTCCINFO?` §11.1.15 | ✅ serving + up to 10 neighbours per RAT |
| MIMO / CA | `AT+GTCAINFO?` §11.1.16 | ✅ (10-field trap below) |
| Cell lock | `AT+EMMCHLCK` | ✅ LTE only (below) |
| SIM slot | `AT+GTDUALSIM` §4.3 | ✅ **persistent + destructive** |
| Change APN | `+CGDCONT` / `+EAPNACT` | ✅ in the dialer |
| Lock PCI/EARFCN/SCS, QCI/5QI | — | ❌ no command |
| TTL | — | ❌ done router-side |

> **Read/test forms erroring proves nothing on this firmware.** `AT+EAPNACT=?`, `AT+EIAAPN` with
> the wrong arity, and `AT+CCHO=?` all mislead in both directions, and `AT+CLAC` under-reports
> (37 commands, omits `+CGACT`/`+EAPNACT`/`+EMMCHLCK` which all work). **CLAC finding a command
> proves presence; CLAC missing one proves nothing.** Never guess a set-form blind — that is how
> this modem gets wedged.

### Band lock — `AT+GTACT`
```
AT+GTACT=<rat>,<PreferredAct1>,<PreferredAct2>[,<band>...]
RAT: 1 UMTS, 2 LTE, 4 LTE/UMTS, 10 auto, 14 NR, 16 NR/UMTS, 17 NR/LTE, 20 NR/LTE/UMTS
Preference: 2 UMTS, 3 LTE, 6 NR
```
- **Fields 2 and 3 are preferences, not bands**, and cannot be omitted — `AT+GTACT=20,,,103` and
  `AT+GTACT=14,6,` are both rejected (`+CME ERROR: phone failure`). A *trailing* empty (absent band
  list) is fine; an empty **preference** is not.
- **A read-back string is not necessarily replayable.** The modem reports empty preference fields
  (e.g. `+GTACT: 14,6,`) that it then refuses on write. Any code that captures and replays a
  `+GTACT` value must fill empty preferences from the string's own RAT first (`fm350-radio` does
  this via `gtact_replayable()`) — a silent restore failure presents as success.
- **Band sets are per-RAT and partial.** Setting LTE bands narrows only the LTE list; NR stays
  fully enabled. "Lock to B3" also needs a RAT constraint, and any revert must restore the *whole*
  previous parameter string.
- **A band-less string enables EVERY band of that RAT** — never use the short form to mean "leave
  bands as they are".
- **Numbering is a flat list, not a bitmask** (`+EPBSEH` is the bitmask one): LTE band *N* →
  `100+N`; NR band *N* → digits `50` then *N* (n1 = `501`, n20 = `5020`). Build the picker from
  `AT+GTACT=?`.
- **Persists in modem NVRAM across reboot and `sysupgrade`** — a reboot is *not* an escape hatch
  from a bad lock.

### Cell lock — `AT+EMMCHLCK`
```
AT+EMMCHLCK=?  ->  +EMMCHLCK: (0-1),(0,2,7),(0,1),(0-46589),(0-511)
                       enable   rat    ?      earfcn      pci
AT+EMMCHLCK?   ->  +EMMCHLCK: 1,7,0,1650,187,0     locked — SIX fields
AT+EMMCHLCK=1,7,0,<earfcn>,<pci>                   lock (LTE)
AT+EMMCHLCK=0                                      unlock
```
- **Read returns six fields, set takes five** — trim before replaying.
- **LTE only.** RAT accepts `0,2,7` and the ARFCN ceiling is 46589; the six-parameter NR form seen
  online is rejected here. A cell lock does **not** stop the modem using 5G — pair it with an
  LTE-only RAT, and **clearing the lock must restore the RAT** or the user silently loses 5G.
- **A `CFUN` cycle is needed for reselection, not for the lock to be accepted** — without it the
  lock reads as applied but the modem does not move.
- **The lock binds IDLE-mode selection only.** Once data flows, handover is the network's decision
  and the lock gets no vote (measured: idle held the locked cell 90 s; under load it moved to a
  neighbour and stayed). **Do not treat "registered + data flows" as proof the lock took** — read
  the serving PCI. Tell users it is a preference, not a pin; observe it only while the bearer is
  **down**.
- **Persists in NVRAM** across reboot (contradicting the online tip that it's lost on power loss;
  cold power-off is untested).
- **A neighbour row's EARFCN can be unusable as printed** — `AT+GTCCINFO?` offered `165084`, above
  the `EMMCHLCK` ceiling; the true carrier was EARFCN `1650`. Treat the PCI as trustworthy and the
  ARFCN as a hint; validate against `AT+EMMCHLCK=?` before offering a one-click "lock to this cell".

### The radio guard
`fm350-radio` is a procd one-shot that owns apply → verify → revert. It takes the interface down,
applies, waits for registration, brings it back up, and **verifies against data, not
registration** (a slot switch once registered perfectly while every PDP activation failed). UCI is
written only *after* data is confirmed, so a persisted lock is by construction one that carried
traffic. Writes go through the guard, not `atq` (which denies `AT+GTACT=` / `AT+GTDUALSIM=`).

### Parsing traps
- **`AT+GTCAINFO?` returns ten fields, the manual documents eight.** Order: band, PCI, EARFCN,
  DL BW, UL BW, **dl_mimo, ul_mimo**, dl mod, ul mod, RSRP. Modulation codes are shown raw — no
  authoritative code→QAM map exists for this modem.
- **`AT+GTDUALSIM?` puts a space before its colon** (`+GTDUALSIM : 0, …`) — anchor regexes accordingly.

---

## 8. eSIM / eUICC

**This unit has an eUICC (slot 1) and it is empty.** The Hardware Guide §3.5 confirms a built-in
eSIM alongside the physical SIM slot, and the modem reports it:

```
AT+GTDUALSIM?  -> +GTDUALSIM : 0, "SUB1", "NR"      slot 0 = physical SIM (in use)
AT+GTDUALSIM=1 -> switches to slot 1 (eUICC)
AT+EID         -> real 32-digit EID on slot 1; empty on slot 0
AT+CPIN?       -> EMPTY_EUICC                       present, no profile installed
```
`AT+EID` is the cheapest possible "is there an eUICC" probe — no lpac, no logical channel. (The EID
is a device identifier; read it from the device when needed, don't commit it.)

**lpac can drive this eUICC over plain `AT+CSIM`** — you issue MANAGE CHANNEL yourself rather than
asking the modem for a logical channel (lpac #394 has a verbatim FM350-GL trace ending in a full
`lpac chip info`). The FM350 leaves `+CSIM` unfiltered, unlike most basebands. The blocker is
**lpac's version, not the modem**: OpenWrt pins v2.3.0, and the `at_csim` backend landed after that
tag. A bridge speaking lpac's ndJSON `stdio` protocol over `AT+CSIM` under `at-lease` is the route;
expect the downstream blocker at ES9+ `authenticateClient` (see `ROADMAP.md` 2.4).

> OpenWrt's `/usr/bin/lpac` is a UCI wrapper that **overwrites `LPAC_APDU`** and hard-codes
> `/dev/ttyUSB2`/`/dev/cdc-wdm0` — both wrong here. Call `/usr/lib/lpac` directly so the
> environment stays authoritative; `h5000m-esim` does.

> **Switching SIM slots is destructive.** `AT+GTDUALSIM=1` then back left the modem registered but
> unable to activate any PDP context (`+CME ERROR: 5848`/`5841`), fixed only by changing the APN
> type; it can also leave the AT port half-dead (§10). Never switch slots over a link you depend on.

---

## 9. SMS

`h5000m-sms` wraps `sms_tool` under `at-lease`:
```
h5000m-sms status     -> Storage type: MT, used: 0, total: 90
```
Storage reports as **`MT`**, not the `ME`/`SM` in the `+CPMS` docs — which is why the wrapper does
not set a preferred storage.

> **`sms_tool` can hang forever and hold the AT port while it does** — an out-of-range delete slot
> (e.g. `99`, above the 90-slot store) loops per fragment and wedges the whole AT layer, taking the
> dialer down with it. `h5000m-sms` wraps it in `timeout -s TERM -k 5` (default 45 s; the web
> backend passes `H5000M_SMS_TIMEOUT=10` for deletes so one bad index can't blow the ~30 s ubus
> budget). An in-range empty slot returns immediately; only out-of-range hangs.

> **`null` is not a valid ubus argument** — rpcd types every argument from the backend's `args`
> exemplar and rejects a null outright, so the call never reaches the backend. Use a
> type-appropriate empty (`0` for int, `''` for string). `tests/test-plugin-invariants.sh` rejects
> nulls statically.

---

## 10. AT-layer operations & hardware recovery

### Logging
`/etc/config/h5000m` controls verbosity at runtime (no rebuild):
```
uci set h5000m.logging.fm350=trace     # error|warn|info|debug|trace
uci commit h5000m
```
`trace` prints the AT wire itself. Two limits: **levels are read once per process** (short-lived
tools pick up a change next run; a long-lived dialer needs `ifdown cellular; ifup cellular`), and
**a process logs under one component** (the dialer sources the AT layer, so everything inside it,
AT traces included, is governed by `fm350`, not `modem_atd`).

**Redaction is on by default at every level.** AT traffic carries IMSI/ICCID/EID/phone
numbers/SMS bodies and syslog can be forwarded off-box. Masking matches on value *shape* (long
digit/hex runs, long quoted strings), so it keeps covering commands added later. `trace_redact 0`
exists for local debugging and logs a warning. For a bounded window without writing to flash:
```
h5000m-log-capture 120 fm350=trace     # follows to /tmp (tmpfs — copy off before reboot), reverts on exit
```

### No RTC — count down, never off the wall clock
There is no `/dev/rtc*`; the clock starts at the image build date and **sysntpd steps it forward
when the network comes up**, landing inside the dialer's modem wait. A deadline like
`_end=$(( $(date +%s) + N ))` is computed before the step and already in the past after it, so the
loop exits on its first check. Count down (`_left=$N; while [ "$_left" -gt 0 ]; …`) instead. In a
**read** loop decrement only on an actual timeout, or long replies (`AT+CLAC` = 37 lines) get
truncated. `tests/test-plugin-invariants.sh` fails on `date +%s` under `files/usr/sbin` or
`files/usr/lib`.

### The AT port can go half-dead — recover it
A single serial endpoint can die while the device enumerates perfectly. `stty -F <at-port>`
reporting **`Not a tty`** (or a passive read echoing only your own writes) is the tell — `lsusb`
and driver bindings look fine. **`unbind`/`bind` does NOT fix this and can make it worse.** What
fixes it:
```
echo 0 > /sys/bus/usb/devices/2-1/authorized
sleep 8
echo 1 > /sys/bus/usb/devices/2-1/authorized
# ~70 s later the ttyUSB nodes return; verify with stty, not ls (nodes reappear before they work)
```
The shipped tool is **`/usr/sbin/fm350-usb-reset`**, which `setsid`-detaches into its own session
and re-authorises from a trap, so even a targeted kill can't strand the device at `authorized=0`
(a bare backgrounded `popen()` from rpcd could — rpcd restarts would `SIGTERM` the whole group
mid-window and permanently deauthorise the modem). Callers: LuCI "Reset modem" and
`fm350-usb-reset --wait`. Slot switching (`AT+GTDUALSIM`) is a known trigger for this state.

---

## 11. Quick diagnostic reference

```
# identity / radio
atq -b 'ATI' 'AT+CPIN?' 'AT+CIMI' 'AT+CESQ' 'AT+CEREG?' 'AT+COPS?'
# data / contexts
atq -b 'AT+CGDCONT?' 'AT+CGACT?' 'AT+GTDNS=1'
atq 'AT+CGPADDR=<aid>'
# host side (discover the netdev name first — do not assume eth2)
modem-ports
ip -4 addr show <netdev> ; ip route
dmesg | grep -iE 'rndis|watchdog' | tail
# the real connectivity test
ping -I <netdev> -c3 1.1.1.1
```

---

## 12. Sources

**Local (`docs/`):** `FM350-GL-AT-Commands.pdf` (V2.2), `FM350-GL-Hardware-Guide.pdf`,
`docs/apn-reference.md`, `docs/at-capture-2026-07-28.md`, `docs/H5000M-hardware-notes.md`.

**Online:**
- QModem (historical management package): https://github.com/FUjr/QModem — issue
  [#179](https://github.com/FUjr/QModem/issues/179) (the pdp_index story) and #169 (cid 1 = IMS).
- mrhaav's OpenWrt FM350-GL driver (independent, uses `+EAPNACT`/retry-on-5847):
  https://github.com/mrhaav/openwrt/tree/master/atc/fib-fm350_gl
- OpenWrt forum "Fibocom FM350-GL support": https://forum.openwrt.org/t/fibocom-fm350-gl-support/142682
- OpenWrt PR #24196 (adds `rndis_host` IDs `0e8d:7126`/`7127` with `NOARP`) — not yet in our kernel,
  hence the manual `arp off`.
- lpac #394 (FM350-GL over `AT+CSIM`), #300 (test-form ≠ support on Fibocom).

Do **not** attempt to reflash the modem for MBIM/QMI over USB — it does not exist for the FM350-GL;
RNDIS is the only USB data path. Reflashing only risks bricking.

---

# Appendix: the QModem-era recipe (historical)

The project no longer ships QModem — this is retained for reference only. QModem drove the modem on
ImmortalWrt 24.10 with a `pdp_index` config knob and hard-coded `eth2` / `ttyUSB1` / `ttyUSB3`
names. Its config lived in `/etc/config/qmodem` (section `2_1`):

```
uci set qmodem.2_1.apn='ctnet'
uci set qmodem.2_1.auth='none'
uci set qmodem.2_1.pdp_index='1'        # QModem's cid knob
uci set qmodem.2_1.pdp_type='IPV4V6'
uci commit qmodem
/etc/init.d/qmodem_network restart
/etc/init.d/qmodem_network redial 2_1
tail -20 /var/run/qmodem/2_1_dir/dial_log   # confirm the dialed context
```

**Why it was replaced.** The `pdp_index` knob encodes the wrong mental model: the real constraint
is *exactly one active context activated via `+EAPNACT`* (§5), not a specific cid number — which is
why "use cid 1" worked for some and not others, and why cid 1 fails outright on China Telecom
(IMS). QModem also polls a fixed AT port continuously, which contends badly with the dialer and
`lpac`/`sms_tool` on this single-AT-port modem; the sanctioned locked `atq` path (§3) replaced that.
For AT-port contention symptoms QModem produced (`at port response unexpected`, wedged `tom_modem`
in `D` state), the fix on the current stack is the priority queue in §3 and, if the port is truly
deaf, the `fm350-usb-reset` recovery in §10.
