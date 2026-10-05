# Error Handling & Cost Awareness (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Cost Awareness

Skills that dispatch multiple subagents or read many files should estimate their resource usage. Include in the contract block when applicable:

| Field | Format | Example |
|-------|--------|---------|
| `estimated_tokens` | range | `50k-200k` |
| `estimated_duration` | range | `5-30 min` |
| `subagent_count` | number | `18` |

This is advisory — users should know that running all 7 audit skills via the ecosystem review runner is significantly more expensive than `/v-check` (single-pass). Skills SHOULD warn before starting operations estimated at >100k tokens.

## Audit Skill Progress Reporting (Mandatory)

Any skill that runs longer than 2 minutes MUST report progress using the task-list tools. Create the step list at the start with one `TaskCreate` per major step, then transition status with `TaskUpdate` as each step completes. Additionally, print a one-line console message at each step transition (e.g., `"Launching 7 audits in parallel..."`, `"6/7 complete. Consolidating..."`, `"Score: 72/100. Writing report..."`).

> **Tool rename (2026-07-05):** the harness no longer exposes a `TodoWrite` tool — `TaskCreate`/`TaskUpdate` replaced it. When granting tools in frontmatter, grant `TaskCreate, TaskUpdate`; a `TodoWrite` grant is dead and a `TodoWrite(...)` call is a no-op. Skill prose that still says "TodoWrite initialization" means this section (kept for anchor stability — see `_v-audit.md` § TodoWrite Progress Reporting).

This is the user's only visibility into what's happening. A skill that runs silently for 15 minutes with no output is broken UX regardless of whether the final output is correct.

## Parallel Subagent Error Handling Contract

Any skill that dispatches multiple parallel subagents (e.g., v-audit-growth, v-audit-seo, v-audit-analytics) MUST implement this error handling pattern:

| Scenario | Action |
|----------|--------|
| **Subagent crash/timeout** (dispatch ceiling `V_DISPATCH_TIMEOUT_SEC`, default 900s per `v-dispatch-subagent.sh`) | Log `audit_[N]_status: failed, reason: [error]`. Score as `null` with `"status": "failed"`. Do NOT fabricate findings. |
| **Partial results** | Accept what was returned, mark `"status": "partial"`. Include partial findings in consolidation. |
| **Score calculation with failures** | Exclude failed audits from the average, redistribute weight proportionally. Note excluded audits in the report. |
| **Minimum viable threshold** | If >50% of audits/dimensions fail, abort consolidation and report `"AUDIT_INCOMPLETE"`. Do not produce a misleading score from insufficient data. **This threshold is universal:** all audit skills (v-check, v-audit-growth, v-audit-analytics, v-audit-messaging, v-audit-sales-pricing, v-audit-seo, v-audit-admin) use the same >50% abort rule. Calculate as `ceil(total_dimensions / 2) + 1` failures required to abort. |
| **Weight redistribution on partial failure** | When computing scores with failed dimensions, **drop** the failed dimensions from the denominator entirely (do not redistribute weight). Report: `"score_basis": "N of M dimensions completed"`. This prevents failed dimensions from inflating remaining scores. |

Skills MUST NOT silently omit failed dimensions or hang waiting for crashed subagents.

## General Error Recovery Protocol

All v-* skills follow this recovery protocol when a step fails:

1. **Command failure (non-zero exit):** Log the error, assess whether the step is skippable. If the step is a quality gate (tests, build, lint), the failure is blocking — report it in the artifact and stop. If the step is advisory (bundle size, optional audit), log it and continue.
2. **Sub-skill invocation failure:** If a Skill tool invocation returns an error, retry once. If it fails again, log the failure and continue with degraded output. Never silently skip a sub-skill.
3. **File not found / missing artifact:** When a skill expects an artifact from a prior step (e.g., PLAN_*.md, PRE_FLIGHT_REPORT_*.md) and it doesn't exist, report the missing artifact explicitly. Do not fabricate data or skip validation.
4. **Worktree directory gone:** If the worktree directory was deleted by another session, stop immediately. Do not fall back to running commands in the main directory.
5. **Network/tool unavailable:** If an external tool (npm, composer, codex) is unavailable, use the graceful degradation path documented in the skill. Never treat "tool not found" as "step passed."
