#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

[ "$#" -eq 6 ] && [ "$1" = build ] || exit 64
output_root=$2
jq_bin=$3
source_algorithm=$4
source_commit=$5
source_tree=$6
case "$output_root:$jq_bin" in /*:/*) ;; *) exit 64 ;; esac
[ -x "$jq_bin" ] && [ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || exit 1
case "$source_algorithm" in
  sha1) oid_pattern='^[0-9a-f]{40}$' ;;
  sha256) oid_pattern='^[0-9a-f]{64}$' ;;
  *) exit 64 ;;
esac
[[ "$source_commit" =~ $oid_pattern ]] && [[ "$source_tree" =~ $oid_pattern ]] || exit 64
[ ! -e "$output_root" ] || exit 1
/bin/mkdir -m 700 "$output_root" "$output_root/manifests"

script_dir=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}" && pwd -P)
repo_root=$(CDPATH='' cd -P -- "$script_dir/../.." && pwd -P)
fixtures="$repo_root/scripts/test"
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

contract_file="$output_root/materialization-contract.json"
"$jq_bin" -S -c -n '{
  schema_version:1,kind:"local_git_materialization_contract",
  allowed_paths:["source.txt"],max_patch_bytes:65536,max_changed_paths:1,
  allowed_modes:["100644","100755"],allow_binary_patch:false,
  allow_symlinks:false,allow_submodules:false,candidate_repository_kind:"bare"
}' > "$contract_file"
patch_file="$output_root/producer.patch"
printf '%s\n' \
  'diff --git a/source.txt b/source.txt' \
  '--- a/source.txt' \
  '+++ b/source.txt' \
  '@@ -1,2 +1,3 @@' \
  ' alpha' \
  ' beta' \
  '+gamma' > "$patch_file"
contract_sha=$(sha_file "$contract_file")
patch_sha=$(sha_file "$patch_file")

manifest_dir="$output_root/manifests"
forge_manifest="$manifest_dir/forge.json"
"$jq_bin" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  {
    schema_version:2,kind:"adapter_manifest",id:"adapter.local-git-materializer.v1",
    body:{adapter_version:"v1",package_ref:(f::blob("adapters/local-git-materializer/v1";"6") |
      .location={kind:"root"} | .object_type="tree" | .mode="040000"),
      offered_roles:["forge"],offered_execution_kinds:["deterministic"],
      offered_capabilities:["core.forge.materialize-candidate.v2"],
      offered_permissions:["core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
        "core.perm.target.read.v1"],offered_tools:[]}}
  | v2
' > "$forge_manifest"
for role in producer publisher reviewer verifier; do
  "$jq_bin" -L "$fixtures" -S -c -n --arg role "$role" '
    import "portable-core-profile-graph-fixtures" as f;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    f::manifest($role) | v2
  ' > "$manifest_dir/$role.json"
done
manifest_shas=$(
  "$jq_bin" -S -c -n \
    --arg forge "$(sha_file "$forge_manifest")" \
    --arg producer "$(sha_file "$manifest_dir/producer.json")" \
    --arg publisher "$(sha_file "$manifest_dir/publisher.json")" \
    --arg reviewer "$(sha_file "$manifest_dir/reviewer.json")" \
    --arg verifier "$(sha_file "$manifest_dir/verifier.json")" \
    '{forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}'
)

profile_file="$output_root/profile.json"
"$jq_bin" -L "$fixtures" -S -c -n --argjson shas "$manifest_shas" \
  --slurpfile forge "$forge_manifest" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def forge_binding: {
    binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:$forge[0].id,sha256:$shas.forge},
    execution_kind:"deterministic",adapter_instance_id:"instance.forge",
    principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
    authority_ref:f::scope("authority";"authority-forge";f::sha("5")),
    package_ref:$forge[0].body.package_ref,skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
      "core.perm.target.read.v1"]};
  f::profile_doc($shas) | v2 |
  .body.bindings += [forge_binding] | .body.bindings |= sort_by(.binding_id)
' > "$profile_file"
profile_sha=$(sha_file "$profile_file")

resolved_file="$output_root/resolved-profile.json"
"$jq_bin" -L "$fixtures" -S -c -n --argjson shas "$manifest_shas" \
  --slurpfile profile "$profile_file" --slurpfile forge "$forge_manifest" \
  --arg profile_sha "$profile_sha" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::resolved_profile_doc($profile[0];$profile_sha;$shas) | v2 |
  .body.bindings |= map(if .binding.role=="forge" then
    .adapter_implementation={id:$forge[0].id,version:"v1"} |
    .manifest_source=f::source_value(f::blob("manifests/forge.json";"a");"canonical-json";$shas.forge) |
    .package_source=f::source_value($forge[0].body.package_ref;"raw-bytes";f::sha("6")) |
    .config_source={state:"absent"} | .prompt_source={state:"absent"} |
    .skill_sources=[] | .tool_sources=[]
  else . end)
' > "$resolved_file"
resolved_sha=$(sha_file "$resolved_file")

request_file="$output_root/stage-request.json"
"$jq_bin" -L "$fixtures" -S -c -n \
  --arg resolved_sha "$resolved_sha" --arg algorithm "$source_algorithm" \
  --arg source_commit "$source_commit" --arg source_tree "$source_tree" \
  --arg contract_sha "$contract_sha" --arg patch_sha "$patch_sha" '
  import "portable-core-stage-request-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def revision: {repository_id:"fixture.target",hash_algorithm:$algorithm,commit_id:$source_commit};
  def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def named($id;$ref): {input_id:$id,value:{type:"artifact",value:{type:"content",value:$ref}}};
  f::request_doc("producer";$resolved_sha) | v2 |
  .id="request.local-git-materializer" | .body.stage_id="stage.materialize" |
  .body.target_repository_id="fixture.target" |
  .body.target_revision={state:"present",value:revision} |
  .body.source={state:"present",value:{type:"git-object",value:{revision:revision,
    location:{kind:"root"},object_type:"tree",object_id:$source_tree,mode:"040000"}}} |
  .body.base={state:"present",value:revision} |
  .body.inputs=([
    f::named_content_input("finish";f::sha("1")),
    named("input.materialize";content("payload-materialize";"application/json";$contract_sha)),
    named("input.producer-patch";content("producer.patch";"text/x-diff";$patch_sha)),
    {input_id:"input.source-tree",value:{type:"artifact",value:{type:"git-object",value:{
      revision:revision,location:{kind:"root"},object_type:"tree",object_id:$source_tree,mode:"040000"}}}},
    f::named_content_input("verify";f::sha("2"))] | sort_by(.input_id)) |
  .body.operation={role:"forge",binding_id:"binding.forge",
    capability_id:"core.forge.materialize-candidate.v2",
    permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1","core.perm.target.read.v1"],
    arguments:{source_tree_input_id:"input.source-tree",candidate_output_id:"candidate.repository",
      materialization_contract:{ref:(f::scope("output-contract";"materialize";f::sha("3")) |
        .subject_ref.value.value=content("payload-materialize";"application/json";$contract_sha)),
        input_id:"input.materialize"},network_mode:"deny"}} |
  .body.required_evidence_kinds=["deterministic"]
' > "$request_file"
request_sha=$(sha_file "$request_file")

input_file="$output_root/input.json"
"$jq_bin" -S -c -n --slurpfile profile "$profile_file" \
  --slurpfile resolved "$resolved_file" --slurpfile request "$request_file" \
  --slurpfile forge "$forge_manifest" --slurpfile producer "$manifest_dir/producer.json" \
  --slurpfile publisher "$manifest_dir/publisher.json" --slurpfile reviewer "$manifest_dir/reviewer.json" \
  --slurpfile verifier "$manifest_dir/verifier.json" --rawfile contract "$contract_file" \
  --rawfile patch "$patch_file" --argjson shas "$manifest_shas" \
  --arg profile_sha "$profile_sha" --arg resolved_sha "$resolved_sha" \
  --arg request_sha "$request_sha" --arg contract_sha "$contract_sha" --arg patch_sha "$patch_sha" '
  {schema_version:1,kind:"local_git_materialization_input",
   attempt:{attempt_id:"attempt.materialize",attempt_number:1,result_id:"result.materialize",
     started_at:"2026-08-30T00:00:01Z",finished_at:"2026-08-30T00:00:02Z",
     recorded_at:"2026-08-30T00:00:03Z"},
   profile:{content:$profile[0],sha256:$profile_sha},
   resolved_profile:{content:$resolved[0],sha256:$resolved_sha},
   manifests:([
     {content:$forge[0],sha256:$shas.forge},
     {content:$producer[0],sha256:$shas.producer},
     {content:$publisher[0],sha256:$shas.publisher},
     {content:$reviewer[0],sha256:$shas.reviewer},
     {content:$verifier[0],sha256:$shas.verifier}] | sort_by(.content.id)),
   stage_request:{content:$request[0],sha256:$request_sha},
   payloads:([
     {input_id:"input.materialize",media_type:"application/json",data:$contract},
     {input_id:"input.producer-patch",media_type:"text/x-diff",data:$patch}]
     | sort_by(.input_id)),
   trust_context:{verified_payloads:([
     {input_id:"input.materialize",content:{media_type:"application/json",data:$contract},
      sha256:$contract_sha},
     {input_id:"input.producer-patch",content:{media_type:"text/x-diff",data:$patch},
      sha256:$patch_sha}]
     | sort_by(.input_id))}}
' > "$input_file"
