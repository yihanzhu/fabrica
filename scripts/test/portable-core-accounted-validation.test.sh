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
accounted_background_pids=('')

cleanup() {
  local background_pid
  for background_pid in "${accounted_background_pids[@]}"; do
    [ -n "$background_pid" ] || continue
    kill "$background_pid" >/dev/null 2>&1 || :
    wait "$background_pid" >/dev/null 2>&1 || :
  done
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
if grep -Eq '(^|[^<])<<([^<]|$)' "$accounted_ingress" ||
   grep -Fq '<<<' "$accounted_ingress"; then
  fail 'accounted program body uses a heredoc or here-string'
fi

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
  if [ "$(wc -l < "$1" | tr -d ' ')" -ne 1 ] ||
     ! grep -Eq '^written-bytes:(0|[1-9][0-9]*)$' "$1"; then
    fail 'malformed accounted receipt'
  fi
  sed -n 's/^written-bytes://p' "$1"
}

run_snapshot_probe() {
  local mode="$1"
  local input_path="$2"
  local scratch_root="$3"
  local probe_path="$4"
  PATH="$probe_path" /bin/bash -c '
    set -uo pipefail
    # shellcheck source=/dev/null
    source "$1"
    if [ "$2" = accounted ]; then
      portable_core_ingress_open "$3" 536870912
    else
      portable_core_ingress_open
    fi
    portable_core_ingress_begin document
    portable_core_ingress_snapshot "$4"
    "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 \
      "$PORTABLE_CORE_INGRESS_SNAPSHOT"
    portable_core_ingress_close
  ' _ "$accounted_ingress" "$mode" "$scratch_root" "$input_path"
}

snapshot_tokens() {
  awk '
    {
      for (i = 1; i <= NF; i++) {
        if (seen) printf " "
        printf "%s", $i
        seen = 1
      }
    }
    END { print "" }
  ' "$1"
}

wait_probe() {
  local probe_pid="$1"
  local probe_name="$2"
  local probe_status=0
  local _
  for _ in 1 2 3 4 5; do
    if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
      wait "$probe_pid" || probe_status=$?
      [ "$probe_status" -eq 0 ] || fail "$probe_name failed"
      return 0
    fi
    /bin/sleep 1
  done
  kill "$probe_pid" >/dev/null 2>&1 || :
  wait "$probe_pid" >/dev/null 2>&1 || :
  fail "$probe_name read its source more than once"
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

multiline_root="$accounted_tmp/multiline"$'\n'"component"$'\r'"tail"
multiline_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" \
  --accounted-validation "$multiline_root" 536870912 \
  validate-document "$accounted_registry" \
  3> "$accounted_tmp/multiline.receipt" \
  > "$accounted_tmp/multiline.stdout" \
  2> "$accounted_tmp/multiline.stderr" || multiline_status=$?
[ "$multiline_status" -ne 0 ] && [ ! -s "$accounted_tmp/multiline.stdout" ] &&
  [ "$(cat "$accounted_tmp/multiline.stderr")" = E_RUNTIME ] &&
  [ "$(receipt_bytes "$accounted_tmp/multiline.receipt")" -eq 0 ] &&
  [ ! -e "$multiline_root" ] && [ ! -L "$multiline_root" ] ||
  fail 'multiline scratch root traversed or misstated its receipt'

symlink_real_root="$accounted_tmp/symlink-real-root"
symlink_root="$accounted_tmp/symlink-root"
mkdir -m 700 "$symlink_real_root"
ln -s "$symlink_real_root" "$symlink_root"
symlink_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" \
  --accounted-validation "$symlink_root" 536870912 \
  validate-document "$accounted_registry" \
  3> "$accounted_tmp/symlink.receipt" \
  > "$accounted_tmp/symlink.stdout" \
  2> "$accounted_tmp/symlink.stderr" || symlink_status=$?
[ "$symlink_status" -ne 0 ] && [ ! -s "$accounted_tmp/symlink.stdout" ] &&
  [ "$(cat "$accounted_tmp/symlink.stderr")" = E_RUNTIME ] &&
  [ "$(receipt_bytes "$accounted_tmp/symlink.receipt")" -eq 0 ] &&
  [ -L "$symlink_root" ] &&
  [ -z "$(find "$symlink_real_root" -mindepth 1 -print -quit)" ] ||
  fail 'symlink scratch root traversed or misstated its receipt'

ordinary_status=0
PATH="$accounted_path" "$package_wrapper" validate-document \
  "$accounted_registry" > "$accounted_tmp/ordinary.stdout" \
  2> "$accounted_tmp/ordinary.stderr" || ordinary_status=$?
[ "$ordinary_status" -ne 0 ] && [ ! -s "$accounted_tmp/ordinary.stdout" ] &&
  [ "$(cat "$accounted_tmp/ordinary.stderr")" = E_SHAPE ] ||
  fail 'ordinary interface changed'

stdin_ordinary="$accounted_tmp/stdin-ordinary.bytes"
printf '{}\000\n\n' |
  run_snapshot_probe ordinary /dev/stdin '' "$accounted_path" > "$stdin_ordinary"
[ "$(snapshot_tokens "$stdin_ordinary")" = '123 125 0 10 10' ] ||
  fail 'ordinary stdin snapshot bytes moved'

stdin_accounted_root="$accounted_tmp/stdin-accounted-root"
mkdir -m 700 "$stdin_accounted_root"
stdin_accounted="$accounted_tmp/stdin-accounted.bytes"
printf '{}\000\n\n' |
  run_snapshot_probe accounted /dev/stdin "$stdin_accounted_root" \
    "$accounted_path" > "$stdin_accounted"
[ "$(snapshot_tokens "$stdin_accounted")" = '123 125 0 10 10' ] &&
  [ -z "$(find "$stdin_accounted_root" -mindepth 1 -print -quit)" ] ||
  fail 'accounted stdin snapshot bytes moved'

fifo_path="$accounted_tmp/one-read.fifo"
fifo_root="$accounted_tmp/fifo-root"
fifo_bytes="$accounted_tmp/fifo.bytes"
mkfifo "$fifo_path"
mkdir -m 700 "$fifo_root"
run_snapshot_probe accounted "$fifo_path" "$fifo_root" "$accounted_path" \
  > "$fifo_bytes" &
fifo_reader_pid=$!
accounted_background_pids+=("$fifo_reader_pid")
printf '{}\000\n\n' > "$fifo_path" &
fifo_writer_pid=$!
accounted_background_pids+=("$fifo_writer_pid")
wait_probe "$fifo_writer_pid" 'FIFO writer'
wait_probe "$fifo_reader_pid" 'FIFO snapshot'
[ "$(snapshot_tokens "$fifo_bytes")" = '123 125 0 10 10' ] &&
  [ -z "$(find "$fifo_root" -mindepth 1 -print -quit)" ] ||
  fail 'FIFO snapshot bytes moved'

mutable_source="$accounted_tmp/mutable.json"
mutable_counter="$accounted_tmp/head.count"
mutable_bin="$accounted_tmp/mutable-bin"
mutable_root="$accounted_tmp/mutable-root"
mutable_bytes="$accounted_tmp/mutable.bytes"
mkdir -p "$mutable_bin"
mkdir -m 700 "$mutable_root"
printf '{"first":true}\n' > "$mutable_source"
printf '0\n' > "$mutable_counter"
cat > "$mutable_bin/head" <<'HEAD_WRAPPER'
#!/bin/bash
set -uo pipefail
count="$(cat "$ACCOUNTED_HEAD_COUNTER")"
count=$((count + 1))
printf '%s\n' "$count" > "$ACCOUNTED_HEAD_COUNTER"
status=0
"$ACCOUNTED_REAL_HEAD" "$@" || status=$?
printf '{"second":true}\n' > "$ACCOUNTED_MUTABLE_SOURCE"
exit "$status"
HEAD_WRAPPER
chmod 0755 "$mutable_bin/head"
ACCOUNTED_HEAD_COUNTER="$mutable_counter" \
ACCOUNTED_REAL_HEAD="$(command -v head)" \
ACCOUNTED_MUTABLE_SOURCE="$mutable_source" \
  run_snapshot_probe accounted "$mutable_source" "$mutable_root" \
    "$mutable_bin:$accounted_path" > "$mutable_bytes"
[ "$(cat "$mutable_counter")" -eq 1 ] &&
  [ "$(snapshot_tokens "$mutable_bytes")" = \
    '123 34 102 105 114 115 116 34 58 116 114 117 101 125 10' ] &&
  [ "$(cat "$mutable_source")" = '{"second":true}' ] ||
  fail 'mutable source was read more than once'

stream_ordinary_status=0
printf '{}\000\n' |
  PATH="$accounted_path" /bin/bash "$package_wrapper" validate-document \
    /dev/stdin > "$accounted_tmp/stream-ordinary.stdout" \
    2> "$accounted_tmp/stream-ordinary.stderr" || stream_ordinary_status=$?
[ "$stream_ordinary_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/stream-ordinary.stdout" ] &&
  [ "$(cat "$accounted_tmp/stream-ordinary.stderr")" = E_PARSE ] ||
  fail 'ordinary stdin NUL semantics moved'

stream_accounted_root="$accounted_tmp/stream-accounted-root"
mkdir -m 700 "$stream_accounted_root"
stream_accounted_status=0
printf '{}\000\n' |
  PATH="$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$stream_accounted_root" 536870912 \
    validate-document /dev/stdin 3> "$accounted_tmp/stream-accounted.receipt" \
    > "$accounted_tmp/stream-accounted.stdout" \
    2> "$accounted_tmp/stream-accounted.stderr" || stream_accounted_status=$?
[ "$stream_accounted_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/stream-accounted.stdout" ] &&
  [ "$(cat "$accounted_tmp/stream-accounted.stderr")" = E_PARSE ] &&
  [ "$(receipt_bytes "$accounted_tmp/stream-accounted.receipt")" -gt 0 ] ||
  fail 'accounted stdin NUL semantics moved'

newline_ordinary_status=0
printf '{}\n\n' |
  PATH="$accounted_path" /bin/bash "$package_wrapper" validate-document \
    /dev/stdin > "$accounted_tmp/newline-ordinary.stdout" \
    2> "$accounted_tmp/newline-ordinary.stderr" || newline_ordinary_status=$?
[ "$newline_ordinary_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/newline-ordinary.stdout" ] &&
  [ "$(cat "$accounted_tmp/newline-ordinary.stderr")" = E_CANONICAL ] ||
  fail 'ordinary trailing-newline semantics moved'

newline_accounted_root="$accounted_tmp/newline-accounted-root"
mkdir -m 700 "$newline_accounted_root"
newline_accounted_status=0
printf '{}\n\n' |
  PATH="$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$newline_accounted_root" 536870912 \
    validate-document /dev/stdin 3> "$accounted_tmp/newline-accounted.receipt" \
    > "$accounted_tmp/newline-accounted.stdout" \
    2> "$accounted_tmp/newline-accounted.stderr" || newline_accounted_status=$?
[ "$newline_accounted_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/newline-accounted.stdout" ] &&
  [ "$(cat "$accounted_tmp/newline-accounted.stderr")" = E_CANONICAL ] &&
  [ "$(receipt_bytes "$accounted_tmp/newline-accounted.receipt")" -gt 0 ] ||
  fail 'accounted trailing-newline semantics moved'

probe_input="$accounted_tmp/limit-probe.json"
awk 'BEGIN { for (i = 0; i < 1048577; i++) printf "x" }' > "$probe_input"
probe_ordinary_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" validate-document \
  "$probe_input" > "$accounted_tmp/probe-ordinary.stdout" \
  2> "$accounted_tmp/probe-ordinary.stderr" || probe_ordinary_status=$?
[ "$probe_ordinary_status" -ne 0 ] &&
  [ "$(cat "$accounted_tmp/probe-ordinary.stderr")" = E_LIMIT ] ||
  fail 'ordinary 1,048,577-byte probe moved'

probe_accounted_root="$accounted_tmp/probe-accounted-root"
mkdir -m 700 "$probe_accounted_root"
probe_accounted_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" \
  --accounted-validation "$probe_accounted_root" 536870912 \
  validate-document "$probe_input" 3> "$accounted_tmp/probe-accounted.receipt" \
  > "$accounted_tmp/probe-accounted.stdout" \
  2> "$accounted_tmp/probe-accounted.stderr" || probe_accounted_status=$?
[ "$probe_accounted_status" -ne 0 ] &&
  [ "$(cat "$accounted_tmp/probe-accounted.stderr")" = E_LIMIT ] &&
  [ "$(receipt_bytes "$accounted_tmp/probe-accounted.receipt")" -ge 1048577 ] ||
  fail 'accounted 1,048,577-byte probe moved'

ordinary_bin="$accounted_tmp/ordinary-bin"
mkdir -p "$ordinary_bin"
for ordinary_tool in jq head wc cmp cat rm od awk mktemp dirname \
  sha256sum shasum; do
  if ordinary_tool_path="$(command -v "$ordinary_tool" 2>/dev/null)"; then
    ln -s "$ordinary_tool_path" "$ordinary_bin/$ordinary_tool"
  fi
done
[ ! -e "$ordinary_bin/stat" ] && [ ! -e "$ordinary_bin/mkdir" ] ||
  fail 'ordinary compatibility PATH contains accounted-only tools'
isolated_status=0
PATH="$ordinary_bin" /bin/bash "$package_wrapper" validate-document \
  "$accounted_registry" > "$accounted_tmp/isolated.stdout" \
  2> "$accounted_tmp/isolated.stderr" || isolated_status=$?
[ "$isolated_status" -ne 0 ] && [ ! -s "$accounted_tmp/isolated.stdout" ] &&
  [ "$(cat "$accounted_tmp/isolated.stderr")" = E_SHAPE ] ||
  fail 'ordinary mode requires accounted-only tools'

open_failure_bin="$accounted_tmp/open-failure-bin"
open_failure_root="$accounted_tmp/open-failure-root"
mkdir -p "$open_failure_bin"
mkdir -m 700 "$open_failure_root"
cat > "$open_failure_bin/head" <<'HEAD_OPEN_FAILURE'
#!/bin/bash
set -uo pipefail
status=0
"$ACCOUNTED_REAL_HEAD" "$@" || status=$?
/bin/mkdir "$ACCOUNTED_OPEN_FAILURE_ROOT/portable-core-accounted-v1/raw.1"
exit "$status"
HEAD_OPEN_FAILURE
chmod 0755 "$open_failure_bin/head"
open_failure_status=0
ACCOUNTED_REAL_HEAD="$(command -v head)" \
ACCOUNTED_OPEN_FAILURE_ROOT="$open_failure_root" \
  PATH="$open_failure_bin:$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$open_failure_root" 536870912 \
    validate-document "$accounted_registry" \
    3> "$accounted_tmp/open-failure.receipt" \
    > "$accounted_tmp/open-failure.stdout" \
    2> "$accounted_tmp/open-failure.stderr" || open_failure_status=$?
[ "$open_failure_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/open-failure.stdout" ] &&
  [ "$(cat "$accounted_tmp/open-failure.stderr")" = E_RUNTIME ] &&
  [ "$(receipt_bytes "$accounted_tmp/open-failure.receipt")" -eq 0 ] &&
  ! grep -Fq "$open_failure_root" "$accounted_tmp/open-failure.stderr" &&
  [ -z "$(find "$open_failure_root" -mindepth 1 -print -quit)" ] ||
  fail 'scratch open failure leaked its private path'

invalid_command_root="$accounted_tmp/invalid-command-root"
mkdir -m 700 "$invalid_command_root"
invalid_command_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" \
  --accounted-validation "$invalid_command_root" 536870912 invalid-command \
  3> "$accounted_tmp/invalid-command.receipt" \
  > "$accounted_tmp/invalid-command.stdout" \
  2> "$accounted_tmp/invalid-command.stderr" || invalid_command_status=$?
[ "$invalid_command_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/invalid-command.stdout" ] &&
  [ "$(cat "$accounted_tmp/invalid-command.stderr")" = E_USAGE ] &&
  [ "$(receipt_bytes "$accounted_tmp/invalid-command.receipt")" -eq 0 ] ||
  fail 'accepted accounted command failure omitted its receipt'

missing_package_root="$accounted_tmp/missing-package"
missing_package_scratch="$accounted_tmp/missing-package-scratch"
mkdir -p "$missing_package_root/scripts"
mkdir -m 700 "$missing_package_scratch"
cp "$accounted_wrapper" "$missing_package_root/scripts/core-contract.sh"
chmod 0755 "$missing_package_root/scripts/core-contract.sh"
missing_package_status=0
PATH="$accounted_path" /bin/bash \
  "$missing_package_root/scripts/core-contract.sh" \
  --accounted-validation "$missing_package_scratch" 536870912 \
  validate-document "$accounted_registry" \
  3> "$accounted_tmp/missing-package.receipt" \
  > "$accounted_tmp/missing-package.stdout" \
  2> "$accounted_tmp/missing-package.stderr" || missing_package_status=$?
[ "$missing_package_status" -ne 0 ] &&
  [ ! -s "$accounted_tmp/missing-package.stdout" ] &&
  [ "$(cat "$accounted_tmp/missing-package.stderr")" = E_RUNTIME ] &&
  [ "$(receipt_bytes "$accounted_tmp/missing-package.receipt")" -eq 0 ] ||
  fail 'accepted accounted package failure omitted its receipt'

mkdir_signal_bin="$accounted_tmp/mkdir-signal-bin"
mkdir_signal_root="$accounted_tmp/mkdir-signal-root"
mkdir_signal_marker="$accounted_tmp/mkdir-signal.marker"
mkdir -p "$mkdir_signal_bin"
mkdir -m 700 "$mkdir_signal_root"
cat > "$mkdir_signal_bin/mkdir" <<'MKDIR_SIGNAL'
#!/bin/bash
set -uo pipefail
status=0
"$ACCOUNTED_REAL_MKDIR" "$@" || status=$?
printf '%s\n' "$PPID" > "$ACCOUNTED_MKDIR_SIGNAL_MARKER"
kill -TERM "$PPID"
/bin/sleep 1
exit "$status"
MKDIR_SIGNAL
chmod 0755 "$mkdir_signal_bin/mkdir"
mkdir_signal_status=0
ACCOUNTED_REAL_MKDIR="$(command -v mkdir)" \
ACCOUNTED_MKDIR_SIGNAL_MARKER="$mkdir_signal_marker" \
  PATH="$mkdir_signal_bin:$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$mkdir_signal_root" 536870912 \
    validate-document "$accounted_registry" \
    3> "$accounted_tmp/mkdir-signal.receipt" \
    > "$accounted_tmp/mkdir-signal.stdout" \
    2> "$accounted_tmp/mkdir-signal.stderr" || mkdir_signal_status=$?
[ "$mkdir_signal_status" -ne 0 ] && [ -s "$mkdir_signal_marker" ] &&
  [ ! -s "$accounted_tmp/mkdir-signal.stdout" ] &&
  { [ ! -s "$accounted_tmp/mkdir-signal.stderr" ] ||
    [ "$(cat "$accounted_tmp/mkdir-signal.stderr")" = E_RUNTIME ]; } &&
  [ "$(receipt_bytes "$accounted_tmp/mkdir-signal.receipt")" -eq 0 ] &&
  [ -z "$(find "$mkdir_signal_root" -mindepth 1 -print -quit)" ] ||
  fail 'signal during mkdir left the accounted directory'

mkdir_retry_status=0
PATH="$accounted_path" /bin/bash "$package_wrapper" \
  --accounted-validation "$mkdir_signal_root" 536870912 \
  validate-document "$accounted_registry" \
  3> "$accounted_tmp/mkdir-retry.receipt" \
  > "$accounted_tmp/mkdir-retry.stdout" \
  2> "$accounted_tmp/mkdir-retry.stderr" || mkdir_retry_status=$?
[ "$mkdir_retry_status" -ne 0 ] &&
  [ "$(cat "$accounted_tmp/mkdir-retry.stderr")" = E_SHAPE ] &&
  [ "$(receipt_bytes "$accounted_tmp/mkdir-retry.receipt")" -gt 0 ] &&
  [ -z "$(find "$mkdir_signal_root" -mindepth 1 -print -quit)" ] ||
  fail 'post-signal mkdir retry did not start cleanly'

race_bin="$accounted_tmp/race-bin"
race_root="$accounted_tmp/race-root"
race_arrivals="$accounted_tmp/race.arrivals"
race_winner="$accounted_tmp/race.winner"
race_loser="$accounted_tmp/race.loser"
race_release="$accounted_tmp/race.release"
mkdir -p "$race_bin"
mkdir -m 700 "$race_root"
: > "$race_arrivals"
cat > "$race_bin/mkdir" <<'MKDIR_RACE'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$PPID" >> "$ACCOUNTED_RACE_ARRIVALS"
race_wait=0
while [ "$(/usr/bin/wc -l < "$ACCOUNTED_RACE_ARRIVALS" | tr -d ' ')" -lt 2 ] &&
      [ "$race_wait" -lt 100 ]; do
  /bin/sleep 0.1
  race_wait=$((race_wait + 1))
done
[ "$(/usr/bin/wc -l < "$ACCOUNTED_RACE_ARRIVALS" | tr -d ' ')" -ge 2 ] ||
  exit 96
if "$ACCOUNTED_REAL_MKDIR" "$@"; then
  printf '%s\n' "$PPID" > "$ACCOUNTED_RACE_WINNER"
  race_wait=0
  while [ ! -e "$ACCOUNTED_RACE_RELEASE" ] && [ "$race_wait" -lt 200 ]; do
    /bin/sleep 0.1
    race_wait=$((race_wait + 1))
  done
  [ -e "$ACCOUNTED_RACE_RELEASE" ] || exit 97
  exit 0
else
  race_status=$?
fi
printf '%s\n' "$PPID" > "$ACCOUNTED_RACE_LOSER"
exit "$race_status"
MKDIR_RACE
chmod 0755 "$race_bin/mkdir"
race_pids=()
for race_index in 1 2; do
  (
    race_status=0
    ACCOUNTED_REAL_MKDIR="$(command -v mkdir)" \
    ACCOUNTED_RACE_ARRIVALS="$race_arrivals" \
    ACCOUNTED_RACE_WINNER="$race_winner" \
    ACCOUNTED_RACE_LOSER="$race_loser" \
    ACCOUNTED_RACE_RELEASE="$race_release" \
      PATH="$race_bin:$accounted_path" /bin/bash "$package_wrapper" \
        --accounted-validation "$race_root" 536870912 \
        validate-document "$accounted_registry" \
        3> "$accounted_tmp/race-$race_index.receipt" \
        > "$accounted_tmp/race-$race_index.stdout" \
        2> "$accounted_tmp/race-$race_index.stderr" || race_status=$?
    printf '%s\n' "$race_status" > "$accounted_tmp/race-$race_index.status"
  ) &
  race_pid=$!
  race_pids+=("$race_pid")
  accounted_background_pids+=("$race_pid")
done

race_status_value() {
  if [ ! -s "$1" ]; then
    printf '%s' pending
  elif grep -Eq '^[0-9]+$' "$1"; then
    tr -d '\n' < "$1"
  else
    printf '%s' invalid
  fi
}

race_receipt_value() {
  if [ ! -s "$1" ]; then
    printf '%s' pending
  elif [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ] &&
       grep -Eq '^written-bytes:(0|[1-9][0-9]*)$' "$1"; then
    sed -n 's/^written-bytes://p' "$1"
  else
    printf '%s' invalid
  fi
}

race_token_value() {
  local token
  if [ ! -e "$1" ]; then
    printf '%s' pending
    return
  fi
  token="$(cat "$1")"
  case "$token" in
    '') printf '%s' empty ;;
    E_RUNTIME|E_SHAPE) printf '%s' "$token" ;;
    *) printf '%s' invalid ;;
  esac
}

race_bool() {
  if "$@"; then printf '%s' true
  else printf '%s' false
  fi
}

race_diagnostics() {
  printf 'race status1=%s status2=%s receipt1=%s receipt2=%s token1=%s token2=%s winner=%s loser=%s loser_done=%s directory=%s root_empty=%s status_ok=%s receipt_ok=%s tokens_ok=%s\n' \
    "$(race_status_value "$accounted_tmp/race-1.status")" \
    "$(race_status_value "$accounted_tmp/race-2.status")" \
    "$(race_receipt_value "$accounted_tmp/race-1.receipt")" \
    "$(race_receipt_value "$accounted_tmp/race-2.receipt")" \
    "$(race_token_value "$accounted_tmp/race-1.stderr")" \
    "$(race_token_value "$accounted_tmp/race-2.stderr")" \
    "$(race_bool test -s "$race_winner")" \
    "$(race_bool test -s "$race_loser")" \
    "$(race_bool test -s "$accounted_tmp/race-1.status" -o \
                       -s "$accounted_tmp/race-2.status")" \
    "$(race_bool test -d "$race_root/portable-core-accounted-v1")" \
    "$(race_bool test -z "$(find "$race_root" -mindepth 1 -print -quit)")" \
    "${race_status_ok:-pending}" "${race_receipt_ok:-pending}" \
    "${race_tokens_ok:-pending}" >&2
}

race_loser_done=false
race_parent_wait=0
while [ "$race_parent_wait" -lt 100 ]; do
  if [ -s "$race_loser" ] && [ -s "$race_winner" ] &&
     { [ -s "$accounted_tmp/race-1.status" ] ||
       [ -s "$accounted_tmp/race-2.status" ]; }; then
    race_loser_done=true
    break
  fi
  /bin/sleep 0.1
  race_parent_wait=$((race_parent_wait + 1))
done
if [ "$race_loser_done" != true ] || [ ! -s "$race_winner" ] ||
   [ ! -d "$race_root/portable-core-accounted-v1" ]; then
  race_diagnostics
  : > "$race_release"
  fail 'mkdir loser removed the winner directory'
fi
: > "$race_release"
for race_pid in "${race_pids[@]}"; do
  wait_probe "$race_pid" 'mkdir race invocation'
done
race_status_one="$(race_status_value "$accounted_tmp/race-1.status")"
race_status_two="$(race_status_value "$accounted_tmp/race-2.status")"
race_receipt_one="$(race_receipt_value "$accounted_tmp/race-1.receipt")"
race_receipt_two="$(race_receipt_value "$accounted_tmp/race-2.receipt")"
race_token_one="$(race_token_value "$accounted_tmp/race-1.stderr")"
race_token_two="$(race_token_value "$accounted_tmp/race-2.stderr")"
race_token_set="$(printf '%s\n' "$race_token_one" "$race_token_two" |
  LC_ALL=C sort)"
race_status_ok=false
if [[ "$race_status_one" =~ ^[0-9]+$ ]] &&
   [[ "$race_status_two" =~ ^[0-9]+$ ]] &&
   [ "$race_status_one" -ne 0 ] && [ "$race_status_two" -ne 0 ]; then
  race_status_ok=true
fi
race_receipt_ok=false
if [[ "$race_receipt_one" =~ ^[0-9]+$ ]] &&
   [[ "$race_receipt_two" =~ ^[0-9]+$ ]]; then
  if [ "$race_receipt_one" -eq 0 ] && [ "$race_receipt_two" -gt 0 ]; then
    race_receipt_ok=true
  elif [ "$race_receipt_two" -eq 0 ] && [ "$race_receipt_one" -gt 0 ]; then
    race_receipt_ok=true
  fi
fi
race_tokens_ok=false
[ "$race_token_set" = $'E_RUNTIME\nE_SHAPE' ] && race_tokens_ok=true
race_root_ok=false
[ -z "$(find "$race_root" -mindepth 1 -print -quit)" ] && race_root_ok=true
if [ "$race_status_ok" != true ] || [ "$race_receipt_ok" != true ] ||
   [ "$race_tokens_ok" != true ] || [ "$race_root_ok" != true ]; then
  race_diagnostics
  fail 'mkdir race receipts or ownership were invalid'
fi

signal_bin="$accounted_tmp/signal-bin"
signal_root="$accounted_tmp/signal-root"
signal_marker="$accounted_tmp/signal.marker"
signal_payload="$accounted_tmp/signal.payload"
mkdir -p "$signal_bin"
mkdir -m 700 "$signal_root"
cat > "$signal_bin/awk" <<'AWK_SIGNAL'
#!/bin/bash
set -uo pipefail
decode=false
for argument in "$@"; do
  case "$argument" in *'printf "%c"'*) decode=true ;; esac
done
if [ "$decode" = false ]; then
  exec "$ACCOUNTED_REAL_AWK" "$@"
fi
/bin/cat > "$ACCOUNTED_SIGNAL_PAYLOAD"
"$ACCOUNTED_REAL_AWK" '
  { for (i = 1; i <= NF; i++) if (++seen == 1) printf "%c", ($i + 0) }
' "$ACCOUNTED_SIGNAL_PAYLOAD"
printf '%s\n' "$PPID" > "$ACCOUNTED_SIGNAL_MARKER"
kill -TERM "$PPID"
/bin/sleep 1
"$ACCOUNTED_REAL_AWK" '
  { for (i = 1; i <= NF; i++) if (++seen > 1) printf "%c", ($i + 0) }
' "$ACCOUNTED_SIGNAL_PAYLOAD"
AWK_SIGNAL
chmod 0755 "$signal_bin/awk"
signal_status=0
ACCOUNTED_REAL_AWK="$(command -v awk)" \
ACCOUNTED_SIGNAL_MARKER="$signal_marker" \
ACCOUNTED_SIGNAL_PAYLOAD="$signal_payload" \
  PATH="$signal_bin:$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$signal_root" 536870912 \
    validate-document "$accounted_registry" \
    3> "$accounted_tmp/signal.receipt" \
    > "$accounted_tmp/signal.stdout" \
    2> "$accounted_tmp/signal.stderr" || signal_status=$?
signal_expected_bytes="$(wc -c < "$accounted_registry" | tr -d ' ')"
if [ "$signal_status" -eq 0 ] || [ ! -s "$signal_marker" ] ||
   [ -s "$accounted_tmp/signal.stdout" ] ||
   [ "$(cat "$accounted_tmp/signal.stderr")" != E_RUNTIME ] ||
   [ "$(receipt_bytes "$accounted_tmp/signal.receipt")" -ne \
     "$signal_expected_bytes" ] ||
   [ -n "$(find "$signal_root" -mindepth 1 -print -quit)" ]; then
  printf 'signal status=%s expected=%s receipt=%s stderr=%s\n' \
    "$signal_status" "$signal_expected_bytes" \
    "$(cat "$accounted_tmp/signal.receipt")" \
    "$(cat "$accounted_tmp/signal.stderr")" >&2
  fail 'deferred signal receipt did not match materialized bytes'
fi

valid_manifest_shas=()
for valid_index in 0 1 2 3; do
  valid_manifest_file="$accounted_tmp/valid-manifest-$valid_index.json"
  "$accounted_jq" -L "$accounted_root/scripts/test" -S -c -n \
    "import \"portable-core-assembly-fixtures\" as fixture;
     fixture::manifest_docs[$valid_index]" > "$valid_manifest_file"
  valid_manifest_shas+=("$(sha256_path "$valid_manifest_file")")
done
valid_manifest_map="$("$accounted_jq" -n \
  --arg producer "${valid_manifest_shas[0]}" \
  --arg publisher "${valid_manifest_shas[1]}" \
  --arg reviewer "${valid_manifest_shas[2]}" \
  --arg verifier "${valid_manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"
valid_profile="$accounted_tmp/valid-profile.json"
"$accounted_jq" -L "$accounted_root/scripts/test" -S -c -n \
  --argjson manifest_shas "$valid_manifest_map" '
    import "portable-core-assembly-fixtures" as fixture;
    fixture::profile_doc($manifest_shas)
  ' > "$valid_profile"

validator_fake_bin="$accounted_tmp/validator-fake-bin"
mkdir -p "$validator_fake_bin"
cat > "$validator_fake_bin/jq" <<'VALIDATOR_FAKE'
#!/bin/bash
set -uo pipefail
validator_call=false
for argument in "$@"; do
  case "$argument" in */contracts.jq) validator_call=true ;; esac
done
if [ "$validator_call" = false ]; then
  exec "$ACCOUNTED_REAL_JQ" "$@"
fi
validator_count="$(/bin/cat "$ACCOUNTED_VALIDATOR_COUNTER")"
validator_count=$((validator_count + 1))
printf '%s\n' "$validator_count" > "$ACCOUNTED_VALIDATOR_COUNTER"
case "$ACCOUNTED_VALIDATOR_MODE" in
  exact) printf 'E_SHAPE\n' ;;
  double-newline) printf 'E_SHAPE\n\n' ;;
  nul) printf 'E_SHAPE\000\n' ;;
  empty) ;;
  nonzero)
    printf 'E_SHAPE\n'
    exit 42
    ;;
  *) exit 43 ;;
esac
VALIDATOR_FAKE
chmod 0755 "$validator_fake_bin/jq"

run_validator_case() {
  local case_id="$1"
  local expected_status="$2"
  local expected_error="$3"
  local case_root="$accounted_tmp/validator-$case_id-root"
  local case_counter="$accounted_tmp/validator-$case_id.count"
  local case_status=0
  mkdir -m 700 "$case_root"
  printf '0\n' > "$case_counter"
  ACCOUNTED_REAL_JQ="$accounted_jq" \
  ACCOUNTED_VALIDATOR_COUNTER="$case_counter" \
  ACCOUNTED_VALIDATOR_MODE="$case_id" \
    PATH="$validator_fake_bin:$accounted_path" /bin/bash "$package_wrapper" \
      --accounted-validation "$case_root" 536870912 \
      validate-document "$accounted_registry" \
      3> "$accounted_tmp/validator-$case_id.receipt" \
      > "$accounted_tmp/validator-$case_id.stdout" \
      2> "$accounted_tmp/validator-$case_id.stderr" || case_status=$?
  [ "$case_status" -eq "$expected_status" ] &&
    [ ! -s "$accounted_tmp/validator-$case_id.stdout" ] &&
    [ "$(cat "$accounted_tmp/validator-$case_id.stderr")" = \
      "$expected_error" ] &&
    [ "$(cat "$case_counter")" -eq 1 ] &&
    [ "$(receipt_bytes "$accounted_tmp/validator-$case_id.receipt")" -gt 0 ] &&
    [ -z "$(find "$case_root" -mindepth 1 -print -quit)" ] ||
    fail "validator byte case failed: $case_id"
}

run_validator_case exact 1 E_SHAPE
run_validator_case double-newline 1 E_RUNTIME
run_validator_case nul 1 E_RUNTIME
run_validator_case empty 0 ''
run_validator_case nonzero 1 E_RUNTIME

finalization_root="$accounted_tmp/finalization-root"
finalization_marker="$accounted_tmp/finalization.marker"
mkdir -m 700 "$finalization_root"
finalization_status=0
(
  # shellcheck disable=SC2059,SC2329
  printf() {
    if [ "${1:-}" = 'written-bytes:%s\n' ] &&
       [ ! -e "$ACCOUNTED_FINALIZATION_MARKER" ]; then
      builtin printf '%s\n' TERM > "$ACCOUNTED_FINALIZATION_MARKER"
      kill -TERM "$$"
    fi
    builtin printf "$@"
  }
  export -f printf
  export ACCOUNTED_FINALIZATION_MARKER="$finalization_marker"
  PATH="$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$finalization_root" 536870912 \
    validate-document "$valid_profile" \
    3> "$accounted_tmp/finalization.receipt" \
    > "$accounted_tmp/finalization.stdout" \
    2> "$accounted_tmp/finalization.stderr"
) || finalization_status=$?
[ "$finalization_status" -ne 0 ] && [ -s "$finalization_marker" ] &&
  [ ! -s "$accounted_tmp/finalization.stdout" ] &&
  [ ! -s "$accounted_tmp/finalization.stderr" ] &&
  [ "$(receipt_bytes "$accounted_tmp/finalization.receipt")" -gt 0 ] &&
  [ -z "$(find "$finalization_root" -mindepth 1 -print -quit)" ] ||
  fail 'signal during final receipt duplicated or lost finalization'

close_signal_bin="$accounted_tmp/close-signal-bin"
close_signal_root="$accounted_tmp/close-signal-root"
close_signal_marker="$accounted_tmp/close-signal.marker"
mkdir -p "$close_signal_bin"
mkdir -m 700 "$close_signal_root"
cat > "$close_signal_bin/rm" <<'CLOSE_SIGNAL'
#!/bin/bash
set -uo pipefail
status=0
"$ACCOUNTED_REAL_RM" "$@" || status=$?
printf '%s\n' "$PPID" > "$ACCOUNTED_CLOSE_SIGNAL_MARKER"
kill -TERM "$PPID"
/bin/sleep 1
exit "$status"
CLOSE_SIGNAL
chmod 0755 "$close_signal_bin/rm"
close_signal_status=0
ACCOUNTED_REAL_RM="$(command -v rm)" \
ACCOUNTED_CLOSE_SIGNAL_MARKER="$close_signal_marker" \
  PATH="$close_signal_bin:$accounted_path" /bin/bash "$package_wrapper" \
    --accounted-validation "$close_signal_root" 536870912 \
    validate-document "$valid_profile" \
    3> "$accounted_tmp/close-signal.receipt" \
    > "$accounted_tmp/close-signal.stdout" \
    2> "$accounted_tmp/close-signal.stderr" || close_signal_status=$?
[ "$close_signal_status" -ne 0 ] && [ -s "$close_signal_marker" ] &&
  [ ! -s "$accounted_tmp/close-signal.stdout" ] &&
  [ ! -s "$accounted_tmp/close-signal.stderr" ] &&
  [ "$(receipt_bytes "$accounted_tmp/close-signal.receipt")" -gt 0 ] &&
  [ -z "$(find "$close_signal_root" -mindepth 1 -print -quit)" ] ||
  fail 'signal during close interrupted cleanup or receipt'

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

printf 'portable core accounted validation: 39/39 passed\n'
