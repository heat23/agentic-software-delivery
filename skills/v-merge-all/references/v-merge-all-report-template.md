# MERGE_ALL_REPORT template

Loaded on demand by `/v-merge-all` Step 7. Pure output formatting — no safety rules live here.
Extracted from SKILL.md 2026-08-03 (the skill was 100% inline at 1328 lines).

Write `.v/artifacts/MERGE_ALL_REPORT_${CLAUDE_SESSION_ID}.md`:

**The filename is literal — no timestamp segment.** The Stop hook's report-only escape probes
`-f "<dir>/MERGE_ALL_REPORT_<sid>.md"`, so a `MERGE_ALL_REPORT_<timestamp>_<sid>.md` is invisible
to it and a healthy no-op run gets recorded as an abandonment instead of a completion. This is the
same fix `v-handoff` took on 2026-08-12 for the same reason. One report per session: a second run
in the same session overwrites it, which is intended — the last run is the one that describes the
tree's final state.

```markdown
## Merge All Report

### Summary
- Branches discovered: [N]
- Branches merged: [N]
- Branches failed: [N] (see details below)
- Conflicts resolved: [N] files across [N] branches
- Artifacts rescued: [N] files

### Cleanup Completeness
- Non-active merged worktrees swept (incl. prior-run leftovers): [N] — `$SWEPT_WORKTREES`
- Merged local branches deleted: [N] — `$MERGED_BRANCHES` + `$SWEPT_BRANCHES`
- Worktrees/branches PRESERVED with reason: [N] — `$PRESERVED_WORKTREES` (each tagged `#active-lock` | `#branch-not-merged` | `#uncommitted-tracked-WIP` | `#remove-failed`)
- Leftover merged worktrees still present after sweep (expect 0): [N]
- Leftover merged local branches still present after sweep (expect 0): [N]
- Stashes present (never auto-popped — rule 7): [N] — surface each for the operator

### Remediation Context
- Latest remediation run: [run-id | none]
- Latest remediation state: [completed | blocked: state]
- Pending remediation prompt files: [N]
- Repo-root synced remediation diff treated as source of truth: [yes | no]
- Runner-owned remediation worktrees skipped as merge sources: [N]
- Runner-owned remediation worktrees cleaned: [N]
- Runner-owned remediation worktrees preserved: [N]

### Merge Order & Results
| # | Branch | Files | Conflicts | Resolution | Status |
|---|--------|-------|-----------|------------|--------|
| 1 | build/auth-abc123 | 12 | 0 | clean ff | merged |
| 2 | fix/typo-def456 | 2 | 0 | clean ff | merged |
| 3 | build/auto-20260315-141300 | 8 | 2 | auto-resolved | merged |

### Conflict Resolutions
[For each conflict that required manual resolution:]
- **File:** `path/to/file.ts`
  - **Branch:** build/feature-x
  - **Conflict:** Both branches modified the `createUser` function
  - **Resolution:** Combined both changes — kept new validation from branch A, kept new logging from branch B
  - **Risk:** Low — changes were complementary

### Failed Branches (if any)
[For each branch that could not be merged:]
- **Branch:** build/complex-refactor-xyz
  - **Error:** Incompatible structural changes to `UserService` — branch rewrote class hierarchy while another branch added methods to old hierarchy
  - **Recommendation:** Manual merge required. The branch is intact at `.worktrees/build-complex-refactor-xyz`

### Post-Merge Verification
- FF shortcut (4-pre Gate 1): [not applicable | applied — skipped 4a-4c/4e, ff-identical to gauntleted tip <sha>]
- Frontend gates 4b/4c (4-pre Gate 2): [run | skipped — no frontend files in union diff]
- Tests: [X] passing, [Y] failures
- TypeScript: [clean | N errors]
- Build: [success | failed]
- Pre-flight: [passed | failed — details]
- Main-root capture review (`MAIN_CAPTURE_NEEDS_REVIEW`): [not applicable — no capture commit | not required — capture attributed to a session with its own passing gates | reviewed — 0 CRITICAL/HIGH | reviewed — N CRITICAL/HIGH fixed before push]

### Push Status
- Pushed to origin: [yes | no — reason]
- Commits pushed: [N]

### Cleanup
- Worktrees removed: [N]
- Branches deleted: [N]
- Remaining worktrees: [N] (failed merges preserved)

### Rescued Artifacts
[List of *_${CLAUDE_SESSION_ID}.md files moved from worktrees to repo root]
```

**Verify artifact exists:** After writing, confirm the file exists with `test -f [path]`. If write failed silently, retry once.

