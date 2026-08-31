import "schema" as schema;

def optional_ok($name; value_ok):
  (has($name) | not) or (.[$name] | value_ok);

def model_request_ok:
  schema::exact_fields(["provider_id","model_id","effort_id"];[]) and
  (.provider_id | schema::id_ok) and
  (.model_id | schema::id_ok) and
  (.effort_id | schema::id_ok);

def adapter_manifest_body_ok:
  schema::exact_fields(
    ["adapter_version","package_ref","offered_roles","offered_execution_kinds",
     "offered_capabilities","offered_permissions","offered_tools"];
    ["config_contract_ref"]) and
  (.adapter_version | schema::version_ok) and
  (.package_ref | schema::git_object_ref_ok) and
  (.offered_roles | schema::enum_set_ok(1;8;schema::adapter_roles)) and
  (.offered_execution_kinds | schema::enum_set_ok(1;2;schema::execution_kinds)) and
  (.offered_capabilities | schema::enum_set_ok(0;3;schema::capability_ids)) and
  (.offered_permissions | schema::enum_set_ok(0;5;schema::permission_ids)) and
  (.offered_tools | schema::bounded_set(0;32;schema::tool_ref_ok;.tool_id)) and
  optional_ok("config_contract_ref";schema::scope_ref_purpose_ok("config-contract"));

def adapter_manifest_shape_ok:
  schema::envelope_ok("adapter_manifest") and
  (.body | adapter_manifest_body_ok);

def adapter_manifest_self_ok: adapter_manifest_shape_ok;

def binding_capability_ok:
  . as $binding |
  (schema::capabilities_for_role($binding.role)) as $capabilities |
  if ($capabilities | length) == 1 then
    $binding.requested_capabilities == $capabilities and
    $binding.requested_permissions ==
      schema::permissions_for_capability($capabilities[0];$binding.execution_kind)
  else
    $binding.requested_capabilities == [] and
    $binding.requested_permissions == []
  end;

def profile_binding_shape_ok:
  schema::exact_fields(
    ["binding_id","role","manifest_ref","execution_kind","adapter_instance_id",
     "principal_id","execution_boundary_id","package_ref","skill_refs",
     "requested_tools","requested_capabilities","requested_permissions"];
    ["authority_ref","config_ref","prompt_ref","model_request"]) and
  (.binding_id | schema::id_ok) and
  (.role | schema::adapter_role_ok) and
  (.manifest_ref | schema::document_ref_kind_ok("adapter_manifest")) and
  (.execution_kind | schema::execution_kind_ok) and
  (.execution_kind as $kind |
   .role as $role |
   schema::execution_kinds_for_role($role) | index($kind) != null) and
  (.adapter_instance_id | schema::id_ok) and
  (.principal_id | schema::id_ok) and
  (.execution_boundary_id | schema::id_ok) and
  optional_ok("authority_ref";schema::scope_ref_purpose_ok("authority")) and
  (.package_ref | schema::git_object_ref_ok) and
  optional_ok("config_ref";schema::git_object_ref_ok) and
  optional_ok("prompt_ref";schema::git_object_ref_ok) and
  (.skill_refs | schema::bounded_set(0;32;schema::git_object_ref_ok;schema::git_key)) and
  (.requested_tools | schema::bounded_set(0;32;schema::tool_ref_ok;.tool_id)) and
  optional_ok("model_request";model_request_ok) and
  (.requested_capabilities |
   schema::enum_set_ok(0;1;schema::capability_ids)) and
  (.requested_permissions |
   schema::enum_set_ok(0;5;schema::permission_ids)) and
  (if .execution_kind == "model" then
     has("model_request") and has("prompt_ref")
   else
     (has("model_request") | not) and
     (has("prompt_ref") | not) and
     .skill_refs == []
   end);

def profile_binding_ok:
  profile_binding_shape_ok and binding_capability_ok;

def profile_body_shape_ok:
  schema::exact_fields(["profile_version","bindings"];[]) and
  (.profile_version | schema::version_ok) and
  (.bindings |
   schema::bounded_set(4;8;profile_binding_ok;.binding_id));

def profile_body_ok: profile_body_shape_ok;

def protected_role_separation_ok($bindings):
  [$bindings[] |
   select(.role as $role | schema::protected_roles | index($role) != null)] as $protected |
  [$bindings[] |
   select(.role as $role | schema::protected_roles | index($role) == null)] as $other |
  all(schema::protected_roles[]; . as $role |
      [$protected[] | select(.role == $role)] | length == 1) and
  all($protected[]; has("authority_ref")) and
  (($protected | map(.binding_id) | unique | length) == ($protected | length)) and
  (($protected | map(.adapter_instance_id) | unique | length) == ($protected | length)) and
  (($protected | map(.principal_id) | unique | length) == ($protected | length)) and
  (($protected | map(.execution_boundary_id) | unique | length) == ($protected | length)) and
  (($protected | map(.authority_ref.scope_sha256) | unique | length) ==
   ($protected | length)) and
  (($other | map(.role) | unique | length) == ($other | length));

def profile_shape_ok:
  schema::envelope_ok("profile") and
  (.body | profile_body_shape_ok);

def profile_relations_ok:
  .body.bindings as $bindings |
  protected_role_separation_ok($bindings);

def profile_self_ok:
  profile_shape_ok and profile_relations_ok;

def tool_source_ok:
  schema::exact_fields(["tool_id","package_source","config_source"];[]) and
  (.tool_id | schema::id_ok) and
  (.package_source | schema::source_value_ref_ok) and
  (.config_source | schema::present_ok(schema::source_value_ref_ok));

def resolved_binding_ok:
  schema::exact_fields(
    ["binding","adapter_implementation","manifest_source","package_source",
     "config_source","prompt_source","skill_sources","tool_sources"];
    []) and
  (.binding | profile_binding_shape_ok) and
  (.adapter_implementation |
   schema::exact_fields(["id","version"];[]) and
   (.id | schema::id_ok) and
   (.version | schema::version_ok)) and
  (.manifest_source |
   schema::source_value_ref_ok and .value_format == "canonical-json") and
  (.package_source | schema::source_value_ref_ok) and
  (.config_source | schema::present_ok(schema::source_value_ref_ok)) and
  (.prompt_source | schema::present_ok(schema::source_value_ref_ok)) and
  (.skill_sources |
   schema::bounded_set(0;32;schema::source_value_ref_ok;schema::source_git_key)) and
  (.tool_sources | schema::bounded_set(0;32;tool_source_ok;.tool_id));

def resolved_profile_body_shape_ok:
  schema::exact_fields(
    ["profile_ref","profile_source","selection_ref","repository_context_ref",
     "bindings"];
    []) and
  (.profile_ref | schema::document_ref_kind_ok("profile")) and
  (.profile_source |
   schema::source_value_ref_ok and .value_format == "canonical-json") and
  (.selection_ref | schema::scope_ref_purpose_ok("selection")) and
  (.repository_context_ref |
   schema::scope_ref_purpose_ok("repository-context")) and
  (.bindings |
   schema::bounded_set(4;8;resolved_binding_ok;.binding.binding_id));

def resolved_profile_body_ok: resolved_profile_body_shape_ok;

def resolved_profile_shape_ok:
  schema::envelope_ok("resolved_profile") and
  (.body | resolved_profile_body_shape_ok);

def present_source_values($present):
  if $present.state == "present" then [$present.value] else [] end;

def resolved_binding_source_claims($resolved_binding):
  [$resolved_binding.manifest_source,$resolved_binding.package_source] +
  present_source_values($resolved_binding.config_source) +
  present_source_values($resolved_binding.prompt_source) +
  $resolved_binding.skill_sources +
  ($resolved_binding.tool_sources |
   map([.package_source] + present_source_values(.config_source)) |
   add // []);

def resolved_profile_source_claims($body):
  [$body.profile_source] +
  ($body.bindings | map(resolved_binding_source_claims(.)) | add // []);

def source_claims_agree($body):
  resolved_profile_source_claims($body) |
  group_by(schema::source_git_key) |
  all(.[];
      (map(.value_format) | unique | length) == 1 and
      (map(.value_sha256) | unique | length) == 1);

def present_source_matches_optional_ref($source; $binding; $name):
  ($source.state == "present") == ($binding | has($name)) and
  (if $binding | has($name) then
     $source.value.source == $binding[$name]
   else true end);

def tool_sources_match($binding; $resolved_binding):
  ($resolved_binding.tool_sources | map(.tool_id)) ==
    ($binding.requested_tools | map(.tool_id)) and
  all($resolved_binding.tool_sources[];
      . as $source |
      [$binding.requested_tools[] |
       select(.tool_id == $source.tool_id)] as $requested |
      ($requested | length) == 1 and
      $source.package_source.source == $requested[0].package_ref and
      ($source.config_source.state == "present") ==
        ($requested[0].config_ref.state == "present") and
      (if $source.config_source.state == "present" then
         $source.config_source.value.source == $requested[0].config_ref.value
       else true end));

def resolved_binding_projection_ok:
  . as $resolved |
  $resolved.binding as $binding |
  $resolved.adapter_implementation.id == $binding.manifest_ref.id and
  $resolved.manifest_source.value_sha256 == $binding.manifest_ref.sha256 and
  $resolved.package_source.source == $binding.package_ref and
  present_source_matches_optional_ref($resolved.config_source;$binding;"config_ref") and
  present_source_matches_optional_ref($resolved.prompt_source;$binding;"prompt_ref") and
  ($resolved.skill_sources | map(schema::source_git_key)) ==
    ($binding.skill_refs | map(schema::git_key)) and
  tool_sources_match($binding;$resolved);

def resolved_profile_relations_ok:
  .body as $body |
  ($body.bindings | map(.binding)) as $bindings |
  $body.profile_source.value_sha256 == $body.profile_ref.sha256 and
  protected_role_separation_ok($bindings) and
  all($bindings[]; binding_capability_ok) and
  all($body.bindings[]; resolved_binding_projection_ok) and
  source_claims_agree($body);

def resolved_profile_self_ok:
  resolved_profile_shape_ok and resolved_profile_relations_ok;

def document_pair_ok($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content | schema::envelope_ok($kind)) and
  (.sha256 | schema::sha256_ok);

def document_ref_for_pair($pair):
  {
    schema_version:2,
    kind:$pair.content.kind,
    id:$pair.content.id,
    sha256:$pair.sha256
  };

def profile_set_refs_ok($profile; $resolved; $manifests):
  ($profile | document_pair_ok("profile")) and
  ($resolved | document_pair_ok("resolved_profile")) and
  ($manifests | type == "array") and
  ($manifests | length) >= 1 and
  ($manifests | length) <= 8 and
  all($manifests[]; document_pair_ok("adapter_manifest")) and
  (($manifests | map(.content.id) | unique | length) == ($manifests | length)) and
  $resolved.content.body.profile_ref == document_ref_for_pair($profile);

def manifest_for_ref($manifests; $ref):
  [$manifests[] | select(document_ref_for_pair(.) == $ref)];

def offered_tool_ok($manifest; $tool):
  $manifest.content.body.offered_tools | any(.[]; . == $tool);

def binding_manifest_graph_ok($binding; $resolved_binding; $manifest):
  ($resolved_binding.binding == $binding) and
  ($manifest.content.body.offered_roles | index($binding.role) != null) and
  ($manifest.content.body.offered_execution_kinds |
   index($binding.execution_kind) != null) and
  all($binding.requested_capabilities[]; . as $capability |
      $manifest.content.body.offered_capabilities | index($capability) != null) and
  all($binding.requested_permissions[]; . as $permission |
      $manifest.content.body.offered_permissions | index($permission) != null) and
  all($binding.requested_tools[]; . as $tool |
      offered_tool_ok($manifest;$tool)) and
  ($binding.package_ref == $manifest.content.body.package_ref) and
  (if $binding | has("config_ref") then
     $manifest.content.body | has("config_contract_ref")
   else true end) and
  ($resolved_binding.adapter_implementation.id == $manifest.content.id) and
  ($resolved_binding.adapter_implementation.version ==
   $manifest.content.body.adapter_version) and
  ($resolved_binding.manifest_source.value_sha256 == $manifest.sha256);

def profile_set_graph_ok($profile; $resolved; $manifests):
  $profile.content.body.bindings as $bindings |
  $resolved.content.body.bindings as $resolved_bindings |
  ($bindings | map(.binding_id)) ==
    ($resolved_bindings | map(.binding.binding_id)) and
  ($resolved.content.body.profile_source.value_sha256 == $profile.sha256) and
  ([ $bindings[].manifest_ref ] | unique) ==
    ([$manifests[] | document_ref_for_pair(.)] | unique) and
  all($bindings[];
      . as $binding |
      manifest_for_ref($manifests;$binding.manifest_ref) as $matches |
      [$resolved_bindings[] |
       select(.binding.binding_id == $binding.binding_id)] as $resolved_matches |
      ($matches | length) == 1 and
      ($resolved_matches | length) == 1 and
      binding_manifest_graph_ok($binding;$resolved_matches[0];$matches[0]));

def profile_set_ok($profile; $resolved; $manifests):
  profile_set_refs_ok($profile;$resolved;$manifests) and
  ($profile.content | profile_self_ok) and
  ($resolved.content | resolved_profile_self_ok) and
  all($manifests[].content; adapter_manifest_self_ok) and
  profile_set_graph_ok($profile;$resolved;$manifests);

def document_shape_ok:
  if .kind == "adapter_manifest" then adapter_manifest_shape_ok
  elif .kind == "profile" then profile_shape_ok
  elif .kind == "resolved_profile" then resolved_profile_shape_ok
  else false
  end;

def document_self_ok:
  if .kind == "adapter_manifest" then adapter_manifest_self_ok
  elif .kind == "profile" then profile_self_ok
  elif .kind == "resolved_profile" then resolved_profile_self_ok
  else false
  end;
