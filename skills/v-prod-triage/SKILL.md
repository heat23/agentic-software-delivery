---
name: v-prod-triage
description: "Use when triaging production health — error clustering, failed-jobs backlog, scheduled-task health, smoke checks, or a backup-restore drill."
allowed-tools: Read, Write, Bash, Glob, Grep, AskUserQuestion
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-prod-triage | version: 1.0.0 | last-updated: 2026-07-05 -->

# 2026 Canonical Contract

Tier: User-facing entry point. Production runtime health triage. Read-only against the running
application and its logs/queues/scheduler — never mutates production data. The one exception
(the backup-restore drill) operates EXCLUSIVELY against a throwaway scratch database it creates
and drops itself; it never connects to or touches the production database connection.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, and `_v-review.md`.

For the per-mode probe commands (Laravel-first, with non-Laravel adaptation notes), read
`references/triage-modes.md`.
For the backup-restore drill's safety protocol, read `references/restore-drill-safety.md`
BEFORE running that mode — it is the mandatory guard sequence, not optional background reading.

```yaml
contract:
  tier: user-facing
  accepts: [mode (errors|queue|scheduler|smoke|restore-drill|all, default all-except-restore-drill), optional --confirm-restore-drill (required to run that mode)]
  produces: [PROD_TRIAGE_${CLAUDE_SESSION_ID}.md]
  invokes: []
  invoked-by: [user, /v]
  estimated_tokens: 20k-60k
  estimated_duration: 5-20 min (add 5-15 min if --confirm-restore-drill is set)
  side-effects: read-only against production (logs, queue tables, scheduler state, HTTP health-check requests); the restore-drill mode creates AND drops its own scratch database only — NEVER connects to the production DB connection
```

# /v-prod-triage — Production Runtime Health Triage

**Conventions:** Follow `_v-core.md` for artifacts and paths, `_v-exec.md` for execution rules,
`_v-review.md` for finding format.

One command that answers "is production actually healthy right now?" — not "did the tests
pass" (`/v-pre-flight`'s job) or "is the code good" (`/v-check`'s job), but the runtime signals
that only show up once real traffic and real time have passed: clustered errors, a growing
failed-jobs backlog, a scheduled task that silently stopped firing, and (opt-in) whether the
latest backup would actually restore cleanly if you needed it.

## Why This Exists

Code review and CI catch defects before deploy. They cannot catch a queue worker that died three
days ago, a scheduled digest job that's been silently failing since a config change, or a backup
file that's been corrupt for a month because nobody tried restoring it. Those failures are
invisible until the moment you need the thing that silently broke — usually mid-incident. This
skill runs the checks that catch them BEFORE that moment.

## Skill Boundaries

**SME persona:** This skill is run by a **senior SRE / production-reliability engineer** whose
specialty is the gap between "the code is correct" and "the system is healthy" — the runtime
signals (error clustering, queue backlog, scheduler drift, backup integrity) that only surface
under real production conditions, and that a skeptical on-call engineer checks BEFORE an
incident, not during one.

### Best fit

- Periodic production health check-ins (weekly, post-deploy, or pre-launch-week)
- Investigating "something feels off" without a specific reported bug
- Verifying disaster-recovery readiness (does the backup actually restore?) before you need it
- Post-deploy smoke-check as the last step of a deploy pipeline

### Use instead

- `/v-pre-flight` — for build/test/lint gates BEFORE a deploy. This skill checks the RUNNING
  system after code is already live.
- `/v-bug-hunt` — for adversarially probing a specific subsystem's behavior. This skill reads
  passive runtime signals (logs, queue tables, scheduler state); it does not exercise the app.
- `/v-check` — for static codebase health (security, perf, tech debt). This skill is runtime,
  not static.
- `/v-audit-code` — for whole-repo modernization/production-readiness of the CODE. This skill
  triages the currently-running DEPLOYMENT, not the codebase.

### Not for

- Fixing anything. This skill reports prioritized findings that feed into `/v` as fix tasks; it
  never edits application code or configuration itself.
- Load testing or capacity planning — use dedicated load-test tooling.
- Ever writing to, migrating, or restoring INTO the production database. The restore-drill mode
  is scratch-database-only by hard design (see `references/restore-drill-safety.md`) — if that
  guard cannot be satisfied, the mode refuses to run rather than degrading its safety guarantee.

## Entry Point

### Step 1 — Resolve mode(s)

- **Explicit mode** (`errors`, `queue`, `scheduler`, `smoke`, `restore-drill`, or `all`) in the
  invocation → run that mode (or all of them for `all`).
- **No-arg default** → run `errors` + `queue` + `scheduler` + `smoke` (the fully safe,
  always-read-only modes). **`restore-drill` is NEVER included in the default set** — it only
  runs when explicitly named AND `--confirm-restore-drill` is present in the invocation, or
  (interactive) the operator confirms via the single `AskUserQuestion` in
  `references/restore-drill-safety.md` § Confirmation gate.

### Step 2 — Stack detection

Read `composer.json` / `package.json` / project `CLAUDE.md` to detect the stack. The probes in
`references/triage-modes.md` are written for Laravel (queue/`failed_jobs`, `schedule:list`,
`storage/logs/laravel.log`) — the most common detected configuration for this operator. Adapt
per the stack-adaptation table in that reference for non-Laravel backends.

### Step 3 — Run the resolved modes

Each mode is independent and documented in full in `references/triage-modes.md`:

1. **`errors`** — cluster recent exceptions from the application log by exception class + top
   stack frame, rank by frequency over the last 24h/7d windows, cite representative log lines.
2. **`queue`** — count `failed_jobs`, age of the oldest unprocessed job, queue-worker liveness
   signal (Horizon status if present, else a heuristic on recent job throughput).
3. **`scheduler`** — list scheduled commands (`schedule:list` or equivalent) and their expected
   vs. actual last-run time; flag anything overdue past its own interval.
4. **`smoke`** — HTTP GET the configured health-check URL(s) (from `.env`/config — never
   hardcoded); assert 200 + expected body marker; record response time.
5. **`restore-drill`** (opt-in only) — per `references/restore-drill-safety.md`: locate the
   latest backup artifact, restore it into a NEW scratch database, run integrity checks (row
   counts vs. a baseline, foreign-key spot-checks), then drop the scratch database. Never
   touches the production connection at any point.

### Step 4 — Write `.v/artifacts/PROD_TRIAGE_${CLAUDE_SESSION_ID}.md`

(Phase-2: write under `.v/artifacts/` — create the dir via `~/.claude/skills/v/references/v-artifact-dir.sh`; the Stop-hook `_PB_*` gate dual-searches, root is a legacy fallback.)

```markdown
# PROD_TRIAGE
generated: <ISO timestamp>
session: ${CLAUDE_SESSION_ID}
modes_run: [errors, queue, scheduler, smoke, restore-drill?]
stack: [detected]

## EXECUTIVE_SUMMARY
2-3 sentences: the single most urgent runtime issue found (if any), and overall health verdict.

## FINDINGS

### P0_CRITICAL
<!-- e.g. failed_jobs backlog growing unbounded, scheduled billing job silently stopped, backup
     restore failed integrity check -->

#### PROD-QUEUE-01: [Issue Title]
mode: queue
severity: critical
evidence: |
  [failed_jobs count, oldest job age, representative failure reason]
repro: |
  [exact command to re-observe: php artisan queue:failed, etc.]
fix_sketch: |
  [HIGH-LEVEL — this is a triage report, not a fix]

### P1_IMPORTANT
### P2_POLISH
### P3_SUSPECTED

## VERIFIED_GOOD
Modes/checks that came back clean — a genuinely healthy system is a valid outcome.

## STOP_CONDITIONS_HIT
- restore_drill_skipped: <true|false + reason, e.g. "not confirmed" or "no backup artifact found">

## NEXT_STEPS
Findings here feed directly into `/v` as fix tasks — paste the P0/P1 findings into a fresh
session to route them through the normal TDD → pre-flight → verify-done gauntlet.
```

## Anti-reward-hacking clause

A mode that finds nothing wrong is a **valid outcome** — report it under `VERIFIED_GOOD` with a
one-line note on what was checked. Do not invent findings to make the triage look thorough.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Restore-drill ran without explicit confirmation | Mode-resolution default accidentally included it | `restore-drill` is NEVER in the no-arg default set — it requires an explicit mode name AND `--confirm-restore-drill` (or the interactive confirmation), every time, no exceptions |
| 2 | Restore-drill mode connected to the production database | Connection string resolution used the default/production connection instead of a scratch one | `references/restore-drill-safety.md` § the connection-name assertion MUST pass (scratch DB name is verified distinct from the production connection's configured name) BEFORE any restore command runs — refuse and report `restore_drill_skipped: safety_check_failed` rather than proceeding on ambiguity |
| 3 | Smoke-check hits the wrong environment (staging URL checked, reported as production) | Health-check URL not resolved from the actual production config | Read the URL from the project's OWN production config/env, never hardcode or guess a URL |
| 4 | Error clustering reports the same exception repeatedly as N separate findings | Clustering key too narrow (e.g. keyed on full stack trace including line-specific noise) | Cluster on exception class + top 1-2 meaningful frames, not the full trace — this is what makes 500 log lines collapse into a handful of real findings |
| 5 | Scheduler check flags a task as "overdue" when it's actually running on a longer cadence than assumed | Overdue threshold used a hardcoded assumption instead of the task's declared interval | Read the actual declared schedule/cron expression per task and compare against ITS OWN interval, never a blanket threshold |

## Idempotency

**Idempotent for the always-safe modes** (`errors`/`queue`/`scheduler`/`smoke`) — pure reads,
safe to run as often as desired, findings reflect current state on each run. **The
`restore-drill` mode is self-cleaning** — it creates its scratch database, runs its checks, and
drops the scratch database as its own last step regardless of outcome (including on failure
paths), so repeated runs never accumulate orphaned scratch databases. Confirm cleanup happened
by checking `restore_drill_scratch_db_dropped: true` in the report; if `false`, the operator
must manually drop the named scratch database (its name is logged explicitly, never hidden).
