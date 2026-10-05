#!/usr/bin/env bash
# block-cross-session-add-test.sh — exhaustive test for the commit-theft PreToolUse gate.
# A false DENY blocks legitimate commits (a regression the operator will not tolerate), so the FP-safe
# paths are tested as hard as the true-positive. Run: bash block-cross-session-add-test.sh
set -u
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/block-cross-session-add.sh"
[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkrepo(){ local R="$TMP/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && printf 'base\n' > app.php && printf 'base\n' > other.php && git add -A && git commit -qm init ) >/dev/null 2>&1; printf '%s' "$R"; }
wlog(){ local R="$1" sid="$2"; shift 2; printf '%s\n' "$@" > "$R/.git/claude-session-writes-$sid.txt"; }   # git-common-dir = R/.git
# run the hook FROM the repo (it resolves repo via CWD), with a given SID + command
run(){ local repo="$1" sid="$2" cmd="$3"; ( cd "$repo" && printf '%s' "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')" | CLAUDE_SESSION_ID="$sid" CLAUDE_CODE_SESSION_ID="$sid" HOOKS_LIB_DIR="$HOME/.claude/hooks/lib" bash "$HOOK" 2>/dev/null ); }
denied(){ printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

MYSID=aaaa1111-1111-4111-8111-aaaaaaaaaaaa
SIB=bbbb2222-2222-4222-8222-bbbbbbbbbbbb

# T1: sweep `git add -A` + a sibling's DIRTY file (not mine) → DENY
R=$(mkrepo t1); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"
( cd "$R" && printf 'sibling-wip\n' > other.php )           # sibling's file dirty in my tree
out=$(run "$R" "$MYSID" "git add -A"); denied "$out" && ok "T1 git add -A swallows sibling's dirty file -> DENY" || no "T1 should DENY" "$out"

# T2: scoped `git add app.php` → ALLOW (not a sweep)
out=$(run "$R" "$MYSID" "git add app.php"); denied "$out" && no "T2 scoped add wrongly DENIED" "$out" || ok "T2 scoped 'git add <file>' -> allow"

# T3: `git commit -m msg` (no -a) → ALLOW (commits only staged)
out=$(run "$R" "$MYSID" 'git commit -m "fix"'); denied "$out" && no "T3 'commit -m' wrongly DENIED" "$out" || ok "T3 'git commit -m' (no -a) -> allow"

# T4: `git commit -am msg` + sibling's dirty file → DENY
out=$(run "$R" "$MYSID" 'git commit -am "fix"'); denied "$out" && ok "T4 'git commit -am' swallows sibling file -> DENY" || no "T4 should DENY" "$out"

# T5: sweep `git add -A` but ONLY my own file is dirty → ALLOW (no sibling file in tree)
R=$(mkrepo t5); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"
( cd "$R" && printf 'my-wip\n' > app.php )                  # only MY file dirty
out=$(run "$R" "$MYSID" "git add -A"); denied "$out" && no "T5 -A on only-my-files wrongly DENIED" "$out" || ok "T5 -A, only my files dirty -> allow (no false-block)"

# T6: sweep + sibling's dirty file BUT sibling FINISHED (has canonical SESSION_LOG) → ALLOW
R=$(mkrepo t6); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"
( cd "$R" && printf 'sib\n' > other.php ); printf 'session_id: %s\n' "$SIB" > "$R/SESSION_LOG_$SIB.yaml"
out=$(run "$R" "$MYSID" "git add -A"); denied "$out" && no "T6 finished-sibling wrongly DENIED" "$out" || ok "T6 -A, sibling FINISHED (logged) -> allow"

# T7: sweep in a WORKTREE (isolated) → ALLOW
R=$(mkrepo t7); wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
( cd "$R" && git worktree add -q .worktrees/w -b build/w HEAD ) >/dev/null 2>&1
out=$(run "$R/.worktrees/w" "$MYSID" "git add -A"); denied "$out" && no "T7 worktree session wrongly DENIED" "$out" || ok "T7 -A in a worktree (isolated) -> allow"

# T8: sweep + SOLO (no sibling writes-log) → ALLOW
R=$(mkrepo t8); wlog "$R" "$MYSID" "app.php"; ( cd "$R" && printf 'my\n' > app.php )
out=$(run "$R" "$MYSID" "git add -A"); denied "$out" && no "T8 solo wrongly DENIED" "$out" || ok "T8 -A, solo (no sibling) -> allow (review-first kept)"

# T9: `git commit --amend` (no -a) → ALLOW (amend is not a sweep)
R=$(mkrepo t9); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" 'git commit --amend --no-edit'); denied "$out" && no "T9 '--amend' wrongly DENIED" "$out" || ok "T9 'git commit --amend' (no -a) -> allow"

# T10: hot-file overlap — sibling's file is ALSO in MY writes-log → ALLOW (not pure theft)
R=$(mkrepo t10); wlog "$R" "$MYSID" "app.php" "other.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'x\n' > other.php )
out=$(run "$R" "$MYSID" "git add -A"); denied "$out" && no "T10 hot-file (also mine) wrongly DENIED" "$out" || ok "T10 file in BOTH logs (overlap) -> allow (not pure theft)"

# T11: `git add .` + sibling's dirty file → DENY
R=$(mkrepo t11); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" "git add ."); denied "$out" && ok "T11 'git add .' swallows sibling file -> DENY" || no "T11 should DENY" "$out"

# T12: non-Bash / malformed input → ALLOW (fail-open)
out=$( printf '%s' '{"tool_name":"Read","tool_input":{}}' | CLAUDE_SESSION_ID="$MYSID" bash "$HOOK" 2>/dev/null )
denied "$out" && no "T12 non-Bash wrongly DENIED" "$out" || ok "T12 non-Bash tool -> allow (exit 0)"
out=$( printf '%s' 'not json' | bash "$HOOK" 2>/dev/null ); denied "$out" && no "T12b malformed wrongly DENIED" "$out" || ok "T12b malformed input -> allow (fail-open)"

# T13: `git status` (contains 'git' but not a sweep) → ALLOW
R=$(mkrepo t13); wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" "git status; ls -A"); denied "$out" && no "T13 'git status; ls -A' wrongly DENIED" "$out" || ok "T13 'git status; ls -A' (no sweep) -> allow"

# ── CODEX round (1.1.0): the three false-deny vectors a false DENY = regression ──────────────────────

# T14 (CODEX-001): sibling owns an UNTRACKED file. `git commit -a` CANNOT stage untracked → must ALLOW;
#     but `git add -A` DOES stage untracked → must still DENY. The asymmetry the reviewer flagged.
R=$(mkrepo t14); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "sib_new.php"
( cd "$R" && printf 'mine\n' > app.php && printf 'sibling-untracked\n' > sib_new.php )   # sib_new.php is ?? (untracked)
out=$(run "$R" "$MYSID" 'git commit -am "fix"'); denied "$out" && no "T14a 'commit -am' wrongly DENIED for UNTRACKED sibling file (commit -a never stages it)" "$out" || ok "T14a commit -a + untracked sibling file -> allow (CODEX-001)"
out=$(run "$R" "$MYSID" 'git add -A');           denied "$out" && ok "T14b 'git add -A' DOES stage untracked sibling file -> DENY (CODEX-001 asymmetry)" || no "T14b add -A untracked sibling should DENY" "$out"
# T14c: sibling owns a TRACKED-modified file + `git commit -am` → still DENY (commit -a DOES stage it).
R=$(mkrepo t14c); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'mine\n' > app.php && printf 'sib-mod\n' > other.php )
out=$(run "$R" "$MYSID" 'git commit -am "fix"'); denied "$out" && ok "T14c commit -a + TRACKED-modified sibling file -> DENY (still caught)" || no "T14c tracked sibling commit -a should DENY" "$out"

# T15 (CODEX-002): a commit MESSAGE containing a flag-like token must NOT trigger the sweep regex.
R=$(mkrepo t15); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" 'git commit -m "document the -all flag behavior"'); denied "$out" && no "T15a 'commit -m \"...-all...\"' wrongly DENIED (message, not flag)" "$out" || ok "T15a commit -m message contains '-all' -> allow (CODEX-002)"
out=$(run "$R" "$MYSID" 'git commit -m "add -A support and -amend handling"'); denied "$out" && no "T15b 'commit -m \"...add -A...\"' wrongly DENIED (message, not flag)" "$out" || ok "T15b commit -m message contains 'add -A' -> allow (CODEX-002 add-regex analogue)"
out=$(run "$R" "$MYSID" 'git commit -am "add -all support"');                  denied "$out" && ok "T15c real 'commit -am' (flag outside quotes) -> still DENY" || no "T15c real commit -am should DENY despite quoted msg" "$out"

# T16 (CODEX-003): unset SID + no runtime file → cannot identify 'mine' → fail-open (ALLOW), even with a
#     sibling's dirty file present. Without this the headless runner (where /v does its merge `git add`)
#     would flag its OWN files as a sibling's. Runtime file is redirected to an empty dir to be sure.
R=$(mkrepo t16); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
EMPTYHOME="$TMP/nohome16"; mkdir -p "$EMPTYHOME/.claude/runtime"
out=$( cd "$R" && printf '%s' "$(jq -nc --arg c "git add -A" '{tool_name:"Bash",tool_input:{command:$c}}')" | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID HOME="$EMPTYHOME" HOOKS_LIB_DIR="$HOME/.claude/hooks/lib" bash "$HOOK" 2>/dev/null )
denied "$out" && no "T16 unset-SID wrongly DENIED (would flag own files in headless runner)" "$out" || ok "T16 unset SID + no runtime file -> allow (CODEX-003 fail-open)"
# T16b: unset env BUT stdin JSON carries .session_id == MYSID → resolver finds it → sibling theft DENIED.
out=$( cd "$R" && printf '%s' "$(jq -nc --arg c "git add -A" --arg s "$MYSID" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}')" | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID HOOKS_LIB_DIR="$HOME/.claude/hooks/lib" bash "$HOOK" 2>/dev/null )
denied "$out" && ok "T16b SID from stdin .session_id -> resolver identifies me, sibling theft DENY (parity w/ track-session-writes)" || no "T16b stdin-resolved SID should still DENY sibling theft" "$out"

# T17 (forensic 2026-07-04, false-deny): a PATHSPEC-SCOPED `git add -A -- <path>` can only
# stage under its pathspec — it must NOT be denied for a sibling file OUTSIDE the pathspec.
# (fixtures use TRACKED-then-modified files: plain `git status --porcelain` collapses untracked
#  new directories to `dir/`, which would bypass the path comparison for a reason unrelated to
#  the pathspec logic under test.)
R=$(mkrepo t17); wlog "$R" "$MYSID" "app/Module/Mine.php"; wlog "$R" "$SIB" "docs/pack.txt"
( cd "$R" && mkdir -p app/Module docs && printf 'base\n' > app/Module/Mine.php && printf 'base\n' > docs/pack.txt \
  && git add -A && git commit -qm t17base && printf 'sib-wip\n' > docs/pack.txt ) >/dev/null 2>&1
out=$(run "$R" "$MYSID" "git add -A -- app/Module/")
denied "$out" && no "T17 pathspec-scoped add wrongly DENIED for out-of-scope sibling file" "$out" || ok "T17 'git add -A -- app/…' cannot reach docs/pack.txt -> allow (pathspec-scope fix)"
# T17b: the SAME scoped add but the sibling file is INSIDE the pathspec → still DENY (scoping is not a hole).
R=$(mkrepo t17b); wlog "$R" "$MYSID" "app/Module/Mine.php"; wlog "$R" "$SIB" "app/Module/Theirs.php"
( cd "$R" && mkdir -p app/Module && printf 'base\n' > app/Module/Theirs.php \
  && git add -A && git commit -qm t17bbase && printf 'sib-wip\n' > app/Module/Theirs.php ) >/dev/null 2>&1
out=$(run "$R" "$MYSID" "git add -A -- app/Module/")
denied "$out" && ok "T17b scoped add that WOULD sweep an in-scope sibling file -> still DENY" || no "T17b in-scope sibling file must still DENY" "$out"
# T17c: repo-wide pathspec (`-- .`) gets NO scoping relief.
R=$(mkrepo t17c); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" "git add -A -- .")
denied "$out" && ok "T17c 'git add -A -- .' (repo-wide pathspec) -> still DENY" || no "T17c repo-wide pathspec should not evade" "$out"

# T18 (forensic 2026-07-04, misdiagnosis): when every victim session is DEAD, the deny
# STANDS but the reason must say DEAD/orphaned-WIP-adjudication, not "concurrent sibling".
R=$(mkrepo t18); wlog "$R" "$MYSID" "app.php"; wlog "$R" "$SIB" "other.php"; ( cd "$R" && printf 'sib\n' > other.php )
out=$(run "$R" "$MYSID" "git add -A")
if denied "$out"; then
  printf '%s' "$out" | grep -q "DEAD" \
    && ok "T18 dead-owner sweep DENIED with an honest dead-owner/adjudication message" \
    || no "T18 deny reason still claims a live 'concurrent sibling' for a dead owner" "$(printf '%s' "$out" | head -c 200)"
else
  no "T18 dead-owner sweep must still DENY" "$out"
fi

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ $FAIL -eq 0 ]
