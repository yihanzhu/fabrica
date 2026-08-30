#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-ci}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci@example.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-ci}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci@example.com}"

count=0
while IFS= read -r test_file; do
  count=$((count + 1))
  printf '\n==> %s\n' "${test_file#"$root/"}"
  bash "$test_file"
done < <(find "$root/scripts/test" -maxdepth 1 -type f -name '*.test.sh' -print | LC_ALL=C sort)

if [ "$count" -eq 0 ]; then
  echo "error: no scripts/test/*.test.sh files found" >&2
  exit 1
fi
printf '\nall %s test scripts passed\n' "$count"
