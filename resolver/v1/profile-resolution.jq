def exact($required; $optional):
  . as $v |
  ($v | type) == "object" and
  (($v | keys_unsorted) - ($required + $optional) | length) == 0 and
  all($required[]; . as $k | $v | has($k));

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def oid_ok($algorithm):
  type == "string" and
  if $algorithm == "sha1" then test("\\A[0-9a-f]{40}\\z")
  elif $algorithm == "sha256" then test("\\A[0-9a-f]{64}\\z")
  else false
  end;

def repo_path_ok:
  type == "string" and
  utf8bytelength > 0 and utf8bytelength <= 8192 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));

def absolute_root_ok:
  type == "string" and
  utf8bytelength >= 1 and utf8bytelength <= 4096 and
  startswith("/") and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (split("/")[1:] | all(.[]; . != "" and . != "." and . != ".."));

def locator_ok:
  . as $locator |
  exact(["repository_id","hash_algorithm","commit_id","path","object_id"];[]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (.commit_id | oid_ok($locator.hash_algorithm)) and
  (.object_id | oid_ok($locator.hash_algorithm)) and
  (.path | repo_path_ok);

def locator_key:
  [.repository_id,.hash_algorithm,.commit_id,.path,.object_id];

def request_minimum_ok:
  type == "object" and has("manifest_sources") and
  (.manifest_sources | type) == "array";

def request_count_ok:
  request_minimum_ok and (.manifest_sources | length) >= 1 and
  (.manifest_sources | length) <= 8;

def request_ok:
  exact(["version","profile_source","manifest_sources","selection_ref",
         "repository_context_ref"];[]) and
  .version == 1 and
  (.profile_source | locator_ok) and
  (.manifest_sources | all(.[]; locator_ok)) and
  (([.profile_source] + .manifest_sources | map(locator_key) | length) ==
   ([.profile_source] + .manifest_sources | map(locator_key) | unique | length));

def map_ok:
  exact(["version","repositories"];[]) and
  .version == 1 and
  (.repositories | type) == "array" and
  (.repositories | length) >= 1 and (.repositories | length) <= 1024 and
  (.repositories | all(.[];
    exact(["repository_id","root"];[]) and
    (.repository_id | id_ok) and (.root | absolute_root_ok))) and
  (.repositories | map(.repository_id) | length) ==
    (.repositories | map(.repository_id) | unique | length);

def document_ref($pair):
  {schema_version:1,kind:$pair.content.kind,id:$pair.content.id,sha256:$pair.sha256};

def git_key:
  [.revision.repository_id,.revision.hash_algorithm,.revision.commit_id,
   .location.kind,(.location.value // ""),.object_type,.object_id,.mode];

def git_object_transport_ok:
  . as $ref |
  exact(["revision","location","object_type","object_id","mode"];[]) and
  (.revision |
    exact(["repository_id","hash_algorithm","commit_id"];[]) and
    (.repository_id | id_ok) and
    (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
    (.commit_id | oid_ok($ref.revision.hash_algorithm))) and
  ((.location | exact(["kind"];[]) and .kind == "root") or
   (.location | exact(["kind","value"];[]) and .kind == "path" and
                (.value | repo_path_ok))) and
  (.object_type == "blob" or .object_type == "tree") and
  (.object_id | oid_ok($ref.revision.hash_algorithm)) and
  (if .location.kind == "root" then .object_type == "tree" else true end) and
  (if .object_type == "tree" then .mode == "040000"
   else (.mode == "100644" or .mode == "100755") end);

def scope_git_object($scope):
  if (($scope | type) == "object" and
      $scope.subject_ref?.type == "artifact" and
      $scope.subject_ref.value?.type == "git-object" and
      ($scope.subject_ref.value.value | git_object_transport_ok))
  then [$scope.subject_ref.value.value]
  else []
  end;

def binding_git_objects($binding):
  [$binding.package_ref] +
  (if $binding | has("config_ref") then [$binding.config_ref] else [] end) +
  (if $binding | has("prompt_ref") then [$binding.prompt_ref] else [] end) +
  ($binding.skill_refs // []) +
  (($binding.requested_tools // []) |
    map([.package_ref] +
        (if .config_ref.state == "present" then [.config_ref.value] else [] end)) |
    add // []) +
  (if $binding | has("authority_ref") then scope_git_object($binding.authority_ref) else [] end);

def selected_objects($request; $profile):
  (scope_git_object($request.selection_ref) +
   scope_git_object($request.repository_context_ref) +
   ($profile.body.bindings | map(binding_git_objects(.)) | add // [])) |
  unique_by(git_key) | sort_by(git_key);

def manifest_index_ok($profile; $records):
  ($profile.body.bindings | map(.manifest_ref) | unique | sort_by([.kind,.id,.sha256])) as $expected |
  ($records | map(.pair | document_ref(.))) as $supplied |
  if ($supplied | group_by([.schema_version,.kind,.id,.sha256]) | any(.[]; length > 1))
  then {ok:false,reason:"manifest-source-ambiguous"}
  elif (($expected - ($supplied | unique)) | length) > 0
  then {ok:false,reason:"manifest-source-missing"}
  elif ((($supplied | unique) - $expected) | length) > 0
  then {ok:false,reason:"manifest-source-extra"}
  else {ok:true}
  end;

def value_for($values; $ref; $format):
  [$values[] | select(.ref == $ref)] as $matches |
  if ($matches | length) != 1 then error("value-lookup")
  else {source:$ref,value_format:$format,value_sha256:$matches[0].value_sha256}
  end;

def present_value_for($values; $owner; $name; $format):
  if $owner | has($name)
  then {state:"present",value:value_for($values;$owner[$name];$format)}
  else {state:"absent"}
  end;

def tool_sources($values; $binding):
  $binding.requested_tools |
  map({
    tool_id:.tool_id,
    package_source:value_for($values;.package_ref;"raw-bytes"),
    config_source:(if .config_ref.state == "present"
                   then {state:"present",value:value_for($values;.config_ref.value;"raw-bytes")}
                   else {state:"absent"} end)
  }) | sort_by(.tool_id);

def manifest_record_for($records; $ref):
  [$records[] | select(document_ref(.pair) == $ref)] |
  if length == 1 then .[0] else error("manifest-lookup") end;

def resolved_binding($records; $values; $binding):
  manifest_record_for($records;$binding.manifest_ref) as $manifest |
  {
    binding:$binding,
    adapter_implementation:{id:$manifest.pair.content.id,
                            version:$manifest.pair.content.body.adapter_version},
    manifest_source:value_for($values;$manifest.source;"canonical-json"),
    package_source:value_for($values;$binding.package_ref;"raw-bytes"),
    config_source:present_value_for($values;$binding;"config_ref";"raw-bytes"),
    prompt_source:present_value_for($values;$binding;"prompt_ref";"raw-bytes"),
    skill_sources:($binding.skill_refs | map(value_for($values;.;"raw-bytes")) |
                   sort_by(.source | git_key)),
    tool_sources:tool_sources($values;$binding)
  };

def assembled_body($state):
  {
    profile_ref:document_ref($state.profile_pair),
    profile_source:value_for($state.values;$state.profile_source;"canonical-json"),
    selection_ref:$state.request.selection_ref,
    repository_context_ref:$state.request.repository_context_ref,
    bindings:($state.profile_pair.content.body.bindings |
      map(resolved_binding($state.manifest_records;$state.values;.)) |
      sort_by(.binding.binding_id))
  };

def run($command; $input):
  if $command == "request-minimum" then $input | request_minimum_ok
  elif $command == "request-count" then $input | request_count_ok
  elif $command == "request" then $input | request_ok
  elif $command == "map" then $input | map_ok
  elif $command == "locator-ids" then
    [$input.profile_source.repository_id,
     $input.manifest_sources[].repository_id] | unique | sort
  elif $command == "selected-objects" then
    selected_objects($input.request;$input.profile)
  elif $command == "selected-ids" then
    selected_objects($input.request;$input.profile) |
    map(.revision.repository_id) | unique | sort
  elif $command == "manifest-index" then
    manifest_index_ok($input.profile;$input.records)
  elif $command == "assemble-body" then assembled_body($input)
  elif $command == "envelope" then
    {schema_version:1,kind:"resolved_profile",
     id:("resolved-profile:" + $input.body_sha256),body:$input.body}
  else error("unknown-command")
  end;

run($command;.)
