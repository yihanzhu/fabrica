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
  1. Make sure your target repo has CI that runs on PRs (the hard merge gate) — the one real
     precondition. You no longer have to wire it yourself: if the repo has no PR CI, Faber can
     BOOTSTRAP it for you at first contact (it scaffolds a pull_request workflow from your
     toolchain as the first 'add PR CI' issue). That CI-bootstrap PR is HUMAN-MERGE-ONLY: Faber
     classifies it as such and does NOT run merge-pr.sh on it at all — a same-repo bootstrap PR
     that adds the workflow can run it on its own PR and self-report green, so the human, not the
     tooling, is the gate — YOU approve and merge it by hand. Or wire it yourself. The loop
     labels + readiness pre-flight are handled by Faber on first use (see step 3), so you do NOT
     need to run setup-target-repo.sh / doctor.sh by hand — they remain available as an
     optional/advanced pre-flight. A target CLAUDE.md is OPTIONAL: the coder auto-discovers the
     install/lint/build/test commands from the repo's CI workflows and standard manifests
     (see the discovery order in $repo_root/routines/coder.md). A filled-in CLAUDE.md
     "Stack & commands" ($repo_root/templates/target-CLAUDE.md) is an OPTIONAL override —
     add one only to pin or disambiguate a non-standard toolchain.
  2. Set your own north star PER TARGET — in each target repo, set + commit + approve
     .fabrica/north-star.md (the gate reads the target's COMMITTED north star; an
     uncommitted local edit does not authorize proactive work). Replace the shipped
     Fabrica default with your own direction — the shipped approval note is the prior
     owner's history, not a token that approves the goal for you. (Fabrica-self is its own
     target: when you run against this control-plane repo it uses its own root
     $repo_root/NORTH_STAR.md.)
  3. Open Claude Code in a target repo and run /faber to summon the manager. On its first
     loop action this session, Faber auto-bootstraps the repo — derives <owner>/<repo> from
     the cwd, creates/reconciles the loop labels, and runs the read-only readiness self-check
     — so adoption is 'cd repo -> /faber -> go'. Then, in that session, explicitly approve
     your north star to Faber — this is the root authorization that unlocks proactive
     autonomous mode (approve it with Faber, not by editing the file). Until it's set +
     approved, Faber acts only on issues you direct (your one-liner -> Faber drafts the spec
     -> you approve that drafted spec -> ready).
EOF
