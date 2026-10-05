# Subprocess Dispatch (Fork-Compatible) — Steps 2 and 7

## Why not the Agent tool (W-fork-fix)

This skill runs `context: fork`, i.e. it IS a subagent, and a forked skill CANNOT dispatch
further subagents via the Agent tool (Claude Code platform limit — the same constraint `/v`
documents; re-verified 2026-05-24 on 2.1.150). The call fails or silently degrades to inline
execution in this fork's ALREADY-CONSUMED context — losing the context isolation the design relies on ("by the time prompt generation happens,
the main context has consumed 50k-200k+ tokens... inline generation will truncate or skip
files" — `v-core-prompt-pack.md`). Bash works from a fork, and a `claude -p` subprocess is an
independent process with its own context and model. That is the dispatch mechanism for BOTH
worker steps. Never use the Agent tool from this skill.

## Step 2 — parser subprocess (model: the operator's, resolved)

**Model resolution (do this ONCE, before either subprocess below).** Both workers here call
`claude -p` DIRECTLY rather than through the helper, and the CLI **rejects** a literal
`--model parent` (`"parent" is not a model this version of Claude Code recognizes"`, rc 1) — the
resolver lives inside the helper. So resolve first, reusing that same resolver instead of keeping
a second copy of the precedence rules that would drift:

```bash
export V_MODEL_POLICY_OVERRIDE=1   # see ~/.claude/skills/references/v-audit-parent-model.md
AUDIT_MODEL="$(~/.claude/skills/v/references/v-dispatch-subagent.sh --model parent --print-resolved-model)" || {
  echo "model resolution failed (sonnet-max gate — is V_MODEL_POLICY_OVERRIDE=1 exported?)" >&2; exit 2; }
```

`--print-resolved-model` applies `enforce_model_policy()` before printing, so these raw sites
inherit the identical gate contract as a helper dispatch — they cannot become a hole in the
allowlist. Both workers below use `"$AUDIT_MODEL"`.

Stage the full parser prompt (SKILL.md Step 2 template, real report paths substituted) to a
file, then ONE Bash call:

```bash
V_TMP="$PROJECT_ROOT/.v/tmp"; mkdir -p "$V_TMP"
PARSE_PROMPT="$V_TMP/consolidate-parse-prompt-${CLAUDE_SESSION_ID}.txt"   # full prompt staged here first
PARSE_OUT="$V_TMP/consolidate-parse-${CLAUDE_SESSION_ID}.json"
# --allowedTools "Read" is MANDATORY: headless `claude -p` auto-denies every tool not
# explicitly granted (it cannot prompt — v-dispatch-subagent.sh:403). Without Read the
# parser cannot open the reports and may emit schema-valid but FABRICATED findings.
# Prompt arrives via STDIN, never as a positional arg: --allowedTools is VARIADIC and
# swallows a trailing positional prompt (v-dispatch-subagent.sh:423,466-468 + :608).
claude -p --no-session-persistence --model "$AUDIT_MODEL" --allowedTools "Read" \
  < "$PARSE_PROMPT" > "$PARSE_OUT" \
  2>"$V_TMP/consolidate-parse-stderr-${CLAUDE_SESSION_ID}.log"
jq -e '.findings | type == "array" and (.report_verdicts | type == "array")' "$PARSE_OUT" >/dev/null && echo PARSE_OK || echo PARSE_INVALID
```

**Anti-fabrication cross-check (run after PARSE_OK, before Step 3):** every finding's
`source_report` must be one of the discovered report paths, and the per-source finding counts
must be plausible against the Step 1 inventory (a source report with N findings in its own
summary yielding 0 or wildly more parsed findings is a red flag). On mismatch, treat as
`PARSE_INVALID` — schema-valid JSON is NOT proof the reports were actually read.
`report_verdicts` must also cover EVERY discovered report exactly once (one entry per
`source_report`, `source_verdict: null` allowed but the entry itself must not be missing) — a
report present in the Step 1 inventory but absent from `report_verdicts` silently drops that
source from Step 6's verdict aggregation, which is the exact gap this schema field exists to
close. Treat a missing report entry as `PARSE_INVALID` too.

**On `PARSE_INVALID`:** retry ONCE with the jq/cross-check error + the first 20 lines of the
bad output appended to the prompt ("your previous output failed validation: ... Return ONLY
the JSON object"). On second failure, abort the run quoting the raw output — do NOT fall back
to parsing the reports inline in the fork's own context (inline parsing at 50k+ tokens is the
exact truncation failure this dispatch exists to avoid).

## Step 7 — pack-writer subprocess (model: the operator's, resolved)

The main skill computes the wave assignment itself (never delegated), then stages the full
self-contained writer prompt (consolidated findings + per-finding→pack→wave assignment +
SKILL.md sections 7d/7e verbatim) and dispatches:

```bash
WRITE_PROMPT="$V_TMP/consolidate-write-prompt-${CLAUDE_SESSION_ID}.txt"   # full writer prompt, self-contained
# Prompt via STDIN (variadic --allowedTools swallows a trailing positional — see Step 2 note).
claude -p --no-session-persistence --model "$AUDIT_MODEL" --allowedTools "Read,Write" \
  < "$WRITE_PROMPT" \
  > "$V_TMP/consolidate-write-${CLAUDE_SESSION_ID}.log" 2>&1
```

The writer prompt MUST name `$PROJECT_ROOT/$PROMPT_DIR` as the ONLY directory it may write
into. Step 8's self-validate is the acceptance check on its output; on failure, re-dispatch
once with the failure messages as context (SKILL.md Step 8).

**Helper note:** these are generic-prompt workers, not registered `~/.claude/agents/*` agents.
The helper does support a no-agent `--model` dispatch (an earlier version of this note claimed it
"requires `--agent <name>`" — it does not; that is why the `--print-resolved-model` call above
works), but it derives its tool allowlist from agent frontmatter, so these two workers keep their
inline invocations to pin the narrow `--allowedTools` sets they need. The two hardening flags that
matter are mirrored inline above (`--no-session-persistence`, scoped `--allowedTools`). Promoting
these workers to registered agents and switching fully to the helper would add the timeout ceiling
and DISPATCH_PROVENANCE logging for free — worth doing, but out of scope for the model sweep.
