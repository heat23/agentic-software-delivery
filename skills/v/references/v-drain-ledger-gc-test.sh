#!/usr/bin/env bash
# v-drain-ledger-gc-test.sh — BITE for C-5 (round-3, 2026-07-01): spent session-writes ledgers pile up forever.
#
# CLASS: <git-common-dir>/claude-session-writes-<sid>.txt files are never GC'd (observed: over a thousand in one repo).
# The P12 absorption gate greps ALL of them, so two long-merged historical sessions' rows false-blocked a
# live session's own commit. Structural fix half: reap a ledger only when it is provably
# SPENT — older than the forensics keep-window AND its session is not live in any registered worktree AND no
# unmerged SID-matching branch still carries its work. Every ambiguous case (non-numeric lock pid, unmerged
# branch, young file) KEEPS the ledger — GC must never weaken P12's evidence for plausibly-active work.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${V_TEST_DRAIN_SCRIPT:-$HERE/v-drain-deferred-merges.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer missing at $DRAINER"; exit 2; }

BASE="$(mktemp -d)"
sleep 300 & ALIVE_PID=$!
DEAD_PID=999999   # beyond macOS pid_max — never live; freed pids recycle under churn (2026-07-02)
trap 'kill "$ALIVE_PID" 2>/dev/null; rm -rf "$BASE" 2>/dev/null' EXIT

SIDlive="beef0001-1111-4222-8333-444455556666"  # live-PID lock in a worktree            → KEEP (old file)
SIDspent="beef0002-1111-4222-8333-444455556666" # dead, branch merged, old               → GC
SIDwork="beef0003-1111-4222-8333-444455556666"  # dead, UNMERGED branch carries work     → KEEP (old file)
SIDyoung="beef0004-1111-4222-8333-444455556666" # fresh mtime, nothing else              → KEEP (window)
SIDgone="beef0005-1111-4222-8333-444455556666"  # dead, no branch at all, old            → GC
SIDkv="beef0006-1111-4222-8333-444455556666"    # LIVE session, key=value lock, branch MERGED, old ledger → KEEP
                                                # (F3 PoC: raw awk parse missed kv locks → GC'd a LIVE ledger)

R="$BASE/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
GDIR="$(git -C "$R" rev-parse --git-common-dir)"; case "$GDIR" in /*) ;; *) GDIR="$R/$GDIR" ;; esac
# live session: worktree + live-PID lock; give it gauntlet evidence so nothing else interferes
( cd "$R" && git checkout -q -b "fix/live-${SIDlive%%-*}" && echo l > l.f && git add -A && git commit -qm l && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/live" "fix/live-${SIDlive%%-*}" >/dev/null 2>&1
printf '%s %s %s\n' "$SIDlive" "$ALIVE_PID" "$(date +%s)" > "$R/.worktrees/live/.claude-session-lock"
# spent: branch merged into main
( cd "$R" && git checkout -q -b "fix/spent-${SIDspent%%-*}" && echo s > s.f && git add -A && git commit -qm s \
  && git checkout -q main && git merge -q --ff-only "fix/spent-${SIDspent%%-*}" ) >/dev/null 2>&1
# work-pending: unmerged branch, no live session
( cd "$R" && git checkout -q -b "fix/pending-${SIDwork%%-*}" && echo w > w.f && git add -A && git commit -qm w && git checkout -q main ) >/dev/null 2>&1
# F3: kv-lock LIVE session whose branch is MERGED — liveness is the ONLY thing keeping its ledger
( cd "$R" && git checkout -q -b "fix/kvlive-${SIDkv%%-*}" && echo k > k.f && git add -A && git commit -qm k \
  && git checkout -q main && git merge -q --ff-only "fix/kvlive-${SIDkv%%-*}" ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/kvlive" "fix/kvlive-${SIDkv%%-*}" >/dev/null 2>&1
printf 'sid=%s pid=%s started=2026-07-01T00:00:00Z\n' "$SIDkv" "$ALIVE_PID" > "$R/.worktrees/kvlive/.claude-session-lock"

for s in "$SIDlive" "$SIDspent" "$SIDwork" "$SIDyoung" "$SIDgone" "$SIDkv"; do printf 'app/File.php\n' > "$GDIR/claude-session-writes-${s}.txt"; done
# age everything except SIDyoung past the keep-window
for s in "$SIDlive" "$SIDspent" "$SIDwork" "$SIDgone" "$SIDkv"; do touch -t 202601010000 "$GDIR/claude-session-writes-${s}.txt"; done

STUB="$BASE/stub"; mkdir -p "$STUB"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/merge-back.sh"; chmod +x "$STUB/merge-back.sh"

echo "== C-5 dry-run: previews the spent ledgers, removes nothing =="
DOUT="$(V_DRAIN_DRY_RUN=1 V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" 2>&1)"
printf '%s' "$DOUT" | grep -q "claude-session-writes-${SIDspent}" && ok "dry-run previews the merged+dead+old ledger" || no "dry-run does not preview spent-ledger GC" "$DOUT"
[ -f "$GDIR/claude-session-writes-${SIDspent}.txt" ] && ok "dry-run removed nothing" || no "dry-run DELETED a ledger"

echo "== C-5 real run: spent ledgers reaped, protected ones kept =="
V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" >/dev/null 2>&1
[ ! -f "$GDIR/claude-session-writes-${SIDspent}.txt" ] && ok "merged+dead+old ledger GC'd" || no "spent ledger survived (the ledger-pile class)"
[ ! -f "$GDIR/claude-session-writes-${SIDgone}.txt" ]  && ok "no-branch dead old ledger GC'd" || no "orphan ledger survived"
[ -f "$GDIR/claude-session-writes-${SIDlive}.txt" ]  && ok "LIVE session's ledger KEPT (P12 evidence for active work)" || no "GC'd a LIVE session's ledger — P12 evidence destroyed"
[ -f "$GDIR/claude-session-writes-${SIDwork}.txt" ]  && ok "unmerged-branch ledger KEPT (work still pending)" || no "GC'd a ledger whose branch is unmerged"
[ -f "$GDIR/claude-session-writes-${SIDyoung}.txt" ] && ok "young ledger KEPT (forensics keep-window)" || no "GC'd inside the keep-window"
[ -f "$GDIR/claude-session-writes-${SIDkv}.txt" ] && ok "F3: key=value-format LIVE lock protects its ledger (shared parser, not raw awk)" || no "F3: kv-lock LIVE session's ledger was GC'd — the PoC'd data-loss bug"

echo "== C-5 summary tally =="
OUT2="$(V_DRAIN_DRY_RUN=1 V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" 2>&1)"
printf '%s' "$OUT2" | grep -qE "spent ledger" && ok "summary line reports the spent-ledger tally" || no "summary lacks ledger tally" "$(printf '%s' "$OUT2" | tail -1)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
