#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

resolver_root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
resolver_runtime="$resolver_root/resolver/v1/profile-resolve-runtime.sh"
resolver_helper_source="$resolver_root/resolver/v1/nofollow-snapshot.c"
resolver_launcher_source="$resolver_root/scripts/test/portable-profile-resolution-launcher.c"
resolver_loader_source="$resolver_root/scripts/test/portable-profile-resolution-loader-trap.c"
resolver_fixture_builder="$resolver_root/scripts/test/portable-profile-resolution-fixtures.sh"
resolver_core="$resolver_root/scripts/core-contract.sh"
resolver_tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-profile-resolver-test.XXXXXX")
resolver_tmp=$(CDPATH='' cd -P -- "$resolver_tmp" && pwd -P)
resolver_download=''
resolver_passed=0
resolver_total=0
/bin/rm -f /tmp/ystack-profile-resolver-must-not-run

cleanup() {
  if [ -n "$resolver_download" ] && [ -f "$resolver_download" ]; then
    /bin/rm -f -- "$resolver_download"
  fi
  /bin/rm -rf -- "$resolver_tmp"
  /bin/rm -f /tmp/ystack-profile-resolver-must-not-run
}
trap cleanup EXIT

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

resolver_platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$resolver_platform" in
  Linux:x86_64)
    resolver_jq_asset=jq-linux64
    resolver_jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    resolver_compiler=${CC:-/usr/bin/cc}
    resolver_host='Linux:x86_64:execve:cc'
    resolver_loader_flags=(-shared -fPIC)
    ;;
  Darwin:x86_64|Darwin:arm64)
    resolver_jq_asset=jq-osx-amd64
    resolver_jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    resolver_compiler=${CC:-/usr/bin/clang}
    resolver_host="$resolver_platform:execve:Apple-clang:developer-functional"
    resolver_loader_flags=(-dynamiclib)
    ;;
  *) printf 'FAIL: unsupported profile resolver host: %s\n' "$resolver_platform" >&2; exit 1 ;;
esac

resolver_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$resolver_cache"
resolver_jq="$resolver_cache/$resolver_jq_asset"
if [ ! -f "$resolver_jq" ] || [ "$(sha256_file "$resolver_jq")" != "$resolver_jq_sha" ]; then
  resolver_download=$(/usr/bin/mktemp "$resolver_cache/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$resolver_jq_asset" \
    -o "$resolver_download"
  [ "$(sha256_file "$resolver_download")" = "$resolver_jq_sha" ] || {
    printf '%s\n' 'FAIL: jq 1.6 release digest mismatch' >&2
    exit 1
  }
  /bin/chmod 0555 "$resolver_download"
  /bin/mv "$resolver_download" "$resolver_jq"
  resolver_download=''
fi
[ "$("$resolver_jq" --version)" = jq-1.6 ] || {
  printf '%s\n' 'FAIL: jq 1.6 identity' >&2
  exit 1
}

resolver_bin="$resolver_tmp/bin"
/bin/mkdir -m 700 "$resolver_bin"
/bin/cp "$resolver_jq" "$resolver_bin/jq"
/bin/chmod 0555 "$resolver_bin/jq"
resolver_bound_jq="$resolver_bin/jq"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_helper_source" -o "$resolver_bin/nofollow-snapshot"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_launcher_source" -o "$resolver_bin/launcher"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "${resolver_loader_flags[@]}" "$resolver_loader_source" -o "$resolver_bin/loader-trap.dylib"

resolver_fixture="$resolver_tmp/fixture"
PATH="$resolver_bin:/usr/bin:/bin" "$resolver_fixture_builder" "$resolver_fixture" >/dev/null

resolver_loader_marker="$resolver_tmp/loader.marker"
"$resolver_bin/launcher" loader-control "$resolver_bin/loader-trap.dylib" "$resolver_loader_marker"
[ -f "$resolver_loader_marker" ] || {
  printf '%s\n' 'FAIL: loader control did not fire' >&2
  exit 1
}
/bin/rm -f "$resolver_loader_marker"

run_resolver() {
  resolver_sandbox=$1
  resolver_request=$2
  resolver_map=$3
  /bin/mkdir -m 700 "$resolver_sandbox"
  YSTACK_TEST_SANDBOX="$resolver_sandbox" \
    "$resolver_bin/launcher" resolve "$resolver_runtime" "$resolver_bin/nofollow-snapshot" \
    "$resolver_bound_jq" "$resolver_request" "$resolver_map"
}

pass_case() {
  resolver_total=$((resolver_total + 1))
  resolver_passed=$((resolver_passed + 1))
  printf 'ok %d - %s\n' "$resolver_total" "$1"
}

fail_case() {
  resolver_total=$((resolver_total + 1))
  printf 'not ok %d - %s\n' "$resolver_total" "$1" >&2
  exit 1
}

expect_failure() {
  resolver_name=$1
  resolver_expected=$2
  resolver_request=$3
  resolver_map=$4
  resolver_stdout="$resolver_tmp/failure.stdout"
  resolver_stderr="$resolver_tmp/failure.stderr"
  if run_resolver "$resolver_tmp/sandbox.failure.$resolver_total" "$resolver_request" "$resolver_map" \
      > "$resolver_stdout" 2> "$resolver_stderr"; then
    fail_case "$resolver_name"
  fi
  [ ! -s "$resolver_stdout" ] || fail_case "$resolver_name emitted stdout"
  [ "$(/usr/bin/sed -n '1p' "$resolver_stderr")" = "$resolver_expected" ] || {
    /bin/cat "$resolver_stderr" >&2
    fail_case "$resolver_name error"
  }
  pass_case "$resolver_name"
}

resolver_output="$resolver_tmp/resolved.json"
run_resolver "$resolver_tmp/sandbox.success" "$resolver_fixture/request.json" "$resolver_fixture/map.json" \
  > "$resolver_output" 2> "$resolver_tmp/success.stderr" || {
    /bin/cat "$resolver_tmp/success.stderr" >&2
    fail_case 'cross-hash multi-repository resolution'
  }
[ ! -s "$resolver_tmp/success.stderr" ] || fail_case 'success stderr is empty'
[ ! -e "$resolver_loader_marker" ] || fail_case 'clean resolver child loaded hostile library'
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_output")" = resolved_profile ] || fail_case 'output kind'
PATH="$resolver_bin:/usr/bin:/bin" /bin/bash "$resolver_core" validate-profile-set \
  "$resolver_fixture/profile/profiles/default.json" "$resolver_output" \
  "$resolver_fixture/manifests/manifests/producer.json" \
  "$resolver_fixture/manifests/manifests/publisher.json" \
  "$resolver_fixture/manifests/manifests/reviewer.json" \
  "$resolver_fixture/manifests/manifests/verifier.json"
pass_case 'cross-hash multi-repository resolution and real core validation'

resolver_second="$resolver_tmp/resolved.second.json"
resolver_permuted_map="$resolver_tmp/map.permuted.json"
resolver_permuted_request="$resolver_tmp/request.permuted.json"
"$resolver_bound_jq" -S -c '.repositories |= reverse' "$resolver_fixture/map.json" > "$resolver_permuted_map"
"$resolver_bound_jq" -S -c '.manifest_sources |= reverse' "$resolver_fixture/request.json" > "$resolver_permuted_request"
run_resolver "$resolver_tmp/sandbox.second" "$resolver_permuted_request" "$resolver_permuted_map" > "$resolver_second"
/usr/bin/cmp -s "$resolver_output" "$resolver_second" || fail_case 'map-order determinism'
pass_case 'map/source order and physical scratch do not affect output'

if /usr/bin/grep -q 'token-do-not-echo\|ystack-profile-resolver-must-not-run\|/private/' "$resolver_output"; then
  fail_case 'opaque bytes or physical roots leaked into output'
fi
[ ! -e /tmp/ystack-profile-resolver-must-not-run ] || fail_case 'selected content executed'
pass_case 'selected content remains inert and private'

"$resolver_bound_jq" -e --slurpfile request "$resolver_fixture/request.json" \
  '.body.selection_ref == $request[0].selection_ref and
   .body.repository_context_ref == $request[0].repository_context_ref' "$resolver_output" >/dev/null ||
  fail_case 'caller scopes changed'
pass_case 'caller-owned scope refs are copied unchanged'

[ "$(/usr/bin/stat -f '%Lp' "$resolver_runtime" 2>/dev/null || /usr/bin/stat -c '%a' "$resolver_runtime")" = 644 ] ||
  fail_case 'inactive runtime mode'
pass_case 'runtime payload is inactive mode 0644'

resolver_bad="$resolver_tmp/request.parse.json"
/usr/bin/printf '%s\n' '{' > "$resolver_bad"
expect_failure 'malformed request before map access' E_PARSE "$resolver_bad" "$resolver_tmp/no-map"

resolver_zero="$resolver_tmp/request.zero.json"
"$resolver_bound_jq" -S -c '.manifest_sources=[]' "$resolver_fixture/request.json" > "$resolver_zero"
expect_failure 'zero manifests has fixed precedence' 'E_INPUT manifest-count' "$resolver_zero" "$resolver_tmp/no-map.zero"

resolver_nine="$resolver_tmp/request.nine.json"
"$resolver_bound_jq" -S -c '.manifest_sources[0] as $manifest | .manifest_sources = [range(0;9) | $manifest]' \
  "$resolver_fixture/request.json" > "$resolver_nine"
expect_failure 'nine manifests has fixed precedence' 'E_INPUT manifest-count' "$resolver_nine" "$resolver_tmp/no-map.nine"

resolver_noncanonical="$resolver_tmp/request.noncanonical.json"
"$resolver_bound_jq" . "$resolver_fixture/request.json" > "$resolver_noncanonical"
expect_failure 'noncanonical request' E_CANONICAL "$resolver_noncanonical" "$resolver_fixture/map.json"

resolver_missing_map="$resolver_tmp/map.missing.json"
"$resolver_bound_jq" -S -c '.repositories |= map(select(.repository_id != "repo.profile"))' \
  "$resolver_fixture/map.json" > "$resolver_missing_map"
expect_failure 'locator map missing' 'E_REPOSITORY locator-map-missing' \
  "$resolver_fixture/request.json" "$resolver_missing_map"

resolver_extra_map="$resolver_tmp/map.extra.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_fixture/assets" \
  '.repositories += [{repository_id:"repo.extra",root:$root}]' "$resolver_fixture/map.json" > "$resolver_extra_map"
expect_failure 'unused map rejected after source join' 'E_REPOSITORY map-extra' \
  "$resolver_fixture/request.json" "$resolver_extra_map"

resolver_wrong_oid="$resolver_tmp/request.wrong-oid.json"
"$resolver_bound_jq" -S -c '.profile_source.object_id = ("0" * 40)' \
  "$resolver_fixture/request.json" > "$resolver_wrong_oid"
expect_failure 'wrong selected object id' 'E_OBJECT object-path' "$resolver_wrong_oid" "$resolver_fixture/map.json"

resolver_locator_shape="$resolver_tmp/request.locator-shape.json"
"$resolver_bound_jq" -S -c '.profile_source.commit_id = "main"' \
  "$resolver_fixture/request.json" > "$resolver_locator_shape"
expect_failure 'revision expressions fail before Git' 'E_INPUT locator-shape' \
  "$resolver_locator_shape" "$resolver_fixture/map.json"

resolver_duplicate_map="$resolver_tmp/map.duplicate.json"
"$resolver_bound_jq" -S -c '.repositories += [.repositories[0]]' \
  "$resolver_fixture/map.json" > "$resolver_duplicate_map"
expect_failure 'duplicate logical map id' 'E_INPUT map-shape' \
  "$resolver_fixture/request.json" "$resolver_duplicate_map"

resolver_oversize="$resolver_tmp/request.oversize.json"
/bin/dd if=/dev/zero of="$resolver_oversize" bs=1048576 count=1 2>/dev/null
/usr/bin/printf x >> "$resolver_oversize"
expect_failure 'request one byte over transport limit' E_LIMIT \
  "$resolver_oversize" "$resolver_tmp/no-map.oversize"

resolver_missing_manifest="$resolver_tmp/request.manifest-missing.json"
"$resolver_bound_jq" -S -c '.manifest_sources = .manifest_sources[0:3]' \
  "$resolver_fixture/request.json" > "$resolver_missing_manifest"
expect_failure 'manifest source join reports missing' 'E_RELATION manifest-source-missing' \
  "$resolver_missing_manifest" "$resolver_fixture/map.json"

/bin/ln -s "$resolver_fixture/profile" "$resolver_tmp/profile-link"
resolver_symlink_map="$resolver_tmp/map.symlink.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_tmp/profile-link" \
  '(.repositories[] | select(.repository_id == "repo.profile").root) = $root' \
  "$resolver_fixture/map.json" > "$resolver_symlink_map"
expect_failure 'symlinked mapped root' 'E_REPOSITORY root' \
  "$resolver_fixture/request.json" "$resolver_symlink_map"

resolver_leak_map="$resolver_tmp/map.leak.json"
"$resolver_bound_jq" -S -c --arg root "$resolver_tmp/does-not-exist-secret-canary" \
  '(.repositories[] | select(.repository_id == "repo.profile").root) = $root' \
  "$resolver_fixture/map.json" > "$resolver_leak_map"
resolver_leak_out="$resolver_tmp/leak.stdout"
resolver_leak_err="$resolver_tmp/leak.stderr"
if run_resolver "$resolver_tmp/sandbox.leak" "$resolver_fixture/request.json" "$resolver_leak_map" \
    > "$resolver_leak_out" 2> "$resolver_leak_err"; then
  fail_case 'private root failure'
fi
[ ! -s "$resolver_leak_out" ] || fail_case 'private root failure stdout'
if /usr/bin/grep -q 'secret-canary\|does-not-exist' "$resolver_leak_err"; then
  fail_case 'physical path leaked'
fi
pass_case 'physical repository paths stay out of errors'

resolver_assets_config="$resolver_fixture/assets/.git/config"
/bin/cp "$resolver_assets_config" "$resolver_tmp/assets.config.saved"
/usr/bin/printf '%s\n' '[include]' 'path = /private/tmp/ystack-profile-resolver-include-canary' >> "$resolver_assets_config"
expect_failure 'mapped config include stays inert' 'E_REPOSITORY config-include' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/assets.config.saved" "$resolver_assets_config"

resolver_replace_source=$("$resolver_bound_jq" -r '.profile_source.object_id' "$resolver_fixture/request.json")
resolver_replace_target=$(/usr/bin/git -C "$resolver_fixture/profile" rev-parse 'HEAD^{tree}')
/usr/bin/git -C "$resolver_fixture/profile" update-ref "refs/replace/$resolver_replace_source" "$resolver_replace_target"
expect_failure 'replacement refs fail before private Git' 'E_REPOSITORY replacement-state' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/usr/bin/git -C "$resolver_fixture/profile" update-ref -d "refs/replace/$resolver_replace_source"

resolver_helper_out="$resolver_tmp/helper-limit.stdout"
resolver_helper_err="$resolver_tmp/helper-limit.stderr"
if "$resolver_bin/nofollow-snapshot" snapshot-repository "$resolver_fixture/profile" \
    "$resolver_tmp/helper-limit-output" 1 268435456 262144 16777216 536870912 \
    > "$resolver_helper_out" 2> "$resolver_helper_err"; then
  fail_case 'helper admin limit'
fi
if [ -s "$resolver_helper_out" ] || [ -e "$resolver_tmp/helper-limit-output" ] ||
   ! /usr/bin/grep -q '^E_LIMIT ' "$resolver_helper_err"; then
  fail_case 'helper admin limit closure'
fi
pass_case 'native helper enforces budgets before publish'

resolver_before=$(/usr/bin/git -C "$resolver_fixture/assets" status --porcelain=v1; /usr/bin/git -C "$resolver_fixture/manifests" status --porcelain=v1; /usr/bin/git -C "$resolver_fixture/profile" status --porcelain=v1)
resolver_after=$(/usr/bin/git -C "$resolver_fixture/assets" status --porcelain=v1; /usr/bin/git -C "$resolver_fixture/manifests" status --porcelain=v1; /usr/bin/git -C "$resolver_fixture/profile" status --porcelain=v1)
[ "$resolver_before" = "$resolver_after" ] || fail_case 'mapped repositories mutated'
pass_case 'resolution leaves mapped repositories unchanged'

[ "$resolver_passed" -eq "$resolver_total" ] || exit 1
printf 'portable profile resolution: %d/%d targeted cases passed\n' "$resolver_passed" "$resolver_total"
printf 'supported tuple: %s; jq=%s; core=%s; helper-source=%s\n' \
  "$resolver_host" "$(sha256_file "$resolver_jq")" \
  "$(/usr/bin/git -C "$resolver_root" hash-object scripts/core-contract.sh)" \
  "$(sha256_file "$resolver_helper_source")"
