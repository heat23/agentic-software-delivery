# Plan Templates — v-plan

Copy-paste templates and reference checklists extracted from `SKILL.md` for progressive disclosure.
Read the relevant section when that step of the workflow runs. The **decision logic** (when to emit an
ADR, session dependency rules, when a SaaS concern applies) stays in `SKILL.md`; this file holds the
**output shapes** those decisions produce.

_Last reviewed: 2026-07-05_

---

## ADR Template (Architecture Decision Records)

Emit this block into the PLAN only when the decision clears the **3-of-3 gate** documented in
`SKILL.md § Architecture Decision Records (ADR)`. This file holds only the shape.

```markdown
## ADR: [Decision Title]
status: proposed
date: [ISO date]
context: |
  [Why this decision needs to be made]
options:
  1. [Option A] — [pros] / [cons]
  2. [Option B] — [pros] / [cons]
  3. [Option C] — [pros] / [cons]
decision: [Chosen option]
rationale: |
  [Why this option was selected]
consequences: |
  [What changes as a result, including trade-offs accepted]
```

**Durable ADR routing (required alongside the PLAN copy):** `PLAN_*.md` is an ephemeral, session-scoped
artifact — an ADR that lives only there is lost once the plan file is cleaned up or the session ends.
When an ADR is generated, also persist it where future AI sessions will actually read it:
1. If the project already has `{repo}/docs/adr/` (or an equivalent ADR log referenced from its
   CLAUDE.md), append a new `docs/adr/ADR-<NNNN>-<slug>.md` file there using the same fields as the PLAN
   section, incrementing `<NNNN>` from the highest existing ADR number (`0001` if none exist).
2. Otherwise, append the ADR (same fields) as a dated entry under an `## Architecture Decisions` section
   in the project's `CLAUDE.md` (create the section if absent) — CLAUDE.md is read at the start of every
   session, so the decision survives.
3. Note the durable location (`docs/adr/ADR-NNNN-slug.md` or an `## Architecture Decisions` section in the project's `CLAUDE.md`) in the
   PLAN's ADR section so a reader knows where the canonical copy lives.

---

## Session Assignment — Layer Groupings by Route

Group tasks into sessions using these architectural layer groupings (adapt based on route and the file
dependency graph computed in `SKILL.md § Build the File Dependency Graph`):

**Route 1 (New Product):**
1. **Foundation session** — Schema, models, migrations, seeders
2. **Backend session** — Services, jobs, API endpoints, policies
3. **Frontend session** — Pages, components, layouts
4. **Integration session** — External APIs, payments, AI features (security-bearing — see the
   security clause below)
5. **Polish session** — Tests, error handling, edge cases

**Route 3 (Specific Feature):**
1. **Backend session** — Models, migrations, services, controllers, form requests
2. **Frontend session** — Pages, components, Inertia props
3. **Testing session** — Feature tests, unit tests, browser tests

**Route 4 (Refactor/Improve):**
- Delegate to `/v-audit-code` which has its own prompt generation (absorbed `/v-refactor` 2026-07-06; see `v-audit-code/references/refactor-modernization.md` for the deep debt-trend/SaaS-arch analysis)

**Route 5 (Growth Planning):**
1. **Measurement session** — Analytics events, tracking, dashboards
2. **Experiment session** — A/B test implementations, feature flags
3. **Optimization session** — Funnel fixes, CRO changes

---

## Write Individual Prompt Files — File Formats

Create a directory `.v-prompt-packs/v-plan-<MM-DD>/` in the project workspace (where `<MM-DD>` is the
current month-day per the unified prompt-pack convention in
`~/.claude/skills/references/v-core-prompt-pack.md`). Write one `.txt` wave pack per session, plus a
single `00-README.md` map, per the shared wave form in
`~/.claude/skills/references/v-runnable-pack-convention.md` (the same shape every other producer emits —
the older `NN-<layer>.md` per-session naming is retired):

```
.v-prompt-packs/v-plan-<MM-DD>/
  00-README.md              ← Overview, session/wave map, dependency notes (the only .md)
  foundation.txt            ← wave 0 (no prefix): schema + models — the first, foundational session
  w1-backend.txt            ← wave 1: services + API (depends on foundation)
  w2-frontend.txt           ← wave 2: pages + components (depends on backend)
  ...
  w<N>-pre-flight.txt       ← closing wave (read-only): project's full quality gates
  w<N>-review.txt           ← closing wave (read-only, parallel with pre-flight): adversarial/second-opinion review
  w<N+1>-hardening.txt      ← sequential: triages findings, fixes CRITICAL/HIGH, re-runs gates, /v-verify-done
  99-verify.txt             ← always last: re-asserts every wave landed
```

**Session → wave mapping.** The session ordering computed in `SKILL.md § Assign Sessions` is already
dependency-ordered (foundation before backend before frontend, etc.), so the default mapping is
positional: the first session is wave 0 (no filename prefix — it runs first, alone), the second session
is `w1-`, the third `w2-`, and so on. Two sessions may share a wave only if they are provably independent
(disjoint file sets, neither depends on the other's output) — apply the same conflict/dependency test as
`SKILL.md § Build the File Dependency Graph`. Route 4 (Refactor) has no sessions here — it delegates
entirely to `/v-audit-code`, which emits its own wave pack.

**Closing waves (always append, per `v-runnable-pack-convention.md` § Closing waves).** After the last
implementation session's wave, append: a parallel READ-ONLY verification wave at the next wave number —
`w<N>-pre-flight.txt` (runs the project's full quality gates) + `w<N>-review.txt` (dispatches the
adversarial/second-opinion reviewer agents, plus a framework-pitfall reviewer only when the plan's diff
touches queues/listeners/signature-verification/cache-keys) — then a single sequential
`w<N+1>-hardening.txt` (triages findings, fixes CRITICAL/HIGH, re-runs gates, runs `/v-verify-done`, walks
the acceptance criteria), then `99-verify.txt` last. The two verification packs use `## Goal` / `## Checks`
/ `## Acceptance` and OMIT `## Files`/`## Tests` and the "leave staged" line — they never edit source.
Reflect these in the 00-README.md wave-map table like every other wave.

**00-README.md** must include:
- Project name, plan date, route used, total tasks, estimated total hours
- Wave map table: `| Wave | File | Layer | Tasks | Est. Hours | Depends on |`
- Dependencies between waves (foundation before backend, backend before frontend typically)
- ADR summary if the plan includes architecture decisions
- Post-merge quality gate commands from CLAUDE.md

**Each pack (`foundation.txt`, `w1-backend.txt`, etc.)** contains ONLY the prompt — the entire file is
what gets pasted into a new session. It MUST carry the body schema in this exact order (the literal
`## Files` H2 is REQUIRED — `/v-build`'s scope guard keys on it):

```
/v Implement the following tasks for [Project Name].

## Goal
[1-3 sentences: what this session delivers and why, tied to its layer/role in the plan]

## Context
[The specific plan decisions this session implements, inlined with concrete detail (exact fields,
endpoints, component names) — file:line evidence where the codebase already has related code.
NO reference to the PLAN artifact, 00-README, or a sibling session file — inline everything needed.]
Tech stack: [brief tech stack from orientation].
Layer: [Foundation / Backend / Frontend / Integration / Polish]

## Files
[Every file this session creates/modifies, one per line, with what changes — aggregated across every
task below. This is the load-bearing section v-build's scope guard reads.]

## Changes
Work through these in order. For each task: write a failing test first (TDD), implement the code,
verify the test passes, then move to the next.

### Task 1: [Title] (Xh est.)
**Dependencies:** [what must exist first — models, migrations, etc.]
**Implementation:** [specific changes — for models include exact fields and relationships; for
controllers include exact actions and form request rules; for pages include exact props and component
structure]

### Task 2: [Title] (Xh est.)
...

## Acceptance criteria
- [ ] [from the plan, one checkbox per observable done-condition]

## Tests
[Exact TDD test cases per task — the implementing agent writes these first]

## Constraints
Read the project's CLAUDE.md first for architecture context, conventions, and quality gate commands.
[Any project guardrail that applies — hard-delete, tenant isolation, framework version.]
[If this session's ## Files touches request signing/HMAC/webhook or signature verification, credential/
secret handling, host/URL construction from variables, auth/authz decisions, or payment flows (this is
the common case for a Route 1 Integration session): "This pack touches security-bearing code — dispatch
an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your
own diff before finishing; fix CRITICAL/HIGH in-session."]

## Dependencies
Wave [N]. Requires: [prior wave's session name, or "none" for wave 0].

Run the full verification suite after all tasks:
[project-specific quality gate commands from CLAUDE.md]

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

**Prompt writing rules:**
- Start with `/v` so the orchestrator routes automatically
- Every task must include TDD test cases — the implementing agent writes tests first
- Completely self-contained — no references to other session files, the PLAN artifact, or 00-README
- Backend sessions include exact model fields, relationships, form request rules, and controller actions
- Frontend sessions include exact Inertia props, component structure, and route names
- Include acceptance criteria from the plan so the implementing agent knows when it's done
- End with the exact phrase "leave all changes staged; do NOT commit" (a test checks this literal phrase)

---

## Prompt-Pack Self-Validation

After writing the tree (inline, via the Write tool — this is not dispatched), self-validate before the
completion banner. This is the same detection `run-v-packs` and `/v-build`'s scope guard use, so passing
it proves the pack will run and resolve waves as intended:

```bash
PROMPT_DIR=".v-prompt-packs/v-plan-$(date +%m-%d)"   # substitute the actual dated dir
"$HOME/.claude/scripts/validate-audit-prompt-packs.sh" "$PROMPT_DIR"
run-v-packs "$PROMPT_DIR" --dry-run   # confirm packs= and waves=[…] match the assigned session order
```

On failure, regenerate the offending file(s) once, then re-check; if it still fails, note
`prompt_pack: degraded` in the completion banner rather than claiming a clean pack. Also re-confirm by
hand: no two packs sharing the same wave prefix name the same target file, and every implementation pack
ends with "leave all changes staged; do NOT commit" (the exact phrase a test checks).

---

## SaaS Concerns Checklist (Required for Routes 1, 3, 5)

After the technical breakdown and before writing the final plan, evaluate every planned feature against
these SaaS-critical dimensions. Document each as "Required", "Not applicable", or "Deferred (reason)" in
the plan under a `## SaaS Concerns` section.

| Concern | Key Question | If Required |
|---------|-------------|-------------|
| **Tenant isolation** | Does this feature query, display, or mutate data that belongs to a specific team/organization? | Add tenant scoping to every query. Document which model scopes apply. Plan tests verifying cross-tenant data is invisible. |
| **Billing/subscription gating** | Should this feature be restricted by plan tier, usage limits, or subscription status? | Specify which plans get access. Define behavior for expired/cancelled/trial states. Plan middleware or gate check placement. |
| **RBAC/permissions** | Who can access this feature? Are there different permission levels (viewer, editor, admin, owner)? | Define required permissions per action. Plan policy/gate classes. Include authorization tests in test plan. |
| **Onboarding relevance** | Is this a feature new users need to discover or configure during setup? | Add to onboarding checklist/wizard. Plan empty states that guide toward first use. Consider progressive disclosure. |
| **Analytics instrumentation** | What user actions should be tracked for product decisions? | Define events with payloads (e.g., `feature_used`, `upgrade_prompt_shown`). Specify where tracking calls go. |
| **Rate limiting** | Can this feature be abused (API endpoints, form submissions, resource creation)? | Specify rate limit values per plan tier. Plan 429 response handling in UI. |
| **Audit logging** | Do actions on this feature need to be traceable for compliance or debugging? | Specify which actions log and what payload they capture. Plan audit trail query interface if needed. |
| **Webhook/integration exposure** | Should external systems be notified when this feature's data changes? | Design webhook event schema. Plan idempotency and retry behavior. |

**When to skip:** Quick-sketch depth plans and Route 2 (Understand Codebase) don't need the full checklist. Route 4 (Refactor) needs it only if the refactor changes data access patterns or permission boundaries.

**How this integrates with existing plan sections:**
- Tenant isolation findings feed into `## Files` (add scopes) and `## Tests Required` (add isolation tests)
- Billing gating feeds into `## Acceptance Criteria` (plan-tier behavior) and effort estimates (+0.5-1h per gated feature)
- RBAC feeds into `## Tests Required` (authorization tests) and `## Files` (policy classes)
- Analytics feeds into `## Instrumentation` section (already in PLAN_SCHEMA via `_v-growth.md`)

---

## API Design Step (Required When Feature Exposes Data or Actions)

For features that create, modify, or expose data through HTTP endpoints — especially those that external
clients, mobile apps, or integrations might consume:

1. **Endpoint design:** REST resource naming, HTTP methods, URL structure
2. **Request/response schemas:** Required fields, optional fields, validation rules, response envelope format
3. **Authentication:** Which endpoints need auth? API key vs session vs OAuth?
4. **Rate limiting:** Per-endpoint limits, plan-tier differentiation
5. **Versioning:** Is this a new API surface that needs version prefixing?
6. **Error responses:** Consistent error format with machine-readable codes
7. **Webhook events:** If the feature mutates state, should it emit webhook events?

Add API design notes to the `## Files` section (new controller/route entries) and `## Acceptance Criteria` (API contract tests).
