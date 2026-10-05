# v-ci-fix Failures Log

Running log of CI failures observed across v-ci-fix sessions. Each entry captures:
- date
- project (a short project label)
- failure class (per `failure-taxonomy.md`)
- signature (the unique fingerprint of this failure)
- root cause (what was actually wrong)
- fix
- time-to-fix

**Purpose:** when v-ci-fix encounters a new failure, it reads recent entries here. Patterns emerge across projects/months that wouldn't be visible from a single session.

**When to write:** SKILL.md Step 9 (success) and Step 10 (blocker/defer) — after every v-ci-fix session that resolved a failure OR escalated as INFRA. Append, never delete.

**When to read:** SKILL.md Step 5b (before classifying). Cross-reference the failure signature against this log before treating it as a novel class — a match jumps you straight to the documented fix.

**Class vocabulary:** entries use the 6 SUMMARY classes (`CODE-BUG / FLAKY / CONFIG / TEST-BUG / DEP-DRIFT / INFRA`). See the summary-class ↔ bucket mapping table in SKILL.md § Failure taxonomy reference (bucket count lives only in `failure-taxonomy.md` — cite, don't restate a count here). Record the bucket number in the `signature` / `notes` field so both vocabularies are captured.

**Format:** newest entries at the top; one block per failure.

---

## Template (use for new entries)

```yaml
- date: 2026-04-30T14:00:00Z
  project: project-a
  class: CODE-BUG | FLAKY | CONFIG | TEST-BUG | DEP-DRIFT | INFRA
  signature: |
    Missing return type on relationship method App\Models\Widget::auditLogs
    on file app/Models/Widget.php:42
  root_cause: |
    Migration added auditLogs relationship; model annotation not updated
  fix: |
    Added @property-read Collection<int, AuditLog> $auditLogs to Widget::class docblock
  time_to_fix_minutes: 8
  prevented_by_pre_flight: true  # local pre-flight would have caught this
  notes: |
    Pattern: model annotation drift after migration.
```

---

## Entries (newest first)

<!--
  This file starts empty. The first v-ci-fix session adds the first entry.
  Aim for entries to be detailed enough that a new Claude session reading
  this file can spot patterns and avoid re-doing the same diagnosis.
-->

_The published snapshot ships this log empty. The live copy holds entries from private projects,
whose test names and stack traces are project-specific, so they were removed for publication._

## Pattern observations (auto-update after every 5 new entries)

After 5 new entries appended, take a moment to scan the log:

- Most common class? (informs which v-pre-flight gates need strengthening)
- Most common project? (informs which CLAUDE.md gotchas need adding)
- Average time-to-fix per class? (FLAKY should be highest; CODE-BUG lowest)
- Failures CI caught that pre-flight didn't? (gap to close)

Document patterns in a `## Pattern observations` block at the top of this file (before the entries list). Update as the log grows.
