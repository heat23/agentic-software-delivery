#!/usr/bin/env bash
# panel-review-validation-test.sh — PANEL (2026-08-03): pins the vendor-neutral adversarial-review
# provenance field that replaces free-text codex prose as the mandatory review gate.
#
# WHY this harness exists. Ground truth over 358 final AGENT_REVIEW artifacts: only 24 (6.7%)
# positively evidence a successful codex CLI run, while 147 say `ran — N candidates…` naming no model
# and no mechanism. The gate accepted all 147 because it grepped prose. Every tightening of that grep
# false-blocked an honest fallback, which induced the model to fabricate a "codex ran" claim
# (forensics of two production sessions) — an arms race with no fixed point.
#
# The panel field ends it by being machine-checkable AND cross-checked against DISPATCH_PROVENANCE.
# What must hold, and is pinned below:
#   1. a well-formed panel field satisfies the required-field slot with no codex field present
#   2. every structural rule actually rejects (panel>=2, models/lenses arity, lens diversity, arithmetic)
#   3. the declared panel size must be BACKED by >= N distinct real status=ok dispatch rows
#   4. legacy codex artifacts keep passing byte-identically (358 artifacts must not retro-fail)
#   5. a panel field CANNOT launder a forged "codex … ran" claim past the independence gate
# Re-run: bash <thisfile>
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# V_VALIDATION_LIB is the standard pre-fix-oracle seam (same shape as validation-test.sh): pointing it
# at a `.pre-*-bak` lets this harness be run RED against a validation.sh that predates the panel
# contract, which is what the P2 bite gate requires as evidence.
LIB="${V_VALIDATION_LIB:-$DIR/validation.sh}"
# shellcheck disable=SC1091
. "$LIB" 2>/dev/null || { echo "SKIP: validation.sh not sourceable"; exit 0; }
type validate_review_semantics >/dev/null 2>&1 || { echo "SKIP: validate_review_semantics unavailable"; exit 0; }
type _panel_field_valid >/dev/null 2>&1 || { echo "NO: _panel_field_valid missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — ${2:-}"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT

PANEL_OK='panel=3 models=sonnet,sonnet,haiku lenses=correctness,security,repro candidates=7 accepted=2 refuted=5'

# Build an AGENT_REVIEW carrying an arbitrary adversarial-provenance line.
mk() { # <outfile> <provenance-line>
  cat > "$1" <<EOF
Model: haiku
# AGENT_REVIEW
Status: completed
Agents dispatched: logic-reviewer, security-reviewer, codebase-fit-reviewer
$2
Hostile adversarial focus: yes
Dispatch mode: foreground
Review evidence: claude_accepted: 2 | findings: 2
Remediation: all CRITICAL/HIGH fixed before sign-off
EOF
}

echo "== panel field :: structural validation =="

# ── 1. well-formed panel, NO codex field at all — must satisfy the required-field slot ──
mk "$TMP/panel_ok.md" "Adversarial review: $PANEL_OK"
err=$(validate_review_semantics "$TMP/panel_ok.md" 1 1 "" 0 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "panel-only artifact PASSES with no codex field present" \
  || no "panel-only artifact wrongly blocked" "rc=$rc :: $err"

# The legacy prose check must NOT fire on a panel artifact — that grep is the fabrication driver.
printf '%s' "$err" | grep -qi 'missing codex/superpowers review provenance' \
  && no "legacy codex prose check still fired on a panel artifact" "$err" \
  || ok "legacy 'missing codex/superpowers provenance' check suppressed for panel artifacts"

# ── 2. structural rejections ──
# A "panel" of one is a single reviewer wearing a panel label.
_panel_field_valid "Adversarial review: panel=1 models=sonnet lenses=correctness candidates=1 accepted=1 refuted=0" >/dev/null 2>&1 \
  && no "panel=1 accepted (a solo review must not pass as a panel)" \
  || ok "panel=1 REJECTED (solo review cannot masquerade as a panel)"

# models count must equal declared panel size
_panel_field_valid "Adversarial review: panel=3 models=sonnet,haiku lenses=a,b,c candidates=1 accepted=0 refuted=1" >/dev/null 2>&1 \
  && no "models arity mismatch accepted" \
  || ok "models arity != panel size REJECTED"

# lenses count must equal declared panel size
_panel_field_valid "Adversarial review: panel=3 models=sonnet,sonnet,haiku lenses=a,b candidates=1 accepted=0 refuted=1" >/dev/null 2>&1 \
  && no "lenses arity mismatch accepted" \
  || ok "lenses arity != panel size REJECTED"

# lens diversity is the whole point of a panel — N identical lenses is redundancy, not independence
_panel_field_valid "Adversarial review: panel=3 models=sonnet,sonnet,haiku lenses=correctness,correctness,correctness candidates=1 accepted=0 refuted=1" >/dev/null 2>&1 \
  && no "zero-diversity lens set accepted" \
  || ok "identical lenses REJECTED (panel requires >=2 distinct lenses)"

# adjudication arithmetic must close
_panel_field_valid "Adversarial review: panel=2 models=sonnet,haiku lenses=a,b candidates=2 accepted=2 refuted=3" >/dev/null 2>&1 \
  && no "accepted+refuted > candidates accepted" \
  || ok "accepted+refuted > candidates REJECTED"

# a valid field returns its declared size (used for the provenance cross-check)
got=$(_panel_field_valid "Adversarial review: $PANEL_OK" 2>/dev/null)
[ "$got" = "3" ] && ok "_panel_field_valid returns declared panel size ($got)" \
  || no "_panel_field_valid returned '$got', expected 3"

# a malformed panel field with no codex fallback must be a HARD error, not a silent downgrade
mk "$TMP/panel_bad.md" "Adversarial review: panel=9 models=sonnet lenses=correctness candidates=1 accepted=0 refuted=0"
err=$(validate_review_semantics "$TMP/panel_bad.md" 1 1 "" 0 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "malformed panel field BLOCKS (no silent downgrade to prose)" \
  || no "malformed panel field wrongly accepted" "$err"
printf '%s' "$err" | grep -qi "malformed 'Adversarial review:'" \
  && ok "rejection message names the malformed panel field" \
  || no "rejection message does not name the panel field" "$err"

echo "== panel field :: independence cross-check against DISPATCH_PROVENANCE =="

SESSION_ID="11111111-2222-3333-4444-555555555555"
ARTIFACT_SEARCH_DIRS=("$TMP")
_TX_SIGNALS=""
PROV="$TMP/DISPATCH_PROVENANCE_${SESSION_ID}.log"

# 3 DISTINCT reviewers dispatched, all status=ok → the declared panel=3 is backed by real rows.
cat > "$PROV" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=a.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111112
DISPATCH|ts=2026-08-03T10:00:01Z|agent=security-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=b.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111113
DISPATCH|ts=2026-08-03T10:00:02Z|agent=codebase-fit-reviewer|mode=capture|status=ok|submodel=haiku|cost_usd=|duration_ms=100|artifact=c.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111114
EOF
_panel_was_dispatched 3 && ok "panel=3 backed by 3 distinct status=ok dispatch rows" \
  || no "3 real dispatch rows not recognized"
_panel_was_dispatched 4 && no "panel=4 accepted on only 3 dispatch rows (over-claim not caught)" \
  || ok "panel=4 REJECTED on 3 rows (declared size cannot exceed real dispatches)"

# PANEL MEMBERSHIP IS KEYED ON ARTIFACT, NOT AGENT NAME (live-fire fix 2026-08-03).
# A real panel is ONE agent (adversarial-panel-reviewer) dispatched N times with DIFFERENT LENSES, so
# every row carries the SAME agent= value. Counting distinct agent NAMES scored a genuine 2-lens run
# as 1 and rejected it — verified live against two real `claude -p --agent` dispatches. What must NOT
# count as N members is N retries writing the SAME artifact.
cat > "$TMP/DISPATCH_PROVENANCE_dup.log" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=same.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111112
DISPATCH|ts=2026-08-03T10:00:01Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=same.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111113
DISPATCH|ts=2026-08-03T10:00:02Z|agent=logic-reviewer|mode=capture|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=same.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111114
EOF
_SAVED_PROV=$(cat "$PROV"); cp "$TMP/DISPATCH_PROVENANCE_dup.log" "$PROV"
_panel_was_dispatched 3 && no "3 retries writing the SAME artifact counted as a 3-member panel" \
  || ok "repeat dispatches to the SAME artifact do not satisfy panel=3 (retries collapse)"
printf '%s' "$_SAVED_PROV" > "$PROV"

# The real-world shape: ONE agent, N lenses, N distinct artifacts -> a valid N-member panel.
cat > "$TMP/DISPATCH_PROVENANCE_lens.log" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=adversarial-panel-reviewer|mode=capture|status=ok|submodel=claude-sonnet-5|cost_usd=0.10|duration_ms=30000|artifact=panel-correctness.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff0000000011111111
DISPATCH|ts=2026-08-03T10:00:01Z|agent=adversarial-panel-reviewer|mode=capture|status=ok|submodel=claude-sonnet-5|cost_usd=0.10|duration_ms=40000|artifact=panel-security.md|sha256=1111111122222222333333334444444455555555666666667777777788888888
EOF
cp "$TMP/DISPATCH_PROVENANCE_lens.log" "$PROV"
_panel_was_dispatched 2 && ok "same agent + 2 DISTINCT lens artifacts satisfies panel=2 (real shape)" \
  || no "REGRESSION: the real 2-lens dispatch shape is rejected — every panel session would deadlock"
_panel_was_dispatched 3 && no "panel=3 over-claim accepted on 2 lens artifacts" \
  || ok "panel=3 over-claim still REJECTED on a 2-member lens panel"
printf '%s' "$_SAVED_PROV" > "$PROV"

# agent-self rows are an artifact's own self-record — never proof of independent dispatch.
cat > "$TMP/DISPATCH_PROVENANCE_self.log" <<'EOF'
DISPATCH|ts=2026-08-03T10:00:00Z|agent=logic-reviewer|mode=agent-self|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=a.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111112
DISPATCH|ts=2026-08-03T10:00:01Z|agent=security-reviewer|mode=agent-self|status=ok|submodel=sonnet|cost_usd=|duration_ms=100|artifact=b.md|sha256=aaaaaaaabbbbbbbbccccccccddddddddeeeeeeeeffffffff00000000111111113
EOF
cp "$TMP/DISPATCH_PROVENANCE_self.log" "$PROV"
_panel_was_dispatched 2 && no "agent-self rows counted toward panel independence" \
  || ok "mode=agent-self rows do NOT count toward panel independence"
printf '%s' "$_SAVED_PROV" > "$PROV"

echo "== panel field :: forgery cannot be laundered =="

# A panel field alongside a FORGED "codex … ran" claim must still resolve 'silent' (BLOCK).
# This is why the panel branch is ordered after the forgery check in _independence_verdict.
rm -f "$PROV"
cat > "$TMP/forge.md" <<EOF
Model: haiku
# AGENT_REVIEW
Status: completed
Agents dispatched: logic-reviewer
Codex adversarial reviewer: codex-adversarial-reviewer ran — 5 candidates, 5 accepted, 0 rejected
Adversarial review: $PANEL_OK
Hostile adversarial focus: yes
Dispatch mode: foreground
Review evidence: claude_accepted: 2 | findings: 2
Remediation: fixed
EOF
v=$(_independence_verdict "$TMP/forge.md" "codex-adversarial-reviewer" 2>/dev/null)
[ "$v" = "silent" ] && ok "panel field CANNOT launder a forged 'codex ran' claim (verdict=silent)" \
  || no "forged codex claim escaped via the panel branch" "verdict=$v"

# With real backing rows and NO codex claim, the panel resolves 'dispatched'.
printf '%s' "$_SAVED_PROV" > "$PROV"
mk "$TMP/panel_indep.md" "Adversarial review: $PANEL_OK"
v=$(_independence_verdict "$TMP/panel_indep.md" "codex-adversarial-reviewer" 2>/dev/null)
[ "$v" = "dispatched" ] && ok "backed panel resolves verdict=dispatched" \
  || no "backed panel did not resolve dispatched" "verdict=$v"

# A panel DECLARED but not backed by dispatches must not reach 'dispatched'.
rm -f "$PROV"
v=$(_independence_verdict "$TMP/panel_indep.md" "codex-adversarial-reviewer" 2>/dev/null)
[ "$v" = "dispatched" ] && no "unbacked panel claim resolved dispatched (forgeable)" "verdict=$v" \
  || ok "unbacked panel claim does NOT resolve dispatched (verdict=$v)"

echo "== back-compat :: legacy codex artifacts unchanged =="

# The 358 historical artifacts carry the legacy field and no panel field. They must behave exactly
# as before — this is the regression that matters most, since a retro-fail would strand real branches.
mk "$TMP/legacy_ok.md" "Codex adversarial reviewer: codex-adversarial-reviewer ran — 3 candidates, 3 accepted, 0 rejected"
validate_review_semantics "$TMP/legacy_ok.md" 1 1 "" 0 >/dev/null 2>&1 \
  && ok "legacy codex artifact still PASSES" || no "legacy codex artifact wrongly blocked"

mk "$TMP/legacy_skip.md" "Codex adversarial reviewer: skipped"
validate_review_semantics "$TMP/legacy_skip.md" 1 1 "" 0 >/dev/null 2>&1 \
  && no "legacy 'skipped' artifact wrongly accepted (back-compat regression)" \
  || ok "legacy 'skipped' artifact still BLOCKS"

mk "$TMP/legacy_none.md" "Codex adversarial reviewer: superpowers:requesting-code-review fallback"
validate_review_semantics "$TMP/legacy_none.md" 1 1 "" 0 >/dev/null 2>&1 \
  && ok "legacy superpowers-fallback artifact still PASSES" \
  || no "legacy superpowers fallback wrongly blocked"

# Neither field present is still a missing-field block.
mk "$TMP/neither.md" "Some unrelated line: value"
err=$(validate_review_semantics "$TMP/neither.md" 1 1 "" 0 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "artifact with NEITHER field still BLOCKS" || no "missing-field block lost" "$err"

echo "== panel field :: stale-count guard =="

# Skeleton emits candidates=0 before adjudication. Pasting findings without updating the counts is
# the never-filled-template failure mode; it must block.
cat > "$TMP/stale.md" <<'EOF'
Model: haiku
# AGENT_REVIEW
Status: completed
Agents dispatched: logic-reviewer, security-reviewer
Adversarial review: panel=2 models=sonnet,haiku lenses=correctness,security candidates=0 accepted=0 refuted=0
Hostile adversarial focus: yes
Dispatch mode: foreground
Review evidence: claude_accepted: 1 | findings: 1
Remediation: fixed

## Findings

#### LOGIC-001: unbounded query in the report builder
severity: high
EOF
err=$(validate_review_semantics "$TMP/stale.md" 1 1 "" 0 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "candidates=0 with finding IDs in body BLOCKS (stale skeleton counts)" \
  || no "stale candidates=0 accepted over a body with findings" "$err"

# candidates=0 with a genuinely clean body must still pass — the guard must not punish clean reviews.
cat > "$TMP/clean.md" <<'EOF'
Model: haiku
# AGENT_REVIEW
Status: completed
Agents dispatched: logic-reviewer, security-reviewer
Adversarial review: panel=2 models=sonnet,haiku lenses=correctness,security candidates=0 accepted=0 refuted=0
Hostile adversarial focus: yes
Dispatch mode: foreground
Review evidence: claude_accepted: 0 | findings: 0
Remediation: 0 — no findings

## Findings

No issues found.
EOF
validate_review_semantics "$TMP/clean.md" 1 1 "" 0 >/dev/null 2>&1 \
  && ok "candidates=0 on a genuinely clean review still PASSES" \
  || no "clean zero-finding panel review wrongly blocked"

# A panel does NOT license lying about the diff: "nothing to review" on a code session still blocks,
# even alongside a valid panel field (that check is orthogonal to which reviewer ran).
cat > "$TMP/panel_lies.md" <<'EOF'
Model: haiku
# AGENT_REVIEW
Status: completed
Agents dispatched: logic-reviewer, security-reviewer
Codex adversarial reviewer: no code changes to review
Adversarial review: panel=2 models=sonnet,haiku lenses=correctness,security candidates=2 accepted=1 refuted=1
Hostile adversarial focus: yes
Dispatch mode: foreground
Review evidence: claude_accepted: 1 | findings: 1
Remediation: fixed
EOF
validate_review_semantics "$TMP/panel_lies.md" 1 1 "" 0 >/dev/null 2>&1 \
  && no "panel field wrongly relaxed the 'nothing to review' false-claim check" \
  || ok "'nothing to review' still BLOCKS even with a valid panel (check stays orthogonal)"

echo "== panel agent :: roster registration (live-fire class guard) =="

# A new reviewer agent must be registered in EVERY roster that gates on agent name, or it silently
# fails in production. Live-fire 2026-08-03 found adversarial-panel-reviewer missing from all of
# these: record-agent-dispatch-provenance.sh would have written NO provenance row (so the panel could
# never satisfy its own cross-check), and block-fork-agent-dispatch.sh would not have protected it.
# Unit tests cannot catch this — only a real dispatch or a structural check like this one can.
_roster_check() { # <file> <label>
  if [ ! -f "$HOME/.claude/$1" ]; then ok "$2: file absent (skipped)"; return; fi
  grep -q 'adversarial-panel-reviewer' "$HOME/.claude/$1" \
    && ok "$2 registers adversarial-panel-reviewer" \
    || no "$2 is MISSING adversarial-panel-reviewer (panel dispatches break in production)" "$1"
}
_roster_check "hooks/record-agent-dispatch-provenance.sh" "provenance allowlist"
_roster_check "hooks/block-fork-agent-dispatch.sh"        "fork-dispatch guard"
_roster_check "skills/v-session-log/references/v-gather-session-data.sh" "session-log independence"
_roster_check "skills/v/references/v-emit-agent-review-skeleton.sh"      "skeleton _REVIEWERS"
_roster_check "hooks/posttoolbatch-aggregate-reviews.sh"  "aggregator lens map"
printf '%s' "$_PANEL_REVIEWERS_RE" | grep -q 'adversarial-panel-reviewer' \
  && ok "validation.sh _PANEL_REVIEWERS_RE registers the agent" \
  || no "_PANEL_REVIEWERS_RE missing adversarial-panel-reviewer"
printf '%s' "$_FALLBACK_REVIEWERS_RE" | grep -q 'adversarial-panel-reviewer' \
  && ok "validation.sh _FALLBACK_REVIEWERS_RE registers the agent" \
  || no "_FALLBACK_REVIEWERS_RE missing adversarial-panel-reviewer"
[ -f "$HOME/.claude/agents/adversarial-panel-reviewer.md" ] \
  && ok "the agent definition file exists" || no "agents/adversarial-panel-reviewer.md missing"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
