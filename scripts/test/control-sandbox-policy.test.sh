#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-sandbox.sh"
policy="$root/control/v1/sandbox-policy.json"
decision="$root/control/v1/sandbox-decision.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-sandbox-policy-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

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

policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg sandbox_policy "$policy_sha" \
  --arg sandbox_decision "$decision_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy_sha;$decision_sha):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;
       "application/vnd.ystack.control-policy+json";$policy_sha),
     decision_ref:ref("control-decision."+$id;
       "application/vnd.ystack.control-decision+json";$decision_sha)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.sandbox-test",
   body:{activation_state:"inactive",core_contract:{generation_id:("g-"+("7"*64)),
     package_ref:ref("core-contract-package.v2";
       "application/vnd.ystack.core-contract+json";("9"*64)),
     semantic_identity:"core.contracts.v2"},fail_mode:"closed",policy_version:"v1",
     sections:[section("credential-policy";("1"*64);("a"*64)),
       section("duty-separation";("2"*64);("b"*64)),
       section("evidence-integrity";("3"*64);("c"*64)),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";("5"*64);("e"*64)),
       section("sandbox";$sandbox_policy;$sandbox_decision)]}}
' >"$policy_set"
policy_set_sha=$(sha256_path "$policy_set")

duty="$tmp/duty.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --slurpfile set "$policy_set" '
  def content($id;$sha):
    {content_id:$id,media_type:"application/vnd.ystack.control-decision+json",sha256:$sha};
  def document($kind;$id;$sha): {schema_version:1,kind:$kind,id:$id,sha256:$sha};
  {schema_version:1,kind:"duty_separation_evaluation",id:"result.sandbox-test",
   body:{activation_state:"inactive",core_contract:$set[0].body.core_contract,
     decision_ref:content("control-decision.duty-separation";("b"*64)),
     evaluation_mode:"observation-only",
     policy_ref:(content("control-policy.duty-separation";("2"*64)) |
       .media_type="application/vnd.ystack.control-policy+json"),
     policy_set:{id:"control-policy-set.sandbox-test",sha256:$set_sha},
     reason_ids:["duty.satisfied"],reference_semantics:"identity-only",
     stage:{request_ref:(document("stage_request";"request.sandbox-test";("3"*64)) |
         .schema_version=2),
       resolved_profile_ref:(document("resolved_profile";"profile.sandbox-test";("4"*64)) |
         .schema_version=2),
       result_ref:(document("stage_result";"result.sandbox-test";("5"*64)) |
         .schema_version=2)},
     verdict:"satisfied"}}
' >"$duty"
duty_sha=$(sha256_path "$duty")

claim="$tmp/claim.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" --arg duty_sha "$duty_sha" \
  --slurpfile policy "$policy" '
  def document($version;$kind;$id;$sha):
    {schema_version:$version,kind:$kind,id:$id,sha256:$sha};
  {schema_version:1,kind:"execution_environment_claim",id:"sandbox-claim.example",
   body:{declaration_status:"complete",
     duty_evaluation_ref:document(1;"duty_separation_evaluation";"result.sandbox-test";$duty_sha),
     effects:{external_writes:false,target_writes:false},environment:$policy[0].body.environment,
     execution_identity:{adapter_instance_id:"instance.verifier",
       execution_boundary_id:"boundary.verifier",principal_id:"principal.verifier",role:"verifier"},
     filesystem:$policy[0].body.filesystem,isolation:$policy[0].body.isolation,
     limits:$policy[0].body.limits,network:$policy[0].body.network,
     policy_set_ref:document(1;"control_policy_set";"control-policy-set.sandbox-test";$set_sha),
     resources:$policy[0].body.resources,sensitive_material:$policy[0].body.sensitive_material,
     stage_result_ref:document(2;"stage_result";"result.sandbox-test";("5"*64)),
     tools:$policy[0].body.tools}}
' >"$claim"

run_evaluator() {
  local active_evaluator=$1 set_input=$2 duty_input=$3 claim_input=$4 out=$5 err=$6 status=0
  PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 \
    "$active_evaluator" evaluate "$set_input" "$duty_input" "$claim_input" \
    >"$out" 2>"$err" || status=$?
  RUN_STATUS=$status
}
expect_error() {
  local name=$1 expected=$2 active_evaluator=$3 set_input=$4 duty_input=$5 claim_input=$6
  local out err
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  run_evaluator "$active_evaluator" "$set_input" "$duty_input" "$claim_input" "$out" "$err"
  if [ "$RUN_STATUS" -eq 0 ] || [ -s "$out" ] ||
     [ "$(/bin/cat "$err")" != "$expected" ] ||
     /usr/bin/grep -Fq "$tmp" "$err"; then
    fail "$name"
  fi
  pass "$name"
}
expect_verdict() {
  local name=$1 expected=$2 set_input=$3 duty_input=$4 claim_input=$5 reason=${6:-}
  local out err
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  run_evaluator "$evaluator" "$set_input" "$duty_input" "$claim_input" "$out" "$err"
  if [ "$RUN_STATUS" -ne 0 ] || [ -s "$err" ] ||
     ! "$jq_bin" -e --arg verdict "$expected" '.body.verdict==$verdict' "$out" >/dev/null ||
     ! /usr/bin/cmp -s "$out" <("$jq_bin" -S -c . "$out"); then
    fail "$name"
  fi
  if [ -n "$reason" ]; then
    "$jq_bin" -e --arg reason "$reason" '.body.reason_ids|index($reason)!=null' "$out" \
      >/dev/null || fail "$name reason"
  fi
  VERDICT_OUTPUT=$out
  pass "$name"
}
mutate() {
  local source=$1 name=$2 filter=$3 target
  target="$tmp/$name.json"
  "$jq_bin" -S -c "$filter" "$source" >"$target"
  /usr/bin/printf '%s\n' "$target"
}
expect_duty_binding_error() {
  local name=$1 filter=$2 moved_duty moved_duty_sha moved_claim
  moved_duty="$tmp/$name-duty.json"
  moved_claim="$tmp/$name-claim.json"
  "$jq_bin" -S -c "$filter" "$duty" >"$moved_duty"
  moved_duty_sha=$(sha256_path "$moved_duty")
  "$jq_bin" -S -c --arg sha "$moved_duty_sha" \
    '.body.duty_evaluation_ref.sha256=$sha' "$claim" >"$moved_claim"
  expect_error "$name" E_RELATION "$evaluator" "$policy_set" "$moved_duty" "$moved_claim"
}

expect_verdict canonical-satisfied satisfied "$policy_set" "$duty" "$claim" \
  sandbox.declaration-satisfied
"$jq_bin" -e '
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.enforcement_proof=="declaration-only" and .body.evaluation_mode=="observation-only" and
  .body.qualification_effect=="none"
' "$VERDICT_OUTPUT" >/dev/null || fail 'inactive claim-only output'
pass 'output grants and activates nothing'

expect_verdict incomplete inconclusive "$policy_set" "$duty" \
  "$(mutate "$claim" incomplete '.body.declaration_status="incomplete"')" declaration.incomplete
expect_verdict network-unknown inconclusive "$policy_set" "$duty" \
  "$(mutate "$claim" network-unknown '.body.network.mode="unknown"')" network.unknown
expect_verdict isolation-unknown inconclusive "$policy_set" "$duty" \
  "$(mutate "$claim" isolation-unknown '.body.isolation.host_access="unknown"')" isolation.unknown
expect_error tool-network-unknown E_RELATION "$evaluator" "$policy_set" "$duty" \
  "$(mutate "$claim" tool-network-unknown '.body.tools[0].network="unknown"')"
expect_verdict sensitive-unknown inconclusive "$policy_set" "$duty" \
  "$(mutate "$claim" sensitive-unknown '.body.sensitive_material.exposure="unknown"')" \
  sensitive-material.unknown
expect_verdict effects-unknown inconclusive "$policy_set" "$duty" \
  "$(mutate "$claim" effects-unknown '.body.effects.external_writes="unknown"')" effects.unknown
duty_inconclusive=$(mutate "$duty" duty-inconclusive \
  '.body.verdict="inconclusive"|.body.reason_ids=["actual.capability-unclassified"]')
duty_inconclusive_sha=$(sha256_path "$duty_inconclusive")
duty_inconclusive_claim="$tmp/duty-inconclusive-claim.json"
"$jq_bin" -S -c --arg duty_sha "$duty_inconclusive_sha" \
  '.body.duty_evaluation_ref.sha256=$duty_sha' "$claim" >"$duty_inconclusive_claim"
expect_verdict duty-inconclusive inconclusive "$policy_set" "$duty_inconclusive" \
  "$duty_inconclusive_claim" duty.inconclusive

expect_duty_binding_error duty-policy-set-sha \
  '.body.policy_set.sha256=("0"*64)'
expect_duty_binding_error duty-policy-set-id \
  '.body.policy_set.id="control-policy-set.forged"'
expect_duty_binding_error duty-policy-ref \
  '.body.policy_ref.sha256=("0"*64)'
expect_duty_binding_error duty-decision-ref \
  '.body.decision_ref.sha256=("0"*64)'
expect_duty_binding_error duty-core-contract \
  '.body.core_contract.semantic_identity="core.contracts.v1"'
expect_duty_binding_error duty-result-id \
  '.id="result.forged"'
expect_duty_binding_error duty-result-kind \
  '.body.stage.result_ref.kind="stage_request"'
expect_duty_binding_error duty-duplicate-reasons \
  '.body.reason_ids=["duty.satisfied","duty.satisfied"]'
expect_duty_binding_error duty-verdict-reason \
  '.body.reason_ids=["duty.forged"]'

expect_verdict role-denied violated "$policy_set" "$duty" \
  "$(mutate "$claim" role-denied '.body.execution_identity.role="producer"')" identity.role-denied
expect_verdict network-allow violated "$policy_set" "$duty" \
  "$(mutate "$claim" network-allow '.body.network.mode="allow"')" network.not-denied
expect_verdict network-endpoint violated "$policy_set" "$duty" \
  "$(mutate "$claim" network-endpoint '.body.network.endpoints=["https://example.invalid"]')" \
  network.not-denied
expect_verdict environment-inherit violated "$policy_set" "$duty" \
  "$(mutate "$claim" environment-inherit '.body.environment.mode="inherit"')" \
  environment.not-cleared
expect_verdict environment-secret violated "$policy_set" "$duty" \
  "$(mutate "$claim" environment-secret \
    '.body.environment.variables += [{name:"API_TOKEN",value:"secret-value"}]')" \
  environment.sensitive-material
expect_verdict environment-url violated "$policy_set" "$duty" \
  "$(mutate "$claim" environment-url '.body.environment.variables[0].value="https://example.invalid"')" \
  environment.external-url
expect_verdict write-root-target violated "$policy_set" "$duty" \
  "$(mutate "$claim" write-root-target '.body.filesystem.write_roots[0].path="/sandbox/target"')" \
  filesystem.write-roots-denied
expect_verdict argv-wildcard violated "$policy_set" "$duty" \
  "$(mutate "$claim" argv-wildcard '.body.tools[0].argv += ["*"]')" tools.not-fixed
expect_verdict argv-url violated "$policy_set" "$duty" \
  "$(mutate "$claim" argv-url '.body.tools[0].argv += ["https://example.invalid"]')" \
  tools.external-url
expect_verdict credential-ref violated "$policy_set" "$duty" \
  "$(mutate "$claim" credential-ref '.body.sensitive_material.credential_refs=["credential.target"]')" \
  sensitive-material.exposed
expect_verdict tool-network violated "$policy_set" "$duty" \
  "$(mutate "$claim" tool-network '.body.tools[0].network=true')" tools.network-requested
expect_verdict target-write violated "$policy_set" "$duty" \
  "$(mutate "$claim" target-write '.body.effects.target_writes=true')" effects.target-write
expect_verdict external-write violated "$policy_set" "$duty" \
  "$(mutate "$claim" external-write '.body.effects.external_writes=true')" effects.external-write
expect_verdict limit-move violated "$policy_set" "$duty" \
  "$(mutate "$claim" limit-move '.body.limits.wall_time_ms=60001')" limits.not-fixed
expect_verdict stale-policy-set-ref violated "$policy_set" "$duty" \
  "$(mutate "$claim" stale-policy-set-ref '.body.policy_set_ref.sha256=("0"*64)')" \
  policy-set.reference-mismatch
expect_verdict stale-duty-ref violated "$policy_set" "$duty" \
  "$(mutate "$claim" stale-duty-ref '.body.duty_evaluation_ref.sha256=("0"*64)')" \
  duty.reference-mismatch
expect_verdict stale-stage-result violated "$policy_set" "$duty" \
  "$(mutate "$claim" stale-stage-result '.body.stage_result_ref.sha256=("0"*64)')" \
  duty.stage-result-mismatch

expect_error unknown-field E_RELATION "$evaluator" "$policy_set" "$duty" \
  "$(mutate "$claim" unknown-field '.body.untrusted="value"')"
expect_error wildcard-path E_RELATION "$evaluator" "$policy_set" "$duty" \
  "$(mutate "$claim" wildcard-path '.body.filesystem.write_roots[0].path="/sandbox/*"')"
expect_error traversal-path E_RELATION "$evaluator" "$policy_set" "$duty" \
  "$(mutate "$claim" traversal-path '.body.filesystem.write_roots[0].path="/sandbox/../target"')"
"$jq_bin" -S -c -n 'reduce range(0;33) as $index (0;{value:.})' >"$tmp/depth-limit.json"
expect_error depth-limit E_LIMIT "$evaluator" "$policy_set" "$duty" "$tmp/depth-limit.json"
expect_error stale-sandbox-policy-binding E_RELATION "$evaluator" \
  "$(mutate "$policy_set" stale-sandbox-policy-binding \
    '.body.sections[5].policy_ref.sha256=("0"*64)')" "$duty" "$claim"

copy_root="$tmp/copied"
/bin/mkdir -p "$copy_root/control/v1"
for path in evaluate-sandbox.sh sandbox-policy.json sandbox-decision.json sandbox.jq \
  validate.sh policy-set.jq; do
  /bin/cp "$root/control/v1/$path" "$copy_root/control/v1/$path"
done
/bin/chmod 0755 "$copy_root/control/v1/evaluate-sandbox.sh" "$copy_root/control/v1/validate.sh"
stale_program_root="$tmp/stale-program"
/bin/cp -R "$copy_root" "$stale_program_root"
/usr/bin/printf '\n' >>"$stale_program_root/control/v1/sandbox.jq"
expect_error stale-evaluator-program E_RELATION \
  "$stale_program_root/control/v1/evaluate-sandbox.sh" "$policy_set" "$duty" "$claim"

relative="$tmp/relative"
/bin/mkdir -m 700 "$relative"
/usr/bin/printf '%s\n' '#!/bin/sh' \
  ': > "${YSTACK_FAKE_JQ_SENTINEL:?}"' \
  'if [ "${1:-}" = --version ]; then printf "%s\n" jq-1.6; exit 0; fi' 'exit 1' \
  >"$relative/jq"
/usr/bin/printf '%s\n' '#!/bin/sh' ': > "${YSTACK_FAKE_BASH_SENTINEL:?}"' 'exit 1' \
  >"$relative/bash"
/bin/chmod 0700 "$relative/jq" "$relative/bash"
fake_jq_sentinel="$tmp/fake-jq-ran"
fake_bash_sentinel="$tmp/fake-bash-ran"
interpreter_out="$tmp/interpreter.out"
interpreter_err="$tmp/interpreter.err"
interpreter_status=0
(cd "$relative" && YSTACK_FAKE_JQ_SENTINEL="$fake_jq_sentinel" \
  YSTACK_FAKE_BASH_SENTINEL="$fake_bash_sentinel" PATH=".:$bin:/usr/bin:/bin" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 "$evaluator" evaluate \
    "$policy_set" "$duty" "$claim" >"$interpreter_out" 2>"$interpreter_err") ||
  interpreter_status=$?
[ "$interpreter_status" -ne 0 ] && [ ! -s "$interpreter_out" ] &&
  [ "$(/bin/cat "$interpreter_err")" = E_RUNTIME ] &&
  [ ! -e "$fake_jq_sentinel" ] && [ ! -e "$fake_bash_sentinel" ] ||
  fail 'relative interpreter path'
pass 'relative interpreter paths cannot run'

absolute_fake="$tmp/absolute-fake"
/bin/mkdir -m 700 "$absolute_fake"
/bin/cp "$relative/jq" "$absolute_fake/jq"
/bin/chmod 0700 "$absolute_fake/jq"
absolute_out="$tmp/absolute.out"
absolute_err="$tmp/absolute.err"
absolute_status=0
YSTACK_FAKE_JQ_SENTINEL="$fake_jq_sentinel" PATH="$absolute_fake:$bin:/usr/bin:/bin" \
  /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 "$evaluator" evaluate \
    "$policy_set" "$duty" "$claim" >"$absolute_out" 2>"$absolute_err" ||
  absolute_status=$?
[ "$absolute_status" -ne 0 ] && [ ! -s "$absolute_out" ] &&
  [ "$(/bin/cat "$absolute_err")" = E_RUNTIME ] && [ ! -e "$fake_jq_sentinel" ] ||
  fail 'untrusted absolute jq identity'
pass 'jq version spoof cannot replace the fixed interpreter'

jq_race_root="$tmp/jq-race"
/bin/cp -R "$copy_root" "$jq_race_root"
jq_before="$tmp/jq-race.before"
jq_call="$tmp/jq-race.call"
jq_after="$tmp/jq-race.after"
jq_finish="$tmp/jq-race.finish"
/usr/bin/printf '%s\n' '#!/bin/bash' 'set -uo pipefail' \
  "/usr/bin/printf '%s\\n' ready >'$jq_before'" \
  "count=0; while [ ! -e '$jq_call' ] && [ \"\$count\" -lt 500 ]; do count=\$((count+1)); /bin/sleep 0.01; done" \
  "[ -e '$jq_call' ] || exit 1" \
  '[ "$(jq --version 2>/dev/null)" = jq-1.6 ] || exit 1' \
  "/usr/bin/printf '%s\\n' used >'$jq_after'" \
  "count=0; while [ ! -e '$jq_finish' ] && [ \"\$count\" -lt 500 ]; do count=\$((count+1)); /bin/sleep 0.01; done" \
  "[ -e '$jq_finish' ] || exit 1" 'exit 0' >"$jq_race_root/control/v1/validate.sh"
/bin/chmod 0755 "$jq_race_root/control/v1/validate.sh"
jq_race_validator_sha=$(sha256_path "$jq_race_root/control/v1/validate.sh")
"$jq_bin" -S -c --arg sha "$jq_race_validator_sha" \
  '.body.evaluator.policy_set_validator.driver_ref.sha256=$sha' \
  "$jq_race_root/control/v1/sandbox-decision.json" >"$tmp/jq-race-decision.json"
/bin/mv "$tmp/jq-race-decision.json" "$jq_race_root/control/v1/sandbox-decision.json"
jq_race_decision_sha=$(sha256_path "$jq_race_root/control/v1/sandbox-decision.json")
jq_race_set="$tmp/jq-race-set.json"
"$jq_bin" -S -c --arg sha "$jq_race_decision_sha" \
  '.body.sections[5].decision_ref.sha256=$sha' "$policy_set" >"$jq_race_set"
jq_race_set_sha=$(sha256_path "$jq_race_set")
jq_race_duty="$tmp/jq-race-duty.json"
"$jq_bin" -S -c --arg sha "$jq_race_set_sha" \
  '.body.policy_set.sha256=$sha' "$duty" >"$jq_race_duty"
jq_race_duty_sha=$(sha256_path "$jq_race_duty")
jq_race_claim="$tmp/jq-race-claim.json"
"$jq_bin" -S -c --arg set_sha "$jq_race_set_sha" --arg duty_sha "$jq_race_duty_sha" \
  '.body.policy_set_ref.sha256=$set_sha|.body.duty_evaluation_ref.sha256=$duty_sha' \
  "$claim" >"$jq_race_claim"
jq_race_out="$tmp/jq-race.out"
jq_race_err="$tmp/jq-race.err"
jq_attack_sentinel="$tmp/jq-attack-ran"
PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 \
  "$jq_race_root/control/v1/evaluate-sandbox.sh" evaluate \
  "$jq_race_set" "$jq_race_duty" "$jq_race_claim" \
  >"$jq_race_out" 2>"$jq_race_err" &
jq_race_pid=$!
attempt=0
while [ ! -e "$jq_before" ] && kill -0 "$jq_race_pid" 2>/dev/null &&
      [ "$attempt" -lt 500 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$jq_before" ]; then
  : >"$jq_call"
  : >"$jq_finish"
  kill "$jq_race_pid" 2>/dev/null || :
  wait "$jq_race_pid" 2>/dev/null || :
  fail 'live jq replacement marker timeout'
fi
jq_original="$tmp/jq-original"
/bin/mv "$bin/jq" "$jq_original"
/usr/bin/printf '%s\n' '#!/bin/sh' ": > '$jq_attack_sentinel'" \
  'printf "%s\n" "{\"kind\":\"fabricated\"}"' 'exit 0' >"$bin/jq"
/bin/chmod 0700 "$bin/jq"
: >"$jq_call"
attempt=0
while [ ! -e "$jq_after" ] && kill -0 "$jq_race_pid" 2>/dev/null &&
      [ "$attempt" -lt 500 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$jq_after" ]; then
  /bin/mv "$bin/jq" "$tmp/jq-attacker"
  /bin/mv "$jq_original" "$bin/jq"
  : >"$jq_finish"
  kill "$jq_race_pid" 2>/dev/null || :
  wait "$jq_race_pid" 2>/dev/null || :
  fail 'private jq validator marker timeout'
fi
[ ! -e "$jq_attack_sentinel" ] || fail 'caller jq ran during validator'
/bin/mv "$bin/jq" "$tmp/jq-attacker"
/bin/mv "$jq_original" "$bin/jq"
: >"$jq_finish"
jq_race_status=0
wait "$jq_race_pid" || jq_race_status=$?
if [ "$jq_race_status" -ne 0 ] || [ -s "$jq_race_err" ] ||
   [ -e "$jq_attack_sentinel" ] ||
   ! "$jq_bin" -e '.kind=="sandbox_policy_evaluation" and .body.verdict=="satisfied" and
     .body.authority_effect=="none" and .body.qualification_effect=="none"' \
     "$jq_race_out" >/dev/null; then
  fail 'private jq replacement result'
fi
pass 'post-check caller jq replacement cannot execute or fabricate output'

race_root="$tmp/race"
/bin/cp -R "$copy_root" "$race_root"
marker="$tmp/validator.marker"
release="$tmp/validator.release"
/usr/bin/printf '%s\n' '#!/bin/bash' 'set -uo pipefail' \
  "/usr/bin/printf '%s\\n' ready >'$marker'" \
  "count=0; while [ ! -e '$release' ] && [ \"\$count\" -lt 500 ]; do count=\$((count+1)); /bin/sleep 0.01; done" \
  "[ -e '$release' ] || exit 1" 'exit 0' >"$race_root/control/v1/validate.sh"
/bin/chmod 0755 "$race_root/control/v1/validate.sh"
race_validator_sha=$(sha256_path "$race_root/control/v1/validate.sh")
"$jq_bin" -S -c --arg sha "$race_validator_sha" \
  '.body.evaluator.policy_set_validator.driver_ref.sha256=$sha' \
  "$race_root/control/v1/sandbox-decision.json" >"$tmp/race-decision.json"
/bin/mv "$tmp/race-decision.json" "$race_root/control/v1/sandbox-decision.json"
race_decision_sha=$(sha256_path "$race_root/control/v1/sandbox-decision.json")
race_set="$tmp/race-set.json"
"$jq_bin" -S -c --arg sha "$race_decision_sha" \
  '.body.sections[5].decision_ref.sha256=$sha' "$policy_set" >"$race_set"
race_set_sha=$(sha256_path "$race_set")
race_duty="$tmp/race-duty.json"
"$jq_bin" -S -c --arg sha "$race_set_sha" '.body.policy_set.sha256=$sha' "$duty" >"$race_duty"
race_duty_sha=$(sha256_path "$race_duty")
race_claim="$tmp/race-claim.json"
"$jq_bin" -S -c --arg set_sha "$race_set_sha" --arg duty_sha "$race_duty_sha" \
  '.body.policy_set_ref.sha256=$set_sha|.body.duty_evaluation_ref.sha256=$duty_sha' \
  "$claim" >"$race_claim"
race_out="$tmp/race.out"
race_err="$tmp/race.err"
PATH="$bin:/usr/bin:/bin" /usr/bin/perl -e 'alarm shift; exec @ARGV' 10 \
  "$race_root/control/v1/evaluate-sandbox.sh" evaluate "$race_set" "$race_duty" "$race_claim" \
  >"$race_out" 2>"$race_err" &
race_pid=$!
attempt=0
while [ ! -e "$marker" ] && kill -0 "$race_pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
  attempt=$((attempt + 1))
  /bin/sleep 0.01
done
if [ ! -e "$marker" ]; then
  : >"$release"
  kill "$race_pid" 2>/dev/null || :
  wait "$race_pid" 2>/dev/null || :
  fail 'TOCTOU marker timeout'
fi
"$jq_bin" -S -c '.body.effects.target_writes=true' "$race_claim" >"$tmp/race-claim-moved"
/bin/mv "$tmp/race-claim-moved" "$race_claim"
: >"$release"
race_status=0
wait "$race_pid" || race_status=$?
[ "$race_status" -ne 0 ] && [ ! -s "$race_out" ] &&
  [ "$(/bin/cat "$race_err")" = E_RELATION ] || fail 'TOCTOU mutation'
pass 'postflight rejects an input changed after snapshot'

for path in control/v1/sandbox-policy.json control/v1/sandbox-decision.json \
  control/v1/sandbox.jq control/v1/evaluate-sandbox.sh \
  scripts/test/control-sandbox-policy.test.sh; do
  [ -e "$root/$path" ] || fail "owned path $path"
done
pass 'owned product and test paths are complete'
/usr/bin/printf 'control sandbox policy: %s focused checks passed\n' "$passes"
