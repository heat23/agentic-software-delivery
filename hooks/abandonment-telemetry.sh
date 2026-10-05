#!/usr/bin/env bash
# abandonment-telemetry.sh
# Event: Stop
# Version: 1.0.0
# Purpose: UNCONDITIONAL append-only logging of every Stop event.
#   Captures the state of (SID, /v-in-history, artifacts-present, session-writes-count,
#   stop_hook_active flag, last_msg_snippet) regardless of whether anyone or any other
#   hook acts on it. Provides ground truth for telemetry — answers questions like
#   "did Stop fire for SID X" that we currently cannot answer.
#
# NEVER BLOCKS. Always exits 0. Failures are silent (best-effort).
# Output: ~/.claude/abandonments.jsonl (append-only, one JSON object per line)
#
# Designed to be the FIRST Stop hook so its data captures the pre-block state.
#
# Adversarial property: the model cannot prevent this hook from running.
# Claude Code fires hooks; the model's hallucination of tool output does not affect
# whether the hook ran. The line we write reflects on-disk reality.
set -euo pipefail


# === R3 defensive: tolerate malformed JSON ===
set +e

# Resolve lib path
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

if [ -f "$HOOKS_LIB_DIR/require-jq.sh" ]; then
  source "$HOOKS_LIB_DIR/require-jq.sh"
  require_jq_or_skip
fi

# Read JSON input
INPUT=$(cat 2>/dev/null || echo '{}')

# Extract fields (best-effort, fall back to empty)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
SID="${SID:-${CLAUDE_SESSION_ID:-unknown}}"
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null || echo "")
LAST_MSG_SNIPPET=$(printf '%s' "$LAST_MSG" | head -c 200 | tr -d '\n\r' | head -c 200)

# Compute facts about the session
# Item 24 (2026-07-03, a silent non-git-root hole): git rev-parse returns empty for a NON-GIT root (e.g.
# ~/.claude itself is not a git repo — confirmed on disk). Every fact below, and the LAYER-4
# ABANDONED_<sid>.md marker write further down, was gated on REPO_ROOT being non-empty — so a
# code-writing session rooted in a non-git directory produced NO facts and NO marker at all, a
# totally silent hole (the exact incident: a session in ~/.claude couldn't write markers). Fall
# back to CLAUDE_PROJECT_DIR / PWD — the SAME convention already used elsewhere in hooks/ (e.g.
# block-fork-agent-dispatch.sh, fork-payload-guard.sh: `git rev-parse --show-toplevel || echo
# "${CLAUDE_PROJECT_DIR:-$PWD}"`) — so this hook's behavior in a non-git root matches its siblings
# instead of being uniquely blind. A non-git REPO_ROOT is marked via IS_GIT_ROOT=0 so downstream
# writes-detection can apply the non-git fallback (below) instead of the git-only ledger.
IS_GIT_ROOT=1
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
  IS_GIT_ROOT=0
  REPO_ROOT="${CLAUDE_PROJECT_DIR:-${PWD:-}}"
fi
V_IN_HISTORY=0
if [ -n "$SID" ] && [ -f "$HOME/.claude/history.jsonl" ]; then
  if grep -F "\"sessionId\":\"$SID\"" "$HOME/.claude/history.jsonl" 2>/dev/null \
     | grep -qE '"display":"/v[ "]' 2>/dev/null; then
    V_IN_HISTORY=1
  fi
fi

ARTIFACTS_COUNT=0
if [ -n "$REPO_ROOT" ] && [ -n "$SID" ]; then
  # W5G-6c: include `.v/artifacts` — W-perf6 consolidation moves artifacts there;
  # a root-only count under-reports gated sessions as artifact-less abandonment
  # (a previously-fixed class, recurring in a telemetry-only consumer).
  ARTIFACTS_COUNT=$(ls "$REPO_ROOT"/PRE_FLIGHT_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/AGENT_REVIEW_*"$SID"*.md \
                       "$REPO_ROOT"/VERIFY_DONE_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/IMPLEMENTATION_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/HANDOFF_*"$SID"*.md \
                       "$REPO_ROOT"/TRIVIAL_PASS_*"$SID"*.md \
                       "$REPO_ROOT"/PLANNING_PASS_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/PRE_FLIGHT_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/AGENT_REVIEW_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/VERIFY_DONE_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/IMPLEMENTATION_REPORT_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/HANDOFF_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/TRIVIAL_PASS_*"$SID"*.md \
                       "$REPO_ROOT"/.v/artifacts/PLANNING_PASS_*"$SID"*.md \
                       2>/dev/null | wc -l | tr -d ' ')
fi

# Session writes log (track-session-writes.sh writes per-Bash-tool-use into .git/)
WRITES_COUNT=0
WRITES_HAS_CODE=0
GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
if [ -n "$GIT_COMMON_DIR" ] && [ -n "$SID" ]; then
  WRITES_FILE="${GIT_COMMON_DIR}/claude-session-writes-${SID}.txt"
  if [ -f "$WRITES_FILE" ]; then
    WRITES_COUNT=$(wc -l < "$WRITES_FILE" 2>/dev/null | tr -d ' ')
    if grep -qE '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)$' "$WRITES_FILE" 2>/dev/null; then
      WRITES_HAS_CODE=1
    fi
  fi
elif [ "$IS_GIT_ROOT" -eq 0 ] && [ -n "$SID" ] && [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]; then
  # Item 24 non-git fallback: track-session-writes.sh's ledger is ANCHORED to git-common-dir by
  # design (survives cwd changes between main/worktrees) and writes NOTHING in a non-git root — a
  # gap outside this hook's ownership. Substitute a git-independent signal: session-start-marker.sh
  # (a SessionStart hook, unconditional, no git dependency) writes a per-SID start timestamp under
  # $REPO_ROOT/.v/tmp regardless of git status. Compare that marker's mtime against code files
  # under REPO_ROOT — any changed strictly AFTER session start is this session's most likely
  # candidate for "wrote code" in the absence of a real ledger. Bounded (maxdepth 4, prunes
  # vendor/node_modules/.git/.v to stay cheap) and advisory-only — never blocks, only feeds the
  # SAME best-effort telemetry this hook already emits for the git case.
  _V_START_MARKER="$REPO_ROOT/.v/tmp/session-start-${SID}.txt"
  if [ -f "$_V_START_MARKER" ]; then
    _v_start_epoch=$(stat -c %Y "$_V_START_MARKER" 2>/dev/null || stat -f %m "$_V_START_MARKER" 2>/dev/null || echo 0)
    if [ -n "$_v_start_epoch" ] && [ "$_v_start_epoch" -gt 0 ] 2>/dev/null; then
      _ng_hits=$(find "$REPO_ROOT" -maxdepth 4 \
                   \( -path '*/.git' -o -path '*/.v' -o -path '*/vendor' -o -path '*/node_modules' -o -path '*/.attic' \) -prune -o \
                   -type f -newer "$_V_START_MARKER" \
                   \( -iname '*.php' -o -iname '*.ts' -o -iname '*.tsx' -o -iname '*.js' -o -iname '*.jsx' \
                      -o -iname '*.vue' -o -iname '*.svelte' -o -iname '*.py' -o -iname '*.rb' -o -iname '*.go' \
                      -o -iname '*.rs' -o -iname '*.sh' \) -print 2>/dev/null | head -50)
      if [ -n "$_ng_hits" ]; then
        WRITES_COUNT=$(printf '%s\n' "$_ng_hits" | grep -c . 2>/dev/null || echo 0)
        WRITES_HAS_CODE=1
      fi
    fi
  fi
fi

# === L4: SESSION_LOG attestation quality check ===
# For each SESSION_LOG_*.yaml found in REPO_ROOT, check if a recent attestation
# exists in ~/.claude/runtime/. Missing attestation = "likely model hallucination."
# Recent = within last 1 hour (sessions typically run /v-session-log near end).
SESSION_LOG_QUALITY="not_checked"
SESSION_LOGS_PRESENT=0
SESSION_LOGS_WITH_ATTESTATION=0
if [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT" ]; then
  for _yaml in "$REPO_ROOT"/SESSION_LOG_*.yaml; do
    [ -f "$_yaml" ] || continue
    SESSION_LOGS_PRESENT=$((SESSION_LOGS_PRESENT + 1))
    # Extract SID from filename
    _yaml_sid=$(basename "$_yaml" .yaml | sed 's/^SESSION_LOG_//')
    _att="$HOME/.claude/runtime/v-session-log-attestation-${_yaml_sid}.json"
    if [ -f "$_att" ]; then
      # Check attestation is recent (last 4 hours = 14400s) and references this yaml
      _att_mtime=$(stat -c %Y "$_att" 2>/dev/null || stat -f %m "$_att" 2>/dev/null || echo 0)
      _yaml_mtime=$(stat -c %Y "$_yaml" 2>/dev/null || stat -f %m "$_yaml" 2>/dev/null || echo 0)
      _now=$(date -u +%s)
      _att_age=$(( _now - _att_mtime ))
      # Attestation must be present AND within 4 hours of YAML mtime
      _yaml_att_diff=$(( _yaml_mtime > _att_mtime ? _yaml_mtime - _att_mtime : _att_mtime - _yaml_mtime ))
      if [ "$_yaml_att_diff" -lt 14400 ] && grep -q '"nonce"' "$_att" 2>/dev/null; then
        SESSION_LOGS_WITH_ATTESTATION=$((SESSION_LOGS_WITH_ATTESTATION + 1))
      fi
    fi
  done
  if [ "$SESSION_LOGS_PRESENT" -eq 0 ]; then
    SESSION_LOG_QUALITY="no_logs"
  elif [ "$SESSION_LOGS_WITH_ATTESTATION" -eq "$SESSION_LOGS_PRESENT" ]; then
    SESSION_LOG_QUALITY="all_attested"
  elif [ "$SESSION_LOGS_WITH_ATTESTATION" -eq 0 ]; then
    SESSION_LOG_QUALITY="none_attested_likely_hallucinated"
  else
    SESSION_LOG_QUALITY="partial"
  fi
fi
# === L4 end ===

# Compose JSON line
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOG_FILE="$HOME/.claude/abandonments.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

# RC-6 (item 25, forensic 2026-07-03: a session's missed bite): compute the shape in bash
# (single-sourced, also feeds the marker-write decision below) rather than only inside the
# jq filter, where it was previously invisible to anything but a manual jsonl read — no one
# polls abandonments.jsonl, so "dead fork with file mutations and no return" (v_in_history=1,
# writes_has_code=1, artifacts=0 — i.e. it wrote code but never reached a gate artifact) left
# NO durable, git-status-visible record. abandonment-telemetry.sh is registered FIRST under
# Stop (stop-drain-wiring-test.sh), so this fires before any blocking gate can starve it.
ABANDONMENT_SHAPE="complete"
if [ "$V_IN_HISTORY" -eq 1 ] && [ "$WRITES_HAS_CODE" -eq 1 ] && [ "$ARTIFACTS_COUNT" -eq 0 ]; then
  ABANDONMENT_SHAPE="abandoned-with-code"
elif [ "$V_IN_HISTORY" -eq 1 ] && [ "$ARTIFACTS_COUNT" -eq 0 ]; then
  ABANDONMENT_SHAPE="abandoned-no-artifacts"
elif [ "$V_IN_HISTORY" -eq 0 ]; then
  ABANDONMENT_SHAPE="non-v-session"
fi

# Atomic append: write to temp then cat onto the log
# (Multiple Stop hooks can fire in parallel session contexts; append is safe but
# we use a tmp+cat pattern to avoid partial writes under contention.)
LINE=$(jq -nc \
  --arg ts "$NOW" \
  --arg sid "$SID" \
  --arg stop_active "$STOP_HOOK_ACTIVE" \
  --argjson v_history "$V_IN_HISTORY" \
  --argjson artifacts "$ARTIFACTS_COUNT" \
  --argjson writes_count "$WRITES_COUNT" \
  --argjson writes_has_code "$WRITES_HAS_CODE" \
  --arg repo "${REPO_ROOT:-unknown}" \
  --arg msg "$LAST_MSG_SNIPPET" \
  --arg sl_quality "$SESSION_LOG_QUALITY" \
  --argjson sl_present "${SESSION_LOGS_PRESENT:-0}" \
  --argjson sl_attested "${SESSION_LOGS_WITH_ATTESTATION:-0}" \
  --arg shape "$ABANDONMENT_SHAPE" \
  '{
    ts: $ts,
    sid: $sid,
    stop_hook_active: ($stop_active == "true"),
    v_in_history: ($v_history == 1),
    artifacts_count: $artifacts,
    session_writes_count: $writes_count,
    session_writes_has_code: ($writes_has_code == 1),
    repo: $repo,
    last_msg_snippet: $msg,
    session_log_quality: $sl_quality,
    session_logs_present: $sl_present,
    session_logs_attested: $sl_attested,
    abandonment_shape: $shape
  }' 2>/dev/null || echo "{}")

if [ -n "$LINE" ] && [ "$LINE" != "{}" ]; then
  # flock-style append (single writer at a time)
  (
    if command -v flock >/dev/null 2>&1; then
      flock -w 2 -x 9 2>/dev/null
    fi
    printf '%s\n' "$LINE" >> "$LOG_FILE"
  ) 9>"${LOG_FILE}.lock" 2>/dev/null
  rm -f "${LOG_FILE}.lock" 2>/dev/null || true
fi

# === RC-6: durable ABANDONED_<sid> marker (item 25) ===
# A jsonl line nobody polls is not a durable record. When THIS Stop event observes the
# "abandoned-with-code" shape (fork mutated tracked code, has session-writes evidence, but
# reached no gate artifact), leave a git-status-visible ABANDONED_<SID>.md marker at the repo
# root — the same convention as SESSION_LOG_MISSING_<sid>.md, so existing sweeps/resolvers that
# already glob for uppercase marker files pick it up for free. Idempotent (skip rewrite if an
# identical-shape marker already exists — avoids mtime churn across repeated blocked-retry Stop
# events for the SAME still-running session) and self-correcting: auto-clears the moment a real
# artifact appears (mirrors every other MISSING-class marker in this codebase). Best-effort;
# never blocks (this hook always exits 0).
if [ -n "${REPO_ROOT:-}" ] && [ -n "${SID:-}" ] && [ "$SID" != "unknown" ]; then
  _abandoned_marker="$REPO_ROOT/ABANDONED_${SID}.md"
  if [ "$ABANDONMENT_SHAPE" = "abandoned-with-code" ]; then
    if [ ! -f "$_abandoned_marker" ]; then
      {
        printf '# ABANDONED SESSION WITH UNCOMMITTED/UNGATED CODE MUTATIONS — %s\n\n' "$SID"
        printf 'Session `%s` ran `/v` (v_in_history), has a non-empty session-writes log touching\n' "$SID"
        printf 'tracked source (session_writes_count=%s, includes code extensions), but reached NO\n' "$WRITES_COUNT"
        printf 'gate artifact (PRE_FLIGHT_REPORT / AGENT_REVIEW / VERIFY_DONE_REPORT / IMPLEMENTATION_REPORT /\n'
        printf 'HANDOFF / TRIVIAL_PASS / PLANNING_PASS) at Stop time. This is a dead-fork-with-mutations\n'
        printf 'shape (RC-6, forensic 2026-07-03: a session died mid-run this way with staged changes and\n'
        printf 'no telemetry) — the work may be real and stranded, not merely "read-only."\n\n'
        printf 'Remediation: inspect this session'"'"'s working tree/worktree for uncommitted or staged\n'
        printf 'changes before treating it as a no-op. If work exists, land it via the normal merge path;\n'
        printf 'if truly abandoned with nothing salvageable, delete this marker. Auto-clears the moment any\n'
        printf 'gate artifact for this SID appears (recorded %s).\n' "$NOW"
      } > "$_abandoned_marker" 2>/dev/null || true
    fi
  elif [ -f "$_abandoned_marker" ] && [ "$ARTIFACTS_COUNT" -gt 0 ]; then
    rm -f "$_abandoned_marker" 2>/dev/null || true
  fi
fi
# === end RC-6 ===

# Always exit 0 — telemetry never blocks completion
exit 0
