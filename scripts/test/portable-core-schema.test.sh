#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

schema_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
schema_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
schema_base="38a26f5f046897c0455fef24874c5dbb40c20926"
schema_module_dir="$schema_root/core/v1/generations/$schema_generation/modules"
schema_module="$schema_module_dir/schema.jq"
schema_registry="$schema_root/core/v1/generation-registry.json"
schema_fixture="$schema_root/scripts/test/portable-core-schema-fixtures.json"
schema_ledger="$schema_root/scripts/test/portable-core-schema-ledger.tsv"
schema_manifest="$schema_root/ci/required-files.txt"
schema_test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-schema.XXXXXX")"
schema_download=""

cleanup() {
  if [ -n "$schema_download" ] && [ -f "$schema_download" ]; then
    rm -f -- "$schema_download"
  fi
  rm -rf -- "$schema_test_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_text_line() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s\n' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s\n' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

schema_platform="$(uname -s):$(uname -m)"
case "$schema_platform" in
  Linux:x86_64)
    schema_asset="jq-linux64"
    schema_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    schema_asset="jq-osx-amd64"
    schema_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    echo "FAIL: unsupported jq 1.6 proof platform: $schema_platform" >&2
    exit 1
    ;;
esac

schema_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$schema_cache"
schema_jq="$schema_cache/$schema_asset"
if [ ! -f "$schema_jq" ] || [ "$(sha256_path "$schema_jq")" != "$schema_asset_sha256" ]; then
  schema_download="$(mktemp "$schema_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$schema_asset" \
    -o "$schema_download"
  if [ "$(sha256_path "$schema_download")" != "$schema_asset_sha256" ]; then
    echo "FAIL: jq 1.6 release asset digest mismatch" >&2
    exit 1
  fi
  chmod 0555 "$schema_download"
  mv "$schema_download" "$schema_jq"
  schema_download=""
fi

if [ "$(sha256_path "$schema_jq")" != "$schema_asset_sha256" ] ||
   [ "$("$schema_jq" --version)" != "jq-1.6" ]; then
  echo "FAIL: pinned jq 1.6 identity check failed" >&2
  exit 1
fi

schema_failures=0
schema_direct_total=0
schema_direct_passed=0
schema_route_total=0
schema_route_passed=0
schema_registry_total=0
schema_registry_passed=0
schema_guard_total=0
schema_guard_passed=0
schema_numeric_total=0
schema_numeric_passed=0
schema_seen_rules="$schema_test_tmp/seen-rules"
schema_seen_tests="$schema_test_tmp/seen-tests"
: > "$schema_seen_rules"
: > "$schema_seen_tests"

fail_case() {
  echo "FAIL: $1" >&2
  schema_failures=$((schema_failures + 1))
}

expect_jq() {
  local case_id="$1"
  local expected="$2"
  local expression="$3"
  local actual
  schema_direct_total=$((schema_direct_total + 1))
  if ! actual="$("$schema_jq" -L "$schema_module_dir" -n \
      --slurpfile fixture "$schema_fixture" \
      "import \"schema\" as schema; \$fixture[0] as \$f | ($expression)")"; then
    fail_case "$case_id raised a jq error"
    return
  fi
  if [ "$actual" = "$expected" ]; then
    schema_direct_passed=$((schema_direct_passed + 1))
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

expect_true() {
  expect_jq "$1" true "$2"
}

expect_false() {
  expect_jq "$1" false "$2"
}

expect_canonical_raw() {
  local case_id="$1"
  local expected="$2"
  local raw_bytes="$3"
  local raw_input
  local canonical_output
  local actual=false
  schema_numeric_total=$((schema_numeric_total + 1))
  raw_input="$schema_test_tmp/numeric-$schema_numeric_total.input"
  canonical_output="$schema_test_tmp/numeric-$schema_numeric_total.canonical"
  printf '%s' "$raw_bytes" > "$raw_input"
  if "$schema_jq" -s -S -c \
      'if length == 1 then .[0] else error("root-count") end' \
      < "$raw_input" > "$canonical_output" 2>/dev/null &&
     cmp -s "$raw_input" "$canonical_output"; then
    actual=true
  fi
  if [ "$actual" = "$expected" ]; then
    schema_numeric_passed=$((schema_numeric_passed + 1))
  else
    fail_case "$case_id expected canonical=$expected, got canonical=$actual"
  fi
}

mark_rule() {
  printf '%s\n' "$1" >> "$schema_seen_rules"
}

mark_test() {
  printf '%s\n' "$1" >> "$schema_seen_tests"
}

mark_rule portable-core-schema.active-pinned-jq16-ci
mark_test portable-core-schema.test.active-pinned-jq16-ci
expect_true exact-fields-valid '{a:1} | schema::exact_fields(["a"];[])'
expect_false exact-fields-extra '{a:1,b:2} | schema::exact_fields(["a"];[])'
mark_rule portable-core-schema.exact-fields

expect_true bounded-set-min-max '["a","b"] | schema::bounded_set(1;2;type == "string";.)'
expect_false bounded-set-reversed '["b","a"] | schema::bounded_set(1;2;type == "string";.)'
expect_false bounded-set-duplicate '["a","a"] | schema::bounded_set(1;2;type == "string";.)'
expect_false bounded-set-one-over '["a","b","c"] | schema::bounded_set(1;2;type == "string";.)'
mark_rule portable-core-schema.set-sorted-unique
mark_test portable-core-schema.test.set-reversed-and-duplicate-rejected

expect_true permission-set-order-valid \
  '["core.perm.evidence.write.v1","core.perm.target.read.v1"] | schema::enum_set_ok(0;5;schema::permission_ids)'
expect_false permission-set-order-invalid \
  '["core.perm.target.read.v1","core.perm.evidence.write.v1"] | schema::enum_set_ok(0;5;schema::permission_ids)'
mark_rule portable-core-schema.permission-set-order
mark_test portable-core-schema.test.legacy-097-offered-permissions-enum-set-not-in-canonical-sorted-order

expect_true present-absent '{state:"absent"} | schema::present_ok(schema::id_ok)'
expect_true present-value '{state:"present",value:"value.example"} | schema::present_ok(schema::id_ok)'
expect_false present-null '{state:"present",value:null} | schema::present_ok(schema::id_ok)'
expect_false present-extra '{state:"absent",value:"no"} | schema::present_ok(schema::id_ok)'
mark_rule portable-core-schema.present-union

expect_true id-boundary '(("a" * 128) | schema::id_ok) and ("a" | schema::id_ok)'
expect_false id-one-over '("a" * 129) | schema::id_ok'
expect_false id-uppercase '"Bad" | schema::id_ok'
mark_rule portable-core-schema.id

expect_true int-boundaries '(0 | schema::int_ok) and (2147483647 | schema::int_ok)'
expect_false int-negative '-1 | schema::int_ok'
expect_false int-one-over '2147483648 | schema::int_ok'
expect_false int-float '1.5 | schema::int_ok'
expect_false int-negative-zero '-0 | schema::int_ok'
expect_canonical_raw raw-integer true $'1\n'
expect_canonical_raw raw-integral-float false $'1.0\n'
expect_canonical_raw raw-integral-exponent false $'1e0\n'
expect_canonical_raw raw-fraction true $'1.5\n'
expect_canonical_raw raw-negative-zero true $'-0\n'
expect_canonical_raw raw-integer-field-float false $'{"attempt":1.0}\n'
expect_canonical_raw raw-schema-version-float false \
  $'{"body":{},"id":"doc.example","kind":"profile","schema_version":1.0}\n'
expect_canonical_raw raw-schema-version-integer true \
  $'{"body":{},"id":"doc.example","kind":"profile","schema_version":1}\n'
mark_rule portable-core-schema.integer-domain
mark_test portable-core-schema.test.legacy-075-float-value
mark_test portable-core-schema.test.legacy-077-negative-integer
mark_test portable-core-schema.test.legacy-079-integer-over-2147483647

expect_true sha-valid '$f.valid.sha256 | schema::sha256_ok'
expect_false sha-invalid '"Aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" | schema::sha256_ok'
mark_rule portable-core-schema.sha256

expect_true short-text-boundary '(("a" * 1024) | schema::short_text_ok) and ("é" | schema::short_text_ok)'
expect_false short-text-empty '"" | schema::short_text_ok'
expect_false short-text-one-over '("a" * 1025) | schema::short_text_ok'
expect_false short-text-byte-over '("é" * 513) | schema::short_text_ok'
mark_rule portable-core-schema.short-text

expect_true time-valid-leap '"2024-02-29T23:59:59Z" | schema::time_ok'
expect_false time-malformed '"2024-2-29T00:00:00Z" | schema::time_ok'
expect_false time-fields '"2024-13-01T24:60:60Z" | schema::time_ok'
expect_false time-calendar '"2024-04-31T00:00:00Z" | schema::time_ok'
expect_false time-non-leap '"2025-02-29T00:00:00Z" | schema::time_ok'
mark_rule portable-core-schema.utc-timestamp-valid-instant
mark_rule portable-core-schema.time
mark_test portable-core-schema.test.utc-timestamp-field-range-rejected
mark_test portable-core-schema.test.utc-timestamp-calendar-date-rejected
mark_test portable-core-schema.test.legacy-153-malformed-requested-at
mark_test portable-core-schema.test.legacy-159-requested-at-with-out-of-range-month-day-time-components
mark_test portable-core-schema.test.legacy-163-requested-at-names-a-day-the-month-does-not-have
mark_test portable-core-schema.test.legacy-165-requested-at-names-feb-29-in-a-non-leap-year
mark_test portable-core-schema.test.legacy-167-requested-at-names-feb-29-in-a-real-leap-year

expect_true media-boundary '("a/" + ("b" * 125)) | schema::media_type_ok'
expect_false media-one-over '("a/" + ("b" * 126)) | schema::media_type_ok'
expect_false media-uppercase '"Application/json" | schema::media_type_ok'
mark_rule portable-core-schema.media-type

expect_true patch-media-valid '"text/x-diff" | schema::patch_media_type_ok'
expect_false patch-media-invalid '"application/json" | schema::patch_media_type_ok'
mark_rule portable-core-schema.patch-media-type

expect_true git-oid-boundaries '("a" * 40 | schema::git_oid_ok) and ("b" * 64 | schema::git_oid_ok)'
expect_false git-oid-invalid '("a" * 41) | schema::git_oid_ok'
mark_rule portable-core-schema.git-oid

expect_true reverse-dns-boundaries '("a.b" | schema::reverse_dns_ok) and (("a" * 63) + ".b" | schema::reverse_dns_ok)'
expect_false reverse-dns-label-over '(("a" * 64) + ".b") | schema::reverse_dns_ok'
expect_false reverse-dns-edge-hyphen '"-a.example" | schema::reverse_dns_ok'
mark_rule portable-core-schema.reverse-dns

expect_true repo-path-unicode '"src/合法.json" | schema::repo_path_ok'
expect_false repo-path-empty '"" | schema::repo_path_ok'
expect_false repo-path-dot '"src/../secret" | schema::repo_path_ok'
expect_false repo-path-backslash '"src\\secret" | schema::repo_path_ok'
expect_false repo-path-del '("src/" + ([127] | implode)) | schema::repo_path_ok'
expect_false repo-path-c1-low '("src/" + ([128] | implode)) | schema::repo_path_ok'
expect_false repo-path-c1-high '("src/" + ([159] | implode)) | schema::repo_path_ok'
mark_rule portable-core-schema.repository-path-no-controls
mark_rule portable-core-schema.repo-path-controls
mark_test portable-core-schema.test.repository-path-del-c1-rejected
mark_test portable-core-schema.test.legacy-131-repository-path-containing-del-u-plus-007f
mark_test portable-core-schema.test.legacy-133-repository-path-containing-a-c1-control-character-u-plus-0080
mark_test portable-core-schema.test.legacy-135-repository-path-containing-a-c1-control-character-u-plus-009f-top-of-range
mark_test portable-core-schema.test.legacy-137-repository-path-with-a-non-control-non-ascii-character-stays-legal

expect_true depth-boundary \
  'def nest($n): reduce range(0;$n) as $i (0; [.]); nest(32) | schema::parsed_limits_ok'
expect_false depth-one-over \
  'def nest($n): reduce range(0;$n) as $i (0; [.]); nest(33) | schema::parsed_limits_ok'
mark_rule portable-core-schema.parsed-depth-limit
mark_test portable-core-schema.test.legacy-065-depth-33-one-over-the-32-limit

expect_true member-boundaries \
  '([range(0;256)] | schema::parsed_limits_ok) and (reduce range(0;256) as $i ({}; .["k\($i)"]=$i) | schema::parsed_limits_ok)'
expect_false array-member-one-over '[range(0;257)] | schema::parsed_limits_ok'
expect_false object-member-one-over 'reduce range(0;257) as $i ({}; .["k\($i)"]=$i) | schema::parsed_limits_ok'
mark_rule portable-core-schema.parsed-member-limit
mark_test portable-core-schema.test.legacy-067-257-object-members-one-over-the-256-limit

expect_true decoded-string-boundary '("a" * 8192) | schema::parsed_limits_ok'
expect_false decoded-string-one-over '("a" * 8193) | schema::parsed_limits_ok'
expect_true decoded-key-boundary '{(("a" * 8192)):0} | schema::parsed_limits_ok'
expect_false decoded-key-one-over '{(("a" * 8193)):0} | schema::parsed_limits_ok'
expect_true decoded-multibyte-boundary '("é" * 4096) | schema::parsed_limits_ok'
expect_false decoded-multibyte-one-over '("é" * 4097) | schema::parsed_limits_ok'
mark_rule portable-core-schema.decoded-string-limit
mark_rule portable-core-schema.decoded-string-byte-limit
mark_test portable-core-schema.test.oversize-object-key-e-limit
mark_test portable-core-schema.test.legacy-069-decoded-string-8-193-bytes-one-over-the-8-192-limit
mark_test portable-core-schema.test.legacy-071-decoded-object-key-8-193-bytes-one-over-the-8-192-limit
mark_test portable-core-schema.test.legacy-073-8-192-byte-object-key-is-at-the-limit-not-over-it-shape-failure-not-e-limit

expect_true parsed-non-numeric-scalars '[true,false,null] | schema::parsed_limits_ok'

expect_true policy-literal-registries \
  'schema::semantic_identity == "core.contracts.v1" and schema::document_kinds == $f.policy_expectation.document_kinds and schema::adapter_roles == $f.policy_expectation.adapter_roles and schema::actor_roles == $f.policy_expectation.actor_roles and schema::capability_ids == $f.policy_expectation.capability_ids and schema::permission_ids == $f.policy_expectation.permission_ids and schema::evidence_kinds == $f.policy_expectation.evidence_kinds'
expect_true policy-exact-mappings \
  'schema::protected_roles == ["producer","publisher","reviewer","verifier"] and schema::capabilities_for_role("producer") == ["core.harness.produce.v1"] and schema::capabilities_for_role("publisher") == [] and schema::capabilities_for_role("unknown") == [] and schema::execution_kinds_for_role("reviewer") == ["deterministic","model"] and schema::execution_kinds_for_role("verifier") == ["deterministic"] and schema::permissions_for_capability("core.verify.run.v1";"deterministic") == ["core.perm.candidate.execute.v1","core.perm.evidence.write.v1","core.perm.target.read.v1"] and schema::permissions_for_capability("core.verify.run.v1";"model") == [] and schema::allowed_evidence_kinds_for_capability("core.verify.run.v1") == ["architecture","behavioral","deterministic"] and schema::required_evidence_kinds_for_capability("core.review.change.v1") == ["independent-review"] and schema::evidence_verdicts == ["failed","inconclusive","passed"]'
expect_false policy-unknowns \
  '("core.verify" | schema::capability_id_ok) or ("core.perm.*" | schema::permission_id_ok) or ("review" | schema::evidence_kind_ok) or ("human" | schema::adapter_role_ok)'
schema_policy_json="$("$schema_jq" -L "$schema_module_dir" -S -c -n 'import "schema" as schema; schema::policy_table')"
schema_direct_total=$((schema_direct_total + 1))
if [ "$(sha256_text_line "$schema_policy_json")" != \
     "$("$schema_jq" -r '.policy_expectation.canonical_sha256' "$schema_fixture")" ]; then
  fail_case "policy table canonical digest"
else
  schema_direct_passed=$((schema_direct_passed + 1))
fi
mark_rule portable-core-schema.policy-table

expect_true document-kind-valid 'all($f.valid.envelopes[]; .kind | schema::document_kind_ok)'
expect_false document-kind-unknown '"stage" | schema::document_kind_ok'
mark_rule portable-core-schema.document-kind

expect_true envelope-five-kinds 'all($f.valid.envelopes[]; . as $doc | $doc | schema::envelope_ok($doc.kind))'
expect_false envelope-unknown '$f.valid.envelopes[0] + {kind:"unknown"} | schema::document_envelope_ok'
mark_rule portable-core-schema.envelope-kind
mark_test portable-core-schema.test.legacy-093-unknown-document-kind
expect_false envelope-version '$f.valid.envelopes[0] + {schema_version:2} | schema::document_envelope_ok'
mark_rule portable-core-schema.envelope-version
mark_test portable-core-schema.test.legacy-095-wrong-schema-version
expect_false envelope-extra '$f.valid.envelopes[0] + {extra:true} | schema::document_envelope_ok'
expect_false envelope-body-type '$f.valid.envelopes[0] + {body:[]} | schema::document_envelope_ok'
mark_rule portable-core-schema.envelope-exact-fields

expect_true document-ref-valid '$f.valid.document_ref | schema::document_ref_kind_ok("stage_result")'
expect_false document-ref-kind '$f.valid.document_ref + {kind:"unknown"} | schema::document_ref_ok'
mark_rule portable-core-schema.document-ref-kind
mark_test portable-core-schema.test.legacy-161-named-input-document-ref-with-an-unknown-document-kind

expect_true git-revision-valid '$f.valid.git_revision_sha1 | schema::git_revision_ref_ok'
expect_false git-revision-algorithm '$f.valid.git_revision_sha1 + {hash_algorithm:"sha256"} | schema::git_revision_ref_ok'
mark_rule portable-core-schema.git-revision-ref

expect_true git-location-variants '({kind:"root"} | schema::git_location_ok) and ({kind:"path",value:"src/main"} | schema::git_location_ok)'
expect_false git-location-invalid '{kind:"path",value:"../main"} | schema::git_location_ok'
mark_rule portable-core-schema.git-location

expect_true git-object-variants '($f.valid.git_blob | schema::git_object_ref_ok) and ($f.valid.git_tree | schema::git_object_ref_ok)'
expect_false git-object-mode '$f.valid.git_blob + {mode:"120000"} | schema::git_object_ref_ok'
expect_false git-object-root-blob '$f.valid.git_blob + {location:{kind:"root"}} | schema::git_object_ref_ok'
mark_rule portable-core-schema.git-object-ref

expect_true content-ref-valid '$f.valid.content_ref | schema::content_ref_ok'
expect_false content-ref-invalid '$f.valid.content_ref + {media_type:"Application/json"} | schema::content_ref_ok'
expect_false content-ref-url-id '$f.valid.content_ref + {content_id:"https:payload"} | schema::content_ref_ok'
expect_false content-ref-path-id '$f.valid.content_ref + {content_id:"path/value"} | schema::content_ref_ok'
mark_rule portable-core-schema.content-ref

expect_true artifact-ref-variants '({type:"git-object",value:$f.valid.git_blob} | schema::artifact_ref_ok) and ({type:"content",value:$f.valid.content_ref} | schema::artifact_ref_ok)'
expect_false artifact-ref-invalid '{type:"url",value:$f.valid.content_ref} | schema::artifact_ref_ok'
mark_rule portable-core-schema.artifact-ref

expect_true input-ref-variants '({type:"artifact",value:{type:"content",value:$f.valid.content_ref}} | schema::input_ref_ok) and ({type:"document",value:$f.valid.document_ref} | schema::input_ref_ok)'
expect_false input-ref-invalid '{type:"document",value:$f.valid.content_ref} | schema::input_ref_ok'
mark_rule portable-core-schema.input-ref

expect_true evidence-ref-valid '{stage_result_ref:$f.valid.document_ref,evidence_id:"evidence.example"} | schema::evidence_ref_ok'
expect_false evidence-ref-kind '{stage_result_ref:($f.valid.document_ref + {kind:"profile"}),evidence_id:"evidence.example"} | schema::evidence_ref_ok'
mark_rule portable-core-schema.evidence-ref

expect_true scope-ref-valid '$f.valid.scope_ref | schema::scope_ref_purpose_ok("policy")'
expect_false scope-ref-invalid '$f.valid.scope_ref + {purpose:"trust"} | schema::scope_ref_ok'
mark_rule portable-core-schema.scope-ref

expect_true actor-ref-valid '{role:"producer",implementation_id:"implementation.example",implementation_version:"v1",adapter_instance_id:"instance.example",principal_id:"principal.example",execution_boundary_id:"boundary.example",authority_ref:$f.valid.authority_ref} | schema::actor_ref_ok'
expect_false actor-ref-invalid '{role:"human",implementation_id:"implementation.example",implementation_version:"v1",adapter_instance_id:"instance.example",principal_id:"principal.example",execution_boundary_id:"boundary.example"} | schema::actor_ref_ok'
mark_rule portable-core-schema.actor-ref

expect_true environment-ref-valid '{environment_id:"environment.example",fingerprint_sha256:$f.valid.sha256} | schema::environment_ref_ok'
expect_false environment-ref-invalid '{environment_id:"environment.example",fingerprint_sha256:"bad"} | schema::environment_ref_ok'
mark_rule portable-core-schema.environment-ref

expect_true tool-ref-valid '$f.valid.tool_ref | schema::tool_ref_ok'
expect_false tool-ref-invalid '$f.valid.tool_ref + {config_ref:{state:"present",value:$f.valid.content_ref}} | schema::tool_ref_ok'
mark_rule portable-core-schema.tool-ref

expect_true git-patch-valid '$f.valid.patch_ref | schema::git_patch_ref_ok'
expect_false git-patch-invalid '$f.valid.content_ref | schema::git_patch_ref_ok'
mark_rule portable-core-schema.git-patch-ref

expect_true change-ref-valid '{repository_id:"repo.example",base:{state:"absent"},head:$f.valid.git_revision_sha1,delta_ref:$f.valid.patch_ref} | schema::change_ref_ok'
expect_false change-ref-repository '{repository_id:"other.example",base:{state:"absent"},head:$f.valid.git_revision_sha1,delta_ref:$f.valid.patch_ref} | schema::change_ref_ok'
mark_rule portable-core-schema.change-ref

expect_true source-value-valid '{source:$f.valid.git_blob,value_format:"canonical-json",value_sha256:$f.valid.sha256} | schema::source_value_ref_ok'
expect_false source-value-tree '{source:$f.valid.git_tree,value_format:"canonical-json",value_sha256:$f.valid.sha256} | schema::source_value_ref_ok'
mark_rule portable-core-schema.source-value-ref
mark_test portable-core-schema.test.legacy-127-canonical-json-source-pointing-at-a-tree-not-a-blob

expect_true delivered-scope-valid '{ref:{purpose:"output-contract",decision_record_ref:$f.valid.content_ref,subject_ref:{type:"artifact",value:{type:"content",value:$f.valid.content_ref}},scope_sha256:$f.valid.sha256},input_id:"input.example"} | schema::delivered_scope_ok("output-contract")'
expect_false delivered-scope-document '{ref:{purpose:"output-contract",decision_record_ref:$f.valid.content_ref,subject_ref:{type:"document",value:$f.valid.document_ref},scope_sha256:$f.valid.sha256},input_id:"input.example"} | schema::delivered_scope_ok("output-contract")'
mark_rule portable-core-schema.delivered-scope

expect_true fact-variants '({state:"recorded",value:"value.example",source_ref:$f.valid.content_ref} | schema::fact_ok(schema::id_ok)) and ({state:"computed",value:"value.example",source_ref:$f.valid.content_ref} | schema::fact_ok(schema::id_ok)) and ({state:"unavailable",reason_id:"reason.example"} | schema::fact_ok(schema::id_ok)) and ({state:"not-applicable"} | schema::fact_ok(schema::id_ok))'
expect_false fact-invalid '{state:"recorded",value:"value.example"} | schema::fact_ok(schema::id_ok)'
mark_rule portable-core-schema.fact-union

schema_route_total=13
schema_route_program='
  import "schema" as schema;
  $fixture[0] as $f |
  def poison: .body = (reduce range(0;33) as $i (0; [.])) ;
  def route_ok($docs): all($docs[]; schema::schema_layer_ok);
  ($f.valid.envelopes | all(.[]; schema::schema_layer_ok)) and
  route_ok([$f.valid.envelopes[1],$f.valid.envelopes[2],$f.valid.envelopes[0]]) and
  route_ok([$f.valid.envelopes[3],$f.valid.envelopes[2],$f.valid.envelopes[4]]) and
  (all(range(0;5); . as $i | ($f.valid.envelopes | .[$i] |= poison | route_ok(.) | not))) and
  (all(range(0;3); . as $i | ([$f.valid.envelopes[1],$f.valid.envelopes[2],$f.valid.envelopes[0]] | .[$i] |= poison | route_ok(.) | not))) and
  (all(range(0;3); . as $i | ([$f.valid.envelopes[3],$f.valid.envelopes[2],$f.valid.envelopes[4]] | .[$i] |= poison | route_ok(.) | not)))
'
if "$schema_jq" -L "$schema_module_dir" -e -n --slurpfile fixture "$schema_fixture" \
    "$schema_route_program" >/dev/null; then
  schema_route_passed=$schema_route_total
else
  fail_case "schema layer route and forced-route proof"
fi
mark_rule portable-core-schema.schema-route-all-docs

schema_registry_total=7
schema_canonical_registry="$schema_test_tmp/registry.canonical.json"
"$schema_jq" -S -c . "$schema_registry" > "$schema_canonical_registry"
if cmp -s "$schema_registry" "$schema_canonical_registry"; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "registry is not canonical jq 1.6 JSON plus one LF"
fi
if "$schema_jq" -e --arg generation "$schema_generation" \
    --arg spec "c6511d96c1a5e6aed27ba2075b5add65c121f782" \
    --arg authorization "$schema_base" \
    'length == 1 and .[0] == {generation_id:$generation,parent_spec_blob:$spec,parent_plan_merge_commit:$authorization}' \
    "$schema_registry" >/dev/null; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "registry exact construction entry"
fi
if "$schema_jq" -e '
    all(.[]; (keys | sort) == ["generation_id","parent_plan_merge_commit","parent_spec_blob"] and
      (.generation_id | test("^g-[0-9a-f]{64}$")) and
      (.parent_spec_blob | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$")) and
      (.parent_plan_merge_commit | test("^[0-9a-f]{40}$|^[0-9a-f]{64}$"))) and
    (map(.generation_id) | length) == (map(.generation_id) | unique | length)
  ' "$schema_registry" >/dev/null; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "registry entry shape and uniqueness"
fi
if "$schema_jq" -e --arg base "$schema_base" \
    '.metadata.construction_base == $base and .metadata.prior_registry_entries == 0' \
    "$schema_fixture" >/dev/null; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "first-publication prior-registry tuple"
fi
if "$schema_jq" -n -e '
    def prefix($prior;$candidate):
      ($candidate | length) >= ($prior | length) and
      $candidate[0:($prior | length)] == $prior;
    prefix([{generation_id:"g-a"}];[{generation_id:"g-a"},{generation_id:"g-b"}]) and
    (prefix([{generation_id:"g-a"}];[{generation_id:"g-b"}]) | not) and
    (prefix([{generation_id:"g-a"},{generation_id:"g-b"}];[{generation_id:"g-b"},{generation_id:"g-a"}]) | not)
  ' >/dev/null; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "registry ordered-prefix positive and negative cases"
fi
if "$schema_jq" -n -e '
    def unique_ids($entries):
      ($entries | map(.generation_id) | length) ==
      ($entries | map(.generation_id) | unique | length);
    unique_ids([{generation_id:"g-a"},{generation_id:"g-b"}]) and
    (unique_ids([{generation_id:"g-a"},{generation_id:"g-a"}]) | not)
  ' >/dev/null; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "registry duplicate generation rejection"
fi
schema_prior_lines="$("$schema_jq" -r '.metadata.prior_manifest_lines' "$schema_fixture")"
schema_prior_digest="$("$schema_jq" -r '.metadata.prior_manifest_sha256' "$schema_fixture")"
head -n "$schema_prior_lines" "$schema_manifest" > "$schema_test_tmp/manifest-prefix"
schema_manifest_start=$((schema_prior_lines + 1))
schema_manifest_end=$((schema_prior_lines + 7))
schema_manifest_block="$(sed -n "${schema_manifest_start},${schema_manifest_end}p" "$schema_manifest")"
schema_expected_block="$(printf '\n# Inactive portable core generation under construction\ncore/v1/generation-registry.json\ncore/v1/generations/%s/modules/schema.jq\nscripts/test/portable-core-schema-fixtures.json\nscripts/test/portable-core-schema-ledger.tsv\nscripts/test/portable-core-schema.test.sh' "$schema_generation")"
if [ "$(sha256_path "$schema_test_tmp/manifest-prefix")" = "$schema_prior_digest" ] &&
   [ "$schema_manifest_block" = "$schema_expected_block" ]; then
  schema_registry_passed=$((schema_registry_passed + 1))
else
  fail_case "required-files deterministic append proof"
fi
mark_rule portable-core-schema.generation-registry-entry
mark_rule portable-core-schema.generation-registry-prefix

private_generation_path_ok() {
  case "$1" in
    "core/v1/generations/$schema_generation/core-ingress.sh"|\
    "core/v1/generations/$schema_generation/modules/schema.jq"|\
    "core/v1/generations/$schema_generation/modules/profile_graph.jq"|\
    "core/v1/generations/$schema_generation/modules/stage_request.jq"|\
    "core/v1/generations/$schema_generation/modules/result_facts.jq"|\
    "core/v1/generations/$schema_generation/modules/result_truth.jq") return 0 ;;
    *) return 1 ;;
  esac
}

guard_paths_ok() {
  local paths_file="$1"
  local generation_path
  while IFS= read -r generation_path; do
    private_generation_path_ok "$generation_path" || return 1
  done < "$paths_file"
}

schema_guard_total=25
schema_generation_files="$schema_test_tmp/generation-files"
find "$schema_root/core/v1/generations/$schema_generation" -type f -print | \
  sed "s#^$schema_root/##" | LC_ALL=C sort > "$schema_generation_files"
if guard_paths_ok "$schema_generation_files" &&
   grep -Fqx "core/v1/generations/$schema_generation/modules/schema.jq" \
     "$schema_generation_files" &&
   [ ! -e "$schema_root/scripts/core-contract.sh" ] &&
   [ ! -e "$schema_root/core/v1/generations/$schema_generation/contracts.jq" ] &&
   [ -z "$(find "$schema_root/core/v1/generations/$schema_generation" -type l -print -quit)" ]; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "incomplete generation has a public, unknown, missing, or symlink member"
fi
if [ -d "$schema_module_dir" ] && [ ! -L "$schema_module_dir" ] &&
   [ -f "$schema_module" ] && [ ! -L "$schema_module" ] &&
   [ -f "$schema_registry" ] && [ ! -L "$schema_registry" ]; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "private generation path must be real directories and regular files"
fi
if ! grep -Eq '^[[:space:]]*(import|include|module)[[:space:](]' "$schema_module"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "schema module must remain import-free"
fi
schema_fake_home="$schema_test_tmp/fake-home"
schema_fake_cwd="$schema_test_tmp/fake-cwd"
schema_driver_dir="$schema_test_tmp/fixed-driver"
mkdir -p "$schema_fake_home/.jq" "$schema_fake_cwd" "$schema_driver_dir"
printf '%s\n' 'def semantic_identity: "poison";' > "$schema_fake_home/.jq/schema.jq"
printf '%s\n' 'def semantic_identity: "poison";' > "$schema_fake_cwd/schema.jq"
printf '%s\n' 'import "schema" as schema; schema::semantic_identity' > \
  "$schema_driver_dir/driver.jq"
schema_loaded_identity="$(
  cd "$schema_fake_cwd"
  cd "$schema_module_dir"
  env HOME="$schema_fake_home" JQ_LIBRARY_PATH="$schema_fake_cwd" \
    "$schema_jq" -L "$schema_module_dir" -r -n -f "$schema_driver_dir/driver.jq"
)"
if [ "$schema_loaded_identity" = "core.contracts.v1" ]; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "ambient module path changed the fixed schema import"
fi
tracked_activation_paths_ok() {
  local paths_file="$1"
  local activation_path
  local test_path
  while IFS= read -r activation_path; do
    case "$activation_path" in
      ci/required-files.txt|core/v1/generation-registry.json) ;;
      scripts/test/portable-core-*)
        test_path="${activation_path#scripts/test/}"
        case "$test_path" in */*) return 1 ;; esac
        ;;
      *) private_generation_path_ok "$activation_path" || return 1 ;;
    esac
  done < "$paths_file"
}

schema_live_hits="$schema_test_tmp/live-hits"
schema_import_hits="$schema_test_tmp/import-hits"
: > "$schema_live_hits"
: > "$schema_import_hits"
schema_import_pattern='(^|[^A-Za-z0-9_])(import|include)[[:space:]]*"schema"'
while IFS= read -r -d '' schema_tracked_path; do
  if ! schema_scan_result="$(
    git -C "$schema_root" show ":$schema_tracked_path" 2>/dev/null |
      "$schema_jq" -Rsr \
        --arg generation "$schema_generation" \
        --arg import_pattern "$schema_import_pattern" \
        '[contains($generation),test($import_pattern)] | @tsv'
  )"; then
    fail_case "unable to scan tracked path: $schema_tracked_path"
    continue
  fi
  IFS=$'\t' read -r schema_has_generation schema_has_import <<< "$schema_scan_result"
  if [ "$schema_has_generation" = true ]; then
    printf '%s\n' "$schema_tracked_path" >> "$schema_live_hits"
  fi
  if [ "$schema_has_import" = true ]; then
    printf '%s\n' "$schema_tracked_path" >> "$schema_import_hits"
  fi
done < <(git -C "$schema_root" ls-files -z)

if tracked_activation_paths_ok "$schema_live_hits"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "generation ID appears outside the closed tracked-path allowlist"
fi
if tracked_activation_paths_ok "$schema_import_hits"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "schema import appears outside the closed tracked-path allowlist"
fi

for schema_invalid_path in \
  .claude/hooks/portable-core-loader.sh \
  core/other/loader.jq \
  docs/portable-core.md \
  scripts/portable-core-loader.sh; do
  printf '%s\n' "$schema_invalid_path" > "$schema_test_tmp/invalid-tracked-path"
  if ! tracked_activation_paths_ok "$schema_test_tmp/invalid-tracked-path"; then
    schema_guard_passed=$((schema_guard_passed + 1))
  else
    fail_case "tracked-path guard accepted: $schema_invalid_path"
  fi
done

schema_load_case() {
  local case_id="$1"
  local expected="$2"
  local source_text="$3"
  local source_file="$schema_test_tmp/$case_id.jq"
  local actual=false
  printf '%s' "$source_text" > "$source_file"
  if "$schema_jq" -Rse --arg pattern "$schema_import_pattern" \
      'test($pattern)' < "$source_file" >/dev/null; then
    actual=true
  fi
  if [ "$actual" = "$expected" ]; then
    schema_guard_passed=$((schema_guard_passed + 1))
  else
    fail_case "$case_id expected schema-load=$expected, got schema-load=$actual"
  fi
}

schema_load_case import-spaced true $'import "schema" as s;\n'
schema_load_case import-compact true $'import"schema"as s;\n'
schema_load_case import-arbitrary-alias true $'import "schema" as any_alias_42;\n'
schema_load_case import-newlines true $'import\n  "schema"\n as\n another_alias;\n'
schema_load_case import-metadata true $'import"schema"as s {search:"."};\n'
schema_load_case include-spaced true $'include "schema";\n'
schema_load_case include-compact true $'include"schema";\n'
schema_load_case include-newlines true $'include\n  "schema"  ;\n'
schema_load_case other-module false $'import "profile_graph" as schema;\n'
schema_load_case longer-module false $'include "schema-extra";\n'
schema_load_case keyword-substring false $'myimport"schema"as s;\n'
if guard_paths_ok "$schema_generation_files"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "private guard rejected the real generation layout"
fi
cp "$schema_generation_files" "$schema_test_tmp/growing-generation-files"
printf '%s\n' \
  "core/v1/generations/$schema_generation/core-ingress.sh" \
  "core/v1/generations/$schema_generation/modules/profile_graph.jq" \
  "core/v1/generations/$schema_generation/modules/stage_request.jq" \
  "core/v1/generations/$schema_generation/modules/result_facts.jq" \
  "core/v1/generations/$schema_generation/modules/result_truth.jq" >> \
  "$schema_test_tmp/growing-generation-files"
if guard_paths_ok "$schema_test_tmp/growing-generation-files"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "private guard rejected accepted growing private members"
fi
cp "$schema_generation_files" "$schema_test_tmp/invalid-generation-files"
printf '%s\n' "core/v1/generations/$schema_generation/contracts.jq" >> \
  "$schema_test_tmp/invalid-generation-files"
if ! guard_paths_ok "$schema_test_tmp/invalid-generation-files"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "private guard accepted a synthetic public root"
fi
cp "$schema_generation_files" "$schema_test_tmp/unknown-generation-files"
printf '%s\n' "core/v1/generations/$schema_generation/modules/unknown.jq" >> \
  "$schema_test_tmp/unknown-generation-files"
if ! guard_paths_ok "$schema_test_tmp/unknown-generation-files"; then
  schema_guard_passed=$((schema_guard_passed + 1))
else
  fail_case "private guard accepted a synthetic unknown member"
fi
mark_rule portable-core-schema.private-activation-guard

schema_manifest_paths="core/v1/generation-registry.json
core/v1/generations/$schema_generation/modules/schema.jq
scripts/test/portable-core-schema-fixtures.json
scripts/test/portable-core-schema-ledger.tsv
scripts/test/portable-core-schema.test.sh"
while IFS= read -r schema_required_path; do
  [ -n "$schema_required_path" ] || continue
  schema_manifest_count="$(grep -Fxc "$schema_required_path" "$schema_manifest" || true)"
  if [ "$schema_manifest_count" -ne 1 ] || [ ! -f "$schema_root/$schema_required_path" ]; then
    fail_case "restore manifest entry: $schema_required_path"
  fi
done <<< "$schema_manifest_paths"

schema_mapping_digest="$("$schema_jq" -r '.metadata.schema_mapping_sha256' "$schema_fixture")"
if [ "$(sha256_path "$schema_ledger")" != "$schema_mapping_digest" ]; then
  fail_case "schema ledger mapping digest"
fi
schema_review_total="$(awk -F '\t' 'NR > 1 && $1 == "review" {count++} END {print count + 0}' "$schema_ledger")"
schema_legacy_total="$(awk -F '\t' 'NR > 1 && $1 == "legacy" {count++} END {print count + 0}' "$schema_ledger")"
schema_expected_review="$("$schema_jq" -r '.metadata.review_rows' "$schema_fixture")"
schema_expected_legacy="$("$schema_jq" -r '.metadata.legacy_rows' "$schema_fixture")"
if [ "$schema_review_total" -ne "$schema_expected_review" ]; then
  fail_case "review ledger row count"
fi
if [ "$schema_legacy_total" -ne "$schema_expected_legacy" ]; then
  fail_case "legacy ledger row count"
fi
if [ "$(tail -n +2 "$schema_ledger" | cut -f2 | sort -u | wc -l | tr -d ' ')" -ne 52 ]; then
  fail_case "ledger row IDs are not unique"
fi
schema_expected_rules="$schema_test_tmp/expected-rules"
"$schema_jq" -r '.owned_rules[]' "$schema_fixture" | LC_ALL=C sort > "$schema_expected_rules"
LC_ALL=C sort "$schema_seen_rules" > "$schema_test_tmp/seen-rules.sorted"
if ! cmp -s "$schema_expected_rules" "$schema_test_tmp/seen-rules.sorted"; then
  fail_case "owned-rule inventory does not match executed rule proof"
fi
schema_expected_tests="$schema_test_tmp/expected-tests"
tail -n +2 "$schema_ledger" | cut -f5 | LC_ALL=C sort -u > "$schema_expected_tests"
LC_ALL=C sort "$schema_seen_tests" > "$schema_test_tmp/seen-tests.sorted"
if ! cmp -s "$schema_expected_tests" "$schema_test_tmp/seen-tests.sorted"; then
  fail_case "ledger test IDs do not match the executed stable-ID inventory"
fi
while IFS=$'\t' read -r schema_source schema_row schema_disposition schema_rule schema_test_id; do
  [ "$schema_source" != "source" ] || continue
  if ! grep -Fqx "$schema_rule" "$schema_expected_rules" ||
     ! grep -Fqx "$schema_test_id" "$schema_test_tmp/seen-tests.sorted" ||
     [[ ! "$schema_row" =~ ^(review-r[0-3]-f[0-9]{2}|legacy-test-[0-9]{3})$ ]] ||
     [[ ! "$schema_disposition" =~ ^(ported|replaced-by)$ ]]; then
    fail_case "invalid ledger mapping row: $schema_row"
  fi
done < "$schema_ledger"

schema_review_accounted="$(awk -F '\t' '
  NR == FNR {executed[$1] = 1; next}
  FNR > 1 && $1 == "review" && ($5 in executed) {count++}
  END {print count + 0}
' "$schema_test_tmp/seen-tests.sorted" "$schema_ledger")"
schema_legacy_accounted="$(awk -F '\t' '
  NR == FNR {executed[$1] = 1; next}
  FNR > 1 && $1 == "legacy" && ($5 in executed) {count++}
  END {print count + 0}
' "$schema_test_tmp/seen-tests.sorted" "$schema_ledger")"
if [ "$schema_review_accounted" -ne "$schema_review_total" ]; then
  fail_case "unexecuted review-ledger test mapping"
fi
if [ "$schema_legacy_accounted" -ne "$schema_legacy_total" ]; then
  fail_case "unexecuted legacy-ledger test mapping"
fi

schema_owned_total="$(wc -l < "$schema_expected_rules" | tr -d ' ')"
schema_owned_passed="$schema_owned_total"
if [ "$schema_failures" -ne 0 ]; then
  schema_owned_passed=0
fi

printf 'owned rules: %s/%s\n' "$schema_owned_passed" "$schema_owned_total"
printf 'direct cases: %s/%s\n' "$schema_direct_passed" "$schema_direct_total"
printf 'private route probes: %s/%s\n' "$schema_route_passed" "$schema_route_total"
printf 'registry cases: %s/%s\n' "$schema_registry_passed" "$schema_registry_total"
printf 'activation guard cases: %s/%s\n' "$schema_guard_passed" "$schema_guard_total"
printf 'numeric boundary cases: %s/%s\n' "$schema_numeric_passed" "$schema_numeric_total"
printf 'review findings accounted for: %s/%s\n' "$schema_review_accounted" "$schema_review_total"
printf 'legacy assertions accounted for: %s/%s\n' "$schema_legacy_accounted" "$schema_legacy_total"
printf 'failures: %s\n' "$schema_failures"

[ "$schema_failures" -eq 0 ]
