#!/usr/bin/env bash
# artifact-prefix-registry.sh — SINGLE SOURCE for "the set of per-session artifact filename
# prefixes" (P3 class fix, 2026-07-03).
#
# WHY: the ecosystem had (at least) two independent copies of this set — the session-writes
# attribution filter (hooks/lib/session-writes.sh awk alternation) and the producer-side skip in
# hooks/track-session-writes.sh (case-glob) — and they had ALREADY drifted from each other and
# from reality (both missed QA_REPORT, IMPACT_MAP, TRIVIAL_PASS, SESSION_LOG_MISSING, and the
# brand-new SID_COLLISION). This is the _FND_EXCLUDE_RE class: every copy rots independently and
# the stalest copy silently wins. Consumers source THIS file; parity is pinned by
# hooks/p3-artifact-prefix-registry-test.sh.
#
# LIMIT OF THAT NET (measured 2026-08-29, close-out audit): it catches a new writer only when the
# writer's literal `<PREFIX>_<uuid>` shape is detectable in source. A writer that builds the path
# through a VARIABLE — e.g. hooks/lib/stop-rearm.sh's `> "$_sr_root/.v/artifacts/STOP_LIVELOCK_${_sid}.md"`
# — is invisible to it. Proof: STOP_REARM_ESCAPE has been written by that same file for months and
# has never appeared in this registry, and the net never flagged it. STOP_LIVELOCK (added 2026-08-29)
# was likewise registered by hand, not by the net. So: adding a prefix here is still MANDATORY, and
# you cannot rely on the harness to remind you.
#
# CONTRACT: a per-session artifact is `<PREFIX>_<full-uuid>[.<sub>].(md|yaml|yml|json)` (basename-
# anchored). WINNER_ELECTION_<slug>.md is deliberately NOT here — it is slug-suffixed and written
# only under .v/artifacts (excluded by path, not by prefix).
#
# When you add a NEW artifact prefix anywhere in the ecosystem: add it HERE, once.

# Pipe-alternation, safe to embed in ERE and awk dynamic regexes. Order-insensitive.
# 2026-07-06 completeness fix (p3 T2 drift): + the REPORT-ONLY completion artifacts the skill
# ecosystem grew without registry rows — the design family (ACTIVATION_FUNNEL / PRICING_STRATEGY /
# BETA_PROGRAM / ILLUSTRATION_SYSTEM, per check-review-artifact.sh's report-only accept list),
# SKILL_REVIEW_REPORT (v-skill-reviewer), CONSOLIDATED_AUDIT_REPORT (v-audit-consolidate),
# SELF_AUDIT_SUMMARY (v-self-audit), LEGAL_AUDIT (v-legal-docs-generate), DIFFERENTIATION_BRIEF
# (v-differentiate), TRAFFIC_PLAN (v-traffic), PROD_TRIAGE, and V_NEXT_REPORT. All are per-session
# `<PREFIX>_<uuid>.md` report artifacts — same classification as the sibling AUDIT_REPORT /
# GAUNTLET_REPORT report-only rows.
V_ARTIFACT_PREFIX_ALTERNATION='AGENT_REVIEW|AGENT_REVIEW_STAGED|AGENT_REVIEW_ADDENDUM|PRE_FLIGHT_REPORT|PRE_FLIGHT_ADDENDUM|VERIFY_DONE_REPORT|UX_CRITIQUE|HANDOFF|WORKTREE_HANDOFF|CYCLE_CAP_HANDOFF|BLOCKED|IMPLEMENTATION_REPORT|SESSION_LOG|SESSION_LOG_MISSING|SESSION_LOG_FAILED|SESSION_LOG_INVALID|SESSION_LOG_INCOMPLETE|SESSION_LOG_PENDING|PROGRESS_NOTE|PLAN|AUDIT_REPORT|REFACTOR_PLAN|POLISH_PLAN|BUILD_BLOCKER|LAUNCH_CHECKLIST|LAUNCH_PLAN|GAUNTLET_REPORT|GAUNTLET_SKIPPED|GAUNTLET_OWED|GAUNTLET_STALE|ADMIN_AUDIT_REPORT|QA_REPORT|QA_REMEDIATION|QA_ADDENDUM|IMPACT_MAP|TRIVIAL_PASS|PLANNING_PASS|WORKFLOW_VERIFICATION|WORKFLOW_VERIFICATION_ADDENDUM|SUCCESS_CRITERIA|WORKFLOW_BLAST_RADIUS|SID_COLLISION|STOP_LIVELOCK|BITE_LEDGER|ABANDON_SUSPECT|BILLING_REVIEWED|REVIEW_DEBT|FND3_ORPHAN_ESCAPE|ACTIVATION_FUNNEL|PRICING_STRATEGY|BETA_PROGRAM|ILLUSTRATION_SYSTEM|SKILL_REVIEW_REPORT|CONSOLIDATED_AUDIT_REPORT|SELF_AUDIT_SUMMARY|LEGAL_AUDIT|DIFFERENTIATION_BRIEF|TRAFFIC_PLAN|PROD_TRIAGE|V_NEXT_REPORT'

# Full basename-anchored ERE for a per-session artifact path (the shape both classifiers key on).
V_ARTIFACT_PREFIX_PATH_RE="(^|/)(${V_ARTIFACT_PREFIX_ALTERNATION})_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.[a-z]+)?\.(md|yaml|yml|json)$"

# is_session_artifact_path <path> → rc 0 when the path is a per-session artifact.
is_session_artifact_path() {
  printf '%s' "${1:-}" | grep -qE "$V_ARTIFACT_PREFIX_PATH_RE"
}
