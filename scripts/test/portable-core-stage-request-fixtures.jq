def metadata:
  {
    construction_base:"94afa6a925c203051133f3017589f1848ee580c8",
    generation_id:"g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386",
    parent_spec_blob:"c6511d96c1a5e6aed27ba2075b5add65c121f782",
    schema_g3_comment:5466181650,
    schema_export_oid:"fd3924d414a7d620c2bf5de919a45c2599d572ec",
    ingress_g3_comment:5468279667,
    ingress_export_oid:"e882b38b0106aac9142c667771f02e3107f8c52f",
    profile_g3_comment:5468723218,
    profile_merge_commit:"fbe3850b94bfa153a169d5bb67348c1b312e3be6",
    profile_export_oid:"48fd185eee7751eedf0ce381b77621e4d7cd1611",
    registry_oid:"5e113105777694a280166e71d31efd19752e9562",
    review_r0_source_sha256:"6361652d62ab94471139e767bc6240385959aafc8f1e7ebf1f0748e9037c1079",
    review_r3_source_sha256:"5398fb81ddacdc13879ccb6ffcbfa2c280068caa45cca69c6fb2104acab46c53",
    legacy_source_sha256:"ee195ecc61f07a4cdf81bbec12fd8d80a6895520a6103cc64faa4e1a0cb77488",
    mapping_sha256:"6dca82d4c3558e7576a2684b4c87a3fac3975a6da36b6693d9ea0a5d0b5bcbd2",
    review_rows:6,
    legacy_rows:22,
    owned_rules:36,
    direct_cases:153,
    command_to_rule_cells:3,
    forced_routes:3,
    error_layer_cases:4,
    guard_cases:17
  };

def sha($character): $character * 64;
def oid($character): $character * 40;
def absent: {state:"absent"};
def present($value): {state:"present",value:$value};

def revision($character):
  {
    repository_id:"repo.example",
    hash_algorithm:"sha1",
    commit_id:oid($character)
  };

def tree($character):
  {
    revision:revision($character),
    location:{kind:"root"},
    object_type:"tree",
    object_id:oid($character),
    mode:"040000"
  };

def blob($path; $character):
  {
    revision:revision("1"),
    location:{kind:"path",value:$path},
    object_type:"blob",
    object_id:oid($character),
    mode:"100644"
  };

def content($id; $media_type; $digest):
  {content_id:$id,media_type:$media_type,sha256:$digest};

def document_ref($kind; $id; $digest):
  {schema_version:1,kind:$kind,id:$id,sha256:$digest};

def actor($role):
  {
    role:$role,
    implementation_id:("implementation." + $role),
    implementation_version:"v1",
    adapter_instance_id:("instance." + $role),
    principal_id:("principal." + $role),
    execution_boundary_id:("boundary." + $role)
  };

def scope($purpose; $id; $digest):
  {
    purpose:$purpose,
    decision_record_ref:content("decision-" + $id;"application/json";$digest),
    subject_ref:{
      type:"artifact",
      value:{type:"content",value:content("payload-" + $id;"application/json";$digest)}
    },
    scope_sha256:$digest
  };

def named_content_input($id; $digest):
  {
    input_id:("input." + $id),
    value:{
      type:"artifact",
      value:{type:"content",value:content("payload-" + $id;"application/json";$digest)}
    }
  };

def named_tree_input($id):
  {
    input_id:("input." + $id),
    value:{type:"artifact",value:{type:"git-object",value:tree("1")}}
  };

def delivered($purpose; $id; $digest):
  {ref:scope($purpose;$id;$digest),input_id:("input." + $id)};

def selection_scope:
  {
    purpose:"selection",
    decision_record_ref:
      content("decision-selection.example";"application/json";sha("a")),
    subject_ref:{
      type:"artifact",
      value:{
        type:"content",
        value:content("selection.example";"application/json";sha("a"))
      }
    },
    scope_sha256:sha("a")
  };

def repository_context_scope:
  {
    purpose:"repository-context",
    decision_record_ref:
      content("decision-repository.example";"application/json";sha("b")),
    subject_ref:{
      type:"artifact",
      value:{
        type:"content",
        value:content("repository.example";"application/json";sha("b"))
      }
    },
    scope_sha256:sha("b")
  };

def permissions($role):
  if $role == "producer" then
    ["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
     "core.perm.scratch.write.v1","core.perm.target.read.v1"]
  elif $role == "reviewer" then
    ["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
     "core.perm.target.read.v1"]
  else
    ["core.perm.candidate.execute.v1","core.perm.evidence.write.v1",
     "core.perm.target.read.v1"]
  end;

def capability($role):
  if $role == "producer" then "core.harness.produce.v1"
  elif $role == "reviewer" then "core.review.change.v1"
  else "core.verify.run.v1"
  end;

def role_inputs($role):
  ([
    named_content_input("finish";sha("1")),
    named_content_input("verify";sha("2"))
  ] +
  (if $role == "producer" then
     [named_content_input("output";sha("3"))]
   elif $role == "verifier" then
     [named_tree_input("candidate"),named_content_input("plan";sha("4"))]
   else
     [named_content_input("policy";sha("5"))]
   end)) | sort_by(.input_id);

def capability_arguments($role):
  if $role == "producer" then
    {
      artifact_kind:"structured-artifact",
      output_contract:delivered("output-contract";"output";sha("3"))
    }
  elif $role == "verifier" then
    {
      candidate_input_id:"input.candidate",
      verification_plan:delivered("verification-plan";"plan";sha("4")),
      network_mode:"deny"
    }
  else
    {
      change_ref:{
        repository_id:"repo.example",
        base:present(revision("2")),
        head:revision("1"),
        delta_ref:content("delta.review";"text/x-diff";sha("6"))
      },
      review_policy:delivered("review-policy";"policy";sha("5"))
    }
  end;

def required_evidence($role):
  if $role == "producer" then ["deterministic"]
  elif $role == "reviewer" then ["independent-review"]
  else ["architecture","behavioral","deterministic"]
  end;

def request_body($role; $resolved_sha):
  {
    initiative_id:"initiative.example",
    workflow_id:"workflow.example",
    stage_id:("stage." + $role),
    task_class_id:"task.example",
    requested_by:actor("orchestrator"),
    target_repository_id:"repo.example",
    target_revision:present(revision("1")),
    source:present({type:"git-object",value:blob("source.txt";"7")}),
    base:present(revision("2")),
    inputs:role_inputs($role),
    prior_evidence_refs:[],
    risk:{
      tier:{namespace:"core",name:"routine"},
      reason_ids:["risk.example"],
      policy_ref:scope("policy";"policy.example";sha("8")),
      required_gate_refs:[]
    },
    resolved_profile_ref:
      document_ref("resolved_profile";"resolved.example";$resolved_sha),
    selection_ref:selection_scope,
    repository_context_ref:repository_context_scope,
    gate_decision_refs:[],
    environment_ref:{environment_id:"environment.example",fingerprint_sha256:sha("9")},
    operation:{
      role:$role,
      binding_id:("binding." + $role),
      capability_id:capability($role),
      permissions:permissions($role),
      arguments:capability_arguments($role)
    },
    finish_condition:delivered("finish-condition";"finish";sha("1")),
    verification_instruction:
      delivered("verification-instructions";"verify";sha("2")),
    required_evidence_kinds:required_evidence($role),
    requested_at:"2026-08-30T00:00:00Z"
  };

def request_doc($role; $resolved_sha):
  {
    schema_version:1,
    kind:"stage_request",
    id:("request." + $role),
    body:request_body($role;$resolved_sha)
  };

def bootstrap_request_doc($resolved_sha):
  request_doc("producer";$resolved_sha) |
  .body.target_revision=absent |
  .body.base=absent |
  .body.risk.tier={namespace:"core",name:"bootstrap"};
