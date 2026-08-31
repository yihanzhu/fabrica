def exact($keys): type == "object" and (keys | sort) == ($keys | sort);
def sha256: type == "string" and test("\\A[0-9a-f]{64}\\z");

def positive_assertions:
  ["audit-projection","candidate-git","core-validation","environment-clean",
   "evidence-projection","gate-projection","outcome-projection",
   "risk-projection","target-git"];

def expected_cases($fixture): [
  {case_id:"matrix-aa",phase:"pipeline",producer_package_id:"fake.producer.a",forge_package_id:"fake.forge.a",expected_verdict:"pass",expected_error:"",equivalence_group:"portable-fake-v1",assertions:positive_assertions,fixture_sha256:$fixture},
  {case_id:"matrix-ab",phase:"pipeline",producer_package_id:"fake.producer.a",forge_package_id:"fake.forge.b",expected_verdict:"pass",expected_error:"",equivalence_group:"portable-fake-v1",assertions:positive_assertions,fixture_sha256:$fixture},
  {case_id:"matrix-ba",phase:"pipeline",producer_package_id:"fake.producer.b",forge_package_id:"fake.forge.a",expected_verdict:"pass",expected_error:"",equivalence_group:"portable-fake-v1",assertions:positive_assertions,fixture_sha256:$fixture},
  {case_id:"matrix-bb",phase:"pipeline",producer_package_id:"fake.producer.b",forge_package_id:"fake.forge.b",expected_verdict:"pass",expected_error:"",equivalence_group:"portable-fake-v1",assertions:positive_assertions,fixture_sha256:$fixture},
  {case_id:"reject-degraded",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_DEGRADED",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-empty",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_EMPTY",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-malformed",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_MALFORMED",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-partial",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_PARTIAL",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-relabelled",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_RELABELLED",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-timeout",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_TIMEOUT",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture},
  {case_id:"reject-transport",phase:"producer",producer_package_id:"fake.protocol-fault",forge_package_id:"none",expected_verdict:"reject",expected_error:"E_TRANSPORT",equivalence_group:"protocol-negative",assertions:["expected-error"],fixture_sha256:$fixture}
];

def inventory_ok($fixture):
  exact(["authorization_ref","cases","protocol","schema_version"]) and
  .schema_version == 1 and .protocol == "ystack.adapter-contract.inventory.v1" and
  .authorization_ref == {comment_id:5476938197,issue_number:153,scope_comment_id:5474023028} and
  .cases == expected_cases($fixture);

def producer_response_ok($package):
  exact(["artifact","package_id","phase","protocol","status"]) and
  .protocol == "ystack.fake-adapter.v1" and .phase == "producer" and
  .status == "ok" and .package_id == $package and
  (.artifact | exact(["content","sha256"]) and (.content | type == "string") and (.sha256 | sha256));

def forge_response_ok($package):
  exact(["commit_id","file_object_id","package_id","phase","protocol","status","tree_id"]) and
  .protocol == "ystack.fake-adapter.v1" and .phase == "forge" and
  .status == "ok" and .package_id == $package and
  (.commit_id | test("\\A[0-9a-f]{40}\\z")) and
  (.tree_id | test("\\A[0-9a-f]{40}\\z")) and
  (.file_object_id | test("\\A[0-9a-f]{40}\\z"));

def projection($artifact; $target_tree; $candidate_tree):
  {artifact_sha256:$artifact,risk:"core:routine",gate_refs:[],
   outcome:"change:changed",evidence:["deterministic:passed"],
   audit:{producer_status:"completed",forge_status:"completed",
          target_tree_id:$target_tree,candidate_tree_id:$candidate_tree}};

if $command == "inventory" then inventory_ok($fixture_sha256)
elif $command == "producer-response" then producer_response_ok($package_id)
elif $command == "forge-response" then forge_response_ok($package_id)
elif $command == "projection" then projection($artifact_sha256;$target_tree_id;$candidate_tree_id)
else error("unknown-command") end
