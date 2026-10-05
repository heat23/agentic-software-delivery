#!/usr/bin/env bash
# run-v-packs-reconcile-test.sh — BEHAVIORAL harness for F1 (parked-pack SID reconciliation) and
# F2 (fully-merged branch-ref GC) in the wave-aware runner.
#
# WHY (forensic 2026-07-01, R4 audit-fix-packs run on a production repo): the landing was CLEAN — all 6 packs'
# fixes were on main — but the pack folder disagreed with reality on two counts:
#   F1  a pack that was PARKED to .needs-review/ (headless /v did 0 turns) had its stranded worktree
#       recovered and merged to main by a LATER drain. run-v-packs never told the pack folder, so the
#       .txt file sat in .needs-review/ forever contradicting main.
#   F2  a fully-merged build/*|fix/* branch ref (0 commits ahead, ancestor-of-main) survived as dangling
#       debris because its own cleanup path never ran (worktree removed by other means).
# This harness proves both fixes AND their safety rails (never touch a live worktree, never touch a
# branch with commits ahead, never touch a non-/v branch) against the REAL runner + REAL drain script.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
DRAINER="${DRAINER:-$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh}"
[ -f "$RUNNER" ]  || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer not found: $DRAINER"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
no1(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t reconcile_parked_by_sid)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose reconcile_parked_by_sid (F1 not shipped)"; exit 1; }
[ "$(type -t gc_merged_branches)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose gc_merged_branches (F2 not shipped)"; exit 1; }

# ══════════════════════════════════════════════════════════════════════════════
# F1 — unit-level: reconcile_parked_by_sid moves a matched pack, ignores everything else
# ══════════════════════════════════════════════════════════════════════════════
echo "── F1 unit: reconcile_parked_by_sid ──"
P="$TMP/u1"; PACK_ABS="$P/.v-prompt-packs/demo"; LOG_DIR="$PACK_ABS/.runlogs"; DONE_DIR="$PACK_ABS/.done"; NEEDS_DIR="$PACK_ABS/.needs-review"
mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR"
SIDA="a1a1a1a1-1111-4222-8333-444455556666"
SIDB="cafefeed-0000-4000-8000-000000000000"

# a parked pack whose OWN .runlogs result event carries SIDA (0-turn inconclusive — still a valid result)
printf '/v fix the docs\n\nbody\n' > "$NEEDS_DIR/EXAMPLE-DOCS-HARDENING.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s"}\n' "$SIDA" > "$LOG_DIR/EXAMPLE-DOCS-HARDENING.log"

# a SECOND parked pack under SIDB — must be left alone (no matching landed sid)
printf '/v unrelated hardening\n\nbody\n' > "$NEEDS_DIR/OTHER-PACK.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s"}\n' "$SIDB" > "$LOG_DIR/OTHER-PACK.log"

DRAIN_OUT="── landing stranded (ended) worktree fixes safely ──
  ✓ merged+cleaned: fix/example-docs-hardening-${SIDA%%-*} (sid=$SIDA)
v-drain: considered=1 drained=1 deferred=0 failed=0 already-merged=0 skipped-LIVE=0; GC'd 0 stale marker(s)."

reconcile_parked_by_sid "$DRAIN_OUT" >/dev/null 2>&1
[ -f "$DONE_DIR/EXAMPLE-DOCS-HARDENING.txt" ]    && ok "matched pack (sid=$SIDA) moved .needs-review/ -> .done/" || no1 "matched pack was NOT reconciled to .done/"
[ ! -f "$NEEDS_DIR/EXAMPLE-DOCS-HARDENING.txt" ] && ok "matched pack no longer sits in .needs-review/"          || no1 "matched pack still present in .needs-review/ (dup, not moved)"
[ -f "$NEEDS_DIR/OTHER-PACK.txt" ]          && ok "non-matched pack (sid=$SIDB) left untouched in .needs-review/" || no1 "non-matched pack was wrongly moved"
[ ! -f "$DONE_DIR/OTHER-PACK.txt" ]         && ok "non-matched pack did NOT leak into .done/"               || no1 "non-matched pack wrongly landed in .done/"

echo "── F1 unit: no landed sids in drain output -> no-op, never crashes ──"
mkdir -p "$P/.v-prompt-packs/demo2/.needs-review" "$P/.v-prompt-packs/demo2/.runlogs" "$P/.v-prompt-packs/demo2/.done"
PACK_ABS="$P/.v-prompt-packs/demo2"; LOG_DIR="$PACK_ABS/.runlogs"; DONE_DIR="$PACK_ABS/.done"; NEEDS_DIR="$PACK_ABS/.needs-review"
printf '/v x\n\nx\n' > "$NEEDS_DIR/UNTOUCHED.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"deadbeef-0000-4000-8000-000000000000"}\n' > "$LOG_DIR/UNTOUCHED.log"
reconcile_parked_by_sid "── landing stranded ── nothing drained this pass." >/dev/null 2>&1
rc=$?
[ "$rc" = 0 ] && ok "empty-landed-sid drain output returns 0 (no crash)" || no1 "reconcile_parked_by_sid errored on no-landed-sid input" "rc=$rc"
[ -f "$NEEDS_DIR/UNTOUCHED.txt" ] && ok "pack stays parked when nothing was drained" || no1 "pack wrongly moved with no landed sids"

# ══════════════════════════════════════════════════════════════════════════════
# F1 — CLASS-LEVEL regression fixture: pack parked at 0-turns AND a same-SID worktree is landed by
# the REAL v-drain-deferred-merges.sh (merge-back stubbed so no full /v gauntlet is needed) => the
# runner MUST reconcile the folder end-to-end. This is the exact scenario the forensic post-mortem
# found: a clean landing that left silent .needs-review/ residue contradicting main.
# ══════════════════════════════════════════════════════════════════════════════
echo "── F1 CLASS FIXTURE: parked-at-0-turns pack + same-SID stranded worktree landed by the drain -> reconciled ──"
R="$TMP/class-repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1

SID_PARK="9a9a9a9a-1111-4222-8333-444455556666"   # the pack's OWN pinned session-id (run-v-packs assigned it)
DEAD_PID=999999   # beyond macOS pid_max (99998) — can NEVER be live; a freshly-freed pid gets RECYCLED under churn (bit live 2026-07-02: ~1000 pids/s wraps the counter in <2 min)

BR="fix/example-docs-hardening-${SID_PARK%%-*}"
( cd "$R" && git checkout -q -b "$BR" && echo fix > example.f && git add -A && git commit -qm "example docs" && git checkout -q main ) >/dev/null 2>&1
WT="$R/.worktrees/example-docs"; git -C "$R" worktree add -q "$WT" "$BR" >/dev/null 2>&1
printf '%s %s %s\n' "$SID_PARK" "$DEAD_PID" "$(date +%s)" > "$WT/.claude-session-lock"   # session ENDED (dead pid) -> drainable
# C-1 (round-3, 2026-07-01): landing now requires durable gauntlet evidence — this fixture models a
# GATED session (the behavior under test is sid-reporting + folder reconciliation, not the verdict
# gate; that has its own suite: v-drain-verdict-gate-test.sh).
mkdir -p "$R/.v/artifacts"
printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${SID_PARK}.md"

# a merge-back STUB (same seam v-drain-and-telemetry-test.sh uses) so this test needs no real /v gauntlet —
# it only has to prove the drain reports "sid=$SID_PARK" and reconcile_parked_by_sid consumes that report.
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/merge-back.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB/merge-back.sh"

PACK_ABS="$R/.v-prompt-packs/r4"; LOG_DIR="$PACK_ABS/.runlogs"; DONE_DIR="$PACK_ABS/.done"; NEEDS_DIR="$PACK_ABS/.needs-review"
mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR"
printf '/v add example docs\n\nbody\n' > "$NEEDS_DIR/EXAMPLE-DOCS-HARDENING.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s"}\n' "$SID_PARK" > "$LOG_DIR/EXAMPLE-DOCS-HARDENING.log"

REAL_DRAIN_OUT="$(V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" 2>&1)"
printf '%s\n' "$REAL_DRAIN_OUT" | grep -qE "merged\+cleaned:.*\(sid=${SID_PARK}\)" \
  && ok "v-drain-deferred-merges.sh reports the landed worktree's sid on its success line" \
  || no1 "drain output missing '(sid=$SID_PARK)' on the merged+cleaned line" "$REAL_DRAIN_OUT"

reconcile_parked_by_sid "$REAL_DRAIN_OUT" >/dev/null 2>&1
[ -f "$DONE_DIR/EXAMPLE-DOCS-HARDENING.txt" ] && ok "CLASS FIXTURE: parked pack reconciled .needs-review/ -> .done/ end-to-end (real drain + real reconcile)" \
  || no1 "CLASS FIXTURE FAILED: parked pack still contradicts main after a clean same-SID landing" "$(ls "$NEEDS_DIR" "$DONE_DIR" 2>&1)"
[ ! -f "$NEEDS_DIR/EXAMPLE-DOCS-HARDENING.txt" ] && ok "…and no longer sits in .needs-review/" || no1 "pack duplicated across both dirs"

# ══════════════════════════════════════════════════════════════════════════════
# F2 — gc_merged_branches: prune fully-merged /v branches, never touch anything unsafe
# ══════════════════════════════════════════════════════════════════════════════
echo "── F2: gc_merged_branches ──"
G="$TMP/gc-repo"; mkdir -p "$G"
( cd "$G" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1

# (a) fully-merged /v branch, 0 ahead, no worktree -> MUST be pruned
( cd "$G" && git checkout -q -b "fix/prune-example-test-5e55a000" && echo a > a.f && git add -A && git commit -qm a \
  && git checkout -q main && git merge -q --no-ff "fix/prune-example-test-5e55a000" -m mergeA ) >/dev/null 2>&1

# (b) build/* branch with a commit AHEAD of main (never merged) -> MUST survive
( cd "$G" && git checkout -q -b "build/in-flight-11112222" && echo b > b.f && git add -A && git commit -qm b && git checkout -q main ) >/dev/null 2>&1

# (c) fully-merged fix/* branch that is STILL checked out in a live worktree -> MUST survive (never touch a live worktree)
( cd "$G" && git checkout -q -b "fix/live-checkout-33334444" && echo c > c.f && git add -A && git commit -qm c \
  && git checkout -q main && git merge -q --no-ff "fix/live-checkout-33334444" -m mergeC ) >/dev/null 2>&1
git -C "$G" worktree add -q "$G/.worktrees/live-checkout" "fix/live-checkout-33334444" >/dev/null 2>&1

# (d) fully-merged branch OUTSIDE the /v naming convention -> MUST survive (scope guard: never touch a non-/v branch)
( cd "$G" && git checkout -q -b "feature/manual-something" && echo d > d.f && git add -A && git commit -qm d \
  && git checkout -q main && git merge -q --no-ff "feature/manual-something" -m mergeD ) >/dev/null 2>&1

gc_merged_branches "$G" >/dev/null 2>&1

_branches_after="$(git -C "$G" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)"
printf '%s\n' "$_branches_after" | grep -qxF "fix/prune-example-test-5e55a000" \
  && no1 "fully-merged fix/* branch with 0 commits ahead SURVIVED (F2 not pruning)" \
  || ok "fully-merged fix/* branch, 0 ahead, no worktree -> pruned"
printf '%s\n' "$_branches_after" | grep -qxF "build/in-flight-11112222" \
  && ok "build/* branch with commits ahead of main -> left intact" \
  || no1 "branch with UNIQUE COMMITS AHEAD was deleted — data-loss risk"
printf '%s\n' "$_branches_after" | grep -qxF "fix/live-checkout-33334444" \
  && ok "fully-merged branch STILL CHECKED OUT in a worktree -> left intact (never touch a live worktree)" \
  || no1 "a branch checked out in a live worktree was deleted"
printf '%s\n' "$_branches_after" | grep -qxF "feature/manual-something" \
  && ok "fully-merged branch OUTSIDE build/*|fix/* convention -> left intact (scope guard)" \
  || no1 "a non-/v branch was deleted — scope leak"

echo "── F2: opt-out wiring (V_PACK_BRANCH_GC=0) is present in the end-of-run sweep ──"
# PHASE 6 (2026-07-04): main() was decomposed into skeleton helpers; the end-of-run drain/backfill/GC
# block now lives in _final_sweep, which main() calls. Same precedent as the W-LAND note below: the pin
# follows the call chain — EVERY link must hold, so an unwired sweep still bites.
mn="$(declare -f main 2>/dev/null)"
fs="$(declare -f _final_sweep 2>/dev/null)"
echo "$mn" | grep -q '_final_sweep' && ok "main() calls _final_sweep (end-of-run drain/backfill/GC)" || no1 "_final_sweep not wired into main()"
echo "$fs" | grep -q 'V_PACK_BRANCH_GC' && ok "_final_sweep gates the branch sweep behind V_PACK_BRANCH_GC" || no1 "V_PACK_BRANCH_GC opt-out not wired into _final_sweep()"
# W-LAND (2026-07-02): the drain+reconcile sequence moved from main() into _land_and_reconcile so the
# per-wave landing barrier and the end-of-run sweep share ONE copy (anti contract-drift). The pin now
# follows the call chain — ALL links must hold, so an unwired reconcile still bites:
lr="$(declare -f _land_and_reconcile 2>/dev/null)"
echo "$fs" | grep -q '_land_and_reconcile' && ok "_final_sweep calls _land_and_reconcile (the shared landing pass)" || no1 "_land_and_reconcile not wired into _final_sweep()"
echo "$lr" | grep -q 'reconcile_parked_by_sid' && ok "_land_and_reconcile calls reconcile_parked_by_sid after the drain" || no1 "reconcile_parked_by_sid not wired into _land_and_reconcile()"
echo "$fs" | grep -q 'gc_merged_branches "\$REPO"' && ok "_final_sweep calls gc_merged_branches after the drain" || no1 "gc_merged_branches not wired into _final_sweep()"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
