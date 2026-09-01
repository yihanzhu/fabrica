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
decision="$source_dir/duty-separation-decision.json"
program="$source_dir/duty-separation.jq"
policy_validator="$source_dir/validate.sh"
core_validator="$repo/scripts/core-contract.sh"
for required in "$source_path" "$policy" "$decision" "$program" \
  "$policy_validator" "$core_validator"; do
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
core_closure_sha() {
  local closure_root=$1 wrapper=$2 selected=$3 tag=$4
  local major registry_rel registry generation_rel generation_root physical_scripts wrapper_parent
  local canonical members descriptor relative digest required_dir required_file
  local root_count module_count major_count selected_sha
  local -a closure_paths
  major_count=$(/usr/bin/grep -Ec \
    '^[[:space:]]*PORTABLE_CORE_SCHEMA_MAJOR=' "$wrapper") || return 1
  [ "$major_count" -eq 1 ] || return 1
  major=$(/usr/bin/sed -n \
    "s/^PORTABLE_CORE_SCHEMA_MAJOR='\([12]\)'$/\1/p" "$wrapper") || return 1
  [ "$major" = 2 ] || return 1
  registry_rel="core/v$major/generation-registry.json"
  registry="$closure_root/$registry_rel"
  generation_rel="core/v$major/generations/$selected"
  generation_root="$closure_root/$generation_rel"
  for required_dir in "$closure_root" "$closure_root/scripts" "$closure_root/core" \
    "$closure_root/core/v$major" "$closure_root/core/v$major/generations" \
    "$generation_root" "$generation_root/modules"; do
    [ -d "$required_dir" ] && [ ! -L "$required_dir" ] || return 1
  done
  physical_scripts=$(CDPATH='' cd -P -- "$closure_root/scripts" 2>/dev/null && pwd -P) ||
    return 1
  wrapper_parent=$(CDPATH='' cd -P -- "${wrapper%/*}" 2>/dev/null && pwd -P) || return 1
  [ "$physical_scripts" = "$closure_root/scripts" ] &&
    [ "$wrapper_parent" = "$physical_scripts" ] &&
    [ "$wrapper" = "$closure_root/scripts/core-contract.sh" ] || return 1
  [ -f "$registry" ] && [ ! -L "$registry" ] || return 1
  root_count=$(/usr/bin/find "$generation_root" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  module_count=$(/usr/bin/find "$generation_root/modules" -mindepth 1 -maxdepth 1 \
    -print 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ') || return 1
  [ "$root_count" -eq 3 ] && [ "$module_count" -eq 5 ] || return 1
  canonical="$scratch/core-registry-$tag.canonical"
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$registry" >"$canonical" 2>/dev/null || return 1
  /usr/bin/cmp -s "$registry" "$canonical" || return 1
  "$jq_bin" -e --arg selected "$selected" '
    type=="array" and length>=1 and
    all(.[];type=="object" and
      (keys|sort)==["authorization_comment_id","concern","generation_id",
        "parent_generation_id","semantic_identity"] and
      (.authorization_comment_id|type)=="number" and
      (.concern|type)=="string" and
      (.generation_id|type=="string" and test("\\Ag-[0-9a-f]{64}\\z")) and
      (.parent_generation_id|type=="string" and test("\\Ag-[0-9a-f]{64}\\z")) and
      (.semantic_identity|type=="string" and test("\\Acore\\.contracts\\.v[1-9][0-9]*\\z"))) and
    (map(.generation_id)|length)==(map(.generation_id)|unique|length) and
    ([.[]|select(.generation_id==$selected and .semantic_identity=="core.contracts.v2")]|length)==1
  ' "$registry" >/dev/null 2>&1 || return 1
  closure_paths=(
    scripts/core-contract.sh
    "$registry_rel"
    "$generation_rel/contracts.jq"
    "$generation_rel/core-ingress.sh"
    "$generation_rel/modules/profile_graph.jq"
    "$generation_rel/modules/result_facts.jq"
    "$generation_rel/modules/result_truth.jq"
    "$generation_rel/modules/schema.jq"
    "$generation_rel/modules/stage_request.jq"
  )
  members="$scratch/core-members-$tag.tsv"
  : >"$members" || return 1
  for relative in "${closure_paths[@]}"; do
    required_file="$closure_root/$relative"
    [ -f "$required_file" ] && [ ! -L "$required_file" ] || return 1
    digest=$(sha256_path "$required_file") || return 1
    /usr/bin/printf '%s\t%s\n' "$relative" "$digest" >>"$members" || return 1
  done
  selected_sha=$(sha256_text "$selected") || return 1
  descriptor=$("$jq_bin" -Rn -S -c --arg selected_sha "$selected_sha" '
    [inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
    {schema_version:1,kind:"core_contract_package_closure",
     semantic_identity:"core.contracts.v2",
     selected_generation_id_sha256:$selected_sha,members:$members}
  ' <"$members") || return 1
  /usr/bin/printf '%s\n' "$descriptor" >"$scratch/core-closure-$tag.json" || return 1
  sha256_text "$descriptor"
}

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-duty.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) || emit_error E_RUNTIME
cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
signal_exit() { trap - EXIT HUP INT TERM; cleanup; exit 1; }
snapshot_fixed() {
  local source=$1 target=$2 fixed_size
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  fixed_size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') ||
    emit_error E_RUNTIME
  [ "$fixed_size" -le 1048576 ] || emit_error E_LIMIT
}
build_core_mirror() {
  local selected=$1 mirror="$scratch/core-package" relative source target mirror_size
  local -a mirror_paths
  /bin/mkdir -p "$mirror/scripts" \
    "$mirror/core/v2/generations/$selected/modules" || return 1
  mirror_paths=(
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
  for relative in "${mirror_paths[@]}"; do
    source="$repo/$relative"
    target="$mirror/$relative"
    /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null || return 1
    mirror_size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || return 1
    [ "$mirror_size" -le 1048576 ] || return 1
  done
  /bin/chmod 0500 "$mirror/scripts/core-contract.sh" || return 1
  /usr/bin/printf '%s\n' "$mirror"
}
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
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/program.jq"

PATH="${jq_bin%/*}:/usr/bin:/bin" "$policy_validator" validate \
  "$scratch/policy-set.json" >"$scratch/policy.out" 2>"$scratch/policy.err" ||
  emit_error E_POLICY_SET
for static_name in policy decision; do
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$scratch/$static_name.json" >"$scratch/$static_name.canonical" 2>/dev/null ||
    emit_error E_RELATION
  /usr/bin/cmp -s "$scratch/$static_name.json" "$scratch/$static_name.canonical" ||
    emit_error E_RELATION
done
policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME
policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
request_sha=$(sha256_path "$scratch/request.json") || emit_error E_RUNTIME
resolved_sha=$(sha256_path "$scratch/resolved.json") || emit_error E_RUNTIME
result_sha=$(sha256_path "$scratch/result.json") || emit_error E_RUNTIME
selected_generation=$(selected_core_generation "$core_validator") || emit_error E_RELATION
generation_id=$("$jq_bin" -er '.body.core_contract.generation_id' \
  "$scratch/policy-set.json" 2>/dev/null) || emit_error E_RELATION
[ "$generation_id" = "$selected_generation" ] || emit_error E_RELATION
generation_id_sha=$(sha256_text "$generation_id") || emit_error E_RUNTIME
live_core_package_sha=$(core_closure_sha \
  "$repo" "$core_validator" "$selected_generation" live-pre) || emit_error E_RELATION
mirror_root=$(build_core_mirror "$selected_generation") || emit_error E_RELATION
mirror_validator="$mirror_root/scripts/core-contract.sh"
mirror_generation=$(selected_core_generation "$mirror_validator") || emit_error E_RELATION
[ "$mirror_generation" = "$selected_generation" ] || emit_error E_RELATION
core_package_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_validator" "$mirror_generation" mirror) || emit_error E_RELATION
[ "$core_package_sha" = "$live_core_package_sha" ] || emit_error E_RELATION

"$jq_bin" -e --arg policy_sha "$policy_sha" \
  --arg decision_sha "$decision_sha" --arg program_sha "$program_sha" \
  --arg driver_sha "$driver_sha" \
  --arg generation_id_sha "$generation_id_sha" \
  --arg core_package_sha "$core_package_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" '
  .body.core_contract.semantic_identity == $policy[0].body.core_contract.semantic_identity and
  $generation_id_sha == $policy[0].body.core_contract.generation_id_sha256 and
  .body.core_contract.package_ref == $policy[0].body.core_contract.package_ref and
  $core_package_sha == $policy[0].body.core_contract.package_ref.sha256 and
  ([.body.sections[] | select(.section_id == "duty-separation")] | length) == 1 and
  ([.body.sections[] | select(.section_id == "duty-separation")][0]) as $section |
  ($section.policy_ref == {
    content_id:$policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",
    sha256:$policy_sha
  }) and
  ($section.decision_ref == {
    content_id:$decision[0].id,
    media_type:"application/vnd.ystack.control-decision+json",
    sha256:$decision_sha
  }) and
  ($decision[0] == {
    schema_version:1,kind:"duty_separation_decision",
    id:"control-decision.duty-separation",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      evaluator:{
        driver_ref:{content_id:"control-evaluator-driver.duty-separation.v1",
          media_type:"text/x-shellscript",sha256:$driver_sha},
        program_ref:{content_id:"control-evaluator-program.duty-separation.v1",
          media_type:"text/x-jq",sha256:$program_sha}},
      semantics:{authority_effect:"none",
        input_contract:"control-policy-set+public-core-stage-run.v1",
        output_kind:"duty_separation_evaluation",output_schema_version:1,
        reference_semantics:"identity-only",
        verdicts:["inconclusive","satisfied","violated"]}}
  })
' "$scratch/policy-set.json" >/dev/null 2>&1 || emit_error E_RELATION

core_status=0
run_status=0
PATH="${jq_bin%/*}:/usr/bin:/bin" "$mirror_validator" validate-document \
  "$scratch/resolved.json" >"$scratch/core.out" 2>"$scratch/core.err" || core_status=$?
if [ "$core_status" -eq 0 ]; then
  PATH="${jq_bin%/*}:/usr/bin:/bin" "$mirror_validator" validate-stage-run \
    "$scratch/request.json" "$scratch/resolved.json" "$scratch/result.json" \
    >"$scratch/run.out" 2>"$scratch/run.err" || run_status=$?
else
  run_status=1
fi
post_selected_generation=$(selected_core_generation "$core_validator") || emit_error E_RELATION
[ "$post_selected_generation" = "$selected_generation" ] || emit_error E_RELATION
post_core_package_sha=$(core_closure_sha \
  "$repo" "$core_validator" "$post_selected_generation" live-post) || emit_error E_RELATION
post_mirror_generation=$(selected_core_generation "$mirror_validator") || emit_error E_RELATION
[ "$post_mirror_generation" = "$mirror_generation" ] || emit_error E_RELATION
post_mirror_package_sha=$(core_closure_sha \
  "$mirror_root" "$mirror_validator" "$post_mirror_generation" mirror-post) ||
  emit_error E_RELATION
[ "$post_core_package_sha" = "$live_core_package_sha" ] &&
  [ "$post_mirror_package_sha" = "$core_package_sha" ] || emit_error E_RELATION
[ "$core_status" -eq 0 ] && [ "$run_status" -eq 0 ] || emit_error E_CORE
[ "$(sha256_path "$policy")" = "$policy_sha" ] &&
  [ "$(sha256_path "$decision")" = "$decision_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] || emit_error E_RELATION

"$jq_bin" -S -c -n -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" \
  --slurpfile result "$scratch/result.json" \
  --arg policy_set_sha "$policy_set_sha" --arg decision_sha "$decision_sha" \
  --arg resolved_sha "$resolved_sha" --arg request_sha "$request_sha" \
  --arg result_sha "$result_sha" >"$scratch/evaluation.json" || emit_error E_RUNTIME
[ "$(sha256_path "$policy")" = "$policy_sha" ] &&
  [ "$(sha256_path "$decision")" = "$decision_sha" ] &&
  [ "$(sha256_path "$program")" = "$program_sha" ] &&
  [ "$(sha256_path "$source_path")" = "$driver_sha" ] || emit_error E_RELATION
"$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
  "$scratch/evaluation.json" >"$scratch/evaluation.canonical" 2>/dev/null ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --slurpfile policy "$scratch/policy.json" --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" --slurpfile request "$scratch/request.json" \
  --slurpfile resolved "$scratch/resolved.json" --slurpfile result "$scratch/result.json" '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="duty_separation_evaluation" and .id==$result[0].id and
  (.body|keys|sort)==["activation_state","core_contract","decision_ref",
    "evaluation_mode","policy_ref","policy_set","reason_ids",
    "reference_semantics","stage","verdict"] and
  .body.activation_state=="inactive" and .body.evaluation_mode=="observation-only" and
  .body.reference_semantics=="identity-only" and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:$policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:$decision[0].id,
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.core_contract==$policy_set[0].body.core_contract and
  .body.stage=={
    request_ref:{schema_version:$request[0].schema_version,kind:$request[0].kind,
      id:$request[0].id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:$resolved[0].schema_version,kind:$resolved[0].kind,
      id:$resolved[0].id,sha256:$resolved_sha},
    result_ref:{schema_version:$result[0].schema_version,kind:$result[0].kind,
      id:$result[0].id,sha256:$result_sha}} and
  (.body.verdict as $verdict | $decision[0].body.semantics.verdicts|index($verdict)!=null) and
  (.body.reason_ids|type=="array" and length>=1 and all(.[];type=="string") and
    .==(sort|unique)) and
  (if .body.verdict=="satisfied" then .body.reason_ids==["duty.satisfied"]
   elif .body.verdict=="inconclusive" then
     .body.reason_ids==["actual.capability-unclassified"]
   else (.body.reason_ids|index("duty.satisfied")==null and
     index("actual.capability-unclassified")==null) end)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME
/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
