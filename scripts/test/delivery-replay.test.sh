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
python_with_int_limit=$(command -v python3)
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
/bin/cp "$jq_bin" "$runtime/jq"
/bin/chmod 0555 "$runtime/jq"
jq_bin="$runtime/jq"
PATH="$runtime:/usr/bin:/bin"
export PATH
[ "$(command -v jq)" = "$runtime/jq" ] || fail 'private jq is not first on PATH'
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

printf '%s\n' '#!/bin/sh' "exec '$jq_bin' \"\$@\"" >"$tmp/jq-launcher"
/bin/chmod 0555 "$tmp/jq-launcher"
/bin/mkdir -m 700 "$tmp/launcher-state" "$tmp/launcher-candidate" "$tmp/launcher-scratch"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target \
  --source-git-dir "$tmp/source.git" --candidate-root "$tmp/launcher-candidate" --scratch-root "$tmp/launcher-scratch" \
  --state-dir "$tmp/launcher-state" --closure-helper "$runtime/object-closure" --jq-bin "$tmp/jq-launcher" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/launcher.out" 2>&1; then
  fail dependency-launcher
fi
grep -Fq 'delivery replay: dependency is not a native executable' "$tmp/launcher.out" ||
  fail dependency-launcher-error
[ ! -e "$tmp/launcher-state/run.json" ] || fail dependency-launcher-journal
python3 "$replay" --input "$base_input" --source-repository-id fixture.target \
  --source-git-dir "$tmp/source.git" --candidate-root "$tmp/launcher-candidate" --scratch-root "$tmp/launcher-scratch" \
  --state-dir "$tmp/launcher-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/launcher-retry.out"
jq -e '.state.phase=="review-wait"' "$tmp/launcher-retry.out" >/dev/null || fail dependency-launcher-retry
pass 'a corrected native dependency can reuse state after launcher rejection'

/bin/cp "$jq_bin" "$tmp/jq-noexec"
/bin/chmod 0444 "$tmp/jq-noexec"
/bin/mkdir -m 700 "$tmp/noexec-state" "$tmp/noexec-candidate" "$tmp/noexec-scratch"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target \
  --source-git-dir "$tmp/source.git" --candidate-root "$tmp/noexec-candidate" --scratch-root "$tmp/noexec-scratch" \
  --state-dir "$tmp/noexec-state" --closure-helper "$runtime/object-closure" --jq-bin "$tmp/jq-noexec" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/noexec.out" 2>&1; then
  fail dependency-noexec
fi
grep -Fq 'delivery replay: dependency is not executable' "$tmp/noexec.out" || fail dependency-noexec-error
[ ! -e "$tmp/noexec-state/run.json" ] && [ ! -e "$tmp/noexec-state/execution" ] || fail dependency-noexec-state
pass 'a non-executable native dependency is rejected before any snapshot grants it execute permission'


snapshot_interrupt_wrapper="$tmp/snapshot-interrupt.py"
printf '%s\n' \
  'import importlib.util, pathlib, sys' \
  'path, point, arguments = sys.argv[1], sys.argv[2], sys.argv[3:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
  'if point == "directory":' \
  '    original_mkdir = module.os.mkdir' \
  '    def interrupted_mkdir(target, *args, **kwargs):' \
  '        result = original_mkdir(target, *args, **kwargs)' \
  '        if pathlib.Path(target).name == ".execution-building": raise module.ReplayError("snapshot interrupted after directory creation")' \
  '        return result' \
  '    module.os.mkdir = interrupted_mkdir' \
  'else:' \
  '    original_atomic = module.atomic_bytes' \
  '    writes = {"count": 0}' \
  '    def interrupted_atomic(target, data):' \
  '        original_atomic(target, data)' \
  '        if ".execution-building" in pathlib.Path(target).parts:' \
  '            writes["count"] += 1' \
  '            if writes["count"] == 2: raise module.ReplayError("snapshot interrupted during copy")' \
  '    module.atomic_bytes = interrupted_atomic' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$snapshot_interrupt_wrapper"
for snapshot_point in directory copy; do
  mkdir -m 700 "$tmp/snapshot-$snapshot_point-state" "$tmp/snapshot-$snapshot_point-candidate" \
    "$tmp/snapshot-$snapshot_point-scratch"
  if python3 "$snapshot_interrupt_wrapper" "$replay" "$snapshot_point" \
    --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/snapshot-$snapshot_point-candidate" --scratch-root "$tmp/snapshot-$snapshot_point-scratch" \
    --state-dir "$tmp/snapshot-$snapshot_point-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/snapshot-$snapshot_point.out" 2>&1; then
    fail "snapshot-$snapshot_point-interrupt"
  fi
  [ ! -e "$tmp/snapshot-$snapshot_point-state/run.json" ] || fail "snapshot-$snapshot_point-journal"
  [ -d "$tmp/snapshot-$snapshot_point-state/.execution-building" ] || fail "snapshot-$snapshot_point-staging"
  python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/snapshot-$snapshot_point-candidate" --scratch-root "$tmp/snapshot-$snapshot_point-scratch" \
    --state-dir "$tmp/snapshot-$snapshot_point-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/snapshot-$snapshot_point-retry.out"
  jq -e '.state.phase=="review-wait"' "$tmp/snapshot-$snapshot_point-retry.out" >/dev/null ||
    fail "snapshot-$snapshot_point-retry"
done

mkdir -m 700 "$tmp/foreign-staging-state" "$tmp/foreign-staging-state/.execution-building" \
  "$tmp/foreign-staging-candidate" "$tmp/foreign-staging-scratch"
printf '%s\n' preserve >"$tmp/foreign-staging-state/.execution-building/sentinel"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/foreign-staging-candidate" --scratch-root "$tmp/foreign-staging-scratch" \
  --state-dir "$tmp/foreign-staging-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/foreign-staging.out" 2>&1; then
  fail foreign-staging
fi
[ "$(cat "$tmp/foreign-staging-state/.execution-building/sentinel")" = preserve ] || fail foreign-staging-preserved
mkdir -m 700 "$tmp/foreign-link-state" "$tmp/foreign-link-target" "$tmp/foreign-link-candidate" "$tmp/foreign-link-scratch"
printf '%s\n' preserve >"$tmp/foreign-link-target/sentinel"
ln -s "$tmp/foreign-link-target" "$tmp/foreign-link-state/.execution-building"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/foreign-link-candidate" --scratch-root "$tmp/foreign-link-scratch" \
  --state-dir "$tmp/foreign-link-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/foreign-link.out" 2>&1; then
  fail foreign-staging-link
fi
[ -L "$tmp/foreign-link-state/.execution-building" ] && \
  [ "$(cat "$tmp/foreign-link-target/sentinel")" = preserve ] || fail foreign-staging-link-preserved
pass 'transactional bundle recovery preserves foreign staging data and links'

run_replay changed "$base_input" "$expected_changed" >"$tmp/changed.out"
jq -e '.state.phase=="review-wait" and .authority=="none" and .offline_simulation==true' "$tmp/changed.out" >/dev/null ||
  fail missing-review-waits
request_sha=$(jq -r '.identity.request_sha256' "$tmp/changed-state/run.json")
candidate_tree=$(jq -r '.identity.candidate_tree_id' "$tmp/changed-state/run.json")
candidate_commit=$(jq -r '.identity.candidate_commit_id' "$tmp/changed-state/run.json")
moved_candidate=$(printf '%s\n' moved | /usr/bin/env -i HOME="$tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture \
  GIT_COMMITTER_EMAIL=fixture@example.invalid /usr/bin/git --git-dir="$tmp/changed-candidate/repository.git" \
  commit-tree "$candidate_tree" -p "$candidate_commit")
expect_candidate_move_rejected() {
  local phase=$1
  shift
  /usr/bin/git --git-dir="$tmp/changed-candidate/repository.git" update-ref refs/heads/candidate "$moved_candidate"
  if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
    --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
    --expected-sha256 "$expected_changed" "$@" >"$tmp/candidate-moved-$phase.out" 2>&1; then
    /usr/bin/git --git-dir="$tmp/changed-candidate/repository.git" update-ref refs/heads/candidate "$candidate_commit"
    fail "candidate-moved-$phase"
  fi
  /usr/bin/git --git-dir="$tmp/changed-candidate/repository.git" update-ref refs/heads/candidate "$candidate_commit"
  grep -Eq 'candidate repository no longer matches saved materialization|candidate repository identity guard failed' \
    "$tmp/candidate-moved-$phase.out" ||
    fail "candidate-moved-$phase-error"
}
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
  'import importlib.util, os, pathlib, signal, sys' \
  'path, arguments = sys.argv[1], sys.argv[2:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
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

mkdir -m 700 "$tmp/repeated-kill-state" "$tmp/repeated-kill-candidate" "$tmp/repeated-kill-scratch"
for kill_round in 1 2 3; do
  if python3 "$kill_wrapper" "$replay" --input "$base_input" --source-repository-id fixture.target \
    --source-git-dir "$tmp/source.git" --candidate-root "$tmp/repeated-kill-candidate" \
    --scratch-root "$tmp/repeated-kill-scratch" --state-dir "$tmp/repeated-kill-state" \
    --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
    --expected-sha256 "$expected_changed" >"$tmp/repeated-kill-$kill_round.out" 2>&1; then
    fail "repeated-kill-$kill_round"
  fi
  [ "$(find "$tmp/repeated-kill-state" -maxdepth 1 -type d -name 'execution*' | wc -l | tr -d ' ')" = 1 ] ||
    fail "repeated-kill-snapshot-count-$kill_round"
done
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/repeated-kill-candidate" --scratch-root "$tmp/repeated-kill-scratch" \
  --state-dir "$tmp/repeated-kill-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/repeated-kill-resume.out"
jq -e '.state.phase=="review-wait"' "$tmp/repeated-kill-resume.out" >/dev/null || fail repeated-kill-resume
pass 'repeated SIGKILL recovery reuses one bounded execution bundle'

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

group_interrupt_wrapper="$tmp/materialization-group-interrupt.py"
printf '%s\n' \
  'import importlib.util, os, pathlib, signal, sys' \
  'path, point, signal_name, arguments = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]' \
  'os.setsid()' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
  'original = module.run_materializer' \
  'def interrupt_materialization(*args, **kwargs):' \
  '    if point == "before":' \
  '        os.killpg(os.getpgrp(), getattr(signal, signal_name))' \
  '        raise module.ReplayError("materialization did not complete")' \
  '    original(*args, **kwargs)' \
  '    os.killpg(os.getpgrp(), getattr(signal, signal_name))' \
  '    raise module.ReplayError("materialization did not complete")' \
  'def interrupt_verification(*_args, **_kwargs):' \
  '    os.killpg(os.getpgrp(), getattr(signal, signal_name))' \
  '    raise module.ReplayError("fixed verifier could not read the candidate blob")' \
  'if point == "verify":' \
  '    module.verify_candidate = interrupt_verification' \
  'else:' \
  '    module.run_materializer = interrupt_materialization' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$group_interrupt_wrapper"
for interrupt_case in before after verify; do
  if [ "$interrupt_case" = after ]; then interrupt_signal=SIGTERM; else interrupt_signal=SIGINT; fi
  mkdir -m 700 "$tmp/group-$interrupt_case-state" "$tmp/group-$interrupt_case-candidate" \
    "$tmp/group-$interrupt_case-scratch"
  if python3 "$group_interrupt_wrapper" "$replay" "$interrupt_case" "$interrupt_signal" \
    --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/group-$interrupt_case-candidate" --scratch-root "$tmp/group-$interrupt_case-scratch" \
    --state-dir "$tmp/group-$interrupt_case-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/group-$interrupt_case.out"; then
    fail "group-$interrupt_case-status"
  else
    interrupt_status=$?
  fi
  [ "$interrupt_status" -eq 75 ] || fail "group-$interrupt_case-code"
  if [ "$interrupt_case" = before ]; then
    expected_interrupt_phase=materializing
    [ ! -e "$tmp/group-$interrupt_case-candidate/repository.git" ] || fail group-before-effect
  else
    if [ "$interrupt_case" = after ]; then expected_interrupt_phase=materializing; else expected_interrupt_phase=verifying; fi
    [ -d "$tmp/group-$interrupt_case-candidate/repository.git" ] || fail group-after-candidate
  fi
  jq -e --arg phase "$expected_interrupt_phase" '.phase==$phase' \
    "$tmp/group-$interrupt_case-state/run.json" >/dev/null || fail "group-$interrupt_case-state"
  python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/group-$interrupt_case-candidate" --scratch-root "$tmp/group-$interrupt_case-scratch" \
    --state-dir "$tmp/group-$interrupt_case-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/group-$interrupt_case-resume.out"
  jq -e '.state.phase=="review-wait"' "$tmp/group-$interrupt_case-resume.out" >/dev/null ||
    fail "group-$interrupt_case-resume"
done
pass 'process-group cancellation during materialization or verification resumes the same attempt'

for tree_case in numeric list null; do
  case "$tree_case" in
    numeric) tree_value=123 ;;
    list) tree_value='[]' ;;
    null) tree_value=null ;;
  esac
  "$jq_bin" -S -c "(.stage_request.content.body.operation.arguments.source_tree_input_id) as \$id |
    (.stage_request.content.body.inputs[] | select(.input_id == \$id) |
    .value.value.value.object_id) = $tree_value" "$base_input" >"$tmp/$tree_case-tree.json"
  mkdir -m 700 "$tmp/$tree_case-tree-state" "$tmp/$tree_case-tree-candidate" "$tmp/$tree_case-tree-scratch"
  if python3 "$replay" --input "$tmp/$tree_case-tree.json" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
    --candidate-root "$tmp/$tree_case-tree-candidate" --scratch-root "$tmp/$tree_case-tree-scratch" \
    --state-dir "$tmp/$tree_case-tree-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
    --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/$tree_case-tree.out" 2>&1; then
    fail "$tree_case-source-tree"
  fi
  if ! grep -Fq 'delivery replay: materialization input tree identity is invalid' "$tmp/$tree_case-tree.out" ||
     grep -Fq Traceback "$tmp/$tree_case-tree.out"; then
    fail "$tree_case-source-tree-error"
  fi
done
pass 'non-string source tree identities fail without a traceback'

for identity_field in commit_id hash_algorithm; do
  case "$identity_field" in
    commit_id) identity_error='materialization input commit identity is invalid' ;;
    hash_algorithm) identity_error='materialization input hash algorithm is invalid' ;;
  esac
  for identity_case in numeric list null; do
    case "$identity_case" in
      numeric) identity_value=1111111111111111111111111111111111111111 ;;
      list) identity_value='[]' ;;
      null) identity_value=null ;;
    esac
    "$jq_bin" -S -c ".stage_request.content.body.target_revision.value.$identity_field = $identity_value" \
      "$base_input" >"$tmp/$identity_field-$identity_case.json"
    mkdir -m 700 "$tmp/$identity_field-$identity_case-state" "$tmp/$identity_field-$identity_case-candidate" \
      "$tmp/$identity_field-$identity_case-scratch"
    if python3 "$replay" --input "$tmp/$identity_field-$identity_case.json" --source-repository-id fixture.target \
      --source-git-dir "$tmp/source.git" --candidate-root "$tmp/$identity_field-$identity_case-candidate" \
      --scratch-root "$tmp/$identity_field-$identity_case-scratch" --state-dir "$tmp/$identity_field-$identity_case-state" \
      --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
      --expected-sha256 "$expected_changed" >"$tmp/$identity_field-$identity_case.out" 2>&1; then
      fail "$identity_field-$identity_case"
    fi
    [ ! -e "$tmp/$identity_field-$identity_case-state/run.json" ] || fail "$identity_field-$identity_case-journal"
    grep -Fq "delivery replay: $identity_error" \
      "$tmp/$identity_field-$identity_case.out" || fail "$identity_field-$identity_case-error"
  done
done
pass 'non-string commit and hash-algorithm identities are rejected before journaling'

mkdir -m 700 "$tmp/caller-execution-root" "$tmp/caller-execution-state" \
  "$tmp/caller-execution-candidate" "$tmp/caller-execution-scratch"
printf '%s\n' keep >"$tmp/caller-execution-root/sentinel"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/caller-execution-candidate" --scratch-root "$tmp/caller-execution-scratch" \
  --state-dir "$tmp/caller-execution-state" --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" \
  --verify-path source.txt --expected-sha256 "$expected_changed" \
  --execution-root "$tmp/caller-execution-root" >"$tmp/caller-execution.out" 2>&1; then
  fail caller-execution-root
fi
[ "$(cat "$tmp/caller-execution-root/sentinel")" = keep ] || fail caller-execution-root-deleted
grep -Fq 'unrecognized arguments: --execution-root' "$tmp/caller-execution.out" ||
  fail caller-execution-root-error
pass 'the replay CLI has no caller-selected execution-root path'

huge_integer=$(printf '1%.0s' {1..5000})
printf '{"huge":%s}\n' "$huge_integer" >"$tmp/huge-input.json"
mkdir -m 700 "$tmp/huge-input-state" "$tmp/huge-input-candidate" "$tmp/huge-input-scratch"
if PYTHONINTMAXSTRDIGITS=4300 "$python_with_int_limit" "$replay" --input "$tmp/huge-input.json" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/huge-input-candidate" --scratch-root "$tmp/huge-input-scratch" --state-dir "$tmp/huge-input-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/huge-input.out" 2>&1; then fail huge-integer-input; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/huge-input.out" ||
   grep -Fq Traceback "$tmp/huge-input.out"; then
  fail huge-integer-input-error
fi
printf '{"huge":%s}\n' "$huge_integer" >"$tmp/huge-observation.json"
if PYTHONINTMAXSTRDIGITS=4300 "$python_with_int_limit" "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/reconcile-candidate" --scratch-root "$tmp/reconcile-scratch" --state-dir "$tmp/reconcile-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/huge-observation.json" >"$tmp/huge-observation.out" 2>&1; then fail huge-integer-observation; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/huge-observation.out" ||
   grep -Fq Traceback "$tmp/huge-observation.out"; then
  fail huge-integer-observation-error
fi
mkdir -m 700 "$tmp/huge-journal-state" "$tmp/huge-journal-candidate" "$tmp/huge-journal-scratch"
printf '{"huge":%s}\n' "$huge_integer" >"$tmp/huge-journal-state/run.json"
if PYTHONINTMAXSTRDIGITS=4300 "$python_with_int_limit" "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/huge-journal-candidate" --scratch-root "$tmp/huge-journal-scratch" --state-dir "$tmp/huge-journal-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/huge-journal.out" 2>&1; then fail huge-integer-journal; fi
if ! grep -Fq 'delivery replay: input is not JSON' "$tmp/huge-journal.out" ||
   grep -Fq Traceback "$tmp/huge-journal.out"; then
  fail huge-integer-journal-error
fi
pass 'huge JSON integers in input, observation, and journal fail without a traceback'

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
expect_candidate_move_rejected review-wait --review-observation "$tmp/review.json"
lock_holder="$tmp/lock-holder.py"
printf '%s\n' \
  'import fcntl, pathlib, sys, time' \
  'lock_path, ready, release = map(pathlib.Path, sys.argv[1:])' \
  'with lock_path.open("a+b") as lock:' \
  '    fcntl.flock(lock, fcntl.LOCK_EX)' \
  '    ready.write_text("ready")' \
  '    while not release.exists(): time.sleep(0.01)' >"$lock_holder"
lock_wrapper="$tmp/lock-replay.py"
printf '%s\n' \
  'import importlib.util, pathlib, sys' \
  'path, marker, arguments = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
  'original = module.fcntl.flock' \
  'def marked_flock(*args, **kwargs):' \
  '    marker.write_text("waiting")' \
  '    return original(*args, **kwargs)' \
  'module.fcntl.flock = marked_flock' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$lock_wrapper"
mkdir -m 700 "$tmp/lock-state"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/lock-state/"
python3 "$lock_holder" "$tmp/lock-state/replay.lock" "$tmp/lock-ready" "$tmp/lock-release" &
lock_holder_pid=$!
while [ ! -f "$tmp/lock-ready" ]; do sleep 0.01; done
python3 "$lock_wrapper" "$replay" "$tmp/lock-waiting" \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/lock-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --review-observation "$tmp/review.json" >"$tmp/lock-cancel.out" &
lock_replay_pid=$!
while [ ! -f "$tmp/lock-waiting" ]; do sleep 0.01; done
kill -TERM "$lock_replay_pid"
touch "$tmp/lock-release"
wait "$lock_holder_pid"
if wait "$lock_replay_pid"; then fail lock-cancel-status; else lock_status=$?; fi
[ "$lock_status" -eq 75 ] || fail lock-cancel-code
jq -e '(.phase=="review-wait") and (has("review")|not)' "$tmp/lock-state/run.json" >/dev/null ||
  fail lock-cancel-state

observation_wrapper="$tmp/observation-interrupt.py"
printf '%s\n' \
  'import importlib.util, os, pathlib, signal, sys' \
  'path, signal_name, arguments = sys.argv[1], sys.argv[2], sys.argv[3:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
  'original = module.observation' \
  'def interrupt_after_observation(*args, **kwargs):' \
  '    result = original(*args, **kwargs)' \
  '    os.kill(os.getpid(), getattr(signal, signal_name))' \
  '    return result' \
  'module.observation = interrupt_after_observation' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$observation_wrapper"
mkdir -m 700 "$tmp/review-cancel-state"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/review-cancel-state/"
if python3 "$observation_wrapper" "$replay" SIGINT \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/review-cancel-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --review-observation "$tmp/review.json" >"$tmp/review-cancel.out"; then
  fail review-cancel-status
else
  review_cancel_status=$?
fi
[ "$review_cancel_status" -eq 75 ] || fail review-cancel-code
jq -e '(.phase=="review-wait") and (has("review")|not)' "$tmp/review-cancel-state/run.json" >/dev/null ||
  fail review-cancel-state
printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_review_observation","actor_id":123,"request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","verdict":"clean"}' >"$tmp/numeric-review.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/numeric-review.json" >"$tmp/numeric-review.out" 2>&1; then fail numeric-review-actor; fi
grep -Fq 'offline observation actor is invalid' "$tmp/numeric-review.out" || fail numeric-review-actor-error
pass 'offline observations require a string actor identity'
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --review-observation "$tmp/review.json" >"$tmp/publish-wait.out"
jq -e '.state.phase=="publish-wait"' "$tmp/publish-wait.out" >/dev/null || fail missing-publisher-waits
expect_candidate_move_rejected publish-wait --publisher-observation "$tmp/publisher.json"
git_clean --git-dir="$tmp/changed-candidate/repository.git" update-ref refs/heads/alternate "$candidate_commit"
git_clean --git-dir="$tmp/changed-candidate/repository.git" symbolic-ref refs/heads/candidate refs/heads/alternate
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/candidate-symref.out" 2>&1; then
  fail candidate-symref
fi
git_clean --git-dir="$tmp/changed-candidate/repository.git" symbolic-ref --delete refs/heads/candidate
git_clean --git-dir="$tmp/changed-candidate/repository.git" update-ref refs/heads/candidate "$candidate_commit"
git_clean --git-dir="$tmp/changed-candidate/repository.git" update-ref -d refs/heads/alternate
grep -Fq 'candidate repository identity guard failed' "$tmp/candidate-symref.out" || fail candidate-symref-error
pass 'candidate completion guard rejects a symbolic candidate ref'
mkdir -m 700 "$tmp/publish-cancel-state"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/publish-cancel-state/"
if python3 "$observation_wrapper" "$replay" SIGTERM \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/publish-cancel-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/publish-cancel.out"; then
  fail publish-cancel-status
else
  publish_cancel_status=$?
fi
[ "$publish_cancel_status" -eq 75 ] || fail publish-cancel-code
jq -e '(.phase=="publish-wait") and (has("publisher")|not)' "$tmp/publish-cancel-state/run.json" >/dev/null ||
  fail publish-cancel-state
pass 'SIGTERM at the lock and SIGINT or SIGTERM after wait observations do not advance state'

atomic_wrapper="$tmp/atomic-candidate-observation.py"
printf '%s\n' \
  'import importlib.util, os, pathlib, signal, subprocess, sys' \
  'path, mode, marker, moved, arguments = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3]), sys.argv[4], sys.argv[5:]' \
  'spec = importlib.util.spec_from_file_location("replay", path)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(path).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, path, "exec"), module.__dict__)' \
  'original = module.observation' \
  'def act_during_publisher(*args, **kwargs):' \
  '    result = original(*args, **kwargs)' \
  '    if args[1] == "delivery_replay_publisher_observation":' \
  '        if mode == "move":' \
  '            candidate = pathlib.Path(arguments[arguments.index("--candidate-root") + 1]) / "repository.git"' \
  '            attempt = subprocess.run(["/usr/bin/git", f"--git-dir={candidate}", "-c", "core.hooksPath=/dev/null", "update-ref", "refs/heads/candidate", moved], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)' \
  '            marker.write_text(str(attempt.returncode))' \
  '        else:' \
  '            os.kill(os.getpid(), signal.SIGKILL)' \
  '    return result' \
  'module.observation = act_during_publisher' \
  'sys.argv = [path] + arguments' \
  'raise SystemExit(module.main())' >"$atomic_wrapper"
mkdir -m 700 "$tmp/atomic-move-state"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/atomic-move-state/"
python3 "$atomic_wrapper" "$replay" move "$tmp/atomic-move-status" "$moved_candidate" \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/atomic-move-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/atomic-move.out"
jq -e '.state.phase=="completed-offline"' "$tmp/atomic-move.out" >/dev/null || fail atomic-move-completion
[ "$(cat "$tmp/atomic-move-status")" != 0 ] || fail atomic-move-lock
[ "$(git_clean --git-dir="$tmp/changed-candidate/repository.git" rev-parse refs/heads/candidate)" = "$candidate_commit" ] ||
  fail atomic-move-ref

mkdir -m 700 "$tmp/atomic-kill-state"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/atomic-kill-state/"
if python3 "$atomic_wrapper" "$replay" kill "$tmp/unused-kill-status" "$moved_candidate" \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/atomic-kill-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/atomic-kill.out" 2>&1; then
  fail atomic-kill-status
fi
atomic_lock="$tmp/changed-candidate/repository.git/refs/heads/candidate.lock"
atomic_wait=0
while [ -e "$atomic_lock" ]; do
  atomic_wait=$((atomic_wait + 1))
  [ "$atomic_wait" -le 100 ] || fail atomic-kill-lock-release
  sleep 0.01
done
python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/atomic-kill-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/atomic-kill-resume.out"
jq -e '.state.phase=="completed-offline"' "$tmp/atomic-kill-resume.out" >/dev/null || fail atomic-kill-resume
pass 'candidate ref guard blocks publisher-time moves and releases after SIGKILL'

mkdir -m 700 "$tmp/git-env-state" "$tmp/git-env-hooks" "$tmp/git-env-work-tree"
cp "$tmp/changed-state/materialization-input.json" "$tmp/changed-state/run.json" "$tmp/git-env-state/"
printf '%s\n' '#!/bin/sh' "printf hook >'$tmp/git-env-hook-ran'" >"$tmp/git-env-hooks/reference-transaction"
/bin/chmod 0555 "$tmp/git-env-hooks/reference-transaction"
printf '%s\n' '[core]' "hooksPath = $tmp/git-env-hooks" >"$tmp/git-env-global"
git_clean init -q --bare "$tmp/git-env-other.git"
/usr/bin/env GIT_NAMESPACE=poison GIT_COMMON_DIR="$tmp/git-env-other.git" GIT_DIR="$tmp/git-env-other.git" \
  GIT_WORK_TREE="$tmp/git-env-work-tree" GIT_CONFIG_NOSYSTEM=0 GIT_CONFIG_GLOBAL="$tmp/git-env-global" \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$tmp/git-env-hooks" \
  python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/git-env-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --publisher-observation "$tmp/publisher.json" >"$tmp/git-env.out"
jq -e '.state.phase=="completed-offline"' "$tmp/git-env.out" >/dev/null || fail git-env-completion
[ ! -e "$tmp/git-env-hook-ran" ] || fail git-env-hook
[ "$(git_clean --git-dir="$tmp/changed-candidate/repository.git" rev-parse refs/heads/candidate)" = "$candidate_commit" ] ||
  fail git-env-candidate
pass 'all candidate Git operations ignore ambient repository, namespace, config, work-tree, and hook settings'
printf '%s\n' '{"schema_version":1,"kind":"delivery_replay_publisher_observation","actor_id":123,"request_sha256":"'"$request_sha"'","candidate_tree_id":"'"$candidate_tree"'","disposition":"offline-simulated"}' >"$tmp/numeric-publisher.json"
if python3 "$replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/changed-candidate" --scratch-root "$tmp/changed-scratch" --state-dir "$tmp/changed-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  --publisher-observation "$tmp/numeric-publisher.json" >"$tmp/numeric-publisher.out" 2>&1; then fail numeric-publisher-actor; fi
grep -Fq 'offline observation actor is invalid' "$tmp/numeric-publisher.out" || fail numeric-publisher-actor-error
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
for candidate_phase in verifying review-wait publish-wait completed-offline; do
  expect_malformed_state "missing-candidate-commit-$candidate_phase" \
    "(.phase=\"$candidate_phase\") | del(.identity.candidate_commit_id)"
  expect_malformed_state "missing-candidate-tree-$candidate_phase" \
    "(.phase=\"$candidate_phase\") | del(.identity.candidate_tree_id)"
done
expect_malformed_state mismatched-candidate-commit \
  '(.phase="verifying") | .identity.candidate_commit_id="0000000000000000000000000000000000000000"'
expect_malformed_state mismatched-candidate-tree \
  '(.phase="completed-offline") | .identity.candidate_tree_id="0000000000000000000000000000000000000000"'
expect_malformed_state numeric-review-actor '.review.actor_id=123'
expect_malformed_state numeric-publisher-actor \
  '(.phase="completed-offline") | .publisher={"actor_id":123,"disposition":"offline-simulated","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}'
for verification_phase in review-wait publish-wait completed-offline; do
  expect_malformed_state "verification-id-$verification_phase" \
    "(.phase=\"$verification_phase\") | .verification.id=\"delivery.other.v1\""
  expect_malformed_state "verification-path-$verification_phase" \
    "(.phase=\"$verification_phase\") | .verification.path=\"other.txt\""
  expect_malformed_state "verification-sha-$verification_phase" \
    "(.phase=\"$verification_phase\") | .verification.sha256=\"0000000000000000000000000000000000000000000000000000000000000000\""
done
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
expect_candidate_move_rejected completed-offline
pass 'review, publish, and completed waits reject a moved same-tree candidate ref'
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

package_root="$tmp/replay-package"
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$root/scripts/core-contract.sh")
/bin/mkdir -p "$package_root/delivery/v1" "$package_root/adapters/local-git-materializer/v1" \
  "$package_root/scripts" "$package_root/core/v2/generations"
/bin/cp "$replay" "$package_root/delivery/v1/replay.py"
/bin/cp "$root/adapters/local-git-materializer/v1/materialize.sh" \
  "$root/adapters/local-git-materializer/v1/protocol.jq" \
  "$package_root/adapters/local-git-materializer/v1/"
/bin/cp "$root/scripts/core-contract.sh" "$package_root/scripts/core-contract.sh"
/bin/cp "$root/core/v2/generation-registry.json" "$package_root/core/v2/generation-registry.json"
/bin/cp -R "$root/core/v2/generations/$generation" "$package_root/core/v2/generations/"
package_replay="$package_root/delivery/v1/replay.py"
/bin/mkdir -m 700 "$tmp/package-state" "$tmp/package-candidate" "$tmp/package-scratch"
python3 "$package_replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/package-candidate" --scratch-root "$tmp/package-scratch" --state-dir "$tmp/package-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/package-first.out"
printf '\n' >>"$package_root/adapters/local-git-materializer/v1/protocol.jq"
if python3 "$package_replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/package-candidate" --scratch-root "$tmp/package-scratch" --state-dir "$tmp/package-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/package-dependency-stale.out"; then fail changed-package-dependency; fi
jq -e '.state.phase=="stale"' "$tmp/package-dependency-stale.out" >/dev/null || fail changed-package-dependency-state
/bin/cp "$root/adapters/local-git-materializer/v1/protocol.jq" \
  "$package_root/adapters/local-git-materializer/v1/protocol.jq"
printf '\n' >>"$package_replay"
if python3 "$package_replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/package-candidate" --scratch-root "$tmp/package-scratch" --state-dir "$tmp/package-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt --expected-sha256 "$expected_changed" \
  >"$tmp/package-driver-stale.out"; then fail changed-replay-driver; fi
jq -e '.state.phase=="stale"' "$tmp/package-driver-stale.out" >/dev/null || fail changed-replay-driver-state
pass 'changed executable package or replay driver cannot reuse a prior run'

/bin/cp "$replay" "$package_replay"
/bin/cp "$root/adapters/local-git-materializer/v1/protocol.jq" \
  "$package_root/adapters/local-git-materializer/v1/protocol.jq"
printf '%s\n' keep >"$package_root/sentinel"
if python3 "$package_replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/package-candidate" --scratch-root "$tmp/package-scratch" --state-dir "$tmp/package-state" \
  --closure-helper "$runtime/object-closure" --jq-bin "$jq_bin" --verify-path source.txt \
  --expected-sha256 "$expected_changed" --execution-root "$package_root" >"$tmp/copied-root-bypass.out" 2>&1; then
  fail copied-root-bypass
fi
grep -Fq 'unrecognized arguments: --execution-root' "$tmp/copied-root-bypass.out" || fail copied-root-bypass-error
[ "$(cat "$package_root/sentinel")" = keep ] || fail copied-root-bypass-deleted
pass 'a copied expected layout cannot select or delete an execution root'

driver_wrapper="$tmp/driver-identity.py"
printf '%s\n' \
  'import hashlib, importlib.util, pathlib, sys' \
  'driver = pathlib.Path(sys.argv[1])' \
  'saved = driver.read_bytes()' \
  'spec = importlib.util.spec_from_file_location("replay", driver)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = saved' \
  'exec(compile(saved, str(driver), "exec"), module.__dict__)' \
  'assert module.driver_identity() == hashlib.sha256(saved).hexdigest()' \
  'for changed in (saved + b"\n# comment after load\n", saved + b"\n\n", saved + b"\nCHANGED_EXECUTABLE_STATEMENT = True\n", saved + b"\n\\xff\n"):' \
  '    driver.write_bytes(changed)' \
  '    assert module.driver_identity() == hashlib.sha256(saved).hexdigest()' \
  'driver.write_bytes(saved)' >"$driver_wrapper"
python3 "$driver_wrapper" "$package_replay" || fail driver-loaded-identity
pass 'driver identity remains bound to the exact source buffer loaded once'

/bin/cp "$runtime/object-closure" "$tmp/race-object-closure"
/bin/cp "$jq_bin" "$tmp/race-jq"
/bin/chmod 0555 "$tmp/race-object-closure" "$tmp/race-jq"
race_wrapper="$tmp/snapshot-race.py"
printf '%s\n' \
  'import argparse, importlib.util, pathlib, stat, sys' \
  'driver, repository, state_dir, helper, jq_bin, *arguments = sys.argv[1:]' \
  'spec = importlib.util.spec_from_file_location("replay", driver)' \
  'module = importlib.util.module_from_spec(spec)' \
  'module._REPLAY_DRIVER_BYTES = pathlib.Path(driver).read_bytes()' \
  'exec(compile(module._REPLAY_DRIVER_BYTES, driver, "exec"), module.__dict__)' \
  'value = lambda name: arguments[arguments.index(name) + 1]' \
  'values = argparse.Namespace(input=value("--input"), source_repository_id=value("--source-repository-id"), source_git_dir=value("--source-git-dir"), candidate_root=value("--candidate-root"), scratch_root=value("--scratch-root"), state_dir=value("--state-dir"), closure_helper=helper, jq_bin=jq_bin, verify_path=value("--verify-path"), expected_sha256=value("--expected-sha256"), review_observation=None, publisher_observation=None)' \
  'module.create_execution_snapshot(pathlib.Path(repository), values, pathlib.Path(state_dir))' \
  'targets = [pathlib.Path(repository) / "adapters/local-git-materializer/v1/protocol.jq", pathlib.Path(helper), pathlib.Path(jq_bin)]' \
  'saved = [target.read_bytes() for target in targets]' \
  'modes = [stat.S_IMODE(target.stat().st_mode) for target in targets]' \
  'try:' \
  '    for target in targets:' \
  '        target.chmod(0o700)' \
  '        target.write_bytes(b"replaced after execution snapshot\n")' \
  '    try:' \
  '        module.replay_locked(values, pathlib.Path(state_dir))' \
  '    except module.ReplayError as error:' \
  '        assert "execution bundle does not match current dependencies" in str(error)' \
  '    else:' \
  '        raise AssertionError("changed execution sources were accepted")' \
  'finally:' \
  '    for target, data, mode in zip(targets, saved, modes):' \
  '        target.write_bytes(data)' \
  '        target.chmod(mode)' >"$race_wrapper"
/bin/mkdir -m 700 "$tmp/race-state" "$tmp/race-candidate" "$tmp/race-scratch"
driver_sha=$(sha_file "$package_replay")
package_sha=$(sha_file "$package_root/adapters/local-git-materializer/v1/protocol.jq")
helper_sha=$(sha_file "$tmp/race-object-closure")
jq_sha=$(sha_file "$tmp/race-jq")
python3 "$race_wrapper" "$package_replay" "$package_root" "$tmp/race-state" \
  "$tmp/race-object-closure" "$tmp/race-jq" \
  --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/race-candidate" --scratch-root "$tmp/race-scratch" --state-dir "$tmp/race-state" \
  --closure-helper "$tmp/race-object-closure" --jq-bin "$tmp/race-jq" \
  --verify-path source.txt --expected-sha256 "$expected_changed"
python3 "$package_replay" --input "$base_input" --source-repository-id fixture.target --source-git-dir "$tmp/source.git" \
  --candidate-root "$tmp/race-candidate" --scratch-root "$tmp/race-scratch" --state-dir "$tmp/race-state" \
  --closure-helper "$tmp/race-object-closure" --jq-bin "$tmp/race-jq" \
  --verify-path source.txt --expected-sha256 "$expected_changed" >"$tmp/race.out"
jq -e '.state.phase=="review-wait" and
  .state.identity.driver_sha256==$driver and
  .state.identity.materializer_package.files["adapters/local-git-materializer/v1/protocol.jq"]==$package and
  .state.identity.closure_helper_sha256==$helper and .state.identity.jq_sha256==$jq' \
  --arg driver "$driver_sha" --arg package "$package_sha" --arg helper "$helper_sha" --arg jq "$jq_sha" \
  "$tmp/race.out" >/dev/null || fail immutable-execution-snapshot
pass 'the one state-owned execution bundle rejects drift and records its exact bytes'

printf 'delivery replay: %s focused checks passed\n' "$passed"
