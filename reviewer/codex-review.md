# Reviewer — Codex (OpenAI), via `scripts/codex-review.sh`

The reviewer runs on **Codex**, not as a Claude routine — that's the cross-vendor
split that decorrelates blind spots (coder = Claude, reviewer = Codex). The reviewer
uses Codex's **built-in** review (`codex exec review`), not a hand-written rubric: the
`--base` flag can't take a custom prompt, and the whole point is to get Codex's own
independent judgment, not Claude's rubric echoed back.

## How the reviewer actually runs

[`scripts/codex-review.sh`](../scripts/codex-review.sh) is the harness. It operates on
the **current repo** — `gh` infers `<owner>/<repo>` from the cwd's git remote, and the
review runs against that repo's PR — so **invoke it from within the target repo's clone**.
The script lives only in *this* control-plane repo, so call it by its **absolute path**
(or put `<fabrica>/scripts` on your `PATH`); don't copy it into each target repo. It first
guards that the cwd is a git repo with a gh-recognized remote (else it errors out) — and it
`unset`s `GH_REPO` then derives the repo from the cwd and passes an explicit `--repo` to
every `gh` call, so a `GH_REPO` in the environment can't redirect the comment to a
*different* repo's PR. Then:

1. Derives the PR's base branch (`gh pr view <PR#> --json baseRefName`) and **fetches the PR
   head fork-safely** with explicit, **fully-qualified** refspecs — `git fetch --no-tags
   <remote> +refs/pull/<PR#>/head:<tmpref> +refs/heads/<base>:<base-tmpref>`. The fetch source is
   the **configured git remote whose URL resolves to the repo `gh` bound the review to** — *not*
   the literal `origin`, *not* a synthesized `https://github.com/...` URL. The script resolves
   gh's canonical identity (`gh repo view <repo> --json url` for the **host**, with `<repo>` passed
   **explicitly** so `gh` views that repo, never a PR-followed parent; `<repo>` itself is the
   `owner/repo`), then iterates `git remote`, **normalizes** each remote's URL to `host` +
   `owner/repo` (handling scp-style `git@host:owner/repo(.git)`, `ssh://git@host/owner/repo(.git)`,
   and `https://host/owner/repo(.git)` — trailing `.git` stripped, compared case-insensitively),
   and **selects the remote that matches** gh's host + `owner/repo` (preferring `origin` when it is
   itself the match). It then fetches from that **remote name**. Three reasons this is right:
   (a) **auth-correct** — using the operator's configured remote means the fetch uses the
   operator's own transport and credentials (SSH key, gh's git credential helper, etc.). A
   synthesized HTTPS *web* URL carries no credentials, so on **private repos or
   SSH-only-authenticated checkouts** `git fetch <url>` would fail even though `gh auth status`
   passes and `origin` works — aborting the review before Codex runs. (b) **fork-safe** — we match
   on the gh-resolved identity, not blind `origin`: in a fork workflow (`origin` = your fork,
   `upstream` = the canonical repo PRs target) `gh` reports the PR on the canonical repo, so we
   select `upstream`; fetching from `origin` would fail (the PR ref doesn't exist on the fork) or
   silently grab a same-numbered, unrelated PR and review the wrong diff. (c) **host-correct** —
   it's the operator's real remote URL, so GitHub Enterprise / non-github.com hosts work, where a
   synthesized github.com URL would hit the wrong host. That makes the source **provably** the repo
   `gh` resolved. If **no** configured remote matches the gh-resolved repo, the script **refuses**
   with an actionable error (`add it (e.g. 'git remote add upstream <url>') and re-run`) and a
   non-zero exit — it does **not** fall back to an unauthenticated synthesized URL. Both sources
   are qualified so a same-named tag (e.g. branch and tag both named `v1.2.0`) can't make
   the fetch resolve ambiguously or fail before Codex runs. The `refs/pull/<PR#>/head` source
   brings the PR head commit into the object store even for **fork** PRs (a plain `git fetch` of
   a branch would not). Both destinations are **private, per-run-unique refs we own** under
   `refs/codex-review/<PR#>-<PID>/` (not a `refs/remotes/<remote>/*` tracking ref) — that keeps them
   independent of which remote we selected, avoids clobbering the operator's `<remote>/<base>` with
   a commit fetched into our own ref, **and** keeps two reviews launched from the same checkout
   from colliding (a shared ref name would let a later run's fetch/cleanup force-update or delete
   the ref while an earlier run is still resolving `--base`). The `--base` review runs against the
   freshly-fetched per-run base ref, always **current** regardless of the clone's configured
   fetch refspecs. The `+` prefixes force-update **only** these two
   destination refs we own — never a global `git fetch --force`, which combined with git's tag
   auto-following could force-update local `refs/tags/*` and mutate operator state; `--no-tags`
   disables that auto-following so the fetch touches nothing outside the two named refs (the
   read-only guarantee stays literally true). It then adds a **detached, throwaway git worktree** at that fetched head
   (`git worktree add --detach <tmpdir> <head>`), **isolated from the operator's checkout**. The review runs in that temp worktree, so the operator's branch, index, working
   tree, and unpushed commits are never touched — there is no force checkout and no
   clean-worktree guard, and the reviewer works even when the operator has local uncommitted
   work. A `trap ... EXIT` removes the temp worktree (`git worktree remove --force`) and temp
   file even on failure, so the script never leaves a stale entry behind; and because each run
   adds its worktree at a fresh `mktemp` path, a stale entry from a hard-killed previous run
   never blocks a re-run. (It deliberately avoids a global `git worktree prune`, which is
   repo-wide and would touch unrelated operator worktrees.)
2. Runs **`codex exec -C <tmpdir> review -c sandbox_mode="read-only" -c model_reasoning_effort="<effort>" --base refs/codex-review/<PR#>-<PID>/base -o <tmpfile> [-m <model>]`** —
   Codex's built-in review of the PR head diff vs. its **current** (qualified, freshly-fetched) base,
   inside the temp worktree (`-C` is a flag on the parent `codex exec`, so it precedes the
   `review` subcommand). The `-c sandbox_mode="read-only"` override **forces** the read-only
   sandbox so the review can't inherit a writable default from the operator's Codex config
   (approval is already `never` for review); the script deliberately does **not** pass
   `--dangerously-bypass-approvals-and-sandbox`, and avoids `--ignore-user-config` so the
   operator's model/effort defaults still apply. See **model policy** below for how `<effort>`
   and the optional `-m <model>` are resolved (#110) — the gate's reasoning effort is **always**
   pinned explicitly, never left to inherit whatever the operator's personal Codex config
   happens to default to.
3. Posts Codex's review to the PR **verbatim**: `gh pr comment <PR#> --body-file <tmpfile>`,
   prefixed only with a short header marking it the Codex cross-vendor reviewer. That header
   also stamps the exact head SHA Codex reviewed as a parseable marker line —
   **`Reviewed-head: <full-sha>`** — so a later actor can bind a merge to the precise commit
   this review covered (and refuse if the head has since moved), plus a
   **`reviewer: <model> @ <effort>`** line recording the RESOLVED config that gated this review
   (see **model policy** below). The marker and reviewer lines are part of
   Faber's header prefix, clearly separate from Codex's verbatim body, so the review stays
   read-only / comments-only / verbatim. [`scripts/merge-pr.sh`](../scripts/merge-pr.sh) is
   the first consumer: it reads the `Reviewed-head`/`Reviewed-base` markers, confirms the PR's
   current head still equals it and that CI is green, then squash-merges pinned to that SHA
   (`--match-head-commit`).

```
# run from within the TARGET repo's clone; invoke the script by ABSOLUTE PATH
# (it lives only in the fabrica control-plane repo — do NOT copy it per repo).
# Substitute your fabrica clone for "$HOME/git/fabrica".
"$HOME/git/fabrica/scripts/codex-review.sh" <PR#>             # e.g. ... 7
"$HOME/git/fabrica/scripts/codex-review.sh" -m <model> <PR#>  # optional model override

# Optional: add fabrica/scripts to PATH once, then call it by name from any target repo:
#   export PATH="$HOME/git/fabrica/scripts:$PATH"   # (add to your shell rc)
#   codex-review.sh <PR#>
```

The `<tmpfile>` and the throwaway worktree both live in the system temp dir, never inside
the repo, and are cleaned up via the `trap ... EXIT` (removed even on failure) — the
`<tmpfile>` exists only to capture Codex's clean final review off the noisy exec trace.
Neither is **ever** committed; the **PR comment is the durable reviewer output**.

## Model policy (#110)

The review gate is a **max-capability decision point** (spend-by-leverage — see
[`config/models.conf`](../config/models.conf) and README.md's "Model policy" section), so it
does not simply inherit the operator's personal Codex defaults. Before doing anything else,
the script sources `config/models.conf` **resolved relative to its own location** (this clone's
control-plane root, following symlinks — never a hardcoded personal path), which sets
`FABRICA_CODEX_MODEL` (empty by default) and `FABRICA_REVIEW_EFFORT` (`high` by default). A
missing or unsourceable `config/models.conf` **fails loudly**, pointing at `scripts/doctor.sh`
check (k), rather than silently reviewing at an unknown effort.

If the **reviewed repo** has committed its own [`.fabrica/models.conf`](../templates/.fabrica/models.conf)
(same format/keys, an opt-in per-target override), it is sourced **after** the shipped defaults —
but read from the **same fetched worktree the review runs against** (the detached worktree
checked out at the exact PR head fetched above), never the operator's possibly-stale or dirty
cwd checkout, so the override always reflects the commit actually under review. An unsourceable
override also fails loudly, the same way.

Applying the resolved config:

- **`-c model_reasoning_effort="$FABRICA_REVIEW_EFFORT"` is ALWAYS passed** — the gate is never
  class-routed down, so this explicitly raises it to the resolved value (`high` by default)
  instead of silently inheriting whatever the operator's `~/.codex/config.toml` happens to
  default to (often `low`).
- **`-m <model>` is passed only when a model is actually resolved.** The script's own `-m` CLI
  flag keeps precedence over `FABRICA_CODEX_MODEL`; if neither is set, no `-m` is passed at all
  (Codex uses its own default model).
- The **resolved** model + effort are echoed into the posted PR comment's header —
  `reviewer: <model> @ <effort>` (e.g. `reviewer: operator-default @ high` when no model was
  pinned) — so every review documents on the record exactly what gated it, and any drift from
  a stray personal config is visible in the PR history, not just in a log nobody reads.

## Invariants (non-negotiable)

- **Cross-vendor.** Coder = Claude, reviewer = Codex. The reviewer's value is being a
  *different* model, not a second copy of the author.
- **Read-only.** The script **forces** the read-only sandbox with
  `-c sandbox_mode="read-only"` (so it can't inherit a writable config default) and never
  bypasses the sandbox.
- **Comments only.** The script's *only* side effect is one `gh pr comment` (pinned to the
  cwd's repo via an explicit `--repo`, with `GH_REPO` unset, so it can't post to another
  repo's PR). It never edits files, pushes, approves-to-merge, or merges, and is never the
  author. It also never touches the operator's working state: the review runs in an isolated,
  throwaway detached worktree at the PR head, so the operator's branch, index, working tree,
  and unpushed commits are never modified — read-only is literally true.
- **Verbatim.** Codex's review is posted unedited — no Claude session rewrites, blends,
  or summarizes it. That preserves the independence of the second opinion.

## The in-session review loop

Today the loop is **synchronous** — it runs while a Faber session is driving it:

```
Faber spawns coder subagent  →  coder opens PR (label round-0)
        ↓
Faber runs codex-review.sh <PR#>  (by absolute path, from the target repo's clone)
   (script posts Codex's verdict to the PR, verbatim)
        ↓
Faber reads the Codex comment
        ├── pass      →  Faber merges if low-risk (CI green); else hands to the human
        └── not pass  →  Faber spawns coder (fix mode) to address comments
                              ↓
                         Faber re-runs codex-review.sh   (bump round-N)
                              ↺  repeat
                              └── ~3-round cap → SCOPE DOWN + FOLLOW-UP (productive):
                                    land the converged core (one scoped-down change →
                                    clean review → merge) + open a follow-up issue for the
                                    contested remainder; reserve needs-human → Faber pings you
                                    for a genuine standoff / safety-rail / north-star
```

Faber, not the reviewer, drives each step; Claude and Codex never talk directly — the
**PR is the message bus**. Rounds + escalation live in the **labels**
(`round-0..3`, `needs-human`), not in any agent's memory.

## Future / alternatives (not wired)

These are possible later changes — **none is set up today.** The in-session harness above
is the only review path that exists.

- **Codex GitHub integration** — a possible **autonomous** upgrade: Codex would post its
  review on PR events itself (PR opened/updated), so the loop would no longer need a Faber
  session to invoke the script. Same invariants (cross-vendor, read-only, comments-only).
  Not built; wiring it is out of scope here.
- **codex-plugin-cc** — an **interactive** alternative: drive Codex review from inside a
  Claude Code session via the plugin, rather than the standalone CLI script.

> Note: Codex on your ChatGPT plan is fine for personal repos (first-party feature =
> ordinary use). Apply terms diligence before pointing it at any work/shared repo.
