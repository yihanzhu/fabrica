# scripts/test/core-contract-fixtures.jq — readable builders for one valid
# five-document graph (manifest -> profile -> resolved profile -> request ->
# result), used only by scripts/test/core-contract.test.sh.
#
# These builders create DATA only. They contain no validation predicate,
# acceptance rule, or expected-verdict logic, and are never loaded by
# core/v1/contracts.jq or scripts/core-contract.sh. The test script — not this
# file — independently canonicalizes each document with pinned jq and hashes it
# with an external SHA tool before wiring that digest into the next document's
# ref, so no digest here is ever self-referential.

def gitrev: {repository_id: "repo-a", hash_algorithm: "sha1", commit_id: ("a" * 40)};
def gitobj(loc; ot; oid; mode): {revision: gitrev, location: loc, object_type: ot, object_id: oid, mode: mode};
def rootref(oid): gitobj({kind: "root"}; "tree"; oid; "040000");
def blobref(path; oid): gitobj({kind: "path", value: path}; "blob"; oid; "100644");
def contentref(id; sha): {content_id: id, media_type: "application/json", sha256: sha};
def scoperef(purpose; subj_id; sha):
  {purpose: purpose, decision_record_ref: contentref("dec-" + subj_id; sha),
   subject_ref: {type: "artifact", value: {type: "content", value: contentref(subj_id; sha)}},
   scope_sha256: sha};
def docref(kind; id; sha): {schema_version: 1, kind: kind, id: id, sha256: sha};
def envelope(kind; id; body): {schema_version: 1, kind: kind, id: id, body: body};
def actorref(role): {role: role, implementation_id: ("impl-" + role), implementation_version: "v1",
  adapter_instance_id: ("inst-" + role), principal_id: ("pri-" + role), execution_boundary_id: ("bnd-" + role)};

def role_capability(role):
  if role == "producer" then "core.harness.produce.v1"
  elif role == "verifier" then "core.verify.run.v1"
  elif role == "reviewer" then "core.review.change.v1"
  else null end;
def role_permissions(role):
  if role == "producer" then ["core.perm.target.read.v1", "core.perm.scratch.write.v1", "core.perm.evidence.write.v1"]
  elif role == "verifier" then ["core.perm.target.read.v1", "core.perm.candidate.execute.v1", "core.perm.evidence.write.v1"]
  elif role == "reviewer" then ["core.perm.target.read.v1", "core.perm.evidence.write.v1"]
  else [] end;

def manifest_body(role):
  {adapter_version: "v1", package_ref: rootref("3" * 40),
   offered_roles: [role], offered_execution_kinds: ["deterministic"],
   offered_capabilities: (if role_capability(role) != null then [role_capability(role)] else [] end),
   offered_permissions: role_permissions(role), offered_tools: []};
def manifest_doc(role): envelope("adapter_manifest"; "manifest-" + role; manifest_body(role));

def binding(role; bid; auth_sha; manifest_sha):
  {binding_id: bid, role: role, manifest_ref: docref("adapter_manifest"; "manifest-" + role; manifest_sha),
   execution_kind: "deterministic", adapter_instance_id: ("inst-" + bid), principal_id: ("pri-" + bid),
   execution_boundary_id: ("bnd-" + bid), package_ref: rootref("3" * 40),
   skill_refs: [], requested_tools: [],
   requested_capabilities: (if role_capability(role) != null then [role_capability(role)] else [] end),
   requested_permissions: role_permissions(role)}
  + (if ["producer", "verifier", "reviewer", "publisher"] | index(role) != null
     then {authority_ref: scoperef("authority"; "auth-" + bid; auth_sha)} else {} end);

# manifest_shas: {producer:sha, verifier:sha, reviewer:sha, publisher:sha}
def profile_body(manifest_shas):
  {profile_version: "v1",
   bindings: [
     binding("producer"; "b-producer"; "4" * 64; manifest_shas.producer),
     binding("verifier"; "b-verifier"; "5" * 64; manifest_shas.verifier),
     binding("reviewer"; "b-reviewer"; "6" * 64; manifest_shas.reviewer),
     binding("publisher"; "b-publisher"; "7" * 64; manifest_shas.publisher)]};
def profile_doc(manifest_shas): envelope("profile"; "profile-1"; profile_body(manifest_shas));

def resolved_binding_for(b; manifest_shas):
  {binding: b,
   adapter_implementation: {id: ("manifest-" + b.role), version: "v1"},
   manifest_source: {source: blobref("manifest.json"; "8" * 40), value_format: "canonical-json", value_sha256: manifest_shas[b.role]},
   package_source: {source: b.package_ref, value_format: "raw-bytes", value_sha256: ("9" * 64)},
   config_source: {state: "absent"}, prompt_source: {state: "absent"},
   skill_sources: [], tool_sources: []};

def resolved_profile_body(profile_sha; manifest_shas):
  {profile_ref: docref("profile"; "profile-1"; profile_sha),
   profile_source: {source: blobref("profile.json"; "b" * 40), value_format: "canonical-json", value_sha256: ("c" * 64)},
   selection_ref: scoperef("selection"; "sel-1"; "0" * 64),
   repository_context_ref: scoperef("repository-context"; "rc-1"; "1" * 64),
   bindings: (profile_body(manifest_shas).bindings | map(resolved_binding_for(.; manifest_shas)))};
def resolved_profile_doc(profile_sha; manifest_shas):
  envelope("resolved_profile"; "resolved-1"; resolved_profile_body(profile_sha; manifest_shas));

def named_input(id; sha): {input_id: id, value: {type: "artifact", value: {type: "content", value: contentref("in-" + id; sha)}}};
def delivered(purpose; input_id; sha): {ref: scoperef(purpose; "scope-" + input_id; sha), input_id: input_id};

def stage_request_body(resolved_sha):
  {initiative_id: "init-1", workflow_id: "wf-1", stage_id: "stage-1", task_class_id: "tc-1",
   requested_by: actorref("orchestrator"), target_repository_id: "repo-a",
   target_revision: {state: "absent"},
   source: {state: "present", value: {type: "content", value: contentref("src-1"; "d" * 64)}},
   base: {state: "absent"},
   inputs: [named_input("out-1"; "e" * 64), named_input("fin-1"; "e" * 64), named_input("ver-1"; "e" * 64)],
   prior_evidence_refs: [],
   risk: {tier: {namespace: "core", name: "routine"}, reason_ids: ["r1"],
          policy_ref: scoperef("policy"; "pol-1"; "4" * 64), required_gate_refs: []},
   resolved_profile_ref: docref("resolved_profile"; "resolved-1"; resolved_sha),
   selection_ref: scoperef("selection"; "sel-1"; "0" * 64),
   repository_context_ref: scoperef("repository-context"; "rc-1"; "1" * 64),
   gate_decision_refs: [],
   environment_ref: {environment_id: "env-1", fingerprint_sha256: ("3" * 64)},
   operation: {role: "producer", binding_id: "b-producer", capability_id: "core.harness.produce.v1",
     permissions: role_permissions("producer"),
     arguments: {artifact_kind: "plan", output_contract: delivered("output-contract"; "out-1"; "e" * 64)}},
   finish_condition: delivered("finish-condition"; "fin-1"; "e" * 64),
   verification_instruction: delivered("verification-instructions"; "ver-1"; "e" * 64),
   required_evidence_kinds: ["deterministic"],
   requested_at: "2026-08-28T00:00:00Z"};
def stage_request_doc(resolved_sha): envelope("stage_request"; "req-1"; stage_request_body(resolved_sha));

def output_for(id; sha): {output_id: id, ref: contentref("out-content-" + id; sha)};
def producer_execution:
  {performer: actorref("producer"),
   actual_binding: {binding_id: "b-producer", role: "producer",
     adapter_implementation: {id: "manifest-producer", version: "v1"},
     manifest_ref: docref("adapter_manifest"; "manifest-producer"; "2" * 64),
     package_ref: rootref("3" * 40), config_ref: {state: "absent"}, execution_kind: "deterministic",
     adapter_instance_id: "inst-b-producer", principal_id: "pri-b-producer", execution_boundary_id: "bnd-b-producer"},
   environment: {environment_id: "env-1", fingerprint_sha256: ("3" * 64)},
   used_capability: {kind: "registered", id: "core.harness.produce.v1"},
   metadata: {kind: "deterministic",
     provider: {state: "not-applicable"}, model: {state: "not-applicable"}, snapshot: {state: "not-applicable"},
     effort: {state: "not-applicable"}, prompt: {state: "not-applicable"}, skills: {state: "not-applicable"},
     tools: {state: "computed", value: [], source_ref: contentref("tools-fact"; "9" * 64)}}};

def stage_result_body(request_sha; resolved_sha):
  {request_ref: docref("stage_request"; "req-1"; request_sha),
   resolved_profile_ref: docref("resolved_profile"; "resolved-1"; resolved_sha),
   attempt_id: "attempt-1", attempt_number: 1, reported_by: actorref("orchestrator"),
   status: "completed", outcome: {family: "change", value: "changed"},
   outputs: [output_for("o1"; "7" * 64)],
   diagnostics: [], execution: producer_execution,
   evidence: [{evidence_id: "ev-1", kind: "deterministic", verdict: "passed", proof_ref: contentref("proof-1"; "8" * 64)}],
   started_at: "2026-08-28T00:00:01Z", finished_at: "2026-08-28T00:00:02Z", recorded_at: "2026-08-28T00:00:03Z"};
def stage_result_doc(request_sha; resolved_sha): envelope("stage_result"; "result-1"; stage_result_body(request_sha; resolved_sha));
