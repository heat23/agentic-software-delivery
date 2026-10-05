# v-audit-admin Report Templates

_Last reviewed: 2026-07-05._

Use these templates when writing admin audit outputs. Keep the main `SKILL.md` focused on discovery, domains, scoring, and execution flow.

## Feature Inventory Matrix Example

```markdown
## FEATURE_INVENTORY_MATRIX

| Resource | List | Create | Edit | Delete | Search | Filter | Sort | Bulk | Export | Audit Log |
|----------|------|--------|------|--------|--------|--------|------|------|--------|-----------|
| User     | Y    | Y      | Y    | Y      | ?      | ?      | ?    | ?    | ?      | ?         |
| Post     | Y    | Y      | Y    | N      | ?      | ?      | ?    | ?    | ?      | ?         |
| ...      |      |        |      |        |        |        |      |      |        |           |
```

## JSON Report Structure

```json
{
  "audit_metadata": {
    "project_name": "...",
    "audit_date": "ISO date",
    "audit_type": "v-audit-admin",
    "depth": "quick|standard|thorough",
    "admin_prefix": "[detected]",
    "total_domains": 3,
    "total_findings": 0,
    "by_priority": {"P0": 0, "P1": 0, "P2": 0, "P3": 0},
    "admin_panel_score": 6.5,
    "model_coverage": "X/Y models with admin CRUD (Z%)",
    "scorecard": [
      {"domain": "Functional Completeness", "persona": "PM", "score": 7.0, "finding_count": 4, "summary": "..."}
    ]
  },
  "feature_inventory_matrix": [],
  "priority_actions": [],
  "findings": [],
  "verified_good": []
}
```

## Markdown Companion Skeleton

````markdown
# ADMIN_AUDIT_REPORT
generated: [ISO_DATE]
status: ready
stack: [detected]
depth: [quick|standard|thorough]
admin_prefix: [detected]

## FEATURE_INVENTORY_MATRIX

| Resource | List | Create | Edit | Delete | Search | Filter | Sort | Bulk | Export | Audit Log |
|----------|------|--------|------|--------|--------|------|------|--------|-----------|
| ...      |      |        |      |        |        |      |      |        |           |

## EXECUTIVE_SUMMARY

### Admin Panel Score: X.X/10
### Coverage: X/Y models with admin CRUD (Z%)
### Critical Findings (P0): N
### Important Findings (P1): N
### Polish Items (P2): N (standard/thorough only — Quick mode is P0/P1 only)
### Deferred Items (P3): N (thorough only — exclusively from Domain 2-4 subagents' `low` severity)

## FINDINGS

### P0_CRITICAL
<!-- Omit this section entirely if no P0 issues found -->

```json
{
  "id": "ADM-PM-001",
  "priority": "P0|P1|P2|P3",
  "confidence": "high|medium|low",
  "domain": "Functional Completeness|Visual Craft|Usability|Edge Cases|Audit Trail & Security|AI-Built Blind Spots",
  "title": "...",
  "description": "...",
  "evidence": [
    {
      "type": "code|pattern|config|missing",
      "path": "app/Http/Controllers/Admin/UserController.php",
      "lines": [42, 58],
      "note": "No bulk action methods exist",
      "proof": "Controller has index/create/store/edit/update/destroy but no bulkDelete/bulkExport"
    }
  ],
  "implementation": {
    "approach": "Short explanation of fix",
    "changes": ["Specific change 1", "Specific change 2"],
    "verification": ["How to verify the fix"]
  },
  "effort_hours": 4
}
```

### P1_IMPORTANT
<!-- Omit this section entirely if no P1 issues found -->

#### ADM-OPS-001: [Issue Title]
...

### P2_POLISH (thorough only)
<!-- Omit this section entirely if no P2 issues found -->

#### ADM-DES-001: [Issue Title]
...

### P3_DEFERRED (thorough only)
<!-- Omit this section entirely if no P3 issues found. P3 is exclusively produced by the
     Domain 2-4 subagents' `low` severity (per `[[v-core-severity]]` § Cross-vocabulary
     mapping); Domains 1, 5, 6 never natively emit it. -->

#### ADM-QA-001: [Issue Title]
...

## VERIFIED_GOOD

Items checked that are correctly implemented:
- [x] Admin routes protected by auth middleware
- [x] CRUD operations for User model
- [x] ...

## IMPLEMENTATION_ORDER

Execute fixes in this order:
1. ADM-PM-001 (highest-severity blocker)
2. ADM-OPS-001 (next highest)
3. ...

## NEXT_STEPS (standalone only)

Admin audit complete. Implementation prompts are in `.v-prompt-packs/v-audit-admin-<MM-DD>/`:

1. Review the session map in `.v-prompt-packs/v-audit-admin-<MM-DD>/00-README.md`
2. Open parallel Claude sessions
3. Copy-paste each prompt file into its own session
4. Sessions marked "Can Parallel? Yes" can run simultaneously
5. After all sessions merge, run the quality gate commands from CLAUDE.md

Estimated effort:
- P0 fixes: [X items, Yh total]
- P1 fixes: [X items, Yh total]
- P2 fixes: [X items, Yh total] (thorough only)
- P3 fixes: [X items, Yh total] (thorough only)
````
