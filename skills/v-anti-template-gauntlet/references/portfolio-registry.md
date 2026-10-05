# Portfolio Registry — sibling-product discovery for the portfolio-distinctiveness check

_Last reviewed: 2026-08-02 (created — Theme-3 P0 fix: the gauntlet had no check for sameness ACROSS the operator's own products; this file supplies the discovery mechanism `../SKILL.md § Step 1.6` needs)._

> **Owned by:** `v-anti-template-gauntlet` Step 1.6 only. This file is a DISCOVERY MECHANISM plus
> a self-updating cache — it is never hand-authored ground truth. If a row in the manifest looks
> wrong, don't hand-edit it; let the next gauntlet run re-derive it from disk.

## Purpose

The portfolio-distinctiveness check needs to compare "the product being gauntlet-run right now"
against every OTHER product the operator has already shipped, without a human pointing at them
each time. This file defines HOW to find those other products — a decision rule, durable — never
WHICH products exist right now — a fact, volatile, that lives only in the manifest table below,
which is a cache, not this file's authority. Per the durability mandate governing this whole
skill cluster: decision rules survive; point-in-time product lists rot the moment a product is
renamed or retired.

## Discovery sequence

Step 1.6 runs this, in order, and stops at the first method that returns ≥1 product:

1. **`$PORTFOLIO_ROOT` environment variable**, if set in the invoking shell — treat its value as
   the directory containing sibling product repos (one subdirectory per product).
2. **`~/.claude/PORTFOLIO_ROOT`** — a one-line pointer file the operator creates once
   (`echo /path/to/portfolio-dir > ~/.claude/PORTFOLIO_ROOT`). Durable across shells and sessions;
   nothing in this skill hardcodes a path. If present, read it and use the directory it names.
3. **This file's `## Known products` manifest** (below) — rows the gauntlet itself appended on
   prior runs across different projects. Treat every row as a CACHE: before using it, verify the
   `Repo path` still exists and its overlay still resolves
   (`test -f "<repo path>/.interface-design/system.md"`); drop and log
   `stale_entry_dropped: <product>` for any row that fails this check rather than comparing
   against a product that may have been renamed, merged, or deleted.
4. **Auto-scan fallback** — sibling directories of `$PROJECT_ROOT`'s parent, filtered to those
   carrying `.interface-design/system.md` (proof they're on the canonical system) and excluding
   `$PROJECT_ROOT` itself:
   ```bash
   find "$(dirname "$PROJECT_ROOT")" -mindepth 2 -maxdepth 2 \
     -path '*/.interface-design/system.md' 2>/dev/null \
     | grep -v "^$PROJECT_ROOT/" \
     | sed 's#/\.interface-design/system\.md##'
   ```

**If all four methods return zero sibling products:** this is either the operator's first
product on the canonical system, or discovery genuinely failed (`$PORTFOLIO_ROOT` unset, no
pointer file, empty/all-stale manifest, sibling dirs not adjacent to `$PROJECT_ROOT`). **Never
treat this as a silent PASS.** `../SKILL.md § Step 1.6` specifies the exact loud-degrade line the
gauntlet report must carry in this case — the absence of comparison data is itself a
finding-shaped fact the operator needs to see, not something to paper over.

## Known products (self-updating manifest — a cache, not authority)

Every gauntlet run that successfully derives a structural profile for the product it just
audited (`../SKILL.md § Step 1.6`, category table in
`gauntlet-checks.md § Portfolio-distinctiveness check`) appends or updates that product's row
here — regardless of the run's PASS/CONDITIONAL_PASS/BLOCK verdict, because the row records what
the product IS, not whether it shipped clean. Verify every row against disk before trusting it
(Discovery step 3 above) — never hand-edit a row's profile fields; let the next run re-derive
them from the product's own overlay and code.

| Product | Repo path | Overlay path | Structural profile (density tier / signature component / type pairing / nav-config note) | Last verified |
|---|---|---|---|---|
| _(empty — populated by the first gauntlet run that discovers ≥1 other product)_ | | | | |

## Refresh trigger

This manifest never goes stale on its own calendar — it is re-verified against disk on every
single Step 1.6 run (Discovery step 3), which is a stronger guarantee than a periodic review
window. The only failure mode is a row surviving after its product repo moved, renamed, or was
deleted; the existence check in Discovery step 3 catches that every run, not on a delay.
