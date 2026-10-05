#!/usr/bin/env bash
# v-stop-readiness-content-hash-test.sh — Item 23 regression test (2026-07-03, R1 MED-3).
#
# The pre-existing gauntlet-attestation preview in v-stop-readiness.sh only checked witness SID
# match + age — the SAME sub-conditions the real Stop hook (check-review-artifact.sh) checks, but
# NOT its content-hash binding (recompute sha256 of each artifact on disk, compare to the witness's
# pre_sha256/rev_sha256/ver_sha256). A model that hand-edits an artifact AFTER a genuine attestation
# (still fresh, still the right SID) sailed through this preview as "READY" only to be BLOCKED by
# the real gate — exactly the block→fix→block thrash this preview exists to prevent (observed
# in a production session). This test produces a REAL witness via v-gauntlet-attest.sh, then tampers with one
# artifact, and asserts the preview now flags it — using the SAME crypto lib the real gate uses.
set -uo pipefail
SR="${V_SR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-stop-readiness.sh}"
ATTEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-gauntlet-attest.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$SR" ] || { echo "SKIP: v-stop-readiness.sh missing"; exit 0; }
[ -f "$ATTEST" ] || { echo "SKIP: v-gauntlet-attest.sh missing"; exit 0; }

SID="dddd1111-2222-4333-8444-555566667788"
TD=$(mktemp -d); R="$TD/repo"; mkdir -p "$R/.v/artifacts"
( cd "$R" && git init -q -b main && echo x > f && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1

BODY="$(head -c 260 < /dev/zero | tr '\0' 'x')"
printf 'Mode: full\n%s\n' "$BODY" > "$R/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
printf 'Dispatch mode: orchestrator-inline (test)\n%s\n' "$BODY" > "$R/.v/artifacts/AGENT_REVIEW_${SID}.md"
printf 'Convention check\n%s\n' "$BODY" > "$R/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"

# Produce a REAL, correctly-signed witness (skip the H4-6 semantic layer — out of scope for this test,
# separately covered by v-gauntlet-attest-semantic-gate-test.sh).
( cd "$R" && PROJECT_ROOT="$R" GW_LIB="$HOME/.claude/hooks/lib/gauntlet-witness.sh" \
  V_VALIDATION_LIB="/nonexistent-skip-semantic-validation-for-this-test" \
  bash "$ATTEST" "$SID" >/dev/null 2>/dev/null )
WIT="$HOME/.claude/runtime/v-gauntlet-attestation-${SID}.json"
[ -f "$WIT" ] || { echo "SKIP: could not produce a real witness (attest prerequisites unmet in this env)"; echo "TOTAL: 0 passed, 0 failed (skipped)"; rm -rf "$TD"; exit 0; }

echo "== Item 23 :: stop-readiness previews the witness content-hash gate (R1 MED-3) =="

OUT1="$(SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" bash "$SR" "$SID" "$R" 2>/dev/null)"
printf '%s' "$OUT1" | grep -qiE 'content-hash matches' \
  && ok "untampered artifacts: preview reports content-hash MATCH (no false blocker)" \
  || no "untampered case did not report a content-hash match" "$(printf '%s' "$OUT1" | grep -i 'content-hash')"

# Tamper: hand-edit PRE_FLIGHT_REPORT AFTER attestation (still same SID, still fresh witness).
printf 'Mode: full\n%s\nTAMPERED LINE\n' "$BODY" > "$R/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"

OUT2="$(SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" bash "$SR" "$SID" "$R" 2>/dev/null)"
printf '%s' "$OUT2" | grep -qiE 'content-hash MISMATCH' \
  && ok "tampered artifact (edited AFTER attestation, same SID + still fresh) -> preview flags content-hash MISMATCH" \
  || no "tampered artifact was NOT flagged (the exact gap Item 23 closes)" "$(printf '%s' "$OUT2" | grep -i 'gauntlet-attestation')"
printf '%s' "$OUT2" | grep -qiE 'NOT READY' \
  && ok "tampered case reports overall NOT READY" \
  || no "tampered case did not roll up to NOT READY" ""

rm -rf "$TD" "$WIT" 2>/dev/null

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
