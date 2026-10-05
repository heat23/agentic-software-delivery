#!/usr/bin/env bash
# v-resolve-task.sh — extracted from SKILL.md Step -3 in W68.
#
# Emits ---TASK-SOURCE=*---, ---TASK-BEGIN---/---TASK-END---, and W25-F7-*
# markers to stdout (orchestrator parses these for routing). Persists
# resolved task to ~/.claude/runtime/v-resolved-task-${CLAUDE_SESSION_ID}.txt
# (W63 contract). Writes recovery trace to
# ~/.claude/runtime/v-task-recovery-${SID}.log (W68 — JSONL + flock).
#
# RUNS WITHOUT `set -u` — original Step -3 code relies on default bash
# semantics where unset variables expand to empty string. Adding set -u
# would silent-exit on uninitialized _* variables and break recovery.
#
# NOTE on SID resolution divergence: this script uses W25-F26 Strategy 1-4
# (env CLAUDE_CODE_SESSION_ID first), NOT W65's lib/resolve-sid.sh
# (Priority 0-3, stdin-JSON first). The divergence is intentional. Reason:
# 2026-05-12 catastrophic incident — 6 parallel /v sessions cross-
# contaminated when history.jsonl was Priority 1. Step -3 must use env
# CLAUDE_CODE_SESSION_ID as PRIMARY (per-process, contamination-proof).
# Unifying the two resolvers is deferred to a future wave (see W68-PLAN-v2).

# W25-F21: Normalize CLAUDE_SESSION_ID from CLAUDE_CODE_SESSION_ID
# Claude Code v2.1.132+ sets CLAUDE_CODE_SESSION_ID in Bash tool subshells
# (NOT CLAUDE_SESSION_ID). All 540+ downstream references in this skill use
# $CLAUDE_SESSION_ID. This one-line export bridges the gap.
export CLAUDE_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

# W25-F9 HARDENED: Find the user's task with three SID-scoped recovery channels.
# All channels are intrinsically SID-scoped — no unscoped file is EVER read,
# preventing cross-session contamination from parallel Claude Code sessions.
#
# Recovery priority:
#   1. PreToolUse SID-scoped capture (last-skill-args-${SID}.txt) → args
#   2. PreToolUse SID-scoped capture → prompt
#   3. ~/.claude/history.jsonl filtered by sessionId + /v-prefix + time window
#      around the PreToolUse CAPTURED_AT timestamp (Claude Code's own append-
#      only typed-input log; safe across parallel sessions and image-attached
#      slash-command Skill invocations on v2.1.138+)
#   4. SID-scoped UserPromptSubmit capture (last-user-prompt-${SID}.txt)
#   5. Otherwise → empty (Final Guard takes over)
#
# IMPORTANT (W25-F10): Empty bash channels do NOT mean "I'm in a subagent".
# When ALL four file-based channels return empty, the model MUST recover from
# the conversation context (Channel 5 — see Step -3 instructions below). Empty
# bash output is a recovery scenario, NOT an excuse to abandon /v.

# === SID resolution (W25-F26: env-var PRIMARY — contamination-proof) ===
# Cross-session contamination defense (corrected from W25-F20 regression):
#
# `CLAUDE_CODE_SESSION_ID` (set by Claude Code v2.1.132+ per anthropics/claude-code
# v2.1.132 changelog) is PER-PROCESS. Each parallel Claude Code session has its
# own value, propagated to all its Bash tool subshells. It CANNOT be contaminated
# by other sessions. This is the strongest signal we have — use it FIRST.
#
# history.jsonl filtered by sessionId is correct IFF the sessionId we filter by
# is correct. Once env gives us the right SID, history.jsonl filtered by that
# SID retrieves OUR task safely.
#
# The W25-F20 priority (history.jsonl PRIMARY) caused catastrophic cross-session
# contamination on 2026-05-12: 6 parallel /v sessions in the same project all
# resolved to whichever session was the latest typer, picking up that session's
# task instead of their own. Reverted here.
#
# Resolution order:
#   1. CLAUDE_CODE_SESSION_ID env (per-process — contamination-proof)
#   2. CLAUDE_SESSION_ID env (legacy fallback if a hook set it manually)
#   3. history.jsonl filtered by project + recency (Strategy D — ONLY when env
#      is unset; risky on parallel sessions)
#   4. shared runtime/current-session-id file (LAST RESORT — last-writer-wins)
_SID=""
_SID_SOURCE=""
_HISTORY_FILE="$HOME/.claude/history.jsonl"

# Strategy 1 (PRIMARY — contamination-proof): env CLAUDE_CODE_SESSION_ID
_env_sid="${CLAUDE_CODE_SESSION_ID:-}"
if echo "$_env_sid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  _SID="$_env_sid"
  _SID_SOURCE="CLAUDE_CODE_SESSION_ID env (Claude Code v2.1.132+, per-process, contamination-proof)"
fi

# Strategy 2 (FALLBACK): legacy CLAUDE_SESSION_ID env
if [ -z "$_SID" ]; then
  _legacy_env_sid="${CLAUDE_SESSION_ID:-}"
  if echo "$_legacy_env_sid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    _SID="$_legacy_env_sid"
    _SID_SOURCE="CLAUDE_SESSION_ID env (legacy — set manually by a hook)"
  fi
fi

# Strategy 3 (EMERGENCY — env-less environment): history.jsonl by project + recency.
# WARNING: with parallel /v sessions in the same project within the last 60s,
# this returns the LATEST typer's SID, not necessarily this session's. Only safe
# when env is genuinely unset AND no parallel sessions are active. We use it
# because the only worse option is the shared runtime file.
if [ -z "$_SID" ] && [ -s "$_HISTORY_FILE" ] && command -v jq >/dev/null 2>&1; then
  _now_ms=$(( $(date +%s) * 1000 ))
  _ms_window=$(( _now_ms - 60000 ))
  _pwd_now=$(pwd 2>/dev/null)
  if [ -n "$_pwd_now" ]; then
    _sid_from_history=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
      | tail -n +2 \
      | jq -Rr --arg pwd "$_pwd_now" --argjson tmin "$_ms_window" \
          'fromjson? | select(.display | type=="string") | select(.display | startswith("/v")) | select(.project == $pwd) | select(.timestamp >= $tmin) | .sessionId' \
          2>/dev/null \
      | tail -1)
    if echo "$_sid_from_history" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
      _SID="$_sid_from_history"
      _SID_SOURCE="history.jsonl (EMERGENCY — env unset; may be contaminated by parallel sessions)"
    fi
  fi
fi

# Strategy 4 (LAST RESORT): shared runtime file — vulnerable to cross-session contamination
if [ -z "$_SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  _c=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
  if echo "$_c" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
     && [ "$_c" != "00000000-0000-0000-0000-000000000000" ]; then
    _SID="$_c"
    _SID_SOURCE="runtime/current-session-id (LAST RESORT — almost certainly contaminated)"
  fi
fi

if [ -n "$_SID" ]; then
  echo "W25-F26-SID-SOURCE=$_SID_SOURCE"
  echo "W25-F26-RESOLVED-SID=$_SID"
fi

# === jq presence check (P1-2) ===
_HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then _HAVE_JQ=1; fi

# === Platform-detect for stat (R2-6 — once, not per-call) ===
# BSD stat (macOS) takes -f '%m'; GNU stat (Linux) takes -c '%Y'. Same flags
# mean different things — feature-detect by exit code fails because GNU stat
# accepts -f and emits filesystem info. Detect by OS family instead.
case "$(uname -s 2>/dev/null)" in
  Darwin|*BSD*) _USE_BSD_STAT=1 ;;
  *)            _USE_BSD_STAT=0 ;;
esac

# === W71-F1 (forensic 2026-07-02): display-referenced paste selection ===
# A history entry's pastedContents map can hold MULTIPLE pastes from the same
# input session (a stray earlier paste + the one actually submitted). Blindly
# dereferencing the FIRST map entry routed a SIBLING terminal's task into 2 of
# 4 fleet sessions on 2026-07-02 (task A executed 3x while the typed tasks B and
# C were silently dropped). Select the entry the display text
# references ("[Pasted text #N ...]"); when the display names no entry, fall
# back to the LAST (most recent) map entry — never the first.
_extract_paste_fields() {
  # $1 = history entry JSON, $2 = display text
  # Sets: _history_paste_hash, _history_inline_content
  _history_paste_hash=""
  _history_inline_content=""
  if [ -z "$1" ] || [ "$1" = "null" ]; then return 0; fi
  _epf_ref=$(printf '%s' "$2" | grep -oE '\[Pasted text #[0-9]+' | head -1 | grep -oE '[0-9]+' | head -1)
  _history_paste_hash=$(printf '%s' "$1" | jq -rc --arg k "${_epf_ref:-}" \
    '(.pastedContents // {}) as $pc
     | (if ($k != "" and ($pc[$k] // null) != null) then $pc[$k]
        else ((($pc | to_entries | last) // {}).value // {}) end)
     | .contentHash // ""' 2>/dev/null)
  _history_inline_content=$(printf '%s' "$1" | jq -rc --arg k "${_epf_ref:-}" \
    '(.pastedContents // {}) as $pc
     | (if ($k != "" and ($pc[$k] // null) != null) then $pc[$k]
        else ((($pc | to_entries | last) // {}).value // {}) end)
     | .content // ""' 2>/dev/null)
  return 0
}

# === Channel 1+2: PreToolUse SID-scoped capture (W25-F9: SID-scoped only) ===
_CAPTURE_SID="$HOME/.claude/runtime/last-skill-args-${_SID}.txt"
_CAPTURE=""
if [ -n "$_SID" ] && [ -s "$_CAPTURE_SID" ]; then
  _CAPTURE="$_CAPTURE_SID"
fi

_args=""
_prompt=""
_captured_at_iso=""
_captured_at_epoch=""

if [ -z "$_CAPTURE" ]; then
  echo "W25-F7-RESULT=capture_missing"
  echo "W25-F7-NOTE=No SID-scoped PreToolUse capture for $_SID. Will try history.jsonl + UserPromptSubmit fallbacks."
else
  echo "W25-F7-RESULT=capture_found"
  echo "W25-F7-PATH=$_CAPTURE"
  _captured_at_iso=$(grep '^CAPTURED_AT=' "$_CAPTURE" | head -1 | cut -d= -f2-)
  echo "W25-F7-CAPTURED_AT=$_captured_at_iso"
  echo "W25-F7-ARGS_LENGTH=$(grep '^ARGS_LENGTH=' "$_CAPTURE" | head -1 | cut -d= -f2-)"
  echo "W25-F7-PROMPT_LENGTH=$(grep '^PROMPT_LENGTH=' "$_CAPTURE" | head -1 | cut -d= -f2-)"
  _args=$(awk '/^---ARGS-BEGIN---$/{f=1;next} /^---ARGS-END---$/{f=0} f' "$_CAPTURE")
  _prompt=$(awk '/^---PROMPT-BEGIN---$/{f=1;next} /^---PROMPT-END---$/{f=0} f' "$_CAPTURE")
  if [ -n "$_captured_at_iso" ]; then
    _captured_at_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$_captured_at_iso" +%s 2>/dev/null \
                         || date -d "$_captured_at_iso" +%s 2>/dev/null \
                         || echo "")
  fi
fi

_stripped_args=$(printf '%s' "$_args" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
_stripped_prompt=$(printf '%s' "$_prompt" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')

# === Channel 3: history.jsonl by SID + /v prefix + time window ===
# (P0-1: time window prevents tail -1 from grabbing a different /v invocation in
# the same session. P2-1: bounded scan with `tail -c 200000`. P1-1: jq -s
# parses JSON objects so embedded \n in display fields don't break selection.)
_HISTORY_FILE="$HOME/.claude/history.jsonl"
_history_task=""
_history_paste_hash=""
_history_inline_content=""
_history_src=""
_history_strategy=""

if [ -n "$_SID" ] && [ -s "$_HISTORY_FILE" ] && [ "$_HAVE_JQ" = "1" ]; then
  # Strategy A: SID + /v-prefix + ±30s of CAPTURED_AT (most precise)
  if [ -n "$_captured_at_epoch" ]; then
    _ms_min=$(( (_captured_at_epoch - 5) * 1000 ))
    _ms_max=$(( (_captured_at_epoch + 30) * 1000 ))
    # W25-F19: tail -n +2 drops the partial first line caused by tail -c byte
    # truncation. Use jq -rc (line-by-line) so malformed lines fail silently
    # instead of poisoning the whole slurp.
    # W25-F22: also extract pastedContents hash if user actually pasted
    _history_entry=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
      | tail -n +2 \
      | jq -cR --arg sid "$_SID" --argjson tmin "$_ms_min" --argjson tmax "$_ms_max" \
          'fromjson? | select(.sessionId==$sid) | select(.display | type=="string") | select(.display | startswith("/v")) | select(.timestamp >= $tmin and .timestamp <= $tmax)' \
          2>/dev/null | tail -1)
    _history_task=$(printf '%s' "$_history_entry" | jq -rc '.display // ""' 2>/dev/null)
    _extract_paste_fields "$_history_entry" "$_history_task"   # W71-F1: display-referenced entry, never .[0]
    [ -n "$_history_task" ] && [ "$_history_task" != "null" ] && _history_strategy="sid+vprefix+timewindow"
  fi
  # Strategy B: SID + /v-prefix, last entry
  if [ -z "$_history_task" ] || [ "$_history_task" = "null" ]; then
    _history_entry=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
      | tail -n +2 \
      | jq -cR --arg sid "$_SID" \
          'fromjson? | select(.sessionId==$sid) | select(.display | type=="string") | select(.display | startswith("/v"))' \
          2>/dev/null | tail -1)
    _history_task=$(printf '%s' "$_history_entry" | jq -rc '.display // ""' 2>/dev/null)
    _extract_paste_fields "$_history_entry" "$_history_task"   # W71-F1: display-referenced entry, never .[0]
    [ -n "$_history_task" ] && [ "$_history_task" != "null" ] && _history_strategy="sid+vprefix"
  fi
  # Strategy C: SID-only — last typed line for this session (extreme edge case)
  if [ -z "$_history_task" ] || [ "$_history_task" = "null" ]; then
    _history_entry=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
      | tail -n +2 \
      | jq -cR --arg sid "$_SID" \
          'fromjson? | select(.sessionId==$sid) | select(.display | type=="string")' \
          2>/dev/null | tail -1)
    _history_task=$(printf '%s' "$_history_entry" | jq -rc '.display // ""' 2>/dev/null)
    _extract_paste_fields "$_history_entry" "$_history_task"   # W71-F1: display-referenced entry, never .[0]
    [ -n "$_history_task" ] && [ "$_history_task" != "null" ] && _history_strategy="sid-only"
  fi
fi

# Strategy D (W25-F10): SID-FREE — most recent /v-prefixed line within the
# last 30 seconds, regardless of sessionId. This handles the case where SID
# resolution is racing with Claude Code's actual session id (env may have been
# set at SessionStart but Claude Code is now using a different SID internally,
# so SID-filtered queries return nothing). Cross-session risk is bounded
# because we require a /v prefix AND a tight 30s window — if a parallel
# session also typed /v in the same 30s window, we'd take the most recent,
# which is at worst the wrong /v call from a clearly active parallel session.
# Better than completely failing recovery.
#
# H4-13 (PLAN_2026-07-02_orchestrator-hardening-4): a fresh /v session's Step -3 once resolved a
# STALE cross-project terminal snippet (a recap from another session) via this exact fallback — the 30s+/v-prefix
# window has NO project scope, so ANY terminal typing "/v ..." anywhere on the machine in that window
# qualifies. history.jsonl carries a `project` field (the absolute cwd the entry was typed from) —
# scope Strategy D to the CURRENT project root so a stale/cross-project entry can never match, even
# within the 30s window. (b) Staleness-vs-session-start: if THIS project already has a session-start
# marker from an earlier invocation in the same conversation (.v/tmp/session-start-*.txt), reject any
# candidate OLDER than that marker — Step -3 can re-run mid-session, and an old pre-session-start
# entry is never this invocation's task.
_h13_proj="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_h13_min_ms=""
_h13_marker=$(ls -t "$_h13_proj"/.v/tmp/session-start-*.txt 2>/dev/null | head -1)
if [ -n "$_h13_marker" ] && [ -f "$_h13_marker" ]; then
  _h13_mtime=$(stat -c %Y "$_h13_marker" 2>/dev/null || stat -f %m "$_h13_marker" 2>/dev/null)
  [ -n "$_h13_mtime" ] && _h13_min_ms=$(( _h13_mtime * 1000 ))
fi
if [ -z "$_history_task" ] && [ -s "$_HISTORY_FILE" ] && [ "$_HAVE_JQ" = "1" ]; then
  _now_ms=$(( $(date +%s) * 1000 ))
  _ms_window=$(( _now_ms - 30000 ))
  # W25-F19: drop partial first line, process line-by-line, take last match.
  _recovered_entry=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
    | tail -n +2 \
    | jq -cR --argjson tmin "$_ms_window" --arg proj "$_h13_proj" --argjson smin "${_h13_min_ms:-0}" \
        'fromjson? | select(.display | type=="string") | select(.display | startswith("/v")) | select(.timestamp >= $tmin) | select(.project == $proj) | select($smin == 0 or .timestamp >= $smin)' \
        2>/dev/null | tail -1)
  if [ -n "$_recovered_entry" ] && [ "$_recovered_entry" != "null" ]; then
    _history_task=$(echo "$_recovered_entry" | jq -r '.display')
    _extract_paste_fields "$_recovered_entry" "$_history_task"   # W71-F1: display-referenced entry, never .[0]
    _recovered_sid=$(echo "$_recovered_entry" | jq -r '.sessionId // empty')
    _history_strategy="sid-free-30s-vprefix"
    # W25-F26b: Strategy D's SID-MISMATCH correction is ONLY safe when the
    # current _SID came from a contamination-prone source. When _SID was
    # resolved from CLAUDE_CODE_SESSION_ID env (per-process, contamination-
    # proof) or legacy CLAUDE_SESSION_ID env, DO NOT override it — even if
    # history.jsonl shows a different SID for the latest /v in this project.
    # That "different SID" is a parallel session's typing; trusting it would
    # silently route THEIR task into THIS session.
    if [ -n "$_recovered_sid" ] && [ "$_recovered_sid" != "$_SID" ]; then
      case "$_SID_SOURCE" in
        *"CLAUDE_CODE_SESSION_ID env"*|*"CLAUDE_SESSION_ID env"*)
          echo "W25-F26b-SID-MISMATCH-IGNORED: env-resolved SID=$_SID is authoritative; ignoring history.jsonl candidate $_recovered_sid (parallel session)"
          # Do NOT override _SID. Also clear _history_task because it belongs to a different session.
          _history_task=""
          _history_paste_hash=""
          _history_inline_content=""   # else a parallel session's inline paste body leaks into this session
          ;;
        *)
          echo "W25-F10-SID-MISMATCH: env-unavailable; correcting to history.jsonl authoritative SID=$_recovered_sid (was $_SID from $_SID_SOURCE)"
          _SID="$_recovered_sid"
          # Re-query the SID-scoped PreToolUse capture with the corrected SID
          _CAPTURE_RECOVER="$HOME/.claude/runtime/last-skill-args-${_SID}.txt"
          if [ -s "$_CAPTURE_RECOVER" ]; then
            _CAPTURE="$_CAPTURE_RECOVER"
            _args=$(awk '/^---ARGS-BEGIN---$/{f=1;next} /^---ARGS-END---$/{f=0} f' "$_CAPTURE")
            _prompt=$(awk '/^---PROMPT-BEGIN---$/{f=1;next} /^---PROMPT-END---$/{f=0} f' "$_CAPTURE")
            _stripped_args=$(printf '%s' "$_args" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
            _stripped_prompt=$(printf '%s' "$_prompt" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
            echo "W25-F10-RECOVERED-CAPTURE: $_CAPTURE_RECOVER (args=${#_args} prompt=${#_prompt})"
          fi
          ;;
      esac
    fi
  fi
fi

if [ -n "$_history_task" ] && [ "$_history_task" != "null" ]; then
  _history_src="$_HISTORY_FILE [strategy=$_history_strategy]"
else
  _history_task=""
fi

# === W25-F18: history.jsonl flush-race retry ===
# Claude Code writes to history.jsonl asynchronously; on a fresh /v invocation
# the user's just-typed line may not be flushed yet. If all 4 strategies came
# back empty AND history.jsonl exists, sleep briefly and re-attempt Strategy D
# (SID-free 30s + /v-prefix) once. Bounds added latency to 200ms.
# If the retry succeeds with a different sessionId than _SID, also re-query the
# PreToolUse capture under the corrected SID (mirrors Strategy D block).
if [ -z "$_history_task" ] && [ -s "$_HISTORY_FILE" ] && [ "$_HAVE_JQ" = "1" ]; then
  sleep 0.2
  _now_ms=$(( $(date +%s) * 1000 ))
  _ms_window=$(( _now_ms - 30000 ))
  # H4-13: same project-scope + session-start-staleness guard as the primary Strategy D block
  # above — this is a near-duplicate retry of that same query, and was NOT covered by the first
  # fix (a distinct code path, easy to miss — confirmed by a live repro during test-writing: the
  # first fix alone did not close the leak because THIS retry block still ran unscoped).
  _h13_proj="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _h13_min_ms=""
  _h13_marker=$(ls -t "$_h13_proj"/.v/tmp/session-start-*.txt 2>/dev/null | head -1)
  if [ -n "$_h13_marker" ] && [ -f "$_h13_marker" ]; then
    _h13_mtime=$(stat -c %Y "$_h13_marker" 2>/dev/null || stat -f %m "$_h13_marker" 2>/dev/null)
    [ -n "$_h13_mtime" ] && _h13_min_ms=$(( _h13_mtime * 1000 ))
  fi
  # W25-F19: drop partial first line, process line-by-line, take last match.
  _recovered_entry=$(tail -c 200000 "$_HISTORY_FILE" 2>/dev/null \
    | tail -n +2 \
    | jq -cR --argjson tmin "$_ms_window" --arg proj "$_h13_proj" --argjson smin "${_h13_min_ms:-0}" \
        'fromjson? | select(.display | type=="string") | select(.display | startswith("/v")) | select(.timestamp >= $tmin) | select(.project == $proj) | select($smin == 0 or .timestamp >= $smin)' \
        2>/dev/null | tail -1)
  if [ -n "$_recovered_entry" ] && [ "$_recovered_entry" != "null" ]; then
    _history_task=$(echo "$_recovered_entry" | jq -r '.display')
    _extract_paste_fields "$_recovered_entry" "$_history_task"   # W71-F1: display-referenced entry, never .[0]
    _recovered_sid=$(echo "$_recovered_entry" | jq -r '.sessionId // empty')
    _history_strategy="post-flush-retry-30s-vprefix"
    _history_src="$_HISTORY_FILE [strategy=$_history_strategy]"
    echo "W25-F18-RECOVERY=succeeded after 200ms flush wait"
    if [ -n "$_recovered_sid" ] && [ "$_recovered_sid" != "$_SID" ]; then
      # W25-F26b: same protection as Strategy D — env-resolved SID is authoritative
      case "$_SID_SOURCE" in
        *"CLAUDE_CODE_SESSION_ID env"*|*"CLAUDE_SESSION_ID env"*)
          echo "W25-F18-SID-MISMATCH-IGNORED: env-resolved SID=$_SID is authoritative; ignoring post-flush history.jsonl candidate $_recovered_sid (parallel session)"
          # Discard the recovered task — it belongs to the other session
          _history_task=""
          _history_paste_hash=""       # W-perf4 review (codex+logic): else the parallel session's
                                       # contentHash survives and drives the paste-cache scan (line ~371)
                                       # into THEIR paste-cache file → cross-session task contamination
                                       # (matches the Strategy-D discard site above; this sibling omitted it).
          _history_inline_content=""   # else a parallel session's inline paste body leaks into this session
          _history_strategy=""
          ;;
        *)
          echo "W25-F18-SID-CORRECTED-POST-FLUSH=$_recovered_sid (was $_SID from $_SID_SOURCE)"
          _SID="$_recovered_sid"
          # Mirror Strategy D: re-query the PreToolUse capture under the new SID
          # so $_args/$_prompt/$_stripped_args reflect the correct session's data.
      _CAPTURE_RECOVER="$HOME/.claude/runtime/last-skill-args-${_SID}.txt"
      if [ -s "$_CAPTURE_RECOVER" ]; then
        _CAPTURE="$_CAPTURE_RECOVER"
        _args=$(awk '/^---ARGS-BEGIN---$/{f=1;next} /^---ARGS-END---$/{f=0} f' "$_CAPTURE")
        _prompt=$(awk '/^---PROMPT-BEGIN---$/{f=1;next} /^---PROMPT-END---$/{f=0} f' "$_CAPTURE")
        _stripped_args=$(printf '%s' "$_args" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
        _stripped_prompt=$(printf '%s' "$_prompt" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
        echo "W25-F18-RECOVERED-CAPTURE: $_CAPTURE_RECOVER (args=${#_args} prompt=${#_prompt})"
      fi
          ;;
      esac
    fi
  fi
fi



# === Channel 6 (W25-F12): paste-cache scan for large pastes ===
# Claude Code stores multi-line pastes at ~/.claude/paste-cache/<hash>.txt at
# PASTE TIME — before the slash command even dispatches. So this file exists
# regardless of which hooks fire, which SID is current, or whether
# history.jsonl has flushed. For users who paste large bug-hunt reports as
# the /v body, this is the most reliable recovery source.
#
# Strategy: find the most recent paste-cache file modified within the last
# 60 seconds. If found, treat its content as the user's task content.
# Cross-session risk is bounded: paste-cache filenames are content-hashed,
# so even if another session pasted simultaneously, the latest mtime is the
# user's most recent paste in *this* terminal session 99% of the time.
_PASTE_CACHE_DIR="$HOME/.claude/paste-cache"
_paste_task=""
_paste_src=""
_foreign_claim=""        # W71-F1: set when the referenced paste is claimed by a sibling SID
_foreign_claim_kind=""   # W71-review M4: "shared" (own SID-scoped entry) vs "foreign" (sid-free recovery)
# W25-F22: only consult paste-cache if THIS user's history.jsonl entry has a
# non-empty pastedContents hash. Use that hash directly — never "latest by mtime"
# (which contaminated sessions with stale pastes from earlier reports in 2026-05-11).
if [ -d "$_PASTE_CACHE_DIR" ] && [ -n "$_history_paste_hash" ]; then
  _latest_paste="$_PASTE_CACHE_DIR/${_history_paste_hash}.txt"
  echo "W25-F22-PASTE-CACHE-HASH=$_history_paste_hash (from user's history entry, NOT latest-by-mtime)"
  if [ -n "$_latest_paste" ] && [ -s "$_latest_paste" ]; then
    # Verify it's recent (<60s old). Platform-detect: BSD stat -f vs GNU stat -c
    # (same flag means different things — feature-detect-by-exit-code fails
    # because GNU `stat -f` succeeds and prints filesystem info).
    _now=$(date +%s)
    if [ "$_USE_BSD_STAT" = "1" ]; then
      _mtime=$(stat -c '%Y' "$_latest_paste" 2>/dev/null || stat -f '%m' "$_latest_paste" 2>/dev/null || echo 0)
    else
      _mtime=$(stat -c '%Y' "$_latest_paste" 2>/dev/null || echo 0)
    fi
    if [ "$_mtime" -gt 0 ] 2>/dev/null && [ $((_now - _mtime)) -lt 60 ]; then
      # === W25-F14 SID-CLAIM CHECK: prevent cross-session paste-cache leakage ===
      # If another session has claimed this paste within the last 60s (matches
      # the paste-freshness window above), this isn't our paste. Skip it.
      _hash=$(basename "$_latest_paste" .txt)
      _own_marker="$_PASTE_CACHE_DIR/.claimed-${_hash}-${_SID:-unknown}"
      _conflict=""
      # Use `find` instead of glob to avoid literal-glob expansion when no markers exist
      while IFS= read -r _m; do
        [ -z "$_m" ] && continue
        # Extract SID from filename. Format: .claimed-<hash>-<SID>
        # SID is a UUID with dashes; basename + sed to strip the .claimed-<hash>- prefix.
        _other_sid=$(basename "$_m" | sed -E 's/^\.claimed-[^-]+-//')
        if [ -n "$_other_sid" ] && [ "$_other_sid" != "${_SID:-unknown}" ]; then
          if [ "$_USE_BSD_STAT" = "1" ]; then
            _m_mtime=$(stat -c '%Y' "$_m" 2>/dev/null || stat -f '%m' "$_m" 2>/dev/null || echo 0)
          else
            _m_mtime=$(stat -c '%Y' "$_m" 2>/dev/null || echo 0)
          fi
          _m_age=$(( _now - _m_mtime ))
          if [ "$_m_age" -lt 60 ]; then
            _conflict="${_m_age}s ago by SID=${_other_sid}"
            break
          fi
        fi
      done < <(find "$_PASTE_CACHE_DIR" -maxdepth 1 -name ".claimed-${_hash}-*" 2>/dev/null)
      if [ -n "$_conflict" ]; then
        echo "W25-F14-PASTE-SKIPPED=$_latest_paste (claimed $_conflict)"
        _foreign_claim="$_conflict"   # W71-F1: remembered so the empty-task branch can block loudly
        # W71-review M4: provenance-graded guidance. When the hash came from THIS
        # session's OWN (SID-scoped) history entry, a sibling claim on the SAME
        # content usually means the same pack text was pasted into two terminals —
        # a legitimate duplicate, not contamination. Still never read the claimed
        # file (conservative), but route to Channel 5 instead of a hard stop.
        case "$_history_strategy" in
          sid-free-*|post-flush-*) _foreign_claim_kind="foreign" ;;
          *)                       _foreign_claim_kind="shared" ;;
        esac
      else
        # Claim this paste for this SID before reading
        touch "$_own_marker" 2>/dev/null || true
        # W25-F12b: bound the read to 200KB to prevent ARG_MAX overruns on huge pastes
        _paste_task=$(head -c 200000 "$_latest_paste" 2>/dev/null || true)
        _paste_src="$_latest_paste"
        echo "W25-F12-PASTE-CACHE-PATH=$_paste_src"
        echo "W25-F12-PASTE-CACHE-LENGTH=${#_paste_task}"
        echo "W25-F12-PASTE-CACHE-AGE_SEC=$((_now - _mtime))"
        echo "W25-F14-CLAIMED-MARKER=$_own_marker"
      fi
    fi
  fi
fi

# === Channel 4: SID-scoped UserPromptSubmit capture ===
_userprompt_sid="$HOME/.claude/runtime/last-user-prompt-${_SID}.txt"
_userprompt=""
_userprompt_src=""
if [ -n "$_SID" ] && [ -s "$_userprompt_sid" ]; then
  _userprompt=$(cat "$_userprompt_sid" 2>/dev/null || true)
  _userprompt_src="$_userprompt_sid"
fi

# Pick fallback (priority order):
# 1. paste-cache — if it was triggered by a non-empty pastedContents hash on the
#    user's OWN history entry, this is the literal paste content. History.jsonl's
#    display field for that entry is just a placeholder like "Fix [Pasted text
#    #1 +N lines]" — useless for routing. Paste-cache wins. (T16 fix)
# 2. history.jsonl — the user's typed line (no paste involved).
# 3. user-prompt-fallback — SID-scoped UserPromptSubmit capture (legacy).
_fallback_task=""
_fallback_src=""
_fallback_tag=""
if [ -n "$_paste_task" ]; then
  _fallback_task="$_paste_task"
  _fallback_src="$_paste_src"
  _fallback_tag="paste-cache"
elif [ -n "$_history_inline_content" ]; then
  # FORMAT B (small inline paste, <~1KB): Claude Code stores the paste BODY INLINE
  # in history.jsonl (.pastedContents[].content) with NO contentHash — so the
  # paste-cache branch above never fires (it keys on the hash) and .display is just
  # the "[Pasted text #1 +N lines]" placeholder that strips to empty. This tier
  # surfaces the REAL task text (the inline content), SID-scoped via the same
  # history query that found the entry (and cleared on SID-mismatch above). Without
  # it, /v silently resolves to the placeholder and the model hallucinates an
  # unrelated task while claiming success (three production sessions).
  _fallback_task="$_history_inline_content"
  _fallback_src="$_HISTORY_FILE [inline-content strategy=$_history_strategy]"
  _fallback_tag="history-jsonl-inline"
elif [ -n "$_history_task" ]; then
  _fallback_task="$_history_task"
  _fallback_src="$_history_src"
  _fallback_tag="history-jsonl"
elif [ -n "$_userprompt" ]; then
  _fallback_task="$_userprompt"
  _fallback_src="$_userprompt_src"
  _fallback_tag="user-prompt-fallback"
fi

# Strip leading /v — P1-3: BSD-sed safe (two passes, no \| alternation)
_fallback_task_stripped=$(printf '%s' "$_fallback_task" | sed -E 's|^[[:space:]]*/v[[:space:]]+||; s|^[[:space:]]*/v$||')
_stripped_fallback=$(printf '%s' "$_fallback_task_stripped" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')

echo "W25-F9-HAVE_JQ=$_HAVE_JQ"
echo "W25-F9-FALLBACK_PATH=$_fallback_src"
echo "W25-F9-FALLBACK_LENGTH=${#_fallback_task}"
echo "W25-F9-FALLBACK_TAG=$_fallback_tag"

# === Final routing ===
echo "---TASK-BEGIN---"
if [ -n "$_stripped_args" ]; then
  printf '%s' "$_args"
  echo
  echo "---TASK-SOURCE=args---"
elif [ -n "$_stripped_prompt" ]; then
  printf '%s' "$_prompt"
  echo
  echo "---TASK-SOURCE=prompt---"
elif [ -n "$_stripped_fallback" ]; then
  printf '%s' "$_fallback_task_stripped"
  echo
  echo "---TASK-SOURCE=$_fallback_tag---"
else
  echo "---TASK-SOURCE=empty---"
  if [ "$_HAVE_JQ" = "0" ]; then
    echo "W25-F9-WARNING=jq not installed — history.jsonl recovery channel was disabled. Install jq (brew install jq) for full prompt-recovery resilience."
  fi
fi
echo "---TASK-END---"

# W71-F1 (forensic 2026-07-02): when the ONLY recoverable candidate is a paste
# claimed by a sibling session, say so LOUDLY. The 2026-07-02 fleet incident:
# two sessions saw this exact skip, then improvised from shared caches and
# executed the sibling's task behind a passing gauntlet. Detection without a
# stop order is theatre — this is the stop order.
if [ -z "$_stripped_args" ] && [ -z "$_stripped_prompt" ] && [ -z "$_stripped_fallback" ] && [ -n "$_foreign_claim" ]; then
  if [ "${_foreign_claim_kind:-foreign}" = "shared" ]; then
    echo "W25-F14-SHARED=this session's OWN history entry references a paste already claimed by a sibling /v session ($_foreign_claim) — most likely the SAME pack text pasted into multiple terminals. Do NOT read the claimed cache file. The paste content IS visible in THIS conversation (the user pasted it here) — recover the task from the conversation context (Channel 5) and proceed normally. Only if it is NOT visible: STOP and write BLOCKED_${_SID:-unknown}.md asking the user to restate the task."
  else
    echo "W25-F14-BLOCKED=this session's task could not be recovered and the only candidate paste is claimed by a sibling /v session ($_foreign_claim). DO NOT adopt that paste and DO NOT scan shared caches (paste-cache, history.jsonl, runtime/) for a substitute task. Recover the task ONLY from THIS conversation's visible context (Channel 5); if it is not visible, STOP and write BLOCKED_${_SID:-unknown}.md asking the user to restate the task."
  fi
fi

# === W25-F13b: Persist the resolved task for Step 0 (W63-revised) ===
# Bash tool calls do NOT share variable state. Step 0's W25-F13
# autonomous project-root recovery needs the resolved task text; we serialize
# it here so Step 0 can read it from disk. SID-scoped only (W63): if SID is
# unresolved we skip persistence entirely — Step 0 then recovers the task from
# conversation context. The previous v-resolved-task-LATEST fallback was a
# cross-session contamination vector (last-writer-wins under parallel /v
# sessions) and was removed.
_RESOLVED_TASK_DIR="$HOME/.claude/runtime"
mkdir -p "$_RESOLVED_TASK_DIR" 2>/dev/null || true
if [ -n "$_SID" ]; then
  _RESOLVED_TASK_FILE="$_RESOLVED_TASK_DIR/v-resolved-task-${_SID}.txt"
else
  _RESOLVED_TASK_FILE=""
  echo "W63: STEP-3 WARNING — session_id unresolved; task persistence skipped (Step 0 will recover from conversation context)" >&2
fi
# Pick whichever channel actually carried the task. Prefer args/prompt
# (unstripped — Step 0 doesn't care about the /v prefix when extracting paths).
_persist=""
if [ -n "$_stripped_args" ]; then
  _persist="$_args"
elif [ -n "$_stripped_prompt" ]; then
  _persist="$_prompt"
elif [ -n "$_stripped_fallback" ]; then
  _persist="$_fallback_task_stripped"
fi
# W71-F1 persist guard: never persist a placeholder-only "task" (the 26-byte
# v-resolved-task-<sid>.txt incident, 3 of 4 fleet sessions on 2026-07-02).
# Belt over the strip-regex fix above — no downstream consumer (Step 0,
# check-review-artifact) may ever read a bare placeholder as the session task.
if [ -n "$_persist" ]; then
  _persist_check=$(printf '%s' "$_persist" | sed -E 's/\[Image #[0-9]+\]//g; s/\[Pasted text #[0-9]+( \+[0-9]+ lines)?\]//g' | tr -d '[:space:]')
  if [ -z "$_persist_check" ]; then
    echo "W71-F1-PERSIST-REFUSED=placeholder-only resolution not persisted"
    _persist=""
  fi
fi
if [ -n "$_persist" ] && [ -n "$_RESOLVED_TASK_FILE" ]; then  # W63: prevent literal .tmp file when SID empty
  printf '%s' "$_persist" > "${_RESOLVED_TASK_FILE}.tmp" 2>/dev/null && \
    mv "${_RESOLVED_TASK_FILE}.tmp" "$_RESOLVED_TASK_FILE" 2>/dev/null || true
  echo "W25-F13b-PERSISTED-TASK=$_RESOLVED_TASK_FILE (${#_persist} bytes)"
fi

# === W68: recovery trace log (JSONL + flock; race-safe) ===
_W68_TRACE_LOG="$HOME/.claude/runtime/v-task-recovery-${_SID:-unknown}.log"
mkdir -p "$(dirname "$_W68_TRACE_LOG")" 2>/dev/null || true
{
  _task_hash=$(printf '%s' "${_args:-${_prompt:-${_fallback_task:-}}}" | shasum -a 256 2>/dev/null | cut -c1-12)
  _rejected_json="${_REJECTED_CHANNELS:-[]}"
  _trace_line=$(python3 -c "
import json, sys, datetime
print(json.dumps({
  'ts': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
  'sid': '${_SID:-unknown}',
  'source': '${_SID_SOURCE:-unknown}',
  'task_hash': '${_task_hash:-none}',
}))
" 2>/dev/null)
  if [ -n "$_trace_line" ]; then
    # flock guards concurrent /v invocations writing to same log
    ( flock -x 200; echo "$_trace_line" >> "$_W68_TRACE_LOG" ) 200>"$_W68_TRACE_LOG.lock" 2>/dev/null || true
  fi
} 2>/dev/null || true
# === end W68 ===
