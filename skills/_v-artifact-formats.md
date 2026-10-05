# Artifact Format Contracts — Shared Reference

This file is the canonical reference for skill authors who write dispatch prompts that produce artifacts validated by Stop hooks (`enforce-pre-commit-gates.sh`, `check-review-artifact.sh`, etc.). The runtime contract is duplicated inline in each dispatch prompt so haiku agents see the full spec at dispatch time without an extra read; **this file is the source of truth for that pattern**.

If you're a haiku agent reading a DISPATCH_PROMPT.md, you do NOT need to also read this file — the rules are already inline in your prompt. Read this file when authoring a NEW dispatch prompt or auditing an existing one for drift.

## Hook-binding vs documentary artifacts (operator-facing summary)

Not every session artifact is enforced by a Stop hook. Operators reading a handoff or running a skill standalone need to know which artifacts, if missing, BLOCK their next commit vs. which are informational only.

| Artifact | Hook-binding? | Effect when missing | Producer skill |
|---|---|---|---|
| `PRE_FLIGHT_REPORT_${SID}.md` | **YES** — `enforce-pre-commit-gates.sh` | Next staged commit is blocked. `wip:` messages not exempt. | `/v-pre-flight` |
| `AGENT_REVIEW_${SID}.md` | **YES** — `enforce-pre-commit-gates.sh` + `check-review-artifact.sh` | Next staged commit is blocked. Must also be semantically complete (`status: complete`, hostile_focus when applicable). | `/v-build`, `/v-verify-done` (dispatched in their respective Step 5) |
| `IMPLEMENTATION_REPORT_${SID}.md` | **YES** — `check-review-artifact.sh` (runner-managed sessions only) | Runner reverts every change in the session. Only enforced when `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`. | `/v-build`, `/v-build-narrow` |
| `VERIFY_DONE_REPORT_${SID}.md` | **YES** — `check-review-artifact.sh` (Stop hook) | Stop hook adds a BLOCKING_ISSUES entry: "VERIFY_DONE_REPORT not found for this session — run /v-verify-done." Both presence AND structural validity (`validate_artifact "$VERIFY_DONE_FILE" "VERIFY_DONE_REPORT"`) are checked. Headless mode does NOT relax this gate (per AVF-002 — headless has MORE checking, not less). | `/v-verify-done` |
| `HANDOFF_${SID}.md` (LITERAL — no timestamp; the Stop-hook completion gates test this exact name via `-f`) | NO — documentary | None. Consumed by the next session's operator. | `/v-handoff` |
| `AUDIT_REPORT_*`, `BUG_HUNT_REPORT_*`, `PLAN_*`, `BUILD_BLOCKER_*`, `LAUNCH_CHECKLIST_*`, `MERGE_ALL_REPORT_*`, `*_AUDIT_*.json`, `CONTENT_*` | NO — documentary | None directly. May be referenced by downstream skills (`/v-build` reads `PLAN_*`; `/v-bug-hunt`'s `boundaries` lens reads a same-target `bugs`-lens `BUG_HUNT_REPORT_*` as baseline — v-edge-hunt merged into v-bug-hunt 2026-07-05, no more separate `EDGE_HUNT_REPORT_*` shape; `/v-handoff` attaches all session-stamped artifacts via glob). | varies |

**Operator rule of thumb:** if you ran a code-mutating skill (anything that wrote to your project files), the Stop hook (`check-review-artifact.sh`) blocks session completion unless ALL THREE of `PRE_FLIGHT_REPORT_${SID}.md`, `AGENT_REVIEW_${SID}.md`, and `VERIFY_DONE_REPORT_${SID}.md` exist at repo root and pass structural validation. Headless sessions have MORE checking, not less. Documentary artifacts (HANDOFF, AUDIT_REPORT, PLAN, etc.) are not gating.

**Pre-flight ↔ verify-done relationship:** v-pre-flight writes the gate report; v-verify-done writes its convention-check report AND dispatches the AGENT_REVIEW. Both must run in that order before session-end. Missing either → Stop hook blocks completion.

**Runner-managed implementation-only sessions** (`CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`) are the exception: PRE_FLIGHT, AGENT_REVIEW, and VERIFY_DONE are owned by the external runner outside the implementation session. The implementation session only needs a valid `IMPLEMENTATION_REPORT_${SID}.md`.

## Why This Exists

Pass 1 of the v-orchestrator-improvements plan (2026-04-29) discovered that Stop hooks reject artifacts on structural format mismatches — wrong heading level, missing `Model: haiku` line, trailing parenthetical on the status line. Format-failure re-dispatches cost ~80–94k haiku tokens per session (2 of 3 logged sessions hit this). The runtime fix was to mirror the hook's regex contract directly inside each dispatch prompt so the haiku agent produces hook-conforming output on the first try.

This shared reference exists so:

- New artifact types can inherit the pattern without re-deriving it from the hooks.
- Drift between dispatch prompts can be detected by comparing against this canonical spec.
- Hook contract changes update one anchor point and all dispatch prompts re-cite it.

## The Canonical Pattern (universal across artifacts)

Every artifact format contract enforced by a Stop hook MUST include these five rules in the dispatch prompt:

1. **`Model: haiku` in the first 5 lines.** Not just line 1; within the top 5 lines is enough. Frontmatter, comments, or blank lines may precede it.
2. **Required H2 section header matching a documented regex.** Each artifact type has a specific regex (e.g., `^##[[:space:]]+(Test Results|Gates)`). The header text must match exactly — H3 variants and minor wording changes (`## Gate Results` instead of `## Gates`) are rejected by hooks.
3. **Final-line exact-match status.** The artifact's last meaningful line is a status sentinel (`Overall Status: PASS`, `Overall Verdict: PASS`, `Handoff Status: READY`). No trailing parenthetical, no commentary — explanations go in a `## Notes` section above.
4. **Pre-existing baseline segregation (where applicable).** When the artifact reports failures, pre-existing failures (those present on merge-base before the session started) go in a separate `## Pre-existing Baseline` section and DO NOT count toward the final status. Only session-introduced failures gate the verdict.
5. **Self-validation checklist.** The dispatch prompt includes a 4–6 question pre-flight checklist for the haiku agent to mentally run before calling Write.

The dispatch prompt also carries:

- A literal example template the agent copies verbatim and fills in.
- An anti-pattern table citing real failures observed in production sessions (e.g., `### PHP Tests` H3 misuse from a production session).
- An explicit note that format failures are recoverable via in-place Edit (cheaper than re-dispatch) per `/v` SKILL.md § Format Failure Remediation.

## Registered Artifact Format Contracts

The following dispatch prompts enforce this pattern. When the hook regex changes, every entry in this table must update.

| Artifact | Dispatch prompt | Hook validator | Required H2 regex | Final status line |
|---|---|---|---|---|
| PRE_FLIGHT_REPORT | `${CLAUDE_SKILL_DIR}/references/dispatch-v-pre-flight.md` § Required Output Format (Wave 12: extracted from /v SKILL.md Appendix A.1; sibling v-pre-flight/DISPATCH_PROMPT.md is a redirect stub) | `enforce-pre-commit-gates.sh`, `validation.sh` | `^##[[:space:]]+(Test Results\|Gates)` | `Overall Status: PASS\|FAIL` |
| AGENT_REVIEW | `_v-review.md` § Required AGENT_REVIEW Artifact Format | `check-review-artifact.sh`, `enforce-pre-commit-gates.sh` | `^##[[:space:]]+(Findings\|Review)` | (provenance fields, not status sentinel — see callout below) |
| VERIFY_DONE_REPORT | `${CLAUDE_SKILL_DIR}/references/dispatch-v-verify-done.md` § Required Output Format (Wave 12: extracted from /v SKILL.md Appendix A.2; sibling v-verify-done/DISPATCH_PROMPT.md is a redirect stub) | `validation.sh` | `^##[[:space:]]+(Verification\|Checks)` | `Overall Verdict: PASS\|FAIL` |
| HANDOFF | `${CLAUDE_SKILL_DIR}/references/dispatch-v-handoff.md` § Required Output Format (Wave 12: extracted from /v SKILL.md Appendix A.3; sibling v-handoff/DISPATCH_PROMPT.md is a redirect stub) | `check-review-artifact.sh` (~line 743): ≥80 bytes AND heading matches `^#+[[:space:]]*Handoff\b` — "# Handoff — <date>" passes, "# Session Handoff" FAILS (P1 doc-drift fix 2026-07-05: this row previously claimed only defensive H2 validation, which matched no hook code) | heading regex above is the enforced one; the H2 sections (`Branch State`/`Status`/`Handoff Summary`/`Current State`) are advisory template structure | `Handoff Status: READY\|BLOCKED` |

## AGENT_REVIEW Carve-Out: No Exact-Status Sentinel

**Important for skill authors:** Universal Rule 3 (final-line exact-match status, e.g., `Overall Status: PASS`) does NOT apply to AGENT_REVIEW. AGENT_REVIEW uses **provenance fields** as its enforcement mechanism instead. Do NOT add an `Overall Status:` or similar sentinel line to AGENT_REVIEW templates — it would be ignored by the validating hook and confuse readers.

The provenance fields documented below replace the status sentinel and carry semantically richer information (which agents ran, what evidence they produced, what was remediated). When authoring or modifying AGENT_REVIEW format rules, work from this section, not from the universal rule template.

## Provenance Fields (AGENT_REVIEW only)

`AGENT_REVIEW_<sid>.md` has additional structural requirements beyond the universal pattern, enforced by the Stop hook's semantic-completion check (per `/v` SKILL.md Step 5):

- `Status: completed | pass | passed`
- `Agents dispatched: <list>` (or `none — invoked superpowers:requesting-code-review`)
- `Codex adversarial reviewer: <ran — N candidates | superpowers:requesting-code-review fallback | skipped — file not found | codex-adversarial-reviewer (orchestrator-inline fallback)>` (the value MUST contain a hook-recognized substring: `codex-adversarial-reviewer`, `superpowers:`, or `ran`)
- `Reviewer model: <haiku|sonnet|opus>` (W13 — actual model the review ran on)
- `Hostile adversarial focus: <yes — diff touches auth/payment/data | no>`
- `Dispatch mode: <foreground | background | orchestrator_inline>`
- `Review evidence: <findings count or descriptor>`
- `Remediation: <findings fixed and re-verified | no findings>`

Missing provenance fields cause `check-review-artifact.sh` to block commits. The exact field list lives in `_v-review.md` § Required AGENT_REVIEW Artifact Format.


## WORKTREE_HANDOFF Format (Wave 8)

Written by `v-merge-back.sh` when merge-back fails (rebase conflicts, lock timeout, escalation). Validated by Stop hook (`check-review-artifact.sh` enum, when hook supports it).

### Required structure

```
Model: orchestrator
SID: <session_id>

## Worktree Handoff

worktree_path: <abs path>
worktree_branch: <build/fix-* branch name>
last_commit: <sha>
merge_target: <main branch name>
attempts: <int>
conflict_files: <space-separated file list>

## Recovery Steps

1-N. <numbered steps to manually merge>

Handoff Status: BLOCKED
```

### Required validation rules

1. `Model:` line in first 3 lines (any value — orchestrator, haiku, etc.)
2. `## Worktree Handoff` H2 header
3. `## Recovery Steps` H2 header with numbered list
4. Final line exactly `Handoff Status: BLOCKED` (or `READY` if recovery is automatic)

### Why this exists

When a session can't complete merge-back (parallel-safety guards triggered, conflicts unresolvable in autonomous resolver exhausts strategies (10-cycle cap; W17-2)), the worktree is left intact. The handoff artifact records exactly how to recover so the user can manually finish or invoke `/v-merge-all`. Without this artifact, Step 6.5 failures are silent.

## How to Add a New Artifact Type

When introducing a new artifact (e.g., `BLOCKED_<sid>.md`, `RECOVERY_DEFERRED_<sid>.md`, `MERGE_PENDING_<sid>.md`):

1. **Decide if hook validation is needed.** If the artifact gates a session-end check, it needs format enforcement. If it's purely informational (e.g., a journal entry), it doesn't.

2. **If hook validation is needed:**
   a. Add a regex to `validation.sh` (or create a new validator script).
   b. Add an entry to the Registered Artifact Format Contracts table above.
   c. Author or update the dispatch prompt with a `## Required Output Format` section that mirrors the canonical pattern (rules 1–5 from above).
   d. Include a literal example template, an anti-pattern table, and a self-validation checklist.

3. **If hook validation is NOT needed:** still document the artifact's structure in the producing skill (so future readers know what fields exist), but skip the format-failure prevention apparatus. Examples: `PROGRESS_NOTE_<sid>.md` (no hook), `IMPLEMENTATION_REPORT_<sid>.md` (validated by Step 6 verification loop, not hooks).

## Anti-Pattern: Skipping the Inline Spec

A dispatch prompt MUST keep the full Required Output Format spec inline. Pointing the haiku agent at this shared file ("see `_v-artifact-formats.md` for rules") would require an extra Read call and is brittle — agents skip optional reads. The duplication across dispatch prompts is intentional; this shared file is for skill authors at design time, not for runtime haiku consumption.

## Validation

The live harness is `~/.claude/skills/v-session-log/references/v-token-budget-test.sh`
(wrapped by `~/.claude/skills/__tests__/v-token-budget-harness.test.ts`). For each
dispatch prompt (`v/references/dispatch-v-pre-flight.md`, `dispatch-v-verify-done.md`,
`dispatch-v-qa-reviewer.md`) it verifies:

- the first-line sentinel is intact (e.g. `You are v-pre-flight`);
- every binding anchor is still present — a dropped section fails the run;
- the file clears the `v-emit-prompt.sh` exit-7 minimum line floor;
- the token ratchet has not grown past its recorded baseline.

Run it after any change to a dispatch prompt or this shared reference:

```bash
bash ~/.claude/skills/v-session-log/references/v-token-budget-test.sh
```

> Superseded reference (2026-08-02): this section previously pointed at
> `audits/validate_v_changes.py`, which no longer exists on disk. The anchor/sentinel
> checks it described now live in the harness above.
