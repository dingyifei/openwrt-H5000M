#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plugin-signing-key.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_keypair() {
  local directory="$1"
  mkdir -m 0700 "${directory}"
  openssl ecparam -name prime256v1 -genkey -noout -out "${directory}/private-key.pem" 2>/dev/null
  openssl pkey -in "${directory}/private-key.pem" -pubout -out "${directory}/public-key.pem" 2>/dev/null
  chmod 0600 "${directory}/private-key.pem"
  chmod 0644 "${directory}/public-key.pem"
}

matching="${WORK_DIR}/matching"
make_keypair "${matching}"
cp "${ROOT_DIR}/official-base-files/etc/apk/keys/h5000m-plugins.pem" "${matching}/public-key.pem"

# A generated private key must not be accepted merely because a trusted public key is beside it.
if "${ROOT_DIR}/scripts/check-plugin-signing-key.sh" "${matching}" >/dev/null 2>&1; then
  fail "mismatched private key was accepted"
fi

wrong_mode="${WORK_DIR}/wrong-mode"
make_keypair "${wrong_mode}"
chmod 0644 "${wrong_mode}/private-key.pem"
if "${ROOT_DIR}/scripts/check-plugin-signing-key.sh" "${wrong_mode}" >/dev/null 2>&1; then
  fail "over-permissive private key was accepted"
fi

missing="${WORK_DIR}/missing"
mkdir -m 0700 "${missing}"
if "${ROOT_DIR}/scripts/check-plugin-signing-key.sh" "${missing}" >/dev/null 2>&1; then
  fail "missing key pair was accepted"
fi

printf 'plugin signing-key negative tests passed.\n'
