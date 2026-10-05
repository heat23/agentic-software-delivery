#!/usr/bin/env bash
# v-drain-and-telemetry-test.sh — BITE for Phase-1 fixes (2026-07-01):
#   P1-A  v-drain-deferred-merges.sh — lands stranded worktrees whose OWNING PROCESS has ended (PID liveness,
#         NOT the flaky 240-min mtime gate), drives merge-back per drainable worktree, GCs stale markers, dry-run.
#   P1-B  finalize-session-log.sh — mirrors the canonical SESSION_LOG into the durable MAIN .v/artifacts so a
#         worktree teardown / git-clean can't lose the telemetry (git-common-dir resolves main from a worktree).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="$HERE/v-drain-deferred-merges.sh"
FINALIZE="${V_FINALIZE_OVERRIDE:-$HOME/.claude/skills/v-session-log/references/finalize-session-log.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer missing at $DRAINER"; exit 2; }

BASE="$(mktemp -d)"
# a live PID (owns WT_live) + a dead PID (spawn then reap)
sleep 300 & ALIVE_PID=$!
DEAD_PID=999999   # beyond macOS pid_max — never live; freed pids recycle under churn (2026-07-02)
trap 'kill "$ALIVE_PID" 2>/dev/null; rm -rf "$BASE" 2>/dev/null' EXIT

SIDlive="aaaaaaaa-1111-4222-8333-444455556666"   # worktree whose session PID is ALIVE  → must NOT drain
SIDdead="bbbbbbbb-1111-4222-8333-444455556666"   # worktree whose session PID is DEAD   → drain
SIDnolk="cccccccc-1111-4222-8333-444455556666"   # worktree with NO lock (session ended) → drain
SIDmrg="dddddddd-1111-4222-8333-444455556666"    # branch merged into main               → marker GC
SIDorf="eeeeeeee-1111-4222-8333-444455556666"    # no branch at all                       → marker GC
SIDempty="88888888-1111-4222-8333-444455556666"  # no lock, NO proof, ZERO commits ahead  → genuine mid-setup, still SKIPPED (H-4)

R="$BASE/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
mk_wt(){ # $1=slug $2=sid  → unmerged branch + worktree ahead of main; prints the worktree path
  local slug="$1" sid="$2" b="fix/${1}-${2%%-*}"
  ( cd "$R" && git checkout -q -b "$b" && echo "$slug" > "$slug.f" && git add -A && git commit -qm "$slug" && git checkout -q main ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$R/.worktrees/$slug" "$b" >/dev/null 2>&1
  printf '%s/.worktrees/%s' "$R" "$slug"
}
WTL="$(mk_wt live   "$SIDlive")"; printf '%s %s %s\n' "$SIDlive" "$ALIVE_PID" "$(date +%s)" > "$WTL/.claude-session-lock"
WTD="$(mk_wt dead   "$SIDdead")"; printf '%s %s %s\n' "$SIDdead" "$DEAD_PID"  "$(date +%s)" > "$WTD/.claude-session-lock"
WTN="$(mk_wt nolock "$SIDnolk")"; rm -f "$WTN/.claude-session-lock" 2>/dev/null
SIDsetup="99999999-1111-4222-8333-444455556666"                    # no lock, NO named proof, BUT 1 commit ahead
                                                                     # of main ⇒ H-4 (2026-07-02): stranded, DRAIN
WTS="$(mk_wt setup "$SIDsetup")"; rm -f "$WTS/.claude-session-lock" 2>/dev/null
# Genuine mid-setup: a worktree/branch that exists but carries ZERO commits ahead of main (nothing
# committed yet) — the H-4 widening must NOT drain this; it is the case the guard exists to protect.
mk_wt_empty(){ local slug="$1" sid="$2" b="fix/${1}-${2%%-*}"
  ( cd "$R" && git checkout -q -b "$b" main && git checkout -q main ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$R/.worktrees/$slug" "$b" >/dev/null 2>&1
  printf '%s/.worktrees/%s' "$R" "$slug"
}
WTMS="$(mk_wt_empty midsetup "$SIDempty")"; rm -f "$WTMS/.claude-session-lock" 2>/dev/null
# R18 regression: a worktree registered at the EXTERNAL convention (~/.claude/worktrees/<repo>/… → a path
# segment WITHOUT the leading-dot '/.worktrees/', here '/extwt/') must ALSO be drained. dead-PID lock ⇒
# deterministically drainable, exactly like WTD. Before the R18 fix, line-75's '*"/.worktrees/"*' filter
# SILENTLY skipped this worktree (the real-world bug: most fleet worktrees lived under ~/.claude/worktrees).
SIDext="77777777-1111-4222-8333-444455556666"
mk_wt_ext(){ local slug="$1" sid="$2" b="fix/${1}-${2%%-*}"
  ( cd "$R" && git checkout -q -b "$b" && echo "$slug" > "$slug.f" && git add -A && git commit -qm "$slug" && git checkout -q main ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$BASE/extwt/$slug" "$b" >/dev/null 2>&1
  printf '%s/extwt/%s' "$BASE" "$slug"
}
WTE="$(mk_wt_ext ext "$SIDext")"; printf '%s %s %s\n' "$SIDext" "$DEAD_PID" "$(date +%s)" > "$WTE/.claude-session-lock"
# a branch merged into main (its marker must GC)
( cd "$R" && git checkout -q -b "fix/merged-${SIDmrg%%-*}" && echo m > m.f && git add -A && git commit -qm m \
  && git checkout -q main && git merge -q --no-ff "fix/merged-${SIDmrg%%-*}" -m merge ) >/dev/null 2>&1
# Create WTN's stranding proof LAST — after every `git add -A` above (mk_wt + merged-branch stage -A, which would
# otherwise sweep this untracked file onto a side branch and drop it from main). Drainer finds it untracked at root.
printf '# handoff\n' > "$R/HANDOFF_${SIDnolk%%-*}-stranded.md"
# C-1 (round-3, 2026-07-01): landing now ALSO requires gauntlet-completeness evidence (AGENT_REVIEW or
# GAUNTLET_SKIPPED artifact; no QA-fail/BLOCKED/merge-hold). These fixtures model GATED sessions — the
# liveness semantics under test here are unchanged. The HOLD matrix has its own suite:
# v-drain-verdict-gate-test.sh. Note: AGENT_REVIEW is deliberately NOT in the mid-setup PROOF glob list,
# so WTS still exercises the H-4 commits-ahead classification path.
mkdir -p "$R/.v/artifacts"
for _s in "$SIDdead" "$SIDnolk" "$SIDsetup" "$SIDext"; do printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${_s}.md"; done

STUB="$BASE/stub"; mkdir -p "$STUB"; MB_LOG="$BASE/mb.log"; : > "$MB_LOG"
printf '#!/usr/bin/env bash\nprintf "MB sid=%%s wt=%%s\\n" "$1" "$2" >> "%s"\nexit 0\n' "$MB_LOG" > "$STUB/merge-back.sh"
chmod +x "$STUB/merge-back.sh"
plant_markers(){ mkdir -p "$R/.v"; local s; for s in "$SIDlive" "$SIDmrg" "$SIDorf"; do printf 'deferred_sid: %s\n' "$s" > "$R/.v/merge-deferred-${s}.md"; done; }
drain(){ V_DRAIN_MERGEBACK="$STUB/merge-back.sh" bash "$DRAINER" "$R" 2>&1; }

echo "== P1-A SAFETY KEYSTONE: a worktree whose owning PROCESS is ALIVE is never drained =="
# grep by worktree basename — git resolves /var→/private/var on macOS, so a full-path match is symlink-fragile.
: > "$MB_LOG"; plant_markers; OUT="$(drain)"
grep -qE "wt=.*/\.worktrees/live([/[:space:]]|$)" "$MB_LOG" && no "DRAINED A LIVE WORKTREE — clobber risk!" "$(cat "$MB_LOG")" || ok "live-PID worktree is NOT drained (owning session protected)"
printf '%s' "$OUT" | grep -q "ALIVE" && ok "reports the live worktree as skipped" || no "no ALIVE-skip message" "$OUT"

echo "== P1-A drains worktrees whose session ENDED (dead PID / no lock) =="
grep -qE "wt=.*/\.worktrees/dead([/[:space:]]|$)" "$MB_LOG"   && ok "dead-PID worktree IS drained" || no "dead-PID worktree not drained" "$(cat "$MB_LOG")"
grep -qE "wt=.*/\.worktrees/nolock([/[:space:]]|$)" "$MB_LOG" && ok "no-lock worktree WITH a stranding artifact IS drained" || no "no-lock+proof worktree not drained" "$(cat "$MB_LOG")"
grep -q "sid=$SIDdead" "$MB_LOG" && ok "passes the lock's authoritative SID to merge-back" || no "wrong/absent SID" "$(cat "$MB_LOG")"
grep -qE "wt=.*/extwt/ext([/[:space:]]|\$)" "$MB_LOG" && ok "external-convention worktree (no /.worktrees/ segment) IS drained (R18)" || no "external-path worktree SILENTLY SKIPPED — R18 filter bug (~/.claude/worktrees shape)" "$(cat "$MB_LOG")"

echo "== H-4 (2026-07-02): a lockless worktree with commits-ahead-of-main IS treated as stranded (drained), NOT mid-setup =="
grep -qE "wt=.*/\.worktrees/setup([/[:space:]]|$)" "$MB_LOG" && ok "lockless worktree WITH commits ahead of main is drained (timeout-killed sessions leave exactly this shape)" || no "commits-ahead lockless worktree wrongly skipped as mid-setup" "$(cat "$MB_LOG")"

echo "== MID-SETUP RACE GUARD (still enforced): a lockless worktree with ZERO commits ahead + no proof is NOT drained =="
grep -qE "wt=.*/\.worktrees/midsetup([/[:space:]]|$)" "$MB_LOG" && no "DRAINED A GENUINE MID-SETUP WORKTREE — clobber risk!" "$(cat "$MB_LOG")" || ok "lockless+no-proof+0-commits-ahead worktree is SKIPPED (won't clobber a sibling mid-setup)"

echo "== P1-A MAIN-BRANCH guard: a worktree parked on MAIN is never fed to merge-back (no merge-into-itself) =="
: > "$MB_LOG"   # WTD (dead PID) normally drains; with main pointed at ITS branch it must be skipped by the guard
V_DRAIN_MERGEBACK="$STUB/merge-back.sh" CLAUDE_MAIN_BRANCH="fix/dead-${SIDdead%%-*}" bash "$DRAINER" "$R" >/dev/null 2>&1
grep -qE "wt=.*/\.worktrees/dead([/[:space:]]|$)" "$MB_LOG" && no "a worktree on the main branch was fed to merge-back (would merge main into itself)" "$(cat "$MB_LOG")" || ok "worktree whose branch == main is skipped (never merged into itself)"

echo "== P1-A dry-run merges NOTHING =="
: > "$MB_LOG"; OUT="$(V_DRAIN_DRY_RUN=1 drain)"
[ ! -s "$MB_LOG" ] && ok "V_DRAIN_DRY_RUN=1 invokes no merge-back" || no "dry-run still merged" "$(cat "$MB_LOG")"
printf '%s' "$OUT" | grep -qi "dry-run" && ok "dry-run previews" || no "no dry-run preview" "$OUT"

echo "== P1-A GC: stale markers removed, live one kept =="
plant_markers; drain >/dev/null 2>&1
[ ! -f "$R/.v/merge-deferred-${SIDmrg}.md" ] && ok "GC removes a marker whose branch is MERGED" || no "merged-branch marker survived"
[ ! -f "$R/.v/merge-deferred-${SIDorf}.md" ] && ok "GC removes a marker with no matching branch" || no "orphan marker survived"
[ -f "$R/.v/merge-deferred-${SIDlive}.md" ] && ok "GC KEEPS the marker for a still-unmerged worktree" || no "live marker wrongly GC'd"

echo "== P1-A robustness: non-git dir ⇒ clean exit 0 =="
rc=0; OUT="$(bash "$DRAINER" "$BASE/nope" 2>&1)" || rc=$?
[ "$rc" = 0 ] && ok "non-git path exits 0 cleanly" || no "non-git path errored" "rc=$rc"

echo "== P1-B durability: finalize block present + git-common-dir resolves MAIN root from a worktree =="
if [ ! -f "$FINALIZE" ]; then
  echo "  skip finalize durable-copy check — the session-log subsystem is not in the public snapshot"
else
grep -q "telemetry DURABILITY" "$FINALIZE" 2>/dev/null && grep -qE 'cp -f "\$FINAL" "\$_main_root/\.v/artifacts/SESSION_LOG' "$FINALIZE" 2>/dev/null \
  && ok "finalize carries the durable-copy block after the canonical mv (orphan guard)" || no "durable-copy block missing/renamed in finalize"
fi
SIDt="ffffffff-1111-4222-8333-444455556666"; FINAL="$WTN/SESSION_LOG_${SIDt}.yaml"; printf 'session_id: %s\n' "$SIDt" > "$FINAL"
( cd "$WTN"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
  _gcd="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
  case "$_gcd" in /*) ;; ?*) _gcd="$REPO_ROOT/$_gcd" ;; *) _gcd="" ;; esac
  _main_root="$( [ -n "$_gcd" ] && cd "$(dirname "$_gcd")" 2>/dev/null && pwd || true )"; [ -n "$_main_root" ] || _main_root="$REPO_ROOT"
  mkdir -p "$_main_root/.v/artifacts" 2>/dev/null && cp -f "$FINAL" "$_main_root/.v/artifacts/SESSION_LOG_${SIDt}.yaml" 2>/dev/null || true )
[ -f "$R/.v/artifacts/SESSION_LOG_${SIDt}.yaml" ] && ok "durable copy lands in MAIN's .v/artifacts (survives worktree teardown)" || no "durable copy did not resolve to main root" "$(ls -R "$R/.v" 2>/dev/null | head)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
