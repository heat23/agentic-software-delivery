# Migration Lifecycle Reference (GAP-MIG)

_Last reviewed: 2026-08-03 (deferred-findings closure: added an explicit local seeded-copy fallback — with a concrete 10x-row-count/500K-minimum threshold and a mandatory rollback-rehearsal note — for the `up → down → up` rehearsal and volume test when no staging/production-like tier exists, so the check is no longer silently un-executable on a typical solo Forge/Vapor setup)_

**Scope:** Full database migration design, execution, testing, and rollback patterns. Code snippets use Laravel migration + `DB` idiom (the operator's stack); raw SQL is shown where the concept is engine-agnostic.

**Gap:** v-check audits migration safety at deploy time (section 1.8), but no skill owns the complete migration lifecycle from planning through validation.

---

## 1. Migration Design Principles

### One Concern Per Migration
- **Single responsibility:** Each migration should perform exactly one logical change — add a table, add a column, add an index, or backfill data.
- **Why:** Smaller migrations are easier to test, debug, and roll back. A failure in migration 5 doesn't affect the valid state of migrations 1–4.
- **Example:** Don't combine "add column + backfill + add NOT NULL constraint" in one migration. Do it in three migrations (or one per deploy step).

### Separate Schema from Data Migrations
- **Schema migrations:** Change the table structure (add/drop/alter columns, indexes, constraints).
- **Data migrations:** Populate or transform existing data (backfill, compute, bulk update).
- **Why:** Schema changes affect all queries immediately; data migrations can run slowly without blocking the app. Separate concerns prevent accidentally locking tables during backfill.
- **Example:** "Add column status" (schema) in deploy N. "Backfill status = 'active' for existing rows" (data) in deploy N or N+1, depending on table size.

### Additive-First Approach
- **Add before remove:** Always add new columns/tables/indexes before removing old ones.
- **Why:** Reduces deployment risk — if the new code fails, the old code is still available.
- **Timeline:** Add (deploy N) → code uses new, old still exists (deploy N+1) → remove old code reference (deploy N+2) → drop column (deploy N+3).
- **Benefit:** Any code deployed during this window can handle both states.

---

## 2. Zero-Downtime Migration Patterns

### Add Column with Default + Backfill + Constraint

**Pattern for adding a NOT NULL column to a large, live table:**

1. **Migration 1:** Add column with default value (nullable, fast):
   ```sql
   ALTER TABLE orders ADD COLUMN status VARCHAR(50) DEFAULT 'pending';
   ```
   - App doesn't know about the column yet.
   - New rows get the default automatically.

2. **Code Deploy 1:** Update app to use the new column (read it, but don't require it yet).
   - Old inserts still work.
   - New inserts set status to a value.

3. **Migration 2:** Backfill existing rows asynchronously (if table is large, batch process):
   ```sql
   UPDATE orders SET status = 'completed' WHERE status IS NULL AND created_at < '2026-01-01';
   -- Repeat in batches: UPDATE ... LIMIT 10000; (commit, wait, repeat)
   ```
   - For very large tables, run batches manually or via a job.
   - Monitor table lock time; backfill during low-traffic windows if needed.

4. **Code Deploy 2:** Now require status in all new inserts (app enforces via validation).

5. **Migration 3:** Add the constraint:
   ```sql
   ALTER TABLE orders MODIFY COLUMN status VARCHAR(50) NOT NULL;
   ```
   - All existing rows are backfilled, so this succeeds instantly.

**Why this works:** Schema change (add column) doesn't lock the table for long. Data fill happens independently. Constraint is added only after data is guaranteed present.

### Expand-Contract Pattern (for renaming or changing a column)

**Scenario:** Rename column `customer_id` to `user_id`.

1. **Migration 1:** Add new column `user_id`:
   ```sql
   ALTER TABLE orders ADD COLUMN user_id BIGINT;
   ```

2. **Code Deploy 1:** Write to both columns:
   ```php
   $order->customer_id = $customer->id;
   $order->user_id = $customer->id; // same value
   $order->save();
   ```

3. **Migration 2:** Backfill `user_id` from `customer_id`:
   ```sql
   UPDATE orders SET user_id = customer_id WHERE user_id IS NULL;
   ```

4. **Code Deploy 2:** Read from `user_id`, still write to both:
   ```php
   $userId = $order->user_id; // prefer new column
   // but still write to both for backward compat
   ```

5. **Migration 3:** Drop the old column:
   ```sql
   ALTER TABLE orders DROP COLUMN customer_id;
   ```

6. **Code Deploy 3:** Remove code that writes to old column.

**Why:** At any point during deploys, both old and new code can handle the column state.

---

## 3. Data Migration Patterns

### Separate Data Migrations from Schema Migrations

- **File placement:** Use a separate directory or naming convention (e.g., `database/data_migrations/` or `migrate_202601_backfill_status.php`).
- **Why:** Schema migrations are instant; data migrations may be long-running. A deployment system might need to apply schema migrations before code, and data migrations after (or in a background job).

### Batch Processing for Large Tables

**Problem:** `UPDATE big_table SET ...` on millions of rows locks the table and causes downtime.

**Solution: Batch in smaller chunks** (Laravel — run from an artisan command or queued job, not the migration file itself):
```php
use Illuminate\Support\Facades\DB;

do {
    $updated = DB::table('orders')
        ->where('processed', false)
        ->limit(10_000)
        ->update(['processed' => true]);
    usleep(100_000); // 0.1s — let other queries run between batches
} while ($updated > 0);
```

**Why:** Small locks don't block traffic. Sleep between batches lets the database serve other queries.

### Progress Tracking

- **Add a progress table** for long-running migrations:
  ```sql
  CREATE TABLE migration_progress (
    migration_id VARCHAR(255) PRIMARY KEY,
    last_processed_id BIGINT,
    total_rows BIGINT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
  );
  ```
- **Log progress:**
  ```php
  DB::table('migration_progress')->updateOrInsert(
      ['migration_id' => $migrationId],
      ['last_processed_id' => $lastId, 'total_rows' => $total],
  );
  ```
- **Resume interrupted migrations** by checking `last_processed_id`.
- **Monitor:** Query progress table to show operator what % is done.

---

## 4. Rollback Strategy

### Every Migration Should Have a `down()` Method

- **Reversible migrations:** Include a `down()` method that undoes the `up()` change.
  ```php
  public function up(): void
  {
      Schema::table('orders', fn (Blueprint $t) => $t->string('status', 50)->nullable());
  }

  public function down(): void
  {
      Schema::table('orders', fn (Blueprint $t) => $t->dropColumn('status'));
  }
  ```
- **Irreversible migrations:** Mark explicitly:
  ```php
  public function down(): void
  {
      throw new RuntimeException('Migration drop_payment_token is irreversible: deletes sensitive data');
  }
  ```
- **Why:** Reversible migrations let you roll back without manual data recovery. Explicit irreversible warnings prevent accidental data loss.

### Test the `down()` in Staging

- **Before launch:** Run the full migration sequence in staging:
  1. Start with schema version N−1.
  2. Run migrations up to N.
  3. Run `migrate down` to revert to N−1.
  4. Run `migrate up` again to N.
  5. Verify data integrity.
- **Why:** Catches bugs in rollback logic before production. A broken `down()` method is discovered in staging, not during an incident.

### No Staging Tier? Local Seeded-Copy Fallback (Do Not Silently Skip)

A production-like staging environment is not a given — a typical solo Forge/Vapor setup often has only
local + production. "Run it in staging" is not executable advice on that setup, and the rehearsal is
too important to quietly drop because the tier named in the checklist doesn't exist.

- **If no staging/production-like environment exists:** seed a **local** copy of the migration's
  target table(s) to **at least 10x the current production row count for that table (minimum 500K
  rows if the table is new or currently small)**, then run the full `up → down → up` sequence
  (Section 5) against that seeded local copy instead of staging. Same validation steps, same pass
  criteria — only the environment changes.
- **This raises the migration's risk tier, it doesn't lower the bar.** Any migration rehearsed this
  way (rather than against real staging/production-like data) must carry an explicit
  **rollback-rehearsal note** in the PR/deploy description: what was seeded, the row-count multiple
  used, and the `up → down → up` result — so a reviewer (human or the gate) can see the check ran
  against a stand-in, not silently assume staging coverage that isn't there.
- **Never skip the rehearsal because staging is absent.** "No staging" changes *where* you rehearse,
  never *whether* you do.

### Irreversible Migrations Need Explicit Marking

- **Pattern:** Migrations that delete data should be clearly marked:
  ```php
  // Migration: 2026_01_15_drop_legacy_payment_token.php
  public function up(): void
  {
      // IRREVERSIBLE: This migration deletes all legacy payment tokens.
      // Backup the database before running this in production.
      Schema::dropIfExists('legacy_payment_tokens');
  }

  public function down(): void
  {
      throw new RuntimeException('This migration is irreversible. Restore from backup if needed.');
  }
  ```
- **Process:** Review and backup before running such migrations.

---

## 5. Testing Migrations

### Run up + down + up on Staging

**No staging tier available?** Use the local seeded-copy fallback in Section 4 (`§ No Staging Tier?
Local Seeded-Copy Fallback`) — same checklist below, run against a local copy seeded to the stated
row-count multiple instead, with a rollback-rehearsal note recording that substitution.

**Validation checklist:**
1. Run `migrate up` from version N−1 to N.
   - Verify no errors.
   - Verify the change is present (`SHOW COLUMNS FROM orders;` if adding a column).
2. Run `migrate down` from version N to N−1.
   - Verify the change is reverted.
   - Verify the table state matches the prior version (same row counts, same schema).
3. Run `migrate up` again to N.
   - Verify the change is re-applied.
   - Verify idempotency: running the same migration twice doesn't fail.

### Test Against Production-Like Data Volumes

- **Small tables (< 100K rows):** Test locally.
- **Medium tables (100K–1M rows):** Use a backup or sanitized copy of production data in staging.
- **Large tables (> 1M rows):**
  - Test on a separate instance with production schema and partial data (e.g., last 30 days of records).
  - Measure lock times and lock impact with production volume.
  - Run backfill migrations in batches and measure time-to-completion.

**Why:** A migration that runs in 1 second on 10K rows may lock the table for 5 minutes on 50M rows, causing downtime.

### Verify Index Usage with EXPLAIN

- **After adding an index:**
  ```sql
  EXPLAIN SELECT * FROM orders WHERE user_id = 42 AND created_at > '2026-01-01';
  ```
  - Verify the query plan uses the new index (look for `index_name` in the output).
  - If the index isn't used, adjust the migration (column order, selectivity) or the query.

- **After changing a column (e.g., type, collation):**
  ```sql
  EXPLAIN SELECT * FROM orders WHERE id = 42;
  ```
  - Verify index scans still work and selectivity hasn't degraded.

---

## 6. Migration Review Checklist

Before shipping a migration, verify:

1. **One concern:** Does this migration do one logical thing? (Add column, add index, backfill, etc.)
2. **Zero-downtime pattern:** If adding a NOT NULL column, is it using add-default-backfill-constraint pattern? If renaming, is it expand-contract?
3. **Separate schema/data:** Are data operations separated from schema changes (in time or in a separate file)?
4. **Idempotent:** Would running the migration twice cause an error or data corruption?
   - Check for guards: `if (!Schema::hasColumn(...))` or `if NOT EXISTS`.
5. **Has down() method:** Does the migration include a `down()` that reverses it, or is it marked irreversible?
6. **Tested in staging (or the local seeded-copy fallback):** Was `migrate up → down → up` tested with
   production-like data volume? If no staging tier exists, was it tested against a local copy seeded to
   at least 10x current production row count (minimum 500K rows for a new/small table), with a
   rollback-rehearsal note recording that substitution (`§ No Staging Tier? Local Seeded-Copy Fallback`)?
7. **No model calls:** Does the migration use `DB::table()` instead of `Model::where()`? (Models may change after migration is written.)

**Example pre-ship checklist note (staging available):**
```
- [x] Single concern (add status column)
- [x] Zero-downtime pattern (add → backfill → constraint in 3 separate migrations)
- [x] Idempotent (uses Schema::hasColumn guard)
- [x] Has reversible down()
- [x] Tested on staging with 5M row dataset
- [x] Uses DB::table, not models
```

**Example pre-ship checklist note (no staging tier — local seeded-copy fallback used):**
```
- [x] Single concern (add status column)
- [x] Zero-downtime pattern (add → backfill → constraint in 3 separate migrations)
- [x] Idempotent (uses Schema::hasColumn guard)
- [x] Has reversible down()
- [x] Rollback-rehearsal note: no staging tier — seeded local copy to 3.2M rows
      (10x current prod count of ~320K for `orders`); up → down → up all passed
- [x] Uses DB::table, not models
```

---

## Glossary

- **Idempotent migration:** Running it twice produces the same result as running it once.
- **Zero-downtime migration:** The database is writable during the migration; no table locks prevent app traffic.
- **Expand-contract:** Add new column → write to both → migrate data → read from new → remove old code → drop old column.
- **Backfill:** Populate an empty column with computed or historical values.
- **Migration lock:** Exclusive lock on a table during schema changes; blocks all queries.
