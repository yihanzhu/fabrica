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
ingress_registry="$ingress_repo/core/v1/generation-registry.json"
ingress_host_path="$PATH"
ingress_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-ingress-test.XXXXXX")"
ingress_tmp="$(cd "$ingress_tmp" && pwd -P)"
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
ingress_platform_runtime='native'
case "$ingress_platform" in
  Linux:x86_64)
    ingress_asset='jq-linux64'
    ingress_asset_sha256='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44'
    ;;
  Darwin:x86_64)
    ingress_asset='jq-osx-amd64'
    ingress_asset_sha256='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'
    ;;
  Darwin:arm64)
    ingress_asset='jq-osx-amd64'
    ingress_asset_sha256='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'
    ingress_platform_runtime='Rosetta 2'
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
if [ "$(sha256_path "$ingress_jq")" != "$ingress_asset_sha256" ]; then
  echo 'FAIL: jq 1.6 release asset digest mismatch' >&2
  exit 1
fi
if ! ingress_jq_version="$("$ingress_jq" --version 2>/dev/null)"; then
  if [ "$ingress_platform_runtime" = 'Rosetta 2' ]; then
    echo 'FAIL: unsupported jq 1.6 proof platform: Darwin:arm64 without Rosetta 2' >&2
  else
    echo 'FAIL: pinned jq 1.6 executable could not run' >&2
  fi
  exit 1
fi
[ "$ingress_jq_version" = jq-1.6 ] || {
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
utf8_inside_file="$ingress_tmp/invalid-utf8-inside-string.json"
utf8_truncated_file="$ingress_tmp/truncated-utf8.json"
utf8_overlong_file="$ingress_tmp/overlong-utf8.json"
utf8_surrogate_file="$ingress_tmp/surrogate-utf8.json"
utf8_too_high_file="$ingress_tmp/too-high-utf8.json"
utf8_valid_boundaries_file="$ingress_tmp/valid-utf8-boundaries.json"
duplicate_file="$ingress_tmp/duplicate.json"
whitespace_file="$ingress_tmp/whitespace.json"
escape_file="$ingress_tmp/escape.json"
no_lf_file="$ingress_tmp/no-lf.json"
extra_lf_file="$ingress_tmp/extra-lf.json"
unsorted_file="$ingress_tmp/unsorted.json"
unicode_sorted_file="$ingress_tmp/unicode-sorted.json"
unicode_unsorted_file="$ingress_tmp/unicode-unsorted.json"
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
printf '{"x":"\200"}\n' > "$utf8_inside_file"
printf '{"x":"\302"}\n' > "$utf8_truncated_file"
printf '{"x":"\300\257"}\n' > "$utf8_overlong_file"
printf '{"x":"\355\240\200"}\n' > "$utf8_surrogate_file"
printf '{"x":"\364\220\200\200"}\n' > "$utf8_too_high_file"
printf '{"x":"\302\200\337\277\340\240\200\357\277\277\360\220\200\200\364\217\277\277"}\n' \
  > "$utf8_valid_boundaries_file"
printf '{"a":1,"a":2}\n' > "$duplicate_file"
printf '{ "a": 1 }\n' > "$whitespace_file"
printf '{"x":"\\u0061"}\n' > "$escape_file"
printf '{}' > "$no_lf_file"
printf '{}\n\n' > "$extra_lf_file"
printf '{"b":1,"a":2}\n' > "$unsorted_file"
printf '{"z":1,"é":2,"😀":3}\n' > "$unicode_sorted_file"
printf '{"é":2,"z":1,"😀":3}\n' > "$unicode_unsorted_file"
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
document_finish_failure invalid-utf8-inside-string E_PARSE "$utf8_inside_file"
document_finish_failure truncated-utf8 E_PARSE "$utf8_truncated_file"
document_finish_failure overlong-utf8 E_PARSE "$utf8_overlong_file"
document_finish_failure surrogate-utf8 E_PARSE "$utf8_surrogate_file"
document_finish_failure too-high-utf8 E_PARSE "$utf8_too_high_file"
start_ingress document
expect_success valid-utf8-boundaries-snapshot \
  portable_core_ingress_snapshot "$utf8_valid_boundaries_file"
expect_success valid-utf8-boundaries-driver portable_core_ingress_finish_driver
stop_ingress
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
start_ingress document
expect_success unicode-key-order-snapshot portable_core_ingress_snapshot \
  "$unicode_sorted_file"
expect_success unicode-key-order-driver portable_core_ingress_finish_driver
stop_ingress
document_finish_failure unicode-key-order-unsorted E_CANONICAL \
  "$unicode_unsorted_file"
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

python3 - "$ingress_tmp/depth-32.json" "$ingress_tmp/depth-33.json" \
  "$ingress_tmp/depth-257.json" "$ingress_tmp/depth-string.json" \
  "$ingress_tmp/depth-33-malformed.json" \
  "$ingress_tmp/depth-33-noncanonical.json" \
  "$ingress_tmp/depth-257-noncanonical.json" \
  "$ingress_tmp/depth-256.json" \
  "$ingress_tmp/depth-100000.json" \
  "$ingress_tmp/depth-100000-malformed.json" \
  "$ingress_tmp/dense-near-limit.json" \
  "$ingress_tmp/number-near-limit.json" \
  "$ingress_tmp/object-depth-128.json" \
  "$ingress_tmp/object-depth-129.json" \
  "$ingress_tmp/mixed-depth-128.json" \
  "$ingress_tmp/mixed-depth-129.json" \
  "$ingress_tmp/deep-wide.json" \
  "$ingress_tmp/deep-wide-malformed.json" \
  "$ingress_tmp/deep-wide-noncanonical.json" \
  "$ingress_tmp/deep-object-sorted.json" \
  "$ingress_tmp/deep-object-duplicate.json" \
  "$ingress_tmp/deep-object-unsorted.json" \
  "$ingress_tmp/deep-high-surrogate.json" \
  "$ingress_tmp/deep-low-surrogate.json" \
  "$ingress_tmp/depth-empty-32.json" \
  "$ingress_tmp/depth-empty-33.json" <<'PY'
import json
import sys

for path, depth in zip(sys.argv[1:4], (32, 33, 257)):
    open(path, "wb").write(("[" * depth + "0" + "]" * depth + "\n").encode())
value = ("[{" * 40) + '"quoted"' + "\\" + ("]}" * 40)
encoded = json.dumps({"x": value}, ensure_ascii=False, separators=(",", ":")) + "\n"
open(sys.argv[4], "wb").write(encoded.encode())
open(sys.argv[5], "wb").write(("[" * 33 + "0" + "]" * 32 + "\n").encode())
open(sys.argv[6], "wb").write(("[" * 33 + " 0" + "]" * 33 + "\n").encode())
open(sys.argv[7], "wb").write(("[" * 257 + " 0" + "]" * 257 + "\n").encode())
open(sys.argv[8], "wb").write(("[" * 256 + "0" + "]" * 256 + "\n").encode())
open(sys.argv[9], "wb").write(("[" * 100000 + "0" + "]" * 100000 + "\n").encode())
open(sys.argv[10], "wb").write(("[" * 100000 + "0" + "]" * 99999 + "\n").encode())
open(sys.argv[11], "wb").write(b"[" + b",".join([b"0"] * 524286) + b"]\n")
open(sys.argv[12], "wb").write(b"1" + b"1" * 1048573 + b"\n")
open(sys.argv[13], "wb").write(("{\"a\":" * 128 + "0" + "}" * 128 + "\n").encode())
open(sys.argv[14], "wb").write(("{\"a\":" * 129 + "0" + "}" * 129 + "\n").encode())

def mixed(depth):
    opens = []
    closes = []
    for index in range(depth):
        if index % 2 == 0:
            opens.append("[")
            closes.append("]")
        else:
            opens.append("{\"a\":")
            closes.append("}")
    return "".join(opens) + "0" + "".join(reversed(closes)) + "\n"

open(sys.argv[15], "wb").write(mixed(128).encode())
open(sys.argv[16], "wb").write(mixed(129).encode())
deep_prefix = b"[" * 250000
deep_values = b",".join([b"0"] * 250000)
deep_suffix = b"]" * 250000
open(sys.argv[17], "wb").write(deep_prefix + deep_values + deep_suffix + b"\n")
open(sys.argv[18], "wb").write(deep_prefix + deep_values + deep_suffix[:-1] + b"\n")
open(sys.argv[19], "wb").write(deep_prefix + b" " + deep_values + deep_suffix + b"\n")
object_prefix = b'{"a":' * 129
object_suffix = b'}' * 129
open(sys.argv[20], "wb").write(object_prefix + b'{"a":0,"b":1}' + object_suffix + b"\n")
open(sys.argv[21], "wb").write(object_prefix + b'{"a":0,"a":1}' + object_suffix + b"\n")
open(sys.argv[22], "wb").write(object_prefix + b'{"b":0,"a":1}' + object_suffix + b"\n")
open(sys.argv[23], "wb").write(b"[" * 129 + b'"\\uD800"' + b"]" * 129 + b"\n")
open(sys.argv[24], "wb").write(b"[" * 129 + b'"\\uDC00"' + b"]" * 129 + b"\n")
open(sys.argv[25], "wb").write(b"[" * 32 + b"[]" + b"]" * 32 + b"\n")
open(sys.argv[26], "wb").write(b"[" * 33 + b"[]" + b"]" * 33 + b"\n")
PY
[ "$(wc -c < "$ingress_tmp/deep-wide.json" | tr -d ' ')" -eq 1000000 ]
[ "$(wc -c < "$ingress_tmp/deep-wide-malformed.json" | tr -d ' ')" -eq 999999 ]
[ "$(wc -c < "$ingress_tmp/deep-wide-noncanonical.json" | tr -d ' ')" -eq 1000001 ]

start_ingress document
expect_success depth-32-snapshot portable_core_ingress_snapshot "$ingress_tmp/depth-32.json"
expect_success depth-32-driver portable_core_ingress_finish_driver
stop_ingress
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/depth-33.json"
expect_failure depth-33-limit E_LIMIT portable_core_ingress_finish_driver
stop_ingress
start_ingress document
expect_success depth-empty-32-snapshot portable_core_ingress_snapshot \
  "$ingress_tmp/depth-empty-32.json"
expect_success depth-empty-32-driver portable_core_ingress_finish_driver
stop_ingress
document_finish_failure depth-empty-33-limit E_LIMIT \
  "$ingress_tmp/depth-empty-33.json"
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/depth-257.json"
expect_failure depth-257-limit E_LIMIT portable_core_ingress_finish_driver
stop_ingress
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/depth-256.json"
expect_failure depth-256-limit E_LIMIT portable_core_ingress_finish_driver
stop_ingress
start_ingress document
portable_core_ingress_snapshot "$ingress_tmp/depth-100000.json"
expect_failure depth-100000-limit E_LIMIT portable_core_ingress_finish_driver
stop_ingress
document_finish_failure depth-100000-malformed E_PARSE \
  "$ingress_tmp/depth-100000-malformed.json"
document_finish_failure deep-wide-limit E_LIMIT "$ingress_tmp/deep-wide.json"
document_finish_failure deep-wide-malformed E_PARSE \
  "$ingress_tmp/deep-wide-malformed.json"
document_finish_failure deep-wide-noncanonical E_CANONICAL \
  "$ingress_tmp/deep-wide-noncanonical.json"
document_finish_failure deep-object-sorted E_LIMIT \
  "$ingress_tmp/deep-object-sorted.json"
document_finish_failure deep-object-duplicate E_CANONICAL \
  "$ingress_tmp/deep-object-duplicate.json"
document_finish_failure deep-object-unsorted E_CANONICAL \
  "$ingress_tmp/deep-object-unsorted.json"
document_finish_failure deep-high-surrogate E_PARSE \
  "$ingress_tmp/deep-high-surrogate.json"
document_finish_failure deep-low-surrogate E_CANONICAL \
  "$ingress_tmp/deep-low-surrogate.json"
document_finish_failure object-depth-128-limit E_LIMIT \
  "$ingress_tmp/object-depth-128.json"
document_finish_failure object-depth-129-limit E_LIMIT \
  "$ingress_tmp/object-depth-129.json"
document_finish_failure mixed-depth-128-limit E_LIMIT \
  "$ingress_tmp/mixed-depth-128.json"
document_finish_failure mixed-depth-129-limit E_LIMIT \
  "$ingress_tmp/mixed-depth-129.json"
document_finish_failure depth-33-malformed E_PARSE \
  "$ingress_tmp/depth-33-malformed.json"
document_finish_failure depth-33-noncanonical E_CANONICAL \
  "$ingress_tmp/depth-33-noncanonical.json"
document_finish_failure depth-257-noncanonical E_CANONICAL \
  "$ingress_tmp/depth-257-noncanonical.json"
start_ingress document
expect_success depth-string-snapshot portable_core_ingress_snapshot "$ingress_tmp/depth-string.json"
expect_success depth-string-driver portable_core_ingress_finish_driver
stop_ingress
mark_rule portable-core-ingress.raw-depth-limit

[ "$(wc -c < "$ingress_tmp/dense-near-limit.json" | tr -d ' ')" -eq 1048574 ]
start_ingress document
expect_success dense-near-limit-snapshot portable_core_ingress_snapshot \
  "$ingress_tmp/dense-near-limit.json"
expect_success dense-near-limit-driver portable_core_ingress_finish_driver
stop_ingress
[ "$(wc -c < "$ingress_tmp/number-near-limit.json" | tr -d ' ')" -eq 1048575 ]
document_finish_failure number-near-limit E_CANONICAL \
  "$ingress_tmp/number-near-limit.json"

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
printf '{"x":' > "$ingress_tmp/unclosed-within-depth.json"
start_ingress profile-set
portable_core_ingress_snapshot "$ingress_tmp/depth-33.json"
portable_core_ingress_snapshot "$utf8_inside_file"
expect_failure multi-utf8-after-depth E_PARSE portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$utf8_inside_file"
portable_core_ingress_snapshot "$ingress_tmp/depth-33.json"
expect_failure multi-utf8-before-depth E_PARSE portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$ingress_tmp/unclosed-within-depth.json"
portable_core_ingress_snapshot "$ingress_tmp/depth-33.json"
expect_failure multi-parse-before-depth E_PARSE portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$ingress_tmp/depth-33-noncanonical.json"
portable_core_ingress_snapshot "$ingress_tmp/unclosed-within-depth.json"
expect_failure multi-deep-parse-before-canonical E_PARSE portable_core_ingress_finish_driver
stop_ingress
start_ingress profile-set
portable_core_ingress_snapshot "$ingress_tmp/depth-33.json"
portable_core_ingress_snapshot "$ingress_tmp/depth-257-noncanonical.json"
expect_failure multi-deep-canonical-before-limit E_CANONICAL \
  portable_core_ingress_finish_driver
stop_ingress
document_finish_failure unclosed-within-depth E_PARSE "$ingress_tmp/unclosed-within-depth.json"

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
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
rm "$PORTABLE_CORE_INGRESS_SNAPSHOT"
runtime_failure private-snapshot-read-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress
start_ingress document
od_failure="$ingress_tmp/od-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "od SECRET path" >&2' 'exit 2' > "$od_failure"
chmod +x "$od_failure"
PORTABLE_CORE_INGRESS_OD="$od_failure"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure byte-scanner-read-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress
start_ingress document
awk_failure="$ingress_tmp/awk-failure"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "awk SECRET path" >&2' 'exit 2' > "$awk_failure"
chmod +x "$awk_failure"
PORTABLE_CORE_INGRESS_AWK="$awk_failure"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure byte-scanner-logic-failure E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
awk_exit_forty="$ingress_tmp/awk-exit-forty"
printf '%s\n' '#!/bin/sh' 'exit 40' > "$awk_exit_forty"
chmod +x "$awk_exit_forty"
PORTABLE_CORE_INGRESS_AWK="$awk_exit_forty"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure analyzer-awk-exit-forty E_RUNTIME portable_core_ingress_finish_driver
stop_ingress

start_ingress document
real_ingress_awk="$PORTABLE_CORE_INGRESS_AWK"
marker_awk_exit_forty_one="$ingress_tmp/marker-awk-exit-forty-one"
printf '%s\n' '#!/bin/sh' \
  'case " $* " in *" -v scalar_file="*) exec "$REAL_AWK" "$@" ;; esac' \
  'exit 41' > "$marker_awk_exit_forty_one"
chmod +x "$marker_awk_exit_forty_one"
PORTABLE_CORE_INGRESS_AWK="$marker_awk_exit_forty_one"
export REAL_AWK="$real_ingress_awk"
portable_core_ingress_snapshot "$canonical_file"
runtime_failure marker-awk-exit-forty-one E_RUNTIME portable_core_ingress_finish_driver
unset REAL_AWK
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
  for tool in dirname head wc cmp cat rm mktemp od awk; do
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$destination/$tool"
  done
}

dirname_fail_bin="$ingress_tmp/dirname-fail-bin"
make_isolated_bin "$dirname_fail_bin"
rm "$dirname_fail_bin/dirname"
ingress_product_dir="${ingress_product%/*}"
printf '%s\n' '#!/bin/sh' \
  "printf '%s\\n' \"$ingress_product_dir\"" \
  'printf "%s\n" "dirname SECRET /private/source/path" >&2' \
  'exit 1' > "$dirname_fail_bin/dirname"
chmod +x "$dirname_fail_bin/dirname"
runtime_failure dirname-failure-sanitized E_RUNTIME env PATH="$dirname_fail_bin" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$ingress_product"

jq_version_fail_bin="$ingress_tmp/jq-version-fail-bin"
make_isolated_bin "$jq_version_fail_bin"
rm "$jq_version_fail_bin/jq"
printf '%s\n' '#!/bin/sh' \
  'if [ "${1:-}" = "--version" ]; then printf "%s\n" jq-1.6; exit 1; fi' \
  "exec \"$ingress_jq\" \"\$@\"" > "$jq_version_fail_bin/jq"
chmod +x "$jq_version_fail_bin/jq"
runtime_failure jq-version-nonzero E_RUNTIME env PATH="$jq_version_fail_bin" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ "$ingress_product"

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

for stream_runtime_status in 5 41; do
  start_ingress document
  real_ingress_jq="$PORTABLE_CORE_INGRESS_JQ"
  stream_runtime_fail="$ingress_tmp/stream-exit-$stream_runtime_status"
  printf '%s\n' '#!/bin/sh' \
    "case \" \$* \" in *\" --stream --stream-errors \"*) exit $stream_runtime_status ;; esac" \
    "exec \"$real_ingress_jq\" \"\$@\"" > "$stream_runtime_fail"
  chmod +x "$stream_runtime_fail"
  PORTABLE_CORE_INGRESS_JQ="$stream_runtime_fail"
  portable_core_ingress_snapshot "$ingress_tmp/depth-257.json"
  runtime_failure "streaming-canonicalizer-exit-$stream_runtime_status" E_RUNTIME \
    portable_core_ingress_finish_driver
  stop_ingress
done

for key_order_mode in nonzero malformed; do
  start_ingress document
  real_ingress_jq="$PORTABLE_CORE_INGRESS_JQ"
  key_order_fail="$ingress_tmp/key-order-$key_order_mode"
  if [ "$key_order_mode" = nonzero ]; then
    key_order_action='exit 7'
  else
    key_order_action='printf "%s" malformed; exit 0'
  fi
  printf '%s\n' '#!/bin/sh' \
    "case \" \$* \" in *\" --slurpfile keys \"*) $key_order_action ;; esac" \
    "exec \"$real_ingress_jq\" \"\$@\"" > "$key_order_fail"
  chmod +x "$key_order_fail"
  PORTABLE_CORE_INGRESS_JQ="$key_order_fail"
  portable_core_ingress_snapshot "$ingress_tmp/deep-object-sorted.json"
  runtime_failure "key-order-$key_order_mode" E_RUNTIME \
    portable_core_ingress_finish_driver
  stop_ingress
done

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

start_ingress document
portable_core_ingress_snapshot "$canonical_file"
analysis_wc_malformed="$ingress_tmp/analysis-wc-malformed"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "SECRET /private/meta/path"' \
  'exit 0' > "$analysis_wc_malformed"
chmod +x "$analysis_wc_malformed"
PORTABLE_CORE_INGRESS_WC="$analysis_wc_malformed"
runtime_failure analysis-wc-malformed-output E_RUNTIME \
  portable_core_ingress_finish_driver
stop_ingress

write_failure_case() {
  local case_id="$1"
  local target_kind="$2"
  start_ingress document
  case "$target_kind" in
    raw) mkdir "$PORTABLE_CORE_INGRESS_TEMP/raw.1" ;;
    canonical) mkdir "$PORTABLE_CORE_INGRESS_TEMP/canonical.1" ;;
    analysis) mkdir "$PORTABLE_CORE_INGRESS_TEMP/deep-scalars.ndjson" ;;
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
write_failure_case analysis-sidecar-write-failure analysis
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
package_alias="$ingress_tmp/package-alias"
mkdir "$package_alias"
ln -s "$package_copy/core" "$package_alias/core"
symlink_ancestor_product="$package_alias/core/v1/generations/$ingress_generation/core-ingress.sh"
runtime_failure source-ancestor-symlink E_RUNTIME \
  env PATH="$ingress_proof_bin:$ingress_host_path" \
  /bin/bash -c 'source "$1"; portable_core_ingress_open' _ \
  "$symlink_ancestor_product"

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

start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
validator_wc_malformed="$ingress_tmp/validator-wc-malformed"
printf '%s\n' '#!/bin/sh' \
  'printf "%s\n" "SECRET /private/caller/path"' \
  'exit 0' > "$validator_wc_malformed"
chmod +x "$validator_wc_malformed"
PORTABLE_CORE_INGRESS_WC="$validator_wc_malformed"
runtime_failure validator-wc-malformed-output E_RUNTIME portable_core_ingress_validate
stop_ingress

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
printf '%s\n' '"E_SHAPE\u0000"' > "$package_root"
start_ingress document
portable_core_ingress_snapshot "$canonical_file"
portable_core_ingress_finish_driver
runtime_failure validator-null-output E_RUNTIME portable_core_ingress_validate
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

ingress_private_generation_path_ok() {
  case "$1" in
    "core/v1/generations/$ingress_generation/core-ingress.sh"|\
    "core/v1/generations/$ingress_generation/contracts.jq"|\
    "core/v1/generations/$ingress_generation/modules/schema.jq"|\
    "core/v1/generations/$ingress_generation/modules/profile_graph.jq"|\
    "core/v1/generations/$ingress_generation/modules/stage_request.jq"|\
    "core/v1/generations/$ingress_generation/modules/result_facts.jq"|\
    "core/v1/generations/$ingress_generation/modules/result_truth.jq") return 0 ;;
    *) return 1 ;;
  esac
}

ingress_guard_paths_ok() {
  local paths_file="$1"
  local candidate_path
  while IFS= read -r candidate_path; do
    ingress_private_generation_path_ok "$candidate_path" || return 1
  done < "$paths_file"
}

ingress_activation_state_ok() {
  local root_program="$1"
  local wrapper="$2"
  local root_exists=false
  local wrapper_exists=false
  local selected_major
  local selected_generation
  local selected_registry
  local selected_root
  { [ -e "$root_program" ] || [ -L "$root_program" ]; } && root_exists=true
  { [ -e "$wrapper" ] || [ -L "$wrapper" ]; } && wrapper_exists=true
  if [ "$root_exists" = false ] && [ "$wrapper_exists" = false ]; then
    return 0
  fi
  selected_major="$(sed -n \
    "s/^PORTABLE_CORE_SCHEMA_MAJOR='\([12]\)'$/\1/p" "$wrapper")"
  selected_generation="$(sed -n \
    "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$wrapper")"
  selected_registry="$ingress_repo/core/v$selected_major/generation-registry.json"
  selected_root="$ingress_repo/core/v$selected_major/generations/$selected_generation"
  [ "$root_exists" = true ] && [ "$wrapper_exists" = true ] &&
    [ -f "$root_program" ] && [ ! -L "$root_program" ] &&
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && [ -x "$wrapper" ] &&
    [ "$(grep -Ec "^PORTABLE_CORE_SCHEMA_MAJOR='[12]'$" "$wrapper")" -eq 1 ] &&
    [ "$(grep -Ec "^PORTABLE_CORE_GENERATION='g-[0-9a-f]{64}'$" "$wrapper")" -eq 1 ] &&
    [ -n "$selected_major" ] &&
    [ -n "$selected_generation" ] &&
    grep -Fq "\"generation_id\":\"$selected_generation\"" "$selected_registry" &&
    [ -d "$selected_root/modules" ] && [ ! -L "$selected_root/modules" ] &&
    [ -f "$selected_root/contracts.jq" ] && [ ! -L "$selected_root/contracts.jq" ] &&
    [ -f "$selected_root/core-ingress.sh" ] && [ ! -L "$selected_root/core-ingress.sh" ]
}

if ingress_guard_paths_ok "$guard_paths" &&
   grep -Fqx "core/v1/generations/$ingress_generation/core-ingress.sh" "$guard_paths" &&
   grep -Fqx "core/v1/generations/$ingress_generation/modules/schema.jq" "$guard_paths" &&
   ingress_activation_state_ok \
     "$ingress_repo/core/v1/generations/$ingress_generation/contracts.jq" \
     "$ingress_repo/scripts/core-contract.sh" &&
   [ -z "$(find "$ingress_repo/core/v1/generations/$ingress_generation" -type l -print -quit)" ]; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'private generation guard'
fi
planned_guard_paths="$ingress_tmp/planned-generation-files"
cp "$guard_paths" "$planned_guard_paths"
printf '%s\n' \
  "core/v1/generations/$ingress_generation/modules/profile_graph.jq" \
  "core/v1/generations/$ingress_generation/modules/stage_request.jq" \
  "core/v1/generations/$ingress_generation/modules/result_facts.jq" \
  "core/v1/generations/$ingress_generation/modules/result_truth.jq" >> \
  "$planned_guard_paths"
if ingress_guard_paths_ok "$planned_guard_paths"; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'private generation guard rejected a planned module'
fi

ingress_registry_ok() {
  local candidate_registry="$1"
  local canonical_registry="$ingress_tmp/registry-check.canonical"
  "$ingress_jq" -s -S -c \
    'if length == 1 then .[0] else error("root-count") end' \
    "$candidate_registry" > "$canonical_registry" 2>/dev/null &&
    cmp -s "$candidate_registry" "$canonical_registry" &&
    "$ingress_jq" -e \
      --arg generation "$ingress_generation" \
      --arg spec c6511d96c1a5e6aed27ba2075b5add65c121f782 \
      --arg authorization 38a26f5f046897c0455fef24874c5dbb40c20926 '
      length >= 1 and
      .[0] == {generation_id:$generation,
        parent_spec_blob:$spec,
        parent_plan_merge_commit:$authorization} and
      all(.[];
        (keys | sort) ==
          ["generation_id","parent_plan_merge_commit","parent_spec_blob"] and
        (.generation_id | test("\\Ag-[0-9a-f]{64}\\z")) and
        (.parent_spec_blob | test("\\A([0-9a-f]{40}|[0-9a-f]{64})\\z")) and
        (.parent_plan_merge_commit |
          test("\\A([0-9a-f]{40}|[0-9a-f]{64})\\z"))) and
      (map(.generation_id) | length) ==
        (map(.generation_id) | unique | length)
    ' "$candidate_registry" >/dev/null
}

if [ "$(git -C "$ingress_repo" ls-tree HEAD \
       "core/v1/generations/$ingress_generation/modules/schema.jq" | awk '{print $3}')" = \
       fd3924d414a7d620c2bf5de919a45c2599d572ec ] &&
   ingress_registry_ok "$ingress_registry"; then
  ingress_guard_total=$((ingress_guard_total + 1))
  ingress_guard_passed=$((ingress_guard_passed + 1))
else
  ingress_guard_total=$((ingress_guard_total + 1))
  fail_case 'schema G3 export or registry prefix moved'
fi
future_registry="$ingress_tmp/future-generation-registry.json"
reordered_registry="$ingress_tmp/reordered-generation-registry.json"
multi_root_registry="$ingress_tmp/multi-root-generation-registry.json"
"$ingress_jq" -S -c '. + [{
    generation_id:("g-" + ("f" * 64)),
    parent_plan_merge_commit:("e" * 40),
    parent_spec_blob:("d" * 40)}]' "$ingress_registry" > "$future_registry"
"$ingress_jq" -S -c 'reverse' "$future_registry" > "$reordered_registry"
"$ingress_jq" -c '.,.' "$ingress_registry" > "$multi_root_registry"
if ingress_registry_ok "$future_registry" &&
   ! ingress_registry_ok "$reordered_registry" &&
   ! ingress_registry_ok "$multi_root_registry"; then
  ingress_direct_total=$((ingress_direct_total + 1))
  ingress_direct_passed=$((ingress_direct_passed + 1))
else
  ingress_direct_total=$((ingress_direct_total + 1))
  fail_case 'registry ordered-prefix growth proof'
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
