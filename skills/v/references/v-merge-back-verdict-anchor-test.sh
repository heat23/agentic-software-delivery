#!/usr/bin/env bash
# v-merge-back-verdict-anchor-test.sh — ND-0716: _verify_done_untrusted() must read the verdict
# from AUTHORITATIVE positions only (Stop-hook parity), never from narrative prose.
#
# Ground truth (live repro 2026-07-16): the old whole-file `grep -iqE 'verdict:\s*\**\s*fail'`
# matched a Notes-section mention of a PRIOR iteration's fail ("iteration 1 verdict: fail — fixed
# in iteration 2") and false-blocked a merge whose true final line was `Overall Verdict: PASS`
# (fail-closed deadlock). Post-fix the function mirrors check-review-artifact.sh's
# VERIFY_DONE_FAIL detector: W53 final-line check + legacy last-5-lines line-anchored check,
# blockquote ('>') excluded as quoted history.
#
# Extraction convention: the REAL function body is pulled from v-merge-back.sh between
# `_verify_done_untrusted() {` and its closing `  }` (same convention as the sanity-gate test).
# Run against the PRE-FIX script via V_MERGE_BACK_SCRIPT=<path-to-bak> to reproduce RED.
set -u
SRC="${V_MERGE_BACK_SCRIPT:-$HOME/.claude/skills/v/references/v-merge-back.sh}"
[ -f "$SRC" ] || { echo "SKIP: missing $SRC"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

FN=$(sed -n '/_verify_done_untrusted() {/,/^  }$/p' "$SRC")
[ -n "$FN" ] || { no "function extraction" "no _verify_done_untrusted block found"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1; }
ok "_verify_done_untrusted extracted from $(basename "$SRC")"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SESSION_ID="11111111-2222-4333-8444-555555555555"
REPO_ROOT="$T/repo"; WORKTREE_PATH="$T/wt"
mkdir -p "$REPO_ROOT/.v/artifacts" "$WORKTREE_PATH/.v/artifacts"
eval "$FN"
ART="$REPO_ROOT/.v/artifacts/VERIFY_DONE_REPORT_${SESSION_ID}.md"

chk(){  # <expect: block|allow> <label> (report content on stdin)
  local want="$1" lbl="$2"
  cat > "$ART"
  _vdr_block_reason=""
  if _verify_done_untrusted; then
    [ "$want" = block ] && ok "$lbl (blocked: $_vdr_block_reason)" || no "$lbl" "false-BLOCK: $_vdr_block_reason"
  else
    [ "$want" = allow ] && ok "$lbl (allowed)" || no "$lbl" "should have blocked but did not"
  fi
}

# ── the flagship false-block case: narrative fail mention + true final PASS ──
chk allow "T1: PASS report narrating a prior iteration's 'verdict: fail' is NOT blocked" <<'EOF'
Model: haiku
SID: x
Mode: scoped(writes-log)
Changed: 3

## Checks
No findings.

## Notes
Earlier in the QA loop the reviewer noted iteration 1 verdict: fail due to a missing test;
iteration 2 fixed it and re-ran clean.

## Summary
critical:0 high:0 medium:0 low:0

Overall Verdict: PASS
EOF

# ── real FAILs must still block ──
chk block "T2: W53 final-line 'Overall Verdict: FAIL' blocks" <<'EOF'
Model: haiku
Mode: full
Changed: 2

## Checks
#### FND-001 | app/X.php:1 | critical | high
bad.
fix: pending.

## Summary
critical:1 high:0 medium:0 low:0

Overall Verdict: FAIL
EOF

chk block "T3: legacy 'Verdict: FAIL' within last 5 lines blocks" <<'EOF'
Mode: full
Changed: 1

## Verification
issue found.

Verdict: FAIL
(see findings above)
EOF

chk block "T4: bold-decorated '**Overall Verdict: FAIL**' final line blocks" <<'EOF'
Mode: full
Changed: 1

## Summary
critical:1

**Overall Verdict: FAIL**
EOF

# ── quoted history + PASS forms must not block ──
chk allow "T5: blockquoted '> Overall Verdict: FAIL' (quoted history) does NOT block" <<'EOF'
Mode: full
Changed: 1

## Notes
Prior run said:
> Overall Verdict: FAIL

## Summary
critical:0

Overall Verdict: PASS
EOF

chk allow "T6: clean PASS report is not blocked" <<'EOF'
Mode: scoped(writes-log)
Changed: 2

## Checks
No findings.

## Summary
critical:0 high:0 medium:0 low:0

Overall Verdict: PASS
EOF

# ── (B) lane unchanged: no-isolation scope still blocks even on PASS ──
chk block "T7: Mode no-isolation still blocks regardless of PASS" <<'EOF'
Mode: scoped(fallback-git-state:no-isolation)
Changed: 4

## Summary
critical:0

Overall Verdict: PASS
EOF

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
