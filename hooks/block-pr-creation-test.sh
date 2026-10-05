#!/usr/bin/env bash
# block-pr-creation-test.sh — every pull-request-creation route is denied; unrelated tools are not.
# CLASS (2026-10-03): the hook matched only one MCP PR tool by exact name, so a standard GitHub MCP
# server's create_pull_request tool was allowed. V_HOOK_OVERRIDE points it at another copy (RED leg).
set -uo pipefail
HOOK="${V_HOOK_OVERRIDE:-$HOME/.claude/hooks/block-pr-creation.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
decision(){ printf '%s' "$1" | env -u V_PACK_ALLOW_PR -u V_PACK_FILE bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }
expect(){ local want="$1" label="$2" json="$3" got; got=$(decision "$json"); [ -z "$got" ] && got=allow
  [ "$got" = "$want" ] && ok "$label -> $want" || no "$label -> got $got, want $want"; }
expect deny  "codex MCP PR tool"          '{"tool_name":"mcp__codex_apps__github_create_pull_request","tool_input":{"title":"t"}}'
expect deny  "GitHub MCP PR tool"         '{"tool_name":"mcp__github__create_pull_request","tool_input":{"title":"t"}}'
expect deny  "gh pr create in Bash"       '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title t --body b"}}'
expect allow "unrelated Bash command"     '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
expect allow "unrelated MCP tool"         '{"tool_name":"mcp__github__list_issues","tool_input":{}}'
echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
