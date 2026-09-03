#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
protocol="$root/adapters/local-git-materializer/v1/protocol.jq"
fixture_builder="$root/scripts/test/local-git-materializer-fixtures.sh"
test_tmp_base=${TMPDIR:-/tmp}
tmp=$(/usr/bin/mktemp -d "${test_tmp_base%/}/ystack-materializer-protocol.XXXXXX")
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
jq_source="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$jq_asset"
[ -f "$jq_source" ] && [ ! -L "$jq_source" ] && [ "$(sha_file "$jq_source")" = "$jq_sha" ] || {
  printf '%s\n' 'FAIL: pinned jq 1.6 is required' >&2
  exit 1
}
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
if [ "$platform" = Darwin:arm64 ]; then
  printf '%s\n' '#!/bin/bash' "exec /usr/bin/arch -x86_64 '$jq_source' \"\$@\"" > "$bin/jq"
else
  /bin/cp "$jq_source" "$bin/jq"
fi
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
export PATH="$bin:/usr/bin:/bin"
[ "$($jq_bin --version)" = jq-1.6 ] || exit 1
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\{64\}\)'$/\1/p" \
  "$root/scripts/core-contract.sh")
[[ "$generation" =~ ^g-[0-9a-f]{64}$ ]] || exit 1
$jq_bin -e --arg generation "$generation" '
  [.[] | select(.generation_id == $generation and
    .semantic_identity == "core.contracts.v2")] | length == 1
' "$root/core/v2/generation-registry.json" >/dev/null || exit 1
modules="$root/core/v2/generations/$generation/modules"
core="$root/scripts/core-contract.sh"

passed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

fixture="$tmp/fixture"
source_commit=$(printf '%040d' 0 | /usr/bin/tr 0 1)
source_tree=$(printf '%040d' 0 | /usr/bin/tr 0 2)
"$fixture_builder" build "$fixture" "$jq_bin" sha1 "$source_commit" "$source_tree"
input="$fixture/input.json"

manifest_args=(
  "$fixture/manifests/forge.json"
  "$fixture/manifests/producer.json"
  "$fixture/manifests/publisher.json"
  "$fixture/manifests/reviewer.json"
  "$fixture/manifests/verifier.json"
)
for document in "$fixture/profile.json" "$fixture/resolved-profile.json" \
  "$fixture/stage-request.json" "${manifest_args[@]}"; do
  "$core" validate-document "$document" || fail "core-document-${document##*/}"
done
"$core" validate-profile-set "$fixture/profile.json" "$fixture/resolved-profile.json" \
  "${manifest_args[@]}" || fail core-profile-set
"$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" "$input" >/dev/null ||
  fail valid-input
pass 'exact core v2 graph, request, manifest, and payload envelope validate'

expect_invalid() {
  local name=$1 filter=$2
  local candidate="$tmp/$name.json"
  "$jq_bin" -S -c "$filter" "$input" > "$candidate"
  if "$jq_bin" -L "$modules" -e --arg command validate-input -f "$protocol" \
      "$candidate" >/dev/null 2> "$tmp/$name.err"; then
    fail "$name accepted"
  fi
  pass "$name"
}

expect_invalid_contract() {
  local name=$1 filter=$2
  expect_invalid "$name" "$filter |
    (.trust_context.verified_payloads[] |
      select(.input_id==\"input.materialize\") | .content.data) =
      (.payloads[] | select(.input_id==\"input.materialize\") | .data)"
}

expect_invalid extra-envelope-field '.unexpected=true'
expect_invalid missing-attempt 'del(.attempt)'
expect_invalid malformed-time '.attempt.finished_at="2026-02-30T00:00:02Z"'
expect_invalid duplicate-payload '.payloads[1]=.payloads[0]'
expect_invalid relabelled-payload '.payloads[1].input_id="input.other"'
expect_invalid payload-media-mismatch '.payloads[1].media_type="application/json"'
expect_invalid changed-after-verification \
  '(.payloads[] | select(.input_id=="input.producer-patch") | .data) += "tamper"'
expect_invalid missing-verified-payload 'del(.trust_context.verified_payloads[0])'
expect_invalid stale-resolved-ref \
  '.stage_request.content.body.resolved_profile_ref.sha256=("0"*64)'
expect_invalid duplicate-manifest '.manifests += [.manifests[0]]'
expect_invalid wrong-manifest-package \
  '(.resolved_profile.content.body.bindings[] | select(.binding.role=="forge") |
    .binding.package_ref.object_id)=("0"*40)'
expect_invalid wrong-role '.stage_request.content.body.operation.role="producer"'
expect_invalid wrong-capability \
  '.stage_request.content.body.operation.capability_id="core.harness.produce.v1"'
expect_invalid wrong-permissions \
  '.stage_request.content.body.operation.permissions-=["core.perm.candidate-repository.write.v2"]'
expect_invalid_contract malformed-contract-data \
  '(.payloads[] | select(.input_id=="input.materialize") | .data)="{"'
expect_invalid_contract traversal-contract-path \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_paths=["../escape"] | tojson)'
expect_invalid_contract git-contract-path \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_paths=[".Git/config"] | tojson)'
expect_invalid_contract contract-mode-expansion \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allowed_modes += ["120000"] | tojson)'
expect_invalid_contract contract-zero-byte-limit \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_patch_bytes=0 | tojson)'
expect_invalid_contract contract-change-limit-over-paths \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_changed_paths=2 | tojson)'
expect_invalid_contract contract-allows-binary \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_binary_patch=true | tojson)'
expect_invalid_contract contract-allows-symlink \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_symlinks=true | tojson)'
expect_invalid_contract contract-allows-submodule \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .allow_submodules=true | tojson)'
expect_invalid_contract contract-worktree-output \
  '(.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .candidate_repository_kind="worktree" | tojson)'
expect_invalid_contract contract-patch-byte-limit '
  (.payloads[] | select(.input_id=="input.materialize") | .data) |=
    (fromjson | .max_patch_bytes=1 | tojson)'

receipt="$tmp/receipt.json"
candidate_commit=$(printf '%040d' 0 | /usr/bin/tr 0 3)
candidate_tree=$(printf '%040d' 0 | /usr/bin/tr 0 4)
changed_paths_sha=$(printf '%064d' 0 | /usr/bin/tr 0 5)
receipt_args=(
  --arg command receipt
  --arg source_repository_id fixture.target
  --arg source_hash_algorithm sha1
  --arg source_commit "$source_commit"
  --arg source_tree "$source_tree"
  --arg candidate_commit "$candidate_commit"
  --arg candidate_tree "$candidate_tree"
  --arg changed_path_count 1
  --arg changed_paths_sha256 "$changed_paths_sha"
)
projection_malformed="$tmp/projection-malformed.json"
"$jq_bin" -S -c '.unexpected=true' "$input" > "$projection_malformed"
for projection_command in contract patch receipt stage-result; do
  projection_args=(--arg command "$projection_command")
  case "$projection_command" in
    receipt) projection_args=("${receipt_args[@]}") ;;
    stage-result)
      projection_args=(--arg command stage-result --arg outcome changed
        --arg receipt_json '{}' --arg verified_receipt_json '{}')
      ;;
  esac
  if "$jq_bin" -L "$modules" "${projection_args[@]}" -f "$protocol" \
       "$projection_malformed" >"$tmp/$projection_command-malformed.out" 2>/dev/null; then
    fail "$projection_command projection accepted invalid envelope"
  fi
  pass "$projection_command validates the current envelope"
done
"$jq_bin" -S -c -L "$modules" "${receipt_args[@]}" -f "$protocol" "$input" > "$receipt"
"$jq_bin" -S -c -L "$modules" "${receipt_args[@]}" -f "$protocol" "$input" > "$tmp/receipt-repeat"
/usr/bin/cmp -s "$receipt" "$tmp/receipt-repeat" || fail receipt-repeat
if /usr/bin/grep -Fq "$tmp" "$receipt" ||
   "$jq_bin" -e '[..|objects|keys[]] | any(.=="authority" or .=="effects" or .=="qualification")' \
     "$receipt" >/dev/null; then
  fail receipt-effect-surface
fi
pass 'canonical receipt is path-free and carries no authority or effect'

expect_receipt_reject() {
  local name=$1 repository_id=$2 commit_id=$3 tree_id=$4 changed_count=$5
  if "$jq_bin" -L "$modules" --arg command receipt \
      --arg source_repository_id "$repository_id" --arg source_hash_algorithm sha1 \
      --arg source_commit "$commit_id" --arg source_tree "$tree_id" \
      --arg candidate_commit "$candidate_commit" --arg candidate_tree "$candidate_tree" \
      --arg changed_path_count "$changed_count" \
      --arg changed_paths_sha256 "$changed_paths_sha" \
      -f "$protocol" "$input" >/dev/null 2>&1; then
    fail "$name"
  fi
  pass "$name"
}
expect_receipt_reject source-repository-mismatch fixture.other \
  "$source_commit" "$source_tree" 1
expect_receipt_reject source-commit-mismatch fixture.target \
  "$(printf '%040d' 0 | /usr/bin/tr 0 6)" "$source_tree" 1
expect_receipt_reject source-tree-mismatch fixture.target \
  "$source_commit" "$(printf '%040d' 0 | /usr/bin/tr 0 7)" 1
expect_receipt_reject changed-path-limit fixture.target \
  "$source_commit" "$source_tree" 2

receipt_sha=$(sha_file "$receipt")
verified_receipt="$tmp/verified-receipt.json"
"$jq_bin" -S -c -n --slurpfile receipt "$receipt" --arg sha "$receipt_sha" \
  '{content:$receipt[0],sha256:$sha}' > "$verified_receipt"
stage_result_args=(
  --arg command stage-result
  --arg outcome changed
  --arg receipt_json "$(<"$receipt")"
  --arg verified_receipt_json "$(<"$verified_receipt")"
)
result="$tmp/result.json"
"$jq_bin" -S -c -L "$modules" "${stage_result_args[@]}" \
  -f "$protocol" "$input" > "$result"
"$core" validate-stage-run "$fixture/stage-request.json" "$fixture/resolved-profile.json" \
  "$result" || fail core-stage-result
"$jq_bin" -e '
  .body.status=="completed" and .body.outcome=={family:"change",value:"changed"} and
  .body.outputs[0].output_id=="candidate.repository" and
  .body.evidence==[{evidence_id:"evidence.local-git-materialization",kind:"deterministic",
    verdict:"passed",proof_ref:.body.outputs[0].ref}] and
  ([..|objects|keys[]] | index("effects")==null) and
  ([..|objects|keys[]] | index("qualification")==null)
' "$result" >/dev/null || fail result-surface
"$jq_bin" -S -c -L "$modules" "${stage_result_args[@]}" \
  -f "$protocol" "$input" > "$tmp/result-repeat"
/usr/bin/cmp -s "$result" "$tmp/result-repeat" || fail result-repeat
pass 'pure result projection passes the exact core v2 stage relation'

make_verified_receipt() {
  local source_file=$1 output_file=$2 digest
  digest=$(sha_file "$source_file")
  "$jq_bin" -S -c -n --slurpfile receipt "$source_file" --arg sha "$digest" \
    '{content:$receipt[0],sha256:$sha}' > "$output_file"
}
expect_stage_result_reject() {
  local name=$1 outcome=$2 raw_file=$3 pair_file=$4
  if "$jq_bin" -L "$modules" --arg command stage-result --arg outcome "$outcome" \
      --arg receipt_json "$(<"$raw_file")" \
      --arg verified_receipt_json "$(<"$pair_file")" \
      -f "$protocol" "$input" >/dev/null 2>&1; then
    fail "$name"
  fi
  pass "$name"
}

moved_receipt="$tmp/moved-receipt.json"
"$jq_bin" -S -c '.request_ref.sha256=("6"*64)' "$receipt" > "$moved_receipt"
expect_stage_result_reject receipt-changed-after-verification changed \
  "$moved_receipt" "$verified_receipt"

mismatched_request_pair="$tmp/mismatched-request-pair.json"
make_verified_receipt "$moved_receipt" "$mismatched_request_pair"
expect_stage_result_reject receipt-request-mismatch changed \
  "$moved_receipt" "$mismatched_request_pair"

nested_source_input="$tmp/nested-source-input.json"
"$jq_bin" -S -c '
  (.stage_request.content.body.inputs[] |
    select(.input_id=="input.source-tree") | .value.value.value.location) =
    {kind:"path",value:"nested"} |
  .stage_request.content.body.source.value.location={kind:"path",value:"nested"} |
  .stage_request.sha256=("9"*64)
' "$input" > "$nested_source_input"
nested_source_receipt="$tmp/nested-source-receipt.json"
"$jq_bin" -S -c '.request_ref.sha256=("9"*64)' \
  "$receipt" > "$nested_source_receipt"
nested_source_pair="$tmp/nested-source-pair.json"
make_verified_receipt "$nested_source_receipt" "$nested_source_pair"
if "$jq_bin" -L "$modules" --arg command stage-result --arg outcome changed \
    --arg receipt_json "$(<"$nested_source_receipt")" \
    --arg verified_receipt_json "$(<"$nested_source_pair")" \
    -f "$protocol" "$nested_source_input" >/dev/null 2>&1; then
  fail receipt-nested-source-tree
fi
pass 'receipt source must be the repository root tree'

mismatched_attempt="$tmp/mismatched-attempt-receipt.json"
"$jq_bin" -S -c '.attempt.attempt_number += 1' "$receipt" > "$mismatched_attempt"
mismatched_attempt_pair="$tmp/mismatched-attempt-pair.json"
make_verified_receipt "$mismatched_attempt" "$mismatched_attempt_pair"
expect_stage_result_reject receipt-attempt-mismatch changed \
  "$mismatched_attempt" "$mismatched_attempt_pair"

malformed_digest_pair="$tmp/malformed-receipt-digest-pair.json"
"$jq_bin" -S -c '.sha256="invalid"' "$verified_receipt" > "$malformed_digest_pair"
expect_stage_result_reject receipt-digest-shape changed \
  "$receipt" "$malformed_digest_pair"
expect_stage_result_reject receipt-outcome-mismatch no-change \
  "$receipt" "$verified_receipt"

unchanged_commit_receipt="$tmp/unchanged-commit-receipt.json"
"$jq_bin" -S -c '.candidate.commit_id=.source.commit_id' \
  "$receipt" > "$unchanged_commit_receipt"
unchanged_commit_pair="$tmp/unchanged-commit-pair.json"
make_verified_receipt "$unchanged_commit_receipt" "$unchanged_commit_pair"
expect_stage_result_reject changed-with-unchanged-commit changed \
  "$unchanged_commit_receipt" "$unchanged_commit_pair"

unchanged_tree_receipt="$tmp/unchanged-tree-receipt.json"
"$jq_bin" -S -c '.candidate.tree_id=.source.tree_id' \
  "$receipt" > "$unchanged_tree_receipt"
unchanged_tree_pair="$tmp/unchanged-tree-pair.json"
make_verified_receipt "$unchanged_tree_receipt" "$unchanged_tree_pair"
expect_stage_result_reject changed-with-unchanged-tree changed \
  "$unchanged_tree_receipt" "$unchanged_tree_pair"

no_change_receipt="$tmp/no-change-receipt.json"
"$jq_bin" -S -c -L "$modules" --arg command receipt \
  --arg source_repository_id fixture.target --arg source_hash_algorithm sha1 \
  --arg source_commit "$source_commit" --arg source_tree "$source_tree" \
  --arg candidate_commit "$source_commit" --arg candidate_tree "$source_tree" \
  --arg changed_path_count 0 --arg changed_paths_sha256 "$changed_paths_sha" \
  -f "$protocol" "$input" > "$no_change_receipt"
no_change_pair="$tmp/no-change-pair.json"
make_verified_receipt "$no_change_receipt" "$no_change_pair"
no_change_result="$tmp/no-change-result.json"
"$jq_bin" -S -c -L "$modules" --arg command stage-result --arg outcome no-change \
  --arg receipt_json "$(<"$no_change_receipt")" \
  --arg verified_receipt_json "$(<"$no_change_pair")" \
  -f "$protocol" "$input" > "$no_change_result"
"$core" validate-stage-run "$fixture/stage-request.json" "$fixture/resolved-profile.json" \
  "$no_change_result" || fail core-no-change-result
"$jq_bin" -e '.body.outcome.value=="no-change" and .body.outputs==[] and
  .body.evidence[0].proof_ref.sha256 == .body.execution.metadata.tools.source_ref.sha256' \
  "$no_change_result" >/dev/null || fail no-change-result-surface
pass 'verified no-change receipt binds the no-change result'

if "$jq_bin" -L "$modules" --arg command receipt --arg source_hash_algorithm sha1 \
    --arg source_commit INVALID --arg source_tree "$source_tree" \
    --arg candidate_commit "$source_commit" --arg candidate_tree "$source_tree" \
    --arg changed_path_count 1 --arg changed_paths_sha256 "$(printf '%064d' 0)" \
    --arg source_repository_id fixture.target -f "$protocol" "$input" \
    > "$tmp/bad-receipt.out" 2> "$tmp/bad-receipt.err"; then
  fail malformed-receipt-identity
fi
pass 'malformed receipt identity rejected'

if /usr/bin/grep -Eq 'curl|wget|gh |glab |github[.]com|gitlab[.]com|system[(]|@sh|getenv' \
    "$protocol" "$fixture_builder"; then
  fail execution-surface
fi
pass 'protocol and fixture builder have no product execution or network seam'

printf 'local Git materializer protocol: %s focused checks passed\n' "$passed"
