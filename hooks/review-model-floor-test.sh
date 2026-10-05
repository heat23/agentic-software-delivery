#!/usr/bin/env bash
# review-model-floor-test.sh
# Version: 1.0.0 (W-REVIEW-FLOOR, 2026-08-06)
#
# Guards Layer 3 of enforce-haiku-dispatch.sh: a CODE-REVIEW agent may never be dispatched at
# haiku, whatever the caller passes.
#
# THE INCIDENT. Owner decision, 2026-08-06: adversarial-panel-reviewer must run on SONNET, not
# Haiku 4.5, because code review needs the stronger model. The agent's own frontmatter said
# `model: sonnet` — but the Agent tool's `model` PARAMETER overrides frontmatter, and CLAUDE.md
# said "Dispatch review agents with model: \"haiku\"". So the declaration was sonnet and the
# dispatch was haiku, silently, for months.
#
# THE SWEEP (DISPATCH_PROVENANCE, the machine witness, 2026-07-25..2026-08-06) — this was NOT one
# agent. EVERY review agent had run on haiku despite declaring sonnet:
#   adversarial-panel-reviewer 10 | logic-reviewer 8 | codex-adversarial-reviewer 11
#   codebase-fit-reviewer 6 (of 28!) | v-qa-reviewer 9 | v-workflow-verifier 6
#   security-reviewer 7 of 50 — the agent that reviews auth, payments and data exposure.
#
# WHY THE EXISTING GUARD MISSED IT — and this is the reusable lesson. v-review-model-tier-test.sh
# asserted the FRONTMATTER text of each agent. Frontmatter is a DECLARATION; the violation happens
# at DISPATCH. A static assertion cannot see a runtime override, so the guard was green through
# every one of those dispatches. Guard the property where it is DECIDED, not a proxy one layer away.
# (Same shape as three other bugs found the same week: a detector measuring dispatch-spread instead
# of batching, a regex pinning a column position instead of "is this a gate row", and a re-arm
# counter fingerprinting rendered text instead of the violation.)
#
# WHAT MUST NOT CHANGE: the MECHANICAL runners stay haiku. v-pre-flight-runner and
# v-verify-done-runner execute gates and report; they do not judge code. Layers 1-2 pin those and
# are asserted here to be intact.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/enforce-haiku-dispatch.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

# Drive the REAL hook over stdin, exactly as PreToolUse does.
fire(){ # $1=subagent_type $2=model $3=prompt -> resolved model ('' = untouched)
  jq -n --arg a "$1" --arg m "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$a,model:$m,prompt:$p}}' \
  | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.updatedInput.model // empty' 2>/dev/null
}
decision(){ jq -n --arg a "$1" --arg m "$2" --arg p "$3" \
    '{tool_name:"Agent",tool_input:{subagent_type:$a,model:$m,prompt:$p}}' \
  | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null; }

echo "== W-REVIEW-FLOOR :: code-review agents are never dispatched at haiku =="

REVIEWERS="adversarial-panel-reviewer security-reviewer logic-reviewer codebase-fit-reviewer framework-pitfall-reviewer codex-adversarial-reviewer v-qa-reviewer"
allup=1; why=""
for a in $REVIEWERS; do
  r=$(fire "$a" haiku "Review the diff.")
  [ "$r" = "sonnet" ] || { allup=0; why="$a -> '${r:-<untouched>}'"; break; }
done
[ "$allup" -eq 1 ] && ok "every code-review agent passed model=haiku is upgraded to sonnet" \
                   || no "code-review agent upgraded off haiku" "sonnet for all 7" "$why"

# The specific agent from the incident report.
r=$(fire adversarial-panel-reviewer haiku "Review the spend guard")
[ "$r" = "sonnet" ] && ok "REGRESSION PIN: the reported case (adversarial-panel-reviewer + haiku) -> sonnet" \
                    || no "reported case upgraded" "sonnet" "${r:-<untouched>}"

# Idempotence: an already-correct dispatch must not be rewritten (no churn, no updatedInput).
r=$(fire security-reviewer sonnet "Review the diff.")
[ -z "$r" ] && ok "an already-sonnet review dispatch is left untouched (no needless rewrite)" \
            || no "sonnet dispatch left untouched" "(no updatedInput)" "$r"

# Never DOWN-tier: opus/fable are out of policy but this hook must not be the thing that lowers
# a review below sonnet. It only ever raises haiku.
r=$(fire logic-reviewer opus "Review the diff.")
case "$r" in
  haiku) no "never down-tiers a review below sonnet" "not haiku" "haiku" ;;
  *)     ok "a non-haiku review model is never lowered to haiku by this layer" ;;
esac

# An omitted model must not be forced: frontmatter should govern (every reviewer declares sonnet).
r=$(fire logic-reviewer "" "Review the diff.")
[ "$r" != "haiku" ] && ok "omitted model is not forced to haiku (frontmatter governs)" \
                    || no "omitted model not forced to haiku" "not haiku" "haiku"

echo
echo "== mechanical runners stay haiku (Layers 1-2 intact) =="
# These execute gates and report; they do not judge code. The dispatch prompt — not the agent name
# — is what Layer 2 keys on, so drive it the same way Layer 2 sees it.
r=$(fire v-pre-flight-runner sonnet "You are v-pre-flight. Run the gates.")
[ "$r" = "haiku" ] && ok "v-pre-flight-runner is still pinned to haiku (mechanical)" \
                   || no "v-pre-flight pinned to haiku" "haiku" "${r:-<untouched>}"
r=$(fire v-verify-done-runner sonnet "You are v-verify-done. Check conventions.")
[ "$r" = "haiku" ] && ok "v-verify-done-runner is still pinned to haiku (mechanical)" \
                   || no "v-verify-done pinned to haiku" "haiku" "${r:-<untouched>}"
# The documented sonnet escape hatch for verify-done must survive.
r=$(VERIFY_DONE_MODEL_OVERRIDE=sonnet fire v-verify-done-runner haiku "You are v-verify-done. Check conventions.")
[ "$r" = "sonnet" ] && ok "VERIFY_DONE_MODEL_OVERRIDE=sonnet still honored (W13-2)" \
                    || no "verify-done sonnet override honored" "sonnet" "${r:-<untouched>}"

# A non-review, non-runner agent must be left entirely alone.
r=$(fire general-purpose haiku "Find the config file.")
[ -z "$r" ] && ok "an unrelated agent is untouched (no blanket rewrite)" \
            || no "unrelated agent untouched" "(no updatedInput)" "$r"

# Nothing here may turn into a BLOCK: this layer corrects, it never denies.
d=$(decision adversarial-panel-reviewer haiku "Review the diff.")
[ "$d" != "deny" ] && ok "the floor corrects the model, it never DENIES the dispatch" \
                   || no "floor never denies" "allow" "deny"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
