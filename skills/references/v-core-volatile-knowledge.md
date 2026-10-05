# Volatile Knowledge Contract

_Last reviewed: 2026-07-06 (added the two-date convention; prev 2026-07-05 ecosystem review sweep)._

Use this reference when a skill depends on facts that can change outside the repository.

## What Counts As Volatile

Volatile knowledge includes:
- thresholds and benchmarks
- product or platform deprecations
- search, browser, AI, or policy changes
- external bot names, supported features, or vendor restrictions
- current-year guidance that may drift

## Rules

- Keep workflow logic in the `SKILL.md` body.
- Move volatile facts into a dated reference file.
- Name dated references clearly, for example `seo-volatile-knowledge-2026.md`.
- State the freshness window or update date in the reference.
- When a skill uses volatile guidance, the skill must point to the dated reference instead of restating the facts inline.
- **Freshness window + staleness alarm (required).** Each dated reference carries a `Last reviewed: <date>` line and a re-review window (default 45 days). A skill consuming the reference SHOULD compute the age of `Last reviewed` and, when older than the window, surface a NON-BLOCKING warning in its output (e.g. `⚠ <ref> last reviewed <date> (>45d) — verify current facts before high-confidence claims`) instead of silently trusting stale data. Staleness is a warning, never a hard block.
- **Two-date convention.** A reference may distinguish an editorial `Last reviewed` date from a `facts last deep-verified` date (e.g. `seo-volatile-knowledge-2026.md`). When both exist, compute staleness from the **facts last deep-verified** date — an editorial/formatting pass must NOT reset the decay clock.

## Writing Style

- Distinguish durable operating rules from time-sensitive facts.
- Prefer short summaries in the skill body and detailed facts in the dated reference.
- When a recommendation depends on current external behavior, say so explicitly in the reference.

## Anti-Patterns

Avoid:
- embedding long current-year market claims in the main SKILL body
- mixing durable workflow instructions with dated benchmark values
- scattering the same external-policy facts across multiple skills
