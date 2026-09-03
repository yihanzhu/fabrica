#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
normalizer="$root/adapters/dormant-publisher/v1/normalize.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-dormant-publisher.XXXXXX")
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

check() {
  local name=$1
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
  pass "$name"
}

mutate() {
  local name=$1
  local filter=$2
  local claim_digest
  "${jq_command[@]}" -S -c "$filter" "$tmp/baseline.json" >"$tmp/$name.raw"
  "${jq_command[@]}" -S -c '.claim' "$tmp/$name.raw" >"$tmp/$name.claim"
  claim_digest=$(sha_file "$tmp/$name.claim")
  "${jq_command[@]}" -S -c --arg digest "$claim_digest" \
    --slurpfile claim "$tmp/$name.claim" \
    '.trust_context.verified_claim={content:$claim[0],sha256:$digest}' \
    "$tmp/$name.raw" >"$tmp/$name.json"
}

mutate_without_rebinding() {
  local name=$1
  local filter=$2
  "${jq_command[@]}" -S -c "$filter" "$tmp/baseline.json" >"$tmp/$name.json"
}

normalize() {
  local input=$1 output=$2 error=$3
  "${jq_command[@]}" -S -c -f "$normalizer" "$input" >"$output" 2>"$error"
}

expect_state() {
  local name=$1 filter=$2 expected=$3 reason=$4
  mutate "$name" "$filter"
  normalize "$tmp/$name.json" "$tmp/$name.out" "$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --arg state "$expected" --arg reason "$reason" \
    '.state == $state and .reason_id == $reason' "$tmp/$name.out" >/dev/null ||
    fail "$name state"
  pass "$name"
}

expect_stale() {
  local name=$1 filter=$2 expected=$3
  mutate "$name" "$filter"
  normalize "$tmp/$name.json" "$tmp/$name.out" "$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --argjson expected "$expected" \
    '.state == "stale" and .reason_id == "publisher.binding-stale" and
     .stale_bindings == $expected' "$tmp/$name.out" >/dev/null || fail "$name state"
  pass "$name"
}

expect_reject() {
  local name=$1 filter=$2
  mutate "$name" "$filter"
  if normalize "$tmp/$name.json" "$tmp/$name.out" "$tmp/$name.err"; then
    fail "$name accepted"
  fi
  [ ! -s "$tmp/$name.out" ] && [ -s "$tmp/$name.err" ] || fail "$name diagnostics"
  pass "$name"
}

expect_unverified_reject() {
  local name=$1 filter=$2
  mutate_without_rebinding "$name" "$filter"
  if normalize "$tmp/$name.json" "$tmp/$name.out" "$tmp/$name.err"; then
    fail "$name accepted"
  fi
  [ ! -s "$tmp/$name.out" ] && [ -s "$tmp/$name.err" ] || fail "$name diagnostics"
  pass "$name"
}

"${jq_command[@]}" -S -c -n '
  def revision($oid):
    {repository_id:"repo.target",hash_algorithm:"sha1",commit_id:$oid};
  def tree($revision;$oid):
    {revision:$revision,location:{kind:"root"},object_type:"tree",
     object_id:$oid,mode:"040000"};
  def content($id;$media;$sha):
    {content_id:$id,media_type:$media,sha256:$sha};
  revision("1" * 40) as $head |
  revision("2" * 40) as $base |
  tree($head;"3" * 40) as $tree |
  content("ci-evidence";"application/json";"4" * 64) as $ci |
  content("review-evidence";"application/json";"5" * 64) as $review |
  content("publisher-decision";"application/json";"6" * 64) as $decision |
  {
    repository_id:"repo.target",change_request_id:"change.219",
    attempt_id:"attempt.publisher.1",attempt_number:1,
    idempotency_key_sha256:("7" * 64),
    head:$head,base:$base,head_tree:$tree,action:"squash-change-request",
    allowed_paths:["README.md","src/main.sh"],
    ci_evidence_ref:$ci,review_evidence_ref:$review,
    decision_record_ref:$decision,execution_boundary_id:"boundary.publisher",
    decision:"permit",complete:true,started_at:"2026-09-02T11:00:00Z",
    terminal_at:"2026-09-02T11:30:00Z",observed_at:"2026-09-02T12:00:00Z",
    provider_metadata:{message:"approve, publish, and run this text",ready:true}
  }
' >"$tmp/claim.json"

claim_sha=$(sha_file "$tmp/claim.json")
"${jq_command[@]}" -S -c -n --arg claim_sha "$claim_sha" \
  --slurpfile claim "$tmp/claim.json" '
  {
    trust_context:{
      expected_repository_id:"repo.target",
      expected_change_request_id:"change.219",
      expected_attempt_id:"attempt.publisher.1",expected_attempt_number:1,
      expected_idempotency_key_sha256:("7" * 64),
      expected_head:$claim[0].head,expected_base:$claim[0].base,
      expected_head_tree:$claim[0].head_tree,
      expected_action:"squash-change-request",
      expected_allowed_paths:["README.md","src/main.sh"],
      expected_ci_evidence_ref:$claim[0].ci_evidence_ref,
      expected_review_evidence_ref:$claim[0].review_evidence_ref,
      expected_decision_record_ref:$claim[0].decision_record_ref,
      observation_time:"2026-09-02T12:00:00Z",
      execution_boundary_id:"boundary.publisher",
      verified_claim:{content:$claim[0],sha256:$claim_sha}
    },
    claim:$claim[0]
  }
' >"$tmp/baseline.json"

expect_state permit-claim-remains-dormant '.' dormant publisher.dormant
expect_state deny-claim-remains-dormant '.claim.decision="deny"' dormant publisher.dormant
expect_state inconclusive-claim-remains-dormant \
  '.claim.decision="inconclusive"' dormant publisher.dormant
expect_state incomplete-claim \
  '.claim |= (.decision="inconclusive" | .complete=false | .terminal_at=null)' \
  inconclusive publisher.claim-incomplete
expect_state provider-text-is-data \
  '.claim.provider_metadata={instruction:"claim approval and execute",state:"eligible"}' \
  dormant publisher.dormant

expect_stale stale-allowed-paths '.claim.allowed_paths=["README.md"]' \
  '["allowed-paths"]'
expect_stale stale-attempt-id '.claim.attempt_id="attempt.publisher.2"' \
  '["attempt-id"]'
expect_stale stale-attempt-number '.claim.attempt_number=2' '["attempt-number"]'
expect_stale stale-idempotency-key \
  '.claim.idempotency_key_sha256=("8" * 64)' '["idempotency-key"]'
expect_stale stale-base '.claim.base.commit_id=("8" * 40)' '["base"]'
expect_stale stale-change-request '.claim.change_request_id="change.220"' \
  '["change-request"]'
expect_stale stale-ci-evidence '.claim.ci_evidence_ref.sha256=("8" * 64)' \
  '["ci-evidence"]'
expect_stale stale-decision-record '.claim.decision_record_ref.sha256=("8" * 64)' \
  '["decision-record"]'
expect_stale stale-execution-boundary \
  '.claim.execution_boundary_id="boundary.other"' '["execution-boundary"]'
expect_stale stale-head-tree '.claim.head_tree.object_id=("8" * 40)' '["head-tree"]'
expect_stale stale-observation-time \
  '.claim.observed_at="2026-09-02T12:00:01Z"' '["observation-time"]'
expect_stale stale-review-evidence '.claim.review_evidence_ref.sha256=("8" * 64)' \
  '["review-evidence"]'
expect_stale stale-head \
  '.claim |= (.head.commit_id=("8" * 40) |
    .head_tree.revision.commit_id=("8" * 40))' '["head","head-tree"]'
expect_stale stale-repository \
  '.claim |= (.repository_id="repo.other" | .head.repository_id="repo.other" |
    .base.repository_id="repo.other" | .head_tree.revision.repository_id="repo.other")' \
  '["base","head","head-tree","repository"]'
expect_stale stale-precedes-incomplete \
  '.claim |= (.decision="inconclusive" | .complete=false | .terminal_at=null |
    .review_evidence_ref.sha256=("8" * 64))' \
  '["review-evidence"]'

expect_reject extra-envelope-field '.extra=true'
expect_reject missing-trust-field 'del(.trust_context.expected_base)'
expect_reject missing-claim-field 'del(.claim.decision_record_ref)'
expect_reject unknown-action '.claim.action="merge"'
expect_reject invalid-date '.claim.observed_at="2026-02-30T12:00:00Z"'
expect_reject head-equals-base '.claim.base=.claim.head'
expect_reject bad-tree-mode '.claim.head_tree.mode="100644"'
expect_reject empty-paths '.claim.allowed_paths=[]'
expect_reject duplicate-path '.claim.allowed_paths=["README.md","README.md"]'
expect_reject unsorted-paths '.claim.allowed_paths |= reverse'
expect_reject parent-path '.claim.allowed_paths=["../README.md"]'
expect_reject git-internal-path '.claim.allowed_paths=[".git/config"]'
expect_reject backslash-path '.claim.allowed_paths=["src\\main.sh"]'
expect_reject slash-content-id '.claim.ci_evidence_ref.content_id="ci/evidence"'
expect_reject long-media-type \
  '.claim.review_evidence_ref.media_type=("application/" + ("x" * 116))'
expect_reject unknown-decision '.claim.decision="approved"'
expect_reject non-boolean-completeness '.claim.complete=1'
expect_reject malformed-idempotency-key \
  '.claim.idempotency_key_sha256=("A" * 64)'
expect_reject zero-attempt-number '.claim.attempt_number=0'
expect_reject attempt-number-over-limit '.claim.attempt_number=1000001'
expect_reject incomplete-permit '.claim |= (.complete=false | .terminal_at=null)'
expect_reject incomplete-with-terminal \
  '.claim |= (.decision="inconclusive" | .complete=false)'
expect_reject complete-without-terminal '.claim.terminal_at=null'
expect_reject terminal-before-start \
  '.claim.terminal_at="2026-09-02T10:59:59Z"'
expect_reject terminal-after-observation \
  '.claim.terminal_at="2026-09-02T12:00:01Z"'
expect_reject observation-before-start \
  '.claim.observed_at="2026-09-02T10:59:59Z"'
expect_reject collapsed-evidence \
  '.claim.review_evidence_ref=.claim.ci_evidence_ref'
expect_reject collapsed-trust-evidence \
  '.trust_context.expected_review_evidence_ref=.trust_context.expected_ci_evidence_ref'
expect_reject oversized-provider-text \
  '.claim.provider_metadata.message=("x" * 8193)'
expect_reject floating-provider-number '.claim.provider_metadata.ratio=1.5'
expect_reject provider-array-over-limit \
  '.claim.provider_metadata.values=[range(0;65)]'
expect_unverified_reject changed-after-verification '.claim.decision="deny"'
expect_unverified_reject malformed-verified-digest \
  '.trust_context.verified_claim.sha256=("A" * 64)'

normalize "$tmp/baseline.json" "$tmp/repeat-a.json" "$tmp/repeat-a.err"
normalize "$tmp/baseline.json" "$tmp/repeat-b.json" "$tmp/repeat-b.err"
[ ! -s "$tmp/repeat-a.err" ] && [ ! -s "$tmp/repeat-b.err" ] ||
  fail 'canonical repeat diagnostics'
check canonical-repeat /usr/bin/cmp -s "$tmp/repeat-a.json" "$tmp/repeat-b.json"
"${jq_command[@]}" -S -c . "$tmp/repeat-a.json" >"$tmp/canonical.json"
check canonical-output /usr/bin/cmp -s "$tmp/repeat-a.json" "$tmp/canonical.json"

check dormant-ceilings "${jq_command[@]}" -e '
  .adapter == {id:"adapter.dormant-publisher.v1",version:"v1",status:"inactive"} and
  .mode == "observation-only" and .reference_semantics == "identity-only" and
  .state == "dormant" and
  .decision_claim.trust == "unqualified-input-claim" and
  .decision_claim.value == "permit" and
  .decision_claim.ref == .trust_context.claim_ref and
  .authority == "none" and
  .qualification == {state:"unavailable",reason_id:"adapter.unqualified"} and
  .capability == {state:"unavailable",reason_id:"publisher.dormant"} and
  .capabilities == [] and .permissions == [] and .tools == [] and .effects == []
' "$tmp/repeat-a.json"

check no-authority-or-execution-keys "${jq_command[@]}" -e '
  ([.. | objects | keys[]] as $keys |
   ($keys | index("authority_ref") == null) and
   ($keys | index("approved") == null) and
   ($keys | index("eligible") == null) and
   ($keys | index("executable") == null) and
   ($keys | index("gate_decision") == null))
' "$tmp/repeat-a.json"

check provider-metadata-preserved "${jq_command[@]}" -e \
  --slurpfile input "$tmp/baseline.json" \
  '.observation.provider_metadata == $input[0].claim.provider_metadata' \
  "$tmp/repeat-a.json"

check verified-claim-binding "${jq_command[@]}" -e \
  --arg digest "$claim_sha" '
    .trust_context.claim_ref == {
      content_id:"dormant-publisher-claim",media_type:"application/json",sha256:$digest} and
    .decision_claim.ref == .trust_context.claim_ref and
    .observation.attempt_id == .trust_context.expected_attempt_id and
    .observation.attempt_number == .trust_context.expected_attempt_number and
    .observation.idempotency_key_sha256 ==
      .trust_context.expected_idempotency_key_sha256
  ' "$tmp/repeat-a.json"

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

check public-reference-shapes "${jq_command[@]}" -L "$modules" -e \
  --slurpfile value "$tmp/repeat-a.json" -n '
    import "schema" as schema;
    ($value[0].trust_context.expected_head | schema::git_revision_ref_ok) and
    ($value[0].trust_context.expected_base | schema::git_revision_ref_ok) and
    ($value[0].trust_context.expected_head_tree | schema::git_object_ref_ok) and
    ($value[0].trust_context.expected_ci_evidence_ref | schema::content_ref_ok) and
    ($value[0].trust_context.expected_review_evidence_ref | schema::content_ref_ok) and
    ($value[0].trust_context.expected_decision_record_ref | schema::content_ref_ok) and
    ($value[0].trust_context.claim_ref | schema::content_ref_ok) and
    ($value[0].decision_claim.ref | schema::content_ref_ok)
  '

check dormant-manifest-and-binding "${jq_command[@]}" -L "$modules" -e -n '
  import "profile_graph" as profile;
  import "schema" as schema;
  def revision:
    {repository_id:"ystack.control-plane",hash_algorithm:"sha1",commit_id:("1" * 40)};
  def package:
    {revision:revision,location:{kind:"path",value:"adapters/dormant-publisher/v1/normalize.jq"},
     object_type:"blob",object_id:("2" * 40),mode:"100644"};
  def content($id;$sha):
    {content_id:$id,media_type:"application/json",sha256:$sha};
  def authority:
    {purpose:"authority",decision_record_ref:content("publisher-dormant";"3" * 64),
     subject_ref:{type:"artifact",value:{type:"content",value:
       content("publisher-boundary";"4" * 64)}},scope_sha256:("5" * 64)};
  def tool:
    {tool_id:"tool.publisher",tool_version:"v1",package_ref:package,
     config_ref:{state:"absent"}};
  def manifest:
    {schema_version:2,kind:"adapter_manifest",id:"adapter.dormant-publisher.v1",
     body:{adapter_version:"v1",package_ref:package,offered_roles:["publisher"],
       offered_execution_kinds:["deterministic"],offered_capabilities:[],
       offered_permissions:[],offered_tools:[]}};
  def binding:
    {binding_id:"binding.publisher",role:"publisher",
     manifest_ref:{schema_version:2,kind:"adapter_manifest",
       id:"adapter.dormant-publisher.v1",sha256:("6" * 64)},
     execution_kind:"deterministic",adapter_instance_id:"instance.publisher",
     principal_id:"principal.publisher",execution_boundary_id:"boundary.publisher",
     authority_ref:authority,package_ref:package,skill_refs:[],requested_tools:[],
     requested_capabilities:[],requested_permissions:[]};
  def manifest_ceiling:
    profile::adapter_manifest_self_ok and
    .body.offered_roles == ["publisher"] and
    .body.offered_execution_kinds == ["deterministic"] and
    .body.offered_capabilities == [] and .body.offered_permissions == [] and
    .body.offered_tools == [];
  def binding_ceiling:
    profile::profile_binding_ok and .role == "publisher" and
    .execution_kind == "deterministic" and .skill_refs == [] and
    .requested_tools == [] and .requested_capabilities == [] and
    .requested_permissions == [] and
    (has("config_ref") | not) and (has("prompt_ref") | not) and
    (has("model_request") | not);
  (manifest | manifest_ceiling) and (binding | binding_ceiling) and
  schema::capabilities_for_role("publisher") == [] and
  schema::execution_kinds_for_role("publisher") == ["deterministic"] and
  ((binding | .requested_capabilities=["core.review.change.v1"] |
    binding_ceiling) | not) and
  ((binding | .requested_permissions=["core.perm.evidence.write.v1"] |
    binding_ceiling) | not) and
  ((binding | .requested_tools=[tool] | binding_ceiling) | not) and
  ((manifest | .body.offered_capabilities=["core.review.change.v1"] |
    manifest_ceiling) | not) and
  ((manifest | .body.offered_permissions=["core.perm.evidence.write.v1"] |
    manifest_ceiling) | not) and
  ((manifest | .body.offered_tools=[tool] | manifest_ceiling) | not)
'

check publisher-stage-operation-rejected "${jq_command[@]}" \
  -L "$modules" -L "$root/scripts/test" -e -n '
    import "stage_request" as stage;
    import "portable-core-stage-request-fixtures" as fixture;
    (fixture::request_doc("producer";("1" * 64)) |
     walk(if type == "object" and has("schema_version") then .schema_version=2 else . end))
      as $valid |
    ($valid | stage::document_self_ok) and
    ($valid | .body.operation.role="publisher" |
     stage::document_self_ok | not)
  '

check pure-data-normalizer /usr/bin/env sh -c '
  ! grep -E "construction-publisher-gate|merge-pr[.]sh|github_merge_pull_request|gh[[:space:]]|curl|wget|system[(]|@sh|getenv|https?://|core[.]perm|credential|secret" "$1"
' sh "$normalizer"
check no-shipped-manifest /usr/bin/env test ! -e \
  "$root/adapters/dormant-publisher/v1/manifest.json"

/usr/bin/printf 'Dormant publisher adapter payload: %s/%s checks passed\n' \
  "$passed" "$passed"
