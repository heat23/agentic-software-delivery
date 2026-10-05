# Execution Paths & Build Workflows Reference

## Build Path

`v` → `v-new-feature` (medium/large) → `v-tdd` (backend logic) → `v-build` → `v-polish` (UI changed) → `interface-design:critique` (new UI) → `v-check` (scoped, medium/large) → `v-pre-flight` → agent review → `v-verify-done`

## Launch Path

`v` → `v-pre-flight` → ecosystem review runner (all 7 specialist audit skills). `v-check` remains for launch-day execution (T-0/T+1/T+7 procedure) after audits clear.

## Quick Validation Path

`v` → `v-pre-flight` → `v-check` (Quick) — 11-domain code audit in ~5 min for post-fix re-validation.

## Review Path

`v` → `v-check` → `v-audit-code` (absorbed `/v-refactor` 2026-07-06) only when structural issues justify it

## Maintenance Path

`v` → `v-maintenance` → targeted tests → `v-pre-flight` (changed-only when supported) → agent review → `v-verify-done`

## Planning Path

`v` → `v-plan`, then recommend `v-build` or a relevant growth skill
- **Interactive** (`HEADLESS_MODE=0`): `v` → `v-plan`, then recommend `v-build` or a relevant growth skill to the user
- **Headless** (`HEADLESS_MODE=1`): `v` → `v-plan` → `v-build` (auto-chain; no human approval gate)

## Consolidation Path

`v` → `v-merge-all` — after parallel sessions complete, merge all worktrees/branches into main and push to origin
