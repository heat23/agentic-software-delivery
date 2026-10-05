#!/usr/bin/env bash
# orch-r2-skeleton-test.sh — BITE for SKELETON-GEN v-emit-agent-review-skeleton.sh (2026-06-30).
# GREEN: emits a valid-on-arrival AGENT_REVIEW skeleton; NO provenance → orchestrator_inline (no forge);
# real codex status=ok → foreground. RED vs the pre-skeleton stub (.pre-r2-bak: exits non-zero, no output).
set -uo pipefail
SKEL="${V_SKEL_SCRIPT:-$HOME/.claude/skills/v/references/v-emit-agent-review-skeleton.sh}"
[ -f "$SKEL" ] || { echo "FAIL: skeleton script missing"; exit 2; }
SID="33333333-3333-4333-8333-333333333333"

# (1) NO provenance ⇒ orchestrator_inline (honest, never forges a dispatch claim).
OUT_NP="$(bash "$SKEL" --sid "$SID" --provenance-log /dev/null 2>/dev/null || true)"
printf '%s' "$OUT_NP" | grep -q '^- Dispatch mode: orchestrator_inline' \
  || { echo "FAIL: no-provenance did NOT yield orchestrator_inline (forge risk, or stub)"; exit 1; }

# (2) real codex status=ok ⇒ foreground + valid structure.
P="$(mktemp)"; printf 'DISPATCH|ts=x|agent=codex-adversarial-reviewer|mode=codex_cli|status=ok|submodel=claude-sonnet-4-6|sha256=z\n' > "$P"
OUT="$(bash "$SKEL" --sid "$SID" --provenance-log "$P" 2>/dev/null || true)"; rm -f "$P"
# 2026-08-06: was pinned to the literal `Model: haiku` on the belief that it is "the validator magic
# constant". That belief was STALE and is now disproven: validation.sh:60 sets
# ALLOWED_REVIEW_MODELS='haiku|sonnet|opus|fable' and :378 matches any of them, and a live
# validate_artifact() run over this skeleton's own sonnet output returns PASS. Pinning the literal
# meant the artifact DECLARED haiku while a sonnet reviewer actually ran — the same
# declaration-vs-decision split that let every reviewer run on haiku while its frontmatter said
# sonnet. Assert the PROPERTY (line 1 declares a policy-valid review model, and never haiku for a
# code review) instead of one spelling.
printf '%s' "$OUT" | head -1 | grep -qE '^Model: (sonnet|opus|fable)' \
  || { echo "FAIL: line 1 must declare a policy-valid CODE-REVIEW model (sonnet); got: $(printf '%s' "$OUT" | head -1)"; exit 1; }
printf '%s' "$OUT" | grep -q '^- Dispatch mode: foreground' || { echo "FAIL: codex ok did not yield foreground"; exit 1; }
for f in 'Status: completed' 'Agents dispatched:' 'Codex adversarial reviewer:' 'Hostile adversarial focus:' 'Dispatch mode:' 'Review evidence:' 'Remediation:'; do
  printf '%s' "$OUT" | grep -q "$f" || { echo "FAIL: missing required field: $f"; exit 1; }
done
printf '%s' "$OUT" | grep -qE '^## Findings' || { echo "FAIL: no ## Findings"; exit 1; }

# (3) LEVER1-SREV (2026-06-30 review): an agent's OWN tamper-baseline line (mode=agent-self, and any future
# -suffix variant) is NOT an independent dispatch ⇒ must stay orchestrator_inline. Guards against a self-record
# (or a variant typo) being forged into a `foreground` independence claim. The variant case also bites the
# line-52 widening (pre-widening, `agent-self-inline` slipped through → foreground).
for _self in 'agent-self' 'agent-self-inline'; do
  PS="$(mktemp)"; printf 'DISPATCH|ts=x|agent=codex-adversarial-reviewer|mode=%s|status=ok|submodel=sonnet|sha256=z\n' "$_self" > "$PS"
  OUT_S="$(bash "$SKEL" --sid "$SID" --provenance-log "$PS" 2>/dev/null || true)"; rm -f "$PS"
  printf '%s' "$OUT_S" | grep -q '^- Dispatch mode: orchestrator_inline' \
    || { echo "FAIL: mode=$_self (self-record) yielded a NON-inline mode — forge risk"; exit 1; }
done
echo "PASS (skeleton-gen): valid-on-arrival; no-prov→orchestrator_inline; codex→foreground; agent-self(+variant)→inline"
exit 0
