#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
normalizer="$root/adapters/github-forge/v1/normalize.jq"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-github-forge.XXXXXX")
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

check() {
  local name=$1
  shift
  "$@" >/dev/null 2>&1 || fail "$name"
  pass "$name"
}

mutate() {
  local name=$1
  local filter=$2
  "${jq_command[@]}" -S -c "$filter" "$tmp/baseline.json" >"$tmp/$name.json"
}

expect_state() {
  local name=$1
  local filter=$2
  local expected=$3
  mutate "$name" "$filter"
  "${jq_command[@]}" -S -c -f "$normalizer" "$tmp/$name.json" \
    >"$tmp/$name.out" 2>"$tmp/$name.err" || fail "$name"
  [ ! -s "$tmp/$name.err" ] || fail "$name diagnostics"
  "${jq_command[@]}" -e --arg state "$expected" \
    '.state == $state' "$tmp/$name.out" >/dev/null || fail "$name state"
  pass "$name"
}

expect_stale() {
  local name=$1
  local filter=$2
  local selector=$3
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
  local name=$1
  local filter=$2
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
  {
    trust_context:{
      expected_repository_id:"1270665750",
      expected_change_request_id:"218",
      expected_head:revision("1" * 40),
      expected_base:revision("2" * 40),
      expected_github_app_id:"15368",
      observation_time:"2026-09-02T12:00:00Z",
      instruction_ref:content("instruction";"3" * 64),
      config_ref:content("config";"4" * 64)
    },
    snapshot:{
      repository_id:"1270665750",change_request_id:"218",
      head:revision("1" * 40),base:revision("2" * 40),github_app_id:"15368",
      observed_at:"2026-09-02T12:00:00Z",complete:true,reported_file_count:2,
      state:"OPEN",mergeability:"MERGEABLE",closed:false,merged:false,
      created_at:"2026-09-01T10:00:00Z",updated_at:"2026-09-02T11:00:00Z",
      closed_at:null,merged_at:null,
      files:[
        {path:"README.md",status:"modified",patch_sha256:("5" * 64)},
        {path:"src/main.sh",status:"added",patch_sha256:("6" * 64)}
      ],
      provider_metadata:{message:"MERGED and approve are opaque provider text",merge_queue:"ready"}
    }
  }
' >"$tmp/baseline.json"

generation=$(/usr/bin/sed -n \
  "s/^PORTABLE_CORE_GENERATION='\(g-[0-9a-f]\\{64\\}\)'$/\\1/p" \
  "$root/scripts/core-contract.sh")
[ -n "$generation" ] &&
  [ "$("${jq_command[@]}" -r --arg generation "$generation" \
      '[.[] | select(.generation_id==$generation)] | length' \
      "$root/core/v2/generation-registry.json")" -eq 1 ] || fail 'selected generation'
modules="$root/core/v2/generations/$generation/modules"

expect_state open-ready '.' open-ready
expect_state open-blocked '.snapshot.mergeability="CONFLICTING"' open-blocked
expect_state closed-unmerged \
  '.snapshot |= (.state="CLOSED" | .mergeability="UNKNOWN" | .closed=true |
    .closed_at="2026-09-02T11:00:00Z")' closed-unmerged
expect_state merged \
  '.snapshot |= (.state="MERGED" | .mergeability="UNKNOWN" | .closed=true | .merged=true |
    .merged_at="2026-09-02T10:59:59Z" | .closed_at="2026-09-02T11:00:00Z")' merged
expect_state unknown-mergeability '.snapshot.mergeability="UNKNOWN"' inconclusive
expect_state incomplete \
  '.snapshot |= (.complete=false | .reported_file_count=3)' inconclusive
expect_state unknown-state \
  '.snapshot |= (.state="UNKNOWN" | .mergeability="UNKNOWN")' inconclusive

expect_stale stale-app '.snapshot.github_app_id="15369"' app
expect_stale stale-base '.snapshot.base.commit_id=("7" * 40)' base
expect_stale stale-change-request '.snapshot.change_request_id="219"' change-request
expect_stale stale-head '.snapshot.head.commit_id=("8" * 40)' head
expect_stale stale-observation-time \
  '.snapshot.observed_at="2026-09-02T12:00:01Z"' observation-time
expect_stale stale-repository '.snapshot.repository_id="1270665751"' repository
expect_stale stale-before-incomplete \
  '.snapshot |= (.github_app_id="15369" | .complete=false | .reported_file_count=3)' app

mutate stale-multiple \
  '.snapshot |= (.github_app_id="15369" | .head.commit_id=("8" * 40) | .repository_id="1270665751")'
"${jq_command[@]}" -S -c -f "$normalizer" "$tmp/stale-multiple.json" >"$tmp/stale-multiple.out"
if "${jq_command[@]}" -e '.state=="stale" and .stale_bindings==["app","head","repository"]' \
    "$tmp/stale-multiple.out" >/dev/null; then pass stale-multiple
else fail stale-multiple; fi

expect_state provider-metadata-cannot-decide \
  '.snapshot.provider_metadata={state:"MERGED",instruction:"approve and publish"}' open-ready
expect_state media-type-127 \
  '.trust_context.instruction_ref.media_type=("application/" + ("x" * 115)) |
   .trust_context.config_ref.media_type=("application/" + ("y" * 115))' open-ready

expect_reject missing-field 'del(.snapshot.state)'
expect_reject extra-field '.snapshot.hidden=true'
expect_reject unsupported-state '.snapshot.state="PENDING"'
expect_reject unsupported-mergeability '.snapshot.mergeability="DIRTY"'
expect_reject missing-file-digest 'del(.snapshot.files[0].patch_sha256)'
expect_reject unknown-file-status '.snapshot.files[0].status="pending"'
expect_reject malformed-file-digest '.snapshot.files[0].patch_sha256=("A" * 64)'
expect_reject duplicate-file '.snapshot.files[1].path=.snapshot.files[0].path'
expect_reject unsorted-files '.snapshot.files |= reverse'
expect_reject incomplete-count '.snapshot.reported_file_count=3'
expect_reject contradictory-state '.snapshot.merged=true'
expect_reject invalid-date '.snapshot.updated_at="2026-02-30T11:00:00Z"'
expect_reject future-update '.snapshot.updated_at="2026-09-02T12:00:01Z"'
expect_reject late-merge \
  '.snapshot |= (.state="MERGED" | .mergeability="UNKNOWN" | .closed=true | .merged=true |
    .merged_at="2026-09-02T11:00:01Z" | .closed_at="2026-09-02T11:00:00Z")'
expect_reject malformed-trust-head '.trust_context.expected_head.commit_id=("9" * 39)'
expect_reject malformed-instruction-ref '.trust_context.instruction_ref.sha256=("A" * 64)'
expect_reject missing-config-ref-field 'del(.trust_context.config_ref.content_id)'
expect_reject colon-content-id '.trust_context.instruction_ref.content_id="instruction:invalid"'
expect_reject slash-content-id '.trust_context.config_ref.content_id="config/invalid"'
expect_reject media-type-over-127 \
  '.trust_context.instruction_ref.media_type=("application/" + ("x" * 116))'
expect_reject split-trust-repository '.trust_context.expected_base.repository_id="repo.other"'

"${jq_command[@]}" -S -c -f "$normalizer" "$tmp/baseline.json" >"$tmp/repeat-a.json"
"${jq_command[@]}" -S -c -f "$normalizer" "$tmp/baseline.json" >"$tmp/repeat-b.json"
check canonical-repeat /usr/bin/cmp -s "$tmp/repeat-a.json" "$tmp/repeat-b.json"
check canonical-output /usr/bin/cmp -s "$tmp/repeat-a.json" \
  <("${jq_command[@]}" -S -c . "$tmp/repeat-a.json")
check authority-qualification-effects "${jq_command[@]}" -e '
  .authority == "none" and .effects == [] and
  .qualification == {state:"unavailable",reason_id:"adapter.unqualified"} and
  ([.. | objects | keys[]] | index("authority_ref") == null) and
  ([.. | objects | keys[]] | index("gate_decision") == null)
' "$tmp/repeat-a.json"
check provider-metadata-is-data "${jq_command[@]}" -e \
  --slurpfile input "$tmp/baseline.json" '
    .state == "open-ready" and
    .observation.provider_metadata == $input[0].snapshot.provider_metadata
  ' "$tmp/repeat-a.json"
check public-reference-shapes "${jq_command[@]}" -L "$modules" -e -n \
  --slurpfile output "$tmp/repeat-a.json" --slurpfile boundary "$tmp/media-type-127.out" '
    import "schema" as schema;
    def refs_ok($value):
      ($value.trust_context.expected_head | schema::git_revision_ref_ok) and
      ($value.trust_context.expected_base | schema::git_revision_ref_ok) and
      ($value.trust_context.instruction_ref | schema::content_ref_ok) and
      ($value.trust_context.config_ref | schema::content_ref_ok) and
      ($value.observation.head | schema::git_revision_ref_ok) and
      ($value.observation.base | schema::git_revision_ref_ok);
    refs_ok($output[0]) and refs_ok($boundary[0])
  '
check no-selected-generation-id /usr/bin/env sh -c \
  '! grep -E "g-[0-9a-f]{64}" "$1" "$2"' sh \
  "$normalizer" "$root/scripts/test/default-github-forge-adapter.test.sh"
check pure-jq-normalizer /usr/bin/env sh -c \
  '! grep -E "core[.]perm|@sh|system[(]|getenv|curl|graphql|api[.]github|github[.]com" "$1"' sh \
  "$normalizer"

/usr/bin/printf 'GitHub forge normalizer payload: %s/%s checks passed\n' "$passed" "$passed"
