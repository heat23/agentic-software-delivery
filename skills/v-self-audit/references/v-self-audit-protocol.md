# v-self-audit — per-stage protocol

Detailed instructions each dispatched sub-agent executes. Target throughout: the **local `/v` orchestrator + fleet system** under `~/.claude/` and its runner bin. The full in-scope surface (the audit has historically under-covered everything past `skills/v/**`, which is where recent incidents actually landed):

- **Orchestrator skill:** `skills/v/**`, `skills/v-session-log/**`.
- **All current `/v-*` skills** (not just `skills/v/`): every `skills/v-*/SKILL.md` + its `references/**` — the audit family (`v-audit-*`, `v-audit-orchestrator`, `v-audit-consolidate`, `v-audit-code`), the hunter (`v-bug-hunt`, covering both its `bugs` and `boundaries` lenses — v-edge-hunt merged in 2026-07-05), the design/build/check family, and this skill itself (`v-self-audit`). Compose with `v-skill-reviewer` for the per-skill authoring lens rather than re-deriving it.
- **Fleet runner (a top incident source):** `~/.local/bin/run-v-packs` + `~/.local/bin/run-v-packs-lib/**` (the modularized runner). These fire headless `/v` sessions at scale; their landing/verdict/lock logic is where strand/data-loss regressions concentrate. (`skills/run-claude-ecosystem-review.sh`, the legacy full-audit shell runner, was archived 2026-07-05; `/v-audit-orchestrator` is now the canonical full-audit entry point.)
- **Scripts:** `scripts/**` (gate-cost, mutation-gate, detect-changed-files, codex-review, session-artifact-inventory, harness-test-sweep, e2e/model-dispatch boundary, and the `run-v-packs-*-test.sh` harnesses).
- **Hooks:** `hooks/**` incl. `hooks/lib/validation.sh` and the stop-drain / session-lock machinery.
- **Agents:** `agents/**`.
- **Tests:** `skills/__tests__/**` + `skills/**/references/*-test.sh` + `scripts/**/*-test.sh`.

Read-only on source; ground-truth every claim (cite `path:line`, tag `confidence: confirmed|likely|speculative`); emit the named artifact as your final message (capture mode — no Write).

---

## Stage 1 — Code audit

Mission: find where the `/v` system is incorrect, fragile, contradictory, forgeable, dead, or duplicated. Find the *class*, not one instance. This system has a multi-week history of recurring regressions caught only by manual production-session analysis — your job is to surface them statically.

Examine each dimension; for each, locate the enforcing code, then try to break it:
1. **Independence / provenance.** `hooks/lib/validation.sh` (`_independence_verdict`, `_agent_was_dispatched`, `_prep_independence_signals`) consumed by `hooks/check-review-artifact.sh` (Stop) and `skills/v/references/v-completion-selfcheck.sh`. Enumerate every accepted dispatch-evidence signal (DISPATCH_PROVENANCE log; transcript `subagent_type`; proxy files) and every recognized declared-mode, and test them adversarially: can a same-uid session forge any accepted signal? does an honestly-degraded review get hard-blocked (the failure mode that historically induced fabrication)? Note: the inline-interactive Agent-tool provenance death-loop (a genuinely independent review mis-classified `silent`→BLOCK, and `Dispatch mode: subagent-dispatched` unrecognized) was CLOSED via the SID-keyed DISPATCH_PROVENANCE PostToolUse witness and the `Dispatch mode:` parse at `validation.sh:402` — do NOT report it as an open finding unless you can reproduce a regression; instead confirm it is still closed and hunt for NEW siblings of the class.
2. **Survival / concurrency.** `_survival_verdict`; `skills/v/references/v-merge-back.sh`, `v-suite-lock.sh`, `v-active-siblings.sh`; worktree machinery. Can racing sessions lose each other's work (stash churn, merge-back race, shared-main edits)? Does the survival gate key on `git status --porcelain` and fire recoverably mid-session?
3. **Contract drift (dominant class).** Every authored template (`skills/v/references/dispatch-v-*.md`, `v-artifact-skeleton.sh`, `skills/v-session-log/DISPATCH_PROMPT.md`, `SCHEMA.yaml`) must round-trip through its validator (`skills/v-session-log/references/validate-log.py`; the Stop hook's `validate_*_semantics`). List every (producer → validator) pair and flag any that diverge.
4. **Inline-vs-fork dispatch + model pins.** `v-dispatch-subagent.sh`; where the orchestrator/reviewer model is actually selected; any instruction that assumes a lever that's inert (frontmatter `model:` for inline).
5. **Failure-mode handling.** codex unavailable; browser/Playwright absent; resolver exit codes 4/5/6/7; malformed input. Each must fail loud-but-safe, never silently pass or hard-crash.
6. **Dead / duplicate / contradictory.** Unreferenced scripts; two implementations of one rule that can drift; instructions contradicting each other across SKILL.md vs references vs hooks. For orphan test harnesses: do NOT compare against `run-vitest-suite.sh` directly — it runs only `*.test.ts` files, so every `*-test.sh` shell script would trivially "fail" that comparison whether or not it's actually wired in, producing a 100%-false-positive list. The real coverage mechanism is `scripts/harness-test-sweep.sh` (itself invoked by `harness-sweep-coverage.test.ts`, which IS one of `run-vitest-suite.sh`'s `.test.ts` files): it sweeps every `*test*.sh` in the canonical harness dirs (`v-session-log/references`, `v/references`, `hooks`, `scripts`) and runs it, skipping only files carrying a `harness-sweep-skip:` marker. Compose with that sweep instead of re-deriving orphan detection: a true orphan is a `*-test.sh` sitting OUTSIDE those swept dirs, or a directory harboring test scripts that was never added to `harness-test-sweep.sh`'s `SWEEP_DIRS` — check both. **This 4-dir list is a prose duplicate of `harness-test-sweep.sh`'s own `SWEEP_DIRS` array (currently `scripts/harness-test-sweep.sh` lines ~21-26) — it is NOT read from that array programmatically, so it CAN silently drift if `SWEEP_DIRS` gains/loses a directory and this line isn't updated to match. Before trusting "outside those swept dirs" as a true-orphan signal, diff this list against the live `SWEEP_DIRS` array in `scripts/harness-test-sweep.sh` (e.g. `grep -A6 'SWEEP_DIRS=(' scripts/harness-test-sweep.sh`) and flag any mismatch as a finding in its own right, not just a stale doc nit.**

Compose with `v-skill-reviewer` for the skill-authoring lens rather than re-deriving it.

**Emit `# AUDIT_REPORT`** with: a one-line invariant scorecard (independence / survival / contract / failure-handling: Upheld|Partial|Broken), then a findings list — each `### F<n>: title` with `severity:` (CRITICAL/HIGH/MEDIUM/LOW), `class:`, `evidence: path:line`, `manifests:` (runtime effect), `confidence:`, `proposed-fix:` and `fix-risk:` (LOW/MED/HIGH — MED/HIGH if it touches a gate's accept logic, model tiers, or correctness). CRITICAL/HIGH/MEDIUM/LOW is this stage's own ad-hoc vocabulary, kept because it reads naturally for a code-audit narrative — but it is NOT a second, competing scale: per `[[v-core-severity]]` (`~/.claude/skills/references/v-core-severity.md` § Cross-vocabulary mapping), normalize CRITICAL→P0, HIGH→P1, MEDIUM→P2, LOW→P3 before this report feeds any downstream consolidation or SHIP_LIST prioritization — append the normalized `P#` alongside each finding's native `severity:` field. End with `## Coverage & gaps`.

---

## Stage 2 — Efficiency evaluation (fact-based)

Mission: measure — not estimate — where `/v` spends tokens and wall-clock, and propose LOW-risk levers toward a **10–20%** cost reduction.

Source telemetry (real recent sessions): per-message token fields in the transcript JSONL under `~/.claude/projects/*/<sid>.jsonl` and `<sid>/subagents/**` (`cache_read`, `cache_creation`, `output`/`input`); `DISPATCH_PROVENANCE_*.log` (`cost_usd`, `duration_ms` per dispatch); session-log `token_cost`. Reuse existing tools if present — locate `gate-cost.py` (check `~/.claude/scripts/` and `~/.claude/.v/tmp/`) and `v-token-profile.py`; **validate the tool against transcript ground truth before trusting it** (its classifier has under-counted reviewers before). If a tool is missing or wrong, compute the split directly from the transcripts and mark `measurement: degraded (direct)`.

Compute and report:
- **Component split**: cached (`cache_read`) vs non-cached (`cache_creation` + `output`), in tokens AND price-weighted $ and %. (Reminder: dedup per-message by message.id, last-wins, to avoid streaming-partial double counts.)
- **Per-consumer / per-stage attribution**: orchestrator resident × turns, growth, and each gate/sub-agent dispatch.
- **Wall-clock per stage/gate** from `duration_ms` + transcript timestamps; separate **BILL** (model tokens) from **WALL-CLOCK** (test subprocesses ≈ zero tokens).
- **Ranked cost drivers** with evidence.
- **Candidate LOW-risk levers** (quality-neutral / gate-safe), each with measured-impact estimate, risk tag, and BILL-vs-WALL-CLOCK tag. Bias to: de-prose machine-only `.md` artifacts; anchor-guarded resident trim; pre-impl pipeline de-dup; gate-prompt cache reuse; session-growth discipline. Tag reviewer/model down-tiering or per-project Opus→Sonnet as MEDIUM (Deferred), not recommended.

**Emit `# EFFICIENCY_REPORT`** with: a `measurement:` provenance line (which sessions, tool used or direct, totals reconciled Y/N), the component-split table, the per-consumer/per-stage table, the wall-clock table, ranked drivers, and the candidate-lever table. No asserted numbers without provenance.

---

## Stage 3 — Adversarial review

Mission: red-team the Stage 1 + Stage 2 findings. Default-skeptical: every finding is unproven until you reproduce it; every proposed fix/lever is dangerous until traced. When uncertain after a real attempt, default to Refuted/Unverifiable.

For EVERY finding assign: **Confirmed** (reproduced/verified line) / **Refuted** (false — show contradicting evidence) / **Overstated** (real but narrower) / **Understated** (worse than claimed) / **Unverifiable** (couldn't ground). For every proposed fix/lever assign **Ship / Revise / Reject** — and REJECT anything that would weaken, bypass, or make more permissive any gate (independence/survival/contract/pre-commit/Stop), even if convenient. For efficiency levers, refute over-claimed sizes (re-derive the number) and reject any lever that trades correctness or touches the review/safety net. Verify by reading the cited `path:line` and, where feasible, running the command. Re-derive highest-severity findings independently — don't reuse the audit's reasoning.

**Emit `# ADVERSARIAL_REVIEW`** with: a top `independence:` line (real|degraded), a verdict table (finding ID → verdict + one-line evidence + corrected severity), a fix-safety table (fix/lever → Ship|Revise|Reject + reason + the regression/gate-weakening it would cause), a list of refuted/overstated items, and any NEW issues found while verifying (marked NEW). End with `## What I verified vs only read`.

---

## Stage 4 — Synthesis

Mission: reconcile Stage 1 + 2 + 3 into ONE ship-ready, LOW-risk-by-default list. No new analysis.

Rules: a finding/lever advances only if the adversarial stage marked it Confirmed/Understated/Overstated-but-real (Refuted→Rejected bucket; Unverifiable→Deferred). Take the adversarial-corrected severity and the safe fix form (Revise→use the safer alternative, or Deferred if none given). Dedupe per the conflict map. **By default the recommended list contains ONLY LOW-risk, gate-safe, quality-neutral items**; MEDIUM/HIGH (gate accept-logic, model tiers, review-net, correctness trades) go to a separate Deferred/opt-in section. Drop anything that weakens a gate outright.

Each recommended code fix carries: root cause (one line), files (`path:line`) + consumers touched, change intent, the **safety invariant to preserve**, the **regression-test spec** (which harness stays green + the new test that fails on the un-fixed code + a negative case + that it's wired into `run-vitest-suite.sh`), risk, rollback. Each efficiency lever carries: measured impact, BILL/WALL-CLOCK tag, risk.

**Emit `# SHIP_LIST`** with: `## Recommended now (LOW-risk)` (ordered/batched, full spec per item), `## Deferred / opt-in (MEDIUM/HIGH)`, `## Rejected` (refuted/gate-weakening, one-line reason each), and `## Conflict ledger`. End with a one-screen exec summary (counts per bucket).

**Make the SHIP LIST executable, not just prose — supply runnable-pack raw material.** This stage runs in capture mode (no Write tool), so the sub-agent does NOT write the pack tree itself; instead, for EACH recommended LOW-risk item, the SHIP_LIST must include a ready-to-emit **pack body** — a paste-ready `/v Fix …` (or `/v-<skill> …`) prompt, ≥10 lines, self-contained, no YAML frontmatter, no `git commit`/`git push`, ending "leave staged; do not commit" — plus a **wave tag** (`wave: 0|1|2…`) computed per `~/.claude/skills/references/v-runnable-pack-convention.md` § Wave assignment (same-file/different-fix items MUST get different waves — the load-bearing parallel-safety invariant). **The pack body itself MUST carry the mandatory body schema, in this order** (`v-runnable-pack-convention.md` § Pack body schema): `## Goal` (outcome + why, tied to the finding) · `## Context` (the finding inlined with `path:line` evidence — never "see AUDIT_REPORT/SHIP_LIST", the pack sits alone in a cold session) · **`## Files`** (every file the fix touches, literal H2 — v-build's scope guard keys on it) · `## Changes` (the concrete steps) · `## Acceptance criteria` (checkbox) · `## Tests` (the regression-test spec below, made concrete) · `## Constraints` ("Read the project's CLAUDE.md first" + the safety invariant to preserve; if `## Files` touches ANY of request signing/HMAC, webhook or signature verification, credential/secret handling, host/URL construction from variables, auth/authz decisions, or payment flows, also inline verbatim: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session.") · `## Dependencies` (`Wave <N>. Requires: <prior item ID(s) or none>`). Each pack body embeds that item's regression-test spec (the test that must fail on the un-fixed code + negative case + wiring into `run-vitest-suite.sh`) inside `## Tests`. DEFERRED / MEDIUM-HIGH items and efficiency levers get NO pack body — they are advisory, not gate-safe to fire-and-forget. The v-self-audit orchestrator (which holds the Write tool) assembles these bodies into the on-disk `$ADIR/ship-pack-<MM-DD>/` tree and self-validates it — see the SKILL's Stage-4 note. Format each in the SHIP_LIST so the orchestrator can lift it verbatim:

```
### <ITEM-ID> — <title>  (wave: <N>)
<pack body: first line `/v Fix …`, then ## Goal/## Context/## Files/## Changes/
## Acceptance criteria/## Tests/## Constraints/## Dependencies in order,
ends "leave staged; do not commit">
```

---

## Stage 5 — Testing audit

Mission: prove how far the test suite is behind reality and why. The premise is that green ≠ correct — quantify the divergence by EXECUTION, not reasoning. `npm test` runs from `skills/__tests__/` via `run-vitest-suite.sh`.

1. **Inventory + fidelity**: every test (vitest specs + `*-test.sh`) → layer (unit/integration/e2e) × {real artifact | reimplementation/mock} × {behavioral | sentinel-grep} × {has-negative?} × {executed by run-vitest-suite.sh? | orphan} × {deterministic?}.
2. **Coverage-gap map**: for every workflow step / gate / script / hook / producer↔validator contract / dispatch-mode / failure-mode / concurrency scenario, mark real-behavioral / sentinel-only / none.
3. **Backtest (executed)**: from `git log` on `skills`/`hooks`, session-log/HANDOFF/forensic artifacts, and the documented incidents (interactive Agent-tool provenance; manual `/v-session-log` abandonment; survival/data-loss; contract drift; concurrency stash-drop), reconstruct each past bug's pre-fix state ON A TEMP COPY (`cp` into `mktemp -d`), run the relevant harness, and record caught / not-caught + whether the catching test pre-existed the fix (proactive) or shipped with it (retro). Report the **proactive catch rate**.
4. **Mutation kill-rate (executed)**: in a temp copy, inject faults into the most safety-critical invariants (independence/survival/contract validators, pre-commit/Stop enforcement) — weaken a regex, drop a required field, make a gate `return 0`, revert a known fix — and confirm a test goes RED. Report kills/injected per area + the survivors (faults no test caught). `rm -rf` every temp dir.
5. **Structural diagnosis**: in a few sentences, why is the suite systematically behind? (no true e2e? sentinel tests? orphan harnesses? mocks that diverge? new behavior shipping without a regression test? production as the only oracle?)

TEMP-COPY DISCIPLINE IS MANDATORY — never mutate the live tree; always clean up.

**Emit `# TESTING_AUDIT`** with: the inventory table, the coverage-gap map, the backtest result (per-bug + overall + proactive rate), the mutation kill-rate per area + survivors, and the structural diagnosis. End with `## Coverage & gaps` (what you executed vs only inspected).

---

## Stage 6 — Testing synthesis

Mission: turn the Stage 5 findings into ONE self-validating testing plan. No new analysis.

North-star metrics first: baseline + target for **proactive backtest catch rate**, **mutation kill-rate**, **orphan-harness count** (target 0). The plan's definition of done is hitting these thresholds, not shipping N items.

Foundations first (prerequisites): real **e2e harness** (run a real `/v` workflow against a scratch git repo, inline AND forked, real Stop hook, assert outcomes); real-session **fixture corpus** (frozen sanitized transcripts/artifacts replayed through the real validators; seed with the documented past bugs); **mutation/fault-injection mechanism** + the **mandatory pre-ship mutation gate** (a change isn't done until its regression test is proven to fail on the un-fixed code + has a negative case + is wired into the right tier); **orphan-harness killer** meta-test; determinism conventions (`env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID`, fixtures not live-state, no line-number pinning). Then per-bug-class regression tests, then the "what's-untested" critic.

Tier every item: **fast** (unit/contract/parity — every cycle) vs **gated** (e2e/replay/mutation — pre-flight/CI only). Each item is **proof-carrying**: it must be demonstrated to fail on the un-fixed/mutated code and pass on correct code, with a negative case, anchored to a Stage-5 gap/backtest-miss/mutation-survivor.

**Emit `# TESTING_PLAN`** with: north-star metrics (baseline/target), the foundations (ordered), the per-class regression items (each with target + self-proof + tier + wiring), the standing mutation-gate + critic spec (with enforcement point), the tiering/runtime plan, the whole-plan definition-of-done (metric thresholds), and a residual-risk section.
