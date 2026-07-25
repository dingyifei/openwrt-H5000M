# Phase 2 — Package Availability & Compatibility Report

**Device:** `hiveton,h5000m` · **Target:** `mediatek/filogic` · **Arch:** `aarch64_cortex-a53`
**Base:** official OpenWrt SNAPSHOT **r35420-06c826e335** · **Package manager:** `apk` (apk-tools v3, ADB indexes)

## Provenance & method (read this first)

The numbers below are the **exact pinned r35420 feed indexes**, not the live rolling snapshot.

- Source of truth: the pinned feed-lock bundle cached at
  `~/.cache/openwrt-H5000M/feed-bundles/official-base-r35420-06c826e335.feed-lock.tar.zst`
  (matches `configs/official-base.feed.env` → `FEED_LOCK_ID=r35420-06c826e335-dea2b501e99e76a0`).
- The 8 `dl/APKINDEX.*.tar.gz` files inside are **apk v3 `ADBd` binary indexes** (deflate-compressed ADB blobs, *not* gzip/tar). They were inflated and the string pool parsed to enumerate packages, versions, licenses and dependency names for every feed in `configs/official-base.repositories.lock`.
- Feeds parsed: target `packages`, `base`, target `kmods` (`6.18.38-1-45144f660449efe7168d085e7f599cf8`), `luci`, `packages`, `routing`, `telephony`, `video`.
- Cross-checks against the **live** `downloads.openwrt.org` snapshot were used for the kmod set. **Caveat:** the live snapshot has already rolled past r35420, and the live HTML directory listings are large enough that the fetch summarizer silently truncates them (~600 entries, `a`–`g`) and dropped real packages (`uqmi`/`umbim`/`comgt` and even `kmod-usb-net-cdc-mbim`). **Do not trust the live directory listing for tail-of-alphabet packages** — the r35420 ADB indexes below are authoritative.
- Versions marked **[idx]** were read directly from the r35420 ADB index. Versions marked **[src]** come from the OpenWrt source Makefile (`openwrt.git` / `feeds/packages` master ≈ snapshot) because apk stores those records' version as a binary field not adjacent in the string pool; presence is still index-confirmed.
- **Signatures:** every in-feed package is covered by the signed OpenWrt snapshot apk index (the base image ships `openwrt-keyring`; `apk` verifies the ADB index signature). Treat all "in official feed = yes" rows as **signed/verified by the OpenWrt snapshot key**. Third-party (must-build) packages are **not** OpenWrt-signed.
- **Sizes** are order-of-magnitude *installed* estimates (the ADB stores sizes as binary integers not extracted here); flagged approximate.

---

## Main table

| Package | In official feed? | Version (r35420) | Feed | Key deps | ~Installed size | License | Notes |
|---|---|---|---|---|---|---|---|
| **travelmate** | ✅ yes | 2.4.6(-r2) `[src]` | packages | iwinfo, jshn, jsonfilter, curl, ca-bundle, rpcd, rpcd-mod-rpcsys | ~80 KB | GPL-3.0-or-later | ucode/shell WLAN travel-router mgr |
| **luci-app-travelmate** | ✅ yes | 2.4.6-r3 `[idx]` | luci | luci-base, travelmate, rpcd-mod-luci | ~120 KB | Apache-2.0 (LuCI) | |
| **mwan3** | ✅ yes | 2.12.2-r1 `[idx]` | packages | ip, ipset, iptables, ip6tables, iptables-mod-conntrack-extra, iptables-mod-ipopt, rpcd-mod-ucode, jshn | ~90 KB | GPL-2.0 | multi-WAN load-balance/failover |
| **luci-app-mwan3** | ✅ yes | 26.x `[idx]` | luci | luci-base, mwan3 | ~150 KB | Apache-2.0 | present as `luci-app-mwan3` |
| **tailscale** | ✅ yes | **1.98.3-r1** `[idx]` | packages | `$(GO_ARCH_DEPENDS)`, ca-bundle, **kmod-tun** | ~30 MB | BSD-3-Clause | Go binary (tailscaled+tailscale) — **large**, watch flash budget |
| **luci-app-tailscale-community** | ✅ yes | 26.x `[idx]` | luci | luci-base, tailscale | ~60 KB | Apache-2.0 | **this is the maintained LuCI app in the feed**; plain `luci-app-tailscale` (asvow) is **NOT** in the official feed |
| **kmod-tun** | ✅ yes | 6.18.38-r1 `[idx]` | kmods (target) | kmod (kernel) | ~10 KB | GPL-2.0 | TUN/TAP; dep of tailscale + openconnect |
| **openconnect** | ✅ yes | **9.12-r7** `[idx]` | packages | libxml2, kmod-tun, resolveip, **vpnc-scripts**, (OpenSSL: libopenssl+p11-kit+libp11 \| GnuTLS variant) | ~250 KB | LGPL-2.1-or-later | Cisco AnyConnect/Juniper/GlobalProtect client |
| **luci-proto-openconnect** | ✅ yes | 26.x `[idx]` | luci | luci-base, openconnect | ~15 KB | Apache-2.0 | protocol handler present |
| **vpnc-scripts** | ✅ yes | 20151220-r3 `[src]` | packages | (ip) | ~20 KB | GPL-2.0 | runtime dep of openconnect |
| **lpac** | ✅ yes | 2.3.0-r2 `[src]` | packages | libcurl, (PCSC: libpcsclite+pcscd), (MBIM: libmbim), (UQMI: uqmi) | ~200 KB | **AGPL-3.0-only + LGPL-2.0-only** `[idx]` | eUICC/eSIM LPA manager (estkme-group/lpac) |
| **luci-app-epm** | ❌ no | — | — | — | — | — | eSIM Profile Manager LuCI app is **third-party**, not in official luci feed — **build from source** |
| **PassWall2** (`luci-app-passwall2`/`passwall2`) | ❌ no | — | — | — | — | — | not in any official feed — third-party (`xiaorouji/openwrt-passwall2`). **build from source.** `passwall`/`luci-app-passwall`/`openclash`/`qmodem` also absent. |
| — proxy cores that *are* in feed | ✅ yes | see notes | packages | — | varies | mixed | `sing-box`, `xray-core`, `v2ray-core`, `hysteria`, `trojan`/`trojan-go` are all in the official packages feed (PassWall2's engines exist even though the PassWall2 wrapper does not) |

### FM350-GL modem driver manifest (the base image ships NONE of these by default)

All kmods below are in the **target kmods feed** at kernel `6.18.38-r1`, license GPL-2.0. Userspace controllers are in `base`/`packages`.

| Package | In official feed? | Version (r35420) | Feed | Purpose for FM350 | License |
|---|---|---|---|---|---|
| **kmod-usb-serial-option** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | AT/serial ports (`option` driver) | GPL-2.0 |
| **kmod-usb-net-cdc-ether** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | CDC-ECM data path | GPL-2.0 |
| **kmod-usb-net-rndis** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | RNDIS data path (⚠ r35420 packages it as `kmod-usb-net-rndis`; the *live* rolled snapshot renamed it to `kmod-usb-net-rndis-host`) | GPL-2.0 |
| **kmod-usb-net-cdc-mbim** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | **MBIM data path (FM350 primary mode)** | GPL-2.0 |
| **umbim** | ✅ yes | **2025.10.04~2939b7d0-r1** `[idx]` | base | userspace MBIM controller (deps: kmod-usb-net-cdc-mbim, wwan) | GPL-2.0 |
| **kmod-usb-net-qmi-wwan** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | QMI data path (alt) | GPL-2.0 |
| **uqmi** | ✅ yes | **2025.07.30~7914da43-r2** `[idx]` | base | userspace QMI controller (deps: kmod-usb-net-qmi-wwan, wwan) | GPL-2.0 |
| **kmod-usb-net-cdc-ncm** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | NCM data path | GPL-2.0 |
| **kmod-usb-net-huawei-cdc-ncm** | ✅ yes | 6.18.38-r1 `[idx]` | kmods | NCM (Huawei variant), needed by comgt-ncm | GPL-2.0 |
| **comgt** | ✅ yes | **0.32-r36** `[idx]` | base | 3G/AT control tool (dep: chat) | GPL-2.0+ |
| **comgt-ncm** | ✅ yes | (subpkg of comgt) `[idx]` | base | NCM connect scripts (deps: comgt, wwan, kmod-usb-serial-option, kmod-usb-net-huawei-cdc-ncm) | GPL-2.0+ |
| **wwan** | ✅ yes | present `[idx]` | base | netifd wwan proto glue (uqmi/umbim/comgt-ncm dep) | GPL-2.0 |
| **modemmanager** | ✅ yes | 1.24.0-r11 `[src]` | packages | full modem manager (deps: glib2, dbus, ppp, libmbim, libqmi, libqrtr-glib) | GPL-2.0-or-later | 
| **libqmi / libmbim / libqrtr-glib** | ✅ yes | libqrtr-glib 4.1.1-r2 `[idx]`; libqmi/libmbim present `[idx]` | packages | ModemManager/lpac backends | GPL/LGPL |
| **luci-proto-qmi** | ✅ yes | present `[idx]` | luci | LuCI QMI proto | Apache-2.0 |
| **luci-proto-mbim** | ✅ yes | present `[idx]` | luci | LuCI MBIM proto | Apache-2.0 |
| **luci-proto-ncm** | ✅ yes | present `[idx]` | luci | LuCI NCM proto | Apache-2.0 |
| **luci-proto-3g** | ✅ yes | present `[idx]` | luci | LuCI 3G proto | Apache-2.0 |
| **luci-proto-modemmanager** | ✅ yes | present `[idx]` | luci | LuCI ModemManager proto | Apache-2.0 |
| kmod-usb-acm, kmod-usb-serial-wwan, kmod-wwan, kmod-mhi-wwan-mbim, kmod-mhi-wwan-ctrl | ✅ yes | 6.18.38-r1 `[idx]` | kmods | extra ACM/MHI(PCIe) paths if the FM350 is wired via PCIe/MHI instead of USB | GPL-2.0 |
| **qmodem / luci-app-qmodem** | ❌ no | — | — | third-party MediaTek modem UI — **build from source** if wanted | — |

---

## FM350 driver-set verdict

**All kernel + userspace pieces needed to bring up the FM350-GL over USB are present in the official r35420 feeds — nothing kmod-side needs a source build.**

> ## ⛔ CORRECTION (2026-07-26) — the MBIM/QMI verdicts below are OBSOLETE
>
> This report was written **before** the `AT+GTUSBMODE` constraint was known. On the real
> device `AT+GTUSBMODE=?` returns **only `(40,41)` — and both are RNDIS**. FM350-GL
> firmware exposes **no MBIM and no QMI over USB**; MBIM exists only over **PCIe** via
> `mtk_t7xx`, and this board wires the modem over USB (`0e8d:7127`).
>
> Therefore, **for this device**: `kmod-usb-net-cdc-mbim`, `umbim`,
> `kmod-usb-net-qmi-wwan`, `uqmi` and `modemmanager` are **dead ends**. The packages are
> genuinely available in the feed — they just cannot carry data on this hardware.
>
> **The actual stack is:** `kmod-usb-serial-option` (AT control) + `kmod-usb-net-rndis`
> (data) + `kmod-usb-acm` (the interfaces are CDC-ACM class, so `cdc_acm` may claim them
> instead of `option` on a stock kernel — ship both and probe at runtime).
> eSIM still works: lpac drives the eUICC over its **AT** backend.

- ~~**MBIM path (recommended for FM350):**~~ **NOT VIABLE — see correction above.** `kmod-usb-net-cdc-mbim` + `umbim` (or `modemmanager`+`libmbim`) are in the feed but unusable on this modem.
- **QMI path (alt):** `kmod-usb-net-qmi-wwan` + `uqmi` (or `modemmanager`+`libqmi`) — ✅ all available.
- **AT/serial + NCM fallback:** `kmod-usb-serial-option`, `comgt`/`comgt-ncm`, `kmod-usb-net-huawei-cdc-ncm` — ✅ available.
- **RNDIS/ECM:** `kmod-usb-net-rndis` (⚠ named `kmod-usb-net-rndis-host` on the live rolled snapshot — pin against r35420 or update the package name in build lists), `kmod-usb-net-cdc-ether` — ✅ available.
- LuCI protocol handlers for qmi/mbim/ncm/3g/modemmanager are all in the luci feed, so the modem is configurable from the web UI.
- **PCIe/MHI option:** if the FM350 is attached via PCIe rather than USB, `kmod-mhi-wwan-mbim` / `kmod-mhi-wwan-ctrl` are also present.

**These are firmware add-ons** (the stock base image installs none of them) — they must be added to the ImageBuilder package list, but they resolve entirely from the pinned official feeds (no plugin-SDK source build required for the modem stack).

---

## Must-build-from-source (NOT in any official feed)

These require the (future) plugin-SDK source pipeline:

1. **PassWall2** — `luci-app-passwall2` + `passwall2` (third-party `xiaorouji/openwrt-passwall2`). Note: the underlying proxy engines (`sing-box`, `xray-core`, `v2ray-core`, `hysteria`, `trojan`) *are* in the official feed, so only the PassWall2 wrapper/UI needs building. (`luci-app-passwall`, `openclash` also absent.)
2. **luci-app-epm** — eSIM Profile Manager LuCI app (third-party). `lpac` itself (the eSIM engine it wraps) **is** in the official feed.
3. **luci-app-tailscale** (plain, asvow) — only if you specifically want that UI; the official **`luci-app-tailscale-community`** is available and is the maintained one.
4. **qmodem / luci-app-qmodem** — optional third-party modem UI; not needed for the FM350 stack above.

Everything else in the Phase-2 request (travelmate, mwan3, tailscale, openconnect + luci-proto, vpnc-scripts, kmod-tun, lpac, and the complete FM350 kmod/userspace set) is available and signed in the pinned r35420 official feeds.

---

## Data-quality notes

- r35420 vs live rolled snapshot: everything above is **r35420** (the pinned base). ~~The only known drift observed is the `kmod-usb-net-rndis` → `kmod-usb-net-rndis-host` rename on the live snapshot.~~ **CORRECTION (2026-07-26): the rename appears to be mistaken.** Upstream `package/kernel/linux/modules/usb.mk` on `main` still defines `KernelPackage/usb-net-rndis` (i.e. `kmod-usb-net-rndis`), with `DEPENDS:= +kmod-usb-net-cdc-ether`. Dependency resolution makes the distinction moot in any case. Version strings will still have advanced on live (e.g., kmod release bumps `-r1`→`-r2+`).
- `[idx]` versions are byte-exact from the pinned ADB index; `[src]` versions are from the master source tree (presence is index-confirmed, only the exact `-rN` wasn't cleanly extractable from the binary record).
- Installed sizes are estimates; **tailscale (~30 MB) is the one to watch** for flash budget. Everything else is tens-to-low-hundreds of KB except `modemmanager` (~2–3 MB with glib2/dbus).
