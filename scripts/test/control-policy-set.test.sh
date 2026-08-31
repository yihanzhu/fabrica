#!/usr/bin/env bash
# shellcheck disable=SC2016
set -euo pipefail
export LC_ALL=C
umask 077

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
validator="$root/control/v1/validate.sh"
tmp=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ystack-control-policy-test.XXXXXX")
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
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Darwin:*) jq_asset=jq-osx-amd64; jq_sha=5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef ;;
  Linux:x86_64) jq_asset=jq-linux64; jq_sha=af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44 ;;
  *) fail "unsupported host $platform" ;;
esac
jq_cache_dir="${TMPDIR:-/tmp}/ystack-portable-core-jq16"
/bin/mkdir -p "$jq_cache_dir"
jq_cache="$jq_cache_dir/$jq_asset"
if [ ! -f "$jq_cache" ] || [ "$(sha_file "$jq_cache")" != "$jq_sha" ]; then
  download=$(/usr/bin/mktemp "$jq_cache_dir/.jq-1.6.XXXXXX")
  /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL \
    "https://github.com/jqlang/jq/releases/download/jq-1.6/$jq_asset" \
    -o "$download"
  [ "$(sha_file "$download")" = "$jq_sha" ] || fail 'jq release digest'
  /bin/chmod 0555 "$download"
  /bin/mv "$download" "$jq_cache"
  download=''
fi
[ "$(sha_file "$jq_cache")" = "$jq_sha" ] || fail 'jq digest'
bin="$tmp/bin"
/bin/mkdir -m 700 "$bin"
/bin/cp "$jq_cache" "$bin/jq"
/bin/chmod 0555 "$bin/jq"
jq_bin="$bin/jq"
[ "$("$jq_bin" --version)" = jq-1.6 ] || fail 'jq identity'

valid="$tmp/valid.json"
"$jq_bin" -S -c -n '
  def ref($id;$media;$character):
    {content_id:$id,media_type:$media,sha256:($character*64)};
  def decision_character($character):
    if $character=="1" then "a" elif $character=="2" then "b"
    elif $character=="3" then "c" elif $character=="4" then "d"
    elif $character=="5" then "e" else "f" end;
  def section($id;$character):
    {section_id:$id,
     policy_ref:ref("control-policy:"+$id;"application/vnd.ystack.control-policy+json";$character),
     decision_ref:ref("control-decision:"+$id;"application/vnd.ystack.control-decision+json";
       decision_character($character))};
  {schema_version:1,kind:"control_policy_set",id:"control-policy-set.example",
   body:{policy_version:"v1",activation_state:"inactive",fail_mode:"closed",
     core_contract:{semantic_identity:"core.contracts.v2",generation_id:("g-"+("7"*64)),
       package_ref:ref("core-contract-package.v2";"application/vnd.ystack.core-contract+json";"9")},
     sections:[section("credential-policy";"1"),section("duty-separation";"2"),
       section("evidence-integrity";"3"),section("kill-switch";"4"),
       section("risk-gates";"5"),section("sandbox";"6")]}}
' > "$valid"

run_validator() {
  local input=$1 out=$2 err=$3 status=0
  PATH="$bin:/usr/bin:/bin" "$validator" validate "$input" > "$out" 2> "$err" || status=$?
  RUN_STATUS=$status
}
expect_pass() {
  local name=$1 input=$2
  local out="$tmp/$name.out" err="$tmp/$name.err"
  run_validator "$input" "$out" "$err"
  [ "$RUN_STATUS" -eq 0 ] && [ ! -s "$out" ] && [ ! -s "$err" ] || fail "$name"
  pass "$name"
}
expect_error() {
  local name=$1 expected=$2 input=$3
  local out="$tmp/$name.out" err="$tmp/$name.err"
  run_validator "$input" "$out" "$err"
  if [ "$RUN_STATUS" -eq 0 ] || [ -s "$out" ] ||
     [ "$(/bin/cat "$err")" != "$expected" ] ||
     /usr/bin/grep -Fq "$tmp" "$err"; then
    fail "$name"
  fi
  pass "$name"
}
mutate() {
  local name=$1 filter=$2
  "$jq_bin" -S -c "$filter" "$valid" > "$tmp/$name.json"
  /usr/bin/printf '%s\n' "$tmp/$name.json"
}

expect_pass canonical-valid "$valid"
for field in schema_version kind id body; do
  expect_error "missing-envelope-$field" E_SHAPE "$(mutate "missing-envelope-$field" "del(.$field)")"
done
for field in policy_version activation_state fail_mode core_contract sections; do
  expect_error "missing-body-$field" E_SHAPE "$(mutate "missing-body-$field" "del(.body.$field)")"
done
for field in semantic_identity generation_id package_ref; do
  expect_error "missing-core-$field" E_SHAPE "$(mutate "missing-core-$field" "del(.body.core_contract.$field)")"
done
for field in section_id policy_ref decision_ref; do
  expect_error "missing-section-$field" E_SHAPE \
    "$(mutate "missing-section-$field" "del(.body.sections[0].$field)")"
done

expect_error section-missing E_RELATION "$(mutate section-missing '.body.sections |= .[:-1]')"
expect_error section-extra E_RELATION "$(mutate section-extra '.body.sections += [(.body.sections[0] | .section_id="other" | .policy_ref.content_id="control-policy:other" | .policy_ref.sha256=("8"*64) | .decision_ref.content_id="control-decision:other" | .decision_ref.sha256=("8"*64))]')"
expect_error section-duplicate E_RELATION "$(mutate section-duplicate '.body.sections[1]=.body.sections[0]')"
expect_error section-reordered E_RELATION "$(mutate section-reordered '.body.sections[0:2] |= reverse')"
expect_error section-renamed E_RELATION "$(mutate section-renamed '.body.sections[0].section_id="renamed"')"
expect_error policy-media E_SHAPE "$(mutate policy-media '.body.sections[0].policy_ref.media_type="application/json"')"
expect_error decision-media E_SHAPE "$(mutate decision-media '.body.sections[0].decision_ref.media_type="application/json"')"
expect_error package-media E_SHAPE "$(mutate package-media '.body.core_contract.package_ref.media_type="application/json"')"
expect_error bad-digest E_SHAPE "$(mutate bad-digest '.body.sections[0].policy_ref.sha256="bad"')"
expect_error bad-id E_SHAPE "$(mutate bad-id '.id="Bad ID"')"
expect_error policy-id-link E_RELATION "$(mutate policy-id-link '.body.sections[0].policy_ref.content_id="control-policy:other"')"
expect_error decision-id-link E_RELATION "$(mutate decision-id-link '.body.sections[0].decision_ref.content_id="control-decision:other"')"
expect_error core-identity E_RELATION "$(mutate core-identity '.body.core_contract.semantic_identity="other.contract"')"
expect_error core-generation E_SHAPE "$(mutate core-generation '.body.core_contract.generation_id="g-bad"')"
expect_error core-generation-number E_SHAPE "$(mutate core-generation-number '.body.core_contract.generation_id=1')"
expect_error core-generation-object E_SHAPE "$(mutate core-generation-object '.body.core_contract.generation_id={}')"
expect_error core-generation-array E_SHAPE "$(mutate core-generation-array '.body.core_contract.generation_id=[]')"
expect_error core-generation-null E_SHAPE "$(mutate core-generation-null '.body.core_contract.generation_id=null')"
expect_error active-state E_RELATION "$(mutate active-state '.body.activation_state="active"')"
expect_error mutable-state E_RELATION "$(mutate mutable-state '.body.activation_state="mutable"')"
expect_error fail-open E_RELATION "$(mutate fail-open '.body.fail_mode="open"')"
for field in command url credential vendor executable grant evaluation activation; do
  expect_error "injected-$field" E_SHAPE \
    "$(mutate "injected-$field" ".body.$field=\"forbidden\"")"
done

/usr/bin/printf '{\n' > "$tmp/parse.json"
expect_error parse E_PARSE "$tmp/parse.json"
"$jq_bin" . "$valid" > "$tmp/noncanonical.json"
expect_error noncanonical E_CANONICAL "$tmp/noncanonical.json"
/bin/cat "$valid" "$valid" > "$tmp/multi-root.json"
expect_error multi-root E_PARSE "$tmp/multi-root.json"
/usr/bin/printf '\357\273\277' > "$tmp/bom.json"
/bin/cat "$valid" >> "$tmp/bom.json"
expect_error bom E_PARSE "$tmp/bom.json"
/usr/bin/awk 'BEGIN { for (i=0;i<1048577;i++) printf "x" }' > "$tmp/raw-limit.json"
expect_error raw-limit E_LIMIT "$tmp/raw-limit.json"
"$jq_bin" -S -c -n 'reduce range(0;33) as $i (0;{x:.})' > "$tmp/depth-limit.json"
expect_error depth-limit E_LIMIT "$tmp/depth-limit.json"
"$jq_bin" -S -c -n 'reduce range(0;1025) as $i ({};. + {($i|tostring):0})' > "$tmp/member-limit.json"
expect_error member-limit E_LIMIT "$tmp/member-limit.json"
"$jq_bin" -S -c '.body.extra=("x"*8193)' "$valid" > "$tmp/string-limit.json"
expect_error string-limit E_LIMIT "$tmp/string-limit.json"

/bin/ln -s "$valid" "$tmp/symlink.json"
expect_error symlink E_RUNTIME "$tmp/symlink.json"
/usr/bin/mkfifo "$tmp/input.fifo"
expect_error nonregular E_RUNTIME "$tmp/input.fifo"
fake_home="$tmp/fake-home"
fake_cwd="$tmp/fake-cwd"
/bin/mkdir -m 700 "$fake_home" "$fake_cwd"
ambient_out="$tmp/ambient.out"
ambient_err="$tmp/ambient.err"
(cd "$fake_cwd" && HOME="$fake_home" JQ_LIBRARY_PATH="$fake_home" \
  PATH="$bin:/usr/bin:/bin" "$validator" validate "$valid" > "$ambient_out" 2> "$ambient_err")
[ ! -s "$ambient_out" ] && [ ! -s "$ambient_err" ] || fail 'ambient independence'
pass 'ambient cwd and environment independence'

for required in control/v1/policy-set.jq control/v1/validate.sh scripts/test/control-policy-set.test.sh; do
  [ "$(/usr/bin/grep -Fxc "$required" "$root/ci/required-files.txt")" -eq 1 ] ||
    fail "manifest $required"
done
/usr/bin/grep -Fq 'Inactive control policy-set validator' "$root/README.md" || fail 'README docs'
/usr/bin/grep -Fq 'control-policy-set.test.sh' "$root/RESTORE.md" || fail 'RESTORE docs'
pass 'restore manifest and docs'
/usr/bin/printf 'control policy set: %s focused checks passed\n' "$passes"
