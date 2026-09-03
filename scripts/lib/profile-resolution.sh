#!/usr/bin/env bash
# shellcheck disable=SC2016

PROFILE_RESOLUTION_CORE_MERGE='6a9904e6fc3eb70b76e92f3c2f5a37d5a4bf3edf'
PROFILE_RESOLUTION_CORE_GENERATION='g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43'
PROFILE_RESOLUTION_CORE_PUBLISHER_RECEIPT_SHA256='00bd57c0dc3aa6e29bd123c14a18850ffd3432b4a32a6177a86eff6532792d78'
PROFILE_RESOLUTION_CONTRACTS_BLOB='8efe7582480d179463e0e88aac9a7874689786d1'
PROFILE_RESOLUTION_WRAPPER_BLOB='18748127ead49a22717723e9860210940010d84e'
PROFILE_RESOLUTION_REGISTRY_BLOB='0bc09fa56047b2e3fdecf22559f68468f0528797'
PROFILE_RESOLUTION_INGRESS_BLOB='973f5c3808ffbbda23471b2dbdd7b221cb4d0599'
PROFILE_RESOLUTION_SCHEMA_MAJOR='2'
PROFILE_RESOLUTION_GLOBAL_LIMIT=536870912
PROFILE_RESOLUTION_DIAGNOSTIC_RESERVE=256
PROFILE_RESOLUTION_GIT_WALL_SECONDS=30

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

profile_resolution_decimal() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

profile_resolution_charge_global() {
  local profile_resolution_charge=$1
  profile_resolution_decimal "$profile_resolution_charge" || return 2
  if [ "$profile_resolution_charge" -gt "$profile_resolution_global_remaining" ]; then
    profile_resolution_limit_reason=scratch-size
    return 50
  fi
  profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_charge))
}

profile_resolution_charge_value() {
  local profile_resolution_charge=$1
  profile_resolution_decimal "$profile_resolution_charge" || return 2
  if [ "$profile_resolution_charge" -gt 16777216 ] ||
     [ "$profile_resolution_charge" -gt "$profile_resolution_value_remaining" ]; then
    profile_resolution_limit_reason=value-size
    return 50
  fi
  if [ "$profile_resolution_charge" -gt "$profile_resolution_global_remaining" ]; then
    profile_resolution_limit_reason=scratch-size
    return 50
  fi
  profile_resolution_value_remaining=$((profile_resolution_value_remaining - profile_resolution_charge))
  profile_resolution_global_remaining=$((profile_resolution_global_remaining - profile_resolution_charge))
}

profile_resolution_write_text() {
  local profile_resolution_destination=$1
  local profile_resolution_text=$2
  local profile_resolution_mode=${3:-replace}
  local profile_resolution_bytes
  profile_resolution_bytes=$(builtin printf '%s\n' "$profile_resolution_text" |
    /usr/bin/wc -c | /usr/bin/tr -d ' ') || return 2
  profile_resolution_charge_global "$profile_resolution_bytes" || return $?
  case "$profile_resolution_mode" in
    replace) builtin printf '%s\n' "$profile_resolution_text" > "$profile_resolution_destination" ;;
    append) builtin printf '%s\n' "$profile_resolution_text" >> "$profile_resolution_destination" ;;
    *) return 2 ;;
  esac
}

profile_resolution_create_empty() {
  profile_resolution_charge_global 0 || return $?
  : > "$1"
}

profile_resolution_write_decimal_bytes() {
  local profile_resolution_destination=$1
  local profile_resolution_decimal_bytes=$2
  local profile_resolution_decoded_size=$3
  profile_resolution_charge_global "$profile_resolution_decoded_size" || return $?
  builtin printf '%s\n' "$profile_resolution_decimal_bytes" |
    "$profile_resolution_bound_core_awk" \
      '{ for (byte_index = 1; byte_index <= NF; byte_index++) printf "%c", $byte_index }' \
      > "$profile_resolution_destination" || return 2
  [ "$(/usr/bin/wc -c < "$profile_resolution_destination" | /usr/bin/tr -d ' ')" = \
    "$profile_resolution_decoded_size" ] || return 2
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
  profile_resolution_digest=${profile_resolution_digest_line%% *}
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
  profile_resolution_input_decimal=$(/bin/dd if="$profile_resolution_input" bs=1048577 count=1 2>/dev/null |
    /usr/bin/od -An -v -tu1) || return 1
  profile_resolution_bytes=$(builtin printf '%s\n' "$profile_resolution_input_decimal" |
    /usr/bin/wc -w | /usr/bin/tr -d ' ') || return 1
  [ "$profile_resolution_bytes" -le 1048576 ] || return 2
  profile_resolution_write_decimal_bytes "$profile_resolution_destination" \
    "$profile_resolution_input_decimal" "$profile_resolution_bytes" || return $?
}

profile_resolution_canonicalize() {
  local profile_resolution_source=$1
  local profile_resolution_destination=$2
  local profile_resolution_canonical_text
  profile_resolution_canonical_text=$("$YSTACK_RESOLVER_JQ" -S -c . "$profile_resolution_source" 2>/dev/null) || return 1
  profile_resolution_write_text "$profile_resolution_destination" "$profile_resolution_canonical_text" || return $?
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
  profile_resolution_core_budget=$profile_resolution_global_remaining
  profile_resolution_core_capture=$(
    /bin/bash "$profile_resolution_core" --accounted-validation \
      "$profile_resolution_scratch" "$profile_resolution_core_budget" "$@" \
      3>&1 2>&1 1>/dev/null 8>&-
  )
  profile_resolution_core_status=$?
  profile_resolution_core_receipt=${profile_resolution_core_capture##*$'\n'}
  profile_resolution_core_error=${profile_resolution_core_capture%$'\n'*}
  if [ "$profile_resolution_core_receipt" = "$profile_resolution_core_capture" ]; then
    profile_resolution_core_error=''
  fi
  case "$profile_resolution_core_receipt" in
    written-bytes:*) profile_resolution_core_bytes=${profile_resolution_core_receipt#written-bytes:} ;;
    *) return 2 ;;
  esac
  profile_resolution_decimal "$profile_resolution_core_bytes" || return 2
  [ "$profile_resolution_core_bytes" -le "$profile_resolution_core_budget" ] || return 2
  profile_resolution_charge_global "$profile_resolution_core_bytes" || return 2
  if [ "$profile_resolution_core_status" -eq 0 ]; then
    [ -z "$profile_resolution_core_error" ] || return 2
    return 0
  fi
  case "$profile_resolution_core_error" in
    E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION)
      printf '%s\n' "$profile_resolution_core_error" >&3
      return 1
      ;;
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
  profile_resolution_helper_capture=$("$YSTACK_RESOLVER_HELPER" snapshot-repository \
    "$profile_resolution_root" "$profile_resolution_destination" \
    "$profile_resolution_admin_remaining" "$profile_resolution_object_remaining" \
    "$profile_resolution_entry_remaining" "$profile_resolution_name_remaining" \
    "$profile_resolution_global_remaining" 2>&1 8>&-)
  profile_resolution_helper_status=$?
  if [ "$profile_resolution_helper_status" -ne 0 ]; then
    case "$profile_resolution_helper_capture" in
      'E_LIMIT '*) printf '%s\n' "$profile_resolution_helper_capture" >&3 ;;
      'E_REPOSITORY '*) printf '%s\n' "$profile_resolution_helper_capture" >&3 ;;
      *) profile_resolution_error E_RUNTIME unexpected ;;
    esac
    return 2
  fi
  case "$profile_resolution_helper_capture" in *$'\n'*) return 1 ;; esac
  IFS=$'\t' read -r profile_resolution_ok profile_resolution_algorithm \
    profile_resolution_identity profile_resolution_admin_bytes profile_resolution_object_bytes \
    profile_resolution_entries profile_resolution_name_bytes profile_resolution_global_bytes \
    < <(/usr/bin/printf '%s\n' "$profile_resolution_helper_capture") || return 1
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
  profile_resolution_charge_global "$profile_resolution_global_bytes" || return 1
  while IFS=$'\t' read -r _ _ profile_resolution_record_identity _; do
    if [ "$profile_resolution_record_identity" = "$profile_resolution_identity" ]; then
      profile_resolution_error E_REPOSITORY repository-duplicate
      return 2
    fi
  done < "$profile_resolution_snapshots"
  profile_resolution_snapshot_record=$(/usr/bin/printf '%s\t%s\t%s\t%s' \
    "$profile_resolution_repository_id" "$profile_resolution_destination/repository.git" \
    "$profile_resolution_identity" "$profile_resolution_algorithm") || return 1
  profile_resolution_write_text "$profile_resolution_snapshots" \
    "$profile_resolution_snapshot_record" append
  profile_resolution_status=$?
  case "$profile_resolution_status" in
    0) ;;
    50) profile_resolution_error E_LIMIT "${profile_resolution_limit_reason:-scratch-size}"; return 2 ;;
    *) profile_resolution_error E_RUNTIME unexpected; return 2 ;;
  esac
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
  [ -z "${profile_resolution_git_child:-}" ] || return 2
  profile_resolution_git_wall=$PROFILE_RESOLUTION_GIT_WALL_SECONDS
  if [ "${YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS:-}" = 1 ]; then
    profile_resolution_git_wall=1
  fi
  profile_resolution_git_watchdog_fifo="$profile_resolution_scratch/git-watchdog.fifo"
  [ ! -e "$profile_resolution_git_watchdog_fifo" ] || return 2
  /usr/bin/mkfifo -m 600 "$profile_resolution_git_watchdog_fifo" || return 2
  exec 7<> "$profile_resolution_git_watchdog_fifo" || {
    /bin/rm -f -- "$profile_resolution_git_watchdog_fifo"
    return 2
  }
  /bin/rm -f -- "$profile_resolution_git_watchdog_fifo" || {
    exec 7>&-
    return 2
  }
  exec 9<&0 || {
    exec 7>&-
    return 2
  }
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
      exec /usr/bin/git --git-dir="$profile_resolution_gitdir" "$@" \
        0<&9 3>&- 7>&- 8>&- 9<&- 2>/dev/null
  ) &
  profile_resolution_git_child=$!
  exec 9<&-
  if [ "$profile_resolution_git_wall" -eq 1 ] &&
     [ "${YSTACK_RESOLVER_TEST_GIT_STOP:-}" = 1 ]; then
    kill -STOP "$profile_resolution_git_child" 2>/dev/null || :
  fi
  (
    trap 'exit 0' HUP INT TERM
    profile_resolution_watchdog_started=$SECONDS
    while kill -0 "$profile_resolution_git_child" 2>/dev/null; do
      if [ "$((SECONDS - profile_resolution_watchdog_started))" -ge \
           "$profile_resolution_git_wall" ]; then
        kill -KILL "$profile_resolution_git_child" 2>/dev/null || :
        exit 50
      fi
      if IFS= read -r -t 1 -n 1 -u 7 _; then
        exit 0
      fi
    done
    exit 0
  ) 3>&- 9<&- &
  profile_resolution_git_watchdog=$!
  wait "$profile_resolution_git_child"
  profile_resolution_git_status=$?
  /usr/bin/printf x >&7 || :
  wait "$profile_resolution_git_watchdog"
  profile_resolution_watchdog_status=$?
  exec 7>&-
  profile_resolution_git_child=''
  if [ "$profile_resolution_watchdog_status" -eq 50 ]; then
    return 50
  fi
  return "$profile_resolution_git_status"
}

profile_resolution_git_result() {
  if [ "$1" -eq 50 ]; then
    profile_resolution_limit_reason=time-limit
    return 50
  fi
  return 2
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
    if [ -e "$profile_resolution_output" ] &&
       [ "$profile_resolution_cached" -ef "$profile_resolution_output" ]; then
      return 0
    fi
    /bin/rm -f -- "$profile_resolution_output" || return 2
    /bin/ln "$profile_resolution_cached" "$profile_resolution_output" || return 2
    return 0
  fi
  profile_resolution_gitdir=$(profile_resolution_snapshot_gitdir "$profile_resolution_repository_id") || return 1
  [ -n "$profile_resolution_gitdir" ] || return 1
  [ "$(profile_resolution_snapshot_algorithm "$profile_resolution_repository_id")" = "$profile_resolution_algorithm" ] || return 3
  profile_resolution_type=$(profile_resolution_git "$profile_resolution_gitdir" cat-file -t "$profile_resolution_oid")
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || {
    profile_resolution_git_result "$profile_resolution_status"
    return $?
  }
  [ "$profile_resolution_type" = "$profile_resolution_expected_type" ] || return 4
  profile_resolution_size=$(profile_resolution_git "$profile_resolution_gitdir" cat-file -s "$profile_resolution_oid")
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || {
    profile_resolution_git_result "$profile_resolution_status"
    return $?
  }
  case "$profile_resolution_size" in ''|*[!0-9]*) return 2 ;; esac
  profile_resolution_charge_value "$profile_resolution_size" || return $?
  profile_resolution_git "$profile_resolution_gitdir" cat-file "$profile_resolution_expected_type" \
    "$profile_resolution_oid" > "$profile_resolution_cached"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || {
    profile_resolution_git_result "$profile_resolution_status"
    return $?
  }
  [ "$(/usr/bin/wc -c < "$profile_resolution_cached" | /usr/bin/tr -d ' ')" = "$profile_resolution_size" ] || return 2
  profile_resolution_recomputed=$(profile_resolution_git "$profile_resolution_gitdir" hash-object \
    --stdin --no-filters -t "$profile_resolution_expected_type" < "$profile_resolution_cached")
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || {
    profile_resolution_git_result "$profile_resolution_status"
    return $?
  }
  [ "$profile_resolution_recomputed" = "$profile_resolution_oid" ] || return 6
  /bin/rm -f -- "$profile_resolution_output" || return 2
  /bin/ln "$profile_resolution_cached" "$profile_resolution_output" || return 2
}

profile_resolution_tree_listing() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_tree=$3
  profile_resolution_tree_payload=$4
  profile_resolution_listing_key=$(profile_resolution_sha256_text \
    "$profile_resolution_repository_id:$profile_resolution_algorithm:listing:$profile_resolution_tree") || return 2
  profile_resolution_listing="$profile_resolution_scratch/tree-cache/$profile_resolution_listing_key"
  if [ -f "$profile_resolution_listing" ] && [ ! -L "$profile_resolution_listing" ]; then
    return 0
  fi
  profile_resolution_gitdir=$(profile_resolution_snapshot_gitdir "$profile_resolution_repository_id") || return 2
  profile_resolution_listing_decimal=$(
    profile_resolution_git "$profile_resolution_gitdir" ls-tree -z "$profile_resolution_tree" |
      /usr/bin/od -An -v -tu1
  )
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || {
    profile_resolution_git_result "$profile_resolution_status"
    return $?
  }
  profile_resolution_listing_bytes=$(builtin printf '%s\n' "$profile_resolution_listing_decimal" |
    /usr/bin/wc -w | /usr/bin/tr -d ' ') || return 2
  profile_resolution_write_decimal_bytes "$profile_resolution_listing" \
    "$profile_resolution_listing_decimal" "$profile_resolution_listing_bytes" || return $?
  [ -f "$profile_resolution_tree_payload" ] && [ ! -L "$profile_resolution_tree_payload" ] || return 2
}

profile_resolution_commit_tree() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_commit=$3
  profile_resolution_commit_file="$profile_resolution_scratch/value.commit"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_commit" commit "$profile_resolution_commit_file"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  IFS=' ' read -r profile_resolution_word profile_resolution_resolved_tree _ < "$profile_resolution_commit_file" || return 2
  [ "$profile_resolution_word" = tree ] || return 2
  case "$profile_resolution_algorithm:$profile_resolution_resolved_tree" in
    sha1:????????????????????????????????????????|sha256:????????????????????????????????????????????????????????????????) ;;
    *) return 2 ;;
  esac
  case "$profile_resolution_resolved_tree" in *[!0-9a-f]*) return 2 ;; esac
  profile_resolution_root_tree_payload="$profile_resolution_scratch/value.root-tree"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_resolved_tree" tree "$profile_resolution_root_tree_payload"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
}

profile_resolution_walk_path() {
  profile_resolution_repository_id=$1
  profile_resolution_algorithm=$2
  profile_resolution_commit=$3
  profile_resolution_path=$4
  profile_resolution_commit_tree "$profile_resolution_repository_id" \
    "$profile_resolution_algorithm" "$profile_resolution_commit"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  profile_resolution_tree=$profile_resolution_resolved_tree
  profile_resolution_tree_payload=$profile_resolution_root_tree_payload
  profile_resolution_remaining_path=$profile_resolution_path
  while :; do
    profile_resolution_segment=${profile_resolution_remaining_path%%/*}
    if [ "$profile_resolution_segment" = "$profile_resolution_remaining_path" ]; then
      profile_resolution_last_segment=true
    else
      profile_resolution_last_segment=false
    fi
    profile_resolution_tree_listing "$profile_resolution_repository_id" \
      "$profile_resolution_algorithm" "$profile_resolution_tree" \
      "$profile_resolution_tree_payload"
    profile_resolution_status=$?
    [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
    profile_resolution_found=0
    while IFS= read -r -d '' profile_resolution_entry; do
      case "$profile_resolution_entry" in
        *$'\t'*) ;;
        *) return 2 ;;
      esac
      profile_resolution_meta=${profile_resolution_entry%%$'\t'*}
      profile_resolution_name=${profile_resolution_entry#*$'\t'}
      [ "$profile_resolution_name" = "$profile_resolution_segment" ] || continue
      profile_resolution_found=$((profile_resolution_found + 1))
      IFS=' ' read -r profile_resolution_mode profile_resolution_type profile_resolution_oid \
        < <(/usr/bin/printf '%s\n' "$profile_resolution_meta") || return 2
    done < "$profile_resolution_listing"
    [ "$profile_resolution_found" -eq 1 ] || return 3
    if [ "$profile_resolution_last_segment" = false ]; then
      [ "$profile_resolution_type" = tree ] && [ "$profile_resolution_mode" = 040000 ] || return 4
      profile_resolution_tree_payload="$profile_resolution_scratch/value.tree"
      profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
        "$profile_resolution_oid" tree "$profile_resolution_tree_payload"
      profile_resolution_status=$?
      [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
      profile_resolution_tree=$profile_resolution_oid
      profile_resolution_remaining_path=${profile_resolution_remaining_path#*/}
    else
      break
    fi
  done
  profile_resolution_resolved_mode=$profile_resolution_mode
  profile_resolution_resolved_type=$profile_resolution_type
  profile_resolution_resolved_oid=$profile_resolution_oid
}

profile_resolution_verify_locator() {
  profile_resolution_locator=$1
  profile_resolution_label=$2
  profile_resolution_repository_id=$(/usr/bin/printf '%s\n' "$profile_resolution_locator" |
    "$YSTACK_RESOLVER_JQ" -r '.repository_id') || return 1
  profile_resolution_algorithm=$(/usr/bin/printf '%s\n' "$profile_resolution_locator" |
    "$YSTACK_RESOLVER_JQ" -r '.hash_algorithm') || return 1
  profile_resolution_commit=$(/usr/bin/printf '%s\n' "$profile_resolution_locator" |
    "$YSTACK_RESOLVER_JQ" -r '.commit_id') || return 1
  profile_resolution_path=$(/usr/bin/printf '%s\n' "$profile_resolution_locator" |
    "$YSTACK_RESOLVER_JQ" -r '.path') || return 1
  profile_resolution_claimed_oid=$(/usr/bin/printf '%s\n' "$profile_resolution_locator" |
    "$YSTACK_RESOLVER_JQ" -r '.object_id') || return 1
  profile_resolution_walk_path "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_commit" "$profile_resolution_path"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  profile_resolution_mode=$profile_resolution_resolved_mode
  profile_resolution_type=$profile_resolution_resolved_type
  profile_resolution_oid=$profile_resolution_resolved_oid
  [ "$profile_resolution_oid" = "$profile_resolution_claimed_oid" ] || return 3
  [ "$profile_resolution_type" = blob ] || return 4
  case "$profile_resolution_mode" in 100644|100755) ;; *) return 5 ;; esac
  profile_resolution_payload="$profile_resolution_scratch/$profile_resolution_label.payload"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_oid" blob "$profile_resolution_payload"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  profile_resolution_ref="$profile_resolution_scratch/$profile_resolution_label.ref"
  profile_resolution_ref_text=$("$YSTACK_RESOLVER_JQ" -S -c -n --arg repository_id "$profile_resolution_repository_id" \
    --arg hash_algorithm "$profile_resolution_algorithm" --arg commit_id "$profile_resolution_commit" \
    --arg path "$profile_resolution_path" --arg object_id "$profile_resolution_oid" --arg mode "$profile_resolution_mode" \
    '{revision:{repository_id:$repository_id,hash_algorithm:$hash_algorithm,commit_id:$commit_id},
      location:{kind:"path",value:$path},object_type:"blob",object_id:$object_id,mode:$mode}') || return 1
  profile_resolution_write_text "$profile_resolution_ref" "$profile_resolution_ref_text" || return $?
}

profile_resolution_verify_ref() {
  profile_resolution_ref_json=$1
  profile_resolution_key=$(profile_resolution_sha256_text "$profile_resolution_ref_json") || return 1
  if "$YSTACK_RESOLVER_JQ" -e --argjson ref "$profile_resolution_ref_json" '.[] | select(.ref == $ref)' \
      "$profile_resolution_values" >/dev/null 2>&1; then
    return 0
  fi
  profile_resolution_repository_id=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.revision.repository_id') || return 1
  profile_resolution_algorithm=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.revision.hash_algorithm') || return 1
  profile_resolution_commit=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.revision.commit_id') || return 1
  profile_resolution_claim_location_kind=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.location.kind') || return 1
  profile_resolution_claim_type=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.object_type') || return 1
  profile_resolution_claim_oid=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.object_id') || return 1
  profile_resolution_claim_mode=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
    "$YSTACK_RESOLVER_JQ" -r '.mode') || return 1
  if [ "$profile_resolution_claim_location_kind" = root ]; then
    profile_resolution_commit_tree "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
      "$profile_resolution_commit"
    profile_resolution_status=$?
    [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
    profile_resolution_resolved_oid=$profile_resolution_resolved_tree
    profile_resolution_resolved_type=tree
    profile_resolution_resolved_mode=040000
  else
    profile_resolution_path=$(/usr/bin/printf '%s\n' "$profile_resolution_ref_json" |
      "$YSTACK_RESOLVER_JQ" -r '.location.value') || return 1
    profile_resolution_walk_path "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
      "$profile_resolution_commit" "$profile_resolution_path"
    profile_resolution_status=$?
    [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  fi
  profile_resolution_oid=$profile_resolution_resolved_oid
  profile_resolution_type=$profile_resolution_resolved_type
  profile_resolution_mode=$profile_resolution_resolved_mode
  [ "$profile_resolution_oid" = "$profile_resolution_claim_oid" ] || return 3
  [ "$profile_resolution_type" = "$profile_resolution_claim_type" ] || return 4
  [ "$profile_resolution_mode" = "$profile_resolution_claim_mode" ] || return 5
  profile_resolution_payload="$profile_resolution_scratch/value.$profile_resolution_key"
  profile_resolution_verify_object_payload "$profile_resolution_repository_id" "$profile_resolution_algorithm" \
    "$profile_resolution_oid" "$profile_resolution_type" "$profile_resolution_payload"
  profile_resolution_status=$?
  [ "$profile_resolution_status" -eq 0 ] || return "$profile_resolution_status"
  profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_payload") || return 1
  profile_resolution_next="$profile_resolution_scratch/values.next"
  profile_resolution_next_text=$("$YSTACK_RESOLVER_JQ" -S -c \
    --argjson ref "$profile_resolution_ref_json" --arg digest "$profile_resolution_digest" \
    '. + [{ref:$ref,value_sha256:$digest}] | unique_by(.ref)' \
    "$profile_resolution_values") || return 1
  profile_resolution_write_text "$profile_resolution_next" \
    "$profile_resolution_next_text" || return $?
  /bin/mv "$profile_resolution_next" "$profile_resolution_values"
}

profile_resolution_report_object_failure() {
  if [ "$1" -eq 50 ]; then
    profile_resolution_error E_LIMIT "${profile_resolution_limit_reason:-scratch-size}"
  else
    profile_resolution_error E_OBJECT object-path
  fi
}

profile_resolution_main_write() {
  profile_resolution_write_text "$@"
  profile_resolution_status=$?
  case "$profile_resolution_status" in
    0) return 0 ;;
    50) profile_resolution_error E_LIMIT "${profile_resolution_limit_reason:-scratch-size}" ;;
    *) profile_resolution_error E_RUNTIME unexpected ;;
  esac
  return 1
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
  case "${YSTACK_RESOLVER_TEST_GIT_WALL_SECONDS:-}:${YSTACK_RESOLVER_TEST_GIT_STOP:-}" in
    :|1:1) ;;
    *) profile_resolution_error E_RUNTIME binding; return 1 ;;
  esac
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
  for profile_resolution_dependency in /bin/bash /bin/dd /bin/mkdir /bin/rm /bin/mv /bin/cat /bin/ln \
    /usr/bin/git /usr/bin/shasum /usr/bin/mktemp /usr/bin/cmp /usr/bin/wc \
    /usr/bin/sed /usr/bin/tr /usr/bin/sort /usr/bin/comm /usr/bin/mkfifo /usr/bin/od; do
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
  [ "$PROFILE_RESOLUTION_CORE_MERGE" = 6a9904e6fc3eb70b76e92f3c2f5a37d5a4bf3edf ] &&
    [ "$PROFILE_RESOLUTION_CORE_GENERATION" = g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43 ] &&
    [ "$PROFILE_RESOLUTION_CORE_PUBLISHER_RECEIPT_SHA256" = 00bd57c0dc3aa6e29bd123c14a18850ffd3432b4a32a6177a86eff6532792d78 ] &&
    [ "$PROFILE_RESOLUTION_SCHEMA_MAJOR" = 2 ] || {
      profile_resolution_error E_RUNTIME binding
      return 1
    }
  profile_resolution_generation_root="$profile_resolution_repo/core/v$PROFILE_RESOLUTION_SCHEMA_MAJOR/generations/$PROFILE_RESOLUTION_CORE_GENERATION"
  [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object scripts/core-contract.sh 2>/dev/null)" = "$PROFILE_RESOLUTION_WRAPPER_BLOB" ] &&
    [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object "core/v$PROFILE_RESOLUTION_SCHEMA_MAJOR/generation-registry.json" 2>/dev/null)" = "$PROFILE_RESOLUTION_REGISTRY_BLOB" ] &&
    [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object "$profile_resolution_generation_root/contracts.jq" 2>/dev/null)" = "$PROFILE_RESOLUTION_CONTRACTS_BLOB" ] &&
    [ "$(/usr/bin/git -C "$profile_resolution_repo" hash-object "$profile_resolution_generation_root/core-ingress.sh" 2>/dev/null)" = "$PROFILE_RESOLUTION_INGRESS_BLOB" ] || {
      profile_resolution_error E_RUNTIME binding
      return 1
    }
  profile_resolution_global_remaining=$PROFILE_RESOLUTION_GLOBAL_LIMIT
  profile_resolution_limit_reason=''
  profile_resolution_charge_global "$PROFILE_RESOLUTION_DIAGNOSTIC_RESERVE" || {
    profile_resolution_error E_RUNTIME unexpected
    return 1
  }
  /bin/mkdir -m 700 "$profile_resolution_scratch/repositories" \
    "$profile_resolution_scratch/object-cache" "$profile_resolution_scratch/tree-cache" || return 1
  profile_resolution_git_child=''
  profile_resolution_admin_remaining=33554432
  profile_resolution_object_remaining=268435456
  profile_resolution_entry_remaining=262144
  profile_resolution_name_remaining=16777216
  profile_resolution_value_remaining=67108864
  profile_resolution_request_snapshot="$profile_resolution_scratch/request.json"
  profile_resolution_map_snapshot="$profile_resolution_scratch/map.json"
  profile_resolution_snapshot_input "$profile_resolution_request_input" "$profile_resolution_request_snapshot"
  case $? in
    0) ;;
    2|50) profile_resolution_error E_LIMIT; return 1 ;;
    *) profile_resolution_error E_INPUT request-shape; return 1 ;;
  esac
  profile_resolution_canonical="$profile_resolution_scratch/canonical.json"
  profile_resolution_canonicalize "$profile_resolution_request_snapshot" "$profile_resolution_canonical"
  case $? in
    0) ;;
    1) profile_resolution_error E_PARSE; return 1 ;;
    2) profile_resolution_error E_CANONICAL; return 1 ;;
    50) profile_resolution_error E_LIMIT scratch-size; return 1 ;;
    *) profile_resolution_error E_RUNTIME unexpected; return 1 ;;
  esac
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
  case $? in
    0) ;;
    2|50) profile_resolution_error E_LIMIT; return 1 ;;
    *) profile_resolution_error E_INPUT map-shape; return 1 ;;
  esac
  profile_resolution_canonicalize "$profile_resolution_map_snapshot" "$profile_resolution_canonical"
  case $? in
    0) ;;
    1) profile_resolution_error E_PARSE; return 1 ;;
    2) profile_resolution_error E_CANONICAL; return 1 ;;
    50) profile_resolution_error E_LIMIT scratch-size; return 1 ;;
    *) profile_resolution_error E_RUNTIME unexpected; return 1 ;;
  esac
  [ "$(profile_resolution_jq map "$profile_resolution_map_snapshot")" = true ] || {
    profile_resolution_error E_INPUT map-shape; return 1
  }
  profile_resolution_locator_ids="$profile_resolution_scratch/locator.ids"
  profile_resolution_locator_ids_text=$(profile_resolution_jq locator-ids \
    "$profile_resolution_request_snapshot" | "$YSTACK_RESOLVER_JQ" -r '.[]') || return 1
  profile_resolution_main_write "$profile_resolution_locator_ids" \
    "$profile_resolution_locator_ids_text" || return 1
  while IFS= read -r profile_resolution_id; do
    [ "$("$YSTACK_RESOLVER_JQ" -r --arg id "$profile_resolution_id" '[.repositories[] | select(.repository_id == $id)] | length' "$profile_resolution_map_snapshot")" -eq 1 ] || {
      profile_resolution_error E_REPOSITORY locator-map-missing; return 1
    }
  done < "$profile_resolution_locator_ids"
  profile_resolution_snapshots="$profile_resolution_scratch/snapshots.tsv"
  profile_resolution_create_empty "$profile_resolution_snapshots" || return 1
  while IFS= read -r profile_resolution_id; do
    profile_resolution_snapshot_repository "$profile_resolution_id" || return 1
  done < "$profile_resolution_locator_ids"
  profile_resolution_profile_locator=$("$YSTACK_RESOLVER_JQ" -c '.profile_source' "$profile_resolution_request_snapshot")
  profile_resolution_verify_locator "$profile_resolution_profile_locator" profile
  profile_resolution_status=$?
  if [ "$profile_resolution_status" -ne 0 ]; then
    profile_resolution_report_object_failure "$profile_resolution_status"
    return 1
  fi
  profile_resolution_canonicalize "$profile_resolution_scratch/profile.payload" "$profile_resolution_canonical"
  case $? in
    0) ;;
    1) profile_resolution_error E_PARSE; return 1 ;;
    2) profile_resolution_error E_CANONICAL; return 1 ;;
    50) profile_resolution_error E_LIMIT scratch-size; return 1 ;;
    *) profile_resolution_error E_RUNTIME unexpected; return 1 ;;
  esac
  profile_resolution_core_validate validate-document \
    "$profile_resolution_scratch/profile.payload" || return 1
  profile_resolution_profile_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/profile.payload") || return 1
  profile_resolution_profile_pair="$profile_resolution_scratch/profile.pair"
  profile_resolution_profile_pair_text=$("$YSTACK_RESOLVER_JQ" -S -c \
    --arg digest "$profile_resolution_profile_digest" '{content:.,sha256:$digest}' \
    "$profile_resolution_scratch/profile.payload") || return 1
  profile_resolution_main_write "$profile_resolution_profile_pair" \
    "$profile_resolution_profile_pair_text" || return 1
  profile_resolution_manifest_records="$profile_resolution_scratch/manifests.json"
  profile_resolution_main_write "$profile_resolution_manifest_records" '[]' || return 1
  profile_resolution_manifest_count=$("$YSTACK_RESOLVER_JQ" '.manifest_sources | length' "$profile_resolution_request_snapshot")
  profile_resolution_manifest_index=0
  while [ "$profile_resolution_manifest_index" -lt "$profile_resolution_manifest_count" ]; do
    profile_resolution_locator=$("$YSTACK_RESOLVER_JQ" -c --argjson i "$profile_resolution_manifest_index" '.manifest_sources[$i]' "$profile_resolution_request_snapshot")
    profile_resolution_label="manifest.$profile_resolution_manifest_index"
    profile_resolution_verify_locator "$profile_resolution_locator" "$profile_resolution_label"
    profile_resolution_status=$?
    if [ "$profile_resolution_status" -ne 0 ]; then
      profile_resolution_report_object_failure "$profile_resolution_status"
      return 1
    fi
    profile_resolution_canonicalize "$profile_resolution_scratch/$profile_resolution_label.payload" "$profile_resolution_canonical"
    case $? in
      0) ;;
      1) profile_resolution_error E_PARSE; return 1 ;;
      2) profile_resolution_error E_CANONICAL; return 1 ;;
      50) profile_resolution_error E_LIMIT scratch-size; return 1 ;;
      *) profile_resolution_error E_RUNTIME unexpected; return 1 ;;
    esac
    profile_resolution_core_validate validate-document \
      "$profile_resolution_scratch/$profile_resolution_label.payload" || return 1
    profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/$profile_resolution_label.payload") || return 1
    profile_resolution_next="$profile_resolution_scratch/manifests.next"
    profile_resolution_next_text=$("$YSTACK_RESOLVER_JQ" -S -c \
      --slurpfile content "$profile_resolution_scratch/$profile_resolution_label.payload" \
      --slurpfile source "$profile_resolution_scratch/$profile_resolution_label.ref" --arg digest "$profile_resolution_digest" \
      '. + [{pair:{content:$content[0],sha256:$digest},source:$source[0]}]' \
      "$profile_resolution_manifest_records") || return 1
    profile_resolution_main_write "$profile_resolution_next" \
      "$profile_resolution_next_text" || return 1
    /bin/mv "$profile_resolution_next" "$profile_resolution_manifest_records"
    profile_resolution_manifest_index=$((profile_resolution_manifest_index + 1))
  done
  profile_resolution_index_input="$profile_resolution_scratch/index.input"
  profile_resolution_index_input_text=$("$YSTACK_RESOLVER_JQ" -S -c -n \
    --slurpfile profile "$profile_resolution_scratch/profile.payload" \
    --slurpfile records "$profile_resolution_manifest_records" \
    '{profile:$profile[0],records:$records[0]}') || return 1
  profile_resolution_main_write "$profile_resolution_index_input" \
    "$profile_resolution_index_input_text" || return 1
  profile_resolution_index_result=$(profile_resolution_jq manifest-index "$profile_resolution_index_input") || return 1
  if [ "$(/usr/bin/printf '%s\n' "$profile_resolution_index_result" | "$YSTACK_RESOLVER_JQ" -r '.ok')" != true ]; then
    profile_resolution_reason=$(/usr/bin/printf '%s\n' "$profile_resolution_index_result" |
      "$YSTACK_RESOLVER_JQ" -r '.reason')
    profile_resolution_error E_RELATION "$profile_resolution_reason"
    return 1
  fi
  profile_resolution_selected_input="$profile_resolution_scratch/selected.input"
  profile_resolution_selected_input_text=$("$YSTACK_RESOLVER_JQ" -S -c -n \
    --slurpfile request "$profile_resolution_request_snapshot" \
    --slurpfile profile "$profile_resolution_scratch/profile.payload" \
    '{request:$request[0],profile:$profile[0]}') || return 1
  profile_resolution_main_write "$profile_resolution_selected_input" \
    "$profile_resolution_selected_input_text" || return 1
  profile_resolution_selected_refs="$profile_resolution_scratch/selected.refs"
  profile_resolution_selected_refs_text=$(profile_resolution_jq selected-objects \
    "$profile_resolution_selected_input") || return 1
  profile_resolution_main_write "$profile_resolution_selected_refs" \
    "$profile_resolution_selected_refs_text" || return 1
  profile_resolution_selected_ids="$profile_resolution_scratch/selected.ids"
  profile_resolution_selected_ids_text=$({
    /bin/cat "$profile_resolution_locator_ids"
    "$YSTACK_RESOLVER_JQ" -r '.[].revision.repository_id' "$profile_resolution_selected_refs"
  } | /usr/bin/sort -u) || return 1
  profile_resolution_main_write "$profile_resolution_selected_ids" \
    "$profile_resolution_selected_ids_text" || return 1
  profile_resolution_map_ids="$profile_resolution_scratch/map.ids"
  profile_resolution_map_ids_text=$("$YSTACK_RESOLVER_JQ" -r \
    '.repositories[].repository_id' "$profile_resolution_map_snapshot" |
    /usr/bin/sort -u) || return 1
  profile_resolution_main_write "$profile_resolution_map_ids" \
    "$profile_resolution_map_ids_text" || return 1
  profile_resolution_missing=$(/usr/bin/comm -23 "$profile_resolution_selected_ids" "$profile_resolution_map_ids")
  [ -z "$profile_resolution_missing" ] || { profile_resolution_error E_REPOSITORY map-missing; return 1; }
  profile_resolution_extra=$(/usr/bin/comm -13 "$profile_resolution_selected_ids" "$profile_resolution_map_ids")
  [ -z "$profile_resolution_extra" ] || { profile_resolution_error E_REPOSITORY map-extra; return 1; }
  while IFS= read -r profile_resolution_id; do
    profile_resolution_snapshot_repository "$profile_resolution_id" || return 1
  done < "$profile_resolution_selected_ids"
  profile_resolution_values="$profile_resolution_scratch/values.json"
  profile_resolution_values_text=$("$YSTACK_RESOLVER_JQ" -S -c -n \
    --slurpfile profile_ref "$profile_resolution_scratch/profile.ref" \
    --arg digest "$profile_resolution_profile_digest" \
    '[{ref:$profile_ref[0],value_sha256:$digest}]') || return 1
  profile_resolution_main_write "$profile_resolution_values" \
    "$profile_resolution_values_text" || return 1
  profile_resolution_manifest_index=0
  while [ "$profile_resolution_manifest_index" -lt "$profile_resolution_manifest_count" ]; do
    profile_resolution_label="manifest.$profile_resolution_manifest_index"
    profile_resolution_digest=$(profile_resolution_sha256 "$profile_resolution_scratch/$profile_resolution_label.payload") || return 1
    profile_resolution_next="$profile_resolution_scratch/values.next"
    profile_resolution_next_text=$("$YSTACK_RESOLVER_JQ" -S -c \
      --slurpfile ref "$profile_resolution_scratch/$profile_resolution_label.ref" \
      --arg digest "$profile_resolution_digest" '. + [{ref:$ref[0],value_sha256:$digest}] | unique_by(.ref)' \
      "$profile_resolution_values") || return 1
    profile_resolution_main_write "$profile_resolution_next" \
      "$profile_resolution_next_text" || return 1
    /bin/mv "$profile_resolution_next" "$profile_resolution_values"
    profile_resolution_manifest_index=$((profile_resolution_manifest_index + 1))
  done
  profile_resolution_ref_count=$("$YSTACK_RESOLVER_JQ" 'length' "$profile_resolution_selected_refs")
  profile_resolution_ref_index=0
  while [ "$profile_resolution_ref_index" -lt "$profile_resolution_ref_count" ]; do
    profile_resolution_ref_json=$("$YSTACK_RESOLVER_JQ" -c --argjson i "$profile_resolution_ref_index" '.[$i]' "$profile_resolution_selected_refs")
    profile_resolution_verify_ref "$profile_resolution_ref_json"
    profile_resolution_status=$?
    if [ "$profile_resolution_status" -ne 0 ]; then
      profile_resolution_report_object_failure "$profile_resolution_status"
      return 1
    fi
    profile_resolution_ref_index=$((profile_resolution_ref_index + 1))
  done
  profile_resolution_state="$profile_resolution_scratch/state.json"
  profile_resolution_state_text=$("$YSTACK_RESOLVER_JQ" -S -c -n \
    --slurpfile request "$profile_resolution_request_snapshot" \
    --slurpfile profile_pair "$profile_resolution_profile_pair" \
    --slurpfile profile_source "$profile_resolution_scratch/profile.ref" \
    --slurpfile manifest_records "$profile_resolution_manifest_records" \
    --slurpfile values "$profile_resolution_values" \
    '{request:$request[0],profile_pair:$profile_pair[0],profile_source:$profile_source[0],
      manifest_records:$manifest_records[0],values:$values[0]}') || return 1
  profile_resolution_main_write "$profile_resolution_state" \
    "$profile_resolution_state_text" || return 1
  profile_resolution_body="$profile_resolution_scratch/body.json"
  profile_resolution_body_text=$(profile_resolution_jq assemble-body \
    "$profile_resolution_state") || {
    profile_resolution_error E_RUNTIME unexpected; return 1
  }
  profile_resolution_main_write "$profile_resolution_body" \
    "$profile_resolution_body_text" || return 1
  profile_resolution_body_digest=$(profile_resolution_sha256 "$profile_resolution_body") || return 1
  profile_resolution_envelope_input="$profile_resolution_scratch/envelope.input"
  profile_resolution_envelope_input_text=$("$YSTACK_RESOLVER_JQ" -S -c -n \
    --slurpfile body "$profile_resolution_body" \
    --arg body_sha256 "$profile_resolution_body_digest" \
    '{body:$body[0],body_sha256:$body_sha256}') || return 1
  profile_resolution_main_write "$profile_resolution_envelope_input" \
    "$profile_resolution_envelope_input_text" || return 1
  profile_resolution_output="$profile_resolution_scratch/resolved.json"
  profile_resolution_output_text=$(profile_resolution_jq envelope \
    "$profile_resolution_envelope_input") || return 1
  profile_resolution_main_write "$profile_resolution_output" \
    "$profile_resolution_output_text" || return 1
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
  profile_resolution_core_validate validate-profile-set \
    "$profile_resolution_scratch/profile.payload" "$profile_resolution_output" "${profile_resolution_manifest_args[@]}" || return 1
  /bin/cat "$profile_resolution_output"
  trap - EXIT HUP INT TERM
  profile_resolution_cleanup
}
