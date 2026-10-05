#!/usr/bin/env bash
# worktree-write-boundary-test.sh — W25-F25 write boundary (forensic 2026-07-03).
# Live-fires the REAL hook: a session that owns a live-locked worktree in a repo must be denied
# SOURCE writes at that repo's MAIN root — and every fail-open path must stay open.
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/worktree-write-boundary.sh"
[ -f "$HOOK" ] || { echo "NO hook missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T="$(mktemp -d)"; trap 'rm -rf "$T" 2>/dev/null' EXIT
R="$T/repo"; SID="abcd1234-1111-4000-8000-000000000001"
mkdir -p "$R/app" "$T/cfg/runtime"
( cd "$R" && git init -q -b main && echo x > app/base.php && git add -A && git commit -qm base \
  && git worktree add -q .worktrees/feat -b feat ) >/dev/null 2>&1
printf '%s %s %s\n' "$SID" "99999999" "1751500000" > "$R/.worktrees/feat/.claude-session-lock"

run_hook(){ # <file_path> [sid] [cfg]
  local fp="$1" sid="${2:-$SID}" cfg="${3:-$T/cfg}"
  printf '{"tool_input":{"file_path":%s},"session_id":%s}' \
    "$(jq -Rn --arg c "$fp" '$c')" "$(jq -Rn --arg c "$sid" '$c')" \
    | CLAUDE_CONFIG_DIR="$cfg" CLAUDE_SESSION_ID="$sid" bash "$HOOK" 2>/dev/null
}
denied(){ printf '%s' "$1" | grep -q '"permissionDecision":[[:space:]]*"deny"'; }

echo "== the forensic shape: worktree-owning session writing source at main root =="
touch "$T/cfg/runtime/active-worktree-$SID"
o="$(run_hook "$R/app/NewAdapter.php")"
denied "$o" && ok "main-root app/ write DENIED for worktree-owning session" || no "violation not denied" "$o"
printf '%s' "$o" | grep -q ".worktrees/feat" && ok "deny message names the session's own worktree" || no "deny message lacks worktree path"

echo "== fail-open paths stay open =="
o="$(run_hook "$R/.worktrees/feat/app/NewAdapter.php")"
denied "$o" && no "write INSIDE own worktree wrongly denied" || ok "write inside worktree allowed"
o="$(run_hook "$R/PRE_FLIGHT_REPORT_x.md")"
denied "$o" && no "main-root non-source wrongly denied" || ok "main-root report/doc allowed"
o="$(run_hook "$R/app/NewAdapter.php" "ffff9999-2222-4000-8000-000000000002")"
denied "$o" && no "session WITHOUT marker wrongly denied" || ok "no-marker session allowed (inline sessions unaffected)"
rm -f "$R/.worktrees/feat/.claude-session-lock"
o="$(run_hook "$R/app/NewAdapter.php")"
denied "$o" && no "stale marker (no live lock) wrongly denied" || ok "marker-but-no-lock allowed (stale marker fail-open)"
printf '%s %s %s\n' "$SID" "99999999" "1751500000" > "$R/.worktrees/feat/.claude-session-lock"
o="$(run_hook "$T/cfg/hooks/app/thing.sh" "$SID" "$T/cfg")"
denied "$o" && no "CLAUDE_CONFIG_DIR target wrongly denied" || ok "orchestrator home exempt"
o="$(run_hook "$T/outside/app/loose.php")"
denied "$o" && no "non-repo path wrongly denied" || ok "non-repo path allowed"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
