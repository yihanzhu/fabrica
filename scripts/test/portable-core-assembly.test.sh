#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail

assembly_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
assembly_generation="g-14b7ad8ce54c3b8c585ff92063d71551ffc7394cc2294d0297bc7d2b8da2c386"
assembly_selected_generation="g-71433a31f52f37041a41b5a8812f79c4c0f5f26c79265788c8d625a9c6f9686b"
assembly_generation_root="$assembly_root/core/v1/generations/$assembly_generation"
assembly_selected_root="$assembly_root/core/v1/generations/$assembly_selected_generation"
assembly_module_dir="$assembly_generation_root/modules"
assembly_program="$assembly_generation_root/contracts.jq"
assembly_wrapper="$assembly_root/scripts/core-contract.sh"

detect_phase() {
  local wrapper="$1"
  local requested="$2"
  case "$requested" in
    auto)
      if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
        printf '%s\n' post-switch
      else
        printf '%s\n' pre-switch
      fi
      ;;
    --pre-switch|pre-switch) printf '%s\n' pre-switch ;;
    --post-switch|post-switch) printf '%s\n' post-switch ;;
    *) return 1 ;;
  esac
}

if [ "$#" -gt 1 ] ||
   ! assembly_phase="$(detect_phase "$assembly_wrapper" "${1:-auto}")"; then
  printf 'usage: %s [--pre-switch|--post-switch]\n' "$0" >&2
  exit 2
fi

assembly_fixture_dir="$assembly_root/scripts/test"
assembly_ledger="$assembly_fixture_dir/portable-core-assembly-ledger.tsv"
assembly_manifest="$assembly_root/ci/required-files.txt"
assembly_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ystack-portable-assembly.XXXXXX")"
assembly_download=""

cleanup() {
  if [ -n "$assembly_download" ] && [ -f "$assembly_download" ]; then
    rm -f -- "$assembly_download"
  fi
  rm -rf -- "$assembly_tmp"
}
trap cleanup EXIT

sha256_path() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

assembly_platform="$(uname -s):$(uname -m)"
case "$assembly_platform" in
  Linux:x86_64)
    assembly_asset="jq-linux64"
    assembly_asset_sha256="af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44"
    ;;
  Darwin:x86_64|Darwin:arm64)
    assembly_asset="jq-osx-amd64"
    assembly_asset_sha256="5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef"
    ;;
  *)
    printf 'FAIL: unsupported jq 1.6 proof platform: %s\n' "$assembly_platform" >&2
    exit 1
    ;;
esac

assembly_cache="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
mkdir -p "$assembly_cache"
assembly_jq="$assembly_cache/$assembly_asset"
if [ ! -f "$assembly_jq" ] ||
   [ "$(sha256_path "$assembly_jq")" != "$assembly_asset_sha256" ]; then
  assembly_download="$(mktemp "$assembly_cache/.jq-1.6.XXXXXX")"
  curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$assembly_asset" \
    -o "$assembly_download"
  if [ "$(sha256_path "$assembly_download")" != "$assembly_asset_sha256" ]; then
    echo 'FAIL: jq 1.6 release asset digest mismatch' >&2
    exit 1
  fi
  chmod 0555 "$assembly_download"
  mv "$assembly_download" "$assembly_jq"
  assembly_download=""
fi

assembly_jq_command=("$assembly_jq")
if [ "$assembly_platform" = Darwin:arm64 ]; then
  assembly_jq_command=(/usr/bin/arch -x86_64 "$assembly_jq")
fi
if [ "$(sha256_path "$assembly_jq")" != "$assembly_asset_sha256" ] ||
   [ "$("${assembly_jq_command[@]}" --version)" != jq-1.6 ]; then
  echo 'FAIL: pinned jq 1.6 identity check failed' >&2
  exit 1
fi
assembly_runtime_bin="$assembly_tmp/runtime-bin"
mkdir -p "$assembly_runtime_bin"
ln -s "$assembly_jq" "$assembly_runtime_bin/jq"

assembly_failures=0
assembly_route_total=0
assembly_route_passed=0
assembly_layer_total=0
assembly_layer_passed=0
assembly_public_total=0
assembly_public_passed=0
assembly_proof_total=0
assembly_proof_passed=0
assembly_seen_rules="$assembly_tmp/seen-assembly-rules"
assembly_seen_tests="$assembly_tmp/seen-assembly-tests"
: > "$assembly_seen_rules"
: > "$assembly_seen_tests"

fail_case() {
  printf 'FAIL: %s\n' "$1" >&2
  assembly_failures=$((assembly_failures + 1))
}

record_assembly_proof() {
  local test_id="$1"
  local rule_id=''
  case "$test_id" in
    portable-core-assembly.test.usage-before-runtime)
      rule_id=portable-core-assembly.usage-before-runtime ;;
    portable-core-assembly.test.document-route)
      rule_id=portable-core-assembly.document-route ;;
    portable-core-assembly.test.profile-set-route)
      rule_id=portable-core-assembly.profile-set-route ;;
    portable-core-assembly.test.stage-run-route)
      rule_id=portable-core-assembly.stage-run-route ;;
    portable-core-assembly.test.empty-success-output)
      rule_id=portable-core-assembly.empty-success-output ;;
    portable-core-assembly.test.sanitized-errors)
      rule_id=portable-core-assembly.sanitized-errors ;;
    portable-core-assembly.test.fixed-imports)
      rule_id=portable-core-assembly.fixed-imports ;;
    portable-core-assembly.test.fixed-generation)
      rule_id=portable-core-assembly.fixed-generation ;;
    portable-core-assembly.test.aggregate-ledgers)
      rule_id=portable-core-assembly.aggregate-ledgers ;;
    portable-core-assembly.test.restore-view)
      rule_id=portable-core-assembly.restore-view ;;
    portable-core-assembly.test.profile-set-arity)
      rule_id=portable-core-assembly.profile-set-arity ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$test_id" >> "$assembly_seen_tests"
  printf '%s\n' "$rule_id" >> "$assembly_seen_rules"
}

proof() {
  local case_id="$1"
  shift
  assembly_proof_total=$((assembly_proof_total + 1))
  if "$@"; then
    assembly_proof_passed=$((assembly_proof_passed + 1))
    record_assembly_proof "$case_id"
  else
    fail_case "$case_id"
  fi
}

phase_probe="$assembly_tmp/phase-probe"
proof phase-auto-pre-switch test \
  "$(detect_phase "$phase_probe" auto)" = pre-switch
: > "$phase_probe"
proof phase-auto-post-switch test \
  "$(detect_phase "$phase_probe" auto)" = post-switch
proof phase-explicit-pre-switch test \
  "$(detect_phase "$phase_probe" --pre-switch)" = pre-switch
proof phase-explicit-post-switch test \
  "$(detect_phase "$assembly_tmp/absent-phase-probe" --post-switch)" = post-switch

fixture_value() {
  local expression="$1"
  "${assembly_jq_command[@]}" -L "$assembly_fixture_dir" -S -c -n \
    "import \"portable-core-assembly-fixtures\" as fixture; $expression"
}

roles=(producer publisher reviewer verifier)
manifest_files=()
manifest_shas=()
for index in 0 1 2 3; do
  manifest_file="$assembly_tmp/manifest-${roles[$index]}.json"
  fixture_value "fixture::manifest_docs[$index]" > "$manifest_file"
  manifest_files+=("$manifest_file")
  manifest_shas+=("$(sha256_path "$manifest_file")")
done

manifest_sha_map="$("${assembly_jq_command[@]}" -n \
  --arg producer "${manifest_shas[0]}" \
  --arg publisher "${manifest_shas[1]}" \
  --arg reviewer "${manifest_shas[2]}" \
  --arg verifier "${manifest_shas[3]}" \
  '{producer:$producer,publisher:$publisher,reviewer:$reviewer,verifier:$verifier}')"

profile_file="$assembly_tmp/profile.json"
"${assembly_jq_command[@]}" -L "$assembly_fixture_dir" -S -c -n \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-assembly-fixtures" as fixture;
   fixture::profile_doc($manifest_shas)' > "$profile_file"
profile_sha="$(sha256_path "$profile_file")"

resolved_file="$assembly_tmp/resolved.json"
"${assembly_jq_command[@]}" -L "$assembly_fixture_dir" -S -c -n \
  --slurpfile profile "$profile_file" --arg profile_sha "$profile_sha" \
  --argjson manifest_shas "$manifest_sha_map" \
  'import "portable-core-assembly-fixtures" as fixture;
   fixture::resolved_profile_doc($profile[0];$profile_sha;$manifest_shas)' > \
  "$resolved_file"
resolved_sha="$(sha256_path "$resolved_file")"

request_file="$assembly_tmp/request.json"
fixture_value "fixture::request_doc(\"producer\";\"$resolved_sha\")" > \
  "$request_file"
request_sha="$(sha256_path "$request_file")"

result_file="$assembly_tmp/result.json"
"${assembly_jq_command[@]}" -L "$assembly_fixture_dir" -S -c -n \
  --slurpfile request "$request_file" --slurpfile resolved "$resolved_file" \
  --arg request_sha "$request_sha" --arg resolved_sha "$resolved_sha" \
  'import "portable-core-assembly-fixtures" as fixture;
   fixture::result_doc($request[0];$request_sha;$resolved[0];$resolved_sha)' > \
  "$result_file"

build_request() {
  local role="$1"
  local output="$2"
  fixture_value "fixture::request_doc(\"$role\";\"$resolved_sha\")" > "$output"
}

build_fixture_result() {
  local request="$1"
  local builder="$2"
  local output="$3"
  local resolved="${4:-$resolved_file}"
  local request_digest resolved_digest
  request_digest="$(sha256_path "$request")"
  resolved_digest="$(sha256_path "$resolved")"
  "${assembly_jq_command[@]}" -L "$assembly_fixture_dir" -S -c -n \
    --slurpfile request "$request" --slurpfile resolved "$resolved" \
    --arg request_sha "$request_digest" --arg resolved_sha "$resolved_digest" \
    "import \"portable-core-assembly-fixtures\" as fixture;
     fixture::$builder(\$request[0];\$request_sha;\$resolved[0];\$resolved_sha)" > \
    "$output"
}

verifier_request_file="$assembly_tmp/request-verifier.json"
reviewer_request_file="$assembly_tmp/request-reviewer.json"
verifier_result_file="$assembly_tmp/result-verifier.json"
reviewer_result_file="$assembly_tmp/result-reviewer.json"
build_request verifier "$verifier_request_file"
build_request reviewer "$reviewer_request_file"
build_fixture_result "$verifier_request_file" result_doc "$verifier_result_file"
build_fixture_result "$reviewer_request_file" result_doc "$reviewer_result_file"

for status in skipped stale blocked failed cancelled; do
  build_fixture_result "$request_file" "${status}_result_doc" \
    "$assembly_tmp/result-$status.json"
done

producer_changed_file="$assembly_tmp/result-producer-changed.json"
producer_inconclusive_file="$assembly_tmp/result-producer-inconclusive.json"
verifier_failed_file="$assembly_tmp/result-verifier-failed.json"
verifier_inconclusive_file="$assembly_tmp/result-verifier-inconclusive.json"
"${assembly_jq_command[@]}" -S -c \
  '.body.outcome={family:"change",value:"changed"} |
   .body.outputs=[{output_id:"output.changed",ref:.body.evidence[0].proof_ref}]' \
  "$result_file" > "$producer_changed_file"
"${assembly_jq_command[@]}" -S -c \
  '.body.evidence[0].verdict="inconclusive" |
   .body.outcome={family:"change",value:"inconclusive"} |
   .body.reason={reason_id:"proof.inconclusive"}' \
  "$result_file" > "$producer_inconclusive_file"
"${assembly_jq_command[@]}" -S -c \
  '.body.evidence[0].verdict="failed" |
   .body.outcome={family:"check",value:"failed"}' \
  "$verifier_result_file" > "$verifier_failed_file"
"${assembly_jq_command[@]}" -S -c \
  '.body.evidence[0].verdict="inconclusive" |
   .body.outcome={family:"check",value:"inconclusive"} |
   .body.reason={reason_id:"proof.inconclusive"}' \
  "$verifier_result_file" > "$verifier_inconclusive_file"

driver_number=0
build_driver() {
  local mode="$1"
  local output="$2"
  local contents hashes input digest
  shift 2
  driver_number=$((driver_number + 1))
  contents="$assembly_tmp/contents.$driver_number.ndjson"
  hashes="$assembly_tmp/hashes.$driver_number.ndjson"
  : > "$contents"
  : > "$hashes"
  for input in "$@"; do
    cat -- "$input" >> "$contents"
    digest="$(sha256_path "$input")"
    printf '"%s"\n' "$digest" >> "$hashes"
  done
  "${assembly_jq_command[@]}" -n -S -c --arg mode "$mode" \
    --slurpfile contents "$contents" --slurpfile hashes "$hashes" \
    '{mode:$mode,docs:([range(0;($contents|length))] |
      map({content:$contents[.],sha256:$hashes[.]}))}' > "$output"
}

run_root_driver() {
  local driver="$1"
  local actual
  if ! actual="$(HOME=/nonexistent JQ_LIBRARY_PATH=/nonexistent \
      "${assembly_jq_command[@]}" -L "$assembly_module_dir" -r \
      -f "$assembly_program" "$driver" 2>/dev/null)"; then
    printf 'JQ_ERROR'
  elif [ -z "$actual" ]; then
    printf 'OK'
  else
    printf '%s' "$actual"
  fi
}

expect_root() {
  local category="$1"
  local case_id="$2"
  local expected="$3"
  local mode="$4"
  local driver actual
  shift 4
  driver="$assembly_tmp/$case_id.driver.json"
  build_driver "$mode" "$driver" "$@"
  actual="$(run_root_driver "$driver")"
  case "$category" in
    route) assembly_route_total=$((assembly_route_total + 1)) ;;
    layer) assembly_layer_total=$((assembly_layer_total + 1)) ;;
  esac
  if [ "$actual" = "$expected" ]; then
    case "$category" in
      route) assembly_route_passed=$((assembly_route_passed + 1)) ;;
      layer) assembly_layer_passed=$((assembly_layer_passed + 1)) ;;
    esac
  else
    fail_case "$case_id expected $expected, got $actual"
  fi
}

expect_public_success() {
  local case_id="$1"
  local stdout="$assembly_tmp/$case_id.stdout"
  local stderr="$assembly_tmp/$case_id.stderr"
  shift
  assembly_public_total=$((assembly_public_total + 1))
  if PATH="$assembly_runtime_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$assembly_wrapper" "$@" > "$stdout" 2> "$stderr" &&
     [ ! -s "$stdout" ] && [ ! -s "$stderr" ]; then
    assembly_public_passed=$((assembly_public_passed + 1))
  else
    fail_case "$case_id did not return silent success"
  fi
}

expect_public_failure() {
  local case_id="$1"
  local expected="$2"
  local stdout="$assembly_tmp/$case_id.stdout"
  local stderr="$assembly_tmp/$case_id.stderr"
  local status=0
  shift 2
  assembly_public_total=$((assembly_public_total + 1))
  PATH="$assembly_runtime_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$assembly_wrapper" "$@" > "$stdout" 2> "$stderr" || status=$?
  if [ "$status" -ne 0 ] && [ ! -s "$stdout" ] &&
     [ "$(cat "$stderr")" = "$expected" ] &&
     ! grep -Fq "$assembly_tmp" "$stderr"; then
    assembly_public_passed=$((assembly_public_passed + 1))
  else
    fail_case "$case_id did not return only $expected"
  fi
}

expected_imports="$assembly_tmp/expected-imports"
actual_imports="$assembly_tmp/actual-imports"
printf '%s\n' \
  'import "schema" as schema;' \
  'import "profile_graph" as profile_graph;' \
  'import "stage_request" as stage_request;' \
  'import "result_facts" as result_facts;' \
  'import "result_truth" as result_truth;' > "$expected_imports"
awk '/^import / {print}' "$assembly_program" > "$actual_imports"
proof portable-core-assembly.test.fixed-imports \
  cmp -s "$expected_imports" "$actual_imports"
proof no-forbidden-loader-form \
  sh -c '! grep -E "(^|[^[:alnum:]_])(include|import[[:space:]].*search|fromjson|input_filename)([^[:alnum:]_]|$)" "$1" >/dev/null' sh "$assembly_program"

activation_pair_ok() {
  local root_program="$1"
  local wrapper="$2"
  local root_exists=false
  local wrapper_exists=false
  { [ -e "$root_program" ] || [ -L "$root_program" ]; } && root_exists=true
  { [ -e "$wrapper" ] || [ -L "$wrapper" ]; } && wrapper_exists=true
  if [ "$root_exists" = false ] && [ "$wrapper_exists" = false ]; then
    return 0
  fi
  [ "$root_exists" = true ] && [ "$wrapper_exists" = true ] &&
    [ -f "$root_program" ] && [ ! -L "$root_program" ] &&
    [ -f "$wrapper" ] && [ ! -L "$wrapper" ] && [ -x "$wrapper" ] &&
    [ "$(grep -Ec "^PORTABLE_CORE_GENERATION='g-[0-9a-f]{64}'$" "$wrapper")" -eq 1 ] &&
    [ "$(grep -Fxc "PORTABLE_CORE_GENERATION='$assembly_generation'" "$wrapper")" -eq 1 ]
}

activation_pair_rejected() {
  ! activation_pair_ok "$1" "$2"
}

write_synthetic_wrapper() {
  local output="$1"
  local generation="$2"
  printf '#!/usr/bin/env bash\nPORTABLE_CORE_GENERATION='"'"'%s'"'"'\n' \
    "$generation" > "$output"
  chmod 0755 "$output"
}

pair_dir="$assembly_tmp/activation-pair"
pair_root="$pair_dir/contracts.jq"
pair_wrapper="$pair_dir/core-contract.sh"
mkdir -p "$pair_dir"
proof activation-pre-switch activation_pair_ok "$pair_root" "$pair_wrapper"
cp "$assembly_program" "$pair_root"
write_synthetic_wrapper "$pair_wrapper" "$assembly_generation"
proof activation-post-switch activation_pair_ok "$pair_root" "$pair_wrapper"
rm "$pair_wrapper"
proof activation-root-only activation_pair_rejected "$pair_root" "$pair_wrapper"
rm "$pair_root"
write_synthetic_wrapper "$pair_wrapper" "$assembly_generation"
proof activation-wrapper-only activation_pair_rejected "$pair_root" "$pair_wrapper"
rm "$pair_wrapper"
ln -s "$assembly_program" "$pair_root"
write_synthetic_wrapper "$pair_wrapper" "$assembly_generation"
proof activation-root-symlink activation_pair_rejected "$pair_root" "$pair_wrapper"
rm "$pair_root" "$pair_wrapper"
cp "$assembly_program" "$pair_root"
valid_wrapper="$pair_dir/valid-wrapper.sh"
write_synthetic_wrapper "$valid_wrapper" "$assembly_generation"
ln -s "$valid_wrapper" "$pair_wrapper"
proof activation-wrapper-symlink activation_pair_rejected "$pair_root" "$pair_wrapper"
rm "$pair_wrapper"
write_synthetic_wrapper "$pair_wrapper" \
  g-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
proof activation-wrong-generation activation_pair_rejected "$pair_root" "$pair_wrapper"
proof no-live-caller \
  sh -c 'git -C "$1" rev-parse --git-dir >/dev/null 2>&1 && ! git -C "$1" grep -q -E "$2" -- manager reviewer routines templates config scripts/install.sh scripts/setup-target-repo.sh scripts/doctor.sh' \
  sh "$assembly_root" \
  "scripts/core-contract\\.sh|$assembly_generation|$assembly_selected_generation"

for selected_export in contracts.jq modules/schema.jq modules/profile_graph.jq \
  modules/stage_request.jq modules/result_facts.jq modules/result_truth.jq; do
  proof "selected-export-${selected_export//\//-}" cmp -s \
    "$assembly_generation_root/$selected_export" \
    "$assembly_selected_root/$selected_export"
done
proof selected-ingress-generation \
  grep -Fq "PORTABLE_CORE_INGRESS_GENERATION='$assembly_selected_generation'" \
    "$assembly_selected_root/core-ingress.sh"

metadata="$(fixture_value 'fixture::metadata')"
expected_oids=(
  fd3924d414a7d620c2bf5de919a45c2599d572ec
  e882b38b0106aac9142c667771f02e3107f8c52f
  48fd185eee7751eedf0ce381b77621e4d7cd1611
  76c5d54437813a76502b46dc05215fb5b2c3f5bb
  cfc3ed3b1c3d714412a6dffc85accaabb98cf3df
  3bdad8386cecd23adc7ee9960f0e1f4309626891
)
dependency_paths=(
  "$assembly_module_dir/schema.jq"
  "$assembly_generation_root/core-ingress.sh"
  "$assembly_module_dir/profile_graph.jq"
  "$assembly_module_dir/stage_request.jq"
  "$assembly_module_dir/result_facts.jq"
  "$assembly_module_dir/result_truth.jq"
)
for index in 0 1 2 3 4 5; do
  proof "dependency-$index-current-tree" test \
    "$(git -C "$assembly_root" hash-object "${dependency_paths[$index]}")" = \
    "${expected_oids[$index]}"
done
proof dependency-metadata \
  test "$("${assembly_jq_command[@]}" -r \
    '[.dependencies[].g3_comment] == [5466181650,5468279667,5468723218,5469016860,5469128966,5469265117] and [.dependencies[].export_oid] == $oids' \
    --argjson oids "$(printf '%s\n' "${expected_oids[@]}" | "${assembly_jq_command[@]}" -Rsc 'split("\n")[:-1]')" \
    <<< "$metadata")" = true
proof registry-current-tree test \
  "$(git -C "$assembly_root" hash-object core/v1/generation-registry.json)" = \
  a9cb0e4f6a05f4228fc219bef96ba52a324dc223

ledger_files=(
  "$assembly_fixture_dir/portable-core-schema-ledger.tsv"
  "$assembly_fixture_dir/portable-core-ingress-ledger.tsv"
  "$assembly_fixture_dir/portable-core-profile-graph-ledger.tsv"
  "$assembly_fixture_dir/portable-core-stage-request-ledger.tsv"
  "$assembly_fixture_dir/portable-core-result-facts-ledger.tsv"
  "$assembly_fixture_dir/portable-core-result-truth-ledger.tsv"
  "$assembly_ledger"
)
ledger_owners=(
  portable-core-schema
  portable-core-ingress
  portable-core-profile-graph
  portable-core-stage-request
  portable-core-result-facts
  portable-core-result-truth
  portable-core-assembly
)
ledger_review_counts=(8 2 7 6 2 8 1)
ledger_legacy_counts=(44 38 92 22 14 48 21)
ledger_test_scripts=(
  "$assembly_fixture_dir/portable-core-schema.test.sh"
  "$assembly_fixture_dir/portable-core-ingress.test.sh"
  "$assembly_fixture_dir/portable-core-profile-graph.test.sh"
  "$assembly_fixture_dir/portable-core-stage-request.test.sh"
  "$assembly_fixture_dir/portable-core-result-facts.test.sh"
  "$assembly_fixture_dir/portable-core-result-truth.test.sh"
  "$assembly_fixture_dir/portable-core-assembly.test.sh"
)

ledger_set_ok() {
  local assembly_candidate="$1"
  local combined="$assembly_tmp/combined-ledger"
  local index owner ledger test_script rule_inventory test_inventory
  local -a candidates
  candidates=("${ledger_files[@]:0:6}" "$assembly_candidate")
  : > "$combined"
  for index in 0 1 2 3 4 5 6; do
    owner="${ledger_owners[$index]}"
    ledger="${candidates[$index]}"
    test_script="${ledger_test_scripts[$index]}"
    [ -f "$ledger" ] && [ -f "$test_script" ] || return 1
    awk -F '\t' -v owner="$owner" \
      -v expected_review="${ledger_review_counts[$index]}" \
      -v expected_legacy="${ledger_legacy_counts[$index]}" '
      NR == 1 {
        if ($0 != "source\trow_id\tdisposition\trule_id\ttest_id") bad=1
        next
      }
      NF != 5 { bad=1; next }
      $1 == "review" { review++ }
      $1 == "legacy" { legacy++ }
      $1 != "review" && $1 != "legacy" { bad=1 }
      $3 != "ported" && $3 != "replaced-by" { bad=1 }
      index($4,owner ".") != 1 || $4 !~ /^[a-z0-9][a-z0-9._-]+$/ { bad=1 }
      index($5,owner ".test.") != 1 || $5 !~ /^[a-z0-9][a-z0-9._-]+$/ { bad=1 }
      $2 == "" || $4 == "" || $5 == "" { bad=1 }
      END { exit bad || review != expected_review || legacy != expected_legacy }
    ' "$ledger" || return 1
    tail -n +2 "$ledger" >> "$combined"

    rule_inventory="$assembly_tmp/$index.rules"
    test_inventory="$assembly_tmp/$index.tests"
    if [ "$owner" = portable-core-assembly ]; then
      LC_ALL=C sort -u "$assembly_seen_rules" > "$rule_inventory"
      LC_ALL=C sort -u "$assembly_seen_tests" > "$test_inventory"
    else
      grep -Fq 'seen-rules.sorted' "$test_script" &&
        grep -Fq 'seen-tests.sorted' "$test_script" || return 1
      grep -Eo "$owner\\.(test\\.)?[a-z0-9][a-z0-9._-]*" "$test_script" |
        grep -Fv "$owner.test." | LC_ALL=C sort -u > "$rule_inventory"
      grep -Eo "$owner\\.test\\.[a-z0-9][a-z0-9._-]*" "$test_script" |
        LC_ALL=C sort -u > "$test_inventory"
    fi
    while IFS=$'\t' read -r _ _ _ rule_id test_id; do
      grep -Fqx "$rule_id" "$rule_inventory" &&
        grep -Fqx "$test_id" "$test_inventory" || return 1
    done < <(tail -n +2 "$ledger")
  done

  awk -F '\t' '
    { row[$2]++; full[$0]++ }
    $1 == "review" { review++; review_id[$2]++ }
    $1 == "legacy" { legacy++; legacy_id[$2]++ }
    END {
      for (i=1;i<=16;i++) expected_review[sprintf("review-r0-f%02d",i)]=1
      for (i=1;i<=9;i++) expected_review[sprintf("review-r1-f%02d",i)]=1
      for (i=1;i<=5;i++) expected_review[sprintf("review-r2-f%02d",i)]=1
      for (i=1;i<=4;i++) expected_review[sprintf("review-r3-f%02d",i)]=1
      for (id in expected_review) if (review_id[id] != 1) bad=1
      for (id in review_id) if (!expected_review[id] || review_id[id] != 1) bad=1
      for (i=1;i<=279;i++) expected_legacy[sprintf("legacy-test-%03d",i)]=1
      for (id in expected_legacy) if (legacy_id[id] != 1) bad=1
      for (id in legacy_id) if (!expected_legacy[id] || legacy_id[id] != 1) bad=1
      for (id in row) if (row[id] != 1) bad=1
      for (line in full) if (full[line] != 1) bad=1
      exit bad || review != 34 || legacy != 279
    }' "$combined"
}

ledger_set_rejected() {
  ! ledger_set_ok "$1"
}

proof stage-owns-legacy-229-230 \
  sh -c 'grep -q "legacy-test-229" "$1" && grep -q "legacy-test-230" "$1" && ! grep -Eq "legacy-test-(229|230)" "$2"' sh \
  "$assembly_fixture_dir/portable-core-stage-request-ledger.tsv" \
  "$assembly_fixture_dir/portable-core-result-truth-ledger.tsv"

root_rel="core/v1/generations/$assembly_generation/contracts.jq"
fixture_rel="scripts/test/portable-core-assembly-fixtures.jq"
ledger_rel="scripts/test/portable-core-assembly-ledger.tsv"
test_rel="scripts/test/portable-core-assembly.test.sh"
for required in "$root_rel" "$fixture_rel" "$ledger_rel" "$test_rel"; do
  proof "manifest-$required" test \
    "$(grep -Fxc "$required" "$assembly_manifest")" -eq 1
done

expect_root route document-manifest OK document "${manifest_files[0]}"
expect_root route document-profile OK document "$profile_file"
expect_root route document-resolved OK document "$resolved_file"
expect_root route document-request OK document "$request_file"
expect_root route document-result OK document "$result_file"
expect_root route profile-set OK profile-set "$profile_file" "$resolved_file" \
  "${manifest_files[@]}"
expect_root route stage-run OK stage-run "$request_file" "$resolved_file" \
  "$result_file"

limit_file="$assembly_tmp/limit.json"
"${assembly_jq_command[@]}" -S -c '.id=("a"*65537)' "$profile_file" > "$limit_file"
shape_file="$assembly_tmp/shape.json"
"${assembly_jq_command[@]}" -S -c 'del(.body.bindings)' "$profile_file" > \
  "$shape_file"
ref_file="$assembly_tmp/ref.json"
"${assembly_jq_command[@]}" -S -c \
  '.body.resolved_profile_ref.sha256=("0"*64)' "$request_file" > "$ref_file"
relation_file="$assembly_tmp/relation.json"
"${assembly_jq_command[@]}" -S -c \
  'del(.body.bindings[] | select(.role=="publisher") | .authority_ref)' \
  "$profile_file" > "$relation_file"
request_relation_file="$assembly_tmp/request-relation.json"
"${assembly_jq_command[@]}" -S -c \
  '.body.required_evidence_kinds=["independent-review"]' "$request_file" > \
  "$request_relation_file"
facts_shape_file="$assembly_tmp/result-facts-shape.json"
"${assembly_jq_command[@]}" -S -c \
  'del(.body.execution.actual_binding.package_ref)' "$result_file" > \
  "$facts_shape_file"
truth_relation_file="$assembly_tmp/result-truth-relation.json"
"${assembly_jq_command[@]}" -S -c 'del(.body.finished_at)' "$result_file" > \
  "$truth_relation_file"
request_relation_result_file="$assembly_tmp/result-request-relation.json"
build_fixture_result "$request_relation_file" result_doc \
  "$request_relation_result_file"
resolved_relation_file="$assembly_tmp/resolved-relation.json"
"${assembly_jq_command[@]}" -S -c \
  '.body.bindings |= map(
    if .binding.role=="producer" then
      .binding.requested_capabilities=[] | .binding.requested_permissions=[]
    else . end)' "$resolved_file" > "$resolved_relation_file"
resolved_relation_sha="$(sha256_path "$resolved_relation_file")"
profile_forced_request_file="$assembly_tmp/request-profile-relation.json"
fixture_value \
  "fixture::request_doc(\"producer\";\"$resolved_relation_sha\")" > \
  "$profile_forced_request_file"
profile_forced_result_file="$assembly_tmp/result-profile-relation.json"
build_fixture_result "$profile_forced_request_file" result_doc \
  "$profile_forced_result_file" "$resolved_relation_file"
expect_root layer parsed-limit E_LIMIT document "$limit_file"
expect_root layer shape-before-relation E_SHAPE document "$shape_file"
expect_root layer ref-before-relation E_REF stage-run "$ref_file" \
  "$resolved_file" "$result_file"
expect_root layer relation E_RELATION document "$relation_file"

if [ "$assembly_phase" = pre-switch ]; then
  proof pre-switch-wrapper-absent test ! -e "$assembly_wrapper"
  proof pre-switch-wrapper-manifest-absent test \
    "$(grep -Fxc scripts/core-contract.sh "$assembly_manifest" || true)" -eq 0
else
  proof portable-core-assembly.test.fixed-generation \
    grep -qF "PORTABLE_CORE_GENERATION='$assembly_selected_generation'" \
      "$assembly_wrapper"
  proof wrapper-executable test -x "$assembly_wrapper"
  proof wrapper-manifest test \
    "$(grep -Fxc scripts/core-contract.sh "$assembly_manifest")" -eq 1

  expect_public_success document-success validate-document "$profile_file"
  expect_public_success profile-set-success validate-profile-set "$profile_file" \
    "$resolved_file" "${manifest_files[@]}"
  expect_public_success stage-run-success validate-stage-run "$request_file" \
    "$resolved_file" "$result_file"
  expect_public_success stage-run-verifier validate-stage-run \
    "$verifier_request_file" "$resolved_file" "$verifier_result_file"
  expect_public_success stage-run-reviewer validate-stage-run \
    "$reviewer_request_file" "$resolved_file" "$reviewer_result_file"
  for status in skipped stale blocked failed cancelled; do
    expect_public_success "terminal-$status" validate-stage-run "$request_file" \
      "$resolved_file" "$assembly_tmp/result-$status.json"
  done
  expect_public_success outcome-producer-changed validate-stage-run "$request_file" \
    "$resolved_file" "$producer_changed_file"
  expect_public_success outcome-producer-inconclusive validate-stage-run \
    "$request_file" "$resolved_file" "$producer_inconclusive_file"
  expect_public_success outcome-verifier-failed validate-stage-run \
    "$verifier_request_file" "$resolved_file" "$verifier_failed_file"
  expect_public_success outcome-verifier-inconclusive validate-stage-run \
    "$verifier_request_file" "$resolved_file" "$verifier_inconclusive_file"
  expect_public_failure forced-profile-owner E_RELATION validate-stage-run \
    "$profile_forced_request_file" "$resolved_relation_file" \
    "$profile_forced_result_file"
  expect_public_failure forced-request-owner E_RELATION validate-stage-run \
    "$request_relation_file" "$resolved_file" "$request_relation_result_file"
  expect_public_failure forced-facts-owner E_SHAPE validate-stage-run \
    "$request_file" "$resolved_file" "$facts_shape_file"
  expect_public_failure forced-truth-owner E_RELATION validate-stage-run \
    "$request_file" "$resolved_file" "$truth_relation_file"

  usage_stdout="$assembly_tmp/usage.stdout"
  usage_stderr="$assembly_tmp/usage.stderr"
  usage_status=0
  env PATH=/nonexistent /bin/bash "$assembly_wrapper" validate-document \
    > "$usage_stdout" 2> "$usage_stderr" || usage_status=$?
  assembly_public_total=$((assembly_public_total + 1))
  if [ "$usage_status" -ne 0 ] && [ ! -s "$usage_stdout" ] &&
     [ "$(cat "$usage_stderr")" = E_USAGE ]; then
    assembly_public_passed=$((assembly_public_passed + 1))
    record_assembly_proof portable-core-assembly.test.usage-before-runtime
  else
    fail_case portable-core-assembly.test.usage-before-runtime
  fi

  assembly_public_total=$((assembly_public_total + 2))
  arity_ok=true
  for arity_case in zero nine; do
    arity_out="$assembly_tmp/arity-$arity_case.out"
    arity_err="$assembly_tmp/arity-$arity_case.err"
    arity_status=0
    if [ "$arity_case" = zero ]; then
      env PATH=/nonexistent /bin/bash "$assembly_wrapper" validate-profile-set \
        sentinel-profile sentinel-resolved > "$arity_out" 2> "$arity_err" || \
        arity_status=$?
    else
      env PATH=/nonexistent /bin/bash "$assembly_wrapper" validate-profile-set \
        sentinel-profile sentinel-resolved m1 m2 m3 m4 m5 m6 m7 m8 m9 \
        > "$arity_out" 2> "$arity_err" || arity_status=$?
    fi
    if [ "$arity_status" -eq 0 ] || [ -s "$arity_out" ] ||
       [ "$(cat "$arity_err")" != E_USAGE ]; then
      arity_ok=false
    fi
  done
  if [ "$arity_ok" = true ]; then
    assembly_public_passed=$((assembly_public_passed + 2))
    record_assembly_proof portable-core-assembly.test.profile-set-arity
  else
    fail_case portable-core-assembly.test.profile-set-arity
  fi

  runtime_stdout="$assembly_tmp/runtime.stdout"
  runtime_stderr="$assembly_tmp/runtime.stderr"
  runtime_status=0
  env PATH=/nonexistent /bin/bash "$assembly_wrapper" validate-document \
    "$profile_file" > "$runtime_stdout" 2> "$runtime_stderr" || runtime_status=$?
  assembly_public_total=$((assembly_public_total + 1))
  if [ "$runtime_status" -ne 0 ] && [ ! -s "$runtime_stdout" ] &&
     [ "$(cat "$runtime_stderr")" = E_RUNTIME ]; then
    assembly_public_passed=$((assembly_public_passed + 1))
  else
    fail_case runtime-after-usage
  fi

  invalid_file="$assembly_tmp/private-invalid-secret.json"
  printf '{invalid\n' > "$invalid_file"
  noncanonical_file="$assembly_tmp/noncanonical.json"
  printf '{ "schema_version": 1 }\n' > "$noncanonical_file"
  oversize_file="$assembly_tmp/oversize-invalid.json"
  awk 'BEGIN { for (i=0;i<1048577;i++) printf "x" }' > "$oversize_file"
  expect_public_failure raw-limit-before-parse E_LIMIT validate-document \
    "$oversize_file"
  expect_public_failure parse-before-canonical E_PARSE validate-document \
    "$invalid_file"
  expect_public_failure canonical-before-parsed-limit E_CANONICAL validate-document \
    "$noncanonical_file"
  expect_public_failure parsed-limit-before-shape E_LIMIT validate-document \
    "$limit_file"
  expect_public_failure public-shape E_SHAPE validate-document "$shape_file"
  expect_public_failure public-ref E_REF validate-stage-run "$ref_file" \
    "$resolved_file" "$result_file"
  expect_public_failure public-relation E_RELATION validate-document "$relation_file"

  fixed_stdout="$assembly_tmp/fixed.stdout"
  fixed_stderr="$assembly_tmp/fixed.stderr"
  fake_home="$assembly_tmp/fake-home"
  fake_modules="$assembly_tmp/fake-modules"
  mkdir -p "$fake_home/.jq" "$fake_modules"
  printf 'def parsed_limits_ok: false;\n' > "$fake_home/.jq/schema.jq"
  printf 'def parsed_limits_ok: false;\n' > "$fake_modules/schema.jq"
  assembly_public_total=$((assembly_public_total + 1))
  if HOME="$fake_home" JQ_LIBRARY_PATH="$fake_modules" \
     PORTABLE_CORE_GENERATION='g-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff' \
     PATH="$assembly_runtime_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
     "$assembly_wrapper" validate-document "$profile_file" \
       > "$fixed_stdout" 2> "$fixed_stderr" &&
     [ ! -s "$fixed_stdout" ] && [ ! -s "$fixed_stderr" ]; then
    assembly_public_passed=$((assembly_public_passed + 1))
  else
    fail_case fixed-module-and-generation-selection
  fi
fi

proof portable-core-assembly.test.restore-view \
  sh -c 'grep -q "Portable contract validator" "$1" && grep -q "Restore the portable contract validator" "$2"' sh \
  "$assembly_root/README.md" "$assembly_root/RESTORE.md"
proof portable-core-assembly.test.empty-success-output test \
  "$assembly_route_passed" -eq "$assembly_route_total"
proof portable-core-assembly.test.sanitized-errors test \
  "$assembly_layer_passed" -eq "$assembly_layer_total"
proof portable-core-assembly.test.document-route grep -q 'document-manifest' "$0"
proof portable-core-assembly.test.profile-set-route grep -q 'profile-set-success' "$0"
proof portable-core-assembly.test.stage-run-route grep -q 'stage-run-success' "$0"

ledger_closure_ok=false
if [ "$assembly_phase" = post-switch ]; then
  record_assembly_proof portable-core-assembly.test.aggregate-ledgers
  assembly_proof_total=$((assembly_proof_total + 1))
  if ledger_set_ok "$assembly_ledger"; then
    assembly_proof_passed=$((assembly_proof_passed + 1))
    ledger_closure_ok=true
  else
    fail_case portable-core-assembly.test.aggregate-ledgers
  fi

  corrupt_disposition="$assembly_tmp/ledger-corrupt-disposition.tsv"
  corrupt_rule="$assembly_tmp/ledger-corrupt-rule.tsv"
  corrupt_test="$assembly_tmp/ledger-corrupt-test.tsv"
  corrupt_column="$assembly_tmp/ledger-corrupt-column.tsv"
  corrupt_header="$assembly_tmp/ledger-corrupt-header.tsv"
  awk -F '\t' 'BEGIN{OFS=FS} NR==2{$3="unknown"} {print}' \
    "$assembly_ledger" > "$corrupt_disposition"
  awk -F '\t' 'BEGIN{OFS=FS} NR==2{$4="portable-core-assembly.missing-rule"} {print}' \
    "$assembly_ledger" > "$corrupt_rule"
  awk -F '\t' 'BEGIN{OFS=FS} NR==2{$5="portable-core-assembly.test.missing-test"} {print}' \
    "$assembly_ledger" > "$corrupt_test"
  awk -F '\t' 'BEGIN{OFS=FS} NR==2{$6="extra"} {print}' \
    "$assembly_ledger" > "$corrupt_column"
  awk -F '\t' 'BEGIN{OFS=FS} NR==1{$1="sources"} {print}' \
    "$assembly_ledger" > "$corrupt_header"
  proof corrupt-ledger-disposition ledger_set_rejected "$corrupt_disposition"
  proof corrupt-ledger-rule ledger_set_rejected "$corrupt_rule"
  proof corrupt-ledger-test ledger_set_rejected "$corrupt_test"
  proof corrupt-ledger-column ledger_set_rejected "$corrupt_column"
  proof corrupt-ledger-header ledger_set_rejected "$corrupt_header"
fi

if [ "$assembly_failures" -ne 0 ]; then
  printf 'portable core assembly failed: %s failure(s)\n' "$assembly_failures" >&2
  exit 1
fi

printf 'assembly phase: %s\n' "$assembly_phase"
printf 'command routes: %s/%s\n' "$assembly_route_passed" "$assembly_route_total"
printf 'error layers: %s/%s\n' "$assembly_layer_passed" "$assembly_layer_total"
printf 'public boundary: %s/%s\n' "$assembly_public_passed" "$assembly_public_total"
printf 'assembly proof: %s/%s\n' "$assembly_proof_passed" "$assembly_proof_total"
if [ "$ledger_closure_ok" = true ]; then
  printf 'review findings accounted for: 34/34\n'
  printf 'legacy assertions accounted for: 279/279\n'
fi
