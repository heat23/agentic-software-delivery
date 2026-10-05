# Token Budget Reference

_Last reviewed: 2026-08-03 — full reconciliation sweep. Two skills (`v-check`, `v`) each had TWO
rows with conflicting numbers, and 15 of 52 rows disagreed with their own SKILL.md contract block
(10 were never-refined `Auto-added 2026-05 | 10k-50k` placeholders). All 52 now match the contract
block, which this file's own "Source of Truth" section already declared authoritative. Verify with
the check in that section before editing a row by hand. Prior: 2026-08-02 (v-launch-channels row
reconciled; stamp had drifted behind the file's own edit history). Earlier: 2026-07-05 sweep._

Per-workflow estimated token consumption for planning and cost awareness. These are advisory estimates based on typical usage — actual consumption varies with project size, complexity, and depth selection. The contract block in each SKILL.md is the authoritative source for individual skill estimates; this document summarizes them and provides workflow chain budgets.

## Individual Skill Estimates

| Skill | Estimated Tokens | Estimated Duration | Notes |
|-------|-----------------|-------------------|-------|
| v (orchestrator) | 60k-400k | 15-60 min | Full orchestrated session; reconciled 2026-08-03 to v/SKILL.md's contract block. Routing overhead ALONE is ~5k-15k / 1-3 min — that sub-metric is not the session cost |
| v-plan | 10k-30k | 2-8 min | Varies by route (1-6) |
| v-new-feature | 12k-35k | 3-8 min | Planning, not implementation (numbers reconciled 2026-08-03 from the skill contract block) |
| v-tdd | 8k-20k | 2-5 min | Test skeleton creation |
| v-build | 30k-100k | 5-30 min | Depends on plan item count |
| v-scaffold | 5k-15k | 1-3 min | Per-component generation |
| v-polish | 10k-30k | 2-8 min | Scoped to changed files |
| v-pre-flight | 8k-25k | 2-8 min | Gate execution + report |
| v-verify-done | 10k-30k | 3-10 min | Convention checks + agent review dispatch |
| v-check | 30k-100k | 5-20 min | Checklist generation; range depends on depth and scope (numbers reconciled 2026-08-03 from the skill contract block) |
| v-audit-full | ~~30k-300k~~ | — | **DEPRECATED** — use ecosystem review runner or specialist audits directly |
| v-audit-growth | 50k-130k | 8-20 min | 4 parallel subagents |
| v-audit-seo | 60k-180k | 10-30 min | 8 dimensions (numbers reconciled 2026-08-03 from the skill contract block) |
| v-audit-code | 30k-100k | 5-25 min | Whole-repo production-readiness + modernization pass |
| v-audit-analytics | 60k-150k | 3-20 min | 6 audit tracks |
| v-audit-messaging | 35k-180k | 3-20 min | 7 surfaces; depth-dependent (Quick ~35-60k, Thorough ~100-180k) |
| v-audit-sales-pricing | 90k-220k | 12-35 min | 10 dimensions |
| v-audit-admin | 20k-80k | 3-20 min | 6 audit domains |
| v-handoff | 5k-15k | 1-3 min | State capture |
| v-merge-all | 30k-120k | 5-25 min | Depends on branch count |
| v-docs | 15k-50k | 3-15 min | Documentation generation |
| v-self-audit | 60k-200k | 15-45 min | 6-stage meta-audit of /v; sub-agent dispatches; read-only |
| v-forensics | 100k-400k | 15-60 min | Read-only multi-session /v orchestration post-mortem (git+artifact ground truth) |
| v-forensics-pack-runner | 80k-300k | 10-45 min | Read-only run-v-packs/merge-drain landing-layer post-mortem after a fleet batch |
| v-help | 3k-8k | <1 min | Catalog display |
| v-ci-fix | 10k-30k | 2-8 min | CI error diagnosis |
| v-content-create | 20k-80k | 5-20 min | Per content piece; brief_type article/aeo (20k-60k, 5-15 min) or comparison (30k-80k, 10-20 min — v-comparison-page merged 2026-07-05) or AEO (30k-80k — v-aeo-content merged 2026-07-05) |
| v-differentiate | 15k-40k | 3-10 min | reconciled 2026-08-03 from the skill contract block |
| v-content-ops | 20k-80k | 5-20 min | Calendar + brief generation |
| v-traffic | 15k-40k | 5-20 min | Traffic wizard (chains audit-seo + content-ops) |
| v-launch | 20k-60k | 10-30 min | Launch wizard (chains prelaunch-readiness + legal-docs + launch-channels) |
| v-interactive-showcase | 15k-40k | 3-10 min | HTML showcase generation |
| v-discover-features | 60k-150k | 10-25 min | Feature discovery audit |
| v-legal-docs-generate | 40k-100k | 8-20 min | Legal document generation |
| v-maintenance | 10k-30k | 2-8 min | Reduced ceremony |
| v-marketing-design | 25k-70k | 3-10 min | Marketing asset design (numbers reconciled 2026-08-03 from the skill contract block) |
| v-setup-project | 8k-20k | 2-5 min | Project setup and hook installation |
| v-activation-funnel-design | 30k-70k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-anti-template-gauntlet | 40k-95k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-audit-consolidate | 20k-60k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-audit-orchestrator | 5k-15k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-beta-program | 25k-50k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-bug-hunt | 50k-200k | 12-45 min | Adversarial read-only audit for one target subsystem — `bugs` lens (60k-200k, 15-45 min, defects) or `boundaries` lens (50k-150k, 12-35 min, boundary conditions — v-edge-hunt merged in 2026-07-05) |
| v-build-narrow | 5k-25k | 1-5 min | reconciled 2026-08-03 from the skill contract block |
| v-illustration-system | 25k-55k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-launch-channels | 30k-80k | 3-15 min | Reconciled 2026-08-02 to match SKILL contract (sonnet; up to 6 channels; 3-direction variance step + web calibration on the primary channel) |
| v-next | 20k-60k | 5-15 min | Portfolio cadence brain; read-only cross-project scan, capped at 20 projects |
| v-prelaunch-readiness | 40k-90k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-prod-triage | 20k-60k | 5-20 min | Production runtime health triage; read-only (add 5-15 min if restore-drill mode confirmed) |
| v-prompt-pack-generate | 20k-60k | 5-20 min | Codebase-grounding pass + wave/pack tree generation |
| v-pricing-design | 40k-90k | 2-15 min | reconciled 2026-08-03 from the skill contract block |
| v-session-log | 3k-10k | <1 min | reconciled 2026-08-03 from the skill contract block |
| v-skill-reviewer | 8k-40k | 2-12 min | Report-only v-skill ecosystem review |

## Workflow Chain Budgets

| Workflow | Typical Chain | Estimated Total | Notes |
|----------|--------------|----------------|-------|
| **Small feature** (1-3 files) | v → v-plan → v-build → v-pre-flight → v-verify-done | 70k-200k | No worktree, no polish |
| **Medium feature** (4-10 files) | v → v-plan → v-tdd → v-build → v-polish → v-pre-flight → v-verify-done → v-merge-all | 120k-300k | Worktree + polish + merge |
| **Large feature** (10+ files) | v → v-plan → v-tdd → v-build → v-polish → v-check (scoped) → v-pre-flight → v-verify-done → v-merge-all | 160k-400k | Full chain with scoped audit |
| **Broad audit** | v → v-check (standalone) | 35k-115k | Single-pass |
| **Full audit** | v → ecosystem review runner (all 7 skills) | 350k-900k | 7 sequential skill runs (v-audit-full is DEPRECATED) |
| **Growth audit** | v → v-audit-growth | 55k-145k | 4 parallel dispatches |
| **Launch** | v → v-check (invokes v-pre-flight) | 25k-70k | Assumes gates already passed |

## Budget Awareness Rule

Skills estimated at >100k tokens SHOULD warn before starting: "This operation is estimated at [range] tokens. Proceed?"

This is advisory — the orchestrator may skip the warning when V_DEPTH >= 1 and the user already approved the parent workflow.

## Source of Truth

The `estimated_tokens` field in each skill's contract block is authoritative. This reference document is a summary for cross-skill planning. If a discrepancy exists, the contract block wins.
