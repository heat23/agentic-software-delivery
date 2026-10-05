#!/usr/bin/env bash
# v-landing-layer-fixes-test.sh — BITE for the 2026-07-02 landing-layer forensic fixes:
#   P0-2  v-drain-deferred-merges.sh: short-8 branch-suffix SID is expanded to the full UUID (via a
#         SID-bearing proof artifact) BEFORE calling merge-back — was a permanent rc=2 loop.
#   H-3   session-lock-parse.sh: ONE shared parser for all 3 observed lock formats (3-field positional,
#         2-field positional, key=value), sourced by BOTH v-drain-deferred-merges.sh and
#         v-active-siblings.sh — a dead-PID key=value lock must be read as DEAD, not fall through to a
#         stale mtime-window "ALIVE".
#   bonus error-line: a merge-back failure reports the real `ERROR:` line, not the banner's `═` tail.
#   GC    dead-PID locks are removed (never a live or unresolvable one).
#   run-v-packs: truthful per-branch drain-verdict summary (_drain_verdict_for) + log rotation
#         (_rotate_pack_log) instead of truncation.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${DRAINER_OVERRIDE:-$HERE/v-drain-deferred-merges.sh}"
SIBLINGS="${SIBLINGS_OVERRIDE:-$HERE/v-active-siblings.sh}"
LOCKLIB="$HOME/.claude/hooks/lib/session-lock-parse.sh"
RUNNER="${RUNNER_OVERRIDE:-$HOME/.local/bin/run-v-packs}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer missing at $DRAINER"; exit 2; }
[ -f "$SIBLINGS" ] || { echo "FATAL: siblings script missing at $SIBLINGS"; exit 2; }
[ -f "$LOCKLIB" ]  || { echo "FATAL: session-lock-parse.sh missing at $LOCKLIB"; exit 2; }
[ -f "$RUNNER" ]   || { echo "FATAL: run-v-packs missing at $RUNNER"; exit 2; }

BASE="$(mktemp -d)"
DEAD_PID=999999   # beyond macOS pid_max — never live; freed pids recycle under churn (2026-07-02)
sleep 300 & ALIVE_PID=$!
trap 'kill "$ALIVE_PID" 2>/dev/null; rm -rf "$BASE" 2>/dev/null' EXIT

echo "== session-lock-parse.sh: all 3 lock formats parse correctly =="
( . "$LOCKLIB"
  LF="$BASE/lock3"; printf 'aaaa1111-1111-4222-8333-444455556666 %s %s\n' "$DEAD_PID" "$(date +%s)" > "$LF"
  [ "$(_lock_pid "$LF")" = "$DEAD_PID" ] && echo OK1 || echo "BAD1: $(_lock_pid "$LF")"
  [ "$(_lock_sid "$LF")" = "aaaa1111-1111-4222-8333-444455556666" ] && echo OK2 || echo "BAD2"
  LF2="$BASE/lock2"; printf 'bbbb2222-1111-4222-8333-444455556666 1700000000\n' > "$LF2"
  [ -z "$(_lock_pid "$LF2")" ] && echo OK3 || echo "BAD3: got pid '$(_lock_pid "$LF2")' from a 2-field EPOCH-only lock"
  [ "$(_lock_epoch "$LF2")" = "1700000000" ] && echo OK4 || echo "BAD4"
  LF3="$BASE/lockkv"; printf 'sid=cccc3333-1111-4222-8333-444455556666 pid=%s started=2026-07-01T00:00:00Z\n' "$DEAD_PID" > "$LF3"
  [ "$(_lock_pid "$LF3")" = "$DEAD_PID" ] && echo OK5 || echo "BAD5: got '$(_lock_pid "$LF3")'"
  [ "$(_lock_sid "$LF3")" = "cccc3333-1111-4222-8333-444455556666" ] && echo OK6 || echo "BAD6: got '$(_lock_sid "$LF3")'"
) > "$BASE/lockparse.out" 2>&1
grep -q OK1 "$BASE/lockparse.out" && ok "3-field positional: pid resolved" || no "3-field pid" "$(cat "$BASE/lockparse.out")"
grep -q OK2 "$BASE/lockparse.out" && ok "3-field positional: sid resolved" || no "3-field sid"
grep -q OK3 "$BASE/lockparse.out" && ok "2-field positional: pid NOT guessed from the epoch slot" || no "2-field pid" "$(cat "$BASE/lockparse.out")"
grep -q OK4 "$BASE/lockparse.out" && ok "2-field positional: epoch resolved" || no "2-field epoch"
grep -q OK5 "$BASE/lockparse.out" && ok "key=value: pid resolved (was the HIGH-3 defect — used to fall to mtime)" || no "key=value pid" "$(cat "$BASE/lockparse.out")"
grep -q OK6 "$BASE/lockparse.out" && ok "key=value: sid resolved cleanly (no 'sid=' prefix leaking through)" || no "key=value sid" "$(cat "$BASE/lockparse.out")"

echo "== lock_alive(): dead pid in EVERY format reads DEAD; live pid reads ALIVE =="
( . "$LOCKLIB"
  LFd3="$BASE/d3"; printf 'x %s %s\n' "$DEAD_PID" "$(date +%s)" > "$LFd3"
  lock_alive "$LFd3" 360 && echo "BAD: 3-field dead pid read ALIVE" || echo "OK: 3-field dead pid read DEAD"
  LFdkv="$BASE/dkv"; printf 'sid=x pid=%s started=2026-07-01T00:00:00Z\n' "$DEAD_PID" > "$LFdkv"
  lock_alive "$LFdkv" 360 && echo "BAD: key=value dead pid read ALIVE (HIGH-3 regression)" || echo "OK: key=value dead pid read DEAD"
  LFl3="$BASE/l3"; printf 'x %s %s\n' "$ALIVE_PID" "$(date +%s)" > "$LFl3"
  lock_alive "$LFl3" 360 && echo "OK: live pid read ALIVE" || echo "BAD: live pid read DEAD"
) > "$BASE/alive.out" 2>&1
grep -q "^OK: 3-field dead" "$BASE/alive.out" && ok "3-field dead-pid lock -> DEAD" || no "3-field dead-pid" "$(cat "$BASE/alive.out")"
grep -q "^OK: key=value dead" "$BASE/alive.out" && ok "key=value dead-pid lock -> DEAD (was misread ALIVE pre-fix)" || no "key=value dead-pid" "$(cat "$BASE/alive.out")"
grep -q "^OK: live pid" "$BASE/alive.out" && ok "live-pid lock -> ALIVE (never touched)" || no "live-pid" "$(cat "$BASE/alive.out")"

# ── repo fixture for drain-script + siblings-script integration tests ─────────────────────────────
R="$BASE/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
STUB="$BASE/stub"; mkdir -p "$STUB"; MB_LOG="$BASE/mb.log"; : > "$MB_LOG"
printf '#!/usr/bin/env bash\nprintf "MB sid=%%s wt=%%s\\n" "$1" "$2" >> "%s"\nexit 0\n' "$MB_LOG" > "$STUB/merge-back.sh"
chmod +x "$STUB/merge-back.sh"

echo "== P0-2: short-8 branch-suffix SID is expanded to the FULL UUID before calling merge-back =="
FULLSID="0a0a0a0a-1111-4111-8111-00000000c003"
( cd "$R" && git checkout -q -b "fix/fix-summary-0a0a0a0a" && echo x > x.f && git add -A && git commit -qm x && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/shortsid" "fix/fix-summary-0a0a0a0a" >/dev/null 2>&1
rm -f "$R/.worktrees/shortsid/.claude-session-lock" 2>/dev/null
mkdir -p "$R/.v/tmp" "$R/.v/artifacts"   # real merge-deferred markers live under .v/tmp/ (and are durable-copied to .v/artifacts/)
printf 'deferred_sid: %s\n' "$FULLSID" > "$R/.v/tmp/merge-deferred-${FULLSID}.md"
# C-1 (round-3): landing now requires gauntlet evidence — this fixture models a GATED session (the
# behavior under test here is SID expansion, not the verdict gate; that has its own suite).
printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${FULLSID}.md"
: > "$MB_LOG"
V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" >"$BASE/p02.out" 2>&1
grep -qF "sid=$FULLSID " "$MB_LOG" && ok "merge-back was called with the FULL UUID, not the short-8 prefix" || no "short SID leaked through to merge-back" "$(cat "$MB_LOG")"
grep -qi "expanded short SID" "$BASE/p02.out" && ok "drain reports the expansion" || no "no expansion narration" "$(cat "$BASE/p02.out")"

echo "== bonus: a merge-back FAILURE reports the real ERROR line, not the banner's final ═ line =="
FAILSTUB="$BASE/failstub.sh"
cat > "$FAILSTUB" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: worktree branch does not contain SESSION_ID — ownership is unprovable." >&2
echo "" >&2
echo "══════════════════════════════════════════════════════════════════════" >&2
echo "⛔ DO NOT FALL BACK TO A MANUAL git merge." >&2
echo "══════════════════════════════════════════════════════════════════════" >&2
exit 2
EOF
chmod +x "$FAILSTUB"
( cd "$R" && git checkout -q -b "fix/willfail-9a9a9a9a" && echo y > y.f && git add -A && git commit -qm y && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/willfail" "fix/willfail-9a9a9a9a" >/dev/null 2>&1
rm -f "$R/.worktrees/willfail/.claude-session-lock" 2>/dev/null
mkdir -p "$R/.v/tmp" "$R/.v/artifacts"
printf 'deferred_sid: 9a9a9a9a-1111-4222-8333-444455556666\n' > "$R/.v/tmp/merge-deferred-9a9a9a9a-1111-4222-8333-444455556666.md"
# C-1 (round-3): gauntlet evidence so the verdict gate passes this fixture through to the error-reporting path.
printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_9a9a9a9a-1111-4222-8333-444455556666.md"
V_DRAIN_MERGEBACK="$FAILSTUB" bash "$DRAINER" "$R" >"$BASE/errline.out" 2>&1
grep -F "rc=2 for fix/willfail" "$BASE/errline.out" | grep -qF "ownership is unprovable" && ok "reports the real ERROR text on failure" || no "did not surface the real error line" "$(cat "$BASE/errline.out")"
grep -F "rc=2 for fix/willfail" "$BASE/errline.out" | grep -qE ': ═+$' && no "the failed-branch line ends in the banner border, not real content" "$(cat "$BASE/errline.out")" || ok "failed-branch line does NOT end in the decorative banner border"

echo "== GC: a lock with a provably-dead PID is removed; a live/unresolvable one is left alone =="
( cd "$R" && git checkout -q -b "fix/gc-target-b1b1b1b1" && echo z > z.f && git add -A && git commit -qm z && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/gctarget" "fix/gc-target-b1b1b1b1" >/dev/null 2>&1
printf 'sid=b1b1b1b1-1111-4222-8333-444455556666 pid=%s started=2026-07-01T00:00:00Z\n' "$DEAD_PID" > "$R/.worktrees/gctarget/.claude-session-lock"
( cd "$R" && git checkout -q -b "fix/gc-live-c2c2c2c2" && echo w > w.f && git add -A && git commit -qm w && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/gclive" "fix/gc-live-c2c2c2c2" >/dev/null 2>&1
printf 'c2c2c2c2-1111-4222-8333-444455556666 %s %s\n' "$ALIVE_PID" "$(date +%s)" > "$R/.worktrees/gclive/.claude-session-lock"
V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" >/dev/null 2>&1
[ -f "$R/.worktrees/gctarget/.claude-session-lock" ] && no "dead-pid lock was NOT gc'd" || ok "dead-pid lock GC'd"
[ -f "$R/.worktrees/gclive/.claude-session-lock" ] && ok "live-pid lock left alone" || no "live-pid lock wrongly removed"

echo "== v-active-siblings.sh: a dead-PID key=value lock is NOT reported as an active sibling =="
R2="$BASE/repo2"; mkdir -p "$R2"
( cd "$R2" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
mkdir -p "$R2/.worktrees/sib"
printf 'sid=d3d3d3d3-1111-4222-8333-444455556666 pid=%s started=2026-07-01T00:00:00Z\n' "$DEAD_PID" > "$R2/.worktrees/sib/.claude-session-lock"
OUT2="$(bash "$SIBLINGS" "$R2" "self-sid" 240 2>&1)"
printf '%s' "$OUT2" | grep -q "d3d3d3d3" && no "reported a DEAD key=value-lock session as an active sibling (HIGH-3 regression)" "$OUT2" || ok "dead key=value-lock session NOT reported as sibling"
mkdir -p "$R2/.worktrees/sib2"
printf 'sid=e4e4e4e4-1111-4222-8333-444455556666 pid=%s started=2026-07-01T00:00:00Z\n' "$ALIVE_PID" > "$R2/.worktrees/sib2/.claude-session-lock"
OUT3="$(bash "$SIBLINGS" "$R2" "self-sid" 240 2>&1)"
printf '%s' "$OUT3" | grep -q "e4e4e4e4" && ok "live key=value-lock session IS reported as sibling" || no "live sibling missed" "$OUT3"

echo "== run-v-packs: _drain_verdict_for classifies each branch truthfully =="
( . "$RUNNER" 2>/dev/null
  DOUT="  ✓ merged+cleaned: fix/a-11111111 (sid=x)
  ⏸ still deferred: fix/b-22222222 (main still carries live sibling WIP — left intact, retry later)
  ✗ merge-back rc=2 for fix/c-33333333 (left intact; see its WORKTREE_HANDOFF): ERROR: ownership unprovable."
  [ "$(_drain_verdict_for "$DOUT" "fix/a-11111111")" = merged ]   && echo OKV1 || echo BADV1
  [ "$(_drain_verdict_for "$DOUT" "fix/b-22222222")" = deferred ] && echo OKV2 || echo BADV2
  [ "$(_drain_verdict_for "$DOUT" "fix/c-33333333")" = failed ]   && echo OKV3 || echo BADV3
  [ "$(_drain_verdict_for "$DOUT" "fix/nope-999")" = unknown ]    && echo OKV4 || echo BADV4
  # prefix-collision guard: fix/a is a PREFIX of fix/a-11111111 — must not false-match
  [ "$(_drain_verdict_for "$DOUT" "fix/a")" = unknown ] && echo OKV5 || echo BADV5
) > "$BASE/verdict.out" 2>&1
grep -q OKV1 "$BASE/verdict.out" && ok "merged branch classified 'merged'" || no "merged classification" "$(cat "$BASE/verdict.out")"
grep -q OKV2 "$BASE/verdict.out" && ok "deferred branch classified 'deferred'" || no "deferred classification"
grep -q OKV3 "$BASE/verdict.out" && ok "failed branch classified 'failed' (drives NEEDS-MANUAL, not 'lands automatically')" || no "failed classification"
grep -q OKV4 "$BASE/verdict.out" && ok "unmentioned branch classified 'unknown'" || no "unknown classification"
grep -q OKV5 "$BASE/verdict.out" && ok "prefix-collision guard: a branch name that is a PREFIX of another does not false-match" || no "prefix collision" "$(cat "$BASE/verdict.out")"

echo "== run-v-packs: _rotate_pack_log preserves the prior generation instead of truncating it =="
( . "$RUNNER" 2>/dev/null
  LF="$BASE/rotate.log"; printf 'run-1 evidence\n' > "$LF"
  _rotate_pack_log "$LF"
  [ -f "$LF.1" ] && [ "$(cat "$LF.1")" = "run-1 evidence" ] && echo OKR1 || echo BADR1
  printf 'run-2 evidence\n' > "$LF"
) > "$BASE/rotate.out" 2>&1
grep -q OKR1 "$BASE/rotate.out" && ok "prior log content preserved at .log.1 (not silently overwritten)" || no "rotation lost prior evidence" "$(cat "$BASE/rotate.out")"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
