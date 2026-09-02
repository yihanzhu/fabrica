def exact_fields($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def provider_id_ok:
  type == "string" and test("\\A[1-9][0-9]{0,19}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def time_ok:
  type == "string" and
  test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z") and
  (capture("\\A(?<year>[0-9]{4})-(?<month>[0-9]{2})-(?<day>[0-9]{2})T(?<hour>[0-9]{2}):(?<minute>[0-9]{2}):(?<second>[0-9]{2})Z\\z") as $parts |
   ($parts.year | tonumber) as $year |
   ($parts.month | tonumber) as $month |
   ($parts.day | tonumber) as $day |
   ($parts.hour | tonumber) as $hour |
   ($parts.minute | tonumber) as $minute |
   ($parts.second | tonumber) as $second |
   ($year % 4 == 0 and ($year % 100 != 0 or $year % 400 == 0)) as $leap |
   [31,(if $leap then 29 else 28 end),31,30,31,30,31,31,30,31,30,31] as $days |
   $month >= 1 and $month <= 12 and
   $day >= 1 and $day <= $days[$month - 1] and
   $hour >= 0 and $hour <= 23 and
   $minute >= 0 and $minute <= 59 and
   $second >= 0 and $second <= 59);

def repository_id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def revision_ok:
  exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id | repository_id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (if .hash_algorithm == "sha1"
   then (.commit_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else (.commit_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok) and
  (.media_type | type == "string" and
   test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z")) and
  (.sha256 | sha256_ok);

def trust_context_ok:
  exact_fields(
    ["expected_repository_id","expected_change_request_id","expected_head",
     "expected_base","expected_github_app_id","observation_time",
     "instruction_ref","config_ref"];
    []) and
  (.expected_repository_id | provider_id_ok) and
  (.expected_change_request_id | provider_id_ok) and
  (.expected_head | revision_ok) and
  (.expected_base | revision_ok) and
  .expected_head.repository_id == .expected_base.repository_id and
  (.expected_github_app_id | provider_id_ok) and
  (.observation_time | time_ok) and
  (.instruction_ref | content_ref_ok) and
  (.config_ref | content_ref_ok);

def path_ok:
  type == "string" and length > 0 and utf8bytelength <= 4096 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));

def file_ok:
  exact_fields(["path","status","patch_sha256"];[]) and
  (.path | path_ok) and
  (.status | type == "string" and
   IN("added","changed","copied","modified","removed","renamed","unchanged")) and
  (.patch_sha256 | sha256_ok);

def files_ok($reported_count; $complete):
  type == "array" and length <= 256 and
  all(.[]; file_ok) and
  (map(.path) as $paths |
   $paths == ($paths | sort) and
   ($paths | length) == ($paths | unique | length)) and
  ($reported_count | type == "number" and . == floor and . >= 0 and . <= 100000) and
  (if $complete then length == $reported_count else length <= $reported_count end);

def state_facts_ok:
  if .state == "OPEN" then
    .closed == false and .merged == false and
    .closed_at == null and .merged_at == null
  elif .state == "CLOSED" then
    .closed == true and .merged == false and
    (.closed_at | time_ok) and .merged_at == null and .mergeability == "UNKNOWN"
  elif .state == "MERGED" then
    .closed == true and .merged == true and
    (.closed_at | time_ok) and (.merged_at | time_ok) and
    .merged_at <= .closed_at and .mergeability == "UNKNOWN"
  elif .state == "UNKNOWN" then
    .closed == false and .merged == false and
    .closed_at == null and .merged_at == null and .mergeability == "UNKNOWN"
  else false
  end;

def timestamps_ok:
  (.created_at | time_ok) and
  (.updated_at | time_ok) and
  (.observed_at | time_ok) and
  .created_at <= .updated_at and .updated_at <= .observed_at and
  (if .closed_at == null then true
   else .created_at <= .closed_at and .closed_at <= .updated_at end) and
  (if .merged_at == null then true
   else .created_at <= .merged_at and .merged_at <= .updated_at end);

def snapshot_ok:
  . as $snapshot |
  exact_fields(
    ["repository_id","change_request_id","head","base","github_app_id",
     "observed_at","complete","reported_file_count","state","mergeability",
     "closed","merged","created_at","updated_at","closed_at","merged_at",
     "files","provider_metadata"];
    []) and
  (.repository_id | provider_id_ok) and
  (.change_request_id | provider_id_ok) and
  (.head | revision_ok) and
  (.base | revision_ok) and
  .head.repository_id == .base.repository_id and
  (.github_app_id | provider_id_ok) and
  (.observed_at | time_ok) and
  (.complete | type == "boolean") and
  (.state | IN("OPEN","CLOSED","MERGED","UNKNOWN")) and
  (.mergeability | IN("MERGEABLE","CONFLICTING","UNKNOWN")) and
  (.closed | type == "boolean") and
  (.merged | type == "boolean") and
  (.provider_metadata | type == "object") and
  (.files | files_ok($snapshot.reported_file_count;$snapshot.complete)) and
  state_facts_ok and timestamps_ok;

def stale_bindings($context; $snapshot):
  [
    if $snapshot.github_app_id != $context.expected_github_app_id then "app" else empty end,
    if $snapshot.base != $context.expected_base then "base" else empty end,
    if $snapshot.change_request_id != $context.expected_change_request_id then "change-request" else empty end,
    if $snapshot.head != $context.expected_head then "head" else empty end,
    if $snapshot.observed_at != $context.observation_time then "observation-time" else empty end,
    if $snapshot.repository_id != $context.expected_repository_id then "repository" else empty end
  ];

def normalized_state($snapshot; $stale):
  if ($stale | length) > 0 then ["stale","github.binding-stale"]
  elif $snapshot.complete == false then ["inconclusive","github.snapshot-incomplete"]
  elif $snapshot.state == "UNKNOWN" then ["inconclusive","github.state-unknown"]
  elif $snapshot.state == "MERGED" then ["merged","github.change-request-merged"]
  elif $snapshot.state == "CLOSED" then ["closed-unmerged","github.change-request-closed-unmerged"]
  elif $snapshot.mergeability == "MERGEABLE" then ["open-ready","github.change-request-open-ready"]
  elif $snapshot.mergeability == "CONFLICTING" then ["open-blocked","github.change-request-open-blocked"]
  else ["inconclusive","github.mergeability-unknown"]
  end;

if (exact_fields(["trust_context","snapshot"];[]) | not) then
  error("github-forge.invalid-envelope")
elif (.trust_context | trust_context_ok) == false then
  error("github-forge.invalid-trust-context")
elif (.snapshot | snapshot_ok) == false then
  error("github-forge.invalid-snapshot")
else
  .trust_context as $context |
  .snapshot as $snapshot |
  stale_bindings($context;$snapshot) as $stale |
  normalized_state($snapshot;$stale) as $normalized |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"adapter.github-forge.v1",version:"v1",status:"inactive"},
    state:$normalized[0],
    reason_id:$normalized[1],
    stale_bindings:$stale,
    trust_context:$context,
    observation:$snapshot,
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:[]
  }
end
