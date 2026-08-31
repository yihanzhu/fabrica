#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

profile_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
profile_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
profile_base="6ae9452848fd1bdec38aaef78efc842f5e938de3"
profile_parent_spec="c6511d96c1a5e6aed27ba2075b5add65c121f782"
profile_schema_merge="d48ecdb908a395c5205260a662db7d9d3f4c1eb4"
profile_schema_oid="fd3924d414a7d620c2bf5de919a45c2599d572ec"
profile_ingress_oid="e882b38b0106aac9142c667771f02e3107f8c52f"
profile_registry_oid="5e113105777694a280166e71d31efd19752e9562"
profile_schema_path="core/v1/generations/$profile_generation/modules/schema.jq"
profile_ingress_path="core/v1/generations/$profile_generation/core-ingress.sh"
profile_registry_path="core/v1/generation-registry.json"
profile_module_dir="$profile_root/core/v1/generations/$profile_generation/modules"
profile_module="$profile_module_dir/profile_graph.jq"
profile_fixture_dir="$profile_root/scripts/test"
profile_ledger="$profile_fixture_dir/portable-core-profile-graph-ledger.tsv"
profile_manifest="$profile_root/ci/required-files.txt"
profile_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-profile.XXXXXX")"
profile_download=""

cleanup() {
  if [ -n "$profile_download" ] && [ -f "$profile_download" ]; then
    rm -f -- "$profile_download"
  fi
  rm -rf -- "$profile_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

profile_platform="$(uname -s):$(uname -m)"
case "$profile_platform" in
  Linux:x86_64)
    profile_asset="jq-linux64"
    profile_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    profile_asset="jq-osx-amd64"
    profile_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $profile_platform" >&2
    exit 1
    ;;
esac

profile_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$profile_cache"
profile_jq="$profile_cache/$profile_asset"
if [ ! -f "$profile_jq" ] ||
   [ "$(sha256_path "$profile_jq")" != "$profile_asset_sha256" ]; then
  profile_download="$(mktemp "$profile_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$profile_asset" \
    -o "$profile_download"
  if [ "$(sha256_path "$profile_download")" != "$profile_asset_sha256" ]; then
    echo "FAIL: jq 1.6 release asset digest mismatch" >&2
    exit 1
  fi
  chmod 0555 "$profile_download"
  mv "$profile_download" "$profile_jq"
  profile_download=""
fi

profile_jq_command=("$profile_jq")
if [ "$profile_platform" = "Darwin:arm64" ]; then
  profile_jq_command=(/usr/bin/arch -x86_64 "$profile_jq")
fi

if [ "$(sha256_path "$profile_jq")" != "$profile_asset_sha256" ] ||
   [ "$("${profile_jq_command[@]}" --version)" != "jq-1.6" ]; then
  echo "FAIL: pinned jq 1.6 identity check failed" >&2
  exit 1
fi

fixture_value() {
  local expression="$1"
  "${profile_jq_command[@]}" -L "$profile_fixture_dir" -S -c -n \
    "import \"portable-core-profile-graph-fixtures\" as fixture; $expression"
}

fixture_metadata="$(fixture_value 'fixture::metadata')"

roles=(producer publisher reviewer verifier)
manifest_files=()
manifest_shas=()
for index in 0 1 2 3; do
  manifest_file="$profile_tmp/manifest-${roles[$index]}.json"
  fixture_value "fixture::manifest_docs[$index]" > "$manifest_file"
  manifest_files+=("$manifest_file")
  manifest_shas+=("$(sha256_path "$manifest_file")")
done

manifest_sha_map="$("${profile_jq_command[@]}" -n \
  --arg producer "${manifest_shas[0]}" \
  --arg publisher "${manifest_shas[1]}" \
  --arg reviewer "${manifest_shas[2]}" \
  --arg verifier "${manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"

profile_file="$profile_tmp/profile.json"
"${profile_jq_command[@]}" -L "$profile_fixture_dir" -S -c -n \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::profile_doc($manifest_shas)' > "$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$profile_tmp/resolved-profile.json"
"${profile_jq_command[@]}" -L "$profile_fixture_dir" -S -c -n \
  --slurpfile profile "$profile_file" \
  --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-profile-graph-fixtures" as fixture;
   fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > "$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

profile_graph="$profile_tmp/graph.json"
"${profile_jq_command[@]}" -S -c -n \
  --slurpfile profile "$profile_file" \
  --slurpfile resolved "$resolved_file" \
  --slurpfile m0 "${manifest_files[0]}" \
  --slurpfile m1 "${manifest_files[1]}" \
  --slurpfile m2 "${manifest_files[2]}" \
  --slurpfile m3 "${manifest_files[3]}" \
  --arg profile_sha "$profile_sha" \
  --arg resolved_sha "$resolved_sha" \
  --arg m0_sha "${manifest_shas[0]}" \
  --arg m1_sha "${manifest_shas[1]}" \
  --arg m2_sha "${manifest_shas[2]}" \
  --arg m3_sha "${manifest_shas[3]}" \
  '{profile:{content:$profile[0],sha256:$profile_sha},
    resolved:{content:$resolved[0],sha256:$resolved_sha},
    manifests:[
      {content:$m0[0],sha256:$m0_sha},
      {content:$m1[0],sha256:$m1_sha},
      {content:$m2[0],sha256:$m2_sha},
      {content:$m3[0],sha256:$m3_sha}]}' > "$profile_graph"

build_graph_with_producer_manifest() {
  local output_file="$1"
  local mutation="$2"
  local output_name="${output_file##*/}"
  local variant_manifest="$profile_tmp/$output_name.manifest.json"
  local variant_profile="$profile_tmp/$output_name.profile.json"
  local variant_resolved="$profile_tmp/$output_name.resolved.json"
  local variant_manifest_sha
  local variant_profile_sha
  local variant_resolved_sha
  local variant_sha_map

  "${profile_jq_command[@]}" -S -c "$mutation" "${manifest_files[0]}" > \
    "$variant_manifest"
  variant_manifest_sha="$(sha256_path "$variant_manifest")"
  variant_sha_map="$("${profile_jq_command[@]}" -n \
    --arg producer "$variant_manifest_sha" \
    --arg publisher "${manifest_shas[1]}" \
    --arg reviewer "${manifest_shas[2]}" \
    --arg verifier "${manifest_shas[3]}" \
    '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"
  "${profile_jq_command[@]}" -L "$profile_fixture_dir" -S -c -n \
    --argjson manifest_shas "$variant_sha_map" \
    'import "portable-core-profile-graph-fixtures" as fixture;
     fixture::profile_doc($manifest_shas)' > "$variant_profile"
  variant_profile_sha="$(sha256_path "$variant_profile")"
  "${profile_jq_command[@]}" -L "$profile_fixture_dir" -S -c -n \
    --slurpfile profile "$variant_profile" \
    --arg profile_sha "$variant_profile_sha" \
    --argjson manifest_shas "$variant_sha_map" \
    'import "portable-core-profile-graph-fixtures" as fixture;
     fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > \
    "$variant_resolved"
  variant_resolved_sha="$(sha256_path "$variant_resolved")"
  "${profile_jq_command[@]}" -S -c -n \
    --slurpfile profile "$variant_profile" \
    --slurpfile resolved "$variant_resolved" \
    --slurpfile m0 "$variant_manifest" \
    --slurpfile m1 "${manifest_files[1]}" \
    --slurpfile m2 "${manifest_files[2]}" \
    --slurpfile m3 "${manifest_files[3]}" \
    --arg profile_sha "$variant_profile_sha" \
    --arg resolved_sha "$variant_resolved_sha" \
    --arg m0_sha "$variant_manifest_sha" \
    --arg m1_sha "${manifest_shas[1]}" \
    --arg m2_sha "${manifest_shas[2]}" \
    --arg m3_sha "${manifest_shas[3]}" \
    '{profile:{content:$profile[0],sha256:$profile_sha},
      resolved:{content:$resolved[0],sha256:$resolved_sha},
      manifests:[
        {content:$m0[0],sha256:$m0_sha},
        {content:$m1[0],sha256:$m1_sha},
        {content:$m2[0],sha256:$m2_sha},
        {content:$m3[0],sha256:$m3_sha}]}' > "$output_file"
}

profile_role_offer_graph="$profile_tmp/role-offer-graph.json"
profile_capability_offer_graph="$profile_tmp/capability-offer-graph.json"
profile_execution_offer_graph="$profile_tmp/execution-offer-graph.json"
profile_permission_offer_graph="$profile_tmp/permission-offer-graph.json"
profile_tool_version_graph="$profile_tmp/tool-version-graph.json"
profile_tool_package_graph="$profile_tmp/tool-package-graph.json"
profile_tool_config_presence_graph="$profile_tmp/tool-config-presence-graph.json"
profile_tool_config_object_graph="$profile_tmp/tool-config-object-graph.json"
profile_package_graph="$profile_tmp/package-graph.json"
profile_config_contract_graph="$profile_tmp/config-contract-graph.json"
profile_superset_offer_graph="$profile_tmp/superset-offer-graph.json"
build_graph_with_producer_manifest "$profile_role_offer_graph" \
  '.body.offered_roles=["reviewer"]'
build_graph_with_producer_manifest "$profile_capability_offer_graph" \
  '.body.offered_capabilities=[]'
build_graph_with_producer_manifest "$profile_execution_offer_graph" \
  '.body.offered_execution_kinds=["deterministic"]'
build_graph_with_producer_manifest "$profile_permission_offer_graph" \
  '.body.offered_permissions=[]'
build_graph_with_producer_manifest "$profile_tool_version_graph" \
  '.body.offered_tools[0].tool_version="v2"'
build_graph_with_producer_manifest "$profile_tool_package_graph" \
  '.body.offered_tools[0].package_ref.object_id=("0"*40)'
build_graph_with_producer_manifest "$profile_tool_config_presence_graph" \
  '.body.offered_tools[0].config_ref={state:"absent"}'
build_graph_with_producer_manifest "$profile_tool_config_object_graph" \
  '.body.offered_tools[0].config_ref.value.object_id=("0"*40)'
build_graph_with_producer_manifest "$profile_package_graph" \
  '.body.package_ref.object_id=("0"*40)'
build_graph_with_producer_manifest "$profile_config_contract_graph" \
  'del(.body.config_contract_ref)'
build_graph_with_producer_manifest "$profile_superset_offer_graph" \
  '.body.offered_roles=["producer","reviewer"] |
   .body.offered_execution_kinds=["deterministic","model"] |
   .body.offered_capabilities=["core.harness.produce.v1","core.review.change.v1","core.verify.run.v1"] |
   .body.offered_permissions=["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] |
   .body.offered_tools += [(.body.offered_tools[0] | .tool_id="tool.zextra")]'

profile_extra_graph="$profile_tmp/extra-manifest-graph.json"
cp "$profile_graph" "$profile_extra_graph"
for extra_index in 1 2 3 4; do
  extra_manifest="$profile_tmp/extra-manifest-$extra_index.json"
  extra_graph_next="$profile_tmp/extra-manifest-graph-$extra_index.json"
  "${profile_jq_command[@]}" -S -c \
    --arg id "manifest.extra$extra_index" \
    '.id=$id' "${manifest_files[0]}" > "$extra_manifest"
  extra_sha="$(sha256_path "$extra_manifest")"
  "${profile_jq_command[@]}" -S -c \
    --slurpfile extra "$extra_manifest" \
    --arg sha "$extra_sha" \
    '.manifests += [{content:$extra[0],sha256:$sha}]' \
    "$profile_extra_graph" > "$extra_graph_next"
  mv "$extra_graph_next" "$profile_extra_graph"
done

profile_failures=0
profile_direct_total=0
profile_direct_passed=0
profile_cell_total=0
profile_cell_passed=0
profile_forced_total=0
profile_forced_passed=0
profile_layer_total=0
profile_layer_passed=0
profile_guard_total=0
profile_guard_passed=0
profile_seen_rules="$profile_tmp/seen-rules"
profile_seen_tests="$profile_tmp/seen-tests"
: > "$profile_seen_rules"
: > "$profile_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  profile_failures=$((profile_failures + 1))
}

mark_rule() {
  printf '%s\n' "$1" >> "$profile_seen_rules"
}

mark_test() {
  printf '%s\n' "$1" >> "$profile_seen_tests"
}

expect_expression() {
  local case_id="$1"
  local expected="$2"
  local expression="$3"
  local graph_file="${4:-$profile_graph}"
  local actual
  profile_direct_total=$((profile_direct_total + 1))
  if ! actual="$("${profile_jq_command[@]}" -L "$profile_module_dir" \
      --slurpfile graph "$graph_file" -n \
      'import "profile_graph" as profile_graph;
       $graph[0] as $g | ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    profile_direct_passed=$((profile_direct_passed + 1))
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

expect_true() {
  expect_expression "$1" true "$2" "${3:-$profile_graph}"
}

expect_false() {
  expect_expression "$1" false "$2" "${3:-$profile_graph}"
}

expect_layer() {
  local case_id="$1"
  local expected="$2"
  local expression="$3"
  local actual
  profile_layer_total=$((profile_layer_total + 1))
  if ! actual="$("${profile_jq_command[@]}" -r -L "$profile_module_dir" \
      --slurpfile graph "$profile_graph" -n \
      'import "profile_graph" as profile_graph;
       $graph[0] as $g | ('"$expression"')')"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    profile_layer_passed=$((profile_layer_passed + 1))
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

mapped_true() {
  mark_test "$1"
  expect_true "$2" "$3" "${4:-$profile_graph}"
}

mapped_false() {
  mark_test "$1"
  expect_false "$2" "$3" "${4:-$profile_graph}"
}

set_ok='profile_graph::profile_set_ok($g.profile;$g.resolved;$g.manifests)'

mapped_true portable-core-profile-graph.test.legacy-001-validate-document-manifest-producer \
  manifest-producer '$g.manifests[0].content | profile_graph::adapter_manifest_self_ok'
mapped_true portable-core-profile-graph.test.legacy-003-validate-document-manifest-verifier \
  manifest-verifier '$g.manifests[3].content | profile_graph::adapter_manifest_self_ok'
mapped_true portable-core-profile-graph.test.legacy-005-validate-document-manifest-reviewer \
  manifest-reviewer '$g.manifests[2].content | profile_graph::adapter_manifest_self_ok'
mapped_true portable-core-profile-graph.test.legacy-007-validate-document-manifest-publisher \
  manifest-publisher '$g.manifests[1].content | profile_graph::adapter_manifest_self_ok'
mark_rule portable-core-profile-graph.manifest-body

mapped_true portable-core-profile-graph.test.legacy-009-validate-document-profile \
  profile-valid '$g.profile.content | profile_graph::profile_self_ok'
mark_rule portable-core-profile-graph.profile-body
mapped_true portable-core-profile-graph.test.legacy-011-validate-document-resolved-profile \
  resolved-valid '$g.resolved.content | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.resolved-profile-self
mapped_true portable-core-profile-graph.test.legacy-017-validate-profile-set \
  graph-valid "$set_ok"
mark_rule portable-core-profile-graph.profile-set-graph

mapped_false portable-core-profile-graph.test.legacy-037-validate-profile-set-eight-manifests-boundary-4-extra-unreferenced-is-reject \
  graph-extra-manifests \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_extra_graph"
mark_rule portable-core-profile-graph.profile-set-exact-manifests

mapped_false portable-core-profile-graph.test.legacy-083-offered-roles-below-minimum \
  manifest-role-min \
  '$g.manifests[0].content | .body.offered_roles=[] | profile_graph::adapter_manifest_shape_ok'
mark_rule portable-core-profile-graph.manifest-role-count
mapped_false portable-core-profile-graph.test.legacy-085-offered-roles-unknown-enum \
  manifest-role-enum \
  '$g.manifests[0].content | .body.offered_roles=["unknown"] | profile_graph::adapter_manifest_shape_ok'
mark_rule portable-core-profile-graph.manifest-role-registry
mapped_false portable-core-profile-graph.test.legacy-087-unknown-top-level-field \
  manifest-extra-field \
  '$g.manifests[0].content | .body.extra=true | profile_graph::adapter_manifest_shape_ok'
mapped_false portable-core-profile-graph.test.legacy-089-missing-required-field \
  manifest-missing-field \
  '$g.manifests[0].content | del(.body.adapter_version) | profile_graph::adapter_manifest_shape_ok'
mapped_false portable-core-profile-graph.test.legacy-091-duplicate-tool-id-in-offered-tools \
  manifest-duplicate-tool \
  '$g.manifests[0].content | .body.offered_tools += [.body.offered_tools[0]] | profile_graph::adapter_manifest_shape_ok'
mark_rule portable-core-profile-graph.manifest-tool-set

mapped_false portable-core-profile-graph.test.legacy-099-below-4-binding-minimum \
  profile-binding-min \
  '$g.profile.content | .body.bindings=(.body.bindings[0:3]) | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.profile-binding-count
mapped_false portable-core-profile-graph.test.legacy-101-producer-requesting-verifiers-capability \
  profile-capability-closure \
  '$g.profile.content | .body.bindings |= map(if .role=="producer" then .requested_capabilities=["core.verify.run.v1"] else . end) | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.binding-capability-closure
expect_false profile-permissions-missing \
  '$g.profile.content | .body.bindings |= map(if .role=="producer" then .requested_permissions=["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1"] else . end) | profile_graph::profile_shape_ok'
expect_false profile-permissions-extra \
  '$g.profile.content | .body.bindings |= map(if .role=="producer" then .requested_permissions=["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] else . end) | profile_graph::profile_shape_ok'
mapped_false portable-core-profile-graph.test.legacy-103-protected-role-missing-authority-ref \
  protected-authority-required \
  '$g.profile.content | .body.bindings |= map(if .role=="publisher" then del(.authority_ref) else . end) | profile_graph::profile_self_ok'
mark_rule portable-core-profile-graph.protected-authority-required
mapped_false portable-core-profile-graph.test.legacy-105-two-protected-roles-share-one-authority-scope \
  protected-authority-distinct \
  '$g.profile.content | (.body.bindings[]|select(.role=="producer")|.authority_ref.scope_sha256) as $shared | .body.bindings |= map(if .role=="reviewer" then .authority_ref.scope_sha256=$shared else . end) | profile_graph::profile_self_ok'
mark_rule portable-core-profile-graph.protected-authority-distinct
mapped_false portable-core-profile-graph.test.legacy-107-two-protected-roles-share-one-principal-id \
  protected-principal-distinct \
  '$g.profile.content | (.body.bindings[]|select(.role=="producer")|.principal_id) as $shared | .body.bindings |= map(if .role=="reviewer" then .principal_id=$shared else . end) | profile_graph::profile_self_ok'
mark_rule portable-core-profile-graph.protected-principal-distinct
mapped_false portable-core-profile-graph.test.legacy-109-verifier-forced-to-model-execution \
  verifier-model \
  '$g.profile.content | .body.bindings |= map(if .role=="verifier" then .execution_kind="model" | .model_request={provider_id:"p",model_id:"m",effort_id:"e"} | .prompt_ref=.package_ref else . end) | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.binding-execution-kind
mapped_false portable-core-profile-graph.test.legacy-111-deterministic-binding-with-non-empty-skill-refs \
  deterministic-skills \
  '$g.profile.content | .body.bindings |= map(if .role=="publisher" then .skill_refs=[.package_ref] else . end) | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.deterministic-skill-empty
mapped_false portable-core-profile-graph.test.legacy-113-duplicate-binding-id \
  binding-id-duplicate \
  '$g.profile.content | .body.bindings[1].binding_id=.body.bindings[0].binding_id | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.binding-id-unique
mapped_false portable-core-profile-graph.test.legacy-115-bindings-not-in-canonical-binding-id-sorted-order \
  binding-id-order \
  '$g.profile.content | .body.bindings|=reverse | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.binding-id-order
mapped_true portable-core-profile-graph.test.legacy-117-producer-allowed-to-use-model-execution \
  producer-model \
  '$g.profile.content | .body.bindings[] | select(.role=="producer") | profile_graph::profile_binding_ok'
expect_true producer-deterministic \
  '$g.profile.content.body.bindings[] | select(.role=="producer") | .execution_kind="deterministic" | del(.model_request,.prompt_ref) | .skill_refs=[] | .requested_permissions=["core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] | profile_graph::profile_binding_ok'
expect_true reviewer-deterministic \
  '$g.profile.content.body.bindings[] | select(.role=="reviewer") | .execution_kind="deterministic" | del(.model_request,.prompt_ref) | .skill_refs=[] | .requested_permissions=["core.perm.evidence.write.v1","core.perm.target.read.v1"] | profile_graph::profile_binding_ok'
mapped_false portable-core-profile-graph.test.legacy-119-dormant-role-publisher-forced-to-model-execution \
  publisher-model \
  '$g.profile.content | .body.bindings |= map(if .role=="publisher" then .execution_kind="model" | .model_request={provider_id:"p",model_id:"m",effort_id:"e"} | .prompt_ref=.package_ref else . end) | profile_graph::profile_shape_ok'
for dormant_role in publisher forge ci execution identity; do
  expect_false "dormant-$dormant_role-model" \
    '$g.profile.content.body.bindings[1] | .role="'"$dormant_role"'" | .execution_kind="model" | .model_request={provider_id:"p",model_id:"m",effort_id:"e"} | .prompt_ref=.package_ref | profile_graph::profile_binding_ok'
done
expect_true optional-role-complete-profile \
  '($g.profile.content.body.bindings[1]) as $seed | $g.profile.content | .body.bindings += (["ci","execution","forge","identity"] | map(. as $role | $seed | .binding_id=("binding.optional."+$role) | .role=$role | .adapter_instance_id=("instance."+$role) | .principal_id=("principal."+$role) | .execution_boundary_id=("boundary."+$role))) | .body.bindings|=sort_by(.binding_id) | profile_graph::profile_self_ok'
expect_false optional-role-duplicate \
  '($g.profile.content.body.bindings[1]) as $seed | $g.profile.content | .body.bindings += (["ci","execution","forge","identity"] | map(. as $role | $seed | .binding_id=("binding.optional."+$role) | .role=$role | .adapter_instance_id=("instance."+$role) | .principal_id=("principal."+$role) | .execution_boundary_id=("boundary."+$role))) | .body.bindings|=sort_by(.binding_id) | .body.bindings |= map(if .role=="identity" then .role="forge" else . end) | profile_graph::profile_self_ok'

mapped_false portable-core-profile-graph.test.legacy-121-missing-selection-ref \
  resolved-selection-missing \
  '$g.resolved.content | del(.body.selection_ref) | profile_graph::resolved_profile_shape_ok'
mapped_false portable-core-profile-graph.test.legacy-123-selection-ref-carries-the-wrong-purpose \
  resolved-selection-purpose \
  '$g.resolved.content | .body.selection_ref.purpose="grant" | profile_graph::resolved_profile_shape_ok'
mark_rule portable-core-profile-graph.resolved-profile-body
mapped_false portable-core-profile-graph.test.legacy-125-resolved-bindings-below-the-4-minimum \
  resolved-binding-min \
  '$g.resolved.content | .body.bindings=(.body.bindings[0:3]) | profile_graph::resolved_profile_shape_ok'
mark_rule portable-core-profile-graph.resolved-binding-count
mapped_false portable-core-profile-graph.test.legacy-129-duplicate-tool-id-in-tool-sources \
  resolved-tool-duplicate \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .tool_sources += [.tool_sources[0]] else . end) | profile_graph::resolved_profile_shape_ok'
mark_rule portable-core-profile-graph.resolved-tool-source-set

mapped_false portable-core-profile-graph.test.legacy-183-resolved-package-source-does-not-match-the-bindings-package-ref \
  resolved-package-projection \
  '$g.resolved.content | .body.bindings[0].package_source.source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.resolved-package-source
expect_false resolved-adapter-id-projection \
  '$g.resolved.content | .body.bindings[0].adapter_implementation.id="manifest.wrong" | profile_graph::resolved_profile_self_ok'
mapped_false portable-core-profile-graph.test.legacy-185-resolved-adapter-implementation-version-does-not-match-the-manifest \
  graph-manifest-version \
  '($g.resolved | .content.body.bindings[0].adapter_implementation.version="v2") as $resolved | profile_graph::profile_set_graph_ok($g.profile;$resolved;$g.manifests)'
mark_rule portable-core-profile-graph.profile-set-manifest-version
mapped_false portable-core-profile-graph.test.legacy-187-resolved-bindings-do-not-cover-the-same-binding-id-set-as-the-profile \
  graph-binding-identities \
  '($g.resolved | .content.body.bindings[-1].binding.binding_id="binding.zzz") as $resolved | profile_graph::profile_set_graph_ok($g.profile;$resolved;$g.manifests)'
mark_rule portable-core-profile-graph.profile-set-binding-identity
mapped_false portable-core-profile-graph.test.legacy-189-mutated-profiles-own-digest-no-longer-matches-the-resolved-profiles-profile \
  refs-profile-bytes-moved \
  '($g.profile | .sha256=("0"*64)) as $profile | profile_graph::profile_set_refs_ok($profile;$g.resolved;$g.manifests)'
mark_rule portable-core-profile-graph.profile-set-profile-ref
mapped_false portable-core-profile-graph.test.legacy-191-a-referenced-manifest-is-simply-not-supplied-profile-resolved-digests-untouc \
  graph-manifest-missing \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests[1:])'
mapped_false portable-core-profile-graph.test.legacy-193-resolved-profile-ref-digest-does-not-match-the-supplied-profile \
  refs-resolved-profile-digest \
  '($g.resolved | .content.body.profile_ref.sha256=("0"*64)) as $resolved | profile_graph::profile_set_refs_ok($g.profile;$resolved;$g.manifests)'
mapped_false portable-core-profile-graph.test.legacy-195-two-supplied-manifests-share-one-document-id \
  refs-manifest-id-duplicate \
  '($g.manifests | .[1].content.id=.[0].content.id) as $manifests | profile_graph::profile_set_refs_ok($g.profile;$g.resolved;$manifests)'
mark_rule portable-core-profile-graph.profile-set-manifest-id-unique
mapped_false portable-core-profile-graph.test.legacy-197-resolved-config-source-present-without-a-config-ref-on-the-binding \
  resolved-config-projection \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="publisher" then .config_source={state:"present",value:.package_source} else . end) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.profile-set-config-source
expect_false resolved-requested-tool-missing-source \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .tool_sources=[] else . end) | profile_graph::resolved_profile_self_ok'
expect_false resolved-config-source-missing \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .config_source={state:"absent"} else . end) | profile_graph::resolved_profile_self_ok'
expect_false resolved-prompt-source-missing \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .prompt_source={state:"absent"} else . end) | profile_graph::resolved_profile_self_ok'
expect_false resolved-tool-config-source-missing \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .tool_sources[0].config_source={state:"absent"} else . end) | profile_graph::resolved_profile_self_ok'
expect_false resolved-skill-source-missing \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .skill_sources=[] else . end) | profile_graph::resolved_profile_self_ok'
mapped_false portable-core-profile-graph.test.legacy-199-resolved-profile-source-digest-does-not-match-the-supplied-profiles-real-byt \
  resolved-profile-source-digest \
  '$g.resolved.content | .body.profile_source.value_sha256=("0"*64) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.profile-set-source-digests
mapped_false portable-core-profile-graph.test.legacy-201-resolved-manifest-source-digest-does-not-match-the-supplied-manifests-real-b \
  resolved-manifest-source-digest \
  '$g.resolved.content | .body.bindings[0].manifest_source.value_sha256=("0"*64) | profile_graph::resolved_profile_self_ok'
mapped_false portable-core-profile-graph.test.legacy-203-manifest-does-not-offer-the-bindings-role \
  graph-role-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_role_offer_graph"
mark_rule portable-core-profile-graph.profile-set-role-offer
mapped_false portable-core-profile-graph.test.legacy-205-manifest-does-not-offer-the-bindings-requested-capability \
  graph-capability-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_capability_offer_graph"
mark_rule portable-core-profile-graph.profile-set-capability-offer
mapped_false portable-core-profile-graph.test.legacy-207-two-bindings-claim-different-digests-for-the-same-source-git-object \
  source-claim-conflict \
  '$g.resolved.content.body | .bindings[1].package_source.source=.bindings[0].package_source.source | profile_graph::source_claims_agree(.)'
mark_rule portable-core-profile-graph.source-claim-unique
expect_false source-claim-same-digest-different-format \
  '$g.resolved.content.body | .bindings[1].package_source.source=.bindings[0].package_source.source | .bindings[1].package_source.value_sha256=.bindings[0].package_source.value_sha256 | .bindings[1].package_source.value_format="canonical-json" | profile_graph::source_claims_agree(.)'
expect_false source-claim-profile-manifest-collision \
  '$g.resolved.content.body | .bindings[0].manifest_source.source=.profile_source.source | profile_graph::source_claims_agree(.)'
expect_false source-claim-skill-tool-collision \
  '$g.resolved.content.body | .bindings[0].tool_sources[0].package_source.source=.bindings[0].skill_sources[0].source | profile_graph::source_claims_agree(.)'
expect_true source-claim-consistent-cross-category-reuse \
  '$g.resolved.content.body | .bindings[0].tool_sources[0].package_source=.bindings[0].skill_sources[0] | profile_graph::source_claims_agree(.)'

mapped_false portable-core-profile-graph.test.legacy-257-embedded-producer-binding-with-emptied-capability-closure \
  resolved-embedded-capability \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end) | profile_graph::resolved_profile_self_ok'
mapped_false portable-core-profile-graph.test.legacy-259-two-embedded-protected-role-bindings-share-one-principal-id \
  resolved-embedded-principal \
  '$g.resolved.content | (.body.bindings[]|select(.binding.role=="producer")|.binding.principal_id) as $shared | .body.bindings |= map(if .binding.role=="reviewer" then .binding.principal_id=$shared else . end) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.resolved-binding-invariants
mapped_false portable-core-profile-graph.test.legacy-263-stage-run-approves-an-operation-its-embedded-binding-never-requested \
  stage-resolved-capability-route \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end) | profile_graph::resolved_profile_self_ok'

mapped_false portable-core-profile-graph.test.binding-outside-manifest-offer-rejected \
  review-binding-manifest-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_permission_offer_graph"
mark_rule portable-core-profile-graph.binding-manifest-offer-closure
mapped_false portable-core-profile-graph.test.resolved-source-digest-mismatch-rejected \
  review-source-document-digest \
  '$g.resolved.content | .body.bindings[0].manifest_source.value_sha256=("0"*64) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.resolved-source-document-digests
mapped_false portable-core-profile-graph.test.unreferenced-manifest-rejected \
  review-unreferenced-manifest \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_extra_graph"
mapped_false portable-core-profile-graph.test.conflicting-source-claim-rejected \
  review-source-single-claim \
  '$g.resolved.content.body | .bindings[1].package_source.source=.bindings[0].package_source.source | profile_graph::source_claims_agree(.)'
mark_rule portable-core-profile-graph.resolved-source-single-claim
mapped_false portable-core-profile-graph.test.dormant-model-binding-rejected \
  review-dormant-deterministic \
  '$g.profile.content | .body.bindings |= map(if .role=="publisher" then .execution_kind="model" | .model_request={provider_id:"p",model_id:"m",effort_id:"e"} | .prompt_ref=.package_ref else . end) | profile_graph::profile_shape_ok'
mark_rule portable-core-profile-graph.dormant-binding-deterministic
mapped_false portable-core-profile-graph.test.resolved-binding-invariant-bypass-rejected \
  review-resolved-binding-invariant \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end) | profile_graph::resolved_profile_self_ok'
mapped_false portable-core-profile-graph.test.resolved-source-projection-standalone-route \
  review-resolved-source-projection \
  '$g.resolved.content | .body.bindings[0].prompt_source.value.source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
mark_rule portable-core-profile-graph.resolved-source-self-projections

expect_true resolved-embedded-field-self-valid \
  '$g.resolved.content | .body.bindings[0].binding.adapter_instance_id="instance.changed" | profile_graph::resolved_profile_self_ok'
expect_false graph-full-embedded-binding-equality \
  '($g.resolved | .content.body.bindings[0].binding.adapter_instance_id="instance.changed") as $resolved | profile_graph::profile_set_graph_ok($g.profile;$resolved;$g.manifests)'

rebuilt_graphs=(
  "$profile_role_offer_graph"
  "$profile_capability_offer_graph"
  "$profile_execution_offer_graph"
  "$profile_permission_offer_graph"
  "$profile_tool_version_graph"
  "$profile_tool_package_graph"
  "$profile_tool_config_presence_graph"
  "$profile_tool_config_object_graph"
  "$profile_package_graph"
  "$profile_config_contract_graph"
  "$profile_extra_graph"
  "$profile_superset_offer_graph"
)
for rebuilt_index in "${!rebuilt_graphs[@]}"; do
  expect_true "rebuilt-$rebuilt_index-refs" \
    'profile_graph::profile_set_refs_ok($g.profile;$g.resolved;$g.manifests)' \
    "${rebuilt_graphs[$rebuilt_index]}"
  expect_true "rebuilt-$rebuilt_index-self-checks" \
    '($g.profile.content|profile_graph::profile_self_ok) and ($g.resolved.content|profile_graph::resolved_profile_self_ok) and all($g.manifests[].content;profile_graph::adapter_manifest_self_ok)' \
    "${rebuilt_graphs[$rebuilt_index]}"
done

expect_false graph-execution-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_execution_offer_graph"
expect_false graph-full-tool-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_tool_version_graph"
expect_false graph-full-tool-package-offer \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_tool_package_graph"
expect_false graph-full-tool-config-presence \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_tool_config_presence_graph"
expect_false graph-full-tool-config-object \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_tool_config_object_graph"
expect_false graph-package-equality \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_package_graph"
expect_false graph-config-contract \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_config_contract_graph"
expect_true graph-offer-superset \
  'profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests)' \
  "$profile_superset_offer_graph"
expect_false resolved-prompt-projection \
  '$g.resolved.content | .body.bindings[0].prompt_source.value.source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
expect_false resolved-skill-projection \
  '$g.resolved.content | .body.bindings[0].skill_sources[0].source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
expect_false resolved-tool-package-projection \
  '$g.resolved.content | .body.bindings[0].tool_sources[0].package_source.source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
expect_false resolved-tool-config-projection \
  '$g.resolved.content | .body.bindings[0].tool_sources[0].config_source.value.source.object_id=("0"*40) | profile_graph::resolved_profile_self_ok'
expect_false protected-instance-distinct \
  '$g.profile.content | (.body.bindings[0].adapter_instance_id) as $shared | .body.bindings[1].adapter_instance_id=$shared | profile_graph::profile_self_ok'
expect_false protected-boundary-distinct \
  '$g.profile.content | (.body.bindings[0].execution_boundary_id) as $shared | .body.bindings[1].execution_boundary_id=$shared | profile_graph::profile_self_ok'
expect_false protected-role-complete \
  '$g.profile.content | .body.bindings[1].role="forge" | profile_graph::profile_self_ok'
mark_rule portable-core-profile-graph.protected-role-separation

expect_true manifest-role-max \
  '$g.manifests[0].content | .body.offered_roles=["ci","execution","forge","identity","producer","publisher","reviewer","verifier"] | profile_graph::adapter_manifest_shape_ok'
expect_false manifest-role-one-over \
  '$g.manifests[0].content | .body.offered_roles=["ci","execution","forge","identity","producer","producer","publisher","reviewer","verifier"] | profile_graph::adapter_manifest_shape_ok'
expect_true manifest-execution-max \
  '$g.manifests[0].content | .body.offered_execution_kinds=["deterministic","model"] | profile_graph::adapter_manifest_shape_ok'
expect_false manifest-execution-one-over \
  '$g.manifests[0].content | .body.offered_execution_kinds=["deterministic","model","model"] | profile_graph::adapter_manifest_shape_ok'
expect_true manifest-capability-max \
  '$g.manifests[0].content | .body.offered_capabilities=["core.harness.produce.v1","core.review.change.v1","core.verify.run.v1"] | profile_graph::adapter_manifest_shape_ok'
expect_false manifest-capability-one-over \
  '$g.manifests[0].content | .body.offered_capabilities=["core.harness.produce.v1","core.review.change.v1","core.verify.run.v1","core.verify.run.v1"] | profile_graph::adapter_manifest_shape_ok'
expect_true manifest-permission-max \
  '$g.manifests[0].content | .body.offered_permissions=["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"] | profile_graph::adapter_manifest_shape_ok'
expect_false manifest-permission-one-over \
  '$g.manifests[0].content | .body.offered_permissions=["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1","core.perm.target.read.v1"] | profile_graph::adapter_manifest_shape_ok'
expect_true manifest-tool-max \
  '$g.manifests[0].content | .body.offered_tools=([range(1;33) as $i | (.body.offered_tools[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::adapter_manifest_shape_ok'
expect_false manifest-tool-one-over \
  '$g.manifests[0].content | .body.offered_tools=([range(1;34) as $i | (.body.offered_tools[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::adapter_manifest_shape_ok'
expect_true profile-binding-max \
  '$g.profile.content | .body.bindings += [range(1;5) as $i | (.body.bindings[1] | .binding_id=("binding.x"+("x"*$i)))] | .body.bindings|=sort_by(.binding_id) | profile_graph::profile_shape_ok'
expect_false profile-binding-one-over \
  '$g.profile.content | .body.bindings += [range(1;6) as $i | (.body.bindings[1] | .binding_id=("binding.x"+("x"*$i)))] | .body.bindings|=sort_by(.binding_id) | profile_graph::profile_shape_ok'
expect_true profile-skill-max \
  '$g.profile.content | .body.bindings[0].skill_refs=([range(1;33) as $i | (.body.bindings[0].skill_refs[0] | .location.value=("skills/"+("x"*$i)))] | sort_by(.location.value)) | profile_graph::profile_shape_ok'
expect_false profile-skill-one-over \
  '$g.profile.content | .body.bindings[0].skill_refs=([range(1;34) as $i | (.body.bindings[0].skill_refs[0] | .location.value=("skills/"+("x"*$i)))] | sort_by(.location.value)) | profile_graph::profile_shape_ok'
expect_true profile-tool-max \
  '$g.profile.content | .body.bindings[0].requested_tools=([range(1;33) as $i | (.body.bindings[0].requested_tools[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::profile_shape_ok'
expect_false profile-tool-one-over \
  '$g.profile.content | .body.bindings[0].requested_tools=([range(1;34) as $i | (.body.bindings[0].requested_tools[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::profile_shape_ok'
expect_true resolved-binding-max \
  '$g.resolved.content | .body.bindings += [range(1;5) as $i | (.body.bindings[1] | .binding.binding_id=("binding.x"+("x"*$i)))] | .body.bindings|=sort_by(.binding.binding_id) | profile_graph::resolved_profile_shape_ok'
expect_false resolved-binding-one-over \
  '$g.resolved.content | .body.bindings += [range(1;6) as $i | (.body.bindings[1] | .binding.binding_id=("binding.x"+("x"*$i)))] | .body.bindings|=sort_by(.binding.binding_id) | profile_graph::resolved_profile_shape_ok'
expect_true resolved-skill-max \
  '$g.resolved.content | .body.bindings[0].skill_sources=([range(1;33) as $i | (.body.bindings[0].skill_sources[0] | .source.location.value=("skills/"+("x"*$i)))] | sort_by(.source.location.value)) | profile_graph::resolved_profile_shape_ok'
expect_false resolved-skill-one-over \
  '$g.resolved.content | .body.bindings[0].skill_sources=([range(1;34) as $i | (.body.bindings[0].skill_sources[0] | .source.location.value=("skills/"+("x"*$i)))] | sort_by(.source.location.value)) | profile_graph::resolved_profile_shape_ok'
expect_true resolved-tool-max \
  '$g.resolved.content | .body.bindings[0].tool_sources=([range(1;33) as $i | (.body.bindings[0].tool_sources[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::resolved_profile_shape_ok'
expect_false resolved-tool-one-over \
  '$g.resolved.content | .body.bindings[0].tool_sources=([range(1;34) as $i | (.body.bindings[0].tool_sources[0] | .tool_id=("tool."+("x"*$i)))] | sort_by(.tool_id)) | profile_graph::resolved_profile_shape_ok'

expect_layer layer-shape E_SHAPE \
  '$g.profile.content | .body.bindings[0].requested_capabilities=["core.verify.run.v1"] | if profile_graph::document_shape_ok then "OK" else "E_SHAPE" end'
expect_layer layer-self-relation E_RELATION \
  '$g.profile.content | del(.body.bindings[1].authority_ref) | if (profile_graph::document_shape_ok|not) then "E_SHAPE" elif profile_graph::document_self_ok then "OK" else "E_RELATION" end'
expect_layer layer-cross-ref E_REF \
  '($g.profile | .sha256=("0"*64)) as $profile | if profile_graph::profile_set_refs_ok($profile;$g.resolved;$g.manifests) then "OK" else "E_REF" end'
expect_layer layer-cross-relation E_RELATION \
  'if (profile_graph::profile_set_refs_ok($g.profile;$g.resolved;$g.manifests[1:])|not) then "E_REF" elif profile_graph::profile_set_graph_ok($g.profile;$g.resolved;$g.manifests[1:]) then "OK" else "E_RELATION" end'
expect_layer layer-resolved-embedded-capability E_RELATION \
  '$g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end) | if (profile_graph::document_shape_ok|not) then "E_SHAPE" elif profile_graph::document_self_ok then "OK" else "E_RELATION" end'

route_case() {
  local case_id="$1"
  local expected="$2"
  local expression="$3"
  local class="$4"
  local actual
  if [ "$class" = cell ]; then
    profile_cell_total=$((profile_cell_total + 1))
  else
    profile_forced_total=$((profile_forced_total + 1))
  fi
  if ! actual="$("${profile_jq_command[@]}" -L "$profile_module_dir" \
      --slurpfile graph "$profile_graph" -n \
      'import "profile_graph" as profile_graph;
       def route_document($document):
         $document | profile_graph::document_self_ok;
       def route_profile_set($profile;$resolved;$manifests):
         all($manifests[].content;profile_graph::adapter_manifest_self_ok) and
         ($profile.content|profile_graph::profile_self_ok) and
         ($resolved.content|profile_graph::resolved_profile_self_ok) and
         profile_graph::profile_set_refs_ok($profile;$resolved;$manifests) and
         profile_graph::profile_set_graph_ok($profile;$resolved;$manifests);
       def route_stage_run($resolved):
         $resolved.content | profile_graph::resolved_profile_self_ok;
       $graph[0] as $g | ('"$expression"')')"; then
    fail_case "$case_id raised a jq route error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    if [ "$class" = cell ]; then
      profile_cell_passed=$((profile_cell_passed + 1))
    else
      profile_forced_passed=$((profile_forced_passed + 1))
    fi
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

route_case cell-document-manifest true \
  'route_document($g.manifests[0].content)' cell
route_case cell-profile-set-manifest true \
  'route_profile_set($g.profile;$g.resolved;$g.manifests)' cell
route_case cell-document-profile true \
  'route_document($g.profile.content)' cell
route_case cell-profile-set-profile true \
  'route_profile_set($g.profile;$g.resolved;$g.manifests)' cell
route_case cell-document-resolved true \
  'route_document($g.resolved.content)' cell
route_case cell-profile-set-resolved true \
  'route_profile_set($g.profile;$g.resolved;$g.manifests)' cell
route_case cell-stage-run-resolved true \
  'route_stage_run($g.resolved)' cell
route_case cell-profile-set-graph true \
  'route_profile_set($g.profile;$g.resolved;$g.manifests)' cell

route_case forced-document-manifest false \
  'route_document($g.manifests[0].content | .body.extra=true)' forced
route_case forced-profile-set-manifest false \
  'route_profile_set($g.profile;$g.resolved;($g.manifests | .[0].content.body.extra=true))' forced
route_case forced-document-profile false \
  'route_document($g.profile.content | .body.extra=true)' forced
route_case forced-profile-set-profile false \
  'route_profile_set(($g.profile | .content.body.extra=true);$g.resolved;$g.manifests)' forced
route_case forced-document-resolved false \
  'route_document($g.resolved.content | .body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end))' forced
route_case forced-profile-set-resolved false \
  'route_profile_set($g.profile;($g.resolved | .content.body.bindings[0].package_source.source.object_id=("0"*40));$g.manifests)' forced
route_case forced-stage-run-resolved false \
  'route_stage_run($g.resolved | .content.body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end))' forced
route_case forced-profile-set-graph false \
  'route_profile_set($g.profile;$g.resolved;$g.manifests[1:])' forced
mark_rule portable-core-profile-graph.document-routes
mark_rule portable-core-profile-graph.profile-set-route
mark_rule portable-core-profile-graph.stage-run-resolved-route
mark_test portable-core-profile-graph.test.legacy-261-resolved-profile-self-forced-route-document
mark_test portable-core-profile-graph.test.legacy-265-resolved-profile-self-forced-route-stage-run

profile_import_guard_ok() {
  local candidate="$1"
  [ "$(head -n 1 "$candidate")" = 'import "schema" as schema;' ] &&
    [ "$(grep -Fxc 'import "schema" as schema;' "$candidate")" -eq 1 ] &&
    ! tail -n +2 "$candidate" |
      grep -Eq '(^|[^a-zA-Z0-9_])(import|include|module)([^a-zA-Z0-9_]|$)' &&
    ! grep -Eq 'search[[:space:]]*:|import[[:space:]]*\"[^\"]+\"[[:space:]]+as[[:space:]]+[^;]+[[:space:]]+\{' "$candidate"
}

profile_guard_total=$((profile_guard_total + 1))
if profile_import_guard_ok "$profile_module"; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "fixed schema-only import"
fi

for directive_case in compact-import multiline-import compact-include metadata-import escaped-import module-directive; do
  directive_file="$profile_tmp/$directive_case.jq"
  cp "$profile_module" "$directive_file"
  case "$directive_case" in
    compact-import) printf '%s\n' 'import"evil"as evil;' >> "$directive_file" ;;
    multiline-import) printf '%s\n' 'import' ' "evil"' ' as evil;' >> "$directive_file" ;;
    compact-include) printf '%s\n' 'include"evil";' >> "$directive_file" ;;
    metadata-import) printf '%s\n' 'import "evil" as evil {search:"."};' >> "$directive_file" ;;
    escaped-import) printf '%s\n' 'import"ev\u0069l"as evil;' >> "$directive_file" ;;
    module-directive) printf '%s\n' 'module {name:"evil"};' >> "$directive_file" ;;
  esac
  profile_guard_total=$((profile_guard_total + 1))
  if ! profile_import_guard_ok "$directive_file"; then
    profile_guard_passed=$((profile_guard_passed + 1))
  else
    fail_case "fixed import guard accepted $directive_case"
  fi
done
mark_rule portable-core-profile-graph.fixed-schema-import

current_blob_ok() {
  local repo="$1" path="$2" expected_oid="$3" mode type oid actual_path
  IFS=$' \t' read -r mode type oid actual_path < <(git -C "$repo" ls-tree HEAD -- "$path") || return 1
  [ "$mode" = 100644 ] && [ "$type" = blob ] &&
    [ "$oid" = "$expected_oid" ] && [ "$actual_path" = "$path" ]
}

registry_prefix_ok() {
  local repo="$1" path="$2" prefix_oid="$3" current_oid="$4" proof_id="$5"
  local canonical="$profile_tmp/registry-$proof_id.canonical"
  local prefix="$profile_tmp/registry-$proof_id.prefix"
  current_blob_ok "$repo" "$path" "$current_oid" &&
    "${profile_jq_command[@]}" -S -c . "$repo/$path" > "$canonical" &&
    cmp -s "$repo/$path" "$canonical" &&
    "${profile_jq_command[@]}" -S -c '.[0:1]' "$repo/$path" > "$prefix" &&
    [ "$(git hash-object "$prefix")" = "$prefix_oid" ] &&
    "${profile_jq_command[@]}" -e '
      length >= 1 and
      all(.[];
        (keys | sort) ==
          ["generation_id","parent_plan_merge_commit","parent_spec_blob"] and
        (.generation_id | test("\\Ag-[0-9a-f]{64}\\z")) and
        (.parent_spec_blob | test("\\A([0-9a-f]{40}|[0-9a-f]{64})\\z")) and
        (.parent_plan_merge_commit |
          test("\\A([0-9a-f]{40}|[0-9a-f]{64})\\z"))) and
      (map(.generation_id) | length) ==
        (map(.generation_id) | unique | length)
    ' "$repo/$path" >/dev/null
}

profile_registry_current_oid="$(
  git -C "$profile_root" hash-object "$profile_registry_path"
)"

profile_guard_total=$((profile_guard_total + 1))
if current_blob_ok "$profile_root" "$profile_schema_path" "$profile_schema_oid" &&
   registry_prefix_ok "$profile_root" "$profile_registry_path" \
     "$profile_registry_oid" "$profile_registry_current_oid" current; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "schema G3 dependency pin"
fi
mark_rule portable-core-profile-graph.schema-dependency-pin

profile_guard_total=$((profile_guard_total + 1))
if current_blob_ok "$profile_root" "$profile_ingress_path" "$profile_ingress_oid"; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "ingress serial predecessor receipt"
fi
mark_rule portable-core-profile-graph.serial-predecessor-receipt

profile_guard_total=$((profile_guard_total + 1))
if [ "$("${profile_jq_command[@]}" -r '.construction_base' <<< "$fixture_metadata")" = "$profile_base" ] &&
   [ "$("${profile_jq_command[@]}" -r '.generation_id' <<< "$fixture_metadata")" = "$profile_generation" ] &&
   [ "$("${profile_jq_command[@]}" -r '.parent_spec_blob' <<< "$fixture_metadata")" = "$profile_parent_spec" ] &&
   [ "$("${profile_jq_command[@]}" -r '.schema_export_oid' <<< "$fixture_metadata")" = "$profile_schema_oid" ] &&
   [ "$("${profile_jq_command[@]}" -r '.schema_g3_comment' <<< "$fixture_metadata")" -eq 5466181650 ] &&
   [ "$("${profile_jq_command[@]}" -r '.schema_merge_commit' <<< "$fixture_metadata")" = "$profile_schema_merge" ] &&
   [ "$("${profile_jq_command[@]}" -r '.ingress_export_oid' <<< "$fixture_metadata")" = "$profile_ingress_oid" ] &&
   [ "$("${profile_jq_command[@]}" -r '.ingress_g3_comment' <<< "$fixture_metadata")" -eq 5468279667 ] &&
   [ "$("${profile_jq_command[@]}" -r '.registry_oid' <<< "$fixture_metadata")" = "$profile_registry_oid" ]; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "fixture identity and predecessor record"
fi

shallow_repo="$profile_tmp/shallow-checkout"
git -c init.defaultObjectFormat=sha1 init -q --object-format=sha1 --template= -b main "$shallow_repo"
mkdir -p "$shallow_repo/$(dirname "$profile_schema_path")"
cp "$profile_root/$profile_schema_path" "$shallow_repo/$profile_schema_path"
cp "$profile_root/$profile_ingress_path" "$shallow_repo/$profile_ingress_path"
cp "$profile_root/$profile_registry_path" "$shallow_repo/$profile_registry_path"
GIT_ATTR_NOSYSTEM=1 git -C "$shallow_repo" -c core.attributesFile=/dev/null -c core.autocrlf=false add .
git -C "$shallow_repo" -c core.hooksPath=/dev/null -c user.name=proof -c user.email=proof@example.invalid -c commit.gpgSign=false commit -qm tip
printf '%s\n' "$(git -C "$shallow_repo" rev-parse HEAD)" > "$shallow_repo/.git/shallow"
profile_guard_total=$((profile_guard_total + 1))
if [ "$(git -C "$shallow_repo" rev-parse --is-shallow-repository)" = true ] &&
   ! git -C "$shallow_repo" cat-file -e "$profile_schema_merge^{commit}" 2>/dev/null &&
   current_blob_ok "$shallow_repo" "$profile_schema_path" "$profile_schema_oid" &&
   current_blob_ok "$shallow_repo" "$profile_ingress_path" "$profile_ingress_oid" &&
   registry_prefix_ok "$shallow_repo" "$profile_registry_path" \
     "$profile_registry_oid" "$profile_registry_current_oid" shallow; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "history-absent dependency proof"
fi

generation_files="$profile_tmp/generation-files"
find "$profile_root/core/v1/generations/$profile_generation" -type f -print |
  sed "s#^$profile_root/##" | LC_ALL=C sort > "$generation_files"

private_generation_path_ok() {
  case "$1" in
    "core/v1/generations/$profile_generation/core-ingress.sh"|\
    "core/v1/generations/$profile_generation/contracts.jq"|\
    "core/v1/generations/$profile_generation/modules/schema.jq"|\
    "core/v1/generations/$profile_generation/modules/profile_graph.jq"|\
    "core/v1/generations/$profile_generation/modules/stage_request.jq"|\
    "core/v1/generations/$profile_generation/modules/result_facts.jq"|\
    "core/v1/generations/$profile_generation/modules/result_truth.jq") return 0 ;;
    *) return 1 ;;
  esac
}

private_generation_paths_ok() {
  local candidate_file="$1"
  local candidate_path
  while IFS= read -r candidate_path; do
    [ -n "$candidate_path" ] || continue
    private_generation_path_ok "$candidate_path" || return 1
  done < "$candidate_file"
}

profile_activation_state_ok() {
  local root_program="$1"
  local wrapper="$2"
  local root_exists=false
  local wrapper_exists=false
  local selected_generation
  local selected_root
  { [ -e "$root_program" ] || [ -L "$root_program" ]; } && root_exists=true
  { [ -e "$wrapper" ] || [ -L "$wrapper" ]; } && wrapper_exists=true
  if [ "$root_exists" = false ] && [ "$wrapper_exists" = false ]; then
    return 0
  fi
  selected_generation="$(sed -n \
    "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$wrapper")"
  selected_root="$profile_root/core/v1/generations/$selected_generation"
  [ "$root_exists" = true ] && [ "$wrapper_exists" = true ] &&
    [ -f "$root_program" ] && [ ! -L "$root_program" ] &&
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && [ -x "$wrapper" ] &&
    [ "$(grep -Ec "^PORTABLE_CORE_GENERATION='g-[0-9a-f]{64}'$" "$wrapper")" -eq 1 ] &&
    [ -n "$selected_generation" ] &&
    grep -Fq "\"generation_id\":\"$selected_generation\"" \
      "$profile_root/core/v1/generation-registry.json" &&
    [ -d "$selected_root/modules" ] && [ ! -L "$selected_root/modules" ] &&
    [ -f "$selected_root/contracts.jq" ] && [ ! -L "$selected_root/contracts.jq" ] &&
    [ -f "$selected_root/core-ingress.sh" ] && [ ! -L "$selected_root/core-ingress.sh" ]
}

profile_guard_total=$((profile_guard_total + 1))
if [ "$(grep -Fxc "core/v1/generations/$profile_generation/modules/profile_graph.jq" "$generation_files")" -eq 1 ] &&
   private_generation_paths_ok "$generation_files" &&
   profile_activation_state_ok \
     "$profile_root/core/v1/generations/$profile_generation/contracts.jq" \
     "$profile_root/scripts/core-contract.sh" &&
   [ -z "$(find "$profile_root/core/v1/generations/$profile_generation" -type l -print -quit)" ]; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "private activation guard"
fi

planned_generation_files="$profile_tmp/planned-generation-files"
cp "$generation_files" "$planned_generation_files"
printf '%s\n' \
  "core/v1/generations/$profile_generation/modules/stage_request.jq" \
  "core/v1/generations/$profile_generation/modules/result_facts.jq" \
  "core/v1/generations/$profile_generation/modules/result_truth.jq" >> \
  "$planned_generation_files"
profile_guard_total=$((profile_guard_total + 1))
if private_generation_paths_ok "$planned_generation_files"; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "private guard rejected planned downstream modules"
fi

unknown_generation_files="$profile_tmp/unknown-generation-files"
cp "$generation_files" "$unknown_generation_files"
printf '%s\n' "core/v1/generations/$profile_generation/modules/unknown.jq" >> \
  "$unknown_generation_files"
profile_guard_total=$((profile_guard_total + 1))
if ! private_generation_paths_ok "$unknown_generation_files"; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "private guard accepted an unknown generation member"
fi
mark_rule portable-core-profile-graph.private-activation-guard

required_paths="core/v1/generations/$profile_generation/modules/profile_graph.jq
scripts/test/portable-core-profile-graph-fixtures.jq
scripts/test/portable-core-profile-graph-ledger.tsv
scripts/test/portable-core-profile-graph.test.sh"
profile_guard_total=$((profile_guard_total + 1))
manifest_ok=true
while IFS= read -r required_path; do
  [ "$(grep -Fxc "$required_path" "$profile_manifest" || true)" -eq 1 ] &&
    [ -f "$profile_root/$required_path" ] || manifest_ok=false
done <<< "$required_paths"
if [ "$manifest_ok" = true ]; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "restore manifest coverage"
fi

manifest_prefix="$profile_tmp/manifest-prefix"
head -n 100 "$profile_manifest" > "$manifest_prefix"
profile_guard_total=$((profile_guard_total + 1))
if [ "$(sha256_path "$manifest_prefix")" = \
     "05df3e94698afb36978d4a48e0993db8c4a02bb793b89a095372626cd5a7bfbd" ] &&
   [ "$(sed -n '101,104p' "$profile_manifest")" = "$required_paths" ]; then
  profile_guard_passed=$((profile_guard_passed + 1))
else
  fail_case "restore manifest exact append"
fi
mark_rule portable-core-profile-graph.restore-manifest

profile_review_total="$(awk -F '\t' 'NR>1 && $1=="review" {n++} END {print n+0}' "$profile_ledger")"
profile_legacy_total="$(awk -F '\t' 'NR>1 && $1=="legacy" {n++} END {print n+0}' "$profile_ledger")"
if [ "$profile_review_total" -ne 7 ] || [ "$profile_legacy_total" -ne 92 ] ||
   [ "$(tail -n +2 "$profile_ledger" | cut -f2 | sort -u | wc -l | tr -d ' ')" -ne 99 ] ||
   [ "$(awk -F '\t' 'NR>1 && $3=="ported" {n++} END {print n+0}' "$profile_ledger")" -ne 95 ] ||
   [ "$(awk -F '\t' 'NR>1 && $3=="replaced-by" {n++} END {print n+0}' "$profile_ledger")" -ne 4 ] ||
   [ "$(sha256_path "$profile_ledger")" != \
     "$("${profile_jq_command[@]}" -r '.profile_mapping_sha256' <<< "$fixture_metadata")" ] ||
   [ "$("${profile_jq_command[@]}" -r '.review_rows' <<< "$fixture_metadata")" -ne 7 ] ||
   [ "$("${profile_jq_command[@]}" -r '.legacy_rows' <<< "$fixture_metadata")" -ne 92 ] ||
   [ "$("${profile_jq_command[@]}" -r '.review_source_sha256' <<< "$fixture_metadata")" != \
     "31793a3ad42acf4df117ea158a78738e056bae550269483870487c3e146b27f9" ] ||
   [ "$("${profile_jq_command[@]}" -r '.legacy_source_sha256' <<< "$fixture_metadata")" != \
     "3d5a6fb192f9bcaba5c4b89314d30f88a03b9d8a1e1e634297c267b14f096092" ]; then
  fail_case "frozen ledger row inventory"
fi

profile_expected_rules="$profile_tmp/expected-rules"
cut -f4 "$profile_ledger" | tail -n +2 > "$profile_expected_rules"
printf '%s\n' \
  portable-core-profile-graph.document-routes \
  portable-core-profile-graph.fixed-schema-import \
  portable-core-profile-graph.private-activation-guard \
  portable-core-profile-graph.profile-set-route \
  portable-core-profile-graph.protected-role-separation \
  portable-core-profile-graph.restore-manifest \
  portable-core-profile-graph.schema-dependency-pin \
  portable-core-profile-graph.serial-predecessor-receipt \
  portable-core-profile-graph.stage-run-resolved-route >> "$profile_expected_rules"
LC_ALL=C sort -u "$profile_expected_rules" > "$profile_tmp/expected-rules.sorted"
LC_ALL=C sort -u "$profile_seen_rules" > "$profile_tmp/seen-rules.sorted"
if ! cmp -s "$profile_tmp/expected-rules.sorted" "$profile_tmp/seen-rules.sorted"; then
  fail_case "owned rule inventory"
fi

tail -n +2 "$profile_ledger" | cut -f5 | LC_ALL=C sort -u > "$profile_tmp/expected-tests"
LC_ALL=C sort -u "$profile_seen_tests" > "$profile_tmp/seen-tests.sorted"
if ! cmp -s "$profile_tmp/expected-tests" "$profile_tmp/seen-tests.sorted"; then
  fail_case "ledger stable test inventory"
fi

profile_review_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="review" && ($5 in seen) {n++}
  END {print n+0}
' "$profile_tmp/seen-tests.sorted" "$profile_ledger")"
profile_legacy_accounted="$(awk -F '\t' '
  NR==FNR {seen[$1]=1; next}
  FNR>1 && $1=="legacy" && ($5 in seen) {n++}
  END {print n+0}
' "$profile_tmp/seen-tests.sorted" "$profile_ledger")"
if [ "$profile_review_accounted" -ne 7 ] || [ "$profile_legacy_accounted" -ne 92 ]; then
  fail_case "ledger executed mapping"
fi

profile_owned_total="$(wc -l < "$profile_tmp/expected-rules.sorted" | tr -d ' ')"
if [ "$profile_owned_total" -ne \
     "$("${profile_jq_command[@]}" -r '.owned_rules' <<< "$fixture_metadata")" ] ||
   [ "$profile_direct_total" -ne \
     "$("${profile_jq_command[@]}" -r '.direct_cases' <<< "$fixture_metadata")" ] ||
   [ "$profile_cell_total" -ne \
     "$("${profile_jq_command[@]}" -r '.command_to_rule_cells' <<< "$fixture_metadata")" ] ||
   [ "$profile_forced_total" -ne \
     "$("${profile_jq_command[@]}" -r '.forced_routes' <<< "$fixture_metadata")" ] ||
   [ "$profile_layer_total" -ne \
     "$("${profile_jq_command[@]}" -r '.error_layer_cases' <<< "$fixture_metadata")" ] ||
   [ "$profile_guard_total" -ne \
     "$("${profile_jq_command[@]}" -r '.guard_cases' <<< "$fixture_metadata")" ]; then
  fail_case "fixed proof denominators"
fi
profile_owned_passed="$profile_owned_total"
if [ "$profile_failures" -ne 0 ]; then
  profile_owned_passed=0
fi

printf 'owned rules: %s/%s\n' "$profile_owned_passed" "$profile_owned_total"
printf 'direct cases: %s/%s\n' "$profile_direct_passed" "$profile_direct_total"
printf 'command-to-rule cells: %s/%s\n' "$profile_cell_passed" "$profile_cell_total"
printf 'forced routes: %s/%s\n' "$profile_forced_passed" "$profile_forced_total"
printf 'error-layer cases: %s/%s\n' "$profile_layer_passed" "$profile_layer_total"
printf 'activation/restore/dependency cases: %s/%s\n' "$profile_guard_passed" "$profile_guard_total"
printf 'review findings accounted for: %s/%s\n' "$profile_review_accounted" "$profile_review_total"
printf 'legacy assertions accounted for: %s/%s\n' "$profile_legacy_accounted" "$profile_legacy_total"
printf 'failures: %s\n' "$profile_failures"

[ "$profile_failures" -eq 0 ]
