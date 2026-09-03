#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
fixtures="$root/scripts/test"
generation=g-c83c940afd16550a4f8a4dbee2b9a6f37e429063d277962ba81c141ba5303b43
parent=g-392d20099dfa99872764009b268c8871914b4dbc0da467ec346baa921818ae3e
generation_root="$root/core/v2/generations/$generation"
parent_root="$root/core/v2/generations/$parent"
registry="$root/core/v2/generation-registry.json"
ledger="$root/scripts/test/portable-core-v2-evidence-identity-ledger.tsv"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-core-v2-evidence.XXXXXX")
trap '/bin/rm -rf -- "$tmp"' EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha_text() { /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'; }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); /usr/bin/printf 'ok %s - %s\n' "$passed" "$1"; }
check() { local name=$1; shift; "$@" >/dev/null 2>&1 || fail "$name"; pass "$name"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$digest" ] ||
  fail 'verified jq 1.6 cache is required'
jq_cmd=("$jq_bin")
[ "$platform" != Darwin:arm64 ] || jq_cmd=(/usr/bin/arch -x86_64 "$jq_bin")
[ "$("${jq_cmd[@]}" --version)" = jq-1.6 ] || fail 'jq version'
runtime_bin="$tmp/runtime-bin"
/bin/mkdir -m 0700 "$runtime_bin"
/bin/ln -s "$jq_bin" "$runtime_bin/jq"
export PATH="$runtime_bin:/usr/bin:/bin"

run_generation() (
  local mode=$1 input
  shift
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$generation_root/core-ingress.sh" 2>/dev/null || exit 1
  trap 'portable_core_ingress_close >/dev/null 2>&1 || :' EXIT
  portable_core_ingress_open || exit 1
  portable_core_ingress_begin "$mode" || exit 1
  for input in "$@"; do portable_core_ingress_snapshot "$input" || exit 1; done
  portable_core_ingress_finish_driver || exit 1
  portable_core_ingress_validate || exit 1
  portable_core_ingress_close || exit 1
  trap - EXIT
)

expect_pass() {
  local name=$1 mode=$2
  shift 2
  if run_generation "$mode" "$@" >"$tmp/$name.out" 2>"$tmp/$name.err" &&
     [ ! -s "$tmp/$name.out" ] && [ ! -s "$tmp/$name.err" ]; then pass "$name"
  else /bin/cat "$tmp/$name.err" >&2; fail "$name"; fi
}
expect_relation() {
  local name=$1 expected=$2 request=$3 result=$4
  local output="$tmp/$name.out" error="$tmp/$name.err" status=0
  run_generation stage-run "$request" "$resolved" "$result" >"$output" 2>"$error" || status=$?
  if [ "$expected" = pass ]; then
    [ "$status" -eq 0 ] && [ ! -s "$output" ] && [ ! -s "$error" ] || fail "$name"
  else
    if [ "$status" -eq 0 ] || [ -s "$output" ] ||
       [ "$(/bin/cat "$error")" != E_RELATION ]; then
      /bin/cat "$error" >&2
      fail "$name"
    fi
  fi
  pass "$name"
}
mutate() { "${jq_cmd[@]}" -S -c "$3" "$1" >"$2"; }

preimage="portable-core-v2|selected-generation=$parent|authorization-comment=5517944082|concern=incident-mismatch-nonpassing-evidence"
check generation-derived test "g-$(sha_text "$preimage")" = "$generation"
check registry-entry "${jq_cmd[@]}" -e --arg generation "$generation" --arg parent "$parent" '
  length==2 and .[1]=={authorization_comment_id:5517944082,
    concern:"incident-mismatch-nonpassing-evidence",generation_id:$generation,
    parent_generation_id:$parent,semantic_identity:"core.contracts.v2"} and
  .[0].generation_id==$parent and
  ([.[].generation_id] | length)==([.[].generation_id] | unique | length)
' "$registry"
check ledger-exact /usr/bin/awk -F '\t' '
  NR==1 {ok=($0=="source\trow_id\tdisposition\trule_id\ttest_id"); next}
  NR==2 {ok=ok && $1=="review" && $2=="pr-222-important-1" && $3=="ported" &&
    $4=="portable-core-v2-evidence-identity.passing-evidence-execution" &&
    $5=="portable-core-v2-evidence-identity.test.incident-mismatch-passed-rejected"; next}
  {ok=0} END {exit !(ok && NR==2)}
' "$ledger"

for path in contracts.jq modules/schema.jq modules/profile_graph.jq \
  modules/stage_request.jq modules/result_facts.jq; do
  /usr/bin/cmp -s "$parent_root/$path" "$generation_root/$path" || fail "copied-$path"
done
pass copied-exports-byte-identical

roles=(producer publisher reviewer verifier)
manifest_files=()
for role in "${roles[@]}"; do
  file="$tmp/manifest-$role.json"
  "${jq_cmd[@]}" -L "$fixtures" -S -c -n --arg role "$role" '
    import "portable-core-profile-graph-fixtures" as f;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    f::manifest($role) | v2
  ' >"$file"
  manifest_files+=("$file")
done
forge_manifest="$tmp/manifest-forge.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n '
  import "portable-core-profile-graph-fixtures" as f;
  {schema_version:2,kind:"adapter_manifest",id:"manifest.forge",body:{
    adapter_version:"v2",package_ref:f::blob("packages/forge.bin";"6"),
    offered_roles:["forge"],offered_execution_kinds:["deterministic"],
    offered_capabilities:["core.forge.materialize-candidate.v2"],
    offered_permissions:["core.perm.candidate-repository.write.v2",
      "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
      "core.perm.target.read.v1"],offered_tools:[]}}
' >"$forge_manifest"
manifest_files=("$forge_manifest" "${manifest_files[@]}")
manifest_shas=$(
  "${jq_cmd[@]}" -S -c -n \
    --arg forge "$(sha_file "$forge_manifest")" \
    --arg producer "$(sha_file "$tmp/manifest-producer.json")" \
    --arg publisher "$(sha_file "$tmp/manifest-publisher.json")" \
    --arg reviewer "$(sha_file "$tmp/manifest-reviewer.json")" \
    --arg verifier "$(sha_file "$tmp/manifest-verifier.json")" \
    '{forge:$forge,producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}'
)
profile="$tmp/profile.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n --argjson shas "$manifest_shas" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  def forge_binding:{binding_id:"binding.forge",role:"forge",
    manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$shas.forge},
    execution_kind:"deterministic",adapter_instance_id:"instance.forge",principal_id:"principal.forge",
    execution_boundary_id:"boundary.forge",authority_ref:f::scope("authority";"authority-forge";f::sha("5")),
    package_ref:f::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
    requested_capabilities:["core.forge.materialize-candidate.v2"],
    requested_permissions:["core.perm.candidate-repository.write.v2","core.perm.evidence.write.v1",
      "core.perm.scratch.write.v1","core.perm.target.read.v1"]};
  f::profile_doc($shas) | v2 | .body.profile_version="v2" |
  .body.bindings += [forge_binding] | .body.bindings |= sort_by(.binding_id)
' >"$profile"
profile_sha=$(sha_file "$profile")
resolved="$tmp/resolved.json"
"${jq_cmd[@]}" -L "$fixtures" -S -c -n --slurpfile profile "$profile" \
  --arg profile_sha "$profile_sha" --argjson shas "$manifest_shas" '
  import "portable-core-profile-graph-fixtures" as f;
  def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
  f::resolved_profile_doc($profile[0];$profile_sha;$shas) | v2 |
  .body.bindings |= map(if .binding.role=="forge" then
    .adapter_implementation.version="v2" |
    .manifest_source=f::source_value(f::blob("manifests/forge.json";"a");"canonical-json";$shas.forge)
  else . end)
' >"$resolved"
resolved_sha=$(sha_file "$resolved")
expect_pass profile-set profile-set "$profile" "$resolved" "${manifest_files[@]}"

for role in producer reviewer verifier; do
  request="$tmp/request-$role.json"
  "${jq_cmd[@]}" -L "$fixtures" -S -c -n --arg role "$role" --arg sha "$resolved_sha" '
    import "portable-core-stage-request-fixtures" as f;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    f::request_doc($role;$sha) | v2
  ' >"$request"
  request_sha=$(sha_file "$request")
  base="$tmp/base-$role.json"
  "${jq_cmd[@]}" -L "$fixtures" -S -c -n --slurpfile request "$request" \
    --slurpfile resolved "$resolved" --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
    import "portable-core-result-truth-fixtures" as f;
    def v2: walk(if type=="object" and has("schema_version") then .schema_version=2 else . end);
    f::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) | v2 |
    .body.execution.metadata.tools={state:"unavailable",reason_id:"provider.tools-unavailable"} |
    .body.outcome.value="inconclusive" | .body.reason={reason_id:"evidence.identity-check"}
  ' >"$base"
  expect_relation "$role-correct-fact-gap-passed" pass "$request" "$base"

  wrong="$tmp/$role-wrong-principal.json"
  mutate "$base" "$wrong" '.body.execution.actual_binding.principal_id="principal.other" |
    .body.execution.performer.principal_id="principal.other" |
    .body.reported_by.principal_id="principal.other"'
  expect_relation "$role-wrong-principal-passed" reject "$request" "$wrong"

  nonpassing="$tmp/$role-wrong-principal-nonpassing.json"
  mutate "$wrong" "$nonpassing" '.body.evidence |= map(.verdict="inconclusive")'
  expect_relation "$role-wrong-principal-nonpassing" pass "$request" "$nonpassing"
done

request="$tmp/request-verifier.json"
base="$tmp/base-verifier.json"
for field in binding_id adapter_instance_id execution_boundary_id; do
  candidate="$tmp/verifier-wrong-$field.json"
  mutate "$base" "$candidate" ".body.execution.actual_binding.$field=\"other.$field\""
  expect_relation "verifier-wrong-$field-passed" reject "$request" "$candidate"
done
candidate="$tmp/verifier-wrong-implementation.json"
mutate "$base" "$candidate" '.body.execution.actual_binding.adapter_implementation.id="adapter.other" |
  .body.execution.performer.implementation_id="adapter.other" | .body.reported_by.implementation_id="adapter.other"'
expect_relation verifier-wrong-implementation-passed reject "$request" "$candidate"
candidate="$tmp/verifier-wrong-environment.json"
mutate "$base" "$candidate" '.body.execution.environment.environment_id="environment.other"'
expect_relation verifier-wrong-environment-passed reject "$request" "$candidate"
candidate="$tmp/verifier-wrong-registered-capability.json"
mutate "$base" "$candidate" '.body.execution.used_capability={kind:"registered",id:"core.review.change.v1"}'
expect_relation verifier-wrong-registered-capability-passed reject "$request" "$candidate"
candidate="$tmp/verifier-ci-unclassified.json"
mutate "$base" "$candidate" '
  .body.execution.actual_binding |= (.binding_id="binding.ci" | .role="ci" |
    .adapter_implementation={id:"adapter.github-actions-ci.v1",version:"v1"} |
    .adapter_instance_id="instance.ci" | .principal_id="principal.ci" |
    .execution_boundary_id="boundary.ci" | del(.authority_ref)) |
  .body.execution.performer={role:"ci",implementation_id:"adapter.github-actions-ci.v1",
    implementation_version:"v1",adapter_instance_id:"instance.ci",principal_id:"principal.ci",
    execution_boundary_id:"boundary.ci"} | .body.reported_by=.body.execution.performer |
  .body.execution.used_capability={kind:"unclassified",id:"github.actions.observe.v1"}
'
expect_relation verifier-ci-unclassified-passed reject "$request" "$candidate"
nonpassing="$tmp/verifier-ci-unclassified-nonpassing.json"
mutate "$candidate" "$nonpassing" '.body.evidence |= map(.verdict="inconclusive")'
expect_relation verifier-ci-unclassified-nonpassing pass "$request" "$nonpassing"
mixed="$tmp/verifier-mixed.json"
mutate "$tmp/verifier-wrong-principal.json" "$mixed" \
  '.body.evidence[0].verdict="inconclusive"'
expect_relation verifier-mismatch-mixed-passed reject "$request" "$mixed"

for status in failed cancelled; do
  candidate="$tmp/verifier-$status-passed.json"
  mutate "$tmp/verifier-ci-unclassified.json" "$candidate" ".body.status=\"$status\" |
    .body.reason={reason_id:\"stage.$status\"} | .body.outcome={family:\"check\",value:\"inconclusive\"} |
    .body.outputs=[] | .body.diagnostics=(if \"$status\"==\"failed\" then
      [{content_id:\"diagnostic.failed\",media_type:\"text/plain\",sha256:(\"d\"*64)}] else [] end)"
  expect_relation "verifier-$status-mismatch-passed" reject "$request" "$candidate"
  nonpassing="$tmp/verifier-$status-nonpassing.json"
  mutate "$candidate" "$nonpassing" '.body.evidence |= map(.verdict="inconclusive")'
  expect_relation "verifier-$status-mismatch-nonpassing" pass "$request" "$nonpassing"
done

check result-truth-diff /usr/bin/grep -Fq 'passing_evidence_execution_ok' \
  "$generation_root/modules/result_truth.jq"
check new-ingress-id /usr/bin/grep -Fq "$generation" "$generation_root/core-ingress.sh"

/usr/bin/printf 'portable core v2 evidence identity: %s/%s checks passed\n' "$passed" "$passed"
