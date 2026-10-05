#!/usr/bin/env bash
# block-vtmp-typo-read-test.sh
# Version: 1.0.0 (W-VTMP-READ, 2026-08-09)
#
# Guards the write-position narrowing of block-vtmp-typo.sh.
#
# THE BUG. The hook denied ANY Bash command whose TEXT contained the hyphenated typo path. That is
# one layer off the property: the harm is CREATING files under it, not naming it. During the
# 2026-08-09 forensic pass it denied a plain `ls -lt` of the directory, and then denied an `echo`
# whose only sin was quoting the path inside a progress message — making the directory both
# un-inspectable and un-discussable from a shell.
#
# It also never stopped the writes that actually happened: ~/.claude/<typo-dir> holds 50 files
# (gate logs, gate-summary, pre-flight skeletons from an earlier session, newest 2026-08-04). Those
# were written by scripts INSIDE a Bash call — PreToolUse sees the outer command line, not a path
# a script builds at runtime. A tree-wide search finds no live producer today.
#
# THE CONTRACT NOW:
#   Bash        -> deny ONLY when a redirect / tee / mutating verb reaches the path.
#   Write/Edit  -> deny UNCONDITIONALLY (a literal file_path has no read/write ambiguity).
#
# The dangerous direction is a WRITE that slips through, so every write shape below is asserted
# explicitly, and a mutation check confirms the write-detection is not vacuous.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/block-vtmp-typo.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
[ -x "$HOOK" ] || [ -r "$HOOK" ] || { echo "FAIL: hook missing at $HOOK"; exit 1; }

# Build the typo path at runtime so THIS harness is not itself denied when a future guard
# inspects test files, and so the string never appears as a literal write target here.
T=".v""-tmp"

# An ALLOWED call produces no output at all (the hook just exits 0) — only a deny emits JSON.
# Normalise both shapes to a word so the assertions read the same either way.
_decide(){ local out; out=$(cat); [ -n "$out" ] || { echo allow; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }
fire_bash(){ jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null | _decide; }
fire_write(){ jq -n --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}' | bash "$HOOK" 2>/dev/null | _decide; }

expect(){ # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then ok "$1 -> $3"; else no "$1" "$2" "$3"; fi
}

echo "== W-VTMP-READ :: reads pass, writes still blocked =="

# --- reads and mentions MUST be allowed (the regression this fixes) -----------------------------
expect "ls of the dir"              allow "$(fire_bash "ls -lt $T/")"
expect "find under the dir"         allow "$(fire_bash "find $T/ -name '*.log'")"
expect "cat a file under it"        allow "$(fire_bash "cat $T/gate-summary.txt")"
expect "grep under it"              allow "$(fire_bash "grep -rn foo $T/")"
expect "stat under it"              allow "$(fire_bash "stat -f '%Sm' $T/x")"   # portability-ok: fixture text for the hook, not a stat call
expect "mentioning it in an echo"   allow "$(fire_bash "echo 'is there a producer of $T/ ?'")"
expect "read piped to a file elsewhere" allow "$(fire_bash "ls $T/ > /tmp/out.txt")"

# --- writes MUST still be denied ---------------------------------------------------------------
expect "redirect into it"           deny "$(fire_bash "echo x > $T/f.txt")"
expect "append into it"             deny "$(fire_bash "echo x >> $T/f.txt")"
expect "tee into it"                deny "$(fire_bash "echo x | tee $T/f.txt")"
expect "mkdir it"                   deny "$(fire_bash "mkdir -p $T/sub")"
expect "cp into it"                 deny "$(fire_bash "cp a.txt $T/a.txt")"
expect "mv into it"                 deny "$(fire_bash "mv a.txt $T/a.txt")"
expect "touch under it"             deny "$(fire_bash "touch $T/a.txt")"
expect "rm under it"                deny "$(fire_bash "rm -f $T/a.txt")"
expect "sed -i under it"            deny "$(fire_bash "sed -i '' s/a/b/ $T/a.txt")"
expect "rsync into it"              deny "$(fire_bash "rsync -a src/ $T/")"
expect "read THEN write in one cmd" deny "$(fire_bash "ls $T/ && echo x > $T/f.txt")"

# --- Write/Edit remain unconditional -----------------------------------------------------------
expect "Write tool to the path"     deny "$(fire_write "$T/notes.md")"
expect "Write tool elsewhere"       allow "$(fire_write "/tmp/notes.md")"

# --- unrelated paths untouched ------------------------------------------------------------------
expect "canonical .v/tmp write"     allow "$(fire_bash "echo x > .v/tmp/f.txt")"
expect "unrelated command"          allow "$(fire_bash "git status")"

# --- mutation check: write-detection must actually bite -----------------------------------------
# If the hook were changed to allow everything, the write cases above would silently pass as
# "allow" and this harness would look green while guarding nothing. Assert the deny path is live.
if [ "$(fire_bash "echo x > $T/probe")" = "deny" ] && [ "$(fire_bash "ls $T/")" = "allow" ]; then
  ok "mutation check: hook discriminates write from read (not blanket-allow, not blanket-deny)"
else
  no "mutation check" "write=deny AND read=allow" "write=$(fire_bash "echo x > $T/probe") read=$(fire_bash "ls $T/")"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
