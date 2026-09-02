#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
policy_set="$root/control/v1/control-policy-set.json"
validator="$root/control/v1/validate.sh"
core_wrapper="$root/scripts/core-contract.sh"
core_registry="$root/core/v2/generation-registry.json"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-control-rollup-test.XXXXXX")
tmp=$(CDPATH='' cd -P -- "$tmp" && pwd -P)
download=''

cleanup() {
  if [ -n "$download" ] && [ -f "$download" ]; then
    /bin/rm -f -- "$download"
  fi
  /bin/rm -rf -- "$tmp"
}
trap cleanup EXIT
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passes=0
pass() { passes=$((passes + 1)); /usr/bin/printf 'ok %s - %s\n' "$passes" "$1"; }
sha256_path() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
sha256_text() {
  /usr/bin/printf '%s' "$1" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
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
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" \
    -o "$download"
  [ "$(sha256_path "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
[ "$(sha256_path "$jq_cache")" = "$jq_sha" ] || fail 'jq digest'
bin="$tmp/bin"
/bin/mkdir -m 0700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

"$jq_bin" -s -S -c 'if length==1 then .[0] else error("root-count") end' \
  "$policy_set" >"$tmp/canonical.json" || fail 'shipped set parse'
/usr/bin/cmp -s "$policy_set" "$tmp/canonical.json" || fail 'canonical shipped set'
validator_out="$tmp/validator.out"
validator_err="$tmp/validator.err"
PATH="$bin:/usr/bin:/bin" "$validator" validate "$policy_set" \
  >"$validator_out" 2>"$validator_err" || fail 'shipped set validation'
[ ! -s "$validator_out" ] && [ ! -s "$validator_err" ] || fail 'validator output'
pass 'canonical shipped set passes the v1 validator'

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" "$core_wrapper") ||
  fail 'selected generation'
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || fail 'selected generation shape'
"$jq_bin" -e --arg generation "$generation" '
  [.[] | select(.generation_id==$generation and
    .semantic_identity=="core.contracts.v2")] | length==1
' "$core_registry" >/dev/null || fail 'selected generation registry identity'
generation_sha=$(sha256_text "$generation")

closure_members="$tmp/core-closure-members.tsv"
closure_paths=(
  scripts/core-contract.sh
  core/v2/generation-registry.json
  "core/v2/generations/$generation/contracts.jq"
  "core/v2/generations/$generation/core-ingress.sh"
  "core/v2/generations/$generation/modules/profile_graph.jq"
  "core/v2/generations/$generation/modules/result_facts.jq"
  "core/v2/generations/$generation/modules/result_truth.jq"
  "core/v2/generations/$generation/modules/schema.jq"
  "core/v2/generations/$generation/modules/stage_request.jq"
)
: >"$closure_members"
for closure_path in "${closure_paths[@]}"; do
  /usr/bin/printf '%s\t%s\n' "$closure_path" \
    "$(sha256_path "$root/$closure_path")" >>"$closure_members"
done
closure_descriptor=$("$jq_bin" -Rn -S -c --arg generation_sha "$generation_sha" '
  [inputs | split("\t") | {path:.[0],sha256:.[1]}] as $members |
  {schema_version:1,kind:"core_contract_package_closure",
   semantic_identity:"core.contracts.v2",
   selected_generation_id_sha256:$generation_sha,members:$members}
' <"$closure_members")
core_package_sha=$(sha256_text "$closure_descriptor")
"$jq_bin" -e --arg generation "$generation" --arg package_sha "$core_package_sha" '
  .id=="control-policy-set.v1" and
  .body.core_contract=={
    generation_id:$generation,
    package_ref:{content_id:"core-contract-package.v2",
      media_type:"application/vnd.ystack.core-contract+json",sha256:$package_sha},
    semantic_identity:"core.contracts.v2"}
' "$policy_set" >/dev/null || fail 'shared core contract closure'
pass 'selected core generation and package closure are exact'

sections=(
  credential-policy duty-separation evidence-integrity
  kill-switch risk-gates sandbox
)
policy_files=(
  credential-policy.json duty-separation-policy.json evidence-integrity-policy.json
  kill-switch-policy.json risk-gates-policy.json sandbox-policy.json
)
decision_files=(
  credential-policy-decision.json duty-separation-decision.json
  evidence-integrity-decision.json kill-switch-decision.json
  risk-gates-decision.json sandbox-decision.json
)
policy_media=application/vnd.ystack.control-policy+json
decision_media=application/vnd.ystack.control-decision+json

check_closure() {
  local input=$1 index section policy decision policy_sha decision_sha
  PATH="$bin:/usr/bin:/bin" "$validator" validate "$input" >/dev/null 2>&1 || return 1
  "$jq_bin" -e --arg generation "$generation" --arg package_sha "$core_package_sha" '
    .body.core_contract=={
      generation_id:$generation,
      package_ref:{content_id:"core-contract-package.v2",
        media_type:"application/vnd.ystack.core-contract+json",sha256:$package_sha},
      semantic_identity:"core.contracts.v2"}
  ' "$input" >/dev/null || return 1
  for index in 0 1 2 3 4 5; do
    section=${sections[$index]}
    policy="$root/control/v1/${policy_files[$index]}"
    decision="$root/control/v1/${decision_files[$index]}"
    policy_sha=$(sha256_path "$policy")
    decision_sha=$(sha256_path "$decision")
    "$jq_bin" -e --argjson index "$index" --arg section "$section" \
      --arg policy_media "$policy_media" --arg decision_media "$decision_media" \
      --arg policy_sha "$policy_sha" --arg decision_sha "$decision_sha" '
      .body.sections[$index]=={
        decision_ref:{content_id:("control-decision."+$section),
          media_type:$decision_media,sha256:$decision_sha},
        policy_ref:{content_id:("control-policy."+$section),
          media_type:$policy_media,sha256:$policy_sha},section_id:$section}
    ' "$input" >/dev/null || return 1
  done
}

direct_core_count=0
for index in 0 1 2 3 4 5; do
  section=${sections[$index]}
  policy="$root/control/v1/${policy_files[$index]}"
  decision="$root/control/v1/${decision_files[$index]}"
  policy_sha=$(sha256_path "$policy")
  decision_sha=$(sha256_path "$decision")
  "$jq_bin" -e --arg section "$section" --arg policy_sha "$policy_sha" '
    .schema_version==1 and .id==("control-decision."+$section) and
    .body.activation_state=="inactive" and .body.fail_mode=="closed" and
    .body.decision=="allow-observation-only-evaluation" and
    .body.policy_ref=={content_id:("control-policy."+$section),
      media_type:"application/vnd.ystack.control-policy+json",sha256:$policy_sha} and
    .body.semantics.authority_effect=="none" and
    (.body.semantics.qualification_effect // "none")=="none" and
    (.body.semantics.storage_effect // "none")=="none" and
    (.body.semantics.candidate_execution // "none")=="none" and
    (.body.semantics.credential_access // "none")=="none" and
    (.body.semantics.network_access // "none")=="none"
  ' "$decision" >/dev/null || fail "inactive decision boundary $section"
  "$jq_bin" -e --arg section "$section" '
    .schema_version==1 and .id==("control-policy."+$section) and
    .body.policy_version=="v1" and .body.activation_state=="inactive" and
    .body.fail_mode=="closed" and .body.evaluation_mode=="observation-only"
  ' "$policy" >/dev/null || fail "inactive policy boundary $section"
  if "$jq_bin" -e '.body | has("core_contract")' "$policy" >/dev/null; then
    direct_core_count=$((direct_core_count + 1))
    "$jq_bin" -e --arg generation_sha "$generation_sha" \
      --arg package_sha "$core_package_sha" '
      .body.core_contract=={
        generation_id_sha256:$generation_sha,
        package_ref:{content_id:"core-contract-package.v2",
          media_type:"application/vnd.ystack.core-contract+json",sha256:$package_sha},
        semantic_identity:"core.contracts.v2"}
    ' "$policy" >/dev/null || fail "direct core contract $section"
  else
    case "$section" in
      kill-switch|sandbox) ;;
      *) fail "missing direct core contract $section" ;;
    esac
  fi
  [ "$policy_sha" = "$("$jq_bin" -er --argjson index "$index" \
    '.body.sections[$index].policy_ref.sha256' "$policy_set")" ] ||
    fail "policy digest $section"
  [ "$decision_sha" = "$("$jq_bin" -er --argjson index "$index" \
    '.body.sections[$index].decision_ref.sha256' "$policy_set")" ] ||
    fail "decision digest $section"
done
[ "$direct_core_count" -eq 4 ] || fail 'direct core contract count'
check_closure "$policy_set" || fail 'complete shipped closure'
pass 'all twelve refs and six inactive decision boundaries are exact'

mutate() {
  local name=$1 filter=$2
  "$jq_bin" -S -c "$filter" "$policy_set" >"$tmp/$name.json"
  /usr/bin/printf '%s\n' "$tmp/$name.json"
}
expect_closure_reject() {
  local name=$1 input=$2 out err
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$validator" validate "$input" >"$out" 2>"$err" ||
    fail "$name validator should accept shape"
  [ ! -s "$out" ] && [ ! -s "$err" ] || fail "$name validator output"
  if check_closure "$input"; then fail "$name closure accepted"; fi
  pass "$name fails the exact shipped closure"
}
expect_validator_reject() {
  local name=$1 input=$2 out err status=0
  out="$tmp/$name.out"
  err="$tmp/$name.err"
  PATH="$bin:/usr/bin:/bin" "$validator" validate "$input" >"$out" 2>"$err" || status=$?
  [ "$status" -ne 0 ] && [ ! -s "$out" ] &&
    [ "$(/bin/cat "$err")" = E_RELATION ] || fail "$name validator closure"
  if check_closure "$input"; then fail "$name closure accepted"; fi
  pass "$name fails closed in the validator"
}

for index in 0 1 2 3 4 5; do
  for ref_field in policy_ref decision_ref; do
    name="ref-$index-$ref_field"
    expect_closure_reject "$name" "$(mutate "$name" \
      ".body.sections[$index].$ref_field.sha256=(\"0\"*64)")"
  done
done
expect_closure_reject core-generation "$(mutate core-generation \
  '.body.core_contract.generation_id=("g-"+("0"*64))')"
expect_closure_reject core-package "$(mutate core-package \
  '.body.core_contract.package_ref.sha256=("0"*64)')"
expect_closure_reject core-identity "$(mutate core-identity \
  '.body.core_contract.semantic_identity="core.contracts.v3"')"
expect_validator_reject reordered "$(mutate reordered \
  '.body.sections[0:2] |= reverse')"
expect_validator_reject duplicate "$(mutate duplicate \
  '.body.sections[1]=.body.sections[0]')"
expect_validator_reject activation "$(mutate activation \
  '.body.activation_state="active"')"
expect_validator_reject fail-mode "$(mutate fail-mode \
  '.body.fail_mode="open"')"

for required in control/v1/control-policy-set.json \
  scripts/test/control-foundation-rollup.test.sh; do
  [ "$(/usr/bin/grep -Fxc "$required" "$root/ci/required-files.txt")" -eq 1 ] ||
    fail "manifest $required"
done
/usr/bin/grep -Fq 'Inactive Control foundation roll-up' "$root/README.md" ||
  fail 'README docs'
/usr/bin/grep -Fq 'control-foundation-rollup.test.sh' "$root/RESTORE.md" ||
  fail 'RESTORE docs'
pass 'restore manifest and docs'
/usr/bin/printf 'control foundation roll-up: %s focused checks passed\n' "$passes"
