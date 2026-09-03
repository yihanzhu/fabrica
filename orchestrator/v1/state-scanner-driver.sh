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
  builtin printf '%s\n' "$1" | /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

verify_hash() {
  [ -f "$2" ] && [ ! -L "$2" ] &&
    [ "$(sha256_path "$2")" = "$1" ]
}

[ "$#" -eq 8 ] && [ "$1" = run ] || emit_error E_USAGE
expected_repository_id=$2
expected_commit_id=$3
runtime=$4
input=$5
evaluator=$6
evaluator_sha256=$7
snapshot_sha256=$8

self=${BASH_SOURCE[0]}
case "$self" in /*) ;; *) emit_error E_RUNTIME ;; esac
self_dir=$(CDPATH='' cd -P -- "${self%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
self="$self_dir/${self##*/}"
[ "$self" = "$runtime/driver.sh" ] && [ "$self_dir" = "$runtime" ] ||
  emit_error E_RUNTIME
[ -d "$runtime" ] && [ ! -L "$runtime" ] || emit_error E_RUNTIME
runtime_parent=${runtime%/*}
case "$input" in "$runtime_parent"/input.json) ;; *) emit_error E_RUNTIME ;; esac
case "$evaluator" in "$runtime"/evaluator.json) ;; *) emit_error E_RUNTIME ;; esac

generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
modules="$runtime/core/v2/generations/$generation/modules"
program="$runtime/program.jq"
jq_bin="$runtime/jq"
work="$runtime_parent/work"
verify_runtime() {
  verify_hash 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae \
    "$program" &&
  verify_hash 3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94 \
    "$runtime/core/v2/generation-registry.json" &&
  verify_hash 65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a \
    "$runtime/core/v2/generations/$generation/contracts.jq" &&
  verify_hash dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8 \
    "$runtime/core/v2/generations/$generation/core-ingress.sh" &&
  verify_hash c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207 \
    "$modules/profile_graph.jq" &&
  verify_hash 8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281 \
    "$modules/result_facts.jq" &&
  verify_hash ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46 \
    "$modules/result_truth.jq" &&
  verify_hash 8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade \
    "$modules/schema.jq" &&
  verify_hash 6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e \
    "$modules/stage_request.jq" &&
  verify_hash b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    "$runtime/scripts/core-contract.sh" &&
  [ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  { [ "$(sha256_path "$jq_bin")" = \
        af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ] ||
    [ "$(sha256_path "$jq_bin")" = \
        5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ]; }
}

verify_runtime || emit_error E_STALE
[ -d "$work" ] && [ ! -L "$work" ] || emit_error E_RUNTIME
[ -f "$input" ] && [ ! -L "$input" ] &&
  [ "$(sha256_path "$input")" = "$snapshot_sha256" ] || emit_error E_RUNTIME
[ -f "$evaluator" ] && [ ! -L "$evaluator" ] &&
  [ "$(sha256_path "$evaluator")" = "$evaluator_sha256" ] || emit_error E_RUNTIME

raw_size=$(/usr/bin/wc -c < "$input" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
[ "$raw_size" -le 1048576 ] || emit_error E_LIMIT
bom=$(/usr/bin/od -An -tx1 -N3 "$input" 2>/dev/null | /usr/bin/tr -d ' \n') ||
  emit_error E_RUNTIME
[ "$bom" != efbbbf ] || emit_error E_PARSE
"$jq_bin" . "$input" >/dev/null 2>&1 || emit_error E_PARSE
[ "$("$jq_bin" -s 'length' "$input" 2>/dev/null)" -eq 1 ] || emit_error E_PARSE
"$jq_bin" -S -c . "$input" > "$work/input-canonical.json" 2>/dev/null ||
  emit_error E_PARSE
/usr/bin/cmp -s "$input" "$work/input-canonical.json" || emit_error E_CANONICAL
"$jq_bin" -S -c . "$evaluator" > "$work/evaluator-canonical.json" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$evaluator" "$work/evaluator-canonical.json" || emit_error E_RUNTIME

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
' "$input" >/dev/null 2>&1 || emit_error E_LIMIT

item_count=$("$jq_bin" -r '
  .body.items | if type == "array" then length else 0 end
' "$input" 2>/dev/null) || emit_error E_RUNTIME
: >"$work/item-sha-lines"
i=0
while [ "$i" -lt "$item_count" ]; do
  content=$("$jq_bin" -S -c ".body.items[$i]" "$input") || emit_error E_RUNTIME
  sha256_line "$content" >>"$work/item-sha-lines" || emit_error E_RUNTIME
  i=$((i + 1))
done
"$jq_bin" -R -s -c 'split("\n")[:-1]' "$work/item-sha-lines" \
  >"$work/item-shas.json" 2>/dev/null || emit_error E_RUNTIME

result=$("$jq_bin" -L "$modules" -S -c -r \
  --arg scanner_operation scan \
  --arg expected_repository_id "$expected_repository_id" \
  --arg expected_commit_id "$expected_commit_id" \
  --arg snapshot_sha256 "$snapshot_sha256" \
  --arg evaluator_sha256 "$evaluator_sha256" \
  --slurpfile evaluator_docs "$evaluator" \
  --slurpfile item_sha_docs "$work/item-shas.json" \
  --slurpfile snapshot_docs /dev/null --slurpfile candidate_docs /dev/null \
  -f "$program" "$input" 2>/dev/null) || emit_error E_RUNTIME
case "$result" in E_SHAPE|E_RELATION|E_STALE) emit_error "$result" ;; esac

/usr/bin/printf '%s\n' "$result" > "$work/candidate.json"
"$jq_bin" -S -c . "$work/candidate.json" > "$work/candidate-canonical.json" \
  2>/dev/null || emit_error E_RUNTIME
/usr/bin/cmp -s "$work/candidate.json" "$work/candidate-canonical.json" ||
  emit_error E_RUNTIME

i=0
while [ "$i" -lt "$item_count" ]; do
  for pair_name in request resolved_profile; do
    expected=$("$jq_bin" -r ".body.items[$i].$pair_name.sha256 // empty" "$input") ||
      emit_error E_RUNTIME
    content=$("$jq_bin" -S -c ".body.items[$i].$pair_name.content" "$input") ||
      emit_error E_RUNTIME
    [ -n "$expected" ] && [ "$(sha256_line "$content")" = "$expected" ] ||
      emit_error E_RELATION
  done
  if [ "$("$jq_bin" -r ".body.items[$i].latest_result.state" "$input")" = present ]; then
    expected=$("$jq_bin" -r ".body.items[$i].latest_result.value.sha256" "$input") ||
      emit_error E_RUNTIME
    content=$("$jq_bin" -S -c ".body.items[$i].latest_result.value.content" "$input") ||
      emit_error E_RUNTIME
    [ "$(sha256_line "$content")" = "$expected" ] || emit_error E_RELATION
  fi
  i=$((i + 1))
done

"$jq_bin" -n -e -L "$modules" \
  --arg scanner_operation validate-observation \
  --arg expected_repository_id "$expected_repository_id" \
  --arg expected_commit_id "$expected_commit_id" \
  --arg snapshot_sha256 "$snapshot_sha256" \
  --arg evaluator_sha256 "$evaluator_sha256" \
  --slurpfile evaluator_docs "$evaluator" \
  --slurpfile item_sha_docs "$work/item-shas.json" \
  --slurpfile snapshot_docs "$input" \
  --slurpfile candidate_docs "$work/candidate.json" \
  -f "$program" >/dev/null 2>&1 || emit_error E_RUNTIME
verify_runtime || emit_error E_STALE
[ "$(sha256_path "$input")" = "$snapshot_sha256" ] &&
  [ "$(sha256_path "$evaluator")" = "$evaluator_sha256" ] || emit_error E_RUNTIME
/bin/cat "$work/candidate.json"
