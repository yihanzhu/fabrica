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
   head fork-safely** with explicit, **fully-qualified** refspecs — `git fetch --no-tags origin
   +refs/pull/<PR#>/head:<tmpref> +refs/heads/<base>:refs/remotes/origin/<base>`. Both sources are
   qualified so a same-named tag on origin (e.g. branch and tag both named `v1.2.0`) can't make
   the fetch resolve ambiguously or fail before Codex runs. The `refs/pull/<PR#>/head` source
   brings the PR head commit into the object store even for **fork** PRs (a plain `git fetch
   origin` would not), and the base is fetched straight into `refs/remotes/origin/<base>` so the
   `--base origin/<base>` review is always **current** regardless of the clone's configured fetch
   refspecs (a bare `git fetch origin <base>` would only set `FETCH_HEAD` and could leave
   `origin/<base>` stale or missing). The `+` prefixes force-update **only** these two
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
2. Runs **`codex exec -C <tmpdir> review -c sandbox_mode="read-only" --base origin/<base> -o <tmpfile>`** —
   Codex's built-in review of the PR head diff vs. its **current** (qualified, remote) base,
   inside the temp worktree (`-C` is a flag on the parent `codex exec`, so it precedes the
   `review` subcommand). The `-c sandbox_mode="read-only"` override **forces** the read-only
   sandbox so the review can't inherit a writable default from the operator's Codex config
   (approval is already `never` for review); the script deliberately does **not** pass
   `--dangerously-bypass-approvals-and-sandbox`, and avoids `--ignore-user-config` so the
   operator's model/effort defaults still apply.
3. Posts Codex's review to the PR **verbatim**: `gh pr comment <PR#> --body-file <tmpfile>`,
   prefixed only with a short header marking it the Codex cross-vendor reviewer. That header
   also stamps the exact head SHA Codex reviewed as a parseable marker line —
   **`Reviewed-head: <full-sha>`** — so a later actor can bind a merge to the precise commit
   this review covered (and refuse if the head has since moved). The marker is part of
   Faber's header prefix, clearly separate from Codex's verbatim body, so the review stays
   read-only / comments-only / verbatim. [`scripts/merge-pr.sh`](../scripts/merge-pr.sh) is
   the first consumer: it reads this marker, confirms the PR's current head still equals it
   and that CI is green, then squash-merges pinned to that SHA (`--match-head-commit`).

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
                              └── ~3-round cap → label needs-human → Faber pings you
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
