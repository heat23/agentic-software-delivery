#!/usr/bin/env bash
# h4-3-wrong-tree-refusal-test.sh — H4-3 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# CLASS: wrong-tree gate dispatch produced a plausible-but-false report that the orchestrator
# CONSUMED (fleet 2026-07-02: two consecutive factually-false VERIFY_DONE reports,
# caught only by manual fact-checking, then OVERWRITTEN — evidence lost). The P0-2 contract's
# `WrongTree:` disclosure was WARN-only. v-dispatch-subagent.sh § 7b now HARD-REJECTS any
# artifact carrying a WrongTree: line: preserved under .v/tmp/rejected-*, DISPATCH_STATUS=
# wrong_tree, exit 4 — never a consumable report.
#
# Drives the REAL helper with a PATH-shimmed `claude` stub (no model calls).
# Override knob (mutation-gate red/green): V_DSA_OVERRIDE — alternate v-dispatch-subagent.sh.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HELPER="${V_DSA_OVERRIDE:-$HERE/v-dispatch-subagent.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

SID="bbbb1111-2222-3333-4444-555566667777"
SB="$(mktemp -d "${TMPDIR:-/tmp}/h43-wrongtree.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/repo/.v/tmp" "$SB/repo/.v/artifacts" "$SB/bin"
git -C "$SB/repo" init -q 2>/dev/null && git -C "$SB/repo" commit -q --allow-empty -m init 2>/dev/null
printf 'verify the diff for session %s\n' "$SID" > "$SB/prompt.txt"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok  %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

mk_stub() {  # $1 = result payload (JSON-escaped string content)
  cat > "$SB/bin/claude" <<STUB
#!/bin/bash
# stub claude: consume stdin, emit a claude -p --output-format json shaped payload
cat > /dev/null 2>&1 || true
printf '%s' '{"is_error":false,"result":"$1","total_cost_usd":0.01,"duration_ms":42,"modelUsage":{"claude-haiku-4-5":{}}}'
STUB
  chmod +x "$SB/bin/claude"
}

run_helper() {  # -> rc; stdout in $SB/out.txt
  ( cd "$SB/repo" && \
    PATH="$SB/bin:$PATH" CLAUDE_SESSION_ID="$SID" V_TMP_DIR="$SB/repo/.v/tmp" \
    V_DISPATCH_TIMEOUT_SEC=30 \
    bash "$HELPER" --agent v-verify-done-runner --prompt-file "$SB/prompt.txt" \
      --artifact "$SB/repo/VERIFY_DONE_REPORT_${SID}.md" --mode capture \
      > "$SB/out.txt" 2>"$SB/err.txt" )
}

# ── Case 1: wrong-tree disclosure -> hard refusal ────────────────────────────────────────────
mk_stub 'Mode: refused\nWrongTree: build/sibling-branch-99999999'
run_helper; rc=$?
if [ "$rc" -ne 0 ] && grep -q '^DISPATCH_STATUS=wrong_tree' "$SB/out.txt"; then
  ok "wrong-tree artifact REFUSED (rc=$rc, DISPATCH_STATUS=wrong_tree)"
else
  bad "wrong-tree artifact accepted (rc=$rc, status=$(grep '^DISPATCH_STATUS=' "$SB/out.txt" | head -1))"
fi
if [ ! -s "$SB/repo/VERIFY_DONE_REPORT_${SID}.md" ]; then
  ok "no consumable artifact left at the canonical path"
else
  bad "canonical artifact still present + non-empty (orchestrator could consume a false report)"
fi
if ls "$SB"/repo/.v/tmp/rejected-VERIFY_DONE_REPORT_* >/dev/null 2>&1; then
  ok "rejected artifact PRESERVED under .v/tmp/rejected-* (evidence not lost)"
else
  bad "rejected artifact not preserved (evidence lost — the overwrite class)"
fi
rm -f "$SB"/repo/.v/tmp/rejected-* "$SB/repo/VERIFY_DONE_REPORT_${SID}.md" 2>/dev/null

# ── Case 2 (FP-safety): a normal report passes through untouched ────────────────────────────
mk_stub 'Mode: scoped(writes-log)\nChanged: 2\n\n## Checks\nAll mechanical checks clean.\n\n## Summary\ncritical:0 high:0 medium:0 low:0\n\nOverall Verdict: PASS'
run_helper; rc=$?
if [ "$rc" -eq 0 ] && grep -q '^DISPATCH_STATUS=ok' "$SB/out.txt" && [ -s "$SB/repo/VERIFY_DONE_REPORT_${SID}.md" ]; then
  ok "FP-safe: clean report dispatch still succeeds (rc=0, artifact written)"
else
  bad "FP: clean report was rejected (rc=$rc) — guard over-tightened"
fi
# A report that merely DISCUSSES the phrase mid-line must not trip the line-anchored grep.
rm -f "$SB/repo/VERIFY_DONE_REPORT_${SID}.md"
mk_stub 'Mode: scoped\nChanged: 1\n\n## Checks\nverified the WrongTree: disclosure contract is documented in dispatch-v-verify-done.md\n\nOverall Verdict: PASS'
run_helper; rc=$?
# NOTE: the guard is line-anchored (^[space/quote]*WrongTree:) — a mid-line mention survives.
if [ "$rc" -eq 0 ] && grep -q '^DISPATCH_STATUS=ok' "$SB/out.txt"; then
  ok "FP-safe: mid-line mention of the contract does not trip the refusal"
else
  bad "FP: mid-line 'WrongTree:' mention tripped the refusal (rc=$rc)"
fi

echo ""
echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
