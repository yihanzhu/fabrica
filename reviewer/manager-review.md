# Manager-reviewer — Codex (OpenAI), via `scripts/manager-review.sh`

ystack has a cross-vendor **code** reviewer ([`codex-review.sh`](../scripts/codex-review.sh) —
Codex reviews a PR, with the **PR as the message bus**). The **manager-reviewer** is the
same idea one layer up: a cross-vendor reviewer that debates with yshifu whether a
*proposed issue* is worth raising toward the team's north star — **with the ISSUE as the
message bus** (the mirror of PR-as-bus). It runs on **Codex**, not as a Claude routine, so
the judgment on "should we even build this?" comes from a *different* model than the Claude
manager that drafted it — the same cross-vendor split that decorrelates blind spots
(coder = Claude, reviewer = Codex; manager = Claude, manager-reviewer = Codex).

This gate is for yshifu's **proactive** (self-generated) proposals toward the north star.
**User-directed issues skip it** — when the human asks for something directly, that *is*
the judgment; the manager-debate is for the issues yshifu raises on its own.

## north star

The north star is **per target**: the debate is judged against the **target repo's own
committed `.ystack/north-star.md`** — set, committed, and operator-approved in that repo.
`manager-review.sh` resolves it via the shared resolver (`scripts/lib/north-star.sh`) from
the cwd's checkout and reads the **committed** copy pinned to the **gh-bound remote's
default-branch commit, fetched fresh** — not raw local HEAD. The default branch is
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
does **not** authorize proactive work — nor does one still carrying the shipped default marker
(`ystack-shipped-default`; the legacy `fabrica-shipped-default` marker is treated the same way):
the gate FAILs before invoking Codex, with a pointer back here.

The anchor is **gh-authoritative and fail-closed** (an adversarial sweep): every
input that decides *what* the gate reads is proven against the **same `gh` binding the verdict
posts to**, and any step not provable → **FAIL**. (1) The **default-branch NAME** comes from
gh's `defaultBranchRef` (`gh repo view --json defaultBranchRef`), *not* the stale/locally-
spoofable local `refs/remotes/<remote>/HEAD` symref and *not* `ls-remote` off a remote an
insteadOf could redirect — so a repoint or a spoofed local symref can't anchor to a non-default
branch, and if gh can't resolve the default on a gh-bound run the gate FAILs. (2) Before
fetching, the gate asserts the selected remote's **effective** fetch URL (after any
`url.<base>.insteadOf` rewrite) is a **non-empty GitHub identity equal to** the one `gh` bound
the verdict to — a cross-repo `url.<other>.insteadOf` (read repo A / post to repo B) FAILs, and
so does a rewrite to a **local path / `file://` / `ext::`** or any transport the gate cannot
*prove* is gh's repo (round-2 closed the earlier "empty ⇒ trusted" hole; a deliberate local
mirror is an explicit `YSTACK_ALLOW_LOCAL_MIRROR=1` opt-in, never the default). Remote
*selection* stays available (it matches the configured URL first, then falls back to the
effective URL, so an SSH-alias/shorthand remote still selects — safety is still enforced by the
effective-identity assert before any fetch). (3) The anchor fetch uses `--refmap=` so it writes
**only** its private per-run ref and never mutates the operator's remote-tracking refs.

**Fail vs. fallback (gh-bound).** `manager-review.sh` reads *and posts* a GitHub issue, so its
anchor must bind to the **same repo identity** it comments on. If `gh` resolves a repo but **no
configured remote matches** that identity, the gate **FAILs clearly** — it does **not** fall
back to local HEAD (an unbound local anchor while commenting on a gh-bound issue is the
wrong-source risk). The **visible local-default/HEAD fallback** (logged, never silent) applies
**only** to a genuinely local / greenfield-pre-remote target with no GitHub repo at all — where
there is no issue to post to anyway. `doctor.sh` (a diagnostic that may run local-only) keeps a
visible local fallback for the no-repo / no-matching-remote case, and logs it.

ystack-self is its **own** target. When the gate runs against this control-plane repo it
reads its own root [`NORTH_STAR.md`](../NORTH_STAR.md) (ystack's real approved goal) — that
root file is now **only** ystack-self's target file, not the source for adopters. Adopters set
their direction in their target's `.ystack/north-star.md`, not in the control-plane root.

## Why issue-as-bus (and not a one-shot print)

Code review happens **on the PR**, over rounds; manager-review happens **on the issue**,
over rounds. yshifu and Codex never talk directly — the **issue is the message bus**, just
as the PR is for code review. `manager-review.sh` posts Codex's verdict as an **issue
comment** (verbatim); yshifu reads it and either advances, refines (another round), or
drops — and every step is recorded on the issue thread, so the debate is auditable and
state never lives in an agent's memory.

## The rounds model

```
Step 0 — gate check: has the operator explicitly approved the ACTIVE north star?
   (the target's committed .ystack/north-star.md — ystack-self uses its root
    NORTH_STAR.md. yshifu knows the approval from the operator, NOT from a line in
    the file — a fresh adopter clone showing the shipped ystack default, or any
    `approved-by-user`-style text, is the prior owner's history, NOT this operator's go.)
        ├── unset / not committed / not yet operator-approved / still the shipped default
        │      → do NOT draft, do NOT run the debate, do NOT apply `ready`;
        │        ask the operator to set + commit + approve their own north star first
        │        (that approval is the root authorization for ALL proactive work)
        └── operator has explicitly approved the active north star → proceed:
        ↓
yshifu drafts a proactive issue (created, NOT `ready`, labeled `debating`)
        ↓
yshifu runs manager-review.sh <issue#>   (by absolute path, from the target repo's clone)
   (script posts Codex's PROCEED / REFINE / DROP verdict to the issue, verbatim)
        ↓
yshifu reads the Codex comment and forms its own view
        ├── CONSENSUS to proceed (yshifu agrees AND Codex says PROCEED)
        │      → remove `debating`; record exact-revision proactive intake acceptance
        │        — NO per-issue user approval (consensus clears intake only)
        │      → merge G1 intent → merge G2 spec-with-risk → applicable plan gate
        │      → only then apply `ready` and run the implementation loop
        ├── REFINE → yshifu edits the issue + posts a reply comment (issue-as-bus)
        │      + re-runs manager-review.sh   ← this is a ROUND; cap ~2 rounds
        │      ↺ repeat
        └── DROP / no consensus by the cap → close the issue with a rationale comment
```

Each verdict comment carries `Intake-title-sha256: <64-hex>` and
`Intake-body-sha256: <64-hex>`. The harness hashes the exact non-null UTF-8 title and
body from the forge API, with no added newline or normalization, before and after Codex
runs. If either moved, no verdict is posted. Proactive intake acceptance must cite a
passed verdict whose markers match both digests it accepts.
For a resumed session, select the newest comment by the current `gh` operator with
exactly one manager-reviewer clean header and one matching anchored marker for each
digest before filtering by verdict.
Then require exactly one anchored `VERDICT: PROCEED`. A newer REFINE/DROP/malformed
comment blocks every older go; bare, cross-author, mixed, zero/multiple-verdict, or
duplicate-marker evidence never clears intake.

Rounds are capped at **~2**: a proposal that can't reach consensus in two passes is
dropped, not debated forever. The `debating` label marks an issue that is mid-debate (not
yet accepted); it is removed when consensus advances the issue to the artifact chain or
the issue is closed.

## Consensus / veto-only (the rule)

- **Step 0 — the operator must have explicitly approved the active north star.** Before yshifu
  drafts a proactive issue or runs this manager-debate, yshifu must
  confirm *from the operator* that they have explicitly approved the target's active north star —
  the target repo's committed **`.ystack/north-star.md`** (ystack-self uses its root
  [`NORTH_STAR.md`](../NORTH_STAR.md); see [north star](#north-star) above). yshifu knows this
  **from the operator, not from a line in the file** — a fresh adopter clone showing the shipped
  ystack default (or any `approved-by-user`-style text) is the prior owner's history, **not** this
  operator's go. If the north star is **unset, not committed, not yet approved by this operator, or
  still the shipped ystack default**, yshifu does **not** start this gate — it
  asks the operator to set, commit, and approve their own north star first (that approval is the
  root authorization that unlocks all proactive work). This is the same step-0 guard the manager
  prompt (`manager/CLAUDE.md`) and the generated `/yshifu` command (`templates/yshifu-command.md`)
  carry — the consensus gate below is legitimate *only* under an operator-approved north star.
- **Consensus IS the intake gate (proactive issues).** For a proactive issue *under an operator-approved
  north star* (see step 0 above), the manager-debate
  is not just a recommendation — it is the **intake gate**. On consensus (both yshifu and Codex
  agree the issue is worth pursuing) yshifu removes `debating` and records the accepted
  exact issue revision, with no per-issue user approval. It does **not** apply `ready` yet:
  new normal work must still pass G1 intent, G2 spec-with-risk, and its plan gate.
  This does **not** make yshifu a self-approver: yshifu acting alone cannot record proactive
  intake acceptance — it takes the *passed* cross-vendor debate (yshifu's agreement **and**
  Codex PROCEED). The user's gate moved up an
  altitude — the user approves the **north star** and is involved at **north-star achieved**,
  **goal drift / transition**, and `needs-human`; *within* an approved north star, the
  cross-vendor consensus gates proactive intake. (**User-directed issues keep the direct gate** —
  the user's approval of the concrete intake draft is the judgment (the
  one-liner is the request, not the go); this consensus gate is only for the issues yshifu
  raises on its own.)
- **The manager-reviewer is VETO-ONLY.** It never merges, approves, labels `ready`, or
  edits the issue — its *only* effect is the verdict comment. It cannot advance an issue;
  it can only object to one. (Mirror of the code reviewer being comments-only.)
- **Default-drop on no consensus.** If they don't agree by the round cap, the issue is
  closed — the bar for spending the team's effort is consensus, not a single voice.
- **Never rubber-stamp, never invent busywork.** Codex is told to default to DROP on
  genuine doubt; a proposal that doesn't clearly serve the north star is dropped.
- **But LOG the override-worthy drops.** When yshifu believed a *vetoed* item was genuinely
  north-star-relevant, yshifu records it in the target's north-star log (the
  "vetoed-but-yshifu-thought-relevant" section of that target's `.ystack/north-star.md`;
  ystack-self logs to its root [`NORTH_STAR.md`](../NORTH_STAR.md)), so the human can see
  what consensus filtered out and override it if they want. Default-drop is the floor, not
  a silent shredder.

> **Front gate at the north-star altitude.** The manager-debate consensus **is** the intake gate for proactive issues:
> on consensus yshifu removes `debating` and records exact-revision intake acceptance —
> **no per-issue user approval.** G1, G2-with-risk, and the plan gate still precede `ready`.
> The user's gate moved up an altitude: the user approves the **north star /
> direction** and is involved at **north-star achieved**, **goal drift / transition**, and
> `needs-human` escalations; *proactive* work inside an approved north star is yshifu's to drive on consensus (user-directed issues still need the user's approval of the drafted intake).
> This is not self-approval — **yshifu acting alone still never accepts proactive intake**; it takes the
> passed cross-vendor debate (yshifu's agreement **and** Codex PROCEED). **User-directed issues
> keep the direct gate** (the user's approval of the intake yshifu drafts from their one-liner —
> the one-liner is the request, not the go).

## How the manager-reviewer actually runs

[`scripts/manager-review.sh`](../scripts/manager-review.sh) is the harness. It operates on
the **current repo** — `gh` infers `<owner>/<repo>` from the cwd's git remote, and the
verdict comment is posted to that repo's issue — so **invoke it from within the target
repo's clone**. The script lives only in *this* control-plane repo, so call it by its
**absolute path** (or put `<ystack>/scripts` on your `PATH`); don't copy it into each
target repo. It `unset`s `GH_REPO` then derives the repo from the cwd and passes an
explicit `--repo` to every `gh` call, so a `GH_REPO` in the environment can't redirect the
comment to a *different* repo's issue. Then:

1. **Reads the target's committed north star at the gh-bound default-branch commit, fetched
   fresh** — resolved *for the target this run operates on* via the shared resolver
   (`scripts/lib/north-star.sh`, located from the script's own location by following symlinks
   then `dirname/..`, the same derivation `install.sh`/`doctor.sh` use). It selects the git
   remote matching the repo `gh` resolves (shared `scripts/lib/gh-remote.sh` — the same gh-bound
   remote-identity pattern `codex-review.sh` uses), **fetches that remote's default branch into a
   private per-run ref**, and pins the read to that fetched commit: for a normal target,
   `git show <default-branch-commit>:.ystack/north-star.md`; on a ystack-self run, the
   control-plane root `NORTH_STAR.md` at the same commit. The per-run ref is cleaned up on exit.
   It reads the **committed** copy at the **default-branch** commit — not the working tree, and
   not raw local HEAD — because the north star is an autonomy-authorization artifact: an
   uncommitted local edit (or a feature-branch-only edit) must not silently redirect the gate; the
   integrated (default-branch) state is the approved goal. If `gh` resolves a repo but no
   configured remote matches, the gate **FAILs** (it will not anchor to local HEAD while
   commenting on the gh-bound issue); a genuinely local/greenfield target with no remote uses a
   **visible** local-HEAD fallback (logged). If there is no committed north star on that
   default-branch commit (or it still carries the shipped ystack default marker), the gate
   **FAILs before invoking Codex** with an actionable pointer — the debate needs an integrated,
   committed goal to judge against. It also reads the issue's title + body (`gh issue view
   <issue#> --json title,body`).
2. **Runs `printf '%s' "<prompt>" | codex exec -C <worktree> --json -c sandbox_mode="read-only" -c model_reasoning_effort="<effort>" -o <tmpfile> [-m <model>] -`** —
   the prompt is fed over **stdin** (the trailing `-`), not as an argv argument, so a large
   issue body + comment thread can't trip `E2BIG` or leak into process listings. Codex forms
   the manager-review with the **manager-reviewer prompt + the north star + the issue +
   "read the repo to ground your judgment"** (below). Unlike `codex-review.sh`, this uses a
   **hand-written prompt**, not Codex's built-in `review`: there is no built-in "should this
   issue exist?" review, and the point is Codex's own independent judgment on the *proposal
   vs. the north star*. The `-c sandbox_mode="read-only"` override **forces** the read-only
   sandbox so the review can't inherit a writable default from the operator's Codex config;
   the script deliberately does **not** pass `--dangerously-bypass-approvals-and-sandbox`,
   and avoids `--ignore-user-config` so the operator's model/effort defaults still apply. See
   **model policy** below for how `<effort>` and the optional `-m <model>` are resolved —
   the gate's reasoning effort is **always** pinned explicitly, never left to inherit whatever
   the operator's personal Codex config happens to default to.
   Codex grounds its judgment by reading a **clean detached temp worktree at the same anchored
   default-branch commit** — `git worktree add --detach <worktree> <default-branch-commit>` under
   `mktemp -d`, with `codex exec -C <worktree>` pinning the review there — isolated from the
   operator's live checkout, so Codex sees only the tracked content at that integrated commit,
   never untracked/ignored/uncommitted files (`.env`, secrets, local WIP) or a feature-branch
   variant. The read-only sandbox blocks writes but not reads, so the worktree — not the sandbox —
   is what keeps the operator's dirty/local state out of the review, mirroring `codex-review.sh`'s
   isolation. This same worktree is also where a target's optional per-target `.ystack/models.conf`
   override (see **model policy** below) is read from, so the config always matches the exact
   commit Codex is grounding its judgment in. The worktree, the `<tmpfile>` below, and the private
   per-run anchor ref are removed via a `trap ... EXIT` on every exit. There is no PR head to
   fetch as a *diff* (this judges an issue, not a diff); the **freshly-fetched default-branch
   commit** is what the read and the worktree are both materialized at.
3. **Posts Codex's verdict to the issue VERBATIM**: `gh issue comment <issue#> --body-file
   <tmpfile>`, prefixed only with a short header marking it the Codex manager-reviewer — including
   a **`reviewer: <model> @ <effort>`** line recording the RESOLVED config that gated this debate
   (see **model policy** below) — (and also echoes it to stdout). No Claude session rewrites,
   blends, or summarizes it — that preserves the independence of the second opinion. The
   `<tmpfile>` lives in the system temp dir, never inside the repo, and is cleaned up via a
   `trap ... EXIT` (removed even on failure); it is never committed — the **issue comment is the
   durable reviewer output**.

```
# run from within the TARGET repo's clone; invoke the script by ABSOLUTE PATH
# (it lives only in the ystack control-plane repo — do NOT copy it per repo).
# Substitute your ystack clone for "$HOME/git/ystack".
"$HOME/git/ystack/scripts/manager-review.sh" <issue#>             # e.g. ... 44
"$HOME/git/ystack/scripts/manager-review.sh" -m <model> <issue#>  # optional model override

# Optional: add ystack/scripts to PATH once, then call it by name from any target repo:
#   export PATH="$HOME/git/ystack/scripts:$PATH"   # (add to your shell rc)
#   manager-review.sh <issue#>
```

## Model policy

The manager-debate gate is a **max-capability decision point** (spend-by-leverage — see
[`config/models.conf`](../config/models.conf) and README.md's "Model policy" section), so it
does not simply inherit the operator's personal Codex defaults. Before doing anything else
(alongside sourcing `scripts/lib/north-star.sh` / `scripts/lib/gh-remote.sh`), the script
sources `config/models.conf` **resolved relative to its own location** (this clone's
control-plane root, following symlinks — never a hardcoded personal path), which sets
`YSTACK_CODEX_MODEL` (empty by default) and `YSTACK_DEBATE_EFFORT` (`high` by default). A
missing or unsourceable `config/models.conf` **fails loudly**, pointing at `scripts/doctor.sh`
check (k), rather than silently debating at an unknown effort.

If the **target repo** has committed its own [`.ystack/models.conf`](../templates/.ystack/models.conf)
(same format/keys, an opt-in per-target override), it may override the **producer/model keys
only**, applied on top of the shipped defaults. A target that has not renamed yet may still
keep the override at the legacy `.fabrica/models.conf` path — the harness still reads it there.
The override is read from the **same anchored worktree the debate runs against** (the detached
worktree checked out at the fetched default-branch commit, step 2 above), never the operator's
possibly-stale or dirty cwd checkout, so the override always reflects the SAME integrated commit
the north star was read from and Codex is grounding its judgment in. A target-committed file
must never run as shell in this non-sandboxed harness (it would execute with the operator's own
`gh`/`codex` credentials), so it is read as **data**, via a strict line-by-line parser
(`mc_parse_target_override` in [`scripts/lib/models-conf.sh`](../scripts/lib/models-conf.sh)) —
never `source`/`.`/`eval`. Only a line matching exactly `YSTACK_<allowedkey>=<value>` is
recognized (value charset-restricted, optionally quoted); every other line — comments, blank
lines, shell metacharacters, command substitutions — is silently ignored, never executed.
Absence of the file is normal (most targets have no override) and is not an error.

**Gate keys are not target-overridable.** The parser recognizes `YSTACK_DEBATE_EFFORT` in a
target's override, but **never applies it** — a target can never lower or otherwise change its
own manager-debate gate. Instead it prints a warning and folds a visible **`warning: target
override attempted to set gate effort — ignored`** line into the posted issue comment, so an
attempted downgrade is never silent.

Applying the resolved config:

- **`-c model_reasoning_effort="$YSTACK_DEBATE_EFFORT"` is ALWAYS passed** — the gate is never
  class-routed down, so this explicitly raises it to the resolved value (`high` by default)
  instead of silently inheriting whatever the operator's `~/.codex/config.toml` happens to
  default to (often `low`), and a target override can never change this value.
- **`-m <model>` is passed only when a model is actually resolved.** The script's own `-m` CLI
  flag keeps precedence over `YSTACK_CODEX_MODEL`; if neither is set, no `-m` is passed at all
  (Codex uses its own default model).
- The **resolved** model + effort are echoed into the posted issue comment's header —
  `reviewer: <model> @ <effort>` (e.g. `reviewer: operator-default @ high` when no model was
  pinned) — so every debate documents on the record exactly what gated it, and any drift from
  a stray personal config is visible in the issue history, not just in a log nobody reads.

## Degraded-review detection

The script FAILS LOUDLY on a degraded/non-substantive Codex run instead of posting a fake
`PROCEED`/`REFINE`/`DROP` verdict — the same hardening as `codex-review.sh`, sharing its
detector so the two gates can't diverge on what counts as degraded (real incident and rationale:
see `codex-review.sh`'s **Degraded-review detection** section and
[`scripts/lib/codex-degraded.sh`](../scripts/lib/codex-degraded.sh)).

**Detection uses the same structured boundary as `codex-review.sh`.** Normal `codex exec -o`
repeats its final, issue-influenced verdict on stdout, so the harness forces `--json`. The shared
detector validates every event/item against its understood schema (unknown future types fail
closed), requires a final `turn.completed` after an agent message plus at least one successful
structured `command_execution`, treats fatal top-level `error` / `turn.failed` as hard failures,
and phrase-matches only CLI-authored error-item or
failed-MCP error fields. Agent messages, reasoning, command output, MCP arguments/results, and
the `-o` verdict body are excluded; raw stderr is still checked for failures outside JSONL.

Detection: **non-zero exit**, **invalid/incomplete/unknown-schema JSONL**, **no successful
command evidence**, **fatal `error` / `turn.failed`**, or a known code-mode/host spawn-failure
signal in a trusted CLI error field/raw stderr → DEGRADED. A genuine completed verdict still
posts normally. An
**empty/whitespace-only** `-o` capture is also refused rather than posting a header-only comment.

On detection: the script exits non-zero and posts `VERDICT: DEGRADED` (never
`PROCEED`/`REFINE`/`DROP`) under a **different** header line than the real `## Codex
manager-reviewer (cross-vendor, read-only)` one, so yshifu's "proceed only on consensus" rule can
never read this as a `PROCEED`.

**The DEGRADED comment never embeds codex's raw output verbatim (same as
`codex-review.sh`).** It never embeds the `-o` verdict answer (untrustworthy on a degraded
run), **never embeds JSONL** (it contains private agent/command/repository payloads), and embeds
only a bounded, sanitized raw-stderr tail via `cd_sanitize_snippet` — every line prefixed `> `,
which breaks the line anchors a marker parser like the one in the operator's
`scripts/merge-pr.sh` would require. This comment is posted by, and authored as, the same
gh-authenticated operator, so it must never be able to carry an unneutralized marker-shaped
line even though that script only reads PR comments today — defense-in-depth against codex's
diagnostic output being adversarially influenced by the issue/repo content it read.

## The manager-reviewer prompt

The script builds this prompt from the role + the target's current committed north star
(the target's `.ystack/north-star.md`, or ystack-self's root `NORTH_STAR.md`) + the issue
title/body + a "read the repo to ground your judgment" instruction, and asks for a structured
**PROCEED / REFINE / DROP** verdict:

> You are the cross-vendor MANAGER reviewer for an autonomous coding team. yshifu (a Claude
> manager) has DRAFTED the GitHub issue below as a *proactive* proposal toward the team's
> current north star. Your job is to debate whether this issue is worth raising NOW — not
> to review code, and not to rubber-stamp it. You are VETO-ONLY: you never approve, label,
> edit the issue, or merge anything; you only give a verdict that yshifu weighs. The team
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
> - **GAP YSHIFU MISSED:** a risk, dependency, simpler path, conflict, or "already covered";
>   or "none".

The exact wording lives in [`scripts/manager-review.sh`](../scripts/manager-review.sh) —
treat the script as the source of truth.

## Invariants (non-negotiable)

- **Cross-vendor.** Manager = Claude (yshifu), manager-reviewer = Codex. The reviewer's
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
- **Consensus-only + default-drop.** Proceed only when yshifu and Codex agree; drop on no
  consensus by the round cap; log the drops yshifu thought were north-star-relevant.

## Bootstrap caveat

The issue that *built* `manager-review.sh` couldn't use it (the script didn't exist yet).
That debate was run manually via `codex exec`; the finished script is dogfooded on the next
proactive issue.

## Future / alternatives (not wired)

As with the code reviewer, an **autonomous** Codex GitHub integration (Codex posting the
manager-review on issue events itself, with no yshifu session) is a possible later upgrade —
same invariants (cross-vendor, read-only, comments-only, veto-only). Not built; wiring it
is out of scope here.

> Note: Codex on your ChatGPT plan is fine for personal repos (first-party feature =
> ordinary use). Apply terms diligence before pointing it at any work/shared repo.
