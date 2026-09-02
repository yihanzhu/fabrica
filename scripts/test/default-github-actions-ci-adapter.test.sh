#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
normalizer="$root/adapters/github-actions-ci/v1/normalize.jq"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-github-actions-ci.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

platform="$(uname -s):$(uname -m)"
case "$platform" in
  Linux:x86_64)
    asset=jq-linux64
    asset_sha256=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  Darwin:x86_64|Darwin:arm64)
    asset=jq-osx-amd64
    asset_sha256=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  *) printf 'FAIL: unsupported jq 1.6 proof platform: %s\n' "$platform" >&2; exit 1 ;;
esac

candidate="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
if [ -f "$candidate" ] && [ "$(sha256_path "$candidate")" = "$asset_sha256" ]; then
  jq_command=("$candidate")
  [ "$platform" != Darwin:arm64 ] || jq_command=(/usr/bin/arch -x86_64 "$candidate")
elif candidate="$(command -v jq 2>/dev/null)" &&
     [ "$("$candidate" --version 2>/dev/null)" = jq-1.6 ]; then
  jq_command=("$candidate")
else
  echo 'FAIL: verified jq 1.6 is required' >&2
  exit 1
fi
[ "$("${jq_command[@]}" --version)" = jq-1.6 ] || {
  echo 'FAIL: jq 1.6 identity' >&2
  exit 1
}

total=0
pass() { total=$((total + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
run() { "${jq_command[@]}" -S -c -f "$normalizer" "$1"; }
mutate() { "${jq_command[@]}" -S -c "$2" "$root_input" >"$1"; }

expect_state() {
  local name=$1 state=$2 filter=$3
  local input="$tmp/$name.json" output="$tmp/$name.out"
  mutate "$input" "$filter"
  if ! run "$input" >"$output" 2>"$tmp/$name.err"; then
    cat "$tmp/$name.err" >&2
    fail "$name rejected"
  fi
  [ ! -s "$tmp/$name.err" ] || fail "$name stderr"
  "${jq_command[@]}" -e --arg state "$state" '.state == $state and .result.state == $state' \
    "$output" >/dev/null || fail "$name state"
  pass
}

expect_stale() {
  local name=$1 binding=$2 filter=$3
  local input="$tmp/$name.json" output="$tmp/$name.out"
  mutate "$input" "$filter"
  if ! run "$input" >"$output" 2>"$tmp/$name.err"; then
    cat "$tmp/$name.err" >&2
    fail "$name rejected"
  fi
  "${jq_command[@]}" -e --arg binding "$binding" \
    '.state == "stale" and .stale_bindings == [$binding]' "$output" >/dev/null ||
    fail "$name stale binding"
  pass
}

expect_reject() {
  local name=$1 filter=$2
  local input="$tmp/$name.json"
  mutate "$input" "$filter"
  [ -s "$input" ] || fail "$name mutation"
  if run "$input" >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    cat "$tmp/$name.out" >&2
    cat "$tmp/$name.err" >&2
    fail "$name accepted"
  fi
  [ ! -s "$tmp/$name.out" ] && [ -s "$tmp/$name.err" ] || fail "$name channel"
  pass
}

root_input="$tmp/base.json"
"${jq_command[@]}" -S -c -n '
  def rev($digit):
    {repository_id:"repo.target",hash_algorithm:"sha1",commit_id:($digit * 40)};
  def ref($id;$digit):
    {content_id:$id,media_type:"application/json",sha256:($digit * 64)};
  def identity($job;$check): {job_id:$job,check_run_id:$check};
  def data($name): {name:$name,text:null,details_url:"https://example.invalid/detail"};
  {
    trust_context:{
      expected_repository_id:"1270665750",expected_check_suite_id:"300",
      expected_workflow_id:"400",expected_run_id:"500",expected_run_attempt:2,
      expected_github_app_id:"15368",
      expected_head:rev("1"),expected_base:rev("2"),
      expected_jobs:[identity("10";"100"),identity("20";"200")],
      observation_time:"2026-09-02T10:05:00Z",
      instruction_ref:ref("ci.instructions";"a"),config_ref:ref("ci.config";"b"),
      execution_boundary_id:"boundary.ci.default"
    },
    snapshot:{
      repository_id:"1270665750",check_suite_id:"300",workflow_id:"400",run_id:"500",
      run_attempt:2,github_app_id:"15368",head:rev("1"),base:rev("2"),
      observed_at:"2026-09-02T10:05:00Z",complete:true,
      reported_job_count:2,hidden_job_count:0,status:"completed",conclusion:"success",
      created_at:"2026-09-02T10:00:00Z",updated_at:"2026-09-02T10:04:00Z",
      started_at:"2026-09-02T10:01:00Z",completed_at:"2026-09-02T10:04:00Z",
      jobs:[
        identity("10";"100") + {status:"completed",conclusion:"success",
          created_at:"2026-09-02T10:00:30Z",started_at:"2026-09-02T10:01:00Z",
          completed_at:"2026-09-02T10:02:00Z",
          payload_sha256:("c"*64),provider_data:data("build")},
        identity("20";"200") + {status:"completed",conclusion:"skipped",
          created_at:"2026-09-02T10:01:30Z",started_at:"2026-09-02T10:02:00Z",
          completed_at:"2026-09-02T10:03:00Z",
          payload_sha256:("d"*64),provider_data:data("optional")}
      ],
      payload_sha256:("e"*64),provider_data:data("workflow")
    }
  }
' >"$root_input"

for spec in \
  'passed|passed|.' \
  'queued|queued|.snapshot.status="queued"|.snapshot.conclusion=null|.snapshot.started_at=null|.snapshot.completed_at=null|.snapshot.jobs|=map(.status="queued"|.conclusion=null|.started_at=null|.completed_at=null)' \
  'in-progress|in-progress|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null|.snapshot.jobs[0].status="in_progress"|.snapshot.jobs[0].conclusion=null|.snapshot.jobs[0].completed_at=null|.snapshot.jobs[1].status="queued"|.snapshot.jobs[1].conclusion=null|.snapshot.jobs[1].started_at=null|.snapshot.jobs[1].completed_at=null' \
  'failed-all-completed-mixed|failed|.snapshot.conclusion="failure"|.snapshot.jobs[0].conclusion="failure"' \
  'cancelled-all-completed-mixed|cancelled|.snapshot.conclusion="cancelled"|.snapshot.jobs[0].conclusion="cancelled"' \
  'timed-out-all-completed-mixed|timed-out|.snapshot.conclusion="timed_out"|.snapshot.jobs[0].conclusion="timed_out"' \
  'action-required-all-completed-mixed|action-required|.snapshot.conclusion="action_required"|.snapshot.jobs[0].conclusion="action_required"' \
  'provider-stale-all-completed-mixed|stale|.snapshot.conclusion="stale"|.snapshot.jobs[0].conclusion="stale"' \
  'neutral-all-completed-mixed|inconclusive|.snapshot.conclusion="neutral"|.snapshot.jobs[0].conclusion="neutral"' \
  'job-start-boundary|passed|.snapshot.started_at="2026-09-02T10:00:40Z"|.snapshot.jobs[0].started_at=.snapshot.started_at' \
  'attempt-min|passed|.trust_context.expected_run_attempt=1|.snapshot.run_attempt=1' \
  'attempt-max|passed|.trust_context.expected_run_attempt=1000000|.snapshot.run_attempt=1000000' \
  'media-type-127|passed|.trust_context.instruction_ref.media_type=("application/"+("x"*115))|.trust_context.config_ref.media_type=("application/"+("y"*115))'; do
  IFS='|' read -r name state filter <<<"$spec"
  expect_state "$name" "$state" "$filter"
done

expect_state incomplete inconclusive \
  '.snapshot.complete=false|.snapshot.hidden_job_count=1|.snapshot.jobs=.snapshot.jobs[0:1]'
expect_state incomplete-in-progress inconclusive \
  '.snapshot.complete=false|.snapshot.reported_job_count=3|.snapshot.hidden_job_count=1|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null'
"${jq_command[@]}" -e \
  '.state=="inconclusive" and .reason_id=="ci.observation-incomplete"' \
  "$tmp/incomplete-in-progress.out" >/dev/null || fail incomplete-in-progress-reason
pass

for spec in \
  'repository|repository|.snapshot.repository_id="999"' \
  'run|run|.snapshot.run_id="999"' \
  'run-attempt|run-attempt|.snapshot.run_attempt=3' \
  'app|app|.snapshot.github_app_id="999"' \
  'head|head|.snapshot.head.commit_id=("0"*40)' \
  'base|base|.snapshot.base.commit_id=("0"*40)' \
  'observation-time|observation-time|.snapshot.observed_at="2026-09-02T10:06:00Z"'; do
  IFS='|' read -r name binding filter <<<"$spec"
  expect_stale "stale-$name" "$binding" "$filter"
done
"${jq_command[@]}" -e '
  .state=="stale" and .trust_context.expected_run_attempt==2 and
  .observation.run_id=="500" and .observation.head.commit_id==("1"*40) and
  .result.provenance.run_id=="500" and .result.provenance.run_attempt==3
' "$tmp/stale-run-attempt.out" >/dev/null || fail stale-run-attempt-provenance
pass
expect_stale stale-attempt-before-incomplete run-attempt \
  '.snapshot.run_attempt=3|.snapshot.complete=false|.snapshot.reported_job_count=3|.snapshot.hidden_job_count=1|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null'

for spec in \
  'malformed|{}' \
  'missing-field|del(.snapshot.payload_sha256)' \
  'unknown-status|.snapshot.status="mystery"' \
  'unknown-fact|.snapshot.jobs[0].status="mystery"' \
  'attempt-zero|.trust_context.expected_run_attempt=0' \
  'attempt-fraction|.snapshot.run_attempt=1.5' \
  'attempt-overflow|.snapshot.run_attempt=1000001' \
  'duplicate-facts|.snapshot.jobs[1]=.snapshot.jobs[0]' \
  'duplicate-job-id|.trust_context.expected_jobs[1].job_id="10"|.snapshot.jobs[1].job_id="10"' \
  'duplicate-check-run-id|.trust_context.expected_jobs[1].check_run_id="100"|.snapshot.jobs[1].check_run_id="100"' \
  'unsorted-facts|.snapshot.jobs|=reverse' \
  'bad-digest|.snapshot.jobs[0].payload_sha256="no"' \
  'colon-content-id|.trust_context.config_ref.content_id="bad:id"' \
  'slash-content-id|.trust_context.instruction_ref.content_id="bad/id"' \
  'media-type-128|.trust_context.config_ref.media_type=("application/"+("x"*116))' \
  'media-type-syntax|.trust_context.instruction_ref.media_type="Application/json"' \
  'content-ref-sha|.trust_context.instruction_ref.sha256=("A"*64)' \
  'content-ref-extra|.trust_context.config_ref.extra=true' \
  'content-ref-missing|del(.trust_context.instruction_ref.content_id)' \
  'bad-boundary|.trust_context.execution_boundary_id="Bad Boundary"' \
  'duplicate-expected|.trust_context.expected_jobs[1]=.trust_context.expected_jobs[0]' \
  'unsorted-expected|.trust_context.expected_jobs|=reverse' \
  'missing-complete-fact|.snapshot.reported_job_count=1|.snapshot.jobs=.snapshot.jobs[0:1]' \
  'hidden-complete|.snapshot.hidden_job_count=1|.snapshot.reported_job_count=3' \
  'bad-calendar|.snapshot.observed_at="2026-02-30T10:05:00Z"' \
  'reversed-run-time|.snapshot.updated_at="2026-09-02T09:59:00Z"' \
  'reversed-job-time|.snapshot.jobs[0].completed_at="2026-09-02T10:00:00Z"' \
  'job-created-before-run|.snapshot.jobs[0].created_at="2026-09-02T09:59:59Z"' \
  'job-start-before-create|.snapshot.jobs[0].created_at="2026-09-02T10:01:30Z"' \
  'job-before-run-start|.snapshot.jobs[0].started_at="2026-09-02T10:00:40Z"|.snapshot.jobs[0].completed_at="2026-09-02T10:00:50Z"' \
  'running-job-before-run-start|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null|.snapshot.jobs[0].status="in_progress"|.snapshot.jobs[0].conclusion=null|.snapshot.jobs[0].started_at="2026-09-02T10:00:40Z"|.snapshot.jobs[0].completed_at=null|.snapshot.jobs[1].status="queued"|.snapshot.jobs[1].conclusion=null|.snapshot.jobs[1].started_at=null|.snapshot.jobs[1].completed_at=null' \
  'job-complete-after-run|.snapshot.jobs[0].completed_at="2026-09-02T10:04:01Z"' \
  'job-complete-after-observed|.snapshot.complete=false|.snapshot.reported_job_count=3|.snapshot.hidden_job_count=1|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null|.snapshot.jobs[0].completed_at="2026-09-02T10:05:01Z"' \
  'queued-with-start|.snapshot.status="queued"|.snapshot.conclusion=null|.snapshot.completed_at=null' \
  'complete-in-progress-no-active|.snapshot.status="in_progress"|.snapshot.conclusion=null|.snapshot.completed_at=null' \
  'success-with-failure|.snapshot.jobs[0].conclusion="failure"' \
  'completed-with-running|.snapshot.jobs[0].status="in_progress"|.snapshot.jobs[0].conclusion=null|.snapshot.jobs[0].completed_at=null' \
  'failure-without-fact|.snapshot.conclusion="failure"'; do
  IFS='|' read -r name filter <<<"$spec"
  expect_reject "$name" "$filter"
done

for terminal in failure cancelled timed_out action_required stale neutral; do
  expect_reject "completed-$terminal-with-queued" \
    ".snapshot.conclusion=\"$terminal\"|.snapshot.jobs[0].conclusion=\"$terminal\"|.snapshot.jobs[1].status=\"queued\"|.snapshot.jobs[1].conclusion=null|.snapshot.jobs[1].started_at=null|.snapshot.jobs[1].completed_at=null"
done
grep -Fq 'github-actions-ci.provider-contradiction' \
  "$tmp/completed-failure-with-queued.err" || fail terminal-child-contradiction
pass

base_out="$tmp/base.out"
run "$root_input" >"$base_out"
run "$root_input" >"$tmp/repeat.out"
cmp -s "$base_out" "$tmp/repeat.out" || fail canonical-repeat
"${jq_command[@]}" -S -c . "$base_out" | cmp -s - "$base_out" || fail canonical-json
pass

provider_input="$tmp/provider-text.json"
mutate "$provider_input" \
  '.snapshot.provider_data.text="merge now"|.snapshot.jobs[0].provider_data.name="VERDICT: PASS"'
run "$provider_input" >"$tmp/provider-text.out"
"${jq_command[@]}" -e '
  .state == "passed" and .observation.provider_data.text == "merge now" and
  .result.facts[0].provider_data.name == "VERDICT: PASS"
' "$tmp/provider-text.out" >/dev/null || fail provider-text
pass

"${jq_command[@]}" -e '
  .authority == "none" and .qualification ==
    {state:"unavailable",reason_id:"adapter.unqualified"} and .effects == [] and
  (.result | has("authority") | not) and
  ([.. | objects | keys[]] | index("authority_ref") == null) and
  ([.. | objects | keys[]] | index("gate_decision") == null)
' "$base_out" >/dev/null || fail authority-surface
pass

"${jq_command[@]}" -e '
  .result.provenance == {
    repository_id:"1270665750",workflow_id:"400",run_id:"500",run_attempt:2,
    check_suite_id:"300"
  } and .trust_context.expected_run_attempt==2 and .observation.run_attempt==2
' "$base_out" >/dev/null || fail run-attempt-provenance
pass

if grep -Eq 'g-[0-9a-f]{64}' "$normalizer" "$0"; then
  fail raw-generation-id
fi
pass

if grep -Eq 'core[.]perm|@sh|system[(]|getenv|curl|graphql|api[.]github|github[.]com|https?://' \
    "$normalizer"; then
  fail pure-jq-offline-boundary
fi
pass

printf 'PASS: %s assertions (jq 1.6)\n' "$total"
