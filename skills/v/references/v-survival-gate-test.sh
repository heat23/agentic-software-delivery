#!/usr/bin/env bash
# v-survival-gate-test.sh — 1A survival invariant (_survival_verdict), single-sourced in validation.sh.
#
# WHY THIS HARNESS EXISTS (the anti-whack-a-mole point, 2026-06-15):
# Every wave audit found the SAME loss class (data loss / shared-tree contamination) AFTER the fact,
# because the suite tested the *detectors* (validate-log.py), never the orchestrator's live behavior.
# This is the missing LIVE-GATE test: it drives _survival_verdict — the gate both the Stop hook and the
# producer self-check now consume — and asserts it CATCHES a production silent-wipe (wrote
# source, reverted to baseline, no marker → BLOCK) while NOT false-firing on every legitimate shape
# (committed, uncommitted-present, brand-new file, worktree-held, deferred, read-only, partial).
# Run with: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash v-survival-gate-test.sh
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — got: %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/validation.sh"
[ -f "$LIB" ] || { echo "SKIP: validation.sh not found at $LIB"; exit 0; }
# shellcheck source=/dev/null
. "$LIB"
type _survival_verdict >/dev/null 2>&1 || { echo "FAIL: _survival_verdict not defined"; exit 1; }
type get_session_writes >/dev/null 2>&1 || { echo "FAIL: get_session_writes not available via validation.sh"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkrepo(){ # $1 name -> echo repo path; seeds a tracked src/app.php = "BASE"
  local R="$TMP/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q && mkdir -p src && printf 'BASE\n' > src/app.php && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$R"
}
baseline(){ ( cd "$1" && mkdir -p .v/tmp && git rev-parse HEAD > ".v/tmp/head-baseline-$2.txt" ); }
writes(){ local R="$1" sid="$2"; shift 2; printf '%s\n' "$@" > "$R/.git/claude-session-writes-$sid.txt"; }
V(){ _survival_verdict "$1" "$2"; }

# ── S1: SILENT WIPE (the canonical signature) — wrote a TRACKED file, reverted to baseline, no commit,
#        no marker. The file still EXISTS (== baseline); only the change vanished → lost.
R=$(mkrepo s1); baseline "$R" s1; writes "$R" s1 "src/app.php"
v=$(V s1 "$R"); case "$v" in lost:1:*src/app.php*) ok "S1 silent-wipe (reverted-to-baseline tracked file) -> $v";; *) no "S1 silent-wipe must BLOCK" "$v";; esac

# ── S2: legit COMMITTED — wrote + committed → ok (survives via baseline..HEAD)
R=$(mkrepo s2); baseline "$R" s2; writes "$R" s2 "src/app.php"
( cd "$R" && printf 'CHANGED\n' > src/app.php && git commit -qam change ) >/dev/null 2>&1
v=$(V s2 "$R"); [ "$v" = ok ] && ok "S2 committed change -> ok" || no "S2 committed must not fire" "$v"

# ── S3: legit UNCOMMITTED present — wrote, change still in the working tree → ok (the normal inline case)
R=$(mkrepo s3); baseline "$R" s3; writes "$R" s3 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
v=$(V s3 "$R"); [ "$v" = ok ] && ok "S3 uncommitted-present -> ok (no false-fire on normal inline)" || no "S3 uncommitted-present" "$v"

# ── S4: NEW untracked file PRESENT — created file exists → ok (existence IS survival for a new file)
R=$(mkrepo s4); baseline "$R" s4; writes "$R" s4 "src/new.ts"; printf 'export const y=1;\n' > "$R/src/new.ts"
v=$(V s4 "$R"); [ "$v" = ok ] && ok "S4 new untracked file present -> ok" || no "S4 new file present" "$v"

# ── S5: NEW file WIPED — wrote a new file that no longer exists anywhere → lost
R=$(mkrepo s5); baseline "$R" s5; writes "$R" s5 "src/new.ts"   # never created → wiped
v=$(V s5 "$R"); case "$v" in lost:1:*src/new.ts*) ok "S5 new file wiped -> $v";; *) no "S5 new-file wipe must BLOCK" "$v";; esac

# ── S6: deferred worktree (FND-3 merge-deferred marker) → skip (declared incomplete, not silent)
R=$(mkrepo s6); baseline "$R" s6; writes "$R" s6 "src/app.php"; mkdir -p "$R/.v/tmp"; printf '# FND-3 deferred\n' > "$R/.v/tmp/merge-deferred-s6.md"
v=$(V s6 "$R"); [ "$v" = "skip:declared-incomplete" ] && ok "S6 merge-deferred marker -> skip" || no "S6 deferred" "$v"

# ── S7: HANDOFF marker → skip (honest non-completion)
R=$(mkrepo s7); baseline "$R" s7; writes "$R" s7 "src/app.php"; printf '# Handoff s7\n\n%s\n' "$(printf 'x%.0s' $(seq 1 90))" > "$R/HANDOFF_s7.md"
v=$(V s7 "$R"); [ "$v" = "skip:declared-incomplete" ] && ok "S7 HANDOFF marker -> skip" || no "S7 handoff" "$v"

# ── S8: read-only / artifact-only writes → ok (no source to lose)
R=$(mkrepo s8); baseline "$R" s8; writes "$R" s8 "AUDIT_REPORT_x.md" "notes.md"
v=$(V s8 "$R"); [ "$v" = ok ] && ok "S8 artifact-only writes -> ok (read-only session)" || no "S8 read-only" "$v"

# ── S9 (FIX-7, self-audit survivor 2026-06-18): PARTIAL loss advisory is STDERR-ONLY; the STDOUT
#        verdict contract (exactly one of ok/skip:/lost:) is UNCHANGED. 2 of 3 lost (>half, not all) WITH
#        $V_SURVIVAL_PARTIAL_WARN set → stdout 'ok' AND a stderr advisory. The all-or-nothing BLOCK
#        threshold (S18) is untouched. Capture stdout/stderr separately so we can assert both channels.
R=$(mkrepo s9); baseline "$R" s9; writes "$R" s9 "src/a.ts" "src/b.ts" "src/keep.ts"; printf 'KEEP\n' > "$R/src/keep.ts"
_s9_err="$TMP/s9.err"
v=$(V_SURVIVAL_PARTIAL_WARN=1 _survival_verdict s9 "$R" 2>"$_s9_err")
_s9_advisory=$(cat "$_s9_err" 2>/dev/null)
if [ "$v" = ok ]; then ok "S9 2-of-3 lost -> stdout 'ok' (contract preserved, not 'partial-warn:')"; else no "S9 stdout verdict must stay 'ok' on partial loss" "$v"; fi
case "$_s9_advisory" in *"SURVIVAL ADVISORY (partial loss): 2/3"*) ok "S9 stderr advisory emitted (2/3) under V_SURVIVAL_PARTIAL_WARN";; *) no "S9 stderr advisory missing for 2-of-3 partial loss" "$_s9_advisory";; esac

# ── S9b (FIX-7): 1 of 3 lost (NOT >half) → NO advisory even with the flag set; stdout stays 'ok'.
R=$(mkrepo s9b); baseline "$R" s9b; writes "$R" s9b "src/app.php" "src/k1.ts" "src/k2.ts"; printf 'K1\n' > "$R/src/k1.ts"; printf 'K2\n' > "$R/src/k2.ts"
_s9b_err="$TMP/s9b.err"
v=$(V_SURVIVAL_PARTIAL_WARN=1 _survival_verdict s9b "$R" 2>"$_s9b_err")
_s9b_advisory=$(cat "$_s9b_err" 2>/dev/null)
if [ "$v" = ok ]; then ok "S9b 1-of-3 lost -> stdout 'ok'"; else no "S9b stdout must stay 'ok'" "$v"; fi
if [ -z "$_s9b_advisory" ]; then ok "S9b no advisory at-or-below half (1/3)"; else no "S9b must NOT advise at 1/3 (not >half)" "$_s9b_advisory"; fi

# ── S9c (FIX-7): advisory is OPT-IN — 2 of 3 lost WITHOUT the flag → stdout 'ok', NO stderr advisory.
R=$(mkrepo s9c); baseline "$R" s9c; writes "$R" s9c "src/a.ts" "src/b.ts" "src/keep.ts"; printf 'KEEP\n' > "$R/src/keep.ts"
_s9c_err="$TMP/s9c.err"
v=$(_survival_verdict s9c "$R" 2>"$_s9c_err")   # flag UNSET
_s9c_advisory=$(cat "$_s9c_err" 2>/dev/null)
if [ "$v" = ok ]; then ok "S9c 2-of-3 lost, flag unset -> stdout 'ok'"; else no "S9c stdout must stay 'ok'" "$v"; fi
if [ -z "$_s9c_advisory" ]; then ok "S9c no advisory when V_SURVIVAL_PARTIAL_WARN unset (opt-in)"; else no "S9c advisory must be opt-in" "$_s9c_advisory"; fi

# ── S10: no baseline → skip (FP-safe)
R=$(mkrepo s10); writes "$R" s10 "src/app.php"
v=$(V s10 "$R"); [ "$v" = "skip:no-baseline" ] && ok "S10 no baseline -> skip" || no "S10 no-baseline" "$v"

# ── S11: empty writes-log → skip (FP-safe; forked/headless runner)
R=$(mkrepo s11); baseline "$R" s11; : > "$R/.git/claude-session-writes-s11.txt"
v=$(V s11 "$R"); [ "$v" = "skip:empty-writes-log" ] && ok "S11 empty writes-log -> skip" || no "S11 empty" "$v"

# ── S12: WORKTREE branch holds the change (no marker) → ok (survives via the session worktree)
R=$(mkrepo s12); baseline "$R" s12; writes "$R" s12 "src/app.php"
( cd "$R" && git worktree add -q ".worktrees/w" -b "build/feat-s12" HEAD && \
  printf 's12 %s\n' "$(date +%s)" > ".worktrees/w/.claude-session-lock" && \
  printf 'WT_CHANGE\n' > ".worktrees/w/src/app.php" ) >/dev/null 2>&1
v=$(V s12 "$R"); [ "$v" = ok ] && ok "S12 worktree branch holds change -> ok (no false-fire on worktree sessions)" || no "S12 worktree" "$v"

# ── S13: DELETE is an intended change → ok (a deletion is a net diff vs baseline, not a wipe)
R=$(mkrepo s13); baseline "$R" s13; writes "$R" s13 "src/app.php"; ( cd "$R" && git rm -q src/app.php && git commit -qm "remove app" ) >/dev/null 2>&1
v=$(V s13 "$R"); [ "$v" = ok ] && ok "S13 intentional delete -> ok (deletion is survival)" || no "S13 delete" "$v"

# ── S14 (CDX-001): a CRLF/normalized-away change is still PRESENT-and-dirty (git status ' M') even
#        though `git diff` reports no net content change. Survival must key on the dirty TREE, not the
#        normalized diff, or it false-blocks a session whose work is sitting right there.
R=$(mkrepo s14)
( cd "$R" && printf '* text=auto\n' > .gitattributes && git add .gitattributes && git commit -qm attrs && \
  printf 'a\nb\n' > src/app.php && git add src/app.php && git commit -qm lf ) >/dev/null 2>&1
baseline "$R" s14; writes "$R" s14 "src/app.php"
printf 'a\r\nb\r\n' > "$R/src/app.php"   # CRLF rewrite — git normalizes content away, status shows ' M'
if [ -n "$(git -C "$R" status --porcelain -- src/app.php 2>/dev/null)" ]; then
  v=$(V s14 "$R"); [ "$v" = ok ] && ok "S14 CRLF/normalized dirty file -> ok (no false-block; keys on dirty tree)" || no "S14 CRLF false-block" "$v"
else
  ok "S14 skipped (this git does not surface CRLF-only change as dirty here)"   # env-dependent; never fail
fi

# ── S15 (CDX-002): TRIVIAL_PASS marker → skip (parity with the self-check's TRIVIAL bypass)
R=$(mkrepo s15); baseline "$R" s15; writes "$R" s15 "src/app.php"; printf '# trivial\n' > "$R/TRIVIAL_PASS_s15.md"
v=$(V s15 "$R"); [ "$v" = "skip:declared-incomplete" ] && ok "S15 TRIVIAL_PASS marker -> skip (gate parity)" || no "S15 TRIVIAL_PASS" "$v"

# ── S16 (CDX-002): PLANNING_PASS marker → skip
R=$(mkrepo s16); baseline "$R" s16; writes "$R" s16 "src/app.php"; printf '# planning\n' > "$R/PLANNING_PASS_s16.md"
v=$(V s16 "$R"); [ "$v" = "skip:declared-incomplete" ] && ok "S16 PLANNING_PASS marker -> skip (gate parity)" || no "S16 PLANNING_PASS" "$v"

# ── S17 (framework MEDIUM): drift guard — the survival source-ext regex must stay in lock-step with the
#        Stop hook's CODE_EXT_PATTERN (a silent divergence would misclassify source vs non-source).
CRA="$HOME/.claude/hooks/check-review-artifact.sh"
if [ -f "$CRA" ]; then
  _cra_ext=$(grep -E "^CODE_EXT_PATTERN=" "$HOME/.claude/hooks/lib/code-ext-pattern.sh" | head -1 | sed -E "s/^CODE_EXT_PATTERN='//; s/'\$//")  # ORCHFIX-C: single source = shared lib
  _sv_ext="$_SURVIVAL_CODE_EXT_RE"
  [ "$_cra_ext" = "$_sv_ext" ] && ok "S17 _SURVIVAL_CODE_EXT_RE == CODE_EXT_PATTERN (no drift)" || no "S17 CODE_EXT drift" "cra='$_cra_ext' surv='$_sv_ext'"
fi

# ── S18 (FIX-7 boundary): ALL of multiple files lost (3 of 3) → lost:3 (the BLOCK path is UNCHANGED; a
#        full wipe of >1 file must NOT downgrade to an advisory — it still emits the blocking lost: token).
R=$(mkrepo s18); baseline "$R" s18; writes "$R" s18 "src/a.ts" "src/b.ts" "src/c.ts"   # none created → all 3 lost
v=$(V s18 "$R"); case "$v" in lost:3:*) ok "S18 3-of-3 lost -> $v (full wipe still BLOCKS, not partial)";; *) no "S18 all-lost-of-multiple must emit lost:3:*" "$v";; esac

# ── S19 (forensic 2026-08-18): a HUMAN-NAMED worktree branch holds the change, with
#        NO .claude-session-lock and a branch name that does NOT end in the session ID or its 8-char
#        prefix (unlike S12, which seeds both). _survival_wt_dir finds neither signal, so it returns ""
#        and check (c) never engages — a real production false-fire: a session doing work in a worktree
#        that was created by hand (or by an earlier, unrelated part of the same conversation, for a
#        different purpose) reads every file as "lost" even though all of them are safely committed on
#        that worktree's branch. Must be "ok".
R=$(mkrepo s19); baseline "$R" s19; writes "$R" s19 "src/app.php"
( cd "$R" && git worktree add -q ".worktrees/docs-thing" -b "docs/some-human-branch-name" HEAD && \
  printf 'WT_CHANGE\n' > ".worktrees/docs-thing/src/app.php" && \
  ( cd ".worktrees/docs-thing" && git commit -qam change ) ) >/dev/null 2>&1
v=$(V s19 "$R"); [ "$v" = ok ] && ok "S19 human-named worktree branch, no lock file -> ok (no false-fire, forensic 2026-08-18)" || no "S19 unlabeled worktree" "$v"

# ── S20 (companion to S19): a human-named worktree EXISTS but does NOT hold the lost file's change —
#        the fallback that fixes S19 must not paper over a REAL loss just because some other worktree is
#        present. Must still be "lost:1:*".
R=$(mkrepo s20); baseline "$R" s20; writes "$R" s20 "src/app.php"
( cd "$R" && git worktree add -q ".worktrees/unrelated" -b "docs/unrelated-branch" HEAD ) >/dev/null 2>&1   # untouched: still == baseline
v=$(V s20 "$R"); case "$v" in lost:1:*src/app.php*) ok "S20 unrelated worktree present, file still genuinely lost -> $v";; *) no "S20 must still BLOCK (fallback must not mask a real loss)" "$v";; esac

# ── S21 (adversarial review 2026-08-18/19, follow-up to S19/S20): case (d)'s original fallback was
#        ATTRIBUTION-BLIND — trusting a dirty match in ANY other worktree, even one demonstrably
#        owned by a DIFFERENT session. A sibling worktree carries its OWN .claude-session-lock (the
#        common real-world shape for any /v-provisioned worktree) naming a DIFFERENT sid, and has
#        its OWN, unrelated, uncommitted edit to the SAME path THIS session's file was wiped from
#        (reverted to baseline, no marker — the exact S1 signature). Pre-(d2)-fix, that unrelated
#        dirty match falsely reported "ok". Must still BLOCK — the sibling's dirty state is not
#        evidence of MY session's survival.
R=$(mkrepo s21); baseline "$R" s21; writes "$R" s21 "src/app.php"   # s21's own change: never applied -> == baseline (genuinely wiped)
SIB_SID="99999999-8888-7777-6666-555555555555"
( cd "$R" && git worktree add -q ".worktrees/sibling" -b "build/sibling-thing-${SIB_SID}" HEAD ) >/dev/null 2>&1
printf '%s now\n' "$SIB_SID" > "$R/.worktrees/sibling/.claude-session-lock"
printf 'SIBLING_UNRELATED_EDIT\n' > "$R/.worktrees/sibling/src/app.php"
v=$(V s21 "$R"); case "$v" in lost:1:*src/app.php*) ok "S21 attributed sibling worktree (own lock, own unrelated edit) does NOT mask a real wipe -> $v";; *) no "S21 must still BLOCK -- an attributed sibling's dirty state must not count as MY survival" "$v";; esac

# ── S22 (companion to S21): same attribution-exclusion, but the sibling is identified via a
#        UUID-suffixed BRANCH NAME instead of a lock file (e.g. the lock was already cleaned up
#        after that session finished, branch retained) -- the SECONDARY attribution signal.
R=$(mkrepo s22); baseline "$R" s22; writes "$R" s22 "src/app.php"
SIB_SID2="88888888-7777-6666-5555-444444444444"
( cd "$R" && git worktree add -q ".worktrees/sibling2" -b "build/sibling-${SIB_SID2}" HEAD ) >/dev/null 2>&1
printf 'SIBLING_UNRELATED_EDIT\n' > "$R/.worktrees/sibling2/src/app.php"   # no lock file, UUID branch only
v=$(V s22 "$R"); case "$v" in lost:1:*src/app.php*) ok "S22 attributed sibling worktree (UUID branch, no lock, own unrelated edit) does NOT mask a real wipe -> $v";; *) no "S22 must still BLOCK -- UUID-branch attribution alone must exclude an unrelated sibling" "$v";; esac

# ── S23 (hostile-review finding, 2026-08-19): companion to S21/S22, but the sibling is identified
#        ONLY via the SHORT 8-hex-PREFIX branch-suffix form (build/<name>-<sid8>), no lock file, no
#        full UUID anywhere in the branch name. This is _survival_wt_dir's OWN secondary matching
#        form (line ~1540: `*"-${_sid:0:8}"`) and this codebase's own real fixture convention
#        (v-e2e-lifecycle-test.sh et al.) -- the first cut of the (d2) fix only matched the full-UUID
#        suffix form and still false-"ok"'d here. Must still BLOCK.
R=$(mkrepo s23); baseline "$R" s23; writes "$R" s23 "src/app.php"
SIB_SID3="77777777-6666-5555-4444-333333333333"
( cd "$R" && git worktree add -q ".worktrees/sibling3" -b "build/sibling-thing-${SIB_SID3:0:8}" HEAD ) >/dev/null 2>&1
printf 'SIBLING_UNRELATED_EDIT\n' > "$R/.worktrees/sibling3/src/app.php"   # no lock file, 8-hex-prefix branch suffix only
v=$(V s23 "$R"); case "$v" in lost:1:*src/app.php*) ok "S23 attributed sibling worktree (8-hex-prefix branch only, no lock, own unrelated edit) does NOT mask a real wipe -> $v";; *) no "S23 must still BLOCK -- short-prefix-branch attribution alone must exclude an unrelated sibling (hostile-review finding)" "$v";; esac

# ── S24 (negative control, companion to S23): MY OWN worktree is identified via a lock file
#        ("mine-lock", untouched here); a SEPARATE, different worktree ("coincidence") holds the
#        actual genuine survival edit but its branch happens to end in MY OWN 8-char sid prefix (no
#        lock file of its own). (d2)'s attribution guard must treat a short-prefix match EQUAL to my
#        own prefix as ambiguous, NOT "someone else's" -- excluding it here would wrongly turn a
#        real survival into a false "lost". Proves the guard does not introduce a new false-negative.
R=$(mkrepo s24); SID24="aaaaaaaa-1111-2222-3333-444444444444"
baseline "$R" "$SID24"; writes "$R" "$SID24" "src/app.php"
( cd "$R" && git worktree add -q ".worktrees/mine-lock" -b "docs/mine-untouched" HEAD ) >/dev/null 2>&1
printf '%s now\n' "$SID24" > "$R/.worktrees/mine-lock/.claude-session-lock"
( cd "$R" && git worktree add -q ".worktrees/coincidence" -b "build/leftover-thing-${SID24:0:8}" HEAD && \
  printf 'WT_CHANGE\n' > ".worktrees/coincidence/src/app.php" && \
  ( cd ".worktrees/coincidence" && git commit -qam change ) ) >/dev/null 2>&1
v=$(V "$SID24" "$R"); [ "$v" = ok ] && ok "S24 sibling worktree's branch coincidentally matching MY OWN short prefix is still trusted when it holds my genuine change -> $v" || no "S24 own-prefix-ambiguous sibling must not be wrongly excluded (would be a new false-negative)" "$v"

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ $FAIL -eq 0 ]
