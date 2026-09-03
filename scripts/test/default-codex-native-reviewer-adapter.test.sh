#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
normalizer="$root/adapters/codex-native-reviewer/v1/normalize.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-codex-reviewer.XXXXXX")
trap '/bin/rm -rf -- "$tmp"' EXIT

sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { /usr/bin/printf 'FAIL: %s\n' "$1" >&2; exit 1; }
passed=0
pass() { passed=$((passed + 1)); /usr/bin/printf 'ok %s - %s\n' "$passed" "$1"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) asset=jq-osx-amd64; digest=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) asset=jq-linux64; digest=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ "$(sha_file "$jq_bin")" = "$digest" ] ||
  fail 'verified jq 1.6 cache is required'
jq_command=("$jq_bin")
if [ "$platform" = Darwin:arm64 ]; then jq_command=(/usr/bin/arch -x86_64 "$jq_bin"); fi
[ "$("${jq_command[@]}" --version)" = jq-1.6 ] || fail 'jq version'
runtime_bin="$tmp/bin"
/bin/mkdir -m 700 "$runtime_bin"
/bin/ln -s "$jq_bin" "$runtime_bin/jq"
generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\\{64\\}\)'$/\\1/p" \
  "$root/scripts/core-contract.sh")
[ -n "$generation" ] &&
  [ "$("${jq_command[@]}" -r --arg generation "$generation" \
      '[.[] | select(.generation_id==$generation)] | length' \
      "$root/core/v2/generation-registry.json")" -eq 1 ] || fail 'selected generation'
modules="$root/core/v2/generations/$generation/modules"

check() {
  local name=$1
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
  pass "$name"
}

mutate() {
  local name=$1 filter=$2
  "${jq_command[@]}" -S -c "$filter" "$tmp/baseline.json" >"$tmp/$name.json"
  "${jq_command[@]}" -e 'type == "object"' "$tmp/$name.json" >/dev/null ||
    fail "$name fixture"
}

expect_state() {
  local name=$1 filter=$2 expected=$3
  mutate "$name" "$filter"
  "${jq_command[@]}" -S -c -f "$normalizer" "$tmp/$name.json" \
    >"$tmp/$name.out" 2>"$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --arg state "$expected" \
    '.state == $state' "$tmp/$name.out" >/dev/null || fail "$name state"
  pass "$name"
}

expect_stale() {
  local name=$1 filter=$2 selector=$3
  mutate "$name" "$filter"
  "${jq_command[@]}" -S -c -f "$normalizer" "$tmp/$name.json" \
    >"$tmp/$name.out" 2>"$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --arg selector "$selector" \
    '.state == "stale" and .stale_bindings == [$selector]' \
    "$tmp/$name.out" >/dev/null || fail "$name state"
  pass "$name"
}

expect_reject() {
  local name=$1 filter=$2
  mutate "$name" "$filter"
  if "${jq_command[@]}" -S -c -f "$normalizer" "$tmp/$name.json" \
      >"$tmp/$name.out" 2>"$tmp/$name.err"; then
    fail "$name accepted"
  fi
  [ ! -s "$tmp/$name.out" ] && [ -s "$tmp/$name.err" ] || fail "$name diagnostics"
  pass "$name"
}

"${jq_command[@]}" -S -c -n '
  def revision($oid):
    {repository_id:"repo.target",hash_algorithm:"sha1",commit_id:$oid};
  def content($id;$sha):
    {content_id:$id,media_type:"application/json",sha256:$sha};
  def unavailable: {state:"unavailable",reason_id:"provider.hidden"};
  {
    trust_context:{
      expected_repository_id:"1270665750",expected_change_request_id:"218",
      expected_review_id:"300",expected_head:revision("1" * 40),
      expected_base:revision("2" * 40),expected_github_app_id:"15368",
      observation_time:"2026-09-02T12:00:00Z",
      instruction_ref:content("instruction";"3" * 64),
      review_policy_ref:content("review-policy";"4" * 64),
      execution_boundary_id:"boundary.codex-review",invocation_kind:"native-review"
    },
    snapshot:{
      repository_id:"1270665750",change_request_id:"218",review_id:"300",
      head:revision("1" * 40),base:revision("2" * 40),github_app_id:"15368",
      observed_at:"2026-09-02T12:00:00Z",status:"COMPLETED",complete:true,
      started_at:"2026-09-02T10:00:00Z",updated_at:"2026-09-02T11:00:00Z",
      terminal_at:"2026-09-02T11:00:00Z",dismissed_at:null,
      reported_top_level_count:0,reported_inline_count:0,
      top_level_findings:[],inline_findings:[],
      hidden_execution:{model:unavailable,effort:unavailable,tools:unavailable,cost:unavailable},
      provider_metadata:{summary:"provider clean text",provider_verdict:"looks-good"}
    }
  }
' >"$tmp/baseline.json"

top='[{finding_id:"T1",body:"top finding",provider_severity:"custom-urgent",
  provider_metadata:{classification:"provider-only"}}]'
inline='[{finding_id:"I1",path:"src/main.sh",line:7,side:"RIGHT",
  commit_id:("1" * 40),body:"inline finding",provider_severity:"banana",
  provider_metadata:{classification:"provider-only"}}]'

check content-ref-public-schema-positive "${jq_command[@]}" -L "$modules" -e '
  import "schema" as schema;
  all([.trust_context.instruction_ref,.trust_context.review_policy_ref][];
      schema::content_ref_ok)
' "$tmp/baseline.json"
expect_state content-ref-boundary '
  .trust_context |=
    (.instruction_ref.content_id=("a" + ("b" * 127)) |
     .instruction_ref.media_type=("a/" + ("b" * 125)) |
     .review_policy_ref.content_id=("c" + ("d" * 127)) |
     .review_policy_ref.media_type=("c/" + ("d" * 125)))
' clean
check content-ref-public-schema-boundary "${jq_command[@]}" -L "$modules" -e '
  import "schema" as schema;
  all([.trust_context.instruction_ref,.trust_context.review_policy_ref][];
      schema::content_ref_ok)
' "$tmp/content-ref-boundary.json"
expect_reject content-ref-colon \
  '.trust_context.instruction_ref.content_id="instruction:bad"'
check content-ref-public-schema-reject-colon "${jq_command[@]}" -L "$modules" -e '
  import "schema" as schema;
  (.trust_context.instruction_ref | schema::content_ref_ok) == false
' "$tmp/content-ref-colon.json"
expect_reject content-ref-slash \
  '.trust_context.review_policy_ref.content_id="review/policy"'
expect_reject content-ref-media-too-long \
  '.trust_context.instruction_ref.media_type=("a/" + ("b" * 126))'
expect_reject content-ref-media-invalid \
  '.trust_context.review_policy_ref.media_type="Application/JSON"'

expect_state clean '.' clean
expect_state top-findings ".snapshot |= (.top_level_findings=$top | .reported_top_level_count=1)" findings
expect_state inline-findings ".snapshot |= (.inline_findings=$inline | .reported_inline_count=1)" findings
expect_state dismissed \
  '.snapshot |= (.status="DISMISSED" | .terminal_at="2026-09-02T10:59:59Z" |
    .dismissed_at="2026-09-02T11:00:00Z")' dismissed
expect_state timeout '.snapshot |= (.status="TIMED_OUT" | .complete=false)' timeout
expect_state failed '.snapshot |= (.status="FAILED" | .complete=false)' failed
expect_state incomplete \
  '.snapshot |= (.complete=false | .reported_top_level_count=1)' inconclusive
expect_state in-progress \
  '.snapshot |= (.status="IN_PROGRESS" | .complete=false | .terminal_at=null)' inconclusive
expect_state unknown \
  '.snapshot |= (.status="UNKNOWN" | .complete=false | .terminal_at=null)' inconclusive

expect_reject completed-terminal-before-start \
  '.snapshot.terminal_at="2026-09-02T09:59:59Z"'
expect_reject failed-terminal-before-start \
  '.snapshot |= (.status="FAILED" | .complete=false |
    .terminal_at="2026-09-02T09:59:59Z")'
expect_reject timeout-terminal-before-start \
  '.snapshot |= (.status="TIMED_OUT" | .complete=false |
    .terminal_at="2026-09-02T09:59:59Z")'
expect_reject dismissed-terminal-before-start \
  '.snapshot |= (.status="DISMISSED" |
    .terminal_at="2026-09-02T09:59:59Z" |
    .dismissed_at="2026-09-02T10:30:00Z")'

expect_state snapshot-metadata-serialized-boundary '
  .snapshot.provider_metadata={
    a:("x" * 4096),b:("x" * 4096),c:("x" * 4096),d:("x" * 4067)
  }
' clean
check snapshot-metadata-exact-byte-boundary "${jq_command[@]}" -e '
  (.snapshot.provider_metadata | tojson | utf8bytelength) == 16384
' "$tmp/snapshot-metadata-serialized-boundary.json"
expect_state snapshot-metadata-depth-boundary \
  '.snapshot.provider_metadata={a:{a:{a:{a:{a:{a:{a:"x"}}}}}}}' clean
expect_state snapshot-metadata-node-boundary '
  .snapshot.provider_metadata={
    a:[range(0;64)],b:[range(0;64)],c:[range(0;64)],d:[range(0;59)]
  }
' clean
expect_state snapshot-metadata-scalar-domain '
  .snapshot.provider_metadata={
    null_value:null,bool_value:true,number_value:1.5,string_value:"opaque"
  }
' clean
expect_state top-metadata-key-boundary \
  ".snapshot |= (.top_level_findings=$top | .reported_top_level_count=1 |
    .top_level_findings[0].provider_metadata=({} | .[(\"k\" * 128)]=\"v\"))" findings
expect_state inline-metadata-container-boundary \
  ".snapshot |= (.inline_findings=$inline | .reported_inline_count=1 |
    .inline_findings[0].provider_metadata={items:[range(0;64)]})" findings

expect_reject snapshot-metadata-string-too-large \
  '.snapshot.provider_metadata={text:("x" * 4097)}'
expect_reject snapshot-metadata-serialized-too-large '
  .snapshot.provider_metadata={
    a:("x" * 4096),b:("x" * 4096),c:("x" * 4096),d:("x" * 4068)
  }
'
expect_reject snapshot-metadata-too-deep \
  '.snapshot.provider_metadata={a:{a:{a:{a:{a:{a:{a:{a:"x"}}}}}}}}'
expect_reject snapshot-metadata-too-many-nodes '
  .snapshot.provider_metadata={
    a:[range(0;64)],b:[range(0;64)],c:[range(0;64)],d:[range(0;60)]
  }
'
expect_reject snapshot-metadata-number-out-of-domain \
  '.snapshot.provider_metadata={value:9007199254740992}'
expect_reject top-metadata-key-too-large \
  ".snapshot |= (.top_level_findings=$top | .reported_top_level_count=1 |
    .top_level_findings[0].provider_metadata=({} | .[(\"k\" * 129)]=\"v\"))"
expect_reject inline-metadata-container-too-large \
  ".snapshot |= (.inline_findings=$inline | .reported_inline_count=1 |
    .inline_findings[0].provider_metadata={items:[range(0;65)]})"

expect_stale stale-app '.snapshot.github_app_id="15369"' app
expect_stale stale-base '.snapshot.base.commit_id=("7" * 40)' base
expect_stale stale-change-request '.snapshot.change_request_id="219"' change-request
expect_stale stale-head '.snapshot.head.commit_id=("8" * 40)' head
expect_stale stale-observation-time \
  '.snapshot.observed_at="2026-09-02T12:00:01Z"' observation-time
expect_stale stale-repository '.snapshot.repository_id="1270665751"' repository
expect_stale stale-review '.snapshot.review_id="301"' review

expect_reject missing-field 'del(.snapshot.inline_findings)'
expect_reject extra-field '.snapshot.write_requested=true'
expect_reject unsupported-status '.snapshot.status="APPROVED"'
expect_reject invalid-date '.snapshot.started_at="2026-02-30T10:00:00Z"'
expect_reject future-update '.snapshot.updated_at="2026-09-02T12:00:01Z"'
expect_reject late-terminal '.snapshot.terminal_at="2026-09-02T11:00:01Z"'
expect_reject malformed-instruction '.trust_context.instruction_ref.sha256=("A" * 64)'
expect_reject exposed-model '.snapshot.hidden_execution.model={state:"present",value:"secret"}'
expect_reject missing-cost 'del(.snapshot.hidden_execution.cost)'
expect_reject complete-count-mismatch '.snapshot.reported_inline_count=1'
expect_reject missing-finding-body \
  ".snapshot |= (.top_level_findings=$top | .reported_top_level_count=1 |
    del(.top_level_findings[0].body))"
expect_reject duplicate-finding-id \
  ".snapshot |= (.top_level_findings=$top | .inline_findings=$inline |
    .inline_findings[0].finding_id=\"T1\" | .reported_top_level_count=1 |
    .reported_inline_count=1)"
expect_reject unsorted-top-findings \
  ".snapshot |= (.top_level_findings=($top + $top) |
    .top_level_findings[0].finding_id=\"T2\" | .reported_top_level_count=2)"
expect_reject unsorted-inline-findings \
  ".snapshot |= (.inline_findings=($inline + $inline) |
    .inline_findings[0].finding_id=\"I2\" | .inline_findings[0].path=\"z.sh\" |
    .inline_findings[1].path=\"a.sh\" | .reported_inline_count=2)"
expect_reject wrong-inline-commit \
  ".snapshot |= (.inline_findings=$inline | .inline_findings[0].commit_id=(\"9\" * 40) |
    .reported_inline_count=1)"
expect_reject invalid-inline-line \
  ".snapshot |= (.inline_findings=$inline | .inline_findings[0].line=0 |
    .reported_inline_count=1)"

"${jq_command[@]}" -S -c -f "$normalizer" "$tmp/baseline.json" >"$tmp/repeat-a.json"
"${jq_command[@]}" -S -c -f "$normalizer" "$tmp/baseline.json" >"$tmp/repeat-b.json"
check canonical-repeat /usr/bin/cmp -s "$tmp/repeat-a.json" "$tmp/repeat-b.json"
check canonical-output /usr/bin/cmp -s "$tmp/repeat-a.json" \
  <("${jq_command[@]}" -S -c . "$tmp/repeat-a.json")
"${jq_command[@]}" -S -c -f "$normalizer" \
  "$tmp/snapshot-metadata-serialized-boundary.json" >"$tmp/metadata-repeat-a.json"
"${jq_command[@]}" -S -c -f "$normalizer" \
  "$tmp/snapshot-metadata-serialized-boundary.json" >"$tmp/metadata-repeat-b.json"
check metadata-boundary-canonical-repeat /usr/bin/cmp -s \
  "$tmp/metadata-repeat-a.json" "$tmp/metadata-repeat-b.json"
check read-only-no-authority-effects "${jq_command[@]}" -e '
  .review_mode == "read-only" and .authority == "none" and .effects == [] and
  .qualification == {state:"unavailable",reason_id:"adapter.unqualified"} and
  ([.. | objects | keys[]] as $keys |
   ($keys | index("authority_ref") == null) and
   ($keys | index("approval") == null) and ($keys | index("merge") == null) and
   ($keys | index("write") == null))
' "$tmp/repeat-a.json"
expect_state severity-is-opaque \
  ".snapshot |= (.top_level_findings=$top | .reported_top_level_count=1)" findings
check provider-severity-is-data "${jq_command[@]}" -e \
  '.observation.top_level_findings[0].provider_severity == "custom-urgent"' \
  "$tmp/severity-is-opaque.out"
check instruction-boundary-provenance "${jq_command[@]}" -e \
  --slurpfile input "$tmp/baseline.json" '
    .trust_context.instruction_ref == $input[0].trust_context.instruction_ref and
    .trust_context.execution_boundary_id == $input[0].trust_context.execution_boundary_id and
    (.observation.hidden_execution | [.model,.effort,.tools,.cost] |
     all(.[]; .state == "unavailable"))
  ' "$tmp/repeat-a.json"
check no-selected-generation-id /usr/bin/env sh -c \
  '! grep -E "g-[0-9a-f]{64}" "$1" "$2"' sh \
  "$normalizer" "$root/scripts/test/default-codex-native-reviewer-adapter.test.sh"
check pure-read-only-jq /usr/bin/env sh -c \
  '! grep -E "core[.]perm|@codex[[:space:]]+fix|approve|merge|credential|token|curl|graphql|github[.]com" "$1"' sh \
  "$normalizer"

/usr/bin/printf 'default Codex native reviewer adapter: %s/%s checks passed\n' "$passed" "$passed"
