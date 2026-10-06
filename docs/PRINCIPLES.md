# Operating Principles for My AI Coding Agents

[README](../README.md) · [Architecture](../ARCHITECTURE.md) · [AI security](AI-SECURITY.md) · Terms such as orchestrator, hook and gauntlet are defined in the [README](../README.md#how-it-works).

These are the standing instructions my AI coding agents follow on the products I build myself.
There's no other person on the team, so the agents plan, build, test and review the work, and I
decide what gets pushed and deployed.

> [!IMPORTANT]
> **The agents are told to treat the automated review layer as the only safety net.** That
> constraint shaped everything below. In practice, I don't read most of the code the agents merge,
> and I decide what gets pushed and deployed. The instruction is there so the automated layer never
> counts on me to catch what it missed.

Most of these rules started as softer versions that failed the same way: the instruction existed,
the agent agreed with it, and then violated it. The fix was to turn each one into a check. Some
checks run in code: the destructive-command, pull-request and dependency guards, the risk tiers,
model tiering, and the convention scan for `TODO`s and hardcoded keys. The rest, including the
evidence contract in section 2, remain instructions that reviewers check.

## 1. Act, then report, except for an ask-first list

The default is autonomy. The agent makes implementation decisions (UI placement, edge cases,
error handling) from established codebase patterns and reports afterwards.

When the request is ambiguous, the agent resolves it in a fixed order: (1) the project's stated
goals, (2) the existing codebase pattern, (3) the simpler-but-complete interpretation. It must
**state the interpretation it chose in its first sentence**. It never picks one silently.

It pauses only for this ask-first list:

| Situation | Action |
|---|---|
| Destructive operations (drop table, delete data, force push) | Require explicit approval |
| Security-sensitive changes (auth, encryption, tokens, payments) | Explain implications first |
| Breaking API or interface changes | Document the migration path |
| Removing functionality | Confirm it is intentional |
| Tests still failing after 3 fix attempts | Revert to last good state and ask |

Outward-facing actions are opt-in. Outside the orchestrator the agent never commits on its own;
orchestrated sessions commit to their own branch and merge back to my local `main`, and pushing and
deploying stay my call. No pull requests unless explicitly asked.
"Push" or "ship" means push, never "open a PR".

## 2. The evidence and completeness contract

*"Never claim completion without evidence"* was in the instructions and was still violated.
Vague virtues don't bind. These checkable rules replaced it:

1. **Prove the set before analyzing it.** For any "review / audit / fix ALL X", enumerate X from the
   root of its own tree, not from an assumed path pattern, and say how you enumerated it. A pattern
   that finds *some* X is the most common way a review silently covers half the surface. Re-run the
   discovery from a second angle before claiming coverage.
2. **Never characterize what you have not opened.** Filenames and descriptions support "this
   exists", never "this is correct" or "this is safe". Mark load-bearing claims as *verified*,
   *inferred* or *unchecked*. Extrapolating from a sample requires saying so and giving n.
3. **Never truncate a verification.** No `| head`, `| tail` or `| grep` between a test run and its
   verdict: a pipeline's exit code is the *last* command's, not the test runner's. Capture full
   output to a file and read the counts from the file.
4. **Close with the negative, unprompted.** End substantive work with what was *not* done: scope
   skipped, claims unverified, decisions deferred. When the work spans several evidence sources,
   state coverage per source (fully read / sampled n of N / not opened). **A delegated agent's
   coverage is not yours.** A sub-agent's sampling is a finding to report, not a scope to inherit.
5. **Ground-truth before presenting, not after the reader reacts.** Run the query that could
   falsify the claim while drafting. A finding walked back one turn later should never have been
   sent. A number from a sub-agent is unverified until re-derived. Relaying it is authoring it.
6. **Use the best specialist.** Check the registry of specialist agents before dispatching. The
   general-purpose agent is a fallback, not a default.
7. **A negative claim needs a source that *could* have shown the positive.** Before writing "there
   were no X" or "that is unmeasurable", name the source checked *and* why it would contain X if X
   existed. Then ask: *what other artifact would record this?* In one analysis a cost was declared
   unrecoverable because one telemetry log didn't carry it. The session transcripts carried it in
   full, and the recovered figure reversed the report's conclusion.
8. **A parity claim requires reading both sides, item by item.** "A mirrors B" means B was read in
   full and the correspondence enumerated. One exemption shipped documented as mirroring a gate
   runner's detection logic after its author had read 3 of the runner's 8 guards. The 5 missing
   triggers failed in the *unsafe* direction. Where a mirror is load-bearing, encode it as a test
   that fails on drift.

## 3. Verification proportional to risk

Ceremony that doesn't scale with risk gets skipped or argued around, so verification is tiered:

| Change | Verification |
|---|---|
| Docs, copy, config values | Relevant linter/build only |
| Small code (≤ ~30 lines, ≤ 3 files, no high-risk path) | Targeted tests, scoped lint, one review pass |
| Ordinary code (4–10 files, no high-risk path) | Targeted tests while iterating, full suite once at the end, one adversarial review |
| High-risk paths (auth, payments, encryption/signatures/webhooks, migrations, public API contracts) or 11+ files | The full orchestrated pipeline |

This table decides whether the orchestrator runs at all. It also runs when I ask for it and for
every prompt pack, whatever its size. Path detection has limits: the tier classifiers catch auth,
payments, cryptography, webhooks and credentials by pattern, but not public API routes or
authorization policies, so a small route change can still qualify for the light tier
([details](../ARCHITECTURE.md#1-risk-tiers-computed-from-the-diff)).

Inside the orchestrator, a separate set of light and medium tiers is **derived from the diff by the
enforcement hooks themselves** and cannot be asserted by the agent. An agent that wants less ceremony has to make a smaller change, not argue
that its change is small.

Two related rules:
- During red-green iteration, run **only the changed tests**. The full suite runs once, at the end.
- A full-suite run that a tool timeout truncated is a failed gate, not a partial pass.

## 4. Measure the system, not just the product

Instrument the orchestrator itself, not just the product it builds, and put that analysis through
the same adversarial review as your code. Measuring mine showed that the orchestrator, not the
review gates, was where the money went, so I made it opt-in for high-risk or large changes. The
analysis had a bug of its own: it double-counted dispatch spend until a five-lens adversarial
review panel caught it. The numbers are in the [README](../README.md#results).

## 5. Model tiering, enforced rather than declared

| Work | Model tier |
|---|---|
| Mechanical runners: execute gates and report (tests, lint, build, audits) | Smallest, fastest model |
| Anything that renders judgment on code or UX (all reviewers) | Mid-tier model, never the smallest |
| Any work, on the top-tier model | Only by my explicit per-session choice, never as a default or an escalation |

A `PreToolUse` hook enforces the tiering for the gate runners and for 7 of the 8 reviewer agents;
the UX critique reviewer still relies on its declared model. Two failures made that necessary:

- **The override bug.** The agent-dispatch API's `model` parameter *overrides* the model an agent
  declares for itself. One line of instructions told the orchestrator to pass the small model to
  reviewers, so reviewers were repeatedly dispatched on the smallest model while their own
  definitions declared the mid-tier. The definition declared one model, the call passed another, and
  the call wins, so the rule is enforced where the call is made.
- **Instruction versus enforcement.** The instructions said to run the gates through the Skill tool,
  which runs inline on the session's model, and the tiering hook denies exactly that call. For months, nearly every session that ran the gates burned a round
  obeying the instructions and being denied. When the documentation and the enforcement disagree,
  every session pays the difference.

## 6. Review as if it were the only safety net

- Every product-code change gets an adversarial review before it is called done. Reviewers are
  selected by what changed (logic, security, codebase fit, framework pitfalls), and the
  framework-pitfall reviewer is dispatched only for the diff shapes it actually covers.
- Security, payment and data-deletion code gets a **hostile** review: input-validation gaps, race
  conditions, authorization bypasses, failure modes. All critical and high findings are fixed
  before completion.
- Reviewer findings are refuted or confirmed by a second pass before they count.
- Assertions are never deleted or weakened to make tests pass: fix the code, or document why the
  test was wrong.
- No `TODO` / `FIXME` / `HACK` in delivered code.

## 7. Production defaults

<details>
<summary><b>Baseline engineering standards (not agent-specific)</b></summary>

Every feature ships with:

- **Graceful degradation:** partial data > cached fallback > empty state > error page. Never a raw
  exception to a user.
- **Structured logging** with context (user, action, duration, IP), and never sensitive values,
  even at debug level.
- **Bounded queries:** no N+1, no unbounded queries, enforced with eager loading and query-count
  assertions in tests.
- **Idempotent operations** where possible, transactions around multi-table writes, and
  server-side validation on every input.
- **Security baseline:**
  - Rate limits on every auth endpoint, and CSRF protection on every state-changing route.
  - File uploads validated server-side for type, size and extension.
  - Secrets only in environment configuration.
  - Untrusted HTML rendered only after allowlist sanitization.
- **Schema safety:**
  - New columns are nullable or defaulted, and foreign keys are constrained and indexed.
  - Destructive schema changes ship in two phases: stop using the column, then drop it next deploy.

</details>

## 8. Knowing when to hand off

Long agent sessions degrade. The agent writes a handoff document and asks for a fresh session when
any of these happen:

- It reads the same file three or more times.
- It proposes an approach that contradicts an earlier decision.
- It tries the same fix twice.
- It passes about 40 turns on a single feature.

The handoff records the branch, uncommitted changes, commands run and their outcomes, failing tests
with error excerpts, open decisions, and the next concrete steps.
