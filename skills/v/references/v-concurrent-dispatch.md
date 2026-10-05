# Concurrent Dispatch Decision — Step 3.4 (extracted from /v SKILL.md — W55-F1)

> **Loaded by:** /v Step 3.4, after implementation completes (Step 3 done) and BEFORE Step 3.5/Step 4 dispatch. Inline /v SKILL.md should have only a one-line stub naming this reference. Decides whether to parallelize Step 3.5 (UX critique) and Step 4 (pre-flight).

## Decision rule

After implementation completes (Step 3 done), decide whether to dispatch Step 3.5 (UX critique), Step 4 (pre-flight), and the Step 5 review set concurrently or sequentially.

**Non-hostile optimistic concurrency (Lever A — the primary win for most sessions):** when the diff is stable (Step 3 done) **and `HOSTILE_REVIEW_REQUIRED=0`** (no auth/payment/data-deletion paths — computed once via the regex in `v-agent-review.md`), launch ONE `references/v-supervise-children.sh` call hosting the pre-flight runner **and** the full review set (`codex` + `logic` + `fit`, plus `framework` when its trigger fires, plus `UX-critique` on a UI session) as sibling children. The supervisor already hosts N independent `claude -p`/`codex` children in one blocking foreground Bash call, so this is a merge of the existing pre-flight and reviewer dispatches, not a new mechanism. On the common pre-flight-passes path this saves `min(pre-flight, review)` wall-clock. This is the **non-hostile** path; a hostile diff stays sequential (below).

**Freshness is MECHANICAL, not remembered (closes SREV-005 — the gap Lever A would otherwise introduce).** In the old sequential path, "the review saw the post-fix code" was guaranteed by *ordering* (Step 5 ran after the Step 4 fix), for free. The concurrent path must not downgrade that to "remember to re-review," because model-instruction-only defenses don't hold here. So validity falls out of a **staging → promotion** gate, built on this invariant: the diff is FROZEN from Step-3.4 dispatch until the supervisor returns (no edits permitted), therefore **a pre-flight PASS proves no fix happened → the staged review is provably fresh; only a pre-flight FAIL can create staleness.**
- The concurrent reviewers write to a **staging** artifact `AGENT_REVIEW_STAGED_${SESSION_ID}.md`, NOT the canonical `AGENT_REVIEW_${SESSION_ID}.md` the gauntlet checks.
- **If pre-flight PASSED:** promote staging → canonical (`mv`); the staged review is fresh by the invariant above. Proceed to Step 5 "read artifacts + wrap".
- **If pre-flight FAILED:** **DISCARD** the staged review (`rm` it — it reviewed the pre-fix diff), apply the fix, then fall through to the NORMAL Step 5, which **re-dispatches** the **review** set against the post-fix **pre-flight** diff and writes the canonical `AGENT_REVIEW` **fresh** (the QA-loop already mandates refreshing AGENT_REVIEW after a FAIL fix). Because the gauntlet/attest only ever reads the canonical artifact, a stale staged review can never satisfy completion — the enforcement is structural, not a remembered step. Consistent with the `v-dependency-recover.sh` precedent (re-verify once after a fix).

**Concurrent dispatch (cosmetic UI — UX-critique ∥ pre-flight):** when this session has UI files in the writes-log, Step 3.5 will fire, AND the UI change classifier resolved `COSMETIC` (no full workflow-verification remediation can precede pre-flight), launch BOTH the UX-critique and pre-flight subprocesses through the blocking supervisor (`references/v-supervise-children.sh`). The supervisor backgrounds each independent `claude -p` process inside one foreground Bash invocation, waits for every child, retries transient failures once, and writes loud fallback artifacts for failed gates. Because each child is independent (W-fork-fix — see § FORK CONSTRAINT), wallclock = max(UX-critique, pre-flight) instead of sum. Saves ~30s on cosmetic UI-touching sessions while avoiding the batch-cancellation/no-artifact failure mode.

**Sequential fallback:** use sequential dispatch when:
- Step 3.5 is skipped entirely (no UI files changed) — there's no parallelism to extract; just run Step 4.
- Step 3.5 classified the UI change as `BEHAVIORAL` or otherwise requires browser workflow verification — workflow-verification failures must be remediated before pre-flight, so pre-flight cannot overlap that phase.
- Diff includes auth/payment/data-deletion paths (HOSTILE_REVIEW_REQUIRED=1) — preserve the deliberate sequential-gating semantics; agent review at Step 5 may need to gate before pre-flight.
- Running two heavy subprocesses concurrently would exceed the runner's resource budget — when in doubt, sequential is always correct (only the 30s optimization is lost).

## Concurrent dispatch protocol

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
SUPERVISOR="${CLAUDE_SKILL_DIR}/references/v-supervise-children.sh"
# 1. Build the UX-critique dispatch file (per Step 3.5 protocol — perl substitution).
DISPATCH_UX="$V_TMP_DIR/dispatch-${SESSION_ID}-ux-critique.txt"
SID="$SESSION_ID" PROJ="$PROJECT_ROOT" UIF="$UI_FILES" perl -0pe \
  's/\{\{SESSION_ID\}\}/$ENV{SID}/g; s/\{\{PROJECT_ROOT\}\}/$ENV{PROJ}/g; s/\{\{UI_FILES\}\}/$ENV{UIF}/g;' \
  "${CLAUDE_SKILL_DIR}/references/dispatch-ux-critique.md" > "$DISPATCH_UX"
# 2. Build the pre-flight dispatch file (same helper as the sequential path).
DISPATCH_PF="$V_TMP_DIR/dispatch-${SESSION_ID}-v-pre-flight.txt"
bash "${CLAUDE_SKILL_DIR}/references/v-emit-prompt.sh" v-pre-flight > "$DISPATCH_PF"
# 3. Write child command files. The supervisor runs them concurrently in one
#    foreground Bash call, captures per-child logs, retries transient failures,
#    and writes fallback artifacts when a child cannot produce its report.
UX_CMD="$V_TMP_DIR/child-${SESSION_ID}-ux-critique.sh"
PF_CMD="$V_TMP_DIR/child-${SESSION_ID}-v-pre-flight.sh"
cat > "$UX_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent v-ux-critique-reviewer --prompt-file "$DISPATCH_UX" \
  --artifact "$PROJECT_ROOT/.v/artifacts/UX_CRITIQUE_${SESSION_ID}.md" --mode self-write
EOF
cat > "$PF_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent v-pre-flight-runner --prompt-file "$DISPATCH_PF" \
  --artifact "$PROJECT_ROOT/.v/artifacts/PRE_FLIGHT_REPORT_${SESSION_ID}.md" --mode capture
EOF

# 4. Launch BOTH through the supervisor and block until every child completes.
bash "$SUPERVISOR" \
  --summary "$V_TMP_DIR/supervisor-${SESSION_ID}-ux-preflight.summary" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "ux::900::$PROJECT_ROOT/.v/artifacts/UX_CRITIQUE_${SESSION_ID}.md::$UX_CMD" \
  --child "preflight::900::$PROJECT_ROOT/.v/artifacts/PRE_FLIGHT_REPORT_${SESSION_ID}.md::$PF_CMD"
SUPERVISOR_RC=$?
echo "[W55-F1] concurrent subprocess dispatch complete: supervisor_rc=$SUPERVISOR_RC summary=$V_TMP_DIR/supervisor-${SESSION_ID}-ux-preflight.summary"
```

5. Read the supervisor summary/logs + both artifacts. If `SUPERVISOR_RC` is non-zero, do not discard successful sibling output. The supervisor has already retried transient failures once and written loud fallback artifacts for failed children. Continue to Step 5 using the artifacts as input; failed fallback artifacts remain blocking/visible to the normal gate logic.

## Why this is safe

- UX-critique reads the diff. Pre-flight reads the diff. Neither reads the other's output.
- Both runners write to SID-suffixed artifacts (`UX_CRITIQUE_<sid>.md`, `PRE_FLIGHT_REPORT_<sid>.md`) — no path collision.
- Both append to the same writes-log via the PreToolUse hook at `~/.claude/hooks/track-session-writes.sh:141-150` (the WRITER), which guarantees parallel-safe appends via O_APPEND atomicity for paths ≤PIPE_BUF (4096 bytes). Reader (`lib/session-writes.sh`) returns deduped results.
- W47-A made this contention model production-safe.

## Failure isolation

If one subprocess errors and the other succeeds, the orchestrator processes whichever succeeded. The W49-F1 enforcement (Stop hook blocks completion if UI files changed but `UX_CRITIQUE_<sid>.md` is missing) STILL applies, but the supervisor should prevent a missing-artifact race by writing a degraded/failing fallback artifact for the failed child. Backgrounded subprocesses are fully isolated inside the supervisor: one child crashing does not cancel sibling artifacts.

## Verification

Backgrounded `claude -p` subprocesses are independent OS processes, so true parallelism does not depend on any Agent-tool multi-call contract. The `[W55-F1] concurrent subprocess dispatch complete: supervisor_rc=…` line plus the supervisor summary confirms every child reached a terminal state. If running two heavy subprocesses concurrently is undesirable in a constrained runner, fall back to sequential — no behavioral regression (only the ~30s optimization is lost).

## Anti-patterns

- Step 5's reviewers ARE parallelized AMONG THEMSELVES (W-perf2 — the supervised concurrent Bash helper; see `v-agent-review.md` § Concurrent reviewer dispatch — this is the single largest wall-clock lever in `/v`). **Lever A** additionally overlaps the review set with Step 4 pre-flight **on the non-hostile path** (`HOSTILE_REVIEW_REQUIRED=0`): both only READ the frozen diff and write SID-disjoint artifacts, so they are safe to run as siblings in one supervisor call. (The old blanket "never overlap the agent-review phase with Step 4" anti-pattern is RETIRED for the non-hostile case.)
- **Hostile diff stays sequential:** when `HOSTILE_REVIEW_REQUIRED=1` (auth/payment/data-deletion paths), keep strict Step 4 → Step 5 **sequential** gating — preserve the deliberate review-gates-before-merge semantics; do NOT overlap pre-flight with the review set. Step 6 (verify-done) always stays sequential — it depends on the pre-flight + agent-review artifacts.
- Do NOT parallelize Step 6.1 (completion-verification pre-flight re-dispatch) — Step 3.5 has already run by Step 6, no overlap available.
- Do NOT parallelize Step 6.2 (verify-done) — depends on pre-flight + agent-review artifacts.
