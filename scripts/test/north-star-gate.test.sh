#!/usr/bin/env bash
set -euo pipefail

# north-star-gate.test.sh — integration asserts for the ATOMIC per-target north-star flip
# (issue #98a): the manager-review.sh consensus GATE and doctor.sh check (h) both read the
# TARGET's north star, and the gate reads it COMMITTED (never an uncommitted working-tree edit).
# (Seeding a target's .fabrica/north-star.md is adoption scope — deferred to #98b — so this
# suite no longer drives setup-target-repo.sh.)
#
# These complement scripts/test/north-star-resolver.test.sh, which asserts the resolver lib in
# isolation. This suite asserts the CONSUMERS now wired to that resolver by #98a — the part
# #99 deliberately left dormant.
#
# The gate (manager-review.sh) requires `gh` and `codex`, and materializes a detached worktree
# with REAL git. So we run the REAL script end-to-end against throwaway REAL git repos with
# `gh` and `codex` STUBBED on PATH — testing the actual pinned committed-read code path, not a
# reimplementation of it. The safety-critical assertions (from the manager-debate GAP) are the
# COMMITTED-vs-uncommitted pair, in BOTH directions:
#   - a worktree-only .fabrica/north-star.md (not committed) does NOT authorize (gate FAILs); and
#   - a HEAD-committed star STILL authorizes even if the working-tree copy is deleted or modified.
# Plus: LOCAL committed star → debates; LOCAL + shipped-default marker → FAIL; UNSET → FAIL;
# doctor UNSET → WARN and doctor LOCAL committed → pass; and the SOURCE-IDENTITY assert
# (approval source == gate source), pinned by inspecting the shipped files since operator
# approval is not machine-readable.
#
# OFFLINE and hermetic: no network/gh/codex — both are faked on PATH. Every case builds a
# throwaway git repo in a temp dir. Run: scripts/test/north-star-gate.test.sh

test_dir="$(cd "$(dirname "$0")" && pwd -P)"
repo_root="$(cd "$test_dir/../.." && pwd -P)"
manager_review="$repo_root/scripts/manager-review.sh"
doctor="$repo_root/scripts/doctor.sh"
setup_script="$repo_root/scripts/setup-target-repo.sh"
faber_template="$repo_root/templates/faber-command.md"
persona="$repo_root/manager/CLAUDE.md"
ns_template="$repo_root/templates/.fabrica/north-star.md"
ghr_lib="$repo_root/scripts/lib/gh-remote.sh"   # #102: the shared gh-bound remote-identity helper
for f in "$manager_review" "$doctor" "$setup_script" "$faber_template" "$persona" "$ns_template" "$ghr_lib"; do
  if [ ! -f "$f" ]; then echo "FAIL: missing $f" >&2; exit 1; fi
done

# Give git a per-process identity (the runner has no global user); scoped via env, not config.
export GIT_AUTHOR_NAME="test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="test" GIT_COMMITTER_EMAIL="test@example.com"

tmproot="$(mktemp -d)"
cleanup() { rm -rf "$tmproot"; }
trap cleanup EXIT

passed=0
failed=0
assert_eq() {
  if [ "$2" = "$3" ]; then
    passed=$((passed + 1)); echo "pass: $1"
  else
    failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected: [$2]"; echo "      actual:   [$3]"
  fi
}
assert_contains() {
  # assert_contains <label> <needle> <haystack>
  case "$3" in
    *"$2"*) passed=$((passed + 1)); echo "pass: $1" ;;
    *) failed=$((failed + 1)); echo "FAIL: $1"; echo "      expected to contain: [$2]"; echo "      actual: [$3]" ;;
  esac
}

# --- fake gh / codex on PATH -------------------------------------------------------
# Fake gh: the identity that the #102 gh-bound anchor pattern needs.
#   - `repo view [<repo>] --json nameWithOwner` → a slug keyed off the CWD's git top-level
#     basename (`someone/<basename>`), so a throwaway target repo and the real Fabrica clone get
#     DIFFERENT slugs (the resolver's Fabrica-self check must not false-match).
#   - `repo view [<repo>] --json url` → the matching web URL `https://github.com/someone/<basename>`
#     (#102). ghr_gh_repo_id reads the HOST off this url and re-appends the slug, so the gate's
#     canonical identity is `github.com/someone/<basename>` — which the remote-backed target's
#     configured `origin` url (`https://github.com/someone/<basename>.git`) normalizes to, so
#     ghr_select_remote matches `origin`. (The FETCH goes to the bare repo via an insteadOf
#     transport rewrite; identity matches on the CONFIGURED url — see setup_remote below.)
#   - `FAKE_GH_NO_REPO=1` in the env → `repo view` fails (empty), simulating a genuinely local /
#     no-gh-remote target so manager-review takes its VISIBLE local-HEAD fallback (and doctor its
#     visible fallback). Used by the greenfield/local-only case.
#   - `issue view` prints deterministic scalars for gh's -q extraction; `issue comment` is a no-op.
fakebin="$tmproot/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/gh" <<'GH'
#!/usr/bin/env bash
# Minimal gh stub for the manager-review gate test. Only the calls the scripts make.
cmd="${1:-}"; sub="${2:-}"
case "$cmd $sub" in
  "repo view")
    # Simulate a genuinely local / no-gh-remote target when asked.
    if [ "${FAKE_GH_NO_REPO:-0}" = "1" ]; then
      exit 1
    fi
    # Derive the repo NAME from the CONFIGURED origin url (`https://github.com/someone/<name>.git`)
    # when present — this is shared across a repo's linked worktrees (common config), so a run from
    # a linked worktree resolves the SAME identity as the main checkout (a real gh does too). Fall
    # back to the git top-level basename only when there is no origin (bare-init throwaway repos).
    origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
    case "$origin_url" in
      https://github.com/someone/*)
        name="${origin_url#https://github.com/someone/}"; name="${name%.git}" ;;
      *)
        top="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; name="$(basename "$top")" ;;
    esac
    # #102 round-2 (FIX 2): `repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`.
    # A REAL gh reports the repo's CURRENT server-side default branch. Hermetically, that server is
    # the local bare repo the origin's insteadOf transport maps to, so we ask it AUTHORITATIVELY via
    # `git ls-remote --symref origin HEAD` (the operator's insteadOf makes this hit the bare repo) —
    # this reflects the CURRENT remote default even after a repoint, and is IMMUNE to the local
    # `refs/remotes/origin/HEAD` symref (a spoofed/stale local symref does not change it). Fall back
    # to the local symbolic HEAD only when there is no reachable origin. Emitted `-q` scalar (bare
    # name), matching `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
    if printf '%s\n' "$@" | grep -q 'defaultBranchRef'; then
      # FAKE_GH_NO_DEFAULT=1: simulate gh being unable to resolve the default branch (empty output),
      # so the gh-bound gate FAILs closed (round-2 FIX 2 — no local-symref authorization fallback).
      if [ "${FAKE_GH_NO_DEFAULT:-0}" = "1" ]; then
        exit 0
      fi
      symref="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {print $2; exit}' || true)"
      if [ -n "$symref" ]; then
        echo "${symref#refs/heads/}"
      else
        # No reachable origin: name the checkout's current branch (bare-init throwaway repos).
        git symbolic-ref --quiet --short HEAD 2>/dev/null || true
      fi
      exit 0
    fi
    # Return whichever field was requested (nameWithOwner slug, or the web url for #102).
    if printf '%s\n' "$@" | grep -q 'url'; then
      echo "https://github.com/someone/${name}"
    else
      echo "someone/${name}"
    fi ;;
  "issue view")
    if printf '%s\n' "$@" | grep -q 'title'; then
      echo "A proactive proposal"
    elif printf '%s\n' "$@" | grep -q 'comments'; then
      echo "(no comments yet)"
    else
      echo "issue body text"
    fi ;;
  "issue comment")
    exit 0 ;;
  *)
    exit 0 ;;
esac
GH
chmod +x "$fakebin/gh"

# Fake codex. Two invocation shapes must be honored WITHOUT crossing wires:
#   - The real gate call `codex exec -C <wt> -c ... -o <tmp> [-m model] -` pipes the prompt
#     over stdin (the trailing `-`). It writes a verdict into the -o file and exits 0. Here
#     we MUST drain stdin so the upstream printf doesn't SIGPIPE.
#   - doctor.sh probes `codex login --help` / `codex login status` (and any version probe)
#     WITHOUT piping stdin. Reading stdin there blocks a local interactive run on terminal
#     input. So we only drain stdin for the `codex exec … -` path; other subcommands return
#     the canned behavior without ever touching stdin.
cat >"$fakebin/codex" <<'CODEX'
#!/usr/bin/env bash
# Detect the gate call: `exec` subcommand whose trailing positional is `-` (stdin prompt).
last=""
for a in "$@"; do last="$a"; done
if [ "$1" = "exec" ] && [ "$last" = "-" ]; then
  out=""
  prev=""
  for a in "$@"; do
    if [ "$prev" = "-o" ]; then out="$a"; fi
    prev="$a"
  done
  # Drain stdin (the prompt) so the upstream printf doesn't SIGPIPE.
  cat >/dev/null 2>&1 || true
  if [ -n "$out" ]; then
    printf 'VERDICT: PROCEED\nREASONING: stub.\nGAP FABER MISSED: none.\n' >"$out"
  fi
  exit 0
fi
# Non-exec probes (doctor's `login --help` / `login status`, any version check): exit 0 WITHOUT
# reading stdin so a local interactive run never blocks waiting on the terminal. This matches
# the original stub's observable behavior for these calls (no stdout, exit 0): `login --help`
# yields no `status` word, so doctor (d) reports the read-only "sign-in not verifiable" pass.
exit 0
CODEX
chmod +x "$fakebin/codex"

# run_gate <repo_dir> — run the REAL manager-review.sh from inside <repo_dir> with the fakes on
# PATH; echo "<rc>|<combined-output>". codex/gh are faked; git is real. issue# is 1 (validated
# as a bare integer by the script). FAKE_GH_NO_REPO (if exported by a caller) passes through.
#
# FABRICA_ALLOW_LOCAL_MIRROR (#102 round-2 FIX 1): the hermetic harness rewrites each target's https
# identity url to a local `file://` bare for offline transport, so the EFFECTIVE fetch URL is a local
# mirror (unprovable GitHub identity). The round-2 effective-identity gate FAILs closed on that
# UNLESS the operator opts into a local mirror. So the standard runner exports the opt-in — this IS
# the deliberate-local-mirror case the flag exists for. A caller can DISABLE it (to exercise the
# fail-closed path) by exporting FABRICA_ALLOW_LOCAL_MIRROR=0 before calling; we honor that override.
run_gate() {
  local repo_dir="$1" rc out allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$manager_review" 1 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- remote-backed throwaway targets (#102) ----------------------------------------
# The #102 gate anchors to the gh-BOUND remote's DEFAULT branch, FETCHED FRESH. So a throwaway
# target must have a matching configured remote AND a fetchable default branch. We wire that
# HERMETICALLY (no network):
#   - a bare "remote" repo lives under $tmproot/remotes/<name>.git;
#   - the working repo's `origin` is CONFIGURED with the clean identity url
#     `https://github.com/someone/<name>.git` (what ghr_select_remote matches against — it reads
#     the CONFIGURED url, ignoring insteadOf);
#   - an `insteadOf` rewrite maps that https url to the local bare repo, so the actual git
#     TRANSPORT (push/fetch) goes to the bare repo offline;
#   - `git remote set-head origin --auto` populates refs/remotes/origin/HEAD so
#     ghr_remote_default_branch can name the default branch.
# The default branch is `main`. Commits are PUSHED to the bare repo so the fetched default carries
# them — that is exactly the integrated state the gate anchors to.

remotes_root="$tmproot/remotes"
mkdir -p "$remotes_root"

# setup_remote <repo> <name> — create the bare remote, configure origin (identity url + insteadOf
# transport rewrite), and set the default-branch head. Idempotent per <name>.
setup_remote() {
  local repo="$1" name="$2"
  local bare="$remotes_root/${name}.git"
  git init -q --bare "$bare"
  # Pin the bare repo's HEAD to `main` EXPLICITLY. `git init --bare`'s default branch name varies
  # across git versions (`master` on older CI git, `main` on newer), so without this the SERVER-side
  # HEAD `git ls-remote --symref origin HEAD` reports (the source the fake gh's defaultBranchRef and
  # the round-2 gate rely on, #102 FIX 2) could name a branch the targets never push → the gate can't
  # resolve the default. Setting it here makes the hermetic remote's default deterministic = `main`.
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
  git -C "$repo" remote add origin "https://github.com/someone/${name}.git"
  # Transport rewrite: fetch/push of the https identity url actually hit the local bare repo.
  git -C "$repo" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
}

# push_default <repo> — push the working repo's current branch to origin/main and set the remote
# default head. Called after each commit so the fetched default carries it. Tolerant of a repo
# with NO `origin` (e.g. the embedded inner repo in the nested-repo test, where the nested-repo
# guard fires before any anchor/fetch): skip silently in that case.
push_default() {
  local repo="$1"
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$repo" push -q -f origin HEAD:refs/heads/main
  git -C "$repo" remote set-head origin main >/dev/null 2>&1 || \
    git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 || true
}

# make_target <name> — a throwaway non-Fabrica git repo on default branch `main` with one commit,
# backed by a matching gh-bound remote (so the #102 gate can anchor + fetch fresh); echo its path.
make_target() {
  local name="$1"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m "init"
  setup_remote "$path" "$name"
  push_default "$path"
  echo "$path"
}

# commit_star <repo> <content...> — write .fabrica/north-star.md, COMMIT it, and PUSH to the
# remote default branch (so the gate's fetched-fresh anchor carries it).
commit_star() {
  local repo="$1"; shift
  mkdir -p "$repo/.fabrica"
  printf '%s\n' "$*" > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "set north star"
  push_default "$repo"
}

# commit_star_raw <repo> — read EXACT .fabrica/north-star.md bytes from stdin, COMMIT, and PUSH
# (so a test can pin whitespace/tab/multiline-split marker variants printf can't).
commit_star_raw() {
  local repo="$1"
  mkdir -p "$repo/.fabrica"
  cat > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "set north star"
  push_default "$repo"
}

# commit_symlink_star <repo> <relpath> — commit <relpath> as a SYMLINK pointing at a sibling
# regular file (the symlink attack: `git show <commit>:<relpath>` then returns the link's
# target-path string, not content), then PUSH. The link target file has REAL non-placeholder
# content, so a gate that followed the symlink would wrongly PROCEED — the FIX 4 guard must FAIL
# on the symlink mode (120000) before ever reading it.
commit_symlink_star() {
  local repo="$1" relpath="$2"
  mkdir -p "$repo/$(dirname "$relpath")"
  printf '### Real goal · status: **active** — content the symlink points at\nbody\n' > "$repo/decoy-target.md"
  ( cd "$repo" && ln -s "decoy-target.md" "$relpath" )
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "commit symlink north star"
  push_default "$repo"
}

# advance_remote_default <name> <star-content...> — advance the bare remote <name>.git's default
# branch (main) to a NEW commit whose .fabrica/north-star.md is <star-content>, WITHOUT touching the
# original target's local remote-tracking cache (so that cache goes STALE). Used by the fetch-fresh
# tests. Portable: it builds a throwaway "pusher" repo wired to the bare remote the SAME way as the
# targets (insteadOf transport rewrite to a canonical `file://<abspath>` URL, push by remote NAME) —
# NOT `git clone <file-url>` (cloning a file:// URL behaved inconsistently across git versions in
# CI). It fetches the current default tip, builds on it (fast-forward), and pushes.
advance_remote_default() {
  local name="$1"; shift
  local bare="$remotes_root/${name}.git"
  local pusher="$tmproot/${name}-pusher"
  rm -rf "$pusher"
  git init -q -b main "$pusher"
  git -C "$pusher" remote add origin "https://github.com/someone/${name}.git"
  git -C "$pusher" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
  git -C "$pusher" fetch -q origin main
  git -C "$pusher" checkout -q -B main FETCH_HEAD
  mkdir -p "$pusher/.fabrica"
  printf '%s\n' "$*" > "$pusher/.fabrica/north-star.md"
  git -C "$pusher" add .fabrica/north-star.md
  git -C "$pusher" commit -q -m "advance remote default"
  git -C "$pusher" push -q origin HEAD:main
}

# make_cp_clone <name> — a throwaway CONTROL-PLANE clone: it ships copies of BOTH sourced libs
# (north-star.sh + gh-remote.sh, #102) and manager-review.sh, so ns_fabrica_root (derived from the
# lib's own location) == this clone's git top-level → the resolver classifies FABRICA_SELF and the
# gate takes the FABRICA_SELF branch. Remote-backed on default branch `main` (same as make_target)
# so the #102 gh-bound anchor path is exercised for the self case too. Echoes the clone path; the
# caller commits + pushes the root NORTH_STAR.md (or whatever the case needs) and runs the COPIED
# manager-review.sh so its own-location lib derivation lands inside the clone.
make_cp_clone() {
  local name="$1"
  local cp_root="$tmproot/$name"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$repo_root/scripts/lib/gh-remote.sh" "$cp_root/scripts/lib/gh-remote.sh"
  cp "$manager_review" "$cp_root/scripts/manager-review.sh"; chmod +x "$cp_root/scripts/manager-review.sh"
  git -C "$cp_root" init -q -b main
  setup_remote "$cp_root" "$name"
  echo "$cp_root"
}

# run_cp_gate <cp_root> — run the clone's OWN copied manager-review.sh from inside it with the
# fakes on PATH; echo "<rc>|<combined-output>". Sets the local-mirror opt-in for the hermetic
# file:// transport, same as run_gate (#102 round-2 FIX 1).
run_cp_gate() {
  local cp_root="$1" rc out allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  out="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$cp_root/scripts/manager-review.sh" 1 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# ---------------------------------------------------------------------------------
# (1) SOURCE IDENTITY — approval source == gate source. Operator approval is not
# machine-readable, so we pin the SOURCE identity: manager-review.sh's gate, the persona, and
# the /faber template all name the SAME per-target source (.fabrica/north-star.md via the
# resolver), and the gate reads it COMMITTED (git show at the pinned HEAD).
# ---------------------------------------------------------------------------------
test_source_identity() {
  local mr persona_txt faber_txt
  mr="$(cat "$manager_review")"; persona_txt="$(cat "$persona")"; faber_txt="$(cat "$faber_template")"

  # The gate resolves via the shared resolver and reads .fabrica/north-star.md committed.
  case "$mr" in *"ns_resolve"*) passed=$((passed + 1)); echo "pass: (1) gate resolves via ns_resolve (shared resolver)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) gate does not call ns_resolve" ;; esac
  # The single-quoted needles are LITERAL source text we search for in manager-review.sh's
  # content — the `${head_commit}` / `$worktree` inside them must NOT expand (they are the exact
  # bytes the script contains), so single quotes are deliberate; SC2016 doesn't apply.
  # shellcheck disable=SC2016
  case "$mr" in *'git show "${head_commit}:.fabrica/north-star.md"'*) passed=$((passed + 1)); echo "pass: (1) gate reads .fabrica/north-star.md COMMITTED at the pinned head_commit" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) gate does not read the committed .fabrica/north-star.md at head_commit" ;; esac

  # The pin is the SAME commit the review worktree is materialized at: `git worktree add ...
  # "$head_commit"` and `git show "${head_commit}:..."` both use head_commit (captured once).
  # shellcheck disable=SC2016  # literal source-text needle; must not expand (see above).
  case "$mr" in *'git worktree add --detach "$worktree" "$head_commit"'*) passed=$((passed + 1)); echo "pass: (1) review worktree is pinned to the SAME head_commit as the committed read" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) review worktree is not pinned to head_commit" ;; esac

  # The persona + /faber approval/logging reference the per-target .fabrica/north-star.md, NOT
  # {{FABRICA_ROOT}}/NORTH_STAR.md as the operator-approval source.
  case "$persona_txt" in *".fabrica/north-star.md"*) passed=$((passed + 1)); echo "pass: (1) persona references the target's .fabrica/north-star.md (approval source)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) persona does not reference .fabrica/north-star.md" ;; esac
  case "$faber_txt" in *".fabrica/north-star.md"*) passed=$((passed + 1)); echo "pass: (1) /faber template references the target's .fabrica/north-star.md (approval source)" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) /faber template does not reference .fabrica/north-star.md" ;; esac

  # Gate source ≡ approval source is stated explicitly so the two never silently diverge.
  case "$persona_txt" in *"gate source ≡ approval source"*|*"gate reads — gate source"*|*"same committed source"*) passed=$((passed + 1)); echo "pass: (1) persona pins gate-source == approval-source" ;;
    *) failed=$((failed + 1)); echo "FAIL: (1) persona does not pin gate-source == approval-source" ;; esac
}

# ---------------------------------------------------------------------------------
# (2) COMMITTED vs UNCOMMITTED — the safety-critical pair, BOTH directions.
# ---------------------------------------------------------------------------------

# (2a) A worktree-only .fabrica/north-star.md (written but NOT committed) does NOT authorize:
# the gate reads HEAD, sees no committed star, and FAILs (UNSET) before any verdict.
test_worktree_only_does_not_authorize() {
  local repo; repo="$(make_target "wt-only")"
  # Write the star but DO NOT commit it — an uncommitted working-tree edit.
  mkdir -p "$repo/.fabrica"
  echo "an unreviewed local goal" > "$repo/.fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2a) worktree-only star: gate FAILs (does NOT authorize)" "1" "$rc"
  assert_contains "(2a) worktree-only star: FAIL cites not-committed-at-HEAD" "not committed at HEAD" "$out"
}

# (2b) A HEAD-committed star STILL authorizes even if the working-tree copy is DELETED. The
# gate reads committed content at the pinned commit, independent of the dirty working tree.
test_committed_authorizes_even_if_worktree_deleted() {
  local repo; repo="$(make_target "committed-del")"
  commit_star "$repo" "### our real committed north star · status: **active**"
  rm -f "$repo/.fabrica/north-star.md"   # working-tree copy gone; HEAD still has it
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2b) committed star authorizes even with the worktree copy DELETED (gate proceeds)" "0" "$rc"
  assert_contains "(2b) gate posted the verdict (reached codex)" "PROCEED" "$out"
}

# (2b') A HEAD-committed star STILL authorizes even if the working-tree copy is MODIFIED to the
# shipped-default placeholder: the gate reads the COMMITTED (clean) content, so the dirty
# placeholder edit neither redirects nor blocks it.
test_committed_authorizes_even_if_worktree_modified() {
  local repo; repo="$(make_target "committed-mod")"
  commit_star "$repo" "### our real committed north star · status: **active**"
  # Dirty the working tree with a placeholder marker — the gate must ignore this and read HEAD.
  printf 'placeholder <!-- fabrica-shipped-default -->\n' > "$repo/.fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2b') committed star authorizes even with the worktree copy MODIFIED to a placeholder" "0" "$rc"
  assert_contains "(2b') gate read the committed (clean) star and proceeded" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (2c) FIX 1 (round-2) — FABRICA_SELF authorizes off the COMMITTED root NORTH_STAR.md even when
# the working-tree copy is DELETED. We build a throwaway control-plane clone that CONTAINS a copy
# of the resolver lib + manager-review.sh, init it as git, COMMIT a root NORTH_STAR.md, then delete
# the worktree copy. ns_fabrica_root derives from the lib's own location, so run FROM this clone
# and its git top-level == ns_fabrica_root → the resolver reports FABRICA_SELF off committed state
# and the gate reads `git show HEAD:NORTH_STAR.md` — proceeding despite the deleted worktree copy.
# The gate's FABRICA_SELF branch is EXEMPT from the placeholder-FAIL, so a marker in the committed
# root star does not block it (Fabrica's own root star legitimately carries the shipped-default
# marker). This is the self analogue of (2b) and directly exercises the resolver/gate agreement.
# ---------------------------------------------------------------------------------
test_fabrica_self_committed_worktree_deleted_proceeds() {
  local cp_root; cp_root="$(make_cp_clone "gate-fabrica-self-committed-del")"
  # Commit a root NORTH_STAR.md + push it to the anchored default branch, then delete the worktree
  # copy: the gate must read the fetched default-branch commit, not the (deleted) worktree file.
  printf '### Fabrica goal · status: **active** — our own committed control-plane star\nbody\n' > "$cp_root/NORTH_STAR.md"
  git -C "$cp_root" add NORTH_STAR.md scripts/lib/north-star.sh scripts/lib/gh-remote.sh scripts/manager-review.sh
  git -C "$cp_root" commit -q -m "cp init with committed root star"
  push_default "$cp_root"
  rm -f "$cp_root/NORTH_STAR.md"   # worktree copy gone; the anchored commit still has it
  local res rc out
  res="$(run_cp_gate "$cp_root")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2c) FABRICA_SELF authorizes off COMMITTED root star with the worktree copy DELETED (gate proceeds)" "0" "$rc"
  assert_contains "(2c) Fabrica-self gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (2d) [P2, round-3] Fabrica-self is CLASSIFIED by PATH identity UNCONDITIONALLY — a missing
# committed root NORTH_STAR.md FAILs at the GATE (authorization), it does NOT fall through to a
# stray `.fabrica/north-star.md`. We build a throwaway control-plane clone (contains the lib +
# manager-review.sh, so ns_fabrica_root == its git top-level → the resolver classifies FABRICA_SELF),
# but commit NO root NORTH_STAR.md and DO commit a stray `.fabrica/north-star.md`. Under round-2 the
# resolver's committed-existence gate would have fallen through to the LOCAL branch and the gate
# would have PROCEEDED against `.fabrica`. Now the resolver returns FABRICA_SELF (path-only), the gate
# takes the FABRICA_SELF branch, its `git show HEAD:NORTH_STAR.md` read FAILs cleanly (root not
# committed) with an actionable message, and it NEVER authorizes off the stray `.fabrica` star.
# ---------------------------------------------------------------------------------
test_fabrica_self_no_committed_root_fails_not_local() {
  local cp_root; cp_root="$(make_cp_clone "gate-fabrica-self-no-root")"
  # NO root NORTH_STAR.md. A STRAY .fabrica/north-star.md IS committed + pushed (must NOT authorize).
  mkdir -p "$cp_root/.fabrica"
  printf '### Stray goal · status: **active** — must NOT authorize Fabrica-self\nbody\n' > "$cp_root/.fabrica/north-star.md"
  git -C "$cp_root" add scripts/lib/north-star.sh scripts/lib/gh-remote.sh scripts/manager-review.sh .fabrica/north-star.md
  git -C "$cp_root" commit -q -m "cp init: stray local star, NO root star"
  push_default "$cp_root"
  local res rc out
  res="$(run_cp_gate "$cp_root")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(2d) FABRICA_SELF with no committed root NORTH_STAR.md → gate FAILs (does NOT fall back to .fabrica)" "1" "$rc"
  assert_contains "(2d) FABRICA_SELF missing-root FAIL cites NORTH_STAR.md not committed at HEAD" "NORTH_STAR.md is not committed at HEAD" "$out"
  # And it must NOT have proceeded against the stray .fabrica star.
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (2d) gate must NOT reach a verdict off the stray .fabrica star"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (2d) gate did NOT authorize off the stray .fabrica star" ;;
  esac
}

# ---------------------------------------------------------------------------------
# (3) LOCAL committed → debates; LOCAL + marker → FAIL; UNSET → FAIL.
# ---------------------------------------------------------------------------------

# (3a) A LOCAL committed star with no marker → the gate debates it (proceeds to the verdict).
test_local_committed_debates() {
  local repo; repo="$(make_target "local-ok")"
  commit_star "$repo" "### ship the widget v2 by Q3 · status: **active**"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3a) LOCAL committed star (no marker) → gate debates (exit 0)" "0" "$rc"
  assert_contains "(3a) gate reached the verdict" "PROCEED" "$out"
}

# (3b) A LOCAL committed star STILL carrying the shipped-default marker (un-replaced template)
# → FAIL before any verdict, with an actionable "replace + commit + approve" message.
test_local_marker_fails() {
  local repo; repo="$(make_target "local-marker")"
  # The marker rides on the active HEADING (as in the shipped template), so the heading-anchored
  # active-region scan (round-3 FIX 2) opens on it and the placeholder is detected.
  commit_star "$repo" "### Placeholder status: **active** <!-- fabrica-shipped-default --> replace me"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3b) LOCAL committed star with shipped-default marker → gate FAILs" "1" "$rc"
  assert_contains "(3b) marker FAIL cites the shipped placeholder" "shipped placeholder" "$out"
}

# (3c) UNSET — a non-empty target with no committed star → FAIL with an actionable pointer.
test_unset_fails() {
  local repo; repo="$(make_target "unset")"   # committed init, no .fabrica/north-star.md
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3c) UNSET target (no committed star) → gate FAILs" "1" "$rc"
  assert_contains "(3c) UNSET FAIL names the resolver kind" "resolver: UNSET" "$out"
}

# ---------------------------------------------------------------------------------
# (3d) FIX A at the GATE — the placeholder check is active-region-SCOPED and whitespace/case-
# insensitive. Two bugs the adversarial sweep found:
#   - FALSE-PASS: a spacing/casing/reflow-split marker variant on the active heading must still
#     FAIL the gate (a byte-exact grep would let it AUTHORIZE).
#   - FALSE-FAIL: a correctly-replaced star (marker cleared from the active heading, still named
#     in prose) must PROCEED (a whole-file grep would wrongly FAIL it).
# ---------------------------------------------------------------------------------

# (3d-i) A committed star carrying a WHITESPACE/CASE/SPLIT marker variant on the active heading
# → gate FAILs (the un-replaced placeholder does NOT slip through and authorize).
test_gate_marker_variants_fail() {
  # no-space + UPPERCASE on the active heading
  local r1; r1="$(make_target "marker-nospace-upper")"
  printf '### Goal · status: **active** · <!--FABRICA-SHIPPED-DEFAULT--> replace me\nbody\n' \
    | commit_star_raw "$r1"
  local res rc out
  res="$(run_gate "$r1")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) no-space+UPPERCASE marker variant → gate FAILs" "1" "$rc"
  assert_contains "(3d-i) variant FAIL cites the shipped placeholder" "shipped placeholder" "$out"

  # reflow-SPLIT: marker on the line just below the active heading
  local r2; r2="$(make_target "marker-split")"
  printf '### Goal · status: **active**\n<!-- fabrica-shipped-default -->\nbody\n' \
    | commit_star_raw "$r2"
  res="$(run_gate "$r2")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) reflow-split marker (line below active heading) → gate FAILs" "1" "$rc"

  # TAB-separated marker on the active heading
  local r3; r3="$(make_target "marker-tab")"
  printf '### Goal status: active\t<!--\tfabrica-shipped-default\t-->\nbody\n' \
    | commit_star_raw "$r3"
  res="$(run_gate "$r3")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-i) tab-separated marker variant → gate FAILs" "1" "$rc"
}

# (3d-ii) A CORRECTLY-REPLACED star: the marker is only in the explanatory PROSE, CLEARED from the
# active heading → gate PROCEEDs (the prose mention must not false-FAIL a valid adopter star).
test_gate_correctly_replaced_proceeds() {
  local repo; repo="$(make_target "marker-prose-only")"
  # Mirrors the shipped template shape: prose NAMES the marker, but the active heading is clean.
  printf 'Intro: the shipped default carries a <!-- fabrica-shipped-default --> marker; remove it when you set your own.\n\n### Ship widget v2 by Q3 · status: **active** — our real approved goal\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-ii) correctly-replaced star (marker only in prose) → gate PROCEEDs (no false FAIL)" "0" "$rc"
  assert_contains "(3d-ii) gate reached the verdict" "PROCEED" "$out"
}

# (3d-iii) FIX 2 (round-2) — a DELIMITER-FREE prose mention of the token WITHIN THE ACTIVE REGION
# (the operator removed the real `<!-- … -->` comment but the active heading/body still SAYS
# "fabrica-shipped-default" in prose) must PROCEED. Round-1's bare-token-anywhere match wrongly
# FAILed this valid star; the comment-form match requires the `<!-- … -->` delimiters, so a
# delimiter-free prose token in the active region does NOT trip the placeholder-FAIL.
test_gate_prose_token_in_active_region_proceeds() {
  local repo; repo="$(make_target "marker-prose-in-active")"
  printf '### Ship widget v2 by Q3 · status: **active** — our real goal; we removed the fabrica-shipped-default marker from this line.\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(3d-iii) bare-token PROSE in the ACTIVE region (no <!-- -->) → gate PROCEEDs (FIX 2)" "0" "$rc"
  assert_contains "(3d-iii) gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (6) FIX F — the gate refuses to authorize off a north star in a SEPARATE git repo NESTED inside
# ANOTHER git work tree (confused deputy). A linked worktree (same repo) is NOT rejected.
# ---------------------------------------------------------------------------------

# (6a) Gate run from a SEPARATE embedded repo (its own committed star) inside an outer work tree
# → FAIL with the nested/embedded message (before any verdict).
test_gate_nested_repo_fails() {
  # Outer target repo with its OWN committed star.
  local outer; outer="$(make_target "nested-outer")"
  commit_star "$outer" "the OUTER target's real committed north star"
  # A SEPARATE embedded repo nested inside the outer work tree, with its own committed star.
  local inner="$outer/embedded/inner"
  mkdir -p "$inner"
  git -C "$inner" init -q
  git -C "$inner" commit -q --allow-empty -m "inner init"
  commit_star "$inner" "the embedded repo's DIFFERENT star"
  local res rc out
  res="$(run_gate "$inner")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(6a) gate run from a nested/embedded repo → FAILs" "1" "$rc"
  assert_contains "(6a) nested FAIL tells the operator to run from the target's own top-level clone" "nested/embedded checkout" "$out"
}

# (6b) A LINKED WORKTREE (git worktree add — SAME repo, shares the common dir) is NOT the
# confused-deputy case: it must NOT be rejected as nested. We add a linked worktree of a normal
# target (committed real star) and assert the gate PROCEEDs from it.
test_gate_linked_worktree_ok() {
  local repo; repo="$(make_target "wt-main")"
  commit_star "$repo" "### the target's real committed north star · status: **active**"
  # Create a linked worktree UNDER the repo's tree (same shape as this project's .claude/worktrees).
  local wt="$repo/.wts/feature"
  git -C "$repo" worktree add -q --detach "$wt" HEAD 2>/dev/null
  local res rc out
  res="$(run_gate "$wt")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(6b) linked worktree (same repo) is NOT treated as nested → gate PROCEEDs" "0" "$rc"
  assert_contains "(6b) linked-worktree run reached the verdict" "PROCEED" "$out"
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------------------------------------------------------------------------------
# (7) FIX 4 (round-2) — the gate REJECTS a committed SYMLINK north star (git mode 120000) BEFORE
# the marker check, in BOTH the LOCAL and the FABRICA_SELF branches. A committed symlink makes
# `git show <commit>:<path>` return the link's target-path string, not content, so it would bypass
# the marker check and let the gate authorize off a meaningless string (and diverge from the file
# Codex reviews). The decoy target the link points at has REAL non-placeholder content, so a
# symlink-following gate would wrongly PROCEED — the guard must FAIL with the symlink message.
# ---------------------------------------------------------------------------------

# (7a) LOCAL committed symlink .fabrica/north-star.md → gate FAILs with the symlink message.
test_gate_local_symlink_fails() {
  local repo; repo="$(make_target "local-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(7a) LOCAL committed symlink north star → gate FAILs" "1" "$rc"
  assert_contains "(7a) LOCAL symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# (7b) FABRICA_SELF committed symlink NORTH_STAR.md → gate FAILs with the symlink message. Built
# like (2c): a throwaway control-plane clone that ships the lib + manager-review.sh, so
# ns_fabrica_root == the cwd's top-level → the gate takes the FABRICA_SELF branch.
test_gate_fabrica_self_symlink_fails() {
  local cp_root; cp_root="$(make_cp_clone "gate-fabrica-self-symlink")"
  # Commit NORTH_STAR.md as a SYMLINK to a decoy real file, then push.
  printf '### Real fabrica goal · status: **active** — decoy content\nbody\n' > "$cp_root/decoy-root.md"
  ( cd "$cp_root" && ln -s "decoy-root.md" "NORTH_STAR.md" )
  git -C "$cp_root" add -A
  git -C "$cp_root" commit -q -m "cp init with SYMLINK root star"
  push_default "$cp_root"
  local res rc out
  res="$(run_cp_gate "$cp_root")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(7b) FABRICA_SELF committed symlink NORTH_STAR.md → gate FAILs" "1" "$rc"
  assert_contains "(7b) FABRICA_SELF symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# ---------------------------------------------------------------------------------
# (8) FIX 1 (round-3) — the gate authorizes correctly when run from a SUBDIRECTORY of the target.
# The round-2 symlink guard calls ns_committed_is_regular_file "$PWD" ... with a ROOT-relative
# relpath; pre-fix, from a subdir the `git ls-tree` pathspec was interpreted relative to the subdir
# → the mode lookup returned EMPTY for a valid regular committed star → the guard FALSELY rejected
# the run. The fix resolves the top-level before ls-tree. Assert: a subdir run with a regular
# committed star PROCEEDs (not rejected as a symlink); and a committed SYMLINK is STILL rejected
# from a subdir.
# ---------------------------------------------------------------------------------

# run_gate_from <dir> — like run_gate but runs the REAL manager-review.sh from an arbitrary <dir>
# (typically a subdirectory of the target), so we exercise the subdir-invocation code path. Sets
# the local-mirror opt-in for the hermetic file:// transport, same as run_gate (#102 round-2 FIX 1).
run_gate_from() {
  local dir="$1" rc out allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  out="$(
    cd "$dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$manager_review" 1 2>&1
  )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# (8a) A regular committed star, gate run from a nested SUBDIRECTORY of the target → PROCEEDs (the
# symlink guard's mode lookup resolves the root-relative pathspec from the top-level, not the subdir).
test_gate_subdir_regular_star_proceeds() {
  local repo; repo="$(make_target "subdir-regular")"
  commit_star "$repo" "### Ship v2 by Q3 · status: **active** — our real committed goal"
  local sub="$repo/deeply/nested/dir"
  mkdir -p "$sub"
  local res rc out
  res="$(run_gate_from "$sub")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(8a) gate from a SUBDIR with a regular committed star → PROCEEDs (not falsely symlink-rejected)" "0" "$rc"
  assert_contains "(8a) subdir gate reached the verdict" "PROCEED" "$out"
}

# (8b) A committed SYMLINK north star, gate run from a SUBDIR → STILL FAILs with the symlink message
# (the top-level pathspec resolution correctly finds the symlink mode from the subdir too).
test_gate_subdir_symlink_still_fails() {
  local repo; repo="$(make_target "subdir-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local sub="$repo/deeply/nested/dir"
  mkdir -p "$sub"
  local res rc out
  res="$(run_gate_from "$sub")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(8b) committed SYMLINK star, gate from a SUBDIR → STILL FAILs" "1" "$rc"
  assert_contains "(8b) subdir symlink FAIL says it must be a regular file, not a symlink" "not a symlink" "$out"
}

# ---------------------------------------------------------------------------------
# (9) FIX 2 (round-3) — the active-region scan STARTS on a HEADING line. A committed star with a
# PROSE/front-matter line mentioning `status: active` BEFORE the real active heading (which carries
# the shipped-default marker) must STILL be detected as a placeholder → gate FAILs (no placeholder
# bypass). And a normal single-heading active entry still PROCEEDs.
# ---------------------------------------------------------------------------------

# (9a) Prose `status: active` before the real marked active heading → gate STILL FAILs (placeholder
# is not bypassed by an early prose region-start).
test_gate_prose_active_before_heading_still_fails() {
  local repo; repo="$(make_target "prose-before-heading")"
  printf 'Front-matter: shipped default status: active until you set your own.\n\n### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(9a) prose 'status: active' before the marked active HEADING → gate STILL FAILs (no bypass)" "1" "$rc"
  assert_contains "(9a) FAIL still cites the shipped placeholder" "shipped placeholder" "$out"
}

# (9b) A normal single-heading active entry (no prose decoy, no marker) still PROCEEDs.
test_gate_single_heading_active_proceeds() {
  local repo; repo="$(make_target "single-heading-active")"
  commit_star "$repo" "### Ship widget v2 by Q3 · status: **active** — our real approved goal"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(9b) normal single-heading active entry → gate PROCEEDs" "0" "$rc"
  assert_contains "(9b) single-heading gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (10) [P2, round-3] NO-ACTIVE-ENTRY FAIL — a committed north star with content but NO valid
# `status: active` heading (e.g. the marker was mistyped/removed when editing the template) does
# NOT authorize: ns_has_shipped_default_marker is false (no active region → no marker) AND the file
# exists (so it is not UNSET), so pre-fix the gate PROCEEDED against a goalless file. The fix FAILs
# with "no active … entry" BEFORE any Codex verdict. A normal active entry still PROCEEDs (covered
# by 9b/3a); placeholder still FAILs (3b); UNSET still FAILs (3c).
# ---------------------------------------------------------------------------------
test_gate_no_active_entry_fails() {
  local repo; repo="$(make_target "no-active-entry")"
  # Content, but NO `status: active` heading — a heading + body that never marks an active entry
  # (the operator typo'd/removed `status: active` when editing the template).
  printf '### Ship widget v2 by Q3 — our goal (status typo: actve)\nsome body text describing the goal\n' \
    | commit_star_raw "$repo"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(10) committed star with NO 'status: active' heading → gate FAILs" "1" "$rc"
  assert_contains "(10) no-active-entry FAIL cites the missing active entry" "no active 'status: active' north-star entry" "$out"
  # It must NOT have reached the Codex verdict against the goalless file.
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (10) gate must NOT debate a goalless (no-active-entry) star"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (10) gate did NOT reach a verdict against the goalless star" ;;
  esac
}

# ---------------------------------------------------------------------------------
# (4) doctor.sh check (h) — consistent with the gate, but WARN (not FAIL) since doctor only
# diagnoses. UNSET → WARN; a LOCAL committed real star → pass.
# ---------------------------------------------------------------------------------

# run_doctor_h <repo_dir> — run doctor.sh from inside <repo_dir> with the fakes on PATH; echo
# only its (h) VERDICT line (pass/warn/fail), NOT the informational `info: (h) north-star anchor:`
# line (#102) that now precedes it. doctor may exit non-zero on unrelated hard fails (no /faber
# etc.), so capture output regardless of rc.
run_doctor_h() {
  # Local-mirror opt-in for the hermetic file:// transport, same as run_gate (#102 round-2 FIX 1);
  # a caller can override to 0 to exercise the doctor fail-closed WARN/degrade path.
  local repo_dir="$1" out allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$doctor" 2>&1 || true
  )"
  printf '%s' "$out" | grep -E '^(pass|warn|fail): \(h\)' | head -n1 || true
}

# run_doctor_h_anchor <repo_dir> — like run_doctor_h but echo the informational anchor line
# (`info: (h) north-star anchor: …`) so a test can assert HOW doctor resolved the anchor.
run_doctor_h_anchor() {
  local repo_dir="$1" out allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  out="$(
    cd "$repo_dir"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$doctor" 2>&1 || true
  )"
  printf '%s' "$out" | grep 'north-star anchor:' | head -n1 || true
}

test_doctor_unset_warns() {
  local repo; repo="$(make_target "doctor-unset")"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4a) doctor (h) on an UNSET target WARNs (not fail:)" "warn:" "$line"
  assert_contains "(4a) doctor (h) UNSET message names the gap" "no north star set" "$line"
}

test_doctor_local_committed_passes() {
  local repo; repo="$(make_target "doctor-local")"
  # A real adopter star: an active entry, no shipped-default marker → doctor (h) passes.
  commit_star "$repo" "### Ship v2 · status: **active** — our real project goal for this quarter"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4b) doctor (h) on a LOCAL committed real star PASSES" "pass:" "$line"
}

test_doctor_local_marker_warns() {
  local repo; repo="$(make_target "doctor-marker")"
  # Marker on the active HEADING (shipped-template shape) so the heading-anchored region scan
  # (round-3 FIX 2) opens on it and doctor (h) WARNs on the still-shipped-default placeholder.
  commit_star "$repo" "### Placeholder status: **active** <!-- fabrica-shipped-default --> replace me"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4c) doctor (h) on a still-shipped-default LOCAL star WARNs" "warn:" "$line"
  assert_contains "(4c) doctor (h) shipped-default WARN cites the marker" "fabrica-shipped-default" "$line"
}

# (4d) FIX E — doctor (h) drives its verdict off the COMMITTED star, matching the gate. A star
# committed at HEAD but DELETED in the working tree must still be diagnosed as the committed
# (real) star → PASS, not "no star" — the same committed source the gate authorizes on.
test_doctor_h_committed_worktree_deleted() {
  local repo; repo="$(make_target "doctor-committed-del")"
  commit_star "$repo" "### Ship v2 · status: **active** — our real committed goal"
  rm -f "$repo/.fabrica/north-star.md"   # worktree copy gone; HEAD still has it
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4d) doctor (h) reads the COMMITTED star even when the worktree copy is deleted → pass" "pass:" "$line"
}

# (4d') FIX E, other direction — a star committed at HEAD but MODIFIED in the working tree to a
# placeholder must be diagnosed off the COMMITTED (clean) content → PASS, and NOTE the drift.
test_doctor_h_committed_worktree_modified() {
  local repo; repo="$(make_target "doctor-committed-mod")"
  commit_star "$repo" "### Ship v2 · status: **active** — our real committed goal"
  printf 'placeholder <!-- fabrica-shipped-default -->\n' > "$repo/.fabrica/north-star.md"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4d') doctor (h) reads the COMMITTED (clean) star despite a dirty placeholder worktree edit → pass" "pass:" "$line"
  assert_contains "(4d') doctor (h) notes the working-tree copy differs from the anchored committed version" "differs from the anchored committed version" "$line"
}

# (4d'') FIX 1 (round-3) — the head-vs-worktree drift note must fire for FABRICA_SELF too. doctor
# drives the note off $committed_relpath (the exact path the gate reads), NOT a hardcoded
# .fabrica-relative path — so an uncommitted edit to the control plane's ROOT NORTH_STAR.md is
# surfaced as "differs from HEAD / the gate reads the committed version", not swallowed as a
# silent clean pass. (manager-review.sh reads HEAD:NORTH_STAR.md and ignores the working tree, so
# a dirty root star that doctor reported clean would be misleading.) We build a throwaway
# control-plane clone (contains doctor.sh + the resolver lib, so ns_fabrica_root == its git
# top-level → the resolver classifies FABRICA_SELF → committed_relpath = NORTH_STAR.md), commit a
# real root star, then DIRTY the working-tree copy and run doctor from the clone.
test_doctor_h_fabrica_self_worktree_modified_notes_drift() {
  local name="doctor-fabrica-self-mod"
  local cp_root="$tmproot/$name"
  mkdir -p "$cp_root/scripts/lib"
  cp "$repo_root/scripts/lib/north-star.sh" "$cp_root/scripts/lib/north-star.sh"
  cp "$repo_root/scripts/lib/gh-remote.sh" "$cp_root/scripts/lib/gh-remote.sh"
  cp "$doctor" "$cp_root/scripts/doctor.sh"; chmod +x "$cp_root/scripts/doctor.sh"
  git -C "$cp_root" init -q -b main
  setup_remote "$cp_root" "$name"
  # A real (non-placeholder) committed root star, pushed to the anchored default → PASS clean.
  printf '### Fabrica goal · status: **active** — our own committed control-plane star\nbody\n' > "$cp_root/NORTH_STAR.md"
  git -C "$cp_root" add NORTH_STAR.md scripts/lib/north-star.sh scripts/lib/gh-remote.sh scripts/doctor.sh
  git -C "$cp_root" commit -q -m "cp init with committed root star"
  push_default "$cp_root"
  # Now DIRTY the working-tree root copy (uncommitted edit the gate would ignore).
  printf '### Fabrica goal · status: **active** — uncommitted local edit\nbody CHANGED\n' > "$cp_root/NORTH_STAR.md"
  # Local-mirror opt-in for the hermetic file:// transport, same as run_doctor_h (#102 round-2 FIX 1).
  local line allow="${FABRICA_ALLOW_LOCAL_MIRROR:-1}"
  line="$(
    cd "$cp_root"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR="$allow" bash "$cp_root/scripts/doctor.sh" 2>&1 || true
  )"
  line="$(printf '%s' "$line" | grep -E '^(pass|warn|fail): \(h\)' | head -n1 || true)"
  assert_contains "(4d'') doctor (h) on Fabrica-self reads the COMMITTED root star despite a dirty worktree edit → pass" "pass:" "$line"
  assert_contains "(4d'') doctor (h) notes the Fabrica-self ROOT working-tree copy differs from the anchored committed version" "differs from the anchored committed version" "$line"
}

# (4f) FIX 4 (round-2) — doctor (h) diagnoses a committed SYMLINK north star as a WARN (symmetric
# with the gate, which FAILs). doctor must not read the link's target-path string as if it were the
# star; it WARNs that a regular file is required.
test_doctor_h_committed_symlink_warns() {
  local repo; repo="$(make_target "doctor-symlink")"
  commit_symlink_star "$repo" ".fabrica/north-star.md"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4f) doctor (h) on a committed SYMLINK north star WARNs" "warn:" "$line"
  assert_contains "(4f) doctor (h) symlink WARN says a regular file is required (not a symlink)" "SYMLINK" "$line"
}

# (4e) FIX D — doctor with a MISSING resolver lib must still print its summary and REPORT the
# missing lib (as a fail: line), not crash at the top-of-file source. We run a COPY of the repo
# tree with scripts/lib/north-star.sh removed, so `. "$ns_lib"` would abort the old doctor.
test_doctor_missing_lib_reports_and_summarizes() {
  # Build a throwaway clone of the control-plane tree with the lib removed. Copy only what doctor
  # needs to run past its early checks; the point is the MISSING lib, so remove it after copying.
  local fake_root="$tmproot/doctor-nolib-root"
  mkdir -p "$fake_root/scripts/lib" "$fake_root/scripts/test" "$fake_root/ci" "$fake_root/templates/.fabrica"
  cp "$doctor" "$fake_root/scripts/doctor.sh"; chmod +x "$fake_root/scripts/doctor.sh"
  cp "$setup_script" "$fake_root/scripts/setup-target-repo.sh"; chmod +x "$fake_root/scripts/setup-target-repo.sh"
  cp "$repo_root/ci/required-files.txt" "$fake_root/ci/required-files.txt"
  # Deliberately do NOT copy scripts/lib/north-star.sh → the lib is missing.
  local out rc
  out="$(
    cd "$fake_root"
    PATH="$fakebin:$PATH" bash "$fake_root/scripts/doctor.sh" 2>&1
  )" && rc=0 || rc=$?
  assert_contains "(4e) doctor with a missing resolver lib still prints its summary (no crash)" "doctor:" "$out"
  assert_contains "(4e) doctor (h) reports the missing resolver lib as a fail line" "resolver lib missing" "$out"
  assert_eq "(4e) doctor exits non-zero when the lib (a fail) is missing" "1" "$rc"
}

# ---------------------------------------------------------------------------------
# (11) #102 — the gate anchors to the gh-BOUND remote's DEFAULT branch, not the checked-out branch.
# A star committed ONLY on a NON-default (feature) branch must NOT authorize; the gate anchors to
# the DEFAULT branch (main), which carries the integrated/operator-approved star.
# ---------------------------------------------------------------------------------

# (11a) The default branch (main) has the REAL committed star; a checked-out FEATURE branch has a
# DIFFERENT (placeholder) star. The gate anchors to main → PROCEEDs on the integrated star, NOT the
# feature branch's placeholder (pre-#102 it pinned local HEAD = the feature branch → would FAIL).
test_gate_anchors_to_default_not_feature_branch() {
  local repo; repo="$(make_target "anchor-default-branch")"
  # main gets the real approved star (pushed → the anchored default carries it).
  commit_star "$repo" "### Ship v2 by Q3 · status: **active** — our real integrated goal"
  # Now check out a FEATURE branch and commit a PLACEHOLDER star there (NOT pushed to main).
  git -C "$repo" checkout -q -b feature
  printf '### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' \
    > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "feature-branch placeholder star (must NOT authorize)"
  # HEAD is now the feature branch. The gate must anchor to main (the pushed real star) → PROCEED.
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(11a) star on a non-default branch does NOT authorize; gate anchors to the DEFAULT branch → PROCEEDs" "0" "$rc"
  assert_contains "(11a) gate debated the integrated (default-branch) star, not the feature placeholder" "PROCEED" "$out"
}

# (11b) The mirror: the DEFAULT branch (main) carries a PLACEHOLDER star, while the checked-out
# feature branch has a REAL star. The gate anchors to main → FAILs on the placeholder, proving it
# ignores the feature branch's (uncommitted-to-default) real star.
test_gate_default_placeholder_feature_real_fails() {
  local repo; repo="$(make_target "anchor-default-placeholder")"
  # main gets a PLACEHOLDER star (pushed → the anchored default carries it).
  commit_star_raw "$repo" <<'STAR'
### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me
body
STAR
  # A feature branch has a REAL star, but it never reaches the default branch.
  git -C "$repo" checkout -q -b feature
  printf '### Ship v2 · status: **active** — real feature-branch star (not on default)\nbody\n' \
    > "$repo/.fabrica/north-star.md"
  git -C "$repo" add .fabrica/north-star.md
  git -C "$repo" commit -q -m "feature real star (not integrated to default)"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(11b) gate anchors to the DEFAULT branch's placeholder (ignores the feature real star) → FAILs" "1" "$rc"
  assert_contains "(11b) FAIL cites the default-branch shipped placeholder" "shipped placeholder" "$out"
}

# ---------------------------------------------------------------------------------
# (12) #102 — STALE remote-tracking cache: the gate FETCHES FRESH and pins the INTEGRATED commit,
# NOT a stale local refs/remotes/origin/HEAD. We advance the bare remote's default from a SEPARATE
# clone so the target's remote-tracking ref stays behind. Old cached tip = a PLACEHOLDER star;
# fresh remote tip = a REAL star. If the gate used the stale cache it would FAIL (placeholder);
# fetching fresh → PROCEED, proving it pinned the fetched integrated commit.
# ---------------------------------------------------------------------------------
test_gate_fetches_fresh_not_stale_cache() {
  local name="anchor-stale-cache"
  local repo; repo="$(make_target "$name")"
  # v1 on main = a PLACEHOLDER star, pushed → the target's refs/remotes/origin/main now caches v1.
  commit_star_raw "$repo" <<'STAR'
### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me
body
STAR
  # Confirm the cache is populated at the placeholder commit (belt-and-suspenders).
  local cached; cached="$(git -C "$repo" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  # Advance the bare remote's main to v2 (a REAL star) via a SEPARATE pusher (not the target), so
  # the target's remote-tracking ref stays STALE at v1 (the target never fetched v2).
  advance_remote_default "$name" "### Ship v2 by Q3 · status: **active** — the fresh integrated approved goal"
  # The target's cache is still v1; the gate must FETCH FRESH → v2 (real) → PROCEED.
  local stale_now; stale_now="$(git -C "$repo" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  assert_eq "(12) target's remote-tracking cache is STALE (unchanged after the out-of-band push)" "$cached" "$stale_now"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(12) gate fetches fresh (not the stale placeholder cache) → PROCEEDs on the integrated commit" "0" "$rc"
  assert_contains "(12) gate debated the freshly-fetched real star" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (13) #102 — gh resolves a repo but NO configured remote matches that identity → manager-review
# FAILs CLEARLY (does NOT silently anchor to local HEAD while commenting on the gh-bound issue).
# We build a repo whose `origin` points at a DIFFERENT identity than the fake gh resolves.
# ---------------------------------------------------------------------------------
test_gate_gh_repo_no_matching_remote_fails() {
  local name="no-matching-remote"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m "init"
  commit_star "$path" "### Ship v2 · status: **active** — real committed star"
  # origin points at a DIFFERENT repo identity than gh resolves (gh → someone/<basename>).
  git -C "$path" remote add origin "https://github.com/someone-else/unrelated.git"
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(13) gh-repo-but-no-matching-remote → gate FAILs (no silent local-HEAD anchor)" "1" "$rc"
  assert_contains "(13) FAIL says no configured git remote matches the gh-resolved identity" "no configured git remote matches" "$out"
  # It must NOT have reached a Codex verdict off an unbound local anchor.
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (13) gate must NOT authorize off local HEAD when no remote matches"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (13) gate did NOT anchor to local HEAD on a gh-bound-but-unmatched repo" ;;
  esac
}

# ---------------------------------------------------------------------------------
# (14) #102 — FORK / non-`origin` matching remote: the gate anchors to the MATCHING remote's default
# branch, NOT blindly `origin`. `origin` = a FORK (different identity), `upstream` = the canonical
# repo gh resolves to. The star lives on upstream's default; the gate must select `upstream`.
# ---------------------------------------------------------------------------------
test_gate_fork_selects_upstream_not_origin() {
  local name="fork-upstream"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m "init"
  # The REAL star lives on upstream (the canonical repo gh resolves to: someone/<basename>).
  commit_star "$path" "### Ship v2 · status: **active** — canonical upstream approved goal"
  # Wire the CANONICAL identity as `upstream` (matches gh someone/<basename>); point `origin` at a
  # FORK (different identity). setup_remote already created `origin`? No — we build this by hand.
  local up_bare="$remotes_root/${name}.git"
  git init -q --bare "$up_bare"
  git -C "$path" remote add upstream "https://github.com/someone/${name}.git"
  git -C "$path" config "url.file://${up_bare}.insteadOf" "https://github.com/someone/${name}.git"
  git -C "$path" push -q -f upstream HEAD:refs/heads/main
  git -C "$path" remote set-head upstream main >/dev/null 2>&1 || true
  # `origin` = a FORK with a DIFFERENT identity (and a PLACEHOLDER default, to prove it is NOT used).
  local fork_bare="$remotes_root/${name}-fork.git"
  git init -q --bare "$fork_bare"
  git -C "$path" remote add origin "https://github.com/me/${name}-fork.git"
  git -C "$path" config "url.file://${fork_bare}.insteadOf" "https://github.com/me/${name}-fork.git"
  # Push a placeholder-star commit to the fork's main so, if the gate wrongly picked origin, it FAILs.
  # Build the fork commit in a fresh repo wired via the insteadOf transport (portable — no
  # `git clone` of a file:// URL), then push to the empty fork bare and set its HEAD.
  local forkclone="$tmproot/${name}-forkclone"
  git init -q -b main "$forkclone"
  git -C "$forkclone" remote add origin "https://github.com/me/${name}-fork.git"
  git -C "$forkclone" config "url.file://${fork_bare}.insteadOf" "https://github.com/me/${name}-fork.git"
  mkdir -p "$forkclone/.fabrica"
  printf '### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' \
    > "$forkclone/.fabrica/north-star.md"
  git -C "$forkclone" add .fabrica/north-star.md
  git -C "$forkclone" commit -q -m "fork placeholder star"
  git -C "$forkclone" push -q origin HEAD:main
  git --git-dir="$fork_bare" symbolic-ref HEAD refs/heads/main
  # gh resolves someone/<basename> → matches `upstream`, NOT `origin` (me/<basename>-fork). The gate
  # must anchor to upstream's default (the real star) → PROCEED, ignoring the fork's placeholder.
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(14) fork setup: gate selects the MATCHING remote (upstream), not blindly origin → PROCEEDs" "0" "$rc"
  assert_contains "(14) gate debated upstream's canonical star, not the fork's placeholder" "PROCEED" "$out"
}

# (14b) #102 — matching remote whose local remote-tracking HEAD is NOT set (a manually-added
# `upstream` that was never `git remote set-head`): ghr_remote_default_branch falls back to
# `git ls-remote --symref <remote> HEAD` for the default-branch NAME, so the gate still anchors +
# fetches fresh and PROCEEDs. Same wiring as (14) but the matching remote's symref is left UNSET.
test_gate_matching_remote_unset_symref_falls_back_to_lsremote() {
  local name="upstream-no-sethead"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m "init"
  commit_star "$path" "### Ship v2 · status: **active** — canonical star via ls-remote fallback"
  local up_bare="$remotes_root/${name}.git"
  git init -q --bare "$up_bare"
  # The bare remote needs its OWN HEAD symref pointing at main so ls-remote --symref reports it.
  git -C "$path" remote add upstream "https://github.com/someone/${name}.git"
  git -C "$path" config "url.file://${up_bare}.insteadOf" "https://github.com/someone/${name}.git"
  git -C "$path" push -q -f upstream HEAD:refs/heads/main
  git --git-dir="$up_bare" symbolic-ref HEAD refs/heads/main
  # Deliberately do NOT `git remote set-head upstream` → refs/remotes/upstream/HEAD stays UNSET.
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(14b) matching remote with UNSET tracking HEAD → ls-remote symref fallback names default → PROCEEDs" "0" "$rc"
  assert_contains "(14b) gate anchored via the ls-remote default-branch fallback" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (15) #102 — detached HEAD at the default commit must NOT fail for lacking a branch name. We check
# out the target in DETACHED HEAD state at the default-branch tip; the gate compares COMMITS (not
# branch names) so it proceeds normally.
# ---------------------------------------------------------------------------------
test_gate_detached_head_at_default_proceeds() {
  local repo; repo="$(make_target "detached-at-default")"
  commit_star "$repo" "### Ship v2 · status: **active** — our real integrated goal"
  # Detach HEAD at the current (default-branch) commit — no branch name.
  git -C "$repo" checkout -q --detach HEAD
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(15) detached HEAD at the default commit → gate PROCEEDs (compares commits, not branch names)" "0" "$rc"
  assert_contains "(15) detached-HEAD gate reached the verdict" "PROCEED" "$out"
}

# ---------------------------------------------------------------------------------
# (16) #102 — genuinely LOCAL / greenfield (no gh repo/remote at all): manager-review takes its
# VISIBLE local-default/HEAD fallback (LOGGED, never silent) and a committed active star STILL
# authorizes. Simulated via FAKE_GH_NO_REPO=1 (gh resolves no repo).
# ---------------------------------------------------------------------------------
test_gate_local_greenfield_visible_fallback_authorizes() {
  local repo; repo="$(make_target "local-greenfield")"
  commit_star "$repo" "### Ship the 0->1 scaffold · status: **active** — greenfield goal"
  local res rc out
  res="$(
    cd "$repo"
    FAKE_GH_NO_REPO=1 PATH="$fakebin:$PATH" bash "$manager_review" 1 2>&1
  )" && rc=0 || rc=$?
  # NOTE: with no gh repo, manager-review's own gh guard (`gh repo view`) exits first — the gate
  # cannot post to a non-existent issue. So the VISIBLE-local-fallback anchor path is exercised by
  # doctor (below); for manager-review the correct behavior with no gh repo is the early gh-guard
  # FAIL. Assert the gh-guard message (NOT a north-star authorization).
  assert_eq "(16) manager-review with no gh repo → early gh-guard FAIL (cannot post to a non-existent issue)" "1" "$rc"
  assert_contains "(16) gh-guard FAIL names the missing gh-recognized remote" "not inside a git repo with a gh-recognized remote" "$res"
}

# ---------------------------------------------------------------------------------
# (4g) #102 — doctor (h) diagnoses the SAME anchored source the gate authorizes on: the gh-bound
# remote's default branch, FETCHED FRESH. It logs the anchor source (never silent), and — like the
# gate — reads the FETCHED integrated commit, not a stale local remote-tracking cache. doctor's
# fallback (no gh repo / no matching remote) is VISIBLE (logged), not a hard fail.
# ---------------------------------------------------------------------------------

# (4g-i) doctor (h) on a remote-backed target LOGS the gh-bound fetched-fresh anchor line and
# PASSES on the real committed default-branch star.
test_doctor_h_anchor_logs_ghbound() {
  local repo; repo="$(make_target "doctor-anchor-ghbound")"
  commit_star "$repo" "### Ship v2 · status: **active** — real integrated star"
  local anchor; anchor="$(run_doctor_h_anchor "$repo")"
  assert_contains "(4g-i) doctor (h) logs the gh-bound fetched-fresh anchor (never silent)" "fetched fresh" "$anchor"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4g-i) doctor (h) PASSES on the anchored default-branch star" "pass:" "$line"
}

# (4g-ii) doctor (h) fetches fresh, not the stale cache: same setup as gate (12). Stale cache =
# placeholder; fresh remote = real star. doctor must diagnose the FRESH real star → PASS (a
# stale-cache read would WARN on the placeholder).
test_doctor_h_fetches_fresh_not_stale_cache() {
  local name="doctor-anchor-stale"
  local repo; repo="$(make_target "$name")"
  commit_star_raw "$repo" <<'STAR'
### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me
body
STAR
  # Advance the bare remote's default to a REAL star via a separate pusher (portable helper), so
  # the target's remote-tracking cache stays STALE at the placeholder.
  advance_remote_default "$name" "### Ship v2 · status: **active** — fresh integrated approved goal"
  local line; line="$(run_doctor_h "$repo")"
  assert_contains "(4g-ii) doctor (h) fetches fresh (not the stale placeholder cache) → PASSES on the integrated star" "pass:" "$line"
}

# (4g-iii) doctor (h) on a genuinely LOCAL target (no gh repo) uses the VISIBLE local-HEAD fallback
# and LOGS it (never silent). A committed active star still diagnoses as set (PASS).
test_doctor_h_local_fallback_visible() {
  local repo; repo="$(make_target "doctor-anchor-local")"
  commit_star "$repo" "### Ship v2 · status: **active** — local committed goal"
  local anchor line
  anchor="$(
    cd "$repo"
    FAKE_GH_NO_REPO=1 PATH="$fakebin:$PATH" bash "$doctor" 2>&1 | grep 'north-star anchor:' | head -n1 || true
  )"
  line="$(
    cd "$repo"
    FAKE_GH_NO_REPO=1 PATH="$fakebin:$PATH" bash "$doctor" 2>&1 | grep -E '^(pass|warn|fail): \(h\)' | head -n1 || true
  )"
  assert_contains "(4g-iii) doctor (h) logs the VISIBLE local HEAD fallback when no gh repo resolves" "local HEAD" "$anchor"
  assert_contains "(4g-iii) doctor (h) still PASSES on the committed active star via the local fallback" "pass:" "$line"
}

# ---------------------------------------------------------------------------------
# (17) #102 anchor-security sweep — FIX A/FIX 1: EFFECTIVE-URL IDENTITY GATE, FAIL-CLOSED. The remote
# is selected by URL, but the fetch goes BY NAME and applies `url.<other>.insteadOf`. The gate
# authorizes ONLY when the EFFECTIVE fetch URL is a NON-EMPTY GitHub id EQUAL to gh's. A rewrite that
# redirects the fetch to a DIFFERENT GitHub identity FAILs (read repo B, post to gh's repo A); a
# rewrite to a local path / file:// / ext:: (unprovable identity, normalizes empty) ALSO FAILs by
# default (round-2 — "empty ⇒ trusted" was the re-attack hole), and is allowed ONLY under the
# explicit FABRICA_ALLOW_LOCAL_MIRROR=1 opt-in. A same-identity transport rewrite (https↔ssh for the
# SAME repo, normalizes to the same id) PASSES.
# ---------------------------------------------------------------------------------

# (17z) UNIT — ghr_normalize_repo_id parses the URL AUTHORITY, not a path-embedded host, and rejects
# transport-helper / exotic schemes (#102 round-3 [P1]). This normalizer is the crux of the whole
# fail-closed guard: if it can be fooled into returning gh's `github.com/<owner>/<repo>` identity for
# a URL that actually fetches from a DIFFERENT host/transport, the guard blesses the wrong fetch.
# Deterministic + pure (no git/network): source the lib and call the function directly.
# norm <url> — source the lib in a subshell and print ghr_normalize_repo_id's output for <url>.
norm() {
  # shellcheck source=scripts/lib/gh-remote.sh
  ( . "$ghr_lib" && ghr_normalize_repo_id "$1" )
}

test_normalize_repo_id_authority_and_schemes() {
  local out

  # (17z-i) USERINFO-PATH TRICK: the real host is the authority (evil.example); `github.com` is only
  # in the PATH. The fix must read the host from the authority, so the result is NOT gh's github.com
  # identity — it carries the real host (evil.example), which fails the caller's equality check → the
  # guard FAILs closed. Assert the security property directly: it must NOT normalize to github.com/…
  out="$(norm "https://evil.example/x@github.com/acme/app.git")"
  case "$out" in
    github.com/*) failed=$((failed + 1)); echo "FAIL: (17z-i) userinfo-path trick MUST NOT normalize to a github.com identity"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17z-i) userinfo-path trick does not yield a github.com identity" ;;
  esac
  # And it reads the AUTHORITY (evil.example) as the host, not the path-embedded github.com.
  assert_eq "(17z-i) host is parsed from the authority (evil.example), not the path" "evil.example" "${out%%/*}"

  # (17z-ii) TRANSPORT-HELPER / EXOTIC SCHEMES → EMPTY (fail closed). `ext::…git@github.com:…` and
  # `fd::…` run an arbitrary transport; the scp-style branch used to wrongly extract `github.com`.
  assert_eq "(17z-ii) ext:: transport helper → empty" "" "$(norm "ext::sh -c git@github.com:acme/app.git")"
  assert_eq "(17z-ii) fd:: transport helper → empty" "" "$(norm "fd::17/foo")"
  assert_eq "(17z-ii) generic <helper>:: → empty" "" "$(norm "transport::whatever")"
  # An unsupported real scheme (e.g. file://) is also unprovable → empty.
  assert_eq "(17z-ii) file:// scheme → empty" "" "$(norm "file:///srv/mirror/widget.git")"
  assert_eq "(17z-ii) unknown scheme → empty" "" "$(norm "weird://github.com/o/r.git")"

  # (17z-iii) POSITIVE CONTROLS — genuine forms all normalize to the SAME github.com/o/r identity,
  # including a legit userinfo on the REAL github host, and an ssh URL with an explicit port.
  assert_eq "(17z-iii) https → github.com/o/r" "github.com/o/r" "$(norm "https://github.com/o/r.git")"
  assert_eq "(17z-iii) scp-style → github.com/o/r" "github.com/o/r" "$(norm "git@github.com:o/r.git")"
  assert_eq "(17z-iii) ssh:// → github.com/o/r" "github.com/o/r" "$(norm "ssh://git@github.com/o/r.git")"
  assert_eq "(17z-iii) https + legit userinfo (real github host) → github.com/o/r" "github.com/o/r" "$(norm "https://user@github.com/o/r.git")"
  assert_eq "(17z-iii) ssh:// with :port → github.com/o/r" "github.com/o/r" "$(norm "ssh://git@github.com:22/o/r.git")"

  # (17z-iv) https↔ssh SAME-repo normalization stays EQUAL (a legit transport swap must match).
  local a b c
  a="$(norm "https://github.com/o/r.git")"; b="$(norm "git@github.com:o/r.git")"; c="$(norm "ssh://git@github.com/o/r.git")"
  if [ "$a" = "$b" ] && [ "$b" = "$c" ] && [ -n "$a" ]; then
    passed=$((passed + 1)); echo "pass: (17z-iv) https/scp/ssh same-repo normalize equal ([$a])"
  else
    failed=$((failed + 1)); echo "FAIL: (17z-iv) https/scp/ssh same-repo must normalize equal"; echo "      a=[$a] b=[$b] c=[$c]"
  fi

  # (17z-v) PORT IS PART OF THE HOST IDENTITY (#102 round-3 [P2]). A NON-DEFAULT port must be kept so
  # a GHE host on :8443 does NOT falsely normalize equal to the same host on the scheme default;
  # the scheme's DEFAULT port is normalized away so legit same-repo comparisons still hold.
  # A non-default port is preserved as `<host>:<port>`.
  assert_eq "(17z-v) non-default port kept in identity" "ghe.example:8443/o/r" "$(norm "https://ghe.example:8443/o/r.git")"
  # …and is therefore NOT equal to the no-port identity for the same host+owner+repo.
  local p q
  p="$(norm "https://ghe.example:8443/o/r.git")"; q="$(norm "https://ghe.example/o/r.git")"
  if [ -n "$p" ] && [ "$p" != "$q" ]; then
    passed=$((passed + 1)); echo "pass: (17z-v) :8443 endpoint NOT equal to the no-port endpoint ([$p] != [$q])"
  else
    failed=$((failed + 1)); echo "FAIL: (17z-v) :8443 endpoint must NOT equal the no-port endpoint"; echo "      p=[$p] q=[$q]"
  fi
  # DEFAULT ports are normalized away → equal to the no-port form (per scheme).
  assert_eq "(17z-v) https default :443 == no-port" "github.com/o/r" "$(norm "https://github.com:443/o/r.git")"
  assert_eq "(17z-v) https default :443 equals explicit no-port form" "$(norm "https://github.com/o/r.git")" "$(norm "https://github.com:443/o/r.git")"
  assert_eq "(17z-v) ssh default :22 == no-port" "github.com/o/r" "$(norm "ssh://git@github.com:22/o/r.git")"
  # A NON-default ssh port is likewise preserved.
  assert_eq "(17z-v) non-default ssh port kept" "ghe.example:2222/o/r" "$(norm "ssh://git@ghe.example:2222/o/r.git")"
  # scp-style carries NO port, so it stays portless and still matches the portless https/ssh form.
  local s t
  s="$(norm "git@ghe.example:o/r.git")"; t="$(norm "https://ghe.example/o/r.git")"
  if [ -n "$s" ] && [ "$s" = "$t" ]; then
    passed=$((passed + 1)); echo "pass: (17z-v) scp-style (no port) equals portless https ([$s])"
  else
    failed=$((failed + 1)); echo "FAIL: (17z-v) scp-style (no port) must equal portless https"; echo "      s=[$s] t=[$t]"
  fi
}

# (17a) UNIT — ghr_assert_effective_identity directly, FAIL-CLOSED (#102 round-2 FIX 1). Deterministic
# (no network): we only vary the insteadOf (and the FABRICA_ALLOW_LOCAL_MIRROR opt-in) and check the
# helper's rc + message, since it is a pure derivation over `git remote get-url`. Covers: no insteadOf
# → OK; cross-repo GitHub substitution → FAIL (even under the opt-in); same-identity https↔ssh rewrite
# → OK; local file:// mirror (unprovable identity) → FAIL by default, OK only under the explicit opt-in.
# run_effid <repo_dir> <gh_id> [allow_local_mirror] — source the lib in a subshell cd'd into
# <repo_dir> and run ghr_assert_effective_identity against `origin`; echo "<rc>|<stderr>". The
# optional third arg sets FABRICA_ALLOW_LOCAL_MIRROR for THAT call (default unset → fail-closed). A
# standalone helper (like run_gate) so the subshell reads only its OWN positional args — no outer
# `$repo` shared across the subshell boundary, so shellcheck's SC2030/SC2031 heuristic never fires.
run_effid() {
  local rd="$1" ghid="$2" allow="${3:-}" rc out
  # A PREFIX assignment on the function call scopes the opt-in to that single invocation (no subshell
  # var-modification for shellcheck to flag), while still exercising the flag the callers vary.
  # shellcheck source=scripts/lib/gh-remote.sh
  out="$( cd "$rd" && . "$ghr_lib" && FABRICA_ALLOW_LOCAL_MIRROR="$allow" ghr_assert_effective_identity origin "$ghid" 2>&1 )" && rc=0 || rc=$?
  printf '%s|%s' "$rc" "$out"
}

test_effective_identity_helper_unit() {
  local repo="$tmproot/effid-unit"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" remote add origin "https://github.com/someone/widget.git"
  local gh_id="github.com/someone/widget"
  local res rc out

  # (i) no insteadOf → effective == configured (same identity) → OK (rc 0).
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-i) no insteadOf → effective identity matches gh → OK (rc 0)" "0" "$rc"

  # (ii) CROSS-REPO GitHub substitution insteadOf → effective is a DIFFERENT github identity → FAIL.
  git -C "$repo" config "url.https://github.com/attacker/evil.git.insteadOf" "https://github.com/someone/widget.git"
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-ii) cross-repo insteadOf (github.com/attacker/evil) → helper FAILs (rc 1)" "1" "$rc"
  assert_contains "(17a-ii) FAIL cites the different fetch-URL identity" "DIFFERENT repo identity" "$out"
  assert_contains "(17a-ii) FAIL names the substituted identity" "github.com/attacker/evil" "$out"
  # A cross-repo GitHub substitution FAILs EVEN under the local-mirror opt-in (the opt-in is only for
  # unprovable local transports, never for redirecting to a different GitHub repo).
  res="$(run_effid "$repo" "$gh_id" 1)"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-ii) cross-repo insteadOf FAILs even with FABRICA_ALLOW_LOCAL_MIRROR=1 (rc 1)" "1" "$rc"
  git -C "$repo" config --unset "url.https://github.com/attacker/evil.git.insteadOf"

  # (iii) SAME-IDENTITY transport rewrite (https→ssh for the SAME repo) → normalizes to the same id → OK.
  git -C "$repo" config "url.git@github.com:someone/widget.git.insteadOf" "https://github.com/someone/widget.git"
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-iii) same-identity https→ssh insteadOf → helper OK (rc 0)" "0" "$rc"
  git -C "$repo" config --unset "url.git@github.com:someone/widget.git.insteadOf"

  # (iv) LOCAL file:// mirror (unprovable GitHub identity) → FAIL-CLOSED BY DEFAULT (round-2 FIX 1:
  # empty is no longer trusted — an attacker's `url.<local>.insteadOf` could silently redirect the
  # fetch). It is allowed ONLY under the explicit FABRICA_ALLOW_LOCAL_MIRROR=1 opt-in.
  git -C "$repo" config "url.file:///srv/mirror/widget.git.insteadOf" "https://github.com/someone/widget.git"
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-iv) local file:// mirror insteadOf → FAILs closed by default (rc 1)" "1" "$rc"
  assert_contains "(17a-iv) FAIL explains the unprovable transport + names the opt-in" "FABRICA_ALLOW_LOCAL_MIRROR=1" "$out"
  res="$(run_effid "$repo" "$gh_id" 1)"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-iv) local file:// mirror insteadOf → OK under the explicit opt-in (rc 0)" "0" "$rc"
  git -C "$repo" config --unset "url.file:///srv/mirror/widget.git.insteadOf"

  # (v) LOCAL PATH substitution (a bare absolute path, normalizes empty) → FAIL-CLOSED by default.
  git -C "$repo" config "url./srv/mirror/widget.git.insteadOf" "https://github.com/someone/widget.git"
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-v) local-PATH insteadOf → FAILs closed by default (rc 1)" "1" "$rc"
  git -C "$repo" config --unset "url./srv/mirror/widget.git.insteadOf"

  # (vi) ext:: exotic transport substitution (normalizes empty) → FAIL-CLOSED by default.
  git -C "$repo" config "url.ext::sh -c evil.insteadOf" "https://github.com/someone/widget.git"
  res="$(run_effid "$repo" "$gh_id")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17a-vi) ext:: transport insteadOf → FAILs closed by default (rc 1)" "1" "$rc"
  git -C "$repo" config --unset "url.ext::sh -c evil.insteadOf"
}

# (17b) END-TO-END — a cross-repo-substitution insteadOf makes the GATE FAIL (does NOT fetch/anchor
# the other repo). The target's origin matches gh's identity (so selection succeeds), but an
# insteadOf redirects the fetch to a DIFFERENT github identity. The gate must FAIL at the
# effective-identity check, BEFORE fetching, and never reach a Codex verdict.
test_gate_insteadof_cross_repo_fails() {
  local name="insteadof-cross-repo"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  # A committed real star locally (so ONLY the insteadOf guard — not a missing star — can be the FAIL).
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  # origin matches gh's identity (someone/<basename>) so ghr_select_remote picks it...
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  # ...but an insteadOf redirects the FETCH to a DIFFERENT github identity (the attack).
  git -C "$path" config "url.https://github.com/attacker/evil.git.insteadOf" "https://github.com/someone/${name}.git"
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17b) cross-repo insteadOf → gate FAILs (does NOT fetch/anchor the substituted repo)" "1" "$rc"
  assert_contains "(17b) FAIL cites the insteadOf repo-substitution" "DIFFERENT repo identity" "$out"
  # It must NOT have reached a Codex verdict off the substituted repo.
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (17b) gate must NOT reach a verdict under a cross-repo insteadOf"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17b) gate did NOT authorize under the cross-repo insteadOf" ;;
  esac
}

# (17c) END-TO-END — a deliberate local-mirror transport insteadOf still WORKS UNDER THE OPT-IN: the
# hermetic targets (built by make_target) rewrite the configured https identity url to a local file://
# bare for transport. The effective url is a local mirror (unprovable GitHub identity) — which now
# FAILs closed by default (round-2 FIX 1) — so the operator opts in with FABRICA_ALLOW_LOCAL_MIRROR=1
# (set by run_gate for the whole hermetic suite). This is the positive control: the opt-in lets the
# legitimate local mirror the loop depends on proceed, while the DEFAULT stays fail-closed (17e).
test_gate_insteadof_same_identity_transport_works() {
  local repo; repo="$(make_target "insteadof-transport-ok")"
  commit_star "$repo" "### Ship v2 · status: **active** — real committed star via transport insteadOf"
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17c) local-mirror transport insteadOf UNDER the opt-in → gate PROCEEDs (not falsely FAILed)" "0" "$rc"
  assert_contains "(17c) gate proceeded under the legitimate local-mirror opt-in" "PROCEED" "$out"
}

# (17e) END-TO-END — WITHOUT the opt-in, the hermetic local-mirror target FAILs CLOSED (round-2
# FIX 1: "empty ⇒ trusted" is the re-attack hole). Same setup as 17c, but run with
# FABRICA_ALLOW_LOCAL_MIRROR=0 so the effective file:// url is unprovable → gate FAILs before
# fetching, never reaching a verdict. This is the security control for FIX 1 (the insteadOf→file://
# case); 17c is its opt-in counterpart.
test_gate_insteadof_local_mirror_no_optin_fails() {
  local repo; repo="$(make_target "insteadof-local-nooptin")"
  commit_star "$repo" "### Ship v2 · status: **active** — real committed star behind a local mirror"
  local res rc out
  res="$( FABRICA_ALLOW_LOCAL_MIRROR=0 run_gate "$repo" )"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17e) local-mirror insteadOf WITHOUT the opt-in → gate FAILs closed (rc 1)" "1" "$rc"
  assert_contains "(17e) FAIL explains the unprovable transport + names the opt-in" "FABRICA_ALLOW_LOCAL_MIRROR=1" "$out"
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (17e) gate must NOT reach a verdict on an unprovable local mirror without the opt-in"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17e) gate did NOT authorize on the unprovable local mirror without the opt-in" ;;
  esac
}

# (17f) END-TO-END — insteadOf → ext:: exotic transport WITHOUT the opt-in FAILs closed too (the
# other unprovable-transport class in FIX 1). The configured origin matches gh's identity (so
# selection succeeds), but the effective fetch URL is `ext::sh -c …` — normalizes empty → FAIL.
test_gate_insteadof_ext_transport_no_optin_fails() {
  local name="insteadof-ext-nooptin"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  git -C "$path" config "url.ext::sh -c evil.insteadOf" "https://github.com/someone/${name}.git"
  local res rc out
  res="$( FABRICA_ALLOW_LOCAL_MIRROR=0 run_gate "$path" )"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17f) ext:: transport insteadOf WITHOUT the opt-in → gate FAILs closed (rc 1)" "1" "$rc"
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (17f) gate must NOT reach a verdict on an ext:: transport"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17f) gate did NOT authorize on the ext:: transport" ;;
  esac
}

# (17g) END-TO-END — a SAME-repo https→ssh insteadOf (a legit transport swap, NOT a local mirror)
# PROCEEDs even WITHOUT the local-mirror opt-in: the effective url normalizes to a NON-EMPTY GitHub
# id EQUAL to gh's, so it is provably the same repo. We can't fetch over real ssh hermetically, so
# this asserts at the assert-helper level (the gate's authorization decision) — the fetch itself is
# covered by the file:// transport cases. Uses the ssh→file:// chain so the effective transport is
# still local (fetchable) while a SEPARATE assertion confirms the ssh identity normalizes equal.
test_gate_insteadof_https_ssh_same_repo_proceeds() {
  local name="insteadof-https-ssh"
  local repo; repo="$(make_target "$name")"
  commit_star "$repo" "### Ship v2 · status: **active** — real star, https↔ssh same-repo swap"
  # The effective-identity helper must treat a same-repo ssh rewrite as provably-equal (rc 0) with
  # NO opt-in: point origin's https identity at the ssh form of the SAME repo.
  local sshrepo="$tmproot/$name-ssh-id"
  mkdir -p "$sshrepo"
  git -C "$sshrepo" init -q -b main
  git -C "$sshrepo" remote add origin "https://github.com/someone/${name}.git"
  git -C "$sshrepo" config "url.git@github.com:someone/${name}.git.insteadOf" "https://github.com/someone/${name}.git"
  local res rc
  res="$(run_effid "$sshrepo" "github.com/someone/${name}")"; rc="${res%%|*}"
  assert_eq "(17g) https→ssh SAME-repo insteadOf → authorized with NO opt-in (rc 0)" "0" "$rc"
  # And the full gate PROCEEDs on the hermetic same-repo target (local transport, opt-in via run_gate).
  res="$(run_gate "$repo")"; rc="${res%%|*}"
  assert_eq "(17g) same-repo target → gate PROCEEDs" "0" "$rc"
}

# (17h) END-TO-END — the USERINFO-PATH TRICK (#102 round-3 [P1]): an insteadOf rewrites origin's
# configured (matching) https url to `https://evil.example/x@github.com/<owner>/<repo>.git`. The
# naive parser read the path-embedded `github.com` as the host and blessed the fetch with gh's
# identity — while `git fetch` actually contacts evil.example. The fixed parser reads the host from
# the AUTHORITY (evil.example ≠ gh's github.com), so the effective identity does NOT equal gh's →
# the gate FAILs closed before any fetch, never reaching a Codex verdict. Run with the local-mirror
# opt-in OFF so the ONLY thing that can save it is correct host parsing (a cross-HOST github id, not
# an empty/unprovable one). Even under the opt-in a DIFFERING non-empty github id would still FAIL,
# but here evil.example is not a github id at all — the point is it must never match gh's.
test_gate_insteadof_userinfo_path_host_trick_fails() {
  local name="insteadof-userinfo-path"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  # origin matches gh's identity (someone/<basename>) so ghr_select_remote picks it...
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  # ...but an insteadOf redirects the FETCH to a URL whose REAL host is evil.example, with a
  # path-embedded `@github.com` decoy (the userinfo-path trick). Correct authority parsing → the
  # effective id's host is evil.example, not gh's github.com → FAIL closed.
  git -C "$path" config "url.https://evil.example/x@github.com/someone/${name}.git.insteadOf" "https://github.com/someone/${name}.git"
  local res rc out
  res="$( FABRICA_ALLOW_LOCAL_MIRROR=0 run_gate "$path" )"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(17h) userinfo-path host trick → gate FAILs closed (host read from authority, not path)" "1" "$rc"
  # The FAIL must come from the IDENTITY gate (host parsed as evil.example ≠ gh's github.com), BEFORE
  # any fetch — not merely because the bogus host was unreachable. Assert the effective id it derived
  # carries the real authority host (evil.example), proving the parser did NOT read the path-embedded
  # github.com. (Against the pre-fix parser this would have normalized to gh's id and PASSED the gate.)
  assert_contains "(17h) FAIL is the identity gate, citing the real authority host (evil.example)" "evil.example" "$out"
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (17h) gate must NOT authorize on a userinfo-path host trick"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17h) gate did NOT authorize on the userinfo-path host trick" ;;
  esac
}

# (17d) doctor (h) mirrors FIX A: a cross-repo-substitution insteadOf → doctor WARNs (the gate FAILs)
# and falls back to the visible local-HEAD anchor (doctor only diagnoses). We build a target whose
# origin matches gh's identity but whose fetch is redirected to a DIFFERENT github identity.
test_doctor_h_insteadof_cross_repo_warns() {
  local name="doctor-insteadof-cross-repo"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  git -C "$path" config "url.https://github.com/attacker/evil.git.insteadOf" "https://github.com/someone/${name}.git"
  local out warnline anchorline
  out="$(
    cd "$path"
    PATH="$fakebin:$PATH" bash "$doctor" 2>&1 || true
  )"
  warnline="$(printf '%s' "$out" | grep -E '^warn: \(h\).*insteadOf' | head -n1 || true)"
  anchorline="$(printf '%s' "$out" | grep 'north-star anchor:' | head -n1 || true)"
  assert_contains "(17d) doctor (h) WARNs on a cross-repo insteadOf rewrite" "insteadOf rewrite redirecting its fetch" "$warnline"
  assert_contains "(17d) doctor (h) falls back to the visible LOCAL HEAD anchor (never fetches the substituted repo)" "local HEAD" "$anchorline"
}

# (17i) doctor (h) on a GH-BOUND run whose gh identity has NO matching configured remote → WARN, not
# a silent `pass:` (#102 round-3 [P2]). This is the exact scenario in which the gate FAILs closed
# ("no configured git remote matches"); with a committed active local star, doctor used to silently
# anchor to local HEAD and print `pass:`, advertising a ready gate for a setup that can't run. Now it
# WARNs before the visible local-HEAD fallback. gh resolves someone/<basename> (fake gh reads the top-
# level basename since origin's identity is someone-else/…), but origin normalizes to a DIFFERENT id →
# no match. (Contrast test_doctor_h_local_fallback_visible: NO gh repo at all → visible fallback, no
# such WARN.)
test_doctor_h_ghbound_no_matching_remote_warns() {
  local name="doctor-no-matching-remote"
  local path="$tmproot/$name"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed local star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  # origin points at a DIFFERENT repo identity than gh resolves (gh → someone/<basename>).
  git -C "$path" remote add origin "https://github.com/someone-else/unrelated.git"
  local out hline warnline anchorline
  out="$(
    cd "$path"
    PATH="$fakebin:$PATH" bash "$doctor" 2>&1 || true
  )"
  # The (h) verdict must be a WARN (not pass:) for this gh-bound / no-matching-remote setup.
  hline="$(printf '%s' "$out" | grep -E '^(pass|warn|fail): \(h\)' | head -n1 || true)"
  case "$hline" in
    warn:*) passed=$((passed + 1)); echo "pass: (17i) doctor (h) WARNs (not pass:) on a gh-bound run with no matching remote" ;;
    *) failed=$((failed + 1)); echo "FAIL: (17i) doctor (h) must WARN (not pass:) on a gh-bound run with no matching remote"; echo "      actual: [$hline]" ;;
  esac
  warnline="$(printf '%s' "$out" | grep -E '^warn: \(h\).*no configured git remote matches' | head -n1 || true)"
  assert_contains "(17i) WARN names the gh-bound no-matching-remote gap (mirrors the gate FAIL)" "no configured git remote matches" "$warnline"
  # It still degrades VISIBLY to the local-HEAD anchor (doctor only diagnoses).
  anchorline="$(printf '%s' "$out" | grep 'north-star anchor:' | head -n1 || true)"
  assert_contains "(17i) doctor still falls back to the VISIBLE local HEAD anchor" "local HEAD" "$anchorline"
}

# (17j) doctor.sh <owner>/<repo> from a NON-target checkout must SKIP the anchor-resolution/fetch
# block (#102 round-3 [P2]). Pre-fix, the anchor block resolved+fetched the CWD repo's default
# branch (network, FETCH_HEAD/private-ref writes, WRONG-repo anchor warnings) BEFORE the later
# "north star not checked for the target" guard. The fix gates the whole block on
# ns_h_cwd_is_target: when the cwd is NOT the passed target, skip it entirely — no fetch, no
# wrong-repo anchor warning — and still report the "not checked for <target>" outcome. We run a
# normal remote-backed checkout (its own gh identity / origin / fetchable default) but pass a
# DIFFERENT target slug, so cwd != target. The observable proof the block was skipped: the anchor
# line stays "local HEAD" (a fetch would have logged "fetched fresh"), and no wrong-repo anchor
# warning is emitted.
test_doctor_target_arg_non_target_skips_anchor() {
  local name="doctor-nontarget-skip"
  local repo; repo="$(make_target "$name")"
  commit_star "$repo" "### Ship v2 · status: **active** — the checkout's own committed star"
  local target="someone/some-other-repo"   # deliberately NOT this checkout's slug (someone/$name)
  local out anchorline hline
  out="$(
    cd "$repo"
    PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR=1 bash "$doctor" "$target" 2>&1 || true
  )"
  anchorline="$(printf '%s' "$out" | grep 'north-star anchor:' | head -n1 || true)"
  # Anchor block skipped → no fetch → the anchor stays the local-HEAD default (never "fetched fresh").
  assert_contains "(17j) doctor from a non-target checkout does NOT fetch (anchor stays local HEAD)" "local HEAD" "$anchorline"
  case "$anchorline" in
    *"fetched fresh"*) failed=$((failed + 1)); echo "FAIL: (17j) doctor must NOT fetch the cwd repo's default when cwd != target"; echo "      actual: [$anchorline]" ;;
    *) passed=$((passed + 1)); echo "pass: (17j) doctor skipped the anchor fetch when cwd != target" ;;
  esac
  # No wrong-repo anchor warning (the identity / default-branch / fetch WARNs the block emits) fired.
  case "$out" in
    *"warn: (h)"*"insteadOf"*|*"warn: (h)"*"no configured git remote matches"*|*"warn: (h)"*"could not fetch remote"*|*"warn: (h) gh could not resolve"*)
      failed=$((failed + 1)); echo "FAIL: (17j) doctor emitted a WRONG-repo anchor warning for the cwd repo when cwd != target"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (17j) doctor emitted no wrong-repo anchor warning when cwd != target" ;;
  esac
  # It still reports the real outcome: "north star not checked for <target>".
  hline="$(printf '%s' "$out" | grep -E '^warn: \(h\).*not checked for' | head -n1 || true)"
  assert_contains "(17j) doctor still reports the 'not checked for <target>' outcome" "not checked for $target" "$hline"
}

# (17k) doctor (h): gh resolves the repo AND a remote matches, but the default branch is
# unresolvable via gh AND the local fallback is ALSO empty → WARN, not a silent `pass:` (#102
# round-3 [P2]). Pre-fix, doctor fell through silently to `anchor_source="local HEAD"` and could
# print `pass:` for a committed local star even though the gate (manager-review.sh) FAILs closed
# for this gh-bound repo. Now it WARNs on the empty fallback before diagnosing against local HEAD.
# Hermetic setup: origin matches gh's identity (so a remote is selected), FAKE_GH_NO_DEFAULT=1
# makes gh return an empty defaultBranchRef, and the bare remote's HEAD points at an UNBORN branch
# (with no local origin/HEAD symref) so ghr_remote_default_branch's ls-remote AND local-symref
# fallback are BOTH empty — the empty-fallback path.
test_doctor_h_empty_default_fallback_warns() {
  local name="doctor-empty-default"
  local path="$tmproot/$name"
  local bare="$remotes_root/${name}.git"
  mkdir -p "$path"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — real committed local star\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "set star"
  # origin matches gh's identity (fake gh reads it → someone/<name>) via the insteadOf transport.
  git init -q --bare "$bare"
  # Bare HEAD → an UNBORN branch that no one pushes, so `ls-remote --symref origin HEAD` is EMPTY
  # (the local fallback source). No local refs/remotes/origin/HEAD symref is set → that fallback is
  # empty too. Together: ghr_remote_default_branch returns empty.
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/ghost
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  git -C "$path" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
  local out hline warnline anchorline
  out="$(
    cd "$path"
    FAKE_GH_NO_DEFAULT=1 PATH="$fakebin:$PATH" FABRICA_ALLOW_LOCAL_MIRROR=1 bash "$doctor" 2>&1 || true
  )"
  # A WARN must be present (not a silent pass:). run_doctor_h-style: the first (h) line is the WARN.
  hline="$(printf '%s' "$out" | grep -E '^(pass|warn|fail): \(h\)' | head -n1 || true)"
  case "$hline" in
    warn:*) passed=$((passed + 1)); echo "pass: (17k) doctor (h) WARNs (not a silent pass:) on the empty default-branch fallback" ;;
    *) failed=$((failed + 1)); echo "FAIL: (17k) doctor (h) must WARN (not silent pass:) when the default branch AND local fallback are both empty"; echo "      actual: [$hline]" ;;
  esac
  warnline="$(printf '%s' "$out" | grep -E '^warn: \(h\).*no local fallback default was available' | head -n1 || true)"
  assert_contains "(17k) WARN cites the empty default-branch fallback (mirrors the gate FAIL)" "no local fallback default was available" "$warnline"
  # It still degrades VISIBLY to the local-HEAD anchor (doctor only diagnoses).
  anchorline="$(printf '%s' "$out" | grep 'north-star anchor:' | head -n1 || true)"
  assert_contains "(17k) doctor still falls back to the VISIBLE local HEAD anchor" "local HEAD" "$anchorline"
}

# ---------------------------------------------------------------------------------
# (18) #102 anchor-security sweep — FIX B/FIX 2: the default-branch NAME is resolved AUTHORITATIVELY
# from gh (`gh repo view --json defaultBranchRef`, the SAME binding the verdict posts to), NOT the
# stale/spoofable local refs/remotes/<remote>/HEAD and NOT ls-remote off the (insteadOf-redirectable)
# selected remote. The fake gh reports the CURRENT server-side default (hermetically, the bare repo's
# HEAD), so a stale/spoofed LOCAL symref never changes the gate's anchor. If gh can't resolve the
# default on a gh-bound run, the gate FAILs closed (18d) — no local-symref authorization fallback.
# ---------------------------------------------------------------------------------

# (18a) DEFAULT-BRANCH REPOINT — the remote's default was `develop`, later repointed to `main`
# (where the real star lives). The target's local refs/remotes/origin/HEAD still names the STALE
# `develop` (fetch never refreshes it). If the gate trusted the local symref it would anchor to
# develop (a placeholder star) and FAIL; gh's defaultBranchRef names the CURRENT default (main, real
# star) → PROCEED.
test_gate_default_repoint_uses_lsremote_not_stale_symref() {
  local name="default-repoint"
  local path="$tmproot/$name"
  local bare="$remotes_root/${name}.git"
  mkdir -p "$path"
  git init -q --bare "$bare"
  git -C "$path" init -q -b develop
  git -C "$path" commit -q --allow-empty -m init
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  git -C "$path" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
  # develop carries a PLACEHOLDER star; push it and make the remote default = develop.
  mkdir -p "$path/.fabrica"
  printf '### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "develop placeholder star"
  git -C "$path" push -q -f origin develop:refs/heads/develop
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/develop
  # Populate the target's LOCAL refs/remotes/origin/HEAD = develop (via set-head), then it goes stale.
  git -C "$path" fetch -q origin
  git -C "$path" remote set-head origin develop >/dev/null 2>&1 || true
  # Now REPOINT the remote default to `main` with the REAL star (out of band; local symref stays stale).
  git -C "$path" checkout -q -b main
  printf '### Ship v2 by Q3 · status: **active** — the real integrated goal on the NEW default\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "main real star"
  git -C "$path" push -q -f origin main:refs/heads/main
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main   # remote default repointed → main
  # The target's local refs/remotes/origin/HEAD still says develop (stale). Confirm (belt-and-suspenders).
  local local_head; local_head="$(git -C "$path" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  assert_eq "(18a) local origin/HEAD is STALE at develop (fetch never refreshed it)" "refs/remotes/origin/develop" "$local_head"
  # The gate must anchor to the CURRENT default (main, real star) via gh's defaultBranchRef → PROCEED.
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(18a) default repoint develop→main: gate anchors to CURRENT default via gh → PROCEEDs" "0" "$rc"
  assert_contains "(18a) gate debated the current-default (main) real star, not the stale develop placeholder" "PROCEED" "$out"
}

# (18b) SPOOFED LOCAL SYMREF — the remote default is `main` (real star), but a locally-spoofed
# refs/remotes/origin/HEAD points at a `sneaky` branch carrying a placeholder. gh's defaultBranchRef
# (server-side, not the local symref) names the real default → PROCEED (a symref-trusting gate would
# anchor to `sneaky` and FAIL on its placeholder).
test_gate_spoofed_local_symref_ignored() {
  local name="spoofed-symref"
  local path="$tmproot/$name"
  local bare="$remotes_root/${name}.git"
  mkdir -p "$path"
  git init -q --bare "$bare"
  git -C "$path" init -q -b main
  git -C "$path" commit -q --allow-empty -m init
  git -C "$path" remote add origin "https://github.com/someone/${name}.git"
  git -C "$path" config "url.file://${bare}.insteadOf" "https://github.com/someone/${name}.git"
  # main = the REAL star; push it and make it the remote default.
  mkdir -p "$path/.fabrica"
  printf '### Ship v2 · status: **active** — the real integrated star on main\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "main real star"
  git -C "$path" push -q -f origin main:refs/heads/main
  git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
  # Create a `sneaky` branch with a PLACEHOLDER star, push it, and SPOOF the local symref at it.
  git -C "$path" checkout -q -b sneaky
  printf '### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me\nbody\n' > "$path/.fabrica/north-star.md"
  git -C "$path" add .fabrica/north-star.md
  git -C "$path" commit -q -m "sneaky placeholder star"
  git -C "$path" push -q -f origin sneaky:refs/heads/sneaky
  git -C "$path" fetch -q origin
  # Locally SPOOF refs/remotes/origin/HEAD → sneaky (the attack the fix defends against).
  git -C "$path" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/sneaky
  git -C "$path" checkout -q main
  local res rc out
  res="$(run_gate "$path")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(18b) spoofed local origin/HEAD → gate ignores it, anchors to the real default via gh → PROCEEDs" "0" "$rc"
  assert_contains "(18b) gate anchored to the real default (main), not the spoofed sneaky placeholder" "PROCEED" "$out"
}

# (18d) GH CANNOT RESOLVE THE DEFAULT ON A GH-BOUND RUN → gate FAILs CLOSED (round-2 FIX 2: no
# local-symref authorization fallback). We build a normal remote-backed target (origin matches gh's
# identity, real committed star, so ONLY the unresolvable default — not a missing star/remote — can
# be the FAIL), but make the fake gh return an EMPTY defaultBranchRef via FAKE_GH_NO_DEFAULT=1. The
# gate must FAIL with the "gh could not resolve the default branch" message and never reach a verdict.
test_gate_gh_no_default_branch_fails_closed() {
  local name="gh-no-default"
  local repo; repo="$(make_target "$name")"
  commit_star "$repo" "### Ship v2 · status: **active** — real committed star (default unresolvable via gh)"
  local res rc out
  res="$( FAKE_GH_NO_DEFAULT=1 run_gate "$repo" )"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(18d) gh can't resolve default branch on a gh-bound run → gate FAILs closed (rc 1)" "1" "$rc"
  assert_contains "(18d) FAIL cites gh's unresolved default branch (no local-symref authorization)" "could not resolve the default branch" "$out"
  case "$out" in
    *PROCEED*) failed=$((failed + 1)); echo "FAIL: (18d) gate must NOT reach a verdict when gh can't resolve the default"; echo "      actual: [$out]" ;;
    *) passed=$((passed + 1)); echo "pass: (18d) gate did NOT authorize when gh can't resolve the default branch" ;;
  esac
}

# run_default_branch <repo_dir> — source the lib in a subshell cd'd into <repo_dir> and echo
# ghr_remote_default_branch's result for `origin`. Standalone (like run_gate/run_effid) so the
# subshell reads only its own positional arg (no shared outer var → no SC2030/SC2031).
run_default_branch() {
  local rd="$1"
  # shellcheck source=scripts/lib/gh-remote.sh
  ( cd "$rd" && . "$ghr_lib" && ghr_remote_default_branch origin )
}

# (18c) DIAGNOSTIC-ONLY OFFLINE FALLBACK — ghr_remote_default_branch (doctor's local fallback, NOT
# the gate's authorization source) falls back to the LOCAL refs/remotes/<remote>/HEAD symref when the
# remote read is unavailable. UNIT-level (deterministic): a repo with a bad remote URL (ls-remote
# fails) but a populated local symref → the helper returns the local default name; with NEITHER
# available → empty. (The GATE never uses this — it takes the NAME from gh; see 18a/18b/18d.)
test_default_branch_offline_local_fallback_unit() {
  local repo="$tmproot/offline-fallback-unit"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" commit -q --allow-empty -m init
  # A remote whose URL is unreachable (a nonexistent local path) so ls-remote FAILS. Build a
  # refs/remotes/origin/* + symref by hand so the offline fallback has something to read.
  git -C "$repo" remote add origin "file:///nonexistent/definitely-not-a-repo.git"
  git -C "$repo" update-ref refs/remotes/origin/main "$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  local got
  got="$(run_default_branch "$repo")"
  assert_eq "(18c) offline (ls-remote fails) → helper falls back to the LOCAL symref default name" "main" "$got"
  # With the local symref removed too → empty (nothing to resolve).
  git -C "$repo" symbolic-ref -d refs/remotes/origin/HEAD
  got="$(run_default_branch "$repo")"
  assert_eq "(18c) offline AND no local symref → helper returns empty" "" "$got"
}

# ---------------------------------------------------------------------------------
# (20) #102 anchor-security sweep — FIX 3: SELECTION AVAILABILITY. ghr_select_remote matches the
# CONFIGURED url first; if it does NOT normalize to a GitHub identity (empty — an SSH host-alias or
# shorthand), it falls back to the EFFECTIVE url (insteadOf-applied) for SELECTION. This restores the
# SSH-alias case round-1 broke (configured-url-only selection). Safety is unaffected: the
# effective-identity guard (FIX 1) still gates the FETCH. UNIT-level on ghr_select_remote directly.
# ---------------------------------------------------------------------------------

# run_select <repo_dir> <gh_id> — source the lib in a subshell cd'd into <repo_dir> and echo
# ghr_select_remote's result. Standalone (like run_effid) so no outer var crosses the subshell.
run_select() {
  local rd="$1" ghid="$2"
  # shellcheck source=scripts/lib/gh-remote.sh
  ( cd "$rd" && . "$ghr_lib" && ghr_select_remote "$ghid" )
}

test_select_remote_ssh_alias_effective_fallback() {
  local gh_id="github.com/someone/widget"

  # (20a) CONFIGURED url normalizes to gh's id (the common case) → selected by the configured match.
  local r1="$tmproot/select-configured"
  mkdir -p "$r1"; git -C "$r1" init -q -b main
  git -C "$r1" remote add origin "https://github.com/someone/widget.git"
  assert_eq "(20a) configured url matches gh id → origin selected" "origin" "$(run_select "$r1" "$gh_id")"

  # (20b) CONFIGURED url is an SSH HOST-ALIAS (`myalias:owner/repo`) that does NOT normalize to a
  # GitHub id; an insteadOf expands it so the EFFECTIVE url resolves to gh's repo. Round-1
  # (configured-url-only) would NOT select it; FIX 3 falls back to the effective url → selected.
  local r2="$tmproot/select-ssh-alias"
  mkdir -p "$r2"; git -C "$r2" init -q -b main
  git -C "$r2" remote add origin "myalias:someone/widget.git"
  # Sanity: the configured alias alone does NOT normalize (empty), so selection MUST use the fallback.
  git -C "$r2" config "url.https://github.com/someone/widget.git.insteadOf" "myalias:someone/widget.git"
  assert_eq "(20b) SSH-alias configured url + effective→gh insteadOf → origin selected via effective fallback" "origin" "$(run_select "$r2" "$gh_id")"

  # (20c) NEITHER configured NOR effective url resolves to gh's id → NOT selected (empty), so the
  # gh-bound caller FAILs closed (no false selection of an unrelated remote).
  local r3="$tmproot/select-none"
  mkdir -p "$r3"; git -C "$r3" init -q -b main
  git -C "$r3" remote add origin "https://github.com/other/thing.git"
  assert_eq "(20c) no remote resolves to gh id (configured or effective) → nothing selected" "" "$(run_select "$r3" "$gh_id")"
}

# ---------------------------------------------------------------------------------
# (19) #102 anchor-security sweep — FIX C: `--refmap=` — the anchor fetch writes ONLY the private
# per-run ref; the operator's remote-tracking refs (refs/remotes/<remote>/* and .../HEAD) are
# UNCHANGED after a gate run, and the private per-run anchor ref is cleaned up.
# ---------------------------------------------------------------------------------
test_gate_no_ref_mutation_after_run() {
  local name="no-ref-mutation"
  local repo; repo="$(make_target "$name")"
  # main = a PLACEHOLDER star locally-cached, then advance the remote OUT OF BAND to a REAL star so a
  # tracking-ref-mutating fetch WOULD move refs/remotes/origin/main (making the mutation observable).
  commit_star_raw "$repo" <<'STAR'
### Placeholder · status: **active** · <!-- fabrica-shipped-default --> replace me
body
STAR
  # Populate the local tracking cache at the placeholder tip.
  git -C "$repo" fetch -q origin
  local track_before head_before
  track_before="$(git -C "$repo" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  head_before="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  # Advance the remote default to a REAL star via a separate pusher; the target's cache stays behind.
  advance_remote_default "$name" "### Ship v2 · status: **active** — fresh integrated star"
  # Run the gate: it fetches the fresh real star (→ PROCEED) but must NOT move the tracking refs.
  local res rc out
  res="$(run_gate "$repo")"; rc="${res%%|*}"; out="${res#*|}"
  assert_eq "(19) gate proceeds on the freshly-fetched real star" "0" "$rc"
  assert_contains "(19) gate reached the verdict" "PROCEED" "$out"
  # Tracking refs must be UNCHANGED (still the stale placeholder tip), proving --refmap= isolation.
  local track_after head_after
  track_after="$(git -C "$repo" rev-parse refs/remotes/origin/main 2>/dev/null || true)"
  head_after="$(git -C "$repo" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  assert_eq "(19) refs/remotes/origin/main UNCHANGED after the gate run (--refmap= isolation)" "$track_before" "$track_after"
  assert_eq "(19) refs/remotes/origin/HEAD UNCHANGED after the gate run" "$head_before" "$head_after"
  # The private per-run anchor ref is cleaned up (no leaked refs/manager-review/*).
  local leaked; leaked="$(git -C "$repo" for-each-ref --format='%(refname)' 'refs/manager-review/**' 2>/dev/null || true)"
  assert_eq "(19) the private per-run anchor ref (refs/manager-review/*) is cleaned up after exit" "" "$leaked"
}

echo "== north-star gate/consumer tests =="
test_source_identity
test_worktree_only_does_not_authorize
test_committed_authorizes_even_if_worktree_deleted
test_committed_authorizes_even_if_worktree_modified
test_fabrica_self_committed_worktree_deleted_proceeds
test_fabrica_self_no_committed_root_fails_not_local
test_local_committed_debates
test_local_marker_fails
test_unset_fails
test_gate_marker_variants_fail
test_gate_correctly_replaced_proceeds
test_gate_prose_token_in_active_region_proceeds
test_gate_nested_repo_fails
test_gate_linked_worktree_ok
test_gate_local_symlink_fails
test_gate_fabrica_self_symlink_fails
test_gate_subdir_regular_star_proceeds
test_gate_subdir_symlink_still_fails
test_gate_prose_active_before_heading_still_fails
test_gate_single_heading_active_proceeds
test_gate_no_active_entry_fails
test_gate_anchors_to_default_not_feature_branch
test_gate_default_placeholder_feature_real_fails
test_gate_fetches_fresh_not_stale_cache
test_gate_gh_repo_no_matching_remote_fails
test_gate_fork_selects_upstream_not_origin
test_gate_matching_remote_unset_symref_falls_back_to_lsremote
test_gate_detached_head_at_default_proceeds
test_gate_local_greenfield_visible_fallback_authorizes
test_doctor_unset_warns
test_doctor_local_committed_passes
test_doctor_local_marker_warns
test_doctor_h_committed_worktree_deleted
test_doctor_h_committed_worktree_modified
test_doctor_h_fabrica_self_worktree_modified_notes_drift
test_doctor_h_committed_symlink_warns
test_doctor_missing_lib_reports_and_summarizes
test_doctor_h_anchor_logs_ghbound
test_doctor_h_fetches_fresh_not_stale_cache
test_doctor_h_local_fallback_visible
test_normalize_repo_id_authority_and_schemes
test_effective_identity_helper_unit
test_gate_insteadof_cross_repo_fails
test_gate_insteadof_same_identity_transport_works
test_gate_insteadof_local_mirror_no_optin_fails
test_gate_insteadof_ext_transport_no_optin_fails
test_gate_insteadof_https_ssh_same_repo_proceeds
test_gate_insteadof_userinfo_path_host_trick_fails
test_doctor_h_insteadof_cross_repo_warns
test_doctor_h_ghbound_no_matching_remote_warns
test_doctor_target_arg_non_target_skips_anchor
test_doctor_h_empty_default_fallback_warns
test_gate_default_repoint_uses_lsremote_not_stale_symref
test_gate_spoofed_local_symref_ignored
test_gate_gh_no_default_branch_fails_closed
test_default_branch_offline_local_fallback_unit
test_select_remote_ssh_alias_effective_fallback
test_gate_no_ref_mutation_after_run

echo "-- $passed passed, $failed failed --"
if [ "$failed" -ne 0 ]; then
  exit 1
fi
