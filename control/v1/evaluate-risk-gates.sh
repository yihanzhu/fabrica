#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_RELATION|E_DUTY)
      /usr/bin/printf '%s\n' "$1" >&2
      ;;
    *) /usr/bin/printf '%s\n' E_RUNTIME >&2 ;;
  esac
  exit 1
}

[ "$#" -eq 7 ] && [ "$1" = evaluate ] || emit_error E_USAGE
shift
source_path=${BASH_SOURCE[0]}
case "$source_path" in /*) ;; *) source_path="$(pwd -P)/$source_path" ;; esac
source_dir=$(CDPATH='' cd -P -- "${source_path%/*}" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
source_path="$source_dir/${source_path##*/}"
[ "$source_path" = "$source_dir/evaluate-risk-gates.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/risk-gates-policy.json"
decision="$source_dir/risk-gates-decision.json"
program="$source_dir/risk-gates.jq"
duty_policy="$source_dir/duty-separation-policy.json"
duty_decision="$source_dir/duty-separation-decision.json"
duty_program="$source_dir/duty-separation.jq"
duty_driver="$source_dir/evaluate-duty.sh"
policy_validator="$source_dir/validate.sh"
validator_program="$source_dir/policy-set.jq"
core_driver="$repo/scripts/core-contract.sh"
for required in "$source_path" "$policy" "$decision" "$program" "$duty_policy" \
  "$duty_decision" "$duty_program" "$duty_driver" "$policy_validator" \
  "$validator_program" "$core_driver"; do
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

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-risk.XXXXXX" 2>/dev/null) ||
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
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
}
canonical_json() {
  local input=$1 canonical=$2
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$input" >"$canonical" 2>/dev/null || return 1
  /usr/bin/cmp -s "$input" "$canonical"
}
runtime_paths() {
  local selected=$1
  /usr/bin/printf '%s\n' \
    control/v1/duty-separation-policy.json \
    control/v1/duty-separation-decision.json \
    control/v1/duty-separation.jq \
    control/v1/evaluate-duty.sh \
    control/v1/policy-set.jq \
    control/v1/validate.sh \
    scripts/core-contract.sh \
    core/v2/generation-registry.json \
    "core/v2/generations/$selected/contracts.jq" \
    "core/v2/generations/$selected/core-ingress.sh" \
    "core/v2/generations/$selected/modules/profile_graph.jq" \
    "core/v2/generations/$selected/modules/result_facts.jq" \
    "core/v2/generations/$selected/modules/result_truth.jq" \
    "core/v2/generations/$selected/modules/schema.jq" \
    "core/v2/generations/$selected/modules/stage_request.jq"
}
runtime_closure_sha() {
  local root=$1 selected=$2 tag=$3 relative file digest descriptor members
  local required_dir physical selected_at_root
  for required_dir in "$root" "$root/control" "$root/control/v1" "$root/scripts" \
    "$root/core" "$root/core/v2" "$root/core/v2/generations" \
    "$root/core/v2/generations/$selected" \
    "$root/core/v2/generations/$selected/modules"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || return 1
    physical=$(CDPATH='' cd -P -- "$required_dir" 2>/dev/null && pwd -P) || return 1
    [ "$physical" = "$required_dir" ] || return 1
  done
  selected_at_root=$(selected_core_generation "$root/scripts/core-contract.sh") ||
    return 1
  [ "$selected_at_root" = "$selected" ] || return 1
  members="$scratch/runtime-$tag.tsv"
  : >"$members" || return 1
  while IFS= read -r relative; do
    file="$root/$relative"
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    digest=$(sha256_path "$file") || return 1
    /usr/bin/printf '%s\t%s\n' "$relative" "$digest" >>"$members" || return 1
  done < <(runtime_paths "$selected")
  descriptor=$("$jq_bin" -Rn -S -c \
    --arg generation_sha "$(sha256_text "$selected")" '
      [inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
      {schema_version:1,kind:"duty_separation_runtime_closure",
       selected_generation_id_sha256:$generation_sha,members:$members}
    ' <"$members") || return 1
  sha256_text "$descriptor"
}
build_runtime_mirror() {
  local selected=$1 mirror="$scratch/runtime" relative source target size
  /bin/mkdir -p "$mirror/control/v1" "$mirror/scripts" \
    "$mirror/core/v2/generations/$selected/modules" || return 1
  while IFS= read -r relative; do
    source="$repo/$relative"
    target="$mirror/$relative"
    /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null || return 1
    size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || return 1
    [ "$size" -le 1048576 ] || return 1
  done < <(runtime_paths "$selected")
  /bin/chmod 0500 "$mirror/control/v1/evaluate-duty.sh" \
    "$mirror/control/v1/validate.sh" "$mirror/scripts/core-contract.sh" || return 1
  /usr/bin/printf '%s\n' "$mirror"
}
fixed_files_ok() {
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] &&
    [ "$(sha256_path "$program")" = "$program_sha" ] &&
    [ "$(sha256_path "$policy")" = "$policy_sha" ] &&
    [ "$(sha256_path "$decision")" = "$decision_sha" ]
}

names=(policy-set request resolved result duty-evaluation claim)
index=0
for input in "$@"; do
  snapshot_fixed "$input" "$scratch/${names[$index]}.json"
  canonical_json "$scratch/${names[$index]}.json" \
    "$scratch/${names[$index]}.canonical" || emit_error E_RELATION
  index=$((index + 1))
done
"$jq_bin" -e '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="risk_gate_decision_claim" and
  (.id|type=="string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z")) and
  (.body|type=="object")
' "$scratch/claim.json" >/dev/null 2>&1 || emit_error E_RELATION
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
duty_policy_sha=$(sha256_path "$duty_policy") || emit_error E_RUNTIME
duty_decision_sha=$(sha256_path "$duty_decision") || emit_error E_RUNTIME
duty_driver_sha=$(sha256_path "$duty_driver") || emit_error E_RUNTIME
duty_program_sha=$(sha256_path "$duty_program") || emit_error E_RUNTIME
validator_driver_sha=$(sha256_path "$policy_validator") || emit_error E_RUNTIME
validator_program_sha=$(sha256_path "$validator_program") || emit_error E_RUNTIME

"$jq_bin" -n -e --arg policy_sha "$policy_sha" --arg driver_sha "$driver_sha" \
  --arg program_sha "$program_sha" --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile definition "$scratch/decision.json" '
  $definition[0] == {
    schema_version:1,kind:"risk_gates_decision",
    id:"control-decision.risk-gates",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      dependencies:{duty_separation:{
        policy_ref:{content_id:"control-policy.duty-separation",
          media_type:"application/vnd.ystack.control-policy+json",sha256:$duty_policy_sha},
        decision_ref:{content_id:"control-decision.duty-separation",
          media_type:"application/vnd.ystack.control-decision+json",sha256:$duty_decision_sha}}},
      evaluator:{
        driver_ref:{content_id:"control-evaluator-driver.risk-gates.v1",
          media_type:"text/x-shellscript",sha256:$driver_sha},
        program_ref:{content_id:"control-evaluator-program.risk-gates.v1",
          media_type:"text/x-jq",sha256:$program_sha}},
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      semantics:{authority_effect:"none",
        decision_claim_semantics:"immutable-input-claim-only",
        decision_provenance:"unqualified-input-claim",
        input_contract:"control-policy-set+public-core-stage-run+duty-evaluation+risk-decision-claim.v1",
        output_kind:"risk_gate_evaluation",output_schema_version:1,
        reference_semantics:"identity-only",
        verdicts:["inconclusive","violated"]}}
  }
' >/dev/null 2>&1 || emit_error E_RELATION

"$jq_bin" -e --arg duty_driver_sha "$duty_driver_sha" \
  --arg duty_program_sha "$duty_program_sha" \
  --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" '
  .body.evaluator == {
    driver_ref:{content_id:"control-evaluator-driver.duty-separation.v1",
      media_type:"text/x-shellscript",sha256:$duty_driver_sha},
    policy_set_validator:{
      driver_ref:{content_id:"control-policy-set-validator-driver.v1",
        media_type:"text/x-shellscript",sha256:$validator_driver_sha},
      program_ref:{content_id:"control-policy-set-validator-program.v1",
        media_type:"text/x-jq",sha256:$validator_program_sha}},
    program_ref:{content_id:"control-evaluator-program.duty-separation.v1",
      media_type:"text/x-jq",sha256:$duty_program_sha}}
' "$duty_decision" >/dev/null 2>&1 || emit_error E_RELATION

selected=$(selected_core_generation "$core_driver") || emit_error E_RELATION
live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-pre) ||
  emit_error E_RELATION
mirror_root=$(build_runtime_mirror "$selected") || emit_error E_RELATION
mirror_runtime_sha=$(runtime_closure_sha "$mirror_root" "$selected" mirror-pre) ||
  emit_error E_RELATION
[ "$live_runtime_sha" = "$mirror_runtime_sha" ] || emit_error E_RELATION

: >"$scratch/duty-ready"
duty_status=0
PATH="${jq_bin%/*}:/usr/bin:/bin" "$mirror_root/control/v1/evaluate-duty.sh" evaluate \
  "$scratch/policy-set.json" "$scratch/request.json" "$scratch/resolved.json" \
  "$scratch/result.json" >"$scratch/generated-duty.json" \
  2>"$scratch/generated-duty.err" || duty_status=$?
: >"$scratch/duty-complete"
post_live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-post-duty) ||
  emit_error E_RELATION
post_mirror_runtime_sha=$(runtime_closure_sha \
  "$mirror_root" "$selected" mirror-post-duty) || emit_error E_RELATION
[ "$post_live_runtime_sha" = "$live_runtime_sha" ] &&
  [ "$post_mirror_runtime_sha" = "$mirror_runtime_sha" ] || emit_error E_RELATION
[ "$duty_status" -eq 0 ] || emit_error E_DUTY
/usr/bin/cmp -s "$scratch/generated-duty.json" "$scratch/duty-evaluation.json" ||
  emit_error E_DUTY

policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty-evaluation.json") || emit_error E_RUNTIME
claim_sha=$(sha256_path "$scratch/claim.json") || emit_error E_RUNTIME
request_basis=$("$jq_bin" -S -c \
  '{schema_version,kind,id,body:(.body|del(.gate_decision_refs))}' \
  "$scratch/request.json") || emit_error E_RELATION
request_basis_sha=$(sha256_text "$request_basis") || emit_error E_RUNTIME
policy_scope_descriptor=$("$jq_bin" -S -c -n --arg policy_sha "$policy_sha" \
  --slurpfile request "$scratch/request.json" '
  {schema_version:1,kind:"risk_policy_scope",
   policy_ref:{content_id:"control-policy.risk-gates",
     media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
   subject_ref:{type:"artifact",value:$request[0].body.source.value}}
') || emit_error E_RELATION
policy_scope_sha=$(sha256_text "$policy_scope_descriptor") || emit_error E_RUNTIME
declared_tier=$("$jq_bin" -er '.body.risk.tier.name' "$scratch/request.json") ||
  emit_error E_RELATION
requirement_descriptor=$("$jq_bin" -S -c -n --arg policy_sha "$policy_sha" \
  --arg tier "$declared_tier" --slurpfile request "$scratch/request.json" '
  {schema_version:1,kind:"risk_gate_requirement",declared_tier:$tier,
   policy_ref:{content_id:"control-policy.risk-gates",
     media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
   subject_ref:{type:"artifact",value:$request[0].body.source.value}}
') || emit_error E_RELATION
requirement_scope_sha=$(sha256_text "$requirement_descriptor") || emit_error E_RUNTIME

: >"$scratch/risk-ready"
"$jq_bin" -S -c -n -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile duty_evaluation "$scratch/duty-evaluation.json" \
  --slurpfile claim "$scratch/claim.json" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg duty_sha "$duty_sha" --arg claim_sha "$claim_sha" \
  --arg request_basis_sha "$request_basis_sha" \
  --arg policy_scope_sha "$policy_scope_sha" \
  --arg requirement_scope_sha "$requirement_scope_sha" \
  >"$scratch/evaluation.json" 2>/dev/null || emit_error E_RUNTIME
: >"$scratch/risk-complete"
fixed_files_ok || emit_error E_RELATION
final_live_runtime_sha=$(runtime_closure_sha "$repo" "$selected" live-post-risk) ||
  emit_error E_RELATION
final_mirror_runtime_sha=$(runtime_closure_sha \
  "$mirror_root" "$selected" mirror-post-risk) || emit_error E_RELATION
[ "$final_live_runtime_sha" = "$live_runtime_sha" ] &&
  [ "$final_mirror_runtime_sha" = "$mirror_runtime_sha" ] || emit_error E_RELATION
canonical_json "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME

"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg duty_sha "$duty_sha" --arg claim_sha "$claim_sha" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile claim "$scratch/claim.json" \
  --slurpfile duty "$scratch/duty-evaluation.json" '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="risk_gate_evaluation" and .id==$result[0].id and
  (.body|keys|sort)==["activation_state","authority_effect","classification",
    "core_contract","decision_claim_ref","decision_ref","duty_evaluation_ref",
    "evaluation_mode","policy_ref","policy_set","reason_ids",
    "reference_semantics","stage","verdict"] and
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.evaluation_mode=="observation-only" and
  .body.reference_semantics=="identity-only" and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:"control-policy.risk-gates",
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:"control-decision.risk-gates",
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.decision_claim_ref=={content_id:$claim[0].id,
    media_type:"application/vnd.ystack.risk-gate-decision-claim+json",sha256:$claim_sha} and
  .body.duty_evaluation_ref=={content_id:$duty[0].id,
    media_type:"application/vnd.ystack.duty-separation-evaluation+json",sha256:$duty_sha} and
  .body.core_contract==$policy_set[0].body.core_contract and
  .body.stage=={
    request_ref:{schema_version:$request[0].schema_version,kind:$request[0].kind,
      id:$request[0].id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:$resolved[0].schema_version,
      kind:$resolved[0].kind,id:$resolved[0].id,sha256:$resolved_sha},
    result_ref:{schema_version:$result[0].schema_version,kind:$result[0].kind,
      id:$result[0].id,sha256:$result_sha}} and
  (.body.classification|keys|sort)==["declared_tier","minimum_tier"] and
  (.body.classification.minimum_tier as $minimum |
    (["routine","high","bootstrap"]|index($minimum)!=null) or
    ($minimum=="unknown" and .body.verdict=="violated")) and
  (.body.verdict=="violated" or .body.verdict=="inconclusive") and
  (.body.reason_ids|type=="array" and length>=1 and all(.[];type=="string") and
    .==(sort|unique)) and
  (.body.reason_ids|index("risk-gates.satisfied")==null) and
  ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME

/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
