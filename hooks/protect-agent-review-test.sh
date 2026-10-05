#!/usr/bin/env bash
# protect-agent-review-test.sh — behavioral guard for protect-agent-review.sh (audit 2026-06-19).
#
# WHY: protect-agent-review.sh was DEAD (registered in NEITHER settings file) for months — the audit's
# class-K CRITICAL F-K1. This pass registered it (PreToolUse Write|Edit) so it now fires in EVERY
# interactive session, AND widened its FND-count regex to match indented '#### FND-' headers (review F-6).
# A hook with global blast radius and freshly-changed logic had NO behavioral test (audit F-K1 noted this
# exact gap). This pins the contract so it cannot silently rot or regress:
#   - BLOCKS a >50% size shrink of an existing substantial review,
#   - BLOCKS an FND-finding drop — INCLUDING indented '  #### FND-' headers (T2 bites the regex fix),
#   - ALLOWS first-write, stub-overwrite (<=600B), append/Resolution-grow, and non-AGENT_REVIEW files,
#   - FAILS OPEN on malformed input (never a fail-closed brick of legitimate writes).
set -u
HOOK="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/protect-agent-review.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$HOOK" ] || { echo "SKIP: hook missing"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SID="aaaa1111-2222-3333-4444-555555555555"
AR="$TMP/AGENT_REVIEW_${SID}.md"

# decide <json> -> "deny" if the hook emits a deny decision, else "allow". stderr suppressed (the hook
# also prints a human DENIED line there). The live hook resolves HOOKS_LIB_DIR from its own BASH_SOURCE,
# so invoking it by absolute path finds require-jq.sh correctly.
decide(){ local out; out="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"; printf '%s' "$out" | grep -qE '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' && echo deny || echo allow; }

# A substantial review (>600B) with THREE INDENTED '#### FND-' findings (the shape the old anchored
# regex missed) plus padding so removing one FND line is < a 50% size shrink (isolates the FND rule).
mk_substantial(){
  { printf '# AGENT_REVIEW\nModel: sonnet\nStatus: completed\n\n'
    printf '  #### FND-001 high: overbroad catch\n  detail %s\n' "$(head -c 200 </dev/zero | tr '\0' x)"
    printf '  #### FND-002 medium: retry storm\n  detail %s\n' "$(head -c 200 </dev/zero | tr '\0' y)"
    printf '  #### FND-003 low: no test coverage\n  detail %s\n' "$(head -c 200 </dev/zero | tr '\0' z)"
    printf 'Overall: FAIL\n'
  } > "$AR"
}

echo "== protect-agent-review behavioral contract =="

# T1: substantial review -> Write that shrinks it to a stub -> BLOCK (size rule).
mk_substantial
j="$(jq -nc --arg f "$AR" '{tool_name:"Write",tool_input:{file_path:$f,content:"Overall: PASS"}}')"
[ "$(decide "$j")" = deny ] && ok "T1 >50% size shrink BLOCKED" || no "T1 size shrink NOT blocked"

# T2 (REGEX-FIX BITE): substantial review -> Edit removes ONE indented '#### FND-' line -> BLOCK (3->2).
# With the old anchored regex ('^#### FND-') the indented headers count as 0, so neither the FND rule
# nor the size rule fires and this edit would be ALLOWED. So this case fails RED on a regex regression.
mk_substantial
j="$(jq -nc --arg f "$AR" '{tool_name:"Edit",tool_input:{file_path:$f,old_string:"  #### FND-002 medium: retry storm",new_string:""}}')"
[ "$(decide "$j")" = deny ] && ok "T2 indented FND-drop BLOCKED (regex-fix bite)" || no "T2 indented FND-drop NOT blocked — FND regex anchored to col 0?"

# T3: no existing file -> first write -> ALLOW (nothing to protect yet).
j="$(jq -nc --arg f "$TMP/AGENT_REVIEW_fresh.md" '{tool_name:"Write",tool_input:{file_path:$f,content:"first review body"}}')"
[ "$(decide "$j")" = allow ] && ok "T3 first write ALLOWED" || no "T3 first write blocked"

# T4: existing trivial stub (<=600B) -> overwrite -> ALLOW (the dispatched reviewer replaces a pre-stub).
printf 'pre-dispatch stub\n' > "$AR"
j="$(jq -nc --arg f "$AR" '{tool_name:"Write",tool_input:{file_path:$f,content:"real review body now"}}')"
[ "$(decide "$j")" = allow ] && ok "T4 stub (<=600B) overwrite ALLOWED" || no "T4 stub overwrite blocked"

# T5: substantial review -> Write that GROWS it (appends a Resolution section, keeps all 3 FNDs) -> ALLOW.
mk_substantial
grown="$(cat "$AR")
## Resolution
All findings addressed: fixed 001, documented 002, deferred 003.
$(head -c 400 </dev/zero | tr '\0' q)"
j="$(jq -nc --arg f "$AR" --arg c "$grown" '{tool_name:"Write",tool_input:{file_path:$f,content:$c}}')"
[ "$(decide "$j")" = allow ] && ok "T5 grow + Resolution-append ALLOWED" || no "T5 grow wrongly blocked"

# T6: a non-AGENT_REVIEW file -> ALLOW (the hook must ignore everything else).
j="$(jq -nc --arg f "$TMP/src/foo.ts" '{tool_name:"Write",tool_input:{file_path:$f,content:"x"}}')"
[ "$(decide "$j")" = allow ] && ok "T6 non-AGENT_REVIEW file IGNORED" || no "T6 non-target file blocked"

# T7: malformed input -> ALLOW (fail-open; a guard must never brick legitimate writes on bad JSON).
[ "$(decide 'this is not json')" = allow ] && ok "T7 malformed input FAILS OPEN" || no "T7 malformed input fail-CLOSED (would brick writes)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
