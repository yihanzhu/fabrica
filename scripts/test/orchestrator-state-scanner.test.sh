#!/bin/bash
# shellcheck disable=SC2016
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
  /usr/bin/printf '%s\n' "$1" | /usr/bin/shasum -a 256 |
  /usr/bin/awk '{print $1}'
}

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) /usr/bin/printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
system_jq=$(command -v jq)
jq_source=$system_jq
if [ "$($system_jq --version 2>/dev/null)" != jq-1.6 ]; then
  jq_source="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
  [ -f "$jq_source" ] && [ "$(sha_file "$jq_source")" = "$jq_sha" ] || {
    /usr/bin/printf '%s\n' 'FAIL: verified jq 1.6 required' >&2
    exit 1
  }
fi
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
  local name=$1 snapshot=$2 commit=$3 class=$4 action=$5 reason=$6 output
  if ! output=$("$scanner" scan repo.example "$commit" "$snapshot" 2>"$tmp/$name.err"); then
    fail "$name returned $(<"$tmp/$name.err")"
    return
  fi
  if /usr/bin/printf '%s\n' "$output" | "$jq_bin" -e -S -c \
    --arg class "$class" --arg action "$action" --arg reason "$reason" '
      .schema_version == 1 and .kind == "orchestrator_state_observation" and
      .body.activation_state == "inactive" and
      .body.authority_effect == "none" and .body.mode == "observation-only" and
      (.body.classifications | length) == 1 and
      .body.classifications[0].class == $class and
      .body.classifications[0].recovery.action == $action and
      .body.classifications[0].recovery.reason_id == $reason and
      ((tojson | test("grant|approval|qualification|publish|schedule|wake")) | not)
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
            generation_id_sha256:"6f6acbbd0cf40ab3c913328d6c0070635424ffe920bcdb900fbd0718345d7137",
            package_ref:{content_id:"core-contract-package.v2",
              media_type:"application/vnd.ystack.core-contract+json",
              sha256:"005431c5c7e3a39dc3ab75dfcafd0f09359331667fdcacb140514a4384592716"},
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
  'cancelled retryable retry-stage scanner.stage-cancelled 2' \
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

bad_core="$tmp/bad-core.json"
"$jq_bin" -S -c '.body.core_contract.semantic_identity="core.contracts.v9"' \
  "$pending" >"$bad_core"
expect_error stale-core E_STALE "$bad_core"
expect_error stale-snapshot E_STALE "$pending" "$commit_two"

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
"$jq_bin" -S -c '.body.items += [.body.items[0]]' "$pending" >"$duplicate"
expect_error duplicate-stage E_RELATION "$duplicate"

unordered="$tmp/unordered.json"
"$jq_bin" -S -c '
  .body.items=[(.body.items[0] | .request.content.body.stage_id="stage.z"),
               (.body.items[0] | .request.content.body.stage_id="stage.a")]
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
"$jq_bin" -S -c '.body.items=[range(0;65) as $n | {}]' \
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

if [ "$failed" -ne 0 ]; then
  /usr/bin/printf 'orchestrator state scanner: %s passed, %s failed\n' "$passed" "$failed" >&2
  exit 1
fi
/usr/bin/printf 'orchestrator state scanner: %s/%s checks passed\n' "$passed" "$passed"
