def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

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
   $month >= 1 and $month <= 12 and $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

def actor_ok:
  exact(["adapter_instance_id","execution_boundary_id","implementation_id",
    "implementation_version","principal_id","role"]) and
  (.role | id_ok) and (.implementation_id | id_ok) and
  (.implementation_version | id_ok) and (.adapter_instance_id | id_ok) and
  (.principal_id | id_ok) and (.execution_boundary_id | id_ok);

def reason_set_ok:
  type == "array" and length >= 1 and length <= 256 and
  all(.[];id_ok) and length == (unique | length) and . == sort;

def content_ref($id;$media;$sha):
  {content_id:$id,media_type:$media,sha256:$sha};

def document_ref($document;$digest):
  {schema_version:$document.schema_version,kind:$document.kind,
   id:$document.id,sha256:$digest};

def actor_from_binding($entry):
  {role:$entry.binding.role,
   implementation_id:$entry.adapter_implementation.id,
   implementation_version:$entry.adapter_implementation.version,
   adapter_instance_id:$entry.binding.adapter_instance_id,
   principal_id:$entry.binding.principal_id,
   execution_boundary_id:$entry.binding.execution_boundary_id};

def decision_actor_bound($rule;$request_doc;$resolved_doc;$actor):
  if $rule.decision_role == "reviewer" then
    [$resolved_doc.body.bindings[] | select(.binding.role == "reviewer")] as $matches |
    ($matches | length) == 1 and $actor == actor_from_binding($matches[0])
  elif $rule.decision_role == "operator" then
    $request_doc.body.requested_by.role == "operator" and
    $actor == $request_doc.body.requested_by
  else false
  end;

def expected_core:
  {semantic_identity:"core.contracts.v2",
   generation_id_sha256:
     "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
   package_ref:{content_id:"core-contract-package.v2",
     media_type:"application/vnd.ystack.core-contract+json",
     sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"}};

def expected_tier_rules:
  [
    {classification:"bootstrap",declared_tier:"bootstrap",
     decision_kind:"operator-bootstrap-approval",decision_role:"operator"},
    {classification:"high",declared_tier:"high",
     decision_kind:"operator-plan-approval",decision_role:"operator"},
    {classification:"routine",declared_tier:"high",
     decision_kind:"operator-plan-approval",decision_role:"operator"},
    {classification:"routine",declared_tier:"routine",
     decision_kind:"independent-plan-check",decision_role:"reviewer"}
  ];

def expected_high_reasons:
  ["risk.broad-architecture","risk.constitution","risk.deployment",
   "risk.identity-auth","risk.migration","risk.production-infrastructure",
   "risk.security-control","risk.workflow"];

def policy_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "risk_gates_policy" and .id == "control-policy.risk-gates" and
  (.body |
    exact(["activation_state","core_contract","decision_claim_semantics",
      "decision_provenance","duty_separation","evaluation_mode","fail_mode",
      "forced_high_reason_ids","policy_version","tier_rules"]) and
    .activation_state == "inactive" and
    .core_contract == expected_core and
    .decision_claim_semantics == "immutable-input-claim-only" and
    .decision_provenance == "unqualified-input-claim" and
    .evaluation_mode == "observation-only" and .fail_mode == "closed" and
    .policy_version == "v1" and .forced_high_reason_ids == expected_high_reasons and
    .tier_rules == expected_tier_rules and
    .duty_separation == {
      decision_ref:{content_id:"control-decision.duty-separation",
        media_type:"application/vnd.ystack.control-decision+json",
        sha256:"4c2297341d1d389f21ace62b58b83e27a6ed248f9bf13a10fa385c4f8474af99"},
      evaluation_kind:"duty_separation_evaluation",
      policy_ref:{content_id:"control-policy.duty-separation",
        media_type:"application/vnd.ystack.control-policy+json",
        sha256:"b2663c0c0ae3d1d2e95b2e5d5ade7e00b2893f242a1143e90fad74659f6a41f9"},
      required_verdict:"satisfied"});

def claim_shape_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "risk_gate_decision_claim" and (.id | id_ok) and
  (.body |
    exact(["activation_state","classification","decision","policy_ref",
      "request_basis_sha256","required_gate_refs"]) and
    .activation_state == "inactive" and
    (.request_basis_sha256 | sha256_ok) and
    (.classification |
      exact(["reason_ids","tier"]) and
      (.tier == "routine" or .tier == "high" or .tier == "bootstrap") and
      (.reason_ids | reason_set_ok)) and
    (.policy_ref | type == "object") and
    (.required_gate_refs | type == "array") and
    (.decision |
      (exact(["state"]) and .state == "absent") or
      (exact(["state","value"]) and .state == "present" and
       (.value |
         exact(["asserted_decision","decided_by","decision_kind","recorded_at"]) and
         (.asserted_decision == "accept" or .asserted_decision == "reject") and
         (.decided_by | actor_ok) and (.decision_kind | id_ok) and
         (.recorded_at | time_ok)))));

($policy[0]) as $p |
($decision[0]) as $definition |
($policy_set[0]) as $set |
($request[0]) as $request_doc |
($resolved[0]) as $resolved_doc |
($result[0]) as $result_doc |
($duty_evaluation[0]) as $duty |
($claim[0]) as $claim_doc |
(if ($p | policy_ok) then true else error("invalid shipped risk policy") end) |
($claim_doc | claim_shape_ok) as $claim_valid |
(($claim_doc.body.classification? // null) as $raw_classification |
  if ($raw_classification | type) == "object" then $raw_classification else {} end) as
  $classification |
(($classification.tier? // null) as $candidate_tier |
  if ($candidate_tier | type) == "string" and
     ($candidate_tier == "routine" or $candidate_tier == "high" or
      $candidate_tier == "bootstrap")
  then $candidate_tier else "unknown" end) as $claimed_tier |
(($claim_doc.body.decision? // null) as $raw_decision |
  if ($raw_decision | type) == "object" then $raw_decision else {} end) as
  $claim_decision |
(($claim_decision.value? // null) as $raw_decision_value |
  if ($raw_decision_value | type) == "object" then $raw_decision_value else {} end) as
  $claim_decision_value |
(($claim_decision_value.decided_by? // null) as $raw_actor |
  if ($raw_actor | type) == "object" then $raw_actor else {} end) as $claim_actor |
($claim_decision.state? // "invalid") as $claim_decision_state |
($claim_decision_value.asserted_decision? // "invalid") as $claim_assertion |
($claim_decision_value.decision_kind? // "invalid") as $claim_decision_kind |
($claim_decision_value.recorded_at? // "invalid") as $claim_decision_time |

content_ref($p.id;"application/vnd.ystack.control-policy+json";$policy_sha) as
  $risk_policy_ref |
content_ref($definition.id;"application/vnd.ystack.control-decision+json";
  $decision_sha) as $risk_definition_ref |
{type:"artifact",value:$request_doc.body.source.value} as $subject_ref |
{purpose:"policy",decision_record_ref:$risk_policy_ref,subject_ref:$subject_ref,
 scope_sha256:$policy_scope_sha} as $expected_policy_scope |
{purpose:"gate-requirement",decision_record_ref:$risk_policy_ref,
 subject_ref:$subject_ref,scope_sha256:$requirement_scope_sha} as
  $expected_requirement_scope |
content_ref($claim_doc.id;
  "application/vnd.ystack.risk-gate-decision-claim+json";$claim_sha) as
  $claim_content_ref |
{purpose:"gate-decision",decision_record_ref:$claim_content_ref,
 subject_ref:$subject_ref,scope_sha256:$request_basis_sha} as
  $expected_gate_decision |

([$set.body.sections[] | select(.section_id == "risk-gates")]) as $risk_sections |
([$set.body.sections[] | select(.section_id == "duty-separation")]) as $duty_sections |
(if ($risk_sections | length) == 1 and
    $risk_sections[0].policy_ref == $risk_policy_ref and
    $risk_sections[0].decision_ref == $risk_definition_ref and
    ($duty_sections | length) == 1 and
    $duty_sections[0].policy_ref == $p.body.duty_separation.policy_ref and
    $duty_sections[0].decision_ref == $p.body.duty_separation.decision_ref
 then true else error("invalid policy-set section bindings") end) |

($request_doc.body.risk.tier.namespace == "core" and
 ($request_doc.body.risk.tier.name == "routine" or
  $request_doc.body.risk.tier.name == "high" or
  $request_doc.body.risk.tier.name == "bootstrap")) as $core_tier_supported |
($request_doc.body.risk.tier.name) as $declared_tier |
(if $claimed_tier == "unknown" then "unknown"
 elif ($core_tier_supported | not) then "unknown"
 elif $request_doc.body.target_revision.state == "absent" or
    $request_doc.body.base.state == "absent" then "bootstrap"
 elif any($request_doc.body.risk.reason_ids[];
          . as $reason | $p.body.forced_high_reason_ids | index($reason) != null)
 then "high"
 else $claimed_tier
 end) as $minimum_tier |
([$p.body.tier_rules[] |
  select(.classification == $minimum_tier and .declared_tier == $declared_tier)]) as
  $matching_rules |
($matching_rules[0] // null) as $matching_rule |
([$request_doc.body.gate_decision_refs[] |
  select(.decision_record_ref.media_type ==
    "application/vnd.ystack.risk-gate-decision-claim+json")]) as
  $risk_decision_refs |

((if $claim_valid then [] else ["decision.claim-malformed"] end) +
 (if $request_doc.body.risk.policy_ref == $expected_policy_scope then []
  else ["risk.policy-ref-mismatch"] end) +
 (if $request_doc.body.risk.required_gate_refs == [$expected_requirement_scope] then []
  else ["risk.requirement-ref-mismatch"] end) +
 (if $claim_doc.body.policy_ref == $request_doc.body.risk.policy_ref and
     $claim_doc.body.required_gate_refs == $request_doc.body.risk.required_gate_refs
  then [] else ["decision.claim-context-mismatch"] end) +
 (if $claim_doc.body.request_basis_sha256 == $request_basis_sha then []
  else ["decision.stale"] end) +
 (if ($risk_decision_refs | length) == 1 and
     $risk_decision_refs[0] == $expected_gate_decision then []
  elif ($risk_decision_refs | length) > 1 then ["decision.ambiguous"]
 else ["decision.unbound"] end) +
 (if $claim_valid and
     ($classification.reason_ids? // null) == $request_doc.body.risk.reason_ids
  then [] else ["classification.reasons-mismatch"] end) +
 (if $claim_valid and $minimum_tier == $claimed_tier then []
  else ["classification.forced-tier-mismatch"] end) +
 (if $core_tier_supported and ($matching_rules | length) == 1 then []
  elif $core_tier_supported then ["risk.tier-downgrade"]
  else ["risk.tier-unsupported"] end) +
 (if $duty.body.verdict == "violated" then ["duty.violated"] else [] end) +
 (if $claim_decision_state == "absent" then ["decision.missing"]
  elif $claim_assertion == "reject"
  then ["decision.rejected"]
  else [] end) +
 (if $claim_valid and $claim_decision_state == "present" and
     $matching_rule != null then
    (if $claim_decision_kind == $matching_rule.decision_kind
     then [] else ["decision.kind-denied"] end) +
    (if ($claim_actor.role? // "invalid") == $matching_rule.decision_role
     then [] else ["decision.role-denied"] end) +
    (if decision_actor_bound($matching_rule;$request_doc;$resolved_doc;
          $claim_actor)
     then [] else ["decision.actor-unbound"] end) +
    (if $claim_decision_time <= $request_doc.body.requested_at
     then [] else ["decision.after-request"] end)
  else [] end) | sort | unique) as $violations |

((if $duty.body.verdict == "inconclusive" then ["duty.inconclusive"] else [] end) +
 (if $claim_valid and $claim_decision_state == "present" and
     $claim_assertion == "accept"
  then ["decision.provenance-unqualified"] else [] end) |
 sort | unique) as $unknowns |
(if ($violations | length) > 0 then {verdict:"violated",reasons:$violations}
 elif ($unknowns | length) > 0 then {verdict:"inconclusive",reasons:$unknowns}
 else {verdict:"inconclusive",reasons:["decision.provenance-unqualified"]} end) as $result |

{
  schema_version:1,
  kind:"risk_gate_evaluation",
  id:$result_doc.id,
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    classification:{declared_tier:$declared_tier,minimum_tier:$minimum_tier},
    core_contract:$set.body.core_contract,
    decision_claim_ref:$claim_content_ref,
    decision_ref:$risk_definition_ref,
    duty_evaluation_ref:content_ref($duty.id;
      "application/vnd.ystack.duty-separation-evaluation+json";$duty_sha),
    evaluation_mode:"observation-only",
    policy_ref:$risk_policy_ref,
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    reason_ids:$result.reasons,
    reference_semantics:"identity-only",
    stage:{request_ref:document_ref($request_doc;$request_sha),
      resolved_profile_ref:document_ref($resolved_doc;$resolved_sha),
      result_ref:document_ref($result_doc;$result_sha)},
    verdict:$result.verdict
  }
}
