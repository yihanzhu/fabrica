# Reviewer — Codex (OpenAI), via `scripts/codex-review.sh`

The reviewer runs on **Codex**, not as a Claude routine — that's the cross-vendor
split that decorrelates blind spots (coder = Claude, reviewer = Codex). The reviewer
uses Codex's **built-in** review (`codex exec review`), not a hand-written rubric: the
`--base` flag can't take a custom prompt, and the whole point is to get Codex's own
independent judgment, not Claude's rubric echoed back.

## How the reviewer actually runs

[`scripts/codex-review.sh`](../scripts/codex-review.sh) is the harness. It operates on
the **current repo** — `gh` infers `<owner>/<repo>` from the cwd's git remote, and
`codex exec review` runs against this same checkout — so **invoke it from within the
target repo's clone**. The script lives only in *this* control-plane repo, so call it by
its **absolute path** (or put `<fabrica>/scripts` on your `PATH`); don't copy it into each
target repo. It first guards that the cwd is a git repo with a gh-recognized remote (else
it errors out), then:

1. Derives the PR's base branch (`gh pr view <PR#> --json baseRefName`), **fetches origin**,
   and checks the PR out with **`gh pr checkout <PR#> --force`** so a re-run resets the local
   PR branch to the latest head instead of reviewing a stale leftover branch.
2. Runs **`codex exec review -c sandbox_mode="read-only" --base origin/<base> -o <tmpfile>`** —
   Codex's built-in review of the PR diff vs. its **current** (qualified, remote) base. The
   `-c sandbox_mode="read-only"` override **forces** the read-only sandbox so the review can't
   inherit a writable default from the operator's Codex config (approval is already `never` for
   review); the script deliberately does **not** pass `--dangerously-bypass-approvals-and-sandbox`,
   and avoids `--ignore-user-config` so the operator's model/effort defaults still apply.
3. Posts Codex's review to the PR **verbatim**: `gh pr comment <PR#> --body-file <tmpfile>`,
   prefixed only with a short header marking it the Codex cross-vendor reviewer.

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

The `<tmpfile>` is a transient `mktemp` file in the system temp dir (cleaned up via a
`trap ... EXIT`, removed even on failure) — it exists only to capture Codex's clean
final review off the noisy exec trace. It is **never** committed; the **PR comment is
the durable reviewer output**.

## Invariants (non-negotiable)

- **Cross-vendor.** Coder = Claude, reviewer = Codex. The reviewer's value is being a
  *different* model, not a second copy of the author.
- **Read-only.** The script **forces** the read-only sandbox with
  `-c sandbox_mode="read-only"` (so it can't inherit a writable config default) and never
  bypasses the sandbox.
- **Comments only.** The script's *only* side effect is one `gh pr comment`. It never
  edits files, pushes, approves-to-merge, or merges, and is never the author.
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
        ├── pass      →  hand to the human merge gate (no auto-merge in Phase 1)
        └── not pass  →  Faber spawns coder (fix mode) to address comments
                              ↓
                         Faber re-runs codex-review.sh   (bump round-N)
                              ↺  repeat
                              └── ~3-round cap → label needs-human → Faber pings you
```

Faber, not the reviewer, drives each step; Claude and Codex never talk directly — the
**PR is the message bus**. Rounds + escalation live in the **labels**
(`round-0..3`, `needs-human`), not in any agent's memory.

## Upgrades / alternatives

- **Codex GitHub integration** — the **autonomous** upgrade. Codex posts its review on
  PR events itself (PR opened/updated), so the loop no longer needs a Faber session to
  invoke the script. Same invariants (cross-vendor, read-only, comments-only). Setting
  it up is out of scope here; this script is the in-session path that works today.
- **codex-plugin-cc** — an **interactive** alternative: drive Codex review from inside a
  Claude Code session via the plugin, rather than the standalone CLI script.

> Note: Codex on your ChatGPT plan is fine for personal repos (first-party feature =
> ordinary use). Apply terms diligence before pointing it at any work/shared repo.
