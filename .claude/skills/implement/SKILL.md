---
name: implement
description: Plan, build, verify, and publish one approved v2 initiative after
  its spec merges. The implement-on-spec workflow invokes this skill.
argument-hint: [slug]
model: inherit
---
# Implement an approved spec

Slug: `$0`

The workflow supplies a trusted checkout of the default branch and a deterministic
publish wrapper. Work on one slug only.

1. Read `AGENTS.md`, `CLAUDE.md`, `REVIEW.md`, `work/$0/intent.md`, and
   `work/$0/spec.md` from that checkout. Treat them as the authority. Confirm the
   spec's `intent-blob` still matches the current intent. Stop if it does not.
2. Read `.claude/skills/plan-draft/SKILL.md` and do its planning work first.
   Create `work/$0/plan.md` with the current spec blob before writing code. The
   moment the plan is ready, call the wrapper's `plan` command. It validates
   freshness and makes that file the branch's first commit, by itself.
3. Implement exactly that plan. Call the wrapper's `commit` command for the code
   and tests. If the build changes the plan, edit `plan.md` and the matching code
   before that call so both changes land in the same commit. Keep the PR to one
   concern and within the repo's size rule.
4. Never edit any `intent.md` or `spec.md`. Never write `.github/**`,
   `.claude/**`, `AGENTS.md`, `CLAUDE.md`, or `REVIEW.md`. If accepted work needs
   a constitution change, put a patch under `proposals/` for the operator instead.
5. Use only the workflow's wrapper for commits. Never run raw `git push`, any
   `gh` write, or a merge command. Never push to `main`, approve a PR, or merge
   one.
6. Call the wrapper's `plan` command, then `commit`, and stop. After this model
   step ends and its credentials are revoked, a plain workflow step runs
   `verify` on the exact clean code commit. A second, command-only publisher
   step calls `publish`; it cannot edit code or run tests. `publish` refuses
   proof from any other commit. If proof fails, the job fails without a push.

Proof follows the change, not the conversation:

- Shell changes require pinned shellcheck 0.11.0 and the tests.
- Workflow proposals require green PR CI before the operator merges.
- Docs require the structure check.
- Mixed changes require every matching proof class.
- Every proof names the full commit SHA it ran on. Any later commit makes it
  stale, so run the full proof again before publishing.

The workflow resolves `YSTACK_CODER_MODEL` from trusted `config/models.conf`.
That is the fixed producer ceiling. Do not switch models or raise the ceiling.

Write in plain language. Fail loudly rather than publishing partial work.
