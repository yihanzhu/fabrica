#!/bin/bash -p
# shellcheck disable=SC2016

clean_path=/usr/bin:/bin
while IFS= builtin read -r inherited_function; do
  builtin unset -f "$inherited_function" 2>/dev/null || :
done < <(builtin compgen -A function)
while IFS= builtin read -r exported_name; do
  case "$exported_name" in PATH) ;; *) builtin unset "$exported_name" 2>/dev/null || : ;; esac
done < <(builtin compgen -e)
PATH=$clean_path
LC_ALL=C
export PATH LC_ALL

set -euo pipefail

emit_error() {
  printf '%s\n' "${1:-E_RUNTIME}" >&2
  exit 1
}

[ "$#" -eq 8 ] || emit_error E_USAGE
script_path=${BASH_SOURCE[0]}
case "$script_path" in /*) ;; *) emit_error E_USAGE ;; esac
if [ "$1" = materialize ]; then
  exec /usr/bin/env -i PATH="${PATH:-/usr/bin:/bin}" LC_ALL=C \
    /bin/bash "$script_path" __materialize_clean "$2" "$3" "$4" "$5" "$6" "$7" "$8"
fi
[ "$1" = __materialize_clean ] || emit_error E_USAGE
export LC_ALL=C
umask 077
input_path=$2
source_repository_id=$3
source_git_dir=$4
candidate_root=$5
scratch_root=$6
closure_helper=$7
jq_bin=$8

for absolute_path in "$script_path" "$input_path" "$source_git_dir" \
  "$candidate_root" "$scratch_root" "$closure_helper" "$jq_bin"; do
  case "$absolute_path" in /*) ;; *) emit_error E_USAGE ;; esac
done
[ -f "$closure_helper" ] && [ -x "$closure_helper" ] && [ ! -L "$closure_helper" ] ||
  emit_error E_DEPENDENCY
[ "$("$closure_helper" version 2>/dev/null)" = ystack-object-closure-v1 ] ||
  emit_error E_DEPENDENCY
[ -f "$jq_bin" ] && [ -x "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$("$jq_bin" --version 2>/dev/null)" = jq-1.6 ] || emit_error E_DEPENDENCY
[ -f "$script_path" ] && [ ! -L "$script_path" ] || emit_error E_PACKAGE
script_dir=$(CDPATH='' cd -P -- "${script_path%/*}" && pwd -P) || emit_error E_PACKAGE
repo_root=$(CDPATH='' cd -P -- "$script_dir/../../.." && pwd -P) || emit_error E_PACKAGE
protocol="$script_dir/protocol.jq"
core="$repo_root/scripts/core-contract.sh"
registry="$repo_root/core/v2/generation-registry.json"
for required in "$protocol" "$core" "$registry"; do
  [ -f "$required" ] && [ ! -L "$required" ] || emit_error E_PACKAGE
done

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core") ||
  emit_error E_PACKAGE
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || emit_error E_PACKAGE
"$jq_bin" -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$registry" >/dev/null || emit_error E_PACKAGE
modules="$repo_root/core/v2/generations/$generation/modules"
[ -d "$modules" ] && [ ! -L "$modules" ] || emit_error E_PACKAGE

case "$source_repository_id" in
  ''|*[!a-z0-9._:-]* ) emit_error E_REPOSITORY ;;
esac
[ "${#source_repository_id}" -le 128 ] || emit_error E_REPOSITORY

physical_dir() {
  local path=$1 actual
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  actual=$(CDPATH='' cd -P -- "$path" && pwd -P) || return 1
  [ "$actual" = "$path" ]
}

directory_mode() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
    *) /usr/bin/stat -c '%a' "$1" ;;
  esac
}

directory_owner() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%u' "$1" ;;
    *) /usr/bin/stat -c '%u' "$1" ;;
  esac
}

empty_private_dir() {
  physical_dir "$1" &&
    [ "$(directory_mode "$1")" = 700 ] &&
    [ "$(directory_owner "$1")" = "$(id -u)" ] &&
    [ -z "$(find "$1" -mindepth 1 -print -quit)" ]
}

overlaps() {
  if [ "$1" = / ] || [ "$2" = / ]; then
    return 0
  fi
  case "$1/" in "$2/"*) return 0 ;; esac
  case "$2/" in "$1/"*) return 0 ;; esac
  return 1
}

[ -f "$input_path" ] && [ ! -L "$input_path" ] || emit_error E_INPUT
input_bytes=$(/usr/bin/wc -c < "$input_path" | /usr/bin/tr -d ' ') || emit_error E_INPUT
case "$input_bytes" in ''|*[!0-9]*) emit_error E_INPUT ;; esac
[ "${#input_bytes}" -le 7 ] || emit_error E_INPUT
[ "$input_bytes" -le 8388608 ] || emit_error E_INPUT
physical_dir "$source_git_dir" || emit_error E_SOURCE_GIT
empty_private_dir "$candidate_root" || emit_error E_CANDIDATE_ROOT
empty_private_dir "$scratch_root" || emit_error E_SCRATCH_ROOT
if overlaps "$source_git_dir" "$candidate_root" ||
   overlaps "$source_git_dir" "$scratch_root" ||
   overlaps "$candidate_root" "$scratch_root"; then
  emit_error E_BOUNDARY
fi

run_root="$scratch_root/run"
staging_repo="$candidate_root/.staging.git"
final_repo="$candidate_root/repository.git"
success=0
cleanup() {
  if [ -n "${dependency_bin:-}" ]; then
    /bin/chmod 0700 "$dependency_bin" 2>/dev/null || :
  fi
  /bin/rm -rf -- "$run_root" 2>/dev/null || :
  if [ "$success" -ne 1 ]; then
    /bin/rm -rf -- "$staging_repo" "$final_repo" 2>/dev/null || :
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/bin/mkdir -m 700 "$run_root" || emit_error E_SCRATCH_ROOT
/bin/mkdir -m 500 "$run_root/no-hooks" || emit_error E_SCRATCH_ROOT
/bin/mkdir -m 500 "$run_root/empty-template" || emit_error E_SCRATCH_ROOT
dependency_bin="$run_root/dependencies"
/bin/mkdir -m 700 "$dependency_bin" || emit_error E_SCRATCH_ROOT
/bin/cp "$jq_bin" "$dependency_bin/jq" || emit_error E_DEPENDENCY
/bin/chmod 0500 "$dependency_bin/jq" || emit_error E_DEPENDENCY
[ "$("$dependency_bin/jq" --version 2>/dev/null)" = jq-1.6 ] ||
  emit_error E_DEPENDENCY
/bin/chmod 0500 "$dependency_bin" || emit_error E_DEPENDENCY

input_snapshot="$run_root/input.json"
input_copy_ceiling=8388609
if ! /usr/bin/head -c "$input_copy_ceiling" "$input_path" > "$input_snapshot"; then
  emit_error E_INPUT
fi
input_snapshot_bytes=$(/usr/bin/wc -c < "$input_snapshot" | /usr/bin/tr -d ' ') ||
  emit_error E_INPUT
[ "$input_snapshot_bytes" -le 8388608 ] || emit_error E_INPUT
/bin/chmod 0400 "$input_snapshot" || emit_error E_INPUT
input_canonical="$run_root/input.canonical"
"$jq_bin" -S -c . "$input_snapshot" > "$input_canonical" 2>/dev/null || emit_error E_INPUT
/usr/bin/cmp -s "$input_snapshot" "$input_canonical" || emit_error E_INPUT
"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" \
  "$input_snapshot" >/dev/null 2>&1 || emit_error E_CONTRACT

sha_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

snapshot_pair() {
  local selector=$1 output=$2 expected actual
  "$jq_bin" -S -c "$selector.content" "$input_snapshot" > "$output" 2>/dev/null ||
    return 1
  expected=$("$jq_bin" -r "$selector.sha256" "$input_snapshot") || return 1
  actual=$(sha_file "$output") || return 1
  [ "$actual" = "$expected" ]
}

profile_file="$run_root/profile.json"
resolved_file="$run_root/resolved-profile.json"
request_file="$run_root/stage-request.json"
snapshot_pair '.profile' "$profile_file" || emit_error E_DIGEST
snapshot_pair '.resolved_profile' "$resolved_file" || emit_error E_DIGEST
snapshot_pair '.stage_request' "$request_file" || emit_error E_DIGEST
manifest_files=()
manifest_count=$("$jq_bin" '.manifests | length' "$input_snapshot") || emit_error E_INPUT
manifest_index=0
while [ "$manifest_index" -lt "$manifest_count" ]; do
  manifest_file="$run_root/manifest.$manifest_index.json"
  snapshot_pair ".manifests[$manifest_index]" "$manifest_file" || emit_error E_DIGEST
  manifest_files+=("$manifest_file")
  manifest_index=$((manifest_index + 1))
done

core_validate() {
  local validation_id=$1 validation_root receipt_path
  shift
  validation_root="$run_root/core-$validation_id"
  receipt_path="$run_root/core-$validation_id.receipt"
  /bin/mkdir -m 700 "$validation_root" || return 1
  /usr/bin/env -i PATH="$dependency_bin:/usr/bin:/bin" LC_ALL=C \
    "$core" --accounted-validation "$validation_root" 536870912 "$@" \
    3> "$receipt_path" >/dev/null 2>&1
}

core_validate profile validate-profile-set "$profile_file" "$resolved_file" \
  "${manifest_files[@]}" || emit_error E_CORE_PROFILE
core_validate request validate-document "$request_file" || emit_error E_CORE_REQUEST

contract_file="$run_root/materialization-contract.json"
patch_file="$run_root/producer.patch"
"$jq_bin" -j -L "$modules" --arg command contract -f "$protocol" \
  "$input_snapshot" > "$contract_file" 2>/dev/null || emit_error E_CONTRACT
"$jq_bin" -j -L "$modules" --arg command patch -f "$protocol" \
  "$input_snapshot" > "$patch_file" 2>/dev/null || emit_error E_PATCH
contract_sha=$(sha_file "$contract_file")
patch_sha=$(sha_file "$patch_file")
expected_contract_sha=$("$jq_bin" -r '
  .stage_request.content.body.operation.arguments.materialization_contract.input_id as $id |
  .trust_context.verified_payloads[] | select(.input_id == $id) | .sha256
' "$input_snapshot") || emit_error E_DIGEST
expected_patch_sha=$("$jq_bin" -r \
  '.trust_context.verified_payloads[] |
   select(.input_id == "input.producer-patch") | .sha256' \
  "$input_snapshot") || emit_error E_DIGEST
[ "$contract_sha" = "$expected_contract_sha" ] &&
  [ "$patch_sha" = "$expected_patch_sha" ] || emit_error E_DIGEST
contract_canonical="$run_root/materialization-contract.canonical"
"$jq_bin" -S -c . "$contract_file" > "$contract_canonical" 2>/dev/null || emit_error E_CONTRACT
/usr/bin/cmp -s "$contract_file" "$contract_canonical" || emit_error E_CONTRACT

patch_bytes=$(wc -c < "$patch_file" | /usr/bin/tr -d ' ')
max_patch_bytes=$("$jq_bin" -r '.max_patch_bytes' "$contract_file") || emit_error E_CONTRACT
[ "$patch_bytes" -le "$max_patch_bytes" ] || emit_error E_PATCH_LIMIT
patch_without_nul=$(LC_ALL=C /usr/bin/tr -d '\000' < "$patch_file" | wc -c | /usr/bin/tr -d ' ')
[ "$patch_without_nul" = "$patch_bytes" ] || emit_error E_BINARY_PATCH
if /usr/bin/grep -aEq '^(GIT binary patch|Binary files .+ differ)$' "$patch_file"; then
  emit_error E_BINARY_PATCH
fi
if /usr/bin/grep -aEq \
  '^(copy from|copy to|rename from|rename to|similarity index|dissimilarity index) ' \
  "$patch_file"; then
  emit_error E_PATCH
fi

source_commit=$("$jq_bin" -r '.stage_request.content.body.target_revision.value.commit_id' \
  "$input_snapshot") || emit_error E_SOURCE_IDENTITY
source_algorithm=$("$jq_bin" -r '.stage_request.content.body.target_revision.value.hash_algorithm' \
  "$input_snapshot") || emit_error E_SOURCE_IDENTITY
request_repository_id=$("$jq_bin" -r '.stage_request.content.body.target_repository_id' \
  "$input_snapshot") || emit_error E_SOURCE_IDENTITY
source_input_id=$("$jq_bin" -r \
  '.stage_request.content.body.operation.arguments.source_tree_input_id' \
  "$input_snapshot") || emit_error E_SOURCE_IDENTITY
source_tree=$("$jq_bin" -r --arg id "$source_input_id" '
  .stage_request.content.body.inputs[] | select(.input_id == $id) |
  .value.value.value.object_id
' "$input_snapshot") || emit_error E_SOURCE_IDENTITY
[ "$request_repository_id" = "$source_repository_id" ] || emit_error E_SOURCE_IDENTITY

git_env=(/usr/bin/env -i HOME="$run_root" TMPDIR="$run_root" PATH=/usr/bin:/bin LC_ALL=C
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1
  GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath
  GIT_CONFIG_VALUE_0="$run_root/no-hooks")

git_dir() {
  local directory=$1
  shift
  "${git_env[@]}" /usr/bin/git --no-replace-objects --git-dir="$directory" "$@"
}

source_inventory="$run_root/source-filesystem"
source_inventory_byte_limit=8388608
source_inventory_entry_limit=65536
source_inventory_ceiling=$((source_inventory_byte_limit + 1))
if ! /usr/bin/find "$source_git_dir" -mindepth 1 -print0 |
  /usr/bin/head -c "$source_inventory_ceiling" > "$source_inventory"; then
  emit_error E_SOURCE_LIMIT
fi
source_inventory_bytes=$(/usr/bin/wc -c < "$source_inventory" | /usr/bin/tr -d ' ') ||
  emit_error E_SOURCE_LIMIT
[ "$source_inventory_bytes" -le "$source_inventory_byte_limit" ] ||
  emit_error E_SOURCE_LIMIT
source_inventory_entries=0
while IFS= builtin read -r -d '' source_entry; do
  source_inventory_entries=$((source_inventory_entries + 1))
  [ "$source_inventory_entries" -le "$source_inventory_entry_limit" ] ||
    emit_error E_SOURCE_LIMIT
  case "$source_entry" in "$source_git_dir"/*) ;; *) emit_error E_SOURCE_GIT ;; esac
  if [ -L "$source_entry" ] || { [ ! -f "$source_entry" ] && [ ! -d "$source_entry" ]; }; then
    emit_error E_SOURCE_GIT
  fi
done < "$source_inventory"
/bin/rm -f -- "$source_inventory"

source_config_input="$source_git_dir/config"
[ -f "$source_config_input" ] && [ ! -L "$source_config_input" ] ||
  emit_error E_SOURCE_CONFIG
source_config_snapshot="$run_root/source-config.snapshot"
source_config_ceiling=1048577
if ! /usr/bin/head -c "$source_config_ceiling" "$source_config_input" \
  > "$source_config_snapshot"; then
  emit_error E_SOURCE_CONFIG
fi
source_config_bytes=$(/usr/bin/wc -c < "$source_config_snapshot" | /usr/bin/tr -d ' ') ||
  emit_error E_SOURCE_CONFIG
[ "$source_config_bytes" -le 1048576 ] || emit_error E_SOURCE_CONFIG
source_config="$run_root/source-config"
"${git_env[@]}" /usr/bin/git config --file "$source_config_snapshot" \
  --name-only --list --no-includes > "$source_config" 2>/dev/null ||
  emit_error E_SOURCE_CONFIG
while IFS= read -r config_key; do
  case "$config_key" in
    core.repositoryformatversion|core.filemode|core.bare|core.logallrefupdates|core.ignorecase|core.precomposeunicode|extensions.objectformat) ;;
    '') ;;
    *) emit_error E_SOURCE_CONFIG ;;
  esac
done < "$source_config"
[ "$(git_dir "$source_git_dir" rev-parse --is-bare-repository 2>/dev/null)" = true ] ||
  emit_error E_SOURCE_WORKTREE
[ ! -e "$source_git_dir/commondir" ] && [ ! -e "$source_git_dir/shallow" ] &&
  [ -z "$(find "$source_git_dir/worktrees" -mindepth 1 -print -quit 2>/dev/null)" ] &&
  [ ! -e "$source_git_dir/info/grafts" ] &&
  [ ! -e "$source_git_dir/objects/info/alternates" ] &&
  [ ! -d "$source_git_dir/refs/replace" ] &&
  [ -z "$(find "$source_git_dir/objects/pack" -type f -name '*.promisor' -print -quit 2>/dev/null)" ] ||
  emit_error E_SOURCE_GIT
packed_refs="$source_git_dir/packed-refs"
if [ -e "$packed_refs" ]; then
  [ -f "$packed_refs" ] && [ ! -L "$packed_refs" ] || emit_error E_SOURCE_GIT
  packed_refs_snapshot="$run_root/packed-refs"
  if ! /usr/bin/head -c 1048577 "$packed_refs" > "$packed_refs_snapshot"; then
    emit_error E_SOURCE_LIMIT
  fi
  packed_refs_bytes=$(/usr/bin/wc -c < "$packed_refs_snapshot" | /usr/bin/tr -d ' ') ||
    emit_error E_SOURCE_LIMIT
  [ "$packed_refs_bytes" -le 1048576 ] || emit_error E_SOURCE_LIMIT
  if /usr/bin/grep -aEq '^[0-9A-Fa-f]{40} refs/replace/|^[0-9A-Fa-f]{64} refs/replace/' \
      "$packed_refs_snapshot"; then
    emit_error E_SOURCE_GIT
  fi
fi
if find "$source_git_dir/hooks" -type f ! -name '*.sample' -print -quit 2>/dev/null |
   /usr/bin/grep -q .; then
  emit_error E_SOURCE_HOOK
fi
actual_algorithm=$(git_dir "$source_git_dir" rev-parse --show-object-format 2>/dev/null) ||
  emit_error E_SOURCE_GIT
[ "$actual_algorithm" = "$source_algorithm" ] || emit_error E_SOURCE_IDENTITY
source_commit_type=$(git_dir "$source_git_dir" cat-file -t "$source_commit" 2>/dev/null) ||
  emit_error E_SOURCE_IDENTITY
source_commit_size=$(git_dir "$source_git_dir" cat-file -s "$source_commit" 2>/dev/null) ||
  emit_error E_SOURCE_IDENTITY
[ "$source_commit_type" = commit ] && [ "$source_commit_size" -le 1048576 ] ||
  emit_error E_SOURCE_LIMIT
actual_source_tree=$(git_dir "$source_git_dir" rev-parse "$source_commit^{tree}" 2>/dev/null) ||
  emit_error E_SOURCE_IDENTITY
[ "$actual_source_tree" = "$source_tree" ] || emit_error E_SOURCE_IDENTITY

safe_repo_path() {
  local value=$1 component component_count old_ifs
  [ -n "$value" ] || return 1
  [ "${#value}" -le 4096 ] || return 1
  case "$value" in /*|*\\*) return 1 ;; esac
  [[ ! "$value" =~ [[:cntrl:]] ]] || return 1
  case "$value" in *$'\302'[$'\200'-$'\237']*) return 1 ;; esac
  old_ifs=$IFS
  IFS=/
  read -r -a path_components <<< "$value"
  IFS=$old_ifs
  component_count=0
  for component in "${path_components[@]}"; do
    component_count=$((component_count + 1))
    [ "$component_count" -le 64 ] || return 1
    [ -n "$component" ] && [ "$component" != . ] && [ "$component" != .. ] || return 1
    case "$component" in .[gG][iI][tT]) return 1 ;; esac
    case "$component" in *.|*' ') return 1 ;; esac
  done
}

scan_tree() {
  local repository=$1 tree=$2 output=$3 queue current_tree prefix raw_output
  local entry metadata mode type object path full_path empty_tree tree_type tree_bytes
  local raw_bytes entry_count tree_count total_bytes expanded_bytes remaining path_bytes
  local tree_scan_byte_limit tree_scan_entry_limit tree_scan_tree_limit
  tree_scan_byte_limit=16777216
  tree_scan_entry_limit=65536
  tree_scan_tree_limit=1024
  empty_tree=$(git_dir "$repository" hash-object -t tree --stdin </dev/null) || return 1
  queue="$output.queue"
  expanded_bytes=0
  path_bytes=$((${#tree} + 2))
  [ "$path_bytes" -le "$tree_scan_byte_limit" ] || return 1
  printf '%s\t\n' "$tree" > "$queue" || return 1
  expanded_bytes=$path_bytes
  : > "$output" || return 1
  entry_count=0
  tree_count=0
  total_bytes=0
  while IFS=$'\t' read -r current_tree prefix; do
    tree_count=$((tree_count + 1))
    [ "$tree_count" -le "$tree_scan_tree_limit" ] || return 1
    tree_type=$(git_dir "$repository" cat-file -t "$current_tree" 2>/dev/null) || return 1
    tree_bytes=$(git_dir "$repository" cat-file -s "$current_tree" 2>/dev/null) || return 1
    [ "$tree_type" = tree ] || return 1
    case "$tree_bytes" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#tree_bytes}" -le 8 ] && [ "$tree_bytes" -le "$tree_scan_byte_limit" ] || return 1
    [ -z "$prefix" ] || [ "$current_tree" != "$empty_tree" ] || return 1
    remaining=$((tree_scan_byte_limit - total_bytes))
    [ "$tree_bytes" -le "$remaining" ] || return 1
    raw_output="$output.raw"
    if ! git_dir "$repository" ls-tree -z "$current_tree" |
      /usr/bin/head -c "$((remaining + 1))" > "$raw_output"; then
      return 1
    fi
    raw_bytes=$(/usr/bin/wc -c < "$raw_output" | /usr/bin/tr -d ' ') || return 1
    [ "$raw_bytes" -le "$remaining" ] || return 1
    total_bytes=$((total_bytes + raw_bytes))
    /usr/bin/iconv -f UTF-8 -t UTF-8 "$raw_output" >/dev/null 2>&1 || return 1
    while IFS= read -r -d '' entry; do
      entry_count=$((entry_count + 1))
      [ "$entry_count" -le "$tree_scan_entry_limit" ] || return 1
      metadata=${entry%%$'\t'*}
      path=${entry#*$'\t'}
      read -r mode type object <<< "$metadata"
      [ -n "$object" ] || return 1
      full_path=$path
      [ -z "$prefix" ] || full_path="$prefix/$path"
      safe_repo_path "$full_path" || return 1
      case "$mode:$type" in
        100644:blob|100755:blob)
          path_bytes=$((${#full_path} + 1))
          [ "$path_bytes" -le "$((tree_scan_byte_limit - expanded_bytes))" ] || return 1
          printf '%s\n' "$full_path" >> "$output" || return 1
          expanded_bytes=$((expanded_bytes + path_bytes))
          ;;
        040000:tree)
          path_bytes=$((${#object} + ${#full_path} + 2))
          [ "$path_bytes" -le "$((tree_scan_byte_limit - expanded_bytes))" ] || return 1
          printf '%s\t%s\n' "$object" "$full_path" >> "$queue" || return 1
          expanded_bytes=$((expanded_bytes + path_bytes))
          ;;
        *) return 1 ;;
      esac
    done < "$raw_output"
  done < "$queue"
  /bin/rm -f -- "$queue" "$raw_output" || return 1
  return 0
}

source_paths="$run_root/source-paths"
scan_tree "$source_git_dir" "$source_tree" "$source_paths" || emit_error E_SOURCE_TREE
/bin/rm -f -- "$source_paths"

empty_template="$run_root/empty-template"
source_import_byte_limit=268435456
source_objects="$run_root/source.objects"
"${git_env[@]}" "$closure_helper" walk "$source_git_dir" \
  "$source_algorithm" "$source_commit" "$source_objects" 2>/dev/null ||
  emit_error E_SOURCE_LIMIT

max_changed=$("$jq_bin" -r '.max_changed_paths' "$contract_file") || emit_error E_CONTRACT
patch_paths="$run_root/patch-paths"
: > "$patch_paths"
if [ "$patch_bytes" -gt 0 ]; then
  patch_numstat="$run_root/patch-numstat"
  git_dir "$source_git_dir" apply --numstat -z --whitespace=nowarn \
    "$patch_file" > "$patch_numstat" 2>/dev/null || emit_error E_PATCH
  exec 4< "$patch_numstat"
  while IFS= builtin read -r -d '' patch_record <&4; do
    case "$patch_record" in *$'\t'*$'\t'*) ;; *) emit_error E_PATCH ;; esac
    patch_stat_tail=${patch_record#*$'\t'}
    patch_stat_tail=${patch_stat_tail#*$'\t'}
    if [ -n "$patch_stat_tail" ]; then
      safe_repo_path "$patch_stat_tail" || emit_error E_PATCH_PATH
      printf '%s\n' "$patch_stat_tail" >> "$patch_paths"
    else
      IFS= builtin read -r -d '' patch_old_path <&4 || emit_error E_PATCH
      IFS= builtin read -r -d '' patch_new_path <&4 || emit_error E_PATCH
      if ! safe_repo_path "$patch_old_path" || ! safe_repo_path "$patch_new_path"; then
        emit_error E_PATCH_PATH
      fi
      printf '%s\n%s\n' "$patch_old_path" "$patch_new_path" >> "$patch_paths"
    fi
  done
  exec 4<&-
fi
LC_ALL=C /usr/bin/sort -u "$patch_paths" -o "$patch_paths"
patch_path_count=$(/usr/bin/wc -l < "$patch_paths" | /usr/bin/tr -d ' ')
[ "$patch_path_count" -le "$max_changed" ] || emit_error E_PATCH_LIMIT
candidate_mutation_byte_limit=268435456
candidate_source_bytes=0
while IFS= read -r patch_path; do
  "$jq_bin" -e --arg path "$patch_path" '.allowed_paths | index($path) != null' \
    "$contract_file" >/dev/null || emit_error E_PATCH_SCOPE
  source_path_bytes=0
  if source_path_object=$(git_dir "$source_git_dir" rev-parse --verify \
      "$source_tree:$patch_path" 2>/dev/null); then
    source_path_type=$(git_dir "$source_git_dir" cat-file -t \
      "$source_path_object" 2>/dev/null) || emit_error E_SOURCE_GIT
    case "$source_path_type" in
      blob)
        source_path_bytes=$(git_dir "$source_git_dir" cat-file -s \
          "$source_path_object" 2>/dev/null) || emit_error E_SOURCE_GIT
        ;;
      tree) source_path_bytes=0 ;;
      *) emit_error E_PATCH_PATH ;;
    esac
  fi
  case "$source_path_bytes" in ''|*[!0-9]*) emit_error E_SOURCE_GIT ;; esac
  [ "${#source_path_bytes}" -le 9 ] &&
    [ "$source_path_bytes" -le "$candidate_mutation_byte_limit" ] &&
    [ "$candidate_source_bytes" -le "$((candidate_mutation_byte_limit - source_path_bytes))" ] ||
    emit_error E_CANDIDATE_LIMIT
  candidate_source_bytes=$((candidate_source_bytes + source_path_bytes))
done < "$patch_paths"
[ "$patch_bytes" -le "$((candidate_mutation_byte_limit - candidate_source_bytes))" ] ||
  emit_error E_CANDIDATE_LIMIT

"${git_env[@]}" /usr/bin/git init --template="$empty_template" --bare \
  --object-format="$source_algorithm" \
  "$staging_repo" >/dev/null 2>&1 || emit_error E_CANDIDATE_GIT
source_pack="$run_root/source.pack"
source_pack_ceiling=$((source_import_byte_limit + 1))
if ! git_dir "$source_git_dir" pack-objects --quiet --stdout < "$source_objects" |
  /usr/bin/head -c "$source_pack_ceiling" > "$source_pack"; then
  emit_error E_SOURCE_LIMIT
fi
source_pack_bytes=$(/usr/bin/wc -c < "$source_pack" | /usr/bin/tr -d ' ') ||
  emit_error E_SOURCE_LIMIT
[ "$source_pack_bytes" -le "$source_import_byte_limit" ] || emit_error E_SOURCE_LIMIT
git_dir "$staging_repo" index-pack --stdin --fix-thin < "$source_pack" >/dev/null 2>&1 ||
  emit_error E_CANDIDATE_GIT
/bin/rm -f -- "$source_pack"
git_dir "$staging_repo" cat-file -e "$source_commit^{commit}" >/dev/null 2>&1 ||
  emit_error E_CANDIDATE_GIT

index_file="$run_root/index"
GIT_INDEX_FILE="$index_file" git_dir "$staging_repo" read-tree "$source_tree" ||
  emit_error E_CANDIDATE_GIT
if [ "$patch_bytes" -gt 0 ]; then
  GIT_INDEX_FILE="$index_file" git_dir "$staging_repo" apply --cached --check \
    --whitespace=nowarn "$patch_file" >/dev/null 2>&1 || emit_error E_PATCH
  GIT_INDEX_FILE="$index_file" git_dir "$staging_repo" apply --cached \
    --whitespace=nowarn "$patch_file" >/dev/null 2>&1 || emit_error E_PATCH
fi
candidate_tree=$(GIT_INDEX_FILE="$index_file" git_dir "$staging_repo" write-tree 2>/dev/null) ||
  emit_error E_CANDIDATE_GIT
candidate_paths="$run_root/candidate-paths"
scan_tree "$staging_repo" "$candidate_tree" "$candidate_paths" || emit_error E_CANDIDATE_TREE
/bin/rm -f -- "$candidate_paths"

changed_paths="$run_root/changed-paths"
changed_paths_raw="$run_root/changed-paths.raw"
changed_paths_byte_limit=2097152
changed_paths_ceiling=$((changed_paths_byte_limit + 1))
if ! git_dir "$staging_repo" diff-tree -r --name-only -z \
  "$source_tree" "$candidate_tree" |
  /usr/bin/head -c "$changed_paths_ceiling" > "$changed_paths_raw"; then
  emit_error E_CANDIDATE_GIT
fi
changed_paths_bytes=$(/usr/bin/wc -c < "$changed_paths_raw" | /usr/bin/tr -d ' ') ||
  emit_error E_CANDIDATE_GIT
[ "$changed_paths_bytes" -le "$changed_paths_byte_limit" ] || emit_error E_PATCH_LIMIT
: > "$changed_paths"
while IFS= read -r -d '' changed_path; do
  safe_repo_path "$changed_path" || emit_error E_PATCH_PATH
  printf '%s\n' "$changed_path" >> "$changed_paths"
done < "$changed_paths_raw"
LC_ALL=C /usr/bin/sort -u "$changed_paths" -o "$changed_paths"
changed_count=$(wc -l < "$changed_paths" | /usr/bin/tr -d ' ')
[ "$changed_count" -le "$max_changed" ] || emit_error E_PATCH_LIMIT
while IFS= read -r changed_path; do
  "$jq_bin" -e --arg path "$changed_path" '.allowed_paths | index($path) != null' \
    "$contract_file" >/dev/null || emit_error E_PATCH_SCOPE
done < "$changed_paths"
changed_paths_json="$run_root/changed-paths.json"
"$jq_bin" -Rsc 'split("\n") | map(select(length > 0))' "$changed_paths" |
  "$jq_bin" -S -c . > "$changed_paths_json" || emit_error E_RUNTIME
changed_paths_sha=$(sha_file "$changed_paths_json")

if [ "$candidate_tree" = "$source_tree" ]; then
  candidate_commit=$source_commit
else
  commit_time=2000-01-01T00:00:00Z
  candidate_commit=$(printf '%s\n' 'ystack local candidate' |
    "${git_env[@]}" GIT_AUTHOR_NAME='ystack local materializer' \
    GIT_AUTHOR_EMAIL='materializer@example.invalid' \
    GIT_COMMITTER_NAME='ystack local materializer' \
    GIT_COMMITTER_EMAIL='materializer@example.invalid' GIT_AUTHOR_DATE="$commit_time" \
    GIT_COMMITTER_DATE="$commit_time" /usr/bin/git --no-replace-objects \
    --git-dir="$staging_repo" commit-tree "$candidate_tree" -p "$source_commit") ||
    emit_error E_CANDIDATE_GIT
fi
git_dir "$staging_repo" update-ref refs/heads/candidate "$candidate_commit" ||
  emit_error E_CANDIDATE_GIT
[ "$(git_dir "$staging_repo" rev-parse "$candidate_commit^{tree}" 2>/dev/null)" = "$candidate_tree" ] &&
  { [ "$candidate_commit" = "$source_commit" ] ||
    [ "$(git_dir "$staging_repo" rev-parse "$candidate_commit^" 2>/dev/null)" = "$source_commit" ]; } &&
  [ "$(git_dir "$staging_repo" rev-parse --is-bare-repository 2>/dev/null)" = true ] ||
  emit_error E_CANDIDATE_GIT
git_dir "$staging_repo" fsck --strict --no-progress >/dev/null 2>&1 || emit_error E_CANDIDATE_GIT

receipt_file="$run_root/receipt.json"
"$jq_bin" -S -c -L "$modules" --arg command receipt \
  --arg source_repository_id "$source_repository_id" \
  --arg source_hash_algorithm "$source_algorithm" --arg source_commit "$source_commit" \
  --arg source_tree "$source_tree" --arg candidate_commit "$candidate_commit" \
  --arg candidate_tree "$candidate_tree" --arg changed_path_count "$changed_count" \
  --arg changed_paths_sha256 "$changed_paths_sha" -f "$protocol" "$input_snapshot" \
  > "$receipt_file" 2>/dev/null || emit_error E_RECEIPT
receipt_sha=$(sha_file "$receipt_file")
outcome=changed
[ "$candidate_tree" != "$source_tree" ] || outcome=no-change
verified_receipt="$run_root/verified-receipt.json"
"$jq_bin" -S -c -n --slurpfile receipt "$receipt_file" --arg sha "$receipt_sha" \
  '{content:$receipt[0],sha256:$sha}' > "$verified_receipt" 2>/dev/null || emit_error E_RESULT
result_file="$run_root/stage-result.json"
"$jq_bin" -S -c -L "$modules" --arg command stage-result \
  --arg receipt_json "$(<"$receipt_file")" \
  --arg verified_receipt_json "$(<"$verified_receipt")" --arg outcome "$outcome" \
  -f "$protocol" "$input_snapshot" > "$result_file" 2>/dev/null || emit_error E_RESULT
core_validate result validate-stage-run "$request_file" "$resolved_file" \
  "$result_file" || emit_error E_CORE_RESULT

/bin/mv "$staging_repo" "$final_repo" || emit_error E_CANDIDATE_ROOT
response_file="$run_root/response.json"
"$jq_bin" -S -c -n --slurpfile result "$result_file" --rawfile receipt "$receipt_file" \
  --arg receipt_sha "$receipt_sha" '
  {
    schema_version:1,
    kind:"local_git_materialization_response",
    stage_result:$result[0],
    payloads:[{
      content_id:"candidate.materialization.receipt",
      media_type:"application/json",
      sha256:$receipt_sha,
      data:$receipt
    }],
    authority:"none",
    qualification:{state:"unavailable",reason_id:"adapter.unqualified"},
    effects:["caller-disposable-candidate-repository"]
  }
' > "$response_file" || emit_error E_RESULT
/bin/cat "$response_file" || emit_error E_RESULT
success=1
