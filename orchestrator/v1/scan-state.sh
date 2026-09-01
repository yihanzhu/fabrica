#!/bin/bash
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_PARSE|E_CANONICAL|E_SHAPE|E_RELATION|E_STALE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

sha256_path() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

sha256_line() {
  /usr/bin/printf '%s\n' "$1" | /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

verify_hash() {
  [ -f "$2" ] && [ ! -L "$2" ] &&
    [ "$(sha256_path "$2")" = "$1" ]
}

verify_core() {
  verify_hash bdb5def832e8e611bba8a7b30a2aae95ea4f2701c44b198cf51cd3dfd9ff88f3 \
    "$wrapper" &&
  verify_hash f55b697716dc13a6d2c71bde7769493b3f4b091fd7a94d3280c5d417974df3a1 \
    "$registry" &&
  verify_hash 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade \
    "$modules/schema.jq" &&
  verify_hash c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 \
    "$modules/profile_graph.jq" &&
  verify_hash 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e \
    "$modules/stage_request.jq" &&
  verify_hash 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 \
    "$modules/result_facts.jq" &&
  verify_hash ed992f26761d08e3c3f5ab57eda9bcd771ad59e3aebeb02643de88844184d2d3 \
    "$modules/result_truth.jq"
}

[ "$#" -eq 4 ] && [ "$1" = scan ] || emit_error E_USAGE
expected_repository_id=$2
expected_commit_id=$3
input=$4
[[ "$expected_repository_id" =~ ^[a-z0-9][a-z0-9._:-]{0,127}$ ]] ||
  emit_error E_USAGE
[[ "$expected_commit_id" =~ ^[0-9a-f]{40}$ ]] ||
  [[ "$expected_commit_id" =~ ^[0-9a-f]{64}$ ]] || emit_error E_USAGE

source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
[ -f "$source_path" ] && [ ! -L "$source_path" ] || emit_error E_RUNTIME
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/scan-state.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
[ "$source_dir" = "$repo/orchestrator/v1" ] || emit_error E_RUNTIME

generation=g-392d20099dfa99872764009b268c8871914b4dbc0da467ec346baa921818ae3e
modules="$repo/core/v2/generations/$generation/modules"
program="$source_dir/state-scanner.jq"
registry="$repo/core/v2/generation-registry.json"
wrapper="$repo/scripts/core-contract.sh"
for required_dir in "$repo" "$repo/orchestrator" "$source_dir" "$repo/core" \
  "$repo/core/v2" "$repo/core/v2/generations" "${modules%/modules}" "$modules"; do
  [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || emit_error E_RUNTIME
done
verify_hash 7210dbdf53ce07a3d7274732d22cf2f53245a1968dbd54ba7c8a6b77b1c4b831 "$program" || emit_error E_RUNTIME
verify_core || emit_error E_STALE

[ -f "$input" ] && [ ! -L "$input" ] || emit_error E_RUNTIME
jq_bin=$(command -v jq 2>/dev/null) || emit_error E_RUNTIME
case "$jq_bin" in /*) ;; *) emit_error E_RUNTIME ;; esac
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-state-scan.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

raw="$scratch/raw.json"
/bin/dd if="$input" of="$raw" bs=1048577 count=1 2>/dev/null || emit_error E_RUNTIME
raw_size=$(/usr/bin/wc -c < "$raw" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
[ "$raw_size" -le 1048576 ] || emit_error E_LIMIT
bom=$(/usr/bin/od -An -tx1 -N3 "$raw" 2>/dev/null | /usr/bin/tr -d ' \n') ||
  emit_error E_RUNTIME
[ "$bom" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$raw" >/dev/null 2>&1 || emit_error E_PARSE
[ "$("$jq_bin" -s 'length' "$raw" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
canonical="$scratch/canonical.json"
"$jq_bin" -S -c . "$raw" > "$canonical" 2>/dev/null || emit_error E_PARSE
/usr/bin/cmp -s "$raw" "$canonical" || emit_error E_CANONICAL

"$jq_bin" -e '
  def depth:
    if type == "array" then (if length == 0 then 1 else 1 + ([.[]|depth]|max) end)
    elif type == "object" then (if length == 0 then 1 else 1 + ([.[]|depth]|max) end)
    else 1 end;
  def members:
    if type == "array" then length + ([.[]|members]|add // 0)
    elif type == "object" then (keys_unsorted|length) + ([.[]|members]|add // 0)
    else 0 end;
  def strings_ok:
    if type == "array" then all(.[];strings_ok)
    elif type == "object" then
      all(keys_unsorted[];utf8bytelength <= 8192) and all(.[];strings_ok)
    elif type == "string" then utf8bytelength <= 8192 else true end;
  depth <= 32 and members <= 16384 and strings_ok
' "$raw" >/dev/null 2>&1 || emit_error E_LIMIT

result=$("$jq_bin" -L "$modules" -S -c -r \
  --arg expected_repository_id "$expected_repository_id" \
  --arg expected_commit_id "$expected_commit_id" \
  -f "$program" "$raw" 2>/dev/null) || emit_error E_RUNTIME
case "$result" in
  E_SHAPE|E_RELATION|E_STALE) emit_error "$result" ;;
  \{*) ;;
  *) emit_error E_RUNTIME ;;
esac

item_count=$("$jq_bin" -r '.body.items | length' "$raw" 2>/dev/null) ||
  emit_error E_RUNTIME
i=0
while [ "$i" -lt "$item_count" ]; do
  for pair_name in request resolved_profile; do
    expected=$("$jq_bin" -r ".body.items[$i].$pair_name.sha256 // empty" "$raw") ||
      emit_error E_PARSE
    content=$("$jq_bin" -S -c ".body.items[$i].$pair_name.content" "$raw") ||
      emit_error E_PARSE
    [ -n "$expected" ] && [ "$(sha256_line "$content")" = "$expected" ] ||
      emit_error E_RELATION
  done
  if [ "$("$jq_bin" -r ".body.items[$i].latest_result.state // empty" "$raw")" = present ]; then
    expected=$("$jq_bin" -r ".body.items[$i].latest_result.value.sha256 // empty" "$raw") ||
      emit_error E_PARSE
    content=$("$jq_bin" -S -c ".body.items[$i].latest_result.value.content" "$raw") ||
      emit_error E_PARSE
    [ -n "$expected" ] && [ "$(sha256_line "$content")" = "$expected" ] ||
      emit_error E_RELATION
  fi
  i=$((i + 1))
done

verify_hash 7210dbdf53ce07a3d7274732d22cf2f53245a1968dbd54ba7c8a6b77b1c4b831 "$program" || emit_error E_RUNTIME
verify_core || emit_error E_STALE
/usr/bin/printf '%s\n' "$result"
trap - EXIT HUP INT TERM
cleanup
