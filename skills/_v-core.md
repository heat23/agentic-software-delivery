# V Core

Shared contracts for all `v-*` skills. If an individual skill conflicts with this file, this file wins unless the skill explicitly narrows behavior for a safer outcome.

<!-- runtime -->
## Progressive Disclosure Rule

This file contains universally-needed rules that every skill requires. Specialized content has been extracted to `references/v-core-*.md` and `references/v-exec-*.md` files. **Only read reference files when the skill you're executing explicitly requires them.** Do not preemptively load all references — each skill's "Follow" directive lists which reference files it needs.

**Section index — find detailed content in reference files:**

| Section | Reference File |
|---------|---------------|
| Scope Passing (POLISH_SCOPE, CHECK_SCOPE) | `references/v-core-scope-passing.md` |
| Model Routing (Skill vs Agent tool, model selection) | `references/v-core-model-routing.md` |
| Changed File Detection (worktree-aware bash) | `references/v-core-changed-files.md` |
| Artifact Write Policy + Schemas + Expiration | `references/v-core-artifacts.md` |
| Cross-Session Learning | `references/v-core-cross-session.md` |
| Pre-existing Failure Baseline | `references/v-core-pre-existing.md` |
| Prompt Pack Contract | `references/v-core-prompt-pack.md` |
| Cost Awareness + Error Handling + Progress Reporting | `references/v-core-error-handling.md` |
| Skill Authoring Rules | `references/v-core-skill-authoring.md` |
| Volatile Knowledge Rules | `references/v-core-volatile-knowledge.md` |
| Owner-Managed Infrastructure | `references/v-core-owner-managed.md` |
| User-Owned Maintenance Workflow | `references/v-core-maintenance.md` |
| Blog Content Storage Policy | `references/v-core-blog-storage.md` |
| Artifact Schemas (PLAN, AUDIT, AGENT_REVIEW, etc.) | `references/artifact-schemas.md` |
| Audit Domain Ownership (canonical owner per domain) | `references/v-core-audit-ownership.md` |
| Finding Enrichment Contract (patch, detection, complexity, hostile_counter) | `references/v-core-finding-enrichment.md` |
| Token Budgets (per-skill and per-workflow estimates) | `references/v-core-token-budgets.md` |

## Core Rule

Do not define shared plan schemas, shared artifact names, or shared finding formats inline in individual skills. Reference the shared modules.

Canonical shared anchors:
- `PLAN_SCHEMA` lives in `_v-core.md` and `references/artifact-schemas.md`.
- `Artifact Expiration Policy` lives in `references/v-core-artifacts.md`.
- `Scope Passing Mechanism` lives in `references/v-core-scope-passing.md`.
- Cost-aware skills should expose `estimated_tokens` and related cost fields in their contract blocks.

## Skill Boundary Contract

Every `orchestrator`, `entry-point`, `user-facing`, and `specialized` skill must include a `## Skill Boundaries` section with:
- `### Best fit`
- `### Use instead`
- `### Not for`

This is mandatory for routing clarity. Boundary guidance should name nearby skills when misrouting is likely.

For exact authoring rules, read `references/v-core-skill-authoring.md`.

## Skill Authoring Hygiene

`SKILL.md` bodies must stay structurally clean:
- frontmatter appears once, at the top
- no stray `model:` or `context:` remnants in the body
- no inline shell-artifact lines copied from generation/debugging
- no repeated large templates inline when a reference file is the better home

See `references/v-core-skill-authoring.md`.

## Audit Domain Ownership

When multiple skills touch the same audit domain (SEO, pricing, analytics, messaging), exactly one skill is the canonical owner. Non-owners operate as triage stubs or synthesis lenses — they do not produce implementation-ready findings for owned domains.

See `references/v-core-audit-ownership.md` for the full ownership table and delegation rules.

## Volatile Knowledge Contract

Time-sensitive external facts do not belong inline in workflow-heavy skill bodies.

If a skill depends on current benchmarks, deprecations, policy shifts, vendor-specific bot names, or current-year claims:
- move the facts into a dated reference file
- keep the skill body focused on workflow and judgment
- point the skill body at the dated reference instead of restating the facts

See `references/v-core-volatile-knowledge.md`.

## User-Owned Maintenance

When a task is explicitly about maintaining the local Claude/Codex setup in user-owned roots, follow `references/v-core-maintenance.md` for:
- allowed and forbidden paths
- canonical versus mirror skill ownership
- reduced-ceremony execution
- maintenance-specific hostile review focus

This workflow is intentionally lighter than product feature delivery, but it still requires targeted tests, hostile review, and final verification.

## Tier Glossary

Every `v-*` skill declares a **tier** in its contract. Use exactly these values:

| Tier | Meaning | Examples |
|------|---------|----------|
| **orchestrator** | Top-level router that dispatches to other skills. Only `/v` should use this. | `v` |
| **orchestration-primitive** | Core building-block skill invoked by the orchestrator (or other skills) as part of standard workflows. Not typically invoked standalone by users. | `v-build`, `v-check`, `v-polish`, `v-scaffold`, `v-setup-project` |
| **user-facing** | Designed for direct user invocation. Has its own entry-point questions and can operate standalone. | `v-plan`, `v-help`, `v-check` |
| **entry-point** | A user-facing skill that serves as an alternative entry point to the system (can substitute for `/v` in specific workflows). | `v-merge-all` |
| **specialized** | Domain-specific audit or analysis skill, typically invoked by the orchestrator or directly by the user. Produces structured reports. | `v-audit-growth`, `v-audit-analytics`, `v-audit-seo` |

**Rules:**
- Every SKILL.md contract block MUST include exactly one tier from this table.
- The linter (`v-skill-linter.test.ts`) validates tier values against this list.
- If a new tier is needed, add it here first, then update the linter's valid-tiers array.

## Orchestrator Contract (`/v`)

The `/v` skill is the top-level orchestrator. Its responsibilities are:

| Responsibility | Detail |
|---------------|--------|
| **Classification** | Route user request to the correct skill (plan, build, check, polish, ship, etc.) |
| **Context passing** | Pass user prompt, selected files, and any artifact references to the invoked skill |
| **Invocation ordering** | Enforce: plan → tdd (backend logic) → build → polish (scoped) → interface-design:critique (new UI) → check (scoped, Medium/Large) → pre-flight → agent review → verify-done → merge-back (Medium/Large) |
| **Artifact threading** | Pass output artifacts from one skill as input to the next (e.g., PLAN → v-build, AUDIT_REPORT → v-build) |
| **Scope detection** | Count changed files to determine Small/Medium/Large; set CHECK_SCOPE / POLISH_SCOPE |
| **Worktree decision** | Create worktree for Medium/Large features; skip for Small |
| **Depth 0** | Orchestrator runs at invocation depth 0; all invoked skills run at depth 1+ |

Other skills can rely on these behaviors when they say "return control to the orchestrator." If `/v` is not the invoker (user invoked the skill directly), the skill must handle these responsibilities itself.

## Sub-Skill Invocation Rule (Mandatory)

When any `v-*` skill says "run/invoke `/v-*`", invoke it via the proper tool — do NOT replicate inline. Each sub-skill carries gates, artifacts, and verification that can't be reproduced by hand.

**Tool routing:**

| Skill | Tool | Notes |
|---|---|---|
| `/v-pre-flight`, `/v-verify-done`, `/v-handoff` | Agent tool, `model:"haiku"` | Use Verbatim Dispatch Mechanism in `/v` SKILL.md Step 5 (extract canonical prompt from Appendix A via bash, sed-substitute, pass via Read tool). The legacy 'read sibling DISPATCH_PROMPT.md' pattern was deprecated in Wave 9 — sonnet paraphrases prompts loaded from separate files, dropping format requirements. NEVER Skill tool (60× cost). |
| `/v-build`, `/v-polish`, `/v-check`, `/v-tdd`, `/v-new-feature` | Skill tool | `/v-polish` accepts `POLISH_SCOPE`, `/v-check` accepts `CHECK_SCOPE` for changed-files-only mode. |

**Zero-skills is a failure state.** If session completes with no sub-skill invocations, it failed. Every implementation session minimum: `/v-pre-flight` + `/v-verify-done` (verify-done is mandatory and non-negotiable; orchestrators MUST run verify-done before declaring a session done). "None" / "did it manually" never acceptable.

**Pre-built plan sessions are NOT exempt** (7/9 sessions in 2026-03-17 analysis bypassed all gates because they treated "pre-built plan" as "skip everything" — single most common failure mode):
1. Worktree creation (if parallel sessions exist)
2. Implement
3. `/v-pre-flight` (DISPATCHED via `v-emit-prompt.sh`, not manual test/build/lint — and never the Skill tool, which `enforce-haiku-dispatch.sh` denies; see the dispatch table above)
4. Agent review (codex / superpowers / ORCHESTRATOR_INLINE per `_v-review.md`)
5. `/v-verify-done`

## Changed File Detection

Canonical worktree-aware changed-file detection lives in `references/v-core-changed-files.md`.

Minimum invariant:
- include committed worktree diff when inside a worktree
- include staged and unstaged changes
- include untracked files via `git ls-files --others --exclude-standard`
- deduplicate before handing the file list to `/v-pre-flight`, `/v-verify-done`, `/v-check`, `/v-polish`, or review agents

Do not inline a weaker `git diff --name-only HEAD` shortcut in individual skills. Reference the shared changed-file contract instead.

## Scoped Check Contract

Canonical scoped-audit behavior lives in `references/v-core-scope-passing.md`.

`/v-check` supports both `Standalone mode` and `scoped mode`:
- `Standalone mode` is for direct user invocation when the skill owns the full audit flow.
- `scoped mode` is for orchestrated changed-files-only audits on Medium/Large implementations.

When the orchestrator provides `CHECK_SCOPE`, `/v-check` must:
- skip entry-point questions that only exist for standalone discovery
- audit only the files in `CHECK_SCOPE`
- keep the same blocking rules and evidence requirements as the full audit
- emit artifacts that clearly mark `mode: scoped`

Absence of `CHECK_SCOPE` means `/v-check` stays in `Standalone mode` unless another explicit scoped contract is provided by the caller.

## Scoped Polish Contract

Canonical scoped-polish rules live in `references/v-core-scope-passing.md`.

`/v-polish` is a **scoped mode** orchestration primitive in the current workflow:
- the orchestrator passes `POLISH_SCOPE`
- `/v-polish` audits only those files
- safe and medium-confidence polish fixes are auto-applied directly
- structural changes are deferred into `POLISH_PLAN`

**Standalone mode is not supported for `/v-polish`.** If `POLISH_SCOPE` is absent, `/v-polish` must log `polish_skipped: no_scope_provided` and return control to the caller. For full-codebase UX audits, route to `/v-check` instead.

**`/v` must be the FIRST action.** The global CLAUDE.md requires invoking `/v` via the Skill tool BEFORE writing any code. If you are reading this file, `/v` was correctly invoked first. Now continue the workflow — do NOT implement anything directly without going through the sub-skills above.

**Circular invocation guard:** Skills MUST track invocation depth to prevent infinite loops. Implementation:

1. The orchestrator (`/v`) initializes `V_DEPTH=0` and `V_CHAIN="/v"` at session start.
2. When any skill invokes a sub-skill via the Skill tool, it passes depth context in the invocation prompt: `[V_DEPTH=1, V_CHAIN=/v→/v-build]`.
3. The receiving skill reads V_DEPTH and V_CHAIN from the invocation prompt. If V_DEPTH > 3, STOP immediately and report: `circular_invocation_detected: chain=[V_CHAIN], depth=[V_DEPTH]`. Do NOT continue execution — emit `status: error` in the artifact and return immediately.
4. Before invoking a sub-skill, check if that skill name already appears in V_CHAIN. If so, STOP and report: `circular_invocation_detected: [skill_name] already in chain [V_CHAIN]`.
5. If V_DEPTH/V_CHAIN is not present in the invocation prompt (user invoked directly), default to `V_DEPTH=0`.

**Anti-pattern:** Do not skip depth tracking because "this invocation is safe." Every Skill tool call increments depth, no exceptions.

## V_DEPTH Parsing Protocol (Mandatory)

Every `v-*` skill MUST parse V_DEPTH from its invocation context at startup. This enables skills to distinguish orchestrator invocation (V_DEPTH >= 1) from direct user invocation (V_DEPTH == 0) and adjust behavior accordingly.

**Parsing rules (apply in order):**
1. Search the invocation prompt/args for `[V_DEPTH=N` where N is a number. Extract N.
2. Search for `V_DEPTH=N` (without brackets) as a fallback.
3. If neither is found, default to `V_DEPTH=0` (user invoked directly).

**Behavioral contract by depth:**

| V_DEPTH | Meaning | Entry-point questions | Ownership boundary |
|---------|---------|----------------------|--------------------|
| 0 | User invoked directly | ASK — use AskUserQuestion for all entry-point prompts | Full flow (skill owns all steps) |
| >= 1 | Orchestrator invoked | SKIP — use sensible defaults (see below) | Partial flow (stop at ownership boundary, return control) |

**Sensible defaults when V_DEPTH >= 1 (questions skipped):**

| Skill | Default depth | Default type/mode | Notes |
|-------|---------------|-------------------|-------|
| `v-check` | Standard | Full audit (or scoped if CHECK_SCOPE present) | CHECK_SCOPE already triggers scoped mode |
| `v-plan` | Standard | Auto-route based on prompt context | Already documented: "use those parameters directly" |
| `v-build` | Autonomous | Source from prompt context | Already implemented via ownership boundary |

**Why this matters:** A solo dev running 8 parallel sessions gets 8 AskUserQuestion prompts if every sub-skill asks for depth/type, even though the orchestrator already classified the task. Skipping redundant questions at V_DEPTH >= 1 eliminates this friction without losing the interactive experience for direct invocations.

## Interactive User Prompts (Mandatory)

**ALL user-facing questions MUST use the `AskUserQuestion` tool.** Never ask questions as plain text in the response. This applies to:

1. **Entry-point depth/type questions** — every skill that offers depth selection (Quick/Standard/Thorough) or audit type selection MUST present these as AskUserQuestion interactive prompts, not inline text questions.
2. **Orchestrator clarification questions** — when `/v` needs to ask about stack detection, routing confidence, or handoff resumption, use AskUserQuestion.
3. **Any user decision point** — if the user must choose between options before work proceeds, use AskUserQuestion.

**Why:** Plain text questions are easy to miss, cannot be answered with a single click, and break the interactive workflow. AskUserQuestion renders as selectable chips/buttons in the UI — this is the expected user experience.

**Format:** Every AskUserQuestion MUST include `multiSelect` (false for single, true for multi). Each option needs `label` AND `description`. Missing `multiSelect` causes silent failures in some environments.

**Skip entry-point questions when EITHER:**
1. `V_DEPTH >= 1` (orchestrator-invoked — use defaults per V_DEPTH Parsing Protocol), OR
2. Invoking context has explicit params (`CHECK_SCOPE`, `ADMIN_AUDIT_DEPTH`, depth keyword).

V_DEPTH == 0 AND no explicit params → ask.

**Anti-pattern:** plain-text "What would you like to do?" Always use AskUserQuestion.

### Temporal constraint: questions only during invocation/classification phase

**Rule (autonomous orchestration):** `AskUserQuestion` is permitted ONLY during the invocation/classification phase of `/v` — Steps -2 through Step 1 inclusive (Headless Detection, Branch Gate, Dirty Tree Warning, Project Root & Stack Detection, Entry: Handoff Check, Entry: Prompt Pack Detection, Memory Recall, Parse & Classify). After Step 1 completes and Step 2 (Scope Detection) begins, `AskUserQuestion` is **forbidden** for the remainder of the session — every subsequent decision must be made autonomously. Step 2 itself runs git commands and applies the scope classification table without user input; it has no question call sites in the current or planned design.

**Why:** `/v` runs unattended across many parallel projects. Mid-flight questions strand work waiting for a human who isn't there. The autonomous path uses sensible defaults (per `_v-exec.md` § Safety Gates) and the documented fallback protocol (per `_v-resilience.md` § Documented fallback paths) for every post-classification decision. Multi-reviewer quorum dispatch is not implemented — see `_v-review.md` § Quorum Reviewer Dispatch — Not Implemented.

**Permitted (Steps -2 through 1):**
- Handoff resumption ("resume from handoff or start fresh")
- Stack detection unknown (which framework)
- Low-confidence classification (top 2–3 categories)
- Prompt-pack discovery ("run next pack or ignore")
- Multi-stack ambiguity ("which stack does this change target")

**Forbidden (Step 2 through Step 7):**
- "Should I commit WIP files first?"
- "Main is dirty — wait or proceed?"
- "Conflict detected — which session wins?"
- "Re-dispatch pre-flight or fix in place?"
- "Worktree merge blocked — what should I do?"
- Any "should I…" question during execution, quality gates, agent review, verification, or merge-back.

**For sub-skills:** Sub-skills invoked at `V_DEPTH >= 1` must skip ALL entry-point questions per the existing V_DEPTH Parsing Protocol. The temporal constraint reinforces this: even at `V_DEPTH = 0`, sub-skills invoked from Step 3 onward must not ask questions because the orchestrator's overall session is past the invocation/classification phase.

**Self-detection:** If during Step 3 onward the orchestrator believes it needs to ask a question, that's a signal the design is missing an autonomous resolution path. The correct response is NOT to ask the user — it is to:
1. Apply the documented sensible default for that situation (consult `_v-exec.md` § Safety Gates and `_v-resilience.md` § Documented fallback paths),
2. Or write a `BLOCKED_<sid>.md` artifact describing the missing autonomous path so the next session iteration (or a future plan revision) can address it.

**Anti-pattern:** Treating "I'll just ask the user" as a fallback during execution. There is no user listening during execution. Treat the orchestrator's session as fully autonomous from Step 3 onward.

## Shared Depth Semantics

When any skill offers a depth option (Quick/Standard/Thorough or equivalent), these definitions apply uniformly:

| Depth | File Coverage | Analysis Method | Typical Use |
|-------|--------------|-----------------|-------------|
| **Quick** | Grep-only, no file reads | Pattern matching on filenames and search results | Fast triage, smoke checks |
| **Standard** | Top 20% of files by relevance (key controllers, services, pages) + all files matching the audit scope | Read and analyze selected files, identify patterns | Default for most audits |
| **Thorough** | All files in scope — every controller, service, model, page, test, config | Full file reads, cross-referencing, dependency tracing | Pre-launch, security audits, comprehensive reviews |

Individual skills may add depth-specific behavior on top of these base definitions, but they MUST NOT redefine what "Thorough" or "Quick" means in a way that contradicts this table.


## Project Root Detection

Forked Agent contexts have `pwd` = Claude-internal session dir (NOT the repo). Artifacts written to bare `pwd` land in the wrong place.

**Dispatcher rule:** when invoking any skill via Agent tool, include `PROJECT_ROOT=/absolute/path/to/repo` in the prompt. Run `pwd` before dispatching, pass result.

**Skill startup priority:**
1. `PROJECT_ROOT=` in invocation prompt → use that.
2. Else `git rev-parse --show-toplevel 2>/dev/null` (works in repos and worktrees).
3. Else stop and ask. Do NOT fall back to `pwd`.

**Forbidden fallback roots** (reject before any read/write): `$HOME`, `/`, `/Users`, `/tmp`, `/var`, `/usr`, `/System`, `/Library`, `/Volumes`.

All artifact paths use the resolved project root. NEVER bare `pwd` in forked/headless contexts.

**Defensive bash boilerplate:** audit skills use a stricter version of these
rules with executable runtime guards (refusing `$HOME` / filesystem-level
roots, explicit error messages). Non-audit skills that want the same
defensive checks should source the boilerplate from `_v-audit.md`
§ PROJECT_ROOT Resolution (Mandatory — Before Step 0) — the prose rule above
is the contract; the audit-module bash block is one production-ready
implementation of it.

## Session ID (`${CLAUDE_SESSION_ID}`)

Claude Code provides a built-in `${CLAUDE_SESSION_ID}` variable that is unique per session. Use it directly in all artifact filenames — do not generate a custom SID. The variable is available in skill body text, frontmatter, and bash expansions.

This ID makes every artifact filename unique per session, preventing collisions when multiple sessions (or concurrent worktrees) operate on the same branch or across different projects.

Rules:
1. Use absolute paths.
2. Choose artifact class before writing.
3. Write the file before claiming completion.
4. Include generation timestamp, source skill name, and status.
5. Record the final path in the completion message.
6. **File on disk, not text in response.** Describing the report content in your response text does NOT satisfy the artifact requirement. The file MUST be created via the Write tool. Stop hooks validate file existence on disk — they cannot see your response text.
7. Use `${CLAUDE_SESSION_ID}` consistently for all artifacts in the session.
8. **SID-aware artifact lookup (parallel session safety):** When searching for the latest artifact of a type **from the current session**, filter by the session's `${CLAUDE_SESSION_ID}`:
   ```bash
   # Correct: find this session's artifact
   ls -t PRE_FLIGHT_REPORT_*${CLAUDE_SESSION_ID}*.md 2>/dev/null | head -1
   # Wrong: picks up any session's artifact
   # ls -t PRE_FLIGHT_REPORT_*.md | head -1
   ```
   Use the unfiltered glob (`*_*.md`) only when intentionally searching across all sessions (e.g., handoff, cross-session delta comparison, or checking if any recent artifact exists regardless of origin).
9. **Artifact expiration:** When reading an artifact, check its age against the expiration policy (see `references/v-core-artifacts.md`). If expired, warn the user before relying on it.
10. **Model decision audit trail:** Every artifact that involves judgment calls (skipping steps, choosing between approaches, interpreting ambiguous requirements) MUST include a `## Decisions` section.

## Skill Directory (`${CLAUDE_SKILL_DIR}`)

Skills in this ecosystem use `${CLAUDE_SKILL_DIR}` as a convention for
referencing skill-local artifacts (references, templates, hook scripts).
**Empirical status (as of 2026-05):** the variable is observed in 10+
skills' SKILL.md bodies but is not provably auto-set by the Claude Code
runtime — production audit logs show a default-expansion fallback pattern
(`${CLAUDE_SKILL_DIR:-~/.claude/skills/v-<name>}`) consistent with the
variable being unset in some contexts. Until empirical proof of a runtime
auto-set lands (a hook test or a Claude Code release-note citation), treat
this as a documented convention with a recommended fallback, not a
guaranteed built-in.

**Safe-default pattern for consumers:**

```bash
# Use ${CLAUDE_SKILL_DIR} if set, otherwise fall back to the canonical path
SKILL_DIR="${CLAUDE_SKILL_DIR:-${HOME}/.claude/skills/<skill-name>}"
cat "$SKILL_DIR/references/X.md"
```

When the variable IS set by the runtime, the safe-default fallback is a
no-op. When it ISN'T set (current empirical risk), the fallback resolves
correctly under the operator's home directory.

**Canonical use cases:**

- **Skill-local reference files** that operators or subagents must read:
  `${CLAUDE_SKILL_DIR}/references/X.md`. Bare `references/X.md` resolves
  relative to `pwd`, which is Claude-internal under `context: fork` (per
  § Project Root Detection above) — NOT the skill directory. Use the
  variable.
- **Skill-local hook scripts** (rare): `${CLAUDE_SKILL_DIR}/hooks/X.sh`.
- **Skill-local example outputs or templates** the operator inspects.

**Do NOT use** for:

- Cross-skill references (use `~/.claude/skills/<other-skill>/references/...`
  with absolute home prefix, or relative `_v-X.md` for sibling shared modules).
- Project-relative artifacts (use `$PROJECT_ROOT` per § Project Root Detection).

**Verifying the convention:** the hygiene test `__tests__/v-m1-hygiene.test.ts`
asserts canonical-use enforcement for specific skill-local references (e.g.,
v-ci-fix's failure-taxonomy.md MUST be cited via `${CLAUDE_SKILL_DIR}/`).
When adding a new skill-local reference file, prefer the variable form from
the start; the hygiene test pattern can be extended to cover it.

**Anti-pattern (verified-real, 2026-05 regression):** "fixing" a
`${CLAUDE_SKILL_DIR}/references/X.md` reference because a static analyzer
flagged it as a broken cite — the variable resolves at runtime, not at
parse time. See § Pre-Edit Verification Gate for the verification protocol
that catches this class.

## Audit Finding Schema (Universal Base)

Every audit finding MUST include these base fields:
- `id`: category prefix + sequential (SEC-001, CRO-001, etc.)
- `priority`: P0 | P1 | P2 | P3
- `confidence`: high | medium | low
- `title`: one-line summary
- `description`: detailed explanation
- `evidence`: [{type, path, lines, note, proof, accessed_at}]
- `implementation`: {approach, changes[{file, action, description}], verification[]}
- `effort_hours`: numeric estimate

### Optional Enrichment Fields (for cost-optimized remediation)

Audit skills may populate four additional fields on each finding. These
enable the remediation pipeline to route mechanical fixes off Sonnet:

- `patch`: unified diff applicable via `git apply`. Include only when the
  fix is fully deterministic (single-file null check, typo, missing import,
  missing `await`, etc.). Skip for refactors, logic changes, or any fix
  requiring judgment.
- `detection`: shell command that exits 0 when the finding is FIXED,
  non-zero when still present. Required alongside `patch`. Recommended for
  all non-trivial findings. Must be fast (<2s), side-effect-free, and
  runnable from repo root.
- `complexity`: routing hint — `"patch"` (apply mechanically, no model),
  `"haiku"` (small prescriptive fix, run on Haiku via /v-build-narrow), or
  `"sonnet"` (full reasoning required, default). When uncertain, choose the
  higher bucket — misclassification costs one retry, defaulting to Sonnet
  costs the weekly rate limit.
- `hostile_counter`: 1-3 sentence adversarial counter-analysis capturing
  the strongest argument that this finding is wrong or a false positive.
  Populated during the same audit pass that wrote the finding; replaces a
  separate hostile-review step that would otherwise run as a later dispatch.

**Full field specifications, decision rules, and worked examples:**
`references/v-core-finding-enrichment.md`

Audit skills that omit these fields continue to work — the remediation
pipeline defaults all unspecified findings to the full Sonnet flow. But
every finding that includes `patch` skips the model entirely, and every
finding marked `complexity: haiku` runs on the cheap model. Populate the
fields whenever the reasoning cost is the same as producing just prose.

**Priority classification:** canonical P0-P3 definitions live in `references/v-core-severity.md` § Canonical scale.
Cite that table (it also carries the critical/high/medium/low cross-vocabulary mapping and the
numeric scoring bands) — do not restate it here; the prior inline copy had already drifted from
the owner's wording.

**Priority actions ranking:** `impact / (effort_hours + 1)`, top 25, sorted descending.

**Error handling:** If >50% of dimensions/audits fail, abort consolidation → `AUDIT_INCOMPLETE`.

**JSON validation:** Before writing any JSON artifact:
1. Validate: `echo "$JSON" | jq . > /dev/null 2>&1`
2. If invalid: attempt repair (add missing closing braces, escape unescaped quotes, remove trailing commas)
3. If repair succeeds: rewrite with `"_meta": {"repair_applied": true}` flag in audit_metadata
4. If repair fails: write a plaintext `AUDIT_INCOMPLETE_${CLAUDE_SESSION_ID}.md` report with `status: blocked, reason: json_corruption` and the raw output for debugging. Do NOT write invalid JSON to disk.

**Example finding:**
```json
{
  "id": "SEC-001",
  "priority": "P0",
  "confidence": "high",
  "title": "Unhandled StripeException in BillingService",
  "description": "Stripe API calls lack try/catch, risking inconsistent DB state on network errors",
  "evidence": [{"type": "code", "path": "app/Services/BillingService.php", "lines": [45, 67], "note": "No exception handling around Stripe call"}],
  "implementation": {"approach": "Wrap in try/catch, handle CardException and ApiConnectionException", "changes": [{"file": "app/Services/BillingService.php", "action": "modify", "description": "Add try/catch around lines 45-67"}], "verification": ["php artisan test tests/Feature/BillingServiceTest.php"]},
  "effort_hours": 3
}
```

### Pre-Edit Verification Gate (for path-replacement and rename findings)

Before any finding that proposes a path replacement, rename, or citation
change graduates from a backlog item to an applied edit, the implementer
MUST verify:

1. **Target file existence** — `ls` the proposed target path; confirm it
   exists. Cite the actual file size to prove you read it.
2. **Target file content matches operator instruction** — read the target
   file and the citation-site context together. The target's content must
   support what the SKILL.md text says about it (e.g., "classify into one
   of the 10 buckets in REF" requires REF to actually contain those 10
   buckets; a session log that *mentions* a taxonomy does NOT satisfy the
   instruction).
3. **Source path syntax intent** — search `__tests__/*.test.ts` for any
   regex or invariant that constrains the SOURCE form (e.g., the N2
   hygiene test enforces `${CLAUDE_SKILL_DIR}/` prefix for v-ci-fix's
   taxonomy citation). If a test exists, the proposed change must not
   silently bypass it by renaming or restructuring.

Findings that fail any of (1)/(2)/(3) MUST be marked as `verification_failed`
and either (a) refined with additional context before re-proposal, or (b)
rejected as a false-positive of the upstream detector (e.g., a static-analysis
parser that can't resolve `${VARIABLE}` paths flagging them as broken).

**Audit-author signal:** if your finding involves a path-replacement, you
SHOULD attach a `pre_edit_verification` block to the finding showing the
3 checks above were run. Missing the block lowers the finding's confidence
by one level (high→medium, medium→low) for downstream consumers.

**Audit-the-audit principle:** an INCONCLUSIVE invariant (e.g., the audit's
self-acknowledged INV3 limitation that static parsers can't resolve
`${VARIABLE}` paths) MUST NOT feed actionable backlog items at composite
score >= 5 without per-citation verification first. Findings derived from
INCONCLUSIVE invariants ship at composite cap = 3 until upgraded.

---

## Standard Completion Message

All skills that produce artifacts MUST end with this format (the `Findings` line applies only to audit skills — omit it for non-audit skills; every other line is mandatory):

```
[Skill Name] Complete
  Status: [PASS / FAIL / INCOMPLETE]
  Artifacts: [list of files written]
  Findings: [N] critical, [N] high, [N] medium, [N] low (if audit)
  Next step: [what to do next — e.g., "run /v-build" or "say /commit"]
```

Keep it to 4-5 lines. Do NOT write verbose summaries, tables, or banners.
<!-- end-runtime -->
