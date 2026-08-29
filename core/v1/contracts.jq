# core/v1/contracts.jq — v1 portable core contract validator (pure, offline).
#
# The only product source for v1 shapes, registries, and relational validation
# (spec: work/portable-core-contracts/spec.md; plan: work/portable-core-contracts/plan.md).
# Consumed only through scripts/core-contract.sh, never invoked directly with a
# filesystem path. This file performs no I/O, launches nothing, and never
# dereferences a ref's target — refs are checked as claims (R6), not proven.
#
# Driver contract, built entirely by the shell wrapper from already-parsed JSON and
# externally computed SHA-256 digests (never a raw path):
#   {mode: "document" | "profile-set" | "stage-run",
#    docs: [{content: <parsed JSON value>, sha256: "<64-hex digest of canonical bytes>"}, ...]}
# docs order by mode:
#   document      -> [DOCUMENT]
#   profile-set   -> [PROFILE, RESOLVED_PROFILE, MANIFEST...]   (1-8 manifests)
#   stage-run     -> [REQUEST, RESOLVED_PROFILE, RESULT]
#
# Exit contract: valid input produces no output (this program prints nothing and
# exits 0). Invalid input prints exactly one line with one allowlisted E_* token.
# Validation order is fixed so one mutation has one stable expected token: parsed
# limits -> shape -> ref -> relation.
#   E_LIMIT    a structural bound is violated (depth/members/string bytes/integer range)
#   E_SHAPE    a value's own fields/types/enums don't match its schema
#   E_REF      a reference's target-document identity (kind/id/digest) is wrong
#   E_RELATION a rule combining two or more documents/fields is violated
# A real jq runtime error (a bug, not a validation failure) is caught and reported
# as E_RUNTIME rather than crashing — the shell wrapper treats any other jq exit
# or extra output as E_RUNTIME too.

def utf8_len: explode | map(if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) | (add // 0);
def is_id: type=="string" and test("^[a-z0-9][a-z0-9._:-]{0,127}$");
def is_sha256: type=="string" and test("^[0-9a-f]{64}$");
def is_shorttext: type=="string" and (utf8_len as $l | $l>=1 and $l<=1024);
# is_time: shape (^...$) plus real UTC calendar/field ranges — a well-formed-looking
# string like "2026-99-99T99:99:99Z" or a non-existent calendar date such as
# "2026-02-31T00:00:00Z" / "2025-02-29T00:00:00Z" (non-leap year) must not pass,
# since it later participates in lexical time ordering (R4/time_le) as if it were
# a genuine instant.
def is_time:
  type=="string" and
  test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
  (capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2}):(?<s>[0-9]{2})Z$") as $c |
   ($c.y|tonumber) as $y | ($c.mo|tonumber) as $mo | ($c.d|tonumber) as $d |
   ($c.h|tonumber) as $h | ($c.mi|tonumber) as $mi | ($c.s|tonumber) as $s |
   ($y % 4 == 0 and ($y % 100 != 0 or $y % 400 == 0)) as $leap |
   ([31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31]) as $days_in_month |
   ($mo>=1 and $mo<=12) and ($d>=1 and $d<=$days_in_month[$mo-1]) and
   ($h>=0 and $h<=23) and ($mi>=0 and $mi<=59) and ($s>=0 and $s<=59));
def is_gitoid: type=="string" and (test("^[0-9a-f]{40}$") or test("^[0-9a-f]{64}$"));
def has_exact_fields(req; opt):
  . as $obj |
  ($obj|type=="object") and
  ((($obj|keys_unsorted)-(req+opt))==[]) and
  (all(req[]; . as $k | $obj|has($k)));
def is_bounded_set(mn; mx; item_ok; keyf):
  (type=="array") and (length>=mn) and (length<=mx) and (all(.[]; item_ok)) and
  ((map(keyf)) as $ks | ($ks|unique|length)==($ks|length) and ($ks==($ks|sort)));
def is_present(item_ok):
  (type=="object") and
  ((has_exact_fields(["state"];[]) and .state=="absent") or
   (has_exact_fields(["state","value"];[]) and .state=="present" and (.value|item_ok)));
def is_version: is_id;
def is_mediatype: type=="string" and (length<=127) and test("^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$");
def is_patch_mediatype: type=="string" and .=="text/x-diff";
def is_reverse_dns:
  type=="string" and
  (split(".") as $labels | ($labels|length)>=2 and all($labels[]; test("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")));
# \x{...} codepoint-brace syntax, not bare \xHH: Oniguruma's bare \xHH matches a
# raw byte, so it only ever matches single-byte (ASCII) input under UTF-8 mode —
# \x80-\x9f as bare bytes silently never matches the 2-byte-encoded C1 codepoints
# it's meant to reject. The brace form matches by actual Unicode codepoint.
def is_repopath:
  type=="string" and (length>0) and
  (test("[\\x{0000}-\\x{001f}\\x{007f}\\x{0080}-\\x{009f}]")|not) and (contains("\\")|not) and
  (split("/") as $s | all($s[]; .!="" and .!="." and .!=".."));
def is_bounded_enum_set(mn; mx; allowed):
  (type=="array") and (length>=mn) and (length<=mx) and
  (all(.[]; . as $v | allowed | index($v)!=null)) and ((unique|length)==length) and (.==(sort));

# .as $k | [...]|index($k), not [...]|index(.): the latter reads the piped array
# back as its own needle, which jq's array-in-array indices search always finds at
# 0 — this pre-existing form always returned true and never actually checked
# membership. Same defect class as is_stale_selector above and is_observed_capability below.
def is_document_kind: type=="string" and (. as $k | ["adapter_manifest","profile","resolved_profile","stage_request","stage_result"]|index($k)!=null);
def document_ref_shape:
  has_exact_fields(["schema_version","kind","id","sha256"];[]) and
  (.schema_version==1) and (.kind|is_document_kind) and (.id|is_id) and (.sha256|is_sha256);
def is_document_ref_kind(k): document_ref_shape and (.kind==k);

def is_git_revision_ref:
  has_exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id|is_id) and (.hash_algorithm as $h | $h=="sha1" or $h=="sha256") and (.commit_id|is_gitoid) and
  (if .hash_algorithm=="sha1" then (.commit_id|test("^[0-9a-f]{40}$")) else (.commit_id|test("^[0-9a-f]{64}$")) end);

def is_git_location:
  (type=="object") and
  ((has_exact_fields(["kind"];[]) and .kind=="root") or
   (has_exact_fields(["kind","value"];[]) and .kind=="path" and (.value|is_repopath)));

def is_git_object_ref:
  has_exact_fields(["revision","location","object_type","object_id","mode"];[]) and
  (.revision|is_git_revision_ref) and (.location|is_git_location) and
  (.object_type as $t | $t=="blob" or $t=="tree") and (.object_id|is_gitoid) and
  (.mode as $m | ["100644","100755","040000"]|index($m)!=null) and
  (if .location.kind=="root" then .object_type=="tree" else true end) and
  (if .revision.hash_algorithm=="sha1" then (.object_id|test("^[0-9a-f]{40}$")) else (.object_id|test("^[0-9a-f]{64}$")) end) and
  (if .object_type=="tree" then .mode=="040000" else (.mode=="100644" or .mode=="100755") end);

def is_content_ref:
  has_exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id|is_id) and (.content_id|test("/")|not) and (.content_id|test(":")|not) and
  (.media_type|is_mediatype) and (.sha256|is_sha256);

def is_artifact_ref:
  (type=="object") and
  ((has_exact_fields(["type","value"];[]) and .type=="git-object" and (.value|is_git_object_ref)) or
   (has_exact_fields(["type","value"];[]) and .type=="content" and (.value|is_content_ref)));

def is_input_ref:
  (type=="object") and
  ((has_exact_fields(["type","value"];[]) and .type=="artifact" and (.value|is_artifact_ref)) or
   (has_exact_fields(["type","value"];[]) and .type=="document" and (.value|document_ref_shape)));

def is_evidence_ref:
  has_exact_fields(["stage_result_ref","evidence_id"];[]) and
  (.stage_result_ref|is_document_ref_kind("stage_result")) and (.evidence_id|is_id);

def is_scope_subject:
  (type=="object") and
  ((has_exact_fields(["type","value"];[]) and .type=="artifact" and (.value|is_artifact_ref)) or
   (has_exact_fields(["type","value"];[]) and .type=="document" and (.value|document_ref_shape)));

def scope_purposes:
  ["selection","repository-context","qualification","grant","policy","authority","gate-requirement",
   "gate-decision","config-contract","output-contract","allowed-delta","verification-plan",
   "review-policy","finish-condition","verification-instructions"];

def is_scope_ref:
  has_exact_fields(["purpose","decision_record_ref","subject_ref","scope_sha256"];[]) and
  (.purpose as $p | scope_purposes|index($p)!=null) and
  (.decision_record_ref|is_content_ref) and (.subject_ref|is_scope_subject) and (.scope_sha256|is_sha256);
def is_scope_ref_purpose(p): is_scope_ref and (.purpose==p);

def adapter_roles: ["producer","verifier","reviewer","publisher","forge","ci","execution","identity"];
def actor_roles_all: adapter_roles + ["operator","manager","orchestrator","observer"];
def execution_kinds: ["model","deterministic"];

def is_actor_ref:
  has_exact_fields(
    ["role","implementation_id","implementation_version","adapter_instance_id","principal_id","execution_boundary_id"];
    ["authority_ref"]) and
  (.role as $r | actor_roles_all|index($r)!=null) and (.implementation_id|is_id) and
  (.implementation_version|is_version) and (.adapter_instance_id|is_id) and (.principal_id|is_id) and
  (.execution_boundary_id|is_id) and
  ((has("authority_ref")|not) or (.authority_ref|is_scope_ref_purpose("authority")));

def is_environment_ref:
  has_exact_fields(["environment_id","fingerprint_sha256"];[]) and (.environment_id|is_id) and (.fingerprint_sha256|is_sha256);

def is_tool_ref:
  has_exact_fields(["tool_id","tool_version","package_ref","config_ref"];[]) and
  (.tool_id|is_id) and (.tool_version|is_version) and (.package_ref|is_git_object_ref) and
  (.config_ref|is_present(is_git_object_ref));

def is_git_patch_ref: is_content_ref and (.media_type|is_patch_mediatype);

def is_change_ref:
  has_exact_fields(["repository_id","base","head","delta_ref"];[]) and
  (.repository_id|is_id) and (.base|is_present(is_git_revision_ref)) and (.head|is_git_revision_ref) and
  (.delta_ref|is_git_patch_ref) and (.head.repository_id==.repository_id) and
  (if (.base.state=="present") then (.base.value.repository_id==.repository_id) else true end);

def is_source_value_ref:
  has_exact_fields(["source","value_format","value_sha256"];[]) and (.source|is_git_object_ref) and
  (.value_format as $f | $f=="raw-bytes" or $f=="canonical-json") and (.value_sha256|is_sha256) and
  (if .value_format=="canonical-json" then .source.object_type=="blob" else true end);

def git_key: [.revision.repository_id,.revision.hash_algorithm,.revision.commit_id,.location.kind,(.location.value // ""),.object_type,.object_id,.mode];
def source_git_key: .source|git_key;


def capability_ids: ["core.harness.produce.v1","core.verify.run.v1","core.review.change.v1"];
def permission_ids:
  ["core.perm.target.read.v1","core.perm.scratch.write.v1","core.perm.candidate.execute.v1",
   "core.perm.evidence.write.v1","core.perm.model.invoke.v1"];
def protected_roles: ["producer","verifier","reviewer","publisher"];
def capability_for_role(role):
  if role=="producer" then "core.harness.produce.v1"
  elif role=="verifier" then "core.verify.run.v1"
  elif role=="reviewer" then "core.review.change.v1"
  else null end;
def permissions_for_capability(cap; is_model):
  if cap=="core.harness.produce.v1" then
    (["core.perm.target.read.v1","core.perm.scratch.write.v1","core.perm.evidence.write.v1"] +
     (if is_model then ["core.perm.model.invoke.v1"] else [] end))
  elif cap=="core.verify.run.v1" then
    ["core.perm.target.read.v1","core.perm.candidate.execute.v1","core.perm.evidence.write.v1"]
  elif cap=="core.review.change.v1" then
    (["core.perm.target.read.v1","core.perm.evidence.write.v1"] +
     (if is_model then ["core.perm.model.invoke.v1"] else [] end))
  else null end;
def required_evidence_kinds_for_capability(cap):
  if cap=="core.harness.produce.v1" then ["deterministic"]
  elif cap=="core.review.change.v1" then ["independent-review"]
  else null end;

def is_model_request:
  has_exact_fields(["provider_id","model_id","effort_id"];[]) and
  (.provider_id|is_id) and (.model_id|is_id) and (.effort_id|is_id);

def is_delivered_scope(purpose):
  has_exact_fields(["ref","input_id"];[]) and (.ref|is_scope_ref_purpose(purpose)) and (.input_id|is_id) and
  (.ref.subject_ref.type=="artifact") and (.ref.subject_ref.value.type=="content");

# delivered_scope_input_ok($ds; $ins): closes a delivered_scope over its request's
# named inputs (R9's launch seam) — ds.input_id must select exactly one named
# input whose value equals the scope's complete subject, and the underlying
# payload media type must be one the launcher can deliver as text/JSON bytes.
# $-bound (value, not filter) params: this is called from inside all(.[]; ...),
# and a plain filter param would be re-evaluated against that inner "." instead
# of staying pinned to the scope/inputs passed at the call site.
def instruction_media_type_ok: .=="text/plain" or .=="application/json";
def delivered_scope_input_ok($ds; $ins):
  ($ins | map(select(.input_id == $ds.input_id))) as $matches |
  (($matches|length) == 1) and ($matches[0].value == $ds.ref.subject_ref) and
  (($ds.ref.subject_ref.value.value.media_type) | instruction_media_type_ok);

def is_capability_args(cap):
  (type=="object") and
  (if cap=="core.harness.produce.v1" then
     (has_exact_fields(["artifact_kind","output_contract"];[]) and
      (.artifact_kind as $k | $k=="plan" or $k=="structured-artifact") and
      (.output_contract|is_delivered_scope("output-contract")))
     or
     (has_exact_fields(["artifact_kind","allowed_delta"];[]) and (.artifact_kind=="git-patch") and
      (.allowed_delta|is_delivered_scope("allowed-delta")))
   elif cap=="core.verify.run.v1" then
     has_exact_fields(["candidate_input_id","verification_plan","network_mode"];[]) and
     (.candidate_input_id|is_id) and (.verification_plan|is_delivered_scope("verification-plan")) and
     (.network_mode=="deny")
   elif cap=="core.review.change.v1" then
     has_exact_fields(["change_ref","review_policy"];[]) and (.change_ref|is_change_ref) and
     (.review_policy|is_delivered_scope("review-policy"))
   else false end);

def is_adapter_manifest_body:
  has_exact_fields(
    ["adapter_version","package_ref","offered_roles","offered_execution_kinds",
     "offered_capabilities","offered_permissions","offered_tools"];
    ["config_contract_ref"]) and
  (.adapter_version|is_version) and (.package_ref|is_git_object_ref) and
  (.offered_roles|is_bounded_enum_set(1;8;adapter_roles)) and
  (.offered_execution_kinds|is_bounded_enum_set(1;2;execution_kinds)) and
  (.offered_capabilities|is_bounded_enum_set(0;3;capability_ids)) and
  (.offered_permissions|is_bounded_enum_set(0;5;permission_ids)) and
  (.offered_tools|is_bounded_set(0;32;is_tool_ref;.tool_id)) and
  ((has("config_contract_ref")|not) or (.config_contract_ref|is_scope_ref_purpose("config-contract")));


def is_profile_binding:
  has_exact_fields(
    ["binding_id","role","manifest_ref","execution_kind","adapter_instance_id","principal_id",
     "execution_boundary_id","package_ref","skill_refs","requested_tools",
     "requested_capabilities","requested_permissions"];
    ["authority_ref","config_ref","prompt_ref","model_request"]) and
  (.binding_id|is_id) and (.role as $r | adapter_roles|index($r)!=null) and
  (.manifest_ref|is_document_ref_kind("adapter_manifest")) and
  (.execution_kind as $e | execution_kinds|index($e)!=null) and
  (.adapter_instance_id|is_id) and (.principal_id|is_id) and (.execution_boundary_id|is_id) and
  ((has("authority_ref")|not) or (.authority_ref|is_scope_ref_purpose("authority"))) and
  (.package_ref|is_git_object_ref) and
  ((has("config_ref")|not) or (.config_ref|is_git_object_ref)) and
  ((has("prompt_ref")|not) or (.prompt_ref|is_git_object_ref)) and
  (.skill_refs|is_bounded_set(0;32;is_git_object_ref;git_key)) and
  (.requested_tools|is_bounded_set(0;32;is_tool_ref;.tool_id)) and
  ((has("model_request")|not) or (.model_request|is_model_request)) and
  (.requested_capabilities|is_bounded_enum_set(0;1;capability_ids)) and
  (.requested_permissions|is_bounded_enum_set(0;5;permission_ids)) and
  (if .execution_kind=="model" then (has("model_request") and has("prompt_ref"))
   else ((has("model_request")|not) and (has("prompt_ref")|not) and (.skill_refs==[])) end) and
  # The contract permits model backing only for producer and reviewer; every other
  # (dormant) role — verifier, publisher, forge, ci, execution, identity — must be
  # deterministic.
  (if .role=="producer" or .role=="reviewer" then true else .execution_kind=="deterministic" end);

def profile_binding_capability_ok:
  (capability_for_role(.role)) as $expected |
  if $expected!=null then
    (.requested_capabilities==[$expected]) and
    ((.requested_permissions|sort)==(permissions_for_capability($expected; .execution_kind=="model")|sort))
  else (.requested_capabilities==[]) and (.requested_permissions==[]) end;

def is_profile_body:
  has_exact_fields(["profile_version","bindings"];[]) and (.profile_version|is_version) and
  (.bindings|is_bounded_set(4;8;is_profile_binding;.binding_id)) and
  (.bindings|all(.[]; profile_binding_capability_ok));

def profile_protected_roles_ok:
  (.bindings) as $bs |
  (all(protected_roles[]; . as $role | ([$bs[]|select(.role==$role)]|length)==1)) and
  ([$bs[]|select(.role as $r | protected_roles|index($r)!=null)]) as $ps |
  (all($ps[]; has("authority_ref"))) and
  (($ps|map(.binding_id)|unique|length)==($ps|length)) and
  (($ps|map(.adapter_instance_id)|unique|length)==($ps|length)) and
  (($ps|map(.principal_id)|unique|length)==($ps|length)) and
  (($ps|map(.execution_boundary_id)|unique|length)==($ps|length)) and
  (($ps|map(.authority_ref.scope_sha256)|unique|length)==($ps|length)) and
  (($bs|map(select(.role as $r | protected_roles|index($r)==null))|map(.role))|(unique|length)==length);

# resolved_bindings_profile_invariants_ok: closes the gap where a resolved profile
# is checked (or trusted, inside a stage-run) on its own, without ever passing
# through mode_profile_set's checks against the plain profile it was resolved
# from. Re-applies the same capability and protected-role invariants
# (profile_binding_capability_ok / profile_protected_roles_ok) to the resolved
# profile's own embedded binding set, so an embedded producer binding with empty
# requested_capabilities/requested_permissions, or protected bindings sharing a
# principal/execution boundary, cannot slip past validate-document or
# validate-stage-run just because they arrived pre-resolved. Reuses the existing
# predicates rather than duplicating them.
def resolved_bindings_profile_invariants_ok(resolved_body):
  (resolved_body.bindings | map(.binding)) as $embedded_bindings |
  ({bindings: $embedded_bindings} | profile_protected_roles_ok) and
  ($embedded_bindings | all(.[]; profile_binding_capability_ok));

def is_tool_source:
  has_exact_fields(["tool_id","package_source","config_source"];[]) and (.tool_id|is_id) and
  (.package_source|is_source_value_ref) and (.config_source|is_present(is_source_value_ref));

def is_resolved_binding:
  has_exact_fields(
    ["binding","adapter_implementation","manifest_source","package_source","config_source",
     "prompt_source","skill_sources","tool_sources"]; []) and
  (.binding|is_profile_binding) and
  (.adapter_implementation|has_exact_fields(["id","version"];[]) and (.id|is_id) and (.version|is_version)) and
  (.manifest_source|is_source_value_ref) and (.manifest_source.value_format=="canonical-json") and
  (.package_source|is_source_value_ref) and
  (.config_source|is_present(is_source_value_ref)) and
  (.prompt_source|is_present(is_source_value_ref)) and
  (.skill_sources|is_bounded_set(0;32;is_source_value_ref;source_git_key)) and
  (.tool_sources|is_bounded_set(0;32;is_tool_source;.tool_id));

def is_resolved_profile_body:
  has_exact_fields(["profile_ref","profile_source","selection_ref","repository_context_ref","bindings"];[]) and
  (.profile_ref|is_document_ref_kind("profile")) and
  (.profile_source|is_source_value_ref) and (.profile_source.value_format=="canonical-json") and
  (.selection_ref|is_scope_ref_purpose("selection")) and
  (.repository_context_ref|is_scope_ref_purpose("repository-context")) and
  (.bindings|is_bounded_set(4;8;is_resolved_binding;.binding.binding_id));

# --- validate-profile-set relations (E_RELATION) ---

def find_one(arr; pred): [arr[] | select(pred)];

# tool_ref's config_ref uses present<T>; profile_binding/resolved's config_ref is a
# plain optional field (present only via `has`). Keep the two conventions distinct.
def binding_manifest_relation_ok(b; m; rb):
  (m.body.offered_roles | index(b.role) != null) and
  (m.body.offered_execution_kinds | index(b.execution_kind) != null) and
  (b.requested_capabilities | all(.[]; . as $c | m.body.offered_capabilities | index($c) != null)) and
  (b.requested_permissions | all(.[]; . as $p | m.body.offered_permissions | index($p) != null)) and
  (b.package_ref == m.body.package_ref) and
  (rb.package_source.source == b.package_ref) and
  (b.requested_tools | all(.[]; . as $rt | m.body.offered_tools | any(.[]; . == $rt))) and
  ((rb.tool_sources | map(.tool_id) | sort) == (b.requested_tools | map(.tool_id) | sort)) and
  (rb.tool_sources | all(.[];
     . as $ts |
     (b.requested_tools[] | select(.tool_id == $ts.tool_id)) as $rt |
     ($ts.package_source.source == $rt.package_ref) and
     (($ts.config_source.state == "present") == ($rt.config_ref.state == "present")) and
     (if $ts.config_source.state == "present" then $ts.config_source.value.source == $rt.config_ref.value else true end))) and
  (if (b | has("config_ref")) then (m.body | has("config_contract_ref")) else true end) and
  ((rb.config_source.state == "present") == (b | has("config_ref"))) and
  (if (b | has("config_ref")) then rb.config_source.value.source == b.config_ref else true end) and
  ((rb.prompt_source.state == "present") == (b | has("prompt_ref"))) and
  (if (b | has("prompt_ref")) then rb.prompt_source.value.source == b.prompt_ref else true end) and
  ((rb.skill_sources | map(source_git_key) | sort) == (b.skill_refs | map(git_key) | sort)) and
  (rb.adapter_implementation.id == m.id) and (rb.adapter_implementation.version == m.body.adapter_version);

def present_source_value(p): if p.state=="present" then [p.value] else [] end;

# resolved_binding_source_claims: every source_value_ref a resolved binding makes
# (manifest/package/optional config/optional prompt/skills/each tool's optional
# package+config), used to enforce one format/digest claim per exact source Git
# object across the whole resolved profile (R6/one-claim-per-source), not just
# within a single binding.
def resolved_binding_source_claims(rb):
  [rb.manifest_source, rb.package_source] +
  present_source_value(rb.config_source) + present_source_value(rb.prompt_source) +
  rb.skill_sources +
  (rb.tool_sources | map([.package_source] + present_source_value(.config_source)) | add // []);

def resolved_profile_source_claims(resolved_body):
  [resolved_body.profile_source] +
  (resolved_body.bindings | map(resolved_binding_source_claims(.)) | add // []);

def source_claims_agree(resolved_body):
  (resolved_profile_source_claims(resolved_body) | group_by(source_git_key)) as $groups |
  all($groups[]; (map(.value_format) | unique | length) == 1 and (map(.value_sha256) | unique | length) == 1);

def profile_set_relations_ok(profile_pair; resolved_body; manifests):
  (profile_pair.content.body) as $profile_body |
  ($profile_body.bindings) as $bindings |
  (resolved_body.bindings) as $rbindings |
  (resolved_body.profile_source.value_sha256 == profile_pair.sha256) and
  (source_claims_agree(resolved_body)) and
  (all($bindings[]; . as $b |
    (find_one(manifests; .content.id == $b.manifest_ref.id and .sha256 == $b.manifest_ref.sha256) | length) == 1)) and
  (all(manifests[]; . as $m |
    $bindings | any(.[]; .manifest_ref.id == $m.content.id and .manifest_ref.sha256 == $m.sha256))) and
  ((($rbindings | map(.binding.binding_id) | sort)) == (($bindings | map(.binding_id) | sort))) and
  (all($bindings[];
    . as $b |
    (find_one(manifests; .content.id == $b.manifest_ref.id and .sha256 == $b.manifest_ref.sha256)[0]) as $mpair |
    ($mpair.content) as $mdoc |
    (find_one($rbindings; .binding.binding_id == $b.binding_id)[0]) as $rb |
    ($rb.binding == $b) and ($rb.manifest_source.value_sha256 == $mpair.sha256) and
    binding_manifest_relation_ok($b; $mdoc; $rb)));




def is_named_input:
  has_exact_fields(["input_id","value"];[]) and (.input_id|is_id) and (.value|is_input_ref);

def risk_tier_ok:
  (type=="object") and
  ((has_exact_fields(["namespace","name"];[]) and .namespace=="core" and (.name=="routine" or .name=="high" or .name=="bootstrap")) or
   (has_exact_fields(["namespace","name"];[]) and (.namespace|is_reverse_dns) and (.name|is_id)));

def is_risk_claim:
  has_exact_fields(["tier","reason_ids","policy_ref","required_gate_refs"];[]) and
  (.tier|risk_tier_ok) and (.reason_ids|is_bounded_set(1;256;is_id;.)) and
  (.policy_ref|is_scope_ref_purpose("policy")) and
  (.required_gate_refs|is_bounded_set(0;256;is_scope_ref_purpose("gate-requirement");.scope_sha256));

def is_operation:
  has_exact_fields(["role","binding_id","capability_id","permissions","arguments"];[]) and
  (.role as $r | adapter_roles|index($r)!=null) and (.binding_id|is_id) and
  (.capability_id as $c | capability_ids|index($c)!=null) and
  (.permissions|is_bounded_enum_set(1;5;permission_ids)) and
  ((.capability_id) as $cap | .arguments | is_capability_args($cap));

def is_stage_request_body:
  has_exact_fields(
    ["initiative_id","workflow_id","stage_id","task_class_id","requested_by","target_repository_id",
     "target_revision","source","base","inputs","prior_evidence_refs","risk","resolved_profile_ref",
     "selection_ref","repository_context_ref","gate_decision_refs","environment_ref","operation",
     "finish_condition","verification_instruction","required_evidence_kinds","requested_at"];
    ["qualification_ref","grant_ref"]) and
  (.initiative_id|is_id) and (.workflow_id|is_id) and (.stage_id|is_id) and (.task_class_id|is_id) and
  (.requested_by|is_actor_ref) and (.target_repository_id|is_id) and
  (.target_revision|is_present(is_git_revision_ref)) and (.source|is_present(is_artifact_ref)) and
  (.base|is_present(is_git_revision_ref)) and
  (.inputs|is_bounded_set(0;256;is_named_input;.input_id)) and
  (.prior_evidence_refs|is_bounded_set(0;256;is_evidence_ref;[.stage_result_ref.sha256,.evidence_id])) and
  (.risk|is_risk_claim) and
  (.resolved_profile_ref|is_document_ref_kind("resolved_profile")) and
  (.selection_ref|is_scope_ref_purpose("selection")) and
  (.repository_context_ref|is_scope_ref_purpose("repository-context")) and
  ((has("qualification_ref")|not) or (.qualification_ref|is_scope_ref_purpose("qualification"))) and
  ((has("grant_ref")|not) or (.grant_ref|is_scope_ref_purpose("grant"))) and
  (.gate_decision_refs|is_bounded_set(0;256;is_scope_ref_purpose("gate-decision");.scope_sha256)) and
  (.environment_ref|is_environment_ref) and (.operation|is_operation) and
  (.finish_condition|is_delivered_scope("finish-condition")) and
  (.verification_instruction|is_delivered_scope("verification-instructions")) and
  (.required_evidence_kinds|is_bounded_enum_set(1;3;["deterministic","behavioral","architecture","independent-review"])) and
  (.requested_at|is_time) and
  (if (.target_revision.state=="absent") then
     (.operation.role=="producer") and (.risk.tier=={namespace:"core",name:"bootstrap"})
   else true end) and
  (if .operation.capability_id=="core.verify.run.v1" then
     (.operation.arguments) as $args |
     (.inputs|any(.[]; .input_id==$args.candidate_input_id and .value.type=="artifact" and .value.value.type=="git-object" and
                       .value.value.value.object_type=="tree")) and
     (.target_revision.state=="present") and
     (((.inputs[]|select(.input_id==$args.candidate_input_id)).value.value.value.revision)==.target_revision.value)
   else true end) and
  (if .operation.capability_id=="core.review.change.v1" then
     (.target_revision.state=="present") and (.operation.arguments.change_ref.head==.target_revision.value) and
     (.operation.arguments.change_ref.base==.base)
   else true end) and
  (if .operation.capability_id=="core.verify.run.v1" then (.required_evidence_kinds|index("deterministic")!=null)
   else ((.required_evidence_kinds|sort)==(required_evidence_kinds_for_capability(.operation.capability_id)|sort)) end) and
  (.target_repository_id) as $repo |
  (if .target_revision.state=="present" then .target_revision.value.repository_id==$repo else true end) and
  (if .base.state=="present" then .base.value.repository_id==$repo else true end) and
  (if .source.state=="present" and .source.value.type=="git-object" then .source.value.value.revision.repository_id==$repo else true end) and
  (.inputs | all(.[];
     if .value.type=="artifact" and .value.value.type=="git-object" then .value.value.value.revision.repository_id==$repo else true end)) and
  (if .operation.capability_id=="core.review.change.v1" then .operation.arguments.change_ref.repository_id==$repo else true end) and
  (.inputs) as $ins |
  ((.operation.arguments) as $args |
   (if ($args|has("output_contract")) then $args.output_contract
    elif ($args|has("allowed_delta")) then $args.allowed_delta
    elif ($args|has("verification_plan")) then $args.verification_plan
    else $args.review_policy end) as $cap_scope |
   [.finish_condition, .verification_instruction, $cap_scope] as $scopes |
   ($scopes | map(.input_id)) as $ids |
   (($ids|unique|length) == ($ids|length)) and
   (if .operation.capability_id=="core.verify.run.v1" then ($ids|index($args.candidate_input_id)==null) else true end) and
   ($scopes | all(.[]; delivered_scope_input_ok(.; $ins))));

# resolved_profile_pair is the driver's {content,sha256} pair for the supplied
# resolved_profile document (never dereferenced beyond its own supplied bytes).
def stage_request_relations_ok(request_body; resolved_profile_pair):
  (resolved_profile_pair.content) as $rp |
  (request_body.resolved_profile_ref.id == $rp.id) and
  (request_body.resolved_profile_ref.sha256 == resolved_profile_pair.sha256) and
  (request_body.selection_ref == $rp.body.selection_ref) and
  (request_body.repository_context_ref == $rp.body.repository_context_ref) and
  ((find_one($rp.body.bindings; .binding.binding_id == request_body.operation.binding_id) | length) == 1) and
  (find_one($rp.body.bindings; .binding.binding_id == request_body.operation.binding_id)[0].binding) as $b |
  ($b.role == request_body.operation.role) and
  (capability_for_role($b.role) == request_body.operation.capability_id) and
  ((request_body.operation.permissions | sort) == (permissions_for_capability(request_body.operation.capability_id; $b.execution_kind == "model") | sort));




def is_actual_binding:
  has_exact_fields(
    ["binding_id","role","adapter_implementation","manifest_ref","package_ref","config_ref",
     "execution_kind","adapter_instance_id","principal_id","execution_boundary_id"];
    ["authority_ref"]) and
  (.binding_id|is_id) and (.role as $r | adapter_roles|index($r)!=null) and
  (.adapter_implementation|has_exact_fields(["id","version"];[]) and (.id|is_id) and (.version|is_version)) and
  (.manifest_ref|is_document_ref_kind("adapter_manifest")) and (.package_ref|is_git_object_ref) and
  (.config_ref|is_present(is_git_object_ref)) and
  (.execution_kind as $e | execution_kinds|index($e)!=null) and
  (.adapter_instance_id|is_id) and (.principal_id|is_id) and (.execution_boundary_id|is_id) and
  ((has("authority_ref")|not) or (.authority_ref|is_scope_ref_purpose("authority")));

def is_observed_capability:
  (type=="object") and
  ((has_exact_fields(["kind","id"];[]) and .kind=="registered" and (.id as $c | capability_ids|index($c)!=null)) or
   (has_exact_fields(["kind","id"];[]) and .kind=="unclassified" and (.id|is_id) and (.id as $c | capability_ids|index($c)==null)));

def is_fact(item_ok):
  (type=="object") and
  ((has_exact_fields(["state","value","source_ref"];[]) and .state=="recorded" and (.value|item_ok) and (.source_ref|is_content_ref)) or
   (has_exact_fields(["state","value","source_ref"];[]) and .state=="computed" and (.value|item_ok) and (.source_ref|is_content_ref)) or
   (has_exact_fields(["state","reason_id"];[]) and .state=="unavailable" and (.reason_id|is_id)) or
   (has_exact_fields(["state"];[]) and .state=="not-applicable"));

def is_execution_metadata:
  has_exact_fields(["kind","provider","model","snapshot","effort","prompt","skills","tools"];[]) and
  (.kind as $k | execution_kinds|index($k)!=null) and
  (.provider|is_fact(is_id)) and (.model|is_fact(is_id)) and (.snapshot|is_fact(is_id)) and
  (.effort|is_fact(is_id)) and (.prompt|is_fact(is_git_object_ref)) and
  (.skills|is_fact(is_bounded_set(0;32;is_git_object_ref;git_key))) and
  (.tools|is_fact(is_bounded_set(0;32;is_tool_ref;.tool_id))) and
  (.tools.state != "not-applicable") and
  (if .kind=="deterministic" then
     ([.provider,.model,.snapshot,.effort,.prompt,.skills] | all(.[]; .state=="not-applicable"))
   else
     ([.provider,.model,.snapshot,.effort,.prompt,.skills] |
       all(.[]; .state=="recorded" or .state=="computed" or .state=="unavailable"))
   end);

def is_execution:
  has_exact_fields(["performer","actual_binding","environment","used_capability","metadata"];[]) and
  (.performer|is_actor_ref) and (.actual_binding|is_actual_binding) and (.environment|is_environment_ref) and
  (.used_capability|is_observed_capability) and (.metadata|is_execution_metadata) and
  (.metadata.kind==.actual_binding.execution_kind) and (.performer.role==.actual_binding.role);

def evidence_kinds: ["deterministic","behavioral","architecture","independent-review"];
def v_verdicts: ["passed","failed","inconclusive"];

def is_evidence:
  has_exact_fields(["evidence_id","kind","verdict","proof_ref"];[]) and
  (.evidence_id|is_id) and (.kind as $k | evidence_kinds|index($k)!=null) and
  (.verdict as $v | v_verdicts|index($v)!=null) and (.proof_ref|is_content_ref);

def terminal_statuses: ["completed","skipped","stale","blocked","failed","cancelled"];

def is_reason:
  has_exact_fields(["reason_id"];["summary"]) and (.reason_id|is_id) and
  ((has("summary")|not) or (.summary|is_shorttext));

def is_output:
  has_exact_fields(["output_id","ref"];[]) and (.output_id|is_id) and (.ref|is_content_ref);

# Note the `.kind as $k | [...] | index($k)` form below, not `[...] | index(.kind)`:
# the latter reads .kind off the piped-in array (a pre-existing latent bug — every
# selector using this branch, i.e. everything but "input"/"gate-decision", crashed
# with E_RUNTIME instead of validating), since a pipe rebinds "." to its left side.
def is_stale_selector:
  (type=="object") and
  ((has_exact_fields(["kind"];[]) and (.kind as $k | ["target","source","base","resolved-profile","qualification","environment"]|index($k)!=null)) or
   (has_exact_fields(["kind","input_id"];[]) and .kind=="input" and (.input_id|is_id)) or
   (has_exact_fields(["kind","scope_sha256"];[]) and .kind=="gate-decision" and (.scope_sha256|is_sha256)));

def stale_observed_ok:
  (.selector.kind) as $k |
  if $k=="target" then (.observed|is_present(is_git_revision_ref))
  elif $k=="source" then (.observed|is_present(is_artifact_ref))
  elif $k=="base" then (.observed|is_present(is_git_revision_ref))
  elif $k=="resolved-profile" then (.observed|is_present(is_document_ref_kind("resolved_profile")))
  elif $k=="qualification" then (.observed|is_present(is_scope_ref_purpose("qualification")))
  elif $k=="environment" then (.observed|is_present(is_environment_ref))
  elif $k=="input" then (.observed|is_present(is_input_ref))
  elif $k=="gate-decision" then (.observed|is_present(is_scope_ref_purpose("gate-decision")))
  else false end;

def is_stale_observation:
  has_exact_fields(["selector","observed"];[]) and (.selector|is_stale_selector) and stale_observed_ok;

# stale_observation_ok($req_body; $obs): derives the expected value from the exact
# request slot/set member the selector names and requires the claimed observation
# to differ from it (Design > "Stage result and evidence"). Also requires an
# input/gate-decision selector to actually name something the request carries —
# a selector for nothing is not a stale claim about anything. $-bound params for
# the same reason as delivered_scope_input_ok above (called from all(.[]; ...)).
def stale_observation_ok($req_body; $obs):
  ($obs.selector.kind) as $k |
  if $k=="target" then
    ($req_body.target_revision) as $exp |
    ($obs.observed != $exp) and
    (if $obs.observed.state=="present" then $obs.observed.value.repository_id==$req_body.target_repository_id else true end)
  elif $k=="base" then
    ($req_body.base) as $exp |
    ($obs.observed != $exp) and
    (if $obs.observed.state=="present" then
       ($obs.observed.value.repository_id==$req_body.target_repository_id) and
       (if $exp.state=="present" then $obs.observed.value.hash_algorithm==$exp.value.hash_algorithm else true end)
     else true end)
  elif $k=="source" then
    ($req_body.source) as $exp |
    ($obs.observed != $exp) and
    (if ($obs.observed.state=="present" and $obs.observed.value.type=="git-object") then
       $obs.observed.value.value.revision.repository_id==$req_body.target_repository_id
     else true end)
  elif $k=="resolved-profile" then
    ({state:"present", value: $req_body.resolved_profile_ref}) as $exp |
    ($obs.observed != $exp) and
    (if $obs.observed.state=="present" then
       $obs.observed.value.kind=="resolved_profile" and $obs.observed.value.id==$req_body.resolved_profile_ref.id
     else true end)
  elif $k=="qualification" then
    ((if ($req_body|has("qualification_ref")) then {state:"present", value: $req_body.qualification_ref} else {state:"absent"} end)) as $exp |
    ($obs.observed != $exp)
  elif $k=="environment" then
    ({state:"present", value: $req_body.environment_ref}) as $exp |
    ($obs.observed != $exp) and
    (if $obs.observed.state=="present" then $obs.observed.value.environment_id==$req_body.environment_ref.environment_id else true end)
  elif $k=="input" then
    ($req_body.inputs | map(select(.input_id==$obs.selector.input_id))) as $matches |
    (($matches|length)==1) and
    (({state:"present", value:$matches[0].value}) as $exp | $obs.observed != $exp)
  elif $k=="gate-decision" then
    ($req_body.gate_decision_refs | map(select(.scope_sha256==$obs.selector.scope_sha256))) as $matches |
    (($matches|length)==1) and
    (({state:"present", value:$matches[0]}) as $exp | $obs.observed != $exp)
  else false end;

def outcome_family_values(family):
  if family=="change" then ["changed","no-change","inconclusive"]
  elif family=="check" then ["passed","failed","inconclusive"]
  else null end;

def is_outcome:
  has_exact_fields(["family","value"];[]) and (.family as $f | $f=="change" or $f=="check") and
  (.value as $v | outcome_family_values(.family)|index($v)!=null);

def is_id_int: type=="number" and (.==(.|floor)) and .>=1 and .<=2147483647;

def is_stage_result_body:
  has_exact_fields(
    ["request_ref","resolved_profile_ref","attempt_id","attempt_number","reported_by","status",
     "outputs","diagnostics","evidence","recorded_at"];
    ["outcome","reason","stale_observations","delta_ref","execution","started_at","finished_at"]) and
  (.request_ref|is_document_ref_kind("stage_request")) and
  (.resolved_profile_ref|is_document_ref_kind("resolved_profile")) and
  (.attempt_id|is_id) and (.attempt_number|is_id_int) and (.reported_by|is_actor_ref) and
  (.status as $s | terminal_statuses|index($s)!=null) and
  ((has("outcome")|not) or (.outcome|is_outcome)) and
  ((has("reason")|not) or (.reason|is_reason)) and
  ((has("stale_observations")|not) or
    (.stale_observations|is_bounded_set(1;256;is_stale_observation;[.selector.kind,(.selector.input_id // .selector.scope_sha256 // "")]))) and
  (.outputs|is_bounded_set(0;256;is_output;.output_id)) and
  ((has("delta_ref")|not) or (.delta_ref|is_git_patch_ref)) and
  (.diagnostics|is_bounded_set(0;256;is_content_ref;.content_id)) and
  ((has("execution")|not) or (.execution|is_execution)) and
  (.evidence|is_bounded_set(0;256;is_evidence;.evidence_id)) and
  ((has("started_at")|not) or (.started_at|is_time)) and
  ((has("finished_at")|not) or (.finished_at|is_time)) and
  (.recorded_at|is_time) and
  ((.evidence|map(.kind)|unique|length)==(.evidence|length));


def outcome_family_for_role(role): if role=="producer" then "change" else "check" end;

# Status presence matrix (Design > "Stage result and evidence" table). cap_family is
# the requesting operation's outcome family ("change" for producer, "check" otherwise).
def status_presence_ok(cap_family):
  .status as $s |
  if $s=="completed" then
    has("execution") and has("outcome") and has("started_at") and has("finished_at") and
    (.diagnostics==[]) and (has("stale_observations")|not) and
    ((.outcome.value=="inconclusive") == has("reason"))
  elif $s=="skipped" then
    has("reason") and (.outputs==[]) and (.diagnostics==[]) and (.evidence==[]) and
    (has("stale_observations")|not) and (has("execution")|not) and (has("outcome")|not) and
    (has("delta_ref")|not) and (has("started_at")|not) and (has("finished_at")|not)
  elif $s=="stale" then
    has("reason") and has("stale_observations") and (.outputs==[]) and (.diagnostics==[]) and (.evidence==[]) and
    (has("execution")|not) and (has("outcome")|not) and (has("delta_ref")|not) and
    (has("started_at")|not) and (has("finished_at")|not)
  elif $s=="blocked" then
    has("reason") and (.outputs==[]) and (.evidence==[]) and (has("execution")|not) and (has("outcome")|not) and
    (has("delta_ref")|not) and (has("stale_observations")|not) and (has("started_at")|not) and (has("finished_at")|not)
  elif $s=="failed" or $s=="cancelled" then
    has("reason") and (.outputs==[]) and (has("delta_ref")|not) and (has("stale_observations")|not) and
    (if $s=="failed" then (.diagnostics|length)>0 else true end) and
    (if has("execution") then
       has("outcome") and has("started_at") and has("finished_at") and (.evidence|length)>0 and
       (.outcome.family==cap_family) and (.outcome.value=="inconclusive") and
       (.evidence|all(.[]; .verdict=="failed" or .verdict=="inconclusive"))
     else
       (has("outcome")|not) and (has("started_at")|not) and (has("finished_at")|not) and (.evidence==[])
     end)
  else false end;

def evidence_kind_allowed_for_role(role; kind):
  if role=="producer" then kind=="deterministic"
  elif role=="verifier" then kind=="deterministic" or kind=="behavioral" or kind=="architecture"
  elif role=="reviewer" then kind=="independent-review"
  else false end;

def time_le(a; b): a <= b;

def completed_outcome_relation_ok(op; result):
  (op.role) as $role |
  if $role=="producer" then
    (result.outputs|length) as $n |
    if $n==0 then (result.outcome=={family:"change",value:"no-change"}) and (result|has("delta_ref")|not)
    elif $n==1 then
      (if (op.arguments|has("allowed_delta")) then
         (result.outcome=={family:"change",value:"changed"}) and (result|has("delta_ref")) and
         (result.delta_ref==result.outputs[0].ref)
       else
         (result.outcome=={family:"change",value:"changed"}) and (result|has("delta_ref")|not)
       end)
    else false
    end
  else
    ((result.outputs==[]) and (result|has("delta_ref")|not)) and
    (if (result.evidence|any(.[]; .verdict=="failed")) then result.outcome=={family:"check",value:"failed"}
     elif (result.evidence|any(.[]; .verdict=="inconclusive")) then result.outcome=={family:"check",value:"inconclusive"}
     else result.outcome=={family:"check",value:"passed"} end)
  end;

def is_fact_value_ok(expected):
  if .state=="recorded" or .state=="computed" then .value==expected
  elif .state=="unavailable" then true
  else false end;

# metadata_requested_unavailable: true when a requested provider/model/effort/
# prompt/skills/tools fact is unavailable. The contract forces a completed result
# whose execution carries such a fact to be inconclusive — availability is an
# input to the outcome relation, not a presence check that passes independently
# of it. tools is included via this same path: a completed result cannot stay
# conclusive when the actual tool use it evidences cannot be established, exactly
# like the other requested facts. Deliberately excludes snapshot (not a requested
# fact — it has no corresponding binding field to be honest about).
def metadata_requested_unavailable(meta):
  [meta.provider, meta.model, meta.effort, meta.prompt, meta.skills, meta.tools] | any(.[]; .state=="unavailable");

# actual_facts_ok: model bindings additionally require recorded/computed facts to
# equal the resolved binding's own model_request/prompt_ref/skill_refs (R12 — an
# actual fact is an honest claim about what actually ran, not just a syntactically
# valid one), and recorded/computed tools must be full tool_ref matches from the
# binding's requested tools, not merely same-ID matches.
def actual_facts_ok(binding; meta):
  (if binding.execution_kind=="deterministic" then true
   else
     (meta.provider|is_fact_value_ok(binding.model_request.provider_id)) and
     (meta.model|is_fact_value_ok(binding.model_request.model_id)) and
     (meta.effort|is_fact_value_ok(binding.model_request.effort_id)) and
     (meta.prompt|is_fact_value_ok(binding.prompt_ref)) and
     (meta.skills|is_fact_value_ok(binding.skill_refs))
   end) and
  (if (meta.tools.state=="recorded" or meta.tools.state=="computed") then
     (meta.tools.value) as $used |
     (binding.requested_tools) as $req_tools |
     all($used[]; . as $u | $req_tools | any(.[]; . == $u))
   else true end);

# completed_execution_matches_binding: for completed non-inconclusive execution the
# spec requires actual binding to equal "the corresponding projection of the
# selected resolved binding" across implementation, manifest ref, config, and
# authority, plus a matching performer identity/boundary and the request's own
# environment — not just the handful of fields checked before this fix.
def completed_execution_matches_binding(op; rb; exec_; env_ref):
  (rb != null) and
  (exec_.actual_binding.binding_id == rb.binding.binding_id) and
  (exec_.actual_binding.role == rb.binding.role) and
  (exec_.actual_binding.adapter_implementation == rb.adapter_implementation) and
  (exec_.actual_binding.manifest_ref == rb.binding.manifest_ref) and
  (exec_.actual_binding.package_ref == rb.binding.package_ref) and
  (if (rb.binding|has("config_ref")) then
     (exec_.actual_binding.config_ref.state=="present") and (exec_.actual_binding.config_ref.value==rb.binding.config_ref)
   else exec_.actual_binding.config_ref.state=="absent" end) and
  (exec_.actual_binding.execution_kind == rb.binding.execution_kind) and
  (exec_.actual_binding.adapter_instance_id == rb.binding.adapter_instance_id) and
  (exec_.actual_binding.principal_id == rb.binding.principal_id) and
  (exec_.actual_binding.execution_boundary_id == rb.binding.execution_boundary_id) and
  ((exec_.actual_binding|has("authority_ref")) == (rb.binding|has("authority_ref"))) and
  (if (rb.binding|has("authority_ref")) then exec_.actual_binding.authority_ref==rb.binding.authority_ref else true end) and
  (exec_.performer.role == rb.binding.role) and
  (exec_.performer.implementation_id == exec_.actual_binding.adapter_implementation.id) and
  (exec_.performer.implementation_version == exec_.actual_binding.adapter_implementation.version) and
  (exec_.performer.adapter_instance_id == rb.binding.adapter_instance_id) and
  (exec_.performer.principal_id == rb.binding.principal_id) and
  (exec_.performer.execution_boundary_id == rb.binding.execution_boundary_id) and
  ((exec_.performer|has("authority_ref")) == (rb.binding|has("authority_ref"))) and
  (if (rb.binding|has("authority_ref")) then exec_.performer.authority_ref==rb.binding.authority_ref else true end) and
  (exec_.environment == env_ref) and
  (exec_.used_capability.kind == "registered") and (exec_.used_capability.id == op.capability_id) and
  actual_facts_ok(rb.binding; exec_.metadata);

# request_pair/resolved_pair/result_body: request_pair and resolved_pair are the
# driver's {content,sha256} pairs; result_body is the already-shape-checked stage_result.
def stage_result_relations_ok(request_pair; resolved_pair; result_body):
  (request_pair.content) as $req | (resolved_pair.content) as $rp |
  (result_body.request_ref.id == $req.id) and (result_body.request_ref.sha256 == request_pair.sha256) and
  (result_body.resolved_profile_ref.id == $rp.id) and (result_body.resolved_profile_ref.sha256 == resolved_pair.sha256) and
  ($req.body.resolved_profile_ref.id == $rp.id) and ($req.body.resolved_profile_ref.sha256 == resolved_pair.sha256) and
  ($req.body.operation) as $op |
  (find_one($rp.body.bindings; .binding.binding_id == $op.binding_id)) as $rbm |
  (($rbm | length) == 1) and ($rbm[0]) as $rb |
  (result_body.evidence | all(.[]; evidence_kind_allowed_for_role($op.role; .kind))) and
  ($req.body.requested_at) as $t0 |
  (if (result_body | has("execution")) then
     time_le($t0; result_body.started_at) and time_le(result_body.started_at; result_body.finished_at) and
     time_le(result_body.finished_at; result_body.recorded_at)
   else time_le($t0; result_body.recorded_at) end) and
  (result_body.attempt_number >= 1) and
  (if result_body.status=="stale" then
     (result_body.stale_observations | all(.[]; stale_observation_ok($req.body; .)))
   else true end) and
  (if result_body.status=="completed" then
     (($req.body.required_evidence_kinds | sort) == (result_body.evidence | map(.kind) | sort)) and
     (if ((result_body.evidence | any(.[]; .verdict != "passed")) or
          metadata_requested_unavailable(result_body.execution.metadata)) then
        (result_body.outcome.family == outcome_family_for_role($op.role)) and
        (result_body.outcome.value == "inconclusive") and
        (result_body.outputs == []) and (result_body | has("delta_ref") | not) and
        (result_body | has("reason"))
      else completed_outcome_relation_ok($op; result_body) end) and
     # The contract allows a completed-inconclusive record's execution facts to
     # differ from the resolved binding, so the record can preserve what actually
     # went wrong; only a completed non-inconclusive result requires the equality.
     (if result_body.outcome.value != "inconclusive" then
        completed_execution_matches_binding($op; $rb; result_body.execution; $req.body.environment_ref)
      else true end) and
     (result_body.evidence | all(.[]; select(.kind=="independent-review") |
        (.verdict != "passed") or
        (result_body.execution.performer.role=="reviewer" and
         result_body.execution.used_capability.kind=="registered" and
         result_body.execution.used_capability.id=="core.review.change.v1")))
   else true end);



# ---------------------------------------------------------------------------
# Global structural limits (R5) — every numeric leaf in this closed schema is
# meant to be an Int (0..2147483647); a float or a negative number is a limit
# violation here rather than a separate float-shape rule.
# ---------------------------------------------------------------------------

def limits_violated:
  def bad(d):
    if d > 32 then true
    elif type=="object" then
      (keys_unsorted|length) > 256 or
      (keys_unsorted|any(.[]; utf8_len > 8192)) or
      any(.[]; bad(d+1))
    elif type=="array" then (length) > 256 or any(.[]; bad(d+1))
    elif type=="string" then (utf8_len) > 8192
    elif type=="number" then (. != (.|floor)) or . < 0 or . > 2147483647
    else false end;
  bad(0);

def any_doc_limits_violated(docs): any(docs[]; .content|limits_violated);

# ---------------------------------------------------------------------------
# Dispatch (validate-document / validate-profile-set / validate-stage-run)
# ---------------------------------------------------------------------------

def envelope_ok(kind; body_ok):
  has_exact_fields(["schema_version","kind","id","body"];[]) and
  (.schema_version==1) and (.kind==kind) and (.id|is_id) and (.body|body_ok);

def document_shape_ok:
  (.kind) as $k |
  if $k=="adapter_manifest" then envelope_ok("adapter_manifest"; is_adapter_manifest_body)
  elif $k=="profile" then envelope_ok("profile"; is_profile_body)
  elif $k=="resolved_profile" then envelope_ok("resolved_profile"; is_resolved_profile_body)
  elif $k=="stage_request" then envelope_ok("stage_request"; is_stage_request_body)
  elif $k=="stage_result" then envelope_ok("stage_result"; is_stage_result_body)
  else false end;

def document_ref_ok:
  (type=="object") and (has("kind")) and (.kind|is_document_kind) and document_shape_ok;

def mode_document(docs):
  (docs[0].content) as $doc |
  if ($doc|document_ref_ok|not) then "E_SHAPE"
  elif ($doc.kind=="profile" and ($doc.body|profile_protected_roles_ok|not)) then "E_RELATION"
  elif ($doc.kind=="resolved_profile" and (resolved_bindings_profile_invariants_ok($doc.body)|not)) then "E_RELATION"
  else null end;

def mode_profile_set(docs):
  (docs[0]) as $profile | (docs[1]) as $resolved | (docs[2:]) as $manifests |
  if ($manifests|length) < 1 or ($manifests|length) > 8 then "E_USAGE"
  elif ($profile.content|document_ref_ok|not) or ($profile.content.kind != "profile") then "E_SHAPE"
  elif ($resolved.content|document_ref_ok|not) or ($resolved.content.kind != "resolved_profile") then "E_SHAPE"
  elif (any($manifests[]; (.content|document_ref_ok|not) or (.content.kind != "adapter_manifest"))) then "E_SHAPE"
  elif ($profile.content.body|profile_protected_roles_ok|not) then "E_RELATION"
  elif ($resolved.content.body.profile_ref.id != $profile.content.id) or
       ($resolved.content.body.profile_ref.sha256 != $profile.sha256) then "E_REF"
  elif (($manifests|map(.content.id)|unique|length) != ($manifests|length)) then "E_REF"
  elif (profile_set_relations_ok($profile; $resolved.content.body; $manifests)|not) then "E_RELATION"
  else null end;

def mode_stage_run(docs):
  (docs[0]) as $request | (docs[1]) as $resolved | (docs[2]) as $result |
  if ($request.content|document_ref_ok|not) or ($request.content.kind != "stage_request") then "E_SHAPE"
  elif ($resolved.content|document_ref_ok|not) or ($resolved.content.kind != "resolved_profile") then "E_SHAPE"
  elif ($result.content|document_ref_ok|not) or ($result.content.kind != "stage_result") then "E_SHAPE"
  elif (resolved_bindings_profile_invariants_ok($resolved.content.body)|not) then "E_RELATION"
  elif ($request.content.body.resolved_profile_ref.id != $resolved.content.id) or
       ($request.content.body.resolved_profile_ref.sha256 != $resolved.sha256) then "E_REF"
  elif (stage_request_relations_ok($request.content.body; $resolved)|not) then "E_RELATION"
  elif ($result.content.body.request_ref.id != $request.content.id) or
       ($result.content.body.request_ref.sha256 != $request.sha256) or
       ($result.content.body.resolved_profile_ref.id != $resolved.content.id) or
       ($result.content.body.resolved_profile_ref.sha256 != $resolved.sha256) then "E_REF"
  elif ($result.content.body|status_presence_ok(outcome_family_for_role($request.content.body.operation.role))|not) then "E_RELATION"
  elif (stage_result_relations_ok($request; $resolved; $result.content.body)|not) then "E_RELATION"
  else null end;

def dispatch:
  if .mode=="document" then (if (.docs|length) != 1 then "E_USAGE" else mode_document(.docs) end)
  elif .mode=="profile-set" then (if (.docs|length) < 3 then "E_USAGE" else mode_profile_set(.docs) end)
  elif .mode=="stage-run" then (if (.docs|length) != 3 then "E_USAGE" else mode_stage_run(.docs) end)
  else "E_USAGE" end;

def main: if any_doc_limits_violated(.docs) then "E_LIMIT" else dispatch end;

try (main as $r | if $r == null then empty else $r end) catch "E_RUNTIME"
