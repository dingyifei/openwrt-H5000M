# FM350-GL Cellular Modem — Setup & Troubleshooting Guide (H5000M / ImmortalWrt)

This guide explains how to get internet working through the **Fibocom FM350-GL 5G modem**
on the **Hiveton H5000M** router running **ImmortalWrt 24.10** (MediaTek filogic target),
using the **QModem** package that is preinstalled on this build.

It is written to be followed step by step, including by a small/less-capable agent.
**If you only read one thing, read the box below.**

---

## ⭐ THE ONE KEY FACT (this is what makes it work)

> **The FM350-GL in RNDIS/USB mode ONLY forwards internet traffic on PDP context ID 1
> (the default/initial bearer). You MUST put the APN on context 1 (`AT+CGDCONT=1,...`)
> and activate context 1 (`AT+CGACT=1,1`). If you put the APN on any other context
> (e.g. context 3, which QModem historically defaulted to), the modem WILL get an IP
> address but will silently DROP all traffic — packets go out, nothing comes back.**

Symptom of the wrong-context bug: the interface `eth2` transmits (`tx_packets` rises) but
receives nothing (`rx_packets` stays ~2), and `dmesg` shows
`rndis_host ... NETDEV WATCHDOG: transmit queue timed out`.

The fix in the QModem config is simply: **`pdp_index=1`** (see Section 4).

---

## 1. Hardware / firmware facts (context — do not fight these)

| Thing | Value | Notes |
|---|---|---|
| Router | Hiveton H5000M | ImmortalWrt 24.10-SNAPSHOT, target `mediatek/filogic`, aarch64 |
| Modem | Fibocom FM350-GL (MediaTek T700/M80) | 5G, appears on **USB** bus, not PCIe |
| USB ID | `0e8d:7127` | This is RNDIS composition (`GTUSBMODE 41`) |
| Data interface | **`eth2`** | Linux driver `rndis_host` — this is the cellular data netdev |
| AT command ports | **`/dev/ttyUSB1`** and **`/dev/ttyUSB3`** | ttyUSB3 is QModem's configured port; **prefer ttyUSB1 for manual commands** |
| Management tool | **QModem** (`qmodem` package, LuCI `luci-app-qmodem-next`) | Config file: `/etc/config/qmodem` |
| AT tool binary | `tom_modem` | Usage: `tom_modem -d /dev/ttyUSB1 -c "AT..." -t 5` |

**Firmware constraints you cannot change (verified):**
- `AT+GTUSBMODE=?` returns only `(40,41)` — **both are RNDIS**. There is **no MBIM or QMI
  USB mode** on any FM350-GL firmware. Do **not** try to "unlock" or reflash to get MBIM;
  it does not exist over USB (MBIM only exists over PCIe with the `mtk_t7xx` driver, which
  this board does not use for the modem). Firmware is MediaTek secure-boot signed.
- `AT+GTRNDIS` returns `+CME ERROR: 100` (**unsupported on this firmware**). This is
  **normal and expected** — the MediaTek FM350 uses `AT+CGACT` for data-plane bring-up,
  not `GTRNDIS`. Do not chase this error.

---

## 2. How to connect to the router

From a machine on the router's LAN:
```
ssh root@192.168.88.1        # password: admin   (adjust if changed)
```
All commands in this guide are run **on the router** unless stated otherwise.

Quick health check once logged in:
```
cat /etc/openwrt_release            # confirms ImmortalWrt
ls /sys/class/net | grep eth2       # eth2 must exist (the RNDIS data interface)
lsusb | grep -i fibocom             # confirms the modem is detected
```

---

## 3. Verify the SIM & radio FIRST (before touching data config)

Run these on the AT port. **Use `/dev/ttyUSB1`.**

```
tom_modem -d /dev/ttyUSB1 -c "AT+CPIN?"    -t 4    # want: +CPIN: READY  (SIM present/unlocked)
tom_modem -d /dev/ttyUSB1 -c "AT+CIMI"     -t 4    # IMSI. First 5 digits = carrier (see below)
tom_modem -d /dev/ttyUSB1 -c "AT+CSQ"      -t 4    # signal. want NOT "99,99"
tom_modem -d /dev/ttyUSB1 -c "AT+CEREG?"   -t 4    # want: +CEREG: 0,1 (registered) or 0,5 (roaming)
tom_modem -d /dev/ttyUSB1 -c "AT+COPS?"    -t 4    # want: an operator name, e.g. "CHN-CT"
```

**Interpreting the results:**
- `+CPIN: READY` → SIM OK. Anything else (e.g. `SIM PIN`) → SIM locked/missing; stop here.
- `+CSQ: 99,99` → **NO SIGNAL**. Causes: antennas not connected, no coverage, or the SIM's
  carrier/band is not available. (A China Mobile IoT SIM with APN `scuiot` showed `99,99`
  here and never registered; a China Telecom phone SIM showed `CSQ 12` and registered fine.)
- `+CEREG: 0,2` → searching, not registered (usually a signal/coverage/SIM problem, NOT a
  config problem — fix the radio first).
- `+CEREG: 0,1` or `0,5` → **registered. Good, proceed to data setup.**

**Carrier by IMSI prefix (`AT+CIMI` first 5 digits):**
| Prefix | Carrier | Internet APN |
|---|---|---|
| 46003, 46005, 46011 | China Telecom (中国电信) | **`ctnet`** |
| 46000/02/04/07/08 | China Mobile (中国移动) | `cmnet` |
| 46001/06/09 | China Unicom (中国联通) | `3gnet` |
| 46015 | China Broadnet (中国广电) | `cbnet` |

> **Corrections (2026-07-26, sourced from AOSP `apns-full-conf.xml` + ITU-T E.212B):**
> - **`46012` was removed — it is not an allocated MNC.** It propagates through copied
>   APN lists online; it is absent from ITU E.212B (2023), the Wikipedia MCC-460 table,
>   and AOSP.
> - **46005 added** (China Telecom, ex-CDMA) and **46015 / `cbnet` added** — China
>   Broadnet is a live 4th operator that was missing entirely.
> - Auth is `none` for **every** Chinese carrier. ⚠️ The GNOME
>   `mobile-broadband-provider-info` database is **wrong** here — it still lists
>   CDMA/EVDO-era credentials (`guest`/`guest`, `uninet`, `ctnet@mycdma.cn`). CDMA2000
>   shut down in Dec 2023. Do not copy them.

> ⚠️ Do NOT reuse an APN from a different carrier's SIM. This build shipped with APN
> `scuiot` — **a China *Unicom* (Sichuan) IoT APN**, not a China Mobile one as previously
> stated here — which is wrong for a China Telecom SIM.
>
> **IoT APNs never to use on a consumer SIM:** `cmiot` (Mobile), `cuiot` / `scuiot` /
> `unim2m.*` (Unicom, province-specific), `ctiot` (Telecom). Chinese IoT SIMs broadcast
> the **same MCC-MNC as consumer SIMs**, so an IMSI-prefix table structurally cannot tell
> them apart — it will confidently apply `cmnet`/`3gnet`/`ctnet` and the SIM will register
> but pass no traffic.
>
> **Prefer a blank APN over this table.** `AT+CGDCONT=1,"IPV4V6",""` requests the
> subscription default (TS 27.007 §10.1.1) and is self-correcting across every carrier,
> MVNO and travel eSIM. A *wrong* APN yields ESM cause #27 or attaches to the wrong PGW
> and silently black-holes traffic while still reporting `+CEREG: 0,1`. Use this table
> only as an optimisation after a blank attach, and never fall back to a guessed
> "common default" like `internet`.
>
> Full table (China + US + travel eSIM), **with per-row confidence**, lives in
> [`docs/apn-reference.md`](docs/apn-reference.md).

### Four findings that shape any implementation (2026-07-26)

1. **Set the ATTACH APN, not just CID 1.** On LTE/5G the APN governing attach is the
   **initial EPS bearer**, so `AT+CGDCONT=1,…` alone may not affect it. On Fibocom that is
   **`AT+EIAAPN`** — which is *also* the only way to supply PAP/CHAP, because **this modem
   has no `+CGAUTH`** (absent from the AT manual; QModem's mediatek branch has no auth block
   at all, unlike its qualcomm/lte/unisoc/huawei branches). Set both `EIAAPN` and
   `CGDCONT=1`, and confirm on hardware which actually takes effect.
2. **An eSIM profile does not carry an APN.** The GSMA/TCA SAIP profile ASN.1 has no
   `ef-apn`/PDP-context element; the only APN-related file is optional **`EF_ACL`**, a
   *restriction allow-list* (TS 31.102 §4.2.48) — not a default-APN source. Phones "just
   work" thanks to a device-side carrier database (Android `apns-conf.xml`, iOS carrier
   bundles) that a router does not have. Travel eSIMs work blank because they are
   home-routed and the **issuer's HSS** supplies the default.
3. **A single-family grant is SUCCESS — never re-dial on it.** Requesting `IPV4V6` and
   receiving IPv4-only or IPv6-only is an *accept* carrying ESM cause #50/#51/#52, not a
   reject (TS 24.301 §6.2.2). The documented real-world failure here is **host-side**:
   ModemManager treated "activated with NwError=50" as a failure, tore down a working bearer
   and retried, causing connect/disconnect churn. Do not build PDP-type retry logic.
4. **464XLAT is mandatory for T-Mobile US.** Their core is IPv6-only and the FM350's Intel
   XMM **does not run CLAT itself**, so without `464xlat` + `kmod-nat46` on the *router*,
   IPv4 silently fails and looks exactly like a wrong APN.

---

## 4. Recommended: configure QModem (persistent, survives reboot)

This is the clean way. It sets the APN on **context 1** and lets QModem dial at boot.

```
# ---- edit these two lines for your carrier ----
uci set qmodem.2_1.apn='ctnet'          # China Telecom. Use cmnet / 3gnet for other carriers
uci set qmodem.2_1.auth='none'          # ctnet needs no username/password on LTE

# ---- these are the critical fix + sane defaults (leave as-is) ----
uci set qmodem.2_1.pdp_index='1'        # ⭐ CRITICAL: use context 1 (the default bearer)
uci set qmodem.2_1.pdp_type='IPV4V6'
uci commit qmodem

# apply
/etc/init.d/qmodem_network restart
/etc/init.d/qmodem_network redial 2_1
```

Wait ~20 seconds, then verify (Section 6). The QModem section for this modem is named
`2_1` (it is `config modem-device '2_1'` in `/etc/config/qmodem`, path
`/sys/bus/usb/devices/2-1/`). If your section name differs, list it with:
`uci show qmodem | grep modem-device`.

**Watch the dial log** to confirm it is using context 1:
```
tail -20 /var/run/qmodem/2_1_dir/dial_log
```
You want to see:
```
dialing: ... apn:ctnet; command:AT+CGACT=1,1 pdp_index:1
dial_cmd: AT+CGACT=1,1; cgdcont_cmd: AT+CGDCONT=1,"IPV4V6","ctnet"
ip changed from , to ,10.x.y.z
```
`AT+CGACT=1,1` (context **1**) is correct. If you ever see `AT+CGACT=1,3`, the
`pdp_index` is wrong — set it back to `1`.

---

## 5. Manual bring-up (guaranteed method / for debugging)

Use this if QModem is misbehaving, or to prove the modem works independent of QModem.
This is the exact sequence that was verified working on this device.

**Step 5a — stop QModem from fighting you for the AT port** (see the AT-contention note
in Section 7 — this matters):
```
/etc/init.d/qmodem_monitor stop
/etc/init.d/qmodem_network stop
```

**Step 5b — put the internet APN on context 1 and (re)attach.** The detach/attach
(`CFUN=4` then `CFUN=1`) is required if context 1 was previously something else (e.g. IMS);
it forces the network to bring the default bearer up on the new APN.
```
P=/dev/ttyUSB1
tom_modem -d $P -c "AT+CMEE=2"                       -t 4   # verbose errors
tom_modem -d $P -c "AT+CFUN=4"                       -t 8   # radio detach
tom_modem -d $P -c 'AT+CGDCONT=1,"IPV4V6","ctnet"'   -t 5   # APN on context 1
tom_modem -d $P -c "AT+CFUN=1"                       -t 8   # radio re-attach
# wait until registered:
tom_modem -d $P -c "AT+CEREG?"                       -t 4   # repeat until +CEREG: 0,1 or 0,5
```

**Step 5c — activate context 1 and read its IP + DNS:**
```
tom_modem -d $P -c "AT+CGACT=1,1"   -t 8    # want: OK  (or "+CGEV: ME PDN ACT 1")
tom_modem -d $P -c "AT+CGPADDR=1"   -t 5    # -> +CGPADDR: 1,"10.x.y.z"   (this is YOUR IP)
tom_modem -d $P -c "AT+GTDNS=1"     -t 5    # -> the carrier DNS servers
```
> If `AT+CGACT=1,1` returns `+CME ERROR: 5847`, you skipped the `CFUN=4`/`CFUN=1` detach
> in step 5b (context 1 cannot be re-provisioned while attached). Redo step 5b.

**Step 5d — configure the `eth2` interface with the IP from `CGPADDR=1`.**
The modem gives NO gateway/netmask (cellular is point-to-point); the working convention is:
- IP = exactly the `CGPADDR=1` address (must match byte-for-byte, or the modem drops uplink)
- netmask = `/24` (255.255.255.0)
- gateway = same IP with last octet replaced by `.1` (e.g. IP `10.182.122.63` → gw `10.182.122.1`)

```
IP=10.182.122.63          # <-- replace with YOUR AT+CGPADDR=1 result
GW=${IP%.*}.1             # -> 10.182.122.1
ip addr flush dev eth2
ip link set eth2 up
ip addr add ${IP}/24 dev eth2
ip route replace default via $GW dev eth2 metric 5
```

**Step 5e — test (see Section 6).** This method was verified: `curl` returned HTTP 200.

---

## 6. Verify internet is working

```
# force the test through the modem interface (IPv4):
curl -s -4 --interface eth2 -m 15 -o /dev/null -w "HTTP %{http_code} via %{remote_ip}\n" https://www.baidu.com
# expect: HTTP 200 via <some public IP>

# DNS via the carrier resolver (use a DNS returned by AT+GTDNS=1):
nslookup www.baidu.com 202.101.172.37
```
- `HTTP 200` → **internet through the SIM works.** ✅
- `HTTP 000` → no data path. Re-check: is `eth2` IP byte-identical to `AT+CGPADDR=1`?
  Is context **1** the active/APN context (not 3)? See Section 7.

Interface / link sanity:
```
ip -4 addr show eth2                                    # should show your 10.x.y.z/24
grep '' /sys/class/net/eth2/statistics/{tx,rx}_packets  # BOTH should climb during a ping
tom_modem -d /dev/ttyUSB1 -c "AT+CGACT?" -t 4           # should show: +CGACT: 1,1
```
> Note: pinging the gateway (`10.x.y.1`) directly returns 100% loss — that is **normal**
> (the virtual gateway does not answer ICMP). What matters is that routing *through* it works
> (the `curl` test). Do not treat a failed gateway ping as a problem.

### Making the SIM the primary WAN (routing policy)
The router may also be connected upstream via Wi-Fi client (`phy0-sta0`) with a default route.
Linux prefers the default route with the **lowest metric**. To make the SIM primary, give
`eth2`'s default route a lower metric than the Wi-Fi one (or bring Wi-Fi client down).
In QModem-managed setups the interface is `network.USB` (metric `11`); lower it if needed:
```
uci set network.USB.metric='1'; uci commit network; /etc/init.d/network reload
```
Also ensure `eth2`/`USB` is in the `wan` firewall zone so LAN clients are NAT'd out to it.

---

## 7. Troubleshooting (common failure modes seen on THIS device)

### A. `eth2` transmits but receives nothing (tx rises, rx stuck; `NETDEV WATCHDOG`)
**Cause:** APN/activation is on the wrong PDP context (e.g. context 3). The FM350-GL RNDIS
data plane only bridges **context 1**. **Fix:** use context 1 everywhere
(`pdp_index=1`; `AT+CGDCONT=1,...`; `AT+CGACT=1,1`). This is the #1 issue — see the top box.

### B. AT commands hang / `at port response unexpected` / `tom_modem` piles up
**Cause:** AT-port contention. QModem's status pollers (`base_info`, `sim_info`) constantly
hit `/dev/ttyUSB3` via `tom_modem`, serialized by a semaphore. A single stuck command
(especially a long **`AT+COPS=?`** network scan, which can block for 2+ minutes) deadlocks
the whole queue, and the wedged processes may be un-killable (kernel `D` state) until reboot.
**Avoidance & fix:**
- **Never run `AT+COPS=?` casually** — it blocks the port for minutes. Avoid it.
- Do manual commands on **`/dev/ttyUSB1`** (separate from QModem's ttyUSB3).
- Before manual work, quiet QModem: `/etc/init.d/qmodem_monitor stop; /etc/init.d/qmodem_network stop`.
- Clear a jammed queue: `killall -9 tom_modem; tom_modem -C` (semaphore cleanup). If processes
  are stuck in `D` state and won't die, **reboot the router** — a fresh boot clears the wedged
  USB serial state, after which a correct config (Section 4) comes up cleanly.

### C. `+CSQ: 99,99` and `+CEREG: 0,2` (no signal / never registers)
**Cause:** radio problem, not config. Check: antennas physically connected (main + aux);
SIM actually has coverage for its carrier; you are not using a mismatched IoT SIM/band.
No amount of APN/context tweaking fixes a radio that has no signal.

### D. `AT+CGACT=1,1` → `+CME ERROR: 5847`
**Cause:** trying to (re)provision context 1 while the radio is attached. **Fix:** detach
first — `AT+CFUN=4`, then `AT+CGDCONT=1,...`, then `AT+CFUN=1`, wait for registration,
then `AT+CGACT=1,1` (Section 5b/5c).

### E. `AT+GTRNDIS` → `+CME ERROR: 100`
**Not a bug.** This firmware does not implement `GTRNDIS`; MediaTek FM350 uses `CGACT`.
Ignore it.

### F. QModem re-dials repeatedly and the IP keeps changing
**Cause:** the monitor thinks the link is down (usually because `ip_change` failed to read
`CGPADDR` under AT contention — see B) and re-dials, getting a new IP each time. Fix the
contention (B), then the IP stabilizes. Each re-attach can assign a new IP, so the `eth2`
address must always be re-synced to the current `AT+CGPADDR=1` value.

---

## 8. Quick diagnostic command reference

```
# --- identity / radio ---
tom_modem -d /dev/ttyUSB1 -c "ATI"        -t 4   # model / firmware revision
tom_modem -d /dev/ttyUSB1 -c "AT+CPIN?"   -t 4   # SIM status
tom_modem -d /dev/ttyUSB1 -c "AT+CIMI"    -t 4   # IMSI (carrier)
tom_modem -d /dev/ttyUSB1 -c "AT+CSQ"     -t 4   # signal quality
tom_modem -d /dev/ttyUSB1 -c "AT+CEREG?"  -t 4   # LTE registration
tom_modem -d /dev/ttyUSB1 -c "AT+COPS?"   -t 4   # serving operator

# --- data / contexts ---
tom_modem -d /dev/ttyUSB1 -c "AT+CGDCONT?"  -t 4  # defined contexts + APNs
tom_modem -d /dev/ttyUSB1 -c "AT+CGACT?"    -t 4  # which contexts are active
tom_modem -d /dev/ttyUSB1 -c "AT+CGPADDR=1" -t 5  # IP of context 1
tom_modem -d /dev/ttyUSB1 -c "AT+GTDNS=1"   -t 5  # DNS of context 1

# --- host side ---
ip -4 addr show eth2
ip route
dmesg | grep -iE "rndis|eth2|watchdog" | tail
tail -20 /var/run/qmodem/2_1_dir/dial_log
uci show qmodem | grep -E "apn|pdp_index|auth"

# --- USB mode (informational; do not change) ---
tom_modem -d /dev/ttyUSB1 -c "AT+GTUSBMODE?"  -t 4   # 41 = RNDIS (expected)
```

---

## 9. Sources / references

**Local documents (in `docs/`):**
- `docs/FM350-GL-AT-Commands.pdf` — Fibocom FM350 AT Commands manual (GTUSBMODE, CGACT,
  CGDCONT, GTDNS, GTUSBMODE 40/41 definitions).
- `docs/FM350-GL-Hardware-Guide.pdf` — Fibocom FM350-GL hardware guide (interfaces,
  RNDIS-over-USB vs MBIM-over-PCIe).

**Online (verified relevant):**
- QModem (the management package on this build): https://github.com/FUjr/QModem
  - Dial logic (`modem_dial.sh`, fibocom/mediatek branch, `ip_change_fm350`):
    https://github.com/FUjr/QModem/blob/main/application/qmodem/files/usr/share/qmodem/modem_dial.sh
  - **Issue #179** — root cause of the pdp_index=3 "works but unstable" bug and the
    switch to context 1 / pdp_index: https://github.com/FUjr/QModem/issues/179
- mrhaav's OpenWrt FM350-GL driver package (independent implementation, also uses **CID 1**):
  https://github.com/mrhaav/openwrt/tree/master/atc/fib-fm350_gl
- OpenWrt forum, "Fibocom FM350-GL support" (manual CID 1 recipe, RNDIS-over-USB notes):
  https://forum.openwrt.org/t/fibocom-fm350-gl-support/142682
- Fibocom FM350 AT Commands manual (public copy, GTUSBMODE 40/41 = RNDIS):
  https://www.minipc.de/support_db/support_files/Fibocom_FM350_AT%20Commands%20User%20Manual_V2.10.pdf
- BPI-R4 (MediaTek) FM350-GL write-up (RNDIS-over-USB, MBIM only on PCIe):
  https://blog.nyamoe.com/2024/10/using-the-fibocom-fm350-gl-5g-module-on-banana-pi-bpi-r4/

**Firmware/unlock note:** Do not attempt to reflash the modem to get MBIM/QMI over USB —
it does not exist for the FM350-GL (verified via the AT manual and community sources).
RNDIS (context 1) is the correct and only USB data path. Reflashing only risks bricking.

---

# 10. Clean-base stack (official mt76 OpenWrt) — NOT QModem

Everything above targets ImmortalWrt 24.10 + QModem. This section describes the stack this
project actually ships on the clean official base. **The modem facts carry over; the
tooling does not.** In particular `eth2`, `ttyUSB1` and `ttyUSB3` appear above as literal
names — on the clean base nothing may hard-code them, because they renumber.

## Packages

`kmod-usb-serial-option` + `kmod-usb-net-rndis` from the official feed (**not**
`kmod-usb-acm` — this modem has no CDC-ACM-class interface), plus `464xlat` + `kmod-nat46`
for IPv6-only carriers, and `coreutils-stty` because busybox has no `stty`. Custom glue:
`h5000m-modem-atd` (AT broker) and `h5000m-fm350` (netifd proto + dialer).

## Port layout (measured, firmware 81600.0000.00.29.21.24)

`option` binds the seven `ff/00/00` interfaces → `ttyUSB0..6`; `rndis_host` binds If#0/1 →
one RNDIS netdev. **Only interface 6 (`ttyUSB3` on this boot) answers AT** — the other six
are silent to commands and passively, with or without DTR. The vendor's claim that
`ttyUSB1` is also an AT port does not hold here.

Discovery therefore walks sysfs for `0e8d:7127`, probes candidates in the order
`6 3 7 8 9 4 2`, and publishes `/dev/modem-at0` / `/dev/modem-at1`. Locks are keyed on the
stable USB path (`2-1`) plus interface number, never on the tty name.

## Using it

```sh
modem-ports                 # show discovered ports and the data netdev
modem-ports --rescan        # re-probe (~1s; MODEM_DEEP_SCAN=1 probes all ports, ~26s)
atq 'AT+CSQ'                # one-shot AT on the leased port
at-lease lpac chip info     # hand the port to a foreign tool for its whole lifetime
```

`atq` refuses `AT+COPS=?` (measured: blocks the single AT port for **71 s**), and
`AT+CFUN=` / `AT+CGDCONT=1,` (dialer-owned state).

## Bring-up differences vs the QModem recipe

- The APN is programmed on **context 1** exactly as above — that constraint is real and
  unchanged — but the default is **blank**, not `ctnet`. Blank requests the subscription
  default and is self-correcting; the IMSI table is only consulted after blank has failed.
- `AT+EIAAPN` and `AT+CGAUTH` **do not exist on this firmware** (both return `+CME ERROR`),
  so there is no initial-EPS-bearer APN knob and `auth` can only ever be `none`.
- The interface is brought up by netifd via the custom `fm350` proto, giving the stable UCI
  name `cellular`. Address changes are re-published, never re-dialed, and `proto_set_keep`
  is never set — with it, netifd would leave the stale address attached and the uplink
  would die silently.
- **The modem keeps its APN in its own NVRAM across a router reflash.** A clean image does
  not imply a clean modem: context 1 still held the vendor's `ctnet` on our fresh base.
