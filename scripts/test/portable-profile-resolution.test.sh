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
resolver_fingerprint_counter=0
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

fingerprint_entry() {
  resolver_fingerprint_path=$1
  if [ -L "$resolver_fingerprint_path" ]; then
    /usr/bin/printf 'L\t%s\t%s\n' "$resolver_fingerprint_path" \
      "$(/usr/bin/readlink "$resolver_fingerprint_path")"
  elif [ -d "$resolver_fingerprint_path" ]; then
    /usr/bin/printf 'D\t%s\n' "$resolver_fingerprint_path"
  elif [ -f "$resolver_fingerprint_path" ]; then
    case "$resolver_platform" in
      Linux:x86_64) resolver_fingerprint_stat=$(/usr/bin/stat -c '%a:%s' "$resolver_fingerprint_path") ;;
      Darwin:*) resolver_fingerprint_stat=$(/usr/bin/stat -f '%Lp:%z' "$resolver_fingerprint_path") ;;
    esac
    /usr/bin/printf 'F\t%s\t%s\t%s\n' "$resolver_fingerprint_path" \
      "$resolver_fingerprint_stat" "$(sha256_file "$resolver_fingerprint_path")"
  else
    /usr/bin/printf 'O\t%s\n' "$resolver_fingerprint_path"
  fi
}

repository_fingerprint() {
  resolver_fingerprint_root=$1
  resolver_fingerprint_active=$(/usr/bin/git -C "$resolver_fingerprint_root" rev-parse --absolute-git-dir)
  resolver_fingerprint_common=$(/usr/bin/git --git-dir="$resolver_fingerprint_active" \
    rev-parse --path-format=absolute --git-common-dir)
  resolver_fingerprint_counter=$((resolver_fingerprint_counter + 1))
  resolver_fingerprint_inventory="$resolver_tmp/fingerprint.$resolver_fingerprint_counter"
  {
    /usr/bin/printf 'ROOT\t%s\nACTIVE\t%s\nCOMMON\t%s\n' "$resolver_fingerprint_root" \
      "$resolver_fingerprint_active" "$resolver_fingerprint_common"
    for resolver_fingerprint_fixed in \
      "$resolver_fingerprint_root/.git" "$resolver_fingerprint_active/HEAD" \
      "$resolver_fingerprint_active/config.worktree" "$resolver_fingerprint_active/commondir" \
      "$resolver_fingerprint_active/gitdir" "$resolver_fingerprint_common/HEAD" \
      "$resolver_fingerprint_common/config" "$resolver_fingerprint_common/packed-refs" \
      "$resolver_fingerprint_common/info/grafts"; do
      if [ -e "$resolver_fingerprint_fixed" ] || [ -L "$resolver_fingerprint_fixed" ]; then
        fingerprint_entry "$resolver_fingerprint_fixed"
      fi
    done
    for resolver_fingerprint_tree in "$resolver_fingerprint_common/refs" \
      "$resolver_fingerprint_common/objects"; do
      if [ -d "$resolver_fingerprint_tree" ] && [ ! -L "$resolver_fingerprint_tree" ]; then
        while IFS= read -r -d '' resolver_fingerprint_path; do
          fingerprint_entry "$resolver_fingerprint_path"
        done < <(/usr/bin/find "$resolver_fingerprint_tree" -mindepth 1 -print0 | /usr/bin/sort -z)
      fi
    done
  } > "$resolver_fingerprint_inventory"
  sha256_file "$resolver_fingerprint_inventory"
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
case "$resolver_platform" in
  Linux:x86_64) /bin/cp /usr/bin/awk "$resolver_bin/awk" ;;
  Darwin:*)
    /usr/bin/printf '%s\n' '#!/bin/bash' 'exec /usr/bin/awk "$@"' > "$resolver_bin/awk"
    ;;
esac
/bin/chmod 0555 "$resolver_bin/awk"
[ -f "$resolver_bin/awk" ] && [ ! -L "$resolver_bin/awk" ] || {
  printf '%s\n' 'FAIL: bound core awk must be regular' >&2
  exit 1
}
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_helper_source" -o "$resolver_bin/nofollow-snapshot"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "$resolver_launcher_source" -o "$resolver_bin/launcher"
"$resolver_compiler" -std=c11 -O2 -Wall -Wextra -Werror -pedantic \
  "${resolver_loader_flags[@]}" "$resolver_loader_source" -o "$resolver_bin/loader-trap.dylib"

resolver_fixture="$resolver_tmp/fixture"
PATH="$resolver_bin:/usr/bin:/bin" "$resolver_fixture_builder" "$resolver_fixture" \
  "$resolver_bound_jq" >/dev/null

resolver_variants="$resolver_tmp/repository-variants"
resolver_bare="$resolver_variants/bare"
resolver_linked="$resolver_variants/linked"
/bin/mkdir -p "$resolver_bare" "$resolver_linked"
for resolver_repository_name in assets manifests profile; do
  /usr/bin/git clone -q --bare --no-hardlinks "$resolver_fixture/$resolver_repository_name" \
    "$resolver_bare/$resolver_repository_name.git"
  /usr/bin/git -C "$resolver_fixture/$resolver_repository_name" worktree add -q --detach \
    "$resolver_linked/$resolver_repository_name" HEAD
done
resolver_corrupt_profile="$resolver_variants/corrupt-profile"
/usr/bin/git clone -q --no-hardlinks "$resolver_fixture/profile" "$resolver_corrupt_profile"

resolver_bare_map="$resolver_tmp/map.bare.json"
resolver_linked_map="$resolver_tmp/map.linked.json"
"$resolver_bound_jq" -S -c --arg assets "$resolver_bare/assets.git" \
  --arg manifests "$resolver_bare/manifests.git" --arg profile "$resolver_bare/profile.git" \
  '(.repositories[] | select(.repository_id == "repo.assets").root) = $assets |
   (.repositories[] | select(.repository_id == "repo.manifests").root) = $manifests |
   (.repositories[] | select(.repository_id == "repo.profile").root) = $profile' \
  "$resolver_fixture/map.json" > "$resolver_bare_map"
"$resolver_bound_jq" -S -c --arg assets "$resolver_linked/assets" \
  --arg manifests "$resolver_linked/manifests" --arg profile "$resolver_linked/profile" \
  '(.repositories[] | select(.repository_id == "repo.assets").root) = $assets |
   (.repositories[] | select(.repository_id == "repo.manifests").root) = $manifests |
   (.repositories[] | select(.repository_id == "repo.profile").root) = $profile' \
  "$resolver_fixture/map.json" > "$resolver_linked_map"
resolver_one_segment_request="$resolver_tmp/request.one-segment.json"
"$resolver_bound_jq" -S -c '.profile_source.path = "default.json"' \
  "$resolver_fixture/request.json" > "$resolver_one_segment_request"
resolver_quoted_request="$resolver_tmp/request.quoted.json"
resolver_newline_request="$resolver_tmp/request.newline.json"
"$resolver_bound_jq" -S -c --arg path 'profiles/"quoted".json' \
  '.profile_source.path = $path' "$resolver_fixture/request.json" > "$resolver_quoted_request"
"$resolver_bound_jq" -S -c --arg path $'profiles/new\nline.json' \
  '.profile_source.path = $path' "$resolver_fixture/request.json" > "$resolver_newline_request"

resolver_mapped_roots=(
  "$resolver_fixture/assets" "$resolver_fixture/manifests" "$resolver_fixture/profile"
  "$resolver_bare/assets.git" "$resolver_bare/manifests.git" "$resolver_bare/profile.git"
  "$resolver_linked/assets" "$resolver_linked/manifests" "$resolver_linked/profile"
  "$resolver_corrupt_profile"
)
resolver_fingerprints_before="$resolver_tmp/repository-fingerprints.before"
: > "$resolver_fingerprints_before"
for resolver_mapped_root in "${resolver_mapped_roots[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$resolver_mapped_root" \
    "$(repository_fingerprint "$resolver_mapped_root")" >> "$resolver_fingerprints_before"
done

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

expect_launcher_failure() {
  resolver_name=$1
  resolver_mode=$2
  resolver_expected=$3
  resolver_limit_sandbox="$resolver_tmp/limit.$resolver_mode"
  resolver_limit_stdout="$resolver_tmp/limit.$resolver_mode.stdout"
  resolver_limit_stderr="$resolver_tmp/limit.$resolver_mode.stderr"
  /bin/mkdir -m 700 "$resolver_limit_sandbox"
  if "$resolver_bin/launcher" limit-control "$resolver_mode" "$resolver_limit_sandbox" \
      > "$resolver_limit_stdout" 2> "$resolver_limit_stderr"; then
    fail_case "$resolver_name"
  fi
  [ ! -s "$resolver_limit_stdout" ] || fail_case "$resolver_name emitted partial stdout"
  [ "$(/usr/bin/sed -n '1p' "$resolver_limit_stderr")" = "$resolver_expected" ] || {
    /bin/cat "$resolver_limit_stderr" >&2
    fail_case "$resolver_name token"
  }
  pass_case "$resolver_name"
}

expect_missing_dependency() {
  resolver_missing_helper="$resolver_tmp/missing-helper"
  resolver_missing_sandbox="$resolver_tmp/missing-helper-sandbox"
  resolver_missing_stdout="$resolver_tmp/missing-helper.stdout"
  resolver_missing_stderr="$resolver_tmp/missing-helper.stderr"
  /bin/cp "$resolver_bin/nofollow-snapshot" "$resolver_missing_helper"
  /bin/chmod 0555 "$resolver_missing_helper"
  /bin/mkdir -m 700 "$resolver_missing_sandbox"
  if YSTACK_TEST_SANDBOX="$resolver_missing_sandbox" \
      "$resolver_bin/launcher" resolve-missing-helper "$resolver_runtime" \
      "$resolver_missing_helper" "$resolver_bound_jq" "$resolver_fixture/request.json" \
      "$resolver_fixture/map.json" > "$resolver_missing_stdout" 2> "$resolver_missing_stderr"; then
    fail_case 'missing required dependency'
  fi
  [ ! -s "$resolver_missing_stdout" ] && [ ! -e "$resolver_missing_helper" ] ||
    fail_case 'missing dependency emitted output or survived'
  [ "$(/usr/bin/sed -n '1p' "$resolver_missing_stderr")" = 'E_RUNTIME dependency' ] || {
    /bin/cat "$resolver_missing_stderr" >&2
    fail_case 'missing dependency token'
  }
  pass_case 'missing required dependency is sanitized'
}

expect_internal_budget_failure() {
  resolver_name=$1
  resolver_budget_id=$2
  resolver_budget_gitdir=$3
  resolver_budget_algorithm=$4
  resolver_budget_oid=$5
  resolver_budget_value=$6
  resolver_budget_global=$7
  resolver_budget_reason=$8
  resolver_budget_scratch="$resolver_tmp/budget.$resolver_total"
  resolver_budget_result="$resolver_tmp/budget.$resolver_total.result"
  resolver_budget_error="$resolver_tmp/budget.$resolver_total.error"
  /bin/mkdir -m 700 "$resolver_budget_scratch" "$resolver_budget_scratch/object-cache"
  (
    set +e
    # shellcheck source=/dev/null
    source "$resolver_root/scripts/lib/profile-resolution.sh"
    exec 3> "$resolver_budget_error"
    # shellcheck disable=SC2034
    profile_resolution_scratch=$resolver_budget_scratch
    profile_resolution_snapshots="$resolver_budget_scratch/snapshots.tsv"
    /usr/bin/printf '%s\t%s\tidentity\t%s\n' "$resolver_budget_id" \
      "$resolver_budget_gitdir" "$resolver_budget_algorithm" > "$profile_resolution_snapshots"
    # shellcheck disable=SC2034
    profile_resolution_value_remaining=$resolver_budget_value
    # shellcheck disable=SC2034
    profile_resolution_global_remaining=$resolver_budget_global
    profile_resolution_limit_reason=''
    profile_resolution_verify_object_payload "$resolver_budget_id" "$resolver_budget_algorithm" \
      "$resolver_budget_oid" blob "$resolver_budget_scratch/value"
    resolver_budget_status=$?
    /usr/bin/printf '%s\t%s\n' "$resolver_budget_status" "$profile_resolution_limit_reason"
    profile_resolution_report_object_failure "$resolver_budget_status" >/dev/null
  ) > "$resolver_budget_result" || :
  resolver_budget_expected=$(/usr/bin/printf '50\t%s' "$resolver_budget_reason")
  [ "$(/usr/bin/sed -n '1p' "$resolver_budget_result")" = "$resolver_budget_expected" ] ||
    fail_case "$resolver_name internal status"
  [ "$(/usr/bin/sed -n '1p' "$resolver_budget_error")" = "E_LIMIT $resolver_budget_reason" ] ||
    fail_case "$resolver_name public token"
  pass_case "$resolver_name"
}

resolver_ambient_bin="$resolver_tmp/ambient-bin"
resolver_ambient_request="$resolver_tmp/ambient-awk-request.json"
/bin/mkdir -m 700 "$resolver_ambient_bin"
/bin/ln -s /does/not/exist "$resolver_ambient_bin/awk"
/usr/bin/printf '%s\n' '{' > "$resolver_ambient_request"
PATH="$resolver_ambient_bin:/usr/bin:/bin" expect_failure \
  'symlinked ambient awk is ignored' E_PARSE "$resolver_ambient_request" "$resolver_tmp/no-map.ambient"
expect_missing_dependency

expect_launcher_failure 'launcher sanitizes silent child failure' silent 'E_RUNTIME unexpected'
expect_launcher_failure 'launcher converts file limit to a token' file 'E_LIMIT resource-limit'
expect_launcher_failure 'launcher bounds its process group' process 'E_LIMIT process-limit'

resolver_large_package_oid=$("$resolver_bound_jq" -r \
  '.body.bindings[] | select(.role == "producer") | .package_ref.object_id' \
  "$resolver_fixture/profile/profiles/large.json")
resolver_small_profile_oid=$("$resolver_bound_jq" -r '.profile_source.object_id' \
  "$resolver_fixture/request.json")
expect_internal_budget_failure 'per-value budget keeps E_LIMIT' repo.assets \
  "$resolver_fixture/assets/.git" sha256 "$resolver_large_package_oid" 67108864 536870912 value-size
expect_internal_budget_failure 'aggregate value budget keeps E_LIMIT' repo.profile \
  "$resolver_fixture/profile/.git" sha1 "$resolver_small_profile_oid" 1 536870912 value-size
expect_internal_budget_failure 'global scratch budget keeps E_LIMIT' repo.profile \
  "$resolver_fixture/profile/.git" sha1 "$resolver_small_profile_oid" 67108864 1 scratch-size

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

resolver_bare_output="$resolver_tmp/resolved.bare.json"
run_resolver "$resolver_tmp/sandbox.bare" "$resolver_fixture/request.json" "$resolver_bare_map" \
  > "$resolver_bare_output"
/usr/bin/cmp -s "$resolver_output" "$resolver_bare_output" || fail_case 'bare repository determinism'
pass_case 'bare repositories resolve the same exact graph'

resolver_linked_output="$resolver_tmp/resolved.linked.json"
run_resolver "$resolver_tmp/sandbox.linked" "$resolver_fixture/request.json" "$resolver_linked_map" \
  > "$resolver_linked_output"
/usr/bin/cmp -s "$resolver_output" "$resolver_linked_output" || fail_case 'linked worktree determinism'
pass_case 'linked worktrees resolve the same exact graph'

resolver_one_segment_output="$resolver_tmp/resolved.one-segment.json"
run_resolver "$resolver_tmp/sandbox.one-segment" "$resolver_one_segment_request" \
  "$resolver_fixture/map.json" > "$resolver_one_segment_output"
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_one_segment_output")" = resolved_profile ] ||
  fail_case 'one-segment profile resolution'
pass_case 'one-segment path verifies its root tree before enumeration'

resolver_quoted_output="$resolver_tmp/resolved.quoted.json"
run_resolver "$resolver_tmp/sandbox.quoted" "$resolver_quoted_request" \
  "$resolver_fixture/map.json" > "$resolver_quoted_output"
[ "$("$resolver_bound_jq" -r '.kind' "$resolver_quoted_output")" = resolved_profile ] ||
  fail_case 'quoted path resolution'
pass_case 'NUL tree parsing matches a quoted path as raw bytes'
expect_failure 'newline path is rejected without confusing tree parsing' 'E_INPUT locator-shape' \
  "$resolver_newline_request" "$resolver_fixture/map.json"

resolver_bare_config="$resolver_bare/profile.git/config"
/bin/cp "$resolver_bare_config" "$resolver_tmp/bare.config.saved"
/usr/bin/printf '%s\n' '[include]' 'path = /private/tmp/ystack-profile-resolver-bare-canary' >> "$resolver_bare_config"
expect_failure 'bare repository rejects config include' 'E_REPOSITORY config-include' \
  "$resolver_fixture/request.json" "$resolver_bare_map"
/bin/cp "$resolver_tmp/bare.config.saved" "$resolver_bare_config"

resolver_linked_gitfile="$resolver_linked/profile/.git"
/bin/cp "$resolver_linked_gitfile" "$resolver_tmp/linked.gitfile.saved"
/usr/bin/printf '%s\n' 'gitdir: /does/not/exist' > "$resolver_linked_gitfile"
expect_failure 'linked worktree rejects a broken gitfile' 'E_REPOSITORY gitfile' \
  "$resolver_fixture/request.json" "$resolver_linked_map"
/bin/cp "$resolver_tmp/linked.gitfile.saved" "$resolver_linked_gitfile"

resolver_profile_commit=$("$resolver_bound_jq" -r '.profile_source.commit_id' "$resolver_fixture/request.json")
resolver_profile_root_tree=$(/usr/bin/git -C "$resolver_fixture/profile" show -s --format=%T "$resolver_profile_commit")
resolver_profile_root_object="$resolver_fixture/profile/.git/objects/${resolver_profile_root_tree:0:2}/${resolver_profile_root_tree:2}"
[ -f "$resolver_profile_root_object" ] && [ ! -L "$resolver_profile_root_object" ] ||
  fail_case 'root tree loose-object fixture'
case "$resolver_platform" in
  Linux:x86_64) resolver_profile_root_mode=$(/usr/bin/stat -c '%a' "$resolver_profile_root_object") ;;
  Darwin:*) resolver_profile_root_mode=$(/usr/bin/stat -f '%Lp' "$resolver_profile_root_object") ;;
esac
/bin/cp "$resolver_profile_root_object" "$resolver_tmp/profile-root-tree.saved"
/bin/chmod 0600 "$resolver_profile_root_object"
/usr/bin/printf '%s\n' corrupt > "$resolver_profile_root_object"
expect_failure 'corrupt root tree fails before one-segment walk' 'E_OBJECT object-path' \
  "$resolver_one_segment_request" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/profile-root-tree.saved" "$resolver_profile_root_object"
/bin/chmod "$resolver_profile_root_mode" "$resolver_profile_root_object"

resolver_inline_config="$resolver_fixture/profile/.git/config"
/bin/cp "$resolver_inline_config" "$resolver_tmp/inline.config.saved"
/usr/bin/sed 's/repositoryformatversion = 0/repositoryformatversion = 0 # accepted inline comment/' \
  "$resolver_tmp/inline.config.saved" > "$resolver_inline_config"
/usr/bin/printf '%s\n' '[fixture]' 'value = "literal # and ; characters"' >> "$resolver_inline_config"
resolver_inline_output="$resolver_tmp/resolved.inline-comment.json"
run_resolver "$resolver_tmp/sandbox.inline-comment" "$resolver_fixture/request.json" \
  "$resolver_fixture/map.json" > "$resolver_inline_output"
/usr/bin/cmp -s "$resolver_output" "$resolver_inline_output" || fail_case 'inline comment output drift'
pass_case 'unquoted inline comment is accepted and quoted comment characters stay literal'

/usr/bin/sed 's/repositoryformatversion = 0/repositoryformatversion = "0 # quoted literal"/' \
  "$resolver_tmp/inline.config.saved" > "$resolver_inline_config"
expect_failure 'quoted comment text is not stripped from storage format' 'E_REPOSITORY storage-format' \
  "$resolver_fixture/request.json" "$resolver_fixture/map.json"
/bin/cp "$resolver_tmp/inline.config.saved" "$resolver_inline_config"

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

case "$resolver_platform" in
  Linux:x86_64) resolver_runtime_mode=$(/usr/bin/stat -c '%a' "$resolver_runtime") ;;
  Darwin:*) resolver_runtime_mode=$(/usr/bin/stat -f '%Lp' "$resolver_runtime") ;;
esac
[ "$resolver_runtime_mode" = 644 ] || fail_case 'inactive runtime mode'
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

expect_failure 'selected value over per-value limit stays E_LIMIT' 'E_LIMIT value-size' \
  "$resolver_fixture/request-value-limit.json" "$resolver_fixture/map.json"

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
/bin/rmdir "$resolver_fixture/profile/.git/refs/replace" 2>/dev/null || :

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

resolver_fingerprints_after="$resolver_tmp/repository-fingerprints.after"
: > "$resolver_fingerprints_after"
for resolver_mapped_root in "${resolver_mapped_roots[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$resolver_mapped_root" \
    "$(repository_fingerprint "$resolver_mapped_root")" >> "$resolver_fingerprints_after"
done
/usr/bin/cmp -s "$resolver_fingerprints_before" "$resolver_fingerprints_after" || {
  /usr/bin/diff -u "$resolver_fingerprints_before" "$resolver_fingerprints_after" >&2 || :
  fail_case 'mapped repository fingerprint changed'
}
pass_case 'refs, config, and object stores remain byte-identical'

[ "$resolver_passed" -eq "$resolver_total" ] || exit 1
printf 'portable profile resolution: %d/%d targeted cases passed\n' "$resolver_passed" "$resolver_total"
printf 'supported tuple: %s; jq=%s; core=%s; helper-source=%s\n' \
  "$resolver_host" "$(sha256_file "$resolver_jq")" \
  "$(/usr/bin/git -C "$resolver_root" hash-object scripts/core-contract.sh)" \
  "$(sha256_file "$resolver_helper_source")"
