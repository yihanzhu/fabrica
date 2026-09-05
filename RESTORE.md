# RESTORE.md — rebuild the whole team from this repo

This is the disaster-recovery runbook for ystack. If the live setup is lost — the
`/yshifu` command gone, the Codex CLI disconnected, labels or CI missing — follow this
top to bottom to turn **this repo** back into a running coding team.

This repo is the source of truth for *how the team works*. Everything below is
reconstructed **from files already in this repo** — this runbook only points at them and
gives the order. It does not duplicate their contents; open each referenced file and use
it as written.

> **Parameterize, don't hardcode.** Wherever you see `<owner>/<repo>` (or
> `<owner>`), substitute your own target repo(s). Per the reusability rule in
> [`AGENTS.md`](AGENTS.md), keep personal usernames and repo names out of the shipped
> files — supply them here at restore time, not in the templates.

---

## 0. Prerequisites

Accounts and access you need before starting:

- **A Claude plan that runs Claude Code** — the whole team runs in-session: yshifu is an
  ordinary Claude Code chat, and it spawns the coder (and fix-mode coder) as subagents in
  that same session (metered ordinary use, **no API key**).
- **Codex (OpenAI) CLI** — this is the cross-vendor reviewer, driven by
  `scripts/codex-review.sh`. A ChatGPT plan that includes Codex review is enough for
  personal repos; the Codex CLI must be installed and signed in.
- **GitHub access** to each target repo, plus the **`gh` CLI authenticated** locally
  (`gh auth status` should show you logged in) for labels and the loop's `gh` calls.
- **`jq` on `PATH`** — the review/debate gates validate Codex's `--json` event stream with it,
  and the merge helper parses GitHub check JSON with it.
- **The personal config you must supply** (keep it parameterized — see the note above):
  - the **target repo name(s)**, e.g. `<owner>/<repo>` — the repo(s) the team works in.
    (ystack is its own target repo; add others as you adopt the team elsewhere.)

Read [`README.md`](README.md) once for the mental model (the team, the loop, the
design "why") and [`AGENTS.md`](AGENTS.md) for the conventions and safety rails before
you rebuild.

### Restore the inactive profile resolver source

The resolver is source-only and remains inactive after restore. Confirm the eight
resolver files listed under “Inactive portable profile resolver v1” in
[`ci/required-files.txt`](ci/required-files.txt), then run:

```sh
bash scripts/test/portable-profile-resolution.test.sh
```

That test obtains the pinned jq 1.6 release with its recorded digest, compiles the
single private no-follow helper and the test-owned direct-`execve` launcher with the
host compiler, creates hermetic SHA-1/SHA-256 repositories, and validates the output
with the restored `scripts/core-contract.sh`. No compiled helper is installed or
restored. A future activation must separately qualify and bind a production trusted
parent; restoring these files does not select a live profile.

---

## 1. Recreate yshifu (the manager)

yshifu is the **only human-facing surface** — you talk only to yshifu; the workers have no
human channel.

1. Create a Claude Code project (a chat you keep).
2. Paste the full contents of [`manager/CLAUDE.md`](manager/CLAUDE.md) in as the project's
   persistent instructions / persona.
3. Recreate the `/yshifu` slash command by running
   [`scripts/install.sh`](scripts/install.sh) (no arguments). It generates
   `~/.claude/commands/yshifu.md` from [`templates/yshifu-command.md`](templates/yshifu-command.md),
   substituting this clone's own path for the placeholder — so the command never hardcodes
   a repo location. Idempotent: re-running is safe, and an existing differing `yshifu.md` is
   backed up to `yshifu.md.bak` before overwriting. A retired legacy command file is not
   recreated or deleted by the installer. If legacy `~/.claude/commands/faber.md` remains,
   the installer warns and leaves it byte-for-byte untouched. Retire it in this order before
   running doctor/full smoke:
   1. Verify the new command exists and names this clone:
      `test -f ~/.claude/commands/yshifu.md && grep -qF "$(pwd -P)/" ~/.claude/commands/yshifu.md`.
   2. Inspect whether the legacy file is the generated bridge or contains custom work. Never
      discard custom content.
   3. Move it outside the active command-discovery tree into a unique timestamped
      directory; never overwrite the installer's fixed `.bak` or an earlier retirement:

      ```sh
      set -eu
      legacy_cmd="$HOME/.claude/commands/faber.md" # legacy operator cleanup
      if [ ! -e "$legacy_cmd" ] && [ ! -L "$legacy_cmd" ]; then
        echo "retired command is already absent: $legacy_cmd" >&2
        exit 1
      fi
      claude_root="$(cd "$HOME/.claude" && pwd -P)"
      retired_root="$HOME/.claude/retired-commands"
      if [ -L "$retired_root" ] || { [ -e "$retired_root" ] && [ ! -d "$retired_root" ]; }; then
        echo "refusing unsafe retired-command root: $retired_root" >&2
        exit 1
      fi
      if [ ! -e "$retired_root" ]; then
        mkdir -m 700 "$retired_root"
      fi
      if [ ! -O "$retired_root" ] || [ -n "$(find "$retired_root" -prune \( -perm -020 -o -perm -002 \) -print -quit)" ]; then
        echo "retired-command root must be owned by this user and not group/other writable" >&2
        exit 1
      fi
      retired_real="$(cd "$retired_root" && pwd -P)"
      case "$retired_real" in
        "$claude_root"/*) ;;
        *) echo "retired-command root escaped $claude_root" >&2; exit 1 ;;
      esac
      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      retired_dir="$(mktemp -d "$retired_real/legacy-faber-$stamp.XXXXXX")" # legacy backup
      retired="$retired_dir/command.md"
      if [ -e "$retired" ] || [ -L "$retired" ]; then
        echo "refusing to overwrite retirement destination: $retired" >&2
        exit 1
      fi
      if ! mv "$legacy_cmd" "$retired"; then
        echo "failed to move retired command; original path was not intentionally removed" >&2
        exit 1
      fi
      printf 'retired=%s\n' "$retired"
      ```
   4. Run `scripts/doctor.sh`, restart Claude Code, and run the full `/yshifu` smoke below.
   5. Roll back only if the command path is still absent:
      Set `retired` to the exact path printed above, then run
      `legacy_cmd="$HOME/.claude/commands/faber.md"; test ! -e "$legacy_cmd" && test ! -L "$legacy_cmd" && mv "$retired" "$legacy_cmd"`.
      If either path conflicts, stop and inspect it; never overwrite. The move preserves the
      original bytes and mode. # legacy rollback
   Do **not** recreate this command by hand.
4. Give that session GitHub access (`gh` CLI or the GitHub connector) so yshifu can read
   state and open issues.

yshifu **never writes code or opens PRs** and **never approves on your behalf** — it opens
issues and orchestrates the loop. yshifu **never merges either**: when a PR is CI-green and
Codex passed that exact head/base, it labels the PR `merge-ready` and hands it to you, naming the risk
when there is one (safety-rail changes, north-star / goal drift, high-risk back-look). The
intake gate is **your approval of the concrete intake draft** for user-directed work;
proactive work uses yshifu⇄Codex consensus under your approved north star. yshifu records
the accepted exact issue title/body digests on the issue. Neither path directly earns `ready`.
New normal work then needs operator-merged G1 intent and G2 spec-with-risk, and the
applicable plan gate. Only then does yshifu apply `ready`. Before spawn it records a
unique claim, adds/verifies `claimed`, consumes the existing `ready` label, and verifies
the exact state. Under the hard one-manager-session invariant, a crash leaves `claimed`
visible and blocks duplicate pickup; it is not a cross-manager mutex. Parallel managers
pause with `needs-human`. This
remains an in-session action, not a separate automated trigger.

---

## 2. Recreate the coder + brief instruction sources

Nothing to "wire" here — the coder and brief are **not standalone services**. They are
instruction files in [`routines/`](routines/) that yshifu reads and passes (with the
specific task context) to the subagents it spawns in-session. To restore them, just make
sure the files are present on `main`:

| File | Role |
|------|------|
| [`routines/coder.md`](routines/coder.md) | Coder baseline instructions yshifu passes to a spawned coder subagent |
| [`routines/coder-revision.md`](routines/coder-revision.md) | Coder fix-mode instructions for a spawned revision subagent |
| [`routines/brief.md`](routines/brief.md) | Brief instructions yshifu can run for resurfacing (read-only; not auto-scheduled) |

Notes:
- The `/yshifu` command (step 1) already points yshifu at these files, so once it is
  installed yshifu will use them when it spawns a coder; there is no separate trigger,
  repository, or connector setting to configure.
- The coder instructions self-guard: build requires intake `claimed` with
  `ready|needs-human` absent; fix requires PR `claimed`, PR `needs-human` absent, and
  parent-intake `ready|claimed|needs-human` absent. Both match a unique claim ID and exact tuple
  before doing anything.
  For normal work, `ready` means the durable intake record, G1/G2, and applicable plan
  gate all cleared; named bootstraps use their dedicated approved plan. Approval or
  consensus alone is not enough.

---

## 3. Recreate the Codex reviewer

The reviewer runs on **Codex (OpenAI)**, not on Claude — that cross-vendor split is
deliberate (decorrelated blind spots). It uses Codex's **built-in** review
(`codex exec review`) driven by the in-session harness — see
[`reviewer/codex-review.md`](reviewer/codex-review.md) for the mechanism and the loop.

Make sure the **Codex CLI is installed and signed in**, then drive review with
[`scripts/codex-review.sh`](scripts/codex-review.sh). The script lives only in *this*
control-plane repo, so from within the target repo's clone yshifu invokes it by **absolute
path** — `"$HOME/git/ystack/scripts/codex-review.sh" <PR#>` (substitute your ystack
clone; or put `<ystack>/scripts` on `PATH` and call `codex-review.sh <PR#>`). Do **not**
copy the script into each target repo. `gh` infers `<owner>/<repo>` from the cwd; the
script runs `codex exec review` (read-only forced via `-c sandbox_mode="read-only"`) and
posts Codex's verdict to the PR **verbatim**. No GitHub-side wiring needed; the script
itself only posts a comment.

**Comments only / read-only is non-negotiable**: Codex (and the script) get no write
access beyond posting review comments. It never pushes, never approves-to-merge, never
merges, and is never the author of the code it reviews (see Safety rails below).

> **Future, not wired.** Codex also offers a GitHub integration that could review PRs
> automatically on open/update with no yshifu session — an autonomous upgrade. It is **not
> set up here**; the in-session harness above is the only review path today.

---

## 4. Recreate labels, branch protection, and CI (per target repo)

Do this **once per target repo**. The full checklist already exists — **reuse it**, do
not re-derive it: [`templates/repo-setup.md`](templates/repo-setup.md).

That checklist covers:
- **Labels** — the `debating` / `ready` / `claimed` / `round-0..round-3` / `needs-human` / `merge-ready`
  set the loop uses as its state (each coder spawn is stateless, so the round lives in the
  label; `debating` marks a proactive issue under manager-debate, not yet approved).
  The `gh label create` loop is in that file. `setup-target-repo.sh` is the **canonical
  source of truth** for these labels: a normal run force-edits each live label to the
  script's definitions, so **re-running reconciles any drift**. To verify labels after a
  restore **without mutating anything**, run the read-only dry mode —
  `scripts/setup-target-repo.sh --check <owner>/<repo>` — which reports per label
  `matches` / `differs` / `missing` and exits non-zero if anything is missing or differs.
  After activating this policy, audit old `ready` issues too. Remove it from every
  already-open implementation PR before `legacy-open` fix mode. A PR-absent issue keeps
  it only with a complete new build tuple (and exact approved plan record for a named
  bootstrap). The reconciled description does not turn an old label into evidence.
- **Branch protection on `main`** — require CI status checks to pass; keep GitHub's
  **native auto-merge button off** (merging is the operator's, gated on green CI and a
  `merge-ready` label — never a server-side trigger, and never an agent). Caveat: that section of `repo-setup.md` is a **UI checkbox checklist with no
  command** (unlike the labels loop), and **branch protection isn't available on free
  private repos** — it needs a paid plan or a public repo. If you can't enable it, **CI is
  still the hard gate** (see Safety rails); you just lose the server-side enforcement.
- **CI** — comes from [`.github/workflows/ci.yml`](.github/workflows/ci.yml) (structure
  check + shellcheck). It is the **hard merge gate**; restore it by having this repo's
  `.github/workflows/` present on `main`. Don't copy its steps here — link to it.
  - The structure check enforces the full backup against
    [`ci/required-files.txt`](ci/required-files.txt) — the **source of truth** for every
    restore-critical file. It fails the build if any listed path is missing (and if a
    listed `scripts/*.sh` isn't executable), so a PR can't silently drop `install.sh`,
    `RESTORE.md`, or any other load-bearing file and stay green. When you add a file the
    team needs to be reconstructable, add it to that manifest.
  - **Out of scope: `claude.yml`.** `.github/workflows/` also contains
    [`claude.yml`](.github/workflows/claude.yml) — the optional `@claude`-mention helper
    (`anthropics/claude-code-action`, pinned to the full commit SHA for the v1 loop). It is **not part
    of the team loop** and is not
    required to restore the coding team, so it is out of scope for this runbook. If you do
    want it back, note that it needs a `CLAUDE_CODE_OAUTH_TOKEN` repo secret, which lives
    only in GitHub repo settings (not in any file here) and must be re-created by hand.
- **North star (per target)** — the team steers by the target's **committed**
  `.ystack/north-star.md` (resolved via `scripts/lib/north-star.sh`; the manager-debate gate
  reads its committed content). Restore it in the target repo: copy
  [`templates/.ystack/north-star.md`](templates/.ystack/north-star.md) to
  `.ystack/north-star.md`, replace the placeholder with your direction, **remove the
  `<!-- ystack-shipped-default -->` marker**, and **commit** it — a missing / still-marked /
  no-`status: active` star FAILs the proactive gate (`manager-review.sh`) and WARNs in
  `doctor.sh`. Setup does **not** seed it — `setup-target-repo.sh` only creates the loop labels.
  (When restoring **ystack itself**, its north star is the root
  [`NORTH_STAR.md`](NORTH_STAR.md) — ystack is its own target — so there's no separate
  `.ystack/north-star.md` to restore.)
- **Conventions** — drop [`templates/target-CLAUDE.md`](templates/target-CLAUDE.md) into
  the target repo's root, filled in for that repo.
- **The in-session setup** — install `/yshifu` (step 1) and connect the Codex CLI for
  `scripts/codex-review.sh` (step 3); there are no per-repo routine triggers to wire.

If you are restoring **ystack itself**, the labels and CI live in this repo already;
recreate any labels that were lost with the loop in `templates/repo-setup.md` using
`<owner>/<repo>` = your clone/copy of this repo (restoring ystack is the same repo, not
a fork).

---

## 4a. Restore the portable contract validator

The stable manual command is [`scripts/core-contract.sh`](scripts/core-contract.sh).
Its selected root, ingress boundary, five private modules, fixtures, ledgers, and tests
are all listed in [`ci/required-files.txt`](ci/required-files.txt). Restore those files
from the same commit; do not mix generations or edit a published generation in place.

Install jq 1.6 on `PATH`, confirm `jq --version` prints `jq-1.6`, then run:

```sh
bash scripts/test/portable-core-assembly.test.sh
```

The proof checks the fixed package, public error boundary, and the complete 34-row and
279-row migration ledgers. It does not install or activate a profile, contact a target,
or grant authority. The existing `/yshifu` restore path remains separate.

The v1 generation registry is ordered and append-only. Its last generation contains
the inactive accounted-validation interface and remains restorable after the v2
selection. Restore every file listed in the manifest from the same commit, then run
its focused proof:

```sh
bash scripts/test/portable-core-accounted-validation.test.sh
```

That proof checks caller-owned mode-0700 scratch, exact boundary admission, the fixed
descriptor-3 receipt, ordinary-call compatibility, cleanup, and byte-for-byte copies
of the unchanged exports. It performs no install, activation, networked validation,
or target use.

`core/v2/` contains append-only inactive generations, including the unchanged
fake-forge generation. The stable wrapper and inactive profile resolver select the
evidence-identity correction. Restore the registry and both complete generations from
one commit, then run:

```sh
bash scripts/test/portable-core-v2-fake-forge.test.sh
```

This proof validates the atomic wrapper selection and deterministic fake candidate
materialization in a caller-disposable repository. The package is not qualified for a real forge.
It grants no credential, network, publish, push, merge, or remote branch-write
capability. The switch does not install the resolver or select a live profile.

Restore the complete selected v2 evidence-identity generation, its dedicated ledger,
and its focused test from the manifest, then run:

```sh
bash scripts/test/portable-core-v2-evidence-identity.test.sh
```

This proof requires passed evidence to retain the exact selected performer,
binding, environment, capability, and metadata projection. It also proves that
all-non-passing incident mismatches remain preservable. Its selection is bound to
the reviewed generation merge and publisher receipt and grants no authority,
qualification, credential, network, activation, or external effect.

Restore every path in the manifest's inactive fake adapter matrix block, then run:

```sh
bash scripts/test/portable-adapter-contracts.test.sh
```

The proof resolves four fake-only profiles, validates both core stage records in
each cell, and checks the accepted 2×2 matrix plus closed negative protocol cases.
It uses no real adapter or credential and makes no network/host isolation,
qualification, activation, or external-target-smoke claim.

Restore the three paths in the manifest's inactive control policy-set block, then
run:

```sh
bash scripts/test/control-policy-set.test.sh
```

The proof validates only the canonical six-section identity bundle. It does not
evaluate a policy, grant authority, activate a profile, or enforce sandbox,
credential, risk, kill-switch, or evidence behavior.

Restore the two paths in the manifest's inactive Control foundation roll-up block,
then run:

```sh
bash scripts/test/control-foundation-rollup.test.sh
```

This recomputes the six policy and six decision file identities, their common core
generation and package closure, and the inactive fail-closed boundary. It adds no
aggregator runtime and makes no enforcement, qualification, authority, activation,
or external-effect claim.

Restore the five paths in the manifest's inactive duty-separation block, then run:

```sh
bash scripts/test/control-duty-separation.test.sh
```

This checks the exact policy and decision links, mirrored policy-set validator,
full selected public-core package closure, evaluator identities, role and permission
ceilings, all three identity-separation dimensions, dormant publisher behavior, and
canonical observation results. It does not enforce effective sandbox or credential
permissions and grants no authority or external write.

Restore the five paths in the manifest's inactive risk-gates block, then run:

```sh
bash scripts/test/control-risk-gates.test.sh
```

This checks the exact policy, decision, evaluator, duty-separation, policy-set, and
public-core identity closure; tier downgrade and malformed-input handling; and
canonical `violated` or `inconclusive` observations. Decision input is an
unqualified immutable claim, so an accept claim cannot produce `satisfied` or grant
approval, authority, qualification, activation, permission, or an external effect.

Restore the five paths in the manifest's inactive kill-switch block, then run:

```sh
bash scripts/test/control-kill-switch.test.sh
```

This checks exact identity closure, all five stop scopes, cleared and missing
state, rollback, replay, ambiguity, duty failure, malformed input, deterministic
output, and bounded child-process cleanup. The evaluator is inactive and
observation only. It does not send a signal, cancel or run a candidate, grant
authority, use a credential, activate a profile, or perform an external write.

Restore the five paths in the manifest's inactive sandbox-policy block, then run:

```sh
bash scripts/test/control-sandbox-policy.test.sh
```

This checks exact identity closure, the complete allowlisted declaration, unknown
and violated inputs, duty failure, stale links, malformed input, deterministic
output, snapshotted jq execution, and postflight mutation detection. The result is
inactive and declaration-only. It does not enforce or qualify a real sandbox, run
a candidate or adapter, use a credential, activate a profile, or perform a network
or external-write action.

Restore the five paths in the manifest's inactive credential-policy block, then
run:

```sh
bash scripts/test/control-credential-policy.test.sh
```

This checks exact identity closure, the brokered single-stage model-inference
ceiling, protected-role and incompatible-permission handling, incomplete and
malformed claims, stale links, deterministic output, bounded child cleanup, and
postflight mutation detection. The evaluator is inactive and observation only. It
does not read credential material or credential-like environment values, qualify a
claim, grant authority, activate a profile, run a candidate or adapter, or perform
a network or external-write action.

Restore the five paths in the manifest's inactive evidence-integrity block, then
run:

```sh
bash scripts/test/control-evidence-integrity.test.sh
```

This checks exact policy-set and public-core closure, stage and qualification
identity binding, canonical evidence/prior sets, stale or aliased references, and
deterministic observation output. It also checks the explicit trusted-launcher
boundary, exact marked-payload identity, producer-final scratch identities,
accounted core receipt and cleanup, and nested Bash environment isolation. The
launcher is not self-attested. It does not read proof bytes, establish proof
truth, qualify a workflow, store evidence, grant authority, activate a profile,
run a candidate or adapter, or perform a network or external-write action.

Restore the five paths in the manifest's inactive canonical state scanner block
from the same commit. With the same pinned, architecture-bound jq 1.6 runtime used
by the portable core, run:

```sh
bash scripts/test/orchestrator-state-scanner.test.sh
```

This checks bounded canonical snapshots, exact repository and commit binding,
deterministic pending and stranded classifications, recovery reasons, private
runtime snapshots, and fail-closed input handling. The scanner remains inactive
and observation only. It does not deliver or retry events, reconcile or write
state, use a credential or network, activate a profile, or touch a target.

Restore the two paths in the manifest's inactive reconciliation planner block,
then run:

```sh
bash scripts/test/orchestrator-reconciliation-plan.test.sh
```

This checks deterministic at-least-once planning, failed-stage retry, stranded
attempt recovery without a new attempt, acknowledged-delivery suppression,
operator messages, and stable backpressure. It also rejects malformed, stale,
duplicate, unsorted, and oversized inputs. The jq filter remains inactive and
planning only. It does not dispatch, schedule, execute recovery, write state, use
a credential or network, activate a profile, publish, or touch a target.

Restore the two paths in the manifest's inactive GitHub forge normalizer payload
block, then run:

```sh
bash scripts/test/default-github-forge-adapter.test.sh
```

This checks exact caller bindings, deterministic state normalization, opaque
provider data, and fail-closed malformed or stale input. This stage intentionally
has no adapter manifest. A later assembly PR can bind the payload through a
durable main commit and add default-set wiring. The pure jq payload is offline and
unqualified. It does not call GitHub, use a credential, change a repository or
request, grant authority or qualification, or activate a profile.

Restore the two paths in the manifest's inactive Codex native reviewer
normalizer payload block, then run:

```sh
bash scripts/test/default-codex-native-reviewer-adapter.test.sh
```

This checks exact caller bindings, deterministic clean and finding states,
opaque provider severity, explicit hidden-execution unavailability, and
fail-closed malformed or stale input. This stage intentionally has no adapter
manifest. A later assembly PR can bind the payload through a durable main commit
and add default-set wiring. The pure jq payload is offline, read-only, and
unqualified. It does not invoke a model or CLI, use a credential or network,
post a review, grant authority or qualification, or activate a profile.

Restore the two paths in the manifest's inactive GitHub Actions CI normalizer
payload block, then run:

```sh
bash scripts/test/default-github-actions-ci-adapter.test.sh
```

This checks exact caller bindings, deterministic workflow and job-state
normalization, opaque provider data, and fail-closed malformed, contradictory,
incomplete, or stale input. This stage intentionally has no adapter manifest. A
later assembly PR can bind the payload through a durable main commit and add
default-set wiring. The pure jq payload is offline and unqualified. It does not
call GitHub, use a credential, rerun, cancel, or dispatch work, change a
repository, grant authority or qualification, or activate a profile.

Restore the four paths in the manifest's inactive local Git materializer block,
then run:

```sh
bash scripts/test/local-git-materializer-adapter.test.sh
```

This builds disposable SHA-1 and SHA-256 source repositories, validates a complete
portable-core v2 profile and stage request, and proves that a contract-bound patch
becomes a deterministic bare child commit and path-free receipt. The negative
matrix rejects moved identities, unsafe directories and paths, hooks, filters,
remotes, worktrees, alternates, shallow or partial repositories, replace state,
binary patches, symlinks, submodules, host Git templates, and reachable source
history above the fixed 65,536-object or 256 MiB import budget. Copy/rename patch
metadata and source trees containing empty subtrees also fail closed. It proves empty-patch
`no-change` and rejects tree scans above 65,536 entries, 64 path components, or a
16 MiB encoded listing. It also checks that the source stays unchanged and scratch
is removed. Input and config snapshots are stream-capped before parsing. The
complete source filesystem scan is capped at 65,536 entries and 8 MiB. Tree scans
are capped at 1,024 tree objects, with each object size-checked before non-recursive
expansion. A shared-large-blob
fixture proves the 256 MiB pre-apply candidate
budget blocks path fan-out before Git writes changed blobs.
The test compiles the private object-closure helper with strict warnings. It proves
that an oversized historical tree and an oversized packed-refs file fail before
recursive traversal or parsing. The runtime takes the pinned jq 1.6 executable as
an explicit dependency and ignores the caller's executable search path.

This payload has no adapter manifest. A later assembly PR may bind the directory
tree through the payload's durable main commit. It is an inactive, local-only
materializer, not a GitHub or GitLab operation. Restoring it does not qualify an
adapter, select or activate a profile, read a credential, contact a provider or
real target during construction, or permit push, publish, merge, or another
external write.

Restore the two paths in the manifest's inactive Claude Code producer normalizer
payload block, then run:

```sh
bash scripts/test/default-claude-code-producer-adapter.test.sh
```

This checks the caller-supplied core request, resolved profile, manifest, target,
package, config, prompt, skills, tools, model, effort, and execution boundary. The
test manifest is synthetic fixture data; no adapter manifest ships in this unit.
A caller constructs the trust context only after canonical SHA-256 verification
of the snapshot pair. The proof rejects moved untrusted content, changed attempt
identity, and non-diff output for a changed git-patch request.
A later assembly PR can bind the durable main payload into the default profile.
The pure jq payload is inactive, offline, and unqualified. It does not call Claude
Code, invoke a model, use a credential or network, write a target, publish, or
activate a profile.

Restore the three paths in the manifest's inactive local Git materializer protocol
block, then run:

```sh
bash scripts/test/local-git-materializer-protocol.test.sh
```

This builds only synthetic JSON fixtures. It validates the exact portable-core v2
profile, request, manifest, contract, payload, receipt, and result relations. The
negative matrix rejects malformed, stale, duplicate, relabelled, unsafe-path,
expanded-mode, and weakened-limit inputs, and repeat checks require canonical
output. It also requires caller-verified content-and-digest payload pairs, binds the
source repository, commit, and tree to the request, enforces patch and changed-path
limits, and revalidates the envelope before every projection. A stage result also
requires a caller-verified receipt pair whose request, attempt, source, limits, and
changed/no-change outcome all match before the receipt digest can back passing
evidence.

There is no materialization executable in this stage. Restoring it cannot read or
write a Git repository, create a candidate, run provider tooling, use a credential
or network, grant authority or qualification, or perform an external effect. A
later runtime PR may consume the protocol and test fixture; only a still-later
assembly may add a manifest after the complete package has a durable main commit.

Restore the two paths in the manifest's inactive dormant publisher normalizer
payload block, then run:

```sh
bash scripts/test/default-dormant-publisher-adapter.test.sh
```

This checks exact attempt, idempotency, repository, change-request, candidate,
path, evidence, decision, terminal-time, observation-time, and boundary bindings.
The caller supplies a canonical, SHA-256-verified claim pair, and changed content
is rejected. Permit, deny, and inconclusive claims all remain inert; malformed
input is rejected and moved input becomes stale. This stage has no adapter manifest.
A later assembly PR can bind its durable main payload with empty capability,
permission, and tool sets. It is separate from the temporary construction
publisher gate and performs no credential, network, merge, external write,
authority, qualification, or profile activation.

Restore the two paths in the manifest's inactive deterministic verifier normalizer
payload block, then run:

```sh
bash scripts/test/default-deterministic-verifier-adapter.test.sh
```

This validates exact core-v2 verifier request/profile/result relations, the
deterministic role and permission ceiling, candidate and verification-plan binding,
exact caller-verified snapshot and result pairs, attempt identity, timestamp and
evidence precedence, stale inputs, and the boundary that keeps CI observations out
of verifier evidence. This stage intentionally has no adapter manifest. The pure jq
payload is offline and unqualified. It does not execute a candidate or tool, read
proof bytes, enforce a sandbox, use a credential or network, write evidence, grant
authority or qualification, or activate a profile.

Restore the seven paths in the manifest's inactive eval and trace framework block
from the same commit. With the same pinned, architecture-bound jq 1.6 runtime used
by the portable core, run:

```sh
bash scripts/test/evals-framework.test.sh
```

This checks the canonical catalog (nine roadmap families, two seeded), the exact
program, catalog, and driver digest pins, a full deterministic pass of the seeded
core replays through the real portable core, byte-identical repeat runs, honest
grading (a wrong expectation fails; a model-only family stays inconclusive), and
fail-closed handling of malformed, moved, or edited inputs. The framework remains
inactive and observation only. It does not run a candidate or adapter, invoke a
model, use a credential or network, grant qualification, or activate a profile.

---

## 5. Smoke test — prove the rebuilt team is alive

**Pre-flight first.** Before running the full live loop, run the read-only self-check
from this clone to catch the cheap failures fast — a missing credential, an
uninstalled `/yshifu`, a dropped restore-critical file, or absent loop labels:

```sh
scripts/doctor.sh                 # checks (a) /yshifu points here (b) gh auth (c) claude on PATH (d) codex (e) required files
scripts/doctor.sh <owner>/<repo>  # also verifies that target repo's loop labels (delegates to setup-target-repo.sh --check)
```

It prints a pass/fail line per check and exits non-zero if anything fails; it never
mutates anything. Fix any `fail:` line before the smoke test below — otherwise the
loop will stall at exactly that gap. Then prove the team end to end:

Run **one trivial issue** through the full loop end to end, all from your yshifu session:

1. Ask **yshifu** for a throwaway change (e.g. a one-line doc tweak). Your ask is the
   *request*; yshifu drafts an intake issue.
2. **You** approve that concrete intake. Confirm yshifu records the exact title/body digests,
   then coordinate G1 intent and G2 spec-with-risk PRs through independent review and
   **your merge**. Confirm the plan gate passes: high risk uses a reviewed plan-only
   PR you merge; routine work uses a plan-first remote head accepted by a different reviewer.
   Only then confirm **yshifu** applies `ready`, takes a verified `claimed` pickup,
   clears `ready`, and **spawns a coder subagent**.
3. Confirm the implementation PR says `Closes #<n>` and carries `round-0`; the earlier
   artifact/plan PRs must have used non-closing `Tracks #<n>`.
4. Confirm the review path:
   - **yshifu runs** `scripts/codex-review.sh <PR#>` and **Codex** posts review comments
     to the PR (and nothing else — no approve, no merge).
   - **CI** runs on the PR and goes green.
5. If there's feedback, confirm **yshifu spawns a fix-mode coder** that pushes follow-up
   commits and bumps the `round-N` label, then re-runs `codex-review.sh`.
6. Confirm the merge path: for a clean PR (CI green + Codex passed at that head/base) yshifu
   applies **`merge-ready`** and hands it over — **you merge**. Nothing else has a merge
   path: `main` requires a pull request and an approving review, the reviewer is
   comments-only, and no agent has a bypass.

If every step above fired, the team is back. If one stage is silent: re-check `/yshifu` is
installed and points at this repo (step 1), the coder instruction files are present (step
2), and the Codex CLI is signed in so `codex-review.sh` runs (step 3).

> Optional: confirm the **brief** by asking yshifu to run it, and check you get one
> action-first message back.

---

## 6. Safety rails that must survive any rebuild

These are load-bearing — per the self-modification safety section of
[`AGENTS.md`](AGENTS.md), never weaken them without explicit human sign-off:

- **Reviewer stays read-only / comments-only.** Codex never pushes, approves-to-merge, or
  merges, and is never the author.
- **Merging is yours, always.** yshifu labels a reviewed-clean head/base `merge-ready` and hands
  the PR over; it never merges, and the label goes void when the reviewed head or base moves. The
  in-session auto-merge v1 allowed was retired when the branch ruleset landed. Carve-outs
  survive as handoff duties: safety-rail changes, ambiguous specs, anything escalated
  (`needs-human`/round-cap), north-star milestones / goal drift, and high-risk back-look
  (auth, migrations, shared repos) are named as such when handed to you. Codex never
  approves or merges either.
- **Rounds cap (~3) + `needs-human` escalation stay intact.** Because each coder spawn is
  stateless, this state lives in the **labels** (`round-0..3`, `needs-human`), not in agent
  memory — so the labels (step 4) are part of the safety system, not decoration.
- **CI is the hard gate.** Merges require green CI; restore CI before trusting the loop.
- **One of two intake paths starts one shared artifact/plan pipeline.** A
  **user-directed** issue starts after you approve the concrete intake draft. A
  **proactive** issue starts after you've approved the active north star and yshifu⇄Codex
  manager-debate reaches consensus — no per-issue ask. The exact accepted issue title/body digests
  is recorded. Then G1 intent, G2 spec-with-risk, and the applicable plan gate must pass.
  `ready` means that whole sequence cleared; named bootstraps use only their dedicated
  approved plan. `claimed` means a pickup is active or unresolved and, under the
  one-manager invariant, blocks another spawn. It is not a cross-manager mutex. yshifu
  never infers intake acceptance or self-accepts a plan.

---

## Troubleshooting / gotchas

Real lessons from setting this up:

- **`/yshifu` not found, or points at the wrong repo?** Re-run
  [`scripts/install.sh`](scripts/install.sh) (no arguments) from your ystack clone — it
  regenerates `~/.claude/commands/yshifu.md` with this clone's path. Do not hand-edit it.
- **Local `gh` auth is what the loop uses.** yshifu, the spawned coder, and
  `codex-review.sh` all run in your local Claude Code session and hit GitHub through your
  local `gh` auth. If GitHub calls fail, check `gh auth status` first.
- **Coder won't start on an issue?** `ready` is only the unclaimed cue. The manager must
  take a unique `claimed` pickup and clear `ready`; the coder then requires that claim,
  no `needs-human`, and an exact tuple. Under one manager, an unresolved claim blocks
  another spawn; parallel managers require `needs-human`. Approval
  or consensus alone is not runnable; confirm every applicable gate and claim transition.
- **No Codex review on the PR?** The review is not automatic — **yshifu must run**
  `scripts/codex-review.sh <PR#>` from the target repo's clone. Check the Codex CLI is
  installed and signed in (`codex` runs), and that the script is invoked by absolute path.
  Claude and Codex never talk directly — the PR is the only message bus.
