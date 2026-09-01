def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def content_ref_ok:
  exact(["content_id","media_type","sha256"]) and
  (.content_id | id_ok) and (.media_type | type == "string") and
  (.sha256 | sha256_ok);

def document_ref_ok($kind):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == 2 and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def scope_ref_ok($purpose):
  exact(["decision_record_ref","purpose","scope_sha256","subject_ref"]) and
  .purpose == $purpose and (.decision_record_ref | content_ref_ok) and
  (.scope_sha256 | sha256_ok) and (.subject_ref | type == "object");

def presence_ok(value_ok):
  type == "object" and
  ((exact(["state"]) and .state == "absent") or
   (exact(["state","value"]) and .state == "present" and (.value | value_ok)));

def evidence_ok:
  exact(["evidence_id","kind","proof_ref","verdict"]) and
  (.evidence_id | id_ok) and (.kind | id_ok) and
  (.verdict == "passed" or .verdict == "failed" or .verdict == "inconclusive") and
  (.proof_ref | content_ref_ok);

def evidence_ref_ok:
  exact(["evidence_id","stage_result_ref"]) and
  (.evidence_id | id_ok) and (.stage_result_ref | document_ref_ok("stage_result"));

def expected_core:
  {semantic_identity:"core.contracts.v2",
   generation_id_sha256:
     "6f6acbbd0cf40ab3c913328d6c0070635424ffe920bcdb900fbd0718345d7137",
   package_ref:{content_id:"core-contract-package.v2",
     media_type:"application/vnd.ystack.core-contract+json",
     sha256:"005431c5c7e3a39dc3ab75dfcafd0f09359331667fdcacb140514a4384592716"}};

def policy_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "evidence_integrity_policy" and
  .id == "control-policy.evidence-integrity" and
  (.body |
    exact(["activation_state","core_contract","evaluation_mode",
      "evidence_contract","fail_mode","policy_version",
      "qualification_semantics","storage_effect"]) and
    .activation_state == "inactive" and .core_contract == expected_core and
    .evaluation_mode == "observation-only" and .fail_mode == "closed" and
    .policy_version == "v1" and .qualification_semantics == "identity-only-unqualified" and
    .storage_effect == "none" and
    .evidence_contract == {
      current_result_binding:"exact-document-digest",
      presentation_kind:"evidence_integrity_presentation",
      prior_evidence_binding:"exact-stage-result-digest-and-evidence-id",
      proof_binding:"content-ref-sha256",
      qualification_binding:"exact-scope-ref-or-absent"});

def presentation_structure_ok:
  exact(["body","id","kind","schema_version"]) and .schema_version == 1 and
  .kind == "evidence_integrity_presentation" and (.id | id_ok) and
  (.body |
    exact(["evidence","prior_evidence_refs","qualification_ref","request_ref",
      "resolved_profile_ref","result_ref"]) and
    (.request_ref | document_ref_ok("stage_request")) and
    (.resolved_profile_ref | document_ref_ok("resolved_profile")) and
    (.result_ref | document_ref_ok("stage_result")) and
    (.evidence | type == "array" and length <= 256 and all(.[];evidence_ok)) and
    (.prior_evidence_refs |
      type == "array" and length <= 256 and all(.[];evidence_ref_ok)) and
    (.qualification_ref | presence_ok(scope_ref_ok("qualification"))));

def canonical_presentation_sets:
  (.body.evidence == (.body.evidence | sort_by(.evidence_id))) and
  ((.body.evidence | map(.evidence_id) | length) ==
    (.body.evidence | map(.evidence_id) | unique | length)) and
  ((.body.evidence | map(.kind) | length) ==
    (.body.evidence | map(.kind) | unique | length)) and
  (.body.prior_evidence_refs ==
    (.body.prior_evidence_refs | sort_by([.stage_result_ref.sha256,.evidence_id]))) and
  ((.body.prior_evidence_refs |
      map([.stage_result_ref.sha256,.evidence_id]) | length) ==
    (.body.prior_evidence_refs |
      map([.stage_result_ref.sha256,.evidence_id]) | unique | length));

def document_ref($document;$digest):
  {schema_version:$document.schema_version,kind:$document.kind,
   id:$document.id,sha256:$digest};

def content_ref($id;$media;$digest):
  {content_id:$id,media_type:$media,sha256:$digest};

def normalized_array($value):
  if ($value | type) == "array" then $value else [] end;

def duplicate_scalar_key($entries;$field):
  ($entries | normalized_array(.)) as $items |
  ($items | map(.[$field])) as $keys |
  ($keys | length) != ($keys | unique | length);

def duplicate_prior_key($entries):
  ($entries | normalized_array(.)) as $items |
  ($items | map([.stage_result_ref.sha256,.evidence_id])) as $keys |
  ($keys | length) != ($keys | unique | length);

def prior_document_alias($entries):
  ($entries | normalized_array(.)) as $items |
  if all($items[];evidence_ref_ok) then
    any($items | group_by(.stage_result_ref.sha256)[];
      ([.[] | [.stage_result_ref.schema_version,.stage_result_ref.kind,
        .stage_result_ref.id]] | unique | length) > 1)
  else false end;

($policy[0]) as $p |
($decision[0]) as $definition |
($policy_set[0]) as $set |
($request[0]) as $request_doc |
($resolved[0]) as $resolved_doc |
($result[0]) as $result_doc |
($presentation[0]) as $presented |
(if ($p | policy_ok) then true else error("invalid shipped evidence policy") end) |

document_ref($request_doc;$request_sha) as $expected_request_ref |
document_ref($resolved_doc;$resolved_sha) as $expected_resolved_ref |
document_ref($result_doc;$result_sha) as $expected_result_ref |
(if $request_doc.body | has("qualification_ref") then
   {state:"present",value:$request_doc.body.qualification_ref}
 else {state:"absent"} end) as $expected_qualification |
(if ($presented.body? | type) == "object" then $presented.body else {} end) as
  $presented_body |
($presented_body.evidence? | normalized_array(.)) as $presented_evidence |
($presented_body.prior_evidence_refs? | normalized_array(.)) as $presented_prior |

content_ref($p.id;"application/vnd.ystack.control-policy+json";$policy_sha) as
  $policy_ref |
content_ref($definition.id;"application/vnd.ystack.control-decision+json";
  $decision_sha) as $decision_ref |
([$set.body.sections[] | select(.section_id == "evidence-integrity")]) as
  $evidence_sections |
(if ($evidence_sections | length) == 1 and
    $evidence_sections[0].policy_ref == $policy_ref and
    $evidence_sections[0].decision_ref == $decision_ref
 then true else error("invalid policy-set evidence binding") end) |

((if (($presented | presentation_structure_ok) and
      ($presented | canonical_presentation_sets)) then []
   else ["evidence.presentation-malformed"] end) +
 (if $presented_body.request_ref? == $expected_request_ref then []
  else ["evidence.request-moved"] end) +
 (if $presented_body.resolved_profile_ref? == $expected_resolved_ref then []
  else ["evidence.resolved-profile-moved"] end) +
 (if $presented_body.result_ref? == $expected_result_ref then []
  else ["evidence.result-moved"] end) +
 (if $presented_evidence == $result_doc.body.evidence then []
  else ["evidence.current-mismatch"] end) +
 (if $presented_prior == $request_doc.body.prior_evidence_refs then []
  else ["evidence.prior-stale"] end) +
 (if $presented_body.qualification_ref? == $expected_qualification then []
  else ["evidence.qualification-mismatch"] end) +
 (if duplicate_scalar_key($presented_evidence;"evidence_id") or
     duplicate_scalar_key($presented_evidence;"kind") or
     duplicate_prior_key($presented_prior) or
     prior_document_alias($presented_prior)
  then ["evidence.presentation-ambiguous"] else [] end) |
 sort | unique) as $violations |
(if ($violations | length) == 0 then
   {verdict:"satisfied",reasons:["evidence.integrity-satisfied"]}
 else {verdict:"violated",reasons:$violations} end) as $evaluation |

{
  schema_version:1,
  kind:"evidence_integrity_evaluation",
  id:$result_doc.id,
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    core_contract:$set.body.core_contract,
    decision_ref:$decision_ref,
    evaluation_mode:"observation-only",
    evidence_refs:($result_doc.body.evidence | map({evidence_id,kind,proof_ref,verdict})),
    policy_ref:$policy_ref,
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    presentation_ref:content_ref($presented.id;
      "application/vnd.ystack.evidence-integrity-presentation+json";$presentation_sha),
    prior_evidence_refs:$request_doc.body.prior_evidence_refs,
    qualification_observation:$expected_qualification,
    qualification_semantics:"identity-only-unqualified",
    reason_ids:$evaluation.reasons,
    reference_semantics:"identity-only",
    stage:{request_ref:$expected_request_ref,resolved_profile_ref:$expected_resolved_ref,
      result_ref:$expected_result_ref},
    storage_effect:"none",
    verdict:$evaluation.verdict
  }
}
