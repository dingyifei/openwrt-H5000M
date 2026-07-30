#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_FILE="${ROOT_DIR}/configs/official-base.packages"
BASE_ENV="${ROOT_DIR}/configs/official-base.env"

required_paths=(
  .dockerignore
  .github/workflows/build.yml
  Dockerfile
  configs/official-base.env
  configs/official-base.feed.env
  configs/official-base.feeds.sha256
  configs/official-base.manifest.lock
  configs/official-base.packages
  configs/official-base.repositories.lock
  official-base-files/etc/apk/keys/h5000m-plugins.pem
  official-base-files/etc/uci-defaults/90-h5000m-base
  scripts/build-official-base-docker.sh
  scripts/build-official-base-local.sh
  scripts/check-plugin-signing-key.sh
  scripts/check-secrets.sh
  scripts/manage-feed-lock.sh
  tests/test-check-secrets.sh
  tests/test-plugin-signing-key.sh
)
for path in "${required_paths[@]}"; do
  [ -f "${ROOT_DIR}/${path}" ] || {
    echo "Missing required main-package file: ${path}" >&2
    exit 1
  }
done

for directory in files packages patches; do
  if [ -d "${ROOT_DIR}/${directory}" ] && \
     find "${ROOT_DIR}/${directory}" \( -type f -o -type l \) -print -quit | grep -q .; then
    echo "Legacy custom source files must not exist in the main package: ${directory}" >&2
    exit 1
  fi
done

# shellcheck source=../configs/official-base.env
source "${BASE_ENV}"
[[ "${OPENWRT_REVISION}" =~ ^r[0-9]+-[0-9a-f]+$ ]]
[[ "${IMAGEBUILDER_SHA256}" =~ ^[0-9a-f]{64}$ ]]
[ "${IMAGEBUILDER_FILE}" = "openwrt-imagebuilder-mediatek-filogic.Linux-x86_64.tar.zst" ]
[ "${OPENWRT_PROFILE}" = "hiveton_h5000m" ]
[ "${OPENWRT_TARGET}" = "mediatek/filogic" ]
[ "${OPENWRT_ARCH}" = "aarch64_cortex-a53" ]
# Kernel and ABI are pinned in configs/official-base.env and MOVE with the snapshot, so
# they are validated by shape, not by value. Hardcoding them duplicated the pin in a second
# place: re-pinning the base to r35533 (kernel 6.18.39) left this asserting 6.18.38, and
# because these are bare [ ] tests under `set -e` the build died with NO message at all -
# silently, before printing a single line. A guard that fails without saying why is worse
# than no guard. The base build itself asserts that the image's real kernel and ABI match
# these values, which is the check that actually matters.
[[ "${OPENWRT_KERNEL}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "OPENWRT_KERNEL is not a kernel version: ${OPENWRT_KERNEL}" >&2; exit 1; }
[[ "${OPENWRT_KERNEL_ABI}" =~ ^[0-9a-f]{32}$ ]] \
  || { echo "OPENWRT_KERNEL_ABI is not a 32-hex ABI hash: ${OPENWRT_KERNEL_ABI}" >&2; exit 1; }
[[ "${H5000M_PLUGIN_KEY_SHA256}" =~ ^[0-9a-f]{64}$ ]]

# The pinned feed-lock environment must carry a coherent, well-formed identity so
# the optional offline build path resolves the exact package closure.
# shellcheck source=../configs/official-base.feed.env
source "${ROOT_DIR}/configs/official-base.feed.env"
[[ "${FEED_LOCK_ID}" =~ ^${OPENWRT_REVISION}-[0-9a-f]{16}$ ]]
[[ "${FEED_LOCK_BUNDLE_FILENAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._+~-]*$ ]]
for feed_hash in FEED_LOCK_BUNDLE_SHA256 FEED_LOCK_REPOSITORIES_SHA256 \
  FEED_LOCK_FEEDS_SHA256 FEED_LOCK_MANIFEST_SHA256; do
  [[ "${!feed_hash}" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Malformed ${feed_hash} in official-base.feed.env" >&2
    exit 1
  }
done
[ "$(sha256sum "${ROOT_DIR}/configs/official-base.repositories.lock" | cut -d' ' -f1)" \
  = "${FEED_LOCK_REPOSITORIES_SHA256}" ] || {
  echo "official-base.repositories.lock does not match the pinned FEED_LOCK_REPOSITORIES_SHA256." >&2
  exit 1
}
[ "$(sha256sum "${ROOT_DIR}/configs/official-base.feeds.sha256" | cut -d' ' -f1)" \
  = "${FEED_LOCK_FEEDS_SHA256}" ] || {
  echo "official-base.feeds.sha256 does not match the pinned FEED_LOCK_FEEDS_SHA256." >&2
  exit 1
}
[ "$(sha256sum "${ROOT_DIR}/configs/official-base.manifest.lock" | cut -d' ' -f1)" \
  = "${FEED_LOCK_MANIFEST_SHA256}" ] || {
  echo "official-base.manifest.lock does not match the pinned FEED_LOCK_MANIFEST_SHA256." >&2
  exit 1
}

package_lines() {
  sed -e 's/#.*//' \
      -e 's/^[[:space:]]*//' \
      -e 's/[[:space:]]*$//' \
      -e '/^$/d' "${PACKAGE_FILE}"
}

duplicates="$(package_lines | sort | uniq -d)"
[ -z "${duplicates}" ] || {
  echo "Duplicate entries in official-base.packages:" >&2
  echo "${duplicates}" >&2
  exit 1
}

has_package() {
  local expected="$1"
  package_lines | grep -Fx -- "${expected}" >/dev/null
}

required_packages=(
  luci luci-ssl luci-i18n-base-zh-cn
  luci-app-package-manager luci-app-upnp luci-i18n-upnp-zh-cn
  miniupnpd-nftables
)
for package in "${required_packages[@]}"; do
  has_package "${package}" || {
    echo "Required package is absent from the main-package list: ${package}" >&2
    exit 1
  }
done

required_wifi_packages=(
  -wpad-basic-mbedtls
  wpad-openssl
)
for package in "${required_wifi_packages[@]}"; do
  has_package "${package}" || {
    echo "Required Wi-Fi provider selection is absent from the main-package list: ${package}" >&2
    exit 1
  }
done

is_wpad_provider() {
  case "$1" in
    wpad|wpad-basic|wpad-basic-*|wpad-mini|wpad-mini-*|wpad-mbedtls|wpad-wolfssl|wpad-openssl)
      return 0
      ;;
  esac
  return 1
}

wpad_providers=()
while IFS= read -r package; do
  case "${package}" in
    -*) continue ;;
  esac
  if is_wpad_provider "${package}"; then
    wpad_providers+=("${package}")
  fi
done < <(package_lines)
if [ "${#wpad_providers[@]}" -ne 1 ] || [ "${wpad_providers[0]:-}" != "wpad-openssl" ]; then
  echo "Exactly one wpad provider must be selected, and it must be wpad-openssl: ${wpad_providers[*]:-(none)}" >&2
  exit 1
fi

is_forbidden_feature_package() {
  case "$1" in
    h5000m-fancontrol|luci-app-h5000m-fancontrol*|luci-app-h5000m-netmode*|luci-app-mt5700m*|\
    travelmate|luci-app-travelmate*|mwan3|luci-app-mwan3*|tailscale|luci-app-tailscale*|\
    openconnect|luci-proto-openconnect*|vpnc-scripts|lpac|luci-app-epm*|\
    dnsmasq-full|kmod-nft-socket|kmod-nft-tproxy|\
    luci-app-passwall*|luci-app-homeproxy*|luci-app-mosdns*|\
    nikki|nikki-*|luci-app-nikki*|luci-i18n-nikki*|mihomo|mihomo-*|v2ray-core|v2ray-core-*|\
    xray-core|xray-core-*|xray-plugin|xray-plugin-*|sing-box|sing-box-*|\
    hysteria|hysteria-*|hysteria2|hysteria2-*|tuic-client|tuic-client-*|naiveproxy|naiveproxy-*|\
    qmodem|qmodem-*|ubus-at-daemon|ubus-at-daemon-*|sms-tool_q|sms-tool_q-*|at-webserver|at-webserver-*)
      return 0
      ;;
  esac
  return 1
}

while IFS= read -r package; do
  case "${package}" in
    -*) continue ;;
  esac
  if is_forbidden_feature_package "${package}"; then
    echo "Plugin-owned package is forbidden in the main package: ${package}" >&2
    exit 1
  fi
done < <(package_lines)

bash -n "${ROOT_DIR}/scripts/build-official-base-docker.sh"
bash -n "${ROOT_DIR}/scripts/build-official-base-local.sh"
bash -n "${ROOT_DIR}/scripts/check-plugin-signing-key.sh"
bash -n "${ROOT_DIR}/scripts/check-secrets.sh"
bash -n "${ROOT_DIR}/scripts/manage-feed-lock.sh"
bash -n "${ROOT_DIR}/tests/test-check-secrets.sh"
bash -n "${ROOT_DIR}/tests/test-plugin-signing-key.sh"
sh -n "${ROOT_DIR}/official-base-files/etc/uci-defaults/90-h5000m-base"
"${ROOT_DIR}/tests/test-check-secrets.sh"
"${ROOT_DIR}/tests/test-plugin-signing-key.sh"
plugin_key="${ROOT_DIR}/official-base-files/etc/apk/keys/h5000m-plugins.pem"
openssl pkey -pubin -in "${plugin_key}" -noout >/dev/null
actual_plugin_key_sha256="$(
  openssl pkey -pubin -in "${plugin_key}" -pubout -outform DER |
    sha256sum |
    cut -d' ' -f1
)"
[ "${actual_plugin_key_sha256}" = "${H5000M_PLUGIN_KEY_SHA256}" ] || {
  echo "The embedded plugin trust anchor does not match the pinned fingerprint." >&2
  exit 1
}

"${ROOT_DIR}/scripts/check-secrets.sh" "${ROOT_DIR}"

if git -C "${ROOT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${ROOT_DIR}" diff --check
fi
echo "Main-package boundary check passed."
