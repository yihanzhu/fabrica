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
trap '/bin/rm -rf -- "$tmp"' EXIT

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
jq_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_cache" ] || fail 'verified jq 1.6 cache missing'
case "$jq_asset" in
  jq-osx-amd64) jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
esac
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
/usr/bin/git init -q "$fixture/target"
/usr/bin/git -C "$fixture/target" config user.name fixture
/usr/bin/git -C "$fixture/target" config user.email fixture@example.invalid
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  /usr/bin/git -C "$fixture/target" add source.txt
GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
  /usr/bin/git -C "$fixture/target" commit -q -m fixture

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
    ([{repository_id:"fixture.target",root:($root+"/target")}] +
     (["aa","ab","ba","bb"] |
      map(. as $cell | ["assets","manifests","profile"] |
        map(. as $repo | {repository_id:($cell+"."+$repo),
          root:($root+"/cells/"+$cell+"/"+$repo)})) | add))}
' > "$fixture/repository-map.json"

fingerprint_before=$(/usr/bin/git -C "$fixture/target" rev-parse 'HEAD^{tree}')
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
  (.cells | length) == 4 and (.negative_observations | length) == 7 and
  ([.cells[].projection] | unique | length) == 1 and
  ([.cells[].provenance.profile_sha256] | unique | length) == 4 and
  (.non_claims | index("external-target-smoke") != null) and
  (.non_claims | index("network-isolation") != null) and
  (.inventory_acceptance_ref.authorization_comment_id == 5476938197)
' "$output" >/dev/null || fail 'observation shape and equivalence'
[ "$fingerprint_before" = "$(/usr/bin/git -C "$fixture/target" rev-parse 'HEAD^{tree}')" ] ||
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

source_saved="$tmp/source.saved"
/bin/cp "$fixture/target/source.txt" "$source_saved"
/usr/bin/printf '%s\n' changed > "$fixture/target/source.txt"
/usr/bin/git -C "$fixture/target" add source.txt
GIT_AUTHOR_DATE=2000-01-02T00:00:00Z GIT_COMMITTER_DATE=2000-01-02T00:00:00Z \
  /usr/bin/git -C "$fixture/target" commit -q -m changed
expect_failure fixture-digest-mismatch E_FIXTURE
/bin/cp "$source_saved" "$fixture/target/source.txt"
/usr/bin/git -C "$fixture/target" add source.txt
GIT_AUTHOR_DATE=2000-01-03T00:00:00Z GIT_COMMITTER_DATE=2000-01-03T00:00:00Z \
  /usr/bin/git -C "$fixture/target" commit -q -m restored

producer="$fixture/cells/aa/assets/packages/producer-a.sh"
/usr/bin/printf '%s\n' '# changed' >> "$producer"
/usr/bin/git -C "$fixture/cells/aa/assets" add packages/producer-a.sh
GIT_AUTHOR_DATE=2000-01-02T00:00:00Z GIT_COMMITTER_DATE=2000-01-02T00:00:00Z \
  /usr/bin/git -C "$fixture/cells/aa/assets" commit -q -m changed
expect_failure executable-digest-mismatch E_PACKAGE

/usr/bin/printf 'portable adapter contracts: %s focused checks passed\n' "$pass_count"
