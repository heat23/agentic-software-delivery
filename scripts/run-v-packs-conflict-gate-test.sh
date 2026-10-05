#!/usr/bin/env bash
# run-v-packs-conflict-gate-test.sh — BEHAVIORAL suite for the 2026-07-11 pre-run safety pair:
#   (a) the MULTI-BATCH GUARD in _preflight_and_dirs — a dir holding ≥2 batch roots (subdirs with their
#       own 00-README.md) is AUTO-RUN SEQUENTIALLY by default (2026-07-11 operator request: one full child
#       run per batch, oldest 00-README.md first, stop-on-first-failure, cross-batch lint informational,
#       exact dups quarantined on a REAL run only). V_PACK_MULTI_BATCH_SEQ=0 restores the old refusal;
#       V_PACK_ALLOW_MULTI_BATCH=1 forces ONE combined interleaved run with a loud warning; a CHILD run
#       whose batch is itself a nested multi-batch root refuses instead of recursing.
#   (b) the _conflict_gate pre-run lint — check-pack-conflicts.sh runs after the banner, warn-only by
#       default, blocking under V_PACK_CONFLICT_GATE=1, skippable via V_PACK_CONFLICT_CHECK=0, and
#       FAIL-OPEN when the lint script is missing (its absence must never block a run).
# All assertions drive main() under --dry-run (read-only: no lock, no claude dispatch, no dirs mutated
# beyond the guard's own refusal path). Portable bash 3.2/macOS.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
CHECKER="${CHECKER:-$HOME/.claude/scripts/check-pack-conflicts.sh}"
BAK="${RUNNER}.pre-conflict-gate-bak"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
[ -f "$CHECKER" ] || { echo "FATAL: checker not found: $CHECKER"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

mkpack(){ # $1=path $2=declared file
  mkdir -p "$(dirname "$1")"
  printf '/v task %s\n\n## Context\nctx\n\n## Files\n- %s — edit\n\n## Changes\n1. do it\n' "$(basename "$1")" "$2" > "$1"
}

drive(){ # $1=runner $2=packdir [env pairs as "K=V" ...] — main --dry-run; echoes output, returns its rc
  local rb="$1" p="$2"; shift 2
  ( cd "$TMP" && env "$@" bash -c "source '$rb' >/dev/null 2>&1 || true; main '$p' --dry-run" 2>&1 )
}

echo "── fixtures: one git repo, a multi-batch root, and single batches with/without collisions ──"
REPO="$TMP/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
MB="$REPO/multi"; mkdir -p "$MB/batch-a" "$MB/batch-b" "$MB/DONE-batch-z" "$MB/.claude"
echo "# map" > "$MB/batch-a/00-README.md"; echo "# map" > "$MB/batch-b/00-README.md"
echo "# map" > "$MB/DONE-batch-z/00-README.md"; echo "# map" > "$MB/.claude/00-README.md"
mkpack "$MB/batch-a/task.txt" "app/A.php"; mkpack "$MB/batch-b/task.txt" "app/B.php"
SB="$REPO/single"; mkpack "$SB/collide-a.txt" "routes/web.php"; mkpack "$SB/collide-b.txt" "routes/web.php"
CB="$REPO/cleanbatch"; mkpack "$CB/only.txt" "app/Only.php"

echo "── (1) multi-batch root AUTO-RUNS SEQUENTIALLY by default (one child dry-run per batch, oldest README first) ──"
touch -t 202601010101 "$MB/batch-b/00-README.md"   # batch-b authored FIRST → must run first
touch -t 202606060606 "$MB/batch-a/00-README.md"
o="$(drive "$RUNNER" "$MB")"; rc=$?
[ "$rc" -eq 0 ] && ok "sequential dry-run completes (exit 0)" || no "expected exit 0, got $rc" "$(printf '%s\n' "$o" | tail -3)"
printf '%s\n' "$o" | grep -q 'MULTI-BATCH root.*SEQUENTIALLY' && ok "sequential banner present" || no "no sequential banner" "$o"
printf '%s\n' "$o" | grep -q '1\. batch-b' && printf '%s\n' "$o" | grep -q '2\. batch-a' && ok "oldest-README-first ordering (batch-b before batch-a)" || no "ordering wrong" "$o"
printf '%s\n' "$o" | grep -q 'BATCH 1/2: batch-b' && ok "child runs launch in that order" || no "child order wrong" "$o"
[ "$(printf '%s\n' "$o" | grep -c 'would run wave')" -eq 2 ] && ok "each batch got its OWN dry-run report (no merged queue)" || no "per-batch dry-run reports missing/merged" "$o"
printf '%s\n' "$o" | grep -q 'DONE-batch-z' && no "DONE-* batch wrongly counted" "$o" || ok "DONE-*/hidden dirs not counted as batches"
printf '%s\n' "$o" | grep -q 'multi-batch run complete' && ok "clean-completion banner present" || no "no completion banner" "$o"

echo "── (1b) V_PACK_MULTI_BATCH_SEQ=0 restores the old REFUSAL (exit 1, names the batches + the safe loop) ──"
o="$(drive "$RUNNER" "$MB" V_PACK_MULTI_BATCH_SEQ=0)"; rc=$?
[ "$rc" -eq 1 ] && ok "refused with exit 1" || no "expected exit 1, got $rc" "$(printf '%s\n' "$o" | tail -2)"
printf '%s\n' "$o" | grep -q 'MULTI-BATCH root' && ok "refusal message present" || no "no MULTI-BATCH message" "$o"
printf '%s\n' "$o" | grep -q 'batch-a' && printf '%s\n' "$o" | grep -q 'batch-b' && ok "both batches named" || no "batches not listed" "$o"
printf '%s\n' "$o" | grep -q 'for b in ' && ok "sequential per-batch loop suggested" || no "no sequential loop hint" "$o"

echo "── (2) V_PACK_ALLOW_MULTI_BATCH=1 proceeds, with a loud interleave warning ──"
o="$(drive "$RUNNER" "$MB" V_PACK_ALLOW_MULTI_BATCH=1)"; rc=$?
[ "$rc" -eq 0 ] && ok "override proceeds to the dry-run report (exit 0)" || no "override exited $rc" "$(printf '%s\n' "$o" | tail -3)"
printf '%s\n' "$o" | grep -q '⚠ MULTI-BATCH root: proceeding' && ok "override warns about interleaving" || no "no override warning" "$o"

echo "── (2b) multi-batch DETECTION always runs the cross-batch lint (sequential + refusal + override paths) ──"
# operator request 2026-07-11: the refusal used to exit before the lint, so colliding batches were only
# discovered mid-run. Fixture: two batches declaring the SAME file.
MB2="$REPO/multi2"; mkdir -p "$MB2/batch-x" "$MB2/batch-y"
echo "# map" > "$MB2/batch-x/00-README.md"; echo "# map" > "$MB2/batch-y/00-README.md"
mkpack "$MB2/batch-x/task.txt" "app/Shared.php"; mkpack "$MB2/batch-y/task.txt" "app/Shared.php"
o="$(drive "$RUNNER" "$MB2" V_PACK_CONFLICT_SCRIPT="$CHECKER")"; rc=$?
[ "$rc" -eq 0 ] && ok "sequential mode: cross-batch collision does NOT block (sequencing is its remedy)" || no "sequential mode blocked on CROSS (exit $rc)" "$(printf '%s\n' "$o" | tail -3)"
printf '%s\n' "$o" | grep -q 'CROSS-BATCH OVERLAP.*app/Shared.php' && ok "sequential mode surfaces the collision (informational)" || no "collision missing from sequential banner" "$o"
printf '%s\n' "$o" | grep -q 'INFORMATIONAL' && ok "sequential lint banner explains the downgrade" || no "no informational framing" "$o"
o="$(drive "$RUNNER" "$MB2" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_MULTI_BATCH_SEQ=0)"; rc=$?
[ "$rc" -eq 1 ] && ok "refusal path (SEQ=0): colliding multi-batch root refused (exit 1)" || no "expected exit 1, got $rc" "$(printf '%s\n' "$o" | tail -2)"
printf '%s\n' "$o" | grep -q 'cross-batch conflict lint' && ok "refusal includes the lint banner" || no "no lint banner in refusal" "$o"
printf '%s\n' "$o" | grep -q 'CROSS-BATCH OVERLAP.*app/Shared.php' && ok "refusal surfaces the cross-batch collision" || no "collision missing from refusal" "$o"
o="$(drive "$RUNNER" "$MB2" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_CONFLICT_CHECK=0 V_PACK_MULTI_BATCH_SEQ=0)"; rc=$?
printf '%s\n' "$o" | grep -q 'conflict lint' && no "lint ran in refusal despite CHECK=0" "$o" || ok "V_PACK_CONFLICT_CHECK=0 suppresses the refusal-path lint"
o="$(drive "$RUNNER" "$MB2" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_CONFLICT_CHECK=0)"; rc=$?
printf '%s\n' "$o" | grep -q 'conflict lint' && no "lint ran in sequential mode despite CHECK=0" "$o" || ok "V_PACK_CONFLICT_CHECK=0 suppresses the sequential-path lint"
o="$(drive "$RUNNER" "$MB2" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_ALLOW_MULTI_BATCH=1)"; rc=$?
printf '%s\n' "$o" | grep -q 'CROSS-BATCH OVERLAP.*app/Shared.php' && ok "override path also surfaces the collision (via the pre-run gate)" || no "override path lost the lint" "$o"
[ "$rc" -eq 0 ] && ok "override + warn-only lint still proceeds to the dry-run report" || no "override run exited $rc" "$(printf '%s\n' "$o" | tail -2)"

echo "── (2c) STOP-ON-FAILURE + recursion guard: a nested multi-batch CHILD refuses; later batches never run ──"
MB3="$REPO/multi3"; mkdir -p "$MB3/c-old" "$MB3/m-mid/sub-a" "$MB3/m-mid/sub-b" "$MB3/z-new"
echo "# map" > "$MB3/c-old/00-README.md"; echo "# map" > "$MB3/m-mid/00-README.md"; echo "# map" > "$MB3/z-new/00-README.md"
echo "# map" > "$MB3/m-mid/sub-a/00-README.md"; echo "# map" > "$MB3/m-mid/sub-b/00-README.md"
mkpack "$MB3/c-old/task.txt" "app/COld.php"; mkpack "$MB3/z-new/task.txt" "app/ZNew.php"
mkpack "$MB3/m-mid/sub-a/task.txt" "app/SubA.php"; mkpack "$MB3/m-mid/sub-b/task.txt" "app/SubB.php"
touch -t 202601010101 "$MB3/c-old/00-README.md"; touch -t 202603030303 "$MB3/m-mid/00-README.md"; touch -t 202606060606 "$MB3/z-new/00-README.md"
o="$(drive "$RUNNER" "$MB3")"; rc=$?
[ "$rc" -ne 0 ] && ok "chain stops with the failing child's nonzero exit (rc=$rc)" || no "chain did not stop (exit 0)" "$o"
printf '%s\n' "$o" | grep -q 'BATCH 1/3: c-old' && ok "oldest batch ran first" || no "c-old did not run first" "$o"
printf '%s\n' "$o" | grep -q "batch 'm-mid' exited rc=" && ok "failing batch named in the stop report" || no "no stop report" "$o"
printf '%s\n' "$o" | grep -q 'not run: z-new' && ok "remaining batch listed as not-run" || no "not-run list missing" "$o"
printf '%s\n' "$o" | grep -q 'BATCH 3/3' && no "later batch ran despite the failure" "$o" || ok "later batch was NOT launched after the failure"

echo "── (2d) --dry-run is READ-ONLY: exact duplicates are reported but NOT quarantined ──"
MB4="$REPO/multi4"; mkdir -p "$MB4/d-one" "$MB4/d-two"
echo "# map" > "$MB4/d-one/00-README.md"; echo "# map" > "$MB4/d-two/00-README.md"
mkpack "$MB4/d-one/samejob.txt" "app/Dup.php"; mkpack "$MB4/d-two/samejob.txt" "app/Dup.php"
cp "$MB4/d-one/samejob.txt" "$MB4/d-two/samejob.txt"   # identical body → exact DUPLICATE
o="$(drive "$RUNNER" "$MB4" V_PACK_CONFLICT_SCRIPT="$CHECKER")"; rc=$?
printf '%s\n' "$o" | grep -q 'DUPLICATE' && ok "duplicate surfaced in the sequential lint" || no "duplicate not surfaced" "$o"
[ -f "$MB4/d-one/samejob.txt" ] && [ -f "$MB4/d-two/samejob.txt" ] && ok "dry-run did not move/quarantine any pack" || no "dry-run mutated the queue" "$(ls "$MB4"/d-*/ 2>&1)"

echo "── (3) a SINGLE batch (even with wave subfolders) never trips the guard ──"
WB="$REPO/wavebatch"; mkdir -p "$WB/wave-1" "$WB/wave-2"
echo "# map" > "$WB/00-README.md"
mkpack "$WB/wave-1/one.txt" "app/One.php"; mkpack "$WB/wave-2/two.txt" "app/Two.php"
o="$(drive "$RUNNER" "$WB")"; rc=$?
[ "$rc" -eq 0 ] && ok "wave-subfolder batch runs normally (exit 0)" || no "single batch refused (exit $rc)" "$o"
printf '%s\n' "$o" | grep -q 'MULTI-BATCH' && no "guard fired on wave subfolders" "$o" || ok "no multi-batch message on a single batch"

echo "── (4) conflict lint WARNS by default (run continues) and names the collision ──"
o="$(drive "$RUNNER" "$SB" V_PACK_CONFLICT_SCRIPT="$CHECKER")"; rc=$?
[ "$rc" -eq 0 ] && ok "warn mode: dry-run completes (exit 0)" || no "warn mode exited $rc" "$(printf '%s\n' "$o" | tail -3)"
printf '%s\n' "$o" | grep -q 'PACK-CONFLICT LINT' && ok "lint banner shown" || no "no lint banner" "$o"
printf '%s\n' "$o" | grep -q 'SAME-WAVE COLLISION.*routes/web.php' && ok "collision surfaced pre-run" || no "collision not surfaced" "$o"

echo "── (5) V_PACK_CONFLICT_GATE=1 BLOCKS the run on hard findings (exit 1) ──"
o="$(drive "$RUNNER" "$SB" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_CONFLICT_GATE=1)"; rc=$?
[ "$rc" -eq 1 ] && ok "gate blocks with exit 1" || no "gate did not block (exit $rc)" "$(printf '%s\n' "$o" | tail -2)"
printf '%s\n' "$o" | grep -q 'pack-conflict gate' && ok "gate die message present" || no "no gate message" "$o"

echo "── (6) a CLEAN queue passes the armed gate silently ──"
o="$(drive "$RUNNER" "$CB" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_CONFLICT_GATE=1)"; rc=$?
[ "$rc" -eq 0 ] && ok "clean queue + armed gate: run proceeds (exit 0)" || no "clean queue blocked (exit $rc)" "$o"
printf '%s\n' "$o" | grep -q 'PACK-CONFLICT LINT' && no "lint banner on a clean queue" "$o" || ok "no lint noise on a clean queue"

echo "── (7) V_PACK_CONFLICT_CHECK=0 skips the lint entirely ──"
o="$(drive "$RUNNER" "$SB" V_PACK_CONFLICT_SCRIPT="$CHECKER" V_PACK_CONFLICT_CHECK=0)"; rc=$?
printf '%s\n' "$o" | grep -q 'PACK-CONFLICT' && no "lint ran despite CHECK=0" "$o" || ok "lint skipped under V_PACK_CONFLICT_CHECK=0"
[ "$rc" -eq 0 ] && ok "run proceeds with lint off" || no "run failed with lint off (exit $rc)" "$o"

echo "── (8) FAIL-OPEN: a missing lint script never blocks (even with the gate armed) ──"
o="$(drive "$RUNNER" "$SB" V_PACK_CONFLICT_SCRIPT="$TMP/does-not-exist.sh" V_PACK_CONFLICT_GATE=1)"; rc=$?
[ "$rc" -eq 0 ] && ok "missing lint script: run proceeds (fail-open)" || no "missing script blocked the run (exit $rc)" "$o"

echo "── (9) RED oracle vs pre-fix snapshot: old runner merged the multi-batch root silently ──"
if [ -f "$BAK" ]; then
  o="$(drive "$BAK" "$MB")"; rc=$?
  { [ "$rc" -eq 0 ] && ! printf '%s\n' "$o" | grep -q 'MULTI-BATCH'; } \
    && ok "red-oracle: pre-fix runner accepted the multi-batch root (the bug this guard closes)" \
    || no "red-oracle: unexpected pre-fix behavior (exit $rc)" "$(printf '%s\n' "$o" | head -3)"
else
  echo "  WARN red-oracle snapshot missing ($BAK)"
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
