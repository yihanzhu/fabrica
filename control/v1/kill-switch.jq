def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and
  (.content_id | id_ok) and .media_type == $media and (.sha256 | sha256_ok);

def identity_ref_ok($kind):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == 1 and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def expected_scopes: ["global","repository","workflow","stage","attempt"];

def policy_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "kill_switch_policy" and
  .id == "control-policy.kill-switch" and
  (.body |
    exact(["activation_state","duty_decision_ref","evaluation_mode","fail_mode",
      "policy_version","scope_order","states"]) and
    .activation_state == "inactive" and
    .evaluation_mode == "observation-only" and .fail_mode == "closed" and
    .policy_version == "v1" and .scope_order == expected_scopes and
    .states == ["cleared","stop"] and
    (.duty_decision_ref |
      content_ref_ok("application/vnd.ystack.control-decision+json") and
      .content_id == "control-decision.duty-separation"));

def decision_ok($policy_sha; $decision_sha):
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "kill_switch_decision" and
  .id == "control-decision.kill-switch" and
  (.body |
    exact(["activation_state","decision","duty_decision_ref","evaluator","fail_mode",
      "policy_ref","semantics"]) and
    .activation_state == "inactive" and
    .decision == "allow-observation-only-evaluation" and .fail_mode == "closed" and
    .duty_decision_ref == $policy[0].body.duty_decision_ref and
    (.evaluator |
      exact(["driver_ref","policy_set_validator","program_ref"]) and
      (.driver_ref | content_ref_ok("text/x-shellscript")) and
      (.program_ref | content_ref_ok("text/x-jq")) and
      (.policy_set_validator |
        exact(["driver_ref","program_ref"]) and
        (.driver_ref | content_ref_ok("text/x-shellscript")) and
        (.program_ref | content_ref_ok("text/x-jq")))) and
    .policy_ref == {content_id:$policy[0].id,
      media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
    (.semantics |
      exact(["authority_effect","input_contract","output_kind",
        "output_schema_version","reference_semantics","verdicts"]) and
      .authority_effect == "none" and
      .input_contract == "control-policy-set+kill-state+attempt+duty-evaluation.v1" and
      .output_kind == "kill_switch_evaluation" and .output_schema_version == 1 and
      .reference_semantics == "identity-only" and
      .verdicts == ["inconclusive","satisfied","violated"])) and
  ($decision_sha | sha256_ok);

def scope_shape_ok:
  exact(["attempt_id","repository_id","stage_id","workflow_id"]) and
  all(.[]; id_ok);

def attempt_shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "kill_switch_attempt" and (.id | id_ok) and
  (.body |
    exact(["activation_state","authority_epoch","duty_evaluation_ref",
      "expected_state","scope"]) and
    .activation_state == "inactive" and (.authority_epoch | id_ok) and
    (.duty_evaluation_ref | identity_ref_ok("duty_separation_evaluation")) and
    (.expected_state |
      exact(["id","revision","sha256"]) and (.id | id_ok) and
      (.revision | type == "number" and . >= 1 and . <= 9007199254740991 and
        floor == .) and (.sha256 | sha256_ok)) and
    (.scope | scope_shape_ok));

def entry_shape_ok:
  exact(["scope_id","scope_kind","state"]) and
  (.scope_kind as $kind |
    ($kind | type == "string") and (expected_scopes | index($kind) != null)) and
  (.scope_id | type == "string" and length >= 1 and length <= 128) and
  (.state == "cleared" or .state == "stop");

def state_shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "kill_switch_state" and (.id | id_ok) and
  (.body |
    exact(["activation_state","attempt_id","authority_epoch","entries","revision"]) and
    .activation_state == "inactive" and (.attempt_id | id_ok) and
    (.authority_epoch | id_ok) and
    (.revision | type == "number" and . >= 1 and . <= 9007199254740991 and
      floor == .) and
    (.entries | type == "array" and length <= 16 and all(.[]; entry_shape_ok)));

def generic_ref_ok:
  type == "object" and
  (keys | sort) == ["id","sha256"] and (.id | id_ok) and (.sha256 | sha256_ok);

def document_ref_ok:
  type == "object" and
  (keys | sort) == ["id","kind","schema_version","sha256"] and
  .schema_version == 2 and (.id | id_ok) and (.kind | id_ok) and
  (.sha256 | sha256_ok);

def duty_shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "duty_separation_evaluation" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","decision_ref","evaluation_mode",
      "policy_ref","policy_set","reason_ids","reference_semantics","stage","verdict"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .reference_semantics == "identity-only" and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.policy_set | generic_ref_ok) and
    (.core_contract | type == "object") and
    (.stage |
      exact(["request_ref","resolved_profile_ref","result_ref"]) and
      (.request_ref | document_ref_ok) and
      (.resolved_profile_ref | document_ref_ok) and
      (.result_ref | document_ref_ok)) and
    (.verdict == "satisfied" or .verdict == "violated" or .verdict == "inconclusive") and
    (.reason_ids | type == "array" and length >= 1 and length <= 64 and
      all(.[]; id_ok) and . == (sort | unique)));

def ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,
   sha256:$digest};

def expected_scope_id($scope; $kind):
  if $kind == "global" then "*"
  elif $kind == "repository" then $scope.repository_id
  elif $kind == "workflow" then $scope.workflow_id
  elif $kind == "stage" then $scope.stage_id
  else $scope.attempt_id end;

($policy[0]) as $p |
($decision[0]) as $decision_doc |
($policy_set[0]) as $set |
($state[0]) as $state_doc |
($attempt[0]) as $attempt_doc |
($duty[0]) as $duty_doc |
(if ($p | policy_ok) then true else error("invalid shipped policy") end) |
(if ($decision_doc | decision_ok($policy_sha;$decision_sha))
 then true else error("invalid shipped decision") end) |
($attempt_doc | attempt_shape_ok) as $attempt_valid |
($state_doc | state_shape_ok) as $state_valid |
($duty_doc | duty_shape_ok) as $duty_valid |
(if $attempt_valid then true else error("invalid attempt") end) |
(if $state_valid then true else error("invalid state") end) |
(if $duty_valid then true else error("invalid duty evaluation") end) |
(if $attempt_valid then $attempt_doc.body.scope else null end) as $scope |
(if $state_valid and $attempt_valid then
   [$state_doc.body.entries[] |
    select(.scope_kind as $kind |
      .scope_id == expected_scope_id($scope;$kind)) |
    select(.state == "stop") |
    "kill.stop." + .scope_kind]
 else [] end) as $stop_reasons |
(if $attempt_valid and $state_valid then
   ((if $state_doc.id != $attempt_doc.body.expected_state.id
      then ["kill.state-id-mismatch"] else [] end) +
    (if $state_doc.body.revision < $attempt_doc.body.expected_state.revision
     then ["kill.state-rollback"]
     elif $state_doc.body.revision > $attempt_doc.body.expected_state.revision
     then ["kill.attempt-stale"] else [] end) +
    (if $state_sha != $attempt_doc.body.expected_state.sha256
     then ["kill.state-digest-mismatch"] else [] end) +
    (if $state_doc.body.authority_epoch != $attempt_doc.body.authority_epoch or
        $state_doc.body.attempt_id != $scope.attempt_id
     then ["kill.state-replayed"] else [] end) +
    (expected_scopes | map(. as $kind |
      [$state_doc.body.entries[] | select(.scope_kind == $kind)] as $entries |
      if ($entries | length) > 1 then "kill.scope-ambiguous." + $kind
      elif ($entries | length) == 1 and
           $entries[0].scope_id != expected_scope_id($scope;$kind)
      then "kill.scope-mismatch." + $kind else empty end)) +
    (if $duty_valid and
        $attempt_doc.body.duty_evaluation_ref == ref($duty_doc;$duty_sha) and
        $duty_doc.body.decision_ref == $p.body.duty_decision_ref and
        $duty_doc.body.stage.result_ref.id == $scope.attempt_id and
        $duty_doc.body.verdict == "violated"
     then ["kill.duty-violated"] else [] end))
 elif ($attempt_valid | not) then ["kill.attempt-invalid"]
 else ["kill.state-invalid"] end) as $violations |
(if $attempt_valid and $state_valid then
   ((expected_scopes | map(. as $kind |
      [$state_doc.body.entries[] | select(.scope_kind == $kind)] as $entries |
      if ($entries | length) == 0 then "kill.scope-missing." + $kind else empty end)) +
    (if ($duty_valid | not) or
        $attempt_doc.body.duty_evaluation_ref != ref($duty_doc;$duty_sha) or
        $duty_doc.body.decision_ref != $p.body.duty_decision_ref or
        $duty_doc.body.stage.result_ref.id != $scope.attempt_id
     then ["kill.duty-unverifiable"]
     elif $duty_doc.body.verdict == "inconclusive"
     then ["kill.duty-inconclusive"] else [] end))
 else [] end) as $unknowns |
((if ($stop_reasons | length) > 0 then
    {verdict:"violated",reasons:($stop_reasons + $violations + $unknowns)}
  elif ($violations | length) > 0 then
    {verdict:"violated",reasons:$violations}
  elif ($unknowns | length) > 0 then
    {verdict:"inconclusive",reasons:$unknowns}
  else {verdict:"satisfied",reasons:["kill.cleared-current"]} end) |
  .reasons |= (sort | unique)) as $result |
{
  schema_version:1,
  kind:"kill_switch_evaluation",
  id:(if $attempt_valid then $attempt_doc.id else "kill-attempt.invalid" end),
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    evaluation_mode:"observation-only",
    reference_semantics:"identity-only",
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    policy_ref:$decision_doc.body.policy_ref,
    decision_ref:{content_id:$decision_doc.id,
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha},
    duty_decision_ref:$p.body.duty_decision_ref,
    state_ref:ref($state_doc;$state_sha),
    attempt_ref:ref($attempt_doc;$attempt_sha),
    duty_evaluation_ref:ref($duty_doc;$duty_sha),
    verdict:$result.verdict,
    reason_ids:$result.reasons
  }
}
