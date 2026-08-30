#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
set -euo pipefail

ingress_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ingress_generation='g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386'
ingress_product="$ingress_repo/core/v1/generations/$ingress_generation/core-ingress.sh"
ingress_schema="$ingress_repo/core/v1/generations/$ingress_generation/modules/schema.jq"
ingress_fixture="$ingress_repo/scripts/test/portable-core-ingress-fixtures.json"
ingress_ledger="$ingress_repo/scripts/test/portable-core-ingress-ledger.tsv"
ingress_manifest="$ingress_repo/ci/required-files.txt"
ingress_host_path="$PATH"
ingress_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-ingress-test.XXXXXX")"
ingress_download=''

cleanup() {
  if [ -n "${PORTABLE_CORE_INGRESS_TEMP:-}" ]; then
    portable_core_ingress_close >/dev/null 2>&1 || true
  fi
  if [ -n "$ingress_download" ] && [ -f "$ingress_download" ]; then
    rm -f -- "$ingress_download"
  fi
  rm -rf -- "$ingress_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

ingress_platform="$(uname -s):$(uname -m)"
case "$ingress_platform" in
  Linux:x86_64)
    ingress_asset='jq-linux64'
    ingress_asset_sha256='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44'
    ;;
  Darwin:x86_64|Darwin:arm64)
    ingress_asset='jq-osx-amd64'
    ingress_asset_sha256='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $ingress_platform" >&2
    exit 1
    ;;
esac

ingress_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$ingress_cache"
ingress_jq="$ingress_cache/$ingress_asset"
if [ ! -f "$ingress_jq" ] ||
   [ "$(sha256_path "$ingress_jq")" != "$ingress_asset_sha256" ]; then
  ingress_download="$(mktemp "$ingress_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$ingress_asset" \
    -o "$ingress_download"
  [ "$(sha256_path "$ingress_download")" = "$ingress_asset_sha256" ] || {
    echo 'FAIL: jq 1.6 release asset digest mismatch' >&2
    exit 1
  }
  chmod 0555 "$ingress_download"
  mv "$ingress_download" "$ingress_jq"
  ingress_download=''
fi
[ "$(sha256_path "$ingress_jq")" = "$ingress_asset_sha256" ] &&
  [ "$("$ingress_jq" --version)" = jq-1.6 ] || {
    echo 'FAIL: pinned jq 1.6 identity check failed' >&2
    exit 1
  }

ingress_proof_bin="$ingress_tmp/proof-bin"
mkdir -p "$ingress_proof_bin"
ln -s "$ingress_jq" "$ingress_proof_bin/jq"
PATH="$ingress_proof_bin:$ingress_host_path"
export PATH

# shellcheck source=/dev/null
source "$ingress_product"

ingress_failures=0
ingress_direct_total=0
ingress_direct_passed=0
ingress_runtime_total=0
ingress_runtime_passed=0
ingress_guard_total=0
ingress_guard_passed=0
ingress_seen_rules="$ingress_tmp/seen-rules"
ingress_seen_tests="$ingress_tmp/seen-tests"
: > "$ingress_seen_rules"
: > "$ingress_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  ingress_failures=$((ingress_failures + 1))
}

mark_rule() {
  printf '%s\n' "$1" >> "$ingress_seen_rules"
}

mark_test() {
  printf '%s\n' "$1" >> "$ingress_seen_tests"
}

expect_failure() {
  local case_id="$1"
  local expected="$2"
  shift 2
  local stdout_file="$ingress_tmp/$case_id.stdout"
  local stderr_file="$ingress_tmp/$case_id.stderr"
  local actual
  ingress_direct_total=$((ingress_direct_total + 1))
  if "$@" >"$stdout_file" 2>"$stderr_file"; then
    fail_case "$case_id unexpectedly succeeded"
    return
  fi
  actual="$(cat "$stderr_file")"
  if [ ! -s "$stdout_file" ] && [ "$actual" = "$expected" ] &&
     [ "$(wc -c < "$stderr_file" | tr -d ' ')" -eq $((${#expected} + 1)) ]; then
    ingress_direct_passed=$((ingress_direct_passed + 1))
  else
    fail_case "$case_id expected exact $expected"
  fi
}

expect_success() {
  local case_id="$1"
  shift
  local stdout_file="$ingress_tmp/$case_id.stdout"
  local stderr_file="$ingress_tmp/$case_id.stderr"
  ingress_direct_total=$((ingress_direct_total + 1))
  if "$@" >"$stdout_file" 2>"$stderr_file" &&
     [ ! -s "$stdout_file" ] && [ ! -s "$stderr_file" ]; then
    ingress_direct_passed=$((ingress_direct_passed + 1))
  else
    fail_case "$case_id expected silent success"
  fi
}

start_ingress() {
  portable_core_ingress_open && portable_core_ingress_begin "${1:-document}"
}

stop_ingress() {
  portable_core_ingress_close
}

canonical_file="$ingress_tmp/canonical.json"
"$ingress_jq" -j '.canonical.bytes' "$ingress_fixture" > "$canonical_file"
expected_digest="$("$ingress_jq" -r '.canonical.sha256' "$ingress_fixture")"

if start_ingress document &&
   [ "$PORTABLE_CORE_INGRESS_GENERATION" = "$ingress_generation" ] &&
   [ "$PORTABLE_CORE_INGRESS_SCHEMA" = "$ingress_schema" ] &&
   [ "$PORTABLE_CORE_INGRESS_MODULE_DIR" = "${ingress_schema%/*}" ]; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'fixed generation and schema paths'
fi
mark_rule portable-core-ingress.fixed-generation
mark_rule portable-core-ingress.fixed-schema-loading

expect_success canonical-snapshot portable_core_ingress_snapshot "$canonical_file"
expect_success canonical-driver portable_core_ingress_finish_driver
if [ "$PORTABLE_CORE_INGRESS_SHA256" = "$expected_digest" ] &&
   cmp -s "$canonical_file" "$PORTABLE_CORE_INGRESS_SNAPSHOT"; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'snapshot digest and bytes differ'
fi
mark_rule portable-core-ingress.snapshot-sha256
if "$ingress_jq" -e --arg digest "$expected_digest" \
    '.mode == "document" and (.docs|length) == 1 and
     .docs[0].content == {a:1,text:"é"} and .docs[0].sha256 == $digest' \
    "$PORTABLE_CORE_INGRESS_DRIVER" >/dev/null; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'driver does not bind the accepted snapshot and digest'
fi
mark_rule portable-core-ingress.driver-snapshot
mark_rule portable-core-ingress.bounded-snapshot
mark_test portable-core-ingress.test.legacy-278-unmutated-mktemp-path-still-succeeds
stop_ingress
mark_rule portable-core-ingress.private-temp

empty_file="$ingress_tmp/empty.json"
multi_file="$ingress_tmp/multi.json"
bom_file="$ingress_tmp/bom.json"
utf8_file="$ingress_tmp/invalid-utf8.json"
duplicate_file="$ingress_tmp/duplicate.json"
whitespace_file="$ingress_tmp/whitespace.json"
escape_file="$ingress_tmp/escape.json"
no_lf_file="$ingress_tmp/no-lf.json"
extra_lf_file="$ingress_tmp/extra-lf.json"
unsorted_file="$ingress_tmp/unsorted.json"
nan_file="$ingress_tmp/nan.json"
infinity_file="$ingress_tmp/infinity.json"
negative_infinity_file="$ingress_tmp/negative-infinity.json"
leading_plus_file="$ingress_tmp/leading-plus.json"
leading_zero_file="$ingress_tmp/leading-zero.json"
trailing_dot_file="$ingress_tmp/trailing-dot.json"
leading_dot_file="$ingress_tmp/leading-dot.json"
: > "$empty_file"
printf '{}\n{}\n' > "$multi_file"
printf '\357\273\277{}\n' > "$bom_file"
printf '\200\n' > "$utf8_file"
printf '{"a":1,"a":2}\n' > "$duplicate_file"
printf '{ "a": 1 }\n' > "$whitespace_file"
printf '{"x":"\\u0061"}\n' > "$escape_file"
printf '{}' > "$no_lf_file"
printf '{}\n\n' > "$extra_lf_file"
printf '{"b":1,"a":2}\n' > "$unsorted_file"
printf 'NaN\n' > "$nan_file"
printf 'Infinity\n' > "$infinity_file"
printf '%s\n' -Infinity > "$negative_infinity_file"
printf '+1\n' > "$leading_plus_file"
printf '01\n' > "$leading_zero_file"
printf '1.\n' > "$trailing_dot_file"
printf '.1\n' > "$leading_dot_file"

start_ingress document
expect_failure unreadable-input E_RUNTIME portable_core_ingress_snapshot \
  "$ingress_tmp/distinctive-missing-input-SECRET.json"
stop_ingress

document_finish_failure() {
  local case_id="$1"
  local expected="$2"
  local input_file="$3"
  start_ingress document
  portable_core_ingress_snapshot "$input_file"
  expect_failure "$case_id" "$expected" portable_core_ingress_finish_driver
  stop_ingress
}

document_finish_failure empty-input E_PARSE "$empty_file"
mark_test portable-core-ingress.test.legacy-041-empty-input
document_finish_failure multi-root E_PARSE "$multi_file"
mark_test portable-core-ingress.test.legacy-043-multi-root-stream
document_finish_failure bom-prefix E_CANONICAL "$bom_file"
mark_test portable-core-ingress.test.legacy-045-bom-prefix
document_finish_failure invalid-utf8 E_PARSE "$utf8_file"
mark_test portable-core-ingress.test.legacy-047-invalid-utf-8
document_finish_failure duplicate-keys E_CANONICAL "$duplicate_file"
mark_test portable-core-ingress.test.legacy-049-duplicate-keys-non-canonical
document_finish_failure alternate-whitespace E_CANONICAL "$whitespace_file"
mark_test portable-core-ingress.test.legacy-051-alternate-whitespace-non-canonical
document_finish_failure alternate-escaping E_CANONICAL "$escape_file"
mark_test portable-core-ingress.test.legacy-053-alternate-escaping-non-canonical
document_finish_failure missing-final-lf E_CANONICAL "$no_lf_file"
mark_test portable-core-ingress.test.legacy-055-missing-final-lf-non-canonical
document_finish_failure extra-final-lf E_CANONICAL "$extra_lf_file"
mark_test portable-core-ingress.test.legacy-057-extra-final-lf-non-canonical
document_finish_failure unsorted-keys E_CANONICAL "$unsorted_file"
mark_test portable-core-ingress.test.legacy-059-unsorted-keys-non-canonical
document_finish_failure non-json-nan E_PARSE "$nan_file"
document_finish_failure non-json-infinity E_PARSE "$infinity_file"
document_finish_failure non-json-negative-infinity E_PARSE "$negative_infinity_file"
document_finish_failure non-json-leading-plus E_PARSE "$leading_plus_file"
document_finish_failure non-json-leading-zero E_PARSE "$leading_zero_file"
document_finish_failure non-json-trailing-dot E_PARSE "$trailing_dot_file"
document_finish_failure non-json-leading-dot E_PARSE "$leading_dot_file"
mark_rule portable-core-ingress.snapshot-readable
mark_rule portable-core-ingress.single-root-json
mark_rule portable-core-ingress.utf8-json
mark_rule portable-core-ingress.canonical-bytes
mark_rule portable-core-ingress.sanitized-errors
mark_test portable-core-ingress.test.legacy-081-sanitized-input-diagnostics

python3 - "$ingress_tmp/at-limit.json" "$ingress_tmp/over-limit.json" <<'PY'
import sys
items = ([b'a' * 8192] * 127) + [b'b' * 7806]
payload = b'["' + b'","'.join(items) + b'"]\n'
assert len(payload) == 1048576
open(sys.argv[1], 'wb').write(payload)
open(sys.argv[2], 'wb').write(payload + b'x')
PY
[ "$(wc -c < "$ingress_tmp/at-limit.json" | tr -d ' ')" -eq 1048576 ]
[ "$(wc -c < "$ingress_tmp/over-limit.json" | tr -d ' ')" -eq 1048577 ]

start_ingress document
expect_success at-limit-snapshot portable_core_ingress_snapshot "$ingress_tmp/at-limit.json"
expect_success at-limit-driver portable_core_ingress_finish_driver
stop_ingress
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/over-limit.json"
expect_failure over-limit E_LIMIT portable_core_ingress_finish_driver
stop_ingress
mark_rule portable-core-ingress.raw-byte-limit
mark_test portable-core-ingress.test.legacy-063-one-byte-over-the-1-048-576-limit

start_ingress profile-set
portable_core_ingress_snapshot "$empty_file"
portable_core_ingress_snapshot "$ingress_tmp/over-limit.json"
expect_failure multi-limit-before-parse E_LIMIT portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$whitespace_file"
portable_core_ingress_snapshot "$empty_file"
expect_failure multi-parse-before-canonical E_PARSE portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$ingress_tmp/over-limit.json"
expect_failure multi-runtime-before-limit E_RUNTIME portable_core_ingress_snapshot \
  "$ingress_tmp/missing-later-input-SECRET.json"
stop_ingress

snapshot_original="$ingress_tmp/snapshot-original.json"
printf '{"v":1}\n' > "$snapshot_original"
snapshot_original_digest="$(sha256_path "$snapshot_original")"
start_ingress document
expect_success one-bounded-read portable_core_ingress_snapshot "$snapshot_original"
printf '{"v":2}\n' > "$snapshot_original"
expect_success finish-preserved-snapshot portable_core_ingress_finish_driver
if "$ingress_jq" -e --arg digest "$snapshot_original_digest" \
    '.docs == [{content:{v:1},sha256:$digest}]' \
    "$PORTABLE_CORE_INGRESS_DRIVER" >/dev/null; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'driver reread mutable caller input'
fi
stop_ingress

route_one="$ingress_tmp/route-1.json"
route_two="$ingress_tmp/route-2.json"
route_three="$ingress_tmp/route-3.json"
route_four="$ingress_tmp/route-4.json"
printf '{"index":1}\n' > "$route_one"
printf '{"index":2}\n' > "$route_two"
printf '{"index":3}\n' > "$route_three"
printf '{"index":4}\n' > "$route_four"

route_driver_case() {
  local mode="$1"
  local expected_count="$2"
  shift 2
  local route_input
  start_ingress "$mode"
  for route_input in "$@"; do
    portable_core_ingress_snapshot "$route_input"
  done
  portable_core_ingress_finish_driver
  if "$ingress_jq" -e --arg mode "$mode" --argjson count "$expected_count" \
      '.mode == $mode and (.docs|length) == $count and
       [.docs[].content.index] == [range(1;($count+1))]' \
      "$PORTABLE_CORE_INGRESS_DRIVER" >/dev/null; then
    ingress_direct_total=$((ingress_direct_total + 1))
    ingress_direct_passed=$((ingress_direct_passed + 1))
  else
    ingress_direct_total=$((ingress_direct_total + 1))
    fail_case "$mode route did not preserve mode, count, and input order"
  fi
  stop_ingress
}

route_driver_case document 1 "$route_one"
route_driver_case profile-set 4 "$route_one" "$route_two" "$route_three" "$route_four"
route_driver_case stage-run 3 "$route_one" "$route_two" "$route_three"

route_failure_case() {
  local mode="$1"
  local missing_position="$2"
  local supplied_count="$3"
  local route_index
  start_ingress "$mode"
  for ((route_index = 1; route_index <= supplied_count; route_index++)); do
    if [ "$route_index" -eq "$missing_position" ]; then
      expect_failure "route-$mode-missing-$route_index" E_RUNTIME \
        portable_core_ingress_snapshot "$ingress_tmp/route-missing-$route_index-SECRET.json"
      break
    fi
    portable_core_ingress_snapshot "$ingress_tmp/route-$route_index.json"
  done
  stop_ingress
}

route_failure_case document 1 1
for route_position in 1 2 3 4; do
  route_failure_case profile-set "$route_position" 4
done
for route_position in 1 2 3; do
  route_failure_case stage-run "$route_position" 3
done
mark_rule portable-core-ingress.command-routes
mark_test portable-core-ingress.test.legacy-039-validate-profile-set-unreadable-input

runtime_failure() {
  local case_id="$1"
  local expected="$2"
  shift 2
  ingress_runtime_total=$((ingress_runtime_total + 1))
  expect_failure "$case_id" "$expected" "$@"
  if [ "$(cat "$ingress_tmp/$case_id.stderr")" = "$expected" ]; then
    ingress_runtime_passed=$((ingress_runtime_passed + 1))
  fi
}

start_ingress document
real_head="$PORTABLE_CORE_INGRESS_HEAD"
head_log="$ingress_tmp/head-arguments"
logged_head="$ingress_tmp/logged-head"
printf '%s\n' '#!/bin/sh' \
  "printf '%s\\n' \"\$*\" >> \"$head_log\"" \
  "exec \"$real_head\" \"\$@\"" > "$logged_head"
chmod +x "$logged_head"
PORTABLE_CORE_INGRESS_HEAD="$logged_head"
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
if [ "$(wc -l < "$head_log" | tr -d ' ')" -eq 1 ] &&
   [ "$(cat "$head_log")" = "-c 1048577 -- $canonical_file" ]; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'snapshot was not one bounded 1,048,577-byte read'
fi
stop_ingress

start_ingress document
head_failure="$ingress_tmp/head-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "head SECRET path" >&2' 'exit 1' > "$head_failure"
chmod +x "$head_failure"
PORTABLE_CORE_INGRESS_HEAD="$head_failure"
runtime_failure bounded-read-failure E_RUNTIME portable_core_ingress_snapshot "$canonical_file"
stop_ingress
start_ingress document
wc_failure="$ingress_tmp/wc-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "wc SECRET path" >&2' 'exit 1' > "$wc_failure"
chmod +x "$wc_failure"
PORTABLE_CORE_INGRESS_WC="$wc_failure"
runtime_failure byte-count-failure E_RUNTIME portable_core_ingress_snapshot "$canonical_file"
stop_ingress

fake_jq_bin="$ingress_tmp/fake-jq-bin"
mkdir -p "$fake_jq_bin"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then printf "%s\\n" jq-1.7; exit 0; fi' \
  'exit 99' > "$fake_jq_bin/jq"
chmod +x "$fake_jq_bin/jq"
runtime_failure non-jq-1-6 E_RUNTIME env PATH="$fake_jq_bin:$ingress_host_path" \
  bash -c 'source "$1"; portable_core_ingress_open' _ "$ingress_product"
mark_rule portable-core-ingress.jq-version
mark_test portable-core-ingress.test.legacy-267-non-1-6-jq-on-path-is-rejected

make_isolated_bin() {
  local destination="$1"
  local tool
  local tool_path
  mkdir -p "$destination"
  ln -s "$ingress_jq" "$destination/jq"
  for tool in dirname head wc cmp cat rm mktemp; do
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$destination/$tool"
  done
}

no_sha_bin="$ingress_tmp/no-sha-bin"
make_isolated_bin "$no_sha_bin"
runtime_failure missing-sha E_RUNTIME env PATH="$no_sha_bin" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$ingress_product"
mark_test portable-core-ingress.test.legacy-272-missing-sha-tool-to-e-runtime

mktemp_fail_bin="$ingress_tmp/mktemp-fail-bin"
make_isolated_bin "$mktemp_fail_bin"
rm "$mktemp_fail_bin/mktemp"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n" "mktemp SECRET /private/caller/path" >&2' \
  'exit 1' > "$mktemp_fail_bin/mktemp"
chmod +x "$mktemp_fail_bin/mktemp"
sha_real="$(command -v shasum || command -v sha256sum)"
case "${sha_real##*/}" in
  shasum) ln -s "$sha_real" "$mktemp_fail_bin/shasum" ;;
  sha256sum) ln -s "$sha_real" "$mktemp_fail_bin/sha256sum" ;;
esac
runtime_failure mktemp-failure E_RUNTIME env PATH="$mktemp_fail_bin" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$ingress_product"
mark_rule portable-core-ingress.private-temp-errors-sanitized
mark_test portable-core-ingress.test.mktemp-failure-sanitized-e-runtime
mark_test portable-core-ingress.test.legacy-275-mktemp-failure-sanitized

sha256_bin="$ingress_tmp/sha256-bin"
make_isolated_bin "$sha256_bin"
case "${sha_real##*/}" in
  shasum)
    printf '%s\n' '#!/bin/sh' \
      "exec \"$sha_real\" -a 256 \"\${2}\"" > "$sha256_bin/sha256sum"
    ;;
  sha256sum)
    printf '%s\n' '#!/bin/sh' \
      "exec \"$sha_real\" -- \"\${2}\"" > "$sha256_bin/sha256sum"
    ;;
esac
chmod +x "$sha256_bin/sha256sum"
PATH="$sha256_bin" portable_core_ingress_open
portable_core_ingress_begin document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
sha256_backend_digest="$PORTABLE_CORE_INGRESS_SHA256"
sha256_backend_name="$PORTABLE_CORE_INGRESS_SHA_BACKEND"
portable_core_ingress_close

shasum_bin="$ingress_tmp/shasum-bin"
make_isolated_bin "$shasum_bin"
case "${sha_real##*/}" in
  shasum) ln -s "$sha_real" "$shasum_bin/shasum" ;;
  sha256sum)
    printf '%s\n' '#!/bin/sh' \
      "exec \"$sha_real\" -- \"\${4}\"" > "$shasum_bin/shasum"
    chmod +x "$shasum_bin/shasum"
    ;;
esac
PATH="$shasum_bin" portable_core_ingress_open
portable_core_ingress_begin document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
shasum_backend_digest="$PORTABLE_CORE_INGRESS_SHA256"
shasum_backend_name="$PORTABLE_CORE_INGRESS_SHA_BACKEND"
portable_core_ingress_close
if [ "$sha256_backend_name" = sha256sum ] && [ "$shasum_backend_name" = shasum ] &&
   [ "$sha256_backend_digest" = "$expected_digest" ] &&
   [ "$shasum_backend_digest" = "$expected_digest" ]; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'selected SHA-256 backends disagree'
fi
mark_rule portable-core-ingress.sha256-tool
mark_test portable-core-ingress.test.legacy-274-sha256-backend-portability

start_ingress document
sha_failure="$ingress_tmp/sha-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "sha SECRET path" >&2' 'exit 1' > "$sha_failure"
chmod +x "$sha_failure"
PORTABLE_CORE_INGRESS_SHA="$sha_failure"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure sha-command-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress
start_ingress document
sha_empty="$ingress_tmp/sha-empty"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$sha_empty"
chmod +x "$sha_empty"
PORTABLE_CORE_INGRESS_SHA="$sha_empty"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure sha-empty-digest E_RUNTIME portable_core_ingress_finish_driver
stop_ingress
start_ingress document
sha_multiline="$ingress_tmp/sha-multiline"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\\n%s\\n" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  file" "extra"' \
  > "$sha_multiline"
chmod +x "$sha_multiline"
PORTABLE_CORE_INGRESS_SHA="$sha_multiline"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure sha-multiline-digest E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
parser_probe_fail="$ingress_tmp/parser-probe-fail"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "parser SECRET path" >&2' 'exit 2' > "$parser_probe_fail"
chmod +x "$parser_probe_fail"
PORTABLE_CORE_INGRESS_JQ="$parser_probe_fail"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure parser-probe-runtime-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
real_ingress_jq="$PORTABLE_CORE_INGRESS_JQ"
lexer_probe_fail="$ingress_tmp/lexer-probe-fail"
printf '%s\n' '#!/bin/sh' \
  'case " $* " in *" -Rse "*) printf "%s\\n" "lexer SECRET path" >&2; exit 2 ;; esac' \
  "exec \"$real_ingress_jq\" \"\$@\"" > "$lexer_probe_fail"
chmod +x "$lexer_probe_fail"
PORTABLE_CORE_INGRESS_JQ="$lexer_probe_fail"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure lexer-probe-runtime-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
jq_canonical_fail="$ingress_tmp/jq-canonical-fail"
printf '%s\n' '#!/bin/sh' \
  'case " $* " in *" -s -e "*|*" -Rse "*) exit 0 ;; esac' \
  'printf "%s\\n" "jq SECRET path" >&2' \
  'exit 1' > "$jq_canonical_fail"
chmod +x "$jq_canonical_fail"
PORTABLE_CORE_INGRESS_JQ="$jq_canonical_fail"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure canonicalizer-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
cmp_failure="$ingress_tmp/cmp-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "cmp SECRET path" >&2' 'exit 2' > "$cmp_failure"
chmod +x "$cmp_failure"
PORTABLE_CORE_INGRESS_CMP="$cmp_failure"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure cmp-operational-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

write_failure_case() {
  local case_id="$1"
  local target_kind="$2"
  start_ingress document
  case "$target_kind" in
    raw) mkdir "$PORTABLE_CORE_INGRESS_TEMP/raw.1" ;;
    canonical) mkdir "$PORTABLE_CORE_INGRESS_TEMP/canonical.1" ;;
    contents)
      rm "$PORTABLE_CORE_INGRESS_CONTENTS"
      mkdir "$PORTABLE_CORE_INGRESS_CONTENTS"
      ;;
    hashes)
      rm "$PORTABLE_CORE_INGRESS_HASHES"
      mkdir "$PORTABLE_CORE_INGRESS_HASHES"
      ;;
  esac
  if [ "$target_kind" = raw ]; then
    runtime_failure "$case_id" E_RUNTIME portable_core_ingress_snapshot "$canonical_file"
  else
    portable_core_ingress_snapshot "$canonical_file"
    runtime_failure "$case_id" E_RUNTIME portable_core_ingress_finish_driver
  fi
  stop_ingress
}

portable_core_ingress_open
mkdir "$PORTABLE_CORE_INGRESS_TEMP/contents.ndjson"
runtime_failure contents-truncate-failure E_RUNTIME portable_core_ingress_begin document
stop_ingress
portable_core_ingress_open
mkdir "$PORTABLE_CORE_INGRESS_TEMP/hashes.ndjson"
runtime_failure hashes-truncate-failure E_RUNTIME portable_core_ingress_begin document
stop_ingress
write_failure_case raw-write-failure raw
write_failure_case canonical-write-failure canonical
write_failure_case contents-append-failure contents
write_failure_case hashes-append-failure hashes

start_ingress document
cleanup_temp="$PORTABLE_CORE_INGRESS_TEMP"
cleanup_real_rm="$PORTABLE_CORE_INGRESS_RM"
cleanup_fail="$ingress_tmp/cleanup-fail"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "rm SECRET path" >&2' 'exit 1' > "$cleanup_fail"
chmod +x "$cleanup_fail"
PORTABLE_CORE_INGRESS_RM="$cleanup_fail"
runtime_failure cleanup-failure E_RUNTIME portable_core_ingress_close
PORTABLE_CORE_INGRESS_RM="$cleanup_real_rm"
"$cleanup_real_rm" -rf -- "$cleanup_temp"
PORTABLE_CORE_INGRESS_TEMP=''

start_ingress document
portable_core_ingress_snapshot "$canonical_file"
mkdir "$PORTABLE_CORE_INGRESS_TEMP/driver.json"
runtime_failure driver-write-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress
mark_test portable-core-ingress.test.private-temp-write-failures-sanitized-e-runtime

package_copy="$ingress_tmp/package-copy"
package_generation_dir="$package_copy/core/v1/generations/$ingress_generation"
mkdir -p "$package_generation_dir/modules"
cp "$ingress_product" "$package_generation_dir/core-ingress.sh"
cp "$ingress_schema" "$package_generation_dir/modules/schema.jq"
package_product="$package_generation_dir/core-ingress.sh"
package_root="$package_generation_dir/contracts.jq"

printf '%s\n' 'import "schema" as schema;' \
  'if (.docs[0].content | schema::parsed_limits_ok | not) then "E_LIMIT"' \
  'elif (.docs[0].content | schema::document_envelope_ok | not) then "E_SHAPE"' \
  'else empty end' \
  > "$package_root"
# shellcheck source=/dev/null
source "$package_product"
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/at-limit.json"
portable_core_ingress_finish_driver
expect_failure at-limit-reaches-validator E_SHAPE portable_core_ingress_validate
stop_ingress
mark_test portable-core-ingress.test.legacy-061-at-exact-1-048-576-byte-boundary-is-still-just-a-shape-failure-not-e-limit

printf '%s\n' 'import "schema" as schema;' \
  'if schema::semantic_identity == "core.contracts.v1" then empty else error("identity") end' \
  > "$package_root"
poison_home="$ingress_tmp/poison-home"
poison_cwd="$ingress_tmp/poison-cwd"
mkdir -p "$poison_home/.jq" "$poison_cwd"
printf '%s\n' 'def semantic_identity: "poison";' > "$poison_home/.jq/schema.jq"
printf '%s\n' 'def semantic_identity: "poison";' > "$poison_cwd/schema.jq"
(
  cd "$poison_cwd"
  HOME="$poison_home" JQ_LIBRARY_PATH="$poison_cwd" start_ingress document
  portable_core_ingress_snapshot "$canonical_file"
  portable_core_ingress_finish_driver
  expect_success fixed-module-validator portable_core_ingress_validate
  stop_ingress
)

printf '%s\n' 'error("validator SECRET /private/path")' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-nonzero E_RUNTIME portable_core_ingress_validate
stop_ingress
printf '%s\n' '["E_SHAPE","E_REF"][]' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-extra-output E_RUNTIME portable_core_ingress_validate
stop_ingress
printf '%s\n' '"UNKNOWN"' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-unknown-token E_RUNTIME portable_core_ingress_validate
stop_ingress
printf '%s\n' '"E_SHAPE\n"' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-extra-newline E_RUNTIME portable_core_ingress_validate
stop_ingress
printf '%s\n' 'empty' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
mkdir "$PORTABLE_CORE_INGRESS_TEMP/validator.out"
runtime_failure validator-output-write E_RUNTIME portable_core_ingress_validate
stop_ingress

root_target="$ingress_tmp/root-target.jq"
printf '%s\n' 'empty' > "$root_target"
rm "$package_root"
ln -s "$root_target" "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-root-symlink E_RUNTIME portable_core_ingress_validate
stop_ingress
rm "$package_root"
printf '%s\n' 'empty' > "$package_root"

mv "$package_generation_dir/modules/schema.jq" "$package_generation_dir/modules/schema-real.jq"
ln -s schema-real.jq "$package_generation_dir/modules/schema.jq"
runtime_failure schema-symlink E_RUNTIME env PATH="$ingress_proof_bin:$ingress_host_path" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$package_product"
rm "$package_generation_dir/modules/schema.jq"
mv "$package_generation_dir/modules/schema-real.jq" "$package_generation_dir/modules/schema.jq"

mv "$package_generation_dir/modules" "$package_generation_dir/modules-real"
ln -s modules-real "$package_generation_dir/modules"
runtime_failure module-directory-symlink E_RUNTIME env PATH="$ingress_proof_bin:$ingress_host_path" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$package_product"
rm "$package_generation_dir/modules"
mv "$package_generation_dir/modules-real" "$package_generation_dir/modules"

mv "$package_product" "$package_generation_dir/core-ingress-real.sh"
ln -s core-ingress-real.sh "$package_product"
runtime_failure ingress-library-symlink E_RUNTIME env PATH="$ingress_proof_bin:$ingress_host_path" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$package_product"
mark_rule portable-core-ingress.validator-boundary

# shellcheck source=/dev/null
source "$ingress_product"

guard_paths="$ingress_tmp/generation-files"
find "$ingress_repo/core/v1/generations/$ingress_generation" -type f -print |
  sed "s#^$ingress_repo/##" | LC_ALL=C sort > "$guard_paths"
expected_generation_files="core/v1/generations/$ingress_generation/core-ingress.sh
core/v1/generations/$ingress_generation/modules/schema.jq"
if [ "$(cat "$guard_paths")" = "$expected_generation_files" ] &&
   [ ! -e "$ingress_repo/scripts/core-contract.sh" ] &&
   [ ! -e "$ingress_repo/core/v1/generations/$ingress_generation/contracts.jq" ] &&
   [ -z "$(find "$ingress_repo/core/v1/generations/$ingress_generation" -type l -print -quit)" ]; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'private generation guard'
fi
if [ "$(git -C "$ingress_repo" ls-tree HEAD \
       "core/v1/generations/$ingress_generation/modules/schema.jq" | awk '{print $3}')" = \
       fd3924d414a7d620c2bf5de919a45c2599d572ec ] &&
   [ "$(git -C "$ingress_repo" ls-tree HEAD core/v1/generation-registry.json | awk '{print $3}')" = \
       5e113105777694a280166e71d31efd19752e9562 ]; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'schema G3 export or registry OID moved'
fi
mark_rule portable-core-ingress.private-activation-guard

required_paths="core/v1/generations/$ingress_generation/core-ingress.sh
scripts/test/portable-core-ingress-fixtures.json
scripts/test/portable-core-ingress-ledger.tsv
scripts/test/portable-core-ingress.test.sh"
manifest_ok=true
while IFS= read -r required_path; do
  [ "$(grep -Fxc "$required_path" "$ingress_manifest" || true)" -eq 1 ] &&
    [ -f "$ingress_repo/$required_path" ] || manifest_ok=false
done <<< "$required_paths"
if [ "$manifest_ok" = true ]; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'restore manifest coverage'
fi
manifest_prefix="$ingress_tmp/current-manifest-prefix"
manifest_base_lines="$("$ingress_jq" -r '.metadata.prior_manifest_lines' "$ingress_fixture")"
manifest_base_digest="$("$ingress_jq" -r '.metadata.prior_manifest_sha256' "$ingress_fixture")"
manifest_block_start=$((manifest_base_lines + 1))
manifest_block_end=$((manifest_base_lines + 4))

ingress_manifest_block_ok() {
  local candidate_manifest="$1"
  head -n "$manifest_base_lines" "$candidate_manifest" > "$manifest_prefix"
  [ "$(sha256_path "$manifest_prefix")" = "$manifest_base_digest" ] &&
    [ "$(sed -n "${manifest_block_start},${manifest_block_end}p" "$candidate_manifest")" = \
      "$required_paths" ]
}

if ingress_manifest_block_ok "$ingress_manifest"; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'restore manifest is not an exact append'
fi
growing_manifest="$ingress_tmp/growing-manifest"
cp "$ingress_manifest" "$growing_manifest"
printf '%s\n' 'scripts/test/future-portable-core-unit.test.sh' >> "$growing_manifest"
if ingress_manifest_block_ok "$growing_manifest"; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'restore manifest proof rejected a later append'
fi
mark_rule portable-core-ingress.restore-manifest

mark_test portable-core-ingress.test.mktemp-failure-sanitized-e-runtime
mark_test portable-core-ingress.test.private-temp-write-failures-sanitized-e-runtime

review_digest="$("$ingress_jq" -r '.metadata.review_source_sha256' "$ingress_fixture")"
legacy_digest="$("$ingress_jq" -r '.metadata.legacy_source_sha256' "$ingress_fixture")"
mapping_digest="$("$ingress_jq" -r '.metadata.ingress_mapping_sha256' "$ingress_fixture")"
if [ "$review_digest" != 31793a3ad42acf4df117ea158a78738e056bae550269483870487c3e146b27f9 ] ||
   [ "$legacy_digest" != 3d5a6fb192f9bcaba5c4b89314d30f88a03b9d8a1e1e634297c267b14f096092 ] ||
   [ "$(sha256_path "$ingress_ledger")" != "$mapping_digest" ]; then
  fail_case 'ledger checksum mismatch'
fi
"$ingress_jq" -r '.metadata.review_row_ids[]' "$ingress_fixture" |
  LC_ALL=C sort > "$ingress_tmp/source-review-ids"
"$ingress_jq" -r '.metadata.legacy_row_ids[]' "$ingress_fixture" |
  LC_ALL=C sort > "$ingress_tmp/source-legacy-ids"
awk -F '\t' 'NR > 1 && $1 == "review" {print $2}' "$ingress_ledger" |
  LC_ALL=C sort > "$ingress_tmp/local-review-ids"
awk -F '\t' 'NR > 1 && $1 == "legacy" {print $2}' "$ingress_ledger" |
  LC_ALL=C sort > "$ingress_tmp/local-legacy-ids"
cmp -s "$ingress_tmp/source-review-ids" "$ingress_tmp/local-review-ids" ||
  fail_case 'review ledger row set mismatch'
cmp -s "$ingress_tmp/source-legacy-ids" "$ingress_tmp/local-legacy-ids" ||
  fail_case 'legacy ledger row set mismatch'

expected_rules="$ingress_tmp/expected-rules"
"$ingress_jq" -r '.owned_rules[]' "$ingress_fixture" | LC_ALL=C sort > "$expected_rules"
LC_ALL=C sort -u "$ingress_seen_rules" > "$ingress_tmp/seen-rules.sorted"
cmp -s "$expected_rules" "$ingress_tmp/seen-rules.sorted" ||
  fail_case 'owned rule inventory does not match executed proof'
tail -n +2 "$ingress_ledger" | cut -f5 | LC_ALL=C sort -u > "$ingress_tmp/expected-tests"
LC_ALL=C sort -u "$ingress_seen_tests" > "$ingress_tmp/seen-tests.sorted"
cmp -s "$ingress_tmp/expected-tests" "$ingress_tmp/seen-tests.sorted" ||
  fail_case 'ledger test IDs do not match executed proof'

ingress_review_total="$(awk -F '\t' 'NR > 1 && $1 == "review" {n++} END {print n+0}' "$ingress_ledger")"
ingress_legacy_total="$(awk -F '\t' 'NR > 1 && $1 == "legacy" {n++} END {print n+0}' "$ingress_ledger")"
ingress_review_accounted="$(awk -F '\t' '
  NR == FNR {seen[$1]=1; next}
  FNR > 1 && $1 == "review" && ($5 in seen) {n++}
  END {print n+0}
' "$ingress_tmp/seen-tests.sorted" "$ingress_ledger")"
ingress_legacy_accounted="$(awk -F '\t' '
  NR == FNR {seen[$1]=1; next}
  FNR > 1 && $1 == "legacy" && ($5 in seen) {n++}
  END {print n+0}
' "$ingress_tmp/seen-tests.sorted" "$ingress_ledger")"
[ "$ingress_review_total" -eq 2 ] && [ "$ingress_legacy_total" -eq 38 ] ||
  fail_case 'ingress ledger denominators'
[ "$ingress_review_accounted" -eq "$ingress_review_total" ] ||
  fail_case 'review ledger execution accounting'
[ "$ingress_legacy_accounted" -eq "$ingress_legacy_total" ] ||
  fail_case 'legacy ledger execution accounting'

ingress_owned_total="$(wc -l < "$expected_rules" | tr -d ' ')"
ingress_owned_passed="$ingress_owned_total"
if [ "$ingress_failures" -ne 0 ]; then
  ingress_owned_passed=0
fi

printf 'owned rules: %s/%s\n' "$ingress_owned_passed" "$ingress_owned_total"
printf 'direct cases: %s/%s\n' "$ingress_direct_passed" "$ingress_direct_total"
printf 'runtime/error cases: %s/%s\n' "$ingress_runtime_passed" "$ingress_runtime_total"
printf 'activation/restore cases: %s/%s\n' "$ingress_guard_passed" "$ingress_guard_total"
printf 'review findings accounted for: %s/%s\n' "$ingress_review_accounted" "$ingress_review_total"
printf 'legacy assertions accounted for: %s/%s\n' "$ingress_legacy_accounted" "$ingress_legacy_total"
printf 'failures: %s\n' "$ingress_failures"

[ "$ingress_failures" -eq 0 ]
