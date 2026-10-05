#!/usr/bin/env bash
# v-strand-redrive-test.sh — STRAND-LIVENESS class (FND-3 liveness re-driver, forensic 2026-07-04).
#
# THE CLASS: v-drain-deferred-merges.sh walks `git worktree list` only, so a gauntleted-but-unmerged
# branch whose WORKTREE IS GONE (owner session dead, worktree GC'd) is invisible to every drain
# trigger — a manual recovery had to park checkpoint worktrees on disk just so the drain could
# see them. v-strand-redrive.sh re-attaches such strands (materializes a plain worktree) so the
# drain's existing C-1 + merge-back gate chain decides the landing.
#
# RED ORACLE: run with V_TEST_DRAIN=<path to v-drain-deferred-merges.sh.pre-redrive0704-bak> —
# T1 fails (the pre-fix drain never considers a worktree-less branch) → harness exits 1.
set -u
REFS="$HOME/.claude/skills/v/references"
DRAIN="${V_TEST_DRAIN:-$REFS/v-drain-deferred-merges.sh}"
DRAIN_BAK="$REFS/v-drain-deferred-merges.sh.pre-redrive0704-bak"
REDRIVE="$REFS/v-strand-redrive.sh"
CRON="${V_TEST_CRON:-$HOME/.claude/scripts/v-cron-drain.sh}"
HOOK="${V_TEST_STOP_HOOK:-$HOME/.claude/hooks/stop-drain-deferred-merges.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$DRAIN" ] || { echo "SKIP: drain missing"; exit 0; }
[ -f "$REDRIVE" ] || { echo "SKIP: redrive missing (pre-fix world)"; exit 1; }

SID="5e55a000-2222-4222-8222-000000000002"; S8="${SID%%-*}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
OLD_DATE="2026-01-01T00:00:00"

mk_repo(){ # $1=dir — main repo with one base commit
  mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && echo base > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
}

mk_strand(){ # $1=repo $2=branch — 1 commit ahead, OLD tip, worktree REMOVED (the class fixture)
  local R="$1" B="$2" W="$1-wt-tmp"
  git -C "$R" worktree add -q "$W" -b "$B" HEAD 2>/dev/null
  ( cd "$W" && echo feat > feat.php && git add feat.php \
    && GIT_AUTHOR_DATE="$OLD_DATE" GIT_COMMITTER_DATE="$OLD_DATE" git commit -qm "feat" ) >/dev/null 2>&1
  git -C "$R" worktree remove --force "$W" >/dev/null 2>&1
  git -C "$R" worktree prune >/dev/null 2>&1
}

mk_stub(){ # $1=path — merge-back stub recording "SID WT" lines
  cat > "$1" <<'STUB'
#!/usr/bin/env bash
echo "$1 $2" >> "${STUB_LOG:?}"
exit 0
STUB
  chmod +x "$1"
}

# ── T1: THE CLASS — gauntleted branch, dead owner, NO worktree → drain re-attaches and lands ──
R1="$T/r1"; mk_repo "$R1"; mk_strand "$R1" "build/feat-${S8}"
mkdir -p "$R1/.v/artifacts"; : > "$R1/.v/artifacts/AGENT_REVIEW_${SID}.md"
STUB1="$T/stub1.sh"; mk_stub "$STUB1"
OUT1=$(STUB_LOG="$T/stub1.log" V_DRAIN_MERGEBACK="$STUB1" bash "$DRAIN" "$R1" 2>&1)
if [ -s "$T/stub1.log" ] && grep -qF "$SID" "$T/stub1.log"; then
  ok "T1 strand-liveness class: worktree-less gauntleted strand re-attached + merge-back invoked with full SID"
else
  no "T1 strand stayed stranded (the pre-fix class)" "$(printf '%s' "$OUT1" | tail -4)"
fi
ls -d "$R1/.worktrees/redrive-"* >/dev/null 2>&1 \
  && ok "T1b redrive worktree materialized under .worktrees/redrive-*" \
  || no "T1b no redrive worktree on disk" "$(printf '%s' "$OUT1" | tail -3)"

# ── T2: UNGAUNTLETED strand (no AGENT_REVIEW) → never materialized, loud durable record, idempotent ──
R2="$T/r2"; mk_repo "$R2"; mk_strand "$R2" "build/raw-${S8}"
STUB2="$T/stub2.sh"; mk_stub "$STUB2"
OUT2=$(STUB_LOG="$T/stub2.log" V_DRAIN_MERGEBACK="$STUB2" bash "$DRAIN" "$R2" 2>&1)
MK2="$(find "$R2/.v/artifacts" -name "merge-deferred-${S8}*.md" 2>/dev/null | head -1)"
if [ ! -s "$T/stub2.log" ] && [ -n "$MK2" ] && grep -q "ungauntleted" "$MK2" 2>/dev/null; then
  ok "T2 ungauntleted strand: NOT landed, durable ungauntleted record written"
else
  no "T2 ungauntleted strand mishandled" "$(printf '%s' "$OUT2" | tail -4)"
fi
ls -d "$R2/.worktrees/redrive-"* >/dev/null 2>&1 \
  && no "T2b worktree churn: materialized an ungauntleted strand" "" \
  || ok "T2b no worktree materialized for ungauntleted strand"
OUT2B=$(STUB_LOG="$T/stub2.log" V_DRAIN_MERGEBACK="$STUB2" bash "$DRAIN" "$R2" 2>&1)
N2=$(find "$R2/.v/artifacts" "$R2/.v/tmp" -name "merge-deferred-${S8}*.md" 2>/dev/null | wc -l | tr -d ' ')
[ "$N2" = "1" ] && [ ! -s "$T/stub2.log" ] \
  && ok "T2c idempotent: second drain adds no duplicate record, still no landing" \
  || no "T2c second run not idempotent (records=$N2)" "$(printf '%s' "$OUT2B" | tail -3)"

# ── T3: user branch (no SID tail) with commits ahead → NEVER touched ──
R3="$T/r3"; mk_repo "$R3"; mk_strand "$R3" "release-notes"
STUB3="$T/stub3.sh"; mk_stub "$STUB3"
OUT3=$(STUB_LOG="$T/stub3.log" V_DRAIN_MERGEBACK="$STUB3" bash "$DRAIN" "$R3" 2>&1)
if [ ! -s "$T/stub3.log" ] && ! ls -d "$R3/.worktrees/redrive-"* >/dev/null 2>&1 \
   && [ -z "$(find "$R3/.v" -name 'merge-deferred-*' 2>/dev/null | head -1)" ]; then
  ok "T3 user branch without SID tail: untouched (no worktree, no record, no landing)"
else
  no "T3 user branch was touched" "$(printf '%s' "$OUT3" | tail -3)"
fi

# ── T4: YOUNG tip (fresh commit) → skipped; never race a freshly-dead session ──
R4="$T/r4"; mk_repo "$R4"
git -C "$R4" worktree add -q "$R4-wt" -b "build/new-${S8}" HEAD 2>/dev/null
( cd "$R4-wt" && echo x > x.php && git add x.php && git commit -qm fresh ) >/dev/null 2>&1
git -C "$R4" worktree remove --force "$R4-wt" >/dev/null 2>&1; git -C "$R4" worktree prune >/dev/null 2>&1
mkdir -p "$R4/.v/artifacts"; : > "$R4/.v/artifacts/AGENT_REVIEW_${SID}.md"
OUT4=$(bash "$REDRIVE" "$R4" 2>&1)
if printf '%s' "$OUT4" | grep -q "skipped-young=1" && ! ls -d "$R4/.worktrees/redrive-"* >/dev/null 2>&1; then
  ok "T4 fresh tip (< min age): skipped, nothing materialized"
else
  no "T4 young-tip guard did not hold" "$(printf '%s' "$OUT4" | tail -3)"
fi

# ── T5: --probe is a read-only census ──
R5="$T/r5"; mk_repo "$R5"; mk_strand "$R5" "build/p-${S8}"
mkdir -p "$R5/.v/artifacts"; : > "$R5/.v/artifacts/AGENT_REVIEW_${SID}.md"
OUT5=$(bash "$REDRIVE" "$R5" --probe 2>&1)
if [ "$(printf '%s\n' "$OUT5" | sed -n 's/^strands=//p')" = "1" ] \
   && ! ls -d "$R5/.worktrees/redrive-"* >/dev/null 2>&1 \
   && [ -z "$(find "$R5/.v" -name 'merge-deferred-*' 2>/dev/null | head -1)" ]; then
  ok "T5 probe: strands=1, zero side effects"
else
  no "T5 probe wrong or side-effecting" "$OUT5"
fi

# ── T6: dry-run previews, changes nothing ──
OUT6=$(V_DRAIN_DRY_RUN=1 bash "$DRAIN" "$R5" 2>&1)
if printf '%s' "$OUT6" | grep -q "would materialize" && ! ls -d "$R5/.worktrees/redrive-"* >/dev/null 2>&1; then
  ok "T6 dry-run names the would-be materialization, creates nothing"
else
  no "T6 dry-run behavior wrong" "$(printf '%s' "$OUT6" | tail -3)"
fi

# ── T7: LIVE owner (alive lock on a registered worktree with this SID) → skip ──
R7="$T/r7"; mk_repo "$R7"; mk_strand "$R7" "build/live-${S8}"
mkdir -p "$R7/.v/artifacts"; : > "$R7/.v/artifacts/AGENT_REVIEW_${SID}.md"
git -C "$R7" worktree add -q "$R7-other" -b "build/other-${SID}" HEAD 2>/dev/null
printf '%s %s %s\n' "$SID" "$$" "$(date +%s)" > "$R7-other/.claude-session-lock"   # ALIVE: this shell
OUT7=$(bash "$REDRIVE" "$R7" 2>&1)
if printf '%s' "$OUT7" | grep -q "skipped-LIVE=1" && ! ls -d "$R7/.worktrees/redrive-"* >/dev/null 2>&1; then
  ok "T7 live same-SID lock elsewhere: strand skipped (never re-drive a live session)"
else
  no "T7 live-owner guard did not hold" "$(printf '%s' "$OUT7" | tail -3)"
fi

# ── T8: stop-drain hook probe — no markers, worktree-less strand → drain LAUNCHED ──
if [ -f "$HOOK" ]; then
  R8="$T/r8"; mk_repo "$R8"; mk_strand "$R8" "build/hk-${S8}"
  mkdir -p "$R8/.v/artifacts"; : > "$R8/.v/artifacts/AGENT_REVIEW_${SID}.md"
  DSTUB8="$T/dstub8.sh"
  cat > "$DSTUB8" <<STUB8
#!/usr/bin/env bash
echo "drain \$1" >> "$T/hook8.log"
exit 0
STUB8
  chmod +x "$DSTUB8"
  H8="$T/home8"; mkdir -p "$H8/.claude/runtime"
  ( cd "$R8" && printf '{}' | HOME="$H8" V_STOP_DRAIN_SCRIPT="$DSTUB8" V_STOP_DRAIN_REDRIVE="$REDRIVE" bash "$HOOK" ) >/dev/null 2>&1
  _i=0; while [ $_i -lt 50 ] && [ ! -s "$T/hook8.log" ]; do _i=$((_i+1)); sleep 0.1; done
  if [ -s "$T/hook8.log" ] && grep -qF "$R8" "$T/hook8.log"; then
    ok "T8 stop-hook probe: marker-less worktree-less strand still triggers the drain"
  else
    no "T8 stop-hook fast path still blind to worktree-less strands" "$(cat "$R8/.v/artifacts/"stop-drain-*.log 2>/dev/null | tail -2)"
  fi
  # control: no strand, no markers → hook exits without launching
  R8C="$T/r8c"; mk_repo "$R8C"
  ( cd "$R8C" && printf '{}' | HOME="$H8" V_STOP_DRAIN_SCRIPT="$DSTUB8" V_STOP_DRAIN_REDRIVE="$REDRIVE" bash "$HOOK" ) >/dev/null 2>&1
  sleep 0.3
  grep -qF "$R8C" "$T/hook8.log" 2>/dev/null \
    && no "T8b hook launched a drain with nothing owed" "" \
    || ok "T8b control: clean repo → hook fast path still exits quietly"
else
  ok "T8 skipped: stop-drain hook not on disk"
fi

# ── T9: cron actor — registry repo with NO markers but a strand is KEPT + drained (not pruned) ──
if [ -f "$CRON" ]; then
  R9="$T/r9"; mk_repo "$R9"; mk_strand "$R9" "build/cr-${S8}"
  mkdir -p "$R9/.v/artifacts"; : > "$R9/.v/artifacts/AGENT_REVIEW_${SID}.md"
  R9C="$T/r9c"; mk_repo "$R9C"                                   # control: nothing owed → pruned
  RT9="$T/rt9"; mkdir -p "$RT9"
  printf '%s\n%s\n' "$R9" "$R9C" > "$RT9/v-drain-repos.txt"
  DSTUB9="$T/dstub9.sh"
  cat > "$DSTUB9" <<STUB9
#!/usr/bin/env bash
echo "drain \$1" >> "$T/cron9.log"
exit 0
STUB9
  chmod +x "$DSTUB9"
  V_RUNTIME_DIR="$RT9" V_CRON_DRAIN_SCRIPT="$DSTUB9" V_CRON_REDRIVE_SCRIPT="$REDRIVE" bash "$CRON" >/dev/null 2>&1
  if grep -qF "$R9" "$T/cron9.log" 2>/dev/null && grep -qxF "$R9" "$RT9/v-drain-repos.txt" 2>/dev/null; then
    ok "T9 cron actor: marker-less strand repo kept in registry + drained"
  else
    no "T9 cron actor pruned/skipped a repo that still owes a landing" "$(cat "$RT9/v-drain-repos.txt" 2>/dev/null)"
  fi
  grep -qxF "$R9C" "$RT9/v-drain-repos.txt" 2>/dev/null \
    && no "T9b control repo (nothing owed) not pruned" "" \
    || ok "T9b control: repo with nothing owed pruned from registry"
else
  ok "T9 skipped: cron drain not on disk"
fi

# ── T10 (red fixture): the PRE-FIX drain must LEAVE the T1-class strand stranded — proves the bite ──
if [ -f "$DRAIN_BAK" ]; then
  R10="$T/r10"; mk_repo "$R10"; mk_strand "$R10" "build/red-${S8}"
  mkdir -p "$R10/.v/artifacts"; : > "$R10/.v/artifacts/AGENT_REVIEW_${SID}.md"
  STUB10="$T/stub10.sh"; mk_stub "$STUB10"
  OUT10=$(STUB_LOG="$T/stub10.log" V_DRAIN_MERGEBACK="$STUB10" bash "$DRAIN_BAK" "$R10" 2>&1)
  if [ ! -s "$T/stub10.log" ]; then
    ok "T10 red-fixture: pre-fix drain never considers the worktree-less branch (the strand-liveness class)"
  else
    no "T10 red-fixture vacuous: pre-fix drain landed it too" "$(printf '%s' "$OUT10" | tail -2)"
  fi
else
  ok "T10 skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
