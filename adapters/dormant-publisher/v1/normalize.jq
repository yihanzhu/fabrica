def exact_fields($required; $optional):
  . as $value |
  type == "object" and
  ((keys_unsorted - ($required + $optional)) | length) == 0 and
  all($required[]; . as $key | $value | has($key));

def id_ok:
  type == "string" and test("\\A[a-z0-9][a-z0-9._:-]{0,127}\\z");

def sha256_ok:
  type == "string" and test("\\A[0-9a-f]{64}\\z");

def int_ok:
  type == "number" and . == floor and . >= 0 and . <= 2147483647 and
  tostring != "-0";

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
  (if .hash_algorithm == "sha1" then
     (.commit_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else
     (.commit_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def root_tree_ok($revision):
  exact_fields(["revision","location","object_type","object_id","mode"];[]) and
  .revision == $revision and
  .location == {kind:"root"} and
  .object_type == "tree" and .mode == "040000" and
  (if .revision.hash_algorithm == "sha1" then
     (.object_id | type == "string" and test("\\A[0-9a-f]{40}\\z"))
   else
     (.object_id | type == "string" and test("\\A[0-9a-f]{64}\\z"))
   end);

def content_ref_ok:
  exact_fields(["content_id","media_type","sha256"];[]) and
  (.content_id | id_ok and (contains(":") | not) and (contains("/") | not)) and
  (.media_type | type == "string" and utf8bytelength <= 127 and
   test("\\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\\z")) and
  (.sha256 | sha256_ok);

def path_ok:
  type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096 and
  (test("[\\x{0000}-\\x{001f}\\x{007f}-\\x{009f}]") | not) and
  (contains("\\") | not) and
  (split("/") | all(.[]; . != "" and . != "." and . != ".." and . != ".git"));

def allowed_paths_ok:
  type == "array" and length >= 1 and length <= 64 and
  all(.[]; path_ok) and . == (sort | unique);

def bounded_data($depth):
  if $depth > 8 then false
  elif type == "object" then
    length <= 64 and
    all(keys_unsorted[]; utf8bytelength <= 256) and
    all(.[]; bounded_data($depth + 1))
  elif type == "array" then
    length <= 64 and all(.[]; bounded_data($depth + 1))
  elif type == "string" then utf8bytelength <= 8192
  elif type == "number" then
    . == floor and . >= -2147483648 and . <= 2147483647 and tostring != "-0"
  else true
  end;

def verified_claim_ok:
  exact_fields(["content","sha256"];[]) and
  (.content | type == "object") and (.sha256 | sha256_ok);

def claim_ref($verified):
  {
    content_id:"dormant-publisher-claim",
    media_type:"application/json",
    sha256:$verified.sha256
  };

def trust_context_ok:
  . as $context |
  exact_fields(
    ["expected_repository_id","expected_change_request_id","expected_attempt_id",
     "expected_attempt_number","expected_idempotency_key_sha256","expected_head",
     "expected_base","expected_head_tree","expected_action",
     "expected_allowed_paths","expected_ci_evidence_ref",
     "expected_review_evidence_ref","expected_decision_record_ref",
     "observation_time","execution_boundary_id","verified_claim"];
    []) and
  (.expected_repository_id | id_ok) and
  (.expected_change_request_id | id_ok) and
  (.expected_attempt_id | id_ok) and
  (.expected_attempt_number | int_ok) and
  .expected_attempt_number >= 1 and .expected_attempt_number <= 1000000 and
  (.expected_idempotency_key_sha256 | sha256_ok) and
  (.expected_head | revision_ok) and (.expected_base | revision_ok) and
  .expected_head.repository_id == .expected_repository_id and
  .expected_base.repository_id == .expected_repository_id and
  .expected_head != .expected_base and
  (.expected_head_tree | root_tree_ok($context.expected_head)) and
  .expected_action == "squash-change-request" and
  (.expected_allowed_paths | allowed_paths_ok) and
  (.expected_ci_evidence_ref | content_ref_ok) and
  (.expected_review_evidence_ref | content_ref_ok) and
  (.expected_decision_record_ref | content_ref_ok) and
  ([.expected_ci_evidence_ref,.expected_review_evidence_ref,
    .expected_decision_record_ref] | unique | length) == 3 and
  (.observation_time | time_ok) and
  (.execution_boundary_id | id_ok) and
  (.verified_claim | verified_claim_ok);

def claim_ok:
  . as $claim |
  exact_fields(
    ["repository_id","change_request_id","attempt_id","attempt_number",
     "idempotency_key_sha256","head","base","head_tree","action","allowed_paths",
     "ci_evidence_ref","review_evidence_ref",
     "decision_record_ref","execution_boundary_id","decision","complete",
     "started_at","terminal_at","observed_at","provider_metadata"];
    []) and
  (.repository_id | id_ok) and (.change_request_id | id_ok) and
  (.attempt_id | id_ok) and (.attempt_number | int_ok) and
  .attempt_number >= 1 and .attempt_number <= 1000000 and
  (.idempotency_key_sha256 | sha256_ok) and
  (.head | revision_ok) and (.base | revision_ok) and
  .head.repository_id == .repository_id and
  .base.repository_id == .repository_id and .head != .base and
  (.head_tree | root_tree_ok($claim.head)) and
  .action == "squash-change-request" and
  (.allowed_paths | allowed_paths_ok) and
  (.ci_evidence_ref | content_ref_ok) and
  (.review_evidence_ref | content_ref_ok) and
  (.decision_record_ref | content_ref_ok) and
  ([.ci_evidence_ref,.review_evidence_ref,.decision_record_ref] |
   unique | length) == 3 and
  (.execution_boundary_id | id_ok) and
  (.decision == "permit" or .decision == "deny" or .decision == "inconclusive") and
  (.complete | type == "boolean") and
  (.started_at | time_ok) and (.observed_at | time_ok) and
  .started_at <= .observed_at and
  (if .complete then
     (.terminal_at | time_ok) and
     .started_at <= .terminal_at and .terminal_at <= .observed_at
   else
     .terminal_at == null and .decision == "inconclusive"
   end) and
  (.provider_metadata | type == "object" and bounded_data(0));

def stale_bindings($context; $claim):
  [
    if $claim.allowed_paths != $context.expected_allowed_paths then "allowed-paths" else empty end,
    if $claim.attempt_id != $context.expected_attempt_id then "attempt-id" else empty end,
    if $claim.attempt_number != $context.expected_attempt_number then "attempt-number" else empty end,
    if $claim.base != $context.expected_base then "base" else empty end,
    if $claim.change_request_id != $context.expected_change_request_id then "change-request" else empty end,
    if $claim.ci_evidence_ref != $context.expected_ci_evidence_ref then "ci-evidence" else empty end,
    if $claim.decision_record_ref != $context.expected_decision_record_ref then "decision-record" else empty end,
    if $claim.execution_boundary_id != $context.execution_boundary_id then "execution-boundary" else empty end,
    if $claim.head != $context.expected_head then "head" else empty end,
    if $claim.head_tree != $context.expected_head_tree then "head-tree" else empty end,
    if $claim.idempotency_key_sha256 != $context.expected_idempotency_key_sha256 then "idempotency-key" else empty end,
    if $claim.observed_at != $context.observation_time then "observation-time" else empty end,
    if $claim.repository_id != $context.expected_repository_id then "repository" else empty end,
    if $claim.review_evidence_ref != $context.expected_review_evidence_ref then "review-evidence" else empty end
  ] | sort;

def normalized_state($claim; $stale):
  if ($stale | length) > 0 then ["stale","publisher.binding-stale"]
  elif $claim.complete == false then ["inconclusive","publisher.claim-incomplete"]
  else ["dormant","publisher.dormant"]
  end;

if (exact_fields(["trust_context","claim"];[]) | not) then
  error("dormant-publisher.invalid-envelope")
elif (.trust_context | trust_context_ok) == false then
  error("dormant-publisher.invalid-trust-context")
elif (.claim | claim_ok) == false then
  error("dormant-publisher.invalid-claim")
elif .claim != .trust_context.verified_claim.content then
  error("dormant-publisher.unverified-claim")
else
  .trust_context as $context |
  .claim as $claim |
  stale_bindings($context;$claim) as $stale |
  normalized_state($claim;$stale) as $normalized |
  {
    schema_version:1,
    kind:"adapter_observation",
    adapter:{id:"adapter.dormant-publisher.v1",version:"v1",status:"inactive"},
    mode:"observation-only",
    reference_semantics:"identity-only",
    state:$normalized[0],
    reason_id:$normalized[1],
    stale_bindings:$stale,
    trust_context:($context | del(.verified_claim) +
      {claim_ref:claim_ref($context.verified_claim)}),
    observation:$claim,
    decision_claim:{trust:"unqualified-input-claim",
      ref:claim_ref($context.verified_claim),value:$claim.decision},
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    capability:{state:"unavailable",reason_id:"publisher.dormant"},
    capabilities:[],
    permissions:[],
    tools:[],
    effects:[]
  }
end
