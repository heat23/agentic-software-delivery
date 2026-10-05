#!/usr/bin/env bash
# v-exposed-inline-test.sh — 1B exposed-inline-work gate (_exposed_inline_verdict), single-sourced.
#
# Forensic 2026-06-16 (REP-008 near-miss): a Maintenance-tier session worked INLINE on shared
# main and left its source UNCOMMITTED while sibling /v sessions were active — the exact uncommitted-on-
# shared-main state a concurrent sibling's stash clobbers. The survival gate catches the WIPE;
# this gate prevents it by blocking (recoverably) on the EXPOSURE. This harness proves it FIRES on the
# exposed shape and does NOT false-fire on the safe ones (committed, worktree session, no siblings, RO).
# Run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash v-exposed-inline-test.sh
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — got: %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
# V_VALIDATION_LIB (mutation-gate seam, audit 2026-06-18): the gate injects a mutant validation.sh
# here (file-valued override, like the parity/e2e harnesses). Default (unset) → live lib via
# HOOKS_LIB_DIR, zero behavior change.
LIB="${V_VALIDATION_LIB:-${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/validation.sh}"
[ -f "$LIB" ] || { echo "SKIP: validation.sh not found"; exit 0; }
# shellcheck source=/dev/null
. "$LIB"
type _exposed_inline_verdict >/dev/null 2>&1 || { echo "FAIL: _exposed_inline_verdict not defined"; exit 1; }
[ -f "$HOME/.claude/skills/v/references/v-active-siblings.sh" ] || { echo "SKIP: v-active-siblings.sh not found"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkrepo(){ local R="$TMP/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && mkdir -p src && printf 'BASE\n' > src/app.php && git add -A && git commit -qm init ) >/dev/null 2>&1; printf '%s' "$R"; }
writes(){ local R="$1" sid="$2"; shift 2; printf '%s\n' "$@" > "$R/.git/claude-session-writes-$sid.txt"; }
add_sibling(){ mkdir -p "$1/.worktrees/$2"; printf '%s %s\n' "$2" "$(date +%s)" > "$1/.worktrees/$2/.claude-session-lock"; }   # fresh sibling lock
V(){ _exposed_inline_verdict "$1" "$2"; }

# E1: inline + active sibling + UNCOMMITTED source → exposed (the REP-008 case)
R=$(mkrepo e1); add_sibling "$R" sibaaaa; writes "$R" e1 "src/app.php"; printf 'WIP_UNCOMMITTED\n' > "$R/src/app.php"
v=$(V e1 "$R"); case "$v" in exposed:1:*src/app.php*) ok "E1 inline + active sibling + uncommitted -> $v";; *) no "E1 must flag exposed" "$v";; esac

# E2: inline + active sibling + COMMITTED source → ok (committed = clean porcelain = not exposed = the recovery)
R=$(mkrepo e2); add_sibling "$R" sibbbbb; writes "$R" e2 "src/app.php"; ( cd "$R" && printf 'FIXED\n' > src/app.php && git commit -qam fix ) >/dev/null 2>&1
v=$(V e2 "$R"); [ "$v" = ok ] && ok "E2 committed source -> ok (the recovery: commit clears it)" || no "E2 committed not exposed" "$v"

# E3: inline + NO active sibling → skip (solo: the user's review-first '/commit when ready' flow is safe)
R=$(mkrepo e3); writes "$R" e3 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
v=$(V e3 "$R"); [ "$v" = "skip:no-active-siblings" ] && ok "E3 no active sibling -> skip (solo flow safe; no false-block)" || no "E3 no-siblings" "$v"

# E4: WORKTREE session (own lock) + active sibling → skip (work lives on the branch, not main's tree)
R=$(mkrepo e4); add_sibling "$R" sibcccc
( cd "$R" && git worktree add -q .worktrees/own -b build/own-e4 HEAD ) >/dev/null 2>&1
printf 'e4 %s\n' "$(date +%s)" > "$R/.worktrees/own/.claude-session-lock"
writes "$R" e4 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
v=$(V e4 "$R"); [ "$v" = "skip:worktree" ] && ok "E4 worktree session -> skip (isolated; no false-block)" || no "E4 worktree" "$v"

# E5: inline + sibling + artifact-only writes → ok (no source to expose)
R=$(mkrepo e5); add_sibling "$R" sibdddd; writes "$R" e5 "AUDIT_REPORT_x.md" "notes.md"
v=$(V e5 "$R"); [ "$v" = ok ] && ok "E5 artifact-only writes -> ok (read-only session)" || no "E5 read-only" "$v"

# E6: empty writes-log → skip (forked/headless runner; FP-safe)
R=$(mkrepo e6); add_sibling "$R" sibeeee; : > "$R/.git/claude-session-writes-e6.txt"
v=$(V e6 "$R"); [ "$v" = "skip:empty-writes-log" ] && ok "E6 empty writes-log -> skip" || no "E6 empty" "$v"

# E7: inline + sibling + NEW untracked source file present → exposed (untracked is also clobberable)
R=$(mkrepo e7); add_sibling "$R" sibffff; writes "$R" e7 "src/new.ts"; printf 'export const x=1;\n' > "$R/src/new.ts"
v=$(V e7 "$R"); case "$v" in exposed:1:*src/new.ts*) ok "E7 new untracked source -> $v";; *) no "E7 untracked exposed" "$v";; esac

# E8: PARTIAL — some committed, one left uncommitted → exposed on the uncommitted one (protect everything)
R=$(mkrepo e8); add_sibling "$R" sibgggg; writes "$R" e8 "src/app.php" "src/two.php"
( cd "$R" && printf 'DONE\n' > src/app.php && printf 'NEW\n' > src/two.php && git add src/two.php && git commit -qm two ) >/dev/null 2>&1
# src/two.php committed (NO -a, so app.php is NOT swept in); src/app.php left modified-uncommitted
v=$(V e8 "$R"); case "$v" in exposed:1:*src/app.php*) ok "E8 partial: one uncommitted -> exposed on it (protect all)";; *) no "E8 partial-exposed" "$v";; esac

# E9 (CDX-002): an honest incompletion declaration (HANDOFF) → skip, even with siblings + uncommitted
#     work. The orchestrator INTENTIONALLY left WIP; verdict-parity with the survival gate.
R=$(mkrepo e9); add_sibling "$R" sibhhhh; writes "$R" e9 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
printf '# Handoff e9\n\n%s\n' "$(printf 'x%.0s' $(seq 1 90))" > "$R/HANDOFF_e9.md"
v=$(V e9 "$R"); [ "$v" = "skip:declared-incomplete" ] && ok "E9 HANDOFF marker -> skip (parity with survival gate)" || no "E9 marker" "$v"

# E10 (forensic 2026-06-16): INLINE session + an INLINE sibling (NO worktree lock) +
#     uncommitted source → exposed, detected via writes-log activity OVERLAP (another session's writes-log
#     modified at/after my session start). This is the all-inline-wave case the worktree-only signal missed.
R=$(mkrepo e10); writes "$R" e10 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
mkdir -p "$R/.v/tmp"; ( cd "$R" && git rev-parse HEAD > .v/tmp/head-baseline-e10.txt )   # my session start
sleep 1
printf 'src/sibling-other.php\n' > "$R/.git/claude-session-writes-aaaa0000-1111-4222-8333-444455556666.txt"   # an INLINE sibling wrote AFTER my start
v=$(V e10 "$R"); case "$v" in exposed:1:*src/app.php*) ok "E10 inline-wave (writes-log overlap, no worktree lock) -> $v";; *) no "E10 inline-wave exposure (the all-inline-wave gap)" "$v";; esac

# E11 (FP-safety): INLINE + uncommitted source + baseline, but NO sibling wrote during my window → skip.
#     Proves the writes-log signal does not false-fire on a genuinely solo session (review-first flow kept).
R=$(mkrepo e11); printf 'src/sibling-other.php\n' > "$R/.git/claude-session-writes-bbbb0000-1111-4222-8333-444455556666.txt"   # a sibling wrote BEFORE my start
sleep 1
writes "$R" e11 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
mkdir -p "$R/.v/tmp"; ( cd "$R" && git rev-parse HEAD > .v/tmp/head-baseline-e11.txt )   # my start is AFTER the sibling's only write
v=$(V e11 "$R"); [ "$v" = "skip:no-active-siblings" ] && ok "E11 solo (sibling write predates my start) -> skip (FP-safe; review-first kept)" || no "E11 solo-FP" "$v"

# E12 (codex CDX-001 FP-guard): a sibling whose writes-log is FRESH (≥ my start) but that ALREADY
#     FINISHED (has a canonical SESSION_LOG_<sib>.yaml) is not a live clobberer → NOT counted → skip.
#     Prevents a stale prior session's touched writes-log from false-firing a genuinely-solo session.
R=$(mkrepo e12); writes "$R" e12 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
mkdir -p "$R/.v/tmp"; ( cd "$R" && git rev-parse HEAD > .v/tmp/head-baseline-e12.txt )   # my start
sleep 1
SIBDONE=cccc0000-1111-4222-8333-444455556666
printf 'src/other.php\n' > "$R/.git/claude-session-writes-$SIBDONE.txt"                 # fresh sibling writes-log
printf 'session_id: %s\n' "$SIBDONE" > "$R/SESSION_LOG_$SIBDONE.yaml"                   # ...but it FINISHED (has canonical log)
v=$(V e12 "$R"); [ "$v" = "skip:no-active-siblings" ] && ok "E12 finished sibling (has SESSION_LOG) NOT counted -> skip (CDX-001 FP-guard)" || no "E12 finished-sibling FP" "$v"

# E13 (codex CDX-004): my baseline lives in \$TMPDIR (forked/headless-runner layout), not .v/tmp —
#     _exposed_concurrency must still find it via the 4-tier path list and detect the concurrent sibling.
R=$(mkrepo e13); writes "$R" e13 "src/app.php"; printf 'WIP\n' > "$R/src/app.php"
_td=$(mktemp -d); ( cd "$R" && git rev-parse HEAD > "$_td/head-baseline-e13.txt" )      # baseline in TMPDIR only
sleep 1
printf 'src/other.php\n' > "$R/.git/claude-session-writes-dddd0000-1111-4222-8333-444455556666.txt"   # unfinished concurrent sibling
v=$(TMPDIR="$_td" V e13 "$R"); rm -rf "$_td"
case "$v" in exposed:1:*src/app.php*) ok "E13 baseline in \$TMPDIR (forked-runner) still covered -> $v (CDX-004)";; *) no "E13 TMPDIR baseline coverage" "$v";; esac

# E14 (forensic 2026-06-19): a dependency MANIFEST (composer.json) left UNCOMMITTED on shared main with
# an active sibling is EXPOSED — a session left composer.json/lock dirty on main, deadlocking FOUR
# concurrent worktree merge-backs (FND-3 deferred over the foreign WIP rather than stash it → all four
# stranded). Manifests are now in _SURVIVAL_DEP_MANIFEST_RE, so the inline session is forced to commit.
R=$(mkrepo e14); add_sibling "$R" sibe14
( cd "$R" && printf 'v1\n' > composer.json && git add composer.json && git commit -qm dep ) >/dev/null 2>&1
writes "$R" e14 "composer.json"; printf 'v2-uncommitted\n' > "$R/composer.json"
v=$(V e14 "$R")
case "$v" in exposed:1:*composer.json*) ok "E14 uncommitted composer.json + active sibling -> exposed (manifest in scope)";; *) no "E14 dependency manifest not flagged exposed (the manifest-dirty merge-back deadlock)" "$v";; esac

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ $FAIL -eq 0 ]
