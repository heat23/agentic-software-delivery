#!/usr/bin/env bash
# v-run-gates-treededup-test.sh — TREEDEDUP tree-hash gate dedup (backlog #1, 2026-07-09;
# extended to SCOPED runs by F6 on 2026-08-29 — see the F6-* cases).
#
# CLASS: redundant full gate runs on CONTENT-IDENTICAL trees (fleet verify lanes, back-to-back
# /v sessions, re-dispatch storms) are pure waste; P1C only covers same-SID re-verifies.
# FIX: v-run-gates.sh TREEDEDUP-REUSE (reuse a green verdict when tree+config hash match,
# HMAC-verified, TTL-bounded, fail-closed) + TREEDEDUP-MEMO-WRITE (memo written ONLY on a
# strictly-green primary-lane run with a pre/post tree-hash equality bind).
# F6 (2026-08-29): coverage is no longer full-mode-only. MODE and SCOPE_DIGEST are now INSIDE the
# HMAC canonical on both sign and verify sides, so a full memo can never satisfy a scoped request
# (or vice versa) and a changed scope set invalidates reuse. Scoped memos live at a distinct
# gates-green-memo-scoped.* path; the full-mode filename is unchanged.
#
# Idiom: blocks extracted VERBATIM (awk range) and eval'd against real git fixture repos —
# same pattern as p1c-reverify-scope-test.sh. T9 drives the REAL Stop hook (CRA) against a
# PRE_FLIGHT_REPORT carrying the reuse wording (W71 scanner must not block it).
# RED ORACLE: v-run-gates.sh.pre-treededup-bak has neither block → awk ranges empty.
set -u
SCRIPT="${V_RUNGATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
BAK="$HOME/.claude/skills/v/references/v-run-gates.sh.pre-treededup-bak"
CRA="$HOME/.claude/hooks/check-review-artifact.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP: openssl unavailable"; exit 0; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
HOMEDIR="$TMP/home"; REPO="$TMP/repo"
mkdir -p "$HOMEDIR/.claude/runtime" "$REPO"
REAL_LIB_DIR="$HOME/.claude/hooks/lib"
# The block's self-binding falls back to $HOME/.claude/skills/v/references/v-run-gates.sh when
# BASH_SOURCE is relative (this harness's eval context) — mirror it into the fixture HOME.
mkdir -p "$HOMEDIR/.claude/skills/v/references"
ln -s "$HOME/.claude/skills/v/references/v-run-gates.sh" "$HOMEDIR/.claude/skills/v/references/v-run-gates.sh" 2>/dev/null
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p app && printf '<?php echo 1;\n' > app/a.php \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$REPO/.v/artifacts" "$REPO/.v/tmp"

REUSE="$(awk '/^# === TREEDEDUP-REUSE /,/^# === end TREEDEDUP-REUSE ===/' "$SCRIPT")"
WRITE="$(awk '/^# === TREEDEDUP-MEMO-WRITE /,/^# === end TREEDEDUP-MEMO-WRITE ===/' "$SCRIPT")"

echo "== TREEDEDUP :: tree-hash full-suite dedup =="
if [ -z "$REUSE" ] || [ -z "$WRITE" ]; then
  no "TREEDEDUP blocks present in v-run-gates.sh" "awk range empty (pre-treededup = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "both TREEDEDUP blocks present"

# Placement invariant: REUSE must sit AFTER command resolution and BEFORE Phase 1 execution,
# and its hit path must hard-exit (short-circuiting the gates) — grep-level structural proof.
_l_reuse=$(grep -n '^# === TREEDEDUP-REUSE ' "$SCRIPT" | cut -d: -f1)
_l_vitest=$(grep -n '^VITEST_CMD_DEFAULT=' "$SCRIPT" | head -1 | cut -d: -f1)
# W-PHPSTAN1 (2026-07-14): match the Phase 1 SECTION HEADER, not its gate list. The marker was the
# literal 'Phase 1: TSC + audits in parallel', so adding a gate to Phase 1 (PHPStan) renamed the
# header and silently emptied $_l_phase1 — failing this placement check for a reason unrelated to the
# placement it guards. Anchor on the stable numbered-section prefix instead; the invariant is
# unchanged (REUSE must sit between command resolution and Phase 1 execution).
_l_phase1=$(grep -nE '^# ── 4\. Phase 1:' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$_l_reuse" ] && [ -n "$_l_vitest" ] && [ -n "$_l_phase1" ] \
   && [ "$_l_reuse" -gt "$_l_vitest" ] && [ "$_l_reuse" -lt "$_l_phase1" ] \
   && awk '/^# === TREEDEDUP-REUSE /,/^# === end TREEDEDUP-REUSE ===/' "$SCRIPT" | grep -q '^        exit 0$'; then
  ok "REUSE block placed after command resolution, before Phase 1, with a hard exit on hit"
else
  no "REUSE block placement/exit invariant broken" "reuse=$_l_reuse vitest=$_l_vitest phase1=$_l_phase1"
fi

# run_reuse <sid> [extra-env-assignments...] — eval the REUSE block in a fixture subshell.
# Echoes marker "HIT" if the block exited (reuse fired), "MISS" if it fell through.
run_reuse() {
  local sid="$1"; shift
  ( cd "$REPO" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$REPO/.v/tmp"; SESSION_ID="$sid"
    PROJECT_ROOT="$REPO"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    for _a in "$@"; do eval "$_a"; done
    eval "$REUSE"
    echo "MISS"   # only reached when the block fell through (no reuse)
  ) > "$TMP/out.$sid" 2>"$TMP/err.$sid"
  if grep -q '^MISS$' "$TMP/out.$sid"; then echo MISS; else echo HIT; fi
}

# run_write <sid> [extra-env-assignments...] — eval REUSE (to bind _TD_*) then WRITE, against a
# green fixture summary+skeleton for <sid>. F6: the fixture's Mode:/MODE= content follows a
# 'PFM=<mode>' entry in the extra-env-assignments (default "full", i.e. byte-identical to the
# pre-F6 hardcoded fixture for every EXISTING caller below that never passes PFM=) — a real run's
# skeleton always carries the correct Mode: line (v-run-gates.sh's own report writer), so a scoped
# fixture must too, or the REUSE-HIT skeleton splice (which prints the memo's stored Mode: line
# verbatim) would misreport a scoped reuse as "Mode: full".
run_write() {
  local sid="$1"; shift
  local _rw_mode="full" _rw_a
  for _rw_a in "$@"; do
    case "$_rw_a" in PFM=*) _rw_mode="${_rw_a#PFM=}" ;; esac
  done
  printf 'TSC_RC=0\nLINT_RC=0\nBUILD_RC=0\nPEST_RC=0\nVITEST_RC=0\nCOMPOSER_AUDIT_RC=SKIP\nNPM_AUDIT_RC=SKIP\nMODE=%s\nDONE_AT=2026-07-09T00:00:00Z\n' "$_rw_mode" > "$REPO/.v/tmp/gate-summary-${sid}.txt"
  {
    printf 'Repo: %s\nHEAD: deadbeef\nMode: %s\n## Gates\n| Status | Gate | Notes |\n|--------|------|-------|\n' "$REPO" "$_rw_mode"
    printf '| PASS | TypeScript | 1s |\n| PASS | Lint | 1s |\n| PASS | Build | 1s |\n| PASS | PHP Tests | 1s |\n| PASS | JS Tests | 1s |\n\n'
    printf 'Overall Status: PASS\n'
  } > "$REPO/.v/tmp/pre-flight-skeleton-${sid}.md"
  ( cd "$REPO" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0; _GATE_SUFFIX=""
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$REPO/.v/tmp"; SESSION_ID="$sid"
    PROJECT_ROOT="$REPO"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    ALL_PASS=1; PREFLIGHT_BLIND=0; TREE_MISMATCH=0
    SUMMARY_FILE="$REPO/.v/tmp/gate-summary-${sid}.txt"
    SKELETON_FILE="$REPO/.v/tmp/pre-flight-skeleton-${sid}.md"
    for _a in "$@"; do eval "$_a"; done
    eval "$REUSE" >/dev/null   # binds _TD_HASH_T0/_TD_CONFIG_HASH/_TD_MAIN_ART (memo absent → miss)
    eval "$WRITE"
  ) >"$TMP/wout.$sid" 2>"$TMP/werr.$sid"
}

MEMO="$REPO/.v/artifacts/gates-green-memo.txt"
MEMO_SCOPED="$REPO/.v/artifacts/gates-green-memo-scoped.txt"

# T1 — green full run writes a signed memo.
run_write "aaaaaaaa-1dd0-4111-8111-aaaaaaaaaaaa"
if [ -f "$MEMO" ] && grep -q '^HMAC=..' "$MEMO" && [ -f "$REPO/.v/artifacts/gates-green-memo-summary.txt" ] \
   && [ -f "$REPO/.v/artifacts/gates-green-memo-skeleton.md" ]; then
  ok "T1: strictly-green full run writes a signed memo (+summary/skeleton copies)"
else
  no "T1: memo not written on a green run" "$(tail -2 "$TMP/werr.aaaaaaaa-1dd0-4111-8111-aaaaaaaaaaaa" 2>/dev/null | head -1)"
fi

# T2 — identical tree, NEW sid ⇒ reuse fires; artifacts carry the reuse contract.
S2="bbbbbbbb-1dd0-4222-8222-bbbbbbbbbbbb"
if [ "$(run_reuse "$S2")" = "HIT" ] \
   && grep -q '^TREEDEDUP=1$' "$REPO/.v/tmp/gate-summary-${S2}.txt" 2>/dev/null \
   && grep -q '^Reuse: tree-hash dedup' "$REPO/.v/tmp/pre-flight-skeleton-${S2}.md" 2>/dev/null \
   && [ "$(grep -v '^$' "$REPO/.v/tmp/pre-flight-skeleton-${S2}.md" | tail -1)" = "Overall Status: PASS" ]; then
  ok "T2: identical tree + new SID reuses the verdict (TREEDEDUP=1 summary, Reuse-line skeleton, PASS last line)"
else
  no "T2: reuse did not fire on an identical tree" "$(tail -2 "$TMP/err.$S2" 2>/dev/null | head -1)"
fi

# T2b — reuse prose contains no W71 skip-vocabulary (skip/partial/defer/not run).
if ! grep -iE '(^|[^a-z])(skip|skipped|partial|defer|not run)([^a-z]|$)' \
     "$REPO/.v/tmp/pre-flight-skeleton-${S2}.md" >/dev/null 2>&1; then
  ok "T2b: reuse skeleton carries no skip-vocabulary (W71-safe wording)"
else
  no "T2b: skip-vocabulary leaked into the reuse skeleton" ""
fi

# T3 — tracked-file edit ⇒ different tree ⇒ MISS (fail-closed).
printf '<?php echo 2;\n' > "$REPO/app/a.php"
[ "$(run_reuse cccccccc-1dd0-4333-8333-cccccccccccc)" = "MISS" ] \
  && ok "T3: tracked-file change misses the memo (gates run for real)" \
  || no "T3: reuse fired on a CHANGED tree" "CRITICAL"
git -C "$REPO" checkout -q -- app/a.php

# T3b — UNTRACKED file ⇒ different tree ⇒ MISS (untracked coverage of the hash).
printf 'x\n' > "$REPO/app/new-untracked.php"
[ "$(run_reuse dddddddd-1dd0-4444-8444-dddddddddddd)" = "MISS" ] \
  && ok "T3b: untracked new file misses the memo (hash covers untracked)" \
  || no "T3b: reuse fired despite an untracked new file" "CRITICAL"
rm -f "$REPO/app/new-untracked.php"

# T4 — field-tampered memo (EPOCH backdated 100s: a DIFFERENT signed-field value, still inside
# the TTL — only the HMAC can catch it) ⇒ MISS.
cp "$MEMO" "$TMP/memo.orig"
_t4_epoch="$(( $(date +%s) - 100 ))"
sed -i '' -e "s/^EPOCH=.*/EPOCH=${_t4_epoch}/" "$MEMO" 2>/dev/null || sed -i -e "s/^EPOCH=.*/EPOCH=${_t4_epoch}/" "$MEMO"
_t4_a="$(run_reuse eeeeeeee-1dd0-4555-8555-eeeeeeeeeeee)"
cp "$TMP/memo.orig" "$MEMO"
[ "$_t4_a" = "MISS" ] \
  && ok "T4: EPOCH-tampered memo fails HMAC verification (no laundering via field edits)" \
  || no "T4: tampered memo was ACCEPTED" "CRITICAL"

# T5 — TTL expiry: age the memo past a 1-second TTL (2s wait keeps the HMAC intact — the memo
# is legitimately signed, just old) ⇒ MISS.
sleep 2
[ "$(run_reuse ffffffff-1dd0-4666-8666-ffffffffffff 'V_GATES_DEDUP_TTL_SEC=1')" = "MISS" ] \
  && ok "T5: TTL-expired memo is not reused" \
  || no "T5: expired memo reused" ""

# T6 — opt-out: V_GATES_DEDUP=0 disables reuse even with a valid memo.
[ "$(run_reuse 99999999-1dd0-4777-8777-999999999999 'V_GATES_DEDUP=0')" = "MISS" ] \
  && ok "T6: V_GATES_DEDUP=0 forces a fresh run" \
  || no "T6: opt-out ignored" ""

# T7 — a FAILING run must never write a memo.
rm -f "$MEMO" "$REPO/.v/artifacts/gates-green-memo-summary.txt" "$REPO/.v/artifacts/gates-green-memo-skeleton.md"
run_write "88888888-1dd0-4888-8888-888888888888" 'ALL_PASS=0'
[ ! -f "$MEMO" ] \
  && ok "T7: ALL_PASS=0 writes no memo (only strictly-green runs are reusable)" \
  || no "T7: a FAILING run wrote a memo" "CRITICAL"

# T8 — postmerge lane: never reused, never memoized.
run_write "77777777-1dd0-4999-8999-777777777777"   # re-seed a valid memo
[ "$(run_reuse 66666666-1dd0-4aaa-8aaa-666666666666 'POSTMERGE_REVERIFY=1')" = "MISS" ] \
  && ok "T8: POSTMERGE_REVERIFY=1 never reuses (combined-state verify always runs)" \
  || no "T8: postmerge re-verify was deduped away" "CRITICAL"
rm -f "$MEMO"
run_write "55555555-1dd0-4bbb-8bbb-555555555555" '_GATE_SUFFIX=-postmerge'
[ ! -f "$MEMO" ] \
  && ok "T8b: -postmerge run writes no memo" \
  || no "T8b: postmerge run memoized" ""

# T10 — a TRACKED symlink escaping the hash's coverage (target under .v/) blocks memo write.
rm -f "$MEMO"
( cd "$REPO" && mkdir -p .v/tmp && printf 'ext\n' > .v/tmp/ext.txt \
  && ln -s .v/tmp/ext.txt escaped-link && git add escaped-link && git commit -qm symlink ) >/dev/null 2>&1
run_write "44444444-1dd0-4ccc-8ccc-444444444444"
if [ ! -f "$MEMO" ] && grep -q 'tracked symlink escaping' "$TMP/werr.44444444-1dd0-4ccc-8ccc-444444444444" 2>/dev/null; then
  ok "T10: tracked symlink into .v/ blocks the memo (verdict never binds to unseen state)"
else
  no "T10: symlink-escape repo was memoized" "CRITICAL"
fi
( cd "$REPO" && git rm -q escaped-link && git commit -qm rm-symlink ) >/dev/null 2>&1

# T10b — a malformed skeleton (no Mode: line) is never signed into a memo.
rm -f "$MEMO"
S10B="33333333-1dd0-4ddd-8ddd-333333333333"
run_write "$S10B"   # writes valid fixtures first...
rm -f "$MEMO"
printf 'no mode line here\nOverall Status: PASS\n' > "$REPO/.v/tmp/pre-flight-skeleton-${S10B}.md"
( cd "$REPO" || exit 9
  set +eu
  HOME="$HOMEDIR"; export HOME
  PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0; _GATE_SUFFIX=""
  V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$REPO/.v/tmp"; SESSION_ID="$S10B"; PROJECT_ROOT="$REPO"
  TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
  PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
  ALL_PASS=1; PREFLIGHT_BLIND=0; TREE_MISMATCH=0
  SUMMARY_FILE="$REPO/.v/tmp/gate-summary-${S10B}.txt"
  SKELETON_FILE="$REPO/.v/tmp/pre-flight-skeleton-${S10B}.md"
  eval "$REUSE" >/dev/null
  eval "$WRITE"
) >/dev/null 2>"$TMP/werr10b"
[ ! -f "$MEMO" ] \
  && ok "T10b: skeleton without a Mode: line is never signed into a memo" \
  || no "T10b: malformed skeleton memoized" ""
run_write "22222222-1dd0-4eee-8eee-222222222222"   # restore a valid memo for any later cases

# T9 — the reuse wording survives the REAL Stop hook (CRA W71 scanner + verdict gates).
if [ -f "$CRA" ] && command -v jq >/dev/null 2>&1; then
  H9="$TMP/home9"; R9="$TMP/repo9"; mkdir -p "$H9/.claude/projects/p" "$R9"
  ln -s "$HOME/.claude/hooks" "$H9/.claude/hooks" 2>/dev/null
  ( cd "$R9" && git init -q && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
  : > "$H9/.claude/history.jsonl"
  G9="$(cd "$R9" && git rev-parse --git-common-dir)"; case "$G9" in /*) ;; *) G9="$R9/$G9";; esac
  S9="12345678-1dd0-4ccc-8ccc-123456789012"
  printf '{"sessionId":"%s","display":"/v X"}\n' "$S9" >> "$H9/.claude/history.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"/v X"}}\n' > "$H9/.claude/projects/p/${S9}.jsonl"
  printf 'app/Services/Foo.php\n' > "$G9/claude-session-writes-${S9}.txt"
  {
    printf 'Model: haiku\nSID: %s\nMode: full\n' "$S9"
    printf 'Reuse: tree-hash dedup — the working tree (git tree 0123abc) is content-identical to the tree that already passed this FULL gate run at 2026-07-09T00:00:00Z (sid aaaa); gate results carried over verbatim. Force a fresh run with V_GATES_DEDUP=0.\n\n'
    printf '## Gates\n\n| Status | Gate | Notes |\n| --- | --- | --- |\n'
    printf '| PASS | TypeScript | 1s |\n| PASS | Lint | 1s |\n| PASS | Build | 1s |\n| PASS | PHP Tests | 1s |\n| PASS | JS Tests | 1s |\n\n'
    printf 'Overall Status: PASS\n'
  } > "$R9/PRE_FLIGHT_REPORT_${S9}.md"
  ( cd "$R9" && printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$S9" "$H9/.claude/projects/p/${S9}.jsonl" "$R9" \
    | HOME="$H9" CLAUDE_SESSION_ID="$S9" CLAUDE_CODE_SESSION_ID="$S9" bash "$CRA" ) > "$TMP/out9" 2>&1
  if grep -qF 'skipped the FULL TEST SUITE for time/budget reasons' "$TMP/out9" \
     || grep -qF 'own verdict is FAIL/BLOCK' "$TMP/out9"; then
    no "T9: CRA blocked the reuse wording (W71/verdict false positive)" "$(grep -m1 '❌' "$TMP/out9" | cut -c1-90)"
  else
    ok "T9: real CRA does not block a PRE_FLIGHT_REPORT carrying the reuse line"
  fi
else
  echo "  --  T9 skipped (CRA or jq unavailable)"
fi

# === F6 (2026-08-29) :: TREEDEDUP-SCOPE — extends the memo to cover PFM=scoped runs ===
# MODE + SCOPE_DIGEST are now inside the signed canonical on both sign/verify sides, and a scoped
# memo lives at a distinct filename (gates-green-memo-scoped.*) from the full memo. F6-2/F6-4 hold
# the tree hash constant across a write/reuse pair and vary exactly one input (BASE_SHA_FOR_DIFF
# or a tracked file's content) to prove the memo binds to the RIGHT thing.
echo ""
echo "== F6 :: TREEDEDUP-SCOPE (scoped-mode dedup) =="
git -C "$REPO" reset -q --hard >/dev/null 2>&1
git -C "$REPO" clean -qfd >/dev/null 2>&1
mkdir -p "$REPO/.v/artifacts" "$REPO/.v/tmp"
rm -f "$MEMO" "$MEMO_SCOPED"

# ── F6 ANTI-VACUITY HELPER (close-out audit, 2026-08-29) ────────────────────────────────────
# EVERY negative F6 case asserts `= "MISS"`. A MISS is ALSO what you get when no memo exists at
# all, so a MISS-only assertion passes vacuously the moment `run_write` silently fails. Proven, not
# theorised: running this harness with V_RUNGATES_OVERRIDE pointed at the pre-F6 .bak produced
# `cp: .../gates-green-memo-scoped.txt: No such file or directory` and F6-2/3/4/5/6/8 still printed
# `ok`. That is the tree's own "verify the verifier" class — a broken check returning a confident
# WRONG answer at exit 0. `need_memo` makes each negative case state the precondition its MISS is
# supposed to be attributable to, so an absent memo fails LOUDLY instead of masquerading as a pass.
need_memo() {  # <memo-path> <case-label>
  [ -f "$1" ] && return 0
  no "$2 SETUP: expected memo $(basename "$1") was NOT written — the MISS below would be VACUOUS" "CRITICAL"
  return 1
}

# F6-1 — two scoped runs, identical tree + identical in-scope file set ⇒ second REUSES.
printf 's1\n' > "$REPO/app/f6-s1.php"; git -C "$REPO" add app/f6-s1.php >/dev/null 2>&1
run_write "f6000001-1dd0-4000-8000-f60000000001" 'PFM=scoped'
S612="f6000001-1dd0-4000-8000-f60000000012"
if [ -f "$MEMO_SCOPED" ] && [ "$(run_reuse "$S612" 'PFM=scoped')" = "HIT" ] \
   && grep -q '^TREEDEDUP=1$' "$REPO/.v/tmp/gate-summary-${S612}.txt" 2>/dev/null; then
  ok "F6-1: two scoped runs, identical tree+scope ⇒ second reuses"
else
  no "F6-1: scoped reuse did not fire on identical tree+scope" "$(tail -2 "$TMP/err.$S612" 2>/dev/null | head -1)"
fi

# F6-1b — the reuse HIT must report the REAL mode (never a hardcoded "full").
if grep -q '^Mode: scoped$' "$REPO/.v/tmp/pre-flight-skeleton-${S612}.md" 2>/dev/null \
   && grep -q 'PFM=scoped' "$REPO/.v/tmp/gate-iterations-${S612}.txt" 2>/dev/null \
   && ! grep -q 'PFM=full' "$REPO/.v/tmp/gate-iterations-${S612}.txt" 2>/dev/null; then
  ok "F6-1b: scoped reuse HIT reports Mode: scoped / PFM=scoped (never hardcoded full)"
else
  no "F6-1b: scoped reuse mislabeled as full" "$(cat "$REPO/.v/tmp/gate-iterations-${S612}.txt" 2>/dev/null)"
fi

# F6-2 — identical tree, DIFFERENT in-scope file set (BASE_SHA_FOR_DIFF moved between dispatches
# of the SAME session — the exact forensic scenario F6 exists for) ⇒ no reuse, even though the
# tree hash (HEAD + working tree content) never changed between the write and the reuse attempt.
git -C "$REPO" reset -q --hard >/dev/null 2>&1
git -C "$REPO" clean -qfd >/dev/null 2>&1
mkdir -p "$REPO/.v/artifacts" "$REPO/.v/tmp"
rm -f "$MEMO" "$MEMO_SCOPED"
( cd "$REPO" && printf 'a\n' > app/f6-base.php && git add -A && git commit -qm f6-c1 ) >/dev/null 2>&1
C1="$(git -C "$REPO" rev-parse HEAD)"
( cd "$REPO" && printf 'b\n' > app/f6-later.php && git add -A && git commit -qm f6-c2 ) >/dev/null 2>&1
run_write "f6000002-1dd0-4000-8000-f60000000021" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1"
S622="f6000002-1dd0-4000-8000-f60000000022"
need_memo "$MEMO_SCOPED" "F6-2"
RES622="$(run_reuse "$S622" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1~1")"
[ "$RES622" = "MISS" ] \
  && ok "F6-2: same tree, different BASE_SHA_FOR_DIFF (different in-scope set) ⇒ no reuse" \
  || no "F6-2: scoped reuse fired despite a different in-scope file set" "CRITICAL"

# F6-3 — a FULL memo must never satisfy a SCOPED request, and the reverse.
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000003-1dd0-4000-8000-f60000000031" 'PFM=full'
S632="f6000003-1dd0-4000-8000-f60000000032"
need_memo "$MEMO" "F6-3a"
RES632="$(run_reuse "$S632" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1")"
[ "$RES632" = "MISS" ] \
  && ok "F6-3a: a FULL memo does not satisfy a SCOPED request" \
  || no "F6-3a: scoped request reused a FULL memo" "CRITICAL"
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000003-1dd0-4000-8000-f60000000033" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1"
S634="f6000003-1dd0-4000-8000-f60000000034"
need_memo "$MEMO_SCOPED" "F6-3b"
RES634="$(run_reuse "$S634" 'PFM=full')"
[ "$RES634" = "MISS" ] \
  && ok "F6-3b: a SCOPED memo does not satisfy a FULL request" \
  || no "F6-3b: full request reused a SCOPED memo" "CRITICAL"

# F6-4 — tracked-file content change (tree hash moves) ⇒ no reuse in scoped mode either.
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000004-1dd0-4000-8000-f60000000041" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1"
printf 'changed\n' > "$REPO/app/f6-later.php"
S642="f6000004-1dd0-4000-8000-f60000000042"
need_memo "$MEMO_SCOPED" "F6-4"
RES642="$(run_reuse "$S642" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1")"
git -C "$REPO" checkout -q -- app/f6-later.php
[ "$RES642" = "MISS" ] \
  && ok "F6-4: tracked-file change under scoped mode misses the memo" \
  || no "F6-4: scoped reuse fired on a CHANGED tree" "CRITICAL"

# F6-5 — TTL expiry applies identically to a scoped memo.
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000005-1dd0-4000-8000-f60000000051" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1"
sleep 2
S652="f6000005-1dd0-4000-8000-f60000000052"
need_memo "$MEMO_SCOPED" "F6-5"
RES652="$(run_reuse "$S652" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1" 'V_GATES_DEDUP_TTL_SEC=1')"
[ "$RES652" = "MISS" ] \
  && ok "F6-5: TTL-expired SCOPED memo is not reused" \
  || no "F6-5: expired scoped memo reused" ""

# F6-6 — tampered SCOPE_DIGEST field (flipped) fails HMAC verification ⇒ no reuse (fail-closed;
# a hand-edited scope digest can never unlock a reuse it did not earn).
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000006-1dd0-4000-8000-f60000000061" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1"
cp "$MEMO_SCOPED" "$TMP/memo_scoped.orig"
# POSITIVE CONTROL (close-out audit, 2026-08-29). Without this, F6-6 was VACUOUS: it asserted only
# that a tampered memo yields MISS, and MISS is exactly what you get when there is NO memo at all.
# If run_write had silently failed, the CRITICAL-marked assertion guarding F6's core security
# property (SCOPE_DIGEST inside the HMAC canonical) would have passed while proving nothing.
# Prove the memo is REUSABLE first, so the MISS below is attributable to the tamper and nothing else.
[ -f "$MEMO_SCOPED" ] \
  && ok "F6-6a: scoped memo was actually written (precondition for the tamper test)" \
  || no "F6-6a: no scoped memo written — F6-6 below would pass VACUOUSLY" "CRITICAL"
RES661="$(run_reuse "f6000006-1dd0-4000-8000-f60000000060" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1")"
[ "$RES661" = "HIT" ] \
  && ok "F6-6b: UNtampered scoped memo REUSES (positive control — the MISS below is the tamper, not an absent memo)" \
  || no "F6-6b: untampered scoped memo did not reuse (got '$RES661') — F6-6 cannot attribute its MISS to the tamper" "CRITICAL"
_f66_orig="$(sed -n 's/^SCOPE_DIGEST=//p' "$MEMO_SCOPED")"
_f66_flip="$(printf '%s' "$_f66_orig" | sed 's/^./0/')"
[ "$_f66_flip" = "$_f66_orig" ] && _f66_flip="${_f66_orig}0"
[ "$_f66_flip" != "$_f66_orig" ] \
  && ok "F6-6c: the tamper actually changed SCOPE_DIGEST (a no-op flip would pass vacuously too)" \
  || no "F6-6c: tamper was a NO-OP — F6-6 proves nothing" "CRITICAL"
sed -i '' -e "s/^SCOPE_DIGEST=.*/SCOPE_DIGEST=${_f66_flip}/" "$MEMO_SCOPED" 2>/dev/null \
  || sed -i -e "s/^SCOPE_DIGEST=.*/SCOPE_DIGEST=${_f66_flip}/" "$MEMO_SCOPED"
S662="f6000006-1dd0-4000-8000-f60000000062"
RES662="$(run_reuse "$S662" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1")"
cp "$TMP/memo_scoped.orig" "$MEMO_SCOPED"
[ "$RES662" = "MISS" ] \
  && ok "F6-6: SCOPE_DIGEST-tampered memo fails HMAC verification (fail-closed)" \
  || no "F6-6: tampered SCOPE_DIGEST was ACCEPTED" "CRITICAL"

# F6-7 — POSTMERGE_REVERIFY=1 / V_REVERIFY_FULL=1 never reuse, even under scoped mode.
need_memo "$MEMO_SCOPED" "F6-7"
RES672="$(run_reuse "f6000007-1dd0-4000-8000-f60000000072" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1" 'POSTMERGE_REVERIFY=1')"
[ "$RES672" = "MISS" ] \
  && ok "F6-7a: POSTMERGE_REVERIFY=1 never reuses a scoped memo" \
  || no "F6-7a: postmerge re-verify deduped a scoped run away" "CRITICAL"
RES673="$(run_reuse "f6000007-1dd0-4000-8000-f60000000073" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1" 'V_REVERIFY_FULL=1')"
[ "$RES673" = "MISS" ] \
  && ok "F6-7b: V_REVERIFY_FULL=1 never reuses a scoped memo" \
  || no "F6-7b: V_REVERIFY_FULL=1 deduped a scoped run away" "CRITICAL"

# F6-8 — V_GATES_DEDUP=0 disables scoped reuse too.
need_memo "$MEMO_SCOPED" "F6-8"
RES68="$(run_reuse "f6000008-1dd0-4000-8000-f60000000081" 'PFM=scoped' "BASE_SHA_FOR_DIFF=$C1" 'V_GATES_DEDUP=0')"
[ "$RES68" = "MISS" ] \
  && ok "F6-8: V_GATES_DEDUP=0 forces a fresh run in scoped mode too" \
  || no "F6-8: opt-out ignored in scoped mode" ""

# F6-9 — a scoped memo is never written on a FAILING or -postmerge run (mirrors T7/T8b for the
# full lane, now proven for the scoped lane too).
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000009-1dd0-4000-8000-f60000000091" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1" 'ALL_PASS=0'
[ ! -f "$MEMO_SCOPED" ] \
  && ok "F6-9a: ALL_PASS=0 writes no scoped memo" \
  || no "F6-9a: a FAILING scoped run wrote a memo" "CRITICAL"
run_write "f6000009-1dd0-4000-8000-f60000000092" "PFM=scoped" "BASE_SHA_FOR_DIFF=$C1" '_GATE_SUFFIX=-postmerge'
[ ! -f "$MEMO_SCOPED" ] \
  && ok "F6-9b: -postmerge scoped run writes no memo" \
  || no "F6-9b: postmerge scoped run memoized" ""

# F6-10 — the full-mode memo's filename/path stays byte-identical to the pre-F6 layout (no
# regression to the existing full-mode reuse path).
rm -f "$MEMO" "$MEMO_SCOPED"
run_write "f6000010-1dd0-4000-8000-f60000000101" 'PFM=full'
if [ -f "$REPO/.v/artifacts/gates-green-memo.txt" ] && [ ! -f "$REPO/.v/artifacts/gates-green-memo-scoped.txt" ]; then
  ok "F6-10: full-mode memo still lands at the pre-F6 filename (no regression)"
else
  no "F6-10: full-mode memo filename regressed" ""
fi

# F6-11 (hostile-review follow-up, 2026-08-29 — flagged independently by both the
# security-reviewer and logic-reviewer dispatches): TREE_HASH gets a pre/post equality recheck at
# write time, but SCOPE_DIGEST originally did not. SESSION_WRITES (one of _td_scope_list's 4
# sources) lives under .v/, which _td_tree_hash deliberately EXCLUDES — so a mutation to that log
# DURING the gate run is invisible to the tree-hash recheck. This proves the added scope-digest
# recheck (_td_w_scope1 = $_TD_SCOPE_DIGEST) closes that gap: mutate SESSION_WRITES between the
# REUSE eval (which binds the pre-run scope digest) and the WRITE eval (which now re-derives and
# compares it) and confirm no memo is written.
rm -f "$MEMO" "$MEMO_SCOPED"
SW11="$REPO/.v/tmp/session-writes-f6000011.txt"
printf 'app/f6-base.php\n' > "$SW11"
printf 'TSC_RC=0\nLINT_RC=0\nBUILD_RC=0\nPEST_RC=0\nVITEST_RC=0\nCOMPOSER_AUDIT_RC=SKIP\nNPM_AUDIT_RC=SKIP\nMODE=scoped\nDONE_AT=2026-07-09T00:00:00Z\n' > "$REPO/.v/tmp/gate-summary-f6000011.txt"
{
  printf 'Repo: %s\nHEAD: deadbeef\nMode: scoped\n## Gates\n| Status | Gate | Notes |\n|--------|------|-------|\n' "$REPO"
  printf '| PASS | TypeScript | 1s |\n| PASS | Lint | 1s |\n| PASS | Build | 1s |\n| PASS | PHP Tests | 1s |\n| PASS | JS Tests | 1s |\n\n'
  printf 'Overall Status: PASS\n'
} > "$REPO/.v/tmp/pre-flight-skeleton-f6000011.md"
( cd "$REPO" || exit 9
  set +eu
  HOME="$HOMEDIR"; export HOME
  PFM=scoped; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0; _GATE_SUFFIX=""
  V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$REPO/.v/tmp"; SESSION_ID="f6000011-1dd0-4000-8000-f60000000111"
  PROJECT_ROOT="$REPO"; BASE_SHA_FOR_DIFF="$C1"; SESSION_WRITES="$SW11"
  TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
  PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
  ALL_PASS=1; PREFLIGHT_BLIND=0; TREE_MISMATCH=0
  SUMMARY_FILE="$REPO/.v/tmp/gate-summary-f6000011.txt"
  SKELETON_FILE="$REPO/.v/tmp/pre-flight-skeleton-f6000011.md"
  eval "$REUSE" >/dev/null   # binds _TD_* incl. _TD_SCOPE_DIGEST from SW11's pre-mutation content
  # Simulate a mid-gate-run mutation to the session-writes log (a real hook/sibling appending
  # while gates are still executing) — invisible to the tree hash (SW11 lives under .v/). The
  # appended path must be one NOT already reachable via the other 3 scope sources (working tree,
  # staged, base..HEAD = C1..C2 = app/f6-later.php from F6-2) or the digest would coincidentally
  # stay unchanged and the test would pass vacuously.
  printf 'app/f6-base.php\napp/f6-mutated-scope-marker.php\n' > "$SW11"
  eval "$WRITE"
) >/dev/null 2>"$TMP/werr11"
if [ ! -f "$MEMO_SCOPED" ] && grep -q 'in-scope file set changed while the gates ran' "$TMP/werr11" 2>/dev/null; then
  ok "F6-11: mid-run SESSION_WRITES mutation (invisible to the tree hash) blocks the memo write via the scope-digest recheck"
else
  no "F6-11: mid-run scope mutation was NOT caught (memo written despite drifted scope)" "CRITICAL: $(tail -1 "$TMP/werr11" 2>/dev/null)"
fi

# === end F6 ===

# === T11 (2026-09-01) :: TREEDEDUP-IGN — a repo that GITIGNORES .v/ must still hash + memoize ===
# Cohort forensic 2026-09-01: `git add -A -- . ':(exclude).v' …` exits 1 whenever `.v` exists AND is
# gitignored (git prints "The following paths are ignored by one of your .gitignore files: .v" — the
# ignored-path check matches the exclude item literally). _td_tree_hash then returned EMPTY, both
# TREEDEDUP blocks fell through their `-n "$_TD_HASH_T0"` guards SILENTLY, and dedup was OFF in
# every repo that ignores .v/: 0 reuse hits across the whole cohort's gate summaries. Isolated
# fixture repo so the F6 state above is untouched.
echo ""
echo "== T11 :: TREEDEDUP-IGN (.v/ gitignored + present) =="
R11="$TMP/repo-ign"; mkdir -p "$R11"
( cd "$R11" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p app && printf '<?php echo 11;\n' > app/a.php && printf '.v/\n' > .gitignore \
  && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$R11/.v/artifacts" "$R11/.v/tmp"; printf 'noise\n' > "$R11/.v/artifacts/noise.txt"
if git -C "$R11" check-ignore -q .v; then ok "T11 setup: fixture repo gitignores .v/ and .v/ exists"; else no "T11 setup: fixture did not gitignore .v/" "harness bug"; fi
run_write_r11() {  # <sid>  — same as run_write but against $R11
  local sid="$1"
  printf 'TSC_RC=0\nLINT_RC=0\nBUILD_RC=0\nPEST_RC=0\nVITEST_RC=0\nCOMPOSER_AUDIT_RC=SKIP\nNPM_AUDIT_RC=SKIP\nMODE=full\nDONE_AT=2026-09-01T00:00:00Z\n' > "$R11/.v/tmp/gate-summary-${sid}.txt"
  {
    printf 'Repo: %s\nHEAD: deadbeef\nMode: full\n## Gates\n| Status | Gate | Notes |\n|--------|------|-------|\n' "$R11"
    printf '| PASS | TypeScript | 1s |\n| PASS | Lint | 1s |\n| PASS | Build | 1s |\n| PASS | PHP Tests | 1s |\n| PASS | JS Tests | 1s |\n\n'
    printf 'Overall Status: PASS\n'
  } > "$R11/.v/tmp/pre-flight-skeleton-${sid}.md"
  ( cd "$R11" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0; _GATE_SUFFIX=""
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$R11/.v/tmp"; SESSION_ID="$sid"
    PROJECT_ROOT="$R11"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    ALL_PASS=1; PREFLIGHT_BLIND=0; TREE_MISMATCH=0
    SUMMARY_FILE="$R11/.v/tmp/gate-summary-${sid}.txt"
    SKELETON_FILE="$R11/.v/tmp/pre-flight-skeleton-${sid}.md"
    eval "$REUSE" >/dev/null
    eval "$WRITE"
  ) >"$TMP/wout11.$sid" 2>"$TMP/werr11.$sid"
}
S11A="11111111-1dd0-4f11-8f11-111111111111"; S11B="11111111-1dd0-4f22-8f22-222222222222"
run_write_r11 "$S11A"
MEMO11="$R11/.v/artifacts/gates-green-memo.txt"
if [ -f "$MEMO11" ] && [ "$(sed -n 's/^SID=//p' "$MEMO11")" = "$S11A" ] && [ -n "$(sed -n 's/^TREE_HASH=//p' "$MEMO11")" ]; then
  ok "T11a: green run in a .v/-ignoring repo WRITES a signed memo (tree hash computed despite the ignored exclude path)"
else
  no "T11a: no memo written in a .v/-ignoring repo — _td_tree_hash returned empty (the silent-off class)" "CRITICAL: $(tail -1 "$TMP/werr11.$S11A" 2>/dev/null)"
fi
if grep -q 'tree hash unavailable' "$TMP/werr11.$S11A" 2>/dev/null; then
  no "T11b: runner reported the tree hash as unavailable in a healthy .v/-ignoring repo" "$(grep -m1 'tree hash unavailable' "$TMP/werr11.$S11A")"
else
  ok "T11b: no 'tree hash unavailable' diagnostic on the healthy path"
fi
_t11_hit="$( ( cd "$R11" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$R11/.v/tmp"; SESSION_ID="$S11B"
    PROJECT_ROOT="$R11"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    eval "$REUSE"
    echo "MISS" ) 2>/dev/null | grep -q '^MISS$' && echo MISS || echo HIT )"
if [ "$_t11_hit" = "HIT" ] && grep -q '^TREEDEDUP=1$' "$R11/.v/artifacts/gate-summary-${S11B}.txt" 2>/dev/null; then
  ok "T11c: identical tree + new SID in the .v/-ignoring repo REUSES the verdict (TREEDEDUP=1)"
else
  no "T11c: reuse did not fire in the .v/-ignoring repo" "result=$_t11_hit"
fi
# T11d — the ignored-.v/ artifact churn must NOT move the hash (that is the whole point of excluding it).
printf 'more noise\n' >> "$R11/.v/artifacts/noise.txt"
_t11d="$( ( cd "$R11" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$R11/.v/tmp"; SESSION_ID="11111111-1dd0-4f33-8f33-333333333333"
    PROJECT_ROOT="$R11"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    eval "$REUSE"
    echo "MISS" ) 2>/dev/null | grep -q '^MISS$' && echo MISS || echo HIT )"
[ "$_t11d" = "HIT" ] && ok "T11d: churn under the ignored .v/ does not move the tree hash (still a HIT)" || no "T11d: .v/ churn moved the hash" "result=$_t11d"
# T11e — a real tracked-file edit in the same repo still MISSES (fail-closed unchanged).
printf '<?php echo 12;\n' > "$R11/app/a.php"
_t11e="$( ( cd "$R11" || exit 9
    set +eu
    HOME="$HOMEDIR"; export HOME
    PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0
    V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$R11/.v/tmp"; SESSION_ID="11111111-1dd0-4f44-8f44-444444444444"
    PROJECT_ROOT="$R11"
    TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"
    PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
    eval "$REUSE"
    echo "MISS" ) 2>/dev/null | grep -q '^MISS$' && echo MISS || echo HIT )"
[ "$_t11e" = "MISS" ] && ok "T11e: tracked-file edit in the .v/-ignoring repo still MISSES (fail-closed intact)" || no "T11e: tracked edit reused a stale verdict" "CRITICAL"
# T11f (review PANEL-CORRECTNESS-4): an ignored .v/ that ALSO holds a tracked file. Plain
# `check-ignore` calls such a dir "not ignored" (index special case) while `git add` still errors on
# the exclude item — the memo must still be written (--no-index asks the rules, not the index).
R11F="$TMP/repo-ign-tracked"; mkdir -p "$R11F"
( cd "$R11F" && git init -q && git config user.email t@t && git config user.name t \
  && mkdir -p app .v && printf '<?php echo 1;\n' > app/a.php && printf 'keep\n' > .v/keep.txt \
  && git add -f .v/keep.txt app/a.php && printf '.v/\n' > .gitignore && git add .gitignore && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$R11F/.v/artifacts" "$R11F/.v/tmp"; printf 'noise\n' > "$R11F/.v/artifacts/noise.txt"
S11F="11111111-1dd0-4f55-8f55-555555555555"
printf 'TSC_RC=0\nLINT_RC=0\nBUILD_RC=0\nPEST_RC=0\nVITEST_RC=0\nCOMPOSER_AUDIT_RC=SKIP\nNPM_AUDIT_RC=SKIP\nMODE=full\nDONE_AT=2026-09-01T00:00:00Z\n' > "$R11F/.v/tmp/gate-summary-${S11F}.txt"
{ printf 'Repo: %s\nHEAD: deadbeef\nMode: full\n## Gates\n| Status | Gate | Notes |\n|--------|------|-------|\n' "$R11F"; printf '| PASS | TypeScript | 1s |\n| PASS | Lint | 1s |\n| PASS | Build | 1s |\n| PASS | PHP Tests | 1s |\n| PASS | JS Tests | 1s |\n\nOverall Status: PASS\n'; } > "$R11F/.v/tmp/pre-flight-skeleton-${S11F}.md"
( cd "$R11F" || exit 9
  set +eu; HOME="$HOMEDIR"; export HOME
  PFM=full; POSTMERGE_REVERIFY=0; V_REVERIFY_FULL=0; _GATE_SUFFIX=""
  V_HOOK_LIB_DIR="$REAL_LIB_DIR"; V_TMP_DIR="$R11F/.v/tmp"; SESSION_ID="$S11F"; PROJECT_ROOT="$R11F"
  TSC_CMD_DEFAULT="true"; LINT_CMD_DEFAULT="true"; BUILD_CMD_DEFAULT="true"; PEST_CMD_DEFAULT="true"; VITEST_CMD_DEFAULT="true"
  ALL_PASS=1; PREFLIGHT_BLIND=0; TREE_MISMATCH=0
  SUMMARY_FILE="$R11F/.v/tmp/gate-summary-${S11F}.txt"; SKELETON_FILE="$R11F/.v/tmp/pre-flight-skeleton-${S11F}.md"
  eval "$REUSE" >/dev/null; eval "$WRITE"
) >"$TMP/wout11f" 2>"$TMP/werr11f"
if [ "$(sed -n 's/^SID=//p' "$R11F/.v/artifacts/gates-green-memo.txt" 2>/dev/null)" = "$S11F" ]; then
  ok "T11f: ignored .v/ holding a TRACKED file still hashes + writes the memo (--no-index asks the rules, not the index)"
else
  no "T11f: no memo when the ignored .v/ holds a tracked file" "$(tail -1 "$TMP/werr11f" 2>/dev/null)"
fi
# === end T11 ===

# === T12 (2026-09-05) :: CROSS-SESSION reuse with the REAL TSC_CMD_DEFAULT ===
# Every fixture above pins TSC_CMD_DEFAULT="true", which hid the production defect: the real
# default is "npx tsc ... --tsBuildInfoFile ${V_TMP_DIR}/tsbuildinfo-${SESSION_ID}" — a per-SID
# path folded into CONFIG_HASH — so a memo written by session A could never validate in session B.
# Observed in a cohort: memos were written but never reused, even for identical-tree runs minutes apart.
# This case rebuilds the default exactly as v-run-gates.sh does (per SID) and demands a HIT.
R12="$TMP/repo12"; mkrepo_t12() { mkdir -p "$1" && ( cd "$1" && git init -q . && git config user.email t@t.local && git config user.name t && echo t12 > f && git add -A && git commit -qm i && mkdir -p .v/tmp .v/artifacts ) >/dev/null 2>&1; }
mkrepo_t12 "$R12"
S12A="f6000012-1dd0-4000-8000-f60000000121"; S12B="f6000012-1dd0-4000-8000-f60000000122"
_t12_env='TSC_INCREMENTAL_CACHE="${V_TMP_DIR}/tsbuildinfo-${SESSION_ID}"; TSC_CMD_DEFAULT="npx tsc --noEmit --incremental --tsBuildInfoFile $TSC_INCREMENTAL_CACHE"'
_t12_saved_repo="$REPO"; REPO="$R12"
run_write "$S12A" "$_t12_env"
RES12="$(run_reuse "$S12B" "$_t12_env")"
REPO="$_t12_saved_repo"
if [ -f "$R12/.v/artifacts/gates-green-memo.txt" ] && [ "$RES12" = "HIT" ]; then
  ok "T12: cross-SID reuse HITS with the REAL per-SID TSC_CMD_DEFAULT (tsbuildinfo path normalised out of CONFIG_HASH)"
else
  no "T12: cross-SID reuse MISSED with the real TSC_CMD_DEFAULT (memo=$([ -f "$R12/.v/artifacts/gates-green-memo.txt" ] && echo yes || echo no) res=$RES12) — CONFIG_HASH still embeds the session id" "$(grep -h 'TREEDEDUP' "$TMP/err.$S12B" 2>/dev/null | tail -1)"
fi
# === end T12 ===

# RED oracle — the pre-fix script has neither block.
if [ -f "$BAK" ]; then
  if [ -z "$(awk '/^# === TREEDEDUP-REUSE /,/^# === end TREEDEDUP-REUSE ===/' "$BAK")" ]; then
    ok "RED: pre-fix v-run-gates.sh has no TREEDEDUP block (identical trees always re-run — the waste class reproduced)"
  else
    no "RED: pre-fix script already contains the block — bite not isolating" ""
  fi
else
  echo "  --  RED oracle skipped ($BAK missing)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
