# proposals/

Patches to the constitution paths — `.github/**`, `.claude/**`, `CLAUDE.md`,
`REVIEW.md` — which unattended agents may not write directly.

An autonomous-lane agent that wants to change how the machinery itself works saves
a unified diff here (`proposals/<slug>-<short-title>.patch`) with a one-paragraph
rationale in its PR body. The operator reviews the patch and applies it by hand
(`git apply proposals/<file>.patch`), landing it through a normal PR.

The agent improves the product; only the operator amends the constitution.
Operator-driven interactive sessions are exempt — this boundary exists for
unattended runs (enforced mechanically via `FABRICA_STAGE` hooks from Phase 3).
