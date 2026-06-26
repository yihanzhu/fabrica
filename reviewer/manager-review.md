# Manager-reviewer — Codex (OpenAI), via `scripts/manager-review.sh`

Fabrica has a cross-vendor **code** reviewer ([`codex-review.sh`](../scripts/codex-review.sh) —
Codex reviews a PR, with the **PR as the message bus**). The **manager-reviewer** is the
same idea one layer up: a cross-vendor reviewer that debates with Faber whether a
*proposed issue* is worth raising toward the team's north star — **with the ISSUE as the
message bus** (the mirror of PR-as-bus). It runs on **Codex**, not as a Claude routine, so
the judgment on "should we even build this?" comes from a *different* model than the Claude
manager that drafted it — the same cross-vendor split that decorrelates blind spots
(coder = Claude, reviewer = Codex; manager = Claude, manager-reviewer = Codex).

This gate is for Faber's **proactive** (self-generated) proposals toward the north star.
**User-directed issues skip it** — when the human asks for something directly, that *is*
the judgment; the manager-debate is for the issues Faber raises on its own.

## Why issue-as-bus (and not a one-shot print)

Code review happens **on the PR**, over rounds; manager-review happens **on the issue**,
over rounds. Faber and Codex never talk directly — the **issue is the message bus**, just
as the PR is for code review. `manager-review.sh` posts Codex's verdict as an **issue
comment** (verbatim); Faber reads it and either advances, refines (another round), or
drops — and every step is recorded on the issue thread, so the debate is auditable and
state never lives in an agent's memory.

## The rounds model

```
Faber drafts a proactive issue (created, NOT `ready`, labeled `debating`)
        ↓
Faber runs manager-review.sh <issue#>   (by absolute path, from the target repo's clone)
   (script posts Codex's PROCEED / REFINE / DROP verdict to the issue, verbatim)
        ↓
Faber reads the Codex comment and forms its own view
        ├── CONSENSUS to proceed (Faber agrees AND Codex says PROCEED)
        │      → remove `debating`, then bring the vetted issue to the USER for the
        │        front gate (the user's approval — recorded by applying `ready` — is
        │        still required to launch the coder; the debate vets, it doesn't approve)
        ├── REFINE → Faber edits the issue + posts a reply comment (issue-as-bus)
        │      + re-runs manager-review.sh   ← this is a ROUND; cap ~2 rounds
        │      ↺ repeat
        └── DROP / no consensus by the cap → close the issue with a rationale comment
```

Rounds are capped at **~2**: a proposal that can't reach consensus in two passes is
dropped, not debated forever. The `debating` label marks an issue that is mid-debate (not
yet approved); it is removed when the issue advances to `ready` or is closed.

## Consensus / veto-only (the rule)

- **Consensus vets; the user gates.** The manager-debate is a *vetting / recommendation*
  step, not an approval. Consensus (both Faber and Codex agree the issue is worth building)
  clears the issue out of `debating` and lets Faber bring it to the **user** — but the coder
  loop still starts only on the **user's explicit approval** (recorded by applying `ready`).
  Faber never self-applies `ready`: the user's approval is the front gate, and consensus
  precedes it rather than replacing it.
- **The manager-reviewer is VETO-ONLY.** It never merges, approves, labels `ready`, or
  edits the issue — its *only* effect is the verdict comment. It cannot advance an issue;
  it can only object to one. (Mirror of the code reviewer being comments-only.)
- **Default-drop on no consensus.** If they don't agree by the round cap, the issue is
  closed — the bar for spending the team's effort is consensus, not a single voice.
- **Never rubber-stamp, never invent busywork.** Codex is told to default to DROP on
  genuine doubt; a proposal that doesn't clearly serve the north star is dropped.
- **But LOG the override-worthy drops.** When Faber believed a *vetoed* item was genuinely
  north-star-relevant, Faber records it in [`NORTH_STAR.md`](../NORTH_STAR.md)'s
  north-star log (the "vetoed-but-Faber-thought-relevant" section), so the human can see
  what consensus filtered out and override it if they want. Default-drop is the floor, not
  a silent shredder.

> **Deferred: fully-autonomous proactive mode (#49).** Today the manager-debate only
> *vets* — consensus removes `debating` and Faber brings the issue to the user, whose
> approval (the `ready` label) is still required to launch the coder. Making
> **manager-debate consensus itself the gate** (no per-issue user approval for proactive
> issues) is a deliberate *front-gate change* deferred to issue **#49**, pending the user's
> explicit sign-off. Until then: today = vet, then the user gates; #49 = consensus gates
> (after sign-off).

## How the manager-reviewer actually runs

[`scripts/manager-review.sh`](../scripts/manager-review.sh) is the harness. It operates on
the **current repo** — `gh` infers `<owner>/<repo>` from the cwd's git remote, and the
verdict comment is posted to that repo's issue — so **invoke it from within the target
repo's clone**. The script lives only in *this* control-plane repo, so call it by its
**absolute path** (or put `<fabrica>/scripts` on your `PATH`); don't copy it into each
target repo. It `unset`s `GH_REPO` then derives the repo from the cwd and passes an
explicit `--repo` to every `gh` call, so a `GH_REPO` in the environment can't redirect the
comment to a *different* repo's issue. Then:

1. **Reads the current north star** from [`NORTH_STAR.md`](../NORTH_STAR.md) in the
   **control-plane repo** — resolved from the script's *own* location (follow symlinks, then
   `dirname/..`), the same derivation `install.sh`/`doctor.sh` use, so it reads the control
   plane's north star regardless of which target repo's cwd it is run from (the file lives
   in fabrica, not in each target repo; errors out with a pointer if it is missing — the
   debate needs a goal to judge against). It also reads the issue's title + body (`gh issue
   view <issue#> --json title,body`).
2. **Runs `codex exec -C <worktree> -c sandbox_mode="read-only" -o <tmpfile> "<prompt>"`** — Codex forms
   the manager-review with the **manager-reviewer prompt + the north star + the issue +
   "read the repo to ground your judgment"** (below). Unlike `codex-review.sh`, this uses a
   **hand-written prompt**, not Codex's built-in `review`: there is no built-in "should this
   issue exist?" review, and the point is Codex's own independent judgment on the *proposal
   vs. the north star*. The `-c sandbox_mode="read-only"` override **forces** the read-only
   sandbox so the review can't inherit a writable default from the operator's Codex config;
   the script deliberately does **not** pass `--dangerously-bypass-approvals-and-sandbox`,
   and avoids `--ignore-user-config` so the operator's model/effort defaults still apply.
   Codex grounds its judgment by reading a **clean detached temp worktree at HEAD** —
   `git worktree add --detach <worktree> HEAD` under `mktemp -d`, with `codex exec -C
   <worktree>` pinning the review there — isolated from the operator's live checkout, so
   Codex sees only the tracked content at HEAD, never untracked/ignored/uncommitted files
   (`.env`, secrets, local WIP). The read-only sandbox blocks writes but not reads, so the
   worktree — not the sandbox — is what keeps the operator's dirty/local state out of the
   review, mirroring `codex-review.sh`'s isolation. The worktree (and the `<tmpfile>` below)
   is removed via a `trap ... EXIT` on every exit. There is no PR head to fetch (this judges
   an issue, not a diff); HEAD is the commit the worktree is materialized at.
3. **Posts Codex's verdict to the issue VERBATIM**: `gh issue comment <issue#> --body-file
   <tmpfile>`, prefixed only with a short header marking it the Codex manager-reviewer (and
   also echoes it to stdout). No Claude session rewrites, blends, or summarizes it — that
   preserves the independence of the second opinion. The `<tmpfile>` lives in the system
   temp dir, never inside the repo, and is cleaned up via a `trap ... EXIT` (removed even on
   failure); it is never committed — the **issue comment is the durable reviewer output**.

```
# run from within the TARGET repo's clone; invoke the script by ABSOLUTE PATH
# (it lives only in the fabrica control-plane repo — do NOT copy it per repo).
# Substitute your fabrica clone for "$HOME/git/fabrica".
"$HOME/git/fabrica/scripts/manager-review.sh" <issue#>             # e.g. ... 44
"$HOME/git/fabrica/scripts/manager-review.sh" -m <model> <issue#>  # optional model override

# Optional: add fabrica/scripts to PATH once, then call it by name from any target repo:
#   export PATH="$HOME/git/fabrica/scripts:$PATH"   # (add to your shell rc)
#   manager-review.sh <issue#>
```

## The manager-reviewer prompt

The script builds this prompt from the role + the current north star (from
`NORTH_STAR.md`) + the issue title/body + a "read the repo to ground your judgment"
instruction, and asks for a structured **PROCEED / REFINE / DROP** verdict:

> You are the cross-vendor MANAGER reviewer for an autonomous coding team. Faber (a Claude
> manager) has DRAFTED the GitHub issue below as a *proactive* proposal toward the team's
> current north star. Your job is to debate whether this issue is worth raising NOW — not
> to review code, and not to rubber-stamp it. You are VETO-ONLY: you never approve, label,
> edit the issue, or merge anything; you only give a verdict that Faber weighs. The team
> proceeds ONLY on consensus, and DEFAULT-DROPS on no consensus, so do not invent busywork.
>
> — the **current north star** (from `NORTH_STAR.md`) —
> — the **proposed issue** (title + body) —
>
> Read the repository (read-only) to ground your judgment in what actually exists. Then
> respond with EXACTLY this structure:
> - **VERDICT:** PROCEED / REFINE / DROP (PROCEED = serves the north star, well-scoped;
>   REFINE = north-star-relevant but needs changes first — say what; DROP = doesn't clearly
>   serve the north star / duplicates work / premature — default here on genuine doubt).
> - **REASONING:** why, grounded in the north star and the repo as it stands.
> - **GAP FABER MISSED:** a risk, dependency, simpler path, conflict, or "already covered";
>   or "none".

The exact wording lives in [`scripts/manager-review.sh`](../scripts/manager-review.sh) —
treat the script as the source of truth.

## Invariants (non-negotiable)

- **Cross-vendor.** Manager = Claude (Faber), manager-reviewer = Codex. The reviewer's
  value is being a *different* model judging the proposal, not a second copy of the author.
- **Read-only.** The script **forces** the read-only sandbox with
  `-c sandbox_mode="read-only"` (so it can't inherit a writable config default) and never
  bypasses the sandbox.
- **Comments only / veto-only.** The script's *only* side effect is one `gh issue comment`
  (pinned to the cwd's repo via an explicit `--repo`, with `GH_REPO` unset, so it can't
  post to another repo's issue). It never edits the issue, applies or removes labels,
  pushes, or merges. It cannot advance an issue — only object.
- **Verbatim.** Codex's verdict is posted unedited — no Claude session rewrites, blends, or
  summarizes it. That preserves the independence of the second opinion.
- **Consensus-only + default-drop.** Proceed only when Faber and Codex agree; drop on no
  consensus by the round cap; log the drops Faber thought were north-star-relevant.

## Bootstrap caveat

The issue that *built* `manager-review.sh` couldn't use it (the script didn't exist yet).
That debate was run manually via `codex exec`; the finished script is dogfooded on the next
proactive issue.

## Future / alternatives (not wired)

As with the code reviewer, an **autonomous** Codex GitHub integration (Codex posting the
manager-review on issue events itself, with no Faber session) is a possible later upgrade —
same invariants (cross-vendor, read-only, comments-only, veto-only). Not built; wiring it
is out of scope here.

> Note: Codex on your ChatGPT plan is fine for personal repos (first-party feature =
> ordinary use). Apply terms diligence before pointing it at any work/shared repo.
