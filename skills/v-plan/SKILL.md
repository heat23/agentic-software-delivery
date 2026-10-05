---
name: v-plan
description: "Use when planning work larger than a small feature, including strategy, refactors, or codebase understanding."
allowed-tools: Read, Glob, Grep, Bash, WebSearch, WebFetch, AskUserQuestion, Write, Skill, mcp__plugin_context7_context7__resolve-library-id, mcp__plugin_context7_context7__get-library-docs
argument-hint: "[prompt]"
user-invocable: true
model: sonnet
context: fork
---
<!-- skill: v-plan | version: 1.1.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing entry point.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-growth.md`, and `_v-design.md` (when planning involves UI files).

For prompt pack generation, read `~/.claude/skills/references/v-core-prompt-pack.md`.

Use the shared `PLAN_SCHEMA`. Do not define a second plan schema inline.

Write `.v/artifacts/PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/`; readers dual-search, root is a legacy fallback).

```yaml
contract:
  tier: user-facing
  accepts: [user prompt, route selection]
  produces: [PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md, ".v-prompt-packs/v-plan-<MM-DD>/ (00-README.md + w<N>-*.txt wave packs per v-runnable-pack-convention.md; conditional: 4+ tasks at Standard/Comprehensive depth; legacy v-plan-prompts/ still scanned by /v for backward compat)"]
  invokes: []
  conditional-invokes: [/interface-design (Route 1 new product with UI work), /v-marketing-design (all routes when plan includes marketing surfaces), /v-setup-project (Route 1 infrastructure)]
  invoked-by: [/v, /v-new-feature, user]
  estimated_tokens: 10k-30k
  estimated_duration: 2-8 min
```

# /v-plan - Interactive Planning

One entry point for all planning needs. Asks questions, then generates the right plan document.

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules, `_v-growth.md` when growth triggers apply, and `_v-design.md` (when planning involves UI files).

**Route reference:** Read `${CLAUDE_SKILL_DIR}/references/route-guides.md` for detailed question flows, exploration steps, and plan templates for each planning route.

## Skill Boundaries

**SME persona:** This skill is run by a **senior staff engineer + planning specialist** — specialty is converting a problem statement into an executable plan: scope (what's in / what's out), files (modify list / create list), tests required, acceptance criteria, rollback notes, growth-instrumentation hooks. The plan is the contract that v-build executes.

### Best fit

- Planning requests that need route selection and a written plan artifact across new product, codebase understanding, specific feature, refactor, growth, or user-owned maintenance planning
- Cases where the right planning route is not yet obvious and the skill needs to choose it
- Producing a reusable `PLAN_*` artifact before implementation begins

### Use instead

- Use `/v-new-feature` when the task is clearly a specific feature spec and competitive/context discovery should be front-loaded
- Use `/v-discover-features` when the task is competitive feature discovery, gap analysis, or demand-signal mapping (not generic planning)
- Use `/v-maintenance` directly when the maintenance scope and file paths are already explicit and the user does not need a separate PLAN artifact
- Use `/v-build` when a concrete plan or maintenance checklist already exists and the task is implementation

### Not for

- Replacing implementation or maintenance execution once the plan is already known
- Adding unnecessary plan ceremony to small, explicit maintenance tasks
- Acting as a generic wrapper for work that should route straight into a specialized skill

## Output

File: `{repo_path}/.v/artifacts/PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir; absolute path from the resolved repo root, NOT `pwd`)
Use one canonical filename pattern for all plan routes.
Use Context7 to verify library best practices when uncertain about current API patterns.

## Skill Workflow

1. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
2. Ask entry-point questions (or use explicit parameters if invoked with them)
3. Explore codebase (Glob, Grep, Read as needed)
4. Make design decisions autonomously (document rationale in the plan)
5. Write the plan file using absolute path
5.5. **Post-write integrity gate (REQUIRED — v3.8.5 hardening)** — see "Plan integrity verification" section below. Confirms the file exists AND contains all 6 required sections from PLAN_SCHEMA. If the gate fails, regenerate the missing sections before proceeding.
6. Generate `.v-prompt-packs/v-plan-<MM-DD>/` with parallel session prompt files (Standard/Comprehensive depth, 4+ tasks only)
7. Show completion banner

## Entry Point

**V_DEPTH parsing (mandatory):** Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Search for `[V_DEPTH=N` or `V_DEPTH=N` in the prompt. Default to 0 if absent.

**When to skip entry-point questions:**
- `V_DEPTH >= 1` (orchestrator invoked) → auto-route based on prompt context. Use **Standard** depth. Infer route from keywords.

  **Precedence (mandatory — first match wins):** evaluate the categories **top-to-bottom in the exact order below** and stop at the first match. The order is deliberately *most-specific-intent-first*: specific-domain signals (maintenance, new-product, understand, growth) are checked **before** the generic change-verbs (refactor/improve, add/implement) so a prompt matching two categories routes deterministically. Worked example: "refactor to improve the conversion **funnel**" matches both Route 4 (refactor/improve) and Route 5 (funnel) — under this order Route 5 wins, because the growth-domain signal is more specific than the generic "refactor/improve" verb. This makes headless routing stable run-to-run for genuinely ambiguous prompts.

  1. "hook"/"settings"/"mirror sync"/"repo-local .claude"/"skill tree"/"maintenance" → Route 6 (User-Owned Maintenance)
  2. "new product"/"from scratch"/"build a" (with no "feature" nearby) → Route 1 (New Product)
  3. "understand"/"document"/"how does"/"architecture" → Route 2 (Understand Codebase)
  4. "growth"/"funnel"/"conversion"/"retention" → Route 5 (Growth Planning)
  5. "refactor"/"improve"/"modernize"/"clean up" → Route 4 (Refactor)
  6. "feature"/"add"/"implement" → Route 3 (Specific Feature)
  7. If no keywords match → default to Route 3 (Specific Feature).
- Explicit context provided (e.g., from `/v` orchestrator with "plan a new feature for X") → use the context to select route and depth directly.

**When V_DEPTH == 0 AND no explicit context**, ask using AskUserQuestion. The tool caps at 4 options. The free-text "Other" it always appends, plus the keyword table above, covers Growth Planning (Route 5) when it is not shown as a fixed choice. Growth Planning is a rarer standalone ask than the primary four, and is already routed ahead of Refactor in the precedence order above:

```yaml
question: "What are you planning?"
header: "Planning"
options:
  - label: "New product from scratch"
    description: "I have a domain/idea and want to plan the full product"
  - label: "Understand existing codebase"
    description: "I inherited or forgot this codebase and need to document it"
  - label: "Specific feature"
    description: "I know what I want to build and need a spec"
  - label: "Refactor or improvement"
    description: "I want to improve existing code quality or architecture"
```

If the user picks "Other" and describes growth/funnel/conversion/retention work, route to Route 5 (Growth Planning) per the keyword table above.

Then ask depth:

**Detail level (interactive only):** When V_DEPTH == 0 and `--detail=` is not in the invocation prompt, ASK via AskUserQuestion — never silently default:

```yaml
question: "How detailed should this plan be?"
header: "Detail Level"
multiSelect: false
options:
  - label: "Standard (Recommended)"
    description: "Balanced detail with effort estimates, ready for `/v-build`. Standard depth: read key files, identify patterns, full plan output."
  - label: "Quick"
    description: "Back-of-envelope sketch. Grep-based exploration only, no file reads, outline output. Skips effort estimates → non-actionable for /v-build. Choose only for early-stage exploration."
  - label: "Comprehensive"
    description: "Deep analysis with all edge cases, alternatives, and risks. Reads all relevant files, cross-references patterns. Use for high-stakes or pre-acquisition planning."
```

When V_DEPTH >= 1 (orchestrator-invoked or headless), use the explicit `--detail=` from the invocation prompt; if absent, fall back to Standard (the documented headless default). If `--detail=quick|standard|comprehensive` is passed, skip the question and proceed accordingly.

**Depth affects output:**
| Depth | Exploration | Output |
|-------|-------------|--------|
| Quick | Grep-based, no file reads | Outline only |
| Standard | Key files read, patterns identified | Full plan |
| Comprehensive | All files read, cross-referenced | Plan + alternatives + risks |

## Planning Routes


| Route | Trigger | Key Activities | Output Focus |
|-------|---------|---------------|-------------|
| 1. New Product | "new product", "from scratch", "build X" | Competitive research, persona design, schema planning, pricing, AI integration | Full product blueprint with viability assessment |
| 2. Understand Codebase | "understand", "how does X work", "document" | Stack detection, route listing, architecture mapping, gap analysis | Architecture map with P0/P1/P2 gaps |
| 3. Specific Feature | "add X", "implement Y", "feature Z" | Codebase exploration, pattern matching, option presentation, edge cases | Implementation plan with file-level spec |
| 4. Refactor/Improve | "refactor", "improve", "modernize", "clean up" | Current vs proposed state, risk analysis, migration strategy | Phased migration plan with rollback notes |
| 5. Growth Planning | "growth", "funnel", "conversion", "retention" | Baseline metrics, bottleneck analysis, A/B test design | Growth experiment plan with monitoring |
| 6. User-Owned Maintenance | "hook", "settings", "mirror sync", "repo-local .claude", "skill tree", "maintenance" | Path scoping, canonical-vs-mirror policy, targeted test planning, hostile review focus | Lightweight maintenance checklist or handoff to `/v-maintenance` |

**Route 3 note:** For complex features (4+ files), `/v-new-feature` provides a more structured alternative with codebase pattern discovery and competitive context analysis.

**Route 6 note:** If the user already named the maintenance paths and did not explicitly ask for a written plan, do not generate a full PLAN artifact. Route directly to `/v-maintenance` and keep the checklist inline.

All routes produce `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` using the shared `PLAN_SCHEMA` from `_v-core.md`.

### Route 1 Post-Plan Auto-Chain (New Product Only)

After generating the PLAN for Route 1 (New Product), auto-chain these setup steps so the solo operator gets a fully-prepared project from a single `/v-plan` invocation:

**Step A: Design System Setup**
If the plan includes UI work (pages, components, layouts) AND the canonical tokens are not installed (no canonical `:root`/`@theme` block, or no `.interface-design/system.md` overlay):
1. Invoke `/interface-design` to install the shared SaaS design system (canonical `:root` + `html[data-theme="light"]` blocks, Inter + JetBrains Mono) and generate the per-product overlay. The only decisions to establish are: `--accent`, category color pairs, branding, and domain components — palette, typography, depth, and components are fixed by the spec (`_v-design.md`)
2. Append a `## Design System` section to the PLAN noting the overlay decisions (accent, category colors, branding, domain components)
3. Design decisions feed back into effort estimates — if genuinely custom domain components are needed (beyond the spec's component library), add 30% to frontend task estimates

**Step B: Project Infrastructure**
If `.claude/hooks/` does not exist OR `.claude/settings.json` does not exist:
1. Invoke `/v-setup-project` to generate hooks, agents, and settings for the detected stack
2. Log `setup_completed: hooks=[N], agents=[N]` in the PLAN

**Step C: Content Strategy Recommendation**
If the plan includes public-facing pages (landing page, pricing page, marketing site):
1. Recommend: "Run `/v-audit-seo` to generate a content strategy and keyword plan alongside development."
2. Do NOT auto-invoke — content strategy is async work that runs in parallel with implementation

**Output after auto-chain:** The PLAN artifact now includes design tokens, infrastructure is bootstrapped, and the developer can immediately start implementing from `.v-prompt-packs/v-plan-<MM-DD>/`. No manual steps between planning and building.

### Marketing Design Setup (All Routes)

After generating the PLAN for **any route** (not just Route 1), check if marketing design governance is needed:

If the plan includes marketing surface work (landing page, pricing page, blog layout, campaign page, or any public-facing marketing page) AND `.interface-design/system.md` does not contain a `## Marketing Surfaces` section:
1. Invoke `/v-marketing-design` to establish: marketing visual thesis, hero pattern, section rhythm, CTA strategy, social proof pattern, and motion language
2. `/v-marketing-design` will save its decisions to `.interface-design/system.md` § Marketing Surfaces — the same file used by app UI tokens
3. Append a `## Marketing Design` section to the PLAN noting the established marketing governance

If `.interface-design/system.md` already contains `## Marketing Surfaces`, skip — the marketing design system is already established. Log `marketing_design: existing` in the PLAN.

Detection: grep the plan's file list and task descriptions for patterns matching `*landing*`, `*pricing*`, `*marketing*`, `*campaign*`, `*welcome*`, `*home*` (homepage), `*blog*` (blog layout, not content), `*about*`, `*features*` (public features page), `*contact*`, `*faq*`, or explicit mentions of public-facing conversion pages. Exclude app UI pages that happen to contain these words in compound names (e.g., `marketing-dashboard.tsx` is app UI, not a marketing page — use context from the plan description to disambiguate). (Canonical glob list lives in `_v-design.md § Context Sensitivity Matrix` — keep in lockstep with it and with v-build's Detection glob.)

### Required Plan Sections (all routes)

Every plan MUST include these core sections from `PLAN_SCHEMA`:

- **## Summary** — What is changing and why
- **## Scope** — In-scope and out-of-scope boundaries
- **## Files** — Modify and create lists
- **## Tests Required** — Test cases checklist
- **## Acceptance Criteria** — Testable, artifact-defined, rollout/rollback-defined
- **## Rollback Notes** — Application and data rollback strategies

Conditional sections (added when triggers match): Target Metric, Instrumentation, First Success Path, New Product Viability. See `_v-core.md` for full schema.

## Effort Estimation (Required for Standard/Comprehensive depth)

Every plan at Standard or Comprehensive depth MUST include effort estimates per task, expressed as a
**T-shirt size with an hour range** — never a single invented precise number (see Gotcha #3: hours come
from the operator if provided, otherwise from these ranges; do not state e.g. "3h" with false precision
when the true basis is a size bucket):

```markdown
## Effort Estimate

| Task | Complexity | Effort (size / range) | Risk |
|------|-----------|------------------------|------|
| [File/feature] | low/medium/high | S (0.5-1h) / M (1-3h) / L (3-8h) | [what could go wrong] |
| **Total** | | **[sum of range low – sum of range high]** | |
```

**Sizing heuristics (ranges, not precise hours):**
- S — New file following existing pattern, small edit to existing file, test file for one source file: 0.5-1h
- M — New file with a new pattern, significant refactor of an existing file, migration + model: 1-3h
- L — Integration with an external API, multi-file architectural change: 3-8h
- Add 30% buffer for edge cases and testing on top of the range, not on a single invented point value

## Architecture Decision Records (ADR)

When a plan makes a decision that clears the 3-of-3 gate below (most common on Route 3: Feature, Route 4: Refactor), generate an ADR section using the template in `references/plan-templates.md § ADR Template` — which also specifies the **durable ADR routing** (persist a copy to `docs/adr/ADR-NNNN-slug.md` or an `## Architecture Decisions` section in the project's `CLAUDE.md`, since `PLAN_*.md` is ephemeral).

**When to generate an ADR (3-of-3 gate):** Record an ADR only when the decision clears **all three** tests:
1. **Hard to reverse** — schema/data migrations, public API or contract shape, auth model, framework/dependency choice, anything a later change can't cheaply undo.
2. **Surprising** — a future reader would reasonably expect a different choice; it's not the obvious default for the stack.
3. **A real trade-off** — you gave up something concrete (performance, simplicity, flexibility, cost) for what you chose.

If any one test fails, do NOT emit an ADR — a one-line note in the plan's rationale is enough. The 3-of-3 gate prevents low-signal ADR spam on routine "two obvious options" calls (the old "any time 2+ approaches exist" trigger over-generated). When all three hold, include the ADR in the PLAN artifact **and** persist the durable copy per the template's routing rules.

## Generate Parallel Session Prompts (Routes 1, 3, 4, 5 — Standard/Comprehensive depth only)

For plans that produce 4+ implementation tasks, generate copy-pasteable prompt files — one per session, ready to paste into a new Claude session with zero editing. Skip this for Quick depth plans or Route 2 (Understand Codebase — no implementation).

### Build the File Dependency Graph

1. **Extract file targets** — for every task in the plan, list every file it creates or modifies (source files, test files, migrations, configs).
2. **Build a conflict graph** — two tasks conflict if they share any file target.
3. **Cluster connected components** — tasks that share files (directly or transitively) must go in the same session.
4. **Handle dependencies** — if task A must complete before task B (e.g., migration before model, backend before frontend), they must be in the same session or ordered.

### Assign Sessions

Group tasks into sessions using architectural layer groupings per route (Route 1 Foundation→Backend→Frontend→Integration→Polish; Route 3 Backend→Frontend→Testing; Route 4 delegates to `/v-audit-code`; Route 5 Measurement→Experiment→Optimization). See `references/plan-templates.md § Session Assignment — Layer Groupings by Route` for the full per-route session lists; adapt based on the file dependency graph above.

Session rules:
1. **Size each session at 15-40 estimated hours when total estimated effort supports it.** This 15-40h
   band only applies once the implementation has enough total work to fill multiple sessions at that
   size — it is not a floor every session must individually hit. For smaller implementations (8-15h
   total, per the "Plan weight heuristic" below) that still clear the 4+ task trigger, a single session
   covering the full estimated total is correct; do not pad tasks or split artificially to reach 15h.
   If a session has fewer than 3 tasks, merge it into the most related session.
2. **Prefer vertical slices over horizontal layers** — when a feature can be delivered as a complete user flow (backend + frontend + tests) within one session, do that instead of splitting across layer sessions. Vertical slices produce testable, demoable increments. Use layer-based splitting only when file dependency analysis forces it (e.g., shared models needed by multiple features).
3. **Theme each session** — give it a descriptive name based on the dominant feature or layer.
4. **Order tasks within each session** by dependency order, then by effort (smallest first).
5. **Sort sessions** by dependency order (foundation/backend before frontend).

**Plan weight heuristic:** If the entire implementation is estimated at < 8 hours (roughly 1-2 sessions), skip the full prompt file generation and use a lightweight checklist in the PLAN artifact instead. The planning overhead should never exceed 20% of the implementation time.

Aim for 2-5 sessions total.

### Write Individual Prompt Files

Create a directory `.v-prompt-packs/v-plan-<MM-DD>/` in the project workspace (where `<MM-DD>` is the current month-day per the unified prompt-pack convention in `~/.claude/skills/references/v-core-prompt-pack.md`), with a `00-README.md` (session/wave map + dependency notes — the only `.md`) and one self-contained `.txt` prompt pack per session: wave 0 (the first, foundational session) takes no prefix, each subsequent dependency-ordered session is `w1-<layer>.txt`, `w2-<layer>.txt`, etc. (per `~/.claude/skills/references/v-runnable-pack-convention.md` — the same wave-pack shape every other producer emits; the older `NN-<layer>.md` per-session naming is retired). The exact directory layout, `00-README.md` contents, the copy-paste pack body template (`## Goal / ## Context / ## Files / ## Changes / ## Acceptance criteria / ## Tests / ## Constraints / ## Dependencies`), and the prompt-writing rules are in `references/plan-templates.md § Write Individual Prompt Files — File Formats`. Non-negotiables when writing them: each pack starts with `/v`, is completely self-contained (no cross-file references to the plan or sibling packs — inline the context), carries the literal `## Files` H2 (v-build's scope guard keys on it), includes TDD test cases per task in `## Tests` and acceptance criteria from the plan in `## Acceptance criteria`, and ends with "leave all changes staged; do NOT commit". After writing the tree, self-validate it per `references/plan-templates.md § Prompt-Pack Self-Validation`.

## SaaS Concerns Checklist (Required for Routes 1, 3, 5)

After the technical breakdown and before writing the final plan, evaluate every planned feature against the SaaS-critical dimensions in `references/plan-templates.md § SaaS Concerns Checklist` (tenant isolation, billing/subscription gating, RBAC/permissions, onboarding, analytics instrumentation, rate limiting, audit logging, webhook exposure). Document each as "Required", "Not applicable", or "Deferred (reason)" in the plan under a `## SaaS Concerns` section; the reference also specifies how each finding feeds into `## Files`, `## Tests Required`, `## Acceptance Criteria`, and effort estimates.

**When to skip:** Quick-sketch depth plans and Route 2 (Understand Codebase) don't need the full checklist. Route 4 (Refactor) needs it only if the refactor changes data access patterns or permission boundaries.

## API Design Step (Required When Feature Exposes Data or Actions)

For features that create, modify, or expose data through HTTP endpoints — especially those external clients, mobile apps, or integrations might consume — work through the 7-point API design checklist in `references/plan-templates.md § API Design Step` (endpoint design, request/response schemas, authentication, rate limiting, versioning, error responses, webhook events). Add the resulting API design notes to the `## Files` section (new controller/route entries) and `## Acceptance Criteria` (API contract tests).

## Plan integrity verification (Post-write gate — v3.8.5)

After writing `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`, before
proceeding to step 6 (prompt generation), verify the artifact's
integrity. This catches the failure mode where synthesis ran but
emitted an incomplete plan (missing required sections, malformed
markdown, file write silently failed).

### Checks (run in order)

```bash
# Gate 0: variable provenance preflight
: "${PROJECT_ROOT:?ERROR: PROJECT_ROOT not set — cannot resolve plan path}"
: "${TIMESTAMP:?ERROR: TIMESTAMP not set — cannot resolve plan path}"
: "${CLAUDE_SESSION_ID:?ERROR: CLAUDE_SESSION_ID not set — cannot resolve plan path}"

mkdir -p "${PROJECT_ROOT}/.v/artifacts" 2>/dev/null || true
PLAN_PATH="${PROJECT_ROOT}/.v/artifacts/PLAN_${TIMESTAMP}_${CLAUDE_SESSION_ID}.md"   # Phase-2 relocation: planning artifacts live under .v/artifacts (readers dual-search; root = legacy fallback)

# Gate 1: file exists and is non-empty
[ -s "$PLAN_PATH" ] || {
  echo "FAIL: plan file missing or empty: $PLAN_PATH"
  exit 1
}

# Gate 2: all 6 required sections present (PLAN_SCHEMA core).
# Regex allows the section name to be followed by optional descriptive
# suffix (e.g., "## Tests Required (auto-generated)") — matches the
# real-world plans where authors annotate section headers.
REQUIRED=("Summary" "Scope" "Files" "Tests Required" "Acceptance Criteria" "Rollback Notes")
MISSING=()
for section in "${REQUIRED[@]}"; do
  # Match "## Summary", "## Tests Required (anything)", "### Scope — annotated", etc.
  if ! grep -qE "^#{2,3}[[:space:]]+${section}([[:space:]].*)?$" "$PLAN_PATH"; then
    MISSING+=("$section")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "FAIL: PLAN missing required sections from PLAN_SCHEMA:"
  printf "  - %s\n" "${MISSING[@]}"
  echo ""
  echo "Re-run plan synthesis with all 6 sections present."
  echo "See SKILL.md § Required Plan Sections for the canonical list."
  exit 1
fi

# Gate 3: effort estimate present at Standard/Comprehensive depth.
# Default V_DEPTH and PLAN_DETAIL (mirrors the --detail= invocation flag above) to safe values when unset.
V_DEPTH="${V_DEPTH:-0}"
PLAN_DETAIL="${PLAN_DETAIL:-quick}"
if [ "$V_DEPTH" -ge 1 ] || [ "$PLAN_DETAIL" = "standard" ] || [ "$PLAN_DETAIL" = "comprehensive" ]; then
  if ! grep -qE "^##[[:space:]]+Effort Estimate([[:space:]].*)?$" "$PLAN_PATH"; then
    echo "WARN: Standard/Comprehensive plan should include '## Effort Estimate' section"
    # Warning, not failure — operator may have intentionally elided
  fi
fi

echo "PLAN integrity verified — all required sections present at $PLAN_PATH"

# W42-F6: write PLANNING_PASS_<sid>.md marker so the Stop hook accepts the
# session as planning-only and does not require PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE.
# The Stop hook validates this marker structurally:
#   - PLANNING=1
#   - PLAN_FILE=<existing path>
#   - FILES_MODIFIED=0 (any non-zero rejects the marker)
#   - ≥80 bytes
# If a planner accidentally edited a source file, FILES_MODIFIED won't be 0 and
# the marker is rejected — falling back to the regular gauntlet (correct).
# Defense-in-depth: the Stop hook does NOT trust this self-reported field — it
# independently recomputes the real changed-file count from the same canonical
# writes log before honoring the marker. This self-count is a fast local check,
# not the authority.
PLAN_REL=$(printf '%s' "$PLAN_PATH" | sed "s|^${PROJECT_ROOT}/||")
PLANNING_MARKER="${PROJECT_ROOT}/.v/artifacts/PLANNING_PASS_${CLAUDE_SESSION_ID}.md"
# Files modified by THIS session (excluding the plan file itself).
# Resolve the canonical writes-log path the same way the Stop hook does
# (hooks/lib/session-writes.sh § session_writes_log_path): it lives at
# ${git-common-dir}/claude-session-writes-<SID>.txt, NOT under .v/tmp.
# Source the shared helper when reachable; else fall back to the identical
# git-common-dir construction so a stale/relocated hooks dir can't break us.
if ! type session_writes_log_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh" 2>/dev/null || true
fi
if type session_writes_log_path >/dev/null 2>&1; then
  SESSION_WRITES_LOG=$(session_writes_log_path "$CLAUDE_SESSION_ID" 2>/dev/null || echo "")
else
  _git_dir=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null \
             || git -C "$PROJECT_ROOT" rev-parse --git-dir 2>/dev/null \
             || echo "$PROJECT_ROOT/.git")
  SESSION_WRITES_LOG="${_git_dir}/claude-session-writes-${CLAUDE_SESSION_ID}.txt"
fi
FILES_MODIFIED_COUNT=0
if [ -n "$SESSION_WRITES_LOG" ] && [ -f "$SESSION_WRITES_LOG" ]; then
  # track-session-writes.sh records REPO-RELATIVE paths, so exclude the plan by
  # its relative form ($PLAN_REL) — plus the PLANNING_PASS marker itself — exactly
  # as check-review-artifact.sh does. Using the absolute $PLAN_PATH here would
  # never match a relative log entry and would over-count by one.
  FILES_MODIFIED_COUNT=$( ( grep -v '^$' "$SESSION_WRITES_LOG" 2>/dev/null \
    | sort -u \
    | grep -v -F "$PLAN_REL" 2>/dev/null \
    | grep -v -F "PLANNING_PASS_${CLAUDE_SESSION_ID}.md" 2>/dev/null \
    ) | wc -l | tr -d ' ' )
  FILES_MODIFIED_COUNT=${FILES_MODIFIED_COUNT:-0}
fi
cat > "$PLANNING_MARKER" << MARKER
PLANNING=1
PLAN_FILE=${PLAN_REL}
FILES_MODIFIED=${FILES_MODIFIED_COUNT}
SESSION_ID=${CLAUDE_SESSION_ID}
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

This session was planning-only. The Stop hook accepts this marker
in lieu of PRE_FLIGHT_REPORT, AGENT_REVIEW, and VERIFY_DONE_REPORT.
PLAN file: ${PLAN_REL}
MARKER
echo "PLANNING_PASS marker written: $PLANNING_MARKER (FILES_MODIFIED=${FILES_MODIFIED_COUNT})"
```

### Behavior on failure

If Gate 1 fails (file missing): the write step itself failed.
Re-attempt the write with the same payload. If second attempt also
fails, surface as BUILD_BLOCKER (filesystem error / permissions).

If Gate 2 fails (missing sections): the synthesis was incomplete.
Re-task the planner with: *"The plan you wrote at $PLAN_PATH is
missing the following required sections from PLAN_SCHEMA: {list}.
Append these sections to the existing file (do not rewrite from
scratch). Each section MUST follow the format specified in
SKILL.md § Required Plan Sections."*

If Gate 3 warns (no effort estimate at Standard/Comprehensive
depth): emit the warning but proceed. Operator may have a reason;
this is informational not blocking.

### Why this gate exists

v-plan workflow step 5 writes the plan file. Without verification,
two failure modes are silent:

1. The Write tool succeeded but the file content is malformed
   (synthesis cut short, headers missing, markdown corrupted).
2. The PLAN_SCHEMA changed and the planner missed a new required
   section.

Both produce a "looks done" plan that downstream `/v-build` will
fail to execute against. The integrity gate catches them at
write-time, when the planner's context is still warm.

Mirrors the file-existence verification pattern from v-ui-audit's former Gate 8 (v-ui-audit absorbed into `/v-audit-code` 2026-07-06).

## Quality Rules

1. **Proceed with explicit assumptions when information is missing** — document assumptions clearly in the plan so they can be validated by reviewing the plan artifact. Only block if missing information would make the plan unsafe (e.g., unknown database engine for migration strategy).
2. **Explore before deciding** - Find existing patterns
3. **Choose the best approach and document alternatives** — make a decision, explain rationale, note what you'd do differently if assumptions are wrong
4. **Be specific** - Include file paths, not just concepts
5. **Keep plans actionable** - Ready for v-build
6. **Include "Out of Scope"** - Prevent creep
7. **Solo-dev calibration** — For solo developers, note that calendar time = effort hours (no parallelization across people). Add 1.5× multiplier for context switching overhead when estimating elapsed time.
8. **Effort estimates required** — Standard/Comprehensive plans without effort estimates are incomplete.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Plan written but lacks `## Files` section → v-build can't find scope | PLAN_SCHEMA validation skipped | Validate against PLAN_SCHEMA before writing; all 6 core headings (Summary / Scope / Files / Tests Required / Acceptance Criteria / Rollback Notes) required |
| 2 | Plan routes to feature design when problem is actually a refactor | Route-detection wrong | Read project's existing code first; if request is "improve X" without behavior change, route to v-audit-code not v-new-feature |
| 3 | Plan estimates effort hours; v-build session takes 10x | Effort estimation hallucinated | Effort hours come from operator if provided, OR from "small/medium/large" T-shirt sizing; never invent precise numbers |
| 4 | Plan references files that don't exist in the project | Files inferred from request, not verified | `## Files` list MUST be verified by glob/find before writing — non-existent files = invalid plan |
| 5 | Plan ships without `## Rollback Notes` for a destructive change | Rollback notes treated as optional | If `## Files` includes any DESTRUCTIVE op (delete, drop column, force-delete), Rollback Notes is mandatory + concrete |
## Idempotency

**Idempotent for the input.** Re-running on the same prompt produces a fresh PLAN_*.md; output structure is stable but specific ordering may vary. Filesystem-mutating: writes plan artifact.
