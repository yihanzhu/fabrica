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
duty_decision="$root/control/v1/duty-separation-decision.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-kill-test.XXXXXX") || exit 1
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT
fail() { /usr/bin/printf 'not ok - %s\n' "$1" >&2; exit 1; }
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

for shipped in "$policy" "$decision"; do
  "$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
    "$shipped" >"$tmp/canonical.json" || fail 'shipped json parse'
  /usr/bin/cmp -s "$shipped" "$tmp/canonical.json" || fail 'shipped json canonical'
done
policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
duty_decision_sha=$(sha256_path "$duty_decision")
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
  --arg duty_decision_sha "$duty_decision_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy;$decision):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;"application/vnd.ystack.control-policy+json";$policy),
     decision_ref:ref("control-decision."+$id;"application/vnd.ystack.control-decision+json";$decision)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.test",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
    core_contract:{semantic_identity:"core.contracts.v2",
      generation_id:("g-"+("0"*64)),
      package_ref:ref("core-contract-package.v2";
        "application/vnd.ystack.core-contract+json";("9"*64))},
    sections:[section("credential-policy";("1"*64);("a"*64)),
      section("duty-separation";("2"*64);$duty_decision_sha),
      section("evidence-integrity";("3"*64);("c"*64)),
      section("kill-switch";$policy_sha;$decision_sha),
      section("risk-gates";("5"*64);("e"*64)),
      section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set" || fail 'policy set fixture'

duty="$tmp/duty.json"
"$jq_bin" -S -c -n --arg decision_sha "$duty_decision_sha" '
  def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def doc($kind;$id;$digit):
    {schema_version:2,kind:$kind,id:$id,sha256:($digit*64)};
  {schema_version:1,kind:"duty_separation_evaluation",id:"duty-evaluation.test",
   body:{activation_state:"inactive",evaluation_mode:"observation-only",
    reference_semantics:"identity-only",
    policy_set:{id:"control-policy-set.test",sha256:("1"*64)},
    policy_ref:content("control-policy.duty-separation";
      "application/vnd.ystack.control-policy+json";("2"*64)),
    decision_ref:content("control-decision.duty-separation";
      "application/vnd.ystack.control-decision+json";$decision_sha),
    core_contract:{semantic_identity:"core.contracts.v2"},
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
  local state_sha duty_sha state_revision
  state_sha=$(sha256_path "$state_input") || return 1
  duty_sha=$(sha256_path "$duty_input") || return 1
  state_revision=$("$jq_bin" -r '.body.revision' "$state_input") || return 1
  [ -z "$revision" ] || state_revision=$revision
  "$jq_bin" -S -c -n --arg state_sha "$state_sha" --arg duty_sha "$duty_sha" \
    --argjson revision "$state_revision" '
    {schema_version:1,kind:"kill_switch_attempt",id:"kill-attempt.test",
     body:{activation_state:"inactive",authority_epoch:"epoch.test",
      expected_state:{id:"kill-state.current",revision:$revision,sha256:$state_sha},
      scope:{attempt_id:"attempt.test",repository_id:"repo.test",
        stage_id:"stage.test",workflow_id:"workflow.test"},
      duty_evaluation_ref:{schema_version:1,kind:"duty_separation_evaluation",
        id:"duty-evaluation.test",sha256:$duty_sha}}}
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

bad_set="$tmp/bad-set.json"
"$jq_bin" -S -c '(.body.sections[]|select(.section_id=="kill-switch").decision_ref.sha256)=("0"*64)' \
  "$policy_set" >"$bad_set"
expect_error policy-binding E_RELATION "$bad_set" "$state" "$attempt" "$duty"
noncanonical="$tmp/noncanonical.json"
/usr/bin/sed 's/,/,&/' "$state" >"$noncanonical"
expect_error noncanonical-state E_RELATION "$policy_set" "$noncanonical" "$attempt" "$duty"
/bin/ln -s "$state" "$tmp/state-link.json"
expect_error symlink-input E_RUNTIME "$policy_set" "$tmp/state-link.json" "$attempt" "$duty"

"$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
  --slurpfile decision "$decision" --slurpfile policy_set "$policy_set" \
  --slurpfile state "$state" --slurpfile attempt "$attempt" --slurpfile duty "$duty" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
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
    kill-switch.jq duty-separation-decision.json validate.sh policy-set.jq; do
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
    '  case "$value" in */program.jq) : >"$GATE_MARKER"; while [ ! -f "$GATE_RELEASE" ]; do /bin/sleep 0.01; done; break ;; esac' \
    'done' \
    'exec "$REAL_JQ" "$@"' >"$destination"
  /bin/chmod 0500 "$destination"
  GATE_MARKER=$marker GATE_RELEASE=$release REAL_JQ=$jq_bin :
}
wait_marker() {
  local marker=$1 pid=$2 attempt_count=0
  while [ "$attempt_count" -lt 500 ]; do
    [ -f "$marker" ] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    attempt_count=$((attempt_count + 1))
    /bin/sleep 0.01
  done
  return 1
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
GATE_MARKER=$marker GATE_RELEASE=$release REAL_JQ=$jq_bin \
  PATH="$race_bin:/usr/bin:/bin" "$race_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$race_state" "$attempt" "$duty" \
  >"$tmp/input-race.out" 2>"$tmp/input-race.err" &
race_pid=$!
wait_marker "$marker" "$race_pid" || fail 'input race marker'
"$jq_bin" -S -c '(.body.entries[]|select(.scope_kind=="global").state)="stop"' \
  "$race_state" >"$tmp/race-state-new.json"
/bin/mv "$tmp/race-state-new.json" "$race_state"
: >"$release"
wait "$race_pid" || fail 'input race status'
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
GATE_MARKER=$source_marker GATE_RELEASE=$source_release REAL_JQ=$jq_bin \
  PATH="$source_bin:/usr/bin:/bin" "$source_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" \
  >"$tmp/source-race.out" 2>"$tmp/source-race.err" &
source_pid=$!
wait_marker "$source_marker" "$source_pid" || fail 'source race marker'
/usr/bin/printf '\n' >>"$source_root/control/v1/kill-switch.jq"
: >"$source_release"
source_status=0
wait "$source_pid" || source_status=$?
[ "$source_status" -ne 0 ] && [ ! -s "$tmp/source-race.out" ] &&
  [ "$(/bin/cat "$tmp/source-race.err")" = E_RELATION ] || fail 'source race result'
pass 'source mutation fails closed'

signal_root="$tmp/signal-runtime"
copy_runtime "$signal_root"
signal_bin="$tmp/signal-bin"
/bin/mkdir "$signal_bin"
signal_marker="$tmp/signal.marker"
signal_release="$tmp/signal.release"
make_gate_jq "$signal_bin/jq" "$signal_marker" "$signal_release"
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
GATE_MARKER=$signal_marker GATE_RELEASE=$signal_release REAL_JQ=$jq_bin TMPDIR=$signal_scratch \
  PATH="$signal_bin:/usr/bin:/bin" "$signal_root/control/v1/evaluate-kill-switch.sh" evaluate \
  "$policy_set" "$state" "$attempt" "$duty" \
  >"$tmp/signal.out" 2>"$tmp/signal.err" &
signal_pid=$!
wait_marker "$signal_marker" "$signal_pid" || fail 'signal marker'
kill -TERM "$signal_pid" || fail 'signal delivery'
signal_status=0
wait "$signal_pid" || signal_status=$?
[ "$signal_status" -eq 143 ] && [ ! -s "$tmp/signal.out" ] &&
  [ ! -s "$tmp/signal.err" ] || fail 'signal result'
[ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
  fail 'signal scratch cleanup'
pass 'signal cleanup is bounded and quiet'

/usr/bin/printf '1..%s\n' "$passes"
