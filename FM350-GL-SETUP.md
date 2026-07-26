# FM350-GL Cellular Modem — Setup & Troubleshooting Guide (H5000M / ImmortalWrt)

This guide explains how to get internet working through the **Fibocom FM350-GL 5G modem**
on the **Hiveton H5000M** router running **ImmortalWrt 24.10** (MediaTek filogic target),
using the **QModem** package that is preinstalled on this build.

It is written to be followed step by step, including by a small/less-capable agent.
**If you only read one thing, read the box below.**

---

> ⛔ **THE "ONE KEY FACT" BELOW IS CONTRADICTED BY UPSTREAM EVIDENCE — see §12.**
> QModem #179 shows an FM350-GL over RNDIS working on **cid 3**, and QModem's maintainer
> disowns the `pdp_index` theory entirely (it originated in a misdiagnosed Quectel EC200
> argument-order bug). On a China Telecom SIM, forcing the internet APN onto cid 1 fights
> the firmware, because cid 1 is auto-provisioned as IMS. Read §12 before following §4/§5.

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
⛔ **The explanation previously given here ("you skipped the CFUN=4/CFUN=1 detach") was
invented.** It has no source, and it is falsified by our own measurement: we performed the
detach cycle correctly and still got 5847. See §12 for what 5847 actually is and the
handling the one shipped implementation uses (**retry the same command**).

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

---

# 11. The cid-1 / IMS deadlock (measured 2026-07-26, working CT consumer SIM)

Tested on the clean OpenWrt base with a **working consumer China Telecom SIM**
(IMSI `46011…`), firmware `81600.0000.00.29.21.24`, `GTUSBMODE 41`.

**The modem is healthy and fully attached.** `+CPIN: READY`, `+CEREG: 0,1`,
`+CGATT: 1`, `+COPS: 0,2,"46011",11` (NR5G). None of what follows is a SIM,
signal or registration problem.

## What the network provisions on attach

| cid | APN | State |
|---|---|---|
| 1 | `IMS` | **active, IPv6-only** — `+CGCONTRDP: 1,,"IMS",…`, `+CGPADDR: 1,"0.0.0.0.0.0.0.0.24.197…"` |
| 2 | (defined `ctiot`) | inactive until activated; the network actually grants **`ctnet`** |

## The deadlock

- `AT+CGACT=1,1` while attached → **`+CME ERROR: 5847`**. Context 1 cannot be
  re-activated because the network already holds it for IMS.
- `AT+CGACT=1,2` → **succeeds**: `+CGEV: ME PDN ACT 2`, `+CGACT: 2,1`.
  `AT+CGPADDR=2` → `10.87.138.159` (real IPv4 + IPv6);
  `AT+CGCONTRDP=2` → APN **`ctnet`**, DNS `222.66.251.8` / `116.236.159.8`.
  So a perfectly good data bearer is available — on cid 2.
- But configuring `eth2` with that address and routing through it gives
  **tx=3, rx=0** — the documented black-hole signature. `eth2` has `carrier=1`,
  so the link is up; the modem simply does not forward cid 2 over RNDIS.

**This confirms the cid-1 constraint rather than refuting it.** RNDIS is bound to
context 1 only. The problem is that on this network context 1 is taken by IMS, so
the one context RNDIS will forward is the one we cannot have.

## Why the usual escape hatch does not work here

The vendor recipe is `CFUN=4` → `CGDCONT=1,"IPV4V6","<apn>"` → `CFUN=1`, which
re-attaches with the new cid-1 definition. On this firmware that still ends with
IMS on cid 1 and `CGACT=1,1` failing. And the documented alternative for setting
the **initial/attach** APN, `AT+EIAAPN`, **does not exist on this firmware**
(`+CME ERROR`), as does `AT+GTRNDIS` (`+CME ERROR: unknown`), so there is no
supported way to rebind RNDIS to another cid.

> ⚠️ Timing matters when re-provisioning: `AT+CEREG?` keeps reporting the
> pre-detach state for several seconds after `AT+CFUN=4`. Writing `CGDCONT`
> before the detach lands reproduces `+CME ERROR: 5847`, and a registration wait
> started too early returns instantly on a stale "registered". Wait for `CEREG`
> to leave the registered state before reprovisioning.

## What the AT manual actually says — two of our conclusions were WRONG

Read out of `docs/FM350-GL-AT-Commands.pdf` (V2.2), not inferred:

### `+EIAAPN` takes SEVEN parameters (§12.2.14, p158)

```
AT+EIAAPN=<APN_Name>,<APN_Index>,<PDP_type>,<Roaming_PDP_type>,<auth_type>,<username>,<password>
```
`<APN_Index>`: "No use, specify it as 0". `<auth_type>`: **0 None, 1 PAP, 2 CHAP**.

We called it as `AT+EIAAPN="ctnet","IPV4V6"` — two arguments — got `+CME ERROR`, and
concluded the command does not exist. **That conclusion was wrong**: we called it with the
wrong arity. The manual also defines no read (`?`) or test (`=?`) form, so those returning
errors proves nothing either. **Two downstream claims must be re-tested:**
- that this firmware has no initial-attach-APN knob;
- that PAP/CHAP is impossible because `+CGAUTH` is absent — `EIAAPN` carries `auth_type`,
  `username` and `password` itself.

### `+EAPNACT` activates by APN NAME AND TYPE, not by cid (§12.2.16, p159)

```
AT+EAPNACT=<state>,<parameter>        state 1 = activate -> <apn_name>,<apn_type>
                                      state 0 = deactivate -> <aid>
```
`<apn_type>` is an enum of *purposes*:
`unknow / default / ims / mms / supl / dun / hipri / fota / cbs / emergency / ia / dm /
wap / net / cmmail / tethering / rcse / xcap / rcs`

This reframes the whole problem. The modem organises bearers by **purpose**, not by cid
number — cid 1 holding `IMS` is not an accident of numbering, it is simply the `ims`-type
context. So "RNDIS forwards cid 1 only" is probably the wrong mental model; what likely
matters is the APN *type* bound to the RNDIS data path.

**Measured:** `AT+EAPNACT=1,"ctnet","default"` → `+CGEV: ME PDN ACT 3,2`, and
`+CGACT: 3,1` — a `default`-type `ctnet` context activates cleanly on cid 3, with no
`CFUN` cycle and no 5847. But `eth2` still shows `rx=0`, so RNDIS is still not carrying it.

## Still open

Which context the RNDIS data path is actually bound to, and how to bind it. Candidates not
yet read out of the manual: `+CEMODE` (UE modes of operation for EPS, §11.1.9 p119),
`+E5GOPT` (5G option, §12.2.15), `+CGDATA` (§12.2.8), `+CGCMOD` (§12.2.7), and the CME
error table (§20.2 p231) for the real meaning of **5847**. Also untested: whether
`apn_type` `net` or `tethering` — rather than `default` — is what RNDIS forwards.

**Do not guess AT commands here.** Every wrong turn so far came from inferring a command's
behaviour instead of reading its definition; the manual has been right each time.


---

# 12. Upstream evidence review (2026-07-26) — corrections to this document

Sourced from the Fibocom manual, MediaTek RIL source, and shipped OpenWrt packages.
Several claims elsewhere in this file are **wrong**; they are corrected here.

## `+CME ERROR: 5847` is not a network reject, and not a detach problem

- **Not documented by Fibocom.** The CME table (§20.2, both V2.2 and public V2.10) ends at
  `1283`. No 4-digit vendor codes exist in either manual.
- **Not a 3GPP cause.** MediaTek's RIL decodes data-call errors by base offset
  (`RmcDataDefs.h`): SM `0xC00`, ESM `0xD00`, PAM `0x1200`, CME `0x64`. `5847 = 0x16D7`
  falls outside every range, so it is a **MediaTek-internal local cause**, which MTK's own
  RIL maps to `PDP_FAIL_ERROR_UNSPECIFIED`. The neighbouring named constant
  `0x1671 (5745) = PDP_FAIL_DATA_NOT_ALLOW` suggests this block is MTK's local
  policy/state refusal family.
- **The one shipped implementation simply retries.** mrhaav's `atc-fib-fm350_gl`
  (`/lib/netifd/proto/atc.sh`): on `+CME ERROR` with value `5847`, re-send `AT+CGACT=1,1`.
- **Never run:** `AT+CEER` (§20.1.2) is the vendor-sanctioned decoder and returns a textual
  category such as "SM activation error". `AT+CLAC` (§3.14) enumerates what this firmware
  actually implements. **Both are documented and both should be the next diagnostics.**

## cid 1 is IMS *by design* on China Telecom — stop fighting it

QModem **#169** is the same modem, same carrier, same symptom:
```
+CGDCONT: 1,"IPV4V6","IMS", …,1,1,,0,1,0     <- IM_CN_Signalling_Flag_Ind = 1
+CGDCONT: 2,"IPV4V6","CTNET", …
CGPADDR=1 -> IPv6 only          CGPADDR=2 -> 10.x + IPv6
```
That trailing flag is `IM_CN_Signalling_Flag_Ind` (§12.2.1): **"this context is for IM CN
subsystem signalling only"**. cid 1 is auto-created, already active, and flagged not to
carry user traffic. Our device matches exactly — `CGCONTRDP=1` reports `IMS`, `CGPADDR=1`
is IPv6-only, and `CGCONTRDP=2` grants `ctnet` with a real IPv4.

**So the internet bearer is cid 2, not cid 1.** QModem #179 further shows RNDIS working on
**cid 3**, and QModem's maintainer states `pdp_index` "should not be set at all" — the knob
came from a misdiagnosed Quectel EC200 argument-order bug. QModem's own default for
fibocom/mediatek is 3.

## What the working implementations actually do

mrhaav's shipped sequence differs from ours in four ways:
1. `AT+CGACT` is issued only after **`AT+COPS?` confirms registration**, not merely on
   `+CEREG: 0,1`.
2. Success is **`+CGEV: ME PDN ACT <cid>`**, not `OK`.
3. The AT port is **held open** and commands are fire-and-forget.
4. `+CME ERROR: 5847` → **retry**.

`AT+EIAAPN` is used with its full 7-argument form, before `CFUN=1`.

⚠️ **`AT+CGACT` may return no terminal response at all** on this modem (GL.iNet
`gl-modem-community` PR #8: the stock AT broker blocks ~160 s; their fix synthesises an
`OK`). A one-shot AT call with a short timeout cannot survive that — our `atq`-style
transaction model is exposed here.

## Host-side gap: the RNDIS netdev is mis-flagged

OpenWrt PR **#24196** (open) adds explicit `rndis_host` IDs for `0e8d:7126`/`0e8d:7127`
with `FLAG_WWAN | FLAG_POINTTOPOINT | FLAG_NOARP`, because the generic RNDIS matcher
rejects the FM350 (it reports physical medium `WIRELESS_LAN`). On stock kernel 6.18.39 we
fall through to the **generic** profile — ARP on, not point-to-point. koshev's `xmm.sh`
compensates with `ip link set dev <if> arp off`.

**Measured on our device:** setting `arp off` (flags `0x1083`, NOARP confirmed) and routing
cid 2's address over `eth2` still gives **tx=14 / rx=0**. So the missing flags are a real
gap but **not sufficient on their own**.

## Corrected: `+EAPNACT` is MediaTek's primary activation path

MTK RIL (`RmcDcCommonReqHandler.cpp`) uses `AT+EAPNACT=1,"<apn>","<type>"` as its
**primary** activation, waiting for `+CGEV: ME PDN ACT <aid>` — **the modem chooses the
aid**, the host does not. Deactivate is `AT+EAPNACT=0,<aid>`.
Measured here: `AT+EAPNACT=1,"ctnet","default"` → `+CGEV: ME PDN ACT 3,2`, cid 3 active,
no `CFUN` cycle and no 5847. Still no RNDIS traffic.

## Still unknown

**How the single RNDIS netdev is bound to a context.** There is no binding command in
either manual. MTK's stack uses `AT+EPDN=<aid>,"ifst",…` (verified in RIL source) but
`+EPDN` is undocumented for FM350 and untested. `AT+CLAC` would reveal whether it exists.

## Also corrected

`+EDSBP` / `+ESIMS` are **not** data-bearer commands. `+EDSBP` is MediaTek's *Dynamic SBP
(carrier configuration) change* indication and `+ESIMS` is a SIM URC — they mean the modem
is swapping carrier config after seeing the SIM, which is a reason to **wait before
dialling**, not evidence of hidden bearer commands.

`AT+CNMP` does **not** exist on this modem (it is a Quectel command). The FM350 equivalents
are `AT+GTACT` (§11.1.14) and `AT+E5GOPT` (§12.2.15).

## Diagnostics run 2026-07-26 (results)

**`AT+CEER` returns `+CEER: 0,NONE` immediately after a fresh `+CME ERROR: 5847`.**
There is no network cause because the network was never asked: the modem refuses the
activation **locally**. This corroborates the reading of 5847 as a MediaTek local
policy/state refusal, and it is further reason to stop trying to force cid 1 — the refusal
is the firmware protecting its IMS context, not a negotiation we can win with better
timing or a different APN.

**`AT+CLAC` is NOT exhaustive on this firmware — do not use it to prove absence.**
It lists only 37 commands, essentially the network/registration group. `+CGACT`,
`+CGDCONT` and `+EAPNACT` are all absent from that list and all demonstrably work.

> ⚠️ **Read/test forms erroring proves nothing on this firmware.** `AT+EAPNACT=?` returns
> `+CME ERROR: unknown`, yet `AT+EAPNACT=1,"ctnet","default"` works. This is the same trap
> that produced the earlier false conclusion about `AT+EIAAPN`. Therefore the `+CME ERROR`
> from `AT+EPDN?`, `AT+EAPNSET?` and `AT+ECNCFG?` does **not** establish that those
> commands are missing — only a correctly-formed set command would, and guessing one blind
> is how this modem gets wedged.

**State at the end of the session:** two bearers active and healthy —
`+CGACT: 2,1` (`ctnet`, IPv4 `10.87.138.159` + IPv6) and `+CGACT: 3,1`
(`ctnet`, `default` type, created by `EAPNACT`) — with `eth2` carrying **tx only, rx 0**,
`arp off` applied. The bearer exists; RNDIS is not attached to it.

**Next diagnostics, in order:** (1) capture what a *working* implementation does, by running
mrhaav's `atc-fib-fm350_gl` sequence verbatim with the AT port held open, since our one-shot
transaction model may simply be missing the `+CGEV: ME PDN ACT` that signals success;
(2) only then consider `+EPDN`, and only with a set form read out of MTK RIL source rather
than guessed.

---

# 13. ⭐ SOLVED: the data path works with EXACTLY ONE active context

Measured 2026-07-26 on the clean base, working China Telecom SIM.

```
AT+EAPNACT=0,<aid>   … for every currently-active aid   <- deactivate ALL first
AT+EAPNACT=1,"ctnet","default"        -> +CGEV: ME PDN ACT 3,2
AT+CGPADDR=3                          -> 10.141.14.81
ip link set eth2 arp off up
ip addr add 10.141.14.81/24 dev eth2
ip route replace default via 10.141.14.1 dev eth2
```
Result: **ping 4/4, RTT 31–86 ms**, and DNS resolves through the carrier resolver
(`nslookup www.baidu.com 222.66.251.8` returns records). `rx_packets` climbs.

## What actually mattered

**Exactly one PDP context may be active.** Every earlier failure had two or more live
(cid 2 from a manual `CGACT`, cid 3 from `EAPNACT`), and RNDIS forwarded none of them —
tx climbed, rx stayed 0. Deactivating everything and activating exactly one made the same
address and the same route start working. This — not the cid *number* — is the real
constraint, which is why "use cid 1" appeared to work for some people and not others.

**Use `+EAPNACT`, not `+CGACT`.** It activates by APN name and type, the modem picks the
aid, and it never returns 5847. `AT+CGACT=1,1` cannot succeed on China Telecom because
cid 1 is the IMS context (see §12).

**`arp off` is required** — the generic `rndis_host` profile lacks `NOARP` for this device
(OpenWrt PR #24196). Necessary but not sufficient on its own.

**Parsing trap:** `AT+CGPADDR` returns the IPv6 address as **sixteen** dotted octets, which
a naive `[0-9.]+` regex happily matches as if it were IPv4. Select the value with exactly
four octets.

## Consequences for h5000m-fm350

The dialer must be rewritten around this: deactivate all aids, `EAPNACT` exactly one,
parse the aid out of `+CGEV: ME PDN ACT <aid>,<n>`, read `CGPADDR=<aid>` (four-octet
field), set `arp off`, then publish. `pdp_index` becomes meaningless and should go.
