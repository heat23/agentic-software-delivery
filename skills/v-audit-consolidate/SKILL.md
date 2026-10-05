---
name: v-audit-consolidate
description: "Use when consolidating multiple audit reports, deduplicating findings, or normalizing severities."
allowed-tools: Read, Write, Bash, TaskCreate, TaskUpdate, AskUserQuestion
user-invocable: true
disable-model-invocation: true
context: fork
model: inherit  # inherit = run on the session/CLI model. Governs MANUAL /v-audit-consolidate only; Skill-tool dispatch ignores it. Fan-out subprocesses are pinned separately at the dispatch site — via --model, or by the agent file's own frontmatter pin when dispatched with --agent (see v-core-model-routing.md).
---
<!-- skill: v-audit-consolidate | version: 1.3.4 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing. Meta-audit consolidator that runs AFTER multiple audit skills have produced their reports.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-review.md`, and `_v-audit.md`.

**Model — MANDATORY (parent-model inheritance).** Every subprocess this skill dispatches runs on the **operator's session model**, never a hardcoded tier — read `~/.claude/skills/references/v-audit-parent-model.md` and export its preamble ONCE before the first dispatch:

```bash
export V_MODEL_POLICY_OVERRIDE=1
V_AUDIT_MODEL="parent"     # every --model in this skill takes this value
```

Without that override every dispatch exits 2 on the sonnet-max gate. Never pass `--agent <name>` for a **haiku-pinned** agent — `--agent` ignores `--model` entirely and is the one path this preamble cannot correct (see that file's § The `--agent` bypass).


**Audit opener:** see `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and task-list initialization (TaskCreate/TaskUpdate; see that file's § TodoWrite Progress Reporting for the current tool names) before Step 0 begins. **Standalone-depth override (intentional, per `_v-audit.md` § Depth Question Contract → "meta-skills without a depth axis"):** when run standalone, this skill substitutes its single Consolidation Scope question for the canonical Quick/Standard/Thorough depth question — consolidation depth is driven by the discovered report set (count + window), not a depth tier.

**Fork dispatch constraint (W-fork-fix):** this skill runs `context: fork` and therefore CANNOT use the Agent tool. Steps 2 and 7 dispatch their workers — at the operator's resolved model — as independent `claude -p` Bash subprocesses per `references/subprocess-dispatch.md` — read it before either step.

**Scope boundary (mandatory):** per `_v-audit.md` § In-App Actionability Boundary. Source reports written before the boundary existed may still contain off-stack findings (runbooks/ops process, offsite backups, HA/failover/DR, external monitoring/alerting services, CI/CD or DNS/CDN infrastructure, new vendors/tools) — DROP them during consolidation: exclude from the consolidated findings, scores, dedup counts, and prompt packs; optionally move each dropped item to `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` per that section, and record the dropped IDs in the consolidation report so the exclusion is auditable.

For severity normalization across audit skills, read `references/severity-mapping.md`.
For finding-fingerprint algorithm + dedup rules + verdict aggregation, read `references/consolidation-rules.md`.
For output conventions (citation format, version stamp), read `~/.claude/skills/references/v-audit-output-conventions.md`.
For the dated-folder naming convention (`.v-prompt-packs/<skill>-<MM-DD>/`, same-day re-run archive), read `~/.claude/skills/references/v-core-prompt-pack.md`.
For the **runnable wave-pack form this skill emits** — wave assignment, closing waves, and self-validate — read `~/.claude/skills/references/v-runnable-pack-convention.md`. This is the single source of truth for the wave partitioning; `/v-prompt-pack-generate` emits the same form from plans.

```yaml
contract:
  tier: user-facing
  accepts: [PROJECT_ROOT (auto-detected), optional --include=skill1,skill2,..., optional --window=N (days)]
  produces: [CONSOLIDATED_AUDIT_REPORT_${CLAUDE_SESSION_ID}.md, .v-prompt-packs/v-audit-consolidate-<MM-DD>/ runnable wave tree (00-README master map + flat w<N>-*.txt paste-ready /v packs, 99-verify last) per v-runnable-pack-convention.md — run-v-packs-ready]
  invokes: []
  conditional-invokes: []
  invoked-by: [/v, user, /v-audit-orchestrator]
  estimated_tokens: 20k-60k
```

## Skill Boundaries

**SME persona:** This skill is run by a **senior audit synthesist + program manager** — specialty is normalizing severity vocabularies across heterogeneous audit outputs, deduplicating findings via fingerprinting, surfacing cross-audit themes the individual specialists missed, and producing a single prioritized backlog from N parallel concerns.

### Best fit

- Pre-launch sweep where the operator ran 2+ audit skills (e.g., v-prelaunch-readiness + v-anti-template-gauntlet + v-audit-seo) and now has overlapping prompt packs to execute
- Pre-merge gate where v-check + v-verify-done + v-pre-flight all flagged related issues — consolidate into one fix sequence
- Periodic project-health re-runs where 4-5 audits accumulate over a week and the operator wants ONE prioritized fix list, not N

### Use instead

- The underlying audit skill — run that first. v-audit-consolidate has nothing to consume if no audits have run yet.
- **Single-audit case:** if you've only run ONE audit, paste its prompt-pack file into `/v` directly (routes to the v-build primitive). v-audit-consolidate would auto-detect this and exit with a "no consolidation needed; run /v on the existing prompt pack" message — but going straight to /v skips the round trip.
- `/v <prompt-pack>` — for executing a single prompt pack (routes to the v-build primitive). Consolidate is for *merging* prompt packs before execution; v-build is for executing them.
- `/v-check` — for the operational launch gate. v-audit-consolidate gives you a unified product/code view; v-check gives you the operational view. Both run before launch.

### Not for

- Re-running audits (this skill consumes existing outputs; never re-runs the underlying audits)
- Fabricating findings (only consolidates findings that already exist in source reports)
- Cross-project consolidation (operates on ONE project root at a time)
- Replacing the underlying audit skills (it depends on them; without 2+ audits, nothing to consolidate)


## Verification Gates

v-audit-consolidate inherits gated findings from source audits — each source-audit (v-audit-{admin,analytics,growth,messaging,sales-pricing,seo}, v-check, v-anti-template-gauntlet, v-prelaunch-readiness) has already passed its own Gates 0/1/2/8 per `~/.claude/skills/references/v-audit-gates.md`. **`v-audit-code` is the exception:** it's a flexible-framework audit with no numbered-dim checklist, so it does not run Gates 0/1/2/8 — its findings still need a `file:line` citation (this skill's own Gate 1 dedup logic still applies to whatever it hands off), but there's no per-dim exploration block or floor-driven re-task to inherit. (`v-ui-audit` retired 2026-07-06 and is no longer a live source; `v-audit-code` is its successor for deep-UX findings — see `references/severity-mapping.md`.) Findings carry source provenance into the consolidated report; their Gate 0 exploration evidence and Gate 1 file:line citations (where the source audit produced them) are preserved unchanged.

**This skill DOES re-apply Gate 8 (file-existence verification) on the consolidated prompt pack.** Step 8 (runnable-pack self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree — the structural check plus `run-v-packs --dry-run`) is a Gate 8 enforcement on the merged output: methodology must verify both `CONSOLIDATED_AUDIT_REPORT_${CLAUDE_SESSION_ID}.md` AND the runnable `.v-prompt-packs/v-audit-consolidate-<MM-DD>/` wave tree exist (and resolve to the assigned waves) before declaring completion.

This skill does NOT re-run Gates 0, 1, or 2 on findings that were already gated upstream — re-running would be redundant work without new evidence. Re-task only when a source audit's exploration block or citations are visibly missing (treat as a source-audit defect; surface in the consolidated report as `source_audit_gate_violation: <skill>:<finding-id>`).


## Why This Exists

Pre-launch flows for solo SaaS routinely run 4-7 audits:
v-prelaunch-readiness, v-anti-template-gauntlet, v-audit-seo,
v-audit-messaging, v-audit-sales-pricing, v-check,
v-pre-flight. Each produces its own report and its own
`v-{skill}-prompts/` directory. **Findings overlap.** A broken
OG image path gets flagged by 3 different skills with 3 different
finding IDs (`M-OG-001`, `OG-01`, `SEO-014`) at 3 different
severity tiers (`MUST-FIX`, `CRITICAL`, `P1`).

Without consolidation, the operator works through 3 separate
prompt packs that all fix the same thing. Or worse, they pick
one pack to run and silently skip findings the other packs caught
that the chosen pack missed.

This skill is the missing meta-layer:
- One canonical severity vocabulary (P0/P1/P2/P3)
- One canonical verdict (PASS/NEEDS-WORK/BLOCK) aggregated
  worst-case across all source audits
- One de-duplicated finding list (same file:line:category →
  one consolidated finding with all source-skill provenance)
- One merged prompt pack — every fix appears once

The operator runs N audits, then runs `/v-audit-consolidate`,
then works through ONE prompt pack instead of N.

## Entry Point

**Auto-detect everything. ONE multiple-choice question for the operator.**

### Auto-detection sequence

1. **Discover audit reports** within PROJECT_ROOT (recursive, last 14 days by default):
   ```bash
   find "$PROJECT_ROOT" -maxdepth 4 \
     \( -name '*_REPORT_*.md' -o -name '*_REPORT_*.json' \
        -o -name '*_AUDIT_*.md' -o -name '*_AUDIT_*.json' \
        -o -name 'PRELAUNCH_READINESS_REPORT_*.md' \
        -o -name 'GAUNTLET_REPORT_*.md' \
        -o -name 'LAUNCH_CHECKLIST_*.md' \
        -o -name 'PRE_FLIGHT_REPORT_*.md' \
        -o -name 'VERIFY_DONE_REPORT_*.md' \
        -o -name 'SEO_AUDIT_*.md' -o -name 'SEO_AUDIT_*.json' \
        -o -name 'ANALYTICS_AUDIT_*.md' -o -name 'ANALYTICS_AUDIT_*.json' \
        -o -name 'GROWTH_AUDIT_*.md' -o -name 'GROWTH_AUDIT_*.json' \
        -o -name 'SALES_PRICING_AUDIT_*.md' -o -name 'SALES_PRICING_AUDIT_*.json' \
        -o -name 'ADMIN_AUDIT_REPORT_*.md' -o -name 'ADMIN_AUDIT_REPORT_*.json' \
        -o -name 'v-ui-audit-*.md' -o -name 'v-ui-audit-*.json' \) \
     ! -name 'CONSOLIDATED_AUDIT_REPORT_*' \
     ! -name 'QA_REPORT_*' ! -name 'IMPLEMENTATION_REPORT_*' ! -name 'SKILL_REVIEW_REPORT_*' \
     -mtime -14 2>/dev/null | sort
   ```

   **The `*_REPORT_*` / `*_AUDIT_*` catch-alls are broad by design** (so a new audit skill is discovered without
   an SKILL.md edit here), but that breadth also matches non-audit session artifacts that happen to share the
   `_REPORT_` token: `QA_REPORT_<sid>.md` (v-qa-reviewer's per-session acceptance review), `IMPLEMENTATION_REPORT_<sid>.md`
   (build-session completion artifact), and `SKILL_REVIEW_REPORT_<sid>.md` (meta-review of a *skill*, not a product
   audit) are none of them product-audit findings — ingesting them pollutes consolidation and can spuriously push
   the "2+ reports found" threshold. The three `! -name` exclusions above are required alongside the
   `CONSOLIDATED_AUDIT_REPORT_*` self-recursion guard.

   **Critical:** the `! -name 'CONSOLIDATED_AUDIT_REPORT_*'` exclusion prevents self-recursion — without it, this skill would consume its own previous output on every re-run, doubling findings each time.

   **Legacy recognizer:** `v-ui-audit` retired 2026-07-06, absorbed into `v-audit-code` (see
   `references/severity-mapping.md`). The `v-ui-audit-*.md`/`.json` clause above is kept only so
   pre-existing legacy reports still discover — `v-audit-code`'s `AUDIT_CODE_REPORT_*.md` already
   matches the `*_REPORT_*.md` catch-all, so no new clause is needed for it.

2. **Discover prompt packs** alongside reports (both the current `.v-prompt-packs/<skill>-<MM-DD>/` convention
   AND the legacy `v-<skill>-prompts/` dirs still on disk from `v-refactor` before its 2026-07-06 retirement,
   absorbed into `v-audit-code`):
   ```bash
   find "$PROJECT_ROOT" -maxdepth 4 -type d \( -path '*/.v-prompt-packs/*' -o -name 'v-*-prompts' \) 2>/dev/null | sort
   ```
   The old glob matched ONLY `v-*-prompts` and so could never see any current skill's `.v-prompt-packs/` output.

3. **Inventory the bundle** — count reports, classify by source skill (filename prefix), count findings per source.

4. **Apply the early-exit logic:**
   - 0 reports found → exit with: "No audit reports found in `$PROJECT_ROOT` within the last 14 days. Run audit skills first (e.g., `/v-prelaunch-readiness`, `/v-check`, `/v-anti-template-gauntlet`)."
   - 1 report found → exit with: "Only one audit report found (`{path}`). No consolidation needed — work directly from that report's prompt pack at `{prompt_pack_path}`."
   - 2+ reports found → continue to entry-point question.

   **Early-exit still writes the report artifact.** On BOTH early-exit paths, write a minimal `$PROJECT_ROOT/.v/artifacts/CONSOLIDATED_AUDIT_REPORT_${CLAUDE_SESSION_ID}.md` (Phase-2 — create the dir; the Stop-hook `_PB_*` gate dual-searches, root is a legacy fallback) before exiting — first line `# CONSOLIDATED_AUDIT_REPORT_{session-id}`, a `generated:` ISO-timestamp line, `verdict: NOT-RUN`, the line `Generated by v-audit-consolidate`, a `## Source audits` section stating what discovery found (0 reports, or the single report's path), and the early-exit message verbatim. This is the session's completion artifact: without it, a correctly-executed early-exit run has no recognized artifact and the Stop hook's Part-B abandonment block fires on a successful session.

### The single question

```yaml
question: "Which audit reports to consolidate?"
header: "Consolidation Scope"
multiSelect: false
options:
  - label: "All recent reports ({N} found, last 14 days) — Recommended default"
    description: "Consume every audit report + prompt pack discovered in PROJECT_ROOT. Best for periodic health-check sweeps."
  - label: "Pre-launch sweep (prelaunch + gauntlet + audit-messaging + audit-seo)"
    description: "The 4 most-common pre-launch audits. Filters to those skills only."
  - label: "Pre-merge sweep (check + verify-done + pre-flight)"
    description: "Code-quality audits run before merging a feature branch."
  - label: "Last 24 hours only"
    description: "Just today's audits — for tight launch-day cycles."
```

A custom subset isn't a listed option (it's a flag, not a choice) — it's reachable either
by typing `--include=skill1,skill2` via the free-text "Other" response, or by passing
`--include=` directly in the invocation, which skips the question entirely (see below).

The auto-discovery output ({N} found) is interpolated into the
first option's label so the operator sees the actual count.

**Interpolation contract:** before invoking `AskUserQuestion`, the orchestrator MUST substitute `{N}` with the actual count (e.g., `4`) in the option label. Do NOT pass `{N}` literally to the question UI — the operator would see `({N} found)` rather than `(4 found)`.

If the operator passes `--include=v-check,v-pre-flight,v-verify-done` (or any explicit subset) in the invocation, skip the question and proceed with that filter.

If the operator passes `--window=7` (or any other day count), use that as the time window instead of the default 14.

## Workflow

| Step | Action | Skip conditions |
|---|---|---|
| Step 0 | Audit opener (PROJECT_ROOT, V_DEPTH, task list) | — |
| Step 1 | Discover artifacts; apply early-exit if <2 reports (early-exit still writes the minimal report) | — |
| Step 2 | Parse reports (`claude -p` subprocess at the operator's resolved model) — JSON preferred, MD fallback | — |
| Step 3 | Normalize severity per `references/severity-mapping.md` | — |
| Step 4 | Compute fingerprint per finding | — |
| Step 5 | Deduplicate clusters (pick richest description; track all sources) | — |
| Step 6 | Aggregate verdict per `references/consolidation-rules.md` (BLOCK if any source-BLOCK or any P0; NEEDS-WORK if any P1 or any source-NEEDS-WORK; else PASS) | — |
| Step 7 | Assign waves (per `v-runnable-pack-convention.md` § Wave assignment) + build the runnable wave tree of `w<N>-*.txt` packs (`claude -p` subprocess at the operator's resolved model writes files) | Skip if 0 findings (PASS verdict) |
| Step 8 | Self-validate the runnable tree per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate (structural + `run-v-packs --dry-run`) | Skip if Step 7 was skipped |
| Step 9 | Write `.v/artifacts/CONSOLIDATED_AUDIT_REPORT_*.md` | — |
| Step 10 | Present summary (verdict + dedup stats + recommended fix order) | — |

### Step 0: Audit opener

Per `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and task-list initialization (TaskCreate at start, TaskUpdate per step) before Step 1. If the task tools are unavailable in this context, proceed without them — progress reporting is best-effort, never a blocker.

### Step 1: Discover and validate artifacts

Perform the artifact discovery and early-exit logic documented in the **Entry Point** section above (the audit-report `find` command and the prompt-pack discovery in Entry Point § Auto-detection). Apply the early-exit rules:
- 0 reports → exit with the documented "no audit reports found" message
- 1 report → exit with the documented "consolidation not needed; work directly from {path}" message
- 2+ reports → confirm count and source-skill classification, then proceed to Step 2

Do NOT re-run discovery logic in Step 2 — the report inventory and prompt-pack inventory are already in memory after this step.

### Step 2: Parse reports (subprocess dispatch)

Dispatch ONE parser subprocess (at the operator's resolved model — `$AUDIT_MODEL`, see `references/subprocess-dispatch.md` § Step 2) with ALL discovered report paths + parsing instructions — mechanism, JSON validation, and the retry-then-abort rule per `references/subprocess-dispatch.md` § Step 2 (**NOT the Agent tool**; never fall back to inline parsing). It returns a unified findings table.

**Carry `parse_errors` forward.** The returned `parse_errors` array is rendered in the Step 9 report (`## Parse warnings`) and counted in `## Consolidation stats`; Step 10's console summary names the unparsed reports when the array is non-empty. Dropping it at this layer would silently under-count findings from a broken source — the exact failure the subagent prompt's own "do NOT silently drop findings" rule exists to prevent.

**Carry `report_verdicts` forward.** The returned `report_verdicts` array (one entry per source report, `{source_skill, source_report, source_verdict}`) is the ONLY place a source report's own top-level verdict (its `NOT READY` / `UNRELIABLE` / `INCONSISTENT` / etc.) is captured — no per-finding object carries it. Step 6's aggregation reads this array (mapped through `severity-mapping.md` § Verdict vocabulary mapping to canonical PASS/NEEDS-WORK/BLOCK) to implement the "any source audit's canonical verdict == BLOCK" rule in `consolidation-rules.md` § Verdict aggregation. Step 9's `## Source audits` table's "Native verdict" / "Canonical verdict" columns render this same array. Dropping it here means a score-driven BLOCK with zero P0 findings (e.g. `analytics_health: UNRELIABLE` from a low `overall_score` alone) can never surface in the consolidated verdict — exactly the gap this wiring closes.

**Subprocess prompt template:**

```
You are a parser for audit-report consolidation. Read these N audit reports and extract every finding.

Reports to parse: [list of absolute paths]

For each report:
1. Detect format (.json or .md)
2. JSON path: parse JSON and extract `findings: []` array
3. MD path: parse markdown headings/tables to extract findings — look for sections "## Findings", "## MUST-FIX", "## P0", "### Fix N", numbered finding lists, or tabular finding rows. Known per-skill shapes (normative registry: `references/severity-mapping.md`): v-bug-hunt's `bugs` lens groups under `### P0_CRITICAL`…`### P3_SUSPECTED` headings with an inline `severity:` field; v-bug-hunt's `boundaries` lens (the former v-edge-hunt, merged in 2026-07-05 — same `BUG_HUNT_REPORT_*` file, distinguished by a `lens: boundaries` metadata field and `EHUNT-*` ID prefixes) uses the compact pipe header `#### <ID> | file:line | category | severity | confidence` — the 4th pipe token IS the severity (there are no severity headings to look for). Parse by ID prefix (`BHUNT-` vs `EHUNT-`), never by skill name — both shapes can appear in the same skill's output now.
4. **Also extract the report's own top-level verdict** — ONE per report, separate from per-finding severities. Look for (in order): a `verdict:` front-matter/body line (JSON top-level `verdict` key, or MD line matching `^verdict:\s*(.+)$`); OR a skill-specific top-level field named in `references/severity-mapping.md` § Verdict vocabulary mapping (`analytics_health:`, `growth_readiness:`, `messaging_health:`, `revenue_readiness:`); OR a `## Verdict` / `## Readiness` section's first bolded token. Return the RAW string exactly as written (e.g. `"NOT READY"`, `"UNRELIABLE"`, `"INCONSISTENT"`, `"BLOCK_OVERRIDDEN"`) — do NOT normalize it here, normalization happens in Step 3/6 against the mapping table. If a report emits no top-level verdict field at all (some skills only emit finding counts), return `null` for that report's `source_verdict` — do not guess one from the findings.

For each finding, return a normalized JSON object:

{
  "source_skill": "v-prelaunch-readiness",   // Inferred from filename pattern
  "source_report": "/path/to/report.md",
  "source_finding_id": "M-OG-001",            // Original ID
  "native_severity": "MUST-FIX",              // Original severity term
  "title": "Broken OG image paths on 16 pages",
  "description": "Full description from the report",
  "fix": "The 1-2 sentence fix description",
  "file_path": "resources/js/Pages/Marketing/Pricing.tsx",
  "line": 296,
  "also_affects": ["resources/js/Pages/.../Compare.tsx:42", "..."],   // Multi-file findings
  "category_hint": "og-image"                 // From the report's category field if present
}

For each REPORT (not finding — one entry per source report, even if it has zero findings), also return:

{
  "source_skill": "v-audit-analytics",        // Same inference as per-finding source_skill
  "source_report": "/path/to/report.md",
  "source_verdict": "UNRELIABLE"              // Raw top-level verdict string, or null if the report emits none
}

Return ONLY the JSON object (no prose, no code fences): { "findings": [...], "report_verdicts": [...], "parse_errors": [...] }

Parse_errors: any reports/findings that couldn't be parsed (give path + reason). Do NOT silently drop findings.
```

### Step 3: Severity normalization

Every incoming finding's severity MUST be normalized to the canonical P0-P3 scale of `~/.claude/skills/references/v-core-severity.md` ([[v-core-severity]]) **before** any dedup or ranking — that file is the single source of truth for what P0/P1/P2/P3 mean and for the "one P0 ⇒ failing verdict" rule the Step 6 aggregation depends on. `references/severity-mapping.md` is the per-skill lookup that translates each skill's *native* vocabulary (MUST-FIX, CRITICAL, HIGH, fail, …) into that canonical scale; its P-tier definitions are the [[v-core-severity]] definitions, restated only for the mapping table's convenience.

For each finding, look up its `(source_skill, native_severity)` in `references/severity-mapping.md` and assign `canonical_severity` (P0/P1/P2/P3).

If the pair isn't in the mapping table, default to **P2** and mark `severity_unmapped: true`. Log a warning.

### Step 4: Fingerprint computation

Per `references/consolidation-rules.md` § Finding fingerprint algorithm — the primary hash-group key uses the **bucketed** line so near-line dupes collide:

```bash
# line_bucket = FILE (literal) for file-level findings, else floor(line/10)*10
line_bucket=$([ "$line" = "FILE" ] && echo FILE || echo $(( line / 10 * 10 )))
fingerprint=$(echo -n "${file_path_lowercased}:${line_bucket}:${category_slug}" | shasum -a 1 | awk '{print $1}')
```

The `category_slug` derives from `category_hint` (if present in the source report) OR from title-keyword matching per the rules reference's extended table (security / perf / a11y / billing / data-integrity / observability / testing categories, not just marketing/UI).

### Step 5: Deduplicate

Group findings by fingerprint (the cheap first pass), THEN within and across neighbouring groups apply `consolidation-rules.md` § Finding fingerprint algorithm's `same_finding()` two-test rule to catch bucket-edge near-line dupes and same-file/different-category-slug dupes the hash alone misses. For each resulting cluster of N≥2 (a duplicate cluster):

1. Apply tie-break order from `consolidation-rules.md` § Duplicate detection + merging
2. Pick the primary finding (richest fix description; most-authoritative skill; most-recent)
3. Build the consolidated finding object with `sources: []` listing every original
4. Severity = worst-case across the cluster

### Step 6: Aggregate verdict

**Map each captured `source_verdict` to canonical; SKIP partial or null sources.** For every entry in Step 2's `report_verdicts` array (skip entries where `source_verdict` is `null` — that source emits no top-level verdict): look up `(source_skill, source_verdict)` in `severity-mapping.md` § Verdict vocabulary mapping and assign `canonical_source_verdict` (PASS/NEEDS-WORK/BLOCK/BLOCK_OVERRIDDEN). A non-Thorough partial-state string (`"N/A (quick depth …)"`, `"PARTIAL — <depth> depth"`, `AUDIT_INCOMPLETE`) maps to SKIP per that section — exclude it from the aggregation below, same as a `null` source_verdict (see the ND-0716 note below for a partial signal that is NOT in the verdict string). This is the step that actually makes "any source audit's canonical verdict == BLOCK" have an input — without it the rule below is unreachable.

Then, per `consolidation-rules.md` § Verdict aggregation:

```
if any canonical_source_verdict == BLOCK_OVERRIDDEN:
    consolidated_verdict = NEEDS-WORK
    consolidated_verdict_flag = "block_overridden_at_source"
elif any canonical_source_verdict == BLOCK or any consolidated finding has canonical_severity == P0 → BLOCK
elif any consolidated finding has canonical_severity == P1 or any canonical_source_verdict == NEEDS-WORK → NEEDS-WORK
else → PASS
```

This is the same algorithm as `consolidation-rules.md` § Verdict aggregation (that file is normative if this ever drifts) — restated here with the explicit `canonical_source_verdict` input wired in, so a source like `v-audit-analytics` reporting `analytics_health: UNRELIABLE` (which per severity-mapping.md fires on a low `overall_score` alone, with zero P0 findings) still forces the consolidated verdict to BLOCK.

If any source had `BLOCK_OVERRIDDEN`, include the operator-override callout in the consolidated report (treat as NEEDS-WORK with a flag, not BLOCK).

**ND-0716 note — the partial signal is not always in the verdict string.** `v-audit-growth` emits a real `growth_readiness` value in every mode and marks shallowness via a separate top-level `"partial": true` boolean. In the Step 6 mapping above, check the source JSON for `"partial": true` (or an equivalent top-level partial/incomplete boolean) and map that source's verdict to SKIP too; a Quick-depth `NOT READY` from one launched dimension must never flip the consolidated sweep to a full-confidence BLOCK (nor a partial READY to a clean PASS).

### Step 7: Build consolidated prompt pack (MUST USE SUBPROCESS)

Pre-dispatch shell setup (run before dispatching the writer subprocess):

**`/v` first-line requirement:** every pack file (the `<theme>.txt` / `w<N>-*.txt` packs, excluding `00-README.md`) MUST start on line 1 with `/v ` (the orchestrator routing prefix). Files that do not start with `/v ` are not detected as packs by `run-v-packs` and are rejected by the self-validate in `v-runnable-pack-convention.md` § Self-validate. The dispatched subagent must produce paste-ready files: operator copy-pastes the entire file content into a fresh `/v` session — or hands the whole dir to `run-v-packs` — with zero edits required.


```bash
PROMPT_DIR=".v-prompt-packs/v-audit-consolidate-$(date +%m-%d)"
# Reuse THIS exact $PROMPT_DIR value in every later step (Step 8 self-validate, Step 9 report,
# Step 10 summary) — never recompute $(date +%m-%d) in a later Bash call: a session crossing
# midnight would fork the path and validate/report a directory the packs aren't in.

# Idempotent re-run: archive any prior pack, then create the active dir.
# Per `_v-audit.md` § Step 3: Prompt Generation Contract — see the Pre-dispatch shell block.
# Without this, fewer-or-renamed packs on re-run leave stale w<N>-*.txt orphaned;
# the self-validate / run-v-packs would then see (and run) packs from a prior consolidation.
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

Per `_v-audit.md` § Step 3: Prompt Generation Contract. **The main skill computes the wave assignment (7a–7c) itself** (per `v-runnable-pack-convention.md` § Wave assignment — wave assignment is never delegated), then dispatches a `claude -p` writer subprocess (at the operator's resolved model `$AUDIT_MODEL` — NOT the Agent tool) to WRITE the files, passing: the consolidated findings, the computed per-finding→pack→wave assignment, and sections 7d (per-pack format) + 7e (README) below verbatim. Mechanism + writer-scope contract per `references/subprocess-dispatch.md` § Step 7. Step 8's self-validate is the acceptance check on its output.

**Skip Step 7-8 entirely** when the verdict is PASS (no findings to fix) — no prompt pack needed.

#### 7a. Assign waves (per `v-runnable-pack-convention.md` § Wave assignment)

The deduped consolidated findings are the **work items**. The main skill (not the subagent) partitions them
into waves with the convention's algorithm — file-set per finding → conflict edges (file intersection) →
dependency edges → disjoint-files-share-a-wave. Concretely for consolidated findings:

1. **File set per finding** = its `file_path` + every entry in `also_affects` + any test/config it implies.
2. **Most findings touch disjoint files → wave 0** (no prefix, all parallel). This is the common case.
3. **Same file, DIFFERENT remedy → different waves.** Dedup (Steps 4–5) already merged same-file+same-fix
   into one finding; the remaining same-file pairs are genuine conflicts and MUST land in different waves
   (`w1-`, `w2-`, …) — never the same wave. This is the invariant that makes `run-v-packs` parallel-safe.
4. **Dependency edge (per convention § Wave assignment item 3):** finding A → B when B's fix consumes A's
   output (e.g. a fix that patches a shared type/contract before the findings that depend on the corrected
   shape, or a backend fix before the frontend finding that mirrors it). This is independent of the
   file-conflict edge above — two findings can have disjoint file sets and still carry a dependency edge.
   B's wave MUST be strictly after A's.
5. **Severity orders ties:** within the constraints above, schedule P0-bearing packs in the earliest waves.

#### 7b. Pack size + theme

Group a wave's co-scheduled findings into themed packs (`<theme>.txt` for wave 0; `w<N>-<theme>.txt`
otherwise), theme = dominant category. Cap each pack at ~15–25 findings (operators fatigue past that). If one
wave's themed pack would exceed the cap AND the findings are independent (disjoint files), split into two
packs IN THE SAME WAVE (still parallel-safe). Only push to a later wave when a real conflict/dependency edge
forces it.

#### 7c. Closing waves (per `v-runnable-pack-convention.md` § Closing waves)

After the last implementation wave, append the standard closing waves as the highest prefixes:
`w<N>-pre-flight.txt` + `w<N>-review.txt` (parallel, READ-ONLY), then `w<N+1>-hardening.txt` (sequential),
then `99-verify.txt` (final gate-runner, always last). For the review pack, defer to the project's
`.claude/agents/` matching the changed file types and always include an adversarial reviewer
(codex-adversarial-reviewer, fallback `superpowers:requesting-code-review`).

#### 7d. Per-pack format

Each pack file is the ENTIRE content the operator pastes into `/v` (or that `run-v-packs` runs). First
character `/`, no frontmatter, no commentary outside the prompt body, no `git commit`/`git push` — packs end
**"leave staged; do not commit"** (operator/orchestrator commits). The READ-ONLY verification packs omit even
that line.

**Security-bearing pack clause (per `v-runnable-pack-convention.md` § Security-bearing packs).** When a pack's
`## Files` touches request signing / HMAC / webhook or signature verification, credential/secret handling,
host/URL construction from variables, auth/authz decisions, or payment flows, that pack's body MUST additionally
inline: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer,
fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session."
This is in addition to, not a replacement for, the closing review wave (§ 7c) — it closes the gap while the
pack is staged and not yet through that wave.

Per `~/.claude/skills/references/v-runnable-pack-convention.md` § Pack body schema, every implementation pack's
body MUST carry these sections, in this order (literal H2 headings — a cold agent has ONLY this one file, never
the consolidated report or a sibling pack):

```
/v Fix consolidated audit findings: [theme] for [Project Name].

## Goal
Fix [N] consolidated audit findings in the [theme] area for [Project Name] — [1-3 sentence outcome tied to the verdict].

## Context
Read CLAUDE.md first for stack + conventions + quality gates.
Tech stack: [from orientation].

These findings were consolidated from N audit skills: [v-prelaunch-readiness, v-anti-template-gauntlet, v-check, ...]. Each finding was originally flagged by 1-3 audits; sources are listed inline.

### Finding 1: [CON-001] [Title] (P0)
**File:** path/to/file.tsx:42
**Also affects:** [other file:line if multi-file]
**Sources:** v-prelaunch-readiness (M-OG-001 / MUST-FIX), v-anti-template-gauntlet (OG-01 / CRITICAL)
**Problem:** [description from primary finding]

### Finding 2: ...

## Files
- path/to/file.tsx:42 — [what changes]
- [other file:line from "Also affects"] — [what changes]
(every file any finding above touches — REQUIRED, literal `## Files` heading; v-build's scope guard keys on it)

## Changes
### Fix 1: [CON-001] [Title]
[specific code changes from the primary finding's fix field]

### Fix 2: ...

## Acceptance criteria
- [ ] [Finding 1 fixed and verified via its verify command]
- [ ] [Finding 2 fixed and verified via its verify command]
- [ ] Full quality-gate suite passes

## Tests
- [TDD test to write per finding — only for backend logic; UI fixes can be test-after]

## Constraints
- Read CLAUDE.md first
- Tech stack: [from orientation]
- [any domain guardrail the findings imply]

## Dependencies
Wave [N]. Requires: [prior pack name(s), or "none"].

Run the project's quality gates:
- [test command from CLAUDE.md]
- [build command from CLAUDE.md]
- [lint command from CLAUDE.md]

Re-run the audits to confirm findings cleared:
- [list of source audit skill commands to re-run]

Leave all changes staged; do NOT commit (the operator/orchestrator owns commits).
```

#### 7e. README

Write `$PROMPT_DIR/00-README.md` (the Step 7 pre-dispatch value — do not recompute the date) with:
- Project name, consolidation date, source audit count, total consolidated findings
- Verdict (PASS / NEEDS-WORK / BLOCK)
- Dedup stats: "X duplicate clusters merged; Y unique findings remain"
- Source-skill provenance: list which audit skills contributed findings
- **How to run:** "`run-v-packs <this dir>` runs it end-to-end — packs in a wave run in parallel, a wave starts only after the prior wave completes; or paste a single pack into a fresh `/v` session."
- **Wave map:** `| Wave | Prefix | Parallel packs | Theme | Findings (P0/P1/P2/P3) | Sources | Touches files | Depends on |`
- Recommended fix order: P0-bearing waves first, then P1, then P2/P3
- Re-run guidance: which audit skills to re-run after the consolidated pack executes (to confirm findings cleared)

### Step 8: Self-validate the runnable tree

Run the self-validate from `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree: the structural check (every pack's first non-blank line is `/v…`, no YAML frontmatter, no bare `git commit`/`git push`, ≥10 lines, `00-README.md` present), THEN `run-v-packs "$PROJECT_ROOT/$PROMPT_DIR" --dry-run` to confirm the packs resolve to the waves you assigned and `99-verify` is listed last. Plus the two manual passes the shell can't do: (1) no two packs sharing the same wave prefix name the same target file; (2) implementation packs end "leave staged; do not commit", the READ-ONLY verification packs omit it. On failure, re-dispatch the writer subprocess once with the failure messages as context. On second failure, mark `prompt_pack: validation_failed` in the consolidated report.

(If `run-v-packs` is not on PATH, the structural check + the two manual passes are sufficient; note the missing dry-run cross-check in the report.)

### Step 9: Write consolidated report

```markdown
# CONSOLIDATED_AUDIT_REPORT_{session-id}
generated: [ISO timestamp]
project: [project name]
verdict: [PASS | NEEDS-WORK | BLOCK]

Generated by v-audit-consolidate

## Source audits

| Skill | Report | Date | Native verdict | Canonical verdict | Findings (raw) |
|---|---|---|---|---|---|
| v-prelaunch-readiness | PRELAUNCH_READINESS_REPORT_*.md | YYYY-MM-DD | NEEDS-WORK | NEEDS-WORK | 12 |
| v-anti-template-gauntlet | GAUNTLET_REPORT_*.md | YYYY-MM-DD | BLOCK | BLOCK | 15 |
| ... | | | | | |

## Verdict

**[PASS | NEEDS-WORK | BLOCK]** — [1-line rationale citing the worst signal]

## Consolidation stats

| Metric | Count |
|---|---|
| Source audits | N |
| Raw findings (before dedup) | N |
| Duplicate clusters merged | N |
| Unique consolidated findings | N |
| Stale-flagged findings | N |
| Severity-unmapped findings | N |
| Parse errors (see Parse warnings) | N |

## Parse warnings

[CONDITIONAL — only emit when Step 2 returned a non-empty `parse_errors` array; omit entirely when empty (the stats row above still shows 0). Render a `| Source report | Reason it could not be parsed |` table, one row per entry — these sources are UNDER-REPRESENTED in the findings below.]

## Findings by canonical severity

### P0 (Blocking) — [N findings]
[Per-finding entries with: id, title, file:line, also_affects, sources, fix]

### P1 (High) — [N findings]
...

### P2 (Medium) — [N findings]
...

### P3 (Low) — [N findings]
...

## Prompt pack

[CONDITIONAL — only emit this section when verdict != PASS]

Runnable wave tree: `.v-prompt-packs/v-audit-consolidate-<MM-DD>/`. Run it end-to-end with `run-v-packs .v-prompt-packs/v-audit-consolidate-<MM-DD>/` (parallel, isolated, walk away), or paste a single `w<N>-*.txt` pack into a fresh `/v` session.

Recommended order: see `.v-prompt-packs/v-audit-consolidate-<MM-DD>/00-README.md` § Wave map (the Step 7 `$PROMPT_DIR`).

**When verdict == PASS:** omit this section entirely. The report instead includes a one-line note: *"All audits clean; no fixes required."*

## Source-skill provenance

[Which audit skills contributed findings. Useful for re-run intelligence — when an operator re-runs ONE source audit, they can cross-reference here to know which consolidated findings might be affected.]

## Appendix: BLOCK_OVERRIDDEN sources

[CONDITIONAL — only emit when a source audit's verdict was BLOCK_OVERRIDDEN. Per `references/consolidation-rules.md` § Verdict aggregation, emit its ⚠️ operator-override callout verbatim for EACH such source, and list that source's findings HERE — never mixed into the main backlog (Gotcha 3: mixing them breaks priority semantics). Omit the section when no source was overridden.]
```

### Step 10: Present summary

Console output:
- Source audits consolidated (count + skill names)
- Parse warnings, when any: "N source report(s) could not be parsed: {paths} — findings from these are NOT included" (omit the line when zero)
- Dedup stats (X clusters merged into Y unique findings)
- Verdict (PASS / NEEDS-WORK / BLOCK with reason)
- Top 3 P0 findings (file:line + 1-line title)
- Prompt pack location
- Recommended next: `run-v-packs .v-prompt-packs/v-audit-consolidate-<MM-DD>/` (parallel, walk away), or paste the highest-priority pack into a fresh `/v`

## Cross-references

- Severity mapping (per-skill native → canonical P-tier): `references/severity-mapping.md`
- Consolidation rules (fingerprint, dedup, verdict aggregation): `references/consolidation-rules.md`
- Fork-compatible `claude -p` dispatch for Steps 2/7 (mechanism, validation, retry rules): `references/subprocess-dispatch.md`
- Output format: `~/.claude/skills/references/v-audit-output-conventions.md`
- Runnable wave-pack form emitted (wave assignment, closing waves, self-validate — shared with `/v-prompt-pack-generate`): `~/.claude/skills/references/v-runnable-pack-convention.md`
- Dated-folder naming (`.v-prompt-packs/<skill>-<MM-DD>/`, same-day re-run archive): `~/.claude/skills/references/v-core-prompt-pack.md`
- Source audit skills: `v-prelaunch-readiness`, `v-anti-template-gauntlet`, `v-audit-{admin,analytics,growth,messaging,sales-pricing,seo}`, `v-check`, `v-pre-flight`, `v-verify-done`

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Consolidated severity inconsistent — same finding rated P1 in one source, P0 in another | Severity vocabulary not normalized | Apply `references/severity-mapping.md` BEFORE merging; never carry source-specific severity through |
| 2 | Duplicate findings shipped because fingerprint missed near-duplicates | Fingerprint algorithm too strict (whole-message hash) | Use `sha1(file_path:line:category_slug)` — message variation between sources doesn't break dedup |
| 3 | BLOCK_OVERRIDDEN findings appear in main backlog | Carve-out rule skipped | BLOCK_OVERRIDDEN findings MUST go to a separate appendix; mixing them with non-overridden findings breaks priority semantics |
| 4 | Cross-skill duplicates not detected because sources used different ID prefixes | ID prefix dictionary out of date | Maintain mapping of source skill → ID prefix in `references/severity-mapping.md`; new audit skills update this |
| 5 | Consolidated verdict (PASS/NEEDS-WORK/BLOCK) not reproducible | Aggregation rule not deterministic | Verdict logic (normative: `references/consolidation-rules.md` § Verdict aggregation — apply in order): BLOCK_OVERRIDDEN source → NEEDS-WORK + flag (checked FIRST, wins even over a consolidated P0); any `canonical_source_verdict == BLOCK` or any consolidated P0 → BLOCK; any P1 or any source NEEDS-WORK → NEEDS-WORK; else PASS. Per-source verdicts ARE an input — a score-only `analytics_health: UNRELIABLE` forces BLOCK with zero P0s; dedup/severity mapping applies to the consolidated finding set |
| 6 | `run-v-packs` hits a merge conflict / clobber because two parallel packs edited the same file | Two findings touching the SAME file but with DIFFERENT remedies were put in the same wave | Per `v-runnable-pack-convention.md` § Wave assignment: same-file/different-fix findings are NOT duplicates but DO conflict — they must land in different waves (`w1-`/`w2-`). The Step 8 `run-v-packs --dry-run` + manual parallel-safety pass catches this before handoff |
| 7 | A consolidated pack contains a `git commit`/`git push` line → the run-v-packs self-validate flags it, or the operator's no-auto-commit policy is violated | Carried the legacy NN-*.md template's commit footer into the runnable form | Implementation packs end "leave staged; do not commit"; the operator/orchestrator owns commits (the READ-ONLY verification packs omit even that line) |

## Idempotency

Re-running on the same project produces a fresh consolidated report + prompt pack with the latest source audits. The `CON-NNN` consolidated finding IDs are NOT cross-run-stable (each run renumbers); operators wanting cross-run stability should track findings via the source audits' own IDs. The fingerprint IS stable — same `file:line:category` always hashes the same way.

## When to revisit / re-run

- After re-running any single source audit → re-run consolidate to refresh
- After implementing a session from the consolidated prompt pack → re-run consolidate to confirm findings cleared (the cleared findings won't appear in the new consolidation; new findings introduced by the fix WILL appear)
- Before any actual launch → run consolidate once with `--window=1` to capture only same-day audits and produce the launch-day GO/NO-GO consolidated view
