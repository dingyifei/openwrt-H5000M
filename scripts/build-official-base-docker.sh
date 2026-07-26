#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_ROOT="${OPENWRT_LOCAL_CACHE:-${HOME}/.cache/openwrt-H5000M}"
ARTIFACT_ROOT="${OPENWRT_LOCAL_ARTIFACTS:-${ROOT_DIR}/artifacts}"
BUILDER_IMAGE="${OPENWRT_DOCKER_IMAGE:-openwrt-h5000m-imagebuilder:ubuntu-24.04-amd64}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

[ "${HOST_UID}" -ne 0 ] || {
  echo "Run the container build as an unprivileged host user." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || {
  echo "Missing required command: docker" >&2
  exit 1
}
docker info >/dev/null 2>&1 || {
  echo "Docker is unavailable. Start OrbStack or another Docker-compatible engine." >&2
  exit 1
}

mkdir -p "${CACHE_ROOT}" "${ARTIFACT_ROOT}"
CACHE_ROOT="$(cd "${CACHE_ROOT}" && pwd -P)"
ARTIFACT_ROOT="$(cd "${ARTIFACT_ROOT}" && pwd -P)"

docker build \
  --platform linux/amd64 \
  --file "${ROOT_DIR}/Dockerfile" \
  --tag "${BUILDER_IMAGE}" \
  "${ROOT_DIR}"

# Optional "loaded" image: base + signed plugins. The plugin repo lives outside this
# repository, so it needs its own read-only mount, and the in-container path is what the
# build script must see - a host path would be meaningless inside the container.
LOADED_ARGS=()
if [ "${H5000M_LOADED_IMAGE:-0}" = 1 ]; then
  : "${H5000M_PLUGIN_REPO:?H5000M_LOADED_IMAGE=1 requires H5000M_PLUGIN_REPO=<plugins>/offline-repo}"
  [ -d "${H5000M_PLUGIN_REPO}" ] || {
    echo "H5000M_PLUGIN_REPO=${H5000M_PLUGIN_REPO} is not a directory." >&2
    exit 1
  }
  PLUGIN_REPO_ABS="$(cd "${H5000M_PLUGIN_REPO}" && pwd)"
  LOADED_ARGS=(
    --env H5000M_LOADED_IMAGE=1
    --env H5000M_PLUGIN_REPO=/plugin-repo
    --mount "type=bind,source=${PLUGIN_REPO_ABS},target=/plugin-repo,readonly"
  )
fi

docker run --rm --init \
  --platform linux/amd64 \
  --user "${HOST_UID}:${HOST_GID}" \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,exec,nosuid,nodev,mode=1777 \
  --env HOME=/tmp \
  --env OPENWRT_LOCAL_CACHE=/cache \
  --env OPENWRT_LOCAL_ARTIFACTS=/artifacts \
  "${LOADED_ARGS[@]}" \
  --mount "type=bind,source=${ROOT_DIR},target=/workspace,readonly" \
  --mount "type=bind,source=${CACHE_ROOT},target=/cache" \
  --mount "type=bind,source=${ARTIFACT_ROOT},target=/artifacts" \
  --workdir /workspace \
  "${BUILDER_IMAGE}" \
  bash -c '
    set -euo pipefail
    [ "$(uname -m)" = x86_64 ] || {
      echo "Expected an x86_64 ImageBuilder container." >&2
      exit 1
    }
    [ ! -w /workspace ] || {
      echo "The repository mount must be read-only." >&2
      exit 1
    }
    [ -w /cache ] && [ -w /artifacts ] || {
      echo "The cache and artifact mounts must be writable." >&2
      exit 1
    }
    umask 022
    exec ./scripts/build-official-base-local.sh
  '
