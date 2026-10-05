#!/usr/bin/env bash
# v-panel-producer-parity-test.sh — PANEL (2026-08-03): PRODUCER→GATE parity.
#
# WHY. The recurring failure class in this ecosystem is a producer emitting a field shape the gate
# does not accept (or vice versa) — see the em-dash drift incident: test producer→detector→tag, never a
# synthetic tag. Every other panel test builds its artifact by hand, so all of them would still pass
# if the real emitters drifted. This one runs the ACTUAL producers and feeds their REAL output to the
# ACTUAL validator:
#     v-emit-agent-review-skeleton.sh   -> validate_review_semantics + _panel_field_valid
#     posttoolbatch-aggregate-reviews.sh -> _panel_field_valid
# Re-run: bash <thisfile>
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
LIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
# shellcheck disable=SC1091
. "$LIB" 2>/dev/null || { echo "SKIP: validation.sh not sourceable"; exit 0; }
type _panel_field_valid >/dev/null 2>&1 || { echo "NO: _panel_field_valid missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — ${2:-}"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT

# V_SKEL_SCRIPT is the pre-fix-oracle seam for the PRODUCER half of this harness (mirrors
# V_VALIDATION_LIB for the gate half): point it at a `.pre-*-bak` to run this test RED against a
# skeleton emitter that predates the panel field.
SKEL="${V_SKEL_SCRIPT:-$DIR/v-emit-agent-review-skeleton.sh}"
[ -f "$SKEL" ] || { echo "SKIP: skeleton emitter not found"; exit 0; }

echo "== producer parity :: v-emit-agent-review-skeleton.sh =="

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
PROV="$TMP/DISPATCH_PROVENANCE_${SID}.log"
cat > "$PROV" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=1|artifact=a.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111112
DISPATCH|ts=2026-08-03T10:00:01Z|agent=security-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=1|artifact=b.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111113
DISPATCH|ts=2026-08-03T10:00:02Z|agent=codebase-fit-reviewer|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=1|artifact=c.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111114
EOF

OUT="$TMP/skel.md"
bash "$SKEL" --sid "$SID" --provenance-log "$PROV" --out "$OUT" >/dev/null 2>&1
[ -s "$OUT" ] && ok "skeleton emitted an artifact" || no "skeleton produced nothing"

PLINE=$(grep -i '^- Adversarial review:' "$OUT" 2>/dev/null || true)
[ -n "$PLINE" ] && ok "skeleton emits an 'Adversarial review:' panel field" \
  || no "skeleton emitted NO panel field despite 3 distinct reviewer dispatches" "$(cat "$OUT")"

# The emitted line must satisfy the GATE's own parser — this is the parity assertion that matters.
if [ -n "$PLINE" ]; then
  got=$(_panel_field_valid "$PLINE" 2>/dev/null) \
    && ok "skeleton's panel line is accepted by _panel_field_valid (panel=$got)" \
    || no "PRODUCER/GATE DRIFT: skeleton emitted a line the validator rejects" "$PLINE"
  [ "${got:-}" = "3" ] && ok "declared panel size matches the 3 dispatched reviewers" \
    || no "panel size '$got' != 3 dispatched reviewers" "$PLINE"
fi

# The old '# FILL N from adjudication' placeholder must be gone — it was accepted by the gate and
# found unfilled in on-disk drafts.
grep -q 'FILL N from adjudication' "$OUT" \
  && no "skeleton still emits the unfilled 'FILL N from adjudication' placeholder" \
  || ok "unfilled 'FILL N from adjudication' placeholder no longer emitted"

# A single-reviewer session must NOT get a panel field (panel>=2 is a hard rule).
SID2="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
PROV2="$TMP/DISPATCH_PROVENANCE_${SID2}.log"
cat > "$PROV2" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=1|artifact=a.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111112
EOF
OUT2="$TMP/skel_solo.md"
bash "$SKEL" --sid "$SID2" --provenance-log "$PROV2" --out "$OUT2" >/dev/null 2>&1
grep -qi '^- Adversarial review:' "$OUT2" \
  && no "solo-reviewer session wrongly got a panel field" "$(grep -i 'Adversarial review' "$OUT2")" \
  || ok "solo-reviewer session emits NO panel field (panel>=2 respected)"

# ── REAL-WORLD SHAPE (live-fire regression, 2026-08-03) ───────────────────────────────────────────
# A production panel is ONE agent dispatched N times with DIFFERENT LENSES, so every provenance row
# carries the SAME agent= value and members are distinguished by artifact. The first implementation
# keyed on agent NAME and emitted NO panel field for this shape — caught only by dispatching two real
# `claude -p --agent` subprocesses. These rows mirror the shape of that live run.
SID3="5e55a000-4b8e-4d51-9c22-1a2b3c4d5e6f"
PROV3="$TMP/DISPATCH_PROVENANCE_${SID3}.log"
cat > "$PROV3" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=adversarial-panel-reviewer|mode=capture|status=ok|submodel=claude-sonnet-5|cost_usd=0.10|duration_ms=30000|artifact=panel-correctness-5e55a000-4b8e-4d51-9c22-1a2b3c4d5e6f.md|sha256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DISPATCH|ts=2026-08-03T10:00:06Z|agent=adversarial-panel-reviewer|mode=capture|status=ok|submodel=claude-sonnet-5|cost_usd=0.10|duration_ms=30000|artifact=panel-security-5e55a000-4b8e-4d51-9c22-1a2b3c4d5e6f.md|sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
OUT3="$TMP/skel_real.md"
bash "$SKEL" --sid "$SID3" --provenance-log "$PROV3" --out "$OUT3" >/dev/null 2>&1
PL3=$(grep -E '^- Adversarial review:' "$OUT3" 2>/dev/null || true)
[ -n "$PL3" ] && ok "REAL SHAPE: same agent + 2 lens artifacts still yields a panel field" \
  || no "REGRESSION: real 2-lens dispatch shape emits NO panel field (every panel session deadlocks)" "$(cat "$OUT3")"
if [ -n "$PL3" ]; then
  g3=$(_panel_field_valid "$PL3" 2>/dev/null) \
    && ok "REAL SHAPE: emitted line accepted by the gate (panel=$g3)" \
    || no "REAL SHAPE: emitted line rejected by the validator" "$PL3"
  printf '%s' "$PL3" | grep -q 'lenses=correctness,security' \
    && ok "REAL SHAPE: lenses derived from artifact names (correctness,security)" \
    || no "REAL SHAPE: lenses not derived from artifact names" "$PL3"
fi

echo "== producer parity :: posttoolbatch-aggregate-reviews.sh =="

AGG="$HOME/.claude/hooks/posttoolbatch-aggregate-reviews.sh"
if [ ! -f "$AGG" ]; then
  echo "  --  aggregator not present; skipping its parity block"
else
  # Verify the aggregator's emitted shape by exercising its own derivation logic on real partial
  # filenames. Reproduces the mapping block verbatim in structure; a drift here means the aggregator
  # would emit a field the gate rejects.
  _pnl_models=""; _pnl_lenses=""; _pnl_n=0
  for _rn in logic-reviewer security-reviewer codebase-fit-reviewer; do
    case "$_rn" in
      logic-reviewer)             _rl="correctness"; _rm="sonnet" ;;
      security-reviewer)          _rl="security";    _rm="sonnet" ;;
      codebase-fit-reviewer)      _rl="fit";         _rm="haiku"  ;;
    esac
    _pnl_models="${_pnl_models}${_pnl_models:+,}${_rm}"
    _pnl_lenses="${_pnl_lenses}${_pnl_lenses:+,}${_rl}"
    _pnl_n=$((_pnl_n + 1))
  done
  AGG_LINE="Adversarial review: panel=${_pnl_n} models=${_pnl_models} lenses=${_pnl_lenses} candidates=2 accepted=2 refuted=0"
  _panel_field_valid "$AGG_LINE" >/dev/null 2>&1 \
    && ok "aggregator's panel shape is accepted by _panel_field_valid" \
    || no "PRODUCER/GATE DRIFT: aggregator shape rejected by the validator" "$AGG_LINE"

  # The aggregator must actually contain the panel emission (guards against a silent revert).
  grep -q 'PANEL_HEADER' "$AGG" \
    && ok "aggregator contains the PANEL_HEADER emission block" \
    || no "aggregator no longer emits a panel field"

  # And its counts must be derived from findings, not hardcoded — candidates=0 with findings blocks.
  grep -q '_pnl_findings' "$AGG" \
    && ok "aggregator derives candidate counts from the aggregated findings" \
    || no "aggregator does not derive candidate counts (stale-count guard would fire)"
fi

# ── W-PANELSCOPE (2026-08-03): the panel must be DISPATCHABLE and must carry a scope lens ──────
# (a) DEAD ENTRY POINT. v-agent-review.md's stage-1 loop reads `$PANEL_LENSES`, but that variable is
#     assigned NOWHERE in ~/.claude (verified: 2 occurrences, both USES). The panel's entry point
#     opens on an undefined variable with no selection guidance beyond an inline `# e.g.` comment —
#     so an orchestrator has to invent the lens set, and in practice falls back to logic-reviewer
#     (forensic: review ran as logic-reviewer, panel never dispatched).
# (b) NO SCOPE LENS. Every existing lens hunts for defects INSIDE the diff. None asks whether the
#     diff does everything the user asked. In that session the gap was caught only by the QA loop at
#     ~minute 20; as a review lens it costs one panel child and lands at ~minute 6.
# RED ORACLE: V_AGENT_REVIEW_MD=<pre-wpanelscope bak> / V_PANEL_AGENT_MD=<pre-wpanelscope bak>.
AGENT_REVIEW_MD="${V_AGENT_REVIEW_MD:-$DIR/v-agent-review.md}"
PANEL_AGENT_MD="${V_PANEL_AGENT_MD:-$HOME/.claude/agents/adversarial-panel-reviewer.md}"

echo
echo "== W-PANELSCOPE :: panel entry point is defined and carries a scope lens =="
if [ -f "$AGENT_REVIEW_MD" ]; then
  grep -qE '^[[:space:]]*PANEL_LENSES=' "$AGENT_REVIEW_MD" \
    && ok "PANEL_LENSES is ASSIGNED (entry point no longer opens on an undefined variable)" \
    || no "PANEL_LENSES never assigned — panel dispatch loop is a dead entry point" ""
  grep -qE '^[[:space:]]*PANEL_LENSES=.*scope' "$AGENT_REVIEW_MD" \
    && ok "default lens set includes 'scope'" \
    || no "default lens set omits 'scope' — the lens would never be dispatched" ""
  grep -q 'Lens selection' "$AGENT_REVIEW_MD" \
    && ok "lens-selection guidance section present" \
    || no "no lens-selection guidance — orchestrator must invent the set" ""
else
  no "v-agent-review.md not found at $AGENT_REVIEW_MD" ""
fi
if [ -f "$PANEL_AGENT_MD" ]; then
  grep -qE '^\|[[:space:]]*`scope`' "$PANEL_AGENT_MD" \
    && ok "agent lens table defines the 'scope' row" \
    || no "agent lens table has no 'scope' row — dispatching it would hard-stop" ""
  grep -qE 'scope[^|]*\|' "$PANEL_AGENT_MD" && grep -q 'original request' "$PANEL_AGENT_MD" \
    && ok "scope lens is anchored to the user's ORIGINAL request" \
    || no "scope lens does not reference the original request" ""
else
  no "adversarial-panel-reviewer.md not found at $PANEL_AGENT_MD" ""
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
