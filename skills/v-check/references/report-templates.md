# v-check Report Templates

Use these templates when writing the final report. Keep the main `SKILL.md` focused on modes, domains, and execution rules.

## Standalone Report Skeleton

```markdown
# AUDIT_REPORT
generated: [ISO_DATE]
report_status: generated
stack: laravel/[react|livewire|blade]
audit_type: [full|security|performance|quick]
depth: [thorough|standard|quick]

## EXECUTIVE_SUMMARY

### Critical Findings (P0)
- [count] security issues requiring immediate fix
- [count] data integrity risks

### Important Findings (P1)
- [count] performance issues
- [count] test coverage gaps

### Polish Items (P2)
- [count] UX improvements
- [count] tech debt items

## FINDINGS

### P0_CRITICAL
<!-- Omit this section entirely if no P0 issues found -->

#### FND-001: [Issue Title]
file: [path:line]
type: [security | performance | growth | ux | test-coverage | accessibility | seo | docs | tech-debt | completeness | other]
severity: critical
confidence: high
issue: |
  [What's wrong]
evidence: |
  [Code snippet or grep output]
fix: |
  [Specific fix with code]
test: |
  [How to verify the fix]

### P1_IMPORTANT
<!-- Omit this section entirely if no P1 issues found -->

### P2_POLISH
<!-- Omit this section entirely if no P2 issues found -->

## VERIFIED_GOOD
- [x] [Items checked that are correctly implemented]

## IMPLEMENTATION_ORDER
1. [highest-severity blocker]
2. [next highest user or security risk]

## NEXT_STEPS
1. Review findings for accuracy
2. Start fresh implementation session if needed
3. Run: `/v-build AUDIT_REPORT_[timestamp].md`
```

## Scoped Report Skeleton

```markdown
# AUDIT_REPORT
generated: [ISO_DATE]
report_status: generated
mode: scoped
depth: standard (scoped)

## SCOPE
files_audited:
  - [file1.php]
  - [file2.tsx]

## EXECUTIVE_SUMMARY

### Critical Findings (P0)
- [count] issues requiring immediate fix

### Important Findings (P1)
- [count] issues to address

### Polish Items (P2)
- [count] minor improvements

## FINDINGS

### P0_CRITICAL
<!-- Omit if none -->

### P1_IMPORTANT
<!-- Omit if none -->

### P2_POLISH
<!-- Omit if none -->

## VERIFIED_GOOD
- [x] [Items checked that are correctly implemented in scoped files]

## SUMMARY
- Files audited: [N]
- P0 findings: [N]
- P1 findings: [N]
- P2 findings: [N]
```
