# v-self-audit — dispatch blocks (runnable source of truth)

Each stage is one fenced bash block below. Run them in order (1→6; stop after 4 under `--quick`). Bash state does not persist across tool calls, so every block re-derives `SID`/`ADIR`/`HELPER`/`PROTO`. Each dispatch is **blocking**; if it auto-backgrounds past the 600s cap, poll via `BashOutput` — never set `run_in_background:true`, never go passive. Capture mode means the sub-agent emits the artifact as its final message and the helper writes it (the agents have no Write tool).

Helper interface: `v-dispatch-subagent.sh --agent NAME --prompt-file FILE --artifact PATH --mode capture` (exit 0 = ran + artifact present; non-zero = caller owns the fallback).

## Stage 1 — Code audit → AUDIT_REPORT

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
PF="$ADIR/prompt-stage1.txt"
cat > "$PF" <<EOF
You are running STAGE 1 (Code audit) of /v-self-audit.
Read the "Stage 1 — Code audit" section of $PROTO and execute it exactly against the /v system under ~/.claude.
Ground-truth every claim against disk (cite path:line; tag confidence). Compose with v-skill-reviewer for the skill-review dimension; do not duplicate it.
Emit the full AUDIT_REPORT as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" \
  --artifact "$ADIR/AUDIT_REPORT_${SID}.md" --mode capture
echo "stage1 rc=$? -> $ADIR/AUDIT_REPORT_${SID}.md"
```

## Stage 2 — Efficiency evaluation (fact-based) → EFFICIENCY_REPORT

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
PF="$ADIR/prompt-stage2.txt"
cat > "$PF" <<EOF
You are running STAGE 2 (Efficiency evaluation, fact-based) of /v-self-audit.
Read the "Stage 2 — Efficiency evaluation" section of $PROTO and execute it exactly against real recent /v session telemetry.
Measure cached (cache_read) vs non-cached (cache_creation + output) tokens, price-weighted, per consumer/stage, plus wall-clock per stage/gate. Self-validate the measurement before trusting any lever size; degrade loud if a tool is missing.
Emit the full EFFICIENCY_REPORT as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" \
  --artifact "$ADIR/EFFICIENCY_REPORT_${SID}.md" --mode capture
echo "stage2 rc=$? -> $ADIR/EFFICIENCY_REPORT_${SID}.md"
```

## Stage 3 — Adversarial review (independent) → ADVERSARIAL_REVIEW

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
ART="$ADIR/ADVERSARIAL_REVIEW_${SID}.md"; PF="$ADIR/prompt-stage3.txt"
cat > "$PF" <<EOF
You are running STAGE 3 (Adversarial review) of /v-self-audit.
There is no git diff to review — the artifacts UNDER REVIEW are the audit findings at
  $ADIR/AUDIT_REPORT_${SID}.md
  $ADIR/EFFICIENCY_REPORT_${SID}.md
Read both, then follow the "Stage 3 — Adversarial review" section of $PROTO.
Verify each finding against the /v codebase under ~/.claude. Assign every finding {Confirmed|Refuted|Overstated|Understated|Unverifiable} and every proposed fix/lever {Ship|Revise|Reject}. REJECT anything that would weaken a gate; refute over-claimed lever sizes. Default to skeptical when uncertain.
Emit the full ADVERSARIAL_REVIEW as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent codex-adversarial-reviewer --prompt-file "$PF" --artifact "$ART" --mode capture
RC=$?
if [ "$RC" -ne 0 ] || ! grep -qiE 'confirmed|refuted|verdict|ship|reject' "$ART" 2>/dev/null; then
  echo "stage3: codex unavailable/empty (rc=$RC) — degrading to independent auditor adversarial dispatch"
  printf '\n[FALLBACK] codex was unavailable; you are v-orchestrator-auditor doing this adversarial review instead. Add a top line "independence: degraded".\n' >> "$PF"
  bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" --artifact "$ART" --mode capture
fi
echo "stage3 rc=$? -> $ART"
```

## Stage 4 — Synthesis → SHIP_LIST

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
PF="$ADIR/prompt-stage4.txt"
cat > "$PF" <<EOF
You are running STAGE 4 (Synthesis) of /v-self-audit.
Inputs (read all three):
  $ADIR/AUDIT_REPORT_${SID}.md
  $ADIR/EFFICIENCY_REPORT_${SID}.md
  $ADIR/ADVERSARIAL_REVIEW_${SID}.md
Follow the "Stage 4 — Synthesis" section of $PROTO. Produce ONE deduplicated, dependency-ordered SHIP LIST of gate-safe code fixes + a ranked efficiency-lever set, each tagged risk + measured-impact + bill/wall-clock. By DEFAULT recommend only LOW-risk, gate-safe items; route MEDIUM/HIGH to a separate "Deferred / opt-in" section. Drop anything the adversarial stage Refuted or marked Reject. Each code fix carries a regression-test spec.
Emit the full SHIP_LIST as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" \
  --artifact "$ADIR/SHIP_LIST_${SID}.md" --mode capture
echo "stage4 rc=$? -> $ADIR/SHIP_LIST_${SID}.md"
```

## Stage 5 — Testing audit → TESTING_AUDIT  *(skip under --quick)*

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
PF="$ADIR/prompt-stage5.txt"
cat > "$PF" <<EOF
You are running STAGE 5 (Testing audit) of /v-self-audit.
Follow the "Stage 5 — Testing audit" section of $PROTO. You EXECUTE: test inventory + fidelity classification, coverage-gap map, a backtest (reconstruct documented past regressions, run the suite against the pre-fix state ON A TEMP COPY, measure proactive catch rate), and a mutation kill-rate (inject faults INTO TEMP COPIES, confirm a test goes red), plus the structural diagnosis.
MUTATION/BACKTEST ON TEMP COPIES ONLY — cp into a fresh mktemp -d, mutate there, run, then rm -rf. Never touch the live tree.
Emit the full TESTING_AUDIT as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" \
  --artifact "$ADIR/TESTING_AUDIT_${SID}.md" --mode capture
echo "stage5 rc=$? -> $ADIR/TESTING_AUDIT_${SID}.md"
```

## Stage 6 — Testing synthesis → TESTING_PLAN  *(skip under --quick)*

```bash
SID="${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}"; ADIR="$HOME/.claude/.v/self-audit/$SID"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
PF="$ADIR/prompt-stage6.txt"
cat > "$PF" <<EOF
You are running STAGE 6 (Testing synthesis) of /v-self-audit.
Input: $ADIR/TESTING_AUDIT_${SID}.md
Follow the "Stage 6 — Testing synthesis" section of $PROTO. Produce ONE self-validating testing plan: foundations (real e2e harness; real-session fixture corpus; mutation/fault-injection mechanism; orphan-harness killer meta-test) -> per-bug-class regression tests -> the mandatory pre-ship mutation gate + "what's-untested" critic. Definition of done = metric thresholds, not item count. Every item is mutation-proof-carrying and tiered (fast vs gated).
Emit the full TESTING_PLAN as your final message (capture mode — do NOT use Write).
EOF
bash "$HELPER" --agent v-orchestrator-auditor --prompt-file "$PF" \
  --artifact "$ADIR/TESTING_PLAN_${SID}.md" --mode capture
echo "stage6 rc=$? -> $ADIR/TESTING_PLAN_${SID}.md"
```
