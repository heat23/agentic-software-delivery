# QA Acceptance & Autonomous Remediation Loop (Step 6.4.9) — extracted from /v SKILL.md

> **Loaded by:** /v Step 6.4.9, the final sub-step of Step 6 Completion Verification — after pre-flight (6.1), verify-done (6.2), workflow-verification (6.2.5), impact-map closure (6.2.6), drift (6.3), and zero-skills (6.4), and BEFORE Step 6.5 merge-back. Runs for every code-changing Feature/Bug-Fix/Refactor session.
>
> **Why this exists:** every other gate verifies against the AI's *own* derived criteria (success criteria, plan, impact map) or looks for *code* bugs in the diff. None asks, as an independent QA function would: *did we build the right thing, completely, would the user accept it, and what breaks when I try to break it?* And critically — the orchestrator must run **autonomously end-to-end**: a QA finding can't just be flagged for a human. It must be **analyzed by the right domain SME, fixed correctly, and re-tested — all without operator action.** This step is that closed loop.
>
> **Outputs:** `QA_REPORT_<sid>.md` (independent QA verdict, owned by the `v-qa-reviewer` agent) and `QA_REMEDIATION_<sid>.md` (the SME analysis + fix + re-test trail, owned by the orchestrator).

## Step 0 — LIGHT-TIER check (skip the QA loop entirely for tiny gated guard diffs)

Before dispatching v-qa-reviewer, run ONE command:

```bash
bash ~/.claude/skills/v/references/v-classify-light-tier.sh
```

If it prints `LIGHT=1`, **skip this entire step** (do NOT dispatch v-qa-reviewer, write no QA_REPORT) and proceed to Step 6.5 — the Stop hook re-derives the same diff shape itself (P1B-LIGHT-TIER) and waives the QA gate; it never trusts your claim, so do not write a QA_REPORT "just in case" and never assert LIGHT status in prose. `LIGHT=1` requires ALL of: ≤10 changed non-test lines, only config/routes/app-Console path classes, a REAL accompanying test, and zero security-bearing paths/content (signing/HMAC/webhook/credential/host-construction/auth/payment are HARD-excluded — those always take the full QA loop regardless of size). If it prints `LIGHT=0`, run the loop below exactly as written.

## The loop (operator does nothing)

```
        ┌──────────────────────────────────────────────────────────┐
        │  (A) ASSESS   v-qa-reviewer → QA_REPORT (findings+verdict) │
        └──────────────────────────────────────────────────────────┘
                 │ verdict: pass / no critical|high
                 ▼  ───────────────────────────────► EXIT (record residual risk) → Step 6.5
                 │ verdict: fail (critical|high findings)
                 ▼
        (B) TRIAGE      keep critical|high; medium|low → residual risk (logged, not looped)
                 ▼
        (C) SME ANALYZE per finding → route to domain SME → remediation directive
                 ▼       (root cause + domain-correct fix + the re-test that proves it)
        (D) IMPLEMENT   apply directives (TDD the fix for backend logic); stay in scope
                 ▼
        (E) RE-VERIFY   per-iteration: TARGETED tests only (NOT full pre-flight),
                 │       verifier if UI, impact-closure if consumers; re-dispatch v-qa-reviewer.
                 │       Full /v-pre-flight runs ONCE on convergence (attest exit-8 enforces it).
                 └──────────────────► back to (A).  Cap: 3 iterations.
                          on cap → ESCALATE: BLOCKED_<sid>.md + verdict: escalated → stop
```

The operator is pulled in at exactly ONE point — escalation after 3 autonomous iterations fail to converge — which matches the existing "3 failed fix attempts → revert/ask" contract (global CLAUDE.md) and the v-agent-review § Cycle Cap. Everything else is orchestrator-driven.

## (A) Assessment — what `v-qa-reviewer` does

Dispatched as an INDEPENDENT `claude -p --agent v-qa-reviewer` subprocess (W-fork-fix — `Agent(subagent_type:…)` fails from /v's `context: fork` and silently drops to inline self-grading, which defeats independent QA). A Bash-spawned subprocess is a separate process with its own context + model, so independence is restored. Dispatch via the helper:

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
SRC="${CLAUDE_SKILL_DIR}/references/dispatch-v-qa-reviewer.md"
DISPATCH_FILE="$V_TMP_DIR/dispatch-${SESSION_ID}-qa-reviewer.txt"
# ORIGINAL_TASK + CHANGED_FILES are multiline → perl -0pe (slurp) substitutes cleanly.
SID="$SESSION_ID" PROJ="$PROJECT_ROOT" ITER="$QA_ITERATION" \
  OTASK="$ORIGINAL_TASK" CFILES="$CHANGED_FILES" perl -0pe \
  's/\{\{SESSION_ID\}\}/$ENV{SID}/g; s/\{\{PROJECT_ROOT\}\}/$ENV{PROJ}/g; s/\{\{ITERATION\}\}/$ENV{ITER}/g; s/\{\{ORIGINAL_TASK\}\}/$ENV{OTASK}/g; s/\{\{CHANGED_FILES\}\}/$ENV{CFILES}/g;' \
  "$SRC" > "$DISPATCH_FILE"
# QA gets the FULL 900s child ceiling (NOT the ≤540 "below-the-tool-timeout" reduction the other gates
# use): exploratory + adversarial QA legitimately runs long, and one production session had v-qa-reviewer
# KILLED at 600s TWICE → escalated with no QA_REPORT. 900s exceeds the 600s foreground Bash-tool cap, so
# this dispatch WILL auto-background — issue it as a blocking Bash call (run_in_background:false) and
# POLL via BashOutput until it returns; NEVER go passive (that strands the gauntlet, observed in production). The
# helper's V_DISPATCH_TIMEOUT_SEC ceiling still bounds a genuinely-hung child (self-terminates → rc124 →
# escalate), so the longer budget never becomes an unbounded wait.
V_DISPATCH_TIMEOUT_SEC=900 bash "$HELPER" --agent v-qa-reviewer --prompt-file "$DISPATCH_FILE" \
  --artifact "$PROJECT_ROOT/.v/artifacts/QA_REPORT_${SESSION_ID}.md" --mode self-write
```

**Contention fallback (P1-D — replaces inline self-grading, which is FORBIDDEN):** if the foreground dispatch is killed by the tool/runtime (rc 124, or the Bash call itself dies under fleet load) — do NOT retry foreground (double-billing) and do NOT degrade to an inline verdict. Re-issue the SAME helper command ONCE with `--detach` appended: it returns immediately, runs the identical dispatch as a disowned child bounded by the same V_DISPATCH_TIMEOUT_SEC ceiling, and maintains `QA_REPORT_<sid>.md.dispatch-status` (`RUNNING …` → appended `DONE rc=…`). Then CONTINUE the remaining gauntlet steps (session-log, drift checks, artifact consolidation) and re-read the status file ONCE between steps — a single `cat`, never a sleep/poll loop (W41). If `DONE rc=0`, proceed with the QA verdict as normal; if `DONE` with non-zero rc or still `RUNNING` when nothing else remains, escalate per `dispatch-v-qa-reviewer.md` (`verdict: escalated` + `BLOCKED_<sid>.md`). The Stop artifact gate blocks completion until QA_REPORT lands, so the detached path cannot silently strand.

The helper loads the agent frontmatter (`model: sonnet`; `tools:` = `Bash, Read, Grep, Glob, BashOutput, Write` — no live browser MCP; UI checks are HTTP/code-level + the committed e2e spec). `--mode self-write`: the QA agent writes `QA_REPORT_${SESSION_ID}.md` itself; the helper verifies it landed. **NO restart needed** for a newly-added agent. If the helper exits non-zero (`DISPATCH_STATUS=error`, e.g. agent file missing), escalate per `dispatch-v-qa-reviewer.md` (write `verdict: escalated` + `BLOCKED_<sid>.md`) — do NOT rubber-stamp your own `verdict: pass` (that isn't independent QA), and do NOT replace the helper with an in-context `Agent` dispatch (fails from the fork).

It is **independent** (separate process + model, read-only on source — it cannot fix, so it cannot rationalize its own work) and judges the *product*, not the code:

1. **Acceptance vs. ORIGINAL intent** — re-reads the user's original request (passed verbatim, NOT the AI's derived success criteria) and rules `accept | partial | reject`: did we build the right thing, completely? This catches "all gates green, wrong/partial feature."
2. **Exploratory / adversarial** — beyond the scripted success-criteria/impact scenarios, tries to break it: unexpected inputs, odd sequences, abuse, boundaries. Probes at the backend/HTTP/code level (artisan/tinker/HTTP + the committed e2e spec results); browser-level UX is `v-workflow-verifier`'s committed spec.
3. **Cross-feature regression** — names adjacent features sharing infra/state (not just direct consumers) and confirms they still work.
4. **Test-quality** — are the new tests meaningful or green-but-hollow (tautological, over-mocked, asserting the mock)? Reuse the v-tdd anti-pattern catalog as the lens.

It writes `QA_REPORT_<sid>.md`: each finding tagged with **domain** + **severity**, plus the acceptance verdict and overall `verdict: pass|fail`.

## (B) Triage — severity discipline (cost control)

Only **critical** and **high** findings drive the autonomous remediation loop. **Medium/low** are recorded in `QA_REPORT` under Residual Risk (knowingly accepted; not looped) — otherwise QA never converges on nitpicks. This mirrors the agent-review "fix CRITICAL/HIGH, log the rest" convention. (QA severity vocabulary maps 1:1 to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md`: critical=P0, high=P1, medium=P2, low=P3 — the loop gate is the P0/P1 must-fix rule.)

## (C) SME analysis — domain expert prescribes the fix BEFORE implementation

**A QA finding is never blindly patched.** Each critical/high finding is routed by `domain` to the matching SME, who diagnoses root cause and prescribes the *domain-correct* fix + the re-test. For **security** and **data** domains the SME analysis MUST be a dispatched specialist agent (independent second opinion where it matters most); for the rest, the orchestrator adopts the named SME persona (the v-tdd persona model), and MAY dispatch the agent for extra rigor.

| Finding domain | SME persona | Dispatched agent |
|---|---|---|
| acceptance / scope / completeness | **Product Manager** — re-derive what the user actually needs; is the delivery complete & correct, or mis-scoped? | orchestrator persona (holds original-intent context) |
| ux / interaction / visual / a11y / flow | **UX Designer** | `v-ux-critique-reviewer` (analysis mode) — optional |
| architecture / coupling / abstraction / API design | **Software Architect** | `codebase-fit-reviewer` + `logic-reviewer` — optional |
| data / integrity / migration / query correctness / backfill | **DBA / Data Engineer** | **MANDATORY** independent dispatch: `migration-safety-reviewer` if the project scaffolded it, else `logic-reviewer` (always global) |
| security / authz / exposure / input validation | **Security Engineer** | `security-reviewer` — **MANDATORY** |
| reliability / async / idempotency / race / retry | **Reliability Engineer** | `framework-pitfall-reviewer` — optional |
| performance / N+1 / payload / cache | **Performance Engineer** | `logic-reviewer` (perf lens) — optional |

**Dispatching a specialist SME agent (W-fork-fix):** `Agent(subagent_type:…)` fails from /v's `context: fork`, so dispatch these read-only analysis agents (`security-reviewer`, `logic-reviewer`, `migration-safety-reviewer`, `codebase-fit-reviewer`, `framework-pitfall-reviewer`) as INDEPENDENT subprocesses via the helper in **capture mode** — they return their analysis as text, which the orchestrator folds into the remediation directive:

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
# Write the SME analysis prompt (the finding + diff context + "diagnose root cause,
# prescribe the domain-correct fix + re-test") to $DISPATCH_FILE, then:
bash "$HELPER" --agent security-reviewer --prompt-file "$DISPATCH_FILE" \
  --artifact "$V_TMP_DIR/sme-security-${SESSION_ID}.md" --mode capture
# Read the captured analysis (the helper's --artifact) and fold it into the directive.
```

These agents declare `tools: Read, Glob, Grep, Bash` (no Write) — capture mode is the natural fit; the helper writes their returned analysis to the scratch `--artifact`. Each SME produces a **remediation directive** (append to `.v/artifacts/QA_REMEDIATION_<sid>.md`):

```yaml
- finding_id: QA-001
  domain: data
  sme: "DBA / Data Engineer"
  agent_dispatched: "migration-safety-reviewer"   # or "persona-only"
  root_cause: "<why it happens — not the symptom>"
  fix_directive: "<the domain-correct change — e.g. 'nullable column + backfill job + unique index', NOT just 'add column'>"
  scope_check: "<within session scope? if the fix would balloon the diff >2x or needs a product decision the orchestrator can't make → ESCALATE instead of guessing>"
  retest: "<the exact check that proves it — test name / browser flow / gate>"
```

**Domain-correctness is the point.** A DBA doesn't "just add a column" — they consider nullability, backfill, indexes, FK cascade, two-phase deploy. A PM doesn't "just make the error go away" — they confirm it's the right behavior for the user. The directive must reflect that expertise.

## (D) Implement

Apply the directives. For backend logic, **write the failing test first** (invoke `/v-tdd` with the `retest` as scope) then fix — the re-test becomes a permanent regression guard. Stay within session scope; if a directive's `scope_check` says it balloons the diff or needs a product decision → do NOT guess, ESCALATE (write BLOCKED with the directive and stop).

## (E) Re-verify — targeted per iteration, full suite ONCE on convergence

**During each iteration, re-run ONLY the targeted tests the fix touched — NOT the full pre-flight suite.** The full cross-cutting suite runs exactly once, after the loop converges (see below). Re-running `/v-pre-flight` after every iteration is the redundant-full-suite waste Lever E removes (one observed session: 12 avoidable full-suite runs), and matches the global CLAUDE.md rule: *targeted tests during red-green, full suite once at the end.*

Per-iteration, re-run the minimal relevant verification:
- backend/logic fix → the **targeted** tests proving the fix (`--filter` / the single changed test file), NOT `/v-pre-flight`
- UI fix → `v-workflow-verifier` on the changed workflow (targeted), NOT a full `/v-polish` sweep
- consumer/data fix → the specific impact-closure / migration check for the touched consumer

Then **re-dispatch `v-qa-reviewer`** on the previously-failing findings (it reads the existing gate-summary and does its own targeted spot-checks; per `dispatch-v-qa-reviewer.md` it does NOT re-run the full suite either). It re-assesses and rewrites `QA_REPORT` with the new verdict. Loop to (A).

**On convergence (loop exits `verdict: pass`), run the full gauntlet ONCE over the final tree — this is YOUR unconditional responsibility whenever the loop touched code:**
- `/v-pre-flight` over the whole suite, then refresh markers (`v-preflight-mark.sh`).
- **A QA fix is new code.** If any iteration changed code (trivial or not), also **refresh `AGENT_REVIEW` (Step 5 adversarial review) and `VERIFY_DONE` (Step 6.2 conventions)** — those artifacts were produced before the QA fixes and no longer cover them; the Stop hook checks they exist + are valid but not that they're fresh against the latest diff, so QA fixes would otherwise ship unreviewed. Refresh **all three** artifacts (attest Item 19 compares all three against any source write), not just pre-flight.

**Run the final full pre-flight yourself — do NOT rely on the gate to force it.** `v-gauntlet-attest.sh` exit 8 (Item 19, stale-vs-last-source-write) is a backstop, but it **fails open** when this session's writes-ledger is empty/incomplete (a documented race — one production session logged 13 edits with a 0-byte ledger — and it never records Bash-applied `sed`/`perl` edits); no other gate catches a `PRE_FLIGHT_REPORT` that graded a pre-QA-fix tree. So a skipped convergence run can slip through. Running it unconditionally on convergence is what guarantees cross-cutting coverage; exit 8 only catches the ledger-present forget case. A targeted-test substitute for that final run is the forbidden rationalization (c) in SKILL.md Step 4.

## Measurement validity (a threshold finding needs a representative measurement)

**Before returning `fail` on any QUANTITATIVE threshold** — word counts, response times, row counts, bundle size, coverage %, query counts — state the measurement basis and confirm it is representative of PRODUCTION scale.

If the environment cannot produce a representative measurement (default dev seed, empty fixture, local-only data, a stub), you **MUST NOT return `fail`** on that finding. Record it under `## Scale-unverified findings` with the observed value, the basis you had, and what scale would settle it. That bucket is a non-blocking caveat — it is explicitly NOT a critical/high finding and does not gate `verdict: pass`.

A blocking `fail` on a threshold finding requires one of:
- **(a)** data at production scale (seed it, or restore a representative snapshot), or
- **(b)** a direct call of the unit under test with production-shaped inputs (e.g. invoking the builder/service with a realistic argument set rather than driving it through an under-seeded HTTP route).

**Forensic (2026-08-03).** QA measured 4 server-rendered pages against a word-count threshold using the project's default **minimal local seed** (a couple of rows), returned a blocking `fail`, and burned a full extra iteration — **~18 min** — whose only product was *retracting* that verdict once it finally measured at real scale (a production-sized dataset). The fix was already correct at iteration 2; the fixture was not. Note the loop cap below is NOT the remedy for this: capping lower would have converted a *real* iteration-1 finding into a hard `BLOCKED` stop. Preventing the false `fail` is what saves the turn.

**This rule constrains the QA agent's verdict, not its curiosity.** Report the observation either way — the rule only governs whether it is allowed to *block*.

## Loop cap + escalation (the only operator touchpoint)

Cap at **3 iterations** of (A→E). If the 3rd re-assessment still has unresolved critical/high findings, or any directive hit an ESCALATE `scope_check`:
1. Write `BLOCKED_<sid>.md` — the unresolved findings, their SME analyses, what was tried each iteration, and the specific decision/scope the operator must resolve.
2. Set `QA_REPORT` `verdict: escalated`.
3. Stop. Do NOT merge-back. This is consistent with the global "3 attempts → revert to last good state, ask" rule — the operator is engaged only after autonomous remediation is genuinely exhausted.

## QA_REPORT artifact (`QA_REPORT_<sid>.md` — agent-owned, Stop-hook enforced)

First line MUST be `Model: sonnet`; then a blank line; then the H2; then a `verdict:` line — the Stop hook validates this shape and the verdict.

**Deterministic seed (avoids the format bounce):** `bash "${CLAUDE_SKILL_DIR}/references/v-artifact-skeleton.sh" --type qa_report --sid "$CLAUDE_SESSION_ID" > "QA_REPORT_${CLAUDE_SESSION_ID}.md"` emits the `Model:` header, the `## QA Acceptance` heading, and a **fail-closed** col-0 `verdict: fail` exactly as `validate_qa_report_structure` requires. Fill the substance, then set `verdict:` to your honest assessment (the bare col-0 token — never `**verdict: pass**`). Round-tripped against the real validator by `references/v-artifact-skeleton-test.sh`.

```
Model: sonnet

## QA Acceptance — <sid>

verdict: <pass | fail | escalated>
iteration: <n>/3
original_request: "<the user's task, quoted>"
acceptance: "<accept | partial | reject> — <one line: does the delivery satisfy the actual intent?>"
measurement_basis: "<for ANY quantitative finding: the fixture/data scale measured against + whether it is production-representative (see § Measurement validity). 'n/a — no threshold finding' when none.>"

## Findings (current iteration)
#### QA-001 | <domain> | <critical|high|medium|low> | <file:line or flow>
observed: "<what's wrong / what a user hits>"
repro: "<steps / inputs>"

## Re-test results
- QA-001: <fixed & re-verified | still failing — iteration N>

## Scale-unverified findings (threshold observations without a representative measurement — NOT blocking)
- <observed value | basis measured against | what scale would settle it>

## Residual risk (medium/low — knowingly accepted, NOT blocking)
- <...>

## Summary
verdict: <pass|escalated>  acceptance: <accept|partial|reject>  critical:N high:N medium:N low:N  iterations: n/3
```

**Verdict state machine:** the `v-qa-reviewer` agent writes `pass` or `fail` (its honest assessment each iteration). The orchestrator rewrites a persistently-failing report to `escalated` only after the 3-iteration cap. `verdict: pass` requires acceptance = `accept` AND zero unresolved critical/high findings (a `reject`/`partial` acceptance is itself a critical finding). `verdict: escalated` requires a companion `BLOCKED_<sid>.md`. The Stop hook accepts `pass` and `escalated`(+BLOCKED); it blocks `fail`, missing, and escalated-without-BLOCKED.

## Autonomy contract

- The loop is entirely orchestrator-driven: it dispatches the QA agent, routes SME analysis, implements, re-verifies, and re-dispatches — no operator step.
- The QA agent is read-only on source (cannot fix) → assessment stays independent.
- The orchestrator owns remediation (it can edit) → the SME directives get implemented.
- The ONLY operator engagement is the escalation artifact after 3 failed iterations.
- The loop self-enforces fix quality: a blind fix that ignores the SME root cause fails re-QA and burns an iteration, so doing the SME analysis properly is the cheapest path to `pass`.

## Anti-patterns

1. **Blind patching.** Fixing the QA symptom without the SME root-cause analysis. The re-test will pass but the real defect (or a sibling) survives → fails next iteration. Always analyze before implementing.
2. **Looping on nitpicks.** Medium/low findings are residual risk, not loop fuel. Only critical/high drive remediation.
3. **Self-grading.** Letting the same agent that built the feature also QA it. QA is a separate, independent dispatch against the *original* request.
4. **Acceptance theater.** Marking `accept` because tests are green. Acceptance is judged against the user's actual intent and observed behavior — "200 response" ≠ "the user got what they asked for."
5. **Scope balloon.** Letting QA remediation expand the diff indefinitely. If a fix needs a product decision or >2x diff, ESCALATE — don't autonomously guess at a large redesign.
6. **Infinite loop.** No cap → runaway cost. Hard cap at 3; escalate with a BLOCKED artifact.
