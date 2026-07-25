# H5000M Feature Stack — Roadmap

Multi-session progress tracker for retargeting the portable feature stack onto the
official OpenWrt mt76 base.

**Sources of truth**
- Plan: `~/.claude/plans/plan-following-auto-h5000m-bin-handover-binary-jellyfish.md`
- Handoff: `../Auto-H5000M-BIN/handover-openwrt.md`

**Architecture:** keep this repo as the clean official ImageBuilder base
(`custom_plugins_included=false`); deliver features as separately built, signed
APK plugins from a sibling `openwrt-H5000M-plugins` repo. Do not port vendor
`mt_wifi7` / mtwifi / DTS / kernel work — target is official mt76/mac80211.

**Status legend:** ✅ done · 🔄 in progress · ⛔ blocked · ⬜ not started

---

## Phase 0 — freeze and prove the base
Complete. Software merged to master (PR #1, `912b414`, CI green) and the hardware
baseline gate (0.4) verified on the physical H5000M on 2026-07-25.

- ✅ **0.1 Baseline hardening** — `wpad-basic-mbedtls` → `wpad-openssl` (single-provider
  assertion); feature-plugin denylist widened; boundary check + secret scanner + tests.
- ✅ **0.2 Snapshot reproducibility** — `scripts/manage-feed-lock.sh`
  (capture/verify/materialize) + pinned `configs/official-base.{feed.env,repositories.lock,feeds.sha256,manifest.lock}`.
  Offline pinned build proven byte-identical. Also added `OPENWRT_ROLLING=1`
  (mirror rolls ~hourly, so CI tracks the live snapshot; pinned mode stays default).
- ✅ **0.3 Signing-key gate (software)** — plugin trust anchor rotated to fresh
  ECDSA P-256 (`ccb879ec…`); pinned fingerprint enforced; `scripts/check-plugin-signing-key.sh`.
  - ⬜ Back up `~/.config/h5000m-apk/private-key.pem` off-machine (only copy the firmware trusts).
  - ⬜ Decide: upload signing key to GitHub Secrets (`H5000M_APK_SIGNING_KEY`) — deferred until plugins exist.
- ✅ **0.4 Hardware baseline gate** — verified live 2026-07-25 (root SSH @ 192.168.10.1,
  base = SNAPSHOT r35420-06c826e335, kernel 6.18.38, aarch64, apk).
  - ✅ Stock firmware config dumped (`stock-fw-configs/`, gitignored — contains
    `shadow`/`passwd`/`uhttpd.key`; **never commit**). Real vendor stack captured:
    qmodem, mosdns, openclash, gwswitch, mtkhqos, eqos/appfilter, fancontrol,
    sms_forwarder. Mine it for FM350/modem facts (Phase 0.4/2) and the vendor
    feature set — but the target base is clean official mt76, not this vendor image.
  - ✅ mt76 RF up: chip **MT7996e/MT7992** (filogic WiFi7), dual-band AP (2.4 ch1 +
    5 ch36 @ 160 MHz), regdomain CN, cpu-thermal 43 °C idle. **Stop-the-line cleared.**
  - ✅ `eth1` = WAN (dhcp/dhcpv6); `eth0`→`br-lan` LAN. Storage: eMMC GPT, `/overlay`
    f2fs **7.2 GB / ~7 GB free** → partition ceiling is a non-issue.
  - ✅ FM350-GL facts: USB `0e8d:7127`, 10-iface CDC-ACM+data (RNDIS/ECM+AT) composite,
    config 1 (~GTUSBMODE 41). See FM350-GL-SETUP.md + RISK-2 below.
  - ⚠️ **RISK-1 (Wi-Fi):** device shipped **uncalibrated** — `factory` partition
    (`mmcblk0p2`) was all-zero, so `mt7996e … eeprom load fail, use default bin`.
    Confirmed NOT caused by our flash (stock HiGoROS is a sysupgrade tar with the same
    blank-factory DT wiring → stock ran default-bin too; stock u-boot has no MAC either).
    Interface MACs are **stable across reboots** (persisted in `/overlay .../network`,
    arbitrary `6a:…`), not random-per-boot. **Action taken (reversible):** wrote a valid
    2i5i eeprom + deterministic MAC `02:73:d9:be:07:c7` to `factory` → `eeprom load fail`
    now gone (calibration provisioned); note OpenWrt still derives interface MACs from the
    eth base, not the eeprom. RF-power vs TXpower found flat (see
    `docs/H5000M-hardware-notes.md`). Follow-up: vendor golden eeprom + MAC scheme;
    true RF cal infeasible DIY. See plan WS-R1 + `docs/H5000M-hardware-notes.md`.
  - ⚠️ **RISK-2 (modem):** FM350 enumerates but the clean base ships **no modem kmods**
    (no option/cdc_ether/rndis/qmi_wwan/cdc_mbim, no uqmi/umbim/comgt/QModem) → zero
    `/dev` nodes. This is the concrete Phase 2/3.2 driver manifest, not a base defect.
- ✅ Merge PR #1 to master (merged: `912b414`).

> **Re-planned 2026-07-26.** The old Phase 1–5 numbering is retired: Phase 2 turned out to
> be complete, the pinning model was dropped for rolling, and deep research invalidated the
> MBIM target. Full plan + evidence:
> `~/.claude/plans/given-phase-0-4-is-ancient-fiddle.md`.

## Phase 2 — package availability gate — ✅ DONE
- ✅ `docs/phase2-package-availability.md`. **Nearly every feature package is already in
  the official feeds, OpenWrt-signed** — travelmate, mwan3, tailscale + `kmod-tun` +
  `luci-app-tailscale-community`, openconnect, lpac, and the full FM350 kmod set.
  Only PassWall2 and `luci-app-epm` would need source builds (both deferred).
- ⚠️ Two corrections annotated in that file: its "MBIM recommended" verdict is **obsolete**
  (see below), and the `kmod-usb-net-rndis-host` rename warning appears **mistaken**.

## Stage 0 — Base tuning + reflash
- ⬜ Wi-Fi/forwarding defaults in `90-h5000m-base`: `country=AU` (measured: 5 GHz disabled
  channels 16 → 7, unlocking the DFS band 100–144 that CN blocks), `tx_burst=2.0`,
  `packet_steering=1`, `flow_offloading{,_hw}=1` — with matching build assertions.
- ⬜ `OPENWRT_ROLLING=1` build; record revision/kernel/ABI as the **kmod contract**; flash.
- **Why now:** device is on r35420/kernel 6.18.38 but feeds are 6.18.39+; kmods are
  ABI-locked, so FM350 drivers from today's feed cannot load until we reflash.

## Stage 1 — Plugin pipeline (the old "Phase 1")
- ⬜ Implement `configure-sdk` / `build-packages` / `build-offline-repo` /
  `verify-offline-install` / `check-secrets` in `openwrt-H5000M-plugins` (scaffolded, pushed).
- **Milestone M1:** `h5000m-travelmate-defaults` built → signed → offline repo → installed
  into the exact base rootfs with `--network none`, no `--allow-untrusted`, negative
  controls failing as required.
- Key findings: the **SDK signs each APK** (unlike the buildbot) so the dev loop needs no
  `--allow-untrusted`; **`feeds.buildinfo`** pins all feeds per-run, giving rolling
  determinism; official indexes are ~1.4 MB so we ship them **byte-identical** and let the
  device verify OpenWrt's own signatures.

## Stage 2 — Features (in-feed packages + one small custom package each)
- ⬜ **2.1 Travelmate** — `h5000m-travelmate-defaults`; one disabled `mode='sta'` VIF →
  `trm_wwan`; idempotent, no baked SSID/PSK. Doubles as the M1 proof package.
- ⬜ **2.2 Tailscale** — `tailscale` + `kmod-tun` + `luci-app-tailscale-community`
  (the maintained in-feed app); ship logged out; `tailscale0` zone. Flash is a non-issue.
- 🔄 **2.3 FM350 cellular** — `kmod-usb-serial-option` + `kmod-usb-acm` +
  `kmod-usb-net-rndis` (+ `464xlat`/`kmod-nat46` for IPv6-only US carriers), plus
  `h5000m-modem-atd` (serialized AT broker) and `h5000m-fm350` (netifd proto + dialer).
  - ⛔ **MBIM target DROPPED.** `AT+GTUSBMODE=?` → only `(40,41)`, **both RNDIS**. There is
    no MBIM/QMI over USB on this modem (MBIM is PCIe-only via `mtk_t7xx`).
    `umbim`/`uqmi`/`cdc-mbim`/`qmi-wwan` are dead ends here.
  - ⭐ **Key data-path fix:** RNDIS forwards only on **PDP context 1**
    (`AT+CGDCONT=1,…` + `AT+CGACT=1,1`). Wrong context → tx rises, rx stuck ~2,
    `NETDEV WATCHDOG` (silent RX drop).
  - ⭐ **APN: blank first.** `AT+CGDCONT=1,"IPV4V6",""` requests the subscription default
    and is self-correcting; a wrong APN silently black-holes traffic. The IMSI table is an
    optimisation, not the primary path.
  - ⭐ Never hard-code the netdev or AT port — discover from USB `0e8d:7127`; handle both
    `ttyUSB` (option) and `ttyACM` (cdc_acm) bindings.
  - ✅ Field research: `FM350-GL-SETUP.md`, `stock-fw-opkg-installed.md`,
    `docs/FM350-GL-*.pdf` — written against ImmortalWrt+QModem; modem facts port, QModem
    specifics are reference only.
- ⬜ **2.4 eSIM (CLI only)** — in-feed `lpac` over its **AT backend**
  (`LPAC_WITH_AT` is `default y`, verified). EPM web UI deferred. First test:
  `lpac chip info` — the vendor image had zero eSIM support, so it is unconfirmed whether
  this unit even has an eUICC.
- ⬜ **2.5 mwan3** — wired(1) → `trm_wwan`(2) → discovered cellular iface(3); no hard-coded
  netdev; `mwan3.user` keeps `tailscale0` out. Track **public IPs**, never the cellular
  pseudo-gateway (it never answers ICMP). Re-validate flow offloading here — offloaded
  flows bypass netfilter and can defeat fwmark policy routing.

## Later — deferred, not scheduled
- ⬜ **OpenConnect/Cisco** — disabled `cisco` interface; **auth feasibility gate**
  (SAML/MFA/cookie) before promising unattended reconnect.
- ⬜ **Six-state egress selector** — routing contract first (numeric fwmarks/priorities/
  tables, DNS owner, IPv6 policy; disjoint from mwan3 `0x3F00` / Tailscale `0xff0000`),
  then a transactional apply/probe/rollback implementation.
- ⬜ **PassWall2 / luci-app-epm** — the only two packages needing third-party source builds.

## Security, provenance, CI (continuous)
- 🔄 Done: secret scan, SHA256SUMS over sidecars, CI, signing-key gate.
- ⬜ Extend the secret scan to APK contents / rootfs / release sidecars.
- ⬜ Full provenance record (revision, SDK, feed commits, per-package hashes, key fingerprint).
- ⬜ Final on-device matrix once the selector exists.

## Explicit non-goals
No vendor Wi-Fi driver/cfg80211; no MTK EasyMesh/`.dat`; no MT5700M-specific modem
impl (hardware is FM350-GL); no auto/geolocation selector; no baked secrets;
no `--allow-untrusted`, no silent key replacement.
