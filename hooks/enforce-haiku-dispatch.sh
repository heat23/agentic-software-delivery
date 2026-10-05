#!/usr/bin/env bash
# enforce-haiku-dispatch.sh
# COST OPTIMIZATION HOOK — P1
# Event: PreToolUse/Skill|Agent
# Version: 4.1.0   ← W24 friction-reduction: HOOK-7 message points at v-emit-prompt.sh
#
# Three enforcement layers:
#   1. Block Skill tool invocations of the haiku-designated gate runners (the Skill tool runs
#      inline on the session's own model)
#   2. Silently fix the Agent tool's model param to "haiku" for those runners, via updatedInput
#   3. Raise a haiku dispatch to sonnet for 7 named review agents (never lowers, never denies)
#
# v4.1 changes:
#   HOOK-7 (W24): Layer 1 deny-message rewritten. Previous text told the
#                 orchestrator to "extract the canonical prompt from /v SKILL.md
#                 § Appendix A.{1,2,3} via bash" — but Appendix A was externalized
#                 in W12 to v/references/dispatch-*.md. Sessions following the
#                 stale instructions ran improvised `sed -n '/^## Appendix A/...'`
#                 pipelines that produced empty / wrong output. The new message
#                 names a single helper script that does extraction + substitution
#                 + validation in one call. Zero sed-improvisation surface.
#
# v4 changes (prior):
#   HOOK-3: Layer 2 prompt-detection regex now matches `You are v-{skill}` (the
#           actual W9 dispatch prompt header) instead of `running v-{skill}`
#           (which never appears in real prompts — Layer 2 silently never fired).
#   HOOK-7: Error message points users at /v SKILL.md § Verbatim Dispatch Mechanism
#           (Wave 9 inlined the dispatch prompts; sibling DISPATCH_PROMPT.md files
#           are deprecated stubs). Superseded by v4.1 helper-pointing message.
#   HOOK-10: Honor VERIFY_DONE_MODEL_OVERRIDE env var per W13-2 (verify-done can
#            run at sonnet for full-mode/large-diff sessions).

set -euo pipefail


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

# ── Layer 1: Block Skill tool for haiku-designated skills ──────────────────
# The Skill tool runs inline on the session model — it CANNOT be downgraded.
# Must redirect to Agent tool with model: haiku.
if [[ "$TOOL_NAME" == "Skill" ]]; then
  SKILL_NAME=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')
  case "$SKILL_NAME" in
    v-pre-flight|v-verify-done|v-handoff)
      # HOOK-7 (W24): name the single-call helper — eliminates improvised
      # multi-step bash that produced wrong output in prior sessions.
      REASON="BLOCKED: '${SKILL_NAME}' must be dispatched via Agent tool, not Skill tool (Skill runs inline on the session model = sonnet/opus, defeating the haiku cost split). Use the W24 single-call helper:

  bash ~/.claude/skills/v/references/v-emit-prompt.sh ${SKILL_NAME} > \"\$DISPATCH_FILE\"

then dispatch:

  Agent(model: \"haiku\", timeout: 600000, prompt: <Read result of \$DISPATCH_FILE>)

The helper handles SID resolution, MODE selection, sed substitution, and sentinel checks in one call. Full protocol: /v SKILL.md § Verbatim Dispatch Mechanism (D1–D3). Do NOT improvise multi-step extraction — earlier sessions ran stale 'sed -n /^## Appendix A/' patterns that produced empty output (W12 externalized those prompts to v/references/dispatch-<skill>.md)."
      jq -n --arg reason "$REASON" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
      ;;
  esac
  exit 0
fi

# ── Layer 2: Auto-fix Agent tool model param for haiku skills ──────────────
# Instead of blocking and making the model retry, silently correct the model
# parameter via updatedInput. Zero friction, guaranteed compliance.
if [[ "$TOOL_NAME" == "Agent" ]]; then
  PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty' 2>/dev/null) || exit 0
  MODEL=$(echo "$INPUT" | jq -r '.tool_input.model // empty' 2>/dev/null) || exit 0

  # HOOK-3: match prompts that are DISPATCH prompts for haiku skills.
  # The actual dispatch prompts (now in v/references/dispatch-*.md, formerly
  # /v SKILL.md Appendix A) start with "You are v-pre-flight" / "You are
  # v-verify-done" / "You are v-handoff" on their first line. The previous
  # v3.x check looked for "running v-{skill}" which never appears — so Layer 2
  # silently never fired and sonnet sessions could dispatch v-pre-flight at
  # any model.
  HAIKU_SKILL_MATCH=""
  FIRST_LINES=$(echo "$PROMPT" | head -3)
  for skill in v-pre-flight v-verify-done v-handoff; do
    if echo "$FIRST_LINES" | grep -qE "^You are ${skill}\\b"; then
      HAIKU_SKILL_MATCH="$skill"
      break
    fi
  done

  if [[ -n "$HAIKU_SKILL_MATCH" ]]; then
    # HOOK-10: VERIFY_DONE_MODEL_OVERRIDE env var honoring (W13-2).
    # When the orchestrator wants a sonnet verify-done for full-mode or
    # large-diff sessions, it sets VERIFY_DONE_MODEL_OVERRIDE=sonnet.
    # Per W13-2 deferred work: only verify-done is overridable; pre-flight and
    # handoff stay haiku regardless (mechanical work).
    # ND-0716: `opus` REMOVED from the whitelist — HOOK-10 predates the 2026-07-07
    # sonnet-max policy (CLAUDE.md Model Policy: ALL gate/review dispatches are
    # Sonnet 5 + Haiku ONLY) and was never updated; an env var could push a GATE
    # dispatch to opus. opus now falls through as unrecognized → haiku default.
    EFFECTIVE_MODEL="haiku"
    if [[ "$HAIKU_SKILL_MATCH" == "v-verify-done" ]] && [[ -n "${VERIFY_DONE_MODEL_OVERRIDE:-}" ]]; then
      case "${VERIFY_DONE_MODEL_OVERRIDE}" in
        haiku|sonnet)
          EFFECTIVE_MODEL="${VERIFY_DONE_MODEL_OVERRIDE}"
          ;;
        *)
          # Unrecognized override (incl. opus/fable — sonnet-max) — default (haiku).
          ;;
      esac
    fi

    if [[ "$MODEL" != "$EFFECTIVE_MODEL" ]]; then
      # Auto-correct: allow the call but override model via updatedInput.
      # Defensive: echo ALL original tool_input fields with only model changed,
      # in case updatedInput uses replace semantics instead of merge.
      UPDATED=$(echo "$INPUT" | jq --arg m "$EFFECTIVE_MODEL" '.tool_input | .model = $m')
      jq -n --argjson updated "$UPDATED" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":$updated}}'
      exit 0
    fi
  fi

  # ── Layer 3: review-model FLOOR (W-REVIEW-FLOOR, 2026-08-06) ──────────────
  # Layers 1-2 stop a MECHANICAL runner from being dispatched too EXPENSIVELY. This layer is the
  # mirror image: it stops a CODE-REVIEW agent from being dispatched too CHEAPLY.
  #
  # Owner decision, 2026-08-06: haiku is not suitable for reviewing product code. The agents already declared
  # `model: sonnet` in their frontmatter — but the Agent tool's `model` PARAMETER overrides
  # frontmatter, and CLAUDE.md instructed "Dispatch review agents with model: haiku". Declaration
  # said sonnet, dispatch said haiku, and nothing reconciled them.
  #
  # The DISPATCH_PROVENANCE witness shows this was systemic, not one agent — every reviewer had
  # run on haiku: adversarial-panel 10, codex-adversarial 11, logic 8, codebase-fit 6 of 28, qa 9,
  # workflow-verifier 6, and security-reviewer 7 of 50 (the agent covering auth, payments and data
  # exposure). CLAUDE.md is fixed, but prose is advisory and drifts; this is the enforcement.
  #
  # WHY HERE AND NOT IN THE TIER HARNESS: v-review-model-tier-test.sh asserts each agent's
  # FRONTMATTER. Frontmatter is a declaration; the violation happens at dispatch. A static
  # assertion cannot observe a runtime override, so it stayed green through every one of those
  # dispatches. Enforce the property where it is DECIDED.
  #
  # Deliberately narrow: it only ever RAISES haiku to sonnet for a fixed list of review agents. It
  # never lowers a model, never denies a call, never touches the mechanical runners (they are
  # matched by Layer 2 above, which returns first), and leaves an omitted model alone so each
  # agent's own frontmatter governs. Sonnet remains the CAP — this opens no opus path.
  # Bite: hooks/review-model-floor-test.sh
  SUBAGENT=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null) || exit 0
  if [[ "$MODEL" == "haiku" ]]; then
    case "$SUBAGENT" in
      adversarial-panel-reviewer|security-reviewer|logic-reviewer|codebase-fit-reviewer|\
      framework-pitfall-reviewer|codex-adversarial-reviewer|v-qa-reviewer)
        UPDATED=$(echo "$INPUT" | jq '.tool_input | .model = "sonnet"')
        jq -n --argjson updated "$UPDATED" \
          '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":$updated}}'
        exit 0
        ;;
    esac
  fi
  exit 0
fi

# All other tools — allow
exit 0
