#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_RISK_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_RISK_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 240; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-risk-gates.sh"
duty_evaluator="$root/control/v1/evaluate-duty.sh"
policy="$root/control/v1/risk-gates-policy.json"
definition="$root/control/v1/risk-gates-decision.json"
duty_policy="$root/control/v1/duty-separation-policy.json"
duty_definition="$root/control/v1/duty-separation-decision.json"
core_wrapper="$root/scripts/core-contract.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-risk-test.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT HUP INT TERM
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*)
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
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
policy_sha=$(sha256_path "$policy")
definition_sha=$(sha256_path "$definition")
duty_policy_sha=$(sha256_path "$duty_policy")
duty_definition_sha=$(sha256_path "$duty_definition")
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")

for canonical_source in "$policy" "$definition"; do
  "$jq_bin" -S -c . "$canonical_source" >"$tmp/canonical"
  /usr/bin/cmp -s "$canonical_source" "$tmp/canonical" ||
    fail "canonical ${canonical_source##*/}"
done
for source_path in control/v1/risk-gates-policy.json \
  control/v1/risk-gates-decision.json control/v1/risk-gates.jq \
  control/v1/evaluate-risk-gates.sh scripts/test/control-risk-gates.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation $source_path"
done
pass 'canonical shipped definitions and opaque generation identity'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg risk_policy_sha "$policy_sha" \
  --arg risk_definition_sha "$definition_sha" --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_definition_sha "$duty_definition_sha" --arg generation "$generation" \
  --arg core_package_sha "$core_package_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy_sha;$decision_sha):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;
       "application/vnd.ystack.control-policy+json";$policy_sha),
     decision_ref:ref("control-decision."+$id;
       "application/vnd.ystack.control-decision+json";$decision_sha)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.test",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
     core_contract:{semantic_identity:"core.contracts.v2",generation_id:$generation,
       package_ref:ref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";$core_package_sha)},
     sections:[section("credential-policy";("1"*64);("a"*64)),
       section("duty-separation";$duty_policy_sha;$duty_definition_sha),
       section("evidence-integrity";("3"*64);("c"*64)),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";$risk_policy_sha;$risk_definition_sha),
       section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set"

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

policy_scope() {
  local request=$1 output=$2 descriptor digest
  descriptor=$("$jq_bin" -S -c -n --arg policy_sha "$policy_sha" \
    --slurpfile request "$request" '
    {schema_version:1,kind:"risk_policy_scope",
     policy_ref:{content_id:"control-policy.risk-gates",
       media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
     subject_ref:{type:"artifact",value:$request[0].body.source.value}}
  ')
  digest=$(sha256_text "$descriptor")
  "$jq_bin" -S -c -n --arg policy_sha "$policy_sha" --arg digest "$digest" \
    --slurpfile request "$request" '
    {purpose:"policy",
     decision_record_ref:{content_id:"control-policy.risk-gates",
       media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
     subject_ref:{type:"artifact",value:$request[0].body.source.value},
     scope_sha256:$digest}
  ' >"$output"
}
requirement_scope() {
  local request=$1 tier=$2 output=$3 descriptor digest
  descriptor=$("$jq_bin" -S -c -n --arg policy_sha "$policy_sha" --arg tier "$tier" \
    --slurpfile request "$request" '
    {schema_version:1,kind:"risk_gate_requirement",declared_tier:$tier,
     policy_ref:{content_id:"control-policy.risk-gates",
       media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
     subject_ref:{type:"artifact",value:$request[0].body.source.value}}
  ')
  digest=$(sha256_text "$descriptor")
  "$jq_bin" -S -c -n --arg policy_sha "$policy_sha" --arg digest "$digest" \
    --slurpfile request "$request" '
    {purpose:"gate-requirement",
     decision_record_ref:{content_id:"control-policy.risk-gates",
       media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
     subject_ref:{type:"artifact",value:$request[0].body.source.value},
     scope_sha256:$digest}
  ' >"$output"
}

build_case() {
  local name=$1 declared=$2 classification=$3 decision_state=$4 decision_kind=$5
  local decision_role=$6 asserted=$7 reason=$8 mode=${9:-normal}
  local namespace=${10:-core}
  local dir="$tmp/$name" base_request="$tmp/$name.base-request"
  local request_basis request_basis_sha claim_sha request_sha
  /bin/mkdir -p "$dir"
  "$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
    import "portable-core-stage-request-fixtures" as request;
    request::request_doc("producer";$resolved_sha) |
    walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
  ' >"$base_request"
  if [ "$mode" = bootstrap ]; then
    "$jq_bin" -S -c '.body.target_revision={state:"absent"} |
      .body.base={state:"absent"}' "$base_request" >"$dir/request.seed"
  elif [ "$mode" = duty-collision ]; then
    "$jq_bin" -S -c '.body.requested_by.principal_id="principal.producer"' \
      "$base_request" >"$dir/request.seed"
  else
    /bin/cp "$base_request" "$dir/request.seed"
  fi
  "$jq_bin" -S -c --arg declared "$declared" --arg namespace "$namespace" \
    --arg reason "$reason" '
    .body.risk.tier={namespace:$namespace,name:$declared} |
    .body.risk.reason_ids=[$reason] |
    .body.gate_decision_refs=[]
  ' "$dir/request.seed" >"$dir/request.typed"
  policy_scope "$dir/request.typed" "$dir/policy-scope.json"
  requirement_scope "$dir/request.typed" "$declared" "$dir/requirement-scope.json"
  "$jq_bin" -S -c --slurpfile policy_ref "$dir/policy-scope.json" \
    --slurpfile requirement "$dir/requirement-scope.json" '
    .body.risk.policy_ref=$policy_ref[0] |
    .body.risk.required_gate_refs=[$requirement[0]]
  ' "$dir/request.typed" >"$dir/request.basis"
  request_basis=$("$jq_bin" -S -c \
    '{schema_version,kind,id,body:(.body|del(.gate_decision_refs))}' "$dir/request.basis")
  request_basis_sha=$(sha256_text "$request_basis")
  if [ "$decision_state" = absent ]; then
    decision_json='{"state":"absent"}'
  else
    decision_json=$("$jq_bin" -S -c -n --arg kind "$decision_kind" \
      --arg role "$decision_role" --arg asserted "$asserted" '
      {state:"present",value:{asserted_decision:$asserted,decision_kind:$kind,
        decided_by:{role:$role,implementation_id:("implementation."+$role),
          implementation_version:"v1",adapter_instance_id:("instance."+$role),
          principal_id:("principal."+$role),execution_boundary_id:("boundary."+$role)},
        recorded_at:"2026-08-29T23:59:59Z"}}
    ')
  fi
  "$jq_bin" -S -c -n --arg id "risk.claim.$name" \
    --arg classification "$classification" --arg reason "$reason" \
    --arg request_basis_sha "$request_basis_sha" --argjson decision "$decision_json" \
    --slurpfile policy_ref "$dir/policy-scope.json" \
    --slurpfile requirement "$dir/requirement-scope.json" '
    {schema_version:1,kind:"risk_gate_decision_claim",id:$id,
     body:{activation_state:"inactive",
       classification:{tier:$classification,reason_ids:[$reason]},
       decision:$decision,policy_ref:$policy_ref[0],
       request_basis_sha256:$request_basis_sha,
       required_gate_refs:[$requirement[0]]}}
  ' >"$dir/claim.json"
  claim_sha=$(sha256_path "$dir/claim.json")
  "$jq_bin" -S -c --arg id "risk.claim.$name" --arg claim_sha "$claim_sha" \
    --arg request_basis_sha "$request_basis_sha" '
    .body.gate_decision_refs=[{purpose:"gate-decision",
      decision_record_ref:{content_id:$id,
        media_type:"application/vnd.ystack.risk-gate-decision-claim+json",sha256:$claim_sha},
      subject_ref:{type:"artifact",value:.body.source.value},
      scope_sha256:$request_basis_sha}]
  ' "$dir/request.basis" >"$dir/request.json"
  request_sha=$(sha256_path "$dir/request.json")
  "$jq_bin" -L "$root/scripts/test" -S -c -n \
    --slurpfile request "$dir/request.json" --slurpfile resolved "$resolved" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
    import "portable-core-result-truth-fixtures" as result;
    result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
    walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
  ' >"$dir/result.json"
  PATH="$bin:/usr/bin:/bin" "$duty_evaluator" evaluate "$policy_set" \
    "$dir/request.json" "$resolved" "$dir/result.json" >"$dir/duty.json" \
    2>"$dir/duty.err" || {
      /bin/cat "$dir/duty.err" >&2
      fail "build duty $name"
    }
}

expect_eval() {
  local name=$1 verdict=$2 reason=$3
  local dir="$tmp/$name" out="$tmp/$name/risk.out"
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$dir/request.json" \
    "$resolved" "$dir/result.json" "$dir/duty.json" "$dir/claim.json" \
    >"$out" 2>"$dir/risk.err" || {
      /bin/cat "$dir/risk.err" >&2
      fail "$name status"
    }
  [ ! -s "$dir/risk.err" ] || fail "$name stderr"
  "$jq_bin" -e --arg verdict "$verdict" --arg reason "$reason" '
    .kind=="risk_gate_evaluation" and .body.activation_state=="inactive" and
    .body.authority_effect=="none" and .body.evaluation_mode=="observation-only" and
    .body.reference_semantics=="identity-only" and .body.verdict==$verdict and
    (.body.reason_ids|index($reason)!=null) and .body.reason_ids==(.body.reason_ids|sort|unique) and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
  ' "$out" >/dev/null || fail "$name verdict"
  "$jq_bin" -S -c . "$out" >"$dir/repeat"
  /usr/bin/cmp -s "$out" "$dir/repeat" || fail "$name canonical output"
  pass "$name"
}

expect_error() {
  local name=$1 expected=$2 runtime=${3:-$root}
  local dir="$tmp/$name" status=0
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-risk-gates.sh" evaluate \
    "$policy_set" "$dir/request.json" "$resolved" "$dir/result.json" \
    "$dir/duty.json" "$dir/claim.json" >"$dir/error.out" 2>"$dir/error.err" ||
    status=$?
  [ "$status" -ne 0 ] && [ ! -s "$dir/error.out" ] &&
    [ "$(/bin/cat "$dir/error.err")" = "$expected" ] || fail "$name error"
  pass "$name"
}

build_case routine routine routine present independent-plan-check reviewer accept \
  risk.routine
expect_eval routine satisfied risk-gates.satisfied

build_case routine-escalated high routine present operator-plan-approval operator accept \
  risk.routine
expect_eval routine-escalated satisfied risk-gates.satisfied

build_case high high high present operator-plan-approval operator accept \
  risk.security-control
expect_eval high satisfied risk-gates.satisfied

build_case bootstrap bootstrap bootstrap present operator-bootstrap-approval operator accept \
  risk.bootstrap bootstrap
expect_eval bootstrap satisfied risk-gates.satisfied

build_case missing high high absent ignored operator accept risk.security-control
expect_eval missing violated decision.missing

build_case rejected high high present operator-plan-approval operator reject \
  risk.security-control
expect_eval rejected violated decision.rejected

build_case downgrade routine high present independent-plan-check reviewer accept \
  risk.security-control
expect_eval downgrade violated risk.tier-downgrade

build_case invented-role high high present operator-plan-approval reviewer accept \
  risk.security-control
expect_eval invented-role violated decision.role-denied

build_case invented-kind high high present independent-plan-check operator accept \
  risk.security-control
expect_eval invented-kind violated decision.kind-denied

build_case after-request routine routine present independent-plan-check reviewer accept \
  risk.routine
"$jq_bin" -S -c '.body.decision.value.recorded_at="2026-09-01T00:00:01Z"' \
  "$tmp/after-request/claim.json" >"$tmp/after-request/claim.changed"
/bin/mv "$tmp/after-request/claim.changed" "$tmp/after-request/claim.json"
expect_eval after-request violated decision.after-request

build_case stale routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.request_basis_sha256=("0"*64)' "$tmp/stale/claim.json" \
  >"$tmp/stale/claim.changed"
/bin/mv "$tmp/stale/claim.changed" "$tmp/stale/claim.json"
expect_eval stale violated decision.stale

build_case unbound routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.gate_decision_refs[0].decision_record_ref.sha256=("0"*64)' \
  "$tmp/unbound/request.json" >"$tmp/unbound/request.changed"
/bin/mv "$tmp/unbound/request.changed" "$tmp/unbound/request.json"
unbound_request_sha=$(sha256_path "$tmp/unbound/request.json")
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$tmp/unbound/request.json" --slurpfile resolved "$resolved" \
  --arg request_sha "$unbound_request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$tmp/unbound/result.json"
PATH="$bin:/usr/bin:/bin" "$duty_evaluator" evaluate "$policy_set" \
  "$tmp/unbound/request.json" "$resolved" "$tmp/unbound/result.json" \
  >"$tmp/unbound/duty.json" 2>"$tmp/unbound/duty.err" || fail 'unbound duty rebuild'
expect_eval unbound violated decision.unbound

build_case ambiguous routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.gate_decision_refs += [{purpose:"gate-decision",
  decision_record_ref:{content_id:"risk.claim.other",
    media_type:"application/vnd.ystack.risk-gate-decision-claim+json",sha256:("1"*64)},
  subject_ref:{type:"artifact",value:.body.source.value},scope_sha256:("0"*64)}] |
  .body.gate_decision_refs |= sort_by(.scope_sha256)' "$tmp/ambiguous/request.json" \
  >"$tmp/ambiguous/request.changed"
/bin/mv "$tmp/ambiguous/request.changed" "$tmp/ambiguous/request.json"
ambiguous_request_sha=$(sha256_path "$tmp/ambiguous/request.json")
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$tmp/ambiguous/request.json" --slurpfile resolved "$resolved" \
  --arg request_sha "$ambiguous_request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$tmp/ambiguous/result.json"
PATH="$bin:/usr/bin:/bin" "$duty_evaluator" evaluate "$policy_set" \
  "$tmp/ambiguous/request.json" "$resolved" "$tmp/ambiguous/result.json" \
  >"$tmp/ambiguous/duty.json" 2>"$tmp/ambiguous/duty.err" ||
  fail 'ambiguous duty rebuild'
expect_eval ambiguous violated decision.ambiguous

build_case unsupported custom routine present independent-plan-check reviewer accept \
  risk.routine normal example.test
expect_eval unsupported inconclusive risk.tier-unsupported

build_case duty-violated routine routine present independent-plan-check reviewer accept \
  risk.routine duty-collision
expect_eval duty-violated violated duty.violated

build_case forged-duty routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.verdict="violated" | .body.reason_ids=["duty.violated"]' \
  "$tmp/forged-duty/duty.json" >"$tmp/forged-duty/duty.changed"
/bin/mv "$tmp/forged-duty/duty.changed" "$tmp/forged-duty/duty.json"
expect_error forged-duty E_DUTY

link="$tmp/request-link.json"
/bin/ln -s "$tmp/routine/request.json" "$link"
status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$link" "$resolved" \
  "$tmp/routine/result.json" "$tmp/routine/duty.json" "$tmp/routine/claim.json" \
  >"$tmp/link.out" 2>"$tmp/link.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/link.out" ] &&
  [ "$(/bin/cat "$tmp/link.err")" = E_RUNTIME ] || fail 'symlink input rejection'
pass 'symlink input rejection'

relative_bin="$tmp/relative-bin"
/bin/mkdir "$relative_bin"
/bin/cp "$jq_bin" "$relative_bin/jq"
status=0
(cd "$relative_bin" && PATH=".:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
  "$tmp/routine/request.json" "$resolved" "$tmp/routine/result.json" \
  "$tmp/routine/duty.json" "$tmp/routine/claim.json") \
  >"$tmp/relative.out" 2>"$tmp/relative.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/relative.out" ] &&
  [ "$(/bin/cat "$tmp/relative.err")" = E_RUNTIME ] || fail 'relative jq rejection'
pass 'relative jq rejection'

copy_runtime() {
  local destination=$1 copy_path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for copy_path in risk-gates-policy.json risk-gates-decision.json risk-gates.jq \
    evaluate-risk-gates.sh duty-separation-policy.json duty-separation-decision.json \
    duty-separation.jq evaluate-duty.sh validate.sh policy-set.jq; do
    /bin/cp "$root/control/v1/$copy_path" "$destination/control/v1/$copy_path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}

dependency_runtime="$tmp/dependency-runtime"
copy_runtime "$dependency_runtime"
/usr/bin/printf '\n' >>"$dependency_runtime/control/v1/duty-separation-decision.json"
/bin/cp -R "$tmp/routine" "$tmp/dependency-binding"
expect_error dependency-binding E_DUTY "$dependency_runtime"

race_runtime="$tmp/race-runtime"
copy_runtime "$race_runtime"
race_bin="$tmp/race-bin"
race_scratch="$tmp/race-scratch"
race_trigger="$tmp/race-trigger"
/bin/mkdir -p "$race_bin" "$race_scratch"
/usr/bin/printf '%s\n' '#!/bin/bash' "real_jq='$jq_bin'" \
  'if [ "${1:-}" = --version ]; then exec "$real_jq" "$@"; fi' \
  'for arg in "$@"; do' \
  '  case "$arg" in' \
  '    */program.jq)' \
  '      marker=$(/usr/bin/find "${TMPDIR:-/tmp}" -type f -name risk-ready -print -quit 2>/dev/null)' \
  '      if [ -n "$marker" ] && [ ! -e "$RISK_TRIGGER" ]; then' \
  '        : >"$RISK_TRIGGER"' \
  '        /bin/sleep 1' \
  '      fi' \
  '      ;;' \
  '  esac' \
  'done' \
  'exec "$real_jq" "$@"' >"$race_bin/jq"
/bin/chmod 0555 "$race_bin/jq"
(
  status=0
  TMPDIR="$race_scratch" RISK_TRIGGER="$race_trigger" \
    PATH="$race_bin:/usr/bin:/bin" \
    "$race_runtime/control/v1/evaluate-risk-gates.sh" evaluate "$policy_set" \
    "$tmp/routine/request.json" "$resolved" "$tmp/routine/result.json" \
    "$tmp/routine/duty.json" "$tmp/routine/claim.json" \
    >"$tmp/race.out" 2>"$tmp/race.err" || status=$?
  /usr/bin/printf '%s\n' "$status" >"$tmp/race.status"
) &
race_pid=$!
attempt=0
while [ ! -e "$race_trigger" ] && kill -0 "$race_pid" 2>/dev/null &&
  [ "$attempt" -lt 400 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$race_trigger" ]; then
  kill -TERM "$race_pid" 2>/dev/null || :
  wait "$race_pid" 2>/dev/null || :
  fail 'risk program race marker'
fi
/usr/bin/printf '\n' >>"$race_runtime/control/v1/risk-gates.jq"
wait "$race_pid"
[ "$(/bin/cat "$tmp/race.status")" -ne 0 ] && [ ! -s "$tmp/race.out" ] &&
  [ "$(/bin/cat "$tmp/race.err")" = E_RELATION ] || fail 'risk program TOCTOU'
pass 'risk program TOCTOU closes after mirrored execution'

pure_dir="$tmp/routine"
pure_policy_set_sha=$(sha256_path "$policy_set")
pure_request_sha=$(sha256_path "$pure_dir/request.json")
pure_result_sha=$(sha256_path "$pure_dir/result.json")
pure_duty_sha=$(sha256_path "$pure_dir/duty.json")
pure_claim_sha=$(sha256_path "$pure_dir/claim.json")
pure_basis=$("$jq_bin" -S -c \
  '{schema_version,kind,id,body:(.body|del(.gate_decision_refs))}' \
  "$pure_dir/request.json")
pure_basis_sha=$(sha256_text "$pure_basis")
policy_scope "$pure_dir/request.json" "$tmp/pure-policy-scope"
pure_policy_scope_sha=$("$jq_bin" -r '.scope_sha256' "$tmp/pure-policy-scope")
requirement_scope "$pure_dir/request.json" routine "$tmp/pure-requirement-scope"
pure_requirement_sha=$("$jq_bin" -r '.scope_sha256' "$tmp/pure-requirement-scope")
"$jq_bin" -S -c -n -f "$root/control/v1/risk-gates.jq" \
  --slurpfile policy "$policy" --slurpfile decision "$definition" \
  --slurpfile policy_set "$policy_set" --slurpfile request "$pure_dir/request.json" \
  --slurpfile resolved "$resolved" --slurpfile result "$pure_dir/result.json" \
  --slurpfile duty_evaluation "$pure_dir/duty.json" \
  --slurpfile claim "$pure_dir/claim.json" --arg policy_sha "$policy_sha" \
  --arg decision_sha "$definition_sha" --arg policy_set_sha "$pure_policy_set_sha" \
  --arg request_sha "$pure_request_sha" --arg resolved_sha "$resolved_sha" \
  --arg result_sha "$pure_result_sha" --arg duty_sha "$pure_duty_sha" \
  --arg claim_sha "$pure_claim_sha" --arg request_basis_sha "$pure_basis_sha" \
  --arg policy_scope_sha "$pure_policy_scope_sha" \
  --arg requirement_scope_sha "$pure_requirement_sha" >"$tmp/pure.out"
"$jq_bin" -e '.body.verdict=="satisfied" and
  .body.reason_ids==["risk-gates.satisfied"]' "$tmp/pure.out" >/dev/null ||
  fail 'pure evaluator'
pass 'pure evaluator canonical satisfied path'

/usr/bin/printf 'control risk gates: %s passed\n' "$passes"
