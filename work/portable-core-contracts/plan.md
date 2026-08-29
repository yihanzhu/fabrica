---
spec-blob: f5b218626dec8484518295e901e427e3ff8f3daf
drafted: 2026-08-28
---

# Plan: portable-core-contracts

Build the accepted contract as one inactive implementation PR on
`ystack/impl/portable-core-contracts`. The expected implementation is about
900–1,100 normally formatted lines. That is the spec's accepted review-size
exception, not permission to reduce tests or compress code.

The PR stays one concern and one canonical schema. Its commits and review passes are
split by responsibility so a reviewer can check the byte boundary, profile relations,
and stage truth separately. Nothing is installed, selected by a live profile, or
called by `/yshifu`.

## Files that change

- `work/portable-core-contracts/plan.md` — this plan, committed before code.
- `core/v1/contracts.jq` — the only product source for v1 shapes, registries, and
  relational validation. It dispatches the three validation modes and returns only
  allowlisted result codes.
- `scripts/core-contract.sh` — the only public shell front door. It snapshots bounded
  input bytes, enforces jq 1.6, checks canonical bytes, computes document SHA-256,
  sanitizes errors, and invokes `contracts.jq`. It is executable.
- `scripts/test/core-contract-fixtures.jq` — test-only readable builders for one valid
  five-document graph. It creates data but contains no validation predicates and is
  never loaded by product code.
- `scripts/test/core-contract.test.sh` — hermetic positive, raw-byte, shape, relation,
  and status tests. It invokes the real shell front door and contains at least 60
  table-driven mutations. It is executable.
- `.github/workflows/ci.yml` — download the official jq 1.6 Linux binary without
  `sudo`, verify SHA-256
  `af986793a515d500ab2d35f8d2aecd656e764504b789b66d7e1a0b727a124c44`,
  assert `jq-1.6`, and run the new test suite. Existing CI steps stay unchanged.
- `ci/required-files.txt` — add the jq source, front door, test, and fixture builder.
- `AGENTS.md` — replace “validators are still to come” with the new files and exact
  local test command. Keep the existing jq/shellcheck safety guidance.
- `README.md` — document the three commands and state that the validator is manual
  and inactive; it does not change the current profile.
- `RESTORE.md` — record the jq 1.6 runtime pin and how to verify the restored
  validator. Do not change the current `/yshifu` restore path.

`QUICKSTART.md`, manager prompts, routines, templates, and install scripts do not
change because the validator is not part of the live profile or target setup.

## Order of work

1. **Commit this plan first.** Recheck that main's spec hashes to the recorded
   `spec-blob` and its `intent-blob` still matches main's intent. Stop as `stale` on
   either mismatch.

2. **Land the raw-byte boundary and shared shapes as one review section.**

   - In `scripts/core-contract.sh`, use `set -euo pipefail`, `LC_ALL=C`, `umask 077`,
     and a trapped private temp directory.
   - Resolve `core/v1/contracts.jq` from the script's own repo root. Never use a
     caller path for schema or config.
   - Accept only the three exact command/argument forms in the spec. Wrong command or
     arity is `E_USAGE`; an unreadable input, wrong jq version, missing schema, or
     missing SHA tool is `E_RUNTIME`. Never echo the rejected path.
   - `validate-profile-set` accepts 1–8 manifest arguments. Reject zero or more than
     eight as `E_USAGE` before opening or snapshotting any input; the profile's eight
     binding maximum is also the CLI resource bound.
   - Snapshot at most 1,048,577 bytes from each input before parsing. Reject the extra
     byte as `E_LIMIT`; all later canonical and hash work reads the same snapshot.
   - Run the exact jq 1.6 single-root canonicalizer from the spec. Capture its exact
     stdout—one canonical root with jq's single terminating LF—and compare it
     byte-for-byte with the snapshot. Do not append a second LF. Suppress raw jq
     stderr. Parser failure is `E_PARSE`; byte mismatch is `E_CANONICAL`.
   - Hash the accepted snapshot including the LF. Prefer `sha256sum`; fall back to
     `shasum -a 256`; reject any other path instead of changing digest semantics.
   - Pass jq a driver value containing only the mode, parsed documents, and their
     computed digests. Product jq never receives local paths or raw stderr.
   - In `contracts.jq`, add deterministic error helpers, global null/integer/string-
     key/string-value/member/depth checks, exact-key helpers, sorted unique sets,
     tagged unions, primitives, shared refs, envelope dispatch, and the five document
     body shapes.
   - Jq exits normally with exactly one allowlisted `E_LIMIT`, `E_SHAPE`, `E_REF`, or
     `E_RELATION` token on stdout for a parsed-limit or semantic failure. The wrapper
     suppresses that stdout and emits the token on stderr. Raw byte size and parsed
     depth/member/string/integer limits both report `E_LIMIT` through their own single
     owner. A valid value produces no jq output. Any nonzero jq exit, extra output,
     or unknown token becomes `E_RUNTIME`.
   - After raw-byte gates, validation order is parsed limits → shape → ref → relation.
     Return the first class in that order so one mutation has one stable expected
     token and a later relation cannot mask an earlier malformed value.

3. **Add manifest/profile/resolved-profile relations as the second review section.**

   - Encode the one capability/permission/role registry once in `contracts.jq`.
   - Enforce offer → request separation, exact permission unions, full package/tool
     equality, config-contract presence, deterministic/model prompt and skill rules,
     source-object projections, document digests, and protected-role separation.
   - Keep Git existence, physical repository mapping, provenance truth,
     authentication, grants, qualification, and policy evaluation outside core.
   - Add focused fixture variants and mutation rows before moving to stage records.

4. **Add request/result/status/evidence relations as the third review section.**

   - Validate exact capability arguments, target/input/revision closure, three
     delivered instruction refs, requested permissions, evidence kinds, and risk
     claims.
   - Implement the six terminal-status presence matrix first, then outcome/evidence
     precedence, producer patch rules, actual-vs-requested incident facts, model/tool
     facts, time order, and stale selectors.
   - Failed, cancelled, and completed-inconclusive records preserve actual mismatch
     claims; completed conclusive records require exact requested equality.
   - Do not implement the raw instruction transport, execute a candidate, read Git,
     call a model, or evaluate an external policy. Current tests cover only the
     request-side delivery relations owned by this contract.

5. **Build independent fixtures and adversarial proof.**

   - `core-contract-fixtures.jq` builds manifest → profile → resolved profile → request
     → result in dependency order. The shell test independently canonicalizes and
     hashes each earlier document before inserting its ref into the next one.
   - The fixture builder may share literal sample values, but never product validators,
     registries, acceptance predicates, or expected verdict logic.
   - Raw-byte cases cover empty and multi-root input, BOM, invalid UTF-8, duplicate
     keys, alternate escapes/whitespace, missing/final-extra LF, oversize, excessive
     depth/members/string size, floats, negatives, and large integers.
     Byte-size and each parsed resource limit include exact-boundary and one-over
     cases; every one-over case must return `E_LIMIT`.
   - Semantic rows cover every document kind, unknown fields/enums, paths/root trees,
     canonical-JSON blobs, package/tool/config/source relations, protected/dormant
     roles, all three capability argument and permission sets, instruction closure,
     deterministic skills, verifier revision equality, every terminal status,
     output/patch/time rules, actual-fact incidents, evidence precedence/replay, and
     every stale selector.
   - Mutations that target a relation recompute affected document hashes so they reach
     that relation instead of failing earlier at canonical or ref validation.
   - For each command, assert exit status, empty success stdout, exact first error
     token, and absence of fixture bytes and local paths from stderr. Add a PATH stub
     proving a non-1.6 jq fails as `E_RUNTIME`. Exercise `sha256sum`, the `shasum`
     fallback, and the no-SHA-tool failure without changing expected digests.
   - Exercise 0, 1, 8, and 9 manifest arguments. Zero and nine return `E_USAGE`
     before any named input is read; use unreadable/sentinel paths to prove that the
     count gate precedes snapshot work.

6. **Wire restore and CI only after the complete local suite passes.**

   - Add all new restore-critical files to `ci/required-files.txt`.
   - In one CI step, download `jq-linux64` from the official jq 1.6 release, verify
     the pinned hash, set mode 0555, prepend its private directory for this test step,
     assert the version, and run `core-contract.test.sh`.
   - Keep the existing system jq behavior for unrelated CI steps; the new pin must
     not silently change current review/debate tooling.
   - Update AGENTS, README, and RESTORE in plain language. State that structural
     validity is not trust or authority and that no live adapter consumes these
     records yet.
   - Recount normal-format lines by file and record the result in the PR. A difference
     from the 800–1,100 estimate is explained, not used as a pass/fail shortcut.

7. **Final one-PR proof and review.** Run every command below on the final commit.
   Review the PR in four passes matching the commit sections: byte/schema boundary,
   profile relations, stage truth, and tests/docs/CI. Any new concern or scope goes
   back to the artifact gate; it is not added during implementation.

## Risks

- **Riskiest boundary — raw bytes before parsed JSON.** If the wrapper parses, hashes,
  and compares different reads, a file can change between checks or duplicate keys and
  alternate encodings can disappear. One bounded private snapshot is the root fix.
- **Jq version drift.** This host ships `jq-1.7.1-apple`; CI and product semantics are
  jq 1.6. The wrapper rejects every other version. For local parity on Apple Silicon,
  use the official `jq-osx-amd64` 1.6 asset through Rosetta with SHA-256
  `5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef`.
- **Error leakage.** Jq and shell tools may include file names or input fragments in
  diagnostics. Capture their output, emit only allowlisted codes, and test with a
  distinctive secret-like fixture/path that must never appear.
- **Fixture circularity.** A test that asks production code to build refs or decide an
  expected verdict can reproduce the same bug on both sides. Fixtures may use pinned
  jq only for canonical bytes and an external SHA command only for hashes; expectations
  stay in the test table.
- **Truth-table ordering.** Status, evidence, output, and mismatch rules overlap. Use
  explicit status dispatch and fixed failed > inconclusive > passed precedence rather
  than one broad boolean expression.
- **Resource exhaustion.** Enforce byte size before jq and root-inclusive depth,
  member, string, and integer limits inside jq. Include exact boundary and one-over
  tests.
- **Review-size exception.** The PR is expected to exceed the normal soft guide. It
  remains one concern, but each commit/review section must be independently readable.
  Long lines, copied schema, fewer tests, or a second parser are not acceptable ways
  to make it look smaller.
- **Constitution paths.** `.github/workflows/ci.yml` and `AGENTS.md` are changed only
  because this is an operator-driven session. An unattended implementation must put
  those patches under `proposals/` instead.
- **No partial activation.** New files may exist on the branch before final wiring,
  but no current script, manager prompt, target template, profile, or install path
  calls them. The implementation becomes a manual validator only when the complete PR
  is merged.
- **Rejected alternatives.** JSON Schema, another language, or a second generated
  schema would create two sources of meaning. Multiple implementation PRs violate the
  accepted intent/branch. Trusting system jq creates version drift. Minifying the jq
  file hides review risk instead of reducing it.

## Proof

Prepare the exact local jq 1.6 binary on this Apple Silicon host:

```sh
mkdir -p /private/tmp/ystack-jq-1.6
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/jqlang/jq/releases/download/jq-1.6/jq-osx-amd64 \
  -o /private/tmp/ystack-jq-1.6/jq
printf '%s  %s\n' \
  5c0a0a3ea600f302ee458b30317425dd9632d1ad8882259fcaf4e9b868b2b1ef \
  /private/tmp/ystack-jq-1.6/jq | shasum -a 256 -c -
chmod 0555 /private/tmp/ystack-jq-1.6/jq
export PATH="/private/tmp/ystack-jq-1.6:$PATH"
test "$(jq --version)" = jq-1.6
```

Run the implementation proof from the repo root:

```sh
bash scripts/test/core-contract.test.sh
shellcheck -x -S style $(find . -name '*.sh' -not -path './.git/*')
bash scripts/test/north-star-resolver.test.sh
bash scripts/test/north-star-gate.test.sh
bash scripts/test/models-conf-parser.test.sh
bash scripts/test/codex-degraded-gate.test.sh
bash scripts/test/v2-pending-stage.test.sh
bash scripts/test/v2-round-cap.test.sh
bash scripts/test/v2-quota-preflight.test.sh
bash scripts/test/v2-check-rename.test.sh
bash scripts/check-rename.sh
git diff --check
```

The contract test must report all positive cases and at least 60 mutations passed,
with zero failures. ShellCheck must be version 0.11.0 as already pinned by CI. The PR
must show green GitHub CI on the exact reviewed head. The final review confirms:

- only the planned files changed;
- `plan.md` still points to main's current spec blob;
- success stdout is empty and every failure begins with an allowed `E_*` token;
- test stderr never exposes input bytes or local paths;
- all three commands reject shape/ref/relation drift and perform no Git, network,
  adapter, candidate, model, policy, credential, or external-write operation;
- README/RESTORE/AGENTS and `ci/required-files.txt` match the shipped files;
- no live prompt, profile, template, installer, or manager behavior changed.
