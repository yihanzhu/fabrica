# <Target repo> — conventions for the coding agents

Drop this file in the root of each target repo. Both the coder and the reviewer
read it, so it's how you specialize the *one* coder per repo (instead of having
separate FE/BE agents).

> Fill in the skeleton below with your repo's real values. A complete worked
> example follows at the bottom — read it for the level of concreteness expected,
> then **delete it** (it describes a fictional repo, not yours).

## Stack & commands
*Why this matters: these are the exact commands the coder runs to satisfy its
CI-green bar, and the reviewer reruns to confirm a PR is mergeable — vague or
wrong commands here mean the coder can't tell whether its work passes.*

- Language / framework: <fill in>
- Install: `<cmd>`
- Test: `<cmd>`  ← where applicable (or the repo's CI checks); must pass before any PR is opened
- Lint / typecheck: `<cmd>`
- Build / run: `<cmd>`

## PR rules (enforced by coder + reviewer)
*Why this matters: these are the gate the reviewer checks every PR against —
keep them in sync with your real workflow so the coder doesn't get bounced on
rules it never saw.*

- **One concern per PR.** A PR does exactly one thing.
- Soft size budget **~300–400 net lines**. Past that, split into smaller issues
  rather than one big PR. (Tripwire, not a hard reject — a large mechanical rename
  is fine.)
- Every PR links its issue (`Closes #<n>`) and adds/updates tests where the repo
  has them; CI must stay green.
- Conventional commit messages: `<convention, e.g. feat:/fix:/chore:>`

## Exceptional implementations and comments
*Why this matters: a narrow workaround can be necessary, but an unexplained or
copied workaround quietly becomes architecture.*

- This section governs exceptional implementation code, not separately accepted
  CI or project-bootstrap process gates. Prefer the root-cause fix. Use an
  exceptional implementation only for an external constraint, safety concern,
  migration boundary, or accepted scope decision when the normal fix is unsafe,
  unavailable, or outside scope. Every
  exception must be named before implementation in an accepted issue, spec, plan,
  or operator decision record. A link, code comment, or PR discussion records
  provenance; it is not approval. A newly discovered exception returns to that
  gate before code is added.
- Keep each exception behind one named private function, module, or adapter. Add a
  regression test that runs in CI and link the durable issue, spec, plan, or
  decision explaining the tradeoff. When the protected invariant can be expressed
  reliably as lint, type, or another deterministic check, run that check in CI.
- Temporary exceptions name an objective removal condition. Permanent exceptions
  name the external invariant and the change that requires re-evaluation.
- Do not expose the exceptional pattern as a reusable API or copy it elsewhere.
  When the same need repeats, make it a normal architecture path, lint/type rule,
  test helper, or tracked redesign.
- An exception never waives CI, independent review, authorization boundaries,
  target safety rules, or human merge.
- Comments explain only a non-obvious reason, invariant, external contract, or tool
  directive. Do not add code restatements, AI-generated essays, commented-out code,
  copied PR discussion, or `TODO`/`FIXME` without a durable tracking reference.
  Keep required license, tooling, security/concurrency, compatibility/protocol,
  public API, and short exception-boundary comments.
- This baseline is not a blanket no-comments rule. A stricter target policy,
  including zero optional comments, may be recorded here: `<optional stricter
  rule>`. It cannot weaken the exception floor. Required notices, directives,
  documentation, invariants, and provenance remain in source or accepted
  sidecar/metadata.

## Conventions
*Why this matters: this is what keeps the coder's output looking like the rest of
your codebase, and gives the reviewer concrete grounds to request changes instead
of guessing at house style.*

- Code style: <fill in / point at the linter config>
- Directory layout: <fill in>
- Patterns to follow / anti-patterns to avoid: <fill in>
- Anything the agents should NOT touch: <fill in>

---

<!--
=============================================================================
ILLUSTRATIVE EXAMPLE — DELETE THIS ENTIRE BLOCK (between the comment markers)
BEFORE SHIPPING. It describes a *fictional* Node/TypeScript repo to show the
level of concreteness expected above. Do not ship it verbatim — replace the
skeleton with your real values and remove this example.
=============================================================================
-->

### Example: a fictional Node/TypeScript API service (delete me)

#### Stack & commands
*Why this matters: these are the exact commands the coder runs to satisfy its
CI-green bar, and the reviewer reruns to confirm a PR is mergeable.*

- Language / framework: TypeScript on Node 20, Express + Prisma, Postgres
- Install: `npm ci`
- Test: `npm test` (Vitest; runs unit + integration — must pass before any PR is opened)
- Lint / typecheck: `npm run lint && npm run typecheck` (ESLint + `tsc --noEmit`)
- Build / run: `npm run build` then `npm start` (or `npm run dev` for watch mode)

#### PR rules (enforced by coder + reviewer)
*Why this matters: these are the gate the reviewer checks every PR against.*

- **One concern per PR.** A PR does exactly one thing.
- Soft size budget **~300–400 net lines**.
- Every PR links its issue (`Closes #<n>`) and adds/updates Vitest specs next to
  the code it changes; CI must stay green.
- Conventional commit messages: `feat:` / `fix:` / `chore:` / `docs:` / `test:`.

#### Conventions
*Why this matters: this keeps the coder's output looking like the rest of the
codebase and gives the reviewer concrete grounds to request changes.*

- Code style: Prettier + ESLint (config in `.eslintrc.cjs`); no manual formatting —
  run `npm run format`.
- Directory layout: routes in `src/routes/`, business logic in `src/services/`,
  DB access only via Prisma in `src/db/`; tests as `*.test.ts` beside the source.
- Patterns to follow:
  - All HTTP handlers are thin — validate input, call a service, return; no DB
    queries in route files.
  - Use the shared `AppError` type for expected failures; let the error middleware
    format the response.
  - Follow the exceptional-implementation rule above: isolate any accepted
    compatibility boundary, test it, and link its durable decision.
- Anti-patterns to avoid:
  - No raw SQL strings — go through Prisma so migrations stay the source of truth.
  - No `any`; if a type is hard, add a narrow interface rather than escaping the
    type system.
- Do NOT touch:
  - `prisma/migrations/**` — migrations are generated and applied via
    `npx prisma migrate`; hand-editing them corrupts schema history.
  - `src/generated/**` — committed Prisma client output; regenerate it, never edit.

<!--
=============================================================================
END ILLUSTRATIVE EXAMPLE — DELETE EVERYTHING FROM THE MARKER ABOVE TO HERE.
=============================================================================
-->
