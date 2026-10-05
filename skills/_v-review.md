# V Review

Shared review rules for audit, verification, and refactor skills.

<!-- runtime -->
## Section Index

| Section | Purpose |
|---------|---------|
| FINDING_FORMAT | Markdown finding template (all fields required) |
| FINDING_FORMAT_JSON | JSON finding structure for prompt generation pipeline |
| Confidence Calibration | high/medium/low definitions and evidence standards |
| Finding Deduplication Protocol | Fingerprinting and merge rules for cross-tool findings |
| Review Rules | Core review principles (evidence, confidence, dedup) |
| Agent Dispatch Protocol | Rules for dispatching review agents + mandatory fallback |
| Agent Dispatch Verification Gate | Three valid outcomes: DISPATCHED, SKIPPED-GRACEFULLY, NOT-APPLICABLE |
| Adversarial Reviewer Output Contract | Prompt suffix for controlling agent output format |
| Hostile-Context Input Contract | Required preamble before agent dispatch (focuses review on diff's risk surface) |
| Quorum Reviewer Dispatch | Not implemented — single-reviewer path (codex + superpowers fallback + ORCHESTRATOR_INLINE) is the operative protocol |
| Required AGENT_REVIEW Artifact Format | Hook-enforced structural rules for AGENT_REVIEW artifacts (H2 headers, Model line, provenance fields) |

## FINDING_FORMAT

```markdown
#### FND-001: [Issue Title]
file: [path:line]
type: [security | performance | growth | ux | test-coverage | accessibility | seo | docs | tech-debt | completeness | other]
severity: [critical | high | medium | low]
confidence: [high | medium | low]
issue: |
  ...
evidence: |
  ...
fix: |
  ...
verification: |
  ...
```

## FINDING_FORMAT_JSON

When a skill outputs JSON (e.g., `v-check --json`, specialist audit skills), findings MUST use this structure to be compatible with the built-in prompt generation pipeline:

```json
{
  "id": "SEC-001",
  "priority": "P0|P1|P2|P3",
  "category": "security|performance|growth|ux|test-coverage|accessibility|seo|docs|tech-debt|completeness|other",
  "title": "Short descriptive title",
  "description": "Detailed description of the issue",
  "severity": "critical|high|medium|low",
  "confidence": "high|medium|low",
  "files_affected": [
    {"path": "relative/path/to/file.php", "lines": [42, 43, 44]}
  ],
  "test_first": "Description of test to write before fixing (TDD)",
  "implementation": {
    "approach": "How to fix this",
    "changes": ["Step 1", "Step 2"]
  },
  "verification": "How to verify the fix works",
  "effort_hours": 0.5
}
```

**Mapping from Markdown FINDING_FORMAT to JSON:**
| Markdown Field | JSON Field |
|---------------|------------|
| `#### FND-001:` | `id` + `title` |
| `severity:` | `severity` + maps to `priority` (critical→P0, high→P1, medium→P2, low→P3) |
| `confidence:` | `confidence` |
| `file:` | `files_affected[0].path` + `.lines` |
| `type:` | `category` |
| `issue:` | `description` |
| `fix:` | `implementation.approach` + `.changes` |
| `verification:` | `verification` |

Skills that produce only Markdown findings can be converted to JSON using this mapping. The audit skills' built-in prompt generation consumes this JSON format to generate parallelized implementation prompts.

## Severity Scale (AGENT_REVIEW — parsed, do not rename)

Findings use `severity: critical|high|medium|low` — the AGENT_REVIEW scale is FROZEN by the Stop hook's anti-rubber-stamp parser (`~/.claude/hooks/lib/validation.sh` `validate_review_semantics`: CRITICAL/HIGH = must-resolve). It maps 1:1 to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md` (critical=P0, high=P1, medium=P2, low=P3); render these words in review artifacts and map to P-levels only at consolidation.

## Confidence Calibration

All findings using `confidence: high|medium|low` MUST follow these definitions:

| Level | Definition | Evidence Standard |
|-------|-----------|-------------------|
| **high** | Verified by code path tracing — the issue was confirmed by reading the actual execution path, running the code, or observing the behavior | Exact file:line reference with proof of the issue |
| **medium** | Pattern match or heuristic — the issue is likely based on a recognized anti-pattern, missing guard, or structural analysis, but was not traced through execution | File:line reference with pattern description |
| **low** | Inferred from absence — the issue is suspected because expected code, test, or configuration was not found, but no direct evidence of a bug exists | Description of what was searched for and not found |

Skills MUST NOT assign `confidence: high` to findings based solely on pattern matching. If a finding was not verified by tracing the actual code path or observing the behavior, it is `medium` at best.

## Finding Deduplication Protocol

When multiple skills or agents audit the same codebase (e.g., v-check + specialist audits + agent review), duplicate findings are common. Use this fingerprinting protocol to detect and merge them.

**Fingerprint:** `file_path:line_number:category` (e.g., `app/Http/Controllers/AuthController.php:42:security`). Two findings with the same fingerprint are duplicates.

**Deduplication rules:**
1. Before adding a finding to a report, compute its fingerprint and check against existing findings in the current report.
2. If a duplicate exists, merge: keep the higher priority, higher confidence, and more specific description. Append `deduplicated_from: [original_finding_id]` to the surviving finding.
3. If merging across reports (e.g., consolidating v-check + agent review), the main report's finding is the "surviving" entry. Agent findings that duplicate it are noted as corroboration: `corroborated_by: [agent_finding_id]`. Corroboration elevates confidence by one level (low→medium, medium→high) but does not change priority.

   **Independence condition — corroboration only counts if the evidence is independent.**
   Two reviewers reading the same file, sampling the same pages, or extrapolating from the
   same subset are one observation, not two. Elevate confidence ONLY when the corroborating
   finding cites a *different* evidence source: a different file, a different sample, an
   executed command versus a static read, or a primary doc versus an inference.
   Otherwise record `corroborated_by` and leave confidence unchanged.

   Measured failure this prevents (2026-08-09): two subagents each extrapolated a corpus-wide
   count from the same 2 sampled items, corroborated each other, were promoted to `medium`,
   and reported ~40 instances. A full-corpus scan found **6**. Same evidence counted twice
   produced a 6.7× overstatement that reached the user as fact.
4. Line-range tolerance: findings within ±3 lines of each other in the same file and category are considered duplicates.
5. Log all deduplication decisions: `dedup: merged [FND-X] into [FND-Y], reason: same fingerprint` in the report's metadata or a `## Deduplication Log` section.

## Review Rules

1. Evidence is required.
2. A heuristic hit alone is not a critical finding.
3. Low-confidence findings are advisory only.
4. When a gap maps to a dedicated Tier 1 skill, recommend that skill rather than redefining its workflow inline.
5. Domain-prefixed finding IDs (`SEC-001`, `MOD-001`, `DOC-001`, etc.) are allowed as specializations of `FINDING_FORMAT` when they improve readability, but they must keep all required fields, including `confidence`.
6. **Cross-audit priority resolution:** When multiple audit tools (v-check, specialist audits, agent review) produce findings for the same file:line, use the HIGHEST priority (P0 > P1 > P2 > P3). A single P0 from any source makes the merged finding P0. If the finding descriptions conflict, prefer the one with `confidence: high`. If both are `confidence: high`, the more specific finding (narrower scope) wins.
7. **Deduplication is mandatory.** Every report that consolidates findings from multiple sources MUST run the deduplication protocol above before writing the final artifact.
8. **User-owned maintenance scope leakage is always review-worthy.** For tasks governed by `references/v-core-maintenance.md`, touching forbidden roots (`.codex`, plugin cache, plugin marketplaces, or mirror files before canonical files) is at least a medium-severity finding and becomes high severity when the edit weakens review, gate, or sync behavior.
9. **Lower ceremony is not a waiver.** If a maintenance workflow removes targeted tests, hostile review, or final verification in the name of speed, review it as a regression rather than an optimization.

## Agent Dispatch Protocol

Review-oriented skills dispatch specialized agents for parallel analysis when an agents directory exists.

**Fork-context callers:** skills that run `context: fork` (all `v-audit-*` specialists, `/v-check`, `/v` itself) CANNOT use the Agent tool — a subagent cannot dispatch another subagent (platform limit; the call fails silently). From a fork, dispatch named agents as independent `claude -p` subprocesses via `~/.claude/skills/v/references/v-dispatch-subagent.sh --agent <name>` instead. The rules below apply identically to both dispatch paths.

**Agent directory lookup order:** Check both paths and use whichever exists (project-level takes precedence):
1. `.claude/agents/` (project-level, relative to repo root)
2. `~/.claude/agents/` (global, user home directory)

Rules:
1. Select agents based on changed files or audit scope.
2. Use worktree isolation for post-implementation review when available.
3. Treat agent output as findings to merge into the final artifact, not as authority that overrides the skill rules.
4. If neither agents directory exists AND codex-adversarial-reviewer is not found: invoke `superpowers:requesting-code-review` via Skill tool as the FIRST-CHOICE fallback. **If that skill returns "Unknown skill" / is not installed**, do NOT loop — write the AGENT_REVIEW artifact directly with `Codex adversarial reviewer: skipped — file not found` and `Agents dispatched: none — superpowers:requesting-code-review not installed; orchestrator self-reviewed full diff` in the provenance fields, then conduct an inline orchestrator-side adversarial review on the full diff (read every changed file, look for security/correctness/perf issues), and write findings into the AGENT_REVIEW. NEVER skip review entirely.
5. External-model agents (e.g., `codex-adversarial-reviewer`): **dispatch is mandatory when the agent file is found** in either agents directory. If the underlying CLI tool (e.g., `codex`) is unavailable, record `agent_dispatch: skipped, reason: cli_unavailable` and try `superpowers:requesting-code-review` via Skill tool. **If that skill is also not installed (returns "Unknown skill"), fall through to inline orchestrator-side adversarial review** on the full diff per rule 4 above. The review requirement never downgrades to optional, but the path adapts to what's actually available. Document the adaptation in the AGENT_REVIEW provenance fields.
5a. **Model for review agents (W13 tiered routing):**
    - **codex-adversarial-reviewer (Agent tool dispatch):** model resolved by `resolve_review_model()` in /v § Review Model Tiering — `sonnet` floor AND cap (2026-07-07 sonnet-max decision: reviews run ONLY on sonnet/haiku; billing/payment stays a non-overridable sonnet risk gate — V_REVIEW_TIER=haiku cannot down-tier it).
    - **superpowers:requesting-code-review (Skill tool fallback):** runs INLINE on the session model (typically `sonnet`), NOT haiku. The Skill tool does not fork — it executes in the orchestrator's conversation. This is intentionally higher-quality than the codex haiku path.
    - **ORCHESTRATOR_INLINE (last-resort fallback):** the orchestrator (sonnet) reads the diff and conducts the review itself. Same model as superpowers fallback.
    - **Prior claim** that haiku-dispatched agents catch identical vulnerability classes as opus-dispatched ones is uncorroborated by Wave 11 evidence (5 sessions, 5 LOW findings total). The W13 tiering (as amended 2026-07-07 sonnet-max) runs everything on sonnet — billing/auth keep a non-overridable sonnet risk gate so the haiku cost dial can never shallow the reviews that materially hurt.
6. Findings from external-model agents inherit `confidence: low` by default. The dispatching skill may escalate confidence only after independent verification.
6a. **Per-agent timeout:** Each dispatched agent has a 5-minute wall-clock timeout. If an agent exceeds this, terminate it and log `agent_timeout: [agent_name], partial_findings: [count]`. Partial findings are still merged (they already inherit `confidence: low`).
6b. **Contradictory findings resolution:** When two agents produce findings that contradict each other (e.g., Agent A says "add index" and Agent B says "remove index" on the same table), the dispatching skill MUST: (1) log both findings with their sources, (2) independently verify which is correct by reading the relevant code, (3) ACCEPT the verified finding and REJECT the other with reason `contradicted_by: [finding_id]`.
7. When using `codex-adversarial-reviewer`, follow `.claude/agents/codex-adversarial-reviewer.md` for capability detection, timeout handling, and fallback behavior.
8. **Report ALL severity levels** (critical, high, medium, low). Do NOT filter to only critical/high — medium and low findings prevent tech debt accumulation and quality erosion over time.
9. **Fix everything valid.** The adjudication step has three verdicts only: ACCEPT (valid → fix now), MODIFY (partially valid → fix with adjustments now), REJECT (false positive → skip with reason). There is no DEFER verdict. If Claude independently verifies a finding is valid, it gets fixed in this session — no exceptions. Deferring valid findings is how tech debt accumulates. No DEFER verdict. If a finding is genuinely invalid (false positive), REJECT it with concrete proof per rule 10 — but when in doubt, ACCEPT the conservative fix.
10. **REJECT requires proof, not opinion.** A REJECT verdict is only valid when you can cite concrete evidence that the finding is factually wrong — a test proving the behavior is correct, a code trace showing the issue cannot occur, or a framework guarantee that makes the concern impossible. "I disagree with the approach" or "I think this is fine" are NOT valid REJECT reasons. When in doubt, ACCEPT and fix — the cost of an unnecessary fix is always lower than shipping a real bug. This matters because the AI review is the ONLY safety net; no human reviews this code.
11. **Fix with code, not documentation.** When a finding identifies a missing test, write the test. When it identifies a bug, fix the code. When it identifies a missing validation, add the validation. Writing a markdown document, code comment, or text explanation of why the code is already correct does NOT count as fixing a code-level finding. The reviewer will reject documentation-only "fixes" and re-raise the finding, wasting a review cycle.
12. **Recurring issue escalation.** If cycle 2 of the review finds the same issue as cycle 1 (same file, same category, same description), the fix attempt failed. Do NOT attempt a third fix with a different approach — instead, stop and report the specific issue to the user with both attempted fixes and why they didn't resolve it. Continuing to loop on the same unfixable issue wastes tokens and context without progress.

### Agent Dispatch Verification Gate

Before completing any review-oriented skill, verify agent dispatch occurred. Four outcomes:

| Outcome | Condition | Action |
|---------|-----------|--------|
| **DISPATCHED** | Agent file found, CLI available, agent ran | Merge findings into report |
| **SKIPPED-GRACEFULLY** | Agent file found, CLI unavailable | Log `agent_dispatch: skipped, reason: cli_unavailable`. Try `superpowers:requesting-code-review` via Skill tool. If that returns "Unknown skill" → fall through to ORCHESTRATOR_INLINE. |
| **NOT-APPLICABLE** | Agent file not found in either directory | Log `agent_dispatch: not_applicable`. Try `superpowers:requesting-code-review`. If that returns "Unknown skill" → fall through to ORCHESTRATOR_INLINE. |
| **ORCHESTRATOR_INLINE** | Both codex and superpowers unavailable | Orchestrator conducts inline adversarial review on the full diff. Reads every changed file, looks for security/correctness/perf issues, writes findings into AGENT_REVIEW. Provenance fields document the fallback chain. |

**Enforcement:** If the review skill completes without one of these four logged outcomes, the review is incomplete. The dispatching skill MUST include `agent_dispatch_outcome` in its output artifact.

**W5F-6 — unavailability claims need EVIDENCE, and parallel load needs a RETRY (forensic 2026-06-06):** all five wave-1 pack sessions (running 12-way parallel) declared "codex/superpowers unavailable" and reviewed inline, while codex demonstrably worked on the same host hours earlier — zero failure output was captured anywhere. Two binding rules:
1. **Capture the failing attempt verbatim.** An ORCHESTRATOR_INLINE AGENT_REVIEW must quote the actual failure (the codex CLI error line / exit code, and the superpowers "Unknown skill" response) in its provenance fields — not just assert unavailability. The Stop hook accepts a declared-inline review only when its superpowers line states an attempt OUTCOME (attempted / returned / failed / not installed / unknown skill / timed out / rc=N); a bare mention is treated as a skipped chain.
2. **Under parallel sessions, transient codex failure ≠ unavailable.** If the codex CLI errors with a resource/transport-class failure (timeout, 429/5xx, EAGAIN, lock contention) while sibling /v sessions are active, RETRY ONCE after 30–60s before falling back. Concurrent siblings contending for one codex CLI is the expected cause; an immediate inline fallback across a whole wave removes independent review from every pack at once.
3. **W5G/M-5 — capture codex output to a FILE, never through a truncating pipe.** Run `codex exec … > "$V_TMP_DIR/codex-review-$SID.out" 2>&1` and read/summarize from that file. A production session piped codex through `head -60`: every finding beyond the diff echo was silently LOST, and the AGENT_REVIEW had to declare "output partially captured". A review whose findings were truncated is not a completed review — if the capture file is missing or truncated, the codex outcome is `incomplete` (re-run it), never `ran`.

**CRITICAL: No code ships without review.** No humans review this code — the AI review (codex, superpowers, or orchestrator-inline) is the ONLY safety net. Every session that modifies code MUST hit one of the four outcomes above. "I skipped review because codex wasn't available" is a bug — there is always a fallback path that DOES land. Sessions where `superpowers:requesting-code-review` returns "Unknown skill" must NOT loop on it; they must fall through to ORCHESTRATOR_INLINE on the first failure.

**Production observation (two production sessions):** `superpowers:requesting-code-review` is referenced as a fallback but is not installed in many environments. Sessions that hit this without the ORCHESTRATOR_INLINE path documented above wasted ~30-50k tokens looping on stop-hook rewrites until they discovered the right framing manually. The four-outcome table above prevents the loop.

### Adversarial Reviewer Output Contract

When dispatching the `codex-adversarial-reviewer` agent, use this prompt suffix to control output format:

```
Report ALL findings at every severity level (critical, high, medium, low).
Format each finding as:
  severity: [critical|high|medium|low]
  file: [path:line]
  category: [security|performance|growth|ux|test-coverage|accessibility|seo|docs|tech-debt|completeness|other]
  issue: [description]
  fix: [recommended change]
Do NOT limit output length. Report every finding found.
```

This replaces any older "CRITICAL and HIGH only, max 20 lines" constraint. The full finding set is adjudicated: valid findings are fixed immediately, false positives are rejected with documented reasons. No findings are deferred.

## Hostile-Context Input Contract

The Adversarial Reviewer Output Contract above controls what the agent produces. This section controls what the agent receives — specifically, the preamble that focuses adversarial analysis on the diff's actual risk surface.

**When dispatching codex-adversarial-reviewer or `superpowers:requesting-code-review`, the dispatch prompt MUST include a 3–5 line hostile-context preamble BEFORE the diff.** Without it, the reviewer catches generic patterns but misses domain-specific risks.

**Required preamble structure:**
```
HOSTILE CONTEXT for this review:
- Domain: <what the diff touches: billing / auth / data deletion / multi-tenant / file upload / external API / etc.>
- Risk surface: <specific failure modes — race conditions, PII exposure, unscoped queries, webhook idempotency, etc.>
- Edge cases I considered: <what you already thought through>
- What I'm worried about: <the specific concerns that kept you up while implementing>
- Adversarial focus: <if auth/payment/data deletion: name it explicitly so the reviewer enters hostile mode>
```

**The orchestrator (`/v` SKILL.md Step 5) generates this preamble from in-context state.** It is not optional — the orchestrator's contract block requires it before any review-agent dispatch.

**Multi-domain diffs:** if the change touches multiple domains (e.g., billing AND auth), include both with separate Risk surface lines. Do not collapse to a single domain.

**Cost/value:** ~200 tokens added per dispatch. Surfaces domain-specific findings the reviewer would otherwise miss. Strongest impact on diffs touching auth, payments, data deletion, file upload, or external APIs — exactly the surface where shipped bugs are most expensive.

**Anti-pattern:** dispatching a bare diff with no preamble. Generic adversarial review will produce generic findings; the diff's domain risk surface will go unreviewed.

## Critic Dispatch Protocol

**When skills use this:** apply when a skill needs adversarial review of its primary output before downstream consumption. Current consumers: `v-audit-messaging` Step 2.6, `v-audit-seo` Step 2.5 (added 2026-08-10, runs at ALL depths including Quick — not gated to Standard/Thorough like this skill's other own steps), `v-content-create` Step 13, `v-pricing-design` Step 6.5, `v-differentiate` § Critic Step.

**Skip rule (identical across all consumers):** skip critic dispatch ONLY when `V_DEPTH ≥ 1` (orchestrator owns post-output review), `HEADLESS_BATCH=1`, `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`, or `--no-critic` flag is set. In skip cases, log `critic_review: skipped — reason=<flag>` in the output metadata and proceed. Skipping silently is not allowed.

**Why critic dispatch:** the output produced through the prior steps is the result of the SAME AI's reasoning at every gate (persona engagement, variance generation, output grading). A critic from a different dispatch catches blind spots the producer cannot see by self-review. Dispatch a fork-safe `claude -p` subprocess (`~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode capture` — sonnet per the 2026-08-02 critic-tier decision: finding-extraction quality matters more than the haiku cost delta, and this keeps the critic at the same tier as the codex-adversarial-reviewer primary it stands in for; fork-context skills cannot use the Agent tool) with adversarial focus per § Agent Dispatch Protocol:

- Primary: `codex-adversarial-reviewer` if `.claude/agents/codex-adversarial-reviewer.md` exists in the project OR `~/.claude/agents/`
- Fallback: `superpowers:requesting-code-review` skill via Skill tool dispatch
- Last resort: generic `--model sonnet` subprocess dispatch (no `--agent`) with the adversarial prompt below

**Verbatim prompt template** (consuming skill substitutes `{ROLE_TITLE}`, `{ROLE_EXPERIENCE}`, `{FIND_ITEMS}` — everything else is verbatim):

```
You are a {ROLE_TITLE} with adversarial mindset — {ROLE_EXPERIENCE}. Your job is NOT to be helpful — it is to actively try to break the output, probe edge cases, question architectural decisions, and surface what the producer's self-review missed.

Read: <artifact-path> + any sibling spec/benchmark artifacts in the same SID-qualified set.

Find:
{FIND_ITEMS}

Output format: 3-5 findings, each as JSON:
{
  "severity": "P0|P1|P2|P3",
  "finding": "specific issue, named in concrete terms",
  "evidence": "exact quote from the artifact OR specific reasoning chain",
  "suggested_fix": "concrete intervention",
  "confidence": "high|medium|low"
}

If after honest review zero issues exist, return `findings: []` with metadata `review_outcome: clean`. Do NOT fabricate concerns to meet a quota — fabricated noise pollutes adjudication. Only record findings you can defend with concrete evidence.
```

**Adjudication (identical across all consumers):**

For each critic finding:
- **ACCEPT** → fix the issue NOW (re-task the relevant earlier step), then re-run output grading on the fixed output, then proceed
- **MODIFY** → apply the suggested fix with adjustments documented inline
- **REJECT** → document the reason ("we considered this in Step X — explicit choice because Y")

No DEFER. If ≥1 ACCEPT/MODIFY: complete the fix loop, then re-dispatch the critic ONCE for cycle 2 (regression check on fixes).

**Global mutation-pass cap:** across all gates in the consuming skill (variance re-task + grading re-task + critic adjudication), maximum 4 total content-mutation passes per session. On the 5th proposed mutation, ship as-is and log `gate_chain_capped: true` in output metadata to prevent infinite ping-pong between gates. Cap at 2 critic cycles total — if cycle 2 produces ≥1 ACCEPT findings, log `critic_review: contested` in output metadata and ship with prominent banner ("adversarial review surfaced unresolved concerns: [list]").

If 0 ACCEPT/MODIFY findings: log critique under `## Adversarial review` in the output and proceed to the consuming skill's next step.

## Quorum Reviewer Dispatch — Not Implemented

The orchestrator does not currently dispatch multiple parallel reviewers with majority voting. The Agent Dispatch Protocol above is the operative review path: single `codex-adversarial-reviewer` with `superpowers:requesting-code-review` as mandatory first-choice fallback, and ORCHESTRATOR_INLINE as last-resort fallback when both are unavailable. See the four-outcome verification gate above.

This section anchor exists so cross-references from older docs that mention "quorum reviewer" resolve cleanly. When other shared modules say "escalate to quorum reviewer for ambiguous calls", read that as: apply the documented sensible default per `_v-resilience.md` § Documented fallback paths, and if the situation is genuinely ambiguous, write a `BLOCKED_<sid>.md` artifact and continue with the conservative path.

If multi-reviewer voting becomes operationally necessary (recurring class of ambiguous-judgment cases that the single-reviewer path keeps getting wrong), it should be designed and shipped as a versioned change to this protocol. There is no plan-of-record for it today.

## Required AGENT_REVIEW Artifact Format

(Canonical: `_v-artifact-formats.md`. Runtime rules below — hook source: `~/.claude/hooks/lib/validation.sh`.)

**Required structural rules:**

1. `Model: sonnet` within first 5 lines (the format validator's allowlist is haiku|sonnet|opus|fable — state the model the review ACTUALLY ran on, never a copied literal). **This allowlist is deliberately broader than the dispatch-time policy cap and does NOT enforce model choice.** The validator only checks artifact SHAPE (a parseable literal in the field); the sonnet-floor-and-cap decision (§ Agent Dispatch Protocol 5a above, non-overridable) is enforced separately, at the dispatch chokepoint (`v-dispatch-subagent.sh`'s `enforce_model_policy()`), not by this parser. In current practice `Reviewer model:` should only ever read `sonnet` or `haiku` — an `opus`/`fable` value that passes this validator is a signal of an upstream POLICY violation, not a passing state; do not read "the validator accepts it" as "it's allowed."
2. H2 header matching `^##[[:space:]]+(Findings|Review)$`. Exact match. NOT `### Findings` (H3), NOT `## Finding 1:` (numbered separate H2s). One container H2; findings nested as H3/H4.
3. All severity levels reported (critical, high, medium, low) — no filtering.
4. Each finding follows compact `FINDING_FORMAT` (single pipe-delimited header line + fix: + verify: lines).
5. **Provenance H2 with all 8 fields, literal field names** (hooks check by name):
   - `Status: completed | pass | passed`
   - `Agents dispatched: <list>` (or `none — superpowers:requesting-code-review not installed; orchestrator self-reviewed full diff`)
   - `Codex adversarial reviewer: <ran — N candidates, N accepted, N rejected | superpowers fallback | skipped — file not found | orchestrator-inline>`
   - `Reviewer model: <haiku | sonnet | opus>` (W13 — actual model the review ran on)
   - `Hostile adversarial focus: <yes — diff touches: <paths> | no>`
   - `Dispatch mode: <background | foreground>`
   - `Review evidence: <codex_candidates:N findings:N-ACCEPT,N-REJECT | No issues found | ORCHESTRATOR_INLINE: full-diff review>`
   - `Remediation: <N fixed re-verified | no findings>`

### Required template (copy verbatim; fill values; provenance field names are LITERAL hook-checked strings)

**Canonical form (matches /v SKILL.md Step 5 § Required artifact — single source of truth):**

```
Model: sonnet

## Agent Review — <session_id>
- Status: completed
- Agents directory: ~/.claude/agents
- Agents dispatched: codex-adversarial-reviewer
- Codex adversarial reviewer: ran — 5 candidates, 3 accepted, 2 rejected
- Reviewer model: sonnet
- Hostile adversarial focus: yes — diff touches: billing,cashier
- Dispatch mode: background
- Review evidence: codex_candidates:5 findings:3-ACCEPT,2-REJECT
- Remediation: 3 fixed re-verified

## Findings

#### FND-001 | app/Http/Controllers/BillingController.php:42 | performance | high | high
N+1 on $user->subscriptions inside foreach (line 38).
fix: ->load('subscriptions','subscriptions.items') before foreach.
verify: php artisan test tests/Feature/BillingDashboardTest.php; DB::getQueryLog() ≤2 queries.

#### FND-002 | <file:line> | <type> | <severity> | <confidence>
<one-line issue>
fix: <one-line fix>
verify: <one-line verification>

## Adjudication
FND-001 ACCEPT commit:abc123
FND-002 MODIFY commit:def456
FND-003 REJECT proof:app/Http/Requests/StoreUser.php:18-validates-upstream
```

**FND-18 reconciliation note:** Earlier versions of this file used `## Provenance` H2 with bare (non-dash-prefixed) `Status: completed` lines. /v SKILL.md uses `## Agent Review — <sid>` with dash-prefixed `- Status: completed` lines. Both forms have been observed in production AGENT_REVIEW artifacts, suggesting the validator accepts either. The W12-2 Post-Dispatch Wrap rule and the W13 `Reviewer model:` field are documented in the dash-prefixed form, so that is now the canonical template here too. If you find divergent old artifacts, they are valid — but new writes should use the canonical form above.

Required H2s: `## Agent Review — <session_id>`, `## Findings` (or `## Review`), `## Adjudication`.

### ⛔ STOP — Final Pre-Write Verification for AGENT_REVIEW (READ LAST)

Mentally grep your draft:

1. `head -5 draft | grep -cE '^Model: (haiku|sonnet)'` → ≥1
2. `grep -cE '^##[[:space:]]+(Findings|Review)$' draft` → ≥1 (NOT `### Findings`, NOT `## Finding 1:`)
3. `grep -cE '^- (Status|Agents dispatched|Codex adversarial reviewer|Reviewer model|Hostile adversarial focus|Dispatch mode|Review evidence|Remediation):' draft` → ≥8 (W13: Reviewer model required)
4. ALL severity levels reported (no filtering to critical/high only)
5. `grep -ic 'self-review (degraded)' draft` → 0 (degraded-self-review language is hook-rejected)

If codex AND superpowers are unavailable: use `Codex adversarial reviewer: orchestrator-inline (codex unavailable, superpowers not installed)` and conduct a real full-diff review. Don't loop on `superpowers:requesting-code-review` "Unknown skill" returns — fall through to ORCHESTRATOR_INLINE on first failure.

If any check fails: fix draft, re-verify, THEN Write. First-write cost: ~0 extra tokens. Loop cost: ~30-80k tokens per cycle at the critic tier — now sonnet, so the retry loop is materially more expensive than when this was measured on haiku (4 of 5 production sessions hit this). Get the draft right on the first write.

<!-- end-runtime -->
