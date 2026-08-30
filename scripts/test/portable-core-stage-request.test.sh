#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

stage_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
stage_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
stage_initial_base="94afa6a925c203051133f3017589f1848ee580c8"
stage_parent_spec="c6511d96c1a5e6aed27ba2075b5add65c121f782"
stage_schema_oid="fd3924d414a7d620c2bf5de919a45c2599d572ec"
stage_ingress_oid="e882b38b0106aac9142c667771f02e3107f8c52f"
stage_profile_oid="48fd185eee7751eedf0ce381b77621e4d7cd1611"
stage_registry_oid="5e113105777694a280166e71d31efd19752e9562"
stage_schema_path="core/v1/generations/$stage_generation/modules/schema.jq"
stage_ingress_path="core/v1/generations/$stage_generation/core-ingress.sh"
stage_profile_path="core/v1/generations/$stage_generation/modules/profile_graph.jq"
stage_module_path="core/v1/generations/$stage_generation/modules/stage_request.jq"
stage_registry_path="core/v1/generation-registry.json"
stage_module_dir="$stage_root/core/v1/generations/$stage_generation/modules"
stage_module="$stage_root/$stage_module_path"
stage_fixture_dir="$stage_root/scripts/test"
stage_fixture="$stage_fixture_dir/portable-core-stage-request-fixtures.jq"
stage_ledger="$stage_fixture_dir/portable-core-stage-request-ledger.tsv"
stage_manifest="$stage_root/ci/required-files.txt"
stage_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-stage.XXXXXX")"
stage_download=""

cleanup() {
  if [ -n "$stage_download" ] && [ -f "$stage_download" ]; then
    rm -f -- "$stage_download"
  fi
  rm -rf -- "$stage_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

stage_platform="$(uname -s):$(uname -m)"
case "$stage_platform" in
  Linux:x86_64)
    stage_asset="jq-linux64"
    stage_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    stage_asset="jq-osx-amd64"
    stage_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $stage_platform" >&2
    exit 1
    ;;
esac

stage_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$stage_cache"
stage_jq="$stage_cache/$stage_asset"
if [ ! -f "$stage_jq" ] ||
   [ "$(sha256_path "$stage_jq")" != "$stage_asset_sha256" ]; then
  stage_download="$(mktemp "$stage_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$stage_asset" \
    -o "$stage_download"
  if [ "$(sha256_path "$stage_download")" != "$stage_asset_sha256" ]; then
    echo "FAIL: jq 1.6 release asset digest mismatch" >&2
    exit 1
  fi
  chmod 0555 "$stage_download"
  mv "$stage_download" "$stage_jq"
  stage_download=""
fi

stage_jq_command=("$stage_jq")
if [ "$stage_platform" = "Darwin:arm64" ]; then
  stage_jq_command=(/usr/bin/arch -x86_64 "$stage_jq")
fi

if [ "$(sha256_path "$stage_jq")" != "$stage_asset_sha256" ] ||
   [ "$("${stage_jq_command[@]}" --version)" != "jq-1.6" ]; then
  echo "FAIL: pinned jq 1.6 identity check failed" >&2
  exit 1
fi

fixture_value() {
  local expression="$1"
  "${stage_jq_command[@]}" -L "$stage_fixture_dir" -S -c -n \
    "import \"portable-core-stage-request-fixtures\" as fixture; $expression"
}

stage_metadata="$(fixture_value 'fixture::metadata')"

roles=(producer publisher reviewer verifier)
manifest_files=()
manifest_shas=()
for index in 0 1 2 3; do
  manifest_file="$stage_tmp/manifest-${roles[$index]}.json"
  "${stage_jq_command[@]}" -L "$stage_fixture_dir" -S -c -n \
    "import \"portable-core-profile-graph-fixtures\" as fixture;
     fixture::manifest_docs[$index]" > "$manifest_file"
  manifest_files+=("$manifest_file")
  manifest_shas+=("$(sha256_path "$manifest_file")")
done

manifest_sha_map="$("${stage_jq_command[@]}" -n \
  --arg producer "${manifest_shas[0]}" \
  --arg publisher "${manifest_shas[1]}" \
  --arg reviewer "${manifest_shas[2]}" \
  --arg verifier "${manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"

profile_file="$stage_tmp/profile.json"
"${stage_jq_command[@]}" -L "$stage_fixture_dir" -S -c -n \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::profile_doc($manifest_shas)' > "$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$stage_tmp/resolved.json"
"${stage_jq_command[@]}" -L "$stage_fixture_dir" -S -c -n \
  --slurpfile profile "$profile_file" \
  --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > \
  "$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

producer_request="$stage_tmp/request-producer.json"
verifier_request="$stage_tmp/request-verifier.json"
reviewer_request="$stage_tmp/request-reviewer.json"
bootstrap_request="$stage_tmp/request-bootstrap.json"
fixture_value "fixture::request_doc(\"producer\";\"$resolved_sha\")" > \
  "$producer_request"
fixture_value "fixture::request_doc(\"verifier\";\"$resolved_sha\")" > \
  "$verifier_request"
fixture_value "fixture::request_doc(\"reviewer\";\"$resolved_sha\")" > \
  "$reviewer_request"
fixture_value "fixture::bootstrap_request_doc(\"$resolved_sha\")" > \
  "$bootstrap_request"

stage_failures=0
stage_direct_total=0
stage_direct_passed=0
stage_cell_total=0
stage_cell_passed=0
stage_forced_total=0
stage_forced_passed=0
stage_layer_total=0
stage_layer_passed=0
stage_guard_total=0
stage_guard_passed=0
stage_seen_rules="$stage_tmp/seen-rules"
stage_seen_tests="$stage_tmp/seen-tests"
: > "$stage_seen_rules"
: > "$stage_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  stage_failures=$((stage_failures + 1))
}

mark_rule() {
  printf '%s\n' "$1" >> "$stage_seen_rules"
}

mark_test() {
  printf '%s\n' "$1" >> "$stage_seen_tests"
}

expect_expression() {
  local case_id="$1"
  local expected="$2"
  local request_file="$3"
  local expression="$4"
  local actual
  stage_direct_total=$((stage_direct_total + 1))
  if ! actual="$("${stage_jq_command[@]}" -L "$stage_module_dir" -n \
      --slurpfile request "$request_file" \
      --slurpfile resolved "$resolved_file" \
      'import "stage_request" as stage_request;
       $request[0] as $request_doc |
       $resolved[0] as $resolved_doc |
       ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    stage_direct_passed=$((stage_direct_passed + 1))
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

expect_true() {
  expect_expression "$1" true "$2" "$3"
}

expect_false() {
  expect_expression "$1" false "$2" "$3"
}

expect_null() {
  expect_expression "$1" null "$2" "$3"
}

mapped_true() {
  mark_test "$1"
  expect_true "$2" "$3" "$4"
}

mapped_false() {
  mark_test "$1"
  expect_false "$2" "$3" "$4"
}

mapped_true portable-core-stage-request.test.legacy-013-validate-document-request \
  producer-self-valid "$producer_request" \
  '$request_doc | stage_request::document_self_ok'
mark_rule portable-core-stage-request.stage-request-self

expect_true verifier-self-valid "$verifier_request" \
  '$request_doc | stage_request::document_self_ok'
expect_true reviewer-self-valid "$reviewer_request" \
  '$request_doc | stage_request::document_self_ok'
expect_true bootstrap-self-valid "$bootstrap_request" \
  '$request_doc | stage_request::document_self_ok'

mapped_false portable-core-stage-request.test.legacy-139-missing-risk \
  missing-risk "$producer_request" \
  '$request_doc | del(.body.risk) | stage_request::stage_request_shape_ok'
mapped_false portable-core-stage-request.test.legacy-141-unknown-core-risk-tier \
  unknown-core-tier "$producer_request" \
  '$request_doc | .body.risk.tier={namespace:"core",name:"unknown"} |
   stage_request::stage_request_shape_ok'
expect_true custom-risk-tier "$producer_request" \
  '$request_doc | .body.risk.tier={namespace:"example.org",name:"tier"} |
   stage_request::stage_request_shape_ok'
expect_false risk-empty-reasons "$producer_request" \
  '$request_doc | .body.risk.reason_ids=[] |
   stage_request::stage_request_shape_ok'
expect_false risk-duplicate-reasons "$producer_request" \
  '$request_doc | .body.risk.reason_ids=["same","same"] |
   stage_request::stage_request_shape_ok'
expect_false risk-wrong-policy-purpose "$producer_request" \
  '$request_doc | .body.risk.policy_ref.purpose="grant" |
   stage_request::stage_request_shape_ok'
expect_false risk-gate-wrong-purpose "$producer_request" \
  '$request_doc | .body.risk.required_gate_refs=[.body.risk.policy_ref] |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.risk-claim

mapped_false portable-core-stage-request.test.legacy-143-operation-permissions-below-the-1-minimum \
  permissions-empty "$producer_request" \
  '$request_doc | .body.operation.permissions=[] |
   stage_request::stage_request_shape_ok'
expect_false permissions-duplicate "$producer_request" \
  '$request_doc | .body.operation.permissions += [.body.operation.permissions[0]] |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.operation-permissions

mapped_false portable-core-stage-request.test.legacy-145-git-patch-arguments-missing-allowed-delta \
  producer-git-patch-missing-delta "$producer_request" \
  '$request_doc | .body.operation.arguments={artifact_kind:"git-patch"} |
   stage_request::stage_request_shape_ok'
expect_true producer-plan-arguments "$producer_request" \
  '$request_doc | .body.operation.arguments.artifact_kind="plan" |
   stage_request::stage_request_shape_ok'
expect_true producer-git-patch-arguments "$producer_request" \
  '$request_doc |
   .body.operation.arguments={artifact_kind:"git-patch",allowed_delta:(.body.operation.arguments.output_contract | .ref.purpose="allowed-delta")} |
   stage_request::stage_request_shape_ok'
expect_false producer-arguments-extra "$producer_request" \
  '$request_doc | .body.operation.arguments.extra=true |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.producer-arguments

expect_false verifier-network-not-denied "$verifier_request" \
  '$request_doc | .body.operation.arguments.network_mode="allow" |
   stage_request::stage_request_shape_ok'
expect_false verifier-candidate-id-missing "$verifier_request" \
  '$request_doc | del(.body.operation.arguments.candidate_input_id) |
   stage_request::stage_request_shape_ok'
expect_false verifier-arguments-extra "$verifier_request" \
  '$request_doc | .body.operation.arguments.command="test" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.verifier-arguments

expect_false reviewer-change-delta-media "$reviewer_request" \
  '$request_doc | .body.operation.arguments.change_ref.delta_ref.media_type="application/json" |
   stage_request::stage_request_shape_ok'
expect_false reviewer-arguments-missing-policy "$reviewer_request" \
  '$request_doc | del(.body.operation.arguments.review_policy) |
   stage_request::stage_request_shape_ok'
expect_false reviewer-arguments-extra "$reviewer_request" \
  '$request_doc | .body.operation.arguments.query="all" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.reviewer-arguments

mapped_false portable-core-stage-request.test.legacy-147-required-evidence-kinds-below-minimum \
  evidence-empty "$producer_request" \
  '$request_doc | .body.required_evidence_kinds=[] |
   stage_request::stage_request_shape_ok'
expect_false evidence-unknown "$producer_request" \
  '$request_doc | .body.required_evidence_kinds=["unknown"] |
   stage_request::stage_request_shape_ok'
mapped_false portable-core-stage-request.test.legacy-149-producer-required-evidence-kinds-must-be-exactly-deterministic \
  producer-wrong-evidence "$producer_request" \
  '$request_doc | .body.required_evidence_kinds=["independent-review"] |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.required-evidence

expect_false operation-extra-field "$producer_request" \
  '$request_doc | .body.operation.extra=true |
   stage_request::stage_request_shape_ok'
expect_false operation-unknown-role "$producer_request" \
  '$request_doc | .body.operation.role="unknown" |
   stage_request::stage_request_shape_ok'
expect_false operation-unknown-capability "$producer_request" \
  '$request_doc | .body.operation.capability_id="core.unknown.v1" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.operation-shape

expect_false body-missing-initiative "$producer_request" \
  '$request_doc | del(.body.initiative_id) |
   stage_request::stage_request_shape_ok'
expect_false body-extra-field "$producer_request" \
  '$request_doc | .body.transport={} |
   stage_request::stage_request_shape_ok'
expect_false body-invalid-workflow "$producer_request" \
  '$request_doc | .body.workflow_id="UPPER" |
   stage_request::stage_request_shape_ok'
expect_false body-invalid-stage "$producer_request" \
  '$request_doc | .body.stage_id="bad/id" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.stage-request-body

expect_false requested-by-unknown-role "$producer_request" \
  '$request_doc | .body.requested_by.role="unknown" |
   stage_request::stage_request_shape_ok'
expect_true requested-by-operator "$producer_request" \
  '$request_doc | .body.requested_by.role="operator" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.requested-by

expect_false target-wrapper-missing-state "$producer_request" \
  '$request_doc | .body.target_revision={} |
   stage_request::stage_request_shape_ok'
expect_false base-wrapper-extra "$producer_request" \
  '$request_doc | .body.base.extra=true |
   stage_request::stage_request_shape_ok'
expect_false source-wrapper-missing-state "$producer_request" \
  '$request_doc | .body.source={} |
   stage_request::stage_request_shape_ok'
expect_false target-revision-algorithm-mismatch "$producer_request" \
  '$request_doc | .body.target_revision.value.hash_algorithm="sha256" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.target-selector-shape

expect_false duplicate-input-id "$producer_request" \
  '$request_doc | .body.inputs += [.body.inputs[0]] |
   stage_request::stage_request_shape_ok'
expect_false input-unknown-document-kind "$producer_request" \
  '$request_doc | .body.inputs += [{input_id:"input.zzz",value:{type:"document",value:{schema_version:1,kind:"unknown",id:"doc",sha256:("0"*64)}}}] |
   stage_request::stage_request_shape_ok'
expect_true input-document-variant "$producer_request" \
  '$request_doc | .body.inputs += [{input_id:"input.zzz",value:{type:"document",value:{schema_version:1,kind:"profile",id:"doc",sha256:("0"*64)}}}] |
   stage_request::stage_request_shape_ok'
expect_false input-count-over-maximum "$producer_request" \
  '$request_doc | .body.inputs=([range(0;257)] | map({input_id:("input." + (.|tostring)),value:{type:"document",value:{schema_version:1,kind:"profile",id:"doc",sha256:("0"*64)}}})) |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.named-input-set

expect_true prior-evidence-valid "$producer_request" \
  '$request_doc | .body.prior_evidence_refs=[{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("1"*64)},evidence_id:"evidence"}] |
   stage_request::stage_request_shape_ok'
expect_false prior-evidence-wrong-kind "$producer_request" \
  '$request_doc | .body.prior_evidence_refs=[{stage_result_ref:{schema_version:1,kind:"profile",id:"result",sha256:("1"*64)},evidence_id:"evidence"}] |
   stage_request::stage_request_shape_ok'
expect_false prior-evidence-duplicate "$producer_request" \
  '$request_doc | .body.prior_evidence_refs=[{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("1"*64)},evidence_id:"evidence"},{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("1"*64)},evidence_id:"evidence"}] |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.prior-evidence-set

expect_false resolved-ref-wrong-kind "$producer_request" \
  '$request_doc | .body.resolved_profile_ref.kind="profile" |
   stage_request::stage_request_shape_ok'
expect_false selection-wrong-purpose "$producer_request" \
  '$request_doc | .body.selection_ref.purpose="grant" |
   stage_request::stage_request_shape_ok'
expect_false repository-context-wrong-purpose "$producer_request" \
  '$request_doc | .body.repository_context_ref.purpose="policy" |
   stage_request::stage_request_shape_ok'
expect_true optional-qualification-valid "$producer_request" \
  '$request_doc | .body.qualification_ref=(.body.selection_ref | .purpose="qualification") |
   stage_request::stage_request_shape_ok'
expect_false optional-qualification-wrong-purpose "$producer_request" \
  '$request_doc | .body.qualification_ref=.body.selection_ref |
   stage_request::stage_request_shape_ok'
expect_true optional-grant-valid "$producer_request" \
  '$request_doc | .body.grant_ref=(.body.selection_ref | .purpose="grant") |
   stage_request::stage_request_shape_ok'
expect_false optional-grant-wrong-purpose "$producer_request" \
  '$request_doc | .body.grant_ref=.body.selection_ref |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.resolved-context-shape

expect_false gate-decision-wrong-purpose "$producer_request" \
  '$request_doc | .body.gate_decision_refs=[.body.selection_ref] |
   stage_request::stage_request_shape_ok'
expect_false gate-decision-duplicate "$producer_request" \
  '$request_doc | (.body.selection_ref | .purpose="gate-decision") as $decision |
   .body.gate_decision_refs=[$decision,$decision] |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.gate-decision-set

expect_false environment-bad-digest "$producer_request" \
  '$request_doc | .body.environment_ref.fingerprint_sha256="bad" |
   stage_request::stage_request_shape_ok'
expect_false environment-extra-field "$producer_request" \
  '$request_doc | .body.environment_ref.region="host" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.environment-shape

expect_false finish-wrong-purpose "$producer_request" \
  '$request_doc | .body.finish_condition.ref.purpose="policy" |
   stage_request::stage_request_shape_ok'
expect_false verification-wrong-purpose "$producer_request" \
  '$request_doc | .body.verification_instruction.ref.purpose="policy" |
   stage_request::stage_request_shape_ok'
expect_false instruction-document-subject "$producer_request" \
  '$request_doc | .body.finish_condition.ref.subject_ref={type:"document",value:.body.resolved_profile_ref} |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.instruction-shape

expect_false requested-at-invalid "$producer_request" \
  '$request_doc | .body.requested_at="not-a-time" |
   stage_request::stage_request_shape_ok'
expect_false requested-at-impossible-date "$producer_request" \
  '$request_doc | .body.requested_at="2026-02-31T00:00:00Z" |
   stage_request::stage_request_shape_ok'
expect_true requested-at-leap-date "$producer_request" \
  '$request_doc | .body.requested_at="2024-02-29T00:00:00Z" |
   stage_request::stage_request_shape_ok'
mark_rule portable-core-stage-request.requested-at

mapped_false portable-core-stage-request.test.verifier-independent-review-request-rejected \
  verifier-independent-review "$verifier_request" \
  '$request_doc | .body.required_evidence_kinds=["deterministic","independent-review"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true verifier-deterministic-only "$verifier_request" \
  '$request_doc | .body.required_evidence_kinds=["deterministic"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true verifier-behavioral "$verifier_request" \
  '$request_doc | .body.required_evidence_kinds=["behavioral","deterministic"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true verifier-architecture "$verifier_request" \
  '$request_doc | .body.required_evidence_kinds=["architecture","deterministic"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_false reviewer-deterministic-evidence "$reviewer_request" \
  '$request_doc | .body.required_evidence_kinds=["deterministic"] |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.verifier-evidence-allowlist

expect_false producer-role-capability-mismatch "$producer_request" \
  '$request_doc | .body.operation.capability_id="core.review.change.v1" |
   .body.operation.arguments={change_ref:{repository_id:"repo.example",base:.body.base,head:.body.target_revision.value,delta_ref:{content_id:"delta",media_type:"text/x-diff",sha256:("0"*64)}},review_policy:.body.finish_condition} |
   .body.operation.arguments.review_policy.ref.purpose="review-policy" |
   .body | stage_request::stage_request_self_relations_ok'
expect_false dormant-role-capability "$producer_request" \
  '$request_doc | .body.operation.role="publisher" |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.capability-role-closure

expect_false arbitrary-permission-subset "$producer_request" \
  '$request_doc | .body.operation.permissions=["core.perm.target.read.v1"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true deterministic-producer-permissions "$producer_request" \
  '$request_doc | .body.operation.permissions=["core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.selected-binding-closure

mapped_false portable-core-stage-request.test.legacy-151-finish-condition-and-verification-instruction-share-one-input-id \
  duplicate-finish-verification-input "$producer_request" \
  '$request_doc | .body.finish_condition.input_id=.body.verification_instruction.input_id |
   .body | stage_request::stage_request_self_relations_ok'
expect_false capability-scope-duplicates-finish "$producer_request" \
  '$request_doc | .body.operation.arguments.output_contract.input_id=.body.finish_condition.input_id |
   .body | stage_request::stage_request_self_relations_ok'
expect_false verifier-candidate-duplicates-plan "$verifier_request" \
  '$request_doc | .body.operation.arguments.candidate_input_id=.body.operation.arguments.verification_plan.input_id |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.instruction-input-distinct

mapped_false portable-core-stage-request.test.delivered-scope-input-id-subject-media \
  delivered-input-id-missing "$producer_request" \
  '$request_doc | .body.finish_condition.input_id="input.missing" |
   .body | stage_request::stage_request_self_relations_ok'
expect_false delivered-subject-mismatch "$producer_request" \
  '$request_doc | .body.finish_condition.ref.subject_ref=.body.verification_instruction.ref.subject_ref |
   .body | stage_request::stage_request_self_relations_ok'
expect_false delivered-media-disallowed "$producer_request" \
  '$request_doc |
   .body.finish_condition.ref.subject_ref.value.value.media_type="application/octet-stream" |
   .body.inputs |= map(if .input_id=="input.finish" then .value.value.value.media_type="application/octet-stream" else . end) |
   .body | stage_request::stage_request_self_relations_ok'
expect_true delivered-text-media "$producer_request" \
  '$request_doc |
   .body.finish_condition.ref.subject_ref.value.value.media_type="text/plain" |
   .body.inputs |= map(if .input_id=="input.finish" then .value.value.value.media_type="text/plain" else . end) |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.delivered-scope-input-closure

mapped_false portable-core-stage-request.test.cross-repository-request-ref-rejected \
  source-cross-repository "$producer_request" \
  '$request_doc | .body.source.value.value.revision.repository_id="repo.other" |
   .body | stage_request::stage_request_self_relations_ok'
expect_false target-cross-repository "$producer_request" \
  '$request_doc | .body.target_revision.value.repository_id="repo.other" |
   .body | stage_request::stage_request_self_relations_ok'
expect_false base-cross-repository "$producer_request" \
  '$request_doc | .body.base.value.repository_id="repo.other" |
   .body | stage_request::stage_request_self_relations_ok'
expect_false input-cross-repository "$verifier_request" \
  '$request_doc | .body.inputs |= map(if .input_id=="input.candidate" then .value.value.value.revision.repository_id="repo.other" else . end) |
   .body | stage_request::stage_request_self_relations_ok'
expect_false review-change-cross-repository "$reviewer_request" \
  '$request_doc | .body.operation.arguments.change_ref.repository_id="repo.other" |
   .body | stage_request::stage_request_self_relations_ok'
expect_true resolved-sources-not-target-inputs "$producer_request" \
  '($resolved_doc | .body.bindings[0].package_source.source.revision.repository_id="repo.other") as $moved |
   ($moved | type=="object") and
   ($request_doc.body | stage_request::stage_request_self_relations_ok)'
mark_rule portable-core-stage-request.request-git-ref-repository-closure

mapped_false portable-core-stage-request.test.verifier-blob-candidate-rejected \
  verifier-blob-candidate "$verifier_request" \
  '$request_doc |
   .body.inputs |= map(if .input_id=="input.candidate" then .value.value.value.location={kind:"path",value:"candidate.bin"} | .value.value.value.object_type="blob" | .value.value.value.mode="100644" else . end) |
   .body | stage_request::stage_request_self_relations_ok'
expect_false verifier-candidate-revision-mismatch "$verifier_request" \
  '$request_doc |
   .body.inputs |= map(if .input_id=="input.candidate" then .value.value.value.revision.commit_id=("2"*40) else . end) |
   .body | stage_request::stage_request_self_relations_ok'
expect_false verifier-candidate-input-missing "$verifier_request" \
  '$request_doc | .body.inputs |= map(select(.input_id!="input.candidate")) |
   .body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.verifier-candidate-tree

expect_false reviewer-head-mismatch "$reviewer_request" \
  '$request_doc | .body.operation.arguments.change_ref.head.commit_id=("3"*40) |
   .body | stage_request::stage_request_self_relations_ok'
expect_true reviewer-head-match "$reviewer_request" \
  '$request_doc.body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.reviewer-change-head-equality

mapped_false portable-core-stage-request.test.reviewer-change-base-wrapper-equality \
  reviewer-base-wrapper-mismatch "$reviewer_request" \
  '$request_doc | .body.operation.arguments.change_ref.base={state:"absent"} |
   .body | stage_request::stage_request_self_relations_ok'
expect_true reviewer-base-wrapper-match "$reviewer_request" \
  '$request_doc.body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.reviewer-change-base-equality

mapped_false portable-core-stage-request.test.absent-target-nonbootstrap-rejected \
  absent-target-routine "$producer_request" \
  '$request_doc | .body.target_revision={state:"absent"} |
   .body | stage_request::stage_request_self_relations_ok'
mapped_false portable-core-stage-request.test.legacy-157-absent-target-requires-bootstrap-risk-tier-not-merely-a-producer-role \
  absent-target-high "$bootstrap_request" \
  '$request_doc | .body.risk.tier={namespace:"core",name:"high"} |
   .body | stage_request::stage_request_self_relations_ok'
mapped_false portable-core-stage-request.test.legacy-155-bootstrap-producer-only-rule-violated-by-a-non-producer-role \
  absent-target-nonproducer "$bootstrap_request" \
  '$request_doc | .body.operation.role="reviewer" |
   .body | stage_request::stage_request_self_relations_ok'
expect_true absent-target-bootstrap-producer "$bootstrap_request" \
  '$request_doc.body | stage_request::stage_request_self_relations_ok'
mark_rule portable-core-stage-request.absent-target-bootstrap
mark_rule portable-core-stage-request.absent-target-bootstrap-producer-only

expect_true exact-resolved-ref "$producer_request" \
  '{content:$request_doc,sha256:("1"*64)} as $request_pair |
   {content:$resolved_doc,sha256:$request_doc.body.resolved_profile_ref.sha256} as $resolved_pair |
   stage_request::stage_request_resolved_ref_ok($request_pair;$resolved_pair)'
expect_false resolved-ref-digest-mismatch "$producer_request" \
  '{content:$request_doc,sha256:("1"*64)} as $request_pair |
   {content:$resolved_doc,sha256:("0"*64)} as $resolved_pair |
   stage_request::stage_request_resolved_ref_ok($request_pair;$resolved_pair)'
expect_false resolved-ref-id-mismatch "$producer_request" \
  '($resolved_doc | .id="resolved.other") as $moved |
   stage_request::stage_request_resolved_ref_ok(
     {content:$request_doc,sha256:("1"*64)};
     {content:$moved,sha256:$request_doc.body.resolved_profile_ref.sha256})'
mark_rule portable-core-stage-request.resolved-profile-ref

expect_true producer-cross-relation "$producer_request" \
  'stage_request::stage_request_resolved_relation_ok($request_doc.body;$resolved_doc.body)'
expect_true verifier-cross-relation "$verifier_request" \
  'stage_request::stage_request_resolved_relation_ok($request_doc.body;$resolved_doc.body)'
expect_true reviewer-cross-relation "$reviewer_request" \
  'stage_request::stage_request_resolved_relation_ok($request_doc.body;$resolved_doc.body)'
expect_false selection-context-mismatch "$producer_request" \
  '$request_doc | .body.selection_ref.scope_sha256=("0"*64) |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
expect_false repository-context-mismatch "$producer_request" \
  '$request_doc | .body.repository_context_ref.scope_sha256=("0"*64) |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
mark_rule portable-core-stage-request.selection-context-relation

mapped_false portable-core-stage-request.test.legacy-229-request-operation-names-a-binding-absent-from-the-resolved-profile \
  binding-not-found "$producer_request" \
  '$request_doc | .body.operation.binding_id="binding.missing" |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
expect_false binding-not-unique "$producer_request" \
  '$resolved_doc | .body.bindings += [.body.bindings[0]] |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'
mark_rule portable-core-stage-request.binding-selection

expect_false selected-binding-role-mismatch "$producer_request" \
  '$resolved_doc | .body.bindings |= map(if .binding.binding_id=="binding.producer" then .binding.role="reviewer" else . end) |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'
expect_false selected-binding-capabilities-empty "$producer_request" \
  '$resolved_doc | .body.bindings |= map(if .binding.binding_id=="binding.producer" then .binding.requested_capabilities=[] else . end) |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'
expect_false selected-binding-capability-wrong "$producer_request" \
  '$resolved_doc | .body.bindings |= map(if .binding.binding_id=="binding.producer" then .binding.requested_capabilities=["core.review.change.v1"] else . end) |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'
expect_false selected-binding-permissions-mismatch "$producer_request" \
  '$resolved_doc | .body.bindings |= map(if .binding.binding_id=="binding.producer" then .binding.requested_permissions=["core.perm.target.read.v1"] else . end) |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'
expect_false request-binding-permissions-mismatch "$producer_request" \
  '$request_doc | .body.operation.permissions=["core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
expect_false binding-policy-permissions-mismatch "$producer_request" \
  '$resolved_doc | .body.bindings |= map(if .binding.binding_id=="binding.producer" then .binding.execution_kind="deterministic" else . end) |
   stage_request::stage_request_resolved_relation_ok($request_doc.body;.body)'

expect_true projection-object "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) | type=="object"'
expect_true projection-actual-binding "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.actual_binding.binding_id=="binding.producer" and
   $projection.actual_binding.config_ref.state=="present" and
   $projection.actual_binding.authority_ref==$resolved_doc.body.bindings[0].binding.authority_ref'
expect_true projection-performer "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.performer.role=="producer" and
   $projection.performer.implementation_id=="manifest.producer" and
   $projection.performer.principal_id=="principal.producer"'
expect_true projection-environment-capability "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.environment==$request_doc.body.environment_ref and
   $projection.used_capability=={kind:"registered",id:"core.harness.produce.v1"}'
expect_true projection-model-expectation "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.execution_kind=="model" and
   $projection.metadata_expectation.model_request.state=="present" and
   $projection.metadata_expectation.prompt_ref.state=="present" and
   $projection.metadata_expectation.skill_refs==$resolved_doc.body.bindings[0].binding.skill_refs'
expect_true projection-tools-allowlist "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body).metadata_expectation.allowed_tools ==
   $resolved_doc.body.bindings[0].binding.requested_tools'
expect_true projection-excludes-snapshot "$producer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body).metadata_expectation | has("snapshot") | not'
expect_true deterministic-projection "$verifier_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.execution_kind=="deterministic" and
   $projection.actual_binding.config_ref.state=="absent" and
   $projection.metadata_expectation.model_request.state=="absent" and
   $projection.metadata_expectation.prompt_ref.state=="absent" and
   $projection.metadata_expectation.skill_refs==[] and
   $projection.metadata_expectation.allowed_tools==[]'
expect_null invalid-projection-is-null "$producer_request" \
  '$request_doc | .body.operation.binding_id="binding.missing" |
   stage_request::expected_execution_projection(.body;$resolved_doc.body)'
mark_rule portable-core-stage-request.expected-execution-projection

expect_false initiative-uppercase-rejected "$producer_request" \
  '$request_doc | .body.initiative_id="Initiative" |
   stage_request::stage_request_shape_ok'
expect_false task-class-path-rejected "$producer_request" \
  '$request_doc | .body.task_class_id="task/class" |
   stage_request::stage_request_shape_ok'
expect_false requested-by-extra-authority-field "$producer_request" \
  '$request_doc | .body.requested_by.extra=true |
   stage_request::stage_request_shape_ok'
expect_true content-source-valid "$producer_request" \
  '$request_doc | .body.source={state:"present",value:{type:"content",value:{content_id:"source",media_type:"application/json",sha256:("0"*64)}}} |
   stage_request::stage_request_shape_ok'
expect_true absent-source-valid "$producer_request" \
  '$request_doc | .body.source={state:"absent"} |
   stage_request::stage_request_self_ok'
expect_true absent-base-valid-producer "$producer_request" \
  '$request_doc | .body.base={state:"absent"} |
   stage_request::stage_request_self_ok'
expect_false source-document-union-rejected "$producer_request" \
  '$request_doc | .body.source={state:"present",value:{type:"document",value:.body.resolved_profile_ref}} |
   stage_request::stage_request_shape_ok'
expect_false prior-evidence-bad-id "$producer_request" \
  '$request_doc | .body.prior_evidence_refs=[{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("1"*64)},evidence_id:"bad/id"}] |
   stage_request::stage_request_shape_ok'
expect_true risk-two-reasons-sorted "$producer_request" \
  '$request_doc | .body.risk.reason_ids=["reason.a","reason.b"] |
   stage_request::stage_request_shape_ok'
expect_false risk-reasons-unsorted "$producer_request" \
  '$request_doc | .body.risk.reason_ids=["reason.b","reason.a"] |
   stage_request::stage_request_shape_ok'
expect_true one-gate-decision-valid "$producer_request" \
  '$request_doc | .body.gate_decision_refs=[(.body.selection_ref | .purpose="gate-decision")] |
   stage_request::stage_request_shape_ok'
expect_false gate-decisions-unsorted "$producer_request" \
  '$request_doc | (.body.selection_ref | .purpose="gate-decision" | .scope_sha256=("f"*64)) as $later |
   (.body.selection_ref | .purpose="gate-decision" | .scope_sha256=("0"*64)) as $earlier |
   .body.gate_decision_refs=[$later,$earlier] |
   stage_request::stage_request_shape_ok'
expect_true structured-artifact-output "$producer_request" \
  '$request_doc | .body.operation.arguments.artifact_kind="structured-artifact" |
   stage_request::stage_request_self_ok'
expect_false output-contract-wrong-purpose "$producer_request" \
  '$request_doc | .body.operation.arguments.output_contract.ref.purpose="allowed-delta" |
   stage_request::stage_request_shape_ok'
expect_false verification-plan-wrong-purpose "$verifier_request" \
  '$request_doc | .body.operation.arguments.verification_plan.ref.purpose="review-policy" |
   stage_request::stage_request_shape_ok'
expect_false review-policy-wrong-purpose "$reviewer_request" \
  '$request_doc | .body.operation.arguments.review_policy.ref.purpose="verification-plan" |
   stage_request::stage_request_shape_ok'
expect_false producer-behavioral-evidence "$producer_request" \
  '$request_doc | .body.required_evidence_kinds=["behavioral","deterministic"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_false reviewer-mixed-evidence "$reviewer_request" \
  '$request_doc | .body.required_evidence_kinds=["deterministic","independent-review"] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true reviewer-absent-base-wrapper "$reviewer_request" \
  '$request_doc | .body.base={state:"absent"} |
   .body.operation.arguments.change_ref.base={state:"absent"} |
   stage_request::stage_request_self_ok'
expect_false reviewer-different-present-base "$reviewer_request" \
  '$request_doc | .body.operation.arguments.change_ref.base.value.commit_id=("4"*40) |
   .body | stage_request::stage_request_self_relations_ok'
expect_true document-input-repository-neutral "$producer_request" \
  '$request_doc | .body.inputs += [{input_id:"input.zzz",value:{type:"document",value:{schema_version:1,kind:"profile",id:"profile",sha256:("0"*64)}}}] |
   .body | stage_request::stage_request_self_relations_ok'
expect_true content-input-repository-neutral "$producer_request" \
  '$request_doc.body | stage_request::stage_request_self_relations_ok'
expect_false cross-operation-role-mismatch "$producer_request" \
  '$request_doc | .body.operation.role="reviewer" |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
expect_null projection-permission-mismatch-null "$producer_request" \
  '$request_doc | .body.operation.permissions=["core.perm.target.read.v1"] |
   stage_request::expected_execution_projection(.body;$resolved_doc.body)'
expect_true reviewer-projection-model "$reviewer_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.performer.role=="reviewer" and
   $projection.metadata_expectation.model_request.value.model_id=="review.example" and
   $projection.metadata_expectation.allowed_tools==[]'
expect_true verifier-projection-registered-capability "$verifier_request" \
  'stage_request::expected_execution_projection($request_doc.body;$resolved_doc.body) as $projection |
   $projection.performer.role=="verifier" and
   $projection.used_capability.id=="core.verify.run.v1" and
   $projection.actual_binding.execution_kind=="deterministic"'
expect_false custom-tier-single-label-namespace "$producer_request" \
  '$request_doc | .body.risk.tier={namespace:"custom",name:"tier"} |
   stage_request::stage_request_shape_ok'
expect_false inputs-unsorted "$producer_request" \
  '$request_doc | .body.inputs |= reverse |
   stage_request::stage_request_shape_ok'
expect_false operation-permissions-unsorted "$producer_request" \
  '$request_doc | .body.operation.permissions |= reverse |
   stage_request::stage_request_shape_ok'
expect_false required-evidence-unsorted "$verifier_request" \
  '$request_doc | .body.required_evidence_kinds |= reverse |
   stage_request::stage_request_shape_ok'
expect_false risk-gates-unsorted "$producer_request" \
  '$request_doc | (.body.selection_ref | .purpose="gate-requirement" | .scope_sha256=("f"*64)) as $later |
   (.body.selection_ref | .purpose="gate-requirement" | .scope_sha256=("0"*64)) as $earlier |
   .body.risk.required_gate_refs=[$later,$earlier] |
   stage_request::stage_request_shape_ok'
expect_false evidence-refs-unsorted "$producer_request" \
  '$request_doc | .body.prior_evidence_refs=[{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("f"*64)},evidence_id:"z"},{stage_result_ref:{schema_version:1,kind:"stage_result",id:"result",sha256:("0"*64)},evidence_id:"a"}] |
   stage_request::stage_request_shape_ok'

run_counted_expression() {
  local counter="$1"
  local case_id="$2"
  local expected="$3"
  local request_file="$4"
  local expression="$5"
  local actual
  case "$counter" in
    cell) stage_cell_total=$((stage_cell_total + 1)) ;;
    forced) stage_forced_total=$((stage_forced_total + 1)) ;;
    layer) stage_layer_total=$((stage_layer_total + 1)) ;;
  esac
  if ! actual="$("${stage_jq_command[@]}" -r -L "$stage_module_dir" -n \
      --slurpfile request "$request_file" \
      --slurpfile resolved "$resolved_file" \
      'import "stage_request" as stage_request;
       $request[0] as $request_doc |
       $resolved[0] as $resolved_doc |
       ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    case "$counter" in
      cell) stage_cell_passed=$((stage_cell_passed + 1)) ;;
      forced) stage_forced_passed=$((stage_forced_passed + 1)) ;;
      layer) stage_layer_passed=$((stage_layer_passed + 1)) ;;
    esac
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

run_counted_expression cell document-self-cell true "$producer_request" \
  '$request_doc | stage_request::document_self_ok'
run_counted_expression cell stage-run-self-cell true "$verifier_request" \
  '$request_doc | stage_request::stage_request_self_ok'
run_counted_expression cell stage-run-cross-cell true "$reviewer_request" \
  'stage_request::stage_request_resolved_relation_ok($request_doc.body;$resolved_doc.body)'

run_counted_expression forced document-forced-route false "$producer_request" \
  '$request_doc | del(.body.risk) | stage_request::document_self_ok'
run_counted_expression forced stage-run-self-forced-route false "$producer_request" \
  '$request_doc | .body.finish_condition.input_id="input.missing" |
   stage_request::stage_request_self_ok'
run_counted_expression forced stage-run-cross-forced-route false "$producer_request" \
  '$request_doc | .body.operation.binding_id="binding.missing" |
   stage_request::stage_request_resolved_relation_ok(.body;$resolved_doc.body)'
mark_rule portable-core-stage-request.document-routing

layer_classifier='def classify($request_doc;$resolved_doc;$resolved_sha):
  if ($request_doc | stage_request::stage_request_shape_ok | not) then "E_SHAPE"
  elif (stage_request::stage_request_resolved_ref_ok(
          {content:$request_doc,sha256:("1"*64)};
          {content:$resolved_doc,sha256:$resolved_sha}) | not) then "E_REF"
  elif ($request_doc.body | stage_request::stage_request_self_relations_ok | not) then "E_RELATION"
  elif (stage_request::stage_request_resolved_relation_ok($request_doc.body;$resolved_doc.body) | not) then "E_RELATION"
  else "OK"
  end;'

run_counted_expression layer shape-layer E_SHAPE "$producer_request" \
  "${layer_classifier}"' classify(($request_doc | del(.body.risk));$resolved_doc;$request_doc.body.resolved_profile_ref.sha256)'
run_counted_expression layer local-relation-layer E_RELATION "$producer_request" \
  "${layer_classifier}"' classify(($request_doc | .body.required_evidence_kinds=["independent-review"]);
            $resolved_doc;$request_doc.body.resolved_profile_ref.sha256)'
run_counted_expression layer resolved-ref-layer E_REF "$producer_request" \
  "${layer_classifier}"' classify($request_doc;$resolved_doc;("0"*64))'
run_counted_expression layer cross-relation-layer E_RELATION "$producer_request" \
  "${layer_classifier}"' classify(($request_doc | .body.selection_ref.scope_sha256=("0"*64));
            $resolved_doc;$request_doc.body.resolved_profile_ref.sha256)'

guard_pass() {
  stage_guard_total=$((stage_guard_total + 1))
  stage_guard_passed=$((stage_guard_passed + 1))
}

guard_fail() {
  stage_guard_total=$((stage_guard_total + 1))
  fail_case "$1"
}

current_blob_ok() {
  local repository="$1"
  local path="$2"
  local expected_oid="$3"
  local mode type oid actual_path
  IFS=$' \t' read -r mode type oid actual_path < <(
    git -C "$repository" ls-tree HEAD -- "$path"
  ) || return 1
  [ "$mode" = 100644 ] && [ "$type" = blob ] &&
    [ "$oid" = "$expected_oid" ] && [ "$actual_path" = "$path" ]
}

if current_blob_ok "$stage_root" "$stage_schema_path" "$stage_schema_oid"; then
  guard_pass
else
  guard_fail "schema G3 export pin"
fi

if current_blob_ok "$stage_root" "$stage_ingress_path" "$stage_ingress_oid"; then
  guard_pass
else
  guard_fail "ingress serial predecessor pin"
fi

if current_blob_ok "$stage_root" "$stage_profile_path" "$stage_profile_oid"; then
  guard_pass
else
  guard_fail "profile-graph G3 export pin"
fi

if current_blob_ok "$stage_root" "$stage_registry_path" "$stage_registry_oid"; then
  guard_pass
else
  guard_fail "generation registry pin"
fi

if [ "$("${stage_jq_command[@]}" -r '.construction_base' <<< "$stage_metadata")" = "$stage_initial_base" ] &&
   [ "$("${stage_jq_command[@]}" -r '.generation_id' <<< "$stage_metadata")" = "$stage_generation" ] &&
   [ "$("${stage_jq_command[@]}" -r '.parent_spec_blob' <<< "$stage_metadata")" = "$stage_parent_spec" ] &&
   [ "$("${stage_jq_command[@]}" -r '.schema_g3_comment' <<< "$stage_metadata")" -eq 5466181650 ] &&
   [ "$("${stage_jq_command[@]}" -r '.schema_export_oid' <<< "$stage_metadata")" = "$stage_schema_oid" ] &&
   [ "$("${stage_jq_command[@]}" -r '.ingress_g3_comment' <<< "$stage_metadata")" -eq 5468279667 ] &&
   [ "$("${stage_jq_command[@]}" -r '.ingress_export_oid' <<< "$stage_metadata")" = "$stage_ingress_oid" ] &&
   [ "$("${stage_jq_command[@]}" -r '.profile_g3_comment' <<< "$stage_metadata")" -eq 5468723218 ] &&
   [ "$("${stage_jq_command[@]}" -r '.profile_merge_commit' <<< "$stage_metadata")" = "fbe3850b94bfa153a169d5bb67348c1b312e3be6" ] &&
   [ "$("${stage_jq_command[@]}" -r '.profile_export_oid' <<< "$stage_metadata")" = "$stage_profile_oid" ] &&
   [ "$("${stage_jq_command[@]}" -r '.registry_oid' <<< "$stage_metadata")" = "$stage_registry_oid" ]; then
  guard_pass
else
  guard_fail "fixture dependency metadata"
fi

if [ "$(git -C "$stage_root" hash-object config/construction-mode.json)" = \
     "4f35b0ec232e584973071a8d2e90ee5971af6e79" ] &&
   [ "$(git -C "$stage_root" hash-object ROADMAP.md)" = \
     "4bb0fff1ee11c20441cc16182337f762300ac0f2" ] &&
   [ "$(git -C "$stage_root" hash-object NORTH_STAR.md)" = \
     "d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013" ]; then
  guard_pass
else
  guard_fail "construction identity"
fi

expected_imports='import "schema" as schema;
import "profile_graph" as profile_graph;'
if [ "$(grep '^import ' "$stage_module")" = "$expected_imports" ] &&
   [ "$(grep -c '^import ' "$stage_module")" -eq 2 ]; then
  guard_pass
else
  guard_fail "fixed product imports"
fi
mark_rule portable-core-stage-request.fixed-imports

if ! grep -Eq '(^|[^a-z])(gh|glab|curl|wget|system|env|input_filename)([^a-z]|$)|@sh|transport_frame|raw_bytes' \
     "$stage_module"; then
  guard_pass
else
  guard_fail "forbidden product execution or transport surface"
fi

if ! grep -Eq '^[[:space:]]*import |schema::|profile_graph::|stage_request::' \
     "$stage_fixture"; then
  guard_pass
else
  guard_fail "fixture must remain data only"
fi

stage_review_total="$(awk -F '\t' 'NR>1 && $1=="review" {n++} END {print n+0}' "$stage_ledger")"
stage_legacy_total="$(awk -F '\t' 'NR>1 && $1=="legacy" {n++} END {print n+0}' "$stage_ledger")"
if [ "$stage_review_total" -eq 6 ] && [ "$stage_legacy_total" -eq 22 ] &&
   [ "$(wc -l < "$stage_ledger" | tr -d ' ')" -eq 29 ] &&
   [ "$(tail -n +2 "$stage_ledger" | cut -f2 | LC_ALL=C sort -u | wc -l | tr -d ' ')" -eq 28 ] &&
   [ "$(awk -F '\t' 'NR>1 && $3=="ported" {n++} END {print n+0}' "$stage_ledger")" -eq 28 ] &&
   [ "$(sha256_path "$stage_ledger")" = \
     "$("${stage_jq_command[@]}" -r '.mapping_sha256' <<< "$stage_metadata")" ] &&
   [ "$("${stage_jq_command[@]}" -r '.review_r0_source_sha256' <<< "$stage_metadata")" = \
     "6361652d62ab94471139e767bc6240385959aafc8f1e7ebf1f0748e9037c1079" ] &&
   [ "$("${stage_jq_command[@]}" -r '.review_r3_source_sha256' <<< "$stage_metadata")" = \
     "5398fb81ddacdc13879ccb6ffcbfa2c280068caa45cca69c6fb2104acab46c53" ] &&
   [ "$("${stage_jq_command[@]}" -r '.legacy_source_sha256' <<< "$stage_metadata")" = \
     "ee195ecc61f07a4cdf81bbec12fd8d80a6895520a6103cc64faa4e1a0cb77488" ]; then
  guard_pass
else
  guard_fail "frozen migration ledger"
fi

required_paths="$stage_module_path
scripts/test/portable-core-stage-request-fixtures.jq
scripts/test/portable-core-stage-request-ledger.tsv
scripts/test/portable-core-stage-request.test.sh"
manifest_ok=true
while IFS= read -r required_path; do
  [ "$(grep -Fxc "$required_path" "$stage_manifest" || true)" -eq 1 ] &&
    [ -f "$stage_root/$required_path" ] || manifest_ok=false
done <<< "$required_paths"
if [ "$manifest_ok" = true ]; then
  guard_pass
else
  guard_fail "restore manifest coverage"
fi

manifest_prefix="$stage_tmp/manifest-prefix"
head -n 108 "$stage_manifest" > "$manifest_prefix"
if [ "$(sha256_path "$manifest_prefix")" = \
     "f07a3325080bf7c3ad98a2aaaa70f6d89f781d110f7f400be3729c0ddb0c25c6" ] &&
   [ "$(sed -n '109,112p' "$stage_manifest")" = "$required_paths" ]; then
  guard_pass
else
  guard_fail "restore manifest exact append"
fi
mark_rule portable-core-stage-request.restore-manifest

generation_files="$stage_tmp/generation-files"
find "$stage_root/core/v1/generations/$stage_generation" -type f -print |
  sed "s#^$stage_root/##" | LC_ALL=C sort > "$generation_files"
generation_members_ok=true
while IFS= read -r generation_file; do
  case "$generation_file" in
    "core/v1/generations/$stage_generation/core-ingress.sh"|\
    "core/v1/generations/$stage_generation/contracts.jq"|\
    "core/v1/generations/$stage_generation/modules/schema.jq"|\
    "core/v1/generations/$stage_generation/modules/profile_graph.jq"|\
    "core/v1/generations/$stage_generation/modules/stage_request.jq"|\
    "core/v1/generations/$stage_generation/modules/result_facts.jq"|\
    "core/v1/generations/$stage_generation/modules/result_truth.jq") ;;
    *) generation_members_ok=false ;;
  esac
done < "$generation_files"
if [ "$generation_members_ok" = true ] &&
   [ "$(grep -Fxc "$stage_module_path" "$generation_files")" -eq 1 ]; then
  guard_pass
else
  guard_fail "private generation member allowlist"
fi

stage_activation_state_ok() {
  local root_program="$1"
  local wrapper="$2"
  local root_exists=false
  local wrapper_exists=false
  { [ -e "$root_program" ] || [ -L "$root_program" ]; } && root_exists=true
  { [ -e "$wrapper" ] || [ -L "$wrapper" ]; } && wrapper_exists=true
  if [ "$root_exists" = false ] && [ "$wrapper_exists" = false ]; then
    return 0
  fi
  [ "$root_exists" = true ] && [ "$wrapper_exists" = true ] &&
    [ -f "$root_program" ] && [ ! -L "$root_program" ] &&
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && [ -x "$wrapper" ] &&
    [ "$(grep -Ec "^PORTABLE_CORE_GENERATION='g-[0-9a-f]{64}'$" "$wrapper")" -eq 1 ] &&
    [ "$(grep -Fxc "PORTABLE_CORE_GENERATION='$stage_generation'" "$wrapper")" -eq 1 ]
}

if stage_activation_state_ok \
   "$stage_root/core/v1/generations/$stage_generation/contracts.jq" \
   "$stage_root/scripts/core-contract.sh"; then
  guard_pass
else
  guard_fail "generation activation state"
fi

if [ -z "$(find "$stage_root/core/v1/generations/$stage_generation" \
     "$stage_fixture" "$stage_ledger" -type l -print -quit)" ]; then
  guard_pass
else
  guard_fail "portable-core symlink guard"
fi

if [ -x "$stage_root/scripts/test/portable-core-stage-request.test.sh" ] &&
   grep -Fq "find \"\$root/scripts/test\" -maxdepth 1 -type f -name '*.test.sh'" \
     "$stage_root/scripts/test/run-all.sh"; then
  guard_pass
else
  guard_fail "CI test discovery"
fi

regular_files_ok=true
while IFS= read -r required_path; do
  [ -f "$stage_root/$required_path" ] &&
    [ ! -L "$stage_root/$required_path" ] || regular_files_ok=false
done <<< "$required_paths"
if [ "$regular_files_ok" = true ]; then
  guard_pass
else
  guard_fail "new file regularity"
fi

stage_expected_rules="$stage_tmp/expected-rules"
printf '%s\n' \
  portable-core-stage-request.absent-target-bootstrap \
  portable-core-stage-request.absent-target-bootstrap-producer-only \
  portable-core-stage-request.binding-selection \
  portable-core-stage-request.capability-role-closure \
  portable-core-stage-request.delivered-scope-input-closure \
  portable-core-stage-request.document-routing \
  portable-core-stage-request.environment-shape \
  portable-core-stage-request.expected-execution-projection \
  portable-core-stage-request.fixed-imports \
  portable-core-stage-request.gate-decision-set \
  portable-core-stage-request.instruction-input-distinct \
  portable-core-stage-request.instruction-shape \
  portable-core-stage-request.named-input-set \
  portable-core-stage-request.operation-permissions \
  portable-core-stage-request.operation-shape \
  portable-core-stage-request.prior-evidence-set \
  portable-core-stage-request.producer-arguments \
  portable-core-stage-request.request-git-ref-repository-closure \
  portable-core-stage-request.requested-at \
  portable-core-stage-request.requested-by \
  portable-core-stage-request.required-evidence \
  portable-core-stage-request.resolved-context-shape \
  portable-core-stage-request.resolved-profile-ref \
  portable-core-stage-request.restore-manifest \
  portable-core-stage-request.reviewer-arguments \
  portable-core-stage-request.reviewer-change-base-equality \
  portable-core-stage-request.reviewer-change-head-equality \
  portable-core-stage-request.risk-claim \
  portable-core-stage-request.selected-binding-closure \
  portable-core-stage-request.selection-context-relation \
  portable-core-stage-request.stage-request-body \
  portable-core-stage-request.stage-request-self \
  portable-core-stage-request.target-selector-shape \
  portable-core-stage-request.verifier-arguments \
  portable-core-stage-request.verifier-candidate-tree \
  portable-core-stage-request.verifier-evidence-allowlist > "$stage_expected_rules"

LC_ALL=C sort -u "$stage_expected_rules" > "$stage_tmp/expected-rules.sorted"
LC_ALL=C sort -u "$stage_seen_rules" > "$stage_tmp/seen-rules.sorted"
if ! cmp -s "$stage_tmp/expected-rules.sorted" "$stage_tmp/seen-rules.sorted"; then
  fail_case "owned rule inventory"
fi

tail -n +2 "$stage_ledger" | cut -f5 | LC_ALL=C sort -u > \
  "$stage_tmp/expected-tests"
LC_ALL=C sort -u "$stage_seen_tests" > "$stage_tmp/seen-tests.sorted"
if ! cmp -s "$stage_tmp/expected-tests" "$stage_tmp/seen-tests.sorted"; then
  fail_case "ledger stable test inventory"
fi

stage_review_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="review" && ($5 in seen) {n++}
  END {print n+0}
' "$stage_tmp/seen-tests.sorted" "$stage_ledger")"
stage_legacy_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="legacy" && ($5 in seen) {n++}
  END {print n+0}
' "$stage_tmp/seen-tests.sorted" "$stage_ledger")"
if [ "$stage_review_accounted" -ne 6 ] ||
   [ "$stage_legacy_accounted" -ne 22 ]; then
  fail_case "ledger executed mapping"
fi

stage_owned_total="$(wc -l < "$stage_tmp/expected-rules.sorted" | tr -d ' ')"
if [ "$stage_owned_total" -ne \
     "$("${stage_jq_command[@]}" -r '.owned_rules' <<< "$stage_metadata")" ] ||
   [ "$stage_direct_total" -ne \
     "$("${stage_jq_command[@]}" -r '.direct_cases' <<< "$stage_metadata")" ] ||
   [ "$stage_cell_total" -ne \
     "$("${stage_jq_command[@]}" -r '.command_to_rule_cells' <<< "$stage_metadata")" ] ||
   [ "$stage_forced_total" -ne \
     "$("${stage_jq_command[@]}" -r '.forced_routes' <<< "$stage_metadata")" ] ||
   [ "$stage_layer_total" -ne \
     "$("${stage_jq_command[@]}" -r '.error_layer_cases' <<< "$stage_metadata")" ] ||
   [ "$stage_guard_total" -ne \
     "$("${stage_jq_command[@]}" -r '.guard_cases' <<< "$stage_metadata")" ]; then
  fail_case "fixed proof denominators"
fi

stage_owned_passed="$stage_owned_total"
if [ "$stage_failures" -ne 0 ]; then
  stage_owned_passed=0
fi

printf 'owned rules: %s/%s\n' "$stage_owned_passed" "$stage_owned_total"
printf 'direct cases: %s/%s\n' "$stage_direct_passed" "$stage_direct_total"
printf 'command-to-rule cells: %s/%s\n' "$stage_cell_passed" "$stage_cell_total"
printf 'forced routes: %s/%s\n' "$stage_forced_passed" "$stage_forced_total"
printf 'error-layer cases: %s/%s\n' "$stage_layer_passed" "$stage_layer_total"
printf 'activation/restore/dependency cases: %s/%s\n' "$stage_guard_passed" "$stage_guard_total"
printf 'review findings accounted for: %s/%s\n' "$stage_review_accounted" "$stage_review_total"
printf 'legacy assertions accounted for: %s/%s\n' "$stage_legacy_accounted" "$stage_legacy_total"
printf 'failures: %s\n' "$stage_failures"

[ "$stage_failures" -eq 0 ]
