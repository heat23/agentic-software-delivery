#!/usr/bin/env bash
# provenance-frontmatter-model-test.sh
# Version: 1.0.0 (W-PROV-FRONTMATTER, 2026-08-09)
#
# Guards the frontmatter fallback for `submodel=` in record-agent-dispatch-provenance.sh.
#
# WHY THIS EXISTS. DISPATCH_PROVENANCE is the machine witness that exposed the 2026-08-06 haiku
# incident: every reviewer DECLARED `model: sonnet` in frontmatter while the Agent tool's `model`
# PARAMETER silently overrode it to haiku, and provenance was the only artefact that recorded what
# actually ran. The fix for that incident (correctly) tells sessions to pass NO model and let each
# agent's frontmatter govern — which made `.tool_input.model` empty, so every `mode=agent-tool`
# row started recording `submodel=unknown`. Measured on the 2026-08-06..09 corpus: most
# adversarial-panel rows, plus logic / security / framework-pitfall / codex — all `unknown`.
#
# So the witness went blind at exactly the dispatch mode that caused the incident. That is the
# same declaration-vs-observation split, one layer over. This restores observability.
#
# THE HONESTY REQUIREMENT — the reason for the `~fm` suffix. A row must never claim to have
# OBSERVED a passed parameter when it inferred one. `sonnet` = the call specified it.
# `sonnet~fm` = inherited from the agent definition. A future analysis that treats the two as
# identical evidence would be repeating the original mistake, so the distinction is asserted here.
#
# Telemetry only: no gate reads this field to decide anything, and Layer 3 of
# enforce-haiku-dispatch.sh remains the enforcement.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/record-agent-dispatch-provenance.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
[ -r "$HOOK" ] || { echo "FAIL: hook missing at $HOOK"; exit 1; }

echo "== W-PROV-FRONTMATTER :: submodel falls back to the agent definition =="

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1
git init -q . 2>/dev/null; git config user.email t@t; git config user.name t
mkdir -p .v/artifacts

# Drive the REAL hook as PostToolUse does, with a SID that matches local identity so the
# foreign-SID rejection at :107 does not short-circuit the run.
SID="11111111-2222-3333-4444-aaaaaaaaaaaa"
run(){ # $1=subagent_type  $2=model ("" = omit the key entirely, as the guidance now recommends)
  local payload
  if [ -z "$2" ]; then
    payload=$(jq -n --arg a "$1" --arg s "$SID" \
      '{tool_name:"Agent",session_id:$s,tool_input:{subagent_type:$a,prompt:"review the diff"},tool_response:{content:"finding: none"}}')
  else
    payload=$(jq -n --arg a "$1" --arg m "$2" --arg s "$SID" \
      '{tool_name:"Agent",session_id:$s,tool_input:{subagent_type:$a,model:$m,prompt:"review the diff"},tool_response:{content:"finding: none"}}')
  fi
  printf '%s' "$payload" | CLAUDE_SESSION_ID="$SID" bash "$HOOK" >/dev/null 2>&1
}
submodel_for(){ grep "agent=$1|" ".v/artifacts/DISPATCH_PROVENANCE_${SID}.log" 2>/dev/null \
  | tail -1 | grep -oE 'submodel=[^|]*' | cut -d= -f2; }

# --- an agent whose frontmatter declares a model, dispatched with NO model param ----------------
FM=$(awk '/^---[[:space:]]*$/{n++; next} n==1 && /^model:/{sub(/^model:[[:space:]]*/,""); gsub(/["'"'"'[:space:]]/,""); print; exit}' "$HOME/.claude/agents/security-reviewer.md" 2>/dev/null)
if [ -z "$FM" ]; then
  no "precondition: security-reviewer declares a model in frontmatter" "non-empty" "empty"
else
  ok "precondition: security-reviewer frontmatter declares model=$FM"
  run security-reviewer ""
  got=$(submodel_for security-reviewer)
  if [ "$got" = "${FM}~fm" ]; then ok "omitted model -> submodel=$got (inferred, marked)"
  else no "omitted model falls back to frontmatter" "${FM}~fm" "${got:-<no row>}"; fi
fi

# --- an explicit param must still win, and must NOT carry the ~fm marker ------------------------
run logic-reviewer "sonnet"
got=$(submodel_for logic-reviewer)
if [ "$got" = "sonnet" ]; then ok "explicit model -> submodel=sonnet (observed, unmarked)"
else no "explicit model recorded verbatim" "sonnet" "${got:-<no row>}"; fi

case "$got" in *"~fm"*) no "explicit model must not be marked inferred" "no ~fm suffix" "$got" ;;
                     *) ok "explicit model carries no ~fm suffix" ;; esac

# --- an agent with no definition on disk must degrade to 'unknown', never invent a model --------
run definitely-not-a-real-agent-xyz ""
got=$(submodel_for definitely-not-a-real-agent-xyz)
if [ "$got" = "unknown" ] || [ -z "$got" ]; then ok "unknown agent -> ${got:-<no row>} (no invention)"
else no "unknown agent must not gain a model" "unknown or no row" "$got"; fi

# --- the marker must be parseable back to a bare model name -------------------------------------
if [ "$(printf '%s' "sonnet~fm" | sed 's/~fm$//')" = "sonnet" ]; then
  ok "~fm suffix strips cleanly for analysis (sed 's/~fm\$//')"
else
  no "~fm strips cleanly" "sonnet" "$(printf '%s' "sonnet~fm" | sed 's/~fm$//')"
fi

# --- mutation check: the fallback must be what produced the value, not a coincidence -------------
# Point HOME at an agents dir where the SAME agent declares a DIFFERENT model. If the row does not
# follow, the assertion above was not reading the frontmatter at all.
MUT="$TMP/fakehome"; mkdir -p "$MUT/.claude/agents" "$MUT/.claude/skills/v/references"
printf -- '---\nname: security-reviewer\nmodel: haiku\n---\nbody\n' > "$MUT/.claude/agents/security-reviewer.md"
rm -f ".v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
jq -n --arg s "$SID" '{tool_name:"Agent",session_id:$s,tool_input:{subagent_type:"security-reviewer",prompt:"p"},tool_response:{content:"c"}}' \
  | HOME="$MUT" CLAUDE_SESSION_ID="$SID" bash "$HOOK" >/dev/null 2>&1
got=$(submodel_for security-reviewer)
if [ "$got" = "haiku~fm" ]; then
  ok "mutation check: changing the definition changes the row (fallback is live)"
else
  no "mutation check" "haiku~fm from the mutated definition" "${got:-<no row>}"
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
