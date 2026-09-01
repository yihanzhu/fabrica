import "schema" as schema;
import "profile_graph" as profile;
import "stage_request" as request;
import "result_truth" as result;

def pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content | schema::envelope_ok($kind)) and
  (.sha256 | schema::sha256_ok);

def present_shape(value_ok):
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def core_contract_shape:
  schema::exact_fields(
    ["generation_id_sha256","package_ref","semantic_identity"];[]) and
  (.generation_id_sha256 | schema::sha256_ok) and
  (.package_ref | schema::content_ref_ok) and
  (.semantic_identity | schema::id_ok);

def attempt_value_shape:
  schema::exact_fields(
    ["attempt_id","attempt_number","deadline_at","request_ref","state"];[]) and
  (.attempt_id | schema::id_ok) and
  (.attempt_number | schema::int_ok) and .attempt_number >= 1 and
  (.deadline_at | schema::time_ok) and
  (.request_ref | schema::document_ref_kind_ok("stage_request")) and
  (.state == "dispatched" or .state == "started");

def item_shape:
  schema::exact_fields(
    ["attempt","latest_result","request","resolved_profile","retry_limit"];[]) and
  (.request | pair_shape("stage_request")) and
  (.resolved_profile | pair_shape("resolved_profile")) and
  (.latest_result | present_shape(pair_shape("stage_result"))) and
  (.attempt | present_shape(attempt_value_shape)) and
  (.retry_limit | schema::int_ok) and
  .retry_limit >= 1 and .retry_limit <= 10;

def snapshot_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["core_contract","items","observed_at","source_revision"];[]) and
   (.core_contract | core_contract_shape) and
   (.source_revision | schema::git_revision_ref_ok) and
   (.observed_at | schema::time_ok) and
   (.items | type == "array" and length >= 1 and length <= 64 and
    all(.[];item_shape)));

def expected_core:
  {
    generation_id_sha256:
      "6f6acbbd0cf40ab3c913328d6c0070635424ffe920bcdb900fbd0718345d7137",
    package_ref:{
      content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",
      sha256:"005431c5c7e3a39dc3ab75dfcafd0f09359331667fdcacb140514a4384592716"
    },
    semantic_identity:"core.contracts.v2"
  };

def stage_key:
  .request.content.body |
  [.initiative_id,.workflow_id,.stage_id,.task_class_id];

def request_ref:
  .request | profile::document_ref_for_pair(.);

def item_relation($source; $observed_at):
  . as $item |
  ($item.request.content | request::document_self_ok) and
  ($item.resolved_profile.content | profile::resolved_profile_self_ok) and
  request::stage_request_resolved_ref_ok(
    $item.request;$item.resolved_profile) and
  request::stage_request_resolved_relation_ok(
    $item.request.content.body;$item.resolved_profile.content.body) and
  $item.request.content.body.target_repository_id == $source.repository_id and
  $item.request.content.body.requested_at <= $observed_at and
  (if $item.latest_result.state == "present" then
     $item.attempt.state == "absent" and
     result::stage_run_ok(
       $item.request;$item.resolved_profile;$item.latest_result.value) and
     $item.latest_result.value.content.body.recorded_at <= $observed_at and
     $item.latest_result.value.content.body.attempt_number <= $item.retry_limit
   elif $item.attempt.state == "present" then
     $item.attempt.value.request_ref == ($item | request_ref) and
     $item.attempt.value.attempt_number <= $item.retry_limit and
     $item.request.content.body.requested_at <= $item.attempt.value.deadline_at
   else true
   end);

def set_relations:
  .body.items as $items |
  ($items | map(stage_key)) as $keys |
  ($keys == ($keys | sort)) and
  (($keys | length) == ($keys | unique | length)) and
  (($items | map(.request | profile::document_ref_for_pair(.))) as $refs |
   ($refs | length) == ($refs | unique | length)) and
  ([ $items[] |
     if .attempt.state == "present" then .attempt.value.attempt_id
     elif .latest_result.state == "present" then
       .latest_result.value.content.body.attempt_id
     else empty end ] as $attempt_ids |
   ($attempt_ids | length) == ($attempt_ids | unique | length));

def source_reason($item):
  if $item.latest_result.state == "present" and
     ($item.latest_result.value.content.body | has("reason"))
  then {state:"present",value:$item.latest_result.value.content.body.reason.reason_id}
  else {state:"absent"}
  end;

def attempt_number($item):
  if $item.latest_result.state == "present" then
    $item.latest_result.value.content.body.attempt_number
  elif $item.attempt.state == "present" then $item.attempt.value.attempt_number
  else 0
  end;

def target_moved($item; $source):
  $item.request.content.body.target_revision.state == "present" and
  $item.request.content.body.target_revision.value != $source and
  ($item.latest_result.state == "absent" or
   ($item.latest_result.value.content.body.status != "completed" and
    $item.latest_result.value.content.body.status != "skipped"));

def classification($item; $source; $observed_at):
  ($item.latest_result.value.content.body.status // null) as $status |
  (attempt_number($item)) as $attempt_number |
  (source_reason($item)) as $source_reason |
  (if target_moved($item;$source) then
     ["stale","refresh-stage-inputs","scanner.target-revision-moved"]
   elif $status == "completed" then
     ["terminal","none","scanner.stage-completed"]
   elif $status == "skipped" then
     ["terminal","none","scanner.stage-skipped"]
   elif $status == "stale" then
     ["stale","refresh-stage-inputs","scanner.stage-stale"]
   elif $status == "blocked" then
     ["blocked","resolve-stage-blocker","scanner.stage-blocked"]
   elif $status == "failed" or $status == "cancelled" then
     if $attempt_number < $item.retry_limit then
       ["retryable","retry-stage","scanner.stage-" + $status]
     else ["blocked","operator-reconcile","scanner.retry-limit-reached"]
     end
   elif $item.attempt.state == "present" and
        $item.attempt.value.deadline_at <= $observed_at then
     ["stranded","recover-stranded-attempt","scanner.attempt-deadline-reached"]
   elif $item.attempt.state == "present" then
     ["pending","wait-for-attempt","scanner.attempt-in-flight"]
   else ["pending","dispatch-stage","scanner.no-attempt"]
   end) as $decision |
  {
    stage_key:{
      initiative_id:$item.request.content.body.initiative_id,
      workflow_id:$item.request.content.body.workflow_id,
      stage_id:$item.request.content.body.stage_id,
      task_class_id:$item.request.content.body.task_class_id
    },
    class:$decision[0],
    recovery:{
      action:$decision[1],
      reason_id:$decision[2],
      source_reason_id:$source_reason,
      attempt_number:$attempt_number,
      retry_limit:$item.retry_limit
    }
  };

. as $snapshot |
if (snapshot_shape | not) then "E_SHAPE"
elif $snapshot.body.core_contract != expected_core then "E_STALE"
elif $snapshot.body.source_revision.repository_id != $expected_repository_id or
     $snapshot.body.source_revision.commit_id != $expected_commit_id then "E_STALE"
elif (all($snapshot.body.items[];
          item_relation(
            $snapshot.body.source_revision;$snapshot.body.observed_at)) | not)
then "E_RELATION"
elif ($snapshot | set_relations | not) then "E_RELATION"
else {
  schema_version:1,
  kind:"orchestrator_state_observation",
  id:$snapshot.id,
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    mode:"observation-only",
    core_contract:$snapshot.body.core_contract,
    source_revision:$snapshot.body.source_revision,
    observed_at:$snapshot.body.observed_at,
    classifications:[
      $snapshot.body.items[] |
      classification(.;$snapshot.body.source_revision;$snapshot.body.observed_at)
    ]
  }
}
end
