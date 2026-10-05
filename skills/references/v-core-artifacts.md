# Artifact Write Policy (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Artifact Write Policy

Generated deliverable files are required for planning, audit, docs, ship, handoff, and other report skills.

### Project Root Detection

**Problem:** Skills dispatched via Agent tool with `context: fork` run in a fresh context where `pwd` returns a Claude-internal session directory (e.g., `~/.claude/plans/`), NOT the project repository. Artifacts written to `pwd` in a forked context land in the wrong place.

**Rule for dispatchers:** When invoking ANY skill via Agent tool, include the project root path in the prompt:
```
PROJECT_ROOT=/absolute/path/to/repo
```
The dispatcher MUST run `pwd` before dispatching and pass the result. Example:
```
Agent(subagent_type: "general-purpose", model: "sonnet", prompt: "PROJECT_ROOT=$(pwd) Run a full audit...")
```

**Rule for skills:** At startup, determine the project root using this priority:
1. If `PROJECT_ROOT=` appears in the invocation prompt, use that path
2. Otherwise, run `git rev-parse --show-toplevel 2>/dev/null` (works in repos and worktrees)
3. If neither yields a safe repo root, stop and ask for the project path. Do NOT fall back to `pwd`.

After resolution, reject forbidden fallback roots before any reads or writes. At minimum, reject:
- `$HOME`
- `/`
- filesystem-level roots such as `/Users`, `/tmp`, `/var`, `/usr`, `/System`, `/Library`, and `/Volumes`

All artifact paths MUST use the resolved project root. Never use a bare `pwd` as a project root in a forked or headless context.

Artifact classes:
- Strategic artifacts: immutable, timestamped + session-scoped, never silently overwritten
- Operational artifacts: session-scoped `*_${CLAUDE_SESSION_ID}.md`, safe for concurrent sessions

### Session ID (`${CLAUDE_SESSION_ID}`)

Claude Code provides a built-in `${CLAUDE_SESSION_ID}` variable that is unique per session. Use it directly in all artifact filenames — do not generate a custom SID. The variable is available in skill body text, frontmatter, and bash expansions.

This ID makes every artifact filename unique per session, preventing collisions when multiple sessions (or concurrent worktrees) operate on the same branch or across different projects.

Rules:
1. Use absolute paths.
2. Choose artifact class before writing.
3. Write the file before claiming completion.
4. Include generation timestamp, source skill name, and status.
5. Record the final path in the completion message.
6. **File on disk, not text in response.** Describing the report content in your response text does NOT satisfy the artifact requirement. The file MUST be created via the Write tool. Stop hooks validate file existence on disk — they cannot see your response text. If you produce the content in-line but forget to `Write` it, the stop hook will block completion and demand you re-produce the artifact.
7. Use `${CLAUDE_SESSION_ID}` consistently for all artifacts in the session.
7. **SID-aware artifact lookup (parallel session safety):** When searching for the latest artifact of a type **from the current session**, filter by the session's `${CLAUDE_SESSION_ID}`:
   ```bash
   # Correct: find this session's artifact
   ls -t PRE_FLIGHT_REPORT_*${CLAUDE_SESSION_ID}*.md 2>/dev/null | head -1
   # Wrong: picks up any session's artifact
   # ls -t PRE_FLIGHT_REPORT_*.md | head -1
   ```
   Use the unfiltered glob (`*_*.md`) only when intentionally searching across all sessions (e.g., handoff, cross-session delta comparison, or checking if any recent artifact exists regardless of origin).
8. **Artifact expiration:** When reading an artifact, check its age against the expiration policy. If expired, warn the user before relying on it.
9. **Model decision audit trail:** Every artifact that involves judgment calls (skipping steps, choosing between approaches, interpreting ambiguous requirements) MUST include a `## Decisions` section documenting: what was decided, what alternatives were considered, and why this choice was made. This is especially important for: skipping JiT (v-build), skipping gates (v-pre-flight), choosing plan depth (v-plan), and adjudicating agent findings (v-build step 11).

### Artifact Expiration Policy

| Artifact Type | Max Age | On Expiry |
|---------------|---------|-----------|
| `PLAN_*.md` | 14 days | Warn: "Plan is [N] days old. Re-run `/v-plan` to refresh." |
| `AUDIT_REPORT_*.md` | 7 days | Warn: "Audit is [N] days old. Re-run `/v-check` or the relevant specialist audit skill." |
| `REFACTOR_PLAN_*.md` | 14 days | Warn: "Refactor plan is stale. Codebase may have changed." |
| `PRE_FLIGHT_REPORT_*.md` | 1 day | Warn: "Pre-flight report is stale. Re-run `/v-pre-flight`." |
| `BUILD_BLOCKER_*.md` | Session-only | Auto-stale after session ends. Next session should re-assess. |
| `LAUNCH_CHECKLIST_*.md` | 3 days | Warn: "Launch checklist is stale. Re-run `/v-check`." |
| `HANDOFF_*.md` | 7 days | Warn: "Handoff is [N] days old. Context may be stale — verify before relying on it." |
| `DOCS_AUDIT_*.md` | 7 days | Warn: "Docs audit is stale. Re-run the docs audit via `/v` (routes to v-docs)." |
| `POLISH_PLAN_*.md` | 7 days | Warn: "Polish plan is stale. Re-run `/v-audit-code` (codebase-wide) or a fresh `/v` build (scoped)." |
| `PROGRESS_NOTE_*.md` | Session-only | Auto-stale after session ends. |
| `AGENT_REVIEW_*.md` | Session-only | Auto-stale after session ends. |

**Age check:** Parse the `generated:` timestamp from the artifact header. If the `generated` timestamp is missing or unparseable, fall back to file modification time (`stat -f %m` on macOS, `stat -c %Y` on Linux). If neither is available, treat the artifact as expired. Emit the warning but still proceed (expiration is advisory, not blocking).

## Artifact Schemas

**Reference:** Read `references/artifact-schemas.md` for complete PLAN_SCHEMA template, all artifact specs (PLAN, AUDIT_REPORT, REFACTOR_PLAN, IMPLEMENTATION_REPORT, BUILD_BLOCKER, PROGRESS_NOTE, PRE_FLIGHT_REPORT, VERIFY_DONE_REPORT, AGENT_REVIEW, POLISH_PLAN, HANDOFF, DOCS_AUDIT, LAUNCH_CHECKLIST, IMPLEMENTATION_PROMPTS, SALES_PRICING_AUDIT, ANALYTICS_AUDIT, MESSAGING_AUDIT, SEO_AUDIT, CONTENT_BRIEF), and conditional growth/onboarding/new-product blocks.

Quick reference for artifact paths:

| Artifact | Class | Path Pattern |
|----------|-------|-------------|
| PLAN | strategic | `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| AUDIT_REPORT | strategic | `AUDIT_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| REFACTOR_PLAN | strategic | `REFACTOR_PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| IMPLEMENTATION_REPORT | operational | `IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md` |
| BUILD_BLOCKER | strategic | `BUILD_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| PROGRESS_NOTE | operational | `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md` |
| PRE_FLIGHT_REPORT | operational | `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` |
| VERIFY_DONE_REPORT | operational | `VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md` |
| AGENT_REVIEW | operational | `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` |
| POLISH_PLAN | operational | `POLISH_PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| HANDOFF | strategic | `HANDOFF_${CLAUDE_SESSION_ID}.md` (LITERAL — no timestamp; Stop gates test this exact name) |
| LAUNCH_CHECKLIST | strategic | `LAUNCH_CHECKLIST_[timestamp]_${CLAUDE_SESSION_ID}.md` |
| SESSION_LOG | reserved/manual | `SESSION_LOG_${CLAUDE_SESSION_ID}.md` |

### SESSION_LOG Schema

`SESSION_LOG_${CLAUDE_SESSION_ID}.md` is a reserved manual diagnostic artifact. It is **not** part of the standard `/v` pipeline, no live hook requires it, and no skill should claim it is mandatory unless a separate maintenance workflow explicitly asks for it.

```markdown
# Session Log: {task_name}

**Session ID:** ${CLAUDE_SESSION_ID}
**Date:** {ISO date}
**Session Model:** {model the session was started with — e.g., opus, sonnet}
**Branch:** {branch name}
**Worktree:** {yes/no — was main work done in a worktree?}
**Worktree Path:** {path if yes, "N/A" if no}
**Duration:** {approximate}

## Files Changed
- Created: {count}
- Modified: {count}
- Deleted: {count}

## Worktree Usage
| Worktree Path | Branch | Created By Skill | Merged? | Cleaned Up? |
|---------------|--------|-----------------|---------|-------------|

**How to populate:** Run `git worktree list 2>/dev/null` to detect active worktrees. Cross-reference with skill invocations — skills with `context: fork` and Agent dispatches with `isolation: "worktree"` create worktrees. Check `git branch --merged` to determine if worktree branches were merged back. Check for stale lock files with `find . -name "*.lock" -path "*worktrees*" 2>/dev/null`.

If no worktrees were used this session, write: "No worktrees used — all work done on main branch."

## Skills Invoked
| Skill | Configured Model | Actual Model | Worktree? | Status | Notes |
|-------|-----------------|--------------|-----------|--------|-------|

**How to populate columns:**
- **Configured Model:** The `model:` field from the skill's SKILL.md frontmatter (opus/sonnet/haiku/inherit). Check the active skill tree's copy of `{skill}/SKILL.md` rather than hard-coding a mirror path.
- **Actual Model:** What actually ran. For skills invoked via the Skill tool, the actual model is ALWAYS the session model (Skill tool runs inline, ignoring frontmatter). For skills dispatched via the Agent tool with `model:` parameter, the actual model matches the parameter. For manually invoked skills (`/skill-name`), `context: fork` + `model:` is honored.
- **Worktree?:** Did this skill run in a worktree? Check if the skill's SKILL.md has `context: fork` (which may use worktrees) or if the Agent dispatch used `isolation: "worktree"`. Values: `yes (path)`, `no`, or `inline`.
- If a skill dispatched subagents, add a sub-row: `  └ subagent: {task}` with the model and worktree info for that subagent.

## Quality Gates
| Status | Gate | Notes |
|--------|------|-------|
| {pass/fail/skipped} | Tests | |
| {pass/fail/skipped} | Build | |
| {pass/fail/skipped} | Lint | |
| {pass/fail/skipped} | TypeCheck | |
| {pass/fail/skipped} | Pre-flight | |
| {pass/fail/skipped} | Verify-done | |

## Errors Encountered
| # | Error | Category | Avoidable? | Resolution |
|---|-------|----------|-----------|------------|

## Pre-existing Issues
{List issues that existed before this session — clearly separated from session-caused issues}

## Deviations from Plan
{Any scope changes, skipped steps, or departures from the original plan}
```
