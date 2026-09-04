#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(CDPATH='' cd -P -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
config='profiles/default/v1/producer-config.json'
expected_blob='369159a30c8a0026644c3716e7fc1132206e826c'
sha_file() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'ok %s - %s\n' "$pass" "$1"; }

platform=$(/usr/bin/uname -s):$(/usr/bin/uname -m)
case "$platform" in
  Linux:x86_64) asset='jq-linux64'; asset_sha='af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44' ;;
  Darwin:x86_64|Darwin:arm64) asset='jq-osx-amd64'; asset_sha='5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef' ;;
  *) fail "unsupported jq 1.6 proof platform: $platform" ;;
esac
jq_bin="${TMPDIR:-/tmp}/ystack-portable-core-jq16/$asset"
[ -f "$jq_bin" ] && [ ! -L "$jq_bin" ] &&
  [ "$(sha_file "$jq_bin")" = "$asset_sha" ] || fail 'pinned jq 1.6 is required'
jq_command=("$jq_bin")
[ "$platform" != Darwin:arm64 ] || jq_command=(/usr/bin/arch -x86_64 "$jq_bin")
[ "$("${jq_command[@]}" --version)" = jq-1.6 ] || fail jq-version

[ -f "$root/$config" ] && [ ! -L "$root/$config" ] || fail config-file
[ "$(/usr/bin/git -C "$root" hash-object "$config")" = "$expected_blob" ] ||
  fail config-blob
index_record=$(/usr/bin/git -C "$root" ls-files --stage --error-unmatch -- "$config")
expected_index=$'100644 369159a30c8a0026644c3716e7fc1132206e826c 0\tprofiles/default/v1/producer-config.json'
[ "$index_record" = "$expected_index" ] ||
  fail config-index-anchor
ok 'the config is a tracked immutable Git blob'

"${jq_command[@]}" -e '
  type == "object" and
  (keys | sort) == ["effort_id","model_id","provider_id","schema_version"] and
  .schema_version == 1 and
  .provider_id == "anthropic" and
  .model_id == "claude.sonnet" and
  .effort_id == "high"
' "$root/$config" >/dev/null || fail producer-preference
ok 'the config records the inactive default producer preference'

printf 'default producer config: %s focused checks passed\n' "$pass"
