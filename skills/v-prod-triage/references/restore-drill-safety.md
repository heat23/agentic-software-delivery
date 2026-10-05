# v-prod-triage — Backup-Restore Drill: Mandatory Safety Protocol

Loaded on-demand by v-prod-triage before running `restore-drill` mode. **This is not optional
background reading — every guard below MUST pass before any restore command runs.** If any
guard fails, the mode STOPS and reports `restore_drill_skipped: safety_check_failed` with the
specific failed guard named. There is no "proceed anyway" path for a failed guard.

## What this mode does and does not do

**Does:** locate the most recent backup artifact, restore it into a brand-new scratch database
this run creates, run integrity checks against that scratch copy, then drop the scratch
database.

**Never does:** connect to, read from, write to, or in any way touch the production database
connection. The production database is never opened by this mode — not for comparison, not for
a baseline, nothing. Any baseline row counts used for comparison come from the backup's own
manifest/metadata if available, or are skipped with `baseline_unavailable: true` rather than
querying production to get one.

## Confirmation gate (mandatory, runs FIRST — before any other guard)

`restore-drill` mode requires explicit confirmation, every time, no exceptions:

- **Headless / orchestrator (`V_DEPTH >= 1` or `HEADLESS_BATCH=1`):** the invocation MUST
  contain `--confirm-restore-drill` literally. Absent that flag, skip the mode entirely and
  report `restore_drill_skipped: not_confirmed` — do NOT ask, do NOT proceed anyway.
- **Interactive:** ask once via `AskUserQuestion`:

```yaml
question: "The restore-drill mode will restore your latest backup into a NEW scratch database (never touching production) to verify it actually restores cleanly, then drop the scratch database. Proceed?"
header: "Restore drill"
multiSelect: false
options:
  - label: "Yes, run the restore drill"
    description: "Creates a scratch DB, restores into it, checks integrity, drops it. Production DB is never touched."
  - label: "No, skip this mode"
    description: "Run the other triage modes only (errors, queue, scheduler, smoke)."
```

A "No" answer, or no answer given, skips the mode with `restore_drill_skipped: operator_declined`.

## Guard sequence (all MUST pass, in order, after confirmation)

### Guard 1 — Locate the backup artifact without guessing

```bash
# Adapt the glob to the project's actual backup location/tool (spatie/laravel-backup default
# shown; substitute the project's own convention if different).
BACKUP_FILE=$(find "$PROJECT_ROOT/storage/app/backup" -name "*.zip" -o -name "*.sql*" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
if [ -z "$BACKUP_FILE" ]; then
  echo "restore_drill_skipped: no_backup_artifact_found"
  exit 0
fi
```

No backup found → skip cleanly, never fabricate a drill result.

### Guard 2 — Derive the scratch database name and assert it is NOT the production name

```bash
# Read the PRODUCTION connection's configured database name (never connect to it — just read
# the config value) so the scratch name can be asserted distinct from it.
PROD_DB_NAME=$(grep -E '^DB_DATABASE=' "$PROJECT_ROOT/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
SCRATCH_DB_NAME="${PROD_DB_NAME}_scratch_verify_$(date +%s)"

if [ -z "$PROD_DB_NAME" ] || [ "$SCRATCH_DB_NAME" = "$PROD_DB_NAME" ]; then
  echo "restore_drill_skipped: safety_check_failed (scratch name derivation failed to produce a name distinct from production)"
  exit 1
fi
echo "Scratch database for this drill: $SCRATCH_DB_NAME"
```

**This assertion is the load-bearing guard.** The scratch name is ALWAYS the production name
plus a unique suffix — it can never collide with the production name by construction, and the
explicit equality check is a second, independent layer against a config-read failure silently
returning an empty or wrong value.

### Guard 3 — Create the scratch database using an ADMIN connection, never the app's default connection

```bash
# Use a separate, explicitly-scratch connection profile — never reuse Laravel's default DB
# connection config (which points at production). Adapt the CREATE DATABASE syntax to the
# project's actual DB engine (MySQL/Postgres/etc).
mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" -e "CREATE DATABASE \`${SCRATCH_DB_NAME}\`;"
```

If credentials for an admin/superuser connection aren't available in the project's config,
STOP and report `restore_drill_skipped: no_admin_credentials_available` — do not fall back to
the application's own production credentials for a CREATE DATABASE operation.

### Guard 4 — Restore the backup INTO the scratch database only

```bash
# The target database in this restore command is ALWAYS $SCRATCH_DB_NAME, never $PROD_DB_NAME.
mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" "$SCRATCH_DB_NAME" < "$RESTORED_SQL_FILE"
```

### Guard 5 — Run integrity checks against the scratch copy

- Row counts per table vs. the backup manifest's own recorded counts (if the backup tool records
  them) — flag any table whose restored count doesn't match.
- Foreign-key spot-check: for a sample of tables with FK constraints, verify no orphaned
  references exist post-restore.
- Report `baseline_unavailable: true` if no manifest counts exist to compare against — a
  successful restore with unverifiable counts is still reported, just with lower confidence.

### Guard 6 — Drop the scratch database (runs even on failure paths)

```bash
mysql -h "$DB_HOST" -u "$DB_ADMIN_USER" -p"$DB_ADMIN_PASS" -e "DROP DATABASE \`${SCRATCH_DB_NAME}\`;"
echo "restore_drill_scratch_db_dropped: true"
```

This cleanup step MUST run regardless of whether Guard 5's integrity checks passed or failed —
use a shell trap or explicit try/finally-equivalent so a failed integrity check doesn't leave
the scratch database orphaned. If the drop itself fails, report
`restore_drill_scratch_db_dropped: false` with the scratch database's name explicitly logged so
the operator can drop it manually — never hide an orphaned scratch database.

## Forbidden patterns (any of these is a P0 defect in this skill itself, not a normal finding)

- Ever constructing a DROP/DELETE/TRUNCATE statement that targets `$PROD_DB_NAME` for any reason.
- Reusing the application's default database connection (which is the production connection) to
  perform ANY step of this drill.
- Skipping the confirmation gate under any headless condition.
- Treating a missing backup artifact, missing admin credentials, or failed name-distinctness
  assertion as anything other than a clean skip.
