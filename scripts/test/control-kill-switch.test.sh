#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P) || exit 1
evaluator="$root/control/v1/evaluate-kill-switch.sh"
policy="$root/control/v1/kill-switch-policy.json"
decision="$root/control/v1/kill-switch-decision.json"
program="$root/control/v1/kill-switch.jq"
duty_policy="$root/control/v1/duty-separation-policy.json"
duty_decision="$root/control/v1/duty-separation-decision.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-kill-test.XXXXXX") || exit 1
RACE_PID=''
RACE_PGID=''
TEST_PGID=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ') || exit 1
[[ "$TEST_PGID" =~ ^[1-9][0-9]*$ ]] || exit 1
group_alive() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && kill -0 -- "-$1" 2>/dev/null
}
terminate_reap() {
  local leader=$1 group=$2 attempt_count=0
  [[ "$leader" =~ ^[1-9][0-9]*$ ]] && [[ "$group" =~ ^[1-9][0-9]*$ ]] &&
    [ "$group" = "$leader" ] && [ "$group" != "$TEST_PGID" ] || return 1
  kill -TERM -- "-$group" 2>/dev/null || :
  while group_alive "$group" && [ "$attempt_count" -lt 100 ]; do
    attempt_count=$((attempt_count + 1))
    /bin/sleep 0.01
  done
  if group_alive "$group"; then
    kill -KILL -- "-$group" 2>/dev/null || :
    attempt_count=0
    while group_alive "$group" && [ "$attempt_count" -lt 100 ]; do
      attempt_count=$((attempt_count + 1))
      /bin/sleep 0.01
    done
  fi
  wait "$leader" 2>/dev/null || :
  ! group_alive "$group"
}
cleanup() {
  if [ -n "${RACE_PID:-}" ] || [ -n "${RACE_PGID:-}" ]; then
    terminate_reap "$RACE_PID" "$RACE_PGID" || :
  fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { /usr/bin/printf 'not ok - %s\n' "$1" >&2; exit 1; }
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
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download" ||
    fail 'jq download'
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

for shipped in "$policy" "$decision" "$duty_policy"; do
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$shipped" >"$tmp/canonical.json" || fail 'shipped json parse'
  /usr/bin/cmp -s "$shipped" "$tmp/canonical.json" || fail 'shipped json canonical'
done
policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
duty_decision_sha=$(sha256_path "$duty_decision")
duty_policy_sha=$(sha256_path "$duty_policy")
duty_policy_ref_sha=$("$jq_bin" -er '.body.policy_ref.sha256' "$duty_decision") ||
  fail 'duty policy identity'
[ "$duty_policy_sha" = "$duty_policy_ref_sha" ] || fail 'duty policy binding'
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
  "$root/scripts/core-contract.sh") || fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
generation_id_sha=$(sha256_text "$generation")
[ "$generation_id_sha" = "$("$jq_bin" -r '.body.core_contract.generation_id_sha256' \
  "$duty_policy")" ] || fail 'selected generation identity'
driver_sha=$(sha256_path "$evaluator")
program_sha=$(sha256_path "$program")
validator_driver_sha=$(sha256_path "$root/control/v1/validate.sh")
validator_program_sha=$(sha256_path "$root/control/v1/policy-set.jq")
"$jq_bin" -e --arg policy_sha "$policy_sha" --arg driver_sha "$driver_sha" \
  --arg program_sha "$program_sha" --arg duty_sha "$duty_decision_sha" \
  --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" '
  .body.policy_ref.sha256==$policy_sha and
  .body.duty_decision_ref.sha256==$duty_sha and
  .body.evaluator.driver_ref.sha256==$driver_sha and
  .body.evaluator.program_ref.sha256==$program_sha and
  .body.evaluator.policy_set_validator.driver_ref.sha256==$validator_driver_sha and
  .body.evaluator.policy_set_validator.program_ref.sha256==$validator_program_sha
' "$decision" >/dev/null || fail 'decision shipped identities'
pass 'canonical shipped identities'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg duty_policy_sha "$duty_policy_sha" --arg duty_decision_sha "$duty_decision_sha" \
  --arg generation "$generation" --slurpfile duty_policy "$duty_policy" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy;$decision):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;"application/vnd.ystack.control-policy+json";$policy),
     decision_ref:ref("control-decision."+$id;"application/vnd.ystack.control-decision+json";$decision)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.test",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
    core_contract:{semantic_identity:$duty_policy[0].body.core_contract.semantic_identity,
      generation_id:$generation,package_ref:$duty_policy[0].body.core_contract.package_ref},
    sections:[section("credential-policy";("1"*64);("a"*64)),
      section("duty-separation";$duty_policy_sha;$duty_decision_sha),
      section("evidence-integrity";("3"*64);("c"*64)),
      section("kill-switch";$policy_sha;$decision_sha),
      section("risk-gates";("5"*64);("e"*64)),
      section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set" || fail 'policy set fixture'
policy_set_sha=$(sha256_path "$policy_set")

duty="$tmp/duty.json"
"$jq_bin" -S -c -n --arg set_sha "$policy_set_sha" \
  --arg decision_sha "$duty_decision_sha" \
  --slurpfile set "$policy_set" --slurpfile duty_decision "$duty_decision" '
  def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def doc($kind;$id;$digit):
    {schema_version:2,kind:$kind,id:$id,sha256:($digit*64)};
  {schema_version:1,kind:"duty_separation_evaluation",id:"attempt.test",
   body:{activation_state:"inactive",evaluation_mode:"observation-only",
    reference_semantics:"identity-only",
    policy_set:{id:$set[0].id,sha256:$set_sha},
    policy_ref:$duty_decision[0].body.policy_ref,
    decision_ref:content($duty_decision[0].id;
      "application/vnd.ystack.control-decision+json";$decision_sha),
    core_contract:$set[0].body.core_contract,
    stage:{request_ref:doc("stage_request";"request.test";"3"),
      resolved_profile_ref:doc("resolved_profile";"profile.test";"4"),
      result_ref:doc("stage_result";"attempt.test";"5")},
    verdict:"satisfied",reason_ids:["duty.satisfied"]}}
' >"$duty" || fail 'duty fixture'

state="$tmp/state.json"
"$jq_bin" -S -c -n '
  {schema_version:1,kind:"kill_switch_state",id:"kill-state.current",
   body:{activation_state:"inactive",authority_epoch:"epoch.test",
    attempt_id:"attempt.test",revision:7,
    entries:[{scope_kind:"global",scope_id:"*",state:"cleared"},
      {scope_kind:"repository",scope_id:"repo.test",state:"cleared"},
      {scope_kind:"workflow",scope_id:"workflow.test",state:"cleared"},
      {scope_kind:"stage",scope_id:"stage.test",state:"cleared"},
      {scope_kind:"attempt",scope_id:"attempt.test",state:"cleared"}]}}
' >"$state" || fail 'state fixture'

make_attempt() {
  local state_input=$1 duty_input=$2 output=$3 revision=${4:-}
  local state_sha duty_sha duty_id state_revision
  state_sha=$(sha256_path "$state_input") || return 1
  duty_sha=$(sha256_path "$duty_input") || return 1
  duty_id=$("$jq_bin" -er '.id' "$duty_input") || return 1
  state_revision=$("$jq_bin" -r '.body.revision' "$state_input") || return 1
  [ -z "$revision" ] || state_revision=$revision
  "$jq_bin" -S -c -n --arg state_sha "$state_sha" --arg duty_sha "$duty_sha" \
    --arg duty_id "$duty_id" \
    --argjson revision "$state_revision" '
    {schema_version:1,kind:"kill_switch_attempt",id:"kill-attempt.test",
     body:{activation_state:"inactive",authority_epoch:"epoch.test",
      expected_state:{id:"kill-state.current",revision:$revision,sha256:$state_sha},
      scope:{attempt_id:"attempt.test",repository_id:"repo.test",
        stage_id:"stage.test",workflow_id:"workflow.test"},
      duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
        id:$duty_id,sha256:$duty_sha}}}
  ' >"$output"
}
attempt="$tmp/attempt.json"
make_attempt "$state" "$duty" "$attempt" || fail 'attempt fixture'

expect_eval() {
  local name=$1 verdict=$2 reason=$3 state_input=$4 attempt_input=$5 duty_input=$6
  local out="$tmp/$name.out" err="$tmp/$name.err" repeat="$tmp/$name.repeat"
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$state_input" \
    "$attempt_input" "$duty_input" >"$out" 2>"$err" || {
      /bin/cat "$err" >&2
      fail "$name status"
    }
  [ ! -s "$err" ] || fail "$name stderr"
  "$jq_bin" -e --arg verdict "$verdict" --arg reason "$reason" '
    .kind=="kill_switch_evaluation" and .body.activation_state=="inactive" and
    .body.authority_effect=="none" and .body.evaluation_mode=="observation-only" and
    .body.reference_semantics=="identity-only" and .body.verdict==$verdict and
    (.body.reason_ids|index($reason)!=null) and .body.reason_ids==(.body.reason_ids|sort|unique)
  ' "$out" >/dev/null || fail "$name verdict"
  "$jq_bin" -S -c . "$out" >"$repeat"
  /usr/bin/cmp -s "$out" "$repeat" || fail "$name canonical"
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2 set_input=$3 state_input=$4 attempt_input=$5 duty_input=$6
  local status=0 out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$set_input" "$state_input" \
    "$attempt_input" "$duty_input" >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] &&
    [ "$(/bin/cat "$err")" = "$expected" ] || fail "$name"
  pass "$name"
}

expect_eval cleared satisfied kill.cleared-current "$state" "$attempt" "$duty"
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$state" "$attempt" "$duty" \
  >"$tmp/cleared-repeat.out" 2>"$tmp/cleared-repeat.err" || fail 'repeat status'
/usr/bin/cmp -s "$tmp/cleared.out" "$tmp/cleared-repeat.out" || fail 'repeat bytes'
pass 'deterministic repeat'

for scope in global repository workflow stage attempt; do
  stopped="$tmp/stop-$scope.json"
  "$jq_bin" -S -c --arg scope "$scope" \
    '(.body.entries[]|select(.scope_kind==$scope).state)="stop"' "$state" >"$stopped"
  stopped_attempt="$tmp/stop-$scope-attempt.json"
  make_attempt "$stopped" "$duty" "$stopped_attempt" || fail "stop $scope attempt"
  expect_eval "stop-$scope" violated "kill.stop.$scope" \
    "$stopped" "$stopped_attempt" "$duty"
done

missing="$tmp/missing.json"
"$jq_bin" -S -c '.body.entries|=map(select(.scope_kind!="stage"))' "$state" >"$missing"
make_attempt "$missing" "$duty" "$tmp/missing-attempt.json" || fail 'missing attempt'
expect_eval missing-scope inconclusive kill.scope-missing.stage \
  "$missing" "$tmp/missing-attempt.json" "$duty"

stop_missing="$tmp/stop-missing.json"
"$jq_bin" -S -c '(.body.entries[]|select(.scope_kind=="global").state)="stop" |
  .body.entries|=map(select(.scope_kind!="stage"))' "$state" >"$stop_missing"
make_attempt "$stop_missing" "$duty" "$tmp/stop-missing-attempt.json" ||
  fail 'stop missing attempt'
expect_eval stop-overrides-missing violated kill.stop.global \
  "$stop_missing" "$tmp/stop-missing-attempt.json" "$duty"
"$jq_bin" -e '.body.reason_ids|index("kill.scope-missing.stage")!=null' \
  "$tmp/stop-overrides-missing.out" >/dev/null || fail 'stop missing evidence'
pass 'stop retains fail-closed missing reason'

duplicate="$tmp/duplicate.json"
"$jq_bin" -S -c '.body.entries += [.body.entries[]|select(.scope_kind=="workflow")]' \
  "$state" >"$duplicate"
make_attempt "$duplicate" "$duty" "$tmp/duplicate-attempt.json" || fail 'duplicate attempt'
expect_eval ambiguous-scope violated kill.scope-ambiguous.workflow \
  "$duplicate" "$tmp/duplicate-attempt.json" "$duty"

mismatch="$tmp/mismatch.json"
"$jq_bin" -S -c '(.body.entries[]|select(.scope_kind=="repository").scope_id)="repo.other"' \
  "$state" >"$mismatch"
make_attempt "$mismatch" "$duty" "$tmp/mismatch-attempt.json" || fail 'mismatch attempt'
expect_eval scope-mismatch violated kill.scope-mismatch.repository \
  "$mismatch" "$tmp/mismatch-attempt.json" "$duty"

rollback="$tmp/rollback.json"
"$jq_bin" -S -c '.body.revision=6' "$state" >"$rollback"
make_attempt "$rollback" "$duty" "$tmp/rollback-attempt.json" 7 || fail 'rollback attempt'
expect_eval rollback violated kill.state-rollback \
  "$rollback" "$tmp/rollback-attempt.json" "$duty"
newer="$tmp/newer.json"
"$jq_bin" -S -c '.body.revision=8' "$state" >"$newer"
make_attempt "$newer" "$duty" "$tmp/newer-attempt.json" 7 || fail 'newer attempt'
expect_eval stale-attempt violated kill.attempt-stale "$newer" "$tmp/newer-attempt.json" "$duty"

bad_digest="$tmp/bad-digest-attempt.json"
"$jq_bin" -S -c '.body.expected_state.sha256=("f"*64)' "$attempt" >"$bad_digest"
expect_eval state-digest violated kill.state-digest-mismatch "$state" "$bad_digest" "$duty"
replayed="$tmp/replayed.json"
"$jq_bin" -S -c '.body.attempt_id="attempt.old"' "$state" >"$replayed"
make_attempt "$replayed" "$duty" "$tmp/replayed-attempt.json" || fail 'replayed attempt'
expect_eval replayed-state violated kill.state-replayed \
  "$replayed" "$tmp/replayed-attempt.json" "$duty"

duty_violated="$tmp/duty-violated.json"
"$jq_bin" -S -c '.body.verdict="violated"|.body.reason_ids=["publisher.not-dormant"]' \
  "$duty" >"$duty_violated"
make_attempt "$state" "$duty_violated" "$tmp/duty-violated-attempt.json" ||
  fail 'duty violated attempt'
expect_eval duty-violated violated kill.duty-violated \
  "$state" "$tmp/duty-violated-attempt.json" "$duty_violated"
duty_unknown="$tmp/duty-unknown.json"
"$jq_bin" -S -c '.body.verdict="inconclusive"|.body.reason_ids=["actual.capability-unclassified"]' \
  "$duty" >"$duty_unknown"
make_attempt "$state" "$duty_unknown" "$tmp/duty-unknown-attempt.json" ||
  fail 'duty unknown attempt'
expect_eval duty-inconclusive inconclusive kill.duty-inconclusive \
  "$state" "$tmp/duty-unknown-attempt.json" "$duty_unknown"
bad_duty_ref="$tmp/bad-duty-ref.json"
"$jq_bin" -S -c '.body.duty_evaluation_ref.sha256=("e"*64)' "$attempt" >"$bad_duty_ref"
expect_eval duty-unverifiable inconclusive kill.duty-unverifiable \
  "$state" "$bad_duty_ref" "$duty"
duty_replay="$tmp/duty-replay.json"
"$jq_bin" -S -c '.body.stage.result_ref.id="attempt.old"' "$duty" >"$duty_replay"
make_attempt "$state" "$duty_replay" "$tmp/duty-replay-attempt.json" ||
  fail 'duty replay attempt'
expect_eval duty-replay inconclusive kill.duty-unverifiable \
  "$state" "$tmp/duty-replay-attempt.json" "$duty_replay"
duty_stale_set="$tmp/duty-stale-set.json"
"$jq_bin" -S -c '.body.policy_set.sha256=("9"*64)' "$duty" >"$duty_stale_set"
make_attempt "$state" "$duty_stale_set" "$tmp/duty-stale-set-attempt.json" ||
  fail 'duty stale set attempt'
expect_eval duty-stale-policy-set inconclusive kill.duty-unverifiable \
  "$state" "$tmp/duty-stale-set-attempt.json" "$duty_stale_set"
duty_stale_policy="$tmp/duty-stale-policy.json"
"$jq_bin" -S -c '.body.policy_ref.sha256=("8"*64)' "$duty" >"$duty_stale_policy"
make_attempt "$state" "$duty_stale_policy" "$tmp/duty-stale-policy-attempt.json" ||
  fail 'duty stale policy attempt'
expect_eval duty-stale-policy inconclusive kill.duty-unverifiable \
  "$state" "$tmp/duty-stale-policy-attempt.json" "$duty_stale_policy"
duty_stale_core="$tmp/duty-stale-core.json"
"$jq_bin" -S -c '.body.core_contract.package_ref.sha256=("7"*64)' \
  "$duty" >"$duty_stale_core"
make_attempt "$state" "$duty_stale_core" "$tmp/duty-stale-core-attempt.json" ||
  fail 'duty stale core attempt'
expect_eval duty-stale-core inconclusive kill.duty-unverifiable \
  "$state" "$tmp/duty-stale-core-attempt.json" "$duty_stale_core"
forged_core_set="$tmp/forged-core-set.json"
"$jq_bin" -S -c '.body.core_contract.semantic_identity="core.contracts.v3" |
  .body.core_contract.package_ref.sha256=("7"*64)' "$policy_set" >"$forged_core_set"
forged_core_set_sha=$(sha256_path "$forged_core_set")
forged_core_duty="$tmp/forged-core-duty.json"
"$jq_bin" -S -c --arg set_sha "$forged_core_set_sha" \
  --slurpfile forged_set "$forged_core_set" '
  .body.policy_set.sha256=$set_sha | .body.core_contract=$forged_set[0].body.core_contract
' "$duty" >"$forged_core_duty"
make_attempt "$state" "$forged_core_duty" "$tmp/forged-core-attempt.json" ||
  fail 'paired forged core attempt'
expect_error paired-core-forgery E_RELATION "$forged_core_set" "$state" \
  "$tmp/forged-core-attempt.json" "$forged_core_duty"
forged_duty="$tmp/forged-duty.json"
"$jq_bin" -S -c '.body.reason_ids=["duty.forged"]' "$duty" >"$forged_duty"
make_attempt "$state" "$forged_duty" "$tmp/forged-duty-attempt.json" ||
  fail 'forged duty attempt'
expect_error forged-duty E_RELATION "$policy_set" "$state" \
  "$tmp/forged-duty-attempt.json" "$forged_duty"
forged_stage="$tmp/forged-stage.json"
"$jq_bin" -S -c '.body.stage.result_ref.kind="stage_request"' "$duty" >"$forged_stage"
make_attempt "$state" "$forged_stage" "$tmp/forged-stage-attempt.json" ||
  fail 'forged stage attempt'
expect_error forged-duty-stage E_RELATION "$policy_set" "$state" \
  "$tmp/forged-stage-attempt.json" "$forged_stage"

bad_set="$tmp/bad-set.json"
"$jq_bin" -S -c '(.body.sections[]|select(.section_id=="kill-switch").decision_ref.sha256)=("0"*64)' \
  "$policy_set" >"$bad_set"
expect_error policy-binding E_RELATION "$bad_set" "$state" "$attempt" "$duty"
bad_duty_set="$tmp/bad-duty-set.json"
"$jq_bin" -S -c '(.body.sections[]|select(.section_id=="duty-separation").policy_ref.sha256)=("0"*64)' \
  "$policy_set" >"$bad_duty_set"
expect_error duty-policy-binding E_RELATION "$bad_duty_set" "$state" "$attempt" "$duty"
noncanonical="$tmp/noncanonical.json"
/usr/bin/sed 's/,/,&/' "$state" >"$noncanonical"
expect_error noncanonical-state E_RELATION "$policy_set" "$noncanonical" "$attempt" "$duty"
/bin/ln -s "$state" "$tmp/state-link.json"
expect_error symlink-input E_RUNTIME "$policy_set" "$tmp/state-link.json" "$attempt" "$duty"

"$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
  --slurpfile decision "$decision" --slurpfile policy_set "$policy_set" \
  --slurpfile duty_policy "$duty_policy" \
  --slurpfile duty_decision "$duty_decision" \
  --slurpfile state "$state" --slurpfile attempt "$attempt" --slurpfile duty "$duty" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg duty_policy_sha "$duty_policy_sha" --arg duty_decision_sha "$duty_decision_sha" \
  --arg generation_id_sha "$generation_id_sha" \
  --arg policy_set_sha "$(sha256_path "$policy_set")" --arg state_sha "$(sha256_path "$state")" \
  --arg attempt_sha "$(sha256_path "$attempt")" --arg duty_sha "$(sha256_path "$duty")" \
  >"$tmp/pure.out" || fail 'pure evaluator status'
"$jq_bin" -e '.body.verdict=="satisfied" and .body.reason_ids==["kill.cleared-current"]' \
  "$tmp/pure.out" >/dev/null || fail 'pure evaluator result'
pass 'pure evaluator'

copy_runtime() {
  local destination=$1 name
  /bin/mkdir -p "$destination/control/v1"
  for name in evaluate-kill-switch.sh kill-switch-policy.json kill-switch-decision.json \
    kill-switch.jq duty-separation-policy.json duty-separation-decision.json \
    validate.sh policy-set.jq; do
    /bin/cp "$root/control/v1/$name" "$destination/control/v1/$name"
  done
  /bin/chmod 0500 "$destination/control/v1/evaluate-kill-switch.sh" \
    "$destination/control/v1/validate.sh"
}
make_gate_jq() {
  local destination=$1 marker=$2 release=$3
  /usr/bin/printf '%s\n' '#!/bin/bash' \
    'if [ "${1:-}" = --version ]; then /usr/bin/printf "jq-1.6\\n"; exit 0; fi' \
    'for value in "$@"; do' \
    '  case "$value" in */program.jq)' \
    '    if [ "${TERM_RESIST_NESTED:-0}" = 1 ]; then trap "" TERM; fi' \
    '    if [ -n "${NESTED_PID_FILE:-}" ]; then /bin/sleep 30 & nested=$!; /usr/bin/printf "%s\n" "$nested" >"$NESTED_PID_FILE"; fi' \
    '    if [ -n "${INNER_LEADER_FILE:-}" ]; then /usr/bin/printf "%s\n" "$$" >"$INNER_LEADER_FILE"; fi' \
    '    if [ -n "${INNER_PGID_FILE:-}" ]; then /bin/ps -o pgid= -p $$ | /usr/bin/tr -d " " >"$INNER_PGID_FILE"; fi' \
    '    : >"$GATE_MARKER"; while [ ! -f "$GATE_RELEASE" ]; do /bin/sleep 0.01; done; break ;; esac' \
    'done' \
    'exec "$REAL_JQ" "$@"' >"$destination"
  /bin/chmod 0500 "$destination"
  GATE_MARKER=$marker GATE_RELEASE=$release REAL_JQ=$jq_bin :
}
start_eval_group() {
  local name=$1 output=$2 diagnostic=$3 gate leader pgid
  shift 3
  gate="$tmp/$name.start-gate"
  /usr/bin/mkfifo "$gate" || fail "$name start gate"
  exec 8<>"$gate" || fail "$name start gate open"
  /bin/rm -f -- "$gate" || fail "$name start gate remove"
  set -m
  /bin/bash -c '
    IFS= read -r token <&8 || exit 125
    exec 8>&-
    [ "$token" = go ] || exit 125
    exec "$@"
  ' test-supervisor "$@" >"$output" 2>"$diagnostic" &
  leader=$!
  set +m
  pgid=$(/bin/ps -o pgid= -p "$leader" 2>/dev/null | /usr/bin/tr -d ' ') || pgid=''
  if ! [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$leader" ] ||
     [ "$pgid" = "$TEST_PGID" ]; then
    /usr/bin/printf 'abort\n' >&8 || :
    exec 8>&-
    wait "$leader" 2>/dev/null || :
    fail "$name unsafe process group"
  fi
  RACE_PID=$leader
  RACE_PGID=$pgid
  /usr/bin/printf 'go\n' >&8 || fail "$name gate release"
  exec 8>&-
}
wait_marker() {
  local name=$1 marker=$2 pid=$3 group=$4 attempt_count=0
  while [ "$attempt_count" -lt 500 ]; do
    [ -f "$marker" ] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      terminate_reap "$pid" "$group" || :
      RACE_PID=''
      RACE_PGID=''
      fail "$name exited before marker"
    fi
    attempt_count=$((attempt_count + 1))
    /bin/sleep 0.01
  done
  terminate_reap "$pid" "$group" || :
  RACE_PID=''
  RACE_PGID=''
  fail "$name marker timeout"
}
wait_named_file() {
  local name=$1 root_path=$2 pattern=$3 pid=$4 group=$5 attempt_count=0 found
  while [ "$attempt_count" -lt 5000 ]; do
    found=$(/usr/bin/find "$root_path" -name "$pattern" -type f -print -quit 2>/dev/null)
    [ -n "$found" ] && return 0
    if ! kill -0 "$pid" 2>/dev/null; then
      terminate_reap "$pid" "$group" || :
      RACE_PID=''
      RACE_PGID=''
      fail "$name exited before $pattern"
    fi
    attempt_count=$((attempt_count + 1))
    /bin/sleep 0.001
  done
  terminate_reap "$pid" "$group" || :
  RACE_PID=''
  RACE_PGID=''
  fail "$name timeout waiting for $pattern"
}
wait_group() {
  local name=$1 pid=$2 group=$3 attempt_count=0 status=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt_count" -lt 1000 ]; do
    attempt_count=$((attempt_count + 1))
    /bin/sleep 0.01
  done
  if kill -0 "$pid" 2>/dev/null; then
    terminate_reap "$pid" "$group" || :
    RACE_PID=''
    RACE_PGID=''
    fail "$name completion timeout"
  fi
  wait "$pid" 2>/dev/null || status=$?
  if group_alive "$group"; then
    terminate_reap "$pid" "$group" || :
    RACE_PID=''
    RACE_PGID=''
    fail "$name left descendants"
  fi
  RACE_STATUS=$status
  RACE_PID=''
  RACE_PGID=''
}

race_root="$tmp/race-runtime"
copy_runtime "$race_root"
race_bin="$tmp/race-bin"
/bin/mkdir "$race_bin"
marker="$tmp/input.marker"
release="$tmp/input.release"
make_gate_jq "$race_bin/jq" "$marker" "$release"
race_state="$tmp/race-state.json"
/bin/cp "$state" "$race_state"
start_eval_group input-race "$tmp/input-race.out" "$tmp/input-race.err" \
  /usr/bin/env GATE_MARKER="$marker" GATE_RELEASE="$release" REAL_JQ="$jq_bin" \
  PATH="$race_bin:/usr/bin:/bin" "$race_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$race_state" "$attempt" "$duty" \
  || fail 'input race start'
race_pid=$RACE_PID
race_pgid=$RACE_PGID
wait_marker input-race "$marker" "$race_pid" "$race_pgid"
"$jq_bin" -S -c '(.body.entries[]|select(.scope_kind=="global").state)="stop"' \
  "$race_state" >"$tmp/race-state-new.json"
/bin/mv "$tmp/race-state-new.json" "$race_state"
: >"$release"
wait_group input-race "$race_pid" "$race_pgid"
[ "$RACE_STATUS" -eq 0 ] || fail 'input race status'
[ ! -s "$tmp/input-race.err" ] || fail 'input race stderr'
"$jq_bin" -e '.body.verdict=="satisfied"' "$tmp/input-race.out" >/dev/null ||
  fail 'input snapshot changed'
pass 'input snapshot is single-read'

source_root="$tmp/source-runtime"
copy_runtime "$source_root"
source_bin="$tmp/source-bin"
/bin/mkdir "$source_bin"
source_marker="$tmp/source.marker"
source_release="$tmp/source.release"
make_gate_jq "$source_bin/jq" "$source_marker" "$source_release"
start_eval_group source-race "$tmp/source-race.out" "$tmp/source-race.err" \
  /usr/bin/env GATE_MARKER="$source_marker" GATE_RELEASE="$source_release" \
  REAL_JQ="$jq_bin" PATH="$source_bin:/usr/bin:/bin" \
  "$source_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" \
  || fail 'source race start'
source_pid=$RACE_PID
source_pgid=$RACE_PGID
wait_marker source-race "$source_marker" "$source_pid" "$source_pgid"
/usr/bin/printf '\n' >>"$source_root/control/v1/kill-switch.jq"
: >"$source_release"
wait_group source-race "$source_pid" "$source_pgid"
[ "$RACE_STATUS" -ne 0 ] && [ ! -s "$tmp/source-race.out" ] &&
  [ "$(/bin/cat "$tmp/source-race.err")" = E_RELATION ] || fail 'source race result'
pass 'source mutation fails closed'

launch_root="$tmp/launch-runtime"
copy_runtime "$launch_root"
launch_scratch="$tmp/launch-scratch"
/bin/mkdir "$launch_scratch"
start_eval_group launch-signal "$tmp/launch.out" "$tmp/launch.err" \
  /usr/bin/env TMPDIR="$launch_scratch" PATH="$bin:/usr/bin:/bin" \
  "$launch_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" \
  || fail 'launch signal start'
launch_pid=$RACE_PID
launch_pgid=$RACE_PGID
wait_named_file launch-signal "$launch_scratch" child-launching "$launch_pid" "$launch_pgid"
for _ in 1 2 3; do kill -TERM -- "-$launch_pgid" 2>/dev/null || :; done
wait_group launch-signal "$launch_pid" "$launch_pgid"
[ "$RACE_STATUS" -eq 143 ] && [ ! -s "$tmp/launch.out" ] &&
  [ ! -s "$tmp/launch.err" ] || fail 'launch signal result'
[ -z "$(/usr/bin/find "$launch_scratch" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'launch signal scratch cleanup'
pass 'launch-window repeated group signal is clean'

teardown_root="$tmp/teardown-runtime"
copy_runtime "$teardown_root"
teardown_scratch="$tmp/teardown-scratch"
/bin/mkdir "$teardown_scratch"
start_eval_group teardown-signal "$tmp/teardown.out" "$tmp/teardown.err" \
  /usr/bin/env TMPDIR="$teardown_scratch" PATH="$bin:/usr/bin:/bin" \
  "$teardown_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" || fail 'teardown signal start'
teardown_pid=$RACE_PID
teardown_pgid=$RACE_PGID
wait_named_file teardown-signal "$teardown_scratch" child-teardown \
  "$teardown_pid" "$teardown_pgid"
for _ in 1 2 3; do kill -TERM -- "-$teardown_pgid" 2>/dev/null || :; done
wait_group teardown-signal "$teardown_pid" "$teardown_pgid"
[ "$RACE_STATUS" -eq 143 ] && [ ! -s "$tmp/teardown.out" ] &&
  [ ! -s "$tmp/teardown.err" ] || fail 'teardown signal result'
[ -z "$(/usr/bin/find "$teardown_scratch" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'teardown signal scratch cleanup'
pass 'teardown-window repeated group signal is clean'

signal_root="$tmp/signal-runtime"
copy_runtime "$signal_root"
signal_bin="$tmp/signal-bin"
/bin/mkdir "$signal_bin"
signal_marker="$tmp/signal.marker"
signal_release="$tmp/signal.release"
nested_pid_file="$tmp/nested.pid"
inner_leader_file="$tmp/inner.leader"
inner_pgid_file="$tmp/inner.pgid"
make_gate_jq "$signal_bin/jq" "$signal_marker" "$signal_release"
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
start_eval_group nested-signal "$tmp/signal.out" "$tmp/signal.err" \
  /usr/bin/env GATE_MARKER="$signal_marker" GATE_RELEASE="$signal_release" \
  NESTED_PID_FILE="$nested_pid_file" INNER_LEADER_FILE="$inner_leader_file" \
  INNER_PGID_FILE="$inner_pgid_file" \
  TERM_RESIST_NESTED=1 REAL_JQ="$jq_bin" TMPDIR="$signal_scratch" \
  PATH="$signal_bin:/usr/bin:/bin" "$signal_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" || fail 'nested signal start'
signal_pid=$RACE_PID
signal_pgid=$RACE_PGID
wait_marker nested-signal "$signal_marker" "$signal_pid" "$signal_pgid"
wait_marker nested-child "$nested_pid_file" "$signal_pid" "$signal_pgid"
wait_marker inner-leader "$inner_leader_file" "$signal_pid" "$signal_pgid"
wait_marker inner-group "$inner_pgid_file" "$signal_pid" "$signal_pgid"
nested_pid=$(/bin/cat "$nested_pid_file")
inner_leader=$(/bin/cat "$inner_leader_file")
inner_pgid=$(/bin/cat "$inner_pgid_file")
[[ "$nested_pid" =~ ^[1-9][0-9]*$ ]] || fail 'nested pid shape'
[[ "$inner_leader" =~ ^[1-9][0-9]*$ ]] && [ "$inner_leader" = "$inner_pgid" ] &&
  [[ "$inner_pgid" =~ ^[1-9][0-9]*$ ]] && [ "$inner_pgid" != "$TEST_PGID" ] &&
  [ "$inner_pgid" != "$signal_pgid" ] || fail 'inner pgid shape'
kill -TERM -- "-$signal_pgid" 2>/dev/null || fail 'first cleanup signal'
/bin/sleep 0.2
if ! kill -0 "$signal_pid" 2>/dev/null || ! kill -0 "$nested_pid" 2>/dev/null ||
   ! group_alive "$inner_pgid"; then
  fail 'cleanup window was not held'
fi
for _ in 1 2; do kill -TERM -- "-$signal_pgid" 2>/dev/null || :; done
wait_group nested-signal "$signal_pid" "$signal_pgid"
if [ "$RACE_STATUS" -ne 143 ] || [ -s "$tmp/signal.out" ] ||
   [ -s "$tmp/signal.err" ] || kill -0 "$inner_leader" 2>/dev/null ||
   kill -0 "$nested_pid" 2>/dev/null ||
   group_alive "$inner_pgid"; then
  fail 'nested signal result'
fi
[ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'nested signal scratch cleanup'
pass 'signal reaps nested descendants and scratch'

/usr/bin/printf '1..%s\n' "$passes"
