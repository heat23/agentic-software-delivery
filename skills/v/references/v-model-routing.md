# Model Routing — Dispatch Patterns

> **Canonical model assignments:** See `references/v-core-model-routing.md` for the authoritative, complete model routing table (all skills, all tiers). This file covers **dispatch patterns only** — how to actually invoke skills on different models.

## Haiku Skill Dispatch Pattern

**DEPRECATED — superseded twice.** (1) Wave 9 inlined the canonical prompts and moved off sibling `DISPATCH_PROMPT.md` files (sonnet paraphrased them). (2) W-fork-fix (2026-05-24) replaced **Agent-tool dispatch entirely** with `claude -p --agent` SUBPROCESS dispatch, because `/v` runs `context: fork` and a subagent cannot dispatch a subagent via the Agent tool (it fails silently → inline self-review). The Agent() snippet below is retained ONLY as historical context — do NOT use it.

**Current canonical dispatch:** `/v` SKILL.md § Verbatim Dispatch Mechanism → the helper `references/v-dispatch-subagent.sh` runs `claude -p --agent <name> --no-session-persistence --allowedTools <derived from agent frontmatter> --output-format json`. It preserves the agent's frontmatter model pin and read-only tool whitelist, and reports `DISPATCH_MODE=subprocess`.

```
# HISTORICAL — Wave-9-era Agent-tool dispatch. FAILS from /v's fork. Do NOT use.
Agent(model: "haiku", timeout: 600000, prompt: <DISPATCH_PROMPT.md with substitutions>)
```

**Why a helper, not hand-rolled:** Constructing the invocation from scratch produced inconsistent results (some sessions used the wrong model, others timed out from `sleep` commands). The helper + the canonical dispatch prompts encode all critical rules (no sleep, worktree cd, model self-report, capture-mode Write-stripping), so the orchestrator's job is reduced to one Bash call.

**Enforcement note:** `enforce-haiku-dispatch.sh` (PreToolUse/Skill|Agent) historically blocked Skill-tool invocation of haiku skills and auto-corrected the Agent `model` param. With subprocess dispatch the model is pinned by the agent's own frontmatter; the dispatch prompts still instruct `Model: haiku` as the report's first line for traceability.

## Skill Tool Invocations (All Other Skills)

These run inline on the session model. Pass context in `args`:
1. `PROJECT_ROOT=/absolute/path/to/repo`
2. `WORKTREE_PATH=/absolute/path/to/worktree` (if working in a worktree)
3. `[V_DEPTH=1, V_CHAIN=/v→/v-build]` — controls ownership boundary (v-build stops at step 7 when V_DEPTH >= 1)

**Without V_DEPTH, skills like v-build will execute their FULL flow (steps 1-14) instead of stopping at the orchestrator boundary (step 7).** This causes duplicate pre-flight/verify-done runs and wastes tokens.

Example (Skill tool):
```
Skill(skill: "v-build", args: "PROJECT_ROOT=<absolute-project-root> WORKTREE_PATH=<absolute-project-root>/.worktrees/build-feature [V_DEPTH=1, V_CHAIN=/v→/v-build] Implement PLAN_20260317_abc123.md")
```
