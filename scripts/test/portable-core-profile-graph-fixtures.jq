def metadata:
  {
    construction_base:"6ae9452848fd1bdec38aaef78efc842f5e938de3",
    generation_id:"g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386",
    parent_spec_blob:"c6511d96c1a5e6aed27ba2075b5add65c121f782",
    schema_g3_comment:5466181650,
    schema_merge_commit:"d48ecdb908a395c5205260a662db7d9d3f4c1eb4",
    schema_export_oid:"fd3924d414a7d620c2bf5de919a45c2599d572ec",
    ingress_g3_comment:5468279667,
    ingress_export_oid:"e882b38b0106aac9142c667771f02e3107f8c52f",
    registry_oid:"5e113105777694a280166e71d31efd19752e9562",
    review_source_sha256:"31793a3ad42acf4df117ea158a78738e056bae550269483870487c3e146b27f9",
    legacy_source_sha256:"3d5a6fb192f9bcaba5c4b89314d30f88a03b9d8a1e1e634297c267b14f096092",
    profile_mapping_sha256:"7a1deb7cc114bb78f118eb74d9587cee0f7a9822025747cb87aaed0a11b562c4",
    review_rows:7,
    legacy_rows:92,
    owned_rules:45,
    direct_cases:135,
    command_to_rule_cells:8,
    forced_routes:8,
    error_layer_cases:5,
    guard_cases:15
  };

def sha($character): $character * 64;
def oid($character): $character * 40;

def revision:
  {
    repository_id:"repo.example",
    hash_algorithm:"sha1",
    commit_id:(oid("1"))
  };

def blob($path; $character):
  {
    revision:revision,
    location:{kind:"path",value:$path},
    object_type:"blob",
    object_id:(oid($character)),
    mode:"100644"
  };

def content($id; $digest):
  {content_id:$id,media_type:"application/json",sha256:$digest};

def scope($purpose; $id; $digest):
  {
    purpose:$purpose,
    decision_record_ref:content("decision-" + $id;$digest),
    subject_ref:{type:"artifact",value:{type:"content",value:content($id;$digest)}},
    scope_sha256:$digest
  };

def document_ref($kind; $id; $digest):
  {schema_version:1,kind:$kind,id:$id,sha256:$digest};

def envelope($kind; $id; $body):
  {schema_version:1,kind:$kind,id:$id,body:$body};

def absent: {state:"absent"};
def present($value): {state:"present",value:$value};

def package_ref($role):
  if $role == "producer" then blob("packages/producer.bin";"2")
  elif $role == "publisher" then blob("packages/publisher.bin";"3")
  elif $role == "reviewer" then blob("packages/reviewer.bin";"4")
  else blob("packages/verifier.bin";"5")
  end;

def manifest_source_ref($role):
  if $role == "producer" then blob("manifests/producer.json";"6")
  elif $role == "publisher" then blob("manifests/publisher.json";"7")
  elif $role == "reviewer" then blob("manifests/reviewer.json";"8")
  else blob("manifests/verifier.json";"9")
  end;

def capability($role):
  if $role == "producer" then "core.harness.produce.v1"
  elif $role == "reviewer" then "core.review.change.v1"
  elif $role == "verifier" then "core.verify.run.v1"
  else null
  end;

def permissions($role; $execution):
  if $role == "producer" and $execution == "model" then
    ["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
     "core.perm.scratch.write.v1","core.perm.target.read.v1"]
  elif $role == "reviewer" and $execution == "model" then
    ["core.perm.evidence.write.v1","core.perm.model.invoke.v1",
     "core.perm.target.read.v1"]
  elif $role == "verifier" then
    ["core.perm.candidate.execute.v1","core.perm.evidence.write.v1",
     "core.perm.target.read.v1"]
  else []
  end;

def producer_tool:
  {
    tool_id:"tool.producer",
    tool_version:"v1",
    package_ref:blob("tools/producer.bin";"a"),
    config_ref:present(blob("tools/producer.json";"b"))
  };

def manifest_body($role):
  (if $role == "producer" or $role == "reviewer" then "model" else "deterministic" end) as $execution |
  {
    adapter_version:"v1",
    package_ref:package_ref($role),
    offered_roles:[$role],
    offered_execution_kinds:[$execution],
    offered_capabilities:(if capability($role) == null then [] else [capability($role)] end),
    offered_permissions:permissions($role;$execution),
    offered_tools:(if $role == "producer" then [producer_tool] else [] end)
  } +
  (if $role == "producer" then
     {config_contract_ref:scope("config-contract";"producer-config";sha("c"))}
   else {} end);

def manifest($role):
  envelope("adapter_manifest";"manifest." + $role;manifest_body($role));

def manifest_docs:
  [manifest("producer"),manifest("publisher"),manifest("reviewer"),manifest("verifier")];

def binding($role; $manifest_shas):
  (if $role == "producer" or $role == "reviewer" then "model" else "deterministic" end) as $execution |
  {
    binding_id:("binding." + $role),
    role:$role,
    manifest_ref:document_ref("adapter_manifest";"manifest." + $role;$manifest_shas[$role]),
    execution_kind:$execution,
    adapter_instance_id:("instance." + $role),
    principal_id:("principal." + $role),
    execution_boundary_id:("boundary." + $role),
    authority_ref:scope("authority";"authority-" + $role;
      if $role == "producer" then sha("1")
      elif $role == "publisher" then sha("2")
      elif $role == "reviewer" then sha("3")
      else sha("4") end),
    package_ref:package_ref($role),
    skill_refs:(if $role == "producer" then [blob("skills/producer.md";"c")] else [] end),
    requested_tools:(if $role == "producer" then [producer_tool] else [] end),
    requested_capabilities:(if capability($role) == null then [] else [capability($role)] end),
    requested_permissions:permissions($role;$execution)
  } +
  (if $role == "producer" then
     {
       config_ref:blob("config/producer.json";"d"),
       prompt_ref:blob("prompts/producer.md";"e"),
       model_request:{provider_id:"provider.example",model_id:"model.example",effort_id:"high"}
     }
   elif $role == "reviewer" then
     {
       prompt_ref:blob("prompts/reviewer.md";"f"),
       model_request:{provider_id:"provider.example",model_id:"review.example",effort_id:"high"}
     }
   else {} end);

def profile_doc($manifest_shas):
  envelope("profile";"profile.example";
    {
      profile_version:"v1",
      bindings:(["producer","publisher","reviewer","verifier"] |
        map(binding(.;$manifest_shas)))
    });

def source_value($source; $format; $digest):
  {source:$source,value_format:$format,value_sha256:$digest};

def resolved_tool_source:
  {
    tool_id:"tool.producer",
    package_source:source_value(producer_tool.package_ref;"raw-bytes";sha("a")),
    config_source:present(source_value(producer_tool.config_ref.value;"raw-bytes";sha("b")))
  };

def resolved_binding($binding; $manifest_shas):
  $binding.role as $role |
  {
    binding:$binding,
    adapter_implementation:{id:("manifest." + $role),version:"v1"},
    manifest_source:source_value(manifest_source_ref($role);"canonical-json";$manifest_shas[$role]),
    package_source:source_value($binding.package_ref;"raw-bytes";
      if $role == "producer" then sha("5")
      elif $role == "publisher" then sha("6")
      elif $role == "reviewer" then sha("7")
      else sha("8") end),
    config_source:(if $role == "producer" then
      present(source_value($binding.config_ref;"raw-bytes";sha("9"))) else absent end),
    prompt_source:(if $binding | has("prompt_ref") then
      present(source_value($binding.prompt_ref;"raw-bytes";
        if $role == "producer" then sha("d") else sha("e") end)) else absent end),
    skill_sources:(if $role == "producer" then
      [source_value($binding.skill_refs[0];"raw-bytes";sha("f"))] else [] end),
    tool_sources:(if $role == "producer" then [resolved_tool_source] else [] end)
  };

def resolved_profile_doc($profile; $profile_sha; $manifest_shas):
  envelope("resolved_profile";"resolved.example";
    {
      profile_ref:document_ref("profile";$profile.id;$profile_sha),
      profile_source:source_value(blob("profiles/profile.json";"0");"canonical-json";$profile_sha),
      selection_ref:scope("selection";"selection.example";sha("a")),
      repository_context_ref:scope("repository-context";"repository.example";sha("b")),
      bindings:($profile.body.bindings | map(resolved_binding(.;$manifest_shas)))
    });
