---
name: v-docs
description: "Use when generating or auditing technical docs, OpenAPI specs, README files, guides, or changelogs."
model: sonnet
context: fork
allowed-tools: Read, Glob, Grep, Bash, Write, AskUserQuestion, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
user-invocable: false
disable-model-invocation: true
---
<!-- skill: v-docs | version: 1.4.1 | last-updated: 2026-08-12 -->
<!-- 1.4.0 (2026-08-02): Route 2 now applies the library's own answer-engine pattern
     (channel-playbooks.md § Channel 7) to FAQ/guide headings instead of never citing it; added
     an in-product-reachability quality rule (§ Quality Rules item 8) so generated docs that
     nothing in the product links to get flagged as a gap instead of silently shipped. -->


# 2026 Canonical Contract

Tier: Orchestration primitive. **Orchestrator-only — not user-invocable.** Reached via `/v` Docs classification ("document", "docs", "README", "API docs"); start with `/v`. (`user-invocable: false` + `disable-model-invocation: true` remove it from the interactive Skill menu, so normal runs are `V_DEPTH >= 1`. The `V_DEPTH == 0` standalone branch in the Completion Contract is still reachable via **direct headless/subprocess dispatch** — e.g. `claude -p "/v-docs …"` — which bypasses the menu gate; that branch exists to keep such a run gauntlet-correct, not to invite interactive use.)

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-growth.md`, and `_v-review.md`.

For reusable route prompts and output skeletons, read `${CLAUDE_SKILL_DIR}/references/route-templates.md`.

Rules:
- every user-facing claim must map to source
- mark unverified claims as `unverified`
- for marketing-adjacent copy, keep the output measurement-aware

```yaml
contract:
  tier: orchestration-primitive
  accepts: [user prompt, doc type selection]
  produces: [docs/*.md, docs/api/README.md, openapi.yaml, CHANGELOG.md, docs/migration/*.md, DOCS_AUDIT_YYYY-MM-DD_HHMM_${CLAUDE_SESSION_ID}.md, docs/adr/ADR-*.md, CLAUDE.md (an `## Architecture Decisions` section)]
  invokes: []
  conditional-invokes: [/v-pre-flight, /v-verify-done]
  invoked-by: [/v, user]
  estimated_tokens: 15k-50k
  estimated_duration: 3-15 min
```

# /v-docs - Documentation Generator

Interactive documentation: API reference, user guides, or docs audit.

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules, `_v-growth.md` when user-facing copy affects metrics, and `_v-review.md` for docs-audit confidence labeling.

## Skill Boundaries

**SME persona:** This skill is run by a **senior technical writer + DX specialist** — specialty is API docs, runbooks, and onboarding guides that the reader can act on. Knows when an example is worth more than a paragraph, when to link out vs duplicate, and when to skip the diagram because the prose is clearer.

_See `Route Boundaries` below for the structural boundaries (best fit / use instead / not for)._

## Route Boundaries

- Use `/v-docs` when the deliverable is documentation or a docs audit grounded in source code.
- Use `/v-check` when the question is broad product/code risk rather than documentation accuracy.
- Use `/v-plan` when the user needs an implementation plan, not docs output.
- Use `/v-legal-docs-generate` for privacy/terms/cookie/DPA legal docs — NOT this skill.
- Keep route-specific Ask First / Output examples in `${CLAUDE_SKILL_DIR}/references/route-templates.md` instead of duplicating large scaffolds inline.

## Execution Context (resolve once, first)

Before any route, establish context — these values feed every path/timestamp/question below:

1. **V_DEPTH** — parse per `_v-core.md` § V_DEPTH Parsing Protocol. Search the invocation prompt for `[V_DEPTH=N` (bracketed) then `V_DEPTH=N` (bare); default `0` if absent.
2. **PROJECT_ROOT** — per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from the invocation prompt if present, else `git rev-parse --show-toplevel`. If that does not yield a safe repo root, STOP and ask for `PROJECT_ROOT` explicitly. Never fall back to bare `pwd` in a forked/headless context.
3. **SID** — resolve `${CLAUDE_SESSION_ID}` via the standard env cascade (`$CLAUDE_SESSION_ID` / `$CLAUDE_CODE_SESSION_ID`, else the persisted `~/.claude/runtime/current-session-id` file). Never invent a SID or derive one from a filename.
4. **Timestamp** — generate real timestamps with `date -u +%Y-%m-%d_%H%M` (UTC). NEVER fabricate a date/time string.
5. **Headless / non-interactive** — treat the session as non-interactive when `V_DEPTH >= 1`, `HEADLESS_BATCH=1`, or `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`. In that case `AskUserQuestion` is unavailable — see § Entry Point for the fallback.

All artifact paths are absolute from `PROJECT_ROOT`.

## Output

- API docs: `{PROJECT_ROOT}/docs/api/README.md` + `{PROJECT_ROOT}/openapi.yaml`
- User docs: `{PROJECT_ROOT}/docs/*.md`
- Changelog: `{PROJECT_ROOT}/CHANGELOG.md`
- Migration guide: `{PROJECT_ROOT}/docs/migration/v{version}.md`
- Docs audit: `{PROJECT_ROOT}/.v/artifacts/DOCS_AUDIT_YYYY-MM-DD_HHMM_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir; e.g. `.v/artifacts/DOCS_AUDIT_2026-02-03_1430_${CLAUDE_SESSION_ID}.md`)
- AI-facing internal docs: `{PROJECT_ROOT}/docs/adr/ADR-{NNNN}-{slug}.md` and/or an `## Architecture Decisions` section in `{PROJECT_ROOT}/CLAUDE.md`

---

## Entry Point

**When invoked with an explicit doc type** (from `/v`, or user keywords like "api docs", "changelog", "migration guide", "audit docs") — use that type directly. No question.

**Keyword routing** (apply before asking): `api|openapi|endpoint|swagger` → Route 1 · `guide|quickstart|onboarding|faq|user docs` → Route 2 · `audit|review docs|accuracy|completeness` → Route 3 · `changelog|release notes` → Route 4 · `migration|upgrade|breaking change` → Route 5 · `adr|architecture decision|decision record|CLAUDE.md` → Route 6 · `all|full docs suite|everything` → run Routes 1–5 in sequence (Route 6 is on-demand only, not part of "full suite").

**When invoked standalone with no explicit type or keyword AND interactive** (`V_DEPTH == 0` and not headless), ask with `AskUserQuestion` (single call, `multiSelect: false`). The tool allows **max 4 options** — the free-text "Other" it always appends covers changelog / migration / full-suite when not chosen:

```yaml
question: "What documentation do you need?"
header: "Doc Type"
multiSelect: false
options:
  - label: "API documentation"
    description: "OpenAPI spec + reference docs from routes (Route 1)"
  - label: "Public user docs"
    description: "Quick start, guides, FAQ for end users (Route 2)"
  - label: "Audit existing docs"
    description: "Review docs for completeness + accuracy (Route 3)"
  - label: "Changelog or migration guide"
    description: "Release notes from git, or a breaking-change upgrade guide (Routes 4/5)"
```

If the user picks "Changelog or migration guide", disambiguate: breaking changes present in the diff/tags → migration guide (Route 5); otherwise changelog (Route 4). "Full documentation suite" and "ADR / CLAUDE.md maintenance" (Route 6) are reachable via the "Other" free-text answer or their respective keywords — they're deliberately not in the 4-option list since they're rarer asks than the primary four.

**When headless / non-interactive** (`V_DEPTH >= 1`, `HEADLESS_BATCH=1`, or implementation-only): do NOT call `AskUserQuestion`. Infer the doc type from prompt keywords (routing table above); if still ambiguous, default to the narrowest single deliverable the prompt implies (API docs when routes/controllers dominate the context, else a docs audit — Route 3 is read-mostly and safe), and log the inferred choice in the completion message.

---

## Route 1: API Documentation

**Output:** `docs/api/` + `openapi.yaml`

### Extraction Process

```bash
# List all API routes
php artisan route:list --json 2>/dev/null | jq '.[] | select(.uri | startswith("api/"))'

# Find API controllers
ls app/Http/Controllers/Api/ 2>/dev/null
```

Non-Laravel projects: enumerate routes from the framework's router (Express `app.<verb>`, FastAPI decorators, Rails `routes.rb`, etc.). If no router can be enumerated, use the Error Handling fallback below.

### For Each Endpoint, Extract:

1. **Route info:** Method, URI, middleware
2. **Request validation:** From FormRequest classes
3. **Response structure:** From Resource classes or controller returns
4. **Authentication:** From middleware (sanctum, auth:api)

**Context7 (external-API verification only):** when an endpoint documents an integration with a third-party library/SDK (Stripe, Sanctum, etc.), resolve it via `mcp__plugin_context7_context7__resolve-library-id` → `mcp__plugin_context7_context7__get-library-docs` and verify the current API surface before writing examples. Skip Context7 for purely internal endpoints — it is a network call with no payoff there.

Use the Route 1 output skeletons in `${CLAUDE_SKILL_DIR}/references/route-templates.md` for `openapi.yaml` and `docs/api/README.md`.

### Error Handling
- **OpenAPI extraction fails:** If route/controller analysis can't produce a valid OpenAPI spec (no routes detected, unsupported framework), fall back to documenting API endpoints from README, CLAUDE.md, or test files. Note `"api_docs_source": "fallback"` in output.
- **Changelog git history unavailable:** If git log is empty or repo has no tags, generate changelog from current state only with note `"changelog_scope": "current_snapshot"`.

---

## Route 2: Public User Docs

**Output:** `docs/` with user-facing documentation

Use the Route 2 Ask First prompt and output skeletons in `${CLAUDE_SKILL_DIR}/references/route-templates.md`.

### Generate From Code

1. **Quick Start:** Extract from onboarding flow in code
2. **Features:** Extract from routes and UI pages
3. **FAQ:** Generate from common patterns and config
4. **Troubleshooting:** Extract from error handling

### Answer-engine phrasing (FAQ + guide headers)

FAQ and feature-guide content is exactly the shape the library's answer-engine pattern targets
— apply it here, don't reinvent it. Every FAQ/guide H2 or H3 must be phrased as the actual
question a user (or an AI assistant summarizing the page) would ask, with a direct 1-2 sentence
answer immediately under the heading, before any elaboration, examples, or caveats. "How do I
reset my password?" answered in the first sentence, THEN the steps — not a heading followed by
three paragraphs of preamble before the answer shows up. See `~/.claude/skills/v-launch-channels/references/channel-playbooks.md` § Channel 7: AI-Assistant Discoverability (passive, always-on) for the pattern and why it works — cite it, don't restate its rationale here. This applies to `docs/faq.md` and `docs/features/*.md` headings; Quick Start and Troubleshooting stay task-oriented (steps first), not Q&A-shaped.

### Verification

Before writing docs, verify claims against code:

```bash
# Verify feature exists
grep -rn "<feature or page name>" resources/js/Pages --include="*.tsx"

# Verify route exists
php artisan route:list | grep "<route fragment>"

# Verify config value
grep -rn "<config key>" config/
```

**CRITICAL:** Never document features that don't exist in code.

**Route verification:** After generating API docs, cross-check documented routes against actual route files (`routes/web.php`, `routes/api.php`) or `php artisan route:list` output. Flag any documented route that doesn't exist in code, and any undocumented route that should be public.

---

## Route 3: Audit Existing Docs

**Output:** `DOCS_AUDIT_YYYY-MM-DD_HHMM_${CLAUDE_SESSION_ID}.md` with issues and recommendations (report-only — no source is modified).

### Audit Checklist

| Category | Check |
|----------|-------|
| **Completeness** | All features documented? |
| **Accuracy** | Claims match code? |
| **Currency** | Up to date with latest? |
| **DX** | Easy to follow? |
| **Navigation** | Easy to find things? |
| **Examples** | Code samples work? |
| **SEO alignment** | Docs pages match SEO content gaps? |

### Verification Commands

```bash
# Find documented features
grep -rn "## " docs/ --include="*.md" | head -30

# Find all routes (should be documented)
php artisan route:list | wc -l

# Compare features in docs vs code (page filenames rarely match heading text
# verbatim, so a raw `diff` of the two lists is 100% noise — every row differs
# by format alone. Instead, flag pages that have no mention anywhere in docs/):
for f in resources/js/Pages/*.tsx; do
  name=$(basename "$f" .tsx)
  grep -rqi -- "$name" docs/ 2>/dev/null || echo "UNDOCUMENTED PAGE: $f"
done

# (Advisory) cross-reference recent SEO/marketing audit findings if any exist
ls -t .v-ecosystem-review/*.json .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md v-*-prompts/SESSION_*.md 2>/dev/null | head -1
```

Use the Route 3 report skeleton in `${CLAUDE_SKILL_DIR}/references/route-templates.md`. Include only sections with findings and omit empty priority sections. Confidence-label every finding per `_v-review.md`.

---

## Route 4: Changelog Generation

**Output:** `CHANGELOG.md` (auto-generated or appended)

### Changelog Auto-Generation from Git

```bash
# Detect conventional commits format
git log --oneline --decorate | grep -E "feat|fix|refactor|perf|docs|style|test|chore" | head -20

# Detect PR title format (if squash-merged)
git log --oneline | grep -E "#[0-9]+" | head -20
```

Use the Route 4 Ask First prompt and output skeleton in `${CLAUDE_SKILL_DIR}/references/route-templates.md`.

**Programmatic fallback (headless / orchestrator-invoked):** Auto-detect version from the most recent git tag (semver bump), date range from the last tag, and commit format by scanning `git log --oneline -50`.

### Generation Process

1. Extract commits matching specified format
2. Group by type: `feat`, `fix`, `refactor`, `perf`, `docs`, `breaking`
3. Parse issue/PR numbers and link to GitHub if repo detected
4. Generate readable descriptions from commit messages
5. Output to `CHANGELOG.md` (or append to existing with new section — do not rewrite prior entries)

---

## Route 5: Migration Guide

**Output:** `docs/migration/v{version}.md`

### Migration Guide for Breaking Changes

```bash
# Check for version changes
grep -r "version\|VERSION" composer.json package.json 2>/dev/null | grep -v lock
```

Use the Route 5 Ask First prompt and output skeleton in `${CLAUDE_SKILL_DIR}/references/route-templates.md`.

**Programmatic fallback (headless / orchestrator-invoked):** Auto-detect breaking-change type from git diff, source version from the second-most-recent tag, target version from the most recent tag or HEAD.

### Migration Guide Structure

Each guide includes:

1. **What Changed** — Clear summary of breaking change
2. **Why** — Rationale and benefits
3. **How to Migrate** — Step-by-step instructions
4. **Before/After Examples** — Code snippets showing old vs new
5. **Troubleshooting** — Common gotchas and solutions
6. **Timeline** — When old version is deprecated/removed

---

## Route 6: AI-Facing Internal Docs (ADRs / CLAUDE.md Maintenance)

**Output:** `docs/adr/ADR-{NNNN}-{slug}.md` (index/backfill) and/or a dated entry under an `## Architecture Decisions` section in the project's `CLAUDE.md`.

This route is the durable home for internal, AI-facing documentation — content future sessions read (not end users). `/v-plan` writes an ADR at decision-time into whichever of these two locations already exists in the project (see `v-plan/SKILL.md` § Durable ADR routing); this route is for the two cases v-plan doesn't cover: **auditing/backfilling** the ADR log and **establishing** the convention when neither location exists yet.

1. **Detect existing convention:** check for `docs/adr/` (any `ADR-*.md` files) or a `## Architecture Decisions` section in `CLAUDE.md`.
2. **If neither exists and the request is to establish one:** ask (interactive) or default (headless) to `docs/adr/` for a multi-app project, else a `CLAUDE.md` section for a single-app repo. Create the first file/section with an index/template so `/v-plan` has somewhere to append.
3. **If auditing:** cross-check `docs/adr/*.md` entries (or the `CLAUDE.md` section) against actual architectural decisions found in code/git history (major dependency additions, schema redesigns, auth-model changes) that were never recorded. Flag gaps the same way Route 3 flags undocumented features — do not fabricate a decision's rationale if it can't be reconstructed from commit messages or the diff; mark `rationale: unverified — reconstruct from author` instead.
4. **Never duplicate v-plan's schema** — an ADR entry uses the same fields v-plan writes (`status`, `context`, `options`, `decision`, `rationale`, `consequences`); this route only creates the missing home for them or backfills gaps, it doesn't invent a second ADR format.

### Verification Commands

```bash
# Detect existing ADR convention
ls -d docs/adr/ 2>/dev/null && ls docs/adr/*.md 2>/dev/null | wc -l
grep -q "^## Architecture Decisions" CLAUDE.md 2>/dev/null && echo "CLAUDE.md section exists"
```

---

## Quality Rules

1. **Verify against code** - Never document features that don't exist
2. **Use actual values** - Pull limits/config from code, don't guess
3. **Include examples** - Code samples that actually work
4. **Keep updated** - Note when docs need refresh
5. **User-centric** - Write for the reader, not the developer
6. **Cross-reference audits** - Link docs to SEO and marketing audit findings when available
7. **Real timestamps** - `date -u +%Y-%m-%d_%H%M`; never fabricate a date
8. **In-product reachability (Routes 1/2)** — after generating docs, check whether they're
   actually reachable from inside the product: an empty-state CTA, a contextual help link
   near the relevant feature, or in-app search that indexes `docs/`. Docs nobody inside the
   product links to don't get read. Grep for an existing help/docs link
   (`grep -rn "docs\.\|/help\|/docs" resources/js/Pages --include="*.tsx"` or the framework
   equivalent); if none is found, state that explicitly as a gap in the completion message
   (`in_product_surfacing: not_found — recommend adding a docs link to <surface>`) rather than
   silently omitting it. This is a finding to report, not a code change this skill makes itself.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | OpenAPI spec includes endpoints that don't exist in code | Endpoints inferred from convention, not extracted | Step 1 must enumerate actual route definitions; OpenAPI MUST match `routes/*.php` or equivalent verbatim |
| 2 | README claims feature that's behind a feature flag | Feature-flag state not surfaced | If feature is flag-gated (`config/features.php` or similar), README must say "available when X flag enabled", not unconditional |
| 3 | Migration guide for v2 → v3 misses breaking changes that aren't in CHANGELOG | Breaking changes inferred from CHANGELOG only | Cross-reference: CHANGELOG + commit messages with `BREAKING:` prefix + actual API diff between versions |
| 4 | Runbook commands are bash but operator's runtime is Laravel Sail | Project runtime not detected | Detect project runtime (sail/docker/local-php); commands target THAT runtime, not generic bash |
| 5 | Docs claim "auto-deploys on push to main" but no GitHub Actions workflow exists | Deploy claim not verified against config | Every "auto-X" claim must reference the actual config (`.github/workflows/*.yml`, `vercel.json`, etc.) — un-grounded claims drift |
| 6 | API docs leak an internal/admin endpoint or an auth token in an example | Whole route table documented without a public/private filter | Only document routes that are actually public; redact real tokens/keys — use `{token}` placeholders. Never copy a live secret into a sample |
| 7 | Monorepo: docs generated against the wrong package's routes | `PROJECT_ROOT` resolved to the repo root, not the target package | When multiple route files / packages exist, confirm which package the request targets before extracting; state it in the output |
| 8 | Large repo: extraction times out or floods context | Unbounded `grep -r` / `route:list` over a huge tree | Bound scans (`head`, target `docs/` and route files specifically); paginate endpoint docs rather than dumping every route at once |

## Completion Contract (Stop-hook interop)

How this session satisfies the Stop hook depends on how it was invoked and what it wrote:

- **Orchestrator-invoked (`V_DEPTH >= 1`):** `/v` owns pre-flight, agent review, verify-done, and merge. Produce the docs artifacts, emit the Standard Completion Message, and return. Do NOT run gauntlet steps yourself.
- **Standalone (`V_DEPTH == 0`) that wrote a code-classified file** — `openapi.yaml` or any `.yaml`/`.yml`/`.json` (these match the Stop hook's `CODE_EXT_PATTERN`; `.md` does NOT): the session counts as code-changing and owes the gauntlet. The simplest correct path is to route the work through `/v` from the start, which owns the full gauntlet. If completing in place, produce all three artifacts via **fork-safe Bash subprocesses** — NOT the Skill tool (`~/.claude/hooks/enforce-haiku-dispatch.sh` Layer 1 DENIES Skill-tool invocation of `v-pre-flight`/`v-verify-done`/`v-handoff`) and NOT the Agent tool (fork-blocked from this `context: fork` skill, F16):
  - **pre-flight:** `bash ~/.claude/skills/v/references/v-emit-prompt.sh v-pre-flight > "$DISPATCH_FILE"`, then `v-dispatch-subagent.sh --agent v-pre-flight-runner --prompt-file "$DISPATCH_FILE" --mode capture --artifact "$PROJECT_ROOT/PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md"` — `--prompt-file` is MANDATORY (the helper exits 2 without a readable one) **If `v-emit-prompt.sh` exits 10 (F7 stack gate: no gate-bearing stack), do NOT dispatch — the report is already written mechanically; pre-flight is complete.**;
  - **verify-done:** `bash ~/.claude/skills/v/references/v-emit-prompt.sh v-verify-done > "$DISPATCH_FILE2"`, then `v-dispatch-subagent.sh --agent v-verify-done-runner --prompt-file "$DISPATCH_FILE2" --mode capture --artifact "$PROJECT_ROOT/VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md"`;
  - **agent review:** launch an independent reviewer as a `claude -p --agent <reviewer> "…" </dev/null` Bash subprocess producing `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`.

  Docs generation is never "trivial" (the classifier caps at ≤2 files), so the trivial bypass does not apply.
- **Standalone (`V_DEPTH == 0`) markdown-only** (Routes 2/3/4/5 — no `.yaml`/`.json`/code written): the session changed no code. Emit the Standard Completion Message. If the Stop hook then blocks the session with an abandonment message (v-docs is not yet in the hook's report-only escape registry — see follow-up below), write `HANDOFF_${CLAUDE_SESSION_ID}.md` (≥80 bytes, `# Handoff` heading) that NAMES the docs produced and states that no code gauntlet applies. This is the recognized terminal completion record for a no-code session.

> **Follow-up (not fixed here):** Route 3's `DOCS_AUDIT_*_${CLAUDE_SESSION_ID}.md` is genuinely report-only and belongs in `check-review-artifact.sh`'s report-only escape registry (glob-shaped name, like the `v-audit-*` family row) so pure docs-audit runs clean-exit without needing a HANDOFF. That is a hook change (needs its own regression test + BITE_LEDGER) and is out of scope for a skill-only edit.

End every run with the `_v-core.md` § Standard Completion Message (4–5 lines: Status / Artifacts / Findings if audit / Next step). No verbose summaries or banners.

## Idempotency

**Idempotent for the route.** Re-running on the same route produces fresh documentation; output may vary in wording but covers the same surface. Filesystem-mutating: writes docs to the project's docs directory (Route 3 is report-only and mutates nothing but its audit artifact).
