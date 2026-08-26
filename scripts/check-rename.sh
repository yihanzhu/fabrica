#!/usr/bin/env bash
# scripts/check-rename.sh — fail CI if any tracked file still uses the old names.
#
# The product was renamed to ystack and the manager persona to yshifu. This gate
# scans every git-tracked text file for the old product or persona name
# (case-insensitive). If it finds any, it prints one line per hit as
# file:line:text and exits 1. A clean tree exits 0.
#
# Three kinds of lines may keep an old name:
#   1. Documented back-compat code — reading the old per-target dir, the old
#      env keys, or the old shipped-default marker so targets on the old names
#      keep working. Convention: such a line carries the word
#      "legacy" (either case) on the same line. Such lines are skipped.
#   2. Anything under work/ — merged chain artifacts are history, kept as-is.
#   3. This script and its test — they must spell the old names to search
#      for them, so they are skipped by path.
#
# Run from anywhere inside the repo: scripts/check-rename.sh

set -euo pipefail

# Scan from the repo root so the tracked-file list covers the whole repo.
cd "$(git rev-parse --show-toplevel)" || exit 1

# The old names to hunt for (matched case-insensitively).
pattern='fabrica|faber'

# A line containing the word "legacy" (any case) is documented back-compat — allowed.
# scripts/test/ is exempt as a class: its fixtures deliberately spell the old names
# to prove the fallbacks work; reviewers own test hygiene.

hits=0
while IFS= read -r -d '' file; do
  case "$file" in
    work/*) continue ;;                                # history, kept as-is
    scripts/check-rename.sh) continue ;;               # this gate spells the old names
    scripts/test/v2-check-rename.test.sh) continue ;;  # so does its test
  esac
  # Skip paths that are not plain files (deleted in the worktree, submodules).
  [ -f "$file" ] || continue
  # -I skips binary files, -i ignores case, -n prints the line number.
  case "$file" in
    scripts/test/*) continue ;;                        # fixtures exercise the fallbacks
  esac
  while IFS= read -r match; do
    lower="$(printf '%s' "$match" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *legacy*) continue ;;                            # self-labeled back-compat line
    esac
    printf '%s:%s\n' "$file" "$match"
    hits=$((hits + 1))
  done < <(grep -IinE "$pattern" -- "$file" || true)
done < <(git ls-files -z)

if [ "$hits" -gt 0 ]; then
  echo "check-rename: $hits line(s) still use an old name (listed above)." >&2
  exit 1
fi
echo "check-rename: clean — no old names in tracked files."
