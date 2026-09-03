import "schema" as schema;
import "profile_graph" as profile;
import "stage_request" as request;

def exact($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def pair($kind):
  profile::document_pair_ok($kind);

def path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (startswith("/") | not) and (contains("\\") | not) and
  (split("/") |
   all(.[];
       . != "" and . != "." and . != ".." and
       (ascii_downcase != ".git") and
       (endswith(".") | not) and (endswith(" ") | not)));

def attempt_ok:
  exact(
    ["attempt_id","attempt_number","result_id","started_at","finished_at",
     "recorded_at"];
    []) and
  (.attempt_id | schema::id_ok) and
  (.attempt_number | schema::int_ok) and .attempt_number >= 1 and
  (.result_id | schema::id_ok) and
  (.started_at | schema::time_ok) and
  (.finished_at | schema::time_ok) and
  (.recorded_at | schema::time_ok) and
  .started_at <= .finished_at and .finished_at <= .recorded_at;

def payload_ok:
  exact(["input_id","media_type","data"];[]) and
  (.input_id | schema::id_ok) and
  (.media_type | schema::media_type_ok) and
  (.data | type == "string" and utf8bytelength <= 2097152);

def verified_payload_ok:
  exact(["input_id","content","sha256"];[]) and
  (.input_id | schema::id_ok) and
  (.content |
   exact(["media_type","data"];[]) and
   (.media_type | schema::media_type_ok) and
   (.data | type == "string" and utf8bytelength <= 2097152)) and
  (.sha256 | schema::sha256_ok);

def materialization_contract_ok:
  exact(
    ["schema_version","kind","allowed_paths","max_patch_bytes",
     "max_changed_paths","allowed_modes","allow_binary_patch",
     "allow_symlinks","allow_submodules","candidate_repository_kind"];
    []) and
  .schema_version == 1 and .kind == "local_git_materialization_contract" and
  (.allowed_paths |
   type == "array" and length >= 1 and length <= 256 and
   all(.[];path_ok) and . == sort and length == (unique | length)) and
  (.max_patch_bytes | schema::int_ok) and
  .max_patch_bytes >= 1 and .max_patch_bytes <= 1048576 and
  (.max_changed_paths | schema::int_ok) and
  .max_changed_paths >= 1 and .max_changed_paths <= 256 and
  .max_changed_paths <= (.allowed_paths | length) and
  .allowed_modes == ["100644","100755"] and
  .allow_binary_patch == false and .allow_symlinks == false and
  .allow_submodules == false and .candidate_repository_kind == "bare";

def input_content_ref($body; $input_id):
  [$body.inputs[] |
   select(.input_id == $input_id and .value.type == "artifact" and
          .value.value.type == "content") |
   .value.value.value] as $matches |
  if ($matches | length) == 1 then $matches[0] else null end;

def payload_for($input; $input_id):
  [$input.payloads[] | select(.input_id == $input_id)] as $matches |
  if ($matches | length) == 1 then $matches[0] else null end;

def verified_payload_for($input; $input_id):
  [$input.trust_context.verified_payloads[] |
   select(.input_id == $input_id)] as $matches |
  if ($matches | length) == 1 then $matches[0] else null end;

def payload_matches_input($input; $input_id):
  input_content_ref($input.stage_request.content.body;$input_id) as $ref |
  payload_for($input;$input_id) as $payload |
  verified_payload_for($input;$input_id) as $verified |
  $ref != null and $payload != null and $verified != null and
  $payload == ({input_id:$input_id} + $verified.content) and
  $verified.content.media_type == $ref.media_type and
  $verified.sha256 == $ref.sha256;

def git_object_input($body; $input_id):
  [$body.inputs[] |
   select(.input_id == $input_id and .value.type == "artifact" and
          .value.value.type == "git-object") |
   .value.value.value] as $matches |
  if ($matches | length) == 1 then $matches[0] else null end;

def selected_binding($input):
  [$input.resolved_profile.content.body.bindings[] |
   select(.binding.binding_id ==
          $input.stage_request.content.body.operation.binding_id)];

def selected_manifest($input; $binding):
  [$input.manifests[] |
   select(profile::document_ref_for_pair(.) == $binding.binding.manifest_ref)];

def materializer_manifest_ok:
  (.content | profile::adapter_manifest_self_ok) and
  .content.id == "adapter.local-git-materializer.v1" and
  .content.body.adapter_version == "v1" and
  .content.body.offered_roles == ["forge"] and
  .content.body.offered_execution_kinds == ["deterministic"] and
  .content.body.offered_capabilities == ["core.forge.materialize-candidate.v2"] and
  .content.body.offered_permissions == [
    "core.perm.candidate-repository.write.v2",
    "core.perm.evidence.write.v1",
    "core.perm.scratch.write.v1",
    "core.perm.target.read.v1"
  ] and
  .content.body.offered_tools == [] and
  (.content.body | has("config_contract_ref") | not);

def core_relations_ok($input):
  ($input.profile | pair("profile")) and
  ($input.resolved_profile | pair("resolved_profile")) and
  ($input.manifests |
   type == "array" and length >= 1 and length <= 8 and
   all(.[];pair("adapter_manifest")) and
   (map(.content.id) | . == sort and length == (unique | length))) and
  profile::profile_set_ok(
    $input.profile;$input.resolved_profile;$input.manifests) and
  ($input.stage_request | pair("stage_request")) and
  ($input.stage_request.content | request::document_self_ok) and
  request::stage_request_resolved_ref_ok(
    $input.stage_request;$input.resolved_profile) and
  request::stage_request_resolved_relation_ok(
    $input.stage_request.content.body;$input.resolved_profile.content.body);

def materializer_relations_ok($input):
  $input.stage_request.content.body as $body |
  selected_binding($input) as $bindings |
  ($bindings | length) == 1 and
  $bindings[0] as $binding |
  selected_manifest($input;$binding) as $manifests |
  ($manifests | length) == 1 and
  ($manifests[0] | materializer_manifest_ok) and
  profile::binding_manifest_graph_ok(
    $binding.binding;$binding;$manifests[0]) and
  $body.operation == {
    role:"forge",
    binding_id:$binding.binding.binding_id,
    capability_id:"core.forge.materialize-candidate.v2",
    permissions:[
      "core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1",
      "core.perm.target.read.v1"
    ],
    arguments:$body.operation.arguments
  } and
  $body.operation.arguments.network_mode == "deny" and
  $body.target_revision.state == "present" and
  $binding.binding.execution_kind == "deterministic" and
  ($binding.binding | has("config_ref") | not) and
  ($binding.binding | has("prompt_ref") | not) and
  ($binding.binding | has("model_request") | not) and
  $binding.binding.skill_refs == [] and $binding.binding.requested_tools == [] and
  $input.attempt.started_at >= $body.requested_at;

def trust_context_ok:
  exact(["verified_payloads"];[]) and
  (.verified_payloads |
   type == "array" and length == 2 and all(.[];verified_payload_ok) and
   (map(.input_id) | . == sort and length == (unique | length)));

def payload_relations_ok($input):
  $input.stage_request.content.body.operation.arguments as $arguments |
  $arguments.materialization_contract.input_id as $contract_id |
  (payload_for($input;$contract_id).data |
   try fromjson catch null) as $contract |
  payload_for($input;"input.producer-patch") as $patch |
  ($input.payloads |
   type == "array" and length == 2 and all(.[];payload_ok) and
   (map(.input_id) | . == sort and length == (unique | length))) and
  ($input.trust_context | trust_context_ok) and
  payload_matches_input($input;$contract_id) and
  payload_matches_input($input;"input.producer-patch") and
  (payload_for($input;$contract_id).media_type == "application/json") and
  ($patch.media_type == "text/x-diff") and
  ($contract | materialization_contract_ok) and
  ($patch.data | utf8bytelength) <= $contract.max_patch_bytes;

def input_ok:
  . as $input |
  exact(
    ["schema_version","kind","attempt","profile","resolved_profile",
     "manifests","stage_request","payloads","trust_context"];
    []) and
  .schema_version == 1 and .kind == "local_git_materialization_input" and
  (.attempt | attempt_ok) and
  core_relations_ok($input) and materializer_relations_ok($input) and
  payload_relations_ok($input);

def document_ref($pair): profile::document_ref_for_pair($pair);

def receipt:
  . as $input |
  $input.stage_request.content.body as $request_body |
  $request_body.operation.arguments as $arguments |
  $arguments.materialization_contract.input_id as $contract_id |
  (payload_for($input;$contract_id).data | fromjson) as $contract |
  git_object_input($request_body;$arguments.source_tree_input_id) as $source_ref |
  $request_body.target_revision.value as $target_revision |
  ($ARGS.named.source_repository_id // "") as $source_repository_id |
  ($ARGS.named.source_hash_algorithm // "") as $source_hash_algorithm |
  ($ARGS.named.source_commit // "") as $source_commit |
  ($ARGS.named.source_tree // "") as $source_tree |
  ($ARGS.named.candidate_commit // "") as $candidate_commit |
  ($ARGS.named.candidate_tree // "") as $candidate_tree |
  ($ARGS.named.changed_path_count // "") as $changed_path_count |
  ($ARGS.named.changed_paths_sha256 // "") as $changed_paths_sha256 |
  if input_ok and
     $source_repository_id == $request_body.target_repository_id and
     $target_revision == {
       repository_id:$source_repository_id,
       hash_algorithm:$source_hash_algorithm,
       commit_id:$source_commit
     } and
     $source_ref != null and $source_ref.revision == $target_revision and
     $source_ref.location == {kind:"root"} and
     $source_ref.object_type == "tree" and $source_ref.mode == "040000" and
     $source_ref.object_id == $source_tree and
     (($source_hash_algorithm == "sha1" and
       ($source_commit | test("\\A[0-9a-f]{40}\\z")) and
       ($source_tree | test("\\A[0-9a-f]{40}\\z")) and
       ($candidate_commit | test("\\A[0-9a-f]{40}\\z")) and
       ($candidate_tree | test("\\A[0-9a-f]{40}\\z"))) or
      ($source_hash_algorithm == "sha256" and
       ($source_commit | test("\\A[0-9a-f]{64}\\z")) and
       ($source_tree | test("\\A[0-9a-f]{64}\\z")) and
       ($candidate_commit | test("\\A[0-9a-f]{64}\\z")) and
       ($candidate_tree | test("\\A[0-9a-f]{64}\\z")))) and
     ($changed_paths_sha256 | schema::sha256_ok) and
     ($changed_path_count | tonumber | schema::int_ok) and
     ($changed_path_count | tonumber) <= $contract.max_changed_paths then
    {
      schema_version:1,
      kind:"candidate_materialization_receipt",
      adapter:{id:"adapter.local-git-materializer.v1",version:"v1",status:"inactive"},
      attempt:{
        attempt_id:$input.attempt.attempt_id,
        attempt_number:$input.attempt.attempt_number
      },
      request_ref:document_ref($input.stage_request),
      resolved_profile_ref:document_ref($input.resolved_profile),
      manifest_ref:(selected_binding($input)[0].binding.manifest_ref),
      materialization_contract_ref:
        input_content_ref($input.stage_request.content.body;$contract_id),
      patch_ref:
        input_content_ref($input.stage_request.content.body;"input.producer-patch"),
      source:{
        repository_id:$source_repository_id,
        hash_algorithm:$source_hash_algorithm,
        commit_id:$source_commit,
        tree_id:$source_tree
      },
      candidate:{
        repository_kind:"bare",
        hash_algorithm:$source_hash_algorithm,
        commit_id:$candidate_commit,
        tree_id:$candidate_tree,
        parent_commit_id:$source_commit
      },
      changed_paths:{
        count:($changed_path_count | tonumber),
        sha256:$changed_paths_sha256
      }
    }
  else error("E_RECEIPT") end;

def recorded($value; $source_ref):
  {state:"recorded",value:$value,source_ref:$source_ref};
def not_applicable: {state:"not-applicable"};

def oid_ok($algorithm):
  type == "string" and
  if $algorithm == "sha1" then test("\\A[0-9a-f]{40}\\z")
  elif $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
  else false
  end;

def verified_receipt_pair_ok:
  exact(["content","sha256"];[]) and
  (.content | type == "object") and (.sha256 | schema::sha256_ok);

def receipt_relations_ok($input; $value):
  $input.stage_request.content.body as $request_body |
  $request_body.operation.arguments as $arguments |
  $arguments.materialization_contract.input_id as $contract_id |
  (payload_for($input;$contract_id).data | fromjson) as $contract |
  git_object_input($request_body;$arguments.source_tree_input_id) as $source_ref |
  $request_body.target_revision.value as $target_revision |
  selected_binding($input)[0].binding as $binding |
  ($value | exact(
    ["schema_version","kind","adapter","attempt","request_ref",
     "resolved_profile_ref","manifest_ref","materialization_contract_ref",
     "patch_ref","source","candidate","changed_paths"];
    [])) and
  $value.schema_version == 1 and
  $value.kind == "candidate_materialization_receipt" and
  $value.adapter == {
    id:"adapter.local-git-materializer.v1",version:"v1",status:"inactive"
  } and
  $value.attempt == {
    attempt_id:$input.attempt.attempt_id,
    attempt_number:$input.attempt.attempt_number
  } and
  $value.request_ref == document_ref($input.stage_request) and
  $value.resolved_profile_ref == document_ref($input.resolved_profile) and
  $value.manifest_ref == $binding.manifest_ref and
  $value.materialization_contract_ref ==
    input_content_ref($request_body;$contract_id) and
  $value.patch_ref == input_content_ref($request_body;"input.producer-patch") and
  $source_ref.location == {kind:"root"} and
  $value.source == {
    repository_id:$request_body.target_repository_id,
    hash_algorithm:$target_revision.hash_algorithm,
    commit_id:$target_revision.commit_id,
    tree_id:$source_ref.object_id
  } and
  ($value.candidate |
   exact(["repository_kind","hash_algorithm","commit_id","tree_id",
          "parent_commit_id"];[]) and
   .repository_kind == "bare" and
   .hash_algorithm == $target_revision.hash_algorithm and
   (.commit_id | oid_ok($target_revision.hash_algorithm)) and
   (.tree_id | oid_ok($target_revision.hash_algorithm)) and
   .parent_commit_id == $target_revision.commit_id) and
  ($value.changed_paths |
   exact(["count","sha256"];[]) and
   (.count | schema::int_ok) and .count <= $contract.max_changed_paths and
   (.sha256 | schema::sha256_ok));

def receipt_outcome_ok($value; $outcome):
  if $outcome == "changed" then
    $value.changed_paths.count >= 1 and
    ($value.candidate.commit_id != $value.source.commit_id and
     $value.candidate.tree_id != $value.source.tree_id)
  elif $outcome == "no-change" then
    $value.changed_paths.count == 0 and
    $value.candidate.commit_id == $value.source.commit_id and
    $value.candidate.tree_id == $value.source.tree_id
  else false
  end;

def stage_result:
  . as $input |
  ($ARGS.named.receipt_json // "" | try fromjson catch null) as $receipt |
  ($ARGS.named.verified_receipt_json // "" | try fromjson catch null) as $verified |
  ($ARGS.named.outcome // "") as $outcome |
  request::expected_execution_projection(
    $input.stage_request.content.body;$input.resolved_profile.content.body) as $projection |
  {
    content_id:"candidate.materialization.receipt",
    media_type:"application/json",
    sha256:$verified.sha256
  } as $receipt_ref |
  if input_ok and ($verified | verified_receipt_pair_ok) and
     $receipt == $verified.content and
     receipt_relations_ok($input;$receipt) and
     receipt_outcome_ok($receipt;$outcome) and $projection != null then
    {
      schema_version:2,
      kind:"stage_result",
      id:$input.attempt.result_id,
      body:{
        request_ref:document_ref($input.stage_request),
        resolved_profile_ref:document_ref($input.resolved_profile),
        attempt_id:$input.attempt.attempt_id,
        attempt_number:$input.attempt.attempt_number,
        reported_by:$projection.performer,
        status:"completed",
        outcome:{family:"change",value:$outcome},
        outputs:(if $outcome == "changed" then [{
          output_id:$input.stage_request.content.body.operation.arguments.candidate_output_id,
          ref:$receipt_ref
        }] else [] end),
        diagnostics:[],
        execution:{
          performer:$projection.performer,
          actual_binding:$projection.actual_binding,
          environment:$projection.environment,
          used_capability:$projection.used_capability,
          metadata:{
            kind:"deterministic",
            provider:not_applicable,
            model:not_applicable,
            snapshot:not_applicable,
            effort:not_applicable,
            prompt:not_applicable,
            skills:not_applicable,
            tools:recorded([];$receipt_ref)
          }
        },
        evidence:[{
          evidence_id:"evidence.local-git-materialization",
          kind:"deterministic",
          verdict:"passed",
          proof_ref:$receipt_ref
        }],
        started_at:$input.attempt.started_at,
        finished_at:$input.attempt.finished_at,
        recorded_at:$input.attempt.recorded_at
      }
    }
  else error("E_RESULT") end;

if $command == "validate-input" then input_ok
elif $command == "contract" then
  . as $input |
  if input_ok then
    payload_for(
      $input;
      $input.stage_request.content.body.operation.arguments.materialization_contract.input_id).data
  else error("E_INPUT") end
elif $command == "patch" then
  if input_ok then payload_for(.;"input.producer-patch").data else error("E_INPUT") end
elif $command == "receipt" then receipt
elif $command == "stage-result" then stage_result
else error("E_COMMAND") end
