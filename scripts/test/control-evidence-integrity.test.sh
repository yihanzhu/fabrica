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
  local name=$1 input=${2:-$presentation} runtime=${3:-$root} run_status=0
  local out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$input" >"$out" 2>"$err" ||
    run_status=$?
  if [ "$run_status" -ne 0 ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$run_status" >&2
    /bin/cat "$err" >&2
    fail "$name status"
  fi
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
pure_eval_tuple() {
  local request_input=$1 result_input=$2 presentation_input=$3 output=$4
  local request_digest result_digest
  request_digest=$(sha256_path "$request_input")
  result_digest=$(sha256_path "$result_input")
  "$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
    --slurpfile decision "$definition" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$request_input" --slurpfile resolved "$resolved" \
    --slurpfile result "$result_input" --slurpfile presentation "$presentation_input" \
    --arg policy_sha "$policy_sha" --arg decision_sha "$definition_sha" \
    --arg policy_set_sha "$(sha256_path "$policy_set")" \
    --arg request_sha "$request_digest" --arg resolved_sha "$resolved_sha" \
    --arg result_sha "$result_digest" \
    --arg presentation_sha "$(sha256_path "$presentation_input")" >"$output"
}
expect_pure_violation() {
  local name=$1 filter=$2 reason=$3 second_reason=${4:-}
  local input="$tmp/$name.presentation" output="$tmp/$name.pure"
  "$jq_bin" -S -c "$filter" "$presentation" >"$input"
  pure_eval "$input" "$output"
  "$jq_bin" -e --arg reason "$reason" --arg second "$second_reason" '
    .body.verdict=="violated" and (.body.reason_ids|index($reason)!=null) and
    ($second=="" or (.body.reason_ids|index($second)!=null)) and
    .body.authority_effect=="none" and .body.storage_effect=="none" and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
  ' "$output" >/dev/null || fail "$name"
  pass "$name"
}
expect_full_malformed_element() {
  local name=$1 filter=$2 mismatch_reason=$3 input="$tmp/$1.presentation"
  "$jq_bin" -S -c "$filter" "$presentation" >"$input"
  run_eval "$name" "$input"
  "$jq_bin" -e --arg mismatch "$mismatch_reason" '
    .body.verdict=="violated" and
    .body.reason_ids==(["evidence.presentation-malformed",$mismatch]|sort) and
    (.body.reason_ids|index("evidence.presentation-ambiguous")==null) and
    .body.authority_effect=="none" and .body.storage_effect=="none"
  ' "$tmp/$name.out" >/dev/null || fail "$name reasons"
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

expect_pure_violation duplicate-evidence-id \
  '.body.evidence += [(.body.evidence[0] | .kind="runtime-alt")]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation duplicate-evidence-kind \
  '.body.evidence += [(.body.evidence[0] | .evidence_id="evidence.zzz")]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation reversed-evidence \
  '.body.evidence += [(.body.evidence[0] | .evidence_id="evidence.zzz" |
    .kind="runtime-alt")] | .body.evidence |= reverse' \
  evidence.presentation-malformed
expect_pure_violation duplicate-prior-key \
  '.body.prior_evidence_refs += [.body.prior_evidence_refs[0]]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation reversed-prior \
  '.body.prior_evidence_refs += [(.body.prior_evidence_refs[0] |
    .stage_result_ref.sha256=("9"*64) | .stage_result_ref.id="result.zzz" |
    .evidence_id="evidence.zzz")] | .body.prior_evidence_refs |= reverse' \
  evidence.presentation-malformed
expect_pure_violation prior-document-alias \
  '.body.prior_evidence_refs += [(.body.prior_evidence_refs[0] |
    .stage_result_ref.id="result.alias" | .evidence_id="evidence.alias")] |
    .body.prior_evidence_refs |= sort_by([.stage_result_ref.sha256,.evidence_id])' \
  evidence.presentation-ambiguous

expect_full_malformed_element current-scalar '.body.evidence=[1]' \
  evidence.current-mismatch
expect_full_malformed_element current-null '.body.evidence=[null]' \
  evidence.current-mismatch
expect_full_malformed_element current-array '.body.evidence=[[]]' \
  evidence.current-mismatch
expect_full_malformed_element prior-scalar '.body.prior_evidence_refs=[1]' \
  evidence.prior-stale
expect_full_malformed_element prior-null '.body.prior_evidence_refs=[null]' \
  evidence.prior-stale
expect_full_malformed_element prior-array '.body.prior_evidence_refs=[[]]' \
  evidence.prior-stale

shared_result="$tmp/shared-proof.result"
shared_presentation="$tmp/shared-proof.presentation"
shared_output="$tmp/shared-proof.out"
"$jq_bin" -S -c '
  .body.evidence += [(.body.evidence[0] |
    .evidence_id="evidence.zzz" | .kind="runtime-alt" |
    .proof_ref.content_id="proof.logical-alt" |
    .proof_ref.media_type="application/vnd.ystack.alt-proof+json")] |
  .body.evidence |= sort_by(.evidence_id)
' "$result" >"$shared_result"
shared_result_sha=$(sha256_path "$shared_result")
"$jq_bin" -S -c --slurpfile result "$shared_result" \
  --arg result_sha "$shared_result_sha" '
  .body.evidence=$result[0].body.evidence |
  .body.result_ref={schema_version:$result[0].schema_version,kind:$result[0].kind,
    id:$result[0].id,sha256:$result_sha}
' "$presentation" >"$shared_presentation"
pure_eval_tuple "$request" "$shared_result" "$shared_presentation" "$shared_output"
"$jq_bin" -e '
  .body.verdict=="satisfied" and
  .body.reason_ids==["evidence.integrity-satisfied"] and
  (.body.evidence_refs|length)==2 and
  (.body.evidence_refs[0].proof_ref.sha256==.body.evidence_refs[1].proof_ref.sha256) and
  (.body.evidence_refs[0].proof_ref.content_id!=
    .body.evidence_refs[1].proof_ref.content_id)
' "$shared_output" >/dev/null || {
  /bin/cat "$shared_output" >&2
  fail 'same proof bytes distinct logical refs'
}
pass 'same proof digest under distinct logical refs remains valid'

shared_mismatch="$tmp/shared-proof-mismatch.presentation"
"$jq_bin" -S -c \
  '.body.evidence[0].proof_ref.content_id="proof.presentation-only"' \
  "$shared_presentation" >"$shared_mismatch"
pure_eval_tuple "$request" "$shared_result" "$shared_mismatch" "$shared_output"
"$jq_bin" -e '
  .body.verdict=="violated" and
  (.body.reason_ids|index("evidence.current-mismatch")!=null)
' "$shared_output" >/dev/null || fail 'logical ref identity mismatch'
pass 'changed logical proof identity with retained digest fails closed'

absent_request="$tmp/qualification-absent.request"
absent_result="$tmp/qualification-absent.result"
absent_presentation="$tmp/qualification-absent.presentation"
absent_output="$tmp/qualification-absent.out"
"$jq_bin" -S -c 'del(.body.qualification_ref)' "$request" >"$absent_request"
absent_request_sha=$(sha256_path "$absent_request")
"$jq_bin" -S -c --arg request_sha "$absent_request_sha" \
  '.body.request_ref.sha256=$request_sha |
   .body.evidence[0].verdict="inconclusive"' "$result" >"$absent_result"
absent_result_sha=$(sha256_path "$absent_result")
"$jq_bin" -S -c --slurpfile request "$absent_request" \
  --slurpfile result "$absent_result" --arg request_sha "$absent_request_sha" \
  --arg result_sha "$absent_result_sha" '
  .body.qualification_ref={state:"absent"} |
  .body.request_ref={schema_version:$request[0].schema_version,kind:$request[0].kind,
    id:$request[0].id,sha256:$request_sha} |
  .body.result_ref={schema_version:$result[0].schema_version,kind:$result[0].kind,
    id:$result[0].id,sha256:$result_sha} |
  .body.evidence=$result[0].body.evidence
' "$presentation" >"$absent_presentation"
pure_eval_tuple "$absent_request" "$absent_result" "$absent_presentation" \
  "$absent_output"
"$jq_bin" -e '
  .body.verdict=="satisfied" and
  .body.qualification_observation=={state:"absent"} and
  .body.qualification_semantics=="identity-only-unqualified" and
  .body.authority_effect=="none" and .body.storage_effect=="none" and
  (.body.evidence_refs[0].verdict=="inconclusive")
' "$absent_output" >/dev/null || fail 'absent qualification identity-only'
pass 'absent qualification and inconclusive proof remain identity-only'

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

/usr/bin/printf '{' >"$tmp/invalid.json"
expect_error invalid-json E_PARSE "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/invalid.json"
/usr/bin/printf '{}\n{}\n' >"$tmp/multi-root.json"
expect_error multi-root E_PARSE "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/multi-root.json"
"$jq_bin" . "$presentation" >"$tmp/noncanonical.json"
expect_error noncanonical E_CANONICAL "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/noncanonical.json"
/usr/bin/perl -e 'print "["x33,"0","]"x33,"\n"' >"$tmp/deep.json"
expect_error depth-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/deep.json"
"$jq_bin" -S -c '.id=("x"*8193)' "$presentation" >"$tmp/string-limit.json"
expect_error string-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/string-limit.json"
/usr/bin/perl -e 'print "{\"x\":\"","x"x1048576,"\"}\n"' >"$tmp/oversize.json"
expect_error byte-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/oversize.json"

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

wrapper_bin="$tmp/wrapper-bin"
/bin/mkdir "$wrapper_bin"
/usr/bin/printf '%s\n' '#!/bin/bash' \
  'if [ "${1:-}" = --version ]; then echo jq-1.6; exit 0; fi' \
  'exec /usr/bin/jq "$@"' >"$wrapper_bin/jq"
/bin/chmod 0555 "$wrapper_bin/jq"
unbound_status=0
PATH="$wrapper_bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation" >"$tmp/unbound-jq.out" \
  2>"$tmp/unbound-jq.err" || unbound_status=$?
[ "$unbound_status" -ne 0 ] && [ ! -s "$tmp/unbound-jq.out" ] &&
  [ "$(/bin/cat "$tmp/unbound-jq.err")" = E_RUNTIME ] || fail 'unbound jq result'
pass 'only official jq 1.6 bytes are accepted'

/usr/bin/grep -Fq \
  '"$jq_bin" -n -e --arg policy_sha "$policy_sha" --arg driver_sha "$driver_sha"' \
  "$evaluator" || fail 'decision envelope null-input mode'
pass 'decision envelope explicitly uses null input'

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

mutated_decision_runtime="$tmp/mutated-decision-runtime"
copy_runtime "$mutated_decision_runtime"
"$jq_bin" -S -c '.body.semantics.authority_effect="unexpected"' \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json" \
  >"$mutated_decision_runtime/decision.next"
/bin/mv "$mutated_decision_runtime/decision.next" \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json"
mutated_decision_sha=$(sha256_path \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json")
mutated_decision_set="$tmp/mutated-decision-policy-set.json"
"$jq_bin" -S -c --arg digest "$mutated_decision_sha" '
  .body.sections[] |= if .section_id=="evidence-integrity"
    then .decision_ref.sha256=$digest else . end
' "$policy_set" >"$mutated_decision_set"
expect_error mutated-decision E_RELATION "$mutated_decision_set" "$request" \
  "$resolved" "$result" "$presentation" "$mutated_decision_runtime"

wait_exit() {
  local pid=$1 limit=${2:-500} attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt "$limit" ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  ! kill -0 "$pid" 2>/dev/null
}
slice_until_path() {
  local pid=$1 search_root=$2 suffix=$3 attempt=0 found
  /bin/kill -STOP "$pid" 2>/dev/null || return 1
  while [ "$attempt" -lt 800 ]; do
    found=$(/usr/bin/find "$search_root" -type f -path "*/$suffix" -print -quit \
      2>/dev/null) || found=
    if [ -n "$found" ]; then /usr/bin/printf '%s\n' "$found"; return 0; fi
    kill -0 "$pid" 2>/dev/null || return 1
    /bin/kill -CONT "$pid" 2>/dev/null || return 1
    /bin/sleep 0.005
    /bin/kill -STOP "$pid" 2>/dev/null || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

replace_identity_case() {
  local name=$1 target_kind=$2 expected=${3:-E_RELATION}
  local runtime="$tmp/$1-runtime" live_bin="$tmp/$1-bin"
  local scratch_root="$tmp/$1-scratch" process target observed suffix case_status=0
  copy_runtime "$runtime"
  /bin/mkdir "$live_bin" "$scratch_root"
  /bin/cp "$jq_bin" "$live_bin/jq"
  /bin/chmod 0555 "$live_bin/jq"
  TMPDIR="$scratch_root" PATH="$live_bin:/usr/bin:/bin" \
    "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
    "$request" "$resolved" "$result" "$presentation" >"$tmp/$name.out" \
    2>"$tmp/$name.err" &
  process=$!
  suffix=driver.sh
  case "$target_kind" in
    private-driver) suffix=bin/jq ;;
    live-jq|private-jq) suffix=evaluation.json ;;
  esac
  observed=$(slice_until_path "$process" "$scratch_root" "$suffix") || {
    /bin/kill -KILL "$process" 2>/dev/null || :
    wait "$process" 2>/dev/null || :
    fail "$name observed path"
  }
  case "$target_kind" in
    origin) target="$runtime/control/v1/evaluate-evidence-integrity.sh" ;;
    private-driver) target="${observed%/bin/jq}/driver.sh" ;;
    live-jq) target="$live_bin/jq" ;;
    private-jq) target="${observed%/evaluation.json}/bin/jq" ;;
    *) fail "$name target" ;;
  esac
  /bin/cp "$target" "$target.next"
  /bin/chmod 0500 "$target.next"
  /bin/mv "$target.next" "$target"
  /bin/kill -CONT "$process" 2>/dev/null || :
  wait "$process" || case_status=$?
  if [ "$case_status" -eq 0 ] || [ -s "$tmp/$name.out" ] ||
     [ "$(/bin/cat "$tmp/$name.err")" != "$expected" ] ||
     [ -n "$(/usr/bin/find "$scratch_root" -mindepth 1 -print -quit)" ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$case_status" >&2
    /bin/cat "$tmp/$name.err" >&2
    fail "$name result"
  fi
  pass "$name"
}

replace_identity_case origin-driver-swap origin
replace_identity_case executing-driver-swap private-driver
replace_identity_case live-jq-swap live-jq
replace_identity_case private-jq-swap private-jq

program_runtime="$tmp/program-race-runtime"
program_scratch="$tmp/program-race-scratch"
copy_runtime "$program_runtime"
/bin/mkdir "$program_scratch"
TMPDIR="$program_scratch" PATH="$bin:/usr/bin:/bin" \
  "$program_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation" >"$tmp/program-race.out" \
  2>"$tmp/program-race.err" &
program_pid=$!
program_snapshot=
program_attempt=0
while [ -z "$program_snapshot" ] && [ "$program_attempt" -lt 800 ]; do
  program_snapshot=$(/usr/bin/find "$program_scratch" -type f -name program.jq \
    -print -quit 2>/dev/null) || program_snapshot=
  [ -z "$program_snapshot" ] || break
  kill -0 "$program_pid" 2>/dev/null || break
  program_attempt=$((program_attempt + 1))
  /bin/sleep 0.005
done
[ -n "$program_snapshot" ] || fail 'program race snapshot'
/usr/bin/printf '\n' >>"$program_runtime/control/v1/evidence-integrity.jq"
program_status=0
wait "$program_pid" || program_status=$?
[ "$program_status" -ne 0 ] && [ ! -s "$tmp/program-race.out" ] &&
  [ "$(/bin/cat "$tmp/program-race.err")" = E_RELATION ] || fail 'program race'
pass 'live program mutation closes after no-follow snapshot'

find_owned_leader() {
  /bin/ps -axo pid=,ppid=,pgid= 2>/dev/null | /usr/bin/awk -v parent="$1" \
    '$2==parent && $1==$3 {print $1; exit}'
}
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
TMPDIR="$signal_scratch" PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/signal.out" 2>"$tmp/signal.err" &
signal_pid=$!
signal_leader=
signal_attempt=0
while [ -z "$signal_leader" ] && [ "$signal_attempt" -lt 800 ]; do
  signal_leader=$(find_owned_leader "$signal_pid") || signal_leader=
  [ -z "$signal_leader" ] || break
  kill -0 "$signal_pid" 2>/dev/null || break
  signal_attempt=$((signal_attempt + 1))
  /bin/sleep 0.005
done
[[ "$signal_leader" =~ ^[1-9][0-9]*$ ]] || fail 'owned child leader'
/bin/kill -STOP -- "-$signal_leader"
/bin/kill -TERM "$signal_pid"
wait_exit "$signal_pid" 500 || fail 'signal bounded exit'
signal_status=0
wait "$signal_pid" || signal_status=$?
signal_live=$(/bin/ps -axo pgid=,state= 2>/dev/null | /usr/bin/awk \
  -v group="$signal_leader" '$1==group && $2!~/^Z/ {count++} END {print count+0}')
[ "$signal_status" -ne 0 ] && [ "$signal_live" -eq 0 ] &&
  [ ! -s "$tmp/signal.out" ] &&
  [ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'signal cleanup'
pass 'signal kills and reaps the stopped owned child group'

/usr/bin/grep -Fq 'ulimit -f 2048' "$evaluator" || fail 'child output cap'
/usr/bin/grep -Fq '[ "$attempt" -lt 1000 ]' "$evaluator" || fail 'child deadline'
pass 'child runtime and output are bounded'

bind_modified_driver() {
  local runtime=$1 output_set=$2 driver_digest decision_digest
  driver_digest=$(sha256_path "$runtime/control/v1/evaluate-evidence-integrity.sh")
  "$jq_bin" -S -c --arg digest "$driver_digest" \
    '.body.evaluator.driver_ref.sha256=$digest' \
    "$runtime/control/v1/evidence-integrity-decision.json" >"$runtime/decision.next"
  /bin/mv "$runtime/decision.next" \
    "$runtime/control/v1/evidence-integrity-decision.json"
  decision_digest=$(sha256_path "$runtime/control/v1/evidence-integrity-decision.json")
  "$jq_bin" -S -c --arg digest "$decision_digest" '
    .body.sections[] |= if .section_id=="evidence-integrity"
      then .decision_ref.sha256=$digest else . end
  ' "$policy_set" >"$output_set"
}

output_runtime="$tmp/output-swap-runtime"
output_scratch="$tmp/output-swap-scratch"
copy_runtime "$output_runtime"
/usr/bin/perl -0777 -pi -e '
  s{  pin_path "\$scratch/worker\.out" \|\| emit_supervisor_failure E_RUNTIME}{
    /bin/mv "\$scratch/worker.out" "\$scratch/worker.saved" || exit 1;
    /bin/ln -s "\$scratch/worker.saved" "\$scratch/worker.out" || exit 1;
    pin_path "\$scratch/worker.out" || emit_supervisor_failure E_RUNTIME
  }
' "$output_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$output_runtime" "$tmp/output-swap-set.json"
/bin/mkdir "$output_scratch"
output_status=0
TMPDIR="$output_scratch" PATH="$bin:/usr/bin:/bin" \
  "$output_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/output-swap-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/output-swap.out" 2>"$tmp/output-swap.err" || output_status=$?
[ "$output_status" -ne 0 ] && [ ! -s "$tmp/output-swap.out" ] &&
  [ "$(/bin/cat "$tmp/output-swap.err")" = E_RUNTIME ] &&
  [ -z "$(/usr/bin/find "$output_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'output symlink swap'
pass 'output path replacement is rejected before cleanup and emission'

cleanup_runtime="$tmp/cleanup-failure-runtime"
cleanup_scratch="$tmp/cleanup-failure-scratch"
copy_runtime "$cleanup_runtime"
/usr/bin/perl -0777 -pi -e 's/cleanup\(\) \{\n/cleanup() {\n  return 1;\n/' \
  "$cleanup_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$cleanup_runtime" "$tmp/cleanup-failure-set.json"
/bin/mkdir "$cleanup_scratch"
cleanup_status=0
TMPDIR="$cleanup_scratch" PATH="$bin:/usr/bin:/bin" \
  "$cleanup_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/cleanup-failure-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/cleanup-failure.out" 2>"$tmp/cleanup-failure.err" || cleanup_status=$?
[ "$cleanup_status" -ne 0 ] && [ ! -s "$tmp/cleanup-failure.out" ] ||
  fail 'cleanup failure output'
pass 'cleanup failure remains non-success and emits no stdout'

for required in control/v1/evidence-integrity-policy.json \
  control/v1/evidence-integrity-decision.json control/v1/evidence-integrity.jq \
  control/v1/evaluate-evidence-integrity.sh \
  scripts/test/control-evidence-integrity.test.sh; do
  [ "$(/usr/bin/grep -Fxc "$required" "$root/ci/required-files.txt")" -eq 1 ] ||
    fail "manifest $required"
done
/usr/bin/grep -Fq 'Inactive evidence-integrity evaluator' "$root/README.md" ||
  fail 'README docs'
/usr/bin/grep -Fq 'control-evidence-integrity.test.sh' "$root/RESTORE.md" ||
  fail 'RESTORE docs'
pass 'restore manifest and docs'

/usr/bin/printf 'control evidence integrity: %s passed\n' "$passes"
