#!/usr/bin/env bash
# shellcheck disable=SC2016

PROFILE_RESOLUTION_CORE_MERGE='48f726cdebed4a5c8683ba2a2268c8e2b662208c'
PROFILE_RESOLUTION_CONTRACTS_BLOB='8efe7582480d179463e0e88aac9a7874689786d1'
PROFILE_RESOLUTION_WRAPPER_BLOB='ee36af60aeb615550ebbc3b0d42b7caa184ff96c'
PROFILE_RESOLUTION_SCHEMA_MAJOR='1'

profile_resolution_error() {
  case "$1" in
    E_USAGE|E_INPUT|E_RUNTIME|E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION|E_REPOSITORY|E_OBJECT) ;;
    *) set -- E_RUNTIME unexpected ;;
  esac
  if [ "$#" -eq 2 ]; then
    case "$2" in
      usage|binding|dependency|unexpected|request-shape|manifest-count|locator-shape|locator-duplicate|map-shape|locator-map-missing|map-missing|map-extra|map-duplicate|repository-duplicate|manifest-source-ambiguous|manifest-source-missing|manifest-source-extra|object-format|repository-layout|repository-config|repository-state|object-missing|object-type|object-mode|object-oid|object-path|value-size|scratch-size|time-limit) ;;
      *) set -- E_RUNTIME unexpected ;;
    esac
  fi
  if [ "$#" -eq 1 ]; then
    printf '%s\n' "$1" >&3
  else
    printf '%s %s\n' "$1" "$2" >&3
  fi
  return 1
}

profile_resolution_cleanup() {
  if [ -n "${profile_resolution_scratch:-}" ] &&
     [ -d "$profile_resolution_scratch" ] &&
     [ ! -L "$profile_resolution_scratch" ]; then
    /bin/rm -rf -- "$profile_resolution_scratch" >/dev/null 2>&1 || :
  fi
}

profile_resolution_sha256() {
  /usr/bin/shasum -a 256 -- "$1" | {
    IFS=' ' read -r profile_resolution_digest _ || return 1
    case "$profile_resolution_digest" in
      *[!0-9a-f]*|'') return 1 ;;
    esac
    [ "${#profile_resolution_digest}" -eq 64 ] || return 1
    printf '%s\n' "$profile_resolution_digest"
  }
}

profile_resolution_sha256_text() {
  profile_resolution_digest_line=$(/usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256) || return 1
  IFS=' ' read -r profile_resolution_digest _ <<< "$profile_resolution_digest_line" || return 1
  case "$profile_resolution_digest" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#profile_resolution_digest}" -eq 64 ] || return 1
  printf '%s\n' "$profile_resolution_digest"
}

profile_resolution_snapshot_input() {
  profile_resolution_input=$1
  profile_resolution_destination=$2
  if [ ! -f "$profile_resolution_input" ] || [ -L "$profile_resolution_input" ]; then
    return 1
  fi
  /bin/dd if="$profile_resolution_input" of="$profile_resolution_destination" bs=1048577 count=1 2>/dev/null || return 1
  profile_resolution_bytes=$(/usr/bin/wc -c < "$profile_resolution_destination") || return 1
  profile_resolution_bytes=${profile_resolution_bytes//[[:space:]]/}
  [ "$profile_resolution_bytes" -le 1048576 ] || return 2
}

profile_resolution_canonicalize() {
  profile_resolution_source=$1
  profile_resolution_destination=$2
  "$YSTACK_RESOLVER_JQ" -S -c . "$profile_resolution_source" > "$profile_resolution_destination" 2>/dev/null || return 1
  /usr/bin/cmp -s "$profile_resolution_source" "$profile_resolution_destination" || return 2
}

profile_resolution_jq() {
  profile_resolution_command=$1
  profile_resolution_input_file=$2
  "$YSTACK_RESOLVER_JQ" -L "$profile_resolution_repo/resolver/v1" -S -c \
    --arg command "$profile_resolution_command" \
    -f "$profile_resolution_repo/resolver/v1/profile-resolution.jq" \
    "$profile_resolution_input_file" 2>/dev/null
}

profile_resolution_core_validate() {
  profile_resolution_core_stderr=$1
  shift
  : > "$profile_resolution_core_stderr"
  if /bin/bash "$profile_resolution_core" "$@" > "$profile_resolution_scratch/core.stdout" \
       2> "$profile_resolution_core_stderr"; then
    [ ! -s "$profile_resolution_scratch/core.stdout" ] &&
      [ ! -s "$profile_resolution_core_stderr" ] || return 2
    return 0
  fi
  [ ! -s "$profile_resolution_scratch/core.stdout" ] || return 2
  profile_resolution_core_line=$(/usr/bin/sed -n '1p' "$profile_resolution_core_stderr")
  [ "$profile_resolution_core_line" = "$(/usr/bin/sed -n '$p' "$profile_resolution_core_stderr")" ] || return 2
  case "$profile_resolution_core_line" in
    E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION) printf '%s\n' "$profile_resolution_core_line" >&3; return 1 ;;
    *) return 2 ;;
  esac
}

profile_resolution_map_root() {
  profile_resolution_map_id=$1
  "$YSTACK_RESOLVER_JQ" -r --arg id "$profile_resolution_map_id" \
    '.repositories[] | select(.repository_id == $id) | .root' \
    "$profile_resolution_map_snapshot"
}

profile_resolution_snapshot_repository() {
  profile_resolution_repository_id=$1
  while IFS=$'\t' read -r profile_resolution_record_id _; do
    [ "$profile_resolution_record_id" != "$profile_resolution_repository_id" ] || return 0
  done < "$profile_resolution_snapshots"
  profile_resolution_root=$(profile_resolution_map_root "$profile_resolution_repository_id") || return 1
  [ -n "$profile_resolution_root" ] || return 1
  profile_resolution_slot=$(profile_resolution_sha256_text "$profile_resolution_repository_id") || return 1
  profile_resolution_destination="$profile_resolution_scratch/repositories/$profile_resolution_slot"
  profile_resolution_receipt="$profile_resolution_scratch/receipt"
  : > "$profile_resolution_receipt"
  if ! "$YSTACK_RESOLVER_HELPER" snapshot-repository "$profile_resolution_root" \
       "$profile_resolution_destination" "$profile_resolution_admin_remaining" \
       "$profile_resolution_object_remaining" "$profile_resolution_entry_remaining" \
       "$profile_resolution_name_remaining" "$profile_resolution_global_remaining" \
       > "$profile_resolution_receipt" 2> "$profile_resolution_scratch/helper.stderr"; then
    profile_resolution_helper_error=$(/usr/bin/sed -n '1p' "$profile_resolution_scratch/helper.stderr")
    case "$profile_resolution_helper_error" in
      'E_LIMIT '*) printf '%s\n' "$profile_resolution_helper_error" >&3 ;;
      'E_REPOSITORY '*) printf '%s\n' "$profile_resolution_helper_error" >&3 ;;
      *) profile_resolution_error E_RUNTIME unexpected ;;
    esac
    return 2
  fi
  IFS=$'\t' read -r profile_resolution_ok profile_resolution_algorithm \
    profile_resolution_identity profile_resolution_admin_bytes profile_resolution_object_bytes \
    profile_resolution_entries profile_resolution_name_bytes profile_resolution_global_bytes \
    < "$profile_resolution_receipt" || return 1
  [ "$profile_resolution_ok" = ok ] || return 1
  case "$profile_resolution_algorithm" in sha1|sha256) ;; *) return 1 ;; esac
  case "$profile_resolution_identity" in *[!0-9a-f:]*|'') return 1 ;; esac
  for profile_resolution_number in "$profile_resolution_admin_bytes" "$profile_resolution_object_bytes" \
    "$profile_resolution_entries" "$profile_resolution_name_bytes" "$profile_resolution_global_bytes"; do
    case "$profile_resolution_number" in ''|*[!0-9]*) return 1 ;; esac
  done
  [ "$profile_resolution_admin_bytes" -le "$profile_resolution_admin_remaining" ] &&
    [ "$profile_resolution_object_bytes" -le "$profile_resolution_object_remaining" ] &&
    [ "$profile_resolution_entries" -le "$profile_resolution_entry_remaining" ] &&
    [ "$profile_resolution_name_bytes" -le "$profile_resolution_name_remaining" ] &&
    [ "$profile_resolution_global_bytes" -le "$profile_resolution_global_remaining" ] || return 1
  profile_resolution_admin_remaining=$((profile_resolution_admin_remaining - profile_resolution_admin_bytes))
  profile_resolution_object_remaining=$((profile_resolution_object_remaining - profile_resolution_object_bytes))
  profile_resolution_entry_remaining=$((profile_resolution_entry_remaining - profile_resolution_entries))
  profile_resolution_name_remaining=$((profile_resolution_name_remaining - profile_resolution_name_bytes))
  profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_global_bytes))
  while IFS=$'\t' read -r _ _ profile_resolution_record_identity _; do
    if [ "$profile_resolution_record_identity" = "$profile_resolution_identity" ]; then
      profile_resolution_error E_REPOSITORY repository-duplicate
      return 2
    fi
  done < "$profile_resolution_snapshots"
  /usr/bin/printf '%s\t%s\t%s\t%s\n' "$profile_resolution_repository_id" \
    "$profile_resolution_destination/repository.git" "$profile_resolution_identity" \
    "$profile_resolution_algorithm" >> "$profile_resolution_snapshots"
}

profile_resolution_snapshot_gitdir() {
  profile_resolution_lookup_id=$1
  while IFS=$'\t' read -r profile_resolution_record_id profile_resolution_record_gitdir _ _; do
    if [ "$profile_resolution_record_id" = "$profile_resolution_lookup_id" ]; then
      printf '%s\n' "$profile_resolution_record_gitdir"
      return 0
    fi
  done < "$profile_resolution_snapshots"
  return 1
}

profile_resolution_snapshot_algorithm() {
  profile_resolution_lookup_id=$1
  while IFS=$'\t' read -r profile_resolution_record_id _ _ profile_resolution_record_algorithm; do
    if [ "$profile_resolution_record_id" = "$profile_resolution_lookup_id" ]; then
      printf '%s\n' "$profile_resolution_record_algorithm"
      return 0
    fi
  done < "$profile_resolution_snapshots"
  return 1
}

profile_resolution_git() {
  profile_resolution_gitdir=$1
  shift
  (
    ulimit -t 15
    ulimit -n 64
    ulimit -f 131072
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_CONFIG_COUNT=7 \
    GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null \
    GIT_CONFIG_KEY_1=core.useReplaceRefs GIT_CONFIG_VALUE_1=false \
    GIT_CONFIG_KEY_2=core.attributesFile GIT_CONFIG_VALUE_2=/dev/null \
    GIT_CONFIG_KEY_3=core.excludesFile GIT_CONFIG_VALUE_3=/dev/null \
    GIT_CONFIG_KEY_4=protocol.file.allow GIT_CONFIG_VALUE_4=never \
    GIT_CONFIG_KEY_5=fetch.fsckObjects GIT_CONFIG_VALUE_5=true \
    GIT_CONFIG_KEY_6=core.multiPackIndex GIT_CONFIG_VALUE_6=false \
    GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
      /usr/bin/git --git-dir="$profile_resolution_gitdir" "$@" 3>&- 2>/dev/null
  )
}

profile_resolution_verify_object_payload() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_oid=$3
  profile_resolution_expected_type=$4
  profile_resolution_output=$5
  profile_resolution_cache_key=$(profile_resolution_sha256_text \
    "$profile_resolution_repository_id:$profile_resolution_algorithm:$profile_resolution_expected_type:$profile_resolution_oid") || return 1
  profile_resolution_cached="$profile_resolution_scratch/object-cache/$profile_resolution_cache_key"
  if [ -f "$profile_resolution_cached" ] && [ ! -L "$profile_resolution_cached" ]; then
    profile_resolution_size=$(/usr/bin/wc -c < "$profile_resolution_cached" | /usr/bin/tr -d ' ') || return 2
    [ "$profile_resolution_size" -le "$profile_resolution_global_remaining" ] || return 5
    profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_size))
    /bin/cp "$profile_resolution_cached" "$profile_resolution_output" || return 2
    return 0
  fi
  profile_resolution_gitdir=$(profile_resolution_snapshot_gitdir "$profile_resolution_repository_id") || return 1
  [ -n "$profile_resolution_gitdir" ] || return 1
  [ "$(profile_resolution_snapshot_algorithm "$profile_resolution_repository_id")" = "$profile_resolution_algorithm" ] || return 3
  profile_resolution_type=$(profile_resolution_git "$profile_resolution_gitdir" cat-file -t "$profile_resolution_oid") || return 2
  [ "$profile_resolution_type" = "$profile_resolution_expected_type" ] || return 4
  profile_resolution_size=$(profile_resolution_git "$profile_resolution_gitdir" cat-file -s "$profile_resolution_oid") || return 2
  case "$profile_resolution_size" in ''|*[!0-9]*) return 2 ;; esac
  [ "$profile_resolution_size" -le 16777216 ] || return 5
  [ "$profile_resolution_size" -le "$profile_resolution_value_remaining" ] &&
    [ "$profile_resolution_size" -le "$profile_resolution_global_remaining" ] || return 5
  profile_resolution_value_remaining=$((profile_resolution_value_remaining - profile_resolution_size))
  profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_size))
  profile_resolution_git "$profile_resolution_gitdir" cat-file "$profile_resolution_expected_type" \
    "$profile_resolution_oid" > "$profile_resolution_output" || return 2
  [ "$(/usr/bin/wc -c < "$profile_resolution_output" | /usr/bin/tr -d ' ')" = "$profile_resolution_size" ] || return 2
  profile_resolution_recomputed=$(profile_resolution_git "$profile_resolution_gitdir" hash-object \
    --stdin --no-filters -t "$profile_resolution_expected_type" < "$profile_resolution_output") || return 2
  [ "$profile_resolution_recomputed" = "$profile_resolution_oid" ] || return 6
  [ "$profile_resolution_size" -le "$profile_resolution_global_remaining" ] || return 5
  profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_size))
  /bin/cp "$profile_resolution_output" "$profile_resolution_cached" || return 2
}

profile_resolution_commit_tree() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_commit=$3
  profile_resolution_commit_file="$profile_resolution_scratch/value.commit"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_commit" commit "$profile_resolution_commit_file" || return $?
  IFS=' ' read -r profile_resolution_word profile_resolution_tree _ < "$profile_resolution_commit_file" || return 2
  [ "$profile_resolution_word" = tree ] || return 2
  case "$profile_resolution_algorithm:$profile_resolution_tree" in
    sha1:????????????????????????????????????????|sha256:????????????????????????????????????????????????????????????????) ;;
    *) return 2 ;;
  esac
  case "$profile_resolution_tree" in *[!0-9a-f]*) return 2 ;; esac
  printf '%s\n' "$profile_resolution_tree"
}

profile_resolution_walk_path() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_commit=$3
  profile_resolution_path=$4
  profile_resolution_tree=$(profile_resolution_commit_tree "$profile_resolution_repository_id" \
    "$profile_resolution_algorithm" "$profile_resolution_commit") || return 2
  profile_resolution_old_ifs=$IFS
  IFS='/'
  read -r -a profile_resolution_segments <<< "$profile_resolution_path"
  IFS=$profile_resolution_old_ifs
  profile_resolution_last_index=$((${#profile_resolution_segments[@]} - 1))
  profile_resolution_index=0
  for profile_resolution_segment in "${profile_resolution_segments[@]}"; do
    profile_resolution_gitdir=$(profile_resolution_snapshot_gitdir "$profile_resolution_repository_id") || return 2
    profile_resolution_listing="$profile_resolution_scratch/tree.list"
    profile_resolution_git "$profile_resolution_gitdir" -c core.quotePath=false ls-tree "$profile_resolution_tree" \
      > "$profile_resolution_listing" || return 2
    profile_resolution_found=0
    while IFS=$'\t' read -r profile_resolution_meta profile_resolution_name; do
      [ "$profile_resolution_name" = "$profile_resolution_segment" ] || continue
      profile_resolution_found=$((profile_resolution_found + 1))
      IFS=' ' read -r profile_resolution_mode profile_resolution_type profile_resolution_oid <<< "$profile_resolution_meta"
    done < "$profile_resolution_listing"
    [ "$profile_resolution_found" -eq 1 ] || return 3
    if [ "$profile_resolution_index" -lt "$profile_resolution_last_index" ]; then
      [ "$profile_resolution_type" = tree ] && [ "$profile_resolution_mode" = 040000 ] || return 4
      profile_resolution_tree_payload="$profile_resolution_scratch/value.tree"
      profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
        "$profile_resolution_oid" tree "$profile_resolution_tree_payload" || return 5
      profile_resolution_tree=$profile_resolution_oid
    fi
    profile_resolution_index=$((profile_resolution_index + 1))
  done
  /usr/bin/printf '%s\t%s\t%s\n' "$profile_resolution_mode" "$profile_resolution_type" "$profile_resolution_oid"
}

profile_resolution_verify_locator() {
  profile_resolution_locator=$1
  profile_resolution_label=$2
  profile_resolution_repository_id=$("$YSTACK_RESOLVER_JQ" -r '.repository_id' <<< "$profile_resolution_locator") || return 1
  profile_resolution_algorithm=$("$YSTACK_RESOLVER_JQ" -r '.hash_algorithm' <<< "$profile_resolution_locator") || return 1
  profile_resolution_commit=$("$YSTACK_RESOLVER_JQ" -r '.commit_id' <<< "$profile_resolution_locator") || return 1
  profile_resolution_path=$("$YSTACK_RESOLVER_JQ" -r '.path' <<< "$profile_resolution_locator") || return 1
  profile_resolution_claimed_oid=$("$YSTACK_RESOLVER_JQ" -r '.object_id' <<< "$profile_resolution_locator") || return 1
  profile_resolution_walk=$(profile_resolution_walk_path "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_commit" "$profile_resolution_path") || return 2
  IFS=$'\t' read -r profile_resolution_mode profile_resolution_type profile_resolution_oid <<< "$profile_resolution_walk"
  [ "$profile_resolution_oid" = "$profile_resolution_claimed_oid" ] || return 3
  [ "$profile_resolution_type" = blob ] || return 4
  case "$profile_resolution_mode" in 100644|100755) ;; *) return 5 ;; esac
  profile_resolution_payload="$profile_resolution_scratch/$profile_resolution_label.payload"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_oid" blob "$profile_resolution_payload" || return 6
  profile_resolution_ref="$profile_resolution_scratch/$profile_resolution_label.ref"
  "$YSTACK_RESOLVER_JQ" -S -c -n --arg repository_id "$profile_resolution_repository_id" \
    --arg hash_algorithm "$profile_resolution_algorithm" --arg commit_id "$profile_resolution_commit" \
    --arg path "$profile_resolution_path" --arg object_id "$profile_resolution_oid" --arg mode "$profile_resolution_mode" \
    '{revision:{repository_id:$repository_id,hash_algorithm:$hash_algorithm,commit_id:$commit_id},
      location:{kind:"path",value:$path},object_type:"blob",object_id:$object_id,mode:$mode}' \
    > "$profile_resolution_ref" || return 1
}

profile_resolution_verify_ref() {
  profile_resolution_ref_json=$1
  profile_resolution_key=$(profile_resolution_sha256_text "$profile_resolution_ref_json") || return 1
  if "$YSTACK_RESOLVER_JQ" -e --argjson ref "$profile_resolution_ref_json" '.[] | select(.ref == $ref)' \
      "$profile_resolution_values" >/dev/null 2>&1; then
    return 0
  fi
  profile_resolution_repository_id=$("$YSTACK_RESOLVER_JQ" -r '.revision.repository_id' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_algorithm=$("$YSTACK_RESOLVER_JQ" -r '.revision.hash_algorithm' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_commit=$("$YSTACK_RESOLVER_JQ" -r '.revision.commit_id' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_location_kind=$("$YSTACK_RESOLVER_JQ" -r '.location.kind' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_expected_type=$("$YSTACK_RESOLVER_JQ" -r '.object_type' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_expected_oid=$("$YSTACK_RESOLVER_JQ" -r '.object_id' <<< "$profile_resolution_ref_json") || return 1
  profile_resolution_expected_mode=$("$YSTACK_RESOLVER_JQ" -r '.mode' <<< "$profile_resolution_ref_json") || return 1
  if [ "$profile_resolution_location_kind" = root ]; then
    profile_resolution_oid=$(profile_resolution_commit_tree "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
      "$profile_resolution_commit") || return 2
    profile_resolution_type=tree
    profile_resolution_mode=040000
  else
    profile_resolution_path=$("$YSTACK_RESOLVER_JQ" -r '.location.value' <<< "$profile_resolution_ref_json") || return 1
    profile_resolution_walk=$(profile_resolution_walk_path "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
      "$profile_resolution_commit" "$profile_resolution_path") || return 2
    IFS=$'\t' read -r profile_resolution_mode profile_resolution_type profile_resolution_oid <<< "$profile_resolution_walk"
  fi
  [ "$profile_resolution_oid" = "$profile_resolution_expected_oid" ] || return 3
  [ "$profile_resolution_type" = "$profile_resolution_expected_type" ] || return 4
  [ "$profile_resolution_mode" = "$profile_resolution_expected_mode" ] || return 5
  profile_resolution_payload="$profile_resolution_scratch/value.$profile_resolution_key"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_oid" "$profile_resolution_type" "$profile_resolution_payload" || return 6
  profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_payload") || return 1
  profile_resolution_next="$profile_resolution_scratch/values.next"
  "$YSTACK_RESOLVER_JQ" -S -c --argjson ref "$profile_resolution_ref_json" --arg digest "$profile_resolution_digest" \
    '. + [{ref:$ref,value_sha256:$digest}] | unique_by(.ref)' "$profile_resolution_values" \
    > "$profile_resolution_next" || return 1
  /bin/mv "$profile_resolution_next" "$profile_resolution_values"
}

profile_resolution_main() {
  exec 3>&2
  exec 2>/dev/null
  if [ "$#" -ne 3 ] || [ "$1" != resolve ]; then
    profile_resolution_error E_USAGE
    return 1
  fi
  profile_resolution_request_input=$2
  profile_resolution_map_input=$3
  case "${YSTACK_RESOLVER_TRUSTED:-}:${YSTACK_RESOLVER_HELPER:-}:${YSTACK_RESOLVER_JQ:-}" in
    1:/*:/*) ;;
    *) profile_resolution_error E_RUNTIME binding; return 1 ;;
  esac
  [ -x "$YSTACK_RESOLVER_HELPER" ] && [ ! -L "$YSTACK_RESOLVER_HELPER" ] || {
    profile_resolution_error E_RUNTIME dependency
    return 1
  }
  [ -x "$YSTACK_RESOLVER_JQ" ] && [ ! -L "$YSTACK_RESOLVER_JQ" ] &&
    [ "$($YSTACK_RESOLVER_JQ --version 2>/dev/null)" = jq-1.6 ] || {
      profile_resolution_error E_RUNTIME dependency
      return 1
    }
  profile_resolution_bound_tool_root=${YSTACK_RESOLVER_JQ%/*}
  profile_resolution_bound_core_awk="$profile_resolution_bound_tool_root/awk"
  [ -x "$profile_resolution_bound_core_awk" ] &&
    [ ! -L "$profile_resolution_bound_core_awk" ] || {
      profile_resolution_error E_RUNTIME dependency
      return 1
    }
  for profile_resolution_dependency in /bin/bash /bin/dd /bin/mkdir /bin/rm /bin/mv /bin/cat /bin/cp \
    /usr/bin/git /usr/bin/shasum /usr/bin/mktemp /usr/bin/cmp /usr/bin/wc \
    /usr/bin/sed /usr/bin/tr /usr/bin/sort /usr/bin/comm; do
    [ -x "$profile_resolution_dependency" ] && [ ! -L "$profile_resolution_dependency" ] || {
      profile_resolution_error E_RUNTIME dependency
      return 1
    }
  done
  umask 077
  profile_resolution_scratch=$(/usr/bin/mktemp -d "${TMPDIR%/}/ystack-profile-resolution.XXXXXX") || {
    profile_resolution_error E_RUNTIME unexpected
    return 1
  }
  trap profile_resolution_cleanup EXIT
  trap 'profile_resolution_error E_LIMIT time-limit; exit 1' HUP INT TERM
  profile_resolution_repo=${BASH_SOURCE[0]%/scripts/lib/profile-resolution.sh}
  profile_resolution_core="$profile_resolution_repo/scripts/core-contract.sh"
  profile_resolution_program="$profile_resolution_repo/resolver/v1/profile-resolution.jq"
  [ -f "$profile_resolution_core" ] && [ ! -L "$profile_resolution_core" ] &&
    [ -f "$profile_resolution_program" ] && [ ! -L "$profile_resolution_program" ] || {
      profile_resolution_error E_RUNTIME binding
      return 1
    }
  [ "$PROFILE_RESOLUTION_CORE_MERGE" = 48f726cdebed4a5c8683ba2a2268c8e2b662208c ] &&
    [ "$PROFILE_RESOLUTION_SCHEMA_MAJOR" = 1 ] || {
      profile_resolution_error E_RUNTIME binding
      return 1
    }
  [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object scripts/core-contract.sh 2>/dev/null)" = "$PROFILE_RESOLUTION_WRAPPER_BLOB" ] &&
    [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object core/v1/generations/g-*/contracts.jq 2>/dev/null)" = "$PROFILE_RESOLUTION_CONTRACTS_BLOB" ] || {
      profile_resolution_error E_RUNTIME binding
      return 1
    }
  /bin/mkdir -m 700 "$profile_resolution_scratch/repositories" "$profile_resolution_scratch/object-cache" || return 1
  profile_resolution_admin_remaining=33554432
  profile_resolution_object_remaining=268435456
  profile_resolution_entry_remaining=262144
  profile_resolution_name_remaining=16777216
  profile_resolution_value_remaining=67108864
  profile_resolution_global_remaining=536870656
  profile_resolution_request_snapshot="$profile_resolution_scratch/request.json"
  profile_resolution_map_snapshot="$profile_resolution_scratch/map.json"
  profile_resolution_snapshot_input "$profile_resolution_request_input" "$profile_resolution_request_snapshot"
  case $? in 0) ;; 2) profile_resolution_error E_LIMIT; return 1 ;; *) profile_resolution_error E_INPUT request-shape; return 1 ;; esac
  profile_resolution_canonical="$profile_resolution_scratch/canonical.json"
  profile_resolution_canonicalize "$profile_resolution_request_snapshot" "$profile_resolution_canonical"
  case $? in 0) ;; 1) profile_resolution_error E_PARSE; return 1 ;; *) profile_resolution_error E_CANONICAL; return 1 ;; esac
  [ "$(profile_resolution_jq request-minimum "$profile_resolution_request_snapshot")" = true ] || {
    profile_resolution_error E_INPUT request-shape; return 1
  }
  [ "$(profile_resolution_jq request-count "$profile_resolution_request_snapshot")" = true ] || {
    profile_resolution_error E_INPUT manifest-count; return 1
  }
  [ "$(profile_resolution_jq request "$profile_resolution_request_snapshot")" = true ] || {
    profile_resolution_error E_INPUT locator-shape; return 1
  }
  profile_resolution_snapshot_input "$profile_resolution_map_input" "$profile_resolution_map_snapshot"
  case $? in 0) ;; 2) profile_resolution_error E_LIMIT; return 1 ;; *) profile_resolution_error E_INPUT map-shape; return 1 ;; esac
  profile_resolution_canonicalize "$profile_resolution_map_snapshot" "$profile_resolution_canonical"
  case $? in 0) ;; 1) profile_resolution_error E_PARSE; return 1 ;; *) profile_resolution_error E_CANONICAL; return 1 ;; esac
  [ "$(profile_resolution_jq map "$profile_resolution_map_snapshot")" = true ] || {
    profile_resolution_error E_INPUT map-shape; return 1
  }
  profile_resolution_locator_ids="$profile_resolution_scratch/locator.ids"
  profile_resolution_jq locator-ids "$profile_resolution_request_snapshot" |
    "$YSTACK_RESOLVER_JQ" -r '.[]' > "$profile_resolution_locator_ids" || return 1
  while IFS= read -r profile_resolution_id; do
    [ "$("$YSTACK_RESOLVER_JQ" -r --arg id "$profile_resolution_id" '[.repositories[] | select(.repository_id == $id)] | length' "$profile_resolution_map_snapshot")" -eq 1 ] || {
      profile_resolution_error E_REPOSITORY locator-map-missing; return 1
    }
  done < "$profile_resolution_locator_ids"
  profile_resolution_snapshots="$profile_resolution_scratch/snapshots.tsv"
  : > "$profile_resolution_snapshots"
  while IFS= read -r profile_resolution_id; do
    profile_resolution_snapshot_repository "$profile_resolution_id" || return 1
  done < "$profile_resolution_locator_ids"
  profile_resolution_profile_locator=$("$YSTACK_RESOLVER_JQ" -c '.profile_source' "$profile_resolution_request_snapshot")
  profile_resolution_verify_locator "$profile_resolution_profile_locator" profile || {
    profile_resolution_error E_OBJECT object-path; return 1
  }
  profile_resolution_canonicalize "$profile_resolution_scratch/profile.payload" "$profile_resolution_canonical"
  case $? in 0) ;; 1) profile_resolution_error E_PARSE; return 1 ;; *) profile_resolution_error E_CANONICAL; return 1 ;; esac
  profile_resolution_core_validate "$profile_resolution_scratch/core.stderr" validate-document \
    "$profile_resolution_scratch/profile.payload" || return 1
  profile_resolution_profile_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/profile.payload") || return 1
  profile_resolution_profile_pair="$profile_resolution_scratch/profile.pair"
  "$YSTACK_RESOLVER_JQ" -S -c --arg digest "$profile_resolution_profile_digest" '{content:.,sha256:$digest}' \
    "$profile_resolution_scratch/profile.payload" > "$profile_resolution_profile_pair" || return 1
  profile_resolution_manifest_records="$profile_resolution_scratch/manifests.json"
  printf '[]\n' > "$profile_resolution_manifest_records"
  profile_resolution_manifest_count=$("$YSTACK_RESOLVER_JQ" '.manifest_sources | length' "$profile_resolution_request_snapshot")
  profile_resolution_manifest_index=0
  while [ "$profile_resolution_manifest_index" -lt "$profile_resolution_manifest_count" ]; do
    profile_resolution_locator=$("$YSTACK_RESOLVER_JQ" -c --argjson i "$profile_resolution_manifest_index" '.manifest_sources[$i]' "$profile_resolution_request_snapshot")
    profile_resolution_label="manifest.$profile_resolution_manifest_index"
    profile_resolution_verify_locator "$profile_resolution_locator" "$profile_resolution_label" || {
      profile_resolution_error E_OBJECT object-path; return 1
    }
    profile_resolution_canonicalize "$profile_resolution_scratch/$profile_resolution_label.payload" "$profile_resolution_canonical"
    case $? in 0) ;; 1) profile_resolution_error E_PARSE; return 1 ;; *) profile_resolution_error E_CANONICAL; return 1 ;; esac
    profile_resolution_core_validate "$profile_resolution_scratch/core.stderr" validate-document \
      "$profile_resolution_scratch/$profile_resolution_label.payload" || return 1
    profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/$profile_resolution_label.payload") || return 1
    profile_resolution_next="$profile_resolution_scratch/manifests.next"
    "$YSTACK_RESOLVER_JQ" -S -c --slurpfile content "$profile_resolution_scratch/$profile_resolution_label.payload" \
      --slurpfile source "$profile_resolution_scratch/$profile_resolution_label.ref" --arg digest "$profile_resolution_digest" \
      '. + [{pair:{content:$content[0],sha256:$digest},source:$source[0]}]' \
      "$profile_resolution_manifest_records" > "$profile_resolution_next" || return 1
    /bin/mv "$profile_resolution_next" "$profile_resolution_manifest_records"
    profile_resolution_manifest_index=$((profile_resolution_manifest_index + 1))
  done
  profile_resolution_index_input="$profile_resolution_scratch/index.input"
  "$YSTACK_RESOLVER_JQ" -S -c -n --slurpfile profile "$profile_resolution_scratch/profile.payload" \
    --slurpfile records "$profile_resolution_manifest_records" \
    '{profile:$profile[0],records:$records[0]}' > "$profile_resolution_index_input" || return 1
  profile_resolution_index_result=$(profile_resolution_jq manifest-index "$profile_resolution_index_input") || return 1
  if [ "$("$YSTACK_RESOLVER_JQ" -r '.ok' <<< "$profile_resolution_index_result")" != true ]; then
    profile_resolution_reason=$("$YSTACK_RESOLVER_JQ" -r '.reason' <<< "$profile_resolution_index_result")
    profile_resolution_error E_RELATION "$profile_resolution_reason"
    return 1
  fi
  profile_resolution_selected_input="$profile_resolution_scratch/selected.input"
  "$YSTACK_RESOLVER_JQ" -S -c -n --slurpfile request "$profile_resolution_request_snapshot" \
    --slurpfile profile "$profile_resolution_scratch/profile.payload" \
    '{request:$request[0],profile:$profile[0]}' > "$profile_resolution_selected_input" || return 1
  profile_resolution_selected_refs="$profile_resolution_scratch/selected.refs"
  profile_resolution_jq selected-objects "$profile_resolution_selected_input" > "$profile_resolution_selected_refs" || return 1
  profile_resolution_selected_ids="$profile_resolution_scratch/selected.ids"
  {
    /bin/cat "$profile_resolution_locator_ids"
    "$YSTACK_RESOLVER_JQ" -r '.[].revision.repository_id' "$profile_resolution_selected_refs"
  } | /usr/bin/sort -u > "$profile_resolution_selected_ids"
  profile_resolution_map_ids="$profile_resolution_scratch/map.ids"
  "$YSTACK_RESOLVER_JQ" -r '.repositories[].repository_id' "$profile_resolution_map_snapshot" | /usr/bin/sort -u > "$profile_resolution_map_ids"
  profile_resolution_missing=$(/usr/bin/comm -23 "$profile_resolution_selected_ids" "$profile_resolution_map_ids")
  [ -z "$profile_resolution_missing" ] || { profile_resolution_error E_REPOSITORY map-missing; return 1; }
  profile_resolution_extra=$(/usr/bin/comm -13 "$profile_resolution_selected_ids" "$profile_resolution_map_ids")
  [ -z "$profile_resolution_extra" ] || { profile_resolution_error E_REPOSITORY map-extra; return 1; }
  while IFS= read -r profile_resolution_id; do
    profile_resolution_snapshot_repository "$profile_resolution_id" || return 1
  done < "$profile_resolution_selected_ids"
  profile_resolution_values="$profile_resolution_scratch/values.json"
  "$YSTACK_RESOLVER_JQ" -S -c -n --slurpfile profile_ref "$profile_resolution_scratch/profile.ref" \
    --arg digest "$profile_resolution_profile_digest" '[{ref:$profile_ref[0],value_sha256:$digest}]' \
    > "$profile_resolution_values" || return 1
  profile_resolution_manifest_index=0
  while [ "$profile_resolution_manifest_index" -lt "$profile_resolution_manifest_count" ]; do
    profile_resolution_label="manifest.$profile_resolution_manifest_index"
    profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/$profile_resolution_label.payload") || return 1
    profile_resolution_next="$profile_resolution_scratch/values.next"
    "$YSTACK_RESOLVER_JQ" -S -c --slurpfile ref "$profile_resolution_scratch/$profile_resolution_label.ref" \
      --arg digest "$profile_resolution_digest" '. + [{ref:$ref[0],value_sha256:$digest}] | unique_by(.ref)' \
      "$profile_resolution_values" > "$profile_resolution_next" || return 1
    /bin/mv "$profile_resolution_next" "$profile_resolution_values"
    profile_resolution_manifest_index=$((profile_resolution_manifest_index + 1))
  done
  profile_resolution_ref_count=$("$YSTACK_RESOLVER_JQ" 'length' "$profile_resolution_selected_refs")
  profile_resolution_ref_index=0
  while [ "$profile_resolution_ref_index" -lt "$profile_resolution_ref_count" ]; do
    profile_resolution_ref_json=$("$YSTACK_RESOLVER_JQ" -c --argjson i "$profile_resolution_ref_index" '.[$i]' "$profile_resolution_selected_refs")
    profile_resolution_verify_ref "$profile_resolution_ref_json" || {
      profile_resolution_error E_OBJECT object-path; return 1
    }
    profile_resolution_ref_index=$((profile_resolution_ref_index + 1))
  done
  profile_resolution_state="$profile_resolution_scratch/state.json"
  "$YSTACK_RESOLVER_JQ" -S -c -n --slurpfile request "$profile_resolution_request_snapshot" \
    --slurpfile profile_pair "$profile_resolution_profile_pair" \
    --slurpfile profile_source "$profile_resolution_scratch/profile.ref" \
    --slurpfile manifest_records "$profile_resolution_manifest_records" \
    --slurpfile values "$profile_resolution_values" \
    '{request:$request[0],profile_pair:$profile_pair[0],profile_source:$profile_source[0],
      manifest_records:$manifest_records[0],values:$values[0]}' > "$profile_resolution_state" || return 1
  profile_resolution_body="$profile_resolution_scratch/body.json"
  profile_resolution_jq assemble-body "$profile_resolution_state" > "$profile_resolution_body" || {
    profile_resolution_error E_RUNTIME unexpected; return 1
  }
  profile_resolution_body_digest=$(profile_resolution_sha256 "$profile_resolution_body") || return 1
  profile_resolution_envelope_input="$profile_resolution_scratch/envelope.input"
  "$YSTACK_RESOLVER_JQ" -S -c -n --slurpfile body "$profile_resolution_body" --arg body_sha256 "$profile_resolution_body_digest" \
    '{body:$body[0],body_sha256:$body_sha256}' > "$profile_resolution_envelope_input" || return 1
  profile_resolution_output="$profile_resolution_scratch/resolved.json"
  profile_resolution_jq envelope "$profile_resolution_envelope_input" > "$profile_resolution_output" || return 1
  profile_resolution_manifest_args=()
  while IFS= read -r profile_resolution_manifest_id; do
    profile_resolution_manifest_index=0
    while [ "$profile_resolution_manifest_index" -lt "$profile_resolution_manifest_count" ]; do
      if [ "$("$YSTACK_RESOLVER_JQ" -r '.id' "$profile_resolution_scratch/manifest.$profile_resolution_manifest_index.payload")" = "$profile_resolution_manifest_id" ]; then
        profile_resolution_manifest_args+=("$profile_resolution_scratch/manifest.$profile_resolution_manifest_index.payload")
        break
      fi
      profile_resolution_manifest_index=$((profile_resolution_manifest_index + 1))
    done
  done < <("$YSTACK_RESOLVER_JQ" -r 'sort_by([.pair.content.kind,.pair.content.id,.pair.sha256]) | .[].pair.content.id' \
    "$profile_resolution_manifest_records")
  profile_resolution_core_validate "$profile_resolution_scratch/core.stderr" validate-profile-set \
    "$profile_resolution_scratch/profile.payload" "$profile_resolution_output" "${profile_resolution_manifest_args[@]}" || return 1
  /bin/cat "$profile_resolution_output"
  trap - EXIT HUP INT TERM
  profile_resolution_cleanup
}
