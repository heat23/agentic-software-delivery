#!/usr/bin/env bash
# v-gauntlet-attest-semantic-gate-test.sh — H4-6 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: a production session attested + merged with an AGENT_REVIEW the Stop hook LATER ruled
# semantically invalid (hostile review required but undeclared) — the attest+merge path consumed
# WEAKER validation (presence + size only) than the Stop hook (validate_artifact +
# validate_review_semantics, hostile-aware). v-gauntlet-attest.sh now runs the SAME validators
# BEFORE attesting/writing the witness, so a semantically-invalid gauntlet can never be attested.
#
# RED on the pre-edit backup (accepts a hostile-undeclared AGENT_REVIEW — presence+size only).
# GREEN on the fix (refuses with exit 7).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ATTEST="${V_ATTEST_OVERRIDE:-$HERE/v-gauntlet-attest.sh}"
ATTEST_BAK="$HERE/v-gauntlet-attest.sh.pre-h4-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
_GW_LIB_CHECK="$HOME/.claude/hooks/lib/gauntlet-witness.sh"
[ -f "$_GW_LIB_CHECK" ] || { echo "SKIP: gauntlet-witness.sh not found"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

echo "== H4-6 :: v-gauntlet-attest.sh Stop-grade semantic validation =="
bash -n "$ATTEST" && ok "v-gauntlet-attest.sh parses (bash -n)" || no "syntax error"

SID="5e55a000-1111-4222-8333-999988887777"
# F7c hygiene (forensic 2026-07-10): also remove the fixture SID's witness from the GLOBAL attest
# store — the real attest script writes there, and without this the harness leaked a synthetic-SID
# witness into the live runtime dir on every run (test-env-SID-leak class).
TD=$(mktemp -d); trap 'rm -rf "$TD"; rm -f "$HOME/.claude/runtime/v-gauntlet-attestation-5e55a000-1111-4222-8333-999988887777.json" 2>/dev/null' EXIT
( cd "$TD" && git init -q -b main && echo base > app.php \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base
  # billing.php left STAGED but uncommitted — v-hostile-required.sh's --sid fallback (no session-writes
  # log in this fixture) reads `git diff --name-only HEAD`, which sees staged/unstaged changes against
  # tracked files but NOT untracked ones; `git add` (stage, no commit) is what makes it visible. This is
  # the diff the orchestrator's OWN hostile computation would see.
  echo x > billing.php && git -c user.name=t -c user.email=t@t add billing.php ) >/dev/null 2>&1
mkdir -p "$TD/.v/tmp"
_pad="$(printf 'x%.0s' $(seq 1 220))"

_write_valid() {  # writes a compliant PRE_FLIGHT/VERIFY_DONE + a valid (non-hostile-claiming) AGENT_REVIEW
  printf 'Model: haiku\nStatus: PASS\n## Gates\n%s\n' "$_pad" > "$TD/PRE_FLIGHT_REPORT_${SID}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$_pad" > "$TD/VERIFY_DONE_REPORT_${SID}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: %s\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n%s\n' \
    "$SID" "$1" "$_pad" > "$TD/AGENT_REVIEW_${SID}.md"
}

run_attest() {  # <script>
  ( cd "$TD" && CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$TD" V_TMP_DIR="$TD/.v/tmp" bash "$1" "$SID" 2>&1 >/dev/null )
}

echo "-- GREEN: fixed script --"
# Case 1: honestly-declared inline, non-hostile diff -> must PASS (a valid W13 fallback, not a violation)
( cd "$TD" && git reset -q -- billing.php && rm -f billing.php ) >/dev/null 2>&1
_write_valid "no"
OUT1=$(run_attest "$ATTEST"); RC1=$?
[ "$RC1" -eq 0 ] && ok "fixed: honest non-hostile inline review -> attest SUCCEEDS (rc=0)" \
  || no "fixed: honest non-hostile inline review should attest cleanly" "rc=$RC1 out=$OUT1"

# Case 2: the hostile-undeclared shape — billing/hostile diff (billing.php staged) but AGENT_REVIEW claims
# 'Hostile adversarial focus: no' — the Stop hook's own hostile computation (via v-hostile-required.sh,
# H4-5) would say hostile=1 for this diff, so validate_review_semantics is called with hostile_required=1
# and MUST reject an artifact that under-declares it.
( cd "$TD" && echo x > billing.php && git -c user.name=t -c user.email=t@t add billing.php ) >/dev/null 2>&1
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n%s\n' \
  "$SID" "$_pad" > "$TD/AGENT_REVIEW_${SID}.md"
OUT2=$(run_attest "$ATTEST"); RC2=$?
[ "$RC2" -eq 7 ] && ok "fixed: hostile diff (billing.php) + 'Hostile adversarial focus: no' -> refused (rc=7, hostile-undeclared class)" \
  || no "fixed: hostile-undeclared review should be refused with rc=7" "rc=$RC2 out=$OUT2"

echo "-- RED: pre-edit backup (presence+size only — must have ACCEPTED the hostile-undeclared shape) --"
if [ -f "$ATTEST_BAK" ]; then
  OUT3=$(run_attest "$ATTEST_BAK"); RC3=$?
  [ "$RC3" -eq 0 ] && ok "backup: hostile-undeclared review WAS accepted pre-fix (confirms the gap existed)" \
    || no "backup should have accepted the hostile-undeclared shape (weaker validation)" "rc=$RC3 out=$OUT3"
else
  echo "  SKIP: no backup at $ATTEST_BAK"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
