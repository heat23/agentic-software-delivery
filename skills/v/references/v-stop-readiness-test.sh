#!/usr/bin/env bash
# v-stop-readiness-test.sh — bite for the advisory pre-stop gate preview (cost-sink fix 2026-06-29). Asserts
# it DETECTS the dominant blockers in ONE pass — a missing required artifact, a forged 'codex … ran'
# AGENT_REVIEW with no dispatch provenance (_independence_verdict=silent), and a QA verdict:fail — and
# reports NOT READY. This is the whole value: surface every blocker at once so the model stops the
# stop→block→fix→stop thrash (forensic: most turns of a measured run came after the first block).
# RED on v-stop-readiness.sh.mut-bak (bad() neutered → never detects a blocker → always READY).
set -uo pipefail
SR="${V_SR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-stop-readiness.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$SR" ] || { echo "SKIP: script missing"; exit 0; }

SID="bbbbcccc-1111-4222-8333-555566667777"
TD=$(mktemp -d); R="$TD/repo"; mkdir -p "$R/.v/artifacts"
( cd "$R" && git init -q -b main && echo x > f && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
# Forged 'codex … ran' AGENT_REVIEW with NO dispatch provenance → _independence_verdict = silent (a blocker).
printf '## Agent Review\nModel: haiku\nDispatch mode: subagent-dispatched\nCodex adversarial reviewer: codex-adversarial-reviewer ran independently against the diff\n\n### Findings\nNo unresolved CRITICAL or HIGH.\n' > "$R/AGENT_REVIEW_$SID.md"
# QA with a FAILING verdict → a blocker. (PRE_FLIGHT/VERIFY_DONE/IMPACT_MAP are intentionally absent.)
printf '## QA Acceptance\nverdict: fail\n' > "$R/QA_REPORT_$SID.md"

# Scope the ambient SID to the fixture so _independence_verdict evaluates the FIXTURE's provenance (none →
# silent), not this live session's (the function keys on the global $SESSION_ID, validation.sh:962).
OUT="$(SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" bash "$SR" "$SID" "$R" 2>/dev/null)"
printf '%s' "$OUT" | grep -qiE 'NO dispatch provenance|claims an independent' \
  && ok "detects forged 'codex … ran' with no provenance (silent → ✗)" \
  || no "missed the forged-provenance blocker" "$(printf '%s' "$OUT" | grep -i independ | head -1)"
printf '%s' "$OUT" | grep -qiE 'QA verdict: FAIL' \
  && ok "detects QA verdict: fail (✗)" || no "missed the QA-fail blocker" ""
printf '%s' "$OUT" | grep -qiE 'PRE_FLIGHT_REPORT is ABSENT' \
  && ok "detects a missing required artifact (✗)" || no "missed the absent-artifact blocker" ""
printf '%s' "$OUT" | grep -qiE 'NOT READY' \
  && ok "verdict = NOT READY when blockers exist (one-pass list)" || no "did not report NOT READY" ""
rm -rf "$TD"

# codex SREV-001/002: an artifact present ONLY in .v/artifacts (worktree / consolidated session) must be
# FOUND via the full ARTIFACT_SEARCH_DIRS, not reported absent — a false-absent here is a false NOT-READY,
# but the symmetric false-READY (saying ready while the gate blocks) is the exact thrash this tool prevents.
SID2=eeee9999-1111-4222-8333-aaaabbbbcccc; TD2=$(mktemp -d); R2="$TD2/r"; mkdir -p "$R2/.v/artifacts"
( cd "$R2" && git init -q -b main && echo x > f && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm b ) >/dev/null 2>&1
printf '## QA\nverdict: pass\n' > "$R2/.v/artifacts/QA_REPORT_$SID2.md"   # ONLY in .v/artifacts, NOT at root
OUT2="$(SESSION_ID="$SID2" CLAUDE_SESSION_ID="$SID2" bash "$SR" "$SID2" "$R2" 2>/dev/null)"
printf '%s' "$OUT2" | grep -qiE 'QA verdict: pass' \
  && ok "an artifact present ONLY in .v/artifacts is FOUND (worktree/consolidated — no false-absent)" \
  || no "missed an artifact in .v/artifacts (worktree search gap)" ""
rm -rf "$TD2"

# T4 (2026-07-02): a PRESENT-but-malformed artifact must be reported "is INVALID (present but malformed)",
# never "is ABSENT" — v-artifact-validate-all.sh prints the token `FAIL` for a structurally-invalid artifact
# (see v-artifact-validate-all.sh:64, `printf '  FAIL    %s\n'`), not the substring `invalid`; the old grep
# here only matched `invalid`, so every FAIL line fell through to the "ABSENT" branch and told the operator
# to regenerate a file that already existed and needed one field fixed (observed live: a present-but-
# Mode-less PRE_FLIGHT_REPORT reported "is ABSENT" across several fix cycles). RED on
# v-stop-readiness.sh.pre-r2-bak (pre-T4 grep: 'invalid' only, no 'FAIL' alternative).
SID3=ffff8888-2222-4333-9444-bbbbccccdddd; TD3=$(mktemp -d); R3="$TD3/r"; mkdir -p "$R3/.v/artifacts"
( cd "$R3" && git init -q -b main && echo x > f && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm b ) >/dev/null 2>&1
# Present but structurally invalid: missing the required 'Mode:' line in the first 12 lines
# (validate_pre_flight_w53_contract rejects it) -> v-artifact-validate-all.sh prints 'FAIL', not 'invalid'.
printf 'Model: haiku\n\n## Pre-Flight Report\n\nOverall Status: PASS\n' > "$R3/PRE_FLIGHT_REPORT_$SID3.md"

PRE_BAK="$(dirname "$SR")/v-stop-readiness.sh.pre-r2-bak"
if [ -f "$PRE_BAK" ]; then
  OUT3_RED="$(SESSION_ID="$SID3" CLAUDE_SESSION_ID="$SID3" bash "$PRE_BAK" "$SID3" "$R3" 2>/dev/null)"
  printf '%s' "$OUT3_RED" | grep -qiE 'PRE_FLIGHT_REPORT is ABSENT' \
    && ok "RED: pre-T4 script misreports a present-but-invalid artifact as ABSENT (bug reproduced)" \
    || no "RED not reproduced against pre-T4 backup" "$(printf '%s' "$OUT3_RED" | grep -i pre_flight | head -1)"
else
  echo "  SKIP  pre-T4 backup missing: $PRE_BAK"
fi

OUT3="$(SESSION_ID="$SID3" CLAUDE_SESSION_ID="$SID3" bash "$SR" "$SID3" "$R3" 2>/dev/null)"
printf '%s' "$OUT3" | grep -qiE 'PRE_FLIGHT_REPORT is INVALID' \
  && ok "GREEN: current script reports the malformed artifact as INVALID, not ABSENT (T4 fix confirmed)" \
  || no "GREEN failed — current script still misreports as ABSENT" "$(printf '%s' "$OUT3" | grep -i pre_flight | head -1)"
printf '%s' "$OUT3" | grep -qiE 'PRE_FLIGHT_REPORT is ABSENT' \
  && no "current script ALSO still says ABSENT (regression check)" "" \
  || ok "current script does NOT say ABSENT for a present-but-invalid artifact"
rm -rf "$TD3"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
