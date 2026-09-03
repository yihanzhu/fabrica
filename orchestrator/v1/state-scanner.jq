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

def expected_core:
  {
    generation_id_sha256:
      "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
    package_ref:{
      content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",
      sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"
    },
    semantic_identity:"core.contracts.v2"
  };

def expected_core_closure:
  [
    {path:"core/v2/generation-registry.json",
     sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",
     sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",
     sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",
     sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",
     sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",
     sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",
     sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",
     sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
    {path:"scripts/core-contract.sh",
     sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
  ];

def ref_shape($content_id; $media_type):
  schema::content_ref_ok and
  .content_id == $content_id and .media_type == $media_type;

def evaluator_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and
  .kind == "orchestrator_state_scanner_evaluator" and
  .id == "orchestrator.state-scanner.v1" and
  (.body |
   schema::exact_fields(
     ["bootstrap_ref","core_closure","core_contract","driver_ref",
      "launcher_ref","program_ref","runtime"];[]) and
   .core_contract == expected_core and
   .core_closure == expected_core_closure and
   (.bootstrap_ref |
    ref_shape("orchestrator-state-scanner-bootstrap.v1";"text/x-shellscript")) and
   (.launcher_ref |
    ref_shape("orchestrator-state-scanner-launcher.v1";"text/x-shellscript")) and
   (.driver_ref |
    ref_shape("orchestrator-state-scanner-driver.v1";"text/x-shellscript")) and
   (.program_ref |
    ref_shape("orchestrator-state-scanner-program.v1";"text/x-jq")) and
   (.runtime |
    schema::exact_fields(
      ["execution_mode","host_architecture","host_os","jq_architecture",
       "jq_ref","shell_ref"];[]) and
    (.jq_ref | ref_shape("jq-runtime.v1";"application/x-executable")) and
    (.shell_ref | ref_shape("bash-runtime";"application/x-executable")) and
    ((.host_os == "linux" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44") or
     (.host_os == "darwin" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef") or
     (.host_os == "darwin" and .host_architecture == "arm64" and
      .jq_architecture == "x86_64" and .execution_mode == "rosetta" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"))));

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
  . as $snapshot |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
  (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["core_contract","items","observed_at","snapshot_contract",
      "source_revision"];[]) and
   (.core_contract | type == "object") and
   (.source_revision | schema::git_revision_ref_ok) and
   (.observed_at | schema::time_ok) and
   (.items | type == "array" and length <= 64 and all(.[];item_shape)) and
   (.snapshot_contract |
    schema::exact_fields(
      ["completeness","declared_item_count","maximum_item_count",
       "schema_identity"];[]) and
    .completeness == "complete" and
    .schema_identity == "orchestrator.state-snapshot.v1" and
    .maximum_item_count == 64 and
    (.declared_item_count | schema::int_ok) and
    .declared_item_count == ($snapshot.body.items | length)));

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

def set_relations($snapshot):
  $snapshot.body.items as $items |
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
  $item.request.content.body.target_revision.value != $source;

def snapshot_ref($snapshot; $snapshot_sha):
  {
    schema_identity:$snapshot.body.snapshot_contract.schema_identity,
    kind:$snapshot.kind,
    id:$snapshot.id,
    sha256:$snapshot_sha
  };

def evaluator_ref($evaluator_sha):
  {
    content_id:"orchestrator-state-scanner-evaluator.v1",
    media_type:"application/vnd.ystack.orchestrator-state-scanner-evaluator+json",
    sha256:$evaluator_sha
  };

def item_ref($item_sha):
  {schema_identity:"orchestrator.state-item.v1",sha256:$item_sha};

def classification(
    $item; $item_sha; $source; $observed_at; $snapshot_ref; $evaluator_ref):
  ($item.latest_result.value.content.body.status // null) as $status |
  (attempt_number($item)) as $attempt_number |
  (source_reason($item)) as $source_reason |
  (if $status == "completed" then
     ["terminal","none","scanner.stage-completed"]
   elif $status == "skipped" then
     ["terminal","none","scanner.stage-skipped"]
   elif $status == "cancelled" then
     ["terminal","none","scanner.stage-cancelled"]
   elif target_moved($item;$source) then
     ["stale","refresh-stage-inputs","scanner.target-revision-moved"]
   elif $status == "stale" then
     ["stale","refresh-stage-inputs","scanner.stage-stale"]
   elif $status == "blocked" then
     ["blocked","resolve-stage-blocker","scanner.stage-blocked"]
   elif $status == "failed" then
     if $attempt_number < $item.retry_limit then
       ["retryable","retry-stage","scanner.stage-failed"]
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
    provenance:{
      snapshot_ref:$snapshot_ref,
      evaluator_ref:$evaluator_ref,
      item_ref:item_ref($item_sha),
      request_ref:($item.request | profile::document_ref_for_pair(.)),
      resolved_profile_ref:
        ($item.resolved_profile | profile::document_ref_for_pair(.)),
      latest_result_ref:
        (if $item.latest_result.state == "present" then
           {state:"present",value:
             ($item.latest_result.value | profile::document_ref_for_pair(.))}
         else {state:"absent"} end),
      active_attempt:$item.attempt
    },
    recovery:{
      action:$decision[1],
      reason_id:$decision[2],
      source_reason:$source_reason,
      attempt_number:$attempt_number,
      retry_limit:$item.retry_limit
    }
  };

def observation($snapshot; $snapshot_sha; $item_shas; $evaluator; $evaluator_sha):
  (snapshot_ref($snapshot;$snapshot_sha)) as $snapshot_ref |
  (evaluator_ref($evaluator_sha)) as $evaluator_ref |
  {
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
      snapshot_ref:$snapshot_ref,
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      classifications:[
        range(0;($snapshot.body.items | length)) as $index |
        classification(
          $snapshot.body.items[$index];$item_shas[$index];
          $snapshot.body.source_revision;$snapshot.body.observed_at;
          $snapshot_ref;$evaluator_ref)
      ]
    }
  };

def evaluate($snapshot; $snapshot_sha; $item_shas; $evaluator; $evaluator_sha):
  if (($snapshot | snapshot_shape) | not) then "E_SHAPE"
  elif $snapshot.body.core_contract != expected_core then "E_STALE"
  elif ($item_shas | type) != "array" or
       ($item_shas | length) != ($snapshot.body.items | length) or
       (all($item_shas[];schema::sha256_ok) | not) then "E_RELATION"
  elif ($snapshot_sha | schema::sha256_ok | not) or
       ($evaluator_sha | schema::sha256_ok | not) or
       (($evaluator | evaluator_shape) | not) then "E_STALE"
  elif $snapshot.body.source_revision.repository_id != $expected_repository_id or
       $snapshot.body.source_revision.commit_id != $expected_commit_id then "E_STALE"
  elif (all($snapshot.body.items[];
            item_relation(
              $snapshot.body.source_revision;$snapshot.body.observed_at)) | not)
  then "E_RELATION"
  elif (set_relations($snapshot) | not) then "E_RELATION"
  else observation($snapshot;$snapshot_sha;$item_shas;$evaluator;$evaluator_sha)
  end;

if $scanner_operation == "scan" then
  if ($evaluator_docs | length) != 1 or ($item_sha_docs | length) != 1
  then "E_STALE"
  else evaluate(
    .;$snapshot_sha256;$item_sha_docs[0];$evaluator_docs[0];$evaluator_sha256)
  end
elif $scanner_operation == "validate-observation" then
  if ($snapshot_docs | length) != 1 or ($evaluator_docs | length) != 1 or
     ($candidate_docs | length) != 1 or ($item_sha_docs | length) != 1 then false
  else
    evaluate(
      $snapshot_docs[0];$snapshot_sha256;$item_sha_docs[0];
      $evaluator_docs[0];$evaluator_sha256) as $expected |
    ($expected | type) == "object" and $candidate_docs[0] == $expected
  end
else false
end
