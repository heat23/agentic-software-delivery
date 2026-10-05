---
name: v-next
description: "Use when asking what to work on next across your projects — portfolio-wide cadence: stale audits, unresolved findings, launch stage, stranded worktrees, CI health."
allowed-tools: Read, Write, Bash, Glob, Grep
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-next | version: 1.2.1 | last-updated: 2026-08-12 -->
<!-- 1.1.0 (2026-07-06): pending pack-inbox signal (§ 5b) wired into Step 2 gather list, Step 3
     examples, Step 4 report template, and priority-scoring.md (was doc-only in signal-sources.md). -->
<!-- 1.2.0 (2026-08-02): two new signals wired end-to-end (Step 2 gather list, Step 3 examples,
     Step 4 report template, priority-scoring.md) — security_audit (§ 6, composer/npm audit
     lockfile-cadence staleness) and legal_docs (§ 7, v-legal-docs-generate output staleness +
     jurisdiction-change escalation). Previously v-next could not see either drift class. -->

# 2026 Canonical Contract

Tier: User-facing entry point. Portfolio-wide cadence brain. Read-only / report-only — never edits source, never auto-dispatches other skills.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, and `_v-review.md`.

Recommended items must still pass the zero-outreach motion gate (`~/.claude/skills/references/v-core-solo-motion.md`) — a plan item written before a gate fix (or by a pre-gate audit) is NOT exempt; re-check it before re-surfacing it as a next action.

For the per-project ground-truth signal sources and staleness thresholds, read `references/signal-sources.md`.
For the priority-scoring model, read `references/priority-scoring.md`.

```yaml
contract:
  tier: user-facing
  accepts: [optional --projects=path1,path2 (explicit project roots), optional --root=<dir> (auto-discovery root, default ~/dev), no-arg (auto-discover)]
  produces: [V_NEXT_REPORT_${CLAUDE_SESSION_ID}.md]
  invokes: []
  invoked-by: [user, /v]
  estimated_tokens: 20k-60k
  estimated_duration: 5-15 min
  side-effects: report-only (reads across multiple project directories; writes ONLY the report artifact; never edits source, never runs another skill)
```

# /v-next — Portfolio Cadence Brain

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules, `_v-review.md` for finding format.

One command that looks across ALL of the operator's projects — not just the one you're sitting
in — and answers "what's most overdue right now?" It reads ground truth (file mtimes, git
state, existing report contents) from each project, ranks the findings into ONE list, and
recommends which skill to run next. **It never runs anything itself** — it is the planning
layer above `/v`, not a replacement for it.

## Why This Exists

Solo operators running many projects lose track of cadence: an SEO audit from 3 months ago that
was never re-run, 12 unresolved P1 findings sitting in a report nobody re-opened, a worktree
from a fix session that never merged back, a CI run that's been red for a week. Each individual
project's tooling (`/v-audit-*`, `/v-merge-all`, `/v-ci-fix`) handles its own domain well, but
nothing looks ACROSS projects and says "here is the single most valuable thing to do right now."
That's this skill's entire job.

## Skill Boundaries

**SME persona:** This skill is run by a **portfolio-operations lead** whose specialty is
noticing what's overdue across a fleet of projects before it becomes a fire — stale audits,
abandoned worktrees, unresolved findings sitting untouched — and ranking them by actual cost of
delay, not recency of complaint.

### Best fit

- Weekly/periodic "what should I work on" check-ins across multiple projects
- Detecting silent drift: an audit that was run once and never re-run, a fix pack that was
  generated but never executed, a worktree that's been sitting unmerged for weeks
- Triaging where to point `/v` next when there's no specific task in mind

### Use instead

- `/v-audit-orchestrator` — for running or choosing a specific audit ON one project you're
  already in. v-next tells you WHICH project/audit is overdue; it does not run the audit itself.
- `/v-merge-all` — for actually consolidating stranded worktrees/branches once v-next flags them.
- `/v-ci-fix` — for actually fixing a red CI pipeline once v-next flags it.
- `/v-self-audit` — for auditing the `/v` orchestrator SYSTEM itself, not the operator's product
  projects. Different subject entirely.

### Not for

- Auditing a single project in depth — that's the specialist audit skills' job. v-next only
  reads their OUTPUT artifacts and mtimes; it never re-derives audit findings itself.
- Fixing anything. This skill recommends; it never dispatches or implements.
- Projects with no prior `/v` activity (no `.v/artifacts/`, no audit reports) — for those,
  v-next reports `no_signal: true` and recommends running `/v-setup-project` or a first audit,
  rather than fabricating a priority score from nothing.

## Entry Point

### Step 1 — Resolve the project set

1. **Explicit `--projects=path1,path2,...`** in the invocation → use exactly those paths (each
   must be a git repo; skip and warn on any that aren't).
2. **Explicit `--root=<dir>`** → auto-discover: every immediate subdirectory of `<dir>` that is a
   git repo (has `.git`).
3. **No-arg default** → auto-discover under `~/dev` if it exists, else ask the operator once in a
   plain-text turn (this skill has no `AskUserQuestion` tool and runs `context: fork` — never emit a
   structured question) for a root directory, else (headless) STILL write
   `V_NEXT_REPORT_${CLAUDE_SESSION_ID}.md` — same `# V_NEXT_REPORT` heading and `session:` line
   as a normal run — with top-level `blocked: true`, `reason: no root directory provided and none
   discoverable`, and an empty ranked-actions section. Never report the blocked outcome as bare
   stdout: the Stop hook's report-only escape recognizes ONLY that filename+heading for this
   skill, so a run that writes nothing (or a differently-named file) false-blocks at session end.
   This is the one genuinely missing-input case, not a fabricable default.

Cap at 20 projects per run (report the rest as `truncated: true` with a count) — this is a
cadence check, not an unbounded fleet scan.

### Step 2 — Per-project ground-truth read (read-only, no mutation)

For each project root, gather (see `references/signal-sources.md` for the exact commands and
staleness thresholds per signal):

1. **Last-audit timestamps** — mtime of the newest `AUDIT_REPORT_*`, `SEO_AUDIT_*`,
   `*_AUDIT_*.json`, `BUG_HUNT_REPORT_*` etc. per audit family, searched under `.v/artifacts/`
   first, then repo root as fallback. Compute days-since-last-run per family.
2. **Unresolved findings** — grep the most recent consolidated report (from
   `/v-audit-consolidate`, if one exists) for P0/P1/P2 counts still open (no matching
   `RESOLVED`/fix-commit marker).
3. **Launch stage** — read the project's `CLAUDE.md` for stage hints, or apply the same
   greenfield/growth/mature heuristics the audit skills already use (published-article count,
   GSC data presence, revenue-mention grep) — reuse, don't re-derive a new heuristic.
4. **Stranded worktrees/branches** — `git worktree list --porcelain` for worktrees older than 7
   days with uncommitted or unmerged work; `git branch --no-merged <main>` for branches with no
   corresponding open PR (if `gh` is available) or no recent activity.
5. **CI state** — if `gh` CLI is available AND the repo has a GitHub remote: `gh run list
   --limit 5` for the default branch; flag if the most recent run failed. If `gh` is unavailable
   or there's no remote, mark `ci_data_source: unavailable` — do NOT fabricate a CI status.
6. **Wizard-plan & operational freshness** (§ 1b) — mtime of the newest `TRAFFIC_PLAN_*` (>30d →
   `/v-traffic` refresh), `CONTENT_CALENDAR_*` (>30d → `/v-content-ops`), `PROD_TRIAGE_*` (>21d →
   `/v-prod-triage`). Two are CONTENT-gated, not age-gated: grep the latest `LAUNCH_PLAN_*`'s
   `## Verdict` — a `NO-GO`/open-MUST-FIX is a TOP item regardless of age (→ `/v-launch`); and the
   latest `PROD_TRIAGE_*`'s `### P0` section — an open P0 (growing failed-jobs backlog, stopped
   scheduler) is URGENT and outranks a stale audit. An ABSENT plan is not a signal — only surface
   plans that exist and are due/overdue or carry an open verdict.
7. **Pending pack-inbox work** (§ 5b) — count real pack files sitting directly in
   `.v/packs/inbox/` (excluding the runner-owned `.done/`, `.needs-review/`, `.runlogs/`).
   `PENDING>0` means generated work is queued but not yet executed — recommend `run-v-packs
   <inbox> --once` (or `v-inbox run <project_root>`); packs in `.needs-review/` are parked and
   need the operator, not a re-run.
8. **Dependency / security-audit staleness** (§ 6) — lockfile last-commit date vs. the
   fresh/due/overdue thresholds. `overdue` recommends `composer audit` / `npm audit
   --audit-level=critical` directly in the product repo (never `/v-maintenance` — its fence is
   `~/.claude` meta-tooling only, per its § Not for).
9. **Legal-doc staleness** (§ 7) — `last_updated` frontmatter on the newest legal doc set vs.
   the fresh/due/overdue thresholds, OR an escalation trigger (jurisdiction-set changed since
   generation) regardless of age. Either case recommends `/v-legal-docs-generate` re-run. An
   absent legal-docs directory is not a signal here — that's `/v-launch`'s Legal risk gate.

Each signal that can't be gathered gets an explicit `data_source: unavailable` tag, never a
guessed value — a `no_signal` project is more useful than a fabricated one.

### Step 3 — Rank into ONE list

Apply the scoring model in `references/priority-scoring.md` (staleness × severity ×
project-stage weighting) to produce a single cross-project ranked list. Each entry names: the
project, the specific overdue item, why it matters (one sentence), and the **recommended next
skill** (e.g. "audit X is 60 days stale — due for `/v-audit-seo`", "12 unresolved P1s — run the
existing fix pack via `/v-build`", "3 stranded worktrees — run `/v-merge-all`", "CI red for 5
days — run `/v-ci-fix`", "traffic plan 3 weeks stale — refresh with `/v-traffic`", "2 launch blockers still open — `/v-launch`", "prod has a growing failed-jobs backlog — `/v-prod-triage`", "4 packs queued 6 days in `.v/packs/inbox` — `run-v-packs <inbox> --once` or `v-inbox run`", "dependency audit 45 days stale, one known-open CRITICAL advisory — run `npm audit --audit-level=critical` now", "legal docs 200 days stale and JURISDICTION_STATE changed — re-run `/v-legal-docs-generate`"). **Never auto-dispatch the recommended skill** — this skill's entire
value is the ranked read, not the execution.

### Step 4 — Write `.v/artifacts/V_NEXT_REPORT_${CLAUDE_SESSION_ID}.md`

(Phase-2: write under `.v/artifacts/` — create the dir via `~/.claude/skills/v/references/v-artifact-dir.sh`; the Stop-hook `_PB_*` gate dual-searches, root is a legacy fallback.)

```markdown
# V_NEXT_REPORT
generated: <ISO timestamp>
session: ${CLAUDE_SESSION_ID}
projects_scanned: N
projects_truncated: <true|false>

## EXECUTIVE_SUMMARY
2-3 sentences: the single most urgent item across the whole portfolio, and the overall health
picture (how many projects have stale audits, how many have unresolved P0/P1s).

## RANKED_NEXT_ACTIONS

### 1. [project-name] — <one-line action>
reason: <why this ranks here — staleness days / finding count / CI state>
recommended_skill: `/v-audit-seo` | `/v-merge-all` | `/v-ci-fix` | `/v-build <pack>` | `/v-traffic` | `/v-launch` | `/v-prod-triage` | `/v-content-ops` | etc.
data_source: <measured | data_source: unavailable for any missing signal used>

### 2. ...

## PER_PROJECT_DETAIL

### [project-name]
- Last audits: <family: days-since-run, ...>
- Unresolved findings: P0:N P1:N P2:N (source: <report path> or none found)
- Launch stage: <greenfield | growth | mature | unknown>
- Worktrees/branches: <N stranded, oldest N days>
- CI: <passing | failing since <date> | data_source: unavailable>
- Pack inbox: <N pending / N parked in .needs-review | empty | no inbox>
- Dependency/security audit: <fresh Nd | due Nd | overdue Nd | not_applicable — no lockfile>
- Legal docs: <fresh Nd | due Nd | overdue Nd | escalation: jurisdiction changed | no docs (not a signal)>

## NO_SIGNAL_PROJECTS
<projects with no prior /v activity — recommend /v-setup-project or a first audit, not a score>

## NEXT_STEPS
Recommended: pick the #1 ranked action and run its named skill directly. Re-run /v-next
weekly or after a batch of project work to re-rank.
```

## Anti-reward-hacking clause

A project with genuinely no overdue items is a **valid outcome** — report it as `status: current`
in its per-project detail, not a fabricated finding. Do not invent staleness to fill the list.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Every project shows the same generic "run an audit" recommendation | Signal gathering skipped; fell back to a template | § Step 2 must actually read each project's artifacts/git state — a project with real signal data never produces a generic recommendation |
| 2 | CI status reported as "passing" for a project with no GitHub remote | `data_source: unavailable` case treated as a guessed pass | Never guess a CI/data status — unavailable data is tagged `data_source: unavailable`, never silently defaulted to a positive outcome |
| 3 | v-next recommends running a skill, and the operator expects it to just run it | Skill boundary not communicated | This skill is advisory-only by design (see contract `side-effects:`); state this explicitly in the executive summary when a session's context suggests the operator expected auto-execution |
| 4 | A project with a recent audit still shows as "stale" | Staleness threshold applied to the wrong audit family, or the newest report file wasn't actually the newest by mtime | Use `find -exec ls -t` (mtime-sorted), never filename-lexicographic sort, per `references/signal-sources.md` |
| 5 | Portfolio scan takes an unbounded amount of time on a large `~/dev` | No cap applied | Cap at 20 projects per run; report the remainder as `truncated: true` |

## Idempotency

**Idempotent and side-effect-free.** Re-running produces a fresh ranked list reflecting current
project state; the only write is the report artifact itself (SID-scoped, never collides with a
concurrent session). Safe to run as often as desired.
