#!/usr/bin/env bash
# block-fork-agent-dispatch.sh — PreToolUse(Agent/Task) guard (F2, 2026-06-30).
#
# WHY: /v runs in context:fork. From a fork, Agent(subagent_type=<reviewer/runner>) SILENTLY drops to
# inline self-review (Claude Code platform limit: subagents cannot spawn subagents) with NO error — the
# model assumes the review ran, hand-writes the artifact, and the independence gate then BLOCKS it
# ("no independent reviewer ran"). A fleet session hand-authored its QA_REPORT exactly this way.
# This guard turns the silent drop into a LOUD DENY that hands the model the fork-safe subprocess
# dispatch (v-dispatch-subagent.sh), which works in BOTH fork and inline and records the
# DISPATCH_PROVENANCE the gate requires.
#
# SCOPE: only the /v reviewer/runner agent types, and only when a /v session is active in this repo
# (a bootstrap-*.env marker exists — the same /v-active signal v-artifact-board.sh uses). Fail-OPEN on
# EVERY uncertainty (no jq, empty/bad stdin, no repo root, no marker) so it can never false-block a
# non-/v session. Escape hatch: V_FORK_DISPATCH_GUARD=off.
#
# REGISTRATION (deferred to operator — do NOT wire in live while a fleet runs): add to the existing
# "Skill|Agent" PreToolUse matcher in settings.json:
#     { "type": "command", "command": "~/.claude/hooks/block-fork-agent-dispatch.sh" }
set -uo pipefail

# Runner-managed implementation-only sessions are NOT /v orchestrator sessions.
[ "${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}" = "1" ] && exit 0
[ "${V_FORK_DISPATCH_GUARD:-on}" = "off" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0   # cannot parse stdin → fail-open (never false-block)

INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL_NAME" in Agent|Task) ;; *) exit 0 ;; esac
SUB=$(printf '%s' "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)
[ -n "$SUB" ] || exit 0

# Only the agent types /v dispatches and that silent-drop from a fork.
case "$SUB" in
  v-qa-reviewer|v-pre-flight-runner|v-verify-done-runner|v-workflow-verifier|v-ux-critique-reviewer|\
  logic-reviewer|security-reviewer|codex-adversarial-reviewer|codebase-fit-reviewer|framework-pitfall-reviewer|\
  adversarial-panel-reviewer) ;;
  *) exit 0 ;;
esac

# Only intervene when a /v session is active in this repo. Fail-open if the repo root is unknown.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-${PWD:-}}")"
[ -n "$ROOT" ] || exit 0
# Require a FRESH bootstrap marker — a stale marker from a long-dead /v session must not make F2 over-fire on
# a later unrelated session in the same repo. TTL = V_FORK_DISPATCH_TTL_MIN (default 480min/8h): the bootstrap
# mtime is set ONCE at session start and not refreshed, so 240min was too tight for long refactor waves and
# would silently drop fork-agent protection mid-session (adversarial review SREV-002).
ACTIVE=0; NOW=$(date +%s 2>/dev/null || echo 0); _TTL="${V_FORK_DISPATCH_TTL_MIN:-480}"
# ORCHFIX-E2 (forensics 2026-07-02): scope the marker check to THIS session's SID. The
# repo-wide glob made a SIBLING session's fresh bootstrap marker (parallel fleet, markers accumulate,
# 8h TTL) activate this guard for a NON-fork main-loop session whose Agent dispatches would have
# worked fine — with nightly fleets the guard was effectively always-on for every session in the
# repo. When the SID is known (hook stdin's session_id, else CLAUDE_SESSION_ID), only a
# bootstrap-<THIS-sid>*.env marker activates the guard; the repo-wide glob remains ONLY as the
# fail-closed fallback for an unknown SID (fail-open on uncertainty would gut the fork protection).
_SID_F2="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$_SID_F2" ] || _SID_F2="${CLAUDE_SESSION_ID:-}"
if [ -n "$_SID_F2" ]; then
  _F2_GLOB=("$ROOT"/.v/tmp/bootstrap-"${_SID_F2}"*.env)
else
  _F2_GLOB=("$ROOT"/.v/tmp/bootstrap-*.env)
fi
for _m in "${_F2_GLOB[@]}"; do
  [ -f "$_m" ] || continue
  _mt=$(stat -c %Y "$_m" 2>/dev/null || stat -f %m "$_m" 2>/dev/null || echo 0)
  [ "$NOW" -gt 0 ] && [ "${_mt:-0}" -gt 0 ] && [ $(( (NOW - _mt) / 60 )) -lt "$_TTL" ] && { ACTIVE=1; break; }
done
[ "$ACTIVE" -eq 1 ] || exit 0

REASON="F2 fork-safe /v dispatch: Agent(subagent_type=${SUB}) is unsafe for /v reviewers/runners — from a /v fork it SILENTLY drops to inline self-review (platform limit: subagents cannot spawn subagents), producing a hand-authored artifact that the independence gate then blocks. Use the fork-safe subprocess helper instead (works in fork AND inline, records DISPATCH_PROVENANCE):
  bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent ${SUB} --prompt-file <PROMPT_FILE> [--artifact <ARTIFACT_NAME>]
(See the v-dispatch-subagent.sh header for exact flags/modes. Override only if certain the Agent path works in your context: re-run with V_FORK_DISPATCH_GUARD=off.)"

jq -n --arg reason "$REASON" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
exit 0
