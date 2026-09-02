import "profile_graph" as profile;
import "stage_request" as request;
import "result_facts" as facts;

def exact_fields($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def int_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647 and
  tostring != "-0";
def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");
def short_text_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 1024;
def media_type_ok:
  type == "string" and length <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");

def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $parts |
   ($parts.year | tonumber) as $year |
   ($parts.month | tonumber) as $month |
   ($parts.day | tonumber) as $day |
   ($parts.hour | tonumber) as $hour |
   ($parts.minute | tonumber) as $minute |
   ($parts.second | tonumber) as $second |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and
   $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and
   $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

def git_revision_ref_ok:
  exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (if .hash_algorithm == "sha1"
   then (.commit_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else (.commit_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok and (contains(":") | not) and (contains("/") | not)) and
  (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);

def document_ref_kind_ok($kind):
  exact_fields(["schema_version","kind","id","sha256"];[]) and
  .schema_version == 2 and .kind == $kind and
  (.id | id_ok) and (.sha256 | sha256_ok);

def present_ok(value_ok):
  (exact_fields(["state"];[]) and .state == "absent") or
  (exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def present($value): {state:"present",value:$value};
def absent: {state:"absent"};

def document_ref($pair):
  {
    schema_version:2,
    kind:$pair.content.kind,
    id:$pair.content.id,
    sha256:$pair.sha256
  };

def snapshot_ref($pair):
  {
    content_id:"claude-code-snapshot",
    media_type:"application/json",
    sha256:$pair.sha256
  };

def trust_shape:
  exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "adapter_trust_context" and
  (.id | id_ok) and
  (.body |
   exact_fields(
     ["binding_id","expected_attempt_id","expected_attempt_number","manifest",
      "request","resolved_profile","target_revision","verified_snapshot"];[]) and
   (.binding_id | id_ok) and
   (.expected_attempt_id | id_ok) and
   (.expected_attempt_number | int_ok) and .expected_attempt_number >= 1 and
   (.manifest | profile::document_pair_ok("adapter_manifest")) and
   (.request | profile::document_pair_ok("stage_request")) and
   (.resolved_profile | profile::document_pair_ok("resolved_profile")) and
   (.verified_snapshot |
    exact_fields(["content","sha256"];[]) and
    (.content | type == "object") and
    (.sha256 | sha256_ok)) and
   (.target_revision | git_revision_ref_ok));

def attempt_shape:
  exact_fields(
    ["attempt_id","attempt_number","finished_at","recorded_at","started_at"];[]) and
  (.attempt_id | id_ok) and
  (.attempt_number | int_ok) and .attempt_number >= 1 and
  (.started_at | time_ok) and
  (.finished_at | time_ok) and
  (.recorded_at | time_ok) and
  .started_at <= .finished_at and .finished_at <= .recorded_at;

def provider_metadata_shape:
  exact_fields(["message"];[]) and
  (.message | present_ok(short_text_ok));

def source_state_ok:
  . == "changed" or . == "no-change" or . == "failure" or
  . == "timeout" or . == "degraded" or . == "stale" or
  . == "inconclusive";

def snapshot_shape:
  exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "claude_code_producer_snapshot" and
  (.id | id_ok) and
  (.body |
   exact_fields(
     ["attempt","execution","observed_at","output","provider_metadata",
      "request_ref","resolved_profile_ref","state","target_revision"];[]) and
   (.attempt | attempt_shape) and
   (.execution | facts::execution_shape_ok) and
   (.observed_at | time_ok) and
   (.output | present_ok(content_ref_ok)) and
   (.provider_metadata | provider_metadata_shape) and
   (.request_ref | document_ref_kind_ok("stage_request")) and
   (.resolved_profile_ref |
    document_ref_kind_ok("resolved_profile")) and
   (.state | source_state_ok) and
   (.target_revision | git_revision_ref_ok) and
   .attempt.recorded_at <= .observed_at and
   (if .state == "changed" then .output.state == "present"
    else .output.state == "absent" end));

def input_shape:
  exact_fields(["snapshot","trust_context"];[]) and
  (.trust_context | trust_shape) and
  (.trust_context.body.verified_snapshot.content | snapshot_shape) and
  (.snapshot | snapshot_shape);

def selected_resolved_binding($trust):
  [$trust.body.resolved_profile.content.body.bindings[] |
   select(.binding.binding_id == $trust.body.binding_id)];

def manifest_contract_ok($manifest):
  ($manifest.content | profile::adapter_manifest_self_ok) and
  $manifest.content.id == "adapter.claude-code-producer.v1" and
  $manifest.content.body.adapter_version == "v1" and
  $manifest.content.body.offered_roles == ["producer"] and
  $manifest.content.body.offered_execution_kinds == ["model"] and
  $manifest.content.body.offered_capabilities == ["core.harness.produce.v1"] and
  $manifest.content.body.offered_permissions ==
    ["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
     "core.perm.scratch.write.v1","core.perm.target.read.v1"] and
  $manifest.content.body.offered_tools == [] and
  ($manifest.content.body | has("config_contract_ref"));

def trust_relations($trust):
  $trust.body.request as $request |
  $trust.body.resolved_profile as $resolved |
  $trust.body.manifest as $manifest |
  selected_resolved_binding($trust) as $selected |
  ($request.content | request::document_self_ok) and
  ($resolved.content | profile::resolved_profile_self_ok) and
  request::stage_request_resolved_ref_ok($request;$resolved) and
  request::stage_request_resolved_relation_ok(
    $request.content.body;$resolved.content.body) and
  manifest_contract_ok($manifest) and
  ($selected | length) == 1 and
  profile::binding_manifest_graph_ok(
    $selected[0].binding;$selected[0];$manifest) and
  $request.content.body.operation.role == "producer" and
  $request.content.body.operation.binding_id == $trust.body.binding_id and
  $request.content.body.operation.capability_id == "core.harness.produce.v1" and
  $request.content.body.target_revision == present($trust.body.target_revision) and
  $request.content.body.target_repository_id ==
    $trust.body.target_revision.repository_id and
  $selected[0].binding.execution_kind == "model" and
  $selected[0].binding.model_request.provider_id == "anthropic" and
  ($selected[0].binding | has("config_ref")) and
  ($selected[0].binding | has("prompt_ref")) and
  $selected[0].binding.requested_tools == [];

def fact_agrees($fact; $expected):
  if $fact.state == "recorded" or $fact.state == "computed"
  then $fact.value == $expected
  else $fact.state == "unavailable"
  end;

def metadata_relations($metadata; $binding):
  $metadata.kind == "model" and
  fact_agrees($metadata.provider;$binding.model_request.provider_id) and
  fact_agrees($metadata.model;$binding.model_request.model_id) and
  fact_agrees($metadata.effort;$binding.model_request.effort_id) and
  fact_agrees($metadata.prompt;$binding.prompt_ref) and
  fact_agrees($metadata.skills;$binding.skill_refs) and
  fact_agrees($metadata.tools;$binding.requested_tools) and
  fact_agrees($metadata.snapshot;"claude-code.v1");

def metadata_complete($metadata):
  [$metadata.provider,$metadata.model,$metadata.snapshot,$metadata.effort,
   $metadata.prompt,$metadata.skills,$metadata.tools] |
  all(.[];.state == "recorded" or .state == "computed");

def snapshot_relations($trust; $snapshot):
  selected_resolved_binding($trust)[0].binding as $binding |
  $trust.body.request.content.body.operation.arguments.artifact_kind as $artifact_kind |
  request::expected_execution_projection(
    $trust.body.request.content.body;
    $trust.body.resolved_profile.content.body) as $expected |
  $snapshot == $trust.body.verified_snapshot.content and
  $snapshot.body.request_ref == document_ref($trust.body.request) and
  $snapshot.body.resolved_profile_ref ==
    document_ref($trust.body.resolved_profile) and
  $snapshot.body.target_revision == $trust.body.target_revision and
  $snapshot.body.attempt.attempt_id == $trust.body.expected_attempt_id and
  $snapshot.body.attempt.attempt_number == $trust.body.expected_attempt_number and
  $trust.body.request.content.body.requested_at <=
    $snapshot.body.attempt.started_at and
  $expected != null and
  $snapshot.body.execution.actual_binding == $expected.actual_binding and
  $snapshot.body.execution.performer == $expected.performer and
  $snapshot.body.execution.environment == $expected.environment and
  $snapshot.body.execution.used_capability == $expected.used_capability and
  (if $snapshot.body.state == "changed" and $artifact_kind == "git-patch" then
     $snapshot.body.output.state == "present" and
     $snapshot.body.output.value.media_type == "text/x-diff"
   else true end) and
  metadata_relations($snapshot.body.execution.metadata;$binding);

def result_status($source_state):
  if $source_state == "stale" then "stale"
  elif $source_state == "failure" or $source_state == "timeout" or
       $source_state == "degraded" then "failed"
  else "completed"
  end;

def normalized_state($snapshot):
  if $snapshot.body.state == "stale" then "stale"
  elif (metadata_complete($snapshot.body.execution.metadata) | not) then
    "inconclusive"
  elif $snapshot.body.state == "changed" then "changed"
  elif $snapshot.body.state == "no-change" then "no-change"
  else "inconclusive"
  end;

def reason_id($snapshot; $state):
  if $state == "changed" then "adapter.changed"
  elif $state == "no-change" then "adapter.no-change"
  elif $state == "stale" then "adapter.inputs-stale"
  elif $snapshot.body.state == "failure" then "adapter.provider-failure"
  elif $snapshot.body.state == "timeout" then "adapter.provider-timeout"
  elif $snapshot.body.state == "degraded" then "adapter.provider-degraded"
  elif $snapshot.body.state == "inconclusive" then
    "adapter.provider-inconclusive"
  elif (metadata_complete($snapshot.body.execution.metadata) | not) then
    "adapter.metadata-incomplete"
  else "adapter.provider-inconclusive"
  end;

def outcome($state):
  if $state == "stale" then absent
  elif $state == "changed" then
    present({family:"change",value:"changed"})
  elif $state == "no-change" then
    present({family:"change",value:"no-change"})
  else present({family:"change",value:"inconclusive"})
  end;

def normalized_output($snapshot; $state):
  if $state == "changed" then $snapshot.body.output else absent end;

def observation($trust; $snapshot):
  selected_resolved_binding($trust)[0].binding as $binding |
  (normalized_state($snapshot)) as $state |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"claude-code-producer",version:"v1"},
    state:$state,
    reason_id:reason_id($snapshot;$state),
    trust_context:{
      snapshot_ref:snapshot_ref($trust.body.verified_snapshot),
      request_ref:document_ref($trust.body.request),
      resolved_profile_ref:document_ref($trust.body.resolved_profile),
      manifest_ref:document_ref($trust.body.manifest),
      target_revision:$trust.body.target_revision,
      binding_id:$trust.body.binding_id,
      expected_attempt_id:$trust.body.expected_attempt_id,
      expected_attempt_number:$trust.body.expected_attempt_number
    },
    observation:{
      observed_at:$snapshot.body.observed_at,
      binding:{
        adapter_implementation:
          $snapshot.body.execution.actual_binding.adapter_implementation,
        package_ref:$binding.package_ref,
        config_ref:present($binding.config_ref),
        prompt_ref:present($binding.prompt_ref),
        skill_refs:$binding.skill_refs,
        tool_refs:$binding.requested_tools,
        model_request:$binding.model_request,
        adapter_instance_id:$binding.adapter_instance_id,
        principal_id:$binding.principal_id,
        execution_boundary_id:$binding.execution_boundary_id,
        environment:$snapshot.body.execution.environment
      },
      result:{
        attempt_id:$snapshot.body.attempt.attempt_id,
        attempt_number:$snapshot.body.attempt.attempt_number,
        status:(if $state == "inconclusive" then
                  result_status($snapshot.body.state)
                else result_status($state) end),
        outcome:outcome($state),
        output_ref:normalized_output($snapshot;$state),
        started_at:$snapshot.body.attempt.started_at,
        finished_at:$snapshot.body.attempt.finished_at,
        recorded_at:$snapshot.body.attempt.recorded_at
      },
      provider_metadata:{
        source_state:$snapshot.body.state,
        message:$snapshot.body.provider_metadata.message
      }
    },
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:[]
  };

. as $input |
if ($input | input_shape | not) then error("E_SHAPE")
elif (trust_relations($input.trust_context) | not) then error("E_TRUST")
elif (snapshot_relations($input.trust_context;$input.snapshot) | not) then
  error("E_STALE")
else observation($input.trust_context;$input.snapshot)
end
