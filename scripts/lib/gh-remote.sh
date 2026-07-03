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
# "<host[:port]>/<owner>/<repo>", lowercased, with any trailing `.git` stripped. Handles the three
# common transports without fragile regex (pure parameter expansion + `case`):
#   git@host:owner/repo(.git)         (scp-style SSH)
#   ssh://git@host/owner/repo(.git)   (ssh:// URL, optional user@)
#   https://host/owner/repo(.git)     (https, optional user@host)
# Prints the normalized id, or nothing if the URL doesn't parse to host + owner/repo.
#
# PORT IS PART OF THE HOST IDENTITY (#102 round-3, [P2]). A GHE host reachable on `:8443` is a
# DIFFERENT endpoint than the same host on the scheme default — dropping the port let distinct
# endpoints normalize to the same id and compare equal (a false same-repo match). So we KEEP any
# NON-DEFAULT port as `<host>:<port>`, and normalize away ONLY the scheme's DEFAULT port so legit
# same-repo comparisons still hold: https default 443, http 80, ssh 22, git 9418, and scp-style has
# no port at all (default). Thus `https://github.com/o/r` and `git@github.com:o/r.git` both have no
# port and stay equal; `https://github.com:443/o/r` == `https://github.com/o/r`; but
# `https://ghe.example:8443/o/r` keeps `:8443` and is NOT equal to `ghe.example/o/r`.
#
# IDENTITY-CRITICAL PARSING (#102 round-3, [P1]). The host must come from the URL AUTHORITY, never
# from anything embedded in the PATH — the whole fail-closed guard rests on this. Two bypasses the
# naive "drop everything before the last/first `@`" approach let through:
#   - USERINFO-PATH trick: `https://evil.example/x@github.com/acme/app.git` — the real host is the
#     authority `evil.example`; `github.com` sits in the PATH. Stripping to the last `@` wrongly read
#     `github.com` as the host, so a fetch that contacts evil.example was blessed with gh's identity.
#     FIX: take the authority = substring between `://` and the FIRST `/`, and strip `userinfo@`
#     WITHIN that authority only (never a path-embedded `@`).
#   - TRANSPORT-HELPER / exotic scheme: `ext::sh -c '…git@github.com:acme/app'`, `fd::…`, any
#     `<helper>::…` runs an ARBITRARY transport; the scp-style branch wrongly extracted `github.com`.
#     FIX: reject any url containing `::` outright, and accept only the schemes below → else empty.
# The returned host is NOT checked against github.com here (this normalizer is host-agnostic so it
# also serves GH Enterprise / the gh-configured host); the CALLERS enforce host correctness by
# requiring the normalized id to EQUAL gh's id (ghr_select_remote / ghr_assert_effective_identity).
# A parse that resolves to the WRONG host (e.g. evil.example/acme/app) therefore fails that equality
# and the guard FAILs closed — exactly the intent.
ghr_normalize_repo_id() {
  local url="$1" host rest authority port="" default_port=""
  # Reject git transport helpers / any `<scheme>::…` form outright (ext::, fd::, transport::…): the
  # `::` runs an arbitrary helper, so no host we could parse out is authoritative. Fail closed.
  case "$url" in
    *::*) return 0 ;;
  esac
  case "$url" in
    *://*)
      # scheme://[userinfo@]host[:port]/owner/repo... — accept ONLY genuine git URL schemes; any
      # other scheme is unsupported and unprovable → empty (fail closed). Record the scheme's
      # DEFAULT port so a matching explicit ':port' below is normalized away (kept otherwise).
      case "$url" in
        https://*) default_port=443 ;;
        http://*)  default_port=80 ;;
        ssh://*)   default_port=22 ;;
        git://*)   default_port=9418 ;;
        *) return 0 ;;
      esac
      rest="${url#*://}"
      # AUTHORITY = everything up to the FIRST '/' (host[:port], with optional leading userinfo@).
      # The remaining path stays in `rest`; a path-embedded '@' is NEVER read as the host.
      authority="${rest%%/*}"
      rest="${rest#*/}"
      # Strip userinfo WITHIN the authority only (up to the last '@' in the authority component),
      # then split host from ':port'. A port is part of the endpoint identity (see header), so we
      # KEEP it — dropping only the scheme default below.
      authority="${authority##*@}"
      host="${authority%%:*}"
      case "$authority" in
        *:*) port="${authority##*:}" ;;
      esac
      ;;
    *@*:*)
      # scp-style [userinfo@]host:owner/repo — host is between the optional userinfo@ and the FIRST
      # colon; owner/repo follow it. scp-style carries NO port (the ':' delimits the path), so the
      # port stays empty = the default. (The `::` reject above already excluded transport-helper forms.)
      rest="${url#*@}"
      host="${rest%%:*}"
      rest="${rest#*:}"
      ;;
    *:*)
      # scp-style with NO userinfo (host:owner/repo). Split on the first colon. No port (see above).
      host="${url%%:*}"
      rest="${url#*:}"
      ;;
    *)
      # Unrecognized form — can't match.
      return 0
      ;;
  esac
  # Normalize away ONLY the scheme's DEFAULT port so legit same-repo comparisons across transports
  # stay equal; PRESERVE any non-default port as part of the host identity.
  if [ -n "$port" ] && [ "$port" = "$default_port" ]; then
    port=""
  fi
  # `rest` is now the path "owner/repo[/...]"; keep exactly the first two segments.
  local owner="${rest%%/*}"
  rest="${rest#*/}"
  local name="${rest%%/*}"
  name="${name%.git}"
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$name" ] || return 0
  local host_id="$host"
  [ -n "$port" ] && host_id="${host}:${port}"
  printf '%s/%s/%s' "$host_id" "$owner" "$name" | tr '[:upper:]' '[:lower:]'
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

# ghr_select_remote <gh_repo_id> — print the configured git remote NAME whose URL resolves to the
# SAME host + owner/repo <gh_repo_id> (from ghr_gh_repo_id), or nothing if none matches. We do NOT
# blindly use `origin`: in a fork workflow `origin` = your fork while the PR / canonical default
# branch lives on `upstream`, so we match on identity (fork-safe). `origin` is only PREFERRED when
# it is itself the match. Run from within the repo's work tree (the callers `cd` there / run at the
# cwd). Prints nothing when no remote matches — the caller decides whether that is a hard FAIL
# (gh-bound consumer) or a fallback (diagnostic / local-only).
#
# SELECTION is availability-only, NOT authorization: it decides which remote NAME to hand the
# caller. Authorization (that the remote we actually FETCH from is gh's repo) is enforced
# separately by ghr_assert_effective_identity (below), which the callers run on the selected
# remote BEFORE any fetch. So selection can afford to be permissive; it must not FAIL to find a
# legit remote that the guard would then accept.
#
# We match on the CONFIGURED url FIRST (`git config --get remote.<name>.url`) — the operator's
# declared identity for the remote, and the common case (identical to the effective url when there
# is no insteadOf). If the configured url does NOT normalize to a GitHub identity (empty — e.g. an
# SSH host-alias `myalias:owner/repo`, or a shorthand the operator's insteadOf expands at fetch
# time), we fall back to the EFFECTIVE url (`git remote get-url`, which applies insteadOf) for
# selection (#102 round-2 FIX 3). This restores the SSH-alias / shorthand case, where the
# configured url alone can't be normalized but the effective url resolves to gh's repo. Safety is
# unaffected: ghr_assert_effective_identity still re-derives the EFFECTIVE url and FAILs unless it
# is a NON-EMPTY GitHub id EQUAL to gh's (see below), so the effective-url fallback here only
# widens SELECTION availability, never what is authorized to fetch.
ghr_select_remote() {
  local gh_repo_id="$1"
  [ -n "$gh_repo_id" ] || return 0
  local selected_remote="" remote_name configured_url effective_url
  while IFS= read -r remote_name; do
    [ -n "$remote_name" ] || continue
    # CONFIGURED url first (the declared identity). If it doesn't normalize to a GitHub id, fall
    # back to the EFFECTIVE url (insteadOf-applied) so an SSH-alias / shorthand remote still selects.
    configured_url="$(git config --get "remote.${remote_name}.url" 2>/dev/null || true)"
    if [ -z "$configured_url" ] || [ "$(ghr_normalize_repo_id "$configured_url")" != "$gh_repo_id" ]; then
      # Configured url absent or not gh's identity — try the effective (insteadOf-applied) url.
      effective_url="$(git remote get-url "$remote_name" 2>/dev/null || true)"
      if [ -z "$effective_url" ] || [ "$(ghr_normalize_repo_id "$effective_url")" != "$gh_repo_id" ]; then
        continue
      fi
    fi
    if [ "$remote_name" = "origin" ]; then
      selected_remote="origin"
      break
    fi
    [ -n "$selected_remote" ] || selected_remote="$remote_name"
  done < <(git remote)
  [ -n "$selected_remote" ] || return 0
  printf '%s' "$selected_remote"
}

# ghr_assert_effective_identity <remote> <gh_repo_id> — the FETCH-time identity gate, FAIL-CLOSED
# (#102 round-2 FIX 1). ghr_select_remote picks the remote by URL, but the caller then FETCHES BY
# NAME — which applies `url.<base>.insteadOf`, so the URL git actually contacts can differ from the
# one selection matched. This gate re-derives the EFFECTIVE fetch URL (`git remote get-url`, which
# applies insteadOf exactly as the fetch will), normalizes it, and authorizes the fetch ONLY when
# that EFFECTIVE identity is a NON-EMPTY GitHub id EQUAL to <gh_repo_id> (the repo the verdict posts
# to). Anything else FAILs closed:
#   - a DIFFERENT non-empty GitHub id  → `url.<other-gh-repo>.insteadOf` cross-repo substitution
#     (read repo B, post to repo A) — the original documented attack;
#   - an EMPTY id (a local path, `file://`, `ext::`, an SSH host-alias that doesn't resolve, or any
#     transport that does not parse to host+owner/repo) → UNPROVABLE against gh's identity. Round-1
#     allowed this through ("not a GitHub repo, so not the confused-deputy") — but an attacker who
#     can set `url.<local-path-or-file-or-ext>.insteadOf = <the configured url>` (repo/global/
#     included git config) makes the fetch pull from an ARBITRARY LOCAL repo while the verdict still
#     posts to gh's real repo. "Ambiguous/empty ⇒ trusted" is exactly the hole the re-attack found,
#     so we now FAIL closed on it: an effective URL we cannot PROVE is gh's repo cannot authorize.
#
# Legit same-repo transport rewrites still pass: an https↔ssh insteadOf for the SAME repo
# normalizes to a non-empty id EQUAL to gh's → OK.
#
# EXPLICIT LOCAL-MIRROR OPT-IN: a genuine local mirror (a `file://` / on-disk clone the operator
# deliberately fetches from) is unprovable against gh's GitHub identity, so it is refused BY DEFAULT.
# An operator who really wants it must opt in EXPLICITLY by exporting
# FABRICA_ALLOW_LOCAL_MIRROR=1 — never the silent default. When set, an EMPTY effective id is
# allowed through (a cross-repo GitHub substitution — a non-empty DIFFERING id — still FAILs even
# then, since that is unambiguously the confused-deputy attack). This flag is what the hermetic test
# harness (which rewrites the https identity to a local `file://` bare for offline transport) sets.
#
# Returns 0 (OK to fetch) when authorized, non-zero (printing an actionable error to stderr) when
# not. `|| true` on the get-url substitution so a git hiccup degrades to empty — which now FAILs
# closed (unprovable), not silently passes.
ghr_assert_effective_identity() {
  local remote="$1" gh_repo_id="$2"
  [ -n "$remote" ] && [ -n "$gh_repo_id" ] || return 0
  local effective_url effective_id
  effective_url="$(git remote get-url "$remote" 2>/dev/null || true)"
  effective_id="$(ghr_normalize_repo_id "$effective_url")"
  # Authorized ONLY when the effective identity is a non-empty GitHub id EQUAL to gh's.
  if [ -n "$effective_id" ] && [ "$effective_id" = "$gh_repo_id" ]; then
    return 0
  fi
  # A DIFFERENT non-empty GitHub id is ALWAYS the cross-repo-substitution attack — refuse it even
  # under the local-mirror opt-in (the opt-in is for unprovable local transports, not for
  # redirecting to a different GitHub repo).
  if [ -n "$effective_id" ]; then
    echo "error: remote '${remote}' is configured to match ${gh_repo_id}, but an insteadOf rewrite" >&2
    echo "       redirects its actual fetch URL to a DIFFERENT repo identity (${effective_id})." >&2
    echo "       The gate/reviewer refuses to fetch from one repo while binding its verdict to" >&2
    echo "       another (a 'url.<other>.insteadOf' repo-substitution). Remove the cross-repo" >&2
    echo "       insteadOf rewrite (or point it at the SAME repo's transport), then re-run." >&2
    return 1
  fi
  # EMPTY effective id: unprovable against gh's identity (local path / file:// / ext:: / alias /
  # unparseable). FAIL closed unless the operator explicitly opted into a local mirror.
  if [ "${FABRICA_ALLOW_LOCAL_MIRROR:-0}" = "1" ]; then
    return 0
  fi
  echo "error: remote '${remote}' resolves (via git remote get-url, applying any insteadOf) to a fetch" >&2
  echo "       URL that does NOT parse to gh's GitHub identity (${gh_repo_id}) — it is a local path," >&2
  echo "       file://, ext::, an SSH alias, or another unprovable transport. The gate/reviewer binds" >&2
  echo "       its verdict to ${gh_repo_id}, so it FAILs closed rather than fetch from a source it" >&2
  echo "       cannot prove is that repo (an 'url.<local>.insteadOf' could silently redirect the fetch)." >&2
  echo "       Point the remote at the real GitHub transport, or — for a deliberate local mirror —" >&2
  echo "       export FABRICA_ALLOW_LOCAL_MIRROR=1 to opt in explicitly, then re-run." >&2
  return 1
}

# ghr_gh_default_branch <repo> — print the SHORT default branch NAME (e.g. `main`) AUTHORITATIVELY
# from gh, for the gh-BOUND gate (#102 round-2 FIX 2). <repo> is the `owner/repo` gh bound this run
# to (`gh repo view --json nameWithOwner`); we query the SAME gh binding the verdict posts to:
#   env -u GH_REPO gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name
# `--repo <repo>` EXPLICIT + `GH_REPO` cleared (exactly like ghr_gh_repo_id) so the answer reflects
# THAT repo, never a PR-followed parent/upstream or a spoofed GH_REPO. Prints nothing (rc 0, so a
# `set -e` caller can decide) if gh can't resolve it — the gh-bound caller MUST then FAIL closed.
#
# WHY gh, NOT any local/remote-derived source (the round-2 security fix): the default-branch NAME is
# an AUTHORIZATION input — it decides which branch's committed north star authorizes the proactive
# gate. Round-1 took it from `git ls-remote --symref <remote> HEAD` with a fallback to the local
# `refs/remotes/<remote>/HEAD` symref. Both surfaces are spoofable/stale relative to the verdict
# identity: the local symref is locally MUTABLE (`git symbolic-ref …`) and STALE (fetch never
# refreshes it), and even ls-remote answers about whatever the SELECTED REMOTE resolves to — which
# a `url.<other>.insteadOf` can redirect. Taking the name from the SAME gh binding the verdict posts
# to removes that whole surface: the branch identity is now as authoritative as, and tied to, the
# repo identity the verdict binds to. There is NO local-symref fallback for the gate — an
# unresolvable default on a gh-bound run is a FAIL, never a degrade to a spoofable local source.
#
# NOTE: this is only the NAME. The caller builds a fully-qualified refspec (`refs/heads/<default>`)
# and FETCHES FRESH from the validated remote into a private per-run ref, pinning to the FETCHED
# commit. `|| true` keeps this degrade-to-empty under a `set -e` caller (which then FAILs closed).
ghr_gh_default_branch() {
  local repo="$1"
  [ -n "$repo" ] || return 0
  env -u GH_REPO gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true
}

# ghr_remote_default_branch <remote> — DIAGNOSTIC-ONLY default-branch NAME resolver for the given
# remote (e.g. `main`). This is NOT an authorization input — the gh-bound GATE uses
# ghr_gh_default_branch (gh-authoritative) above. `doctor.sh` uses THIS as a visible local/network
# fallback when it can't reach gh, so its diagnosis still names a plausible default.
#
# PREFERS the remote's HEAD via `git ls-remote --symref <remote> HEAD` (parse the
# `ref: refs/heads/<name>` line); falls back to the LOCAL remote-tracking HEAD
# (`git symbolic-ref refs/remotes/<remote>/HEAD`) ONLY as an offline last resort. BOTH are
# stale/spoofable — acceptable ONLY because this feeds a diagnostic (doctor WARNs + degrades
# visibly), never the gate's authorization. Prints nothing if neither resolves. `|| true` keeps the
# degrade-to-empty under a `set -e` caller.
ghr_remote_default_branch() {
  local remote="$1"
  [ -n "$remote" ] || return 0
  # Ask the remote. `git ls-remote --symref <remote> HEAD` prints a line like
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
