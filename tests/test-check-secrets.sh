#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER_SOURCE="${ROOT_DIR}/scripts/check-secrets.sh"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/check-secrets.XXXXXX")"
REPO_DIR="${WORK_DIR}/repository"

cleanup() {
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_line() {
  local expected result
  expected="$1"
  result="$2"
  printf '%s\n' "${result}" | grep -Fqx -- "${expected}" || fail "missing finding ${expected}"
}

mkdir -p "${REPO_DIR}/scripts"
cp "${SCANNER_SOURCE}" "${REPO_DIR}/scripts/check-secrets.sh"
chmod +x "${REPO_DIR}/scripts/check-secrets.sh"

git -C "${REPO_DIR}" init -q

private_part='PRI''VATE'
public_part='PUB''LIC'
pgp_part='P''GP'
proxy_scheme='vl''ess'
provider_prefix='g''h'
known_value="${provider_prefix}p_abcdefghijklmnopqrstuvwxyz1234567890"
private_body='redacted-private-material'
assignment_name='API_TOKEN'
literal_value='literal-credential-material'
root_name='ROOT_PASSWORD'
wireless_name='WIFI_PASSWORD'
ci_reference='$'"{{ secrets.API_TOKEN }}"

printf '%s\n%s\n' "-----BEGIN ${private_part} KEY-----" "${private_body}" > "${REPO_DIR}/tracked-private.pem"
printf 'ignored-secret.txt\n' > "${REPO_DIR}/.gitignore"
git -C "${REPO_DIR}" add .gitignore scripts/check-secrets.sh tracked-private.pem
git -C "${REPO_DIR}" -c user.name=test -c user.email=test@example.invalid commit -qm fixtures

printf '%s\n' "-----BEGIN ${pgp_part} ${private_part} KEY BLOCK-----" > "${REPO_DIR}/untracked-container.txt"
printf '%s\n' "${proxy_scheme}://123e4567-e89b-12d3-a456-426614174000@example.invalid:443" > "${REPO_DIR}/untracked-proxy.txt"
printf '%s\n' "${known_value}" > "${REPO_DIR}/untracked-provider.txt"
printf '%s=%s\n' "${assignment_name}" "${literal_value}" > "${REPO_DIR}/untracked-env.sh"
printf 'opaque credential container\n' > "${REPO_DIR}/untracked-credentials.p12"
printf '%s\n' "${known_value}" > "${REPO_DIR}/ignored-secret.txt"

mkdir -p "${REPO_DIR}/artifacts" "${REPO_DIR}/.claude/worktrees/build"
printf '%s\n' "${known_value}" > "${REPO_DIR}/artifacts/skip.txt"
printf '%s\n' "${known_value}" > "${REPO_DIR}/.claude/worktrees/build/skip.txt"
printf '%s\0trailing\n' "${known_value}" > "${REPO_DIR}/binary.bin"
printf '%s\n' "-----BEGIN ${public_part} KEY-----" > "${REPO_DIR}/safe-public.pem"
printf '%s: %s\n' "${assignment_name}" "${ci_reference}" > "${REPO_DIR}/ci-reference.yml"
printf '%s\n' 'PRIVATE_KEY=${SIGNING_DIR}/private-key.pem' > "${REPO_DIR}/referenced-key-path.env"
printf '%s=%s\n%s=%s\n' "${root_name}" root "${wireless_name}" 77778888 > "${REPO_DIR}/public-bootstrap.env"

set +e
result="$("${REPO_DIR}/scripts/check-secrets.sh" "${REPO_DIR}")"
status=$?
set -e
[ "${status}" -eq 1 ] || fail "scanner status was ${status}, expected 1"

require_line 'private-key:tracked-private.pem:1' "${result}"
require_line 'private-key:untracked-container.txt:1' "${result}"
require_line 'proxy-uri:untracked-proxy.txt:1' "${result}"
require_line 'provider-token:untracked-provider.txt:1' "${result}"
require_line 'sensitive-assignment:untracked-env.sh:1' "${result}"
require_line 'credential-filename:untracked-credentials.p12:1' "${result}"

line_count="$(printf '%s\n' "${result}" | awk 'NF { count++ } END { print count + 0 }')"
[ "${line_count}" -eq 6 ] || fail "scanner produced ${line_count} findings, expected 6"

while IFS= read -r record; do
  [[ "${record}" =~ ^(private-key|proxy-uri|provider-token|sensitive-assignment|credential-filename):[^:]+:[1-9][0-9]*$ ]] || \
    fail "scanner output is not category:path:line"
done <<< "${result}"

case "${result}" in
  *"${known_value}"*|*"${private_body}"*|*"${literal_value}"*)
    fail "scanner output exposed a matched value"
    ;;
esac

case "${result}" in
  *ignored-secret.txt*|*artifacts/skip.txt*|*.claude/worktrees/build/skip.txt*|*binary.bin*|\
  *safe-public.pem*|*ci-reference.yml*|*referenced-key-path.env*|*public-bootstrap.env*)
    fail "scanner reported an ignored, skipped, binary, public, or allowed fixture"
    ;;
esac

rm -f \
  "${REPO_DIR}/tracked-private.pem" \
  "${REPO_DIR}/untracked-container.txt" \
  "${REPO_DIR}/untracked-proxy.txt" \
  "${REPO_DIR}/untracked-provider.txt" \
  "${REPO_DIR}/untracked-env.sh" \
  "${REPO_DIR}/untracked-credentials.p12"

set +e
clean_result="$("${REPO_DIR}/scripts/check-secrets.sh" "${REPO_DIR}")"
clean_status=$?
set -e
[ "${clean_status}" -eq 0 ] || fail "scanner reported allowed fixtures after removing positives"
[ -z "${clean_result}" ] || fail "scanner emitted findings for allowed fixtures"

printf 'check-secrets tests passed.\n'
