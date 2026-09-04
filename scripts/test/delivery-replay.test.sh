#!/usr/bin/env bash
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

printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_review_observation","actor_id":"test.reviewer","request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","verdict":"clean"}' >"$tmp/review.json"
printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_publisher_observation","actor_id":"test.publisher","request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","disposition":"offline-simulated"}' >"$tmp/publisher.json"
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/review.json" >"$tmp/publish-wait.out"
jq -e '.state.phase=="publish-wait"' "$tmp/publish-wait.out" >/dev/null || fail missing-publisher-waits
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

empty_input="$tmp/empty-input.json"
jq -S -c '(.stage_request.content.body.inputs[] | select(.input_id=="input.producer-patch") | .value.value.value.sha256) = $sha |
  (.payloads[] | select(.input_id=="input.producer-patch") | .data) = "" |
  (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch") | .content.data) = "" |
  (.trust_context.verified_payloads[] | select(.input_id=="input.producer-patch") | .sha256) = $sha' \
  --arg sha "$(printf '' | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" "$base_input" >"$empty_input"
empty_request="$tmp/empty-request.json"
jq -S -c '.stage_request.content' "$empty_input" >"$empty_request"
empty_request_sha=$(sha_file "$empty_request")
jq -S -c --arg sha "$empty_request_sha" '.stage_request.sha256=$sha' "$empty_input" >"$tmp/empty-final.json"
source_digest=$(printf '%s\n' alpha beta | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
run_replay no-change "$tmp/empty-final.json" "$source_digest" >"$tmp/no-change.out"
jq -e '.state.phase=="review-wait" and .state.materialization.candidate_tree_id==.state.identity.source_tree_id' "$tmp/no-change.out" >/dev/null ||
  fail no-change
pass 'empty producer patch records a no-change candidate before review'

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
