# Boundaries Lens — Dimension Protocol

> Loaded on-demand by `v-bug-hunt` when `--lens=boundaries` (or an equivalent trigger) is
> selected. This reference carries the full boundary-condition probe protocol that was
> `v-edge-hunt`'s SKILL.md body before the 2026-07-05 merge (v-edge-hunt archived to
> `~/.claude/archive/skills-merged-2026-07-05/`). The `bugs` lens (this skill's original
> 8-dimension behavioral-defect protocol) stays inline in `SKILL.md`; this file exists so the
> two ~700-line bodies are never stacked into one oversized SKILL.md.

## When this lens applies

Boundary-condition audit: empty/null/zero inputs, max-value overflow, time/DST/leap/timezone
edges, currency rounding, unicode/emoji/RTL, pagination off-by-one, state-machine invalid
transitions, concurrent races, and plan-limit/entitlement boundaries. This is the narrower,
deeper companion to the `bugs` lens — it finds the edges that pass the happy path (bugs lens
territory) but break the moment a real user with an emoji name, a Feb 29 birthday, or a 0-day
proration period hits the surface.

**Quality bar:** every finding must name a specific edge condition + cite the code/test that
fails to handle it + propose a concrete fix. Generic findings ("validate inputs more
carefully") are auto-dropped at Verification Gate 1.

## Depth tiers (boundaries lens — distinct from the bugs lens table)

```yaml
question: "How deep should this boundaries-lens hunt go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Quick — for iteration"
    description: "EHUNT-EMPTY + EHUNT-LIMIT only. ~8 min."
  - label: "Standard — recommended default"
    description: "EHUNT-EMPTY + EHUNT-LIMIT + EHUNT-TIME + EHUNT-MONEY + EHUNT-ENTITLEMENT (both if billing/Cashier touched) + EHUNT-QUANTITY. ~20 min."
  - label: "Thorough — pre-launch / pre-merge"
    description: "All 9 dimensions, parallel subagents. ~32 min."
```

## Dispatch model

Same mechanics as the bugs lens: dispatch each depth-selected dimension as a parallel
fork-safe `claude -p` subprocess (`~/.claude/skills/v/references/v-dispatch-subagent.sh
--model sonnet --mode capture` — NOT the Agent tool, which fails silently from `context:
fork`), each pinned to `sonnet` (sonnet-max policy) and instructed in its briefing file to use extended thinking
before probing. Boundary/adversarial reasoning (DST double-fire, proration-to-Stripe-minimum,
state-machine invalid transitions) is exactly where the strongest available reasoning model
materially outperforms — do not leave these unpinned.

## Stack detection

Read `composer.json` and `package.json` (same Step 0 detection as the bugs lens). The
dimension probes below are written for **Laravel + React/Inertia + Pest + Cashier/Stripe** —
adapt as follows when another stack is detected:

| Detected stack | Adaptation |
|---|---|
| Laravel + Pest | All probes apply as written |
| Laravel + PHPUnit | Replace `pest-test` evidence snippets with PHPUnit equivalents |
| Laravel without Cashier | Skip `EHUNT-MONEY` Cashier-specific checks; probe general money math instead |
| Non-Laravel PHP | Replace Eloquent/Form Request/Carbon references with your framework's equivalents |
| Non-PHP backend | Replace PHP probe patterns; keep dimension logic (empty/limit/time/money/unicode/etc.) |

When Laravel + Cashier is detected: Eloquent models + Form Requests for billing, Carbon for
date/time (DST + timezone helpers), Inertia for page rendering, Pest 3.x+ dataset()-driven
(table-based, NOT property-based) boundary coverage, Stripe as payment provider.

## Dimension 1 — Empty / Null / Zero Inputs (`EHUNT-EMPTY`)

**Probe:** every input boundary that could be empty in production: empty arrays in
collections, null on optional fields with downstream calls, zero counts in
billing/pagination, empty strings in user content, no-results states.

**Concrete checks:**
- `foreach` over a collection that could be empty — does the code emit a "no results" empty
  state, or does it produce a blank section?
- Optional FK columns (nullable in migrations) — does the consumer code handle `null`, or
  does it `->method()` on null?
- Zero-amount transactions (zero-dollar invoices, zero-day proration) — does Cashier handle
  this without throwing?
- Empty string in `User->name`, `User->email`, profile bio — what does the rendered UI show?
- Empty array of items in a cart, an order, a subscription — does the controller short-circuit
  or proceed to a broken state?

**Evidence form:** failing Pest test (`it('handles empty <X> without crashing', ...)`) + code
citation `path:line`.

## Dimension 2 — Max / Limit / Overflow (`EHUNT-LIMIT`)

**Probe:** every input boundary at the upper end: DB column max length, validation `max:N`
rules, integer overflow, file-upload size, max array size, max query result count.

**Concrete checks:**
- VARCHAR(255) columns receiving 256+ chars — does the Form Request validation catch it, or
  does it hit a DB error?
- Integer columns with values approaching PHP_INT_MAX or JavaScript's Number.MAX_SAFE_INTEGER
  (especially for IDs serialized to JSON).
- Validation `max:65535` on text fields that could legitimately exceed (long-form blog
  content, custom field bodies).
- File upload size at exactly the configured max and just above — does the response degrade
  gracefully?
- Unbounded list endpoints — what happens at 10k, 100k, 1M records?

**Evidence form:** failing Pest test asserting graceful 422 or proper degradation + code
citation.

## Dimension 3 — Date / Time / Timezone / DST / Leap (`EHUNT-TIME`)

**Probe:** every date/time boundary: DST forward/backward transitions, leap year (Feb 29),
timezone boundaries between user and server, Carbon arithmetic over month/year boundaries,
scheduled-job timing edges.

**Concrete checks:**
- DST transitions in scheduled jobs (cron at 2:30 AM on the day clocks "fall back" — runs
  twice; "spring forward" — runs zero times).
- Leap year: Feb 29 birthdays + anniversary computations + subscription anchor dates.
- Timezone boundaries: user in NZ creates a record at local-midnight; server (UTC) sees it as
  previous day. Does the day-grouping logic produce surprising results?
- Carbon `addMonth()` on Jan 31 (lands on Mar 3 or Feb 28 — both surprise depending on
  intent).
- Future-dated subscriptions at edge dates (created on Feb 29 in a leap year).
- Cron expressions that have ambiguous semantics during DST (e.g., `30 2 * * *` is ambiguous
  twice a year).

**Evidence form:** failing Pest test with `Carbon::setTestNow(...)` set to the edge date +
code citation.

## Dimension 4 — Currency / Money / Cashier Proration (`EHUNT-MONEY`)

**Probe:** Cashier-specific + general money edges. Currency rounding, multi-currency,
proration at zero/max, refund edge cases, Stripe minimum amounts.

**Concrete checks:**
- Stripe minimum charge (50 cents USD, varies per currency) — does the upgrade flow validate
  the prorated amount won't fall below minimum?
- Proration with 0 days prorated (mid-day upgrade on plan-anchor day) — what's the invoice
  line item?
- Multi-currency (USD has 2 decimal places, JPY has 0) — does the code use integer-cents
  consistently?
- Refund amount > original charge (partial-refund stacking bug).
- Currency mismatch between cart, subscription, and customer default currency.
- Very small amounts (one or five cents) — does dunning logic handle these or treat them as
  "negligible"?
- Very large amounts approaching Stripe's per-charge max.

**Evidence form:** failing Pest test using Stripe sandbox or Cashier mock + code citation.

## Dimension 5 — Unicode / Emoji / RTL / Multibyte (`EHUNT-UNICODE`)

**Probe:** every user-input field that flows to UI, DB, email, or external API.
Unicode/emoji handling, RTL layouts, combining characters, NFC/NFD normalization, multibyte at
length boundaries.

**Concrete checks:**
- Emoji in `User->name`, business name, post title — does the email render? Does the URL slug
  generator handle it?
- RTL languages (Arabic, Hebrew) in mixed-script contexts — does the layout break?
- Combining characters in passwords (`é` as `e + ́` vs single codepoint) — does login compare
  correctly?
- Surrogate pairs in JS `String.length` vs PHP `mb_strlen` — does a "max 50 chars" UI counter
  match the server validation?
- NFC vs NFD normalization in unique constraints — can two visually-identical user names both
  register?
- Zero-width joiner sequences in emoji (family emoji as multiple codepoints).

**Evidence form:** failing Pest test with explicit unicode test inputs + code citation.

## Dimension 6 — Pagination / Sorting / Pluralization (`EHUNT-QUANTITY`)

**Probe:** quantity-related edges on list endpoints + UI copy that varies by count.

**Concrete checks:**
- Exactly-page-size results (last page has exactly N items) — does the "next page" button
  correctly disable?
- `page=0` vs `page=1` indexing in URL — does the controller normalize? Does the UI link
  generator?
- Page beyond max — does the response 404, 200-with-empty, or 422?
- 0 / 1 / N pluralization in copy ("1 file" vs "0 files" vs "2 files") — does the React
  component use a proper intl helper, or does it `{count} files` regardless?
- Empty page handling — does the UI show an empty state, a "no results" message, or just
  whitespace?
- Sort key that allows arbitrary user input — what if it's NULL on the sorted column?

**Evidence form:** failing Pest feature test + code citation (controller + Inertia page
component).

## Dimension 7 — State Machine / Invalid Transitions (`EHUNT-STATE`)

**Probe:** state machines (subscriptions, orders, jobs) for invalid transitions,
terminal-state mutations, concurrent state changes.

**Concrete checks:**
- Subscription state machine. Stripe ships **8 statuses**
  (https://stripe.com/docs/api/subscriptions/object#subscription_object-status): `trialing`,
  `active`, `past_due`, `canceled`, `incomplete`, `incomplete_expired`, `unpaid`, `paused`. The
  `incomplete` + `incomplete_expired` states are the highest-leverage edges — most controllers
  only code the happy 4-state path. Probe: (a) can a subscription stuck in `incomplete` for
  >23 hours auto-transition to `incomplete_expired` without the consumer noticing? (b) what
  does the UI show when a subscription is `paused`? (c) does `unpaid` gate access correctly,
  or does the access check only look at `active|trialing`? Also probe terminal-state
  transitions: can a webhook arrive that transitions from `canceled → active`? (Stripe can —
  for resubscribes.)
- Terminal-state mutations: canceled subscription receives a payment webhook — what does the
  controller do?
- Concurrent state changes: two webhooks for the same subscription arrive simultaneously —
  does the DB enforce ordering via lock or version?
- User-initiated cancel while a billing-cycle webhook is in-flight — race condition between
  optimistic UI update and webhook resolution.
- Soft-delete with FK constraint where children still exist — does the code attempt the
  delete and crash, or check first?

**Evidence form:** Pest test simulating the transition with `Cashier::fake()` or a manual
state setup + code citation.

## Dimension 8 — Concurrent / Race / Idempotency (`EHUNT-CONCURRENT`)

**Probe:** concurrent-write scenarios + retry idempotency + double-submit patterns.

**Concrete checks:**
- Duplicate-key race: two users registering the same email simultaneously — does the second
  500 or 422 cleanly?
- Webhook retry idempotency: Stripe retries the same event (same `event.id`) — does the
  controller short-circuit?
- Double-submit form: user clicks submit twice in <100ms — does the second request create
  duplicate records?
- Queue worker race: same job dispatched twice (e.g., from two webhook deliveries) — does the
  job check for already-processed state?
- Optimistic locking: two users editing the same record save simultaneously — does the second
  write detect the conflict?
- Cache stampede: 100 simultaneous requests all miss the cache and hit the DB — does the code
  coalesce or thunder?

**Evidence form:** Pest test using `parallel testing` patterns OR a unit test with explicit
race-condition setup + code citation.

## Dimension 9 — Plan Limit / Entitlement Boundary (`EHUNT-ENTITLEMENT`)

**Probe:** the boundaries of subscription plan limits, seat caps, usage quotas, and feature
gates — the edges that fire when a user sits at, crosses, or drops below an entitlement
threshold. Highest leverage when the TARGET is billing, multi-tenant, or any metered feature.

**Concrete checks:**
- **Downgrade below current usage:** a team on the Pro plan (10 projects) with 8 projects
  active downgrades to Free (3-project cap). What happens to projects 4-8 — silently
  orphaned, hard-deleted, read-only-locked, or does the downgrade get blocked with a "reduce
  usage first" gate? An unhandled downgrade-below-usage is a data-loss or access-integrity
  finding.
- **Seat-cap edge:** plan allows exactly N seats. Probe N (last allowed invite succeeds), N+1
  (must be rejected cleanly, not 500), and the race where two admins invite the Nth+1 member
  simultaneously (concurrent seat-cap bypass — cross-reference EHUNT-CONCURRENT).
- **Quota at exact cap:** a metered quota (API calls, storage GB, emails/month) at exactly the
  limit, one below, and one above. Off-by-one at the cap (`>=` vs `>`) either lets one unit
  through free or blocks the last legitimate unit. Also probe: does the counter reset at the
  billing-period boundary correctly (cross-reference EHUNT-TIME timezone edges on the reset)?
- **Feature-gate-after-downgrade:** a user created content using a Pro-only feature, then
  downgraded. Is the existing content still viewable/editable, or does the feature gate now
  403/crash on data that legitimately exists? Probe both the create gate AND the read/edit
  gate — most code gates creation but forgets the already-created rows.
- **Grace-period / past_due entitlement:** during dunning (`past_due`), does access follow the
  intended policy (usually retain access through the grace window) or does it flip to blocked
  immediately (cross-reference EHUNT-STATE `unpaid`/`past_due` handling)?
- **Unlimited/null-cap sentinel:** plans that encode "unlimited" as `null` or `-1` — does the
  quota-check code treat `null` as zero (blocks everything) or as unlimited (correct)?

**Evidence form:** failing Pest feature test that sets up the entitlement boundary + code
citation of the gate/limit check. Where the cap is enforced only in the UI and not
server-side, that gap is itself a P0/P1 finding.

## Verification Gates (boundaries lens)

Apply Gates 0, 1, 2, and 8 from `~/.claude/skills/references/v-audit-gates.md`, same as the
bugs lens. Evidence-tier requirement (mandatory for runtime claims) — findings claiming the
code fails at a boundary MUST attach one of:

- `evidence_type: pest-test` — a paste-runnable Pest test snippet that fails on current code
- `evidence_type: property-test` — a property-based reproduction (e.g., using a `Generator`
  library)
- `evidence_type: code-citation` — a precise `path:line` showing the boundary is unhandled (no
  test required if the absence is self-evident)
- `evidence_type: UNVERIFIED-BEHAVIORAL` — claim couldn't be runtime-verified. Auto-downgrades
  to confidence:medium and cannot be P0/P1.
- `evidence_type: PATTERN-MATCH-ONLY` — pure grep match without runtime confirmation.
  Auto-downgrades to confidence:low and cannot be P0/P1.

### Per-dim exploration

Every subagent return MUST include a `## Per-dim exploration` block listing files greped
(patterns + counts), Pest test files inspected, specific boundary inputs attempted (with test
results), specific code paths traced. Same shape as the bugs lens's Gate 0 contract — see
`SKILL.md § Per-dim exploration block`.

### Anti-reward-hacking clause

If a dim genuinely finds nothing, return `findings: []` with metadata `dim_outcome: clean` and
a populated exploration block. Do NOT fabricate findings to hit a quota.

## Output format additions (boundaries lens)

The lens writes into the SAME `BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` file the
bugs lens uses (see `SKILL.md § Output Format`) — set `lens: boundaries` in the report's
metadata header instead of generating a separate `EDGE_HUNT_REPORT_*` file. Findings use the
`EHUNT-*` ID prefixes (`EHUNT-MONEY-01`, etc.) in the same `FINDING_FORMAT` shape the bugs
lens uses. Example:

```markdown
#### EHUNT-MONEY-01 | path/to/file.php:42 | money | high | high
Cashier proration display hardcodes 2 decimal places at line 134, breaking on JPY/KRW/VND
currencies (0 decimals — values are integer yen, not cents).
evidence_type: pest-test
repro: |
  it('handles JPY (0-decimal) subscription totals without decimal-place corruption', function () {
      $user = User::factory()->create();
      $user->newSubscription('default', 'price_jpy_pro')->create('pm_card_jp');
      $user->subscription('default')->swapAndInvoice('price_jpy_enterprise');
      $invoice = $user->invoices()->first();
      expect((string) $invoice->total())->not->toContain('.');  // fails on current code
  });
fix: keep the amount as INTEGER MINOR UNITS end-to-end and only format at the display
boundary via `Cashier::formatAmount(int $amount, string $currency)`.
verify: run the pest test above; expect green.
```

## JSON output extensions (boundaries lens)

When `--format=json` is requested and the boundaries lens ran, each finding in the shared
`FINDING_FORMAT_JSON` array adds:

```json
{
  "id": "EHUNT-MONEY-01",
  "dimension": "money",
  "evidence_type": "pest-test|property-test|code-citation|UNVERIFIED-BEHAVIORAL|PATTERN-MATCH-ONLY",
  "boundary_input": "JPY currency code | leap year Feb 29 | exactly-page-size N | etc.",
  "repro": {"kind": "pest|shell|curl", "snippet": "..."}
}
```

## Critic Dispatch substitutions (boundaries lens)

Apply per `~/.claude/skills/_v-review.md § Critic Dispatch Protocol`, dispatched against the
report before prompt-pack generation, same as the bugs lens. Substitutions specific to this
lens:

- `ROLE_TITLE`: senior production-readiness reviewer with adversarial mindset
- `ROLE_EXPERIENCE`: first-hand experience watching pre-launch boundary audits produce
  false-positive findings that wasted sprint cycles, AND missed real edge bugs that bit
  production within 2 weeks of ship
- `FIND_ITEMS`:
  1. Whether each P0/P1 finding's `evidence_type` actually matches the strength of the claim.
     A P0 with `PATTERN-MATCH-ONLY` is auto-invalid; flag any that slipped through.
  2. Whether each Cashier/Stripe API call in the worked-example repros references a REAL
     method on the operator's Cashier version. `swapAndInvoice($priceId)` and
     `swap($priceId)` ARE real Cashier subscription methods — do NOT flag them as fabricated
     unless called WITHOUT a price id argument. A bare `subscription` relation (singular) IS
     fabricated — Cashier exposes `subscriptions` (plural relation) + `subscription('default')`
     (method), never a singular `subscription` relation.
  3. Whether the state-machine probe (`EHUNT-STATE`) actually exercises
     `incomplete`/`incomplete_expired`/`paused`/`unpaid` or only the happy 4-state path.
  4. Whether unicode findings (`EHUNT-UNICODE`) cite SPECIFIC failing inputs or generic claims.
     Generic findings auto-drop.
  5. Whether the prompt-pack session clustering produces fixable units (one Pest test per
     finding, files-affected don't conflict across sessions, P0 findings come first).

Same cycle-cap rules as the bugs lens (max 2 critic cycles; `critic_review: contested` if
cycle 2 still produces ACCEPT findings). Skip rule: V_DEPTH >= 1, HEADLESS_BATCH=1, or
`--no-critic` → skip and log `critic_review: skipped — reason=<flag>`.

## Session clustering (boundaries lens — distinct from the bugs lens clusters)

Cluster findings into sessions by dimension affinity:

1. **Money, state & entitlement session** — `EHUNT-MONEY` + `EHUNT-STATE` +
   `EHUNT-ENTITLEMENT` findings. Cashier proration, subscription state machine, and
   plan-limit/quota gates are one tightly-coupled billing fix surface.
2. **Time & quantity session** — `EHUNT-TIME` + `EHUNT-QUANTITY` findings.
3. **Input session** — `EHUNT-EMPTY` + `EHUNT-LIMIT` + `EHUNT-UNICODE` findings.
4. **Concurrency session** — `EHUNT-CONCURRENT` findings.

Same sizing/merge/ordering rules as the bugs lens (4-15h per session, <2 findings merge into
the most related session, P0 first then file affinity, aim for 2-4 sessions, all wave 0
unless a real file-dependency conflict exists). Prompt-pack directory is the SAME
`.v-prompt-packs/v-bug-hunt-<MM-DD>/` the bugs lens uses — sessions from either lens can land
in the same pack directory (archived together per the existing pre-dispatch archive step).

## Gotchas (boundaries lens)

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Boundary probe wastes effort on unreachable code | Feature flag disabled in production | Detect flags first (`grep -rn "Feature::active\|Feature::for\|@feature\|Pennant"` etc. — see full patterns below); ask the operator if the surface is about to launch before probing a permanently-off flag. |
| 2 | Unicode bug in an obscure admin field rated P0 | Dimension-based auto-classification instead of context | Evaluate severity in context — a unicode bug in checkout is P0, the same bug in an obscure admin field is P3. |
| 3 | Cashier proration findings can't be verified | No Stripe test environment available | Mark `evidence_type: UNVERIFIED-BEHAVIORAL` and prompt the operator to set up a Cashier sandbox. |
| 4 | Property-based test triples CI wall-clock | Generator-driven test with too many iterations | If a property test takes >5 seconds, scope it down to representative samples. |
| 5 | Stripe minimum-charge assumption wrong for non-USD | Per-currency minimums vary (50¢ is NOT universal) | Reference https://stripe.com/docs/currencies#minimum-and-maximum-charge-amounts in the fix prompt. |

Feature-flag detection patterns (Gotcha 1, full form):

```bash
# Laravel Pennant
grep -rn "Feature::active\|Feature::for\|@feature\|Pennant" "$PROJECT_ROOT/app" "$PROJECT_ROOT/resources" 2>/dev/null | head
# Plain config-driven flags
grep -rn "config('features\.\|env('FEATURE_" "$PROJECT_ROOT/app" 2>/dev/null | head
# Inertia-side flags (FeatureFlag context, react-flagged)
grep -rn "featureFlag\|useFlag\|<Flag\|gates\." "$PROJECT_ROOT/resources/js" 2>/dev/null | head
```
