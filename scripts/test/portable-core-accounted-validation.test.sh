#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

accounted_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
accounted_old='g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386'
accounted_generation='g-71433a31f52f37041a41b5a8812f79c4c0f5f26c79265788c8d625a9c6f9686b'
accounted_generation_root="$accounted_root/core/v1/generations/$accounted_generation"
accounted_ingress="$accounted_generation_root/core-ingress.sh"
accounted_registry="$accounted_root/core/v1/generation-registry.json"
accounted_wrapper="$accounted_root/scripts/core-contract.sh"
accounted_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-core-accounted.XXXXXX")"
accounted_tmp="$(cd "$accounted_tmp" && pwd -P)"
accounted_download=''

cleanup() {
  if [ -n "${PORTABLE_CORE_INGRESS_TEMP:-}" ]; then
    portable_core_ingress_close >/dev/null 2>&1 || :
  fi
  if [ -n "$accounted_download" ] && [ -f "$accounted_download" ]; then
    rm -f -- "$accounted_download"
  fi
  rm -rf -- "$accounted_tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

accounted_platform="$(uname -s):$(uname -m)"
case "$accounted_platform" in
  Linux:x86_64)
    accounted_asset='jq-linux64'
    accounted_asset_sha256='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44'
    ;;
  Darwin:x86_64|Darwin:arm64)
    accounted_asset='jq-osx-amd64'
    accounted_asset_sha256='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'
    ;;
  *) fail "unsupported jq 1.6 proof platform: $accounted_platform" ;;
esac

accounted_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$accounted_cache"
accounted_jq="$accounted_cache/$accounted_asset"
if [ ! -f "$accounted_jq" ] ||
   [ "$(sha256_path "$accounted_jq")" != "$accounted_asset_sha256" ]; then
  accounted_download="$(mktemp "$accounted_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$accounted_asset" \
    -o "$accounted_download"
  [ "$(sha256_path "$accounted_download")" = "$accounted_asset_sha256" ] ||
    fail 'jq 1.6 release asset digest mismatch'
  chmod 0555 "$accounted_download"
  mv "$accounted_download" "$accounted_jq"
  accounted_download=''
fi
[ "$(sha256_path "$accounted_jq")" = "$accounted_asset_sha256" ] ||
  fail 'jq 1.6 release asset digest mismatch'
[ "$("$accounted_jq" --version 2>/dev/null)" = jq-1.6 ] ||
  fail 'pinned jq 1.6 identity check failed'

accounted_bin="$accounted_tmp/bin"
mkdir -p "$accounted_bin"
ln -s "$accounted_jq" "$accounted_bin/jq"
accounted_path="$accounted_bin:/usr/bin:/bin:/usr/sbin:/sbin"

derived_id="g-$(printf '%s\n' \
  'ystack portable core generation v1' \
  "source_generation=$accounted_old" \
  'operator_decision_comment=5470219645' \
  'concern=accounted-validation' | sha256_path /dev/stdin)"
[ "$derived_id" = "$accounted_generation" ] || fail 'generation derivation'

for unchanged_export in contracts.jq modules/schema.jq modules/profile_graph.jq \
  modules/stage_request.jq modules/result_facts.jq modules/result_truth.jq; do
  cmp -s \
    "$accounted_root/core/v1/generations/$accounted_old/$unchanged_export" \
    "$accounted_generation_root/$unchanged_export" ||
    fail "copied export moved: $unchanged_export"
done

canonical_registry="$accounted_tmp/registry.canonical"
"$accounted_jq" -S -c . "$accounted_registry" > "$canonical_registry"
cmp -s "$accounted_registry" "$canonical_registry" || fail 'registry canonical form'
"$accounted_jq" -e --arg old "$accounted_old" \
  --arg new "$accounted_generation" '
    length == 2 and .[0].generation_id == $old and .[1].generation_id == $new and
    .[0].parent_spec_blob == .[1].parent_spec_blob and
    .[0].parent_plan_merge_commit == .[1].parent_plan_merge_commit
  ' "$accounted_registry" >/dev/null || fail 'registry ordered append'

package_root="$accounted_tmp/package"
package_generation="$package_root/core/v1/generations/$accounted_generation"
mkdir -p "$package_root/scripts" "$package_generation/modules"
cp "$accounted_wrapper" "$package_root/scripts/core-contract.sh"
for package_export in contracts.jq core-ingress.sh modules/schema.jq \
  modules/profile_graph.jq modules/stage_request.jq modules/result_facts.jq \
  modules/result_truth.jq; do
  cp "$accounted_generation_root/$package_export" \
    "$package_generation/$package_export"
done
sed "s/$accounted_old/$accounted_generation/" \
  "$package_root/scripts/core-contract.sh" > "$accounted_tmp/switched-wrapper"
mv "$accounted_tmp/switched-wrapper" "$package_root/scripts/core-contract.sh"
chmod 0755 "$package_root/scripts/core-contract.sh"
package_wrapper="$package_root/scripts/core-contract.sh"

run_case() {
  local case_id="$1"
  local budget="$2"
  local scratch="$accounted_tmp/scratch-$case_id"
  RUN_STATUS=0
  RUN_STDOUT="$accounted_tmp/$case_id.stdout"
  RUN_STDERR="$accounted_tmp/$case_id.stderr"
  RUN_RECEIPT="$accounted_tmp/$case_id.receipt"
  mkdir -m 700 "$scratch"
  PATH="$accounted_path" "$package_wrapper" --accounted-validation \
    "$scratch" "$budget" validate-document "$accounted_registry" \
    3> "$RUN_RECEIPT" > "$RUN_STDOUT" 2> "$RUN_STDERR" || RUN_STATUS=$?
  [ -z "$(find "$scratch" -mindepth 1 -print -quit)" ] ||
    fail "$case_id left internal scratch"
}

receipt_bytes() {
  grep -Eq '^written-bytes:(0|[1-9][0-9]*)$' "$1" ||
    fail 'malformed accounted receipt'
  sed -n 's/^written-bytes://p' "$1"
}

run_case high 536870912
[ "$RUN_STATUS" -ne 0 ] && [ ! -s "$RUN_STDOUT" ] &&
  [ "$(cat "$RUN_STDERR")" = E_SHAPE ] || fail 'accounted validation semantics'
exact_bytes="$(receipt_bytes "$RUN_RECEIPT")"
[ "$exact_bytes" -gt 0 ] || fail 'empty byte receipt'

run_case exact "$exact_bytes"
[ "$RUN_STATUS" -ne 0 ] && [ ! -s "$RUN_STDOUT" ] &&
  [ "$(cat "$RUN_STDERR")" = E_SHAPE ] &&
  [ "$(receipt_bytes "$RUN_RECEIPT")" -eq "$exact_bytes" ] ||
  fail 'exact boundary did not preserve validator result'

run_case short "$((exact_bytes - 1))"
short_bytes="$(receipt_bytes "$RUN_RECEIPT")"
[ "$RUN_STATUS" -ne 0 ] && [ ! -s "$RUN_STDOUT" ] &&
  [ "$(cat "$RUN_STDERR")" = E_LIMIT ] &&
  [ "$short_bytes" -le $((exact_bytes - 1)) ] ||
  fail 'one-byte-short budget crossed its boundary'

direct_scratch="$accounted_tmp/direct-scratch"
mkdir -m 700 "$direct_scratch"
PATH="$accounted_path"
export PATH
# shellcheck source=/dev/null
source "$accounted_ingress"
portable_core_ingress_open "$direct_scratch" 536870912
portable_core_ingress_begin document
portable_core_ingress_snapshot "$accounted_registry"
portable_core_ingress_finish_driver
direct_status=0
portable_core_ingress_validate 2> "$accounted_tmp/direct.stderr" ||
  direct_status=$?
direct_sum="$(find "$PORTABLE_CORE_INGRESS_TEMP" -type f -exec wc -c {} + |
  tail -n 1 | awk '{print $1}')"
[ "$direct_status" -ne 0 ] &&
  [ "$(cat "$accounted_tmp/direct.stderr")" = E_SHAPE ] &&
  [ "$PORTABLE_CORE_INGRESS_WRITTEN_BYTES" -eq "$direct_sum" ] ||
  fail 'receipt is not the exact written-byte sum'
portable_core_ingress_close
[ -z "$(find "$direct_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'direct invocation left internal scratch'

unsafe_scratch="$accounted_tmp/unsafe-scratch"
mkdir -m 755 "$unsafe_scratch"
unsafe_status=0
PATH="$accounted_path" "$package_wrapper" --accounted-validation \
  "$unsafe_scratch" 536870912 validate-document "$accounted_registry" \
  3> "$accounted_tmp/unsafe.receipt" > "$accounted_tmp/unsafe.stdout" \
  2> "$accounted_tmp/unsafe.stderr" || unsafe_status=$?
[ "$unsafe_status" -ne 0 ] && [ ! -s "$accounted_tmp/unsafe.stdout" ] &&
  [ "$(cat "$accounted_tmp/unsafe.stderr")" = E_RUNTIME ] &&
  [ "$(receipt_bytes "$accounted_tmp/unsafe.receipt")" -eq 0 ] ||
  fail 'unsafe scratch root was accepted'

ordinary_status=0
PATH="$accounted_path" "$package_wrapper" validate-document \
  "$accounted_registry" > "$accounted_tmp/ordinary.stdout" \
  2> "$accounted_tmp/ordinary.stderr" || ordinary_status=$?
[ "$ordinary_status" -ne 0 ] && [ ! -s "$accounted_tmp/ordinary.stdout" ] &&
  [ "$(cat "$accounted_tmp/ordinary.stderr")" = E_SHAPE ] ||
  fail 'ordinary interface changed'

for required_path in \
  "core/v1/generations/$accounted_generation/modules/schema.jq" \
  "core/v1/generations/$accounted_generation/core-ingress.sh" \
  "core/v1/generations/$accounted_generation/modules/profile_graph.jq" \
  "core/v1/generations/$accounted_generation/modules/stage_request.jq" \
  "core/v1/generations/$accounted_generation/modules/result_facts.jq" \
  "core/v1/generations/$accounted_generation/modules/result_truth.jq" \
  "core/v1/generations/$accounted_generation/contracts.jq" \
  scripts/test/portable-core-accounted-validation.test.sh; do
  [ "$(grep -Fxc "$required_path" "$accounted_root/ci/required-files.txt")" -eq 1 ] ||
    fail "restore manifest entry: $required_path"
done

printf 'portable core accounted validation: 12/12 passed\n'
