#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034

portable_core_ingress_error() {
  case "${1:-}" in
    E_RUNTIME|E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION)
      printf '%s\n' "$1" >&2
      ;;
    *)
      printf '%s\n' E_RUNTIME >&2
      ;;
  esac
  return 1
}

portable_core_ingress_regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

portable_core_ingress_real_directory() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

portable_core_ingress_open() {
  local source_dir
  local repo_root
  local expected_dir
  local jq_path
  local schema_identity
  local sha_path
  local temp_path
  local required_dir

  [ "$#" -eq 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }

  PORTABLE_CORE_INGRESS_GENERATION='g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386'
  source_dir="$(
    CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P
  )" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  repo_root="$(CDPATH='' cd -P -- "$source_dir/../../../.." 2>/dev/null && pwd -P)" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  expected_dir="$repo_root/core/v1/generations/$PORTABLE_CORE_INGRESS_GENERATION"
  [ "$source_dir" = "$expected_dir" ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  for required_dir in \
    "$repo_root" \
    "$repo_root/core" \
    "$repo_root/core/v1" \
    "$repo_root/core/v1/generations" \
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
  [ "$("$jq_path" --version 2>/dev/null)" = jq-1.6 ] || {
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
  [ "$schema_identity" = core.contracts.v1 ] || {
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
  : 2>/dev/null > "$PORTABLE_CORE_INGRESS_CONTENTS" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  : 2>/dev/null > "$PORTABLE_CORE_INGRESS_HASHES" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_COUNT=0
  PORTABLE_CORE_INGRESS_RAW_PATHS=()
  PORTABLE_CORE_INGRESS_RAW_SIZES=()
  PORTABLE_CORE_INGRESS_CANONICAL_PATHS=()
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
  read -r digest _ <<< "$digest_output"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && [[ "$digest_output" != *$'\n'* ]] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_SHA256="$digest"
}

portable_core_ingress_snapshot() {
  local input_path
  local snapshot_number
  local raw_path
  local byte_count

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
  if ! "$PORTABLE_CORE_INGRESS_HEAD" -c 1048577 -- "$input_path" \
      2>/dev/null > "$raw_path"; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  byte_count="$("$PORTABLE_CORE_INGRESS_WC" -c 2>/dev/null < "$raw_path")" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  byte_count="${byte_count//[[:space:]]/}"
  [[ "$byte_count" =~ ^[0-9]+$ ]] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  PORTABLE_CORE_INGRESS_RAW_PATHS[PORTABLE_CORE_INGRESS_COUNT]="$raw_path"
  PORTABLE_CORE_INGRESS_RAW_SIZES[PORTABLE_CORE_INGRESS_COUNT]="$byte_count"
  PORTABLE_CORE_INGRESS_SNAPSHOT="$raw_path"
  PORTABLE_CORE_INGRESS_COUNT="$snapshot_number"
}

portable_core_ingress_finish_driver() {
  local input_index
  local raw_path
  local canonical_path
  local compare_status
  local json_token_pattern

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
  json_token_pattern='(?:[ \t\r\n]+|[\[\]{}:,]|"(?:[^"\\\x00-\x1f]|\\(?:["\\/bfnrt]|u[0-9A-Fa-f]{4}))*"|(?<![A-Za-z0-9_.+-])-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?(?![A-Za-z0-9_.+-])|(?<![A-Za-z0-9_])(?:true|false|null)(?![A-Za-z0-9_]))'
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    if ! "$PORTABLE_CORE_INGRESS_JQ" -s -e 'length == 1' "$raw_path" \
        >/dev/null 2>/dev/null; then
      portable_core_ingress_error E_PARSE
      return 1
    fi
    if ! "$PORTABLE_CORE_INGRESS_JQ" -Rse --arg token "$json_token_pattern" \
        '(if startswith("\ufeff") then .[1:] else . end) |
         gsub($token;"") == ""' "$raw_path" >/dev/null 2>/dev/null; then
      portable_core_ingress_error E_PARSE
      return 1
    fi
    canonical_path="$PORTABLE_CORE_INGRESS_TEMP/canonical.$((input_index + 1))"
    if ! "$PORTABLE_CORE_INGRESS_JQ" -s -S -c \
        'if length == 1 then .[0] else error("root-count") end' "$raw_path" \
        2>/dev/null > "$canonical_path"; then
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
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
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    portable_core_ingress_digest "$raw_path" || return 1
    if ! "$PORTABLE_CORE_INGRESS_CAT" -- "$raw_path" \
        2>/dev/null >> "$PORTABLE_CORE_INGRESS_CONTENTS"; then
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
    if ! printf '"%s"\n' "$PORTABLE_CORE_INGRESS_SHA256" \
        2>/dev/null >> "$PORTABLE_CORE_INGRESS_HASHES"; then
      portable_core_ingress_error E_RUNTIME
      return 1
    fi
  done
  PORTABLE_CORE_INGRESS_DRIVER="$PORTABLE_CORE_INGRESS_TEMP/driver.json"
  if ! "$PORTABLE_CORE_INGRESS_JQ" -n -S -c \
      --arg mode "$PORTABLE_CORE_INGRESS_MODE" \
      --slurpfile contents "$PORTABLE_CORE_INGRESS_CONTENTS" \
      --slurpfile hashes "$PORTABLE_CORE_INGRESS_HASHES" \
      '{mode:$mode,
        docs:([range(0;($contents|length))] |
          map({content:$contents[.],sha256:$hashes[.]}))}' \
      2>/dev/null > "$PORTABLE_CORE_INGRESS_DRIVER"; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
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

  if [ "$#" -ne 0 ] ||
     ! portable_core_ingress_regular_file "${PORTABLE_CORE_INGRESS_DRIVER:-}" ||
     ! portable_core_ingress_regular_file "${PORTABLE_CORE_INGRESS_ROOT:-}"; then
      portable_core_ingress_error E_RUNTIME
      return 1
  fi
  PORTABLE_CORE_INGRESS_OUTPUT="$PORTABLE_CORE_INGRESS_TEMP/validator.out"
  if ! (
    CDPATH='' cd -P -- "$PORTABLE_CORE_INGRESS_MODULE_DIR" &&
      HOME=/nonexistent JQ_LIBRARY_PATH=/nonexistent \
        "$PORTABLE_CORE_INGRESS_JQ" -L "$PORTABLE_CORE_INGRESS_MODULE_DIR" -r \
        -f "$PORTABLE_CORE_INGRESS_ROOT" "$PORTABLE_CORE_INGRESS_DRIVER"
  ) 2>/dev/null > "$PORTABLE_CORE_INGRESS_OUTPUT"; then
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  if [ ! -s "$PORTABLE_CORE_INGRESS_OUTPUT" ]; then
    return 0
  fi
  output_size="$("$PORTABLE_CORE_INGRESS_WC" -c \
    2>/dev/null < "$PORTABLE_CORE_INGRESS_OUTPUT")" || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  output_size="${output_size//[[:space:]]/}"
  token="$("$PORTABLE_CORE_INGRESS_CAT" -- "$PORTABLE_CORE_INGRESS_OUTPUT" 2>/dev/null)" || {
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
