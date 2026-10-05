#!/usr/bin/env bash
# block-vtmp-typo-test.sh — behavioral harness for block-vtmp-typo.sh (PreToolUse guard).
#
# WHY THIS EXISTS (audit 2026-06-17): block-vtmp-typo.sh had ZERO behavioral coverage — its only
# reference was a quoted token in v-token-budget-test.sh's anchor list, which coverage-critic counted
# as "covered" via bare name-inclusion. This harness drives the REAL hook over stdin and asserts the
# deny/allow decision: a `.v-tmp/` path is blocked, the canonical `.v/tmp/` is allowed, and a
# slashless `.v-tmp` prose mention is NOT falsely blocked (the documented FP-safety boundary).
set -uo pipefail
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/block-vtmp-typo.sh"
[ -f "$HOOK" ] || { echo "NO block-vtmp-typo.sh missing"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# run <json> -> prints hook stdout; sets RC
run(){ printf '%s' "$1" | bash "$HOOK" 2>/dev/null; }
# [ -n ] first: jq 1.6 (Debian 12) exits 0 for `jq -e` on empty input, which read "no output" as a deny.
is_deny(){ [ -n "$1" ] && printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }

echo "=== T1: Bash command writing to .v-tmp/ -> DENY ==="
OUT=$(run '{"tool_name":"Bash","tool_input":{"command":"echo x > .v-tmp/foo.txt"}}')
is_deny "$OUT" && ok "blocked .v-tmp/ in Bash command" || no "T1: expected deny (out=$OUT)"

echo "=== T2: Bash command using canonical .v/tmp/ -> ALLOW ==="
OUT=$(run '{"tool_name":"Bash","tool_input":{"command":"echo x > .v/tmp/foo.txt"}}')
is_deny "$OUT" && no "T2: canonical .v/tmp/ wrongly blocked (out=$OUT)" || ok "canonical .v/tmp/ allowed"

echo "=== T3: Write to a .v-tmp/ file path -> DENY ==="
OUT=$(run '{"tool_name":"Write","tool_input":{"file_path":"/proj/.v-tmp/scratch.md"}}')
is_deny "$OUT" && ok "blocked .v-tmp/ file_path on Write" || no "T3: expected deny (out=$OUT)"

echo "=== T4: Write to canonical .v/tmp/ path -> ALLOW ==="
OUT=$(run '{"tool_name":"Write","tool_input":{"file_path":"/proj/.v/tmp/scratch.md"}}')
is_deny "$OUT" && no "T4: canonical path wrongly blocked (out=$OUT)" || ok "canonical .v/tmp/ Write allowed"

echo "=== T5: slashless prose mention of .v-tmp (no path) -> ALLOW (FP-safety) ==="
OUT=$(run '{"tool_name":"Bash","tool_input":{"command":"echo we renamed .v-tmp to .v/tmp in the commit body"}}')
is_deny "$OUT" && no "T5: slashless mention wrongly blocked (FP) (out=$OUT)" || ok "slashless .v-tmp mention not blocked"

echo "=== T6: non-write tool (Read) with .v-tmp/ -> ALLOW (guard only targets Bash/Write/Edit) ==="
OUT=$(run '{"tool_name":"Read","tool_input":{"file_path":"/proj/.v-tmp/x"}}')
is_deny "$OUT" && no "T6: Read wrongly blocked (out=$OUT)" || ok "Read not gated"

echo "─────────────────────────────────────────"
echo "block-vtmp-typo-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
