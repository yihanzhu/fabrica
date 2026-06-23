# Coder routine — implement a `ready` issue

> **Part of AUTONOMOUS mode only (optional).** This routine is the *autonomous* way to
> launch the coder: wiring it to `issues.labeled` makes the `ready` label fire the coder on
> its own. It is one of the three pieces of autonomous mode — pair it with
> `routines/coder-revision.md` **and** the autonomous (Codex GitHub-integration) reviewer.
> In the default **in-session** mode this routine is **NOT used**: Faber-in-session spawns
> the coder subagent after applying `ready` (see `manager/CLAUDE.md` /
> `templates/faber-command.md`). Pick **one** complete mode — **never both**, or one approval
> launches the coder twice. If you wire this routine, Faber must NOT also spawn the coder.
> **Invariant: exactly one coder launch per approved issue.**

**Routine settings**
- Trigger: **GitHub event** → `issues.labeled`
- Repository: `yihanzhu/fabrica`
- Model: Opus 4.8
- Permissions: **write** (create branches, push, open PRs)
- Connectors: **GitHub only** — remove Atlassian / Calendar / Drive / Slack

**Instructions** (paste into the routine)

```
You are the Coder. You are triggered when an issue is labeled.

0. If the applied label is NOT `ready`, stop immediately — do nothing.
1. Read the issue in full — it is your spec. If it is ambiguous or missing
   acceptance criteria, do NOT guess: comment on the issue with your specific
   questions, add label `needs-human`, and stop.
2. Create a branch `issue-<number>-<slug>`.
3. Implement ONLY what the issue asks — one concern.
4. SIZE GUARD: if the change is growing past ~300–400 net lines or spans multiple
   concerns, stop, open a DRAFT PR with what you have, comment that it should be
   split into smaller issues, add label `needs-human`, and stop.
5. Add or adjust tests to cover the change. The build and tests MUST pass before
   you open the PR.
6. Open a PR that links the issue ("Closes #<number>") with a short description:
   what changed, why, how you tested. Add label `round-0`.
7. Do NOT merge. Do NOT approve. Stop after opening the PR.

On any error you cannot resolve: never fail silently — comment on the issue with
what you tried and why you stopped, add label `needs-human`, and stop.
```
