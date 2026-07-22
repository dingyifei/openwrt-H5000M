# openwrt-H5000M

Hiveton/Airpi H5000M 的干净基础固件构建项目。主包直接使用 OpenWrt 官方 ImageBuilder 和官方 H5000M 设备支持，只补充 Web 管理、中文、常用工具和产品级首启默认值，不维护 DTS、端口布局、内核补丁或自研应用副本。

## 主包边界

主包只包含：

- OpenWrt 官方 H5000M 系统与驱动
- LuCI HTTPS 管理界面和简体中文
- 软件包管理器、ttyd（预装但默认停用）
- 常用诊断、存储和 USB 工具
- OpenWrt 官方 UPnP LuCI 与 `miniupnpd-nftables`
- 完整 `wpad-openssl` 无线认证组件（为后续签名 Travelmate 插件提供 AP+STA 能力）
- H5000M 插件仓库公钥（仅公钥，不包含签名私钥，并固定校验指纹）

主包明确不包含：

- H5000M 风扇管理
- FM350-GL / MT5700M 模组管理、eSIM 和 5G 流量统计
- Travelmate、mwan3、Tailscale、OpenConnect 和出口模式选择器
- 有线 WAN / WiFi 中继 / 5G 出口优先级
- PassWall2 主程序、运行依赖、代理核心、节点、分流或凭据配置
- QModem 主程序、第三方 feed 或模组 WebUI
- EEPROM 自动写入、非官方 DTS 或内核补丁

这些功能以独立签名插件交付，插件故障不会影响基础系统启动。

## 独立插件

| 功能 | 独立仓库 |
| --- | --- |
| H5000M 风扇管理 | [luci-app-h5000m-fancontrol](https://github.com/FAN789/luci-app-h5000m-fancontrol) |
| MT5700M 模组管理及 5G 流量统计 | [luci-app-mt5700m](https://github.com/FAN789/luci-app-mt5700m)（仅适用于 MT5700M） |
| 有线 WAN / 5G 出口优先级 | [luci-app-h5000m-netmode](https://github.com/FAN789/luci-app-h5000m-netmode) |
| PassWall2 离线安装包 | [luci-app-passwall2-h5000m](https://github.com/FAN789/luci-app-passwall2-h5000m) |
| FM350-GL、Travelmate、mwan3、Tailscale、OpenConnect 和出口选择器 | 规划中的独立 `openwrt-H5000M-plugins` 签名仓库 |

实机模组已确认是 Fibocom FM350-GL（USB `0e8d:7127`），不是 MT5700M；MT5700M 专用插件不能作为该模组的实现。UPnP 来自 OpenWrt 官方软件源，直接预装在主包中，不建立独立项目。

插件用一把持久化 ECDSA P-256 密钥签名：私钥只保存在受控编译机的 `$HOME/.config/h5000m-apk/`（或 `H5000M_APK_SIGNING_DIR`），绝不进入 Git；固件只内置对应公钥并固定其 SPKI SHA256 指纹。发布或用 CI 签名前运行 `scripts/check-plugin-signing-key.sh`，它会校验目录/密钥的所有权与权限，并证明私钥、公钥、固件内置公钥和固定指纹四者一致。

历史信任锚（指纹 `43860aca…`）的私钥已丢失，因此已完成一次密钥轮换：当前信任锚是全新生成的 `ccb879ec…`。由于尚无已部署设备信任旧公钥，本次为直接替换，无需新旧双签过渡。签名密钥托管在 GitHub Actions Secrets（`H5000M_APK_SIGNING_KEY`）中，CI 可自动签名插件，不需要手动操作。

## 官方基线

构建参数集中在 `configs/official-base.env`：

- OpenWrt：`r35420-06c826e335`
- 目标：`mediatek/filogic`
- 设备：`hiveton_h5000m`
- 架构：`aarch64_cortex-a53`
- Kernel：`6.18.38`
- Kernel ABI：`45144f660449efe7168d085e7f599cf8`
- 插件公钥 SPKI SHA256：`ccb879ececd19bde222c8d1b36ba529c2420d260e767305edea5397ff15e10f7`
- 构建器：官方 OpenWrt Snapshot ImageBuilder（固定 SHA256）

官方端口定义保持不变：`eth0` 是 LAN，`eth1` 是有线 WAN。MAC、WiFi EEPROM、LED 和 sysupgrade 布局全部沿用 OpenWrt 官方实现。

## 产品默认值

- LAN：`192.168.10.1/24`
- 主机名：`H5000M`
- 时区：`Asia/Shanghai`
- LuCI：简体中文、HTTP 自动跳转 HTTPS
- 管理员：root 默认密码为 `root`
- WiFi：2.4GHz/5GHz 双频同名 `H5000M`，默认密码 `77778888`
- WiFi 频宽：2.4GHz 使用 `EHT40`，5GHz 使用 `EHT160`
- WiFi 安全与漫游：默认开启、WPA2/WPA3 混合模式、802.11w 可选保护及 802.11k 辅助漫游
- WiFi 认证组件：只安装 `wpad-openssl`，不保留精简 `wpad-basic-mbedtls`
- ttyd：预装但默认停用
- SSH：默认开启 root 密码登录，同时保留公钥登录
- UPnP：软件包默认集成，运行策略仍由 OpenWrt 官方配置控制
- PassWall2：主程序及 `dnsmasq-full`、nftables/kmod 依赖全部由独立离线包负责

## 首次使用

1. 只使用名称中带 `squashfs-sysupgrade.bin` 的文件刷写或升级系统。
2. 通过 LAN 访问 `https://192.168.10.1`，使用 root / `root` 登录；WiFi 初始名称为 `H5000M`，密码为 `77778888`。
3. 按需安装独立插件；插件版本必须与主包的 OpenWrt 版本和内核 ABI 匹配。
4. 安装或升级后保留对应固件、插件包和 `SHA256SUMS`，便于恢复与核验。

默认管理密码和无线密码用于首次部署，均属于公开弱密码。设备接入不受信任网络前应立即修改。

插件压缩包、APK 和 `packages.adb` 都不是固件，不能通过 U-Boot 或 LuCI 固件升级页面刷写。

## 本地构建

本项目使用 OpenWrt 官方 ImageBuilder 组装已编译的软件包，不从源码重新编译工具链、Kernel 和驱动。H5000M 固件目标架构是 `aarch64_cortex-a53`，但官方 ImageBuilder 的宿主工具只发布 `Linux-x86_64` 版本；两者是相互独立的架构。

### Apple Silicon macOS（OrbStack）

启动 [OrbStack](https://orbstack.dev/) 后执行：

```sh
./scripts/build-official-base-docker.sh
```

脚本通过 OrbStack 的 Rosetta 支持构建并运行 `linux/amd64` Ubuntu 24.04 容器，容器内仍生成 ARM64 H5000M 固件。项目目录以只读方式挂载；ImageBuilder 缓存和固件产物分别写入宿主机的 `$HOME/.cache/openwrt-H5000M` 和 `artifacts/`。

可覆盖宿主机缓存和产物目录：

```sh
OPENWRT_LOCAL_CACHE=$HOME/openwrt-official-cache \
OPENWRT_LOCAL_ARTIFACTS=$HOME/openwrt-artifacts \
./scripts/build-official-base-docker.sh
```

### x86_64 Linux

可不使用容器，直接执行：

```sh
./scripts/check-main-package.sh
./scripts/build-official-base-local.sh
```

直接构建可通过同名环境变量覆盖缓存和产物目录：

```sh
OPENWRT_LOCAL_CACHE=/home/builder/openwrt-official-cache \
OPENWRT_LOCAL_ARTIFACTS=/home/builder/artifacts \
./scripts/build-official-base-local.sh
```

构建脚本会校验 ImageBuilder 哈希、固件版本、Kernel ABI、LuCI、中文、UPnP、首启默认值、插件公钥指纹和软件包清单；同时确认只有 `wpad-openssl` 一个 wpad provider，主包使用官方精简 `dnsmasq`，且没有混入 Travelmate、mwan3、VPN、eSIM、PassWall2 专用 kmod、代理核心或代理配置。边界检查还会运行脱敏的凭据扫描和对应回归测试。直接构建需要 64 位 Linux，以及 `curl`、`flock`、GNU Make、OpenSSL、`sha256sum`、GNU tar、`unsquashfs` 和 Zstandard 支持。

OpenWrt Snapshot 下载地址和软件源会滚动更新，固定 ImageBuilder 哈希并不足以复现软件包闭包。本项目用 `scripts/manage-feed-lock.sh` 锁定本次构建实际使用的软件源缓存：

- `capture IMAGEBUILDER_DIR ARTIFACT_DIR BUNDLE`：校验 ImageBuilder revision、236 包安装清单和 `dl/` 缓存，生成确定性 `tar.zst` bundle，并把有序软件源列表、逐文件哈希、安装清单和整包哈希写入 `configs/official-base.repositories.lock`、`official-base.feeds.sha256`、`official-base.manifest.lock` 和 `official-base.feed.env`。
- `verify BUNDLE`：对照 `configs/` 中固定的哈希校验 bundle，拒绝篡改、路径穿越和多余/缺失成员，并解包核对每个文件哈希。
- `materialize BUNDLE [DEST]`：先 `verify`，再原子地产出一个已核验的离线缓存（`dl/` + 有序 `repositories`），供构建断网复用。

边界检查会验证 `configs/official-base.feed.env` 的身份格式，并确认三份 lock 文件与其中固定的哈希一致。设置 `OPENWRT_OFFLINE=1` 后，构建会 `materialize` 该 bundle、把精确缓存与软件源列表注入 ImageBuilder，并在断网容器中复现固件——已验证与联网构建逐字节一致（`sysupgrade.bin` SHA256 相同）。默认仍为联网模式；离线模式需要预先保全 hash 固定的 ImageBuilder 归档和 feed-lock bundle。

另外，`r35420-06c826e335` 对应的官方 SDK 未在本地保留，而 OpenWrt 在线 Snapshot SDK 已滚动到其他 revision。因此在恢复匹配 SDK 或整体更新并同时锁定 ImageBuilder、SDK 和 feeds 之前，不能发布与本基线声称 ABI/工具链匹配的自编译插件。

## GitHub Actions

手动运行“构建 H5000M 官方基础固件”。工作流先执行主包边界检查，再在 GitHub 托管的 `ubuntu-24.04` runner 上调用同一构建脚本，避免维护两套构建逻辑。托管 runner 是原生 x86_64、网络稳定，直接运行 ImageBuilder 宿主工具，无需 Docker 或 Rosetta（容器路径仅用于 Apple Silicon 本地构建）。

产物目录包含：

- `openwrt-mediatek-filogic-hiveton_h5000m-squashfs-sysupgrade.bin`
- `installed-package-manifest.txt`
- `official-base.env`
- `official-base.packages`
- `profiles.json`
- `BUILD-INFO.txt`
- `SHA256SUMS`

每次构建都会把完整安装清单和基线信息放入产物目录，`SHA256SUMS` 覆盖固件和所有发布 sidecar；发布前应核对 `custom_plugins_included=false`、`wpad_provider=wpad-openssl`、固定的 `plugin_key_sha256` 和 `upnp_included=true`。
PassWall2 相关核对项为 `passwall2_included=false`、`passwall2_runtime_prerequisites_included=false` 和 `dnsmasq_variant=compact`。

## 仓库结构

```text
.dockerignore                     最小化容器构建上下文
.github/workflows/build.yml       唯一的主包工作流
Dockerfile                        Ubuntu 24.04 amd64 ImageBuilder 环境
configs/official-base.env         固定官方基线和 ImageBuilder 哈希
configs/official-base.packages    主包软件清单
official-base-files/              最小产品默认值和插件公钥
configs/official-base.feed.env    feed-lock bundle 身份与固定哈希
configs/official-base.repositories.lock  有序官方软件源列表
configs/official-base.feeds.sha256  dl/ 缓存逐文件哈希清单
configs/official-base.manifest.lock 锁定的 236 包安装清单
scripts/check-main-package.sh     主包边界、wpad、公钥和 feed-lock 策略检查
scripts/check-plugin-signing-key.sh  持久化插件签名密钥匹配检查
scripts/check-secrets.sh          脱敏的凭据与私钥扫描
scripts/manage-feed-lock.sh       feed-lock capture/verify/materialize
scripts/build-official-base-docker.sh  OrbStack/Docker 本地构建入口
scripts/build-official-base-local.sh   构建和固件内容验证
tests/test-check-secrets.sh       凭据扫描器回归测试
tests/test-plugin-signing-key.sh  签名密钥拒绝路径测试
```

更新 OpenWrt 基线时，必须同步更新 `official-base.env` 的版本与 ImageBuilder SHA256，并重新完成启动、LAN/WAN、WiFi、LuCI、UPnP、升级和插件安装回归。
