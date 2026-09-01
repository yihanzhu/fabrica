#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_CREDENTIAL_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_CREDENTIAL_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 180; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-credential-policy.sh"
duty_evaluator="$root/control/v1/evaluate-duty.sh"
policy="$root/control/v1/credential-policy.json"
decision="$root/control/v1/credential-policy-decision.json"
program="$root/control/v1/credential-policy.jq"
duty_policy="$root/control/v1/duty-separation-policy.json"
duty_decision="$root/control/v1/duty-separation-decision.json"
core_wrapper="$root/scripts/core-contract.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-credential-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
INPUT_RACE_PID=
INPUT_RACE_PGID=
INPUT_RACE_STATUS=
TEST_PGID=$(/bin/ps -o pgid= -p $$ 2>/dev/null | /usr/bin/tr -d ' ') || exit 1
[[ "$TEST_PGID" =~ ^[1-9][0-9]*$ ]] || exit 1
group_alive() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && /bin/kill -0 -- "-$1" 2>/dev/null
}
terminate_input_race() {
  local leader=$1 group=$2 attempt=0
  [[ "$leader" =~ ^[1-9][0-9]*$ ]] && [[ "$group" =~ ^[1-9][0-9]*$ ]] &&
    [ "$leader" = "$group" ] && [ "$group" != "$TEST_PGID" ] || return 1
  /bin/kill -TERM -- "-$group" 2>/dev/null || :
  /bin/kill -CONT -- "-$group" 2>/dev/null || :
  while group_alive "$group" && [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  if group_alive "$group"; then
    /bin/kill -KILL -- "-$group" 2>/dev/null || :
    attempt=0
    while group_alive "$group" && [ "$attempt" -lt 100 ]; do
      attempt=$((attempt + 1))
      /bin/sleep 0.01
    done
  fi
  wait "$leader" 2>/dev/null || :
  ! group_alive "$group"
}
cleanup() {
  if [ -n "${INPUT_RACE_PID:-}" ] || [ -n "${INPUT_RACE_PGID:-}" ]; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
  fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT HUP INT TERM
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

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
/bin/mkdir -m 0700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core_wrapper") ||
  fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
policy_sha=$(sha256_path "$policy")
decision_sha=$(sha256_path "$decision")
duty_policy_sha=$(sha256_path "$duty_policy")
duty_decision_sha=$(sha256_path "$duty_decision")
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")

for canonical_source in "$policy" "$decision"; do
  "$jq_bin" -S -c . "$canonical_source" >"$tmp/canonical"
  /usr/bin/cmp -s "$canonical_source" "$tmp/canonical" ||
    fail "canonical ${canonical_source##*/}"
done
for source_path in control/v1/credential-policy.json \
  control/v1/credential-policy-decision.json control/v1/credential-policy.jq \
  control/v1/evaluate-credential-policy.sh \
  scripts/test/control-credential-policy.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation $source_path"
done
pass 'canonical definitions and opaque generation identity'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg credential_policy_sha "$policy_sha" \
  --arg credential_decision_sha "$decision_sha" \
  --arg duty_policy_sha "$duty_policy_sha" \
  --arg duty_decision_sha "$duty_decision_sha" --arg generation "$generation" \
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
     sections:[section("credential-policy";$credential_policy_sha;$credential_decision_sha),
       section("duty-separation";$duty_policy_sha;$duty_decision_sha),
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
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("producer";$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$request"
request_sha=$(sha256_path "$request")
result="$tmp/result.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$request" --slurpfile resolved "$resolved" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$result"
result_sha=$(sha256_path "$result")
duty="$tmp/duty.json"
PATH="$bin:/usr/bin:/bin" "$duty_evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" >"$duty" 2>"$tmp/duty.err" || {
    /bin/cat "$tmp/duty.err" >&2
    fail 'build duty evaluation'
  }
duty_sha=$(sha256_path "$duty")

claim="$tmp/claim.json"
"$jq_bin" -S -c -n --slurpfile set "$policy_set" --slurpfile duty "$duty" \
  --slurpfile result "$result" --slurpfile resolved "$resolved" \
  --arg set_sha "$policy_set_sha" --arg duty_sha "$duty_sha" \
  --arg result_sha "$result_sha" '
  def doc($document;$sha):
    {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,sha256:$sha};
  def actor($entry):
    {role:$entry.binding.role,implementation_id:$entry.adapter_implementation.id,
     implementation_version:$entry.adapter_implementation.version,
     adapter_instance_id:$entry.binding.adapter_instance_id,
     principal_id:$entry.binding.principal_id,
     execution_boundary_id:$entry.binding.execution_boundary_id};
  {schema_version:1,kind:"credential_boundary_claim",id:"credential-claim.test",
   body:{accesses:[$resolved[0].body.bindings[] |
       {actor:actor(.),binding_id:.binding.binding_id,
        credentials:(if .binding.execution_kind=="model" and
          (.binding.role=="producer" or .binding.role=="reviewer")
          then [{credential_class:"model-inference",delivery:"brokered",
            exposure:"none",scope:"single-stage"}] else [] end)}] | sort_by(.binding_id),
     activation_state:"inactive",declaration_status:"complete",
     duty_evaluation_ref:doc($duty[0];$duty_sha),
     policy_set_ref:doc($set[0];$set_sha),
     stage_result_ref:doc($result[0];$result_sha)}}
' >"$claim"

run_driver() {
  local name=$1 claim_path=${2:-$claim} duty_path=${3:-$duty}
  local runtime=${4:-$root} run_status=0 out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-credential-policy.sh" \
    evaluate "$policy_set" "$request" "$resolved" "$result" "$duty_path" \
    "$claim_path" >"$out" 2>"$err" || run_status=$?
  [ "$run_status" -eq 0 ] && [ ! -s "$err" ] || {
    /bin/cat "$err" >&2
    fail "$name driver"
  }
}

run_pure() {
  local name=$1 claim_path=$2 expected=$3 reason=$4 duty_path=${5:-$duty}
  local pure_claim_sha pure_duty_sha
  pure_claim_sha=$(sha256_path "$claim_path")
  pure_duty_sha=$(sha256_path "$duty_path")
  "$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
    --slurpfile decision "$decision" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --slurpfile result "$result" --slurpfile duty "$duty_path" \
    --slurpfile claim "$claim_path" --arg policy_sha "$policy_sha" \
    --arg decision_sha "$decision_sha" --arg policy_set_sha "$policy_set_sha" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    --arg result_sha "$result_sha" --arg duty_sha "$pure_duty_sha" \
    --arg claim_sha "$pure_claim_sha" >"$tmp/$name.out" 2>"$tmp/$name.err" || {
      /bin/cat "$tmp/$name.err" >&2
      fail "$name pure status"
    }
  [ ! -s "$tmp/$name.err" ] || fail "$name pure stderr"
  "$jq_bin" -e --arg expected "$expected" --arg reason "$reason" '
    .body.verdict==$expected and (.body.reason_ids|index($reason)!=null) and
    .body.reason_ids==(.body.reason_ids|sort|unique) and
    .body.activation_state=="inactive" and .body.authority_effect=="none" and
    .body.qualification_effect=="none" and
    ((.body|has("grant_ref") or has("activation") or has("credential_ref"))|not)
  ' "$tmp/$name.out" >/dev/null || fail "$name pure verdict"
  pass "$name"
}

mutate_claim() {
  local name=$1 filter=$2 destination
  destination="$tmp/$name.claim"
  "$jq_bin" -S -c "$filter" "$claim" >"$destination"
  /usr/bin/printf '%s\n' "$destination"
}

start_input_race() {
  local name=$1 scratch_root=$2 claim_path=$3 gate leader pgid attempt=0
  gate="$tmp/$name.launch.gate"
  INPUT_RACE_OUT="$tmp/$name.out"
  INPUT_RACE_ERR="$tmp/$name.err"
  /usr/bin/mkfifo "$gate" || fail "$name launch gate"
  exec 8<>"$gate" || fail "$name launch gate open"
  set -m
  /bin/bash -c '
    IFS= read -r token <&8 || exit 125
    exec 8>&-
    [ "$token" = go ] || exit 125
    race_tmp=$1
    race_path=$2
    shift 2
    TMPDIR=$race_tmp PATH=$race_path exec "$@"
  ' input-race "$scratch_root" "$bin:/usr/bin:/bin" "$evaluator" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim_path" \
    >"$INPUT_RACE_OUT" 2>"$INPUT_RACE_ERR" &
  leader=$!
  set +m
  pgid=
  while [ -z "$pgid" ] && /bin/kill -0 "$leader" 2>/dev/null &&
    [ "$attempt" -lt 100 ]; do
    pgid=$(/bin/ps -o pgid= -p "$leader" 2>/dev/null |
      /usr/bin/tr -d ' ') || pgid=
    [ -n "$pgid" ] || /bin/sleep 0.01
    attempt=$((attempt + 1))
  done
  if [[ ! "$pgid" =~ ^[1-9][0-9]*$ ]] || [ "$pgid" != "$leader" ] ||
     [ "$pgid" = "$TEST_PGID" ]; then
    /usr/bin/printf 'abort\n' >&8 || :
    exec 8>&-
    /bin/rm -f -- "$gate"
    /bin/kill -KILL "$leader" 2>/dev/null || :
    wait "$leader" 2>/dev/null || :
    fail "$name unsafe evaluator process group"
  fi
  INPUT_RACE_PID=$leader
  INPUT_RACE_PGID=$pgid
  /usr/bin/printf 'go\n' >&8 || {
    exec 8>&-
    /bin/rm -f -- "$gate"
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name launch release"
  }
  exec 8>&-
  /bin/rm -f -- "$gate"
}

stop_at_input_pending() {
  local name=$1 scratch_root=$2 attempt=0 marker owner state stop_attempt=0
  marker=
  while [ -z "$marker" ] && [ "$attempt" -lt 5000 ]; do
    marker=$(/usr/bin/find "$scratch_root" -type f -name input-snapshot-pending \
      -print -quit 2>/dev/null) || marker=
    if [ -z "$marker" ] && ! /bin/kill -0 "$INPUT_RACE_PID" 2>/dev/null; then
      wait "$INPUT_RACE_PID" 2>/dev/null || :
      INPUT_RACE_PID=
      INPUT_RACE_PGID=
      fail "$name evaluator exited before input snapshot marker"
    fi
    [ -n "$marker" ] || /bin/sleep 0.001
    attempt=$((attempt + 1))
  done
  [ -n "$marker" ] || {
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name input snapshot marker timeout"
  }
  case "$marker" in "$scratch_root"/*/input-snapshot-pending) ;; *)
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name marker escaped scratch"
  esac
  owner=$(/bin/cat "$marker")
  [ "$owner" = "$INPUT_RACE_PID" ] || {
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name marker owner mismatch"
  }
  /bin/kill -STOP -- "-$INPUT_RACE_PGID" || fail "$name stop evaluator group"
  state=
  while [ "$stop_attempt" -lt 100 ]; do
    state=$(/bin/ps -o state= -p "$INPUT_RACE_PID" 2>/dev/null |
      /usr/bin/tr -d ' ') || state=
    case "$state" in T*) break ;; esac
    /bin/sleep 0.01
    stop_attempt=$((stop_attempt + 1))
  done
  case "$state" in T*) ;; *)
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name evaluator group did not stop"
  esac
  if /usr/bin/find "$scratch_root" -type f -name input-snapshot-ready -print -quit |
    /usr/bin/grep -q .; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name missed guarded input window"
  fi
}

resume_and_wait_input_race() {
  local name=$1 attempt=0 state status=0
  /bin/kill -CONT -- "-$INPUT_RACE_PGID" || fail "$name resume evaluator group"
  while [ "$attempt" -lt 1000 ]; do
    state=$(/bin/ps -o state= -p "$INPUT_RACE_PID" 2>/dev/null |
      /usr/bin/tr -d ' ') || state=
    case "$state" in ''|Z*) break ;; esac
    /bin/sleep 0.01
    attempt=$((attempt + 1))
  done
  if [ "$attempt" -ge 1000 ]; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name evaluator completion timeout"
  fi
  wait "$INPUT_RACE_PID" 2>/dev/null || status=$?
  if group_alive "$INPUT_RACE_PGID"; then
    terminate_input_race "$INPUT_RACE_PID" "$INPUT_RACE_PGID" || :
    INPUT_RACE_PID=
    INPUT_RACE_PGID=
    fail "$name evaluator left descendants"
  fi
  INPUT_RACE_STATUS=$status
  INPUT_RACE_PID=
  INPUT_RACE_PGID=
}

run_driver baseline
"$jq_bin" -e '.body.verdict=="inconclusive" and
  .body.reason_ids==["claim.provenance-unqualified"] and
  .kind=="credential_policy_evaluation"' "$tmp/baseline.out" >/dev/null ||
  fail 'baseline observation'
"$jq_bin" -S -c . "$tmp/baseline.out" >"$tmp/baseline.canonical"
/usr/bin/cmp -s "$tmp/baseline.out" "$tmp/baseline.canonical" ||
  fail 'baseline canonical output'
pass 'baseline remains provenance-unqualified'

YSTACK_TEST_CREDENTIAL='synthetic-must-not-be-read' run_driver ambient-environment
/usr/bin/cmp -s "$tmp/baseline.out" "$tmp/ambient-environment.out" ||
  fail 'ambient environment changed output'
pass 'ambient credential-like environment is ignored'

perl_inject_dir="$tmp/perl-inject"
perl_inject_marker="$tmp/perl-inject.marker"
/bin/mkdir "$perl_inject_dir"
/usr/bin/printf '%s\n' 'package YStackInjected;' \
  "BEGIN { open(my \$fh, '>', '$perl_inject_marker') or die; print \$fh 'loaded'; close \$fh; }" \
  '1;' >"$perl_inject_dir/YStackInjected.pm"
PERL5LIB="$perl_inject_dir" PERLLIB="$perl_inject_dir" \
  PERL5OPT=-MYStackInjected run_driver perl-environment
if [ -e "$perl_inject_marker" ] ||
   ! /usr/bin/cmp -s "$tmp/baseline.out" "$tmp/perl-environment.out"; then
  fail 'ambient Perl injection'
fi
pass 'Perl helper environment is cleared'

run_pure baseline-pure "$claim" inconclusive claim.provenance-unqualified
bad=$(mutate_claim incomplete '.body.declaration_status="incomplete" |
  .body.accesses=(.body.accesses[0:1])')
run_pure incomplete "$bad" inconclusive claim.incomplete
bad=$(mutate_claim malformed-access '.body.accesses[0].credentials="bad"')
run_pure malformed-access "$bad" violated claim.malformed
run_driver malformed-driver "$bad"
"$jq_bin" -e '.body.verdict=="violated" and
  (.body.reason_ids|index("claim.malformed")!=null)' "$tmp/malformed-driver.out" \
  >/dev/null || fail 'malformed driver verdict'
pass 'malformed claim returns a canonical violation'
bad=$(mutate_claim direct '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].delivery="direct" else . end')
run_pure direct "$bad" violated credential.direct-delivery
bad=$(mutate_claim exposed '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].exposure="present" else . end')
run_pure exposed "$bad" violated credential.material-exposed
bad=$(mutate_claim persistent '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].scope="persistent" else . end')
run_pure persistent "$bad" violated credential.scope-denied
bad=$(mutate_claim wrong-class '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].credential_class="forge-write" else . end')
run_pure wrong-class "$bad" violated credential.ceiling-denied
bad=$(mutate_claim wrong-class-unknown '.body.accesses[] |=
  if (.credentials|length)>0 then
    .credentials[0].credential_class="forge-write" |
    .credentials[0].delivery="unknown"
  else . end')
run_pure wrong-class-unknown "$bad" violated credential.class-role-denied
bad=$(mutate_claim verifier-access '.body.accesses[] |=
  if .actor.role=="verifier" then .credentials=[{credential_class:"model-inference",
    delivery:"brokered",exposure:"none",scope:"single-stage"}] else . end')
run_pure verifier-access "$bad" violated credential.incompatible-permission
bad=$(mutate_claim actor-mismatch '.body.accesses[0].actor.principal_id="principal.other"')
run_pure actor-mismatch "$bad" violated claim.actor-or-binding-mismatch
bad=$(mutate_claim missing-binding 'del(.body.accesses[0])')
run_pure missing-binding "$bad" violated claim.binding-set-incomplete
bad=$(mutate_claim extra-binding '.body.accesses += [{actor:.body.accesses[0].actor,
  binding_id:"binding.extra",credentials:[]}] | .body.accesses|=sort_by(.binding_id)')
run_pure extra-binding "$bad" violated claim.binding-extra
bad=$(mutate_claim stale-set '.body.policy_set_ref.sha256=("0"*64)')
run_pure stale-set "$bad" violated claim.policy-set-ref-mismatch
bad=$(mutate_claim stale-duty '.body.duty_evaluation_ref.sha256=("0"*64)')
run_pure stale-duty "$bad" violated claim.duty-ref-mismatch
bad=$(mutate_claim stale-result '.body.stage_result_ref.sha256=("0"*64)')
run_pure stale-result "$bad" violated claim.stage-result-ref-mismatch
bad=$(mutate_claim unknown '.body.accesses[] |=
  if (.credentials|length)>0 then .credentials[0].delivery="unknown" else . end')
run_pure unknown "$bad" inconclusive credential.access-unknown

duty_violated="$tmp/duty-violated.json"
"$jq_bin" -S -c '.body.verdict="violated" |
  .body.reason_ids=["publisher.requested"]' "$duty" >"$duty_violated"
duty_violated_sha=$(sha256_path "$duty_violated")
duty_violated_claim="$tmp/duty-violated.claim"
"$jq_bin" -S -c --arg sha "$duty_violated_sha" \
  '.body.duty_evaluation_ref.sha256=$sha' "$claim" >"$duty_violated_claim"
run_pure duty-violated "$duty_violated_claim" violated duty.violated "$duty_violated"
duty_inconclusive="$tmp/duty-inconclusive.json"
"$jq_bin" -S -c '.body.verdict="inconclusive" |
  .body.reason_ids=["actual.capability-unclassified"]' "$duty" >"$duty_inconclusive"
duty_inconclusive_sha=$(sha256_path "$duty_inconclusive")
duty_inconclusive_claim="$tmp/duty-inconclusive.claim"
"$jq_bin" -S -c --arg sha "$duty_inconclusive_sha" \
  '.body.duty_evaluation_ref.sha256=$sha' "$claim" >"$duty_inconclusive_claim"
run_pure duty-inconclusive "$duty_inconclusive_claim" inconclusive duty.inconclusive \
  "$duty_inconclusive"

while IFS= read -r output; do
  "$jq_bin" -e '.body.verdict != "satisfied" and
    (.body.reason_ids | index("credential-policy.satisfied") == null)' "$output" \
    >/dev/null || fail "claim synthesized satisfied ${output##*/}"
done < <(/usr/bin/find "$tmp" -type f -name '*.out' -print)
pass 'no claim-only path can synthesize satisfied'

forged_duty="$tmp/forged-duty.json"
"$jq_bin" -S -c '.body.reason_ids=["forged"] | .body.verdict="violated"' \
  "$duty" >"$forged_duty"
forged_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$forged_duty" "$claim" >"$tmp/forged.out" \
  2>"$tmp/forged.err" || forged_status=$?
[ "$forged_status" -ne 0 ] && [ ! -s "$tmp/forged.out" ] &&
  [ "$(/bin/cat "$tmp/forged.err")" = E_DUTY ] || fail 'forged duty rejection'
pass 'forged duty is rejected'

noncanonical="$tmp/noncanonical.json"
"$jq_bin" . "$claim" >"$noncanonical"
canonical_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$noncanonical" >"$tmp/noncanonical.out" \
  2>"$tmp/noncanonical.err" || canonical_status=$?
[ "$canonical_status" -ne 0 ] && [ ! -s "$tmp/noncanonical.out" ] &&
  [ "$(/bin/cat "$tmp/noncanonical.err")" = E_CANONICAL ] ||
  fail 'noncanonical rejection'
pass 'noncanonical input is rejected'

malformed_json="$tmp/malformed.json"
/usr/bin/printf '{' >"$malformed_json"
[ "$(/usr/bin/wc -c <"$malformed_json" | /usr/bin/tr -d ' ')" -eq 1 ] &&
  [ "$(/usr/bin/od -An -tx1 "$malformed_json" | /usr/bin/tr -d ' \n')" = 7b ] ||
  fail 'malformed JSON fixture bytes'
parse_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$malformed_json" >"$tmp/parse.out" \
  2>"$tmp/parse.err" || parse_status=$?
[ "$parse_status" -ne 0 ] && [ ! -s "$tmp/parse.out" ] &&
  [ "$(/bin/cat "$tmp/parse.err")" = E_PARSE ] || fail 'malformed JSON rejection'
pass 'malformed JSON is rejected'

oversize="$tmp/oversize.json"
/bin/dd if=/dev/zero of="$oversize" bs=1048577 count=1 2>/dev/null
oversize_scratch="$tmp/oversize-scratch"
/bin/mkdir "$oversize_scratch"
oversize_status=0
TMPDIR="$oversize_scratch" PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$duty" "$oversize" \
  >"$tmp/oversize.out" 2>"$tmp/oversize.err" || oversize_status=$?
[ "$oversize_status" -ne 0 ] && [ ! -s "$tmp/oversize.out" ] &&
  [ "$(/bin/cat "$tmp/oversize.err")" = E_LIMIT ] &&
  [ -z "$(/usr/bin/find "$oversize_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'oversize input bound'
pass 'oversize input stops at the one-megabyte boundary'

swap_claim="$tmp/swap-claim.json"
swap_backup="$tmp/swap-claim.backup"
swap_replacement="$tmp/swap-claim.replacement"
swap_target="$tmp/synthetic-sensitive.json"
/bin/cp "$claim" "$swap_claim"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' >"$swap_target"
swap_scratch="$tmp/swap-scratch"
/bin/mkdir "$swap_scratch"
start_input_race path-swap "$swap_scratch" "$swap_claim"
stop_at_input_pending path-swap "$swap_scratch"
/bin/mv "$swap_claim" "$swap_backup"
/bin/cp "$swap_target" "$swap_claim"
if [ -L "$swap_claim" ] || ! /usr/bin/cmp -s "$swap_target" "$swap_claim"; then
  fail 'path-swap replacement'
fi
resume_and_wait_input_race path-swap
/bin/mv "$swap_claim" "$swap_replacement"
/bin/mv "$swap_backup" "$swap_claim"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/path-swap.out" ] ||
   [ "$(/bin/cat "$tmp/path-swap.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$claim" "$swap_claim" ||
   ! /usr/bin/cmp -s "$swap_target" "$swap_replacement"; then
  fail 'transient path swap'
fi
[ -z "$(/usr/bin/find "$swap_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'path-swap scratch cleanup'
pass 'gated regular-file replacement is rejected before read and fully restored'

inplace_claim="$tmp/inplace-claim.json"
inplace_backup="$tmp/inplace-claim.backup"
/bin/cp "$claim" "$inplace_claim"
/bin/cp "$claim" "$inplace_backup"
inplace_scratch="$tmp/inplace-scratch"
/bin/mkdir "$inplace_scratch"
start_input_race same-inode "$inplace_scratch" "$inplace_claim"
stop_at_input_pending same-inode "$inplace_scratch"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' >"$inplace_claim"
if /usr/bin/cmp -s "$inplace_backup" "$inplace_claim"; then
  fail 'same-inode mutation did not change bytes'
fi
resume_and_wait_input_race same-inode
/bin/cp "$inplace_backup" "$inplace_claim"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/same-inode.out" ] ||
   [ "$(/bin/cat "$tmp/same-inode.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$inplace_backup" "$inplace_claim"; then
  fail 'same-inode content replacement'
fi
[ -z "$(/usr/bin/find "$inplace_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'same-inode scratch cleanup'
pass 'gated same-inode mutation is rejected before read and fully restored'

parent_swap_dir="$tmp/parent-swap"
parent_swap_backup="$tmp/parent-swap.original"
parent_swap_replacement="$tmp/parent-swap.replacement"
/bin/mkdir "$parent_swap_dir"
/bin/cp "$claim" "$parent_swap_dir/claim.json"
parent_swap_scratch="$tmp/parent-swap-scratch"
/bin/mkdir "$parent_swap_scratch"
start_input_race parent-swap "$parent_swap_scratch" "$parent_swap_dir/claim.json"
stop_at_input_pending parent-swap "$parent_swap_scratch"
/bin/mv "$parent_swap_dir" "$parent_swap_backup"
/bin/mkdir "$parent_swap_dir"
/usr/bin/printf '%s\n' '{"synthetic_secret":"must-not-be-read"}' \
  >"$parent_swap_dir/claim.json"
resume_and_wait_input_race parent-swap
/bin/mv "$parent_swap_dir" "$parent_swap_replacement"
/bin/mv "$parent_swap_backup" "$parent_swap_dir"
if [ "$INPUT_RACE_STATUS" -eq 0 ] || [ -s "$tmp/parent-swap.out" ] ||
   [ "$(/bin/cat "$tmp/parent-swap.err")" != E_RUNTIME ] ||
   ! /usr/bin/cmp -s "$claim" "$parent_swap_dir/claim.json" ||
   ! /usr/bin/grep -Fq synthetic_secret "$parent_swap_replacement/claim.json"; then
  fail 'transient parent replacement'
fi
[ -z "$(/usr/bin/find "$parent_swap_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'parent-swap scratch cleanup'
pass 'gated parent-directory replacement is rejected before read and fully restored'

link="$tmp/claim-link.json"
/bin/ln -s "$claim" "$link"
link_status=0
PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$link" >"$tmp/link.out" \
  2>"$tmp/link.err" || link_status=$?
[ "$link_status" -ne 0 ] && [ ! -s "$tmp/link.out" ] &&
  [ "$(/bin/cat "$tmp/link.err")" = E_RUNTIME ] || fail 'symlink rejection'
pass 'symlink input is rejected'

fake_bin="$tmp/fake-bin"
/bin/mkdir "$fake_bin"
/usr/bin/printf '%s\n' '#!/bin/bash' 'printf "jq-1.6\n"' >"$fake_bin/jq"
/bin/chmod 0555 "$fake_bin/jq"
fake_status=0
PATH="$fake_bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$duty" "$claim" >"$tmp/fake.out" \
  2>"$tmp/fake.err" || fake_status=$?
[ "$fake_status" -ne 0 ] && [ ! -s "$tmp/fake.out" ] &&
  [ "$(/bin/cat "$tmp/fake.err")" = E_RUNTIME ] || fail 'jq digest rejection'
pass 'interpreter identity is pinned'

copy_runtime() {
  local destination=$1 copy_path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for copy_path in credential-policy.json credential-policy-decision.json \
    credential-policy.jq evaluate-credential-policy.sh duty-separation-policy.json \
    duty-separation-decision.json duty-separation.jq evaluate-duty.sh validate.sh \
    policy-set.jq; do
    /bin/cp "$root/control/v1/$copy_path" "$destination/control/v1/$copy_path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}

binding_runtime="$tmp/binding-runtime"
copy_runtime "$binding_runtime"
binding_scratch="$tmp/binding-scratch"
/bin/mkdir "$binding_scratch"
(
  binding_status=0
  TMPDIR="$binding_scratch" PATH="$bin:/usr/bin:/bin" \
    "$binding_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
    >"$tmp/binding.out" 2>"$tmp/binding.err" || binding_status=$?
  /usr/bin/printf '%s\n' "$binding_status" >"$tmp/binding.status"
) &
binding_pid=$!
binding_marker=
binding_attempt=0
while [ -z "$binding_marker" ] && /bin/kill -0 "$binding_pid" 2>/dev/null &&
  [ "$binding_attempt" -lt 1000 ]; do
  binding_marker=$(/usr/bin/find "$binding_scratch" -type f \
    -name runtime-bindings-ready -print -quit 2>/dev/null)
  [ -n "$binding_marker" ] || /bin/sleep 0.01
  binding_attempt=$((binding_attempt + 1))
done
[ -n "$binding_marker" ] || fail 'runtime binding marker'
/usr/bin/printf '\n' >>"$binding_runtime/control/v1/duty-separation.jq"
wait "$binding_pid"
[ "$(/bin/cat "$tmp/binding.status")" -ne 0 ] && [ ! -s "$tmp/binding.out" ] &&
  [ "$(/bin/cat "$tmp/binding.err")" = E_RELATION ] ||
  fail 'decision-bound runtime mutation'
[ -z "$(/usr/bin/find "$binding_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'runtime binding scratch cleanup'
pass 'decision-bound runtime mutation closes before execution'

race_runtime="$tmp/race-runtime"
copy_runtime "$race_runtime"
race_scratch="$tmp/race-scratch"
/bin/mkdir "$race_scratch"
(
  race_status=0
  TMPDIR="$race_scratch" PATH="$bin:/usr/bin:/bin" \
    "$race_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
    >"$tmp/race.out" 2>"$tmp/race.err" || race_status=$?
  /usr/bin/printf '%s\n' "$race_status" >"$tmp/race.status"
) &
race_pid=$!
race_marker=
race_attempt=0
while [ -z "$race_marker" ] && /bin/kill -0 "$race_pid" 2>/dev/null &&
  [ "$race_attempt" -lt 1000 ]; do
  race_marker=$(/usr/bin/find "$race_scratch" -type f -name duty-ready -print -quit \
    2>/dev/null)
  [ -n "$race_marker" ] || /bin/sleep 0.01
  race_attempt=$((race_attempt + 1))
done
[ -n "$race_marker" ] || fail 'TOCTOU marker'
/usr/bin/printf '\n' >>"$race_runtime/control/v1/credential-policy.jq"
wait "$race_pid"
[ "$(/bin/cat "$tmp/race.status")" -ne 0 ] && [ ! -s "$tmp/race.out" ] &&
  [ "$(/bin/cat "$tmp/race.err")" = E_RELATION ] || fail 'TOCTOU closure'
[ -z "$(/usr/bin/find "$race_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'TOCTOU scratch cleanup'
pass 'TOCTOU mutation closes and cleans scratch'

signal_runtime="$tmp/signal-runtime"
copy_runtime "$signal_runtime"
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
TMPDIR="$signal_scratch" PATH="$bin:/usr/bin:/bin" \
  "$signal_runtime/control/v1/evaluate-credential-policy.sh" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$duty" "$claim" \
  >"$tmp/signal.out" 2>"$tmp/signal.err" &
signal_pid=$!
signal_marker=
signal_attempt=0
while [ -z "$signal_marker" ] && /bin/kill -0 "$signal_pid" 2>/dev/null &&
  [ "$signal_attempt" -lt 5000 ]; do
  signal_marker=$(/usr/bin/find "$signal_scratch" -type f -name child-launching \
    -print -quit 2>/dev/null)
  [ -n "$signal_marker" ] || /bin/sleep 0.001
  signal_attempt=$((signal_attempt + 1))
done
[ -n "$signal_marker" ] || fail 'signal marker'
signal_child=
signal_child_attempt=0
while [ -z "$signal_child" ] && /bin/kill -0 "$signal_pid" 2>/dev/null &&
  [ "$signal_child_attempt" -lt 1000 ]; do
  signal_child=$(/usr/bin/pgrep -P "$signal_pid" | /usr/bin/head -n 1 || :)
  [ -n "$signal_child" ] || /bin/sleep 0.001
  signal_child_attempt=$((signal_child_attempt + 1))
done
[[ "$signal_child" =~ ^[1-9][0-9]*$ ]] || fail 'signal child identity'
signal_child_pgid=$(/bin/ps -o pgid= -p "$signal_child" | /usr/bin/tr -d ' ')
[[ "$signal_child_pgid" =~ ^[1-9][0-9]*$ ]] &&
  [ "$signal_child_pgid" = "$signal_child" ] || fail 'signal child group'
for _ in 1 2 3; do /bin/kill -TERM "$signal_pid" 2>/dev/null || :; done
signal_wait=0
while /bin/kill -0 "$signal_pid" 2>/dev/null && [ "$signal_wait" -lt 1000 ]; do
  signal_wait=$((signal_wait + 1))
  /bin/sleep 0.01
done
if /bin/kill -0 "$signal_pid" 2>/dev/null; then
  /bin/kill -KILL "$signal_pid" 2>/dev/null || :
  wait "$signal_pid" 2>/dev/null || :
  fail 'signal termination deadline'
fi
signal_status=0
wait "$signal_pid" 2>/dev/null || signal_status=$?
[ "$signal_status" -eq 143 ] && [ ! -s "$tmp/signal.out" ] &&
  [ ! -s "$tmp/signal.err" ] &&
  ! /bin/kill -0 -- "-$signal_child_pgid" 2>/dev/null &&
  [ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'signal cleanup'
pass 'launch-window signal reaps the full child group and scratch'

/usr/bin/printf 'control credential policy: %s passed\n' "$passes"
