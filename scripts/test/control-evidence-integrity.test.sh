#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

if [ "${YSTACK_EVIDENCE_TEST_BOUNDED:-0}" != 1 ]; then
  YSTACK_EVIDENCE_TEST_BOUNDED=1 exec /usr/bin/perl -e 'alarm 360; exec @ARGV' "$0"
fi

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
evaluator="$root/control/v1/evaluate-evidence-integrity.sh"
policy="$root/control/v1/evidence-integrity-policy.json"
definition="$root/control/v1/evidence-integrity-decision.json"
program="$root/control/v1/evidence-integrity.jq"
core_wrapper="$root/scripts/core-contract.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-evidence-test.XXXXXX")
cleanup() { /bin/rm -rf -- "$tmp"; }
trap cleanup EXIT HUP INT TERM
# Accounted Linux paths can exceed 7s; 4000 x 5ms leaves a 20s CI margin
# inside the suite's 360s hard cap for markers reached after that work.
late_marker_attempts=4000
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
test_path_identity() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MCwd=abs_path -e '
      my ($path)=@ARGV; my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 2 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent); chdir($parent) or exit 2;
      my @cwd=stat("."); my @leaf=lstat($name);
      exit 2 unless @parent && @cwd && @leaf && S_ISDIR($parent[2]) &&
        S_ISREG($leaf[2]);
      sysopen(my $input,$name,O_RDONLY|O_NOFOLLOW) or exit 2;
      binmode($input); my @opened=stat($input); my $sha=Digest::SHA->new(256);
      while (1) { my $read=sysread($input,my $buffer,65536); exit 2 unless
        defined($read); last if $read==0; $sha->add($buffer); }
      my @after=stat($input); my @path_after=lstat($name);
      exit 2 unless @opened && @after && @path_after &&
        $leaf[0]==$opened[0] && $leaf[1]==$opened[1] &&
        $opened[0]==$after[0] && $opened[1]==$after[1] &&
        $after[0]==$path_after[0] && $after[1]==$path_after[1];
      print $parent[0],":",$parent[1],":",$leaf[0],":",$leaf[1],":",
        $leaf[7],":",$leaf[9],":",$leaf[10],":",$sha->hexdigest,"\n";
    ' "$1"
}
test_directory_identity() {
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin \
    /usr/bin/perl -MFcntl=:mode -MCwd=abs_path -e '
      my ($path)=@ARGV; my ($parent,$name)=$path =~ m{\A(.+)/([^/]+)\z};
      exit 1 unless defined($parent) && defined($name) &&
        defined(abs_path($parent)) && abs_path($parent) eq $parent;
      my @parent=lstat($parent); my @dir=lstat($path); my $physical=abs_path($path);
      exit 1 unless @parent && @dir && S_ISDIR($parent[2]) && S_ISDIR($dir[2]) &&
        (($dir[2] & 07777) == 0700) && defined($physical) && $physical eq $path;
      print $parent[0],":",$parent[1],":",$dir[0],":",$dir[1],"\n";
    ' "$1"
}
test_payload_sha() {
  local identity=${2:-}
  [ -n "$identity" ] || identity=$(test_path_identity "$1")
  [ -n "$identity" ] || return 1
  /usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin /bin/bash -c '
    source "$1" || exit 1
    payload_sha_from_identity "$1" "$2"
  ' payload-hash "$1" "$identity"
}

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*)
    jq_asset=jq-osx-amd64
    jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef
    ;;
  Linux:x86_64)
    jq_asset=jq-linux64
    jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44
    ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha256_path "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" -o "$download"
  [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
fi
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$($jq_bin --version)" = jq-1.6 ] || fail 'jq identity'

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core_wrapper") ||
  fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
policy_sha=$(sha256_path "$policy")
definition_sha=$(sha256_path "$definition")
launcher_sha=$(sha256_path "$evaluator")
launcher_identity=$(test_path_identity "$evaluator")
payload_sha=$(test_payload_sha "$evaluator" "$launcher_identity")
core_package_sha=$("$jq_bin" -er '.body.core_contract.package_ref.sha256' "$policy")
for canonical_source in "$policy" "$definition"; do
  "$jq_bin" -S -c . "$canonical_source" >"$tmp/canonical"
  /usr/bin/cmp -s "$canonical_source" "$tmp/canonical" ||
    fail "canonical ${canonical_source##*/}"
done
for source_path in control/v1/evidence-integrity-policy.json \
  control/v1/evidence-integrity-decision.json control/v1/evidence-integrity.jq \
  control/v1/evaluate-evidence-integrity.sh scripts/test/control-evidence-integrity.test.sh; do
  ! /usr/bin/grep -Fq "$generation" "$root/$source_path" ||
    fail "raw generation $source_path"
done
pass 'canonical definitions and opaque core generation'
"$jq_bin" -e --arg launcher "$launcher_sha" --arg payload "$payload_sha" '
  .body.evaluator.trusted_launcher_ref=={
    content_id:"control-evaluator-launcher.evidence-integrity.v1",
    media_type:"text/x-shellscript",sha256:$launcher} and
  .body.evaluator.evaluation_payload_ref=={
    content_id:"control-evaluator-payload.evidence-integrity.v1",
    media_type:"text/x-shellscript-fragment",sha256:$payload} and
  .body.semantics.launcher_attestation=="trusted-boundary-not-self-attested"
' "$definition" >/dev/null || fail 'launcher and payload identity contract'
if ! /usr/bin/grep -Fq 'self-attest bytes that Bash already loaded' "$root/README.md" ||
   ! /usr/bin/grep -Fq 'launcher is not self-attested.' "$root/RESTORE.md"; then
  fail 'launcher boundary docs'
fi
pass 'trusted launcher and exact evaluation payload are distinct identities'

policy_set="$tmp/policy-set.json"
"$jq_bin" -S -c -n --arg policy_sha "$policy_sha" \
  --arg definition_sha "$definition_sha" --arg generation "$generation" \
  --arg core_package_sha "$core_package_sha" '
  def ref($id;$media;$sha): {content_id:$id,media_type:$media,sha256:$sha};
  def section($id;$policy_sha;$decision_sha):
    {section_id:$id,
     policy_ref:ref("control-policy."+$id;
       "application/vnd.ystack.control-policy+json";$policy_sha),
     decision_ref:ref("control-decision."+$id;
       "application/vnd.ystack.control-decision+json";$decision_sha)};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.test",
   body:{activation_state:"inactive",fail_mode:"closed",policy_version:"v1",
     core_contract:{semantic_identity:"core.contracts.v2",generation_id:$generation,
       package_ref:ref("core-contract-package.v2";
         "application/vnd.ystack.core-contract+json";$core_package_sha)},
     sections:[section("credential-policy";("1"*64);("a"*64)),
       section("duty-separation";("2"*64);("b"*64)),
       section("evidence-integrity";$policy_sha;$definition_sha),
       section("kill-switch";("4"*64);("d"*64)),
       section("risk-gates";("5"*64);("e"*64)),
       section("sandbox";("6"*64);("f"*64))]}}
' >"$policy_set"

resolved="$tmp/resolved.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n '
  import "portable-core-profile-graph-fixtures" as profile;
  def v2: walk(if type == "object" and has("schema_version")
               then .schema_version=2 else . end);
  def forge_binding($sha):
    {binding_id:"binding.forge",role:"forge",
     manifest_ref:{schema_version:2,kind:"adapter_manifest",id:"manifest.forge",sha256:$sha},
     execution_kind:"deterministic",adapter_instance_id:"instance.forge",
     principal_id:"principal.forge",execution_boundary_id:"boundary.forge",
     authority_ref:profile::scope("authority";"authority-forge";profile::sha("5")),
     package_ref:profile::blob("packages/forge.bin";"6"),skill_refs:[],requested_tools:[],
     requested_capabilities:["core.forge.materialize-candidate.v2"],
     requested_permissions:["core.perm.candidate-repository.write.v2",
       "core.perm.evidence.write.v1","core.perm.scratch.write.v1",
       "core.perm.target.read.v1"]};
  {forge:("1"*64),producer:("2"*64),publisher:("3"*64),
   reviewer:("4"*64),verifier:("5"*64)} as $shas |
  (profile::profile_doc($shas) | v2 | .body.profile_version="v2" |
   .body.bindings += [forge_binding($shas.forge)] |
   .body.bindings |= sort_by(.binding_id)) as $profile |
  profile::resolved_profile_doc($profile;("0"*64);$shas) | v2 |
  .body.bindings |= map(if .binding.role == "forge" then
    .adapter_implementation.version="v2" |
    .manifest_source=profile::source_value(
      profile::blob("manifests/forge.json";"a");"canonical-json";$shas.forge)
    else . end)
' >"$resolved"
resolved_sha=$(sha256_path "$resolved")

request="$tmp/request.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-profile-graph-fixtures" as profile;
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("producer";$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end) |
  .body.qualification_ref=profile::scope("qualification";"qualification.test";("7"*64)) |
  .body.prior_evidence_refs=[{stage_result_ref:{schema_version:2,kind:"stage_result",
    id:"result.previous",sha256:("8"*64)},evidence_id:"evidence.previous"}]
' >"$request"
request_sha=$(sha256_path "$request")
result="$tmp/result.json"
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$request" --slurpfile resolved "$resolved" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$result"
result_sha=$(sha256_path "$result")
presentation="$tmp/presentation.json"
"$jq_bin" -S -c -n --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
  --arg result_sha "$result_sha" --slurpfile request "$request" \
  --slurpfile resolved "$resolved" --slurpfile result "$result" '
  def doc($value;$sha):
    {schema_version:$value.schema_version,kind:$value.kind,id:$value.id,sha256:$sha};
  {schema_version:1,kind:"evidence_integrity_presentation",id:"evidence.presentation.test",
   body:{evidence:$result[0].body.evidence,
     prior_evidence_refs:$request[0].body.prior_evidence_refs,
     qualification_ref:{state:"present",value:$request[0].body.qualification_ref},
     request_ref:doc($request[0];$request_sha),
     resolved_profile_ref:doc($resolved[0];$resolved_sha),
     result_ref:doc($result[0];$result_sha)}}
' >"$presentation"

run_eval() {
  local name=$1 input=${2:-$presentation} runtime=${3:-$root} run_status=0
  local out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_set" "$request" "$resolved" "$result" "$input" >"$out" 2>"$err" ||
    run_status=$?
  if [ "$run_status" -ne 0 ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$run_status" >&2
    /bin/cat "$err" >&2
    fail "$name status"
  fi
  [ ! -s "$err" ] || fail "$name stderr"
  "$jq_bin" -S -c . "$out" >"$tmp/$name.canonical"
  /usr/bin/cmp -s "$out" "$tmp/$name.canonical" || fail "$name canonical"
}
run_eval_tuple() {
  local name=$1 request_input=$2 resolved_input=$3 result_input=$4 input=$5
  local runtime=${6:-$root} run_status=0
  local out="$tmp/$name.out" err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_set" "$request_input" "$resolved_input" "$result_input" "$input" \
    >"$out" 2>"$err" || run_status=$?
  if [ "$run_status" -ne 0 ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$run_status" >&2
    /bin/cat "$err" >&2
    fail "$name status"
  fi
  [ ! -s "$err" ] || fail "$name stderr"
  "$jq_bin" -S -c . "$out" >"$tmp/$name.canonical"
  /usr/bin/cmp -s "$out" "$tmp/$name.canonical" || fail "$name canonical"
}
expect_error() {
  local name=$1 expected=$2 policy_input=${3:-$policy_set} request_input=${4:-$request}
  local resolved_input=${5:-$resolved} result_input=${6:-$result}
  local presentation_input=${7:-$presentation} runtime=${8:-$root} status=0
  PATH="$bin:/usr/bin:/bin" "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$policy_input" "$request_input" "$resolved_input" "$result_input" \
    "$presentation_input" >"$tmp/$name.out" 2>"$tmp/$name.err" || status=$?
  if [ "$status" -eq 0 ] || [ -s "$tmp/$name.out" ] ||
     [ "$(/bin/cat "$tmp/$name.err")" != "$expected" ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$status" >&2
    /bin/cat "$tmp/$name.err" >&2
    fail "$name error"
  fi
  pass "$name"
}
pure_eval() {
  local input=$1 output=$2
  "$jq_bin" -S -c -n -f "$program" --slurpfile policy "$policy" \
    --slurpfile decision "$definition" --slurpfile policy_set "$policy_set" \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --slurpfile result "$result" --slurpfile presentation "$input" \
    --arg policy_sha "$policy_sha" --arg decision_sha "$definition_sha" \
    --arg policy_set_sha "$(sha256_path "$policy_set")" --arg request_sha "$request_sha" \
    --arg resolved_sha "$resolved_sha" --arg result_sha "$result_sha" \
    --arg presentation_sha "$(sha256_path "$input")" >"$output"
}
expect_pure_violation() {
  local name=$1 filter=$2 reason=$3 second_reason=${4:-}
  local input="$tmp/$name.presentation" output="$tmp/$name.pure"
  "$jq_bin" -S -c "$filter" "$presentation" >"$input"
  pure_eval "$input" "$output"
  "$jq_bin" -e --arg reason "$reason" --arg second "$second_reason" '
    .body.verdict=="violated" and (.body.reason_ids|index($reason)!=null) and
    ($second=="" or (.body.reason_ids|index($second)!=null)) and
    .body.authority_effect=="none" and .body.storage_effect=="none" and
    ((.body|has("grant_ref") or has("qualification_ref") or has("activation"))|not)
  ' "$output" >/dev/null || fail "$name"
  pass "$name"
}
expect_full_malformed_element() {
  local name=$1 filter=$2 mismatch_reason=$3 input="$tmp/$1.presentation"
  "$jq_bin" -S -c "$filter" "$presentation" >"$input"
  run_eval "$name" "$input"
  "$jq_bin" -e --arg mismatch "$mismatch_reason" '
    .body.verdict=="violated" and
    .body.reason_ids==(["evidence.presentation-malformed",$mismatch]|sort) and
    (.body.reason_ids|index("evidence.presentation-ambiguous")==null) and
    .body.authority_effect=="none" and .body.storage_effect=="none"
  ' "$tmp/$name.out" >/dev/null || fail "$name reasons"
  pass "$name"
}

run_eval valid
"$jq_bin" -e '.body.verdict=="satisfied" and
  .body.reason_ids==["evidence.integrity-satisfied"] and
  .body.qualification_semantics=="identity-only-unqualified" and
  (.body.evidence_refs|length)==1' "$tmp/valid.out" >/dev/null || fail 'valid output'
pass 'valid exact immutable evidence presentation'
run_eval portable-valid
/usr/bin/cmp -s "$tmp/valid.out" "$tmp/portable-valid.out" ||
  fail 'portable valid output'
pass "portable valid evaluation on $platform"

bash_env_hook="$tmp/conditional-bash-env.sh"
bash_env_sentinel="$tmp/conditional-bash-env.sentinel"
/usr/bin/printf '%s\n' \
  'case "$0" in' \
  '  */validate.sh|*/core-contract.sh)' \
  '    /usr/bin/printf "%s\\n" "${AWS_SECRET_ACCESS_KEY:-missing}" >'\
"\"$bash_env_sentinel\"" \
  '    ;;' \
  'esac' >"$bash_env_hook"
bash_env_status=0
BASH_ENV="$bash_env_hook" AWS_SECRET_ACCESS_KEY=must-not-reach-nested-bash \
  PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" "$request" \
  "$resolved" "$result" "$presentation" >"$tmp/bash-env.out" \
  2>"$tmp/bash-env.err" || bash_env_status=$?
if ! { [ "$bash_env_status" -eq 0 ] && [ -s "$tmp/bash-env.out" ] &&
       [ ! -s "$tmp/bash-env.err" ] && [ ! -e "$bash_env_sentinel" ] &&
       /usr/bin/cmp -s "$tmp/valid.out" "$tmp/bash-env.out"; }; then
  fail 'nested bash environment isolation'
fi
pass 'nested bash ignores conditional BASH_ENV and credential-like values'

expect_pure_violation result-moved '.body.result_ref.sha256=("0"*64)' \
  evidence.result-moved
expect_pure_violation request-moved '.body.request_ref.sha256=("0"*64)' \
  evidence.request-moved
expect_pure_violation resolved-moved '.body.resolved_profile_ref.sha256=("0"*64)' \
  evidence.resolved-profile-moved
expect_pure_violation current-mismatch '.body.evidence[0].proof_ref.sha256=("0"*64)' \
  evidence.current-mismatch
expect_pure_violation prior-stale '.body.prior_evidence_refs[0].stage_result_ref.sha256=("0"*64)' \
  evidence.prior-stale
expect_pure_violation qualification-mismatch '.body.qualification_ref={state:"absent"}' \
  evidence.qualification-mismatch
expect_pure_violation malformed-presentation '.body.evidence=1' \
  evidence.presentation-malformed
expect_pure_violation ambiguous-presentation '.body.evidence += [.body.evidence[0]]' \
  evidence.presentation-ambiguous

expect_pure_violation duplicate-evidence-id \
  '.body.evidence += [(.body.evidence[0] | .kind="behavioral")]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation duplicate-evidence-kind \
  '.body.evidence += [(.body.evidence[0] | .evidence_id="evidence.zzz")]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation reversed-evidence \
  '.body.evidence += [(.body.evidence[0] | .evidence_id="evidence.zzz" |
    .kind="behavioral")] | .body.evidence |= reverse' \
  evidence.presentation-malformed
expect_pure_violation duplicate-prior-key \
  '.body.prior_evidence_refs += [.body.prior_evidence_refs[0]]' \
  evidence.presentation-ambiguous evidence.presentation-malformed
expect_pure_violation reversed-prior \
  '.body.prior_evidence_refs += [(.body.prior_evidence_refs[0] |
    .stage_result_ref.sha256=("9"*64) | .stage_result_ref.id="result.zzz" |
    .evidence_id="evidence.zzz")] | .body.prior_evidence_refs |= reverse' \
  evidence.presentation-malformed
expect_pure_violation prior-document-alias \
  '.body.prior_evidence_refs += [(.body.prior_evidence_refs[0] |
    .stage_result_ref.id="result.alias" | .evidence_id="evidence.alias")] |
    .body.prior_evidence_refs |= sort_by([.stage_result_ref.sha256,.evidence_id])' \
  evidence.presentation-ambiguous

expect_full_malformed_element current-scalar '.body.evidence=[1]' \
  evidence.current-mismatch
expect_full_malformed_element current-null '.body.evidence=[null]' \
  evidence.current-mismatch
expect_full_malformed_element current-array '.body.evidence=[[]]' \
  evidence.current-mismatch
expect_full_malformed_element current-object-missing '.body.evidence=[{},{}]' \
  evidence.current-mismatch
expect_full_malformed_element current-object-wrong-type \
  '.body.evidence=[{evidence_id:1,kind:1,proof_ref:1,verdict:1},
    {evidence_id:1,kind:1,proof_ref:1,verdict:1}]' evidence.current-mismatch
expect_full_malformed_element prior-scalar '.body.prior_evidence_refs=[1]' \
  evidence.prior-stale
expect_full_malformed_element prior-null '.body.prior_evidence_refs=[null]' \
  evidence.prior-stale
expect_full_malformed_element prior-array '.body.prior_evidence_refs=[[]]' \
  evidence.prior-stale
expect_full_malformed_element prior-object-missing \
  '.body.prior_evidence_refs=[{},{}]' evidence.prior-stale
expect_full_malformed_element prior-object-wrong-type \
  '.body.prior_evidence_refs=[{evidence_id:1,stage_result_ref:1},
    {evidence_id:1,stage_result_ref:1}]' evidence.prior-stale
expect_full_malformed_element invalid-evidence-kind \
  '.body.evidence[0].kind="runtime-alt"' evidence.current-mismatch
expect_full_malformed_element invalid-proof-content-id \
  '.body.evidence[0].proof_ref.content_id="proof:invalid"' evidence.current-mismatch
expect_full_malformed_element invalid-proof-media-type \
  '.body.evidence[0].proof_ref.media_type=""' evidence.current-mismatch
expect_full_malformed_element invalid-qualification-subject \
  '.body.qualification_ref.value.subject_ref={}' evidence.qualification-mismatch

shared_request="$tmp/shared-proof.request"
"$jq_bin" -L "$root/scripts/test" -S -c -n --arg resolved_sha "$resolved_sha" '
  import "portable-core-profile-graph-fixtures" as profile;
  import "portable-core-stage-request-fixtures" as request;
  request::request_doc("verifier";$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end) |
  .body.qualification_ref=profile::scope("qualification";"qualification.shared";("7"*64))
' >"$shared_request"
shared_request_sha=$(sha256_path "$shared_request")
shared_result="$tmp/shared-proof.result"
shared_presentation="$tmp/shared-proof.presentation"
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$shared_request" --slurpfile resolved "$resolved" \
  --arg request_sha "$shared_request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::completed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$shared_result"
shared_result_sha=$(sha256_path "$shared_result")
"$jq_bin" -S -c -n --arg request_sha "$shared_request_sha" \
  --arg resolved_sha "$resolved_sha" --arg result_sha "$shared_result_sha" \
  --slurpfile request "$shared_request" --slurpfile resolved "$resolved" \
  --slurpfile result "$shared_result" '
  def doc($value;$sha):
    {schema_version:$value.schema_version,kind:$value.kind,id:$value.id,sha256:$sha};
  {schema_version:1,kind:"evidence_integrity_presentation",id:"evidence.presentation.shared",
   body:{evidence:$result[0].body.evidence,
     prior_evidence_refs:$request[0].body.prior_evidence_refs,
     qualification_ref:{state:"present",value:$request[0].body.qualification_ref},
     request_ref:doc($request[0];$request_sha),
     resolved_profile_ref:doc($resolved[0];$resolved_sha),
     result_ref:doc($result[0];$result_sha)}}
' >"$shared_presentation"
run_eval_tuple shared-proof "$shared_request" "$resolved" "$shared_result" \
  "$shared_presentation"
"$jq_bin" -e '
  .body.verdict=="satisfied" and
  .body.reason_ids==["evidence.integrity-satisfied"] and
  (.body.evidence_refs|length)==3 and
  (.body.evidence_refs|map(.proof_ref.sha256)|unique|length)==1 and
  (.body.evidence_refs|map(.proof_ref.content_id)|unique|length)==3
' "$tmp/shared-proof.out" >/dev/null || {
  /bin/cat "$tmp/shared-proof.out" >&2
  fail 'same proof bytes distinct logical refs'
}
pass 'same proof digest under distinct logical refs remains valid'

shared_mismatch="$tmp/shared-proof-mismatch.presentation"
"$jq_bin" -S -c \
  '.body.evidence[0].proof_ref.content_id="proof.presentation-only"' \
  "$shared_presentation" >"$shared_mismatch"
run_eval_tuple shared-proof-mismatch "$shared_request" "$resolved" "$shared_result" \
  "$shared_mismatch"
"$jq_bin" -e '
  .body.verdict=="violated" and
  (.body.reason_ids|index("evidence.current-mismatch")!=null)
' "$tmp/shared-proof-mismatch.out" >/dev/null || fail 'logical ref identity mismatch'
pass 'changed logical proof identity with retained digest fails closed'

absent_request="$tmp/qualification-absent.request"
absent_result="$tmp/qualification-absent.result"
absent_presentation="$tmp/qualification-absent.presentation"
absent_output="$tmp/qualification-absent.out"
"$jq_bin" -S -c 'del(.body.qualification_ref)' "$request" >"$absent_request"
absent_request_sha=$(sha256_path "$absent_request")
"$jq_bin" -L "$root/scripts/test" -S -c -n \
  --slurpfile request "$absent_request" --slurpfile resolved "$resolved" \
  --arg request_sha "$absent_request_sha" --arg resolved_sha "$resolved_sha" '
  import "portable-core-result-truth-fixtures" as result;
  result::failed_result_doc($request[0];$request_sha;$resolved[0];$resolved_sha) |
  walk(if type == "object" and has("schema_version") then .schema_version=2 else . end)
' >"$absent_result"
absent_result_sha=$(sha256_path "$absent_result")
"$jq_bin" -S -c --slurpfile request "$absent_request" \
  --slurpfile result "$absent_result" --arg request_sha "$absent_request_sha" \
  --arg result_sha "$absent_result_sha" '
  .body.qualification_ref={state:"absent"} |
  .body.request_ref={schema_version:$request[0].schema_version,kind:$request[0].kind,
    id:$request[0].id,sha256:$request_sha} |
  .body.result_ref={schema_version:$result[0].schema_version,kind:$result[0].kind,
    id:$result[0].id,sha256:$result_sha} |
  .body.evidence=$result[0].body.evidence
' "$presentation" >"$absent_presentation"
run_eval_tuple qualification-absent "$absent_request" "$resolved" "$absent_result" \
  "$absent_presentation"
"$jq_bin" -e '
  .body.verdict=="satisfied" and
  .body.qualification_observation=={state:"absent"} and
  .body.qualification_semantics=="identity-only-unqualified" and
  .body.authority_effect=="none" and .body.storage_effect=="none" and
  (.body.evidence_refs[0].verdict=="failed")
' "$absent_output" >/dev/null || fail 'absent qualification identity-only'
pass 'absent qualification and inconclusive proof remain identity-only'

malformed="$tmp/malformed.full"
"$jq_bin" -S -c '.body.evidence=1' "$presentation" >"$malformed"
run_eval malformed-full "$malformed"
"$jq_bin" -e '.body.verdict=="violated" and
  (.body.reason_ids|index("evidence.presentation-malformed")!=null)' \
  "$tmp/malformed-full.out" >/dev/null || fail 'malformed full output'
pass 'malformed presentation returns canonical fail-closed observation'

bad_result="$tmp/result.bad"
"$jq_bin" -S -c '.body.evidence[0].proof_ref.sha256="bad"' "$result" >"$bad_result"
expect_error malformed-core E_CORE "$policy_set" "$request" "$resolved" "$bad_result"

bad_policy_set="$tmp/policy-set.bad"
"$jq_bin" -S -c '.body.sections[] |=
  if .section_id=="evidence-integrity" then .decision_ref.sha256=("9"*64) else . end' \
  "$policy_set" >"$bad_policy_set"
expect_error policy-binding E_RELATION "$bad_policy_set"

link="$tmp/presentation-link.json"
/bin/ln -s "$presentation" "$link"
expect_error symlink-input E_RUNTIME "$policy_set" "$request" "$resolved" "$result" "$link"

/usr/bin/printf '{' >"$tmp/invalid.json"
expect_error invalid-json E_PARSE "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/invalid.json"
/usr/bin/printf '{}\n{}\n' >"$tmp/multi-root.json"
expect_error multi-root E_PARSE "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/multi-root.json"
"$jq_bin" . "$presentation" >"$tmp/noncanonical.json"
expect_error noncanonical E_CANONICAL "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/noncanonical.json"
/usr/bin/perl -e 'print "["x33,"0","]"x33,"\n"' >"$tmp/deep.json"
expect_error depth-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/deep.json"
"$jq_bin" -S -c '.id=("x"*8193)' "$presentation" >"$tmp/string-limit.json"
expect_error string-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/string-limit.json"
/usr/bin/perl -e 'print "{\"x\":\"","x"x1048576,"\"}\n"' >"$tmp/oversize.json"
expect_error byte-limit E_LIMIT "$policy_set" "$request" "$resolved" "$result" \
  "$tmp/oversize.json"

relative_bin="$tmp/relative-bin"
/bin/mkdir "$relative_bin"
/bin/cp "$jq_bin" "$relative_bin/jq"
status=0
(cd "$relative_bin" && PATH=".:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation") >"$tmp/relative.out" \
  2>"$tmp/relative.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$tmp/relative.out" ] &&
  [ "$(/bin/cat "$tmp/relative.err")" = E_RUNTIME ] || fail 'relative jq rejection'
pass 'relative jq interpreter rejected'

wrapper_bin="$tmp/wrapper-bin"
/bin/mkdir "$wrapper_bin"
/usr/bin/printf '%s\n' '#!/bin/bash' \
  'if [ "${1:-}" = --version ]; then echo jq-1.6; exit 0; fi' \
  'exec /usr/bin/jq "$@"' >"$wrapper_bin/jq"
/bin/chmod 0555 "$wrapper_bin/jq"
unbound_status=0
PATH="$wrapper_bin:/usr/bin:/bin" "$evaluator" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation" >"$tmp/unbound-jq.out" \
  2>"$tmp/unbound-jq.err" || unbound_status=$?
[ "$unbound_status" -ne 0 ] && [ ! -s "$tmp/unbound-jq.out" ] &&
  [ "$(/bin/cat "$tmp/unbound-jq.err")" = E_RUNTIME ] || fail 'unbound jq result'
pass 'only official jq 1.6 bytes are accepted'

inherited_scratch="$tmp/ystack-evidence.KEEPIT"
/bin/mkdir -m 0700 "$inherited_scratch"
: >"$inherited_scratch/owned-by-caller"
inherited_status=0
YSTACK_EVIDENCE_SCRATCH="$inherited_scratch" PATH="$bin:/usr/bin:/bin" \
  "$evaluator" invalid >"$tmp/inherited.out" 2>"$tmp/inherited.err" ||
  inherited_status=$?
[ "$inherited_status" -ne 0 ] && [ ! -s "$tmp/inherited.out" ] &&
  [ "$(/bin/cat "$tmp/inherited.err")" = E_USAGE ] &&
  [ -f "$inherited_scratch/owned-by-caller" ] || fail 'inherited scratch ownership'
pass 'bootstrap ignores inherited scratch cleanup authority'

/usr/bin/grep -Fq \
  '"$jq_bin" -n -e --arg policy_sha "$policy_sha" --arg launcher_sha "$launcher_sha"' \
  "$evaluator" || fail 'decision envelope null-input mode'
pass 'decision envelope explicitly uses null input'

copy_runtime() {
  local destination=$1 path
  /bin/mkdir -p "$destination/control/v1" "$destination/scripts" "$destination/core"
  for path in evidence-integrity-policy.json evidence-integrity-decision.json \
    evidence-integrity.jq evaluate-evidence-integrity.sh validate.sh policy-set.jq; do
    /bin/cp "$root/control/v1/$path" "$destination/control/v1/$path"
  done
  /bin/cp "$root/scripts/core-contract.sh" "$destination/scripts/core-contract.sh"
  /bin/cp -R "$root/core/v2" "$destination/core/v2"
}

forged_stage_case() {
  local stage=$1 jq_mode=${2:-fake}
  local suffix runtime="$tmp/forged-$stage-$jq_mode-runtime" scratch
  local sentinel="$tmp/forged-$1-$jq_mode-sentinel" physical_tmp origin live
  local driver_id live_id capability
  local scratch_id
  local private_driver_id
  local status=0
  case "$stage:$jq_mode" in
    supervisor:fake) suffix=FAKESV ;;
    worker:fake) suffix=FAKEWK ;;
    supervisor:official) suffix=OFFISV ;;
    worker:official) suffix=OFFIWK ;;
  esac
  scratch="$tmp/ystack-evidence.$suffix"
  copy_runtime "$runtime"
  runtime=$(CDPATH='' cd -P -- "$runtime" && pwd -P)
  /bin/mkdir -m 0700 "$scratch" "$scratch/bin"
  scratch=$(CDPATH='' cd -P -- "$scratch" && pwd -P)
  origin="$runtime/control/v1/evaluate-evidence-integrity.sh"
  /bin/cp "$origin" "$scratch/driver.sh"
  /bin/chmod 0500 "$scratch/driver.sh"
  if [ "$jq_mode" = official ]; then
    /bin/cp "$jq_bin" "$scratch/bin/jq"
  else
    /usr/bin/printf '%s\n' '#!/bin/bash' \
      "sentinel='$sentinel'" \
      'if [ "${1:-}" = --version ]; then echo jq-1.6; exit 0; fi' \
      ': >"$sentinel"' \
      'exec /usr/bin/jq "$@"' >"$scratch/bin/jq"
  fi
  /bin/chmod 0500 "$scratch/bin/jq"
  live="$scratch/bin/jq"
  scratch_id=$(test_directory_identity "$scratch")
  driver_id=$(test_path_identity "$origin")
  private_driver_id=$(test_path_identity "$scratch/driver.sh")
  live_id=$(test_path_identity "$live")
  physical_tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
  capability="$scratch/caller.cap"
  /usr/bin/mkfifo -m 0600 "$capability"
  if [ "$stage" = supervisor ]; then
    exec 8<>"$capability"
    /bin/rm -f "$capability"
    /usr/bin/printf 'supervisor\n' >&8
  else
    exec 9<>"$capability"
    /bin/rm -f "$capability"
    /usr/bin/printf 'worker\n' >&9
  fi
  /usr/bin/env -i LC_ALL=C PATH="$scratch/bin:/usr/bin:/bin" \
    YSTACK_EVIDENCE_STAGE="$stage" YSTACK_EVIDENCE_SCRATCH="$scratch" \
    YSTACK_EVIDENCE_SCRATCH_ID="$scratch_id" \
    YSTACK_EVIDENCE_ORIGIN="$origin" YSTACK_EVIDENCE_ORIGIN_ID="$driver_id" \
    YSTACK_EVIDENCE_PRIVATE_DRIVER_ID="$private_driver_id" \
    YSTACK_EVIDENCE_LIVE_JQ="$live" YSTACK_EVIDENCE_LIVE_JQ_ID="$live_id" \
    YSTACK_EVIDENCE_PRIVATE_JQ="$live" YSTACK_EVIDENCE_PRIVATE_JQ_ID="$live_id" \
    /bin/bash "$scratch/driver.sh" evaluate "$physical_tmp/policy-set.json" \
    "$physical_tmp/request.json" "$physical_tmp/resolved.json" \
    "$physical_tmp/result.json" "$physical_tmp/presentation.json" \
    >"$tmp/forged-$stage-$jq_mode.out" \
    2>"$tmp/forged-$stage-$jq_mode.err" || status=$?
  if [ "$stage" = supervisor ]; then exec 8>&-; else exec 9>&-; fi
  [ "$status" -ne 0 ] && [ ! -s "$tmp/forged-$stage-$jq_mode.out" ] &&
    [ ! -s "$tmp/forged-$stage-$jq_mode.err" ] &&
    [ ! -e "$sentinel" ] || fail "forged $stage stage"
  pass "forged $stage stage with $jq_mode jq cannot bypass parent capability"
}

forged_stage_case supervisor
forged_stage_case worker
forged_stage_case supervisor official
forged_stage_case worker official

direct_runtime="$tmp/direct-worker-runtime"
direct_scratch="$tmp/ystack-evidence.DIRECT"
copy_runtime "$direct_runtime"
/bin/mkdir -m 0700 "$direct_scratch" "$direct_scratch/bin" "$direct_scratch/worker"
direct_runtime=$(CDPATH='' cd -P -- "$direct_runtime" && pwd -P)
direct_scratch=$(CDPATH='' cd -P -- "$direct_scratch" && pwd -P)
direct_worker="$direct_scratch/worker"
direct_live_parent=$(CDPATH='' cd -P -- "${jq_bin%/*}" && pwd -P)
direct_live="$direct_live_parent/${jq_bin##*/}"
direct_input_parent=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
direct_origin="$direct_runtime/control/v1/evaluate-evidence-integrity.sh"
/bin/cp "$direct_origin" "$direct_scratch/driver.sh"
/bin/chmod 0500 "$direct_scratch/driver.sh"
/bin/cp "$jq_bin" "$direct_scratch/bin/jq"
/bin/chmod 0500 "$direct_scratch/bin/jq"
direct_origin_id=$(test_path_identity "$direct_origin")
direct_driver_id=$(test_path_identity "$direct_scratch/driver.sh")
direct_payload_sha=$(test_payload_sha "$direct_scratch/driver.sh" "$direct_driver_id")
direct_live_id=$(test_path_identity "$direct_live")
direct_jq_id=$(test_path_identity "$direct_scratch/bin/jq")
direct_worker_id=$(test_directory_identity "$direct_worker")
direct_status=0
/usr/bin/env -i LC_ALL=C PATH=/usr/bin:/bin TMPDIR="$direct_scratch" \
  HOME=/nonexistent /bin/bash -c \
  'source "$1" || exit 125; shift; declare -F worker_main >/dev/null && exit 124;
   worker_entry "$@"' direct-worker \
  "$direct_origin" "$direct_worker" "$direct_worker_id" "$direct_origin" \
  "$direct_origin_id" "$direct_scratch/driver.sh" "$direct_driver_id" \
  "$direct_payload_sha" "$direct_live" "$direct_live_id" \
  "$direct_scratch/bin/jq" "$direct_jq_id" \
  evaluate "$direct_input_parent/policy-set.json" "$direct_input_parent/request.json" \
  "$direct_input_parent/resolved.json" "$direct_input_parent/result.json" \
  "$direct_input_parent/presentation.json" \
  >"$tmp/direct-worker.out" 2>"$tmp/direct-worker.err" || direct_status=$?
if ! { [ "$direct_status" -eq 0 ] && [ -s "$tmp/direct-worker.out" ] &&
       [ ! -s "$tmp/direct-worker.err" ] && [ ! -e "$direct_worker" ] &&
       [ -z "$(/usr/bin/find "$direct_scratch" -name evaluation.json -print -quit)" ] &&
       "$jq_bin" -e '.kind=="evidence_integrity_evaluation"' \
         "$tmp/direct-worker.out" >/dev/null; }; then
  fail 'direct sourced worker cleanup'
fi
pass 'direct sourced worker has observation output but no retained worker effects'

mutated_decision_runtime="$tmp/mutated-decision-runtime"
copy_runtime "$mutated_decision_runtime"
"$jq_bin" -S -c '.body.semantics.authority_effect="unexpected"' \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json" \
  >"$mutated_decision_runtime/decision.next"
/bin/mv "$mutated_decision_runtime/decision.next" \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json"
mutated_decision_sha=$(sha256_path \
  "$mutated_decision_runtime/control/v1/evidence-integrity-decision.json")
mutated_decision_set="$tmp/mutated-decision-policy-set.json"
"$jq_bin" -S -c --arg digest "$mutated_decision_sha" '
  .body.sections[] |= if .section_id=="evidence-integrity"
    then .decision_ref.sha256=$digest else . end
' "$policy_set" >"$mutated_decision_set"
expect_error mutated-decision E_RELATION "$mutated_decision_set" "$request" \
  "$resolved" "$result" "$presentation" "$mutated_decision_runtime"

wait_exit() {
  local pid=$1 limit=${2:-500} attempt=0
  while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt "$limit" ]; do
    attempt=$((attempt + 1))
    /bin/sleep 0.01
  done
  ! kill -0 "$pid" 2>/dev/null
}
slice_until_path() {
  local pid=$1 search_root=$2 suffix=$3 attempt=0 found
  /bin/kill -STOP "$pid" 2>/dev/null || return 1
  while [ "$attempt" -lt 800 ]; do
    found=$(/usr/bin/find "$search_root" -type f -path "*/$suffix" -print -quit \
      2>/dev/null) || found=
    if [ -n "$found" ]; then /usr/bin/printf '%s\n' "$found"; return 0; fi
    kill -0 "$pid" 2>/dev/null || return 1
    /bin/kill -CONT "$pid" 2>/dev/null || return 1
    /bin/sleep 0.005
    /bin/kill -STOP "$pid" 2>/dev/null || return 1
    attempt=$((attempt + 1))
  done
  return 1
}

replace_identity_case() {
  local name=$1 target_kind=$2 expected=${3:-E_RELATION}
  local runtime="$tmp/$1-runtime" live_bin="$tmp/$1-bin"
  local scratch_root="$tmp/$1-scratch" process target observed suffix case_status=0
  copy_runtime "$runtime"
  /bin/mkdir "$live_bin" "$scratch_root"
  /bin/cp "$jq_bin" "$live_bin/jq"
  /bin/chmod 0555 "$live_bin/jq"
  TMPDIR="$scratch_root" PATH="$live_bin:/usr/bin:/bin" \
    "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
    "$request" "$resolved" "$result" "$presentation" >"$tmp/$name.out" \
    2>"$tmp/$name.err" &
  process=$!
  suffix=driver.sh
  case "$target_kind" in
    private-driver) suffix=bin/jq ;;
    live-jq|private-jq) suffix=evaluation.json ;;
  esac
  observed=$(slice_until_path "$process" "$scratch_root" "$suffix") || {
    /bin/kill -KILL "$process" 2>/dev/null || :
    wait "$process" 2>/dev/null || :
    fail "$name observed path"
  }
  case "$target_kind" in
    origin) target="$runtime/control/v1/evaluate-evidence-integrity.sh" ;;
    private-driver) target="${observed%/bin/jq}/driver.sh" ;;
    live-jq) target="$live_bin/jq" ;;
    private-jq) target="${observed%/worker/evaluation.json}/bin/jq" ;;
    *) fail "$name target" ;;
  esac
  /bin/cp "$target" "$target.next"
  /bin/chmod 0500 "$target.next"
  /bin/mv "$target.next" "$target"
  /bin/kill -CONT "$process" 2>/dev/null || :
  wait "$process" || case_status=$?
  if [ "$case_status" -eq 0 ] || [ -s "$tmp/$name.out" ] ||
     [ "$(/bin/cat "$tmp/$name.err")" != "$expected" ] ||
     [ -n "$(/usr/bin/find "$scratch_root" -mindepth 1 -print -quit)" ]; then
    /usr/bin/printf 'diagnostic %s status=%s stderr=' "$name" "$case_status" >&2
    /bin/cat "$tmp/$name.err" >&2
    fail "$name result"
  fi
  pass "$name"
}

replace_identity_case origin-driver-swap origin
replace_identity_case executing-driver-swap private-driver
replace_identity_case live-jq-swap live-jq
replace_identity_case private-jq-swap private-jq

program_runtime="$tmp/program-race-runtime"
program_scratch="$tmp/program-race-scratch"
copy_runtime "$program_runtime"
/bin/mkdir "$program_scratch"
TMPDIR="$program_scratch" PATH="$bin:/usr/bin:/bin" \
  "$program_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate "$policy_set" \
  "$request" "$resolved" "$result" "$presentation" >"$tmp/program-race.out" \
  2>"$tmp/program-race.err" &
program_pid=$!
program_snapshot=
program_attempt=0
while [ -z "$program_snapshot" ] && [ "$program_attempt" -lt 800 ]; do
  program_snapshot=$(/usr/bin/find "$program_scratch" -type f -name program.jq \
    -print -quit 2>/dev/null) || program_snapshot=
  [ -z "$program_snapshot" ] || break
  kill -0 "$program_pid" 2>/dev/null || break
  program_attempt=$((program_attempt + 1))
  /bin/sleep 0.005
done
[ -n "$program_snapshot" ] || fail 'program race snapshot'
/usr/bin/printf '\n' >>"$program_runtime/control/v1/evidence-integrity.jq"
program_status=0
wait "$program_pid" || program_status=$?
[ "$program_status" -ne 0 ] && [ ! -s "$tmp/program-race.out" ] &&
  [ "$(/bin/cat "$tmp/program-race.err")" = E_RELATION ] || fail 'program race'
pass 'live program mutation closes after no-follow snapshot'

find_owned_leader() {
  /bin/ps -axo pid=,ppid=,pgid= 2>/dev/null | /usr/bin/awk -v parent="$1" \
    '$2==parent && $1==$3 {print $1; exit}'
}
signal_scratch="$tmp/signal-scratch"
/bin/mkdir "$signal_scratch"
TMPDIR="$signal_scratch" PATH="$bin:/usr/bin:/bin" "$evaluator" evaluate \
  "$policy_set" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/signal.out" 2>"$tmp/signal.err" &
signal_pid=$!
signal_leader=
signal_attempt=0
while [ -z "$signal_leader" ] && [ "$signal_attempt" -lt 800 ]; do
  signal_leader=$(find_owned_leader "$signal_pid") || signal_leader=
  [ -z "$signal_leader" ] || break
  kill -0 "$signal_pid" 2>/dev/null || break
  signal_attempt=$((signal_attempt + 1))
  /bin/sleep 0.005
done
[[ "$signal_leader" =~ ^[1-9][0-9]*$ ]] || fail 'owned child leader'
/bin/kill -STOP -- "-$signal_leader"
/bin/kill -TERM "$signal_pid"
wait_exit "$signal_pid" 500 || fail 'signal bounded exit'
signal_status=0
wait "$signal_pid" || signal_status=$?
signal_live=$(/bin/ps -axo pgid=,state= 2>/dev/null | /usr/bin/awk \
  -v group="$signal_leader" '$1==group && $2!~/^Z/ {count++} END {print count+0}')
[ "$signal_status" -ne 0 ] && [ "$signal_live" -eq 0 ] &&
  [ ! -s "$tmp/signal.out" ] &&
  [ -z "$(/usr/bin/find "$signal_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'signal cleanup'
pass 'signal kills and reaps the stopped owned child group'

bind_modified_driver() {
  local runtime=$1 output_set=$2 driver_digest payload_digest decision_digest
  runtime=$(CDPATH='' cd -P -- "$runtime" && pwd -P)
  driver_digest=$(sha256_path "$runtime/control/v1/evaluate-evidence-integrity.sh")
  payload_digest=$(test_payload_sha \
    "$runtime/control/v1/evaluate-evidence-integrity.sh")
  "$jq_bin" -S -c --arg launcher "$driver_digest" --arg payload "$payload_digest" '
    .body.evaluator.trusted_launcher_ref.sha256=$launcher |
    .body.evaluator.evaluation_payload_ref.sha256=$payload
  ' \
    "$runtime/control/v1/evidence-integrity-decision.json" >"$runtime/decision.next"
  /bin/mv "$runtime/decision.next" \
    "$runtime/control/v1/evidence-integrity-decision.json"
  decision_digest=$(sha256_path "$runtime/control/v1/evidence-integrity-decision.json")
  "$jq_bin" -S -c --arg digest "$decision_digest" '
    .body.sections[] |= if .section_id=="evidence-integrity"
      then .decision_ref.sha256=$digest else . end
  ' "$policy_set" >"$output_set"
}

core_stall_runtime="$tmp/core-stall-runtime"
core_stall_scratch="$tmp/core-stall-scratch"
core_stall_helper="$tmp/core-stall-helper.sh"
core_stall_marker="$tmp/core-stall.pid"
copy_runtime "$core_stall_runtime"
/usr/bin/printf '%s\n' '#!/bin/bash' 'set -u' \
  'root=$2' \
  '/bin/mkdir "$root/stalled-core" || exit 1' \
  "/usr/bin/printf '%s\\n' \"\$\$\" >\"$core_stall_marker\"" \
  '/bin/kill -STOP "$$"' \
  'while :; do /bin/sleep 1; done' >"$core_stall_helper"
/bin/chmod 0500 "$core_stall_helper"
CORE_STALL_HELPER="$core_stall_helper" /usr/bin/perl -0777 -pi -e '
  my $helper=$ENV{"CORE_STALL_HELPER"};
  s{"\$mirror_core_driver" --accounted-validation}{"$helper" --accounted-validation}
    or exit 2;
' "$core_stall_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$core_stall_runtime" "$tmp/core-stall-set.json"
/bin/mkdir "$core_stall_scratch"
TMPDIR="$core_stall_scratch" PATH="$bin:/usr/bin:/bin" \
  "$core_stall_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/core-stall-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/core-stall.out" 2>"$tmp/core-stall.err" &
core_stall_parent=$!
core_stall_attempt=0
while [ ! -s "$core_stall_marker" ] && kill -0 "$core_stall_parent" 2>/dev/null &&
      [ "$core_stall_attempt" -lt "$late_marker_attempts" ]; do
  core_stall_attempt=$((core_stall_attempt + 1)); /bin/sleep 0.005
done
[ -s "$core_stall_marker" ] || fail 'nested core stall marker'
core_stall_pid=$(/bin/cat "$core_stall_marker")
[[ "$core_stall_pid" =~ ^[1-9][0-9]*$ ]] || fail 'nested core stall pid'
/bin/kill -TERM "$core_stall_parent"
wait_exit "$core_stall_parent" 500 || fail 'nested core bounded exit'
core_stall_status=0
wait "$core_stall_parent" || core_stall_status=$?
[ "$core_stall_status" -ne 0 ] && ! kill -0 "$core_stall_pid" 2>/dev/null &&
  [ ! -s "$tmp/core-stall.out" ] && [ ! -s "$tmp/core-stall.err" ] &&
  [ -z "$(/usr/bin/find "$core_stall_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'nested core signal cleanup'
pass 'stopped nested core is killed and worker-owned scratch is removed'

/usr/bin/grep -Fq 'ulimit -f 2048' "$evaluator" || fail 'child output cap'
/usr/bin/grep -Fq '[ "$attempt" -lt 1000 ]' "$evaluator" || fail 'child deadline'
pass 'child runtime and output are bounded'

launch_runtime="$tmp/launch-signal-runtime"
launch_scratch="$tmp/launch-signal-scratch"
launch_ready="$tmp/launch-signal.ready"
launch_go="$tmp/launch-signal.go"
copy_runtime "$launch_runtime"
/bin/mkdir "$launch_scratch"
LAUNCH_READY="$launch_ready" LAUNCH_GO="$launch_go" \
  /usr/bin/perl -0777 -pi -e '
    my $ready=$ENV{"LAUNCH_READY"}; my $go=$ENV{"LAUNCH_GO"};
    my $replacement = qq{  child=\$!\n} .
      qq{  /usr/bin/printf "%s\\n" "\$child" >"$ready" || exit 125\n} .
      qq{  while [ ! -e "$go" ]; do /bin/sleep 0.01; done};
    s{  child=\$!}{$replacement} or exit 2;
  ' "$launch_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$launch_runtime" "$tmp/launch-signal-set.json"
TMPDIR="$launch_scratch" PATH="$bin:/usr/bin:/bin" \
  "$launch_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/launch-signal-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/launch-signal.out" 2>"$tmp/launch-signal.err" &
launch_pid=$!
launch_attempt=0
while [ ! -s "$launch_ready" ] && kill -0 "$launch_pid" 2>/dev/null &&
      [ "$launch_attempt" -lt 1200 ]; do
  launch_attempt=$((launch_attempt + 1)); /bin/sleep 0.005
done
[ -s "$launch_ready" ] || fail 'launch signal ready'
launch_child=$(/bin/cat "$launch_ready")
[[ "$launch_child" =~ ^[1-9][0-9]*$ ]] || fail 'launch signal child'
/bin/kill -TERM "$launch_pid"
: >"$launch_go"
wait_exit "$launch_pid" 500 || fail 'launch signal bounded exit'
launch_status=0
wait "$launch_pid" || launch_status=$?
launch_live=$(/bin/ps -axo pgid=,state= 2>/dev/null | /usr/bin/awk \
  -v group="$launch_child" '$1==group && $2!~/^Z/ {count++} END {print count+0}')
[ "$launch_status" -ne 0 ] && ! kill -0 "$launch_child" 2>/dev/null &&
  [ "$launch_live" -eq 0 ] && [ ! -s "$tmp/launch-signal.out" ] &&
  [ ! -s "$tmp/launch-signal.err" ] &&
  [ -z "$(/usr/bin/find "$launch_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'launch signal cleanup'
pass 'launch-window signals wait for owned child registration and reap'

output_runtime="$tmp/output-swap-runtime"
output_scratch="$tmp/output-swap-scratch"
copy_runtime "$output_runtime"
/usr/bin/perl -0777 -pi -e '
  s{capture_path_matches "\$scratch/evaluation\.json" "\$evaluation_capture_key" \|\|}{
    /bin/mv "\$scratch/evaluation.json" "\$scratch/evaluation.saved" || exit 1;
    /bin/ln -s "\$scratch/evaluation.saved" "\$scratch/evaluation.json" || exit 1;
    capture_path_matches "\$scratch/evaluation.json" "\$evaluation_capture_key" ||
  } or exit 2
' "$output_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$output_runtime" "$tmp/output-swap-set.json"
/bin/mkdir "$output_scratch"
output_status=0
TMPDIR="$output_scratch" PATH="$bin:/usr/bin:/bin" \
  "$output_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/output-swap-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/output-swap.out" 2>"$tmp/output-swap.err" || output_status=$?
[ "$output_status" -ne 0 ] && [ ! -s "$tmp/output-swap.out" ] &&
  [ "$(/bin/cat "$tmp/output-swap.err")" = E_RUNTIME ] &&
  [ -z "$(/usr/bin/find "$output_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'output symlink swap'
pass 'output path replacement is rejected before cleanup and emission'

post_capture_runtime="$tmp/post-capture-runtime"
post_capture_scratch="$tmp/post-capture-scratch"
post_capture_ready="$tmp/post-capture.ready"
post_capture_go="$tmp/post-capture.go"
copy_runtime "$post_capture_runtime"
POST_CAPTURE_READY="$post_capture_ready" POST_CAPTURE_GO="$post_capture_go" \
  /usr/bin/perl -0777 -pi -e '
    my $ready=$ENV{"POST_CAPTURE_READY"}; my $go=$ENV{"POST_CAPTURE_GO"};
    my $replacement = qq{    worker_status=\$?\n} .
      qq{  /usr/bin/printf "ready\\n" >"$ready" || exit 1\n} .
      qq{  while [ ! -e "$go" ]; do /bin/sleep 0.01; done\n} .
      qq{  if [ -n};
    s{    worker_status=\$\?\n  if \[ -n}{$replacement} or exit 2;
  ' "$post_capture_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$post_capture_runtime" "$tmp/post-capture-set.json"
/bin/mkdir "$post_capture_scratch"
TMPDIR="$post_capture_scratch" PATH="$bin:/usr/bin:/bin" \
  "$post_capture_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/post-capture-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/post-capture.out" 2>"$tmp/post-capture.err" &
post_capture_pid=$!
post_capture_attempt=0
while [ ! -e "$post_capture_ready" ] && kill -0 "$post_capture_pid" 2>/dev/null &&
      [ "$post_capture_attempt" -lt "$late_marker_attempts" ]; do
  post_capture_attempt=$((post_capture_attempt + 1)); /bin/sleep 0.005
done
[ -e "$post_capture_ready" ] || fail 'post-capture replacement ready'
post_capture_root=$(/usr/bin/find "$post_capture_scratch" -mindepth 1 -maxdepth 1 \
  -type d -name 'ystack-evidence.??????' -print -quit)
[ -n "$post_capture_root" ] || fail 'post-capture replacement root'
/bin/mv "$post_capture_root/io/worker.out" "$post_capture_root/io/worker.saved"
/usr/bin/printf '{"forged":true}\n' >"$post_capture_root/io/worker.out"
: >"$post_capture_go"
post_capture_status=0
wait "$post_capture_pid" || post_capture_status=$?
[ "$post_capture_status" -ne 0 ] && [ ! -s "$tmp/post-capture.out" ] &&
  [ "$(/bin/cat "$tmp/post-capture.err")" = E_RUNTIME ] &&
  [ -z "$(/usr/bin/find "$post_capture_scratch" -mindepth 1 -print -quit)" ] ||
  fail 'post-capture replacement result'
pass 'post-creation output replacement is rejected before consumption'

cleanup_runtime="$tmp/cleanup-failure-runtime"
cleanup_scratch="$tmp/cleanup-failure-scratch"
copy_runtime "$cleanup_runtime"
/usr/bin/perl -0777 -pi -e 's/cleanup\(\) \{\n/cleanup() {\n  return 1;\n/' \
  "$cleanup_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$cleanup_runtime" "$tmp/cleanup-failure-set.json"
/bin/mkdir "$cleanup_scratch"
cleanup_status=0
TMPDIR="$cleanup_scratch" PATH="$bin:/usr/bin:/bin" \
  "$cleanup_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/cleanup-failure-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/cleanup-failure.out" 2>"$tmp/cleanup-failure.err" || cleanup_status=$?
[ "$cleanup_status" -ne 0 ] && [ ! -s "$tmp/cleanup-failure.out" ] ||
  fail 'cleanup failure output'
pass 'cleanup failure remains non-success and emits no stdout'

cleanup_error_scratch="$tmp/cleanup-error-scratch"
/bin/mkdir "$cleanup_error_scratch"
cleanup_error_status=0
TMPDIR="$cleanup_error_scratch" PATH="$bin:/usr/bin:/bin" \
  "$cleanup_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/cleanup-failure-set.json" "$request" "$resolved" "$result" \
  "$tmp/invalid.json" >"$tmp/cleanup-error.out" 2>"$tmp/cleanup-error.err" ||
  cleanup_error_status=$?
[ "$cleanup_error_status" -ne 0 ] && [ ! -s "$tmp/cleanup-error.out" ] &&
  [ ! -s "$tmp/cleanup-error.err" ] || fail 'cleanup failure error-path output'
pass 'error paths emit nothing when scratch cleanup fails'

capture_swap_case() {
  local mode=$1 runtime="$tmp/capture-$1-runtime"
  local parent="$tmp/capture-$1-parent" outside="$tmp/capture-$1-outside"
  local ready="$tmp/capture-$1.ready" go="$tmp/capture-$1.go"
  local process scratch_path status=0 attempt=0
  copy_runtime "$runtime"
  /bin/mkdir "$parent" "$outside"
  /usr/bin/printf 'outside-unchanged\n' >"$outside/sentinel"
  CAPTURE_READY="$ready" CAPTURE_GO="$go" /usr/bin/perl -0777 -pi -e '
    my $ready=$ENV{"CAPTURE_READY"}; my $go=$ENV{"CAPTURE_GO"};
    my $replacement = qq{  /usr/bin/printf "ready\\n" >"$ready" || exit 1\n} .
      qq{  while [ ! -e "$go" ]; do /bin/sleep 0.01; done\n} .
      qq{  run_child scratch_capture_prepared};
    s{  run_child scratch_capture_prepared}{$replacement} or exit 2;
  ' "$runtime/control/v1/evaluate-evidence-integrity.sh"
  bind_modified_driver "$runtime" "$tmp/capture-$1-set.json"
  TMPDIR="$parent" PATH="$bin:/usr/bin:/bin" \
    "$runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
    "$tmp/capture-$1-set.json" "$request" "$resolved" "$result" "$presentation" \
    >"$tmp/capture-$1.out" 2>"$tmp/capture-$1.err" &
  process=$!
  while [ ! -e "$ready" ] && kill -0 "$process" 2>/dev/null &&
        [ "$attempt" -lt 1200 ]; do
    attempt=$((attempt + 1)); /bin/sleep 0.005
  done
  [ -e "$ready" ] || fail "capture $mode ready"
  scratch_path=$(/usr/bin/find "$parent" -mindepth 1 -maxdepth 1 -type d \
    -name 'ystack-evidence.??????' -print -quit)
  [ -n "$scratch_path" ] || fail "capture $mode scratch"
  case "$mode" in
    ancestor)
      /bin/mv "$scratch_path/io" "$scratch_path/io.saved"
      /bin/ln -s "$outside" "$scratch_path/io"
      ;;
    leaf)
      /bin/mv "$scratch_path/io/worker.out" "$scratch_path/io/worker.out.saved"
      /bin/ln -s "$outside/sentinel" "$scratch_path/io/worker.out"
      ;;
    *) fail "capture $mode mode" ;;
  esac
  : >"$go"
  wait "$process" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$tmp/capture-$1.out" ] &&
    [ "$(/bin/cat "$tmp/capture-$1.err")" = E_RUNTIME ] &&
    [ "$(/bin/cat "$outside/sentinel")" = outside-unchanged ] &&
    [ ! -e "$outside/worker.out" ] && [ ! -e "$outside/worker.err" ] &&
    [ -z "$(/usr/bin/find "$parent" -mindepth 1 -print -quit)" ] ||
    fail "capture $mode result"
  pass "anchored scratch capture rejects $mode replacement"
}

capture_swap_case leaf
capture_swap_case ancestor

bin_swap_runtime="$tmp/bin-swap-runtime"
bin_swap_parent="$tmp/bin-swap-parent"
bin_swap_outside="$tmp/bin-swap-outside"
bin_swap_ready="$tmp/bin-swap.ready"
bin_swap_go="$tmp/bin-swap.go"
copy_runtime "$bin_swap_runtime"
/bin/mkdir "$bin_swap_parent" "$bin_swap_outside"
/usr/bin/printf 'outside-unchanged\n' >"$bin_swap_outside/sentinel"
BIN_SWAP_READY="$bin_swap_ready" BIN_SWAP_GO="$bin_swap_go" \
  /usr/bin/perl -0777 -pi -e '
    my $ready=$ENV{"BIN_SWAP_READY"}; my $go=$ENV{"BIN_SWAP_GO"};
    my $replacement = qq{scratch_mkdirs bin io worker || emit_error E_RUNTIME\n} .
      qq{/usr/bin/printf "ready\\n" >"$ready" || exit 1\n} .
      qq{while [ ! -e "$go" ]; do /bin/sleep 0.01; done};
    s{scratch_mkdirs bin io worker \|\| emit_error E_RUNTIME}{$replacement} or exit 2;
  ' "$bin_swap_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$bin_swap_runtime" "$tmp/bin-swap-set.json"
TMPDIR="$bin_swap_parent" PATH="$bin:/usr/bin:/bin" \
  "$bin_swap_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/bin-swap-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/bin-swap.out" 2>"$tmp/bin-swap.err" &
bin_swap_pid=$!
bin_swap_attempt=0
while [ ! -e "$bin_swap_ready" ] && kill -0 "$bin_swap_pid" 2>/dev/null &&
      [ "$bin_swap_attempt" -lt 1200 ]; do
  bin_swap_attempt=$((bin_swap_attempt + 1)); /bin/sleep 0.005
done
[ -e "$bin_swap_ready" ] || fail 'bin ancestor swap ready'
bin_swap_scratch=$(/usr/bin/find "$bin_swap_parent" -mindepth 1 -maxdepth 1 \
  -type d -name 'ystack-evidence.??????' -print -quit)
[ -n "$bin_swap_scratch" ] || fail 'bin ancestor swap scratch'
/bin/mv "$bin_swap_scratch/bin" "$bin_swap_scratch/bin.saved"
/bin/ln -s "$bin_swap_outside" "$bin_swap_scratch/bin"
: >"$bin_swap_go"
bin_swap_status=0
wait "$bin_swap_pid" || bin_swap_status=$?
[ "$bin_swap_status" -ne 0 ] && [ ! -s "$tmp/bin-swap.out" ] &&
  [ "$(/bin/cat "$tmp/bin-swap.err")" = E_RUNTIME ] &&
  [ "$(/bin/cat "$bin_swap_outside/sentinel")" = outside-unchanged ] &&
  [ ! -e "$bin_swap_outside/jq" ] &&
  [ -z "$(/usr/bin/find "$bin_swap_parent" -mindepth 1 -print -quit)" ] ||
  fail 'bin ancestor swap result'
pass 'scratch bin ancestor swap cannot create or chmod outside files'

scratch_swap_runtime="$tmp/scratch-swap-runtime"
scratch_swap_parent="$tmp/scratch-swap-parent"
scratch_swap_ready="$tmp/scratch-swap.ready"
scratch_swap_go="$tmp/scratch-swap.go"
copy_runtime "$scratch_swap_runtime"
/bin/mkdir "$scratch_swap_parent"
SCRATCH_READY="$scratch_swap_ready" SCRATCH_GO="$scratch_swap_go" \
  /usr/bin/perl -0777 -pi -e '
    my $ready=$ENV{"SCRATCH_READY"}; my $go=$ENV{"SCRATCH_GO"};
    my $replacement = qq{  /usr/bin/printf "ready\\n" >"$ready" || exit 1;\n} .
      qq{  while [ ! -e "$go" ]; do /bin/sleep 0.01; done\n} .
      qq{  if ! cleanup; then exit 1; fi};
    s{  if ! cleanup; then exit 1; fi}{$replacement} or exit 2;
  ' "$scratch_swap_runtime/control/v1/evaluate-evidence-integrity.sh"
bind_modified_driver "$scratch_swap_runtime" "$tmp/scratch-swap-set.json"
TMPDIR="$scratch_swap_parent" PATH="$bin:/usr/bin:/bin" \
  "$scratch_swap_runtime/control/v1/evaluate-evidence-integrity.sh" evaluate \
  "$tmp/scratch-swap-set.json" "$request" "$resolved" "$result" "$presentation" \
  >"$tmp/scratch-swap.out" 2>"$tmp/scratch-swap.err" &
scratch_swap_pid=$!
scratch_swap_attempt=0
while [ ! -e "$scratch_swap_ready" ] && kill -0 "$scratch_swap_pid" 2>/dev/null &&
      [ "$scratch_swap_attempt" -lt "$late_marker_attempts" ]; do
  scratch_swap_attempt=$((scratch_swap_attempt + 1)); /bin/sleep 0.005
done
[ -e "$scratch_swap_ready" ] || fail 'scratch swap ready'
scratch_original=$(/usr/bin/find "$scratch_swap_parent" -mindepth 1 -maxdepth 1 \
  -type d -name 'ystack-evidence.??????' -print -quit)
[ -n "$scratch_original" ] || fail 'scratch swap original'
/bin/mv "$scratch_original" "$scratch_original.saved"
/bin/mkdir -m 0700 "$scratch_original"
: >"$scratch_original/replacement"
: >"$scratch_swap_go"
scratch_swap_status=0
wait "$scratch_swap_pid" || scratch_swap_status=$?
[ "$scratch_swap_status" -ne 0 ] && [ ! -s "$tmp/scratch-swap.out" ] &&
  [ ! -s "$tmp/scratch-swap.err" ] && [ -d "$scratch_original.saved" ] &&
  [ -f "$scratch_original/replacement" ] || fail 'scratch swap cleanup identity'
pass 'scratch path replacement cannot authorize cleanup or output'

for required in control/v1/evidence-integrity-policy.json \
  control/v1/evidence-integrity-decision.json control/v1/evidence-integrity.jq \
  control/v1/evaluate-evidence-integrity.sh \
  scripts/test/control-evidence-integrity.test.sh; do
  [ "$(/usr/bin/grep -Fxc "$required" "$root/ci/required-files.txt")" -eq 1 ] ||
    fail "manifest $required"
done
/usr/bin/grep -Fq 'Inactive evidence-integrity evaluator' "$root/README.md" ||
  fail 'README docs'
/usr/bin/grep -Fq 'control-evidence-integrity.test.sh' "$root/RESTORE.md" ||
  fail 'RESTORE docs'
pass 'restore manifest and docs'

/usr/bin/printf 'control evidence integrity: %s passed\n' "$passes"
