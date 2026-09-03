def policy_table:
  {
    roles: [
      {id:"ci", class:"dormant", execution_kinds:["deterministic"], capabilities:[]},
      {id:"execution", class:"dormant", execution_kinds:["deterministic"], capabilities:[]},
      {id:"forge", class:"protected", execution_kinds:["deterministic"], capabilities:["core.forge.materialize-candidate.v2"]},
      {id:"identity", class:"dormant", execution_kinds:["deterministic"], capabilities:[]},
      {id:"producer", class:"protected", execution_kinds:["deterministic","model"], capabilities:["core.harness.produce.v1"]},
      {id:"publisher", class:"protected-dormant", execution_kinds:["deterministic"], capabilities:[]},
      {id:"reviewer", class:"protected", execution_kinds:["deterministic","model"], capabilities:["core.review.change.v1"]},
      {id:"verifier", class:"protected", execution_kinds:["deterministic"], capabilities:["core.verify.run.v1"]}
    ],
    actor_only_roles: ["manager","observer","operator","orchestrator"],
    capabilities: [
      {
        id:"core.forge.materialize-candidate.v2",
        role:"forge",
        argument_shape:"materialize-candidate",
        outcome_family:"change",
        permissions_by_execution:{
          deterministic:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]
        },
        allowed_evidence:["deterministic"],
        required_evidence:["deterministic"]
      },
      {
        id:"core.harness.produce.v1",
        role:"producer",
        argument_shape:"produce",
        outcome_family:"change",
        permissions_by_execution:{
          deterministic:["core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"],
          model:["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]
        },
        allowed_evidence:["deterministic"],
        required_evidence:["deterministic"]
      },
      {
        id:"core.review.change.v1",
        role:"reviewer",
        argument_shape:"review",
        outcome_family:"check",
        permissions_by_execution:{
          deterministic:["core.perm.evidence.write.v1","core.perm.target.read.v1"],
          model:["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.target.read.v1"]
        },
        allowed_evidence:["independent-review"],
        required_evidence:["independent-review"]
      },
      {
        id:"core.verify.run.v1",
        role:"verifier",
        argument_shape:"verify",
        outcome_family:"check",
        permissions_by_execution:{
          deterministic:["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.target.read.v1"]
        },
        allowed_evidence:["architecture","behavioral","deterministic"],
        required_evidence:["deterministic"]
      }
    ],
    permissions: [
      {id:"core.perm.candidate.execute.v1",resource:"exact-candidate",actions:["execute"]},
      {id:"core.perm.candidate-repository.write.v2",resource:"caller-disposable-candidate-repository",actions:["write"]},
      {id:"core.perm.evidence.write.v1",resource:"current-attempt-evidence",actions:["append"]},
      {id:"core.perm.model.invoke.v1",resource:"exact-resolved-model-binding",actions:["invoke"]},
      {id:"core.perm.scratch.write.v1",resource:"caller-disposable-scratch",actions:["write"]},
      {id:"core.perm.target.read.v1",resource:"exact-target-git",actions:["read"]}
    ],
    evidence: [
      {id:"architecture",verdicts:["failed","inconclusive","passed"]},
      {id:"behavioral",verdicts:["failed","inconclusive","passed"]},
      {id:"deterministic",verdicts:["failed","inconclusive","passed"]},
      {id:"independent-review",verdicts:["failed","inconclusive","passed"]}
    ]
  };

def document_kinds:
  ["adapter_manifest","profile","resolved_profile","stage_request","stage_result"];

def semantic_identity: "core.contracts.v2";
def adapter_roles: policy_table.roles | map(.id);
def actor_roles: (adapter_roles + policy_table.actor_only_roles) | sort;
def protected_roles:
  policy_table.roles |
  map(select(.class == "protected" or .class == "protected-dormant") | .id);
def capability_ids: policy_table.capabilities | map(.id);
def permission_ids: policy_table.permissions | map(.id);
def evidence_kinds: policy_table.evidence | map(.id);
def execution_kinds: ["deterministic","model"];
def scope_purposes:
  ["allowed-delta","authority","config-contract","finish-condition","gate-decision",
   "gate-requirement","grant","output-contract","policy","qualification",
   "repository-context","review-policy","selection","verification-instructions",
   "verification-plan"];

def capabilities_for_role($role):
  [policy_table.roles[] | select(.id == $role) | .capabilities] |
  if length == 1 then .[0] else [] end;
def execution_kinds_for_role($role):
  [policy_table.roles[] | select(.id == $role) | .execution_kinds] |
  if length == 1 then .[0] else [] end;
def capability_execution_kinds($capability):
  [policy_table.capabilities[] |
   select(.id == $capability) |
   (.permissions_by_execution | keys)] |
  if length == 1 then .[0] else [] end;
def permissions_for_capability($capability; $execution_kind):
  [policy_table.capabilities[] |
   select(.id == $capability) |
   .permissions_by_execution[$execution_kind] |
   select(. != null)] |
  if length == 1 then .[0] else [] end;
def allowed_evidence_kinds_for_capability($capability):
  [policy_table.capabilities[] | select(.id == $capability) | .allowed_evidence] |
  if length == 1 then .[0] else [] end;
def required_evidence_kinds_for_capability($capability):
  [policy_table.capabilities[] | select(.id == $capability) | .required_evidence] |
  if length == 1 then .[0] else [] end;
def argument_shape_for_capability($capability):
  [policy_table.capabilities[] | select(.id == $capability) | .argument_shape] |
  if length == 1 then .[0] else null end;
def outcome_family_for_capability($capability):
  [policy_table.capabilities[] | select(.id == $capability) | .outcome_family] |
  if length == 1 then .[0] else null end;
def evidence_verdicts:
  policy_table.evidence | map(.verdicts) | unique |
  if length == 1 then .[0] else [] end;

def exact_fields($required; $optional):
  . as $value |
  ($value | type) == "object" and
  (($value | keys_unsorted) - ($required + $optional) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def bounded_set($minimum; $maximum; item_ok; key):
  . as $items |
  ($items | type) == "array" and
  ($items | length) >= $minimum and
  ($items | length) <= $maximum and
  all($items[]; item_ok) and
  (($items | map(key)) as $keys |
   ($keys | length) == ($keys | unique | length) and
   $keys == ($keys | sort));

def enum_set_ok($minimum; $maximum; $allowed):
  . as $items |
  ($items | type) == "array" and
  ($items | length) >= $minimum and
  ($items | length) <= $maximum and
  all($items[]; . as $item | $allowed | index($item) != null) and
  ($items | length) == ($items | unique | length) and
  $items == ($items | sort);

def present_ok(value_ok):
  (exact_fields(["state"];[]) and .state == "absent") or
  (exact_fields(["state","value"];[]) and
   .state == "present" and
   (.value | value_ok));

def id_ok: type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
# Schema receives only values accepted by the raw canonical-byte gate; jq 1.6 preserves -0 here.
def int_ok:
  type == "number" and
  . == floor and
  . >= 0 and
  . <= 2147483647 and
  tostring != "-0";
def sha256_ok: type == "string" and test("\\A[0-9a-f]{64}\\z");
def version_ok: id_ok;
def short_text_ok: type == "string" and utf8bytelength >= 1 and utf8bytelength <= 1024;
def media_type_ok:
  type == "string" and
  length <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");
def patch_media_type_ok: . == "text/x-diff";
def git_oid_ok:
  type == "string" and
  (test("\\A[0-9a-f]{40}\\z") or test("\\A[0-9a-f]{64}\\z"));
def reverse_dns_ok:
  type == "string" and
  (split(".") as $labels |
   ($labels | length) >= 2 and
   all($labels[]; test("\\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\z")));

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
   $month >= 1 and $month <= 12 and
   $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and
   $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

# Oniguruma's bare byte escapes do not match multibyte C1 code points in UTF-8 mode.
def repo_path_ok:
  type == "string" and
  length > 0 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));

def parsed_limits_ok:
  def within($depth):
    if $depth > 32 then false
    elif type == "object" then
      length <= 256 and
      all(keys_unsorted[]; utf8bytelength <= 8192) and
      all(.[]; within($depth + 1))
    elif type == "array" then
      length <= 256 and all(.[]; within($depth + 1))
    elif type == "string" then utf8bytelength <= 8192
    elif type == "number" then int_ok
    else true
    end;
  within(0);

def document_kind_ok:
  type == "string" and (. as $kind | document_kinds | index($kind) != null);
def adapter_role_ok:
  type == "string" and (. as $role | adapter_roles | index($role) != null);
def actor_role_ok:
  type == "string" and (. as $role | actor_roles | index($role) != null);
def capability_id_ok:
  type == "string" and (. as $id | capability_ids | index($id) != null);
def permission_id_ok:
  type == "string" and (. as $id | permission_ids | index($id) != null);
def evidence_kind_ok:
  type == "string" and (. as $kind | evidence_kinds | index($kind) != null);
def execution_kind_ok:
  type == "string" and (. as $kind | execution_kinds | index($kind) != null);
def scope_purpose_ok:
  type == "string" and (. as $purpose | scope_purposes | index($purpose) != null);

def envelope_ok($kind):
  exact_fields(["schema_version","kind","id","body"];[]) and
  .schema_version == 2 and
  .kind == $kind and
  (.kind | document_kind_ok) and
  (.id | id_ok) and
  (.body | type == "object");

def document_envelope_ok:
  (.kind? // "") as $kind |
  ($kind | document_kind_ok) and envelope_ok($kind);

def schema_layer_ok: parsed_limits_ok and document_envelope_ok;

def document_ref_ok:
  exact_fields(["schema_version","kind","id","sha256"];[]) and
  .schema_version == 2 and
  (.kind | document_kind_ok) and
  (.id | id_ok) and
  (.sha256 | sha256_ok);
def document_ref_kind_ok($kind): document_ref_ok and .kind == $kind;

def git_revision_ref_ok:
  exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (if .hash_algorithm == "sha1"
   then (.commit_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else (.commit_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def git_location_ok:
  (exact_fields(["kind"];[]) and .kind == "root") or
  (exact_fields(["kind","value"];[]) and
   .kind == "path" and
   (.value | repo_path_ok));

def git_object_ref_ok:
  exact_fields(["revision","location","object_type","object_id","mode"];[]) and
  (.revision | git_revision_ref_ok) and
  (.location | git_location_ok) and
  (.object_type == "blob" or .object_type == "tree") and
  (if .revision.hash_algorithm == "sha1"
   then (.object_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else (.object_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end) and
  (if .location.kind == "root" then .object_type == "tree" else true end) and
  (if .object_type == "tree"
   then .mode == "040000"
   else (.mode == "100644" or .mode == "100755")
   end);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok) and
  (.content_id | contains(":") | not) and
  (.content_id | contains("/") | not) and
  (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);

def artifact_ref_ok:
  exact_fields(["type","value"];[]) and
  ((.type == "git-object" and (.value | git_object_ref_ok)) or
   (.type == "content" and (.value | content_ref_ok)));

def input_ref_ok:
  exact_fields(["type","value"];[]) and
  ((.type == "artifact" and (.value | artifact_ref_ok)) or
   (.type == "document" and (.value | document_ref_ok)));

def evidence_ref_ok:
  exact_fields(["stage_result_ref","evidence_id"];[]) and
  (.stage_result_ref | document_ref_kind_ok("stage_result")) and
  (.evidence_id | id_ok);

def scope_subject_ok:
  exact_fields(["type","value"];[]) and
  ((.type == "artifact" and (.value | artifact_ref_ok)) or
   (.type == "document" and (.value | document_ref_ok)));

def scope_ref_ok:
  exact_fields(["purpose","decision_record_ref","subject_ref","scope_sha256"];[]) and
  (.purpose | scope_purpose_ok) and
  (.decision_record_ref | content_ref_ok) and
  (.subject_ref | scope_subject_ok) and
  (.scope_sha256 | sha256_ok);
def scope_ref_purpose_ok($purpose): scope_ref_ok and .purpose == $purpose;

def actor_ref_ok:
  exact_fields(
    ["role","implementation_id","implementation_version","adapter_instance_id",
     "principal_id","execution_boundary_id"];
    ["authority_ref"]) and
  (.role | actor_role_ok) and
  (.implementation_id | id_ok) and
  (.implementation_version | version_ok) and
  (.adapter_instance_id | id_ok) and
  (.principal_id | id_ok) and
  (.execution_boundary_id | id_ok) and
  ((has("authority_ref") | not) or (.authority_ref | scope_ref_purpose_ok("authority")));

def environment_ref_ok:
  exact_fields(["environment_id","fingerprint_sha256"];[]) and
  (.environment_id | id_ok) and
  (.fingerprint_sha256 | sha256_ok);

def tool_ref_ok:
  exact_fields(["tool_id","tool_version","package_ref","config_ref"];[]) and
  (.tool_id | id_ok) and
  (.tool_version | version_ok) and
  (.package_ref | git_object_ref_ok) and
  (.config_ref | present_ok(git_object_ref_ok));

def git_patch_ref_ok: content_ref_ok and .media_type == "text/x-diff";

def change_ref_ok:
  exact_fields(["repository_id","base","head","delta_ref"];[]) and
  (.repository_id | id_ok) and
  (.base | present_ok(git_revision_ref_ok)) and
  (.head | git_revision_ref_ok) and
  (.delta_ref | git_patch_ref_ok) and
  .head.repository_id == .repository_id and
  (if .base.state == "present" then .base.value.repository_id == .repository_id else true end);

def source_value_ref_ok:
  exact_fields(["source","value_format","value_sha256"];[]) and
  (.source | git_object_ref_ok) and
  (.value_format == "raw-bytes" or .value_format == "canonical-json") and
  (.value_sha256 | sha256_ok) and
  (if .value_format == "canonical-json" then .source.object_type == "blob" else true end);

def delivered_scope_ok($purpose):
  exact_fields(["ref","input_id"];[]) and
  (.ref | scope_ref_purpose_ok($purpose)) and
  (.input_id | id_ok) and
  .ref.subject_ref.type == "artifact" and
  .ref.subject_ref.value.type == "content";

def fact_ok(value_ok):
  (exact_fields(["state","value","source_ref"];[]) and
   (.state == "recorded" or .state == "computed") and
   (.value | value_ok) and
   (.source_ref | content_ref_ok)) or
  (exact_fields(["state","reason_id"];[]) and
   .state == "unavailable" and
   (.reason_id | id_ok)) or
  (exact_fields(["state"];[]) and .state == "not-applicable");

def git_key:
  [.revision.repository_id,.revision.hash_algorithm,.revision.commit_id,
   .location.kind,(.location.value // ""),.object_type,.object_id,.mode];
def source_git_key: .source | git_key;
