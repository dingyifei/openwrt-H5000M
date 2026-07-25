# H5000M — hardware & OS behaviors (discovered 2026-07-25)

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
