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
  "$jq_bin" -S -c . "$source" > "$output" 2>/dev/null && cmp -s "$source" "$output"
}

[ "$(sha_file "$inventory")" = 1be4e488423d753cf083430aa3560b8dda8d66985b234bce9629b5c0fb1c003a ] ||
  runner_error E_INVENTORY
inventory_canonical="$run_tmp/inventory.canonical"
canonical "$inventory" "$inventory_canonical" || runner_error E_INVENTORY
fixture_source="$fixture_root/target/source.txt"
[ -f "$fixture_source" ] && [ ! -L "$fixture_source" ] || runner_error E_FIXTURE
fixture_sha=$(sha_file "$fixture_source")
[ "$fixture_sha" = ce90e53bb6592130c8d56db2d5cda036c11baba589a5ffb3e2e07e75366c2ef6 ] ||
  runner_error E_FIXTURE
"$jq_bin" -L "$runner_dir" -e --arg command inventory \
  --arg fixture_sha256 "$fixture_sha" --arg package_id '' \
  --arg artifact_sha256 '' --arg target_tree_id '' --arg candidate_tree_id '' \
  -f "$contract" "$inventory" >/dev/null ||
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
  ([.repositories[].repository_id] | length == (unique | length)) and
  ([.repositories[].root] | length == (unique | length)) and
  ([.repositories[] | select(.repository_id == "fixture.target" and .root == ($root+"/target"))] | length) == 1 and
  all(["aa","ab","ba","bb"][];
    . as $cell | all(["assets","manifests","profile"][];
      . as $repo |
      ([$map.repositories[] | select(.repository_id == ($cell+"."+$repo) and
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
    fake.producer.a) printf '%s\n' b141abf12545f39573ee9cd956ba8a80fa3d37c2266929a765b302ab2b832971 ;;
    fake.producer.b) printf '%s\n' 329693fbdea876f595d1deeb4a983a3318ac5938add1206472df18c8d5b57211 ;;
    fake.forge.a) printf '%s\n' df6891340de99bd82ceb2ff684e1d3b76f87aabf3d401aa15ee7306d932efd1a ;;
    fake.forge.b) printf '%s\n' 1da390b4e723a1fb1abe4418c9ef02c5c7d8e886fe38143a61e31e81e89e83ea ;;
    fake.protocol-fault) printf '%s\n' 5a5936a315613960ba5c3760cb851c658c49a0ef030aff744a17da72e81ba199 ;;
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
  local assets=$1
  local package=$2
  local expected_ref=${3:-}
  local relative digest entry meta mode type object
  relative=$(package_path "$package") || return 1
  digest=$(package_digest "$package") || return 1
  [ "$(sha_file "$assets/$relative")" = "$digest" ] || return 1
  entry=$(git_safe -C "$assets" ls-tree HEAD -- "$relative")
  meta=${entry%%$'\t'*}
  read -r mode type object <<< "$meta"
  [ "$mode:$type" = 100755:blob ] &&
    [ "$object" = "$(git_safe -C "$assets" hash-object "$relative")" ] &&
    { [ -z "$expected_ref" ] || [ "$object" = "$expected_ref" ]; }
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
    child_args=("$request" "$jq_bin")
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
  producer_ref=$("$jq_bin" -r '.body.bindings[] | select(.role=="producer") | .package_ref.object_id' "$cell_root/profile/profiles/default.json")
  forge_ref=$("$jq_bin" -r '.body.bindings[] | select(.role=="forge") | .package_ref.object_id' "$cell_root/profile/profiles/default.json")
  if ! verify_package "$assets" "$producer_package" "$producer_ref" ||
     ! verify_package "$assets" "$forge_package" "$forge_ref" ||
     ! verify_package "$assets" fake.protocol-fault; then
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

  producer_request="$run_tmp/$cell.producer.request"
  "$jq_bin" -S -c -n --arg case_id "$cell_id" --arg source "$fixture_sha" \
    '{case_id:$case_id,phase:"producer",protocol:"ystack.fake-adapter.v1",source_sha256:$source}' > "$producer_request"
  producer_output="$run_tmp/$cell.producer.output"
  producer_error="$run_tmp/$cell.producer.stderr"
  run_child "$assets/$producer_path" direct "$producer_request" "$producer_output" \
    "$producer_error" "$run_tmp/$cell.producer.home" || runner_error "$CHILD_ERROR"
  if [ -s "$producer_error" ] ||
     ! canonical "$producer_output" "$run_tmp/$cell.producer.canonical"; then
    runner_error E_PROTOCOL
  fi
  "$jq_bin" -L "$runner_dir" -e --arg command producer-response \
    --arg package_id "$producer_package" --arg fixture_sha256 '' \
    --arg artifact_sha256 '' --arg target_tree_id '' --arg candidate_tree_id '' \
    -f "$contract" "$producer_output" >/dev/null || runner_error E_PROTOCOL
  artifact_content=$("$jq_bin" -r '.artifact.content' "$producer_output")
  artifact_sha=$(sha_text "$artifact_content")
  [ "$artifact_sha" = "$("$jq_bin" -r '.artifact.sha256' "$producer_output")" ] || runner_error E_OBSERVATION

  candidate_root="$run_tmp/$cell.candidate"
  forge_request="$run_tmp/$cell.forge.request"
  "$jq_bin" -S -c -n --arg case_id "$cell_id" --arg root "$candidate_root" \
    --slurpfile response "$producer_output" \
    '{artifact:$response[0].artifact,candidate_root:$root,case_id:$case_id,
      phase:"forge",protocol:"ystack.fake-adapter.v1"}' > "$forge_request"
  forge_output="$run_tmp/$cell.forge.output"
  forge_error="$run_tmp/$cell.forge.stderr"
  run_child "$assets/$forge_path" direct "$forge_request" "$forge_output" \
    "$forge_error" "$run_tmp/$cell.forge.home" || runner_error "$CHILD_ERROR"
  if [ -s "$forge_error" ] ||
     ! canonical "$forge_output" "$run_tmp/$cell.forge.canonical"; then
    runner_error E_PROTOCOL
  fi
  "$jq_bin" -L "$runner_dir" -e --arg command forge-response \
    --arg package_id "$forge_package" --arg fixture_sha256 '' \
    --arg artifact_sha256 '' --arg target_tree_id '' --arg candidate_tree_id '' \
    -f "$contract" "$forge_output" >/dev/null || runner_error E_PROTOCOL
  verify_repo "$candidate_root" || runner_error E_GIT
  candidate_commit=$(git_safe -C "$candidate_root" rev-parse HEAD)
  candidate_tree=$(git_safe -C "$candidate_root" rev-parse 'HEAD^{tree}')
  candidate_object=$(git_safe -C "$candidate_root" rev-parse HEAD:result.txt)
  [ "$(/bin/cat "$candidate_root/result.txt")" = "$artifact_content" ] &&
    [ "$candidate_commit:$candidate_tree:$candidate_object" = \
      "$("$jq_bin" -r '[.commit_id,.tree_id,.file_object_id]|join(":")' "$forge_output")" ] ||
    runner_error E_OBSERVATION
  projection=$("$jq_bin" -L "$runner_dir" -n -c --arg command projection \
    --arg artifact_sha256 "$artifact_sha" --arg target_tree_id "$target_tree" \
    --arg candidate_tree_id "$candidate_tree" --arg package_id '' \
    --arg fixture_sha256 '' -f "$contract")
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
for negative in degraded empty malformed partial relabelled timeout transport; do
  negative_id="reject-$negative"
  negative_request="$run_tmp/$negative.request"
  /usr/bin/printf '%s\n' '{}' > "$negative_request"
  negative_output="$run_tmp/$negative.output"
  negative_stderr="$run_tmp/$negative.stderr"
  observed=''
  if ! run_child "$fault_executable" "$negative" "$negative_request" "$negative_output" \
      "$negative_stderr" "$run_tmp/$negative.home"; then
    observed=$CHILD_ERROR
  elif [ ! -s "$negative_output" ]; then
    observed=E_EMPTY
  elif ! "$jq_bin" -e . "$negative_output" >/dev/null 2>&1; then
    observed=E_MALFORMED
  elif [ "$("$jq_bin" -r '.status // ""' "$negative_output")" = degraded ]; then
    observed=E_DEGRADED
  elif [ "$negative" = relabelled ]; then
    observed=E_RELABELLED
  else
    observed=E_PARTIAL
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
