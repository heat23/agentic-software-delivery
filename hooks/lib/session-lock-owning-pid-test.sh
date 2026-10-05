#!/usr/bin/env bash
# session-lock-owning-pid-test.sh — WRONG-PID-LOCK class (forensic 2026-07-04, Jul-4 fleet).
#
# Lock minting stamped `$$` — the EPHEMERAL Bash-tool subshell — so kill -0 on every fleet lock
# was permanently false while the sessions sat alive in idle tabs; all PID liveness degraded to
# the idle-tab-refreshed transcript-mtime tiebreaker and the drain starved. owning_claude_pid()
# must return a pid that OUTLIVES the minting subshell (the claude ancestor), with a safe
# fallback when no such ancestor exists.
set -u
LIB="${V_LOCKLIB_OVERRIDE:-$HOME/.claude/hooks/lib/session-lock-parse.sh}"
[ -f "$LIB" ] || { echo "SKIP: missing $LIB"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# shellcheck source=/dev/null
. "$LIB"

command -v owning_claude_pid >/dev/null 2>&1 \
  && ok "owning_claude_pid is defined in the shared lock lib" \
  || { no "owning_claude_pid missing from $LIB"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1; }

# --- T1: returns a numeric pid that is ALIVE right now ---
P=$(owning_claude_pid || true)
case "$P" in
  ''|*[!0-9]*) no "T1 returns a numeric pid" "got '$P'" ;;
  *) kill -0 "$P" 2>/dev/null && ok "T1 returned pid $P is alive (kill -0)" || no "T1 returned pid is dead" "pid=$P" ;;
esac

# --- T2 (the class): a lock minted inside an ephemeral subshell must carry a pid that SURVIVES
# the subshell. Old mint (`$$`) provably fails this; new mint (owning_claude_pid) passes when a
# claude ancestor exists. Skip when the test itself runs outside a claude session (CI). ---
_have_claude_ancestor=0
_p=$$; _d=0
while [ -n "$_p" ] && [ "$_p" != "1" ] && [ "$_d" -lt 20 ]; do
  case "$(ps -o comm= -p "$_p" 2>/dev/null | awk '{print $1}')" in */claude|claude) _have_claude_ancestor=1; break ;; esac
  _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d '[:space:]'); _d=$((_d+1))
done
if [ "$_have_claude_ancestor" = 1 ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  # old mint shape (red fixture): the subshell's own pid, dead as soon as the subshell exits
  bash -c 'printf "sid %s 1\n" "$$"' > "$T/lock-old"
  # new mint shape: the owning claude ancestor, still alive after the subshell exits
  bash -c ". '$LIB'; printf 'sid %s 1\n' \"\$(owning_claude_pid)\"" > "$T/lock-new"
  _old_pid=$(awk '{print $2}' "$T/lock-old"); _new_pid=$(awk '{print $2}' "$T/lock-new")
  if kill -0 "$_old_pid" 2>/dev/null; then
    no "T2 red-fixture: old-mint pid should be DEAD after the subshell exits" "pid=$_old_pid still alive — test vacuous"
  else
    ok "T2 red-fixture: old-mint (\$\$) pid $_old_pid is dead after the subshell exits (the bug)"
  fi
  if kill -0 "$_new_pid" 2>/dev/null; then
    ok "T2 new mint (owning_claude_pid) pid $_new_pid survives the minting subshell"
  else
    no "T2 new mint pid should survive the minting subshell" "pid=$_new_pid dead"
  fi
else
  ok "T2 skipped: no claude ancestor in this environment (CI) — fallback behavior covered by T3"
fi

# --- T3: fallback — walking from pid 1 finds no claude ancestor → prints the start pid, rc!=0 ---
OUT=$(owning_claude_pid 1) ; RC=$?
[ "$OUT" = "1" ] && [ "$RC" -ne 0 ] \
  && ok "T3 no-ancestor fallback prints the start pid and signals rc!=0" \
  || no "T3 fallback wrong" "out=$OUT rc=$RC"

# --- T4: mint sites actually USE the helper (regression: a future refactor reverting to \$\$) ---
AOC="$HOME/.claude/skills/v/references/v-worktree-adopt-or-create.sh"
if [ -f "$AOC" ]; then
  _uses=$(grep -E 'owning_claude_pid' "$AOC" 2>/dev/null | wc -l | tr -d ' ')
  _bare=$(grep -E '"\$SID" "\$\$" "\$\(date' "$AOC" 2>/dev/null | wc -l | tr -d ' ')
  [ "$_uses" -ge 2 ] && [ "$_bare" -eq 0 ] \
    && ok "T4 both mint sites in v-worktree-adopt-or-create.sh stamp owning_claude_pid (no bare \$\$ mint left)" \
    || no "T4 mint sites regressed" "owning_claude_pid uses=$_uses bare-\$\$-mints=$_bare"
else
  ok "T4 skipped: adopt-or-create script absent"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
