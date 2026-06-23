# <Target repo> — conventions for the coding agents

Drop this file in the root of each target repo. Both the coder and the reviewer
read it, so it's how you specialize the *one* coder per repo (instead of having
separate FE/BE agents).

## Stack & commands
- Language / framework: <fill in>
- Install: `<cmd>`
- Test: `<cmd>`  ← where applicable (or the repo's CI checks); must pass before any PR is opened
- Lint / typecheck: `<cmd>`
- Build / run: `<cmd>`

## PR rules (enforced by coder + reviewer)
- **One concern per PR.** A PR does exactly one thing.
- Soft size budget **~300–400 net lines**. Past that, split into smaller issues
  rather than one big PR. (Tripwire, not a hard reject — a large mechanical rename
  is fine.)
- Every PR links its issue (`Closes #<n>`) and adds/updates tests where the repo
  has them; CI must stay green.
- Conventional commit messages: `<convention, e.g. feat:/fix:/chore:>`

## Conventions
- Code style: <fill in / point at the linter config>
- Directory layout: <fill in>
- Patterns to follow / anti-patterns to avoid: <fill in>
- Anything the agents should NOT touch: <fill in>
