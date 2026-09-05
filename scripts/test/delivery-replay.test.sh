#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
export PYTHONDONTWRITEBYTECODE=1
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
replay="$root/delivery/v1/replay.py"
fixture_builder="$root/scripts/test/local-git-materializer-fixtures.sh"
closure_source="$root/adapters/local-git-materializer/v1/object-closure.c"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-delivery-replay.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) asset=jq-linux64; asset_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) asset=jq-osx-amd64; asset_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) fail "unsupported host $platform" ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$asset_sha" ] ||
  fail 'pinned jq 1.6 is required'

runtime="$tmp/runtime"
/bin/mkdir -m 700 "$runtime" "$tmp/home"
if [ "$platform" = Darwin:arm64 ]; then
  printf '%s\n' '#!/bin/sh' "exec /usr/bin/arch -x86_64 '$jq_bin' \"\$@\"" > "$runtime/jq"
else
  /bin/cp "$jq_bin" "$runtime/jq"
fi
/bin/chmod 0555 "$runtime/jq"
jq_bin="$runtime/jq"
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 "$closure_source" -o "$runtime/object-closure"
/bin/chmod 0555 "$runtime/object-closure"

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 /usr/bin/git --no-replace-objects "$@"
}
make_source() {
  local destination=$1 blob tree commit
  /bin/mkdir -m 700 "$destination"
  git_clean init -q --bare "$destination"
  blob=$(printf '%s\n' alpha beta | git_clean --git-dir="$destination" hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tsource.txt\n' "$blob" | git_clean --git-dir="$destination" mktree)
  commit=$(printf '%s\n' source | /usr/bin/env -i HOME="$tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=fixture \
    GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@example.invalid GIT_AUTHOR_DATE=2000-01-01T00:00:00Z \
    GIT_COMMITTER_DATE=2000-01-01T00:00:00Z /usr/bin/git --git-dir="$destination" commit-tree "$tree")
  git_clean --git-dir="$destination" update-ref refs/heads/main "$commit"
  printf '%s %s\n' "$commit" "$tree"
}

make_source_with_ancestor() {
  local destination=$1 blob tree base commit
  /bin/mkdir -m 700 "$destination"
  git_clean init -q --bare "$destination"
  blob=$(printf '%s\n' alpha beta | git_clean --git-dir="$destination" hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tsource.txt\n' "$blob" | git_clean --git-dir="$destination" mktree)
  base=$(printf '%s\n' base | /usr/bin/env -i HOME="$tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=fixture \
    GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git --git-dir="$destination" commit-tree "$tree")
  commit=$(printf '%s\n' source | /usr/bin/env -i HOME="$tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=fixture \
    GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
    GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git --git-dir="$destination" commit-tree "$tree" -p "$base")
  git_clean --git-dir="$destination" update-ref refs/heads/main "$commit"
  printf '%s %s\n' "$commit" "$tree"
}

make_empty_input() {
  local input=$1 output=$2
  local intermediate="$output.intermediate" request="$output.request"
  "$jq_bin" -S -c '(.stage_request.content.body.inputs[] | select(.input_id=="input.producer-patch") | .value.value.value.sha256) = $sha |
    (.payloads[] | select(.input_id=="input.producer-patch") | .data) = "" |
    (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch") | .content.data) = "" |
    (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch") | .sha256) = $sha' \
    --arg sha "$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" "$input" >"$intermediate"
  "$jq_bin" -S -c '.stage_request.content' "$intermediate" >"$request"
  "$jq_bin" -S -c --arg sha "$(sha_file "$request")" '.stage_request.sha256=$sha' "$intermediate" >"$output"
}

read -r source_commit source_tree < <(make_source "$tmp/source.git")
"$fixture_builder" build "$tmp/fixture" "$jq_bin" sha1 "$source_commit" "$source_tree"
base_input="$tmp/fixture/input.json"
expected_changed=$(printf '%s\n' alpha beta gamma | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')

run_replay() {
  local name=$1 input=$2 expected=$3
  local state="$tmp/$name-state" candidate="$tmp/$name-candidate" scratch="$tmp/$name-scratch"
  /bin/mkdir -m 700 "$state" "$candidate" "$scratch"
  python3 "$replay" --input "$input" --source-repository-id fixture.target \
    --source-git-dir "$tmp/source.git" --candidate-root "$candidate" --scratch-root "$scratch" \
    --state-dir "$state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected"
}

run_replay changed "$base_input" "$expected_changed" >"$tmp/changed.out"
jq -e '.state.phase=="review-wait" and .authority=="none" and .offline_simulation==true' "$tmp/changed.out" >/dev/null ||
  fail missing-review-waits
request_sha=$(jq -r '.identity.request_sha256' "$tmp/changed-state/run.json")
candidate_tree=$(jq -r '.identity.candidate_tree_id' "$tmp/changed-state/run.json")
pass 'changed materialization and fixed read-only verification wait for review'

cp "$base_input" "$tmp/mutable-input.json"
mkdir -m 700 "$tmp/mutation-state" "$tmp/mutation-candidate" "$tmp/mutation-scratch"
python3 "$replay" --input "$tmp/mutable-input.json" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/mutation-candidate" --scratch-root "$tmp/mutation-scratch" --state-dir "$tmp/mutation-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/mutation.out" &
mutation_pid=$!
mutation_wait=0
while [ ! -f "$tmp/mutation-state/materialization-input.json" ]; do
  if ! kill -0 "$mutation_pid" 2>/dev/null; then
    wait "$mutation_pid" || :
    sed -n '1,12p' "$tmp/mutation.out" >&2
    fail input-snapshot-start
  fi
  mutation_wait=$((mutation_wait + 1))
  if [ "$mutation_wait" -gt 100 ]; then
    kill -TERM "$mutation_pid" 2>/dev/null || :
    wait "$mutation_pid" || :
    fail input-snapshot-timeout
  fi
  sleep 0.1
done
printf '%s\n' '{"replaced":"after snapshot"}' >"$tmp/mutable-input.json"
wait "$mutation_pid" || fail input-snapshot-run
[ "$(sha_file "$tmp/mutation-state/materialization-input.json")" = "$(sha_file "$base_input")" ] || fail input-snapshot-bytes
jq -e '.state.phase=="review-wait" and .state.identity.input_sha256==$sha' --arg sha "$(sha_file "$base_input")" \
  "$tmp/mutation.out" >/dev/null || fail input-snapshot-output
pass 'replacement of the original input after snapshot cannot change materialization'

kill_wrapper="$tmp/kill-after-materialize.py"
printf '%s\n' \
  'import importlib.util, os, signal, sys' \
  'path, arguments = sys.argv[1], sys.argv[2:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'spec.loader.exec_module(module)' \
  'original = module.run_materializer' \
  'def stop_after_materialization(*args, **kwargs):' \
  '    result = original(*args, **kwargs)' \
  '    os.kill(os.getpid(), signal.SIGKILL)' \
  '    return result' \
  'module.run_materializer = stop_after_materialization' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$kill_wrapper"
mkdir -m 700 "$tmp/reconcile-state" "$tmp/reconcile-candidate" "$tmp/reconcile-scratch"
if python3 "$kill_wrapper" "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-candidate" --scratch-root "$tmp/reconcile-scratch" --state-dir "$tmp/reconcile-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/reconcile-killed.out" 2>&1; then fail reconcile-kill; fi
[ "$(jq -r '.phase' "$tmp/reconcile-state/run.json")" = materializing ] && [ -d "$tmp/reconcile-candidate/repository.git" ] ||
  fail reconcile-window
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-candidate" --scratch-root "$tmp/reconcile-scratch" --state-dir "$tmp/reconcile-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/reconcile-retry.out"
jq -e '.state.phase=="review-wait"' "$tmp/reconcile-retry.out" >/dev/null || fail reconcile-retry
pass 'SIGKILL after materializer output reconciles the existing candidate once'

mkdir -m 700 "$tmp/reconcile-bad-state" "$tmp/reconcile-bad-candidate" "$tmp/reconcile-bad-scratch"
if python3 "$kill_wrapper" "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-bad-candidate" --scratch-root "$tmp/reconcile-bad-scratch" --state-dir "$tmp/reconcile-bad-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/reconcile-bad-killed.out" 2>&1; then fail reconcile-bad-kill; fi
bad_repo="$tmp/reconcile-bad-candidate/repository.git"
bad_commit=$(printf '%s\n' mismatch | /usr/bin/env -i HOME="$tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
  GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git --git-dir="$bad_repo" commit-tree "$source_tree" -p "$source_commit")
/usr/bin/git --git-dir="$bad_repo" update-ref refs/heads/candidate "$bad_commit"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-bad-candidate" --scratch-root "$tmp/reconcile-bad-scratch" --state-dir "$tmp/reconcile-bad-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/reconcile-bad.out" 2>&1; then fail reconcile-mismatch; fi
jq -e '.state.phase=="failed" and (.state.reason|contains("does not match frozen"))' "$tmp/reconcile-bad.out" >/dev/null ||
  fail reconcile-mismatch-state
pass 'a mismatched interrupted candidate is rejected without cleanup'

printf '\377' >"$tmp/invalid-input.json"
mkdir -m 700 "$tmp/invalid-input-state" "$tmp/invalid-input-candidate" "$tmp/invalid-input-scratch"
if python3 "$replay" --input "$tmp/invalid-input.json" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/invalid-input-candidate" --scratch-root "$tmp/invalid-input-scratch" --state-dir "$tmp/invalid-input-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/invalid-input.out" 2>&1; then fail invalid-utf8-input; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/invalid-input.out" ||
   grep -Fq Traceback "$tmp/invalid-input.out"; then
  fail invalid-utf8-input-error
fi
printf '\377' >"$tmp/reconcile-state/invalid-review.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-candidate" --scratch-root "$tmp/reconcile-scratch" --state-dir "$tmp/reconcile-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/reconcile-state/invalid-review.json" >"$tmp/invalid-review.out" 2>&1; then fail invalid-utf8-review; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/invalid-review.out" ||
   grep -Fq Traceback "$tmp/invalid-review.out"; then
  fail invalid-utf8-review-error
fi
mkdir -m 700 "$tmp/invalid-journal-state" "$tmp/invalid-journal-candidate" "$tmp/invalid-journal-scratch"
printf '\377' >"$tmp/invalid-journal-state/run.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/invalid-journal-candidate" --scratch-root "$tmp/invalid-journal-scratch" --state-dir "$tmp/invalid-journal-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/invalid-journal.out" 2>&1; then fail invalid-utf8-journal; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/invalid-journal.out" ||
   grep -Fq Traceback "$tmp/invalid-journal.out"; then
  fail invalid-utf8-journal-error
fi
pass 'invalid UTF-8 input, review, and journal records fail without a traceback'

printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_review_observation","actor_id":"test.reviewer","request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","verdict":"clean"}' >"$tmp/review.json"
printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_publisher_observation","actor_id":"test.publisher","request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","disposition":"offline-simulated"}' >"$tmp/publisher.json"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/review.json" >"$tmp/publish-wait.out"
jq -e '.state.phase=="publish-wait"' "$tmp/publish-wait.out" >/dev/null || fail missing-publisher-waits
expect_malformed_state() {
  local name=$1 filter=$2
  local state_root="$tmp/malformed-$name-state"
  /bin/mkdir -m 700 "$state_root"
  cp "$tmp/changed-state/materialization-input.json" "$state_root/materialization-input.json"
  jq -S -c "$filter" "$tmp/changed-state/run.json" >"$state_root/run.json"
  if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$state_root" \
    --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
    >"$tmp/malformed-$name.out" 2>&1; then fail "malformed-$name"; fi
  if ! grep -Fq 'delivery replay: state journal' "$tmp/malformed-$name.out" ||
     grep -Fq Traceback "$tmp/malformed-$name.out"; then
    fail "malformed-$name-error"
  fi
}
expect_malformed_state identity-type '.identity=[]'
expect_malformed_state missing-phase 'del(.phase)'
expect_malformed_state invalid-phase '.phase="unknown"'
expect_malformed_state missing-materialization '(.phase="verifying") | del(.materialization)'
expect_malformed_state missing-verification '(.phase="review-wait") | del(.verification)'
expect_malformed_state missing-review '(.phase="publish-wait") | del(.review)'
expect_malformed_state missing-publisher '(.phase="completed-offline") | del(.publisher)'
pass 'malformed state phases and nested records fail without a traceback'
jq -S -c '.note="changed after review wait"' "$tmp/review.json" >"$tmp/changed-review.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/changed-review.json" --publisher-observation "$tmp/publisher.json" >"$tmp/changed-review.out" 2>&1; then fail changed-review-after-wait; fi
grep -Fq 'review changed after review wait' "$tmp/changed-review.out" || fail changed-review-after-wait-error
pass 'a changed supplied review cannot advance publish wait'
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/review.json" --publisher-observation "$tmp/publisher.json" >"$tmp/completed.out"
jq -e '.state.phase=="completed-offline" and .state.publisher.disposition=="offline-simulated"' "$tmp/completed.out" >/dev/null ||
  fail completed-offline
cp "$tmp/completed.out" "$tmp/completed-first.out"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/completed-repeat.out"
cmp "$tmp/completed-first.out" "$tmp/completed-repeat.out" || fail duplicate-completion-output
pass 'offline review and publisher observations complete once and replay deterministically'

if run_replay verifier-failure "$base_input" "$(printf '0%.0s' {1..64})" >"$tmp/verifier-failure.out" 2>&1; then
  fail fixed-verifier-failure
fi
jq -e '.state.phase=="failed" and (.state.reason|contains("digest mismatch"))' "$tmp/verifier-failure.out" >/dev/null ||
  fail fixed-verifier-failure-state
pass 'fixed verifier failure is terminal and explicit'

mkdir -m 700 "$tmp/mismatch-state" "$tmp/mismatch-candidate" "$tmp/mismatch-scratch"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/mismatch-candidate" --scratch-root "$tmp/mismatch-scratch" --state-dir "$tmp/mismatch-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" > /dev/null
printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_review_observation","actor_id":"test.reviewer","request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$(printf '0%.0s' {1..40})"'","verdict":"clean"}' >"$tmp/mismatch-review.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/mismatch-candidate" --scratch-root "$tmp/mismatch-scratch" --state-dir "$tmp/mismatch-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/mismatch-review.json" >"$tmp/mismatch.out" 2>&1; then fail mismatched-review; fi
grep -Fq 'does not match this candidate' "$tmp/mismatch.out" || fail mismatched-review-error
pass 'mismatched supplied review cannot complete the replay'

make_empty_input "$base_input" "$tmp/empty-final.json"
source_digest=$(printf '%s\n' alpha beta | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
run_replay no-change "$tmp/empty-final.json" "$source_digest" >"$tmp/no-change.out"
jq -e '.state.phase=="review-wait" and .state.materialization.candidate_tree_id==.state.identity.source_tree_id' "$tmp/no-change.out" >/dev/null ||
  fail no-change
pass 'empty producer patch records a no-change candidate before review'

recover_no_change() {
  local name=$1 input=$2 source=$3
  local state="$tmp/$name-state" candidate="$tmp/$name-candidate" scratch="$tmp/$name-scratch"
  /bin/mkdir -m 700 "$state" "$candidate" "$scratch"
  if python3 "$kill_wrapper" "$replay" --input "$input" --source-repository-id fixture.target --source-git-dir "$source" \
    --candidate-root "$candidate" --scratch-root "$scratch" --state-dir "$state" \
    --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$source_digest" \
    >"$tmp/$name-killed.out" 2>&1; then fail "$name-kill"; fi
  [ "$(jq -r '.phase' "$state/run.json")" = materializing ] && [ -d "$candidate/repository.git" ] || fail "$name-window"
  python3 "$replay" --input "$input" --source-repository-id fixture.target --source-git-dir "$source" \
    --candidate-root "$candidate" --scratch-root "$scratch" --state-dir "$state" \
    --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$source_digest" \
    >"$tmp/$name-retry.out"
  jq -e '.state.phase=="review-wait" and .state.materialization.candidate_commit_id==.state.identity.source_commit_id' \
    "$tmp/$name-retry.out" >/dev/null || fail "$name-retry"
}
recover_no_change no-change-root "$tmp/empty-final.json" "$tmp/source.git"
read -r ancestor_commit ancestor_tree < <(make_source_with_ancestor "$tmp/ancestor-source.git")
"$fixture_builder" build "$tmp/ancestor-fixture" "$jq_bin" sha1 "$ancestor_commit" "$ancestor_tree"
make_empty_input "$tmp/ancestor-fixture/input.json" "$tmp/ancestor-empty.json"
recover_no_change no-change-ancestor "$tmp/ancestor-empty.json" "$tmp/ancestor-source.git"
pass 'SIGKILL no-change recovery accepts both root and ancestor source commits'

mkdir -m 700 "$tmp/interrupted-state" "$tmp/interrupted-candidate" "$tmp/interrupted-scratch"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/interrupted-candidate" --scratch-root "$tmp/interrupted-scratch" --state-dir "$tmp/interrupted-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/interrupted.out" &
interrupted_pid=$!
interrupted_wait=0
while [ ! -f "$tmp/interrupted-state/run.json" ]; do
  if ! kill -0 "$interrupted_pid" 2>/dev/null; then
    wait "$interrupted_pid" || :
    sed -n '1,12p' "$tmp/interrupted.out" >&2
    fail interrupted-start
  fi
  interrupted_wait=$((interrupted_wait + 1))
  if [ "$interrupted_wait" -gt 100 ]; then
    kill -TERM "$interrupted_pid" 2>/dev/null || :
    wait "$interrupted_pid" || :
    sed -n '1,12p' "$tmp/interrupted.out" >&2
    fail interrupted-start-timeout
  fi
  sleep 0.1
done
kill -TERM "$interrupted_pid"
if wait "$interrupted_pid"; then fail interrupted-run; fi
[ "$(jq -r '.phase' "$tmp/interrupted-state/run.json")" = verifying ] || fail interrupted-state
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/interrupted-candidate" --scratch-root "$tmp/interrupted-scratch" --state-dir "$tmp/interrupted-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/interrupted-retry.out"
jq -e '.state.phase=="review-wait"' "$tmp/interrupted-retry.out" >/dev/null || fail interrupted-retry
pass 'interruption after materialization resumes without a duplicate candidate output'

mkdir -m 700 "$tmp/stale-state" "$tmp/stale-candidate" "$tmp/stale-scratch"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/stale-candidate" --scratch-root "$tmp/stale-scratch" --state-dir "$tmp/stale-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" > /dev/null
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/stale-candidate" --scratch-root "$tmp/stale-scratch" --state-dir "$tmp/stale-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$source_digest" >"$tmp/stale.out"; then fail changed-input-stale; fi
jq -e '.state.phase=="stale"' "$tmp/stale.out" >/dev/null || fail changed-input-stale-state
pass 'changed verifier input cannot reuse the prior run'
changed_input="$tmp/changed-input.json"
jq -S -c '.attempt.attempt_id="attempt.changed"' "$base_input" >"$changed_input"
if python3 "$replay" --input "$changed_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/stale-candidate" --scratch-root "$tmp/stale-scratch" --state-dir "$tmp/stale-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/changed-input-stale.out"; then fail changed-materialization-input-stale; fi
jq -e '.state.phase=="stale"' "$tmp/changed-input-stale.out" >/dev/null || fail changed-materialization-input-stale-state
pass 'changed materialization input cannot reuse the prior run'

printf 'delivery replay: %s focused checks passed\n' "$passed"
