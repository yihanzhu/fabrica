#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

test_root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
runner="$test_root/adapter-tests/v1/runner.sh"
inventory="$test_root/adapter-tests/v1/inventory.json"
fixture_builder="$test_root/scripts/test/portable-profile-resolution-fixtures.sh"
resolver_runtime="$test_root/resolver/v1/profile-resolve-runtime.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-adapter-contracts.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
download=''

cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then
    /bin/rm -f -- "$download"
  fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT

fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass_count=0
pass() { pass_count=$((pass_count + 1)); /usr/bin/printf 'ok %s - %s\n' "$pass_count" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; compiler=/usr/bin/clang ;;
  Linux:x86_64) jq_asset=jq-linux64; compiler=/usr/bin/cc ;;
  *) fail "unsupported host $platform" ;;
esac
case "$jq_asset" in
  jq-osx-amd64) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" \
    -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
[ "$(sha_file "$jq_cache")" = "$jq_sha" ] || fail 'jq digest'
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
if [ "$platform" = Linux:x86_64 ]; then
  /bin/cp /usr/bin/awk "$bin/awk"
else
  /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' > "$bin/awk"
fi
/bin/chmod 0555 "$bin/awk"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$test_root/resolver/v1/nofollow-snapshot.c" -o "$bin/nofollow-snapshot"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$test_root/scripts/test/portable-profile-resolution-launcher.c" -o "$bin/launcher"
pass 'fixed resolver launcher and dependencies built'

fixture="$tmp/garden-fixture"
/bin/mkdir -m 700 "$fixture" "$fixture/cells" "$fixture/scratch" "$fixture/target"
/bin/cp "$test_root/adapter-tests/v1/fixture/source.txt" "$fixture/target/source.txt"
git_home="$tmp/git-home"
/bin/mkdir -m 700 "$git_home"
fixture_git() {
  /usr/bin/env -i HOME="$git_home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}
/usr/bin/env -i HOME="$git_home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_DEFAULT_HASH=sha256 \
  /usr/bin/git -c init.defaultObjectFormat=sha256 init -q --object-format=sha1 "$fixture/target"
[ "$(fixture_git -C "$fixture/target" rev-parse --show-object-format)" = sha1 ] ||
  fail 'explicit target SHA-1 format'
fixture_git -C "$fixture/target" config user.name fixture
fixture_git -C "$fixture/target" config user.email fixture@example.invalid
fixture_git -C "$fixture/target" add source.txt
fixture_git -C "$fixture/target" commit -q -m fixture
pass 'hostile defaults cannot override explicit target SHA-1'

for cell in aa ab ba bb; do
  cell_root="$fixture/cells/$cell"
  PATH="$bin:/usr/bin:/bin" "$fixture_builder" "$cell_root" "$jq_bin" "$cell" >/dev/null
  /bin/mkdir -m 700 "$cell_root/resolver-sandbox"
  YSTACK_TEST_SANDBOX="$cell_root/resolver-sandbox" \
    "$bin/launcher" resolve "$resolver_runtime" "$bin/nofollow-snapshot" \
    "$jq_bin" "$cell_root/request.json" "$cell_root/map.json" > "$cell_root/resolved.json"
done
pass 'four honest profile variants resolved through the inactive resolver'

"$jq_bin" -S -c -n --arg root "$fixture" '
  {version:1,repositories:
    ([{cell_id:"shared",repository_id:"fixture.target",root:($root+"/target")}] +
     (["aa","ab","ba","bb"] |
      map(. as $cell | ["assets","manifests","profile"] |
        map(. as $repo | {cell_id:$cell,repository_id:("repo."+$repo),
          root:($root+"/cells/"+$cell+"/"+$repo)})) | add))}
' > "$fixture/repository-map.json"

fingerprint_before=$(fixture_git -C "$fixture/target" rev-parse 'HEAD^{tree}')
output="$tmp/observation.json"
error="$tmp/observation.stderr"
GH_TOKEN=must-not-leak AWS_SECRET_ACCESS_KEY=must-not-leak SSH_AUTH_SOCK=/must/not/leak \
  PATH="$bin:/usr/bin:/bin" "$runner" "$inventory" "$fixture" > "$output" 2> "$error" || {
  /bin/cat "$error" >&2
  fail 'accepted matrix run'
}
[ ! -s "$error" ] || fail 'success diagnostics'
"$jq_bin" -e '
  .schema_version == 1 and .kind == "adapter_contract_observation" and
  (.cells | length) == 4 and (.negative_observations | length) == 10 and
  ([.cells[].projection] | unique | length) == 1 and
  ([.cells[].provenance.profile_sha256] | unique | length) == 4 and
  (.non_claims | index("external-target-smoke") != null) and
  (.non_claims | index("network-isolation") != null) and
  (.inventory_acceptance_ref.authorization_comment_id == 5476938197)
' "$output" >/dev/null || fail 'observation shape and equivalence'
[ "$fingerprint_before" = "$(fixture_git -C "$fixture/target" rev-parse 'HEAD^{tree}')" ] ||
  fail 'target changed'
[ -z "$(find "$fixture/scratch" -mindepth 1 -print -quit)" ] || fail 'scratch cleanup'
/usr/bin/grep -Fq 'moon-garden' "$fixture/target/source.txt" || fail 'unrelated target fixture'
pass '2x2 projection, provenance, environment, Git truth, and cleanup'

expect_failure() {
  local name=$1
  local expected=$2
  local chosen_inventory=${3:-$inventory}
  local case_out="$tmp/$name.out"
  local case_err="$tmp/$name.err"
  if PATH="$bin:/usr/bin:/bin" "$runner" "$chosen_inventory" "$fixture" \
      > "$case_out" 2> "$case_err"; then
    fail "$name accepted"
  fi
  [ ! -s "$case_out" ] && [ "$(/bin/cat "$case_err")" = "$expected" ] ||
    fail "$name error"
  pass "$name"
}

for mutation in dropped duplicated relabelled mutated; do
  changed="$tmp/inventory-$mutation.json"
  case "$mutation" in
    dropped) filter='del(.cases[0])' ;;
    duplicated) filter='.cases += [.cases[0]]' ;;
    relabelled) filter='.cases[0].case_id = "matrix-zz"' ;;
    mutated) filter='.cases[0].assertions[0] = "different"' ;;
  esac
  "$jq_bin" -S -c "$filter" "$inventory" > "$changed"
  expect_failure "inventory-$mutation" E_INVENTORY "$changed"
done

map_saved="$tmp/repository-map.saved"
/bin/cp "$fixture/repository-map.json" "$map_saved"
"$jq_bin" -S -c '.repositories[1].root = .repositories[0].root' \
  "$map_saved" > "$fixture/repository-map.json"
expect_failure mapping-mismatch E_MAPPING
/bin/cp "$map_saved" "$fixture/repository-map.json"

/usr/bin/printf '%s\n' /invalid/alternate > "$fixture/target/.git/objects/info/alternates"
expect_failure git-alternates E_GIT
/bin/rm "$fixture/target/.git/objects/info/alternates"

resolved_saved="$tmp/resolved.saved"
/bin/cp "$fixture/cells/aa/resolved.json" "$resolved_saved"
"$jq_bin" -S -c '.body.profile_ref.sha256 = ("0"*64)' "$resolved_saved" > \
  "$fixture/cells/aa/resolved.json"
expect_failure core-ref-mismatch E_CORE
/bin/cp "$resolved_saved" "$fixture/cells/aa/resolved.json"

profile_file="$fixture/cells/aa/profile/profiles/default.json"
profile_saved="$tmp/profile.saved"
/bin/cp "$profile_file" "$profile_saved"
resolved_ref_saved="$tmp/resolved-ref.saved"
/bin/cp "$fixture/cells/aa/resolved.json" "$resolved_ref_saved"
original_package_object=$("$jq_bin" -r \
  '.body.bindings[] | select(.role=="producer") | .package_ref.object_id' "$profile_file")
for ref_mutation in repository revision hash path type mode; do
  case "$ref_mutation" in
    repository) mutate='def mutate: .revision.repository_id="repo.manifests";' ;;
    revision) mutate='def mutate: .revision.commit_id=("0"*64);' ;;
    hash) mutate='def mutate: .revision.hash_algorithm="sha1";' ;;
    path) mutate='def mutate: .location={kind:"path",value:"packages/producer-b.sh"};' ;;
    type) mutate='def mutate: .object_type="tree";' ;;
    mode) mutate='def mutate: .mode="100644";' ;;
  esac
  "$jq_bin" -S -c "$mutate (.body.bindings[] | select(.role==\"producer\") | .package_ref) |= mutate" \
    "$profile_saved" > "$profile_file"
  "$jq_bin" -S -c "$mutate (.body.bindings[] | select(.binding.role==\"producer\") | .binding.package_ref) |= mutate" \
    "$resolved_ref_saved" > "$fixture/cells/aa/resolved.json"
  [ "$("$jq_bin" -r '.body.bindings[] | select(.role=="producer") | .package_ref.object_id' \
      "$profile_file")" = "$original_package_object" ] || fail "ref-$ref_mutation changed object id"
  /usr/bin/git -C "$fixture/cells/aa/profile" add profiles/default.json
  GIT_AUTHOR_DATE=2000-01-04T00:00:00Z GIT_COMMITTER_DATE=2000-01-04T00:00:00Z \
    /usr/bin/git -C "$fixture/cells/aa/profile" commit -q -m "ref-$ref_mutation"
  expect_failure "package-ref-$ref_mutation" E_PACKAGE
  /bin/cp "$profile_saved" "$profile_file"
  /bin/cp "$resolved_ref_saved" "$fixture/cells/aa/resolved.json"
  /usr/bin/git -C "$fixture/cells/aa/profile" add profiles/default.json
  GIT_AUTHOR_DATE=2000-01-05T00:00:00Z GIT_COMMITTER_DATE=2000-01-05T00:00:00Z \
    /usr/bin/git -C "$fixture/cells/aa/profile" commit -q -m "restore-$ref_mutation"
done

source_claim_saved="$tmp/source-claim.saved"
/bin/cp "$fixture/cells/aa/resolved.json" "$source_claim_saved"
for source_mutation in manifest-repository config-commit prompt-path skill-oid tool-mode profile-value; do
  case "$source_mutation" in
    manifest-repository)
      source_filter='(.body.bindings[] | select(.binding.role=="forge") |
        .manifest_source.source.revision.repository_id)="repo.profile"'
      ;;
    config-commit)
      source_filter='(.body.bindings[] | select(.binding.role=="producer") |
        .config_source.value.source.revision.commit_id)=("0"*64)'
      ;;
    prompt-path)
      source_filter='(.body.bindings[] | select(.binding.role=="producer") |
        .prompt_source.value.source.location.value)="prompts/reviewer.md"'
      ;;
    skill-oid)
      source_filter='(.body.bindings[] | select(.binding.role=="producer") |
        .skill_sources[0].source.object_id)=("0"*64)'
      ;;
    tool-mode)
      source_filter='(.body.bindings[] | select(.binding.role=="producer") |
        .tool_sources[0].package_source.source.mode)="100755"'
      ;;
    profile-value) source_filter='.body.profile_source.value_sha256=("0"*64)' ;;
  esac
  "$jq_bin" -S -c "$source_filter" "$source_claim_saved" > "$fixture/cells/aa/resolved.json"
  expect_failure "source-claim-$source_mutation" E_SOURCE
  /bin/cp "$source_claim_saved" "$fixture/cells/aa/resolved.json"
done

late_out="$tmp/late-target.out"
late_err="$tmp/late-target.err"
PATH="$bin:/usr/bin:/bin" "$runner" "$inventory" "$fixture" > "$late_out" 2> "$late_err" &
late_pid=$!
late_marker=''
for _ in {1..3000}; do
  late_marker=$(/usr/bin/find "$fixture/scratch" -path '*/aa.producer.home' -type d -print -quit)
  [ -z "$late_marker" ] || break
  /bin/kill -0 "$late_pid" 2>/dev/null || break
  /bin/sleep 0.02
done
if [ -z "$late_marker" ]; then
  /bin/kill "$late_pid" 2>/dev/null || :
  wait "$late_pid" 2>/dev/null || :
  fail 'late target marker'
fi
fixture_git -C "$fixture/target" commit -q --allow-empty -m late-change
if wait "$late_pid"; then
  fail 'late target mutation accepted'
fi
[ ! -s "$late_out" ] && [ "$(/bin/cat "$late_err")" = E_TARGET_STALE ] ||
  fail 'late target mutation error'
pass 'late target commit recheck'

signal_out="$tmp/signal.out"
signal_err="$tmp/signal.err"
PATH="$bin:/usr/bin:/bin" "$runner" "$inventory" "$fixture" > "$signal_out" 2> "$signal_err" &
signal_pid=$!
signal_marker=''
for _ in {1..6000}; do
  signal_marker=$(/usr/bin/find "$fixture/scratch" -path '*/timeout.home' -type d -print -quit)
  [ -z "$signal_marker" ] || break
  /bin/kill -0 "$signal_pid" 2>/dev/null || break
  /bin/sleep 0.02
done
if [ -z "$signal_marker" ]; then
  /bin/kill "$signal_pid" 2>/dev/null || :
  wait "$signal_pid" 2>/dev/null || :
  fail 'signal child marker'
fi
/bin/kill -TERM "$signal_pid"
signal_status=0
wait "$signal_pid" || signal_status=$?
/bin/sleep 2.2
[ "$signal_status" -eq 143 ] && [ ! -s "$signal_out" ] && [ ! -s "$signal_err" ] &&
  [ -z "$(find "$fixture/scratch" -mindepth 1 -print -quit)" ] ||
  fail 'signal group cleanup'
pass 'TERM stops adapter group and cleans scratch'

source_saved="$tmp/source.saved"
/bin/cp "$fixture/target/source.txt" "$source_saved"
/usr/bin/printf '%s\n' changed > "$fixture/target/source.txt"
fixture_git -C "$fixture/target" add source.txt
fixture_git -C "$fixture/target" commit -q -m changed
expect_failure fixture-digest-mismatch E_FIXTURE
/bin/cp "$source_saved" "$fixture/target/source.txt"
fixture_git -C "$fixture/target" add source.txt
fixture_git -C "$fixture/target" commit -q -m restored

producer="$fixture/cells/aa/assets/packages/producer-a.sh"
/usr/bin/printf '%s\n' '# changed' >> "$producer"
/usr/bin/git -C "$fixture/cells/aa/assets" add packages/producer-a.sh
GIT_AUTHOR_DATE=2000-01-02T00:00:00Z GIT_COMMITTER_DATE=2000-01-02T00:00:00Z \
  /usr/bin/git -C "$fixture/cells/aa/assets" commit -q -m changed
expect_failure executable-digest-mismatch E_PACKAGE

/usr/bin/printf 'portable adapter contracts: %s focused checks passed\n' "$pass_count"
