# /v Rationale Ledger — forensic evidence behind SKILL.md rules

Created 2026-07-01 (Phase-3 trim). SKILL.md keeps each rule + its W-tag + a one-clause why;
the full production postmortems live HERE, keyed by tag. This removes the documented
hallucination vector (the model quoting old session UUIDs from SKILL.md as live state — the
same reason the Final Guard's session excerpts were stripped) while preserving the audit trail.
Nothing in this file is a rule; the rules live in SKILL.md and the references. Do not load this
file during a normal /v run — it exists for maintainers auditing WHY a rule exists.

## SID-RESOLUTION (SKILL.md § Session ID Resolution)
- **Wrong-UUID adoption**: invoked with `/v GAUNTLET_REPORT_<uuid>.md`, the orchestrator adopted the INPUT
  artifact's UUID for its own outputs → `PRE_FLIGHT_REPORT_<uuid>.md` orphaned under the wrong
  UUID; manual `sed` cleanup. Hence: SESSION_ID comes ONLY from `$CLAUDE_SESSION_ID`/runtime file,
  never from input filenames.
- **Missing env var** (2026-05-04): `${CLAUDE_SESSION_ID:?…}` in agent bash exited 127 ("missing") because
  Claude Code does not propagate the env var to Bash subshells — forcing manual export. Hence the
  runtime-file fallback (`~/.claude/runtime/current-session-id`) in resolve-sid.sh.

## W35-CAPTURE-MODE (v-verbatim-dispatch.md § Verbatim Dispatch Mechanism, step D2)
- **Runner with write tools**: a haiku runner with write tools burned 95k tokens and edited 11 unrelated files.
  `--mode capture` strips write tools from the granted allowlist so a read-only runner cannot touch
  source even if its frontmatter were mis-edited.

## W38-NO-FALLTHROUGH (v-verbatim-dispatch.md § Verbatim Dispatch Mechanism, step D2)
- **Dispatch fall-through**: the old dispatch path fell through to a broad full-tool dispatch and a Monitor()
  runaway burned 2+ hours of haiku tokens. The helper now NEVER falls through — non-zero exit emits
  `DISPATCH_STATUS=error` + documented fallback only.

## ANTI-SKIP (SKILL.md Step 4 § ANTI-SKIP GUARD — full essays behind rationalizations a/b/c)
- **(a)** (2026-05-28, 19-file React component migration): skipped review claiming
  "no additional safety signal for this class of change". Same session's UI disclosure
  refactor: 4 codex passes found FND-001/002/004/005 — real state-machine races and double-submit
  vulnerabilities on UI-only diffs. "It's just CSS/UI/migration" is exactly the class where dropped
  readouts, broken aria-disabled patterns, and stale test assertions slip through.
- **(b)** (page-template migration): skipped claiming the fork constraint forbids dispatch.
  It misreads W-fork-fix: `claude -p --agent` subprocesses AND `codex exec` both work from a fork.
  The constraint routes around the broken dispatch path; it does not license skipping the gauntlet.
- **(c)** (component migration): skipped claiming full-suite cost. The pre-flight
  runner validates gates as the full suite would see them post-merge; targeted-test substitutes miss
  cross-cutting failures — the ones gauntlet sessions actually catch.

## FORK-CONSTRAINT-EVIDENCE (SKILL.md Step 5 § FORK CONSTRAINT)
- Re-verified 2026-05-24 on 2.1.150. Three sessions all silently degraded to
  `orchestrator_inline` when `Agent(subagent_type:…)` was attempted from the fork.

## ROLE-CONTEXT (SKILL.md § CRITICAL ROLE CONTEXT + Step -3 W25-F12)
- **Role confusion** (2026-05-10/11): the orchestrator drafted "I am a research sub-agent…",
  "…exceeds appropriate sub-agent scope…", "handing back to the parent…", "the parent agent should
  re-invoke /v…" — all fabrications induced by the generic Skill-execution system prompt. Since
  2026-07-02 this class is mechanically matched by the Stop hook's ABANDON-ENRICH role-confusion
  regex (check-review-artifact.sh), which re-blocks with the captured task quoted.
- **W25-F12 anti-contradiction (full essay, harvested 2026-07-02):** if your reasoning references
  "the user's message contains a /v invocation" / "the user invoked /v" / "the parent dispatched /v
  with…", that statement is PROOF you can see the user's message. You cannot in the same response
  claim "no actual user message of the form /v <task>" or "the parent gave me no task" — those
  contradict your own observation. If you can name the /v invocation you MUST quote its content:
  the conversation context that contains the `/v` keyword also contains the rest of the prompt —
  they came in together; extract them together. Drafting "/v was invoked" and "no /v task in
  context" in one turn is a hallucination: the first sentence is correct, the second is wrong.

## W27-F14-TEMPLATE (SKILL.md Step 5 § AGENT_REVIEW template)
- **W26 audit**: AGENT_REVIEW format-failed 3 cycles (~3000 tokens): markdown heading
  instead of `Model:` line 1, missing Status in first 20 lines, missing the 6 metadata fields.
  Root cause: "read the reference for the template" instead of the template inline. Hence the
  verbatim inline template (and now the stronger v-emit-agent-review-skeleton.sh generator).

## UGREP-SELF-CHECK (SKILL.md Step 5 — do-not-pre-grep rule)
- **Several sessions**: hand-rolled `grep -qiE '^verdict:…'` self-checks spuriously
  missed and burned whole turns on theories ("hidden char?", "BSD quirk?"). Real causes: the
  host's `grep` was `ugrep` (parses some `-E`/`[[:space:]]` patterns and stray-space typos
  differently), and the Stop-hook gate is already case-insensitive + anchored
  (`grep -iE '^verdict:[[:space:]]*(pass|escalated|fail)'`). Rule: write the artifact per template;
  let the Stop hook validate; if you must read a verdict use a fixed-string `grep -i` inside `if`.

## SESSION-WRITES-HOSTILE-FOCUS (SKILL.md Step 3.0)
- **Two sessions**: on a dirty tree (200+ unrelated files) `git diff HEAD` produced
  false-positive `HOSTILE_REVIEW_REQUIRED=1` → AGENT_REVIEW rewrite cycles (~30-50k tokens). Hence
  Step 5 hostile-focus reads the session-writes log, never `git diff HEAD`.

## W-PERF8-COMMIT-FIRST (SKILL.md Step 3.0b)
- **Half-applied fix**: core source edits stayed uncommitted while only test files committed — a
  cancelled batch left the fix half-applied. **Lost edits**: a batch mixing uncommitted `.tsx` Edits
  with the cosmetic classifier call errored on the classifier's by-design exit-1 and the edits were
  reverted/lost. Hence: commit implementation BEFORE any classifier/gate/dispatch batch; never mix
  gate Bash with uncommitted Edit calls; read classifier stdout, never its exit code.
- **Near-miss**: a worktree branch reset to a base SHA almost destroyed a concurrent
  session's merged work — hence worktree-safety.sh Rule 10b blocks `git reset <commit>` in worktrees.

## COSMETIC-FAST-LANE (SKILL.md Step 3.5)
- **Two sessions**: full build+boot+Playwright on pure-styling diffs consumed the bulk of
  45-minute sessions for zero verification value (env lacked auth/seed → degraded anyway). A real
  AA-contrast bug WAS caught by the (retained) UX-critique in one of them — hence critique always runs,
  only the browser drive is skipped on COSMETIC.

## IDEMPOTENCY (SKILL.md § Idempotency — full re-invocation matrix)
| Re-invocation scenario | Behavior |
|---|---|
| Same session, same prompt, no state change | Bootstrap reuses `main-head-at-start-<sid>.txt` (FND-4 freshness); handoff check finds nothing new; classification re-runs deterministically → same routing, same Step 7 summary. |
| Same session, prompt-pack detected | Entry: Prompt Pack Detection offers resume from the next pending pack file; if accepted, runs that pack instead of re-classifying. |
| New session (different SID) | Bootstrap fresh; main HEAD captured anew; handoff check keyed to the new SID; prior artifacts treated as historical. |
| Main HEAD advanced since last run | Step 6.-1 detects divergence (Conc-FND-6 / W22-3) → re-verify, never trust the stale baseline. |

/v itself mutates nothing outside `$V_TMP_DIR` + dispatched sub-skill artifacts; sub-skills carry
their own idempotency contracts.
