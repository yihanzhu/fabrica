import "portable-core-stage-request-fixtures" as request;
import "portable-core-result-truth-fixtures" as result;

def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
def sha256: type == "string" and test("\\A[0-9a-f]{64}\\z");
def v2: walk(if type == "object" and has("schema_version") then .schema_version = 2 else . end);
def payload_ok:
  exact(["data","media_type","payload_id","sha256"]) and
  (.data | type == "string") and (.media_type | type == "string") and
  (.payload_id | type == "string") and (.sha256 | sha256);
def positive_assertions:
  ["audit-projection","candidate-git","core-validation","environment-clean",
   "evidence-projection","gate-projection","outcome-projection",
   "risk-projection","target-git"];
def expected_cases($fixture):
  ["aa","ab","ba","bb"] | map(. as $cell | {
    case_id:("matrix-"+$cell),phase:"pipeline",
    producer_package_id:("fake.producer."+($cell[0:1])),
    forge_package_id:("fake.forge."+($cell[1:2])),expected_verdict:"pass",
    expected_error:"",equivalence_group:"portable-fake-v1",
    assertions:positive_assertions,fixture_sha256:$fixture
  }) + [
    {case_id:"reject-degraded",expected_error:"E_DEGRADED"},
    {case_id:"reject-empty",expected_error:"E_EMPTY"},
    {case_id:"reject-malformed",expected_error:"E_MALFORMED"},
    {case_id:"reject-partial",expected_error:"E_PARTIAL"},
    {case_id:"reject-relabelled",expected_error:"E_RELABELLED"},
    {case_id:"reject-timeout",expected_error:"E_TIMEOUT"},
    {case_id:"reject-transport",expected_error:"E_TRANSPORT"},
    {case_id:"reject-multiple",expected_error:"E_MULTIPLE"},
    {case_id:"reject-unlinked",expected_error:"E_UNLINKED_PAYLOAD"},
    {case_id:"reject-duplicate",expected_error:"E_DUPLICATE_PAYLOAD"},
    {case_id:"reject-descendant",expected_error:"E_DESCENDANT"}
  ] | map(if has("phase") then . else . + {
    phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",
    expected_verdict:"reject",equivalence_group:"protocol-negative",
    assertions:["expected-error"],fixture_sha256:$fixture
  } end);
def inventory_ok:
  (.inventory | exact(["authorization_ref","cases","protocol","schema_version"])) and
  .inventory.schema_version == 1 and
  .inventory.protocol == "ystack.adapter-contract.inventory.v1" and
  .inventory.authorization_ref ==
    {comment_id:5476938197,issue_number:153,scope_comment_id:5474023028} and
  .inventory.cases == expected_cases(.fixture_sha256);

def revision($c):
  {repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$c.target_commit};
def source_ref($c):
  {revision:revision($c),location:{kind:"path",value:"source.txt"},object_type:"blob",
   object_id:$c.target_object,mode:"100644"};
def tree_ref($c):
  {revision:revision($c),location:{kind:"root"},object_type:"tree",
   object_id:$c.target_tree,mode:"040000"};
def target_request($c):
  .body.target_repository_id="fixture.target" |
  .body.target_revision={state:"present",value:revision($c)} |
  .body.base={state:"present",value:revision($c)} |
  .body.source={state:"present",value:{type:"git-object",value:source_ref($c)}};
def producer_request($c):
  request::request_doc("producer";$c.resolved_sha) | v2 |
  .id=("request."+$c.case_id+".producer") |
  .body.stage_id=("stage."+$c.case_id+".producer") |
  .body.resolved_profile_ref.id=$c.resolved_id |
  .body.selection_ref=$c.resolved_profile.body.selection_ref |
  .body.repository_context_ref=$c.resolved_profile.body.repository_context_ref |
  target_request($c) |
  (.body.inputs[] | select(.input_id=="input.output") | .input_id)="input.allowed-delta" |
  .body.inputs |= sort_by(.input_id) |
  .body.operation.arguments={artifact_kind:"git-patch",
    allowed_delta:request::delivered("allowed-delta";"allowed-delta";request::sha("3"))} |
  .body.operation.arguments.allowed_delta.ref.subject_ref as $allowed |
  (.body.inputs[] | select(.input_id=="input.allowed-delta") | .value)=$allowed;
def forge_request($c):
  request::request_doc("producer";$c.resolved_sha) | v2 |
  .id=("request."+$c.case_id+".forge") |
  .body.stage_id=("stage."+$c.case_id+".forge") |
  .body.resolved_profile_ref.id=$c.resolved_id |
  .body.selection_ref=$c.resolved_profile.body.selection_ref |
  .body.repository_context_ref=$c.resolved_profile.body.repository_context_ref |
  target_request($c) |
  .body.inputs=([
    request::named_content_input("finish";request::sha("1")),
    request::named_content_input("materialize";request::sha("3")),
    request::named_content_input("producer-patch";$c.patch_sha),
    {input_id:"input.source-tree",value:{type:"artifact",value:{type:"git-object",value:tree_ref($c)}}},
    request::named_content_input("verify";request::sha("2"))
  ] | sort_by(.input_id)) |
  .body.operation={role:"forge",binding_id:"binding.forge",
    capability_id:"core.forge.materialize-candidate.v2",
    permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1","core.perm.target.read.v1"],
    arguments:{source_tree_input_id:"input.source-tree",candidate_output_id:"candidate.repository",
      materialization_contract:request::delivered("output-contract";"materialize";request::sha("3")),
      network_mode:"deny"}} |
  .body.required_evidence_kinds=["deterministic"];
def stage_result($c; $output_id; $media_type; $payload_sha):
  result::completed_result_doc($c.stage_request;$c.request_sha;
    $c.resolved_profile;$c.resolved_sha) | v2 |
  .id=("result."+$c.case_id+"."+$c.phase) |
  .body.outcome={family:"change",value:"changed"} |
  .body.outputs=[{output_id:$output_id,
    ref:{content_id:("output."+$c.case_id+"."+$c.phase),media_type:$media_type,sha256:$payload_sha}}] |
  if $c.phase == "producer" then .body.delta_ref=.body.outputs[0].ref else . end;
def request_envelope_ok:
  exact(["case_id","payloads","phase","protocol_version","stage_request"]) and
  .protocol_version == 1 and (.phase == "producer" or .phase == "forge") and
  .stage_request.schema_version == 2 and .stage_request.kind == "stage_request" and
  (.payloads | type == "array" and all(.[];payload_ok) and
    ([.[].payload_id] | length == (unique | length)));
def response_envelope_ok:
  (.response | exact(["case_id","payloads","phase","protocol_version","stage_result"])) and
  .response.protocol_version == 1 and .response.case_id == .case_id and
  .response.phase == .phase and .response.stage_result.schema_version == 2 and
  .response.stage_result.kind == "stage_result" and
  (.response.payloads | type == "array" and all(.[];payload_ok)) and
  ([.response.payloads[].payload_id] | length == (unique | length)) and
  ([.response.payloads[].payload_id] | sort) ==
    ([.response.stage_result.body.outputs[].output_id] | sort) and
  .response as $response |
  all($response.payloads[];
    . as $payload |
    [$response.stage_result.body.outputs[] |
     select(.output_id==$payload.payload_id and .ref.media_type==$payload.media_type and
            .ref.sha256==$payload.sha256)] | length == 1);
def response_error:
  if (.response | type) != "object" then "E_PARTIAL"
  elif .response.status? == "degraded" then "E_DEGRADED"
  elif (.response | exact(["case_id","payloads","phase","protocol_version","stage_result"]) | not)
  then "E_PARTIAL"
  elif .response.case_id != .case_id or .response.phase != .phase then "E_RELABELLED"
  elif (.response.payloads | type) != "array" then "E_PARTIAL"
  elif ([.response.payloads[].payload_id] as $ids |
        ($ids | length) != ($ids | unique | length))
  then "E_DUPLICATE_PAYLOAD"
  elif ([.response.payloads[].payload_id] | sort) !=
       ([.response.stage_result.body.outputs[]?.output_id] | sort)
  then "E_UNLINKED_PAYLOAD"
  elif (response_envelope_ok | not) then "E_PARTIAL"
  else "" end;
def projection:
  {artifact_sha256:.artifact_sha256,risk:.producer_request.body.risk,
   gate_refs:.producer_request.body.risk.required_gate_refs,
   outcome:[.producer_result.body.outcome,.forge_result.body.outcome],
   evidence:[.producer_result.body.evidence,.forge_result.body.evidence],
   audit:{producer_status:.producer_result.body.status,forge_status:.forge_result.body.status,
     producer_attempt:.producer_result.body.attempt_number,
     forge_attempt:.forge_result.body.attempt_number,
     target_tree_id:.target_tree,candidate_tree_id:.candidate_tree}};

if $command == "inventory" then inventory_ok
elif $command == "producer-request" then producer_request(.)
elif $command == "forge-request" then forge_request(.)
elif $command == "stage-result" then stage_result(.;.output_id;.media_type;.payload_sha)
elif $command == "request-envelope" then request_envelope_ok
elif $command == "response-envelope" then response_envelope_ok
elif $command == "response-error" then response_error
elif $command == "projection" then projection
else error("unknown-command") end
