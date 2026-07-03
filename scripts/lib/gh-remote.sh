#!/usr/bin/env bash
# gh-remote.sh — the shared gh-BOUND remote-identity selection helper (sourced, not executed).
#
# Both scripts/codex-review.sh and scripts/manager-review.sh must answer the same question:
# "which configured git remote is the SAME repo `gh` bound this run to?" — so a fetch (a PR
# head, a base branch, or the default branch) uses the operator's own configured transport +
# credentials against the PROVABLY-correct repo, and the run never anchors to one repo while
# posting its verdict to another's issue/PR. This lib factors that selection into ONE place so
# the two scripts can't diverge. It is `source`d (no shebang execution) — the `#!/usr/bin/env
# bash` line is only so shellcheck picks the right dialect.
#
# The functions here are PURE derivation/selection — they print a result and never fetch, post
# comments, edit files, or mutate any checkout. Callers own the side effects (the fetch, the
# per-run ref, the cleanup).
#
# WHY NOT blindly `origin`: in a fork workflow `origin` is your fork while the PR / canonical
# default branch lives on `upstream`, so we match on repo IDENTITY (fork-safe), preferring
# `origin` ONLY when it is itself the match. If NO configured remote resolves to gh's repo, the
# caller REFUSES rather than falling back to an unauthenticated synthesized URL (or an unbound
# local anchor). See codex-review.sh / manager-review.sh for the per-consumer refusal policy.

# ghr_normalize_repo_id <url> — normalize a git remote URL (or gh web URL) to
# "<host>/<owner>/<repo>", lowercased, with any trailing `.git` stripped. Handles the three
# common transports without fragile regex (pure parameter expansion + `case`):
#   git@host:owner/repo(.git)         (scp-style SSH)
#   ssh://git@host/owner/repo(.git)   (ssh:// URL, optional user@)
#   https://host/owner/repo(.git)     (https, optional user@host)
# Prints the normalized id, or nothing if the URL doesn't parse to host + owner/repo.
ghr_normalize_repo_id() {
  local url="$1" host rest
  case "$url" in
    *://*)
      # scheme://[user@]host/owner/repo... — drop scheme, then any leading userinfo, then split host/path.
      rest="${url#*://}"
      rest="${rest#*@}"
      host="${rest%%/*}"
      rest="${rest#*/}"
      ;;
    *@*:*)
      # scp-style git@host:owner/repo — drop userinfo, split on the FIRST colon.
      rest="${url#*@}"
      host="${rest%%:*}"
      rest="${rest#*:}"
      ;;
    *)
      # Unrecognized form — can't match.
      return 0
      ;;
  esac
  # `rest` is now the path "owner/repo[/...]"; keep exactly the first two segments.
  local owner="${rest%%/*}"
  rest="${rest#*/}"
  local name="${rest%%/*}"
  name="${name%.git}"
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$name" ] || return 0
  printf '%s/%s/%s' "$host" "$owner" "$name" | tr '[:upper:]' '[:lower:]'
}

# ghr_gh_repo_id <repo> — compute gh's normalized identity (host + owner/repo) for the repo
# `gh` bound this run to. <repo> is the `owner/repo` (`gh repo view --json nameWithOwner`); we
# pass it EXPLICITLY to `gh repo view --json url` so the URL reports THAT repo — never a
# PR-followed parent/upstream — and read the HOST off that URL so the match is host-correct on
# GitHub Enterprise / non-github.com hosts (where `nameWithOwner` resolves the same but the
# canonical host is NOT github.com). Prints "<host>/<owner>/<repo>" lowercased, or nothing.
#
# `env -u GH_REPO`: like the callers, clear a set GH_REPO for this one probe so the URL reflects
# the passed <repo>, not whatever GH_REPO points at (the callers already `unset GH_REPO`, but
# clearing here too keeps this helper correct for any caller). `|| true` on the substitution so
# a gh hiccup degrades to empty (rc 0) rather than aborting a `set -e` caller before the
# emptiness check decides.
ghr_gh_repo_id() {
  local repo="$1"
  [ -n "$repo" ] || return 0
  local repo_url gh_host
  repo_url="$(env -u GH_REPO gh repo view "$repo" --json url -q .url 2>/dev/null || true)"
  [ -n "$repo_url" ] || return 0
  gh_host="$(ghr_normalize_repo_id "$repo_url")"; gh_host="${gh_host%%/*}"
  [ -n "$gh_host" ] || return 0
  ghr_normalize_repo_id "https://${gh_host}/${repo}"
}

# ghr_select_remote <gh_repo_id> — print the configured git remote NAME whose CONFIGURED URL
# resolves to the SAME host + owner/repo <gh_repo_id> (from ghr_gh_repo_id), or nothing if none
# matches. We do NOT blindly use `origin`: in a fork workflow `origin` = your fork while the PR /
# canonical default branch lives on `upstream`, so we match on identity (fork-safe). `origin` is
# only PREFERRED when it is itself the match. Run from within the repo's work tree (the callers
# `cd` there / run at the cwd). Prints nothing when no remote matches — the caller decides whether
# that is a hard FAIL (gh-bound consumer) or a fallback (diagnostic / local-only).
#
# We read the CONFIGURED url via `git config --get remote.<name>.url`, NOT `git remote get-url`,
# on purpose: `get-url` applies any `url.<base>.insteadOf` TRANSPORT rewrite, so on a checkout
# that rewrites its remote for transport (e.g. an https↔ssh swap, or a local mirror), `get-url`
# would return the rewritten URL and the identity match would spuriously fail. The CONFIGURED url
# is the operator's declared identity for the remote — the right thing to match against gh's
# identity for SELECTION. In the common case (no insteadOf) the two are identical.
#
# insteadOf is NOT "only a transport rewrite" (an earlier version of this comment claimed so —
# that was WRONG): `url.<other>.insteadOf = <configured>` makes the FETCH-BY-NAME silently pull
# from `<other>`, an ARBITRARY different repo, even though selection matched the configured URL.
# So selection alone is not enough — the caller MUST additionally gate the FETCH on the EFFECTIVE
# URL's identity via ghr_assert_effective_identity (below), which FAILs if the rewritten fetch URL
# resolves to a DIFFERENT GitHub identity than gh's. That split (match configured for selection,
# gate effective for the fetch) is deliberate: a legit same-repo transport insteadOf still selects
# AND passes the effective-identity gate, while a cross-repo-substitution insteadOf FAILs the gate.
ghr_select_remote() {
  local gh_repo_id="$1"
  [ -n "$gh_repo_id" ] || return 0
  local selected_remote="" remote_name remote_url
  while IFS= read -r remote_name; do
    [ -n "$remote_name" ] || continue
    remote_url="$(git config --get "remote.${remote_name}.url" 2>/dev/null)" || continue
    [ -n "$remote_url" ] || continue
    if [ "$(ghr_normalize_repo_id "$remote_url")" = "$gh_repo_id" ]; then
      if [ "$remote_name" = "origin" ]; then
        selected_remote="origin"
        break
      fi
      [ -n "$selected_remote" ] || selected_remote="$remote_name"
    fi
  done < <(git remote)
  [ -n "$selected_remote" ] || return 0
  printf '%s' "$selected_remote"
}

# ghr_assert_effective_identity <remote> <gh_repo_id> — the FETCH-time identity gate (insteadOf
# repo-substitution guard). ghr_select_remote picks the remote by its CONFIGURED url, but the
# caller then FETCHES BY NAME — which applies `url.<base>.insteadOf`, so the URL git actually
# contacts can differ from the configured one. An attacker who can set
# `url.<attacker-repo>.insteadOf = <the configured url>` makes the fetch silently pull from
# `<attacker-repo>` — an ARBITRARY different repo — while the verdict still posts to gh's repo.
# This gate closes that hole: it re-derives the EFFECTIVE fetch URL (`git remote get-url`, which
# applies insteadOf exactly as the fetch will), normalizes it, and FAILs when that EFFECTIVE
# identity resolves to a DIFFERENT GitHub host/owner/repo than <gh_repo_id>.
#
# Returns 0 (OK to fetch) when the effective URL is safe, non-zero (printing an actionable error
# to stderr) when it is a cross-repo substitution. "Safe" is: the effective URL normalizes to the
# SAME id as gh's (a legit same-identity transport insteadOf, e.g. https↔ssh for the SAME repo), OR
# it does NOT normalize to a GitHub-style identity at all (an empty result — a local mirror such as
# a `file://` path or an exotic transport the operator deliberately configured). Only a NON-EMPTY
# effective identity that DIFFERS from gh's is the documented attack, because the verdict-posting
# gh binding stays <gh_repo_id> regardless — so redirecting the FETCH to a different *GitHub repo*
# (which normalizes to a valid, non-empty, differing id) is the exact "read repo A, post to repo B"
# confused-deputy this refuses. A non-parseable local transport cannot itself be a GitHub repo the
# gate would post a verdict to, so it is left to the operator's own transport config.
#
# `|| true` on the get-url substitution so a git hiccup degrades to empty (treated as safe/local)
# rather than aborting a `set -e` caller before this function's own check runs.
ghr_assert_effective_identity() {
  local remote="$1" gh_repo_id="$2"
  [ -n "$remote" ] && [ -n "$gh_repo_id" ] || return 0
  local effective_url effective_id
  effective_url="$(git remote get-url "$remote" 2>/dev/null || true)"
  [ -n "$effective_url" ] || return 0
  effective_id="$(ghr_normalize_repo_id "$effective_url")"
  # Empty effective id = a non-GitHub-parseable transport (local mirror / exotic scheme): not the
  # cross-repo-substitution attack (see above) — allow it.
  [ -n "$effective_id" ] || return 0
  if [ "$effective_id" != "$gh_repo_id" ]; then
    echo "error: remote '${remote}' is configured to match ${gh_repo_id}, but an insteadOf rewrite" >&2
    echo "       redirects its actual fetch URL to a DIFFERENT repo identity (${effective_id})." >&2
    echo "       The gate/reviewer refuses to fetch from one repo while binding its verdict to" >&2
    echo "       another (a 'url.<other>.insteadOf' repo-substitution). Remove the cross-repo" >&2
    echo "       insteadOf rewrite (or point it at the SAME repo's transport), then re-run." >&2
    return 1
  fi
  return 0
}

# ghr_remote_default_branch <remote> — print the SHORT default branch NAME of the given remote
# (e.g. `main`). PREFERS the remote's AUTHORITATIVE HEAD via `git ls-remote --symref <remote> HEAD`
# (parse the `ref: refs/heads/<name>` line); falls back to the LOCAL remote-tracking HEAD
# (`git symbolic-ref refs/remotes/<remote>/HEAD`) ONLY as an offline last resort when the remote
# read fails or returns nothing. Prints nothing if neither resolves.
#
# WHY ls-remote is authoritative, NOT the local symref (#102 security fix): the local
# `refs/remotes/<remote>/HEAD` symref is (a) STALE — `git fetch` never refreshes it, so after the
# remote repoints its default (e.g. master→main, or → a release branch) it still names the OLD
# default; and (b) locally MUTABLE/SPOOFABLE (`git symbolic-ref refs/remotes/<remote>/HEAD
# refs/remotes/<remote>/<any-branch>`). Either way, trusting it first would let the gate anchor to a
# NON-default branch (the exact bypass #102 closes). The gate/doctor already hit the network to
# FETCH the anchor commit fresh, so an extra `ls-remote` keeps the branch-IDENTITY as fresh +
# trustworthy as the commit. The local symref stays only for the genuinely-offline case (a
# manually-added `upstream` never `set-head`, or a network blip) — degraded, but the best available.
#
# NOTE: this still only tells us the default branch's NAME — never a trustworthy commit. Callers use
# the name to build a fully-qualified fetch refspec (`refs/heads/<default>`) and FETCH FRESH from
# the remote into a private per-run ref, pinning to the FETCHED commit — never to
# `refs/remotes/<remote>/HEAD` itself. `|| true` keeps this degrade-to-empty under a `set -e`
# caller.
ghr_remote_default_branch() {
  local remote="$1"
  [ -n "$remote" ] || return 0
  # AUTHORITATIVE: ask the remote. `git ls-remote --symref <remote> HEAD` prints a line like
  # `ref: refs/heads/main\tHEAD`; extract the branch short-name from that symref line.
  local symref
  symref="$(git ls-remote --symref "$remote" HEAD 2>/dev/null | awk '/^ref:/ {print $2; exit}' || true)"
  if [ -n "$symref" ]; then
    printf '%s' "${symref#refs/heads/}"
    return 0
  fi
  # OFFLINE last resort ONLY (remote read failed/empty): the LOCAL remote-tracking HEAD. May be
  # stale or spoofed, but it is the best available when the remote can't be reached.
  local ref
  ref="$(git symbolic-ref --quiet "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"
  [ -n "$ref" ] || return 0
  # ref is refs/remotes/<remote>/<default>; strip the leading refs/remotes/<remote>/ prefix.
  printf '%s' "${ref#"refs/remotes/${remote}/"}"
}

# ghr_fetch_default_commit <remote> <branch> <dest_ref> — FETCH FRESH the <branch> from <remote>
# into the caller-owned PRIVATE per-run <dest_ref>, and print the fetched commit SHA. Returns
# non-zero (printing nothing) if the fetch fails. Shared by manager-review.sh (gate anchor) and
# doctor.sh (diagnostic anchor) so both anchor to the INTEGRATED tip, never a stale local
# remote-tracking cache.
#
# This is the fetch codex-review.sh does for PR/base refs, generalized: a fully-qualified source
# (`refs/heads/<branch>`) so a same-named tag can't resolve ambiguously; `--no-tags` so tag
# auto-following touches nothing outside <dest_ref>; the `+` force-updates ONLY <dest_ref> (which
# the caller owns and cleans up). We never write a remote-tracking ref, so the operator's
# `<remote>/<branch>` tracking state is untouched. The CALLER is responsible for choosing a
# per-run-unique <dest_ref> (e.g. refs/<tool>/<PID>/anchor) and for deleting it on exit.
#
# `--refmap=` (empty, #102 fix C) DISABLES the remote's configured fetch refmap for this fetch, so
# ONLY the explicit `+refs/heads/<branch>:<dest_ref>` destination is written. Without it, a plain
# `git fetch <remote> <refspec>` ALSO applies the configured `remote.<remote>.fetch` refmap and
# force-updates the operator's `refs/remotes/<remote>/*` tracking refs — contradicting the
# "only our private per-run ref is written" guarantee. The empty refmap makes that guarantee real.
ghr_fetch_default_commit() {
  local remote="$1" branch="$2" dest_ref="$3"
  [ -n "$remote" ] && [ -n "$branch" ] && [ -n "$dest_ref" ] || return 1
  git fetch --no-tags --refmap= "$remote" "+refs/heads/${branch}:${dest_ref}" >/dev/null 2>&1 || return 1
  git rev-parse "$dest_ref" 2>/dev/null || return 1
}
