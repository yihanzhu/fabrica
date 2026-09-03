def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def expected_roles: ["forge","producer","publisher","reviewer","verifier"];
def expected_dormant: ["ci","execution","identity","publisher"];
def expected_dimensions:
  ["adapter_instance_id","execution_boundary_id","principal_id"];
def expected_ceilings:
  [
    {role:"forge",execution_kind:"deterministic",
     capabilities:["core.forge.materialize-candidate.v2"],
     permissions:["core.perm.candidate-repository.write.v2",
       "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
       "core.perm.target.read.v1"]},
    {role:"producer",execution_kind:"deterministic",
     capabilities:["core.harness.produce.v1"],
     permissions:["core.perm.evidence.write.v1","core.perm.scratch.write.v1",
       "core.perm.target.read.v1"]},
    {role:"producer",execution_kind:"model",
     capabilities:["core.harness.produce.v1"],
     permissions:["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
       "core.perm.scratch.write.v1","core.perm.target.read.v1"]},
    {role:"reviewer",execution_kind:"deterministic",
     capabilities:["core.review.change.v1"],
     permissions:["core.perm.evidence.write.v1","core.perm.target.read.v1"]},
    {role:"reviewer",execution_kind:"model",
     capabilities:["core.review.change.v1"],
     permissions:["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
       "core.perm.target.read.v1"]},
    {role:"verifier",execution_kind:"deterministic",
     capabilities:["core.verify.run.v1"],
     permissions:["core.perm.candidate.execute.v1","core.perm.evidence.write.v1",
       "core.perm.target.read.v1"]}
  ];

def policy_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "duty_separation_policy" and
  .id == "control-policy.duty-separation" and
  (.body |
    exact(["activation_state","core_contract","dormant_roles","evaluation_mode",
      "fail_mode","identity_dimensions","operation_ceilings","policy_version",
      "protected_roles","reporter_relation","requester_roles"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .fail_mode == "closed" and .policy_version == "v1" and
    .core_contract == {
      semantic_identity:"core.contracts.v2",
      generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
      package_ref:{content_id:"core-contract-package.v2",
        media_type:"application/vnd.ystack.core-contract+json",
        sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"}
    } and
    .protected_roles == expected_roles and .dormant_roles == expected_dormant and
    .identity_dimensions == expected_dimensions and
    .requester_roles == ["manager","operator","orchestrator"] and
    .reporter_relation == "performer-else-selected" and
    .operation_ceilings == expected_ceilings);

def identity:
  {role,adapter_instance_id,execution_boundary_id,principal_id};

def ceiling_for($policy; $role; $execution):
  [$policy.body.operation_ceilings[] |
   select(.role == $role and .execution_kind == $execution)];

def binding_within_ceiling($policy):
  .binding as $binding |
  ceiling_for($policy;$binding.role;$binding.execution_kind) as $ceilings |
  ($ceilings | length) == 1 and
  $binding.requested_capabilities == $ceilings[0].capabilities and
  $binding.requested_permissions == $ceilings[0].permissions;

def dormant_ok($policy):
  .binding as $binding |
  ($policy.body.dormant_roles | index($binding.role)) != null and
  $binding.execution_kind == "deterministic" and
  $binding.requested_capabilities == [] and $binding.requested_permissions == [];

def unique_dimension($bindings; $dimension):
  ($bindings | map(.binding[$dimension])) as $values |
  ($values | length) == ($values | unique | length);

def document_ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,
   id:$document.id,sha256:$digest};

($policy[0]) as $p |
($decision[0]) as $decision_doc |
($policy_set[0]) as $set |
($request[0]) as $request_doc |
($resolved[0]) as $resolved_doc |
($result[0]) as $result_doc |
(if ($p | policy_ok) then true else error("invalid shipped policy") end) |
($resolved_doc.body.bindings) as $bindings |
([$bindings[] | select(.binding.role as $role |
  $p.body.protected_roles | index($role) != null)]) as $protected |
([$bindings[] | select(
  .binding.binding_id == $request_doc.body.operation.binding_id and
  .binding.role == $request_doc.body.operation.role)]) as $selected |
($selected[0] // null) as $selected_binding |
([$bindings[] | select(.binding.role == "publisher")][0] // null) as $publisher |
($request_doc.body.requested_by | identity) as $requester_identity |

((if ($protected | map(.binding.role) | sort) == expected_roles
  then [] else ["protected.roles-invalid"] end) +
 (expected_dimensions | map(. as $dimension |
   if unique_dimension($protected;$dimension) then empty
   else "protected." + $dimension + "-collision" end)) +
 [$bindings[] | select(
   (.binding.role as $role | ($p.body.protected_roles + $p.body.dormant_roles) |
    index($role) == null)) | "profile.role-denied"] +
 [$bindings[] | select(.binding.role != "publisher" and
   (.binding.role as $role | $p.body.dormant_roles | index($role) == null) and
   (binding_within_ceiling($p) | not)) | "operation.ceiling-denied"] +
 (if $publisher != null and ($publisher | dormant_ok($p))
  then [] else ["publisher.not-dormant"] end) +
 [$bindings[] | select(.binding.role != "publisher" and
   (.binding.role as $role | $p.body.dormant_roles | index($role) != null) and
   (dormant_ok($p) | not)) | "dormant.not-dormant"] +
 (if $p.body.requester_roles | index($request_doc.body.requested_by.role)
  then [] else ["requester.role-denied"] end) +
 (expected_dimensions | map(. as $dimension |
   if all($protected[];.binding[$dimension] != $requester_identity[$dimension])
   then empty else "requester." + $dimension + "-collision" end)) +
 (if ($selected | length) != 1 then ["operation.role-denied"]
  elif $request_doc.body.operation.role == "publisher" then ["publisher.requested"]
  else
    ceiling_for($p;$request_doc.body.operation.role;
      $selected_binding.binding.execution_kind) as $ceilings |
    (if ($ceilings | length) == 1 then [] else ["operation.execution-kind-denied"] end) +
    (if ($ceilings | length) == 1 and
        $ceilings[0].capabilities == [$request_doc.body.operation.capability_id]
     then [] else ["operation.capability-denied"] end) +
    (if ($ceilings | length) == 1 and
        $ceilings[0].permissions == $request_doc.body.operation.permissions
     then [] else ["operation.permissions-denied"] end)
  end) +
 (if $selected_binding == null then []
  elif $result_doc.body | has("execution") then
    ($selected_binding.binding | identity) as $selected_identity |
    ($result_doc.body.execution.actual_binding | identity) as $actual |
    ($result_doc.body.execution.performer | identity) as $performer |
    ($result_doc.body.reported_by | identity) as $reporter |
    (ceiling_for($p;$actual.role;
      $result_doc.body.execution.actual_binding.execution_kind)) as $actual_ceilings |
    (expected_dimensions + ["role"] | map(. as $dimension |
      if $actual[$dimension] == $selected_identity[$dimension] then empty
      else "actual." + $dimension + "-mismatch" end)) +
    (if $result_doc.body.execution.actual_binding.execution_kind ==
          $selected_binding.binding.execution_kind
     then [] else ["actual.execution-kind-mismatch"] end) +
    (expected_dimensions + ["role"] | map(. as $dimension |
      if $performer[$dimension] == $actual[$dimension] then empty
      else "performer." + $dimension + "-mismatch" end)) +
    (expected_dimensions + ["role"] | map(. as $dimension |
      if $reporter[$dimension] == $performer[$dimension] then empty
      else "reporter." + $dimension + "-mismatch" end)) +
    (if $result_doc.body.execution.used_capability.kind == "unclassified" then []
     elif ($actual_ceilings | length) == 1 and
          $result_doc.body.execution.used_capability ==
            {kind:"registered",id:$request_doc.body.operation.capability_id} and
          $actual_ceilings[0].capabilities ==
            [$result_doc.body.execution.used_capability.id]
     then [] else ["actual.capability-mismatch"] end) +
    (if ($actual_ceilings | length) == 1 and
        $actual_ceilings[0].permissions == $request_doc.body.operation.permissions
     then [] else ["actual.permissions-mismatch"] end)
  else
    ($selected_binding.binding | identity) as $selected_identity |
    ($result_doc.body.reported_by | identity) as $reporter |
    (expected_dimensions + ["role"] | map(. as $dimension |
      if $reporter[$dimension] == $selected_identity[$dimension] then empty
      else "reporter." + $dimension + "-mismatch" end))
  end) | sort | unique) as $violations |
(if ($result_doc.body | has("execution")) and
    $result_doc.body.execution.used_capability.kind == "unclassified"
 then ["actual.capability-unclassified"] else [] end) as $unknowns |
(if ($violations | length) > 0 then {verdict:"violated",reasons:$violations}
 elif ($unknowns | length) > 0 then {verdict:"inconclusive",reasons:$unknowns}
 else {verdict:"satisfied",reasons:["duty.satisfied"]} end) as $decision |
{
  schema_version:1,
  kind:"duty_separation_evaluation",
  id:$result_doc.id,
  body:{
    activation_state:"inactive",
    evaluation_mode:"observation-only",
    reference_semantics:"identity-only",
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    policy_ref:$decision_doc.body.policy_ref,
    decision_ref:{content_id:$decision_doc.id,
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha},
    core_contract:$set.body.core_contract,
    stage:{request_ref:document_ref($request_doc;$request_sha),
      resolved_profile_ref:document_ref($resolved_doc;$resolved_sha),
      result_ref:document_ref($result_doc;$result_sha)},
    verdict:$decision.verdict,
    reason_ids:$decision.reasons
  }
}
