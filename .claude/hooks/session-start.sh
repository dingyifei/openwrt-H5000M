#!/bin/bash
# SessionStart hook for openwrt-H5000M.
#
# Installs the host tools that scripts/build-official-base-local.sh and
# scripts/check-main-package.sh need but that are not part of a stock
# Ubuntu image, so firmware builds and boundary checks work inside
# Claude Code on the web sessions.
set -euo pipefail

# Only run inside Claude Code on the web (remote) environments. Local
# machines manage their own toolchains.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# The OpenWrt ImageBuilder flow needs these commands. Everything else the
# build script checks for (curl, flock, make, sha256sum, strings, tar) ships
# with the base image already.
#   unsquashfs -> squashfs-tools   (inspect the built rootfs)
#   zstd       -> zstd             (tar --zstd extracts the ImageBuilder)
need_install=0
for cmd in unsquashfs zstd; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    need_install=1
  fi
done

if [ "${need_install}" -eq 0 ]; then
  echo "openwrt-H5000M: build dependencies already present."
  exit 0
fi

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
${SUDO} apt-get update -qq
${SUDO} apt-get install -y --no-install-recommends squashfs-tools zstd

echo "openwrt-H5000M: installed squashfs-tools (unsquashfs) and zstd."
