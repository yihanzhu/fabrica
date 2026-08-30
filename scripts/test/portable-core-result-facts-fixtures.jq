def metadata:
  {
    construction_base:"4ea04ee0ffb800668871b3b482557dd5a9041801",
    generation_id:"g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386",
    parent_spec_blob:"c6511d96c1a5e6aed27ba2075b5add65c121f782",
    schema_g3_comment:5466181650,
    schema_export_oid:"fd3924d414a7d620c2bf5de919a45c2599d572ec",
    ingress_g3_comment:5468279667,
    ingress_export_oid:"e882b38b0106aac9142c667771f02e3107f8c52f",
    profile_g3_comment:5468723218,
    profile_export_oid:"48fd185eee7751eedf0ce381b77621e4d7cd1611",
    stage_request_g3_comment:5469016860,
    stage_request_merge_commit:"4ea04ee0ffb800668871b3b482557dd5a9041801",
    stage_request_export_oid:"76c5d54437813a76502b46dc05215fb5b2c3f5bb",
    registry_oid:"5e113105777694a280166e71d31efd19752e9562",
    frozen_source_head:"ab4a7082f02e67b5748c5c54b9214f37d222f53f",
    frozen_test_blob:"8a9921d3763e3fcfa103037b021dd6c95bdcad61",
    mapping_sha256:"21f47f23762d96ca98b6ca8588cf3d1adeaa3922c3663d751b4b8d152d77b63a",
    review_rows:2,
    legacy_rows:14,
    owned_rules:23,
    direct_cases:73,
    command_to_rule_cells:2,
    forced_routes:2,
    guard_cases:15
  };

def sha($character): $character * 64;
def content($id):
  {content_id:$id,media_type:"application/json",sha256:sha("a")};
def absent: {state:"absent"};
def recorded($value; $id):
  {state:"recorded",value:$value,source_ref:content($id)};
def not_applicable: {state:"not-applicable"};

def selected_resolved_binding($resolved_body; $role):
  [$resolved_body.bindings[] | select(.binding.role == $role)][0];

def actual_binding($resolved_binding):
  $resolved_binding.binding as $binding |
  {
    binding_id:$binding.binding_id,
    role:$binding.role,
    adapter_implementation:$resolved_binding.adapter_implementation,
    manifest_ref:$binding.manifest_ref,
    package_ref:$binding.package_ref,
    config_ref:(if $binding | has("config_ref")
                then {state:"present",value:$binding.config_ref}
                else absent end),
    execution_kind:$binding.execution_kind,
    adapter_instance_id:$binding.adapter_instance_id,
    principal_id:$binding.principal_id,
    execution_boundary_id:$binding.execution_boundary_id
  } +
  (if $binding | has("authority_ref")
   then {authority_ref:$binding.authority_ref}
   else {} end);

def performer($resolved_binding):
  $resolved_binding.binding as $binding |
  {
    role:$binding.role,
    implementation_id:$resolved_binding.adapter_implementation.id,
    implementation_version:$resolved_binding.adapter_implementation.version,
    adapter_instance_id:$binding.adapter_instance_id,
    principal_id:$binding.principal_id,
    execution_boundary_id:$binding.execution_boundary_id
  } +
  (if $binding | has("authority_ref")
   then {authority_ref:$binding.authority_ref}
   else {} end);

def model_metadata($binding):
  {
    kind:"model",
    provider:recorded($binding.model_request.provider_id;"fact.provider"),
    model:recorded($binding.model_request.model_id;"fact.model"),
    snapshot:recorded("snapshot.example";"fact.snapshot"),
    effort:recorded($binding.model_request.effort_id;"fact.effort"),
    prompt:recorded($binding.prompt_ref;"fact.prompt"),
    skills:recorded($binding.skill_refs;"fact.skills"),
    tools:recorded($binding.requested_tools;"fact.tools")
  };

def deterministic_metadata($binding):
  {
    kind:"deterministic",
    provider:not_applicable,
    model:not_applicable,
    snapshot:not_applicable,
    effort:not_applicable,
    prompt:not_applicable,
    skills:not_applicable,
    tools:recorded($binding.requested_tools;"fact.tools")
  };

def execution($request_body; $resolved_body):
  selected_resolved_binding($resolved_body;$request_body.operation.role) as $resolved |
  $resolved.binding as $binding |
  {
    performer:performer($resolved),
    actual_binding:actual_binding($resolved),
    environment:$request_body.environment_ref,
    used_capability:{kind:"registered",id:$request_body.operation.capability_id},
    metadata:(if $binding.execution_kind == "model"
              then model_metadata($binding)
              else deterministic_metadata($binding) end)
  };

def evidence($role):
  {
    evidence_id:"evidence.example",
    kind:(if $role == "producer" then "deterministic"
          elif $role == "reviewer" then "independent-review"
          else "deterministic" end),
    verdict:"passed",
    proof_ref:content("proof.example")
  };

def outcome($role):
  if $role == "producer" then {family:"change",value:"no-change"}
  else {family:"check",value:"passed"}
  end;

def result_body($request; $request_sha; $resolved; $resolved_sha):
  $request.body.operation.role as $role |
  {
    request_ref:{schema_version:1,kind:"stage_request",id:$request.id,sha256:$request_sha},
    resolved_profile_ref:{schema_version:1,kind:"resolved_profile",id:$resolved.id,sha256:$resolved_sha},
    attempt_id:"attempt.example",
    attempt_number:1,
    reported_by:performer(selected_resolved_binding($resolved.body;$role)),
    status:"completed",
    outcome:outcome($role),
    outputs:[],
    diagnostics:[],
    execution:execution($request.body;$resolved.body),
    evidence:[evidence($role)],
    started_at:"2026-08-30T00:00:01Z",
    finished_at:"2026-08-30T00:00:02Z",
    recorded_at:"2026-08-30T00:00:03Z"
  };

def result_doc($request; $request_sha; $resolved; $resolved_sha):
  {
    schema_version:1,
    kind:"stage_result",
    id:("result." + $request.body.operation.role),
    body:result_body($request;$request_sha;$resolved;$resolved_sha)
  };
