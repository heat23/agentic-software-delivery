# V Audit — Shared Contracts for All Audit Skills

Shared boilerplate for `v-audit-*` and `v-check` skills. Individual skill contracts override on conflict.

## Audit Skill Opener (Mandatory Boilerplate Bundle)

Every audit skill MUST execute these pre-steps in order before
Step 0 begins (i.e., before any orientation, file reads, or
dim work). The individual steps are detailed in their
own sections below; this bundle exists so audit skill bodies can
reference one place instead of scattering pointers.

| # | Step | Section in this file |
|---|---|---|
| 1 | Resolve `PROJECT_ROOT` | `## PROJECT_ROOT Resolution` |
| 2 | Parse `V_DEPTH` | `## V_DEPTH Parsing` |
| 3 | Initialize the task list (TaskCreate) | `## TodoWrite Progress Reporting` |

**Failure to complete any step is a contract violation.** The
audit will produce stale or unsafe output (writing artifacts to
`pwd` outside the project, asking entry-point questions when
called from an orchestrator, no progress visibility).

Beyond these pre-steps, every audit skill is bound for the whole
run by `§ In-App Actionability Boundary` below — off-stack items
never become findings, scores, or prompt packs.

When a skill body references this bundle, it can use the single
line:

> **Audit opener:** see `_v-audit.md` § Audit Skill Opener.

Skills that need to override one step (e.g., a skill that takes
project context via args and skips PROJECT_ROOT detection) should
reference this bundle and then explicitly note the override
inline.

---

## PROJECT_ROOT Resolution (Mandatory — Before Step 0)

Every audit skill runs with `context: fork`, so `pwd` returns a Claude-internal directory (`~/.claude/plans/`), NOT the repo. Resolve the project root **before any file reads or writes**:

1. If `PROJECT_ROOT=` appears in the invocation prompt, use that path
2. Otherwise, run `git rev-parse --show-toplevel 2>/dev/null`
3. If that still does not yield a safe repo root, stop and ask the user for the project path. Do NOT fall back to `pwd`.

```bash
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "ERROR: Cannot detect project root. Pass PROJECT_ROOT= in invocation."
  exit 1
fi
if [ -n "${HOME:-}" ] && [ "$PROJECT_ROOT" = "$HOME" ]; then
  echo "ERROR: Refusing to use \$HOME as PROJECT_ROOT: $PROJECT_ROOT"
  exit 1
fi
case "${PROJECT_ROOT%/}" in
  /|/Users|/home|/root|/tmp|/var|/usr|/etc|/bin|/sbin|/opt|/private|/System|/Library|/Volumes|/dev|/proc|/sys)
    echo "ERROR: Refusing to use filesystem-level root as PROJECT_ROOT: $PROJECT_ROOT"
    exit 1
    ;;
esac
echo "Project root: $PROJECT_ROOT"
cd "$PROJECT_ROOT"
```

**All file paths MUST be prefixed with `$PROJECT_ROOT/`.** Never write artifacts to `pwd` without first confirming it equals `$PROJECT_ROOT`.

## V_DEPTH Parsing (Mandatory — At Startup)

Parse V_DEPTH from invocation args per `_v-core.md` § V_DEPTH Parsing Protocol. Search for `[V_DEPTH=N` or `V_DEPTH=N` in the prompt. Default to 0 if absent.

| V_DEPTH | Entry-point questions | Default depth |
|---------|----------------------|---------------|
| 0, no explicit params | ASK via AskUserQuestion | — |
| 0, with explicit params | Use those params directly | — |
| >= 1 (orchestrator) | SKIP all questions | Thorough (skill-specific) |

## Depth Question Contract (Canonical — All Audit Skills)

Every standalone audit skill (`v-audit-*`) MUST present a depth question to the user at `V_DEPTH = 0` invocation when the depth is not in the prompt. The shape is canonical so operators see the same UX across the family. Skip rules and orchestrator default behavior live in the V_DEPTH table above.

### Canonical 3-tier question

```yaml
question: "How deep should this {domain} audit go?"
header: "Audit Depth"
multiSelect: false
options:
  - label: "Quick — for iteration"
    description: "{tier-1 dimensions, named}. ~{N} min."
  - label: "Standard — recommended default"
    description: "{tier-1 + tier-2 dimensions, named}. ~{N} min."
  - label: "Thorough — pre-launch / pre-merge"
    description: "All {total} dimensions, parallel subagents. ~{N} min."
```

The skill plugs in `{domain}` (e.g., "messaging", "growth", "SEO"), the dimension lists per tier, the totals, and time estimates. Wording, labels, header, and the `multiSelect: false` constraint are FIXED — do not improvise.

### Behavior

- `V_DEPTH = 0` interactive → MUST ASK this question. No silent defaults.
- `V_DEPTH ≥ 1` orchestrator-invoked → SKIP and default to Thorough.
- If the depth is already declared in the invocation prompt (e.g., the operator typed `quick` or `thorough` as a hint), use that and skip the question. Free-form depth keywords (`fast`, `full`, `deep`, `comprehensive`) map: `fast/quick/light` → Quick; `default/normal/standard/medium` → Standard; `full/thorough/deep/comprehensive` → Thorough.

### Permitted deviation: topic-axis

A skill MAY extend the canonical 3-tier when its audit has a real topic axis the operator legitimately splits along (e.g., `v-audit-sales-pricing` runs Pipeline-only and Pricing-only as observed real workflows). In that case:
- Header stays `"Audit Depth"`.
- Quick and Thorough remain.
- Topic-axis options replace Standard or are inserted between Quick and Thorough.
- The skill's SKILL.md documents the deviation in a "Why this skill deviates from the canonical depth question" subsection, citing the operator workflow that justifies it.

Other skills MUST NOT copy a deviation without a matching workflow justification.

### Permitted deviation: meta-skills without a depth axis

A consolidator/meta-skill that consumes other audits' OUTPUTS instead of running audit dimensions (e.g., `v-audit-consolidate`) has no dimension tiers for a depth question to vary. Such a skill MAY substitute its own single scope question (e.g., "Which audit reports to consolidate?") for the canonical 3-tier question entirely, provided its SKILL.md documents the substitution inline as an intentional override citing this clause.

### Tier-design responsibility

Each skill's SKILL.md declares which dimensions run at each tier. The principle:
- **Quick** — the 1-2 most-changed dimensions; the answer the operator wants in <5 min between code edits.
- **Standard** — the dimensions an operator would run weekly; covers ~50% of the audit surface; the recommended default.
- **Thorough** — every dimension; pre-launch / pre-merge / quarterly-review depth.

Time estimates in option descriptions are the source of truth for operator expectations and orchestrator cost estimation. Update them when dimension counts change.

## TodoWrite Progress Reporting (Mandatory)

> **Tool rename (2026-07-05):** the harness no longer exposes a `TodoWrite` tool — the current task-tracking tools are **`TaskCreate`** (create the step list at start) and **`TaskUpdate`** (status transitions). This heading is kept for anchor stability; skill prose that still says "TodoWrite initialization" means this section. When granting tools in frontmatter, grant `TaskCreate, TaskUpdate` — a `TodoWrite` grant is dead.

Every audit skill MUST track progress at every major step. Create the step list at the start (one TaskCreate per workflow step), e.g.:

```
TaskCreate: "Orientation & project context"          → TaskUpdate → in_progress immediately
TaskCreate: "Launch audit dimensions in parallel"
TaskCreate: "Consolidate results and score"
TaskCreate: "Generate implementation prompts"
TaskCreate: "Write report and validate"
```

Update the status via TaskUpdate as each step completes. Mark the current step `in_progress` BEFORE starting it. This is the user's only visibility into progress.

**Availability fallback:** if the task tools are unavailable in the current context (restricted `allowed-tools`, forked execution without them), proceed WITHOUT task tracking — progress reporting is best-effort; its absence is never a reason to block or fail the audit (a scoped exception to the opener bundle's contract-violation rule, which otherwise stands).

## In-App Actionability Boundary (Mandatory — All Audit Skills)

Audit output exists to be executed autonomously: findings become prompt packs, and the operator runs `run-v-packs` on them WITHOUT reading them first. Every finding must therefore be actionable by a `/v` session editing the repository. Anything else is noise: it pollutes scores, burns remediation budget on work the orchestrator cannot complete, and re-appears as a permanently-open item every audit cycle.

**The test:** could a `/v` session complete the fix by editing files in this repo, with its existing stack and dependencies, verified by the project's own quality gates? If no → off-stack → banned from findings.

**Off-stack (banned from findings, scores, verdicts, and prompt packs):**

- Infrastructure/hosting: high availability, load balancing, failover, disaster recovery, offsite/replicated backups, server sizing/scaling
- External monitoring/alerting: uptime services, APM, error-tracking/paging SaaS (Sentry/PagerDuty-class), status pages, log-aggregation services
- Ops process: runbooks, on-call rotations, incident-response process, ops documentation. Writing a runbook/DR-plan `.md` INTO the repo is still ops-process work — equally banned. Never launder an off-stack item into an in-repo doc-writing task.
- Platform/pipeline: CI/CD platform setup, deployment-pipeline infrastructure, DNS/CDN/email-deliverability infrastructure
- Any new third-party vendor, hosted service, or paid tool (extends the solo-motion rules in `references/v-core-solo-motion.md` from outreach to infrastructure)

**Still in scope (in-app twins — do NOT over-ban):**

- Correctness of operational *code* that ships in the repo: scheduled tasks, health/self-check endpoints or commands, backup/restore/verification commands, queue and failed-job admin surfaces, in-app alerting/notification code
- Shipped-config hygiene: debug flags that must be off in production, permissive CORS, unsafe defaults, whether the env-template would produce a safe deployment as written
- Structured logging, in-app error handling, rate limiting — anything the repo itself implements with its existing stack
- Correctness of CI/CD or deploy config files already committed to the repo (workflow YAML pinning/permissions, Procfile-class manifests) — the ban is on provisioning/choosing platforms and pipeline infrastructure, not on fixing committed config
- **AI-crawler edge-accessibility (the ONE named cross-boundary exception, 2026-08-12):** CDN/WAF-layer blocking of citation-tier AI bots, detected by live per-UA fetch (v-audit-seo anti-pattern I3), IS a valid scored finding in v-audit-seo (Dims 1/7) even though remediation may be an edge-config change rather than an in-repo diff — it is the dominant real-world AI-citation killer and invisible to repo inspection. This exception is exhaustive: it does not open the door to any other infra finding, and `v-audit-consolidate` MUST honor it (do not drop these findings as off-stack).

**Rules:**

1. Off-stack items MUST NOT appear in the findings array, MUST NOT lower any score or flip any verdict, and MUST NOT reach a prompt pack (§ 3c below carries the pack-side filter; it is the last line of defense, not a substitute for clean findings).
2. Where a genuinely valuable practice sits outside the boundary, record it ONLY in the off-stack ledger (below) — or omit it entirely. Never present it as a finding, score input, or recommendation.
3. This section binds every `v-audit-*` skill and `v-check`, standalone AND batch mode. A skill's own scope section may be stricter than this boundary, never looser.
4. `v-audit-consolidate` MUST drop any off-stack finding it encounters in source reports (reports written before this boundary existed may still contain them) instead of carrying it into consolidated output, scores, or packs; it MAY move the dropped item to the ledger.

### Off-stack ledger (central, latest-wins)

`$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` is the single home for deferred off-stack observations — kept so the information isn't lost, isolated so it never enters the execution pipeline.

- **Standalone mode only.** Batch/consolidation mode (the four-flag context in § Consolidation / Batch Mode Contract, most simply detected via `RETURN_JSON_ONLY=1`) MUST skip the ledger write — the JSON-only contract stands.
- Each skill owns exactly one section, headed `## <full-skill-name> — <YYYY-MM-DD>`. On re-run, REPLACE your own section in place (latest-wins). Never append duplicate sections; never edit another skill's section.
- At most 10 bullets, one line each: the observation plus why it is off-stack. No severities, no scores, no effort estimates, no implementation steps — the ledger must not look like a findings list, or something will eventually treat it as one.
- **Nothing reads this file downstream.** Prompt-pack generation, `v-audit-consolidate` scoring/dedup, and `run-v-packs` MUST ignore it. It is for the operator's eyes only.
- Create the parent dir if missing (`mkdir -p "$PROJECT_ROOT/.v"`). The write is optional: with zero off-stack observations, do not create or touch the file.

## Evidence Discipline (Mandatory — All Audit Skills)

Six rules. Each one is here because it produced measurably wrong output in a real audit,
not because it sounds prudent.

**E1 — Normalise every traffic/usage figure to the CURRENT run rate before it
drives a decision.** A ratio computed over a cumulative export window and then
applied to a present-tense choice is the single most damaging error in this family.
Measured case: a few content categories held a large share of clicks over a
multi-month analytics export, which drove a recommendation *against* removing them. The
current rate was a small fraction of the window average, so the real exposure was
**only a handful of clicks/month** — the opposite advice for two rounds. Any finding
citing a traffic quantity MUST state the window and the current rate side by side
(`<N> clicks over <M> months = ~<X>/month today`). A bare percentage of a cumulative
total is not evidence.

**E2 — Measured counts only; never extrapolate a corpus-wide number from a sample.**
If a pattern is claimed site-wide, scan the corpus and report the count. State `n`
scanned. Measured case: two reviewers extrapolated a corpus-wide instance count from 2
sampled pages; a full scan found a **far smaller number**. If a full scan is genuinely
infeasible, say "found in N of M sampled" — never project.

**E3 — Subagent findings are hypotheses until independently reproduced.** Re-verify
before a finding reaches a report. Re-verification changed the answer three times in
one engagement (two corpus-wide counts that collapsed on a full scan; "the main feature
errors"→ the main feature works, a *repeated example* errors). Corollary, and it cuts
both ways: brief subagents to **refuse the premise** when it is wrong — several briefing
premises were correctly rejected by subagents in that same engagement, and shipping
them would have introduced new defects while fixing old ones.

**E4 — Cite the version the software reports about itself.** `mysql --version` is the
client; `SELECT VERSION()` is the server (the two can differ by a major version). Same trap: `php -v` vs the
FPM pool, `node -v` vs the deployed runtime, `psql --version` vs `SHOW server_version`.

**E5 — Verify in both directions, and read context before calling a hit.** "Is the bad
pattern gone?" alone produces false alarms — corrected pages often *quote* the old
advice in order to correct it. "Is the fix present?" alone misses partial fixes — a
JSON-LD cleanup that left the OpenGraph equivalent emitting. Check for removal AND
presence, and read the surrounding text before reporting either.

**E6 — Run the falsifier before any surface-wide claim ships.** Before a claim of the form
"X% of the site / all pages of type Y / these flags look accidental" reaches a report, run
the query that could falsify it — the second category, the opposite polarity, the cohort not
yet checked. Measured case: "a third of the pages are noindexed, flags look
inherited" — one category query showed most of them sat in deliberately-excluded
categories; the actionable set was much smaller and the drafted finding was wrong. A finding walked back after
presentation should never have been sent. Where the falsifier genuinely cannot be run, state
the claim as unchecked in the same breath, never flat.

## Data-Sufficiency Posture (Mandatory — All Audit Skills)

Alongside each skill's greenfield/launched detection, classify the **evidence
surface**. Below the analytics noise floor, first-party data cannot answer content or
performance questions, and an audit that pretends otherwise manufactures findings.

```bash
DAILY_CLICKS=$(awk -F, 'NR>1{c+=$2; n++} END{if(n)printf "%.1f", c/n}' \
  .seo/gsc-export-*/Chart.csv 2>/dev/null | tail -1)
SUBNOISE=$(awk -v d="${DAILY_CLICKS:-0}" 'BEGIN{print (d>0 && d<10) ? 1 : 0}')
```

When `SUBNOISE=1`:
- Use the `early` floor column (see `references/v-audit-floors.md` § Data-sufficiency
  override) — an honest under-floor return is a valid result, not a re-task trigger.
- Force `confidence: low` on any finding whose evidence is a traffic, CTR, or
  position delta.
- **Preservation arguments are void by default.** Any "keep this" finding must state
  the item's current clicks/month; below ~1/month, state that removal cost is ~zero.
- Open the report with, verbatim: *"This site is below the analytics noise floor
  (<N> clicks/day). Index and coverage changes will surface within weeks; click
  changes will not be measurable for months. Flat traffic is the expected short-term
  outcome and is not evidence of failure."*

`SUBNOISE=1` is orthogonal to greenfield/launched — a site can be launched, years
old, and still sub-noise. Never let project maturity imply evidence maturity.

## Consolidation / Batch Mode Contract

Audit skills support headless batch execution when the invocation context includes **all four** flags:
- `V_CHAIN=ecosystem-review-runner`
- `HEADLESS_BATCH=1`
- `CONSOLIDATION_MODE=1`
- `RETURN_JSON_ONLY=1`

**Batch mode rules:**
1. Skip all entry-point questions. Use the explicit depth in the invocation prompt, or default to Thorough / Full (the most comprehensive mode the skill supports) if omitted.
2. **Write the JSON report to disk.** The file path MUST be:

   `$PROJECT_ROOT/<DOMAIN>_AUDIT_<YYYYMMDD_HHMMSS>_<CLAUDE_SESSION_ID>.json`

   Use the skill's canonical filename prefix as defined in its own SKILL.md. The canonical prefixes are:
   - `/v-audit-admin` → `ADMIN_AUDIT_REPORT_`
   - `/v-audit-analytics` → `ANALYTICS_AUDIT_`
   - `/v-audit-growth` → `GROWTH_AUDIT_`
   - `/v-audit-messaging` → `MESSAGING_AUDIT_`
   - `/v-audit-sales-pricing` → `SALES_PRICING_AUDIT_`
   - `/v-audit-seo` → `SEO_AUDIT_`

   Concrete example (SEO): `SEO_AUDIT_20260101_120000_<session-id>.json`

   The runner's integrity gate scans `$PROJECT_ROOT/` for files matching the glob `<DOMAIN>_AUDIT_*.json` using the skill's own prefix. Do NOT print the JSON to stdout in place of writing the file — the runner reads from disk, not stdout. The `RETURN_JSON_ONLY=1` flag means "do not produce non-JSON artifacts (companion Markdown, prompt packs)"; it does NOT mean "stream JSON to stdout instead of writing it." Return the same JSON schema and scoring logic as standalone mode.
3. **Filename self-check before Write.** Before calling the Write tool, build the target path as a single string and verify its basename begins with the skill's canonical prefix from rule 2. If the candidate basename begins with anything else — including any generic "ecosystem" variant or a different domain's prefix — discard it and rebuild from the template above.
4. Do not write the companion Markdown report.
5. Do not generate the `.v-prompt-packs/<full-skill-name>-<MM-DD>/` prompt pack directory (batch mode skips prompt packs entirely — JSON only).
6. Stay centered on the skill's audit domain — do not drift into adjacent domains.
7. Outside this trusted headless runner chain, keep normal standalone behavior.

> **Authority note:** If a skill's own SKILL.md defines its own Headless Batch Consolidation Mode section with explicit rules, that section takes precedence over this shared contract on any conflict.

## Mandatory Execution Workflow Pattern

**Every standalone invocation MUST complete ALL steps. Do NOT stop after writing the audit report.**

| Step | Action | Produces |
|------|--------|----------|
| **Step 0** | Orientation — read CLAUDE.md, detect stack | Project context |
| **Step 1** | Launch audit dimensions in parallel as fork-safe `claude -p` subprocesses (via `v-dispatch-subagent.sh` — NEVER the Agent tool; see § Step 3 Dispatch template) | Per-dimension findings |
| **Step 2** | Consolidate results, score, write JSON + MD report | Audit report |
| **Step 3** | **Generate implementation prompts (MUST USE SUBAGENT)** | `.v-prompt-packs/<full-skill-name>-<MM-DD>/` directory |
| **Step 3.5** | Validate JSON before write | Valid JSON |
| **Step 4** | Validate prompt pack + present summary | Verified deliverables |

**Steps 3-4 are NOT optional.** Prompt files are the primary deliverable — users run these in parallel sessions. The audit report without prompts is an incomplete output.

**Threshold note:** Specialist audit skills generate prompt packs unconditionally in standalone mode (Steps 3-4 always run). `/v-plan` uses a different policy: prompt packs are conditional on 4+ implementation tasks at Standard/Comprehensive depth. Do not conflate the two thresholds.

## Step 3: Prompt Generation Contract (MUST USE SUBAGENT)

**CRITICAL: Prompt generation MUST be dispatched to a separate subagent — as a fork-safe `claude -p` subprocess (see the Dispatch template below), NEVER via the Agent tool.** By the time prompt generation runs, the main context has consumed 50k-200k+ tokens on audit dimensions. Inline generation will truncate or skip files.

**Pre-dispatch — archive prior pack, then create the parent directory (mandatory):**

```bash
# PROMPT_DIR is set per-skill per references/v-core-prompt-pack.md "Per-skill MUST-USE values" table.
# Format: .v-prompt-packs/<full-skill-name>-<MM-DD> (no abbreviations; caller computes date dynamically via $(date +%m-%d)).
# Example: PROMPT_DIR=".v-prompt-packs/v-audit-messaging-$(date +%m-%d)"

# Idempotent re-run: archive any prior pack to a timestamped sibling, then start clean.
# Without this, a re-run that produces fewer or differently-named .txt wave packs leaves stale files
# from the prior run orphaned in the dir. The post-generation validator counts them and reports a
# false-positive PASS even though the operator may paste a stale prompt for an already-cleared finding.
if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
  PACK_TS=$(date +%Y%m%d-%H%M%S)-$(printf '%04x' $RANDOM)
  mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$PACK_TS"
  echo "Archived prior pack → $PROMPT_DIR.bak-$PACK_TS"
fi
mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
```

**Backup retention:** `.bak-YYYYMMDD-HHMMSS-XXXX/` siblings accumulate across re-runs. The operator deletes them when no longer needed (`rm -rf .v-prompt-packs/*.bak-*`). Skills MUST NOT auto-delete backups — that loses history without consent.

**Project `.gitignore` guidance (recommended):** to prevent accidental commit of accumulated backups, projects using audit-family skills SHOULD add this rule to `.gitignore`:

```gitignore
.v-prompt-packs/*.bak-*/
```

The active pack (`.v-prompt-packs/<full-skill-name>-<MM-DD>/`) is intentionally tracked-or-ignored per the project's existing rule for `.v-prompt-packs/`. Only the backups need the wildcard. If the project does NOT track `.v-prompt-packs/` at all (already gitignored as `/.v-prompt-packs/`), the `*.bak-*/` rule is implicitly covered.

**Concurrency contract:** only one audit skill of a given name (e.g., `/v-audit-messaging`) should run per project at a time. Concurrent runs on the same `PROMPT_DIR` will race on the pre-dispatch archive — the second run finds the dir empty (after the first run's `mv`) and silently loses its prior pack history. The skill's `mkdir -p` is idempotent, but the surrounding archive check is not atomic. If parallel audits are needed (e.g., across worktrees), use distinct `PROJECT_ROOT` paths so `PROMPT_DIR` resolves to non-overlapping dirs.

If `$PROMPT_DIR` does NOT begin with `.v-prompt-packs/v-`, abort — the skill is using a stale path. See `references/v-core-prompt-pack.md` § Unified folder convention.

### Step 3 Dispatch template

**Fork-safe — the Agent tool DOES NOT WORK here:** audit skills run `context: fork`, i.e. they ARE subagents, and a subagent cannot dispatch another subagent via the Agent tool (platform limit, re-verified 2026-05-24 on Claude Code 2.1.150 — see `/v` SKILL.md § D2). An `Agent(...)` call from an audit skill fails silently and degrades to inline generation on the already-consumed main context — exactly the truncation this contract exists to prevent. Dispatch an independent `claude -p` subprocess via the shared helper instead:

```bash
BRIEF_FILE="$SCRATCH_DIR/prompt-pack-brief.md"   # or mktemp; write the FULLY-SUBSTITUTED brief
cat > "$BRIEF_FILE" <<BRIEF
Generate implementation prompt files from this audit report.

PROJECT_ROOT=$PROJECT_ROOT
PROMPT_DIR=$PROMPT_DIR   # e.g., .v-prompt-packs/v-audit-messaging-<MM-DD>

1. cd $PROJECT_ROOT first — do NOT write files to pwd without confirming it equals PROJECT_ROOT
2. Read the audit JSON at $PROJECT_ROOT/[AUDIT_FILE].json
3. Read the companion .md report at the same path with .md extension
4. Read the project's CLAUDE.md for tech stack and quality gate commands
5. Follow the prompt generation algorithm below EXACTLY
6. Write all files to $PROJECT_ROOT/$PROMPT_DIR/ (full path: $PROJECT_ROOT/.v-prompt-packs/<full-skill-name>-<MM-DD>/). The parent dir was created by the caller; you MUST NOT write outside this directory.

[PASTE COMPLETE TEXT OF SECTIONS 3a, 3b, 3c HERE — NOT A REFERENCE]
BRIEF

V_DISPATCH_TIMEOUT_SEC=5400 ~/.claude/skills/v/references/v-dispatch-subagent.sh \
  --model parent --mode self-write --extra-tools "Write Edit" \
  --prompt-file "$BRIEF_FILE" \
  --artifact "$PROJECT_ROOT/$PROMPT_DIR/00-README.md"
```

`--mode self-write` means the subprocess writes the artifact itself — but it does NOT by itself grant the Write tool. With `--model` and no `--agent` the helper parses no frontmatter `tools:` line and falls back to its read-only default (`Bash Read Grep Glob BashOutput`), while the mode's own epilogue instructs the child to "Write your artifact using the Write tool" — so `--extra-tools "Write Edit"` is REQUIRED on this dispatch (corrected 2026-09-11 against `v-dispatch-subagent.sh` § Derive the tool allowlist; the old wording asserted a grant the helper never makes, and a child without it can only write via Bash heredocs). `V_DISPATCH_TIMEOUT_SEC=5400` because the 900 s default killed a large pack mid-write at its ceiling. The helper verifies the witness artifact (`00-README.md`) landed non-empty. Completion = files on disk (Step 4 validates the full pack) — never the subprocess's prose exit message.

**IMPORTANT:** You MUST copy-paste the full text of sections 3a, 3b, and 3c from the specialist skill's own SKILL.md into the briefing file. The subprocess has no access to the skill file or to this shared module.

### 3a. Build the File Dependency Graph

1. **Extract file targets** — for every finding, list every file it touches (files to modify + test files to create).
2. **Build a conflict graph** — two findings conflict if they share any file target.
3. **Cluster connected components** — findings that share files (directly or transitively) must go in the same session.
4. **Handle dependencies** — if finding A depends on finding B, they must be in the same session (or A's session must be marked as "run after B's session").

### 3b. Assign Sessions

1. **Size each session at 15-40 estimated hours.** If a session has fewer than 3 findings, merge into the most related session.
2. **Theme each session** — descriptive name based on the dominant domain/funnel stage.
3. **Order findings within each session** by priority (P0 first), then by dependency order, then by effort (smallest first).
4. **Sort sessions** by priority of their highest-priority finding.

Aim for 3-6 sessions total. Individual skills define domain-specific default groupings.

### 3c. Write the Wave Packs

Create `$PROMPT_DIR` (caller already ran `mkdir -p`). Emit the **unified `.txt` wave form** defined in
`references/v-runnable-pack-convention.md` (§ Canonical form + § Pack body schema) — NOT the legacy
`NN-*.md` shape. Independent findings (disjoint files) are all wave 0 (no prefix); order only where a
real conflict/dependency requires it (`w1-`, `w2-`); append a `99-verify.txt` closer:

```
.v-prompt-packs/<full-skill-name>-<MM-DD>/
  00-README.md              ← wave map + deps (NOT a pack)
  {theme}.txt               ← wave 0: self-contained /v pack (copy-paste ready)
  w1-{theme}.txt            ← wave 1: runs after wave 0 (only when ordered)
  99-verify.txt             ← read-only final verify, runs last
```

**00-README.md** must include:
- Project name, audit date, total findings, estimated total hours
- Wave map table: `| # | Pack file | Wave | Theme | Domain | Findings | Can Parallel? |`
- Dependencies between packs
- Post-merge quality gate commands from CLAUDE.md

**Closing waves (MANDATORY — never hand over a tree that stops at "implemented"; per `v-runnable-pack-convention.md` § Closing waves).** After the last implementation wave, append, as the highest wave prefixes: a parallel READ-ONLY verification wave — `w<N>-pre-flight.txt` (runs the project's full gates) + `w<N>-review.txt` (dispatches the adversarial/second-opinion reviewer agents) — then a single sequential `w<N+1>-hardening.txt` (triages the review findings, fixes CRITICAL/HIGH, re-runs gates, runs `/v-verify-done`), then the read-only `99-verify.txt` last. The read-only packs use `## Goal / ## Checks / ## Acceptance` and OMIT the "leave staged" line.

**Security-bearing packs (MANDATORY — per `v-runnable-pack-convention.md` § Security-bearing packs).** When a pack's `## Files` set touches request signing / HMAC / webhook or signature verification, credential/secret handling, host/URL construction from variables, auth/authz decisions, or payment flows, that pack's body MUST inline: "This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own diff before finishing; fix CRITICAL/HIGH in-session." The closing review wave does NOT substitute — it is defense-in-depth for the window between staging and landing.

**Each pack file (`.txt`)** carries the mandatory **body schema** (line 1 = `/v …`, then
`## Goal / ## Context / ## Files / ## Changes / ## Acceptance criteria / ## Tests / ## Constraints /
## Dependencies`; read-only verify packs use `## Goal / ## Checks / ## Acceptance`):
- Line 1 starts with `/v ` (orchestrator routing prefix)
- `## Constraints` includes `Read the project's CLAUDE.md first` and the tech stack
- `## Files` (literal H2) lists every file to touch — REQUIRED on implementation packs (v-build scope guard)
- Completely self-contained — no references to other packs or the audit JSON (inline into `## Context`)
- Non-trivial content (>=50 lines)
- **Extract fields directly from the audit JSON** — do not summarize or paraphrase:
  - `[ID]` and `[Title]` → from `finding.id` and `finding.title`
  - `[Xh est.]` → from `finding.effort_hours`
  - `[description]` → from `finding.description` (full text)
  - `[paths]` → from `finding.files_affected[].path` (or `finding.evidence[].path` if the skill's finding schema nests file paths under `evidence`) with line numbers
  - `[specific changes]` → from `finding.implementation`
  - `[verification steps]` → from `finding.implementation.verification[]`
- End with the project's full verification suite

**In-app actionability filter (MANDATORY — self-contained, applies even when this text is pasted into a brief):** a pack may only instruct work completable by editing files in this repository with its existing stack and dependencies. If a finding's fix requires provisioning or configuring anything outside the repo — hosting/HA/load-balancing/failover, disaster recovery, offsite backups, external monitoring/alerting/uptime/APM/error-tracking services, status pages, on-call/runbook/incident-response process, CI/CD platform or deployment-pipeline infrastructure, DNS/CDN/email infrastructure, or any new third-party vendor, hosted service, or paid tool — DROP that finding: write NO pack for it, and list the dropped finding IDs under a `Dropped (off-stack)` line in `00-README.md`. Do not rephrase such an item into an in-repo documentation task (a runbook `.md` committed to the repo is still off-stack work).

## Step 3.5: JSON Validation (Before Write)

```bash
echo "$JSON_CONTENT" | jq . > /dev/null 2>&1 && echo "JSON valid" || echo "JSON INVALID"
```
If validation fails, attempt to fix common issues (trailing commas, unescaped quotes). If still invalid after one repair attempt, write best-effort JSON with `"json_validation": "failed"` flag in `audit_metadata`.

## Step 4: Post-Generation Validation

After the subagent completes, run the **wave-form validator**: `references/v-runnable-pack-convention.md` § Self-validate (or the runnable `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROMPT_DIR"`) followed by `run-v-packs "$PROMPT_DIR" --dry-run`. `PROMPT_DIR` MUST be of the form `.v-prompt-packs/<full-skill-name>-<MM-DD>` (e.g., `.v-prompt-packs/v-audit-messaging-$(date +%m-%d)`) — see `references/v-core-prompt-pack.md` § Per-skill MUST-USE values for the exact value. On failure, re-dispatch the subagent once with the validator output as context. On second failure, report in the audit artifact. Both validators also enforce the runner's per-pack byte cap as of 2026-09-11 (>25,000 B = `PACK_MAX_BYTES` fails): an oversized pack is excluded from `is_pack()`, so `--dry-run` exits 0 while that pack would never run.

**Pack tracking-status report (informational — NEVER a gate):** after validation, report
which git state the pack landed in:

```bash
if git -C "$PROJECT_ROOT" check-ignore -q "$PROMPT_DIR"; then echo "pack: gitignored"
elif git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PROMPT_DIR" >/dev/null 2>&1; then echo "pack: tracked"
else echo "pack: UNTRACKED+UNIGNORED — will pollute git status and can be swept into an unrelated commit; suggest adding the § Step 3 .gitignore rule"; fi
```

`tracked` and `gitignored` are both fine per § Step 3's gitignore guidance (the project
chooses). Only the third state is worth the operator's attention. Never fail or block the
audit on this — report and move on.

## Error Handling for Parallel Subagents

Per `references/v-core-error-handling.md`:

| Scenario | Action |
|----------|--------|
| **Subagent crash/timeout** (dispatch ceiling `V_DISPATCH_TIMEOUT_SEC`, default 900s per `v-dispatch-subagent.sh`) | Log `"dimension_N": {"status": "failed", "error": "..."}`. Score as `null`. Do NOT fabricate findings. |
| **Partial results** | Accept what was returned, mark `"status": "partial"`. Include partial findings. |
| **Score calculation with failures** | **Drop** failed dimensions from the denominator. Report: `"score_basis": "N of M dimensions completed"`. |
| **Minimum viable threshold** | If >50% of dimensions fail, abort → `"AUDIT_INCOMPLETE"`. Calculate as `ceil(total/2) + 1` failures. |

Skills MUST NOT silently omit failed dimensions or hang waiting for crashed subagents.

## Post-Adjudication Re-Score Gate (Mandatory — All Audit Skills)

Every audit skill computes its score, then mutates findings AFTER that computation has run:
root-cause dedup, critic adjudication (ACCEPT/MODIFY fixes), status reclassification. Nothing
used to force a recompute, so the published score could silently remain the pre-adjudication
number (observed 2026-08-16: a score that should have moved substantially after critic-merged
root causes shipped unchanged until caught).

**The gate:** after the LAST step that can add, remove, merge, or edit findings (adjudication
loop complete, dedup applied, status reclassifications logged), re-derive the score against
the FINAL findings state:

- A skill with a mandated mechanical scoring snippet (e.g. v-audit-seo's Step 2 jq) MUST
  re-run that exact snippet — never a variant, never hand-rolled or model arithmetic.
- A skill whose scoring is rubric-derived (v-audit-messaging, v-audit-sales-pricing) MUST
  re-derive the overall and per-dimension scores per its own Step 2 scoring rules.

If the re-run reproduces the drafted number: set `"score_recomputed": true` in the audit
JSON metadata and proceed. If it differs: the re-run's number IS the score — replace every
occurrence in the JSON and MD report (executive summary included) and append an entry to
`score_history[]` (value, timestamp, trigger). Publishing a score the final re-run does not
reproduce is a contract violation of the same class as hand-editing a gate verdict.

Each skill's workflow invokes this gate at its adjudication exit point (the "proceed to
Step 3" transition).
