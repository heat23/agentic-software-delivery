#!/usr/bin/env bash
# v-bite-ledger.sh — record TDD bite evidence for an invariant-file change.
#
# WHAT IT DOES (P2, audit 2026-06-19):
# When a developer changes a file in the "tracked invariant" set (hooks/, hooks/lib/,
# skills/v/references/, scripts/) they MUST prove TDD discipline: the test was RED against
# the pre-change file (.pre-*-bak oracle) and GREEN after the fix. This script records
# that evidence into BITE_LEDGER_<sid>.md so the Stop hook can confirm the discipline was
# followed at session end.
#
# Usage:
#   bash v-bite-ledger.sh \
#       --invariant  hooks/lib/validation.sh          # path that was changed
#       --harness    skills/v/references/v-contract-negative-test.sh  # harness that bites
#       --red-exit   1                                # exit code against pre-fix .bak
#       --green-exit 0                                # exit code after fix
#       --note       "S-A: VALIDATION_MIN_SIZE floor" # human description
#
# Options:
#   --invariant  PATH    Required. Relative (to ~/.claude) or absolute path of the changed file.
#   --harness    PATH    Required. The test harness that must bite.
#   --red-exit   N       Required. Exit code the harness returned against the .pre-*-bak oracle.
#                        Must be non-zero to be accepted.
#   --green-exit N       Required. Exit code after the fix. Must be 0.
#   --note       TEXT    Optional. Free-text description of what survivor/fix this covers.
#   --sid        SID     Optional. Session ID. Defaults to CLAUDE_SESSION_ID env var.
#   --ledger-dir DIR     Optional. Directory for the ledger file. Defaults to ~/.claude.
#
# Exit codes:
#   0  — bite recorded successfully
#   1  — usage error (missing required args)
#   2  — invalid evidence: red-exit was 0 (harness did NOT bite pre-fix) or green-exit non-0
#   3  — ledger write failed

set -uo pipefail

INVARIANT=""
HARNESS=""
RED_EXIT=""
GREEN_EXIT=""
NOTE=""
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
LEDGER_DIR="${HOME}/.claude"

# ── parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --invariant)  INVARIANT="$2";  shift 2 ;;
    --harness)    HARNESS="$2";    shift 2 ;;
    --red-exit)   RED_EXIT="$2";   shift 2 ;;
    --green-exit) GREEN_EXIT="$2"; shift 2 ;;
    --note)       NOTE="$2";       shift 2 ;;
    --sid)        SID="$2";        shift 2 ;;
    --ledger-dir) LEDGER_DIR="$2"; shift 2 ;;
    *) echo "v-bite-ledger: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

# ── validate required args ───────────────────────────────────────────────────
missing=""
[ -z "$INVARIANT"  ] && missing="$missing --invariant"
[ -z "$HARNESS"    ] && missing="$missing --harness"
[ -z "$RED_EXIT"   ] && missing="$missing --red-exit"
[ -z "$GREEN_EXIT" ] && missing="$missing --green-exit"
if [ -n "$missing" ]; then
  echo "v-bite-ledger: missing required args:$missing" >&2
  exit 1
fi

if [ -z "$SID" ]; then
  echo "v-bite-ledger: no session ID — set CLAUDE_SESSION_ID or pass --sid" >&2
  exit 1
fi

# ── validate evidence ────────────────────────────────────────────────────────
if [ "$RED_EXIT" -eq 0 ] 2>/dev/null; then
  echo "v-bite-ledger: INVALID EVIDENCE — red-exit was 0 (harness passed on pre-fix oracle). The test did NOT bite. Fix the harness or the mutant oracle before recording a bite." >&2
  exit 2
fi

if [ "$GREEN_EXIT" -ne 0 ] 2>/dev/null; then
  echo "v-bite-ledger: INVALID EVIDENCE — green-exit was $GREEN_EXIT (harness failed after fix). The fix is broken. Do not record a bite until the harness passes." >&2
  exit 2
fi

# ── write ledger entry ───────────────────────────────────────────────────────
LEDGER_FILE="${LEDGER_DIR}/BITE_LEDGER_${SID}.md"
TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

mkdir -p "$LEDGER_DIR" 2>/dev/null || true

# If ledger doesn't exist, write the header
if [ ! -f "$LEDGER_FILE" ]; then
  {
    echo "# Bite Ledger — ${SID}"
    echo ""
    echo "Session TDD evidence. Each entry proves the test was RED against the"
    echo "pre-fix oracle and GREEN after the fix (P2 audit gate 2026-06-19)."
    echo ""
  } > "$LEDGER_FILE" || { echo "v-bite-ledger: could not create $LEDGER_FILE" >&2; exit 3; }
fi

# Append this bite entry
{
  echo "## Bite — ${TS}"
  echo ""
  echo "| Field        | Value |"
  echo "|---|---|"
  printf '| invariant    | `%s` |\n' "$INVARIANT"
  printf '| harness      | `%s` |\n' "$HARNESS"
  printf '| red-exit     | %s (pre-fix oracle: non-zero = BITES) |\n' "$RED_EXIT"
  printf '| green-exit   | %s (post-fix: zero = PASSES) |\n' "$GREEN_EXIT"
  [ -n "$NOTE" ] && printf '| note         | %s |\n' "$NOTE"
  echo ""
} >> "$LEDGER_FILE" || { echo "v-bite-ledger: could not write to $LEDGER_FILE" >&2; exit 3; }

echo "v-bite-ledger: recorded bite for '${INVARIANT}' → ${LEDGER_FILE}" >&2
exit 0
