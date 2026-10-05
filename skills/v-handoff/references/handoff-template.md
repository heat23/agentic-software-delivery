# v-handoff template

> **Persona for this reference:** senior session-handoff engineer.
> Loaded on-demand by v-handoff to populate the HANDOFF document.

The template below is the canonical skeleton. v-handoff Workflow
Step 4 (Output) writes the file at
`{repo_path}/.v/artifacts/HANDOFF_${CLAUDE_SESSION_ID}.md` (literal name — NO timestamp; the Stop-hook completion gates test this exact filename)
using this template, populated with data collected in Step 1.

**Behavior contract:** the section structure is preserved verbatim.
The `<!-- AUTHORING NOTE -->` blocks must be stripped before
writing the final file — the operator should only see the rendered
content, not the synthesis instructions.

---

## Template content

````markdown
# Handoff — {date}

<!-- HEADING CONTRACT (P0 fix 2026-07-05, skill review): the heading MUST start with
     "Handoff" — check-review-artifact.sh accepts a HANDOFF only when it matches
     `^#+[[:space:]]*Handoff\b` (hook line ~743). The old "# Session Handoff — {date}" form
     failed that regex, so every standalone /v-handoff artifact was silently rejected by the
     Stop hook's abandonment-escape. Same class as the 2026-06-18 "H2 contract fix" in
     v/references/dispatch-v-handoff.md, which was never backported here. -->


<!-- AUTHORING NOTE — strip these instructions before writing the
     final HANDOFF file; the operator only sees the synthesized
     Mental Model paragraph below. -->

## Current Mental Model

<!-- AUTHORING NOTE: replace this entire block with a 3-5 sentence
     paragraph synthesized from the four Ask User answers (or from
     auto-detected session artifacts if invoked by orchestrator).
     The fresh session reads THIS first.

     The paragraph must cover:
     1. What was the operator trying to accomplish? (the goal)
     2. What's working / what landed? (concrete progress, files touched)
     3. What's stuck or unclear? (the blocker, open question)
     4. Next concrete action (what should the fresh session DO first —
        not "review", but "implement X" or "decide between A and B")

     If auto-generated, prefix the paragraph with: "[auto-generated,
     may need operator confirmation]" -->

## Branch
`{branch_name}`

## Uncommitted Changes
{git status --short output}

### Diff Summary
{git diff --stat output}

## Recent Commits
{last 10 commits from git log --oneline}

## Test State
- PHP Tests: {passing/failing} ({count})
- Build: {pass/fail}

## Active Worktrees
{git worktree list output, or "None — working in main directory"}

### Lock File Status
{For each worktree: path, lock sid, lock age, safe-to-delete (yes if no lock, or lock sid matches, or lock age > 4h). "No active worktrees" if none.}

## Merge State
<!-- AUTHORING NOTE (item 27, 2026-07-03): if this session's worktree branch has commits not
     yet merged into main AND the merge is being intentionally deferred (not just forgotten),
     emit the EXACT line below — this is the literal string the W5F-3 / FND-3 gates in
     hooks/check-review-artifact.sh grep for as the deferral escape hatch. Get the branch name
     wrong or omit this line and a genuinely-deferred merge gets flagged as a silently stranded
     worktree on the next session's Stop check. Omit this whole section if there is no worktree
     or the branch is already merged. -->
MERGE_DEFERRED: {worktree_branch_name}

## Blockers
<!-- AUTHORING NOTE: list each open blocker as "- {what's blocked} — hypothesis: {suspected
     cause}". If none, write "None identified." Never leave this section absent — Gotcha 5
     treats a missing Blockers section as a malformed handoff (the next session has no way
     to tell "no blockers" from "blockers not captured"). -->
{blocker list, each with a hypothesis, or "None identified."}

## Open Decisions
<!-- AUTHORING NOTE: list each undecided question as "- {the decision} — options: {A} vs {B}".
     If none, write "None identified." -->
{open decision list, each with options, or "None identified."}

## Context
{from user input}

## Attached Artifacts
- PLAN: {latest PLAN file or "None"}
- AUDIT_REPORT: {latest audit report or "None"}
- REFACTOR_PLAN: {latest refactor plan or "None"}
- POLISH_PLAN: {latest polish plan or "None"}
- BUILD_BLOCKER: {latest blocker report or "None"}
- IMPLEMENTATION_REPORT: {latest implementation report or "None"}
- PROGRESS_NOTE: {latest progress note or "None"}
- PRE_FLIGHT_REPORT: {latest pre-flight report or "None"}
- VERIFY_DONE_REPORT: {latest verify-done report or "None"}
- LAUNCH_CHECKLIST: {latest launch checklist or "None"}
- DOCS_AUDIT: {latest docs audit or "None"}
- AGENT_REVIEW: {latest agent review or "None"}

## Next Steps
1. {concrete next action}
2. {second action}
3. {third action}

<!-- AUTHORING NOTE (item 27): if a Next Step involves landing this session's worktree branch,
     NEVER write "git checkout main" + a raw "git merge --ff-only <branch>" as the instruction —
     both are unexecutable/unsafe from a linked worktree (git refuses to check out a branch
     that's already checked out in another worktree) and a raw merge bypasses the merge lock,
     artifact gate, and commit witness that check-review-artifact.sh relies on. Instead instruct:
     `bash ~/.claude/skills/v/references/v-merge-back.sh {session_id}` — or, if the merge is
     genuinely deferred, rely on the `MERGE_DEFERRED:` line above instead of a manual next step. -->

---

**To continue:** Start a fresh Claude Code session, then:
```
Read this file: HANDOFF_${CLAUDE_SESSION_ID}.md
```

Handoff Status: {READY|BLOCKED — READY when next steps are executable as written; BLOCKED when an open decision or unresolved failure prevents them}
````

---

## How v-handoff fills this in

| Section | Source |
|---|---|
| Current Mental Model | 3-5 sentence synthesis from the 4 Ask User answers, OR auto-detected from session artifacts (IMPLEMENTATION_REPORT, PROGRESS_NOTE, BUILD_BLOCKER, recent commits, diff against main) |
| Branch | `git branch --show-current` |
| Uncommitted Changes | `git status --short` + `git diff --stat` |
| Recent Commits | `git log --oneline -10` |
| Test State | Last test command output / CI status |
| Active Worktrees | `git worktree list` |
| Blockers | Synthesized from the operator's stuck/unclear answer, or auto-detected `BLOCKED`/`TODO`/`FIXME` diffs, each with a hypothesis |
| Open Decisions | Synthesized from the operator's answer, or auto-detected `DECISION_NEEDED`/`TBD` markers, each with the options in play |
| Context | The chosen context tag (task / blockers / open decisions / save state) |
| Attached Artifacts | List of recent `IMPLEMENTATION_REPORT_*`, `AUDIT_REPORT_*`, `PRE_FLIGHT_REPORT_*`, etc. |
| Next Steps | Synthesized from open decisions + blockers |

## Authoring note removal

Before writing the file:

1. Strip every `<!-- AUTHORING NOTE -->` block in full
2. Strip the top-level `<!-- AUTHORING NOTE — strip these
   instructions ... -->` block
3. Verify the resulting file has no `<!-- AUTHORING` markers left
   (grep — if any remain, the file is malformed)
