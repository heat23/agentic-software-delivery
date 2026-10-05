---
name: v-bug-hunt
description: "Use when adversarially hunting bugs and edge/boundary cases: critical flows, race conditions, broken UX, empty/max, DST, currency, unicode, pagination, concurrency."
argument-hint: "[target subsystem or flow, e.g., 'auth', 'checkout', 'onboarding'] [--lens=bugs|boundaries]"
allowed-tools: Read, Glob, Grep, Bash, Write, AskUserQuestion, WebSearch, TaskCreate, TaskUpdate, mcp__plugin_playwright_playwright__browser_navigate, mcp__plugin_playwright_playwright__browser_navigate_back, mcp__plugin_playwright_playwright__browser_click, mcp__plugin_playwright_playwright__browser_type, mcp__plugin_playwright_playwright__browser_fill_form, mcp__plugin_playwright_playwright__browser_press_key, mcp__plugin_playwright_playwright__browser_take_screenshot, mcp__plugin_playwright_playwright__browser_snapshot, mcp__plugin_playwright_playwright__browser_console_messages, mcp__plugin_playwright_playwright__browser_network_requests, mcp__plugin_playwright_playwright__browser_tabs, mcp__plugin_playwright_playwright__browser_wait_for, mcp__plugin_playwright_playwright__browser_handle_dialog, mcp__plugin_playwright_playwright__browser_evaluate
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-bug-hunt | version: 1.3.2 | last-updated: 2026-08-12 -->
<!-- SIZE: ~870 body lines vs a 500-line target / 700-line ceiling. Only 2 reference
     files (505 lines) — 63% of the content is still inline, so real extraction
     headroom remains (the per-lens hunt procedures are the obvious candidates).
     Treated as an open compression task, not a blessed exception. Recorded
     2026-08-02 (ecosystem audit). v-anthropic-2026-standards §1 row 6. -->


# 2026 Canonical Contract

Tier: comprehensive (specialist adversarial audit). User-invocable. Read-only. Does NOT ship fixes — produces a report and a prompt pack only.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-audit.md`, and `_v-review.md`.

For the audit-skill opener, see `_v-audit.md` § Audit Skill Opener.
For model routing, read `~/.claude/skills/references/v-core-model-routing.md`.
For prompt pack generation, read `~/.claude/skills/references/v-core-prompt-pack.md`.
For scope passing, read `~/.claude/skills/references/v-core-scope-passing.md`.
For the operator cheat sheet (when to run, invocation, severity rubric, report read-order, fix workflow), see `${CLAUDE_SKILL_DIR}/references/quick-reference.md`.

Rules:
- one **TARGET subsystem per invocation** — operator picks a flow / surface; the skill does NOT do a full-codebase pass (v-check already covers that ground)
- use the shared `FINDING_FORMAT` from `_v-review.md`
- every finding includes `confidence` AND a paste-runnable `repro` block (commands, URL sequence, or Playwright trace path)
- findings without a parseable `path:line` citation are dropped, never reported as Low
- zero findings is a **valid outcome** — do not invent findings to demonstrate effort
- UI claims require browser evidence (Playwright MCP) or the `UNVERIFIED-UI` tag
- this skill is **read-only** with respect to the repo: never edit application, test, config, or docs files; fixes go into the prompt pack for `/v-build` to execute

Write `.v/artifacts/BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir; readers dual-search, root is a legacy fallback). If `--format=json` is requested, also write `.v/artifacts/BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json`. `[timestamp]` = `$(date +%Y-%m-%d_%H%M)`, captured ONCE at Step 0 — the `.md` and `.json` must share the identical timestamp.

```yaml
contract:
  tier: comprehensive
  accepts: [user prompt, BUG_HUNT_TARGET (one subsystem or flow), optional V_DEPTH, optional lens (bugs|boundaries, default bugs)]
  produces: [BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md, optional BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json, .v-prompt-packs/v-bug-hunt-<MM-DD>/ (00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md)]
  invokes: []
  dispatches: up to 8 parallel dimension subagents (bugs lens) or up to 9 (boundaries lens)
  invoked-by: [/v, user, /v-audit-orchestrator]
  estimated_tokens: 50k-200k
  estimated_duration: 12-45 min
```

**Two lenses, one skill (merged 2026-07-05):** `lens: bugs` (default) is this skill's original
end-to-end behavioral-defect audit (8 dimensions, below). `lens: boundaries` is the former
`/v-edge-hunt` skill's boundary-condition audit (9 dimensions: empty/max/DST/currency/
unicode/pagination/state-machine/concurrency/entitlement), now `references/boundaries-lens.md`
— archived to `~/.claude/archive/skills-merged-2026-07-05/v-edge-hunt/`. Select with
`--lens=boundaries` or `--lens=bugs` in the invocation args; if absent, infer from keywords in
the prompt (`"edge case"`, `"boundary"`, `"DST"`, `"currency"`, `"proration"`, `"unicode"`,
`"pagination"`, `"state machine"`, `"entitlement"`, `"quota"`, `"seat cap"` → `boundaries`;
otherwise `bugs`). If still ambiguous and interactive, ask once alongside the depth question
(§ Step 2). Both lenses write the SAME `BUG_HUNT_REPORT_*` artifact (§ Output Format) with a
`lens:` metadata field — there is no separate `EDGE_HUNT_REPORT_*` artifact anymore.

# /v-bug-hunt — Adversarial End-to-End Defect Audit

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules, `_v-audit.md` for audit-skill opener, and `_v-review.md` for findings.

One command to adversarially exercise a target subsystem end-to-end and surface real bugs — broken flows, race conditions, silent failures, state desync, swallowed exceptions, AI-generated abstractions hiding broken intent — that pattern-grep audits miss.

## The mandate (read this first, every time)

You are running as a **senior backend engineer + senior QA engineer + skeptical support engineer** combined. The premise:

> **"Tests passing is a weak signal, not proof. The code was AI-generated. Real bugs are still in there. Find them by trying to break the app, not by re-reading code."**

This means three things in particular:

1. **Trace flows, don't grep patterns.** Take the golden path of the target subsystem (e.g., "user signs up, verifies email, connects an integration, sees first dashboard data") and walk every branch — happy, sad, hostile. Pattern audits live in `/v-check`; this skill earns its keep by tracing what `/v-check` cannot.

2. **Be hostile.** Multi-tab the same form. Click submit twice. Refresh mid-flow. Hit the back button after a destructive action. Open the page via direct URL with stale session. Submit with the DOM stripped. Submit with the JS framework crashed. Throttle the network. Kill the queue worker mid-job. Real users do all of these.

3. **Be skeptical of AI-flavored abstractions.** AI-generated full-stack code has tells: try/catch blocks that swallow exceptions into a generic "Something went wrong", helper services that exist but are never wired in, validators that pass through unsafely, UI that renders before data is loaded, retries that compound failures, and tests that mock the thing being tested. Surface these as findings with evidence.

When in doubt, ask: **would a hostile QA engineer with prod outage scars on their resume let this ship?** If no — it's a finding.

## Skill Boundaries

**SME persona:** This audit is run by a **senior full-stack engineer + senior QA engineer + skeptical support engineer**. Specialty is reading interface code AND exercising the running app for behavioral defects: race conditions, state desync, silent failures, hostile-user paths, broken error surfaces, and the "looks-fine-passes-tests-breaks-in-prod" distinction. Knows that test suites catch regressions and code review catches structure — but real production defects live in user-flow seams and hostile inputs that nobody wrote a test for.

### Best fit

- Adversarial deep-pass on a specific subsystem (auth, billing, onboarding, checkout, async pipelines) before launch
- AI-generated codebases where the user does NOT trust "tests pass" as proof of correctness
- Post-incident hardening: a real bug shipped, operator wants to know what other latent bugs are similar
- Pre-launch sweep on a single revenue-critical or data-critical flow
- Manual-simulation work where browser automation (Playwright MCP) is available

### Use instead

- `/v-check` — for fast multi-domain codebase audit across security/perf/test-coverage/tech-debt. v-bug-hunt is the deeper, narrower, hostile companion that runs AFTER v-check on a specific target.
- `/v-pre-flight` — for build/test/lint/type/security gate execution. v-bug-hunt does not run tests; it tries to break the app.
- `/v-verify-done` — for convention checks (TS any-ban, DOMPurify on dangerouslySetInnerHTML, page-contract drift). v-bug-hunt finds behavioral bugs, not convention violations.
- `/v-audit-code` — for comprehensive UX/visual/brand/copy/accessibility review (absorbed `/v-ui-audit` 2026-07-06; see `~/.claude/skills/v-audit-code/references/deep-ux-audit.md` for the deep UX/a11y mode). v-bug-hunt focuses on broken behavior, not visual quality.
- `/v-prelaunch-readiness` — for the public-surface readiness gate (marketing pages, legal, blocking-presence checks). Run v-bug-hunt separately on each critical flow before launch — prelaunch-readiness does not invoke it.
- Boundary-condition audits (empty/max values, DST and date math, currency/proration, unicode, pagination limits, state-machine invalid transitions, concurrency, entitlement boundaries) are the **`boundaries` lens of this same skill** (`/v-bug-hunt <target> --lens=boundaries`) — not a separate skill since the 2026-07-05 merge of the former `/v-edge-hunt`. Run the boundaries lens AFTER the default `bugs` lens on the same target; it treats this skill's own prior `BUG_HUNT_REPORT` as baseline (§ Cross-Skill Notes).

### Not for

- Full-codebase audit across all subsystems — pick a target. If the operator truly wants a sweep across everything, run `/v-check` first; then run `/v-bug-hunt` per target subsystem.
- Auto-fixing findings inside this skill — the report is the deliverable; fixes happen in `/v-build` via the generated prompt pack.
- Performance benchmarking — use load tests and APM tools, not this skill.
- Security penetration testing — use `/v-check` Domain 1 baseline + a real pentest skill, not this skill.

## Invocation Modes

v-bug-hunt has two modes. The mode is determined automatically based on how it is invoked.

### Standalone Mode (user invokes `/v-bug-hunt` directly or `/v` classifies as Bug Hunt)

- Asks for the target subsystem if not in args (one subsystem per session — never a full-codebase pass)
- Asks for depth (Quick / Standard / Thorough)
- Runs all 8 dimensions on the chosen target
- Writes BUG_HUNT_REPORT with prioritized findings
- Generates `.v-prompt-packs/v-bug-hunt-<MM-DD>/` — a `00-README.md` map plus flat `.txt` wave packs (per `~/.claude/skills/references/v-runnable-pack-convention.md`) for `/v-build` to execute
- Does NOT auto-fix

### Orchestrator Mode (V_DEPTH >= 1 — operator-chained)

- Reads `BUG_HUNT_TARGET` from invocation args; if absent, falls back to the most recently changed feature area detected via `~/.claude/skills/references/v-core-changed-files.md`
- Skips entry-point questions; defaults to Thorough depth
- Skips prompt-pack generation (the orchestrator handles fix routing)
- Returns control with the report path

**Detecting orchestrator mode:** Parse V_DEPTH at startup. V_DEPTH >= 1 → orchestrator mode.

## Output

File: `$PROJECT_ROOT/.v/artifacts/BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir)
Prioritized P0/P1/P2/P3 findings with evidence, repro, and a fix sketch (NOT the fix itself — fixes are emitted in the prompt pack).

If JSON output was requested, write the same audit to `$PROJECT_ROOT/.v/artifacts/BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json` using the shared FINDING_FORMAT_JSON schema.

## Workflow (Standalone Mode)

Audit opener -> Target selection -> Lens selection -> Depth selection -> Stack detection -> Compose with prior audits -> Run dimensions (8 for `bugs`, 9 for `boundaries` — the latter also runs a critic dispatch pass per `references/boundaries-lens.md § Critic Dispatch substitutions` before the prompt pack) -> Write report -> Dispatch prompt-pack subagent -> Validate -> Show completion banner.

**Audit opener:** see `_v-audit.md` § Audit Skill Opener.

### Compose with prior audits (mandatory pre-step)

Before running dimensions, check for recent reports that overlap with this skill:

```bash
# `sort -r` on filenames only picks the newest report if the filename encodes a
# lexicographically-sortable timestamp. AUDIT_REPORT_*/AUDIT_CODE_REPORT_* do (they embed
# [timestamp]/[YYYY-MM-DD]-[HHMM]), but PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md is
# SID-only (no timestamp — see v-pre-flight SKILL § MANDATORY FINAL ARTIFACT) — a UUID
# sorts arbitrarily, so `sort -r` could silently select a stale report over a newer one.
# Select by true mtime everywhere instead (`find -exec ls -t` batches all matches into
# one `ls -t` call, which sorts by mtime descending — portable on macOS/Linux, unlike
# `find -printf` which is GNU-only).
RECENT_VCHECK=$(find "$PROJECT_ROOT" -maxdepth 2 -name "AUDIT_REPORT_*.md" -mtime -14 -exec ls -t {} + 2>/dev/null | head -1)
# AUDIT_CODE_REPORT_* absorbed v-ui-audit's report (2026-07-06) — written at $PROJECT_ROOT
# root, not under audits/.
RECENT_UI_AUDIT=$(find "$PROJECT_ROOT" -maxdepth 1 -name "AUDIT_CODE_REPORT_*.md" -mtime -14 -exec ls -t {} + 2>/dev/null | head -1)
# The cosmetic-UX skip is only valid if the report's deep-UX mode ACTUALLY ran (v-audit-code
# loads deep-ux-audit.md on demand). Key on the modes_loaded header stamp; bare-'WCAG' is the
# fallback ONLY for pre-stamp legacy reports (mirrors v-check's overlap gate).
if [ -n "$RECENT_UI_AUDIT" ]; then
  if grep -qiE 'modes_loaded:' "$RECENT_UI_AUDIT" 2>/dev/null; then
    grep -qiE 'modes_loaded:.*deep-ux' "$RECENT_UI_AUDIT" || RECENT_UI_AUDIT=""
  else
    grep -qi 'WCAG' "$RECENT_UI_AUDIT" || RECENT_UI_AUDIT=""
  fi
fi
RECENT_PRE_FLIGHT=$(find "$PROJECT_ROOT" -maxdepth 2 -name "PRE_FLIGHT_REPORT_*.md" -mtime -7 -exec ls -t {} + 2>/dev/null | head -1)
# Lens ordering (2026-07-05 merge): when running the boundaries lens, check for a recent
# BUG_HUNT_REPORT from a prior bugs-lens pass on the SAME target so its P0/P1 aren't
# re-surfaced from the boundary angle. Grep `target:` inside candidate reports rather than
# trusting filename alone — the filename carries only a timestamp, not the target string.
RECENT_BUG_HUNT_OTHER_LENS=""
if [ "$LENS" = "boundaries" ]; then
  for _cand in $(find "$PROJECT_ROOT/.v/artifacts" "$PROJECT_ROOT" -maxdepth 2 -name "BUG_HUNT_REPORT_*.md" -mtime -14 -exec ls -t {} + 2>/dev/null); do
    if grep -qE "^target:[[:space:]]*${TARGET}([[:space:]]|$)" "$_cand" 2>/dev/null && grep -qE "^lens:[[:space:]]*bugs" "$_cand" 2>/dev/null; then
      RECENT_BUG_HUNT_OTHER_LENS="$_cand"
      break
    fi
  done
fi
```

| Prior report present | v-bug-hunt action |
|---|---|
| Recent `/v-check` AUDIT_REPORT | Read it. Treat its P0/P1 security/performance findings as **baseline known issues** — do NOT re-surface them as v-bug-hunt findings. Build on top. |
| Recent `/v-audit-code` report (`AUDIT_CODE_REPORT_*.md`) | Skip cosmetic UX findings (covered there). Focus on broken behavior + flow. |
| Recent `/v-pre-flight` PRE_FLIGHT_REPORT | Read it. If pre-flight is failing, STOP and tell the operator to fix gates first — bug-hunt against a broken tree is wasted effort. |
| Recent `BUG_HUNT_REPORT` from the `bugs` lens on the SAME target (boundaries-lens runs only) | Read it. Treat its P0/P1 as baseline; do not re-surface from the boundary angle — add boundary-specific findings only. |

Console summary at session start (print to stderr):

```bash
if [ -n "$RECENT_VCHECK" ]; then
  >&2 echo "[v-bug-hunt] Recent v-check detected: $RECENT_VCHECK"
  >&2 echo "[v-bug-hunt] Treating its P0/P1 findings as baseline; will not re-surface."
fi
# PRE_FLIGHT_REPORT writes `status: pass|fail` (frontmatter) and `Overall Status: PASS|FAIL` (terminal line) — match BOTH forms, never "status: failed"
if [ -n "$RECENT_PRE_FLIGHT" ] && grep -qE '^status:[[:space:]]*fail[[:space:]]*$|Overall Status:[[:space:]]*FAIL' "$RECENT_PRE_FLIGHT" 2>/dev/null; then
  >&2 echo "[v-bug-hunt] PRE_FLIGHT_REPORT is FAILED. Bug-hunting a broken tree is wasted effort."
  >&2 echo "[v-bug-hunt] Fix pre-flight first, then re-invoke v-bug-hunt."
  exit 1
fi
```

---

## Entry Point

**V_DEPTH parsing (mandatory):** see `_v-audit.md` § V_DEPTH Parsing.

### Step 1 — Target subsystem (always required)

The operator chooses ONE target. Never do a full-codebase pass.

If `BUG_HUNT_TARGET=<name>` is in the invocation args, use it. Otherwise ask via AskUserQuestion:

```yaml
question: "Which subsystem should we hunt bugs in?"
header: "Target"
multiSelect: false
options:
  - label: "Auth & session"
    description: "Login, logout, password reset, email verification, session expiry, RBAC, route guards. ~15-30 min."
  - label: "Onboarding / first-run flow"
    description: "Sign-up to first-success path: account creation, setup wizard, initial data load. ~20-40 min."
  - label: "A specific feature flow"
    description: "Pick one CRUD/transactional flow (you'll name it). Best signal-to-noise. ~15-45 min."
  - label: "Background async pipeline"
    description: "Jobs, queues, scheduled tasks, retries, idempotency, external API integration. ~20-40 min."
```

Operators with custom targets (billing, file upload, search, etc.) pick "specific feature flow" and name it inline. The skill accepts any subsystem string.

### Step 1.5 — Lens (bugs vs boundaries)

Resolve `LENS` in this order:
1. Explicit `--lens=bugs` or `--lens=boundaries` in invocation args → use it.
2. Keyword match in the invocation prompt (`"edge case"`, `"boundary"`, `"DST"`, `"currency"`,
   `"proration"`, `"unicode"`, `"pagination"`, `"state machine"`, `"entitlement"`, `"quota"`,
   `"seat cap"`) → `boundaries`. No match → `bugs`.
3. If V_DEPTH >= 1 (orchestrator mode) and still ambiguous, default to `bugs` (the orchestrator
   names `--lens=boundaries` explicitly when it wants that lens — see `v-audit-orchestrator`
   menu row).
4. If interactive and genuinely ambiguous, ask once:

```yaml
question: "Which lens — behavioral bugs, or boundary conditions?"
header: "Lens"
multiSelect: false
options:
  - label: "Bugs (default) — broken flows, races, RBAC, error surfaces"
    description: "The original 8-dimension end-to-end defect hunt."
  - label: "Boundaries — empty/max, DST, currency, unicode, pagination, state-machine, entitlement"
    description: "The 9-dimension boundary-condition hunt (formerly /v-edge-hunt)."
```

The chosen lens determines which dimension table runs (§ Bug Hunt Dimensions for `bugs`;
`references/boundaries-lens.md` for `boundaries`) and which depth-tier mapping applies in
Step 2.

### Step 2 — Depth (canonical 3-tier per `_v-audit.md`)

**If `LENS=boundaries`,** use the depth-tier mapping in `references/boundaries-lens.md` §
Depth tiers (Quick=2 dims, Standard=6 dims, Thorough=9 dims) instead of the table below.

Skip if V_DEPTH >= 1 (default to Thorough) or if a depth keyword is in the prompt — accept both bare (`quick|standard|thorough`) and flag form (`--quick|--standard|--thorough`).

```yaml
question: "How deep should this bug hunt go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Quick — for iteration"
    description: "Dims 1 (Critical Flows), 6 (Error Surfaces). Pattern + flow trace, no browser exercise. ~8-12 min."
  - label: "Standard — recommended default"
    description: "Dims 1, 2, 3, 5, 6, 7. Flow trace + form/validation + async + error + data integrity. ~20-30 min."
  - label: "Thorough — pre-launch / pre-merge"
    description: "All 8 dimensions, parallel subagents, mandatory Playwright exercise for UI claims. ~30-45 min."
```

**Output format:** Markdown by default. Pass `--format=json` for the parallel JSON companion (required for operator-managed pipelines that downstream-consume findings).

---

## Cross-Skill Notes

- **v-check overlap (HARD RULE):** If a v-check `AUDIT_REPORT_*.md` exists within 14 days and covers the same target, v-bug-hunt MUST treat that report's P0/P1 findings as baseline and NOT re-report them. Add a `## Baseline (from v-check)` section in the report listing the pre-known items. v-bug-hunt's value is in finding what v-check CAN'T find — behavior, flow, hostile-user defects.
- **v-audit-code overlap (absorbed v-ui-audit 2026-07-06):** If an `AUDIT_CODE_REPORT_*.md` exists within 14 days, skip cosmetic UX findings (those are v-audit-code's domain). Focus on broken behavior, broken state machines, and flow seams.
- **v-pre-flight prerequisite:** If a recent PRE_FLIGHT_REPORT shows failing gates, STOP. Bug-hunting against a broken tree is wasted effort. Tell the operator to fix pre-flight, then re-invoke.
- **v-prelaunch-readiness composition:** v-prelaunch-readiness does NOT invoke v-bug-hunt (it is a public-surface presence gate that defers deep verification to `/v-check` + `/v-pre-flight`). Before launch, run v-bug-hunt separately — one pass per revenue-critical or data-critical flow. Orchestrator mode exists for any operator chain that sets `V_DEPTH >= 1` and passes `BUG_HUNT_TARGET`.
- **Lens ordering:** when both lenses are planned for the same target, run `lens: bugs` FIRST (it clears the happy path and flow seams); then `lens: boundaries` composes with the same target's prior `BUG_HUNT_REPORT_*.md` (§ Compose with prior audits — checks for a recent report on the same target regardless of which lens wrote it) and adds boundary-condition findings only, skipping any P0/P1 the bugs-lens pass already surfaced. Do not run the boundaries lens on a target whose bugs-lens P0s are still unfixed.
- **/v-verify-done is post-implementation, not adversarial.** v-verify-done checks convention compliance (TS `any` ban, DOMPurify, page contract) on changed files. v-bug-hunt traces user flows against a working app. They do not overlap.

---

## Bug Hunt Dimensions (`lens: bugs` — default)

**If `LENS=boundaries`, skip this section and its dimension table entirely — read
`references/boundaries-lens.md` instead, which carries the full 9-dimension boundary-condition
protocol (Dimension list, depth tiers, verification gates, critic-dispatch substitutions,
output-format additions, session clustering, gotchas).** The two lenses do not share a
dimension table; only the dispatch mechanics (fork-safe `claude -p` subprocess, `sonnet` pin,
per-dim exploration block) are common, and those are documented once, here.

All 8 dimensions are scoped to the chosen target subsystem. Each dimension produces findings tagged with the canonical ID prefix (per `~/.claude/skills/references/findings-id-convention.md`).

**Dimension subagent dispatch model (mandatory at EVERY depth):**

- **Dispatch mechanism:** each depth-selected dimension runs as a parallel fork-safe `claude -p` subprocess via `~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode capture` — **NOT the Agent tool** (it fails silently from `context: fork`). Instruct each briefing file to use extended thinking before tracing hostile/async paths.
- **Model pin is `sonnet` (do NOT omit):** an unpinned dimension silently inherits the SESSION model — which may be `fable` (refuses the /v role and no-ops) or a premium `[1m]` variant. Race-condition, silent-failure, and state-desync reasoning needs the pin (CLAUDE.md Model Policy 2026-07-07: all /v dispatches Sonnet 5 + Haiku only; opus/fable only by explicit per-session operator choice). The Step 7 prompt-pack subprocess is `--model sonnet` too.
- **Depth selects WHICH dimensions run, never whether they dispatch:** Quick = 2 subprocesses, Standard = 6, Thorough = 8.
- **Browser access:** subprocesses get only their scoped `--allowedTools`. In Thorough mode, pass the Playwright plugin tool names (the `mcp__plugin_playwright_playwright__browser_*` set from this skill's frontmatter) via `--extra-tools` to the UI dimensions (1, 2, 4, 5). If Playwright is unavailable, those dimensions still run — their UI claims degrade to `UNVERIFIED-UI`; never fabricate browser evidence.

| # | Dimension | Prefix | Priority | Quick? | Standard? | Thorough? | Focus |
|---|---|---|---|---|---|---|---|
| 1 | Critical Flows | `BHUNT-FLOW` | P0-P1 | Yes | Yes | Yes | End-to-end golden path + sad path + hostile path traced step-by-step |
| 2 | Forms & Validation | `BHUNT-FORM` | P0-P1 | — | Yes | Yes | Client/server validation mismatch, dedup, bypass, multi-tab, malformed input |
| 3 | API / Inertia Contract | `BHUNT-API` | P0-P1 | — | Yes | Yes | Response shape drift, null/undefined handling, prop assumptions, type lies |
| 4 | Auth, Session & RBAC | `BHUNT-AUTH` | P0 | — | — | Yes | Session expiry mid-flow, direct-URL access, role/permission bypass, CSRF, stale token |
| 5 | Async & State | `BHUNT-ASYNC` | P0-P1 | — | Yes | Yes | Race conditions, queue failures, retries, idempotency, stale UI, optimistic-update reconciliation |
| 6 | Error Surfaces | `BHUNT-ERR` | P0-P1 | Yes | Yes | Yes | Swallowed exceptions, generic toasts hiding real errors, missing fallbacks, logging gaps |
| 7 | Data Integrity | `BHUNT-DATA` | P0 | — | Yes | Yes | FK cascade traps, soft-delete reanimation, transaction boundaries, partial writes |
| 8 | Production Surface | `BHUNT-PROD` | P0-P1 | — | — | Yes | Env/config assumptions, dev-only patterns leaking, cron/queue dependencies, error-detail leakage |

**Target-aware override (mandatory):** if the chosen target IS auth/session (the "Auth & session" option) or the flow is auth-gated in a way central to the target (e.g., billing portal, admin panel), Dimension 4 runs at EVERY depth, Quick included. An auth-centric target audited without its auth dimension is an invalid run — add Dim 4 to the dispatch set and say so in the report's methodology. The same logic applies to Dimension 5 when the target is the "Background async pipeline" option: Dim 5 runs at every depth.

### Stack detection (run at Step 0)

Read `composer.json` and `package.json` to detect the actual stack. Findings reference Laravel + Inertia + React idioms when that stack is detected. The table below shows how dimension probes adapt:

| Detected stack | Adaptation |
|---|---|
| Laravel + React/Inertia | All probes apply as written (Inertia contract, Form Request, Eloquent, Jobs) |
| Laravel + Livewire | Replace Inertia contract checks (Dim 3) with Livewire component/action probes |
| Laravel + Blade only | Skip Dim 3 (Inertia contract); replace with Blade template/view-data probes |
| Laravel + SQLite (dev) / MySQL (prod) | Note SQLite FK gotcha in Dim 7 as written |
| Non-Laravel PHP | Replace Eloquent/Form Request/Job idioms with framework equivalents; keep dimension logic |
| Non-PHP backend | Replace PHP-specific probe patterns; keep all 8 dimension concepts |

Note the detected stack in `audit_metadata.stack` in the report output.

### Dimension 1 — Critical Flows (`BHUNT-FLOW`)

Trace the target subsystem's golden path end-to-end. Then trace each obvious sad path. Then trace hostile paths.

**Probe (always run — Laravel form shown; substitute the framework equivalent per the stack table when non-Laravel):**

```bash
# Identify entry routes for the target subsystem
php artisan route:list --columns=method,uri,name,action | grep -i "<target keyword>"
# Non-Laravel: grep the router/urls file (routes.rb, urls.py, app router dir, etc.)
```

For each entry point:
1. **Golden path** — happy-path navigation, identify every controller method invoked, every job dispatched, every Inertia page rendered.
2. **Sad path** — same flow with empty/missing related records, expired session, missing optional dependency, slow/failed responses (when the Playwright plugin is available, capture the in-between state via `browser_snapshot` after the action but before settle, and check `browser_network_requests` for failed calls; if not feasible, note the path as unprobed — do NOT fabricate).
3. **Hostile path** — direct URL to step 3 without completing step 1; back-button after destructive action; refresh mid-flow; duplicate submit; multi-tab same form.
4. **Verify** — does the user see a coherent state at every point, or does the app silently no-op / 500 / show stale UI?

**Findings target:** routes that 500 on edge inputs, flows that strand the user mid-state, missing CSRF on state-changing routes, controller methods that assume relations are loaded but throw on lazy-load when called from a different entry point.

**When Playwright MCP is available (Thorough only):** drive the golden path in a real browser and attach a console-log dump as evidence.

### Dimension 2 — Forms & Validation (`BHUNT-FORM`)

For each form in the target subsystem:

1. List the form's frontend validation (yup/zod schema, `useForm` errors handling, required attributes).
2. List the backend validation (FormRequest rules, controller manual validation, model casting).
3. **Diff them.** Mismatches are findings (`BHUNT-FORM-NN: backend allows X, frontend silently strips it`).
4. Probe: submit with frontend JS disabled. Submit with the field deleted via DOM. Submit while another tab has the same form. Double-click submit.
5. Check: does the API return 422 with field-level errors that the frontend actually maps to the right input?

**Findings target:** validation present client-side but missing server-side (or vice versa), 500s instead of 422s on bad input, dedup race conditions, file uploads with unchecked MIME/size, malformed-input acceptance.

### Dimension 3 — API / Inertia Contract (`BHUNT-API`)

The Inertia.js page contract is a known weak point in AI-generated code:

1. For each `Inertia::render('X/Y', $props)` in the target subsystem, verify `resources/js/Pages/X/Y.tsx` exists and consumes the exact prop keys passed.
2. For each prop the page reads, verify the controller always supplies it on every code path (including error paths). Missing props become `undefined` at runtime, which TypeScript may or may not catch depending on optional-chaining habits.
3. For each `useForm` / `router.post` / `fetch` call, verify the response shape matches what the frontend assumes.
4. **Null check audit:** grep for `.data.` / `.results.` / `.user.` access without optional chaining or guard — every one is a potential crash on a null response.
5. For API endpoints, verify response shape is consistent across success/error paths (e.g., success returns `{data: [...]}`, error returns `{message: '...', errors: {...}}` — these must not collide).

**Findings target:** Inertia pages that render with missing props, frontend assumptions about array vs object shape, type drift between API contract and frontend consumer, response shapes that change shape on error.

### Dimension 4 — Auth, Session & RBAC (`BHUNT-AUTH`)

1. List every route in the target subsystem. For each: which middleware is applied?
2. Identify routes that should require `auth` but don't. Identify routes that require `auth` but lack the resource-scoped authorization check (`can:view,resource`).
3. Probe: visit a resource-scoped URL with a session for a user who does NOT own the resource. Should return 403, not 200 or 500.
4. **Session expiry mid-flow:** start a multi-step flow, wait until session expires (or simulate by clearing the session cookie in DevTools), then try to submit. Does the app re-authenticate gracefully or silently lose data?
5. CSRF: every state-changing route must accept CSRF. Webhook endpoints that bypass CSRF must verify HMAC signatures instead.

**Findings target:** routes missing auth middleware, policies that check ownership but not role, CSRF disabled without compensating signature verification, session expiry causing data loss, RBAC bypass via direct API call.

### Dimension 5 — Async & State (`BHUNT-ASYNC`)

1. List every Job dispatched by the target subsystem.
2. For each job: what's `$tries`? What's `$backoff`? What happens if the job fails on the last retry — does the user see anything, or does it silently disappear into `failed_jobs`?
3. **Idempotency:** can the job be safely retried? If a payment job partially succeeds (charges the card but doesn't write the record), what happens on retry?
4. **Race conditions:** identify any code that reads-then-writes without a lock or transaction. Particularly for counters, balance updates, "first-X-wins" flows.
5. **Optimistic UI:** any frontend that updates state before the server confirms — what happens when the server rejects? Is the UI rolled back?
6. **Stale data:** any background polling or webhook that races with user actions. Order-of-arrival assumptions are findings.

**Findings target:** jobs without `$tries` (typo for `$retries`), jobs with side effects that aren't idempotent, races between user action and webhook, optimistic updates without rollback, stale UI after async failure.

### Dimension 6 — Error Surfaces (`BHUNT-ERR`)

Errors are where AI-generated code fails most consistently. Probe:

1. Grep for `try.*catch` blocks in the target subsystem. For each: does the catch block log the exception (with context)? Does it propagate to the user, or silently swallow?
2. Grep for generic error toasts (`"Something went wrong"`, `"An error occurred"`). For each: trace back to the source. Is the real error available somewhere (server logs, network tab) or has it been thrown away?
3. For each failure mode (DB unreachable, queue down, external API 5xx, OpenAI rate-limit, file storage full): what does the user see? Does the app degrade gracefully, or show a generic error and abandon the flow?
4. **Logging:** are exceptions logged with `user_id`, `action`, `request payload`, `correlation id`? Or are they logged as raw stack traces with no context?
5. **Error UX:** does the error message tell the user what to do next, or just that something is broken?

**Findings target:** swallowed exceptions, missing context in logs, generic toasts hiding actionable errors, no retry guidance, error states that strand the user, raw exceptions leaking to UI.

### Dimension 7 — Data Integrity (`BHUNT-DATA`)

1. Identify every database write in the target subsystem (controller create/update/delete, job actions, observer side effects).
2. For multi-table writes: is there a `DB::transaction()` boundary? If not, can a partial failure leave the DB in an inconsistent state?
3. **Foreign keys:** for each FK, what's the on-delete behavior? `cascadeOnDelete` is correct; `set null` may strand orphans; missing constraint is a finding.
4. **Soft delete traps:** if any model uses SoftDeletes, identify every query that may unintentionally include trashed records (or exclude them when it shouldn't). Restoration paths are particularly risky.
5. **SQLite FK enforcement is config-gated, not absent:** SQLite DOES enforce `cascadeOnDelete()` (and other FK actions) once `PRAGMA foreign_keys = ON` — Laravel enables this pragma by default for SQLite connections (`config('database.connections.sqlite.foreign_key_constraints')`, defaulting to `env('DB_FOREIGN_KEYS', true)`). The real dev/prod drift risk: a test/dev env with `DB_FOREIGN_KEYS=false`, or a migration that calls `Schema::disableForeignKeyConstraints()` and never re-enables it, silently no-ops cascades in SQLite (orphaned rows, no error) while the same schema enforces them in prod (MySQL/Postgres). Verify the pragma/config is on and no migration leaves it disabled — do NOT flag SQLite cascade as broken by default; that's a false finding.
6. **Race conditions:** any unique-by-business-rule field (e.g., slug, email) needs a unique DB constraint AND application-level dedup. Missing either is a finding.

**Findings target:** multi-table writes without transactions, missing FK cascade, soft-delete leaks, dev/prod DB behavior drift, missing unique constraints.

### Dimension 8 — Production Surface (`BHUNT-PROD`)

1. **Env var assumptions:** grep for `env(` calls in non-config files (a Laravel anti-pattern — config caching breaks these). Grep for hardcoded URLs, hardcoded API keys, hardcoded paths.
2. **Dev-only patterns leaking:** `dd()`, `dump()`, `Log::info($sensitive)`, debug routes registered unconditionally, `APP_DEBUG=true` assumptions.
3. **Cron / queue dependencies:** any feature that silently depends on a queue worker running or a scheduled task firing. If the worker dies, what's the user-visible impact?
4. **Error detail leakage:** verify error pages don't include stack traces, SQL, or internal paths. Verify API errors don't leak schema info.
5. **Secrets:** verify no API keys, tokens, or credentials are hardcoded in source. Verify `.env*` tracking matches the project's stated policy (CLAUDE.md § Security Defaults: `.env*` may be committed per project policy; default when the project is silent: gitignored — never flag a policy-sanctioned tracked `.env`).
6. **HMAC / signature verification:** any webhook endpoint must verify the signature. Missing or weak signature verification is a P0.

**Findings target:** `env()` outside config files, debug code in prod-bound paths, silent queue dependencies, error-detail leakage, missing webhook signature verification, hardcoded secrets.

---

## Verification Gates

Apply Gates 0, 1, 2, and 8 from `~/.claude/skills/references/v-audit-gates.md` before declaring the audit complete.

| Gate | What it enforces | Why v-bug-hunt needs it |
|---|---|---|
| Gate 0 | Subagents emit a per-dim exploration block + orchestrator runs a 2-citation hallucination spot-check per subagent | Bug-hunt findings are easy to fabricate ("there's a race condition at user-service.php:142") — Gate 0 forces citation verification before findings ship. |
| Gate 1 | Every finding has a parseable `path:line` citation; findings without one are dropped | Without parseable citations, the prompt-pack generator can't route fixes to the right files. |
| Gate 2 | Per-dim minimum-findings floor with mandatory re-task before auto-justify | See `~/.claude/skills/references/v-audit-floors.md` § `## v-bug-hunt floors (provisional)`. |
| Gate 8 | File-existence verification before methodology emits "phase ran" claims | Methodology must verify BUG_HUNT_REPORT.md and prompt-pack dir via Glob before claiming the run completed. |

### Stop conditions (explicit thresholds — these define `STOP_CONDITIONS_HIT`)

| Condition | Threshold | Action when hit |
|---|---|---|
| `max_findings_hit` | 40 total findings across all dimensions | Stop probing, write the report with what exists, set the flag. More than 40 findings on one subsystem means the target needs `/v-check` triage first, not deeper hunting. |
| `context_budget_exceeded` | ~200k tokens consumed (upper bound of this skill's budget per `references/v-core-token-budgets.md`) | Finish the in-flight dimension, skip remaining dimensions, list skipped dims in the report methodology, set the flag. |
| `target_too_broad` | Target maps to >120 source files after scope resolution | Interactive: ask the operator to narrow. Headless (V_DEPTH >= 1): pick the highest-risk slice (auth-adjacent or money-adjacent first), audit that, set the flag and name the excluded slice. |
| `pre_flight_blocking` | Step 1 detected a failing PRE_FLIGHT_REPORT | Stop before dimensions run (per Compose rules); report is not written. |

### Anti-reward-hacking clause (mandatory)

If a dimension produces zero findings on a target subsystem, that is a **valid outcome**. Report `findings_count: 0` for that dimension with a one-paragraph justification of what was checked and why nothing surfaced. Do NOT invent findings to fill the floor. The auto-justify path in Gate 2 covers this case; use it.

### Browser-evidence requirement (mandatory for UI claims)

Any finding that asserts a UI behavior (the app renders X when it should render Y; the toast appears too late; the form loses state on refresh) MUST attach one of:

1. A Playwright MCP screenshot (`mcp__plugin_playwright_playwright__browser_take_screenshot` output)
2. A reproducible console-log capture (`mcp__plugin_playwright_playwright__browser_console_messages`)
3. The accessibility/visible-text snapshot from `mcp__plugin_playwright_playwright__browser_snapshot`

If Playwright MCP is unavailable in the runtime, mark the finding `confidence: medium` and append `evidence_type: UNVERIFIED-UI` — and do NOT classify it as P0 or P1. UNVERIFIED-UI findings cannot be critical.

### Per-dim exploration block (Gate 0 contract for subagents)

Every Dimension N subagent return MUST include:

```markdown
## Per-dim exploration

### Dimension {N} — {name}
- **Target files inspected:** `path1`, `path2`, ... (full reads, not glances)
- **Routes / endpoints probed:** `GET /foo`, `POST /bar`, ...
- **Greps run:**
  - `grep -rn "pattern" {dir}/` → N hits, key result line: "..."
- **Hostile inputs attempted (if applicable):** "Submitted form with empty CSRF token", ...
- **Browser actions (if Playwright available):** "Navigated to /onboarding, filled form, clicked Submit twice within 200ms"
- **Verifications done:** "Confirmed route auth middleware in routes/web.php:42", ...
```

Returns missing this block are rejected and re-tasked.

The orchestrator picks 2 random `path:line` citations per subagent's findings and verifies the cited line actually contains content matching the finding's description. 1-of-2 mismatch → re-task; 2-of-2 mismatch → drop the entire return as fabricated.

---

## Output Format

Include only sections with findings. Omit empty priority sections.

```markdown
# BUG_HUNT_REPORT
generated: [ISO_DATE]
status: ready
lens: [bugs | boundaries]
target: [auth | onboarding | <feature flow name> | async pipeline]
stack: [detected — e.g. laravel/react-inertia, laravel/livewire, laravel/blade, rails/react, etc.]
depth: [thorough | standard | quick]
target_files_in_scope: [N]

## EXECUTIVE_SUMMARY

### Critical Findings (P0)
- [count] auth/data integrity/silent-failure issues requiring fix before launch

### Important Findings (P1)
- [count] flow seams, race conditions, validation gaps

### Polish Findings (P2)
- [count] error UX, logging gaps

### Suspected (P3)
- [count] findings flagged but not fully verified — manual reproduction recommended

## Baseline (from prior audits)

<!-- Include if a recent v-check or v-audit-code report was loaded -->

- v-check `AUDIT_REPORT_*.md` ({date}): {N} P0/P1 findings on this target — treated as baseline, not re-surfaced
- v-audit-code `AUDIT_CODE_REPORT_*.md` ({date}): {N} UX findings — out of v-bug-hunt scope

## FINDINGS

### P0_CRITICAL
<!-- Omit if no P0 -->

#### BHUNT-FLOW-01: [Issue Title]
file: [path:line]
type: [flow | form | api | auth | async | error-surface | data-integrity | prod-surface]
severity: critical
confidence: high
issue: |
  [What's wrong, behaviorally — "User who refreshes mid-checkout sees a 500 because
   the controller assumes session.cart is populated."]
evidence: |
  [Code snippet, log output, OR Playwright trace path]
repro: |
  [Paste-runnable: shell commands, curl, or click-by-click browser sequence]
  $ php artisan tinker --execute="echo route('checkout.process');"
  $ # Visit /checkout, fill form, click Submit, hit browser refresh before redirect completes
  $ # Observe: 500 instead of redirect to success page
fix_sketch: |
  [HIGH-LEVEL approach for the implementing agent — NOT the fix itself]
  [Guard against missing session.cart in CheckoutController@process by redirecting
   to /cart with a flash message instead of throwing.]
verification: |
  [How v-build can verify the fix landed: failing test to write first, then assertion
   that it passes after the change]

### P1_IMPORTANT
<!-- Omit if no P1 -->

#### BHUNT-FORM-02: [Issue Title]
...

### P2_POLISH
<!-- Omit if no P2 -->

### P3_SUSPECTED
<!-- Findings flagged but evidence is incomplete -->

#### BHUNT-ASYNC-04: Suspected race in dispatch
file: [path:line]
type: async
severity: medium
confidence: low
evidence_type: UNVERIFIED-UI | PATTERN-MATCH-ONLY | INCOMPLETE-REPRO
issue: |
  [What was observed]
why_not_verified: |
  [Why this couldn't be reproduced in this session — e.g., "Playwright MCP unavailable",
   "requires production-scale concurrent load", "needs operator decision on intended behavior"]
next_step: |
  [What to do to confirm or rule out]

## FINDINGS_REQUIRING_HUMAN_DECISION

<!-- Things that are not defects but need a product/business call -->

#### DEC-01: Retention policy on failed sign-ups
context: |
  Sign-ups that fail email verification within 7 days are not cleaned up. Is that
  intentional (for re-attempt analytics) or a leak?
question_for_operator: |
  Should we add a scheduled cleanup job, or is this intentional?

## VERIFIED_GOOD

Items checked that work correctly:
- [x] CSRF protection active on all state-changing routes in target
- [x] Job retries use `$tries` correctly (no `$retries` typo)
- [x] Inertia page contract: all `Inertia::render` calls have matching `.tsx` files
- [x] ...

## IMPLEMENTATION_ORDER

Execute fixes in this order:
1. BHUNT-FLOW-01 (highest-severity, blocks launch)
2. BHUNT-AUTH-03 (auth bypass — fix before any other change)
3. BHUNT-FORM-02 (validation gap, user-visible)
...

## STOP_CONDITIONS_HIT

<!-- Required if the audit stopped early -->

- max_findings_hit: false
- context_budget_exceeded: false
- pre_flight_blocking: false
- target_too_broad: false

## NEXT_STEPS

Bug hunt complete. To implement fixes:
1. Review findings for accuracy (operator gate)
2. Start a fresh session (context hygiene)
3. Run: `/v-build BUG_HUNT_REPORT_[timestamp].md` → `/v-pre-flight` → `/v-verify-done`

Estimated effort:
- P0 fixes: [X items]
- P1 fixes: [X items]
- P2 fixes: [X items]
```

---

## JSON Output Format (when `--format=json` requested)

Save companion JSON to `$PROJECT_ROOT/BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.json` (same `[timestamp]` captured at Step 0 as the `.md`) using FINDING_FORMAT_JSON from `_v-review.md`, with the following bug-hunt-specific extensions. **If `LENS=boundaries`, each finding ALSO adds the `boundary_input` field and uses `EHUNT-*` dimension values** per `references/boundaries-lens.md § JSON output extensions`.

```json
{
  "audit_metadata": {
    "audit_type": "v-bug-hunt",
    "lens": "bugs | boundaries",
    "target": "auth | onboarding | <feature flow> | async pipeline",
    "depth": "thorough | standard | quick",
    "stack": "[detected — e.g. laravel/react-inertia]",
    "baseline_loaded": {
      "v_check_report": "AUDIT_REPORT_...md or null",
      "ui_audit_report": "AUDIT_CODE_REPORT_...md or null",
      "bug_hunt_report_other_lens": "BUG_HUNT_REPORT_...md or null (boundaries lens only)"
    },
    "total_findings": N,
    "by_priority": {"P0": N, "P1": N, "P2": N, "P3": N},
    "stop_conditions_hit": []
  },
  "findings": [
    {
      "id": "BHUNT-FLOW-01",
      "priority": "P0|P1|P2|P3",
      "dimension": "flow|form|api|auth|async|error-surface|data-integrity|prod-surface",
      "category": "ux|security|performance|test-coverage|data-integrity|other",
      "title": "...",
      "description": "...",
      "severity": "critical|high|medium|low",
      "confidence": "high|medium|low",
      "evidence_type": "code-citation | playwright-trace | log-capture | grep-output | UNVERIFIED-UI | PATTERN-MATCH-ONLY",
      "files_affected": [{"path": "...", "lines": [42, 43]}],
      "repro": {
        "kind": "shell|curl|browser-script",
        "commands": ["...", "..."]
      },
      "test_first": "Failing test to write before fix",
      "implementation": {
        "approach": "High-level fix sketch (NOT the fix)",
        "changes": ["Step 1", "Step 2"]
      },
      "verification": "How to verify the fix works",
      "effort_hours": N
    }
  ],
  "findings_requiring_human_decision": [
    {
      "id": "DEC-01",
      "context": "...",
      "question_for_operator": "..."
    }
  ],
  "verified_good": ["...", "..."]
}
```

The `severity` enum (critical|high|medium|low) maps 1:1 to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md` (critical=P0, high=P1, medium=P2, low=P3) — keep the lowercase words in the report schema; consolidation normalizes.

---

## Generate Parallel Session Prompts (Standalone Mode Only)

After writing the BUG_HUNT_REPORT, generate copy-pasteable prompt files — one per dimension cluster, ready to paste into a new Claude session with zero editing.

**CRITICAL: Prompt generation MUST run in a separate subagent with a fresh context.** By this point, the main context has consumed 60k-200k tokens on dimension probes.

Follow `~/.claude/skills/references/v-core-prompt-pack.md` for the canonical algorithm. Dispatch a subagent (model: "sonnet", timeout: `600000`) with the full algorithm verbatim — the subagent has NO access to this skill file.

### Session clustering for v-bug-hunt

**If `LENS=boundaries`, use `references/boundaries-lens.md` § Session clustering instead
(4 EHUNT-prefixed clusters) — the clusters below are `lens: bugs` only.**

Cluster findings into sessions by dimension affinity (merge or split based on file dependency graph):

1. **Critical-Path session** — `BHUNT-FLOW` + `BHUNT-AUTH` findings. Auth + flow seams are tightly coupled in controllers.
2. **Contract session** — `BHUNT-FORM` + `BHUNT-API` findings. Frontend/backend contract repairs.
3. **Async-state session** — `BHUNT-ASYNC` + `BHUNT-DATA` findings. Jobs, transactions, and idempotency are one coherent fix surface.
4. **Resilience session** — `BHUNT-ERR` + `BHUNT-PROD` findings. Error surfaces, logging, env hardening.

Session rules:
1. Size each session at 4-15 estimated hours (smaller than v-check sessions because bug-hunt findings are more complex per item).
2. Sessions with <2 findings get merged into the most related session.
3. Order findings within each session by priority (P0 first), then by file affinity (group same-file findings together).
4. Sort sessions by priority of their highest-priority finding.

Aim for 2-4 sessions total (smaller than v-check's 3-5).

Per `~/.claude/skills/references/v-runnable-pack-convention.md` § Wave assignment, these session clusters are disjoint-file, non-dependent work items ⇒ they are ALL wave 0 (no filename prefix) unless the file-dependency graph proves a real conflict/order between two sessions — write the wave form: `00-README.md` + flat `.txt` packs (e.g. `critical-path.txt`, `contract.txt`, `async-state.txt`, `resilience.txt`).

**Security-bearing pack clause (mandatory, per `v-runnable-pack-convention.md` § Security-bearing packs):** the Critical-Path session (`BHUNT-AUTH` — session/RBAC/CSRF/direct-URL-access findings) and the Resilience session (`BHUNT-PROD` — secrets, HMAC/webhook signature verification findings) touch auth/authz decisions and credential/webhook-signature handling. Inline this exact sentence into each such pack's `## Constraints` section: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session." Apply the same test to Contract/Async-state packs if a specific finding happens to touch payment flows or host/URL construction from variables.

**Closing waves (mandatory, per `v-runnable-pack-convention.md` § Closing waves):** after the last implementation wave (wave 0 above), append `w1-pre-flight.txt` + `w1-review.txt` as a parallel READ-ONLY verification wave (`## Goal`/`## Checks`/`## Acceptance` only — no `## Files`, no "leave staged" line), then a single sequential `w2-hardening.txt` that triages the verification findings, fixes CRITICAL/HIGH, re-runs gates, and runs `/v-verify-done`. Then a closing `99-verify.txt` last, always. Reflect all of these in the 00-README.md wave-map table.

### Pre-dispatch shell setup

```bash
PROMPT_DIR=".v-prompt-packs/v-bug-hunt-$(date +%m-%d)"

if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

### Prompt template per session

Each pack is a flat `.txt` file (never `NN-*.md` — the deprecated shape) whose line 1 MUST be `/v ` (the orchestrator routing prefix), and MUST carry the full body schema from `v-runnable-pack-convention.md` § Pack body schema, in order: `## Goal` · `## Context` · `## Files` (literal H2, REQUIRED — v-build's scope guard keys on it) · `## Changes` · `## Acceptance criteria` · `## Tests` · `## Constraints` · `## Dependencies`.

```markdown
/v Fix the following bug-hunt findings for [Project Name].

## Goal
Land regression-tested fixes for the [target subsystem] behavioral bugs found in this session — [1-3 sentences on impact].

## Context
Tech stack: [from orientation]. Target subsystem: [auth | onboarding | <feature flow> | async pipeline].
Dimensions covered: [Critical Flows + Auth | Forms + API | Async + Data | Errors + Prod]. Priority range: [P0 | P0-P1 | P1-P2].

These are BEHAVIORAL bugs, not lint findings. Each one was reproduced or pattern-matched against running code.

### Finding 1: [FND-ID] [Title] (P0, Xh est.)
**File:** [path:line — from finding.files_affected]
**Dimension:** [Critical Flow | Auth | Form | API | Async | Data | Error | Prod]
**Behavior bug:** [description from finding.description]
**Evidence / repro:** [from finding.repro — paste-runnable, inlined, never "see the report"]

## Files
- [path:line] — [what changes]

## Changes
Do NOT batch the fixes. Do NOT skip the failing-test-first step. The whole point of this
audit was to surface behavior that tests miss — landing a fix without a regression test
defeats the purpose. For each finding, in order:
1. Write a failing test that reproduces the bug (TDD) — [from finding.test_first — exact test to write]
2. Implement the fix — [from finding.implementation.approach + .changes]
3. Verify the test now passes — [from finding.verification]
4. Move to the next finding

## Acceptance criteria
- [ ] [FND-ID] bug reproduced by a failing test, then fixed, then the test passes
- [ ] ...

## Tests
- [test to write before each fix, from finding.test_first — full spec]

## Constraints
Read the project's CLAUDE.md first for architecture context and quality gate commands. Behavioral fix only — no drive-by refactors.

## Dependencies
Wave 0. Requires: none.

## After All Fixes
Run the full verification suite:
\```bash
[quality gate commands from CLAUDE.md]
\```

Then run /v-bug-hunt again on the same target to confirm zero regressions.

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

After the subagent completes, self-validate per `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate (or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROJECT_ROOT/$PROMPT_DIR"`), then `run-v-packs "$PROMPT_DIR" --dry-run`. On failure, re-dispatch once with the failure messages. On second failure, report `VALIDATION_FAILED` in the audit artifact.

---

## Mandatory Execution Workflow (FOLLOW THIS ORDER)

| Step | Action | Gating Rule |
|------|--------|-------------|
| 0 | Audit opener: resolve PROJECT_ROOT, parse V_DEPTH, init TodoWrite | per `_v-audit.md` § Audit Skill Opener |
| 1 | Compose with prior audits: detect recent v-check / v-audit-code / v-pre-flight / (boundaries lens only) a same-target `bugs`-lens BUG_HUNT_REPORT | If PRE_FLIGHT_REPORT is failed, STOP |
| 2 | Ask target subsystem (interactive) OR read `BUG_HUNT_TARGET` from args | One target per session — no full-codebase pass |
| 2.5 | Resolve `LENS` (bugs\|boundaries) — flag, keyword, or ask | Determines which dimension table + depth mapping applies |
| 3 | Ask depth (interactive) OR derive from V_DEPTH / keyword | Skip if V_DEPTH >= 1. Use `references/boundaries-lens.md` depth table when `LENS=boundaries` |
| 4 | Run dimensions: dispatch the depth-selected dimensions as parallel fork-safe `claude -p` subprocesses (`bugs`: Quick 2/Standard 6/Thorough 8; `boundaries`: Quick 2/Standard 6/Thorough 9 per `references/boundaries-lens.md`) | Each subagent emits per-dim exploration block (Gate 0) |
| 5 | Gate 0/1/2 verification on returned findings | Drop fabricated findings; re-task on floor underrun |
| 6 | Write `BUG_HUNT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` | MUST exist before Step 7 |
| 7 | **MUST USE SUBAGENT — NOT OPTIONAL.** Dispatch a fork-safe `claude -p` subprocess (`v-dispatch-subagent.sh --model sonnet --mode self-write`, timeout: `600000` — NOT the Agent tool) to generate `.v-prompt-packs/v-bug-hunt-<MM-DD>/` (00-README.md + flat `.txt` wave packs, `99-verify.txt` last). Copy the algorithm verbatim into the briefing file — the subprocess has no skill access. | Standalone mode only. Skip in orchestrator mode. |
| 8 | Self-validate the pack tree per `v-runnable-pack-convention.md` § Self-validate (or `validate-audit-prompt-packs.sh`) + `run-v-packs --dry-run`. Re-dispatch once on failure. | MUST pass or report failure in artifact |
| 9 | Present completion summary: finding counts, session count, prompt directory | — |

**Steps 7-8 are NOT optional in standalone mode.** Prompt files enable parallel fix sessions in `/v-build` — skipping them defeats the audit.

---

## Quality Rules

1. **Evidence required** — Every finding needs a parseable `path:line` citation. Findings without one are dropped, never reported at low severity.
2. **Repro required** — Every P0/P1 finding needs a paste-runnable repro block (shell, curl, or browser script). No exceptions.
3. **No fixes in the report** — The report carries fix sketches only. Implementation lands in the prompt pack for `/v-build`.
4. **Behavioral over structural** — Surface broken behavior, not code style. Code style is for `/v-check`, `/v-verify-done`, `/v-audit-code` (absorbed `/v-refactor` 2026-07-06).
5. **Zero findings is valid** — Do not invent findings to hit a floor.
6. **Browser evidence for UI claims** — Playwright trace, screenshot, or `UNVERIFIED-UI` tag.
7. **Compose with v-check** — Baseline known findings, don't re-surface.
8. **Escalation bucket** — Product/business decisions go in `FINDINGS_REQUIRING_HUMAN_DECISION`, not in the main backlog.

## Severity Rubric (explicit — no agent discretion)

| Severity | Definition |
|---|---|
| **P0 — Critical** | Data loss, auth bypass, payment/billing correctness defect, silent data corruption, secrets leakage, production crash on a real user path. Must fix before launch / next deploy. |
| **P1 — Important** | User-visible error path that strands the user, race condition reproducible under normal use, silent failure on a golden path, RBAC gap exploitable by a legitimate user. Must fix before the feature is considered done. |
| **P2 — Polish** | Degraded UX, missing fallback, generic error messaging, log gap on failure, observability missing for a feature. Should fix this cycle. |
| **P3 — Suspected / Unverified** | Pattern-match-only or UNVERIFIED-UI findings. Cannot be P0 or P1. Operator follow-up required to promote or drop. |

Severity inflation is a known failure mode — keep the rubric strict. If unsure between P1 and P2, the answer is P2.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Full-codebase pass attempted instead of target subsystem | Operator skipped target question or invoked without arg | The skill MUST refuse to proceed without a target. If interactive, ask. If headless, fail. |
| 2 | Findings duplicate `/v-check` output | Prior audit not composed | Always check for recent AUDIT_REPORT_*.md and load as baseline. Never re-surface v-check's P0/P1. |
| 3 | UI findings flagged as P0 without browser evidence | Playwright MCP unavailable, agent fabricated UI behavior | Mandatory evidence-type tag; UNVERIFIED-UI cannot be P0/P1. |
| 4 | "Race condition" findings without repro | Pattern match on `->update()` without lock, no actual reproduction | Repro block is mandatory on P0/P1. Pattern-match-only findings degrade to P3. |
| 5 | Prompt pack files don't start with `/v ` | Subagent skipped the routing-prefix rule | Post-generation validator enforces; re-dispatch on first failure, report on second. |
| 6 | Audit declared "done" with no findings on a known-broken subsystem | Reward-hacking the zero-finding outcome | Gate 2 floor enforces minimum coverage; zero findings requires per-dim justification, not a blanket pass. |
| 7 | Findings reference Laravel idioms in a non-Laravel stack | Skill assumed default stack without checking | Detect stack in Step 0; adapt dimension probes accordingly. Note stack in audit_metadata. |
| 8 | Pre-flight is failing, but bug-hunt ran anyway | Composition check skipped, or the status grep pattern didn't match the report's actual `status: fail` / `Overall Status: FAIL` lines | Mandatory early exit; use the exact grep from § Compose with prior audits — never invent a new pattern. |
| 9 | Playwright tools listed in frontmatter but every browser call fails | Plugin not installed, or plugin tool names drifted since this skill was written | On the FIRST failed browser call, stop attempting browser actions, tag all UI claims `UNVERIFIED-UI` (severity-capped at P3), and say so in the methodology. Never fabricate browser evidence, never retry the whole suite. |
| 10 | Auth-centric target audited at Quick/Standard depth with Dim 4 skipped | Depth table applied without the target-aware override | Dim 4 runs at every depth when the target is auth-centric; Dim 5 runs at every depth when the target is the async pipeline. |
| 11 | Boundary-condition request (DST, currency, unicode, entitlement) ran the `bugs` lens 8-dim table and found nothing relevant | `LENS` defaulted without a keyword match or explicit flag | Resolve `LENS` explicitly at Step 1.5; when the operator's language clearly names a boundary condition, route to `references/boundaries-lens.md`, never silently run the wrong dimension table. |
| 12 | Operator invoked `/v-edge-hunt` and got "command not found" | v-edge-hunt was archived into this skill 2026-07-05 | Use `/v-bug-hunt <target> --lens=boundaries` instead — same 9 dimensions, same report shape, single `BUG_HUNT_REPORT_*` artifact. |

## Idempotency

**Idempotent for both lenses.** Re-running on the same target (and same lens) produces a fresh BUG_HUNT_REPORT. Pure read of project state — no filesystem mutations to source files. Prompt pack regeneration archives the prior pack before writing (`.v-prompt-packs/v-bug-hunt-<MM-DD>/`, shared by both lenses; each run's `.bak-<timestamp>-<rand>` sibling preserves the previous run). Findings vary as project state changes (intentionally — the goal is to catch new defects on each cycle). **Concurrent runs on the same target:** discouraged — both lenses will race on the prompt-pack archive step if run back-to-back without waiting for completion; use distinct PROJECT_ROOT paths (worktrees) for parallel audits, same as the former v-edge-hunt's guidance.
