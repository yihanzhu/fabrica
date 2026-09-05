#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
profile="$root/profiles/default/v1/profile.json"
manifest_root="$root/profiles/default/v1/manifests"
manifests=("$manifest_root"/*.json)
producer_manifest="$manifest_root/claude-code-producer.json"
producer_config="$root/profiles/default/v1/producer-config.json"
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

history_repo="$tmp/history.git"
history_home="$tmp/home"
/bin/mkdir "$history_home"
/usr/bin/env -i HOME="$history_home" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
  /usr/bin/git init --bare -q "$history_repo"
history_git() {
  /usr/bin/env -i HOME="$history_home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git -C "$history_repo" "$@"
}
origin_url=$(/usr/bin/git -C "$root" remote get-url origin)
[[ "$origin_url" =~ ^https://[^/@[:space:]]+/[^?#[:space:]]+$ ]] ||
  fail origin-url
history_git -c credential.helper= -c core.askPass= fetch -q --no-tags --depth=1 \
  "$origin_url" "+$package_commit:refs/ystack/package"
[ "$(history_git rev-parse 'refs/ystack/package^{commit}')" = "$package_commit" ] ||
  fail package-fetch
[ "$(history_git rev-list --count refs/ystack/package)" -eq 1 ] ||
  fail package-fetch-depth
[ -z "$(history_git for-each-ref --format='%(refname)' refs/tags)" ] ||
  fail package-fetch-tags

[ "${#manifests[@]}" -eq 6 ] || fail manifest-count
scripts_core="$root/scripts/core-contract.sh"
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$scripts_core")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail core-generation
modules="$root/core/v2/generations/$generation/modules"
[ -d "$modules" ] && [ ! -L "$modules" ] || fail core-modules
"$scripts_core" validate-document "$profile" || fail profile-document
for manifest in "${manifests[@]}"; do
  "$scripts_core" validate-document "$manifest" || fail "manifest-${manifest##*/}"
done
ok 'profile and six manifests pass core v2 document validation'

producer_config_ref=$(jq -c '.body.bindings[] | select(.role=="producer") | .config_ref' "$profile")
[ "$(jq -r 'type' <<<"$producer_config_ref")" = object ] || fail producer-config-ref
config_commit=$(jq -r '.revision.commit_id' <<<"$producer_config_ref")
config_path=$(jq -r '.location.value' <<<"$producer_config_ref")
config_oid=$(jq -r '.object_id' <<<"$producer_config_ref")
config_mode=$(jq -r '.mode' <<<"$producer_config_ref")
config_type=$(jq -r '.object_type' <<<"$producer_config_ref")
[ "$config_path" = 'profiles/default/v1/producer-config.json' ] || fail producer-config-path
[ "$config_oid" = "$(git -C "$root" hash-object "$producer_config")" ] ||
  fail producer-config-blob
history_git -c credential.helper= -c core.askPass= fetch -q --no-tags --depth=1 \
  "$origin_url" "+$config_commit:refs/ystack/producer-config"
[ "$(history_git rev-parse 'refs/ystack/producer-config^{commit}')" = "$config_commit" ] ||
  fail producer-config-fetch
[ "$(history_git rev-list --count refs/ystack/producer-config)" -eq 1 ] ||
  fail producer-config-fetch-depth
config_record=$(history_git ls-tree "$config_commit" "$config_path")
[ "$config_record" = "$config_mode $config_type $config_oid"$'\t'"$config_path" ] ||
  fail producer-config-object
config_sha=$(sha_file "$producer_config")
jq -e --arg config_sha "$config_sha" '
  .body.config_contract_ref as $contract |
  $contract.purpose == "config-contract" and
  $contract.scope_sha256 == $config_sha and
  $contract.decision_record_ref == {
    content_id:"producer-config",media_type:"application/json",sha256:$config_sha
  } and
  $contract.subject_ref == {
    type:"artifact",
    value:{type:"content",value:{
      content_id:"producer-config",media_type:"application/json",sha256:$config_sha
    }}
  }
' "$producer_manifest" >/dev/null || fail producer-config-contract
ok 'the producer config contract and Git object are exact at their recorded revision'

jq -e '
  .id == "profile.default.v1" and .body.profile_version == "v1" and
  (.body.bindings | length) == 6 and
  ([.body.bindings[].role] | sort) ==
    ["ci","forge","producer","publisher","reviewer","verifier"] and
  ([.body.bindings[].binding_id] | unique | length) == 6 and
  ([.body.bindings[].adapter_instance_id] | unique | length) == 6 and
  ([.body.bindings[].principal_id] | unique | length) == 6 and
  ([.body.bindings[].execution_boundary_id] | unique | length) == 6 and
  all(.body.bindings[] | select(.role|IN("forge","producer","publisher","reviewer","verifier"));
      has("authority_ref")) and
  ([.body.bindings[] | select(has("authority_ref"))] | length) == 5 and
  all(.body.bindings[] | select(.role=="ci");
    has("authority_ref") | not) and
  all(.body.bindings[] | select(.role|IN("ci","publisher"));
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
  record=$(history_git ls-tree "$commit" "$path")
  [ "$record" = "$mode $type $oid"$'\t'"$path" ] || fail "package-object-$id"
done
while IFS= read -r ref; do
  commit=$(jq -r .revision.commit_id <<<"$ref")
  path=$(jq -r .location.value <<<"$ref")
  [ "$commit" = "$package_commit" ] || fail "prompt-commit-$path"
  oid=$(jq -r .object_id <<<"$ref")
  mode=$(jq -r .mode <<<"$ref")
  type=$(jq -r .object_type <<<"$ref")
  record=$(history_git ls-tree "$commit" "$path")
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

producer_source_repo="$tmp/producer-source"
/usr/bin/git init -q "$producer_source_repo"
/bin/mkdir "$producer_source_repo/manifests"
/bin/cp "$profile" "$producer_source_repo/profile.json"
/bin/cp "$manifest_root"/*.json "$producer_source_repo/manifests/"
/usr/bin/git -C "$producer_source_repo" add profile.json manifests
/usr/bin/git -C "$producer_source_repo" -c user.name=ystack-test \
  -c user.email=ystack-test@example.invalid commit -q -m producer-source
producer_source_commit=$(/usr/bin/git -C "$producer_source_repo" rev-parse HEAD)
producer_manifest_pairs="$tmp/producer-manifest-pairs.json"
producer_manifest_sources="$tmp/producer-manifest-sources.json"
for manifest in "${manifests[@]}"; do
  name=${manifest##*/}
  manifest_id=$(jq -r .id "$manifest")
  manifest_sha=$(sha_file "$manifest")
  IFS=$' \t' read -r manifest_mode manifest_type manifest_oid _ < <(
    /usr/bin/git -C "$producer_source_repo" ls-tree "$producer_source_commit" "manifests/$name")
  jq -S -c -n --arg id "$manifest_id" --arg commit "$producer_source_commit" \
    --arg path "manifests/$name" --arg mode "$manifest_mode" --arg type "$manifest_type" \
    --arg oid "$manifest_oid" --arg sha "$manifest_sha" '
      {id:$id,source:{source:{revision:{repository_id:"repo.default-profile-test",
       hash_algorithm:"sha1",commit_id:$commit},location:{kind:"path",value:$path},
       object_type:$type,object_id:$oid,mode:$mode},value_format:"canonical-json",value_sha256:$sha}}'
done >"$tmp/producer-manifest-records.jsonl"
jq -S -s '.' "$tmp/producer-manifest-records.jsonl" >"$producer_manifest_sources"
for manifest in "${manifests[@]}"; do
  manifest_sha=$(sha_file "$manifest")
  jq -S -c --arg sha "$manifest_sha" '{content:.,sha256:$sha}' "$manifest"
done | jq -S -s '.' >"$producer_manifest_pairs"
IFS=$' \t' read -r producer_profile_mode producer_profile_type producer_profile_oid _ < <(
  /usr/bin/git -C "$producer_source_repo" ls-tree "$producer_source_commit" profile.json)
producer_profile_source="$tmp/producer-profile-source.json"
jq -S -c -n --arg commit "$producer_source_commit" --arg mode "$producer_profile_mode" \
  --arg type "$producer_profile_type" --arg oid "$producer_profile_oid" '
  {source:{revision:{repository_id:"repo.default-profile-test",hash_algorithm:"sha1",
    commit_id:$commit},location:{kind:"path",value:"profile.json"},object_type:$type,
    object_id:$oid,mode:$mode},value_format:"canonical-json",value_sha256:""}' \
  >"$producer_profile_source"

build_producer_input() {
  local case_profile=$1 case_state=$2 case_input=$3
  local case_resolved="$case_input.resolved" case_request="$case_input.request"
  local case_snapshot="$case_input.snapshot" case_profile_sha case_resolved_sha
  local case_request_sha case_snapshot_sha
  case_profile_sha=$(sha_file "$case_profile")
  jq -L "$modules" -L "$root/scripts/test" -S -c -n \
    --slurpfile profile_doc "$case_profile" --slurpfile profile_source "$producer_profile_source" \
    --slurpfile manifests "$producer_manifest_pairs" --slurpfile sources "$producer_manifest_sources" \
    --arg profile_sha "$case_profile_sha" '
    import "portable-core-stage-request-fixtures" as fixture;
    def present($value): {state:"present",value:$value};
    def absent: {state:"absent"};
    def source_value($source;$format;$sha):
      {source:$source,value_format:$format,value_sha256:$sha};
    def pair_for($id): first($manifests[0][] | select(.content.id==$id));
    def source_for($id): first($sources[0][] | select(.id==$id) | .source);
    ($profile_source[0] | .value_sha256=$profile_sha) as $profile_source |
    {schema_version:2,kind:"resolved_profile",id:"resolved.example",body:{
      profile_ref:{schema_version:2,kind:"profile",id:$profile_doc[0].id,sha256:$profile_sha},
      profile_source:$profile_source,selection_ref:fixture::selection_scope,
      repository_context_ref:fixture::repository_context_scope,
      bindings:[$profile_doc[0].body.bindings[] as $binding |
        pair_for($binding.manifest_ref.id) as $manifest |
        {binding:$binding,adapter_implementation:{id:$manifest.content.id,
          version:$manifest.content.body.adapter_version},
         manifest_source:source_for($binding.manifest_ref.id),
         package_source:source_value($binding.package_ref;"raw-bytes";$profile_sha),
         config_source:(if $binding | has("config_ref") then
           present(source_value($binding.config_ref;"raw-bytes";$profile_sha)) else absent end),
         prompt_source:(if $binding | has("prompt_ref") then
           present(source_value($binding.prompt_ref;"raw-bytes";$profile_sha)) else absent end),
         skill_sources:($binding.skill_refs | map(source_value(.;"raw-bytes";$profile_sha))),
         tool_sources:($binding.requested_tools | map({tool_id:.tool_id,
           package_source:source_value(.package_ref;"raw-bytes";$profile_sha),
           config_source:.config_ref}))
        }]}}
  ' >"$case_resolved"
  case_resolved_sha=$(sha_file "$case_resolved")
  jq -L "$root/scripts/test" -S -c -n --arg resolved_sha "$case_resolved_sha" '
    import "portable-core-stage-request-fixtures" as fixture;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    fixture::request_doc("producer";$resolved_sha) | v2
  ' >"$case_request"
  case_request_sha=$(sha_file "$case_request")
  jq -L "$modules" -L "$root/scripts/test" -S -c -n \
    --slurpfile request_doc "$case_request" --slurpfile resolved_doc "$case_resolved" \
    --arg state "$case_state" --arg request_sha "$case_request_sha" \
    --arg resolved_sha "$case_resolved_sha" '
    import "stage_request" as request;
    def present($value): {state:"present",value:$value};
    def absent: {state:"absent"};
    def fact($id;$value;$n): {state:"recorded",value:$value,
      source_ref:{content_id:$id,media_type:"application/json",sha256:($n*64)}};
    request::expected_execution_projection($request_doc[0].body;$resolved_doc[0].body) as $projection |
    ($resolved_doc[0].body.bindings[] | select(.binding.role=="producer") | .binding) as $binding |
    {schema_version:1,kind:"claude_code_producer_snapshot",id:"snapshot.assembly",body:{
      attempt:{attempt_id:"attempt.assembly",attempt_number:1,
       started_at:"2026-08-30T00:01:00Z",finished_at:"2026-08-30T00:02:00Z",
       recorded_at:"2026-08-30T00:03:00Z"},
      execution:{performer:$projection.performer,actual_binding:$projection.actual_binding,
       environment:$projection.environment,used_capability:$projection.used_capability,
       metadata:{kind:"model",provider:fact("fact.provider";$binding.model_request.provider_id;"1"),
        model:fact("fact.model";$binding.model_request.model_id;"2"),
        snapshot:fact("fact.snapshot";"claude-code.v1";"3"),
        effort:fact("fact.effort";$binding.model_request.effort_id;"4"),
        prompt:fact("fact.prompt";$binding.prompt_ref;"5"),skills:fact("fact.skills";$binding.skill_refs;"6"),
        tools:fact("fact.tools";$binding.requested_tools;"7")}},
      observed_at:"2026-08-30T00:04:00Z",
      output:(if $state=="changed" then present({content_id:"producer.patch",
        media_type:"text/x-diff",sha256:("a"*64)}) else absent end),
      provider_metadata:{message:{state:"absent"}},
      request_ref:{schema_version:2,kind:"stage_request",id:$request_doc[0].id,sha256:$request_sha},
      resolved_profile_ref:{schema_version:2,kind:"resolved_profile",id:$resolved_doc[0].id,sha256:$resolved_sha},
      state:$state,target_revision:$request_doc[0].body.target_revision.value}}
  ' >"$case_snapshot"
  case_snapshot_sha=$(sha_file "$case_snapshot")
  jq -S -c -n --slurpfile snapshot "$case_snapshot" --slurpfile request_doc "$case_request" \
    --slurpfile resolved_doc "$case_resolved" --slurpfile manifest_doc "$producer_manifest" \
    --arg snapshot_sha "$case_snapshot_sha" --arg request_sha "$case_request_sha" \
    --arg resolved_sha "$case_resolved_sha" --arg manifest_sha "$(sha_file "$producer_manifest")" '
    {snapshot:$snapshot[0],trust_context:{schema_version:1,kind:"adapter_trust_context",
      id:"trust.assembly",body:{binding_id:"binding.producer",expected_attempt_id:"attempt.assembly",
       expected_attempt_number:1,manifest:{content:$manifest_doc[0],sha256:$manifest_sha},
       request:{content:$request_doc[0],sha256:$request_sha},
       resolved_profile:{content:$resolved_doc[0],sha256:$resolved_sha},
       target_revision:$request_doc[0].body.target_revision.value,
       verified_snapshot:{content:$snapshot[0],sha256:$snapshot_sha}}}}
  ' >"$case_input"
}

producer_normalizer="$root/adapters/claude-code-producer/v1/normalize.jq"
build_producer_input "$profile" changed "$tmp/producer-changed.input"
jq -L "$modules" -S -c -f "$producer_normalizer" "$tmp/producer-changed.input" \
  >"$tmp/producer-changed.output" || fail producer-normalizer-changed
jq -e '.state=="changed" and .observation.binding.config_ref.state=="present"' \
  "$tmp/producer-changed.output" >/dev/null || fail producer-normalizer-changed-output
build_producer_input "$profile" no-change "$tmp/producer-no-change.input"
jq -L "$modules" -S -c -f "$producer_normalizer" "$tmp/producer-no-change.input" \
  >"$tmp/producer-no-change.output" || fail producer-normalizer-no-change
jq -e '.state=="no-change" and .observation.result.output_ref.state=="absent"' \
  "$tmp/producer-no-change.output" >/dev/null || fail producer-normalizer-no-change-output
jq -S -c 'del(.body.bindings[] | select(.role=="producer").config_ref)' "$profile" \
  >"$tmp/producer-missing-config.profile"
build_producer_input "$tmp/producer-missing-config.profile" changed "$tmp/producer-missing-config.input"
if jq -L "$modules" -S -c -f "$producer_normalizer" "$tmp/producer-missing-config.input" \
    >"$tmp/producer-missing-config.output" 2>"$tmp/producer-missing-config.error"; then
  fail producer-normalizer-missing-config
fi
grep -Fq E_TRUST "$tmp/producer-missing-config.error" || fail producer-normalizer-missing-config-error
ok 'the assembled producer binding normalizes changed and unchanged snapshots and rejects a missing config'

printf 'default profile assembly: %s focused checks passed\n' "$pass"
