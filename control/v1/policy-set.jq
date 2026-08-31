def exact($required):
  type == "object" and (keys | sort) == ($required | sort);

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def content_ref_ok($media_type):
  exact(["content_id","media_type","sha256"]) and
  (.content_id | id_ok) and .media_type == $media_type and
  (.sha256 | sha256_ok);

def section_shape_ok:
  exact(["decision_ref","policy_ref","section_id"]) and
  (.section_id | id_ok) and
  (.policy_ref | content_ref_ok("application/vnd.ystack.control-policy+json")) and
  (.decision_ref | content_ref_ok("application/vnd.ystack.control-decision+json"));

def core_contract_shape_ok:
  exact(["generation_id","package_ref","semantic_identity"]) and
  (.semantic_identity | id_ok) and
  (.generation_id | test("\\Ag-[0-9a-f]{64}\\z")) and
  (.package_ref | content_ref_ok("application/vnd.ystack.core-contract+json"));

def shape_ok:
  exact(["body","id","kind","schema_version"]) and
  .schema_version == 1 and .kind == "control_policy_set" and
  (.id | id_ok) and
  (.body |
    exact(["activation_state","core_contract","fail_mode","policy_version","sections"]) and
    (.activation_state | type == "string") and
    (.fail_mode | type == "string") and
    (.policy_version | type == "string") and
    (.core_contract | core_contract_shape_ok) and
    (.sections | type == "array" and length >= 1 and length <= 16 and
      all(.[];section_shape_ok)));

def expected_sections:
  ["credential-policy","duty-separation","evidence-integrity",
   "kill-switch","risk-gates","sandbox"];

def relations_ok:
  .body as $body |
  $body.policy_version == "v1" and
  $body.activation_state == "inactive" and
  $body.fail_mode == "closed" and
  ($body.core_contract.semantic_identity |
    test("\\Acore\\.contracts\\.v[1-9][0-9]*\\z")) and
  ($body.sections | map(.section_id)) == expected_sections and
  ($body.sections | all(.[];
    .policy_ref.content_id == ("control-policy:" + .section_id))) and
  ($body.sections | map(.policy_ref.sha256) | unique | length) == 6 and
  ($body.sections | map(.decision_ref.content_id) | unique | length) == 6 and
  ($body.sections | map(.decision_ref.sha256) | unique | length) == 6;

if (shape_ok | not) then "E_SHAPE"
elif (relations_ok | not) then "E_RELATION"
else empty
end
