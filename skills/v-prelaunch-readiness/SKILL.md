---
name: v-prelaunch-readiness
description: "Use when checking whether a solo SaaS is ready for strangers before launch."
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, TaskCreate, TaskUpdate, AskUserQuestion, WebFetch
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-prelaunch-readiness | version: 1.2.3 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing entry point. Pre-launch product-readiness gate for sole-operator SaaS at 0–100 customers.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-review.md`, and `_v-design.md`.

**Audit opener:** see `_v-audit.md` § Audit Skill Opener — perform PROJECT_ROOT resolution, V_DEPTH parsing, and task-list initialization (`TaskCreate`/`TaskUpdate` — the harness renamed `TodoWrite` per `_v-audit.md` 2026-07-05 note) before Step 0 begins.

For changed file detection, read `~/.claude/skills/references/v-core-changed-files.md`.
For dated SEO guidance (OG tags, schema), read `~/.claude/skills/references/seo-volatile-knowledge-2026.md`.

```yaml
contract:
  tier: user-facing
  accepts: [project root, optional --surface=hero|signup|pricing|demo|docs|all]
  produces: [.v/artifacts/PRELAUNCH_READINESS_REPORT_${CLAUDE_SESSION_ID}.md (+ .json companion in the same dir), prioritized punch list, .v-prompt-packs/v-prelaunch-readiness-<MM-DD>/ (00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md)]
  invokes: []
  conditional-invokes: [/v-anti-template-gauntlet (when surfaces touch user-visible UI), /v-pre-flight (when blocking issues require immediate fix)]
  invoked-by: [/v, user, /v-audit-orchestrator, /v-launch]
  estimated_tokens: 40k-90k
```

## Skill Boundaries

**SME persona:** This audit is run by a **senior solo-SaaS launch operator with first-100-customers experience** — someone who's run dozens of pre-launch checks and knows which surfaces matter, which checks are over-engineering at 0-100 customers, and which omissions burn the launch window.

**Distinct from `/v-anti-template-gauntlet`:** v-prelaunch-readiness checks **SURFACE PRESENCE/CORRECTNESS** (does the hero work? is signup ≤6 fields? is the demo link not 404? are OG tags set per page?). The gauntlet checks **OUTPUT QUALITY** (does the hero LOOK professionally crafted, or default-shadcn?). Run BOTH before launch — different questions, different bars.

### Best fit

- Pre-launch product-readiness check before strangers arrive (HN post, PH submission, organic-search / AI-assistant referral, paid ad URL) at the product
- Solo-operator gate at the "we have a working app" → "we're not embarrassed by the experience" transition
- 30–90 day pre-launch reviews where the product exists but hasn't been pressure-tested by external traffic
- Quarterly "first-100-customers bar" recheck on the public surfaces (homepage, signup, pricing, demo, docs)

### Use instead

- `/v-check` — for code-level quality audit (security, performance, tests, UX, accessibility, tech debt, observability, config validation). v-check verifies the codebase + config is sound; this skill verifies the public surfaces are ready for traffic. Run BOTH before launch — different layers.
- `/v-audit-code` (deep-UX mode, `references/deep-ux-audit.md` — absorbed `/v-ui-audit` 2026-07-06) — for the comprehensive UX/a11y/brand product audit producing a large finding backlog. That mode is *exhaustive*; v-prelaunch-readiness is *triaged-to-essentials* for the pre-launch gate.
- `/v-pre-flight` — for code-level quality gates (tests, build, lint, types). Different concern.
- `/v-anti-template-gauntlet` — for the blocking gate that catches AI/template tells. **v-prelaunch-readiness defers all template/AI-tell detection to the gauntlet** — Surface checks here flag missing surfaces and incorrect content, NOT template-default appearance. Run both: prelaunch-readiness for "are surfaces present and correct" + gauntlet for "does the output look professionally crafted."
- `/v-audit-messaging` — for full positioning audit across 7 dimensions. v-prelaunch-readiness only checks the "is this clear in 5 seconds" subset.

### Not for

- Replacing `/v-check` audit — `/v-check` covers codebase quality + config validation; v-prelaunch-readiness covers public-surface readiness. Run both before launch.
- Post-launch product audits at 100+ customers (use `/v-audit-code` deep-UX mode or specialist `v-audit-*` skills)
- Implementing the fixes — this skill outputs the punch list, `/v-build` implements
- Marketing campaign planning, content calendars, or launch-day announcement coordination (use `/v-content-ops`, `/v-launch-channels`)

## Why This Exists

Solo SaaS founders ship two distinct kinds of "launch":

1. **Operational launch** — does the system handle traffic? (`/v-check` covers this)
2. **Product launch** — is the experience worth sending strangers to?

The second kind has no dedicated gate. Founders run `/v-check`, see a green GO/NO-GO, and point paid ads / Product Hunt submissions / organic + AI-assistant traffic at a homepage that takes 12 seconds to explain itself, a pricing page with placeholder copy, a signup flow that 500's on common edge cases, and a "Demo" link that opens a 404. The operational gate doesn't catch this; nothing does.

`v-prelaunch-readiness` is that gate. It runs through the **public surfaces a stranger encounters in their first 60 seconds** and produces a ruthlessly-triaged punch list of what *must* fix before driving any traffic. The bar is "first-100-customers ready," not "perfect" — perfection is post-traction work.

## Entry Point

**Auto-detect everything. ONE multiple-choice question for the operator.**

### Auto-detection sequence

1. **Surface inventory** — Step 0 below detects which public surfaces exist (homepage, signup, pricing, demo, docs). Surfaces without source files skip automatically.

2. **Stack** — `package.json` / `composer.json` / framework config detection.

3. **Default scope** — all surfaces detected. The operator overrides only via `--surface=NAME` argument.

### The single question

```yaml
question: "How long until you start driving traffic to this product?"
header: "Launch Window"
multiSelect: false
options:
  - label: "Today / this week"
    description: "Triage to MUST-FIX only. Defer everything not blocking."
  - label: "Next 2-4 weeks (Recommended default)"
    description: "Standard scope: MUST-FIX + SHOULD-FIX backlog."
  - label: "1-3 months out"
    description: "Comprehensive: include polish backlog + nice-to-haves."
```

The launch-window answer drives stringency (same findings classified differently). All other inputs are auto-detected or defaulted.

### What's NOT asked

- Scope (defaults to all detected surfaces; operator overrides via `--surface=NAME`)
- Detail level (correlates with launch window; no separate question)
- Output path (auto-determined: `.v/artifacts/PRELAUNCH_READINESS_REPORT_${CLAUDE_SESSION_ID}.md` — Phase-2: under `.v/artifacts/`, create the dir; the `.json` companion goes in the same dir)

### Orchestrator invocation (V_DEPTH ≥ 1) — SKIP the question

When invoked by `/v` or `/v-audit-orchestrator` (V_DEPTH ≥ 1, parsed in the Audit opener), a forked orchestrator cannot surface an interactive prompt — so **do NOT ask the launch-window question.** Default `launch_window = 2-4 weeks` (Standard stringency) unless the invocation prompt names a window: `today`/`this week`/`launching now` → This week; `1-3 months`/`next quarter`/`not soon` → 1-3 months. Record the assumed window in the report's `launch_window:` field with an `(assumed — orchestrator invocation)` note so the operator can re-run with an explicit window if the assumption is wrong. At V_DEPTH = 0 when the window is already named in the prompt, likewise skip the question and use it.

### Why this skill deviates from the canonical Audit Depth question

`_v-audit.md` § Depth Question Contract mandates a canonical 3-tier "Audit Depth" question for standalone audit skills. This skill substitutes a **launch-window** question under `_v-audit.md` § "Permitted deviation: topic-axis". Justification: the operator's real axis here is not *how deep to look* — the surface set is fixed and always fully checked, and the checks are cheap — but *how strict to be given time-to-traffic*. Launch window is that stringency axis (Step 3 reclassifies the same findings by window). The `multiSelect: false` constraint and single-question shape are preserved; only the question's semantic axis differs, as the clause permits.


## Workflow

| Step | Action | Skip conditions |
|---|---|---|
| Step 0 | Orientation — detect stack, find public surfaces | If `--surface=NAME` passed, scope to that |
| Step 1 | Run surface-specific checks in parallel as fork-safe `claude -p` subprocesses via `v-dispatch-subagent.sh` (the Agent tool does NOT work from `context: fork` — fails silently) | Skip surfaces with no source files |
| Step 1.5 | Operator readiness (T-30 → T-7 firing window only) — load `~/.claude/skills/references/v-launch-operator-readiness.md`; produce 5-line pre-commitment artifact | Skip if launch_window=`today / this week` (already past T-7) OR if launch_window=`1-3 months out` (too early; defer to next run) |
| Step 1.6 | Blocking-presence checks (cheap, inline — no subagent): legal-docs · webhook-signature · auth-route presence — see § Step 1.6 | — |
| Step 2 | Consolidate findings, classify by must/should/nice | — |
| Step 3 | Apply launch-window stringency | — |
| Step 4 | Write `.v/artifacts/PRELAUNCH_READINESS_REPORT_*.md` with punch list | — |
| Step 5 | **Generate prompt pack (MUST USE SUBAGENT)** — dispatch a fork-safe sonnet `claude -p` subprocess (`v-dispatch-subagent.sh --model sonnet --mode self-write` — NOT the Agent tool) to create `.v-prompt-packs/v-prelaunch-readiness-<MM-DD>/` directory with paste-ready /v session files | Skip if 0 MUST-FIX + 0 SHOULD-FIX findings |
| Step 6 | Validate prompt pack — per `~/.claude/skills/references/v-core-prompt-pack.md` validator | Skip if Step 5 was skipped |
| Step 7 | Present summary + recommended next step (paste a session file into `/v` to fix; `/v-anti-template-gauntlet` for output-quality gate) | — |

**Important:** This skill produces a punch list AND a paste-ready prompt pack. Each `.v-prompt-packs/v-prelaunch-readiness-<MM-DD>/*.txt` wave pack is a self-contained `/v` invocation — operator copy-pastes the entire file content into a fresh session. No editing required.

### Step 0: Orientation

Detect the stack and locate public surfaces:

```bash
# Stack detection
test -f package.json && grep -q '"react"' package.json && echo "REACT=true"
test -f composer.json && echo "PHP=true"
{ test -f next.config.js || test -f next.config.ts || test -f next.config.mjs; } && echo "NEXT=true"

# Public surface discovery — basename match (Laravel/Inertia Pages, classic Next.js pages/ router)
find resources/js/Pages src/pages app/pages pages -maxdepth 4 \
  \( -iname '*welcome*' -o -iname '*home*' -o -iname '*landing*' \
     -o -iname '*pricing*' -o -iname '*signup*' -o -iname '*register*' \
     -o -iname '*demo*' -o -iname '*docs*' -o -iname '*about*' \) 2>/dev/null | head -20

# Next.js App Router: each route is a DIRECTORY holding page.{tsx,jsx,ts,js}, so basename matching
# above misses them (the file is always "page.*"). Match the PARENT directory name instead.
find app -maxdepth 5 \( -name 'page.tsx' -o -name 'page.jsx' -o -name 'page.ts' -o -name 'page.js' \) 2>/dev/null \
  | grep -iE '/(welcome|home|landing|pricing|signup|register|demo|docs|about)/' | head -20

# OG / metadata config detection
grep -rln "og:title\|og:image\|<meta name=\"description\"" resources src app pages 2>/dev/null | head -5

# Theme detection — verify BOTH themes switch via html[data-theme]
grep -rln "data-theme" resources/css resources/js src/components 2>/dev/null | head -5
```

Fail loud if no public-facing pages found — this skill assumes the project has a marketing surface. If it's a pure backend / API product (no marketing site at all), redirect to `/v-pre-flight` for executable quality gates and `/v-check` for codebase + config audit; this skill cannot meaningfully evaluate a no-marketing-surface product.

### Step 1: Launch surface checks in parallel

Dispatch one fork-safe `claude -p` subprocess per surface (`~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode capture` — NOT the Agent tool, which fails silently from `context: fork`). Each briefing file receives project context + the surface scope.

**Moved to:** `references/surface-checks.md`.

**Summary:** 8 surface-check prompts (Hero/5-Second Test, Signup
Flow, Pricing Page, Demo, Docs, OG/Social Meta, Dark Mode, Mobile
Critical Paths). Each prompt is dispatched as a fork-safe
`claude -p` subprocess whose artifact is JSON with findings +
per-surface verdict.

**Trigger to load:** Step 1 of every run. Read the reference,
then dispatch one subprocess (`--model sonnet --mode capture`) per
surface in scope. Each briefing file receives project context +
the surface's verbatim prompt from the reference.

**Behavior unchanged:** the 8 surface scopes, the assess-criteria
checklists, and the JSON output schemas (with severity must/should/nice)
are preserved verbatim from the prior inline definitions.

**Dispatch mechanics (one subprocess per in-scope surface):**

```bash
SCRATCH="${V_TMP_DIR:-$PROJECT_ROOT/.v/tmp}"; mkdir -p "$SCRATCH"
# For each surface S in scope (hero signup pricing demo docs og dark_mode mobile):
#   1. Write "$SCRATCH/surface-$S.brief.md" = project context (PROJECT_ROOT, stack,
#      CLAUDE.md path) + the surface's VERBATIM prompt from references/surface-checks.md.
#   2. The dispatch helper auto-appends a capture epilogue oriented at `Model:`-prefixed
#      markdown; the surface prompts emit JSON instead. So add ONE line to each brief:
#      "Emit ONLY the JSON object as your final message — no `Model:` line, no prose,
#      no code fence." The capture sanitizer slices from `Model:` only when present, so
#      with no `Model:` line it falls through and persists the raw JSON verbatim.
#   3. Dispatch — NEVER the Agent tool (fails silently from context: fork):
~/.claude/skills/v/references/v-dispatch-subagent.sh \
  --model sonnet --mode capture \
  --prompt-file "$SCRATCH/surface-$S.brief.md" \
  --artifact    "$SCRATCH/surface-$S.json"
```

Fire the in-scope surfaces **concurrently** (independent Bash calls in one turn — not serially), then read each `surface-$S.json` back in the main context for Step 2.

**Failure handling (per `_v-audit.md` § Error Handling for Parallel Subagents):** a surface subprocess that exits non-zero / times out / returns empty is recorded as `{"surface": S, "status": "failed"}` — do NOT fabricate its findings, and mark that surface `unknown` (never `pass`) in the report. Partial/truncated JSON → accept what returned, mark `partial`. If **more than half** the in-scope surfaces fail, do NOT emit a READY/NEEDS-WORK/NOT-READY verdict — write `status: AUDIT-INCOMPLETE`, list the failed surfaces, and tell the operator to re-run.

### Step 1.5: Operator readiness pre-commitment (conditional)

**Run only when `launch_window = 2-4 weeks`** (the T-30 → T-7 firing window). Skip for `today / this week` (already past T-7) and `1-3 months out` (too early — defer to a later run), per the Workflow table skip conditions.

Load `~/.claude/skills/references/v-launch-operator-readiness.md` and produce the 5-line pre-commitment artifact it defines — read the five lines FROM that file, do not restate them here. This is an operator-process check, not a surface check — its output rides in the report as a short "Operator readiness" block, and any unmet commitment is a SHOULD-FIX (NEEDS-WORK), not a NOT-READY blocker.

### Step 1.6: Blocking-presence checks (cheap, inline — no subagent)

The 8 surface checks cover *public-surface* presence/correctness. These three launch-BLOCKERS are cheap to verify statically and are NOT covered by the surface subagents — run them inline (no subprocess dispatch):

```bash
# Legal docs present? (Gotcha #1 — NOT-READY-blocking for any product collecting user data)
find . -maxdepth 4 \( -iname '*privacy*' -o -iname '*terms*' -o -iname '*cookie*' \) \
  \( -name '*.md' -o -name '*.tsx' -o -name '*.blade.php' -o -name '*.vue' \) 2>/dev/null | grep -v node_modules | head
# Webhook signature verification present? (Gotcha #4 — BLOCKING for any product with billing/webhooks)
grep -rnE "constructEvent|verifyHeader|Stripe-Signature|X-Hub-Signature|svix|hmac" app routes resources/js src 2>/dev/null | grep -iv test | head
# Core auth routes present? (Gotcha #3 — login/register/password-reset/email-verification/logout)
# Framework-appropriate route homes: Laravel routes/, Next App-Router app/api & middleware, SPA route files.
grep -rnE "login|register|password|verif|logout" \
  routes app/api src/app/api pages/api src/pages/api middleware.ts middleware.js 2>/dev/null | grep -iv test | head
# Managed-auth-provider fallback (a present provider satisfies presence — do NOT flag missing):
grep -rlnE "next-auth|@clerk|@supabase/auth|Auth0|workos|lucia-auth|Laravel\\\\Fortify|laravel/fortify|Breeze|Jetstream" \
  package.json composer.json 2>/dev/null | head
```

- **Legal docs missing** → MUST-FIX, NOT-READY-blocking for any product collecting user data (deferral ≠ pass). Generate with `/v-legal-docs-generate`.
- **No webhook signature verification** on a product with billing/webhooks → MUST-FIX, NOT-READY (per `~/.claude/skills/v-build/references/saas-patterns.md`).
- **Missing auth routes** (forgot-password / email-verification are the usual omissions) → MUST-FIX. **Do not false-flag managed auth:** if the first grep is empty but the provider grep matches (NextAuth, Clerk, Supabase Auth, Auth0, Fortify/Breeze/Jetstream, etc.), auth lives in the provider — presence is satisfied; confirm the provider config exists rather than flagging MUST-FIX.

**Scope note (load-bearing for the verdict):** these are *presence* checks only — deep verification is out of scope. See § Scope boundary for exactly what THIS skill verifies vs what defers to `/v-check` + `/v-pre-flight` (and perf/CWV to a runtime tool); the READY verdict is scoped accordingly, NOT "operationally hardened." Say so in the report.

### Step 2: Consolidate findings

Merge all in-scope surface JSONs **plus the Step 1.6 blocking-presence findings (legal · webhook-sig · auth)** into a single report. Carry failed/partial surfaces through with their `failed`/`partial` status (per Step 1 failure handling) — never silently drop them. Bucket findings by severity:

- **MUST-FIX** — blocks driving traffic. Examples: signup flow 500's on edge cases; pricing page CTA broken; mobile horizontal scroll on hero; demo link 404s.
- **SHOULD-FIX** — causes silent conversion loss. Examples: generic OG image; pricing tier names unclear; hero specificity weak; missing decision helper on pricing.
- **NICE-TO-HAVE** — polish. Examples: dark mode chart colors; favicon variants; apple-touch-icon.

Canonical mapping (per `~/.claude/skills/references/v-core-severity.md`, mirrored in v-audit-consolidate's `severity-mapping.md`): MUST-FIX=P0, SHOULD-FIX=P1, NICE-TO-HAVE=P3 (this vocabulary has no medium tier). Keep the native tier names in the report — consolidation normalizes via that table.

### Step 3: Apply launch-window stringency

Adjust severity based on time-to-traffic:

| Window | MUST-FIX includes | SHOULD-FIX includes | NICE-TO-HAVE |
|---|---|---|---|
| **This week** | Only critical-path blockers | Reframe non-blockers as deferred backlog | All deferred |
| **2-4 weeks** | Critical-path + conversion-cost issues | Standard polish | Some deferred |
| **1-3 months** | Critical-path | Conversion + polish | Full backlog surfaced |

The same finding can be MUST-FIX in a 1-week window and SHOULD-FIX in a 3-month window. The skill makes this stringency change explicit so the operator knows what changed if they re-run.

### Step 4: Write the report

**Verdict derivation (compute `status` from the consolidated, post-stringency findings — do not eyeball it):**

- **NOT-READY** — ≥1 MUST-FIX finding remains after Step 3 stringency. This is forced by any Step 1.6 blocker (missing legal docs on a data-collecting product · missing webhook signature verification on a billing product · missing core auth route with no managed provider) and by any critical-path surface break (signup 500s, pricing CTA broken, demo 404, hero horizontal-scroll on mobile, five-second test = fail). Do not drive traffic.
- **NEEDS-WORK** — 0 MUST-FIX, but ≥1 SHOULD-FIX. Safe to drive traffic, but leaking conversions; clear the backlog first if the window allows.
- **READY** — 0 MUST-FIX and 0 SHOULD-FIX; only NICE-TO-HAVE remains. Scoped to public-surface + blocking-presence readiness only (see `scope:` — never read as "operationally hardened").
- **AUDIT-INCOMPLETE** — >50% of in-scope surfaces failed to return (Step 1 failure handling). Do not emit READY/NEEDS-WORK/NOT-READY; list the failed surfaces.

```markdown
# PRELAUNCH_READINESS_REPORT
generated: [ISO timestamp]
launch_window: [today | 2-4 weeks | 1-3 months]  (+ "(assumed — orchestrator invocation)" if defaulted at V_DEPTH≥1)
status: [READY | NEEDS-WORK | NOT-READY | AUDIT-INCOMPLETE]
scope: public-surface presence/correctness + blocking-presence (legal · webhook-sig · auth routes). NOT verified here — run /v-check + /v-pre-flight: deep auth/billing E2E, security baseline, observability, performance/CWV.

## Five-second test
What a stranger thinks after 5 seconds: "[verbatim from Surface 1]"
Status: [pass | fail | borderline]

## Surfaces audited
| Surface | Findings (must/should/nice) | Status |
|---|---|---|
| Hero | M:N S:N N:N | [pass|fail] |
| Signup | M:N S:N N:N | [pass|fail] |
| Pricing | M:N S:N N:N | [pass|fail] |
| Demo | M:N S:N N:N | [pass|fail] |
| Docs | M:N S:N N:N | [pass|fail] |
| OG/Social | M:N S:N N:N | [pass|fail] |
| Dark mode | M:N S:N N:N | [pass|fail] |
| Mobile | M:N S:N N:N | [pass|fail] |

(Use `unknown` — never `pass` — for any surface whose subprocess failed to return.)

## Blocking-presence checks (Step 1.6 — launch blockers)
| Check | Present? | Verdict |
|---|---|---|
| Legal docs (privacy · terms) | [yes\|no] | [ok \| MUST-FIX (NOT-READY)] |
| Webhook signature verification | [yes\|no\|n/a — no billing] | [ok \| MUST-FIX (NOT-READY)] |
| Core auth routes (login·register·password-reset·email-verify·logout) | [yes\|via managed provider\|partial\|no] | [ok \| MUST-FIX] |

## MUST-FIX punch list

[Prioritized list. Each finding has ID, file:line, 1-sentence fix.]

## SHOULD-FIX backlog

[Same format, lower priority.]

## NICE-TO-HAVE deferred

[List only — no detail; deferred to post-traction.]

## Recommended next step

[Auto-generated based on findings:
- If MUST-FIX > 0: "Run /v-build with this report's MUST-FIX list before driving traffic."
- If SHOULD-FIX > 0 and launch_window=1-3 months: "Run /v-anti-template-gauntlet to catch AI/template tells, then address SHOULD-FIX backlog."
- If all clean: "Ready for traffic. Run /v-check for operational gate, then /v-launch-channels for channel-specific assets."]
```

### Step 5: Generate prompt pack (MUST USE SUBAGENT)

Pre-dispatch shell setup (run before dispatching the subprocess):

**`/v` first-line requirement:** every pack file (excluding `00-README.md`) MUST be a flat `.txt` file whose line 1 is the literal `/v ` prefix (the orchestrator routing prefix) — the unified wave form per `~/.claude/skills/references/v-runnable-pack-convention.md` § Canonical form, NOT the deprecated `NN-*.md` shape. Files that do not start with `/v ` are rejected by the post-generation validator and the pack will fail. The dispatched subagent must produce paste-ready files: operator copy-pastes the entire file content into a fresh `/v` session with zero edits required.


```bash
PROMPT_DIR=".v-prompt-packs/v-prelaunch-readiness-$(date +%m-%d)"

# Idempotent re-run: archive any prior pack, then create the active dir.
# Per `_v-audit.md` § Step 3: Prompt Generation Contract — see the Pre-dispatch shell block.
# Without this, fewer-or-renamed sessions on re-run leave stale wave packs orphaned;
# the post-generation validator counts them and reports a false-positive PASS.
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

Per `_v-audit.md` § Step 3: Prompt Generation Contract (pack shape per `~/.claude/skills/references/v-runnable-pack-convention.md`). Set `PROMPT_DIR=".v-prompt-packs/v-prelaunch-readiness-$(date +%m-%d)"`. Dispatch a fork-safe `claude -p` subprocess (`v-dispatch-subagent.sh --model sonnet --mode self-write`) whose briefing file contains the report's MUST-FIX + SHOULD-FIX findings + sections 5a/5b/5c below verbatim.

#### 5a. Group findings by surface

Cluster findings by their owning surface (Hero, Signup, Pricing, Demo, Docs, OG/Social, Dark mode, Mobile). Each surface = one session pack. If a surface has both MUST-FIX and SHOULD-FIX findings, include both in the same session pack (MUST-FIX first).

**Blocking-presence findings (Step 1.6) are NOT surfaces** — cluster legal-docs / webhook-signature / auth-route findings into a dedicated `blocking-presence.txt` session. These are disjoint-file from the surface packs (per `v-runnable-pack-convention.md` § Wave assignment) so they stay wave 0 like the rest, but list them FIRST in the 00-README.md wave/session map (they are the NOT-READY blockers — priority-order, not a file dependency) so the operator runs that session first. In its body, route legal-docs generation to `/v-legal-docs-generate` and webhook-signature to `~/.claude/skills/v-build/references/saas-patterns.md` rather than restating the fix inline.

**Security-bearing pack clause (mandatory, per `v-runnable-pack-convention.md` § Security-bearing packs):** `blocking-presence.txt` touches webhook signature verification and auth-route presence — both auth/authz-decision and signature-verification surfaces. Inline this exact sentence into that pack's `## Constraints` section: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session." The surface packs (hero/signup/pricing/demo/docs/og/dark-mode/mobile) skip this clause unless a specific finding on that surface happens to touch auth/authz, secrets, or payment flows.

**No minimum-session floor:** the unified self-validate (`v-runnable-pack-convention.md` § Self-validate) only requires ≥1 real pack — unlike the retired legacy validator, it does not impose a ≥3-session / ≥4-file floor. A triaged pre-launch run producing findings on only 1–2 surfaces is not penalized; do NOT pad with empty stub sessions to hit an artificial count (stubs also fail the <10-line stub check). Split by severity only where that keeps each pack substantive (e.g., `blocking-and-must-fix.txt`, `should-fix.txt`).

#### 5b. Assign session packs

For each surface with ≥1 finding:
- File name: `[surface-slug].txt` (e.g., `hero.txt`, `signup.txt`) — wave 0 (no prefix), since surfaces are disjoint files per the convention's wave-assignment rule
- List surfaces in the 00-README.md wave/session map ordered by surface priority (Hero, Signup, Pricing first; everything else after) — this drives operator run-order, not wave number, since all surface packs are wave 0
- File starts with `/v ` literal — the rest of the file is the operator's paste body
- **Closing waves (mandatory, per `v-runnable-pack-convention.md` § Closing waves):** after the last implementation wave (wave 0 above), append `w1-pre-flight.txt` + `w1-review.txt` as a parallel READ-ONLY verification wave (`## Goal`/`## Checks`/`## Acceptance` only — no `## Files`, no "leave staged" line), then a single sequential `w2-hardening.txt` that triages the verification findings, fixes CRITICAL/HIGH, re-runs gates, and runs `/v-verify-done`. Always append a closing `99-verify.txt` read-only pack last (re-runs the surface checks + confirms READY).

#### 5c. Per-file format

Each pack is the entire content the operator pastes into `/v`. No frontmatter, no metadata, no commentary outside the prompt body. MUST carry the full body schema from `v-runnable-pack-convention.md` § Pack body schema, in order: `## Goal` · `## Context` · `## Files` (literal H2, REQUIRED — v-build's scope guard keys on it) · `## Changes` · `## Acceptance criteria` · `## Tests` · `## Constraints` · `## Dependencies`.

```markdown
/v Fix pre-launch readiness findings on the [surface] surface for [Project Name].

## Goal
Bring the [surface] surface to launch-ready — [1-3 sentences tying the findings to launch risk].

## Context
Tech stack: [from orientation].

[For each finding, inline:
- File:line citation
- What's wrong (1-2 sentences)
- Why it matters for launch]

### Finding 1: [title] ([severity])
**File:** path/to/file.tsx:42
**Problem:** [1-2 sentences]

### Finding 2: ...

## Files
- path/to/file.tsx — [what changes]

## Changes
- [specific change per finding]

## Acceptance criteria
- [ ] [how to verify the fix, per finding]

## Tests
- [test to add/run proving the fix, per finding]

## Constraints
Read CLAUDE.md first for stack + conventions.

## Dependencies
Wave 0. Requires: none.

## After all fixes

Run the project's quality gates:
- `[test command from CLAUDE.md]`
- `[build command from CLAUDE.md]`
- `[lint command from CLAUDE.md]`

Verify the [surface] surface manually:
- [surface-specific manual check, e.g., "Open the homepage; the hero should pass the 5-second test"]

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

#### 5d. README

Write `.v-prompt-packs/v-prelaunch-readiness-$(date +%m-%d)/00-README.md` with:
- Project name, audit date, launch window, total findings (MUST/SHOULD/NICE)
- Wave/session map table: `| Pack | Wave | Surface | Findings (M/S/N) | Can Parallel? |` — every name in this table MUST have a matching file on disk and vice versa, INCLUDING the closing waves (`w1-pre-flight.txt`, `w1-review.txt`, `w2-hardening.txt`, `99-verify.txt`)
- Sessions touching the same files cannot run in parallel — note the conflicts
- Recommended order: `blocking-presence.txt` and MUST-FIX surfaces first (driven by launch-window stringency), then the closing verification/hardening waves, then `99-verify.txt` last

### Step 6: Validate prompt pack

Self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate (or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/$PROMPT_DIR"`), then `run-v-packs "$PROMPT_DIR" --dry-run`. On failure, retry once with the failure messages as context. On second failure, mark `prompt_pack: validation_failed` in the audit report.

### Step 7: Present summary

Show a console summary with:
- Five-second test verdict (pass/fail + verbatim summary)
- MUST-FIX count + SHOULD-FIX count
- Top 3 MUST-FIX items with file:line
- **Prompt pack:** "Implementation prompts are in `.v-prompt-packs/v-prelaunch-readiness-<MM-DD>/`. Each `.txt` pack is paste-ready — copy the entire file content into a fresh `/v` session to fix that surface's findings."
- Recommended next: paste highest-priority session file into `/v`

## Cross-references

- Operational launch readiness: `~/.claude/skills/v-check/SKILL.md` (run BOTH before launch)
- Comprehensive product audit (post-traction): `/v-audit-code` deep-UX mode (`references/deep-ux-audit.md` — absorbed `/v-ui-audit` 2026-07-06)
- Output-quality gate (anti-template/AI tells): `~/.claude/skills/v-anti-template-gauntlet/SKILL.md`
- Channel-specific launch: `~/.claude/skills/v-launch-channels/SKILL.md`
- Zero-outreach/solo-motion gate (traffic sources are passive — organic, AI-assistant, owned; never cold outreach): `~/.claude/skills/references/v-core-solo-motion.md`
- Privacy-friendly analytics + CWV decision (Surface 6 dependency): `~/.claude/skills/references/v-launch-privacy-friendly-analytics.md`
- Help docs / support channel decision (Surface 5 dependency): `~/.claude/skills/references/v-launch-help-docs-channel.md`
- Status page decision (observability — deferred to `/v-check`; optional reference): `~/.claude/skills/references/v-launch-status-page.md`
- Operator readiness pre-commitment (Step 1.5 dependency, T-30 → T-7 only): `~/.claude/skills/references/v-launch-operator-readiness.md`

## Progress Checklist (copy into your response, check off as you go)

```markdown
## Pre-launch readiness progress

Mirror the section headers from this skill's body workflow (Steps 0–7 documented above) into your response — one checkbox per ### Step as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

## Scope boundary (render into the report `scope:` line + the Step 7 summary)

**Verified by THIS skill:** public-surface presence/correctness · operator readiness · legal-docs / webhook-signature / auth-route *presence*.

**Deferred — NOT verified here (run `/v-check` + `/v-pre-flight` before you trust a READY):** deep auth/billing E2E, security baseline (CSP/HSTS/rate-limiting/secrets), observability hooks. Performance / Core Web Vitals defer to a RUNTIME tool (Lighthouse/PSI) — `/v-check` Domain 7 only emits that pointer; no static audit measures CWV. The READY verdict is scoped to public-surface + blocking-presence readiness — never read it as "operationally hardened."

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | "READY" verdict despite missing legal docs (privacy, terms) | Step 1.6 legal-docs presence check skipped, or operator said "I'll add later" | Legal docs are NOT-READY-blocking for any product collecting user data; "I'll add later" is a deferral, not a pass. Step 1.6 verifies presence; generate with `/v-legal-docs-generate` |
| 2 | "READY" reads as if performance was checked, but it wasn't | Performance / Core Web Vitals are runtime metrics — this skill does not measure them, and neither does `/v-check` (its Domain 7 only emits a Lighthouse/PSI pointer) | Do NOT emit a READY that implies perf was measured. The report's `scope:` line must state perf/CWV is deferred to a runtime tool (Lighthouse/PSI); run `/v-check` for the static operational layer |
| 3 | Auth surface "passes" because signup works — forgot-password route is missing | Surface checks cover the signup *page*, not the full auth route set | Step 1.6 flags missing login / register / password-reset / email-verification / logout *routes* (presence). DEEP end-to-end auth verification is deferred to `/v-check` + `/v-pre-flight` |
| 4 | "READY" but webhook handlers have no signature verification | Surface checks stop at "pricing page works" | Step 1.6 greps for webhook signature verification; missing on a billing/webhook product = MUST-FIX, NOT-READY (per `~/.claude/skills/v-build/references/saas-patterns.md`) |
| 5 | Onboarding gets user to sign-up complete, not a first-success-event | "Activation" conflated with account creation; this skill checks the signup *surface*, not activation depth | First-success-event (value delivery, e.g. "first report generated") is operator-defined and audited deeply by `/v-audit-growth` — note it as a scope boundary here, don't claim it as verified |
| 6 | Operator pastes a stale `.txt` pack from a prior run that was already cleared | Pre-dispatch shell only ran `mkdir -p` (orphan files survived) | Pre-dispatch MUST archive prior pack to `.bak-YYYYMMDD-HHMMSS-XXXX/` per `_v-audit.md` § Step 3 — the validator cannot detect orphan staleness, so cleanup is upstream-only |

## Idempotency

Re-running on the same project produces a fresh report. Findings IDs are not cross-run-stable (this is a triaged check, not a tracking audit). For tracked findings across runs, use `/v-audit-code` (deep-UX mode) instead.

**Prompt pack re-run behavior:** the pack subdir at `.v-prompt-packs/v-prelaunch-readiness-<MM-DD>/` is archived (not overwritten) on re-run. A non-empty prior pack is moved to `.v-prompt-packs/v-prelaunch-readiness.bak-YYYYMMDD-HHMMSS-XXXX/` before the new pack is generated, so prior session files cannot leak into a current paste session. The audit JSON+MD in `.v/artifacts/` remain SID-stamped per session for history.
