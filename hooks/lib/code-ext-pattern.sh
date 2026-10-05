#!/usr/bin/env bash
# code-ext-pattern.sh — SINGLE SOURCE OF TRUTH for "which changed paths count as code /
# executable config" across the gauntlet gates (check-review-artifact.sh Stop gate and
# enforce-pre-commit-gates.sh commit gate). Mirrors the ui-path-pattern.sh shared-lib
# convention (W49-M1): drift between per-file copies = silent enforcement gap.
#
# ORCHFIX-C (forensics 2026-07-02, a production repo): the two consumers had ALREADY drifted
# (commit gate carried 10 extensions, Stop gate 40) and BOTH omitted executable config —
# a .github/workflows/static-analysis.yml edit shipped to main in 131s with ZERO gates
# because every code-change signal classified .yml as non-code and the model's prose
# self-exemption agreed. Executable config IS code: it runs CI, gates deploys, drives git
# hooks, and changes dependency surfaces (lockfiles).
#
# CODE_EXT_EXEMPT exists because the orchestrator's own telemetry artifacts live in repo
# roots and would otherwise match the new yaml/json extensions — a logging-only or
# catch-up session must NOT be classified as code-shipping by its own SESSION_LOG /
# OP_TELEMETRY files, and nothing under .v/ is product code. Every consumer MUST pair
# the two:  ... | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT"
#
# .v-prompt-packs/ (forensics 2026-07-06): audit/pack-producing skills
# (v-audit-code, v-audit-seo, … ~23 producers) write their fix-packs — including an
# executable validate.sh + optional .json manifest — into .v-prompt-packs/<skill>-<date>/.
# Those are DELIVERABLES, not product code. Without this exemption, a read-only audit's own
# validate.sh matched CODE_EXT_PATTERN → CODE_CHANGED=1, which (a) fired the LAYER-2
# abandonment-with-code block and (b) skipped the whole CODE_CHANGED=0-gated report-only
# escape registry — so the audit-family escape (which DOES list v-audit-code) never ran and
# the session was forced through the full pre-flight/review/verify gauntlet it can't satisfy.
# Exempting the pack dir (parallel to .v/) lets the audit's own deliverables NOT count as a
# session code change. A session that ALSO touches real source still trips the gate on it.
#
# UPPER_SNAKE_(AUDIT|REPORT)_*.json covers the audit-skill documentary reports
# (ADMIN_AUDIT_REPORT_*, SEO_AUDIT_*, BUG_HUNT_REPORT_*, …) that _v-artifact-formats.md
# classifies as non-gating — a read-only audit session must not be classified as
# code-shipping by its own report JSON. Per-line filtering means a session that ALSO
# touched real source still trips the gate on that source file.
#
# .audit<N>/ (forensics 2026-09-08): the per-dimension audit skills collect each
# dispatched dimension's JSON into an ad-hoc scratch dir ($DIM_OUT) that the SKILL never pinned —
# runs landed on .audit3/, .audit4/. Two of those scratch files (.audit4/dim7.json, dim9.json)
# matched CODE_EXT_PATTERN, set CODE_CHANGED=1, and disarmed the very audit-family escape built for
# that session type — the IDENTICAL failure .v-prompt-packs/ was added to fix, one directory over.
# It also made the block UNRESOLVABLE: HANDOFF (the block message's own option b) tripped the Bug 6 /
# Phase 2 shipped-code refusal, and the survival gate false-fired because the repo's blanket `*`
# .gitignore hides the scratch files from git while they sit on disk. v-audit-seo is pinned to
# .v/audit-scratch/<sid>/ (already exempt) so new runs never land here; this entry covers the dirs
# already written. NB this is the ONE sanctioned scratch location outside .v/ — root-level scratch
# stays code on purpose (see the analytics-qa-taxonomy pair in the bite).
#
# .seo/ is deliberately NOT exempt (2026-10-01 review panel): its CSV/MD data never
# matched CODE_EXT_PATTERN, so an exemption would only have exempted scripts placed there — a review
# bypass at any depth. Session helper scripts belong under .v/, which is already exempt.
#
# Bite: hooks/code-ext-config-gate-test.sh (parity across consumers + behavior + red-vs-backup).
CODE_EXT_PATTERN='\.(php|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hh|hpp|cs|scala|ex|exs|sh|bash|zsh|sql|m|mm|dart|lua|pl|pm|r|clj|cljs|erl|hs|yml|yaml|json|neon|toml|lock)$|(^|/)Dockerfile[^/]*$|(^|/)Makefile$|(^|/)\.husky/[^/.]+$|(^|/)\.github/workflows/[^/]+$'
CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
export CODE_EXT_PATTERN CODE_EXT_EXEMPT
