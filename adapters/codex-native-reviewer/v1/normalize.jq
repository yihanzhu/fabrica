def exact_fields($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");
def provider_id_ok:
  type == "string" and test("\\A[1-9][0-9]{0,19}\\z");
def finding_id_ok:
  type == "string" and test("\\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z");
def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");
def text_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 8192;
def media_type_ok:
  type == "string" and
  utf8bytelength <= 127 and
  test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z");

def metadata_number_ok:
  type == "number" and
  (isnan | not) and
  (isinfinite | not) and
  . >= -9007199254740991 and
  . <= 9007199254740991 and
  tostring != "-0";

def metadata_value_ok($depth):
  . as $value |
  $depth <= 8 and
  if type == "object" then
    length <= 64 and
    all(keys_unsorted[];
      utf8bytelength <= 128 and
      ($value[.] | metadata_value_ok($depth + 1)))
  elif type == "array" then
    length <= 64 and all(.[]; metadata_value_ok($depth + 1))
  elif type == "string" then
    utf8bytelength <= 4096
  elif type == "number" then
    metadata_number_ok
  else
    type == "boolean" or type == "null"
  end;

def provider_metadata_ok:
  type == "object" and
  (tojson | utf8bytelength <= 16384) and
  ([paths] | length <= 255) and
  metadata_value_ok(1);

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

def revision_ok:
  exact_fields(["repository_id","hash_algorithm","commit_id"];[]) and
  (.repository_id | id_ok) and
  (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
  (if .hash_algorithm == "sha1"
   then (.commit_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else (.commit_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok) and
  (.content_id | contains(":") | not) and
  (.content_id | contains("/") | not) and
  (.media_type | media_type_ok) and
  (.sha256 | sha256_ok);

def trust_context_ok:
  exact_fields(
    ["expected_repository_id","expected_change_request_id","expected_review_id",
     "expected_head","expected_base","expected_github_app_id","observation_time",
     "instruction_ref","review_policy_ref","execution_boundary_id",
     "invocation_kind"];
    []) and
  (.expected_repository_id | provider_id_ok) and
  (.expected_change_request_id | provider_id_ok) and
  (.expected_review_id | provider_id_ok) and
  (.expected_head | revision_ok) and
  (.expected_base | revision_ok) and
  .expected_head.repository_id == .expected_base.repository_id and
  (.expected_github_app_id | provider_id_ok) and
  (.observation_time | time_ok) and
  (.instruction_ref | content_ref_ok) and
  (.review_policy_ref | content_ref_ok) and
  (.execution_boundary_id | id_ok) and
  .invocation_kind == "native-review";

def path_ok:
  type == "string" and length > 0 and utf8bytelength <= 4096 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".."));

def unavailable_ok:
  exact_fields(["state","reason_id"];[]) and
  .state == "unavailable" and (.reason_id | id_ok);

def hidden_execution_ok:
  exact_fields(["model","effort","tools","cost"];[]) and
  all([.model,.effort,.tools,.cost][]; unavailable_ok);

def top_finding_ok:
  exact_fields(["finding_id","body","provider_severity","provider_metadata"];[]) and
  (.finding_id | finding_id_ok) and
  (.body | text_ok) and
  (.provider_severity | text_ok) and
  (.provider_metadata | provider_metadata_ok);

def inline_finding_ok($head):
  exact_fields(
    ["finding_id","path","line","side","commit_id","body",
     "provider_severity","provider_metadata"];
    []) and
  (.finding_id | finding_id_ok) and
  (.path | path_ok) and
  (.line | type == "number" and . == floor and . >= 1 and . <= 2147483647) and
  (.side == "LEFT" or .side == "RIGHT") and
  .commit_id == $head.commit_id and
  (.body | text_ok) and
  (.provider_severity | text_ok) and
  (.provider_metadata | provider_metadata_ok);

def findings_ok:
  . as $snapshot |
  (.reported_top_level_count | type == "number" and
   . == floor and . >= 0 and . <= 100000) and
  (.reported_inline_count | type == "number" and
   . == floor and . >= 0 and . <= 100000) and
  (.top_level_findings | type == "array" and length <= 256 and
   all(.[]; top_finding_ok) and
   (map(.finding_id) as $ids |
    $ids == ($ids | sort) and ($ids | length) == ($ids | unique | length))) and
  (.inline_findings | type == "array" and length <= 256 and
   all(.[]; inline_finding_ok($snapshot.head)) and
   (map([.path,.line,.side,.finding_id]) as $keys | $keys == ($keys | sort))) and
  ((.top_level_findings + .inline_findings) | map(.finding_id) |
   length == (unique | length)) and
  (if .complete then
     (.top_level_findings | length) == .reported_top_level_count and
     (.inline_findings | length) == .reported_inline_count
   else
     (.top_level_findings | length) <= .reported_top_level_count and
     (.inline_findings | length) <= .reported_inline_count
   end);

def status_facts_ok:
  if .status == "COMPLETED" then
    (.terminal_at | time_ok) and .dismissed_at == null
  elif .status == "DISMISSED" then
    (.terminal_at | time_ok) and (.dismissed_at | time_ok) and
    .terminal_at <= .dismissed_at
  elif .status == "TIMED_OUT" or .status == "FAILED" then
    (.terminal_at | time_ok) and .dismissed_at == null
  elif .status == "IN_PROGRESS" or .status == "UNKNOWN" then
    .terminal_at == null and .dismissed_at == null
  else false
  end;

def timestamps_ok:
  (.started_at | time_ok) and (.updated_at | time_ok) and (.observed_at | time_ok) and
  .started_at <= .updated_at and .updated_at <= .observed_at and
  (if .terminal_at == null then true
   else .started_at <= .terminal_at and .terminal_at <= .updated_at
   end) and
  (if .dismissed_at == null then true else .dismissed_at <= .updated_at end);

def snapshot_ok:
  exact_fields(
    ["repository_id","change_request_id","review_id","head","base",
     "github_app_id","observed_at","status","complete","started_at","updated_at",
     "terminal_at","dismissed_at","reported_top_level_count",
     "reported_inline_count","top_level_findings","inline_findings",
     "hidden_execution","provider_metadata"];
    []) and
  (.repository_id | provider_id_ok) and
  (.change_request_id | provider_id_ok) and
  (.review_id | provider_id_ok) and
  (.head | revision_ok) and (.base | revision_ok) and
  .head.repository_id == .base.repository_id and
  (.github_app_id | provider_id_ok) and
  (.observed_at | time_ok) and
  (.status | IN("COMPLETED","DISMISSED","TIMED_OUT","FAILED","IN_PROGRESS","UNKNOWN")) and
  (.complete | type == "boolean") and
  (.hidden_execution | hidden_execution_ok) and
  (.provider_metadata | provider_metadata_ok) and
  status_facts_ok and timestamps_ok and findings_ok;

def stale_bindings($context; $snapshot):
  [
    if $snapshot.github_app_id != $context.expected_github_app_id then "app" else empty end,
    if $snapshot.base != $context.expected_base then "base" else empty end,
    if $snapshot.change_request_id != $context.expected_change_request_id then "change-request" else empty end,
    if $snapshot.head != $context.expected_head then "head" else empty end,
    if $snapshot.observed_at != $context.observation_time then "observation-time" else empty end,
    if $snapshot.repository_id != $context.expected_repository_id then "repository" else empty end,
    if $snapshot.review_id != $context.expected_review_id then "review" else empty end
  ];

def normalized_state($snapshot; $stale):
  if ($stale | length) > 0 then ["stale","codex.review-binding-stale"]
  elif $snapshot.status == "DISMISSED" then ["dismissed","codex.review-dismissed"]
  elif $snapshot.status == "TIMED_OUT" then ["timeout","codex.review-timeout"]
  elif $snapshot.status == "FAILED" then ["failed","codex.review-failed"]
  elif $snapshot.complete == false then ["inconclusive","codex.review-incomplete"]
  elif $snapshot.status != "COMPLETED" then ["inconclusive","codex.review-not-terminal"]
  elif ($snapshot.reported_top_level_count + $snapshot.reported_inline_count) > 0 then
    ["findings","codex.review-findings"]
  else ["clean","codex.review-clean"]
  end;

if (exact_fields(["trust_context","snapshot"];[]) | not) then
  error("codex-reviewer.invalid-envelope")
elif (.trust_context | trust_context_ok) == false then
  error("codex-reviewer.invalid-trust-context")
elif (.snapshot | snapshot_ok) == false then
  error("codex-reviewer.invalid-snapshot")
else
  .trust_context as $context |
  .snapshot as $snapshot |
  stale_bindings($context;$snapshot) as $stale |
  normalized_state($snapshot;$stale) as $normalized |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"adapter.codex-native-reviewer.v1",version:"v1",status:"inactive"},
    state:$normalized[0],reason_id:$normalized[1],stale_bindings:$stale,
    review_mode:"read-only",
    trust_context:$context,observation:$snapshot,
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:[]
  }
end
