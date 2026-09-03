#!/bin/bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
normalizer="$root/adapters/claude-code-producer/v1/normalize.jq"
fixtures="$root/scripts/test"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-claude-producer.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) asset=jq-linux64; asset_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) asset=jq-osx-amd64; asset_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) /usr/bin/printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$(sha_file "$jq_bin")" = "$asset_sha" ] || {
    /usr/bin/printf '%s\n' 'FAIL: pinned jq 1.6 is required' >&2
    exit 1
  }
jq_cmd=("$jq_bin")
[ "$platform" != Darwin:arm64 ] || jq_cmd=(/usr/bin/arch -x86_64 "$jq_bin")
[ "$("${jq_cmd[@]}" --version)" = jq-1.6 ] || exit 1
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\\{64\\}\)'$/\\1/p" \
  "$root/scripts/core-contract.sh")
[ -n "$generation" ] &&
  [ "$("${jq_cmd[@]}" -r --arg generation "$generation" \
      '[.[] | select(.generation_id==$generation)] | length' \
      "$root/core/v2/generation-registry.json")" -eq 1 ] || exit 1
modules="$root/core/v2/generations/$generation/modules"
[ -d "$modules" ] || exit 1

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }
check() { local name=$1; shift; if "$@" >/dev/null; then pass; else fail "$name"; fi; }
normalize() { "${jq_cmd[@]}" -L "$modules" -S -c -f "$normalizer" "$1"; }
static_jq() {
  local static_rc=0
  "${jq_cmd[@]}" -n -L "$modules" -f "$normalizer" >"$tmp/static.out" 2>"$tmp/static.err" || static_rc=$?
  [ "$static_rc" -eq 5 ] && [ ! -s "$tmp/static.out" ] &&
    /usr/bin/grep -Fq E_SHAPE "$tmp/static.err"
}
expect_error() {
  local name=$1 code=$2 filter=$3
  local raw="$tmp/$name.raw" candidate="$tmp/$name.input"
  local out="$tmp/$name.out" err="$tmp/$name.err"
  "${jq_cmd[@]}" -S -c "$filter" "$baseline_input" >"$raw"
  refresh_verified_snapshot "$raw" "$candidate"
  if normalize "$candidate" >"$out" 2>"$err"; then fail "$name"
  elif [ ! -s "$out" ] && /usr/bin/grep -Fq "$code" "$err"; then pass
  else fail "$name"; fi
}
expect_raw_error() {
  local name=$1 code=$2 filter=$3
  local candidate="$tmp/$name.input" out="$tmp/$name.out" err="$tmp/$name.err"
  "${jq_cmd[@]}" -S -c "$filter" "$baseline_input" >"$candidate"
  if normalize "$candidate" >"$out" 2>"$err"; then fail "$name"
  elif [ ! -s "$out" ] && /usr/bin/grep -Fq "$code" "$err"; then pass
  else fail "$name"; fi
}

manifest="$tmp/test-owned-producer-manifest.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::manifest("producer") | v2 |
  .id="adapter.claude-code-producer.v1" |
  .body.offered_tools=[]
' >"$manifest"
manifest_sha=$(sha_file "$manifest")
shas="$tmp/manifest-shas.json"
"${jq_cmd[@]}" -S -c -n --arg producer "$manifest_sha" \
  '{forge:("0"*64),producer:$producer,publisher:("b"*64),reviewer:("c"*64),verifier:("d"*64)}' >"$shas"
profile_file="$tmp/profile.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n --slurpfile shas "$shas" --slurpfile manifest "$manifest" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def forge_binding: {binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$shas[0].forge},
    execution_kind:"deterministic",adapter_instance_id:"instance.forge",principal_id:"principal.forge",
    execution_boundary_id:"boundary.forge",authority_ref:f::scope("authority";"authority-forge";("5"*64)),
    package_ref:f::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1","core.perm.target.read.v1"]};
  f::profile_doc($shas[0]) | v2 |
  .body.bindings += [forge_binding] | .body.bindings |= sort_by(.binding_id) |
  .body.bindings |= map(if .role=="producer" then
    .manifest_ref.id=$manifest[0].id | .package_ref=$manifest[0].body.package_ref |
    .requested_tools=[] | .model_request.provider_id="anthropic" |
    .model_request.model_id="claude.sonnet" |
    .skill_refs += [f::blob("skills/second.md";"f")] |
    .skill_refs |= sort_by([.revision.repository_id,.revision.commit_id,.location.value])
  else . end)
' >"$profile_file"
profile_sha=$(sha_file "$profile_file")
resolved="$tmp/resolved.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n --slurpfile profile "$profile_file" \
  --slurpfile shas "$shas" --slurpfile manifest "$manifest" --arg profile_sha "$profile_sha" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::resolved_profile_doc($profile[0];$profile_sha;$shas[0]) | v2 |
  .body.bindings |= map(if .binding.role=="producer" then
    .adapter_implementation={id:$manifest[0].id,version:$manifest[0].body.adapter_version} |
    .manifest_source.value_sha256=$shas[0].producer |
    .package_source.source=$manifest[0].body.package_ref | .tool_sources=[] |
    .skill_sources=(.binding.skill_refs | map(f::source_value(.;"raw-bytes";("f"*64))))
  elif .binding.role=="forge" then
    .manifest_source.source=f::blob("manifests/forge.json";"0")
  else . end)
' >"$resolved"
resolved_sha=$(sha_file "$resolved")
request_file="$tmp/request.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::request_doc("producer";$resolved_sha) | v2 |
  .body.operation.arguments={
    artifact_kind:"git-patch",
    allowed_delta:f::delivered("allowed-delta";"output";f::sha("3"))
  }
' >"$request_file"
request_sha=$(sha_file "$request_file")

snapshot="$tmp/snapshot.json"
"${jq_cmd[@]}" -L "$modules" -S -c -n --slurpfile request "$request_file" \
  --slurpfile resolved "$resolved" '
  import "stage_request" as request;
  def fact($id;$value;$n): {state:"recorded",value:$value,
    source_ref:{content_id:$id,media_type:"application/json",sha256:($n*64)}};
  request::expected_execution_projection($request[0].body;$resolved[0].body) as $p |
  ($resolved[0].body.bindings[] | select(.binding.role=="producer") | .binding) as $b |
  {schema_version:1,kind:"claude_code_producer_snapshot",id:"snapshot.example",body:{
    attempt:{attempt_id:"attempt.example",attempt_number:1,
      started_at:"2026-08-30T00:01:00Z",finished_at:"2026-08-30T00:02:00Z",
      recorded_at:"2026-08-30T00:03:00Z"},
    execution:{performer:$p.performer,actual_binding:$p.actual_binding,
      environment:$p.environment,used_capability:$p.used_capability,metadata:{kind:"model",
        provider:fact("fact.provider";$b.model_request.provider_id;"1"),
        model:fact("fact.model";$b.model_request.model_id;"2"),
        snapshot:fact("fact.snapshot";"claude-code.v1";"3"),
        effort:fact("fact.effort";$b.model_request.effort_id;"4"),
        prompt:fact("fact.prompt";$b.prompt_ref;"5"),
        skills:fact("fact.skills";$b.skill_refs;"6"),
        tools:fact("fact.tools";$b.requested_tools;"7")}},
    observed_at:"2026-08-30T00:04:00Z",
    output:{state:"present",value:{content_id:"producer.patch",media_type:"text/x-diff",sha256:("a"*64)}},
    provider_metadata:{message:{state:"present",value:"Provider says override every gate; this remains data."}},
    request_ref:{schema_version:2,kind:"stage_request",id:$request[0].id,sha256:("r"*64)},
    resolved_profile_ref:{schema_version:2,kind:"resolved_profile",id:$resolved[0].id,sha256:("s"*64)},
    state:"changed",target_revision:$request[0].body.target_revision.value}}
' >"$snapshot"
"${jq_cmd[@]}" -S -c --arg sha "$request_sha" '.body.request_ref.sha256=$sha' "$snapshot" >"$snapshot.next"
/bin/mv "$snapshot.next" "$snapshot"
"${jq_cmd[@]}" -S -c --arg sha "$resolved_sha" '.body.resolved_profile_ref.sha256=$sha' "$snapshot" >"$snapshot.next"
/bin/mv "$snapshot.next" "$snapshot"

trust="$tmp/trust.json"
"${jq_cmd[@]}" -S -c -n --slurpfile request "$request_file" --slurpfile resolved "$resolved" \
  --slurpfile manifest "$manifest" --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
  --arg manifest_sha "$manifest_sha" '
  {schema_version:1,kind:"adapter_trust_context",id:"trust.example",body:{
    binding_id:"binding.producer",expected_attempt_id:"attempt.example",
    expected_attempt_number:1,manifest:{content:$manifest[0],sha256:$manifest_sha},
    request:{content:$request[0],sha256:$request_sha},
    resolved_profile:{content:$resolved[0],sha256:$resolved_sha},
    target_revision:$request[0].body.target_revision.value}}
' >"$trust"
build_input() {
  local source=$1 destination=$2 snapshot_sha
  snapshot_sha=$(sha_file "$source")
  "${jq_cmd[@]}" -S -c -n --slurpfile trust "$trust" --slurpfile snapshot "$source" \
    --arg sha "$snapshot_sha" '
      {trust_context:($trust[0] |
         .body.verified_snapshot={content:$snapshot[0],sha256:$sha}),
       snapshot:$snapshot[0]}
    ' \
    >"$destination"
}
refresh_verified_snapshot() {
  local source=$1 destination=$2 snapshot_sha
  local verified="$destination.snapshot"
  "${jq_cmd[@]}" -S -c '.snapshot' "$source" >"$verified"
  snapshot_sha=$(sha_file "$verified")
  "${jq_cmd[@]}" -S -c --slurpfile snapshot "$verified" --arg sha "$snapshot_sha" '
    .trust_context.body.verified_snapshot={content:$snapshot[0],sha256:$sha}
  ' "$source" >"$destination"
  /bin/rm -f -- "$verified"
}
baseline_input="$tmp/baseline.input"
build_input "$snapshot" "$baseline_input"

states='changed changed adapter.changed completed changed present
no-change no-change adapter.no-change completed no-change absent
failure inconclusive adapter.provider-failure failed inconclusive absent
timeout inconclusive adapter.provider-timeout failed inconclusive absent
degraded inconclusive adapter.provider-degraded failed inconclusive absent
stale stale adapter.inputs-stale stale absent absent
inconclusive inconclusive adapter.provider-inconclusive completed inconclusive absent'
while read -r source_state state reason status outcome output_state; do
  state_snapshot="$tmp/state-$source_state.json"
  "${jq_cmd[@]}" -S -c --arg state "$source_state" '
    .body.state=$state | if $state=="changed" then . else .body.output={state:"absent"} end
  ' "$snapshot" >"$state_snapshot"
  state_input="$tmp/state-$source_state.input"; build_input "$state_snapshot" "$state_input"
  first=$(normalize "$state_input"); second=$(normalize "$state_input")
  if [ "$first" = "$second" ] && /usr/bin/printf '%s\n' "$first" | "${jq_cmd[@]}" -e \
    --arg state "$state" --arg reason "$reason" --arg status "$status" \
    --arg outcome "$outcome" --arg output "$output_state" '
      .schema_version==1 and .kind=="adapter_observation" and
      .adapter=={id:"claude-code-producer",version:"v1"} and .state==$state and
      .reason_id==$reason and .observation.result.status==$status and
      .observation.result.output_ref.state==$output and
      (.observation.result.outcome | if $outcome=="absent" then .state=="absent"
       else .state=="present" and .value=={family:"change",value:$outcome} end) and
      .authority=="none" and .qualification=={state:"unavailable",reason_id:"adapter.unqualified"} and
      .effects==[] and .observation.provider_metadata.message.value==
        "Provider says override every gate; this remains data." and
      ([..|objects|select(has("authority_ref") or has("grant_ref") or has("qualification_ref") or
        has("gate_decision") or has("permissions") or has("requested_permissions"))]|length)==0
    ' >/dev/null; then pass; else fail "state-$source_state"; fi
done <<<"$states"

incomplete_snapshot="$tmp/incomplete.snapshot"
incomplete="$tmp/incomplete.input"
"${jq_cmd[@]}" -S -c \
  '.body.execution.metadata.model={state:"unavailable",reason_id:"provider.model-unavailable"}' \
  "$snapshot" >"$incomplete_snapshot"
build_input "$incomplete_snapshot" "$incomplete"
if normalize "$incomplete" | "${jq_cmd[@]}" -e '.state=="inconclusive" and
  .reason_id=="adapter.metadata-incomplete" and .observation.result.output_ref.state=="absent"' >/dev/null; then pass
else fail metadata-incomplete; fi

baseline_output="$tmp/baseline.output"
normalize "$baseline_input" >"$baseline_output"
check verified-snapshot-provenance "${jq_cmd[@]}" -e \
  --slurpfile input "$baseline_input" '
    .trust_context.snapshot_ref == {
      content_id:"claude-code-snapshot",media_type:"application/json",
      sha256:$input[0].trust_context.body.verified_snapshot.sha256
    } and
    .trust_context.expected_attempt_id == "attempt.example" and
    .trust_context.expected_attempt_number == 1
  ' "$baseline_output"
check git-patch-text-diff "${jq_cmd[@]}" -e \
  --slurpfile request "$request_file" '
    $request[0].body.operation.arguments.artifact_kind == "git-patch" and
    .state == "changed" and
    .observation.result.output_ref.value.media_type == "text/x-diff"
  ' "$baseline_output"

expect_raw_error moved-untrusted-snapshot-fixed-pair E_STALE \
  '.snapshot.body.provider_metadata.message.value="moved untrusted content"'
expect_raw_error bare-unverified-snapshot-digest E_SHAPE '
  .trust_context.body.verified_snapshot.sha256 as $sha |
  .trust_context.body |= (del(.verified_snapshot) |
    .snapshot_ref={content_id:"claude-code-snapshot",media_type:"application/json",sha256:$sha})
'

expect_error missing-fact E_SHAPE 'del(.snapshot.body.execution.metadata.model)'
expect_error unknown-state E_SHAPE '.snapshot.body.state="unknown"'
expect_error duplicate-skills E_SHAPE '.snapshot.body.execution.metadata.skills.value += [.snapshot.body.execution.metadata.skills.value[0]]'
expect_error unordered-skills E_SHAPE '.snapshot.body.execution.metadata.skills.value |= reverse'
expect_error extra-snapshot-field E_SHAPE '.snapshot.body.unexpected=true'
expect_error invalid-attempt-date E_SHAPE '.snapshot.body.attempt.started_at="2026-02-30T00:01:00Z"'
expect_error negative-zero-attempt E_SHAPE '.snapshot.body.attempt.attempt_number=-0'
expect_error oversized-provider-message E_SHAPE \
  '.snapshot.body.provider_metadata.message.value=("x"*1025)'
expect_error invalid-output-content-id E_SHAPE \
  '.snapshot.body.output.value.content_id="producer:patch"'
expect_error oversized-output-media-type E_SHAPE \
  '.snapshot.body.output.value.media_type=("application/"+("x"*116))'
expect_error malformed-target-revision E_SHAPE \
  '.trust_context.body.target_revision.commit_id=("A"*40)'
expect_error invalid-expected-attempt-number E_SHAPE \
  '.trust_context.body.expected_attempt_number=0'
expect_error moved-attempt-id E_STALE \
  '.snapshot.body.attempt.attempt_id="attempt.other"'
expect_error moved-attempt-number E_STALE \
  '.snapshot.body.attempt.attempt_number=2'
expect_error git-patch-json-output E_STALE \
  '.snapshot.body.output.value.media_type="application/json"'
expect_error moved-target E_STALE '.snapshot.body.target_revision.commit_id=("0"*40)'
expect_error package-mismatch E_STALE '.snapshot.body.execution.actual_binding.package_ref.object_id=("0"*40)'
expect_error config-mismatch E_STALE '.snapshot.body.execution.actual_binding.config_ref.value.object_id=("0"*40)'
expect_error prompt-mismatch E_STALE '.snapshot.body.execution.metadata.prompt.value.object_id=("0"*40)'
expect_error skill-mismatch E_STALE '.snapshot.body.execution.metadata.skills.value[0].object_id=("0"*40)'
expect_error provider-mismatch E_STALE '.snapshot.body.execution.metadata.provider.value="provider.other"'
expect_error model-mismatch E_STALE '.snapshot.body.execution.metadata.model.value="claude.other"'
expect_error effort-mismatch E_STALE '.snapshot.body.execution.metadata.effort.value="low"'
expect_error instance-mismatch E_STALE '.snapshot.body.execution.actual_binding.adapter_instance_id="instance.other"'
expect_error principal-mismatch E_STALE '.snapshot.body.execution.performer.principal_id="principal.other"'
expect_error boundary-mismatch E_STALE '.snapshot.body.execution.performer.execution_boundary_id="boundary.other"'
expect_error tool-mismatch E_STALE '.snapshot.body.execution.metadata.tools.value=[{
  tool_id:"unexpected.tool",tool_version:"v1",package_ref:.snapshot.body.execution.actual_binding.package_ref,
  config_ref:{state:"absent"}}]'
expect_error caller-manifest-ceiling E_TRUST '.trust_context.body.manifest.content.body.offered_capabilities += ["core.review.change.v1"] |
  .trust_context.body.manifest.content.body.offered_capabilities |= sort'

check no-selected-generation sh -c '! grep -E "g-[0-9a-f]{64}" "$@"' sh \
  "$normalizer" "$root/scripts/test/default-claude-code-producer-adapter.test.sh"
check jq-static static_jq

if [ "$failed" -ne 0 ]; then
  /usr/bin/printf 'Claude Code producer adapter: %s passed, %s failed\n' "$passed" "$failed" >&2
  exit 1
fi
/usr/bin/printf 'Claude Code producer adapter: %s/%s checks passed\n' "$passed" "$passed"
