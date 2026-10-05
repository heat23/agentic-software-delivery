#!/usr/bin/env bash
# v-bootstrap-wrapper-test.sh — behavioral + invariant harness for v-bootstrap-wrapper.sh (W46-F2).
#
# WHY THIS EXISTS (audit 2026-06-17): v-bootstrap-wrapper.sh had ZERO behavioral coverage — its only
# reference was a quoted token in v-token-budget-test.sh's anchor list. The wrapper exists for ONE
# load-bearing reason: a parent shell with errexit/pipefail/nounset must NOT make Step 0 exit non-zero
# on a benign command (the recurring prod "Exit code 1"). NOTE (proven during authoring): a happy-path
# "exit 0 under hostile options" assertion does NOT bite — the wrapper guards every risky command, so
# it completes cleanly whether or not the immunity is present. The immunity is therefore guarded as a
# STRUCTURAL invariant (the `set +e/+o pipefail/+u` directives must be present, ahead of the first
# risky command), alongside two behavioral assertions that DO bite (happy-path output, unwritable-tmp
# controlled failure). Each assertion below was verified to turn red when its target is removed.
set -uo pipefail
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
WRAP="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/v-bootstrap-wrapper.sh"
[ -f "$WRAP" ] || { echo "NO v-bootstrap-wrapper.sh missing"; exit 1; }

BASE=$(mktemp -d /tmp/vbw-test.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.local GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.local
REPO="$BASE/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && echo x > a.txt && git add -A && git commit -qm init )

echo "=== T1: happy path — wrapper runs to completion, exits 0, emits bootstrap key=value ==="
# Isolation (2026-07-04): pass an explicit SID. Without one the wrapper falls back to the REAL
# ~/.claude/runtime/current-session-id, whose AGE is ambient state — in a long-lived session it
# crosses the staleness threshold and T1 time-bombs (observed live: DETECTION_ERROR=
# stale_runtime_file_<N>s after a few hours). The happy path under test is "wrapper completes and emits
# key=value", not the ambient-file freshness policy (T4 owns SID-source behavior with its own SID).
OUT=$( cd "$REPO" && CLAUDE_SESSION_ID="dddd1111-2222-4333-8444-555566667777" bash "$WRAP" 2>"$BASE/t1.err" ); RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qE '^[A-Z_]+='; then
  ok "wrapper completes, exit 0, surfaces bootstrap output"
else
  no "T1: rc=$RC / no key=value (out=[$(printf '%s' "$OUT" | tr '\n' '|' | head -c 160)] err=[$(tail -2 "$BASE/t1.err" | tr '\n' '|')])"
fi

echo "=== T2: inherited-option immunity is STRUCTURALLY present (the W46-F2 invariant) ==="
# `set +e`, `set +o pipefail`, `set +u` must all be present AND precede the first risky external
# command so inherited errexit/pipefail/nounset are defused before they can bite. "Risky" = a
# bash/grep/git/cat/mkdir invocation at line start OR inside a command substitution (`X="$(git …)"`
# — a failing cmdsubst in an assignment trips the OUTER shell's errexit too, so those count; SREV-001).
# Comment lines are excluded so prose mentioning these commands does not skew the bound.
FIRST_RISKY=$(grep -nvE '^\s*#' "$WRAP" | grep -E ':(\s*|.*\$\()(bash|grep|git|cat|mkdir) ' | head -1 | cut -d: -f1)
SE=$(grep -nE '^\s*set \+e\b' "$WRAP" | head -1 | cut -d: -f1)
SP=$(grep -nE '^\s*set \+o pipefail\b' "$WRAP" | head -1 | cut -d: -f1)
SU=$(grep -nE '^\s*set \+u\b' "$WRAP" | head -1 | cut -d: -f1)
if [ -n "$SE" ] && [ -n "$SP" ] && [ -n "$SU" ] && [ -n "$FIRST_RISKY" ] \
   && [ "$SE" -lt "$FIRST_RISKY" ] && [ "$SP" -lt "$FIRST_RISKY" ] && [ "$SU" -lt "$FIRST_RISKY" ]; then
  ok "set +e / +o pipefail / +u all present before first risky command (line $FIRST_RISKY)"
else
  no "T2: immunity directives missing or after first risky cmd (se=$SE sp=$SP su=$SU firstRisky=$FIRST_RISKY)"
fi

echo "=== T3: unwritable V_TMP_DIR -> controlled exit 2 + explicit diagnostic (no silent code-1) ==="
# Deterministic across fs/uid (no chmod): make `.v` a REGULAR FILE so `mkdir -p .v/tmp` and the
# write-test both fail by construction. The wrapper's guard must catch this and exit 2 with an
# explicit "unwritable / cannot capture" diagnostic — NOT proceed into a silent failure. (Bites:
# with the guard removed, the wrapper instead reports "bootstrap exited", so the grep below misses.)
RO_REPO="$BASE/ro"; mkdir -p "$RO_REPO"; ( cd "$RO_REPO" && git init -q && echo x>a && git add -A && git commit -qm i )
printf '' > "$RO_REPO/.v"   # .v is a file, not a dir -> .v/tmp is uncreatable/unwritable
ERR=$( cd "$RO_REPO" && bash "$WRAP" 2>&1 >/dev/null ); RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$ERR" | grep -qiE 'unwritable|cannot capture'; then
  ok "unwritable tmp -> exit 2 with explicit diagnostic"
else
  no "T3: expected exit 2 + unwritable diagnostic (rc=$RC err=[$(printf '%s' "$ERR" | tr '\n' '|' | head -c 200)])"
fi

echo "=== T4-T7: Step-0 fold (2026-07-01) — BOOTSTRAP_ENV= path, TRIVIAL= fail-open, invocation marker, main-HEAD capture ==="
# Each assertion bit red against the pre-fold snapshot (no BOOTSTRAP_ENV/TRIVIAL emission, no
# marker/capture writes in bootstrap) — see BITE_LEDGER 2026-07-01.
SID4="a1b2c3d4-5678-4abc-8def-aaaaaaaaaaaa"
R4="$BASE/fold"; mkdir -p "$R4"; ( cd "$R4" && git init -q -b main && echo x > a.txt && git add -A && git commit -qm i )
OUT4=$( cd "$R4" && CLAUDE_SESSION_ID="$SID4" bash "$WRAP" 2>/dev/null ); RC4=$?

ENV4=$(printf '%s\n' "$OUT4" | grep '^BOOTSTRAP_ENV=' | head -1 | cut -d= -f2-)
if [ "$RC4" -eq 0 ] && [ -n "$ENV4" ] && [ -f "$ENV4" ]; then
  ok "T4: BOOTSTRAP_ENV= names the real captured env file (nanos-suffixed)"
else
  no "T4: BOOTSTRAP_ENV missing or dangling (rc=$RC4 env=[$ENV4])"
fi

if printf '%s\n' "$OUT4" | grep -qE '^TRIVIAL=[01]$'; then
  ok "T5: TRIVIAL= emitted with 0|1 (fail-open classifier contract)"
else
  no "T5: TRIVIAL= line missing from wrapper output"
fi

MARK4="$R4/.v/tmp/v-invocation-start-${SID4}.txt"
if [ -f "$MARK4" ] && grep -qE '^[0-9]{10}$' "$MARK4"; then
  ok "T6: v-invocation-start marker written with epoch content"
else
  no "T6: invocation marker missing/malformed at $MARK4"
fi

# T6b: per-INVOCATION semantics — a second run must OVERWRITE (session-start is write-once; this is not)
echo "0" > "$MARK4"
( cd "$R4" && CLAUDE_SESSION_ID="$SID4" bash "$WRAP" >/dev/null 2>&1 )
M2=$(cat "$MARK4" 2>/dev/null)
if [ -n "$M2" ] && [ "$M2" != "0" ]; then
  ok "T6b: re-invocation overwrites the marker (per-invocation, not write-once)"
else
  no "T6b: marker not refreshed on re-invocation (content=[$M2])"
fi

HEAD4=$( cd "$R4" && git rev-parse main )
if printf '%s\n' "$OUT4" | grep -q "^MAIN_HEAD_AT_START=$HEAD4"; then
  ok "T7: MAIN_HEAD_AT_START matches refs/heads/main at session start"
else
  no "T7: MAIN_HEAD_AT_START wrong/missing (want $HEAD4)"
fi

echo "─────────────────────────────────────────"
echo "v-bootstrap-wrapper-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
