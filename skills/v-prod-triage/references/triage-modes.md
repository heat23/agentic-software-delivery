# v-prod-triage — Per-Mode Probe Commands

Loaded on-demand by v-prod-triage Step 3. Laravel-first (the operator's default stack per
CLAUDE.md); adapt per the stack table at the end for other backends.

## Mode: `errors` — recent error/exception clustering

```bash
# Laravel: tail the last N days of the application log. Log rotation means "recent" may span
# multiple dated files (laravel-YYYY-MM-DD.log) if daily rotation is configured.
LOG_FILES=$(find "$PROJECT_ROOT/storage/logs" -name "laravel*.log" -mtime -7 2>/dev/null)
grep -hoE '\[[0-9-]+ [0-9:]+\] \w+\.ERROR: [^ ]+' $LOG_FILES 2>/dev/null | \
  sed -E 's/^\[[0-9-]+ [0-9:]+\] \w+\.ERROR: //' | sort | uniq -c | sort -rn | head -20
```

Cluster on **exception class + top 1-2 meaningful stack frames** (the first application-code
frame, skipping vendor/framework frames) — NOT the full trace, which varies line-to-line for
the same underlying bug and would fragment one real issue into dozens of "distinct" findings.

For each cluster: count occurrences in the last 24h and last 7d separately (a spike in the last
24h against a quiet 7d baseline is itself a finding, even if the absolute count is low). Cite
one representative log line verbatim as evidence.

**Non-Laravel adaptation:** substitute the project's own log location/format (structured JSON
logs, syslog, an external aggregator's CLI if one is configured) — the clustering discipline
(class + meaningful frame, 24h vs 7d windows) applies regardless of log format.

## Mode: `queue` — queue depth + failed-jobs triage

```bash
# Laravel
php artisan queue:failed 2>/dev/null | tail -n +2 | wc -l   # failed job count
# Oldest unprocessed failed job (if the failed_jobs table has a failed_at column):
php artisan tinker --execute="echo \DB::table('failed_jobs')->min('failed_at');" 2>/dev/null
# Horizon (if installed) — worker/supervisor liveness:
php artisan horizon:status 2>/dev/null
```

**Findings target:** a growing (not just nonzero) failed-jobs count across repeated runs, an
oldest-failed-job age beyond a reasonable retry/investigation window (>24h with no operator
action is a P1; >7d is a P0), or a stopped/paused Horizon supervisor.

**Non-Laravel adaptation:** substitute the project's queue system's own failed-job inspection
command (Sidekiq's dead-set size, Celery's task-failure inspection, BullMQ's failed-queue count)
— the finding thresholds (growing backlog, stale oldest-failure age, stopped worker) apply
regardless of queue technology.

## Mode: `scheduler` — scheduled-task health

```bash
# Laravel
php artisan schedule:list 2>/dev/null
```

For each listed task, compare its declared interval/cron expression against evidence of its
actual last run (a log line it writes, a `last_run_at` marker it maintains, or — if neither
exists — flag `no_last_run_evidence: true` rather than guessing). A task is "overdue" when the
time since its last confirmed run exceeds ITS OWN declared interval by a meaningful margin (not
a blanket threshold across all tasks — a daily digest and an every-5-minutes health-ping have
very different overdue definitions).

**Non-Laravel adaptation:** substitute the project's scheduler (cron, Celery Beat, a hosted
scheduler's API/dashboard) — same per-task interval-vs-actual comparison.

## Mode: `smoke` — post-deploy smoke check

```bash
# Resolve the health-check URL from the project's OWN production config — never hardcode.
HEALTH_URL=$(grep -E '^HEALTH_CHECK_URL=|^APP_URL=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
curl -sS -o /dev/null -w "%{http_code} %{time_total}\n" "${HEALTH_URL:?no health-check URL resolved}/up" 2>/dev/null
```

Assert HTTP 200 (or the project's documented healthy status code) and log response time.
Laravel 11+ ships a `/up` health-check route by default — check for it first before assuming a
custom path. If no health-check route/URL can be resolved from config, report
`smoke_check_skipped: no_health_url_configured` rather than guessing a URL to hit.

**Findings target:** non-200 response, response time far outside the project's own historical
norm (if a prior smoke-check result exists to compare against), or connection failure.

## Mode: `restore-drill` — see `references/restore-drill-safety.md`

This mode has its own dedicated safety-protocol reference — read that file in full before
running this mode. It is never included in the default mode set.
