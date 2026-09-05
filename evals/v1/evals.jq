import "schema" as schema;

# Inactive eval/trace framework contracts (Roadmap item 5, unit 1).
# Pure jq 1.6. Consumes only canonical core-v2 documents and caller-supplied
# offline observations. Grants nothing, executes nothing, records no cost.

def expected_core:
  {
    generation_id_sha256:
      "84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
    package_ref:{
      content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",
      sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"
    },
    semantic_identity:"core.contracts.v2"
  };

def expected_core_closure:
  [
    {path:"core/v2/generation-registry.json",
     sha256:"3950ce43c3073b97759db23fb7e4ce533cbc1d8a8fe4917db6ee1ee0a8e78f94"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq",
     sha256:"65eb40b9afb9b4f1d809ed66d0f2ca625f656c34e856cedcde9cbbde857f0f0a"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh",
     sha256:"dfdd273ea98f8737188a2a347151b3ffc0e631e222abfaac55391d58dd2618e8"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/profile_graph.jq",
     sha256:"c00f9cfbe88df5cb1dbcfbead61288ff7d68684d43d095e74f26e7820f0d7207"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_facts.jq",
     sha256:"8e49c2c091f1bbe525f7499e3fca072f6916a14d5bb34adbf121439e8ca2d281"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/result_truth.jq",
     sha256:"ed4a9946a95ad0c701f74d6bd64c3b45264126927c2a53511d31c52241c7fd46"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/schema.jq",
     sha256:"8d1d02d36ac7ada778f05248f9413062b3fc251499914c15d79f003bbd009ade"},
    {path:"core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/stage_request.jq",
     sha256:"6572a6ecbac332dc9c4a8ef35acd1feebdc2e8aab04941fc0b756f3a5cbcf29e"},
    {path:"scripts/core-contract.sh",
     sha256:"b081c7de1707a21bd948b998491caa7171084b15d9d95bceaae550cc7893fec9"}
  ];

# The inactive state scanner and reconciliation planner replayed for the events
# family, pinned like the core.
def expected_orchestrator_closure:
  [
    {path:"orchestrator/v1/reconciliation-plan.jq",
     sha256:"03904cef1e06acf207ee7a6cf8666f7dd7a6360acd95bb1e8ce34bd6409ddbe4"},
    {path:"orchestrator/v1/scan-state.sh",
     sha256:"556a365b92a76c7a46c56b25c61a291f5ab3dcad8168fb77f15c15b3f3477ca5"},
    {path:"orchestrator/v1/state-scanner-driver.sh",
     sha256:"5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b"},
    {path:"orchestrator/v1/state-scanner-launcher.sh",
     sha256:"9bff3ce5669477ff6c3043115fd6ea01da486facd5f5f4f7ec2066efb70001cb"},
    {path:"orchestrator/v1/state-scanner.jq",
     sha256:"722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae"}
  ];

def ref_shape($content_id; $media_type):
  schema::content_ref_ok and
  .content_id == $content_id and .media_type == $media_type;

def present_shape(value_ok):
  (schema::exact_fields(["state"];[]) and .state == "absent") or
  (schema::exact_fields(["state","value"];[]) and .state == "present" and
   (.value | value_ok));

def pair_shape($kind):
  schema::exact_fields(["content","sha256"];[]) and
  (.content | schema::envelope_ok($kind)) and
  (.sha256 | schema::sha256_ok);

def grader_kinds: ["deterministic","human","model"];
def verdicts: ["failed","inconclusive","passed"];
def family_ids:
  ["actor-rerun-identity",
   "adapter-contract-compliance",
   "approval-invalidation-no-push-after-approval",
   "empty-fake-timed-out-degraded-reviews",
   "malicious-instructions",
   "protected-path-credential-network-publisher-boundaries",
   "repeated-cancelled-missed-events",
   "reviewer-severity-false-positive-negative",
   "stale-moved-artifacts"];
def seed_sources:
  ["adapter-tests.contract.v1","core.stage-run.v2",
   "orchestrator.reconciliation-plan.v1","orchestrator.state-scanner.v1"];
def stage_statuses:
  ["blocked","cancelled","completed","failed","skipped","stale"];
def core_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_REF","E_RELATION","E_RUNTIME","E_SHAPE","E_USAGE"];
def request_roles: ["producer","reviewer","verifier"];
def active_seed_sources:
  ["core.stage-run.v2","orchestrator.reconciliation-plan.v1","orchestrator.state-scanner.v1"];
def planner_error_tokens: ["E_RECONCILIATION_INPUT"];
def plan_operations: ["dispatch-stage","recover-stranded-attempt","retry-stage"];
def delivery_modes: ["first-delivery","redelivery"];
def scanner_error_tokens:
  ["E_CANONICAL","E_LIMIT","E_PARSE","E_RELATION","E_RUNTIME","E_SHAPE","E_STALE","E_USAGE"];
def scanner_classes: ["blocked","pending","retryable","stale","stranded","terminal"];
def scanner_actions:
  ["dispatch-stage","none","operator-reconcile","recover-stranded-attempt",
   "refresh-stage-inputs","resolve-stage-blocker","retry-stage","wait-for-attempt"];
def scanner_reason_ids:
  ["scanner.attempt-deadline-reached","scanner.attempt-in-flight","scanner.no-attempt",
   "scanner.retry-limit-reached","scanner.stage-blocked","scanner.stage-cancelled",
   "scanner.stage-completed","scanner.stage-failed","scanner.stage-skipped",
   "scanner.stage-stale","scanner.target-revision-moved"];
def tool_content_id($source):
  if $source == "core.stage-run.v2" then "core-contract-front-door.v2"
  elif $source == "orchestrator.state-scanner.v1" then "orchestrator-state-scanner-bootstrap.v1"
  else "orchestrator-reconciliation-planner.v1" end;
def tool_media_type($source):
  if $source == "orchestrator.reconciliation-plan.v1" then "text/x-jq"
  else "text/x-shellscript" end;

def trial_policy_shape:
  (schema::exact_fields(["kind"];[]) and .kind == "single") or
  (schema::exact_fields(["kind","minimum_trials"];[]) and .kind == "multi" and
   (.minimum_trials | schema::int_ok) and
   .minimum_trials >= 2 and .minimum_trials <= 16);

def family_shape:
  schema::exact_fields(
    ["family_id","roadmap_requirement","grader_kinds","trial_policy",
     "evidence_kinds","seed_status","seed_sources"];[]) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.roadmap_requirement | schema::short_text_ok) and
  (.grader_kinds | schema::enum_set_ok(1;3;grader_kinds)) and
  (.trial_policy | trial_policy_shape) and
  (.evidence_kinds | schema::enum_set_ok(1;4;schema::evidence_kinds)) and
  (.seed_status == "seeded" or .seed_status == "declared") and
  (.seed_sources | schema::enum_set_ok(0;4;seed_sources)) and
  ((.seed_status == "seeded") == ((.seed_sources | length) >= 1)) and
  # A family that only a model or human can grade may not claim a single trial.
  (if (.grader_kinds | index("deterministic")) == null
   then .trial_policy.kind == "multi" else true end);

def catalog_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
  (.body |
   schema::exact_fields(
     ["activation_state","catalog_version","core_contract","fail_mode",
      "families","grader_kinds","verdicts"];[]) and
   .activation_state == "inactive" and .fail_mode == "closed" and
   .catalog_version == "v1" and .core_contract == expected_core and
   .grader_kinds == grader_kinds and .verdicts == verdicts and
   (.families | schema::bounded_set(9;9;family_shape;.family_id)) and
   ((.families | map(.family_id) | sort) == family_ids));

def evaluator_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_framework_evaluator" and
  .id == "evals.framework.v1" and
  (.body |
   schema::exact_fields(
     ["bootstrap_ref","catalog_ref","core_closure","core_contract","driver_ref",
      "launcher_ref","orchestrator_closure","program_ref","runtime"];[]) and
   .core_contract == expected_core and .core_closure == expected_core_closure and
   .orchestrator_closure == expected_orchestrator_closure and
   (.bootstrap_ref | ref_shape("evals-framework-bootstrap.v1";"text/x-shellscript")) and
   (.launcher_ref | ref_shape("evals-framework-launcher.v1";"text/x-shellscript")) and
   # Shipped artifacts are pinned to the digests the launcher and driver verified,
   # so an archived result cannot claim a program, driver, or catalog that never ran.
   (.driver_ref | ref_shape("evals-framework-driver.v1";"text/x-shellscript") and
    .sha256 == $driver_sha256) and
   (.program_ref | ref_shape("evals-framework-program.v1";"text/x-jq") and
    .sha256 == $program_sha256) and
   (.catalog_ref |
    ref_shape("evals-catalog.v1";"application/vnd.ystack.eval-catalog+json") and
    .sha256 == $catalog_sha256) and
   (.runtime |
    schema::exact_fields(
      ["execution_mode","host_architecture","host_os","jq_architecture",
       "jq_ref","shell_ref"];[]) and
    (.jq_ref | ref_shape("jq-runtime.v1";"application/x-executable")) and
    (.shell_ref | ref_shape("bash-runtime";"application/x-executable")) and
    ((.host_os == "linux" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44") or
     (.host_os == "darwin" and .host_architecture == "x86_64" and
      .jq_architecture == "x86_64" and .execution_mode == "native" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef") or
     (.host_os == "darwin" and .host_architecture == "arm64" and
      .jq_architecture == "x86_64" and .execution_mode == "rosetta" and
      .jq_ref.sha256 ==
        "5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"))));

def stage_run_expectation_shape:
  (schema::exact_fields(["disposition","status"];[]) and
   .disposition == "accepted" and
   (.status as $status | stage_statuses | index($status) != null)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | core_error_tokens | index($token) != null));

def classification_shape:
  schema::exact_fields(["action","class","reason_id"];[]) and
  (.class as $c | scanner_classes | index($c) != null) and
  (.action as $a | scanner_actions | index($a) != null) and
  (.reason_id as $r | scanner_reason_ids | index($r) != null);

def scanner_expectation_shape:
  (schema::exact_fields(["action","class","disposition","reason_id"];[]) and
   .disposition == "observed" and (del(.disposition) | classification_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | scanner_error_tokens | index($token) != null));

# A plan is graded on exactly which stage, request, operation, and attempt it
# would deliver, defer, or suppress, and which stages it hands to an operator.
# Provenance and document refs stay the planner's own concern.
def plan_stage_key_shape:
  schema::exact_fields(["initiative_id","stage_id","task_class_id","workflow_id"];[]) and
  all(.[]; schema::id_ok);

def plan_item_shape($extra):
  schema::exact_fields(
    ["attempt_number","operation","request_sha256","stage_key"] + [$extra];[]) and
  (.attempt_number | schema::int_ok) and .attempt_number >= 1 and .attempt_number <= 10 and
  (.operation as $o | plan_operations | index($o) != null) and
  (.request_sha256 | schema::sha256_ok) and
  (.stage_key | plan_stage_key_shape);

def plan_summary_shape:
  schema::exact_fields(["deferred","deliveries","operator_messages","suppressed"];[]) and
  (.deliveries | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("delivery_mode") and
            (.delivery_mode as $m | delivery_modes | index($m) != null))) and
  (.deferred | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.suppressed | type == "array" and length <= 64 and
   all(.[]; plan_item_shape("reason_id") and (.reason_id | schema::id_ok))) and
  (.operator_messages | type == "array" and length <= 64 and
   all(.[];
     schema::exact_fields(["action","class","stage_key"];[]) and
     (.action as $a | scanner_actions | index($a) != null) and
     (.class as $c | scanner_classes | index($c) != null) and
     (.stage_key | plan_stage_key_shape)));

def planner_expectation_shape:
  (schema::exact_fields(
     ["deferred","deliveries","disposition","operator_messages","suppressed"];[]) and
   .disposition == "planned" and (del(.disposition) | plan_summary_shape)) or
  (schema::exact_fields(["disposition","error_token"];[]) and
   .disposition == "rejected" and
   (.error_token as $token | planner_error_tokens | index($token) != null));

def expectation_shape($source):
  if $source == "core.stage-run.v2" then stage_run_expectation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_expectation_shape
  else planner_expectation_shape end;

def stage_run_case_shape:
  schema::exact_fields(["case_id","family_id","expectation","request_role","result"];[]) and
  (.case_id | schema::id_ok) and
  (.request_role as $role | request_roles | index($role) != null) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | stage_run_expectation_shape) and
  (.result | pair_shape("stage_result"));

# Snapshots are schema_version 1 orchestrator documents, not core-v2 envelopes.
def snapshot_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(["body","id","kind","schema_version"];[]) and
   .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
   (.id | schema::id_ok) and (.body | type == "object")) and
  (.sha256 | schema::sha256_ok);

# Planner inputs are plain bundles, not envelopes; the planner validates them.
def planner_input_pair_shape:
  schema::exact_fields(["content","sha256"];[]) and
  (.content |
   schema::exact_fields(
     ["delivery_ledger","delivery_ledger_ref","max_in_flight","observation",
      "observation_ref"];[])) and
  (.sha256 | schema::sha256_ok);

def planner_case_shape:
  schema::exact_fields(["case_id","expectation","family_id","input"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expectation | planner_expectation_shape) and
  (.input | planner_input_pair_shape);

def scanner_case_shape:
  schema::exact_fields(
    ["case_id","expected_revision","expectation","family_id","snapshot"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.expected_revision | schema::git_revision_ref_ok) and
  (.expectation | scanner_expectation_shape) and
  (.snapshot | snapshot_pair_shape);

# The run id is "evals.run." + seed id, so a seed id must leave room for the
# prefix inside the shared 128-character id limit.
def run_id_prefix: "evals.run.";
def seed_set_id_ok: schema::id_ok and ((run_id_prefix + .) | schema::id_ok);

def seed_set_shape:
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_seed_set" and (.id | seed_set_id_ok) and
  (.body |
   schema::exact_fields(["cases","core_contract","seed_source","shared"];[]) and
   .core_contract == expected_core and
   (.seed_source as $source | active_seed_sources | index($source) != null) and
   (if .seed_source == "core.stage-run.v2" then
      (.shared |
       schema::exact_fields(["requests","resolved_profile"];[]) and
       (.requests | type == "object" and length >= 1 and
        all(keys[]; . as $role | request_roles | index($role) != null) and
        all(.[]; pair_shape("stage_request"))) and
       (.resolved_profile | pair_shape("resolved_profile"))) and
      (.cases | schema::bounded_set(1;64;stage_run_case_shape;.case_id)) and
      # Every case names a request the shared set actually carries.
      (.shared.requests | keys) as $roles |
      all(.cases[]; .request_role as $role | $roles | index($role) != null)
    elif .seed_source == "orchestrator.state-scanner.v1" then
      # Scanner cases are self-contained: each carries its own snapshot.
      .shared == {} and
      (.cases | schema::bounded_set(1;64;scanner_case_shape;.case_id))
    else
      .shared == {} and
      (.cases | schema::bounded_set(1;64;planner_case_shape;.case_id))
    end));

# A seed set may only feed families the catalog says draw on its source.
def seed_set_bound($catalog):
  seed_set_shape and
  (.body.seed_source as $source |
   all(.body.cases[]; .family_id as $family |
     ([$catalog.body.families[] | select(.family_id == $family) | .seed_sources[]] |
      index($source)) != null));

def stage_run_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","status"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "accepted" and
    (.status | present_shape(. as $s | stage_statuses | index($s) != null)) and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .status == {state:"absent"} and
    (.error_token | present_shape(. as $t | core_error_tokens | index($t) != null))));

def scanner_observation_shape:
  schema::exact_fields(["case_id","classification","disposition","error_token"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "observed" and
    (.classification | present_shape(classification_shape)) and
    .classification.state == "present" and .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .classification == {state:"absent"} and
    (.error_token | present_shape(. as $t | scanner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def planner_observation_shape:
  schema::exact_fields(["case_id","disposition","error_token","plan"];[]) and
  (.case_id | schema::id_ok) and
  ((.disposition == "planned" and
    (.plan | present_shape(plan_summary_shape)) and .plan.state == "present" and
    .error_token == {state:"absent"}) or
   (.disposition == "rejected" and .plan == {state:"absent"} and
    (.error_token | present_shape(. as $t | planner_error_tokens | index($t) != null)) and
    .error_token.state == "present"));

def observation_shape($source):
  if $source == "core.stage-run.v2" then stage_run_observation_shape
  elif $source == "orchestrator.state-scanner.v1" then scanner_observation_shape
  else planner_observation_shape end;

def observation_set_shape($source):
  type == "array" and length >= 1 and length <= 64 and
  all(.[]; observation_shape($source)) and
  (map(.case_id) as $ids | ($ids | length) == ($ids | unique | length));

# Deterministic grading. A family without a deterministic grader cannot be
# decided here and stays inconclusive; nothing is inferred from silence.
def grade($family; $expectation; $observation):
  if ($family.grader_kinds | index("deterministic")) == null then
    {verdict:"inconclusive",reason_id:"evals.no-deterministic-grader"}
  elif $observation == null then
    {verdict:"inconclusive",reason_id:"evals.observation-missing"}
  elif $expectation.disposition != $observation.disposition then
    {verdict:"failed",reason_id:"evals.disposition-mismatch"}
  elif $expectation.disposition == "accepted" then
    if $observation.status == {state:"present",value:$expectation.status} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.status-mismatch"} end
  elif $expectation.disposition == "observed" then
    if $observation.classification ==
       {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.classification-mismatch"} end
  elif $expectation.disposition == "planned" then
    if $observation.plan == {state:"present",value:($expectation | del(.disposition))} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.plan-mismatch"} end
  else
    if $observation.error_token == {state:"present",value:$expectation.error_token} then
      {verdict:"passed",reason_id:"evals.expectation-met"}
    else {verdict:"failed",reason_id:"evals.error-token-mismatch"} end
  end;

def grader_kind_for($family):
  if ($family.grader_kinds | index("deterministic")) != null
  then "deterministic" else "none" end;

def trace_event($case; $family; $tool_ref; $evaluator_ref):
  {
    event_kind:"eval-case",
    case_id:$case.case_id,
    family_id:$family.family_id,
    grader_kind:grader_kind_for($family),
    tool_ref:$tool_ref,
    adapter:{state:"absent"},
    gate:{state:"absent"},
    identity:{evaluator_ref:$evaluator_ref},
    latency:{state:"absent"},
    cost:{state:"absent"}
  };

def evaluator_ref($evaluator_sha):
  {content_id:"evals-framework-evaluator.v1",
   media_type:"application/vnd.ystack.eval-framework-evaluator+json",
   sha256:$evaluator_sha};

def document_ref($doc; $sha):
  {schema_version:1,kind:$doc.kind,id:$doc.id,sha256:$sha};

def build_run_result(
    $catalog; $catalog_sha; $evaluator; $evaluator_sha;
    $seed_set; $seed_set_sha; $observations; $tool_ref; $observed_at):
  ($catalog.body.families | map({key:.family_id,value:.}) | from_entries) as $families |
  ($observations | map({key:.case_id,value:.}) | from_entries) as $observed |
  ($seed_set.body.cases | sort_by(.case_id) | map(
     . as $case |
     $families[$case.family_id] as $family |
     $observed[$case.case_id] as $observation |
     grade($family;$case.expectation;$observation) as $graded |
     {
       case_id:$case.case_id,
       family_id:$case.family_id,
       grader_kind:grader_kind_for($family),
       expectation:$case.expectation,
       observation:(if $observation == null then {state:"absent"}
                    else {state:"present",value:$observation} end),
       verdict:$graded.verdict,
       reason_id:$graded.reason_id,
       subject_ref:
         (if $seed_set.body.seed_source == "core.stage-run.v2" then
            {schema_version:2,kind:"stage_result",
             id:$case.result.content.id,sha256:$case.result.sha256}
          elif $seed_set.body.seed_source == "orchestrator.state-scanner.v1" then
            {schema_version:1,kind:"orchestrator_state_snapshot",
             id:$case.snapshot.content.id,sha256:$case.snapshot.sha256}
          else
            {content_id:"orchestrator-reconciliation-input.v1",
             media_type:"application/json",sha256:$case.input.sha256}
          end)
     })) as $cases |
  {
    schema_version:1,
    kind:"eval_run_result",
    id:(run_id_prefix + $seed_set.id),
    body:{
      activation_state:"inactive",
      authority_effect:"none",
      mode:"deterministic-offline",
      core_contract:expected_core,
      catalog_ref:document_ref($catalog;$catalog_sha),
      evaluator:{content:$evaluator,sha256:$evaluator_sha},
      seed_set_ref:document_ref($seed_set;$seed_set_sha),
      seed_source:$seed_set.body.seed_source,
      observed_at:$observed_at,
      summary:{
        total:($cases | length),
        passed:($cases | map(select(.verdict == "passed")) | length),
        failed:($cases | map(select(.verdict == "failed")) | length),
        inconclusive:($cases | map(select(.verdict == "inconclusive")) | length)
      },
      cases:$cases,
      trace:($seed_set.body.cases | sort_by(.case_id) | map(
        trace_event(.;$families[.family_id];$tool_ref;evaluator_ref($evaluator_sha))))
    }
  };

def subject_ref_shape($source):
  if $source == "core.stage-run.v2" then schema::document_ref_kind_ok("stage_result")
  elif $source == "orchestrator.reconciliation-plan.v1" then
    ref_shape("orchestrator-reconciliation-input.v1";"application/json")
  else
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "orchestrator_state_snapshot" and
    (.id | schema::id_ok) and (.sha256 | schema::sha256_ok)
  end;

def case_result_shape($source):
  schema::exact_fields(
    ["case_id","expectation","family_id","grader_kind","observation",
     "reason_id","subject_ref","verdict"];[]) and
  (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.grader_kind == "deterministic" or .grader_kind == "none") and
  (.expectation | expectation_shape($source)) and
  (.observation | present_shape(observation_shape($source))) and
  (.verdict as $v | verdicts | index($v) != null) and
  (.reason_id | schema::id_ok) and
  (.subject_ref | subject_ref_shape($source)) and
  (if .grader_kind == "none" then .verdict == "inconclusive" else true end) and
  (if .observation.state == "absent" then .verdict == "inconclusive" else true end);

def trace_event_shape($source):
  schema::exact_fields(
    ["adapter","case_id","cost","event_kind","family_id","gate","grader_kind",
     "identity","latency","tool_ref"];[]) and
  .event_kind == "eval-case" and (.case_id | schema::id_ok) and
  (.family_id as $id | family_ids | index($id) != null) and
  (.grader_kind == "deterministic" or .grader_kind == "none") and
  (.tool_ref | ref_shape(tool_content_id($source);tool_media_type($source))) and
  .adapter == {state:"absent"} and .gate == {state:"absent"} and
  .latency == {state:"absent"} and .cost == {state:"absent"} and
  (.identity |
   schema::exact_fields(["evaluator_ref"];[]) and
   (.evaluator_ref |
    ref_shape("evals-framework-evaluator.v1";
              "application/vnd.ystack.eval-framework-evaluator+json")));

def run_result_shape($catalog_sha; $evaluator_sha; $seed_set; $seed_set_sha):
  . as $result |
  schema::exact_fields(["body","id","kind","schema_version"];[]) and
  .schema_version == 1 and .kind == "eval_run_result" and (.id | schema::id_ok) and
  (.body |
   schema::exact_fields(
     ["activation_state","authority_effect","cases","catalog_ref","core_contract",
      "evaluator","mode","observed_at","seed_set_ref","seed_source","summary",
      "trace"];[]) and
   .activation_state == "inactive" and .authority_effect == "none" and
   .mode == "deterministic-offline" and .core_contract == expected_core and
   .seed_source == $seed_set.body.seed_source and
   .seed_source as $source |
   (.catalog_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_catalog" and .id == "evals.catalog.v1" and
    .sha256 == $catalog_sha) and
   (.seed_set_ref |
    schema::exact_fields(["id","kind","schema_version","sha256"];[]) and
    .schema_version == 1 and .kind == "eval_seed_set" and .id == $seed_set.id and
    .sha256 == $seed_set_sha) and
   (.evaluator |
    schema::exact_fields(["content","sha256"];[]) and
    (.content | evaluator_shape) and .sha256 == $evaluator_sha) and
   $result.id == (run_id_prefix + $seed_set.id) and
   (.observed_at | schema::time_ok) and
   (.cases | schema::bounded_set(1;64;case_result_shape($source);.case_id)) and
   (.trace | schema::bounded_set(1;64;trace_event_shape($source);.case_id)) and
   ((.cases | map(.case_id)) == (.trace | map(.case_id))) and
   # A trace event never claims a grader the case result did not have.
   ((.cases | map([.case_id, .grader_kind, .family_id])) ==
    (.trace | map([.case_id, .grader_kind, .family_id]))) and
   (.summary |
    schema::exact_fields(["failed","inconclusive","passed","total"];[]) and
    all(.[]; schema::int_ok) and
    .total == ($result.body.cases | length) and
    .passed == ($result.body.cases | map(select(.verdict == "passed")) | length) and
    .failed == ($result.body.cases | map(select(.verdict == "failed")) | length) and
    .inconclusive ==
      ($result.body.cases | map(select(.verdict == "inconclusive")) | length)) and
   all(.trace[]; .identity.evaluator_ref.sha256 == $result.body.evaluator.sha256));

# The tool each case was replayed through: the core front door for stage runs,
# the scanner bootstrap for orchestrator snapshots. Digests come from the caller.
def tool_ref($source):
  {content_id:tool_content_id($source),media_type:tool_media_type($source),
   sha256:(if $source == "core.stage-run.v2" then $tool_sha256
           elif $source == "orchestrator.state-scanner.v1" then $scanner_sha256
           else $planner_sha256 end)};

# Driver entry points, selected with --arg evals_operation.
if $evals_operation == "validate-catalog" then
  $catalog_docs[0] | catalog_shape
elif $evals_operation == "validate-seed-set" then
  $seed_set_docs[0] | seed_set_bound($catalog_docs[0])
elif $evals_operation == "build-run-result" then
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) |
  if . then
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];
      tool_ref($seed_set_docs[0].body.seed_source);$observed_at)
  else error("E_SHAPE") end
elif $evals_operation == "validate-run-result" then
  # A candidate passes only if it is exactly the result this program derives
  # from the same catalog, evaluator, seed set, and recorded observations.
  ($catalog_docs[0] | catalog_shape) and
  ($seed_set_docs[0] | seed_set_bound($catalog_docs[0])) and
  ($observation_docs[0] | observation_set_shape($seed_set_docs[0].body.seed_source)) and
  ($evaluator_docs[0] | evaluator_shape) and
  ($candidate_docs[0] |
   run_result_shape($catalog_sha256; $evaluator_sha256; $seed_set_docs[0]; $seed_set_sha256)) and
  $candidate_docs[0] ==
    build_run_result(
      $catalog_docs[0];$catalog_sha256;$evaluator_docs[0];$evaluator_sha256;
      $seed_set_docs[0];$seed_set_sha256;$observation_docs[0];
      tool_ref($seed_set_docs[0].body.seed_source);$observed_at)
else error("E_RUNTIME") end
