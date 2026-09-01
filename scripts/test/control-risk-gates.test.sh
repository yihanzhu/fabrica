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
eval_tmp="$tmp/evaluator-scratch"
/bin/mkdir -p "$eval_tmp"
ACTIVE_EVAL_PID=''
ACTIVE_EVAL_PGID=''
LAUNCH_COUNTER=0

group_alive() { kill -0 -- "-$1" 2>/dev/null; }
clear_active() { ACTIVE_EVAL_PID=''; ACTIVE_EVAL_PGID=''; }
terminate_active() {
  local attempt=0
  [ -n "$ACTIVE_EVAL_PID" ] && [ -n "$ACTIVE_EVAL_PGID" ] || return 0
  [[ "$ACTIVE_EVAL_PID" =~ ^[1-9][0-9]*$ ]] &&
    [ "$ACTIVE_EVAL_PID" = "$ACTIVE_EVAL_PGID" ] || return 1
  if kill -0 "$ACTIVE_EVAL_PID" 2>/dev/null; then
    kill -TERM "$ACTIVE_EVAL_PID" 2>/dev/null || :
  fi
  if group_alive "$ACTIVE_EVAL_PGID"; then
    kill -TERM -- "-$ACTIVE_EVAL_PGID" 2>/dev/null || :
  fi
  while group_alive "$ACTIVE_EVAL_PGID" && [ "$attempt" -lt 40 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.025
  done
  if group_alive "$ACTIVE_EVAL_PGID"; then
    kill -KILL -- "-$ACTIVE_EVAL_PGID" 2>/dev/null || :
  fi
  if kill -0 "$ACTIVE_EVAL_PID" 2>/dev/null; then
    kill -KILL "$ACTIVE_EVAL_PID" 2>/dev/null || :
  fi
  attempt=0
  while group_alive "$ACTIVE_EVAL_PGID" && [ "$attempt" -lt 80 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.025
  done
  wait "$ACTIVE_EVAL_PID" 2>/dev/null || :
  group_alive "$ACTIVE_EVAL_PGID" && return 1
  clear_active
}
start_group() {
  local out=$1 err=$2 attempt=0 ready
  shift 2
  LAUNCH_COUNTER=$((LAUNCH_COUNTER + 1))
  ready="$tmp/launcher-ready-$LAUNCH_COUNTER"
  /usr/bin/perl -e '
    use POSIX ();
    my $ready = shift @ARGV;
    POSIX::setpgid(0,0) == 0 or die "setpgid";
    open my $fh, ">", $ready or die "ready";
    print {$fh} "ready\n";
    close $fh or die "ready";
    exec @ARGV;
  ' "$ready" "$@" >"$out" 2>"$err" &
  ACTIVE_EVAL_PID=$!
  ACTIVE_EVAL_PGID=$ACTIVE_EVAL_PID
  while [ ! -s "$ready" ] && [ "$attempt" -lt 100 ]; do
    kill -0 "$ACTIVE_EVAL_PID" 2>/dev/null || break
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  if [ ! -s "$ready" ]; then
    terminate_active || :
    return 126
  fi
  /bin/rm -f -- "$ready"
}
wait_group() {
  local timeout_seconds=$1 ticks=0 max_ticks status=0
  max_ticks=$((timeout_seconds * 20))
  while group_alive "$ACTIVE_EVAL_PGID" && [ "$ticks" -lt "$max_ticks" ]; do
    ticks=$((ticks + 1))
    /bin/sleep 0.05
  done
  if group_alive "$ACTIVE_EVAL_PGID"; then
    terminate_active || return 125
    return 124
  fi
  wait "$ACTIVE_EVAL_PID" 2>/dev/null || status=$?
  clear_active
  return "$status"
}
run_bounded() {
  local timeout_seconds=$1 out=$2 err=$3
  shift 3
  start_group "$out" "$err" "$@" || return $?
  wait_group "$timeout_seconds"
}
cleanup() {
  local status=0
  terminate_active || status=1
  /bin/rm -rf -- "$tmp"
  return "$status"
}
on_exit() {
  local status=$?
  trap - EXIT HUP INT TERM ALRM
  cleanup || status=1
  exit "$status"
}
on_alarm() {
  trap - ALRM
  terminate_active || :
  exit 124
}
on_signal() {
  trap - HUP INT TERM
  terminate_active || :
  exit 124
}
trap on_exit EXIT
trap on_signal HUP INT TERM
trap on_alarm ALRM
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
  local decision_time=${11:-2026-08-29T23:59:59Z}
  local dir="$tmp/$name" base_request="$tmp/$name.base-request"
  local request_basis request_basis_sha claim_sha request_sha actor_json
  /bin/mkdir -p "$dir"
  "$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
    import "portable-core-stage-request-fixtures" as request;
    request::request_doc("producer";$resolved_sha) |
    walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
  ' >"$base_request"
  if [ "$mode" = bootstrap ] || [ "$mode" = tier-number-bootstrap ] ||
    [ "$mode" = tier-object-bootstrap ] || [ "$mode" = tier-null-bootstrap ]; then
    "$jq_bin" -S -c '.body.target_revision={state:"absent"} |
      .body.base={state:"absent"}' "$base_request" >"$dir/request.seed"
  elif [ "$mode" = duty-collision ]; then
    "$jq_bin" -S -c '.body.requested_by.principal_id="principal.producer"' \
      "$base_request" >"$dir/request.seed"
  else
    /bin/cp "$base_request" "$dir/request.seed"
  fi
  "$jq_bin" -S -c --arg declared "$declared" --arg namespace "$namespace" \
    --arg reason "$reason" --arg decision_role "$decision_role" '
    (if $decision_role == "operator" then
       .body.requested_by={role:"operator",implementation_id:"implementation.operator",
         implementation_version:"v1",adapter_instance_id:"instance.operator",
         principal_id:"principal.operator",execution_boundary_id:"boundary.operator"}
     else . end) |
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
    actor_json=$("$jq_bin" -S -c -n --arg role "$decision_role" \
      --slurpfile request "$dir/request.basis" --slurpfile resolved "$resolved" '
      if $role == "reviewer" then
        [$resolved[0].body.bindings[] | select(.binding.role == "reviewer")][0] as $entry |
        {role:$entry.binding.role,implementation_id:$entry.adapter_implementation.id,
         implementation_version:$entry.adapter_implementation.version,
         adapter_instance_id:$entry.binding.adapter_instance_id,
         principal_id:$entry.binding.principal_id,
         execution_boundary_id:$entry.binding.execution_boundary_id}
      elif $role == "operator" then $request[0].body.requested_by
      else
        {role:$role,implementation_id:("implementation."+$role),
         implementation_version:"v1",adapter_instance_id:("instance."+$role),
         principal_id:("principal."+$role),execution_boundary_id:("boundary."+$role)}
      end
    ')
    if [ "$mode" = actor-mismatch ]; then
      actor_json=$("$jq_bin" -S -c '.principal_id="principal.unbound"' <<<"$actor_json")
    fi
    decision_json=$("$jq_bin" -S -c -n --arg kind "$decision_kind" \
      --arg asserted "$asserted" --arg recorded_at "$decision_time" \
      --argjson actor "$actor_json" '
      {state:"present",value:{asserted_decision:$asserted,decision_kind:$kind,
        decided_by:$actor,
        recorded_at:$recorded_at}}
    ')
    if [ "$mode" = malformed-claim ]; then
      decision_json=$("$jq_bin" -S -c 'del(.value.decision_kind)' <<<"$decision_json")
    fi
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
  if [ "$mode" = malformed-classification ]; then
    "$jq_bin" -S -c 'del(.body.classification.tier)' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = tier-custom ]; then
    "$jq_bin" -S -c '.body.classification.tier="custom"' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = tier-empty ]; then
    "$jq_bin" -S -c '.body.classification.tier=""' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = tier-number ] || [ "$mode" = tier-number-forced ] ||
    [ "$mode" = tier-number-bootstrap ]; then
    "$jq_bin" -S -c '.body.classification.tier=1' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = tier-object ] || [ "$mode" = tier-object-forced ] ||
    [ "$mode" = tier-object-bootstrap ]; then
    "$jq_bin" -S -c '.body.classification.tier={value:"routine"}' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = tier-null ] || [ "$mode" = tier-null-forced ] ||
    [ "$mode" = tier-null-bootstrap ]; then
    "$jq_bin" -S -c '.body.classification.tier=null' "$dir/claim.json" \
      >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = decision-scalar ]; then
    "$jq_bin" -S -c '.body.decision=1' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = decision-array ]; then
    "$jq_bin" -S -c '.body.decision=[]' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = decision-null ]; then
    "$jq_bin" -S -c '.body.decision=null' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = value-scalar ]; then
    "$jq_bin" -S -c '.body.decision.value=1' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = value-array ]; then
    "$jq_bin" -S -c '.body.decision.value=[]' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  elif [ "$mode" = value-null ]; then
    "$jq_bin" -S -c '.body.decision.value=null' "$dir/claim.json" >"$dir/claim.changed"
    /bin/mv "$dir/claim.changed" "$dir/claim.json"
  fi
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
  if [ "${PURE_CASE_BUILD:-0}" = 1 ]; then
    /bin/cp "$tmp/routine/result.json" "$dir/result.json"
    /bin/cp "$tmp/routine/duty.json" "$dir/duty.json"
  else
    "$jq_bin" -L "$root/scripts/test" -S -c -n \
      --slurpfile request "$dir/request.json" --slurpfile resolved "$resolved" \
      --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
      import "portable-core-result-truth-fixtures" as result;
      result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
      walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
    ' >"$dir/result.json"
    if ! run_bounded 45 "$dir/duty.json" "$dir/duty.err" /usr/bin/env \
      "TMPDIR=$eval_tmp" "PATH=$bin:/usr/bin:/bin" \
      "$duty_evaluator" evaluate "$policy_set" \
      "$dir/request.json" "$resolved" "$dir/result.json"; then
      /bin/cat "$dir/duty.err" >&2
      fail "build duty $name"
    fi
  fi
}

build_pure_case() { PURE_CASE_BUILD=1 build_case "$@"; }

expect_eval() {
  local name=$1 verdict=$2 reason=$3
  local dir="$tmp/$name" out="$tmp/$name/risk.out"
  if ! run_bounded 45 "$out" "$dir/risk.err" /usr/bin/env \
    "TMPDIR=$eval_tmp" "PATH=$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
    "$dir/request.json" "$resolved" "$dir/result.json" "$dir/duty.json" \
    "$dir/claim.json"; then
      /bin/cat "$dir/risk.err" >&2
      fail "$name status"
  fi
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

expect_pure_eval() {
  local name=$1 verdict=$2 reason=$3 expected_minimum=${4:-}
  local dir="$tmp/$name" out="$tmp/$name/risk.out" request_basis
  local policy_set_digest request_digest result_digest duty_digest claim_digest
  local request_basis_digest policy_scope_digest requirement_scope_digest
  policy_set_digest=$(sha256_path "$policy_set")
  request_digest=$(sha256_path "$dir/request.json")
  result_digest=$(sha256_path "$dir/result.json")
  duty_digest=$(sha256_path "$dir/duty.json")
  claim_digest=$(sha256_path "$dir/claim.json")
  request_basis=$("$jq_bin" -S -c \
    '{schema_version,kind,id,body:(.body|del(.gate_decision_refs))}' \
    "$dir/request.json")
  request_basis_digest=$(sha256_text "$request_basis")
  policy_scope_digest=$("$jq_bin" -er '.body.risk.policy_ref.scope_sha256' \
    "$dir/request.json")
  requirement_scope_digest=$("$jq_bin" -er \
    '.body.risk.required_gate_refs[0].scope_sha256' "$dir/request.json")
  if ! run_bounded 15 "$out" "$dir/risk.err" "$jq_bin" -S -c -n \
    -f "$root/control/v1/risk-gates.jq" --slurpfile policy "$policy" \
    --slurpfile decision "$definition" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$dir/request.json" --slurpfile resolved "$resolved" \
    --slurpfile result "$dir/result.json" --slurpfile duty_evaluation "$dir/duty.json" \
    --slurpfile claim "$dir/claim.json" --arg policy_sha "$policy_sha" \
    --arg decision_sha "$definition_sha" --arg policy_set_sha "$policy_set_digest" \
    --arg request_sha "$request_digest" --arg resolved_sha "$resolved_sha" \
    --arg result_sha "$result_digest" --arg duty_sha "$duty_digest" \
    --arg claim_sha "$claim_digest" --arg request_basis_sha "$request_basis_digest" \
    --arg policy_scope_sha "$policy_scope_digest" \
    --arg requirement_scope_sha "$requirement_scope_digest"; then
    /bin/cat "$dir/risk.err" >&2
    fail "$name pure status"
  fi
  [ ! -s "$dir/risk.err" ] || fail "$name pure stderr"
  "$jq_bin" -e --arg verdict "$verdict" --arg reason "$reason" \
    --arg minimum "$expected_minimum" '
    .kind=="risk_gate_evaluation" and .body.activation_state=="inactive" and
    .body.authority_effect=="none" and .body.evaluation_mode=="observation-only" and
    .body.reference_semantics=="identity-only" and .body.verdict==$verdict and
    (.body.reason_ids|index($reason)!=null) and
    .body.reason_ids==(.body.reason_ids|sort|unique) and
    ($minimum=="" or .body.classification.minimum_tier==$minimum) and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
  ' "$out" >/dev/null || fail "$name pure verdict"
  "$jq_bin" -S -c . "$out" >"$dir/repeat"
  /usr/bin/cmp -s "$out" "$dir/repeat" || fail "$name pure canonical output"
  pass "$name"
}

expect_minimum() {
  local name=$1 expected=$2
  "$jq_bin" -e --arg expected "$expected" '
    .body.verdict=="violated" and .body.classification.minimum_tier==$expected
  ' "$tmp/$name/risk.out" >/dev/null || fail "$name normalized minimum"
}

expect_error() {
  local name=$1 expected=$2 runtime=${3:-$root}
  local dir="$tmp/$name" status=0
  run_bounded 45 "$dir/error.out" "$dir/error.err" /usr/bin/env \
    "TMPDIR=$eval_tmp" "PATH=$bin:/usr/bin:/bin" \
    "$runtime/control/v1/evaluate-risk-gates.sh" evaluate \
    "$policy_set" "$dir/request.json" "$resolved" "$dir/result.json" \
    "$dir/duty.json" "$dir/claim.json" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$dir/error.out" ] &&
    [ "$(/bin/cat "$dir/error.err")" = "$expected" ] || fail "$name error"
  pass "$name"
}

build_case routine routine routine present independent-plan-check reviewer accept \
  risk.routine
expect_eval routine inconclusive decision.provenance-unqualified

build_pure_case routine-escalated high routine present operator-plan-approval operator accept \
  risk.routine
expect_pure_eval routine-escalated inconclusive decision.provenance-unqualified

build_case high high high present operator-plan-approval operator accept \
  risk.security-control
expect_eval high inconclusive decision.provenance-unqualified

build_pure_case backdated-high high high present operator-plan-approval operator accept \
  risk.security-control normal core 2000-01-01T00:00:00Z
expect_pure_eval backdated-high inconclusive decision.provenance-unqualified

build_case bootstrap bootstrap bootstrap present operator-bootstrap-approval operator accept \
  risk.bootstrap bootstrap
expect_eval bootstrap inconclusive decision.provenance-unqualified

build_pure_case missing high high absent ignored operator accept risk.security-control
expect_pure_eval missing violated decision.missing

build_case rejected high high present operator-plan-approval operator reject \
  risk.security-control
expect_eval rejected violated decision.rejected

build_pure_case downgrade routine high present independent-plan-check reviewer accept \
  risk.security-control
expect_pure_eval downgrade violated risk.tier-downgrade

build_pure_case invented-role high high present operator-plan-approval reviewer accept \
  risk.security-control
expect_pure_eval invented-role violated decision.role-denied

build_pure_case unbound-actor routine routine present independent-plan-check reviewer accept \
  risk.routine actor-mismatch
expect_pure_eval unbound-actor violated decision.actor-unbound

build_pure_case invented-kind high high present independent-plan-check operator accept \
  risk.security-control
expect_pure_eval invented-kind violated decision.kind-denied

build_pure_case malformed-claim routine routine present independent-plan-check reviewer accept \
  risk.routine malformed-claim
expect_pure_eval malformed-claim violated decision.claim-malformed

build_pure_case decision-scalar routine routine present independent-plan-check reviewer accept \
  risk.routine decision-scalar
expect_pure_eval decision-scalar violated decision.claim-malformed

build_pure_case decision-array routine routine present independent-plan-check reviewer accept \
  risk.routine decision-array
expect_pure_eval decision-array violated decision.claim-malformed

build_pure_case decision-null routine routine present independent-plan-check reviewer accept \
  risk.routine decision-null
expect_pure_eval decision-null violated decision.claim-malformed

build_pure_case value-scalar routine routine present independent-plan-check reviewer accept \
  risk.routine value-scalar
expect_pure_eval value-scalar violated decision.claim-malformed

build_pure_case value-array routine routine present independent-plan-check reviewer accept \
  risk.routine value-array
expect_pure_eval value-array violated decision.claim-malformed

build_pure_case value-null routine routine present independent-plan-check reviewer accept \
  risk.routine value-null
expect_pure_eval value-null violated decision.claim-malformed

build_pure_case malformed-classification routine routine present independent-plan-check reviewer \
  accept risk.routine malformed-classification
expect_pure_eval malformed-classification violated decision.claim-malformed unknown
expect_minimum malformed-classification unknown

build_pure_case tier-wrong-string routine routine present independent-plan-check reviewer accept \
  risk.routine tier-custom
expect_pure_eval tier-wrong-string violated decision.claim-malformed unknown
expect_minimum tier-wrong-string unknown

build_pure_case tier-empty routine routine present independent-plan-check reviewer accept \
  risk.routine tier-empty
expect_pure_eval tier-empty violated decision.claim-malformed unknown
expect_minimum tier-empty unknown

build_pure_case tier-number routine routine present independent-plan-check reviewer accept \
  risk.routine tier-number
expect_pure_eval tier-number violated decision.claim-malformed unknown
expect_minimum tier-number unknown

build_pure_case tier-object routine routine present independent-plan-check reviewer accept \
  risk.routine tier-object
expect_pure_eval tier-object violated decision.claim-malformed unknown
expect_minimum tier-object unknown

build_pure_case tier-null routine routine present independent-plan-check reviewer accept \
  risk.routine tier-null
expect_pure_eval tier-null violated decision.claim-malformed unknown
expect_minimum tier-null unknown

build_pure_case forced-high-number high high present operator-plan-approval operator accept \
  risk.security-control tier-number-forced
expect_pure_eval forced-high-number violated decision.claim-malformed unknown
expect_minimum forced-high-number unknown

build_pure_case forced-high-object high high present operator-plan-approval operator accept \
  risk.security-control tier-object-forced
expect_pure_eval forced-high-object violated decision.claim-malformed unknown
expect_minimum forced-high-object unknown

build_pure_case forced-high-null high high present operator-plan-approval operator accept \
  risk.security-control tier-null-forced
expect_pure_eval forced-high-null violated decision.claim-malformed unknown
expect_minimum forced-high-null unknown

build_pure_case bootstrap-number bootstrap bootstrap present operator-bootstrap-approval operator \
  accept risk.bootstrap tier-number-bootstrap
expect_pure_eval bootstrap-number violated decision.claim-malformed unknown
expect_minimum bootstrap-number unknown

build_pure_case bootstrap-object bootstrap bootstrap present operator-bootstrap-approval operator \
  accept risk.bootstrap tier-object-bootstrap
expect_pure_eval bootstrap-object violated decision.claim-malformed unknown
expect_minimum bootstrap-object unknown

build_pure_case bootstrap-null bootstrap bootstrap present operator-bootstrap-approval operator \
  accept risk.bootstrap tier-null-bootstrap
expect_pure_eval bootstrap-null violated decision.claim-malformed unknown
expect_minimum bootstrap-null unknown

build_pure_case malformed-time routine routine present independent-plan-check reviewer accept \
  risk.routine normal core 2026-99-99T99:99:99Z
expect_pure_eval malformed-time violated decision.claim-malformed

build_pure_case after-request routine routine present independent-plan-check reviewer accept \
  risk.routine normal core 2026-09-01T00:00:01Z
expect_pure_eval after-request violated decision.after-request

build_pure_case stale routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.request_basis_sha256=("0"*64)' "$tmp/stale/claim.json" \
  >"$tmp/stale/claim.changed"
/bin/mv "$tmp/stale/claim.changed" "$tmp/stale/claim.json"
expect_pure_eval stale violated decision.stale

build_pure_case unbound routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.gate_decision_refs[0].decision_record_ref.sha256=("0"*64)' \
  "$tmp/unbound/request.json" >"$tmp/unbound/request.changed"
/bin/mv "$tmp/unbound/request.changed" "$tmp/unbound/request.json"
expect_pure_eval unbound violated decision.unbound

build_pure_case ambiguous routine routine present independent-plan-check reviewer accept risk.routine
"$jq_bin" -S -c '.body.gate_decision_refs += [{purpose:"gate-decision",
  decision_record_ref:{content_id:"risk.claim.other",
    media_type:"application/vnd.ystack.risk-gate-decision-claim+json",sha256:("1"*64)},
  subject_ref:{type:"artifact",value:.body.source.value},scope_sha256:("0"*64)}] |
  .body.gate_decision_refs |= sort_by(.scope_sha256)' "$tmp/ambiguous/request.json" \
  >"$tmp/ambiguous/request.changed"
/bin/mv "$tmp/ambiguous/request.changed" "$tmp/ambiguous/request.json"
expect_pure_eval ambiguous violated decision.ambiguous

build_pure_case unsupported custom routine present independent-plan-check reviewer accept \
  risk.routine normal example.test
expect_pure_eval unsupported violated risk.tier-unsupported unknown
expect_minimum unsupported unknown

build_pure_case unsupported-foreign-high high high present operator-plan-approval operator accept \
  risk.security-control normal example.test
expect_pure_eval unsupported-foreign-high violated risk.tier-unsupported unknown
expect_minimum unsupported-foreign-high unknown

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
run_bounded 10 "$tmp/link.out" "$tmp/link.err" /usr/bin/env \
  "TMPDIR=$eval_tmp" "PATH=$bin:/usr/bin:/bin" \
  "$evaluator" evaluate "$policy_set" "$link" "$resolved" \
  "$tmp/routine/result.json" "$tmp/routine/duty.json" "$tmp/routine/claim.json" ||
  status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/link.out" ] &&
  [ "$(/bin/cat "$tmp/link.err")" = E_RUNTIME ] || fail 'symlink input rejection'
pass 'symlink input rejection'

relative_bin="$tmp/relative-bin"
/bin/mkdir "$relative_bin"
/bin/cp "$jq_bin" "$relative_bin/jq"
status=0
run_bounded 10 "$tmp/relative.out" "$tmp/relative.err" /usr/bin/env \
  "TMPDIR=$eval_tmp" /bin/bash -c '
  cd "$1" && PATH=".:/usr/bin:/bin" exec "$2" evaluate "$3" "$4" "$5" "$6" "$7" "$8"
' _ "$relative_bin" "$evaluator" "$policy_set" "$tmp/routine/request.json" \
  "$resolved" "$tmp/routine/result.json" "$tmp/routine/duty.json" \
  "$tmp/routine/claim.json" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/relative.out" ] &&
  [ "$(/bin/cat "$tmp/relative.err")" = E_RUNTIME ] || fail 'relative jq rejection'
pass 'relative jq rejection'

strict_bin="$tmp/strict-empty-input-bin"
/bin/mkdir "$strict_bin"
/usr/bin/printf '%s\n' '#!/bin/bash' "real_jq='$jq_bin'" \
  'if [ "${1:-}" = --version ]; then exec "$real_jq" "$@"; fi' \
  'has_definition=0' \
  'has_null_input=0' \
  'for arg in "$@"; do' \
  '  [ "$arg" = definition ] && has_definition=1' \
  '  [ "$arg" = -n ] && has_null_input=1' \
  'done' \
  'if [ "$has_definition" -eq 1 ] && [ "$has_null_input" -ne 1 ]; then exit 4; fi' \
  'exec "$real_jq" "$@"' >"$strict_bin/jq"
/bin/chmod 0555 "$strict_bin/jq"
if ! run_bounded 45 "$tmp/strict.out" "$tmp/strict.err" /usr/bin/env \
  "TMPDIR=$eval_tmp" "PATH=$strict_bin:/usr/bin:/bin" \
  "$evaluator" evaluate "$policy_set" \
  "$tmp/routine/request.json" "$resolved" "$tmp/routine/result.json" \
  "$tmp/routine/duty.json" "$tmp/routine/claim.json"; then
    /bin/cat "$tmp/strict.err" >&2
    fail 'strict empty-input jq status'
fi
[ ! -s "$tmp/strict.err" ] || fail 'strict empty-input jq stderr'
"$jq_bin" -e '.body.verdict=="inconclusive" and
  .body.reason_ids==["decision.provenance-unqualified"]' "$tmp/strict.out" \
  >/dev/null || fail 'strict empty-input jq result'
pass 'risk definition check uses explicit null input on strict jq'

timeout_helper="$tmp/timeout-helper.sh"
timeout_scratch="$tmp/forced-timeout-scratch"
timeout_child_file="$tmp/forced-timeout-child"
/usr/bin/printf '%s\n' '#!/bin/bash' \
  'scratch=$1' \
  'child_file=$2' \
  '/bin/mkdir -p "$scratch"' \
  '/bin/bash -c '\''trap "" TERM; /bin/sleep 30'\'' &' \
  'child=$!' \
  '/usr/bin/printf "%s\n" "$child" >"$child_file"' \
  'trap '\''/bin/rm -rf -- "$scratch"; exit 143'\'' TERM' \
  'wait "$child"' >"$timeout_helper"
/bin/chmod 0555 "$timeout_helper"
timeout_status=0
run_bounded 1 "$tmp/timeout.out" "$tmp/timeout.err" "$timeout_helper" \
  "$timeout_scratch" "$timeout_child_file" || timeout_status=$?
[ "$timeout_status" -eq 124 ] && [ -s "$timeout_child_file" ] &&
  [ ! -e "$timeout_scratch" ] && [ -z "$ACTIVE_EVAL_PID" ] &&
  [ -z "$ACTIVE_EVAL_PGID" ] || fail 'forced timeout cleanup state'
timeout_child=$(/bin/cat "$timeout_child_file")
if [[ ! "$timeout_child" =~ ^[1-9][0-9]*$ ]] ||
   kill -0 "$timeout_child" 2>/dev/null; then
  fail 'forced timeout nested survivor'
fi
pass 'forced timeout reaps nested process group and scratch'

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
expect_error dependency-binding E_RELATION "$dependency_runtime"

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
start_group "$tmp/race.out" "$tmp/race.err" /usr/bin/env \
  "TMPDIR=$race_scratch" "RISK_TRIGGER=$race_trigger" \
  "PATH=$race_bin:/usr/bin:/bin" \
  "$race_runtime/control/v1/evaluate-risk-gates.sh" evaluate "$policy_set" \
  "$tmp/routine/request.json" "$resolved" "$tmp/routine/result.json" \
  "$tmp/routine/duty.json" "$tmp/routine/claim.json" || fail 'risk race launch'
attempt=0
while [ ! -e "$race_trigger" ] && group_alive "$ACTIVE_EVAL_PGID" &&
  [ "$attempt" -lt 400 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$race_trigger" ]; then
  terminate_active || :
  fail 'risk program race marker'
fi
/usr/bin/printf '\n' >>"$race_runtime/control/v1/risk-gates.jq"
race_status=0
wait_group 45 || race_status=$?
[ "$race_status" -ne 0 ] && [ ! -s "$tmp/race.out" ] &&
  [ "$(/bin/cat "$tmp/race.err")" = E_RELATION ] || fail 'risk program TOCTOU'
pass 'risk program TOCTOU closes after mirrored execution'

[ -z "$ACTIVE_EVAL_PID" ] && [ -z "$ACTIVE_EVAL_PGID" ] &&
  [ -z "$(/usr/bin/find "$eval_tmp" -mindepth 1 -print -quit)" ] &&
  [ -z "$(/usr/bin/find "$race_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'evaluator process or scratch cleanup'
pass 'all evaluator groups and scratch are gone'

while IFS= read -r risk_output; do
  "$jq_bin" -e '.body.verdict != "satisfied" and
    (.body.reason_ids | index("risk-gates.satisfied") == null)' "$risk_output" \
    >/dev/null || fail "caller-synthesized satisfied ${risk_output##*/}"
done < <(/usr/bin/find "$tmp" -type f \( -name risk.out -o -name pure.out \) -print)
pass 'no caller-authored claim can synthesize satisfied'

/usr/bin/printf 'control risk gates: %s passed\n' "$passes"
