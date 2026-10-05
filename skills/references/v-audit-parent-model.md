# Audit Family — Parent-Model Inheritance (MANDATORY)

_Last reviewed: 2026-08-11 (created — W-PARENT-MODEL-AUDIT: generalized the 2026-08-11 `/v-audit-seo` parent-model instruction to all nine `/v-audit-*` skills, swept 23 `--model sonnet` fan-out sites to `--model parent`, and documented the `--agent` haiku bypass that `--model` cannot reach)._

_Single source of truth for how EVERY `/v-audit-*` skill picks the model for EVERY phase it dispatches. Cited by all nine audit skills; do not restate its rules in a skill body — cite this file._

> **Operator decision, 2026-08-11:** no `v-audit-*` skill may run on Haiku; every audit phase must use the parent-selected model.
>
> Generalized from the 2026-08-11 `/v-audit-seo` decision (all phases of that audit use the parent-selected model, never Haiku) to the whole audit family.

## The rule

Every subprocess an audit skill dispatches — **every dimension, every critic, every prompt-pack
writer, every consolidation worker** — runs on the **operator's own session model**. No phase of
any audit picks its own tier. There is no "this dimension is mechanical enough for a cheap model"
exception; that judgment is the operator's `/model` choice, not the skill's.

This replaces the previous family-wide `--model sonnet` pin at fan-out dispatch sites (swept
2026-08-11). The sonnet-max *policy* is unchanged — see § Why the override below.

## Applying it (helper dispatches — the normal case)

Export this preamble ONCE, before the first dispatch of the run, then use `$V_AUDIT_MODEL` at
every dispatch site:

```bash
# The audit inherits the operator's /model choice. `--model parent` resolves it inside
# v-dispatch-subagent.sh (V_PARENT_MODEL > CLAUDE_CODE_SUBAGENT_MODEL > .model in
# project/user settings > sonnet). The override is the CLAUDE.md "explicit per-session
# operator choice" lane — required because the resolved model may sit outside the
# sonnet-max allowlist, and the resolver deliberately does NOT self-grant it.
# Both facts are announced on stderr per dispatch.
export V_MODEL_POLICY_OVERRIDE=1
V_AUDIT_MODEL="parent"     # every --model in this skill takes this value
```

## Why the override is required, and why it is not a loophole

`--model parent` resolves the operator's model and then **still passes through
`enforce_model_policy()`** (sonnet|haiku only). Verified live 2026-08-11: with `.model` =
`opus[1m]` in `settings.json`, a dispatch without the override exits **2** with the sonnet-max
error — i.e. converting a skill to `parent` *without* exporting the override does not silently
downgrade it, it **hard-fails every dimension**. That is why the export is part of the same
preamble and not an optional extra.

The override is scoped to the audit run and announces itself on stderr per dispatch. It is the
CLAUDE.md "explicit per-session operator choice" lane, now standing for the audit family by
standing operator instruction. The gate itself is untouched: nothing else in `/v` gains premium
dispatch, and an audit run on a sonnet session still resolves to `sonnet`.

## Raw `claude -p` sites (rare — resolve first, never pass the literal)

The CLI **rejects** `--model parent` (`"parent" is not a model this version of Claude Code
recognizes"`, rc 1) — the resolver lives inside the helper, not in the CLI. A site that must call
`claude -p` directly resolves first, reusing the same resolver rather than keeping a second copy
of the precedence rules:

```bash
AUDIT_MODEL="$(~/.claude/skills/v/references/v-dispatch-subagent.sh --model parent --print-resolved-model)" || {
  echo "model resolution failed (sonnet-max gate — is V_MODEL_POLICY_OVERRIDE=1 exported?)" >&2; exit 2; }
claude -p --no-session-persistence --model "$AUDIT_MODEL" ...
```

`--print-resolved-model` applies `enforce_model_policy()` before printing, so a raw site inherits
the identical gate contract as a helper dispatch — it cannot become a hole in the allowlist.

## The `--agent` bypass — the ONE path `--model parent` cannot fix

**`--model` is IGNORED when `--agent` is set.** `claude --agent` uses the agent file's own
frontmatter `model:` pin, and `v-dispatch-subagent.sh` does not pass `--model` alongside it (the
helper prints a `NOTICE:` when a caller's `--model` is overridden this way). So dispatching a
haiku-pinned agent runs **haiku regardless of this entire document**.

Haiku-pinned agents in `~/.claude/agents/` as of 2026-08-11 — **never dispatch one from an audit
skill**: `v-pre-flight-runner`, `v-verify-done-runner`, `v-ux-critique-reviewer`.

Rule for any audit skill that prefers a live specialist agent: before `--agent <name>`, read that
agent file's frontmatter `model:` pin. Use `--agent` **only** if the pin is not `haiku`; otherwise
dispatch the same brief with `--model "$V_AUDIT_MODEL"` and no `--agent`. Re-check the pin rather
than trusting the list above — agent files change.

## Verify, do not assume

After a fan-out returns, read the run's `DISPATCH_PROVENANCE_${CLAUDE_SESSION_ID}.log` and confirm
every `status=ok` row's `submodel=` matches the resolved parent. Report the observed model in the
audit artifact.

## WebSearch's internal haiku — do not misreport it as a substitution

Claude Code's built-in **WebSearch tool calls haiku internally** to process results. That haiku
entry appears in `.modelUsage` for any search-using dimension no matter which model was requested
— it is the tool's own helper, not the audit's reasoning model, and no flag turns it off.

Before 2026-08-11 the dispatcher extracted `submodel` with `jq keys[0]`, which sorts
alphabetically and so reported `claude-haiku-4-5-…` for every WebSearch-heavy dimension; that
produced a **false** "dimensions silently ran on haiku" report on the 2026-08-11
`/v-audit-seo` run. `v-dispatch-subagent.sh` now records the highest-**spend** entry as `submodel=`
and the complete set as `model_used_all` in `DISPATCH_LEDGER.jsonl`. Read the ledger's
`model_used_all` for the full picture; do not re-raise the WebSearch helper as an incident.
