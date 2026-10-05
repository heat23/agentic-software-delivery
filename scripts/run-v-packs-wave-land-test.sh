#!/usr/bin/env bash
# run-v-packs-wave-land-test.sh — BEHAVIORAL harness for the W-LAND per-wave landing barrier (2026-07-02).
#
# WHY: waves ordered EXECUTION only. A pack archives on GAUNTLET_ATTESTED even when its merge-back
# FND-3-deferred, so wave N+1 sessions branched off a main MISSING wave N's commits (the broken-
# dependency class wave ordering exists to prevent, recreated one layer down), and the 99-* VERIFY
# pack ran BEFORE the end-of-run drain — judging a main missing everything still stranded on branches.
# The fix: land_wave() after each drained wave — the SAME safe landing machinery as end-of-run
# (_land_and_reconcile), then a gate (no dead-owner branch off main, no unverified park) that STOPS
# the runner before dependent waves instead of letting them build on a missing dependency.
#
# This harness proves the barrier's behavior AND its safety rails:
#   • lands a gated dead-owner stranded worktree between waves (real drain, merge-back stubbed)
#   • blocks on HELD (ungated) work — never lands it, never proceeds over it
#   • blocks on a parked pack — but PASSES when the per-wave reconcile proves the park landed
#   • exempts a LIVE-owner branch (an interactive sibling must not deadlock the fleet)
#   • bounded-retries ONLY the self-resolving `deferred` verdict
#   • V_PACK_DRAIN=0 restores the old no-barrier behavior (no new knobs)
#   • integration: wave-2 runs on a main that already contains wave-1's landed commit;
#     a blocked wave-1 stops wave-2 AND skips the VERIFY pack, exit code 2.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
DRAINER="${DRAINER:-$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh}"
[ -f "$RUNNER" ]  || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer not found: $DRAINER"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no1(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
DEAD_PID=999999   # beyond macOS pid_max — can NEVER be live (a freed real pid gets RECYCLED under churn)

# shellcheck disable=SC1090
source "$RUNNER"
for fn in land_wave _land_and_reconcile _unlanded_branches; do
  [ "$(type -t "$fn")" = function ] || { echo "FATAL: sourcing $RUNNER did not expose $fn (W-LAND barrier not shipped)"; exit 1; }
done

# merge-back stub (same V_DRAIN_MERGEBACK seam v-drain-and-telemetry-test.sh uses): actually MERGES the
# worktree's branch into main + cleans up, so the drain's "merged+cleaned (sid=…)" line reflects reality
# and _unlanded_branches sees the branch land. A `defer-once` mode exits 3 (FND-3) on the first call.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/merge-back.sh" <<'EOF'
#!/usr/bin/env bash
sid="$1"; wt="$2"
if [ -n "${MB_DEFER_ONCE_FLAG:-}" ] && [ ! -f "$MB_DEFER_ONCE_FLAG" ]; then
  : > "$MB_DEFER_ONCE_FLAG"; exit 3
fi
br="$(git -C "$wt" branch --show-current)"
gcd="$(git -C "$wt" rev-parse --git-common-dir)"; root="$(cd "$(dirname "$gcd")" && pwd)"
git -C "$root" merge -q --no-edit "$br" >/dev/null 2>&1 || exit 1
git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1
git -C "$root" branch -d "$br" >/dev/null 2>&1
exit 0
EOF
chmod +x "$STUB/merge-back.sh"
export V_DRAIN_MERGEBACK="$STUB/merge-back.sh"
export V_PACK_SETTLE_SEC=0 _LAND_RETRY_SEC=0 V_PACK_TELEMETRY=0 V_PACK_BACKFILL_CHECK=0 V_PACK_BRANCH_GC=0
# This suite asserts the pack dir keeps its name (checks packs/.done/ after clean exit-0 runs); the DONE- dir
# rename (V_PACK_DONE_RENAME, default on) would rename packs/ → DONE-packs/ on a clean finish. That feature has
# its own suite (run-v-packs-done-rename-test.sh) — opt out here so the two features stay independently tested.
export V_PACK_DONE_RENAME=0

mkrepo(){ # $1=dir — git repo on main with one base commit
  mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
}
mkstrand(){ # $1=repo $2=slug $3=sid $4=lockpid(''=no lock) $5=gated(1|0) — dead/live-owner stranded worktree
  local r="$1" slug="$2" sid="$3" pid="$4" gated="$5" br="fix/$2-${3%%-*}"
  git -C "$r" branch "$br" >/dev/null 2>&1
  git -C "$r" worktree add "$r/.worktrees/$slug" "$br" >/dev/null 2>&1
  ( cd "$r/.worktrees/$slug" && echo "work-$slug" > "$slug.txt" && git add -A && git commit -qm "work: $slug" ) >/dev/null 2>&1
  [ -n "$pid" ] && printf '%s %s %s\n' "$sid" "$pid" "$(date +%s)" > "$r/.worktrees/$slug/.claude-session-lock"
  mkdir -p "$r/.v/artifacts"
  [ "$gated" = 1 ] && printf 'APPROVED\n' > "$r/.v/artifacts/AGENT_REVIEW_${sid}.md"
  printf '%s' "$br"
}
mkdirs(){ # $1=repo — set the runner globals a barrier call needs
  REPO="$1"; PACK_ABS="$1/packs"; LOG_DIR="$PACK_ABS/.runlogs"; DONE_DIR="$PACK_ABS/.done"; NEEDS_DIR="$PACK_ABS/.needs-review"
  mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR"
}

echo "── U1: clean repo → barrier passes ──"
R="$TMP/u1"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "land_wave returns 0 on a clean repo" || no1 "clean repo blocked" "rc=$rc: $out"
printf '%s' "$out" | grep -q "✓ wave 1 landed" && ok "prints the ✓ landed line" || no1 "no ✓ landed line" "$out"

echo "── U2: gated dead-owner stranded worktree → barrier LANDS it, then passes ──"
R="$TMP/u2"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
SID2="aaaa1111-2222-4333-8444-555566667777"
BR2="$(mkstrand "$R" u2work "$SID2" "$DEAD_PID" 1)"
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "barrier passes after landing" || no1 "barrier blocked a landable branch" "rc=$rc: $out"
printf '%s' "$out" | grep -q "merged+cleaned: $BR2" && ok "drain landed the branch (merged+cleaned line)" || no1 "no merged+cleaned line" "$out"
git -C "$R" merge-base --is-ancestor "$(git -C "$R" rev-parse main)" main 2>/dev/null
[ -f "$R/u2work.txt" ] || git -C "$R" show main:u2work.txt >/dev/null 2>&1 \
  && ok "the stranded commit is actually ON main" || no1 "commit not on main after 'landing'" "$(git -C "$R" log --oneline main | head -3)"

echo "── U3: UNGATED (held) dead-owner worktree → barrier BLOCKS, work stays off main ──"
R="$TMP/u3"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
SID3="bbbb1111-2222-4333-8444-555566667777"
BR3="$(mkstrand "$R" u3held "$SID3" "$DEAD_PID" 0)"
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "barrier returns 1 on HELD (ungated) work" || no1 "barrier did not block held work" "rc=$rc: $out"
printf '%s' "$out" | grep -q "did NOT fully land" && ok "block message names the failure" || no1 "no block message" "$out"
printf '%s' "$out" | grep -q "drain verdict: held" && ok "per-branch line carries the drain's own verdict (held)" || no1 "verdict not surfaced" "$out"
git -C "$R" show main:u3held.txt >/dev/null 2>&1 && no1 "UNGATED work was LANDED (verdict gate bypassed!)" "" || ok "ungated work stayed OFF main (C-1 verdict gate preserved)"

# RC-2 (resilience, 2026-07-07): a terminal (session-ended, held/ungated) leftover can DEADLOCK
# every future run. The DEFAULT still BLOCKS (preserves the resume-hole guard / I4 below — a later wave must
# not build on an earlier wave's missing held work). V_QUARANTINE_TERMINAL=1 is the operator's explicit
# escape (leftover known-independent): it QUARANTINES terminal blockers and PROCEEDS. `pre-run` only; wave
# barriers stay strict even with the flag; never bypasses the verdict gate.
echo "── RC-2a: DEFAULT (no flag) still BLOCKS pre-run on a terminal held strand (resume-hole guard intact) ──"
R="$TMP/rc2a"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
mkstrand "$R" rc2def "dddd1111-2222-4333-8444-555566667777" "$DEAD_PID" 0 >/dev/null
out="$(land_wave pre-run 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "default pre-run barrier still hard-blocks a terminal strand (I4 contract preserved)" || no1 "default no longer blocks — resume hole reopened" "rc=$rc: $out"

echo "── RC-2b: V_QUARANTINE_TERMINAL=1 QUARANTINES the terminal strand and PROCEEDS (rc=0), work stays off main ──"
R="$TMP/rc2b"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
mkstrand "$R" rc2q "eeee1111-2222-4333-8444-555566667777" "$DEAD_PID" 0 >/dev/null
out="$(V_QUARANTINE_TERMINAL=1 land_wave pre-run 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "flag lets pre-run PROCEED past a terminal strand (no deadlock)" || no1 "flag did not unblock" "rc=$rc: $out"
printf '%s' "$out" | grep -q "QUARANTIN" && ok "emits a loud QUARANTINE notice (not silent)" || no1 "no quarantine notice" "$out"
git -C "$R" show main:rc2q.txt >/dev/null 2>&1 && no1 "QUARANTINE wrongly LANDED ungated work (gate bypassed!)" "" || ok "quarantined work stayed OFF main (C-1 verdict gate NOT bypassed)"

echo "── RC-2c: with the flag, a numbered WAVE barrier STILL BLOCKS (only pre-run is relaxed) ──"
R="$TMP/rc2c"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
mkstrand "$R" rc2wave "ffff1111-2222-4333-8444-555566667777" "$DEAD_PID" 0 >/dev/null
out="$(V_QUARANTINE_TERMINAL=1 land_wave 1 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "wave barrier stays strict even with V_QUARANTINE_TERMINAL=1 (intra-run dependency preserved)" || no1 "wave barrier wrongly relaxed by the flag" "rc=$rc: $out"

echo "── U4: LIVE-owner branch → exempt, barrier passes ──"
R="$TMP/u4"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
SID4="cccc1111-2222-4333-8444-555566667777"
mkstrand "$R" u4live "$SID4" "$$" 1 >/dev/null
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "barrier passes over a LIVE-owner branch (interactive sibling exempt)" || no1 "live-owner branch deadlocked the barrier" "rc=$rc: $out"
printf '%s' "$out" | grep -q "LIVE-owner" && ok "…and says so" || no1 "no LIVE-owner note" "$out"
git -C "$R" show main:u4live.txt >/dev/null 2>&1 && no1 "live session's work was merged out from under it" "" || ok "live worktree untouched"

echo "── U5: parked pack (unproven) → barrier BLOCKS ──"
R="$TMP/u5"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
printf '/v something\n\nbody\n' > "$NEEDS_DIR/STUCK.txt"
out="$(land_wave 2 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "barrier returns 1 over an unproven parked pack" || no1 "parked pack did not block" "rc=$rc: $out"
printf '%s' "$out" | grep -q "unmet dependency" && ok "block message calls the park an unmet dependency" || no1 "no parked-pack message" "$out"

echo "── U6: parked pack whose SID the barrier's own drain lands → reconciled → barrier PASSES ──"
R="$TMP/u6"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
SID6="dddd1111-2222-4333-8444-555566667777"
mkstrand "$R" u6park "$SID6" "$DEAD_PID" 1 >/dev/null
printf '/v parked task\n\nbody\n' > "$NEEDS_DIR/PARKED-LANDS.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s"}\n' "$SID6" > "$LOG_DIR/PARKED-LANDS.log"
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "barrier passes: drain landed the park's worktree, reconcile moved the pack" || no1 "reconcilable park still blocked the barrier" "rc=$rc: $out"
[ -f "$DONE_DIR/PARKED-LANDS.txt" ] && ok "pack reconciled .needs-review/ → .done/" || no1 "pack not reconciled" "$(ls "$NEEDS_DIR" "$DONE_DIR" 2>&1)"

echo "── U7: deferred (FND-3) merge → bounded retry, lands on retry ──"
R="$TMP/u7"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
SID7="eeee1111-2222-4333-8444-555566667777"
BR7="$(mkstrand "$R" u7defer "$SID7" "$DEAD_PID" 1)"
export MB_DEFER_ONCE_FLAG="$TMP/u7-deferred-once"
out="$(land_wave 1 2>&1)"; rc=$?
unset MB_DEFER_ONCE_FLAG
[ "$rc" = 0 ] && ok "barrier retries a deferred merge and passes once it lands" || no1 "deferred merge never retried/landed" "rc=$rc: $out"
printf '%s' "$out" | grep -q "retrying the drain" && ok "retry is announced (deferred is the only retried verdict)" || no1 "no retry announcement" "$out"

echo "── U8: V_PACK_DRAIN=0 → barrier is a no-op (old behavior, no new knobs) ──"
R="$TMP/u8"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0
mkstrand "$R" u8off "ffff1111-2222-4333-8444-555566667777" "$DEAD_PID" 0 >/dev/null
out="$(V_PACK_DRAIN=0 land_wave 1 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "V_PACK_DRAIN=0 disables the barrier along with the drain" || no1 "barrier ran despite V_PACK_DRAIN=0" "rc=$rc: $out"
printf '%s' "$out" | grep -q "landing stranded" && no1 "drain ran despite V_PACK_DRAIN=0" "$out" || ok "no drain invoked"

echo "── U9: _unlanded_branches — shared enumerator (primary-worktree skip, merged branch skip) ──"
R="$TMP/u9"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0; _drain_out=""; _drain_last=""
SID9="abab1111-2222-4333-8444-555566667777"
BR9="$(mkstrand "$R" u9enum "$SID9" "$DEAD_PID" 1)"
lines="$(_unlanded_branches)"
printf '%s\n' "$lines" | grep -q "$BR9" && ok "stranded branch enumerated" || no1 "stranded branch missing" "$lines"
printf '%s\n' "$lines" | grep -q $'\tmain\t' && no1 "primary worktree branch (main) wrongly enumerated" "$lines" || ok "primary worktree branch skipped (R4)"
git -C "$R" merge -q --no-edit "$BR9" >/dev/null 2>&1
lines="$(_unlanded_branches)"
printf '%s\n' "$lines" | grep -q "$BR9" && no1 "fully-merged branch still enumerated" "$lines" || ok "merged branch drops out of the enumeration"

echo "── U10: valid-but-nasty branch name (quotes + \$) survives enumeration and the barrier verbatim ──"
# WREV-002 (codex review, MODIFIED): TAB/control chars are IMPOSSIBLE in a git refname (check-ref-format
# rejects them — verified rc=128), so the TAB separator is safe by git invariant; but quotes and $ ARE
# valid and must pass through _unlanded_branches/land_wave without word-splitting, eval, or truncation.
R="$TMP/u10"; mkrepo "$R"; mkdirs "$R"; HAD_TIMEOUT=0; _drain_out=""; _drain_last=""
NASTY='fix/we"ird-$name'
git -C "$R" branch "$NASTY" >/dev/null 2>&1
git -C "$R" worktree add "$R/.worktrees/nasty" "$NASTY" >/dev/null 2>&1
( cd "$R/.worktrees/nasty" && echo n > n.txt && git add -A && git commit -qm nasty ) >/dev/null 2>&1
lines="$(_unlanded_branches)"
printf '%s\n' "$lines" | grep -qF "$NASTY" && ok "nasty branch name enumerated verbatim (no splitting/eval)" || no1 "nasty branch name mangled" "$lines"
out="$(land_wave 1 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "barrier blocks it (no lock, commits ahead, ungated) rather than crashing" || no1 "barrier misbehaved on nasty name" "rc=$rc: $out"
printf '%s' "$out" | grep -qF "$NASTY" && ok "block report prints the name verbatim" || no1 "name mangled in block report" "$out"

# ══════════════════════════════════════════════════════════════════════════════
# Integration: the runner END-TO-END (fake claude), waves land in order
# ══════════════════════════════════════════════════════════════════════════════
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
# fake claude keyed by markers in the task text (last arg). cwd = repo root (run_pack cd's there).
sid="none"; prev=""; task=""
for a in "$@"; do [ "$prev" = "--session-id" ] && sid="$a"; prev="$a"; task="$a"; done
case "$task" in
  *STRAND-GATED*)
    br="fix/wl-gated-${sid%%-*}"
    git branch "$br" >/dev/null 2>&1
    git worktree add ".worktrees/wl-gated" "$br" >/dev/null 2>&1
    ( cd ".worktrees/wl-gated" && echo gated > wl-gated.txt && git add -A && git commit -qm "wave1-stranded-work" ) >/dev/null 2>&1
    printf '%s 999999 %s\n' "$sid" "$(date +%s)" > ".worktrees/wl-gated/.claude-session-lock"
    mkdir -p .v/artifacts && printf 'APPROVED\n' > ".v/artifacts/AGENT_REVIEW_${sid}.md"
    ;;
  *STRAND-UNGATED*)
    br="fix/wl-ungated-${sid%%-*}"
    git branch "$br" >/dev/null 2>&1
    git worktree add ".worktrees/wl-ungated" "$br" >/dev/null 2>&1
    ( cd ".worktrees/wl-ungated" && echo ungated > wl-ungated.txt && git add -A && git commit -qm "ungated-work" ) >/dev/null 2>&1
    printf '%s 999999 %s\n' "$sid" "$(date +%s)" > ".worktrees/wl-ungated/.claude-session-lock"
    ;;
  *WAVE2CHECK*)
    if git log --format=%s main 2>/dev/null | grep -q wave1-stranded-work; then
      echo ONMAIN > wave2-witness.txt
    else
      echo NOTONMAIN > wave2-witness.txt
    fi
    ;;
esac
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"session_id":"%s"}\nGAUNTLET_ATTESTED: yes\n' "$sid"
EOF
chmod +x "$TMP/fakebin/claude"
export PATH="$TMP/fakebin:$PATH"
export _REAP_POLL=1 PACK_TIMEOUT=120

echo "── I1: wave-1's stranded work is ON MAIN before wave-2 runs; both waves archive; exit 0 ──"
R="$TMP/i1"; mkrepo "$R"; mkdir -p "$R/packs/wave-1" "$R/packs/wave-2"
printf '/v STRAND-GATED build the base\n\nbody\n' > "$R/packs/wave-1/one.txt"
printf '/v WAVE2CHECK consume the base\n\nbody\n' > "$R/packs/wave-2/two.txt"
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i1-out.txt" 2>&1; rc=$?
OUT="$(cat "$TMP/i1-out.txt")"
[ "$rc" = 0 ] && ok "run exits 0 (queue clear, everything landed)" || no1 "run exited $rc" "$(tail -12 "$TMP/i1-out.txt")"
grep -q ONMAIN "$R/wave2-witness.txt" 2>/dev/null \
  && ok "CLASS FIXTURE: wave-2 SAW wave-1's commit on main at its own runtime (dependency honored)" \
  || no1 "wave-2 ran on a main MISSING wave-1's work (the exact class this barrier closes)" "witness=$(cat "$R/wave2-witness.txt" 2>/dev/null || echo none)"
w1land="$(grep -n "✓ wave 1 landed" "$TMP/i1-out.txt" | head -1 | cut -d: -f1)"
w2start="$(grep -n "═══ WAVE 2" "$TMP/i1-out.txt" | head -1 | cut -d: -f1)"
[ -n "$w1land" ] && [ -n "$w2start" ] && [ "$w1land" -lt "$w2start" ] \
  && ok "output ordering: wave-1 landing barrier completes BEFORE wave 2 launches" \
  || no1 "barrier/wave ordering wrong or lines missing" "land=$w1land start=$w2start"
[ -f "$R/packs/.done/one.txt" ] && [ -f "$R/packs/.done/two.txt" ] && ok "both packs archived to .done/" || no1 "packs not archived" "$(ls "$R/packs/.done" 2>&1)"

echo "── I2: blocked wave-1 (ungated strand) → wave-2 NOT run, VERIFY skipped, exit 2 ──"
R="$TMP/i2"; mkrepo "$R"; mkdir -p "$R/packs/wave-1" "$R/packs/wave-2"
printf '/v STRAND-UNGATED sneak something in\n\nbody\n' > "$R/packs/wave-1/one.txt"
printf '/v WAVE2CHECK should never run\n\nbody\n' > "$R/packs/wave-2/two.txt"
printf '/v plain verify\n\nbody\n' > "$R/packs/99-verify.txt"
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i2-out.txt" 2>&1; rc=$?
OUT="$(cat "$TMP/i2-out.txt")"
[ "$rc" = 2 ] && ok "run exits 2 (work remains — barrier blocked)" || no1 "expected exit 2, got $rc" "$(tail -12 "$TMP/i2-out.txt")"
printf '%s' "$OUT" | grep -q "stopping before later waves — wave 1 finished but its work is NOT all on main" \
  && ok "runner says WHY it stopped (barrier, not a pack failure)" || no1 "no barrier stop message" "$(tail -12 "$TMP/i2-out.txt")"
[ ! -f "$R/wave2-witness.txt" ] && ok "wave-2 pack was NOT run on the broken dependency" || no1 "wave-2 ran despite the blocked barrier" "$(cat "$R/wave2-witness.txt")"
[ -f "$R/packs/wave-2/two.txt" ] && ok "wave-2 pack still queued (resume re-runs it)" || no1 "wave-2 pack vanished" "$(ls "$R/packs/wave-2" 2>&1)"
git -C "$R" show main:wl-ungated.txt >/dev/null 2>&1 && no1 "UNGATED work reached main" "" || ok "ungated work stayed off main"

echo "── I3: single wave + VERIFY, blocked barrier → VERIFY pack skipped with the invalid-by-construction message ──"
R="$TMP/i3"; mkrepo "$R"; mkdir -p "$R/packs/wave-1"
printf '/v STRAND-UNGATED w1\n\nbody\n' > "$R/packs/wave-1/one.txt"
printf '/v WAVE2CHECK verify-must-not-run\n\nbody\n' > "$R/packs/99-verify.txt"
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i3-out.txt" 2>&1; rc=$?
grep -q "VERIFY pack skipped" "$TMP/i3-out.txt" && ok "VERIFY explicitly skipped (not silently run) on a blocked barrier" || no1 "no VERIFY-skipped message" "$(tail -12 "$TMP/i3-out.txt")"
[ ! -f "$R/wave2-witness.txt" ] && ok "verify pack did not execute against the incomplete main" || no1 "verify RAN against an incomplete main" ""
[ "$rc" = 2 ] && ok "exit 2" || no1 "expected exit 2, got $rc" ""

echo "── I4: RESUME contract — a re-run re-gates FIRST; leftover held work blocks the next run's earliest wave, and lands once gated ──"
# Live-fired hole this pins (found during development): run 1 blocked wave-1's ungated strand, but its
# pack had already archived — so run 2's earliest wave present was wave-2, which ran against a main
# still missing wave-1's work. The pre-run barrier closes exactly that.
R="$TMP/i4"; mkrepo "$R"; mkdir -p "$R/packs/wave-1" "$R/packs/wave-2"
printf '/v STRAND-UNGATED w1 work\n\nbody\n' > "$R/packs/wave-1/one.txt"
printf '/v WAVE2CHECK w2 consumer\n\nbody\n' > "$R/packs/wave-2/two.txt"
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i4-r1.txt" 2>&1; rc1=$?
[ "$rc1" = 2 ] && ok "run 1 blocks on the ungated strand (exit 2)" || no1 "run 1 expected exit 2, got $rc1" "$(tail -8 "$TMP/i4-r1.txt")"
# RUN 2 — nothing fixed yet: the pre-run barrier must refuse to launch wave-2 on the same broken dependency
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i4-r2.txt" 2>&1; rc2=$?
[ "$rc2" = 2 ] && ok "run 2 (nothing fixed) still exits 2" || no1 "run 2 expected exit 2, got $rc2" "$(tail -8 "$TMP/i4-r2.txt")"
grep -q "not launching any wave" "$TMP/i4-r2.txt" && ok "pre-run barrier refuses to launch waves over a previous run's stranded work" || no1 "no pre-run barrier stop message" "$(tail -10 "$TMP/i4-r2.txt")"
[ ! -f "$R/wave2-witness.txt" ] && ok "wave-2 did NOT run on the broken dependency across the resume boundary (the live-fired hole)" || no1 "RESUME HOLE: wave-2 ran while wave-1's work was off main" "witness=$(cat "$R/wave2-witness.txt" 2>/dev/null)"
# operator gates the stranded session (AGENT_REVIEW for its sid, read from the strand's runlog), re-runs
SID_I4="$(grep -hoE '"session_id":[[:space:]]*"[0-9a-f-]{36}"' "$R/packs/.runlogs/wave-1/one.log" | head -1 | grep -oE '[0-9a-f-]{36}')"
mkdir -p "$R/.v/artifacts"; printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${SID_I4}.md"
( cd "$R" && bash "$RUNNER" packs -j1 ) > "$TMP/i4-r3.txt" 2>&1; rc3=$?
[ "$rc3" = 0 ] && ok "run 3 (gated) exits 0 — backlog landed, wave-2 ran" || no1 "run 3 expected exit 0, got $rc3" "$(tail -10 "$TMP/i4-r3.txt")"
grep -q "pre-run backlog landed" "$TMP/i4-r3.txt" && ok "pre-run barrier LANDS the now-gated leftover before launching waves" || no1 "no pre-run landing line" "$(head -20 "$TMP/i4-r3.txt")"
grep -q ONMAIN "$R/wave2-witness.txt" 2>/dev/null && ok "wave-2 finally ran — and SAW the landed dependency on main" || no1 "wave-2 witness wrong after gated resume" "witness=$(cat "$R/wave2-witness.txt" 2>/dev/null || echo none)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
