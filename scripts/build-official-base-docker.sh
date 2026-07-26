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

# Forward the build-mode switches. Without this there is no way to ask the containerised
# build for a PINNED build: the wrapper forwards almost nothing, so OPENWRT_ROLLING set on
# the host never reached the script and every docker build silently tracked the live
# snapshot. That matters on a slow uplink - rolling re-downloads a 553 MB ImageBuilder and
# a 248 MB SDK every time the mirror moves, which is long enough to lose the race and end
# up with base and plugins built against different kernel ABIs.
MODE_ARGS=()
for v in OPENWRT_ROLLING OPENWRT_OFFLINE; do
  eval "val=\${${v}:-}"
  [ -n "${val}" ] && MODE_ARGS+=(--env "${v}=${val}")
done

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
  "${MODE_ARGS[@]}" \
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

    # Stage the repository into writable space with tar, and build from the staged copy.
    #
    # On Apple Silicon the emulated linux/amd64 container MISCOPIES files read from the
    # read-only bind mount: coreutils cp and install produce a file of the correct size
    # with the wrong contents, deterministically (they use the copy_file_range/sendfile
    # fast path, which the emulation gets wrong). cat, tar and dd - plain read/write - are
    # correct. This is not academic: ImageBuilder copies our FILES= payload off that same
    # mount, so a locally built image could ship a corrupted uci-defaults script or, worse,
    # a corrupted /etc/apk/keys trust anchor at exactly the right size, and still pass
    # every presence check the build makes.
    #
    # Building from a writable staged copy makes every downstream cp - ours and
    # ImageBuilder is own - read from a path that copies correctly. The /workspace mount
    # stays read-only, so the guarantee asserted above is unchanged.
    mkdir -p /tmp/repo
    tar -cf - -C /workspace --exclude=./artifacts . | tar -xf - -C /tmp/repo

    # Verify the staged tree byte-for-byte. Silent corruption is the whole risk here, so a
    # copy we did not check is worth very little. md5sum reads normally and is unaffected.
    ( cd /workspace && find . -path ./artifacts -prune -o -type f -print0 | sort -z |
        xargs -0 md5sum ) > /tmp/src.md5
    ( cd /tmp/repo   && find . -path ./artifacts -prune -o -type f -print0 | sort -z |
        xargs -0 md5sum ) > /tmp/stage.md5
    if ! cmp -s /tmp/src.md5 /tmp/stage.md5; then
      echo "Staged repository copy does not match the source tree:" >&2
      diff /tmp/src.md5 /tmp/stage.md5 | head -20 >&2
      exit 1
    fi
    echo "Staged $(wc -l < /tmp/src.md5) files into /tmp/repo; checksums match."

    cd /tmp/repo
    exec ./scripts/build-official-base-local.sh
  '
