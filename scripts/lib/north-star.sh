#!/usr/bin/env bash
# north-star.sh — the shared per-target north-star RESOLVER (sourced, not executed).
#
# Both scripts/manager-review.sh and scripts/doctor.sh need to answer the same question:
# "what is the active north star for the repo this run operates on?" Historically each
# hardcoded the control-plane root NORTH_STAR.md — which mis-reads Fabrica-self's star when
# a run targets an EXTERNAL repo, or forces a target's star into Fabrica's own source (the
# MapleFolio collision, 2026-07-01). This helper resolves the star FOR THE TARGET, so each
# target owns its own steering. It is `source`d by the callers (no shebang execution) — the
# `#!/usr/bin/env bash` line is only so shellcheck picks the right dialect.
#
# Resolution order (see issue #97):
#   1. Target-local:   <target-toplevel>/.fabrica/north-star.md, where target-toplevel is the
#      target repo's GIT TOP-LEVEL (`git -C <dir> rev-parse --show-toplevel`), NOT literal
#      $PWD — so a run from ANY subdirectory of the target clone resolves the top-level file.
#   2. Fabrica-self:   the control-plane root NORTH_STAR.md — used ONLY when the resolved repo
#      is the Fabrica control-plane repo itself (IDENTITY check: the target's repo slug equals
#      Fabrica's own nameWithOwner), never merely "the file happens to exist."
#   3. Unset:          neither resolves and the target is NON-EMPTY -> UNSET; the caller
#      decides how to react (manager-review FAILs; doctor WARNs). Never silently read another
#      repo's star.
#
# The functions here are pure resolution/derivation — they print a result and never post
# comments, edit files, or mutate any checkout. Callers own the side effects.

# ns_git_toplevel <dir> — print the git top-level directory that contains <dir>, or nothing.
# `git -C <dir> rev-parse --show-toplevel` walks UP from <dir>, so a nested subdirectory of a
# clone resolves to the clone root (the subdirectory-invocation regression guard). Prints
# nothing (and returns non-zero) when <dir> is not inside a git work tree.
ns_git_toplevel() {
  local dir="$1"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

# ns_repo_slug <dir> — print the <owner>/<repo> (gh nameWithOwner) for the repo containing
# <dir>, or nothing. This is the IDENTITY used for the Fabrica-self check and doctor's
# cwd/slug match — a slug, not a path, so two different clones of the same repo compare equal
# and a clone whose path is a prefix of another's cannot false-match. Returns non-zero (and
# prints nothing) when <dir> is not a gh-recognized repo.
#
# `env -u GH_REPO`: `gh repo view` honors an exported GH_REPO OVER the repo at the cwd, so a
# set GH_REPO would make this print the ENV repo's slug instead of the repo at <dir> — which
# would let doctor.sh's cwd/slug match falsely pass (spoofing an external checkout into looking
# like the target and reading the wrong local .fabrica/north-star.md). Clearing GH_REPO for
# this one invocation forces the slug to reflect the actual repo at <dir>, always.
ns_repo_slug() {
  local dir="$1"
  ( cd "$dir" 2>/dev/null && env -u GH_REPO gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null ) || true
}

# ns_slug_eq <a> <b> — return 0 (true) when two <owner>/<repo> slugs name the SAME repo,
# compared CASE-INSENSITIVELY. GitHub owner/repo names are case-insensitive, so a user-typed
# arg (`acme/myrepo`) and `gh repo view`'s canonical casing (`Acme/MyRepo`) are the same
# target — a case-exact `=` would treat them as different and silently skip the north-star
# seeding / --check drift / doctor's local-vs-remote guard. Callers use THIS helper (never a
# bare `=`) so the case-insensitivity rule lives in one place. Two EMPTY slugs are NOT equal
# (an unresolved cwd must never match a target), so callers should still guard on non-emptiness.
ns_slug_eq() {
  local a b
  a="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  b="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  [ "$a" = "$b" ]
}

# ns_fabrica_slug — print Fabrica's OWN control-plane repo slug (the repo that ships THIS
# resolver), or nothing. Derived from the resolver file's own location (this sourced file
# lives at <control-plane>/scripts/lib/north-star.sh), following symlinks, so it identifies
# Fabrica regardless of which target's cwd the caller runs from. Used for the identity check
# in ns_resolve: fall back to root NORTH_STAR.md ONLY when the target IS Fabrica itself.
ns_fabrica_slug() {
  ns_repo_slug "$(ns_fabrica_root)"
}

# ns_fabrica_root — print the Fabrica control-plane repo root, derived from THIS file's own
# location (following symlinks: <root>/scripts/lib/north-star.sh -> dirname x3). BASH_SOURCE[0]
# is the path of the sourced file (not $0, which is the CALLER's path) — that is what lets a
# sourced helper locate the control plane independent of the caller's cwd or invocation.
ns_fabrica_root() {
  local self="${BASH_SOURCE[0]}"
  while [ -L "$self" ]; do
    local link_target
    link_target="$(readlink "$self")"
    case "$link_target" in
      /*) self="$link_target" ;;
      *)  self="$(dirname "$self")/$link_target" ;;
    esac
  done
  # <root>/scripts/lib/north-star.sh -> up three levels is <root>.
  ( cd "$(dirname "$self")/../.." && pwd -P )
}

# ns_dir_is_empty_repo <dir> — return 0 (true) when the git repo containing <dir> has NO
# commits yet (a freshly `git init`ed, empty target). An empty target legitimately has no
# north star, so callers treat "empty + no star" as NOT-unset (benign), distinct from
# "non-empty + no star" (UNSET — a real gap). Returns non-zero for a non-empty repo OR when
# <dir> is not a git repo at all (a non-repo is not the empty-repo case).
ns_dir_is_empty_repo() {
  local dir="$1"
  git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1 || return 1
  # `git rev-parse HEAD` succeeds iff there is at least one commit; its failure means the
  # repo is empty (no commits). `--verify --quiet` keeps it silent.
  if git -C "$dir" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ns_resolve <target_dir> — resolve the active north star for the repo containing <target_dir>.
# Prints ONE result line to stdout; the caller reads the first token:
#   LOCAL <path>          the target's own <toplevel>/.fabrica/north-star.md (order 1)
#   FABRICA_SELF <path>   the control-plane root NORTH_STAR.md, target IS Fabrica (order 2)
#   UNSET                 non-empty target, no star resolved (order 3) — caller decides
#   EMPTY                 target repo has no commits yet (benign; no star expected)
#   NOREPO                <target_dir> is not inside a git work tree (caller-specific handling)
# This is the LOCAL resolver (operates on a checkout on disk). doctor's remote-by-slug path
# is a separate concern handled in doctor.sh (it may not have the target checked out locally).
ns_resolve() {
  local target_dir="$1"
  local toplevel
  toplevel="$(ns_git_toplevel "$target_dir")"
  if [ -z "$toplevel" ]; then
    echo "NOREPO"
    return 0
  fi

  # Order 1 — target-local .fabrica/north-star.md at the git top-level.
  local local_star="$toplevel/.fabrica/north-star.md"
  if [ -f "$local_star" ]; then
    echo "LOCAL $local_star"
    return 0
  fi

  # Order 2 — Fabrica-self fallback: root NORTH_STAR.md, ONLY on an identity match (the
  # target's repo slug equals Fabrica's own). Not "file exists" — an external target must
  # never inherit Fabrica's star just because this clone happens to sit alongside it.
  local target_slug fabrica_slug
  target_slug="$(ns_repo_slug "$toplevel")"
  fabrica_slug="$(ns_fabrica_slug)"
  if [ -n "$target_slug" ] && [ -n "$fabrica_slug" ] && ns_slug_eq "$target_slug" "$fabrica_slug"; then
    local root_star
    root_star="$(ns_fabrica_root)/NORTH_STAR.md"
    if [ -f "$root_star" ]; then
      echo "FABRICA_SELF $root_star"
      return 0
    fi
  fi

  # Order 3 — nothing resolved. An empty target (no commits) is benign; a non-empty one is a
  # real UNSET gap the caller must react to.
  if ns_dir_is_empty_repo "$toplevel"; then
    echo "EMPTY"
    return 0
  fi
  echo "UNSET"
  return 0
}
