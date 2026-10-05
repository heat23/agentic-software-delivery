---
name: v-check
description: "Use when running a fast multi-dimensional codebase audit across security, performance, UX, and quality."
argument-hint: "[scope or focus area]"
allowed-tools: Read, Glob, Grep, Bash, Write, AskUserQuestion, WebSearch, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-check | version: 1.2.0 | last-updated: 2026-08-12 -->
<!-- line-count exception (~797 body lines vs 500 target, >700 ceiling): already 68% extracted —
     4 reference files carry 1656 lines (gates, domain checklists, output conventions).
     The inline remainder is the load-bearing depth-tiered workflow + Gate 0 exploration
     contract, which fragments badly if split further. Documented-exception route,
     v-anthropic-2026-standards §1 row 6. -->


# 2026 Canonical Contract

Tier: User-facing entry point.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-growth.md`, `_v-review.md`, and `_v-design.md` (for UX/accessibility audits).

**Scope boundary (mandatory):** per `_v-audit.md` § In-App Actionability Boundary (that file explicitly covers `v-check`) — off-stack items (runbooks/ops process, offsite backups, HA/failover/DR, external monitoring/alerting services, CI/CD or DNS/CDN infrastructure, new vendors/tools) never become findings, scores, or prompt packs. Domain 11 (Observability & Monitoring) means **in-repo** structured logging, error handling, and in-app health/alerting code — never external monitoring/APM services. Deferred observations go only to `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` per that section (standalone mode only).

For model routing, read `~/.claude/skills/references/v-core-model-routing.md`.
For error handling, read `~/.claude/skills/references/v-core-error-handling.md`.
For prompt pack generation, read `~/.claude/skills/references/v-core-prompt-pack.md`.
For scope passing, read `~/.claude/skills/references/v-core-scope-passing.md`.
For report templates, read `references/report-templates.md`.

Rules:
- use the shared `FINDING_FORMAT`
- every heuristic finding includes `confidence`
- Domain 11 (Observability) includes the analytics instrumentation-existence triage (are product events tracked at all?) — existence triage only; taxonomy/schema/funnel depth belongs to `/v-audit-analytics` (see `references/audit-domains-extended.md` § Domain 11 — Observability & Monitoring, "Analytics Instrumentation Triage" subsection)
- if instrumentation gaps are found, recommend `/v-audit-analytics`; recommend `/v-audit-growth` only when the broader funnel is under question

Write `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md`. If the selected output format includes JSON, also write `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json`.

Runner contract:
- In headless runner mode, if JSON output is requested, producing the JSON companion file is mandatory, not optional.
- Audit execution is read-only with respect to the repo codebase. Do not edit application, test, config, or docs files during the audit.
- The only allowed writes are the declared audit artifacts: `AUDIT_REPORT_*.md`, optional `AUDIT_REPORT_*.json`, and `.v-prompt-packs/v-check-<MM-DD>/`.
- If you detect an existing fresh report for the current session path, update or replace the audit artifacts instead of writing alternate filenames.

```yaml
contract:
  tier: user-facing
  accepts: [user prompt, CHECK_SCOPE (scoped mode)]
  produces: [AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md, optional AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json when explicitly requested, .v-prompt-packs/v-check-<MM-DD>/ (00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md)]
  invokes: []
  invoked-by: [/v, user, /v-audit-orchestrator]
  estimated_tokens: 30k-100k
  estimated_duration: 5-20 min
```

# /v-check - Comprehensive Audit

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules, `_v-review.md` for findings, and `_v-growth.md` when relevant.

One command to find ALL issues. Interactive depth control, single unified report.

## Skill Boundaries

**SME persona:** This skill is run by a **senior code-quality + release engineer** — specialty is the pre-merge gate. What does a tech lead check before approving a PR? Type safety, lint, test coverage on the diff, security regressions, performance regressions, config drift, dependency hygiene. The skill consolidates 12 quality domains into a single shippable verdict.

### Best fit

- Broad project audits covering security, performance, tests, UX, accessibility, SEO, tech debt, observability, and feature completeness
- Scoped post-implementation audits on changed files when the orchestrator or caller passes `CHECK_SCOPE`
- Situations where the output should be a prioritized report and prompt pack, not immediate code changes

### Use instead

- Use `/v-pre-flight` for build/test/lint/type/security gate execution
- Use `/v-verify-done` for convention checks and AI-specific implementation mistakes
- Use a specialized audit skill when the user needs a deeper business, growth, admin, messaging, analytics, pricing, or SEO workflow (`/v-audit-growth`, `/v-audit-admin`, `/v-audit-messaging`, `/v-audit-analytics`, `/v-audit-sales-pricing`, `/v-audit-seo`)
- Use `/v-audit-code` for comprehensive UX/visual/brand/copy review (absorbed `/v-ui-audit` 2026-07-06; see `~/.claude/skills/v-audit-code/references/deep-ux-audit.md` for the deep UX/a11y mode). v-check is the daily/weekly sweep at lower resolution; v-audit-code is the deep audit. Running both within 14 days is redundant — pick one based on cadence (see `## Cross-Skill Notes` § v-audit-code overlap below).

### Not for

- Replacing maintenance verification (use `/v-maintenance`) or refactor analysis (use `/v-audit-code`, which absorbed `/v-refactor` 2026-07-06 — see `~/.claude/skills/v-audit-code/references/refactor-modernization.md` for the DEBT_TREND register and SaaS-arch shapes). Launch-readiness is in-scope (Domain 12), not a sibling skill — see the v-ship retirement note below
- Forcing a full-codebase audit when the current session only needs a scoped changed-file review
- Auto-fixing findings directly inside the audit skill

**Note:** `/v-ship` was retired 2026-04-29 — its `.env*` config-validation domain merged into v-check as Domain 12. Operational readiness checks (monitoring setup, payment provider config, runtime HSTS deployment verification, backups, queue automation) were dropped per project-stage focus; they will return as a separate skill when projects scale past initial traction. Static security-header config checks — including HSTS — remain live in Domain 1 (see `references/v-security-baseline.md` § Headers). See `references/audit-domains-extended.md` § Domain 12 for the merged config-validation scope.

## Invocation Modes

v-check has two modes. The mode is determined automatically based on how it is invoked.

### Standalone Mode (user invokes `/v-check` directly or `/v` classifies as Audit)

- Full codebase audit across all domains (1-12)
- Asks entry-point questions for audit type and depth
- Writes AUDIT_REPORT with prioritized findings
- Generates `.v-prompt-packs/v-check-<MM-DD>/` — a `00-README.md` map plus flat `.txt` wave packs (per `~/.claude/skills/references/v-runnable-pack-convention.md`)
- Does NOT auto-fix — the report is a deliverable for `/v-build` to execute (or use prompt files for parallel sessions)

### Scoped Mode (orchestrator invokes after Medium/Large feature implementation)

Triggered when the orchestrator sets `CHECK_SCOPE` — a list of changed files from the current session.

**Scoped mode rules:**
1. **Skip the entry-point questions** — auto-select Standard depth scoped to changed files only, Full audit type
2. **Only audit the files in `CHECK_SCOPE`** — do NOT grep the full codebase
3. **Run all applicable domains** — Security, Performance, Test Coverage, UX, Tech Debt, Accessibility, AI/LLM Integration (domain 8), Observability & Monitoring (domain 11), Config Validation (domain 12) on the scoped files — i.e. every domain marked `Scoped? Yes` in the Audit Domains table below
4. **Skip domains that require full-codebase context** — SEO (domain 7), Feature Completeness (domain 9), Parallel Deep Analysis (domain 10) are skipped in scoped mode
5. **Report findings but do NOT auto-fix** — findings go into the AUDIT_REPORT for the developer to review
6. **P0 findings block completion** — if any P0_CRITICAL findings are found in scoped mode, the orchestrator must fix them before proceeding
7. **Return control to orchestrator** — do not recommend `/v-build` as next step (the orchestrator continues to `/v-pre-flight`)

**Detecting scoped mode:** At the start of the workflow, check if the invoking context provided a `CHECK_SCOPE` file list. If yes → scoped mode. If no → standalone mode.

**Scoped mode workflow:**
1. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
2. Read each file in `CHECK_SCOPE`
3. For each file, run the applicable audit checks from domains 1-6, 8, 11, 12 (only checks relevant to that file type — `.php` files get Security/Performance/Test Coverage, `.tsx` files get UX/Accessibility/Tech Debt, etc.; `.env*` files get Domain 12)
4. Collect all findings into P0/P1/P2 buckets
5. Write `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` with:
   - `mode: scoped`
   - `files_audited:` list of files checked
   - `findings:` all findings organized by priority
6. Show completion banner

## Output

File: `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md`
Prioritized P0/P1/P2 findings with evidence and actionable fixes.
Use Context7 to verify security best practices for detected stack.

If JSON output was requested, write the same audit to `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json` using the shared finding schema.

## Workflow (Standalone Mode)

Ask questions -> Detect stack -> Run audit domains -> Write file with findings -> Show completion banner.

### Pre-existing Finding Baseline (Standalone Mode Only)

When running standalone on a dirty tree (>30 uncommitted files), pre-existing issues dominate the report. Before running audit domains, snapshot the baseline by checking for recent `AUDIT_REPORT_*.md` files (any session). If a prior audit exists within 7 days, load its findings and mark any finding that matches a prior finding (same file, same category, ±5 lines) as `pre_existing: true`. Newly-introduced findings get `pre_existing: false` and should be prioritized higher in the report.

---

## Entry Point

**V_DEPTH parsing (mandatory):** Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Search for `[V_DEPTH=N` or `V_DEPTH=N` in the prompt. Default to 0 if absent.

**When to skip entry-point questions:**
- `V_DEPTH >= 1` (orchestrator invoked):
  - If `CHECK_SCOPE` is provided → scoped mode on those files (existing behavior).
  - If `CHECK_SCOPE` is NOT provided → **auto-detect changed files and use scoped mode.** Run the worktree-aware changed file detection from `~/.claude/skills/references/v-core-changed-files.md` to build the scope automatically. This prevents full-codebase audits when the orchestrator forgot to pass CHECK_SCOPE. Full audits from the orchestrator are wasteful — use the ecosystem review runner or specialist audit skills for comprehensive coverage.
  - If auto-detection finds zero changed files (fresh branch, no commits), skip the audit entirely and report: `audit_skipped: no_changed_files_detected`. Do NOT fall back to a full-codebase audit — that's wasteful when the orchestrator context indicates scoped work.
- Explicit parameters provided (e.g., `CHECK_SCOPE`, audit type, or depth keyword in the invocation context) → use those parameters directly.

**When V_DEPTH == 0 AND no explicit parameters**, ask using AskUserQuestion:

```yaml
question: "What kind of audit do you need?"
header: "Audit Type"
options:
  - label: "Full audit (Recommended)"
    description: "Security + Performance + Tests + UX — comprehensive check."
  - label: "Security focused"
    description: "Prioritize security, include others at surface level."
  - label: "Performance focused"
    description: "Prioritize speed/scaling, include others at surface level."
  - label: "Test coverage deep dive"
    description: "Thorough test quality + gap analysis."
```

A fast P0-only pre-launch scan isn't a listed option — type "pre-launch quick scan" via the
free-text "Other" response, or pass `--quick` on the invocation, to get a fast P0-only check
for critical blockers instead of the full multi-domain audit.

**Output format:** Markdown by default. Pass `--format=json` to write a parallel JSON output for downstream tooling and consolidation workflows.

**Depth (interactive only):** When V_DEPTH == 0 and `--depth=` is not in the invocation prompt, ASK via AskUserQuestion — never silently auto-derive:

```yaml
question: "How deep should this audit go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Standard (Recommended)"
    description: "Read key files, identify patterns, full multi-domain audit. Default for most check runs. ~5-15 min."
  - label: "Quick"
    description: "Grep-only scan, no file reads. Surface-level smoke check; misses pattern issues. ~2-3 min."
  - label: "Thorough"
    description: "Read all in-scope files, cross-reference, full pattern analysis. Use for pre-launch audits or test-coverage deep dives. ~15-45 min."
```

When V_DEPTH >= 1 (orchestrator-invoked or headless), use the explicit `--depth=` from the invocation prompt; if absent, derive from audit-type (Quick scan → quick; Test coverage deep dive → thorough; all others → standard). If `--depth=quick|standard|thorough` is passed, skip the question.

---

## Cross-Skill Notes

- **Polish overlap:** If `/v-polish` ran this session (dual-search: `.v/artifacts/POLISH_PLAN_*${CLAUDE_SESSION_ID}*.md` first, bare-root `POLISH_PLAN_*${CLAUDE_SESSION_ID}*.md` as legacy fallback) AND this v-check run is scoped mode over the same changed files, skip UX domain (4) and Accessibility domain (6) — polish already audited and auto-fixed those dimensions. The skip does NOT apply to full-codebase (standalone) runs: v-polish is scoped-only, so a diff-scoped polish pass never covers a whole-repo domain 4/6 audit. Exception either way: Domain 4's copy-accuracy check (UI text matches behavior) still runs — v-polish's 21 dimensions don't cover it. Mark as `domain_skipped: covered_by_v-polish` in the report. Security, performance, test coverage, and feature completeness domains still run.
- **v-audit-code overlap (HARD RULE, absorbed v-ui-audit 2026-07-06):** Before running, parse the override flag and detect a recent `/v-audit-code` report.

  **Step 1 — flag parser (mandatory):**

  ```bash
  # Detect the override flag from the invocation prompt. The skill receives the operator's
  # raw prompt as $INVOCATION_PROMPT (or argv); search for the literal flag.
  IGNORE_RECENT_UI_AUDIT=0
  case "${INVOCATION_PROMPT:-$*}" in
    *--ignore-recent-ui-audit*) IGNORE_RECENT_UI_AUDIT=1 ;;
  esac
  ```

  **Step 2 — detect recent report (skipped when override is set):**

  ```bash
  RECENT_UI_AUDIT=""
  if [ "$IGNORE_RECENT_UI_AUDIT" -eq 0 ]; then
    RECENT_UI_AUDIT=$(find "$PROJECT_ROOT" -maxdepth 1 -name "AUDIT_CODE_REPORT_*.md" -mtime -14 -exec ls -t {} + 2>/dev/null | head -1)
  fi
  # The skip is only valid if the report's deep-UX mode ACTUALLY ran: v-audit-code loads
  # deep-ux-audit.md on demand (deep UX / a11y / WCAG requests only), so a refactor- or
  # production-readiness-focused AUDIT_CODE_REPORT never covered domains 4/6/7. Key on the
  # modes_loaded header stamp (v-audit-code SKILL.md § Output). The bare-'WCAG' fallback
  # applies ONLY to pre-stamp legacy reports — a stamped report saying modes_loaded: none
  # or refactor must NOT validate the skip just because a contrast finding mentions WCAG
  # (the always-on UX-craft lens cites WCAG thresholds on any pass).
  if [ -n "$RECENT_UI_AUDIT" ]; then
    if grep -qiE 'modes_loaded:' "$RECENT_UI_AUDIT" 2>/dev/null; then
      grep -qiE 'modes_loaded:.*deep-ux' "$RECENT_UI_AUDIT" || RECENT_UI_AUDIT=""
    else
      grep -qi 'WCAG' "$RECENT_UI_AUDIT" || RECENT_UI_AUDIT=""
    fi
  fi
  ```

  **Step 3 — apply skip rule:** if `RECENT_UI_AUDIT` is non-empty (audit within 14 days):

  | Domain | v-check action | Mark as |
  |---|---|---|
  | 4 (UX & Copy) | Skip — v-audit-code's deep-UX pass covers at higher resolution | `domain_skipped: covered_by_v-audit-code` |
  | 6 (Accessibility) | Skip — v-audit-code's deep-UX pass covers (see `~/.claude/skills/v-audit-code/references/deep-ux-audit.md`) | `domain_skipped: covered_by_v-audit-code` |
  | 7 (SEO triage) | Defer — v-audit-code's dedicated pass covers | `domain_skipped: see_v-audit-code` (also append the existing "For full SEO analysis, run `/v-audit-seo`" note from Domain 7's contract) |
  | 1, 2, 3, 5, 8, 9, 10, 11, 12 | Still run — not v-audit-code overlap | (no skip) |

  Console summary at session start (mandatory — do NOT swallow): print to stderr so the operator sees it even if stdout is captured:

  ```bash
  if [ -n "$RECENT_UI_AUDIT" ]; then
    >&2 echo "[v-check] Recent v-audit-code detected: $RECENT_UI_AUDIT"
    >&2 echo "[v-check] Skipping Domains 4, 6, 7 (covered by v-audit-code)."
    >&2 echo "[v-check] Override: pass --ignore-recent-ui-audit to force full re-audit."
  fi
  if [ "$IGNORE_RECENT_UI_AUDIT" -eq 1 ]; then
    >&2 echo "[v-check] Override active: --ignore-recent-ui-audit — running all domains."
    # Log in audit_metadata.overrides[] when writing the report.
  fi
  ```

  **Audit report Scope section (mandatory — first H2 in the report so it cannot be missed):**

  ```markdown
  ## Scope
  - **Covered:** [list of domain numbers and names]
  - **Deferred to v-audit-code:** [list, with link to recent report path] (none if --ignore-recent-ui-audit set)
  - **To force full re-audit:** pass `--ignore-recent-ui-audit`
  ```
- If `/v-audit-code` was run within the last 7 days (check `AUDIT_CODE_REPORT_*.md` file age), tech debt and dependency findings may overlap with its absorbed refactor-modernization lens — focus on security, performance, test coverage, and feature completeness domains instead of re-discovering refactoring items. (Legacy `REFACTOR_PLAN_*.md` files from a pre-2026-07-06 `/v-refactor` run may also exist on disk — treat them the same way if found.)
- Check for existing `AUDIT_CODE_REPORT_*.md` (or legacy `REFACTOR_PLAN_*.md`) files and reference their findings rather than duplicating.

### Delta Mode (Previous Audit Comparison)

Before writing findings, check for a previous audit report. Use unfiltered glob here intentionally — delta mode compares across sessions:
```bash
# Intentionally session-agnostic: delta mode compares against ANY previous audit
ls -t .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md 2>/dev/null | head -2
```

If no prior audit found, skip Delta section entirely. Log: `delta_mode: skipped, reason: no_prior_audit`.

If a previous report exists:
1. Read it to extract previous finding IDs and files
2. In the new report, add a `## DELTA` section showing:
   - **Resolved:** Findings from last audit that no longer appear (improvements!)
   - **New:** Findings not in the previous report
   - **Persistent:** Findings that remain from last audit
   - **Regressed:** Previously resolved findings that reappeared
3. This helps solo founders track progress across audit cycles

## Audit Domains

**Reference:** Read `${CLAUDE_SKILL_DIR}/references/audit-domains.md` (domains 1-5) and `${CLAUDE_SKILL_DIR}/references/audit-domains-extended.md` (domains 6-11) for detailed detection patterns, grep commands, and checklists for each domain.

**Reference:** Read `~/.claude/skills/v-check/references/v-security-baseline.md` for the security policy baseline these audits enforce (auth middleware, authorization policies, input validation, secrets management, headers, monitoring).

**Pre-launch / greenfield handling (read before auditing — prevents day-0 false-noise).** Detect stage cheaply: pre-launch if `git rev-list --count HEAD 2>/dev/null` is low (≈<50 commits) OR there is no production deploy/`.env` and no revenue/user signal. On a pre-launch project, domains whose findings only make sense against a live/deployed/populated product emit `status: "n/a — pre-launch"` instead of findings and are excluded from any floor: **Domain 7 (SEO)** — skip unless an unauthenticated public route beyond `/`,`/login`,`/register` exists; **Domain 9 (Feature Completeness)** — report missing features as an informational "not-yet-built roadmap" list, never P1/P2 findings; **Domain 3's coverage-% check** — report test-infra presence, not a percentage. NEVER manufacture a finding to satisfy a floor — an empty domain on a day-0 product is correctly-absent, not a defect (`v-core-severity.md`). Security, config, architecture, and data-integrity domains run normally: those matter most before first deploy.

| # | Domain | Priority | Scoped? | Key Focus |
|---|--------|----------|---------|-----------|
| 1 | Security | Always P0 | Yes | Auth gaps, injection, XSS, CSRF, secrets, CORS, CSP |
| 2 | Performance | P0-P1 | Yes | N+1 queries, lazy loading violations, unbounded queries, bundle size |
| 3 | Test Coverage | P0-P1 | Yes | Pass rate, coverage %, missing test files, critical paths |
| 4 | UX & Copy | P1-P2 | Yes | Empty states, loading states, error messages, theme-token conformance |
| 5 | Tech Debt | P1-P2 | Yes | TODOs, dead code, TypeScript `any`, config drift |
| 6 | Accessibility | P1 | Yes | WCAG 2.2 AA: aria-labels, keyboard nav, contrast, focus |
| 7 | SEO (triage) | P1-P2 | No (full only) | **Triage domain** per `~/.claude/skills/references/v-core-audit-ownership.md`. Lightweight surface checks (missing meta tags, broken structured data). **Core Web Vitals are NOT statically analyzable** — v-check cannot measure LCP/INP/CLS from source; it only points the operator to a runtime tool (see Domain 7 § Core Web Vitals in `references/audit-domains-extended.md`). Does NOT produce SEO-prefixed finding IDs or implementation guidance — append "For full SEO analysis, run `/v-audit-seo`" to findings. Canonical depth owned by `/v-audit-seo`. |
| 8 | AI/LLM Integration | P0-P2 | Yes | API key safety, cost tracking, rate limiting, PII |
| 9 | Feature Completeness | P1-P2 | No (full only) | Backend patterns, frontend patterns, team/billing features |
| 10 | Parallel Deep Analysis | — | Full only | Agent-assisted review per `_v-review.md` protocol |
| 11 | Observability & Monitoring | P1-P2 | Yes | Structured logging, error tracking, performance monitoring, alerting |
| 12 | Config Validation (.env*) | P0-P1 | Yes | `.env*` mismatches with `.env.example`, missing required env vars, wrong values (`APP_DEBUG=true` in prod stub, dev URLs in prod), stale vars |

**Scoped mode skips:** SEO (7), Feature Completeness (9), and Parallel Deep Analysis (10) — these require full-codebase context.

**Note on Domain 12 (Config Validation):** added in 2026-04-29 when `/v-ship` was retired. The config-mismatch / missing-value / wrong-value subset migrated to v-check. Operational-readiness checks from `/v-ship` (monitoring setup, payment provider config, runtime HSTS deployment verification, backups, queue worker automation) were dropped — they're not relevant at the operator's pre-production project-stage focus; static security-header config checks including HSTS remain in Domain 1 (`references/v-security-baseline.md` § Headers). Will return as a separate skill when projects scale past initial traction.

### Domain 10: Agent Dispatch (Summary)

Discover available agents from `.claude/agents/` (project) or `~/.claude/agents/` (global). Do not assume specific agent names exist — dispatch whatever agents are found by relevance, as fork-safe `claude -p` subprocesses via `~/.claude/skills/v/references/v-dispatch-subagent.sh --agent <name> --mode capture` (NOT the Agent tool — this skill runs `context: fork`; nested Agent dispatch fails silently). Always add `codex-adversarial-reviewer` when `codex-adversarial-reviewer.md` exists in `.claude/agents/` (project) or `~/.claude/agents/` (global) — dispatch is mandatory. See `${CLAUDE_SKILL_DIR}/references/audit-domains.md` for full dispatch protocol.

### Agent Dispatch Fallback (Mandatory per _v-review.md)

Per `_v-review.md` § Agent Dispatch Protocol, three outcomes are valid:

| Outcome | Condition | Action |
|---------|-----------|--------|
| **DISPATCHED** | Agent file found, CLI available, agent ran | Merge findings into report |
| **SKIPPED-GRACEFULLY** | Agent file found, CLI unavailable | Log `agent_dispatch: skipped`, invoke `superpowers:requesting-code-review` via Skill tool as **MANDATORY FALLBACK** |
| **NOT-APPLICABLE** | Agent file not found in either directory | Log `agent_dispatch: not_applicable`, invoke `superpowers:requesting-code-review` via Skill tool as **MANDATORY FALLBACK** |

In both fallback cases: skipping review entirely is never acceptable. After fallback review:
1. Self-review all P0/P1 findings against `_v-review.md` FINDING_FORMAT rules
2. Reduce confidence to `medium` for any pattern-match-only findings (no runtime evidence)
3. Log the outcome in the audit metadata

### Depth Modifiers

| Mode | Reading Depth | Dependency Audit | P2 Items |
|------|--------------|------------------|----------|
| Thorough | Read ALL files, cross-reference (per shared depth semantics) | Full | Include |
| Standard | Sample top 20% of files by relevance (per shared depth semantics) | Basic | Include |
| Quick | Grep-only, no file reads (per shared depth semantics). v-check narrows to P0 issues only. | Skip | Skip |

**Quick mode is NOT exempt from Verification Gates 0/1 (below).** "No file reads" means the Gate 0 per-dim exploration block's `Files read:` field is legitimately empty/`none` for Quick mode — it does NOT mean the exploration block, citation requirement, or evidence discipline are skipped. Grep output IS the evidence: every finding still needs a parseable `path:line` (Gate 1), sourced from `grep -n`. Because no file was opened to rule out a false match (commented-out code, a string literal, a test fixture), cap `confidence` at `medium` for any Quick-mode finding — never `high` — regardless of the domain's default.

### Audit Order

Always audit in this order (security first): Security → Performance → Test Coverage → UX → Tech Debt → Accessibility → SEO → AI/LLM Integration → Feature Completeness → Parallel Deep Analysis → Observability & Monitoring → Config Validation.

### Already-Configured Detection

Before recommending infrastructure changes, check `.env`, config files, and middleware first. Report detected items as **verified**, not missing. See `${CLAUDE_SKILL_DIR}/references/audit-domains.md` for specific detection patterns.

---

## Verification Gates

**Apply Gates 0, 1, 2, and 8 from `~/.claude/skills/references/v-audit-gates.md` before declaring the audit complete.**

| Gate | What it enforces | Why v-check needs it |
|---|---|---|
| Gate 0 | Subagents emit a per-dim exploration block (files read, greps run, verifications done) + orchestrator runs a 2-citation hallucination spot-check per subagent | v-check is the most-frequently-run audit. Without Gate 0, fabricated findings (`SQL injection at app/Services/UserService.php:142` where line 142 doesn't contain SQL) can ship straight into AUDIT_REPORT and downstream into v-build. |
| Gate 1 | Every finding has a parseable path:line citation; findings without one are dropped | The FND finding format already uses `file: [path:line]` notation. Gate 1 makes the parseability rule explicit and dropping mandatory rather than discretionary. |
| Gate 2 | Per-dim minimum-findings floor with mandatory re-task before auto-justify | Floors for v-check live in `~/.claude/skills/references/v-audit-floors.md` § `## v-check floors (provisional)`. |
| Gate 8 | File-existence verification before methodology emits "phase ran" claims | v-check produces AUDIT_REPORT.md and (when standalone) `.v-prompt-packs/v-check-<MM-DD>/`. Methodology must verify both via Glob before claiming the run completed. |

### Per-dim exploration block (Gate 0 contract for subagents)

Every Domain N subagent return MUST include:

```markdown
## Per-dim exploration

### Domain {N} — {name}
- **Files read:** `path1`, `path2`, ... (full reads, not glances)
- **Greps run:**
  - `grep -rn "pattern" {dir}/` → N hits, key result line: "..."
- **Verifications done:**
  - "Verified Route::fallback exists in routes/web.php:42"
```

Returns missing this block are rejected and re-tasked with: *"Your return omitted the per-dim exploration block. Re-investigate Domain {N}: list every file you read, every grep you ran, and every verification you performed. Then re-submit findings."*

The orchestrator then picks 2 random `path:line` citations per subagent's findings and verifies the cited line actually contains content matching the finding's description. 1-of-2 mismatch → re-task; 2-of-2 mismatch → drop the entire return as fabricated.

#### Scoped mode (no subagents)

In Scoped mode the orchestrator runs Domain checks directly against `CHECK_SCOPE` files — no subagent dispatch. Gate 0 still applies: the **orchestrator** emits its own per-dim exploration block (one block covering ALL scoped domains together, since the orchestrator is the single executor). Format:

```markdown
## Per-dim exploration (scoped mode)

### Scoped run — domains {1,2,3,...} on {N} files
- **Files in CHECK_SCOPE:** `path1`, `path2`, ... (full list)
- **Files actually read:** `path1`, `path2`, ... (subset that produced findings or required deep verification)
- **Greps run (per domain):**
  - Domain 1 (Security): `grep -rn "pattern" {dir}/` → N hits
  - Domain 2 (Performance): `grep -rn "pattern" {dir}/` → N hits
  - ...
- **Verifications done:** "Confirmed lazy-loading guard in app/Models/User.php:42", ...
```

The 2-citation hallucination spot-check still runs in scoped mode — orchestrator picks 2 random findings and verifies the cited lines. Same rejection semantics: 1-of-2 mismatch → re-investigate; 2-of-2 mismatch → drop the affected domain's findings.

**Why universal:** the discipline of citation verification matters most in scoped mode, where the runner is operating on a small file set and finding density is naturally lower — fabricated findings stand out less and are easier to ship by accident.

### Citation parseability (Gate 1 contract for findings)

Every finding's `file: [path:line]` reference must match the regex `[A-Za-z0-9._/-]+\.[a-z]+:[0-9]+` (single line) or `[A-Za-z0-9._/-]+\.[a-z]+:[0-9]+-[0-9]+` (range). Findings without parseable line numbers are **dropped** — not reported at Low severity. This matches v-audit-code's citation rule (carried over from the absorbed v-ui-audit's v3.8.5 rule).

---

## Output Format

Include only sections with findings. Omit empty priority sections (P0/P1/P2) if none exist.

**`overall_score` (honest definition — it was previously an undefined placeholder).** Compute it, don't invent it: start at 100, subtract **P0 −25, P1 −15, P2 −5** per in-scope finding (exclude `n/a — pre-launch` domains), floor at 0 — a 0-100 scale. Zero findings = 100. It is advisory context for the human reader; `v-audit-consolidate` derives the canonical PASS/NEEDS-WORK/BLOCK from finding counts (any P0 → BLOCK), not from this number, so do not add a separate verdict field.

```markdown
# AUDIT_REPORT
generated: [ISO_DATE]
report_status: generated
stack: laravel/[react|livewire|blade]
audit_type: [full|security|performance|quick]
depth: [thorough|standard|quick]

## EXECUTIVE_SUMMARY

### Critical Findings (P0)
- [count] security issues requiring immediate fix
- [count] data integrity risks

### Important Findings (P1)
- [count] performance issues
- [count] test coverage gaps

### Polish Items (P2)
- [count] UX improvements
- [count] tech debt items

## FINDINGS

### P0_CRITICAL
<!-- Omit this section entirely if no P0 issues found -->

#### FND-001: [Issue Title]
file: [path:line]
type: [security | performance | growth | ux | test-coverage | accessibility | seo | docs | tech-debt | completeness | other]
severity: critical
confidence: high
issue: |
  [What's wrong]
evidence: |
  [Code snippet or grep output]
fix: |
  [Specific fix with code]
test: |
  [How to verify the fix]

### P1_IMPORTANT
<!-- Omit this section entirely if no P1 issues found -->

#### FND-002: [Issue Title]
file: [path:line]
type: [security | performance | growth | ux | test-coverage | accessibility | seo | docs | tech-debt | completeness | other]
severity: high
confidence: medium
issue: |
  [What's wrong]
impact: |
  [Performance impact]
fix: |
  [Specific fix]

### P2_POLISH
<!-- Omit this section entirely if no P2 issues found -->

#### FND-003: [Issue Title]
...

## VERIFIED_GOOD

Items checked that are correctly implemented:
- [x] CSRF protection active
- [x] Redis caching configured
- [x] Rate limiting on auth routes
- [x] ...

## IMPLEMENTATION_ORDER

Execute fixes in this order:
1. FND-001 (highest-severity blocker)
2. FND-002 (next highest user or security risk)
3. FND-003 (highest-leverage follow-up)
...

## NEXT_STEPS

Audit complete. To implement fixes:
1. Review findings for accuracy
2. Start new session for fresh context
3. Run: `/v-build AUDIT_REPORT_[timestamp].md` → `/v-pre-flight` → `/v-verify-done`

Estimated effort:
- P0 fixes: [X items]
- P1 fixes: [X items]
- P2 fixes: [X items]
```

---

## JSON Output Format (when Markdown + JSON selected)

In addition to the Markdown report, save a companion JSON file: `{repo_path}/AUDIT_REPORT_YYYY-MM-DD_HHMM_${CLAUDE_SESSION_ID}.json`

Structure:
```json
{
  "audit_metadata": {
    "project_name": "...",
    "audit_date": "ISO date",
    "audit_type": "v-check",
    "stack": "...",
    "depth": "thorough|standard|quick",
    "total_findings": N,
    "by_priority": {"P0": N, "P1": N, "P2": N},
    "overall_score": 85
  },
  "findings": [
    {
      "id": "FND-001",
      "priority": "P0|P1|P2",
      "category": "security|performance|growth|ux|test-coverage|accessibility|seo|docs|other",
      "title": "...",
      "description": "Detailed description of the issue",
      "severity": "critical|high|medium|low",
      "confidence": "high|medium|low",
      "files_affected": [
        {"path": "relative/path/to/file.php", "lines": [42, 43]}
      ],
      "test_first": "Test to write before fixing (TDD)",
      "implementation": {
        "approach": "How to fix this",
        "changes": ["Step 1", "Step 2"]
      },
      "verification": "How to verify the fix works",
      "effort_hours": N
    }
  ],
  "verified_good": ["CSRF protection active", "..."]
}
```

This JSON format is compatible with the ecosystem review runner — it can use this as input to generate parallelized implementation prompts.

---

## Generate Parallel Session Prompts (Standalone Mode Only)

After writing the AUDIT_REPORT, generate copy-pasteable prompt files — one per session, ready to paste into a new Claude session with zero editing.

**Per `~/.claude/skills/_v-audit.md § Step 3: Prompt Generation Contract`** — `_v-audit.md` explicitly covers `v-check` (per its own line 5 "Shared boilerplate for `v-audit-*` and `v-check` skills"). Follow that contract end-to-end. Dispatch parameters specific to `v-check`:

- `model: "sonnet"`
- `timeout: 600000` (10 min — larger codebases produce longer subagent runs)
- `PROMPT_DIR=".v-prompt-packs/v-check-$(date +%m-%d)"`
- Include the three algorithm sections below (`### Build the File Dependency Graph`, `### Assign Sessions`, `### Write Individual Prompt Files` — corresponding to `_v-audit.md` Steps 3a/3b/3c) verbatim in the briefing file — the subprocess has no access to this skill file, so paste the algorithm text into the briefing, do NOT reference these section headers.

**CRITICAL: Prompt generation MUST run in a separate subagent with a fresh context.** By this point the main context has consumed 100k+ tokens on audit domains; inline generation will truncate or skip files. If the dispatch helper or `claude` CLI is unavailable, skip prompt generation and note `prompt_generation: skipped, reason: subprocess_dispatch_unavailable` in the audit report.

**Pre-dispatch shell setup** (run before dispatching the subprocess):

**`/v` first-line requirement:** every pack file (excluding `00-README.md`) MUST be a flat `.txt` file whose line 1 is the literal `/v ` prefix (the orchestrator routing prefix) — the unified wave form per `~/.claude/skills/references/v-runnable-pack-convention.md` § Canonical form, NOT the deprecated `NN-*.md` shape. Files that do not start with `/v ` are rejected by the post-generation validator and the pack will fail. The dispatched subagent must produce paste-ready files: operator copy-pastes the entire file content into a fresh `/v` session with zero edits required.

```bash
PROMPT_DIR=".v-prompt-packs/v-check-$(date +%m-%d)"

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

**After the subagent completes, self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate** (or run `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/$PROMPT_DIR"`), then `run-v-packs "$PROMPT_DIR" --dry-run` to confirm the wave plan resolves. On failure, re-dispatch the subagent once with the failure messages as context. On second failure, report `VALIDATION_FAILED` in the audit artifact under `## Prompt Pack`.

### Build the File Dependency Graph

1. **Extract file targets** — for every finding, list every file it touches (both files to modify and test files to create) from the `files_affected` field.
2. **Build a conflict graph** — two findings conflict if they share any file target.
3. **Cluster connected components** — findings that share files (directly or transitively) must go in the same session.
4. **Handle dependencies** — if finding A depends on finding B, they must be in the same session (or A's session must be marked as "run after B's session").

### Assign Sessions

Group the clusters into sessions using these domain groupings (merge or split based on file dependency graph):

1. **Security session** — Domain 1 (Security) + Domain 8 (AI/LLM Integration) findings. Auth, injection, XSS, CSRF, secrets, API key safety.
2. **Performance session** — Domain 2 (Performance) + Domain 11 (Observability) findings. N+1 queries, lazy loading, bundle size, structured logging.
3. **Quality session** — Domain 3 (Test Coverage) + Domain 5 (Tech Debt) findings. Missing tests, dead code, TypeScript `any`, config drift.
4. **UX & Accessibility session** — Domain 4 (UX & Copy) + Domain 6 (Accessibility) findings. Empty states, loading states, WCAG, theme-token conformance.
5. **SEO & Completeness session** — Domain 7 (SEO) + Domain 9 (Feature Completeness) findings. Technical SEO, backend/frontend patterns. (Core Web Vitals are runtime-only — see the Domain 7 note; v-check emits a Lighthouse/PSI pointer, not a measured CWV finding.)

Session rules:
1. **Size each session at 15-40 estimated hours.** If a session has fewer than 3 findings, merge it into the most related session.
2. **Theme each session** — give it a descriptive name based on the dominant domain.
3. **Order findings within each session** by priority (P0 first), then by effort (smallest first).
4. **Sort sessions** by priority of their highest-priority finding.

Aim for 3-5 sessions total.

### Write Individual Prompt Files

Create a directory `.v-prompt-packs/v-check-<MM-DD>/` in the project workspace. Write the wave-form tree per `~/.claude/skills/references/v-runnable-pack-convention.md` § Canonical form — flat `.txt` packs, one per session, plus one `99-verify.txt`:

```
.v-prompt-packs/v-check-<MM-DD>/
  00-README.md              ← Overview, session map, dependency notes (the ONLY .md)
  security.txt              ← Security + AI/LLM (wave 0 — copy-paste ready)
  performance.txt           ← Performance + observability (wave 0)
  quality.txt                ← Test coverage + tech debt (wave 0)
  ux-accessibility.txt      ← UX + accessibility (wave 0)
  seo-completeness.txt      ← SEO + feature completeness (wave 0)
  w1-pre-flight.txt         ← closing wave: READ-ONLY, runs the project's full quality gates
  w1-review.txt             ← closing wave: READ-ONLY, dispatches adversarial/second-opinion + relevant reviewer agents
  w2-hardening.txt          ← closing wave: sequential, triages w1 findings, fixes CRITICAL/HIGH, re-runs gates, runs /v-verify-done
  99-verify.txt             ← read-only final verification pack (always last)
```

Sessions are independent domain clusters touching disjoint files, so per the convention's wave-assignment rule (§ Wave assignment) they are ALL wave 0 (no prefix) unless the file-dependency graph built above proves an actual conflict/dependency between two sessions — in that rare case, prefix the dependent one `w1-`, `w2-`, etc. **Closing waves (mandatory per `v-runnable-pack-convention.md` § Closing waves):** after the last implementation wave, append `w<N>-pre-flight.txt` + `w<N>-review.txt` as a parallel READ-ONLY verification wave at the next wave number (each carries `## Goal`/`## Checks`/`## Acceptance` only — no `## Files`, no "leave staged" line), then a single sequential `w<N+1>-hardening.txt` that triages the verification findings, fixes CRITICAL/HIGH, re-runs gates, and runs `/v-verify-done`. Always append the closing `99-verify.txt` read-only pack last (re-asserts every session landed via cheap greps + the project's quality gate). Reflect the closing waves in the 00-README.md wave-map table like any other pack.

**00-README.md** must include:
- Project name, audit date, total findings, estimated total hours
- Any exclusions applied
- Wave/session map table: `| Pack | Wave | Domains | Findings | Est. Hours | Can Parallel? |` — every name in this table MUST have a matching file on disk and vice versa (no phantom/orphan packs)
- Dependencies between sessions (most sessions are independent; security should run first if auth changes affect other domains)
- Post-merge quality gate commands from CLAUDE.md

**Each session pack (`security.txt`, `performance.txt`, etc.)** contains ONLY the prompt — the entire file is what gets pasted into a new session — and MUST carry the full body schema from `v-runnable-pack-convention.md` § Pack body schema, in order: `## Goal` · `## Context` · `## Files` (literal H2, REQUIRED — every file to touch; v-build's scope guard keys on this exact heading) · `## Changes` · `## Acceptance criteria` · `## Tests` · `## Constraints` · `## Dependencies`:

**Security-bearing pack clause (mandatory, per `v-runnable-pack-convention.md` § Security-bearing packs):** `security.txt` (Domain 1 Security + Domain 8 AI/LLM Integration findings — auth gaps, injection, XSS, CSRF, secrets, API key safety) always qualifies. Inline this exact sentence into that pack's `## Constraints` section: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session." Apply the same test to any other domain pack whose findings happen to touch request signing/HMAC/webhook verification, credential handling, host/URL construction from variables, auth/authz decisions, or payment flows (e.g. a performance.txt finding that touches a webhook handler) — inline the identical sentence there too.

```markdown
/v Fix the following audit findings for [Project Name].

## Goal
[1-3 sentences: the outcome and why, tied to the domain(s) this session covers]

## Context
Read the project's CLAUDE.md first for architecture context, conventions, and quality gate commands.
Tech stack: [brief tech stack from orientation].
Domains covered: [Security, Performance, etc.]
Priority range: [P0-P1 / P1-P2]

### Finding 1: [FND-ID] [Title] (P0, Xh est.)
**Domain:** [security / performance / etc.]
**Problem:** [description]
**Evidence:** [file:line + proof, inlined — never "see the audit JSON"]

### Finding 2: [FND-ID] [Title] (P1, Xh est.)
...

## Files
- [path] — [what changes]
- [path] — [what changes]

## Changes
Work through findings in order. For each: write a failing test first (TDD), implement the change, verify the test passes, then move to the next.
- [FND-ID]: [specific changes — for security include exact validation rules; for performance include query optimizations; for UX include exact component changes; for accessibility include exact ARIA attributes]

## Acceptance criteria
- [ ] [FND-ID] fixed and verified: [verification steps from finding.verification.acceptance_criteria]
- [ ] ...

## Tests
- [test to write before each fix, from finding.test_first — full spec: setup, assertions, file path]

## Constraints
Read the project's CLAUDE.md first. Follow existing conventions; do not regress other domains.

## Dependencies
Wave 0. Requires: none.

## After All Fixes
Run the full verification suite:
\```bash
[project-specific quality gate commands from CLAUDE.md]
\```

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

**Prompt writing rules — CRITICAL: extract from JSON, do not summarize:**
- Start with `/v` so the orchestrator routes automatically
- **For each finding, EXTRACT the following fields directly from the audit JSON** — do not summarize or paraphrase:
  - `[FND-ID]` and `[Title]` → from `finding.id` and `finding.title`
  - `[Xh est.]` → from `finding.effort_hours`
  - `[description]` → from `finding.description` (full text, not abbreviated)
  - `[paths]` → from `finding.files_affected[].path` with line numbers
  - `[test to write]` → from `finding.test_first` (full test specification including setup, assertions, file path)
  - `[specific changes]` → from `finding.implementation.approach` + `finding.implementation.changes[]` (exact code changes, not vague)
  - `[verification steps]` → from `finding.verification.commands[]` and `finding.verification.acceptance_criteria[]`
  - `[evidence]` → from `finding.evidence[]` (include proof so the implementing agent understands WHY the fix is needed)
- If the JSON finding has a `growth_hook`, include all four fields: target_metric, success_event, instrumentation, readout_trigger
- Completely self-contained — no references to other session files, the audit report, or `00-README.md`
- The richer the detail extracted from JSON, the better the implementing agent performs. Vague prompts like "fix the security issue" waste tokens on re-analysis.

---

## Output Format (Scoped Mode)

```markdown
# AUDIT_REPORT_[timestamp]: [PROJECT] (scoped)
generated: [DATE]
report_status: generated
mode: scoped
audit_type: full (scoped to changed files)
depth: standard (scoped)

## SCOPE
files_audited:
  - [file1.php]
  - [file2.tsx]

## EXECUTIVE_SUMMARY (Scoped Mode)

### Critical Findings (P0)
- [count] issues requiring immediate fix

### Important Findings (P1)
- [count] issues to address

### Polish Items (P2)
- [count] minor improvements

## FINDINGS (Scoped Mode)

### P0_CRITICAL
<!-- Omit if none -->

#### FND-001: [Issue Title]
file: [path:line]
type: [security | performance | growth | ux | test-coverage | accessibility | seo | docs | tech-debt | completeness | other]
severity: critical
confidence: high
issue: |
  [What's wrong]
evidence: |
  [Code snippet]
fix: |
  [Specific fix]

### P1_IMPORTANT
<!-- Omit if none -->

### P2_POLISH
<!-- Omit if none -->

## VERIFIED_GOOD (Scoped Mode)
- [x] [Items checked that are correctly implemented in scoped files]

## SUMMARY
- Files audited: [N]
- P0 findings: [N]
- P1 findings: [N]
- P2 findings: [N]
```

---

## Mandatory Execution Workflow (FOLLOW THIS ORDER)

| Step | Action | Gating Rule |
|------|--------|-------------|
| 0 | Parse V_DEPTH, detect standalone vs scoped mode | — |
| 1 | Ask entry-point questions (standalone + V_DEPTH==0 only) | Skip if V_DEPTH≥1 or scoped mode |
| 2 | Run audit domains 1-12 (standalone) or 1-6,8,11,12 (scoped) | — |
| 3 | Write `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` | MUST exist before Step 4 |
| 4 | **MUST USE SUBAGENT — NOT OPTIONAL.** Dispatch a fork-safe `claude -p` subprocess (`v-dispatch-subagent.sh --model sonnet --mode self-write`, timeout: `600000` — NOT the Agent tool, which fails silently from `context: fork`) to generate `.v-prompt-packs/v-check-<MM-DD>/` with 00-README.md + flat `.txt` wave packs (one per session, `99-verify.txt` last). Copy the full algorithm (Build File Dependency Graph, Assign Sessions, Write Individual Prompt Files, Prompt writing rules) verbatim into the briefing file — the subprocess has NO access to this skill file. | Standalone mode only. Skip in scoped mode. |
| 5 | Self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate (or `~/.claude/scripts/validate-audit-prompt-packs.sh ".v-prompt-packs/v-check-$(date +%m-%d)"`), then `run-v-packs "$PROMPT_DIR" --dry-run`. On failure, re-dispatch once with the failure messages. | MUST pass or report failure in artifact |
| 6 | Present summary: finding counts by priority, session count, prompt directory path | — |

**Steps 4-5 are NOT optional in standalone mode.** The prompt files are the primary deliverable — they enable parallel fix sessions. Skipping them defeats the purpose of the audit.

## Quality Rules

1. **Evidence required** - Every finding needs file:line or grep output (Quick mode included — grep output IS the evidence; see Depth Modifiers)
2. **No false positives** - Verify before reporting
3. **Actionable fixes** - Include specific code, not just descriptions
4. **Prioritized correctly** - Security always P0. Severity assignment follows `~/.claude/skills/references/v-core-severity.md` (canonical P0-P3 scale + critical/high/medium/low mapping). Severity is absolute, not relative to any prior audit's rating — re-raise a mis-rated finding (e.g. a domain table entry rated lower than its true impact) at the correct severity; a prior lower rating never suppresses it.
5. **Acknowledge good** - List what's done right in VERIFIED_GOOD
6. **Check infrastructure first** - Don't recommend what's already configured

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Full-codebase audit when orchestrator was supposed to scope it | `CHECK_SCOPE` env var not passed by orchestrator | Auto-detect changed files via `~/.claude/skills/references/v-core-changed-files.md` when CHECK_SCOPE absent — never default to full codebase |
| 2 | Findings duplicate those from a specialist audit (v-audit-seo, v-audit-messaging, etc.) | Triage domain pollution — v-check should triage, not deep-dive | Triage findings stay surface-level; always append "For full analysis, run `/v-audit-X`" — full SEO/messaging/etc work belongs in specialist skills |
| 3 | Config-validation domain (Domain 12) flags `.env` settings that are intentional | No allowlist mechanism for project-specific overrides | Operator can mark exceptions in `.claude/v-check-allowlist.md`; otherwise expect Domain 12 to flag any deviation from defaults |
| 4 | Re-running v-check overwrites prior findings without audit trail | Each run produces fresh AUDIT_REPORT but no diff vs prior | Prior audits live alongside; diff `AUDIT_REPORT_*.md` files manually OR use `--diff-prior` flag if implemented |
| 5 | Security findings reported but project's actual threat model differs | v-check uses generic security baseline | Read project's `~/.claude/skills/v-check/references/v-security-baseline.md` for the tailored threat model; v-check defaults to OWASP-basics, project may need stricter |

## Idempotency

**Idempotent.** Re-running on the same scope produces a fresh AUDIT_REPORT. Pure read of project state — no filesystem mutations. Findings vary as project state changes.
