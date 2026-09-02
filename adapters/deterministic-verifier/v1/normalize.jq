import "schema" as schema;
import "profile_graph" as profile;
import "stage_request" as request;
import "result_truth" as result;

def absent: {state:"absent"};
def present($value): {state:"present",value:$value};

def document_ref($pair):
  {
    schema_version:2,
    kind:$pair.content.kind,
    id:$pair.content.id,
    sha256:$pair.sha256
  };

def snapshot_ref($pair):
  {
    content_id:"deterministic-verifier-snapshot",
    media_type:"application/json",
    sha256:$pair.sha256
  };

def snapshot_shape_ok:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "deterministic_verifier_snapshot" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(["observed_at","result"];[]) and
   (.observed_at | schema::time_ok) and
   (.result | profile::document_pair_ok("stage_result")));

def verified_snapshot_pair_ok:
  schema::exact_fields(["content","sha256"];[]) and
  (.content | snapshot_shape_ok) and (.sha256 | schema::sha256_ok);

def trust_context_shape_ok:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "adapter_trust_context" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["binding_id","expected_attempt_id","expected_attempt_number","manifest",
      "request","resolved_profile","verified_result","verified_snapshot"];
     []) and
   (.binding_id | schema::id_ok) and
   (.expected_attempt_id | schema::id_ok) and
   (.expected_attempt_number | schema::int_ok) and
   .expected_attempt_number >= 1 and
   (.manifest | profile::document_pair_ok("adapter_manifest")) and
   (.request | profile::document_pair_ok("stage_request")) and
   (.resolved_profile | profile::document_pair_ok("resolved_profile")) and
   (.verified_result | profile::document_pair_ok("stage_result")) and
   (.verified_snapshot | verified_snapshot_pair_ok));

def input_shape_ok:
  schema::exact_fields(["snapshot","trust_context"];[]) and
  (.trust_context | trust_context_shape_ok) and
  (.snapshot | snapshot_shape_ok);

def selected_binding($trust):
  [$trust.body.resolved_profile.content.body.bindings[] |
   select(.binding.binding_id == $trust.body.binding_id)];

def manifest_contract_ok:
  profile::adapter_manifest_self_ok and
  .id == "adapter.deterministic-verifier.v1" and
  .body.adapter_version == "v1" and
  .body.offered_roles == ["verifier"] and
  .body.offered_execution_kinds == ["deterministic"] and
  .body.offered_capabilities == ["core.verify.run.v1"] and
  .body.offered_permissions ==
    ["core.perm.candidate.execute.v1","core.perm.evidence.write.v1",
     "core.perm.target.read.v1"] and
  .body.offered_tools == [] and
  (.body | has("config_contract_ref") | not);

def binding_ceiling_ok:
  .role == "verifier" and .execution_kind == "deterministic" and
  .requested_capabilities == ["core.verify.run.v1"] and
  .requested_permissions ==
    ["core.perm.candidate.execute.v1","core.perm.evidence.write.v1",
     "core.perm.target.read.v1"] and
  .requested_tools == [] and .skill_refs == [] and
  (has("config_ref") | not) and (has("prompt_ref") | not) and
  (has("model_request") | not);

def trust_relations_ok($trust):
  $trust.body.request as $request_pair |
  $trust.body.resolved_profile as $resolved_pair |
  $trust.body.manifest as $manifest_pair |
  selected_binding($trust) as $selected |
  ($request_pair.content | request::document_self_ok) and
  ($resolved_pair.content | profile::resolved_profile_self_ok) and
  request::stage_request_resolved_ref_ok($request_pair;$resolved_pair) and
  request::stage_request_resolved_relation_ok(
    $request_pair.content.body;$resolved_pair.content.body) and
  ($manifest_pair.content | manifest_contract_ok) and
  ($selected | length) == 1 and
  ($selected[0].binding | binding_ceiling_ok) and
  profile::binding_manifest_graph_ok(
    $selected[0].binding;$selected[0];$manifest_pair) and
  $request_pair.content.body.operation.role == "verifier" and
  $request_pair.content.body.operation.binding_id == $trust.body.binding_id and
  $request_pair.content.body.operation.capability_id == "core.verify.run.v1" and
  $request_pair.content.body.operation.arguments.network_mode == "deny";

def snapshot_relations_ok($trust; $snapshot):
  $snapshot == $trust.body.verified_snapshot.content and
  $snapshot.body.result == $trust.body.verified_result and
  $snapshot.body.result.content.body.attempt_id ==
    $trust.body.expected_attempt_id and
  $snapshot.body.result.content.body.attempt_number ==
    $trust.body.expected_attempt_number and
  result::stage_run_ok(
    $trust.body.request;$trust.body.resolved_profile;$snapshot.body.result) and
  (if $snapshot.body.result.content.body | has("execution") then
     $snapshot.body.result.content.body.reported_by ==
       $snapshot.body.result.content.body.execution.performer
   else true end) and
  $snapshot.body.result.content.body.recorded_at <= $snapshot.body.observed_at;

def normalized_state($body):
  if $body.status == "completed" then $body.outcome.value
  else $body.status
  end;

def normalized_reason($body):
  if $body.status == "completed" then
    if $body.outcome.value == "passed" then "verifier.passed"
    elif $body.outcome.value == "failed" then "verifier.failed"
    else "verifier.inconclusive"
    end
  elif $body.status == "stale" then "verifier.inputs-stale"
  elif $body.status == "failed" then "verifier.stage-failed"
  elif $body.status == "cancelled" then "verifier.stage-cancelled"
  elif $body.status == "blocked" then "verifier.stage-blocked"
  else "verifier.stage-skipped"
  end;

def candidate_input($request_body):
  [$request_body.inputs[] |
   select(.input_id == $request_body.operation.arguments.candidate_input_id)][0];

def observation($trust; $snapshot):
  $trust.body.request.content.body as $request_body |
  $snapshot.body.result.content.body as $result_body |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"adapter.deterministic-verifier.v1",version:"v1",status:"inactive"},
    state:normalized_state($result_body),
    reason_id:normalized_reason($result_body),
    trust_context:{
      snapshot_ref:snapshot_ref($trust.body.verified_snapshot),
      manifest_ref:document_ref($trust.body.manifest),
      request_ref:document_ref($trust.body.request),
      resolved_profile_ref:document_ref($trust.body.resolved_profile),
      binding_id:$trust.body.binding_id,
      expected_attempt_id:$trust.body.expected_attempt_id,
      expected_attempt_number:$trust.body.expected_attempt_number
    },
    observation:{
      observed_at:$snapshot.body.observed_at,
      target_revision:$request_body.target_revision.value,
      candidate_input:candidate_input($request_body),
      verification_plan:$request_body.operation.arguments.verification_plan,
      result:{
        result_ref:document_ref($snapshot.body.result),
        attempt_id:$result_body.attempt_id,
        attempt_number:$result_body.attempt_number,
        status:$result_body.status,
        outcome:(if $result_body | has("outcome")
                 then present($result_body.outcome) else absent end),
        reason:(if $result_body | has("reason")
                then present($result_body.reason) else absent end),
        evidence:$result_body.evidence,
        recorded_at:$result_body.recorded_at
      }
    },
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:[]
  };

. as $input |
if ($input | input_shape_ok | not) then error("E_SHAPE")
elif (trust_relations_ok($input.trust_context) | not) then error("E_TRUST")
elif (snapshot_relations_ok($input.trust_context;$input.snapshot) | not) then
  error("E_RESULT")
else observation($input.trust_context;$input.snapshot)
end
