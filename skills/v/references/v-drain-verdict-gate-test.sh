#!/usr/bin/env bash
# v-drain-verdict-gate-test.sh — BITE for C-1 (round-3, 2026-07-01): SESSION-ENDED ≠ GAUNTLET-COMPLETE.
#
# CLASS: v-drain-deferred-merges.sh gated landing on PID-liveness ONLY. It auto-landed sessions whose
# SESSION_LOG was INVALID (un-reviewed scope creep) and would have landed a
# QA-verdict-FAIL branch whose fail evidence had already been erased. A dead owner proves the
# session ENDED, not that its work was GATED.
#
# CONTRACT under test — before LANDING (not before already-merged cleanup) a dead-owner worktree, the drain
# must verify gauntlet completeness from DURABLE ARTIFACTS and honor an operator hold:
#   HOLD when: merge-hold-<sid8>* marker · QA_REPORT verdict:fail · BLOCKED_<sid8>* · no
#              AGENT_REVIEW_<sid8>*/GAUNTLET_SKIPPED_<sid8>* artifact anywhere on disk
#   DRAIN when: review artifact present (AGENT_REVIEW or deliberate GAUNTLET_SKIPPED) + no fail/hold/block
#   NEVER key on DISPATCH_PROVENANCE rows: rows are absent for legit v-dispatch-subagent reviews
#   (observed: zero rows) and forgeable by printf (observed: mode=capture rows with empty sha256).
#   Already-merged worktrees bypass the gate (cleanup is not landing; M2 dirty-guard protects content).
#   Dry-run prints the same HOLD (dry-run/real divergence misleads triage — observed in a production session).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${V_TEST_DRAIN_SCRIPT:-$HERE/v-drain-deferred-merges.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer missing at $DRAINER"; exit 2; }

BASE="$(mktemp -d)"
DEAD_PID=999999   # beyond macOS pid_max — never live; freed pids recycle under churn (2026-07-02)
trap 'rm -rf "$BASE" 2>/dev/null' EXIT

# full UUIDs (merge-back hard-requires them; sid8 = first segment)
SIDu="aaaa0001-1111-4222-8333-444455556666"   # ungated: dead lock, commits ahead, NO artifacts      → HOLD
SIDq="aaaa0002-1111-4222-8333-444455556666"   # QA fail: review present but QA verdict:fail          → HOLD
SIDb="aaaa0003-1111-4222-8333-444455556666"   # BLOCKED artifact present                              → HOLD
SIDh="aaaa0004-1111-4222-8333-444455556666"   # operator merge-hold marker                            → HOLD
SIDg="aaaa0005-1111-4222-8333-444455556666"   # gated control: AGENT_REVIEW + QA pass                 → DRAIN
SIDf="aaaa0006-1111-4222-8333-444455556666"   # forged: provenance row CLAIMS review, no artifact     → HOLD
SIDs="aaaa0007-1111-4222-8333-444455556666"   # deliberate GAUNTLET_SKIPPED trivial session           → DRAIN
SIDw="aaaa0008-1111-4222-8333-444455556666"   # gated, review artifact ONLY in the worktree itself    → DRAIN
SIDm="aaaa0009-1111-4222-8333-444455556666"   # ungated but branch ALREADY MERGED → cleanup allowed   → MB called
# F1/F2/F4/F8 regression pins (adversarial review 2026-07-01, each PoC'd against the pre-fix gate):
SIDt="aaaa0010-1111-4222-8333-444455556666"   # forged review COMMITTED inside the branch's own diff   → HOLD
SIDq2="aaaa0011-1111-4222-8333-444455556666"  # QA verdict: "fail" (quote-wrapped) evaded bare match   → HOLD
SIDap="aaaa0012-1111-4222-8333-444455556666"  # QA top verdict: pass, appendix mentions fail           → DRAIN
SIDcol="aaaa0013-1111-4222-8333-444455556666" # review artifact belongs to ANOTHER session sharing sid8 → HOLD

R="$BASE/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
mkdir -p "$R/.v/artifacts"
mk_wt(){ # $1=slug $2=sid → dead-lock worktree, 1 commit ahead of main; prints path
  local slug="$1" sid="$2" b="fix/${1}-${2%%-*}"
  ( cd "$R" && git checkout -q -b "$b" && echo "$slug" > "$slug.f" && git add -A && git commit -qm "$slug" && git checkout -q main ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$R/.worktrees/$slug" "$b" >/dev/null 2>&1
  printf '%s %s %s\n' "$sid" "$DEAD_PID" "$(date +%s)" > "$R/.worktrees/$slug/.claude-session-lock"
  printf '%s/.worktrees/%s' "$R" "$slug"
}
WTU="$(mk_wt ungated "$SIDu")"
WTQ="$(mk_wt qafail  "$SIDq")"
WTB="$(mk_wt blocked "$SIDb")"
WTH="$(mk_wt held    "$SIDh")"
WTG="$(mk_wt gated   "$SIDg")"
WTF="$(mk_wt forged  "$SIDf")"
WTS="$(mk_wt gskip   "$SIDs")"
WTW="$(mk_wt wtonly  "$SIDw")"
WTQ2="$(mk_wt quoted "$SIDq2")"
WTAP="$(mk_wt appendix "$SIDap")"
WTCOL="$(mk_wt collide "$SIDcol")"
# F1: the forged-review branch COMMITS its own AGENT_REVIEW alongside the payload (tracked = self-attestation)
b="fix/trackforge-${SIDt%%-*}"
( cd "$R" && git checkout -q -b "$b" && echo evil > evil.f && printf 'TOTALLY LEGIT REVIEW\n' > "AGENT_REVIEW_${SIDt}.md" \
  && git add -A && git commit -qm evil && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/trackforge" "$b" >/dev/null 2>&1
printf '%s %s %s\n' "$SIDt" "$DEAD_PID" "$(date +%s)" > "$R/.worktrees/trackforge/.claude-session-lock"
# already-merged ungated branch (cleanup path — gate must NOT block it)
( cd "$R" && git checkout -q -b "fix/mergedun-${SIDm%%-*}" && echo mu > mu.f && git add -A && git commit -qm mu \
  && git checkout -q main && git merge -q --ff-only "fix/mergedun-${SIDm%%-*}" ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/mergedun" "fix/mergedun-${SIDm%%-*}" >/dev/null 2>&1
printf '%s %s %s\n' "$SIDm" "$DEAD_PID" "$(date +%s)" > "$R/.worktrees/mergedun/.claude-session-lock"

A="$R/.v/artifacts"
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDq}.md"
printf '# QA\nverdict: fail\n'    > "$A/QA_REPORT_${SIDq}.md"
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDb}.md"
printf '# blocked\n'              > "$A/BLOCKED_${SIDb}.md"
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDh}.md"
printf 'hold: SME review\n'       > "$A/merge-hold-${SIDh%%-*}.md"
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDg}.md"
printf '# QA\nverdict: pass\n'    > "$A/QA_REPORT_${SIDg}.md"
# forged: a printf'd provenance row CLAIMING a review ran — but no AGENT_REVIEW artifact exists
printf 'DISPATCH|ts=2026-07-01T00:00:00Z|agent=codex-adversarial-reviewer|mode=capture|status=ok|submodel=x|cost_usd=|duration_ms=|artifact=AGENT_REVIEW_%s.md|sha256=\n' "$SIDf" > "$A/DISPATCH_PROVENANCE_${SIDf}.log"
printf 'trivial docs-only session\n' > "$A/GAUNTLET_SKIPPED_${SIDs}.md"
printf 'Model: haiku\nAPPROVED\n' > "$WTW/AGENT_REVIEW_${SIDw}.md"   # worktree-only copy (pre-C-2 sessions) — UNTRACKED by construction
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDq2}.md"
printf '# QA\nverdict: "fail"\n'  > "$A/QA_REPORT_${SIDq2}.md"       # F2: quote-wrapped fail must still HOLD
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDap}.md"
printf '# QA\nverdict: pass\n\n## appendix (adjudicated non-blocking)\nverdict: fail\n' > "$A/QA_REPORT_${SIDap}.md"  # F8: FIRST verdict line wins (old grep -q matched the appendix line anywhere → false HOLD)
printf 'Model: haiku\nAPPROVED\n' > "$A/AGENT_REVIEW_${SIDcol%%-*}-9999-4999-8999-999955556666.md"  # F4: OTHER session, same sid8

STUB="$BASE/stub"; mkdir -p "$STUB"; MB_LOG="$BASE/mb.log"; : > "$MB_LOG"
printf '#!/usr/bin/env bash\nprintf "MB sid=%%s wt=%%s\\n" "$1" "$2" >> "%s"\nexit 0\n' "$MB_LOG" > "$STUB/merge-back.sh"
chmod +x "$STUB/merge-back.sh"
drain(){ V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" 2>&1; }

echo "== C-1 HOLD matrix: ungated / QA-fail / BLOCKED / hold-marker / forged-provenance are NOT landed =="
: > "$MB_LOG"; OUT="$(drain)"
grep -qE "wt=.*/ungated([/[:space:]]|$)" "$MB_LOG" && no "LANDED UNGATED WORK (no artifacts at all) — the ungated/QA-fail landing class" "$(cat "$MB_LOG")" || ok "no-artifact dead session is HELD, not landed"
grep -qE "wt=.*/qafail([/[:space:]]|$)"  "$MB_LOG" && no "LANDED a QA-verdict-FAIL branch" "$(cat "$MB_LOG")" || ok "QA verdict:fail is HELD"
grep -qE "wt=.*/blocked([/[:space:]]|$)" "$MB_LOG" && no "LANDED a session with a BLOCKED artifact" "$(cat "$MB_LOG")" || ok "BLOCKED_<sid> is HELD"
grep -qE "wt=.*/held([/[:space:]]|$)"    "$MB_LOG" && no "LANDED past an operator merge-hold marker" "$(cat "$MB_LOG")" || ok "merge-hold-<sid8> marker is HELD (operator SME-hold switch)"
grep -qE "wt=.*/forged([/[:space:]]|$)"  "$MB_LOG" && no "a printf'd PROVENANCE ROW (no artifact) satisfied the gate — Trap-1 violation" "$(cat "$MB_LOG")" || ok "forged provenance row without the artifact does NOT satisfy the gate (durable-artifact predicate)"
grep -qE "wt=.*/trackforge([/[:space:]]|$)" "$MB_LOG" && no "F1: a review artifact COMMITTED in the branch's own diff satisfied the gate (self-attestation landed)" "$(cat "$MB_LOG")" || ok "F1: tracked (committed-in-diff) review artifact is NOT evidence — HELD"
grep -qE "wt=.*/quoted([/[:space:]]|$)"  "$MB_LOG" && no "F2: quote-wrapped 'verdict: \"fail\"' evaded the QA-fail match and LANDED" "$(cat "$MB_LOG")" || ok "F2: quote-wrapped QA fail verdict is detected — HELD"
grep -qE "wt=.*/collide([/[:space:]]|$)" "$MB_LOG" && no "F4: ANOTHER session's review artifact (same sid8 prefix) satisfied the gate" "$(cat "$MB_LOG")" || ok "F4: sid8-colliding foreign review artifact is NOT evidence — HELD"

echo "== C-1 control cases: gated work still drains; already-merged cleanup not blocked =="
grep -qE "wt=.*/gated([/[:space:]]|$)"   "$MB_LOG" && ok "complete gauntlet (AGENT_REVIEW + QA pass) still DRAINS" || no "false-HOLD: fully-gated session no longer drains" "$(cat "$MB_LOG"; printf '%s' "$OUT")"
grep -qE "wt=.*/gskip([/[:space:]]|$)"   "$MB_LOG" && ok "deliberate GAUNTLET_SKIPPED session still DRAINS (explicit decision artifact honored)" || no "false-HOLD: GAUNTLET_SKIPPED session held" "$(cat "$MB_LOG")"
grep -qE "wt=.*/wtonly([/[:space:]]|$)"  "$MB_LOG" && ok "review artifact ONLY in the worktree satisfies the gate (pre-C-2 sessions)" || no "false-HOLD: worktree-only AGENT_REVIEW not found" "$(cat "$MB_LOG")"
grep -qE "wt=.*/mergedun([/[:space:]]|$)" "$MB_LOG" && ok "already-merged ungated worktree still reaches merge-back cleanup (gate applies to LANDING only)" || no "gate wrongly blocks already-merged cleanup" "$(cat "$MB_LOG")"
grep -qE "wt=.*/appendix([/[:space:]]|$)" "$MB_LOG" && ok "F8: top-level 'verdict: pass' wins over an appendix fail mention — still DRAINS (no false HOLD)" || no "F8: appendix fail mention over-rode the authoritative top pass verdict" "$(cat "$MB_LOG"; printf '%s' "$OUT")"

echo "== C-1 reporting: HOLDs are loud, counted, and name the manual path =="
printf '%s' "$OUT" | grep -q "HOLD fix/ungated-${SIDu%%-*}" && ok "HOLD line names the held branch" || no "no HOLD line for the ungated branch" "$OUT"
printf '%s' "$OUT" | grep -qi "v-merge-back.sh" && ok "HOLD message names the manual land path (no raw git merge)" || no "HOLD message lacks the manual remediation path" "$OUT"
printf '%s' "$OUT" | grep -qE "held-ungated=8" && ok "summary tally counts held-ungated worktrees (8: ungated/qafail/blocked/held/forged/trackforge/quoted/collide)" || no "summary lacks the held-ungated=8 tally" "$(printf '%s' "$OUT" | tail -2)"

echo "== C-1 dry-run parity: dry-run prints the SAME holds and merges nothing =="
: > "$MB_LOG"; DOUT="$(V_DRAIN_DRY_RUN=1 drain)"
[ ! -s "$MB_LOG" ] && ok "dry-run invokes no merge-back" || no "dry-run merged" "$(cat "$MB_LOG")"
printf '%s' "$DOUT" | grep -q "HOLD fix/ungated-${SIDu%%-*}" && ok "dry-run prints the same HOLD (no would-drain lie for ungated work)" || no "dry-run diverges from real HOLD behavior" "$DOUT"
printf '%s' "$DOUT" | grep -qE "would drain.*fix/gated-${SIDg%%-*}|would drain.*gated" && ok "dry-run still previews the gated control as drainable" || no "dry-run no longer previews gated work" "$DOUT"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
