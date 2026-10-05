#!/usr/bin/env bash
# record-agent-dispatch-provenance.sh — PostToolUse (matcher: Agent)
#
# P2 (fleet forensic 2026-06-21): when /v runs INLINE/continuation (not forked) it dispatches reviewers via
# the **Agent tool**, which — unlike the forked `claude -p --agent` path (v-dispatch-subagent.sh, which self-
# records) — writes NO DISPATCH_PROVENANCE. The gate's _agent_was_dispatched then finds no provenance (and the
# transcript subagent_type signal is unreachable across a continuation boundary) → forgery-'silent' BLOCK →
# the AGENT_REVIEW rewrite / re-dispatch churn (top-5 sessions: 30-39 provenance-blocks, 5-10 rewrites) AND
# session-log dispatch_path=none laundering. This hook closes that gap by witnessing the REAL
# Agent-tool dispatch and writing the SID-scoped, file-based provenance line the gate reads.
#
# ANTI-FORGERY: it fires ONLY on a genuinely-completed reviewer dispatch (the harness actually ran it + a non-
# error result came back). A fabricated "codex ran" claim with NO real Agent dispatch produces NO PostToolUse
# event → NO provenance → the forgery is still blocked. The hook is a witness, not a rubber stamp.
#
# Fail-open: PostToolUse must NEVER block or error. `set -uo pipefail` is strict error handling WITHOUT
# errexit (so a single failed step never aborts the hook); the EXIT trap forces exit 0 unconditionally.
set -uo pipefail
trap 'exit 0' EXIT
INPUT=$(cat 2>/dev/null || printf '{}')

_jq() { printf '%s' "$INPUT" | jq -r "$1" 2>/dev/null || printf ''; }

# LEAK-GUARD (2026-08-02): defense-in-depth mirror of the central guard in v-artifact-dir.sh.
# These $PWD fallbacks only fire if that script fails to EXECUTE (missing/unreadable/disk error)
# — near-dead in practice since it always exits 0 — but if they ever do fire inside a skill/hook
# source subtree of the git-less config dir they would nest .v/artifacts there. Snap up instead.
_safe_pwd_artifact_dir() {
  _sad_dir="${PWD}/.v/artifacts"
  _sad_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -n "$_sad_cfg" ] && [ "$PWD" != "$_sad_cfg" ]; then
    case "$PWD" in
      "$_sad_cfg"/*) git -C "$PWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || _sad_dir="${_sad_cfg}/.v/artifacts" ;;
    esac
  fi
  printf '%s\n' "$_sad_dir"
}


# Accept Agent (current tool name) AND Task (defensive — in case the matcher is ever broadened/renamed).
case "$(_jq '.tool_name // empty')" in Agent|Task) ;; *) exit 0 ;; esac
SUBAGENT="$(_jq '.tool_input.subagent_type // empty')"
[ -n "$SUBAGENT" ] || exit 0

# G1 (telemetry 2026-06-21): a DETERMINISTIC per-dispatch ledger — EVERY Agent-tool dispatch (reviewer/runner/
# general/Explore/…), not just the gauntlet reviewers. STANDALONE forensic telemetry: it is a deterministic
# record of agent_type+model_requested+dispatch_path keyed by parent_sid, intended as a FUTURE cost-tally input
# (M6, SME review 2026-06-21: cost-tally.py does NOT yet read this — it classifies by transcript identity, which
# the M5 fix hardened). SEPARATE file + concern from the gate-provenance below: additive, fail-open, never gates
# anything. Records the REQUESTED model; the BILLED model stays authoritative from the child transcript's
# .message.model per the G4 rule (a model:haiku request can still execute on another model).
_LSID="$(_jq '.session_id // empty')"; [ -n "$_LSID" ] || _LSID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
_LMODEL="$(_jq '.tool_input.model // "inherit"')"
_LTS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
_LDIR=$(bash "$HOME/.claude/skills/v/references/v-artifact-dir.sh" 2>/dev/null) || _LDIR="$(_safe_pwd_artifact_dir)"
mkdir -p "$_LDIR" 2>/dev/null || true
# C2/G1-4 (telemetry 2026-06-21; T1 fix post-batch live-validation): record the model that will actually
# BILL. A CONCRETE runtime request WINS — reviewers are dispatched with an explicit `model: haiku` override
# (CLAUDE.md) that overrides the agent's frontmatter pin, so the REQUEST is the billed model; recording the
# pin instead was wrong on 5/12 live rows (pin=sonnet but billed=haiku). Only when the request is
# inherit/none (no override) does the frontmatter pin best-approximate the billed model. This matches the
# hook's own G4 contract above. (The subprocess path records SUBMODEL from .modelUsage — billed truth — directly.)
_LPIN="$(sed -nE 's/^[[:space:]]*model:[[:space:]]*//p' "$HOME/.claude/agents/${SUBAGENT}.md" 2>/dev/null | head -1 | tr -d '"'\''[:space:]')"
case "$_LMODEL" in inherit|"") _LUSED="${_LPIN:-$_LMODEL}" ;; *) _LUSED="$_LMODEL" ;; esac
# review MED (2026-06-21): strip "/\ from interpolated identifiers so a stray quote can't malform the JSON row.
_LSID_J="${_LSID//[\"\\]/}"; _LSUB_J="${SUBAGENT//[\"\\]/}"; _LMODEL_J="${_LMODEL//[\"\\]/}"; _LUSED_J="${_LUSED//[\"\\]/}"
printf '{"ts":"%s","parent_sid":"%s","agent_type":"%s","model_requested":"%s","model_used":"%s","dispatch_path":"agent-tool"}\n' \
  "$_LTS" "$_LSID_J" "$_LSUB_J" "$_LMODEL_J" "$_LUSED_J" >> "$_LDIR/DISPATCH_LEDGER.jsonl" 2>/dev/null || true

# Reviewer/runner allowlist — the agents whose independent dispatch the gauntlet gates on. A non-reviewer
# Agent dispatch (general-purpose, Explore, etc.) is NOT a gauntlet reviewer and must not write provenance.
case "$SUBAGENT" in
  codex-adversarial-reviewer|logic-reviewer|security-reviewer|codebase-fit-reviewer|framework-pitfall-reviewer\
  |adversarial-panel-reviewer\
  |v-qa-reviewer|v-verify-done-runner|v-pre-flight-runner|v-ux-critique-reviewer|v-workflow-verifier) ;;
  *) exit 0 ;;
esac

# Anti-forgery: require a REAL, non-error tool_response (the harness ran it and returned a result).
[ "$(_jq '.tool_response.is_error // .is_error // .tool_response.error // false')" != "true" ] || exit 0
# Robust across every plausible PostToolUse tool_response shape (the one schema uncertainty): a bare string,
# {content:string}, {content:[{text:…}]} (Anthropic content-block array), a bare content-block array, or any
# other object/array (tostring fallback). Whichever yields non-empty text proves a real result came back.
RESP="$(_jq '
  if   (.tool_response|type)=="string"          then .tool_response
  elif (.tool_response.content|type)=="string"  then .tool_response.content
  elif (.tool_response.content|type)=="array"   then ([.tool_response.content[]?|(.text // .)|strings]|join(" "))
  elif (.tool_response|type)=="array"           then ([.tool_response[]?|(.text // .)|strings]|join(" "))
  elif (.tool_response|type)=="object"          then (.tool_response|tostring)
  else "" end')"
[ -n "$(printf '%s' "$RESP" | tr -d '[:space:]')" ] || exit 0

SID="$(_jq '.session_id // empty')"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SID" ] || exit 0

# Item 7 (2026-07-05, session-bleed incident): SID-bind the writer against THIS process's own local
# identity. A payload .session_id that DISAGREES with the local env/runtime identity is a
# foreign-SID bleed, not this session's own dispatch — writing under it would contaminate a
# DIFFERENT session's DISPATCH_PROVENANCE log. Reject (fail-open: skip silently, PostToolUse
# must never block) rather than trust the payload alone when a local identity is resolvable.
# When no local identity is resolvable at all, behavior is unchanged (nothing to cross-check).
_LOCAL_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$_LOCAL_SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  _LOCAL_SID="$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)"
fi
if [ -n "$_LOCAL_SID" ] && [ "$_LOCAL_SID" != "$SID" ]; then
  echo "record-agent-dispatch-provenance: REJECTED foreign-SID row (payload sid=$SID, local identity=$_LOCAL_SID) — refusing to write DISPATCH_PROVENANCE for a different session" >&2
  exit 0
fi

MODEL="$(_jq '.tool_input.model // "unknown"')"
# W-PROV-FRONTMATTER (2026-08-09): when the Agent call omits `model`, fall back to the agent
# definition's own frontmatter instead of recording "unknown".
#
# WHY: `unknown` is what this field reads for EVERY mode=agent-tool row — 20 of 23
# adversarial-panel rows plus logic/security/framework/codex on the 2026-08-06→09 corpus. That
# is a direct consequence of the (correct) 2026-08-06 guidance to pass NO model and let each
# agent's frontmatter govern. But DISPATCH_PROVENANCE is the witness that exposed the haiku
# incident in the first place — it was the ONLY artefact that said what actually ran while
# frontmatter said sonnet. Leaving it blind at exactly the dispatch mode that caused the
# incident recreates the observability gap one layer over.
#
# Recorded as `<model>~fm` so the row never claims to have observed a passed parameter: `sonnet`
# means the call specified it, `sonnet~fm` means it was inherited from the definition. Telemetry
# only — no gate reads this value to decide anything, and Layer 3 of enforce-haiku-dispatch.sh
# remains the enforcement. Bite: hooks/provenance-frontmatter-model-test.sh.
if [ "$MODEL" = "unknown" ] && [ -n "${SUBAGENT:-}" ]; then
  _agent_def="$HOME/.claude/agents/${SUBAGENT}.md"
  if [ -f "$_agent_def" ]; then
    _fm_model=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^model:[[:space:]]*/{sub(/^model:[[:space:]]*/,""); gsub(/["'"'"'[:space:]]/,""); print; exit}' "$_agent_def" 2>/dev/null)
    case "$_fm_model" in
      ''|*[!a-zA-Z0-9._-]*) : ;;
      *) MODEL="${_fm_model}~fm" ;;
    esac
  fi
fi
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')
SHA=$(printf '%s' "$RESP" | shasum -a 256 2>/dev/null | awk '{print $1}')
[ -n "$SHA" ] || exit 0

ADIR=$(bash "$HOME/.claude/skills/v/references/v-artifact-dir.sh" 2>/dev/null) || ADIR="$(_safe_pwd_artifact_dir)"
mkdir -p "$ADIR" 2>/dev/null || true
LOG="$ADIR/DISPATCH_PROVENANCE_${SID}.log"

# Idempotent: don't double-record the SAME dispatch (a single line carrying both this agent AND this sha).
if ! grep -qE "agent=${SUBAGENT}\|.*sha256=${SHA}" "$LOG" 2>/dev/null; then
  # artifact= a NON-FILE witness marker (so the post-dispatch-edit tamper check never mis-matches a real file);
  # the line's job is to prove the dispatch to _agent_was_dispatched (agent|mode≠agent-self|status=ok).
  printf 'DISPATCH|ts=%s|agent=%s|mode=agent-tool|status=ok|submodel=%s|cost_usd=0|duration_ms=0|artifact=dispatch-witness:%s|sha256=%s\n' \
    "$TS" "$SUBAGENT" "$MODEL" "$SUBAGENT" "$SHA" >> "$LOG" 2>/dev/null || true
fi
exit 0
