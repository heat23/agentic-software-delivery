# Success Criteria Derivation (Step 1.7) — extracted from /v SKILL.md

> **Loaded by:** /v Step 1.7, after classification (Step 1) and before Step 3 build, for **Bug Fix + Feature Tiny/Small** workflows. Feature Medium/Large reuse the acceptance-criteria block produced by `/v-new-feature` (see § Reuse for Medium/Large) instead of re-deriving here.
>
> **Why this exists:** the default failure mode of autonomous coding is "tests are green, therefore done" — a *machine-verifiable* signal that does not match *"a human using this feels like it worked."* Unit tests pass while the real workflow breaks because nobody wrote down what "works" means for the **whole flow**, including its non-happy states. This step makes the definition of done explicit, declarative, and state-complete BEFORE code is written, so it can drive tests (Step 3 / v-tdd), the browser workflow gate (Step 3.5), and the completion check (Step 6/7).
>
> **Output:** `SUCCESS_CRITERIA_<sid>.md` at project root. AI-consumed artifact (terse YAML, no prose padding). Consumed by /v-tdd, v-workflow-verifier, and Step 6/7 as the literal stopping condition.

## Principle — declarative, not imperative

Write the **outcome** and the **observable condition that proves it**, not a list of implementation steps. Imperative ("use tanstack-table, add a sort handler, hide empty state behind a flag") tells the model *how* and invites gold-plating with no stopping point. Declarative ("the team can scan, sort, and spot data-quality issues across 10k+ rows without lag; missing data is surfaced, not hidden") tells the model *what success is* and *when to stop*.

Each criterion must be **falsifiable** — there must be a concrete way to observe pass/fail (a test assertion or a browser observation). "Looks good" is not a criterion. "Submitting the form with an empty required field shows an inline error and does not POST" is.

## Mandatory workflow-state coverage

A criterion set that only covers the happy path is incomplete by construction — the happy path is exactly the part that already works. For every user-facing workflow the task touches, the criteria MUST address each of these states or mark it `n/a` with a one-line reason:

| State | Question it answers |
|---|---|
| `empty` | First-run / no-data: is there an empty state, or a blank/broken screen? |
| `loading` | Async in flight: is there a loading affordance, or a frozen UI / layout shift? |
| `error` | Server 4xx/5xx, validation failure, network drop: is it surfaced to the user (not a raw exception / silent no-op)? |
| `slow_network` | Throttled connection: does the UI stay usable, or double-fire / appear hung? |
| `permission_denied` | Wrong user / role / unauthenticated: is access blocked with a clear response (not a 500, not silent data leak)? |
| `concurrent` | Two tabs / two users / stale data: does it corrupt state or lose writes? |
| `double_submit` | Button mashed / form resubmitted: idempotent, or duplicate side effect? |

These are the states where "tests pass, UI broken" bugs live. The block is mandatory; `n/a` is allowed but must be justified (e.g., `concurrent: n/a — single-user settings page, no shared record`).

## Mandatory behavior-change coverage (inverse · isolation · branch)

The state block above covers a flow's *states*. This block covers the *logic the change introduces* — and it is where self-inflicted bugs are actually born: a behavior that fires in the wrong case, state that bleeds between actors, a condition verified only in its "on" position. These three lenses are **language- and domain-agnostic** (they apply equally to a UI conditional, an API authorization check, a CLI flag, a cache key, a queue handler, or a library's option parsing). For **every new conditional behavior or decision** the change introduces, the criteria MUST address each lens or mark it `n/a` with a one-line reason:

| Lens | The obligation | The bug it prevents |
|---|---|---|
| `inverse` | For every "X happens when C", also assert **X does NOT happen when NOT C**. | a behavior shown / fired / allowed for the wrong audience, input, role, tier, or state |
| `isolation` | If the change reads or writes shared / persisted / cached / global state, assert **two distinct actors** (user / tenant / request / key) get **isolated** results — A's value never surfaces for B. | cross-actor data bleed, missing scoping, a shared key/handle without an owner |
| `branch` | Assert **every branch** of a new conditional/decision — the on AND the off, the allow AND the deny, each failure mode — not just the branch the happy path takes. | a condition that's correct when true but wrong / over-eager when false |

Most "the review caught a bug I introduced" findings are an unwritten `inverse`, `isolation`, or `branch` assertion. Writing them here (so v-tdd makes them fail FIRST) means the first draft has to be correct — the bug is never written, rather than written-then-caught. `n/a` is allowed but justified (e.g., `isolation: n/a — pure formatting helper, no shared state`; `inverse: n/a — unconditional copy change`).

## Derivation protocol

1. **Name the workflow(s).** What user-facing flow does this task change? State it as a user goal ("subscribe to a plan", "invite a teammate", "export the report"). If the task touches more than one flow, list each.
2. **Write 3–7 declarative criteria.** Lead with the primary outcome, then the secondary outcomes. Each gets a `verify_by` (`test` / `browser` / `both`) and a `done_when` (the observable pass condition). Prefer `both` for anything a user clicks through.
3. **Fill the workflow-state block** (above) for each flow. Each state becomes a criterion or an explicit `n/a`.
4. **Fill the behavior-change coverage block** (`inverse` / `isolation` / `branch`, above) for each new conditional behavior the change introduces. Each obligation becomes a falsifiable criterion (it flows to v-tdd as a RED test) or an explicit `n/a` with reason.
5. **Pin design forks before coding (decide-once).** If implementing this admits ≥2 viable approaches with materially different tradeoffs (e.g. derive a value vs. persist it; reuse an existing field vs. add one), DECIDE now — pick one with a one-line rationale, or escalate to the operator if it's genuinely the operator's call — and record it. This prevents relitigating the same fork mid-build (a real churn source: a session re-argued one such fork 3× while implementing). A fork that touches a guardrailed/owned area you were told not to change is resolved by staying inside scope, not by reopening it.
6. **Write the human-success sentence.** One sentence answering: *"Would a person actually using this feel like it worked?"* This is the check Step 6/7 applies — it is the antidote to "200 response ≠ it worked."
7. **Write `SUCCESS_CRITERIA_<sid>.md`** with the schema below.

Keep it tight. This is scaffolding for downstream skills, not a spec document. 5–7 criteria + the state block is the target size.

## Reuse for Medium/Large (no duplication)

When the workflow is Feature Medium/Large, `/v-new-feature` already produces `PLAN_*_<sid>.md` with an acceptance-criteria section. Do NOT re-derive. Instead:
- Require that the plan's acceptance-criteria section contains BOTH mandatory blocks above — the workflow-state block AND the behavior-change coverage block (`inverse`/`isolation`/`branch`). If `/v-new-feature` omitted either, append it.
- Emit `SUCCESS_CRITERIA_<sid>.md` as a thin pointer: `source: PLAN_<...>_<sid>.md` plus the workflow-state block, the behavior-coverage block, `design_decisions`, and the human-success sentence, so Step 3.5 / Step 6 have a single stable filename to read regardless of tier.

## Output artifact (`SUCCESS_CRITERIA_<sid>.md`)

```yaml
success_criteria:
  session_id: "<sid>"
  task: "<one-line task summary, quoted from the resolved user prompt>"
  source: "<derived | PLAN_<...>_<sid>.md for Medium/Large>"
  workflows:
    - name: "<user goal, e.g. 'subscribe to a plan'>"
      entrypoint: "<route or page path, e.g. GET /billing/subscribe>"
  criteria:
    - id: SC-1
      statement: "<declarative outcome — what success IS>"
      verify_by: "<test | browser | both>"
      done_when: "<observable pass condition — a test assertion or a browser observation>"
    # 3–7 total
  workflow_states:        # MANDATORY — one line each, n/a allowed with reason
    empty:             "<expected behavior | n/a — reason>"
    loading:           "<...>"
    error:             "<...>"
    slow_network:      "<...>"
    permission_denied: "<...>"
    concurrent:        "<...>"
    double_submit:     "<...>"
  behavior_coverage:      # MANDATORY — for each new conditional behavior; n/a allowed with reason
    inverse:    "<X does NOT happen when NOT C — the case it must NOT fire | n/a — reason>"
    isolation:  "<actor A and actor B get isolated results | n/a — no shared/persisted state>"
    branch:     "<every branch of the new conditional asserted | n/a — no new conditional>"
  design_decisions:       # forks pinned before coding (decide-once); [] if none
    - fork: "<the choice, e.g. 'label: derive from existing field vs. add a column'>"
      chosen: "<the decision + one-line rationale, or 'escalated to operator'>"
  human_success_check: "<one sentence: would a real user feel this worked?>"
```

## How downstream skills consume this

- **/v-tdd** reads `criteria[].verify_by in (test, both)`, the backend-observable `workflow_states` entries, AND every non-`n/a` `behavior_coverage` lens → one failing test per item, written RED before implementation (route→feature test preferred over mock-only unit test). The `behavior_coverage` tests are the highest-leverage: an `inverse`/`isolation`/`branch` test that fails first forces the first draft to be correct, so the bug is never written rather than written-then-caught in review.
- **v-workflow-verifier** (Step 3.5) reads `criteria[].verify_by in (browser, both)` + the `workflow_states` block → the live exercise script + the committed golden-path spec; asserts `human_success_check` is actually demonstrable.
- **Step 6/7 stopping condition** — completion is not "tests green"; it is "every SC-* is demonstrated (by a passing test or browser evidence) AND `human_success_check` holds." A green suite with an unmet SC-* is NOT done.

## Anti-patterns

1. **Imperative criteria.** "Add a useEffect that fetches on mount" is a step, not a success criterion. Rewrite as the observable outcome.
2. **Happy-path-only.** Omitting the workflow-state OR the behavior-change coverage block (or filling either all `n/a` without real reasons) reproduces the exact bug class this step exists to prevent — a behavior that fires for the wrong actor/state, state that bleeds between actors, an unverified `false` branch.
3. **Unfalsifiable criteria.** "The page is polished / intuitive / fast." Pin it to an observation a verifier can actually check: "first error visible without scrolling", "list view issues ≤2 queries regardless of row count", "empty state shows a create CTA". Do NOT pin wall-clock numbers ("<200ms after click") — wall-clock targets are aspirational per CLAUDE.md and neither the test suite nor a static verifier can honestly assert them.
4. **Treating it as documentation.** If the criteria don't flow into v-tdd + the verifier + Step 6, the derivation was wasted. The artifact must be machine-consumed, not filed and forgotten.
5. **Spec bloat.** This is not a PRD. 5–7 criteria + the state block. If it's growing past a screen, the task is Medium/Large and belongs in `/v-new-feature`.
