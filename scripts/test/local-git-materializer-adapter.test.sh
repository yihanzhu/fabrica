#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
adapter="$root/adapters/local-git-materializer/v1/materialize.sh"
closure_source="$root/adapters/local-git-materializer/v1/object-closure.c"
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
runtime_bin="$tmp/runtime tools"
/bin/mkdir -m 700 "$runtime_bin"
if [ "$platform" = Darwin:arm64 ]; then
  printf '%s\n' '#!/bin/bash' "exec /usr/bin/arch -x86_64 '$jq_bin' \"\$@\"" > "$runtime_bin/jq"
else
  /bin/cp "$jq_bin" "$runtime_bin/jq"
fi
/bin/chmod 0555 "$runtime_bin/jq"
/usr/bin/cc -std=c11 -Wall -Wextra -Werror -O2 "$closure_source" \
  -o "$runtime_bin/object-closure"
/bin/chmod 0555 "$runtime_bin/object-closure"
closure_helper="$runtime_bin/object-closure"
jq_dependency="$runtime_bin/jq"
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

limited_closure="$tmp/limited-closure"
(
  ulimit -S -t 1
  ulimit -H -t 1
  "$closure_helper" walk "$tmp/source.git" sha1 "$source_commit" "$limited_closure"
)
[ "$(/usr/bin/wc -l < "$limited_closure" | /usr/bin/tr -d ' ')" -eq 3 ] ||
  fail inherited-resource-ceiling
pass 'stricter inherited resource ceilings remain valid'

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
    "$closure_helper" "$jq_dependency" \
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

wide_time_input="$tmp/wide-time-input.json"
"${jq_cmd[@]}" -S -c '
  .attempt.started_at="2100-01-01T00:00:01Z" |
  .attempt.finished_at="2100-01-01T00:00:02Z" |
  .attempt.recorded_at="2100-01-01T00:00:03Z"
' "$input_file" > "$wide_time_input"
wide_time_root=$(run_case wide-time "$wide_time_input")
[ ! -s "$wide_time_root/err" ] || fail wide-time-stderr
[ "$(git_clean --git-dir="$wide_time_root/candidate/repository.git" rev-parse refs/heads/candidate)" = \
  "$candidate_commit" ] || fail wide-time-candidate-identity
pass 'contract-valid timestamps outside Git date range keep deterministic candidate identity'

host_template="$tmp/host-template"
empty_template="$tmp/empty-template"
/bin/mkdir -m 700 "$host_template" "$empty_template" "$host_template/hooks"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$host_template/hooks/post-checkout"
/bin/chmod 0755 "$host_template/hooks/post-checkout"
host_template_repo="$tmp/host-template-repo.git"
empty_template_repo="$tmp/empty-template-repo.git"
/usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR="$host_template" \
  /usr/bin/git init -q --bare "$host_template_repo"
[ -x "$host_template_repo/hooks/post-checkout" ] || fail host-template-fixture
/usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
  GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TEMPLATE_DIR="$host_template" \
  /usr/bin/git init -q --template="$empty_template" --bare "$empty_template_repo"
[ ! -e "$empty_template_repo/hooks/post-checkout" ] || fail explicit-empty-template
/usr/bin/grep -Fq 'git init --template="$empty_template" --bare' "$adapter" ||
  fail materializer-empty-template-option
[ -z "$(find "$candidate_repo/hooks" -type f -print -quit 2>/dev/null)" ] ||
  fail candidate-template-content
pass 'explicit empty template prevents host Git template contamination'

expect_error() {
  local name=$1 expected=$2 input=${3:-$input_file} source=${4:-$tmp/source.git}
  local case_root="$tmp/error-$name"
  local candidate="$case_root/candidate" scratch="$case_root/scratch"
  /bin/mkdir -m 700 "$case_root" "$candidate" "$scratch"
  if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input" fixture.target \
      "$source" "$candidate" "$scratch" "$closure_helper" "$jq_dependency" \
      > "$case_root/out" 2> "$case_root/err"; then
    fail "$name accepted"
  fi
  [ ! -s "$case_root/out" ] && [ "$(cat "$case_root/err")" = "$expected" ] || fail "$name error"
  [ -z "$(find "$candidate" -mindepth 1 -print -quit)" ] || fail "$name candidate cleanup"
  [ -z "$(find "$scratch" -mindepth 1 -print -quit)" ] || fail "$name scratch cleanup"
  pass "$name"
}

direct_case="$tmp/direct-clean-worker"
/bin/mkdir -m 700 "$direct_case" "$direct_case/candidate" "$direct_case/scratch"
/usr/bin/touch "$direct_case/candidate/occupied"
printf '%s\n' "/usr/bin/touch '$direct_case/bash-env-ran'" > "$direct_case/bash-env"
if (
  # shellcheck disable=SC2329
  find() { return 0; }
  export -f find
  PATH="$runtime_bin:/usr/bin:/bin" GH_TOKEN=must-not-read BASH_ENV="$direct_case/bash-env" \
    "$adapter" __materialize_clean "$input_file" fixture.target "$tmp/source.git" \
    "$direct_case/candidate" "$direct_case/scratch" "$closure_helper" "$jq_dependency" \
    > "$direct_case/out" 2> "$direct_case/err"
); then
  fail direct-clean-worker-accepted
fi
[ ! -s "$direct_case/out" ] &&
  [ "$(cat "$direct_case/err")" = E_CANDIDATE_ROOT ] &&
  [ -f "$direct_case/candidate/occupied" ] && [ ! -e "$direct_case/bash-env-ran" ] ||
  fail direct-clean-worker-sanitization
pass 'direct worker entry blocks startup files and strips hostile environment state'

hostile_path_case="$tmp/hostile-path"
/bin/mkdir -m 700 "$hostile_path_case" "$hostile_path_case/bin" \
  "$hostile_path_case/candidate" "$hostile_path_case/scratch"
printf '%s\n' '#!/bin/bash' "/usr/bin/touch '$hostile_path_case/ran'" 'exit 99' \
  > "$hostile_path_case/bin/jq"
/bin/chmod 0555 "$hostile_path_case/bin/jq"
PATH="$hostile_path_case/bin:$runtime_bin:/usr/bin:/bin" \
  "$adapter" materialize "$input_file" fixture.target "$tmp/source.git" \
  "$hostile_path_case/candidate" "$hostile_path_case/scratch" \
  "$closure_helper" "$jq_dependency" \
  > "$hostile_path_case/out" 2> "$hostile_path_case/err"
[ ! -e "$hostile_path_case/ran" ] && [ ! -s "$hostile_path_case/err" ] ||
  fail hostile-path-execution
pass 'inherited executable search path is ignored'

relative_case="$tmp/relative-path"
/bin/mkdir -m 700 "$relative_case" "$relative_case/candidate" "$relative_case/scratch"
if (
  cd "$tmp"
  PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize 'relative:/input.json' \
    fixture.target "$tmp/source.git" "$relative_case/candidate" "$relative_case/scratch" \
    "$closure_helper" "$jq_dependency" \
    > "$relative_case/out" 2> "$relative_case/err"
); then
  fail relative-input-path-accepted
fi
[ ! -s "$relative_case/out" ] && [ "$(cat "$relative_case/err")" = E_USAGE ] ||
  fail relative-input-path
pass 'each filesystem argument must be independently absolute'

expect_error root-source-boundary E_BOUNDARY "$input_file" /

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

empty_patch="$tmp/empty.patch"
: > "$empty_patch"
no_change_input="$tmp/no-change-input.json"
input_with_patch "$input_file" "$empty_patch" "$no_change_input"
no_change_root=$(run_case no-change "$no_change_input")
[ ! -s "$no_change_root/err" ] || fail no-change-stderr
"${jq_cmd[@]}" -e --arg commit "$source_commit" --arg tree "$source_tree" '
  .stage_result.body.status=="completed" and
  .stage_result.body.outcome=={family:"change",value:"no-change"} and
  (.payloads[0].data | fromjson |
    .candidate.commit_id==$commit and .candidate.tree_id==$tree and
    .changed_paths.count==0)
' "$no_change_root/out" >/dev/null || fail no-change-response
pass 'empty patch returns the canonical no-change result'

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

oversize_input="$tmp/oversize-input.json"
/bin/dd if=/dev/zero of="$oversize_input" bs=8388609 count=1 2>/dev/null
expect_error oversize-input E_INPUT "$oversize_input"

large_source="$tmp/source-large.git"
/bin/mkdir -m 700 "$large_source"
git_clean init -q --bare --object-format=sha1 "$large_source"
large_blob=$(/bin/dd if=/dev/zero bs=1048576 count=257 2>/dev/null |
  git_clean --git-dir="$large_source" hash-object -w --stdin)
large_tree=$(printf '100644 blob %s\tsource.txt\n' "$large_blob" |
  git_clean --git-dir="$large_source" mktree)
large_commit=$(printf '%s\n' large-source |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$large_source" commit-tree "$large_tree")
git_clean --git-dir="$large_source" update-ref refs/heads/main "$large_commit"
large_input="$tmp/large-input.json"
input_for_source "$input_file" "$large_input" sha1 "$large_commit" "$large_tree"
expect_error source-import-budget E_SOURCE_LIMIT "$large_input" "$large_source"

many_objects_source="$tmp/source-many-objects.git"
/bin/mkdir -m 700 "$many_objects_source"
git_clean init -q --bare --object-format=sha1 "$many_objects_source"
/usr/bin/awk 'BEGIN {
  for (i=1; i<=32768; i++) {
    data=sprintf("blob-%05d",i)
    print "blob"
    printf "mark :%d\n",i
    printf "data %d\n%s\n",length(data),data
    print "commit refs/heads/main"
    printf "mark :%d\n",40000+i
    print "author fixture <fixture@example.invalid> 946684800 +0000"
    print "committer fixture <fixture@example.invalid> 946684800 +0000"
    print "data 5"
    print "count"
    if (i>1) printf "from :%d\n",40000+i-1
    printf "M 100644 :%d file\n\n",i
  }
}' | git_clean --git-dir="$many_objects_source" fast-import --quiet
many_objects_commit=$(git_clean --git-dir="$many_objects_source" rev-parse refs/heads/main)
many_objects_tree=$(git_clean --git-dir="$many_objects_source" \
  rev-parse "$many_objects_commit^{tree}")
many_objects_count=$(git_clean --git-dir="$many_objects_source" rev-list \
  --objects --no-object-names "$many_objects_commit" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[ "$many_objects_count" -gt 65536 ] || fail many-objects-fixture
many_objects_input="$tmp/many-objects-input.json"
input_for_source "$input_file" "$many_objects_input" sha1 \
  "$many_objects_commit" "$many_objects_tree"
expect_error source-import-object-count E_SOURCE_LIMIT \
  "$many_objects_input" "$many_objects_source"

large_listing_source="$tmp/source-large-listing.git"
/bin/mkdir -m 700 "$large_listing_source"
git_clean init -q --bare --object-format=sha1 "$large_listing_source"
large_listing_blob=$(printf '%s\n' value |
  git_clean --git-dir="$large_listing_source" hash-object -w --stdin)
large_listing_prefix=$(/usr/bin/awk 'BEGIN { for (i=1; i<=4088; i++) printf "a" }')
large_listing_tree=$(/usr/bin/awk -v object="$large_listing_blob" \
  -v prefix="$large_listing_prefix" 'BEGIN {
    for (i=1; i<=4097; i++)
      printf "100644 blob %s\t%s%05d\n",object,prefix,i
  }' | git_clean --git-dir="$large_listing_source" mktree)
[ "$(git_clean --git-dir="$large_listing_source" cat-file -s "$large_listing_tree")" \
  -gt 16777216 ] || fail large-listing-fixture
large_listing_commit=$(printf '%s\n' large-listing |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$large_listing_source" \
    commit-tree "$large_listing_tree")
git_clean --git-dir="$large_listing_source" update-ref refs/heads/main "$large_listing_commit"
large_listing_input="$tmp/large-listing-input.json"
input_for_source "$input_file" "$large_listing_input" sha1 \
  "$large_listing_commit" "$large_listing_tree"
expect_error source-tree-byte-limit E_SOURCE_TREE \
  "$large_listing_input" "$large_listing_source"

historical_blob=$(printf '%s\n' alpha beta |
  git_clean --git-dir="$large_listing_source" hash-object -w --stdin)
historical_tip_tree=$(printf '100644 blob %s\tsource.txt\n' "$historical_blob" |
  git_clean --git-dir="$large_listing_source" mktree)
historical_tip=$(printf '%s\n' historical-tip |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$large_listing_source" \
    commit-tree "$historical_tip_tree" -p "$large_listing_commit")
git_clean --git-dir="$large_listing_source" update-ref refs/heads/main "$historical_tip"
historical_input="$tmp/historical-input.json"
input_for_source "$input_file" "$historical_input" sha1 "$historical_tip" "$historical_tip_tree"
expect_error oversized-historical-tree E_SOURCE_LIMIT "$historical_input" "$large_listing_source"

shared_source="$tmp/source-shared-large-blob.git"
/bin/mkdir -m 700 "$shared_source"
git_clean init -q --bare --object-format=sha1 "$shared_source"
shared_blob=$(
  { printf 'alpha\n'; /bin/dd if=/dev/zero bs=1048576 count=8 2>/dev/null |
      /usr/bin/tr '\000' a; } |
    git_clean --git-dir="$shared_source" hash-object -w --stdin
)
shared_contract="$tmp/shared-contract.json"
"${jq_cmd[@]}" -S -c '
  .allowed_paths=([range(1;34) | "shared-" + tostring] | sort) |
  .max_changed_paths=33
' "$contract_file" > "$shared_contract"
shared_paths="$tmp/shared-paths"
"${jq_cmd[@]}" -r '.allowed_paths[]' "$shared_contract" > "$shared_paths"
shared_tree=$(while IFS= read -r path; do
  printf '100644 blob %s\t%s\n' "$shared_blob" "$path"
done < "$shared_paths" | git_clean --git-dir="$shared_source" mktree)
shared_commit=$(printf '%s\n' shared-large-blob |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$shared_source" commit-tree "$shared_tree")
git_clean --git-dir="$shared_source" update-ref refs/heads/main "$shared_commit"
shared_patch="$tmp/shared.patch"
while IFS= read -r path; do
  printf '%s\n' "diff --git a/$path b/$path" "--- a/$path" "+++ b/$path" \
    '@@ -1 +1 @@' '-alpha' '+beta'
done < "$shared_paths" > "$shared_patch"
shared_source_input="$tmp/shared-source-input.json"
input_for_source "$input_file" "$shared_source_input" sha1 "$shared_commit" "$shared_tree"
shared_contract_input="$tmp/shared-contract-input.json"
input_with_contract "$shared_source_input" "$shared_contract" "$shared_contract_input"
shared_input="$tmp/shared-input.json"
input_with_patch "$shared_contract_input" "$shared_patch" "$shared_input"
expect_error candidate-mutation-budget E_CANDIDATE_LIMIT "$shared_input" "$shared_source"

copy_contract="$tmp/copy-contract.json"
"${jq_cmd[@]}" -S -c \
  '.allowed_paths=["copy-1","source.txt"] | .max_changed_paths=1' \
  "$contract_file" > "$copy_contract"
copy_patch="$tmp/copy.patch"
printf '%s\n' 'diff --git a/source.txt b/copy-1' 'similarity index 99%' \
  'copy from source.txt' 'copy to copy-1' '--- a/source.txt' '+++ b/copy-1' \
  '@@ -1 +1 @@' '-alpha' '+beta' > "$copy_patch"
copy_contract_input="$tmp/copy-contract-input.json"
input_with_contract "$input_file" "$copy_contract" "$copy_contract_input"
copy_input="$tmp/copy-input.json"
input_with_patch "$copy_contract_input" "$copy_patch" "$copy_input"
expect_error copy-metadata E_PATCH "$copy_input"

directory_file_source="$tmp/source-directory-file.git"
/bin/mkdir -m 700 "$directory_file_source"
git_clean init -q --bare --object-format=sha1 "$directory_file_source"
directory_file_blob=$(printf '%s\n' value |
  git_clean --git-dir="$directory_file_source" hash-object -w --stdin)
directory_file_child=$(printf '100644 blob %s\tfile\n' "$directory_file_blob" |
  git_clean --git-dir="$directory_file_source" mktree)
directory_file_tree=$(printf '040000 tree %s\tdir\n' "$directory_file_child" |
  git_clean --git-dir="$directory_file_source" mktree)
directory_file_commit=$(printf '%s\n' directory-file |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$directory_file_source" \
    commit-tree "$directory_file_tree")
git_clean --git-dir="$directory_file_source" update-ref refs/heads/main "$directory_file_commit"
directory_file_contract="$tmp/directory-file-contract.json"
"${jq_cmd[@]}" -S -c \
  '.allowed_paths=["dir","dir/file"] | .max_changed_paths=2' \
  "$contract_file" > "$directory_file_contract"
directory_file_patch="$tmp/directory-file.patch"
printf '%s\n' 'diff --git a/dir/file b/dir/file' 'deleted file mode 100644' \
  '--- a/dir/file' '+++ /dev/null' '@@ -1 +0,0 @@' '-value' \
  'diff --git a/dir b/dir' 'new file mode 100644' '--- /dev/null' '+++ b/dir' \
  '@@ -0,0 +1 @@' '+replacement' > "$directory_file_patch"
directory_file_source_input="$tmp/directory-file-source-input.json"
input_for_source "$input_file" "$directory_file_source_input" sha1 \
  "$directory_file_commit" "$directory_file_tree"
directory_file_contract_input="$tmp/directory-file-contract-input.json"
input_with_contract "$directory_file_source_input" "$directory_file_contract" \
  "$directory_file_contract_input"
directory_file_input="$tmp/directory-file-input.json"
input_with_patch "$directory_file_contract_input" "$directory_file_patch" \
  "$directory_file_input"
directory_file_root=$(run_case directory-file "$directory_file_input" "$directory_file_source")
[ ! -s "$directory_file_root/err" ] || fail directory-file-stderr
directory_file_candidate="$directory_file_root/candidate/repository.git"
directory_file_candidate_commit=$(git_clean --git-dir="$directory_file_candidate" \
  rev-parse refs/heads/candidate)
if [ "$(git_clean --git-dir="$directory_file_candidate" show \
    "$directory_file_candidate_commit:dir")" != replacement ] ||
   git_clean --git-dir="$directory_file_candidate" cat-file -e \
     "$directory_file_candidate_commit:dir/file" 2>/dev/null; then
  fail directory-file-result
fi
pass 'directory-to-file transition preserves preflight accounting and applies cleanly'

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

packed_replace_source="$tmp/source-packed-replace.git"
/bin/cp -R "$tmp/source.git" "$packed_replace_source"
git_clean --git-dir="$packed_replace_source" update-ref \
  "refs/replace/$source_tree" "$source_tree"
git_clean --git-dir="$packed_replace_source" pack-refs --all --prune
/bin/rmdir "$packed_replace_source/refs/replace" 2>/dev/null || :
[ ! -d "$packed_replace_source/refs/replace" ] || fail packed-replace-fixture
expect_error packed-replace-ref E_SOURCE_GIT "$input_file" "$packed_replace_source"

uppercase_packed_replace_source="$tmp/source-uppercase-packed-replace.git"
/bin/cp -R "$packed_replace_source" "$uppercase_packed_replace_source"
/usr/bin/awk '/^[0-9a-f]+ / {$1=toupper($1)} {print}' \
  "$uppercase_packed_replace_source/packed-refs" \
  > "$uppercase_packed_replace_source/packed-refs.upper"
/bin/mv "$uppercase_packed_replace_source/packed-refs.upper" \
  "$uppercase_packed_replace_source/packed-refs"
git_clean --git-dir="$uppercase_packed_replace_source" show-ref --verify \
  "refs/replace/$source_tree" >/dev/null || fail uppercase-packed-replace-fixture
expect_error uppercase-packed-replace-ref E_SOURCE_GIT "$input_file" \
  "$uppercase_packed_replace_source"

large_packed_refs_source="$tmp/source-large-packed-refs.git"
/bin/cp -R "$tmp/source.git" "$large_packed_refs_source"
/usr/bin/awk 'BEGIN { for (i=0; i<524289; i++) print "#" }' \
  > "$large_packed_refs_source/packed-refs"
expect_error packed-refs-limit E_SOURCE_LIMIT "$input_file" "$large_packed_refs_source"

normal_repo="$tmp/normal"
/bin/mkdir -m 700 "$normal_repo"
git_clean init -q "$normal_repo"
expect_error linked-worktree E_SOURCE_WORKTREE "$input_file" "$normal_repo/.git"

linked_source="$tmp/source-with-worktree.git"
/bin/cp -R "$tmp/source.git" "$linked_source"
linked_path="$tmp/source-linked"
git_clean --git-dir="$linked_source" worktree add --detach "$linked_path" \
  "$source_commit" >/dev/null
[ -d "$linked_source/worktrees" ] || fail bare-linked-worktree-fixture
expect_error bare-linked-worktree-metadata E_SOURCE_GIT "$input_file" "$linked_source"
git_clean --git-dir="$linked_source" worktree remove --force "$linked_path"

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

empty_subtree_source="$tmp/source-empty-subtree.git"
/bin/mkdir -m 700 "$empty_subtree_source"
git_clean init -q --bare --object-format=sha1 "$empty_subtree_source"
empty_subtree_blob=$(printf '%s\n' alpha beta |
  git_clean --git-dir="$empty_subtree_source" hash-object -w --stdin)
empty_tree=$(git_clean --git-dir="$empty_subtree_source" mktree </dev/null)
empty_subtree_tree=$(printf '040000 tree %s\tempty\n100644 blob %s\tsource.txt\n' \
  "$empty_tree" "$empty_subtree_blob" |
  git_clean --git-dir="$empty_subtree_source" mktree)
empty_subtree_commit=$(printf '%s\n' empty-subtree |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$empty_subtree_source" \
    commit-tree "$empty_subtree_tree")
git_clean --git-dir="$empty_subtree_source" update-ref refs/heads/main "$empty_subtree_commit"
empty_subtree_input="$tmp/empty-subtree-input.json"
input_for_source "$input_file" "$empty_subtree_input" sha1 \
  "$empty_subtree_commit" "$empty_subtree_tree"
expect_error source-empty-subtree E_SOURCE_TREE "$empty_subtree_input" "$empty_subtree_source"

newline_source="$tmp/source-newline.git"
/bin/mkdir -m 700 "$newline_source"
git_clean init -q --bare --object-format=sha1 "$newline_source"
newline_blob=$(printf '%s\n' value |
  git_clean --git-dir="$newline_source" hash-object -w --stdin)
newline_tree=$(printf '100644 blob %s\tfoo\nbar\0' "$newline_blob" |
  git_clean --git-dir="$newline_source" mktree -z)
newline_commit=$(printf '%s\n' newline |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$newline_source" \
    commit-tree "$newline_tree")
git_clean --git-dir="$newline_source" update-ref refs/heads/main "$newline_commit"
newline_input="$tmp/newline-input.json"
input_for_source "$input_file" "$newline_input" sha1 "$newline_commit" "$newline_tree"
expect_error source-newline-path E_SOURCE_TREE "$newline_input" "$newline_source"

c1_source="$tmp/source-c1.git"
/bin/mkdir -m 700 "$c1_source"
git_clean init -q --bare --object-format=sha1 "$c1_source"
c1_blob=$(printf '%s\n' value | git_clean --git-dir="$c1_source" hash-object -w --stdin)
c1_tree=$(printf '100644 blob %s\tfoo\302\200bar\0' "$c1_blob" |
  git_clean --git-dir="$c1_source" mktree -z)
c1_commit=$(printf '%s\n' c1-control |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$c1_source" commit-tree "$c1_tree")
git_clean --git-dir="$c1_source" update-ref refs/heads/main "$c1_commit"
c1_input="$tmp/c1-input.json"
input_for_source "$input_file" "$c1_input" sha1 "$c1_commit" "$c1_tree"
expect_error source-c1-control-path E_SOURCE_TREE "$c1_input" "$c1_source"

malformed_source="$tmp/source-malformed-utf8.git"
/bin/mkdir -m 700 "$malformed_source"
git_clean init -q --bare --object-format=sha1 "$malformed_source"
malformed_blob=$(printf '%s\n' value |
  git_clean --git-dir="$malformed_source" hash-object -w --stdin)
malformed_tree=$(printf '100644 blob %s\tfoo\200bar\0' "$malformed_blob" |
  git_clean --git-dir="$malformed_source" mktree -z)
malformed_commit=$(printf '%s\n' malformed-utf8 |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$malformed_source" commit-tree "$malformed_tree")
git_clean --git-dir="$malformed_source" update-ref refs/heads/main "$malformed_commit"
malformed_input="$tmp/malformed-input.json"
input_for_source "$input_file" "$malformed_input" sha1 "$malformed_commit" "$malformed_tree"
expect_error source-malformed-utf8-path E_SOURCE_TREE "$malformed_input" "$malformed_source"

many_paths_source="$tmp/source-many-paths.git"
/bin/mkdir -m 700 "$many_paths_source"
git_clean init -q --bare --object-format=sha1 "$many_paths_source"
many_paths_blob=$(printf '%s\n' value |
  git_clean --git-dir="$many_paths_source" hash-object -w --stdin)
many_paths_tree=$(/usr/bin/awk -v object="$many_paths_blob" \
  'BEGIN { for (i=1; i<=65537; i++) printf "100644 blob %s\tpath-%05d\n", object, i }' |
  git_clean --git-dir="$many_paths_source" mktree)
many_paths_commit=$(printf '%s\n' many-paths |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$many_paths_source" \
    commit-tree "$many_paths_tree")
git_clean --git-dir="$many_paths_source" update-ref refs/heads/main "$many_paths_commit"
many_paths_input="$tmp/many-paths-input.json"
input_for_source "$input_file" "$many_paths_input" sha1 \
  "$many_paths_commit" "$many_paths_tree"
expect_error source-tree-entry-limit E_SOURCE_TREE "$many_paths_input" "$many_paths_source"

deep_path_source="$tmp/source-deep-path.git"
/bin/mkdir -m 700 "$deep_path_source"
git_clean init -q --bare --object-format=sha1 "$deep_path_source"
deep_path_blob=$(printf '%s\n' value |
  git_clean --git-dir="$deep_path_source" hash-object -w --stdin)
deep_path_tree=$(printf '100644 blob %s\tleaf\n' "$deep_path_blob" |
  git_clean --git-dir="$deep_path_source" mktree)
for _ in {1..64}; do
  deep_path_tree=$(printf '040000 tree %s\td\n' "$deep_path_tree" |
    git_clean --git-dir="$deep_path_source" mktree)
done
deep_path_commit=$(printf '%s\n' deep-path |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$deep_path_source" \
    commit-tree "$deep_path_tree")
git_clean --git-dir="$deep_path_source" update-ref refs/heads/main "$deep_path_commit"
deep_path_input="$tmp/deep-path-input.json"
input_for_source "$input_file" "$deep_path_input" sha1 "$deep_path_commit" "$deep_path_tree"
expect_error source-tree-component-limit E_SOURCE_TREE "$deep_path_input" "$deep_path_source"

many_trees_source="$tmp/source-many-trees.git"
/bin/mkdir -m 700 "$many_trees_source"
git_clean init -q --bare --object-format=sha1 "$many_trees_source"
many_trees_blob=$(printf '%s\n' value |
  git_clean --git-dir="$many_trees_source" hash-object -w --stdin)
many_trees_leaf=$(printf '100644 blob %s\tfile\n' "$many_trees_blob" |
  git_clean --git-dir="$many_trees_source" mktree)
many_trees_root=$(/usr/bin/awk -v tree="$many_trees_leaf" \
  'BEGIN { for (i=1; i<=1024; i++) printf "040000 tree %s\tdir-%04d\n",tree,i }' |
  git_clean --git-dir="$many_trees_source" mktree)
many_trees_commit=$(printf '%s\n' many-trees |
  /usr/bin/env -i HOME="$tmp/home" TMPDIR="$tmp" PATH=/usr/bin:/bin LC_ALL=C \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_NO_REPLACE_OBJECTS=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
    /usr/bin/git --no-replace-objects --git-dir="$many_trees_source" \
    commit-tree "$many_trees_root")
git_clean --git-dir="$many_trees_source" update-ref refs/heads/main "$many_trees_commit"
many_trees_input="$tmp/many-trees-input.json"
input_for_source "$input_file" "$many_trees_input" sha1 \
  "$many_trees_commit" "$many_trees_root"
expect_error source-tree-object-limit E_SOURCE_TREE "$many_trees_input" "$many_trees_source"

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
    "$closure_helper" "$jq_dependency" \
    > "$case_nonempty/out" 2> "$case_nonempty/err"; then fail nonempty-candidate; fi
[ "$(cat "$case_nonempty/err")" = E_CANDIDATE_ROOT ] || fail nonempty-candidate-error
pass 'non-empty candidate root rejected'

overlap_candidate="$tmp/source.git/candidate-boundary"
overlap_scratch="$tmp/overlap-scratch"
/bin/mkdir -m 700 "$overlap_candidate" "$overlap_scratch"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$overlap_candidate" "$overlap_scratch" \
    "$closure_helper" "$jq_dependency" \
    > "$tmp/overlap.out" 2> "$tmp/overlap.err"; then fail overlapping-boundary; fi
[ "$(cat "$tmp/overlap.err")" = E_BOUNDARY ] || fail overlapping-boundary-error
/bin/rmdir "$overlap_candidate"
pass 'source, candidate, and scratch boundaries cannot overlap'

closed_output="$tmp/closed-output"
/bin/mkdir -m 700 "$closed_output" "$closed_output/candidate" "$closed_output/scratch"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$closed_output/candidate" "$closed_output/scratch" \
    "$closure_helper" "$jq_dependency" \
    >&- 2> "$closed_output/err"; then
  fail closed-output-accepted
fi
[ -z "$(find "$closed_output/candidate" -mindepth 1 -print -quit)" ] &&
  [ -z "$(find "$closed_output/scratch" -mindepth 1 -print -quit)" ] ||
  fail closed-output-cleanup
pass 'response failure removes candidate and scratch state'

outside="$tmp/outside-sentinel"
/usr/bin/printf '%s\n' unchanged > "$outside"
traversal_patch="$tmp/traversal.patch"
/usr/bin/printf '%s\n' 'diff --git a/../outside-sentinel b/../outside-sentinel' \
  '--- a/../outside-sentinel' '+++ b/../outside-sentinel' '@@ -1 +1 @@' '-unchanged' '+changed' \
  > "$traversal_patch"
traversal_input="$tmp/traversal-input.json"
input_with_patch "$input_file" "$traversal_patch" "$traversal_input"
expect_error traversal E_PATCH_PATH "$traversal_input"
[ "$(cat "$outside")" = unchanged ] || fail traversal-write

symlink_boundary="$tmp/candidate-link"
/bin/ln -s "$tmp" "$symlink_boundary"
boundary_scratch="$tmp/boundary-scratch"
/bin/mkdir -m 700 "$boundary_scratch"
if PATH="$runtime_bin:/usr/bin:/bin" "$adapter" materialize "$input_file" fixture.target \
    "$tmp/source.git" "$symlink_boundary" "$boundary_scratch" \
    "$closure_helper" "$jq_dependency" \
    > "$tmp/boundary.out" 2> "$tmp/boundary.err"; then fail candidate-symlink; fi
[ "$(cat "$tmp/boundary.err")" = E_CANDIDATE_ROOT ] || fail candidate-symlink-error
pass 'symlink candidate boundary rejected'

if /usr/bin/grep -Eq 'curl|wget|gh |glab |github[.]com|gitlab[.]com|git (clone|fetch|pull|push)' \
    "$adapter" "$protocol"; then fail network-command; fi
if [ "$(/usr/bin/grep -Fc -- '--accounted-validation' "$adapter")" -ne 1 ] ||
   /usr/bin/grep -Eq '"\$core" (validate-document|validate-profile-set|validate-stage-run)' \
     "$adapter"; then
  fail unaccounted-core-validation
fi
pass 'core validation is routed through caller-owned accounted scratch'
pass 'payload has no provider, transport, credential, authority or qualification path'

if /usr/bin/grep -Fq 'done < <(git_dir "$staging_repo" diff-tree' "$adapter" ||
   ! /usr/bin/grep -Fq 'diff-tree -r --name-only -z' "$adapter" ||
   ! /usr/bin/grep -Fq '> "$changed_paths_raw"' "$adapter"; then
  fail changed-path-status-capture
fi
pass 'changed-path enumeration is captured before evidence processing'

if /usr/bin/grep -Fq '/bin/cp "$input_path"' "$adapter" ||
   ! /usr/bin/grep -Fq 'input_copy_ceiling=8388609' "$adapter" ||
   ! /usr/bin/grep -Fq 'source_config_ceiling=1048577' "$adapter" ||
   /usr/bin/grep -Fq 'ls-tree -rz -r' "$adapter"; then
  fail preparse-resource-bounds
fi
pass 'input, config, and tree bounds precede copying or recursive parsing'

scan_tree_body=$(/usr/bin/sed -n '/^scan_tree() {$/,/^}$/p' "$adapter")
for checked_write in \
  'printf '\''%s\t\n'\'' "$tree" > "$queue" || return 1' \
  ': > "$output" || return 1' \
  'printf '\''%s\n'\'' "$full_path" >> "$output" || return 1' \
  'printf '\''%s\t%s\n'\'' "$object" "$full_path" >> "$queue" || return 1'; do
  /usr/bin/grep -Fq "$checked_write" <<< "$scan_tree_body" ||
    fail tree-scan-write-status
done
pass 'tree scan scratch writes fail closed'

for expanded_limit in \
  'expanded_bytes=0' \
  'path_bytes=$((${#full_path} + 1))' \
  'path_bytes=$((${#object} + ${#full_path} + 2))' \
  '[ "$path_bytes" -le "$((tree_scan_byte_limit - expanded_bytes))" ] || return 1' \
  'expanded_bytes=$((expanded_bytes + path_bytes))'; do
  /usr/bin/grep -Fq "$expanded_limit" <<< "$scan_tree_body" ||
    fail expanded-tree-path-limit
done
pass 'expanded tree path output shares the fixed byte ceiling'

printf 'local Git materializer: %s focused checks passed\n' "$passed"
