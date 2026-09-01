#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-duty.sh"
policy="$root/control/v1/duty-separation-policy.json"
decision="$root/control/v1/duty-separation-decision.json"
core_wrapper="$root/scripts/core-contract.sh"
core_registry="$root/core/v2/generation-registry.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-duty-test.XXXXXX")
trap '/bin/rm -rf -- "$tmp"' EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$($jq_bin --version)" = jq-1.6 ] || fail 'jq identity'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core_wrapper") ||
  fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
"$jq_bin" -e --arg generation "$generation" \
  '[.[]|select(.generation_id==$generation and .semantic_identity=="core.contracts.v2")]|length==1' \
  "$core_registry" >/dev/null || fail 'selected registry entry'
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")

canonical="$tmp/policy-canonical.json"
"$jq_bin" -S -c . "$policy" >"$canonical"
/usr/bin/cmp -s "$policy" "$canonical" || fail 'canonical shipped policy'
policy_sha=$(sha256_path "$policy")
"$jq_bin" -S -c . "$decision" >"$tmp/decision-canonical.json"
/usr/bin/cmp -s "$decision" "$tmp/decision-canonical.json" || fail 'canonical decision'
decision_sha=$(sha256_path "$decision")
validator_driver_sha=$(sha256_path "$root/control/v1/validate.sh")
validator_program_sha=$(sha256_path "$root/control/v1/policy-set.jq")
"$jq_bin" -e --arg driver_sha "$validator_driver_sha" \
  --arg program_sha "$validator_program_sha" '
  .body.evaluator.policy_set_validator=={
    driver_ref:{content_id:"control-policy-set-validator-driver.v1",
      media_type:"text/x-shellscript",sha256:$driver_sha},
    program_ref:{content_id:"control-policy-set-validator-program.v1",
      media_type:"text/x-jq",sha256:$program_sha}}
' "$decision" >/dev/null || fail 'decision validator identities'

closure_members="$tmp/core-closure-members.tsv"
closure_paths=(
  scripts/core-contract.sh core/v2/generation-registry.json
  "core/v2/generations/$generation/contracts.jq"
  "core/v2/generations/$generation/core-ingress.sh"
  "core/v2/generations/$generation/modules/profile_graph.jq"
  "core/v2/generations/$generation/modules/result_facts.jq"
  "core/v2/generations/$generation/modules/result_truth.jq"
  "core/v2/generations/$generation/modules/schema.jq"
  "core/v2/generations/$generation/modules/stage_request.jq"
)
: >"$closure_members"
for closure_path in "${closure_paths[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$closure_path" "$(sha256_path "$root/$closure_path")" \
    >>"$closure_members"
done
generation_sha=$(sha256_text "$generation")
closure_descriptor=$("$jq_bin" -Rn -S -c --arg generation_sha "$generation_sha" '
  [inputs|split("\t")|{path:.[0],sha256:.[1]}] as $members |
  {schema_version:1,kind:"core_contract_package_closure",
   semantic_identity:"core.contracts.v2",selected_generation_id_sha256:$generation_sha,
   members:$members}
' <"$closure_members")
[ "$(sha256_text "$closure_descriptor")" = "$core_package_sha" ] || fail 'core closure identity'
[ "$generation_sha" = "$("$jq_bin" -r '.body.core_contract.generation_id_sha256' "$policy")" ] ||
  fail 'generation identity'
generation_newline_sha=$(/usr/bin/printf '%s\n' "$generation" |
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
[ "$generation_newline_sha" != "$generation_sha" ] || fail 'generation newline distinction'
for source_path in control/v1/duty-separation-policy.json \
  control/v1/duty-separation-decision.json control/v1/duty-separation.jq \
  control/v1/evaluate-duty.sh scripts/test/control-duty-separation.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" || fail "raw generation $source_path"
done
pass 'opaque generation and full package closure identities'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg duty_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg generation "$generation" --arg core_package_sha "$core_package_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy_sha;$decision_sha):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;
       "application/vnd.ystack.control-policy+json";$policy_sha),
     decision_ref:ref("control-decision."+$id;
       "application/vnd.ystack.control-decision+json";$decision_sha)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.example",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
     core_contract:{semantic_identity:"core.contracts.v2",
       generation_id:$generation,
       package_ref:ref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";$core_package_sha)},
     sections:[section("credential-policy";("1"*64);("a"*64)),
       section("duty-separation";$duty_sha;$decision_sha),
       section("evidence-integrity";("3"*64);("c"*64)),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";("5"*64);("e"*64)),
       section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set"
policy_set_sha=$(sha256_path "$policy_set")

resolved="$tmp/resolved.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  def forge_binding($sha):
    {binding_id:"binding.forge",role:"forge",
     manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$sha},
     execution_kind:"deterministic",adapter_instance_id:"instance.forge",
     principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
     authority_ref:profile::scope("authority";"authority-forge";profile::sha("5")),
     package_ref:profile::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
     requested_capabilities:["core.forge.materialize-candidate.v2"],
     requested_permissions:["core.perm.candidate-repository.write.v2",
       "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
       "core.perm.target.read.v1"]};
  {forge:("1"*64),producer:("2"*64),publisher:("3"*64),
   reviewer:("4"*64),verifier:("5"*64)} as $shas |
  (profile::profile_doc($shas) | v2 | .body.profile_version="v2" |
   .body.bindings += [forge_binding($shas.forge)] |
   .body.bindings |= sort_by(.binding_id)) as $profile |
  profile::resolved_profile_doc($profile;("0"*64);$shas) | v2 |
  .body.bindings |= map(if .binding.role == "forge" then
    .adapter_implementation.version="v2" |
    .manifest_source=profile::source_value(
      profile::blob("manifests/forge.json";"a");"canonical-json";$shas.forge)
    else . end)
' >"$resolved"
resolved_sha=$(sha256_path "$resolved")

request="$tmp/request.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("producer";$sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$request"
request_sha=$(sha256_path "$request")
result="$tmp/result.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$request" --slurpfile resolved "$resolved" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc(
    $request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$result"

expect_eval() {
  local name=$1 expected=$2 reason=$3 set=$4 req=$5 resolved_input=$6 result_input=$7
  local out="$tmp/$name.out" err="$tmp/$name.err" repeat="$tmp/$name.repeat"
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
    "$set" "$req" "$resolved_input" "$result_input" >"$out" 2>"$err" || {
      /bin/cat "$err" >&2
      fail "$name status"
    }
  [ ! -s "$err" ] || fail "$name stderr"
  "$jq_bin" -e --arg verdict "$expected" --arg reason "$reason" '
    .kind == "duty_separation_evaluation" and
    .body.activation_state == "inactive" and
    .body.evaluation_mode == "observation-only" and
    .body.reference_semantics == "identity-only" and
    .body.verdict == $verdict and (.body.reason_ids | index($reason) != null) and
    .body.reason_ids == (.body.reason_ids | sort | unique)
  ' "$out" >/dev/null || fail "$name verdict"
  "$jq_bin" -S -c . "$out" >"$repeat"
  /usr/bin/cmp -s "$out" "$repeat" || fail "$name canonical"
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2 set=$3 req=$4 resolved_input=$5 result_input=$6
  local out="$tmp/$name.out" err="$tmp/$name.err" status=0
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
    "$set" "$req" "$resolved_input" "$result_input" >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] &&
    [ "$(/bin/cat "$err")" = "$expected" ] || fail "$name"
  pass "$name"
}
expect_pure() {
  local name=$1 expected=$2 reason=$3 req=$4 resolved_input=$5 result_input=$6
  local out="$tmp/pure-$name.out" req_sha resolved_input_sha result_input_sha
  req_sha=$(sha256_path "$req")
  resolved_input_sha=$(sha256_path "$resolved_input")
  result_input_sha=$(sha256_path "$result_input")
  "$jq_bin" -S -c -n -f "$root/control/v1/duty-separation.jq" \
    --slurpfile policy "$policy" --slurpfile decision "$decision" \
    --slurpfile policy_set "$policy_set" \
    --slurpfile request "$req" --slurpfile resolved "$resolved_input" \
    --slurpfile result "$result_input" --arg policy_set_sha "$policy_set_sha" \
    --arg decision_sha "$decision_sha" \
    --arg request_sha "$req_sha" --arg resolved_sha "$resolved_input_sha" \
    --arg result_sha "$result_input_sha" >"$out" || fail "pure $name status"
  "$jq_bin" -e --arg expected "$expected" --arg reason "$reason" '
    .body.verdict==$expected and (.body.reason_ids | index($reason) != null) and
    .body.reason_ids == (.body.reason_ids | sort | unique)
  ' "$out" >/dev/null || fail "pure $name verdict"
  pass "pure $name"
}
sync_result() {
  local changed_request=$1 output=$2 digest
  digest=$(sha256_path "$changed_request")
  "$jq_bin" -S -c --arg digest "$digest" '.body.request_ref.sha256=$digest' \
    "$result" >"$output"
}
copy_runtime() {
  local destination=$1 copy_path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for copy_path in evaluate-duty.sh duty-separation.jq duty-separation-policy.json \
    duty-separation-decision.json validate.sh policy-set.jq; do
    /bin/cp "$root/control/v1/$copy_path" "$destination/control/v1/$copy_path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}

expect_eval satisfied satisfied duty.satisfied "$policy_set" "$request" "$resolved" "$result"
result_sha=$(sha256_path "$result")
"$jq_bin" -e --arg policy_set_sha "$policy_set_sha" --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" '
  .body.policy_set.sha256==$policy_set_sha and
  .body.policy_ref.sha256==$policy_sha and .body.decision_ref=={
    content_id:"control-decision.duty-separation",
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.stage.request_ref.sha256==$request_sha and
  .body.stage.resolved_profile_ref.sha256==$resolved_sha and
  .body.stage.result_ref.sha256==$result_sha
' "$tmp/satisfied.out" >/dev/null || fail 'output input identities'
pass 'output input identities'
repeat_out="$tmp/repeat.out"
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" >"$repeat_out"
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" | /usr/bin/cmp -s - "$repeat_out" ||
  fail 'repeat determinism'
pass 'repeat determinism'

skipped="$tmp/skipped.json"
"$jq_bin" -S -c '.body.status="skipped" | .body.reason={reason_id:"stage.skipped"} |
  .body.outputs=[] | .body.diagnostics=[] | .body.evidence=[] |
  del(.body.outcome,.body.execution,.body.started_at,.body.finished_at)' "$result" >"$skipped"
expect_eval skipped-satisfied satisfied duty.satisfied \
  "$policy_set" "$request" "$resolved" "$skipped"

observer_request="$tmp/observer-request.json"
observer_result="$tmp/observer-result.json"
"$jq_bin" -S -c '.body.requested_by.role="observer"' "$request" >"$observer_request"
sync_result "$observer_request" "$observer_result"
expect_eval requester-role violated requester.role-denied \
  "$policy_set" "$observer_request" "$resolved" "$observer_result"

unclassified="$tmp/unclassified.json"
"$jq_bin" -S -c '
  .body.status="failed" | .body.outcome={family:"change",value:"inconclusive"} |
  .body.reason={reason_id:"stage.failed"} | .body.outputs=[] |
  .body.diagnostics=[{content_id:"diagnostic.failed",media_type:"text/plain",sha256:("d"*64)}] |
  .body.evidence |= map(.verdict="failed") |
  .body.execution.used_capability={kind:"unclassified",id:"capability.unknown"}
' "$result" >"$unclassified"
expect_eval unclassified inconclusive actual.capability-unclassified \
  "$policy_set" "$request" "$resolved" "$unclassified"

kind_incident="$tmp/kind-incident.json"
"$jq_bin" -S -c '
  .body.status="failed" | .body.outcome={family:"change",value:"inconclusive"} |
  .body.reason={reason_id:"stage.failed"} | .body.outputs=[] |
  .body.diagnostics=[{content_id:"diagnostic.failed",media_type:"text/plain",sha256:("d"*64)}] |
  .body.evidence |= map(.verdict="failed") |
  .body.execution.actual_binding.execution_kind="deterministic" |
  .body.execution.metadata.kind="deterministic" |
  .body.execution.metadata |= (.provider={state:"not-applicable"} |
    .model={state:"not-applicable"} | .snapshot={state:"not-applicable"} |
    .effort={state:"not-applicable"} | .prompt={state:"not-applicable"} |
    .skills={state:"not-applicable"})
' "$result" >"$kind_incident"
expect_eval actual-kind violated actual.execution-kind-mismatch \
  "$policy_set" "$request" "$resolved" "$kind_incident"

deterministic_resolved="$tmp/deterministic-resolved.json"
deterministic_request="$tmp/deterministic-request.json"
deterministic_result="$tmp/deterministic-result.json"
"$jq_bin" -S -c '
  (.body.bindings[] | select(.binding.role=="producer" or .binding.role=="reviewer") |
   .binding.execution_kind)="deterministic" |
  (.body.bindings[] | select(.binding.role=="producer") |
   .binding.requested_permissions)=["core.perm.evidence.write.v1",
     "core.perm.scratch.write.v1","core.perm.target.read.v1"] |
  (.body.bindings[] | select(.binding.role=="reviewer") |
   .binding.requested_permissions)=["core.perm.evidence.write.v1","core.perm.target.read.v1"]
' "$resolved" >"$deterministic_resolved"
"$jq_bin" -S -c '.body.operation.permissions=["core.perm.evidence.write.v1",
  "core.perm.scratch.write.v1","core.perm.target.read.v1"]' \
  "$request" >"$deterministic_request"
"$jq_bin" -S -c '.body.execution.actual_binding.execution_kind="deterministic"' \
  "$result" >"$deterministic_result"
expect_pure deterministic-ceilings satisfied duty.satisfied \
  "$deterministic_request" "$deterministic_resolved" "$deterministic_result"

for dimension in adapter_instance_id execution_boundary_id principal_id; do
  requester_case="$tmp/requester-$dimension.json"
  "$jq_bin" -S -c --arg dimension "$dimension" --slurpfile resolved "$resolved" '
    .body.requested_by[$dimension]=([$resolved[0].body.bindings[] |
      select(.binding.role=="producer") | .binding[$dimension]][0])
  ' "$request" >"$requester_case"
  requester_result="$tmp/requester-$dimension-result.json"
  sync_result "$requester_case" "$requester_result"
  expect_eval "requester-$dimension" violated "requester.$dimension-collision" \
    "$policy_set" "$requester_case" "$resolved" "$requester_result"
done
publisher_case="$tmp/publisher-active.json"
"$jq_bin" -S -c '(.body.bindings[] | select(.binding.role=="publisher") |
  .binding.requested_permissions)=["core.perm.evidence.write.v1"]' \
  "$resolved" >"$publisher_case"
expect_pure publisher-not-dormant violated publisher.not-dormant \
  "$request" "$publisher_case" "$result"
precedence_case="$tmp/precedence.json"
"$jq_bin" -S -c '.body.reported_by.role="reviewer"' "$unclassified" >"$precedence_case"
expect_eval violation-precedence violated reporter.role-mismatch \
  "$policy_set" "$request" "$resolved" "$precedence_case"

incident="$tmp/incident.json"
"$jq_bin" -S -c '
  .body.status="failed" | .body.outcome={family:"change",value:"inconclusive"} |
  .body.reason={reason_id:"stage.failed"} | .body.outputs=[] |
  .body.diagnostics=[{content_id:"diagnostic.failed",media_type:"text/plain",sha256:("d"*64)}] |
  .body.evidence |= map(.verdict="failed")
' "$result" >"$incident"
for hop in actual_binding performer; do
  hop_case="$tmp/incident-$hop.json"
  "$jq_bin" -S -c --arg hop "$hop" \
    '.body.execution[$hop].principal_id="different.principal"' \
    "$incident" >"$hop_case"
  reason_hop=${hop%_binding}
  expect_eval "incident-$reason_hop" violated "$reason_hop.principal_id-mismatch" \
    "$policy_set" "$request" "$resolved" "$hop_case"
done
incident_capability="$tmp/incident-capability.json"
"$jq_bin" -S -c '.body.execution.used_capability=
  {kind:"registered",id:"core.review.change.v1"}' "$incident" >"$incident_capability"
expect_eval incident-capability violated actual.capability-mismatch \
  "$policy_set" "$request" "$resolved" "$incident_capability"

bad_policy_set="$tmp/bad-policy-set.json"
"$jq_bin" -S -c '(.body.sections[] | select(.section_id=="duty-separation") |
  .policy_ref.sha256)=("7"*64)' "$policy_set" >"$bad_policy_set"
expect_error policy-identity E_RELATION "$bad_policy_set" "$request" "$resolved" "$result"
bad_decision_ref="$tmp/bad-decision-ref.json"
"$jq_bin" -S -c '(.body.sections[] | select(.section_id=="duty-separation") |
  .decision_ref.sha256)=("7"*64)' "$policy_set" >"$bad_decision_ref"
expect_error decision-identity E_RELATION "$bad_decision_ref" "$request" "$resolved" "$result"
bad_generation="$tmp/bad-generation.json"
"$jq_bin" -S -c '.body.core_contract.generation_id=("g-"+("8"*64))' \
  "$policy_set" >"$bad_generation"
expect_error core-generation E_RELATION "$bad_generation" "$request" "$resolved" "$result"
bad_package="$tmp/bad-package.json"
"$jq_bin" -S -c '.body.core_contract.package_ref.sha256=("7"*64)' \
  "$policy_set" >"$bad_package"
expect_error core-package E_RELATION "$bad_package" "$request" "$resolved" "$result"

bad_request="$tmp/bad-permission-request.json"
bad_request_result="$tmp/bad-permission-result.json"
"$jq_bin" -S -c '.body.operation.permissions=["core.perm.candidate.execute.v1"]' \
  "$request" >"$bad_request"
sync_result "$bad_request" "$bad_request_result"
expect_error producer-ceiling E_CORE "$policy_set" "$bad_request" "$resolved" "$bad_request_result"

collision_resolved="$tmp/collision-resolved.json"
"$jq_bin" -S -c '(.body.bindings[] | select(.binding.role=="reviewer") |
  .binding.principal_id)="principal.producer"' "$resolved" >"$collision_resolved"
expect_error protected-collision E_CORE "$policy_set" "$request" "$collision_resolved" "$result"

pretty_set="$tmp/pretty-policy-set.json"
"$jq_bin" . "$policy_set" >"$pretty_set"
expect_error noncanonical-policy-set E_POLICY_SET "$pretty_set" "$request" "$resolved" "$result"
/bin/ln -s "$request" "$tmp/request-link.json"
expect_error symlink-input E_RUNTIME "$policy_set" "$tmp/request-link.json" "$resolved" "$result"
large="$tmp/large.json"
/usr/bin/awk 'BEGIN { for (i=0;i<1048577;i++) printf "x" }' >"$large"
expect_error input-limit E_LIMIT "$policy_set" "$large" "$resolved" "$result"
copy_root="$tmp/policy-limit-root"
/bin/mkdir -p "$copy_root/control/v1" "$copy_root/scripts"
for copy_path in evaluate-duty.sh duty-separation.jq duty-separation-policy.json \
  duty-separation-decision.json validate.sh; do
  /bin/cp "$root/control/v1/$copy_path" "$copy_root/control/v1/$copy_path"
done
/bin/cp "$root/scripts/core-contract.sh" "$copy_root/scripts/core-contract.sh"
/usr/bin/awk 'BEGIN { for (i=0;i<1048577;i++) printf " " }' \
  >>"$copy_root/control/v1/duty-separation-policy.json"
original_evaluator=$evaluator
evaluator="$copy_root/control/v1/evaluate-duty.sh"
expect_error policy-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result"
evaluator=$original_evaluator

decision_limit_root="$tmp/decision-limit-root"
/bin/cp -R "$copy_root" "$decision_limit_root"
/bin/cp "$decision" "$decision_limit_root/control/v1/duty-separation-decision.json"
/usr/bin/awk 'BEGIN { for (i=0;i<1048577;i++) printf " " }' \
  >>"$decision_limit_root/control/v1/duty-separation-decision.json"
evaluator="$decision_limit_root/control/v1/evaluate-duty.sh"
expect_error decision-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result"
evaluator=$original_evaluator

runtime_root="$tmp/runtime-happy"
copy_runtime "$runtime_root"
evaluator="$runtime_root/control/v1/evaluate-duty.sh"
expect_eval copied-runtime satisfied duty.satisfied "$policy_set" "$request" "$resolved" "$result"
evaluator=$original_evaluator

for stale_kind in wrapper ingress module registry; do
  stale_root="$tmp/stale-$stale_kind"
  stale_sentinel="$tmp/stale-$stale_kind-ran"
  copy_runtime "$stale_root"
  case "$stale_kind" in
    wrapper)
      /usr/bin/printf '\n: > "%s"\n' "$stale_sentinel" \
        >>"$stale_root/scripts/core-contract.sh"
      ;;
    ingress)
      /usr/bin/printf '\n: > "%s"\n' "$stale_sentinel" \
        >>"$stale_root/core/v2/generations/$generation/core-ingress.sh"
      ;;
    module)
      /usr/bin/printf '\n' \
        >>"$stale_root/core/v2/generations/$generation/modules/schema.jq"
      ;;
    registry)
      "$jq_bin" -S -c '.[0].concern += ".stale"' \
        "$stale_root/core/v2/generation-registry.json" >"$stale_root/registry.next"
      /bin/mv "$stale_root/registry.next" "$stale_root/core/v2/generation-registry.json"
      ;;
  esac
  evaluator="$stale_root/control/v1/evaluate-duty.sh"
  expect_error "stale-core-$stale_kind" E_RELATION \
    "$policy_set" "$request" "$resolved" "$result"
  [ ! -e "$stale_sentinel" ] || fail "stale $stale_kind executed"
done
evaluator=$original_evaluator
pass 'stale core closure is rejected before execution'

moving_root="$tmp/moving-core"
moving_scratch="$tmp/moving-scratch"
copy_runtime "$moving_root"
/bin/mkdir -p "$moving_scratch"
moving_sentinel="$tmp/moving-live-ingress-ran"
moving_target="$moving_root/core/v2/generations/$generation/core-ingress.sh"
(
  while [ -z "$(/usr/bin/find "$moving_scratch" -name core-closure-mirror.json \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n: > "%s"\n' "$moving_sentinel" >>"$moving_target"
) &
moving_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$moving_scratch"
evaluator="$moving_root/control/v1/evaluate-duty.sh"
expect_error moving-core-postflight E_RELATION "$policy_set" "$request" "$resolved" "$result"
wait "$moving_pid"
[ ! -e "$moving_sentinel" ] || fail 'moving live ingress executed'
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

failure_root="$tmp/moving-core-failure"
failure_scratch="$tmp/moving-failure-scratch"
copy_runtime "$failure_root"
/bin/mkdir -p "$failure_scratch"
(
  while [ -z "$(/usr/bin/find "$failure_scratch" -name core-closure-mirror.json \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n' \
    >>"$failure_root/core/v2/generations/$generation/modules/schema.jq"
) &
failure_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$failure_scratch"
evaluator="$failure_root/control/v1/evaluate-duty.sh"
expect_error moving-core-beats-core-error E_RELATION \
  "$policy_set" "$bad_request" "$resolved" "$bad_request_result"
wait "$failure_pid"
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

swap_root="$tmp/swap-restore-core"
swap_scratch="$tmp/swap-restore-scratch"
swap_sentinel="$tmp/swap-live-ingress-ran"
copy_runtime "$swap_root"
/bin/mkdir -p "$swap_scratch"
swap_target="$swap_root/core/v2/generations/$generation/core-ingress.sh"
/bin/cp "$swap_target" "$tmp/swap-ingress.saved"
(
  while [ -z "$(/usr/bin/find "$swap_scratch" -name core-closure-mirror.json \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n: > "%s"\n' "$swap_sentinel" >>"$swap_target"
  while [ -z "$(/usr/bin/find "$swap_scratch" -name run.out \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /bin/cp "$tmp/swap-ingress.saved" "$swap_target"
) &
swap_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$swap_scratch"
evaluator="$swap_root/control/v1/evaluate-duty.sh"
expect_eval live-swap-restore satisfied duty.satisfied \
  "$policy_set" "$request" "$resolved" "$result"
wait "$swap_pid"
[ ! -e "$swap_sentinel" ] || fail 'swap-restore live ingress executed'
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

scripts_victim="$tmp/scripts-link-victim"
scripts_sibling="$tmp/scripts-link-sibling"
scripts_sentinel="$tmp/scripts-link-ingress-ran"
copy_runtime "$scripts_victim"
copy_runtime "$scripts_sibling"
/usr/bin/printf '\n: > "%s"\n' "$scripts_sentinel" \
  >>"$scripts_sibling/core/v2/generations/$generation/core-ingress.sh"
/bin/rm -rf "$scripts_victim/scripts"
/bin/ln -s "$scripts_sibling/scripts" "$scripts_victim/scripts"
evaluator="$scripts_victim/control/v1/evaluate-duty.sh"
expect_error symlinked-scripts-root E_RELATION "$policy_set" "$request" "$resolved" "$result"
[ ! -e "$scripts_sentinel" ] || fail 'symlinked scripts core executed'
evaluator=$original_evaluator

for unsafe_kind in extra symlink; do
  unsafe_root="$tmp/unsafe-$unsafe_kind"
  copy_runtime "$unsafe_root"
  if [ "$unsafe_kind" = extra ]; then
    : >"$unsafe_root/core/v2/generations/$generation/unknown"
  else
    /bin/rm -f "$unsafe_root/core/v2/generations/$generation/modules/schema.jq"
    /bin/ln -s result_truth.jq \
      "$unsafe_root/core/v2/generations/$generation/modules/schema.jq"
  fi
  evaluator="$unsafe_root/control/v1/evaluate-duty.sh"
  expect_error "unsafe-core-$unsafe_kind" E_RELATION \
    "$policy_set" "$request" "$resolved" "$result"
done
evaluator=$original_evaluator

rebound_decision_root="$tmp/rebound-validator-decision"
copy_runtime "$rebound_decision_root"
"$jq_bin" -S -c '.body.evaluator.policy_set_validator.driver_ref.sha256=("7"*64)' \
  "$rebound_decision_root/control/v1/duty-separation-decision.json" \
  >"$rebound_decision_root/decision.next"
/bin/mv "$rebound_decision_root/decision.next" \
  "$rebound_decision_root/control/v1/duty-separation-decision.json"
rebound_decision_sha=$(sha256_path \
  "$rebound_decision_root/control/v1/duty-separation-decision.json")
"$jq_bin" -S -c --arg sha "$rebound_decision_sha" \
  '(.body.sections[] | select(.section_id=="duty-separation") |
    .decision_ref.sha256)=$sha' "$policy_set" >"$tmp/rebound-decision-policy-set.json"
evaluator="$rebound_decision_root/control/v1/evaluate-duty.sh"
expect_error rebound-validator-decision E_RELATION \
  "$tmp/rebound-decision-policy-set.json" "$request" "$resolved" "$result"
evaluator=$original_evaluator

for stale_kind in validator-driver validator-program; do
  stale_root="$tmp/stale-$stale_kind"
  stale_sentinel="$tmp/stale-$stale_kind-ran"
  copy_runtime "$stale_root"
  if [ "$stale_kind" = validator-driver ]; then
    /usr/bin/printf '\n: > "%s"\n' "$stale_sentinel" \
      >>"$stale_root/control/v1/validate.sh"
  else
    /usr/bin/printf '\n' >>"$stale_root/control/v1/policy-set.jq"
  fi
  evaluator="$stale_root/control/v1/evaluate-duty.sh"
  expect_error "stale-$stale_kind" E_RELATION \
    "$policy_set" "$request" "$resolved" "$result"
  [ ! -e "$stale_sentinel" ] || fail "stale $stale_kind executed"
done
evaluator=$original_evaluator

validator_link_root="$tmp/validator-link"
copy_runtime "$validator_link_root"
/bin/rm -f "$validator_link_root/control/v1/validate.sh"
/bin/ln -s "$root/control/v1/validate.sh" "$validator_link_root/control/v1/validate.sh"
evaluator="$validator_link_root/control/v1/evaluate-duty.sh"
expect_error symlinked-validator E_RELATION "$policy_set" "$request" "$resolved" "$result"
evaluator=$original_evaluator

validator_move_root="$tmp/moving-validator"
validator_move_scratch="$tmp/moving-validator-scratch"
validator_move_sentinel="$tmp/moving-validator-ran"
copy_runtime "$validator_move_root"
/bin/mkdir -p "$validator_move_scratch"
(
  while [ -z "$(/usr/bin/find "$validator_move_scratch" -name policy-validator-ready \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n: > "%s"\n' "$validator_move_sentinel" \
    >>"$validator_move_root/control/v1/validate.sh"
) &
validator_move_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$validator_move_scratch"
evaluator="$validator_move_root/control/v1/evaluate-duty.sh"
expect_error moving-validator E_RELATION "$policy_set" "$request" "$resolved" "$result"
wait "$validator_move_pid"
[ ! -e "$validator_move_sentinel" ] || fail 'moving live validator executed'
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

validator_failure_root="$tmp/moving-validator-failure"
validator_failure_scratch="$tmp/moving-validator-failure-scratch"
copy_runtime "$validator_failure_root"
/bin/mkdir -p "$validator_failure_scratch"
(
  while [ -z "$(/usr/bin/find "$validator_failure_scratch" -name policy-validator-ready \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n' >>"$validator_failure_root/control/v1/policy-set.jq"
) &
validator_failure_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$validator_failure_scratch"
evaluator="$validator_failure_root/control/v1/evaluate-duty.sh"
expect_error validator-movement-beats-policy-error E_RELATION \
  "$pretty_set" "$request" "$resolved" "$result"
wait "$validator_failure_pid"
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

validator_swap_root="$tmp/validator-swap"
validator_swap_scratch="$tmp/validator-swap-scratch"
validator_swap_sentinel="$tmp/validator-swap-ran"
copy_runtime "$validator_swap_root"
/bin/mkdir -p "$validator_swap_scratch"
/bin/cp "$validator_swap_root/control/v1/validate.sh" "$tmp/validator.saved"
(
  while [ -z "$(/usr/bin/find "$validator_swap_scratch" -name policy-validator-ready \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /usr/bin/printf '\n: > "%s"\n' "$validator_swap_sentinel" \
    >>"$validator_swap_root/control/v1/validate.sh"
  while [ -z "$(/usr/bin/find "$validator_swap_scratch" -name policy-validator-complete \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  /bin/cp "$tmp/validator.saved" "$validator_swap_root/control/v1/validate.sh"
) &
validator_swap_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$validator_swap_scratch"
evaluator="$validator_swap_root/control/v1/evaluate-duty.sh"
expect_eval validator-swap-restore satisfied duty.satisfied \
  "$policy_set" "$request" "$resolved" "$result"
wait "$validator_swap_pid"
[ ! -e "$validator_swap_sentinel" ] || fail 'swap-restore live validator executed'
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

mirror_move_root="$tmp/moving-validator-mirror"
mirror_move_scratch="$tmp/moving-validator-mirror-scratch"
copy_runtime "$mirror_move_root"
/bin/mkdir -p "$mirror_move_scratch"
(
  while [ -z "$(/usr/bin/find "$mirror_move_scratch" -name policy-validator-ready \
    -type f -print -quit 2>/dev/null)" ]; do :; done
  mirror_program=$( /usr/bin/find "$mirror_move_scratch" \
    -path '*/policy-validator/control/v1/policy-set.jq' -type f -print -quit )
  /usr/bin/printf '\n' >>"$mirror_program"
) &
mirror_move_pid=$!
saved_tmpdir=${TMPDIR-}
export TMPDIR="$mirror_move_scratch"
evaluator="$mirror_move_root/control/v1/evaluate-duty.sh"
expect_error moving-validator-mirror E_RELATION "$policy_set" "$request" "$resolved" "$result"
wait "$mirror_move_pid"
if [ -n "$saved_tmpdir" ]; then export TMPDIR="$saved_tmpdir"; else unset TMPDIR; fi
evaluator=$original_evaluator

for stale_kind in decision program driver; do
  stale_root="$tmp/stale-$stale_kind"
  copy_runtime "$stale_root"
  case "$stale_kind" in
    decision)
      "$jq_bin" -S -c '.body.extra=true' \
        "$stale_root/control/v1/duty-separation-decision.json" >"$stale_root/decision.next"
      /bin/mv "$stale_root/decision.next" \
        "$stale_root/control/v1/duty-separation-decision.json"
      ;;
    program) /usr/bin/printf '\n' >>"$stale_root/control/v1/duty-separation.jq" ;;
    driver) /usr/bin/printf '\n' >>"$stale_root/control/v1/evaluate-duty.sh" ;;
  esac
  evaluator="$stale_root/control/v1/evaluate-duty.sh"
  expect_error "stale-$stale_kind" E_RELATION \
    "$policy_set" "$request" "$resolved" "$result"
done
evaluator=$original_evaluator

for required in control/v1/duty-separation-policy.json \
  control/v1/duty-separation-decision.json control/v1/duty-separation.jq \
  control/v1/evaluate-duty.sh scripts/test/control-duty-separation.test.sh; do
  [ "$(/usr/bin/grep -Fxc "$required" "$root/ci/required-files.txt")" -eq 1 ] ||
    fail "manifest $required"
done
/usr/bin/grep -Fq 'Inactive duty-separation evaluator' "$root/README.md" || fail 'README docs'
/usr/bin/grep -Fq 'control-duty-separation.test.sh' "$root/RESTORE.md" || fail 'RESTORE docs'
pass 'restore manifest and docs'
/usr/bin/printf 'control duty separation: %s focused checks passed\n' "$passes"
