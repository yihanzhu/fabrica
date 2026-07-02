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
# Resolution order (see issue #97, hardened in #98a):
#   1. Fabrica-self:   the control-plane root NORTH_STAR.md — used ONLY when the resolved repo
#      IS the Fabrica control-plane repo itself, decided by a PATH identity check (the target's
#      git top-level equals THIS lib's own control-plane root), never a slug and never merely
#      "a file happens to exist." Checked FIRST so a stray/committed `.fabrica/north-star.md`
#      accidentally sitting in the control-plane checkout cannot shadow Fabrica's own root star.
#   2. Target-local:   <target-toplevel>/.fabrica/north-star.md, where target-toplevel is the
#      target repo's GIT TOP-LEVEL (`git -C <dir> rev-parse --show-toplevel`), NOT literal
#      $PWD — so a run from ANY subdirectory of the target clone resolves the top-level file.
#   3. Unset:          neither resolves and the target is NON-EMPTY -> UNSET; the caller
#      decides how to react (manager-review FAILs; doctor WARNs). Never silently read another
#      repo's star.
#
# SECURITY (#98a): the Fabrica-self identity is PATH-only. An earlier slug-based fallback
# (target slug == Fabrica's slug -> FABRICA_SELF) rested on the git REMOTE URL, which any clone
# owner can set — so a hostile target pointing origin at Fabrica's slug would be authorized
# against Fabrica's root star, bypassing its own star AND the placeholder-FAIL. The remote URL
# is attacker-settable and thus NOT a trustworthy identity signal; only the path (the target IS
# the clone that ships this very lib) is trustworthy. The slug fallback is removed.
#
# The functions here are pure resolution/derivation — they print a result and never post
# comments, edit files, or mutate any checkout. Callers own the side effects.

# __ns_self — this file's OWN path, absolutized ONCE at source time. `${BASH_SOURCE[0]}` reflects
# HOW the caller sourced us: a relative `. scripts/lib/north-star.sh` leaves it relative, so a lazy
# `dirname`-based root derivation inside ns_fabrica_root would later resolve against the CALLER's
# cwd (which may have cd'd into a target repo) — mis-locating the control plane. Capturing and
# absolutizing here, at source time (cwd is still the caller's source-time cwd, which is where the
# relative path is valid), pins the self-path regardless of any later cd. ns_fabrica_root then uses
# this instead of re-reading BASH_SOURCE, and its symlink loop's relative-target branch resolves
# against the symlink's real dir rather than $PWD.
__ns_self="${BASH_SOURCE[0]}"
case "$__ns_self" in
  /*) ;;
  *) __ns_self="$(cd "$(dirname "$__ns_self")" && pwd -P)/$(basename "$__ns_self")" ;;
esac

# ns_git_toplevel <dir> — print the git top-level directory that contains <dir>, or nothing.
# `git -C <dir> rev-parse --show-toplevel` walks UP from <dir>, so a nested subdirectory of a
# clone resolves to the clone root (the subdirectory-invocation regression guard). Prints
# nothing (and returns non-zero) when <dir> is not inside a git work tree.
ns_git_toplevel() {
  local dir="$1"
  # `|| true`: a non-work-tree dir makes `git rev-parse` exit non-zero; without the guard this
  # (as the function's last command, and inside a caller's `x="$(ns_git_toplevel …)"`) would
  # abort a `set -e` consumer instead of degrading to empty output for the caller's own check.
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true
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
  # Reject an empty/missing arg: `cd ""` is a silent no-op that leaves the subshell in the
  # caller's INHERITED cwd, so `gh repo view` would then report the CALLER's repo slug instead
  # of "nothing" — a wrong-repo identity, not the empty result the contract promises. Return
  # non-zero (no stdout) so an empty arg can never fall through to the cwd's slug.
  [ -n "$dir" ] || return 1
  # `unset CDPATH`: with CDPATH set, `cd <relative>` may resolve <dir> against a CDPATH entry
  # (landing in the WRONG directory) AND echo the chosen path to stdout — which would be captured
  # as part of the slug. `cd -P -- "$dir"`: `-P` uses the physical dir (no symlink games), `--`
  # stops a dir starting with `-` being read as an option. `2>/dev/null` + `|| true` keep the
  # helper degrade-to-empty (never abort a `set -e` caller).
  ( unset CDPATH; cd -P -- "$dir" 2>/dev/null && env -u GH_REPO gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null ) || true
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
# Fabrica regardless of which target's cwd the caller runs from.
#
# NOTE (#98a): this is NO LONGER used for the Fabrica-self IDENTITY decision in ns_resolve —
# that is now PATH-only, because a slug (from the git remote URL) is attacker-settable and thus
# untrustworthy for authorization. Retained as a general-purpose derivation helper for callers
# that legitimately need Fabrica's own slug for a NON-authorization comparison (e.g. diagnostics).
ns_fabrica_slug() {
  # `|| true` on the inner substitution: ns_fabrica_root ends in `( cd … && pwd -P )`, which
  # exits non-zero if the derived root is unreachable — under `set -e` that would abort the
  # caller before ns_repo_slug (itself guarded) can degrade to empty. Guarding here keeps the
  # whole helper degrade-to-empty.
  local root
  root="$(ns_fabrica_root || true)"
  ns_repo_slug "$root"
}

# ns_fabrica_root — print the Fabrica control-plane repo root, derived from THIS file's own
# location (following symlinks: <root>/scripts/lib/north-star.sh -> dirname x3). BASH_SOURCE[0]
# is the path of the sourced file (not $0, which is the CALLER's path) — that is what lets a
# sourced helper locate the control plane independent of the caller's cwd or invocation.
ns_fabrica_root() {
  # `$__ns_self` (absolutized once at source time), NOT a fresh `${BASH_SOURCE[0]}`: a lazily
  # re-read BASH_SOURCE could still be the relative path the caller sourced us with, which would
  # resolve against the caller's (possibly cd'd) cwd. The pinned absolute self keeps root
  # derivation cwd-independent, and the relative-target symlink branch below resolves against
  # the (now absolute) symlink dir.
  local self="$__ns_self"
  while [ -L "$self" ]; do
    local link_target
    link_target="$(readlink "$self")"
    case "$link_target" in
      /*) self="$link_target" ;;
      *)  self="$(dirname "$self")/$link_target" ;;
    esac
  done
  # <root>/scripts/lib/north-star.sh -> up three levels is <root>. `2>/dev/null` + `|| true`
  # (matching the sibling value-helpers): an unreachable root — e.g. the sourced tree was
  # deleted out from under a long-running process — degrades to empty output (rc 0, no stderr
  # leak) instead of aborting a top-level `set -e` consumer with a `cd: … No such file` warning.
  ( cd "$(dirname "$self")/../.." 2>/dev/null && pwd -P ) || true
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

# The stable shipped-default marker (an HTML comment) that rides on the ACTIVE heading of a
# still-unreplaced shipped template. Both the gate (manager-review.sh) and doctor.sh (h) key
# their placeholder detection off THIS token, via ns_has_shipped_default_marker below, so the
# two never disagree on what counts as an un-replaced placeholder.
NS_SHIPPED_DEFAULT_TOKEN='fabrica-shipped-default'

# ns_active_region <file-or-"-"> — print the ACTIVE-entry region of a north-star document read
# from a file path (or, with `-`, from stdin): the first heading line carrying `status: active`
# through the lines up to (but not including) the NEXT heading (`#`…) or horizontal rule
# (`---`/`***`/`___`). Prints nothing when there is no `status: active` heading.
#
# Scoping to the active-entry region (not the whole file) is what stops the marker's mentions in
# the template's explanatory PROSE (and in NORTH_STAR.md's own docs) from tripping the check —
# those live OUTSIDE any active heading, so a correctly-replaced star (marker cleared from the
# active heading, still named in prose) is NOT flagged. Including the continuation lines up to
# the next heading/rule (not just the single heading line) catches a marker that a markdown
# reflow split onto the line just below the heading.
ns_active_region() {
  local src="$1"
  # awk over the document: once we hit a `status: active` heading line (case-insensitive, the
  # `active` possibly wrapped in markdown emphasis `*`/`_`), print from there until the next
  # heading line or horizontal rule. `IGNORECASE=1` is a gawk-ism; be portable by lowercasing in
  # a match on tolower(). Recognize the active heading the SAME way doctor historically did
  # (`status:` then optional non-alpha then `active`), so scoping is consistent.
  awk '
    {
      line = $0
      low = tolower(line)
    }
    in_region {
      # A new heading (line starting with #) or a horizontal rule ends the active region.
      if (line ~ /^[[:space:]]*#/ || low ~ /^[[:space:]]*(-{3,}|\*{3,}|_{3,})[[:space:]]*$/) {
        exit
      }
      print line
      next
    }
    # Detect the active-entry heading: a `status:` followed (after any non-letters, e.g. `**`)
    # by `active`. Match on the lowercased line so casing never matters.
    low ~ /status:[^a-z]*active/ {
      in_region = 1
      print line
      next
    }
  ' "$src"
}

# ns_has_shipped_default_marker <file-or-"-"> — return 0 (true) when the north-star document's
# ACTIVE-entry region still carries the shipped-default marker, matched WHITESPACE- and
# CASE-INSENSITIVELY. Return non-zero otherwise (including when there is no active heading).
#
# Robust match (both bugs the adversarial sweep found, fixed together):
#   - SCOPED to the active region (ns_active_region) → the marker's prose/doc mentions elsewhere
#     do NOT false-trip a correctly-replaced star.
#   - WHITESPACE/CASE-insensitive → an un-replaced placeholder whose marker is written as
#     `<!--fabrica-shipped-default-->`, padded, UPPERCASE, tab-separated, or reflow-split across
#     the heading + next line still MATCHES (a byte-exact `grep -F` on `<!-- … -->` would let all
#     those variants slip through and wrongly AUTHORIZE). We strip ALL whitespace from the region
#     and grep the token case-insensitively.
ns_has_shipped_default_marker() {
  local src="$1"
  local region
  # `|| true`: ns_active_region / the pipe may exit non-zero (e.g. no active heading, or grep's
  # no-match downstream); guard so a `set -e` caller never aborts here — the emptiness/grep result
  # is what decides. Strip ALL whitespace (spaces, tabs, and — via the region being one blob —
  # newlines) so any spacing/line-split variant of the marker collapses to a matchable run.
  region="$(ns_active_region "$src" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)"
  case "$region" in
    *"$NS_SHIPPED_DEFAULT_TOKEN"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ns_resolve <target_dir> — resolve the active north star for the repo containing <target_dir>.
# Prints ONE result line to stdout; the caller reads the first token:
#   FABRICA_SELF <path>   the control-plane root NORTH_STAR.md, target IS Fabrica (order 1)
#   LOCAL <path>          the target's own <toplevel>/.fabrica/north-star.md (order 2)
#   UNSET                 non-empty target, no star resolved (order 3) — caller decides
#   EMPTY                 target repo has no commits yet (benign; no star expected)
#   NOREPO                <target_dir> is not inside a git work tree (caller-specific handling)
# This is the LOCAL resolver (operates on a checkout on disk). doctor's remote-by-slug path
# is a separate concern handled in doctor.sh (it may not have the target checked out locally).
ns_resolve() {
  local target_dir="$1"
  local toplevel
  # `|| true` so a non-git <target_dir> yields empty and falls through to the NOREPO branch
  # below, rather than aborting a `set -e` caller here (belt-and-suspenders with the guard
  # inside ns_git_toplevel — protects this call site even if that helper's guard changes).
  toplevel="$(ns_git_toplevel "$target_dir" || true)"
  if [ -z "$toplevel" ]; then
    echo "NOREPO"
    return 0
  fi

  # Order 1 — Fabrica-self: root NORTH_STAR.md, ONLY on a PATH identity match (the target IS the
  # Fabrica control-plane repo — i.e. the clone that ships THIS very lib). Checked BEFORE the
  # target-local file so a stray/committed `.fabrica/north-star.md` accidentally sitting in the
  # control-plane checkout can NOT shadow Fabrica's own root star (that file would otherwise win
  # the LOCAL branch and mis-steer Fabrica-self).
  #
  # PATH identity only (NO slug): the target's git top-level equals Fabrica's own root (both
  # `pwd -P`-canonical — ns_git_toplevel and ns_fabrica_root — so this is a like-for-like compare,
  # immune to symlink/`/var`→`/private/var` skew). This is gh-free, so Fabrica-self still resolves
  # OFFLINE / when gh is unavailable. The old slug fallback (target slug == Fabrica slug) is
  # REMOVED: the slug derives from the git REMOTE URL, which any clone owner can set, so it let a
  # hostile target pointing origin at Fabrica's slug authorize against Fabrica's root star and
  # bypass the placeholder-FAIL. Only the path (the target IS this shipped copy) is trustworthy.
  local fabrica_root
  # `|| true`: ns_fabrica_root degrades to empty (rc may be non-zero); guard so this `set -e` call
  # site can never abort before the `-n` emptiness check decides.
  fabrica_root="$(ns_fabrica_root || true)"
  if [ -n "$fabrica_root" ] && [ "$toplevel" = "$fabrica_root" ]; then
    local root_star
    root_star="$fabrica_root/NORTH_STAR.md"
    if [ -f "$root_star" ]; then
      echo "FABRICA_SELF $root_star"
      return 0
    fi
  fi

  # Order 2 — target-local .fabrica/north-star.md at the git top-level (reached only when the
  # target is NOT Fabrica-self, so a real external target's own star is what wins here).
  local local_star="$toplevel/.fabrica/north-star.md"
  if [ -f "$local_star" ]; then
    echo "LOCAL $local_star"
    return 0
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
