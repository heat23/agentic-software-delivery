#!/usr/bin/env bash
# readonly-edit-guard.sh — PreToolUse hook (W57-F4)
# Event: PreToolUse / Edit|Write|MultiEdit|NotebookEdit
# Purpose: when the session is marked read-only (by detect-readonly-intent.sh),
#   block edits to TRACKED source files. Report/artifact writes and new
#   untracked files are still allowed, so the session can produce its findings
#   doc. This stops a "READ-ONLY, do NOT edit source" session from instrumenting
#   tracked source with debug probes in a shared working tree (observed
#   2026-05-26) — a concurrency hazard for sibling sessions on the same tree.
#
# Fail-OPEN: this is a usability-sensitive guard, not a safety-critical one.
# Any indeterminate state (no marker, no jq, not a git repo, can't resolve SID,
# can't classify the path) → ALLOW. We only DENY when we positively know the
# session is read-only AND the target is tracked source AND not an artifact.
#
# Override: export V_READONLY_OVERRIDE=1 to bypass (or submit a new prompt
# without a read-only directive, which clears the marker).

set -e
trap 'exit 0' ERR  # fail-open: any unexpected error → allow (never brick editing)
set +e
set -u

# Override escape hatch.
[ "${V_READONLY_OVERRIDE:-0}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null)
[ -n "$INPUT" ] || exit 0

# jq required to parse; if absent, fail-open (do not brick editing).
command -v jq >/dev/null 2>&1 || exit 0

# === ND-AGENT-FENCE (ND-0716) — structural fence for "read-only on source" reviewer agents ===
# v-qa-reviewer / v-ux-critique-reviewer / v-workflow-verifier declare read-only-ness in PROSE
# only: their agent files set `memory: project`, which silently re-grants full Edit/Write
# regardless of the `tools:` allowlist (measured live — see agents/v-pre-flight-runner.md:14-29),
# and this guard's session marker only exists in an explicit operator read-only session — never
# in the normal code-changing /v session where these reviewers are dispatched (Step 3.5/6.4.9).
# A reviewer that "just fixes the small thing" mid-review corrupts review independence with no
# detection (a weaker/more literal model actually does this; prose alone doesn't stop it).
# Ground truth (live probe 2026-07-16): PreToolUse fires inside subagent tool calls and the
# payload's .agent_type carries the agent NAME — so the fence keys on that, no marker needed.
# Deny-by-default is intentionally STRICTER than the session guard below (no new-untracked-file
# lane): a reviewer's only sanctioned writes are its OWN artifact, scratch/tmp/.v paths, and —
# for v-workflow-verifier only — Playwright specs/config (its contract commits a spec).
# Fail-open boundaries preserved: unknown/absent agent_type → skip; V_READONLY_OVERRIDE=1 (top
# of file) bypasses. Sibling sessions' other agents (general-purpose, codex, logic-reviewer …)
# are deliberately NOT fenced here.
ND_AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // empty' 2>/dev/null)
case "$ND_AGENT_TYPE" in
  v-qa-reviewer|v-ux-critique-reviewer|v-workflow-verifier)
    ND_FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
    if [ -n "$ND_FP" ]; then
      _nd_allow=0
      # scratch / artifact-dir lanes (any fenced agent). Deliberately NARROW: session
      # scratchpads (/tmp/claude-* | /private/tmp/claude-*), mktemp TMPDIR (/var/folders),
      # and .v/ — NOT bare /tmp/*, so a fenced agent can't stash source edits there and a
      # /tmp-rooted test harness can still exercise the deny lane.
      case "$ND_FP" in
        */.v/*|/tmp/claude-*|/private/tmp/claude-*|/var/folders/*) _nd_allow=1 ;;
      esac
      # each agent's OWN artifact only (root or any dir) — no cross-artifact laundering.
      # CODEX-001 (ND-0716 review): patterns are .md-anchored — a bare `*QA_REPORT_*` also
      # matched `QA_REPORT_payload.php` (an executable laundered under the artifact token).
      case "$ND_AGENT_TYPE" in
        v-qa-reviewer)          case "$ND_FP" in *QA_REPORT_*.md) _nd_allow=1 ;; esac ;;
        v-ux-critique-reviewer) case "$ND_FP" in *UX_CRITIQUE_*.md) _nd_allow=1 ;; esac ;;
        v-workflow-verifier)
          case "$ND_FP" in
            *WORKFLOW_VERIFICATION_*.md) _nd_allow=1 ;;
            *.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) _nd_allow=1 ;;
            */playwright.config.*|playwright.config.*) _nd_allow=1 ;;
            */e2e/*|*/tests/[Ee]2[Ee]/*) _nd_allow=1 ;;
          esac ;;
      esac
      if [ "$_nd_allow" -eq 0 ]; then
        ND_REASON="BLOCKED (readonly-edit-guard ND-AGENT-FENCE): agent '${ND_AGENT_TYPE}' is READ-ONLY on application source — it judges the code, it never fixes it (fixes belong to the orchestrator's remediation loop; a reviewer editing the code it grades corrupts review independence). Sanctioned writes only: your own artifact ($(case "$ND_AGENT_TYPE" in (v-qa-reviewer) printf 'QA_REPORT_<sid>.md';; (v-ux-critique-reviewer) printf 'UX_CRITIQUE_<sid>.md';; (*) printf 'WORKFLOW_VERIFICATION_<sid>.md + Playwright *.spec.* / playwright.config.* / e2e dirs';; esac)), .v/ and tmp scratch paths. Record the issue as a FINDING in your report instead of editing '${ND_FP}'."
        jq -n --arg reason "$ND_REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
        exit 0
      fi
    fi
    ;;
esac
# === end ND-AGENT-FENCE ===

# Resolve SID (stdin JSON .session_id → env → runtime file).
HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
SID=""
if [ -f "$HOOKS_LIB_DIR/resolve-sid.sh" ]; then
  # shellcheck source=/dev/null
  source "$HOOKS_LIB_DIR/resolve-sid.sh"
  SID=$(resolve_sid "$INPUT" 2>/dev/null || true)
fi
[ -n "$SID" ] || SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$SID" ] || exit 0

MARKER="$HOME/.claude/runtime/readonly-session-${SID}"
[ -f "$MARKER" ] || exit 0   # not a read-only session → allow

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# Must be inside a git work tree to ask "is this tracked?".
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Allowlist: artifacts / reports / transient dirs are always writable, even in
# a read-only session (the session must be able to emit its findings).
# P3-REGISTRY (2026-07-03): the authoritative per-session-artifact test is the single-source
# registry (a QA_REPORT/IMPACT_MAP/TRIVIAL_PASS/etc. write was previously deniable here only
# because those artifacts are usually untracked — list rot, the _FND_EXCLUDE_RE class). The
# legacy glob case below is retained as the fail-open fallback when the registry is absent,
# and still covers the non-per-session shapes (*_FINDINGS.md, WAVE*, bare PLAN_/AUDIT_*).
_APR_LIB="${V_ARTIFACT_PREFIX_REGISTRY:-$HOME/.claude/hooks/lib/artifact-prefix-registry.sh}"
if [ -f "$_APR_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_APR_LIB" 2>/dev/null || true
  if type is_session_artifact_path >/dev/null 2>&1 && is_session_artifact_path "$FILE_PATH"; then
    exit 0
  fi
fi
case "$FILE_PATH" in
  */.v/*|*/PRE_FLIGHT_REPORT_*|*/AGENT_REVIEW*|*/VERIFY_DONE_REPORT_*|*/IMPLEMENTATION_REPORT_*|*/SESSION_LOG_*|*/HANDOFF_*|*/BLOCKED_*|*_FINDINGS.md|*/WAVE[0-9]*|*/PLAN_*|*/AUDIT_*|*/POLISH_PLAN_*|*/REFACTOR_PLAN_*|*/WINNER_ELECTION_*)
    exit 0 ;;
esac

# Only DENY when the target is a tracked file. New untracked files (typical for
# reports/scratch) are allowed.
if git ls-files --error-unmatch -- "$FILE_PATH" >/dev/null 2>&1; then
  REL=$(git ls-files --full-name -- "$FILE_PATH" 2>/dev/null | head -1)
  [ -n "$REL" ] || REL="$FILE_PATH"
  REASON="BLOCKED (readonly-edit-guard): this session is READ-ONLY (you said 'do not edit source' / declared a read-only /v review). Editing the TRACKED file '${REL}' is not allowed — it can corrupt sibling sessions sharing this working tree (e.g. debug-probe instrumentation). Record findings in a NEW report/artifact instead (e.g. *_FINDINGS.md), and report the fix for a later wave. To genuinely edit source now, submit a new prompt WITHOUT a read-only directive, or set V_READONLY_OVERRIDE=1."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

exit 0
