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
# that rewrites its remote for transport, `get-url` would return the rewritten (possibly local)
# URL and the identity match would spuriously fail. The CONFIGURED url is the operator's declared
# identity for the remote — the right thing to match against gh's identity — while the caller
# still FETCHES by the remote NAME, so any insteadOf transport rewrite is honored for the fetch.
# In the common case (no insteadOf) the two are identical.
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

# ghr_remote_default_branch <remote> — print the SHORT default branch NAME of the given remote
# (e.g. `main`). Prefers the LOCAL remote-tracking HEAD (`git symbolic-ref
# refs/remotes/<remote>/HEAD` → `refs/remotes/<remote>/<default>`); if that is unset (common for a
# manually-added `upstream` that was never `git remote set-head`), falls back to asking the remote
# directly via `git ls-remote --symref <remote> HEAD`. Prints nothing if neither resolves.
#
# NOTE: this only tells us the default branch's NAME — never a trustworthy commit. The local
# tracking HEAD can be STALE, and even the ls-remote read is used ONLY for the name. Callers use
# the name to build a fully-qualified fetch refspec (`refs/heads/<default>`) and FETCH FRESH from
# the remote into a private per-run ref, pinning to the FETCHED commit — never to
# `refs/remotes/<remote>/HEAD` itself. `|| true` keeps this degrade-to-empty under a `set -e`
# caller.
ghr_remote_default_branch() {
  local remote="$1"
  [ -n "$remote" ] || return 0
  local ref
  ref="$(git symbolic-ref --quiet "refs/remotes/${remote}/HEAD" 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    # ref is refs/remotes/<remote>/<default>; strip the leading refs/remotes/<remote>/ prefix.
    printf '%s' "${ref#"refs/remotes/${remote}/"}"
    return 0
  fi
  # Fallback: ask the remote. `git ls-remote --symref <remote> HEAD` prints a line like
  # `ref: refs/heads/main\tHEAD`; extract the branch short-name from that symref line.
  local symref
  symref="$(git ls-remote --symref "$remote" HEAD 2>/dev/null | awk '/^ref:/ {print $2; exit}' || true)"
  [ -n "$symref" ] || return 0
  printf '%s' "${symref#refs/heads/}"
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
ghr_fetch_default_commit() {
  local remote="$1" branch="$2" dest_ref="$3"
  [ -n "$remote" ] && [ -n "$branch" ] && [ -n "$dest_ref" ] || return 1
  git fetch --no-tags "$remote" "+refs/heads/${branch}:${dest_ref}" >/dev/null 2>&1 || return 1
  git rev-parse "$dest_ref" 2>/dev/null || return 1
}
