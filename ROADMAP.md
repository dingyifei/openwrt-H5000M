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
Software portion complete and on branch `phase0-base-hardening` (PR #1, CI green).

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
- 🔄 **0.4 Hardware baseline gate** — needs the physical H5000M.
  - ✅ Stock firmware config dumped (`stock-fw-configs/`, gitignored — contains
    `shadow`/`passwd`/`uhttpd.key`; **never commit**). Real vendor stack captured:
    qmodem, mosdns, openclash, gwswitch, mtkhqos, eqos/appfilter, fancontrol,
    sms_forwarder. Mine it for FM350/modem facts (Phase 0.4/2) and the vendor
    feature set — but the target base is clean official mt76, not this vendor image.
  - ⬜ Flash the official base + recovery path; verify mt76/RF/regdb/throughput/thermals.
  - ⬜ Confirm `eth1` WAN, partition ceiling; capture FM350-GL facts (USB id, AT
    port, UCI iface name, RNDIS device, `AT+GTUSBMODE?`) from the dump + live device.
  - **Stop-the-line:** if mt76 RF/throughput is unacceptable, reassess the whole approach.
- ⬜ Merge PR #1 to master.

## Phase 1 — separate signed plugin build/repository
- ⛔ Blocked on: a decision to build plugins, and the **matching official SDK**
  (r-specific GCC 14.4 SDK not preserved locally; online SDK has rolled).
- ⬜ Create sibling `openwrt-H5000M-plugins` (SDK/feed/source/package locks;
  fetch-SDK, configure-SDK, build-packages, build-offline-repo, verify-offline-install).
- ⬜ Reuse only the historical *delivery guarantees* (persistent signing, signed
  `packages.adb`, offline install sim); never use `--allow-untrusted`.

## Phase 2 — package availability & compatibility gate
- ⬜ Machine-readable report for travelmate, mwan3, tailscale+kmod-tun, openconnect+
  luci-proto-openconnect+vpnc-scripts, lpac+luci-app-epm, Tailscale LuCI app, PassWall2.
  Record source/version/deps/size/arch/signature/license per package.

## Phase 3 — feature packages (each independent, needs mac80211 hardware first)
- ⬜ **3.1 Travelmate** — `h5000m-travelmate-defaults`; one disabled `mode='sta'` VIF → `trm_wwan`; idempotent, no baked SSID/PSK.
- ⬜ **3.2 FM350/lpac/EPM** — lpac 2.3.x (AT+UQMI+MBIM), EPM patch `--fuzz=0`, QModem for FM350-GL. Ship RNDIS+AT; MBIM only via reversible `AT+GTUSBMODE` gate.
- ⬜ **3.3 mwan3** — wired(1) → `trm_wwan`(2) → discovered cellular UCI iface(3); no hard-coded `eth2`; `mwan3.user` keeps `tailscale0` out.
- ⬜ **3.4 Tailscale** — pinned tailscale+kmod-tun+LuCI; ship logged out; `tailscale0` zone; verify OpenWrt/Tailscale/Go/LuCI tuple; measure flash size.
- ⬜ **3.5 Cisco/OpenConnect** — disabled `cisco` interface; underlay host-route follows mwan3; **auth feasibility gate** (SAML/MFA/cookie) before promising unattended reconnect.

## Phase 4 — six-state egress selector
- ⬜ **4.1 Routing contract first** — table for `egress{none|proxy|cisco} × tailscale{off|on}`: numeric fwmarks/priorities/tables, DNS owner, IPv6 policy; marks disjoint from mwan3 `0x3F00` / Tailscale `0xff0000`.
- ⬜ **4.2 Transactional impl** — lock/snapshot/stage/apply-once/probe/commit-or-rollback; LAN mgmt always reachable; no silent mode switching.

## Phase 5 — security, provenance, CI, release gates
- 🔄 Partially done (secret scan, SHA256SUMS over sidecars, CI). Remaining:
- ⬜ Extend secret scan to APK contents / rootfs / release sidecars.
- ⬜ Full provenance record (ImageBuilder/SDK/feed hashes, per-package + external source refs, TLS variant, tuple).
- ⬜ Signed release provenance via a separate identity (not the APK key).
- ⬜ Final on-device matrix: 6 selector states × 3 underlays × reboot/WAN-loss/proxy-fail/cisco-fail.

## Explicit non-goals
No vendor Wi-Fi driver/cfg80211; no MTK EasyMesh/`.dat`; no MT5700M-specific modem
impl (hardware is FM350-GL); no auto/geolocation selector; no baked secrets;
no `--allow-untrusted`, no silent key replacement.
