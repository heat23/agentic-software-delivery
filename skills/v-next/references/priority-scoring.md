# v-next — Priority Scoring Model

Loaded on-demand by v-next Step 3. Combines the four signal categories from
`signal-sources.md` into one cross-project ranked list.

## Scoring formula

For each candidate action (one per stale-audit-family, per unresolved-finding-bucket, per
stranded-worktree-group, per red-CI-project, per pending-pack-inbox — § 5b in
`signal-sources.md`), compute:

```
PRIORITY_SCORE = (staleness_factor × 3) + (severity_factor × 4) + (stage_weight × 2) + (age_factor × 1)
```

- **staleness_factor** (0-10): 0 if fresh, 5 if "due", 10 if "overdue" per the family's
  threshold table in `signal-sources.md`. Linear-interpolate between thresholds when useful,
  or just use the 3-bucket value — precision beyond "fresh/due/overdue" isn't meaningful here.
- **severity_factor** (0-10): derived from unresolved finding counts — `0` if none, `3` per P2,
  `6` per P1, `10` per P0 (capped at 10; a single P0 already maxes this factor).
- **stage_weight** (0-10): mature/revenue-generating projects weight higher than greenfield
  ones for content/SEO staleness (a stale audit on a live revenue product costs more than on a
  pre-launch project) — greenfield: 3, growth: 7, mature: 10. CI/worktree staleness is NOT
  stage-weighted (a red CI pipeline matters the same regardless of launch stage) — use 10 flat
  for those candidate types.
- **age_factor** (0-10): for worktrees/branches only — `min(10, days_stranded / 3)`. For
  audit/finding candidates, use 0 (staleness_factor already captures time).
- **Pending-pack-inbox candidates** (§ 5b): score like a worktree-group — staleness_factor=0,
  severity_factor=6 (generated work sitting unexecuted is a follow-through gap, not drift),
  stage_weight=10 flat (not stage-weighted), age_factor=`min(10, days_since_oldest_queued_pack / 3)`.
  Packs parked in `.needs-review/` are an ACTIVE problem: treat like tie-break rule 1 (they need
  the operator's eyes, and dependent waves may be blocked behind them).
- **`security_audit` staleness candidates** (`signal-sources.md` § 6): staleness_factor from
  the § 6 fresh/due/overdue table (0/5/10). severity_factor = `10` flat if a CRITICAL/HIGH
  advisory is already known-open from a prior `composer audit`/`npm audit` run recorded anywhere
  in the project (e.g. a `PRE_FLIGHT_REPORT_*` that logged one) — a known open vulnerability
  outranks plain staleness; else `0` (staleness alone, no known CVE, is lower urgency). stage_weight
  = 10 flat (a live dependency exposure doesn't care about launch stage). age_factor = 0.
- **`legal_docs` staleness candidates** (`signal-sources.md` § 7): staleness_factor from the § 7
  table. severity_factor = `6` when the jurisdiction-set escalation trigger fired (treat like a
  P1 — a compliance gap that compounds, not a P0 actively being exploited), else `3` (age-only
  staleness). stage_weight = 10 flat (legal exposure isn't stage-gated the way SEO content
  staleness is — a pre-launch project with public traffic already carries CCPA/accessibility/
  AI-transparency exposure per `v-legal-docs-generate`). age_factor = 0.

## Tie-breaking

1. Any candidate involving a **P0 finding**, a **red CI pipeline**, or a **known-open
   CRITICAL/HIGH dependency advisory** ALWAYS ranks above any staleness-only candidate,
   regardless of computed score — these are active problems, not drift.
2. Among equal scores, older items (more days since last touched) rank first.
3. Cap the rendered list at the top 15 candidates across the whole portfolio — beyond that,
   summarize the remainder as a count in the executive summary rather than listing every one.

## Worked example

Project A: `v-audit-seo` last run 95 days ago (overdue, staleness_factor=10), 2 unresolved P1
findings (severity_factor=6), stage=mature (stage_weight=10), not a worktree/CI candidate
(age_factor=0):

```
PRIORITY_SCORE = (10×3) + (6×4) + (10×2) + (0×1) = 30 + 24 + 20 + 0 = 74
```

Project B: a stranded worktree, 21 days old (age_factor=7), no audit/finding component
(staleness_factor=0, severity_factor=0), CI/worktree candidates use stage_weight=10 flat:

```
PRIORITY_SCORE = (0×3) + (0×4) + (10×2) + (7×1) = 0 + 0 + 20 + 7 = 27
```

Project A's stale-and-unresolved SEO audit outranks Project B's stranded worktree — both are
legitimate items on the ranked list, but A is more urgent.

## Anti-gaming note

Do not inflate scores to make the list feel more "actionable" — a portfolio where every project
is genuinely current should produce a SHORT list (or an empty one, with `status: current`
reported for each project). A short or empty ranked list is a valid, honest outcome.
