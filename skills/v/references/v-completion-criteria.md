# Task Completion Criteria Reference

## Completion Requirements by Size

| Size | Required Before Claiming Done |
|------|-------------------------------|
| **Bug fix** | Fix implemented + regression test passing |
| **Small** | All changed files tested + linter clean |
| **Medium** | Small criteria + integration tests + diff self-review + entry in CHANGELOG.md (or equivalent) |
| **Large** | Medium criteria + design doc self-reviewed by AI before build + phased PRs + e2e test covering the new user path |

## Completion Verification Artifacts

**For Bug fix / Small:**
- `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` exists and is passing for this session (v-pre-flight was invoked)
- `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md` exists for this session (v-verify-done was invoked)
- `POLISH_PLAN_*_${CLAUDE_SESSION_ID}.md` exists if UI files were changed (dual-search: `.v/artifacts/` first, bare root as legacy fallback)
- `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` exists and is semantically completed for this session
- "Semantically completed" means executed codex/superpowers provenance, no degraded self-review language, and the required provenance fields are present

**Additionally for Medium / Large:**
- `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` exists
- `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` exists
- `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` with `mode: scoped` exists
- Worktree isolation was used (or scope misclassification is documented in report)

## Anti-Patterns to Catch

If you realize you skipped a required skill, do NOT write a retroactive artifact — invoke `/v-pre-flight` now or invoke `/v-verify-done` now as appropriate.

**Agent review anti-patterns:**
- "I skipped agent dispatch because I implemented inline" — agent review is mandatory for ALL implementations
- "There was no agents directory so I skipped it" — invoke `superpowers:requesting-code-review` as fallback

**Verify-done anti-patterns (frequently skipped in early sessions):**
- "It's a content-only session" — if ANY `.php`, `.ts`, `.tsx`, `.js`, `.jsx` file was modified, verify-done is mandatory. Use the same file extension check as agent review (Step 5).
- "It's a Small/Polish scope" — scope does NOT determine verify-done requirement. Code changes do.
- "Deferred to user request" — verify-done is NOT optional or on-request. It runs automatically as the last gate.
- Only skip verify-done when ZERO code files were changed (pure markdown, SVG, image, or `.env` changes only).

## Zero-Skills Critical Failure

If you have invoked ZERO sub-skills during this session, this is a critical failure. The rationalization "No skills were needed" is never valid — every implementation requires at minimum v-pre-flight and v-verify-done.

"None" is NEVER an acceptable answer for "Skills Executed" in the completion report.

You are NOT allowed to:
- Run tests manually instead of invoking `/v-pre-flight`
- Review code manually instead of invoking `/v-verify-done`
- Implement a feature "directly" and claim no skills were needed
- Skip polish because "it's just a backend change" (Step 3.5 determines this, not you)
