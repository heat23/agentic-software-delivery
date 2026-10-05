---
name: v-self-audit
description: "Use when auditing the /v orchestrator ITSELF (not product code) for regressions, hidden bugs, test-suite gaps, or token/wall-clock cost; outputs a SHIP LIST."
argument-hint: "[--quick]"
allowed-tools: Read, Write, Bash, Glob, Grep, BashOutput
user-invocable: true
disable-model-invocation: true
context: fork
model: inherit  # inherit = run on the session/CLI model. Governs MANUAL /v-self-audit only; Skill-tool dispatch ignores it. Fan-out subprocesses are pinned separately at the dispatch site — via --model, or by the agent file's own frontmatter pin when dispatched with --agent (see v-core-model-routing.md).
---
<!-- skill: v-self-audit | version: 1.2.3 | last-updated: 2026-08-12 -->

# 2026 Canonical Contract

Tier: user-facing meta-audit of the `/v` orchestrator system. Read-only on the `/v` system; produces report/plan artifacts only — it does NOT implement fixes (those are handed to `/v`).

Follow `_v-core.md`.

`/v-self-audit` proactively hunts regressions, hidden bugs, test-suite blind spots, and cost waste in the **local `/v` system** (skills, hooks, agents, validators, tests under `~/.claude/`) so they're caught here instead of in a real production session. It runs 6 autonomous stages, each as an independent sub-agent dispatch, and stops at a **verified, LOW-risk SHIP LIST + a self-validating testing plan**.

```yaml
contract:
  tier: user-facing
  accepts: [no-arg (full /v target), --quick (stages 1-4 only, skip testing audit)]
  produces: [AUDIT_REPORT_${SID}.md, EFFICIENCY_REPORT_${SID}.md, ADVERSARIAL_REVIEW_${SID}.md, SHIP_LIST_${SID}.md, ship-pack-<MM-DD>/ (runnable /v pack tree under .v/self-audit/${SID}/ per v-runnable-pack-convention.md), TESTING_AUDIT_${SID}.md, TESTING_PLAN_${SID}.md, SELF_AUDIT_SUMMARY_${SID}.md]
  invokes: []
  invoked-by: [user]
  side-effects: report-only (artifacts under ~/.claude/.v/self-audit/${SID}/; zero tracked-source diff)
  estimated_tokens: 60k-200k
  estimated_duration: 15-45 min
```

The dispatched agents `v-orchestrator-auditor` and `codex-adversarial-reviewer` are sub-agents (not skills), so they are not listed in `invokes:`.

## Skill Boundaries

### Best fit
- Find correctness regressions, test-suite blind spots, and measured cost waste in the `/v` system before they ship.
- Produce a gate-safe, LOW-risk SHIP LIST plus a testing plan that proves it catches the next regression.

### Use instead
- `/v` — to implement the resulting SHIP LIST through the standard gauntlet.
- `/v-skill-reviewer` — for a single-skill instruction review.
- `/v-check`, `/v-bug-hunt` — for product/application code (not the `/v` machinery itself).

### Not for
- Editing skills/hooks/validators (read-only; route fixes to `/v`).
- Product/application code review.
- Implementing fixes or running the recommended changes.

## Artifacts (these names are the contract — emitted by the stages, read by the final report)

| Stage | Artifact |
|---|---|
| 1 Code audit | `AUDIT_REPORT_${SID}.md` |
| 2 Efficiency | `EFFICIENCY_REPORT_${SID}.md` |
| 3 Adversarial review | `ADVERSARIAL_REVIEW_${SID}.md` |
| 4 Synthesis | `SHIP_LIST_${SID}.md` + runnable pack tree `ship-pack-<MM-DD>/` (under `$ADIR`) |
| 5 Testing audit | `TESTING_AUDIT_${SID}.md` |
| 6 Testing synthesis | `TESTING_PLAN_${SID}.md` |
| final | `SELF_AUDIT_SUMMARY_${SID}.md` |

## Safety (NON-NEGOTIABLE)

- **Stop at plan.** This skill changes NO tracked source under `~/.claude/`. The session must leave **zero git diff**; it writes only artifacts under `~/.claude/.v/self-audit/${SID}/` (including the Stage-4 `ship-pack-<MM-DD>/` runnable tree, which lives inside that dir). Implementation is handed to `/v` / `run-v-packs`. Emitting a runnable pack is still "stop at plan" — the packs are not executed by this session.
- **Mutation + backtest run on TEMP COPIES only**, never the live tree; always clean up (the testing-audit stage injects faults — copy-to-temp is mandatory).
- **Low-risk-only recommendations by default.** The SHIP LIST + lever set recommend only LOW-risk, gate-safe, quality-neutral items; MEDIUM/HIGH go to a separate **Deferred / opt-in** section, never auto-recommended.
- **Fork dispatch discipline.** This skill runs `context: fork`, so it CANNOT use the `Agent` tool (silently fails). All sub-agent work goes through the Bash helper `v-dispatch-subagent.sh`. Dispatch each stage **blocking** (`run_in_background:false`); if a dispatch auto-backgrounds past the 600s Bash cap, poll via `BashOutput` — never go passive, never set `run_in_background:true` on a dispatch.
- **Degrade loud, never silent.** If codex is unavailable or a measurement tool is missing, mark the artifact degraded and use the documented fallback; never silently skip a stage or fabricate a number.
- **The summary IS the Stop-completion artifact.** This session dispatches subagents but changes no code, so the Stop hook recognizes it as report-only ONLY via `SELF_AUDIT_SUMMARY_${SID}.md` (its `# SELF_AUDIT_SUMMARY` heading + `Overall: PASS|FINDINGS|BLOCK` line). Always write it at `$ADIR/` before ending — a missing/malformed summary is indistinguishable from an abandoned `/v` session and the Stop hook will block. Do NOT hand-author PRE_FLIGHT_REPORT / AGENT_REVIEW / VERIFY_DONE to satisfy the gate (this skill runs no gauntlet — fabricating them is an anti-pattern). **Location invariant — run this skill with cwd at or under `~/.claude`.** Otherwise the summary lands where the Stop hook won't look → false completion block. Mechanism: the summary is written under `$HOME/.claude/.v/self-audit/$SID/`, but the Stop hook (`check-review-artifact.sh`) searches `$REPO_ROOT/.v/self-audit/$SID/` (and `$MAIN_ROOT/…`), which coincides with the write path only when this session's REPO_ROOT resolves to `~/.claude` — this skill's audit target. Run it from inside a product repo and the summary lands under `~/.claude` while the hook searches that product's tree.

## Workflow

Run the setup block, then execute stages 1→6 in order (**under `--quick`, run stages 1→4 only — setup, code audit, efficiency, adversarial, synthesis + pack assembly, final report — and skip stages 5–6**). The runnable dispatch bash for each stage lives in `references/v-self-audit-dispatch.md` — **read that file and run each stage's fenced block in sequence**; the detailed per-stage audit instructions the sub-agents follow live in `references/v-self-audit-protocol.md`.

**Setup** (one Bash call; establishes SID + artifact dir + helper path — persist to a file since bash state does not cross tool calls):

```bash
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SID" ] || { echo "v-self-audit: no session id"; exit 1; }
ADIR="$HOME/.claude/.v/self-audit/$SID"; mkdir -p "$ADIR"
HELPER="$HOME/.claude/skills/v/references/v-dispatch-subagent.sh"
PROTO="$HOME/.claude/skills/v-self-audit/references/v-self-audit-protocol.md"
printf 'SID=%s\nADIR=%s\nHELPER=%s\nPROTO=%s\n' "$SID" "$ADIR" "$HELPER" "$PROTO" > "$ADIR/env.sh"
echo "v-self-audit ready: $ADIR"
```

### Stage 1 — Code audit → `AUDIT_REPORT_${SID}.md`
Dispatch `v-orchestrator-auditor` (capture) to audit the `/v` system across the correctness dimensions (independence/provenance, concurrency/survival, contract drift, inline-vs-fork dispatch, failure-mode handling, dead/duplicate code). It composes with `v-skill-reviewer` for the skill-review dimension rather than duplicating it. Run the **Stage 1** block in `v-self-audit-dispatch.md` with **`timeout: 600000`**; if the Bash tool auto-backgrounds, call `BashOutput <task-id>` in a polling loop until `stage1 rc=` appears — never wait passively for a notification.

### Stage 2 — Efficiency evaluation (fact-based) → `EFFICIENCY_REPORT_${SID}.md`
Dispatch `v-orchestrator-auditor` (capture) to measure, from a corpus of real recent `/v` sessions, the actual token cost split into **cached (`cache_read`) vs non-cached (`cache_creation` + `output`)**, price-weighted, attributed per consumer/stage, plus **wall-clock per stage/gate** — then emit ranked cost drivers + LOW-risk candidate levers (BILL vs WALL-CLOCK separated) targeting **10–20%**. The measurement is self-validated (cross-check totals before trusting any lever). Run the **Stage 2** block with **`timeout: 600000`**; poll via `BashOutput <task-id>` if it auto-backgrounds.

### Stage 3 — Adversarial review → `ADVERSARIAL_REVIEW_${SID}.md`
Dispatch `codex-adversarial-reviewer` (capture — genuinely independent model + real provenance) over BOTH the correctness and efficiency findings: per-finding {Confirmed/Refuted/Overstated/Understated/Unverifiable} + per-fix/lever {Ship/Revise/Reject}, weighted to refute over-claimed lever sizes and to REJECT any fix that would weaken a gate. On non-zero exit (codex unavailable / empty), fall back to an independent `v-orchestrator-auditor` adversarial dispatch and mark `independence: degraded`. Run the **Stage 3** block with **`timeout: 600000`**; poll via `BashOutput <task-id>` if it auto-backgrounds.

### Stage 4 — Synthesis → `SHIP_LIST_${SID}.md` + runnable pack tree `ship-pack-<MM-DD>/`
Dispatch `v-orchestrator-auditor` (capture) to reconcile audit + efficiency + adversarial into one deduplicated, dependency-ordered SHIP LIST of gate-safe code fixes + a ranked efficiency-lever set (each tagged risk + measured-impact + bill/wall-clock). **By default only LOW-risk, gate-safe items are recommended**; MEDIUM/HIGH → a separate Deferred/opt-in section. Each code fix carries a regression-test spec. The SHIP_LIST also carries a paste-ready `/v ` **pack body + wave tag** per recommended LOW-risk item (capture-mode auditors have no Write tool, so they emit the raw material, not the tree). **After Stage 4 returns, the orchestrator (which holds Write) assembles those bodies into a RUNNABLE PACK TREE** at `$ADIR/ship-pack-<MM-DD>/` per `~/.claude/skills/references/v-runnable-pack-convention.md` (write-confined to `$ADIR` per the stop-at-plan safety rule — a documented deviation from the convention's project-root `.v-prompt-packs/` location) so the LOW-risk list is executable via `run-v-packs` or a paste into `/v`, not just prose — see **Assemble the runnable pack tree** below. Run the **Stage 4** block with **`timeout: 600000`**; poll via `BashOutput <task-id>` if it auto-backgrounds.

### Assemble the runnable pack tree (orchestrator-authored, after Stage 4)

Once `SHIP_LIST_${SID}.md` is written, the orchestrator builds `$ADIR/ship-pack-<MM-DD>/` from its recommended-item pack bodies, following `~/.claude/skills/references/v-runnable-pack-convention.md` (the single source of truth for wave prefixes, closing waves, and self-validate):

- Write each recommended item's pack body to `w<wave>-<slug>.txt` (wave 0 ⇒ no prefix). Verbatim from the SHIP_LIST — first line `/v …`, the mandatory `## Goal`/`## Context`/`## Files`/`## Changes`/`## Acceptance criteria`/`## Tests`/`## Constraints`/`## Dependencies` schema already in place per `v-self-audit-protocol.md` § Stage 4 (copy verbatim, do not reformat), ends "leave staged; do not commit".
- Write `00-README.md` master map (wave table + which SHIP_LIST item each pack implements + dependency order).
- Append the standard closing waves: `w<N>-pre-flight.txt` + `w<N>-review.txt` (parallel, READ-ONLY — omit the "leave staged" line), then `w<N+1>-hardening.txt` (sequential), then `99-verify.txt` (final gate-runner, last).
- **Self-validate** with the convention's § Self-validate the emitted tree block (structural check + wave-map↔file parity); if `run-v-packs` is on PATH, also `run-v-packs "$ADIR/ship-pack-<MM-DD>/" --dry-run`.
- If the SHIP_LIST recommends zero LOW-risk code fixes, write only `00-README.md` stating "no runnable fixes — see SHIP_LIST Deferred section" (no empty packs). Writing this tree is the ONLY additional write; it stays inside `$ADIR`, so the zero-tracked-diff invariant holds.

### Stage 5 — Testing audit → `TESTING_AUDIT_${SID}.md`  *(skipped under `--quick`)*
Dispatch `v-orchestrator-auditor` (capture) to actually EXECUTE: test inventory + fidelity classification, coverage-gap map, a **backtest** (reconstruct documented past regressions, run the suite against the pre-fix state on a temp copy, measure proactive catch rate), and a **mutation kill-rate** (inject faults into temp copies, confirm a test goes red), plus the structural diagnosis. Run the **Stage 5** block with **`timeout: 600000`**; poll via `BashOutput <task-id>` if it auto-backgrounds.

### Stage 6 — Testing synthesis → `TESTING_PLAN_${SID}.md`  *(skipped under `--quick`)*
Dispatch `v-orchestrator-auditor` (capture) to produce one self-validating testing plan: foundations (real e2e harness; real-session fixture corpus; mutation/fault-injection mechanism; orphan-harness killer meta-test) → per-bug-class regression tests → the **mandatory pre-ship mutation gate** + "what's-untested" critic. Definition of done is metric thresholds, not item count. Run the **Stage 6** block with **`timeout: 600000`**; poll via `BashOutput <task-id>` if it auto-backgrounds.

## Final report → `SELF_AUDIT_SUMMARY_${SID}.md`

After all stages, write the consolidated summary yourself (this is the one artifact the orchestrator authors). Use exactly this structure:

```markdown
# SELF_AUDIT_SUMMARY

Target: /v orchestrator system (~/.claude)
Stages run: <1-6 or 1-4 (--quick)>

## Artifacts
- AUDIT_REPORT: <path> (<N findings>)
- EFFICIENCY_REPORT: <path>
- ADVERSARIAL_REVIEW: <path> (independence: real|degraded)
- SHIP_LIST: <path> (<N low-risk recommended>, <N deferred>)
- Runnable pack: <ship-pack-<MM-DD>/ path> (<N packs>, self-validate: PASS|ISSUES) — run with `run-v-packs <path>`
- TESTING_AUDIT: <path or skipped>
- TESTING_PLAN: <path or skipped>

## North-star metrics
- proactive backtest catch rate: <x/y or n/a>
- mutation kill-rate: <x/y or n/a>
- orphan-harness count: <N or n/a>
- token cost split (cached / non-cached / output): <% / % / %>
- per-stage wall-clock: <top consumers>
- projected cost reduction from recommended levers: <%>

## Recommended now (LOW-risk only)
<bullet list of SHIP_LIST low-risk items + levers, each with measured/expected impact>

## Deferred (MEDIUM/HIGH — opt-in)
<bullet list>

Overall: <PASS | FINDINGS | BLOCK>
```

Then STOP. Do not implement anything.

## Self-check (before declaring done)

```bash
. "$HOME/.claude/.v/self-audit/${CLAUDE_SESSION_ID:-$CLAUDE_CODE_SESSION_ID}/env.sh" 2>/dev/null
MISS=0
for a in AUDIT_REPORT EFFICIENCY_REPORT ADVERSARIAL_REVIEW SHIP_LIST SELF_AUDIT_SUMMARY; do
  [ -s "$ADIR/${a}_${SID}.md" ] || { echo "MISSING: $a"; MISS=1; }
done
# SELF_AUDIT_SUMMARY is this skill's Stop-hook completion artifact (report-only escape). It MUST carry
# the '# SELF_AUDIT_SUMMARY' heading AND an 'Overall: PASS|FINDINGS|BLOCK' line — the Stop hook gates on
# exactly these two signals, so validate them here (producer≡validator parity; drift = a false block).
SUMM="$ADIR/SELF_AUDIT_SUMMARY_${SID}.md"
if [ -s "$SUMM" ]; then
  grep -qE '^#+[[:space:]]*SELF_AUDIT_SUMMARY' "$SUMM" || { echo "SUMMARY: missing '# SELF_AUDIT_SUMMARY' heading"; MISS=1; }
  grep -qiE '^[[:space:]]*Overall:[[:space:]]*(PASS|FINDINGS|BLOCK)' "$SUMM" || { echo "SUMMARY: missing 'Overall: PASS|FINDINGS|BLOCK' verdict line"; MISS=1; }
fi
# Runnable pack tree (Stage 4): its 00-README.md must exist whenever the SHIP_LIST recommends any LOW-risk fix.
# Soft check — a genuinely all-deferred SHIP_LIST legitimately ships a README-only tree (or none).
if ls -d "$ADIR"/ship-pack-* >/dev/null 2>&1; then
  for pd in "$ADIR"/ship-pack-*; do
    [ -f "$pd/00-README.md" ] || echo "WARN: $pd has no 00-README.md master map"
  done
elif grep -qiE '^###?[[:space:]]|^-[[:space:]]' "$ADIR/SHIP_LIST_${SID}.md" 2>/dev/null && grep -qi 'recommended now' "$ADIR/SHIP_LIST_${SID}.md" 2>/dev/null; then
  echo "WARN: SHIP_LIST recommends fixes but no ship-pack-<MM-DD>/ runnable tree was emitted (Stage 4 contract)"
fi
# zero tracked-source diff is mandatory (stop-at-plan)
DIRTY=$(cd "$HOME/.claude" && git status --porcelain -- skills hooks agents 2>/dev/null | grep -v '\.v/' | head -1)
[ -z "$DIRTY" ] || echo "WARN: unexpected tracked-source change — investigate: $DIRTY"
[ "$MISS" -eq 0 ] && echo "v-self-audit: all required artifacts present"
```

## Gotchas

| # | Symptom | Rule |
|---|---|---|
| 1 | `Agent` tool dispatch silently no-ops | This skill is a fork → dispatch only via `v-dispatch-subagent.sh` |
| 2 | A fault-injection step touches the live tree | Mutate TEMP COPIES only; clean up |
| 3 | codex reports EMPTY DIFF / unavailable | Fall back to independent auditor adversarial dispatch; mark `independence: degraded` (never silent) |
| 4 | A risky lever lands in the recommended list | Default is LOW-risk only; gate-touching / model-tier / correctness items → Deferred |
| 5 | Session leaves a tracked diff | Stop-at-plan — only `.v/self-audit/` artifacts may change |
| 6 | Stop hook blocks demanding PRE_FLIGHT/AGENT_REVIEW/VERIFY | You skipped the summary. Write `SELF_AUDIT_SUMMARY_${SID}.md` (`# SELF_AUDIT_SUMMARY` heading + `Overall: PASS\|FINDINGS\|BLOCK`) — it is the report-only completion artifact. NEVER fabricate gauntlet reports to escape |

## Idempotency

Read-only on the `/v` system except its own artifacts under `.v/self-audit/${SID}/`. Re-running produces the same findings unless the `/v` system or session corpus changed.
