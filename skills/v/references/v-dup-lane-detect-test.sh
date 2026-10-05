#!/usr/bin/env bash
# v-dup-lane-detect-test.sh — DUPLICATE-DISPATCH lane classes (batch-3, forensic 2026-07-04).
#
# THE CLASS: duplicate dispatches mint same-slug branches under different SIDs (a same-slug adapter
# branch ×2, winner landed separately). Undetected, they read as "unmerged work owed" to every driver
# and can double-land a task. Covers: SUPERSEDED (cherry-clean vs main), ZERO-DIVERGENCE twins (held
# via merge-hold, elder lands), DIVERGENT family (report-only), opt-in prune safety, the redrive
# integration (superseded lanes and attached-sibling lanes are never re-attached as strands), and
# the backfill BRANCH CENSUS (a branch-only session is now an enumerable telemetry candidate).
#
# RED ORACLES: V_TEST_REDRIVE=v-strand-redrive.sh.pre-dup0705-bak (records a superseded lane as an
# ungauntleted strand), V_TEST_BACKFILL=v-session-log-backfill.sh.pre-branchcensus0705-bak (branch-
# only SID never enumerated). The detector itself is NEW — its red oracle is the pre-fix drain
# (.pre-dup0705-bak) which runs no dup detection at all.
set -u
REFS="$HOME/.claude/skills/v/references"
DET="$REFS/v-dup-lane-detect.sh"
REDRIVE="${V_TEST_REDRIVE:-$REFS/v-strand-redrive.sh}"
BACKFILL="${V_TEST_BACKFILL:-$HOME/.claude/skills/v-session-log/references/v-session-log-backfill.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$DET" ] || { echo "SKIP: detector missing (pre-fix world)"; exit 1; }

SIDA="aaaa1e33-3333-4333-8333-000000000003"; A8="${SIDA%%-*}"
SIDB="bbbb1e44-4444-4444-8444-000000000004"; B8="${SIDB%%-*}"
OLD_DATE="2026-01-01T00:00:00"; OLD_DATE2="2026-01-02T00:00:00"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

mk_repo(){ mkdir -p "$1"; ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main && echo base > app.php && git add -A && git commit -qm init ) >/dev/null 2>&1; }

mk_lane(){ # $1=repo $2=branch $3=file $4=content $5=date — worktree-less lane, 1 commit ahead, old tip
  local R="$1" W="$1-lw"
  git -C "$R" worktree add -q "$W" -b "$2" main 2>/dev/null
  ( cd "$W" && echo "$4" > "$3" && git add "$3" \
    && GIT_AUTHOR_DATE="$5" GIT_COMMITTER_DATE="$5" git commit -qm "feat: $3" ) >/dev/null 2>&1
  git -C "$R" worktree remove --force "$W" >/dev/null 2>&1; git -C "$R" worktree prune >/dev/null 2>&1
}

# ── T1: SUPERSEDED — same patch landed on main via another commit → classified + opt-in pruned ──
R1="$T/r1"; mk_repo "$R1"
mk_lane "$R1" "build/adapter-${SIDA}" adapter.php "same content" "$OLD_DATE"
( cd "$R1" && echo "same content" > adapter.php && git add adapter.php \
  && GIT_AUTHOR_DATE="$OLD_DATE2" GIT_COMMITTER_DATE="$OLD_DATE2" git commit -qm "feat: adapter (winner lane)" ) >/dev/null 2>&1
OUT1=$(bash "$DET" "$R1" 2>&1)
printf '%s' "$OUT1" | grep -q "SUPERSEDED duplicate lane build/adapter-${SIDA}" \
  && ok "T1 superseded lane classified (cherry-clean vs main)" \
  || no "T1 superseded not detected" "$OUT1"
git -C "$R1" show-ref --verify --quiet "refs/heads/build/adapter-${SIDA}" \
  && ok "T1b report-only by default: branch NOT deleted" \
  || no "T1b detector deleted a branch without V_DUP_PRUNE=1" ""
OUT1P=$(V_DUP_PRUNE=1 bash "$DET" "$R1" 2>&1)
if ! git -C "$R1" show-ref --verify --quiet "refs/heads/build/adapter-${SIDA}"; then
  ok "T1c V_DUP_PRUNE=1 prunes the worktree-less superseded lane"
else
  no "T1c prune opt-in did not prune" "$OUT1P"
fi

# ── T2: ZERO-DIVERGENCE twins — younger twin held via merge-hold marker, elder left free ──
R2="$T/r2"; mk_repo "$R2"
mk_lane "$R2" "build/widget-${SIDA}" widget.php "twin content" "$OLD_DATE"
mk_lane "$R2" "build/widget-${SIDB}" widget.php "twin content" "$OLD_DATE2"
OUT2=$(bash "$DET" "$R2" 2>&1)
MK2="$R2/.v/artifacts/merge-hold-${B8}-dup-lane.md"
if [ -f "$MK2" ] && grep -q "build/widget-${SIDA}" "$MK2"; then
  ok "T2 zero-divergence: younger twin held via merge-hold naming the elder"
else
  no "T2 twin not held" "$OUT2"
fi
[ ! -f "$R2/.v/artifacts/merge-hold-${A8}-dup-lane.md" ] \
  && ok "T2b elder lane left free to land (no hold marker)" \
  || no "T2b elder was held too (over-hold)" ""

# ── T3: DIVERGENT family — reported, NO automatic hold ──
R3="$T/r3"; mk_repo "$R3"
mk_lane "$R3" "build/gadget-${SIDA}" gadget.php "version A" "$OLD_DATE"
mk_lane "$R3" "build/gadget-${SIDB}" gadget.php "version B totally different" "$OLD_DATE2"
OUT3=$(bash "$DET" "$R3" 2>&1)
printf '%s' "$OUT3" | grep -q "DIVERGENT same-slug duplicate" \
  && ok "T3 divergent family reported for SME adjudication" \
  || no "T3 divergent family not reported" "$OUT3"
[ -z "$(find "$R3/.v/artifacts" -name 'merge-hold-*' 2>/dev/null | head -1)" ] \
  && ok "T3b divergent lanes NOT auto-held" \
  || no "T3b divergent lane was auto-held" ""

# ── T4: redrive integration — superseded lane is NOT recorded as an ungauntleted strand ──
[ -f "$REDRIVE" ] || { echo "SKIP remaining: redrive missing"; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }
R4="$T/r4"; mk_repo "$R4"
mk_lane "$R4" "build/adapter-${SIDA}" adapter.php "same content" "$OLD_DATE"
( cd "$R4" && echo "same content" > adapter.php && git add adapter.php \
  && GIT_AUTHOR_DATE="$OLD_DATE2" GIT_COMMITTER_DATE="$OLD_DATE2" git commit -qm "feat: adapter (winner)" ) >/dev/null 2>&1
OUT4=$(bash "$REDRIVE" "$R4" 2>&1)
if printf '%s' "$OUT4" | grep -q "SUPERSEDED duplicate lane" \
   && [ -z "$(find "$R4/.v" -name "merge-deferred-*" 2>/dev/null | head -1)" ]; then
  ok "T4 redrive: superseded lane skipped as prune candidate, no strand record"
else
  no "T4 redrive still records a superseded lane as a strand (the superseded-lane noise class)" "$(printf '%s' "$OUT4" | tail -3)"
fi

# ── T5: redrive duplicate-worktree guard — sibling lane attached ⇒ this lane not re-attached ──
R5="$T/r5"; mk_repo "$R5"
mk_lane "$R5" "build/widget-${SIDA}" widget.php "version A" "$OLD_DATE"
mkdir -p "$R5/.v/artifacts"; : > "$R5/.v/artifacts/AGENT_REVIEW_${SIDA}.md"   # gauntleted — would otherwise materialize
git -C "$R5" worktree add -q "$R5-sib" -b "build/widget-${SIDB}" main 2>/dev/null
( cd "$R5-sib" && echo "version B" > widget.php && git add widget.php && git commit -qm "sibling lane" ) >/dev/null 2>&1
OUT5=$(bash "$REDRIVE" "$R5" 2>&1)
if printf '%s' "$OUT5" | grep -q "duplicate-worktree guard" && ! ls -d "$R5/.worktrees/redrive-"* >/dev/null 2>&1; then
  ok "T5 duplicate-worktree guard: attached same-slug sibling vetoes re-attach"
else
  no "T5 guard did not hold" "$(printf '%s' "$OUT5" | tail -3)"
fi

# ── T6: redrive merge-hold respect — held lane not materialized ──
R6="$T/r6"; mk_repo "$R6"
mk_lane "$R6" "build/thing-${SIDA}" thing.php "held content" "$OLD_DATE"
mkdir -p "$R6/.v/artifacts"; : > "$R6/.v/artifacts/AGENT_REVIEW_${SIDA}.md"
: > "$R6/.v/artifacts/merge-hold-${A8}-dup-lane.md"
OUT6=$(bash "$REDRIVE" "$R6" 2>&1)
if ! ls -d "$R6/.worktrees/redrive-"* >/dev/null 2>&1 && printf '%s' "$OUT6" | grep -q "merge-hold"; then
  ok "T6 redrive respects merge-hold (no worktree churn for a held lane)"
else
  no "T6 held lane was re-attached" "$(printf '%s' "$OUT6" | tail -3)"
fi

# ── T7: backfill BRANCH CENSUS — a branch-only session becomes a telemetry candidate ──
if [ -f "$BACKFILL" ]; then
  R7="$T/r7"; mk_repo "$R7"
  mk_lane "$R7" "build/ghost-${SIDA}" ghost.php "ghost content" "$OLD_DATE"
  OUT7=$(cd "$R7" && bash "$BACKFILL" "$R7" 2>&1)   # dry-run by default (no V_SL_BACKFILL_ALL)
  printf '%s' "$OUT7" | grep -q "$SIDA" \
    && ok "T7 branch-only session enumerated as backfill candidate (branch-only blind spot closed)" \
    || no "T7 branch census missing" "$(printf '%s' "$OUT7" | tail -4)"
else
  ok "T7 skipped: backfill script not on disk"
fi

# ── T8 (CODEX-001): family-PREFIX non-collision — attached build/cache-adapter-<sid> must NOT
#     veto the redrive of unrelated worktree-less family build/cache ──
R8="$T/r8"; mk_repo "$R8"
mk_lane "$R8" "build/cache-${SIDA}" cache.php "cache feature" "$OLD_DATE"
mkdir -p "$R8/.v/artifacts"; : > "$R8/.v/artifacts/AGENT_REVIEW_${SIDA}.md"
git -C "$R8" worktree add -q "$R8-adapter" -b "build/cache-adapter-${SIDB}" main 2>/dev/null
( cd "$R8-adapter" && echo adapter > adapter.php && git add adapter.php && git commit -qm "adapter lane" ) >/dev/null 2>&1
OUT8=$(bash "$REDRIVE" "$R8" 2>&1)
if ls -d "$R8/.worktrees/redrive-"* >/dev/null 2>&1; then
  ok "T8 CODEX-001: prefix family (build/cache vs build/cache-adapter) does NOT collide — strand re-attached"
else
  no "T8 prefix-collision false-veto (CODEX-001 regression)" "$(printf '%s' "$OUT8" | tail -3)"
fi

# ── T9 (CODEX-002): 3-member family — twin PAIR among NON-eldest members is held ──
R9="$T/r9"; mk_repo "$R9"
mk_lane "$R9" "build/thing-cccc1e55-5555-4555-8555-000000000005" thing.php "version A unique eldest" "$OLD_DATE"
mk_lane "$R9" "build/thing-${SIDA}" thing.php "twin content X" "$OLD_DATE2"
mk_lane "$R9" "build/thing-${SIDB}" thing.php "twin content X" "2026-01-03T00:00:00"
OUT9=$(bash "$DET" "$R9" 2>&1)
if [ -f "$R9/.v/artifacts/merge-hold-${B8}-dup-lane.md" ] \
   && [ ! -f "$R9/.v/artifacts/merge-hold-${A8}-dup-lane.md" ] \
   && [ ! -f "$R9/.v/artifacts/merge-hold-cccc1e55-dup-lane.md" ]; then
  ok "T9 CODEX-002: non-eldest twin pair detected — younger twin held, elder twin + family eldest free"
else
  no "T9 non-eldest twins missed (CODEX-002 regression)" "$OUT9"
fi

# ── T10 (CODEX-004): ambient `export V_DUP_PRUNE=1` must NOT leak pruning into the drain path ──
DRAIN_CUR="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh"
if [ -f "$DRAIN_CUR" ]; then
  R10="$T/r10"; mk_repo "$R10"
  mk_lane "$R10" "build/adapter-${SIDA}" adapter.php "same content" "$OLD_DATE"
  ( cd "$R10" && echo "same content" > adapter.php && git add adapter.php \
    && GIT_AUTHOR_DATE="$OLD_DATE2" GIT_COMMITTER_DATE="$OLD_DATE2" git commit -qm "winner" ) >/dev/null 2>&1
  STUB10="$T/stub10.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB10"; chmod +x "$STUB10"
  ( export V_DUP_PRUNE=1; V_DRAIN_MERGEBACK="$STUB10" bash "$DRAIN_CUR" "$R10" ) >/dev/null 2>&1
  git -C "$R10" show-ref --verify --quiet "refs/heads/build/adapter-${SIDA}" \
    && ok "T10 CODEX-004: ambient V_DUP_PRUNE=1 export did NOT delete a branch via the automated drain" \
    || no "T10 ambient prune leaked through the drain (CODEX-004 regression)" ""
else
  ok "T10 skipped: drain not on disk"
fi

# ── T11 (CODEX-003): stop-hook PROBE throttle — census at most once per window ──
HOOK_CUR="${V_TEST_STOP_HOOK:-$HOME/.claude/hooks/stop-drain-deferred-merges.sh}"
if [ -f "$HOOK_CUR" ]; then
  R11="$T/r11"; mk_repo "$R11"
  mk_lane "$R11" "build/hk2-${SIDA}" hk2.php "hk2 content" "$OLD_DATE"
  mkdir -p "$R11/.v/artifacts"; : > "$R11/.v/artifacts/AGENT_REVIEW_${SIDA}.md"
  H11="$T/home11"; mkdir -p "$H11/.claude/runtime"
  DSTUB11="$T/dstub11.sh"
  printf '#!/usr/bin/env bash\necho "drain $1" >> "%s"\nexit 0\n' "$T/hook11.log" > "$DSTUB11"; chmod +x "$DSTUB11"
  ( cd "$R11" && printf '{}' | HOME="$H11" V_STOP_DRAIN_SCRIPT="$DSTUB11" V_STOP_DRAIN_REDRIVE="$REDRIVE" V_STOP_DRAIN_THROTTLE_SEC=0 bash "$HOOK_CUR" ) >/dev/null 2>&1
  _i=0; while [ $_i -lt 50 ] && [ ! -s "$T/hook11.log" ]; do _i=$((_i+1)); sleep 0.1; done
  _n1=$(wc -l < "$T/hook11.log" 2>/dev/null | tr -d ' '); : "${_n1:=0}"
  ( cd "$R11" && printf '{}' | HOME="$H11" V_STOP_DRAIN_SCRIPT="$DSTUB11" V_STOP_DRAIN_REDRIVE="$REDRIVE" V_STOP_DRAIN_THROTTLE_SEC=0 bash "$HOOK_CUR" ) >/dev/null 2>&1
  sleep 0.5
  _n2=$(wc -l < "$T/hook11.log" 2>/dev/null | tr -d ' '); : "${_n2:=0}"
  if [ "$_n1" -ge 1 ] && [ "$_n2" = "$_n1" ]; then
    ok "T11 CODEX-003: second no-marker Stop within the window is probe-throttled (no repeat census/launch)"
  else
    no "T11 probe throttle did not hold (n1=$_n1 n2=$_n2)" ""
  fi
else
  ok "T11 skipped: stop hook not on disk"
fi

# ── T12 (QA-1): human branch with an 8-hex tail OUTSIDE build/|fix/ → completely untouched ──
R12="$T/r12"; mk_repo "$R12"
mk_lane "$R12" "release/v1-1a2b3c4d" rel.php "release prep" "$OLD_DATE"
OUT12A=$(bash "$REDRIVE" "$R12" 2>&1); OUT12B=$(bash "$DET" "$R12" 2>&1)
if [ -z "$(find "$R12/.v" -name 'merge-deferred-*' -o -name 'merge-hold-*' 2>/dev/null | head -1)" ] \
   && ! ls -d "$R12/.worktrees/redrive-"* >/dev/null 2>&1 \
   && git -C "$R12" show-ref --verify --quiet "refs/heads/release/v1-1a2b3c4d"; then
  ok "T12 QA-1: hex-tailed human branch (release/v1-1a2b3c4d) untouched by redrive AND detector"
else
  no "T12 non-/v branch was touched (QA-1 regression)" "$OUT12A $OUT12B"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
