#!/bin/bash
# shellcheck disable=SC2016
set -uo pipefail
export LC_ALL=C
umask 077

emit_error() {
  case "${1:-}" in
    E_USAGE|E_RUNTIME|E_LIMIT|E_POLICY_SET|E_RELATION)
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
[ "$source_path" = "$source_dir/evaluate-kill-switch.sh" ] || emit_error E_RUNTIME
repo=$(CDPATH='' cd -P -- "$source_dir/../.." 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
policy="$source_dir/kill-switch-policy.json"
decision="$source_dir/kill-switch-decision.json"
program="$source_dir/kill-switch.jq"
duty_policy="$source_dir/duty-separation-policy.json"
duty_decision="$source_dir/duty-separation-decision.json"
policy_validator="$source_dir/validate.sh"
validator_program="$source_dir/policy-set.jq"
for control_dir in "$repo/control" "$source_dir"; do
  [ -d "$control_dir" ] && [ ! -L "$control_dir" ] || emit_error E_RUNTIME
done
[ "$source_dir" = "$repo/control/v1" ] || emit_error E_RUNTIME
for required in "$source_path" "$policy" "$decision" "$program" \
  "$duty_policy" "$duty_decision" "$policy_validator" "$validator_program"; do
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
scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-kill.XXXXXX" 2>/dev/null) ||
  emit_error E_RUNTIME
scratch=$(CDPATH='' cd -P -- "$scratch" 2>/dev/null && pwd -P) ||
  emit_error E_RUNTIME
ACTIVE_PID=''
ACTIVE_PGID=''
CHILD_SEQUENCE=0
SIGNAL_DEFER=0
SIGNAL_EXITING=0
PENDING_SIGNAL_STATUS=0
SELF_PGID=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ') ||
  emit_error E_RUNTIME
[[ "$SELF_PGID" =~ ^[1-9][0-9]*$ ]] || emit_error E_RUNTIME

cleanup() { /bin/rm -rf -- "$scratch" >/dev/null 2>&1 || :; }
group_alive() {
  [ -n "${1:-}" ] && kill -0 -- "-$1" 2>/dev/null
}
terminate_active() {
  local attempt=0 group=${ACTIVE_PGID:-} leader=${ACTIVE_PID:-}
  [[ "$group" =~ ^[1-9][0-9]*$ ]] && [[ "$leader" =~ ^[1-9][0-9]*$ ]] ||
    return 1
  kill -TERM -- "-$group" 2>/dev/null || :
  while group_alive "$group" && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01 || :
  done
  if group_alive "$group"; then
    kill -KILL -- "-$group" 2>/dev/null || :
    attempt=0
    while group_alive "$group" && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      /bin/sleep 0.01 || :
    done
  fi
  group_alive "$group" && return 1
  wait "$leader" 2>/dev/null || :
  ACTIVE_PID=''
  ACTIVE_PGID=''
  ! group_alive "$group"
}
signal_exit() {
  local status=${1:-1}
  trap - EXIT
  exec >/dev/null 2>&1
  if [ -n "${ACTIVE_PGID:-}" ]; then terminate_active || :; fi
  cleanup
  exit "$status"
}
handle_signal() {
  local status=${1:-1}
  [ "${SIGNAL_EXITING:-0}" -eq 0 ] || return 0
  [ "${PENDING_SIGNAL_STATUS:-0}" -ne 0 ] || PENDING_SIGNAL_STATUS=$status
  [ "${SIGNAL_DEFER:-0}" -eq 0 ] || return 0
  SIGNAL_EXITING=1
  signal_exit "$PENDING_SIGNAL_STATUS"
}
replay_pending_signal() {
  local pending
  SIGNAL_DEFER=0
  pending=${PENDING_SIGNAL_STATUS:-0}
  PENDING_SIGNAL_STATUS=0
  if [ "$pending" -ne 0 ]; then
    SIGNAL_EXITING=1
    signal_exit "$pending"
  fi
}
run_child() {
  local status=0 child pgid gate launch_marker teardown_marker wait_status
  [ -z "${ACTIVE_PID:-}" ] && [ -z "${ACTIVE_PGID:-}" ] || return 125
  CHILD_SEQUENCE=$((CHILD_SEQUENCE + 1))
  gate="$scratch/child-gate.$CHILD_SEQUENCE"
  launch_marker="$scratch/child-launching"
  teardown_marker="$scratch/child-teardown"
  PENDING_SIGNAL_STATUS=0
  SIGNAL_DEFER=1
  /usr/bin/mkfifo "$gate" || { replay_pending_signal; return 125; }
  exec 9<>"$gate" || { /bin/rm -f -- "$gate"; replay_pending_signal; return 125; }
  /bin/rm -f -- "$gate" || { exec 9>&-; replay_pending_signal; return 125; }
  : >"$launch_marker" || { exec 9>&-; replay_pending_signal; return 125; }
  if [ "${PENDING_SIGNAL_STATUS:-0}" -ne 0 ]; then
    exec 9>&-
    /bin/rm -f -- "$launch_marker"
    replay_pending_signal
  fi
  set -m
  /bin/bash -c '
    IFS= read -r token <&9 || exit 125
    exec 9>&-
    [ "$token" = go ] || exit 125
    exec "$@"
  ' child-supervisor "$@" &
  child=$!
  set +m
  pgid=$(/bin/ps -o pgid= -p "$child" 2>/dev/null | /usr/bin/tr -d ' ') || pgid=''
  if ! [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$child" ] ||
     [ "$pgid" = "$SELF_PGID" ]; then
    /usr/bin/printf 'abort\n' >&9 || :
    exec 9>&-
    /bin/rm -f -- "$launch_marker"
    while kill -0 "$child" 2>/dev/null; do
      wait "$child" 2>/dev/null || :
      kill -0 "$child" 2>/dev/null && /bin/sleep 0.01 || :
    done
    wait "$child" 2>/dev/null || :
    replay_pending_signal
    return 125
  fi
  ACTIVE_PID=$child
  ACTIVE_PGID=$pgid
  if ! /usr/bin/printf 'go\n' >&9; then
    exec 9>&-
    /bin/rm -f -- "$launch_marker"
    terminate_active
    replay_pending_signal
    return 125
  fi
  exec 9>&-
  /bin/rm -f -- "$launch_marker" || {
    terminate_active
    replay_pending_signal
    return 125
  }
  replay_pending_signal
  while :; do
    wait_status=0
    wait "$child" || wait_status=$?
    case "$wait_status" in
      129|130|143) kill -0 "$child" 2>/dev/null && continue ;;
    esac
    status=$wait_status
    break
  done
  SIGNAL_DEFER=1
  : >"$teardown_marker" || {
    terminate_active
    replay_pending_signal
    return 125
  }
  if group_alive "$ACTIVE_PGID"; then
    terminate_active
    /bin/rm -f -- "$teardown_marker"
    replay_pending_signal
    return 125
  fi
  ACTIVE_PID=''
  ACTIVE_PGID=''
  /bin/rm -f -- "$teardown_marker" || {
    replay_pending_signal
    return 125
  }
  replay_pending_signal
  return "$status"
}
snapshot_fixed() {
  local source=$1 target=$2 size
  /bin/dd if="$source" of="$target" bs=1048577 count=1 2>/dev/null ||
    emit_error E_RUNTIME
  size=$(/usr/bin/wc -c <"$target" | /usr/bin/tr -d ' ') || emit_error E_RUNTIME
  [ "$size" -le 1048576 ] || emit_error E_LIMIT
}
validator_pair_ok() {
  local pair_dir=$1 driver=$2 jq_program=$3 driver_sha=$4 program_sha=$5
  local physical_dir
  [ -d "$pair_dir" ] && [ ! -L "$pair_dir" ] || return 1
  physical_dir=$(CDPATH='' cd -P -- "$pair_dir" 2>/dev/null && pwd -P) || return 1
  [ "$physical_dir" = "$pair_dir" ] &&
    [ "$driver" = "$pair_dir/validate.sh" ] &&
    [ "$jq_program" = "$pair_dir/policy-set.jq" ] &&
    [ -f "$driver" ] && [ ! -L "$driver" ] &&
    [ -f "$jq_program" ] && [ ! -L "$jq_program" ] &&
    [ "$(sha256_path "$driver")" = "$driver_sha" ] &&
    [ "$(sha256_path "$jq_program")" = "$program_sha" ]
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
canonical_one() {
  local input=$1 output=$2
  run_child "$jq_bin" -s -S -c \
    'if length==1 then .[0] else error("root-count") end' "$input" >"$output" 2>/dev/null
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
names=(policy-set state attempt duty)
index=0
for input in "$@"; do
  snapshot_fixed "$input" "$scratch/${names[$index]}.json"
  index=$((index + 1))
done
snapshot_fixed "$policy" "$scratch/policy.json"
snapshot_fixed "$decision" "$scratch/decision.json"
snapshot_fixed "$program" "$scratch/program.jq"
snapshot_fixed "$duty_policy" "$scratch/duty-policy.json"
snapshot_fixed "$duty_decision" "$scratch/duty-decision.json"
for json_name in policy-set state attempt duty policy decision duty-policy duty-decision; do
  canonical_one "$scratch/$json_name.json" "$scratch/$json_name.canonical" ||
    emit_error E_RELATION
  /usr/bin/cmp -s "$scratch/$json_name.json" "$scratch/$json_name.canonical" ||
    emit_error E_RELATION
done

policy_sha=$(sha256_path "$scratch/policy.json") || emit_error E_RUNTIME
decision_sha=$(sha256_path "$scratch/decision.json") || emit_error E_RUNTIME
program_sha=$(sha256_path "$scratch/program.jq") || emit_error E_RUNTIME
duty_policy_sha=$(sha256_path "$scratch/duty-policy.json") || emit_error E_RUNTIME
duty_decision_sha=$(sha256_path "$scratch/duty-decision.json") || emit_error E_RUNTIME
driver_sha=$(sha256_path "$source_path") || emit_error E_RUNTIME
validator_driver_sha=$(sha256_path "$policy_validator") || emit_error E_RELATION
validator_program_sha=$(sha256_path "$validator_program") || emit_error E_RELATION
validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
  "$validator_driver_sha" "$validator_program_sha" || emit_error E_RELATION
mirror_validator_dir=$(build_validator_mirror) || emit_error E_RELATION
mirror_policy_validator="$mirror_validator_dir/validate.sh"
mirror_validator_program="$mirror_validator_dir/policy-set.jq"
validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
  "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha" ||
  emit_error E_RELATION

run_child "$jq_bin" -n -e --arg policy_sha "$policy_sha" \
  --arg decision_sha "$decision_sha" --arg program_sha "$program_sha" \
  --arg driver_sha "$driver_sha" --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" \
  --arg validator_driver_sha "$validator_driver_sha" \
  --arg validator_program_sha "$validator_program_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile duty_policy "$scratch/duty-policy.json" \
  --slurpfile duty_decision "$scratch/duty-decision.json" '
  $decision[0] == {
    schema_version:1,kind:"kill_switch_decision",id:"control-decision.kill-switch",
    body:{activation_state:"inactive",decision:"allow-observation-only-evaluation",
      duty_decision_ref:{content_id:$duty_decision[0].id,
        media_type:"application/vnd.ystack.control-decision+json",sha256:$duty_decision_sha},
      evaluator:{
        driver_ref:{content_id:"control-evaluator-driver.kill-switch.v1",
          media_type:"text/x-shellscript",sha256:$driver_sha},
        program_ref:{content_id:"control-evaluator-program.kill-switch.v1",
          media_type:"text/x-jq",sha256:$program_sha},
        policy_set_validator:{
          driver_ref:{content_id:"control-policy-set-validator-driver.v1",
            media_type:"text/x-shellscript",sha256:$validator_driver_sha},
          program_ref:{content_id:"control-policy-set-validator-program.v1",
            media_type:"text/x-jq",sha256:$validator_program_sha}}},
      fail_mode:"closed",
      policy_ref:{content_id:$policy[0].id,
        media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha},
      semantics:{authority_effect:"none",
        input_contract:"control-policy-set+kill-state+attempt+duty-evaluation.v1",
        output_kind:"kill_switch_evaluation",output_schema_version:1,
        reference_semantics:"identity-only",
        verdicts:["inconclusive","satisfied","violated"]}}
  } and $policy[0].body.duty_decision_ref == $decision[0].body.duty_decision_ref and
  $duty_decision[0].body.policy_ref == {content_id:$duty_policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",sha256:$duty_policy_sha} and
  $decision_sha != ""
' >/dev/null 2>&1 || emit_error E_RELATION

policy_status=0
run_child "$mirror_policy_validator" validate "$scratch/policy-set.json" \
  >"$scratch/policy.out" 2>"$scratch/policy.err" || policy_status=$?
if ! validator_pair_ok "$source_dir" "$policy_validator" "$validator_program" \
     "$validator_driver_sha" "$validator_program_sha" ||
   ! validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
     "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha"; then
  emit_error E_RELATION
fi
[ "$policy_status" -eq 0 ] || emit_error E_POLICY_SET

policy_set_sha=$(sha256_path "$scratch/policy-set.json") || emit_error E_RUNTIME
state_sha=$(sha256_path "$scratch/state.json") || emit_error E_RUNTIME
attempt_sha=$(sha256_path "$scratch/attempt.json") || emit_error E_RUNTIME
duty_sha=$(sha256_path "$scratch/duty.json") || emit_error E_RUNTIME
run_child "$jq_bin" -er '.body.core_contract.generation_id' \
  "$scratch/policy-set.json" >"$scratch/generation-id" 2>/dev/null || emit_error E_RELATION
IFS= read -r generation_id <"$scratch/generation-id" || emit_error E_RELATION
generation_id_sha=$(sha256_text "$generation_id") || emit_error E_RUNTIME
run_child "$jq_bin" -e --arg policy_sha "$policy_sha" \
  --arg decision_sha "$decision_sha" --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" --arg generation_id_sha "$generation_id_sha" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile duty_policy "$scratch/duty-policy.json" \
  --slurpfile duty_decision "$scratch/duty-decision.json" '
  ([.body.sections[] | select(.section_id=="kill-switch")]|length)==1 and
  ([.body.sections[] | select(.section_id=="kill-switch")][0]) as $kill |
  $kill.policy_ref=={content_id:$policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  $kill.decision_ref=={content_id:$decision[0].id,
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  ([.body.sections[] | select(.section_id=="duty-separation")]|length)==1 and
  ([.body.sections[] | select(.section_id=="duty-separation")][0]) as $duty |
  $duty.policy_ref==$duty_decision[0].body.policy_ref and
  $duty.decision_ref=={content_id:$duty_decision[0].id,
    media_type:"application/vnd.ystack.control-decision+json",sha256:$duty_decision_sha} and
  $duty_decision[0].body.policy_ref=={content_id:$duty_policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",sha256:$duty_policy_sha} and
  .body.core_contract.semantic_identity==$duty_policy[0].body.core_contract.semantic_identity and
  .body.core_contract.package_ref==$duty_policy[0].body.core_contract.package_ref and
  $generation_id_sha==$duty_policy[0].body.core_contract.generation_id_sha256
' "$scratch/policy-set.json" >/dev/null 2>&1 || emit_error E_RELATION

run_child "$jq_bin" -S -c -n -f "$scratch/program.jq" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile duty_policy "$scratch/duty-policy.json" \
  --slurpfile duty_decision "$scratch/duty-decision.json" \
  --slurpfile state "$scratch/state.json" \
  --slurpfile attempt "$scratch/attempt.json" \
  --slurpfile duty "$scratch/duty.json" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg duty_policy_sha "$duty_policy_sha" --arg duty_decision_sha "$duty_decision_sha" \
  --arg generation_id_sha "$generation_id_sha" \
  --arg policy_set_sha "$policy_set_sha" --arg state_sha "$state_sha" \
  --arg attempt_sha "$attempt_sha" --arg duty_sha "$duty_sha" \
  >"$scratch/evaluation.json" 2>/dev/null || emit_error E_RELATION

for fixed in "$policy:$policy_sha" "$decision:$decision_sha" "$program:$program_sha" \
  "$source_path:$driver_sha" "$duty_policy:$duty_policy_sha" \
  "$duty_decision:$duty_decision_sha" \
  "$policy_validator:$validator_driver_sha" "$validator_program:$validator_program_sha"; do
  fixed_path=${fixed%:*}
  fixed_sha=${fixed##*:}
  [ "$(sha256_path "$fixed_path")" = "$fixed_sha" ] || emit_error E_RELATION
done
validator_pair_ok "$mirror_validator_dir" "$mirror_policy_validator" \
  "$mirror_validator_program" "$validator_driver_sha" "$validator_program_sha" ||
  emit_error E_RELATION
canonical_one "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME
/usr/bin/cmp -s "$scratch/evaluation.json" "$scratch/evaluation.canonical" ||
  emit_error E_RUNTIME
run_child "$jq_bin" -e --arg policy_set_sha "$policy_set_sha" \
  --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" \
  --arg state_sha "$state_sha" --arg attempt_sha "$attempt_sha" --arg duty_sha "$duty_sha" \
  --slurpfile policy_set "$scratch/policy-set.json" \
  --slurpfile policy "$scratch/policy.json" \
  --slurpfile decision "$scratch/decision.json" \
  --slurpfile state "$scratch/state.json" \
  --slurpfile attempt "$scratch/attempt.json" \
  --slurpfile duty "$scratch/duty.json" '
  (keys|sort)==["body","id","kind","schema_version"] and
  .schema_version==1 and .kind=="kill_switch_evaluation" and
  .id==$attempt[0].id and
  (.body|keys|sort)==["activation_state","attempt_ref","authority_effect",
    "decision_ref","duty_decision_ref","duty_evaluation_ref","evaluation_mode",
    "policy_ref","policy_set","reason_ids","reference_semantics","state_ref","verdict"] and
  .body.activation_state=="inactive" and .body.authority_effect=="none" and
  .body.evaluation_mode=="observation-only" and .body.reference_semantics=="identity-only" and
  .body.policy_set=={id:$policy_set[0].id,sha256:$policy_set_sha} and
  .body.policy_ref=={content_id:$policy[0].id,
    media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
  .body.decision_ref=={content_id:$decision[0].id,
    media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha} and
  .body.duty_decision_ref==$policy[0].body.duty_decision_ref and
  .body.state_ref=={schema_version:$state[0].schema_version,kind:$state[0].kind,
    id:$state[0].id,sha256:$state_sha} and
  .body.attempt_ref=={schema_version:$attempt[0].schema_version,kind:$attempt[0].kind,
    id:$attempt[0].id,sha256:$attempt_sha} and
  .body.duty_evaluation_ref=={schema_version:$duty[0].schema_version,kind:$duty[0].kind,
    id:$duty[0].id,sha256:$duty_sha} and
  (.body.verdict as $verdict | $decision[0].body.semantics.verdicts|index($verdict)!=null) and
  (.body.reason_ids|type=="array" and length>=1 and .==(sort|unique) and
    all(.[];type=="string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z"))) and
  (if .body.verdict=="satisfied" then .body.reason_ids==["kill.cleared-current"]
   else (.body.reason_ids|index("kill.cleared-current")==null) end)
' "$scratch/evaluation.json" >/dev/null 2>&1 || emit_error E_RUNTIME
/bin/cat "$scratch/evaluation.json" || emit_error E_RUNTIME
trap - EXIT HUP INT TERM
cleanup
