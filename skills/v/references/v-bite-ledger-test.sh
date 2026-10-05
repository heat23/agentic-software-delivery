#!/usr/bin/env bash
# v-bite-ledger-test.sh — behavioral tests for v-bite-ledger.sh
#
# TDD harness. Tests both positive (valid evidence recorded) and negative
# (invalid evidence rejected) paths. Injectable via V_BITE_LEDGER_SCRIPT.
# Run standalone or via the vitest wrapper v-bite-ledger-harness.test.ts.
#
# Exit 0 if all pass, non-0 if any fail.
set -uo pipefail

SCRIPT="${V_BITE_LEDGER_SCRIPT:-$(dirname "$0")/v-bite-ledger.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

_ok() { local t="$1"; PASS=$((PASS+1)); printf 'ok   %s\n' "$t"; }
_fail() { local t="$1" msg="${2:-}"; FAIL=$((FAIL+1)); printf 'FAIL %s%s\n' "$t" "${msg:+ — $msg}"; }

run() {
  # run script with test ledger dir
  CLAUDE_SESSION_ID="${TEST_SID:-test-sid-$$}" \
    bash "$SCRIPT" --ledger-dir "$TMP/ledger" "$@" 2>&1
}

run_rc() {
  CLAUDE_SESSION_ID="${TEST_SID:-test-sid-$$}" \
    bash "$SCRIPT" --ledger-dir "$TMP/ledger" "$@" 2>/dev/null
  echo $?
}

# ── Positive: basic bite recorded ─────────────────────────────────────────
TEST_SID="pos-001"
rm -rf "$TMP/ledger"; mkdir -p "$TMP/ledger"
rc=$(run_rc \
  --invariant hooks/lib/validation.sh \
  --harness skills/v/references/v-contract-negative-test.sh \
  --red-exit 1 \
  --green-exit 0 \
  --note "S-A test coverage")
if [ "$rc" -eq 0 ]; then _ok "P1 — basic bite: exit 0"; else _fail "P1 — basic bite: exit 0" "got rc=$rc"; fi

LEDGER="$TMP/ledger/BITE_LEDGER_${TEST_SID}.md"
if [ -f "$LEDGER" ]; then _ok "P2 — ledger file created"; else _fail "P2 — ledger file created" "file not found"; fi
if grep -q "hooks/lib/validation.sh" "$LEDGER" 2>/dev/null; then _ok "P3 — invariant path in ledger"; else _fail "P3 — invariant path in ledger"; fi
if grep -q "S-A test coverage" "$LEDGER" 2>/dev/null; then _ok "P4 — note in ledger"; else _fail "P4 — note in ledger"; fi
if grep -q "red-exit.*1" "$LEDGER" 2>/dev/null; then _ok "P5 — red-exit recorded"; else _fail "P5 — red-exit recorded"; fi
if grep -q "green-exit.*0" "$LEDGER" 2>/dev/null; then _ok "P6 — green-exit recorded"; else _fail "P6 — green-exit recorded"; fi

# ── Positive: append multiple bites to same ledger ────────────────────────
TEST_SID="pos-002"
rm -rf "$TMP/ledger"; mkdir -p "$TMP/ledger"
CLAUDE_SESSION_ID="$TEST_SID" bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant hooks/lib/validation.sh --harness test1.sh \
  --red-exit 1 --green-exit 0 --note "first bite" 2>/dev/null
CLAUDE_SESSION_ID="$TEST_SID" bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant scripts/mutation-gate.sh --harness test2.sh \
  --red-exit 2 --green-exit 0 --note "second bite" 2>/dev/null
LEDGER="$TMP/ledger/BITE_LEDGER_${TEST_SID}.md"
bite_count=$(grep -c "^## Bite" "$LEDGER" 2>/dev/null || echo 0)
if [ "$bite_count" -eq 2 ]; then _ok "P7 — two bites in same ledger"; else _fail "P7 — two bites in same ledger" "count=$bite_count"; fi
if grep -q "first bite" "$LEDGER" && grep -q "second bite" "$LEDGER"; then _ok "P8 — both notes present"; else _fail "P8 — both notes present"; fi

# ── Positive: --sid override ────────────────────────────────────────────────
rm -rf "$TMP/ledger"; mkdir -p "$TMP/ledger"
bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh --harness bar.sh \
  --red-exit 1 --green-exit 0 \
  --sid "manual-sid-xyz" 2>/dev/null
if [ -f "$TMP/ledger/BITE_LEDGER_manual-sid-xyz.md" ]; then _ok "P9 — --sid override creates correct file"; else _fail "P9 — --sid override creates correct file"; fi

# ── Negative: red-exit=0 (harness didn't bite) ────────────────────────────
rm -rf "$TMP/ledger"; mkdir -p "$TMP/ledger"
out=$(CLAUDE_SESSION_ID="neg-001" bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh --harness bar.sh --red-exit 0 --green-exit 0 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then _ok "N1 — red-exit=0 rejected (rc=2)"; else _fail "N1 — red-exit=0 rejected (rc=2)" "got rc=$rc"; fi
if printf '%s' "$out" | grep -qi "did NOT bite"; then _ok "N2 — informative message on red-exit=0"; else _fail "N2 — informative message on red-exit=0" "stdout: $out"; fi
if [ ! -f "$TMP/ledger/BITE_LEDGER_neg-001.md" ]; then _ok "N3 — no ledger written on invalid evidence"; else _fail "N3 — no ledger written on invalid evidence"; fi

# ── Negative: green-exit non-zero (fix is broken) ─────────────────────────
rm -rf "$TMP/ledger"; mkdir -p "$TMP/ledger"
out=$(CLAUDE_SESSION_ID="neg-002" bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh --harness bar.sh --red-exit 1 --green-exit 1 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then _ok "N4 — green-exit=1 rejected (rc=2)"; else _fail "N4 — green-exit=1 rejected (rc=2)" "got rc=$rc"; fi
if printf '%s' "$out" | grep -qi "harness failed after fix"; then _ok "N5 — informative message on green-exit!=0"; else _fail "N5 — informative message on green-exit!=0"; fi

# ── Negative: missing required args ───────────────────────────────────────
out=$(CLAUDE_SESSION_ID="neg-003" bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then _ok "N6 — missing args rejected (rc=1)"; else _fail "N6 — missing args rejected (rc=1)" "got rc=$rc"; fi
if printf '%s' "$out" | grep -qi "missing required"; then _ok "N7 — missing args message shown"; else _fail "N7 — missing args message shown"; fi

# ── Negative: no session ID ────────────────────────────────────────────────
out=$(bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh --harness bar.sh --red-exit 1 --green-exit 0 2>&1 \
  ); rc=$?
# With no CLAUDE_SESSION_ID env var and no --sid, rc should be 1
unset CLAUDE_SESSION_ID 2>/dev/null; unset CLAUDE_CODE_SESSION_ID 2>/dev/null; unset SESSION_ID 2>/dev/null
out=$(bash "$SCRIPT" --ledger-dir "$TMP/ledger" \
  --invariant foo.sh --harness bar.sh --red-exit 1 --green-exit 0 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then _ok "N8 — no session ID rejected (rc=1)"; else _fail "N8 — no session ID rejected (rc=1)" "got rc=$rc"; fi

# ── Summary ────────────────────────────────────────────────────────────────
printf '\nTOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
