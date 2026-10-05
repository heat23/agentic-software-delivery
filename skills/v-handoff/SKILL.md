---
name: v-handoff
description: "Use when ending a session and handing state to a fresh Claude session."
argument-hint: "[reason]"
model: haiku
context: fork
allowed-tools: Bash, Read, Write, AskUserQuestion
user-invocable: true
---
<!-- skill: v-handoff | version: 1.1.0 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing entry point.

This contract overrides older sections below on conflict.

Follow `_v-core.md` and `_v-exec.md`.

For the four Stop-hook-validated artifact format contracts (PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT, HANDOFF), read `_v-artifact-formats.md`. Other session artifacts (PLAN, AUDIT_REPORT, IMPLEMENTATION_REPORT, etc.) are attached by glob without per-format validation.

Rules:
- bound long-running checks with the explicit timeout sequence
- attach the newest session artifacts via the glob `${PROJECT_ROOT}/*_${CLAUDE_SESSION_ID}.md` (matches both session-id-only and `*_[timestamp]_${CLAUDE_SESSION_ID}.md` patterns); the HANDOFF artifact itself is excluded by write-ordering — HANDOFF is written AFTER the glob runs, so it is not present at attachment-collection time. Skills must NOT add the HANDOFF write before this glob expands or self-attachment will occur.
- for the four Stop-hook-validated artifacts (PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT, HANDOFF), see `_v-artifact-formats.md` for required H2 regex and status-line conventions — operators reading the handoff need to know which artifacts are hook-binding vs. informational
- also attach the unstamped session-bridge files when present: `CONTENT_PIPELINE_STATUS.md`, `WORKTREE_HANDOFF.md`
- include current experiment and metric context when present

Output:
- `HANDOFF_${CLAUDE_SESSION_ID}.md`

```yaml
contract:
  tier: user-facing
  accepts: [session state, user context]
  produces: [HANDOFF_${CLAUDE_SESSION_ID}.md]
  invokes: []
  invoked-by: [/v, user]
  reads: [PLAN_*, AUDIT_REPORT_*, REFACTOR_PLAN_*, POLISH_PLAN_*, BUILD_BLOCKER_*, IMPLEMENTATION_REPORT_*, PRE_FLIGHT_REPORT_*, VERIFY_DONE_REPORT_*, LAUNCH_CHECKLIST_*, PROGRESS_NOTE_*, AGENT_REVIEW_*, CONTENT_PIPELINE_STATUS.md, WORKTREE_HANDOFF.md]
  # Resolved paths: ${PROJECT_ROOT}/*_${CLAUDE_SESSION_ID}.md (session-stamped artifacts, glob);
  # ${PROJECT_ROOT}/CONTENT_PIPELINE_STATUS.md and ${PROJECT_ROOT}/WORKTREE_HANDOFF.md (unstamped bridge files).
  # See `_v-artifact-formats.md` for the four Stop-hook-validated artifact formats
  # (PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT, HANDOFF) and their hook contracts.
  estimated_tokens: 5k-15k
  estimated_duration: 1-3 min
```

# /v-handoff - Session Handoff

Creates `HANDOFF_${CLAUDE_SESSION_ID}.md` with everything needed to continue work in a fresh session.

**Conventions:** Follow `_v-core.md` for artifact behavior and `_v-exec.md` for execution rules.

## Skill Boundaries

**SME persona:** This skill is run by a **senior coding-workflow continuity specialist** — specialty is producing a session-end artifact that lets the next session (potentially a fresh AI with no memory) resume without re-deriving context. Captures decisions, blockers, in-flight changes, and the operator's mental model.

### Best fit

- Capturing branch state, artifacts, recent test/build status, and next steps before ending or pausing a session
- Producing a durable handoff artifact when context is large, blockers exist, or another session will resume the work
- Recording the latest implementation context without changing the implementation itself

### Use instead

- Use `/v-maintenance` when the task is still active and you need to keep editing canonical skills, hooks, or settings
- Use `/v-plan` when the missing piece is a future implementation plan rather than a session snapshot
- Use `/v-help` when the user only needs workflow guidance and no handoff artifact

### Not for

- Implementing fixes, changing config, or hardening prompts directly
- Full project verification or quality gating
- Mandatory long-form handoffs for tiny, easily resumable sessions

## Workflow

1. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
2. Gather git state
3. Quick test check
4. Decide between summary-only mode and full handoff
5. Ask user about open context when needed
6. Write HANDOFF file
7. Show completion banner

### Summary-Only Mode

Use a lighter handoff when the session is small and there are no meaningful blockers, pending design decisions, or artifact chains to preserve:

- changed files are limited and easy to infer from `git status`
- there are no failing tests or broken builds to explain
- there is no open branch/worktree coordination risk
- the next session mostly needs "where I left off", not a full operational dossier

In summary-only mode, keep the handoff concise: branch, uncommitted changes, latest artifact, and the next 1-3 concrete steps. Do not force the full artifact inventory narrative when it adds no value.

## Data Collection

**Moved to:** `references/data-collection.md`.

**Summary:** parallel bash commands to gather branch state, git status, diff stats, recent commits, worktree list, test state, and recent session artifacts. The reference includes the worktree-safety guidance (never use `git stash` in worktree workflows).

**Trigger to load:** Workflow **Step 2** ("Gather git state"). The reference is the only source of truth for the bash commands; this skill body should not duplicate them.

## Proactive Context Check

v-handoff can be triggered proactively when context is getting tight. When invoked by the `/v` orchestrator's context monitoring (or when the user hasn't explicitly asked for a handoff), check:

```bash
# Session-weight signal: count session artifacts (feeds the "3+ artifacts" sign below).
# (P2 fix 2026-07-05: the old OLDEST/NEWEST_ARTIFACT ls -t lines computed values nothing read.)
ARTIFACT_COUNT=$(ls .v/artifacts/PLAN_*.md PLAN_*.md .v/artifacts/AUDIT_REPORT_*.md AUDIT_REPORT_*.md .v/artifacts/IMPLEMENTATION_REPORT_*.md IMPLEMENTATION_REPORT_*.md 2>/dev/null | wc -l | tr -d ' ')
echo "session artifacts: ${ARTIFACT_COUNT}"
```

Signs that handoff is needed (report these to the user):
- Session has produced 3+ artifacts (heavy context usage)
- Multiple skill invocations in the same session (plan → build → pre-flight → verify-done)
- User mentions "losing context" or responses seem to miss earlier conversation details
- Git diff shows 20+ files changed (large implementation session)

When detected, suggest: "This session has significant context. Consider running `/v-handoff` to capture state before starting fresh."

## Ask User

**Synthesize-then-confirm — do not interrogate.** Most of what a handoff
needs is already observable from disk: recent session artifacts (latest
IMPLEMENTATION_REPORT, PROGRESS_NOTE, BUILD_BLOCKER), the last 10 commits,
the diff against main, and `BLOCKED`/`TODO`/`FIXME`/`DECISION_NEEDED`/`TBD`
markers in the diff. Draft the Current Mental Model, Blockers, and Open
Decisions sections from that evidence FIRST, then present the draft in a
single AskUserQuestion call for the operator to confirm or correct — never
run the operator through a sequence of open-ended questions when the state
is already inferable.

```yaml
question: "Here's my read on this session — confirm or correct it:\n\n{draft Mental Model}\n\nBlockers: {draft blockers, or 'none detected'}\nOpen decisions: {draft open decisions, or 'none detected'}"
header: "Confirm"
options:
  - label: "Looks right"
    description: "Use this synthesis as-is"
  - label: "Let me correct it"
    description: "I'll describe what's wrong or missing (free text)"
```

If the operator picks "Let me correct it", fold their free-text reply into
the Mental Model / Blockers / Open Decisions sections before writing the
file. If they confirm, write the draft unchanged.

**Programmatic fallback (when invoked by orchestrator / Stop hook, no
operator to ask):** use the same synthesis — Mental Model, Blockers, and
Open Decisions all auto-detected from session artifacts and diff markers —
and flag each auto-generated section as `[auto-generated, may need operator
confirmation]`. Skip the AskUserQuestion call entirely in this mode.

## Output File

File: `{repo_path}/.v/artifacts/HANDOFF_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/`; create the dir.) **The filename MUST be the literal `HANDOFF_${CLAUDE_SESSION_ID}.md` — NO timestamp.** The Stop hook's completion gates test for that EXACT name via `-f` (`check-review-artifact.sh` abandonment-escape :911, MERGE_DEFERRED :3062, FND-3 :3158); a timestamped `HANDOFF_<date>_<sid>.md` is invisible to them and will NOT clear Stop. Put the generation time in the file's `generated:` field, never in the filename. The hook searches both `.v/artifacts/` and the repo root (legacy fallback).

**Template moved to:** `references/handoff-template.md`.

**Summary:** the HANDOFF document skeleton with all sections
(Current Mental Model, Branch, Uncommitted Changes, Recent Commits,
Test State, Active Worktrees, Blockers, Open Decisions, Context,
Attached Artifacts, Next Steps) plus AUTHORING NOTE blocks that get
stripped before writing the final file. Blockers and Open Decisions
are the mandatory sections Gotcha 5 requires — never omit them.

**Trigger to load:** Workflow **Step 6** ("Write HANDOFF file").
Read the template from the reference, populate sections from data
collected in Step 2, **strip every `<!-- AUTHORING NOTE -->` block**
(grep-verify after stripping — none should remain in the rendered
file), then write to
`{repo_path}/.v/artifacts/HANDOFF_${CLAUDE_SESSION_ID}.md` — the same path declared in § Output File above; create `.v/artifacts/` if it doesn't exist. Do NOT drop the `.v/artifacts/` segment: the repo root is a legacy Stop-hook fallback, not the primary write location.

**Authoring-note removal is a hard contract:** the operator only
sees the rendered content. Any `<!-- AUTHORING` marker remaining
in the final file is a malformed handoff. Verify after writing:

```bash
[ "$(grep -c '<!-- AUTHORING' "$HANDOFF_FILE")" -eq 0 ] || echo "MALFORMED: authoring notes left in $HANDOFF_FILE"
```

## Completion

```
========================================
  HANDOFF COMPLETE
  File: {repo_path}/.v/artifacts/HANDOFF_${CLAUDE_SESSION_ID}.md
  Action: Start a fresh session and read the v-handoff file
========================================
```

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | HANDOFF file describes "what we did" but next session can't reproduce the state | Git state not captured | Always include `git log --oneline -10`, `git diff HEAD --stat`, and current branch name |
| 2 | Handoff captures wrong working directory | `pwd` saved instead of project root | Capture `git rev-parse --show-toplevel` AND `pwd` separately; next session may need both |
| 3 | Handoff references files that get cleaned up between sessions | Local artifacts not preserved | Identify which files are session-temp vs durable; handoff lists durable ones explicitly |
| 4 | Handoff written but session continues — bloated artifact | Handoff is for SESSION END | If session continues, use `PROGRESS_NOTE` instead; handoff is the end-of-session protocol |
| 5 | Open decisions / blockers not surfaced | Captured "what was done" but not "what wasn't" | Mandatory sections: blockers (with hypothesis), open decisions (with options), next concrete step |
## Idempotency

**Idempotent.** Re-running produces a fresh HANDOFF artifact reflecting current session state. Pure read of session context — no project mutations.
