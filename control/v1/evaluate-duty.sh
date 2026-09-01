#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_POLICY_SET|E_CORE|E_RELATION)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 5 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-duty.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/duty-separation-policy.json"
program="$source_dir/duty-separation.jq"
policy_validator="$source_dir/validate.sh"
core_validator="$repo/scripts/core-contract.sh"
for required in "$source_path" "$policy" "$program" "$policy_validator" "$core_validator"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_RUNTIME
done
for input in "$@"; do
  [ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
done
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-duty.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM
names=(policy-set request resolved result)
index=0
for input in "$@"; do
  snapshot="$scratch/${names[$index]}.json"
  /bin/dd if="$input" of="$snapshot" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$snapshot" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
  index=$((index + 1))
done
/bin/dd if="$policy" of="$scratch/policy.json" bs=1048577 count=1 2>/dev/null ||
  emit_error E_RUNTIME
size=$(/usr/bin/wc -c <"$scratch/policy.json" | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[ "$size" -le 1048576 ] || emit_error E_LIMIT

PATH="${jq_bin%/*}:/usr/bin:/bin" "$policy_validator" validate \
  "$scratch/policy-set.json" >"$scratch/policy.out" 2>"$scratch/policy.err" ||
  emit_error E_POLICY_SET
policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
core_package_sha=$(sha256_path "$core_validator") || emit_error E_RUNTIME
generation_id=$("$jq_bin" -er '.body.core_contract.generation_id' \
  "$scratch/policy-set.json" 2>/dev/null) || emit_error E_RELATION
generation_id_sha=$(sha256_text "$generation_id") || emit_error E_RUNTIME

"$jq_bin" -e --arg policy_sha "$policy_sha" \
  --arg generation_id_sha "$generation_id_sha" \
  --arg core_package_sha "$core_package_sha" \
  --slurpfile policy "$scratch/policy.json" '
  .body.core_contract.semantic_identity == $policy[0].body.core_contract.semantic_identity and
  $generation_id_sha == $policy[0].body.core_contract.generation_id_sha256 and
  .body.core_contract.package_ref == $policy[0].body.core_contract.package_ref and
  $core_package_sha == $policy[0].body.core_contract.package_ref.sha256 and
  ([.body.sections[] | select(.section_id == "duty-separation")] | length) == 1 and
  ([.body.sections[] | select(.section_id == "duty-separation")][0].policy_ref == {
    content_id:$policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",
    sha256:$policy_sha
  })
' "$scratch/policy-set.json" >/dev/null 2>&1 || emit_error E_RELATION

PATH="${jq_bin%/*}:/usr/bin:/bin" "$core_validator" validate-document \
  "$scratch/resolved.json" >"$scratch/core.out" 2>"$scratch/core.err" || emit_error E_CORE
PATH="${jq_bin%/*}:/usr/bin:/bin" "$core_validator" validate-stage-run \
  "$scratch/request.json" "$scratch/resolved.json" "$scratch/result.json" \
  >"$scratch/run.out" 2>"$scratch/run.err" || emit_error E_CORE
post_core_package_sha=$(sha256_path "$core_validator") || emit_error E_RUNTIME
[ "$post_core_package_sha" = "$core_package_sha" ] || emit_error E_RELATION

"$jq_bin" -S -c -n -f "$program" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --arg policy_set_sha "$policy_set_sha" \
  --arg resolved_sha "$resolved_sha" --arg request_sha "$request_sha" \
  --arg result_sha "$result_sha" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
