#!/usr/bin/env bash
# harness-sweep-skip: this IS the sweep runner, not a test (it matches *test* via "test-sweep").
# harness-test-sweep.sh — run the ~/.claude harness test suite and report pass/fail honestly.
#
# WHY THIS EXISTS: the harness is validated by an ad-hoc `for t in <dir>/*test*.sh; do bash "$t"`
# loop. That glob ALSO catches runtime scripts whose names merely contain "test" (e.g.
# v-gauntlet-attest.sh — "at-test"), which then "fail" the sweep for reasons unrelated to any test
# (v-gauntlet-attest exits 3 because the ambient session has no gauntlet artifacts). A flaky/false
# sweep undermines the one thing that validates every ~/.claude change. This runner skips any file
# carrying a `harness-sweep-skip:` marker comment, so runtime scripts are excluded by design and the
# sweep result is trustworthy.
#
# Usage:
#   bash harness-test-sweep.sh                 # sweep the canonical harness test dirs
#   bash harness-test-sweep.sh <dir> [<dir>..] # sweep explicit dirs (used by the self-test)
# Exit 0 iff every NON-skipped test passed.
set -u
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

if [ "$#" -gt 0 ]; then
  SWEEP_DIRS=("$@")
else
  SWEEP_DIRS=(
    "$CLAUDE_DIR/skills/v-session-log/references"
    "$CLAUDE_DIR/skills/v/references"
    "$CLAUDE_DIR/hooks"
    "$CLAUDE_DIR/scripts"
    # ── Orphan-harness wiring (2026-08-02 ecosystem audit) ────────────────────
    # Each of these four dirs holds a real, currently-PASSING bash TDD harness
    # that this sweep never ran, so its coverage could rot silently — the exact
    # "orphan *-test.sh rot" class the premature-completion guidance warns about.
    # Verified at wiring time: v-run-waves-test.sh 27/27,
    # capture-quarantine-test.sh 4/4, handoff-merge-deferred-test.sh 7/7,
    # v-self-audit-test.sh 87/87.
    "$CLAUDE_DIR/skills"
    "$CLAUDE_DIR/skills/v-merge-all"
    "$CLAUDE_DIR/skills/v-handoff/references"
    # ── hooks/lib orphan wiring (2026-08-10) ──────────────────────────────────
    # Same orphan-rot class as the four dirs above, found the same way: the sweep
    # reported 462 both BEFORE and AFTER a new harness was added under hooks/lib,
    # and a count that does not move when the surface grows is itself the finding.
    #
    # `hooks/` is swept but the glob is deliberately non-recursive, so hooks/lib/
    # was invisible — NOT by adjudication (unlike forensic-2026-06-18-regressions
    # below, whose exclusion is load-bearing and must stay), but purely as a side
    # effect. Eight harnesses / ~100 assertions had never run in any "full" sweep,
    # including the two that guard the most load-bearing code in the tree:
    #   validation-test.sh              27/27 — hooks/lib/validation.sh, the artifact validator
    #   panel-review-validation-test.sh 34/34 — the adversarial-panel review gate
    #   session-lock-{format,liveness-stale-pid,owning-pid}-test.sh  7/4/6 — the suite mutex
    #   git-main-root-test.sh            6/6  — shared-root resolution for worktree paths
    #   stop-rearm-escape-marker-test.sh 5/5  — escape marker placement
    #   stop-rearm-chain-duration-test.sh 14/14 — W-CHAIN-S
    #     (11 `ok` CALL SITES but 14 runtime assertions: T4 loops over 5 garbage values. Counting
    #      call sites instead of assertions is how the original "11/11" here was wrong. The other
    #      7 counts in this block were independently re-run and are accurate.)
    # Verified at wiring time: all 8 pass standalone (rc=0), so this adds coverage
    # without turning the sweep red. hooks/lib has no subdirectories holding
    # harnesses, so the non-recursive glob is sufficient here.
    "$CLAUDE_DIR/hooks/lib"
    "$CLAUDE_DIR/skills/v-self-audit/references"
    # DELIBERATELY NOT WIRED:
    #   $CLAUDE_DIR/skills/v-session-log/references/forensic-2026-06-18-regressions
    # It holds r1-shared-head-fallback-zero-test.sh, RED on its Arm B2 only.
    # THIS IS ALREADY ADJUDICATED — see that dir's own README.md (2026-06-19), which
    # marks the harness QUARANTINED and Arm B2 DEFERRED: the real over-claim was fixed
    # at the SOURCE (v-gather-session-data.sh emits commits_added=0 for
    # shared_head_fallback; regression-guarded by w-conc-fix-test.sh T18a). Arm B2 is a
    # secondary validator-level backstop intentionally NOT added, because blocking the
    # skeleton shape (commits>0 + success + no commit_attribution block) was judged to
    # have a corpus-wide false-positive surface — that shape is structurally identical
    # to an honest unwitnessed solo session, which is exactly why _r1a_* is advisory.
    # So: the dir stays out because its one RED is a PARKED known-issue, not an unfixed
    # defect. Do NOT silence it with a skip marker, and do NOT "fix" Arm B2 without
    # re-adjudicating that README verdict.
    # RE-ADJUDICATION EVIDENCE (2026-08-02): a scan of the full corpus of real SESSION_LOG_*.yaml
    # files found ZERO missing a commit_attribution block — build-skeleton.py's F1
    # fix has fully propagated, so the false-positive surface the 2026-06-19 verdict
    # feared may no longer exist. That is suggestive, NOT sufficient: it is one operator's
    # tree at one point in time, and non-build-skeleton writers (v-session-log-salvage.py)
    # were not confirmed to populate the block. Before promoting B2 to BLOCKING, confirm
    # every log-writing path emits commit_attribution and re-run that corpus scan as a
    # landing gate. (Dir sits UNDER an already-swept path but is invisible to the
    # non-recursive glob — that non-recursion is load-bearing here.)
  )
fi

# ── Cross-agent sweep serialization (cycle-2 F5, 2026-07-03) ────────────────────────────────────
# Two concurrent sweeps produce false FAILs (proven in practice: pre-flight runner + QA reviewer ran
# this script simultaneously → orch-def-2026-06-24-test.sh failed once under contention and passed uncontended ×3). Serialize
# repo-wide via the existing v-suite-lock.sh mkdir-mutex (macOS-portable, fail-open on timeout,
# stale-steal for crashed holders — never blocks a sweep forever). Opt-out: V_NO_SUITE_LOCK=1.
_SWEEP_LOCK="$CLAUDE_DIR/skills/v/references/v-suite-lock.sh"
_SWEEP_LOCK_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-sweep-$$}}"
if [ -f "$_SWEEP_LOCK" ]; then
  # V_SUITE_LOCK_HOLDER_PID=$$ (this long-lived sweep process) opts in to dead-holder reclaim:
  # a SIGKILLed sweep's waiters steal immediately instead of burning the fail-open timeout.
  # Release happens in the single EXIT trap below (bash keeps ONE trap per signal — a second
  # `trap ... EXIT` statement REPLACES the first; that clobbering leaked the lock on 2026-07-04).
  V_SUITE_LOCK_HOLDER_PID=$$ bash "$_SWEEP_LOCK" acquire "$CLAUDE_DIR" "$_SWEEP_LOCK_SID" 900 1800 || true
fi

pass=0; fail=0; skip=0
failed_list=""
skipped_list=""

# Build the run-list (non-skip harnesses) and the skip-list in one pass. Skip markers are recorded
# immediately (cheap, no subprocess).
run_list=()
for d in "${SWEEP_DIRS[@]}"; do
  [ -d "$d" ] || continue
  for t in "$d"/*test*.sh; do
    [ -f "$t" ] || continue
    base="$(basename "$t")"
    if grep -qE '^# *harness-sweep-skip:' "$t" 2>/dev/null; then
      skip=$((skip + 1)); skipped_list="${skipped_list} ${base}"; continue
    fi
    run_list+=("$t")
  done
done

# Bounded PARALLEL sweep (audit 2026-06-18, P0.2): the old strictly-sequential `for` loop ran ~100
# harnesses back-to-back and blew the wrapper's 580s spawnSync budget, so the summary line never
# printed and the orphan-killer meta-net was unreliable. Run the harnesses through a bounded job pool
# instead. Default concurrency = min(6, ncpu) — enough to finish well under budget while leaving
# headroom, and conservative enough that harnesses which still share fixed /tmp fixture paths are
# unlikely to collide (the heavily-collision-prone v-concurrency-test.sh was made hermetic in the same
# audit). Override with HARNESS_SWEEP_JOBS (set =1 for a strictly-serial run if a collision is ever
# suspected). Each harness's rc is written to its OWN result file (the old single shared $_out file was
# itself unsafe under any parallelism), then aggregated DETERMINISTICALLY after all jobs drain — so the
# pass/fail counts and ordering of the FAILURES list do not depend on completion order.
_ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
case "$_ncpu" in ''|*[!0-9]*) _ncpu=4 ;; esac
JOBS="${HARNESS_SWEEP_JOBS:-}"
if [ -z "$JOBS" ]; then JOBS=6; [ "$_ncpu" -lt 6 ] && JOBS="$_ncpu"; fi
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac

RESDIR="$(mktemp -d 2>/dev/null || echo "/tmp/harness-sweep-res.$$")"
mkdir -p "$RESDIR" 2>/dev/null
# RETURN/EXIT cleanup of the per-harness result dir. NB: bash keeps ONE trap per signal — this
# statement REPLACES the suite-lock release trap set above (that clobbering leaked the lock on
# 2026-07-04), so the release is folded in here. Keep any future EXIT cleanup in THIS trap.
trap 'rm -rf "$RESDIR" 2>/dev/null; [ -f "${_SWEEP_LOCK:-}" ] && bash "$_SWEEP_LOCK" release "$CLAUDE_DIR" "$_SWEEP_LOCK_SID" >/dev/null 2>&1 || true' EXIT

# _run_one <index> <harness_path> — run one harness, record "<rc> <basename>" to a result file.
_run_one() {
  local idx="$1" t="$2" base rc
  base="$(basename "$t")"
  # === W-SWEEP-ISO (2026-08-11) — per-job stop-rearm state dir ==============================
  # `hooks/lib/stop-rearm.sh` defaults its state dir to $HOME/.claude/runtime/stop-rearm — a fixed
  # ABSOLUTE path, unlike the rest of the corpus which scopes fixtures under a mktemp'd repo. Three
  # harnesses (orch-hardening-2026-06-23, uncommitted-changes-gate, dead-hook-session-scope) drive a
  # rearm-using hook against the REAL $HOME with a fixed synthetic SID, so they write into the
  # operator's live runtime dir; such files were observed there on 2026-08-11.
  #
  # HONEST SCOPE — this is PREVENTIVE, not a fix for observed flakiness. A 3-lens panel established
  # that no current harness can flake from this: all three writers pass `stop_hook_active:false`,
  # and rearm_gate gates its read/increment behind `active=true` (stop-rearm.sh:97), so they only
  # ever clobber, never read a sibling's file. Synthetic SIDs also cannot collide with real session
  # UUIDs. What this closes is the LATENT case — one future harness using active=true with a
  # shared SID — plus the production pollution itself.
  #
  # PARTIAL BY CONSTRUCTION: this isolates the stop-rearm mechanism only. Nine other harnesses
  # write fixed-SID paths into the real ~/.claude/runtime/ with the identical shape, and
  # hooks/lib/gauntlet-witness.sh:29 keeps a truly global un-keyed secret there. Do NOT read
  # "stop-rearm isolated" as "the collision class is closed."
  #
  # A harness that exports its own CLAUDE_STOP_REARM_DIR still wins (its assignment runs after
  # inheriting). Dirs live under $RESDIR and die with its existing EXIT trap.
  # Bite: scripts/harness-sweep-rearm-isolation-test.sh.
  CLAUDE_STOP_REARM_DIR="$RESDIR/rearm.$idx" bash "$t" >"$RESDIR/out.$idx" 2>&1
  rc=$?
  printf '%s %s\n' "$rc" "$base" > "$RESDIR/res.$idx"
}

i=0
for t in "${run_list[@]}"; do
  _run_one "$i" "$t" &
  i=$((i + 1))
  # Throttle: while the live background-job count reaches JOBS, wait for ANY to finish.
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do
    wait -n 2>/dev/null || true
  done
done
# Drain remaining jobs.
wait 2>/dev/null || true

# Aggregate DETERMINISTICALLY in index order (independent of completion order).
n="$i"
idx=0
while [ "$idx" -lt "$n" ]; do
  if [ -f "$RESDIR/res.$idx" ]; then
    rc="$(awk '{print $1}' "$RESDIR/res.$idx")"
    base="$(awk '{print $2}' "$RESDIR/res.$idx")"
    if [ "$rc" = "0" ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
      failed_list="${failed_list}
  FAIL (rc=$rc): ${base}"
    fi
  else
    # Missing result file = the harness job did not record a verdict (crash/kill). Count as a failure
    # so a lost result can never be silently dropped from the meta-net.
    fail=$((fail + 1))
    failed_list="${failed_list}
  FAIL (rc=?): <harness index $idx produced no result>"
  fi
  idx=$((idx + 1))
done

printf 'harness-test-sweep: %d passed, %d failed, %d skipped (runtime scripts:%s )\n' \
  "$pass" "$fail" "$skip" "${skipped_list:- none}"
if [ "$fail" -gt 0 ]; then
  printf 'FAILURES:%s\n' "$failed_list" >&2
  exit 1
fi
exit 0
