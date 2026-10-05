#!/usr/bin/env bash
# v-emit-agent-review-skeleton.sh — SKELETON-GEN (2026-06-30).
#
# WHY: AGENT_REVIEW is the ONLY gauntlet artifact with no valid-on-arrival skeleton (PRE_FLIGHT/QA/VERIFY/
# IMPACT/UX/WF all have one). So the orchestrator hunts the 8-field template, parses DISPATCH_PROVENANCE for the
# Dispatch-mode/Codex/Reviewer-model fields, runs AREV-MODEL-AUTOFORCE, then hand-writes — ~5-9 turns of ceremony,
# and if it edits a sha-bound dispatched artifact it trips W5G-4. This emits a skeleton that PASSES
# validate_review_semantics on arrival (Model: haiku, Status, SID, the 6 required fields, an evidence marker,
# `## Findings`), with the Dispatch-mode DERIVED from the real DISPATCH_PROVENANCE. The model only fills the
# `## Findings` section (which is NOT sha-bound — no dispatcher ever bound it), so W5G-4 cannot fire.
#
# SAFETY (independence is NOT forgeable here): the emitted `Dispatch mode:` is a CLAIM that the Stop hook
# independently re-verifies via _agent_was_dispatched (a real SID-scoped status=ok provenance line). This script
# emits `foreground` ONLY when such a line exists for a *reviewer* agent; otherwise it emits `orchestrator_inline`
# (honest). It never manufactures a gate pass — a no-reviewer run yields orchestrator_inline, which the gate then
# routes through its declared/superpowers check.
#
# Usage: v-emit-agent-review-skeleton.sh --sid <uuid> [--provenance-log <path>] [--out <file>]
set -uo pipefail

SID="" ; PROV="" ; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sid) SID="${2:-}"; shift 2 || exit 1 ;;
    --provenance-log) PROV="${2:-}"; shift 2 || exit 1 ;;
    --out) OUT="${2:-}"; shift 2 || exit 1 ;;
    *) echo "v-emit-agent-review-skeleton: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
[ -n "$SID" ] || { echo "v-emit-agent-review-skeleton: --sid required" >&2; exit 1; }

# Locate the SID-scoped provenance log (same search shape as validation.sh _agent_was_dispatched).
_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}")"
if [ -z "$PROV" ] || [ ! -f "$PROV" ]; then
  for _d in "$_root/.v/artifacts" "$_root" "$_root/.v/tmp"; do
    [ -f "$_d/DISPATCH_PROVENANCE_${SID}.log" ] && { PROV="$_d/DISPATCH_PROVENANCE_${SID}.log"; break; }
  done
fi

# ── Hostile adversarial focus: DERIVED from the canonical predicate, never hand-judged ──────────────
# H4-6 DRIFT FIX (2026-07-12, forensic): this line used to be a hardcoded `no` with an
# "UPDATE to 'yes' if..." comment — a hand-judgment invitation, the exact drift class
# v-hostile-required.sh (H4-5) exists to kill. A pack session hand-judged `no` on a diff the canonical
# predicate scores HOSTILE_REQUIRED=1 (admin controller paths), the artifact passed every presence
# check, and the branch then stranded at the merge W-GATE's Stop-grade semantic re-validation (H4-6)
# with "hostile adversarial focus required but not declared" — an unattended-run deadlock no later
# automation could clear. Derive the field HERE from the SAME predicate the Stop hook and merge gate
# enforce. Degrades toward `yes` (stricter) when the predicate is unavailable, mirroring
# v-hostile-required.sh's own fail-toward-safer contract. NOTE: `yes` also obligates the session to
# actually dispatch reviewers WITH hostile focus (W59-F2) — the skeleton makes the declaration
# truthful; the dispatch obligation is the orchestrator's.
HOSTILE_LINE="yes — v-hostile-required.sh unavailable; fail-strict (treat diff as hostile)"
_hrscript="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/v-hostile-required.sh"
[ -f "$_hrscript" ] || _hrscript="$HOME/.claude/skills/v/references/v-hostile-required.sh"
if [ -f "$_hrscript" ]; then
  _hr_out="$(bash "$_hrscript" --sid "$SID" --worktree-root "$_root" 2>/dev/null)"
  _hr_req="$(printf '%s\n' "$_hr_out" | grep -m1 '^HOSTILE_REQUIRED=' | cut -d= -f2)"
  if [ "$_hr_req" = "1" ]; then
    _hr_paths="$(printf '%s\n' "$_hr_out" | sed -n '/^=== HOSTILE_PATHS ===$/,/^=== END_HOSTILE_PATHS ===$/p' | grep -v '^===' | grep -v '^NONE$' | head -4 | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    HOSTILE_LINE="yes — v-hostile-required.sh: HOSTILE_REQUIRED=1${_hr_paths:+ (${_hr_paths})}"
  elif [ "$_hr_req" = "0" ]; then
    HOSTILE_LINE="no — v-hostile-required.sh: HOSTILE_REQUIRED=0 (canonical H4-5 predicate)"
  fi
fi

# A reviewer agent is any of these (NOT the gate runners — those produce other artifacts).
_REVIEWERS='codex-adversarial-reviewer|logic-reviewer|security-reviewer|codebase-fit-reviewer|framework-pitfall-reviewer|adversarial-panel-reviewer'

DISPATCH_MODE="orchestrator_inline"   # honest default — only upgraded with a real status=ok reviewer line
CODEX_STATUS="codex-adversarial-reviewer (orchestrator-inline fallback)"
REVIEWER_MODEL="sonnet"               # W13 floor
DISPATCHED="codex-adversarial-reviewer"
PANEL_LINE=""                         # emitted only when >=2 distinct reviewers really dispatched

if [ -n "$PROV" ] && [ -f "$PROV" ]; then
  # A real reviewer dispatch on record (status=ok, not the orchestrator's own mode=agent-self) ⇒ foreground.
  # SREV-002: order-strict match (parity with validation.sh:_agent_was_dispatched `agent=X|mode=...|status=ok`) so a
  # malformed/reordered line can't yield a more-optimistic mode here than the gate's independent re-verification.
  # LEVER1-SREV (2026-06-30 review): exclude mode=agent-self AND any future -suffix variant. Today only the exact
  # `mode=agent-self` is ever written (grep-verified), so this is behavior-identical now; it just makes the
  # skeleton STRICTLY MORE conservative (a variant → orchestrator_inline, never a forged foreground), which
  # preserves the SREV-002 intent (skeleton is never MORE optimistic than the gate). NOTE: the Stop hook's own
  # independence predicate (validation.sh:803) uses the exact-match form; hardening THAT is a separate gate change
  # deliberately NOT made here (touches the core Stop predicate — out of scope for this low-risk lever).
  if grep -E "agent=(${_REVIEWERS})\|mode=[^|]*\|status=ok" "$PROV" 2>/dev/null | grep -qvE '\|mode=agent-self(-[a-z0-9]+)?\|'; then
    DISPATCH_MODE="foreground"
  fi
  # Codex line specifically.
  # PLACEHOLDER FIX (2026-08-03): this used to emit the literal string
  #   "ran — N candidates, N accepted, N rejected   # FILL N from adjudication"
  # — an unfilled template that the validator's substring grep happily accepted. Corpus sweep found
  # that exact placeholder still sitting in 4 on-disk AGENT_REVIEW drafts, i.e. the skeleton was
  # manufacturing the very unverifiable-prose class the gate is supposed to stop. Emit an HONEST,
  # placeholder-free statement of what provenance actually shows instead; the machine-checkable
  # `Adversarial review:` panel field below is what the gate now verifies.
  # W59-F2 INTERACTION (found by live-fire 2026-08-03, before ship): the default CODEX_STATUS says
  # "(orchestrator-inline fallback)". On a HOSTILE-path session that string made the Stop gate conclude
  # an INLINE review had happened — and BLOCK — even though two real subagent panel members had been
  # dispatched and recorded. The elif below only recognised logic/security reviewers, so a pure
  # adversarial-panel-reviewer run fell through to the misleading default. A false block here is
  # exactly what induces hand-editing of the provenance line, i.e. the fabrication loop this whole
  # change exists to end. Match the FULL reviewer roster so any genuine independent dispatch produces
  # an honest, inline-free line.
  if grep -E 'agent=codex-adversarial-reviewer\|' "$PROV" 2>/dev/null | grep -qE '\|status=ok\b'; then
    CODEX_STATUS="ran — see the panel field and Findings below for the adjudicated counts"
  elif grep -E "agent=(${_REVIEWERS})\|" "$PROV" 2>/dev/null | grep -E '\|status=ok\b' | grep -qvE '\|mode=agent-self(-[a-z0-9]+)?\|'; then
    CODEX_STATUS="codex not used — independent reviewer panel dispatched instead (see panel field)"
  fi
  # Reviewer model from the submodel= field of any status=ok reviewer line.
  _m="$(grep -E "agent=(${_REVIEWERS})\|" "$PROV" 2>/dev/null | grep -E '\|status=ok\b' | grep -oE 'submodel=[^|]+' | head -1 | sed 's/submodel=//')"
  [ -n "$_m" ] && REVIEWER_MODEL="$_m"
  # All dispatched reviewer agents (status=ok, exclude agent-self).
  _agents="$(grep -E "agent=(${_REVIEWERS})\|" "$PROV" 2>/dev/null | grep -E '\|status=ok\b' | grep -vE '\|mode=agent-self\b' | grep -oE 'agent=[^|]+' | sed 's/agent=//' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  [ -n "$_agents" ] && DISPATCHED="$_agents"

  # ── PANEL field (2026-08-03) — DERIVED, never hand-written ──────────────────────────────────────
  # panel/models/lenses come straight from the real status=ok dispatch rows, so the emitted size is
  # backed by construction (validation.sh:_panel_was_dispatched re-verifies it independently at the
  # gate). candidates/accepted/refuted start at 0 because adjudication has not happened yet at
  # skeleton time; the orchestrator updates them when it pastes Findings. That is deliberately NOT a
  # `# FILL` placeholder — 0/0/0 is a valid, honest, self-consistent state ("no candidates recorded"),
  # and validate_review_semantics blocks the stale case by cross-checking candidates=0 against any
  # finding IDs present in the body.
  # MEMBERSHIP IS KEYED ON `artifact=`, NOT `agent=` (fixed 2026-08-03 by live-fire, before ship).
  # A panel is ONE agent (adversarial-panel-reviewer) dispatched N times with DIFFERENT LENSES, so all
  # N rows share the same agent= value. Keying on agent name scored a real 2-lens run as 1 member and
  # emitted NO panel field at all — verified live against two real `claude -p --agent` dispatches.
  # Each member writes its own --artifact, so distinct artifacts == distinct members. The LENS comes
  # from the artifact basename (`panel-<lens>-<sid>.md`, the dispatch convention in v-agent-review.md);
  # non-panel reviewers fall back to their agent-name mapping. Mirrors validation.sh:_panel_was_dispatched.
  _panel_rows="$(grep -E "agent=(${_REVIEWERS})\|" "$PROV" 2>/dev/null | grep -E '\|status=ok\b' \
    | grep -vE '\|mode=agent-self(-[a-z0-9]+)?\|')"
  _panel_arts="$(printf '%s\n' "$_panel_rows" | grep -oE '\|artifact=[^|]+' | sed 's/|artifact=//' | grep . | sort -u)"
  _pn="$(printf '%s\n' "$_panel_arts" | grep -c .)"
  if [ "${_pn:-0}" -ge 2 ]; then
    _pmodels=""; _plenses=""
    while IFS= read -r _art; do
      [ -n "$_art" ] || continue
      _row="$(printf '%s\n' "$_panel_rows" | grep -F "|artifact=${_art}" | head -1)"
      _am="$(printf '%s' "$_row" | grep -oE 'submodel=[^|]*' | head -1 | sed 's/submodel=//')"
      case "$_am" in ""|unknown) _am="sonnet" ;; esac
      _a="$(printf '%s' "$_row" | grep -oE 'agent=[^|]+' | head -1 | sed 's/agent=//')"
      # Lens from the artifact name first — that is what actually distinguishes panel members.
      _al="$(printf '%s' "$_art" | sed -nE 's/^panel-([a-z]+)-.*/\1/p')"
      if [ -z "$_al" ]; then
        case "$_a" in
          logic-reviewer)             _al="correctness" ;;
          security-reviewer)          _al="security" ;;
          codebase-fit-reviewer)      _al="fit" ;;
          framework-pitfall-reviewer) _al="framework" ;;
          codex-adversarial-reviewer) _al="adversarial" ;;
          *)                          _al="review" ;;
        esac
      fi
      _pmodels="${_pmodels}${_pmodels:+,}${_am}"
      _plenses="${_plenses}${_plenses:+,}${_al}"
    done <<PANEL_ARTS
$_panel_arts
PANEL_ARTS
    # >=2 DISTINCT lenses is a hard validity rule; if the dispatched set collapsed to one lens the
    # field would be rejected, so emit nothing rather than an invalid line (the legacy codex field
    # still satisfies the required slot in that case).
    if [ "$(printf '%s' "$_plenses" | tr ',' '\n' | sort -u | grep -c .)" -ge 2 ]; then
      PANEL_LINE="panel=${_pn} models=${_pmodels} lenses=${_plenses} candidates=0 accepted=0 refuted=0"
    fi
  fi
fi

_emit() {
  cat <<SKEL
Model: sonnet

## Agent Review — ${SID}
- Status: completed
- Agents directory: ${AGENTS_DIR:-$HOME/.claude/agents}
- Agents dispatched: ${DISPATCHED}
- Codex adversarial reviewer: ${CODEX_STATUS}${PANEL_LINE:+
- Adversarial review: ${PANEL_LINE}   # UPDATE candidates/accepted/refuted after adjudication}
- Reviewer model: ${REVIEWER_MODEL}
- Hostile adversarial focus: ${HOSTILE_LINE}
- Dispatch mode: ${DISPATCH_MODE}
- Review evidence: codex_candidates: N   # FILL: replace N, or paste the CODEX-*/SREV-*/FND-* finding IDs
- Remediation: N findings fixed and re-verified   # FILL from adjudication; '0 — no findings' if clean

## Findings

<!-- Paste reviewer findings verbatim (severity + file:line + ACCEPT/MODIFY/REJECT). "No issues found." if zero. -->
SKEL
}

if [ -n "$OUT" ]; then _emit > "$OUT" && echo "v-emit-agent-review-skeleton: wrote $OUT (Dispatch mode: ${DISPATCH_MODE})"; else _emit; fi
