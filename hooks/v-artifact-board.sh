#!/usr/bin/env bash
# v-artifact-board.sh — EFF-BOARD (2026-06-28): PostToolUse hook that INJECTS the gauntlet-artifact
# present/absent/valid BOARD into the model's context (additionalContext), so the /v orchestrator sees
# artifact state automatically and stops the ad-hoc `ls AGENT_REVIEW* / PRE_FLIGHT*` probe cluster
# (forensic 2026-06-28: ~13 such probe-turns/session ≈ 1.1M cache_read/session; 67 probes across 5 sessions).
#
# Reliable (auto-injected → the model never needs to probe) and ZERO false-positive risk: additionalContext
# is purely ADDITIVE — this hook NEVER denies, NEVER edits, NEVER blocks. It reuses the existing one-shot
# `v-artifact-validate-all.sh` (no reinvention / no drift from the Stop hook's own artifact authority).
#
# REGISTER (settings.json PostToolUse, matcher "Write|Agent|Task" — Edit is intentionally NOT matched; see
# the tool guard below, which boards only on artifact-state-CHANGING tools):
#   { "matcher": "Write|Agent|Task", "hooks": [ { "type": "command", "command": "~/.claude/hooks/v-artifact-board.sh" } ] }
# Fires only inside a /v session (a .v/ dir + a bootstrap marker or an existing gauntlet artifact for this SID);
# a plain chat/edit session anywhere else is a silent no-op. Escape hatch: V_ARTIFACT_BOARD=off.
#
# Bite: hooks/v-artifact-board-test.sh.
set -uo pipefail   # fail-open hook (per-step `|| true`/`|| echo` guards) — pipefail satisfies the
                   # v-hook-integration strict-mode convention without errexit aborting a best-effort step.
[ "${V_ARTIFACT_BOARD:-on}" = "off" ] && exit 0
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

INPUT="$(cat 2>/dev/null || true)"

# Only the events that CHANGE artifact state are worth a board (an artifact Write, or a subagent dispatch
# landing its artifact). Skip source Edits / Bash etc. so this adds no per-turn noise. (The settings.json
# matcher should already narrow this; the internal guard makes the hook safe under any matcher.)
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL" in
  Write|Agent|Task) : ;;      # artifact-state-changing tools → worth a board
  "") : ;;                    # no/!jq payload → env-driven / bite invocation (no stdin JSON)
  *) exit 0 ;;                # Edit, Bash, and any other tool: no board needed (SREV-005)
esac

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SID" ] || exit 0
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$CWD" ] || CWD="$PWD"
[ -d "$CWD" ] || exit 0

REPO="$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$CWD")"

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (114 stray files over
# 8 weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${REPO:-}" ] && [ -n "$_lg_cfg" ] && [ "${REPO}" != "$_lg_cfg" ]; then
  case "${REPO}" in
    "$_lg_cfg"/*) git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO="$_lg_cfg" ;;
  esac
fi

[ -d "$REPO/.v" ] || exit 0   # no /v scaffolding here → not a /v session → no-op

# /v-session confirmation: a bootstrap marker for THIS sid, OR an existing gauntlet artifact for it.
# (SID is a Claude Code session UUID — no glob-special chars — so the unquoted ${SID} in -name is safe.)
_is_v=0
if [ -d "$REPO/.v/tmp" ] && find "$REPO/.v/tmp" -maxdepth 1 -name "bootstrap-${SID}*.env" 2>/dev/null | grep -q .; then _is_v=1; fi
if [ "$_is_v" -eq 0 ]; then
  if find "$REPO" "$REPO/.v/artifacts" -maxdepth 1 -name "*_${SID}*.md" 2>/dev/null \
       | grep -qE '/(PRE_FLIGHT_REPORT|AGENT_REVIEW|VERIFY_DONE_REPORT|QA_REPORT|WORKFLOW_VERIFICATION|UX_CRITIQUE|IMPACT_MAP)_'; then _is_v=1; fi
fi
[ "$_is_v" -eq 1 ] || exit 0

# Build the board via the existing one-shot tool (present/absent/valid + path). Read-only, best-effort.
VAL="$CLAUDE_DIR/skills/v/references/v-artifact-validate-all.sh"
[ -f "$VAL" ] || exit 0
# SREV-002: a worktree session's artifacts usually land in the MAIN checkout, not the worktree — mirror the
# Stop hook's multi-root search (git-common-dir's parent is the main checkout) so the board is not falsely
# 'absent' (a false-absent would trigger the very ls-probing this hook exists to remove).
MAIN="$REPO"
_gcd="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$_gcd" ] && [ "$(basename "$_gcd" 2>/dev/null)" = ".git" ]; then
  _mc="$(dirname "$_gcd")"; [ -d "$_mc" ] && MAIN="$_mc"
fi
BOARD="$(cd "$REPO" 2>/dev/null && bash "$VAL" "$SID" "$REPO/.v/artifacts" "$REPO" "$MAIN/.v/artifacts" "$MAIN" 2>/dev/null || true)"
[ -n "$BOARD" ] || exit 0
# SREV-001 (prompt-injection): validate-all's FAIL detail line ("↳ <msg>") can echo RAW artifact content; the
# model only needs present/absent/valid STATUS, not the raw detail. Drop the ↳ detail lines, strip control
# chars, and cap line + total length so NO attacker-controlled artifact content reaches additionalContext.
BOARD="$(printf '%s' "$BOARD" | grep -vE '↳' | tr -d '\000-\010\013\014\016-\037' | awk '{print substr($0,1,160)}' | head -c 2000)"
[ -n "$BOARD" ] || exit 0

# Cadence (cost-sink fix 2026-06-29): the board fires on EVERY PostToolUse, but ~76% of injections are
# byte-IDENTICAL to the prior one (measured) — and each persists in the conversation, re-read in every later
# turn's cache_read (a recurring per-session cost; meaningful at fleet scale). De-dup: skip the emit
# when the artifact STATE is unchanged since the last injection (the prior board is still in context; the
# Stop hook + readiness check still enforce). Re-emits on ANY state change. Fail-open: marker errors -> emit.
# Escape: V_ARTIFACT_BOARD_CADENCE=off forces every-turn injection.
if [ "${V_ARTIFACT_BOARD_CADENCE:-on}" != "off" ]; then
  _bsig="$(printf '%s' "$BOARD" | grep -oE '^[[:space:]]*(ok|invalid|absent)[[:space:]]+[A-Za-z_]+' | tr -s '[:space:]' ' ' | sort | tr '\n' '|')"
  _bsf="$REPO/.v/tmp/board-sig-${SID}.txt"
  if [ -n "$_bsig" ] && [ "$_bsig" = "$(cat "$_bsf" 2>/dev/null)" ]; then
    exit 0   # state unchanged since last injection — skip the redundant re-inject (prior board still in context)
  fi
  [ -n "$_bsig" ] && { mkdir -p "$REPO/.v/tmp" 2>/dev/null && printf '%s' "$_bsig" > "$_bsf" 2>/dev/null || true; }
fi

CTX="📋 Artifact board (auto-injected — this is the authoritative present/absent/valid state for session ${SID}; do NOT re-check with ad-hoc ls):
${BOARD}
If an artifact you dispatched shows 'absent', WAIT for the subagent's completion notification — do not poll with ls."

# Readiness pointer (cost-sink fix 2026-06-29): once gauntlet artifacts EXIST (the board shows an 'ok' = work
# nearing completion), steer the model to the one-pass gate preview so it clears ALL blockers together instead
# of the stop->block->fix->stop thrash that dominates /v cost (forensic: 76% of one run's cost was
# post-first-block remediation). Additive only; the escape hatch + fail-open contract are unchanged.
if printf '%s' "$BOARD" | grep -qE '^[[:space:]]*(ok|invalid)([[:space:]]|$)'; then
  CTX="${CTX}
💡 Before you stop, run \`bash ~/.claude/skills/v/references/v-stop-readiness.sh ${SID}\` — it previews EVERY Stop gate (artifacts + the semantic ones the board can't show: review provenance, QA verdict, survival, merge-back) and prints each blocker's exact fix. Fix them ALL in one pass; do not stop->block->fix->stop one at a time."
fi

jq -n --arg ctx "$CTX" '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}' 2>/dev/null \
  || printf '%s\n' "$CTX" >&2   # fail-safe: jq unavailable → at least surface on stderr (never block)
exit 0
