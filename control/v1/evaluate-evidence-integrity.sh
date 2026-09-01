#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_RELATION|E_POLICY_SET|E_CORE)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 6 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-evidence-integrity.sh" ] ||
  emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/evidence-integrity-policy.json"
decision="$source_dir/evidence-integrity-decision.json"
program="$source_dir/evidence-integrity.jq"
policy_validator="$source_dir/validate.sh"
validator_program="$source_dir/policy-set.jq"
core_driver="$repo/scripts/core-contract.sh"
for required in "$source_path" "$policy" "$decision" "$program" \
  "$policy_validator" "$validator_program" "$core_driver"; do
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
selected_core_generation() {
  local wrapper=$1 selected assignment_count
  assignment_count=$(/usr/bin/grep -Ec \
    '^[[:space:]]*PORTABLE_CORE_GENERATION=' "$wrapper") || return 1
  [ "$assignment_count" -eq 1 ] || return 1
  selected=$(/usr/bin/sed -n \
    "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
    "$wrapper") || return 1
  [[ "$selected" =~ ^g-[0-9a-f]{64}$ ]] || return 1
  /usr/bin/printf '%s\n' "$selected"
}

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evidence.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
trap cleanup EXIT
trap signal_exit HUP INT TERM

snapshot_fixed() {
  local source=$1 target=$2 size
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') ||
    emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
}
canonical_json() {
  local input=$1 canonical=$2
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$input" >"$canonical" 2>/dev/null || return 1
  /usr/bin/cmp -s "$input" "$canonical"
}
validator_pair_ok() {
  local pair_dir=$1 driver=$2 validator_jq=$3 expected_driver=$4 expected_program=$5
  local physical_dir
  [ -d "$pair_dir" ] && [ ! -L "$pair_dir" ] || return 1
  physical_dir=$(CDPATH='' cd -P -- "$pair_dir" 2>/dev/null && pwd -P) || return 1
  [ "$physical_dir" = "$pair_dir" ] &&
    [ "$driver" = "$pair_dir/validate.sh" ] &&
    [ "$validator_jq" = "$pair_dir/policy-set.jq" ] &&
    [ -f "$driver" ] && [ ! -L "$driver" ] &&
    [ -f "$validator_jq" ] && [ ! -L "$validator_jq" ] &&
    [ "$(sha256_path "$driver")" = "$expected_driver" ] &&
    [ "$(sha256_path "$validator_jq")" = "$expected_program" ]
}
build_validator_mirror() {
  local mirror="$scratch/policy-validator/control/v1" source target size
  /bin/mkdir -p "$mirror" || return 1
  for source in "$policy_validator" "$validator_program"; do
    target="$mirror/${source##*/}"
    /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null || return 1
    size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || return 1
    [ "$size" -le 1048576 ] || return 1
  done
  /bin/chmod 0500 "$mirror/validate.sh" || return 1
  /usr/bin/printf '%s\n' "$mirror"
}
core_closure_sha() {
  local root=$1 wrapper=$2 selected=$3 tag=$4 registry generation_root canonical
  local relative file digest members descriptor physical selected_sha count modules
  local -a paths
  registry="$root/core/v2/generation-registry.json"
  generation_root="$root/core/v2/generations/$selected"
  for required_dir in "$root" "$root/scripts" "$root/core" "$root/core/v2" \
    "$root/core/v2/generations" "$generation_root" "$generation_root/modules"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || return 1
    physical=$(CDPATH='' cd -P -- "$required_dir" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$required_dir" ] || return 1
  done
  [ "$wrapper" = "$root/scripts/core-contract.sh" ] || return 1
  [ "$(selected_core_generation "$wrapper")" = "$selected" ] || return 1
  count=$(/usr/bin/find "$generation_root" -mindepth 1 -maxdepth 1 -print 2>/dev/null |
    /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  modules=$(/usr/bin/find "$generation_root/modules" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  [ "$count" -eq 3 ] && [ "$modules" -eq 5 ] || return 1
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  canonical="$scratch/registry-$tag.json"
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$registry" >"$canonical" 2>/dev/null || return 1
  /usr/bin/cmp -s "$registry" "$canonical" || return 1
  "$jq_bin" -e --arg selected "$selected" '
    type=="array" and length>=1 and
    ([.[]|select(.generation_id==$selected and .semantic_identity=="core.contracts.v2")]
      |length)==1
  ' "$registry" >/dev/null 2>&1 || return 1
  paths=(
    scripts/core-contract.sh
    core/v2/generation-registry.json
    "core/v2/generations/$selected/contracts.jq"
    "core/v2/generations/$selected/core-ingress.sh"
    "core/v2/generations/$selected/modules/profile_graph.jq"
    "core/v2/generations/$selected/modules/result_facts.jq"
    "core/v2/generations/$selected/modules/result_truth.jq"
    "core/v2/generations/$selected/modules/schema.jq"
    "core/v2/generations/$selected/modules/stage_request.jq"
  )
  members="$scratch/core-members-$tag.tsv"
  : >"$members" || return 1
  for relative in "${paths[@]}"; do
    file="$root/$relative"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    digest=$(sha256_path "$file") || return 1
    /usr/bin/printf '%s\t%s\n' "$relative" "$digest" >>"$members" || return 1
  done
  selected_sha=$(sha256_text "$selected") || return 1
  descriptor=$("$jq_bin" -Rn -S -c --arg selected_sha "$selected_sha" '
    [inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
    {schema_version:1,kind:"core_contract_package_closure",
     semantic_identity:"core.contracts.v2",
     selected_generation_id_sha256:$selected_sha,members:$members}
  ' <"$members") || return 1
  sha256_text "$descriptor"
}
build_core_mirror() {
  local selected=$1 mirror="$scratch/core-package" relative source target size
  local -a paths
  /bin/mkdir -p "$mirror/scripts" "$mirror/core/v2/generations/$selected/modules" ||
    return 1
  paths=(
    scripts/core-contract.sh
    core/v2/generation-registry.json
    "core/v2/generations/$selected/contracts.jq"
    "core/v2/generations/$selected/core-ingress.sh"
    "core/v2/generations/$selected/modules/profile_graph.jq"
    "core/v2/generations/$selected/modules/result_facts.jq"
    "core/v2/generations/$selected/modules/result_truth.jq"
    "core/v2/generations/$selected/modules/schema.jq"
    "core/v2/generations/$selected/modules/stage_request.jq"
  )
  for relative in "${paths[@]}"; do
    source="$repo/$relative"
    target="$mirror/$relative"
    /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null || return 1
    size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || return 1
    [ "$size" -le 1048576 ] || return 1
  done
  /bin/chmod 0500 "$mirror/scripts/core-contract.sh" || return 1
  /usr/bin/printf '%s\n' "$mirror"
}
fixed_files_ok() {
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] &&
    [ "$(sha256_path "$program")" = "$program_sha" ] &&
    [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
    [ "$(sha256_path "$decision")" = "$decision_sha" ]
}

names=(policy-set request resolved result presentation)
index=0
for input in "$@"; do
  snapshot_fixed "$input" "$scratch/${names[$index]}.json"
  canonical_json "$scratch/${names[$index]}.json" \
    "$scratch/${names[$index]}.canonical" || emit_error E_RELATION
  index=$((index + 1))
done
"$jq_bin" -e '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="evidence_integrity_presentation" and
  (.id|type=="string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
  (.body|type=="object")
' "$scratch/presentation.json" >/dev/null 2>&1 || emit_error E_RELATION
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/program.jq"
canonical_json "$scratch/policy.json" "$scratch/policy.canonical" ||
  emit_error E_RELATION
canonical_json "$scratch/decision.json" "$scratch/decision.canonical" ||
  emit_error E_RELATION
for control_dir in "$repo/control" "$source_dir"; do
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || emit_error E_RELATION
done
[ "$source_dir" = "$repo/control/v1" ] || emit_error E_RELATION

driver_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME
policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
validator_driver_sha=$(sha256_path "$policy_validator") || emit_error E_RUNTIME
validator_program_sha=$(sha256_path "$validator_program") || emit_error E_RUNTIME
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg driver_sha "$driver_sha" \
  --arg program_sha "$program_sha" --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile definition "$scratch/decision.json" '
  $definition[0] == {
    schema_version:1,kind:"evidence_integrity_decision",
    id:"control-decision.evidence-integrity",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      evaluator:{
        driver_ref:{content_id:"control-evaluator-driver.evidence-integrity.v1",
          media_type:"text/x-shellscript",sha256:$driver_sha},
        policy_set_validator:{
          driver_ref:{content_id:"control-policy-set-validator-driver.v1",
            media_type:"text/x-shellscript",sha256:$validator_driver_sha},
          program_ref:{content_id:"control-policy-set-validator-program.v1",
            media_type:"text/x-jq",sha256:$validator_program_sha}},
        program_ref:{content_id:"control-evaluator-program.evidence-integrity.v1",
          media_type:"text/x-jq",sha256:$program_sha}},
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      semantics:{authority_effect:"none",candidate_execution:"none",
        credential_access:"none",
        input_contract:"control-policy-set+public-core-stage-run+evidence-integrity-presentation.v1",
        network_access:"none",output_kind:"evidence_integrity_evaluation",
        output_schema_version:1,qualification_effect:"none",
        reference_semantics:"identity-only",storage_effect:"none",
        verdicts:["satisfied","violated"]}}
  }
' >/dev/null 2>&1 || emit_error E_RELATION

validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
  "$validator_driver_sha" "$validator_program_sha" || emit_error E_RELATION
mirror_validator_dir=$(build_validator_mirror) || emit_error E_RELATION
mirror_policy_validator="$mirror_validator_dir/validate.sh"
mirror_validator_program="$mirror_validator_dir/policy-set.jq"
validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
  "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha" ||
  emit_error E_RELATION
policy_status=0
PATH="${jq_bin%/*}:/usr/bin:/bin" "$mirror_policy_validator" validate \
  "$scratch/policy-set.json" >"$scratch/policy.out" 2>"$scratch/policy.err" ||
  policy_status=$?
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
[ "$policy_status" -eq 0 ] || emit_error E_POLICY_SET

selected=$(selected_core_generation "$core_driver") || emit_error E_RELATION
selected_sha=$(sha256_text "$selected") || emit_error E_RUNTIME
live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-pre) ||
  emit_error E_RELATION
mirror_root=$(build_core_mirror "$selected") || emit_error E_RELATION
mirror_core_driver="$mirror_root/scripts/core-contract.sh"
mirror_core_sha=$(core_closure_sha "$mirror_root" "$mirror_core_driver" "$selected" mirror-pre) ||
  emit_error E_RELATION
[ "$mirror_core_sha" = "$live_core_sha" ] || emit_error E_RELATION
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg selected "$selected" --arg selected_sha "$selected_sha" \
  --arg core_sha "$live_core_sha" --slurpfile policy "$scratch/policy.json" '
  .body.core_contract == {
    semantic_identity:$policy[0].body.core_contract.semantic_identity,
    generation_id:$selected,package_ref:$policy[0].body.core_contract.package_ref} and
  $selected_sha == $policy[0].body.core_contract.generation_id_sha256 and
  $core_sha == $policy[0].body.core_contract.package_ref.sha256 and
  ([.body.sections[]|select(.section_id=="evidence-integrity")]|length)==1 and
  ([.body.sections[]|select(.section_id=="evidence-integrity")][0]) == {
    section_id:"evidence-integrity",
    policy_ref:{content_id:$policy[0].id,
      media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
    decision_ref:{content_id:"control-decision.evidence-integrity",
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha}}
' "$scratch/policy-set.json" >/dev/null 2>&1 || emit_error E_RELATION

core_status=0
PATH="${jq_bin%/*}:/usr/bin:/bin" "$mirror_core_driver" validate-stage-run \
  "$scratch/request.json" "$scratch/resolved.json" "$scratch/result.json" \
  >"$scratch/core.out" 2>"$scratch/core.err" || core_status=$?
post_live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-post) ||
  emit_error E_RELATION
post_mirror_core_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_core_driver" "$selected" mirror-post) || emit_error E_RELATION
[ "$post_live_core_sha" = "$live_core_sha" ] &&
  [ "$post_mirror_core_sha" = "$mirror_core_sha" ] || emit_error E_RELATION
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
[ "$core_status" -eq 0 ] || emit_error E_CORE

policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
presentation_sha=$(sha256_path "$scratch/presentation.json") || emit_error E_RUNTIME
"$jq_bin" -S -c -n -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile presentation "$scratch/presentation.json" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg presentation_sha "$presentation_sha" >"$scratch/evaluation.json" 2>/dev/null ||
  emit_error E_RUNTIME
fixed_files_ok || emit_error E_RELATION
final_live_core_sha=$(core_closure_sha "$repo" "$core_driver" "$selected" live-final) ||
  emit_error E_RELATION
final_mirror_core_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_core_driver" "$selected" mirror-final) || emit_error E_RELATION
[ "$final_live_core_sha" = "$live_core_sha" ] &&
  [ "$final_mirror_core_sha" = "$mirror_core_sha" ] || emit_error E_RELATION
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
canonical_json "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg presentation_sha "$presentation_sha" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" --slurpfile presentation "$scratch/presentation.json" '
  (keys|sort)==["body","id","kind","schema_version"] and .schema_version==1 and
  .kind=="evidence_integrity_evaluation" and .id==$result[0].id and
  (.body|keys|sort)==["activation_state","authority_effect","core_contract",
    "decision_ref","evaluation_mode","evidence_refs","policy_ref","policy_set",
    "presentation_ref","prior_evidence_refs","qualification_observation",
    "qualification_semantics","reason_ids","reference_semantics","stage",
    "storage_effect","verdict"] and
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.evaluation_mode=="observation-only" and .body.storage_effect=="none" and
  .body.reference_semantics=="identity-only" and
  .body.qualification_semantics=="identity-only-unqualified" and
  .body.core_contract==$policy_set[0].body.core_contract and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:"control-policy.evidence-integrity",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:"control-decision.evidence-integrity",
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.presentation_ref=={content_id:$presentation[0].id,
    media_type:"application/vnd.ystack.evidence-integrity-presentation+json",
    sha256:$presentation_sha} and
  .body.stage=={
    request_ref:{schema_version:$request[0].schema_version,kind:$request[0].kind,
      id:$request[0].id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:$resolved[0].schema_version,kind:$resolved[0].kind,
      id:$resolved[0].id,sha256:$resolved_sha},
    result_ref:{schema_version:$result[0].schema_version,kind:$result[0].kind,
      id:$result[0].id,sha256:$result_sha}} and
  .body.evidence_refs==($result[0].body.evidence|map({evidence_id,kind,proof_ref,verdict})) and
  .body.prior_evidence_refs==$request[0].body.prior_evidence_refs and
  .body.qualification_observation==
    (if $request[0].body|has("qualification_ref") then
       {state:"present",value:$request[0].body.qualification_ref}
     else {state:"absent"} end) and
  (.body.verdict=="satisfied" or .body.verdict=="violated") and
  (.body.reason_ids|type=="array" and length>=1 and .==(sort|unique)) and
  (if .body.verdict=="satisfied" then
     .body.reason_ids==["evidence.integrity-satisfied"]
   else (.body.reason_ids|index("evidence.integrity-satisfied")==null) end) and
  ((.body|has("grant_ref") or has("qualification_ref") or has("activation") or
    has("credential") or has("network") or has("candidate_execution"))|not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
