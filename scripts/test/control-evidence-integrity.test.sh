#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_EVIDENCE_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_EVIDENCE_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 240; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-evidence-integrity.sh"
policy="$root/control/v1/evidence-integrity-policy.json"
definition="$root/control/v1/evidence-integrity-decision.json"
program="$root/control/v1/evidence-integrity.jq"
core_wrapper="$root/scripts/core-contract.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evidence-test.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
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
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")
for canonical_source in "$policy" "$definition"; do
  "$jq_bin" -S -c . "$canonical_source" >"$tmp/canonical"
  /usr/bin/cmp -s "$canonical_source" "$tmp/canonical" ||
    fail "canonical ${canonical_source##*/}"
done
for source_path in control/v1/evidence-integrity-policy.json \
  control/v1/evidence-integrity-decision.json control/v1/evidence-integrity.jq \
  control/v1/evaluate-evidence-integrity.sh scripts/test/control-evidence-integrity.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation $source_path"
done
pass 'canonical definitions and opaque core generation'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg policy_sha "$policy_sha" \
  --arg definition_sha "$definition_sha" --arg generation "$generation" \
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
       section("duty-separation";("2"*64);("b"*64)),
       section("evidence-integrity";$policy_sha;$definition_sha),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";("5"*64);("e"*64)),
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

request="$tmp/request.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-profile-graph-fixtures" as profile;
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("producer";$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end) |
  .body.qualification_ref=profile::scope("qualification";"qualification.test";("7"*64)) |
  .body.prior_evidence_refs=[{stage_result_ref:{schema_version:2,kind:"stage_result",
    id:"result.previous",sha256:("8"*64)},evidence_id:"evidence.previous"}]
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
presentation="$tmp/presentation.json"
"$jq_bin" -S -c -n --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
  --arg result_sha "$result_sha" --slurpfile request "$request" \
  --slurpfile resolved "$resolved" --slurpfile result "$result" '
  def doc($value;$sha):
    {schema_version:$value.schema_version,kind:$value.kind,id:$value.id,sha256:$sha};
  {schema_version:1,kind:"evidence_integrity_presentation",id:"evidence.presentation.test",
   body:{evidence:$result[0].body.evidence,
     prior_evidence_refs:$request[0].body.prior_evidence_refs,
     qualification_ref:{state:"present",value:$request[0].body.qualification_ref},
     request_ref:doc($request[0];$request_sha),
     resolved_profile_ref:doc($resolved[0];$resolved_sha),
     result_ref:doc($result[0];$result_sha)}}
' >"$presentation"

run_eval() {
  local name=$1 input=${2:-$presentation} runtime=${3:-$root}
  local out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$input" >"$out" 2>"$err" ||
    fail "$name status"
  [ ! -s "$err" ] || fail "$name stderr"
  "$jq_bin" -S -c . "$out" >"$tmp/$name.canonical"
  /usr/bin/cmp -s "$out" "$tmp/$name.canonical" || fail "$name canonical"
}
expect_error() {
  local name=$1 expected=$2 policy_input=${3:-$policy_set} request_input=${4:-$request}
  local resolved_input=${5:-$resolved} result_input=${6:-$result}
  local presentation_input=${7:-$presentation} runtime=${8:-$root} status=0
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_input" "$request_input" "$resolved_input" "$result_input" \
    "$presentation_input" >"$tmp/$name.out" 2>"$tmp/$name.err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/$name.out" ] &&
    [ "$(/bin/cat "$tmp/$name.err")" = "$expected" ] || fail "$name error"
  pass "$name"
}
pure_eval() {
  local input=$1 output=$2
  "$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
    --slurpfile decision "$definition" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --slurpfile result "$result" --slurpfile presentation "$input" \
    --arg policy_sha "$policy_sha" --arg decision_sha "$definition_sha" \
    --arg policy_set_sha "$(sha256_path "$policy_set")" --arg request_sha "$request_sha" \
    --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
    --arg presentation_sha "$(sha256_path "$input")" >"$output"
}
expect_pure_violation() {
  local name=$1 filter=$2 reason=$3
  local input="$tmp/$name.presentation" output="$tmp/$name.pure"
  "$jq_bin" -S -c "$filter" "$presentation" >"$input"
  pure_eval "$input" "$output"
  "$jq_bin" -e --arg reason "$reason" '
    .body.verdict=="violated" and (.body.reason_ids|index($reason)!=null) and
    .body.authority_effect=="none" and .body.storage_effect=="none" and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
  ' "$output" >/dev/null || fail "$name"
  pass "$name"
}

run_eval valid
"$jq_bin" -e '.body.verdict=="satisfied" and
  .body.reason_ids==["evidence.integrity-satisfied"] and
  .body.qualification_semantics=="identity-only-unqualified" and
  (.body.evidence_refs|length)==1' "$tmp/valid.out" >/dev/null || fail 'valid output'
pass 'valid exact immutable evidence presentation'

expect_pure_violation result-moved '.body.result_ref.sha256=("0"*64)' \
  evidence.result-moved
expect_pure_violation request-moved '.body.request_ref.sha256=("0"*64)' \
  evidence.request-moved
expect_pure_violation resolved-moved '.body.resolved_profile_ref.sha256=("0"*64)' \
  evidence.resolved-profile-moved
expect_pure_violation current-mismatch '.body.evidence[0].proof_ref.sha256=("0"*64)' \
  evidence.current-mismatch
expect_pure_violation prior-stale '.body.prior_evidence_refs[0].stage_result_ref.sha256=("0"*64)' \
  evidence.prior-stale
expect_pure_violation qualification-mismatch '.body.qualification_ref={state:"absent"}' \
  evidence.qualification-mismatch
expect_pure_violation malformed-presentation '.body.evidence=1' \
  evidence.presentation-malformed
expect_pure_violation ambiguous-presentation '.body.evidence += [.body.evidence[0]]' \
  evidence.presentation-ambiguous

malformed="$tmp/malformed.full"
"$jq_bin" -S -c '.body.evidence=1' "$presentation" >"$malformed"
run_eval malformed-full "$malformed"
"$jq_bin" -e '.body.verdict=="violated" and
  (.body.reason_ids|index("evidence.presentation-malformed")!=null)' \
  "$tmp/malformed-full.out" >/dev/null || fail 'malformed full output'
pass 'malformed presentation returns canonical fail-closed observation'

bad_result="$tmp/result.bad"
"$jq_bin" -S -c '.body.evidence[0].proof_ref.sha256="bad"' "$result" >"$bad_result"
expect_error malformed-core E_CORE "$policy_set" "$request" "$resolved" "$bad_result"

bad_policy_set="$tmp/policy-set.bad"
"$jq_bin" -S -c '.body.sections[] |=
  if .section_id=="evidence-integrity" then .decision_ref.sha256=("9"*64) else . end' \
  "$policy_set" >"$bad_policy_set"
expect_error policy-binding E_RELATION "$bad_policy_set"

link="$tmp/presentation-link.json"
/bin/ln -s "$presentation" "$link"
expect_error symlink-input E_RUNTIME "$policy_set" "$request" "$resolved" "$result" "$link"

relative_bin="$tmp/relative-bin"
/bin/mkdir "$relative_bin"
/bin/cp "$jq_bin" "$relative_bin/jq"
status=0
(cd "$relative_bin" && PATH=".:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation") >"$tmp/relative.out" \
  2>"$tmp/relative.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/relative.out" ] &&
  [ "$(/bin/cat "$tmp/relative.err")" = E_RUNTIME ] || fail 'relative jq rejection'
pass 'relative jq interpreter rejected'

copy_runtime() {
  local destination=$1 path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for path in evidence-integrity-policy.json evidence-integrity-decision.json \
    evidence-integrity.jq evaluate-evidence-integrity.sh validate.sh policy-set.jq; do
    /bin/cp "$root/control/v1/$path" "$destination/control/v1/$path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}
wait_marker() {
  local marker=$1 pid=$2 attempt=0
  while [ ! -e "$marker" ] && kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 400 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  [ -e "$marker" ]
}
wait_exit() {
  local pid=$1 attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  ! kill -0 "$pid" 2>/dev/null
}
make_delaying_jq() {
  local destination=$1 marker=$2 delay=$3
  /usr/bin/printf '%s\n' '#!/bin/bash' "real_jq='$jq_bin'" "marker='$marker'" \
    "delay='$delay'" \
    'if [ "${1:-}" = --version ]; then exec "$real_jq" "$@"; fi' \
    'for arg in "$@"; do' \
    '  case "$arg" in' \
    '    */program.jq) if [ ! -e "$marker" ]; then : >"$marker"; /bin/sleep "$delay"; fi ;;' \
    '  esac' \
    'done' \
    'exec "$real_jq" "$@"' >"$destination"
  /bin/chmod 0555 "$destination"
}

race_runtime="$tmp/race-runtime"
copy_runtime "$race_runtime"
race_bin="$tmp/race-bin"
race_marker="$tmp/race-marker"
/bin/mkdir "$race_bin"
make_delaying_jq "$race_bin/jq" "$race_marker" 1
(
  race_status=0
  PATH="$race_bin:/usr/bin:/bin" \
    "$race_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
    "$request" "$resolved" "$result" "$presentation" >"$tmp/race.out" \
    2>"$tmp/race.err" || race_status=$?
  /usr/bin/printf '%s\n' "$race_status" >"$tmp/race.status"
) &
race_pid=$!
wait_marker "$race_marker" "$race_pid" || {
  kill -TERM "$race_pid" 2>/dev/null || :
  wait "$race_pid" 2>/dev/null || :
  fail 'TOCTOU marker'
}
/usr/bin/printf '\n' >>"$race_runtime/control/v1/evidence-integrity.jq"
wait "$race_pid"
[ "$(/bin/cat "$tmp/race.status")" -ne 0 ] && [ ! -s "$tmp/race.out" ] &&
  [ "$(/bin/cat "$tmp/race.err")" = E_RELATION ] || fail 'TOCTOU closure'
pass 'program mutation closes after snapshot execution'

signal_runtime="$tmp/signal-runtime"
copy_runtime "$signal_runtime"
signal_bin="$tmp/signal-bin"
signal_scratch="$tmp/signal-scratch"
signal_marker="$tmp/signal-marker"
/bin/mkdir "$signal_bin" "$signal_scratch"
make_delaying_jq "$signal_bin/jq" "$signal_marker" 2
TMPDIR="$signal_scratch" PATH="$signal_bin:/usr/bin:/bin" \
  "$signal_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation" >"$tmp/signal.out" \
  2>"$tmp/signal.err" &
signal_pid=$!
wait_marker "$signal_marker" "$signal_pid" || {
  kill -TERM "$signal_pid" 2>/dev/null || :
  wait "$signal_pid" 2>/dev/null || :
  fail 'signal marker'
}
kill -TERM "$signal_pid"
wait_exit "$signal_pid" || {
  kill -KILL "$signal_pid" 2>/dev/null || :
  wait "$signal_pid" 2>/dev/null || :
  fail 'signal bounded exit'
}
signal_status=0
wait "$signal_pid" || signal_status=$?
[ "$signal_status" -ne 0 ] && [ ! -s "$tmp/signal.out" ] &&
  [ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'signal cleanup'
pass 'signal lifecycle is bounded and removes private scratch'

/usr/bin/printf 'control evidence integrity: %s passed\n' "$passes"
