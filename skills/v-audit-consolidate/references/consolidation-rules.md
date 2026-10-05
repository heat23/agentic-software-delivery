# Consolidation rules

> **Persona for this reference:** senior data-pipeline engineer
> with experience deduplicating heterogeneous outputs from
> independent analyzers. Loaded on-demand by v-audit-consolidate
> Steps 4-6.

When multiple audit skills run on the same project, their
outputs overlap. The OG-paths issue surfaces in v-prelaunch-
readiness as `M-OG-001` AND in v-anti-template-gauntlet as
`OG-01`. Both are correct; both are independently valuable; and
both produce a fix-prompt the operator would otherwise execute
twice.

This reference documents the deterministic algorithms that
collapse those duplicates into a single consolidated finding
without losing source-skill provenance.

---

## Finding fingerprint algorithm

**Why an exact `file:line` hash isn't enough:** two audit skills scanning the same code rarely cite the
*identical* line — one anchors on the function signature, another on the offending statement three lines
down; one is line-specific, another is file-level with no line at all. Requiring an exact match on `line`
means cross-skill duplicates almost never collide, and consolidation quietly degrades to concatenation
(every source's findings pass through untouched) — defeating the point of running consolidate at all. The
matching rule below is therefore two independent tests, either of which is sufficient to treat two findings
as the same underlying issue:

```
same_finding(A, B) :=
    ( file_path_normalized(A) == file_path_normalized(B)
      AND category_slug(A) == category_slug(B)
      AND line_distance(A, B) <= NEARBY_WINDOW )   # primary: file + category + nearby line
    OR
    ( file_path_normalized(A) == file_path_normalized(B)
      AND title_similarity(A, B) >= SIMILARITY_THRESHOLD
      AND line_distance(A, B) <= FALLBACK_WINDOW )   # fallback: same file + same finding, category-slug drift or a line offset beyond NEARBY_WINDOW but still nearby
```

- `NEARBY_WINDOW = 10` lines. `line_distance` treats a file-level citation (`FILE` token) as distance 0 from
  ANY line in the same file+category — a file-level finding and a line-specific finding about the same issue
  in the same file now merge instead of being forced apart.
- `title_similarity` = Jaccard similarity of the lowercased, stemmed, stopword-stripped significant-keyword
  sets of the two titles (e.g. "Broken OG image paths on 16 pages" → `{broken, og, image, path}`). Use
  `SIMILARITY_THRESHOLD = 0.5` (at least half the significant keywords overlap). This is the escape hatch for
  same-file dupes where the two skills' category-slug derivation disagrees (e.g. one categorizes as
  `error-handling`, the other as `input-validation`, for the same missing-check finding) or the line numbers
  drift by more than `NEARBY_WINDOW`.
- `FALLBACK_WINDOW = 50` lines. The title-similarity fallback still needs a line-distance bound — without one,
  two unrelated same-titled findings far apart in a large file (e.g. "loading state on Submit button" at line
  42 vs "loading state on Delete button" at line 890) would incorrectly merge on keyword overlap alone
  (`{loading, state, button}` clears the 0.5 Jaccard threshold even though they're different UI elements). A
  file-level citation (`FILE` token) is still distance 0 from any line, so file-level ↔ line-specific merges
  are unaffected by this bound.
- Compute `fingerprint = sha1(file_path_normalized + ':' + line_bucket + ':' + category_slug)` as before for
  the **primary** grouping key (Step 4), where `line_bucket = floor(line / NEARBY_WINDOW) * NEARBY_WINDOW`
  (or `FILE` unchanged) — this catches most same-category near-line dupes cheaply via a single hash-group
  pass. Then, within Step 5's clustering, run the exact `same_finding()` test above (which also inspects the
  window boundary the bucket hash can miss, e.g. line 39 vs 41 straddling a bucket edge, and the
  title-similarity fallback) to merge any additional pairs the bucket hash didn't already group. Never emit
  duplicates as a "known limitation" — the two-test rule above is the fix, not a suggestion to try later.

### Components

**`file_path_normalized`** — the file the finding cites:
- Strip leading `./` (e.g., `./resources/js/Welcome.tsx` → `resources/js/Welcome.tsx`)
- Strip trailing whitespace
- Collapse double slashes (`//` → `/`)
- Lowercase the entire path (filesystems vary on case sensitivity; collapse)
- **For findings spanning multiple files** (e.g., "broken on 16 pages"): sort the file list lexicographically, then use the FIRST file (by sorted order) as the canonical fingerprint anchor. Sorting ensures audits citing files in different orders produce the same fingerprint. Include the remaining files in `also_affects: []`.

**`line`** — the line number from the citation:
- If single line: use that number (e.g., `42`)
- If line range: use the start (e.g., `42-67` → `42`)
- If file-level (no line cited): use `FILE` (literal token, NOT `0`) — keeps file-level findings distinct from line-1 findings, and prevents two unrelated file-level findings in the same category from collapsing
- If only column or other non-line-number citation: use `FILE` (treat as file-level)

**Note on file-level vs line-specific findings:** a file-level finding ("Lazy loading missing in Pricing.tsx") and a line-specific finding ("Lazy loading on Pricing.tsx:42") produce DIFFERENT primary hashes (`...:FILE:lazy-loading-missing` vs `...:40:lazy-loading-missing`, using the bucketed line), so they don't collide in the cheap Step 4 hash-group pass. Step 5's `same_finding()` test still merges them: `line_distance` treats `FILE` as distance 0 from any line in the same file+category, so this pair merges automatically — no manual operator consolidation needed for the common case. The title-similarity fallback catches the rarer case where `category_slug` itself disagrees between sources.

**`category_slug`** — coarse-grained category derived from the finding:
- Source: the finding's `category` field (if present in JSON output)
- Fallback: derive from finding title via these patterns (case-insensitive, applied in order):

  | Title keywords match | Category slug |
  |---|---|
  | "OG image" / "og:image" / "open graph" / "social share image" | `og-image` |
  | "icon" + ("size" / "sizing" / "consistent") | `icon-sizing` |
  | "CTA" + ("label" / "generic" / "default") | `cta-label` |
  | "hover" + ("only" / "mobile" / "touch") | `hover-only-interaction` |
  | "loading" + "state" | `loading-state` |
  | "error" + ("toast" / "message" / "boundary") | `error-handling` |
  | "empty" + "state" | `empty-state` |
  | "confirm" + ("native" / "browser" / "window") | `native-confirm-dialog` |
  | "twitter" + ("handle" / "consistency") | `twitter-handle-consistency` |
  | "password" + ("validation" / "schema") | `password-validation` |
  | "annual" + ("billing" / "pricing") | `annual-billing-cta` |
  | "gradient" + ("preset" / "default" / "tailwind") | `default-gradient` |
  | "stock" + ("photo" / "photography") | `stock-photography` |
  | — SECURITY — | |
  | ("SQL" / "query") + "injection", or "SQLi" | `sql-injection` |
  | "XSS" / "cross-site scripting" / ("dangerouslySetInnerHTML" without "sanitize") / ("unsanitized" + ("html" / "output")) | `xss` |
  | "CSRF" / "cross-site request forgery" | `csrf` |
  | "SSRF" / "server-side request forgery" | `ssrf` |
  | "IDOR" / ("authorization" / "authz" / "access control") + ("missing" / "bypass" / "broken") / "BOLA" | `broken-authz` |
  | ("auth" / "authentication" / "login" / "session") + ("bypass" / "weak" / "missing" / "fixation") | `auth-weakness` |
  | ("secret" / "API key" / "token" / "credential" / "password") + ("hardcoded" / "exposed" / "leaked" / "in source" / "logged") | `secret-exposure` |
  | "mass assignment" / ("fillable" / "guarded") + ("unsafe" / "missing") | `mass-assignment` |
  | ("rate limit" / "throttle") + ("missing" / "absent" / "no") | `missing-rate-limit` |
  | ("input" / "request") + ("validation" / "sanitization") + ("missing" / "absent" / "no") | `input-validation` |
  | "prompt injection" / ("LLM" / "AI") + ("injection" / "jailbreak" / "abuse") | `prompt-injection` |
  | — PERFORMANCE — | |
  | "N+1" / "n plus one" / ("eager" + "load" + ("missing" / "no")) | `n-plus-one` |
  | ("unbounded" / "unpaginated" / "no pagination" / "missing pagination") + ("query" / "list" / "result") | `unbounded-query` |
  | ("missing" / "no") + "index", or "full table scan" | `missing-index` |
  | ("cache" / "caching") + ("missing" / "no" / "absent" / "uncached") | `missing-cache` |
  | ("slow" / "blocking") + ("query" / "request" / "render" / "response") / "bundle size" / "payload weight" | `perf-latency` |
  | ("memory" / "resource") + ("leak" / "exhaustion") | `resource-leak` |
  | — ACCESSIBILITY — | |
  | ("alt" + "text") + ("missing" / "no") / ("image" + "accessible") | `missing-alt-text` |
  | ("aria" / "role" / "label") + ("missing" / "wrong" / "incorrect") | `aria-issue` |
  | "contrast" + ("low" / "insufficient" / "fail" / "ratio") / "WCAG" + "contrast" | `low-contrast` |
  | ("keyboard" / "focus") + ("trap" / "missing" / "inaccessible" / "no focus") / "focus state" + ("missing" / "no") | `keyboard-a11y` |
  | ("screen reader" / "a11y" / "accessibility") + ("broken" / "issue" / "gap") | `a11y-general` |
  | — BILLING / PAYMENTS — | |
  | ("webhook") + ("signature" / "verification" / "unverified" / "unhandled" / "idempoten") | `webhook-handling` |
  | ("double" / "duplicate") + ("charge" / "bill" / "invoice") / "idempoten" + ("payment" / "charge") | `double-charge` |
  | ("dunning" / "failed payment" / "retry") + ("missing" / "no" / "absent") | `dunning-gap` |
  | ("subscription" / "plan" / "proration" / "swap") + ("wrong" / "incorrect" / "broken" / "bug") | `subscription-logic` |
  | ("tax" / "VAT" / "currency") + ("wrong" / "missing" / "incorrect") | `billing-calculation` |
  | — DATA INTEGRITY / RELIABILITY — | |
  | ("transaction" / "atomicity") + ("missing" / "no" / "not wrapped") / "partial write" | `missing-transaction` |
  | ("race condition" / "concurrency" / "lock") + ("bug" / "missing" / "unsafe") | `race-condition` |
  | ("migration") + ("destructive" / "unsafe" / "NOT NULL" / "not nullable" / "no default") | `unsafe-migration` |
  | ("idempoten") + ("missing" / "not" / "no") / ("retry" + "unsafe") | `non-idempotent` |
  | ("foreign key" / "constraint" / "cascade") + ("missing" / "no") | `missing-constraint` |
  | — OBSERVABILITY / OPS — | |
  | ("logging" / "log") + ("missing" / "no" / "absent" / "insufficient") | `missing-logging` |
  | ("error" / "exception") + ("swallowed" / "silenced" / "ignored" / "uncaught") | `swallowed-error` |
  | ("debug" / "APP_DEBUG") + ("on" / "true" / "enabled") + "production" / ("CORS" + ("permissive" / "wildcard" / "wide open")) | `unsafe-config` |
  | — TESTING — | |
  | ("test" / "coverage") + ("missing" / "no" / "absent" / "gap") | `missing-test` |
  | ("flaky" / "flake" / "non-deterministic") + "test" | `flaky-test` |
  | ("test") + ("blesses" / "tautolog" / "asserts implementation" / "seeds same path") | `weak-test` |
  | (fallback) | `category-{first-3-tokens-lowercase-hyphenated}` |

  Match is case-insensitive; a `+` means all listed tokens must be present, a `/` inside a group means any-of.
  Apply the rows top-to-bottom and take the FIRST match — the specific security/perf/a11y/billing rows above
  are ordered before the generic fallback so a "Missing rate limit on login" finding slugs to
  `missing-rate-limit`, not the 3-token fallback. This table is deliberately broad because consolidate now
  ingests findings from `v-check`, `v-bug-hunt` (both its `bugs` and `boundaries` lenses — v-edge-hunt merged in 2026-07-05), and `v-audit-code` (security / perf / data /
  reliability heavy), not just the marketing/UI specialists it originally served — a too-narrow table sends
  every backend finding into the `category-{first-3-tokens}` fallback, which almost never collides across
  skills and so re-introduces the concatenation problem the fingerprint exists to prevent.

  E.g., a finding titled "Lazy loading missing on Cashier methods" with no explicit category falls into `category-lazy-loading-missing` after the fallback rule.

### Example

- v-prelaunch-readiness finding `M-OG-001`: file=`resources/js/Pages/Marketing/Pricing.tsx` (first of 16 listed), line=296, title="Broken OG image paths"
- v-anti-template-gauntlet finding `OG-01`: file=`resources/js/Pages/Marketing/Pricing.tsx`, line=296, title="OG images referenced at wrong path"

Both compute fingerprint using the bucketed line (`line_bucket = floor(296 / 10) * 10 = 290`, per the
fingerprint formula above — NOT the raw cited line):
```
sha1("resources/js/pages/marketing/pricing.tsx" + ":" + "290" + ":" + "og-image")
```

Same fingerprint → identified as duplicates.

---

## Duplicate detection + merging

Group findings by fingerprint. For each group of N≥2 findings (a duplicate cluster):

### 1. Pick the "primary" finding

Tie-break order (stop at first decisive criterion):

1. **Richest fix description** — finding with the longest `fix:` field (more characters = more guidance)
2. **Most authoritative source skill** per this priority order (specialist > generalist):
   - Specialist v-audit-* skills (admin, analytics, growth, messaging, sales-pricing, seo) → highest priority (their fix descriptions are domain-expert grade)
   - v-audit-code findings → high (comprehensive whole-repo pass; absorbed `v-ui-audit`'s audit depth 2026-07-06, retired)
   - Pre-launch-style skills (v-prelaunch-readiness, v-anti-template-gauntlet) → middle (focused but narrower)
   - v-check (broad codebase audit) → lowest priority for tie-break (broad-net catches same issues but with shallower fix guidance; deliberately NOT in the middle tier — a single tier per skill keeps primary-finding selection deterministic)
3. **Most recent report** — break ties by report's `dateGenerated` (newest wins)
4. **Shortest source finding ID** — final tie-break. E.g., `OG-01` beats `M-OG-001`. Shorter IDs come from skills with simpler ID schemes (audit-style skills use 2-letter prefixes; multi-skill bundles use longer prefixes). Either works deterministically; this just picks the more aesthetic display.

### 2. Build the consolidated finding

```yaml
id: CON-{NNN}                           # Sequential consolidated ID
canonical_severity: P0|P1|P2|P3         # Worst-case across the cluster
fingerprint: {sha1 hash}
title: {primary's title}
description: {primary's description}
fix: {primary's fix field}
file_path: {primary's first file}
line: {primary's line}
also_affects:                           # If the primary cited multiple files, list the rest
  - {file:line}
  - {file:line}
sources:                                # Track every original audit
  - skill: v-prelaunch-readiness
    finding_id: M-OG-001
    native_severity: MUST-FIX
    report_path: {original report path}
  - skill: v-anti-template-gauntlet
    finding_id: OG-01
    native_severity: CRITICAL
    report_path: {original report path}
verdict_impact: blocking|high|medium|low # Used by Step 6 verdict aggregation
```

`native_severity` records each source skill's own vocabulary verbatim (MUST-FIX, CRITICAL, …); `canonical_severity` is always P0–P3. The native→canonical translation table lives in `severity-mapping.md` (canonical scale authority: `~/.claude/skills/references/v-core-severity.md`) — never improvise a mapping here.

### 3. Worst-case severity

When 2+ findings cluster with different P-tiers, the consolidated
finding takes the **worst** (lowest-numbered) tier:
- P0 + P1 → P0
- P1 + P2 → P1
- P2 + P3 → P2

This errs on the side of caution. The operator can downgrade
manually if needed.

### 4. Same-fingerprint sanity check

If 2+ findings have the same fingerprint but **different** titles
that don't share keywords, log a warning:

```
warning: fingerprint collision suspected — same file:line:category
         but titles differ substantially:
         - "Broken OG image paths" (v-prelaunch-readiness)
         - "Lazy loading missing here" (v-check)
```

Manual review the cluster before merging. Most often this means
the category-slug fallback collapsed two unrelated issues into
the same slug — refine the slug and re-fingerprint.

---

## Verdict aggregation

After all findings are consolidated and severity-normalized:

```
if any source audit's canonical verdict == BLOCK_OVERRIDDEN:
    # Operator explicitly overrode a BLOCK at the source-audit level.
    # Treat as NEEDS-WORK with a flag, NOT BLOCK.
    consolidated_verdict = NEEDS-WORK
    consolidated_verdict_flag = "block_overridden_at_source"
elif any source audit's canonical verdict == BLOCK:
    consolidated_verdict = BLOCK
elif any consolidated finding has canonical_severity == P0:
    consolidated_verdict = BLOCK
elif any consolidated finding has canonical_severity == P1:
    consolidated_verdict = NEEDS-WORK
elif any source audit's canonical verdict == NEEDS-WORK:
    consolidated_verdict = NEEDS-WORK
else:
    consolidated_verdict = PASS
```

The aggregated verdict is always the worst-case reading across
all source audits. There's no "averaging" — one BLOCK breaks
the whole sweep.

When `BLOCK_OVERRIDDEN` is the source verdict (operator used
`--force` on the underlying audit), the consolidated report
includes a callout:

```
⚠️ Source audit `{skill}` verdict was BLOCK_OVERRIDDEN by operator.
The consolidated verdict treats this as NEEDS-WORK with a flag,
not BLOCK — the operator's override is respected at this layer.
```

---

## Stale-report detection

A report is **stale** if its generation date is older than the
project's most recent meaningful change. Heuristic:

```
last_relevant_commit = git log -1 --since={report_date} \
  --format='%H' --diff-filter=ACM \
  -- 'resources/' 'app/' 'src/' 'pages/' 'public/' 2>/dev/null

if last_relevant_commit is non-empty:
    report is potentially stale
```

When a stale report is detected, log a warning and INCLUDE its
findings in consolidation but flag them with `staleness: warning`.
The operator can choose to re-run the source audit or proceed
with the staler view.

The default time window is **14 days**. Beyond that, reports are
excluded by default unless the operator passes `--include-stale`.

**Stack-agnostic detection:** the heuristic above grep-checks
common SaaS source paths (`resources/`, `app/`, `src/`, `pages/`,
`public/`). For projects on non-Laravel/non-React stacks (Go,
Python, Rust, etc.), the path filter may not trigger. Fallback:
if the path-grep returns empty, run a stack-agnostic check —
`git log -1 --since={report_date} --format='%H' --diff-filter=ACM 2>/dev/null` (no path filter). If that returns ≥1 commit since
the report, the report is stale.

---

## Cross-skill source provenance

Every consolidated finding's `sources: []` lists every audit
that flagged it. This serves three purposes:

1. **Audit trail:** the operator can trace any consolidated
   finding back to its original report for full context.
2. **Re-run intelligence:** when the operator re-runs ONE of
   the source audits, the consolidated report can be
   incrementally updated rather than fully regenerated.
3. **Confidence boost:** a finding flagged by 3+ independent
   audit skills is higher-confidence than one flagged by a
   single skill. The consolidated report can sort findings by
   source-count as a secondary signal beyond severity.

---

## What this reference is NOT

- Not a finding-format spec (see `~/.claude/skills/references/v-audit-output-conventions.md`)
- Not a verdict semantics doc (see `severity-mapping.md`)
- Not a prompt-pack format spec (see `~/.claude/skills/references/v-core-prompt-pack.md`)
- Not a cross-project consolidation spec (this skill operates within ONE project root)

---

## Cross-references

- Severity vocabulary mappings: `severity-mapping.md`
- Output format conventions: `~/.claude/skills/references/v-audit-output-conventions.md`
- Prompt pack contract: `~/.claude/skills/references/v-core-prompt-pack.md`
- Audit floors (per-dim calibration; not used by this skill but referenced for context): `~/.claude/skills/references/v-audit-floors.md`
