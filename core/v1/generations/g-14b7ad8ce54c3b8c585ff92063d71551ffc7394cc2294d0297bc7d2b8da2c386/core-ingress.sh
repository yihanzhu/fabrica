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
  PORTABLE_CORE_INGRESS_DEPTH_OVER=()
  PORTABLE_CORE_INGRESS_STREAM_REQUIRED=()
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
  PORTABLE_CORE_INGRESS_DEPTH_OVER=()
  PORTABLE_CORE_INGRESS_STREAM_REQUIRED=()
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

portable_core_ingress_scan_raw() {
  local raw_path="$1"
  local scan_status
  local -a pipeline_status

  portable_core_ingress_regular_file "$raw_path" && [ -r "$raw_path" ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  if "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 "$raw_path" 2>/dev/null |
      "$PORTABLE_CORE_INGRESS_AWK" '
        function literal_expected(kind, position) {
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
        function start_token(byte) {
          token_active = 1
          if (byte == 116) {
            token_state = "literal"; literal_kind = 1; literal_position = 1;
            literal_length = 4
          } else if (byte == 102) {
            token_state = "literal"; literal_kind = 2; literal_position = 1;
            literal_length = 5
          } else if (byte == 110) {
            token_state = "literal"; literal_kind = 3; literal_position = 1;
            literal_length = 4
          } else if (byte == 45) {
            token_state = "sign"
          } else if (byte == 48) {
            token_state = "zero"
          } else if (byte >= 49 && byte <= 57) {
            token_state = "integer"
          } else {
            invalid_token = 1
          }
        }
        function advance_token(byte) {
          if (!token_active) {
            start_token(byte)
          } else if (token_state == "literal") {
            literal_position++
            if (literal_position > literal_length ||
                byte != literal_expected(literal_kind, literal_position)) {
              invalid_token = 1
            }
          } else if (token_state == "sign") {
            if (byte == 48) token_state = "zero"
            else if (byte >= 49 && byte <= 57) token_state = "integer"
            else invalid_token = 1
          } else if (token_state == "zero") {
            if (byte == 46) token_state = "decimal-mark"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else invalid_token = 1
          } else if (token_state == "integer") {
            if (byte >= 48 && byte <= 57) token_state = "integer"
            else if (byte == 46) token_state = "decimal-mark"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else invalid_token = 1
          } else if (token_state == "decimal-mark") {
            if (byte >= 48 && byte <= 57) token_state = "fraction"
            else invalid_token = 1
          } else if (token_state == "fraction") {
            if (byte >= 48 && byte <= 57) token_state = "fraction"
            else if (byte == 101 || byte == 69) token_state = "exponent-mark"
            else invalid_token = 1
          } else if (token_state == "exponent-mark") {
            if (byte == 43 || byte == 45) token_state = "exponent-sign"
            else if (byte >= 48 && byte <= 57) token_state = "exponent"
            else invalid_token = 1
          } else if (token_state == "exponent-sign") {
            if (byte >= 48 && byte <= 57) token_state = "exponent"
            else invalid_token = 1
          } else if (token_state == "exponent") {
            if (byte < 48 || byte > 57) invalid_token = 1
          } else {
            invalid_token = 1
          }
        }
        function finish_token() {
          if (token_active &&
              !((token_state == "literal" && literal_position == literal_length) ||
                token_state == "zero" || token_state == "integer" ||
                token_state == "fraction" || token_state == "exponent")) {
            invalid_token = 1
          }
          token_active = 0
          token_state = ""
        }
        BEGIN {
          in_string = 0; escaped = 0; need = 0; invalid = 0;
          invalid_token = 0; token_active = 0; token_state = "";
          next_min = 128; next_max = 191; depth = 0; max_depth = 0
        }
        {
          for (i = 1; i <= NF; i++) {
            byte = $i + 0
            ascii = (need == 0 && byte <= 127)
            if (need > 0) {
              if (byte < next_min || byte > next_max) {
                invalid = 1; need = 0
              } else {
                need--; next_min = 128; next_max = 191
              }
            } else if (byte <= 127) {
              # ASCII is valid and also drives JSON string/depth state below.
            } else if (byte >= 194 && byte <= 223) {
              need = 1; next_min = 128; next_max = 191
            } else if (byte == 224) {
              need = 2; next_min = 160; next_max = 191
            } else if ((byte >= 225 && byte <= 236) ||
                       (byte >= 238 && byte <= 239)) {
              need = 2; next_min = 128; next_max = 191
            } else if (byte == 237) {
              need = 2; next_min = 128; next_max = 159
            } else if (byte == 240) {
              need = 3; next_min = 144; next_max = 191
            } else if (byte >= 241 && byte <= 243) {
              need = 3; next_min = 128; next_max = 191
            } else if (byte == 244) {
              need = 3; next_min = 128; next_max = 143
            } else {
              invalid = 1
            }

            if (ascii) {
              if (in_string) {
                if (escaped) escaped = 0
                else if (byte == 92) escaped = 1
                else if (byte == 34) in_string = 0
              } else if (byte == 34) {
                finish_token()
                in_string = 1
              } else if (byte == 91 || byte == 123) {
                finish_token()
                depth++
                if (depth > max_depth) max_depth = depth
              } else if ((byte == 93 || byte == 125) && depth > 0) {
                finish_token()
                depth--
              } else if (byte == 93 || byte == 125 || byte == 44 ||
                         byte == 58 || byte == 9 || byte == 10 ||
                         byte == 13 || byte == 32) {
                finish_token()
              } else if (byte < 32) {
                invalid_token = 1
              } else {
                advance_token(byte)
              }
            } else if (!in_string && token_active) {
              invalid_token = 1
            }
          }
        }
        END {
          finish_token()
          if (invalid || need != 0 || invalid_token) exit 31
          if (max_depth > 128) exit 33
          if (max_depth > 32) exit 32
        }
      ' >/dev/null 2>/dev/null; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  [ "${#pipeline_status[@]}" -eq 2 ] && [ "${pipeline_status[0]}" -eq 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  scan_status="${pipeline_status[1]}"
  case "$scan_status" in
    0)
      PORTABLE_CORE_INGRESS_SCAN_DEPTH_OVER=false
      PORTABLE_CORE_INGRESS_SCAN_STREAM_REQUIRED=false
      ;;
    31)
      portable_core_ingress_error E_PARSE
      return 1
      ;;
    32)
      PORTABLE_CORE_INGRESS_SCAN_DEPTH_OVER=true
      PORTABLE_CORE_INGRESS_SCAN_STREAM_REQUIRED=false
      ;;
    33)
      PORTABLE_CORE_INGRESS_SCAN_DEPTH_OVER=true
      PORTABLE_CORE_INGRESS_SCAN_STREAM_REQUIRED=true
      ;;
    *)
      portable_core_ingress_error E_RUNTIME
      return 1
      ;;
  esac
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

portable_core_ingress_tree_canonical() {
  local raw_path="$1"
  local canonical_path="$2"
  local parse_status

  if "$PORTABLE_CORE_INGRESS_JQ" -s -e 'length == 1' "$raw_path" \
      >/dev/null 2>/dev/null; then
    :
  else
    parse_status=$?
    case "$parse_status" in
      1|4) portable_core_ingress_error E_PARSE ;;
      *) portable_core_ingress_error E_RUNTIME ;;
    esac
    return 1
  fi
  if "$PORTABLE_CORE_INGRESS_JQ" -s -S -c \
      'if length == 1 then .[0] else error("root-count") end' "$raw_path" \
      2>/dev/null > "$canonical_path"; then
    return 0
  fi
  portable_core_ingress_error E_RUNTIME
  return 1
}

portable_core_ingress_stream_canonical() {
  local raw_path="$1"
  local canonical_path="$2"
  local marker_status
  local -a pipeline_status

  if "$PORTABLE_CORE_INGRESS_JQ" -n --stream --stream-errors -j '
      def component_kind($component):
        if ($component | type) == "number" then "array"
        elif ($component | type) == "string" then "object"
        else null
        end;
      def first_children_valid($path):
        all($path[];
          ((type == "number") and (. == 0)) or (type == "string"));
      def open_first_children($path):
        [$path[] |
          if type == "number" then "["
          else "{" + (tojson) + ":"
          end] | join("");
      def closer($kind): if $kind == "array" then "]" else "}" end;
      foreach (inputs, {end: true}) as $event
        ({emit: "", last_path: [], open_depth: 0, started: false,
          done: false, parse: true, runtime: true, ordered: true};
         if ($event | type) == "object" then
           if (.runtime | not) then halt_error(42)
           elif (.parse | not) or (.started | not) or (.done | not) or
                (.open_depth != 0) then .emit = "\u0000"
           elif .ordered then .emit = "\n"
           else .emit = "!\n"
           end
         elif (.parse | not) then .emit = ""
         elif (($event | type) != "array") or (($event | length) == 0) then
           .runtime = false | .emit = ""
         elif ($event[0] | type) == "string" then
           .parse = false | .emit = ""
         elif ($event[0] | type) != "array" then
           .runtime = false | .emit = ""
         elif ($event | length) == 2 then
           ($event[0]) as $path |
           ($event[1]) as $value |
           if .done then .parse = false | .emit = ""
           elif .open_depth == 0 then
             if .started then .parse = false | .emit = ""
             elif ($path | length) == 0 then
               .emit = ($value | tojson) |
               .started = true |
               .done = true
             elif (first_children_valid($path) | not) then
               .runtime = false | .emit = ""
             else
               .emit = open_first_children($path) + ($value | tojson) |
               .last_path = $path |
               .open_depth = ($path | length) |
               .started = true
             end
           else
             .open_depth as $depth |
             if (($path | length) < $depth) or
                ((.last_path | length) < $depth) or
                ($path[0:($depth - 1)] != .last_path[0:($depth - 1)]) then
               .runtime = false | .emit = ""
             else
               ($path[$depth - 1]) as $current |
               (.last_path[$depth - 1]) as $previous |
               ($path[$depth:] | first_children_valid(.)) as $suffix_valid |
               if (component_kind($current) == null) or
                  (component_kind($current) != component_kind($previous)) or
                  (($current | type) == "number" and
                   ($current != ($previous + 1))) or
                  ($suffix_valid | not) then
                 .runtime = false | .emit = ""
               else
                 if (($current | type) == "string") and
                    (($previous < $current) | not) then
                   .ordered = false
                 else . end |
                 .emit = "," +
                   (if ($current | type) == "string" then
                      ($current | tojson) + ":"
                    else ""
                    end) +
                   open_first_children($path[$depth:]) + ($value | tojson) |
                 .last_path = $path |
                 .open_depth = ($path | length)
               end
             end
           end
         elif ($event | length) == 1 then
           ($event[0]) as $path |
           if (.open_depth == 0) or
              (($path | length) != .open_depth) or
              (component_kind($path[-1]) == null) then
             .runtime = false | .emit = ""
           else
             .emit = closer(component_kind($path[-1])) |
             .open_depth -= 1 |
             if .open_depth == 0 then .done = true else . end
           end
         else .runtime = false | .emit = ""
         end;
         .emit)
    ' "$raw_path" 2>/dev/null > "$canonical_path"; then
    :
  else
    portable_core_ingress_error E_RUNTIME
    return 1
  fi
  if "$PORTABLE_CORE_INGRESS_OD" -An -v -t u1 "$canonical_path" 2>/dev/null |
      "$PORTABLE_CORE_INGRESS_AWK" '
        {
          for (i = 1; i <= NF; i++) if (($i + 0) == 0) found = 1
        }
        END { if (found) exit 41 }
      ' >/dev/null 2>/dev/null; then
    pipeline_status=("${PIPESTATUS[@]}")
  else
    pipeline_status=("${PIPESTATUS[@]}")
  fi
  [ "${#pipeline_status[@]}" -eq 2 ] && [ "${pipeline_status[0]}" -eq 0 ] || {
    portable_core_ingress_error E_RUNTIME
    return 1
  }
  marker_status="${pipeline_status[1]}"
  case "$marker_status" in
    0) return 0 ;;
    41) portable_core_ingress_error E_PARSE ;;
    *) portable_core_ingress_error E_RUNTIME ;;
  esac
  return 1
}

portable_core_ingress_finish_driver() {
  local input_index
  local raw_path
  local canonical_path
  local compare_status

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
    portable_core_ingress_scan_raw "$raw_path" || return 1
    PORTABLE_CORE_INGRESS_DEPTH_OVER[input_index]="$PORTABLE_CORE_INGRESS_SCAN_DEPTH_OVER"
    PORTABLE_CORE_INGRESS_STREAM_REQUIRED[input_index]="$PORTABLE_CORE_INGRESS_SCAN_STREAM_REQUIRED"
  done
  for ((input_index = 0; input_index < PORTABLE_CORE_INGRESS_COUNT; input_index++)); do
    raw_path="${PORTABLE_CORE_INGRESS_RAW_PATHS[$input_index]}"
    canonical_path="$PORTABLE_CORE_INGRESS_TEMP/canonical.$((input_index + 1))"
    if [ "${PORTABLE_CORE_INGRESS_STREAM_REQUIRED[$input_index]}" = true ]; then
      portable_core_ingress_stream_canonical "$raw_path" "$canonical_path" || return 1
    else
      portable_core_ingress_tree_canonical "$raw_path" "$canonical_path" || return 1
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
    if [ "${PORTABLE_CORE_INGRESS_DEPTH_OVER[$input_index]}" = true ]; then
      portable_core_ingress_error E_LIMIT
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
