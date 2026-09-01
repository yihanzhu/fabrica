def exact($fields):
  type == "object" and (keys | sort) == ($fields | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def content_ref_ok($media):
  exact(["content_id","media_type","sha256"]) and
  (.content_id | id_ok) and .media_type == $media and (.sha256 | sha256_ok);

def document_ref_ok($kind; $schema_version):
  exact(["id","kind","schema_version","sha256"]) and
  .schema_version == $schema_version and .kind == $kind and (.id | id_ok) and
  (.sha256 | sha256_ok);

def identity_ok:
  exact(["adapter_instance_id","execution_boundary_id","principal_id","role"]) and
  (.adapter_instance_id | id_ok) and (.execution_boundary_id | id_ok) and
  (.principal_id | id_ok) and (.role | id_ok);

def path_ok:
  type == "string" and length <= 256 and
  test("\\A/sandbox/[a-z0-9][a-z0-9._/-]*\\z") and
  (test("//|/\\./|/\\.\\./|[?*\\[\\]{}\\\\]|[[:space:]]") | not);

def scalar_ok:
  type == "string" and length <= 256 and
  (test("[[:cntrl:]]") | not);

def truth_or_unknown:
  type == "boolean" or . == "unknown";

def root_ok:
  exact(["access","path","purpose"]) and
  (.access == "read-only" or .access == "read-write" or .access == "write-only") and
  (.path | path_ok) and (.purpose | id_ok);

def resource_ok:
  exact(["access","id","kind","path"]) and
  (.access == "read-only" or .access == "read-write" or .access == "write-only") and
  (.id | id_ok) and .kind == "directory" and (.path | path_ok);

def variable_ok:
  exact(["name","value"]) and
  (.name | type == "string" and test("\\A[A-Z][A-Z0-9_]{0,63}\\z")) and
  (.value | scalar_ok);

def tool_ok:
  exact(["argv","executable","network","resource_ids","sha256","tool_id"]) and
  (.argv | type == "array" and length >= 1 and length <= 32 and
    all(.[];scalar_ok)) and
  (.executable | path_ok) and (.network | type == "boolean") and
  (.resource_ids | type == "array" and length <= 16 and all(.[];id_ok)) and
  (.sha256 | sha256_ok) and (.tool_id | id_ok);

def claim_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "execution_environment_claim" and
  (.id | id_ok) and
  (.body |
    exact(["declaration_status","duty_evaluation_ref","effects","environment",
      "execution_identity","filesystem","isolation","limits","network",
      "policy_set_ref","resources","sensitive_material","stage_result_ref","tools"]) and
    (.declaration_status == "complete" or .declaration_status == "incomplete") and
    (.duty_evaluation_ref | document_ref_ok("duty_separation_evaluation";1)) and
    (.policy_set_ref | document_ref_ok("control_policy_set";1)) and
    (.stage_result_ref | document_ref_ok("stage_result";2)) and
    (.execution_identity | identity_ok) and
    (.effects | exact(["external_writes","target_writes"]) and
      (.external_writes | truth_or_unknown) and (.target_writes | truth_or_unknown)) and
    (.environment | exact(["mode","variables"]) and
      (.mode == "clear-then-allowlist" or .mode == "inherit" or .mode == "unknown") and
      (.variables | type == "array" and length <= 64 and all(.[];variable_ok))) and
    (.filesystem | exact(["read_roots","write_roots"]) and
      (.read_roots | type == "array" and length <= 16 and all(.[];root_ok)) and
      (.write_roots | type == "array" and length <= 16 and all(.[];root_ok))) and
    (.isolation | exact(["candidate_only","disposable","host_access"]) and
      (.candidate_only | truth_or_unknown) and (.disposable | truth_or_unknown) and
      (.host_access | truth_or_unknown)) and
    (.limits | exact(["cpu_time_ms","memory_bytes","output_bytes","process_count",
      "wall_time_ms"]) and all(.[];type == "number" and . >= 0 and floor == .)) and
    (.network | exact(["endpoints","mode"]) and
      (.mode == "allow" or .mode == "deny" or .mode == "unknown") and
      (.endpoints | type == "array" and length <= 32 and all(.[];scalar_ok))) and
    (.resources | type == "array" and length <= 32 and all(.[];resource_ok)) and
    (.sensitive_material | exact(["credential_refs","exposure","secret_refs"]) and
      (.credential_refs | type == "array" and length <= 32 and all(.[];id_ok)) and
      (.secret_refs | type == "array" and length <= 32 and all(.[];id_ok)) and
      (.exposure == "none" or .exposure == "present" or .exposure == "unknown")) and
    (.tools | type == "array" and length <= 16 and all(.[];tool_ok)));

def section_ref_ok:
  exact(["decision_ref","policy_ref","section_id"]) and
  (.section_id | id_ok) and
  (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
  (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json"));

def policy_set_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "control_policy_set" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","fail_mode","policy_version","sections"]) and
    .activation_state == "inactive" and .fail_mode == "closed" and
    .policy_version == "v1" and
    (.core_contract |
      exact(["generation_id","package_ref","semantic_identity"]) and
      .semantic_identity == "core.contracts.v2" and
      (.generation_id | type == "string" and test("\\Ag-[0-9a-f]{64}\\z")) and
      (.package_ref | content_ref_ok("application/vnd.ystack.core-contract+json"))) and
    (.sections | type == "array" and length == 6 and all(.[];section_ref_ok)) and
    (.sections | map(.section_id)) ==
      ["credential-policy","duty-separation","evidence-integrity",
       "kill-switch","risk-gates","sandbox"]);

def duty_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "duty_separation_evaluation" and (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","decision_ref","evaluation_mode",
      "policy_ref","policy_set","reason_ids","reference_semantics","stage","verdict"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .reference_semantics == "identity-only" and
    (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json")) and
    (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
    (.policy_set | exact(["id","sha256"]) and (.id | id_ok) and (.sha256 | sha256_ok)) and
    (.reason_ids | type == "array" and length >= 1 and length <= 64 and
      all(.[];id_ok) and . == (sort | unique)) and
    (.stage | exact(["request_ref","resolved_profile_ref","result_ref"]) and
      (.request_ref | document_ref_ok("stage_request";2)) and
      (.resolved_profile_ref | document_ref_ok("resolved_profile";2)) and
      (.result_ref | document_ref_ok("stage_result";2))) and
    ((.verdict == "satisfied" and .reason_ids == ["duty.satisfied"]) or
     (.verdict == "inconclusive" and .reason_ids == ["actual.capability-unclassified"]) or
     (.verdict == "violated" and
       (.reason_ids | all(. != "duty.satisfied" and . != "actual.capability-unclassified")))));

def duty_binding_ok($set; $set_sha):
  . as $duty_doc |
  ([$set.body.sections[] | select(.section_id == "duty-separation")]) as $sections |
  ($sections | length) == 1 and
  $duty_doc.body.policy_set == {id:$set.id,sha256:$set_sha} and
  $duty_doc.body.policy_ref == $sections[0].policy_ref and
  $duty_doc.body.decision_ref == $sections[0].decision_ref and
  $duty_doc.body.core_contract == $set.body.core_contract and
  $duty_doc.id == $duty_doc.body.stage.result_ref.id;

def policy_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "sandbox_policy" and
  .id == "control-policy.sandbox" and
  (.body |
    exact(["activation_state","environment","evaluation_mode","fail_mode","filesystem",
      "isolation","limits","network","policy_version","reference_semantics",
      "required_role","resources","sensitive_material","tools"]) and
    .activation_state == "inactive" and .evaluation_mode == "observation-only" and
    .fail_mode == "closed" and .policy_version == "v1" and
    .reference_semantics == "identity-only" and .required_role == "verifier" and
    .environment == {mode:"clear-then-allowlist",variables:[
      {name:"LANG",value:"C"},{name:"LC_ALL",value:"C"},
      {name:"PATH",value:"/sandbox/tools"},{name:"TMPDIR",value:"/sandbox/scratch"}]} and
    .filesystem == {read_roots:[
      {access:"read-only",path:"/sandbox/candidate",purpose:"candidate"},
      {access:"read-only",path:"/sandbox/tools",purpose:"toolchain"}],write_roots:[
      {access:"write-only",path:"/sandbox/evidence",purpose:"evidence"},
      {access:"read-write",path:"/sandbox/scratch",purpose:"scratch"}]} and
    .isolation == {candidate_only:true,disposable:true,host_access:false} and
    .limits == {cpu_time_ms:30000,memory_bytes:536870912,output_bytes:10485760,
      process_count:32,wall_time_ms:60000} and
    .network == {endpoints:[],mode:"deny"} and
    .resources == [
      {access:"read-only",id:"resource.candidate",kind:"directory",path:"/sandbox/candidate"},
      {access:"write-only",id:"resource.evidence",kind:"directory",path:"/sandbox/evidence"},
      {access:"read-write",id:"resource.scratch",kind:"directory",path:"/sandbox/scratch"},
      {access:"read-only",id:"resource.toolchain",kind:"directory",path:"/sandbox/tools"}] and
    .sensitive_material == {credential_refs:[],exposure:"none",secret_refs:[]} and
    .tools == [{argv:["verify","--candidate","/sandbox/candidate","--evidence",
      "/sandbox/evidence"],executable:"/sandbox/tools/verifier",network:false,
      resource_ids:["resource.candidate","resource.evidence","resource.scratch"],
      sha256:("1"*64),tool_id:"tool.verifier"}]);

def document_ref($document; $digest):
  {schema_version:$document.schema_version,kind:$document.kind,id:$document.id,sha256:$digest};

($policy[0]) as $p |
($decision[0]) as $decision_doc |
($policy_set[0]) as $set |
($duty[0]) as $duty_doc |
($claim[0]) as $claim_doc |
(if ($p | policy_ok) and ($set | policy_set_ok) and ($duty_doc | duty_ok) and
    ($claim_doc | claim_ok) then true else error("invalid-input") end) |
(if ($duty_doc | duty_binding_ok($set;$policy_set_sha))
 then true else error("duty-binding") end) |
([$set.body.sections[] | select(.section_id == "sandbox")]) as $sandbox_sections |
(if ($sandbox_sections | length) == 1 and
    $sandbox_sections[0].policy_ref == $decision_doc.body.policy_ref and
    $sandbox_sections[0].decision_ref ==
      {content_id:$decision_doc.id,
       media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha}
 then true else error("sandbox-policy-set-binding") end) |
($claim_doc.body) as $body |
((if $body.execution_identity.role == $p.body.required_role then []
   else ["identity.role-denied"] end) +
 (if $body.policy_set_ref == document_ref($set;$policy_set_sha) then []
   else ["policy-set.reference-mismatch"] end) +
 (if $body.duty_evaluation_ref == document_ref($duty_doc;$duty_sha) then []
   else ["duty.reference-mismatch"] end) +
 (if $body.stage_result_ref == $duty_doc.body.stage.result_ref then []
   else ["duty.stage-result-mismatch"] end) +
 (if $duty_doc.body.verdict == "violated" then ["duty.violated"] else [] end) +
 (if $body.network.mode == "allow" or ($body.network.endpoints | length) > 0
   then ["network.not-denied"] else [] end) +
 (if $body.environment.mode == "inherit" then ["environment.not-cleared"] else [] end) +
 (if $body.environment.variables != $p.body.environment.variables
   then ["environment.not-allowlisted"] else [] end) +
 ([$body.environment.variables[] |
    select((.name | test("(?i)(credential|password|secret|token|key)")) or
      (.value | test("(?i)(credential|password|secret|token|key)"))) |
    "environment.sensitive-material"]) +
 ([$body.environment.variables[] | select(.value | test("://")) |
    "environment.external-url"]) +
 (if $body.filesystem.read_roots != $p.body.filesystem.read_roots
   then ["filesystem.read-roots-denied"] else [] end) +
 (if $body.filesystem.write_roots != $p.body.filesystem.write_roots
   then ["filesystem.write-roots-denied"] else [] end) +
 (if $body.isolation.candidate_only == false then ["isolation.not-candidate-only"] else [] end) +
 (if $body.isolation.disposable == false then ["isolation.not-disposable"] else [] end) +
 (if $body.isolation.host_access == true then ["isolation.host-access"] else [] end) +
 (if $body.limits != $p.body.limits then ["limits.not-fixed"] else [] end) +
 (if $body.resources != $p.body.resources then ["resources.not-fixed"] else [] end) +
 (if $body.tools != $p.body.tools then ["tools.not-fixed"] else [] end) +
 ([$body.tools[].argv[] | select(test("://")) | "tools.external-url"]) +
 (if any($body.tools[];.network == true) then ["tools.network-requested"] else [] end) +
 (if $body.sensitive_material.exposure == "present" or
      ($body.sensitive_material.credential_refs | length) > 0 or
      ($body.sensitive_material.secret_refs | length) > 0
   then ["sensitive-material.exposed"] else [] end) +
 (if $body.effects.target_writes == true then ["effects.target-write"] else [] end) +
 (if $body.effects.external_writes == true then ["effects.external-write"] else [] end)
 | sort | unique) as $violations |
((if $body.declaration_status == "incomplete" then ["declaration.incomplete"] else [] end) +
 (if $duty_doc.body.verdict == "inconclusive" then ["duty.inconclusive"] else [] end) +
 (if $body.network.mode == "unknown" then ["network.unknown"] else [] end) +
 (if $body.environment.mode == "unknown" then ["environment.unknown"] else [] end) +
 (if $body.isolation.candidate_only == "unknown" or
      $body.isolation.disposable == "unknown" or $body.isolation.host_access == "unknown"
   then ["isolation.unknown"] else [] end) +
 (if $body.sensitive_material.exposure == "unknown" then ["sensitive-material.unknown"] else [] end) +
 (if $body.effects.target_writes == "unknown" or $body.effects.external_writes == "unknown"
   then ["effects.unknown"] else [] end)
 | sort | unique) as $unknowns |
(if ($violations | length) > 0 then {verdict:"violated",reasons:$violations}
 elif ($unknowns | length) > 0 then {verdict:"inconclusive",reasons:$unknowns}
 else {verdict:"satisfied",reasons:["sandbox.declaration-satisfied"]} end) as $result |
{
  schema_version:1,
  kind:"sandbox_policy_evaluation",
  id:$claim_doc.id,
  body:{
    activation_state:"inactive",
    authority_effect:"none",
    claim_ref:document_ref($claim_doc;$claim_sha),
    decision_ref:{content_id:$decision_doc.id,
      media_type:"application/vnd.ystack.control-decision+json",sha256:$decision_sha},
    duty_evaluation_ref:document_ref($duty_doc;$duty_sha),
    enforcement_proof:"declaration-only",
    evaluation_mode:"observation-only",
    policy_ref:$decision_doc.body.policy_ref,
    policy_set:{id:$set.id,sha256:$policy_set_sha},
    qualification_effect:"none",
    reason_ids:$result.reasons,
    verdict:$result.verdict
  }
}
