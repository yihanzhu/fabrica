#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
adapter="$root/adapters/local-git-materializer/v1/materialize.sh"
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
test_tmp_base=${TMPDIR:-/tmp}
tmp=$(/usr/bin/mktemp -d "${test_tmp_base%/}/ystack-local-materializer.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  Darwin:x86_64|Darwin:arm64) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  *) printf 'FAIL: unsupported host %s\n' "$platform" >&2; exit 1 ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$jq_sha" ] || {
  printf '%s\n' 'FAIL: pinned jq 1.6 is required' >&2
  exit 1
}
jq_cmd=("$jq_bin")
[ "$platform" != Darwin:arm64 ] || jq_cmd=(/usr/bin/arch -x86_64 "$jq_bin")
[ "$("${jq_cmd[@]}" --version)" = jq-1.6 ] || exit 1
runtime_bin="$tmp/bin"
/bin/mkdir -m 700 "$runtime_bin"
if [ "$platform" = Darwin:arm64 ]; then
  printf '%s\n' '#!/bin/bash' "exec /usr/bin/arch -x86_64 '$jq_bin' \"\$@\"" > "$runtime_bin/jq"
else
  /bin/cp "$jq_bin" "$runtime_bin/jq"
fi
/bin/chmod 0555 "$runtime_bin/jq"
export PATH="$runtime_bin:/usr/bin:/bin"
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
  "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || exit 1
"${jq_cmd[@]}" -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$root/core/v2/generation-registry.json" >/dev/null || exit 1
modules="$root/core/v2/generations/$generation/modules"
core="$root/scripts/core-contract.sh"

passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

git_clean() {
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 \
    /usr/bin/git --no-replace-objects "$@"
}

make_bare_source() {
  local destination=$1 format=$2 mode=${3:-100644} source_blob tree commit
  /bin/mkdir -m 700 "$destination"
  git_clean init -q --bare --object-format="$format" "$destination"
  source_blob=$(printf '%s\n' 'alpha' 'beta' | git_clean --git-dir="$destination" hash-object -w --stdin)
  tree=$(printf '%s blob %s\tsource.txt\n' "$mode" "$source_blob" |
    git_clean --git-dir="$destination" mktree)
  commit=$(printf '%s\n' source |
    /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
      GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
      GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
      GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
      /usr/bin/git --no-replace-objects --git-dir="$destination" commit-tree "$tree")
  git_clean --git-dir="$destination" update-ref refs/heads/main "$commit"
  printf '%s %s\n' "$commit" "$tree"
}

/bin/mkdir -m 700 "$tmp/home"
read -r source_commit source_tree < <(make_bare_source "$tmp/source.git" sha1)
source_fingerprint=$(find "$tmp/source.git" -type f -print0 | LC_ALL=C sort -z |
  xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')

contract_file="$tmp/contract.json"
"${jq_cmd[@]}" -S -c -n '{
  schema_version:1,kind:"local_git_materialization_contract",
  allowed_paths:["source.txt"],max_patch_bytes:65536,max_changed_paths:1,
  allowed_modes:["100644","100755"],allow_binary_patch:false,
  allow_symlinks:false,allow_submodules:false,candidate_repository_kind:"bare"
}' > "$contract_file"
patch_file="$tmp/change.patch"
printf '%s\n' \
  'diff --git a/source.txt b/source.txt' \
  '--- a/source.txt' \
  '+++ b/source.txt' \
  '@@ -1,2 +1,3 @@' \
  ' alpha' \
  ' beta' \
  '+gamma' > "$patch_file"
contract_sha=$(sha_file "$contract_file")
patch_sha=$(sha_file "$patch_file")

manifest_dir="$tmp/manifests"
/bin/mkdir -m 700 "$manifest_dir"
forge_manifest="$manifest_dir/forge.json"
"${jq_cmd[@]}" -L "$root/scripts/test" -S -c -n '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  {
    schema_version:2,kind:"adapter_manifest",id:"adapter.local-git-materializer.v1",
    body:{adapter_version:"v1",package_ref:(f::blob("adapters/local-git-materializer/v1";"6") |
      .location={kind:"root"} | .object_type="tree" | .mode="040000"),
      offered_roles:["forge"],offered_execution_kinds:["deterministic"],
      offered_capabilities:["core.forge.materialize-candidate.v2"],
      offered_permissions:["core.perm.candidate-repository.write.v2",
        "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
        "core.perm.target.read.v1"],offered_tools:[]}}
  | v2
' > "$forge_manifest"
for role in producer publisher reviewer verifier; do
  "${jq_cmd[@]}" -L "$root/scripts/test" -S -c -n --arg role "$role" '
    import "portable-core-profile-graph-fixtures" as f;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    f::manifest($role) | v2
  ' > "$manifest_dir/$role.json"
done
manifest_shas=$(
  "${jq_cmd[@]}" -S -c -n \
    --arg forge "$(sha_file "$forge_manifest")" \
    --arg producer "$(sha_file "$manifest_dir/producer.json")" \
    --arg publisher "$(sha_file "$manifest_dir/publisher.json")" \
    --arg reviewer "$(sha_file "$manifest_dir/reviewer.json")" \
    --arg verifier "$(sha_file "$manifest_dir/verifier.json")" \
    '{forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}'
)

profile_file="$tmp/profile.json"
"${jq_cmd[@]}" -L "$root/scripts/test" -S -c -n --argjson shas "$manifest_shas" \
  --slurpfile forge "$forge_manifest" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def forge_binding: {
    binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:$forge[0].id,sha256:$shas.forge},
    execution_kind:"deterministic",adapter_instance_id:"instance.forge",
    principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
    authority_ref:f::scope("authority";"authority-forge";f::sha("5")),
    package_ref:$forge[0].body.package_ref,skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
      "core.perm.target.read.v1"]};
  f::profile_doc($shas) | v2 |
  .body.bindings += [forge_binding] | .body.bindings |= sort_by(.binding_id)
' > "$profile_file"
profile_sha=$(sha_file "$profile_file")

resolved_file="$tmp/resolved.json"
"${jq_cmd[@]}" -L "$root/scripts/test" -S -c -n --argjson shas "$manifest_shas" \
  --slurpfile profile "$profile_file" --slurpfile forge "$forge_manifest" \
  --arg profile_sha "$profile_sha" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::resolved_profile_doc($profile[0];$profile_sha;$shas) | v2 |
  .body.bindings |= map(if .binding.role=="forge" then
    .adapter_implementation={id:$forge[0].id,version:"v1"} |
    .manifest_source=f::source_value(f::blob("manifests/forge.json";"a");"canonical-json";$shas.forge) |
    .package_source=f::source_value($forge[0].body.package_ref;"raw-bytes";f::sha("6")) |
    .config_source={state:"absent"} | .prompt_source={state:"absent"} |
    .skill_sources=[] | .tool_sources=[]
  else . end)
' > "$resolved_file"
resolved_sha=$(sha_file "$resolved_file")

request_file="$tmp/request.json"
"${jq_cmd[@]}" -L "$root/scripts/test" -S -c -n \
  --arg resolved_sha "$resolved_sha" --arg source_commit "$source_commit" \
  --arg source_tree "$source_tree" --arg contract_sha "$contract_sha" \
  --arg patch_sha "$patch_sha" '
  import "portable-core-stage-request-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def revision: {repository_id:"fixture.target",hash_algorithm:"sha1",commit_id:$source_commit};
  def content($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def named($id;$ref): {input_id:$id,value:{type:"artifact",value:{type:"content",value:$ref}}};
  f::request_doc("producer";$resolved_sha) | v2 |
  .id="request.local-git-materializer" | .body.stage_id="stage.materialize" |
  .body.target_repository_id="fixture.target" |
  .body.target_revision={state:"present",value:revision} |
  .body.source={state:"present",value:{type:"git-object",value:{revision:revision,
    location:{kind:"root"},object_type:"tree",object_id:$source_tree,mode:"040000"}}} |
  .body.base={state:"present",value:revision} |
  .body.inputs=([
    f::named_content_input("finish";f::sha("1")),
    named("input.materialize";content("payload-materialize";"application/json";$contract_sha)),
    named("input.producer-patch";content("producer.patch";"text/x-diff";$patch_sha)),
    {input_id:"input.source-tree",value:{type:"artifact",value:{type:"git-object",value:{
      revision:revision,location:{kind:"root"},object_type:"tree",object_id:$source_tree,mode:"040000"}}}},
    f::named_content_input("verify";f::sha("2"))] | sort_by(.input_id)) |
  .body.operation={role:"forge",binding_id:"binding.forge",
    capability_id:"core.forge.materialize-candidate.v2",
    permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1","core.perm.target.read.v1"],
    arguments:{source_tree_input_id:"input.source-tree",candidate_output_id:"candidate.repository",
      materialization_contract:{ref:(f::scope("output-contract";"materialize";f::sha("3")) |
        .subject_ref.value.value=content("payload-materialize";"application/json";$contract_sha)),
        input_id:"input.materialize"},network_mode:"deny"}} |
  .body.required_evidence_kinds=["deterministic"]
' > "$request_file"
request_sha=$(sha_file "$request_file")

input_file="$tmp/input.json"
"${jq_cmd[@]}" -S -c -n --slurpfile profile "$profile_file" \
  --slurpfile resolved "$resolved_file" --slurpfile request "$request_file" \
  --slurpfile forge "$forge_manifest" --slurpfile producer "$manifest_dir/producer.json" \
  --slurpfile publisher "$manifest_dir/publisher.json" --slurpfile reviewer "$manifest_dir/reviewer.json" \
  --slurpfile verifier "$manifest_dir/verifier.json" --rawfile contract "$contract_file" \
  --rawfile patch "$patch_file" --argjson shas "$manifest_shas" \
  --arg profile_sha "$profile_sha" --arg resolved_sha "$resolved_sha" --arg request_sha "$request_sha" \
  --arg contract_sha "$contract_sha" --arg patch_sha "$patch_sha" '
  {schema_version:1,kind:"local_git_materialization_input",
   attempt:{attempt_id:"attempt.materialize",attempt_number:1,result_id:"result.materialize",
     started_at:"2026-08-30T00:00:01Z",finished_at:"2026-08-30T00:00:02Z",
     recorded_at:"2026-08-30T00:00:03Z"},
   profile:{content:$profile[0],sha256:$profile_sha},
   resolved_profile:{content:$resolved[0],sha256:$resolved_sha},
   manifests:([
     {content:$forge[0],sha256:$shas.forge},
     {content:$producer[0],sha256:$shas.producer},
     {content:$publisher[0],sha256:$shas.publisher},
     {content:$reviewer[0],sha256:$shas.reviewer},
     {content:$verifier[0],sha256:$shas.verifier}] | sort_by(.content.id)),
   stage_request:{content:$request[0],sha256:$request_sha},
   payloads:([
     {input_id:"input.materialize",media_type:"application/json",data:$contract},
     {input_id:"input.producer-patch",media_type:"text/x-diff",data:$patch}]
     | sort_by(.input_id)),
   trust_context:{verified_payloads:([
     {input_id:"input.materialize",content:{media_type:"application/json",data:$contract},
      sha256:$contract_sha},
     {input_id:"input.producer-patch",content:{media_type:"text/x-diff",data:$patch},
      sha256:$patch_sha}]
     | sort_by(.input_id))}}
' > "$input_file"

for document in "$profile_file" "$resolved_file" "$forge_manifest" \
  "$manifest_dir/producer.json" "$manifest_dir/publisher.json" \
  "$manifest_dir/reviewer.json" "$manifest_dir/verifier.json"; do
  "$core" validate-document "$document" || fail "core-document-${document##*/}"
done
"$core" validate-profile-set "$profile_file" "$resolved_file" \
  "$forge_manifest" "$manifest_dir/producer.json" "$manifest_dir/publisher.json" \
  "$manifest_dir/reviewer.json" "$manifest_dir/verifier.json" || fail core-profile-fixture
"$core" validate-document "$request_file" || fail core-request-fixture
"${jq_cmd[@]}" -L "$modules" -e --arg command validate-input -f "$protocol" \
  "$input_file" >/dev/null || fail protocol-fixture
pass 'core v2 input fixture validates'

run_case() {
  local name=$1 input=${2:-$input_file} source=${3:-$tmp/source.git}
  local case_root="$tmp/case-$name"
  local candidate="$case_root/candidate" scratch="$case_root/scratch"
  /bin/mkdir -m 700 "$case_root" "$candidate" "$scratch"
  PATH="$runtime_bin:/usr/bin:/bin" GH_TOKEN=must-not-read GITHUB_TOKEN=must-not-read \
    AWS_SECRET_ACCESS_KEY=must-not-read SSH_AUTH_SOCK=/must/not/read \
    "$adapter" materialize "$input" fixture.target "$source" "$candidate" "$scratch" \
    > "$case_root/out" 2> "$case_root/err"
  printf '%s\n' "$case_root"
}

case_root=$(run_case success)
[ ! -s "$case_root/err" ] || fail success-stderr
"${jq_cmd[@]}" -e '
  .schema_version==1 and .kind=="local_git_materialization_response" and
  .authority=="none" and .qualification=={state:"unavailable",reason_id:"adapter.unqualified"} and
  .effects==["caller-disposable-candidate-repository"] and
  .stage_result.body.status=="completed" and .stage_result.body.outcome=={family:"change",value:"changed"} and
  .stage_result.body.outputs[0].output_id=="candidate.repository" and
  .payloads[0].content_id=="candidate.materialization.receipt"
' "$case_root/out" >/dev/null || fail success-response
receipt_file="$case_root/receipt"
"${jq_cmd[@]}" -j '.payloads[0].data' "$case_root/out" > "$receipt_file"
[ "$(sha_file "$receipt_file")" = "$("${jq_cmd[@]}" -r '.payloads[0].sha256' "$case_root/out")" ] ||
  fail receipt-digest
if /usr/bin/grep -Fq "$tmp" "$receipt_file" ||
   /usr/bin/grep -Eq 'must-not-read|GH_TOKEN|GITHUB_TOKEN|AWS_SECRET_ACCESS_KEY|SSH_AUTH_SOCK' \
     "$case_root/out"; then
  fail receipt-leaked-local-or-credential-data
fi
candidate_repo="$case_root/candidate/repository.git"
[ "$(git_clean --git-dir="$candidate_repo" rev-parse --is-bare-repository)" = true ] || fail bare
candidate_commit=$(git_clean --git-dir="$candidate_repo" rev-parse refs/heads/candidate)
[ "$(git_clean --git-dir="$candidate_repo" rev-parse "$candidate_commit^")" = "$source_commit" ] || fail parent
git_clean --git-dir="$candidate_repo" show "$candidate_commit:source.txt" |
  /usr/bin/grep -Fxq gamma || fail patch-content
[ -z "$(find "$case_root/scratch" -mindepth 1 -print -quit)" ] || fail scratch-clean
[ "$source_fingerprint" = "$(find "$tmp/source.git" -type f -print0 | LC_ALL=C sort -z |
  xargs -0 /usr/bin/shasum -a 256 | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" ] ||
  fail source-mutated
"${jq_cmd[@]}" -S -c '.stage_result' "$case_root/out" > "$case_root/result.json"
"$core" validate-stage-run "$request_file" "$resolved_file" "$case_root/result.json" || fail stage-result
pass 'materializes deterministic bare child and validates stage result'

repeat_root=$(run_case repeat)
/usr/bin/cmp -s "$case_root/out" "$repeat_root/out" || fail deterministic-response
pass 'same exact input produces the same receipt and commit'

expect_error() {
  local name=$1 expected=$2 input=${3:-$input_file} source=${4:-$tmp/source.git}
  local case_root="$tmp/error-$name"
  local candidate="$case_root/candidate" scratch="$case_root/scratch"
  /bin/mkdir -m 700 "$case_root" "$candidate" "$scratch"
  if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input" fixture.target \
      "$source" "$candidate" "$scratch" > "$case_root/out" 2> "$case_root/err"; then
    fail "$name accepted"
  fi
  [ ! -s "$case_root/out" ] && [ "$(cat "$case_root/err")" = "$expected" ] || fail "$name error"
  [ -z "$(find "$candidate" -mindepth 1 -print -quit)" ] || fail "$name candidate cleanup"
  [ -z "$(find "$scratch" -mindepth 1 -print -quit)" ] || fail "$name scratch cleanup"
  pass "$name"
}

refresh_request_pair() {
  local source=$1 destination=$2 request_snapshot="$tmp/request-refresh"
  "${jq_cmd[@]}" -S -c '.stage_request.content' "$source" > "$request_snapshot"
  "${jq_cmd[@]}" -S -c --arg sha "$(sha_file "$request_snapshot")" \
    '.stage_request.sha256=$sha' "$source" > "$destination"
}

input_for_source() {
  local source=$1 destination=$2 algorithm=$3 commit=$4 tree=$5 intermediate="$tmp/source-input.next"
  "${jq_cmd[@]}" -S -c --arg algorithm "$algorithm" --arg commit "$commit" --arg tree "$tree" '
    .stage_request.content.body.target_revision.value |=
      (.hash_algorithm=$algorithm | .commit_id=$commit) |
    .stage_request.content.body.base.value |=
      (.hash_algorithm=$algorithm | .commit_id=$commit) |
    .stage_request.content.body.source.value.value.revision |=
      (.hash_algorithm=$algorithm | .commit_id=$commit) |
    .stage_request.content.body.source.value.value.object_id=$tree |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.source-tree") |
      .value.value.value.revision) |= (.hash_algorithm=$algorithm | .commit_id=$commit) |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.source-tree") |
      .value.value.value.object_id)=$tree
  ' "$source" > "$intermediate"
  refresh_request_pair "$intermediate" "$destination"
}

input_with_patch() {
  local source=$1 patch=$2 destination=$3 sha intermediate="$tmp/patch-input.next"
  sha=$(sha_file "$patch")
  "${jq_cmd[@]}" -S -c --rawfile patch "$patch" --arg sha "$sha" '
    (.payloads[] | select(.input_id=="input.producer-patch")) |=
      (.data=$patch) |
    (.trust_context.verified_payloads[] |
      select(.input_id=="input.producer-patch")) |=
      (.content.data=$patch | .sha256=$sha) |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.producer-patch") |
      .value.value.value.sha256)=$sha
  ' "$source" > "$intermediate"
  refresh_request_pair "$intermediate" "$destination"
}

input_with_contract() {
  local source=$1 contract=$2 destination=$3 sha intermediate="$tmp/contract-input.next"
  sha=$(sha_file "$contract")
  "${jq_cmd[@]}" -S -c --rawfile contract "$contract" --arg sha "$sha" '
    (.payloads[] | select(.input_id=="input.materialize")) |=
      (.data=$contract) |
    (.trust_context.verified_payloads[] |
      select(.input_id=="input.materialize")) |=
      (.content.data=$contract | .sha256=$sha) |
    (.stage_request.content.body.inputs[] | select(.input_id=="input.materialize") |
      .value.value.value.sha256)=$sha |
    .stage_request.content.body.operation.arguments.materialization_contract.ref.subject_ref.value.value.sha256=$sha
  ' "$source" > "$intermediate"
  refresh_request_pair "$intermediate" "$destination"
}

bad_digest="$tmp/bad-digest.json"
"${jq_cmd[@]}" -S -c '.trust_context.verified_payloads[0].sha256=("0"*64)' \
  "$input_file" > "$bad_digest"
expect_error bad-digest E_CONTRACT "$bad_digest"

wrong_repository="$tmp/wrong-repository.json"
"${jq_cmd[@]}" -S -c '.stage_request.content.body.target_repository_id="other.target"' \
  "$input_file" > "$wrong_repository"
expect_error wrong-repository E_CONTRACT "$wrong_repository"

missing_revision="$tmp/missing-revision.json"
"${jq_cmd[@]}" -S -c '.stage_request.content.body.target_revision.value.commit_id=("0"*40)' \
  "$input_file" > "$missing_revision.next"
refresh_request_pair "$missing_revision.next" "$missing_revision"
expect_error missing-revision E_CONTRACT "$missing_revision"

/usr/bin/printf '%s\n' '/invalid/alternate' > "$tmp/source.git/objects/info/alternates"
expect_error alternates E_SOURCE_GIT
/bin/rm "$tmp/source.git/objects/info/alternates"

git_clean --git-dir="$tmp/source.git" config filter.evil.smudge 'touch /tmp/must-not-run'
expect_error filter-config E_SOURCE_CONFIG
git_clean --git-dir="$tmp/source.git" config --unset-all filter.evil.smudge

hook_marker="$tmp/hook-ran"
printf '%s\n' '#!/bin/sh' "touch '$hook_marker'" > "$tmp/source.git/hooks/post-checkout"
/bin/chmod 0755 "$tmp/source.git/hooks/post-checkout"
expect_error source-hook E_SOURCE_HOOK
[ ! -e "$hook_marker" ] || fail source-hook-ran
/bin/rm "$tmp/source.git/hooks/post-checkout"

/usr/bin/touch "$tmp/source.git/shallow"
expect_error shallow E_SOURCE_GIT
/bin/rm "$tmp/source.git/shallow"

/bin/mkdir -p "$tmp/source.git/refs/replace"
/usr/bin/touch "$tmp/source.git/refs/replace/0000000000000000000000000000000000000000"
expect_error replace-ref E_SOURCE_GIT
/bin/rm -rf "$tmp/source.git/refs/replace"

normal_repo="$tmp/normal"
/bin/mkdir -m 700 "$normal_repo"
git_clean init -q "$normal_repo"
expect_error linked-worktree E_SOURCE_WORKTREE "$input_file" "$normal_repo/.git"

promisor="$tmp/source.git/objects/pack/test.promisor"
/usr/bin/touch "$promisor"
expect_error promisor E_SOURCE_GIT
/bin/rm "$promisor"

remote_source="$tmp/source-remote.git"
/bin/cp -R "$tmp/source.git" "$remote_source"
git_clean --git-dir="$remote_source" config remote.origin.url https://example.invalid/repo.git
expect_error remote-config E_SOURCE_CONFIG "$input_file" "$remote_source"

symlink_source="$tmp/source-symlink.git"
read -r symlink_commit symlink_tree < <(make_bare_source "$symlink_source" sha1 120000)
symlink_input="$tmp/symlink-input.json"
input_for_source "$input_file" "$symlink_input" sha1 "$symlink_commit" "$symlink_tree"
expect_error source-symlink-mode E_SOURCE_TREE "$symlink_input" "$symlink_source"

submodule_source="$tmp/source-submodule.git"
/bin/mkdir -m 700 "$submodule_source"
git_clean init -q --bare --object-format=sha1 "$submodule_source"
sub_blob=$(printf '%s\n' nested | git_clean --git-dir="$submodule_source" hash-object -w --stdin)
sub_tree=$(printf '100644 blob %s\tnested.txt\n' "$sub_blob" |
  git_clean --git-dir="$submodule_source" mktree)
sub_commit=$(printf '%s\n' nested |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$submodule_source" commit-tree "$sub_tree")
outer_tree=$(printf '160000 commit %s\tmodule\n' "$sub_commit" |
  git_clean --git-dir="$submodule_source" mktree)
outer_commit=$(printf '%s\n' outer |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$submodule_source" commit-tree "$outer_tree")
git_clean --git-dir="$submodule_source" update-ref refs/heads/main "$outer_commit"
submodule_input="$tmp/submodule-input.json"
input_for_source "$input_file" "$submodule_input" sha1 "$outer_commit" "$outer_tree"
expect_error source-submodule-mode E_SOURCE_TREE "$submodule_input" "$submodule_source"

sha256_source="$tmp/source-sha256.git"
read -r sha256_commit sha256_tree < <(make_bare_source "$sha256_source" sha256)
sha256_input="$tmp/sha256-input.json"
input_for_source "$input_file" "$sha256_input" sha256 "$sha256_commit" "$sha256_tree"
sha256_root=$(run_case sha256 "$sha256_input" "$sha256_source")
[ ! -s "$sha256_root/err" ] &&
  [ "$(git_clean --git-dir="$sha256_root/candidate/repository.git" rev-parse --show-object-format)" = sha256 ] ||
  fail sha256-materialization
pass 'SHA-256 source and candidate identities remain exact'

scope_contract="$tmp/scope-contract.json"
"${jq_cmd[@]}" -S -c '.allowed_paths=["other.txt"]' "$contract_file" > "$scope_contract"
scope_input="$tmp/scope-input.json"
input_with_contract "$input_file" "$scope_contract" "$scope_input"
expect_error patch-scope E_PATCH_SCOPE "$scope_input"

binary_patch="$tmp/binary.patch"
printf '%s\n' 'GIT binary patch' 'literal 0' 'HcmV?d00001' > "$binary_patch"
binary_input="$tmp/binary-input.json"
input_with_patch "$input_file" "$binary_patch" "$binary_input"
expect_error binary-patch E_BINARY_PATCH "$binary_input"

wrong_tree_input="$tmp/wrong-tree-input.json"
"${jq_cmd[@]}" -S -c '
  .stage_request.content.body.source.value.value.object_id=("0"*40) |
  (.stage_request.content.body.inputs[] | select(.input_id=="input.source-tree") |
    .value.value.value.object_id)=("0"*40)
' "$input_file" > "$wrong_tree_input.next"
refresh_request_pair "$wrong_tree_input.next" "$wrong_tree_input"
expect_error wrong-source-tree E_SOURCE_IDENTITY "$wrong_tree_input"

mode_patch_repo="$tmp/mode-patch"
/bin/mkdir -m 700 "$mode_patch_repo"
git_clean init -q "$mode_patch_repo"
git_clean -C "$mode_patch_repo" config user.name fixture
git_clean -C "$mode_patch_repo" config user.email fixture@example.invalid
printf '%s\n' alpha beta > "$mode_patch_repo/source.txt"
git_clean -C "$mode_patch_repo" add source.txt
git_clean -C "$mode_patch_repo" commit -q -m source
/bin/ln -s outside "$mode_patch_repo/link"
git_clean -C "$mode_patch_repo" add link
symlink_patch="$tmp/symlink.patch"
git_clean -C "$mode_patch_repo" diff --cached --binary > "$symlink_patch"
git_clean -C "$mode_patch_repo" reset -q
/bin/rm "$mode_patch_repo/link"
symlink_contract="$tmp/symlink-contract.json"
"${jq_cmd[@]}" -S -c '.allowed_paths=["link"]' "$contract_file" > "$symlink_contract"
symlink_patch_contract_input="$tmp/symlink-patch-contract-input.json"
input_with_contract "$input_file" "$symlink_contract" "$symlink_patch_contract_input"
symlink_patch_input="$tmp/symlink-patch-input.json"
input_with_patch "$symlink_patch_contract_input" "$symlink_patch" "$symlink_patch_input"
expect_error patch-created-symlink E_CANDIDATE_TREE "$symlink_patch_input"

git_clean -C "$mode_patch_repo" update-index --add --cacheinfo \
  "160000,$source_commit,module"
submodule_patch="$tmp/submodule.patch"
git_clean -C "$mode_patch_repo" diff --cached --binary > "$submodule_patch"
submodule_contract="$tmp/submodule-contract.json"
"${jq_cmd[@]}" -S -c '.allowed_paths=["module"]' "$contract_file" > "$submodule_contract"
submodule_patch_contract_input="$tmp/submodule-patch-contract-input.json"
input_with_contract "$input_file" "$submodule_contract" "$submodule_patch_contract_input"
submodule_patch_input="$tmp/submodule-patch-input.json"
input_with_patch "$submodule_patch_contract_input" "$submodule_patch" "$submodule_patch_input"
expect_error patch-created-submodule E_CANDIDATE_TREE "$submodule_patch_input"

case_nonempty="$tmp/nonempty"
/bin/mkdir -m 700 "$case_nonempty" "$case_nonempty/candidate" "$case_nonempty/scratch"
/usr/bin/touch "$case_nonempty/candidate/existing"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$case_nonempty/candidate" "$case_nonempty/scratch" \
    > "$case_nonempty/out" 2> "$case_nonempty/err"; then fail nonempty-candidate; fi
[ "$(cat "$case_nonempty/err")" = E_CANDIDATE_ROOT ] || fail nonempty-candidate-error
pass 'non-empty candidate root rejected'

overlap_candidate="$tmp/source.git/candidate-boundary"
overlap_scratch="$tmp/overlap-scratch"
/bin/mkdir -m 700 "$overlap_candidate" "$overlap_scratch"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$overlap_candidate" "$overlap_scratch" \
    > "$tmp/overlap.out" 2> "$tmp/overlap.err"; then fail overlapping-boundary; fi
[ "$(cat "$tmp/overlap.err")" = E_BOUNDARY ] || fail overlapping-boundary-error
/bin/rmdir "$overlap_candidate"
pass 'source, candidate, and scratch boundaries cannot overlap'

outside="$tmp/outside-sentinel"
/usr/bin/printf '%s\n' unchanged > "$outside"
traversal_patch="$tmp/traversal.patch"
/usr/bin/printf '%s\n' 'diff --git a/../outside-sentinel b/../outside-sentinel' \
  '--- a/../outside-sentinel' '+++ b/../outside-sentinel' '@@ -1 +1 @@' '-unchanged' '+changed' \
  > "$traversal_patch"
traversal_input="$tmp/traversal-input.json"
input_with_patch "$input_file" "$traversal_patch" "$traversal_input"
expect_error traversal E_PATCH "$traversal_input"
[ "$(cat "$outside")" = unchanged ] || fail traversal-write

symlink_boundary="$tmp/candidate-link"
/bin/ln -s "$tmp" "$symlink_boundary"
boundary_scratch="$tmp/boundary-scratch"
/bin/mkdir -m 700 "$boundary_scratch"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$symlink_boundary" "$boundary_scratch" \
    > "$tmp/boundary.out" 2> "$tmp/boundary.err"; then fail candidate-symlink; fi
[ "$(cat "$tmp/boundary.err")" = E_CANDIDATE_ROOT ] || fail candidate-symlink-error
pass 'symlink candidate boundary rejected'

if /usr/bin/grep -Eq 'curl|wget|gh |glab |github[.]com|gitlab[.]com|git (clone|fetch|pull|push)' \
    "$adapter" "$protocol"; then fail network-command; fi
pass 'payload has no provider, transport, credential, authority or qualification path'

printf 'local Git materializer: %s focused checks passed\n' "$passed"
