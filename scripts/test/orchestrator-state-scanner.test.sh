#!/bin/bash
# shellcheck disable=SC2016,SC2329
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
scanner="$root/orchestrator/v1/scan-state.sh"
fixtures="$root/scripts/test"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-state-scanner-test.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_line() {
  builtin printf '%s\n' "$1" | /usr/bin/shasum -a 256 |
    /usr/bin/awk '{print $1}'
}

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:x86_64)
    jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    expected_host_arch=x86_64; expected_execution_mode=native
    ;;
  Darwin:arm64)
    jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    expected_host_arch=arm64; expected_execution_mode=rosetta
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    expected_host_arch=x86_64; expected_execution_mode=native
    ;;
  *) /usr/bin/printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
jq_source=''
for candidate in "${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset" \
  /usr/bin/jq "$(command -v jq)"; do
  if [ -f "$candidate" ] && [ ! -L "$candidate" ] &&
     [ "$(sha_file "$candidate")" = "$jq_sha" ]; then
    jq_source=$candidate
    break
  fi
done
[ -n "$jq_source" ] || {
  /usr/bin/printf '%s\n' 'FAIL: verified architecture-bound jq 1.6 required' >&2
  exit 1
}
case "$platform" in
  Darwin:*) /usr/bin/file "$jq_source" | /usr/bin/grep -Fq x86_64 ;;
  Linux:x86_64) /usr/bin/file "$jq_source" | /usr/bin/grep -Eq 'x86-64|x86_64' ;;
esac
/bin/mkdir -m 700 "$tmp/bin"
/bin/cp "$jq_source" "$tmp/bin/jq"
/bin/chmod 0555 "$tmp/bin/jq"
export PATH="$tmp/bin:/usr/bin:/bin"
jq_bin="$tmp/bin/jq"
[ "$($jq_bin --version)" = jq-1.6 ] || {
  /usr/bin/printf '%s\n' 'FAIL: jq identity' >&2
  exit 1
}

passed=0
failed=0
pass() { passed=$((passed + 1)); }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

expect_class() {
  local name=$1 snapshot=$2 commit=$3 class=$4 action=$5 reason=$6
  local output snapshot_sha item_content item_sha
  snapshot_sha=$(sha_file "$snapshot")
  item_content=$("$jq_bin" -S -c '.body.items[0]' "$snapshot")
  item_sha=$(sha_line "$item_content")
  if ! output=$("$scanner" scan repo.example "$commit" "$snapshot" 2>"$tmp/$name.err"); then
    fail "$name returned $(<"$tmp/$name.err")"
    return
  fi
  if /usr/bin/printf '%s\n' "$output" | "$jq_bin" -e -S -c \
    --arg class "$class" --arg action "$action" --arg reason "$reason" \
    --arg snapshot_sha "$snapshot_sha" --arg item_sha "$item_sha" \
    --arg host_arch "$expected_host_arch" \
    --arg execution_mode "$expected_execution_mode" --slurpfile snapshot "$snapshot" '
      .schema_version == 1 and .kind == "orchestrator_state_observation" and
      (.body | keys) == ["activation_state","authority_effect","classifications",
        "core_contract","evaluator","mode","observed_at","snapshot_ref",
        "source_revision"] and
      .body.activation_state == "inactive" and
      .body.authority_effect == "none" and .body.mode == "observation-only" and
      .body.snapshot_ref == {schema_identity:"orchestrator.state-snapshot.v1",
        kind:"orchestrator_state_snapshot",id:$snapshot[0].id,sha256:$snapshot_sha} and
      .body.evaluator.sha256 ==
        .body.classifications[0].provenance.evaluator_ref.sha256 and
      (.body.evaluator.content.body.bootstrap_ref.sha256 |
        test("^[0-9a-f]{64}$")) and
      .body.evaluator.content.body.program_ref.sha256 ==
        "722afbf8a20ecf6f1d61b045186dc97b22fea1457f167ec87ac5b31b317e34ae" and
      .body.evaluator.content.body.driver_ref.sha256 ==
        "5972a0a6ab7858815963717995d3d09561e76e2b7412ad1887252d83ad0db19b" and
      .body.evaluator.content.body.runtime.host_architecture == $host_arch and
      .body.evaluator.content.body.runtime.execution_mode == $execution_mode and
      (.body.evaluator.content.body.core_closure | length) == 9 and
      (.body.classifications | length) == 1 and
      (.body.classifications[0] | keys) == ["class","provenance","recovery","stage_key"] and
      (.body.classifications[0].provenance | keys) == ["active_attempt","evaluator_ref",
        "item_ref","latest_result_ref","request_ref","resolved_profile_ref","snapshot_ref"] and
      (.body.classifications[0].recovery | keys) == ["action","attempt_number",
        "reason_id","retry_limit","source_reason"] and
      .body.classifications[0].provenance.snapshot_ref == .body.snapshot_ref and
      .body.classifications[0].provenance.item_ref ==
        {schema_identity:"orchestrator.state-item.v1",sha256:$item_sha} and
      .body.classifications[0].provenance.request_ref.sha256 ==
        $snapshot[0].body.items[0].request.sha256 and
      .body.classifications[0].provenance.resolved_profile_ref.sha256 ==
        $snapshot[0].body.items[0].resolved_profile.sha256 and
      .body.classifications[0].provenance.active_attempt ==
        $snapshot[0].body.items[0].attempt and
      .body.classifications[0].provenance.latest_result_ref ==
        (if $snapshot[0].body.items[0].latest_result.state == "present" then
           {state:"present",value:{schema_version:2,kind:"stage_result",
             id:$snapshot[0].body.items[0].latest_result.value.content.id,
             sha256:$snapshot[0].body.items[0].latest_result.value.sha256}}
         else {state:"absent"} end) and
      .body.classifications[0].class == $class and
      .body.classifications[0].recovery.action == $action and
      .body.classifications[0].recovery.reason_id == $reason
    ' >/dev/null &&
    [ "$output" = "$(/usr/bin/printf '%s\n' "$output" | "$jq_bin" -S -c .)" ]; then
    pass
  else
    fail "$name produced the wrong observation"
  fi
}

expect_error() {
  local name=$1 expected=$2 snapshot=$3 commit=${4:-1111111111111111111111111111111111111111}
  local output status
  set +e
  output=$("$scanner" scan repo.example "$commit" "$snapshot" 2>"$tmp/$name.err")
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ -z "$output" ] &&
     [ "$(<"$tmp/$name.err")" = "$expected" ]; then
    pass
  else
    fail "$name expected $expected"
  fi
}

resolved="$tmp/resolved.json"
"$jq_bin" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  def forge_binding($shas): {
    binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$shas.forge},
    execution_kind:"deterministic",adapter_instance_id:"instance.forge",
    principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
    authority_ref:profile::scope("authority";"authority-forge";("5"*64)),
    package_ref:profile::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]
  };
  {forge:("0"*64),producer:("a"*64),publisher:("b"*64),
   reviewer:("c"*64),verifier:("d"*64)} as $shas |
  (profile::profile_doc($shas) | v2 |
   .body.profile_version="v2" |
   .body.bindings += [forge_binding($shas)] |
   .body.bindings |= sort_by(.binding_id)) as $profile |
  profile::resolved_profile_doc($profile;("e"*64);$shas) | v2 |
  .body.bindings |= map(
    if .binding.role == "forge" then
      .adapter_implementation.version="v2" |
      .manifest_source=profile::source_value(
        profile::blob("manifests/forge.json";"a");"canonical-json";$shas.forge)
    else . end)
' >"$resolved"
resolved_sha=$(sha_file "$resolved")

request="$tmp/request.json"
"$jq_bin" -L "$fixtures" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-stage-request-fixtures" as request;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  request::request_doc("producer";$resolved_sha) | v2
' >"$request"
request_sha=$(sha_file "$request")

for flavor in completed skipped stale blocked failed cancelled; do
  result_file="$tmp/result-$flavor.json"
  "$jq_bin" -L "$fixtures" -S -c -n \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    --arg flavor "$flavor" '
      import "portable-core-result-truth-fixtures" as result;
      def v2: walk(if type == "object" and has("schema_version")
                   then .schema_version=2 else . end);
      (if $flavor == "completed" then
         result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       elif $flavor == "skipped" then
         result::skipped_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       elif $flavor == "stale" then
         result::stale_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       elif $flavor == "blocked" then
         result::blocked_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       elif $flavor == "failed" then
         result::failed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       else result::cancelled_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)
       end) | v2
    ' >"$result_file"
done

make_snapshot() {
  local destination=$1 result_path=$2 attempt_state=$3 deadline=$4 retry_limit=$5 commit=$6
  local result_args=(--slurpfile result /dev/null)
  if [ "$result_path" != absent ]; then result_args=(--slurpfile result "$result_path"); fi
  "$jq_bin" -S -c -n --slurpfile request "$request" --slurpfile resolved "$resolved" \
    "${result_args[@]}" --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
    --arg attempt_state "$attempt_state" --arg deadline "$deadline" \
    --argjson retry_limit "$retry_limit" --arg commit "$commit" '
      def pair($docs;$sha): {content:$docs[0],sha256:$sha};
      def doc_ref($pair):
        {schema_version:2,kind:$pair.content.kind,id:$pair.content.id,sha256:$pair.sha256};
      (pair($request;$request_sha)) as $request_pair |
      (pair($resolved;$resolved_sha)) as $resolved_pair |
      {
        schema_version:1,
        kind:"orchestrator_state_snapshot",
        id:"snapshot.example",
        body:{
          core_contract:{
            generation_id_sha256:"84a153ba1d60f1763d5424c872256fc3337209678f4105cb0802958798bd19f5",
            package_ref:{content_id:"core-contract-package.v2",
              media_type:"application/vnd.ystack.core-contract+json",
              sha256:"eff044bdd6de0de71d5f8c5a58d889a122cd9efdf717b9f68713b47842fb0963"},
            semantic_identity:"core.contracts.v2"
          },
          items:[{
            attempt:(if $attempt_state == "absent" then {state:"absent"} else
              {state:"present",value:{attempt_id:"attempt.pending",attempt_number:1,
               deadline_at:$deadline,request_ref:doc_ref($request_pair),state:$attempt_state}} end),
            latest_result:(if ($result | length) == 1 then
              {state:"present",value:pair($result;("0"*64))}
              else {state:"absent"} end),
            request:$request_pair,
            resolved_profile:$resolved_pair,
            retry_limit:$retry_limit
          }],
          observed_at:"2026-08-30T00:10:00Z",
          snapshot_contract:{completeness:"complete",declared_item_count:1,
            maximum_item_count:64,schema_identity:"orchestrator.state-snapshot.v1"},
          source_revision:{repository_id:"repo.example",hash_algorithm:"sha1",commit_id:$commit}
        }
      }
    ' >"$destination"
  if [ "$result_path" != absent ]; then
    local result_sha
    result_sha=$(sha_file "$result_path")
    "$jq_bin" -S -c --arg sha "$result_sha" \
      '.body.items[0].latest_result.value.sha256=$sha' "$destination" >"$destination.next"
    /bin/mv "$destination.next" "$destination"
  fi
}

commit_one=1111111111111111111111111111111111111111
commit_two=2222222222222222222222222222222222222222
pending="$tmp/pending.json"
make_snapshot "$pending" absent absent 2026-08-30T00:20:00Z 2 "$commit_one"
expect_class pending "$pending" "$commit_one" pending dispatch-stage scanner.no-attempt
baseline_output=$("$scanner" scan repo.example "$commit_one" "$pending")

hash_helpers_builtin=true
for hash_script in \
  "$root/orchestrator/v1/state-scanner-driver.sh" \
  "$root/orchestrator/v1/state-scanner-launcher.sh"; do
  hash_body=$(/usr/bin/sed -n '/^sha256_line() {$/,/^}$/p' "$hash_script")
  if [[ "$hash_body" != *"builtin printf '%s\n' \"\$1\""* ]] ||
     [[ "$hash_body" == *'/usr/bin/printf'* ]]; then
    hash_helpers_builtin=false
  fi
done
if [ "$hash_helpers_builtin" = true ]; then
  pass
else
  fail 'document hashing must stream through builtin printf'
fi

large_request="$tmp/request-large.json"
"$jq_bin" -S -c '
  def digest($n): (("0" * 64) + ($n | tostring))[-64:];
  def long_id($prefix;$n):
    ($n | tostring) as $suffix |
    $prefix + ("x" * (128 - ($prefix | length) - ($suffix | length))) + $suffix;
  def media_type: "application/" + ("x" * 115);
  def content($prefix;$n):
    {content_id:long_id($prefix;$n),media_type:media_type,sha256:digest($n)};
  def gate($n): {
    purpose:"gate-requirement",
    decision_record_ref:content("decision.";$n),
    subject_ref:{
      type:"artifact",
      value:{type:"content",value:content("subject.";$n)}
    },
    scope_sha256:digest($n)
  };
  def evidence($n): {
    stage_result_ref:{
      schema_version:2,
      kind:"stage_result",
      id:long_id("result.";$n),
      sha256:digest($n)
    },
    evidence_id:long_id("evidence.";$n)
  };
  .body.risk.required_gate_refs=[range(0;256) | gate(.)] |
  .body.prior_evidence_refs=[range(0;256) | evidence(.)]
' "$request" >"$large_request"
large_request_sha=$(sha_file "$large_request")
large_snapshot="$tmp/snapshot-large.json"
"$jq_bin" -S -c --slurpfile request "$large_request" \
  --arg request_sha "$large_request_sha" '
    .body.items[0].request={content:$request[0],sha256:$request_sha}
  ' "$pending" >"$large_snapshot"
large_request_size=$(/usr/bin/wc -c <"$large_request" | /usr/bin/tr -d ' ')
large_snapshot_size=$(/usr/bin/wc -c <"$large_snapshot" | /usr/bin/tr -d ' ')
if [ "$large_request_size" -gt 131072 ] &&
   [ "$large_snapshot_size" -gt "$large_request_size" ] &&
   [ "$large_snapshot_size" -le 1048576 ]; then
  expect_class large-valid-request "$large_snapshot" "$commit_one" \
    pending dispatch-stage scanner.no-attempt
else
  fail 'large valid request did not cross the per-argument threshold'
fi

malicious_path="$tmp/malicious-path"
/bin/mkdir "$malicious_path"
{
  /usr/bin/printf '%s\n' '#!/bin/bash'
  /usr/bin/printf ': > "%s"\n' "$tmp/path-jq-ran"
  /usr/bin/printf '%s\n' 'exit 0'
} >"$malicious_path/jq"
/bin/chmod 0500 "$malicious_path/jq"
path_output=$(PATH="$malicious_path:/usr/bin:/bin" \
  "$scanner" scan repo.example "$commit_one" "$pending")
if [ "$path_output" = "$baseline_output" ] && [ ! -e "$tmp/path-jq-ran" ]; then
  pass
else
  fail 'writable PATH runtime is ignored'
fi

poison_dir="$tmp/perl-poison"
/bin/mkdir "$poison_dir"
{
  /usr/bin/printf '%s\n' 'package ScannerPoison;'
  /usr/bin/printf 'BEGIN { open(my $fh, ">", "%s") or die; print {$fh} "ran\\n"; close($fh) or die; }\n' \
    "$tmp/perl-poison-ran"
  /usr/bin/printf '%s\n' '1;'
} >"$poison_dir/ScannerPoison.pm"
compgen() { /usr/bin/printf '%s\n' LC_ALL PATH PWD SHLVL TMPDIR; }
export -f compgen
poison_output=$(PERL5LIB="$poison_dir" PERL5OPT=-MScannerPoison \
  "$scanner" scan repo.example "$commit_one" "$pending" 2>"$tmp/perl-poison.err")
unset -f compgen
if [ "$poison_output" = "$baseline_output" ] && [ ! -s "$tmp/perl-poison.err" ] &&
   [ ! -e "$tmp/perl-poison-ran" ]; then
  pass
else
  fail 'ambient Perl options are removed before snapshotting'
fi

set +e
"$scanner" scan repo.example "$commit_one" "$pending" \
  >&- 2>"$tmp/closed-output.err"
closed_output_status=$?
set -e
if [ "$closed_output_status" -ne 0 ] &&
   [ "$(<"$tmp/closed-output.err")" = E_RUNTIME ]; then
  pass
else
  fail 'failed output delivery cannot return success'
fi

empty="$tmp/empty.json"
"$jq_bin" -S -c '
  .id="snapshot.empty" | .body.items=[] |
  .body.snapshot_contract.declared_item_count=0
' "$pending" >"$empty"
if empty_output=$("$scanner" scan repo.example "$commit_one" "$empty") &&
   /usr/bin/printf '%s\n' "$empty_output" | "$jq_bin" -e \
     --arg sha "$(sha_file "$empty")" '
       .id == "snapshot.empty" and .body.classifications == [] and
       .body.snapshot_ref.sha256 == $sha and
       .body.evaluator.content.kind == "orchestrator_state_scanner_evaluator"
     ' >/dev/null; then
  pass
else
  fail 'empty complete snapshot'
fi

inflight="$tmp/inflight.json"
make_snapshot "$inflight" absent started 2026-08-30T00:20:00Z 2 "$commit_one"
expect_class in-flight "$inflight" "$commit_one" pending wait-for-attempt scanner.attempt-in-flight

stranded="$tmp/stranded.json"
make_snapshot "$stranded" absent dispatched 2026-08-30T00:10:00Z 2 "$commit_one"
expect_class stranded "$stranded" "$commit_one" stranded recover-stranded-attempt scanner.attempt-deadline-reached

for spec in \
  'completed terminal none scanner.stage-completed 2' \
  'skipped terminal none scanner.stage-skipped 2' \
  'stale stale refresh-stage-inputs scanner.stage-stale 2' \
  'blocked blocked resolve-stage-blocker scanner.stage-blocked 2' \
  'failed retryable retry-stage scanner.stage-failed 2' \
  'cancelled terminal none scanner.stage-cancelled 2' \
  'failed blocked operator-reconcile scanner.retry-limit-reached 1'; do
  read -r flavor expected_class action reason retry_limit <<<"$spec"
  snapshot="$tmp/$flavor-$retry_limit.json"
  make_snapshot "$snapshot" "$tmp/result-$flavor.json" absent \
    2026-08-30T00:20:00Z "$retry_limit" "$commit_one"
  expect_class "$flavor-$expected_class-$retry_limit" "$snapshot" "$commit_one" \
    "$expected_class" "$action" "$reason"
done

moved="$tmp/moved.json"
make_snapshot "$moved" absent absent 2026-08-30T00:20:00Z 2 "$commit_two"
expect_class moved-request "$moved" "$commit_two" stale refresh-stage-inputs scanner.target-revision-moved

completed_moved="$tmp/completed-moved.json"
make_snapshot "$completed_moved" "$tmp/result-completed.json" absent \
  2026-08-30T00:20:00Z 2 "$commit_two"
expect_class immutable-terminal "$completed_moved" "$commit_two" terminal none scanner.stage-completed

cancelled_moved="$tmp/cancelled-moved.json"
make_snapshot "$cancelled_moved" "$tmp/result-cancelled.json" absent \
  2026-08-30T00:20:00Z 2 "$commit_two"
expect_class immutable-cancellation "$cancelled_moved" "$commit_two" terminal none scanner.stage-cancelled

other_pending="$tmp/pending-other.json"
"$jq_bin" -S -c \
  '.body.items[0].request.content.body.requested_by.principal_id="principal.other"' \
  "$pending" >"$other_pending.raw"
other_content=$("$jq_bin" -S -c '.body.items[0].request.content' "$other_pending.raw")
other_request_sha=$(sha_line "$other_content")
"$jq_bin" -S -c --arg sha "$other_request_sha" \
  '.body.items[0].request.sha256=$sha' "$other_pending.raw" >"$other_pending"
other_output=$("$scanner" scan repo.example "$commit_one" "$other_pending")
if [ "$baseline_output" != "$other_output" ] &&
   [ "$(/usr/bin/printf '%s\n' "$other_output" | "$jq_bin" -r \
       '.body.classifications[0].provenance.request_ref.sha256')" = "$other_request_sha" ] &&
   [ "$(/usr/bin/printf '%s\n' "$other_output" | "$jq_bin" -r \
       '.body.snapshot_ref.sha256')" = "$(sha_file "$other_pending")" ]; then
  pass
else
  fail 'distinct snapshots retain distinct provenance'
fi

bad_core="$tmp/bad-core.json"
"$jq_bin" -S -c '.body.core_contract.semantic_identity="core.contracts.v9"' \
  "$pending" >"$bad_core"
expect_error stale-core E_STALE "$bad_core"
expect_error stale-snapshot E_STALE "$pending" "$commit_two"

truncated="$tmp/truncated.json"
"$jq_bin" -S -c '.body.snapshot_contract.declared_item_count=0' \
  "$pending" >"$truncated"
expect_error incomplete-count E_SHAPE "$truncated"
partial="$tmp/partial.json"
"$jq_bin" -S -c '.body.snapshot_contract.completeness="partial"' \
  "$pending" >"$partial"
expect_error partial-page E_SHAPE "$partial"
paged="$tmp/paged.json"
"$jq_bin" -S -c '.body.snapshot_contract.page_cursor="next"' "$pending" >"$paged"
expect_error ambiguous-page-field E_SHAPE "$paged"

bad_sha="$tmp/bad-sha.json"
"$jq_bin" -S -c '.body.items[0].request.sha256=("0"*64)' "$pending" >"$bad_sha"
expect_error content-ref-hash E_RELATION "$bad_sha"

ambiguous="$tmp/ambiguous.json"
"$jq_bin" -S -c --slurpfile attempt "$inflight" \
  '.body.items[0].attempt=$attempt[0].body.items[0].attempt' \
  "$tmp/completed-2.json" >"$ambiguous"
expect_error ambiguous-current-and-terminal E_RELATION "$ambiguous"

time_travel="$tmp/time-travel.json"
"$jq_bin" -S -c '.body.observed_at="2026-08-29T23:59:59Z"' "$pending" >"$time_travel"
expect_error observation-before-request E_RELATION "$time_travel"

duplicate="$tmp/duplicate.json"
"$jq_bin" -S -c '
  .body.items += [.body.items[0]] |
  .body.snapshot_contract.declared_item_count=2
' "$pending" >"$duplicate"
expect_error duplicate-stage E_RELATION "$duplicate"

unordered="$tmp/unordered.json"
"$jq_bin" -S -c '
  .body.items=[(.body.items[0] | .request.content.body.stage_id="stage.z"),
               (.body.items[0] | .request.content.body.stage_id="stage.a")] |
  .body.snapshot_contract.declared_item_count=2
' "$pending" >"$unordered.raw"
for index in 0 1; do
  content=$("$jq_bin" -S -c ".body.items[$index].request.content" "$unordered.raw")
  digest=$(sha_line "$content")
  "$jq_bin" -S -c --argjson index "$index" --arg digest "$digest" \
    '.body.items[$index].request.sha256=$digest' "$unordered.raw" >"$unordered.next"
  /bin/mv "$unordered.next" "$unordered.raw"
done
/bin/mv "$unordered.raw" "$unordered"
expect_error unordered-stage E_RELATION "$unordered"

too_many="$tmp/too-many.json"
"$jq_bin" -S -c '
  .body.items=[range(0;65) as $n | {}] |
  .body.snapshot_contract.declared_item_count=65
' \
  "$pending" >"$too_many"
expect_error item-bound E_SHAPE "$too_many"
oversize="$tmp/oversize.json"
/bin/dd if=/dev/zero of="$oversize" bs=1048577 count=1 2>/dev/null
expect_error byte-bound E_LIMIT "$oversize"

pretty="$tmp/pretty.json"
"$jq_bin" . "$pending" >"$pretty"
expect_error noncanonical E_CANONICAL "$pretty"
duplicate_key="$tmp/duplicate-key.json"
{
  /usr/bin/printf '%s' '{"body":null,'
  /usr/bin/printf '%s' "$(<"$pending")" | /usr/bin/cut -c2-
} >"$duplicate_key"
expect_error duplicate-key E_CANONICAL "$duplicate_key"

link="$tmp/input-link.json"
/bin/ln -s "$pending" "$link"
expect_error symlink-input E_RUNTIME "$link"

copy_root="$tmp/scanner-copy"
copy_modules="$copy_root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules"
/bin/mkdir -p "$copy_root/orchestrator/v1" "$copy_modules" "$copy_root/scripts"
/bin/cp "$root/orchestrator/v1/scan-state.sh" \
  "$root/orchestrator/v1/state-scanner-launcher.sh" \
  "$root/orchestrator/v1/state-scanner-driver.sh" \
  "$root/orchestrator/v1/state-scanner.jq" "$copy_root/orchestrator/v1/"
/bin/cp "$root/core/v2/generation-registry.json" "$copy_root/core/v2/"
/bin/cp "$root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/contracts.jq" \
  "$root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/core-ingress.sh" \
  "$copy_root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/"
/bin/cp "$root/core/v2/generations/g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43/modules/"*.jq \
  "$copy_modules/"
/bin/cp "$root/scripts/core-contract.sh" "$copy_root/scripts/"
/bin/chmod 0500 "$copy_root/orchestrator/v1/scan-state.sh"
copy_scanner="$copy_root/orchestrator/v1/scan-state.sh"
race_tmp="$tmp/race-tmp"
/bin/mkdir -p "$race_tmp/ystack-portable-core-jq16"
/bin/cp "$jq_source" "$race_tmp/ystack-portable-core-jq16/$jq_asset"
/bin/chmod 0500 "$race_tmp/ystack-portable-core-jq16/$jq_asset"

program_copy="$copy_root/orchestrator/v1/state-scanner.jq"
/bin/cp "$program_copy" "$tmp/program-saved"
/usr/bin/printf '\n' >>"$program_copy"
set +e
tampered_output=$(TMPDIR="$race_tmp" "$copy_scanner" scan \
  repo.example "$commit_one" "$pending" 2>"$tmp/tampered-program.err")
tampered_status=$?
set -e
if [ "$tampered_status" -ne 0 ] && [ -z "$tampered_output" ] &&
   [ "$(<"$tmp/tampered-program.err")" = E_STALE ]; then
  pass
else
  fail 'same-inode program mutation fails closed'
fi
/bin/cp "$tmp/program-saved" "$program_copy"

/bin/mv "$program_copy" "$tmp/program-real"
/bin/ln -s "$tmp/program-real" "$program_copy"
set +e
symlink_output=$(TMPDIR="$race_tmp" "$copy_scanner" scan \
  repo.example "$commit_one" "$pending" 2>"$tmp/symlink-program.err")
symlink_status=$?
set -e
if [ "$symlink_status" -ne 0 ] && [ -z "$symlink_output" ] &&
   [ "$(<"$tmp/symlink-program.err")" = E_STALE ]; then
  pass
else
  fail 'swapped program symlink fails closed'
fi
/bin/rm "$program_copy"
/bin/mv "$tmp/program-real" "$program_copy"

race_cache="$race_tmp/ystack-portable-core-jq16/$jq_asset"
/bin/cp "$program_copy" "$tmp/program-race-saved"
/bin/cp "$race_cache" "$tmp/jq-race-saved"
TMPDIR="$race_tmp" "$copy_scanner" scan repo.example "$commit_one" "$pending" \
  >"$tmp/race-output" 2>"$tmp/race-error" &
race_pid=$!
runtime_ready=''
for _ in {1..200}; do
  for candidate in "$race_tmp"/ystack-state-scan.*/runtime; do
    if [ -f "$candidate/program.jq" ] && [ -f "$candidate/jq" ]; then
      runtime_ready=$candidate
      break 2
    fi
  done
  /bin/sleep 0.01
done
if [ -n "$runtime_ready" ] && kill -0 "$race_pid" 2>/dev/null; then
  /usr/bin/printf '\n' >>"$program_copy"
  /bin/chmod 0700 "$race_cache"
  /usr/bin/printf '\000' >>"$race_cache"
  program_size=$(/usr/bin/wc -c <"$tmp/program-race-saved" | /usr/bin/tr -d ' ')
  jq_size=$(/usr/bin/wc -c <"$tmp/jq-race-saved" | /usr/bin/tr -d ' ')
  /bin/dd if="$tmp/program-race-saved" of="$program_copy" bs=65536 conv=notrunc 2>/dev/null
  /usr/bin/truncate -s "$program_size" "$program_copy"
  /bin/dd if="$tmp/jq-race-saved" of="$race_cache" bs=65536 conv=notrunc 2>/dev/null
  /usr/bin/truncate -s "$jq_size" "$race_cache"
  /bin/chmod 0500 "$race_cache"
else
  fail 'private runtime was not observable before completion'
fi
set +e
wait "$race_pid"
race_status=$?
set -e
if [ "$race_status" -eq 0 ] && [ ! -s "$tmp/race-error" ] &&
   [ "$(<"$tmp/race-output")" = "$baseline_output" ]; then
  pass
else
  fail 'private snapshot survives source swap-restore'
fi

if [ "$failed" -ne 0 ]; then
  /usr/bin/printf 'orchestrator state scanner: %s passed, %s failed\n' "$passed" "$failed" >&2
  exit 1
fi
/usr/bin/printf 'orchestrator state scanner: %s/%s checks passed\n' "$passed" "$passed"
