# Workflow Blast-Radius (Step 1.6) — extracted from /v SKILL.md

> **Loaded by:** /v Step 1.6, after classification = bug-fix AND a UI/workflow signal is present in the task content OR the diff. Inline /v SKILL.md has a one-line stub. This is the **synchronous-workflow sibling of Step 1.5** (Async Bug Scope Explosion): Step 1.5 owns queue/event/async bugs; Step 1.6 owns user-facing-flow bugs.
>
> **Why this exists:** the bug-fix workflow normally writes a failing test for the *reported* symptom only. For UI/workflow bugs, the reported symptom is almost always one state of a flow that has many — empty, loading, error, permission-denied, concurrent, boundary, and the *sibling routes/components that share the code being changed*. Fixing only the reported state leaves the others live; the bug "comes back" next session in a different state of the same flow, or a sibling consumer of the changed code breaks silently. This is the "narrow fix → new bug / leftover sibling bug" loop. This step forces broader scope BEFORE TDD writes the test and BEFORE the browser gate exercises the flow.
>
> **Output:** `WORKFLOW_BLAST_RADIUS_<sid>.md` at project root. Feeds /v-tdd (backend-testable states) and v-workflow-verifier (browser-only states).

## Trigger signals

Fires when classification = bug-fix AND **any** of these appear in the resolved task content OR in `git diff` of the session writes, AND the async signals of Step 1.5 did NOT already claim it (a single bug can run both; they are not mutually exclusive, but a purely-async bug with no UI surface skips 1.6):

**Frontend / page signals:**
- File paths under `resources/js/Pages/`, `resources/js/Components/`, `resources/views/`, `src/pages/`, `src/app/`, `app/` (Next), `pages/`, `components/`, `*.tsx`, `*.jsx`, `*.vue`, `*.svelte`, `*.blade.php`
- Code: `useState`, `useEffect`, `useForm`, `router.`, `Inertia`, `fetch(`, `axios`, `useQuery`, `useMutation`, `onSubmit`, `onClick`, form/validation handling

**Route / controller signals:**
- File paths under `routes/`, `app/Http/Controllers/`, `app/Http/Requests/`, `app/Http/Middleware/`
- Code: route definitions, controller actions, Form Request validation, policy/`authorize(` checks

**Task-language signals:**
- "doesn't work", "broken", "nothing happens", "blank", "stuck", "can't <verb>", "wrong <noun> shows", "error when", "after I click", "the form", "the page", "the list", "the table", "filter", "sort", "pagination", "modal", "redirect", names of user flows ("checkout", "signup", "invite", "export", "settings")

**Negative filter (do NOT fire):** pure backend/CLI/library change with no route, page, controller, or component in the diff AND no UI/flow language in the task. (A pure async/queue bug routes to Step 1.5 only.)

## Trace protocol

Use Read + Grep. Do NOT estimate — every entry cites `file:line`.

### 1. Entrypoints
Where does the user enter this flow? The route(s), page(s), component(s) that start it.
- Laravel route → controller: `php artisan route:list --json` then resolve the action.
- Inertia/React page: the `Pages/` component the route renders.
- Output rows: `{ file:line, kind: route|page|component|controller }`.

### 2. Flow trace (entry → outcome)
Walk the flow from entrypoint to its observable outcome. For each hop cite `file:line` and what happens: client event → request → validation → controller/service → DB → response → client state update → rendered result. This is the spine the reported symptom sits on.

### 3. Shared dependencies (the sibling surface)
What ELSE uses the unit you are about to change? This is the step that catches the "fixed it here, broke it there" class.
- Grep for other callers of the changed function/component/route/Form Request/policy.
- Grep for other routes that hit the same controller method or service.
- Grep for other pages that render the same component.
- Output rows: `{ file:line, note: "sibling consumer — what would break if the change has wrong assumptions" }`.

### 4. State enumeration
For the affected flow, enumerate the states from the success-criteria coverage list (`empty / loading / error / slow_network / permission_denied / concurrent / double_submit`) PLUS:
- **boundary**: min/max/zero/overflow inputs, pagination first/last page, single vs many items.
- **sibling-route**: the other routes/components found in step 3 that exercise the changed code.

For each: is it `covered` (a test or guard exists), a `gap` (live, untested), or `n/a` (doesn't apply — justify). Assign a `test_layer`:
- `feature` — a backend route/HTTP test reproduces it (preferred for anything with a request/response/DB effect).
- `unit` — pure function/logic, no I/O.
- `browser` — only observable by driving the rendered UI (client-side state, rendering, focus, double-click, layout).

## Failure-mode → test-layer routing

| state | typical test_layer |
|---|---|
| empty / error / permission_denied / boundary / sibling-route | `feature` (route test: assert status, payload, side-effect count) |
| double_submit / concurrent | `feature` (two requests, assert idempotency / lock) — escalate to `integration` only if it needs real timing |
| loading / slow_network / client validation / focus / rendering | `browser` (no meaningful unit assertion — goes to v-workflow-verifier) |

Only `gap` + (`feature` | `unit`) entries feed /v-tdd. `gap` + `browser` entries feed v-workflow-verifier. `n/a` and `covered` entries generate nothing.

## Output artifact (`WORKFLOW_BLAST_RADIUS_<sid>.md`)

```yaml
workflow_blast_radius:
  session_id: "<sid>"
  reported_symptom: "<quote the user literally>"
  affected_workflow: "<user goal — e.g. 'apply a discount code at checkout'>"
  entrypoints:
    - { file: "<path:line>", kind: "<route|page|component|controller>" }
  flow_trace:
    - "<hop: file:line — what happens>"
  shared_dependencies:
    - { file: "<path:line>", note: "<sibling consumer of the changed unit>" }
  states_to_verify:
    # gap + test_layer in (feature, unit). Each becomes a failing test in /v-tdd.
    - id: WV-1
      state: "<empty|error|permission_denied|boundary|sibling-route|double_submit|concurrent>"
      scenario: "<one-line plain-English failure being tested>"
      test_layer: "<feature|unit>"
      arrange: "<state/inputs to set up>"
      act: "<request to fire / function to call>"
      assert: "<what must hold — status, payload shape, DB row count, etc.>"
  browser_only_states:
    # gap + test_layer: browser. Routed to v-workflow-verifier (Step 3.5), NOT /v-tdd.
    - { state: "<loading|slow_network|client-validation|focus|rendering>", scenario: "<...>" }
```

## Hand-off

- **/v-tdd** reads `states_to_verify` exactly like it reads Step 1.5's `failure_modes_to_test`: one failing test per entry, the fix must make ALL of them pass — not just the reported symptom.
- **v-workflow-verifier** reads `browser_only_states` (plus the success-criteria browser items) as its live exercise script.
- If `states_to_verify` is empty AND `browser_only_states` is empty (rare — the bug really is a single isolated state with no siblings), proceed with normal /v-tdd flow on the reported symptom only.

## Anti-patterns

1. **Fixing only the reported state.** "Empty filter crashes" → don't just fix empty. Trace the flow, find that the error state also renders raw JSON and the sibling `/reports` route shares the filter component — fix and test all three.
2. **Skipping the shared-dependency grep.** This is the step that prevents the new bug. "It's just this one component" is the assumption that breaks a sibling page.
3. **Estimating without grep.** Every entrypoint, hop, and sibling cites `file:line`.
4. **Routing everything to `browser`.** Most workflow states are cheaper and more durable as feature tests (real route → DB). Reserve `browser` for genuinely client-only observations.
5. **Documentation-only.** The artifact must feed v-tdd and the verifier. If you produce it then write only the reported-symptom test, the explosion was wasted.

## Relationship to Step 1.5

A bug can trip both (e.g., "clicking Subscribe sometimes double-charges" is async idempotency *and* a double_submit UI flow). When both fire, both artifacts are written; /v-tdd merges `failure_modes_to_test` + `states_to_verify` into one RED set. Neither replaces the other — 1.5 owns the queue/event lifecycle, 1.6 owns the user-facing flow surface.
