#!/usr/bin/env bash
# enforce-branch-gate-test.sh — behavioral guard for enforce-branch-gate.sh (audit 2026-06-19).
#
# WHY: this pass REGISTERED enforce-branch-gate.sh as a GLOBAL PreToolUse/Bash hard gate (it was dead —
# class-K F-K3). A global hard-block on EVERY Bash call is high-risk: a fail-CLOSED edge case would brick
# all interactive work. There was no behavioral test. This pins the contract — especially the FAIL-OPEN
# paths, so a future change that accidentally makes the gate fail-closed (non-git / main / build|fix /
# override) is caught loudly — plus the genuine BLOCK paths (wrong branch, detached HEAD) and one-shot.
set -u
HOOK="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/enforce-branch-gate.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$HOOK" ] || { echo "SKIP: hook missing"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

_cfg(){ git -C "$1" config user.email t@t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }
# repo_on <branch> -> fresh repo (unique path => unique REPO_KEY => no one-shot-marker carryover) on <branch>.
repo_on(){ local b="$1" r; r="$(mktemp -d)"; git init -q "$r" >/dev/null 2>&1; _cfg "$r"
  printf 'x\n' > "$r/f"; git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm base >/dev/null 2>&1
  git -C "$r" branch -M main >/dev/null 2>&1
  [ "$b" != main ] && git -C "$r" checkout -qb "$b" >/dev/null 2>&1
  printf '%s' "$r"; }
_n=0
# run <repo> <sid> [VAR=val ...] -> deny|allow. Runs the LIVE hook with CWD=repo (it resolves REPO_ROOT
# via `git rev-parse --show-toplevel` from CWD); a unique SID per call avoids one-shot-marker carryover.
run(){ local r="$1" sid="$2"; shift 2
  local j; j="$(jq -nc --arg c "$r" --arg s "$sid" '{cwd:$c,session_id:$s,tool_name:"Bash",tool_input:{command:"ls"}}')"
  local out; out="$( cd "$r" 2>/dev/null && printf '%s' "$j" | env "$@" bash "$HOOK" 2>/dev/null )"
  printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' && echo deny || echo allow; }
fresh_sid(){ _n=$((_n+1)); printf '%08d-0000-4000-8000-00000000abcd' "$_n"; }

echo "== enforce-branch-gate behavioral contract =="

# ── FAIL-OPEN paths (the brick-risk surface — these MUST allow) ──
r="$(repo_on main)";        [ "$(run "$r" "$(fresh_sid)")" = allow ] && ok "main branch ALLOWED" || no "main wrongly blocked (BRICK)"; rm -rf "$r"
r="$(repo_on build/feat-x)";[ "$(run "$r" "$(fresh_sid)")" = allow ] && ok "build/* branch ALLOWED" || no "build/* wrongly blocked (BRICK)"; rm -rf "$r"
r="$(repo_on fix/bug-y)";   [ "$(run "$r" "$(fresh_sid)")" = allow ] && ok "fix/* branch ALLOWED" || no "fix/* wrongly blocked (BRICK)"; rm -rf "$r"
nogit="$(mktemp -d)";       [ "$(run "$nogit" "$(fresh_sid)")" = allow ] && ok "non-git dir ALLOWED" || no "non-git wrongly blocked (BRICK)"; rm -rf "$nogit"
r="$(repo_on feature/z)";   [ "$(run "$r" "$(fresh_sid)" CLAUDE_ALLOW_NON_MAIN=1)" = allow ] && ok "CLAUDE_ALLOW_NON_MAIN=1 bypass ALLOWED" || no "override bypass did not allow"; rm -rf "$r"

# ── BLOCK paths (the gate's reason to exist) ──
r="$(repo_on feature/z)";   [ "$(run "$r" "$(fresh_sid)")" = deny ] && ok "wrong (feature/*) branch BLOCKED" || no "wrong branch NOT blocked"; rm -rf "$r"
# detached HEAD: check out the commit SHA directly.
r="$(repo_on main)"; _sha="$(git -C "$r" rev-parse HEAD)"; git -C "$r" checkout -q "$_sha" >/dev/null 2>&1
[ "$(run "$r" "$(fresh_sid)")" = deny ] && ok "detached HEAD BLOCKED" || no "detached HEAD NOT blocked"; rm -rf "$r"

# ── One-shot marker is written only on the ALLOW paths (it skips re-checking an already-validated
#    session); it must NOT give a wrong-branch session a free pass after one block. A wrong-branch
#    session therefore STAYS blocked on every call until the branch is fixed (or the override is set) —
#    the secure, evasion-resistant behavior (cf. security review F-4). ──
r="$(repo_on feature/z)"; sid="$(fresh_sid)"
v1="$(run "$r" "$sid")"; v2="$(run "$r" "$sid")"
{ [ "$v1" = deny ] && [ "$v2" = deny ]; } && ok "wrong branch STAYS blocked on repeat (no one-shot escape)" || no "wrong-branch block leaked after first call (v1=$v1 v2=$v2)"; rm -rf "$r"
# A main-branch session is allowed on repeated calls (allow-path one-shot marker short-circuits cleanly).
r="$(repo_on main)"; sid="$(fresh_sid)"
m1="$(run "$r" "$sid")"; m2="$(run "$r" "$sid")"
{ [ "$m1" = allow ] && [ "$m2" = allow ]; } && ok "main session allowed on repeat (allow-path one-shot)" || no "main repeat-call off (m1=$m1 m2=$m2)"; rm -rf "$r"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
