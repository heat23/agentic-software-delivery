#!/usr/bin/env bash
# check-review-artifact-test.sh
# Regression harness for check-review-artifact.sh — focused on the gate-independence
# machinery (_agent_was_dispatched / _independence_verdict).
#
# ORIGINAL ROOT BUG (forensics, 2026-06-02):
#   The AGENT_REVIEW independence check CALLS _independence_verdict, but the function was
#   DEFINED ~250 lines LOWER in the same file. bash resolves functions at call time
#   top-to-bottom, so the call hit "command not found", the `case` matched nothing,
#   MISSING_REVIEW stayed 0, and orchestrator-inline self-reviews were SILENTLY accepted
#   on every code-changing session (AGENT_REVIEW is "the AI review is the ONLY safety net").
#
# MODERNISED 2026-06-16: those two helpers were SINGLE-SOURCED into hooks/lib/validation.sh
#   (the parity refactor — the Stop hook and v-completion-selfcheck.sh now call the SAME
#   functions so they can't drift). The dead-gate failure mode therefore changed shape: it is
#   no longer "inline def below call" but "the hook must `source` validation.sh BEFORE any call
#   site." This harness now guards THAT invariant. (Previously it grepped the hook for an inline
#   `_independence_verdict() {` definition that no longer exists there — it had silently rotted to
#   1/6 while orphaned from CI; this rewrite restores real coverage and is wired into vitest.)
#
# Tier 1 (STATIC dead-gate guard, single-sourced era): the `source .../validation.sh` line must
#         precede EVERY call site of each helper in the hook, AND each helper must RESOLVE once
#         validation.sh is sourced (so "command not found" can never silently kill the gate again).
# Tier 2 (HOOK LINT): `bash -n` every hook — catches the block-v-polling.sh-class syntax error
#         that blocked ALL Bash execution at the start of those same sessions (now also covers
#         newer hooks like block-cross-session-add.sh).
# Tier 3 (FUNCTION LOGIC smoke): source validation.sh and confirm both helpers are defined +
#         the `dispatched` verdict resolves. The FULL four-branch verdict matrix
#         (dispatched|silent|declared|unverifiable) is owned by the canonical, in-CI harnesses
#         skills/v/references/v-completion-independence-test.sh + v-completion-parity-test.sh
#         (which set up the function's full required context) — not duplicated here.

HOOK="${HOOK_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
HOOKS_DIR="$HOME/.claude/hooks"
LIB="$HOME/.claude/hooks/lib/validation.sh"
TEST_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

PASS=0
FAIL=0

_ok()   { printf '  ok  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "== check-review-artifact :: gate-independence ordering + logic (single-sourced era) =="

# ── Tier 1: STATIC dead-gate guard ──────────────────────────────────────────
# (a) the helpers live in validation.sh (single-sourced), NOT inline in the hook;
# (b) the hook SOURCES validation.sh before every call site (the modern call-before-resolve guard);
# (c) each helper RESOLVES once validation.sh is sourced.
[ -f "$LIB" ] || { _fail "T1 validation.sh not found at $LIB"; }

# source line in the hook (where validation.sh is pulled in). Recognizes both the legacy literal
# `source "$HOOKS_LIB_DIR/validation.sh"` form AND the test-injectable indirection introduced by the
# 2026-06-18 audit (`_VALIDATION_LIB="${V_VALIDATION_LIB:-$HOOKS_LIB_DIR/validation.sh}"; source
# "$_VALIDATION_LIB"`) — both resolve to validation.sh; the indirection is the mutation-gate seam.
_src_line() { grep -nE 'source "\$HOOKS_LIB_DIR/validation\.sh"|source .*/lib/validation\.sh|source "\$_?VALIDATION_LIB"' "$HOOK" 2>/dev/null | head -1 | cut -d: -f1; }
# call sites of $1 in the hook: bareword followed by space/quote, excluding the def + comment lines.
_call_lines() {
  grep -nE "(^|[^A-Za-z0-9_])$1[ \"]" "$HOOK" 2>/dev/null \
    | grep -vE "^[0-9]+:[[:space:]]*#" \
    | grep -vE "^[0-9]+:$1\(\)" \
    | cut -d: -f1
}

SRC=$(_src_line)
if [ -z "$SRC" ]; then
  _fail "T1 hook does not source validation.sh (the helpers would be undefined → dead gate)"
else
  _ok "T1 hook sources validation.sh (line $SRC)"
fi

for fn in _independence_verdict _agent_was_dispatched; do
  # (a) defined in validation.sh, not inline in the hook
  if grep -qE "^${fn}\(\) \{" "$LIB"; then
    _ok "T1 $fn defined in validation.sh (single-sourced)"
  else
    _fail "T1 $fn NOT defined in validation.sh"
  fi
  # (b) source precedes every call site in the hook (skip cleanly if not called directly here)
  calls=$(_call_lines "$fn")
  if [ -z "$calls" ]; then
    _ok "T1 $fn has no direct call site in the hook (called via validation.sh internals) — ordering N/A"
  elif [ -z "$SRC" ]; then
    _fail "T1 $fn called but validation.sh is never sourced"
  else
    worst=0; bad=0
    for c in $calls; do [ "$c" -le "$SRC" ] && { bad=1; worst="$c"; }; done
    if [ "$bad" = "0" ]; then
      _ok "T1 $fn: validation.sh source (line $SRC) precedes all $(printf '%s\n' "$calls" | wc -l | tr -d ' ') call site(s)"
    else
      _fail "T1 $fn CALLED at line $worst BEFORE validation.sh is sourced at line $SRC (dead-gate ordering bug)"
    fi
  fi
done

# ── Tier 2: HOOK LINT (bash -n over every hook) ─────────────────────────────
_lint_fail=0
for h in "$HOOKS_DIR"/*.sh; do
  [ -f "$h" ] || continue
  case "$h" in *-test.sh) continue;; esac   # skip the test harnesses themselves
  if ! bash -n "$h" 2>/dev/null; then
    _lint_fail=1
    printf '       bash -n FAILED: %s\n' "$h"
  fi
done
if [ "$_lint_fail" = "0" ]; then _ok "T2 bash -n clean across all hooks"; else _fail "T2 a hook has a syntax error (would block all Bash)"; fi

# ── Tier 3: FUNCTION-LOGIC smoke (source validation.sh, confirm resolve + dispatched verdict) ─
# The full verdict matrix is owned by v-completion-independence-test.sh + v-completion-parity-test.sh
# (both wired into vitest). Here we only guard that the helpers RESOLVE (no "command not found"
# dead-gate recurrence) and that the strongest signal (an independent dispatch) classifies correctly.
SBX=$(mktemp -d)
cat > "$SBX/AGENT_REVIEW_dispatched_${TEST_UUID}.md" <<'EOF'
Model: haiku
## Agent Review
dispatch: inline (codex unavailable; superpowers: requesting-code-review attempted)
Overall: APPROVED
EOF
T3=$(
  set +u
  # shellcheck source=/dev/null
  source "$LIB" 2>/dev/null
  type _independence_verdict >/dev/null 2>&1 || { echo "NODEF independence"; exit 0; }
  type _agent_was_dispatched >/dev/null 2>&1 || { echo "NODEF dispatched"; exit 0; }
  echo "DEFINED"
  SESSION_ID="$TEST_UUID"
  ARTIFACT_SEARCH_DIRS=("$SBX")
  _TX_SIGNALS='"subagent_type":"codex-adversarial-reviewer"'; TRANSCRIPT_READABLE=1
  echo "VERDICT=$(_independence_verdict "$SBX/AGENT_REVIEW_dispatched_${TEST_UUID}.md" codex-adversarial-reviewer)"
)
rm -rf "$SBX" 2>/dev/null || true

case "$T3" in
  *NODEF*) _fail "T3 a helper did NOT resolve after sourcing validation.sh ($T3) — the dead-gate recurrence guard";;
  *DEFINED*) _ok "T3 both helpers RESOLVE after sourcing validation.sh (dead-gate 'command not found' cannot recur)";;
  *) _fail "T3 sourcing validation.sh failed ($T3)";;
esac
if printf '%s' "$T3" | grep -q 'VERDICT=dispatched'; then
  _ok "T3 _independence_verdict('dispatch'+transcript subagent_type) -> dispatched (smoke; full matrix in v-completion-independence-test.sh)"
else
  _fail "T3 dispatched smoke: expected 'dispatched', got '$(printf '%s' "$T3" | grep -o 'VERDICT=[^ ]*')'"
fi

# ── Tier 3b: B-FALLBACK SCOPING (forensic 2026-06-16) ────────────────────────
# A real security-reviewer dispatch (sanctioned superpowers fallback when codex is down) must satisfy the
# CODEX independence requirement, but must NOT leak into the v-qa-reviewer independence check (that gate
# needs its OWN agent). Locks the agent-scoping of the new _fallback_reviewer_dispatched credit.
SBX2=$(mktemp -d)
printf 'Model: haiku\n## Agent Review\n- Codex adversarial reviewer: codex unavailable; superpowers fallback — security-reviewer dispatched\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED\n' > "$SBX2/AGENT_REVIEW_${TEST_UUID}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$SBX2/QA_REPORT_${TEST_UUID}.md"
T3B=$(
  set +u
  # shellcheck source=/dev/null
  source "$LIB" 2>/dev/null
  type _independence_verdict >/dev/null 2>&1 || { echo "NODEF"; exit 0; }
  SESSION_ID="$TEST_UUID"
  ARTIFACT_SEARCH_DIRS=("$SBX2")
  # ONLY a security-reviewer dispatch in the transcript — no codex, no QA agent.
  _TX_SIGNALS='"subagent_type":"security-reviewer"'; TRANSCRIPT_READABLE=1
  echo "CODEX=$(_independence_verdict "$SBX2/AGENT_REVIEW_${TEST_UUID}.md" codex-adversarial-reviewer)"
  echo "QA=$(_independence_verdict "$SBX2/QA_REPORT_${TEST_UUID}.md" v-qa-reviewer)"
)
rm -rf "$SBX2" 2>/dev/null || true
if printf '%s' "$T3B" | grep -q 'CODEX=dispatched'; then
  _ok "T3b security-reviewer fallback dispatch SATISFIES codex-adversarial-reviewer independence (B-FALLBACK)"
else
  _fail "T3b expected codex independence 'dispatched' via security-reviewer fallback, got '$(printf '%s' "$T3B" | grep -o 'CODEX=[^ ]*')'"
fi
if printf '%s' "$T3B" | grep -qE 'QA=(dispatched)'; then
  _fail "T3b SCOPING LEAK: a security-reviewer dispatch wrongly satisfied the v-qa-reviewer independence check"
else
  _ok "T3b scoping: security-reviewer dispatch does NOT satisfy v-qa-reviewer independence (got '$(printf '%s' "$T3B" | grep -o 'QA=[^ ]*')')"
fi

# ── Tier 4: SKILL-REVIEW ESCAPE (Part B, 2026-07-05) — full-hook E2E in a sandbox ──
# /v-skill-reviewer is report-only; Part B used to block it. The escape must
# open ONLY for (history shows /v-skill-reviewer) AND (content-validated report). Every other
# combination — no report, forged report in a generic /v session, stub, missing verdict — must
# still BLOCK (the existing laundering guard). Drives the REAL hook E2E: fake $HOME with the
# real hooks/ and skills/ symlinked in, fixture history.jsonl, throwaway git repo, stdin JSON.
_t4_case() {
  # $1=name $2=history-display $3=report-content ("" = none) $4=expected (allow|block)
  # $5=artifact prefix (default SKILL_REVIEW_REPORT; e.g. CONSOLIDATED_AUDIT_REPORT for /v-audit-consolidate)
  # $6=transcript first-user-message content ("" = no transcript) — exercises the strict
  #    W4B3-mirror pasted-text fallback inside the escape (SREV-001/SREV-002 coverage).
  local name="$1" display="$2" report="$3" expect="$4" prefix="${5:-SKILL_REVIEW_REPORT}" txcontent="${6:-}"
  local SID="cafe0000-1111-4000-8000-$(printf '%04d%08d' $((RANDOM % 10000)) $((RANDOM * RANDOM % 100000000)))"
  local SBX; SBX=$(mktemp -d)
  mkdir -p "$SBX/home/.claude/projects/-sandbox" "$SBX/repo"
  ln -s "$HOME/.claude/hooks" "$SBX/home/.claude/hooks"
  ln -s "$HOME/.claude/skills" "$SBX/home/.claude/skills"
  if [ -n "$display" ]; then
    printf '{"sessionId":"%s","display":"%s","timestamp":1}\n' "$SID" "$display" > "$SBX/home/.claude/history.jsonl"
  else
    : > "$SBX/home/.claude/history.jsonl"
  fi
  if [ -n "$txcontent" ]; then
    printf '{"type":"user","content":"%s"}\n' "$txcontent" > "$SBX/home/.claude/projects/-sandbox/${SID}.jsonl"
  fi
  git -C "$SBX/repo" init -q 2>/dev/null
  git -C "$SBX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  [ -n "$report" ] && printf '%s' "$report" > "$SBX/repo/${prefix}_${SID}.md"
  local INPUT rc
  INPUT=$(printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Review complete. Report written with findings."}' "$SID")
  (cd "$SBX/repo" && echo "$INPUT" | HOME="$SBX/home" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" bash "$HOOK" >/dev/null 2>&1)
  rc=$?
  rm -rf "$SBX" 2>/dev/null
  if [ "$expect" = allow ]; then
    [ "$rc" -eq 0 ] && _ok "T4 $name (allowed)" || _fail "T4 $name — expected allow, got rc=$rc"
  else
    [ "$rc" -eq 2 ] && _ok "T4 $name (blocked)" || _fail "T4 $name — expected block(2), got rc=$rc"
  fi
}
_T4_VALID="# SKILL_REVIEW_REPORT

Mode: standard
Targets: v-tdd
Reviewed at: 2026-07-05

## Executive Summary
Reviewed against all lenses; evidence verified on disk against the live hook sources and reference files as the review contract requires. No P0/P1 findings.

## Ranked Findings
### P2: example finding
- confidence: high
- evidence: SKILL.md:1

Overall Status: PASS
"
_t4_case "skill-reviewer + valid report"        "/v-skill-reviewer v-tdd" "$_T4_VALID" allow
_t4_case "skill-reviewer, NO report"            "/v-skill-reviewer v-tdd" ""          block
_t4_case "generic /v + forged report (launder)" "/v fix the login bug"    "$_T4_VALID" block
_t4_case "skill-reviewer + stub report (<300B)" "/v-skill-reviewer v-tdd" "# SKILL_REVIEW_REPORT
tiny" block
# Fallback-path coverage (SREV-001/SREV-002): the pasted-text transcript fallback must accept a
# REAL pasted /v-skill-reviewer command, and must NOT accept a prose mention of the skill name
# inside some other /v session's first message (the exact laundering vector the first shipped
# version had). Note the display for pasted input is "[Pasted text #N +M lines]".
_t4_case "PASTED skill-reviewer cmd + valid report"          "[Pasted text #1 +3 lines]" "$_T4_VALID" allow SKILL_REVIEW_REPORT "/v-skill-reviewer v-tdd --standard"
_t4_case "generic /v + PROSE mention in tx + forged report"  "/v fix the login bug"      "$_T4_VALID" block SKILL_REVIEW_REPORT "please also look at /v-skill-reviewer sometime"
_t4_case "PASTED generic /v + prose mention + forged report" "[Pasted text #1 +2 lines]" "$_T4_VALID" block SKILL_REVIEW_REPORT "/v fix the bug. I reviewed /v-skill-reviewer earlier."

# ── Tier 4b: CONSOLIDATE ESCAPE (Part B generalization, 2026-07-05) ──
# /v-audit-consolidate is another report-only-shaped skill: its 0/1-report early-exits and
# PASS-verdict runs change no code, so Part B blocked a successful standalone consolidation
# (SKILL_REVIEW_REPORT F4 recurrence, second skill). Same evidence-gated + content-validated
# escape contract: history must prove /v-audit-consolidate ran for THIS SID, and the report
# must pass content validation (>=300B, CONSOLIDATED_AUDIT_REPORT heading, verdict: line —
# incl. NOT-RUN for early-exits — and the provenance line). Forged/stub/verdict-less/
# cross-artifact combos must still BLOCK (existing laundering guard preserved).
_T4C_VALID="# CONSOLIDATED_AUDIT_REPORT_cafe0000
generated: 2026-07-05T12:00:00Z
project: sandbox
verdict: NOT-RUN

Generated by v-audit-consolidate v1.1

## Source audits

No audit reports found in the project root within the last 14 days. Run audit skills first
(e.g., /v-prelaunch-readiness, /v-check, /v-anti-template-gauntlet), then re-run consolidation.
"
_t4_case "consolidate + valid early-exit report"  "/v-audit-consolidate" "$_T4C_VALID" allow CONSOLIDATED_AUDIT_REPORT
_t4_case "consolidate, NO report"                 "/v-audit-consolidate" ""            block CONSOLIDATED_AUDIT_REPORT
_t4_case "generic /v + forged consolidate report" "/v fix the login bug" "$_T4C_VALID" block CONSOLIDATED_AUDIT_REPORT
_t4_case "consolidate + stub report (<300B)"      "/v-audit-consolidate" "# CONSOLIDATED_AUDIT_REPORT
tiny" block CONSOLIDATED_AUDIT_REPORT
_t4_case "consolidate + report missing verdict"   "/v-audit-consolidate" "# CONSOLIDATED_AUDIT_REPORT_x
generated: 2026-07-05T12:00:00Z
project: sandbox

Generated by v-audit-consolidate v1.1

## Source audits

A long-enough report body that clears the 300-byte floor but deliberately omits the verdict line,
so content validation must reject it — size alone is never sufficient (existing laundering guard).
" block CONSOLIDATED_AUDIT_REPORT
_t4_case "cross-artifact mismatch (reviewer hist + consolidate report)" "/v-skill-reviewer v-tdd" "$_T4C_VALID" block CONSOLIDATED_AUDIT_REPORT

# ── Tier 4c: GAUNTLET-REPORT ESCAPE (Part B registry row, 2026-07-05) ──
# /v-anti-template-gauntlet is report-only on its audit path: a standalone pre-ship gate run
# writes GAUNTLET_REPORT_<sid>.md and changes no code, so Part B blocked a correctly-completed
# gauntlet (a prior skill-review report P0, F4 recurrence #4).
# Same evidence-gated + content-validated contract: history must prove /v-anti-template-gauntlet
# ran for THIS SID, and the report must pass content validation (>=300B, GAUNTLET_REPORT heading,
# verdict line incl. BLOCK_OVERRIDDEN for --force override runs). Forged/stub/verdict-less
# combos must still BLOCK (existing laundering guard preserved).
_T4G_VALID="# GAUNTLET_REPORT
generated: 2026-07-05T12:00:00Z
scope: changed files (incremental mode)
strictness: standard
verdict: PASS

## Verdict reasoning

0 CRITICAL and 1 HIGH finding at Standard strictness — under the 0C/<=2H PASS bar per the
verdict table. Spec-conformance sampling ran against the canonical system plus the overlay.

## Findings

### HIGH (1)
- G-H1 resources/js/Pages/Landing.tsx:42 — raw Tailwind palette class without semantic binding
"
_T4G_OVERRIDE="# GAUNTLET_REPORT
generated: 2026-07-05T12:00:00Z
scope: changed files (incremental mode)
strictness: standard
verdict: BLOCK_OVERRIDDEN

## Override accountability

BLOCK overridden by operator at 2026-07-05T12:00:00Z via --force. Findings remained
unaddressed: G-C1 (hardcoded hex in app-UI components, resources/js/Pages/Landing.tsx:17).
"
_t4_case "gauntlet + valid PASS report"            "/v-anti-template-gauntlet"        "$_T4G_VALID"    allow GAUNTLET_REPORT
_t4_case "gauntlet + BLOCK_OVERRIDDEN (--force)"   "/v-anti-template-gauntlet --force" "$_T4G_OVERRIDE" allow GAUNTLET_REPORT
_t4_case "gauntlet, NO report"                     "/v-anti-template-gauntlet"        ""               block GAUNTLET_REPORT
_t4_case "generic /v + forged gauntlet report"     "/v fix the login bug"             "$_T4G_VALID"    block GAUNTLET_REPORT
_t4_case "gauntlet + stub report (<300B)"          "/v-anti-template-gauntlet"        "# GAUNTLET_REPORT
tiny" block GAUNTLET_REPORT
_t4_case "gauntlet + report missing verdict"       "/v-anti-template-gauntlet"        "# GAUNTLET_REPORT
generated: 2026-07-05T12:00:00Z
scope: changed files

A long-enough report body that clears the 300-byte floor but deliberately omits the verdict line,
so content validation must reject it — size alone is never sufficient (existing laundering guard).
The remaining text pads this fixture safely past the minimum-size threshold for the content gate.
" block GAUNTLET_REPORT
_t4_case "cross-artifact mismatch (gauntlet hist + consolidate report)" "/v-anti-template-gauntlet" "$_T4C_VALID" block CONSOLIDATED_AUDIT_REPORT
_t4_case "PASTED gauntlet cmd + valid report"            "[Pasted text #1 +2 lines]" "$_T4G_VALID" allow GAUNTLET_REPORT "/v-anti-template-gauntlet --strictness=standard"
_t4_case "PASTED generic /v + gauntlet mention + forged" "[Pasted text #1 +2 lines]" "$_T4G_VALID" block GAUNTLET_REPORT "/v fix the bug. also /v-anti-template-gauntlet is neat"

# ── Tier 4d: DIFFERENTIATE ESCAPE (Part B registry row, 2026-07-05) ──
# /v-differentiate is report-only on its ideation path: a standalone run writes a divergent
# DIFFERENTIATION_BRIEF_<sid>.md (operator-pick menu) or a target_too_vague stub under the same
# name, and changes no code — implementation is deferred to a follow-up /v-build. Part B would
# block a correctly-completed brief-only session (a prior skill-review report P0, F4 recurrence
# #5). Same evidence-gated + content-validated escape: history must prove /v-differentiate ran for
# THIS SID, and the artifact must pass content validation (>=300B, DIFFERENTIATION_BRIEF heading,
# session: line). Forged/stub/heading-less/session-less variants must still BLOCK.
_T4D_VALID="# DIFFERENTIATION_BRIEF
session: cafe0000
generated: 2026-07-05T00:00:00Z
mode: memorable-moment
target_surface: the empty state on the alerts dashboard

## Selection rule
This brief is DIVERGENT — operator picks 1-3 ideas to ship, not all of them.

## Ideas
### Idea 1: animated first-action doodle
- Design choice: replace the empty state with a hand-drawn animated doodle of the user's first action
- Reference precedent: Linear's onboarding checklist reveal
- Implementation cost: M
- Differentiation moat: requires domain-specific illustration, not a template swap
"
_T4D_VAGUE="# DIFFERENTIATION_BRIEF
session: cafe0000
status: target_too_vague

## Why this is too vague
The target 'our product' names no concrete surface. Return with a specific page, flow, or
decision (e.g. 'the empty state on the alerts dashboard for a never-connected user') so the
skill can generate specific, implementable ideas instead of generic filler.
"
_t4_case "differentiate + valid brief"             "/v-differentiate hero" "$_T4D_VALID" allow DIFFERENTIATION_BRIEF
_t4_case "differentiate + valid too_vague stub"    "/v-differentiate x"    "$_T4D_VAGUE" allow DIFFERENTIATION_BRIEF
_t4_case "differentiate, NO brief"                 "/v-differentiate hero" ""            block DIFFERENTIATION_BRIEF
_t4_case "generic /v + forged brief (launder)"     "/v fix the login bug"  "$_T4D_VALID" block DIFFERENTIATION_BRIEF
_t4_case "differentiate + stub brief (<300B)"      "/v-differentiate hero" "# DIFFERENTIATION_BRIEF
session: x" block DIFFERENTIATION_BRIEF
_t4_case "differentiate + brief missing session"   "/v-differentiate hero" "# DIFFERENTIATION_BRIEF
mode: memorable-moment
target_surface: hero. Ideas follow with lots of padding text to exceed three hundred bytes so the
size gate passes but the session-line content check does not, which must still force a block here.
## Ideas
### Idea 1: something specific and implementable with a named precedent and a real moat line here
" block DIFFERENTIATION_BRIEF
_t4_case "PASTED differentiate cmd + valid brief"  "[Pasted text #1 +2 lines]" "$_T4D_VALID" allow DIFFERENTIATION_BRIEF "/v-differentiate the pricing page --luxury"
_t4_case "PASTED generic /v + differ mention + forged" "[Pasted text #1 +2 lines]" "$_T4D_VALID" block DIFFERENTIATION_BRIEF "/v fix the bug. /v-differentiate looks useful too"

# /v-legal-docs-generate is report-only-ADJACENT (a prior skill-review report P0, catalog F4):
# it dispatches 5 analysis dimensions (HAS_SUBAGENT_DISPATCH=1) but writes only .md deliverables
# (content/legal/*.md + LEGAL_AUDIT_<sid>.md), so CODE_CHANGED=0 dropped it into the gap between
# the code-gated clean exit and the report-only registry. Same evidence-gated + content-validated
# escape: history must prove /v-legal-docs-generate ran for THIS SID, and LEGAL_AUDIT must pass
# content validation (>=300B, '# Legal Compliance Audit' heading AND '## Documents Generated'
# section — two structural signals). Forged-under-generic-/v, stub, and missing-section still block.
_T4L_VALID="# Legal Compliance Audit: Acme

## Analysis Provenance
- Jurisdiction: US federal + CA (CCPA/CPRA) + TX (TDPSA)
- Dimensions: 5 of 5 completed (score_basis: \"5 of 5 dimensions completed\").

## Data Collection Summary
- Personal data types collected: 6
- Third-party processors: 4

## Compliance Gaps Found
None material; ad-tech absent so no Do-Not-Sell link required.

## Documents Generated
- [x] Privacy Policy (content/legal/privacy-policy.md)
- [x] Terms of Service (content/legal/terms-of-service.md)
- [x] Cookie Policy (content/legal/cookie-policy.md)

## Recommendations
1. Set up privacy@domain email alias.
"
_T4L_NOSECTION="# Legal Compliance Audit: Acme

## Data Collection Summary
- Personal data types collected: 6
- Third-party processors: 4

## Recommendations
1. Set up privacy@domain email alias. This report has the heading but is deliberately missing the
   '## Documents Generated' section, so the second structural content-gate signal fails and the
   escape must still block even though the file is well over 300 bytes and history matches.
"
_t4_case "legal-docs + valid audit"                "/v-legal-docs-generate all" "$_T4L_VALID" allow LEGAL_AUDIT
_t4_case "legal-docs, NO audit"                    "/v-legal-docs-generate all" ""            block LEGAL_AUDIT
_t4_case "generic /v + forged audit (launder)"     "/v fix the login bug"       "$_T4L_VALID" block LEGAL_AUDIT
_t4_case "legal-docs + stub audit (<300B)"         "/v-legal-docs-generate all" "# Legal Compliance Audit
## Documents Generated" block LEGAL_AUDIT
_t4_case "legal-docs + audit missing Documents section" "/v-legal-docs-generate all" "$_T4L_NOSECTION" block LEGAL_AUDIT
_t4_case "PASTED legal-docs cmd + valid audit"     "[Pasted text #1 +2 lines]" "$_T4L_VALID" allow LEGAL_AUDIT "/v-legal-docs-generate privacy + terms"
_t4_case "PASTED generic /v + legal mention + forged" "[Pasted text #1 +2 lines]" "$_T4L_VALID" block LEGAL_AUDIT "/v fix the bug. /v-legal-docs-generate later maybe"

# ── Tier 4e: PORTFOLIO-CADENCE (v-next) + PROD-TRIAGE ESCAPE (Part B registry, 2026-07-05) ──
# /v-next and /v-prod-triage are new report-only skills (added alongside this hook change): each
# writes exactly ONE fixed-name artifact per session and touches no application code on a
# standalone run. Same evidence-gated + content-validated escape as every fixed-name row above:
# history must prove the skill ran for THIS SID, and the artifact must pass content validation
# (>=300B, heading + session: line — two structural signals). Forged/stub/heading-less/
# session-less variants must still BLOCK.
_T4N_VALID="# V_NEXT_REPORT
session: cafe0000
generated: 2026-07-05T00:00:00Z
projects_scanned: 3

## EXECUTIVE_SUMMARY
project-a's SEO audit is 95 days stale and carries 2 unresolved P1 findings — the top-ranked item.

## RANKED_NEXT_ACTIONS
### 1. project-a — re-run /v-audit-seo (95 days stale, 2 unresolved P1)
reason: overdue past the 90-day threshold with open findings
recommended_skill: /v-audit-seo
"
_T4P_VALID="# PROD_TRIAGE
session: cafe0000
generated: 2026-07-05T00:00:00Z
modes_run: [errors, queue, scheduler, smoke]

## EXECUTIVE_SUMMARY
Queue has a growing failed_jobs backlog (14 jobs, oldest 3 days) — the top-priority finding.

## FINDINGS
### P1_IMPORTANT
#### PROD-QUEUE-01: Growing failed_jobs backlog
mode: queue
severity: high
evidence: |
  14 failed jobs, oldest failed_at 3 days ago
"
_t4_case "v-next + valid report"                   "/v-next --root=~/dev" "$_T4N_VALID" allow V_NEXT_REPORT
_t4_case "v-next, NO report"                        "/v-next --root=~/dev" ""            block V_NEXT_REPORT
_t4_case "generic /v + forged v-next report"        "/v fix the login bug" "$_T4N_VALID" block V_NEXT_REPORT
_t4_case "v-next + stub report (<300B)"              "/v-next --root=~/dev" "# V_NEXT_REPORT
session: x" block V_NEXT_REPORT
_t4_case "v-next + report missing session line"     "/v-next --root=~/dev" "# V_NEXT_REPORT
generated: 2026-07-05T00:00:00Z. Padded well past the three hundred byte content-gate minimum so
the size gate and the session-line gate are exercised independently of each other in this test.
## RANKED_NEXT_ACTIONS
### 1. some project — some action with enough padding text to clear the byte-size floor here
" block V_NEXT_REPORT
_t4_case "PASTED v-next cmd + valid report"         "[Pasted text #1 +2 lines]" "$_T4N_VALID" allow V_NEXT_REPORT "/v-next --root=~/dev"
_t4_case "PASTED generic /v + next mention + forged" "[Pasted text #1 +2 lines]" "$_T4N_VALID" block V_NEXT_REPORT "/v fix the bug. also /v-next is neat"

_t4_case "prod-triage + valid report"               "/v-prod-triage" "$_T4P_VALID" allow PROD_TRIAGE
_t4_case "prod-triage, NO report"                   "/v-prod-triage" ""            block PROD_TRIAGE
_t4_case "generic /v + forged prod-triage report"   "/v fix the login bug" "$_T4P_VALID" block PROD_TRIAGE
_t4_case "prod-triage + stub report (<300B)"         "/v-prod-triage" "# PROD_TRIAGE
session: x" block PROD_TRIAGE
_t4_case "prod-triage + report missing session line" "/v-prod-triage" "# PROD_TRIAGE
generated: 2026-07-05T00:00:00Z. Padded well past the three hundred byte content-gate minimum so
the size gate and the session-line gate are exercised independently of each other in this test.
## FINDINGS
### P1_IMPORTANT padded further with enough text to clear the byte-size floor for this fixture.
" block PROD_TRIAGE
_t4_case "PASTED prod-triage cmd + valid report"    "[Pasted text #1 +2 lines]" "$_T4P_VALID" allow PROD_TRIAGE "/v-prod-triage"
_t4_case "PASTED generic /v + triage mention + forged" "[Pasted text #1 +2 lines]" "$_T4P_VALID" block PROD_TRIAGE "/v fix the bug. also /v-prod-triage is neat"

# /v-traffic (2026-07-06) is report-only-adjacent: a plan-only run writes exactly one
# TRAFFIC_PLAN_<sid>.md (`# TRAFFIC_PLAN` heading + `session:` line, two signals) and no code, so
# CODE_CHANGED stays 0 — same escape shape as V_NEXT_REPORT / PROD_TRIAGE. Forged/stub/session-less
# variants must still BLOCK. (One-tap execute that writes .tsx/.jsx flips CODE_CHANGED=1 and owes the
# full gauntlet via the dispatched /v-content-create — not covered by this report-only escape.)
_T4T_VALID="# TRAFFIC_PLAN — project-a (2026-07-06)
session: cafe0000
data: GSC 2026-07-06 (120 queries) · GA4 2026-07-06   |   stage: launched

## If you do nothing else
Rewrite the title+meta for /example-page — it ranks #12 with 400 impressions and 0.8% CTR.

## Do this week
1. Title+meta rewrite for /example-page — striking-distance query — [impact: high, effort ~10 min]
"
_t4_case "v-traffic + valid plan"                   "/v-traffic" "$_T4T_VALID" allow TRAFFIC_PLAN
_t4_case "v-traffic, NO plan"                        "/v-traffic" ""            block TRAFFIC_PLAN
_t4_case "generic /v + forged traffic plan"         "/v fix the login bug" "$_T4T_VALID" block TRAFFIC_PLAN
_t4_case "v-traffic + stub plan (<300B)"            "/v-traffic" "# TRAFFIC_PLAN
session: x" block TRAFFIC_PLAN
_t4_case "v-traffic + plan missing session line"    "/v-traffic" "# TRAFFIC_PLAN — project-a
data: GSC 2026-07-06. Padded well past the three hundred byte content-gate minimum so the size gate
and the session-line gate are exercised independently of each other in this fixture for v-traffic.
## Do this week
1. some action with enough padding text to clear the byte-size floor for this fixture here now.
" block TRAFFIC_PLAN

# /v-launch (2026-07-06) is report-only-adjacent: a plan-only run writes exactly one
# LAUNCH_PLAN_<sid>.md (`# LAUNCH_PLAN` heading + `session:` line, two signals) and no code, so
# CODE_CHANGED stays 0 — same escape shape as TRAFFIC_PLAN / V_NEXT_REPORT. Free-text verdict
# (`NO-GO — clear N MUST-FIX first`), so heading+session gate, no verdict enum (empty CHECK3).
# Forged/stub/session-less variants must BLOCK. (One-tap `fix N` hands a MUST-FIX to /v, which
# writes code → CODE_CHANGED=1 flips into /v's own full gauntlet — not this report-only escape.)
_T4L_VALID="# LAUNCH_PLAN — project-a (2026-07-06)
session: cafe0000
data: readiness gate + legal + channels   |   stage: launched

## Verdict
NO-GO — clear 1 MUST-FIX first

## Blockers (MUST-FIX)
1. Signup flow 500s on duplicate email — fix before launch. → reply fix 1

## Before launch (SHOULD-FIX)
- Add a status page; wire the pricing FAQ.

## Legal
Privacy policy + terms generated; cookie policy already present.

## Launch day
Show HN first, then Product Hunt next morning, then an X thread. Follow-up cadence over the week.
"
_t4_case "v-launch + valid plan"                    "/v-launch" "$_T4L_VALID" allow LAUNCH_PLAN
_t4_case "v-launch, NO plan"                         "/v-launch" ""            block LAUNCH_PLAN
_t4_case "generic /v + forged launch plan"          "/v fix the login bug" "$_T4L_VALID" block LAUNCH_PLAN
_t4_case "v-launch + stub plan (<300B)"             "/v-launch" "# LAUNCH_PLAN
session: x" block LAUNCH_PLAN
_t4_case "v-launch + plan missing session line"     "/v-launch" "# LAUNCH_PLAN — project-a
data: readiness. Padded well past the three hundred byte content-gate minimum so the size gate
and the session-line gate are exercised independently of each other in this fixture for v-launch.
## Verdict
GO — enough padding text here to clear the byte-size floor for this particular fixture now.
" block LAUNCH_PLAN

# ── Tier 4f: MERGE-ALL must NOT get a report-only escape (2026-08-13, DELIBERATE) ──
# A registry row for /v-merge-all was built, RED-proven, and then REVERTED after adversarial
# review found a reachable bypass. Recorded as tests so the decision is enforced, not just
# remembered — anyone re-adding the row will turn these red and have to read this block.
#
# WHY IT IS UNSAFE TODAY. /v-merge-all lands code via `git merge`/`git push` through the Bash
# tool. track-session-writes.sh only inspects Bash commands for a v-dispatch-subagent marker, so
# a conflict-free merge performs ZERO Edit/Write calls and leaves CODE_CHANGED=0. The two
# backstops that would otherwise catch it BOTH depend on head-baseline-<sid>.txt:
#   - check-review-artifact.sh component #2 (its own header claims it "runs UNCONDITIONALLY")
#   - the W-LIGHT2-CHORE commit-tag escape (needs >=1 tagged commit vs a baseline)
# That file is written by skills/v/references/v-bootstrap.sh, which runs INSIDE the dispatched
# subagent — so for a background-dispatched /v-merge-all it never exists in the PARENT session.
# Verified on disk 2026-08-13: a normal background-dispatch session has ONLY
# session-start-<sid>.txt, which holds a TIMESTAMP, not a SHA; another session has the bootstrap
# markers only because it manually ran v-bootstrap-wrapper.sh mid-session. With no HEAD baseline there is
# no non-forgeable precondition to gate the escape on, and the artifact's own "Branches merged: N"
# line is model-authored prose — too weak a bar for the one report-only skill whose job is moving
# code into main.
#
# PREREQUISITE for revisiting: a SessionStart-written HEAD SHA baseline for every session (
# session-start-marker.sh already runs unconditionally and could record it alongside the
# timestamp). With that, the row could be gated on machine-verified "HEAD did not move", which
# cannot be faked by the gated agent. Until then /v-merge-all correctly owes HANDOFF or the
# gauntlet.
_T4M_VALID="## Merge All Report

### Summary
- Branches discovered: 2 (1 unmerged feature branch + 1 already-merged cleanup candidate)
- Branches merged: 1 — landed as a no-op, content already byte-identical to main
- Branches skipped (gate-failed / unverified): 1
- Conflicts resolved: 0
- Worktrees discovered: 1 (main only)

### Merge Order & Results
| # | Branch | Files | Conflicts | Status |
|---|--------|-------|-----------|--------|
| 1 | fix/example-branch | 2 | 0 | merged (no-op) |

### Push Status
main is in sync with origin/main; nothing to push.
"
_t4_case "v-merge-all + valid report (NO escape by design)" "/v-merge-all" "$_T4M_VALID" block MERGE_ALL_REPORT
_t4_case "v-merge-all, NO report"                    "/v-merge-all" ""            block MERGE_ALL_REPORT
_t4_case "generic /v + forged merge-all report"     "/v fix the login bug" "$_T4M_VALID" block MERGE_ALL_REPORT
_t4_case "v-merge-all + stub report (<300B)"        "/v-merge-all" "## Merge All Report
### Summary
x" block MERGE_ALL_REPORT
_t4_case "v-merge-all + report missing Summary"     "/v-merge-all" "## Merge All Report
Padded well past the three hundred byte content-gate minimum so the size gate and the section
gate are exercised independently of each other in this fixture, exactly as the sibling rows do.
### Merge Order & Results
| 1 | fix/example-branch | 2 | 0 | merged | plus padding text to clear the byte-size floor here
" block MERGE_ALL_REPORT
_t4_case "PASTED merge-all cmd + valid report (NO escape)" "[Pasted text #1 +2 lines]" "$_T4M_VALID" block MERGE_ALL_REPORT "/v-merge-all"
_t4_case "PASTED generic /v + merge-all mention"    "[Pasted text #1 +2 lines]" "$_T4M_VALID" block MERGE_ALL_REPORT "/v fix the bug. also /v-merge-all is neat"

# ── Tier 5: DESIGN-FAMILY ESCAPE (Part B, 2026-07-05) — full-hook E2E in a sandbox ──
# Mirrors Tier 4 exactly, for the DESIGN-tier report-only skills (v-activation-funnel-design,
# v-pricing-design, v-beta-program, v-illustration-system — a prior skill-review report
# P0/F4). The escape must open ONLY for (history shows the SPECIFIC design skill) AND
# (content-validated artifact: >=300 bytes + expected H1 heading). Every other shape — no
# artifact, forged artifact under a generic /v session (launder), stub artifact, WRONG family's
# heading in the file — must still BLOCK (existing laundering guard preserved).
_t5_case() {
  # $1=name $2=history-display $3=artifact-basename-prefix (e.g. ACTIVATION_FUNNEL; "" = none
  # written) $4=artifact-content ("" = none) $5=expected (allow|block) $6="marker" = seed a
  # [subagent-dispatch] writes-log marker (CODEX-CRIT-1 2026-07-05: Step 9's mandated
  # v-dispatch-subagent.sh call always produces this in production; without it the fixture
  # under-models the real session state and the F1 IS_V_SESSION promotion bypass goes untested)
  local name="$1" display="$2" prefix="$3" content="$4" expect="$5" marker="${6:-}"
  local SID="dead0000-2222-4000-8000-$(printf '%04d%08d' $((RANDOM % 10000)) $((RANDOM * RANDOM % 100000000)))"
  local SBX; SBX=$(mktemp -d)
  mkdir -p "$SBX/home/.claude/projects/-sandbox" "$SBX/repo"
  ln -s "$HOME/.claude/hooks" "$SBX/home/.claude/hooks"
  ln -s "$HOME/.claude/skills" "$SBX/home/.claude/skills"
  if [ -n "$display" ]; then
    printf '{"sessionId":"%s","display":"%s","timestamp":1}\n' "$SID" "$display" > "$SBX/home/.claude/history.jsonl"
  else
    : > "$SBX/home/.claude/history.jsonl"
  fi
  git -C "$SBX/repo" init -q 2>/dev/null
  git -C "$SBX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  [ -n "$prefix" ] && [ -n "$content" ] && printf '%s' "$content" > "$SBX/repo/${prefix}_${SID}.md"
  [ "$marker" = "marker" ] && printf '[subagent-dispatch]\n' > "$SBX/repo/.git/claude-session-writes-${SID}.txt"
  local INPUT rc
  INPUT=$(printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Design complete. Strategy doc written."}' "$SID")
  (cd "$SBX/repo" && echo "$INPUT" | HOME="$SBX/home" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" bash "$HOOK" >/dev/null 2>&1)
  rc=$?
  rm -rf "$SBX" 2>/dev/null
  if [ "$expect" = allow ]; then
    [ "$rc" -eq 0 ] && _ok "T5 $name (allowed)" || _fail "T5 $name — expected allow, got rc=$rc"
  else
    [ "$rc" -eq 2 ] && _ok "T5 $name (blocked)" || _fail "T5 $name — expected block(2), got rc=$rc"
  fi
}
_T5_AFD="# Activation Funnel Design — Fixture Project
generated: 2026-07-05T00:00:00Z

Generated by v-activation-funnel-design v1.0

## Product category
API / developer tool / infrastructure

## First-success-event (FSE)
**Chosen:** first successful API call
**Why this and not alternatives:** fixture rationale text padding this document past the 300 byte minimum the content validator requires so the size gate and the heading gate are tested independently of each other.
"
_T5_PRICING="# Pricing Strategy — Fixture Project
generated: 2026-07-05T00:00:00Z

## Chosen model
Usage-based

## Why this and not alternatives
Fixture rationale text padding this document past the 300 byte minimum the content validator requires so the size gate and the heading gate are tested independently of each other in this regression harness.
"
# green: valid design-artifact session passes
_t5_case "activation-funnel-design + valid doc"        "/v-activation-funnel-design"     ACTIVATION_FUNNEL   "$_T5_AFD"     allow
_t5_case "pricing-design (sibling) + valid doc"        "/v-pricing-design"               PRICING_STRATEGY    "$_T5_PRICING" allow
# red: unrecognized / mismatched .md-only session still blocks
_t5_case "activation-funnel-design, NO artifact"       "/v-activation-funnel-design"     ""                   ""             block
_t5_case "generic /v + forged doc (launder)"           "/v fix the login bug"            ACTIVATION_FUNNEL    "$_T5_AFD"     block
_t5_case "activation-funnel-design + stub doc (<300B)" "/v-activation-funnel-design"     ACTIVATION_FUNNEL    "# Activation Funnel Design
tiny" block
_t5_case "activation-funnel-design + wrong heading"    "/v-activation-funnel-design"     ACTIVATION_FUNNEL    "# Pricing Strategy — Fixture Project
generated: 2026-07-05T00:00:00Z

This is padding text to clear the 300 byte minimum so only the heading mismatch is under test here, not the size gate, padding padding padding padding.
" block
# CODEX-CRIT-1 (2026-07-05): Step 9's v-dispatch-subagent.sh call writes a [subagent-dispatch]
# marker in EVERY real design-family run; the F1 promotion (IS_V_SESSION=1) must not carry the
# session past Part B — the escape must still fire on a valid doc, and a generic /v session
# with the same marker must still be unable to launder a forged doc through it.
_t5_case "valid doc + subagent-dispatch marker (F1 bypass)" "/v-activation-funnel-design"  ACTIVATION_FUNNEL    "$_T5_AFD"     allow  marker
_t5_case "generic /v + forged doc + dispatch marker"        "/v fix the login bug"         ACTIVATION_FUNNEL    "$_T5_AFD"     block  marker

# ── Tier 5b: STRICT FALLBACK PARITY (SREV-001 sweep, 2026-07-05) ──
# The SREV-001 substring-fallback fix must hold in ALL THREE Part-B escapes (skill-review,
# consolidate, design-family) — the vulnerable idiom was cloned before the fix landed. A real
# PASTED command must pass; a prose MENTION of the skill name in a pasted generic-/v session
# must still block, per escape. Reuses _t4_case ($5=artifact prefix, $6=transcript content).
_t4_case "PASTED consolidate cmd + valid report"            "[Pasted text #1 +2 lines]" "$_T4C_VALID" allow CONSOLIDATED_AUDIT_REPORT "/v-audit-consolidate"
_t4_case "PASTED generic /v + consolidate mention + forged" "[Pasted text #1 +2 lines]" "$_T4C_VALID" block CONSOLIDATED_AUDIT_REPORT "/v fix the bug. also /v-audit-consolidate is neat"
_t4_case "PASTED design cmd + valid doc"                    "[Pasted text #1 +2 lines]" "$_T5_AFD"    allow ACTIVATION_FUNNEL "/v-activation-funnel-design for acme"
_t4_case "PASTED generic /v + design mention + forged doc"  "[Pasted text #1 +2 lines]" "$_T5_AFD"    block ACTIVATION_FUNNEL "/v fix the bug. see /v-activation-funnel-design notes"


# -- Tier 6: AUDIT-FAMILY ESCAPE (Part B registry, 2026-07-05) -- full-hook E2E in a sandbox --
# The generalized escape for the per-dimension v-audit-* skills (v-audit-growth and siblings),
# added per a prior skill-review report P0. Unlike Tier 4/5 (fixed
# artifact name per row), this row is glob-shaped: any "<PREFIX>_AUDIT[_REPORT]_<ts>_${SID}.json"
# or ".md" satisfies the content gate, keyed on the same [A-Z][A-Z0-9_]*_(AUDIT|REPORT)_
# convention CODE_EXT_EXEMPT already recognizes. History-gated the same STRICT way as every
# other row (exact display match OR the W4B3/SREV-001 pasted-content-start fallback -- never a
# bare substring). F14 negative cases mandatory: a /v-tdd session must NOT match; an artifact
# belonging to a DIFFERENT session's SID must NOT match; a generic /v session (no audit
# invocation) forging a report must NOT match (existing laundering guard, same as every prior
# tier); v-audit-consolidate history must NOT ride this row (it has its own dedicated, stricter
# row above and is deliberately excluded from the family regex).
_t6_case() {
  # $1=name $2=history-display $3=artifact-filename-template (use __SID__ for this test's own
  #    SID; a literal foreign UUID exercises the "different session's artifact" negative case;
  #    "" = no artifact written) $4=artifact-content ("" = none) $5=expected (allow|block)
  #    $6=transcript first-user-message ("" = no transcript, mirrors _t4_case's pasted fallback)
  #    $7=SID override ("" = random; a metachar-bearing value exercises the SID glob-safety guard)
  local name="$1" display="$2" artifact_tpl="$3" content="$4" expect="$5" txcontent="${6:-}"
  local SID="beef0000-3333-4000-8000-$(printf '%04d%08d' $((RANDOM % 10000)) $((RANDOM * RANDOM % 100000000)))"
  [ -n "${7:-}" ] && SID="$7"
  local SBX; SBX=$(mktemp -d)
  mkdir -p "$SBX/home/.claude/projects/-sandbox" "$SBX/repo"
  ln -s "$HOME/.claude/hooks" "$SBX/home/.claude/hooks"
  ln -s "$HOME/.claude/skills" "$SBX/home/.claude/skills"
  if [ -n "$display" ]; then
    printf '{"sessionId":"%s","display":"%s","timestamp":1}\n' "$SID" "$display" > "$SBX/home/.claude/history.jsonl"
  else
    : > "$SBX/home/.claude/history.jsonl"
  fi
  if [ -n "$txcontent" ]; then
    printf '{"type":"user","content":"%s"}\n' "$txcontent" > "$SBX/home/.claude/projects/-sandbox/${SID}.jsonl"
  fi
  git -C "$SBX/repo" init -q 2>/dev/null
  git -C "$SBX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "$artifact_tpl" ] && [ -n "$content" ]; then
    local fname="${artifact_tpl//__SID__/$SID}"
    printf '%s' "$content" > "$SBX/repo/${fname}"
  fi
  local INPUT rc
  INPUT=$(printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Audit complete. Report written with findings."}' "$SID")
  (cd "$SBX/repo" && echo "$INPUT" | HOME="$SBX/home" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" bash "$HOOK" >/dev/null 2>&1)
  rc=$?
  rm -rf "$SBX" 2>/dev/null
  if [ "$expect" = allow ]; then
    [ "$rc" -eq 0 ] && _ok "T6 $name (allowed)" || _fail "T6 $name -- expected allow, got rc=$rc"
  else
    [ "$rc" -eq 2 ] && _ok "T6 $name (blocked)" || _fail "T6 $name -- expected block(2), got rc=$rc"
  fi
}
_T6_GROWTH_VALID='{
  "skill": "v-audit-growth",
  "generated": "2026-07-05T12:00:00Z",
  "project": "sandbox",
  "dimensions": {
    "activation": {"score": 7, "findings": []},
    "retention": {"score": 6, "findings": []},
    "feedback_loops": {"score": 8, "findings": []},
    "cro": {"score": 5, "findings": []}
  },
  "overall_score": 6.5,
  "summary": "Fixture growth audit JSON padded well past the 300 byte content-gate minimum so the size gate and the filename-prefix gate are exercised independently of each other in this regression harness."
}'
_T6_ADMIN_VALID='{
  "skill": "v-audit-admin",
  "generated": "2026-07-05T12:00:00Z",
  "project": "sandbox",
  "domains": {"crud": {"score": 8}, "bulk_ops": {"score": 6}},
  "overall_score": 7,
  "summary": "Fixture admin audit JSON using the ADMIN_AUDIT_REPORT_ naming convention (AUDIT then REPORT before the timestamp) padded past the 300 byte content-gate minimum, to prove the (AUDIT|REPORT) alternation covers this sibling shape too."
}'
# green: valid per-dimension audit session passes, including the AUDIT_REPORT-shaped sibling
_t6_case "growth-audit + valid JSON artifact"             "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.json"       "$_T6_GROWTH_VALID" allow
_t6_case "admin-audit (AUDIT_REPORT-shaped name) + valid" "/v-audit-admin"  "ADMIN_AUDIT_REPORT_20260705_120000___SID__.json" "$_T6_ADMIN_VALID"  allow
# red: no artifact, stub artifact, generic /v forgery -- still block (existing guard preserved)
_t6_case "growth-audit, NO artifact"                      "/v-audit-growth" ""                                                 ""                   block
_t6_case "growth-audit + stub artifact (<300B)"           "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.json"       "tiny stub"          block
_t6_case "generic /v + forged growth artifact (launder)"  "/v fix the login bug" "GROWTH_AUDIT_20260705_120000___SID__.json"  "$_T6_GROWTH_VALID"  block
# F14 negative #1 (mandatory): a non-audit skill session must NOT ride this escape
_t6_case "v-tdd session + forged growth artifact (F14: non-audit skill must not match)" "/v-tdd fix the thing" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_GROWTH_VALID" block
# F14 negative #2 (mandatory): an artifact belonging to a DIFFERENT session's SID must NOT match
_t6_case "growth-audit history + artifact stamped with a DIFFERENT sid (F14: cross-session artifact must not match)" "/v-audit-growth" "GROWTH_AUDIT_20260705_120000_ffffffff-ffff-ffff-ffff-ffffffffffff.json" "$_T6_GROWTH_VALID" block
# extra rigor: consolidate has its own dedicated row and is excluded from the family regex --
# consolidate history + a growth-shaped artifact must still block (no accidental cross-credit)
_t6_case "consolidate history + growth artifact cross-mismatch" "/v-audit-consolidate" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_GROWTH_VALID" block
# pasted-fallback strict parity (SREV-001 sweep applies to this row too)
_t6_case "PASTED growth-audit cmd + valid artifact"                "[Pasted text #1 +2 lines]" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_GROWTH_VALID" allow "/v-audit-growth for acme"
_t6_case "PASTED generic /v + growth mention + forged artifact"    "[Pasted text #1 +2 lines]" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_GROWTH_VALID" block "/v fix the bug. see /v-audit-growth notes"
# -- content-gate hardening (2026-07-05 hostile-review round) -- the glob row must validate
# CONTENT with the same rigor as the fixed-name rows: garbage bytes, non-audit JSON, names
# without a timestamp segment, heading-less md, and glob-metachar SIDs must all fail closed.
_T6_GARBAGE='lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ut enim ad minim veniam quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur excepteur sint occaecat cupidatat non proident'
_T6_NONAUDIT_JSON='{
  "skill": "v-growth",
  "generated": "2026-07-05T12:00:00Z",
  "project": "sandbox",
  "summary": "Valid JSON that parses cleanly and clears the 300 byte size gate but carries no domain token anywhere in its body -- a laundered non-report file wearing a report-shaped filename. The content gate must reject it even though the filename regex, the size gate, and the JSON-parse gate all pass. Padding padding padding padding padding."
}'
_T6_POLISH_MD='# AUDIT_CODE_REPORT

Fixture markdown report for the md-only sibling (v-audit-code produces no consolidated JSON). Contains a real heading line and the audit domain token, padded well past the 300 byte content-gate minimum so the honest md-report path stays green after the content-gate hardening round. Scores: overall 7.2, verdict READY WITH CAVEATS.'
_T6_DECOY_JSON='{
  "note": "audit audit audit -- a decoy artifact that is syntactically valid JSON, name-drops the domain token in free text, clears the 300 byte floor and the timestamp-anchored filename regex, but carries NO structural key any real sibling schema emits (no audit_* key, no findings, no overall_score, no scorecard). Live-proven bypass in the 2026-07-05 re-verification round (CONDITIONAL_PASS residual); the key-shaped content gate must reject it."
}'
_t6_case "growth-audit + garbage non-JSON artifact (content gate)" "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_GARBAGE"       block
_t6_case "growth-audit + decoy JSON (audit token in free text, no structural key)" "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_DECOY_JSON" block
_t6_case "growth-audit + valid JSON but non-audit content"         "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.json" "$_T6_NONAUDIT_JSON" block
_t6_case "growth-audit + REPORT-name with no timestamp segment"    "/v-audit-growth" "ACME_REPORT_notes___SID__.json"            "$_T6_GROWTH_VALID"  block
_t6_case "growth-audit + garbage md (no heading, no audit token)"  "/v-audit-growth" "GROWTH_AUDIT_20260705_120000___SID__.md"   "$_T6_GARBAGE"       block
_t6_case "polish (md-only sibling) + valid AUDIT_CODE_REPORT md" "/v-audit-code" "AUDIT_CODE_REPORT_20260705_120000___SID__.md" "$_T6_POLISH_MD" allow

# -- Tier 6b: HUNT-FAMILY ESCAPE (Part B registry, 2026-07-05; MIGRATED 2026-07-05) -- v-bug-hunt only --
# v-edge-hunt was MERGED into v-bug-hunt as a `boundaries` lens and its skill directory archived
# (~/.claude/archive/skills-merged-2026-07-05/v-edge-hunt/); this row now recognizes ONLY
# BUG_HUNT_REPORT_* (both lenses write that single artifact shape -- see v-bug-hunt SKILL.md §
# Two lenses, one skill). Report-only, subagent-dispatching audit that was previously absent from
# BOTH escape paths and false-blocked every standalone run (CODEX-CRIT-1 recurrence). Its row is
# glob-shaped but keyed on the GUARANTEED report HEADING (# BUG_HUNT_REPORT) + timestamped REPORT
# filename -- NOT the audit family's loose "audit" body token. Same evidence+content gates and
# same existing / F14 laundering guards as Tier 6. Reuses _t6_case (writes <name>_<sid>.md, drives
# the real hook E2E).
_T6B_BH_VALID='# BUG_HUNT_REPORT — sandbox / auth
generated: 2026-07-05_1301
session: cafe
target: auth
depth: Thorough

## EXECUTIVE_SUMMARY
Adversarial end-to-end defect sweep of the auth flow: one P1 race on concurrent registration, the rest
cleared. Fixture report padded well past the 300 byte content-gate minimum so the size gate and the
heading gate are exercised independently of each other in this regression harness for the hunt family.

## FINDINGS
### BUG-AUTH-01 | app/Auth.php:52 | race | high | high
Two simultaneous registrations of the same email both succeed.'
_T6B_BH_BOUNDARIES_VALID='# BUG_HUNT_REPORT — sandbox / billing
generated: 2026-07-05_1301
session: cafe
lens: boundaries
target: billing
depth: Thorough

## EXECUTIVE_SUMMARY
Boundaries-lens sweep of the billing subsystem: one P1 JPY 0-decimal proration edge, the remaining
dimensions passed. Fixture report padded well past the 300 byte content-gate minimum so the size
gate and the heading gate are exercised independently of each other in this regression harness.

## FINDINGS
### EHUNT-MONEY-01 | app/Billing.php:134 | money | high | high
JPY (0-decimal currency) proration corrupts the invoice total.'
# green: valid bug-hunt reports pass regardless of lens (bugs lens .md, boundaries lens .md)
_t6_case "bug-hunt (bugs lens) + valid BUG_HUNT_REPORT md" "/v-bug-hunt auth"     "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md"  "$_T6B_BH_VALID" allow
_t6_case "bug-hunt --lens=boundaries + valid BUG_HUNT_REPORT md" "/v-bug-hunt billing --lens=boundaries" "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md" "$_T6B_BH_BOUNDARIES_VALID" allow
# red: no report, stub, generic-/v forgery (existing launder guard) -- still block
_t6_case "bug-hunt, NO report"                           "/v-bug-hunt billing"  ""                                             ""               block
_t6_case "bug-hunt + stub report (<300B)"                 "/v-bug-hunt billing"  "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md"  "# BUG_HUNT_REPORT tiny" block
_t6_case "generic /v + forged bug-hunt report (launder)"  "/v fix the login bug" "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md"  "$_T6B_BH_VALID" block
# content-gate: heading-less body, and REPORT name with no timestamp segment -- both fail closed
_t6_case "bug-hunt + heading-less md (content gate)"      "/v-bug-hunt billing"  "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md"  "no heading here just prose padded past three hundred bytes ................................................................................................................................................................................................................ end" block
_t6_case "bug-hunt + REPORT name w/ no timestamp seg"    "/v-bug-hunt billing"  "BUG_HUNT_REPORT_notes___SID__.md"            "$_T6B_BH_VALID" block
# F14 negatives (mandatory): non-hunt skill must not ride; cross-session artifact must not match
_t6_case "v-tdd session + forged bug-hunt report (F14)"   "/v-tdd fix the thing" "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md"  "$_T6B_BH_VALID" block
_t6_case "bug-hunt history + DIFFERENT sid artifact (F14)" "/v-bug-hunt billing" "BUG_HUNT_REPORT_2026-07-05_1301_ffffffff-ffff-ffff-ffff-ffffffffffff.md" "$_T6B_BH_VALID" block
# pasted-fallback strict parity (SREV-001 sweep applies to this row too)
_t6_case "PASTED bug-hunt cmd + valid report"             "[Pasted text #1 +2 lines]" "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md" "$_T6B_BH_VALID" allow "/v-bug-hunt billing"
_t6_case "PASTED generic /v + hunt mention + forged"      "[Pasted text #1 +2 lines]" "BUG_HUNT_REPORT_2026-07-05_1301___SID__.md" "$_T6B_BH_VALID" block "/v fix the bug. also /v-bug-hunt is neat"
# migration regression (2026-07-05): a legacy EDGE_HUNT_REPORT shape (the retired v-edge-hunt
# artifact name/heading) must NOT ride this escape anymore -- both the evidence gate ('v-bug-hunt'
# no longer matches a "/v-edge-hunt" history entry) and the content gate (glob keys on
# BUG_HUNT_REPORT only now) must independently reject it, proving the migration closed the old
# shape rather than leaving it silently still-accepted.
_T6B_EH_LEGACY='# EDGE_HUNT_REPORT — sandbox / billing
generated: 2026-07-05_1301
session: cafe
target: billing
depth: Thorough

## EXECUTIVE_SUMMARY
Legacy edge-hunt-shaped report padded well past the 300 byte content-gate minimum to prove this
shape is rejected on its own content gate, not merely because it is short.

## FINDINGS
### EHUNT-MONEY-01 | app/Billing.php:134 | money | high | high
JPY (0-decimal currency) proration corrupts the invoice total.'
_t6_case "legacy /v-edge-hunt invocation + legacy EDGE_HUNT_REPORT (post-merge, must block)" "/v-edge-hunt billing" "EDGE_HUNT_REPORT_2026-07-05_1301___SID__.md" "$_T6B_EH_LEGACY" block

# SID glob-safety (two-layer lock): lib/resolve-sid.sh already rejects any non-UUID SID (the
# strict UUID grep), so a metachar SID resolves EMPTY and the hook takes the generic no-SID
# path -- it never reaches Part B, and the family row's own [A-Za-z0-9-] case guard is the
# second layer behind it. rc alone can't distinguish "generic pass" from "escape credit", so
# this case asserts the invariant directly: the hook must NEVER emit the "Audit-family
# completion" systemMessage for a SID the resolver would reject (glob-widening gets no escape
# credit at EITHER layer).
_t6_sid_guard() {
  local SID='beef*000-3333-4000-8000-000000000000'
  local SBX; SBX=$(mktemp -d)
  mkdir -p "$SBX/home/.claude/projects/-sandbox" "$SBX/repo"
  ln -s "$HOME/.claude/hooks" "$SBX/home/.claude/hooks"
  ln -s "$HOME/.claude/skills" "$SBX/home/.claude/skills"
  printf '{"sessionId":"%s","display":"/v-audit-growth","timestamp":1}\n' "$SID" > "$SBX/home/.claude/history.jsonl"
  git -C "$SBX/repo" init -q 2>/dev/null
  git -C "$SBX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  printf '%s' "$_T6_GROWTH_VALID" > "$SBX/repo/GROWTH_AUDIT_20260705_120000_${SID}.json"
  local INPUT out
  INPUT=$(printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Audit complete. Report written with findings."}' "$SID")
  out=$( (cd "$SBX/repo" && echo "$INPUT" | HOME="$SBX/home" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" bash "$HOOK" 2>/dev/null) || true )
  rm -rf "$SBX" 2>/dev/null
  if printf '%s' "$out" | grep -q "Audit-family completion"; then
    _fail "T6 glob-metachar SID must fail closed (SID guard) -- escape credit granted"
  else
    _ok "T6 glob-metachar SID must fail closed (no escape credit at either layer)"
  fi
}
_t6_sid_guard

# ── Tier 7: SELF-AUDIT ESCAPE (Part B registry row, 2026-07-05) ──
# /v-self-audit is context:fork + report-only: dispatches sub-agents (HAS_SUBAGENT_DISPATCH=1),
# changes no code, and writes its terminal SELF_AUDIT_SUMMARY under .v/self-audit/<sid>/ (NOT in
# ARTIFACT_SEARCH_DIRS). Before its row it was promoted to IS_V_SESSION=1 and false-blocked on
# EVERY run (CODEX-CRIT-1 recurrence -- the 2026-07-05 escape-registry merge missed this skill).
# Its own row is history-gated + content-validated on the two signals SKILL.md's final-report
# template guarantees: the '# SELF_AUDIT_SUMMARY' heading + an 'Overall: PASS|FINDINGS|BLOCK'
# verdict line (the SAME two the skill's self-check validates -- producer≡validator parity). A
# separate helper from _t6_case because the artifact lives in the self-audit dir, not REPO_ROOT.
_t7_case() {
  # $1=name $2=history-display $3=summary-content ("" = no summary written) $4=expect(allow|block)
  # $5=transcript first-user-message ("" = none; exercises the pasted-content-start fallback)
  local name="$1" display="$2" summary="$3" expect="$4" txcontent="${5:-}"
  local SID="7e1f0000-5555-4000-8000-$(printf '%04d%08d' $((RANDOM % 10000)) $((RANDOM * RANDOM % 100000000)))"
  local SBX; SBX=$(mktemp -d)
  mkdir -p "$SBX/home/.claude/projects/-sandbox" "$SBX/repo"
  ln -s "$HOME/.claude/hooks" "$SBX/home/.claude/hooks"
  ln -s "$HOME/.claude/skills" "$SBX/home/.claude/skills"
  if [ -n "$display" ]; then
    printf '{"sessionId":"%s","display":"%s","timestamp":1}\n' "$SID" "$display" > "$SBX/home/.claude/history.jsonl"
  else
    : > "$SBX/home/.claude/history.jsonl"
  fi
  [ -n "$txcontent" ] && printf '{"type":"user","content":"%s"}\n' "$txcontent" > "$SBX/home/.claude/projects/-sandbox/${SID}.jsonl"
  git -C "$SBX/repo" init -q 2>/dev/null
  git -C "$SBX/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  if [ -n "$summary" ]; then
    mkdir -p "$SBX/repo/.v/self-audit/$SID"
    printf '%s' "$summary" > "$SBX/repo/.v/self-audit/$SID/SELF_AUDIT_SUMMARY_${SID}.md"
  fi
  # A real /v-self-audit ALWAYS dispatches sub-agents via v-dispatch-subagent.sh -> the session
  # writes log carries a [subagent-dispatch] marker, which is what triggers the F1 IS_V_SESSION
  # promotion. Seed it so every case exercises the REAL promotion path (the escape must skip the
  # promotion via _RO_REPORT_ONLY_ERE): without this a regression of the ERE-token edit would slip
  # through (the row alone would still allow via Part B). The allow cases now depend on BOTH edits.
  printf '[subagent-dispatch]\n.v/self-audit/%s/SELF_AUDIT_SUMMARY_%s.md\n' "$SID" "$SID" \
    > "$SBX/repo/.git/claude-session-writes-${SID}.txt"
  local INPUT rc
  INPUT=$(printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"Self-audit complete. Summary written."}' "$SID")
  (cd "$SBX/repo" && echo "$INPUT" | HOME="$SBX/home" CLAUDE_SESSION_ID="" CLAUDE_CODE_SESSION_ID="" bash "$HOOK" >/dev/null 2>&1)
  rc=$?
  rm -rf "$SBX" 2>/dev/null
  if [ "$expect" = allow ]; then
    [ "$rc" -eq 0 ] && _ok "T7 $name (allowed)" || _fail "T7 $name — expected allow, got rc=$rc"
  else
    [ "$rc" -eq 2 ] && _ok "T7 $name (blocked)" || _fail "T7 $name — expected block(2), got rc=$rc"
  fi
}
_T7_VALID="# SELF_AUDIT_SUMMARY

Target: /v orchestrator system (~/.claude)
Stages run: 1-6

## Artifacts
- AUDIT_REPORT: path (3 findings)
- SHIP_LIST: path (2 low-risk recommended, 1 deferred)

## North-star metrics
- proactive backtest catch rate: 4/5
- mutation kill-rate: 9/10

## Recommended now (LOW-risk only)
- item one

## Deferred (MEDIUM/HIGH — opt-in)
- item two

Overall: FINDINGS
"
# green: valid summary in the self-audit dir passes (both bare and pasted invocation)
_t7_case "self-audit + valid summary in .v/self-audit"   "/v-self-audit"        "$_T7_VALID" allow
_t7_case "PASTED self-audit cmd + valid summary"         "[Pasted text #1 +2 lines]" "$_T7_VALID" allow "/v-self-audit --quick"
# red: no summary, generic-/v forgery (existing launder guard), and content-gate misses
_t7_case "self-audit, NO summary"                        "/v-self-audit"        ""           block
_t7_case "generic /v + forged summary (launder)"         "/v fix the login bug" "$_T7_VALID" block
_t7_case "v-tdd session + forged summary (F14: non-self-audit skill must not match)" "/v-tdd fix it" "$_T7_VALID" block
_t7_case "self-audit + summary missing Overall verdict"  "/v-self-audit"        "# SELF_AUDIT_SUMMARY

## Artifacts
- AUDIT_REPORT: path to the audit report with several findings recorded here

This summary deliberately omits the machine-readable verdict line, so the ONLY reason the hook has
to block it is the absent 'Overall:' verdict — padding padding padding padding padding to clear the
300-byte content floor and isolate that single failing signal in this regression harness." block
_t7_case "self-audit + stub summary (<300B)"             "/v-self-audit"        "# SELF_AUDIT_SUMMARY
Overall: PASS" block

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
