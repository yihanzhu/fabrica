def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and
  (.content_id | id_ok) and .media_type == $media and (.sha256 | sha256_ok);

def document_ref_ok($kind; $version):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == $version and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def actor_ok:
  exact(["adapter_instance_id","execution_boundary_id","implementation_id",
    "implementation_version","principal_id","role"]) and
  all(.[];id_ok);

def credential_entry_ok:
  exact(["credential_class","delivery","exposure","scope"]) and
  (.credential_class | id_ok) and
  (.delivery == "brokered" or .delivery == "direct" or .delivery == "unknown") and
  (.exposure == "none" or .exposure == "present" or .exposure == "unknown") and
  (.scope == "single-stage" or .scope == "session" or .scope == "persistent" or
   .scope == "unknown");

def access_entry_ok:
  exact(["actor","binding_id","credentials"]) and (.binding_id | id_ok) and
  (.actor | actor_ok) and
  (.credentials | type == "array" and length <= 8 and
    all(.[];credential_entry_ok) and
    . == sort_by([.credential_class,.delivery,.exposure,.scope]) and
    length == (unique | length));

def claim_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "credential_boundary_claim" and (.id | id_ok) and
  (.body |
    exact(["accesses","activation_state","declaration_status",
      "duty_evaluation_ref","policy_set_ref","stage_result_ref"]) and
    .activation_state == "inactive" and
    (.declaration_status == "complete" or .declaration_status == "incomplete") and
    (.policy_set_ref | document_ref_ok("control_policy_set";1)) and
    (.duty_evaluation_ref | document_ref_ok("duty_separation_evaluation";1)) and
    (.stage_result_ref | document_ref_ok("stage_result";2)) and
    (.accesses | type == "array" and length <= 32 and all(.[];access_entry_ok) and
      . == sort_by(.binding_id) and length == (map(.binding_id) | unique | length)));

def expected_core:
  {semantic_identity:"core.contracts.v2",
   generation_id_sha256:
     "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
   package_ref:{content_id:"core-contract-package.v2",
     media_type:"application/vnd.ystack.core-contract+json",
     sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"}};

def expected_credential_classes:
  [{credential_class:"model-inference",delivery:"brokered",
    execution_kinds:["model"],exposure:"none",roles:["producer","reviewer"],
    scope:"single-stage"}];

def policy_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "credential_policy" and .id == "control-policy.credential-policy" and
  (.body |
    exact(["activation_state","claim_provenance","core_contract",
      "credential_classes","credential_incompatible_permissions","duty_separation",
      "evaluation_mode","fail_mode","policy_version","protected_roles",
      "reference_semantics"]) and
    .activation_state == "inactive" and
    .claim_provenance == "unqualified-input-claim" and
    .core_contract == expected_core and
    .credential_classes == expected_credential_classes and
    .credential_incompatible_permissions ==
      ["core.perm.candidate-repository.write.v2","core.perm.candidate.execute.v1"] and
    .duty_separation == {
      decision_ref:{content_id:"control-decision.duty-separation",
        media_type:"application/vnd.ystack.control-decision+json",
        sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
      policy_ref:{content_id:"control-policy.duty-separation",
        media_type:"application/vnd.ystack.control-policy+json",
        sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"}} and
    .evaluation_mode == "observation-only" and .fail_mode == "closed" and
    .policy_version == "v1" and
    .protected_roles ==
      ["ci","execution","forge","identity","producer","publisher","reviewer","verifier"] and
    .reference_semantics == "identity-only");

def policy_set_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "control_policy_set" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","fail_mode","policy_version","sections"]) and
    .activation_state == "inactive" and .fail_mode == "closed" and
    .policy_version == "v1" and
    (.sections | type == "array" and length == 6));

def duty_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "duty_separation_evaluation" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","decision_ref","evaluation_mode",
      "policy_ref","policy_set","reason_ids","reference_semantics","stage","verdict"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .reference_semantics == "identity-only" and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.policy_set | exact(["id","sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok)) and
    (.stage | exact(["request_ref","resolved_profile_ref","result_ref"]) and
      (.request_ref | document_ref_ok("stage_request";2)) and
      (.resolved_profile_ref | document_ref_ok("resolved_profile";2)) and
      (.result_ref | document_ref_ok("stage_result";2))) and
    (.reason_ids | type == "array" and length >= 1 and length <= 64 and
      all(.[];id_ok) and . == (sort | unique)) and
    ((.verdict == "satisfied" and .reason_ids == ["duty.satisfied"]) or
     (.verdict == "inconclusive" and
       .reason_ids == ["actual.capability-unclassified"]) or
     (.verdict == "violated" and
       (.reason_ids | all(. != "duty.satisfied" and
         . != "actual.capability-unclassified")))));

def document_ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,
   id:$document.id,sha256:$digest};

def content_ref($id; $media; $digest):
  {content_id:$id,media_type:$media,sha256:$digest};

def actor_from_binding($entry):
  {role:$entry.binding.role,
   implementation_id:$entry.adapter_implementation.id,
   implementation_version:$entry.adapter_implementation.version,
   adapter_instance_id:$entry.binding.adapter_instance_id,
   principal_id:$entry.binding.principal_id,
   execution_boundary_id:$entry.binding.execution_boundary_id};

def expected_credentials($policy; $entry):
  if ($entry.binding.execution_kind == "model" and
      ($entry.binding.role == "producer" or $entry.binding.role == "reviewer"))
  then [$policy.body.credential_classes[0] |
    {credential_class,delivery,exposure,scope}]
  else [] end;

def access_unknown:
  any(.credentials[];
    .delivery == "unknown" or .exposure == "unknown" or .scope == "unknown");

($policy[0]) as $p |
($decision[0]) as $decision_doc |
($policy_set[0]) as $set |
($request[0]) as $request_doc |
($resolved[0]) as $resolved_doc |
($result[0]) as $result_doc |
($duty[0]) as $duty_doc |
($claim[0]) as $claim_doc |
(if ($p | policy_ok) and ($set | policy_set_ok) and ($duty_doc | duty_ok)
 then true else error("invalid-fixed-input") end) |
($claim_doc | claim_ok) as $claim_valid |
content_ref($p.id;"application/vnd.ystack.control-policy+json";$policy_sha) as
  $credential_policy_ref |
content_ref($decision_doc.id;"application/vnd.ystack.control-decision+json";
  $decision_sha) as $credential_decision_ref |
([$set.body.sections[] | select(.section_id == "credential-policy")]) as
  $credential_sections |
([$set.body.sections[] | select(.section_id == "duty-separation")]) as
  $duty_sections |
(if ($credential_sections | length) == 1 and
    $credential_sections[0].policy_ref == $credential_policy_ref and
    $credential_sections[0].decision_ref == $credential_decision_ref and
    ($duty_sections | length) == 1 and
    $duty_sections[0].policy_ref == $p.body.duty_separation.policy_ref and
    $duty_sections[0].decision_ref == $p.body.duty_separation.decision_ref and
    $duty_doc.body.policy_set == {id:$set.id,sha256:$policy_set_sha} and
    $duty_doc.body.policy_ref == $duty_sections[0].policy_ref and
    $duty_doc.body.decision_ref == $duty_sections[0].decision_ref and
    $duty_doc.body.core_contract == $set.body.core_contract and
    $duty_doc.body.stage == {
      request_ref:document_ref($request_doc;$request_sha),
      resolved_profile_ref:document_ref($resolved_doc;$resolved_sha),
      result_ref:document_ref($result_doc;$result_sha)} and
    $duty_doc.id == $result_doc.id
 then true else error("identity-binding") end) |

(if $claim_valid then
  ($claim_doc.body.accesses) as $accesses |
  ([$resolved_doc.body.bindings[] | .binding.binding_id]) as $binding_ids |
  (($binding_ids | sort) ==
    ($accesses | map(.binding_id) | sort)) as $binding_set_complete |
  (([$accesses[] | .binding_id as $binding_id |
      select(($binding_ids | index($binding_id)) == null)] | length) == 0) as
    $no_extras |
  (([$resolved_doc.body.bindings[] as $binding |
      [$accesses[] | select(.binding_id == $binding.binding.binding_id)] as $matches |
      if ($matches | length) == 0 and
         $claim_doc.body.declaration_status == "incomplete"
      then empty
      elif ($matches | length) == 1 and
         $matches[0].actor == actor_from_binding($binding)
      then empty else "claim.actor-or-binding-mismatch" end]) as $identity_violations |
   ([$resolved_doc.body.bindings[] as $binding |
      [$accesses[] | select(.binding_id == $binding.binding.binding_id)] as $matches |
      if ($matches | length) == 1 and ($matches[0] | access_unknown | not) and
         $matches[0].credentials != expected_credentials($p;$binding)
      then "credential.ceiling-denied" else empty end]) as $ceiling_violations |
   ([$resolved_doc.body.bindings[] as $binding |
      [$accesses[] | select(.binding_id == $binding.binding.binding_id)] as $matches |
      if ($matches | length) == 1 and
         any($matches[0].credentials[];
           . as $credential |
           ([ $p.body.credential_classes[] | select(
             .credential_class == $credential.credential_class and
             (.roles | index($binding.binding.role)) != null and
             (.execution_kinds | index($binding.binding.execution_kind)) != null) ] |
            length) != 1)
      then "credential.class-role-denied" else empty end]) as $class_violations |
   ([$resolved_doc.body.bindings[] as $binding |
      [$accesses[] | select(.binding_id == $binding.binding.binding_id)] as $matches |
      if ($matches | length) == 1 and ($matches[0].credentials | length) > 0 and
         any($binding.binding.requested_permissions[];
           . as $permission |
           $p.body.credential_incompatible_permissions | index($permission) != null)
      then "credential.incompatible-permission" else empty end]) as
      $permission_violations |
   ((if $binding_set_complete or $claim_doc.body.declaration_status == "incomplete"
     then [] else ["claim.binding-set-incomplete"] end) +
    (if $no_extras then [] else ["claim.binding-extra"] end) +
    $identity_violations + $ceiling_violations + $class_violations +
    $permission_violations +
    [$accesses[].credentials[] | select(.delivery == "direct") |
      "credential.direct-delivery"] +
    [$accesses[].credentials[] | select(.exposure == "present") |
      "credential.material-exposed"] +
    [$accesses[].credentials[] |
      select(.scope == "session" or .scope == "persistent") |
      "credential.scope-denied"])
  )
 else ["claim.malformed"] end) as $claim_violations |

((if $duty_doc.body.verdict == "violated" then ["duty.violated"] else [] end) +
 (if $claim_valid then
    (if $claim_doc.body.policy_set_ref == document_ref($set;$policy_set_sha)
     then [] else ["claim.policy-set-ref-mismatch"] end) +
    (if $claim_doc.body.duty_evaluation_ref == document_ref($duty_doc;$duty_sha)
     then [] else ["claim.duty-ref-mismatch"] end) +
    (if $claim_doc.body.stage_result_ref == $duty_doc.body.stage.result_ref
     then [] else ["claim.stage-result-ref-mismatch"] end)
  else [] end) + $claim_violations | sort | unique) as $violations |

((if $duty_doc.body.verdict == "inconclusive" then ["duty.inconclusive"] else [] end) +
 (if $claim_valid and $claim_doc.body.declaration_status == "incomplete"
  then ["claim.incomplete"] else [] end) +
 (if $claim_valid and any($claim_doc.body.accesses[];access_unknown)
  then ["credential.access-unknown"] else [] end) +
 (if $claim_valid then ["claim.provenance-unqualified"] else [] end) |
 sort | unique) as $unknowns |
(if ($violations | length) > 0 then {verdict:"violated",reasons:$violations}
 elif ($unknowns | length) > 0 then {verdict:"inconclusive",reasons:$unknowns}
 else {verdict:"inconclusive",reasons:["claim.provenance-unqualified"]} end) as
  $evaluation |

{
  schema_version:1,
  kind:"credential_policy_evaluation",
  id:$result_doc.id,
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    claim_ref:document_ref($claim_doc;$claim_sha),
    core_contract:$set.body.core_contract,
    decision_ref:$credential_decision_ref,
    duty_evaluation_ref:document_ref($duty_doc;$duty_sha),
    evaluation_mode:"observation-only",
    policy_ref:$credential_policy_ref,
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    qualification_effect:"none",
    reason_ids:$evaluation.reasons,
    reference_semantics:"identity-only",
    stage:{request_ref:document_ref($request_doc;$request_sha),
      resolved_profile_ref:document_ref($resolved_doc;$resolved_sha),
      result_ref:document_ref($result_doc;$result_sha)},
    verdict:$evaluation.verdict
  }
}
