#!/usr/bin/env bash
# v-drain-dirty-midsetup-test.sh — DIRTY-WORKTREE STRAND vs mid-setup (forensic 2026-07-07).
#
# A session whose FORK did real work but whose parent closed at 0 turns (or that timed out before it
# committed) leaves its deliverables UNCOMMITTED in the worktree: N files dirty, 0 commits ahead, no lock,
# no artifact. The pre-fix drain's mid-setup skip looked ONLY at commits-ahead + artifacts, so it called
# this "no stranding proof … likely a sibling mid-setup" — which reads as "nothing here, safe to prune".
# The fix checks worktree dirtiness first: a lockless worktree with uncommitted content is an ENDED
# session's un-committed work, HELD + reported (not auto-landable — nothing is committed to merge) with a
# resume pointer, never mislabeled as mid-setup.
#   T1: dirty lockless worktree (0 ahead) → drain HOLDs it, says UNCOMMITTED + Do NOT prune, NOT "mid-setup".
#   T2: CLEAN lockless worktree (0 ahead) → still the benign "likely a sibling mid-setup" skip (no false HOLD).
#   T3 (red fixture): the pre-fix drain mislabels the DIRTY case as "likely a sibling mid-setup".
set -u
DRAIN="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh"
DRAIN_BAK="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh.pre-dirtymidsetup-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
[ -f "$DRAIN" ] || { echo "SKIP: drain missing"; exit 0; }

SID="eeee1111-2222-4333-8444-555566667777"; S8="${SID%%-*}"
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# $1=root $2=dirty(1|0) -> repo with a lockless worktree, branch fix/thing-<SID>, 0 commits ahead.
mk_midsetup(){
  local R="$1/repo" W="$1/wt"
  mkdir -p "$R"
  ( cd "$R" && git init -q -b main && echo base > app.php && G add -A && G commit -qm base ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$W" -b "fix/thing-${SID}" HEAD 2>/dev/null
  # NO .claude-session-lock (lockless → _session_alive false → reaches the mid-setup skip). 0 commits ahead.
  if [ "$2" = 1 ]; then
    # real, UNCOMMITTED deliverable in the worktree working tree (fork-did-work / timeout-before-commit)
    printf 'hardened\n' >> "$W/app.php"
    printf 'new source\n' > "$W/feat.php"
  fi
  printf '%s\n' "$R"
}

# a merge-back stub — never reached on the mid-setup path (we `continue` first), but harmless if it is.
STUB="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB"; chmod +x "$STUB"
T="$(mktemp -d)"; trap 'rm -rf "$T" "$STUB"' EXIT

# ── T1: dirty lockless worktree → HELD as uncommitted strand, not mid-setup ──
F1="$T/f1"; mkdir -p "$F1"; R1="$(mk_midsetup "$F1" 1)"
OUT1=$(V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN" "$R1" 2>&1)
if printf '%s' "$OUT1" | grep -qi 'UNCOMMITTED' \
   && printf '%s' "$OUT1" | grep -qi 'do NOT prune' \
   && ! printf '%s' "$OUT1" | grep -qi 'likely a sibling mid-setup'; then
  ok "T1 dirty lockless worktree → reported as UNCOMMITTED work + resume pointer, NOT mid-setup"
else
  no "T1 dirty worktree mislabeled or not held" "$(printf '%s' "$OUT1" | grep -iE 'thing-|mid-setup|uncommitted' | head -3 | tr '\n' '|')"
fi

# ── T2: CLEAN lockless worktree → benign mid-setup skip preserved (no false HOLD) ──
F2="$T/f2"; mkdir -p "$F2"; R2="$(mk_midsetup "$F2" 0)"
OUT2=$(V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN" "$R2" 2>&1)
if printf '%s' "$OUT2" | grep -qi 'likely a sibling mid-setup' \
   && ! printf '%s' "$OUT2" | grep -qi 'UNCOMMITTED'; then
  ok "T2 clean lockless worktree → still the benign mid-setup skip (no false HOLD / no false-positive)"
else
  no "T2 clean worktree behaved unexpectedly" "$(printf '%s' "$OUT2" | grep -iE 'thing-|mid-setup|uncommitted' | head -3 | tr '\n' '|')"
fi

# ── T3 (red fixture): pre-fix drain mislabels the DIRTY case as mid-setup ──
if [ -f "$DRAIN_BAK" ]; then
  F3="$T/f3"; mkdir -p "$F3"; R3="$(mk_midsetup "$F3" 1)"
  OUT3=$(V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN_BAK" "$R3" 2>&1)
  if printf '%s' "$OUT3" | grep -qi 'likely a sibling mid-setup' \
     && ! printf '%s' "$OUT3" | grep -qi 'UNCOMMITTED'; then
    ok "T3 red-fixture: pre-fix drain mislabeled the dirty strand as mid-setup (the bug the fix closes)"
  else
    no "T3 red-fixture vacuous: pre-fix drain did not mislabel (fixture no longer reaches the path?)" "$(printf '%s' "$OUT3" | grep -iE 'thing-|mid-setup|uncommitted' | head -3 | tr '\n' '|')"
  fi
else
  ok "T3 skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
