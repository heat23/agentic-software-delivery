#!/usr/bin/env bash
# v-artifact-skeleton.sh — emit a canonical, validator-passing skeleton for the two artifacts
# whose STRUCTURE (not substance) repeatedly bounced the Stop hook and forced re-format loops
# (several production sessions; observed again W4-416/417/418 patching IMPACT_MAP/
# QA_REPORT after self-check failures). The agent fills the SUBSTANCE; the structural anchors —
# the bare `subsystems:` + line-start subsystem keys for IMPACT_MAP, and `Model:` / `## QA
# Acceptance` / col-0 `verdict:` for QA_REPORT — are emitted here so they can never drift.
#
# These skeletons are kept byte-for-structure in sync with hooks/lib/validation.sh
# (validate_impact_map_semantics / validate_qa_report_structure) via v-artifact-skeleton-test.sh,
# which round-trips the output through those exact validators.
#
# Usage:
#   v-artifact-skeleton.sh --type impact_map|qa_report --sid <sid> [--out FILE]
#   bash v-artifact-skeleton.sh --type impact_map --sid "$SID" > "IMPACT_MAP_${SID}.md"
set -u

TYPE="" SID="" OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --type) TYPE="${2:-}"; shift 2 || exit 2 ;;
    --sid)  SID="${2:-}";  shift 2 || exit 2 ;;
    --out)  OUT="${2:-}";  shift 2 || exit 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$TYPE" ] && [ -n "$SID" ] || { echo "usage: v-artifact-skeleton.sh --type impact_map|qa_report|ux_critique|workflow_verification|verify_done_report --sid <sid> [--out FILE]" >&2; exit 2; }

emit_impact_map() {
  cat <<EOF
# Impact Map — ${SID}

> Fill the SUBSTANCE only. Do NOT edit the \`subsystems:\` line or the subsystem keys — the Stop
> hook (validate_impact_map_semantics) anchors on them at line start. A genuinely isolated change
> is all \`impacted: no\` WITH a one-line reason each (always satisfiable).

impact_map:
  session_id: "${SID}"
  classification: "<feature-tiny|feature-small|feature-medium|feature-large|bug-fix>"
  change_summary: "<one line: what changed and why>"
  subsystems:
    functional_flow:     { impacted: no, reason: "<consumers + how verified, or why not impacted>" }
    reporting_metrics:   { impacted: no, reason: "<metrics/reports/session-log readers, or why not>" }
    admin:               { impacted: no, reason: "<admin views/actions, or why not>" }
    async_jobs:          { impacted: no, reason: "<jobs/listeners/queues, or why not>" }
    notification_emails: { impacted: no, reason: "<mail/notifications, or why not>" }
    cache_invalidation:  { impacted: no, reason: "<cache keys/locks to bust, or why not>" }
    db_integrity:        { impacted: no, reason: "<FKs/uniques/counters/backfill, or why not>" }
    api_contract:        { impacted: no, reason: "<API resources/webhooks/consumers, or why not>" }
    authorization:       { impacted: no, reason: "<policies/gates/field exposure, or why not>" }
  reviewer_scope: []   # consumer files NOT in the diff a reviewer MUST check (downstream readers)
EOF
}

emit_qa_report() {
  cat <<EOF
Model: sonnet

## QA Acceptance — ${SID}

verdict: fail
iteration: 0/3
original_request: "<the user's ORIGINAL task, quoted verbatim>"
acceptance: "<accept|partial|reject> — <does the delivery satisfy the actual intent?>"

## Findings (current iteration)
#### QA-001 | <domain> | <critical|high|medium|low> | <file:line or flow>
observed: "<what's wrong / what a user hits>  (delete this block if no findings)"
repro: "<steps / inputs>"

## Re-test results
- QA-001: <fixed & re-verified | still failing — iteration N>

## Residual risk (medium/low — knowingly accepted, NOT blocking)
- <none, or list>

## Summary
verdict: fail  acceptance: <accept|partial|reject>  critical:0 high:0 medium:0 low:0  iterations: 0/3
EOF
}

emit_ux_critique() {
  cat <<EOF
Model: <haiku|sonnet|opus>

## UX Critique — ${SID}

> Fill the SUBSTANCE. Keep the \`Model:\` line in the first 5 lines and the \`## UX Critique\` H2 —
> the Stop hook (validate_ux_critique_structure) anchors on them. Findings here are ADVISORY
> (non-blocking). A heading of '## Heuristic coverage' or '## UX findings' is also accepted; a bare
> '## Findings' is NOT (it would masquerade as AGENT_REVIEW).

| Heuristic | Finding | Severity | Recommendation |
|-----------|---------|----------|----------------|
| visibility of system status | <observed, or "no issue"> | <low\|medium\|high> | <fix, or "none"> |

## Heuristic coverage
- Contrast / focus states / error affordances / empty+loading+error states: <reviewed — pass, or note above>
EOF
}

emit_workflow_verification() {
  cat <<EOF
Model: <haiku|sonnet|opus>

## Workflow Verification — ${SID}

status: degraded

> Set \`status:\` to pass|degraded|fail at COLUMN 0 (the Stop hook anchors on it). 'degraded' = the
> browser/Playwright env was unavailable — accepted, NON-blocking; keep the \`degraded_reason:\` line.
> 'fail' = a user flow is broken in the browser: fix the WF-* findings and re-run the verifier.
degraded_reason: "<e.g. browser/Playwright unavailable in this environment>"

## Flows exercised
- <flow name>: <golden-path result; sad paths driven: empty / loading / error / permission / double-submit>
EOF
}

emit_verify_done_report() {
  cat <<EOF
Mode: scoped

Changed: 0

## Summary

> Fill the SUBSTANCE. \`Mode:\` (full|scoped|dirty-tree|user-owned-maintenance) and \`Changed: <N>\`
> must both appear in the FIRST 12 lines, and the FINAL non-empty line must read exactly
> \`Overall Verdict: PASS\` or \`Overall Verdict: FAIL\` (uppercase).

- Conventions checked: naming, error handling, eager-loading, semantic color tokens, loading/empty/error states
- Violations: <none, or list each with file:line>

Overall Verdict: PASS
EOF
}

case "$TYPE" in
  impact_map)            BODY="$(emit_impact_map)" ;;
  qa_report)             BODY="$(emit_qa_report)" ;;
  ux_critique)           BODY="$(emit_ux_critique)" ;;
  workflow_verification) BODY="$(emit_workflow_verification)" ;;
  verify_done_report)    BODY="$(emit_verify_done_report)" ;;
  *) echo "ERROR: --type must be impact_map|qa_report|ux_critique|workflow_verification|verify_done_report (got '$TYPE')" >&2; exit 2 ;;
esac

if [ -n "$OUT" ]; then
  printf '%s\n' "$BODY" > "$OUT" || { echo "ERROR: could not write '$OUT'" >&2; exit 1; }
  echo "wrote $TYPE skeleton → $OUT" >&2
else
  printf '%s\n' "$BODY"
fi
