#!/usr/bin/env bash
# inflight-advisory-test.sh — W-INFLIGHT (2026-09-05): a blocked Stop names the Agent-tool subagents
# still in flight so the model waits on them synchronously instead of ending the turn.
# CLASS: a production session hit a long run of Stop blocks, most of them no-op turns, while
# background subagents were producing the very artifacts the gate demanded.
# RED ORACLE: check-review-artifact.sh.pre-fix20260905-bak has no W-INFLIGHT section.
set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/check-review-artifact.sh}"
BAK="$HOME/.claude/hooks/check-review-artifact.sh.pre-fix20260905-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
[ -f "$HOOK" ] || { echo "NO hook missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOMEDIR="$TMP/home"; REPO="$TMP/repo"
mkdir -p "$HOMEDIR/.claude/projects/p" "$REPO"
ln -s "$HOME/.claude/hooks" "$HOMEDIR/.claude/hooks" 2>/dev/null
( cd "$REPO" && git init -q -b main && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
: > "$HOMEDIR/.claude/history.jsonl"
GITDIR="$(cd "$REPO" && git rev-parse --git-common-dir 2>/dev/null)"; case "$GITDIR" in /*) ;; *) GITDIR="$REPO/$GITDIR";; esac
SID="1f1f1f1f-1111-4111-8111-000000000001"
TX="$HOMEDIR/.claude/projects/p/${SID}.jsonl"
printf '{"sessionId":"%s","display":"/v add the widget"}\n' "$SID" >> "$HOMEDIR/.claude/history.jsonl"
printf 'app/Widget.php\n' > "$GITDIR/claude-session-writes-${SID}.txt"
mkdir -p "$REPO/.v/artifacts"; printf 'Model: haiku\nplaceholder so the hook reaches the artifact-gate assembly (not the earlier abandonment block)\n' > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
NOW="$(date -u +%Y-%m-%dT%H:%M:%S).000Z"
OLD="$(date -u -v-3H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%S).000Z"
# Transcript: A (single, recent, notified), B+C (PARALLEL in one line, recent, NOT notified), D (single, 3h old, not notified).
mk_tx() {
  {
    printf '{"type":"user","message":{"role":"user","content":"/v add the widget"},"timestamp":"%s"}\n' "$NOW"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_AAAA1","name":"Agent","input":{"subagent_type":"v-verify-done-runner","prompt":"x"}}]},"timestamp":"%s"}\n' "$NOW"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_BBBB2","name":"Agent","input":{"description":"d","prompt":"p{}q","subagent_type":"logic-reviewer"}},{"type":"tool_use","id":"toolu_EEEE5","name":"Agent","input":{"prompt":"bare agent, no subagent_type"}},{"type":"tool_use","id":"toolu_CCCC3","name":"Agent","input":{"subagent_type":"security-reviewer","prompt":"y"}}]},"timestamp":"%s"}\n' "$NOW"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_DDDD4","name":"Agent","input":{"subagent_type":"general-purpose","prompt":"z"}}]},"timestamp":"%s"}\n' "$OLD"
    printf '{"type":"user","message":{"role":"user","content":"<task-notification>\\n<task-id>t1</task-id>\\n<tool-use-id>toolu_AAAA1</tool-use-id>\\n<status>completed</status>\\n</task-notification>"},"timestamp":"%s"}\n' "$NOW"
    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Waiting for the agents."}]},"timestamp":"%s"}\n' "$NOW"
  } > "$TX"
}
OUTF="$TMP/out"; RC=0
run(){ ( cd "$REPO" && printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":%s,"hook_event_name":"Stop"}' "$SID" "$TX" "$REPO" "${2:-false}" \
    | HOME="$HOMEDIR" CLAUDE_SESSION_ID="$SID" CLAUDE_CODE_SESSION_ID="$SID" bash "$1" ) > "$OUTF" 2>&1; RC=$?; }

echo "== W-INFLIGHT :: blocked Stop names in-flight Agent subagents =="
mk_tx; run "$HOOK"
grep -q 'COMPLETION BLOCKED — artifact gates not satisfied' "$OUTF" && ok "1 fixture reaches the artifact-gate block (rc=$RC)" || no "1 fixture did not reach the artifact-gate block" "rc=$RC $(head -c 300 "$OUTF")"
grep -q 'IN-FLIGHT SUBAGENTS: 3 Agent tool call' "$OUTF" && ok "2 counts exactly the 3 un-notified recent calls (parallel B+E+C counted separately; A notified; D aged out)" || no "2 wrong in-flight count" "$(grep -o 'IN-FLIGHT SUBAGENTS: [0-9]*' "$OUTF" | head -1)"
grep -q 'logic-reviewer, agent, security-reviewer' "$OUTF" && ok "3 labels each block from ITS OWN input (the type-less middle block is 'agent'; neighbours keep their labels)" || no "3 labels shifted/misattributed" "$(grep -o 'notification ([^)]*)' "$OUTF" | head -1)"
grep -q 'TaskOutput' "$OUTF" && ok "4 tells the model to wait synchronously (TaskOutput) instead of ending the turn" || no "4 remediation instruction missing"
[ "$RC" -eq 2 ] && ok "5 still BLOCKS (rc=2) — advisory is message-only, gate unchanged" || no "5 rc changed: $RC"

# Negative: every agent notified -> no section.
{ grep -v 'toolu_BBBB2' "$TX" | grep -v 'toolu_DDDD4'; printf '{"type":"user","message":{"role":"user","content":"<task-notification><tool-use-id>toolu_BBBB2</tool-use-id><tool-use-id>toolu_EEEE5</tool-use-id><tool-use-id>toolu_CCCC3</tool-use-id></task-notification>"},"timestamp":"%s"}\n' "$NOW"; } > "$TX.2"; mv "$TX.2" "$TX"
run "$HOOK"
grep -q 'IN-FLIGHT SUBAGENTS' "$OUTF" && no "6 section printed with nothing in flight (false positive)" || ok "6 all notified -> no in-flight section"
[ "$RC" -eq 2 ] && ok "7 still blocks without the section (rc=2)" || no "7 rc changed: $RC"

# Fail-open: unreadable transcript path -> no section, still blocks.
TX_SAVE="$TX"; TX="$TMP/does-not-exist.jsonl"; run "$HOOK"; TX="$TX_SAVE"
grep -q 'IN-FLIGHT SUBAGENTS' "$OUTF" && no "8 section printed from a missing transcript" || ok "8 missing transcript -> section silently omitted"
[ "$RC" -eq 2 ] && ok "9 missing transcript still blocks (fail-open on the advisory, not on the gate)" || no "9 rc changed: $RC"

# Fingerprint invariance (W-BLOCK-FP): the in-flight count must NOT move the escape counter — the
# same violation with 2 vs 0 in-flight agents must fingerprint identically. Derive: block twice
# with different transcripts under one fresh CLAUDE_STOP_REARM_DIR and read the chain's `same` counter.
mk_tx; export CLAUDE_STOP_REARM_DIR="$TMP/rearm"; mkdir -p "$CLAUDE_STOP_REARM_DIR"
run "$HOOK" true; mk_tx; { grep -v 'toolu_BBBB2' "$TX"; } > "$TX.2"; mv "$TX.2" "$TX"; run "$HOOK" true
_same=$(sed -n 2p "$CLAUDE_STOP_REARM_DIR"/*check-review-artifact* 2>/dev/null | head -1)
unset CLAUDE_STOP_REARM_DIR
[ "${_same:-0}" = "2" ] && ok "10 rendering the section does not change the violation fingerprint (same=2 across two renders)" || no "10 fingerprint moved with the rendering (same=${_same:-?})" "state files: $(ls "$TMP/rearm" 2>/dev/null | tr '\n' ' ')"

if [ -f "$BAK" ]; then
  mk_tx; run "$BAK"
  grep -q 'IN-FLIGHT SUBAGENTS' "$OUTF" && no "RED: pre-fix hook already prints the section (bite not isolating)" || ok "RED: pre-fix hook blocks with NO in-flight section (the waste class reproduced)"
else
  echo "  --  RED oracle skipped ($BAK missing)"
fi
echo; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1
