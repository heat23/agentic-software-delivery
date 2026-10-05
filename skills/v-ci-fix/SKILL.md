---
name: v-ci-fix
description: "Use when fixing failing CI jobs end-to-end from GitHub Actions logs to verified pass."
allowed-tools: Bash, Read, Write, Edit, Glob, Grep
user-invocable: true
context: fork
model: sonnet
---
<!-- skill: v-ci-fix | version: 1.3.0 | last-updated: 2026-08-12 -->
<!-- 1.2.1 (2026-08-03): the 2026-08-02 fix that removed the stale inline 10-bucket list
     (§ Failure taxonomy reference) left two stale "10" counts and an incomplete
     summary-class mapping table behind — buckets 11 (coverage-threshold regression) and
     12 (registry/schedule drift), added to failure-taxonomy.md, had no FLAKY/DEP-DRIFT/
     TEST-BUG/CONFIG/CODE-BUG/INFRA rollup, so Step 9 could not record a summary class for
     either. Mapped 11→TEST-BUG, 12→CONFIG; replaced both hardcoded "10" counts with a
     cite (never restate) of the taxonomy file. -->


# 2026 Canonical Contract

Tier: User-facing utility. Invoked directly by user when CI is red.

Follow `_v-core.md` and `_v-exec.md`.

Read `~/.claude/skills/references/v-core-cross-session.md` for prior blocker detection.

For the canonical CI/runtime error taxonomy and per-category handling patterns, read `~/.claude/skills/references/v-error-taxonomy.md`.

Rules:
- diagnose from CI logs, not guesswork
- fix code to pass checks, never disable checks
- max 3 push-watch cycles **per failure-bucket** (per the failure taxonomy below); if 2 different buckets exhaust their per-bucket cap OR total push-watch cycles ≥ 5, write CI_BLOCKER immediately
- check `~/.claude/skills/references/v-core-cross-session.md` for prior blockers

Output:
- `CI_FIX_SUMMARY_${CLAUDE_SESSION_ID}.md` (on success)
- `CI_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` (on cycle-cap / unrecoverable failure)
- (No HANDOFF needed — the `[v-ci-fix]` commit tag closes the Stop gate via `check-review-artifact.sh`'s W-LIGHT2-CHORE block; `CI_FIX_SUMMARY` is the completion record. See § Stop-gate completion.)

```yaml
contract:
  tier: user-facing
  accepts: [failing CI run on current branch]
  produces: [CI_FIX_SUMMARY_${CLAUDE_SESSION_ID}.md (success), CI_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md]
  invokes: []
  invoked-by: [/v, user]
  estimated_tokens: 10k-30k
  estimated_duration: 5-25 min (dominated by CI re-run wall-clock, not local work; a slow pipeline can push past this — resume the poll in a fresh Bash call rather than blocking)
```

# /v-ci-fix — Autonomous CI Repair

Fix the failing CI job on the current branch without human intervention.

## Skill Boundaries

**SME persona:** This skill is run by a **senior DevOps / CI specialist** — specialty is reading failing CI output, classifying the failure (flaky vs real / known-pattern vs novel / infra vs code), applying the minimum correct remediation, and updating the failure taxonomy when a new class appears so the next session is faster.

### Best fit

- Red GitHub Actions runs on the current branch where logs are available through `gh` — this includes `main` itself. Where the workflow pushes `main` directly, CI frequently goes red on `main`; this skill repairs the current branch whatever it is, feature branch or `main`
- Diagnosing CI failures from actual workflow logs, fixing code, verifying locally, and iterating until CI is green or a blocker is documented
- Branch-scoped CI repair for repositories that already use `.github/workflows/*`

### Use instead

- Use `/v-pre-flight` when the goal is local gate verification before CI goes red
- Use `/v-build` when the task is implementation work and CI is only one verification step
- Use `/v-maintenance` for user-owned hook/settings/skill maintenance outside a repo CI workflow

### Not for

- Generic CI systems that are not GitHub Actions
- Editing workflows as a first resort when the code is actually broken
- Guessing at root causes without reading the failing logs

## Failure taxonomy reference (REQUIRED — Round 3)

Before deciding the fix strategy, classify the failure into one of the
buckets defined in `${CLAUDE_SKILL_DIR}/references/failure-taxonomy.md`
— that file is the single source of truth for the bucket set, their
numbering, and their detection patterns. **Read it; do not classify from
memory and do not restate the bucket list here.** An inline copy of the
list lived at this spot until 2026-08-02 and had silently drifted (it
still said 10 buckets after buckets 11 and 12 were added), which is
exactly the failure the cite-don't-restate rule exists to prevent —
a stale copy sitting directly above an instruction to read the source.

Each bucket has signature log patterns, root-cause questions, fix
strategies, and a ship-or-defer rule. **Misclassification is the
most expensive bug in CI repair** — fixing a "race condition" with
a snapshot update wastes time AND masks the real failure.

Apply the triage decision tree at the bottom of
`${CLAUDE_SKILL_DIR}/references/failure-taxonomy.md` to classify in 2-5 minutes
before fixing. The commit message MUST name the bucket explicitly
(see § Commit convention below) so subsequent failures of the same
class are easy to spot.

**Two vocabularies, one mapping (READ THIS — F4 consistency fix).**
The numbered *buckets* defined in `${CLAUDE_SKILL_DIR}/references/failure-taxonomy.md` are
the fine-grained diagnostic classes (used in commit messages + decision
tree) — read the count from that file, never restate it here (the bug
this section's own changelog describes above is exactly a stale count
copied out of that file). The `CI_FIX_SUMMARY` /
`references/v-ci-fix-failures.md` log rolls these up into 6 coarse
*summary classes*. Always record BOTH: the bucket number (diagnosis)
and the summary class (reporting). **The summary-class → bucket mapping is
maintained ONLY in `${CLAUDE_SKILL_DIR}/references/failure-taxonomy.md` (§ top, the "Summary class |
Buckets" table) — read it there, do NOT copy it here.** A prior inline copy
drifted out of sync (it had bucket 12 under CONFIG when the canonical puts it
under CODE-BUG, and omitted bucket 13); restating the map is exactly the F4
drift class this section exists to prevent.

When Step 9 / the checklist / the failures-log ask for "failure
class," they mean a **summary class** from this table — not a bucket
number, and not a free-form word.

## Workflow

1. Resolve project root per `_v-core.md` § Project Root Detection. **Bind
   `PROJECT_ROOT` and run every subsequent `git` / `find` / local-check
   command against it** — CWD is not guaranteed to be the repo root (the
   fork may start elsewhere):
   ```bash
   cd "$PROJECT_ROOT" || { echo "ERROR: could not cd to resolved PROJECT_ROOT"; exit 1; }
   ```

2. **Prerequisite check:**
   ```bash
   command -v gh >/dev/null 2>&1 || { echo "ERROR: GitHub CLI (gh) is not installed. Install it: https://cli.github.com"; exit 1; }
   gh auth status >/dev/null 2>&1 || { echo "ERROR: gh CLI is not authenticated. Run: gh auth login"; exit 1; }
   ```
   If `gh` is missing or not authenticated, report the error with install/auth instructions and exit.

3. **Check for GitHub Actions CI configuration:**
   ```bash
   BRANCH=$(git branch --show-current)
   WORKFLOW_COUNT=$(find "$PROJECT_ROOT/.github/workflows" \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | wc -l | tr -d ' ')
   ```
   If no workflow files found (`WORKFLOW_COUNT` = 0), report "No GitHub Actions workflows found in .github/workflows/. This skill only supports GitHub Actions — use a CI-specific workflow outside `/v-ci-fix` for other providers." and exit.
   (The parenthesised `\( … \)` group is required — without it `-o` makes `find` ignore the `.yml` predicate and match every file.)

4. Find the most recent failing CI run **for the current HEAD**:
   ```bash
   HEAD_SHA=$(git rev-parse HEAD)
   FAILING_RUN=$(gh run list --status failure --branch "$BRANCH" --limit 10 \
     --json databaseId,headSha --jq "map(select(.headSha==\"$HEAD_SHA\")) | .[0].databaseId // empty")
   # Fall back to the latest failing run on the branch if none match HEAD exactly
   [ -z "$FAILING_RUN" ] && FAILING_RUN=$(gh run list --status failure --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
   ```
   If no failing run exists (`FAILING_RUN` empty), report "No failing CI runs found on $BRANCH. CI may be passing or the branch hasn't been pushed yet." and exit. If the only failing runs are for OLDER commits than HEAD, say so — HEAD may already carry an untested fix.

5. Pull the failure logs (guard the empty case — logs expire ~90 days, and cancelled/skipped runs have no failed-step log):
   ```bash
   LOG=$(gh run view "$FAILING_RUN" --log-failed 2>&1)
   if [ -z "$(printf '%s' "$LOG" | tr -d '[:space:]')" ]; then
     # Retry without the --log-failed filter (some conclusions, e.g. "cancelled",
     # "startup_failure", or a failed setup step, produce no per-step failed log).
     LOG=$(gh run view "$FAILING_RUN" --log 2>&1 | tail -400)
   fi
   printf '%s\n' "$LOG" | tail -300
   ```
   If `LOG` is still empty, treat the failure as a Bucket-7/8 infra/config class you cannot diagnose from logs → write `CI_BLOCKER` (Step 10) instead of guessing. When there are multiple failed jobs, pull the earliest-failing job's log specifically (`gh run view "$FAILING_RUN" --log --job <id>`) rather than trusting `tail -300`, which can push an early root cause out of the window.

5b. **Cross-reference the failures log BEFORE classifying** (this is what makes
   the next session faster): read the recent entries in
   `${CLAUDE_SKILL_DIR}/references/v-ci-fix-failures.md` and check whether this
   failure's signature matches a known pattern. If it does, jump straight to
   that entry's documented fix.

6. For each distinct failure in the logs, first **classify into a taxonomy
   bucket** (§ Failure taxonomy reference), then act on the bucket's
   ship-or-defer rule:

   **6-A · Code-fixable buckets (1, 2, 3, 5, 6, 9, and code-rooted cases):**
   a. Identify the root cause — trace the error to the actual file and line, not just the test or step that reported it
   b. Read the broken file(s)
   c. Write the fix
   d. Run the equivalent local check to verify — use the SAME command CI runs (e.g. `npm ci` before `npm test`, not `npm install`):
      - Test failures → run the specific failing test suite
      - Build failures → `npm run build` or equivalent
      - Lint failures → run the linter on changed files
      - Type errors → `npx tsc --noEmit`
   e. If local check passes, commit with the § Commit convention format below.
   f. If local check fails, iterate (max 3 attempts per issue)

   **6-B · Defer / no-code-fix buckets (7 network flake, 8 secret/credential,
   10 matrix-restructure, and any bucket the taxonomy marks "defer to
   operator"):** do NOT invent a code edit. The correct remediation is outside
   this session's authority (add a repo secret, rotate a credential, provision
   an infra mirror, re-run a transient job). Capture the exact operator action
   in `CI_BLOCKER` (Step 10) and stop that failure — a fabricated code change to
   "fix" a missing secret is an anti-pattern and masks the real cause. (A
   genuine transient flake with a code-side mitigation — e.g. adding
   `--fetch-retry-mintimeout` or a `waitFor` — stays in 6-A.)

7. After all code fixes are committed (skip this step if EVERY failure was 6-B —
   go straight to Step 10), push and poll for the CI result:
   ```bash
   # Capture the pre-push run id so we can wait for a NEW run, not re-read a stale one.
   PREV_RUN=$(gh run list --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId // empty')
   # Branch-aware push. This skill works on WHATEVER branch has the red run — for a
   # solo operator that is frequently `main` itself (CI often goes red on main after a
   # direct push), not only feature branches. Push the current branch:
   if ! git push origin "$BRANCH" 2>push_err.log; then
     if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
       # A protect-main hook or remote branch protection rejected the direct push.
       # Where direct push to main is the policy, a PR is NOT an acceptable
       # fallback. If protection genuinely requires a PR, STOP and report that
       # constraint in CI_BLOCKER — do NOT open a PR to route around it.
       echo "PUSH REJECTED on $BRANCH — $(cat push_err.log). If this is branch protection requiring a PR, this is a blocker: report it (do not open a PR). If it is a local protect-main hook, the fix commit is still valid locally; escalate to the operator."
       # Write CI_BLOCKER (Step 10, class INFRA, action: 'operator must allow the push or relax protection') and stop.
     else
       echo "PUSH REJECTED on $BRANCH — $(cat push_err.log)"; # feature branch push failed → treat as blocker
     fi
   fi
   PUSHED_SHA=$(git rev-parse HEAD)

   # Wait for GitHub to register a NEW run for the pushed SHA (avoids grabbing the old failing run).
   RUN_ID=""
   for i in $(seq 1 20); do          # up to ~100s for the run to appear
     RUN_ID=$(gh run list --branch "$BRANCH" --limit 5 --json databaseId,headSha \
       --jq "map(select(.headSha==\"$PUSHED_SHA\")) | .[0].databaseId // empty")
     [ -n "$RUN_ID" ] && [ "$RUN_ID" != "$PREV_RUN" ] && break
     RUN_ID=""; sleep 5
   done
   if [ -z "$RUN_ID" ]; then
     echo "No new CI run appeared for $PUSHED_SHA — check workflow triggers (does the workflow run on this branch/path?)."
     # Do not poll a stale run; treat as a blocker if it persists.
   fi

   # Bounded poll (NEVER `while true` — the Bash tool caps a single call at 10 min,
   # so an unbounded loop dies mid-CI with no verdict). Deadline-gated instead.
   CONCLUSION=""
   if [ -n "$RUN_ID" ]; then
     for i in $(seq 1 40); do        # 40 × 30s ≈ 20 min ceiling
       STATUS=$(gh run view "$RUN_ID" --json status --jq '.status' 2>/dev/null)
       [ "$STATUS" = "completed" ] && { CONCLUSION=$(gh run view "$RUN_ID" --json conclusion --jq '.conclusion'); break; }
       sleep 30
     done
   fi
   # If CONCLUSION is still empty here, CI is slower than the 20-min ceiling.
   # Re-invoke this poll block in a fresh Bash call (state is on the remote) rather
   # than extending the loop past the tool timeout. Record the RUN_ID so the next
   # call resumes on the same run.
   ```
   NOTE: Do NOT use `gh run watch --exit-status` — it blocks indefinitely and will be killed by the Bash tool timeout on long CI runs. Do NOT use `while true` — use the bounded, deadline-gated poll above so a slow CI run yields a resumable "still running" state instead of a killed loop with no verdict.

8. If CI still fails after push (`CONCLUSION` = `failure`), classify the new failure into the taxonomy bucket (Step 6, using the NEW logs). Then:
   - If the new failure is the **same bucket** as before: counts toward that bucket's per-bucket cycle cap (max 3). On the 3rd cycle in the same bucket, write CI_BLOCKER and stop.
   - If the new failure is a **different bucket**: counts as 1 cycle in the new bucket. If 2 different buckets have each consumed their per-bucket cap, write CI_BLOCKER and stop.
   - **Global ceiling:** total push-watch cycles ≥ 5 (regardless of bucket distribution) → write CI_BLOCKER and stop.
   Read the NEW failure logs (not the old ones) and repeat from step 6 if no cap has been hit.

9. On success (`CONCLUSION` = `success`): write `CI_FIX_SUMMARY_${CLAUDE_SESSION_ID}.md` in `$PROJECT_ROOT` with:
   - Branch name and CI run ID (the one that turned green)
   - **Summary class** — one of `FLAKY / CONFIG / TEST-BUG / CODE-BUG / DEP-DRIFT / INFRA` (per the mapping table in § Failure taxonomy reference) **plus** the bucket number(s) that were fixed
   - Files changed (`git diff --stat HEAD~N..HEAD` where N is the number of fix commits)
   - Push-watch cycles used (total + per-bucket breakdown, e.g., "total 2 — bucket 3: 1, bucket 7: 1")
   - One-line conclusion (e.g., "Fixed: PostgreSQL container env var missing")

   Then **append an entry to `${CLAUDE_SKILL_DIR}/references/v-ci-fix-failures.md`** (newest first, using the template at the top of that file) so the next session recognises this signature. This close-out is not optional — an un-logged fix throws away the cross-session learning that is the whole point of the log.

   Then complete the Stop gate (§ Stop-gate completion) and report the same info to chat. The artifact lets downstream sessions distinguish a completed v-ci-fix run from one that crashed.

10. On any cycle-cap trip (per Step 8: same-bucket cap, two-bucket cap, or global ceiling), on an all-6-B run (no code fix was possible), or when logs are undiagnosable (Step 5): write `CI_BLOCKER_[timestamp]_${CLAUDE_SESSION_ID}.md` in `$PROJECT_ROOT` with:
   - Branch name and CI run ID
   - Summary class + bucket (INFRA / the deferring bucket)
   - What was tried (each cycle) — or, for a 6-B defer, the exact operator action required (e.g., "add `STRIPE_SECRET_KEY` to repo Actions secrets")
   - Current failure (latest logs)
   - Hypothesis for what needs manual investigation
   - Do NOT keep making random changes

   Also append the escalation to `${CLAUDE_SKILL_DIR}/references/v-ci-fix-failures.md` (class `INFRA`), then complete the Stop gate (§ Stop-gate completion).

## Commit convention

Every fix commit MUST carry BOTH the bucket name (for pattern-spotting) AND the
`[v-ci-fix]` tag (for the pre-commit gate exemption). One canonical format:

```
fix(ci): bucket <N> — <what was fixed> [v-ci-fix]
```

e.g. `fix(ci): bucket 3 — regenerate package-lock after axios bump [v-ci-fix]`.

- The `[v-ci-fix]` tag lets the commit through `enforce-pre-commit-gates.sh`
  without PRE_FLIGHT_REPORT / AGENT_REVIEW artifacts. CI-fix commits are targeted
  repairs to already-reviewed code, not new feature deliveries — the CI pipeline
  itself is the quality gate. **Never drop the tag** (the commit will be blocked).
- The `bucket <N>` phrase lets a later session `git log --grep 'bucket <N>'` to
  see how often a class recurs.

## Stop-gate completion

**Handled by the commit tag — no extra artifact or reviewer dispatch needed (verified against the hook 2026-08-12).** Every v-ci-fix commit carries `[v-ci-fix]` (per Commit Convention above). The Stop review gate `check-review-artifact.sh` recognises that tag via its `W-LIGHT2-CHORE` block (2026-08-03): when *every* session commit is tagged `[v-ci-fix]` / `[v-chore]` / `[v-merge-all]`, it accepts the operational-commit-tag workflow and exits cleanly with **no** `PRE_FLIGHT_REPORT` / `AGENT_REVIEW` / `VERIFY_DONE_REPORT` / `HANDOFF` required — mirroring the commit-gate exemption `enforce-pre-commit-gates.sh` already grants. So just write `CI_FIX_SUMMARY_<sid>.md` (success) or `CI_BLOCKER_<sid>.md` (blocked) as the human-readable record and finish; do NOT write a HANDOFF or dispatch a reviewer to "close the gate" — the tag already does it.

The one hard requirement: **every** code commit this session makes must carry the tag. A single untagged code commit drops the session to the full gauntlet (which this `context: fork` skill cannot satisfy), and on shared `main` the baseline range can even catch a sibling's untagged commit — the exemption fails SAFE (blocks), so never commit untagged.

**Design note (not a defect):** the tag exemption means v-ci-fix commits are NOT independently code-reviewed — this is deliberate, since a CI-fix is a targeted repair to already-reviewed code, treated like a chore. If you ever want a CI-fix's *diff* reviewed anyway (e.g. it touched real application logic, not just a test/lockfile), that is an operator opt-in, not a gate requirement — dispatch `codex-adversarial-reviewer` via `v-dispatch-subagent.sh --agent codex-adversarial-reviewer --mode capture --prompt-file <brief> --artifact <path>` before push.

## Rules

- Never modify CI workflow files (`.github/workflows/`) unless the workflow itself is the problem (e.g., wrong Node version, missing env var). Prefer fixing the code over fixing the CI config.
- Never skip or disable failing checks. The goal is to make them pass, not to silence them.
- Never modify existing passing tests to make them accept broken behavior.
- If the failure is a flaky test (passes locally, fails in CI intermittently), note it in the commit message but still fix it (add retry, fix race condition, or fix timing dependency).
- Check for prior `CI_BLOCKER_*.md` files per `~/.claude/skills/references/v-core-cross-session.md` before starting — a previous session may have already diagnosed the issue.

## Progress Checklist (copy into your response, check off as you go)

```markdown
## CI-fix progress

Mirror the section headers from this skill's body workflow (the failure-taxonomy + remediation workflow documented below) into your response — one checkbox per ### Step / ### Phase / ### Gate as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

Concrete render of the current body workflow (keep in sync with the numbered
steps above — this is the example, not a second source of truth):

- [ ] Steps 1-3: PROJECT_ROOT bound, `gh` present + authed, GitHub Actions workflows found
- [ ] Steps 4-5: failing run found for HEAD, failure logs pulled (empty-log case handled)
- [ ] Step 5b: signature cross-referenced against `references/v-ci-fix-failures.md`
- [ ] Step 6: each failure classified into a bucket → 6-A (code fix) or 6-B (defer/no-code-fix)
- [ ] Step 6-A: root cause at file:line, fix applied, targeted local check passes (SAME command CI runs — NOT a full pre-flight), committed per § Commit convention
- [ ] Step 7: pushed, NEW run for pushed SHA identified, bounded poll to a verdict
- [ ] Step 8: on re-fail, re-classified and per-bucket / global cycle caps honoured
- [ ] Step 9/10: `CI_FIX_SUMMARY` (green) or `CI_BLOCKER` (capped/deferred) written to `$PROJECT_ROOT`
- [ ] Failure appended to `references/v-ci-fix-failures.md` (always, not just novel classes)
- [ ] Stop gate closed: every code commit carries the `[v-ci-fix]` tag (W-LIGHT2-CHORE exemption); `CI_FIX_SUMMARY_<sid>.md` written (§ Stop-gate completion)

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | "Fix CI" produced patch that breaks other CI jobs | Single failure analyzed without checking dependent jobs | Read the FULL workflow file; understand which jobs depend on which (matrix, `needs:`); weigh the fix's impact on dependents before committing |
| 2 | Local check passes but CI still fails after push | Environment difference (Node version, OS, env vars) | If local passes and CI fails, FIRST check env diff (Node version pinned? OS-specific paths? secrets present?) — this is Bucket 2; never push another fix without diagnosis |
| 3 | Failure classified as "flaky" but it's a real race condition | Flaky-vs-real classification too quick | Flaky requires 3+ different failures with different signatures over time; same signature 2x = real bug |
| 4 | New failure pattern fixed but not added to the log | Failures-log append skipped | Always append to `${CLAUDE_SKILL_DIR}/references/v-ci-fix-failures.md` (Step 9/10); add a NEW bucket to `failure-taxonomy.md` only when a mode fits none of the existing ones |
| 5 | Push triggers many CI runs because skill commits + pushes per fix attempt | Iterating on remote | Batch ALL local fixes and verify each with its TARGETED check (not a full pre-flight — see checklist), then push ONCE; only re-push after a genuinely new CI failure (Step 8) |

## Idempotency

**Conditionally idempotent.** Same CI failure → same remediation. New CI failure → new remediation. Mutates project state to fix the failure; re-run after fix is a no-op.
