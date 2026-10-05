#!/usr/bin/env bash
# v-merge-back-fnd3-orphan-escape-test.sh — FND3-ORPHAN class (forensic 2026-07-04).
#
# The Jul-4 fleet deferred several gauntleted branches for a full day on main WIP owned by a
# session that was already DEAD — because FND-3 deferred on "any live worktree sibling" without
# asking WHO OWNS THE WIP. Fix: attribute the foreign paths via the per-session write-ledgers;
# only a LIVE claim defers. Dead/unclaimed WIP falls through to the existing FND-2 recoverable
# auto-stash with a durable FND3_ORPHAN_ESCAPE receipt.
#   T1: dirty main claimed by a DEAD session's ledger + live worktree sibling → MERGES (escape),
#       receipt written, WIP restored after the merge (FND-2 stash round-trip).
#   T2: dirty main claimed by the LIVE sibling's ledger → still DEFERS (exit 3) — guard intact.
#   T3 (red fixture): the pre-fix merge-back DEFERS on the T1 fixture — proves the test bites.
set -u
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
MB_BAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-orphan0704-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$MB" ] || { echo "SKIP: merge-back missing"; exit 0; }
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1

SID="0e0e0e0e-2222-4222-8222-000000000002"; S8="${SID%%-*}"
LIVESID="11a11a11-3333-4333-8333-000000000003"
DEADSID="dead0000-4444-4444-8444-000000000004"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mk_fixture(){ # $1=root -> prints repo and worktree paths
  local R="$1/repo" W SB
  mkdir -p "$R"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && printf 'l1\n' > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  W="$R/.worktrees/fix-thing-${S8}"
  git -C "$R" worktree add -q "$W" -b "fix/thing-${S8}" HEAD 2>/dev/null
  ( cd "$W" && echo new > merged_feature.php && git add merged_feature.php && git commit -qm "wt work" ) >/dev/null 2>&1
  mkdir -p "$R/.v/tmp"
  printf 'merged_feature.php\n' > "$R/.v/tmp/session-writes-${SID}.txt"
  # a LIVE worktree sibling (lock pid = this test shell, alive throughout)
  SB="$R/.worktrees/sibling-${LIVESID%%-*}"
  git -C "$R" worktree add -q "$SB" -b "build/sib-${LIVESID%%-*}" HEAD 2>/dev/null
  printf '%s %s %s\n' "$LIVESID" "$$" "$(date +%s)" > "$SB/.claude-session-lock"
  # foreign uncommitted SOURCE WIP on main
  echo foreign > "$R/orphaned_wip.php"
  printf '%s\n' "$R" "$W"
}

run_mb(){ # $1=script $2=repo $3=wt
  ( cd "$2" && V_TMP_DIR="$2/.v/tmp" REPO_ROOT="$2" bash "$1" "$SID" "$3" ) > "$T/out" 2>&1
  echo $?
}

# ── T1: WIP owned by a DEAD session's ledger → orphan escape, merge proceeds ──
F1="$T/f1"; mkdir -p "$F1"; { read -r R1; read -r W1; } < <(mk_fixture "$F1")
printf 'orphaned_wip.php\n' > "$R1/.git/claude-session-writes-${DEADSID}.txt"
RC1=$(run_mb "$MB" "$R1" "$W1")
if [ "$RC1" -eq 0 ] && grep -q new "$R1/merged_feature.php" 2>/dev/null; then
  ok "T1 dead-owner WIP + live sibling → merge PROCEEDS (rc=0, feature landed)"
else
  no "T1 merge should proceed via orphan escape" "rc=$RC1 :: $(tail -3 "$T/out" 2>/dev/null | tr '\n' ' | ')"
fi
[ -f "$R1/.v/artifacts/FND3_ORPHAN_ESCAPE_${SID}.md" ] \
  && ok "T1b durable FND3_ORPHAN_ESCAPE receipt written" \
  || no "T1b receipt missing" "$R1/.v/artifacts/FND3_ORPHAN_ESCAPE_${SID}.md"
grep -qF "$DEADSID" "$R1/.v/artifacts/FND3_ORPHAN_ESCAPE_${SID}.md" 2>/dev/null \
  && ok "T1c receipt names the dead owner" \
  || no "T1c receipt does not attribute the dead owner"
[ -f "$R1/orphaned_wip.php" ] && grep -q foreign "$R1/orphaned_wip.php" 2>/dev/null \
  && ok "T1d the orphaned WIP survived (FND-2 stash restored it — nothing discarded)" \
  || no "T1d orphaned WIP lost" "orphaned_wip.php absent or altered after merge"

# ── T2: WIP claimed by the LIVE sibling's ledger → defer stands (guard NOT weakened) ──
F2="$T/f2"; mkdir -p "$F2"; { read -r R2; read -r W2; } < <(mk_fixture "$F2")
printf 'orphaned_wip.php\n' > "$R2/.git/claude-session-writes-${LIVESID}.txt"
RC2=$(run_mb "$MB" "$R2" "$W2")
if [ "$RC2" -eq 3 ] && [ -f "$R2/.v/tmp/merge-deferred-${SID}.md" ]; then
  ok "T2 live-owner WIP → still DEFERS (exit 3, marker written) — safety intact"
else
  no "T2 should defer on live-claimed WIP" "rc=$RC2"
fi

# ── T3 (red fixture): pre-fix merge-back DEFERS on the dead-owner fixture ──
if [ -f "$MB_BAK" ]; then
  F3="$T/f3"; mkdir -p "$F3"; { read -r R3; read -r W3; } < <(mk_fixture "$F3")
  printf 'orphaned_wip.php\n' > "$R3/.git/claude-session-writes-${DEADSID}.txt"
  RC3=$(run_mb "$MB_BAK" "$R3" "$W3")
  if [ "$RC3" -eq 3 ]; then
    ok "T3 red-fixture: pre-fix merge-back deferred on the ghost (the day-long standoff bug)"
  else
    no "T3 red-fixture vacuous" "pre-fix rc=$RC3 (expected 3)"
  fi
else
  ok "T3 skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
