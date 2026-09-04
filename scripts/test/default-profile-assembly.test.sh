#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
profile="$root/profiles/default/v1/profile.json"
manifest_root="$root/profiles/default/v1/manifests"
manifests=("$manifest_root"/*.json)
roadmap="$root/ROADMAP.md"
roadmap_sha='1466262c8994d637a02cc3503c35e3254ecce28479f9847589cb112e42b00107'
package_commit='a637451d4b3fbef6b516a9c08f68c0dde46a7059'
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-default-profile.XXXXXX")
download=''
cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then
    /bin/rm -f -- "$download"
  fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64)
    asset='jq-linux64'
    asset_sha='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44'
    ;;
  Darwin:x86_64|Darwin:arm64)
    asset='jq-osx-amd64'
    asset_sha='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef'
    ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac

cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$cache"
jq_bin="$cache/$asset"
if [ ! -f "$jq_bin" ] || [ -L "$jq_bin" ] ||
   [ "$(sha_file "$jq_bin")" != "$asset_sha" ]; then
  download=$(/usr/bin/mktemp "$cache/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$asset" \
    -o "$download"
  [ "$(sha_file "$download")" = "$asset_sha" ] || fail jq-download-digest
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_bin"
  download=''
fi

jq_runtime="$tmp/bin"
/bin/mkdir "$jq_runtime"
if [ "$platform" = Darwin:arm64 ]; then
  /bin/ln -s "$jq_bin" "$jq_runtime/jq-real"
  /usr/bin/printf '%s\n' '#!/bin/sh' \
    'exec /usr/bin/arch -x86_64 "${0%/*}/jq-real" "$@"' >"$jq_runtime/jq"
  /bin/chmod 0555 "$jq_runtime/jq"
else
  /bin/ln -s "$jq_bin" "$jq_runtime/jq"
fi
export PATH="$jq_runtime:$PATH"

[ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$asset_sha" ] ||
  fail jq-cache-digest
[ "$(jq --version)" = jq-1.6 ] || fail jq-version
[ "${#manifests[@]}" -eq 7 ] || fail manifest-count
scripts_core="$root/scripts/core-contract.sh"
"$scripts_core" validate-document "$profile" || fail profile-document
for manifest in "${manifests[@]}"; do
  "$scripts_core" validate-document "$manifest" || fail "manifest-${manifest##*/}"
done
ok 'profile and seven manifests pass core v2 document validation'

jq -e '
  .id == "profile.default.v1" and .body.profile_version == "v1" and
  (.body.bindings | length) == 7 and
  ([.body.bindings[].role] | sort) ==
    ["ci","forge","identity","producer","publisher","reviewer","verifier"] and
  ([.body.bindings[].binding_id] | unique | length) == 7 and
  ([.body.bindings[].adapter_instance_id] | unique | length) == 7 and
  ([.body.bindings[].principal_id] | unique | length) == 7 and
  ([.body.bindings[].execution_boundary_id] | unique | length) == 7 and
  all(.body.bindings[] | select(.role|IN("forge","producer","publisher","reviewer","verifier"));
      has("authority_ref")) and
  ([.body.bindings[] | select(has("authority_ref"))] | length) == 5 and
  all(.body.bindings[] | select(.role|IN("ci","identity"));
      has("authority_ref") | not) and
  all(.body.bindings[] | select(.role|IN("ci","identity","publisher"));
      .requested_capabilities == [] and .requested_permissions == [])
' "$profile" >/dev/null || fail role-graph
ok 'roles and protected boundaries are complete and separated'

[ "$(sha_file "$roadmap")" = "$roadmap_sha" ] || fail roadmap-digest
jq -e --arg digest "$roadmap_sha" '
  all(.body.bindings[] | select(has("authority_ref"));
      .authority_ref.decision_record_ref == {
        content_id:"roadmap",
        media_type:"text/markdown",
        sha256:$digest
      })
' "$profile" >/dev/null || fail authority-decision-record
ok 'protected authority scopes cite the accepted Roadmap decision record'

for manifest in "${manifests[@]}"; do
  digest=$(sha_file "$manifest")
  id=$(jq -r .id "$manifest")
  jq -e --arg id "$id" --arg digest "$digest" --slurpfile manifest "$manifest" '
    [.body.bindings[] |
     select(.manifest_ref.id==$id and .manifest_ref.sha256==$digest)] as $matches |
    ($matches | length) == 1 and
    ($matches[0] as $binding | $manifest[0].body as $offered |
     ($offered.offered_roles | index($binding.role)) != null and
     ($offered.offered_execution_kinds | index($binding.execution_kind)) != null and
     all($binding.requested_capabilities[]; . as $item |
         ($offered.offered_capabilities | index($item)) != null) and
     all($binding.requested_permissions[]; . as $item |
         ($offered.offered_permissions | index($item)) != null) and
     all($binding.requested_tools[]; . as $item |
         ($offered.offered_tools | index($item)) != null) and
     $binding.package_ref == $offered.package_ref)
  ' "$profile" >/dev/null || fail "manifest-graph-$id"
  commit=$(jq -r .body.package_ref.revision.commit_id "$manifest")
  [ "$commit" = "$package_commit" ] || fail "package-commit-$id"
  path=$(jq -r .body.package_ref.location.value "$manifest")
  oid=$(jq -r .body.package_ref.object_id "$manifest")
  mode=$(jq -r .body.package_ref.mode "$manifest")
  type=$(jq -r .body.package_ref.object_type "$manifest")
  record=$(git -C "$root" ls-tree HEAD "$path")
  [ "$record" = "$mode $type $oid"$'\t'"$path" ] || fail "package-object-$id"
done
while IFS= read -r ref; do
  commit=$(jq -r .revision.commit_id <<<"$ref")
  path=$(jq -r .location.value <<<"$ref")
  [ "$commit" = "$package_commit" ] || fail "prompt-commit-$path"
  oid=$(jq -r .object_id <<<"$ref")
  mode=$(jq -r .mode <<<"$ref")
  type=$(jq -r .object_type <<<"$ref")
  record=$(git -C "$root" ls-tree HEAD "$path")
  [ "$record" = "$mode $type $oid"$'\t'"$path" ] || fail "prompt-object-$path"
done < <(jq -c '.body.bindings[] | .prompt_ref? // empty' "$profile")
ok 'every manifest graph and selected Git object is exact'

jq -e '
  all(.body.bindings[];
      .requested_tools == [] and .skill_refs == []) and
  (.body.bindings[] | select(.role=="producer") |
    .model_request.provider_id=="anthropic" and .prompt_ref.location.value=="routines/coder.md") and
  (.body.bindings[] | select(.role=="reviewer") |
    .model_request.provider_id=="openai" and .prompt_ref.location.value=="reviewer/codex-review.md")
' "$profile" >/dev/null || fail default-selection
ok 'default model preferences are data and no tool is granted'

printf 'default profile assembly: %s focused checks passed\n' "$pass"
