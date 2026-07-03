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

## north star

The north star is **per target**: the debate is judged against the **target repo's own
committed `.fabrica/north-star.md`** — set, committed, and operator-approved in that repo.
`manager-review.sh` resolves it via the shared resolver (`scripts/lib/north-star.sh`) from
the cwd's checkout and reads the **committed** copy pinned to the **gh-bound remote's
default-branch commit, fetched fresh** (#102) — not raw local HEAD. The default branch is
where reviewed changes land via the loop, so its committed star is the *integrated* one (the
best available proxy for operator approval); anchoring there stops a star committed on a
**feature branch** from authorizing proactive work. The gate selects the git remote whose URL
matches the repo `gh` resolves for the cwd (the same gh-bound remote-identity pattern
`codex-review.sh` uses — prefer `origin` only if it matches, else e.g. `upstream` in a fork),
**fetches that remote's default branch into a private per-run ref** (never trusting a possibly
stale local `refs/remotes/<remote>/HEAD`), and pins **both** the north-star read **and** the
Codex review worktree to that fetched commit. The north star is an autonomy-authorization
artifact, so an uncommitted working-tree edit (or a feature-branch-only edit) must **not**
silently redirect the gate. A target with **no committed** north star on that default branch
(or one still carrying the shipped Fabrica default marker) does **not** authorize proactive
work: the gate FAILs before invoking Codex, with a pointer back here.

The anchor is also hardened against three transport/identity attacks (an adversarial sweep):
(1) the **default-branch NAME** is read *authoritatively* from the remote (`git ls-remote
--symref … HEAD`), never the stale/locally-spoofable local tracking `HEAD` symref, so a repoint
or a spoofed local symref can't anchor to a non-default branch; (2) before fetching, the gate
asserts the remote's **effective** fetch URL (after any `url.<base>.insteadOf` rewrite) still
resolves to the **same** GitHub identity `gh` bound the verdict to — a `url.<other>.insteadOf`
that would silently redirect the fetch to a *different* repo FAILs (read repo A / post to repo B
is refused); (3) the anchor fetch uses `--refmap=` so it writes **only** its private per-run ref
and never mutates the operator's remote-tracking refs.

**Fail vs. fallback (gh-bound).** `manager-review.sh` reads *and posts* a GitHub issue, so its
anchor must bind to the **same repo identity** it comments on. If `gh` resolves a repo but **no
configured remote matches** that identity, the gate **FAILs clearly** — it does **not** fall
back to local HEAD (an unbound local anchor while commenting on a gh-bound issue is the
wrong-source risk). The **visible local-default/HEAD fallback** (logged, never silent) applies
**only** to a genuinely local / greenfield-pre-remote target with no GitHub repo at all — where
there is no issue to post to anyway. `doctor.sh` (a diagnostic that may run local-only) keeps a
visible local fallback for the no-repo / no-matching-remote case, and logs it.

Fabrica-self is its **own** target. When the gate runs against this control-plane repo it
reads its own root [`NORTH_STAR.md`](../NORTH_STAR.md) (Fabrica's real approved goal) — that
root file is now **only** Fabrica-self's target file, not the source for adopters. Adopters set
their direction in their target's `.fabrica/north-star.md`, not in the control-plane root.

## Why issue-as-bus (and not a one-shot print)

Code review happens **on the PR**, over rounds; manager-review happens **on the issue**,
over rounds. Faber and Codex never talk directly — the **issue is the message bus**, just
as the PR is for code review. `manager-review.sh` posts Codex's verdict as an **issue
comment** (verbatim); Faber reads it and either advances, refines (another round), or
drops — and every step is recorded on the issue thread, so the debate is auditable and
state never lives in an agent's memory.

## The rounds model

```
Step 0 — gate check: has the operator explicitly approved the ACTIVE north star?
   (the target's committed .fabrica/north-star.md — Fabrica-self uses its root
    NORTH_STAR.md. Faber knows the approval from the operator, NOT from a line in
    the file — a fresh adopter clone showing the shipped Fabrica default, or any
    `approved-by-user`-style text, is the prior owner's history, NOT this operator's go.)
        ├── unset / not committed / not yet operator-approved / still the shipped default
        │      → do NOT draft, do NOT run the debate, do NOT apply `ready`;
        │        ask the operator to set + commit + approve their own north star first
        │        (that approval is the root authorization for ALL proactive work)
        └── operator has explicitly approved the active north star → proceed:
        ↓
Faber drafts a proactive issue (created, NOT `ready`, labeled `debating`)
        ↓
Faber runs manager-review.sh <issue#>   (by absolute path, from the target repo's clone)
   (script posts Codex's PROCEED / REFINE / DROP verdict to the issue, verbatim)
        ↓
Faber reads the Codex comment and forms its own view
        ├── CONSENSUS to proceed (Faber agrees AND Codex says PROCEED)
        │      → remove `debating`, apply `ready`, and run the loop — NO per-issue
        │        user approval (the consensus IS the gate for proactive north-star
        │        work; the user gates the direction, not each issue)
        ├── REFINE → Faber edits the issue + posts a reply comment (issue-as-bus)
        │      + re-runs manager-review.sh   ← this is a ROUND; cap ~2 rounds
        │      ↺ repeat
        └── DROP / no consensus by the cap → close the issue with a rationale comment
```

Rounds are capped at **~2**: a proposal that can't reach consensus in two passes is
dropped, not debated forever. The `debating` label marks an issue that is mid-debate (not
yet approved); it is removed when the issue advances to `ready` or is closed.

## Consensus / veto-only (the rule)

- **Step 0 — the operator must have explicitly approved the active north star.** Before Faber
  drafts a proactive issue, runs this manager-debate, or applies `ready` on consensus, Faber must
  confirm *from the operator* that they have explicitly approved the target's active north star —
  the target repo's committed **`.fabrica/north-star.md`** (Fabrica-self uses its root
  [`NORTH_STAR.md`](../NORTH_STAR.md); see [north star](#north-star) above). Faber knows this
  **from the operator, not from a line in the file** — a fresh adopter clone showing the shipped
  Fabrica default (or any `approved-by-user`-style text) is the prior owner's history, **not** this
  operator's go. If the north star is **unset, not committed, not yet approved by this operator, or
  still the shipped Fabrica default**, Faber does **not** start this gate or self-apply `ready` — it
  asks the operator to set, commit, and approve their own north star first (that approval is the
  root authorization that unlocks all proactive work). This is the same step-0 guard the manager
  prompt (`manager/CLAUDE.md`) and the generated `/faber` command (`templates/faber-command.md`)
  carry — the consensus gate below is legitimate *only* under an operator-approved north star.
- **Consensus IS the gate (proactive issues).** For a proactive issue *under an operator-approved
  north star* (see step 0 above), the manager-debate
  is not just a recommendation — it is the **front gate**. On consensus (both Faber and Codex
  agree the issue is worth building) Faber removes `debating`, **applies `ready` itself, and
  runs the loop — with no per-issue user approval.** This does **not** make Faber a
  self-approver: **Faber acting alone still never applies `ready`** — it takes the *passed*
  cross-vendor debate (Faber's agreement **and** Codex PROCEED). The user's gate moved up an
  altitude — the user approves the **north star** and is involved at **north-star achieved**,
  **goal drift / transition**, and `needs-human`; *within* an approved north star, the
  cross-vendor consensus gates proactive work. (**User-directed issues keep the direct gate** —
  the user's approval of the spec Faber drafts from their one-liner is the judgment (the
  one-liner is the request, not the go); this consensus gate is only for the issues Faber
  raises on its own.)
- **The manager-reviewer is VETO-ONLY.** It never merges, approves, labels `ready`, or
  edits the issue — its *only* effect is the verdict comment. It cannot advance an issue;
  it can only object to one. (Mirror of the code reviewer being comments-only.)
- **Default-drop on no consensus.** If they don't agree by the round cap, the issue is
  closed — the bar for spending the team's effort is consensus, not a single voice.
- **Never rubber-stamp, never invent busywork.** Codex is told to default to DROP on
  genuine doubt; a proposal that doesn't clearly serve the north star is dropped.
- **But LOG the override-worthy drops.** When Faber believed a *vetoed* item was genuinely
  north-star-relevant, Faber records it in the target's north-star log (the
  "vetoed-but-Faber-thought-relevant" section of that target's `.fabrica/north-star.md`;
  Fabrica-self logs to its root [`NORTH_STAR.md`](../NORTH_STAR.md)), so the human can see
  what consensus filtered out and override it if they want. Default-drop is the floor, not
  a silent shredder.

> **Front gate at the north-star altitude (#49).** Per the user-authorized front-gate
> change in **#49**, the manager-debate consensus **is** the gate for proactive issues: on
> consensus Faber removes `debating`, applies `ready`, and runs the loop — **no per-issue
> user approval.** The user's gate moved up an altitude: the user approves the **north star /
> direction** and is involved at **north-star achieved**, **goal drift / transition**, and
> `needs-human` escalations; *proactive* work inside an approved north star is Faber's to drive on consensus (user-directed issues still need the user's approval of the drafted spec).
> This is not self-approval — **Faber acting alone still never applies `ready`**; it takes the
> passed cross-vendor debate (Faber's agreement **and** Codex PROCEED). **User-directed issues
> keep the direct gate** (the user's approval of the spec Faber drafts from their one-liner —
> the one-liner is the request, not the go).

## How the manager-reviewer actually runs

[`scripts/manager-review.sh`](../scripts/manager-review.sh) is the harness. It operates on
the **current repo** — `gh` infers `<owner>/<repo>` from the cwd's git remote, and the
verdict comment is posted to that repo's issue — so **invoke it from within the target
repo's clone**. The script lives only in *this* control-plane repo, so call it by its
**absolute path** (or put `<fabrica>/scripts` on your `PATH`); don't copy it into each
target repo. It `unset`s `GH_REPO` then derives the repo from the cwd and passes an
explicit `--repo` to every `gh` call, so a `GH_REPO` in the environment can't redirect the
comment to a *different* repo's issue. Then:

1. **Reads the target's committed north star at the gh-bound default-branch commit, fetched
   fresh** (#102) — resolved *for the target this run operates on* via the shared resolver
   (`scripts/lib/north-star.sh`, located from the script's own location by following symlinks
   then `dirname/..`, the same derivation `install.sh`/`doctor.sh` use). It selects the git
   remote matching the repo `gh` resolves (shared `scripts/lib/gh-remote.sh` — the same gh-bound
   remote-identity pattern `codex-review.sh` uses), **fetches that remote's default branch into a
   private per-run ref**, and pins the read to that fetched commit: for a normal target,
   `git show <default-branch-commit>:.fabrica/north-star.md`; on a Fabrica-self run, the
   control-plane root `NORTH_STAR.md` at the same commit. The per-run ref is cleaned up on exit.
   It reads the **committed** copy at the **default-branch** commit — not the working tree, and
   not raw local HEAD — because the north star is an autonomy-authorization artifact: an
   uncommitted local edit (or a feature-branch-only edit) must not silently redirect the gate; the
   integrated (default-branch) state is the approved goal. If `gh` resolves a repo but no
   configured remote matches, the gate **FAILs** (it will not anchor to local HEAD while
   commenting on the gh-bound issue); a genuinely local/greenfield target with no remote uses a
   **visible** local-HEAD fallback (logged). If there is no committed north star on that
   default-branch commit (or it still carries the shipped Fabrica default marker), the gate
   **FAILs before invoking Codex** with an actionable pointer — the debate needs an integrated,
   committed goal to judge against. It also reads the issue's title + body (`gh issue view
   <issue#> --json title,body`).
2. **Runs `printf '%s' "<prompt>" | codex exec -C <worktree> -c sandbox_mode="read-only" -o <tmpfile> -`** —
   the prompt is fed over **stdin** (the trailing `-`), not as an argv argument, so a large
   issue body + comment thread can't trip `E2BIG` or leak into process listings. Codex forms
   the manager-review with the **manager-reviewer prompt + the north star + the issue +
   "read the repo to ground your judgment"** (below). Unlike `codex-review.sh`, this uses a
   **hand-written prompt**, not Codex's built-in `review`: there is no built-in "should this
   issue exist?" review, and the point is Codex's own independent judgment on the *proposal
   vs. the north star*. The `-c sandbox_mode="read-only"` override **forces** the read-only
   sandbox so the review can't inherit a writable default from the operator's Codex config;
   the script deliberately does **not** pass `--dangerously-bypass-approvals-and-sandbox`,
   and avoids `--ignore-user-config` so the operator's model/effort defaults still apply.
   Codex grounds its judgment by reading a **clean detached temp worktree at the same anchored
   default-branch commit** — `git worktree add --detach <worktree> <default-branch-commit>` under
   `mktemp -d`, with `codex exec -C <worktree>` pinning the review there — isolated from the
   operator's live checkout, so Codex sees only the tracked content at that integrated commit,
   never untracked/ignored/uncommitted files (`.env`, secrets, local WIP) or a feature-branch
   variant. The read-only sandbox blocks writes but not reads, so the worktree — not the sandbox —
   is what keeps the operator's dirty/local state out of the review, mirroring `codex-review.sh`'s
   isolation. The worktree, the `<tmpfile>` below, and the private per-run anchor ref are removed
   via a `trap ... EXIT` on every exit. There is no PR head to fetch as a *diff* (this judges an
   issue, not a diff); the **freshly-fetched default-branch commit** is what the read and the
   worktree are both materialized at.
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

The script builds this prompt from the role + the target's current committed north star
(the target's `.fabrica/north-star.md`, or Fabrica-self's root `NORTH_STAR.md`) + the issue
title/body + a "read the repo to ground your judgment" instruction, and asks for a structured
**PROCEED / REFINE / DROP** verdict:

> You are the cross-vendor MANAGER reviewer for an autonomous coding team. Faber (a Claude
> manager) has DRAFTED the GitHub issue below as a *proactive* proposal toward the team's
> current north star. Your job is to debate whether this issue is worth raising NOW — not
> to review code, and not to rubber-stamp it. You are VETO-ONLY: you never approve, label,
> edit the issue, or merge anything; you only give a verdict that Faber weighs. The team
> proceeds ONLY on consensus, and DEFAULT-DROPS on no consensus, so do not invent busywork.
>
> — the **current north star** (the target's committed north star) —
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
