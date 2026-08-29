#!/usr/bin/env bash
# scripts/core-contract.sh — the only public front door to core/v1/contracts.jq.
#
# Three exact commands, no others:
#   core-contract.sh validate-document DOCUMENT
#   core-contract.sh validate-profile-set PROFILE RESOLVED_PROFILE MANIFEST...  (1-8 manifests)
#   core-contract.sh validate-stage-run REQUEST RESOLVED_PROFILE RESULT
#
# Success: exit 0, empty stdout. Failure: nonzero exit, stderr starts with one
# allowlisted E_USAGE|E_RUNTIME|E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION
# token. Input bytes and the caller-supplied paths are never echoed back.
#
# This script never proves Git/content existence — it only checks that each
# input is exactly one canonical-JSON document and asks core/v1/contracts.jq to
# validate shapes/refs/relations. See work/portable-core-contracts/spec.md.

set -euo pipefail
LC_ALL=C
export LC_ALL
umask 077

fail() {
  # fail CODE — the only place stderr is written; never echoes a path or byte.
  printf '%s\n' "$1" >&2
  exit 1
}

# Resolve the schema from this script's own repo root, never a caller path.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/.." && pwd -P)"
schema="$repo_root/core/v1/contracts.jq"
[ -f "$schema" ] || fail "E_RUNTIME"

command -v jq >/dev/null 2>&1 || fail "E_RUNTIME"
jq_version="$(jq --version 2>/dev/null || true)"
[ "$jq_version" = "jq-1.6" ] || fail "E_RUNTIME"

sha_tool=""
if command -v sha256sum >/dev/null 2>&1; then
  sha_tool="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  sha_tool="shasum -a 256"
else
  fail "E_RUNTIME"
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
byte_limit=1048576

# snapshot_one INPUT OUT_CANON_VAR OUT_SHA_VAR — bound-read, canonicalize, hash one
# input file. Populates the two named variables on success; calls fail() otherwise.
snapshot_one() {
  input="$1"
  [ -r "$input" ] || fail "E_RUNTIME"
  raw="$tmpdir/raw.$$.$RANDOM"
  if ! head -c $((byte_limit + 1)) -- "$input" > "$raw" 2>/dev/null; then
    fail "E_RUNTIME"
  fi
  size="$(wc -c < "$raw" | tr -d ' ')"
  [ "$size" -le "$byte_limit" ] || fail "E_LIMIT"

  canon="$tmpdir/canon.$$.$RANDOM"
  if ! jq -s -S -c 'if length == 1 then .[0] else error("root-count") end' \
        -- "$raw" > "$canon" 2>/dev/null; then
    fail "E_PARSE"
  fi
  cmp -s "$raw" "$canon" || fail "E_CANONICAL"

  digest="$($sha_tool "$raw" 2>/dev/null | awk '{print $1}')"
  [ -n "$digest" ] || fail "E_RUNTIME"

  snap_canon="$canon"
  snap_sha="$digest"
}

# validate MODE INPUT... — snapshot every input in order, assemble the driver
# value, and run it through the pure jq validator.
validate() {
  mode="$1"
  shift
  contents_file="$tmpdir/contents.ndjson"
  : > "$contents_file"
  shas_json="[]"
  for f in "$@"; do
    snapshot_one "$f"
    cat -- "$snap_canon" >> "$contents_file"
    shas_json="$(printf '%s' "$shas_json" | jq -c --arg s "$snap_sha" '. + [$s]')"
  done

  driver="$tmpdir/driver.json"
  jq -n --arg mode "$mode" --argjson shas "$shas_json" --slurpfile contents "$contents_file" \
    '{mode: $mode, docs: ([range(0; ($contents|length))] | map({content: $contents[.], sha256: $shas[.]}))}' \
    > "$driver" 2>/dev/null || fail "E_RUNTIME"

  out="$tmpdir/out.txt"
  if ! jq -r -f "$schema" "$driver" > "$out" 2>/dev/null; then
    fail "E_RUNTIME"
  fi
  lines="$(wc -l < "$out" | tr -d ' ')"
  if [ "$lines" -eq 0 ] && [ ! -s "$out" ]; then
    exit 0
  fi
  [ "$lines" -eq 1 ] || fail "E_RUNTIME"
  token="$(cat -- "$out")"
  case "$token" in
    E_USAGE|E_RUNTIME|E_PARSE|E_CANONICAL|E_LIMIT|E_SHAPE|E_REF|E_RELATION) fail "$token" ;;
    *) fail "E_RUNTIME" ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  validate-document)
    [ "$#" -eq 2 ] || fail "E_USAGE"
    validate "document" "$2"
    ;;
  validate-profile-set)
    # cmd + PROFILE + RESOLVED_PROFILE + 1..8 manifests = 4..11 total args.
    [ "$#" -ge 4 ] && [ "$#" -le 11 ] || fail "E_USAGE"
    shift
    validate "profile-set" "$@"
    ;;
  validate-stage-run)
    [ "$#" -eq 4 ] || fail "E_USAGE"
    validate "stage-run" "$2" "$3" "$4"
    ;;
  *)
    fail "E_USAGE"
    ;;
esac
