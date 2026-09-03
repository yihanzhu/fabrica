#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

portable_core_ingress_error() {
  local error_token
  case "${1:-}" in
    E_RUNTIME|E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION)
      error_token="$1"
      ;;
    *)
      error_token=E_RUNTIME
      ;;
  esac
  if [ "${PORTABLE_CORE_INGRESS_BUFFER_ERRORS:-false}" = true ]; then
    if [ -z "${PORTABLE_CORE_INGRESS_PENDING_ERROR:-}" ]; then
      PORTABLE_CORE_INGRESS_PENDING_ERROR="$error_token"
    fi
  else
    printf '%s\n' "$error_token" >&2
  fi
  return 1
}

portable_core_ingress_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

portable_core_ingress_real_directory() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

portable_core_ingress_physical_file_path() {
  local candidate_path="$1"
  local current_path=''
  local component
  local remaining_path

  case "$candidate_path" in /*) ;; *) return 1 ;; esac
  case "$candidate_path" in *$'\n'*|*$'\r'*) return 1 ;; esac
  remaining_path="${candidate_path#/}"
  [ -n "$remaining_path" ] || return 1
  while [ -n "$remaining_path" ]; do
    case "$remaining_path" in
      */*)
        component="${remaining_path%%/*}"
        remaining_path="${remaining_path#*/}"
        ;;
      *)
        component="$remaining_path"
        remaining_path=''
        ;;
    esac
    case "$component" in ''|.|..) return 1 ;; esac
    current_path="$current_path/$component"
    [ ! -L "$current_path" ] || return 1
    if [ -n "$remaining_path" ]; then
      [ -d "$current_path" ] || return 1
    else
      [ -f "$current_path" ] || return 1
    fi
  done
}

portable_core_ingress_physical_directory_path() {
  local candidate_path="$1"
  local current_path=''
  local component
  local remaining_path

  case "$candidate_path" in /*) ;; *) return 1 ;; esac
  case "$candidate_path" in *$'\n'*|*$'\r'*) return 1 ;; esac
  remaining_path="${candidate_path#/}"
  [ -n "$remaining_path" ] || return 1
  while [ -n "$remaining_path" ]; do
    case "$remaining_path" in
      */*)
        component="${remaining_path%%/*}"
        remaining_path="${remaining_path#*/}"
        ;;
      *)
        component="$remaining_path"
        remaining_path=''
        ;;
    esac
    case "$component" in ''|.|..) return 1 ;; esac
    current_path="$current_path/$component"
    [ ! -L "$current_path" ] && [ -d "$current_path" ] || return 1
  done
}

portable_core_ingress_decimal() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

portable_core_ingress_file_size() {
  local measured_path="$1"
  local measured_size

  measured_size="$("$PORTABLE_CORE_INGRESS_WC" -c 2>/dev/null < "$measured_path")" ||
    return 1
  measured_size="${measured_size//[[:space:]]/}"
  portable_core_ingress_decimal "$measured_size" || return 1
  PORTABLE_CORE_INGRESS_MEASURED_SIZE="$measured_size"
}

portable_core_ingress_account_reserve() {
  local expected_bytes="$1"

  [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ] || return 0
  portable_core_ingress_decimal "$expected_bytes" &&
    [ -z "${PORTABLE_CORE_INGRESS_RESERVED_BYTES:-}" ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  if [ "$expected_bytes" -gt "$PORTABLE_CORE_INGRESS_REMAINING_BYTES" ]; then
    portable_core_ingress_error E_LIMIT
    return 1
  fi
  PORTABLE_CORE_INGRESS_RESERVED_BYTES="$expected_bytes"
}

portable_core_ingress_account_commit() {
  local actual_bytes="$1"
  local reserved_bytes

  [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ] || return 0
  portable_core_ingress_decimal "$actual_bytes" &&
    [ -n "${PORTABLE_CORE_INGRESS_RESERVED_BYTES:-}" ] || {
      PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  reserved_bytes="$PORTABLE_CORE_INGRESS_RESERVED_BYTES"
  [ "$actual_bytes" -le "$reserved_bytes" ] || {
    PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_REMAINING_BYTES=$((
    PORTABLE_CORE_INGRESS_REMAINING_BYTES - actual_bytes
  ))
  PORTABLE_CORE_INGRESS_WRITTEN_BYTES=$((
    PORTABLE_CORE_INGRESS_WRITTEN_BYTES + actual_bytes
  ))
  PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
  [ "$actual_bytes" -eq "$reserved_bytes" ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  if [ -n "${PORTABLE_CORE_INGRESS_DEFERRED_SIGNAL:-}" ]; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
}

portable_core_ingress_account_files() {
  local expected_bytes="$1"
  local measured_path
  local measured_total=0
  local invalid_path=false
  shift

  [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ] || return 0
  for measured_path in "$@"; do
    if ! portable_core_ingress_regular_file "$measured_path" ||
       ! portable_core_ingress_file_size "$measured_path"; then
      invalid_path=true
      continue
    fi
    measured_total=$((measured_total + PORTABLE_CORE_INGRESS_MEASURED_SIZE))
  done
  portable_core_ingress_account_commit "$measured_total" || return 1
  if [ "$invalid_path" = true ] ||
     [ "$measured_total" -ne "$expected_bytes" ]; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
}

portable_core_ingress_account_append() {
  local expected_bytes="$1"
  local prior_bytes="$2"
  local measured_path="$3"
  local appended_bytes

  [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ] || return 0
  portable_core_ingress_file_size "$measured_path" || {
    PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  [ "$PORTABLE_CORE_INGRESS_MEASURED_SIZE" -ge "$prior_bytes" ] || {
    PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  appended_bytes=$((PORTABLE_CORE_INGRESS_MEASURED_SIZE - prior_bytes))
  portable_core_ingress_account_commit "$appended_bytes" &&
    [ "$appended_bytes" -eq "$expected_bytes" ]
}

portable_core_ingress_open() {
  local accounted=false
  local accounted_root=''
  local accounted_budget=0
  local source_path
  local source_cwd
  local source_dir
  local source_parent
  local repo_root
  local expected_dir
  local jq_path
  local jq_version
  local schema_identity
  local sha_path
  local temp_path
  local required_dir
  local scratch_mode
  local mkdir_status=0
  local owner_pid

  case "$#" in
    0) ;;
    2)
      accounted=true
      accounted_root="$1"
      accounted_budget="$2"
      portable_core_ingress_decimal "$accounted_budget" &&
        [ "$accounted_budget" -le 536870912 ] || {
          portable_core_ingress_error E_RUNTIME
          return 1
        }
      ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac

  PORTABLE_CORE_INGRESS_BUFFER_ERRORS="$accounted"
  PORTABLE_CORE_INGRESS_PENDING_ERROR=''

  PORTABLE_CORE_INGRESS_GENERATION='g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43'
  case "${BASH_SOURCE[0]}" in
    /*) source_path="${BASH_SOURCE[0]}" ;;
    *)
      source_cwd="$(pwd -L 2>/dev/null)" || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
      source_path="$source_cwd/${BASH_SOURCE[0]}"
      ;;
  esac
  portable_core_ingress_physical_file_path "$source_path" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  source_dir="$(
    {
      source_parent="$(dirname -- "$source_path")" &&
        CDPATH='' cd -P -- "$source_parent" && pwd -P
    } 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  repo_root="$(
    {
      CDPATH='' cd -P -- "$source_dir/../../../.." && pwd -P
    } 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  expected_dir="$repo_root/core/v2/generations/$PORTABLE_CORE_INGRESS_GENERATION"
  [ "$source_dir" = "$expected_dir" ] &&
    [ "$source_path" = "$expected_dir/core-ingress.sh" ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  for required_dir in \
    "$repo_root" \
    "$repo_root/core" \
    "$repo_root/core/v2" \
    "$repo_root/core/v2/generations" \
    "$expected_dir" \
    "$expected_dir/modules"; do
    portable_core_ingress_real_directory "$required_dir" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  done

  PORTABLE_CORE_INGRESS_REPO_ROOT="$repo_root"
  PORTABLE_CORE_INGRESS_MODULE_DIR="$expected_dir/modules"
  PORTABLE_CORE_INGRESS_SCHEMA="$PORTABLE_CORE_INGRESS_MODULE_DIR/schema.jq"
  PORTABLE_CORE_INGRESS_ROOT="$expected_dir/contracts.jq"
  portable_core_ingress_regular_file "$expected_dir/core-ingress.sh" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  portable_core_ingress_regular_file "$PORTABLE_CORE_INGRESS_SCHEMA" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }

  jq_path="$(command -v jq 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$jq_path" in
    /*) ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  jq_version="$("$jq_path" --version 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  [ "$jq_version" = jq-1.6 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  schema_identity="$(
    CDPATH='' cd -P -- "$PORTABLE_CORE_INGRESS_MODULE_DIR" 2>/dev/null &&
      HOME=/nonexistent JQ_LIBRARY_PATH=/nonexistent \
        "$jq_path" -L "$PORTABLE_CORE_INGRESS_MODULE_DIR" -nr \
        'import "schema" as schema; schema::semantic_identity' 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  [ "$schema_identity" = core.contracts.v2 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_JQ="$jq_path"

  if sha_path="$(command -v sha256sum 2>/dev/null)"; then
    PORTABLE_CORE_INGRESS_SHA_BACKEND=sha256sum
  elif sha_path="$(command -v shasum 2>/dev/null)"; then
    PORTABLE_CORE_INGRESS_SHA_BACKEND=shasum
  else
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  case "$sha_path" in
    /*) PORTABLE_CORE_INGRESS_SHA="$sha_path" ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac

  PORTABLE_CORE_INGRESS_HEAD="$(command -v head 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_WC="$(command -v wc 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_CMP="$(command -v cmp 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_CAT="$(command -v cat 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_RM="$(command -v rm 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_OD="$(command -v od 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_AWK="$(command -v awk 2>/dev/null)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$PORTABLE_CORE_INGRESS_OD:$PORTABLE_CORE_INGRESS_AWK" in
    /*:/*) ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac

  PORTABLE_CORE_INGRESS_ACCOUNTED="$accounted"
  PORTABLE_CORE_INGRESS_SCRATCH_ROOT=''
  PORTABLE_CORE_INGRESS_INITIAL_BYTES="$accounted_budget"
  PORTABLE_CORE_INGRESS_REMAINING_BYTES="$accounted_budget"
  PORTABLE_CORE_INGRESS_WRITTEN_BYTES=0
  PORTABLE_CORE_INGRESS_RESERVED_BYTES=''
  PORTABLE_CORE_INGRESS_DEFERRED_SIGNAL=''
  PORTABLE_CORE_INGRESS_CREATING_TEMP=false
  PORTABLE_CORE_INGRESS_OWNS_TEMP=false
  if [ "$accounted" = true ]; then
    PORTABLE_CORE_INGRESS_STAT="$(command -v stat 2>/dev/null)" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    PORTABLE_CORE_INGRESS_MKDIR="$(command -v mkdir 2>/dev/null)" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    case "$PORTABLE_CORE_INGRESS_STAT:$PORTABLE_CORE_INGRESS_MKDIR" in
      /*:/*) ;;
      *)
        portable_core_ingress_error E_RUNTIME
        return 1
        ;;
    esac
    portable_core_ingress_physical_directory_path "$accounted_root" &&
      [ -O "$accounted_root" ] || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
    if scratch_mode="$("$PORTABLE_CORE_INGRESS_STAT" -c %a -- \
        "$accounted_root" 2>/dev/null)"; then
      :
    elif scratch_mode="$("$PORTABLE_CORE_INGRESS_STAT" -f %Lp \
        "$accounted_root" 2>/dev/null)"; then
      :
    else
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    [ "$scratch_mode" = 700 ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    PORTABLE_CORE_INGRESS_SCRATCH_ROOT="$accounted_root"
    owner_pid="$$"
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] && [ "${#owner_pid}" -le 20 ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    PORTABLE_CORE_INGRESS_OWNER_PID="$owner_pid"
    temp_path="$accounted_root/portable-core-accounted-v2.$owner_pid"
    if [ -e "$temp_path" ] || [ -L "$temp_path" ]; then
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    PORTABLE_CORE_INGRESS_TEMP="$temp_path"
    PORTABLE_CORE_INGRESS_CREATING_TEMP=true
    "$PORTABLE_CORE_INGRESS_MKDIR" -m 700 -- "$temp_path" 2>/dev/null ||
      mkdir_status=$?
    if [ "$mkdir_status" -eq 0 ]; then
      PORTABLE_CORE_INGRESS_OWNS_TEMP=true
    elif portable_core_ingress_physical_directory_path "$temp_path" &&
         [ -O "$temp_path" ]; then
      if scratch_mode="$("$PORTABLE_CORE_INGRESS_STAT" -c %a -- \
          "$temp_path" 2>/dev/null)"; then
        :
      elif scratch_mode="$("$PORTABLE_CORE_INGRESS_STAT" -f %Lp \
          "$temp_path" 2>/dev/null)"; then
        :
      else
        scratch_mode=''
      fi
      [ "$scratch_mode" = 700 ] && PORTABLE_CORE_INGRESS_OWNS_TEMP=true
    fi
    PORTABLE_CORE_INGRESS_CREATING_TEMP=false
    if [ -n "$PORTABLE_CORE_INGRESS_DEFERRED_SIGNAL" ] ||
       [ "$mkdir_status" -ne 0 ]; then
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  else
    temp_path="$(mktemp -d /tmp/ystack-portable-core-ingress.XXXXXXXX 2>/dev/null)" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    case "$temp_path" in
      /tmp/ystack-portable-core-ingress.*) ;;
      *)
        portable_core_ingress_error E_RUNTIME
        return 1
        ;;
    esac
  fi
  portable_core_ingress_real_directory "$temp_path" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_TEMP="$temp_path"
  PORTABLE_CORE_INGRESS_MODE=''
  PORTABLE_CORE_INGRESS_CONTENTS=''
  PORTABLE_CORE_INGRESS_HASHES=''
  PORTABLE_CORE_INGRESS_DRIVER=''
  PORTABLE_CORE_INGRESS_OUTPUT=''
  PORTABLE_CORE_INGRESS_SNAPSHOT=''
  PORTABLE_CORE_INGRESS_SHA256=''
  PORTABLE_CORE_INGRESS_COUNT=0
  PORTABLE_CORE_INGRESS_RAW_PATHS=()
  PORTABLE_CORE_INGRESS_RAW_SIZES=()
  PORTABLE_CORE_INGRESS_CANONICAL_PATHS=()
  PORTABLE_CORE_INGRESS_DEPTH_OVER=()
}

portable_core_ingress_begin() {
  [ "$#" -eq 1 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$1" in
    document|profile-set|stage-run) ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  portable_core_ingress_real_directory "${PORTABLE_CORE_INGRESS_TEMP:-}" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_MODE="$1"
  PORTABLE_CORE_INGRESS_CONTENTS="$PORTABLE_CORE_INGRESS_TEMP/contents.ndjson"
  PORTABLE_CORE_INGRESS_HASHES="$PORTABLE_CORE_INGRESS_TEMP/hashes.ndjson"
  portable_core_ingress_account_reserve 0 || return 1
  if : 2>/dev/null > "$PORTABLE_CORE_INGRESS_CONTENTS"; then
    portable_core_ingress_account_files 0 \
      "$PORTABLE_CORE_INGRESS_CONTENTS" || return 1
  else
    portable_core_ingress_account_files 0 \
      "$PORTABLE_CORE_INGRESS_CONTENTS" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  portable_core_ingress_account_reserve 0 || return 1
  if : 2>/dev/null > "$PORTABLE_CORE_INGRESS_HASHES"; then
    portable_core_ingress_account_files 0 \
      "$PORTABLE_CORE_INGRESS_HASHES" || return 1
  else
    portable_core_ingress_account_files 0 \
      "$PORTABLE_CORE_INGRESS_HASHES" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  PORTABLE_CORE_INGRESS_COUNT=0
  PORTABLE_CORE_INGRESS_RAW_PATHS=()
  PORTABLE_CORE_INGRESS_RAW_SIZES=()
  PORTABLE_CORE_INGRESS_CANONICAL_PATHS=()
  PORTABLE_CORE_INGRESS_DEPTH_OVER=()
}

portable_core_ingress_digest() {
  local input_path="$1"
  local digest_output
  local digest

  case "$PORTABLE_CORE_INGRESS_SHA_BACKEND" in
    sha256sum)
      digest_output="$("$PORTABLE_CORE_INGRESS_SHA" -- "$input_path" 2>/dev/null)" || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
      ;;
    shasum)
      digest_output="$("$PORTABLE_CORE_INGRESS_SHA" -a 256 -- "$input_path" 2>/dev/null)" || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
      ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  case "$digest_output" in *$'\n'*|*$'\r'*)
    portable_core_ingress_error E_RUNTIME
    return 1
  esac
  [[ "$digest_output" =~ ^([0-9a-f]{64})([[:space:]].*)?$ ]] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  digest="${BASH_REMATCH[1]}"
  PORTABLE_CORE_INGRESS_SHA256="$digest"
}

portable_core_ingress_snapshot() {
  local input_path
  local snapshot_number
  local raw_path
  local encoded_bytes
  local byte_count
  local -a pipeline_status

  [ "$#" -eq 1 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  input_path="$1"
  [ -n "${PORTABLE_CORE_INGRESS_MODE:-}" ] &&
    portable_core_ingress_real_directory "${PORTABLE_CORE_INGRESS_TEMP:-}" &&
    [ -r "$input_path" ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }

  snapshot_number=$((PORTABLE_CORE_INGRESS_COUNT + 1))
  raw_path="$PORTABLE_CORE_INGRESS_TEMP/raw.$snapshot_number"
  encoded_bytes="$(
    "$PORTABLE_CORE_INGRESS_HEAD" -c 1048577 -- "$input_path" 2>/dev/null |
      "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  byte_count="$(
    printf '%s\n' "$encoded_bytes" |
      "$PORTABLE_CORE_INGRESS_AWK" '
        {
          for (i = 1; i <= NF; i++) {
            if ($i !~ /^[0-9]+$/ || ($i + 0) < 0 || ($i + 0) > 255) {
              invalid = 1
              exit 42
            }
            count++
          }
        }
        END { if (!invalid) print count + 0 }
      ' 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  byte_count="${byte_count//[[:space:]]/}"
  portable_core_ingress_decimal "$byte_count" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  portable_core_ingress_account_reserve "$byte_count" || return 1
  if printf '%s\n' "$encoded_bytes" |
      "$PORTABLE_CORE_INGRESS_AWK" '
        { for (i = 1; i <= NF; i++) printf "%c", ($i + 0) }
      ' 2>/dev/null > "$raw_path"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  if [ "${#pipeline_status[@]}" -eq 2 ] &&
     [ "${pipeline_status[0]}" -eq 0 ] &&
     [ "${pipeline_status[1]}" -eq 0 ]; then
    portable_core_ingress_account_files "$byte_count" "$raw_path" || return 1
  else
    portable_core_ingress_account_files "$byte_count" "$raw_path" \
      >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  PORTABLE_CORE_INGRESS_RAW_PATHS[PORTABLE_CORE_INGRESS_COUNT]="$raw_path"
  PORTABLE_CORE_INGRESS_RAW_SIZES[PORTABLE_CORE_INGRESS_COUNT]="$byte_count"
  PORTABLE_CORE_INGRESS_SNAPSHOT="$raw_path"
  PORTABLE_CORE_INGRESS_COUNT="$snapshot_number"
}

portable_core_ingress_analyze() {
  local raw_path="$1"
  local canonical_path="$2"
  local scalar_path="$PORTABLE_CORE_INGRESS_TEMP/deep-scalars.ndjson"
  local scalar_canonical_path="$PORTABLE_CORE_INGRESS_TEMP/deep-scalars-canonical.ndjson"
  local key_path="$PORTABLE_CORE_INGRESS_TEMP/deep-keys.ndjson"
  local key_pair_path="$PORTABLE_CORE_INGRESS_TEMP/deep-key-pairs.ndjson"
  local key_order_path="$PORTABLE_CORE_INGRESS_TEMP/deep-key-order"
  local meta_path="$PORTABLE_CORE_INGRESS_TEMP/deep-meta"
  local scalar_marker_path="$PORTABLE_CORE_INGRESS_TEMP/deep-scalar-marker"
  local scratch_path
  local compare_status
  local meta_size
  local meta_lines
  local meta_kind
  local structural_canonical
  local max_depth
  local extra_meta
  local marker_size
  local marker_lines
  local marker_kind
  local scalar_program
  local scalar_canonical_size
  local key_order_output
  local key_order_size
  local canonical_size
  local scan_program
  local scan_sizes
  local scalar_size
  local key_size
  local key_pair_size
  local expected_scan_bytes
  local canonical_ok=true
  local -a pipeline_status

  for scratch_path in "$scalar_path" "$scalar_canonical_path" \
    "$key_path" "$key_pair_path" "$key_order_path" "$meta_path" \
    "$scalar_marker_path"; do
    portable_core_ingress_account_reserve 0 || return 1
    if : 2>/dev/null > "$scratch_path"; then
      portable_core_ingress_account_files 0 "$scratch_path" || return 1
    else
      portable_core_ingress_account_files 0 "$scratch_path" \
        >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  done

  scan_program='        function fail_parse() { parse_bad = 1 }
        function byte_char(byte) { return sprintf("%c", byte) }
        function is_hex(byte) {
          return (byte >= 48 && byte <= 57) ||
                 (byte >= 65 && byte <= 70) ||
                 (byte >= 97 && byte <= 102)
        }
        function value_expected() {
          if (depth == 0) return root_state == 1
          return frame[depth] == 1 || frame[depth] == 2 || frame[depth] == 7
        }
        function key_expected() {
          return depth > 0 && (frame[depth] == 4 || frame[depth] == 5)
        }
        function record_value_depth() {
          if (depth > max_depth) max_depth = depth
        }
        function complete_value() {
          if (depth == 0) {
            if (root_state != 1) { fail_parse(); return }
            root_state = 2
          } else if (frame[depth] == 1 || frame[depth] == 2) {
            frame[depth] = 3
          } else if (frame[depth] == 7) {
            frame[depth] = 8
          } else {
            fail_parse()
          }
        }
        function flush_token_chunk() {
          if (token_chunk == "") return
          scalar_size += length(token_chunk)
          if (!measure_only) printf "%s", token_chunk >> scalar_file
          if (token_role == "key") {
            key_size += length(token_chunk)
            if (!measure_only) printf "%s", token_chunk >> key_file
          }
          token_chunk = ""
        }
        function begin_token(role, first_byte) {
          token_active = 1
          token_role = role
          token_chunk = ""
          if (role == "key") {
            current_key_index = key_count
            key_count++
          }
          append_token(first_byte)
        }
        function append_token(byte) {
          token_chunk = token_chunk byte_char(byte)
          if (length(token_chunk) >= 4096) flush_token_chunk()
        }
        function finish_scalar() {
          flush_token_chunk()
          scalar_size++
          if (!measure_only) printf "\n" >> scalar_file
          if (token_role == "key") {
            if (!key_expected()) { fail_parse(); return }
            key_size++
            if (!measure_only) printf "\n" >> key_file
            if (depth in previous_key_index) {
              pair_text = sprintf("[%d,%d]\n", previous_key_index[depth],
                                  current_key_index)
              key_pair_size += length(pair_text)
              if (!measure_only) printf "%s", pair_text >> key_pair_file
            }
            previous_key_index[depth] = current_key_index
            frame[depth] = 6
          } else {
            complete_value()
          }
          token_chunk = ""
          token_role = ""
          token_active = 0
          token_state = ""
        }
        function token_terminal() {
          if (token_state == "literal") return literal_pos == literal_len
          return token_state == "zero" || token_state == "integer" ||
                 token_state == "fraction" || token_state == "exponent"
        }
        function literal_byte(kind, position) {
          if (kind == 1) {
            if (position == 2) return 114
            if (position == 3) return 117
            if (position == 4) return 101
          } else if (kind == 2) {
            if (position == 2) return 97
            if (position == 3) return 108
            if (position == 4) return 115
            if (position == 5) return 101
          } else {
            if (position == 2) return 117
            if (position == 3) return 108
            if (position == 4) return 108
          }
          return -1
        }
        function start_atom(byte) {
          if (!value_expected()) { fail_parse(); return }
          record_value_depth()
          begin_token("value", byte)
          if (byte == 116) {
            token_state = "literal"; literal_kind = 1; literal_pos = 1;
            literal_len = 4
          } else if (byte == 102) {
            token_state = "literal"; literal_kind = 2; literal_pos = 1;
            literal_len = 5
          } else if (byte == 110) {
            token_state = "literal"; literal_kind = 3; literal_pos = 1;
            literal_len = 4
          } else if (byte == 45) {
            token_state = "sign"
          } else if (byte == 48) {
            token_state = "zero"
          } else if (byte >= 49 && byte <= 57) {
            token_state = "integer"
          } else {
            fail_parse()
          }
        }
        function atom_byte(byte) {
          if (token_state == "literal") {
            if (literal_pos < literal_len) {
              if (byte != literal_byte(literal_kind, literal_pos + 1)) return -1
              literal_pos++
              append_token(byte)
              return 1
            }
            return 0
          }
          if (token_state == "sign") {
            if (byte == 48) token_state = "zero"
            else if (byte >= 49 && byte <= 57) token_state = "integer"
            else return -1
          } else if (token_state == "zero") {
            if (byte == 46) token_state = "decimal-mark"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else if (byte >= 48 && byte <= 57) return -1
            else return 0
          } else if (token_state == "integer") {
            if (byte >= 48 && byte <= 57) token_state = "integer"
            else if (byte == 46) token_state = "decimal-mark"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else return 0
          } else if (token_state == "decimal-mark") {
            if (byte >= 48 && byte <= 57) token_state = "fraction"
            else return -1
          } else if (token_state == "fraction") {
            if (byte >= 48 && byte <= 57) token_state = "fraction"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else return 0
          } else if (token_state == "exponent-mark") {
            if (byte == 43 || byte == 45) token_state = "exponent-sign"
            else if (byte >= 48 && byte <= 57) token_state = "exponent"
            else return -1
          } else if (token_state == "exponent-sign") {
            if (byte >= 48 && byte <= 57) token_state = "exponent"
            else return -1
          } else if (token_state == "exponent") {
            if (byte >= 48 && byte <= 57) token_state = "exponent"
            else return 0
          } else {
            return -1
          }
          append_token(byte)
          return 1
        }
        function push_container(byte) {
          if (!value_expected()) { fail_parse(); return }
          record_value_depth()
          depth++
          if (byte == 91) frame[depth] = 1
          else {
            frame[depth] = 4
          }
        }
        function close_container(byte, state) {
          if (depth == 0) { fail_parse(); return }
          state = frame[depth]
          if (byte == 93) {
            if (!(state == 1 || state == 3)) { fail_parse(); return }
          } else {
            if (!(state == 4 || state == 8)) { fail_parse(); return }
          }
          if (byte == 125) {
            delete previous_key_index[depth]
          }
          delete frame[depth]
          depth--
          complete_value()
        }
        function structural_ascii(byte) {
          if (byte == 32 || byte == 9 || byte == 10 || byte == 13) {
            if (depth == 0 && root_state == 2) {
              trailing_count++
              if (trailing_count == 1) trailing_byte = byte
            } else {
              internal_space = 1
            }
            return
          }
          if (depth == 0 && root_state == 2) { fail_parse(); return }
          if (byte == 34) {
            if (key_expected()) begin_token("key", byte)
            else if (value_expected()) {
              record_value_depth()
              begin_token("value", byte)
            }
            else { fail_parse(); return }
            in_string = 1
            escape_state = 0
            return
          }
          if (byte == 91 || byte == 123) { push_container(byte); return }
          if (byte == 93 || byte == 125) {
            if ((byte == 93 && frame[depth] != 1 && frame[depth] != 3) ||
                (byte == 125 && frame[depth] != 4 && frame[depth] != 8)) {
              fail_parse(); return
            }
            close_container(byte)
            return
          }
          if (byte == 44) {
            if (depth == 0) { fail_parse(); return }
            if (frame[depth] == 3) frame[depth] = 2
            else if (frame[depth] == 8) frame[depth] = 5
            else fail_parse()
            return
          }
          if (byte == 58) {
            if (depth > 0 && frame[depth] == 6) frame[depth] = 7
            else fail_parse()
            return
          }
          if (byte < 32 || byte > 127) { fail_parse(); return }
          start_atom(byte)
        }
        function string_ascii(byte) {
          append_token(byte)
          if (escape_state == 2) {
            if (!is_hex(byte)) { fail_parse(); return }
            unicode_left--
            if (unicode_left == 0) escape_state = 0
            return
          }
          if (escape_state == 1) {
            if (byte == 117) { escape_state = 2; unicode_left = 4; return }
            if (byte == 34 || byte == 92 || byte == 47 || byte == 98 ||
                byte == 102 || byte == 110 || byte == 114 || byte == 116) {
              escape_state = 0
              return
            }
            fail_parse(); return
          }
          if (byte == 34) {
            in_string = 0
            finish_scalar()
          } else if (byte == 92) {
            escape_state = 1
          } else if (byte < 32) {
            fail_parse()
          }
        }
        function consume_byte(byte, used) {
          if (parse_bad || runtime_bad) return
          byte_position++
          if (bom_state == 1) {
            if (byte != 187) { fail_parse(); return }
            bom_state = 2
            return
          }
          if (bom_state == 2) {
            if (byte != 191) { fail_parse(); return }
            bom_state = 0
            return
          }
          if (byte_position == 1 && byte == 239) {
            bom_present = 1
            bom_state = 1
            return
          }
          if (utf_need > 0) {
            if (byte < utf_min || byte > utf_max) { fail_parse(); return }
            if (!in_string) { fail_parse(); return }
            append_token(byte)
            utf_need--
            utf_min = 128
            utf_max = 191
            return
          }
          if (byte > 127) {
            if (!in_string) { fail_parse(); return }
            append_token(byte)
            if (byte >= 194 && byte <= 223) {
              utf_need = 1; utf_min = 128; utf_max = 191
            } else if (byte == 224) {
              utf_need = 2; utf_min = 160; utf_max = 191
            } else if ((byte >= 225 && byte <= 236) ||
                       (byte >= 238 && byte <= 239)) {
              utf_need = 2; utf_min = 128; utf_max = 191
            } else if (byte == 237) {
              utf_need = 2; utf_min = 128; utf_max = 159
            } else if (byte == 240) {
              utf_need = 3; utf_min = 144; utf_max = 191
            } else if (byte >= 241 && byte <= 243) {
              utf_need = 3; utf_min = 128; utf_max = 191
            } else if (byte == 244) {
              utf_need = 3; utf_min = 128; utf_max = 143
            } else {
              fail_parse()
            }
            return
          }
          if (in_string) { string_ascii(byte); return }
          if (token_active) {
            used = atom_byte(byte)
            if (used == 1) return
            if (used < 0 || !token_terminal()) { fail_parse(); return }
            finish_scalar()
            if (parse_bad) return
          }
          structural_ascii(byte)
        }
        BEGIN {
          depth = 0
          max_depth = 0
          root_state = 1
          parse_bad = 0
          runtime_bad = 0
          token_active = 0
          in_string = 0
          utf_need = 0
          internal_space = 0
          trailing_count = 0
          byte_position = 0
          bom_state = 0
          bom_present = 0
          key_count = 0
        }
        {
          for (i = 1; i <= NF; i++) {
            if ($i !~ /^[0-9]+$/ || ($i + 0) < 0 || ($i + 0) > 255) {
              runtime_bad = 1
              next
            }
            consume_byte($i + 0)
          }
        }
        END {
          meta_text = ""
          if (!parse_bad && token_active) {
            if (!token_terminal()) fail_parse()
            else finish_scalar()
          }
          if (in_string || utf_need != 0 || bom_state != 0 ||
              depth != 0 || root_state != 2) fail_parse()
          if (runtime_bad) {
            meta_text = "R\n"
          } else if (parse_bad) {
            meta_text = "P\n"
          } else {
            structurally_canonical = !bom_present && !internal_space &&
                                     trailing_count == 1 && trailing_byte == 10
            meta_text = sprintf("S %d %d\n", structurally_canonical, max_depth)
          }
          if (measure_only) {
            printf "%d %d %d %d\n", scalar_size, key_size, key_pair_size,
                                     length(meta_text)
          } else {
            printf "%s", meta_text
          }
        }
'
  if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
    scan_sizes="$(
      "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 "$raw_path" 2>/dev/null |
        LC_ALL=C "$PORTABLE_CORE_INGRESS_AWK" \
          -v measure_only=1 \
          -v scalar_file="$scalar_path" \
          -v key_file="$key_path" \
          -v key_pair_file="$key_pair_path" "$scan_program"
    )" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    case "$scan_sizes" in *$'\n'*|*$'\r'*)
      portable_core_ingress_error E_RUNTIME
      return 1
    esac
    [[ "$scan_sizes" =~ ^([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)$ ]] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    scalar_size="${BASH_REMATCH[1]}"
    key_size="${BASH_REMATCH[2]}"
    key_pair_size="${BASH_REMATCH[3]}"
    meta_size="${BASH_REMATCH[4]}"
    expected_scan_bytes=$((scalar_size + key_size + key_pair_size + meta_size))
    portable_core_ingress_account_reserve "$expected_scan_bytes" || return 1
  else
    expected_scan_bytes=0
  fi
  if "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 "$raw_path" 2>/dev/null |
      LC_ALL=C "$PORTABLE_CORE_INGRESS_AWK" \
        -v measure_only=0 \
        -v scalar_file="$scalar_path" \
        -v key_file="$key_path" \
        -v key_pair_file="$key_pair_path" "$scan_program" \
        2>/dev/null > "$meta_path"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  portable_core_ingress_account_files "$expected_scan_bytes" \
    "$scalar_path" "$key_path" "$key_pair_path" "$meta_path" || return 1
  [ "${#pipeline_status[@]}" -eq 2 ] &&
    [ "${pipeline_status[0]}" -eq 0 ] &&
    [ "${pipeline_status[1]}" -eq 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }

  meta_size="$("$PORTABLE_CORE_INGRESS_WC" -c 2>/dev/null < "$meta_path")" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  meta_lines="$("$PORTABLE_CORE_INGRESS_WC" -l 2>/dev/null < "$meta_path")" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  meta_size="${meta_size//[[:space:]]/}"
  meta_lines="${meta_lines//[[:space:]]/}"
  [[ "$meta_size" =~ ^[0-9]+$ ]] && [[ "$meta_lines" =~ ^[0-9]+$ ]] &&
    [ "$meta_size" -ge 2 ] && [ "$meta_lines" -eq 1 ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  IFS=' ' read -r meta_kind structural_canonical max_depth extra_meta \
    2>/dev/null < "$meta_path" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  case "$meta_kind" in
    P)
      [ "$meta_size" -eq 2 ] && [ -z "${structural_canonical:-}" ] &&
        [ -z "${max_depth:-}" ] && [ -z "${extra_meta:-}" ] || {
          portable_core_ingress_error E_RUNTIME
          return 1
        }
      portable_core_ingress_error E_PARSE
      return 1
      ;;
    R)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
    S) ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  case "$structural_canonical" in 0|1) ;; *)
    portable_core_ingress_error E_RUNTIME
    return 1
  esac
  [[ "$max_depth" =~ ^[0-9]+$ ]] && [ -z "${extra_meta:-}" ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  if [ "$max_depth" -gt 32 ]; then
    PORTABLE_CORE_INGRESS_ANALYZE_DEPTH_OVER=true
  else
    PORTABLE_CORE_INGRESS_ANALYZE_DEPTH_OVER=false
  fi

  scalar_program='      foreach (inputs, {end:true}) as $event
        ({emit:"", parse:true, runtime:true};
         if ($event | type) == "object" then
           if (.runtime | not) then halt_error(42)
           elif (.parse | not) then .emit = "\u0000"
           else .emit = ""
           end
         elif (.parse | not) then .emit = ""
         elif (($event | type) != "array") or (($event | length) == 0) then
           .runtime = false | .emit = ""
         elif ($event[0] | type) == "string" then
           .parse = false | .emit = ""
         elif (($event | length) == 2) and ($event[0] == []) then
           .emit = ($event[1] | tojson) + "\n"
         else .runtime = false | .emit = ""
         end;
         .emit)
'
  if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
    scalar_canonical_size="$(
      "$PORTABLE_CORE_INGRESS_JQ" -n --stream --stream-errors -j \
        "$scalar_program" "$scalar_path" 2>/dev/null |
        "$PORTABLE_CORE_INGRESS_WC" -c 2>/dev/null
    )" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    scalar_canonical_size="${scalar_canonical_size//[[:space:]]/}"
    portable_core_ingress_decimal "$scalar_canonical_size" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    portable_core_ingress_account_reserve "$scalar_canonical_size" || return 1
  else
    scalar_canonical_size=0
  fi
  if "$PORTABLE_CORE_INGRESS_JQ" -n --stream --stream-errors -j \
      "$scalar_program" "$scalar_path" 2>/dev/null > "$scalar_canonical_path"; then
    portable_core_ingress_account_files "$scalar_canonical_size" \
      "$scalar_canonical_path" || return 1
  else
    portable_core_ingress_account_files "$scalar_canonical_size" \
      "$scalar_canonical_path" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  marker_kind="$(
    "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 \
        "$scalar_canonical_path" 2>/dev/null |
      "$PORTABLE_CORE_INGRESS_AWK" '
        {
          for (i = 1; i <= NF; i++) if (($i + 0) == 0) found = 1
        }
        END { print found ? "P" : "C" }
      ' 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  marker_size=$((${#marker_kind} + 1))
  portable_core_ingress_account_reserve "$marker_size" || return 1
  if printf '%s\n' "$marker_kind" 2>/dev/null > "$scalar_marker_path"; then
    portable_core_ingress_account_files "$marker_size" \
      "$scalar_marker_path" || return 1
  else
    portable_core_ingress_account_files "$marker_size" \
      "$scalar_marker_path" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  marker_size="$("$PORTABLE_CORE_INGRESS_WC" -c \
    2>/dev/null < "$scalar_marker_path")" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  marker_lines="$("$PORTABLE_CORE_INGRESS_WC" -l \
    2>/dev/null < "$scalar_marker_path")" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  marker_size="${marker_size//[[:space:]]/}"
  marker_lines="${marker_lines//[[:space:]]/}"
  [[ "$marker_size" =~ ^[0-9]+$ ]] && [[ "$marker_lines" =~ ^[0-9]+$ ]] &&
    [ "$marker_size" -eq 2 ] && [ "$marker_lines" -eq 1 ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
  IFS= read -r marker_kind 2>/dev/null < "$scalar_marker_path" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$marker_kind" in
    C) ;;
    P)
      portable_core_ingress_error E_PARSE
      return 1
      ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  if "$PORTABLE_CORE_INGRESS_CMP" -s -- "$scalar_path" \
      "$scalar_canonical_path" 2>/dev/null; then
    :
  else
    compare_status=$?
    if [ "$compare_status" -eq 1 ]; then
      canonical_ok=false
    else
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  fi

  if [ -s "$key_pair_path" ]; then
    key_order_output="$("$PORTABLE_CORE_INGRESS_JQ" -n -j \
        --slurpfile keys "$key_path" '
        reduce inputs as $pair
          (false;
           if (($pair | type) != "array") or (($pair | length) != 2) or
              (all($pair[];
                (type == "number") and (. >= 0) and (floor == .)) | not) or
              ($pair[0] >= ($keys | length)) or
              ($pair[1] >= ($keys | length)) then
             halt_error(43)
           else . or (($keys[$pair[0]] < $keys[$pair[1]]) | not)
           end)
        | if . then "x" else empty end
      ' "$key_pair_path" 2>/dev/null)" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    key_order_size="${#key_order_output}"
    portable_core_ingress_account_reserve "$key_order_size" || return 1
    if printf '%s' "$key_order_output" 2>/dev/null > "$key_order_path"; then
      portable_core_ingress_account_files "$key_order_size" \
        "$key_order_path" || return 1
    else
      portable_core_ingress_account_files "$key_order_size" \
        "$key_order_path" >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  fi
  if [ -s "$key_order_path" ]; then
    if "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 "$key_order_path" 2>/dev/null |
        "$PORTABLE_CORE_INGRESS_AWK" '
          {
            for (i = 1; i <= NF; i++) {
              count++
              if (($i + 0) != 120) invalid = 1
            }
          }
          END { if (invalid || count != 1) exit 42 }
        ' >/dev/null 2>/dev/null; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi
    [ "${#pipeline_status[@]}" -eq 2 ] &&
      [ "${pipeline_status[0]}" -eq 0 ] &&
      [ "${pipeline_status[1]}" -eq 0 ] || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
    canonical_ok=false
  fi
  if [ "$structural_canonical" != 1 ]; then
    canonical_ok=false
  fi

  if [ "$canonical_ok" = true ]; then
    portable_core_ingress_file_size "$raw_path" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    canonical_size="$PORTABLE_CORE_INGRESS_MEASURED_SIZE"
    portable_core_ingress_account_reserve "$canonical_size" || return 1
    if ! "$PORTABLE_CORE_INGRESS_CAT" -- "$raw_path" \
        2>/dev/null > "$canonical_path"; then
      portable_core_ingress_account_files "$canonical_size" "$canonical_path" \
        >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    portable_core_ingress_account_files "$canonical_size" \
      "$canonical_path" || return 1
  else
    canonical_size=2
    portable_core_ingress_account_reserve "$canonical_size" || return 1
    if ! printf '!\n' 2>/dev/null > "$canonical_path"; then
      portable_core_ingress_account_files "$canonical_size" "$canonical_path" \
        >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    portable_core_ingress_account_files "$canonical_size" \
      "$canonical_path" || return 1
  fi
}

portable_core_ingress_finish_driver() {
  local input_index
  local raw_path
  local canonical_path
  local compare_status
  local contents_before
  local hashes_before
  local driver_program
  local driver_size

  [ "$#" -eq 0 ] && [ "${PORTABLE_CORE_INGRESS_COUNT:-0}" -gt 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }

  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    if [ "${PORTABLE_CORE_INGRESS_RAW_SIZES[$input_index]}" -gt 1048576 ]; then
      portable_core_ingress_error E_LIMIT
      return 1
    fi
  done
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    canonical_path="$PORTABLE_CORE_INGRESS_TEMP/canonical.$((input_index + 1))"
    portable_core_ingress_analyze "$raw_path" "$canonical_path" || return 1
    PORTABLE_CORE_INGRESS_DEPTH_OVER[input_index]="$PORTABLE_CORE_INGRESS_ANALYZE_DEPTH_OVER"
    PORTABLE_CORE_INGRESS_CANONICAL_PATHS[input_index]="$canonical_path"
  done
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    canonical_path="${PORTABLE_CORE_INGRESS_CANONICAL_PATHS[$input_index]}"
    if "$PORTABLE_CORE_INGRESS_CMP" -s -- "$raw_path" "$canonical_path" 2>/dev/null; then
      :
    else
      compare_status=$?
      if [ "$compare_status" -eq 1 ]; then
        portable_core_ingress_error E_CANONICAL
      else
        portable_core_ingress_error E_RUNTIME
      fi
      return 1
    fi
  done
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    if [ "${PORTABLE_CORE_INGRESS_DEPTH_OVER[$input_index]}" = true ]; then
      portable_core_ingress_error E_LIMIT
      return 1
    fi
  done
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    portable_core_ingress_digest "$raw_path" || return 1
    if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
      portable_core_ingress_file_size "$PORTABLE_CORE_INGRESS_CONTENTS" || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
      contents_before="$PORTABLE_CORE_INGRESS_MEASURED_SIZE"
    else
      contents_before=0
    fi
    portable_core_ingress_account_reserve \
      "${PORTABLE_CORE_INGRESS_RAW_SIZES[$input_index]}" || return 1
    if "$PORTABLE_CORE_INGRESS_CAT" -- "$raw_path" \
        2>/dev/null >> "$PORTABLE_CORE_INGRESS_CONTENTS"; then
      portable_core_ingress_account_append \
        "${PORTABLE_CORE_INGRESS_RAW_SIZES[$input_index]}" \
        "$contents_before" "$PORTABLE_CORE_INGRESS_CONTENTS" || return 1
    else
      portable_core_ingress_account_append \
        "${PORTABLE_CORE_INGRESS_RAW_SIZES[$input_index]}" \
        "$contents_before" "$PORTABLE_CORE_INGRESS_CONTENTS" \
        >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
      portable_core_ingress_file_size "$PORTABLE_CORE_INGRESS_HASHES" || {
        portable_core_ingress_error E_RUNTIME
        return 1
      }
      hashes_before="$PORTABLE_CORE_INGRESS_MEASURED_SIZE"
    else
      hashes_before=0
    fi
    portable_core_ingress_account_reserve 67 || return 1
    if printf '"%s"\n' "$PORTABLE_CORE_INGRESS_SHA256" \
        2>/dev/null >> "$PORTABLE_CORE_INGRESS_HASHES"; then
      portable_core_ingress_account_append 67 "$hashes_before" \
        "$PORTABLE_CORE_INGRESS_HASHES" || return 1
    else
      portable_core_ingress_account_append 67 "$hashes_before" \
        "$PORTABLE_CORE_INGRESS_HASHES" >/dev/null 2>&1 || :
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  done
  PORTABLE_CORE_INGRESS_DRIVER="$PORTABLE_CORE_INGRESS_TEMP/driver.json"
  driver_program='      {mode:$mode,
       docs:([range(0;($contents|length))] |
         map({content:$contents[.],sha256:$hashes[.]}))}
'
  if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
    driver_size="$(
      "$PORTABLE_CORE_INGRESS_JQ" -n -S -c \
        --arg mode "$PORTABLE_CORE_INGRESS_MODE" \
        --slurpfile contents "$PORTABLE_CORE_INGRESS_CONTENTS" \
        --slurpfile hashes "$PORTABLE_CORE_INGRESS_HASHES" \
        "$driver_program" 2>/dev/null |
        "$PORTABLE_CORE_INGRESS_WC" -c 2>/dev/null
    )" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    driver_size="${driver_size//[[:space:]]/}"
    portable_core_ingress_decimal "$driver_size" || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    portable_core_ingress_account_reserve "$driver_size" || return 1
  else
    driver_size=0
  fi
  if ! "$PORTABLE_CORE_INGRESS_JQ" -n -S -c \
      --arg mode "$PORTABLE_CORE_INGRESS_MODE" \
      --slurpfile contents "$PORTABLE_CORE_INGRESS_CONTENTS" \
      --slurpfile hashes "$PORTABLE_CORE_INGRESS_HASHES" \
      "$driver_program" \
      2>/dev/null > "$PORTABLE_CORE_INGRESS_DRIVER"; then
    portable_core_ingress_account_files "$driver_size" \
      "$PORTABLE_CORE_INGRESS_DRIVER" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  portable_core_ingress_account_files "$driver_size" \
    "$PORTABLE_CORE_INGRESS_DRIVER" || return 1
  if ! "$PORTABLE_CORE_INGRESS_JQ" -e \
      '(.docs|length) > 0 and (.docs|length) == ([.docs[].sha256]|length)' \
      "$PORTABLE_CORE_INGRESS_DRIVER" >/dev/null 2>/dev/null; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
}

portable_core_ingress_validate() {
  local output_size
  local token
  local validator_capture
  local validator_encoded
  local validator_status_record
  local validator_jq_status
  local validator_od_status
  local -a pipeline_status

  if [ "$#" -ne 0 ] ||
     ! portable_core_ingress_regular_file "${PORTABLE_CORE_INGRESS_DRIVER:-}" ||
     ! portable_core_ingress_regular_file "${PORTABLE_CORE_INGRESS_ROOT:-}"; then
      portable_core_ingress_error E_RUNTIME
      return 1
  fi
  PORTABLE_CORE_INGRESS_OUTPUT="$PORTABLE_CORE_INGRESS_TEMP/validator.out"
  validator_capture="$(
    if (
        CDPATH='' cd -P -- "$PORTABLE_CORE_INGRESS_MODULE_DIR" &&
          HOME=/nonexistent JQ_LIBRARY_PATH=/nonexistent \
            "$PORTABLE_CORE_INGRESS_JQ" -L "$PORTABLE_CORE_INGRESS_MODULE_DIR" -r \
            -f "$PORTABLE_CORE_INGRESS_ROOT" "$PORTABLE_CORE_INGRESS_DRIVER"
      ) 2>/dev/null | "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 2>/dev/null; then
      pipeline_status=("${PIPESTATUS[@]}")
    else
      pipeline_status=("${PIPESTATUS[@]}")
    fi
    printf 'S %s %s\n' "${pipeline_status[0]}" "${pipeline_status[1]}"
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$validator_capture" in
    *$'\n'*)
      validator_encoded="${validator_capture%$'\n'*}"
      validator_status_record="${validator_capture##*$'\n'}"
      ;;
    *)
      validator_encoded=''
      validator_status_record="$validator_capture"
      ;;
  esac
  [[ "$validator_status_record" =~ ^S[[:space:]]([0-9]+)[[:space:]]([0-9]+)$ ]] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  validator_jq_status="${BASH_REMATCH[1]}"
  validator_od_status="${BASH_REMATCH[2]}"
  [ "$validator_jq_status" -eq 0 ] && [ "$validator_od_status" -eq 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  output_size="$(
    printf '%s\n' "$validator_encoded" |
      "$PORTABLE_CORE_INGRESS_AWK" '
        {
          for (i = 1; i <= NF; i++) {
            if ($i !~ /^[0-9]+$/ || ($i + 0) < 0 || ($i + 0) > 255) {
              invalid = 1
              exit 42
            }
            count++
          }
        }
        END { if (!invalid) print count + 0 }
      ' 2>/dev/null
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  output_size="${output_size//[[:space:]]/}"
  portable_core_ingress_decimal "$output_size" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  portable_core_ingress_account_reserve "$output_size" || return 1
  if printf '%s\n' "$validator_encoded" |
      "$PORTABLE_CORE_INGRESS_AWK" '
        { for (i = 1; i <= NF; i++) printf "%c", ($i + 0) }
      ' 2>/dev/null > "$PORTABLE_CORE_INGRESS_OUTPUT"; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  if [ "${#pipeline_status[@]}" -ne 2 ] ||
     [ "${pipeline_status[0]}" -ne 0 ] ||
     [ "${pipeline_status[1]}" -ne 0 ]; then
    portable_core_ingress_account_files "$output_size" \
      "$PORTABLE_CORE_INGRESS_OUTPUT" >/dev/null 2>&1 || :
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  portable_core_ingress_account_files "$output_size" \
    "$PORTABLE_CORE_INGRESS_OUTPUT" || return 1
  if [ ! -s "$PORTABLE_CORE_INGRESS_OUTPUT" ]; then
    return 0
  fi
  output_size="$("$PORTABLE_CORE_INGRESS_WC" -c \
    2>/dev/null < "$PORTABLE_CORE_INGRESS_OUTPUT")" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  output_size="${output_size//[[:space:]]/}"
  [[ "$output_size" =~ ^[0-9]+$ ]] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  IFS= read -r token 2>/dev/null < "$PORTABLE_CORE_INGRESS_OUTPUT" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  case "$token" in
    E_LIMIT|E_SHAPE|E_REF|E_RELATION) ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  if [ "$output_size" -ne $((${#token} + 1)) ]; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  portable_core_ingress_error "$token"
}

portable_core_ingress_close() {
  local temp_path="${PORTABLE_CORE_INGRESS_TEMP:-}"
  if [ "${PORTABLE_CORE_INGRESS_ACCOUNTED:-false}" = true ]; then
    if [ "$temp_path" = \
         "${PORTABLE_CORE_INGRESS_SCRATCH_ROOT:-}/portable-core-accounted-v2.${PORTABLE_CORE_INGRESS_OWNER_PID:-}" ] &&
       [[ "${PORTABLE_CORE_INGRESS_OWNER_PID:-}" =~ ^[1-9][0-9]*$ ]]; then
      if [ "${PORTABLE_CORE_INGRESS_OWNS_TEMP:-false}" = true ]; then
        if [ -d "$temp_path" ] && [ ! -L "$temp_path" ]; then
          if ! "$PORTABLE_CORE_INGRESS_RM" -rf -- "$temp_path" \
              >/dev/null 2>&1; then
            portable_core_ingress_error E_RUNTIME
            return 1
          fi
        elif [ -e "$temp_path" ] || [ -L "$temp_path" ]; then
          portable_core_ingress_error E_RUNTIME
          return 1
        fi
      fi
      PORTABLE_CORE_INGRESS_CREATING_TEMP=false
      PORTABLE_CORE_INGRESS_OWNS_TEMP=false
      PORTABLE_CORE_INGRESS_OWNER_PID=''
      PORTABLE_CORE_INGRESS_TEMP=''
      return 0
    fi
    [ -z "$temp_path" ] || {
      portable_core_ingress_error E_RUNTIME
      return 1
    }
    return 0
  fi
  case "$temp_path" in
    /tmp/ystack-portable-core-ingress.*)
      if [ -d "$temp_path" ] && [ ! -L "$temp_path" ]; then
        if ! "$PORTABLE_CORE_INGRESS_RM" -rf -- "$temp_path" >/dev/null 2>&1; then
          portable_core_ingress_error E_RUNTIME
          return 1
        fi
      fi
      ;;
    '') ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
  PORTABLE_CORE_INGRESS_TEMP=''
}
