# AI Feature Engineering — cost, reliability, correctness, and UX for model-backed features

_Last reviewed: 2026-08-02 (created — AI-era coverage sweep; canon file for the new
"AI/model-backed feature engineering" theme, registered in `references/v-theme-owners.md`)._

> **Persona for this reference:** an engineer building or reviewing a model-backed
> feature (chat, generation, extraction, classification, agentic tool-use) inside an
> otherwise-ordinary SaaS product, writing guidance meant to hold up as the
> underlying models and providers change out from under it.

**Scope boundary.** This file covers cost, reliability, correctness, and UX for
model-backed features. It does not cover prompt-injection defense, authorization of
who can call a model feature, or secrets/credential handling for provider access —
those are `_v-security.md`'s domain and are out of scope here. Job-level mechanics
(budget enforcement before dispatch, timeouts, retry policy, the streaming pattern)
live in `~/.claude/skills/_v-jobs.md § Model-Call Jobs` — cite that, don't restate it.
Code-review-time detection of missing cost/abuse controls lives in
`~/.claude/skills/v-audit-code/references/audit-lenses.md § Cost & abuse: metered
outbound calls` — this file is the reasoning those controls are built from, not the
audit checklist itself.

**Durability note for future edits.** Model capability tiers, context windows, and
pricing change faster than any other part of this stack. Write every rule in this
file as a decision procedure (a threshold, a comparison, an escalation trigger),
never as a snapshot of what a specific provider or model currently costs or
supports. Never name a specific model as a recommendation — name the selection
criteria. If a genuinely volatile fact needs to live somewhere, give it its own
dated reference with a `_Last reviewed:_` stamp and a staleness window + refresh
trigger, following `~/.claude/skills/references/seo-volatile-knowledge-2026.md §
Staleness` — never inline it here as timeless truth.

---

## Cost model

A model-backed feature has unit economics the same way a physical SKU does — the
difference is that "cost per unit sold" is invisible until you compute it, and it
can vary 10-100x between the cheapest and most expensive input the UI allows.

- **Reason in cost-per-action and cost-per-active-user, not cost-per-token.**
  Token/request counts are a volatile implementation detail of the current provider
  and model; cost-per-action ("$X to summarize one document," "$Y per active user
  per month at observed usage") is the durable unit that survives a model swap and
  is what actually shows up on a bill.
- **Decision rule: a model-backed feature needs a known worst-case cost per user
  BEFORE it ships, not an average-case estimate.** Compute it from the ceiling, not
  the median: the maximum input size the UI allows × the maximum number of calls one
  user action can trigger (including any internal retries or multi-step/agentic
  calls) × the most expensive capability tier the feature is allowed to escalate to
  (see § Model selection criteria below). That worst-case number is what feeds the
  per-user/per-tenant spend cap `~/.claude/skills/_v-jobs.md § Model-Call Jobs`
  enforces before dispatch — a cap derived from average observed usage instead of
  the worst case is not a cap, it's a hope.
- **Distinguish COGS-bounded from metered-passthrough features.** A flat-rate
  feature (no per-use charge to the customer) needs its worst-case cost to fit
  inside the margin the plan price allows for one user — if it doesn't, either the
  feature needs metering/capping or the plan is underpriced for it. A
  metered/credit-based feature still needs the same worst-case number, because the
  cap protects against a bug or an abusive account generating cost the customer was
  never billed for, not only against underpricing. (Whether the customer-facing
  price is high enough to cover this cost is a pricing/margin question owned
  elsewhere in the audit family — this section is the engineering-side number that
  question depends on, not a restatement of the pricing check itself.)
- **Recompute the worst case whenever the feature's input surface changes shape** —
  a new file-upload path, a longer allowed context, a new multi-step chain — not
  only when the model changes. The input surface drifting silently past the
  original worst-case assumption is the more common way this number goes stale.

## Model selection criteria

Naming a specific model as "the" choice is wrong within months by construction —
capability, price, and what counts as "the cheap tier" all move. What doesn't move
is the decision procedure:

- **Think in capability tiers, not model names:** a fast/low-cost tier suited to
  classification, extraction, and short transforms with a narrow, checkable output
  space; a mid tier for structured generation or moderate multi-step reasoning; a
  high-capability tier for complex reasoning, agentic tool-use, or generation
  quality that is directly customer-visible as the product's core value. Every
  provider's lineup maps onto some version of this shape even as the specific names
  and boundaries shift under it.
- **Decision rule: start with the cheapest tier that passes the feature's eval bar
  (§ Eval harness below); escalate only on a measured failure against that suite,
  never on a subjective "feels smarter" judgment.** Document the specific
  escalation trigger (an eval pass-rate threshold, a named failure class) so a
  future review — or a future model swap — is a decidable re-run of the same suite,
  not a fresh argument.
- **Escalation is a ladder, not a switch.** Move up exactly one tier at a time and
  re-run the eval suite at each step; jumping straight to the most capable tier
  because a mid-tier failure was alarming is usually paying for capability the
  feature doesn't need everywhere it's used.
- **Re-evaluate tier assignment on a cadence, not only at launch.** Provider
  capability and pricing shift underneath a shipped feature; a periodic (e.g.
  quarterly) re-run of the eval suite against the current cheapest tier catches a
  feature that's now overpaying for capability a newer cheap tier already clears.

## Eval harness

**This is the piece most often skipped, and the one most likely to be missing from
an otherwise well-built feature — a model-backed feature with no eval suite is a
feature nobody can prove still works after the next change.**

- **Why it's needed beyond ordinary tests:** ordinary unit/feature tests assert
  exact expected values. Model output varies run to run even at fixed input, so a
  test asserting an exact string is either flaky (the model phrased it differently)
  or vacuous (the assertion was loosened until it always passes). An eval harness is
  the regression suite built for that reality — a fixed set of input →
  expected-*property* cases, run against the model, scored on whether the
  properties hold.
- **What to assert — properties and invariants, never exact strings:** output
  contains/omits specific required elements; output parses as valid
  JSON/matches a schema when structure is required; output stays within a length or
  format bound; a classification lands in the correct category; a factual claim
  checkable against the input is present and not contradicted; refusal/safety
  behavior fires on cases designed to trigger it; latency and cost per case stay
  under the budget from § Cost model. Exact-string assertions belong in the
  deterministic tests for your own parsing/formatting code, not in the eval suite
  for the model's output itself.
- **Build the suite from real failure modes, not only happy paths:**
  adversarial/edge-case inputs (empty, maximum-length, malformed, ambiguous,
  off-topic), at least one case per known prior failure (every bug found in
  production becomes a permanent eval case, the same way a regression test is added
  for a code bug), and enough volume per property to catch a regression that only
  fails some fraction of the time — a single passing example proves nothing about a
  system with run-to-run variance.
- **How it plugs into the existing test story:** the eval suite is a distinct pass
  from the deterministic test suite (see § Non-determinism in tests below for why)
  — run it on a schedule (pre-ship for the feature, and periodically post-ship,
  since a provider-side model update can shift behavior with no change on your own
  side) rather than gating every commit, and treat a drop in eval pass rate the same
  way a newly-failing test would be treated: something changed, find out what
  before shipping further.
- **A pass-rate threshold, not 100%.** Model output is inherently variable; require
  the suite to clear an explicit bar (e.g. "≥95% of property checks pass, zero
  failures on the safety/refusal subset") rather than demanding every case pass
  every run — and treat a drop below the bar as a blocking regression the same way
  a failing deterministic test would block.

## Non-determinism in tests

A model-backed feature's output varies at fixed input — the deterministic test
suite (the project's normal unit/feature-test run) still has to be reliable and
fast, which means it cannot depend on a live model call.

- **Fixture/replay for CI:** record a real model response once (input, output, and
  enough metadata to know it's still representative) and replay it as a fixture in
  the deterministic suite — the test asserts your code's handling of that response
  (parsing, error branches, UI state transitions), not the model's judgment. This
  keeps the deterministic suite fast, offline-capable, and immune to provider-side
  flakiness or cost.
- **Property assertions where a live call is genuinely unavoidable** (e.g. an
  end-to-end smoke test): assert structural properties (parses, non-empty, within
  bounds) rather than content equality, and mark the test explicitly as
  non-deterministic/quarantined from the suite that gates a normal commit.
- **Decision rule: a live model call must never gate the deterministic test suite.**
  If a test needs a real call to pass, it belongs in the eval harness (§ Eval
  harness above) — run on its own schedule, with its own pass-rate bar, tolerant of
  and reporting on variance — never in the suite a routine code change has to pass
  to merge. A deterministic suite that occasionally fails because the model phrased
  something differently today is a suite nobody trusts, and an untrusted suite gets
  ignored exactly when it matters.
- **Freeze everything else.** The usual determinism rules still apply on top of
  this (freeze time, avoid engine-specific tie-breaks) — the model-response fixture
  removes the one source of variance unique to this feature class; it doesn't
  replace the rest of test-determinism discipline.

## Degradation UX

A model-backed feature has more ways to be temporarily unusable than an ordinary
CRUD feature — slow, unavailable, over budget, and technically-successful-but-
unusable output are each a distinct state, and each needs a designed response
rather than a raw error.

- **Map each failure onto the house error-handling ladder**
  (`~/.claude/CLAUDE.md § Production Standards`: partial data > cached fallback >
  empty state > error page — never raw exceptions to users):
  - **Slow** (still within timeout but past what feels instant): a loading state
    that communicates progress, not a frozen UI — see
    `~/.claude/skills/_v-jobs.md § Model-Call Jobs` for the streaming-vs-polling
    mechanism this state is built on.
  - **Unavailable** (provider outage, timeout exceeded, retry ceiling exhausted):
    cached fallback if a prior result exists and its staleness is acceptable to say
    out loud ("showing your last result — retry for a fresh one"); otherwise a
    designed empty/unavailable state, never a raw exception or a generic error page.
  - **Over budget** (the per-user/per-tenant cap from § Cost model /
    `~/.claude/skills/_v-jobs.md § Model-Call Jobs` is hit): an explicit, specific
    message stating the limit and when or how it resets or can be increased — never
    a silent failure, and never a generic error indistinguishable from a real
    outage.
  - **Unusable output** (the call succeeded but failed an eval-harness-style
    invariant, or your own validation): treat it as a failure, not a success —
    route it to the same degraded path as an outage rather than showing the user
    output you already know is broken.
- **These map onto the house's six canonical UI states**
  (`~/.claude/skills/v-build/references/saas-patterns.md § UI state management
  checklist`) rather than inventing new ones: slow is the loading state,
  unavailable/over-budget/unusable-output are variants of the error state (each
  with its own specific message per above), and a feature with no prior result to
  fall back on is the empty state. Cite that checklist for the state-coverage
  requirement itself — this section only adds the model-specific mapping onto it.
- **Never let a model-backed feature's failure take down a surface that doesn't
  need it.** A model-backed suggestion or enhancement layered on top of a core flow
  should degrade to the core flow working without it, not block the whole surface —
  reserve a hard block for the rare feature where the model call *is* the entire
  value of the surface.

## Observability

Cost and quality regressions in a model-backed feature are invisible unless the
call itself is logged with enough structure to detect them — a generic "job ran"
log line proves nothing about whether the feature is working, or what it costs.

Log at minimum, per model call, on top of the house structured-logging floor
(`~/.claude/CLAUDE.md § Production Standards`: `user_id`, `action`, `duration_ms`,
`ip` minimum) — and never log secrets, raw prompts, or provider credentials beyond
what that floor already requires
(`~/.claude/CLAUDE.md § Security Defaults` never-log list; treat raw prompt/response
content as sensitive by default unless a deliberate, documented decision says
otherwise):

- **Latency** (`duration_ms`, already in the house minimum) — the number that shows
  a timeout tuned per `~/.claude/skills/_v-jobs.md § Model-Call Jobs` drifting out
  of date as usage patterns shift.
- **Token/unit counts** (input and output, or whatever the provider's own billable
  unit is) — the raw input to the cost-per-action number in § Cost model; without
  this, a cost regression is only visible on the bill, weeks later.
- **Model/capability-tier identifier** — which tier handled the call (see § Model
  selection criteria), so an escalation-rate regression (more calls silently
  climbing to a more expensive tier) is visible in logs before it's visible in cost.
- **Outcome** — success, non-retryable rejection, retryable-failure-then-success, or
  exhausted-retries/failed — the same success/failure taxonomy
  `~/.claude/skills/_v-jobs.md § Model-Call Jobs` uses to route retry decisions,
  logged so the ratio is queryable over time.
- **Cost estimate** — a computed per-call cost (from the unit count and the tier's
  rate) attached to the log line, even if approximate; this is what turns "spend
  went up" into "spend went up because feature X's tier-escalation rate rose," a
  diagnosable regression instead of a mystery.
- **Eval/quality signal where available** — if the call matches a case the eval
  harness also covers, or a lightweight runtime check (schema validation, length
  bound) ran against the live response, log its pass/fail — this is what makes a
  quality regression (not just a cost or latency regression) detectable from
  production traffic between scheduled eval runs.

Aggregate these into whatever the project's existing metrics/logging pipeline
already does for other jobs — this section does not introduce a new observability
*system*, only the fields a model-call job's log line needs beyond the house
minimum to make cost and quality regressions detectable, consistent with
`~/.claude/CLAUDE.md § Production Standards`'s structured-logging requirement.

---

## Cross-references

- `~/.claude/skills/_v-jobs.md § Model-Call Jobs` — job-level mechanics (budget
  enforcement before dispatch, timeouts, retry policy, streaming pattern). This
  file owns the reasoning that produces those numbers and policies; that section
  owns their implementation.
- `~/.claude/skills/v-audit-code/references/audit-lenses.md § Cost & abuse: metered
  outbound calls` — the code-review-time check that the controls this file argues
  for actually exist and fire on every metered call site.
- `~/.claude/skills/v-build/references/saas-patterns.md § UI state management
  checklist` — the six canonical UI states § Degradation UX maps onto; owner for
  state-coverage requirements generally.
- `~/.claude/CLAUDE.md § Production Standards` — the error-handling ladder and the
  structured-logging minimum fields this file's § Degradation UX and § Observability
  sections build on.
- `~/.claude/skills/references/v-theme-owners.md` — this file's registry row; the
  theme-ownership rule (cite, never restate) governing this file itself.
