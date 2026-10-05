# Impact Analysis (Step 1.8) — extracted from /v SKILL.md

> **Loaded by:** /v Step 1.8 — runs after whichever of the preceding Step 1.5–1.7 sub-steps applied to this classification — for **every Feature (any tier), Bug Fix, and Refactor** workflow (and any other classification that ends up changing code; the Stop hook gates on code change). Inline /v SKILL.md has a one-line stub. (Behavior-preserving refactors are usually all-`no`-with-reasons; signature/behavior-changing refactors need the full enumeration.)
>
> **Why this exists:** the per-change review reasons *forward from the diff* — reviewers read the changed files. The only *backward* "who-consumes-this" traversal is the bug-fix scope-explosion (Steps 1.5/1.6). So a change can silently break a subsystem that wasn't edited: the admin report that reads the column you repurposed, the cached aggregate that's now stale, the listener that assumed the old event shape, the metric that double-counts. **A diff-scoped reviewer cannot see a consumer that wasn't changed.** This step forces a domain-aware enumeration of the connected subsystems BEFORE work is done, so "I didn't think about admin / reporting / cache" becomes impossible.
>
> **Output:** `IMPACT_MAP_<sid>.md` at project root. Feeds /v-tdd (consumer tests), v-workflow-verifier (admin/UI consumers), and Step 5 agent review (consumer-side scope).

## Design: cheap triage → targeted deep-dive (NOT analyze-everything)

The cost trap is "trace every subsystem deeply on every change." Avoid it. The shape is:

1. **Triage (cheap, always):** identify the **changed units** (models, columns, events, endpoints, components, cache keys), then for each subsystem run a fast grep to decide `impacted: yes|no`. Most changes light up 0–2 subsystems; the rest are `no` with a one-line reason.
2. **Deep-dive (only the lit-up ones):** for each `impacted: yes`, grep the actual consumers (`file:line`) and route each to a verification — a test, a browser exercise, or consumer-side review.
3. **Route:** `tests_to_add` → /v-tdd; `browser_to_verify` → v-workflow-verifier; `reviewer_scope` → Step 5; `unresolved` (backfill/ops) → surfaced, not silently dropped.

A subsystem marked `no` MUST carry a reason (e.g., `reporting_metrics: no — change is a UI label, touches no persisted/aggregated data`). Empty/blank is not allowed — the enumeration is the point.

## Relationship to Steps 1.5 / 1.6 (no duplication)

Impact Analysis is the **umbrella triage**; 1.5 and 1.6 are deep-dives for two specific domains:
- If `async_jobs` or `notification_emails` is impacted AND `ASYNC_LIFECYCLE_TRACE_<sid>.md` exists (Step 1.5 ran), reference it — do NOT re-trace. If 1.5 did NOT run (e.g., this is a *feature* — 1.5 is bug-fix-only) but the row is impacted, enumerate the job/listener/mailable consumers here and route them to feature tests (you don't need the full lifecycle trace, just the consumer list + assertions).
- If `functional_flow` is impacted AND `WORKFLOW_BLAST_RADIUS_<sid>.md` exists (Step 1.6 ran), reference it. Otherwise enumerate sibling routes/components here.

## Changed-unit identification (do this first)

From the diff (bug-fix/refactor — the code exists) or the plan/intent (new feature — no diff exists at Step 1.8 yet; this triage is predictive and gets **reconciled against the actual diff at Step 6.2.6** after implementation), list the **units** other code depends on:
- **Models / columns**: which tables, which columns, and did the *meaning* of a value change (not just add a column)? Semantic changes are the dangerous ones.
- **Events / their payloads**: emitted events whose shape or timing changed.
- **Endpoints / response shapes**: routes whose contract changed.
- **Components / props**: shared UI whose interface changed.
- **Cache keys / cached values**: data that is cached anywhere.
Cite `file:line`. These units are the search terms for the per-subsystem greps below.

## OWNS contract capture (advisory — do this alongside changed-unit identification)

Wave/parallel prompts often declare an ownership contract — an **"OWNS (only edit these):"**
bullet list (and a "MUST NOT TOUCH" list). Forensic A-7 (2026-06-04): two Wave-H sessions
shipped production edits outside their OWNS lists (H-5: an API-client class and its exception class;
H-7: a sync-complete notification and an admin controller) with **no record
anywhere** — the drift surfaced only in a post-hoc forensic diff. Capture the contract now so
Step 6.2.6 can reconcile it:

1. **At Step 1.8 (here):** if the prompt declares an OWNS list, copy its bullet lines (only
   the OWNS block — NOT the "MUST NOT TOUCH" lines) verbatim to
   `.v/tmp/owns-${CLAUDE_SESSION_ID}.txt`. Raw bullets are fine — the checker normalizes
   `` - `app/X.php` (note) `` → `app/X.php`. No OWNS list in the prompt → skip; record
   `owns_contract: not-declared` in the IMPACT_MAP.
2. **At Step 6.2.6 (diff reconciliation):** run
   `bash "${CLAUDE_SKILL_DIR}/references/v-owns-check.sh" "$CLAUDE_SESSION_ID" --owns ".v/tmp/owns-${CLAUDE_SESSION_ID}.txt"`
   (it derives the changed set from the session-writes logs + commit witness — it deliberately
   never uses a shared `base..HEAD` window, which would count sibling sessions' commits).
   Append the result to the IMPACT_MAP as line-start keys:

   ```yaml
   owns_contract: pass | drift | unverifiable | not-declared
   owns_drift_files:        # only when drift — one per file the checker listed
     - app/Services/ApiClient.php
   ```

3. **ADVISORY ONLY — never gate.** Test files, mandated CHANGELOG/version bumps, and
   review-fix collateral legitimately land outside OWNS (built-in allowances cover tests +
   bookkeeping + CHANGELOG.md/readme.txt). `drift` means: name the files in the IMPACT_MAP and
   route them into `reviewer_scope` (a file you weren't contracted to touch deserves
   consumer-side review) — it is NOT a completion blocker, and exit code 3 from the checker
   must not fail any gate.

## Subsystem checklist (triage every row; deep-dive the `yes` rows)

For each, the grep is the cheap triage signal (Laravel-centric; adapt the paths to the detected stack — Next/Rails/Django equivalents in parentheses).

### 1. Functional related flow
Sibling routes/pages/components that share the changed unit. Defer to `WORKFLOW_BLAST_RADIUS` if it ran.
- Grep: other callers of the changed function/route/component/Form Request/policy.

### 2. Downstream reporting / metrics / analytics
Aggregations, dashboards, scheduled reports, and analytics events that read the changed data — the place where a semantic change produces *wrong numbers* with no error.
- Grep: `<Model>` / `<column>` inside `sum(`, `count(`, `avg(`, `groupBy(`, `selectRaw(`, report/export classes, `app/Reports`, dashboard components; analytics: `track(`, `Analytics::`, event-name constants, the analytics schema registry.
- Deep-dive: a feature test that asserts the **report/aggregate value** is still correct after the change (not just that the query runs).

### 3. Admin functionality
Admin panels/screens that read or mutate the same models — usually under-tested and invisible to a diff-scoped review.
- Grep (Laravel/Filament/Nova): `app/Filament`, `app/Nova`, `app/Http/Controllers/Admin`, `routes/admin*.php`, `resources/js/Pages/Admin`; (Rails: `app/admin`, ActiveAdmin; Django: `admin.py`).
- Deep-dive: feature test on the admin endpoint, OR a `browser_to_verify` entry (admin flow driven by v-workflow-verifier) if it's UI.

### 4. Async jobs
Jobs/listeners/observers that process the changed data or react to the changed event. Defer to `ASYNC_LIFECYCLE_TRACE` if it ran.
- Grep: `app/Jobs`, `app/Listeners`, `app/Observers`, `implements ShouldQueue`, `dispatch(`, event listeners for the changed event; (Sidekiq/Celery/BullMQ equivalents).
- Deep-dive: feature test asserting the job/listener still handles the new shape (idempotency/payload).

### 5. Notification emails / messages
Mailables/notifications triggered by, or containing, the changed data.
- Grep: `app/Mail`, `app/Notifications`, `Mail::`, `Notification::send`, `->notify(`; the changed field used in a mail/notification template (`resources/views/mail`, notification `toMail`).
- Deep-dive: feature test asserting the mailable is queued with correct content / the field renders.

### 6. Cache invalidation
Cached values **derived from** the changed data. The classic bug: a write path updates the source but not the cache → stale reads.
- Grep: `Cache::remember`, `Cache::put`, `Cache::get`, cache-key strings referencing the changed model/id, `Cache::tags`, `->remember(`; model-level cache traits.
- Deep-dive: feature test — mutate the source, assert the cached read reflects it (or that invalidation fires). A `no` here must confirm the data isn't cached anywhere.

### 7. Database data integrity / accuracy
Constraints, FKs, uniqueness, derived/denormalized columns, aggregates/counters, soft-delete cascades, and **existing-row backfill** needs when a column's meaning changes or a NOT NULL/derived column is added.
- Grep: migrations touching the table, `->foreign(`, `unique(`, denormalized counters (`*_count`, `cached_*`), `withCount`, DB triggers/generated columns; check existing rows need a backfill.
- Deep-dive: the pre-flight migration-rollback + seeder gates cover schema reversibility; ADD a feature test for the integrity rule (e.g., uniqueness rejected, counter stays consistent). Backfill needs go to `unresolved` (a migration/ops action, not a test).

### 8. API contract / external consumers
If the changed data is exposed via an API resource, public endpoint, or webhook payload, external consumers can break.
- Grep: `app/Http/Resources`, `routes/api.php`, API controllers, `toArray(`, webhook payload builders, `tests/Contracts`.
- Deep-dive: contract test (or `tests/Contracts`) asserting the response shape is unchanged / versioned.

### 9. Authorization / policies
If the change affects who can see or do what (new field exposure, new endpoint, changed ownership).
- Grep: `app/Policies`, `Gate::`, `->can(`, `authorize(`, `@can`, middleware on the route.
- Deep-dive: feature test — the wrong user/role is denied; the field isn't leaked to unauthorized users.

## Output artifact (`IMPACT_MAP_<sid>.md`)

### ⛔ STOP — format contract (the Stop hook anchors on BARE line-start keys)

**Deterministic seed (avoids the format bounce):** start from the canonical skeleton —
`bash "${CLAUDE_SKILL_DIR}/references/v-artifact-skeleton.sh" --type impact_map --sid "$CLAUDE_SESSION_ID" > "IMPACT_MAP_${CLAUDE_SESSION_ID}.md"` — then fill ONLY the substance
(`impacted` / `reason` / `consumers`). It emits the `subsystems:` line and all nine line-start
keys exactly as `validate_impact_map_semantics` requires, so the structural anchors can never
drift. Round-tripped against the real validator by `references/v-artifact-skeleton-test.sh`.

Write the YAML block below — it's the richest form (carries `consumers` + `verification` per
subsystem, which /v-tdd and the reviewers consume). The Stop hook (`check-review-artifact.sh` →
`validate_impact_map_semantics`) requires each subsystem key — `subsystems`, `reporting_metrics`,
`cache_invalidation`, `db_integrity` — to appear at **line start** (after optional `#`/`|`/space)
followed by `:` or `|`. As of W-perf8 a **Markdown triage table is ALSO accepted** (each key as
the first cell of its row), because a table enumerates the subsystems just as well — that was
real friction: two prod sessions wrote a valid table and got bounced, then
thrashed re-formatting. Prefer the YAML form; reach for a table only if you must.

```text
WRONG (still bounces — key not at line start / no key line at all):
  ### reporting_metrics                    ← heading prefix `###` + no trailing ":" or "|"
  (a prose paragraph that merely mentions reporting_metrics)   ← key not at line start
  (omitting any of the three required subsystem keys entirely)

RIGHT — form A, YAML (preferred; bare `key:` at line start, leading indent is fine):
  subsystems:
    reporting_metrics:  { impacted: no, reason: "…" }
    cache_invalidation: { impacted: no, reason: "…" }
    db_integrity:       { impacted: no, reason: "…" }

RIGHT — form B, Markdown table (accepted; each key is the first cell of its row):
  | subsystem          | impacted | reason |
  |--------------------|----------|--------|
  | reporting_metrics  | no       | …      |
  | cache_invalidation | no       | …      |
  | db_integrity       | yes      | adds a migration |
```

```yaml
impact_map:
  session_id: "<sid>"
  classification: "<feature-tiny|feature-small|feature-medium|feature-large|bug-fix>"
  change_summary: "<one line: what changed>"
  changed_units:
    - { unit: "<Model.column | EventClass | METHOD /route | Component prop | cache:key>", file: "<path:line>", semantic_change: <yes|no> }
  subsystems:
    functional_flow:    { impacted: <yes|no>, reason: "<...>", consumers: ["<file:line>"], verification: "<WORKFLOW_BLAST_RADIUS | feature-test | browser>" }
    reporting_metrics:  { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<feature-test:assert-value | reviewer>" }
    admin:              { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<feature-test | browser | reviewer>" }
    async_jobs:         { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<ASYNC_LIFECYCLE_TRACE | feature-test>" }
    notification_emails:{ impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<feature-test:assert-mail | reviewer>" }
    cache_invalidation: { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<feature-test:write-then-read | reviewer>" }
    db_integrity:       { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<migration-gate | feature-test:constraint | backfill→unresolved>" }
    api_contract:       { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<contract-test | reviewer>" }
    authorization:      { impacted: <yes|no>, reason: "<...>", consumers: [...], verification: "<feature-test:deny | reviewer>" }
  tests_to_add:        # feeds /v-tdd — one per impacted subsystem that's feature/unit-testable
    - { subsystem: "<name>", scenario: "<one line>", test_layer: "<feature|unit>", arrange: "<...>", act: "<...>", assert: "<...>" }
  browser_to_verify:   # feeds v-workflow-verifier (e.g., admin UI consumers)
    - { subsystem: "<name>", scenario: "<...>" }
  reviewer_scope:      # feeds Step 5 consumer-side review — files NOT in the diff that must be checked against the change
    - "<file:line>"
  unresolved:          # impacts needing a migration/backfill/ops action, not a test — surfaced, never dropped
    - "<e.g. 'existing N rows need backfill for repurposed status column'>"
```

## Hand-off

- **/v-tdd** reads `tests_to_add` (same mechanism as `failure_modes_to_test` / `states_to_verify`): one failing test per entry; the fix must satisfy all.
- **v-workflow-verifier** reads `browser_to_verify` (e.g., admin screens) and adds them to the live exercise.
- **Step 5 agent review** reads `reviewer_scope`: those consumer files are ADDED to the review scope so the reviewers judge them against the change — the consumer-side review the diff-scoped pass would otherwise miss.
- **`unresolved`** items are surfaced in Step 7 (e.g., "backfill required") so an ops/migration follow-up isn't forgotten.
- If EVERY subsystem is `no` (genuinely isolated change), `tests_to_add`/`reviewer_scope` are empty and the pipeline proceeds normally — but the enumeration is recorded, so the decision was explicit, not skipped.

## Anti-patterns

1. **Blank `no` rows.** Every `no` needs a one-line reason. A blank row means you didn't check — which is the exact failure this step prevents.
2. **Analyze-everything.** Don't deep-trace subsystems the triage grep didn't light up. Triage is cheap; deep-dive only the `yes` rows.
3. **Documentation-only.** `tests_to_add` / `reviewer_scope` / `browser_to_verify` MUST flow into v-tdd / Step 5 / the verifier. An IMPACT_MAP that's filed and not consumed was wasted.
4. **Missing the semantic change.** Adding a column is usually low-impact; *repurposing* a column's meaning silently breaks every reader. Flag `semantic_change: yes` and treat reporting/cache/integrity as likely-impacted.
5. **Forgetting backfill.** A new derived/NOT-NULL column or a repurposed value usually needs existing rows backfilled. That's an `unresolved` item, not just a test.
