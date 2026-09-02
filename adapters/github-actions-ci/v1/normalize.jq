def exact_fields($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));
def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def content_id_ok:
  id_ok and (contains(":") | not) and (contains("/") | not);
def media_type_ok:
  type == "string" and utf8bytelength <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");
def provider_id_ok:
  type == "string" and test("\\A[1-9][0-9]{0,19}\\z");
def run_attempt_ok:
  type == "number" and . == floor and . >= 1 and . <= 1000000;
def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");
def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<y>[0-9]{4})-(?<m>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<i>[0-9]{2}):(?<s>[0-9]{2})Z\\z") |
   map_values(tonumber)) as $t |
  ($t.y % 4 == 0 and ($t.y % 100 != 0 or $t.y % 400 == 0)) as $leap |
  [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
  $t.m >= 1 and $t.m <= 12 and $t.d >= 1 and $t.d <= $days[$t.m - 1] and
  $t.h >= 0 and $t.h <= 23 and $t.i >= 0 and $t.i <= 59 and
  $t.s >= 0 and $t.s <= 59;
def revision_ok:
  exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (if .hash_algorithm == "sha1" then (.commit_id | test("\\A[0-9a-f]{40}\\z"))
   else (.commit_id | test("\\A[0-9a-f]{64}\\z")) end);
def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | content_id_ok) and (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);
def job_identity_ok:
  exact_fields(["job_id","check_run_id"];[]) and
  (.job_id | provider_id_ok) and (.check_run_id | provider_id_ok);
def job_key: [(.job_id | length),.job_id,(.check_run_id | length),.check_run_id];
def ordered_unique:
  . as $items | ($items | map(job_key)) as $keys |
  $keys == ($keys | sort) and ($keys | length) == ($keys | unique | length) and
  (($items | map(.job_id) | unique | length) == ($items | length)) and
  (($items | map(.check_run_id) | unique | length) == ($items | length));
def expected_jobs_ok:
  type == "array" and length >= 1 and length <= 128 and
  all(.[]; job_identity_ok) and ordered_unique;
def trust_context_ok:
  exact_fields(
    ["expected_repository_id","expected_check_suite_id","expected_workflow_id",
     "expected_run_id","expected_run_attempt","expected_github_app_id",
     "expected_head","expected_base","expected_jobs","observation_time",
     "instruction_ref","config_ref","execution_boundary_id"];
    []) and
  all([.expected_repository_id,.expected_check_suite_id,.expected_workflow_id,
       .expected_run_id,.expected_github_app_id][]; provider_id_ok) and
  (.expected_run_attempt | run_attempt_ok) and
  (.expected_head | revision_ok) and (.expected_base | revision_ok) and
  .expected_head.repository_id == .expected_base.repository_id and
  (.expected_jobs | expected_jobs_ok) and (.observation_time | time_ok) and
  (.instruction_ref | content_ref_ok) and (.config_ref | content_ref_ok) and
  (.execution_boundary_id | id_ok);
def opaque_text_ok: . == null or (type == "string" and utf8bytelength <= 8192);
def provider_data_ok:
  exact_fields(["name","text","details_url"];[]) and
  all([.name,.text,.details_url][]; opaque_text_ok);
def queued_status: IN("queued","pending","requested","waiting");
def status_ok: queued_status or . == "in_progress" or . == "completed";
def conclusion_ok:
  IN("success","failure","neutral","cancelled","skipped","timed_out",
     "action_required","stale");
def status_conclusion_ok:
  if .status == "completed" then (.conclusion | conclusion_ok)
  else .conclusion == null end;
def job_time_ok($snapshot):
  (if $snapshot.status == "completed" then $snapshot.completed_at
   else $snapshot.observed_at end) as $upper |
  (.created_at | time_ok) and $snapshot.created_at <= .created_at and
  .created_at <= $upper and
  if (.status | queued_status) then .started_at == null and .completed_at == null
  elif .status == "in_progress" then
    (.started_at | time_ok) and $snapshot.started_at <= .started_at and
    .created_at <= .started_at and
    .started_at <= $upper and .completed_at == null
  else
    (.started_at | time_ok) and (.completed_at | time_ok) and
    $snapshot.started_at <= .started_at and .created_at <= .started_at and
    .started_at <= .completed_at and
    .completed_at <= $upper
  end;
def job_ok($snapshot):
  exact_fields(
    ["job_id","check_run_id","status","conclusion","created_at","started_at",
     "completed_at","payload_sha256","provider_data"];
    []) and (.job_id | provider_id_ok) and (.check_run_id | provider_id_ok) and
  (.status | status_ok) and status_conclusion_ok and
  job_time_ok($snapshot) and (.payload_sha256 | sha256_ok) and
  (.provider_data | provider_data_ok);
def run_time_ok:
  (.created_at | time_ok) and (.updated_at | time_ok) and
  .created_at <= .updated_at and .updated_at <= .observed_at and
  if (.status | queued_status) then .started_at == null and .completed_at == null
  elif .status == "in_progress" then
    (.started_at | time_ok) and .created_at <= .started_at and
    .started_at <= .updated_at and .completed_at == null
  else
    (.started_at | time_ok) and (.completed_at | time_ok) and
    .created_at <= .started_at and .started_at <= .completed_at and
    .completed_at <= .updated_at
  end;
def count_ok: type == "number" and . == floor and . >= 0 and . <= 128;
def jobs_ok($snapshot):
  type == "array" and length <= 128 and
  all(.[]; job_ok($snapshot)) and ordered_unique and
  $snapshot.reported_job_count == length + $snapshot.hidden_job_count and
  (if $snapshot.complete then $snapshot.hidden_job_count == 0 else true end);
def snapshot_ok:
  . as $snapshot |
  exact_fields(
    ["repository_id","check_suite_id","workflow_id","run_id","run_attempt",
     "github_app_id","head","base","observed_at","complete","reported_job_count",
     "hidden_job_count","status","conclusion","created_at","updated_at",
     "started_at","completed_at","jobs","payload_sha256","provider_data"];
    []) and
  all([.repository_id,.check_suite_id,.workflow_id,.run_id,.github_app_id][];
      provider_id_ok) and
  (.run_attempt | run_attempt_ok) and
  (.head | revision_ok) and (.base | revision_ok) and
  .head.repository_id == .base.repository_id and (.observed_at | time_ok) and
  (.complete | type == "boolean") and (.reported_job_count | count_ok) and
  (.hidden_job_count | count_ok) and (.status | status_ok) and
  status_conclusion_ok and run_time_ok and (.jobs | jobs_ok($snapshot)) and
  (.payload_sha256 | sha256_ok) and (.provider_data | provider_data_ok);
def jobs_bound_ok($context; $snapshot):
  ($context.expected_jobs) as $expected |
  ($snapshot.jobs | map({job_id,check_run_id})) as $actual |
  all($actual[]; . as $identity | $expected | index($identity) != null) and
  (if $snapshot.complete then $actual == $expected else true end);
def children_agree($snapshot):
  ($snapshot.jobs) as $jobs |
  if ($snapshot.status | queued_status) then all($jobs[]; .status | queued_status)
  elif $snapshot.status == "in_progress" then
    all($jobs[]; .status | status_ok) and
    (if $snapshot.complete then any($jobs[]; .status != "completed") else true end)
  elif (all($jobs[]; .status == "completed") | not) then false
  elif $snapshot.complete == false then true
  elif $snapshot.conclusion == "success" then
    any($jobs[]; .conclusion == "success") and
    all($jobs[]; .conclusion | IN("success","neutral","skipped"))
  elif $snapshot.conclusion == "failure" then any($jobs[]; .conclusion == "failure")
  elif $snapshot.conclusion == "cancelled" then any($jobs[]; .conclusion == "cancelled")
  elif $snapshot.conclusion == "timed_out" then any($jobs[]; .conclusion == "timed_out")
  elif $snapshot.conclusion == "action_required" then
    any($jobs[]; .conclusion == "action_required")
  elif $snapshot.conclusion == "stale" then any($jobs[]; .conclusion == "stale")
  elif $snapshot.conclusion == "neutral" then any($jobs[]; .conclusion == "neutral")
  else all($jobs[]; .conclusion == "skipped")
  end;
def stale_bindings($context; $snapshot):
  [
    if $snapshot.github_app_id != $context.expected_github_app_id then "app" else empty end,
    if $snapshot.base != $context.expected_base then "base" else empty end,
    if $snapshot.check_suite_id != $context.expected_check_suite_id then "check-suite" else empty end,
    if $snapshot.head != $context.expected_head then "head" else empty end,
    if $snapshot.observed_at != $context.observation_time then "observation-time" else empty end,
    if $snapshot.repository_id != $context.expected_repository_id then "repository" else empty end,
    if $snapshot.run_id != $context.expected_run_id then "run" else empty end,
    if $snapshot.run_attempt != $context.expected_run_attempt then "run-attempt" else empty end,
    if $snapshot.workflow_id != $context.expected_workflow_id then "workflow" else empty end
  ];
def normalized($context; $snapshot; $stale):
  if ($stale | length) > 0 then ["stale","ci.binding-stale"]
  elif $snapshot.complete == false or
       ($snapshot.jobs | length) != ($context.expected_jobs | length) then
    ["inconclusive","ci.observation-incomplete"]
  elif ($snapshot.status | queued_status) then ["queued","ci.queued"]
  elif $snapshot.status == "in_progress" then ["in-progress","ci.in-progress"]
  elif $snapshot.conclusion == "success" then ["passed","ci.passed"]
  elif $snapshot.conclusion == "failure" then ["failed","ci.failed"]
  elif $snapshot.conclusion == "cancelled" then ["cancelled","ci.cancelled"]
  elif $snapshot.conclusion == "timed_out" then ["timed-out","ci.timed-out"]
  elif $snapshot.conclusion == "action_required" then ["action-required","ci.action-required"]
  elif $snapshot.conclusion == "stale" then ["stale","ci.provider-stale"]
  else ["inconclusive","ci.provider-inconclusive"]
  end;
def fact_state:
  if (.status | queued_status) then "queued"
  elif .status == "in_progress" then "in-progress"
  elif .conclusion == "success" then "passed"
  elif .conclusion == "failure" then "failed"
  elif .conclusion == "cancelled" then "cancelled"
  elif .conclusion == "timed_out" then "timed-out"
  elif .conclusion == "action_required" then "action-required"
  elif .conclusion == "stale" then "stale"
  else "inconclusive" end;
if (exact_fields(["trust_context","snapshot"];[]) | not) then
  error("github-actions-ci.invalid-envelope")
elif (.trust_context | trust_context_ok) == false then
  error("github-actions-ci.invalid-trust-context")
elif (.snapshot | snapshot_ok) == false then
  error("github-actions-ci.invalid-snapshot")
elif jobs_bound_ok(.trust_context;.snapshot) == false or children_agree(.snapshot) == false then
  error("github-actions-ci.provider-contradiction")
else
  .trust_context as $context | .snapshot as $snapshot |
  stale_bindings($context;$snapshot) as $stale |
  normalized($context;$snapshot;$stale) as $normalized |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"adapter.github-actions-ci.v1",version:"v1",status:"inactive"},
    state:$normalized[0],
    reason_id:$normalized[1],
    stale_bindings:$stale,
    trust_context:$context,
    observation:$snapshot,
    result:{
      state:$normalized[0],
      observed_at:$snapshot.observed_at,
      subject:{head:$snapshot.head,base:$snapshot.base},
      provenance:{
        repository_id:$snapshot.repository_id,
        workflow_id:$snapshot.workflow_id,
        run_id:$snapshot.run_id,
        run_attempt:$snapshot.run_attempt,
        check_suite_id:$snapshot.check_suite_id
      },
      source_sha256:$snapshot.payload_sha256,
      facts:($snapshot.jobs | map({
        fact_id:("ci.job." + .job_id + ".check." + .check_run_id),
        state:fact_state,
        source_sha256:.payload_sha256,
        provider_data:.provider_data
      }))
    },
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:[]
  }
end
