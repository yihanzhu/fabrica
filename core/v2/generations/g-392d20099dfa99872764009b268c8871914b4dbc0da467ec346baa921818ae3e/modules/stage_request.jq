import "schema" as schema;
import "profile_graph" as profile_graph;

def optional_ok($name; value_ok):
  (has($name) | not) or (.[$name] | value_ok);

def present($value): {state:"present",value:$value};
def absent: {state:"absent"};

def named_input_shape_ok:
  schema::exact_fields(["input_id","value"];[]) and
  (.input_id | schema::id_ok) and
  (.value | schema::input_ref_ok);

def risk_tier_shape_ok:
  schema::exact_fields(["namespace","name"];[]) and
  ((.namespace == "core" and
    (.name == "routine" or .name == "high" or .name == "bootstrap")) or
   ((.namespace | schema::reverse_dns_ok) and (.name | schema::id_ok)));

def risk_claim_shape_ok:
  schema::exact_fields(
    ["tier","reason_ids","policy_ref","required_gate_refs"];
    []) and
  (.tier | risk_tier_shape_ok) and
  (.reason_ids | schema::bounded_set(1;256;schema::id_ok;.)) and
  (.policy_ref | schema::scope_ref_purpose_ok("policy")) and
  (.required_gate_refs |
   schema::bounded_set(
     0;256;schema::scope_ref_purpose_ok("gate-requirement");.scope_sha256));

def instruction_media_type_ok:
  . == "text/plain" or . == "application/json";

def capability_arguments_shape_ok($capability):
  schema::argument_shape_for_capability($capability) as $shape |
  if $shape == "materialize-candidate" then
    schema::exact_fields(
      ["source_tree_input_id","candidate_output_id",
       "materialization_contract","network_mode"];
      []) and
    (.source_tree_input_id | schema::id_ok) and
    (.candidate_output_id | schema::id_ok) and
    (.materialization_contract |
     schema::delivered_scope_ok("output-contract")) and
    .network_mode == "deny"
  elif $shape == "produce" then
    (schema::exact_fields(["artifact_kind","output_contract"];[]) and
     (.artifact_kind == "plan" or .artifact_kind == "structured-artifact") and
     (.output_contract | schema::delivered_scope_ok("output-contract"))) or
    (schema::exact_fields(["artifact_kind","allowed_delta"];[]) and
     .artifact_kind == "git-patch" and
     (.allowed_delta | schema::delivered_scope_ok("allowed-delta")))
  elif $shape == "verify" then
    schema::exact_fields(
      ["candidate_input_id","verification_plan","network_mode"];
      []) and
    (.candidate_input_id | schema::id_ok) and
    (.verification_plan | schema::delivered_scope_ok("verification-plan")) and
    .network_mode == "deny"
  elif $shape == "review" then
    schema::exact_fields(["change_ref","review_policy"];[]) and
    (.change_ref | schema::change_ref_ok) and
    (.review_policy | schema::delivered_scope_ok("review-policy"))
  else false
  end;

def operation_shape_ok:
  schema::exact_fields(
    ["role","binding_id","capability_id","permissions","arguments"];
    []) and
  (.role | schema::adapter_role_ok) and
  (.binding_id | schema::id_ok) and
  (.capability_id | schema::capability_id_ok) and
  (.permissions | schema::enum_set_ok(1;5;schema::permission_ids)) and
  (.capability_id as $capability |
   .arguments | capability_arguments_shape_ok($capability));

def stage_request_body_shape_ok:
  schema::exact_fields(
    ["initiative_id","workflow_id","stage_id","task_class_id","requested_by",
     "target_repository_id","target_revision","source","base","inputs",
     "prior_evidence_refs","risk","resolved_profile_ref","selection_ref",
     "repository_context_ref","gate_decision_refs","environment_ref","operation",
     "finish_condition","verification_instruction","required_evidence_kinds",
     "requested_at"];
    ["qualification_ref","grant_ref"]) and
  (.initiative_id | schema::id_ok) and
  (.workflow_id | schema::id_ok) and
  (.stage_id | schema::id_ok) and
  (.task_class_id | schema::id_ok) and
  (.requested_by | schema::actor_ref_ok) and
  (.target_repository_id | schema::id_ok) and
  (.target_revision | schema::present_ok(schema::git_revision_ref_ok)) and
  (.source | schema::present_ok(schema::artifact_ref_ok)) and
  (.base | schema::present_ok(schema::git_revision_ref_ok)) and
  (.inputs | schema::bounded_set(0;256;named_input_shape_ok;.input_id)) and
  (.prior_evidence_refs |
   schema::bounded_set(
     0;256;schema::evidence_ref_ok;
     [.stage_result_ref.sha256,.evidence_id])) and
  (.risk | risk_claim_shape_ok) and
  (.resolved_profile_ref | schema::document_ref_kind_ok("resolved_profile")) and
  (.selection_ref | schema::scope_ref_purpose_ok("selection")) and
  (.repository_context_ref |
   schema::scope_ref_purpose_ok("repository-context")) and
  optional_ok("qualification_ref";
    schema::scope_ref_purpose_ok("qualification")) and
  optional_ok("grant_ref";schema::scope_ref_purpose_ok("grant")) and
  (.gate_decision_refs |
   schema::bounded_set(
     0;256;schema::scope_ref_purpose_ok("gate-decision");.scope_sha256)) and
  (.environment_ref | schema::environment_ref_ok) and
  (.operation | operation_shape_ok) and
  (.finish_condition | schema::delivered_scope_ok("finish-condition")) and
  (.verification_instruction |
   schema::delivered_scope_ok("verification-instructions")) and
  (.required_evidence_kinds |
   schema::enum_set_ok(1;3;schema::evidence_kinds)) and
  (.requested_at | schema::time_ok);

def stage_request_shape_ok:
  schema::envelope_ok("stage_request") and
  (.body | stage_request_body_shape_ok);

def operation_capability_scope($operation):
  if $operation.arguments | has("output_contract") then
    $operation.arguments.output_contract
  elif $operation.arguments | has("allowed_delta") then
    $operation.arguments.allowed_delta
  elif $operation.arguments | has("verification_plan") then
    $operation.arguments.verification_plan
  elif $operation.arguments | has("review_policy") then
    $operation.arguments.review_policy
  elif $operation.arguments | has("materialization_contract") then
    $operation.arguments.materialization_contract
  else null
  end;

def delivered_scope_input_relation_ok($delivered; $inputs):
  [$inputs[] | select(.input_id == $delivered.input_id)] as $matches |
  ($matches | length) == 1 and
  $matches[0].value == $delivered.ref.subject_ref and
  ($delivered.ref.subject_ref.value.value.media_type |
   instruction_media_type_ok);

def instruction_relations_ok($body):
  operation_capability_scope($body.operation) as $capability_scope |
  if $capability_scope == null then false
  else
    [$body.finish_condition,$body.verification_instruction,$capability_scope] as $scopes |
    ($scopes | map(.input_id)) as $instruction_ids |
    ($instruction_ids | unique | length) == 3 and
    all($scopes[]; . as $scope |
        delivered_scope_input_relation_ok($scope;$body.inputs)) and
    (if $body.operation.capability_id == "core.verify.run.v1" then
       ($instruction_ids |
        index($body.operation.arguments.candidate_input_id) == null)
     elif $body.operation.capability_id ==
          "core.forge.materialize-candidate.v2" then
       ($instruction_ids |
        index($body.operation.arguments.source_tree_input_id) == null)
     else true end)
  end;

def capability_role_relation_ok($operation):
  schema::capabilities_for_role($operation.role) ==
    [$operation.capability_id];

def permissions_match_a_role_execution_kind($operation):
  schema::execution_kinds_for_role($operation.role) as $role_kinds |
  schema::capability_execution_kinds($operation.capability_id) as $capability_kinds |
  any($role_kinds[]; . as $execution_kind |
      ($capability_kinds | index($execution_kind) != null) and
      $operation.permissions ==
        schema::permissions_for_capability(
          $operation.capability_id;$execution_kind));

def evidence_relation_ok($operation; $required):
  if $operation.capability_id == "core.verify.run.v1" then
    ($required | index("deterministic") != null) and
    all($required[];
        . == "deterministic" or . == "behavioral" or . == "architecture")
  else
    $required ==
      schema::required_evidence_kinds_for_capability(
        $operation.capability_id)
  end;

def artifact_repository_ok($artifact; $repository_id):
  if $artifact.type == "git-object" then
    $artifact.value.revision.repository_id == $repository_id
  else true
  end;

def input_repository_ok($input; $repository_id):
  if $input.value.type == "artifact" then
    artifact_repository_ok($input.value.value;$repository_id)
  else true
  end;

def request_repository_relations_ok($body):
  $body.target_repository_id as $repository_id |
  (if $body.target_revision.state == "present" then
     $body.target_revision.value.repository_id == $repository_id
   else true end) and
  (if $body.source.state == "present" then
     artifact_repository_ok($body.source.value;$repository_id)
   else true end) and
  (if $body.base.state == "present" then
     $body.base.value.repository_id == $repository_id
   else true end) and
  all($body.inputs[]; . as $input |
      input_repository_ok($input;$repository_id)) and
  (if $body.operation.capability_id == "core.review.change.v1" then
     $body.operation.arguments.change_ref.repository_id == $repository_id
   else true end);

def verifier_candidate_relation_ok($body):
  if $body.operation.capability_id == "core.verify.run.v1" then
    $body.operation.arguments.candidate_input_id as $candidate_id |
    [$body.inputs[] | select(.input_id == $candidate_id)] as $matches |
    $body.target_revision.state == "present" and
    ($matches | length) == 1 and
    $matches[0].value.type == "artifact" and
    $matches[0].value.value.type == "git-object" and
    $matches[0].value.value.value.object_type == "tree" and
    $matches[0].value.value.value.revision == $body.target_revision.value
  else true
  end;

def reviewer_change_relation_ok($body):
  if $body.operation.capability_id == "core.review.change.v1" then
    $body.target_revision.state == "present" and
    $body.operation.arguments.change_ref.head == $body.target_revision.value and
    $body.operation.arguments.change_ref.base == $body.base
  else true
  end;

def forge_materialization_relation_ok($body):
  if $body.operation.capability_id ==
     "core.forge.materialize-candidate.v2" then
    $body.operation.arguments.source_tree_input_id as $source_id |
    [$body.inputs[] | select(.input_id == $source_id)] as $matches |
    $body.target_revision.state == "present" and
    ($matches | length) == 1 and
    $matches[0].value.type == "artifact" and
    $matches[0].value.value.type == "git-object" and
    $matches[0].value.value.value.object_type == "tree" and
    $matches[0].value.value.value.revision == $body.target_revision.value and
    all($body.inputs[];
        .input_id != $body.operation.arguments.candidate_output_id)
  else true
  end;

def absent_target_relation_ok($body):
  if $body.target_revision.state == "absent" then
    $body.operation.role == "producer" and
    $body.risk.tier == {namespace:"core",name:"bootstrap"}
  else true
  end;

def stage_request_self_relations_ok:
  . as $body |
  capability_role_relation_ok($body.operation) and
  permissions_match_a_role_execution_kind($body.operation) and
  evidence_relation_ok($body.operation;$body.required_evidence_kinds) and
  instruction_relations_ok($body) and
  request_repository_relations_ok($body) and
  verifier_candidate_relation_ok($body) and
  reviewer_change_relation_ok($body) and
  forge_materialization_relation_ok($body) and
  absent_target_relation_ok($body);

def stage_request_self_ok:
  stage_request_shape_ok and
  (.body | stage_request_self_relations_ok);

def stage_request_resolved_ref_ok($request_pair; $resolved_pair):
  $request_pair.content.body.resolved_profile_ref ==
    profile_graph::document_ref_for_pair($resolved_pair);

def selected_resolved_binding($request_body; $resolved_body):
  [$resolved_body.bindings[] |
   select(.binding.binding_id == $request_body.operation.binding_id)];

def selected_binding_relation_ok($operation; $resolved_binding):
  $resolved_binding.binding as $binding |
  $binding.role == $operation.role and
  $binding.requested_capabilities == [$operation.capability_id] and
  $binding.requested_permissions == $operation.permissions and
  $operation.permissions ==
    schema::permissions_for_capability(
      $operation.capability_id;$binding.execution_kind);

def stage_request_resolved_relation_ok($request_body; $resolved_body):
  selected_resolved_binding($request_body;$resolved_body) as $matches |
  $request_body.selection_ref == $resolved_body.selection_ref and
  $request_body.repository_context_ref == $resolved_body.repository_context_ref and
  ($matches | length) == 1 and
  selected_binding_relation_ok($request_body.operation;$matches[0]);

def projected_actual_binding($resolved_binding):
  $resolved_binding.binding as $binding |
  {
    binding_id:$binding.binding_id,
    role:$binding.role,
    adapter_implementation:$resolved_binding.adapter_implementation,
    manifest_ref:$binding.manifest_ref,
    package_ref:$binding.package_ref,
    config_ref:(if $binding | has("config_ref")
                then present($binding.config_ref)
                else absent end),
    execution_kind:$binding.execution_kind,
    adapter_instance_id:$binding.adapter_instance_id,
    principal_id:$binding.principal_id,
    execution_boundary_id:$binding.execution_boundary_id
  } +
  (if $binding | has("authority_ref")
   then {authority_ref:$binding.authority_ref}
   else {} end);

def projected_performer($resolved_binding):
  $resolved_binding.binding as $binding |
  {
    role:$binding.role,
    implementation_id:$resolved_binding.adapter_implementation.id,
    implementation_version:$resolved_binding.adapter_implementation.version,
    adapter_instance_id:$binding.adapter_instance_id,
    principal_id:$binding.principal_id,
    execution_boundary_id:$binding.execution_boundary_id
  } +
  (if $binding | has("authority_ref")
   then {authority_ref:$binding.authority_ref}
   else {} end);

def metadata_expectation($binding):
  {
    kind:$binding.execution_kind,
    model_request:(if $binding | has("model_request")
                   then present($binding.model_request)
                   else absent end),
    prompt_ref:(if $binding | has("prompt_ref")
                then present($binding.prompt_ref)
                else absent end),
    skill_refs:$binding.skill_refs,
    allowed_tools:$binding.requested_tools
  };

def expected_execution_projection($request_body; $resolved_body):
  selected_resolved_binding($request_body;$resolved_body) as $matches |
  if (($matches | length) == 1 and
      selected_binding_relation_ok($request_body.operation;$matches[0])) then
    $matches[0] as $resolved_binding |
    {
      actual_binding:projected_actual_binding($resolved_binding),
      performer:projected_performer($resolved_binding),
      environment:$request_body.environment_ref,
      used_capability:{kind:"registered",id:$request_body.operation.capability_id},
      execution_kind:$resolved_binding.binding.execution_kind,
      metadata_expectation:metadata_expectation($resolved_binding.binding)
    }
  else null
  end;

def document_shape_ok:
  if .kind == "stage_request" then stage_request_shape_ok
  else false
  end;

def document_self_ok:
  if .kind == "stage_request" then stage_request_self_ok
  else false
  end;
