# v-* Failure Catalog — empirically observed in 2026-05 review sessions

_Last reviewed: 2026-08-02 (F29 tightened to a two-stage keyword+anchor check; F33/F34 added for instruction-quality and description-collision; **F35 added** for misattributed external standards, and **F26 extended** with an open-ended chained-call existence rule after its closed blocklist missed a fabricated `Route::resource()->can()` in the most-inherited security module — 2026-08-02 SME content review)._

> **Loaded by:** v-skill-reviewer in `standard` and `thorough` modes when applying the **Failure-mode catalog** lens. Each entry is a real failure caught in a prior review chain; check the target skill against each pattern.

Document each entry as: **what the failure is, how to detect it, the canonical fix.** Reviewer cites this catalog when a finding matches.

---

## F1 — Bash state doesn't survive between Bash tool calls

**Failure:** SKILL.md instructs a bash block to set a variable (e.g., `V_TIMEOUT_CMD=timeout 120` or `cd /some/path`) intending it to apply to subsequent Bash tool calls in the same skill workflow.

**Why it breaks:** Claude Code's Bash tool starts a fresh shell for each invocation. Variables, exported env, cwd, shell functions — none persist. The second Bash call sees an empty `$V_TIMEOUT_CMD` and runs the inner command unbounded.

**Detection commands:**
```bash
# Look for variable assignment in one bash block + use of that variable in a separate bash block
rg -nA 5 '^\$?[A-Z_]+=' <SKILL.md> | head -40
# Look for `cd` in one block + subsequent commands assuming the cwd
rg -n '^cd ' <SKILL.md>
```

**Failure signal in review:** if the SKILL.md has two `bash` fences AND the second references a variable set in the first → P0.

**Canonical fix:** inline the variable-setting AND the variable-using commands in the SAME fenced bash block (single Bash tool call). For genuinely-cross-call state, persist to a file: `echo "$VAR" > "$V_TMP_DIR/var-${SID}.txt"` then `VAR=$(cat ...)`.

**Cited from:** v-tdd Phase 2 review 2026-05-18 — `V_TIMEOUT_CMD` detection block was split from test-run block; first fix attempt was theatre.

---

## F2 — Path drift between skill docs and hook source-of-truth

**Failure:** SKILL.md references a filesystem path (writes log, marker file, env file, runtime cache) that doesn't match where the hook actually writes/reads it.

**Why it breaks:** the path looks right ("session-writes-${SID}.txt under .v/tmp/") but the actual hook (`track-session-writes.sh:128`) writes to `${git_common_dir}/claude-session-writes-${SESSION_ID}.txt`. The SKILL.md's `[ -f "$PATH" ]` check always fails → silent no-op.

**Detection commands:**
```bash
# Find every path the skill references that looks like a hook artifact
rg -no 'claude-session-writes-[^"\s]*|session-writes-[^"\s]*|\.v/tmp/[a-z-]+-\$\{?[A-Z_]+' <SKILL.md>
# Cross-check against hook sources
for p in $(rg -no 'claude-session-writes-|session-writes-|.v/tmp/' ~/.claude/hooks/*.sh | sort -u); do
  echo "Hook writes: $p"
done
```

**Failure signal in review:** any SKILL.md path that doesn't grep clean to the producing hook → P0/P1 depending on whether the failed-path-check silently passes or aborts.

**Canonical fix:** cite the producing hook's exact line, e.g.:
> `// Path source: ~/.claude/hooks/track-session-writes.sh:128`

When the canonical path is computed (`${git_common_dir}/...`), include the derivation: `GIT_COMMON_DIR=$(git rev-parse --git-common-dir)`.

**Cited from:** v-tdd Phase 2 review — Step 5.5 wrote-log gate read wrong path; gate was non-functional.

---

## F3 — Safety banner vs hook redundancy mismatch

**Failure:** SKILL.md contains a long preamble banner ("MUST do X before Y") AND a hook that enforces X exists — but they document different rules, OR the banner enforces something no hook backstops.

**Why it matters:** banners are pre-emptive (stop the model before bad behavior); hooks are reactive (catch bad behavior after it happens). For SOLE-defense banners (no hook), compression is dangerous. For hook-backstopped banners, narrative bloat is removable.

**Detection commands:**
```bash
# List every "MUST"/"NEVER"/"FORBIDDEN" in SKILL.md
rg -n '^\*\*(MUST|NEVER|FORBIDDEN|ABSOLUTE|MANDATORY)' <SKILL.md>
# Cross-check each against the hooks
for pat in MUST NEVER FORBIDDEN MANDATORY; do
  rg -lF "$pat" ~/.claude/hooks/*.sh
done
```

**Failure signal in review:**
- Banner rule has NO hook backstop → flag as SOLE-DEFENSE; do NOT recommend compression
- Banner rule has hook backstop → recommend compression to a one-line pointer to the hook
- Banner rule contradicts the hook (e.g., banner says "write FOO.md," hook accepts only BAR.md) → P0

**Canonical fix:** for SOLE-defense banners, document the missing hook as future-work. For backstopped banners, compress prose to "see hook X for enforcement."

**Cited from:** /v banner analysis 2026-05-18 — PATH CONVENTION banner was heavily redundant with `block-vtmp-typo.sh` hook; SELF-SUFFICIENCY DIRECTIVE was sole defense.

---

## F4 — Stop-hook artifact contract drift

**Failure:** Skill produces an artifact name (`PROGRESS_NOTE_${SID}.md`, `BUILD_BLOCKER_{ts}.md`) that the Stop hook does NOT accept as gate satisfaction. Session is trapped in an impossible gate.

**Why it breaks:** `check-review-artifact.sh` accepts a specific set of artifact names — do NOT trust any remembered or documented copy of that list (it grows over time; IMPACT_MAP, QA_REPORT, UX_CRITIQUE, WORKFLOW_VERIFICATION, CYCLE_CAP_HANDOFF were all added after the original seven). Grep the hook's `IS_V_SESSION` recognized-artifact loop as the source of truth. Any name outside it → block. One scoped exception exists: the SKILL-REVIEW ESCAPE (2026-07-05) in Part B accepts `SKILL_REVIEW_REPORT_${SID}.md` for report-only `/v-skill-reviewer` sessions, gated on harness-written history evidence + content validation (≥300 bytes, `# SKILL_REVIEW_REPORT` heading, `Mode:` line, `Overall Status:` verdict) — regression-locked by Tier 4 of `hooks/check-review-artifact-test.sh`.

**Detection commands:**
```bash
# What artifacts does the Stop hook accept?
rg -n '_HANDOFF_|_PRE_FLIGHT_REPORT_|_AGENT_REVIEW_|_VERIFY_DONE_REPORT_|TRIVIAL_PASS|PLANNING_PASS|IMPLEMENTATION_REPORT' \
  ~/.claude/hooks/check-review-artifact.sh
# What artifacts does the skill claim to produce?
rg -n 'produces:|writes? [\`]?[A-Z_]+_\$\{' <SKILL.md>
```

**Failure signal in review:**
- Skill's `produces:` mentions an artifact name not in the Stop hook accept-list → P0
- Skill says "write X.md to exit cleanly" where X is not on the accept-list → P0
- Skill omits VERIFY_DONE_REPORT from its standalone contract when the hook requires the trio → P1

**Canonical fix:** every produced artifact name must appear in the Stop hook source. If a new artifact type is needed, extend the hook FIRST.

**Cited from:** v-tdd Phase 1 review 2026-05-18 — PROGRESS_NOTE was recommended as standalone exit, hook didn't accept it.

---

## F5 — SID-binding missing on cross-session artifacts

**Failure:** Skill writes `BUILD_BLOCKER_{timestamp}.md` (no `_${CLAUDE_SESSION_ID}` suffix). Parallel sessions trample each other's BUILD_BLOCKER files; cross-session-learning hooks can't bind a blocker to a specific session.

**Detection commands:**
```bash
# Look for artifact patterns without SID. NOTE: `(?!_\$)` is a negative lookahead — rg's default
# regex engine (Rust `regex` crate) does NOT support lookaround; this command errors ("error:
# parsing not implemented") unless you pass --pcre2 (only if your rg build includes the PCRE2
# feature). Prefer the lookahead-free form below, which is portable everywhere:
rg -nE '(BUILD_BLOCKER|PROGRESS_NOTE|HANDOFF|PLAN|AUDIT_REPORT)_\{[^}]+\}' <SKILL.md> | grep -v '_\${'
# If you specifically need the lookahead form and know --pcre2 is available:
rg --pcre2 -nE '(BUILD_BLOCKER|PROGRESS_NOTE|HANDOFF|PLAN|AUDIT_REPORT)_\{[^}]+\}(?!_\$)' <SKILL.md>
rg -nE '(BUILD_BLOCKER|PROGRESS_NOTE|HANDOFF)_\$\{?[a-z_]+\}?\.md' <SKILL.md>
```

**Failure signal in review:** any artifact named with `{timestamp}` or `[timestamp]` but no `${CLAUDE_SESSION_ID}` → P1.

**Canonical fix:** always SID-suffix: `BUILD_BLOCKER_{timestamp}_${CLAUDE_SESSION_ID}.md`.

**Cited from:** v-tdd Phase 1 review — BUILD_BLOCKER was missing SID; pattern from v-build was canonical.

---

## F6 — Test-only-writes / scope-boundary violation

**Failure:** Skill describes itself as writing only to a constrained surface (e.g., "test files only") but has `Write/Edit` tools and no enforcement gate. Model can edit anything.

**Detection commands:**
```bash
# What does the skill claim it writes to?
rg -n 'mutates|writes only|test-only|read-only' <SKILL.md>
# What tools does it have?
rg -n '^allowed-tools:' <SKILL.md>
# Is there an enforcement gate?
rg -nE 'session.?writes|git diff.*HEAD.*name-only.*grep' <SKILL.md>
```

**Failure signal in review:**
- Skill claims constrained writes BUT has Edit/Write BUT no enforcement gate → P1
- Claim contradicts idempotency section ("mutates code + tests" vs "test-only") → P2

**Canonical fix:** add a Step 5.5-style runtime gate that greps the session writes log against an allowlist regex; falls back to `git diff --name-only HEAD` if log absent. Allowlist must cover Cypress, Playwright, Storybook, framework factories (Laravel `database/factories/`), test configs at repo root.

**Cited from:** v-tdd Phase 1+2 reviews — test-only-writes was documentation-only; runtime gate added in Tier-1 hot fix.

---

## F7 — `disable-model-invocation` mismatch with usage pattern

**Failure:** Skill is intended to be called only by sibling skills (`/v` invokes `/v-tdd`) but lacks `disable-model-invocation: true`. Claude can auto-match and fire it unexpectedly. OR: skill is meant to be user-invocable but has `disable-model-invocation: true` AND `user-invocable: true` — autonomous matching blocked but direct user invocation works (subtle).

**Detection commands:**
```bash
rg -n '^(disable-model-invocation|user-invocable):' <SKILL.md>
# Cross-check against `invoked-by:` contract
rg -n '^\s*invoked-by:' <SKILL.md>
```

**Failure signal in review:**
- `invoked-by: [/v, /v-build, user]` AND no `disable-model-invocation` → autonomous matching MAY fire; intentional? Document or flag P2.
- `disable-model-invocation: true` AND `user-invocable: false` → skill is unreachable. P0.

**Canonical fix:** decide intent. Internal-only (called by sibling): `disable-model-invocation: true`. User-typeable but not autonomous-matchable: `disable-model-invocation: true` + `user-invocable: true`. Discoverable by Claude: omit the flag.

**Cited from:** v-tdd Tier-2 #12 — added `disable-model-invocation: true` to prevent surprise auto-invocation.

---

## F8 — Dead `allowed-tools` grant

**Failure:** Frontmatter declares a tool (commonly MCP tools like `mcp__plugin_context7_context7__resolve-library-id`) but the SKILL.md workflow never references it.

**Detection commands:**
```bash
# Extract allowed-tools list
rg -nE '^allowed-tools:' <SKILL.md>
# For each tool, check if it appears in the body
for tool in $(grep '^allowed-tools:' <SKILL.md> | sed 's/^allowed-tools://;s/,/ /g'); do
  tool=$(echo "$tool" | tr -d ' ')
  [ -z "$tool" ] && continue
  rg -qF "$tool" <SKILL.md> || echo "DEAD GRANT: $tool"
done
```

**Failure signal in review:** any granted tool whose name doesn't appear anywhere in the body → P3 (cleanup).

**Canonical fix:** either remove the dead grant OR add a workflow step that uses the tool.

**Cited from:** v-tdd Tier-3 #15 — context7 MCP tools were granted but unused; Tier-3 added a library-doc lookup step.

---

## F9 — History.jsonl regex matching `/v` vs `/v-*`

**Failure:** Stop hook detects "v-orchestrator family invocation" via regex on history.jsonl `display` field. Original regex `/v[ "]` matched `/v fix bug` but NOT `/v-tdd Foo`. Standalone sub-skill sessions therefore failed to engage abandonment-escape (HANDOFF acceptance).

**Detection commands:**
```bash
rg -nE '/v\[' ~/.claude/hooks/check-review-artifact.sh
# Test the regex empirically:
for cmd in '/v fix' '/v-tdd Foo' '/v-build' '/v' '/version' '/verify'; do
  echo "\"display\":\"$cmd\"" | grep -qE '"display":"/v(-[a-z]|[ "])' && echo "$cmd: MATCH" || echo "$cmd: NO_MATCH"
done
```

**Failure signal in review:** any v-* sub-skill that documents a standalone exit relying on `IS_V_INVOCATION_VIA_HISTORY=1` while the hook regex doesn't match `/v-*` → P0.

**Canonical fix:** AVF-031 — extend regex to `'"display":"/v(-[a-z]|[ "])'`. Verifies negative cases: `/version`, `/verify` correctly do NOT match.

**Cited from:** v-tdd Phase 1 review — hook regex change shipped 2026-05-18.

---

## F10 — Anti-pattern catalog duplication

**Failure:** Two anti-pattern catalogs exist (local `skill/references/X.md` + global `skills/references/X.md`), both cited from the same skill at different points. Drift inevitable — skill generates under one catalog while another skill rejects under the other.

**Detection commands:**
```bash
# Find duplicate catalog files
find ~/.claude/skills -name "anti-patterns.md" -o -name "*-anti-patterns.md" 2>/dev/null
# Check if multiple are cited from the same SKILL.md
rg -nE 'anti-patterns\.md|anti_patterns' <SKILL.md>
```

**Failure signal in review:** same-topic reference file in TWO locations, both cited → P1 (drift risk).

**Canonical fix:** one canonical (preferably under `skills/references/` for cross-skill sharing). Other becomes a 20-line redirect stub.

**Cited from:** v-tdd Phase 1 #3 — anti-patterns existed at both `v-tdd/references/anti-patterns.md` and `skills/references/v-tdd-anti-patterns.md`. Dedup'd by making global canonical, local a redirect.

---

## F11 — Idempotency claim vs runtime-behavior mismatch

**Failure:** Skill's "Idempotency" section claims behavior that contradicts other parts of the skill. E.g., "Mutates code + test files" while another section forbids touching production code.

**Detection commands:**
```bash
rg -nB 2 -A 5 '^## Idempotency' <SKILL.md>
# Cross-check against scope claims
rg -nE 'mutates|writes? to|edits?|forbidden|test-only' <SKILL.md>
```

**Failure signal in review:** idempotency claim contradicts a Rules/Boundaries/Workflow rule → P2.

**Canonical fix:** rewrite idempotency to match the strictest claim elsewhere in the skill.

**Cited from:** v-tdd Tier-3 #17 — old "Mutates code + test files" violated the Tier-1 test-only-writes principle.

---

## F12 — Composability silence (multiple input sources, no priority rule)

**Failure:** Skill accepts N input types (e.g., async-trace + PLAN + persona + Gherkin) but doesn't document what happens when 2+ apply simultaneously. Model improvises priorities; output drifts session-to-session.

**Detection commands:**
```bash
# Look for accepts list size
rg -nA 10 '^\s*accepts:' <SKILL.md>
# Look for explicit prioritization
rg -nE 'priority|prioriti|cap.*tests|drop.*from' <SKILL.md>
```

**Failure signal in review:** `accepts:` has 3+ types AND no documented prioritization → P2.

**Canonical fix:** add a "Test budget + prioritization rule" with explicit ordering + worked example.

**Cited from:** v-tdd Tier-2 hot fix — 8 input types but no prioritization; worked example added.

---

## F13 — Wave-marker preservation during refactor

**Failure:** Skill refactor (extraction, compression) drops `W##-F##` markers that encode operational lessons (production session IDs, dates, root causes).

**Detection commands:**
```bash
# Wave markers in baseline vs current. Use a scoped scratch dir, not a bare unscoped /tmp/*.txt —
# a global /tmp path can collide with a concurrent reviewer session (same failure class this
# catalog's own F5 flags for skill artifacts; applies equally to the reviewer's own scratch files).
_WAVE_SCRATCH="$(mktemp -d)"
rg -no 'W[0-9]+(-F?[0-9]+[a-z]?)?' /path/to/baseline.md | sort -u > "$_WAVE_SCRATCH/baseline-waves.txt"
rg -no 'W[0-9]+(-F?[0-9]+[a-z]?)?' /path/to/current.md | sort -u > "$_WAVE_SCRATCH/current-waves.txt"
comm -23 "$_WAVE_SCRATCH/baseline-waves.txt" "$_WAVE_SCRATCH/current-waves.txt"
```

**Failure signal in review:** any wave marker present in baseline but missing from current OR its referenced sub-file → P2 (information loss).

**Canonical fix:** preserve every wave marker either in SKILL.md body or in a referenced file. Wave markers are operational provenance.

**Cited from:** /v + v-ui-audit refactor 2026-05-18 — parity check confirmed every wave marker was preserved.

---

## F14 — Hook side-effect contagion

**Failure:** Modifying a Stop hook (e.g., extending a regex to fix one skill) accidentally enables a permissive path for OTHER skills that shouldn't trigger it.

**Detection commands:**
```bash
# Show all paths in the hook that gate on the modified condition
rg -nB 2 -A 8 'IS_V_INVOCATION_VIA_HISTORY' ~/.claude/hooks/check-review-artifact.sh
# Test the new regex on synthetic inputs the original didn't intend to match
```

**Failure signal in review:** hook regex change matches strings outside the intended scope (e.g., `/verify`, `/version`) → P0.

**Canonical fix:** include negative-case test in the review report; reject the patch if false-positives slip through.

**Cited from:** v-tdd Phase 1 hot fix — AVF-031 regex extension was tested against `/version` and `/verify-stuff` before shipping.

---

## F15 — Reference-as-stub vs reference-as-detail confusion

**Failure:** SKILL.md compresses a section to a "stub + reference link" but the reference doesn't actually contain the content the stub claims. Stub-only readers act on incomplete info.

**Detection commands:**
```bash
# For each section that ends with "see references/X.md", verify X.md has the claimed content
rg -nE 'see references/[a-z-]+\.md|read references/[a-z-]+\.md' <SKILL.md> \
  | while read line; do
      ref=$(echo "$line" | rg -o 'references/[a-z-]+\.md')
      [ -f "$(dirname <SKILL.md>)/$ref" ] || echo "BROKEN REF: $line"
    done
```

**Failure signal in review:** any "see references/X.md § Y" pointer where the referenced file lacks Y → P1.

**Canonical fix:** verify by reading the referenced file before approving the compression.

**Cited from:** /v Step 3 Verbatim Dispatch compression 2026-05-18 — initial compression referenced `§ W38 Abort Message` + `§ MODE Resolution` sections that didn't exist; added during the same patch.

---

## F16 — Frontmatter/runtime capability mismatch

**Failure:** Frontmatter declares two fields whose runtime behaviors are mutually incompatible, most commonly `context: fork` (this skill runs as a subagent) combined with granting the `Agent` tool in `allowed-tools` (used to dispatch further subagents). A skill running in a forked context IS ITSELF a subagent — Claude Code's platform does not allow a subagent to dispatch further subagents via the Agent tool. The Agent-tool call either errors or silently falls through to inline execution, which is a much weaker guarantee than the skill's workflow assumes (e.g., "dispatch an independent read-only reviewer" silently degrades to "review it yourself, biased by your own prior reasoning"). A second variant: a `model:` pin (e.g. `haiku`) combined with a workflow that requires open-ended multi-step judgment the pinned model tier isn't suited for.

**Why it breaks:** the frontmatter is declarative and never runtime-validated against the workflow body — nothing stops a skill author from writing a step that assumes a capability the frontmatter's OTHER fields structurally rule out.

**Detection commands:**
```bash
# context:fork + Agent tool granted together
grep -n '^context: fork' <SKILL.md> && grep -n '^allowed-tools:.*\bAgent\b' <SKILL.md>
# Cross-check: does the body actually call the Agent tool / describe dispatching a subagent?
grep -nE 'Agent\(|dispatch.*[Aa]gent|subagent_type' <SKILL.md>
```

**Failure signal in review:** `context: fork` present AND `Agent` in `allowed-tools` AND the body describes dispatching a sub-agent via the Agent tool → P1 (the capability is structurally broken, not just unused — worse than F8's plain dead grant, because the workflow actively relies on it). Recommended fix: drop the `Agent` grant and rewrite the step to use a `claude -p --agent <name> "..." </dev/null` Bash subprocess instead (works from a forked context because Bash does, and the subprocess is genuinely independent).

**Canonical fix:** either (a) remove `context: fork` if the skill genuinely needs Agent-tool subagent dispatch and can run in the parent's context instead, or (b) keep `context: fork` and replace all Agent-tool dispatch steps with `claude -p --agent <name>` Bash subprocesses, dropping `Agent` from `allowed-tools`.

**Cited from:** v-skill-reviewer self-review 2026-07-05 — the skill's own frontmatter had this exact mismatch (`context: fork` + `Agent` granted for an "optionally dispatch a read-only Agent reviewer" thorough-mode step); fixed by dropping the grant and switching Workflow step 8 to the `claude -p` subprocess pattern.

---

## F17 — Harness-tool drift in `allowed-tools`

**Failure:** A tool name in `allowed-tools` that was valid when the skill was authored no longer corresponds to any tool the current Claude Code harness actually exposes (the tool catalog changes across harness versions — tools get renamed, split, or retired). The skill silently loses the capability: the model can't invoke a tool name the harness doesn't recognize, but nothing in the skill file signals this — it just looks like a normal, if unused, grant (indistinguishable from F8's "dead grant" without cross-checking against the live tool catalog).

**Known rename (as of 2026-07):** `TodoWrite` (multi-step progress tracking) → superseded by `TaskCreate`/`TaskUpdate`-style task-tracking tools in current harnesses. Treat this as an EXAMPLE, not an exhaustive list — the whole point of this entry is that the mapping will drift again.

**Detection commands:**
```bash
# Extract the allowed-tools list from frontmatter
awk -F: '/^allowed-tools:/{print $2}' <SKILL.md> | tr ',' '\n' | tr -d ' '
```
There is no static grep that proves a tool name is CURRENTLY valid — the harness's live tool catalog is the only source of truth. During a review, cross-check each `allowed-tools` entry against the tools actually available to you this session (e.g., via a tool-search/discovery mechanism if the harness exposes one) rather than trusting that a name known from a prior session or from training data is still current.

**Failure signal in review:** any `allowed-tools` entry that doesn't match a tool in the live catalog, especially task/todo-tracking tools (renamed most often) → P2 (reduces autonomy silently — the skill believes it can track progress and can't) unless the workflow critically depends on it, in which case P1.

**Canonical fix:** replace the stale name with whatever the current harness grants for the same capability; do not assume the replacement name without checking (guess-and-ship perpetuates the drift under a new name).

**Cited from:** v-skill-reviewer self-review 2026-07-05 — `TodoWrite` in `allowed-tools` and Workflow step 1 was verified stale against the live tool catalog; replaced with `TaskCreate`/`TaskUpdate` and a forward-looking caveat.

---

## F18 — Missing sibling-convention cross-reference pointer

**Failure:** A skill in a family where every sibling carries an explicit shared-procedure pointer (e.g., `_v-audit.md § Audit Skill Opener`) omits it, while still using content that depends on that procedure (e.g., a workflow row saying "Step 0 | Audit opener (PROJECT_ROOT, V_DEPTH, TodoWrite)" with no citation for where the opener is defined). The model running the skill has no in-file instruction for WHERE the procedure lives, so it may skip it, improvise its own version, or desync downstream steps that assume the canonical procedure ran (e.g., `V_DEPTH`-gated skip conditions).

**Detection commands:**
```bash
# Any skill whose workflow mentions the audit opener without citing its definition up top
grep -l 'Audit opener\|PROJECT_ROOT, V_DEPTH' ~/.claude/skills/*/SKILL.md | while read f; do
  head -30 "$f" | grep -q '_v-audit.md' || echo "MISSING OPENER POINTER: $f"
done
# Generalized: diff the contract-section pointer sentences of a skill against 2+ same-tier
# siblings (same `Follow` line) and flag pointers present in ALL siblings but absent here.
```

**Failure signal in review:** a step/table row references a named procedure ("Audit opener", "Prompt Generation Contract") with no resolvable citation in the skill's contract section, while ≥2 same-tier siblings carry the pointer verbatim → P2.

**Canonical fix:** add the sibling's exact pointer sentence (verbatim phrasing, same position near the `Follow` line) — additive, zero regression risk.

**Cited from:** v-anti-template-gauntlet review 2026-07-05 — Step 0 depended on the `_v-audit.md § Audit Skill Opener` procedure and Step 9 separately cited `_v-audit.md`, but the opener pointer sentence carried by both `v-ui-audit` and `v-prelaunch-readiness` was missing; added.

---

## F19 — Named-gate citation with silent per-severity narrowing

**Failure:** A skill says "Apply Gate N from `<canonical-gates>.md`" but then restates a materially different rule for a subset of finding severities (e.g., canonical Gate 1 drops ANY finding without a `file:line` citation, while the skill permits generalized references for MEDIUM/LOW), without an explicit "this narrows/differs from canonical because..." clause. A maintainer cross-referencing the canonical gate finds two disagreeing definitions with no bridge — indistinguishable from drift. Especially jarring when an adjacent gate exemption in the SAME skill (e.g., "Gate 2 does NOT apply because...") demonstrates the correct explicit-deviation pattern.

**Detection commands:**
```bash
# For each named-gate citation, extract the skill's restated rule and diff against canonical
grep -n 'Gate [0-9]' <SKILL.md>
# Then side-by-side read the skill's gate paragraph vs the same Gate section in
# references/v-audit-gates.md; flag any semantic delta lacking an explicit deviation clause.
```

**Failure signal in review:** a "Gate N" citation whose in-skill restatement differs semantically from the canonical gate text for any severity tier, with no deviation clause → P3 (P2 if the delta affects blocking-tier findings or the verdict).

**Canonical fix:** add one sentence naming the deviation and its rationale, mirroring how the adjacent gate-exemption is documented (do NOT silently align to canonical — the narrowing may be intentional; make it legible instead).

**Cited from:** v-anti-template-gauntlet review 2026-07-05 — Gate 1 was cited by name but quietly permitted generalized references for MEDIUM/LOW findings, narrower than canonical `v-audit-gates.md` Gate 1's drop-on-fail rule; fixed with an explicit deviation clause noting MEDIUM/LOW never affect the binary verdict.

---

## F20 — Skill-tool fallback tier in a forked skill (F16's Skill-tool sibling)

**Failure:** A `context: fork` skill's documented fallback ladder names the **Skill tool** as a dispatch mechanism (e.g., "Fallback: `superpowers:requesting-code-review` skill via Skill tool dispatch") while the skill's own `allowed-tools` never grants `Skill` — and a forked skill cannot assume same-process skill dispatch is reachable regardless. Same class as F16 (frontmatter structurally rules out a capability the body relies on), but via the Skill tool instead of the Agent tool, and typically buried mid-ladder so it only bites when the primary tier's precondition fails.

**Why it breaks:** fallback tiers are exercised rarely, so the dead tier survives every session where the primary works. The first time the primary is unavailable (agent file renamed/missing), the model either hallucinates a Skill-tool attempt, silently skips to the last resort, or stalls — and the skipped tier is invisible in the output.

**Detection commands:**
```bash
grep -n '^context: fork' <SKILL.md> && grep -n 'Skill tool' <SKILL.md>
# Cross-check: does allowed-tools grant the literal Skill tool?
awk -F: '/^allowed-tools:/{print $2}' <SKILL.md> | grep -w 'Skill'
```

**Failure signal in review:** `context: fork` + a body fallback tier citing "Skill tool" + no `Skill` in `allowed-tools` → P1 (documented, uninvocable instruction on an error path).

**Canonical fix:** collapse the ladder to tiers a fork can actually execute — named `--agent` subprocess dispatch, then generic `--model` subprocess dispatch with the prompt inline — and state explicitly why no Skill-tool tier exists (so a future editor doesn't re-add it).

**Cited from:** v-anti-template-gauntlet review 2026-07-05 (v1.1.0) — Step 8.6's middle fallback tier cited a Skill-tool dispatch the skill could never perform; collapsed to a 2-tier `v-dispatch-subagent.sh` ladder with an explicit no-Skill-tier rationale sentence.

---

## F21 — Fallback-ladder command/tier mismatch in dispatch-script citations

**Failure:** A step describes a fallback ladder ("Primary: agent X if its file exists; last resort: bare model dispatch") but the ONE literal command shown carries the LAST-RESORT tier's flags (`--model <alias>`, no `--agent`). Compounding it, the dispatch script makes an `--agent` dispatch's frontmatter model pin authoritative — a caller-passed `--model` is ignored with a warning — so the shown command doesn't merely mislabel the tier, it produces a materially different dispatch (generic model prompt instead of the named agent's system prompt, tools, and adjudication logic) while the report still claims the primary path ran.

**Detection commands:**
```bash
# For each "Primary: <agent-name>" ladder, verify the first literal command includes --agent
grep -n -A6 'Primary' <SKILL.md> | grep -E 'dispatch-subagent\.sh|claude -p'
# then check that command for --agent <the named agent>, not just --model
```

**Failure signal in review:** a "Primary: `<agent>`" tier whose nearest literal command lacks `--agent <agent>` → P1 (the independent-review guarantee the step exists for is silently downgraded).

**Canonical fix:** show one literal command per tier, in tier order, each with exactly the flags that tier needs (`--agent` and no `--model` for the primary when the pin wins; `--model` and no `--agent` for the last resort).

**Cited from:** v-anti-template-gauntlet review 2026-07-05 (v1.1.0) — Step 8.6's top-line command was `--model haiku --mode capture` while the ladder's primary tier was `codex-adversarial-reviewer` (frontmatter pin: sonnet); fixed by showing both tier commands explicitly with full flags.

---

## F22 — Self-contradicting duplicate section with stray fence seam

**Failure:** A section argues for a single source of truth ("mirror the body's headers into your response — not a hard-coded duplicate") and is immediately followed, in the same file, by exactly the hard-coded duplicate it argues against — with an unmatched code fence marking the copy-paste seam. The duplicate silently goes stale on the next body edit (the drift the design was meant to prevent), and the odd fence count risks mis-rendering everything after it in strict markdown renderers.

**Detection commands:**
```bash
# Fence parity: odd = unbalanced
c=$(grep -c '^```' <SKILL.md>); [ $((c % 2)) -eq 0 ] || echo "UNBALANCED FENCES: $c"
# Then manually read any section whose prose argues against duplication for a nearby contradiction
```

**Failure signal in review:** odd fence count, OR a "don't duplicate X" instruction with a duplicate of X within the same file → P2.

**Canonical fix:** keep exactly one version (delete the hard-coded duplicate and the orphan fence); if both are intentionally kept, fence both correctly and add one sentence explaining why two coexist.

**Cited from:** v-anti-template-gauntlet review 2026-07-05 (v1.1.0) — the Progress Checklist's "not a hard-coded duplicate" rationale was immediately followed by a hard-coded canonical step list ending in a stray unmatched fence (33 fence markers); duplicate + orphan fence deleted, fence count restored to even.

---

# Content & currency failures (F23–F30) — added 2026-07-05 from the 54-skill content review

These are the DOMAIN-CORRECTNESS classes lenses 18-25 exist to catch. The mechanics catalog (F1–F22) checks *how a skill is wired*; F23–F30 check *whether its instructions are true, current, and fit the operator's use case*. This was the dominant defect surface in the 2026-07-05 review (6 P0s, ~200 findings).

## F23 — Un-live-fired detection command (false-positive / inert / invalid)

**Failure:** A skill embeds a shell command to FIND issues (grep/rg/comm/awk) that was never actually run, so it silently matches everything (false-positive machine feeding a downstream safe-delete/verdict), matches nothing (inert — wrong literal, e.g. gate greps `status: failed` while the report writes `status: fail`), uses an invalid flag (`rg --type tsx` — rg has no built-in `tsx` type), or loses data through broken quoting (`grep -q | grep` — a quiet grep emits nothing downstream; apostrophe-escaping that neuters or inverts a gate) or unsupported syntax (`\u{...}` in grep).

**Detection commands:**
```bash
# Enumerate every detection command, then RUN each against realistic input:
grep -nE '\b(grep|rg|comm|awk|sed)\b' <SKILL.md and its references/*.md>
rg --type tsx x . 2>&1 | grep -qi 'unrecognized file type' && echo "INVALID: rg has no tsx type → use -g '*.tsx'"
# For each gate that greps a literal out of another artifact, confirm the producer writes that exact literal.
```

**Failure signal in review:** any find-command not demonstrated to bite on a realistic input → P1 (P0 if it feeds a destructive phase or a gate verdict).

**Canonical fix:** live-fire the command; fix the literal/flag/quoting; re-run to prove it bites. `rg --type tsx` → `-g '*.tsx'` (add `-g '*.ts'`); two-input `comm` needs both sorted + matched parens.

## F24 — Zero-outreach / solo-motion violation

**Failure:** A growth/messaging/pricing/launch/beta/differentiate skill emits a finding, benchmark, or prompt-pack target that requires cold outreach, founder demos ("book a demo"), ongoing community posting/karma-farming, personal-network recruitment, or guest-posting — for an operator whose motion is passive/self-serve only. Because findings flow into autonomously-executed prompt packs, this can build cold-email infrastructure or score the correct ABSENCE of an outbound artifact as a gap. NOT a violation: one-time, no-relationship launch-day self-posts/listings (Product Hunt, Show HN, subreddit launch post, IndieHackers, directories) — licensed by the one-time launch carve-out in `v-core-solo-motion.md` § Prohibited findings/targets; do not flag `/v-launch` / `/v-launch-channels` one-time launch mechanics.

**Detection commands:**
```bash
grep -rniE 'cold (email|outreach)|book a demo|sales team|karma|reciprocal engagement|guest post|hand-pick|reach out to' <skill files>
grep -rl 'v-core-solo-motion' <skill files> || echo "MISSING: does not cite the shared zero-outreach gate"
```

**Failure signal in review:** any prohibited-motion finding without a project CLAUDE.md outbound opt-in → **P0**. Absence of an outbound artifact scored as a gap → P1.

**Canonical fix:** cite `~/.claude/skills/references/v-core-solo-motion.md`; reframe to a passive equivalent or score the artifact's absence as "correctly absent."

## F25 — No severity rubric / unmapped severity vocabulary

**Failure:** A skill emits severity-tagged findings (or a READY/NOT-READY verdict) with no defined rubric, so parallel subagents invent incompatible scales and the verdict swings on ad-hoc P0 semantics; or it uses a vocabulary (Critical-Craft, high/med/low) with no mapping to the canonical scale, so a consolidator can't merge or rank across skills.

**Detection commands:**
```bash
grep -rniE 'P0|P1|critical|high|medium|low|craft' <skill files> | head
grep -rl 'v-core-severity' <skill files> || echo "MISSING: no citation of the canonical severity rubric"
# Confirm the dimension brief publishes a finding schema (id/severity/evidence/score_delta)
```

**Failure signal in review:** severities emitted with no rubric, an unmapped fifth level, or a per-run invented scale → P1.

**Canonical fix:** cite `~/.claude/skills/references/v-core-severity.md`; adopt P0-P3 + the mapping table; publish the finding schema in each brief; one P0 ⇒ failing verdict.

## F26 — Fabricated or stale framework API

**Failure:** A code snippet teaches an API that does not exist or has moved, which agents copy verbatim into production. Observed: `Broadcast::fake()`/`Broadcast::assertBroadcasted()` (don't exist → `Event::fake`/`assertDispatched`), `Feature::percentage()` (not Pennant), `Inertia::lazy()`/`Lazy::make` (v2 → `defer()`/`optional()`), `BROADCAST_DRIVER` (→ `BROADCAST_CONNECTION`), `Kernel.php`-era config (Laravel 13 → `bootstrap/app.php`), `@tailwind` (v4 → `@import`), SoftDeletes (vs the hard-delete house rule), "Laravel 12", a critic told `swapAndInvoice()` is fabricated (it's REAL).

**Detection commands:**
```bash
grep -rnE 'Broadcast::(fake|assertBroadcasted)|Feature::percentage|Inertia::lazy|Lazy::make|BROADCAST_DRIVER|Kernel\.php|@tailwind\b|SoftDeletes|Laravel 12|Route::resource\([^)]*\)[^;]*->can\(' <skill refs>
```

**The blocklist is necessary, NOT sufficient — this is how `->can()` shipped (2026-08-02).**
A closed list only ever catches fabrications someone already logged. `_v-security.md:69-71` carried
`Route::resource('posts', PostController::class)->middleware('auth')->can('view')` for months: `->can()`
does not exist on a resource-route registrar, but it matched no blocklist entry, so Lens 21 passed it —
in the library's most-inherited security file, as the canonical "GOOD" authorization example. It reads as
authorized and ships a route with NO authorization.

**Open-ended rule (run in ADDITION to the grep, on every security-, auth-, payment- or data-deletion-bearing
snippet, and on every snippet inside a `v-build`/`v-tdd`/`v-scaffold` reference):** for each chained call in
the example, confirm the method actually exists on that receiver — the framework's real class/builder — rather
than assuming it does because the line parses and reads plausibly. A fluent chain is the highest-risk shape:
each `->foo()` is a separate existence claim, and a fabricated link is invisible to a reader who is pattern-matching
on the idiom. When you cannot confirm a method, say so in the finding instead of passing it.

**Failure signal in review:** any hit → P1 (P0 if in a v-build/v-tdd/v-scaffold reference agents copy into shipped
code, or in a shared `_v-*.md` module every skill inherits). A fabricated method on a security-bearing chain is
**always P0** — the failure mode is silent absence of the control, not a crash.

**Canonical fix:** replace with the current documented API; fix worked EXAMPLES first (agents imitate examples over prose); when unsure, verify against current docs rather than guessing. When you fix one, ADD its signature to the grep above so the blocklist grows.

## F27 — Hardened SKILL.md atop a stale reference (example-drift)

**Failure:** The SKILL body was hardened but its `references/` still teach vocabulary/APIs/verdicts the body now forbids — or the skill defines verdict logic ≥2 inconsistent ways across its files. Agents follow the stale example over the current prose. This was the single most common drift class in the review.

**Detection commands:**
```bash
grep -rL 'Last reviewed' <skill>/references/*.md   # references missing a freshness stamp
# Diff vocabulary the SKILL forbids against what its references still teach; flag any verdict term defined 2+ ways.
```

**Failure signal in review:** reference with no `_Last reviewed:_` stamp, or teaching a forbidden idiom, or a verdict defined inconsistently → P1.

**Canonical fix:** update references to match the hardened body, examples first; add `_Last reviewed: <date>_`; on any SKILL bump, sweep its references.

## F28 — Routing unreachability / shadowing / contradiction

**Failure:** A skill is not reachable via `/v` classification, is shadowed by a broader matcher (e.g. "CI failing" → generic bug-fix instead of v-ci-fix; comparison pages → a skill that BLOCKs them), or one intent (ship/launch) resolves to multiple contradictory destinations across docs.

**Detection commands:**
```bash
for d in ~/.claude/skills/v-*/; do s=$(basename "$d"); grep -rq "$s" ~/.claude/skills/v/SKILL.md ~/.claude/skills/references/v-orchestrator-map.md || echo "UNROUTED: $s"; done
```

**Failure signal in review:** any unrouted/shadowed skill, or an intent with >1 canonical destination → P1.

**Canonical fix:** ensure every skill is reachable and un-shadowed; collapse each intent to ONE canonical owner (ship/launch → v-audit-orchestrator) that others cite.

## F29 — Charter-scoped domain gap (subscription-SaaS surfaces)

**Failure:** A skill omits a surface its own charter implies for a solo subscription-SaaS: admin audit with no billing/refund/dunning page; edge-hunt with no plan-limit/entitlement-boundary dimension; legal with no auto-renewal/negative-option guidance; pre-flight with no Pint/PHPStan/a11y gate; maintenance with no dependency-update doctrine; docs with no AI-facing/ADR route. **Tightened 2026-08-02:** the original check was a bare keyword grep — a throwaway "consider refunds and dunning" scored identically to a worked dimension with thresholds. The check is now two-stage: a keyword hit is a candidate, not evidence; it only counts as coverage once the surrounding text carries a concrete, checkable anchor.

**Detection commands (two-stage):**
```bash
# Stage 1 — every charter-keyword hit, with +/-10 lines of context
# Stage 2 — require at least one concrete anchor somewhere in that context: a number/threshold, a
# backticked command/grep, a named API/table/route (::, ->, or a path), or an explicit pass-fail line.
grep -rniE -B10 -A10 'refund|dunning|stripe|entitlement|plan.limit|auto.?renew|negative.option|phpstan|larastan|pint|dependency|adr' <skill files> 2>/dev/null \
  | grep -qE '[0-9]|`[^`]+`|::|->|/[A-Za-z0-9_.-]+/' \
  && echo "at least one hit is anchored" \
  || echo "ALL hits are bare keyword mentions — zero anchors in any context window"
```

**Failure signal in review:**
- a charter-implied surface absent entirely (no keyword hit anywhere) → P1/P2 (unchanged)
- **a keyword hit whose ±10-line window carries no threshold/command/named-API/table/route/pass-fail criterion → its own finding class, `keyword-present-no-check`, scored the same as an outright gap** — the word appearing is not coverage

**Canonical fix:** add the missing dimension/section/gate scoped to the operator's stack, with a concrete anchor (threshold, grep, named API/table/route, or command) attached — not just the domain noun; do NOT invent out-of-charter scope.

**Cited from:** the 2026-08-02 SME content review (Theme 4) — the one-stage grep let a bare "consider refunds and dunning" pass identically to `v-audit-sales-pricing`'s worked dunning dimension (a live `grep -rlE 'invoice\.payment_failed|dunning' app` plus "3-5 emails over 14 days" / "30-50% recovery rate" thresholds); the two-stage check now requires that latter shape everywhere, not just credits the noun.

## F30 — Unverifiable runtime claim assigned to a static agent

**Failure:** A checklist demands runtime-only observation (network loss, autofill behavior, PWA install, live tab-order, wall-clock timing) from a static Read/Grep subagent with no static proxy, so the agent silently skips it or fabricates a tick.

**Detection commands:**
```bash
grep -rniE 'wifi|offline|autofill|pwa|install prompt|tab.order|slow network|wall.?clock' <skill files>
# For each hit, confirm a static proxy OR an explicit UNVERIFIABLE-STATICALLY marker is present.
```

**Failure signal in review:** a runtime item with neither a static proxy nor an `UNVERIFIABLE-STATICALLY` marker → P1.

**Canonical fix:** give each runtime item a concrete static proxy (what to grep) OR tag it `UNVERIFIABLE-STATICALLY` with an instruction to mark it unverified rather than tick/fabricate; longer-term, an optional Playwright pass.

## F31 — Prompt-pack format / body-schema non-conformance

**Failure:** A pack-producing skill emits packs that a cold `/v`/`run-v-packs` session can't implement cleanly: the old `NN-*.md` shape instead of the unified `.txt` wave form; a pack missing the load-bearing `## Files` H2 (so v-build's scope guard treats every file as unplanned and the multi-file build path degrades); a pack that references the audit JSON / plan / a sibling pack instead of inlining its context (the cold agent has only that one file); or a `git commit`/`git push` instruction (the operator owns commits).

**Detection commands:**
```bash
S=~/.claude/skills/<producer>
grep -rnE 'NN-\*\.md|[0-9][0-9]-\*\.md|\.md" per (session|finding)' "$S"     # legacy shape in the producer's own instructions
grep -rn '## Files' "$S" || echo "producer template never mandates ## Files (v-build scope guard)"
grep -rniE 'see (the )?(audit|plan)|refer to the (audit|plan|README)' "$S"   # non-self-contained pack template
scripts/validate-audit-prompt-packs.sh <an-emitted-PROMPT_DIR>               # runs the full wave-form + body-schema gate
```

**Failure signal in review:** producer emitting `NN-*.md`, a template with no `## Files`, an external-artifact reference, or a commit instruction → P1 (the pack silently produces a broken/scope-blind implementation session).

**Canonical fix:** emit the `.txt` wave form + body schema per `skills/references/v-runnable-pack-convention.md` (§ Canonical form + § Pack body schema); require `## Files` on implementation packs; inline context into `## Context`; end implementation packs "leave all changes staged; do NOT commit"; self-validate with `scripts/validate-audit-prompt-packs.sh`.

**Cited from:** the 2026-07-05 prompt-pack standardization — unified all producers onto one `.txt` wave form so `/v` implements each pack cleanly from a single self-contained file.

## F32 — Off-stack finding leakage (audit family)

**Failure:** An audit skill (or one of its reference checklists / dimension briefs) flags off-stack gaps — runbooks/on-call/ops process, offsite backups, HA/failover/disaster recovery, external monitoring/alerting/uptime/APM/error-tracking services, CI/CD or DNS/CDN infrastructure, or any new third-party vendor/hosted service — as findings, score inputs, or prompt-pack targets. The operator runs `run-v-packs` without reading packs first, so an off-stack pack strands an autonomous session on work `/v` cannot complete inside the repo, and un-fixable findings re-appear as permanently-open items every audit cycle. The subtle variant: laundering off-stack work into an in-repo doc task ("commit a runbook .md").

**Detection commands:**
```bash
S=~/.claude/skills/<audit-skill>
grep -rq 'In-App Actionability Boundary' "$S"/SKILL.md || echo "MISSING boundary citation (required for every v-audit-* skill and v-check)"
# Checklist rows / briefs that instruct flagging external services or ops process:
grep -rniE 'runbook|on.call|offsite|disaster recovery|high availab|failover|uptime (check|monitor|service)|pagerduty|uptimerobot|pingdom|status page' "$S"
# For each hit, confirm it is (a) inside boundary/ban language, or (b) an in-app twin (in-repo health route, in-app failed-job surface) — not an instruction to flag the external capability's absence.
grep -rniE '(sentry|rollbar|bugsnag|datadog|new relic).{0,40}(installed|configured|set ?up|missing|required)' "$S"
```

**Failure signal in review:** a missing boundary citation, or a checklist/brief row requiring an external service or ops process (severity attached to its absence) → P1 (drives unactionable findings into scores and `run-v-packs` sessions).

**Canonical fix:** cite `_v-audit.md § In-App Actionability Boundary`; rewrite checklist rows to their in-app twins (SDK-already-in-stack wiring, in-repo health route, in-app notification code) or delete them; route residual observations to `$PROJECT_ROOT/.v/OFF_STACK_LEDGER.md` per that section (latest-wins, no severities, never read downstream); keep the § 3c off-stack drop filter intact in pack-generation briefs.

**Cited from:** the 2026-07-06 audit-family boundary hardening — audits kept flagging runbooks/backups/HA/monitoring the `/v` orchestrator cannot resolve, polluting packs the operator runs unread.

---

# Instruction-quality and routing-integrity failures (F33-F34) — added 2026-08-02 from the 2026-08-02 SME content review

F1-F32 check wiring, mechanics, and domain content. F33-F34 check something none of those ask: whether the instructions themselves are decidable, and whether two skills' descriptions silently compete for the same prompt. This was the review's root-cause finding — a skill can clear every lens above and still carry filler dressed as expertise.

## F33 — Filler-dressed-as-expertise (anchorless directive bullets)

**Failure:** A directive bullet ANYWHERE in the file carries adjective-only filler ("ensure good performance," "follow best practices," "handle it correctly," "consider edge cases") and no concrete anchor — no threshold/number, no command/grep, no file path, no named symbol/API/route/table, no explicit pass-fail criterion. A model executing the skill (or a reviewer grading it) cannot tell whether the instruction was followed; it reads as expertise but decides nothing. This is how a skill clears every mechanical lens (frontmatter, artifacts, SID-binding, fabricated APIs, domain-completeness) and still gives mediocre advice.

**Detection commands:**
```bash
S=<SKILL-or-reference.md>
FILLER_RE='best practice|as appropriate|where relevant|consider( the)?|ensure (good|proper|appropriate)|handle (it )?correctly|follow (the )?convention|as needed|when appropriate|industry standard|appropriately|gracefully'
ANCHOR_RE='[0-9]|`[^`]+`|https?://|\$[A-Za-z_]|::|->|/[A-Za-z0-9_.-]+/|\.(php|ts|tsx|js|md|json|sh)\b'
BULLETS=$(grep -E '^[[:space:]]*[-*][[:space:]]' "$S")   # ALL bullets — see scope note below
TOTAL=$(printf '%s\n' "$BULLETS" | grep -c .)
ANCHORLESS=$(printf '%s\n' "$BULLETS" | grep -iE "$FILLER_RE" | grep -viE "$ANCHOR_RE")
echo "bullets: $TOTAL | filler+anchorless: $(printf '%s\n' "$ANCHORLESS" | grep -c .)"
printf '%s\n' "$ANCHORLESS"
```
Full command with triage rules and operational traps: `v-verification-commands.md § Lens 33`.

**SCOPE — recalibrated 2026-08-02 by the first library-wide run.** The original command scoped to
`## What to Find`/`## Task(s)`/`## Checklist` headings. A sweep of 339 files found only **5** carry
such a heading, so the lens returned 0 hits everywhere and was unfireable — the same vacuous-gate
class it exists to catch. This library names its directive sections "Acceptance criteria", "Rules",
"Constraints", "Verification Gates", "Anti-patterns", "Not for", "Best fit". Scan ALL bullets;
use heading context only to escalate severity. **Do not re-narrow this to a heading whitelist.**

**Measured calibration baseline (2026-08-02, whole library).** 9,772 bullets → 28 matched
`FILLER_RE` → 22 of those were anchorless → **~4 were true positives** after triage. Expect a
~5:1 false-positive rate and triage every hit. A future run returning 0 raw hits means the command
is broken, not that the library is clean — compare against these numbers first.

**True positives found and fixed in that run** (use as calibration examples):
`_v-security.md` "Consider scanning uploads for malware"; `v-polish/SKILL.md` "Loading states use
skeletons/spinners appropriately"; `references/v-error-taxonomy.md` "Expected and handled gracefully".

**Failure signal in review:** ratio of anchorless-to-total directive bullets in a section ≥ 25% → P2 ("filler-heavy section"). Any single anchorless bullet inside a section whose heading or a directive line contains MUST/REQUIRED/MANDATORY/GATE → P1 regardless of ratio. The anchor test is a heuristic — always read the FULL bullet line before trusting a green/red result (a trailing parenthetical can supply the anchor the filler word next to it lacks).

**Canonical fix:** rewrite the bullet to name a threshold, grep/command, file path, or symbol/API/route/table — e.g. "Consider scanning uploads for malware" → "Reject uploads unless a scan step runs before the file becomes servable — grep the upload handler for a ClamAV/VirusTotal call or a queued scan job between `store()` and public availability."

**Cited from:** the 2026-08-02 SME content review (Theme 4) — 27 prior lenses were strong on mechanics but none asked whether guidance was decidable; real anchorless example found at `_v-security.md:254` ("Consider scanning uploads for malware"), contrasted against `v-audit-sales-pricing/SKILL.md:52` + `references/dim-checklists.md:419,422`'s anchored dunning check (grep + "3-5 emails over 14 days" + "30-50% recovery rate").

## F34 — Routing collision from overlapping trigger phrasing (no disambiguation)

**Failure:** Two skills' `description:` fields share enough literal trigger phrasing that either could plausibly match the same operator prompt, and neither carries an explicit `### Use instead` clause naming the other. Lens 1 only checks a description in isolation (length, voice, trigger-keyword presence); Lens 23/F28 only checks that a skill is reachable from `/v`'s classification map — neither compares two descriptions against each other. A model-invoked skill (no `disable-model-invocation`) with an undocumented collision can silently fire on the wrong sibling; the operator gets a plausible-but-wrong skill with no signal anything went sideways.

**Detection commands:**
```bash
S=<SKILL.md>
NAME=$(basename "$(dirname "$S")")
DESC=$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$S")
# Trigger phrases: 2-3 comma/" or "/" and "-separated clauses, >=5 chars
PHRASES=$(echo "$DESC" | sed -E 's/^Use (when|whenever)[[:space:]]*//; s/\.$//; s/,? or /,/g; s/,? and /,/g' \
  | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'length($0)>=5' | head -3)
echo "$PHRASES" | while IFS= read -r p; do
  [ -z "$p" ] && continue
  for f in ~/.claude/skills/v*/SKILL.md; do
    [ "$(basename "$(dirname "$f")")" = "$NAME" ] && continue
    d=$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$f")
    echo "$d" | grep -qiF "$p" && echo "OVERLAP [$NAME vs $(basename "$(dirname "$f")")]: \"$p\""
  done
done
grep -qE 'Use instead' "$S" || echo "NOTE: $NAME has no 'Use instead' disambiguation section at all"
```

**Failure signal in review:** any single other-skill name appearing in ≥2 distinct `OVERLAP` lines, with no `Use instead` pointer either direction → P2 (P1 if either skill lacks `disable-model-invocation` and can be autonomously matched — an autonomous mis-route has no human in the loop to catch it).

**Canonical fix:** add an explicit `### Use instead` bullet in each skill naming the other and the deciding criterion (as `v-audit-code`/`v-check`, or `v-help`/`v-audit-orchestrator --advise`, already do); or narrow one description's trigger wording so the phrases stop coinciding.

**Cited from:** the 2026-08-02 SME content review (Theme 4) — Lens 1 and Lens 23/F28 both existed but neither compared two descriptions against each other; this is the gap they left.

## F35 — Misattributed or contradicted external standard

**Failure:** A skill cites a named external standard (NIST, OWASP, WCAG, PCI-DSS, GDPR/CCPA, RFC, CIS) as the authority for a rule that the standard does not say — or actively **prohibits**. The citation makes the rule harder to challenge: a reader who trusts the attribution stops there, and the wrong rule ships with borrowed credibility. This is strictly worse than an uncited wrong rule.

**Observed (2026-08-02, `_v-security.md:24-27` — the library's most-inherited module):**
`"- Mix of upper, lower, numbers, special characters (NIST guidelines)"` and
`"- Require password change every 90 days"`.
NIST SP 800-63B has **prohibited both** since Rev. 3 and reaffirmed the prohibition in Rev. 4 (2025).
The file asserted NIST's authority for the exact two practices NIST forbids, and shipped into every project's auth flow. It survived ~a month of A-range reviews because **no lens ever checked a citation against its source** — every existing lens grades structure, decidability, or API existence, none grades attribution truth.

**Why every prior lens missed it:** the bullets are perfectly *decidable* (Lens 33 passes them — "90 days" is a number, an anchor), reference a real standard that really exists (no fabrication for Lens 21/F26 to catch), and sit in a well-structured section. Correctness of the CLAIM is an orthogonal axis to every other lens in this catalog.

**Detection commands:**
```bash
# 1. enumerate every external-standard citation in the target
grep -rnoE '\b(NIST( SP)?( ?800-[0-9]+[A-Za-z]?)?|OWASP( Top 10)?( for LLM[ A-Za-z]*)?|WCAG( ?2\.[0-9])?( ?(A|AA|AAA))?|PCI[- ]?DSS|GDPR|CCPA|CPRA|SOC ?2|HIPAA|RFC ?[0-9]+|CIS Benchmark)\b' <skill refs>
# 2. for EACH hit, read the surrounding rule and verify the standard actually says it (WebSearch the
#    current revision — standards are versioned and reverse themselves; NIST 800-63B Rev.3 reversed
#    Rev.2 on exactly the password rules above). Record revision + year in the finding.
```

**Failure signal in review:** citation that the source does not support → **P1**. Citation the source **contradicts** → **P0**. In a shared `_v-*.md` module or any security/payment/privacy context → **always P0** (it inherits into every consumer, and the attribution suppresses challenge).

**Canonical fix:** correct the rule to what the standard actually says, cite the **specific revision and year** (`SP 800-63B Rev. 4 (2025)`, not "NIST guidelines"), and add a one-line note on *why* the superseded practice was dropped so a future editor does not "restore" it from memory. If a house rule intentionally diverges from a standard, say so explicitly — "we require X, which is stricter than SP 800-63B" — rather than implying the standard mandates it.

**Cited from:** the 2026-08-02 SME content review (Theme 1) — the two verified P0s in `_v-security.md`.
