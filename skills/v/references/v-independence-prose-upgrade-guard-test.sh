#!/usr/bin/env bash
# v-independence-prose-upgrade-guard-test.sh — H4-8 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: a production session iterated AGENT_REVIEW wording specifically to avoid the W59-F2
# inline-admission regex ("carefully avoiding phrasing that would trip…") until
# _independence_verdict said "dispatched". Auditing hooks/lib/validation.sh's CURRENT
# _independence_verdict shows only TWO emission sites for the "dispatched" verdict — both gated
# behind a witness check (_agent_was_dispatched, or _fallback_reviewer_dispatched for the codex
# fallback path); no prose-only branch can produce "dispatched". This PINS that invariant with an
# explicit adversarial fixture: an artifact worded to dodge every known inline-admission phrase,
# with ZERO backing DISPATCH_PROVENANCE/transcript/proxy evidence, must NOT resolve to "dispatched".
#
# This is a VERIFICATION test (H4-8 was found already closed by prior fixes — A-1b/B-2/B-FALLBACK,
# 2026-06-15/17) — it pins the invariant against regression rather than proving a NEW fix, so there
# is no red/green fix-pair; it documents + locks in the already-correct behavior.
set -uo pipefail
LIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }
[ -f "$LIB" ] || { echo "FATAL: validation.sh missing"; exit 2; }

echo "== H4-8 :: prose alone cannot upgrade the independence verdict to 'dispatched' =="

# Structural pin: exactly the three witness-gated emission sites, nothing else.
# RAISED 2→3 on 2026-08-03 for the PANEL branch. This count is deliberately hard to change: it exists
# so a new 'dispatched' path cannot be added without someone re-justifying that it is WITNESS-GATED.
# The third site qualifies — it is reached only when `_panel_was_dispatched "$_pnl_n"` confirms >= N
# DISTINCT `status=ok` DISPATCH_PROVENANCE rows, i.e. the declared panel size is backed by real
# dispatch records. It is also ordered AFTER the forgery + wrong-tree 'silent' branches, so it cannot
# rescue a fabricated "codex … ran" claim. Behavioural proof that prose alone still cannot reach it:
# hooks/lib/panel-review-validation-test.sh — "unbacked panel claim does NOT resolve dispatched".
# If you are here because the count moved to 4: prove the new site is witness-gated, or revert it.
_n_dispatched=$(grep -cE '^\s*echo "dispatched"; return' "$LIB")
[ "$_n_dispatched" -eq 3 ] \
  && ok "exactly 3 'dispatched' emission sites in validation.sh (all witness-gated)" \
  || no "expected exactly 3 'dispatched' emission sites" "found $_n_dispatched"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
SID="ffeeddcc-1111-4222-8333-444455556666"

# Adversarial fixture: mentions "dispatched" and "ran" in language carefully NOT matching any of
# _independence_verdict's admission/forgery regexes (no 'Dispatch mode:' field, no bare
# 'codex adversarial reviewer: ... ran', no 'ran from main' phrasing) — the observed evasion shape.
cat > "$TMP/AGENT_REVIEW_${SID}.md" <<EOF
Model: haiku

## Agent Review — ${SID}

The adversarial review process was completed and the changes were thoroughly examined by our
review pipeline before this artifact was produced. Everything checked out fine and the team is
confident in the quality of this change after a careful look-through.

## Findings

No issues found.
EOF

( . "$LIB"
  SESSION_ID="$SID"
  ARTIFACT_SEARCH_DIRS=("$TMP")
  TRANSCRIPT_READABLE=0
  _TX_SIGNALS=""
  _independence_verdict "$TMP/AGENT_REVIEW_${SID}.md" "codex-adversarial-reviewer"
) > "$TMP/verdict.out" 2>/dev/null
VERDICT=$(cat "$TMP/verdict.out")
[ "$VERDICT" != "dispatched" ] \
  && ok "adversarial evasive-prose fixture (no witness) does NOT resolve to 'dispatched' (got: $VERDICT)" \
  || no "evasive prose upgraded the verdict to 'dispatched' with zero witness evidence" "$VERDICT"

# FP-safe control: the SAME wording, but with a REAL DISPATCH_PROVENANCE witness present -> MUST
# resolve to 'dispatched' (the fix must never over-tighten and block a genuinely independent review).
printf 'DISPATCH|ts=2026-07-02T20:00:00Z|agent=codex-adversarial-reviewer|mode=codex_cli|status=ok|submodel=gpt-5.5|cost_usd=0.10|duration_ms=45000|artifact=%s|sha256=%s\n' \
  "AGENT_REVIEW_${SID}.md" "$(shasum -a 256 "$TMP/AGENT_REVIEW_${SID}.md" 2>/dev/null | awk '{print $1}')" \
  > "$TMP/DISPATCH_PROVENANCE_${SID}.log"
( . "$LIB"
  SESSION_ID="$SID"
  ARTIFACT_SEARCH_DIRS=("$TMP")
  TRANSCRIPT_READABLE=0
  _TX_SIGNALS=""
  _independence_verdict "$TMP/AGENT_REVIEW_${SID}.md" "codex-adversarial-reviewer"
) > "$TMP/verdict2.out" 2>/dev/null
VERDICT2=$(cat "$TMP/verdict2.out")
[ "$VERDICT2" = "dispatched" ] \
  && ok "FP-safe: the SAME wording WITH a real DISPATCH_PROVENANCE witness -> 'dispatched' (not over-tightened)" \
  || no "FP: a genuine witness-backed dispatch should resolve to 'dispatched'" "$VERDICT2"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
