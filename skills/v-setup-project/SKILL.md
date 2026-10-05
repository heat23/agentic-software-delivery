---
name: v-setup-project
description: "Use when bootstrapping a new project .claude folder, hooks, settings, skills, or stack-aware rules."
model: sonnet
context: fork
allowed-tools: Read, Write, Bash, Grep, AskUserQuestion
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-setup-project | version: 1.1.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: Orchestration primitive. Most users should only run this when bootstrapping or upgrading a repo's skill setup.

This contract overrides older sections below on conflict.

Follow `_v-core.md` and `_v-exec.md`.

For infrastructure scope, read `~/.claude/skills/references/v-core-owner-managed.md`.
For hook details, read `~/.claude/skills/references/v-exec-hooks.md`.
For reviewer-agent template standards, read `${CLAUDE_SKILL_DIR}/references/agent-templates.md`.
For generated-hook bodies (Step 3), read `${CLAUDE_SKILL_DIR}/references/hook-templates.md`.

Rules:
- detect `jq` before generating jq-dependent hooks
- split templates by stack
- validate generated hooks and generated agent files
- generated review agents are hook-oriented review helpers, not aliases for the corresponding `v-*` skills

```yaml
contract:
  tier: orchestration-primitive
  accepts: [project directory]
  produces: [.claude/ directory with hooks, agents, settings]
  invokes: []
  invoked-by: [/v, user]
  estimated_tokens: 8k-20k
  estimated_duration: 2-5 min
```

# /v-setup-project - Project Bootstrap

Creates `.claude/` directory with hooks, agents, and settings tailored to the project's stack. Designed for the Laravel 13 + Inertia + React + TS + Tailwind v4 stack but adapts to what's detected.

**Usage:** Run `/v-setup-project` in any project directory.

## Skill Boundaries

**SME persona:** This skill is run by a **senior platform engineer** — specialty is bootstrapping a new project's `.claude/` configuration: hooks, agents, skills, settings — so the first `/v` invocation has all the safety rails and project-specific context the AI needs to produce production-quality output from session zero.

### Best fit

- Bootstrapping or upgrading a repo-local `.claude/` environment (hooks, agents, settings, stack-aware `CLAUDE.md` rules) for a project workspace.
- Scaffolding the E2E workflow-testing harness (`playwright.config.ts` + `tests/e2e/`) and Coupling Invariants so the first `/v` run has its safety rails.

### Use instead

- `/v-maintenance` — editing the **global** user-owned skill/hook/settings trees under `~/.claude/`, not creating repo-local bootstrap assets.
- `/interface-design` — installing the shared design system / tokens before UI is scaffolded (this skill only *detects* and *recommends* it; see Step 1.6).
- `/v-check`, `/v-prelaunch-readiness`, `/v-audit-orchestrator` — auditing the code once setup exists (this skill *recommends* the stage-appropriate one in Step 7; it does not run the audit itself).

### Not for

- Editing global (`~/.claude/`) skills/hooks/settings — that is `/v-maintenance`.
- Implementing product features or fixing application bugs — that is `/v` and its build/tdd sub-skills.
- Running the audit itself, or overwriting an existing `.claude/`, `CLAUDE.md`, or `playwright.config.*` (this skill merges/appends only — see Merge Strategy).

Keep generated reviewer agents aligned with `${CLAUDE_SKILL_DIR}/references/agent-templates.md` instead of expanding the main skill body with repeated template prose.

---

### Step 0: Resolve Project Root

Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.

### Step 1: Detect Stack

```bash
# Core stack detection
test -f composer.json && echo "PHP_PROJECT=true"
test -f package.json && echo "NODE_PROJECT=true"
test -f tsconfig.json && echo "TYPESCRIPT=true"

# Framework detection
grep -q "laravel/framework" composer.json 2>/dev/null && echo "LARAVEL=true"
grep -q "inertiajs" package.json 2>/dev/null && echo "INERTIA=true"
grep -q '"react"' package.json 2>/dev/null && echo "REACT=true"
grep -q "tailwindcss" package.json 2>/dev/null && echo "TAILWIND=true"

# Front-end framework variants — consumed by Step 4.5's Playwright webServer table.
# Without these, a Next/Nuxt/SvelteKit project silently falls back to the Laravel
# default (`php artisan serve`) and scaffolds a broken playwright.config.
grep -q '"vue"' package.json 2>/dev/null && echo "VUE=true"
grep -q '"svelte"\|@sveltejs/kit' package.json 2>/dev/null && echo "SVELTE=true"
grep -q '"next"' package.json 2>/dev/null && echo "NEXT=true"
grep -q '"nuxt"' package.json 2>/dev/null && echo "NUXT=true"
# Build script presence (Step 4.5-A frontend trigger + webServer `npm run build`).
grep -q '"build"[[:space:]]*:' package.json 2>/dev/null && echo "BUILD_SCRIPT=true"

# Tool detection
test -f vendor/bin/pint && echo "PINT=true"
grep -q "eslint" package.json 2>/dev/null && echo "ESLINT=true"
grep -q "ziggy" composer.json 2>/dev/null && echo "ZIGGY=true"
test -d database/factories && echo "FACTORIES=true"
test -f .env && echo "DOTENV=true"
test -f playwright.config.ts && echo "PLAYWRIGHT=true"
test -f vendor/bin/infection && echo "INFECTION=true"
test -f node_modules/.bin/stryker && echo "STRYKER=true"

# Mutation testing availability (critical for test quality verification)
if [ ! -f vendor/bin/infection ] && [ ! -f node_modules/.bin/stryker ]; then
  echo "MUTATION_TESTING_MISSING=true"
  echo "WARNING: No mutation testing tool detected. Install Infection (PHP: composer require --dev infection/infection) or Stryker (JS: npm install --save-dev @stryker-mutator/core) for independent test quality verification."
fi

# Existing Claude setup
test -d .claude && echo "CLAUDE_DIR_EXISTS=true"
test -f .claude/settings.json && echo "SETTINGS_EXISTS=true"
test -d .claude/hooks && echo "HOOKS_EXIST=true"
test -d .claude/agents && echo "AGENTS_EXIST=true"
```

---

### Step 1.5: Skill Health Check

Verify that the user's global v-* skills are present and consistent:

```bash
# Check for global skills directory
SKILLS_DIR="$HOME/.claude/skills"
if [ -d "$SKILLS_DIR" ]; then
  echo "Skills directory found: $SKILLS_DIR"
  ls "$SKILLS_DIR"/v-*/SKILL.md 2>/dev/null | wc -l
  ls "$SKILLS_DIR"/_v-*.md 2>/dev/null | wc -l
else
  echo "WARNING: No skills directory at $SKILLS_DIR"
  echo "The v-* skill system requires global skills. See setup instructions."
fi

# Check shared governance files exist
for f in _v-core.md _v-exec.md _v-growth.md _v-review.md _v-design.md; do
  test -f "$SKILLS_DIR/$f" && echo "OK: $f" || echo "MISSING: $f"
done

# Check for stale skill references (customize this list for your installation's retired skills)
# grep -rn "your-retired-skill-name" "$SKILLS_DIR"/*/SKILL.md 2>/dev/null && echo "WARNING: Stale references found"
```

Report any missing or stale skills before proceeding with project setup.

---

### Step 1.6: Design System Check

Check if the project has a design direction established:

```bash
# Check for design system artifacts
test -f .interface-design/system.md && echo "DESIGN_SYSTEM=true" || echo "DESIGN_SYSTEM=false"
test -f .interface-design/motion-language.md && echo "MOTION_LANGUAGE=true"
test -f .interface-design/typography-scale.css && echo "TYPOGRAPHY_SCALE=true"
test -f .interface-design/dark-mode-design.md && echo "DARK_MODE_DESIGN=true"
test -f .interface-design/loading-states.md && echo "LOADING_STATES=true"
test -f .interface-design/performance-budget.md && echo "PERFORMANCE_BUDGET=true"
```

**If DESIGN_SYSTEM=false AND the project has UI files** (React, Vue, Svelte detected):
Recommend installing the shared design system before building UI. Add to the setup options:

```
After setup completes, run `/interface-design` to install the shared SaaS design system
(canonical :root + [data-theme='light'] token blocks, Inter + JetBrains Mono) and generate
the per-product overlay (accent, category pairs, branding, domain components — full section set per `_v-design.md § Per-Product Overlay`; marketing surfaces added later by /v-marketing-design) BEFORE any components are
scaffolded. Takes 5-10 minutes and saves hours of conformance fixes later.
```

**If DESIGN_SYSTEM=true but templates are missing:** list which `.interface-design/` files exist and which are missing. Recommend running `/interface-design` to generate the missing ones (motion-language, loading-states, dark-mode-design, typography-scale, performance-budget).

---

### Step 2: Ask What to Create

```yaml
question: "What should I set up?"
header: "Setup"
options:
  - label: "Full setup (Recommended)"
    description: "Hooks + agents + settings based on detected stack"
  - label: "Hooks only"
    description: "Pre/post tool hooks for quality enforcement"
  - label: "Agents only"
    description: "Specialized reviewer agents for deep analysis"
  - label: "Update existing"
    description: "Add missing items to existing .claude/ setup"
```

If `.claude/` already exists with content, default to "Update existing" and show what's already present vs what's missing.

---

### Step 3: Create Hooks

Create only hooks relevant to the detected stack. Each hook is a bash script in `.claude/hooks/`.

### Universal Hooks (any project with .env)

> **Note:** `.env*` files are allowed to contain secrets and may be committed per project policy
> (see `~/.claude/skills/references/v-core-owner-managed.md`). No secret-scanning hook is created
> for new projects (retired 2026-08-03, owner request). A `block-env-edit.sh` should NOT be
> created either — it would conflict with the current policy.

**detect-secrets-in-write.sh** — RETIRED 2026-08-03 (owner request; `.env*` secrets are policy-allowed). Do NOT create, copy, or register this hook for new projects, and ensure the Step 5 `settings.json` carries NO PreToolUse registration for it — never register a hook path absent on disk (Gotcha 2).

### Stack-specific hooks

Copy the matching hook body from `${CLAUDE_SKILL_DIR}/references/hook-templates.md` (the canonical
source for each body) — create only the ones whose stack was detected in Step 1. All three depend on
`jq`; honor the Error Handling rule if `jq` is absent (write with a `# REQUIRES: jq` header, do not register).

- **ziggy-on-route-edit.sh** (emit when `ZIGGY=true`) — PostToolUse: regenerates Ziggy routes after `routes/*.php` edits.
- **factory-reminder.sh** (emit when `FACTORIES=true`) — PostToolUse: warns when a new `app/Models/*.php` model has no matching factory.
- **lint-on-edit.sh** (emit when `ESLINT=true`) — PostToolUse: runs `eslint --max-warnings=0` on edited `.ts`/`.tsx` files.

---

### Step 4: Create Agents

Create agent prompt files in `.claude/agents/`. Only create agents relevant to the detected stack.

Generate the relevant agent prompt bodies from `${CLAUDE_SKILL_DIR}/references/agent-templates.md`.

### Laravel Agents

- `eager-loading-detective.md`
- `migration-safety-reviewer.md`

### React + TypeScript Agents

- `typescript-strictifier.md`

### Inertia Agents

- `inertia-contract-checker.md`

### Route Agents

- `route-middleware-auditor.md`

### Test Agent

- `test-writer.md`

Only generate the templates that match the detected stack and workflow. The reference file is the canonical source for the body text, "what to find", and output-format contract of each generated agent.

---

### Step 4.5: Scaffold E2E Workflow Testing + Coupling Invariants

This makes every new SaaS app ready for the browser workflow gate (`v-workflow-verifier` in `/v` Step 3.5 + the pre-flight E2E specs gate) and captures the couplings that diff-based review is blind to.

**A. Playwright scaffold (when a frontend is detected — REACT / INERTIA / VUE / SVELTE / NEXT / any `package.json` with a `build` script — AND `PLAYWRIGHT` is false):**

1. Create `tests/e2e/.gitkeep` (the verifier writes committed `*.spec.ts` here).
2. Create `playwright.config.ts` with a **build-then-serve `webServer`** (this stack serves built front-end artifacts — specs MUST run against a fresh build, never stale assets) and a `baseURL`. Default (Laravel + Inertia/Vue/React):

   ```ts
   import { defineConfig, devices } from '@playwright/test';

   const BASE_URL = process.env.APP_URL ?? 'http://localhost:8000';

   export default defineConfig({
     testDir: './tests/e2e',
     fullyParallel: false,
     workers: 1,                          // matches the v-pre-flight single-core cap
     reporter: [['list']],
     use: { baseURL: BASE_URL, trace: 'on-first-retry', screenshot: 'only-on-failure' },
     // Build front-end artifacts BEFORE serving — non-negotiable for this stack.
     webServer: {
       command: 'npm run build && php artisan serve',
       url: BASE_URL,
       reuseExistingServer: !process.env.CI,
       timeout: 120_000,
     },
     projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
   });
   ```

   **Adapt `webServer.command` + `baseURL` to the detected stack:**

   | Stack | `webServer.command` | `baseURL` |
   |---|---|---|
   | Laravel + Inertia/Vue/React | `npm run build && php artisan serve` | `http://localhost:8000` |
   | Next.js | `npm run build && npm run start` | `http://localhost:3000` |
   | Nuxt | `npm run build && npm run preview` | `http://localhost:3000` |
   | SvelteKit | `npm run build && npm run preview` | `http://localhost:4173` |
   | Rails + JS bundler | `npm run build && bin/rails server` | `http://localhost:3000` |

3. Ensure `@playwright/test` is a dev dependency (note it in the report if missing — do NOT auto-install; the user runs `npm i -D @playwright/test && npx playwright install chromium`).
4. If `playwright.config.*` already exists, do NOT overwrite — note it in the report.

**B. Coupling Invariants (append to the project `CLAUDE.md`, never overwrite):**

Append this section if `CLAUDE.md` lacks a `## Coupling Invariants` heading. These are the load-bearing constraints that unit tests and diff-based review cannot see — stating them lets `/v` (and reviewers) respect them and is the cheapest defense against the "fixed here, broke a sibling" class.

```markdown
## Coupling Invariants

Constraints that diff-based review and unit tests cannot see. Fill in per project;
delete the examples. `/v`'s blast-radius step and its reviewers read these.

- <Service> is the ONLY writer for <table/resource> — nothing else mutates it directly.
- Nothing outside <module> may touch <shared resource> (e.g. the session store, auth tokens).
- <Component> is shared by <routes/pages> — a change must be verified against ALL of them.
- <Job/Listener> assumes <invariant> — breaking it corrupts <downstream>.
```

---

### Step 4.6: Seed Stack-Convention Rules (CLAUDE.md)

The skill's charter is "stack-aware rules" — so it MUST seed the project `CLAUDE.md` with the
convention rules for the DETECTED stack, not just Coupling Invariants. Append a
`## Stack Conventions` section **only if `CLAUDE.md` lacks that heading** (check
`grep -q '^## Stack Conventions' CLAUDE.md` first — never overwrite an existing one). Emit only
the blocks whose stack was detected in Step 1; drop the rest.

```markdown
## Stack Conventions

<!-- Laravel (emit when LARAVEL=true) -->
- **Laravel 13:** all config (routes, middleware, exceptions) registered in `bootstrap/app.php`; providers and events are auto-discovered. There is no `Kernel.php`.
- External API calls belong in queued Jobs, never in the request lifecycle. Use Form Requests for validation. Cache expensive operations.
- **Eager-load every relationship** before calling model methods that access it (especially Cashier: `$user->load('subscriptions')` before subscription checks — a user's subscription is `$user->subscription('default')` or the `subscriptions` relation, never a bare `subscription` relation).
- **Hard deletes by default** — do NOT add `SoftDeletes` unless this project's CLAUDE.md explicitly overrides for a named model.
- New columns on existing tables are always nullable or defaulted (never bare `NOT NULL`). Foreign keys: `->constrained()->cascadeOnDelete()` + index. Wrap multi-table writes in transactions.
- Rate-limit all auth endpoints. Webhooks use Cashier's built-in controller/route, not a hand-rolled one.

<!-- React / Inertia (emit when REACT=true or INERTIA=true) -->
- **React/Inertia v2:** config values flow in as props, never hardcoded. Use semantic color tokens for dark mode. Handle loading, empty, AND error states. Use `LoadingButton` for async actions. Deferred props via `Inertia::defer(fn () => …)`; partial-reload-only props via `Inertia::optional(fn () => …)`.
- `dangerouslySetInnerHTML` requires `DOMPurify.sanitize()` with an explicit allowlist — no exceptions.

<!-- Tailwind (emit when TAILWIND=true) -->
- **Tailwind v4:** `@import "tailwindcss"` (not `@tailwind` directives); configuration lives in CSS, not `tailwind.config.js`.

<!-- Testing (always emit) -->
- Server-side validation on all inputs (client-side validation is UX, not security). Never log secrets, even at debug level.
- Tests: use the project's runner (Pest `it()`/`test()` when present). Never weaken assertions to pass. No TODO/FIXME/HACK in delivered code.
```

Report in Step 6 whether the section was appended or already present.

---

### Step 5: Create Settings

Generate `.claude/settings.json` with hook registrations:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          ".claude/hooks/ziggy-on-route-edit.sh",
          ".claude/hooks/factory-reminder.sh",
          ".claude/hooks/lint-on-edit.sh"
        ]
      }
    ]
  }
}
```

Only include hooks that were actually created (based on stack detection). The `PreToolUse`
`detect-secrets-in-write.sh` registration shown in older revisions of this doc is retired
(2026-08-03, owner request) — do not add it back.

---

### Step 6: Report

```markdown
## Setup Complete

### Created
- `.claude/hooks/` — [N] hooks
  - [list each hook and what it does]
- `.claude/agents/` — [N] agents
  - [list each agent and what it does]
- `.claude/settings.json` — Hook registration
- `CLAUDE.md` — `## Stack Conventions` [appended / already present] + `## Coupling Invariants` [appended / already present]

### Stack Detected
- [x] Laravel [version]
- [x] React [version]
- [x] TypeScript
- [x] Tailwind CSS v4
- [x] ESLint
- [x] Ziggy
- [ ] [anything not detected]

### What This Enables
- **Hooks** auto-run on every file edit (lint, static analysis, route regen)
- **Agents** are dispatched by `/v-check`, `/v-verify-done`, and `/v` for deep analysis
- **E2E scaffold** (`playwright.config.ts` + `tests/e2e/`) makes the browser workflow gate (`v-workflow-verifier`) and the pre-flight E2E specs gate runnable from session zero
- **Coupling Invariants** in CLAUDE.md capture constraints diff-based review can't see (feeds Step 1.6 blast-radius + reviewers)

### Skill Health Status
- [status of global v-* skills]
- [status of governance files]
- [any stale references detected]

### Next Steps
- See the stage-appropriate first-audit recommendation below (Step 7) — do not run an audit before that
- Use `/v <description>` for single-step workflows
```

---

### Step 7: First Audit Recommendation

After setup, recommend the initial audit **by project stage** (per Gotcha 4 — the recommendation
MUST match the detected stage, and this must stay consistent with `/v-help`'s "First time on a new
project" guidance):

- **Greenfield / pre-launch** (no deploy, few/no users) → recommend `/v-prelaunch-readiness`
- **Actively in-development** (shipping, has code to audit) → recommend `/v-check` (fast code audit)
- **Launched** (in production, real users) → recommend `/v-audit-orchestrator` (routes specialists + auto-consolidates)

Mark the stage-appropriate option as Recommended in the prompt:

```yaml
question: "Would you like to run an initial audit?"
header: "First Audit"
options:
  - label: "Pre-launch readiness"
    description: "Run /v-prelaunch-readiness — recommended for greenfield / not-yet-launched projects"
  - label: "Quick code check"
    description: "Run /v-check for a fast code audit — recommended for actively-developed projects"
  - label: "Full production audit"
    description: "Run /v-audit-orchestrator (routes specialists + auto-consolidates) — recommended for launched projects"
  - label: "Skip for now"
    description: "I'll audit later"
```

If the user selects an audit, invoke the corresponding skill. The audit will use the agents and hooks just created for deeper analysis.

---

## Completion Contract (Stop-hook awareness)

This skill writes real code-extension files — `.claude/hooks/*.sh`, `.claude/settings.json`,
and (Step 4.5) `playwright.config.ts`. The global Stop hook's `CODE_EXT_PATTERN` matches
`sh`, `json`, and `ts`, and none of these paths are in `CODE_EXT_EXEMPT`. So a **standalone**
`/v-setup-project` run is promoted to `IS_V_SESSION=1` + `CODE_CHANGED=1` and owes a completion
artifact at Stop — the same gauntlet any code-changing session owes. (`CLAUDE.md` is `.md`, which
is NOT a code extension, so an append-only run that touched *only* `CLAUDE.md` does not trip it.)

Resolve, in order of fit:

- **Invoked by `/v`** — `/v` owns the completion contract for the whole workflow. Do nothing extra here.
- **Standalone, generated hooks/config only** — this is scaffolding, not product code, and a brand-new
  project has no meaningful test/build surface to pre-flight. Classify via
  `~/.claude/skills/v/references/v-classify-trivial.sh`; if it accepts, write
  `TRIVIAL_PASS_${CLAUDE_SESSION_ID}.md` at `$PROJECT_ROOT`.
- **Standalone, classifier rejects (large/complex generation)** — run the standard gauntlet against the
  bootstrapped project: `/v-pre-flight` → dispatch agent review → `/v-verify-done`, producing
  `PRE_FLIGHT_REPORT` / `AGENT_REVIEW` / `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md`.

Never strip or fake these artifacts — the Stop hook validates their content, not just their presence.

## Merge Strategy (Update Existing)

When `.claude/` already exists:

1. **Hooks:** Only create hooks that don't already exist (check filenames)
2. **Agents:** Only create agents that don't already exist
3. **Settings:** Merge new hook entries into existing settings.json without overwriting existing entries
4. **Never delete** existing hooks, agents, or settings

---

## Quality Rules

1. **Only create what's detected** — Only create hooks for tools that are installed and detected
2. **Scripts must be executable** — `chmod +x` every hook script
3. **Test hooks work** — Run each hook with a mock JSON input to verify it doesn't error
4. **Respect existing setup** — Never overwrite existing files without asking
5. **Portable paths** — Use relative paths in settings.json, absolute paths nowhere

---

## Error Handling

- **jq not installed:** If `which jq` fails, skip hooks that depend on JSON parsing (secret detection hooks, JSON validation hooks). Generate the hook files with a `# REQUIRES: jq — install with: brew install jq / apt install jq` comment at the top and log `"hooks_skipped": ["secret-detection", "json-validation"], "reason": "jq_not_found"`.
- **Git not initialized:** If the project has no `.git` directory, STOP and ask the user to provide `PROJECT_ROOT` explicitly. Do NOT run `git init` — running it from an unresolved working directory (e.g., `~/.claude/plans/`) would initialize a git repo at the wrong location (potentially the OS home directory). The user must confirm the correct project path before any git operations.
- **Existing .claude directory:** If `.claude/` already exists, do NOT overwrite. Merge new files only, preserving existing CLAUDE.md and custom skills. Log what was preserved vs added.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Setup overwrites existing CLAUDE.md with template | Pre-existence check skipped | Always check `test -f CLAUDE.md` before writing; existing = merge / append, never replace |
| 2 | Hooks installed but never run because `settings.json hooks` field not updated | Hook scripts dropped without config wiring | After any hook script create: append to `settings.json` hooks array; verify hook is reachable |
| 3 | Stack detection misclassifies hybrid projects (Laravel + Inertia + React) | Detection logic too simple | Multi-stack detection: read package.json AND composer.json AND .env.example; hybrid stacks need hybrid CLAUDE.md sections |
| 4 | First-audit recommendation routes to wrong skill | Project-stage detection inverted | Greenfield → v-prelaunch-readiness; in-development → v-check; launched → v-audit-orchestrator |
| 5 | Hook scripts have hardcoded user-specific paths | Generic templates not parameterized | Template variables: `${PROJECT_ROOT}`, `${HOME}`, `${USER}` — never bake operator's path into shipped hook |
## Idempotency

**Idempotent.** Re-running on a configured project is mostly no-op (existing hooks/agents/settings preserved). New additions are merged. Filesystem-mutating: writes to `.claude/`.
