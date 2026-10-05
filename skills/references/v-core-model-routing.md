# Model Routing (extracted from _v-core.md)

_Last reviewed: 2026-08-02 (single-source-of-truth sweep: the "Start 3 Opus sessions..." example contradicted the sonnet-max policy stated at the top of this same file by framing Opus as the quality choice for architecture — rewritten sonnet-only, Opus caveated as an explicit per-session operator choice, never a recommendation; prior sweep 2026-07-16)._

> **⛔ SONNET-MAX POLICY (CLAUDE.md Model Policy, 2026-07-07 — overrides every tier below):**
> /v orchestration and ALL gate/review/audit dispatches use **Sonnet 5 + Haiku ONLY**.
> Never `opus` or `fable`, never `[1m]` context variants, as a skill default or an
> escalation. Opus/Fable happen only by explicit per-session operator choice. Any table
> row or example in this file that names `opus` is a HISTORICAL tier reference retained
> for structure — resolve it to `sonnet` at dispatch time. `v-dispatch-subagent.sh`
> enforces this allowlist at the chokepoint (V_MODEL_POLICY_OVERRIDE=1 + explicit
> operator instruction required to pass anything else).
>
> **⚠ AUDIT-FAMILY CARVE-OUT (standing operator instruction, 2026-08-11):** every `/v-audit-*`
> skill dispatches ALL of its subprocesses at `--model parent` — the operator's own session model
> — under `export V_MODEL_POLICY_OVERRIDE=1`. This supersedes the `--model sonnet` fan-out pin
> described in the tables below **for the audit family only**. The gate itself is unchanged: the
> override is the CLAUDE.md "explicit per-session operator choice" lane, it announces itself on
> stderr per dispatch, and nothing outside the audit family gains premium dispatch. Single source:
> `~/.claude/skills/references/v-audit-parent-model.md` — read it before changing any audit
> skill's model routing.

## Model Routing

Claude Code supports model routing at **three levels**: skill frontmatter, Agent tool parameter, and environment variable.

**Model generation (as of 2026-06-30):** the `model:` aliases resolve to the current generation — `opus` → Opus 4.8, `sonnet` → Sonnet 5, `haiku` → Haiku 4.5. Always pass the **alias** (never a pinned dated ID) so dispatches track the latest generation automatically.

### Level 1: Skill Frontmatter (`model:` + `context: fork`)

Skills with `context: fork` + `model:` in their frontmatter are INTENDED to run in an isolated subagent on the specified model. **However, the Skill tool runs skills inline in the main conversation** — it does NOT spawn a subagent. This means `context: fork` and `model:` frontmatter are IGNORED when invoked programmatically via the Skill tool.

**`context: fork` + `model:` ONLY works when the user manually types `/skill-name`.** When the orchestrator chains skills via the Skill tool, they run inline on the session model.

**Key rule:** For skills where model routing matters (cost savings), the orchestrator MUST use the **Agent tool** with an explicit `model:` parameter. This applies to Haiku-configured skills. Other skills run on the session model via the Skill tool — WARNING: the session model is whatever the operator last set via `/model` (may be Fable, which refuses the /v role, or a `[1m]` variant); it is NOT guaranteed to be sonnet. Deep or judgment-heavy skill work is still capped at sonnet — there is no opus escalation lane.

**`model:` frontmatter accepts an `inherit` value (verified live 2026-08-02).** `inherit` means
"run on whatever the operator's session/CLI model is". It is valid ONLY in frontmatter —
`claude -p --model inherit` is rejected by the CLI, so a dispatch site can never forward the
literal string; a dispatch must name a real alias. The two planes are independent and must not
be conflated:

| Plane | Set by | Applies when |
|---|---|---|
| The skill's own model | `model:` frontmatter | ONLY on a manually typed `/skill-name`. Ignored under Skill-tool (orchestrator) dispatch — see Level 1. |
| Its fan-out subprocesses | `--model` / `--agent` at the dispatch site | Always. Enforced by `enforce_model_policy()` (sonnet\|haiku only). |

**Convention (2026-08-02):** the **audit family uses `model: inherit`** so a hand-run audit
honors the operator's chosen model; **coding/implementation skills keep an explicit
`model: sonnet` pin** (v-build, v-tdd, v-new-feature, v-scaffold, v-polish, v-docs) so
implementation work states its intended tier even where the pin is currently inert
(`user-invocable: false` forecloses the only path that would honor it). A pin that cannot fire
is kept deliberately as declared intent — do not "clean it up" without changing the convention here.

**Current model assignments for /v skills (all sonnet-max — the former Opus tier was retired 2026-07-07):**

| Model | Skills | Dispatch |
|-------|--------|----------|
| **Sonnet** (deep/judgment work — formerly the Opus tier, retired by sonnet-max) | v-check, v-audit-admin, v-audit-growth, v-audit-analytics, v-audit-messaging, v-audit-sales-pricing, v-audit-seo, v-audit-consolidate, v-audit-orchestrator, v-audit-code (absorbed v-refactor + v-ui-audit 2026-07-06), v-bug-hunt (both `bugs` and `boundaries` lenses — v-edge-hunt merged in 2026-07-05), v-prelaunch-readiness, v-anti-template-gauntlet, v-content-create, v-tdd, v-new-feature, v-plan | Skill tool (runs inline on session model). **Fan-outs: the `v-audit-*` skills in this row dispatch at `--model parent`, NOT `--model sonnet` — see the audit-family carve-out above. Non-audit skills in this row still pin `--model sonnet`.** |
| **Sonnet** (session model) | v-build, v-polish, v-docs, v-scaffold, v-interactive-showcase, v-merge-all, v-setup-project, interface-design | Skill tool (runs inline on session model) |
| **Haiku** — gate runners (works) | v-pre-flight, v-verify-done, v-handoff | Their SKILL.md frontmatter is `sonnet`; the haiku comes from their **runner agent files** (`agents/v-pre-flight-runner.md`, `v-verify-done-runner.md` = `model: haiku`), reached via `v-emit-prompt.sh <skill>` + Agent dispatch. `enforce-haiku-dispatch.sh` blocks the Skill tool for these three so the haiku split can't be bypassed. Do NOT read the frontmatter as the source of their haiku. |
| **Haiku** — frontmatter pins (work as intended) | v-handoff, v-help, v-session-log, v-build-narrow | Frontmatter `model: haiku` fires on a manually typed `/skill-name` — and for these three that is the ONLY path that reaches them, so the pin does its job. **Verified 2026-08-02:** nothing Skill-tool-invokes `v-help`, `v-session-log` or `v-build-narrow` (zero matches ecosystem-wide), none appear in `/v`'s routing tables, `/v`'s `v-session-log` call was disabled 2026-06-08 ("removed from critical path — run manually"), and `v-build-narrow` has no invoker at all (the wave runner pins its own `--model`). `v-handoff` additionally has hook protection because `/v` *does* dispatch it. **Do NOT add these three to `enforce-haiku-dispatch.sh`'s case list** — Layer 1 blocks the Skill tool and redirects to `v-emit-prompt.sh`, which supports only v-pre-flight/v-verify-done/v-handoff and exits 2 otherwise, so that "fix" would break all three to close a gap that isn't open. An earlier note in this file claimed they "fall through to the session model"; that described a dispatch path nothing exercises. |
| **Inherit (session)** | v (orchestrator only) | Runs inline — no fork |
| **`model: inherit`** (frontmatter) | the audit family — v-audit-admin, v-audit-analytics, v-audit-code, v-audit-consolidate, v-audit-growth, v-audit-messaging, v-audit-orchestrator, v-audit-sales-pricing, v-audit-seo, v-self-audit | Manual `/skill-name` runs on the operator's session/CLI model. Skill-tool dispatch ignores it (Level 1). **Their fan-out subprocesses now inherit the same parent model via `--model parent` (carve-out above) — they are no longer pinned to sonnet.** An `--agent` dispatch still overrides `--model` with the agent file's own pin, so audit skills must not `--agent` a haiku-pinned agent. |
| **Sonnet** (for raw subagents) | Explore agents (codebase pattern discovery) | Agent tool (`model: "sonnet"`) |
| **Sonnet** (for raw subagents) | `framework-pitfall-reviewer`, `v-ux-critique-reviewer` | Agent tool. **Corrected 2026-08-11:** this row previously said Haiku for both and was wrong on both counts — `framework-pitfall-reviewer` has been `model: sonnet` in its frontmatter all along (the row was stale, never enforced), and `v-ux-critique-reviewer` was raised haiku→sonnet by operator instruction. The only remaining haiku agents are the two gate runners in the row above. |
| **Sonnet** — adversarial critic tier (changed 2026-08-02) | the Critic Dispatch step in v-differentiate, v-marketing-design, v-content-create, v-anti-template-gauntlet | `v-dispatch-subagent.sh --model sonnet --mode capture`. **The `v-audit-*` critics (sales-pricing, messaging, seo) moved to `--model parent` on 2026-08-11 per the carve-out above and are no longer part of this row.** Previously haiku; raised because finding-extraction quality outweighs the cost delta and it matches the `codex-adversarial-reviewer` tier the critic stands in for. Single source: `_v-review.md` § Critic Dispatch. |

### Level 2: Agent Tool `model` Parameter

When skills dispatch parallel subagents via the Agent tool, pass the `model` parameter to control each subagent's model:

```
# Code implementation subagent:
Agent(prompt: "...", model: "sonnet")

# Audit/analysis subagent (sonnet-max — never opus):
Agent(prompt: "...", model: "sonnet")

# Simple validation subagent:
Agent(prompt: "...", model: "haiku")
```

The Agent tool `model` parameter takes precedence over the agent definition's `model` frontmatter.

### Level 3: Environment Variable

`CLAUDE_CODE_SUBAGENT_MODEL` globally sets the default model for agents that don't specify one. Set it to route all subagents to a cheaper model: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet`.

### Recommended model tiers for subagent dispatches

| Task Type | Model | Rationale |
|-----------|-------|-----------|
| Deep adversarial / judgment audit subagents (v-bug-hunt's `bugs` + `boundaries` lens dimensions, UI craft + AI-tell judgment, security architecture, pricing/positioning strategy, multi-source synthesis) | `sonnet` (sonnet-max cap; formerly opus) | Multi-step reasoning, taste, race/failure-mode analysis — engage extended thinking |
| Well-scoped structured-extraction audit subagents (schema/config validation, analytics taxonomy, admin checklist, most domain scans) | `sonnet` | Capable + ~1/5 opus cost; pin VERBATIM briefings so directives survive |
| Narrow mechanical scans + validation + adversarial critics | `haiku` | grep/pattern matching, gate spot-checks, finding-extraction critics — ~1/25 cost |
| TDD / test writing subagents | `sonnet` (sonnet-max cap; formerly opus) | Correctness validation |
| Planning / feature design subagents | `sonnet` (sonnet-max cap; formerly opus) | Strategic decisions |
| Standard code implementation subagents | `sonnet` | Fast, capable, ~1/5 cost |
| Content-only subagents (blog, copy, docs) | `sonnet` | No complex reasoning needed |
| Simple validation / gate check subagents | `haiku` | Fast binary pass/fail, ~1/25 cost |

### Mandatory rule: never leave a fan-out subagent unpinned

When a skill dispatches parallel dimension/domain subagents via the Agent tool, **every dispatch MUST carry an explicit `model:` parameter** chosen from the tiers above. An unpinned Agent dispatch silently inherits the session model (or `CLAUDE_CODE_SUBAGENT_MODEL`). This is a correctness hazard in **both** directions:

- A deep-reasoning hunt (v-bug-hunt's `bugs`/`boundaries` lenses, UI craft, AI-tell detection) left unpinned inherits the session model — which may be Haiku (recall loss), or Fable/`[1m]` via the operator's `/model` default (role-refusal no-ops + premium cost).
- A narrow grep scan left to inherit a premium session model burns ~5–25× the necessary cost on every run.

Frontmatter `model:` does NOT solve this — per Level 1 above it is inert under Skill-tool (orchestrator) dispatch. The Agent-tool `model:` parameter on each fan-out dispatch is the only reliable lever. Pin it explicitly at the dispatch site, not just in a summary table.

**For user-dispatched parallel sessions** (e.g., 8 `/v` sessions), the model is set at session creation time. Assign models explicitly per the sonnet-max policy: "Start 8 Sonnet sessions — 3 on architectural/planning work, 5 on implementation." This alone can reduce cost vs. an unpinned default with no quality loss. (Opus is available only as an explicit, session-scoped operator choice for a specific session that genuinely warrants it — CLAUDE.md Model Policy — never framed here as "the quality tier for architecture"; a skill or example recommending Opus as the default for a class of work contradicts that policy.)
