#!/bin/bash
# shellcheck disable=SC2016
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

verify_hash() {
  [ -f "$2" ] && [ ! -L "$2" ] &&
    [ "$(sha256_path "$2")" = "$1" ]
}

[ "$#" -eq 7 ] && [ "$1" = run ] || emit_error E_USAGE
runtime=$2
input=$3
evaluator=$4
evaluator_sha256=$5
seed_set_sha256=$6
observed_at=$7
[[ "$observed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
  emit_error E_USAGE

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
catalog="$runtime/catalog.json"
core_front_door="$runtime/scripts/core-contract.sh"
scanner="$runtime/orchestrator/v1/scan-state.sh"
scanner_sha256=556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5
planner="$runtime/orchestrator/v1/reconciliation-plan.jq"
planner_sha256=03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4
jq_bin="$runtime/bin/jq"
work="$runtime_parent/work"
program_sha256=c141ed838ec480e27a2bc9f6535b99b686100c613a1a1e3ff7f21cd161823776
driver_sha256=$(sha256_path "$self") || emit_error E_RUNTIME

verify_runtime() {
  verify_hash "$program_sha256" "$program" &&
  verify_hash b8d8bfeb88c13bebb35f3f4112298db7d3505d3f4085d0c7712769576720d083 "$catalog" &&
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
    "$core_front_door" &&
  verify_hash "$scanner_sha256" "$scanner" &&
  verify_hash "$planner_sha256" "$planner" &&
  verify_hash 5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b \
    "$runtime/orchestrator/v1/state-scanner-driver.sh" &&
  verify_hash 9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb \
    "$runtime/orchestrator/v1/state-scanner-launcher.sh" &&
  verify_hash 722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae \
    "$runtime/orchestrator/v1/state-scanner.jq" &&
  verify_hash "$evaluator_sha256" "$evaluator" &&
  verify_hash "$seed_set_sha256" "$input"
}
verify_runtime || emit_error E_STALE
[ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_RUNTIME
[ -d "$work" ] && [ ! -L "$work" ] || emit_error E_RUNTIME

run_program() {
  "$jq_bin" -S -c -n -L "$modules" \
    --arg evals_operation "$1" \
    --arg program_sha256 "$program_sha256" --arg driver_sha256 "$driver_sha256" \
    --arg catalog_sha256 b8d8bfeb88c13bebb35f3f4112298db7d3505d3f4085d0c7712769576720d083 \
    --arg evaluator_sha256 "$evaluator_sha256" \
    --arg seed_set_sha256 "$seed_set_sha256" \
    --arg tool_sha256 b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9 \
    --arg scanner_sha256 "$scanner_sha256" --arg planner_sha256 "$planner_sha256" \
    --arg observed_at "$observed_at" \
    --slurpfile catalog_docs "$catalog" \
    --slurpfile seed_set_docs "$input" \
    --slurpfile observation_docs "$2" \
    --slurpfile evaluator_docs "$evaluator" \
    --slurpfile candidate_docs "$3" \
    -f "$program"
}

# The seed set is caller input: it must be one parseable JSON root before any
# contract runs, so a broken file reads as a parse error and nothing else.
"$jq_bin" -e -n --slurpfile roots "$input" '($roots | length) == 1' \
  >/dev/null 2>&1 || emit_error E_PARSE

/usr/bin/printf '[]\n' > "$work/empty-observations.json" || emit_error E_RUNTIME
/usr/bin/printf '{}\n' > "$work/empty-candidate.json" || emit_error E_RUNTIME
[ "$(run_program validate-catalog "$work/empty-observations.json" \
      "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_STALE
[ "$(run_program validate-seed-set "$work/empty-observations.json" \
      "$work/empty-candidate.json" 2>/dev/null)" = true ] || emit_error E_SHAPE

seed_source=$("$jq_bin" -r '.body.seed_source // empty' "$input") || emit_error E_RUNTIME
case "$seed_source" in
  core.stage-run.v2|orchestrator.reconciliation-plan.v1|orchestrator.state-scanner.v1) ;;
  *) emit_error E_SHAPE ;;
esac
case_count=$("$jq_bin" -r '.body.cases | length' "$input") || emit_error E_RUNTIME
[[ "$case_count" =~ ^[1-9][0-9]?$ ]] && [ "$case_count" -le 64 ] || emit_error E_SHAPE
observations="$work/observations.json"
/usr/bin/printf '[' > "$observations" || emit_error E_RUNTIME

record_observation() {
  if [ "$i" -gt 0 ]; then /usr/bin/printf ',' >> "$observations" || emit_error E_RUNTIME; fi
  /usr/bin/printf '%s' "$1" >> "$observations" || emit_error E_RUNTIME
}

# Orchestrator snapshots replay through the real state scanner. The scanner
# finds its jq under TMPDIR and its core under its own repo root, so both are
# staged inside the private runtime; nothing outside it is read.
replay_scanner_cases() {
  local platform jq_asset scanner_tmp snapshot_doc repository_id commit_id
  local scan_out scan_err scan_status classification token observation
  platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m) || emit_error E_RUNTIME
  case "$platform" in
    Linux:x86_64) jq_asset=jq-linux64 ;;
    Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64 ;;
    *) emit_error E_RUNTIME ;;
  esac
  scanner_tmp="$work/scanner-tmp"
  /bin/mkdir -m 0700 "$scanner_tmp" "$scanner_tmp/ystack-portable-core-jq16" ||
    emit_error E_RUNTIME
  /bin/cp "$jq_bin" "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  /bin/chmod 0500 "$scanner_tmp/ystack-portable-core-jq16/$jq_asset" || emit_error E_RUNTIME
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    snapshot_doc="$work/snapshot-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].snapshot.content" "$input" > "$snapshot_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$snapshot_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].snapshot.sha256" "$input")" ] || emit_error E_RELATION
    repository_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.repository_id" "$input") ||
      emit_error E_RUNTIME
    commit_id=$("$jq_bin" -r ".body.cases[$i].expected_revision.commit_id" "$input") ||
      emit_error E_RUNTIME
    scan_out="$work/scan-$i.out"
    scan_err="$work/scan-$i.err"
    /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$scanner_tmp" \
      /bin/bash "$scanner" scan "$repository_id" "$commit_id" "$snapshot_doc" \
      </dev/null >"$scan_out" 2>"$scan_err"
    scan_status=$?
    if [ "$scan_status" -eq 0 ]; then
      [ ! -s "$scan_err" ] || emit_error E_RUNTIME
      classification=$("$jq_bin" -S -c '
        if (.body.classifications | length) == 1 then
          .body.classifications[0] |
          {action:.recovery.action,class:.class,reason_id:.recovery.reason_id}
        else empty end' "$scan_out") || emit_error E_RUNTIME
      [ -n "$classification" ] || emit_error E_RELATION
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        --argjson classification "$classification" \
        '{case_id:$case_id,disposition:"observed",
          classification:{state:"present",value:$classification},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$scan_out" ] || emit_error E_RUNTIME
      token=$(/bin/cat "$scan_err" 2>/dev/null) || emit_error E_RUNTIME
      case "$token" in
        E_CANONICAL|E_LIMIT|E_PARSE|E_RELATION|E_RUNTIME|E_SHAPE|E_STALE|E_USAGE) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
        '{case_id:$case_id,disposition:"rejected",classification:{state:"absent"},
          error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Planner bundles replay through the real reconciliation planner, pure jq over
# the private modules. Exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator,
# is recorded; a refusal is recorded by its one token.
replay_planner_cases() {
  local input_doc plan_out plan_err plan_status summary observation
  i=0
  while [ "$i" -lt "$case_count" ]; do
    case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
    input_doc="$work/plan-input-$i.json"
    "$jq_bin" -S -c ".body.cases[$i].input.content" "$input" > "$input_doc" ||
      emit_error E_RUNTIME
    [ "$(sha256_path "$input_doc")" = \
      "$("$jq_bin" -r ".body.cases[$i].input.sha256" "$input")" ] || emit_error E_RELATION
    plan_out="$work/plan-$i.out"
    plan_err="$work/plan-$i.err"
    "$jq_bin" -L "$modules" -S -c -f "$planner" "$input_doc" \
      </dev/null >"$plan_out" 2>"$plan_err"
    plan_status=$?
    if [ "$plan_status" -eq 0 ]; then
      [ ! -s "$plan_err" ] || emit_error E_RUNTIME
      summary=$("$jq_bin" -S -c '
        def item: .delivery_key |
          {attempt_number,operation,request_sha256,stage_key};
        {deliveries:[.body.deliveries[] | item + {delivery_mode}],
         deferred:[.body.deferred[] | item + {reason_id}],
         suppressed:[.body.suppressed[] | item + {reason_id}],
         operator_messages:[.body.operator_messages[] |
           {action:.recovery.action,class,stage_key}]}' "$plan_out") || emit_error E_RUNTIME
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --argjson plan "$summary" \
        '{case_id:$case_id,disposition:"planned",plan:{state:"present",value:$plan},
          error_token:{state:"absent"}}') || emit_error E_RUNTIME
    else
      [ ! -s "$plan_out" ] || emit_error E_RUNTIME
      case "$(/bin/cat "$plan_err" 2>/dev/null)" in
        *E_RECONCILIATION_INPUT*) ;;
        *) emit_error E_RUNTIME ;;
      esac
      observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" \
        '{case_id:$case_id,disposition:"rejected",plan:{state:"absent"},
          error_token:{state:"present",value:"E_RECONCILIATION_INPUT"}}') || emit_error E_RUNTIME
    fi
    record_observation "$observation"
    i=$((i + 1))
  done
}

# Canonical documents for one case, each checked against its recorded digest
# before the core sees it. The core is the only judge; the driver only records.
replay_stage_run_cases() {
resolved_doc="$work/resolved.json"
"$jq_bin" -S -c '.body.shared.resolved_profile.content' "$input" > "$resolved_doc" ||
  emit_error E_RUNTIME
[ "$(sha256_path "$resolved_doc")" = \
  "$("$jq_bin" -r '.body.shared.resolved_profile.sha256' "$input")" ] ||
  emit_error E_RELATION
i=0
while [ "$i" -lt "$case_count" ]; do
  case_id=$("$jq_bin" -r ".body.cases[$i].case_id" "$input") || emit_error E_RUNTIME
  role=$("$jq_bin" -r ".body.cases[$i].request_role" "$input") || emit_error E_RUNTIME
  case "$role" in producer|reviewer|verifier) ;; *) emit_error E_SHAPE ;; esac
  request_doc="$work/request-$i.json"
  result_doc="$work/result-$i.json"
  "$jq_bin" -S -c --arg role "$role" '.body.shared.requests[$role].content' \
    "$input" > "$request_doc" || emit_error E_RUNTIME
  [ "$(sha256_path "$request_doc")" = \
    "$("$jq_bin" -r --arg role "$role" '.body.shared.requests[$role].sha256' "$input")" ] ||
    emit_error E_RELATION
  "$jq_bin" -S -c ".body.cases[$i].result.content" "$input" > "$result_doc" ||
    emit_error E_RUNTIME
  [ "$(sha256_path "$result_doc")" = \
    "$("$jq_bin" -r ".body.cases[$i].result.sha256" "$input")" ] || emit_error E_RELATION
  status_value=$("$jq_bin" -r '.body.status // empty' "$result_doc") || emit_error E_RUNTIME

  core_err="$work/core-$i.err"
  core_out="$work/core-$i.out"
  /usr/bin/env -i LC_ALL=C PATH="$runtime/bin:/usr/bin:/bin" TMPDIR="$work" \
    /bin/bash "$core_front_door" validate-stage-run \
    "$request_doc" "$resolved_doc" "$result_doc" </dev/null 3>&- >"$core_out" 2>"$core_err"
  core_status=$?
  [ ! -s "$core_out" ] || emit_error E_RUNTIME
  if [ "$core_status" -eq 0 ]; then
    [ ! -s "$core_err" ] || emit_error E_RUNTIME
    case "$status_value" in
      blocked|cancelled|completed|failed|skipped|stale) ;;
      *) emit_error E_RELATION ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg status "$status_value" \
      '{case_id:$case_id,disposition:"accepted",status:{state:"present",value:$status},
        error_token:{state:"absent"}}') || emit_error E_RUNTIME
  else
    token=$(/bin/cat "$core_err" 2>/dev/null) || emit_error E_RUNTIME
    case "$token" in
      E_CANONICAL|E_LIMIT|E_PARSE|E_REF|E_RELATION|E_RUNTIME|E_SHAPE|E_USAGE) ;;
      *) emit_error E_RUNTIME ;;
    esac
    observation=$("$jq_bin" -S -c -n --arg case_id "$case_id" --arg token "$token" \
      '{case_id:$case_id,disposition:"rejected",status:{state:"absent"},
        error_token:{state:"present",value:$token}}') || emit_error E_RUNTIME
  fi
  record_observation "$observation"
  i=$((i + 1))
done
}

case "$seed_source" in
  core.stage-run.v2) replay_stage_run_cases ;;
  orchestrator.state-scanner.v1) replay_scanner_cases ;;
  *) replay_planner_cases ;;
esac
/usr/bin/printf ']\n' >> "$observations" || emit_error E_RUNTIME

result="$work/run-result.json"
run_program build-run-result "$observations" "$work/empty-candidate.json" \
  > "$result" 2>/dev/null || emit_error E_RUNTIME
[ "$(run_program validate-run-result "$observations" "$result" 2>/dev/null)" = true ] ||
  emit_error E_RUNTIME
verify_runtime || emit_error E_STALE
/bin/cat "$result" || emit_error E_RUNTIME
