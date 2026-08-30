#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

facts_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
facts_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
facts_schema_oid="fd3924d414a7d620c2bf5de919a45c2599d572ec"
facts_ingress_oid="e882b38b0106aac9142c667771f02e3107f8c52f"
facts_profile_oid="48fd185eee7751eedf0ce381b77621e4d7cd1611"
facts_stage_oid="76c5d54437813a76502b46dc05215fb5b2c3f5bb"
facts_registry_oid="5e113105777694a280166e71d31efd19752e9562"
facts_generation_root="core/v1/generations/$facts_generation"
facts_module_path="$facts_generation_root/modules/result_facts.jq"
facts_module_dir="$facts_root/$facts_generation_root/modules"
facts_fixture_dir="$facts_root/scripts/test"
facts_fixture="$facts_fixture_dir/portable-core-result-facts-fixtures.jq"
facts_ledger="$facts_fixture_dir/portable-core-result-facts-ledger.tsv"
facts_manifest="$facts_root/ci/required-files.txt"
facts_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-facts.XXXXXX")"
facts_download=""

cleanup() {
  if [ -n "$facts_download" ] && [ -f "$facts_download" ]; then
    rm -f -- "$facts_download"
  fi
  rm -rf -- "$facts_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

facts_platform="$(uname -s):$(uname -m)"
case "$facts_platform" in
  Linux:x86_64)
    facts_asset="jq-linux64"
    facts_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    facts_asset="jq-osx-amd64"
    facts_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $facts_platform" >&2
    exit 1
    ;;
esac

facts_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$facts_cache"
facts_jq="$facts_cache/$facts_asset"
if [ ! -f "$facts_jq" ] ||
   [ "$(sha256_path "$facts_jq")" != "$facts_asset_sha256" ]; then
  facts_download="$(mktemp "$facts_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$facts_asset" \
    -o "$facts_download"
  if [ "$(sha256_path "$facts_download")" != "$facts_asset_sha256" ]; then
    echo "FAIL: jq 1.6 release asset digest mismatch" >&2
    exit 1
  fi
  chmod 0555 "$facts_download"
  mv "$facts_download" "$facts_jq"
  facts_download=""
fi

facts_jq_command=("$facts_jq")
if [ "$facts_platform" = "Darwin:arm64" ]; then
  facts_jq_command=(/usr/bin/arch -x86_64 "$facts_jq")
fi

if [ "$(sha256_path "$facts_jq")" != "$facts_asset_sha256" ] ||
   [ "$("${facts_jq_command[@]}" --version)" != "jq-1.6" ]; then
  echo "FAIL: pinned jq 1.6 identity check failed" >&2
  exit 1
fi

fixture_value() {
  local expression="$1"
  "${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
    "import \"portable-core-result-facts-fixtures\" as fixture; $expression"
}

facts_metadata="$(fixture_value 'fixture::metadata')"

roles=(producer publisher reviewer verifier)
manifest_files=()
manifest_shas=()
for index in 0 1 2 3; do
  manifest_file="$facts_tmp/manifest-${roles[$index]}.json"
  "${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
    "import \"portable-core-profile-graph-fixtures\" as fixture;
     fixture::manifest_docs[$index]" > "$manifest_file"
  manifest_files+=("$manifest_file")
  manifest_shas+=("$(sha256_path "$manifest_file")")
done

manifest_sha_map="$("${facts_jq_command[@]}" -n \
  --arg producer "${manifest_shas[0]}" \
  --arg publisher "${manifest_shas[1]}" \
  --arg reviewer "${manifest_shas[2]}" \
  --arg verifier "${manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"

profile_file="$facts_tmp/profile.json"
"${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::profile_doc($manifest_shas)' > "$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$facts_tmp/resolved.json"
"${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
  --slurpfile profile "$profile_file" \
  --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > \
  "$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

for role in producer reviewer verifier; do
  request_file="$facts_tmp/request-$role.json"
  "${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
    --arg role "$role" --arg resolved_sha "$resolved_sha" \
    'import "portable-core-stage-request-fixtures" as fixture;
     fixture::request_doc($role;$resolved_sha)' > "$request_file"
  request_sha="$(sha256_path "$request_file")"
  "${facts_jq_command[@]}" -L "$facts_fixture_dir" -S -c -n \
    --slurpfile request "$request_file" --slurpfile resolved "$resolved_file" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    'import "portable-core-result-facts-fixtures" as fixture;
     fixture::result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)' > \
    "$facts_tmp/result-$role.json"
done

facts_failures=0
facts_direct_total=0
facts_direct_passed=0
facts_cell_total=0
facts_cell_passed=0
facts_forced_total=0
facts_forced_passed=0
facts_guard_total=0
facts_guard_passed=0
facts_seen_rules="$facts_tmp/seen-rules"
facts_seen_tests="$facts_tmp/seen-tests"
: > "$facts_seen_rules"
: > "$facts_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  facts_failures=$((facts_failures + 1))
}

mark_rule() { printf '%s\n' "$1" >> "$facts_seen_rules"; }
mark_test() { printf '%s\n' "$1" >> "$facts_seen_tests"; }

expect_expression() {
  local case_id="$1"
  local expected="$2"
  local role="$3"
  local expression="$4"
  local actual
  facts_direct_total=$((facts_direct_total + 1))
  if ! actual="$("${facts_jq_command[@]}" -r -L "$facts_module_dir" -n \
      --slurpfile request "$facts_tmp/request-$role.json" \
      --slurpfile resolved "$resolved_file" \
      --slurpfile result "$facts_tmp/result-$role.json" \
      'import "schema" as schema;
       import "result_facts" as result_facts;
       $request[0] as $request_doc |
       $resolved[0] as $resolved_doc |
       $result[0] as $result_doc |
       ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    facts_direct_passed=$((facts_direct_passed + 1))
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

expect_true() { expect_expression "$1" true "$2" "$3"; }
expect_false() { expect_expression "$1" false "$2" "$3"; }

mapped_true() {
  mark_test "$1"
  expect_true "$2" "$3" "$4"
}

mapped_false() {
  mark_test "$1"
  expect_false "$2" "$3" "$4"
}

expect_true producer-result-facts-shape producer \
  '$result_doc.body | result_facts::stage_result_facts_shape_ok'
expect_true verifier-result-facts-shape verifier \
  '$result_doc.body | result_facts::stage_result_facts_shape_ok'
expect_true execution-optional producer \
  '$result_doc.body | del(.execution) | result_facts::stage_result_facts_shape_ok'
expect_false execution-must-be-object producer \
  '$result_doc.body | .execution=[] | result_facts::stage_result_facts_shape_ok'
mark_rule portable-core-result-facts.result-execution-optional

mapped_true portable-core-result-facts.test.legacy-175-actual-binding-shape \
  actual-binding-valid producer \
  '$result_doc.body.execution.actual_binding | result_facts::actual_binding_shape_ok'
expect_false actual-binding-missing-package producer \
  '$result_doc.body.execution.actual_binding | del(.package_ref) |
   result_facts::actual_binding_shape_ok'
expect_false actual-binding-extra-field producer \
  '$result_doc.body.execution.actual_binding + {grant:true} |
   result_facts::actual_binding_shape_ok'
expect_false actual-binding-bad-implementation producer \
  '$result_doc.body.execution.actual_binding |
   .adapter_implementation.id="bad/id" |
   result_facts::actual_binding_shape_ok'
expect_false actual-binding-bad-config-wrapper producer \
  '$result_doc.body.execution.actual_binding | .config_ref={} |
   result_facts::actual_binding_shape_ok'
expect_false actual-binding-bad-authority producer \
  '$result_doc.body.execution.actual_binding | .authority_ref.purpose="grant" |
   result_facts::actual_binding_shape_ok'
mark_rule portable-core-result-facts.actual-binding-shape

expect_false performer-bad-implementation producer \
  '$result_doc | .body.execution.performer.implementation_id="bad/id" |
   .body.execution | result_facts::execution_shape_ok'
expect_false performer-missing-boundary producer \
  '$result_doc | del(.body.execution.performer.execution_boundary_id) |
   .body.execution | result_facts::execution_shape_ok'
mark_rule portable-core-result-facts.performer-shape

expect_false environment-bad-digest producer \
  '$result_doc | .body.execution.environment.fingerprint_sha256="bad" |
   .body.execution | result_facts::execution_shape_ok'
expect_false environment-extra-field producer \
  '$result_doc | .body.execution.environment.host="ambient" |
   .body.execution | result_facts::execution_shape_ok'
mark_rule portable-core-result-facts.environment-shape

expect_true registered-capability producer \
  '$result_doc.body.execution.used_capability |
   result_facts::observed_capability_shape_ok'
expect_true unclassified-capability-shape producer \
  '{kind:"unclassified",id:"capability.observed"} |
   result_facts::observed_capability_shape_ok'
expect_false registered-unknown-capability producer \
  '{kind:"registered",id:"capability.observed"} |
   result_facts::observed_capability_shape_ok'
expect_false unclassified-registered-capability producer \
  '{kind:"unclassified",id:"core.harness.produce.v1"} |
   result_facts::observed_capability_shape_ok'
expect_false capability-unknown-kind producer \
  '{kind:"ambient",id:"capability.observed"} |
   result_facts::observed_capability_shape_ok'
mark_rule portable-core-result-facts.observed-capability-shape

expect_true fact-recorded producer \
  '$result_doc.body.execution.metadata.provider |
   result_facts::fact_shape_ok(schema::id_ok)'
expect_true fact-computed producer \
  '$result_doc.body.execution.metadata.provider | .state="computed" |
   result_facts::fact_shape_ok(schema::id_ok)'
expect_true fact-unavailable producer \
  '{state:"unavailable",reason_id:"fact.missing"} |
   result_facts::fact_shape_ok(schema::id_ok)'
expect_true fact-not-applicable producer \
  '{state:"not-applicable"} | result_facts::fact_shape_ok(schema::id_ok)'
expect_false fact-recorded-missing-source producer \
  '$result_doc.body.execution.metadata.provider | del(.source_ref) |
   result_facts::fact_shape_ok(schema::id_ok)'
expect_false fact-unavailable-extra producer \
  '{state:"unavailable",reason_id:"fact.missing",value:"x"} |
   result_facts::fact_shape_ok(schema::id_ok)'
expect_false fact-unknown-state producer \
  '{state:"assumed"} | result_facts::fact_shape_ok(schema::id_ok)'
expect_false fact-scalar producer \
  '0 | result_facts::fact_shape_ok(schema::id_ok)'
expect_false fact-array producer \
  '[] | result_facts::fact_shape_ok(schema::id_ok)'
expect_false factual-state-scalar producer \
  '0 | result_facts::factual_or_unavailable'
expect_false metadata-scalar-fact producer \
  '$result_doc.body.execution.metadata | .provider=0 |
   result_facts::execution_metadata_shape_ok'
mark_rule portable-core-result-facts.fact-state-shape

expect_true deterministic-metadata-valid verifier \
  '$result_doc.body.execution.metadata |
   result_facts::execution_metadata_shape_ok'
expect_false deterministic-provider-recorded verifier \
  '$result_doc.body.execution.metadata |
   .provider={state:"recorded",value:"provider",source_ref:{content_id:"fact",media_type:"application/json",sha256:("a"*64)}} |
   result_facts::execution_metadata_shape_ok'
expect_false deterministic-tools-not-applicable verifier \
  '$result_doc.body.execution.metadata | .tools={state:"not-applicable"} |
   result_facts::execution_metadata_shape_ok'
mark_rule portable-core-result-facts.deterministic-metadata-state

expect_true model-metadata-valid producer \
  '$result_doc.body.execution.metadata |
   result_facts::execution_metadata_shape_ok'
expect_false model-provider-not-applicable producer \
  '$result_doc.body.execution.metadata | .provider={state:"not-applicable"} |
   result_facts::execution_metadata_shape_ok'
expect_true model-prompt-unavailable producer \
  '$result_doc.body.execution.metadata |
   .prompt={state:"unavailable",reason_id:"prompt.missing"} |
   result_facts::execution_metadata_shape_ok'
expect_true model-snapshot-unavailable producer \
  '$result_doc.body.execution.metadata |
   .snapshot={state:"unavailable",reason_id:"snapshot.missing"} |
   result_facts::execution_metadata_shape_ok'
mark_rule portable-core-result-facts.model-metadata-state

expect_false skills-unsorted producer \
  '$result_doc.body.execution.metadata |
   .skills.value=[.skills.value[0],(.skills.value[0] | .location.value="a.md")] |
   result_facts::execution_metadata_shape_ok'
expect_false skills-over-bound producer \
  '$result_doc.body.execution.metadata |
   .skills.value=([range(0;33)] | map(. as $n | $result_doc.body.execution.actual_binding.package_ref | .location={kind:"path",value:("skill-"+($n|tostring))})) |
   result_facts::execution_metadata_shape_ok'
mark_rule portable-core-result-facts.skills-fact-bound

expect_false tools-duplicate producer \
  '$result_doc.body.execution.metadata |
   .tools.value += [.tools.value[0]] |
   result_facts::execution_metadata_shape_ok'
expect_false tools-over-bound producer \
  '$result_doc.body.execution.metadata |
   .tools.value=([range(0;33)] | map(. as $n | $result_doc.body.execution.metadata.tools.value[0] | .tool_id=("tool."+($n|tostring)))) |
   result_facts::execution_metadata_shape_ok'
mark_rule portable-core-result-facts.tools-fact-bound

mapped_true portable-core-result-facts.test.legacy-177-execution-shape \
  execution-valid producer \
  '$result_doc.body.execution | result_facts::execution_shape_ok'
expect_false execution-extra-field producer \
  '$result_doc.body.execution + {command:"run"} |
   result_facts::execution_shape_ok'
mark_rule portable-core-result-facts.execution-shape

mapped_false portable-core-result-facts.test.legacy-181-metadata-kind-binding \
  metadata-kind-mismatch producer \
  '$result_doc.body.execution | .metadata.kind="deterministic" |
   result_facts::execution_shape_ok'
mark_rule portable-core-result-facts.metadata-kind-binding

mapped_false portable-core-result-facts.test.legacy-211-performer-role-binding \
  performer-role-mismatch producer \
  '$result_doc.body.execution | .performer.role="reviewer" |
   result_facts::execution_shape_ok'
mark_rule portable-core-result-facts.performer-role-binding

expect_true producer-conclusive-match producer \
  'result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;$result_doc.body)'
expect_true reviewer-conclusive-match reviewer \
  'result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;$result_doc.body)'
expect_true verifier-conclusive-match verifier \
  'result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;$result_doc.body)'
mapped_false portable-core-result-facts.test.conclusive-full-projection \
  conclusive-adapter-mismatch producer \
  '$result_doc | .body.execution.actual_binding.adapter_implementation.version="v2" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-manifest-mismatch producer \
  '$result_doc | .body.execution.actual_binding.manifest_ref.sha256=("0"*64) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-package-mismatch producer \
  '$result_doc | .body.execution.actual_binding.package_ref.object_id=("0"*40) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-config-mismatch producer \
  '$result_doc | .body.execution.actual_binding.config_ref.value.object_id=("0"*40) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-principal-mismatch producer \
  '$result_doc | .body.execution.actual_binding.principal_id="principal.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-authority-mismatch producer \
  '$result_doc | .body.execution.actual_binding.authority_ref.scope_sha256=("0"*64) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-performer-mismatch producer \
  '$result_doc | .body.execution.performer.principal_id="principal.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-environment-mismatch producer \
  '$result_doc | .body.execution.environment.fingerprint_sha256=("0"*64) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-capability-mismatch producer \
  '$result_doc | .body.execution.used_capability.id="core.review.change.v1" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.conclusive-projection

mapped_false portable-core-result-facts.test.legacy-243-model-fact-mismatch \
  conclusive-provider-mismatch producer \
  '$result_doc | .body.execution.metadata.provider.value="provider.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-model-mismatch producer \
  '$result_doc | .body.execution.metadata.model.value="model.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-effort-mismatch producer \
  '$result_doc | .body.execution.metadata.effort.value="low" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-prompt-mismatch producer \
  '$result_doc | .body.execution.metadata.prompt.value.object_id=("0"*40) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-skills-mismatch producer \
  '$result_doc | .body.execution.metadata.skills.value=[] |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true conclusive-prompt-unavailable producer \
  '$result_doc | .body.execution.metadata.prompt={state:"unavailable",reason_id:"prompt.missing"} |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.model-fact-values

mapped_false portable-core-result-facts.test.legacy-245-tool-fact-mismatch \
  conclusive-unrequested-tool producer \
  '$result_doc | .body.execution.metadata.tools.value[0].tool_id="tool.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true conclusive-tool-subset producer \
  '$result_doc | .body.execution.metadata.tools.value=[] |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true conclusive-tools-unavailable producer \
  '$result_doc | .body.execution.metadata.tools={state:"unavailable",reason_id:"tools.missing"} |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.tool-fact-values

mapped_true portable-core-result-facts.test.completed-inconclusive-mismatch \
  completed-inconclusive-mismatch producer \
  '$result_doc | .body.status="completed" |
   .body.outcome={family:"change",value:"inconclusive"} |
   .body.execution.environment.fingerprint_sha256=("0"*64) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true failed-mismatch producer \
  '$result_doc | .body.status="failed" |
   .body.execution.actual_binding.principal_id="principal.other" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true cancelled-mismatch producer \
  '$result_doc | .body.status="cancelled" |
   .body.execution.used_capability.id="core.review.change.v1" |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.incident-mismatch

mapped_true portable-core-result-facts.test.legacy-247-incident-unclassified-capability \
  incident-unclassified producer \
  '$result_doc | .body.status="completed" |
   .body.outcome={family:"change",value:"inconclusive"} |
   .body.execution.used_capability={kind:"unclassified",id:"capability.observed"} |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_true failed-unclassified producer \
  '$result_doc | .body.status="failed" |
   .body.execution.used_capability={kind:"unclassified",id:"capability.observed"} |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
expect_false conclusive-unclassified producer \
  '$result_doc | .body.execution.used_capability={kind:"unclassified",id:"capability.observed"} |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.unclassified-incident-only

expect_false missing-selected-binding producer \
  '$request_doc | .body.operation.binding_id="binding.missing" |
   result_facts::stage_result_execution_relation_ok(.body;$resolved_doc.body;$result_doc.body)'
mark_rule portable-core-result-facts.projection-required

run_counted() {
  local counter="$1"
  local case_id="$2"
  local expected="$3"
  local expression="$4"
  local actual
  case "$counter" in
    cell) facts_cell_total=$((facts_cell_total + 1)) ;;
    forced) facts_forced_total=$((facts_forced_total + 1)) ;;
  esac
  if ! actual="$("${facts_jq_command[@]}" -r -L "$facts_module_dir" -n \
      --slurpfile request "$facts_tmp/request-producer.json" \
      --slurpfile resolved "$resolved_file" \
      --slurpfile result "$facts_tmp/result-producer.json" \
      'import "result_facts" as result_facts;
       $request[0] as $request_doc | $resolved[0] as $resolved_doc |
       $result[0] as $result_doc | ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    case "$counter" in
      cell) facts_cell_passed=$((facts_cell_passed + 1)) ;;
      forced) facts_forced_passed=$((facts_forced_passed + 1)) ;;
    esac
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

run_counted cell document-result-facts true \
  '$result_doc | result_facts::document_shape_ok'
run_counted cell stage-run-facts true \
  'result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;$result_doc.body)'
run_counted forced document-result-facts-reject false \
  '$result_doc | .body.execution.metadata.tools={state:"not-applicable"} |
   result_facts::document_shape_ok'
run_counted forced stage-run-facts-reject false \
  '$result_doc | .body.execution.environment.fingerprint_sha256=("0"*64) |
   result_facts::stage_result_execution_relation_ok($request_doc.body;$resolved_doc.body;.body)'
mark_rule portable-core-result-facts.document-routing

guard_pass() {
  facts_guard_total=$((facts_guard_total + 1))
  facts_guard_passed=$((facts_guard_passed + 1))
}

guard_fail() {
  facts_guard_total=$((facts_guard_total + 1))
  fail_case "$1"
}

current_blob_ok() {
  local path="$1"
  local expected="$2"
  local mode type oid actual_path
  IFS=$' \t' read -r mode type oid actual_path < <(
    git -C "$facts_root" ls-tree HEAD -- "$path"
  ) || return 1
  [ "$mode" = 100644 ] && [ "$type" = blob ] &&
    [ "$oid" = "$expected" ] && [ "$actual_path" = "$path" ]
}

if current_blob_ok "$facts_generation_root/modules/schema.jq" "$facts_schema_oid"; then
  guard_pass
else guard_fail "schema export pin"
fi
if current_blob_ok "$facts_generation_root/core-ingress.sh" "$facts_ingress_oid"; then
  guard_pass
else guard_fail "ingress serial dependency pin"
fi
if current_blob_ok "$facts_generation_root/modules/profile_graph.jq" "$facts_profile_oid"; then
  guard_pass
else guard_fail "profile-graph export pin"
fi
if current_blob_ok "$facts_generation_root/modules/stage_request.jq" "$facts_stage_oid"; then
  guard_pass
else guard_fail "stage-request serial dependency pin"
fi
if current_blob_ok "core/v1/generation-registry.json" "$facts_registry_oid"; then
  guard_pass
else guard_fail "generation registry pin"
fi

if [ "$("${facts_jq_command[@]}" -r '.construction_base' <<< "$facts_metadata")" = \
     "4ea04ee0ffb800668871b3b482557dd5a9041801" ] &&
   [ "$("${facts_jq_command[@]}" -r '.stage_request_g3_comment' <<< "$facts_metadata")" -eq 5469016860 ] &&
   [ "$("${facts_jq_command[@]}" -r '.stage_request_merge_commit' <<< "$facts_metadata")" = \
     "4ea04ee0ffb800668871b3b482557dd5a9041801" ] &&
   [ "$("${facts_jq_command[@]}" -r '.stage_request_export_oid' <<< "$facts_metadata")" = "$facts_stage_oid" ] &&
   [ "$("${facts_jq_command[@]}" -r '.frozen_source_head' <<< "$facts_metadata")" = \
     "ab4a7082f02e67b5748c5c54b9214f37d222f53f" ] &&
   [ "$("${facts_jq_command[@]}" -r '.frozen_test_blob' <<< "$facts_metadata")" = \
     "8a9921d3763e3fcfa103037b021dd6c95bdcad61" ]; then
  guard_pass
else guard_fail "fixture dependency metadata"
fi

if [ "$(git -C "$facts_root" hash-object config/construction-mode.json)" = \
     "4f35b0ec232e584973071a8d2e90ee5971af6e79" ] &&
   [ "$(git -C "$facts_root" hash-object ROADMAP.md)" = \
     "4bb0fff1ee11c20441cc16182337f762300ac0f2" ] &&
   [ "$(git -C "$facts_root" hash-object NORTH_STAR.md)" = \
     "d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013" ]; then
  guard_pass
else guard_fail "construction identity"
fi

expected_imports='import "schema" as schema;
import "profile_graph" as profile_graph;
import "stage_request" as stage_request;'
if [ "$(sed -n '1,3p' "$facts_root/$facts_module_path")" = "$expected_imports" ] &&
   [ "$(grep -Ec '^import ' "$facts_root/$facts_module_path")" -eq 3 ]; then
  guard_pass
else guard_fail "fixed module imports"
fi
mark_rule portable-core-result-facts.fixed-imports

if [ "$(awk 'END {print NR-1}' "$facts_ledger")" -eq 16 ] &&
   [ "$(awk -F '\t' 'NR>1 && $1=="review" {n++} END {print n+0}' "$facts_ledger")" -eq 2 ] &&
   [ "$(awk -F '\t' 'NR>1 && $1=="legacy" {n++} END {print n+0}' "$facts_ledger")" -eq 14 ] &&
   [ "$(sha256_path "$facts_ledger")" = \
     "$("${facts_jq_command[@]}" -r '.mapping_sha256' <<< "$facts_metadata")" ]; then
  guard_pass
else guard_fail "frozen migration ledger"
fi

required_paths="$facts_module_path
scripts/test/portable-core-result-facts-fixtures.jq
scripts/test/portable-core-result-facts-ledger.tsv
scripts/test/portable-core-result-facts.test.sh"
manifest_ok=true
while IFS= read -r required_path; do
  [ "$(grep -Fxc "$required_path" "$facts_manifest" || true)" -eq 1 ] &&
    [ -f "$facts_root/$required_path" ] || manifest_ok=false
done <<< "$required_paths"
if [ "$manifest_ok" = true ]; then guard_pass
else guard_fail "restore manifest coverage"
fi
mark_rule portable-core-result-facts.restore-manifest

manifest_block_ok() {
  local manifest="$1"
  local prefix="$facts_tmp/required-files-prefix"
  head -n 112 "$manifest" > "$prefix"
  [ "$(sha256_path "$prefix")" = \
    "9f452902a785f3e7bb932cfeb36c453a4f72786a18447e6e7ebc6b67da85cd59" ] &&
    [ "$(sed -n '113,116p' "$manifest")" = "$required_paths" ]
}

if manifest_block_ok "$facts_manifest"; then
  guard_pass
else guard_fail "restore manifest exact append"
fi

future_manifest="$facts_tmp/future-required-files.txt"
cp "$facts_manifest" "$future_manifest"
printf '%s\n' "$facts_generation_root/modules/result_truth.jq" >> "$future_manifest"
if manifest_block_ok "$future_manifest"; then
  guard_pass
else guard_fail "restore manifest permits downstream append"
fi

generation_members_ok=true
while IFS= read -r generation_file; do
  case "$generation_file" in
    "$facts_generation_root/core-ingress.sh"|\
    "$facts_generation_root/modules/schema.jq"|\
    "$facts_generation_root/modules/profile_graph.jq"|\
    "$facts_generation_root/modules/stage_request.jq"|\
    "$facts_generation_root/modules/result_facts.jq"|\
    "$facts_generation_root/modules/result_truth.jq") ;;
    *) generation_members_ok=false ;;
  esac
done < <(find "$facts_root/$facts_generation_root" -type f -print |
  sed "s#^$facts_root/##" | LC_ALL=C sort)
if [ "$generation_members_ok" = true ] &&
   [ ! -e "$facts_root/$facts_generation_root/contracts.jq" ]; then
  guard_pass
else guard_fail "private generation member allowlist"
fi

if [ ! -e "$facts_root/scripts/core-contract.sh" ] &&
   [ -z "$(find "$facts_root/$facts_generation_root" "$facts_fixture" "$facts_ledger" \
     -type l -print -quit)" ]; then
  guard_pass
else guard_fail "private inactive regular files"
fi

if [ -x "$facts_root/scripts/test/portable-core-result-facts.test.sh" ] &&
   grep -Fq "find \"\$root/scripts/test\" -maxdepth 1 -type f -name '*.test.sh'" \
     "$facts_root/scripts/test/run-all.sh"; then
  guard_pass
else guard_fail "CI test discovery"
fi
mark_rule portable-core-result-facts.dependency-pins

facts_expected_rules="$facts_tmp/expected-rules"
printf '%s\n' \
  portable-core-result-facts.actual-binding-shape \
  portable-core-result-facts.conclusive-projection \
  portable-core-result-facts.dependency-pins \
  portable-core-result-facts.deterministic-metadata-state \
  portable-core-result-facts.document-routing \
  portable-core-result-facts.environment-shape \
  portable-core-result-facts.execution-shape \
  portable-core-result-facts.fact-state-shape \
  portable-core-result-facts.fixed-imports \
  portable-core-result-facts.incident-mismatch \
  portable-core-result-facts.metadata-kind-binding \
  portable-core-result-facts.model-fact-values \
  portable-core-result-facts.model-metadata-state \
  portable-core-result-facts.observed-capability-shape \
  portable-core-result-facts.performer-role-binding \
  portable-core-result-facts.performer-shape \
  portable-core-result-facts.projection-required \
  portable-core-result-facts.restore-manifest \
  portable-core-result-facts.result-execution-optional \
  portable-core-result-facts.skills-fact-bound \
  portable-core-result-facts.tool-fact-values \
  portable-core-result-facts.tools-fact-bound \
  portable-core-result-facts.unclassified-incident-only > "$facts_expected_rules"

LC_ALL=C sort -u "$facts_expected_rules" > "$facts_tmp/expected-rules.sorted"
LC_ALL=C sort -u "$facts_seen_rules" > "$facts_tmp/seen-rules.sorted"
if ! cmp -s "$facts_tmp/expected-rules.sorted" "$facts_tmp/seen-rules.sorted"; then
  fail_case "owned rule inventory"
fi

tail -n +2 "$facts_ledger" | cut -f5 | LC_ALL=C sort -u > \
  "$facts_tmp/expected-tests"
LC_ALL=C sort -u "$facts_seen_tests" > "$facts_tmp/seen-tests.sorted"
if ! cmp -s "$facts_tmp/expected-tests" "$facts_tmp/seen-tests.sorted"; then
  fail_case "ledger stable test inventory"
fi

facts_review_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="review" && ($5 in seen) {n++}
  END {print n+0}
' "$facts_tmp/seen-tests.sorted" "$facts_ledger")"
facts_legacy_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="legacy" && ($5 in seen) {n++}
  END {print n+0}
' "$facts_tmp/seen-tests.sorted" "$facts_ledger")"
if [ "$facts_review_accounted" -ne 2 ] ||
   [ "$facts_legacy_accounted" -ne 14 ]; then
  fail_case "ledger executed mapping"
fi

facts_owned_total="$(wc -l < "$facts_tmp/expected-rules.sorted" | tr -d ' ')"
if [ "$facts_owned_total" -ne \
     "$("${facts_jq_command[@]}" -r '.owned_rules' <<< "$facts_metadata")" ] ||
   [ "$facts_direct_total" -ne \
     "$("${facts_jq_command[@]}" -r '.direct_cases' <<< "$facts_metadata")" ] ||
   [ "$facts_cell_total" -ne \
     "$("${facts_jq_command[@]}" -r '.command_to_rule_cells' <<< "$facts_metadata")" ] ||
   [ "$facts_forced_total" -ne \
     "$("${facts_jq_command[@]}" -r '.forced_routes' <<< "$facts_metadata")" ] ||
   [ "$facts_guard_total" -ne \
     "$("${facts_jq_command[@]}" -r '.guard_cases' <<< "$facts_metadata")" ]; then
  fail_case "fixed proof denominators"
fi

facts_owned_passed="$facts_owned_total"
if [ "$facts_failures" -ne 0 ]; then facts_owned_passed=0; fi

printf 'portable-core-result-facts owned rules: %s/%s\n' \
  "$facts_owned_passed" "$facts_owned_total"
printf 'portable-core-result-facts direct cases: %s/%s\n' \
  "$facts_direct_passed" "$facts_direct_total"
printf 'portable-core-result-facts command-to-rule cells: %s/%s\n' \
  "$facts_cell_passed" "$facts_cell_total"
printf 'portable-core-result-facts forced routes: %s/%s\n' \
  "$facts_forced_passed" "$facts_forced_total"
printf 'portable-core-result-facts guards: %s/%s\n' \
  "$facts_guard_passed" "$facts_guard_total"
printf 'portable-core-result-facts review rows: %s/2\n' "$facts_review_accounted"
printf 'portable-core-result-facts legacy rows: %s/14\n' "$facts_legacy_accounted"
printf 'portable-core-result-facts failures: %s\n' "$facts_failures"

[ "$facts_failures" -eq 0 ]
