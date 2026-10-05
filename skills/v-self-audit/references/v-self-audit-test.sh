#!/usr/bin/env bash
# v-self-audit-test.sh — contract harness for the /v-self-audit skill.
# Verifies the skill's structure, dispatch wiring, and template≡consumer round-trip
# WITHOUT running the (expensive, model-dispatching) skill itself. Deterministic,
# read-only. Prints "TOTAL: N passed, M failed" and exits non-zero on any failure.
set -u

ROOT="${CLAUDE_ROOT:-$HOME/.claude}"
SK="$ROOT/skills/v-self-audit"
SKILL="$SK/SKILL.md"
DISP="$SK/references/v-self-audit-dispatch.md"
PROTO="$SK/references/v-self-audit-protocol.md"
AGENT="$ROOT/agents/v-orchestrator-auditor.md"
CODEX="$ROOT/agents/codex-adversarial-reviewer.md"
HELPER="$ROOT/skills/v/references/v-dispatch-subagent.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
exists(){ if [ -f "$1" ]; then ok; else bad "missing file: $1"; fi; }
has(){ if grep -qF -- "$2" "$1" 2>/dev/null; then ok; else bad "$3"; fi; }
hasre(){ if grep -qE -- "$2" "$1" 2>/dev/null; then ok; else bad "$3"; fi; }

# --- files exist (skill + dependencies) ---
exists "$SKILL"
exists "$DISP"
exists "$PROTO"
exists "$AGENT"
exists "$CODEX"      # adversarial-stage dependency
exists "$HELPER"     # dispatch dependency

# --- SKILL.md frontmatter ---
has "$SKILL" "name: v-self-audit" "SKILL name slug"
has "$SKILL" "user-invocable: true" "user-invocable: true"
has "$SKILL" "context: fork" "context: fork"
has "$SKILL" "disable-model-invocation: true" "disable-model-invocation: true"
hasre "$SKILL" "^model: " "model pin"
hasre "$SKILL" "^allowed-tools: " "allowed-tools present"
has "$SKILL" "BashOutput" "allowed-tools includes BashOutput (required for polling auto-backgrounded stage dispatches)"

# --- SKILL.md size (Anthropic progressive-disclosure cap) ---
LC=$(wc -l < "$SKILL" 2>/dev/null | tr -d ' '); LC=${LC:-9999}
if [ "$LC" -le 500 ]; then ok; else bad "SKILL.md >500 lines ($LC)"; fi

# --- 6 stage anchors in SKILL.md ---
for n in 1 2 3 4 5 6; do has "$SKILL" "### Stage $n" "SKILL stage-$n anchor"; done

# --- artifact names appear >=2x in SKILL.md (table + final report = round-trip) ---
for a in AUDIT_REPORT EFFICIENCY_REPORT ADVERSARIAL_REVIEW SHIP_LIST TESTING_AUDIT TESTING_PLAN SELF_AUDIT_SUMMARY; do
  C=$(grep -cF -- "$a" "$SKILL" 2>/dev/null); C=${C:-0}
  if [ "$C" -ge 2 ]; then ok; else bad "artifact $a appears <2x in SKILL.md ($C) — template/consumer round-trip"; fi
done

# --- dispatch reference wiring ---
has "$DISP" "v-dispatch-subagent.sh" "dispatch uses helper"
has "$DISP" "--agent v-orchestrator-auditor" "dispatch auditor agent"
has "$DISP" "--agent codex-adversarial-reviewer" "dispatch codex (independent) agent"
CAP=$(grep -cF -- "--mode capture" "$DISP" 2>/dev/null); CAP=${CAP:-0}
if [ "$CAP" -ge 6 ]; then ok; else bad "dispatch has <6 '--mode capture' ($CAP)"; fi
BF=$(grep -cF -- '```bash' "$DISP" 2>/dev/null); BF=${BF:-0}
if [ "$BF" -ge 6 ]; then ok; else bad "dispatch has <6 bash fences ($BF)"; fi
for n in 1 2 3 4 5 6; do has "$DISP" "## Stage $n" "dispatch stage-$n header"; done
for a in AUDIT_REPORT EFFICIENCY_REPORT ADVERSARIAL_REVIEW SHIP_LIST TESTING_AUDIT TESTING_PLAN; do
  has "$DISP" "$a" "dispatch emits $a"
done

# --- protocol section headers + emitted artifacts ---
has "$PROTO" "## Stage 1 — Code audit" "proto stage-1 header"
has "$PROTO" "## Stage 2 — Efficiency evaluation" "proto stage-2 header"
has "$PROTO" "## Stage 3 — Adversarial review" "proto stage-3 header"
has "$PROTO" "## Stage 4 — Synthesis" "proto stage-4 header"
has "$PROTO" "## Stage 5 — Testing audit" "proto stage-5 header"
has "$PROTO" "## Stage 6 — Testing synthesis" "proto stage-6 header"
for a in AUDIT_REPORT EFFICIENCY_REPORT ADVERSARIAL_REVIEW SHIP_LIST TESTING_AUDIT TESTING_PLAN; do
  has "$PROTO" "$a" "proto defines $a structure"
done

# --- stronger contract (review MEDIUM): each artifact is ACTUALLY emitted by a dispatch --artifact
# flag (NAME_<sid>) AND defined by an "Emit # NAME" heading in the protocol. Catches the class where
# an artifact is named in prose but never emitted by a dispatch or instructed in the protocol. ---
for a in AUDIT_REPORT EFFICIENCY_REPORT ADVERSARIAL_REVIEW SHIP_LIST TESTING_AUDIT TESTING_PLAN; do
  has "$DISP" "${a}_" "dispatch --artifact emits ${a}_<sid>"
  has "$PROTO" "# $a" "protocol instructs 'Emit # $a'"
done

# --- round-trip: each stage section name the dispatch references must exist in the protocol ---
for s in "Stage 1 — Code audit" "Stage 2 — Efficiency evaluation" "Stage 3 — Adversarial review" "Stage 4 — Synthesis" "Stage 5 — Testing audit" "Stage 6 — Testing synthesis"; do
  if grep -qF -- "$s" "$DISP" 2>/dev/null && grep -qF -- "$s" "$PROTO" 2>/dev/null; then ok; else bad "section round-trip mismatch: $s"; fi
done

# --- convention reference must be an ABSOLUTE path (2026-07-05 P2): a bare skill-relative
# `references/v-runnable-pack-convention.md` resolves to this skill's own references/ dir, which
# does NOT contain it — the file lives at skills/references/. Both Stage-4 citations must use the
# absolute ~/.claude/skills/references/ form (matching the protocol). ---
ABSCONV=$(grep -cF -- '~/.claude/skills/references/v-runnable-pack-convention.md' "$SKILL" 2>/dev/null); ABSCONV=${ABSCONV:-0}
if [ "$ABSCONV" -ge 2 ]; then ok; else bad "SKILL.md convention citation(s) not absolute-pathed ($ABSCONV/2 use ~/.claude/skills/references/)"; fi
# negative: the broken bare skill-relative citation must NOT appear (would mis-resolve to this skill's references/)
if grep -nE '[^/]references/v-runnable-pack-convention\.md' "$SKILL" 2>/dev/null | grep -vqF 'skills/references/'; then
  bad "SKILL.md still has a bare 'references/v-runnable-pack-convention.md' (mis-resolves to skill-local references/)"
else ok; fi

# --- SELF_AUDIT_SUMMARY producer/validator parity (2026-07-05 P2): the summary is this skill's
# report-only Stop-completion artifact, so the skill must (a) validate the exact two signals the
# Stop hook gates on — the '# SELF_AUDIT_SUMMARY' heading + an 'Overall: PASS|FINDINGS|BLOCK' line —
# in its self-check, and (b) document that contract so a run never skips the summary. ---
has "$SKILL" '^#+[[:space:]]*SELF_AUDIT_SUMMARY' "self-check validates SELF_AUDIT_SUMMARY heading"
has "$SKILL" 'Overall:[[:space:]]*(PASS|FINDINGS|BLOCK)' "self-check validates Overall verdict line"
has "$SKILL" "report-only completion artifact" "SKILL documents summary as the Stop-hook completion artifact"

# --- Stop-hook report-only escape (2026-07-05 P0): /v-self-audit is context:fork + report-only and
# dispatches sub-agents (HAS_SUBAGENT_DISPATCH=1), so without a Stop-hook escape it is promoted to
# IS_V_SESSION=1 and false-blocked on a gauntlet it can never run. The escape needs BOTH the
# promotion-skip ERE token AND a Part-B row keyed on SELF_AUDIT_SUMMARY. Cross-check the hook so
# removing either half fails THIS harness (the full behavioral bite lives in check-review-artifact-
# test.sh Tier 7). ---
CRA="$ROOT/hooks/check-review-artifact.sh"
exists "$CRA"
hasre "$CRA" "\|v-self-audit[|']" "hook _RO_REPORT_ONLY_ERE registers v-self-audit (promotion-skip)"
has "$CRA" 'SELF_AUDIT_SUMMARY_${SESSION_ID}.md' "hook Part-B row gates on SELF_AUDIT_SUMMARY_<sid>"
has "$CRA" 'Overall:[[:space:]]*(PASS|FINDINGS|BLOCK)' "hook content-gate matches the skill's verdict enum"

# --- auditor agent: capture-mode safe (no Write), has tools + model ---
hasre "$AGENT" "^name: v-orchestrator-auditor" "auditor name"
hasre "$AGENT" "^tools: " "auditor tools line"
hasre "$AGENT" "^model: " "auditor model pin"
TLINE=$(grep -m1 "^tools:" "$AGENT" 2>/dev/null)
if printf '%s' "$TLINE" | grep -qw "Write"; then bad "auditor must NOT grant Write (capture mode)"; else ok; fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
