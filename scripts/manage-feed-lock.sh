#!/usr/bin/env bash
# Capture, verify, and materialize a byte-exact OpenWrt ImageBuilder package-cache bundle.
#
# OpenWrt's official ImageBuilder resolves packages from rolling snapshot mirrors
# that overwrite files over time, so an identical rebuild is not reproducible by
# default. This tool snapshots the exact package cache (dl/) plus the ordered
# repository list into a deterministic bundle, pins its hashes in configs/, and
# re-materializes a verified offline cache the build can consume without network.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../configs/official-base.env
source "${ROOT_DIR}/configs/official-base.env"
REPOSITORIES_LOCK="${ROOT_DIR}/configs/official-base.repositories.lock"
FEEDS_LOCK="${ROOT_DIR}/configs/official-base.feeds.sha256"
MANIFEST_LOCK="${ROOT_DIR}/configs/official-base.manifest.lock"
FEED_ENV="${ROOT_DIR}/configs/official-base.feed.env"
TAR="${GNU_TAR:-tar}"
SAFE_NAME='[A-Za-z0-9][A-Za-z0-9._+~-]*'
WORK_DIRS=()
STAGE=""

fail() { printf 'feed-lock: %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }
cleanup() {
  local path
  for path in "${WORK_DIRS[@]}"; do rm -rf -- "${path}"; done
  [ -z "${STAGE}" ] || rm -rf -- "${STAGE}"
}
new_work() {
  CURRENT_WORK="$(mktemp -d "${TMPDIR:-/tmp}/manage-feed-lock.XXXXXX")"
  WORK_DIRS+=("${CURRENT_WORK}")
}
trap cleanup EXIT

require_tools() {
  local tool
  for tool in cmp cp cut find grep ln mkdir mktemp mv sha256sum sort tar uniq xargs zstd; do
    command -v "${tool}" >/dev/null || fail "missing required command: ${tool}"
  done
  "${TAR}" --version | grep -q 'GNU tar' || fail 'GNU tar is required (set GNU_TAR if needed)'
}
copy_atomic() {
  local source="$1" destination="$2" temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  cp -- "${source}" "${temporary}"
  mv -f -- "${temporary}" "${destination}"
}
check_cache_names() {
  local dl="$1" path name
  [ -d "${dl}" ] || fail "missing dl directory: ${dl}"
  if find "${dl}" -mindepth 1 ! -type f -print -quit | grep -q .; then
    fail 'dl must contain only regular files'
  fi
  while IFS= read -r -d '' path; do
    name="${path#"${dl}/"}"
    [[ "${name}" =~ ^${SAFE_NAME}$ ]] || fail "unsafe dl filename: ${name}"
  done < <(find "${dl}" -mindepth 1 -type f -print0)
}
write_feed_manifest() {
  local builder="$1" temporary
  temporary="$(mktemp "${FEEDS_LOCK}.tmp.XXXXXX")"
  (
    cd "${builder}"
    LC_ALL=C find dl -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
  ) > "${temporary}"
  [ -s "${temporary}" ] || fail 'dl cache is empty'
  mv -f -- "${temporary}" "${FEEDS_LOCK}"
}
capture() {
  [ "$#" -eq 3 ] || fail 'usage: manage-feed-lock.sh capture IMAGEBUILDER_DIR ARTIFACT_DIR BUNDLE_OUTPUT'
  local builder="$1" artifact="$2" bundle="$3" revision temporary repo_hash feeds_hash manifest_hash bundle_hash lock_id
  require_tools
  [ -f "${builder}/include/version.mk" ] || fail 'ImageBuilder version file is missing'
  revision="$(grep '^REVISION:=' "${builder}/include/version.mk" | cut -d= -f2-)"
  [ "${revision}" = "${OPENWRT_REVISION}" ] || fail "ImageBuilder revision ${revision:-unknown} does not match ${OPENWRT_REVISION}"
  [ -f "${builder}/repositories" ] || fail 'ImageBuilder repositories file is missing'
  [ -f "${artifact}/installed-package-manifest.txt" ] || fail 'installed package manifest is missing'
  [ "$(grep -c ' - ' "${artifact}/installed-package-manifest.txt")" -eq 236 ] || fail 'installed manifest does not contain 236 packages'
  check_cache_names "${builder}/dl"
  copy_atomic "${builder}/repositories" "${REPOSITORIES_LOCK}"
  copy_atomic "${artifact}/installed-package-manifest.txt" "${MANIFEST_LOCK}"
  write_feed_manifest "${builder}"
  mkdir -p "$(dirname "${bundle}")"
  temporary="$(mktemp "${bundle}.tmp.XXXXXX")"
  (
    cd "${builder}"
    ZSTD_NBTHREADS=1 ZSTD_CLEVEL=19 "${TAR}" --format=gnu --sort=name --mtime=@0 \
      --owner=0 --group=0 --numeric-owner --mode=go=rX,u+rwX --zstd -cf "${temporary}" dl
  )
  mv -f -- "${temporary}" "${bundle}"
  repo_hash="$(sha256 "${REPOSITORIES_LOCK}")"
  feeds_hash="$(sha256 "${FEEDS_LOCK}")"
  manifest_hash="$(sha256 "${MANIFEST_LOCK}")"
  bundle_hash="$(sha256 "${bundle}")"
  lock_id="${OPENWRT_REVISION}-$(printf '%s\n%s\n%s\n' "${repo_hash}" "${feeds_hash}" "${manifest_hash}" | sha256sum | cut -c1-16)"
  temporary="$(mktemp "${FEED_ENV}.tmp.XXXXXX")"
  {
    printf '%s\n' '# Pinned feed-cache bundle for the official ImageBuilder baseline.'
    printf '%s\n' '# Regenerate with: scripts/manage-feed-lock.sh capture ...'
    printf '%s\n' \
      "FEED_LOCK_ID=${lock_id}" \
      "FEED_LOCK_BUNDLE_FILENAME=$(basename "${bundle}")" \
      "FEED_LOCK_BUNDLE_SHA256=${bundle_hash}" \
      "FEED_LOCK_REPOSITORIES_SHA256=${repo_hash}" \
      "FEED_LOCK_FEEDS_SHA256=${feeds_hash}" \
      "FEED_LOCK_MANIFEST_SHA256=${manifest_hash}"
  } > "${temporary}"
  mv -f -- "${temporary}" "${FEED_ENV}"
  cat "${FEED_ENV}"
}
load_lock() {
  [ -f "${FEED_ENV}" ] || fail "missing pinned feed environment: ${FEED_ENV}"
  # shellcheck source=../configs/official-base.feed.env
  source "${FEED_ENV}"
  local key value
  for key in FEED_LOCK_ID FEED_LOCK_BUNDLE_FILENAME FEED_LOCK_BUNDLE_SHA256 FEED_LOCK_REPOSITORIES_SHA256 FEED_LOCK_FEEDS_SHA256 FEED_LOCK_MANIFEST_SHA256; do
    value="${!key:-}"
    [ -n "${value}" ] || fail "${key} is not set"
  done
  [[ "${FEED_LOCK_ID}" =~ ^[A-Za-z0-9._-]+$ ]] || fail 'unsafe feed lock id'
  [[ "${FEED_LOCK_BUNDLE_FILENAME}" =~ ^${SAFE_NAME}$ ]] || fail 'unsafe bundle filename'
  for key in FEED_LOCK_BUNDLE_SHA256 FEED_LOCK_REPOSITORIES_SHA256 FEED_LOCK_FEEDS_SHA256 FEED_LOCK_MANIFEST_SHA256; do
    [[ "${!key}" =~ ^[0-9a-f]{64}$ ]] || fail "invalid ${key}"
  done
}
check_lock_hashes() {
  [ "$(sha256 "${REPOSITORIES_LOCK}")" = "${FEED_LOCK_REPOSITORIES_SHA256}" ] || fail 'repository lock hash mismatch'
  [ "$(sha256 "${FEEDS_LOCK}")" = "${FEED_LOCK_FEEDS_SHA256}" ] || fail 'feed manifest hash mismatch'
  [ "$(sha256 "${MANIFEST_LOCK}")" = "${FEED_LOCK_MANIFEST_SHA256}" ] || fail 'installed manifest lock hash mismatch'
}
expected_paths() {
  local output="$1" line hash path
  : > "${output}"
  while IFS= read -r line || [ -n "${line}" ]; do
    hash="${line%% *}"
    path="${line#"${hash}  "}"
    [[ "${hash}" =~ ^[0-9a-f]{64}$ && "${path}" =~ ^dl/${SAFE_NAME}$ && "${line}" = "${hash}  ${path}" ]] || fail 'invalid feed manifest record'
    printf '%s\n' "${path}" >> "${output}"
  done < "${FEEDS_LOCK}"
  [ -s "${output}" ] || fail 'feed manifest is empty'
  LC_ALL=C sort -c "${output}" || fail 'feed manifest paths are not canonically sorted'
  ! uniq -d "${output}" | grep -q . || fail 'feed manifest has duplicate paths'
}
check_archive_members() {
  local bundle="$1" expected="$2" work="$3" member kind seen="${work}/seen" members="${work}/members" types="${work}/types" dl_seen=0
  : > "${seen}"
  "${TAR}" --zstd -tf "${bundle}" > "${members}"
  "${TAR}" --zstd -tvf "${bundle}" > "${types}"
  exec 3<"${types}"
  while IFS= read -r member; do
    IFS= read -r kind <&3 || fail 'archive member/type listing mismatch'
    [ -n "${member}" ] || fail 'archive contains an empty path'
    if [ "${member}" = 'dl/' ]; then
      [ "${dl_seen}" -eq 0 ] || fail 'archive contains duplicate dl directory'
      [ "${kind:0:1}" = d ] || fail 'dl is not a directory'
      dl_seen=1
    else
      grep -Fqx -- "${member}" "${expected}" || fail "unexpected archive member: ${member}"
      [ "${kind:0:1}" = '-' ] || fail "archive member is not a regular file: ${member}"
      grep -Fqx -- "${member}" "${seen}" && fail "archive contains duplicate member: ${member}"
      printf '%s\n' "${member}" >> "${seen}"
    fi
  done < "${members}"
  if IFS= read -r kind <&3; then fail 'archive member/type listing mismatch'; fi
  exec 3<&-
  [ "${dl_seen}" -eq 1 ] || fail 'archive has no dl directory'
  while IFS= read -r member; do grep -Fqx -- "${member}" "${seen}" || fail "archive is missing ${member}"; done < "${expected}"
}
check_repository_indexes() {
  local root="$1" url sum index count=0
  while IFS= read -r url || [ -n "${url}" ]; do
    case "${url}" in ''|'#'*) continue ;; esac
    sum="$(printf '%s' "${url}" | sha256sum | cut -c1-8)"
    index="APKINDEX.${sum}.tar.gz"
    [ -f "${root}/dl/${index}" ] || fail "missing cached index for ${url}"
    count=$((count + 1))
  done < "${REPOSITORIES_LOCK}"
  [ "${count}" -gt 0 ] || fail 'repository lock contains no repositories'
}
verify_bundle() {
  local bundle="$1" output="${2:-}" work expected actual
  require_tools
  load_lock
  [ -f "${bundle}" ] || fail "bundle does not exist: ${bundle}"
  [ "$(basename "${bundle}")" = "${FEED_LOCK_BUNDLE_FILENAME}" ] || fail 'bundle filename does not match the lock'
  check_lock_hashes
  new_work; work="${CURRENT_WORK}"
  cp -- "${bundle}" "${work}/bundle.tar.zst"
  [ "$(sha256 "${work}/bundle.tar.zst")" = "${FEED_LOCK_BUNDLE_SHA256}" ] || fail 'bundle hash mismatch'
  expected="${work}/expected"
  expected_paths "${expected}"
  check_archive_members "${work}/bundle.tar.zst" "${expected}" "${work}"
  if [ -z "${output}" ]; then output="${work}/extract"; else [ ! -e "${output}" ] || fail "verification output already exists: ${output}"; fi
  mkdir -p "${output}"
  "${TAR}" --zstd -xf "${work}/bundle.tar.zst" -C "${output}" --no-same-owner --no-same-permissions
  if find "${output}/dl" -mindepth 1 ! -type f -print -quit | grep -q .; then fail 'extracted dl contains a non-regular file'; fi
  actual="${work}/actual"
  (cd "${output}" && LC_ALL=C find dl -type f -printf '%p\n' | LC_ALL=C sort) > "${actual}"
  cmp -s "${expected}" "${actual}" || fail 'extracted files do not exactly match the feed manifest'
  (cd "${output}" && sha256sum -c "${FEEDS_LOCK}" >/dev/null) || fail 'extracted file hash mismatch'
  check_repository_indexes "${output}"
}
verify() {
  [ "$#" -eq 1 ] || fail 'usage: manage-feed-lock.sh verify BUNDLE'
  verify_bundle "$1"
  printf 'verified: %s\n' "${FEED_LOCK_ID}"
}
# Materialize an offline cache the ImageBuilder can consume directly: a verified
# dl/ package cache plus the byte-identical ordered repositories file. No mirror
# rewriting -- apk resolves each repository's APKINDEX.<hash>.tar.gz and its
# packages straight out of dl/ when the cache is seeded and the network is cut.
materialize() {
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'usage: manage-feed-lock.sh materialize BUNDLE [DEST]'
  local bundle="$1" cache_root destination parent
  load_lock
  cache_root="${OPENWRT_LOCAL_CACHE:-${HOME}/.cache/openwrt-H5000M}"
  destination="${2:-${cache_root}/feed-locks/${FEED_LOCK_ID}}"
  [ ! -e "${destination}" ] || fail "materialization destination already exists: ${destination}"
  parent="$(dirname "${destination}")"
  mkdir -p "${parent}"
  STAGE="$(mktemp -d "${parent}/.${FEED_LOCK_ID}.tmp.XXXXXX")"
  verify_bundle "${bundle}" "${STAGE}/verify"
  mv -- "${STAGE}/verify/dl" "${STAGE}/dl"
  rm -rf -- "${STAGE}/verify"
  cp -- "${REPOSITORIES_LOCK}" "${STAGE}/repositories"
  printf '%s\n' "${FEED_LOCK_ID}" > "${STAGE}/.verified"
  mv -- "${STAGE}" "${destination}"
  STAGE=""
  printf 'materialized: %s\n' "${destination}"
}

case "${1:-}" in
  capture) shift; capture "$@" ;;
  verify) shift; verify "$@" ;;
  materialize) shift; materialize "$@" ;;
  *) fail 'usage: manage-feed-lock.sh {capture|verify|materialize} ...' ;;
esac
