# Scope Passing Mechanism (extracted from _v-core.md)

_Last reviewed: 2026-07-06 (design-language consistency pass)_

## Scope Passing Mechanism

When the orchestrator invokes a skill in **scoped mode**, it passes a file list via the prompt text. The convention:

```
Invoke /v-polish with POLISH_SCOPE:
- resources/js/Pages/Dashboard.tsx
- resources/js/Components/Chart.tsx
```

The receiving skill detects scoped mode by checking whether its invocation prompt contains `POLISH_SCOPE:` or `CHECK_SCOPE:` followed by a file list. Each file is on its own line, prefixed with `- `. Paths are relative to the repo root.

| Variable | Set by | Consumed by | Trigger |
|----------|--------|-------------|---------|
| `POLISH_SCOPE` | Orchestrator (`/v`) | `/v-polish` | UI files (`.tsx`, `.jsx`, `.css`, `.html`, `.vue`, `.svelte`) changed during implementation |
| `CHECK_SCOPE` | Orchestrator (`/v`) | `/v-check` | Medium/Large feature completed (4+ files changed) |

`CHECK_SCOPE` is optional because `/v-check` still supports standalone full-codebase audits. `POLISH_SCOPE` is required because `/v-polish` is a scoped auto-fix primitive, not a standalone audit entry point.

## Scoped Polish Contract

When the orchestrator detects UI file changes (`.tsx`, `.jsx`, `.css`, `.html`, `.vue`, `.svelte`) after implementation, it MUST invoke `/v-polish` in **scoped mode**.

**Scoped mode** means:
1. The orchestrator passes a `POLISH_SCOPE` file list to `/v-polish`
2. **Conflict check:** Before auto-fixing, `/v-polish` reads the most recent `AUDIT_REPORT_*.md` (if one exists). If an audit finding targets the same file:line as a polish finding, the audit finding takes precedence — do not auto-fix the polish finding on that range. Log: `polish_conflict: [file:line], deferred to audit finding [FND-ID]`.
3. `/v-polish` audits ONLY those files (not the full codebase)
4. **Split findings into two buckets:**
   - **safe_auto_fix:** Low-effort, high-confidence changes (color not resolving to a canonical token — bind to the token, light value comes from `[data-theme="light"]`, NEVER add a `dark:` variant per `_v-design.md § Visual Craft Gate` Check 2; missing `aria-label`; missing focus ring; responsive tweaks). Auto-apply these directly.
   - **auto_apply_with_review:** Medium-effort changes (new component creation, animation). Apply automatically with build verification after each batch.
   - **skip_and_log:** High-risk structural changes (major refactoring, UI restructuring). Log in POLISH_PLAN for a future dedicated session.
5. **Apply both safe_auto_fix and auto_apply_with_review findings automatically** — only skip_and_log items are deferred. Volume cap: 15 edits per file per pass.
6. After fixes, `/v-polish` verifies `npm run build` still passes
7. Control returns to the orchestrator, which continues to `/v-pre-flight`

**Standalone mode is not supported for `/v-polish`.**
- If `POLISH_SCOPE` is absent, log `polish_skipped: no_scope_provided` and return immediately.
- For full-codebase UX audits, route to `/v-check` or `/v-audit-orchestrator` (canonical full-audit entry point; the legacy `run-claude-ecosystem-review.sh` shell runner was archived 2026-07-05).

## Scoped Check Contract

When the orchestrator completes a Medium/Large feature implementation, it MUST invoke `/v-check` in **scoped mode** before quality gates.

**Scoped mode** means:
1. The orchestrator passes a `CHECK_SCOPE` file list to `/v-check`
2. `/v-check` audits ONLY those files (not the full codebase) at Standard depth (reads and analyzes each file)
3. Runs Security, Performance, Test Coverage, UX, Tech Debt, Accessibility, and AI/LLM Integration domains on the scoped files
4. Skips SEO, Feature Completeness, and Parallel Deep Analysis (these require full-codebase context)
5. Findings are reported but NOT auto-fixed — P0 findings block the orchestrator from proceeding
6. Control returns to the orchestrator, which continues to `/v-pre-flight`

**Standalone mode** (user invokes `/v-check` directly or `/v` classifies task as Audit):
- Full codebase audit, entry-point questions asked for audit type and depth
- Report is a deliverable for `/v-build` to execute
