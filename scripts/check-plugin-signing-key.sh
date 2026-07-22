#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../configs/official-base.env
source "${ROOT_DIR}/configs/official-base.env"

SIGNING_DIR="${1:-${H5000M_APK_SIGNING_DIR:-${HOME}/.config/h5000m-apk}}"
PRIVATE_KEY="${SIGNING_DIR}/private-key.pem"
PUBLIC_KEY="${SIGNING_DIR}/public-key.pem"
EMBEDDED_KEY="${ROOT_DIR}/official-base-files/etc/apk/keys/h5000m-plugins.pem"

fail() {
  echo "Signing-key check failed: $*" >&2
  exit 1
}

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

file_uid() {
  if stat -c '%u' "$1" >/dev/null 2>&1; then
    stat -c '%u' "$1"
  else
    stat -f '%u' "$1"
  fi
}

public_fingerprint() {
  openssl pkey -pubin -in "$1" -pubout -outform DER 2>/dev/null |
    sha256sum |
    cut -d' ' -f1
}

private_fingerprint() {
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null |
    sha256sum |
    cut -d' ' -f1
}

[ -d "${SIGNING_DIR}" ] || fail "missing persistent signing directory: ${SIGNING_DIR}"
[ ! -L "${SIGNING_DIR}" ] || fail "signing directory must not be a symlink"
[ "$(cd "${SIGNING_DIR}" && pwd)" = "$(cd "${SIGNING_DIR}" && pwd -P)" ] || \
  fail "signing directory path contains a symlink"
[ "$(file_uid "${SIGNING_DIR}")" -eq "$(id -u)" ] || fail "signing directory has the wrong owner"
dir_mode="$(file_mode "${SIGNING_DIR}")"
[ $((8#${dir_mode} & 8#077)) -eq 0 ] || fail "signing directory permissions must be 0700 or stricter"

for key in "${PRIVATE_KEY}" "${PUBLIC_KEY}"; do
  [ -f "${key}" ] || fail "missing key: ${key}"
  [ ! -L "${key}" ] || fail "key must not be a symlink: ${key}"
  [ "$(file_uid "${key}")" -eq "$(id -u)" ] || fail "key has the wrong owner: ${key}"
done
private_mode="$(file_mode "${PRIVATE_KEY}")"
[ $((8#${private_mode} & 8#077)) -eq 0 ] || fail "private key permissions must be 0600 or stricter"

openssl pkey -in "${PRIVATE_KEY}" -check -noout >/dev/null 2>&1 || fail "private key validation failed"
openssl pkey -pubin -in "${PUBLIC_KEY}" -noout >/dev/null 2>&1 || fail "public key validation failed"

private_sha256="$(private_fingerprint "${PRIVATE_KEY}")"
public_sha256="$(public_fingerprint "${PUBLIC_KEY}")"
embedded_sha256="$(public_fingerprint "${EMBEDDED_KEY}")"
[ "${private_sha256}" = "${public_sha256}" ] || fail "private and public keys do not match"
[ "${public_sha256}" = "${embedded_sha256}" ] || fail "signing key does not match the firmware trust anchor"
[ "${embedded_sha256}" = "${H5000M_PLUGIN_KEY_SHA256}" ] || fail "firmware trust anchor is not the pinned key"

printf 'Signing key matches pinned H5000M trust anchor: %s\n' "${public_sha256}"
