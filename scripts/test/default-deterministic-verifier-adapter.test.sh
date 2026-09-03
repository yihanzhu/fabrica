#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
normalizer="$root/adapters/deterministic-verifier/v1/normalize.jq"
fixtures="$root/scripts/test"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-deterministic-verifier.XXXXXX")
trap '/bin/rm -rf -- "$tmp"' EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); /usr/bin/printf 'ok %s - %s\n' "$passed" "$1"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$digest" ] ||
  fail 'verified jq 1.6 cache is required'
jq_command=("$jq_bin")
if [ "$platform" = Darwin:arm64 ]; then jq_command=(/usr/bin/arch -x86_64 "$jq_bin"); fi
[ "$("${jq_command[@]}" --version)" = jq-1.6 ] || fail 'jq version'

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
  "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected core generation'
"${jq_command[@]}" -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$root/core/v2/generation-registry.json" >/dev/null ||
  fail 'selected core registry identity'
modules="$root/core/v2/generations/$generation/modules"
[ -d "$modules" ] && [ ! -L "$modules" ] || fail 'selected core modules'

check() {
  local name=$1
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
  pass "$name"
}

normalize() {
  "${jq_command[@]}" -L "$modules" -S -c -f "$normalizer" "$1"
}

expect_state() {
  local name=$1 input=$2 expected=$3 output
  output="$tmp/$name.out"
  normalize "$input" >"$output" 2>"$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --arg state "$expected" '.state == $state' "$output" \
    >/dev/null || fail "$name state"
  pass "$name"
}

expect_error() {
  local name=$1 filter=$2 expected=$3 input
  input="$tmp/$name.json"
  "${jq_command[@]}" -S -c "$filter" "$tmp/passed.json" >"$input"
  if normalize "$input" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    fail "$name accepted"
  fi
  if [ -s "$tmp/$name.out" ] ||
     ! /usr/bin/grep -F "$expected" "$tmp/$name.err" >/dev/null; then
    fail "$name diagnostics"
  fi
  pass "$name"
}

for role in producer publisher reviewer; do
  "${jq_command[@]}" -L "$fixtures" -S -c -n --arg role "$role" '
    import "portable-core-profile-graph-fixtures" as profile;
    def v2: walk(if type == "object" and has("schema_version")
                 then .schema_version=2 else . end);
    profile::manifest($role) | v2
  ' >"$tmp/manifest-$role.json"
done

"${jq_command[@]}" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  profile::manifest("verifier") | v2 |
  .id="adapter.deterministic-verifier.v1"
' >"$tmp/manifest-verifier.json"

"${jq_command[@]}" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  {
    schema_version:2,kind:"adapter_manifest",id:"manifest.forge",
    body:{adapter_version:"v2",package_ref:profile::blob("packages/forge.bin";"6"),
      offered_roles:["forge"],offered_execution_kinds:["deterministic"],
      offered_capabilities:["core.forge.materialize-candidate.v2"],
      offered_permissions:["core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
        "core.perm.target.read.v1"],offered_tools:[]}
  }
' >"$tmp/manifest-forge.json"

forge_sha=$(sha_file "$tmp/manifest-forge.json")
producer_sha=$(sha_file "$tmp/manifest-producer.json")
publisher_sha=$(sha_file "$tmp/manifest-publisher.json")
reviewer_sha=$(sha_file "$tmp/manifest-reviewer.json")
verifier_sha=$(sha_file "$tmp/manifest-verifier.json")
"${jq_command[@]}" -S -c -n --arg forge "$forge_sha" --arg producer "$producer_sha" \
  --arg publisher "$publisher_sha" --arg reviewer "$reviewer_sha" \
  --arg verifier "$verifier_sha" \
  '{forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}' \
  >"$tmp/manifest-shas.json"

"${jq_command[@]}" -L "$fixtures" -S -c -n \
  --slurpfile shas "$tmp/manifest-shas.json" '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  def forge_binding($digests): {
    binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",
      sha256:$digests.forge},execution_kind:"deterministic",
    adapter_instance_id:"instance.forge",principal_id:"principal.forge",
    execution_boundary_id:"boundary.forge",
    authority_ref:profile::scope("authority";"authority-forge";profile::sha("5")),
    package_ref:profile::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
      "core.perm.target.read.v1"]};
  profile::profile_doc($shas[0]) | v2 |
  .body.profile_version="v2" |
  (.body.bindings[] | select(.role=="verifier") | .manifest_ref.id)=
    "adapter.deterministic-verifier.v1" |
  .body.bindings += [forge_binding($shas[0])] |
  .body.bindings |= sort_by(.binding_id)
' >"$tmp/profile.json"
profile_sha=$(sha_file "$tmp/profile.json")

"${jq_command[@]}" -L "$fixtures" -S -c -n --slurpfile profile_doc "$tmp/profile.json" \
  --arg profile_sha "$profile_sha" --slurpfile shas "$tmp/manifest-shas.json" '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  profile::resolved_profile_doc($profile_doc[0];$profile_sha;$shas[0]) | v2 |
  .body.bindings |= map(
    if .binding.role=="forge" then
      .adapter_implementation.version="v2" |
      .manifest_source=profile::source_value(profile::blob("manifests/forge.json";"a");
        "canonical-json";$shas[0].forge)
    elif .binding.role=="verifier" then
      .adapter_implementation.id="adapter.deterministic-verifier.v1"
    else . end)
' >"$tmp/resolved.json"
resolved_sha=$(sha_file "$tmp/resolved.json")

"${jq_command[@]}" -L "$fixtures" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  request::request_doc("verifier";$resolved_sha) | v2
' >"$tmp/request.json"
request_sha=$(sha_file "$tmp/request.json")

make_result() {
  local flavor=$1 output=$2
  "${jq_command[@]}" -L "$fixtures" -S -c -n \
    --slurpfile request_doc "$tmp/request.json" --slurpfile resolved_doc "$tmp/resolved.json" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" --arg flavor "$flavor" '
    import "portable-core-result-truth-fixtures" as result;
    def v2: walk(if type == "object" and has("schema_version")
                 then .schema_version=2 else . end);
    (if $flavor=="passed" then
       result::completed_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha)
     elif $flavor=="failed-check" then
       result::completed_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha) |
       .body.evidence[0].verdict="failed" |
       .body.outcome={family:"check",value:"failed"}
     elif $flavor=="inconclusive" then
       result::completed_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha) |
       .body.evidence[0].verdict="inconclusive" |
       .body.outcome={family:"check",value:"inconclusive"} |
       .body.reason={reason_id:"verification.inconclusive"}
     elif $flavor=="stale" then
       result::stale_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha)
     elif $flavor=="blocked" then
       result::blocked_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha)
     elif $flavor=="stage-failed" then
       result::failed_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha)
     else
       result::cancelled_result_doc($request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha)
     end) | v2
  ' >"$output"
}

make_input() {
  local result_file=$1 output=$2 result_sha snapshot_file snapshot_sha
  result_sha=$(sha_file "$result_file")
  snapshot_file="${output%.json}.snapshot.json"
  "${jq_command[@]}" -S -c -n --slurpfile result_doc "$result_file" \
    --arg result_sha "$result_sha" '
    def pair($docs;$sha): {content:$docs[0],sha256:$sha};
    {schema_version:1,kind:"deterministic_verifier_snapshot",id:"snapshot.verifier",
     body:{observed_at:"2026-08-30T00:00:04Z",result:pair($result_doc;$result_sha)}}
  ' >"$snapshot_file"
  snapshot_sha=$(sha_file "$snapshot_file")
  "${jq_command[@]}" -S -c -n --slurpfile manifest "$tmp/manifest-verifier.json" \
    --slurpfile request_doc "$tmp/request.json" --slurpfile resolved "$tmp/resolved.json" \
    --slurpfile result_doc "$result_file" --slurpfile snapshot_doc "$snapshot_file" \
    --arg manifest_sha "$verifier_sha" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    --arg result_sha "$result_sha" --arg snapshot_sha "$snapshot_sha" '
    def pair($docs;$sha): {content:$docs[0],sha256:$sha};
    {
      trust_context:{schema_version:1,kind:"adapter_trust_context",id:"trust.verifier",
        body:{binding_id:"binding.verifier",expected_attempt_id:"attempt.example",
          expected_attempt_number:1,manifest:pair($manifest;$manifest_sha),
          request:pair($request_doc;$request_sha),resolved_profile:pair($resolved;$resolved_sha),
          verified_result:pair($result_doc;$result_sha),
          verified_snapshot:pair($snapshot_doc;$snapshot_sha)}},
      snapshot:$snapshot_doc[0]
    }
  ' >"$output"
}

for flavor in passed failed-check inconclusive stale blocked stage-failed cancelled; do
  make_result "$flavor" "$tmp/result-$flavor.json"
  make_input "$tmp/result-$flavor.json" "$tmp/$flavor.json"
done

expect_state passed "$tmp/passed.json" passed
expect_state failed-check "$tmp/failed-check.json" failed
expect_state inconclusive "$tmp/inconclusive.json" inconclusive
expect_state stale "$tmp/stale.json" stale
expect_state blocked "$tmp/blocked.json" blocked
expect_state stage-failed "$tmp/stage-failed.json" failed
expect_state cancelled "$tmp/cancelled.json" cancelled

expect_error github-actions-not-verifier \
  '.snapshot={schema_version:1,kind:"github_actions_ci_snapshot",id:"snapshot.ci",body:{}}' \
  E_SHAPE
expect_error ci-field-rejected '.snapshot.body.workflow_id="ci"' E_SHAPE
expect_error wrong-role '.trust_context.body.request.content.body.operation.role="ci"' E_TRUST
expect_error wrong-capability \
  '.trust_context.body.request.content.body.operation.capability_id="core.review.change.v1"' E_TRUST
expect_error permission-subset \
  '.trust_context.body.request.content.body.operation.permissions=["core.perm.target.read.v1"]' E_TRUST
expect_error network-not-denied \
  '.trust_context.body.request.content.body.operation.arguments.network_mode="allow"' E_TRUST
expect_error candidate-cross-repository \
  '(.trust_context.body.request.content.body.inputs[] |
    select(.input_id=="input.candidate") | .value.value.value.revision.repository_id)="repo.other"' \
  E_TRUST
expect_error verification-plan-alias \
  '.trust_context.body.request.content.body.operation.arguments.verification_plan.input_id="input.candidate"' \
  E_TRUST
expect_error manifest-capability-ceiling \
  '.trust_context.body.manifest.content.body.offered_capabilities=["core.review.change.v1"]' \
  E_TRUST
expect_error manifest-config-contract \
  '.trust_context.body.manifest.content.body.config_contract_ref=
    .trust_context.body.request.content.body.operation.arguments.verification_plan.ref' E_TRUST
expect_error verifier-tool \
  '(.trust_context.body.resolved_profile.content.body.bindings[] |
    select(.binding.role=="verifier") | .binding.requested_tools)=[{
      tool_id:"tool.hidden",tool_version:"v1",
      package_ref:.trust_context.body.resolved_profile.content.body.bindings[0].binding.package_ref,
      config_ref:{state:"absent"}}]' E_TRUST
expect_error verifier-model \
  '(.trust_context.body.resolved_profile.content.body.bindings[] |
    select(.binding.role=="verifier") | .binding) |=
    (.execution_kind="model" | .model_request={provider_id:"p",model_id:"m",effort_id:"e"} |
     .prompt_ref=.package_ref)' E_TRUST
expect_error stale-request-digest '.trust_context.body.request.sha256=("0"*64)' E_RESULT
expect_error stale-resolved-digest '.trust_context.body.resolved_profile.sha256=("0"*64)' E_TRUST
expect_error stale-manifest-digest '.trust_context.body.manifest.sha256=("0"*64)' E_TRUST
expect_error moved-untrusted-snapshot '.snapshot.id="snapshot.moved"' E_RESULT
expect_error moved-verified-snapshot \
  '.trust_context.body.verified_snapshot.content.id="snapshot.moved"' E_RESULT
expect_error moved-verified-result \
  '.trust_context.body.verified_result.sha256=("0"*64)' E_RESULT
expect_error malformed-verified-snapshot-digest \
  '.trust_context.body.verified_snapshot.sha256=("A"*64)' E_SHAPE
expect_error expected-attempt-id \
  '.trust_context.body.expected_attempt_id="attempt.other"' E_RESULT
expect_error expected-attempt-number \
  '.trust_context.body.expected_attempt_number=2' E_RESULT
expect_error performer-mismatch \
  '.snapshot.body.result.content.body.execution.performer.principal_id="principal.other"' E_RESULT
expect_error reporter-mismatch \
  '.snapshot.body.result.content.body.reported_by.execution_boundary_id="boundary.other"' E_RESULT
expect_error missing-deterministic-evidence \
  '.snapshot.body.result.content.body.evidence |= map(select(.kind!="deterministic"))' E_RESULT
expect_error false-pass-over-failure \
  '(.snapshot.body.result.content.body.evidence[0].verdict)="failed"' E_RESULT
expect_error verifier-output \
  '.snapshot.body.result.content.body.outputs=[{output_id:"forbidden",
    ref:{content_id:"forbidden",media_type:"application/json",sha256:("a"*64)}}]' E_RESULT
expect_error observation-before-result \
  '.snapshot.body.observed_at="2026-08-30T00:00:02Z"' E_RESULT
expect_error terminal-before-start '
  .snapshot.body.result.content.body.finished_at="2026-08-29T23:59:59Z" |
  .trust_context.body.verified_result=.snapshot.body.result |
  .trust_context.body.verified_snapshot.content=.snapshot' E_RESULT
expect_error invalid-proof-media '
  .snapshot.body.result.content.body.evidence[0].proof_ref.media_type="INVALID" |
  .trust_context.body.verified_result=.snapshot.body.result |
  .trust_context.body.verified_snapshot.content=.snapshot' E_RESULT
expect_error non-core-content-id '
  .snapshot.body.result.content.body.evidence[0].proof_ref.content_id="proof:invalid" |
  .trust_context.body.verified_result=.snapshot.body.result |
  .trust_context.body.verified_snapshot.content=.snapshot' E_RESULT
expect_error opaque-metadata-rejected '
  .snapshot.body.provider_metadata={nested:{message:("x"*9000)}} |
  .trust_context.body.verified_snapshot.content=.snapshot' E_SHAPE

normalize "$tmp/passed.json" >"$tmp/repeat-a.json"
normalize "$tmp/passed.json" >"$tmp/repeat-b.json"
check canonical-repeat /usr/bin/cmp -s "$tmp/repeat-a.json" "$tmp/repeat-b.json"
check canonical-output /usr/bin/cmp -s "$tmp/repeat-a.json" \
  <("${jq_command[@]}" -S -c . "$tmp/repeat-a.json")
check inactive-no-authority-effects "${jq_command[@]}" -e '
  .adapter=={id:"adapter.deterministic-verifier.v1",version:"v1",status:"inactive"} and
  .authority=="none" and .effects==[] and
  .qualification=={state:"unavailable",reason_id:"adapter.unqualified"}
' "$tmp/repeat-a.json"
check exact-candidate-and-plan "${jq_command[@]}" -e \
  --slurpfile input "$tmp/passed.json" '
  .observation.candidate_input ==
    ($input[0].trust_context.body.request.content.body.inputs[] |
     select(.input_id=="input.candidate")) and
  .observation.verification_plan ==
    $input[0].trust_context.body.request.content.body.operation.arguments.verification_plan and
  .trust_context.expected_attempt_id ==
    $input[0].trust_context.body.expected_attempt_id and
  .trust_context.expected_attempt_number ==
    $input[0].trust_context.body.expected_attempt_number and
  .trust_context.snapshot_ref.sha256 ==
    $input[0].trust_context.body.verified_snapshot.sha256 and
  .observation.result.result_ref.sha256 ==
    $input[0].trust_context.body.verified_result.sha256
' "$tmp/repeat-a.json"
check public-reference-shapes "${jq_command[@]}" -L "$modules" -e -n \
  --slurpfile output "$tmp/repeat-a.json" '
  import "schema" as schema;
  ($output[0].trust_context.snapshot_ref | schema::content_ref_ok) and
  ($output[0].trust_context.manifest_ref |
    schema::document_ref_kind_ok("adapter_manifest")) and
  ($output[0].trust_context.request_ref |
    schema::document_ref_kind_ok("stage_request")) and
  ($output[0].trust_context.resolved_profile_ref |
    schema::document_ref_kind_ok("resolved_profile")) and
  ($output[0].observation.result.result_ref |
    schema::document_ref_kind_ok("stage_result")) and
  all($output[0].observation.result.evidence[];.proof_ref | schema::content_ref_ok)
  '
check no-ci-projection "${jq_command[@]}" -e '
  ([.. | objects | keys[]] as $keys |
   all(["app_id","check_run_id","check_suite_id","job_id","run_id","workflow_id"][];
     . as $key | $keys | index($key)==null))
' "$tmp/repeat-a.json"
check no-selected-generation /usr/bin/env sh -c \
  '! grep -E "g-[0-9a-f]{64}" "$@"' sh "$normalizer" \
  "$root/scripts/test/default-deterministic-verifier-adapter.test.sh"
check pure-offline-normalizer /usr/bin/env sh -c \
  '! grep -Ei "github|actions|curl|graphql|https?://|@sh|system[(]|getenv|credential|token" "$1"' \
  sh "$normalizer"

/usr/bin/printf 'default deterministic verifier adapter: %s/%s checks passed\n' \
  "$passed" "$passed"
