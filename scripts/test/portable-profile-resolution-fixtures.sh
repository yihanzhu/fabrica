#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

fixture_script_dir=${BASH_SOURCE[0]%/*}
fixture_repo=$(CDPATH='' cd -P -- "$fixture_script_dir/../.." && pwd -P)
fixture_core="$fixture_repo/scripts/core-contract.sh"

fixture_canonical() {
  "$fixture_jq" -S -c . > "$1"
}

fixture_init_repo() {
  fixture_path=$1
  fixture_format=$2
  /usr/bin/git init -q --object-format="$fixture_format" "$fixture_path"
  /usr/bin/git -C "$fixture_path" config user.name fixture
  /usr/bin/git -C "$fixture_path" config user.email fixture@example.invalid
}

fixture_commit() {
  fixture_path=$1
  GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
    /usr/bin/git -C "$fixture_path" add .
  GIT_AUTHOR_DATE='2000-01-01T00:00:00Z' GIT_COMMITTER_DATE='2000-01-01T00:00:00Z' \
    /usr/bin/git -C "$fixture_path" commit -q -m fixture
  /usr/bin/git -C "$fixture_path" rev-parse HEAD
}

fixture_git_ref() {
  fixture_id=$1
  fixture_path=$2
  fixture_algorithm=$3
  fixture_commit_id=$4
  fixture_file=$5
  fixture_line=$(/usr/bin/git -C "$fixture_path" ls-tree "$fixture_commit_id" -- "$fixture_file")
  fixture_meta=${fixture_line%%$'\t'*}
  IFS=' ' read -r fixture_mode fixture_type fixture_oid <<< "$fixture_meta"
  "$fixture_jq" -S -c -n --arg id "$fixture_id" --arg algorithm "$fixture_algorithm" \
    --arg commit "$fixture_commit_id" --arg path "$fixture_file" --arg type "$fixture_type" \
    --arg oid "$fixture_oid" --arg mode "$fixture_mode" \
    '{revision:{repository_id:$id,hash_algorithm:$algorithm,commit_id:$commit},
      location:{kind:"path",value:$path},object_type:$type,object_id:$oid,mode:$mode}'
}

fixture_locator() {
  "$fixture_jq" -S -c '{repository_id:.revision.repository_id,
    hash_algorithm:.revision.hash_algorithm,commit_id:.revision.commit_id,
    path:.location.value,object_id:.object_id}' <<< "$1"
}

fixture_digest() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

fixture_scope() {
  fixture_purpose=$1
  fixture_name=$2
  fixture_character=$3
  fixture_hash=$(/usr/bin/printf '%064d' 0 | /usr/bin/tr 0 "$fixture_character")
  "$fixture_jq" -S -c -n --arg purpose "$fixture_purpose" --arg name "$fixture_name" --arg hash "$fixture_hash" \
    '{purpose:$purpose,
      decision_record_ref:{content_id:("decision-"+$name),media_type:"application/json",sha256:$hash},
      subject_ref:{type:"artifact",value:{type:"content",value:{content_id:$name,media_type:"application/json",sha256:$hash}}},
      scope_sha256:$hash}'
}

if [ "$#" -ne 2 ]; then
  printf '%s\n' 'usage: portable-profile-resolution-fixtures.sh OUTPUT_ROOT JQ_1_6' >&2
  exit 64
fi
fixture_root=$1
fixture_jq=$2
case "$fixture_jq" in /*) ;; *) exit 1 ;; esac
[ -x "$fixture_jq" ] && [ -f "$fixture_jq" ] && [ ! -L "$fixture_jq" ] &&
  [ "$("$fixture_jq" --version)" = jq-1.6 ] || exit 1
[ ! -e "$fixture_root" ] || exit 1
/bin/mkdir -m 700 "$fixture_root"

fixture_assets="$fixture_root/assets"
fixture_manifests="$fixture_root/manifests"
fixture_profile="$fixture_root/profile"
fixture_init_repo "$fixture_assets" sha256
/bin/mkdir -p "$fixture_assets/packages" "$fixture_assets/config" "$fixture_assets/prompts" \
  "$fixture_assets/skills" "$fixture_assets/tools"
/usr/bin/printf '%s\n' producer-package > "$fixture_assets/packages/producer.bin"
/usr/bin/printf '%s\n' publisher-package > "$fixture_assets/packages/publisher.bin"
/usr/bin/printf '%s\n' reviewer-package > "$fixture_assets/packages/reviewer.bin"
/usr/bin/printf '%s\n' verifier-package > "$fixture_assets/packages/verifier.bin"
/usr/bin/printf '%s\n' '{"fixture":"$(touch /tmp/ystack-profile-resolver-must-not-run)","secret_like":"token-do-not-echo"}' > "$fixture_assets/config/producer.json"
/usr/bin/printf '%s\n' 'Produce only the requested change.' > "$fixture_assets/prompts/producer.md"
/usr/bin/printf '%s\n' 'Review the exact candidate.' > "$fixture_assets/prompts/reviewer.md"
/usr/bin/printf '%s\n' 'Bounded fixture skill.' > "$fixture_assets/skills/producer.md"
/usr/bin/printf '%s\n' tool-package > "$fixture_assets/tools/producer.bin"
/usr/bin/printf '%s\n' '{"tool":true}' > "$fixture_assets/tools/producer.json"
fixture_assets_commit=$(fixture_commit "$fixture_assets")
fixture_producer_package=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" packages/producer.bin)
fixture_publisher_package=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" packages/publisher.bin)
fixture_reviewer_package=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" packages/reviewer.bin)
fixture_verifier_package=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" packages/verifier.bin)
fixture_producer_config=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" config/producer.json)
fixture_producer_prompt=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" prompts/producer.md)
fixture_reviewer_prompt=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" prompts/reviewer.md)
fixture_producer_skill=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" skills/producer.md)
fixture_tool_package=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" tools/producer.bin)
fixture_tool_config=$(fixture_git_ref repo.assets "$fixture_assets" sha256 "$fixture_assets_commit" tools/producer.json)

fixture_config_scope=$(fixture_scope config-contract producer-config c)
fixture_tool=$("$fixture_jq" -S -c -n --argjson package "$fixture_tool_package" --argjson config "$fixture_tool_config" \
  '{tool_id:"tool.producer",tool_version:"v1",package_ref:$package,
    config_ref:{state:"present",value:$config}}')

fixture_init_repo "$fixture_manifests" sha1
/bin/mkdir -p "$fixture_manifests/manifests"
for fixture_role in producer publisher reviewer verifier; do
  case "$fixture_role" in
    producer)
      fixture_package=$fixture_producer_package
      fixture_execution=model
      fixture_capabilities='["core.harness.produce.v1"]'
      fixture_permissions='["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]'
      fixture_tools="[$fixture_tool]"
      fixture_extra=",\"config_contract_ref\":$fixture_config_scope"
      ;;
    publisher)
      fixture_package=$fixture_publisher_package
      fixture_execution=deterministic
      fixture_capabilities='[]'
      fixture_permissions='[]'
      fixture_tools='[]'
      fixture_extra=''
      ;;
    reviewer)
      fixture_package=$fixture_reviewer_package
      fixture_execution=model
      fixture_capabilities='["core.review.change.v1"]'
      fixture_permissions='["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.target.read.v1"]'
      fixture_tools='[]'
      fixture_extra=''
      ;;
    verifier)
      fixture_package=$fixture_verifier_package
      fixture_execution=deterministic
      fixture_capabilities='["core.verify.run.v1"]'
      fixture_permissions='["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.target.read.v1"]'
      fixture_tools='[]'
      fixture_extra=''
      ;;
  esac
  /usr/bin/printf '%s\n' \
    "{\"schema_version\":1,\"kind\":\"adapter_manifest\",\"id\":\"manifest.$fixture_role\",\"body\":{\"adapter_version\":\"v1\",\"package_ref\":$fixture_package,\"offered_roles\":[\"$fixture_role\"],\"offered_execution_kinds\":[\"$fixture_execution\"],\"offered_capabilities\":$fixture_capabilities,\"offered_permissions\":$fixture_permissions,\"offered_tools\":$fixture_tools$fixture_extra}}" |
    fixture_canonical "$fixture_manifests/manifests/$fixture_role.json"
  /bin/bash "$fixture_core" validate-document "$fixture_manifests/manifests/$fixture_role.json"
done
fixture_manifests_commit=$(fixture_commit "$fixture_manifests")

fixture_manifest_refs='{}'
fixture_manifest_locators='[]'
for fixture_role in producer publisher reviewer verifier; do
  fixture_manifest_file="$fixture_manifests/manifests/$fixture_role.json"
  fixture_manifest_digest=$(fixture_digest "$fixture_manifest_file")
  fixture_manifest_source=$(fixture_git_ref repo.manifests "$fixture_manifests" sha1 "$fixture_manifests_commit" "manifests/$fixture_role.json")
  fixture_manifest_locator=$(fixture_locator "$fixture_manifest_source")
  fixture_manifest_refs=$("$fixture_jq" -S -c --arg role "$fixture_role" --arg digest "$fixture_manifest_digest" \
    '. + {($role):{schema_version:1,kind:"adapter_manifest",id:("manifest."+$role),sha256:$digest}}' <<< "$fixture_manifest_refs")
  fixture_manifest_locators=$("$fixture_jq" -S -c --argjson locator "$fixture_manifest_locator" '. + [$locator]' <<< "$fixture_manifest_locators")
done

fixture_init_repo "$fixture_profile" sha1
/bin/mkdir -p "$fixture_profile/profiles"
fixture_bindings='[]'
for fixture_role in producer publisher reviewer verifier; do
  case "$fixture_role" in
    producer)
      fixture_package=$fixture_producer_package
      fixture_execution=model
      fixture_capabilities='["core.harness.produce.v1"]'
      fixture_permissions='["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.scratch.write.v1","core.perm.target.read.v1"]'
      fixture_tools="[$fixture_tool]"
      fixture_optional=$("$fixture_jq" -S -c -n --argjson config "$fixture_producer_config" \
        --argjson prompt "$fixture_producer_prompt" --argjson skill "$fixture_producer_skill" \
        '{config_ref:$config,prompt_ref:$prompt,skill_refs:[$skill],
          model_request:{provider_id:"provider.example",model_id:"model.example",effort_id:"high"}}')
      ;;
    publisher)
      fixture_package=$fixture_publisher_package; fixture_execution=deterministic
      fixture_capabilities='[]'; fixture_permissions='[]'; fixture_tools='[]'; fixture_optional='{"skill_refs":[]}'
      ;;
    reviewer)
      fixture_package=$fixture_reviewer_package; fixture_execution=model
      fixture_capabilities='["core.review.change.v1"]'
      fixture_permissions='["core.perm.evidence.write.v1","core.perm.model.invoke.v1","core.perm.target.read.v1"]'
      fixture_tools='[]'
      fixture_optional=$("$fixture_jq" -S -c -n --argjson prompt "$fixture_reviewer_prompt" \
        '{prompt_ref:$prompt,skill_refs:[],model_request:{provider_id:"provider.example",model_id:"review.example",effort_id:"high"}}')
      ;;
    verifier)
      fixture_package=$fixture_verifier_package; fixture_execution=deterministic
      fixture_capabilities='["core.verify.run.v1"]'
      fixture_permissions='["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.target.read.v1"]'
      fixture_tools='[]'; fixture_optional='{"skill_refs":[]}'
      ;;
  esac
  case "$fixture_role" in
    producer) fixture_authority_character=1 ;;
    publisher) fixture_authority_character=2 ;;
    reviewer) fixture_authority_character=3 ;;
    verifier) fixture_authority_character=4 ;;
  esac
  fixture_authority=$(fixture_scope authority "authority-$fixture_role" "$fixture_authority_character")
  fixture_manifest_ref=$("$fixture_jq" -c --arg role "$fixture_role" '.[$role]' <<< "$fixture_manifest_refs")
  fixture_binding=$("$fixture_jq" -S -c -n --arg role "$fixture_role" --arg execution "$fixture_execution" \
    --argjson manifest "$fixture_manifest_ref" --argjson package "$fixture_package" \
    --argjson tools "$fixture_tools" --argjson capabilities "$fixture_capabilities" \
    --argjson permissions "$fixture_permissions" --argjson authority "$fixture_authority" \
    --argjson optional "$fixture_optional" \
    '{binding_id:("binding."+$role),role:$role,manifest_ref:$manifest,execution_kind:$execution,
      adapter_instance_id:("instance."+$role),principal_id:("principal."+$role),
      execution_boundary_id:("boundary."+$role),authority_ref:$authority,package_ref:$package,
      requested_tools:$tools,requested_capabilities:$capabilities,requested_permissions:$permissions} + $optional')
  fixture_bindings=$("$fixture_jq" -S -c --argjson binding "$fixture_binding" '. + [$binding] | sort_by(.binding_id)' <<< "$fixture_bindings")
done
"$fixture_jq" -S -c -n --argjson bindings "$fixture_bindings" \
  '{schema_version:1,kind:"profile",id:"profile.example",body:{profile_version:"v1",bindings:$bindings}}' \
  > "$fixture_profile/profiles/default.json"
/bin/bash "$fixture_core" validate-document "$fixture_profile/profiles/default.json"
/bin/cp "$fixture_profile/profiles/default.json" "$fixture_profile/default.json"
fixture_profile_commit=$(fixture_commit "$fixture_profile")
fixture_profile_source=$(fixture_git_ref repo.profile "$fixture_profile" sha1 "$fixture_profile_commit" profiles/default.json)
fixture_profile_locator=$(fixture_locator "$fixture_profile_source")
fixture_selection=$(fixture_scope selection selection 8)
fixture_context=$(fixture_scope repository-context repository-context 9)
"$fixture_jq" -S -c -n --argjson profile "$fixture_profile_locator" --argjson manifests "$fixture_manifest_locators" \
  --argjson selection "$fixture_selection" --argjson context "$fixture_context" \
  '{version:1,profile_source:$profile,manifest_sources:$manifests,
    selection_ref:$selection,repository_context_ref:$context}' > "$fixture_root/request.json"
"$fixture_jq" -S -c -n --arg assets "$fixture_assets" --arg manifests "$fixture_manifests" --arg profile "$fixture_profile" \
  '{version:1,repositories:[
    {repository_id:"repo.assets",root:$assets},
    {repository_id:"repo.manifests",root:$manifests},
    {repository_id:"repo.profile",root:$profile}]}' > "$fixture_root/map.json"

/usr/bin/printf 'request=%s\nmap=%s\nprofile=%s\nmanifests=%s\nassets=%s\n' \
  "$fixture_root/request.json" "$fixture_root/map.json" "$fixture_profile" "$fixture_manifests" "$fixture_assets"
