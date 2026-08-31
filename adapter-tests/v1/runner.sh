#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

runner_error() {
  printf '%s\n' "${1:-E_RUNTIME}" >&2
  exit 1
}

[ "$#" -eq 2 ] || runner_error E_USAGE
inventory=$1
fixture_root=$2
runner_source=${BASH_SOURCE[0]}
case "$runner_source:$inventory:$fixture_root" in /*:/*:/*) ;; *) runner_error E_USAGE ;; esac
runner_dir=${runner_source%/*}
repo_root=$(CDPATH='' cd -P -- "$runner_dir/../.." && pwd -P) || runner_error
contract="$runner_dir/contract.jq"
core="$repo_root/scripts/core-contract.sh"
core_fixture_modules="$repo_root/scripts/test"
for runner_file in "$runner_source" "$contract" "$inventory" "$core"; do
  [ -f "$runner_file" ] && [ ! -L "$runner_file" ] || runner_error E_BINDING
done
jq_bin=$(command -v jq) || runner_error E_DEPENDENCY
[ "$($jq_bin --version 2>/dev/null)" = jq-1.6 ] || runner_error E_DEPENDENCY
fixture_root=$(CDPATH='' cd -P -- "$fixture_root" && pwd -P) || runner_error E_FIXTURE
[ -z "$(find "$fixture_root" -type l -print -quit)" ] || runner_error E_FIXTURE
[ -d "$fixture_root/scratch" ] && [ -d "$fixture_root/target/.git" ] || runner_error E_FIXTURE

run_tmp=$(/usr/bin/mktemp -d "$fixture_root/scratch/run.XXXXXX") || runner_error
cleanup() { /bin/rm -rf -- "$run_tmp"; }
trap cleanup EXIT HUP INT TERM
/bin/mkdir -m 700 "$run_tmp/home"

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_text() { /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
canonical() {
  local source=$1
  local output=$2
  "$jq_bin" -s -e 'length == 1' "$source" >/dev/null 2>&1 &&
    "$jq_bin" -S -c . "$source" > "$output" 2>/dev/null &&
    cmp -s "$source" "$output"
}

[ "$(sha_file "$inventory")" = 73b90745ba3ae879f8d6d958e3133e33fb6169bc89fb9c26a826be1be9fd9fd6 ] ||
  runner_error E_INVENTORY
inventory_canonical="$run_tmp/inventory.canonical"
canonical "$inventory" "$inventory_canonical" || runner_error E_INVENTORY
fixture_source="$fixture_root/target/source.txt"
[ -f "$fixture_source" ] && [ ! -L "$fixture_source" ] || runner_error E_FIXTURE
fixture_sha=$(sha_file "$fixture_source")
[ "$fixture_sha" = ce90e53bb6592130c8d56db2d5cda036c11baba589a5ffb3e2e07e75366c2ef6 ] ||
  runner_error E_FIXTURE
"$jq_bin" -c --slurpfile inventory "$inventory" --arg fixture_sha256 "$fixture_sha" -n \
  '{inventory:$inventory[0],fixture_sha256:$fixture_sha256}' |
  "$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -e \
    --arg command inventory -f "$contract" >/dev/null ||
  runner_error E_INVENTORY

git_safe() {
  /usr/bin/env -i HOME="$run_tmp/home" TMPDIR="$run_tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    /usr/bin/git --no-replace-objects "$@"
}

verify_repo() {
  local root=$1
  [ -d "$root/.git" ] && [ ! -L "$root/.git" ] &&
    [ ! -e "$root/.git/objects/info/alternates" ] &&
    [ "$(git_safe -C "$root" rev-parse --show-toplevel)" = "$root" ] &&
    [ -z "$(git_safe -C "$root" status --porcelain)" ] &&
    ! git_safe -C "$root" config --local --get-regexp \
      '(^remote\.|promisor|partialclone|alternates|insteadOf)' >/dev/null 2>&1
}

mapping="$fixture_root/repository-map.json"
mapping_canonical="$run_tmp/repository-map.canonical"
if [ ! -f "$mapping" ] || [ -L "$mapping" ] ||
   ! canonical "$mapping" "$mapping_canonical"; then
  runner_error E_MAPPING
fi
"$jq_bin" -e --arg root "$fixture_root" '
  . as $map |
  .version == 1 and (.repositories | length) == 13 and
  ([.repositories[] | [.cell_id,.repository_id]] | length == (unique | length)) and
  ([.repositories[].root] | length == (unique | length)) and
  ([.repositories[] | select(.cell_id == "shared" and
    .repository_id == "fixture.target" and .root == ($root+"/target"))] | length) == 1 and
  all(["aa","ab","ba","bb"][];
    . as $cell | all(["assets","manifests","profile"][];
      . as $repo |
      ([$map.repositories[] | select(.cell_id == $cell and
        .repository_id == ("repo."+$repo) and
        .root == ($root+"/cells/"+$cell+"/"+$repo))] | length) == 1))
' "$mapping" >/dev/null || runner_error E_MAPPING

verify_repo "$fixture_root/target" || runner_error E_GIT
target_commit=$(git_safe -C "$fixture_root/target" rev-parse HEAD)
target_tree=$(git_safe -C "$fixture_root/target" rev-parse 'HEAD^{tree}')
target_entry=$(git_safe -C "$fixture_root/target" ls-tree HEAD -- source.txt)
target_meta=${target_entry%%$'\t'*}
read -r target_mode target_type target_object <<< "$target_meta"
[ "$target_mode:$target_type:$target_object" = \
  "100644:blob:$(git_safe -C "$fixture_root/target" hash-object source.txt)" ] ||
  runner_error E_GIT

package_digest() {
  case "$1" in
    fake.producer.a) printf '%s\n' 39ee6f968f4b823530e2b36de31faab71c1dc1d675ab9f72c409fd9bcccf3aa4 ;;
    fake.producer.b) printf '%s\n' 602650c6cf4b161f5b92b273b6944a42fb84eb5946918e9ec13fed9746a20049 ;;
    fake.forge.a) printf '%s\n' 672636d079df76736b3b9160d7a38f67ff83767d7da455458c418c1cb0b539a6 ;;
    fake.forge.b) printf '%s\n' a87a8453b2daf7723a9565bb597531f198c7c891d2b47c7dfef80ffd3dc2096b ;;
    fake.protocol-fault) printf '%s\n' 6daeccbda2b6752415c457967dfad03811837da75d25f38370a400381382de28 ;;
    *) return 1 ;;
  esac
}

package_path() {
  case "$1" in
    fake.producer.a) printf '%s\n' packages/producer-a.sh ;;
    fake.producer.b) printf '%s\n' packages/producer-b.sh ;;
    fake.forge.a) printf '%s\n' packages/forge-a.sh ;;
    fake.forge.b) printf '%s\n' packages/forge-b.sh ;;
    fake.protocol-fault) printf '%s\n' packages/protocol-fault.sh ;;
    *) return 1 ;;
  esac
}

verify_package() {
  local cell=$1
  local package=$2
  local ref=$3
  local relative digest repository_id root algorithm commit entry meta mode type object snapshot
  relative=$(package_path "$package") || return 1
  digest=$(package_digest "$package") || return 1
  "$jq_bin" -e --arg path "$relative" '
    type == "object" and
    (keys | sort) == ["location","mode","object_id","object_type","revision"] and
    (.revision | type == "object" and
      (keys | sort) == ["commit_id","hash_algorithm","repository_id"] and
      .repository_id == "repo.assets" and
      (.hash_algorithm == "sha1" or .hash_algorithm == "sha256") and
      (.commit_id | test("\\A[0-9a-f]{40}([0-9a-f]{24})?\\z"))) and
    .location == {kind:"path",value:$path} and .object_type == "blob" and
    .mode == "100755" and (.object_id | test("\\A[0-9a-f]{40}([0-9a-f]{24})?\\z"))
  ' <<< "$ref" >/dev/null || return 1
  repository_id=$("$jq_bin" -r '.revision.repository_id' <<< "$ref")
  root=$("$jq_bin" -r --arg cell "$cell" --arg id "$repository_id" '
    [.repositories[] | select(.cell_id==$cell and .repository_id==$id)] |
    if length == 1 then .[0].root else "" end
  ' "$mapping")
  [ -n "$root" ] && verify_repo "$root" || return 1
  algorithm=$(git_safe -C "$root" rev-parse --show-object-format)
  [ "$algorithm" = "$("$jq_bin" -r '.revision.hash_algorithm' <<< "$ref")" ] || return 1
  commit=$("$jq_bin" -r '.revision.commit_id' <<< "$ref")
  git_safe -C "$root" cat-file -e "$commit^{commit}" >/dev/null 2>&1 || return 1
  entry=$(git_safe -C "$root" ls-tree "$commit" -- "$relative")
  meta=${entry%%$'\t'*}
  read -r mode type object <<< "$meta"
  [ "$mode" = "$("$jq_bin" -r '.mode' <<< "$ref")" ] &&
    [ "$type" = "$("$jq_bin" -r '.object_type' <<< "$ref")" ] &&
    [ "$object" = "$("$jq_bin" -r '.object_id' <<< "$ref")" ] || return 1
  snapshot="$run_tmp/package.$cell.${package##*.}"
  git_safe -C "$root" cat-file blob "$object" > "$snapshot" || return 1
  [ -f "$root/$relative" ] && [ ! -L "$root/$relative" ] &&
    cmp -s "$snapshot" "$root/$relative" && [ "$(sha_file "$snapshot")" = "$digest" ]
}

CHILD_STATUS=0
CHILD_ERROR=''
run_child() {
  local executable=$1
  local mode=$2
  local request=$3
  local output=$4
  local diagnostic=$5
  local child_home=$6
  local pid tick=0
  CHILD_STATUS=0
  CHILD_ERROR=''
  /bin/mkdir -m 700 "$child_home"
  (
    ulimit -t 2 -f 2048 -n 64
    child_args=("$request" "$jq_bin" "$contract" "$core_fixture_modules")
    [ "$mode" = direct ] || child_args=("$mode" "${child_args[@]}")
    exec /usr/bin/env -i HOME="$child_home" TMPDIR="$child_home" PATH=/usr/bin:/bin \
      LC_ALL=C GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
      GIT_AUTHOR_NAME=fake GIT_AUTHOR_EMAIL=fake@example.invalid \
      GIT_COMMITTER_NAME=fake GIT_COMMITTER_EMAIL=fake@example.invalid \
      GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
      /bin/bash "$executable" "${child_args[@]}"
  ) > "$output" 2> "$diagnostic" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    tick=$((tick + 1))
    if [ "$tick" -ge 20 ]; then
      kill -TERM "$pid" 2>/dev/null || :
      /bin/sleep 0.1
      kill -KILL "$pid" 2>/dev/null || :
      wait "$pid" 2>/dev/null || :
      CHILD_ERROR=E_TIMEOUT
      return 1
    fi
    /bin/sleep 0.05
  done
  wait "$pid" || CHILD_STATUS=$?
  [ "$CHILD_STATUS" -eq 0 ] || { CHILD_ERROR=E_TRANSPORT; return 1; }
  [ "$(wc -c < "$output" | tr -d ' ')" -le 1048576 ] &&
    [ "$(wc -c < "$diagnostic" | tr -d ' ')" -le 4096 ] || {
    CHILD_ERROR=E_LIMIT
    return 1
  }
}

extract_payload() {
  local response=$1
  local payload_id=$2
  local output=$3
  [ "$("$jq_bin" -r --arg id "$payload_id" '[.payloads[] | select(.payload_id==$id)] | length' "$response")" -eq 1 ] ||
    return 1
  "$jq_bin" -j --arg id "$payload_id" '.payloads[] | select(.payload_id==$id) | .data' \
    "$response" > "$output" &&
    [ "$(sha_file "$output")" = \
      "$("$jq_bin" -r --arg id "$payload_id" '.payloads[] | select(.payload_id==$id) | .sha256' "$response")" ]
}

stage_consistent() {
  local request=$1
  local resolved=$2
  local result=$3
  "$jq_bin" -e --slurpfile request "$request" --slurpfile resolved "$resolved" '
    .body.reported_by == .body.execution.performer and
    .body.execution.actual_binding.binding_id == $request[0].body.operation.binding_id and
    .body.execution.actual_binding.role == $request[0].body.operation.role and
    (.body.execution.actual_binding as $actual |
      [$resolved[0].body.bindings[] |
       select(.binding.binding_id==$actual.binding_id and
              .binding.package_ref==$actual.package_ref and
              .binding.principal_id==$actual.principal_id)] | length == 1)
  ' "$result" >/dev/null
}

RESPONSE_ERROR=''
validate_response() {
  local response=$1
  local request=$2
  local resolved=$3
  local case_id=$4
  local phase=$5
  local result_output=$6
  local roots response_context observed_error payload_id payload_index=0
  RESPONSE_ERROR=''
  [ -s "$response" ] || { RESPONSE_ERROR=E_EMPTY; return 1; }
  roots=$("$jq_bin" -s 'length' "$response" 2>/dev/null) || {
    RESPONSE_ERROR=E_MALFORMED
    return 1
  }
  [ "$roots" -eq 1 ] || { RESPONSE_ERROR=E_MULTIPLE; return 1; }
  canonical "$response" "$run_tmp/response.canonical" || {
    RESPONSE_ERROR=E_MALFORMED
    return 1
  }
  response_context="$run_tmp/response-context.json"
  "$jq_bin" -S -c -n --slurpfile response "$response" --arg case_id "$case_id" \
    --arg phase "$phase" '{case_id:$case_id,phase:$phase,response:$response[0]}' > "$response_context"
  observed_error=$("$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -r \
    --arg command response-error -f "$contract" "$response_context") || {
    RESPONSE_ERROR=E_PARTIAL
    return 1
  }
  [ -z "$observed_error" ] || { RESPONSE_ERROR=$observed_error; return 1; }
  "$jq_bin" -S -c '.stage_result' "$response" > "$result_output"
  "$core" validate-stage-run "$request" "$resolved" "$result_output" \
    >/dev/null 2>&1 || { RESPONSE_ERROR=E_CORE; return 1; }
  stage_consistent "$request" "$resolved" "$result_output" || {
    RESPONSE_ERROR=E_PROVENANCE
    return 1
  }
  while IFS= read -r payload_id; do
    extract_payload "$response" "$payload_id" \
      "$run_tmp/accepted-payload.$payload_index" || {
      RESPONSE_ERROR=E_PAYLOAD_DIGEST
      return 1
    }
    payload_index=$((payload_index + 1))
  done < <("$jq_bin" -r '.payloads[].payload_id' "$response")
}

git_write() {
  /usr/bin/env -i HOME="$run_tmp/home" TMPDIR="$run_tmp/home" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 \
    GIT_AUTHOR_NAME=fake GIT_AUTHOR_EMAIL=fake@example.invalid \
    GIT_COMMITTER_NAME=fake GIT_COMMITTER_EMAIL=fake@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects "$@"
}

cells="$run_tmp/cells.ndjson"
negatives="$run_tmp/negatives.ndjson"
: > "$cells"
: > "$negatives"
for cell in aa ab ba bb; do
  cell_id="matrix-$cell"
  cell_root="$fixture_root/cells/$cell"
  assets="$cell_root/assets"
  manifests="$cell_root/manifests"
  profiles="$cell_root/profile"
  resolved="$cell_root/resolved.json"
  for mapped_repo in "$assets" "$manifests" "$profiles"; do
    verify_repo "$mapped_repo" || runner_error E_GIT
  done
  producer_variant=${cell%?}
  forge_variant=${cell#?}
  producer_package="fake.producer.$producer_variant"
  forge_package="fake.forge.$forge_variant"
  producer_path=$(package_path "$producer_package")
  forge_path=$(package_path "$forge_package")
  producer_ref=$("$jq_bin" -c '.body.bindings[] | select(.role=="producer") | .package_ref' "$cell_root/profile/profiles/default.json")
  forge_ref=$("$jq_bin" -c '.body.bindings[] | select(.role=="forge") | .package_ref' "$cell_root/profile/profiles/default.json")
  producer_resolved_ref=$("$jq_bin" -c '.body.bindings[] | select(.binding.role=="producer") | .binding.package_ref' "$resolved")
  forge_resolved_ref=$("$jq_bin" -c '.body.bindings[] | select(.binding.role=="forge") | .binding.package_ref' "$resolved")
  assets_commit=$("$jq_bin" -r '.revision.commit_id' <<< "$forge_ref")
  fault_entry=$(git_safe -C "$assets" ls-tree "$assets_commit" -- packages/protocol-fault.sh 2>/dev/null) ||
    runner_error E_PACKAGE
  fault_meta=${fault_entry%%$'\t'*}
  read -r fault_mode fault_type fault_object <<< "$fault_meta"
  fault_ref=$("$jq_bin" -c --arg path packages/protocol-fault.sh \
    --arg mode "$fault_mode" --arg type "$fault_type" --arg object "$fault_object" \
    '.location={kind:"path",value:$path} | .mode=$mode | .object_type=$type | .object_id=$object' \
    <<< "$forge_ref")
  if [ "$producer_ref" != "$producer_resolved_ref" ] || [ "$forge_ref" != "$forge_resolved_ref" ] ||
     ! verify_package "$cell" "$producer_package" "$producer_ref" ||
     ! verify_package "$cell" "$forge_package" "$forge_ref" ||
     ! verify_package "$cell" fake.protocol-fault "$fault_ref"; then
    runner_error E_PACKAGE
  fi
  profile="$profiles/profiles/default.json"
  manifest_args=()
  for role in forge producer publisher reviewer verifier; do
    manifest_file="$manifests/manifests/$role.json"
    "$core" validate-document "$manifest_file" >/dev/null 2>&1 || runner_error E_CORE
    manifest_args+=("$manifest_file")
  done
  "$core" validate-document "$profile" >/dev/null 2>&1 || runner_error E_CORE
  "$core" validate-profile-set "$profile" "$resolved" "${manifest_args[@]}" \
    >/dev/null 2>&1 || runner_error E_CORE
  "$jq_bin" -e --arg profile "profile.$cell" --arg producer "fake-$producer_variant" \
    --arg forge "fake-$forge_variant" '
    .id == $profile and
    ([.body.bindings[] | select(.role=="producer") | .manifest_ref.id] == ["manifest.producer"])
  ' "$profile" >/dev/null || runner_error E_PROVENANCE
  "$jq_bin" -e --arg producer "fake-$producer_variant" --arg forge "fake-$forge_variant" '
    ([.body.bindings[] | select(.binding.role=="producer") | .adapter_implementation.version] == [$producer]) and
    ([.body.bindings[] | select(.binding.role=="forge") | .adapter_implementation.version] == [$forge])
  ' "$resolved" >/dev/null || runner_error E_PROVENANCE

  resolved_sha=$(sha_file "$resolved")
  resolved_id=$("$jq_bin" -r '.id' "$resolved")
  producer_context="$run_tmp/$cell.producer.context"
  "$jq_bin" -S -c -n --slurpfile resolved_profile "$resolved" \
    --arg case_id "$cell_id" --arg resolved_sha "$resolved_sha" \
    --arg resolved_id "$resolved_id" \
    --arg target_commit "$target_commit" --arg target_tree "$target_tree" \
    --arg target_object "$target_object" \
    '{case_id:$case_id,resolved_sha:$resolved_sha,resolved_id:$resolved_id,
      resolved_profile:$resolved_profile[0],target_commit:$target_commit,
      target_tree:$target_tree,target_object:$target_object}' > "$producer_context"
  producer_stage_request="$run_tmp/$cell.producer.stage-request"
  "$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -S -c \
    --arg command producer-request -f "$contract" "$producer_context" > "$producer_stage_request"
  "$core" validate-document "$producer_stage_request" >/dev/null 2>&1 || runner_error E_CORE_PRODUCER_REQUEST
  producer_request="$run_tmp/$cell.producer.request"
  "$jq_bin" -S -c -n --arg case_id "$cell_id" --slurpfile stage "$producer_stage_request" \
    --rawfile source "$fixture_source" --arg source_sha "$fixture_sha" \
    --rawfile resolved "$resolved" --arg resolved_sha "$resolved_sha" '
    {case_id:$case_id,payloads:[
      {data:$resolved,media_type:"application/json",payload_id:"resolved-profile",sha256:$resolved_sha},
      {data:$source,media_type:"text/plain",payload_id:"source",sha256:$source_sha}],
     phase:"producer",protocol_version:1,stage_request:$stage[0]}' > "$producer_request"
  "$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -e \
    --arg command request-envelope -f "$contract" "$producer_request" >/dev/null || runner_error E_PROTOCOL_PRODUCER_REQUEST
  producer_output="$run_tmp/$cell.producer.output"
  producer_error="$run_tmp/$cell.producer.stderr"
  run_child "$assets/$producer_path" direct "$producer_request" "$producer_output" \
    "$producer_error" "$run_tmp/$cell.producer.home" || runner_error "$CHILD_ERROR"
  producer_result="$run_tmp/$cell.producer.stage-result"
  [ ! -s "$producer_error" ] || runner_error E_PROTOCOL_PRODUCER_OUTPUT
  validate_response "$producer_output" "$producer_stage_request" "$resolved" \
    "$cell_id" producer "$producer_result" || runner_error "$RESPONSE_ERROR"
  producer_patch="$run_tmp/$cell.producer.patch"
  extract_payload "$producer_output" producer.patch "$producer_patch" || runner_error E_OBSERVATION
  patch_sha=$(sha_file "$producer_patch")
  "$jq_bin" -e --arg sha "$patch_sha" '
    .body.outputs == [{output_id:"producer.patch",ref:.body.delta_ref}] and
    .body.delta_ref.media_type == "text/x-diff" and .body.delta_ref.sha256 == $sha
  ' "$producer_result" >/dev/null || runner_error E_OBSERVATION

  forge_context="$run_tmp/$cell.forge.context"
  "$jq_bin" -S -c -n --slurpfile resolved_profile "$resolved" \
    --arg case_id "$cell_id" --arg resolved_sha "$resolved_sha" \
    --arg resolved_id "$resolved_id" \
    --arg target_commit "$target_commit" --arg target_tree "$target_tree" \
    --arg target_object "$target_object" --arg patch_sha "$patch_sha" \
    '{case_id:$case_id,resolved_sha:$resolved_sha,resolved_id:$resolved_id,
      resolved_profile:$resolved_profile[0],target_commit:$target_commit,
      target_tree:$target_tree,target_object:$target_object,patch_sha:$patch_sha}' > "$forge_context"
  forge_stage_request="$run_tmp/$cell.forge.stage-request"
  "$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -S -c \
    --arg command forge-request -f "$contract" "$forge_context" > "$forge_stage_request"
  "$core" validate-document "$forge_stage_request" >/dev/null 2>&1 || runner_error E_CORE_FORGE_REQUEST
  forge_request="$run_tmp/$cell.forge.request"
  "$jq_bin" -S -c -n --arg case_id "$cell_id" --slurpfile stage "$forge_stage_request" \
    --rawfile source "$fixture_source" --arg source_sha "$fixture_sha" \
    --rawfile resolved "$resolved" --arg resolved_sha "$resolved_sha" \
    --rawfile patch "$producer_patch" --arg patch_sha "$patch_sha" '
    {case_id:$case_id,payloads:[
      {data:$resolved,media_type:"application/json",payload_id:"resolved-profile",sha256:$resolved_sha},
      {data:$source,media_type:"text/plain",payload_id:"source",sha256:$source_sha},
      {data:$patch,media_type:"text/x-diff",payload_id:"producer.patch",sha256:$patch_sha}],
     phase:"forge",protocol_version:1,stage_request:$stage[0]}' > "$forge_request"
  "$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -e \
    --arg command request-envelope -f "$contract" "$forge_request" >/dev/null || runner_error E_PROTOCOL_FORGE_REQUEST
  forge_output="$run_tmp/$cell.forge.output"
  forge_error="$run_tmp/$cell.forge.stderr"
  forge_home="$run_tmp/$cell.forge.home"
  run_child "$assets/$forge_path" direct "$forge_request" "$forge_output" \
    "$forge_error" "$forge_home" || runner_error "$CHILD_ERROR"
  forge_result="$run_tmp/$cell.forge.stage-result"
  [ ! -s "$forge_error" ] || runner_error E_PROTOCOL_FORGE_OUTPUT
  validate_response "$forge_output" "$forge_stage_request" "$resolved" \
    "$cell_id" forge "$forge_result" || runner_error "$RESPONSE_ERROR"
  receipt="$run_tmp/$cell.receipt"
  extract_payload "$forge_output" candidate.repository "$receipt" || runner_error E_OBSERVATION
  receipt_sha=$(sha_file "$receipt")
  "$jq_bin" -e --arg sha "$receipt_sha" '
    (.body | has("delta_ref") | not) and .body.outputs == [{
      output_id:"candidate.repository",ref:.body.outputs[0].ref}] and
    .body.outputs[0].ref.media_type == "application/json" and
    .body.outputs[0].ref.sha256 == $sha
  ' "$forge_result" >/dev/null || runner_error E_OBSERVATION
  candidate_root="$forge_home/candidate"
  verify_repo "$candidate_root" || runner_error E_GIT
  candidate_commit=$(git_safe -C "$candidate_root" rev-parse HEAD)
  candidate_tree=$(git_safe -C "$candidate_root" rev-parse 'HEAD^{tree}')
  candidate_object=$(git_safe -C "$candidate_root" rev-parse HEAD:source.txt)
  "$jq_bin" -e --arg source "$target_tree" --arg patch "$patch_sha" \
    --arg commit "$candidate_commit" --arg tree "$candidate_tree" --arg object "$candidate_object" '
    . == {candidate_commit_id:$commit,candidate_object_id:$object,candidate_tree_id:$tree,
          patch_sha256:$patch,source_tree_id:$source}
  ' "$receipt" >/dev/null || runner_error E_OBSERVATION
  oracle="$run_tmp/$cell.oracle"
  /bin/mkdir -m 700 "$oracle"
  git_write init -q "$oracle"
  /bin/cp "$fixture_source" "$oracle/source.txt"
  git_write -C "$oracle" add source.txt
  git_write -C "$oracle" commit -q -m source
  git_write -C "$oracle" apply "$producer_patch"
  git_write -C "$oracle" add source.txt
  git_write -C "$oracle" commit -q -m candidate
  [ "$candidate_tree" = "$(git_safe -C "$oracle" rev-parse 'HEAD^{tree}')" ] || runner_error E_OBSERVATION
  projection_context="$run_tmp/$cell.projection-context"
  "$jq_bin" -S -c -n --slurpfile producer_request "$producer_stage_request" \
    --slurpfile producer_result "$producer_result" --slurpfile forge_request "$forge_stage_request" \
    --slurpfile forge_result "$forge_result" --arg artifact_sha256 "$patch_sha" \
    --arg target_tree "$target_tree" --arg candidate_tree "$candidate_tree" '
    {artifact_sha256:$artifact_sha256,producer_request:$producer_request[0],
     producer_result:$producer_result[0],forge_request:$forge_request[0],
     forge_result:$forge_result[0],target_tree:$target_tree,candidate_tree:$candidate_tree}' > "$projection_context"
  projection=$("$jq_bin" -L "$runner_dir" -L "$core_fixture_modules" -c \
    --arg command projection -f "$contract" "$projection_context")
  "$jq_bin" -S -c -n --arg case_id "$cell_id" --argjson projection "$projection" \
    --arg profile_sha256 "$(sha_file "$profile")" \
    --arg producer "$producer_package" --arg producer_digest "$(package_digest "$producer_package")" \
    --arg forge "$forge_package" --arg forge_digest "$(package_digest "$forge_package")" '
    {assertion_ids:["audit-projection","candidate-git","core-validation","environment-clean",
      "evidence-projection","gate-projection","outcome-projection","risk-projection","target-git"],
     case_id:$case_id,projection:$projection,
     provenance:{profile_sha256:$profile_sha256,
       producer:{package_id:$producer,sha256:$producer_digest},
       forge:{package_id:$forge,sha256:$forge_digest}}}
  ' >> "$cells"
done

fault_executable="$fixture_root/cells/aa/assets/packages/protocol-fault.sh"
negative_request="$run_tmp/aa.producer.request"
negative_stage_request="$run_tmp/aa.producer.stage-request"
negative_resolved="$fixture_root/cells/aa/resolved.json"
for negative in degraded empty malformed partial relabelled timeout transport multiple unlinked duplicate; do
  negative_id="reject-$negative"
  negative_output="$run_tmp/$negative.output"
  negative_stderr="$run_tmp/$negative.stderr"
  negative_result="$run_tmp/$negative.stage-result"
  observed=''
  if ! run_child "$fault_executable" "$negative" "$negative_request" "$negative_output" \
      "$negative_stderr" "$run_tmp/$negative.home"; then
    observed=$CHILD_ERROR
  elif validate_response "$negative_output" "$negative_stage_request" "$negative_resolved" \
      matrix-aa producer "$negative_result"; then
    observed=E_UNEXPECTED_PASS
  else
    observed=$RESPONSE_ERROR
  fi
  expected=$("$jq_bin" -r --arg id "$negative_id" '.cases[] | select(.case_id==$id) | .expected_error' "$inventory")
  [ "$observed" = "$expected" ] || runner_error E_NEGATIVE
  "$jq_bin" -S -c -n --arg case_id "$negative_id" --arg observed_error "$observed" \
    '{assertion_ids:["expected-error"],case_id:$case_id,observed_error:$observed_error}' >> "$negatives"
done

"$jq_bin" -s -e '([.[].projection] | unique | length) == 1 and
  ([.[].provenance.producer.package_id] | unique | length) == 2 and
  ([.[].provenance.forge.package_id] | unique | length) == 2 and
  ([.[].provenance.profile_sha256] | unique | length) == 4' "$cells" >/dev/null ||
  runner_error E_EQUIVALENCE
inventory_sha=$(sha_file "$inventory")
"$jq_bin" -S -c -n --slurpfile cells "$cells" --slurpfile negatives "$negatives" \
  --arg inventory_sha "$inventory_sha" --arg target_commit "$target_commit" \
  --arg target_object "$target_object" '
  {schema_version:1,kind:"adapter_contract_observation",
   inventory_acceptance_ref:{authorization_comment_id:5476938197,sha256:$inventory_sha},
   cells:$cells,negative_observations:$negatives,
   target_facts:{commit_id:$target_commit,source_object_id:$target_object},
   non_claims:["authority","qualification","approval","publish","merge","branch-write",
               "real-adapter-safety","network-isolation","host-isolation","external-target-smoke"]}
'
trap - EXIT HUP INT TERM
cleanup
