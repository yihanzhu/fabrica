#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
test_dir="$test_root/scripts/test"
generation_id="g-392d20099dfa99872764009b268c8871914b4dbc0da467ec346baa921818ae3e"
parent_generation="g-71433a31f52f37041a41b5a8812f79c4c0f5f26c79265788c8d625a9c6f9686b"
parent_root="$test_root/core/v1/generations/$parent_generation"
generation_root="$test_root/core/v2/generations/$generation_id"
registry="$test_root/core/v2/generation-registry.json"
wrapper="$test_root/scripts/core-contract.sh"
manifest="$test_root/ci/required-files.txt"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-core-v2-forge.XXXXXX")"

cleanup() {
  rm -rf -- "$test_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

test_platform="$(uname -s):$(uname -m)"
case "$test_platform" in
  Linux:x86_64)
    test_asset="jq-linux64"
    test_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    test_asset="jq-osx-amd64"
    test_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    printf 'FAIL: unsupported jq 1.6 proof platform: %s\n' "$test_platform" >&2
    exit 1
    ;;
esac

test_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
test_jq="$test_cache/$test_asset"
if [ -f "$test_jq" ] &&
   [ "$(sha256_path "$test_jq")" = "$test_asset_sha256" ]; then
  jq_command=("$test_jq")
  if [ "$test_platform" = Darwin:arm64 ]; then
    jq_command=(/usr/bin/arch -x86_64 "$test_jq")
  fi
elif test_jq="$(command -v jq 2>/dev/null)" &&
     [ "$("$test_jq" --version 2>/dev/null)" = jq-1.6 ]; then
  jq_command=("$test_jq")
else
  echo 'FAIL: jq 1.6 is required on PATH or in the verified portable-core cache' >&2
  exit 1
fi
[ "$("${jq_command[@]}" --version)" = jq-1.6 ] || {
  echo 'FAIL: pinned jq 1.6 identity check failed' >&2
  exit 1
}

runtime_bin="$test_tmp/runtime-bin"
mkdir -p "$runtime_bin"
ln -s "$test_jq" "$runtime_bin/jq"
export PATH="$runtime_bin:/usr/bin:/bin"

failures=0
passed=0
total=0

check() {
  local case_id="$1"
  shift
  total=$((total + 1))
  if "$@" >/dev/null; then
    passed=$((passed + 1))
  else
    printf 'FAIL: %s\n' "$case_id" >&2
    failures=$((failures + 1))
  fi
}

run_v2() (
  local mode="$1"
  shift
  local input
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$generation_root/core-ingress.sh" 2>/dev/null || exit 1
  trap 'portable_core_ingress_close >/dev/null 2>&1 || :' EXIT
  portable_core_ingress_open || exit 1
  portable_core_ingress_begin "$mode" || exit 1
  for input in "$@"; do
    portable_core_ingress_snapshot "$input" || exit 1
  done
  portable_core_ingress_finish_driver || exit 1
  portable_core_ingress_validate || exit 1
  portable_core_ingress_close || exit 1
  trap - EXIT
)

run_v1_document() (
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$parent_root/core-ingress.sh" 2>/dev/null || exit 1
  trap 'portable_core_ingress_close >/dev/null 2>&1 || :' EXIT
  portable_core_ingress_open || exit 1
  portable_core_ingress_begin document || exit 1
  portable_core_ingress_snapshot "$1" || exit 1
  portable_core_ingress_finish_driver || exit 1
  portable_core_ingress_validate || exit 1
  portable_core_ingress_close || exit 1
  trap - EXIT
)

expect_v2_pass() {
  local case_id="$1"
  local mode="$2"
  shift 2
  local out="$test_tmp/$case_id.out"
  local err="$test_tmp/$case_id.err"
  run_v2 "$mode" "$@" >"$out" 2>"$err" &&
    [ ! -s "$out" ] && [ ! -s "$err" ]
}

expect_v2_error() {
  local case_id="$1"
  local expected="$2"
  local mode="$3"
  shift 3
  local out="$test_tmp/$case_id.out"
  local err="$test_tmp/$case_id.err"
  if run_v2 "$mode" "$@" >"$out" 2>"$err"; then
    return 1
  fi
  [ ! -s "$out" ] && [ "$(cat "$err")" = "$expected" ]
}

expect_v1_error() {
  local case_id="$1"
  local expected="$2"
  local document="$3"
  local out="$test_tmp/$case_id.out"
  local err="$test_tmp/$case_id.err"
  if run_v1_document "$document" >"$out" 2>"$err"; then
    return 1
  fi
  [ ! -s "$out" ] && [ "$(cat "$err")" = "$expected" ]
}

json_mutate() {
  local source="$1"
  local destination="$2"
  local filter="$3"
  "${jq_command[@]}" -S -c "$filter" "$source" >"$destination"
}

roles=(producer publisher reviewer verifier)
manifest_files=()
for role in "${roles[@]}"; do
  file="$test_tmp/manifest-$role.json"
  "${jq_command[@]}" -L "$test_dir" -S -c -n --arg role "$role" '
    import "portable-core-profile-graph-fixtures" as profile;
    def v2: walk(if type == "object" and has("schema_version")
                 then .schema_version = 2 else . end);
    profile::manifest($role) | v2
  ' >"$file"
  manifest_files+=("$file")
done

forge_manifest="$test_tmp/manifest-forge.json"
"${jq_command[@]}" -L "$test_dir" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  {
    schema_version:2,
    kind:"adapter_manifest",
    id:"manifest.forge",
    body:{
      adapter_version:"v2",
      package_ref:profile::blob("packages/forge.bin";"6"),
      offered_roles:["forge"],
      offered_execution_kinds:["deterministic"],
      offered_capabilities:["core.forge.materialize-candidate.v2"],
      offered_permissions:[
        "core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1",
        "core.perm.scratch.write.v1",
        "core.perm.target.read.v1"
      ],
      offered_tools:[]
    }
  }
' >"$forge_manifest"
manifest_files=("$forge_manifest" "${manifest_files[@]}")

manifest_shas="$({
  printf '{'
  printf '"forge":"%s"' "$(sha256_path "$forge_manifest")"
  for role in "${roles[@]}"; do
    printf ',"%s":"%s"' "$role" \
      "$(sha256_path "$test_tmp/manifest-$role.json")"
  done
  printf '}\n'
} | "${jq_command[@]}" -S -c .)"

profile_file="$test_tmp/profile.json"
"${jq_command[@]}" -L "$test_dir" -S -c -n \
  --argjson manifest_shas "$manifest_shas" '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version = 2 else . end);
  def forge_binding:
    {
      binding_id:"binding.forge",
      role:"forge",
      manifest_ref:{schema_version:2,kind:"adapter_manifest",
                    id:"manifest.forge",sha256:$manifest_shas.forge},
      execution_kind:"deterministic",
      adapter_instance_id:"instance.forge",
      principal_id:"principal.forge",
      execution_boundary_id:"boundary.forge",
      authority_ref:profile::scope("authority";"authority-forge";
                                   profile::sha("5")),
      package_ref:profile::blob("packages/forge.bin";"6"),
      skill_refs:[],
      requested_tools:[],
      requested_capabilities:["core.forge.materialize-candidate.v2"],
      requested_permissions:[
        "core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1",
        "core.perm.scratch.write.v1",
        "core.perm.target.read.v1"
      ]
    };
  profile::profile_doc($manifest_shas) | v2 |
  .body.profile_version = "v2" |
  .body.bindings += [forge_binding] |
  .body.bindings |= sort_by(.binding_id)
' >"$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$test_tmp/resolved.json"
"${jq_command[@]}" -L "$test_dir" -S -c -n \
  --slurpfile profile_doc "$profile_file" \
  --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_shas" '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version = 2 else . end);
  profile::resolved_profile_doc(
    $profile_doc[0];$profile_sha;$manifest_shas) | v2 |
  .body.bindings |= map(
    if .binding.role == "forge" then
      .adapter_implementation.version = "v2" |
      .manifest_source = profile::source_value(
        profile::blob("manifests/forge.json";"a");
        "canonical-json";$manifest_shas.forge)
    else . end)
' >"$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

request_file="$test_tmp/request.json"
"${jq_command[@]}" -L "$test_dir" -S -c -n \
  --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version = 2 else . end);
  request::request_doc("producer";$resolved_sha) | v2 |
  .id = "request.forge" |
  .body.stage_id = "stage.forge" |
  .body.inputs = ([
    request::named_content_input("finish";request::sha("1")),
    request::named_content_input("materialize";request::sha("3")),
    request::named_tree_input("source-tree"),
    request::named_content_input("verify";request::sha("2"))
  ] | sort_by(.input_id)) |
  .body.operation = {
    role:"forge",
    binding_id:"binding.forge",
    capability_id:"core.forge.materialize-candidate.v2",
    permissions:[
      "core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1",
      "core.perm.target.read.v1"
    ],
    arguments:{
      source_tree_input_id:"input.source-tree",
      candidate_output_id:"candidate.repository",
      materialization_contract:
        request::delivered("output-contract";"materialize";request::sha("3")),
      network_mode:"deny"
    }
  } |
  .body.required_evidence_kinds = ["deterministic"]
' >"$request_file"
request_sha="$(sha256_path "$request_file")"

result_file="$test_tmp/result.json"
"${jq_command[@]}" -L "$test_dir" -S -c -n \
  --slurpfile request_doc "$request_file" \
  --slurpfile resolved_doc "$resolved_file" \
  --arg request_sha "$request_sha" \
  --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version = 2 else . end);
  result::completed_result_doc(
    $request_doc[0];$request_sha;$resolved_doc[0];$resolved_sha) | v2 |
  .body.outcome = {family:"change",value:"changed"} |
  .body.outputs = [{
    output_id:"candidate.repository",
    ref:{content_id:"candidate-materialization-receipt",
         media_type:"application/json",sha256:("c" * 64)}
  }]
' >"$result_file"

check forge-manifest-document expect_v2_pass forge-manifest-document \
  document "$forge_manifest"
check forge-profile-set expect_v2_pass forge-profile-set \
  profile-set "$profile_file" "$resolved_file" "${manifest_files[@]}"
check forge-stage-run expect_v2_pass forge-stage-run \
  stage-run "$request_file" "$resolved_file" "$result_file"
no_change_result="$test_tmp/no-change-result.json"
json_mutate "$result_file" "$no_change_result" \
  '.body.outputs = [] | .body.outcome = {family:"change",value:"no-change"}'
check forge-no-change expect_v2_pass forge-no-change \
  stage-run "$request_file" "$resolved_file" "$no_change_result"
inconclusive_result="$test_tmp/inconclusive-result.json"
json_mutate "$result_file" "$inconclusive_result" '
  .body.outputs = [] |
  .body.outcome = {family:"change",value:"inconclusive"} |
  .body.reason = {reason_id:"materialization.inconclusive"} |
  .body.evidence[0].verdict = "inconclusive"
'
check forge-inconclusive expect_v2_pass forge-inconclusive \
  stage-run "$request_file" "$resolved_file" "$inconclusive_result"

v1_envelope="$test_tmp/v1-envelope.json"
json_mutate "$forge_manifest" "$v1_envelope" '.schema_version = 1'
check v2-rejects-v1-envelope expect_v2_error v2-rejects-v1-envelope \
  E_SHAPE document "$v1_envelope"
check v1-rejects-v2-envelope expect_v1_error v1-rejects-v2-envelope \
  E_SHAPE "$forge_manifest"

wrong_role="$test_tmp/wrong-role.json"
json_mutate "$request_file" "$wrong_role" '.body.operation.role = "producer"'
check wrong-role expect_v2_error wrong-role E_RELATION document "$wrong_role"

wrong_capability="$test_tmp/wrong-capability.json"
json_mutate "$request_file" "$wrong_capability" '
  .body.operation.capability_id = "core.harness.produce.v1" |
  .body.operation.permissions = [
    "core.perm.evidence.write.v1",
    "core.perm.scratch.write.v1",
    "core.perm.target.read.v1"
  ] |
  .body.operation.arguments = {
    artifact_kind:"structured-artifact",
    output_contract:.body.operation.arguments.materialization_contract
  }
'
check wrong-capability expect_v2_error wrong-capability \
  E_RELATION document "$wrong_capability"

wrong_permission="$test_tmp/wrong-permission.json"
json_mutate "$request_file" "$wrong_permission" '
  .body.operation.permissions -= ["core.perm.candidate-repository.write.v2"]
'
check wrong-permission expect_v2_error wrong-permission \
  E_RELATION document "$wrong_permission"

wrong_arguments="$test_tmp/wrong-arguments.json"
json_mutate "$request_file" "$wrong_arguments" \
  '.body.operation.arguments.network_mode = "allow"'
check wrong-arguments expect_v2_error wrong-arguments \
  E_SHAPE document "$wrong_arguments"

wrong_evidence="$test_tmp/wrong-evidence.json"
json_mutate "$result_file" "$wrong_evidence" \
  '.body.evidence[0].kind = "independent-review"'
check wrong-evidence expect_v2_error wrong-evidence \
  E_RELATION stage-run "$request_file" "$resolved_file" "$wrong_evidence"

wrong_outcome="$test_tmp/wrong-outcome.json"
json_mutate "$result_file" "$wrong_outcome" \
  '.body.outcome = {family:"check",value:"passed"}'
check wrong-outcome expect_v2_error wrong-outcome \
  E_RELATION stage-run "$request_file" "$resolved_file" "$wrong_outcome"

wrong_output="$test_tmp/wrong-output.json"
json_mutate "$result_file" "$wrong_output" \
  '.body.outputs[0].output_id = "candidate.other"'
check wrong-output-relation expect_v2_error wrong-output-relation \
  E_RELATION stage-run "$request_file" "$resolved_file" "$wrong_output"

wrong_binding_request="$test_tmp/wrong-binding-request.json"
json_mutate "$request_file" "$wrong_binding_request" \
  '.body.operation.binding_id = "binding.producer"'
wrong_binding_sha="$(sha256_path "$wrong_binding_request")"
wrong_binding_result="$test_tmp/wrong-binding-result.json"
"${jq_command[@]}" -S -c --arg request_sha "$wrong_binding_sha" \
  '.body.request_ref.sha256 = $request_sha' "$result_file" >"$wrong_binding_result"
check wrong-binding expect_v2_error wrong-binding E_RELATION \
  stage-run "$wrong_binding_request" "$resolved_file" "$wrong_binding_result"

shared_profile="$test_tmp/shared-profile.json"
json_mutate "$profile_file" "$shared_profile" '
  (.body.bindings[] | select(.role == "forge") | .principal_id) =
    (.body.bindings[] | select(.role == "producer") | .principal_id)
'
shared_profile_sha="$(sha256_path "$shared_profile")"
shared_resolved="$test_tmp/shared-resolved.json"
"${jq_command[@]}" -S -c --arg profile_sha "$shared_profile_sha" '
  (.body.bindings[] | select(.binding.role == "forge") |
    .binding.principal_id) =
      (.body.bindings[] | select(.binding.role == "producer") |
        .binding.principal_id) |
  .body.profile_ref.sha256 = $profile_sha |
  .body.profile_source.value_sha256 = $profile_sha
' "$resolved_file" >"$shared_resolved"
check protected-profile-separation expect_v2_error protected-profile-separation \
  E_RELATION profile-set "$shared_profile" "$shared_resolved" \
  "${manifest_files[@]}"

check registry-canonical cmp -s "$registry" \
  <("${jq_command[@]}" -S -c . "$registry")
check registry-prefix-unique "${jq_command[@]}" -e --arg generation "$generation_id" \
  'type == "array" and length == 2 and
   (map(.generation_id) | length == (unique | length)) and
   .[0].generation_id == $generation and
   .[1].parent_generation_id == $generation and
   .[0].semantic_identity == "core.contracts.v2"' "$registry"
registered_generations="$("${jq_command[@]}" -r \
  '.[].generation_id' "$registry" | LC_ALL=C sort)"
packaged_generations="$(find "$test_root/core/v2/generations" \
  -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort)"
check registry-covers-packages test \
  "$registered_generations" = "$packaged_generations"

derived_generation="g-$(printf '%s' \
  "portable-core-v2|selected-generation=$parent_generation|authorization-comment=5476938197|concern=fake-forge-materialization-contract" |
  sha256_text)"
check generation-derived test "$derived_generation" = "$generation_id"

expected_package=$'contracts.jq\ncore-ingress.sh\nmodules/profile_graph.jq\nmodules/result_facts.jq\nmodules/result_truth.jq\nmodules/schema.jq\nmodules/stage_request.jq'
actual_package="$(find "$generation_root" -type f -print |
  sed "s#^$generation_root/##" | LC_ALL=C sort)"
check package-complete test "$actual_package" = "$expected_package"
check package-no-symlinks test -z \
  "$(find "$generation_root" -type l -print -quit)"

check semantic-identity test \
  "$("${jq_command[@]}" -L "$generation_root/modules" -nr \
    'import "schema" as schema; schema::semantic_identity')" = \
  core.contracts.v2
check v1-tree-unchanged test \
  "$(git -C "$test_root" rev-parse HEAD:core/v1)" = \
  4af76e02fc8b86ead009156bf165ee700aabe7f8
check wrapper-known test \
  "$(git -C "$test_root" hash-object scripts/core-contract.sh)" = \
  18748127ead49a22717723e9860210940010d84e
check schema-major-selected grep -Fxq \
  "PORTABLE_CORE_SCHEMA_MAJOR='2'" "$wrapper"
selected_generation_id="$(sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$wrapper")"
check generation-selected "${jq_command[@]}" -e \
  --arg selected "$selected_generation_id" '.[1].generation_id == $selected' "$registry"
check wrapper-document "$wrapper" validate-document "$forge_manifest"
check wrapper-profile-set "$wrapper" validate-profile-set \
  "$profile_file" "$resolved_file" "${manifest_files[@]}"
check wrapper-stage-run "$wrapper" validate-stage-run \
  "$request_file" "$resolved_file" "$result_file"

check policy-exact "${jq_command[@]}" -L "$generation_root/modules" -e -n '
  import "schema" as schema;
  [schema::policy_table.capabilities[] |
    select(.id == "core.forge.materialize-candidate.v2")] == [{
      id:"core.forge.materialize-candidate.v2",
      role:"forge",
      argument_shape:"materialize-candidate",
      outcome_family:"change",
      permissions_by_execution:{deterministic:[
        "core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1",
        "core.perm.scratch.write.v1",
        "core.perm.target.read.v1"
      ]},
      allowed_evidence:["deterministic"],
      required_evidence:["deterministic"]
    }] and
  [schema::policy_table.permissions[] |
    select(.id == "core.perm.candidate-repository.write.v2")] == [{
      id:"core.perm.candidate-repository.write.v2",
      resource:"caller-disposable-candidate-repository",
      actions:["write"]
    }]
'
check capability-vocabulary "${jq_command[@]}" \
  -L "$generation_root/modules" -e -n '
  import "schema" as schema;
  ([schema::policy_table.capabilities[] |
      select(.id == "core.forge.materialize-candidate.v2")] +
   [schema::policy_table.permissions[] |
      select(.id == "core.perm.candidate-repository.write.v2")]) |
  tostring | ascii_downcase |
  test("authority|grant|qualification|approval|merge|push|remote|branch|credential|network|publish") | not
'

required_paths=(
  core/v2/generation-registry.json
  "core/v2/generations/$generation_id/contracts.jq"
  "core/v2/generations/$generation_id/core-ingress.sh"
  "core/v2/generations/$generation_id/modules/profile_graph.jq"
  "core/v2/generations/$generation_id/modules/result_facts.jq"
  "core/v2/generations/$generation_id/modules/result_truth.jq"
  "core/v2/generations/$generation_id/modules/schema.jq"
  "core/v2/generations/$generation_id/modules/stage_request.jq"
  scripts/test/portable-core-v2-fake-forge.test.sh
)
for required_path in "${required_paths[@]}"; do
  check "manifest-$required_path" grep -Fxq "$required_path" "$manifest"
done
check readme-inactive grep -Fq \
  'Inactive portable core v2 fake-forge contract' "$test_root/README.md"
check restore-inactive grep -Eq \
  'core/v2/.*append-only inactive generations' \
  "$test_root/RESTORE.md"
check readme-no-real-qualification grep -Fq \
  'not qualified for a real forge' "$test_root/README.md"
check restore-no-real-qualification grep -Fq \
  'not qualified for a real forge' "$test_root/RESTORE.md"

if [ "$failures" -ne 0 ]; then
  printf 'portable core v2 fake-forge: %s/%s checks passed\n' \
    "$passed" "$total" >&2
  exit 1
fi
printf 'portable core v2 fake-forge: %s/%s checks passed\n' "$passed" "$total"
