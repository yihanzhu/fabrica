#!/usr/bin/env bash
# scripts/test/core-contract.test.sh — hermetic positive, raw-byte, shape,
# relation, and status tests for core/v1/contracts.jq + scripts/core-contract.sh.
#
# Builds one valid five-document graph with scripts/test/core-contract-fixtures.jq,
# independently canonicalizing and hashing each document (pinned jq + an external
# SHA tool — never the product wrapper) before wiring its digest into the next
# document's ref, so no fixture digest is ever self-referential. Runs the real
# `scripts/core-contract.sh` end to end (no Git, no process launch, no network) and
# asserts exit status, empty success stdout, the exact first stderr token, and the
# absence of a distinctive fixture path/secret from stderr. Requires jq 1.6 exactly
# on PATH (see AGENTS.md for the pinned local binary).
#
# Run: scripts/test/core-contract.test.sh

set -euo pipefail
LC_ALL=C
export LC_ALL

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$test_dir/../.." && pwd -P)"
wrapper="$repo_root/scripts/core-contract.sh"
fixtures="$test_dir/core-contract-fixtures.jq"
for f in "$wrapper" "$fixtures"; do
  [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

if [ "$(jq --version 2>/dev/null || true)" != "jq-1.6" ]; then
  echo "FAIL: this test requires jq 1.6 exactly on PATH (see AGENTS.md)" >&2
  exit 1
fi

sha_tool="sha256sum"
command -v sha256sum >/dev/null 2>&1 || sha_tool="shasum -a 256"

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

passed=0
failed=0
assert_eq() {
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); echo "pass: $1"
  else failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected: [$2]"; echo "      actual:   [$3]"; fi
}
assert_not_contains() {
  case "$3" in
    *"$2"*) failed=$((failed + 1)); echo "FAIL: $1 (unexpectedly contains [$2])" ;;
    *) passed=$((passed + 1)); echo "pass: $1" ;;
  esac
}

run_expr() {
  # run_expr EXPR [jq-args...] -> canonical JSON on stdout
  local expr="$1"; shift
  local prog="$tmpdir/prog.$$.$RANDOM.jq"
  cat "$fixtures" > "$prog"
  printf '%s\n' "$expr" >> "$prog"
  jq -n "$@" -f "$prog" | jq -S -c .
}
hash_of() { $sha_tool "$1" | awk '{print $1}'; }

# mutate BASE_FILE JQ_FILTER OUT_FILE — apply a jq filter to an existing canonical
# doc and re-canonicalize (used for shape/relation mutations; raw-byte mutations
# are crafted directly instead, since jq cannot emit non-canonical JSON on purpose).
mutate() { jq -S -c "$2" "$1" > "$3"; }

# stderr_of/status_of CMD... — run scripts/core-contract.sh, capturing stderr text
# and exit status into globals so a single invocation can be asserted on both axes.
LAST_STDERR=""
LAST_STATUS=0
run_wrapper() {
  local out
  out="$(bash "$wrapper" "$@" 2>&1 1>/dev/null)" && LAST_STATUS=0 || LAST_STATUS=$?
  LAST_STDERR="$out"
}
assert_fail() {
  # assert_fail LABEL EXPECTED_TOKEN ARGS...
  local label="$1" expected="$2"; shift 2
  run_wrapper "$@"
  assert_eq "$label (exit nonzero)" "1" "$([ "$LAST_STATUS" -ne 0 ] && echo 1 || echo 0)"
  assert_eq "$label (token)" "$expected" "$LAST_STDERR"
}
assert_ok() {
  local label="$1"; shift
  local out
  out="$(bash "$wrapper" "$@" 2>&1)" && LAST_STATUS=0 || LAST_STATUS=$?
  assert_eq "$label (exit 0)" "0" "$LAST_STATUS"
  assert_eq "$label (empty stdout+stderr)" "" "$out"
}

echo "== building the valid five-document graph =="

for role in producer verifier reviewer publisher; do
  run_expr "manifest_doc(\"$role\")" > "$tmpdir/manifest-$role.json"
done
sha_producer=$(hash_of "$tmpdir/manifest-producer.json")
sha_verifier=$(hash_of "$tmpdir/manifest-verifier.json")
sha_reviewer=$(hash_of "$tmpdir/manifest-reviewer.json")
sha_publisher=$(hash_of "$tmpdir/manifest-publisher.json")
manifest_shas=$(jq -n --arg p "$sha_producer" --arg v "$sha_verifier" --arg r "$sha_reviewer" --arg u "$sha_publisher" \
  '{producer:$p, verifier:$v, reviewer:$r, publisher:$u}')

# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'profile_doc($manifest_shas)' --argjson manifest_shas "$manifest_shas" > "$tmpdir/profile.json"
sha_profile=$(hash_of "$tmpdir/profile.json")

# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'resolved_profile_doc($profile_sha; $manifest_shas)' \
  --arg profile_sha "$sha_profile" --argjson manifest_shas "$manifest_shas" > "$tmpdir/resolved_profile.json"
sha_resolved=$(hash_of "$tmpdir/resolved_profile.json")

# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'stage_request_doc($resolved_sha)' --arg resolved_sha "$sha_resolved" > "$tmpdir/request.json"
sha_request=$(hash_of "$tmpdir/request.json")

# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'stage_result_doc($request_sha; $resolved_sha; $manifest_shas)' \
  --arg request_sha "$sha_request" --arg resolved_sha "$sha_resolved" --argjson manifest_shas "$manifest_shas" > "$tmpdir/result.json"

echo "== (a) positive path: every document, profile-set, and stage-run validate clean =="
for f in manifest-producer manifest-verifier manifest-reviewer manifest-publisher profile resolved_profile request result; do
  assert_ok "(a) validate-document $f" validate-document "$tmpdir/$f.json"
done
assert_ok "(a) validate-profile-set" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
assert_ok "(a) validate-stage-run" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/result.json"

echo "== (b) CLI usage / arity =="
assert_fail "(b) unknown command" "E_USAGE" bogus-command
assert_fail "(b) no command" "E_USAGE"
assert_fail "(b) validate-document no arg" "E_USAGE" validate-document
assert_fail "(b) validate-document extra arg" "E_USAGE" validate-document "$tmpdir/profile.json" extra
assert_fail "(b) validate-stage-run too few args" "E_USAGE" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json"
assert_fail "(b) validate-stage-run too many args" "E_USAGE" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/result.json" extra
assert_fail "(b) validate-profile-set zero manifests" "E_USAGE" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json"
assert_fail "(b) validate-profile-set nine manifests" "E_USAGE" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer.json"
for i in 1 2 3 4; do
  mutate "$tmpdir/manifest-producer.json" ".id = \"extra-manifest-$i\" | .body.package_ref.object_id = (\"$i\"*40)" "$tmpdir/extra-manifest-$i.json"
done
# The accepted contract requires the supplied manifest set to be exact — extras
# unreferenced by any binding widen a supposedly closed profile set, so eight
# manifests (four referenced, four not) is syntactically within the 1-8 CLI bound
# but must still be rejected at the relation level, not accepted.
assert_fail "(b) validate-profile-set eight manifests (boundary, 4 extra unreferenced) is rejected" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json" \
  "$tmpdir/extra-manifest-1.json" "$tmpdir/extra-manifest-2.json" "$tmpdir/extra-manifest-3.json" "$tmpdir/extra-manifest-4.json"
assert_fail "(b) validate-profile-set unreadable input" "E_RUNTIME" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" "$tmpdir/does-not-exist.json"

echo "== (c) raw-byte and canonical boundary (direct-crafted bytes, validate-document) =="
printf '' > "$tmpdir/rb-empty.json"
assert_fail "(c) empty input" "E_PARSE" validate-document "$tmpdir/rb-empty.json"
printf '{"a":1}\n{"b":2}\n' > "$tmpdir/rb-multiroot.json"
assert_fail "(c) multi-root stream" "E_PARSE" validate-document "$tmpdir/rb-multiroot.json"
printf '\xef\xbb\xbf{"a":1}\n' > "$tmpdir/rb-bom.json"
assert_fail "(c) BOM prefix" "E_CANONICAL" validate-document "$tmpdir/rb-bom.json"
printf '\xff\xfe{"a":1}\n' > "$tmpdir/rb-badutf8.json"
assert_fail "(c) invalid UTF-8" "E_PARSE" validate-document "$tmpdir/rb-badutf8.json"
printf '{"a":1,"a":2}\n' > "$tmpdir/rb-dupkeys.json"
assert_fail "(c) duplicate keys (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-dupkeys.json"
printf '{ "a": 1 }\n' > "$tmpdir/rb-altwhitespace.json"
assert_fail "(c) alternate whitespace (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-altwhitespace.json"
printf '{"a":"\\u0041"}\n' > "$tmpdir/rb-altescape.json"
assert_fail "(c) alternate escaping (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-altescape.json"
printf '{"a":1}' > "$tmpdir/rb-nolf.json"
assert_fail "(c) missing final LF (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-nolf.json"
printf '{"a":1}\n\n' > "$tmpdir/rb-extralf.json"
assert_fail "(c) extra final LF (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-extralf.json"
printf '{"b":1,"a":2}\n' > "$tmpdir/rb-unsortedkeys.json"
assert_fail "(c) unsorted keys (non-canonical)" "E_CANONICAL" validate-document "$tmpdir/rb-unsortedkeys.json"
python3 -c "
def build(bump):
    K = 256
    lengths = [4093]*248 + [4092]*8
    lengths[0] += bump
    return '{\"a\":[' + ','.join('\"' + ('x'*L) + '\"' for L in lengths) + ']}\n'
import sys
with open(sys.argv[1], 'w') as f: f.write(build(0))
with open(sys.argv[2], 'w') as f: f.write(build(1))
" "$tmpdir/rb-atlimit.json" "$tmpdir/rb-overlimit.json"
[ "$(wc -c < "$tmpdir/rb-atlimit.json" | tr -d ' ')" -eq 1048576 ] || { echo "FAIL: at-limit fixture miscounted" >&2; exit 1; }
[ "$(wc -c < "$tmpdir/rb-overlimit.json" | tr -d ' ')" -eq 1048577 ] || { echo "FAIL: over-limit fixture miscounted" >&2; exit 1; }
assert_fail "(c) at exact 1,048,576-byte boundary is still just a shape failure, not E_LIMIT" "E_SHAPE" validate-document "$tmpdir/rb-atlimit.json"
assert_fail "(c) one byte over the 1,048,576 limit" "E_LIMIT" validate-document "$tmpdir/rb-overlimit.json"
python3 -c "
depth = 33
s = '{\"a\":' * depth + '1' + '}' * depth
print(s)
" > "$tmpdir/rb-toodeep.json"
assert_fail "(c) depth 33 (one over the 32 limit)" "E_LIMIT" validate-document "$tmpdir/rb-toodeep.json"
python3 -c "
import json
obj = {('k%d' % i): 1 for i in range(257)}
print(json.dumps(obj, separators=(',', ':'), sort_keys=True))
" > "$tmpdir/rb-toomanymembers.json"
assert_fail "(c) 257 object members (one over the 256 limit)" "E_LIMIT" validate-document "$tmpdir/rb-toomanymembers.json"
python3 -c "
print('{\"a\":\"' + ('y' * 8193) + '\"}')
" > "$tmpdir/rb-toolongstring.json"
assert_fail "(c) decoded string 8,193 bytes (one over the 8,192 limit)" "E_LIMIT" validate-document "$tmpdir/rb-toolongstring.json"
# The recursive limit walker must also count object keys, not only values, or an
# oversized key escapes E_LIMIT and surfaces later as E_SHAPE instead.
python3 -c "
print('{\"' + ('k' * 8193) + '\":1}')
" > "$tmpdir/rb-toolongkey.json"
assert_fail "(c) decoded object key 8,193 bytes (one over the 8,192 limit)" "E_LIMIT" validate-document "$tmpdir/rb-toolongkey.json"
python3 -c "
print('{\"' + ('k' * 8192) + '\":1}')
" > "$tmpdir/rb-keyatlimit.json"
assert_fail "(c) 8,192-byte object key is at the limit, not over it (shape failure, not E_LIMIT)" "E_SHAPE" validate-document "$tmpdir/rb-keyatlimit.json"
printf '{"a":1.5}\n' > "$tmpdir/rb-float.json"
assert_fail "(c) float value" "E_LIMIT" validate-document "$tmpdir/rb-float.json"
printf '{"a":-1}\n' > "$tmpdir/rb-negative.json"
assert_fail "(c) negative integer" "E_LIMIT" validate-document "$tmpdir/rb-negative.json"
printf '{"a":9999999999}\n' > "$tmpdir/rb-hugeint.json"
assert_fail "(c) integer over 2147483647" "E_LIMIT" validate-document "$tmpdir/rb-hugeint.json"

secret="zzz-super-secret-path-marker-zzz"
printf '{"%s":1}\n' "$secret" > "$tmpdir/rb-secretpath.json"
run_wrapper validate-document "$tmpdir/rb-secretpath.json"
assert_not_contains "(c) stderr never echoes the input path or a distinctive fixture byte" "$secret" "$LAST_STDERR"
assert_not_contains "(c) stderr never echoes the tmp input path itself" "$tmpdir" "$LAST_STDERR"

echo "== (d) manifest shape (validate-document) =="
mutate "$tmpdir/manifest-producer.json" '.body.offered_roles = []' "$tmpdir/m-d1.json"
assert_fail "(d) offered_roles below minimum" "E_SHAPE" validate-document "$tmpdir/m-d1.json"
mutate "$tmpdir/manifest-producer.json" '.body.offered_roles = ["not-a-role"]' "$tmpdir/m-d2.json"
assert_fail "(d) offered_roles unknown enum" "E_SHAPE" validate-document "$tmpdir/m-d2.json"
mutate "$tmpdir/manifest-producer.json" '.body.extra_field = 1' "$tmpdir/m-d3.json"
assert_fail "(d) unknown top-level field" "E_SHAPE" validate-document "$tmpdir/m-d3.json"
mutate "$tmpdir/manifest-producer.json" 'del(.body.adapter_version)' "$tmpdir/m-d4.json"
assert_fail "(d) missing required field" "E_SHAPE" validate-document "$tmpdir/m-d4.json"
mutate "$tmpdir/manifest-producer.json" '.body.offered_tools = [{tool_id:"t1",tool_version:"v1",package_ref:.body.package_ref,config_ref:{state:"absent"}},{tool_id:"t1",tool_version:"v1",package_ref:.body.package_ref,config_ref:{state:"absent"}}]' "$tmpdir/m-d5.json"
assert_fail "(d) duplicate tool_id in offered_tools" "E_SHAPE" validate-document "$tmpdir/m-d5.json"
mutate "$tmpdir/manifest-producer.json" '.kind = "not-a-kind"' "$tmpdir/m-d6.json"
assert_fail "(d) unknown document kind" "E_SHAPE" validate-document "$tmpdir/m-d6.json"
mutate "$tmpdir/manifest-producer.json" '.schema_version = 2' "$tmpdir/m-d7.json"
assert_fail "(d) wrong schema_version" "E_SHAPE" validate-document "$tmpdir/m-d7.json"
mutate "$tmpdir/manifest-producer.json" '.body.offered_permissions = (.body.offered_permissions | sort | reverse)' "$tmpdir/m-d8.json"
assert_fail "(d) offered_permissions enum set not in canonical sorted order" "E_SHAPE" validate-document "$tmpdir/m-d8.json"

echo "== (e) profile shape + protected-role relations (validate-document) =="
mutate "$tmpdir/profile.json" '.body.bindings = [.body.bindings[0]]' "$tmpdir/p-e1.json"
assert_fail "(e) below 4-binding minimum" "E_SHAPE" validate-document "$tmpdir/p-e1.json"
mutate "$tmpdir/profile.json" '.body.bindings[0].requested_capabilities = ["core.verify.run.v1"]' "$tmpdir/p-e2.json"
assert_fail "(e) producer requesting verifier's capability" "E_SHAPE" validate-document "$tmpdir/p-e2.json"
mutate "$tmpdir/profile.json" 'del(.body.bindings[3].authority_ref)' "$tmpdir/p-e3.json"
assert_fail "(e) protected role missing authority_ref" "E_RELATION" validate-document "$tmpdir/p-e3.json"
mutate "$tmpdir/profile.json" '.body.bindings[1].authority_ref.scope_sha256 = .body.bindings[0].authority_ref.scope_sha256' "$tmpdir/p-e4.json"
assert_fail "(e) two protected roles share one authority scope" "E_RELATION" validate-document "$tmpdir/p-e4.json"
mutate "$tmpdir/profile.json" '.body.bindings[1].principal_id = .body.bindings[0].principal_id' "$tmpdir/p-e5.json"
assert_fail "(e) two protected roles share one principal_id" "E_RELATION" validate-document "$tmpdir/p-e5.json"
# Selects the verifier binding by role, not array position — canonical sorted
# order (core/v1/contracts.jq's is_bounded_set) no longer places it at a fixed index.
mutate "$tmpdir/profile.json" '.body.bindings |= map(if .role=="verifier" then .execution_kind="model" else . end)' "$tmpdir/p-e6.json"
assert_fail "(e) verifier forced to model execution" "E_SHAPE" validate-document "$tmpdir/p-e6.json"
mutate "$tmpdir/profile.json" '.body.bindings[0].skill_refs = [.body.bindings[0].package_ref]' "$tmpdir/p-e7.json"
assert_fail "(e) deterministic binding with non-empty skill_refs" "E_SHAPE" validate-document "$tmpdir/p-e7.json"
mutate "$tmpdir/profile.json" '.body.bindings[0].binding_id = .body.bindings[1].binding_id' "$tmpdir/p-e8.json"
assert_fail "(e) duplicate binding_id" "E_SHAPE" validate-document "$tmpdir/p-e8.json"
mutate "$tmpdir/profile.json" '.body.bindings |= reverse' "$tmpdir/p-e9.json"
assert_fail "(e) bindings not in canonical binding_id-sorted order" "E_SHAPE" validate-document "$tmpdir/p-e9.json"
# Model backing is permitted only for producer and reviewer; every other (dormant)
# role must stay deterministic.
model_bits='.execution_kind="model" | .model_request={provider_id:"prov-1",model_id:"model-1",effort_id:"effort-1"} | .prompt_ref={revision:{repository_id:"repo-a",hash_algorithm:"sha1",commit_id:("a"*40)},location:{kind:"path",value:"prompt.json"},object_type:"blob",object_id:("c"*40),mode:"100644"}'
mutate "$tmpdir/profile.json" ".body.bindings |= map(if .role==\"producer\" then ($model_bits | .requested_permissions=([\"core.perm.target.read.v1\",\"core.perm.scratch.write.v1\",\"core.perm.evidence.write.v1\",\"core.perm.model.invoke.v1\"]|sort)) else . end)" "$tmpdir/p-e10.json"
assert_ok "(e) producer allowed to use model execution" validate-document "$tmpdir/p-e10.json"
mutate "$tmpdir/profile.json" ".body.bindings |= map(if .role==\"publisher\" then ($model_bits) else . end)" "$tmpdir/p-e11.json"
assert_fail "(e) dormant role (publisher) forced to model execution" "E_SHAPE" validate-document "$tmpdir/p-e11.json"

echo "== (f) resolved_profile shape (validate-document) =="
mutate "$tmpdir/resolved_profile.json" 'del(.body.selection_ref)' "$tmpdir/rp-f1.json"
assert_fail "(f) missing selection_ref" "E_SHAPE" validate-document "$tmpdir/rp-f1.json"
mutate "$tmpdir/resolved_profile.json" '.body.selection_ref.purpose = "grant"' "$tmpdir/rp-f2.json"
assert_fail "(f) selection_ref carries the wrong purpose" "E_SHAPE" validate-document "$tmpdir/rp-f2.json"
mutate "$tmpdir/resolved_profile.json" '.body.bindings = [.body.bindings[0],.body.bindings[1],.body.bindings[2]]' "$tmpdir/rp-f3.json"
assert_fail "(f) resolved bindings below the 4 minimum" "E_SHAPE" validate-document "$tmpdir/rp-f3.json"
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.value_format = "canonical-json" | .body.profile_source.source.object_type = "tree"' "$tmpdir/rp-f4.json"
assert_fail "(f) canonical-json source pointing at a tree, not a blob" "E_SHAPE" validate-document "$tmpdir/rp-f4.json"
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].tool_sources = [{tool_id:"t1",package_source:.body.bindings[0].package_source,config_source:{state:"absent"}},{tool_id:"t1",package_source:.body.bindings[0].package_source,config_source:{state:"absent"}}]' "$tmpdir/rp-f5.json"
assert_fail "(f) duplicate tool_id in tool_sources" "E_SHAPE" validate-document "$tmpdir/rp-f5.json"

echo "== (n) RepoPath rejects DEL and C1 control characters, not just C0 (validate-document) =="
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.source.location.value = "profile.json"' "$tmpdir/rp-n1.json"
assert_fail "(n) repository path containing DEL (U+007F)" "E_SHAPE" validate-document "$tmpdir/rp-n1.json"
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.source.location.value = "profile.json"' "$tmpdir/rp-n2.json"
assert_fail "(n) repository path containing a C1 control character (U+0080)" "E_SHAPE" validate-document "$tmpdir/rp-n2.json"
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.source.location.value = "profile.json"' "$tmpdir/rp-n3.json"
assert_fail "(n) repository path containing a C1 control character (U+009F, top of range)" "E_SHAPE" validate-document "$tmpdir/rp-n3.json"
# Pair: a genuinely non-ASCII but non-control path segment stays legal — the fix
# extends control-character rejection, it does not reject all non-ASCII bytes.
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.source.location.value = "profile-é.json"' "$tmpdir/rp-n4.json"
assert_ok "(n) repository path with a non-control non-ASCII character stays legal" validate-document "$tmpdir/rp-n4.json"

echo "== (g) stage_request shape (validate-document) =="
mutate "$tmpdir/request.json" 'del(.body.risk)' "$tmpdir/r-g1.json"
assert_fail "(g) missing risk" "E_SHAPE" validate-document "$tmpdir/r-g1.json"
mutate "$tmpdir/request.json" '.body.risk.tier = {namespace:"core",name:"not-a-tier"}' "$tmpdir/r-g2.json"
assert_fail "(g) unknown core risk tier" "E_SHAPE" validate-document "$tmpdir/r-g2.json"
mutate "$tmpdir/request.json" '.body.operation.permissions = []' "$tmpdir/r-g3.json"
assert_fail "(g) operation permissions below the 1 minimum" "E_SHAPE" validate-document "$tmpdir/r-g3.json"
mutate "$tmpdir/request.json" '.body.operation.arguments = {artifact_kind:"git-patch"}' "$tmpdir/r-g4.json"
assert_fail "(g) git-patch arguments missing allowed_delta" "E_SHAPE" validate-document "$tmpdir/r-g4.json"
mutate "$tmpdir/request.json" '.body.required_evidence_kinds = []' "$tmpdir/r-g5.json"
assert_fail "(g) required_evidence_kinds below minimum" "E_SHAPE" validate-document "$tmpdir/r-g5.json"
mutate "$tmpdir/request.json" '.body.required_evidence_kinds = ["independent-review"]' "$tmpdir/r-g6.json"
assert_fail "(g) producer required_evidence_kinds must be exactly deterministic" "E_SHAPE" validate-document "$tmpdir/r-g6.json"
mutate "$tmpdir/request.json" '.body.finish_condition.input_id = .body.verification_instruction.input_id' "$tmpdir/r-g7.json"
assert_fail "(g) finish_condition and verification_instruction share one input_id" "E_SHAPE" validate-document "$tmpdir/r-g7.json"
mutate "$tmpdir/request.json" '.body.requested_at = "not-a-time"' "$tmpdir/r-g8.json"
assert_fail "(g) malformed requested_at" "E_SHAPE" validate-document "$tmpdir/r-g8.json"
mutate "$tmpdir/request.json" '.body.operation.role = "publisher"' "$tmpdir/r-g9.json"
assert_fail "(g) bootstrap producer-only rule violated by a non-producer role" "E_SHAPE" validate-document "$tmpdir/r-g9.json"
mutate "$tmpdir/request.json" '.body.risk.tier = {namespace:"core",name:"routine"}' "$tmpdir/r-g10.json"
assert_fail "(g) absent target requires bootstrap risk tier, not merely a producer role" "E_SHAPE" validate-document "$tmpdir/r-g10.json"
mutate "$tmpdir/request.json" '.body.requested_at = "2026-99-99T99:99:99Z"' "$tmpdir/r-g11.json"
assert_fail "(g) requested_at with out-of-range month/day/time components" "E_SHAPE" validate-document "$tmpdir/r-g11.json"
# named_input's "document" variant (input_ref -> document_ref_shape) is the one
# spot with no accompanying exact-kind check next to it (unlike every document_ref(K)
# use, which also compares .kind==K) — an unknown .kind here only is_document_kind
# itself can catch, so it is the mutation that actually exercises that fix.
mutate "$tmpdir/request.json" '.body.inputs[0].value = {type:"document", value:{schema_version:1,kind:"not-a-document-kind",id:"x",sha256:("0"*64)}}' "$tmpdir/r-g12.json"
assert_fail "(g) named input document ref with an unknown document kind" "E_SHAPE" validate-document "$tmpdir/r-g12.json"
# is_time must validate the calendar, not just per-field ranges: a well-formed-looking
# non-existent date (Feb 31; Feb 29 in a non-leap year) must still fail, while a real
# leap day must still pass.
mutate "$tmpdir/request.json" '.body.requested_at = "2026-02-31T00:00:00Z"' "$tmpdir/r-g13.json"
assert_fail "(g) requested_at names a day the month does not have" "E_SHAPE" validate-document "$tmpdir/r-g13.json"
mutate "$tmpdir/request.json" '.body.requested_at = "2025-02-29T00:00:00Z"' "$tmpdir/r-g14.json"
assert_fail "(g) requested_at names Feb 29 in a non-leap year" "E_SHAPE" validate-document "$tmpdir/r-g14.json"
mutate "$tmpdir/request.json" '.body.requested_at = "2024-02-29T00:00:00Z"' "$tmpdir/r-g15.json"
assert_ok "(g) requested_at names Feb 29 in a real leap year" validate-document "$tmpdir/r-g15.json"

echo "== (h) stage_result shape (validate-document) =="
mutate "$tmpdir/result.json" '.body.evidence = [.body.evidence[0], (.body.evidence[0] | .evidence_id = "ev-2")]' "$tmpdir/s-h1.json"
assert_fail "(h) two evidence items share one kind" "E_SHAPE" validate-document "$tmpdir/s-h1.json"
mutate "$tmpdir/result.json" '.body.status = "not-a-status"' "$tmpdir/s-h2.json"
assert_fail "(h) unknown terminal status" "E_SHAPE" validate-document "$tmpdir/s-h2.json"
mutate "$tmpdir/result.json" '.body.attempt_number = 0' "$tmpdir/s-h3.json"
assert_fail "(h) attempt_number below 1" "E_SHAPE" validate-document "$tmpdir/s-h3.json"
mutate "$tmpdir/result.json" '.body.execution.used_capability = {kind:"registered", id:"not-a-capability"}' "$tmpdir/s-h4.json"
assert_fail "(h) registered capability outside the closed set" "E_SHAPE" validate-document "$tmpdir/s-h4.json"
mutate "$tmpdir/result.json" '.body.execution.metadata.tools.state = "not-applicable"' "$tmpdir/s-h5.json"
assert_fail "(h) tools fact cannot be not-applicable for any execution" "E_SHAPE" validate-document "$tmpdir/s-h5.json"
mutate "$tmpdir/result.json" 'del(.body.outputs[0].ref)' "$tmpdir/s-h6.json"
assert_fail "(h) output missing its content ref" "E_SHAPE" validate-document "$tmpdir/s-h6.json"
mutate "$tmpdir/result.json" '.body.execution.used_capability = {kind:"unclassified", id:"core.harness.produce.v1"}' "$tmpdir/s-h7.json"
assert_fail "(h) unclassified used_capability id equals a registered capability id" "E_SHAPE" validate-document "$tmpdir/s-h7.json"

echo "== (i) profile-set relations (validate-profile-set) =="
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].package_source.source.object_id = ("f"*40)' "$tmpdir/rp-i1.json"
assert_fail "(i) resolved package_source does not match the binding's package_ref" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i1.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].adapter_implementation.version = "not-v1"' "$tmpdir/rp-i2.json"
assert_fail "(i) resolved adapter_implementation.version does not match the manifest" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i2.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
# Renames (rather than reorders) the last binding so the array stays in the
# required canonical sorted-by-binding_id order (core/v1/contracts.jq's
# is_bounded_set now enforces that order) while still breaking the binding_id-set
# match against the profile.
mutate "$tmpdir/resolved_profile.json" '.body.bindings[-1].binding.binding_id = "b-zzz-no-such-binding"' "$tmpdir/rp-i3.json"
assert_fail "(i) resolved bindings do not cover the same binding_id set as the profile" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i3.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/profile.json" '.body.bindings[0].manifest_ref.id = "no-such-manifest"' "$tmpdir/p-i4.json"
assert_fail "(i) mutated profile's own digest no longer matches the resolved profile's profile_ref" "E_REF" validate-profile-set "$tmpdir/p-i4.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/manifest-producer.json" '.id = "extra-manifest-unrelated"' "$tmpdir/extra-manifest-unrelated.json"
assert_fail "(i) a referenced manifest is simply not supplied (profile/resolved digests untouched)" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/extra-manifest-unrelated.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/resolved_profile.json" '.body.profile_ref.sha256 = ("0"*64)' "$tmpdir/rp-i5.json"
assert_fail "(i) resolved profile_ref digest does not match the supplied profile" "E_REF" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i5.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
cp "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer-dup.json"
assert_fail "(i) two supplied manifests share one document id" "E_REF" validate-profile-set "$tmpdir/profile.json" "$tmpdir/resolved_profile.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-producer-dup.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].config_source = {state:"present", value:{source:.body.bindings[0].package_source.source, value_format:"raw-bytes", value_sha256:("1"*64)}}' "$tmpdir/rp-i6.json"
assert_fail "(i) resolved config_source present without a config_ref on the binding" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i6.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/resolved_profile.json" '.body.profile_source.value_sha256 = ("0"*64)' "$tmpdir/rp-i7.json"
assert_fail "(i) resolved profile_source digest does not match the supplied profile's real bytes" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i7.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].manifest_source.value_sha256 = ("0"*64)' "$tmpdir/rp-i8.json"
assert_fail "(i) resolved manifest_source digest does not match the supplied manifest's real bytes" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i8.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
# These two rebuild a fully hash-consistent profile+resolved_profile pair around
# the mutated manifest (mutate() alone can't: changing a referenced manifest's
# bytes changes its digest, and profile.json/resolved_profile.json embed digests
# of each other, so a bare byte-level mutation would only trip the earlier
# "referenced manifest not supplied" check instead of the offer relation itself).
mutate "$tmpdir/manifest-producer.json" '.body.offered_roles = ["verifier"]' "$tmpdir/m-i9.json"
sha_i9=$(hash_of "$tmpdir/m-i9.json")
manifest_shas_i9=$(jq -n --arg p "$sha_i9" --arg v "$sha_verifier" --arg r "$sha_reviewer" --arg u "$sha_publisher" \
  '{producer:$p, verifier:$v, reviewer:$r, publisher:$u}')
# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'profile_doc($manifest_shas)' --argjson manifest_shas "$manifest_shas_i9" > "$tmpdir/p-i9.json"
sha_p_i9=$(hash_of "$tmpdir/p-i9.json")
# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'resolved_profile_doc($profile_sha; $manifest_shas)' --arg profile_sha "$sha_p_i9" --argjson manifest_shas "$manifest_shas_i9" > "$tmpdir/rp-i9.json"
assert_fail "(i) manifest does not offer the binding's role" "E_RELATION" validate-profile-set "$tmpdir/p-i9.json" "$tmpdir/rp-i9.json" \
  "$tmpdir/m-i9.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
mutate "$tmpdir/manifest-producer.json" '.body.offered_capabilities = []' "$tmpdir/m-i10.json"
sha_i10=$(hash_of "$tmpdir/m-i10.json")
manifest_shas_i10=$(jq -n --arg p "$sha_i10" --arg v "$sha_verifier" --arg r "$sha_reviewer" --arg u "$sha_publisher" \
  '{producer:$p, verifier:$v, reviewer:$r, publisher:$u}')
# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'profile_doc($manifest_shas)' --argjson manifest_shas "$manifest_shas_i10" > "$tmpdir/p-i10.json"
sha_p_i10=$(hash_of "$tmpdir/p-i10.json")
# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'resolved_profile_doc($profile_sha; $manifest_shas)' --arg profile_sha "$sha_p_i10" --argjson manifest_shas "$manifest_shas_i10" > "$tmpdir/rp-i10.json"
assert_fail "(i) manifest does not offer the binding's requested capability" "E_RELATION" validate-profile-set "$tmpdir/p-i10.json" "$tmpdir/rp-i10.json" \
  "$tmpdir/m-i10.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"
# One exact source Git object gets only one format/digest claim across the whole
# resolved profile — every binding's package_source points at the same shared
# package_ref object, so two different value_sha256 claims for it must be rejected
# even though each binding's own manifest-relation check passes in isolation.
mutate "$tmpdir/resolved_profile.json" '.body.bindings[0].package_source.value_sha256 = ("f" * 64)' "$tmpdir/rp-i11.json"
assert_fail "(i) two bindings claim different digests for the same source Git object" "E_RELATION" validate-profile-set "$tmpdir/profile.json" "$tmpdir/rp-i11.json" \
  "$tmpdir/manifest-producer.json" "$tmpdir/manifest-verifier.json" "$tmpdir/manifest-reviewer.json" "$tmpdir/manifest-publisher.json"

echo "== (j) stage-run relations (validate-stage-run) =="
mutate "$tmpdir/result.json" '.body.outcome.value = "no-change"' "$tmpdir/s-j1.json"
assert_fail "(j) producer outcome mismatches non-empty outputs" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j1.json"
mutate "$tmpdir/result.json" '.body.execution.performer.role = "verifier" | .body.execution.actual_binding.role = "verifier"' "$tmpdir/s-j2.json"
assert_fail "(j) execution performer role does not match the request's binding role" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j2.json"
mutate "$tmpdir/result.json" '.body.evidence = [{evidence_id:"ev-1",kind:"independent-review",verdict:"passed",proof_ref:{content_id:"p1",media_type:"application/json",sha256:("2"*64)}}]' "$tmpdir/s-j3.json"
assert_fail "(j) producer result carries reviewer-only evidence kind" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j3.json"
mutate "$tmpdir/result.json" '.body.finished_at = "2020-01-01T00:00:00Z"' "$tmpdir/s-j4.json"
assert_fail "(j) finished_at precedes started_at" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j4.json"
mutate "$tmpdir/result.json" '.body.attempt_number = 0' "$tmpdir/s-j5.json"
assert_fail "(j) attempt_number below 1 (shape catches it first)" "E_SHAPE" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j5.json"
mutate "$tmpdir/result.json" '.body.request_ref.sha256 = ("0"*64)' "$tmpdir/s-j6.json"
assert_fail "(j) result request_ref digest does not match the supplied request" "E_REF" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j6.json"
mutate "$tmpdir/result.json" '.body.resolved_profile_ref.sha256 = ("0"*64)' "$tmpdir/s-j7.json"
assert_fail "(j) result resolved_profile_ref digest does not match the supplied resolved profile" "E_REF" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j7.json"
mutate "$tmpdir/result.json" 'del(.body.finished_at)' "$tmpdir/s-j8.json"
assert_fail "(j) completed status missing finished_at (status presence matrix)" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j8.json"
mutate "$tmpdir/result.json" '.body.status = "skipped" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = []' "$tmpdir/s-j9.json"
assert_ok "(j) skipped status with matching empty fields is a legal terminal state" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j9.json"
mutate "$tmpdir/result.json" '.body.status = "skipped" | .body.reason = {reason_id:"r1"} | del(.body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = []' "$tmpdir/s-j10.json"
assert_fail "(j) skipped status still carrying an outcome" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j10.json"
mutate "$tmpdir/request.json" '.body.operation.binding_id = "no-such-binding"' "$tmpdir/r-j11.json"
# shellcheck disable=SC2016  # single-quoted jq $-vars on purpose, not shell vars
run_expr 'stage_result_doc($request_sha; $resolved_sha; $manifest_shas)' --arg request_sha "$(hash_of "$tmpdir/r-j11.json")" --arg resolved_sha "$sha_resolved" --argjson manifest_shas "$manifest_shas" > "$tmpdir/s-j11.json"
assert_fail "(j) request operation names a binding absent from the resolved profile" "E_RELATION" validate-stage-run "$tmpdir/r-j11.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j11.json"
mutate "$tmpdir/result.json" '.body.outputs = [.body.outputs[0], (.body.outputs[0] | .output_id = "o2")]' "$tmpdir/s-j12.json"
assert_fail "(j) completed producer change with more than one output" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j12.json"
mutate "$tmpdir/result.json" '.body.status = "stale" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = [] | .body.stale_observations = [{selector:{kind:"target"},observed:{state:"absent"}}]' "$tmpdir/s-j13.json"
assert_fail "(j) stale observation repeats the request's own unchanged (absent) target" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j13.json"
mutate "$tmpdir/result.json" '.body.status = "stale" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = [] | .body.stale_observations = [{selector:{kind:"input",input_id:"no-such-input"},observed:{state:"present",value:{type:"document",value:{schema_version:1,kind:"profile",id:"profile-1",sha256:("0"*64)}}}}]' "$tmpdir/s-j14.json"
assert_fail "(j) stale observation names an input absent from the request" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j14.json"
mutate "$tmpdir/result.json" '.body.status = "stale" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = [] | .body.stale_observations = [{selector:{kind:"environment"},observed:{state:"present",value:{environment_id:"env-1",fingerprint_sha256:("4"*64)}}}]' "$tmpdir/s-j15.json"
assert_ok "(j) stale observation with a genuinely different environment fingerprint is a legal terminal state" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j15.json"
# A stale resolved-profile observation must pin the expected ID, not just the kind:
# the same kind with an unrelated ID names a different document entirely, not a
# staleness claim about this one.
mutate "$tmpdir/result.json" '.body.status = "stale" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = [] | .body.stale_observations = [{selector:{kind:"resolved-profile"},observed:{state:"present",value:{schema_version:1,kind:"resolved_profile",id:"resolved-1",sha256:("5"*64)}}}]' "$tmpdir/s-j16.json"
assert_ok "(j) stale resolved-profile observation keeps the request's own ID with a genuinely different digest" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j16.json"
mutate "$tmpdir/result.json" '.body.status = "stale" | .body.reason = {reason_id:"r1"} | del(.body.outcome, .body.execution, .body.started_at, .body.finished_at) | .body.evidence = [] | .body.outputs = [] | .body.stale_observations = [{selector:{kind:"resolved-profile"},observed:{state:"present",value:{schema_version:1,kind:"resolved_profile",id:"some-other-resolved-profile",sha256:("5"*64)}}}]' "$tmpdir/s-j17.json"
assert_fail "(j) stale resolved-profile observation names an unrelated resolved profile ID" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j17.json"
# Regression guard (round-0 over-corrected this to an unconditional equality): a
# completed record with failing evidence is explicitly allowed to report execution
# facts that differ from the resolved binding, so it can preserve what went wrong;
# a completed non-inconclusive record must still match exactly.
mutate "$tmpdir/result.json" '.body.execution.environment.environment_id = "env-mismatch"' "$tmpdir/s-j18.json"
assert_fail "(j) completed non-inconclusive execution environment mismatches the request's environment" "E_RELATION" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j18.json"
mutate "$tmpdir/result.json" '.body.evidence[0].verdict = "failed" | .body.outcome = {family:"change",value:"inconclusive"} | .body.outputs = [] | .body.reason = {reason_id:"r1"} | .body.execution.environment.environment_id = "env-mismatch"' "$tmpdir/s-j19.json"
assert_ok "(j) completed-inconclusive execution environment may differ from the resolved binding" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/s-j19.json"

echo "== (l) unavailable requested facts force a completed result inconclusive (validate-stage-run) =="
# Builds one alternate model-backed producer binding (base fixtures are all
# deterministic) and rewires the ref chain the same way (i9)/(i10) do: mutate,
# rehash, and feed the new digest into the next document.
model_perms='(["core.perm.target.read.v1","core.perm.scratch.write.v1","core.perm.evidence.write.v1","core.perm.model.invoke.v1"]|sort)'
prompt_ref_literal='{revision:{repository_id:"repo-a",hash_algorithm:"sha1",commit_id:("a"*40)},location:{kind:"path",value:"prompt.json"},object_type:"blob",object_id:("c"*40),mode:"100644"}'
mutate "$tmpdir/resolved_profile.json" ".body.bindings |= map(if .binding.role==\"producer\" then
    .binding.execution_kind=\"model\" | .binding.model_request={provider_id:\"prov-1\",model_id:\"model-1\",effort_id:\"effort-1\"} |
    .binding.prompt_ref=$prompt_ref_literal | .binding.requested_permissions=$model_perms
  else . end)" "$tmpdir/rp-model.json"
sha_rp_model=$(hash_of "$tmpdir/rp-model.json")
mutate "$tmpdir/request.json" ".body.resolved_profile_ref.sha256=\"$sha_rp_model\" | .body.operation.permissions=$model_perms" "$tmpdir/req-model.json"
sha_req_model=$(hash_of "$tmpdir/req-model.json")
mutate "$tmpdir/result.json" ".body.request_ref.sha256=\"$sha_req_model\" | .body.resolved_profile_ref.sha256=\"$sha_rp_model\" |
    .body.execution.actual_binding.execution_kind=\"model\" | .body.execution.metadata.kind=\"model\" |
    .body.execution.metadata.snapshot={state:\"unavailable\",reason_id:\"no-snapshot\"} |
    .body.execution.metadata.provider={state:\"recorded\",value:\"prov-1\",source_ref:{content_id:\"cf-provider\",media_type:\"application/json\",sha256:(\"9\"*64)}} |
    .body.execution.metadata.model={state:\"recorded\",value:\"model-1\",source_ref:{content_id:\"cf-model\",media_type:\"application/json\",sha256:(\"9\"*64)}} |
    .body.execution.metadata.effort={state:\"recorded\",value:\"effort-1\",source_ref:{content_id:\"cf-effort\",media_type:\"application/json\",sha256:(\"9\"*64)}} |
    .body.execution.metadata.prompt={state:\"recorded\",value:$prompt_ref_literal,source_ref:{content_id:\"cf-prompt\",media_type:\"application/json\",sha256:(\"9\"*64)}} |
    .body.execution.metadata.skills={state:\"recorded\",value:[],source_ref:{content_id:\"cf-skills\",media_type:\"application/json\",sha256:(\"9\"*64)}}
  " "$tmpdir/result-model.json"
assert_ok "(l) model-backed completed producer change with all requested facts recorded" validate-stage-run "$tmpdir/req-model.json" "$tmpdir/rp-model.json" "$tmpdir/result-model.json"
mutate "$tmpdir/result-model.json" '.body.execution.metadata.prompt = {state:"unavailable", reason_id:"prompt-store-unreachable"}' "$tmpdir/result-model-bad.json"
assert_fail "(l) unavailable prompt fact still claims a conclusive outcome" "E_RELATION" validate-stage-run "$tmpdir/req-model.json" "$tmpdir/rp-model.json" "$tmpdir/result-model-bad.json"
mutate "$tmpdir/result-model.json" '.body.execution.metadata.prompt = {state:"unavailable", reason_id:"prompt-store-unreachable"} |
    .body.outcome = {family:"change", value:"inconclusive"} | .body.outputs = [] | .body.reason = {reason_id:"r1"}' "$tmpdir/result-model-ok.json"
assert_ok "(l) unavailable prompt fact correctly reported as a completed-inconclusive record" validate-stage-run "$tmpdir/req-model.json" "$tmpdir/rp-model.json" "$tmpdir/result-model-ok.json"
# tools follows the same forced-inconclusive path as provider/model/effort/prompt/
# skills (round-2 routed those five through metadata_requested_unavailable but
# missed tools) — a completed record whose actual tool use cannot be established
# must not stay conclusive, and must still validate once it honestly reports
# inconclusive instead.
mutate "$tmpdir/result-model.json" '.body.execution.metadata.tools = {state:"unavailable", reason_id:"tool-inventory-unreachable"}' "$tmpdir/result-model-tools-bad.json"
assert_fail "(l) unavailable tools fact still claims a conclusive outcome" "E_RELATION" validate-stage-run "$tmpdir/req-model.json" "$tmpdir/rp-model.json" "$tmpdir/result-model-tools-bad.json"
mutate "$tmpdir/result-model.json" '.body.execution.metadata.tools = {state:"unavailable", reason_id:"tool-inventory-unreachable"} |
    .body.outcome = {family:"change", value:"inconclusive"} | .body.outputs = [] | .body.reason = {reason_id:"r1"}' "$tmpdir/result-model-tools-ok.json"
assert_ok "(l) unavailable tools fact correctly reported as a completed-inconclusive record" validate-stage-run "$tmpdir/req-model.json" "$tmpdir/rp-model.json" "$tmpdir/result-model-tools-ok.json"

echo "== (m) resolved-profile embedded bindings must still satisfy the profile invariants (validate-document, validate-stage-run) =="
# validate-document on a bare resolved_profile: shape alone lets an embedded
# producer binding through with an empty requested_capabilities/requested_permissions
# set, which profile validation would reject. Reuses profile_binding_capability_ok
# via resolved_bindings_profile_invariants_ok, not a parallel check.
mutate "$tmpdir/resolved_profile.json" '.body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end)' "$tmpdir/rp-m1.json"
assert_fail "(m) embedded producer binding with emptied capability closure" "E_RELATION" validate-document "$tmpdir/rp-m1.json"
# shellcheck disable=SC2016  # single-quoted jq $-var on purpose, not a shell var
mutate "$tmpdir/resolved_profile.json" '(.body.bindings[] | select(.binding.role=="publisher") | .binding.principal_id) as $shared | .body.bindings |= map(if .binding.role=="reviewer" then .binding.principal_id=$shared else . end)' "$tmpdir/rp-m2.json"
assert_fail "(m) two embedded protected-role bindings share one principal_id" "E_RELATION" validate-document "$tmpdir/rp-m2.json"
assert_ok "(m) unmutated resolved_profile still validates on its own" validate-document "$tmpdir/resolved_profile.json"
# The same gap exists behind validate-stage-run: the request/result relations
# never look at a binding's own requested_capabilities/requested_permissions, only
# its role, so without this fix a stage run is approved for an operation the
# embedded binding never actually requested.
mutate "$tmpdir/resolved_profile.json" '.body.bindings |= map(if .binding.role=="producer" then .binding.requested_capabilities=[] | .binding.requested_permissions=[] else . end)' "$tmpdir/rp-m3.json"
sha_rp_m3=$(hash_of "$tmpdir/rp-m3.json")
mutate "$tmpdir/request.json" ".body.resolved_profile_ref.sha256=\"$sha_rp_m3\"" "$tmpdir/req-m3.json"
sha_req_m3=$(hash_of "$tmpdir/req-m3.json")
mutate "$tmpdir/result.json" ".body.request_ref.sha256=\"$sha_req_m3\" | .body.resolved_profile_ref.sha256=\"$sha_rp_m3\"" "$tmpdir/result-m3.json"
assert_fail "(m) stage-run approves an operation its embedded binding never requested" "E_RELATION" validate-stage-run "$tmpdir/req-m3.json" "$tmpdir/rp-m3.json" "$tmpdir/result-m3.json"
assert_ok "(m) unmutated request/resolved_profile/result triple still validates as a stage-run" validate-stage-run "$tmpdir/request.json" "$tmpdir/resolved_profile.json" "$tmpdir/result.json"

echo "== (k) jq version pin and SHA-tool fallback (environment) =="
fakebin="$tmpdir/fakebin"
mkdir -p "$fakebin"
cat > "$fakebin/jq" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "jq-1.7"; exit 0; fi
exec /usr/bin/env jq "$@"
EOF
chmod +x "$fakebin/jq"
out="$(PATH="$fakebin:$PATH" bash "$wrapper" validate-document "$tmpdir/profile.json" 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "(k) non-1.6 jq on PATH is rejected (exit)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "(k) non-1.6 jq on PATH is rejected (token)" "E_RUNTIME" "$out"
# The exact command form (including the 1-8 manifest count) must be checked before
# any runtime dependency, so a bad command/arity still reports E_USAGE even on a
# host without the pinned jq — the well-formed case just above still hits E_RUNTIME,
# proving this isn't just a deleted check.
out="$(PATH="$fakebin:$PATH" bash "$wrapper" bogus-command 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "(k) usage checked before the jq pin: unknown command (exit)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "(k) usage checked before the jq pin: unknown command (token)" "E_USAGE" "$out"
out="$(PATH="$fakebin:$PATH" bash "$wrapper" validate-document 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "(k) usage checked before the jq pin: missing arg (token)" "E_USAGE" "$out"

nojqbin="$tmpdir/nojqbin"
mkdir -p "$nojqbin"
for b in bash sh cat head wc awk tr mktemp rm dirname cmp env printf sha256sum shasum; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$nojqbin/$b"
done
rm -f "$nojqbin/sha256sum" "$nojqbin/shasum"
out="$(PATH="$nojqbin" bash "$wrapper" validate-document "$tmpdir/profile.json" 2>&1 1>/dev/null)" && rc=0 || rc=$?
assert_eq "(k) missing SHA tool -> E_RUNTIME (exit)" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
assert_eq "(k) missing SHA tool -> E_RUNTIME (token)" "E_RUNTIME" "$out"

noshasumbin="$tmpdir/noshasumbin"
mkdir -p "$noshasumbin"
for b in bash sh jq cat head wc awk tr mktemp rm dirname cmp env printf shasum; do
  p="$(command -v "$b" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$noshasumbin/$b"
done
rm -f "$noshasumbin/sha256sum"
out2="$(PATH="$noshasumbin" bash "$wrapper" validate-document "$tmpdir/profile.json" 2>&1)"
assert_eq "(k) falls back to shasum -a 256 when sha256sum is absent (empty output)" "" "$out2"

echo "== (p) sanitized mktemp -d failure mapping (environment) =="
# A failing `mktemp -d` (read-only/full/unavailable temp dir) must map to sanitized
# E_RUNTIME, not leak mktemp's own raw diagnostic/path past `set -e`. The stub only
# shadows mktemp; every other tool still resolves off the real PATH behind it.
mktemp_diagnostic="mktemp: failed to create a temp directory (stub)"
failmktempbin="$tmpdir/failmktempbin"
mkdir -p "$failmktempbin"
cat > "$failmktempbin/mktemp" <<EOF
#!/usr/bin/env bash
echo "$mktemp_diagnostic /some/local/path" >&2
exit 1
EOF
chmod +x "$failmktempbin/mktemp"
out3="$(PATH="$failmktempbin:$PATH" bash "$wrapper" validate-document "$tmpdir/profile.json" 2>&1 1>/dev/null)" && rc3=0 || rc3=$?
assert_eq "(p) failing mktemp -d (exit nonzero)" "1" "$([ "$rc3" -ne 0 ] && echo 1 || echo 0)"
assert_eq "(p) failing mktemp -d maps to sanitized E_RUNTIME" "E_RUNTIME" "$out3"
assert_not_contains "(p) failing mktemp -d never leaks its raw diagnostic" "$mktemp_diagnostic" "$out3"
# Pair: the normal (succeeding) mktemp path this fix must not regress.
assert_ok "(p) unmutated mktemp path still succeeds" validate-document "$tmpdir/profile.json"

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
