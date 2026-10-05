# v-docs Route Templates

_Last reviewed: 2026-08-02 (Route 2: noted the answer-engine phrasing rule now applies to the FAQ/guide headings below; prev 2026-07-05 added Route 6 skeletons)._

Use these route-specific templates when the main `SKILL.md` needs examples without carrying all of the repetitive inline scaffolding.

## Route 1: API Documentation

### Output Skeletons

**openapi.yaml**

```yaml
openapi: 3.1.0
info:
  title: [App Name] API
  version: 1.0.0
  description: [Generated from code]

servers:
  - url: https://[domain]/api
    description: Production

paths:
  /endpoint:
    get:
      summary: [From controller docblock or method name]
      tags: [Controller name]
      security:
        - bearerAuth: []
      parameters:
        - name: [param]
          in: query
          schema:
            type: string
      responses:
        '200':
          description: Success
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Resource'

components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
  schemas:
    Resource:
      type: object
      properties:
        [from Resource class]
```

**docs/api/README.md**

````markdown
# API Reference

## Authentication
Bearer token via Sanctum. Include header:
`Authorization: Bearer {token}`

## Endpoints

### [Resource Name]

#### GET /api/resource
[Description]

**Parameters:**
| Name | Type | Required | Description |
|------|------|----------|-------------|

**Response:**
```json
{
  "data": [...]
}
```

#### POST /api/resource
[Description]

**Request Body:**
| Field | Type | Required | Validation |
|-------|------|----------|------------|

**Response:**
```json
{
  "data": {...}
}
```
````

## Route 2: Public User Docs

### Ask First

```yaml
question: "What should the docs cover?"
header: "Scope"
multiSelect: true
options:
  - label: "Quick Start guide"
    description: "Get users to first success fast"
  - label: "Feature guides"
    description: "How to use each feature"
  - label: "FAQ"
    description: "Common questions and answers"
  - label: "Troubleshooting"
    description: "Common issues and solutions"
```

### Output Skeletons

FAQ and feature-guide headings below are already question-shaped — keep them that way, and
put the direct 1-2 sentence answer immediately under the heading before any elaboration (see
`SKILL.md` § Answer-engine phrasing (FAQ + guide headers)). `[Answer ...]` placeholders mean
"the direct answer first," not "background, then eventually an answer."

**docs/quick-start.md**

```markdown
# Quick Start

Get up and running in 5 minutes.

## 1. Create Account
[Screenshot/description]

## 2. [First Action]
[Steps with screenshots]

## 3. [See Results]
[What success looks like]

## Next Steps
- [Link to feature guide]
- [Link to API docs]
```

**docs/features/[feature].md**

```markdown
# [Feature Name]

## Overview
[What it does, why it's useful]

## How to Use

### Step 1: [Action]
[Description with screenshot]

### Step 2: [Action]
[Description]

## Tips
- [Pro tip 1]
- [Pro tip 2]

## Related
- [Link to related feature]
```

**docs/faq.md**

```markdown
# Frequently Asked Questions

## Getting Started

### How do I create my first [resource]?
[Answer with link to guide]

### What are the free tier limits?
[Answer from config - VERIFY AGAINST CODE]

## Billing

### How do I upgrade?
[Answer]

### Can I cancel anytime?
[Answer]

## Technical

### What browsers are supported?
[Answer]

### Is my data secure?
[Answer with specifics]
```

## Route 3: Audit Existing Docs

### Report Skeleton

```markdown
# DOCS_AUDIT_[timestamp]: [Project]
generated: [DATE]
filename: DOCS_AUDIT_[YYYY-MM-DD_HHMM]_${CLAUDE_SESSION_ID}.md

## SUMMARY

| Category | Score | Issues |
|----------|-------|--------|
| Completeness | [1-10] | [count] |
| Accuracy | [1-10] | [count] |
| Currency | [1-10] | [count] |
| DX | [1-10] | [count] |
| Navigation | [1-10] | [count] |

Overall: [1-10]

## CRITICAL_ISSUES (P0)

### DOC-001: [Feature] not documented
location: docs/features/
confidence: high
impact: Users can't learn feature
fix: Create docs/features/[feature].md

### DOC-002: Incorrect limit stated
confidence: high
location: docs/faq.md:45
issue: Says "5 projects" but config says 10
fix: Update to match config('plans.free.limits.projects')

## IMPROVEMENTS (P1)

### DOC-003: Missing code examples
location: docs/api/README.md
impact: Developers struggle to integrate
fix: Add curl/JS examples for each endpoint

## POLISH (P2)

### DOC-004: Inconsistent formatting
locations: [list]
fix: Standardize headers and code blocks

## RECOMMENDATIONS

1. [Specific actionable recommendation]
2. [Another recommendation]
```

## Route 4: Changelog Generation

### Ask First

```yaml
questions:
  - question: "What's the version for this changelog entry?"
    header: "Version"
    multiSelect: false
  - question: "What date range to cover?"
    header: "Date Range"
    multiSelect: false
    options:
      - label: "Since last tag"
        description: "From previous release to now"
      - label: "Last 30 days"
        description: "Last month of commits"
      - label: "Custom date range"
        description: "Specify start and end dates"
  - question: "Commit format in use?"
    header: "Format"
    multiSelect: false
    options:
      - label: "Conventional commits (feat:, fix:, etc.)"
        description: "Structured commit messages"
      - label: "PR title format (#123)"
        description: "Squash-merged PRs with issue numbers"
      - label: "Both / Mixed"
        description: "Use both formats"
```

### Output Skeleton

```markdown
# Changelog

## [1.2.0] - 2026-03-10

### Added
- [#123] Feature description ([commit hash](link))
- New capability X that enables Y

### Fixed
- [#456] Bug fix description
- Issue where X caused Y

### Changed
- [#789] Breaking change or significant modification

### Deprecated
- Old feature that will be removed in 2.0

### Security
- Security fix for vulnerability description
```

## Route 5: Migration Guide

### Ask First

```yaml
questions:
  - question: "What type of breaking change?"
    header: "Change Type"
    multiSelect: false
    options:
      - label: "API endpoint change"
        description: "Removed, renamed, or restructured endpoint"
      - label: "Configuration change"
        description: "Config file structure or option changes"
      - label: "Database schema change"
        description: "New migrations affecting data structure"
      - label: "Dependency update"
        description: "Major version bump in libraries"
  - question: "What's the source version?"
    header: "From Version"
    multiSelect: false
  - question: "What's the target version?"
    header: "To Version"
    multiSelect: false
```

(Tool caps AskUserQuestion at 4 options, consistent with SKILL.md § Entry Point. "Multiple / Complex" is folded into the free-text "Other" the tool always appends — a migration guide covering several breaking-change domains is still written the same way; the "Breaking Changes" section below already lists multiple numbered items regardless of which single Change Type was picked, so no capability is lost.)

### Output Skeleton

````markdown
# Migration Guide: v1.x -> v2.0

## Overview

This guide covers breaking changes in v2.0 and how to migrate your application.

## Breaking Changes

### 1. API Endpoint Restructure

**What Changed:**
- `/api/resource/{id}` -> `/api/v2/resource/{id}`
- Response format changed from `{ data: [...] }` to `{ resources: [...], meta: {...} }`

**Why:**
[Benefits of change]

**Before:**
```bash
curl https://api.example.com/api/resource/123
# Response: { "data": { "id": 123, "name": "X" } }
```

**After:**
```bash
curl https://api.example.com/api/v2/resource/123
# Response: { "resources": [{ "id": 123, "name": "X" }], "meta": { ... } }
```

**How to Migrate:**
1. Update all API calls to use `/api/v2/` prefix
2. Update response parsing to access `response.resources[0]` instead of `response.data`
3. Handle new `meta` object for pagination info

### 2. Configuration File Changes

**What Changed:**
`config/app.php` -> `config/application.php` (file renamed)

**Before:**
```php
// config/app.php
return [
    'name' => env('APP_NAME'),
];
```

**After:**
```php
// config/application.php
return [
    'app_name' => env('APP_NAME'),
];
```

**How to Migrate:**
1. Rename `config/app.php` to `config/application.php`
2. Update references in code: `config('app.name')` -> `config('application.app_name')`

## Timeline

| Event | Date | Action Required |
|-------|------|-----------------|
| v1.10 released | 2026-01-01 | (no change needed) |
| v2.0-beta | 2026-02-01 | Prepare migration |
| v2.0 released | 2026-03-01 | Migrate before date |
| v1.x end of life | 2026-06-01 | v1.x no longer supported |

## Troubleshooting

**Q: I get 404 errors after upgrade**
A: Verify your API calls use `/api/v2/` prefix. Check CHANGELOG.md for endpoint renames.

**Q: Configuration not loading**
A: Ensure `config/application.php` exists and matches new format. Run `php artisan config:cache` to refresh.
````

### Output Shape

Migration guides should include:
- overview
- what changed
- why
- before/after examples
- troubleshooting
- timeline

## Route 6: AI-Facing Internal Docs (ADRs / CLAUDE.md Maintenance)

### Output Skeleton — new ADR (docs/adr/ADR-{NNNN}-{slug}.md)

```markdown
# ADR-0001: [Decision Title]
status: proposed
date: [ISO date]

## Context
[Why this decision needs to be made]

## Options
1. [Option A] — [pros] / [cons]
2. [Option B] — [pros] / [cons]

## Decision
[Chosen option]

## Rationale
[Why this option was selected, or "unverified — reconstruct from author" if backfilled from history without a clear record]

## Consequences
[What changes as a result, including trade-offs accepted]
```

### Output Skeleton — an `## Architecture Decisions` section in the project's `CLAUDE.md` (single-app repos without docs/adr/)

```markdown
## Architecture Decisions

### [ISO date]: [Decision Title]
- Context: [why]
- Decision: [what was chosen]
- Consequences: [trade-offs accepted]
```

### Backfill Audit Skeleton (when the request is "document our past decisions")

```markdown
## ADR Backfill Findings

| Decision (inferred) | Evidence | Confidence | Action |
|---|---|---|---|
| [e.g. "Switched from SQLite to Postgres"] | [commit/PR/migration file] | high/medium/low | create ADR-000N |
```
