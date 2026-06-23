#!/usr/bin/env bash
set -euo pipefail

# install.sh — generate the /faber Claude Code command from this repo.
#
# Reproducibly writes ~/.claude/commands/faber.md from templates/faber-command.md,
# substituting the control-plane repo's own location for the {{FABRICA_ROOT}}
# placeholder — so the command never hardcodes ~/git/fabrica and works from
# wherever this clone lives. Idempotent: re-running yields the same file; if an
# existing faber.md differs, it is backed up to faber.md.bak before overwriting.

# Resolve the repo root from this script's own location, following symlinks so
# the derived path is the real clone directory even if install.sh is symlinked.
script_path="$0"
while [ -L "$script_path" ]; do
  link_target="$(readlink "$script_path")"
  case "$link_target" in
    /*) script_path="$link_target" ;;
    *)  script_path="$(dirname "$script_path")/$link_target" ;;
  esac
done
repo_root="$(cd "$(dirname "$script_path")/.." && pwd -P)"

template="$repo_root/templates/faber-command.md"
commands_dir="$HOME/.claude/commands"
target="$commands_dir/faber.md"

if [ ! -f "$template" ]; then
  echo "error: template not found: $template" >&2
  exit 1
fi

# Render the template with the resolved repo path. Build the content first so we
# can compare against any existing file before touching it (idempotency + backup).
# Use bash literal string replacement (not sed) so paths containing sed
# metacharacters (&, #, /, spaces) substitute correctly — bash ${var//pat/repl}
# treats the replacement literally.
template_contents="$(cat "$template")"
rendered="${template_contents//'{{FABRICA_ROOT}}'/$repo_root}"

mkdir -p "$commands_dir"

if [ -f "$target" ]; then
  if [ "$rendered" = "$(cat "$target")" ]; then
    echo "Already up to date: $target"
    action="unchanged"
  else
    cp "$target" "$target.bak"
    printf '%s\n' "$rendered" >"$target"
    echo "Updated (backed up old version to $target.bak): $target"
    action="updated"
  fi
else
  printf '%s\n' "$rendered" >"$target"
  echo "Created: $target"
  action="created"
fi

cat <<EOF

/faber command ${action}.
  command file: $target
  repo path:    $repo_root  (derived from this script's location)

Next steps:
  1. In a target repo, run: "$repo_root/scripts/setup-target-repo.sh" <owner>/<repo>
     (bootstraps the loop labels).
  2. Confirm that target repo has CI (the hard merge gate) and, optionally, a
     CLAUDE.md of conventions — see $repo_root/templates/.
  3. Open Claude Code in a target repo and run /faber to summon the manager.
EOF
