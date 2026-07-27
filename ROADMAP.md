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

**Delivery model (decided 2026-07-26): hybrid — two images, not one.**
Building/signing plugins separately and *installing* them post-flash were being treated
as one decision; they are independent. The clean base is still built, asserted and hashed
first and remains the artifact we can prove is stock OpenWrt. A **second, optional**
artifact — the *loaded* image — is then built on the same ImageBuilder run with the signed
plugin repo added (`H5000M_LOADED_IMAGE=1` + `H5000M_PLUGIN_REPO=<plugins>/offline-repo`,
package list in `configs/loaded-features.packages`).

Why bake at all, when the plugins install fine over SSH:
- **sysupgrade wipes the overlay**, so every reflash otherwise loses the whole feature
  set — and under the rolling model reflashing is routine, on a *travel* router that may
  have no laptop nearby.
- It makes the **kernel-ABI contract structural instead of procedural**: image and kmods
  come out of one build, so they cannot disagree. Post-flash installation relies on the
  operator pairing the right offline repo with the right image, which can fail silently.

The clean base keeps its `forbidden_packages` guard; the loaded image gets the **inverse**
check (every listed plugin, plus the `h5000m-modem-atd` dependency, must be present), so a
loaded image that silently shipped without its features fails the build.

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

## Stage 0 — Base tuning + reflash — ✅ DONE (2026-07-26)
- ✅ Wi-Fi/forwarding defaults in `90-h5000m-base`, each with a matching build assertion:
  `country=AU` — **measured on-device: 5 GHz disabled channels 16 → 7**, unlocking the DFS
  band (ch 100–144) that CN blocks; `tx_burst=2.0`; `packet_steering=1`;
  `flow_offloading{,_hw}=1` (confirmed active: `flowtable ft { flags offload`).
- ✅ Rolling build + flash. **kmod contract: `r35533-3b2bc55dcb`, kernel `6.18.39`,
  ABI `38ca7baf52c71e940d7f3ce0e127bcc9`, `aarch64_cortex-a53`.**
- ✅ **Factory partition survived sysupgrade** — no `eeprom load fail`; only the overlay reset.
- ⚠️ TX power is a no-op on this unit, so AU buys **channel choice, not power**.
- ⚠️ Offloaded flows bypass netfilter → **re-validate flow offloading when mwan3 lands**;
  if failover misroutes, set both flags back to `0`.
- ⬜ Throughput before/after **not** measured (no `iperf3` on base, no uplink yet) — deferred.

## Stage 1 — Plugin pipeline — ✅ DONE, M1 VERIFIED (2026-07-26)
- ✅ `configure-sdk` / `build-packages` / `build-offline-repo` / `verify-offline-install` /
  `check-secrets` / signing-key gate implemented in `openwrt-H5000M-plugins`.
- ✅ **M1 passed end to end:** `h5000m-travelmate-defaults` built → signed → offline repo →
  installed into the exact base rootfs with `--network none`, **no `--allow-untrusted`**,
  alongside 4 OpenWrt-signed packages, using only the firmware's embedded anchors.
  **All 4 negative controls failed as required** (empty keys-dir, corrupted `.apk`,
  untrusted signer, absent package).
- Verified findings: the **SDK signs each APK** (unlike the buildbot) so the dev loop needs
  no `--allow-untrusted`; **`feeds.buildinfo`** pins all feeds per-run; official indexes are
  ~1.4 MB and **superset indexes work**, so we ship them byte-identical and the device
  verifies OpenWrt's own signatures rather than us re-attesting them.
  See `../openwrt-H5000M-plugins/docs/apk-tooling-findings.md`.

## Stage 2 — Features (in-feed packages + one small custom package each)

> **Re-planned 2026-07-26 → modem-first order (2.3 → 2.4 → 2.1 → 2.2 → 2.5).** The FM350 is
> the only substantial engineering and its kmods are ABI-locked to the flashed snapshot.
> All six custom packages are now written; see `docs/H5000M-hardware-notes.md`
> §"FM350 on the clean base" for what was measured rather than assumed.

- 🔄 **2.1 Travelmate** — `h5000m-travelmate-defaults`; one disabled `mode='sta'` VIF →
  `trm_wwan`; idempotent, no baked SSID/PSK. **Stub replaced with real logic and verified
  on device**: generic radio discovery, exactly one STA VIF, AP sections preserved,
  `fw4 check` clean, config stable across three consecutive runs.
- 🔄 **2.2 Tailscale** — `tailscale` + `kmod-tun` + `luci-app-tailscale-community`
  (the maintained in-feed app); ship logged out; `tailscale0` zone. Flash is a non-issue.
  Zone + both forwardings created and verified idempotent on device.
- ✅ **2.3 FM350 cellular — WORKING end to end (2026-07-26).** `ifup cellular` brings the
  link up unattended and passes traffic: `up: true`, `10.20.22.218/24`, rx 544 vs tx 108,
  HTTP responses over `eth2`. Ships `auto=1`.
  - ⭐ **The real constraint is that EXACTLY ONE PDP context may be active** — not the cid
    number. With two or more live, RNDIS forwards none of them (tx climbs, rx stays 0).
    This retires the "cid 1 only" rule that was in our docs, QModem's docs and upstream
    folklore alike; it only ever appeared true when nothing else happened to be active.
  - ⭐ **`+EAPNACT` replaces `+CGACT`** — activates by APN name and type, the modem picks
    the aid, and it never returns the local refusal `5847`, which `AT+CGACT=1,1` always
    will where the carrier owns cid 1 for IMS (China Telecom does). Success is
    `+CGEV: ME PDN ACT <aid>`, not `OK`.
  - ⭐ **`arp off`** on the RNDIS netdev (OpenWrt PR #24196 — the generic `rndis_host`
    profile lacks `NOARP` for `0e8d:7127`). Necessary but not sufficient alone, which is
    why each fix tested in isolation looked like a dead end.
  - ⭐ **Blank APN worked** (`apn='<subscription default>'`) — blank-first was right all
    along, it just never got a turn while the dialer fought over cid 1.
  - Removed with the old model: `pdp_index`, `EIAAPN`, and all `CFUN` radio cycling —
    which was also the main way the dialer could wedge the modem.
  - ⭐ **The APN *type* is not stable and is now a ladder (2026-07-26).** Same SIM, same
    carrier: `"default"` activated cleanly one session and returned `+CME ERROR: 5848`
    the next with nothing active, while `"net"` activated immediately. `AT+CEER` reports
    `0,NONE` — no network cause, so the refusal is local and unpredictable. The dialer now
    tries the configured type, then `default`/`net`/`tethering`, as it already does for
    the APN itself. Re-verified end to end: `10.120.135.159/24`, ping 4/4 @ 28 ms.
  - 🐛 **`luci-proto-fm350` was missing from the loaded image** — it DEPENDS on
    `h5000m-fm350`, not the reverse, so nothing pulled it in and LuCI kept showing
    "unsupported protocol type". Now listed explicitly in
    `configs/loaded-features.packages`, where the build's manifest assertion enforces it.
  - ⬜ Throughput/failover measurement deferred until `eth1` is connected.

- 🔄 **2.4 eSIM — eUICC CONFIRMED PRESENT, lpac blocked (2026-07-26).** C15 is closed.
  - ⭐ **This unit has a built-in eUICC.** The Hardware Guide §3.5 states the FM350
    "supports dual SIM, one is a built-in eSIM"; measured, `AT+GTDUALSIM=?` → `(0-1)`, and
    switching to slot 1 makes `AT+EID` return a real 32-digit EID. It reports
    `+CPIN: EMPTY_EUICC` — present, no profile installed.
  - ⭐ **`AT+EID` is the cheap probe.** It answers "is there an eUICC" with no lpac, no
    logical channel and no slot switch. Empty string = not available (manual's definition).
  - ⛔ **OpenWrt's `lpac` package hides a UCI wrapper.** `/usr/bin/lpac` is not the binary
    (`/usr/lib/lpac` is); it **overwrites `LPAC_APDU`** from
    `uci lpac.global.apdu_backend`, default `uqmi` → opens `/dev/cdc-wdm0`, which this
    modem lacks. Symptom is a bare "Failed to open device". `h5000m-esim` now calls the
    real binary directly.
  - ⛔ **`AT+CCHO` to the ISD-R AID returns ERROR on both slots**, so lpac's `at` backend
    cannot reach the applet; `at_csim` is not compiled into the packaged build. Unresolved
    whether this is because the eUICC is empty or because the firmware never exposes ISD-R
    that way. MediaTek's `+ESIMS` family is implemented and untried.
  - ⚠️ **Switching slots broke PDP activation** until the APN type was changed — never
    switch slots on a link you depend on without another way in.
- ✅ **2.6 AT layer hardening + web UI (2026-07-27).** The modem is now administrable from
  the browser, and the layer underneath it can be reasoned about.
  - ⭐ **Priority-aware AT access.** Consumers declare `AT_PRIO` (dialer 30, SMS/eSIM 20,
    `atq` 10, UI poll 1). Measured against five competing pollers: priority 30 waited
    **1 s** where priority 1 waited **11 s**. Approximate, not a queue — `flock` has no
    ordering without a port-owning daemon, and the code says so rather than overselling it.
  - ⭐ **`atq -b` batch mode** — four commands in **1.07 s** under one lock acquisition,
    emitting `@@CMD`/`@@RC` so a caller can attribute each reply.
  - ⭐ **Tiered logging** (`/etc/config/h5000m`), runtime-configurable per component, with
    `trace` printing the AT wire. A suppressed call costs zero forks. **Redaction runs at
    every level** and was verified against this SIM's real 15-digit IMSI. A full bring-up
    now costs **3 log lines**, down from dozens.
  - ⭐ **`luci-app-fm350`** — status, SMS inbox/composer, and recovery (reconnect, plus the
    USB `authorized` toggle that fixes a half-dead AT endpoint, verified with `stty` rather
    than by looking for the device node).
  - ⭐ **`AT+CESQ` is RAT-dependent.** LTE populates fields 5–6, NR populates 7–9, the rest
    read 255; this unit switched between them within a day. Conversions and worked examples
    are in `FM350-GL-SETUP.md`. Anything hard-coded to one RAT displays nonsense on the
    other.
  - Two boot races fixed: the AT port answers before the modem has finished booting, and
    the SIM is READY later still. Both are now bounded waits rather than single checks.
  - 🐛 `luci-proto-fm350` shipped without `return network.registerProtocol(...)`, so the
    interface page threw "factory yields invalid constructor". `node --check` passes it —
    a contract violation, not a syntax error — so a test now asserts the contract.
  - 🐛 `h5000m-travelmate-defaults` created an *anonymous* `wifi-iface`, which is what
    LuCI's wireless-migration dialog exists to rename (restarting the network to do it).
    Now named, and it renames sections left by earlier releases so deployed units benefit.
  - Tests: **31 invariants + 21 log-library unit tests**, both negative-controlled.

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
