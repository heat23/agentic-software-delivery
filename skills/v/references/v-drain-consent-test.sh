#!/usr/bin/env bash
# v-drain-consent-test.sh — CONSENT-DRAIN + false-landed-marker-GC classes (forensic 2026-07-04).
#
# Jul-4 fleet standoff: several sessions idle-open in terminal tabs (transcript mtime forever fresh) →
# the drain's ALIVE skip held every deferred branch hostage and NOTHING landed all day. The fix:
# a session that already WROTE merge-deferred-<sid>.md has finished and requested landing —
# drain it when the worktree is QUIESCENT (clean, tip predates the marker, marker aged), even if
# the owner is alive. Also: gc_markers must NOT GC a deferral marker whose branch reads "landed"
# via is-ancestor while its worktree still holds uncommitted content (false-landed-by-reset).
set -u
DRAIN="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh"
DRAIN_BAK="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh.pre-consent0704-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$DRAIN" ] || { echo "SKIP: drain missing"; exit 0; }

SID="c0a51e11-1111-4111-8111-000000000001"; S8="${SID%%-*}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mk_fixture(){ # $1=root -> repo at $1/repo, worktree at $1/wt, deferred marker, C-1 review artifact
  local R="$1/repo" W="$1/wt"
  mkdir -p "$R"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && echo base > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$W" -b "build/x-${S8}" HEAD 2>/dev/null
  ( cd "$W" && echo feat > feat.php && git add feat.php && git commit -qm "feat" ) >/dev/null 2>&1
  # ALIVE lock: this test shell's pid is alive for the whole run
  printf '%s %s %s\n' "$SID" "$$" "$(date +%s)" > "$W/.claude-session-lock"
  mkdir -p "$R/.v/artifacts" "$R/.v/tmp"
  { echo "deferred_sid: $SID"; echo "worktree_path: $W"; } > "$R/.v/artifacts/merge-deferred-${SID}.md"
  : > "$R/AGENT_REVIEW_${SID}.md"    # satisfy the C-1 verdict gate (full-SID match, F4)
  printf '%s\n' "$R" "$W"
}

mk_stub(){ # $1=path -> merge-back stub that records its invocation
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "${STUB_LOG:?}"
exit 0
STUB
  chmod +x "$1"
}

# ── T1: alive owner + deferral marker + quiescent worktree → drain lands by CONSENT ──
F1="$T/f1"; mkdir -p "$F1"; { read -r R1; read -r W1; } < <(mk_fixture "$F1")
STUB1="$T/stub1.sh"; mk_stub "$STUB1"
OUT1=$(STUB_LOG="$T/stub1.log" V_DRAIN_MERGEBACK="$STUB1" V_DRAIN_CONSENT_MIN_AGE_SEC=0 bash "$DRAIN" "$R1" 2>&1)
if [ -s "$T/stub1.log" ] && grep -qF "$SID" "$T/stub1.log"; then
  ok "T1 consent-drain: alive owner with quiescent deferral → merge-back invoked"
else
  no "T1 consent-drain did not land" "$(printf '%s' "$OUT1" | tail -3)"
fi
printf '%s' "$OUT1" | grep -q "landing by consent" \
  && ok "T1b drain names the consent path in its output" \
  || no "T1b consent line missing" "$(printf '%s' "$OUT1" | tail -2)"

# ── T2: alive owner + marker but DIRTY worktree → still skipped (owner may be mid-work) ──
F2="$T/f2"; mkdir -p "$F2"; { read -r R2; read -r W2; } < <(mk_fixture "$F2")
echo wip > "$W2/uncommitted.php"
STUB2="$T/stub2.sh"; mk_stub "$STUB2"
OUT2=$(STUB_LOG="$T/stub2.log" V_DRAIN_MERGEBACK="$STUB2" V_DRAIN_CONSENT_MIN_AGE_SEC=0 bash "$DRAIN" "$R2" 2>&1)
if [ ! -s "$T/stub2.log" ] && printf '%s' "$OUT2" | grep -q "skip .*ALIVE"; then
  ok "T2 dirty worktree → ALIVE skip stands (no consent)"
else
  no "T2 should have skipped a dirty live worktree" "$(printf '%s' "$OUT2" | tail -3)"
fi

# ── T3: commit AFTER the marker (owner resumed) → skipped ──
F3="$T/f3"; mkdir -p "$F3"; { read -r R3; read -r W3; } < <(mk_fixture "$F3")
touch -t 202601010000 "$R3/.v/artifacts/merge-deferred-${SID}.md"   # marker long ago
( cd "$W3" && echo more > more.php && git add more.php && git commit -qm "resumed work" ) >/dev/null 2>&1
STUB3="$T/stub3.sh"; mk_stub "$STUB3"
OUT3=$(STUB_LOG="$T/stub3.log" V_DRAIN_MERGEBACK="$STUB3" V_DRAIN_CONSENT_MIN_AGE_SEC=0 bash "$DRAIN" "$R3" 2>&1)
if [ ! -s "$T/stub3.log" ]; then
  ok "T3 tip newer than marker (owner resumed) → ALIVE skip stands"
else
  no "T3 should not land after post-deferral commits" "$(printf '%s' "$OUT3" | tail -3)"
fi

# ── T4: young marker (< min age) → skipped (never race the owner's own retry) ──
F4="$T/f4"; mkdir -p "$F4"; { read -r R4; read -r W4; } < <(mk_fixture "$F4")
STUB4="$T/stub4.sh"; mk_stub "$STUB4"
OUT4=$(STUB_LOG="$T/stub4.log" V_DRAIN_MERGEBACK="$STUB4" V_DRAIN_CONSENT_MIN_AGE_SEC=3600 bash "$DRAIN" "$R4" 2>&1)
if [ ! -s "$T/stub4.log" ]; then
  ok "T4 marker younger than consent min-age → ALIVE skip stands"
else
  no "T4 should not land on a fresh marker" "$(printf '%s' "$OUT4" | tail -3)"
fi

# ── T5 (red fixture): the PRE-FIX drain must SKIP the T1 fixture — proves the test bites ──
if [ -f "$DRAIN_BAK" ]; then
  F5="$T/f5"; mkdir -p "$F5"; { read -r R5; read -r W5; } < <(mk_fixture "$F5")
  STUB5="$T/stub5.sh"; mk_stub "$STUB5"
  OUT5=$(STUB_LOG="$T/stub5.log" V_DRAIN_MERGEBACK="$STUB5" V_DRAIN_CONSENT_MIN_AGE_SEC=0 bash "$DRAIN_BAK" "$R5" 2>&1)
  if [ ! -s "$T/stub5.log" ]; then
    ok "T5 red-fixture: pre-fix drain skips the alive+deferred+quiescent worktree (the standoff bug)"
  else
    no "T5 red-fixture vacuous: pre-fix drain landed it too" "$(printf '%s' "$OUT5" | tail -2)"
  fi
else
  ok "T5 skipped: no pre-fix bak on disk"
fi

# ── T6: gc_markers false-landed-by-reset guard — branch reads landed (reset to main HEAD) but
#        worktree holds STAGED content → marker KEPT ──
F6="$T/f6"; R6="$F6/repo"; W6="$F6/wt"; mkdir -p "$R6"
( cd "$R6" && git init -q && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main && echo base > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
git -C "$R6" worktree add -q "$W6" -b "build/y-${S8}" HEAD 2>/dev/null
( cd "$W6" && echo staged > staged.php && git add staged.php ) >/dev/null 2>&1   # STAGED, never committed
mkdir -p "$R6/.v/artifacts"
{ echo "deferred_sid: $SID"; echo "worktree_path: $W6"; } > "$R6/.v/artifacts/merge-deferred-${SID}.md"
OUT6=$(V_DRAIN_DRY_RUN=1 bash "$DRAIN" "$R6" 2>&1)
if [ -f "$R6/.v/artifacts/merge-deferred-${SID}.md" ] && printf '%s' "$OUT6" | grep -q "KEEP marker"; then
  ok "T6 false-landed-by-reset: marker KEPT while the worktree holds staged-only work"
else
  no "T6 marker should be kept for a reset branch with staged content" "$(printf '%s' "$OUT6" | tail -3)"
fi
if [ -f "$DRAIN_BAK" ]; then
  OUT6B=$(V_DRAIN_DRY_RUN=1 bash "$DRAIN_BAK" "$R6" 2>&1)
  printf '%s' "$OUT6B" | grep -q "would GC stale marker" \
    && ok "T6b red-fixture: pre-fix gc_markers would have GC'd the marker over live staged work" \
    || ok "T6b red-fixture inconclusive (pre-fix output differs) — non-blocking"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
