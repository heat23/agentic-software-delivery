#!/usr/bin/env bash
# protect-agent-review.sh
# Event: PreToolUse / Write|Edit
# Version: 1.0.0  (W43-N6 — prevent AGENT_REVIEW overwrite with stub)
#
# Production motivation: a production session (2026-05-03) showed:
#   1. codex-adversarial-reviewer wrote AGENT_REVIEW_<sid>.md with 109 lines:
#      FND-001 high (overbroad catch), FND-002 medium (retry storm),
#      FND-003 medium (Schema::hasColumn guard), FND-004 low (no test
#      coverage), FND-005 low (no observability) — Overall: FAIL.
#   2. Parent narrowed the try-catch (good).
#   3. Parent then OVERWROTE the AGENT_REVIEW with a 7-line stub:
#      "critical:0 high:0 medium:0 low:1 / Overall Verdict: PASS"
#      — silently discarding 4 findings the codex reviewer raised.
#
# That's a guardrail bypass: the human reads PASS and assumes review
# concerns were addressed. Several of the discarded findings (retry
# storm, missing Schema::hasColumn) were NOT addressed in the narrow
# catch fix.
#
# Fix: block any Write/Edit on AGENT_REVIEW that shrinks an existing
# substantial review by >50%, OR drops the FND-XXX finding lines.
# Append-only-style protection — parents are still free to ADD a
# "Resolution" section noting which findings were addressed.

# W44-E4 fix: relax to set -uo (no -e). Bad JSON makes jq exit non-zero;
# under set -e the hook aborts with rc=4/5 instead of failing open. Discovered
# by E2E scenario 23 (malformed input fuzz).
set -uo pipefail

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
case "$TOOL_NAME" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -z "$FILE" ] && exit 0

# Only act on AGENT_REVIEW_<sid>.md files
case "$FILE" in
  */AGENT_REVIEW_*.md|AGENT_REVIEW_*.md) ;;
  *) exit 0 ;;
esac

# If file doesn't exist yet, allow the first write (no prior review to protect)
if [ ! -f "$FILE" ]; then
  exit 0
fi

OLD_SIZE=$(wc -c < "$FILE" 2>/dev/null | tr -d ' ')
OLD_SIZE=${OLD_SIZE:-0}

# Trivial existing review (≤ 600 bytes, e.g., a stub the parent wrote
# pre-dispatch). Allow overwrite — the dispatched reviewer is replacing it.
if [ "$OLD_SIZE" -le 600 ]; then
  exit 0
fi

# Existing review is substantial. Determine the new content size.
NEW_CONTENT=""
if [ "$TOOL_NAME" = "Write" ]; then
  NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
elif [ "$TOOL_NAME" = "Edit" ]; then
  # Edit replaces old_string with new_string. Compute net size delta.
  OLD_STR=$(echo "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
  NEW_STR=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
  OLD_LEN=${#OLD_STR}
  NEW_LEN=${#NEW_STR}
  # Approximate post-edit size
  NEW_SIZE=$((OLD_SIZE - OLD_LEN + NEW_LEN))
  NEW_CONTENT="$(cat "$FILE" 2>/dev/null)"
  # Substring-replace check: if old_string isn't present, the Edit will
  # fail anyway — let it through.
  if ! grep -qF "$OLD_STR" "$FILE" 2>/dev/null; then
    exit 0
  fi
fi

# For Write: NEW_SIZE comes from content length
if [ "$TOOL_NAME" = "Write" ]; then
  NEW_SIZE=${#NEW_CONTENT}
fi

# Compute existing FND-XXX finding count (canonical pattern from codex/superpowers)
OLD_FND_COUNT=$(grep -cE '^[[:space:]]*(####[[:space:]]+)?FND-[0-9]+' "$FILE" 2>/dev/null || echo 0)
OLD_FND_COUNT=${OLD_FND_COUNT:-0}
OLD_FND_COUNT=$(echo "$OLD_FND_COUNT" | tr -d '\n ')

# Build the prospective new content for analysis
if [ "$TOOL_NAME" = "Write" ]; then
  PROSPECTIVE="$NEW_CONTENT"
else
  # W44-E5: Edit substitution via bash parameter expansion (replaces fragile
  # awk approach that didn't handle multi-line values correctly). Edit tool
  # does FIRST-occurrence replacement, so use ${var/old/new} (single slash).
  CURRENT=$(cat "$FILE" 2>/dev/null || echo "")
  PROSPECTIVE="${CURRENT/"$OLD_STR"/"$NEW_STR"}"
  # If substitution didn't change anything (old_string not found), fall back
  # to current — Edit will fail at the actual tool layer, hook is permissive.
  [ -z "$PROSPECTIVE" ] && PROSPECTIVE="$CURRENT"
  # Update NEW_SIZE based on actual substituted string length
  NEW_SIZE=${#PROSPECTIVE}
fi
NEW_FND_COUNT=$(echo "$PROSPECTIVE" | grep -cE '^[[:space:]]*(####[[:space:]]+)?FND-[0-9]+' 2>/dev/null || echo 0)
NEW_FND_COUNT=${NEW_FND_COUNT:-0}
NEW_FND_COUNT=$(echo "$NEW_FND_COUNT" | tr -d '\n ')

# Decision rules:
#   1. Size shrinking by > 50% → block
#   2. FND-XXX count decreasing → block (don't allow silent finding removal)
SIZE_THRESHOLD=$(( OLD_SIZE * 50 / 100 ))
SHOULD_BLOCK=0
BLOCK_REASON=""

if [ "$NEW_SIZE" -lt "$SIZE_THRESHOLD" ]; then
  SHOULD_BLOCK=1
  BLOCK_REASON="size shrinking from ${OLD_SIZE} bytes to ~${NEW_SIZE} bytes (>50% smaller)"
elif [ "$NEW_FND_COUNT" -lt "$OLD_FND_COUNT" ]; then
  SHOULD_BLOCK=1
  BLOCK_REASON="FND finding count decreasing from ${OLD_FND_COUNT} to ${NEW_FND_COUNT} (silent finding removal)"
fi

if [ "$SHOULD_BLOCK" = "1" ]; then
  # read -d '' rather than $(cat <<EOF): bash 3.2 (stock macOS) cannot parse a here-document that
  # contains an apostrophe inside $(...), and the whole hook then fails to load.
  DENY_MSG=""
  read -r -d '' DENY_MSG <<EOF || true
W43-N6 BLOCKED: AGENT_REVIEW overwrite would discard existing review content.

File: $FILE
Existing: ${OLD_SIZE} bytes, ${OLD_FND_COUNT} FND-XXX findings.
Proposed: ~${NEW_SIZE} bytes, ${NEW_FND_COUNT} FND-XXX findings.
Reason:   ${BLOCK_REASON}

A production session (2026-05-03) showed a 109-line codex review
overwritten with a 7-line "PASS" stub — silently discarding 4 findings
that had not been addressed in the narrow catch fix. AGENT_REVIEW is
append-only after the first substantial review is written. To document
that findings were addressed:

  ✓ ADD a "## Resolution" or "## Findings Addressed" section at the END
    of the existing report listing which findings were fixed and how.
  ✗ DO NOT replace the original findings with a smaller PASS verdict.

If the existing review is genuinely incorrect (false positives) and
needs to be fully replaced, dispatch a NEW codex/superpowers review and
have the new review supersede the old one — don't hand-write a stub.
EOF
  echo "[protect-agent-review] DENIED: $BLOCK_REASON" >&2
  jq -n --arg reason "$DENY_MSG" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

exit 0
