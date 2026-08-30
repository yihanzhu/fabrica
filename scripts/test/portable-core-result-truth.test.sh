#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

truth_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
truth_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
truth_schema_oid="fd3924d414a7d620c2bf5de919a45c2599d572ec"
truth_ingress_oid="e882b38b0106aac9142c667771f02e3107f8c52f"
truth_profile_oid="48fd185eee7751eedf0ce381b77621e4d7cd1611"
truth_stage_oid="76c5d54437813a76502b46dc05215fb5b2c3f5bb"
truth_facts_oid="cfc3ed3b1c3d714412a6dffc85accaabb98cf3df"
truth_registry_oid="5e113105777694a280166e71d31efd19752e9562"
truth_generation_root="core/v1/generations/$truth_generation"
truth_module_path="$truth_generation_root/modules/result_truth.jq"
truth_module_dir="$truth_root/$truth_generation_root/modules"
truth_fixture_dir="$truth_root/scripts/test"
truth_fixture="$truth_fixture_dir/portable-core-result-truth-fixtures.jq"
truth_ledger="$truth_fixture_dir/portable-core-result-truth-ledger.tsv"
truth_manifest="$truth_root/ci/required-files.txt"
truth_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-truth.XXXXXX")"
truth_download=""

cleanup() {
  if [ -n "$truth_download" ] && [ -f "$truth_download" ]; then
    rm -f -- "$truth_download"
  fi
  rm -rf -- "$truth_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

truth_platform="$(uname -s):$(uname -m)"
case "$truth_platform" in
  Linux:x86_64)
    truth_asset="jq-linux64"
    truth_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    truth_asset="jq-osx-amd64"
    truth_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $truth_platform" >&2
    exit 1
    ;;
esac

truth_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$truth_cache"
truth_jq="$truth_cache/$truth_asset"
if [ ! -f "$truth_jq" ] ||
   [ "$(sha256_path "$truth_jq")" != "$truth_asset_sha256" ]; then
  truth_download="$(mktemp "$truth_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$truth_asset" \
    -o "$truth_download"
  if [ "$(sha256_path "$truth_download")" != "$truth_asset_sha256" ]; then
    echo "FAIL: jq 1.6 release asset digest mismatch" >&2
    exit 1
  fi
  chmod 0555 "$truth_download"
  mv "$truth_download" "$truth_jq"
  truth_download=""
fi

truth_jq_command=("$truth_jq")
if [ "$truth_platform" = "Darwin:arm64" ]; then
  truth_jq_command=(/usr/bin/arch -x86_64 "$truth_jq")
fi

if [ "$(sha256_path "$truth_jq")" != "$truth_asset_sha256" ] ||
   [ "$("${truth_jq_command[@]}" --version)" != "jq-1.6" ]; then
  echo "FAIL: pinned jq 1.6 identity check failed" >&2
  exit 1
fi

fixture_value() {
  local expression="$1"
  "${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
    "import \"portable-core-result-truth-fixtures\" as fixture; $expression"
}

truth_metadata="$(fixture_value 'fixture::metadata')"

roles=(producer publisher reviewer verifier)
manifest_files=()
manifest_shas=()
for index in 0 1 2 3; do
  manifest_file="$truth_tmp/manifest-${roles[$index]}.json"
  "${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
    "import \"portable-core-profile-graph-fixtures\" as fixture;
     fixture::manifest_docs[$index]" > "$manifest_file"
  manifest_files+=("$manifest_file")
  manifest_shas+=("$(sha256_path "$manifest_file")")
done

manifest_sha_map="$("${truth_jq_command[@]}" -n \
  --arg producer "${manifest_shas[0]}" \
  --arg publisher "${manifest_shas[1]}" \
  --arg reviewer "${manifest_shas[2]}" \
  --arg verifier "${manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"

profile_file="$truth_tmp/profile.json"
"${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::profile_doc($manifest_shas)' > "$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$truth_tmp/resolved.json"
"${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
  --slurpfile profile "$profile_file" \
  --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > \
  "$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

for role in producer reviewer verifier; do
  request_file="$truth_tmp/request-$role.json"
  "${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
    --arg role "$role" --arg resolved_sha "$resolved_sha" \
    'import "portable-core-stage-request-fixtures" as fixture;
     fixture::request_doc($role;$resolved_sha)' > "$request_file"
  request_sha="$(sha256_path "$request_file")"
  printf '%s\n' "$request_sha" > "$truth_tmp/request-$role.sha"
  "${truth_jq_command[@]}" -L "$truth_fixture_dir" -S -c -n \
    --slurpfile request "$request_file" --slurpfile resolved "$resolved_file" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    'import "portable-core-result-truth-fixtures" as fixture;
     fixture::completed_result_doc(
       $request[0];$request_sha;$resolved[0];$resolved_sha)' > \
    "$truth_tmp/result-$role.json"
done

truth_failures=0
truth_direct_total=0
truth_direct_passed=0
truth_cell_total=0
truth_cell_passed=0
truth_forced_total=0
truth_forced_passed=0
truth_guard_total=0
truth_guard_passed=0
truth_seen_rules="$truth_tmp/seen-rules"
truth_seen_tests="$truth_tmp/seen-tests"
: > "$truth_seen_rules"
: > "$truth_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  truth_failures=$((truth_failures + 1))
}

mark_rule() { printf '%s\n' "$1" >> "$truth_seen_rules"; }
mark_test() { printf '%s\n' "$1" >> "$truth_seen_tests"; }

expect_expression() {
  local case_id="$1"
  local expected="$2"
  local role="$3"
  local expression="$4"
  local request_sha actual
  request_sha="$(cat "$truth_tmp/request-$role.sha")"
  truth_direct_total=$((truth_direct_total + 1))
  if ! actual="$("${truth_jq_command[@]}" -r -L "$truth_module_dir" \
      -L "$truth_fixture_dir" -n \
      --slurpfile request "$truth_tmp/request-$role.json" \
      --slurpfile resolved "$resolved_file" \
      --slurpfile result "$truth_tmp/result-$role.json" \
      --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
      'import "result_truth" as result_truth;
       import "portable-core-result-truth-fixtures" as fixture;
       $request[0] as $request_doc |
       $resolved[0] as $resolved_doc |
       $result[0] as $result_doc |
       {content:$request_doc,sha256:$request_sha} as $request_pair |
       {content:$resolved_doc,sha256:$resolved_sha} as $resolved_pair |
       ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    truth_direct_passed=$((truth_direct_passed + 1))
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

expect_true result-body-valid producer \
  '$result_doc.body | result_truth::stage_result_body_shape_ok'
expect_false result-body-extra producer \
  '$result_doc.body + {command:"run"} |
   result_truth::stage_result_body_shape_ok'
expect_false result-body-missing-recorded producer \
  '$result_doc.body | del(.recorded_at) |
   result_truth::stage_result_body_shape_ok'
mapped_false portable-core-result-truth.test.legacy-171-unknown-terminal-status \
  unknown-status producer \
  '$result_doc.body | .status="finished" |
   result_truth::stage_result_body_shape_ok'
mark_rule portable-core-result-truth.result-body-shape

mapped_false portable-core-result-truth.test.legacy-173-attempt-number-below-one \
  attempt-zero producer \
  '$result_doc.body | .attempt_number=0 |
   result_truth::stage_result_body_shape_ok'
mapped_false portable-core-result-truth.test.legacy-217-attempt-number-below-one-stage-run \
  attempt-zero-stage-run producer \
  '$result_doc | .body.attempt_number=0 |
   result_truth::document_self_ok'
expect_false attempt-fraction producer \
  '$result_doc.body | .attempt_number=1.5 |
   result_truth::stage_result_body_shape_ok'
mark_rule portable-core-result-truth.attempt-number

expect_true change-outcome producer \
  '{family:"change",value:"changed"} | result_truth::outcome_shape_ok'
expect_true check-outcome verifier \
  '{family:"check",value:"failed"} | result_truth::outcome_shape_ok'
expect_false outcome-cross-family producer \
  '{family:"change",value:"passed"} | result_truth::outcome_shape_ok'
expect_false outcome-extra producer \
  '{family:"check",value:"passed",score:1} |
   result_truth::outcome_shape_ok'
mark_rule portable-core-result-truth.outcome-shape

expect_true reason-valid producer \
  '{reason_id:"reason.example",summary:"short"} |
   result_truth::reason_shape_ok'
expect_false reason-empty-summary producer \
  '{reason_id:"reason.example",summary:""} |
   result_truth::reason_shape_ok'
expect_false reason-extra producer \
  '{reason_id:"reason.example",detail:"raw"} |
   result_truth::reason_shape_ok'
mark_rule portable-core-result-truth.reason-shape

expect_true output-valid producer \
  'fixture::output("one";"application/json";"1") |
   result_truth::output_shape_ok'
mapped_false portable-core-result-truth.test.legacy-179-output-missing-content-ref \
  output-missing-ref producer \
  'fixture::output("one";"application/json";"1") | del(.ref) |
   result_truth::output_shape_ok'
expect_false output-git-object producer \
  '{output_id:"one",ref:$result_doc.body.execution.actual_binding.package_ref} |
   result_truth::output_shape_ok'
mark_rule portable-core-result-truth.output-shape

expect_true evidence-valid producer \
  'fixture::evidence("one";"deterministic";"passed") |
   result_truth::evidence_shape_ok'
expect_false evidence-unknown-kind producer \
  'fixture::evidence("one";"ambient";"passed") |
   result_truth::evidence_shape_ok'
expect_false evidence-unknown-verdict producer \
  'fixture::evidence("one";"deterministic";"unknown") |
   result_truth::evidence_shape_ok'
mark_rule portable-core-result-truth.evidence-shape

mapped_false portable-core-result-truth.test.legacy-169-two-evidence-items-share-one-kind \
  evidence-kind-duplicate verifier \
  '$result_doc.body |
   .evidence=[fixture::evidence("a";"deterministic";"passed"),
              fixture::evidence("b";"deterministic";"passed")] |
   result_truth::stage_result_body_shape_ok'
expect_false evidence-id-duplicate verifier \
  '$result_doc.body |
   .evidence=[fixture::evidence("a";"architecture";"passed"),
              fixture::evidence("a";"deterministic";"passed")] |
   result_truth::stage_result_body_shape_ok'
mark_rule portable-core-result-truth.evidence-unique-kind

expect_true stale-target-selector producer \
  '{kind:"target"} | result_truth::stale_selector_shape_ok'
expect_true stale-input-selector producer \
  '{kind:"input",input_id:"input.example"} |
   result_truth::stale_selector_shape_ok'
expect_false stale-target-extra producer \
  '{kind:"target",input_id:"input.example"} |
   result_truth::stale_selector_shape_ok'
expect_false stale-gate-bad-digest producer \
  '{kind:"gate-decision",scope_sha256:"bad"} |
   result_truth::stale_selector_shape_ok'
mark_rule portable-core-result-truth.stale-selector-shape

expect_true stale-target-observed-absent producer \
  '{selector:{kind:"target"},observed:{state:"absent"}} |
   result_truth::stale_observation_shape_ok'
expect_false stale-target-observed-content producer \
  '{selector:{kind:"target"},observed:{state:"present",value:
    {type:"content",value:fixture::content("x";"application/json";"a")}}} |
   result_truth::stale_observation_shape_ok'
expect_false stale-qualification-wrong-purpose producer \
  '{selector:{kind:"qualification"},observed:{state:"present",value:
    $request_doc.body.risk.policy_ref}} |
   result_truth::stale_observation_shape_ok'
mark_rule portable-core-result-truth.stale-observed-shape

expect_false stale-selector-duplicate producer \
  '$result_doc.body |
   .stale_observations=[
     {selector:{kind:"target"},observed:{state:"absent"}},
     {selector:{kind:"target"},observed:{state:"absent"}}] |
   result_truth::stage_result_body_shape_ok'
mark_rule portable-core-result-truth.stale-selector-unique

expect_true completed-presence producer \
  '$result_doc.body | result_truth::status_presence_ok'
mapped_false portable-core-result-truth.test.legacy-223-completed-missing-finished-at \
  completed-missing-finished producer \
  '$result_doc.body | del(.finished_at) |
   result_truth::status_presence_ok'
expect_false completed-diagnostics producer \
  '$result_doc.body |
   .diagnostics=[fixture::content("diagnostic";"text/plain";"1")] |
   result_truth::status_presence_ok'
expect_false completed-reason-with-conclusive producer \
  '$result_doc.body | .reason=fixture::reason("unexpected") |
   result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-completed

mapped_true portable-core-result-truth.test.legacy-225-skipped-valid \
  skipped-valid producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::stage_result_self_ok'
mapped_false portable-core-result-truth.test.legacy-227-skipped-carries-outcome \
  skipped-outcome producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .outcome={family:"change",value:"no-change"} |
   result_truth::status_presence_ok'
expect_false skipped-diagnostic producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .diagnostics=[fixture::content("diagnostic";"text/plain";"1")] |
   result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-skipped

expect_true stale-presence producer \
  'fixture::stale_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::status_presence_ok'
expect_false stale-empty-observations producer \
  'fixture::stale_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .stale_observations=[] | result_truth::stage_result_self_ok'
expect_false stale-execution producer \
  'fixture::stale_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .execution=$result_doc.body.execution |
   result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-stale

expect_true blocked-presence producer \
  'fixture::blocked_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::stage_result_self_ok'
expect_false blocked-evidence producer \
  'fixture::blocked_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .evidence=[fixture::evidence("one";"deterministic";"failed")] |
   result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-blocked

expect_true failed-executed producer \
  'fixture::failed_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::stage_result_self_ok'
expect_true failed-unexecuted producer \
  'fixture::failed_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   del(.execution,.outcome,.started_at,.finished_at) | .evidence=[] |
   result_truth::stage_result_self_ok'
expect_false failed-no-diagnostic producer \
  'fixture::failed_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .diagnostics=[] | result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-failed

expect_true cancelled-executed producer \
  'fixture::cancelled_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::stage_result_self_ok'
expect_true cancelled-unexecuted producer \
  'fixture::cancelled_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   del(.execution,.outcome,.started_at,.finished_at) | .evidence=[] |
   result_truth::stage_result_self_ok'
expect_false cancelled-passing-evidence producer \
  'fixture::cancelled_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .evidence[0].verdict="passed" | result_truth::status_presence_ok'
mark_rule portable-core-result-truth.status-cancelled

mapped_false portable-core-result-truth.test.legacy-215-finished-precedes-started \
  finished-before-started producer \
  '$result_doc.body | .finished_at="2026-08-30T00:00:00Z" |
   result_truth::local_time_order_ok'
expect_false recorded-before-finished producer \
  '$result_doc.body | .recorded_at="2026-08-30T00:00:01Z" |
   result_truth::local_time_order_ok'
expect_true no-execution-local-time producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::local_time_order_ok'
mark_rule portable-core-result-truth.local-time-order

mapped_false portable-core-result-truth.test.legacy-219-result-request-ref-digest-mismatch \
  request-ref-digest producer \
  '$result_doc.body | .request_ref.sha256=("0"*64) |
   result_truth::refs_relation_ok($request_pair;$resolved_pair;.)'
mapped_false portable-core-result-truth.test.legacy-221-result-resolved-ref-digest-mismatch \
  resolved-ref-digest producer \
  '$result_doc.body | .resolved_profile_ref.sha256=("0"*64) |
   result_truth::refs_relation_ok($request_pair;$resolved_pair;.)'
expect_false request-resolved-ref-digest producer \
  '$request_pair | .content.body.resolved_profile_ref.sha256=("0"*64) |
   result_truth::refs_relation_ok(.;$resolved_pair;$result_doc.body)'
expect_true refs-valid producer \
  'result_truth::refs_relation_ok($request_pair;$resolved_pair;$result_doc.body)'
mark_rule portable-core-result-truth.refs

expect_true requested-floor-execution producer \
  'result_truth::requested_time_floor_ok($request_doc.body;$result_doc.body)'
expect_false requested-after-start producer \
  '$request_doc.body | .requested_at="2026-08-30T00:00:02Z" |
   result_truth::requested_time_floor_ok(.;$result_doc.body)'
expect_true requested-floor-no-execution producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body as $skipped |
   result_truth::requested_time_floor_ok($request_doc.body;$skipped)'
expect_false requested-after-recorded producer \
  'fixture::skipped_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body as $skipped |
   $request_doc.body | .requested_at="2026-08-30T00:00:04Z" |
   result_truth::requested_time_floor_ok(.;$skipped)'
mark_rule portable-core-result-truth.requested-time-floor

mapped_false portable-core-result-truth.test.legacy-233-stale-repeats-unchanged-target \
  stale-target-equal producer \
  '{selector:{kind:"target"},observed:$request_doc.body.target_revision} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mapped_true portable-core-result-truth.test.legacy-237-stale-environment-valid \
  stale-environment-different producer \
  '{selector:{kind:"environment"},observed:{state:"present",value:
    ($request_doc.body.environment_ref + {fingerprint_sha256:("0"*64)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-target-different producer \
  '{selector:{kind:"target"},observed:{state:"present",value:
    ($request_doc.body.target_revision.value + {commit_id:("0"*40)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-base-different producer \
  '{selector:{kind:"base"},observed:{state:"present",value:
    ($request_doc.body.base.value + {commit_id:("0"*40)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-source-different producer \
  '{selector:{kind:"source"},observed:{state:"present",value:
    ($request_doc.body.source.value | .value.object_id=("0"*40))}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mark_rule portable-core-result-truth.stale-difference

mapped_false portable-core-result-truth.test.stale-cross-repository-rejected \
  stale-cross-repository producer \
  '{selector:{kind:"target"},observed:{state:"present",value:
    ($request_doc.body.target_revision.value + {repository_id:"repo.other",
      commit_id:("0"*40)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_false stale-base-algorithm producer \
  '{selector:{kind:"base"},observed:{state:"present",value:
    {repository_id:"repo.example",hash_algorithm:"sha256",commit_id:("0"*64)}}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_false stale-source-cross-repository producer \
  '{selector:{kind:"source"},observed:{state:"present",value:
    ($request_doc.body.source.value | .value.revision.repository_id="repo.other")}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mark_rule portable-core-result-truth.stale-repository

mapped_true portable-core-result-truth.test.legacy-239-stale-resolved-profile-valid \
  stale-resolved-valid producer \
  '{selector:{kind:"resolved-profile"},observed:{state:"present",value:
    ($request_doc.body.resolved_profile_ref + {sha256:("0"*64)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mapped_true portable-core-result-truth.test.stale-resolved-profile-keeps-id \
  stale-resolved-id-preserved producer \
  '{selector:{kind:"resolved-profile"},observed:{state:"present",value:
    ($request_doc.body.resolved_profile_ref + {sha256:("0"*64)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mapped_false portable-core-result-truth.test.legacy-241-stale-resolved-profile-unrelated-id \
  stale-resolved-unrelated-id producer \
  '{selector:{kind:"resolved-profile"},observed:{state:"present",value:
    ($request_doc.body.resolved_profile_ref + {id:"resolved.other",sha256:("0"*64)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_false stale-environment-unrelated-id producer \
  '{selector:{kind:"environment"},observed:{state:"present",value:
    ($request_doc.body.environment_ref + {environment_id:"environment.other",
      fingerprint_sha256:("0"*64)})}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
mark_rule portable-core-result-truth.stale-identity

mapped_false portable-core-result-truth.test.legacy-235-stale-input-absent-from-request \
  stale-input-missing producer \
  '{selector:{kind:"input",input_id:"input.missing"},observed:{state:"absent"}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_false stale-gate-missing producer \
  '{selector:{kind:"gate-decision",scope_sha256:("0"*64)},observed:{state:"absent"}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-qualification-absent-to-present producer \
  '{selector:{kind:"qualification"},observed:{state:"present",value:
    ($request_doc.body.risk.policy_ref | .purpose="qualification")}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-input-selected producer \
  '$request_doc.body.inputs[0] as $input |
   {selector:{kind:"input",input_id:$input.input_id},
    observed:{state:"absent"}} |
   result_truth::stale_observation_relation_ok($request_doc.body;.)'
expect_true stale-gate-selected producer \
  '($request_doc.body.risk.policy_ref |
   .purpose="gate-decision") as $gate |
   ($request_doc.body | .gate_decision_refs=[$gate]) as $request |
   {selector:{kind:"gate-decision",scope_sha256:$gate.scope_sha256},
    observed:{state:"absent"}} |
   result_truth::stale_observation_relation_ok($request;.)'
mark_rule portable-core-result-truth.stale-member-selection

expect_true evidence-allowed-producer producer \
  'result_truth::evidence_kinds_allowed($request_doc.body;$result_doc.body)'
mapped_false portable-core-result-truth.test.legacy-213-producer-result-carries-reviewer-evidence \
  producer-review-evidence producer \
  '$result_doc.body |
   .evidence=[fixture::evidence("review";"independent-review";"passed")] |
   result_truth::evidence_kinds_allowed($request_doc.body;.)'
expect_false verifier-unrequested-subset verifier \
  '($request_doc.body | .required_evidence_kinds=["deterministic"]) as $request |
   $result_doc.body |
   result_truth::evidence_kinds_allowed($request;.)'
mark_rule portable-core-result-truth.evidence-allowed

mapped_true portable-core-result-truth.test.completed-evidence-exact \
  completed-exact-evidence verifier \
  'result_truth::completed_evidence_exact($request_doc.body;$result_doc.body)'
mapped_false portable-core-result-truth.test.completed-extra-evidence-rejected \
  completed-extra-evidence producer \
  '$result_doc.body |
   .evidence += [fixture::evidence("extra";"behavioral";"passed")] |
   result_truth::completed_evidence_exact($request_doc.body;.)'
expect_false completed-missing-evidence verifier \
  '$result_doc.body | .evidence=[.evidence[0]] |
   result_truth::completed_evidence_exact($request_doc.body;.)'
expect_true completed-evidence-id-order-independent verifier \
  '$result_doc.body |
   .evidence=[fixture::evidence("a";"deterministic";"passed"),
              fixture::evidence("b";"behavioral";"passed"),
              fixture::evidence("c";"architecture";"passed")] |
   result_truth::completed_evidence_exact($request_doc.body;.)'
mark_rule portable-core-result-truth.completed-evidence-exact

expect_true producer-inconclusive-evidence producer \
  '$result_doc.body | .evidence[0].verdict="inconclusive" |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("evidence.inconclusive") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
expect_false producer-inconclusive-with-output producer \
  '$result_doc.body | .evidence[0].verdict="failed" |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("evidence.failed") |
   .outputs=[fixture::output("one";"application/json";"1")] |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
expect_false producer-inconclusive-with-delta producer \
  '$result_doc.body | .evidence[0].verdict="inconclusive" |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("evidence.inconclusive") |
   .delta_ref=fixture::content("delta";"text/x-diff";"2") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mark_rule portable-core-result-truth.producer-inconclusive

expect_true producer-no-change producer \
  'result_truth::producer_outcome_ok(
    $request_doc.body.operation;$result_doc.body)'
mapped_false portable-core-result-truth.test.legacy-209-producer-outcome-mismatches-nonempty-outputs \
  no-change-with-output producer \
  '$result_doc.body |
   .outputs=[fixture::output("one";"application/json";"1")] |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mark_rule portable-core-result-truth.producer-no-change

expect_true structured-output-changed producer \
  '$result_doc.body |
   .outcome={family:"change",value:"changed"} |
   .outputs=[fixture::output("one";"application/json";"1")] |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
expect_false structured-output-delta producer \
  '$result_doc.body |
   .outcome={family:"change",value:"changed"} |
   .outputs=[fixture::output("one";"application/json";"1")] |
   .delta_ref=fixture::content("delta";"text/x-diff";"2") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_false portable-core-result-truth.test.legacy-231-producer-more-than-one-output \
  producer-two-outputs producer \
  '$result_doc.body |
   .outcome={family:"change",value:"changed"} |
   .outputs=[fixture::output("one";"application/json";"1"),
             fixture::output("two";"application/json";"2")] |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_true portable-core-result-truth.test.patch-output-matches-delta \
  patch-output-delta producer \
  '($request_doc.body.operation |
    .arguments={artifact_kind:"git-patch",allowed_delta:
      $request_doc.body.operation.arguments.output_contract}) as $operation |
   $result_doc.body |
   .outcome={family:"change",value:"changed"} |
   .outputs=[fixture::output("patch";"text/x-diff";"3")] |
   .delta_ref=.outputs[0].ref |
   result_truth::producer_outcome_ok($operation;.)'
expect_false patch-delta-mismatch producer \
  '($request_doc.body.operation |
    .arguments={artifact_kind:"git-patch",allowed_delta:
      $request_doc.body.operation.arguments.output_contract}) as $operation |
   $result_doc.body |
   .outcome={family:"change",value:"changed"} |
   .outputs=[fixture::output("patch";"text/x-diff";"3")] |
   .delta_ref=fixture::content("delta";"text/x-diff";"4") |
   result_truth::producer_outcome_ok($operation;.)'
mark_rule portable-core-result-truth.producer-change-output

mapped_true portable-core-result-truth.test.failed-evidence-precedes-inconclusive \
  check-failed-precedence verifier \
  '$result_doc.body |
   .evidence[0].verdict="failed" | .evidence[1].verdict="inconclusive" |
   .outcome={family:"check",value:"failed"} |
   result_truth::check_outcome_ok(.)'
expect_true check-failed-precedes-gap verifier \
  '$result_doc.body |
   .evidence[0].verdict="failed" |
   .execution.metadata.tools=fixture::unavailable("tools.missing") |
   .outcome={family:"check",value:"failed"} |
   result_truth::check_outcome_ok(.)'
expect_false check-failed-as-inconclusive verifier \
  '$result_doc.body |
   .evidence[0].verdict="failed" | .evidence[1].verdict="inconclusive" |
   .outcome={family:"check",value:"inconclusive"} |
   result_truth::check_outcome_ok(.)'
mark_rule portable-core-result-truth.check-failed-precedence

expect_true check-inconclusive-evidence verifier \
  '$result_doc.body | .evidence[0].verdict="inconclusive" |
   .outcome={family:"check",value:"inconclusive"} |
   result_truth::check_outcome_ok(.)'
expect_false check-inconclusive-as-passed verifier \
  '$result_doc.body | .evidence[0].verdict="inconclusive" |
   result_truth::check_outcome_ok(.)'
mark_rule portable-core-result-truth.check-inconclusive

expect_true check-passed verifier \
  'result_truth::check_outcome_ok($result_doc.body)'
expect_false check-output verifier \
  '$result_doc.body |
   .outputs=[fixture::output("one";"application/json";"1")] |
   result_truth::check_outcome_ok(.)'
mark_rule portable-core-result-truth.check-passed

expect_false no-fact-gap producer \
  'result_truth::requested_fact_gap($result_doc.body)'
for fact in provider model effort prompt skills tools; do
  expect_true "fact-gap-$fact" producer \
    "\$result_doc.body | .execution.metadata.$fact=fixture::unavailable(\"$fact.missing\") |
     result_truth::requested_fact_gap(.)"
done
expect_false snapshot-not-requested-gap producer \
  '$result_doc.body |
   .execution.metadata.snapshot=fixture::unavailable("snapshot.missing") |
   result_truth::requested_fact_gap(.)'
mapped_false portable-core-result-truth.test.legacy-249-unavailable-prompt-conclusive \
  prompt-gap-conclusive producer \
  '$result_doc.body |
   .execution.metadata.prompt=fixture::unavailable("prompt.missing") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_true portable-core-result-truth.test.legacy-251-unavailable-prompt-inconclusive \
  prompt-gap-inconclusive producer \
  '$result_doc.body |
   .execution.metadata.prompt=fixture::unavailable("prompt.missing") |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("prompt.missing") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_false portable-core-result-truth.test.legacy-253-unavailable-tools-conclusive \
  tools-gap-conclusive producer \
  '$result_doc.body |
   .execution.metadata.tools=fixture::unavailable("tools.missing") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_true portable-core-result-truth.test.legacy-255-unavailable-tools-inconclusive \
  tools-gap-inconclusive producer \
  '$result_doc.body |
   .execution.metadata.tools=fixture::unavailable("tools.missing") |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("tools.missing") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mapped_true portable-core-result-truth.test.unavailable-tools-force-inconclusive \
  tools-gap-review-row producer \
  '$result_doc.body |
   .execution.metadata.tools=fixture::unavailable("tools.missing") |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("tools.missing") |
   result_truth::producer_outcome_ok($request_doc.body.operation;.)'
mark_rule portable-core-result-truth.fact-gap

expect_true passing-review-identity reviewer \
  'result_truth::passing_review_identity_ok($request_doc.body;$result_doc.body)'
expect_false passing-review-wrong-performer reviewer \
  '$result_doc.body | .execution.performer.role="producer" |
   result_truth::passing_review_identity_ok($request_doc.body;.)'
expect_true failed-review-wrong-performer reviewer \
  '$result_doc.body | .evidence[0].verdict="failed" |
   .execution.performer.role="producer" |
   result_truth::passing_review_identity_ok($request_doc.body;.)'
mark_rule portable-core-result-truth.passing-review-identity

expect_true failed-executed-family producer \
  'fixture::failed_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   result_truth::status_external_relation_ok($request_doc.body;.)'
expect_false failed-wrong-family producer \
  'fixture::failed_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .outcome.family="check" |
   result_truth::status_external_relation_ok($request_doc.body;.)'
mark_rule portable-core-result-truth.incident-outcome-family

mapped_true portable-core-result-truth.test.completed-inconclusive-preserves-mismatch \
  inconclusive-mismatch-preserved producer \
  '$result_doc.body |
   .evidence[0].verdict="failed" |
   .outcome={family:"change",value:"inconclusive"} |
   .reason=fixture::reason("execution.mismatch") |
   .execution.environment.fingerprint_sha256=("0"*64) |
   result_truth::stage_result_relation_ok($request_pair;$resolved_pair;.)'
expect_false conclusive-mismatch-rejected producer \
  '$result_doc.body |
   .execution.environment.fingerprint_sha256=("0"*64) |
   result_truth::stage_result_relation_ok($request_pair;$resolved_pair;.)'
mark_rule portable-core-result-truth.execution-assessment

expect_true stage-result-relation producer \
  'result_truth::stage_result_relation_ok(
    $request_pair;$resolved_pair;$result_doc.body)'
expect_false stale-relation-equal producer \
  'fixture::stale_result_doc(
     $request_doc;$request_sha;$resolved_doc;$resolved_sha).body |
   .stale_observations=[{selector:{kind:"target"},
     observed:$request_doc.body.target_revision}] |
   result_truth::stage_result_relation_ok($request_pair;$resolved_pair;.)'
mark_rule portable-core-result-truth.stage-result-relation

expect_true document-self producer \
  '$result_doc | result_truth::document_self_ok'
mapped_true portable-core-result-truth.test.legacy-015-validate-document-result \
  document-result-route producer \
  '$result_doc | result_truth::document_self_ok'
expect_false document-wrong-kind producer \
  '$result_doc | .kind="stage_request" |
   result_truth::document_shape_ok'
mark_rule portable-core-result-truth.document-routing

run_counted() {
  local counter="$1"
  local case_id="$2"
  local expected="$3"
  local role="$4"
  local expression="$5"
  local request_sha actual
  request_sha="$(cat "$truth_tmp/request-$role.sha")"
  case "$counter" in
    cell) truth_cell_total=$((truth_cell_total + 1)) ;;
    forced) truth_forced_total=$((truth_forced_total + 1)) ;;
  esac
  if ! actual="$("${truth_jq_command[@]}" -r -L "$truth_module_dir" \
      -L "$truth_fixture_dir" -n \
      --slurpfile request "$truth_tmp/request-$role.json" \
      --slurpfile resolved "$resolved_file" \
      --slurpfile result "$truth_tmp/result-$role.json" \
      --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
      'import "result_truth" as result_truth;
       $request[0] as $request_doc | $resolved[0] as $resolved_doc |
       $result[0] as $result_doc |
       {content:$request_doc,sha256:$request_sha} as $request_pair |
       {content:$resolved_doc,sha256:$resolved_sha} as $resolved_pair |
       {content:$result_doc,sha256:("a"*64)} as $result_pair |
       ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    case "$counter" in
      cell) truth_cell_passed=$((truth_cell_passed + 1)) ;;
      forced) truth_forced_passed=$((truth_forced_passed + 1)) ;;
    esac
  else fail_case "$case_id expected $expected, got $actual"
  fi
}

run_counted cell document-result-truth true producer \
  '$result_doc | result_truth::document_self_ok'
run_counted cell stage-run-truth true producer \
  'result_truth::stage_run_ok($request_pair;$resolved_pair;$result_pair)'
run_counted forced document-result-truth-reject false producer \
  '$result_doc | del(.body.finished_at) | result_truth::document_self_ok'
run_counted forced stage-run-truth-reject false producer \
  '$result_doc | .body.request_ref.sha256=("0"*64) |
   {content:.,sha256:("a"*64)} as $bad_result |
   result_truth::stage_run_ok($request_pair;$resolved_pair;$bad_result)'
mark_rule portable-core-result-truth.stage-run-routing

guard_pass() {
  truth_guard_total=$((truth_guard_total + 1))
  truth_guard_passed=$((truth_guard_passed + 1))
}

guard_fail() {
  truth_guard_total=$((truth_guard_total + 1))
  fail_case "$1"
}

current_blob_ok() {
  local path="$1"
  local expected="$2"
  local mode type oid actual_path
  IFS=$' \t' read -r mode type oid actual_path < <(
    git -C "$truth_root" ls-tree HEAD -- "$path"
  ) || return 1
  [ "$mode" = 100644 ] && [ "$type" = blob ] &&
    [ "$oid" = "$expected" ] && [ "$actual_path" = "$path" ]
}

tracked_worktree_file_ok() {
  local path="$1"
  local expected_mode="$2"
  local mode type oid actual_path
  IFS=$' \t' read -r mode type oid actual_path < <(
    git -C "$truth_root" ls-tree HEAD -- "$path"
  ) || return 1
  [ "$mode" = "$expected_mode" ] && [ "$type" = blob ] &&
    [ "$actual_path" = "$path" ] &&
    [ "$oid" = "$(git -C "$truth_root" hash-object "$path")" ]
}

if current_blob_ok "$truth_generation_root/modules/schema.jq" "$truth_schema_oid"; then
  guard_pass
else guard_fail "schema export pin"
fi
if current_blob_ok "$truth_generation_root/core-ingress.sh" "$truth_ingress_oid"; then
  guard_pass
else guard_fail "ingress dependency pin"
fi
if current_blob_ok "$truth_generation_root/modules/profile_graph.jq" "$truth_profile_oid"; then
  guard_pass
else guard_fail "profile dependency pin"
fi
if current_blob_ok "$truth_generation_root/modules/stage_request.jq" "$truth_stage_oid"; then
  guard_pass
else guard_fail "stage-request dependency pin"
fi
if current_blob_ok "$truth_generation_root/modules/result_facts.jq" "$truth_facts_oid"; then
  guard_pass
else guard_fail "result-facts serial dependency pin"
fi
if current_blob_ok "core/v1/generation-registry.json" "$truth_registry_oid"; then
  guard_pass
else guard_fail "generation registry pin"
fi

if [ "$("${truth_jq_command[@]}" -r '.construction_base' <<< "$truth_metadata")" = \
     "1c45dd3015bb22f13db41217d09a7d73a9b0617c" ] &&
   [ "$("${truth_jq_command[@]}" -r '.result_facts_g3_comment' <<< "$truth_metadata")" -eq 5469128966 ] &&
   [ "$("${truth_jq_command[@]}" -r '.result_facts_merge_commit' <<< "$truth_metadata")" = \
     "1c45dd3015bb22f13db41217d09a7d73a9b0617c" ] &&
   [ "$("${truth_jq_command[@]}" -r '.result_facts_export_oid' <<< "$truth_metadata")" = "$truth_facts_oid" ] &&
   [ "$("${truth_jq_command[@]}" -r '.frozen_source_head' <<< "$truth_metadata")" = \
     "ab4a7082f02e67b5748c5c54b9214f37d222f53f" ] &&
   [ "$("${truth_jq_command[@]}" -r '.frozen_test_blob' <<< "$truth_metadata")" = \
     "8a9921d3763e3fcfa103037b021dd6c95bdcad61" ]; then
  guard_pass
else guard_fail "fixture dependency metadata"
fi

if [ "$(git -C "$truth_root" hash-object config/construction-mode.json)" = \
     "4f35b0ec232e584973071a8d2e90ee5971af6e79" ] &&
   [ "$(git -C "$truth_root" hash-object ROADMAP.md)" = \
     "4bb0fff1ee11c20441cc16182337f762300ac0f2" ] &&
   [ "$(git -C "$truth_root" hash-object NORTH_STAR.md)" = \
     "d2bbe82a8b2a1bb14fde1c50995f7ecec9b58013" ]; then
  guard_pass
else guard_fail "construction identity"
fi

expected_imports='import "schema" as schema;
import "profile_graph" as profile_graph;
import "stage_request" as stage_request;
import "result_facts" as result_facts;'
if [ "$(sed -n '1,4p' "$truth_root/$truth_module_path")" = "$expected_imports" ] &&
   [ "$(grep -Ec '^import ' "$truth_root/$truth_module_path")" -eq 4 ]; then
  guard_pass
else guard_fail "fixed module imports"
fi
mark_rule portable-core-result-truth.fixed-imports

if [ "$(awk 'END {print NR-1}' "$truth_ledger")" -eq 56 ] &&
   [ "$(awk -F '\t' 'NR>1 && $1=="review" {n++} END {print n+0}' "$truth_ledger")" -eq 8 ] &&
   [ "$(awk -F '\t' 'NR>1 && $1=="legacy" {n++} END {print n+0}' "$truth_ledger")" -eq 48 ] &&
   [ "$(sha256_path "$truth_ledger")" = \
     "$("${truth_jq_command[@]}" -r '.mapping_sha256' <<< "$truth_metadata")" ]; then
  guard_pass
else guard_fail "frozen migration ledger"
fi

required_paths="$truth_module_path
scripts/test/portable-core-result-truth-fixtures.jq
scripts/test/portable-core-result-truth-ledger.tsv
scripts/test/portable-core-result-truth.test.sh"
manifest_ok=true
while IFS= read -r required_path; do
  [ "$(grep -Fxc "$required_path" "$truth_manifest" || true)" -eq 1 ] &&
    [ -f "$truth_root/$required_path" ] || manifest_ok=false
done <<< "$required_paths"
if [ "$manifest_ok" = true ]; then guard_pass
else guard_fail "restore manifest coverage"
fi
mark_rule portable-core-result-truth.restore-manifest

truth_activation_state_ok() {
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
    [ "$(grep -Fxc "PORTABLE_CORE_GENERATION='$truth_generation'" "$wrapper")" -eq 1 ]
}

if truth_activation_state_ok "$truth_root/$truth_generation_root/contracts.jq" \
     "$truth_root/scripts/core-contract.sh" &&
   [ -z "$(find "$truth_root/$truth_generation_root" "$truth_fixture" "$truth_ledger" \
     -type l -print -quit)" ]; then
  guard_pass
else guard_fail "generation activation and regular files"
fi

if [ -x "$truth_root/scripts/test/portable-core-result-truth.test.sh" ] &&
   grep -Fq "find \"\$root/scripts/test\" -maxdepth 1 -type f -name '*.test.sh'" \
     "$truth_root/scripts/test/run-all.sh"; then
  guard_pass
else guard_fail "CI test discovery"
fi
mark_rule portable-core-result-truth.dependency-pins

generation_members_ok=true
while IFS= read -r generation_file; do
  case "$generation_file" in
    "$truth_generation_root/core-ingress.sh"|\
    "$truth_generation_root/contracts.jq"|\
    "$truth_generation_root/modules/schema.jq"|\
    "$truth_generation_root/modules/profile_graph.jq"|\
    "$truth_generation_root/modules/stage_request.jq"|\
    "$truth_generation_root/modules/result_facts.jq"|\
    "$truth_generation_root/modules/result_truth.jq") ;;
    *) generation_members_ok=false ;;
  esac
done < <(find "$truth_root/$truth_generation_root" -type f -print |
  sed "s#^$truth_root/##" | LC_ALL=C sort)
if [ "$generation_members_ok" = true ]; then
  guard_pass
else guard_fail "private generation member allowlist"
fi

if tracked_worktree_file_ok "$truth_module_path" 100644 &&
   tracked_worktree_file_ok \
     scripts/test/portable-core-result-truth-fixtures.jq 100644 &&
   tracked_worktree_file_ok \
     scripts/test/portable-core-result-truth-ledger.tsv 100644 &&
   tracked_worktree_file_ok \
     scripts/test/portable-core-result-truth.test.sh 100755; then
  guard_pass
else guard_fail "owned current-tree files"
fi

mark_rule portable-core-result-truth.dependency-pins

truth_expected_rules="$truth_tmp/expected-rules"
printf '%s\n' \
  portable-core-result-truth.attempt-number \
  portable-core-result-truth.check-failed-precedence \
  portable-core-result-truth.check-inconclusive \
  portable-core-result-truth.check-passed \
  portable-core-result-truth.completed-evidence-exact \
  portable-core-result-truth.dependency-pins \
  portable-core-result-truth.document-routing \
  portable-core-result-truth.evidence-allowed \
  portable-core-result-truth.evidence-shape \
  portable-core-result-truth.evidence-unique-kind \
  portable-core-result-truth.execution-assessment \
  portable-core-result-truth.fact-gap \
  portable-core-result-truth.fixed-imports \
  portable-core-result-truth.incident-outcome-family \
  portable-core-result-truth.local-time-order \
  portable-core-result-truth.outcome-shape \
  portable-core-result-truth.output-shape \
  portable-core-result-truth.passing-review-identity \
  portable-core-result-truth.producer-change-output \
  portable-core-result-truth.producer-inconclusive \
  portable-core-result-truth.producer-no-change \
  portable-core-result-truth.reason-shape \
  portable-core-result-truth.refs \
  portable-core-result-truth.requested-time-floor \
  portable-core-result-truth.restore-manifest \
  portable-core-result-truth.result-body-shape \
  portable-core-result-truth.stage-result-relation \
  portable-core-result-truth.stage-run-routing \
  portable-core-result-truth.stale-difference \
  portable-core-result-truth.stale-identity \
  portable-core-result-truth.stale-member-selection \
  portable-core-result-truth.stale-observed-shape \
  portable-core-result-truth.stale-repository \
  portable-core-result-truth.stale-selector-shape \
  portable-core-result-truth.stale-selector-unique \
  portable-core-result-truth.status-blocked \
  portable-core-result-truth.status-cancelled \
  portable-core-result-truth.status-completed \
  portable-core-result-truth.status-failed \
  portable-core-result-truth.status-skipped \
  portable-core-result-truth.status-stale > "$truth_expected_rules"

LC_ALL=C sort -u "$truth_expected_rules" > "$truth_tmp/expected-rules.sorted"
LC_ALL=C sort -u "$truth_seen_rules" > "$truth_tmp/seen-rules.sorted"
if ! cmp -s "$truth_tmp/expected-rules.sorted" "$truth_tmp/seen-rules.sorted"; then
  fail_case "owned rule inventory"
fi

tail -n +2 "$truth_ledger" | cut -f5 | LC_ALL=C sort -u > \
  "$truth_tmp/expected-tests"
LC_ALL=C sort -u "$truth_seen_tests" > "$truth_tmp/seen-tests.sorted"
if ! cmp -s "$truth_tmp/expected-tests" "$truth_tmp/seen-tests.sorted"; then
  fail_case "ledger stable test inventory"
fi

truth_review_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="review" && ($5 in seen) {n++}
  END {print n+0}
' "$truth_tmp/seen-tests.sorted" "$truth_ledger")"
truth_legacy_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="legacy" && ($5 in seen) {n++}
  END {print n+0}
' "$truth_tmp/seen-tests.sorted" "$truth_ledger")"
if [ "$truth_review_accounted" -ne 8 ] ||
   [ "$truth_legacy_accounted" -ne 48 ]; then
  fail_case "ledger executed mapping"
fi

truth_owned_total="$(wc -l < "$truth_tmp/expected-rules.sorted" | tr -d ' ')"
if [ "$truth_owned_total" -ne \
     "$("${truth_jq_command[@]}" -r '.owned_rules' <<< "$truth_metadata")" ] ||
   [ "$truth_direct_total" -ne \
     "$("${truth_jq_command[@]}" -r '.direct_cases' <<< "$truth_metadata")" ] ||
   [ "$truth_cell_total" -ne \
     "$("${truth_jq_command[@]}" -r '.command_to_rule_cells' <<< "$truth_metadata")" ] ||
   [ "$truth_forced_total" -ne \
     "$("${truth_jq_command[@]}" -r '.forced_routes' <<< "$truth_metadata")" ] ||
   [ "$truth_guard_total" -ne \
     "$("${truth_jq_command[@]}" -r '.guard_cases' <<< "$truth_metadata")" ]; then
  fail_case "fixed proof denominators"
fi

truth_owned_passed="$truth_owned_total"
if [ "$truth_failures" -ne 0 ]; then truth_owned_passed=0; fi

printf 'portable-core-result-truth owned rules: %s/%s\n' \
  "$truth_owned_passed" "$truth_owned_total"
printf 'portable-core-result-truth direct cases: %s/%s\n' \
  "$truth_direct_passed" "$truth_direct_total"
printf 'portable-core-result-truth command-to-rule cells: %s/%s\n' \
  "$truth_cell_passed" "$truth_cell_total"
printf 'portable-core-result-truth forced routes: %s/%s\n' \
  "$truth_forced_passed" "$truth_forced_total"
printf 'portable-core-result-truth guards: %s/%s\n' \
  "$truth_guard_passed" "$truth_guard_total"
printf 'portable-core-result-truth review rows: %s/8\n' "$truth_review_accounted"
printf 'portable-core-result-truth legacy rows: %s/48\n' "$truth_legacy_accounted"
printf 'portable-core-result-truth failures: %s\n' "$truth_failures"

[ "$truth_failures" -eq 0 ]
