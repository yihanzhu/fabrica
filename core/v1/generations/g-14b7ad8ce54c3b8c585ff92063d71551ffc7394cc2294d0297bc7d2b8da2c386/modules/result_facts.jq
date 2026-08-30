import "schema" as schema;
import "profile_graph" as profile_graph;
import "stage_request" as stage_request;

def optional_ok($name; value_ok):
  (has($name) | not) or (.[$name] | value_ok);

def actual_binding_shape_ok:
  schema::exact_fields(
    ["binding_id","role","adapter_implementation","manifest_ref","package_ref",
     "config_ref","execution_kind","adapter_instance_id","principal_id",
     "execution_boundary_id"];
    ["authority_ref"]) and
  (.binding_id | schema::id_ok) and
  (.role | schema::adapter_role_ok) and
  (.adapter_implementation |
   schema::exact_fields(["id","version"];[]) and
   (.id | schema::id_ok) and
   (.version | schema::version_ok)) and
  (.manifest_ref | schema::document_ref_kind_ok("adapter_manifest")) and
  (.package_ref | schema::git_object_ref_ok) and
  (.config_ref | schema::present_ok(schema::git_object_ref_ok)) and
  (.execution_kind | schema::execution_kind_ok) and
  (.adapter_instance_id | schema::id_ok) and
  (.principal_id | schema::id_ok) and
  (.execution_boundary_id | schema::id_ok) and
  optional_ok("authority_ref";schema::scope_ref_purpose_ok("authority"));

def observed_capability_shape_ok:
  schema::exact_fields(["kind","id"];[]) and
  (if .kind == "registered" then
     (.id | schema::capability_id_ok)
   elif .kind == "unclassified" then
     (.id | schema::id_ok) and
     (.id as $id | schema::capability_ids | index($id) == null)
   else false
   end);

def fact_shape_ok(value_ok):
  type == "object" and
  (if .state == "recorded" or .state == "computed" then
     schema::exact_fields(["state","value","source_ref"];[]) and
     (.value | value_ok) and
     (.source_ref | schema::content_ref_ok)
   elif .state == "unavailable" then
     schema::exact_fields(["state","reason_id"];[]) and
     (.reason_id | schema::id_ok)
   elif .state == "not-applicable" then
     schema::exact_fields(["state"];[])
   else false
   end);

def factual_or_unavailable:
  type == "object" and
  (.state == "recorded" or .state == "computed" or .state == "unavailable");

def execution_metadata_shape_ok:
  schema::exact_fields(
    ["kind","provider","model","snapshot","effort","prompt","skills","tools"];
    []) and
  (.kind | schema::execution_kind_ok) and
  (.provider | fact_shape_ok(schema::id_ok)) and
  (.model | fact_shape_ok(schema::id_ok)) and
  (.snapshot | fact_shape_ok(schema::id_ok)) and
  (.effort | fact_shape_ok(schema::id_ok)) and
  (.prompt | fact_shape_ok(schema::git_object_ref_ok)) and
  (.skills |
   fact_shape_ok(schema::bounded_set(0;32;schema::git_object_ref_ok;schema::git_key))) and
  (.tools |
   fact_shape_ok(schema::bounded_set(0;32;schema::tool_ref_ok;.tool_id))) and
  .tools.state != "not-applicable" and
  (if .kind == "deterministic" then
     [.provider,.model,.snapshot,.effort,.prompt,.skills] |
     all(.[];.state == "not-applicable")
   else
     [.provider,.model,.snapshot,.effort,.prompt,.skills] |
     all(.[];factual_or_unavailable)
   end);

def execution_shape_ok:
  schema::exact_fields(
    ["performer","actual_binding","environment","used_capability","metadata"];
    []) and
  (.performer | schema::actor_ref_ok) and
  (.actual_binding | actual_binding_shape_ok) and
  (.environment | schema::environment_ref_ok) and
  (.used_capability | observed_capability_shape_ok) and
  (.metadata | execution_metadata_shape_ok) and
  .metadata.kind == .actual_binding.execution_kind and
  .performer.role == .actual_binding.role;

def stage_result_facts_shape_ok:
  type == "object" and
  (if has("execution") then (.execution | execution_shape_ok) else true end);

def fact_matches($fact; $expected):
  if $fact.state == "recorded" or $fact.state == "computed" then
    $fact.value == $expected
  else $fact.state == "unavailable"
  end;

def used_tools_match($fact; $allowed):
  if $fact.state == "recorded" or $fact.state == "computed" then
    all($fact.value[];. as $tool | $allowed | index($tool) != null)
  else $fact.state == "unavailable"
  end;

def metadata_matches_projection($metadata; $projection):
  $metadata.kind == $projection.execution_kind and
  used_tools_match($metadata.tools;$projection.metadata_expectation.allowed_tools) and
  (if $projection.execution_kind == "model" then
     $projection.metadata_expectation.model_request.value as $model_request |
     fact_matches($metadata.provider;$model_request.provider_id) and
     fact_matches($metadata.model;$model_request.model_id) and
     fact_matches($metadata.effort;$model_request.effort_id) and
     fact_matches($metadata.prompt;$projection.metadata_expectation.prompt_ref.value) and
     fact_matches($metadata.skills;$projection.metadata_expectation.skill_refs)
   else true
   end);

def execution_matches_projection($execution; $projection):
  $projection != null and
  $execution.actual_binding == $projection.actual_binding and
  $execution.performer == $projection.performer and
  $execution.environment == $projection.environment and
  $execution.used_capability == $projection.used_capability and
  metadata_matches_projection($execution.metadata;$projection);

def incident_execution_allowed($result_body):
  $result_body.status == "failed" or
  $result_body.status == "cancelled" or
  ($result_body.status == "completed" and
   ($result_body | has("outcome")) and
   $result_body.outcome.value == "inconclusive");

def stage_result_execution_relation_ok($request_body; $resolved_body; $result_body):
  if ($result_body | has("execution") | not) then true
  elif ($result_body.execution | execution_shape_ok | not) then false
  else
    stage_request::expected_execution_projection($request_body;$resolved_body) as $projection |
    $projection != null and
    (if $result_body.execution.used_capability.kind == "unclassified" then
       incident_execution_allowed($result_body)
     elif incident_execution_allowed($result_body) then true
     else execution_matches_projection($result_body.execution;$projection)
     end)
  end;

def document_shape_ok:
  .kind == "stage_result" and
  (.body | stage_result_facts_shape_ok);
