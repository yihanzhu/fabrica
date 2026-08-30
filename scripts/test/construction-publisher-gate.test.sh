#!/usr/bin/env bash

set -euo pipefail

export LC_ALL=C

test_root="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd -P)"
source_gate="$test_root/scripts/construction-publisher-gate.sh"
test_tmp="$(mktemp -d /tmp/ystack-construction-publisher-test.XXXXXXXX)"
trap 'rm -rf -- "$test_tmp"' EXIT

fixtures="$test_tmp/fixtures"
fake_bin="$test_tmp/bin"
log="$test_tmp/gh.log"
trusted_repo="$test_tmp/trusted"
mkdir -p "$fixtures" "$fake_bin" "$trusted_repo/scripts/test"
cp "$source_gate" "$trusted_repo/scripts/construction-publisher-gate.sh"
cp "$test_root/scripts/test/construction-publisher-gate.test.sh" \
  "$trusted_repo/scripts/test/construction-publisher-gate.test.sh"
git -C "$trusted_repo" init -q -b main
git -C "$trusted_repo" add scripts
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
  git -C "$trusted_repo" commit -q -m 'install trusted construction publisher gate'
gate="$trusted_repo/scripts/construction-publisher-gate.sh"

base="$(git -C "$trusted_repo" rev-parse HEAD)"
gate_blob="$(git -C "$trusted_repo" rev-parse HEAD:scripts/construction-publisher-gate.sh)"
test_blob="$(git -C "$trusted_repo" rev-parse HEAD:scripts/test/construction-publisher-gate.test.sh)"
head='2222222222222222222222222222222222222222'
merge='3333333333333333333333333333333333333333'
tree='4444444444444444444444444444444444444444'
pr=191
review_id=9001
failures=0
passes=0

fail() {
  printf 'not ok: %s\n' "$1" >&2
  failures=$((failures + 1))
}

pass() {
  printf 'ok: %s\n' "$1"
  passes=$((passes + 1))
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

assert_jq() {
  local label="$1"
  local filter="$2"
  local file="$3"
  if jq -e "$filter" "$file" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_last_read_main() {
  local label="$1"
  if [ "$(tail -n 1 "$log")" = 'repos/yihanzhu/ystack/git/ref/heads/main' ]; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_no_write() {
  local label="$1"
  if [ ! -s "$fixtures/mutations" ]; then
    pass "$label"
  else
    fail "$label"
  fi
}

cat > "$fake_bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" != api ]; then
  printf '%s\n' "non-api gh command: $*" >> "$CPG_TEST_FIXTURES/mutations"
  exit 90
fi
shift
endpoint=''
hostname=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname)
      hostname="$2"
      shift 2
      ;;
    -H)
      shift 2
      ;;
    --paginate|--slurp)
      shift
      ;;
    -X|--method|-f|-F|--field|--raw-field|--input)
      printf '%s\n' "mutation option: $1" >> "$CPG_TEST_FIXTURES/mutations"
      exit 90
      ;;
    *)
      [ -z "$endpoint" ] || {
        printf '%s\n' "unexpected gh argument: $1" >> "$CPG_TEST_FIXTURES/mutations"
        exit 90
      }
      endpoint="$1"
      shift
      ;;
  esac
done

[ -n "$endpoint" ] || exit 91
[ "$hostname" = github.com ] || {
  printf '%s\n' "wrong or missing hostname: $hostname" >> "$CPG_TEST_FIXTURES/mutations"
  exit 90
}
case "$endpoint" in
  *'/merge'*|graphql*)
    printf '%s\n' "mutation endpoint: $endpoint" >> "$CPG_TEST_FIXTURES/mutations"
    exit 90
    ;;
esac
printf '%s\n' "$endpoint" >> "$CPG_TEST_LOG"

scenario="${CPG_TEST_SCENARIO:-success}"
phase="${CPG_TEST_PHASE:-pre}"

emit() {
  local file="$1"
  local filter="${2:-.}"
  jq -c "$filter" "$CPG_TEST_FIXTURES/$file"
}

case "$endpoint" in
  user)
    if [ "$scenario" = wrong-user ]; then
      emit user.json '.login="someone-else"'
    else
      emit user.json
    fi
    ;;
  repos/yihanzhu/ystack)
    if [ "$scenario" = wrong-repo ]; then
      emit repo.json '.id=1'
    else
      emit repo.json
    fi
    ;;
  'repos/yihanzhu/ystack/contents/config/construction-mode.json?ref='*)
    if [ "$scenario" = inactive-mode ]; then
      jq -c '.status="inactive"' "$CPG_TEST_FIXTURES/mode.json" |
        jq -Rs -c --arg sha 4f35b0ec232e584973071a8d2e90ee5971af6e79 \
          '{type:"file",encoding:"base64",sha:$sha,content:(@base64)}'
    elif [ "$scenario" = wrong-mode-blob ]; then
      jq -Rs -c --arg sha 0000000000000000000000000000000000000000 \
        '{type:"file",encoding:"base64",sha:$sha,content:(@base64)}' \
        "$CPG_TEST_FIXTURES/mode.json"
    else
      jq -Rs -c --arg sha 4f35b0ec232e584973071a8d2e90ee5971af6e79 \
        '{type:"file",encoding:"base64",sha:$sha,content:(@base64)}' \
        "$CPG_TEST_FIXTURES/mode.json"
    fi
    ;;
  'repos/yihanzhu/ystack/contents/scripts/construction-publisher-gate.sh?ref='*)
    printf '{"sha":"%s"}\n' "$CPG_TEST_GATE_BLOB"
    ;;
  'repos/yihanzhu/ystack/contents/scripts/test/construction-publisher-gate.test.sh?ref='*)
    printf '{"sha":"%s"}\n' "$CPG_TEST_TEST_BLOB"
    ;;
  'repos/yihanzhu/ystack/contents/ROADMAP.md?ref='*)
    if [ "$scenario" = wrong-roadmap ]; then
      printf '%s\n' '{"sha":"0000000000000000000000000000000000000000"}'
    else
      emit roadmap.json
    fi
    ;;
  'repos/yihanzhu/ystack/contents/NORTH_STAR.md?ref='*)
    emit north-star.json
    ;;
  repos/yihanzhu/ystack/rulesets/21500323)
    count="$(grep -Fxc "$endpoint" "$CPG_TEST_LOG")"
    case "$scenario" in
      ruleset-not-strict) emit ruleset.json '(.rules[]|select(.type=="required_status_checks").parameters.strict_required_status_checks_policy)=false' ;;
      ruleset-bypass) emit ruleset.json '.bypass_actors=[{"actor_id":1}]' ;;
      ruleset-wrong-app) emit ruleset.json '(.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[0].integration_id)=1' ;;
      late-ruleset-move)
        if [ "$count" -gt 1 ]; then
          emit ruleset.json '.updated_at="later"'
        else
          emit ruleset.json
        fi
        ;;
      *) emit ruleset.json ;;
    esac
    ;;
  repos/yihanzhu/ystack/pulls/183)
    if [ "$scenario" = frozen-pr-moved ]; then
      emit frozen-pr.json '.head.sha="0000000000000000000000000000000000000000"'
    else
      emit frozen-pr.json
    fi
    ;;
  "repos/yihanzhu/ystack/pulls/$CPG_TEST_PR")
    if [ "$phase" = post ]; then
      case "$scenario" in
        post-not-merged) emit pr.json ;;
        post-pr-read-failed) exit 93 ;;
        post-pr-mismatch) emit pr-post.json '.merge_commit_sha="0000000000000000000000000000000000000000"' ;;
        *) emit pr-post.json ;;
      esac
    else
      count="$(grep -Fxc "$endpoint" "$CPG_TEST_LOG")"
      case "$scenario" in
        draft-pr) emit pr.json '.draft=true' ;;
        wrong-head) emit pr.json '.head.sha="0000000000000000000000000000000000000000"' ;;
        fork-head) emit pr.json '.head.repo.id=8' ;;
        dirty-pr) emit pr.json '.mergeable_state="dirty"' ;;
        late-pr-move)
          if [ "$count" -gt 1 ]; then
            emit pr.json '.head.sha="0000000000000000000000000000000000000000"'
          else
            emit pr.json
          fi
          ;;
        *) emit pr.json ;;
      esac
    fi
    ;;
  "repos/yihanzhu/ystack/issues/$CPG_TEST_PR/comments?per_page=100")
    count="$(grep -Fxc "$endpoint" "$CPG_TEST_LOG")"
    case "$scenario" in
      review-important) emit comments-important.json ;;
      review-newer-malformed) emit comments-newer.json ;;
      late-review-move)
        if [ "$count" -gt 1 ]; then
          emit comments-newer.json
        else
          emit comments.json
        fi
        ;;
      *) emit comments.json ;;
    esac
    ;;
  "repos/yihanzhu/ystack/pulls/$CPG_TEST_PR/files?per_page=100")
    case "$scenario" in
      forbidden-path) emit files-forbidden.json ;;
      publisher-path) emit files-publisher.json ;;
      *) emit files.json ;;
    esac
    ;;
  'repos/yihanzhu/ystack/contents/ci/required-files.txt?ref='*)
    manifest="$CPG_TEST_FIXTURES/manifest.txt"
    case "$scenario" in
      manifest-entry-missing) manifest="$CPG_TEST_FIXTURES/manifest-missing.txt" ;;
      publisher-manifest-missing) manifest="$CPG_TEST_FIXTURES/manifest-publisher-missing.txt" ;;
    esac
    jq -Rs -c --arg sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
      '{type:"file",encoding:"base64",sha:$sha,content:(@base64)}' "$manifest"
    ;;
  'repos/yihanzhu/ystack/compare/'*)
    if [ "$scenario" = bad-ancestry ]; then
      emit compare.json '.behind_by=1'
    else
      emit compare.json
    fi
    ;;
  "repos/yihanzhu/ystack/git/commits/$CPG_TEST_HEAD")
    if [ "$scenario" = post-head-tree-mismatch ]; then
      emit head-commit.json '.tree.sha="0000000000000000000000000000000000000000"'
    else
      emit head-commit.json
    fi
    ;;
  "repos/yihanzhu/ystack/git/commits/$CPG_TEST_MERGE")
    case "$scenario" in
      post-wrong-parent) emit merge-commit.json '.parents[0].sha="0000000000000000000000000000000000000000"' ;;
      post-two-parents) emit merge-commit.json '.parents += [{sha:"6666666666666666666666666666666666666666"}]' ;;
      post-wrong-tree) emit merge-commit.json '.tree.sha="0000000000000000000000000000000000000000"' ;;
      *) emit merge-commit.json ;;
    esac
    ;;
  'repos/yihanzhu/ystack/commits/'*'/check-runs?check_name=ci&app_id=15368&filter=latest&per_page=100')
    count="$(grep -Fxc "$endpoint" "$CPG_TEST_LOG")"
    case "$scenario" in
      ci-wrong-app) emit checks.json '.check_runs[0].app.id=1' ;;
      ci-pending) emit checks.json '.check_runs[0].status="in_progress"|.check_runs[0].conclusion=null' ;;
      ci-failed) emit checks.json '.check_runs[0].conclusion="failure"' ;;
      ci-duplicate) emit checks.json '.total_count=2|.check_runs += [.check_runs[0]]' ;;
      late-ci-move)
        if [ "$count" -gt 1 ]; then
          emit checks.json '.check_runs[0].status="in_progress"|.check_runs[0].conclusion=null'
        else
          emit checks.json
        fi
        ;;
      *) emit checks.json ;;
    esac
    ;;
  repos/yihanzhu/ystack/git/ref/heads/main)
    if [ "$phase" = post ]; then
      if [ "$scenario" = post-main-moved ]; then
        emit main-post.json '.object.sha="5555555555555555555555555555555555555555"'
      else
        emit main-post.json
      fi
    elif [ "$scenario" = main-moved ]; then
      emit main-pre.json '.object.sha="5555555555555555555555555555555555555555"'
    else
      emit main-pre.json
    fi
    ;;
  *)
    printf '%s\n' "unknown GET endpoint: $endpoint" >> "$CPG_TEST_FIXTURES/mutations"
    exit 92
    ;;
esac
FAKE_GH
chmod +x "$fake_bin/gh"

cp "$test_root/config/construction-mode.json" "$fixtures/mode.json"
cp "$test_root/ci/required-files.txt" "$fixtures/manifest.txt"
grep -Fvx 'AGENTS.md' "$fixtures/manifest.txt" > "$fixtures/manifest-missing.txt"
grep -Fvx 'scripts/construction-publisher-gate.sh' "$fixtures/manifest.txt" \
  > "$fixtures/manifest-publisher-missing.txt"

jq -n '{login:"yihanzhu",id:48186361}' > "$fixtures/user.json"
jq -n '{
  id:1270665750,full_name:"yihanzhu/ystack",default_branch:"main",archived:false,
  allow_squash_merge:true,allow_merge_commit:false,allow_rebase_merge:false,
  allow_auto_merge:false
}' > "$fixtures/repo.json"
jq -n --arg sha "$(jq -r '.roadmap_blob' "$fixtures/mode.json")" '{sha:$sha}' > "$fixtures/roadmap.json"
jq -n --arg sha "$(jq -r '.north_star_blob' "$fixtures/mode.json")" '{sha:$sha}' > "$fixtures/north-star.json"
jq -n '{
  id:21500323,name:"ystack-main-gate",target:"branch",source_type:"Repository",
  source:"yihanzhu/ystack",enforcement:"active",
  conditions:{ref_name:{exclude:[],include:["~DEFAULT_BRANCH"]}},
  rules:[
    {type:"deletion"},{type:"non_fast_forward"},
    {type:"pull_request",parameters:{
      required_approving_review_count:0,dismiss_stale_reviews_on_push:false,
      required_reviewers:[],require_code_owner_review:false,
      require_last_push_approval:false,required_review_thread_resolution:false,
      require_extra_approval_for_unattributed_changes:false,
      allowed_merge_methods:["squash"]}},
    {type:"required_status_checks",parameters:{
      strict_required_status_checks_policy:true,do_not_enforce_on_create:false,
      required_status_checks:[{context:"ci",integration_id:15368}]}}
  ],
  bypass_actors:[],current_user_can_bypass:"never",updated_at:"2026-08-29T20:59:43.926-04:00"
}' > "$fixtures/ruleset.json"

jq -n \
  --argjson number "$pr" --arg base "$base" --arg head "$head" '{
    number:$number,state:"open",merged:false,draft:false,mergeable:true,mergeable_state:"clean",
    base:{ref:"main",sha:$base},
    head:{sha:$head,repo:{id:1270665750,full_name:"yihanzhu/ystack"}}
  }' > "$fixtures/pr.json"
jq -n \
  --argjson number "$pr" --arg base "$base" --arg head "$head" --arg merge "$merge" '{
    number:$number,state:"closed",merged:true,merged_at:"2026-08-30T12:00:00Z",
    merged_by:{login:"yihanzhu"},merge_commit_sha:$merge,
    base:{ref:"main",sha:$base},head:{sha:$head}
  }' > "$fixtures/pr-post.json"
jq -n \
  --arg head "$(jq -r '.frozen_pr_183_head' "$fixtures/mode.json")" \
  --arg base "$(jq -r '.frozen_pr_183_base' "$fixtures/mode.json")" '{
    number:183,state:"open",head:{sha:$head},base:{sha:$base},
    labels:[{name:"round-3"},{name:"needs-human"}]
  }' > "$fixtures/frozen-pr.json"

cat > "$fixtures/review-body.txt" <<EOF
## Codex reviewer (cross-vendor, read-only)

Reviewed-head: $head
Reviewed-base: $base
reviewer: operator-default @ high

_Posted verbatim by codex-review.sh in an isolated temporary worktree with a read-only sandbox. Comments only; the reviewer never edits, approves, publishes, or merges._

The construction publisher gate matches the active repository-only mode. The review inspected the exact change, its fail-closed paths, tests, identity boundary, and receipt checks. No actionable correctness, security, or compliance issue was found.
EOF
review_digest="$(sha256_file "$fixtures/review-body.txt")"
jq -n --rawfile body "$fixtures/review-body.txt" --argjson id "$review_id" '[[{
  id:$id,user:{login:"yihanzhu"},body:$body,
  created_at:"2026-08-30T11:00:00Z",updated_at:"2026-08-30T11:00:00Z"
}]]' > "$fixtures/comments.json"
jq '. [0][0].body += "\n- [P1] Important safety finding"' \
  "$fixtures/comments.json" > "$fixtures/comments-important.json"
jq '. [0] += [{
  id:9002,user:{login:"yihanzhu"},
  body:"## Codex reviewer (cross-vendor, read-only)\nmalformed newer review",
  created_at:"2026-08-30T11:10:00Z",updated_at:"2026-08-30T11:10:00Z"
}]' "$fixtures/comments.json" > "$fixtures/comments-newer.json"

jq -n '[[
  {filename:"ci/required-files.txt",status:"modified"},
  {filename:"core/v1/generations/g-test/modules/example.jq",status:"added"},
  {filename:"scripts/test/example-construction-unit.test.sh",status:"added"}
]]' > "$fixtures/files.json"
jq '.[0] += [{filename:".github/workflows/unsafe.yml",status:"added"}]' \
  "$fixtures/files.json" > "$fixtures/files-forbidden.json"
jq '.[0] += [{filename:"scripts/construction-publisher-gate.sh",status:"modified"}]' \
  "$fixtures/files.json" > "$fixtures/files-publisher.json"
jq -n --arg base "$base" '{status:"ahead",ahead_by:1,behind_by:0,merge_base_commit:{sha:$base}}' \
  > "$fixtures/compare.json"
jq -n --arg head "$head" --arg tree "$tree" '{sha:$head,tree:{sha:$tree},parents:[]}' \
  > "$fixtures/head-commit.json"
jq -n --arg merge "$merge" --arg base "$base" --arg tree "$tree" '{
  sha:$merge,tree:{sha:$tree},parents:[{sha:$base}]
}' > "$fixtures/merge-commit.json"
jq -n --arg head "$head" '{
  total_count:1,check_runs:[{
    id:7001,name:"ci",head_sha:$head,status:"completed",conclusion:"success",
    details_url:"https://github.com/yihanzhu/ystack/actions/runs/7001/job/1",app:{id:15368}
  }]
}' > "$fixtures/checks.json"
jq -n --arg sha "$base" '{object:{sha:$sha}}' > "$fixtures/main-pre.json"
jq -n --arg sha "$merge" '{object:{sha:$sha}}' > "$fixtures/main-post.json"

jq -S -n \
  --arg base "$base" --arg head "$head" --arg digest "$review_digest" \
  --argjson pr "$pr" --argjson review_id "$review_id" '{
    schema_version:1,repository:"yihanzhu/ystack",repository_id:1270665750,
    pull_request:$pr,expected_head:$head,expected_base:$base,
    allowed_paths:[
      "ci/required-files.txt",
      "core/v1/generations/g-test/modules/example.jq",
      "scripts/test/example-construction-unit.test.sh"
    ],
    connector:{
      id:48186361,login:"yihanzhu",tool:"github_merge_pull_request",
      identity_observed:true,identity_observation_tool:"github_get_user_login",
      identity_attested_by:"current-operator-authorized-codex-construction-session"
    },
    review:{
      comment_id:$review_id,body_sha256:$digest,
      independent_review_run:true,complete_review_read:true,
      machine_verdict_available:false,
      semantic_decision:"no_unresolved_important",
      semantic_decision_source:"current-session-read-complete-review",
      unresolved_important_findings:0,
      attested_by:"current-operator-authorized-codex-construction-session"
    }
  }' > "$fixtures/request.json"
jq -n --arg sha "$merge" '{merged:true,sha:$sha,message:"Pull Request successfully merged"}' \
  > "$fixtures/merge-result.json"
jq -n --arg sha "$merge" '{result:{merged:true,sha:$sha,message:"ok"}}' \
  > "$fixtures/merge-result-wrapped.json"
jq -n '{merged:false,message:"Base branch was modified"}' > "$fixtures/merge-result-failed.json"
jq -n '{outcome:"uncertain"}' > "$fixtures/merge-result-uncertain.json"
jq -j '.[0][0].body' "$fixtures/comments-important.json" > "$fixtures/review-important-body.txt"
important_digest="$(sha256_file "$fixtures/review-important-body.txt")"
jq --arg digest "$important_digest" '.review.body_sha256=$digest' \
  "$fixtures/request.json" > "$fixtures/request-review-important.json"
jq '.allowed_paths += [".github/workflows/unsafe.yml"]' \
  "$fixtures/request.json" > "$fixtures/request-forbidden.json"
jq '.allowed_paths += ["scripts/construction-publisher-gate.sh"]' \
  "$fixtures/request.json" > "$fixtures/request-publisher.json"

export PATH="$fake_bin:$PATH"
export CPG_TEST_FIXTURES="$fixtures"
export CPG_TEST_LOG="$log"
export CPG_TEST_PR="$pr"
export CPG_TEST_HEAD="$head"
export CPG_TEST_MERGE="$merge"
export CPG_TEST_GATE_BLOB="$gate_blob"
export CPG_TEST_TEST_BLOB="$test_blob"
export GH_TOKEN='SECRET_CANARY_MUST_NOT_LEAK'
export GH_HOST='evil.example'

run_preflight() {
  local scenario="$1"
  local request="${2:-$fixtures/request.json}"
  : > "$log"
  : > "$fixtures/mutations"
  CPG_TEST_PHASE=pre CPG_TEST_SCENARIO="$scenario" \
    "$gate" preflight "$request" > "$test_tmp/preflight.out" 2> "$test_tmp/preflight.err"
}

expect_preflight_failure() {
  local scenario="$1"
  local label="$2"
  local request="${3:-$fixtures/request.json}"
  if run_preflight "$scenario" "$request"; then
    fail "$label"
  else
    pass "$label"
  fi
  assert_no_write "$label performs no GitHub write"
}

expect_tampered_preflight_failure() {
  local filter="$1"
  local label="$2"
  jq "$filter" "$test_tmp/preflight.json" > "$test_tmp/preflight-tampered.json"
  : > "$log"
  : > "$fixtures/mutations"
  if CPG_TEST_PHASE=post CPG_TEST_SCENARIO=success \
      "$gate" postflight "$test_tmp/preflight-tampered.json" \
        "$fixtures/merge-result.json" > "$test_tmp/postflight.out" 2> "$test_tmp/postflight.err"; then
    fail "$label"
  else
    pass "$label"
  fi
  assert_no_write "$label performs no GitHub write"
}

run_postflight() {
  local scenario="$1"
  local result="${2:-$fixtures/merge-result.json}"
  : > "$log"
  : > "$fixtures/mutations"
  CPG_TEST_PHASE=post CPG_TEST_SCENARIO="$scenario" \
    "$gate" postflight "$test_tmp/preflight.json" "$result" \
      > "$test_tmp/postflight.out" 2> "$test_tmp/postflight.err"
}

expect_postflight_failure() {
  local scenario="$1"
  local label="$2"
  local result="${3:-$fixtures/merge-result.json}"
  if run_postflight "$scenario" "$result"; then
    fail "$label"
  else
    pass "$label"
  fi
  assert_no_write "$label performs no GitHub write"
}

repo_head_before="$(git -C "$test_root" rev-parse HEAD)"
repo_status_before="$(git -C "$test_root" status --porcelain=v1)"

if run_preflight success; then
  cp "$test_tmp/preflight.out" "$test_tmp/preflight.json"
  pass 'preflight accepts the exact active construction candidate'
else
  fail 'preflight accepts the exact active construction candidate'
  sed 's/^/  preflight: /' "$test_tmp/preflight.err" >&2
  cp "$test_tmp/preflight.out" "$test_tmp/preflight.json"
fi
assert_jq 'preflight emits fixed connector arguments and an honest non-CAS base guard' "
  .status == \"eligible_for_external_publish\" and
  .connector.arguments == {
    expected_head_sha:\"2222222222222222222222222222222222222222\",
    merge_method:\"squash\",pr_number:191,repository_full_name:\"yihanzhu/ystack\"} and
  .base_guard == {
    atomic_base_cas:false,last_read:\"$base\",
    server_strict_required_checks:true}
" "$test_tmp/preflight.json"
assert_last_read_main 'preflight main/base check is the final GitHub read'
if grep -Fq "/check-runs?check_name=ci&app_id=15368&filter=latest&per_page=100" "$log"; then
  pass 'preflight asks GitHub to filter latest CI by required app 15368'
else
  fail 'preflight asks GitHub to filter latest CI by required app 15368'
fi
assert_no_write 'successful preflight performs no GitHub write'

cp "$test_tmp/preflight.json" "$test_tmp/preflight.first"
if run_preflight success && cmp -s "$test_tmp/preflight.first" "$test_tmp/preflight.out"; then
  pass 'preflight is deterministic for one exact GitHub snapshot'
else
  fail 'preflight is deterministic for one exact GitHub snapshot'
fi

cp "$gate" "$test_tmp/gate.backup"
printf '\n' >> "$gate"
if run_preflight success; then
  fail 'preflight rejects a modified candidate copy of the installed gate'
else
  pass 'preflight rejects a modified candidate copy of the installed gate'
fi
mv "$test_tmp/gate.backup" "$gate"
chmod +x "$gate"
assert_no_write 'modified gate source performs no GitHub write'

git -C "$trusted_repo" switch -q -c candidate-copy
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
  git -C "$trusted_repo" commit -q --allow-empty -m 'candidate head'
if run_preflight success; then
  fail 'preflight rejects execution from a candidate HEAD instead of the reviewed base'
else
  pass 'preflight rejects execution from a candidate HEAD instead of the reviewed base'
fi
git -C "$trusted_repo" switch -q --detach "$base"
assert_no_write 'candidate HEAD source performs no GitHub write'

expect_preflight_failure wrong-user 'preflight rejects a different operator identity'
expect_preflight_failure wrong-repo 'preflight rejects a different repository identity'
expect_preflight_failure inactive-mode 'preflight rejects inactive construction mode'
expect_preflight_failure wrong-mode-blob 'preflight rejects a different construction mode blob'
expect_preflight_failure wrong-roadmap 'preflight rejects a moved Roadmap blob'
expect_preflight_failure ruleset-not-strict 'preflight rejects a non-strict status gate'
expect_preflight_failure ruleset-bypass 'preflight rejects a ruleset bypass actor'
expect_preflight_failure ruleset-wrong-app 'preflight rejects a different required CI app'
expect_preflight_failure draft-pr 'preflight rejects a draft PR'
expect_preflight_failure wrong-head 'preflight rejects a moved PR head'
expect_preflight_failure fork-head 'preflight rejects a fork head'
expect_preflight_failure dirty-pr 'preflight rejects an unclean merge state'
expect_preflight_failure review-important 'preflight rejects an Important review marker' \
  "$fixtures/request-review-important.json"
expect_preflight_failure review-newer-malformed 'a newer malformed review blocks an older clean review'
expect_preflight_failure forbidden-path 'preflight rejects a forbidden path on any files page' \
  "$fixtures/request-forbidden.json"
expect_preflight_failure publisher-path 'preflight rejects changes to its installed gate' \
  "$fixtures/request-publisher.json"
expect_preflight_failure manifest-entry-missing 'preflight rejects a removed required manifest entry'
expect_preflight_failure publisher-manifest-missing 'preflight preserves its own restore-manifest entry'
expect_preflight_failure bad-ancestry 'preflight rejects a head that is behind its reviewed base'
expect_preflight_failure ci-wrong-app 'preflight rejects a successful check from the wrong app'
expect_preflight_failure ci-pending 'preflight rejects pending required CI'
expect_preflight_failure ci-failed 'preflight rejects failed required CI'
expect_preflight_failure ci-duplicate 'preflight rejects ambiguous duplicate latest CI'
expect_preflight_failure frozen-pr-moved 'preflight rejects a moved frozen PR #183'
expect_preflight_failure late-ruleset-move 'preflight rejects a ruleset that moves during validation'
expect_preflight_failure late-review-move 'preflight rejects a review that moves during validation'
expect_preflight_failure late-ci-move 'preflight rejects required CI that moves during validation'
expect_preflight_failure late-pr-move 'preflight rejects a PR that moves during validation'
expect_preflight_failure main-moved 'preflight rejects a base move at the final read'

jq '.review.unresolved_important_findings=1' "$fixtures/request.json" \
  > "$fixtures/request-important.json"
if run_preflight success "$fixtures/request-important.json"; then
  fail 'request refuses unresolved Important findings before any eligibility output'
else
  pass 'request refuses unresolved Important findings before any eligibility output'
fi
assert_no_write 'invalid review attestation performs no GitHub write'

jq '.connector.identity_observed=false' "$fixtures/request.json" \
  > "$fixtures/request-connector-unobserved.json"
if run_preflight success "$fixtures/request-connector-unobserved.json"; then
  fail 'request refuses an unobserved connector identity'
else
  pass 'request refuses an unobserved connector identity'
fi
assert_no_write 'invalid connector identity observation performs no GitHub write'

expect_tampered_preflight_failure '.authorization.mode_record_blob=null' \
  'postflight rejects a preflight with a missing mode identity'
expect_tampered_preflight_failure '.authorization.ci.check_run_id=null' \
  'postflight rejects a preflight with missing CI evidence'
expect_tampered_preflight_failure '.authorization.review.body_sha256=null' \
  'postflight rejects a preflight with missing review evidence'
expect_tampered_preflight_failure '.exact.allowed_paths=[]' \
  'postflight rejects a preflight with missing scope evidence'

cp "$gate" "$test_tmp/gate.backup"
printf '\n' >> "$gate"
if run_postflight success; then
  fail 'postflight rejects a modified candidate copy of the installed gate'
else
  pass 'postflight rejects a modified candidate copy of the installed gate'
fi
mv "$test_tmp/gate.backup" "$gate"
chmod +x "$gate"
assert_no_write 'modified postflight gate performs no GitHub write'

if run_postflight success; then
  pass 'postflight accepts the exact squash merge result'
else
  fail 'postflight accepts the exact squash merge result'
  sed 's/^/  postflight: /' "$test_tmp/postflight.err" >&2
fi
assert_jq 'postflight records parent, tree, main, CI, review, and connector identities' "
  .receipt.status == \"completed\" and .receipt.result == \"merged\" and
  .receipt.merge_method == \"squash\" and
  .receipt.exact.parents == [\"$base\"] and
  .receipt.exact.head_tree == \"4444444444444444444444444444444444444444\" and
  .receipt.exact.merge_tree == .receipt.exact.head_tree and
  .receipt.exact.main == .receipt.exact.merge_commit and
  .receipt.authorization.ci.app_id == 15368 and
  .receipt.authorization.review.unresolved_important_findings == 0 and
  .receipt.authorization.connector.tool == \"github_merge_pull_request\" and
  (.receipt_sha256 | test(\"^[0-9a-f]{64}$\"))
" "$test_tmp/postflight.out"
assert_last_read_main 'postflight main verification is the final GitHub read'
assert_no_write 'successful postflight performs no GitHub write'

cp "$test_tmp/postflight.out" "$test_tmp/postflight.first"
if run_postflight success "$fixtures/merge-result-wrapped.json" &&
   cmp -s "$test_tmp/postflight.first" "$test_tmp/postflight.out"; then
  pass 'postflight accepts the connector wrapper and emits a deterministic receipt'
else
  fail 'postflight accepts the connector wrapper and emits a deterministic receipt'
fi

if run_postflight success "$fixtures/merge-result-uncertain.json"; then
  pass 'postflight reconciles an uncertain connector response from authoritative GitHub state'
else
  fail 'postflight reconciles an uncertain connector response from authoritative GitHub state'
fi
assert_jq 'uncertain reconciliation records how the merge was recovered' '
  .receipt.status == "completed" and .receipt.result == "merged" and
  .receipt.connector_outcome == "reconciled_after_uncertain"
' "$test_tmp/postflight.out"
assert_no_write 'uncertain reconciliation never retries the merge write'

expect_postflight_failure post-not-merged 'postflight records a refused connector result as not merged' \
  "$fixtures/merge-result-failed.json"
assert_jq 'not-merged reconciliation forbids a blind retry' '
  .receipt.kind == "construction-merge-reconciliation" and
  .receipt.status == "not_merged" and .receipt.retry_allowed == false
' "$test_tmp/postflight.out"
expect_postflight_failure success 'a refused connector cannot claim an out-of-band merge' \
  "$fixtures/merge-result-failed.json"
assert_jq 'refused-but-merged is recorded as unverified, never completed' '
  .receipt.status == "merged_unverified" and
  .receipt.reason == "connector_refused_but_pr_merged" and
  .receipt.retry_allowed == false
' "$test_tmp/postflight.out"
expect_postflight_failure post-pr-read-failed 'postflight records an unavailable PR reconciliation read'
expect_postflight_failure post-pr-mismatch 'postflight rejects a mismatched PR merge record'
expect_postflight_failure post-head-tree-mismatch 'postflight re-reads and rejects a moved head tree'
expect_postflight_failure post-wrong-parent 'postflight rejects the wrong squash parent'
expect_postflight_failure post-two-parents 'postflight rejects a non-squash two-parent commit'
expect_postflight_failure post-wrong-tree 'postflight rejects a merge tree different from the head tree'
expect_postflight_failure post-main-moved 'postflight does not claim success when main is not the merge commit'
assert_jq 'main mismatch leaves a durable merged-unverified record and forbids retry' '
  .receipt.kind == "construction-merge-reconciliation" and
  .receipt.status == "merged_unverified" and .receipt.reason == "main_mismatch" and
  .receipt.retry_allowed == false
' "$test_tmp/postflight.out"

if rg -n 'gh[[:space:]]+pr[[:space:]]+merge|pulls/[0-9]+/merge|git[[:space:]]+(push|update-ref|reset|clean|stash|rebase)|curl|wget' \
    "$gate" >/dev/null 2>&1; then
  fail 'gate source has no generic merge, ref-write, network fallback, or cleanup path'
else
  pass 'gate source has no generic merge, ref-write, network fallback, or cleanup path'
fi

combined="$test_tmp/combined-output"
cat "$test_tmp/preflight.out" "$test_tmp/preflight.err" \
  "$test_tmp/postflight.out" "$test_tmp/postflight.err" "$log" > "$combined"
if grep -Fq 'SECRET_CANARY_MUST_NOT_LEAK' "$combined"; then
  fail 'gate output and logs do not leak the credential canary'
else
  pass 'gate output and logs do not leak the credential canary'
fi

if [ "$(git -C "$test_root" rev-parse HEAD)" = "$repo_head_before" ] &&
   [ "$(git -C "$test_root" status --porcelain=v1)" = "$repo_status_before" ]; then
  pass 'gate tests leave the repository HEAD, index, and worktree state unchanged'
else
  fail 'gate tests leave the repository HEAD, index, and worktree state unchanged'
fi

printf 'construction publisher gate cases passed: %s\n' "$passes"
printf 'construction publisher gate failures: %s\n' "$failures"
[ "$failures" -eq 0 ]
