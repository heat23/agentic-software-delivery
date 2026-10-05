#!/usr/bin/env bash
# v-readonly-completion-test.sh — READ-ONLY verification completion contract (2026-07-07).
#
# CLASS: a run-v-packs read-only verification pack (w1-pre-flight / w1-review / 99-verify) changes NO
# product source and produces NO commit BY DESIGN. Before this fix the /v completion machinery had no
# read-only lane, so such a session:
#   * FAILED v-completion-selfcheck.sh ("PRE_FLIGHT not found") → the model FABRICATED diff-review gates
#     (a spurious QA loop that also corrupted the session log), and
#   * was BLOCKED by the Stop hook's abandonment machinery (exit 2 — a false-abandonment hole) once /v-invocation
#     was detected on a zero-diff completion-language session.
# The fix adds a TRIPLE-GATED read-only completion path — recognized in lockstep by the producer self-check,
# the gauntlet-attest safety net, and the Stop hook — that fires ONLY when: (1) the runner tagged the session
# read-only ($REPO/.v/tmp/pack-readonly-<sid>.marker), (2) the session provably wrote ZERO product code
# (shared CODE_EXT_PATTERN/EXEMPT), and (3) a findings artifact exists. A CODE session can never take it.
#
# GREEN on the live scripts; RED on each *.pre-readonly-bak (the pre-fix version). Portable bash 3.2/macOS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAUDE_SRC="${HERE%/skills/v/references}"
SC="$HERE/v-completion-selfcheck.sh"; SC_BAK="$HERE/v-completion-selfcheck.sh.pre-readonly-bak"
AT="$HERE/v-gauntlet-attest.sh";      AT_BAK="$HERE/v-gauntlet-attest.sh.pre-readonly-bak"
STOP="$CLAUDE_SRC/hooks/check-review-artifact.sh"; STOP_BAK="$CLAUDE_SRC/hooks/check-review-artifact.sh.pre-readonly-bak"
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "── result: 0 passed, 0 failed ──"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
# The pre-fix backups these RED cases compare against are not shipped in the public snapshot, so an
# absent backup is a visible skip (not counted as a pass), never a failure.
skip(){ printf '  skip %s — %s\n' "$1" "${2:-}"; }

# Hermetic HOME so the gates resolve their sibling libs/skills without touching the operator's ~/.claude.
HOME_T="$(mktemp -d)"; trap 'rm -rf "$HOME_T"' EXIT
mkdir -p "$HOME_T/.claude/hooks/lib" "$HOME_T/.claude/skills/v/references" \
         "$HOME_T/.claude/skills/v-session-log/references" "$HOME_T/.claude/runtime"
cp -R "$CLAUDE_SRC/hooks/lib/." "$HOME_T/.claude/hooks/lib/" 2>/dev/null || true
cp -R "$CLAUDE_SRC/skills/v/references/." "$HOME_T/.claude/skills/v/references/" 2>/dev/null || true
cp -R "$CLAUDE_SRC/skills/v-session-log/references/." "$HOME_T/.claude/skills/v-session-log/references/" 2>/dev/null || true
SID=dd110001-0000-0000-0000-0000000000ab

mkrepo(){ # $1=writes-ledger-content -> echoes a repo dir wired for a read-only $SID session
  local R; R="$(mktemp -d)"
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
  mkdir -p "$R/.v/tmp" "$R/.v/artifacts"
  printf 'SID=%s\nPACK=w1-review\n' "$SID" > "$R/.v/tmp/pack-readonly-${SID}.marker"   # runner read-only tag
  printf '%s\n' "$1" > "$R/.git/claude-session-writes-${SID}.txt"                      # writes ledger
  printf '# Blocked\nOverall Status: BLOCKED\n' > "$R/.v/artifacts/BLOCKED_${SID}.md"  # findings artifact
  echo "$R"; }

sc_verdict(){ ( cd "$2" && CLAUDE_CODE_SESSION_ID=$SID CLAUDE_SESSION_ID=$SID HOME="$HOME_T" bash "$1" 2>/dev/null ) | grep -E 'V-COMPLETION-SELFCHECK' | head -1; }
at_exit(){ ( cd "$2" && CLAUDE_SESSION_ID=$SID CLAUDE_CODE_SESSION_ID=$SID HOME="$HOME_T" bash "$1" "$SID" >/dev/null 2>&1 ); echo $?; }

echo "── (1) v-completion-selfcheck.sh read-only bypass ──"
R="$(mkrepo '.claude/agent-memory/security-reviewer/MEMORY.md')"
case "$(sc_verdict "$SC" "$R")" in
  *"PASS — read-only"*) ok "live: read-only marker + zero product-code + findings → PASS (read-only)" ;;
  *) no "live read-only bypass did not PASS" "got: $(sc_verdict "$SC" "$R")" ;;
esac
if [ -f "$SC_BAK" ]; then
  case "$(sc_verdict "$SC_BAK" "$R")" in
    *FAIL*) ok "RED: pre-readonly-bak self-check FAILs the same read-only session (the bypass is new)" ;;
    *) no "SC RED oracle did not FAIL" "got: $(sc_verdict "$SC_BAK" "$R")" ;;
  esac
else skip "SC RED oracle absent" "$SC_BAK"; fi
rm -rf "$R"
R="$(mkrepo 'app/Services/Foo.php')"   # a REAL code write
case "$(sc_verdict "$SC" "$R")" in
  *"PASS — read-only"*) no "GUARD BROKEN: a code write took the read-only bypass" "" ;;
  *) ok "guard: a real .php write does NOT take the read-only bypass (falls to full check)" ;;
esac
rm -rf "$R"
R="$(mkrepo '.claude/agent-memory/security-reviewer/MEMORY.md')"; rm -f "$R/.v/tmp/pack-readonly-${SID}.marker"
case "$(sc_verdict "$SC" "$R")" in
  *"PASS — read-only"*) no "GUARD BROKEN: a session with no runner marker took the read-only bypass" "" ;;
  *) ok "guard: without the runner's read-only marker there is no bypass (normal path)" ;;
esac
rm -rf "$R"

echo "── (2) v-gauntlet-attest.sh read-only safety net ──"
R="$(mkrepo '.claude/agent-memory/security-reviewer/MEMORY.md')"
[ "$(at_exit "$AT" "$R")" = 0 ] && ok "live: read-only attest exits 0 (no exit-3 demand for the 3 code artifacts)" || no "read-only attest did not exit 0" "exit=$(at_exit "$AT" "$R")"
if [ -f "$AT_BAK" ]; then
  [ "$(at_exit "$AT_BAK" "$R")" = 3 ] && ok "RED: pre-readonly-bak attest exit-3s the same read-only session" || no "attest RED oracle not exit-3" "exit=$(at_exit "$AT_BAK" "$R")"
else skip "AT RED oracle absent" "$AT_BAK"; fi
rm -rf "$R"
R="$(mkrepo 'app/Services/Foo.php')"
[ "$(at_exit "$AT" "$R")" = 3 ] && ok "guard: attest STILL exit-3s a code session missing its gauntlet artifacts" || no "code session attest did not exit 3" "exit=$(at_exit "$AT" "$R")"
rm -rf "$R"

echo "── (3) check-review-artifact.sh read-only exit (Stop-hook enforcement mirror) ──"
if [ -f "$STOP" ]; then
  stop_exit(){ # $1=hookfile $2=marker(on/off) -> exit code
    local R rc; R="$(mktemp -d)"
    ( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
    mkdir -p "$R/.v/tmp"
    printf '{"sessionId":"%s","display":"/v Run the full pre-flight gate suite READ-ONLY"}\n' "$SID" > "$HOME_T/.claude/history.jsonl"  # IS_V_INVOCATION trigger
    [ "$2" = on ] && printf 'SID=%s\n' "$SID" > "$R/.v/tmp/pack-readonly-${SID}.marker" || true
    ( cd "$R" && printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Pre-flight audit complete — all gates verified, findings recorded."}' "$SID" \
      | env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID CLAUDE_SESSION_ID="$SID" V_TMP_DIR="$R/.v/tmp" HOME="$HOME_T" bash "$1" >/dev/null 2>&1 )
    rc=$?; rm -rf "$R"; echo "$rc"; }
  [ "$(stop_exit "$STOP" on)" = 0 ] && ok "live: read-only /v session with marker → Stop hook exits 0 (no false abandonment block)" || no "stop hook did not exit 0 with marker" "exit=$(stop_exit "$STOP" on)"
  if [ -f "$STOP_BAK" ]; then
    [ "$(stop_exit "$STOP_BAK" on)" != 0 ] && ok "RED: pre-readonly-bak Stop hook BLOCKs the same read-only /v session (the false-abandonment hole)" || no "stop hook RED oracle did not block" "exit=$(stop_exit "$STOP_BAK" on)"
  else skip "STOP RED oracle absent" "$STOP_BAK"; fi
else no "stop hook absent" "$STOP"; fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
