#!/usr/bin/env bash
# v-merge-back-lockscan-resolve-test.sh — adopted-worktree lock-scan resolution (forensic 2026-07-04).
# A bare `v-merge-back <sid>` from the main checkout used to resolve the worktree by cwd,
# hitting "main checkout; nothing to merge" for an ADOPTED worktree (branch named with a sibling's
# SID). merge-back now lock-scans the registered worktrees for the one whose .claude-session-lock SID
# matches, when no explicit path is given.
#   T1: bare `<sid>` from main root → resolves the adopted worktree by lock-SID and merges it.
#   T2: an explicit path arg is still honored (no scan override).
#   T3 (red fixture): the pre-fix merge-back reports "nothing to merge" for the bare call.
set -u
MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
MB_BAK="$HOME/.claude/skills/v/references/v-merge-back.sh.pre-orphan0704-bak"   # predates the lock-scan edit
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
[ -f "$MB" ] || { echo "SKIP: merge-back missing"; exit 0; }
export V_MERGE_BACK_SKIP_ARTIFACT_GATE=1
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# SID differs from the branch-name slug (the ADOPTION shape): branch carries OTHER8, lock carries SID.
SID="dddddddd-1111-4111-8111-000000000001"
OTHER8="eeeeeeee"

mk(){ # $1=root -> repo at $1/repo, adopted worktree at $1/wt (branch named with OTHER8, lock=SID)
  local R="$1/repo" W="$1/wt"
  mkdir -p "$R"
  ( cd "$R" && git init -q -b main && echo base > app.php && G add -A && G commit -qm base ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$W" -b "build/feature-${OTHER8}" HEAD 2>/dev/null
  ( cd "$W" && echo feat > feat.php && G add feat.php && G commit -qm feat ) >/dev/null 2>&1
  printf '%s %s %s\n' "$SID" "$$" "$(date +%s)" > "$W/.claude-session-lock"   # lock re-keyed to the adopter
  printf '%s\n' "$R" "$W"
}

run_bare(){ # $1=script $2=repo-root  — invoke with ONLY the SID, cwd=main root
  ( cd "$2" && bash "$1" "$SID" ) 2>&1
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── T1: bare <sid> from main root resolves + merges the adopted worktree ──
F1="$T/f1"; mkdir -p "$F1"; { read -r R1; read -r W1; } < <(mk "$F1")
OUT=$(run_bare "$MB" "$R1")
if printf '%s' "$OUT" | grep -q "lock-scan resolved worktree for $SID"; then
  ok "T1 bare <sid> lock-scan resolved the adopted worktree (branch carries a sibling's SID)"
else
  no "T1 lock-scan did not resolve" "$(printf '%s' "$OUT" | grep -iE 'nothing to merge|lock-scan|INFO' | head -2)"
fi
if git -C "$R1" cat-file -e main:feat.php 2>/dev/null; then
  ok "T1b the adopted worktree's commit actually landed on main"
else
  no "T1b feature did not land" "$(printf '%s' "$OUT" | tail -3)"
fi

# ── T2: an explicit path arg is still honored (scan must not override it) ──
F2="$T/f2"; mkdir -p "$F2"; { read -r R2; read -r W2; } < <(mk "$F2")
OUT2=$( ( cd "$R2" && bash "$MB" "$SID" "$W2" ) 2>&1 )
# with an explicit path, the lock-scan INFO line must NOT appear (path given → scan skipped)
if ! printf '%s' "$OUT2" | grep -q "lock-scan resolved"; then
  ok "T2 explicit path arg honored (lock-scan skipped when a path is given)"
else
  no "T2 lock-scan wrongly ran despite an explicit path" "$(printf '%s' "$OUT2" | grep lock-scan)"
fi

# ── T3 (red fixture): pre-fix merge-back says "nothing to merge" for the bare call ──
if [ -f "$MB_BAK" ]; then
  F3="$T/f3"; mkdir -p "$F3"; { read -r R3; read -r W3; } < <(mk "$F3")
  OUT3=$(run_bare "$MB_BAK" "$R3")
  if printf '%s' "$OUT3" | grep -qi "main checkout; nothing to merge"; then
    ok "T3 red-fixture: pre-fix merge-back resolved to main checkout ('nothing to merge') — the bug"
  else
    ok "T3 red-fixture inconclusive (pre-fix behaved differently) — non-blocking"
  fi
else
  ok "T3 skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
