#!/usr/bin/env bash
# north-star.sh — the shared per-target north-star RESOLVER (sourced, not executed).
#
# Both scripts/manager-review.sh and scripts/doctor.sh need to answer the same question:
# "what is the active north star for the repo this run operates on?" Historically each
# hardcoded the control-plane root NORTH_STAR.md — which mis-reads the control plane's own star
# when a run targets an EXTERNAL repo, or forces a target's star into the control plane's own
# source (the MapleFolio collision, 2026-07-01). This helper resolves the star FOR THE TARGET,
# so each target owns its own steering. It is `source`d by the callers (no shebang execution) —
# the `#!/usr/bin/env bash` line is only so shellcheck picks the right dialect.
#
# Resolution order (see issue #97, hardened in #98a):
#   1. ystack-self:    the control-plane root NORTH_STAR.md — CLASSIFIED (as the SOURCE) whenever
#      the resolved repo IS the ystack control-plane repo itself (its main checkout OR any linked
#      worktree of it), decided by a SHARED-GIT-COMMON-DIR identity check (the target's git
#      common-dir equals THIS lib's own control-plane common-dir; the top-level PATH equality is
#      kept as one accepted case), never a slug. This classification is IDENTITY-ONLY (git-structural,
#      not slug) and UNCONDITIONAL — it does NOT depend on whether NORTH_STAR.md
#      exists (round-3 [P2]): CLASSIFICATION (which source applies) is the resolver's job; whether
#      that source carries a real committed star (AUTHORIZATION) is the gate's job. Checked FIRST,
#      and returned unconditionally on a path match, so a stray per-target star file
#      accidentally sitting in the control-plane checkout can NEVER shadow ystack-self (the gate
#      then FAILs cleanly if the root star is not committed — it does NOT fall back to the
#      per-target file).
#   2. Target-local:   <target-toplevel>/.ystack/north-star.md, falling back to the LEGACY
#      <target-toplevel>/.fabrica/north-star.md for legacy targets that have not renamed yet (the new
#      path wins when both exist). target-toplevel is the target repo's GIT TOP-LEVEL
#      (`git -C <dir> rev-parse --show-toplevel`), NOT literal $PWD — so a run from ANY
#      subdirectory of the target clone resolves the top-level file.
#   3. Unset:          neither resolves and the target is NON-EMPTY -> UNSET; the caller
#      decides how to react (manager-review FAILs; doctor WARNs). Never silently read another
#      repo's star.
#
# SECURITY (#98a): the ystack-self identity is GIT-STRUCTURAL (shared common-dir / top-level path),
# never a slug. An earlier slug-based fallback (target slug == the control plane's slug ->
# YSTACK_SELF) rested on the git REMOTE URL, which any clone owner can set — so a hostile target
# pointing origin at the control plane's slug would be authorized against its root star, bypassing
# its own star AND the placeholder-FAIL. The remote URL is attacker-settable and thus NOT a
# trustworthy identity signal; only git-structural identity (the target shares the very repository
# that ships this lib — its main checkout or a linked worktree of it) is trustworthy. The slug
# fallback is removed.
#
# The functions here are pure resolution/derivation — they print a result and never post
# comments, edit files, or mutate any checkout. Callers own the side effects.

# __ns_self — this file's OWN path, absolutized ONCE at source time. `${BASH_SOURCE[0]}` reflects
# HOW the caller sourced us: a relative `. scripts/lib/north-star.sh` leaves it relative, so a lazy
# `dirname`-based root derivation inside ns_ystack_root would later resolve against the CALLER's
# cwd (which may have cd'd into a target repo) — mis-locating the control plane. Capturing and
# absolutizing here, at source time (cwd is still the caller's source-time cwd, which is where the
# relative path is valid), pins the self-path regardless of any later cd. ns_ystack_root then uses
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
# <dir>, or nothing. This is the IDENTITY used for doctor's cwd/slug match — a slug, not a
# path, so two different clones of the same repo compare equal and a clone whose path is a
# prefix of another's cannot false-match. Returns non-zero (and prints nothing) when <dir> is
# not a gh-recognized repo.
#
# `env -u GH_REPO`: `gh repo view` honors an exported GH_REPO OVER the repo at the cwd, so a
# set GH_REPO would make this print the ENV repo's slug instead of the repo at <dir> — which
# would let doctor.sh's cwd/slug match falsely pass (spoofing an external checkout into looking
# like the target and reading the wrong local per-target star). Clearing GH_REPO for this one
# invocation forces the slug to reflect the actual repo at <dir>, always.
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

# ns_ystack_slug — print the ystack control plane's OWN repo slug (the repo that ships THIS
# resolver), or nothing. Derived from the resolver file's own location (this sourced file
# lives at <control-plane>/scripts/lib/north-star.sh), following symlinks, so it identifies
# the control plane regardless of which target's cwd the caller runs from.
#
# NOTE (#98a): this is NO LONGER used for the ystack-self IDENTITY decision in ns_resolve —
# that is now PATH-only, because a slug (from the git remote URL) is attacker-settable and thus
# untrustworthy for authorization. Retained as a general-purpose derivation helper for callers
# that legitimately need the control plane's own slug for a NON-authorization comparison
# (e.g. diagnostics).
ns_ystack_slug() {
  # `|| true` on the inner substitution: ns_ystack_root ends in `( cd … && pwd -P )`, which
  # exits non-zero if the derived root is unreachable — under `set -e` that would abort the
  # caller before ns_repo_slug (itself guarded) can degrade to empty. Guarding here keeps the
  # whole helper degrade-to-empty.
  local root
  root="$(ns_ystack_root || true)"
  ns_repo_slug "$root"
}

# ns_ystack_root — print the ystack control-plane repo root, derived from THIS file's own
# location (following symlinks: <root>/scripts/lib/north-star.sh -> dirname x3). BASH_SOURCE[0]
# is the path of the sourced file (not $0, which is the CALLER's path) — that is what lets a
# sourced helper locate the control plane independent of the caller's cwd or invocation.
#
# GIT-CANONICAL casing (#98a round-2 regression fix): the ystack-self IDENTITY compare in
# ns_resolve (and the same guard in setup-target-repo.sh) tests `toplevel == ystack_root`, where
# `toplevel` comes from `git rev-parse --show-toplevel` (git-canonical casing) while this root is
# a filesystem `pwd -P` (case-PRESERVING). On a case-insensitive filesystem a case-variant path
# (`/Users/x/YStack` vs git's stored `/Users/x/ystack`) makes the two operands differ ONLY in
# case, so the identity compare falsely FAILs → the control plane's own debate FAILs and setup
# would pollute the control plane. So, once we have the physical root, canonicalize it THROUGH
# GIT too (`git -C <root> rev-parse --show-toplevel`) so both sides of the compare are produced
# the same way; fall back to the physical `pwd -P` value when the root is not a git work tree
# (e.g. a tarball restore before `git init`), where a bare-path compare is the best we can do.
ns_ystack_root() {
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
  local phys_root
  phys_root="$( cd "$(dirname "$self")/../.." 2>/dev/null && pwd -P )" || true
  if [ -z "$phys_root" ]; then
    return 0
  fi
  # Prefer git's canonical top-level so this operand matches ns_git_toplevel's casing exactly
  # (the identity compare); fall back to the physical root when not a work tree. `|| true` /
  # 2>/dev/null keep this degrade-to-empty under a `set -e` caller.
  local git_root
  git_root="$( git -C "$phys_root" rev-parse --show-toplevel 2>/dev/null || true )"
  if [ -n "$git_root" ]; then
    printf '%s\n' "$git_root"
  else
    printf '%s\n' "$phys_root"
  fi
}

# ns_git_common_dir <dir> — print the git COMMON directory for the repo containing <dir>,
# canonicalized to an ABSOLUTE physical path, or nothing. This is the identity signal that ties
# a linked WORKTREE to its parent repo: `git rev-parse --git-common-dir` returns the SHARED
# `.git` of the main checkout for every linked worktree of the same repo (whereas
# `--git-dir` differs per worktree, and `--show-toplevel` differs per worktree). So comparing
# canonicalized common-dirs answers "are these the SAME repository?" across the main checkout and
# all its linked worktrees, which a bare top-level PATH compare cannot (a worktree's top-level is
# its own path, not the main checkout's).
#
# CANONICALIZATION: `--git-common-dir` may print a RELATIVE path (`.git` / `../.git`) depending on
# the cwd it is asked from, so we resolve it to an absolute physical path by `cd`ing into <dir>
# first, then into the reported common dir, then `pwd -P` — this also collapses any
# `/var`→`/private/var` symlink skew, so two spellings of the same dir compare equal. This mirrors
# the nested-repo guard in manager-review.sh / setup-target-repo.sh (round-1 FIX F), which uses the
# same `cd … && cd "$(git rev-parse --git-common-dir)" && pwd -P` shape. Every step is guarded
# (`2>/dev/null` / `|| true`) so a non-work-tree <dir> degrades to empty output (rc 0) instead of
# aborting a `set -e` caller.
ns_git_common_dir() {
  local dir="$1"
  [ -n "$dir" ] || return 0
  ( cd "$dir" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P ) || true
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

# ns_committed_is_regular_file <repo_dir> <commit-ish> <relpath> — return 0 (true) when the tree
# entry at <relpath> in <commit-ish> is a REGULAR FILE blob (git mode 100644 or 100755), non-zero
# for a SYMLINK (mode 120000), a gitlink/tree, or an absent path. Shared by the gate and doctor
# (round-2 FIX 4) so they agree on what counts as a real committed north star.
#
# WHY (#98a, symlink attack): a committed north star stored as a SYMLINK makes `git show
# <commit>:<relpath>` return the link's TARGET-PATH STRING, not file content — so the marker check
# would run against a meaningless path string and could AUTHORIZE off it, and the gate's goal would
# diverge from the real file Codex reviews in the worktree. Callers assert this BEFORE the marker
# check and FAIL a symlink north star ("must be a regular file, not a symlink"). `git ls-tree` prints
# `<mode> <type> <oid>\t<path>`; we read the first field. `2>/dev/null` + explicit rc keep it
# degrade-to-non-zero under a `set -e` caller (an absent path prints nothing → non-zero).
#
# TOP-LEVEL pathspec resolution (round-3 FIX 1): <relpath> is ROOT-relative
# (`.ystack/north-star.md`, the legacy `.fabrica/north-star.md`, or `NORTH_STAR.md`), but
# `git -C "$dir" ls-tree "$commit" -- "$relpath"` interprets the pathspec relative to `-C "$dir"`.
# When a caller passes `$PWD` and the gate is invoked from a SUBDIRECTORY of the target
# (documented as supported — the companion `git show <commit>:<relpath>` reads root relative
# regardless of cwd), the ls-tree pathspec then points at `<subdir>/<relpath>` → the mode lookup
# returns EMPTY for a valid regular committed file → this helper falsely reports "not a regular
# file" and the round-2 symlink guard wrongly REJECTS the run. So resolve <dir> to its git
# TOP-LEVEL first and run ls-tree there, making the root-relative pathspec correct from ANY
# subdirectory. `|| true` on the rev-parse keeps this degrade-to-non-zero under a `set -e` caller
# when <dir> is not a work tree; an empty top (not a work tree) short-circuits to rc 1 (we must
# NOT `git -C "" ls-tree`, which git treats as a no-op that stays in the CURRENT dir — possibly a
# DIFFERENT repo).
ns_committed_is_regular_file() {
  local dir="$1" commit="$2" relpath="$3"
  local top
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$top" ] || return 1
  local mode
  mode="$(git -C "$top" ls-tree "$commit" -- "$relpath" 2>/dev/null | awk '{print $1; exit}')"
  case "$mode" in
    100644|100755) return 0 ;;
    *) return 1 ;;
  esac
}

# The stable shipped-default marker (an HTML comment) that rides on the ACTIVE heading of a
# still-unreplaced shipped template. Both the gate (manager-review.sh) and doctor.sh (h) key
# their placeholder detection off THIS token, via ns_has_shipped_default_marker below, so the
# two never disagree on what counts as an un-replaced placeholder.
NS_SHIPPED_DEFAULT_TOKEN='ystack-shipped-default'
# The LEGACY marker, from before the product rename. Targets that adopted the old template
# still carry it, so the marker check accepts BOTH tokens — an old un-replaced placeholder must
# keep FAILing the gate, never slip through because the token name changed.
NS_SHIPPED_DEFAULT_TOKEN_LEGACY='fabrica-shipped-default'

# ns_active_region <file-or-"-"> — print the ACTIVE-entry region of a north-star document read
# from a file path (or, with `-`, from stdin): the first HEADING line carrying `status: active`
# through the lines up to (but not including) the NEXT heading (`#`…) or horizontal rule
# (`---`/`***`/`___`). Prints nothing when there is no `status: active` heading.
#
# Scoping to the active-entry region (not the whole file) is what stops the marker's mentions in
# the template's explanatory PROSE (and in NORTH_STAR.md's own docs) from tripping the check —
# those live OUTSIDE any active heading, so a correctly-replaced star (marker cleared from the
# active heading, still named in prose) is NOT flagged. Including the continuation lines up to
# the next heading/rule (not just the single heading line) catches a marker that a markdown
# reflow split onto the line just below the heading.
#
# HEADING-ANCHORED start (round-3 FIX 2): the region must START on a Markdown HEADING line
# (`^#{1,6}[[:space:]]`) that ALSO carries the `status: … active` marker — NOT any line mentioning
# `status: active`. If a north-star file has PROSE or front-matter that mentions `status: active`
# BEFORE the real active heading, a start-on-any-line scan would open the region on that prose line
# and END it at the very next heading — so the shipped-default marker on the ACTUAL (placeholder)
# active heading would fall OUTSIDE the scanned region and never be seen → the gate would proceed
# against an unreplaced template (placeholder bypass). Anchoring the start to a heading line makes
# the region begin on the real active-entry heading. The shipped `NORTH_STAR.md` /
# `.ystack/north-star.md` active entries ARE headings (e.g. `### B — "…" · status: **active** · …`),
# so this matches the real format.
ns_active_region() {
  local src="$1"
  # awk over the document: once we hit a `status: active` HEADING line (case-insensitive, the
  # `active` possibly wrapped in markdown emphasis `*`/`_`), print from there until the next
  # heading line or horizontal rule. `IGNORECASE=1` is a gawk-ism; be portable by lowercasing in
  # a match on tolower(). Recognize the active heading the SAME way doctor historically did
  # (`status:` then optional non-alpha then `active`), so scoping is consistent — but ONLY on a
  # heading line, so a prose/front-matter mention of `status: active` before the real heading
  # cannot open the region early and hide the marker on the actual placeholder heading.
  #
  # DRAIN-TO-EOF, never `exit` early (round-3 [P1] SIGPIPE fix): when the source is `-` (stdin),
  # callers pipe the content in as `printf '%s' "$star" | ns_active_region - | …` under the
  # caller's `set -o pipefail`. An early `exit` (as soon as the region ends at the NEXT heading/
  # rule) closes awk's stdin while the upstream `printf` still has bytes to write — for a large
  # committed star (placeholder marker in the active entry + tens of KB of body after the next
  # section, enough to fill the pipe buffer) `printf` then dies with SIGPIPE (141). Under
  # `pipefail` that 141 becomes the WHOLE pipeline's status, so `if ns_has_shipped_default_marker`
  # reads FALSE even though the marker matched — a placeholder-FAIL BYPASS (gate proceeds, doctor
  # misses the WARN). So we NEVER `exit`: we track the region with flags and keep READING every
  # line to EOF, merely stopping OUTPUT once the region ends. The emitted bytes are byte-identical
  # to the old `exit` behaviour (same first active region, nothing after), so the marker verdict is
  # unchanged for every case — only the stdin-draining differs, which is what closes the bypass.
  # A `done` latch keeps this to the FIRST active region (a later `status: active` heading cannot
  # re-open output), exactly as the old single-`exit` did.
  awk '
    {
      line = $0
      low = tolower(line)
    }
    in_region {
      # A new heading (line starting with #) or a horizontal rule ENDS the active region. Do NOT
      # `exit` (that SIGPIPEs the upstream printf under pipefail) — latch the region closed and
      # keep reading the remaining lines to EOF, emitting nothing further.
      if (line ~ /^[[:space:]]*#/ || low ~ /^[[:space:]]*(-{3,}|\*{3,}|_{3,})[[:space:]]*$/) {
        in_region = 0
        done = 1
        next
      }
      print line
      next
    }
    # Detect the active-entry HEADING: a Markdown heading line (`#`…`###### ` with a following
    # space) whose text has a `status:` followed (after any non-letters, e.g. `**`) by `active`.
    # Both conditions are tested on the lowercased line so casing never matters. Requiring the
    # heading form is the FIX — a bare prose line mentioning `status: active` no longer starts the
    # region, so the marker on the true active heading is always scanned. The `!done` guard keeps
    # us to the FIRST active region only (a subsequent active heading past the region does not
    # re-open output), matching the old single-region-then-`exit` behaviour.
    !done && low ~ /^[[:space:]]*#{1,6}[[:space:]]/ && low ~ /status:[^a-z]*active/ {
      in_region = 1
      print line
      next
    }
  ' "$src"
}

# ns_has_shipped_default_marker <file-or-"-"> — return 0 (true) when the north-star document's
# ACTIVE-entry region still carries the shipped-default marker AS AN HTML COMMENT, matched
# WHITESPACE- and CASE-INSENSITIVELY. Return non-zero otherwise (including when there is no active
# heading). BOTH the canonical token (ystack-shipped-default) and the legacy one
# (the legacy fabrica-shipped-default) count as the marker — see the token definitions above.
#
# Robust match — three bugs the adversarial sweeps found, fixed together:
#   - SCOPED to the active region (ns_active_region) → the marker's prose/doc mentions elsewhere in
#     the file do NOT false-trip a correctly-replaced star.
#   - WHITESPACE/CASE-insensitive → an un-replaced placeholder whose marker is written as
#     `<!--ystack-shipped-default-->`, padded, UPPERCASE, tab-separated, or reflow-split across the
#     heading + next line still MATCHES (a byte-exact `grep -F` on `<!-- … -->` would let all those
#     variants slip through and wrongly AUTHORIZE).
#   - COMMENT-FORM, not a bare token (round-2 FIX 2): match the `<!-- … <token> … -->`
#     HTML-COMMENT delimiters, NOT a bare token ANYWHERE in the active region. The round-1 bare-token
#     match FALSE-FAILed a valid star when the operator removed the real `<!-- … -->` comment but the
#     active region still mentioned the token in PROSE (e.g. "remove the
#     ystack-shipped-default marker") — a delimiter-free prose mention must NOT count as the marker.
#
# Implementation: strip ALL whitespace (spaces/tabs, and — the region being one blob — newlines) and
# lowercase, so every spacing/line-split/casing variant of the comment collapses to a matchable run
# with `<!--`/`-->` adjacent to the token; then require the COMMENT FORM via an ERE. The `[^>]*`
# before the token and `[^<]*` after it are boundary guards: `[^>]*` cannot cross a preceding `-->`
# (it contains `>`) and `[^<]*` cannot cross into a following `<!--` (it contains `<`), so the token
# must sit INSIDE one `<!-- … -->` comment — a prose token between/outside comments never matches,
# while a comment carrying extra interior text (e.g. `<!-- ystack-shipped-default: keep -->`) still
# does. The alternation accepts either token (canonical or legacy); both are fixed literals whose
# only non-alphanumeric character is `-`, which is ERE-safe here.
ns_has_shipped_default_marker() {
  local src="$1"
  local region
  # `|| true`: ns_active_region / the pipe may exit non-zero (e.g. no active heading); guard so a
  # `set -e` caller never aborts here — the grep result below is what decides.
  region="$(ns_active_region "$src" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' || true)"
  # Match the collapsed COMMENT form: <!-- (up to, no `>`) TOKEN (up to, no `<`) -->. `grep -Eq`
  # returns non-zero on no-match.
  printf '%s' "$region" | grep -Eq "<!--[^>]*(${NS_SHIPPED_DEFAULT_TOKEN}|${NS_SHIPPED_DEFAULT_TOKEN_LEGACY})[^<]*-->"
}

# ns_resolve <target_dir> — resolve the active north star for the repo containing <target_dir>.
# Prints ONE result line to stdout; the caller reads the first token:
#   YSTACK_SELF <path>    the control-plane root NORTH_STAR.md, target IS the control plane (order 1)
#   LOCAL <path>          the target's own <toplevel>/.ystack/north-star.md, or the legacy
#                         <toplevel>/.fabrica/north-star.md when only that legacy file exists (order 2)
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

  # Order 1 — ystack-self: root NORTH_STAR.md, ONLY on a trustworthy identity match (the target IS
  # the ystack control-plane repo — i.e. the clone that ships THIS very lib, OR one of its linked
  # worktrees). Checked BEFORE the target-local file so a stray per-target star file
  # accidentally sitting in the control-plane checkout can NOT shadow the control plane's own
  # root star (that file would otherwise win the LOCAL branch and mis-steer ystack-self).
  #
  # SHARED-GIT-COMMON-DIR identity (NO slug): the target is ystack-self iff its git COMMON-DIR
  # equals the control plane's own git common-dir. This is the SAME signal round-1's nested-repo
  # guard (FIX F) uses, and it is what a bare top-level PATH compare could not do: yshifu operates
  # from a LINKED WORKTREE (`.claude/worktrees/*`) whose `git rev-parse --show-toplevel` is the
  # WORKTREE path, not the main checkout, so `toplevel == ystack_root` FALSELY FAILed and the
  # control plane's own worktree was misclassified as an external target (skipping the root
  # NORTH_STAR.md and instead resolving off a per-target star file in the worktree, mis-steering
  # ystack-self). A linked worktree SHARES its parent repo's common-dir, so the
  # common-dir compare makes the main checkout AND all its linked worktrees resolve as ystack-self,
  # while a genuinely SEPARATE repo (different common-dir) does not. The existing top-level PATH
  # equality is KEPT as one accepted case (belt-and-suspenders: a match either way is self) — but
  # the common-dir compare is the primary signal.
  #
  # BOTH operands are canonicalized to absolute physical paths (ns_git_common_dir `cd`s in and
  # `pwd -P`s), immune to a relative `--git-common-dir` and to `/var`→`/private/var` symlink skew.
  # This is gh-free, so ystack-self still resolves OFFLINE / when gh is unavailable. The old slug
  # fallback (target slug == the control plane's slug) is REMOVED: the slug derives from the git
  # REMOTE URL, which any clone owner can set, so it let a hostile target pointing origin at the
  # control plane's slug authorize against its root star and bypass the placeholder-FAIL. Only
  # git-structural identity (the target shares this shipped copy's repository) is trustworthy.
  local ystack_root
  # `|| true`: ns_ystack_root degrades to empty (rc may be non-zero); guard so this `set -e` call
  # site can never abort before the `-n` emptiness check decides.
  ystack_root="$(ns_ystack_root || true)"
  # Common-dir identity: does the target share the SAME repository as the ystack control plane?
  # Both canonicalized to absolute physical paths so a linked worktree resolves equal to its main
  # checkout. `|| true` keeps each derivation from aborting this `set -e` call site; the emptiness
  # guards below ensure an unresolved common-dir never false-matches.
  local tgt_common cp_common is_self=0
  tgt_common="$(ns_git_common_dir "$toplevel" || true)"
  if [ -n "$ystack_root" ]; then
    cp_common="$(ns_git_common_dir "$ystack_root" || true)"
    if [ -n "$tgt_common" ] && [ -n "$cp_common" ] && [ "$tgt_common" = "$cp_common" ]; then
      is_self=1
    fi
    # Keep the existing top-level PATH equality as one accepted case (a match either way is self).
    if [ "$toplevel" = "$ystack_root" ]; then
      is_self=1
    fi
  fi
  if [ "$is_self" -eq 1 ]; then
    # CLASSIFICATION is IDENTITY-ONLY, UNCONDITIONAL (round-3, [P2]). Classification (which SOURCE
    # applies) and AUTHORIZATION (whether that source has a real committed star) are SEPARATE
    # concerns: classification belongs to the resolver, authorization belongs to the gate. Once the
    # identity matches (this checkout — or a linked worktree of it — IS the ystack control plane),
    # the resolved SOURCE is the root NORTH_STAR.md — FULL STOP. We do NOT gate this on whether
    # NORTH_STAR.md exists (committed OR working-tree): round-2 keyed the branch on
    # `git cat-file -e HEAD:NORTH_STAR.md`, so a control-plane cwd whose root star was NOT
    # committed would FALL THROUGH to the LOCAL branch and a stray committed per-target star there
    # would be authorized as if it were the control plane's star — contradicting the precedence
    # rule (path identity → YSTACK_SELF; the per-target star must never shadow ystack-self).
    # Returning YSTACK_SELF unconditionally here makes the per-target star file incapable of ever
    # shadowing ystack-self. The AUTHORIZATION that a real committed root star exists is the
    # gate's job: manager-review.sh's YSTACK_SELF branch reads `git show HEAD:NORTH_STAR.md` and
    # FAILs cleanly ("NORTH_STAR.md is not committed at HEAD") if the root is not committed — a
    # missing committed root FAILs, it does NOT fall back to the per-target star. doctor.sh
    # likewise diagnoses the uncommitted-root YSTACK_SELF case as a WARN (it never gated the kind
    # on committed existence). So a worktree-deleted-but-committed root still authorizes
    # (path→YSTACK_SELF here, `git show HEAD:` succeeds at the gate).
    echo "YSTACK_SELF $ystack_root/NORTH_STAR.md"
    return 0
  fi

  # Order 2 — target-local star at the git top-level (reached only when the target is NOT
  # ystack-self, so a real external target's own star is what wins here). The canonical
  # `.ystack/north-star.md` is tried first; a target still on the legacy layout keeps working via
  # the legacy `.fabrica/north-star.md` fallback. When BOTH exist, the canonical path wins.
  local local_star="$toplevel/.ystack/north-star.md"
  if [ -f "$local_star" ]; then
    echo "LOCAL $local_star"
    return 0
  fi
  local legacy_star="$toplevel/.fabrica/north-star.md"
  if [ -f "$legacy_star" ]; then
    echo "LOCAL $legacy_star"
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
