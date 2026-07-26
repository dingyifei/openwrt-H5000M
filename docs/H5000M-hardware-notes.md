# H5000M — hardware & OS behaviors (discovered 2026-07-25)

## ⚠️ Rolling-model rule: kmods are kernel-ABI-locked

Under the rolling model the feeds move with the mirror, so **kmods only load on an image
built from the same snapshot**. Always record the tuple from `BUILD-INFO.txt` after a build
and install kmods only from that snapshot:

| field | value (2026-07-26 flash) |
|---|---|
| revision | `r35533-3b2bc55dcb` |
| kernel | `6.18.39` |
| kernel ABI | `38ca7baf52c71e940d7f3ce0e127bcc9` |
| arch | `aarch64_cortex-a53` |

This is why the FM350 work needed a reflash first: the device was on r35420 / 6.18.38
(ABI `45144f66…`), and r35420 kmods no longer exist (snapshots aren't archived).

**Confirmed on the 2026-07-26 sysupgrade:** the Wi-Fi eeprom fix lives in the `factory`
partition (`mmcblk0p2`), which **sysupgrade does not touch** — after flashing, `eeprom load
fail` was still absent and the in-memory eeprom still began
`92 79 00 00 02 73 d9 be 07 c7`. Only the overlay resets. Interface MACs stayed `6a:…`
because sysupgrade preserved `/etc/config/network`.

## Wi-Fi / forwarding tuning (applied 2026-07-26)

Set in `official-base-files/etc/uci-defaults/90-h5000m-base`, each with a matching
assertion in `build-official-base-local.sh`.

| Knob | Value | Measured result |
|---|---|---|
| `country` | `AU` (was `CN`) | **Disabled 5 GHz channels 16 → 7** — unlocks the DFS band **ch 100–144** that CN blocks. Verified twice: live `iw reg set` A/B before the change, and post-flash. ⚠️ Raises the regulatory *ceiling* only — TX power on this unit is a confirmed no-op, so this buys **channel choice, not output power**. |
| `tx_burst` | `2.0` | Real mac80211 option → hostapd `tx_queue_data2_burst`. Independent of calibration. |
| `packet_steering` | **`2`** | `2` = steer to **all** CPUs. Measured: with `1`, each interface got a *single* core (`eth0` rps_cpus=4, wifi=2) and all 12 mt76 NAPI threads were pinned to CPU3; with `2` every interface reports `rps_cpus=f` (all 4 cores). |
| `flow_offloading` / `_hw` | `1` / `1` | **Active** — `nft list table inet fw4` shows `flowtable ft { flags offload`. The in-tree PPE equivalent of the vendor's MediaTek HNAT/WED (which the official mt76 base cannot reproduce). |

⚠️ **Offloaded flows bypass netfilter**, which can defeat fwmark-based policy routing.
**Re-validate when mwan3 lands**; if failover misroutes established connections, set both
flow-offload flags back to `0` — correct failover is worth more than throughput.

### mt76 multi-core: threaded NAPI is on; WED is NOT available (tested 2026-07-26)

| Item | State |
|---|---|
| **mt76 threaded NAPI** | ✅ **On by default** — `/sys/kernel/debug/ieee80211/phy0/mt76/napi_threaded` = `1`, 12 NAPI kernel threads (`[napi/phy0-0]`, `[napi/mtk_eth-0]`). Nothing to enable. |
| **Core spreading** | ✅ Fixed by `packet_steering=2` (see above). |
| **WED (Wireless Ethernet Dispatch)** | ⛔ **Not achievable on the official base.** |

**WED — tested and rejected, don't re-investigate.** The hardware is present (DT node
`wed@15010000`, compatible `mediatek,mt7987-wed`) and the driver knob exists
(`/sys/module/mt7996e/parameters/wed_enable`, default `N`). Setting
`mt7996e wed_enable=1` in `/etc/modules.d/mt7996e` and rebooting **does** take effect, and
mt7996e **does** attempt the attach — but it fails:

```
mt7996e 0000:01:00.0: attaching wed device 0 version 3
platform 15010000.wed: failed to attach wed device
```

Root cause: **no WED platform driver is registered at all.** WED lives in
`CONFIG_NET_MEDIATEK_SOC_WED`, part of `mtk_eth_soc`, which is **built into the kernel**
(absent from `/proc/modules`) — and it is not compiled into the official filogic build.
There is also **no WED kmod in the feed**. So it cannot be added by ImageBuilder or by any
plugin package; it would require building OpenWrt from source with a custom kernel config,
abandoning the official-base architecture. Reverted; Wi-Fi was unaffected either way.

> ⚠️ **"The stock firmware had WED" is not evidence this works.** Stock ran MediaTek's
> closed `mt_wifi7` driver with `kmod-mtk_wed` — an entirely different code path from
> upstream `mt7996e`. Hardware support ≠ upstream driver support.

**Consequence:** Wi-Fi traffic gets **no hardware offload**. The nftables flowtable covers
only `{eth0, eth1}`, so ethernet↔ethernet forwarding is PPE-accelerated while Wi-Fi↔WAN
forwarding is handled in software. On a travel router that is most of the traffic.

**To re-test cheaply after a future snapshot** (rolling means kernels change): put
`mt7996e wed_enable=1` in `/etc/modules.d/mt7996e`, reboot, then
`dmesg | grep -i wed`. If "failed to attach" is gone, the kernel gained WED support.

> Throughput before/after was **not** measured: the base ships no `iperf3`, and the
> forwarding path can't be exercised meaningfully with `eth1` unplugged and no cellular
> uplink yet. Defer the benchmark to after Stage 2 (cellular or WAN present).

## eSIM: lpac AT backend is available

`utils/lpac/Config.in` upstream sets **`LPAC_WITH_AT` `default y`**, so the in-feed `lpac`
(2.3.0-r2) ships the AT backend — **no source build needed** for eSIM. All four backends
default `y`, so installing it also pulls `libpcsclite`/`pcscd`/`libmbim`/`uqmi` as deps;
that is harmless but is **not** a usable MBIM/QMI data path on this modem (see below).

Live investigation on the physical H5000M running our official base
(root SSH @ 192.168.10.1). Companion to `ROADMAP.md` (Phase 0.4) and the plan file
`~/.claude/plans/given-phase-0-4-is-ancient-fiddle.md`.

## Device identity
- OpenWrt **SNAPSHOT r35420-06c826e335**, target `mediatek/filogic`, board
  `hiveton,h5000m`, kernel **6.18.38**, aarch64, pkg manager **apk**, 236 base pkgs.
- SoC **MT7987**; Wi-Fi **MT7992** (WiFi-7, driver `mt7996e`); 2.5GbE PHY MT7987.

## Storage / partitions (eMMC `mmcblk0`, GPT, no MTD)
| part | name | size | notes |
|------|------|------|-------|
| p1 | u-boot-env | 512 KB | no `ethaddr`/`macaddr` set |
| p2 | **factory** | 2 MB | **all-zero as shipped** (Wi-Fi eeprom/cal + MAC region) |
| p3 | fip | 1 MB | ATF FIP (BL2/BL31/u-boot), MT7987 |
| p4 | kernel | 16 MB | |
| p5 | rootfs | ~7.4 GB | squashfs + f2fs overlay |
- `/overlay` f2fs ≈ **7.2 GB, ~7 GB free** → flash budget is NOT a constraint.

## Network
- `eth1` = **WAN** (`network.wan`, dhcp/dhcpv6; NO-CARRIER when unplugged).
- `eth0` → `br-lan` = LAN @ 192.168.10.1.
- board.d `hiveton,h5000m` sets interfaces only; **no MAC logic**.

## Wi-Fi calibration (RISK-1) — the big one
- `mt7996e … eeprom load fail, use default bin`: the driver's DT wiring is **correct** —
  `mt7992@0,0` (`mediatek,mt76`) → `nvmem-cell-names="eeprom"` → factory `eeprom@0`
  (offset 0x0, size **0x1e00** = 7680 B). But the `factory` partition is **all-zero**, so
  the driver falls back to a generic default bin.
- **The device was never per-unit RF-calibrated — we did NOT erase it.** Proof:
  - Stock firmware `HiGoROS-H5000M-…bin` is a plain OpenWrt **sysupgrade tar**
    (`CONTROL`+`kernel`+`root`, no factory image); sysupgrade never writes `factory`.
  - The stock kernel's DT has the **same** factory-nvmem wiring and **no inline
    `mediatek,eeprom-data`** → stock ran default-bin too.
  - Stock u-boot (`fip.bin`) contains **no MAC**; `u-boot-env` has no `ethaddr`.
  This is a custom/small-batch unit shipped without eMMC calibration or an assigned MAC.
- **EEPROM layout** (from the in-mem dump `/sys/kernel/debug/ieee80211/phy0/mt76/eeprom`,
  7680 B): chip id `92 79` (=0x7992) @0x0; **MAC band0 @0x04, band1 @0x0a**; default
  placeholder MAC `00:0c:43:26:60:10/11` (a shared MediaTek sample → OpenWrt rejects it).
- **Variant = `mt7992_eeprom_23_2i5i.bin`** (internal-PA): in-mem eeprom differs from the
  `2i5i` bin by only **11 bytes** (runtime adie/MAC patches) vs **1707** for the plain bin.
- Under default-bin the driver advertises **TX/RX antennas 0x1f (5 chains)** — the raw
  chip max, not the board's real layout (a valid eeprom would constrain it).

### What we changed (approach-A, reversible)
- Backed up the blank `factory` (all-zero) → `scratchpad/factory-blank-backup.bin`.
- Wrote a valid **2i5i eeprom + deterministic locally-administered MAC**
  `02:73:d9:be:07:c7` (band0) / `…c8` (band1), derived from the eMMC CID serial
  `0x73d9be07`, to `mmcblk0p2` @0x0 (7680 B). Saved as
  `scratchpad/factory_new-eeprom-2i5i-mac02.bin`.
- After reboot (boot_id changed): **`eeprom load fail` is GONE** — the driver now loads
  our factory blob (in-mem head = `92 79 00 00 02 73 d9 be 07 c7 …`). Wi-Fi still up on
  both bands. RF behavior unchanged (same 2i5i data), calibration now genuinely provisioned.
- To revert: `dd if=factory-blank-backup.bin of=/dev/mmcblk0p2` (write first 7680 B / whole).

## MAC address behavior (correction of an earlier assumption)
- Interface MACs are **stable across reboots** — `eth0=6a:35:a7:4a:cb:80` identical before
  and after a real reboot. They are **persisted in `/overlay/upper/etc/config/network`**
  (`network.@device[1].macaddr`), assigned once at first boot. **Not random-per-boot.**
- They ARE locally-administered/arbitrary (`6a:…`), not a vendor OUI.
- **mt76 does NOT use the eeprom MAC**: phy0 perm addr = `6a:35:a7:4a:cb:82` (eth0-base +
  offset). OpenWrt derives the Wi-Fi MAC from the ethernet base MAC, overriding the eeprom.
- The **ethernet** `mac@0/1/2` DT nodes have **empty `nvmem-cell-names`** → eth cannot read
  a MAC from `factory`; that's why the SoC eth MAC is generated (`mtk_soc_eth … generated
  random MAC 20:08:02:00:00:00` fallback, then the persisted `6a:…` applies).
- Net: to make interfaces use a chosen deterministic MAC you must set UCI
  `network.@device[N].macaddr` (or add eth nvmem-cell DT wiring in a custom image); the
  eeprom MAC alone is not honored for the interfaces.

## TX-power vs measured RSSI (rough calibration) — CONFIRMED: txpower knob is a no-op
Measured from a MacBook Pro via `scripts/rf-signal-sweep.sh`, 5 GHz ch36, `assoc` mode,
router TXpower swept 3→23 dBm.

| distance | baseline RSSI | RSSI across 3→23 dBm sweep | verdict |
|----------|---------------|---------------------------|---------|
| ~0.3 m (near-field) | ~−29 dBm | flat −28…−31 | inconclusive (AGC may saturate ≳−28) |
| through a wall (~5–10 m) | **~−48 dBm (Mac) / −57 (router)** | **flat −47…−51, no trend** | **conclusive** |

- At −48 dBm the receiver is well within its **linear** range (not saturated), yet a full
  **20 dB** change in the router's requested TXpower produced **zero change** in downlink
  RSSI. Data rate randomly bounced HE-MCS 10/11 with **no correlation** to the setting.
- **Conclusion:** `iw … set txpower fixed` has **no effect on radiated power** on this unit
  — it is a genuine no-op. Root cause = missing calibration (RISK-1): with no valid
  TSSI/power tables in the eeprom, mt76's power-control loop has no reference, so output is
  pinned at the generic default-bin level (matches community reports of broken txpower on
  uncalibrated MT7996-family boards).
- **Implication:** empirical TXpower tuning (plan approach-B) via the standard interface is
  **impossible** on this unit as-is. The only real fix is a genuinely **calibrated eeprom**
  (vendor golden blob, or lab cal — true DIY cal infeasible: needs MediaTek ATE + RF lab).
  A risky last resort would be editing the eeprom power-table bytes directly and measuring,
  but without the table format/TSSI reference that's guesswork (regulatory/PA risk). Upside:
  the radio already emits a usable signal at the fixed default level.

## FM350-GL modem (RISK-2)
- USB `0e8d:7127`, 10-iface CDC-ACM + CDC-data (RNDIS/ECM + AT) composite, config 1
  (~GTUSBMODE 41). On the clean base **no modem kmod is bound → zero `/dev` nodes**.
- Good news (WS-C, `artifacts/phase2-package-availability.md`): the **entire modem driver
  stack is in the official r35420 feeds** (kmod-usb-serial-option, cdc-ether/rndis/cdc-mbim/
  qmi-wwan/cdc-ncm, umbim, uqmi, comgt, modemmanager, luci-proto qmi/mbim/ncm) — nothing
  modem-side needs a source build. Drift: r35420 `kmod-usb-net-rndis` was renamed
  `kmod-usb-net-rndis-host` in the rolled snapshot.

### FM350 on the clean base — measured 2026-07-26 (Stage 2.3)

Kmods installed from the official kmods feed for ABI `38ca7baf…`; everything below was
read off the running device, not inferred.

**USB composition (`0e8d:7127`, GTUSBMODE 41).** Ten interfaces:

| If# | Class/Sub/Proto | Bound by | Result |
|---|---|---|---|
| 0 | `02/02/ff` | `rndis_host` | RNDIS control |
| 1 | `0a/00/00` | `rndis_host` | RNDIS data → **`eth2`** |
| 5 | `ff/42/01` | (none) | ADB — never an AT candidate |
| 2,3,4,6,7,8,9 | `ff/00/00` | `option` | **`ttyUSB0..6`** |

`option` claims it explicitly — Linux 6.18 `option.c`:
`USB_DEVICE_AND_INTERFACE_INFO(0x0e8d, 0x7127, 0xff, 0x00, 0x00)` with
`.driver_info = NCTRL(2)|NCTRL(3)|NCTRL(4)`. **No `new_id` hack is needed**, and there is
**no CDC-ACM-class interface at all**, so `kmod-usb-acm` was dropped from the package set.

> ⭐ **Only ONE AT port exists.** Contrary to the vendor docs (which list `ttyUSB1` *and*
> `ttyUSB3`), only **interface 6 = `/dev/ttyUSB3`** answers AT. The other six are silent
> to `AT`/`ATI` and emit nothing passively, with or without DTR asserted. This **kills the
> planned two-tier broker** (one port owned by the dialer, one leased to everyone else).
> The shipped design is instead a single port with strict per-transaction locking: the
> dialer is a peer, not an owner. Consequence: URCs arriving while another consumer holds
> the port are missed, so dialer state is **poll-authoritative** and URCs are an
> optimisation only. Re-check with `MODEM_DEEP_SCAN=1 modem-ports --rescan` on new firmware.

**Writing to a dead serial port blocks `close()` for ~30 s**, and `SIGTERM` does *not*
interrupt it — `timeout(1)` cannot rescue you. Open and read are instant; the entire cost
is in close. A naive probe sweep of all seven ports therefore took **55 s**. The fix is to
stop at the first working port (the interface-6 prior is correct) and to run probes
detached, judging them by whether output appeared rather than by process exit. Discovery
is now **~1 s**; an explicit deep scan is ~26 s.

**busybox `flock` has no `-w`** (only `-s -x -u -n`). Using `-w` silently turns every
acquisition into a usage error that reads as "AT port busy". Bounded waits must be built
from `-n` plus a retry loop.

**Firmware `81600.0000.00.29.21.24` command support** — verified, not assumed:

| Command | Result | Consequence |
|---|---|---|
| `AT+EIAAPN` | `+CME ERROR` | **No separate initial-EPS-bearer APN knob.** `AT+CGDCONT=1` is the only APN lever here, settling the open C17 question for this unit. |
| `AT+CGAUTH` | `+CME ERROR` | Confirms C13 on hardware: PAP/CHAP is not expressible; `auth` must be `none`. |
| `AT+GTDNS=?` | `OK` | Supported, but `AT+CGCONTRDP` is still preferred (standard, and returns APN + mask + gateway + both DNS at once). |
| `AT+COPS=?` | `OK`, **71 s** | Justifies the denylist — it blocks the single AT port for over a minute. |

**The modem keeps its own APN in NVRAM across a router reflash.** PDP context 1 still held
the vendor's `ctnet` even on our clean base. Do not assume a fresh image means a fresh
modem.

> ⛔ **The SIM currently fitted is refused by the network** (IMSI `46008…`, China Mobile).
> `AT+CPIN: READY`, `AT+CSQ: 11` (≈ −91 dBm), and `AT+COPS=?` lists China Mobile/Telecom/
> Broadnet as *available* — yet attach fails with **`+CEREG: 0,3` (registration denied)**,
> both automatically and when forced with `AT+COPS=1,2,"46000"`. Blank-APN programming
> itself works exactly as designed (`+CGDCONT: 1,"IPV4V6",""` accepted). This is a
> **subscription problem, not a firmware or code problem** — the e2e attach gate needs a
> different SIM.

**netifd loads new protocol handlers only on `restart`, not `reload`.** After dropping in
`/lib/netifd/proto/fm350.sh`, `ubus call network.interface.cellular status` reported
`"proto": "none"` until a full `/etc/init.d/network restart`. Harmless at first boot
(uci-defaults run before netifd), but it must be done by hand after a runtime install.

**Do not use `set -u` in a netifd proto command.** OpenWrt's own `/lib/functions.sh`
dereferences `$IPKG_INSTROOT` while unset, so the script dies the instant it is sourced —
and because netifd respawns a proto command that exits, the result is an immediate restart
storm (measured: dozens of respawns per second).

## macOS Wi-Fi measurement tooling notes
- Legacy `airport` tool is **removed** (recent macOS). `wdutil info` needs sudo.
- `system_profiler SPAirPortDataType` gives associated **Signal/Noise (RSSI)** without sudo.
- CoreWLAN `scanForNetworks(withName:)` via `swift` returns per-BSSID RSSI **without
  associating** — but macOS **caches/throttles scans** (~tens of seconds), so space samples.
- **Background Bash jobs run in a sandbox with no LAN access** — reboot/SSH/scan must run
  in the foreground; use ping-pacing (`ping -c N -i 1 127.0.0.1`) instead of `sleep` there.

## SDK / Phase 1 (WS-B)
- The r35420 SDK is **unrecoverable** (OpenWrt doesn't archive snapshots; mirror rolled to
  r35532-66d356edea). No SDK is pinned in the repo yet. → re-pin ImageBuilder+SDK+feeds to
  the current snapshot in one capture and **preserve the SDK tarball**; fix the hardcoded
  "236 packages" assertion in `scripts/manage-feed-lock.sh` if the closure changes.
