import "schema" as schema;
import "profile_graph" as profile_graph;
import "stage_request" as stage_request;
import "result_facts" as result_facts;

def optional_ok($name; value_ok):
  (has($name) | not) or (.[$name] | value_ok);

def outcome_shape_ok:
  schema::exact_fields(["family","value"];[]) and
  (if .family == "change" then
     .value == "changed" or .value == "no-change" or .value == "inconclusive"
   elif .family == "check" then
     .value == "passed" or .value == "failed" or .value == "inconclusive"
   else false
   end);

def reason_shape_ok:
  schema::exact_fields(["reason_id"];["summary"]) and
  (.reason_id | schema::id_ok) and
  optional_ok("summary";schema::short_text_ok);

def output_shape_ok:
  schema::exact_fields(["output_id","ref"];[]) and
  (.output_id | schema::id_ok) and
  (.ref | schema::content_ref_ok);

def evidence_shape_ok:
  schema::exact_fields(["evidence_id","kind","verdict","proof_ref"];[]) and
  (.evidence_id | schema::id_ok) and
  (.kind | schema::evidence_kind_ok) and
  (.verdict as $verdict | schema::evidence_verdicts | index($verdict) != null) and
  (.proof_ref | schema::content_ref_ok);

def stale_selector_shape_ok:
  type == "object" and
  (if .kind == "target" or .kind == "source" or .kind == "base" or
      .kind == "resolved-profile" or .kind == "qualification" or
      .kind == "environment" then
     schema::exact_fields(["kind"];[])
   elif .kind == "input" then
     schema::exact_fields(["kind","input_id"];[]) and
     (.input_id | schema::id_ok)
   elif .kind == "gate-decision" then
     schema::exact_fields(["kind","scope_sha256"];[]) and
     (.scope_sha256 | schema::sha256_ok)
   else false
   end);

def stale_observed_shape_ok($kind):
  if $kind == "target" or $kind == "base" then
    schema::present_ok(schema::git_revision_ref_ok)
  elif $kind == "source" then
    schema::present_ok(schema::artifact_ref_ok)
  elif $kind == "resolved-profile" then
    schema::present_ok(schema::document_ref_kind_ok("resolved_profile"))
  elif $kind == "qualification" then
    schema::present_ok(schema::scope_ref_purpose_ok("qualification"))
  elif $kind == "environment" then
    schema::present_ok(schema::environment_ref_ok)
  elif $kind == "input" then
    schema::present_ok(schema::input_ref_ok)
  elif $kind == "gate-decision" then
    schema::present_ok(schema::scope_ref_purpose_ok("gate-decision"))
  else false
  end;

def stale_observation_shape_ok:
  schema::exact_fields(["selector","observed"];[]) and
  (.selector | stale_selector_shape_ok) and
  (.selector.kind as $kind | .observed | stale_observed_shape_ok($kind));

def stale_selector_key:
  [.selector.kind,
   (.selector.input_id // .selector.scope_sha256 // "")];

def stage_result_body_shape_ok:
  schema::exact_fields(
    ["request_ref","resolved_profile_ref","attempt_id","attempt_number",
     "reported_by","status","outputs","diagnostics","evidence","recorded_at"];
    ["outcome","reason","stale_observations","delta_ref","execution",
     "started_at","finished_at"]) and
  (.request_ref | schema::document_ref_kind_ok("stage_request")) and
  (.resolved_profile_ref |
   schema::document_ref_kind_ok("resolved_profile")) and
  (.attempt_id | schema::id_ok) and
  (.attempt_number | schema::int_ok) and
  .attempt_number >= 1 and
  (.reported_by | schema::actor_ref_ok) and
  (.status == "completed" or .status == "skipped" or .status == "stale" or
   .status == "blocked" or .status == "failed" or .status == "cancelled") and
  optional_ok("outcome";outcome_shape_ok) and
  optional_ok("reason";reason_shape_ok) and
  optional_ok("stale_observations";
    schema::bounded_set(1;256;stale_observation_shape_ok;stale_selector_key)) and
  (.outputs | schema::bounded_set(0;256;output_shape_ok;.output_id)) and
  optional_ok("delta_ref";schema::git_patch_ref_ok) and
  (.diagnostics |
   schema::bounded_set(0;256;schema::content_ref_ok;.content_id)) and
  (.evidence |
   schema::bounded_set(0;256;evidence_shape_ok;.evidence_id)) and
  ((.evidence | map(.kind) | unique | length) == (.evidence | length)) and
  optional_ok("started_at";schema::time_ok) and
  optional_ok("finished_at";schema::time_ok) and
  (.recorded_at | schema::time_ok) and
  result_facts::stage_result_facts_shape_ok;

def status_presence_ok:
  .status as $status |
  if $status == "completed" then
    has("execution") and has("outcome") and has("started_at") and
    has("finished_at") and .diagnostics == [] and
    (has("stale_observations") | not) and
    ((.outcome.value == "inconclusive") == has("reason"))
  elif $status == "skipped" then
    has("reason") and .outputs == [] and .diagnostics == [] and .evidence == [] and
    (has("outcome") | not) and (has("stale_observations") | not) and
    (has("delta_ref") | not) and (has("execution") | not) and
    (has("started_at") | not) and (has("finished_at") | not)
  elif $status == "stale" then
    has("reason") and has("stale_observations") and .outputs == [] and
    .diagnostics == [] and .evidence == [] and (has("outcome") | not) and
    (has("delta_ref") | not) and (has("execution") | not) and
    (has("started_at") | not) and (has("finished_at") | not)
  elif $status == "blocked" then
    has("reason") and .outputs == [] and .evidence == [] and
    (has("outcome") | not) and (has("stale_observations") | not) and
    (has("delta_ref") | not) and (has("execution") | not) and
    (has("started_at") | not) and (has("finished_at") | not)
  elif $status == "failed" or $status == "cancelled" then
    has("reason") and .outputs == [] and (has("delta_ref") | not) and
    (has("stale_observations") | not) and
    (if $status == "failed" then (.diagnostics | length) > 0 else true end) and
    (if has("execution") then
       has("outcome") and .outcome.value == "inconclusive" and
       has("started_at") and has("finished_at") and
       (.evidence | length) > 0 and
       all(.evidence[];.verdict == "failed" or .verdict == "inconclusive")
     else
       (has("outcome") | not) and .evidence == [] and
       (has("started_at") | not) and (has("finished_at") | not)
     end)
  else false
  end;

def local_time_order_ok:
  if has("execution") then
    .started_at <= .finished_at and .finished_at <= .recorded_at
  else true
  end;

def stage_result_self_ok:
  stage_result_body_shape_ok and status_presence_ok and local_time_order_ok;

def expected_stale_value($request; $observation):
  $observation.selector as $selector |
  if $selector.kind == "target" then $request.target_revision
  elif $selector.kind == "source" then $request.source
  elif $selector.kind == "base" then $request.base
  elif $selector.kind == "resolved-profile" then
    {state:"present",value:$request.resolved_profile_ref}
  elif $selector.kind == "qualification" then
    if $request | has("qualification_ref")
    then {state:"present",value:$request.qualification_ref}
    else {state:"absent"}
    end
  elif $selector.kind == "environment" then
    {state:"present",value:$request.environment_ref}
  elif $selector.kind == "input" then
    [$request.inputs[] | select(.input_id == $selector.input_id)] as $matches |
    if ($matches | length) == 1
    then {state:"present",value:$matches[0].value}
    else null
    end
  elif $selector.kind == "gate-decision" then
    [$request.gate_decision_refs[] |
     select(.scope_sha256 == $selector.scope_sha256)] as $matches |
    if ($matches | length) == 1
    then {state:"present",value:$matches[0]}
    else null
    end
  else null
  end;

def observed_repository_ok($request; $observation; $expected):
  $observation.selector.kind as $kind |
  $observation.observed as $observed |
  if $observed.state == "absent" then true
  elif $kind == "target" then
    $observed.value.repository_id == $request.target_repository_id
  elif $kind == "base" then
    $observed.value.repository_id == $request.target_repository_id and
    (if $expected.state == "present" then
       $observed.value.hash_algorithm == $expected.value.hash_algorithm
     else true
     end)
  elif $kind == "source" and $observed.value.type == "git-object" then
    $observed.value.value.revision.repository_id == $request.target_repository_id
  else true
  end;

def observed_identity_ok($request; $observation):
  $observation.selector.kind as $kind |
  $observation.observed as $observed |
  if $observed.state == "absent" then true
  elif $kind == "resolved-profile" then
    $observed.value.kind == "resolved_profile" and
    $observed.value.id == $request.resolved_profile_ref.id
  elif $kind == "environment" then
    $observed.value.environment_id == $request.environment_ref.environment_id
  else true
  end;

def stale_observation_relation_ok($request; $observation):
  expected_stale_value($request;$observation) as $expected |
  $expected != null and $observation.observed != $expected and
  observed_repository_ok($request;$observation;$expected) and
  observed_identity_ok($request;$observation);

def refs_relation_ok($request_pair; $resolved_pair; $result):
  $result.request_ref == profile_graph::document_ref_for_pair($request_pair) and
  $result.resolved_profile_ref ==
    profile_graph::document_ref_for_pair($resolved_pair) and
  $request_pair.content.body.resolved_profile_ref ==
    profile_graph::document_ref_for_pair($resolved_pair);

def requested_time_floor_ok($request; $result):
  if $result | has("execution") then
    $request.requested_at <= $result.started_at
  else $request.requested_at <= $result.recorded_at
  end;

def evidence_kinds_allowed($request; $result):
  ($request.required_evidence_kinds) as $requested |
  all($result.evidence[];.kind as $kind | $requested | index($kind) != null);

def completed_evidence_exact($request; $result):
  ($result.evidence | map(.kind) | sort) ==
    ($request.required_evidence_kinds | sort);

def requested_fact_gap($result):
  if $result | has("execution") then
    $result.execution.metadata as $metadata |
    [$metadata.provider,$metadata.model,$metadata.effort,$metadata.prompt,
     $metadata.skills,$metadata.tools] |
    any(.[];.state == "unavailable")
  else false
  end;

def producer_outcome_ok($operation; $result):
  ($result.evidence | any(.[];.verdict != "passed")) as $nonpassing |
  requested_fact_gap($result) as $fact_gap |
  ($result.outputs | length) as $output_count |
  if $nonpassing or $fact_gap then
    $result.outcome == {family:"change",value:"inconclusive"} and
    $result.outputs == [] and ($result | has("delta_ref") | not)
  elif $output_count == 0 then
    $result.outcome == {family:"change",value:"no-change"} and
    ($result | has("delta_ref") | not)
  elif $output_count == 1 then
    $result.outcome == {family:"change",value:"changed"} and
    (if $operation.arguments | has("allowed_delta") then
       ($result | has("delta_ref")) and
       $result.delta_ref == $result.outputs[0].ref
     else ($result | has("delta_ref") | not)
     end)
  else false
  end;

def forge_outcome_ok($operation; $result):
  ($result.evidence | any(.[];.verdict != "passed")) as $nonpassing |
  requested_fact_gap($result) as $fact_gap |
  ($result.outputs | length) as $output_count |
  if $nonpassing or $fact_gap then
    $result.outcome == {family:"change",value:"inconclusive"} and
    $result.outputs == [] and ($result | has("delta_ref") | not)
  elif $output_count == 0 then
    $result.outcome == {family:"change",value:"no-change"} and
    ($result | has("delta_ref") | not)
  elif $output_count == 1 then
    $result.outcome == {family:"change",value:"changed"} and
    $result.outputs[0].output_id ==
      $operation.arguments.candidate_output_id and
    $result.outputs[0].ref.media_type == "application/json" and
    ($result | has("delta_ref") | not)
  else false
  end;

def check_outcome_ok($result):
  ($result.evidence | any(.[];.verdict == "failed")) as $failed |
  ($result.evidence | any(.[];.verdict == "inconclusive")) as $inconclusive |
  requested_fact_gap($result) as $fact_gap |
  $result.outputs == [] and ($result | has("delta_ref") | not) and
  (if $failed then
     $result.outcome == {family:"check",value:"failed"}
   elif $inconclusive or $fact_gap then
     $result.outcome == {family:"check",value:"inconclusive"}
   else $result.outcome == {family:"check",value:"passed"}
   end);

def completed_outcome_ok($request; $result):
  if $request.operation.capability_id ==
     "core.forge.materialize-candidate.v2" then
    forge_outcome_ok($request.operation;$result)
  elif $request.operation.role == "producer" then
    producer_outcome_ok($request.operation;$result)
  elif $request.operation.role == "verifier" or
       $request.operation.role == "reviewer" then
    check_outcome_ok($result)
  else false
  end;

def passing_review_identity_ok($request; $result):
  all($result.evidence[];
      if .kind == "independent-review" and .verdict == "passed" then
        $result.execution.performer.role == "reviewer" and
        $result.execution.used_capability ==
          {kind:"registered",id:"core.review.change.v1"} and
        $request.operation.role == "reviewer"
      else true
      end);

def passing_evidence_execution_ok($request; $resolved; $result):
  if any($result.evidence[];.verdict == "passed") then
    ($result | has("execution")) and
    stage_request::expected_execution_projection($request;$resolved) as $projection |
    result_facts::execution_matches_projection($result.execution;$projection)
  else true
  end;

def status_external_relation_ok($request; $result):
  schema::outcome_family_for_capability(
    $request.operation.capability_id) as $outcome_family |
  if $result.status == "completed" then
    completed_evidence_exact($request;$result) and
    completed_outcome_ok($request;$result) and
    passing_review_identity_ok($request;$result)
  elif ($result.status == "failed" or $result.status == "cancelled") and
       ($result | has("execution")) then
    $result.outcome == {
      family:$outcome_family,
      value:"inconclusive"
    }
  else true
  end;

def stage_result_relation_ok($request_pair; $resolved_pair; $result):
  refs_relation_ok($request_pair;$resolved_pair;$result) and
  requested_time_floor_ok($request_pair.content.body;$result) and
  evidence_kinds_allowed($request_pair.content.body;$result) and
  (if $result.status == "stale" then
     all($result.stale_observations[];
         stale_observation_relation_ok($request_pair.content.body;.))
   else true
   end) and
  status_external_relation_ok($request_pair.content.body;$result) and
  passing_evidence_execution_ok(
    $request_pair.content.body;$resolved_pair.content.body;$result) and
  result_facts::stage_result_execution_relation_ok(
    $request_pair.content.body;$resolved_pair.content.body;$result);

def document_shape_ok:
  .kind == "stage_result" and schema::envelope_ok("stage_result") and
  (.body | stage_result_body_shape_ok);

def document_self_ok:
  document_shape_ok and (.body | stage_result_self_ok);

def stage_run_ok($request_pair; $resolved_pair; $result_pair):
  ($request_pair | profile_graph::document_pair_ok("stage_request")) and
  ($resolved_pair | profile_graph::document_pair_ok("resolved_profile")) and
  ($result_pair | profile_graph::document_pair_ok("stage_result")) and
  ($request_pair.content | stage_request::document_self_ok) and
  ($result_pair.content | document_self_ok) and
  stage_result_relation_ok(
    $request_pair;$resolved_pair;$result_pair.content.body);
