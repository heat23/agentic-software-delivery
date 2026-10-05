#!/usr/bin/env bash
# v-gauntlet-attest-marker-worktree-test.sh — T3 (2026-07-02): the freshness-check start-marker lookup
# must be worktree-safe, mirroring the artifact search a few lines above it in the same script.
#
# WHY: /v Step 0 (bootstrap) runs BEFORE Step 2 (worktree creation) — so for every worktree session, the
# v-invocation-start-<sid>.txt marker lands under the MAIN root's .v/tmp (cwd at Step 0 time), while
# v-gauntlet-attest.sh (dispatched later, Step 4, from WITHIN the worktree) re-resolves PROJECT_ROOT from
# its own cwd = the worktree. Pre-fix, the marker lookup checked ONLY $PROJECT_ROOT/.v/tmp (the worktree),
# never found the marker (it's at main), and silently degraded to "legacy session" — skipping the
# freshness check for every worktree session, not a rare edge case.
#
# RED on v-gauntlet-attest.sh.pre-t3marker-bak (marker lookup: $PROJECT_ROOT/.v/tmp only).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

_GW_LIB_CHECK="$HOME/.claude/hooks/lib/gauntlet-witness.sh"
[ -f "$_GW_LIB_CHECK" ] || { echo "SKIP: gauntlet-witness.sh not found — cannot exercise the script at all"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

# H4-6 (PLAN_2026-07-02_orchestrator-hardening-4): v-gauntlet-attest.sh now also runs Stop-grade
# semantic validation (validate_artifact + validate_review_semantics). This test is about the
# freshness-marker lookup, not artifact content, so its fixtures must be minimally COMPLIANT with
# that validation to reach the freshness-check code path at all — same content-marker + AGENT_REVIEW
# 6-field + session-id requirements the real Stop hook always enforced.
_write_gauntlet_fixture() {  # <dir> <sid> <pad>
  local d="$1" sid="$2" pad="$3"
  printf 'Model: haiku\nStatus: PASS\n## Gates\n%s\n' "$pad" > "$d/PRE_FLIGHT_REPORT_${sid}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n%s\n' \
    "$sid" "$pad" > "$d/AGENT_REVIEW_${sid}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$pad" > "$d/VERIFY_DONE_REPORT_${sid}.md"
}

SID="a1b2c3d4-1111-4222-8333-444455556666"
TD=$(mktemp -d); MAIN="$TD/main"; mkdir -p "$MAIN"
# F7c hygiene (forensic 2026-07-10): this harness runs the REAL attest script, which writes its
# witness to the GLOBAL store ($HOME/.claude/runtime/) — with no trap, every run leaked synthetic
# fixture-SID witnesses into the live attest store (observed: c3d4e5f6-…/d6e6f6a6-… sitting next
# to production witnesses — the documented test-env-SID-leak class) AND leaked $TD itself.
trap 'rm -rf "$TD"; rm -f "$HOME/.claude/runtime/v-gauntlet-attestation-a1b2c3d4-1111-4222-8333-444455556666.json" \
  "$HOME/.claude/runtime/v-gauntlet-attestation-b2c3d4e5-2222-4333-9444-555566667777.json" \
  "$HOME/.claude/runtime/v-gauntlet-attestation-c3d4e5f6-3333-4444-9555-666677778888.json" 2>/dev/null' EXIT
( cd "$MAIN" && git init -q -b main && echo x > f && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
WT="$TD/wt"
( cd "$MAIN" && git worktree add -q -b "build-fixture-${SID:0:8}" "$WT" main ) >/dev/null 2>&1
[ -d "$WT/.git" ] || [ -f "$WT/.git" ] || { echo "SKIP: could not create linked worktree"; rm -rf "$TD"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

# Step 0 (bootstrap) semantics: marker written at MAIN's .v/tmp (cwd at bootstrap time, BEFORE the
# worktree existed) — never at the worktree's .v/tmp.
mkdir -p "$MAIN/.v/tmp"
date -u +%s > "$MAIN/.v/tmp/v-invocation-start-${SID}.txt"
sleep 1   # ensure artifact mtimes below are unambiguously newer than the marker's mtime (1s fs granularity)

# 3 gauntlet artifacts, >=200B each, written in the WORKTREE (where a worktree session's Step 3-6 run),
# with mtime AFTER the marker.
_pad="$(printf 'x%.0s' $(seq 1 220))"
_write_gauntlet_fixture "$WT" "$SID" "$_pad"

run_attest() {  # <script>
  ( cd "$WT" && CLAUDE_SESSION_ID="$SID" bash "$1" "$SID" 2>&1 >/dev/null )
}

PRE_BAK="$HERE/v-gauntlet-attest.sh.pre-t3marker-bak"
if [ -f "$PRE_BAK" ]; then
  ERR_RED="$(run_attest "$PRE_BAK")"
  printf '%s' "$ERR_RED" | grep -qi 'legacy session' \
    && ok "RED: pre-T3 script reports 'legacy session' even though a fresh marker exists at main's .v/tmp" \
    || no "RED not reproduced against pre-T3 backup" "$ERR_RED"
else
  echo "  SKIP  pre-T3 backup missing: $PRE_BAK"
fi

ERR_GREEN="$(run_attest "$HERE/v-gauntlet-attest.sh")"
printf '%s' "$ERR_GREEN" | grep -qi 'legacy session' \
  && no "GREEN failed — current script STILL reports 'legacy session' for a worktree session" "$ERR_GREEN" \
  || ok "GREEN: current script finds the main-root marker via the worktree-safe fallback (no 'legacy session')"
printf '%s' "$ERR_GREEN" | grep -qi 'STALE' \
  && no "current script wrongly reports the fresh worktree artifacts as STALE" "$ERR_GREEN" \
  || ok "current script does not misreport the fresh artifacts as stale"

# Negative control: with NO marker anywhere (neither main nor worktree .v/tmp), the current script must
# STILL degrade gracefully to 'legacy session' — the fallback must not fabricate a marker or crash.
SID2="b2c3d4e5-2222-4333-9444-555566667777"
_write_gauntlet_fixture "$WT" "$SID2" "$_pad"
ERR_NC="$(cd "$WT" && CLAUDE_SESSION_ID="$SID2" bash "$HERE/v-gauntlet-attest.sh" "$SID2" 2>&1 >/dev/null)"
printf '%s' "$ERR_NC" | grep -qi 'legacy session' \
  && ok "negative control: genuinely no marker anywhere still degrades to 'legacy session' (no fabrication)" \
  || no "negative control failed — expected 'legacy session' with no marker present" "$ERR_NC"

# codex CDX-1 hardening: mixed-marker state. MAIN's per-invocation marker is a genuinely OLDER
# prior-invocation leftover; the WORKTREE's OWN session-start marker is NEWER and local. Artifacts sit
# BETWEEN the two markers (newer than the old main marker, older than the new local one). Marker
# selection must use the NEWEST candidate (the local session-start marker) as the freshness baseline —
# first-found-in-priority-order would wrongly pick the older main marker (main per-invocation is
# checked before local session-start) and miss that these artifacts are actually stale.
SID3="c3d4e5f6-3333-4444-9555-666677778888"
mkdir -p "$MAIN/.v/tmp"
date -u +%s > "$MAIN/.v/tmp/v-invocation-start-${SID3}.txt"   # OLDEST: simulates a genuinely prior invocation
sleep 1
_write_gauntlet_fixture "$WT" "$SID3" "$_pad"   # BETWEEN the two markers
sleep 1
mkdir -p "$WT/.v/tmp"
date -u +%s > "$WT/.v/tmp/session-start-${SID3}.txt"          # NEWEST: this invocation's own local marker

CDX1_BAK="$HERE/v-gauntlet-attest.sh.pre-cdx1hardening-bak"
if [ -f "$CDX1_BAK" ]; then
  ERR_MIXED_RED="$(cd "$WT" && CLAUDE_SESSION_ID="$SID3" bash "$CDX1_BAK" "$SID3" 2>&1 >/dev/null)"
  printf '%s' "$ERR_MIXED_RED" | grep -qi 'STALE' \
    && no "RED not reproduced — pre-hardening (first-found-wins) unexpectedly caught the stale artifact" "$ERR_MIXED_RED" \
    || ok "RED: pre-hardening first-found-wins misses the stale artifact (picks the older main marker)"
else
  echo "  SKIP  pre-cdx1hardening backup missing: $CDX1_BAK"
fi

ERR_MIXED="$(cd "$WT" && CLAUDE_SESSION_ID="$SID3" bash "$HERE/v-gauntlet-attest.sh" "$SID3" 2>&1 >/dev/null)"
printf '%s' "$ERR_MIXED" | grep -qi 'STALE' \
  && ok "codex CDX-1: mixed-marker state correctly uses the NEWEST marker, flags artifacts as STALE" \
  || no "codex CDX-1 regression — mixed-marker state used the older main marker, missed a stale artifact" "$ERR_MIXED"

rm -rf "$TD"
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
