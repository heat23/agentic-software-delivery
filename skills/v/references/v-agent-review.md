# Step 5: Agent Review (extracted from /v SKILL.md)

> Loaded by /v Step 5 ("read this reference before dispatching review agents"). The Verbatim Dispatch Mechanism, Review Model Tiering, AGENT_REVIEW template, post-dispatch wrap, cycle cap, and recovery protocols all live here. Inline /v Step 5 in SKILL.md is the dispatch checklist + the bash that actually runs.

## Step 5: Agent Review

**Mandatory.** Produces `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` with completed-status, codex/superpowers provenance, evidence markers. Stop hook blocks completion if missing/invalid.

**Semantic validity:** AGENT_REVIEW must include all 8 fields verbatim: `Status`, `Agents dispatched`, `Codex adversarial reviewer`, `Reviewer model`, `Hostile adversarial focus`, `Dispatch mode`, `Review evidence`, `Remediation`. Code changed → `Codex adversarial reviewer` must prove codex ran OR superpowers fallback ran OR ORCHESTRATOR_INLINE used. `review_mode: self-review (degraded)` does NOT satisfy the gate.

**Skip condition (ONLY this):** zero code files modified. Check by extension, not classification:
```bash
CODE_FILES=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)$' | head -1)
STAGED_CODE=$(git diff --cached --name-only 2>/dev/null | grep -E '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)$' | head -1)
UNTRACKED_CODE=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)$' | head -1)
```
ANY hit → review mandatory. "Content session" classification does NOT override.

**Dispatch is concurrent, not serial:** the default is the supervised Bash helper (§ Concurrent reviewer dispatch below). Once review dispatch starts, freeze the reviewed diff: do not edit code, clean imports, remove TODOs, or apply formatting until all reviewer children return and their findings are adjudicated. Do NOT parallel verify-done with review — verify-done runs LAST. Skill tool fallback (`superpowers:requesting-code-review`) is synchronous.

**Lever A — the review set may have ALREADY been dispatched at Step 3.4.** On the non-hostile optimistic path (`HOSTILE_REVIEW_REQUIRED=0`), Step 3.4 launches the review set as siblings of the pre-flight runner inside one `v-supervise-children.sh` call (see `v-concurrent-dispatch.md`). When that happened, the reviewers have **already run** by the time control reaches Step 5, writing a **staging** artifact `AGENT_REVIEW_STAGED_${CLAUDE_SESSION_ID}.md` (never the canonical one directly). The fork is mechanical, not remembered:
- **Pre-flight PASSED** → the staged review is provably fresh (diff was frozen since dispatch; a pass means no fix occurred). Promote it: `mv "$PROJECT_ROOT/.v/artifacts/AGENT_REVIEW_STAGED_${CLAUDE_SESSION_ID}.md" "$PROJECT_ROOT/.v/artifacts/AGENT_REVIEW_${CLAUDE_SESSION_ID}.md"`, then **read artifacts** + Post-Dispatch **Wrap** (adjudicate → finalize), mirroring the W55-F1 "skip dispatch, jump to output handling" handoff.
- **Pre-flight FAILED** → the staged review reviewed the pre-fix diff. **DISCARD it** (`rm "$PROJECT_ROOT/.v/artifacts/AGENT_REVIEW_STAGED_${CLAUDE_SESSION_ID}.md"`), apply the fix, then **re-dispatch** the review set against the new (post-fix) diff and write the canonical `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` **fresh**. The gauntlet only ever reads the canonical artifact, so a stale staged review cannot satisfy completion.

On the hostile path Step 3.4 did NOT pre-dispatch, so Step 5 dispatches normally (sequential after pre-flight).

**Dispatch path — supervised concurrent Bash helper is the DEFAULT for selected reviewers (W-perf2/W-cost):**
- **Default (any scope, forked OR inline):** dispatch codex plus only the reviewers selected by changed-file/risk routing through `references/v-supervise-children.sh`. It runs selected children concurrently, blocks until every child exits, preserves per-child logs/status, retries transient failures once, and writes fallback artifacts when enabled. **Never hand-roll raw `cmd & cmd & wait` blocks for reviewer/gate fan-out** — production transcripts showed one failed parallel tool call can cancel sibling output and burn retry turns. The supervisor keeps the latency win while making partial failure deterministic without broadening the review set beyond the scoped routing decision.
- **Foreground Agent-tool dispatch is a FALLBACK only** — use it solely when the Bash helper is genuinely unavailable AND there is a single reviewer (`run_in_background: false`; it also lands the artifact before completion). NEVER use fire-and-forget `run_in_background: true` on a <10-turn session: that path — and ONLY that path — races the stop hook, which is the hazard the old rule actually guarded against.
- ANY worktree session, regardless of scope → wait for worktree commit checkpoint BEFORE codex dispatch (codex sees empty diff on uncommitted worktrees and produces phantom results — see Pre-commit codex anti-pattern below).

**Pre-commit codex anti-pattern (worktrees):** dispatching codex on a worktree branch BEFORE committing produces empty diff → phantom result → ORCHESTRATOR_INLINE fallback wastes the dispatch entirely. Verify before dispatch:
```bash
[ "$(git -C "$WORKTREE_ABS_PATH" rev-list --count "${BASE_SHA}..HEAD" 2>/dev/null || echo 0)" -gt 0 ] || \
  { echo "ERROR: worktree has no commits yet — defer codex dispatch until checkpoint commit"; exit 1; }
```

**Strict input manifest — codex scope MUST be bounded (item 7, 2026-06-01):**

Codex context must be limited to: (1) the diff files, (2) immediate callers/importers of changed files, (3) explicit `reviewer_scope` entries from `/v` Step 1.6. Passing the full codebase context causes 200k+ token codex inputs for 4-file changes (observed in one session: ~350k codex tokens for a 4-file diff). Build the manifest explicitly:

```bash
# Diff files
DIFF_FILES=$(git -C "$WORKTREE_ABS_PATH" diff --name-only "${BASE_SHA}..HEAD" 2>/dev/null | grep -E '\.(php|ts|tsx|js|jsx|vue|svelte)$')
# 1-hop callers (files that import/use any changed file) — bounded to avoid bloat
CALLER_FILES=""
for f in $DIFF_FILES; do
  basename_f=$(basename "$f" | sed 's/\..*//')
  CALLER_FILES="$CALLER_FILES $(grep -rl "$basename_f" "$WORKTREE_ABS_PATH/app" "$WORKTREE_ABS_PATH/resources" 2>/dev/null | head -5)"
done
CODEX_MANIFEST=$(printf '%s\n%s' "$DIFF_FILES" "$CALLER_FILES" | sort -u | head -30)
# Token budget guard: if manifest > ~40 files, trim to most-changed files only
_manifest_count=$(printf '%s\n' "$CODEX_MANIFEST" | grep -c .)
[ "$_manifest_count" -gt 40 ] && CODEX_MANIFEST=$(git -C "$WORKTREE_ABS_PATH" diff --name-only "${BASE_SHA}..HEAD" | head -20)
```

Pass `$CODEX_MANIFEST` as the file list in the codex prompt. Never feed an entire directory tree as context.

**Decision tree (execute exactly):**

```
0. Compute HOSTILE_FOCUS first (see § Hostile-Context Preamble below) — its value
   determines which model the codex review runs on.
1. Resolve REVIEW_MODEL via the model-tier rule (see § Review Model Tiering below).
   Default: sonnet (quality floor; 2026-06-17 cost-tier decision). Billing/payment hostile: sonnet — the Tier-1 risk gate remains, capped at sonnet (2026-07-07 sonnet-max decision: reviews run ONLY on sonnet/haiku).
2. **PRIMARY — codex via Bash (fork-compatible; W-fork-fix).** `/v` usually runs `context: fork`, and a forked skill CANNOT dispatch subagents (Claude Code: *"subagents cannot spawn subagents"*) — so dispatching the codex-adversarial-reviewer AGENT via the **Agent tool will FAIL from `/v`** and silently drop you to inline review (production bug, two sessions: every review ran `orchestrator-inline` because of this). **Codex does NOT need the Agent tool — it is a CLI.** Invoke it DIRECTLY via Bash, which works from a fork:
     → Run from the repo root (must be a codex-trusted dir — the user's repos are trusted; add `--skip-git-repo-check` only if needed).
     → **ALWAYS pass an explicit model with a fallback:** try `gpt-5.3-codex` first; if it exits non-zero, retry with `gpt-5.5` (see the supervisor snippet below — the `||` retry handles this automatically). Do NOT rely on the global codex config default. `gpt-5.5` is currently the verified-working model; `gpt-5.3-codex` is failing but kept as the first attempt since that may change per account/region.
     → **ALWAYS redirect stdin from `/dev/null`** (the `</dev/null` above) OR pipe the prompt via stdin with a `-` prompt arg. `codex exec` reads its prompt from a positional arg BUT, if stdin is an open pipe that never EOFs, it blocks on `Reading additional input from stdin...` and hangs the whole gate (observed 2026-05-24 when codex was launched without a stdin redirect). `</dev/null` gives an immediate EOF and is the safe default.
     → Feed the diff + the hostile review prompt per `_v-review.md § Agent Dispatch Protocol`; capture candidate findings; adjudicate at step 3.
     → AGENT_REVIEW provenance on success: `Agents dispatched: codex-adversarial-reviewer (codex CLI via Bash)`; `Codex adversarial reviewer: ran — N candidates, N accepted, N rejected`; `Dispatch mode: foreground`. (This is a REAL cross-model independent review — `Dispatch mode` is NOT `orchestrator_inline`, so the W59-F2 hostile-inline gate correctly does not fire.)
   **FALLBACK CHAIN (model retry first, then binary-missing chain):**
   - **Model retry (automatic via `||`):** if `gpt-5.3-codex` exits non-zero, the `||` in the supervisor child re-runs with `gpt-5.5`. This happens within the codex step — no fallback chain needed if the retry succeeds.
   - **Full chain (only if the `codex` binary is missing OR BOTH models exit non-zero):**
     → IF `/v` is NOT forked AND codex-adversarial-reviewer.md exists: synchronous Agent tool dispatch, model:"$REVIEW_MODEL". Do not set `run_in_background:true`; if multiple reviewers are needed, use `v-supervise-children.sh` instead.
     → ELSE Skill("superpowers:code-reviewer") (synchronous; runs INLINE on session model, typically sonnet); if "Unknown skill", try Skill("superpowers:requesting-code-review").
     → ELSE ORCHESTRATOR_INLINE (LAST resort — no cross-model independence): orchestrator reads every changed file, conducts adversarial review on the full diff, writes findings into AGENT_REVIEW with provenance `codex-adversarial-reviewer (orchestrator-inline fallback)`. Flag explicitly that independence was lost.
       **Artifact path (W1-A production bug — CRITICAL):** write to `$(bash "${CLAUDE_SKILL_DIR}/references/v-artifact-dir.sh" 2>/dev/null || echo "${REPO_ROOT}/.v/artifacts")/AGENT_REVIEW_${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID}}.md` using the **full UUID**. Two forbidden patterns that break stop-hook artifact discovery: (a) writing to `.claude/AGENT_REVIEW_<slug>.md` (`.claude/` is the project config dir, not the artifacts dir); (b) truncating the UUID to the 8-char SID slug — the slug is for display/branch names only; stop-hook `find_session_artifact` globs for the full UUID pattern `*<full-UUID>*.md` and will not match a short slug file.
3. Adjudicate ALL findings (critical→low). Three verdicts only: ACCEPT (fix now, re-run /v-pre-flight),
   MODIFY (fix with adjustments now), REJECT (document proof in artifact). No DEFER.
   **SEVERITY-DOWNGRADE DISCLOSURE (mandatory — never silently lower an independent reviewer's severity).**
   You may re-rate a finding's severity during adjudication, but if your final severity is LOWER than the
   severity the independent reviewer (codex / superpowers / a dispatched sub-agent) assigned, you MUST record
   the downgrade explicitly in the artifact: `<finding-id>: codex rated CRITICAL → adjudicated HIGH — <reason>`.
   The reason must be concrete and codebase-grounded (e.g. "guard exists at X:NN", "unreachable because Y"),
   not a bare assertion. A reviewer's CRITICAL that you report as HIGH (or drop to LOW as "latent") without a
   stated, checkable reason is FORBIDDEN — it hides the strongest independent signal from the operator
   (observed 2026-05-25: a reviewer rated a concurrency race CRITICAL and a unit-scale mismatch HIGH; the consolidated
   report silently showed them as HIGH and LOW with no disclosed rationale). When in doubt, keep the
   reviewer's higher severity. Upgrades need no disclosure; only downgrades do.
4. Cycle-2 re-review (mandatory when ACCEPT/MODIFY fixes applied): re-dispatch on ONLY the files
   changed by fixes. Same adjudication. Max 2 cycles. If cycle 2 still flags same issue → stop and report.
5. AFTER all cycles complete: proceed to Step 6 (verify-done).
```

### Concurrent reviewer dispatch (W-perf — independent reviewers run in PARALLEL)

The per-file-type sub-agent reviewers (`logic-reviewer`, `codebase-fit-reviewer`, `framework-pitfall-reviewer`, `security-reviewer`) and the codex adversarial pass are **independent and read-only** — none depends on another's output, and none mutates the tree. Dispatching them **sequentially** makes the agent-review phase the session's dominant latency (observed 2026-05-25: ~18 min wall-clock = 4 reviewers + codex run one-after-another, when the real cost is `max(individual)` ≈ 5 min). **Dispatch them concurrently — this is the DEFAULT for EVERY code-changing session, including ≤5-file / <10-turn bug fixes** (those are precisely where the serial cost was being paid; there is no "too small to parallelize" — two reviewers concurrent already beats two serial).

Mechanism (works from a forked `/v` — it's plain Bash subprocess supervision, NOT Agent-tool fan-out): write one command file per child, then invoke the supervisor in a SINGLE Bash tool call:

```bash
SUPERVISOR="${CLAUDE_SKILL_DIR}/references/v-supervise-children.sh"

cat > "$V_TMP_DIR/review-logic-${SESSION_ID}.sh" <<EOF
bash "$HELPER" --agent logic-reviewer --prompt-file "$PF_LOGIC" --artifact "$ART_LOGIC" --mode capture
EOF
cat > "$V_TMP_DIR/review-fit-${SESSION_ID}.sh" <<EOF
bash "$HELPER" --agent codebase-fit-reviewer --prompt-file "$PF_FIT" --artifact "$ART_FIT" --mode capture
EOF
cat > "$V_TMP_DIR/review-fw-${SESSION_ID}.sh" <<EOF
bash "$HELPER" --agent framework-pitfall-reviewer --prompt-file "$PF_FW" --artifact "$ART_FW" --mode capture
EOF
cat > "$V_TMP_DIR/review-codex-${SESSION_ID}.sh" <<EOF
# MEDIUM fix (2026-06-09): write provenance AFTER codex exits so the gather script and
# GATHER_VARS AGENT_REVIEW_DISPATCH_PATH resolver can detect the codex path reliably.
#
# 21 (forensic 2026-07-03, P1-4 "dispatch ledger structurally blind to subprocess dispatches"):
# \`\$HELPER\` (v-dispatch-subagent.sh) self-records DISPATCH_PROVENANCE for logic/fit/framework
# above — but codex is invoked DIRECTLY (\`codex exec\`, never through \$HELPER, because it's a CLI
# not a \`claude --agent\`), so it needs its OWN provenance-append. This is the GENERIC pattern for
# ANY future reviewer/runner dispatched as a raw subprocess OUTSIDE \$HELPER (the exact shape that
# left one session's ledger with only 1 line for 2 real subprocess review dispatches) — reuse
# \`_v_record_subprocess_provenance\` verbatim; do not hand-roll a new one-off printf per dispatch.
_v_record_subprocess_provenance() {
  # args: agent_name mode submodel status duration_ms artifact_path prov_log
  local _agent="\$1" _mode="\$2" _submodel="\$3" _status="\$4" _dur="\$5" _art="\$6" _log="\$7"
  local _ts _sha
  _ts=\$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
  _sha=\$(shasum -a 256 "\$_art" 2>/dev/null | awk '{print \$1}' || echo "")
  printf 'DISPATCH|ts=%s|agent=%s|mode=%s|status=%s|submodel=%s|cost_usd=|duration_ms=%s|artifact=%s|sha256=%s\n' \
    "\$_ts" "\$_agent" "\$_mode" "\$_status" "\$_submodel" "\$_dur" "\$_art" "\$_sha" >> "\$_log" 2>/dev/null || true
}
_PROV_LOG="${ART_DIR}/DISPATCH_PROVENANCE_${SESSION_ID}.log"
_T0=\$(date +%s%3N 2>/dev/null || date +%s)
# E2 (efficiency, 2026-07-05): check the SHARED, fleet-wide codex-quota cache BEFORE attempting
# codex exec. If ANY session (or an earlier dispatch point in THIS session) already discovered
# codex's quota is exhausted, skip the doomed network round-trip entirely and go straight to the
# documented fallback chain (Skill/ORCHESTRATOR_INLINE) — the cache TTL (default 45 min) self-expires
# so codex is retried again once it's plausibly back. Fail-open: if the lib is missing, behaves
# exactly as before (always attempts codex).
_CQ_LIB="\$HOME/.claude/hooks/lib/codex-quota-cache.sh"
[ -f "\$_CQ_LIB" ] && . "\$_CQ_LIB" 2>/dev/null || true
if declare -F codex_quota_is_blocked >/dev/null 2>&1 && _CQ_REASON=\$(codex_quota_is_blocked); then
  echo "\$_CQ_REASON — skipping codex exec (see \$_CQ_LIB)" >> "$ART_CODEX"
  echo "status: fallback_required" >> "$ART_CODEX"
  echo "reason: \$_CQ_REASON" >> "$ART_CODEX"
  _CODEX_RC=1
else
  codex exec --model "${CODEX_REVIEW_MODEL:-gpt-5.3-codex}" "\$(cat "$PF_CODEX")" </dev/null > "$ART_CODEX" 2>&1 \
    || codex exec --model "${CODEX_REVIEW_MODEL_FALLBACK:-gpt-5.5}" "\$(cat "$PF_CODEX")" </dev/null > "$ART_CODEX" 2>&1
  _CODEX_RC=\$?
  # On a genuine quota-exhaustion signature, record it in the shared cache so OTHER sessions (and
  # later dispatch points in this one) skip straight to fallback until the TTL expires.
  if [ "\$_CODEX_RC" != "0" ] && declare -F codex_quota_looks_like_exhaustion >/dev/null 2>&1 \
     && codex_quota_looks_like_exhaustion "\$(cat "$ART_CODEX" 2>/dev/null)"; then
    codex_quota_record_exhausted "\$(grep -iE 'hit your usage limit|usage limit|quota exceeded|quota|rate.?limit exceeded' "$ART_CODEX" 2>/dev/null | head -1)" 2>/dev/null || true
  fi
fi
_T1=\$(date +%s%3N 2>/dev/null || date +%s)
_DUR=\$(( _T1 - _T0 ))
_STATUS=ok; [ "\$_CODEX_RC" != "0" ] && _STATUS=failed
_v_record_subprocess_provenance "codex-adversarial-reviewer" "codex_cli" "${CODEX_REVIEW_MODEL:-gpt-5.3-codex}" \
  "\$_STATUS" "\$_DUR" "$ART_CODEX" "\$_PROV_LOG"
exit \$_CODEX_RC
EOF

bash "$SUPERVISOR" \
  --summary "$V_TMP_DIR/review-supervisor-${SESSION_ID}.summary" \
  --retry-transient once \
  --fallback-artifacts enabled \
  --child "logic::600::$ART_LOGIC::$V_TMP_DIR/review-logic-${SESSION_ID}.sh" \
  --child "fit::600::$ART_FIT::$V_TMP_DIR/review-fit-${SESSION_ID}.sh" \
  --child "framework::600::$ART_FW::$V_TMP_DIR/review-fw-${SESSION_ID}.sh" \
  --child "codex::900::$ART_CODEX::$V_TMP_DIR/review-codex-${SESSION_ID}.sh"
```

Safe because: each dispatch writes its OWN `--artifact` path + supervisor-scoped log; the shared `DISPATCH_PROVENANCE_<sid>.log` is append-only with single-line `printf`s (atomic for <4KB writes). After the supervisor exits, read the summary and every artifact, then adjudicate per step 3. A non-zero supervisor exit means at least one child failed, NOT that sibling artifacts are missing. Process successful artifacts and apply the fallback chain for failed children. **Only serialize when a later reviewer genuinely needs an earlier one's output** (it never does for these read-only passes). Cycle-2 re-review (step 4) is scoped to changed files and may dispatch fewer reviewers, still concurrently through the supervisor.

**Any raw-subprocess reviewer dispatch that bypasses `$HELPER` MUST call `_v_record_subprocess_provenance`** (21, forensic 2026-07-03): `$HELPER` (v-dispatch-subagent.sh) self-records provenance for every dispatch that goes through it — the ONLY gap is a dispatch invoked as a bare CLI subprocess directly in a supervisor child script (codex today; any future direct-subprocess reviewer tomorrow). The waste-detector / dispatch ledger reads `DISPATCH_PROVENANCE_<sid>.log` as ground truth for what actually ran; a raw subprocess that skips this call is invisible to it (the exact gap: one session's `DISPATCH_PROVENANCE` log carried 1 line — an Agent-tool verify-done dispatch — while the transcript proved 2 additional subprocess review dispatches with no provenance at all).

### The adversarial PANEL (2026-08-03) — the mandatory review gate

**The panel is the gate. Codex is an optional extra voice.** This replaces "codex is mandatory, with a
fallback chain" as the load-bearing design.

**Why the change (ground truth, not preference).** Across 358 final `AGENT_REVIEW` artifacts on disk:
24 (6.7%) positively evidence a successful codex CLI run; 103 record explicit failure/quota/unavailable;
36 record an inline/superpowers fallback; **147 say `ran — N candidates…` naming no model and no
mechanism**; 42 omit the required field entirely. The dispatch ledger agrees — across 83
`codex-adversarial-reviewer` rows, `mode=codex_cli` appears once, `status=error`. The cross-vendor
independence the old design treated as mandatory was absent from the large majority of reviews for its
entire measured history, and requiring it anyway is what produced fabricated "codex ran" claims
(two forensic cases) and ~15 accreted regex special-cases in `validation.sh`.

**What independence means now.** Not "a different vendor answered" but: **N reviewers, mutually blind,
each on a DISTINCT lens, each required to refute before accepting.** That is checkable — and it is
checked, against `DISPATCH_PROVENANCE`, by `validation.sh:_panel_was_dispatched`.

#### Panel composition (risk-tiered; obeys the sonnet/haiku model policy)

| Diff class | Panel | Lenses |
|---|---|---|
| Routine | 2 | `correctness` (sonnet) + `repro` (haiku) |
| Hostile paths (`v-hostile-required.sh` ⇒ 1) | 3 | `security` (sonnet) + `correctness` (sonnet) + `repro` (haiku) |
| Billing / payment code | 3 | as hostile; **sonnet floor is non-overridable** (`resolve_review_model` Tier 1 still returns first) |

`V_REVIEW_TIER=haiku` is REJECTED as of 2026-08-06 (reviews never run on haiku); the note below describes the retired behaviour — Tiers 1/2 returned before it, exactly as
before, so this can never shallow a payment or auth review.

#### Dispatch — two stages, both concurrent

Stage 1 generates candidates; stage 2 refutes them. Reuse the existing supervisor (plain Bash
subprocess supervision — works from a forked `/v`; NOT Agent-tool fan-out):

#### Lens selection

`PANEL_LENSES` is this block's entry point. Set it EXPLICITLY — before W-PANELSCOPE (2026-08-03) it
was referenced twice here and assigned nowhere in `~/.claude`, so the panel opened on an undefined
variable and sessions silently fell back to a single `logic-reviewer`.

| Diff shape | Add lens |
|---|---|
| **every code-changing session (the floor)** | **`scope correctness`** |
| auth / authz / payments / crypto / HMAC / webhooks / migrations | `security` |
| concurrency, retries, queues, webhooks, double-submit paths | `repro` |
| new helper / service / abstraction, or a pattern-heavy area | `fit` |
| queue jobs, service providers, event wiring, framework primitives | `framework` |

`scope` + `correctness` is the MANDATORY floor for every code-changing session, and satisfies the
`>=2 distinct lenses` rule on its own. Rationale for `scope` being in the floor rather than optional:
every other lens hunts defects *inside* the diff, so a requested surface that was never touched is
invisible to all of them. In one production session that gap (4 of 10 page types silently skipped) was caught only
by the QA acceptance loop at ~minute 20; as a panel child it lands at ~minute 6.
Lenses are additive — a payments diff runs `scope correctness security`, never `security` alone.

```bash
SUPERVISOR="${CLAUDE_SKILL_DIR}/references/v-supervise-children.sh"
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
PANEL_LENSES="${PANEL_LENSES:-scope correctness}"   # floor; ADD lenses per the table above

# ── Stage 1: generate, one child per lens ────────────────────────────────────────────────────────
# Each child writes its OWN artifact and self-records DISPATCH_PROVENANCE via $HELPER, which is what
# makes the panel size verifiable at the gate. Do NOT hand-roll a raw subprocess here: a dispatch that
# bypasses $HELPER writes no provenance row and is therefore INVISIBLE to _panel_was_dispatched — the
# panel would then under-count and the artifact's declared size would fail its own cross-check.
for LENS in $PANEL_LENSES; do            # e.g. "correctness security repro"
  cat > "$V_TMP_DIR/panel-${LENS}-${SESSION_ID}.sh" <<EOF
bash "$HELPER" --agent adversarial-panel-reviewer \
  --prompt-file "$V_TMP_DIR/pf-panel-${LENS}-${SESSION_ID}.txt" \
  --artifact "$ART_DIR/panel-${LENS}-${SESSION_ID}.md" --mode capture
EOF
done

bash "$SUPERVISOR" --summary "$V_TMP_DIR/panel-gen-${SESSION_ID}.summary" \
  --retry-transient once --fallback-artifacts enabled \
  $(for LENS in $PANEL_LENSES; do
      printf ' --child %s::600::%s::%s' "$LENS" \
        "$ART_DIR/panel-${LENS}-${SESSION_ID}.md" "$V_TMP_DIR/panel-${LENS}-${SESSION_ID}.sh"
    done)
```

Each stage-1 prompt file MUST state `LENS: <lens>` and `MODE: generate`. The agent hard-stops on a
missing lens — an unassigned lens silently collapses the panel into N identical reviewers, which
satisfies `panel=N` numerically while delivering one reviewer's worth of coverage. That is the single
most important failure mode of this design; the `lenses=` arity + distinctness rules in
`_panel_field_valid` exist to catch it, and the agent's `initialPrompt` is the second net.

> **The artifact name `panel-<lens>-<sid>.md` is LOAD-BEARING — do not rename it.** Panel membership is
> keyed on `artifact=`, not `agent=`, because a panel is ONE agent dispatched N times (every row says
> `agent=adversarial-panel-reviewer`). Both `v-emit-agent-review-skeleton.sh` and
> `validation.sh:_panel_was_dispatched` count DISTINCT artifacts, and the skeleton parses the LENS out
> of that basename. A differently-named artifact still counts toward panel SIZE but loses its lens,
> falling back to the agent-name mapping — which collapses every member to `adversarial`, fails the
> ">=2 distinct lenses" rule, and suppresses the panel field entirely. Verified live 2026-08-03: keying
> on `agent=` instead scored a real 2-lens run as 1 member and rejected it at the gate.

Stage 2 is the same shape with `MODE: refute`, passing the pooled stage-1 candidates. **A finding is
accepted only when a majority of refuters return `stands`.**

#### Codex as an optional extra voice

Probe once, cheaply, and never depend on it:

```bash
# gpt-5.5, NOT gpt-5.3-codex: the latter returns HTTP 400 "not supported when using Codex with a
# ChatGPT account" on this operator's account 100% of the time (verified live 2026-08-03), so making
# it the primary bought a guaranteed-failed round trip on every single review.
if command -v codex >/dev/null 2>&1; then
  codex exec --model "${CODEX_REVIEW_MODEL:-gpt-5.5}" --sandbox read-only \
    "$(cat "$PF_CODEX")" </dev/null > "$ART_CODEX" 2>&1 && CODEX_VOICE=1 || CODEX_VOICE=0
fi
```

If it answers, merge its candidates into the pool and add `codex-adversarial-reviewer` to the panel's
`models=`/`lenses=` as one more voice. **If it does not answer, nothing happens** — no fallback chain,
no memo, no quota cache, no `fallback_required` protocol, no honest-labeling obligation. Codex is no
longer load-bearing, so its absence is a non-event rather than a degradation requiring disclosure.

#### The provenance field

Emit the machine-checkable panel field — `v-emit-agent-review-skeleton.sh` derives it from real
dispatch rows, so **never hand-write it**:

```
- Adversarial review: panel=3 models=sonnet,sonnet,haiku lenses=correctness,security,repro candidates=7 accepted=2 refuted=5
```

`candidates`/`accepted`/`refuted` start at `0/0/0` in the skeleton (honest — adjudication has not run
yet) and MUST be updated when findings are pasted. `validate_review_semantics` blocks `candidates=0`
over a body containing finding IDs, which is the never-filled-template failure the old
`# FILL N from adjudication` placeholder produced in 4 on-disk drafts.

The legacy `Codex adversarial reviewer:` field remains fully accepted for back-compat — 358 historical
artifacts must not retro-fail — but new sessions should emit the panel field.

### Codex dispatch — invocation, retrieval, and HONEST labeling (W22-CC2, HISTORICAL)

> **Superseded 2026-08-03 by the panel above.** Retained because the failure modes it documents are
> real and still apply *whenever codex is invoked as the optional extra voice* — particularly the
> prompt-clobbering rule (2) and the honest-labeling rule (4). What no longer applies: codex is not
> mandatory, there is no fallback chain to enter when it fails, and its absence needs no disclosure.

Forensic (R-3, 2026-06-03): the codex review silently degraded to an orchestrator inline self-review, but the AGENT_REVIEW + log claimed a successful **codex** run (`Dispatch mode: foreground`, "codex exec … exit 0 … reviewed"). The independent-review safety gate was lost AND the telemetry concealed it. Three rules close this — all three are mandatory:

1. **Invocation — never clobber the prompt.** Prefer the canonical helper `bash ~/.claude/scripts/codex-review.sh` (positional-arg prompt + `-o` capture + timeout shim + `</dev/null`). If you hand-roll, the prompt MUST be a **positional arg**: `codex exec --model "$M" "$(cat "$PF_CODEX")" </dev/null`. **NEVER** `echo "$PROMPT" | codex exec … </dev/null` — the `</dev/null` **overrides the stdin pipe**, codex gets an empty prompt, prints `Usage: codex exec …`, and the review is silently lost. (This exact hand-roll is what failed in every laundered session.)

2. **Retrieval — codex auto-backgrounds; do not poll with `cat`.** A foreground `codex exec` that runs >~2 min is auto-backgrounded by Claude Code. Read its output via **`grep`/`tail` on the output file** or the **`BashOutput` tool** — NOT `sleep N && cat …/tasks/*.output`, which the W41 anti-polling hook BLOCKS (that block is precisely what drove the laundered sessions to abandon codex). R-2 recovered correctly by re-reading with `tail`/`grep`; R-3 gave up after the `cat` was blocked.

3. **Honest labeling — you only got a codex review if you READ codex's findings.** If codex backgrounded/failed and you could not retrieve its output, you did **not** obtain a codex review. Set `Dispatch mode: orchestrator_inline` and `Codex adversarial reviewer: codex-adversarial-reviewer (orchestrator-inline fallback)` (the literal `codex-adversarial-reviewer` substring is required — rule 4 below). **NEVER** write `Dispatch mode: foreground`, "exit 0", or "codex reviewed" for output you never read, and NEVER set the session-log `agent_review.dispatch_path: codex` for an inline self-review. This is not optional politeness: `validate-log.py` **W22-CC2** cross-checks `dispatch_path: codex` against the transcript (inline-fallback admission + no codex ingestion ⇒ the log FAILS validation), and W22-CC1 fails an artifact that says `codex` over an inline `Dispatch mode`. Label it honestly and the inline path is fully accepted (HOOK-4); fabricate codex and the gate fails.

### Review Model Tiering (W13 — self-contained)

Adversarial review benefits from stronger reasoning when the diff touches sensitive surfaces. The codex Agent dispatch model is selected by these rules, in order — first match wins:

```bash
# resolve_review_model is SELF-CONTAINED: it computes HOSTILE_PATHS internally
# from the session-writes log + git diff, so it never depends on caller-side
# variable ordering. This was a critical bug in the first W13 cut where
# resolve_review_model was called BEFORE the hostile computation block ran,
# silently downgrading every review to haiku.
resolve_review_model() {
  local sid="${1:-${SESSION_ID:-${CLAUDE_SESSION_ID:-}}}"
  local repo_root="${2:-${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

  # H4-5 (PLAN_2026-07-02_orchestrator-hardening-4): hostile-path detection is now SINGLE-SOURCED
  # via v-hostile-required.sh, which sources hooks/lib/validation.sh's canonical
  # HOSTILE_REVIEW_PATH_PATTERN (the SAME pattern the Stop hook enforces). This function previously
  # hand-rolled its OWN copy of the pattern, which had drifted from the Stop hook's list (missing
  # login/register/encrypt/sanctum/passport/subscription/checkout/invoice/upload/storage) —
  # In one session the orchestrator computed hostile=no here while the Stop hook computed yes on the
  # SAME diff, landing work before the hostile review the Stop hook actually required existed.
  local _hr_script="${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/v}/references/v-hostile-required.sh"
  local hostile_paths=""
  if [ -f "$_hr_script" ]; then
    local _hr_out
    _hr_out=$(bash "$_hr_script" --sid "$sid" --tmp-dir "${V_TMP_DIR:-}" --worktree-root "$repo_root" 2>/dev/null)
    hostile_paths=$(printf '%s\n' "$_hr_out" | awk '/=== HOSTILE_PATHS ===/{f=1;next}/=== END_HOSTILE_PATHS ===/{f=0}f')
    [ "$hostile_paths" = "NONE" ] && hostile_paths=""
  else
    # DEGRADED fallback ONLY if the script is missing entirely (should not happen in a healthy
    # install) — same word-bounded pattern as before, kept as a last resort, not the primary path.
    local writes_log="$V_TMP_DIR/session-writes-${sid}.txt"
    if [ -f "$writes_log" ] && [ -s "$writes_log" ]; then
      hostile_paths=$(grep -iE "(^|/)(auth|billing|cashier|stripe|webhook|payment|password|token|secret|key|credential|oauth|jwt|csrf|hmac|signature|crypto|cipher|salt|nonce|admin|2fa|mfa|sso|saml|oidc|rbac|policy|policies|middleware|cookie|private|session-token|csrf-token)([./]|$)" "$writes_log" 2>/dev/null || true)
    else
      hostile_paths=$(git -C "$repo_root" diff --name-only HEAD 2>/dev/null | grep -iE "(^|/)(auth|billing|cashier|stripe|webhook|payment|password|token|secret|key|credential|oauth|jwt|csrf|hmac|signature|crypto|cipher|salt|nonce|admin|2fa|mfa|sso|saml|oidc|rbac|policy|policies|middleware|cookie|private|session-token|csrf-token)([./]|$)" 2>/dev/null || true)
    fi
  fi

  # Restrict to code files for tier-1/tier-2 escalation (FND-8 fix).
  # Doc-only changes (.md, .yaml, .json) shouldn't trigger model upgrade — they don't
  # contain executable billing logic. Keep the unrestricted match for tier-2 since
  # any auth/secret config is hostile regardless of extension.
  local hostile_code_paths
  hostile_code_paths=$(echo "$hostile_paths" | grep -iE '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs|java|kt|swift)$' || true)

  # Tier 1: billing/payment CODE surface only — strongest AVAILABLE reasoning.
  # 2026-07-07 operator decision (sonnet-max): reviews run ONLY on sonnet/haiku — the
  # opus escalation is retired. Tier 1 stays a distinct risk gate (it returns BEFORE the
  # V_REVIEW_TIER dial, so billing can never be down-tiered to haiku).
  if echo "$hostile_code_paths" | grep -iqE "(^|/)(cashier|stripe|webhook|payment|billing)([./]|$)"; then
    echo "sonnet"
    return
  fi
  # Tier 2: hostile CODE paths (FND-8 — docs/text changes describing billing or auth
  # don't need an upgraded reviewer; only changes to executable code/config do).
  # Config files (.env, .yml, .yaml, .toml, .ini, .conf) ARE included because they
  # often hold secrets/keys.
  local hostile_code_or_config
  hostile_code_or_config=$(echo "$hostile_paths" | grep -iE "\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs|java|kt|swift|env|ya?ml|toml|ini|conf)$" || true)
  if [ -n "$hostile_code_or_config" ]; then
    echo "sonnet"
    return
  fi
  # Tier 3: routine review — SONNET FLOOR (2026-06-17 cost-tier decision). Operator chose a sonnet
  # quality floor for reviews over a haiku floor: routine reviews run sonnet, hostile non-billing also
  # sonnet, and billing/payment CODE (Tier 1) is risk-gated at sonnet (opus tier retired 2026-07-07 —
  # sonnet-max operator decision). This pairs with the review-agent
  # frontmatter default (now `model: sonnet`, was opus) so the EFFECTIVE review floor is sonnet on every
  # path — the canonical W13 dispatch AND any direct/fallback dispatch.
  #
  # D3 (MR-3, 2026-06-21): the global CLAUDE.md "dispatch reviewers with model: haiku" guidance and this
  # sonnet floor CONFLICTED on paper (the floor wins, by design). Reconcile them with an operator dial:
  # $V_REVIEW_TIER (haiku|sonnet) overrides the ROUTINE floor ONLY. It is RISK-GATED by construction —
  # Tier 1 (billing/payment code -> sonnet, non-overridable) and Tier 2 (hostile code/config -> sonnet) have ALREADY returned
  # above, so this override can NEVER down-tier a security/payment review; it only sets the floor for
  # non-hostile, routine (low-risk) diffs. So `V_REVIEW_TIER=haiku` buys the ~3x routine-review saving the
  # Wave-11 note traded away, WITHOUT exposing security/payment to a shallower reviewer. Invalid/unset ->
  # the sonnet floor. (Wave-11 evidence: haiku reviewers surfaced only LOW findings — keep this OFF for
  # logic/security-heavy waves; turn it on for docs/copy/UI-string days.)
  # 2026-08-06 OPERATOR DECISION: haiku is removed from code reviews. `haiku` is NO LONGER an
  # accepted V_REVIEW_TIER value — the dial can now only re-assert the sonnet floor, never lower it.
  # Reviews run on sonnet on EVERY tier and EVERY path; sonnet remains the CAP (no opus lane).
  #
  # What this retires: the D3/MR-3 dial (2026-06-21) that traded routine-review depth for a ~3x
  # saving on non-hostile diffs. The operator has priced review quality above that saving. The
  # Wave-11 evidence quoted above ("haiku reviewers surfaced only LOW findings") is precisely the
  # reason — it was recorded as a caveat and should have been read as a verdict.
  #
  # Enforced in TWO places on purpose, and they must agree: here (resolution) and
  # enforce-haiku-dispatch.sh Layer 3 (dispatch, which raises a hard-coded haiku reviewer back to
  # sonnet). Belt and braces, because a declaration that disagrees with the decision is exactly how
  # every reviewer came to run on haiku while its frontmatter said sonnet.
  case "${V_REVIEW_TIER:-}" in
    sonnet) echo "sonnet"; return ;;
  esac
  echo "sonnet"
}

# Call site: pass nothing; the function self-resolves SID/REPO_ROOT.
REVIEW_MODEL="$(resolve_review_model)"
```

**Tiering (SONNET-MAX, 2026-07-07 — current rule first, history after):** ALL reviews are capped at **sonnet**. Tier 1 billing/payment resolves `sonnet` (still a non-overridable risk gate — it existed so `V_REVIEW_TIER=haiku` could never shallow a payment review; haiku is now rejected outright), and `opus` is NOT a valid `V_REVIEW_TIER` value. There is no opus escalation lane for reviews of any kind. *History (2026-06-17 decision, superseded — kept for context only; ND-0716 moved it after the live rule because a skim-reading model acted on the first half of this paragraph):* the original cost-tier decision set a sonnet floor with billing/payment escalating to opus; sonnet-max later removed that escalation. That decision was also the fix for a real cost leak: review-agent frontmatter defaulted to `model: opus`, so any dispatch that didn't pass `$REVIEW_MODEL` (the codex-down fallback path) ran reviews on opus — 3 opus review subagents in one measured session (~627k tokens). Frontmatter is now `model: sonnet`; the effective review model is sonnet on EVERY path. **`haiku` is NOT a valid `V_REVIEW_TIER` value (operator decision 2026-08-06: haiku is removed from code reviews).** The dial can only re-assert the sonnet floor; it can no longer lower it. Enforced twice on purpose — at resolution here, and at dispatch by `enforce-haiku-dispatch.sh` Layer 3, which raises any hard-coded haiku reviewer back to sonnet.

**Provenance:** the Agent dispatch passes `$REVIEW_MODEL`. The dispatched agent reports its model on line 1 of its review (`Model: haiku|sonnet|opus`). The orchestrator's W12-2 Post-Dispatch Wrap step pastes the reviewer's findings into the canonical skeleton AND records the model in the new `Reviewer model:` provenance field (see skeleton below). The skeleton's literal `Model: haiku` line 1 is preserved as the validator-facing magic constant — this is a known dual-bookkeeping arrangement until `validation.sh` is updated to accept `Model: (haiku|sonnet|opus)`.

Required artifact `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md` (validator-aligned; copy verbatim):
```markdown
Model: haiku

## Agent Review — ${CLAUDE_SESSION_ID}
- Status: [completed | pass | passed]
- Agents directory: [path | not found]
- Agents dispatched: [list, or "none — invoked superpowers:requesting-code-review"]
- Codex adversarial reviewer: [ran — N candidates, N accepted, N rejected | superpowers:requesting-code-review fallback | skipped — file not found | codex-adversarial-reviewer (orchestrator-inline fallback)]
- Reviewer model: [haiku | sonnet | opus]   # actual model the review ran on (W13 tiering)
- Hostile adversarial focus: [verdict of `v-hostile-required.sh --sid "$SESSION_ID"` — HOSTILE_REQUIRED=1 ⇒ "yes — <hostile paths>", 0 ⇒ "no — HOSTILE_REQUIRED=0". NEVER hand-judge (H4-5 single source; admin/settings/webhook paths count as hostile): a hand-judged "no" on a HOSTILE_REQUIRED=1 diff strands the branch at the merge W-GATE (H4-6)]
- Dispatch mode: [foreground | background | orchestrator_inline]
- Review evidence: [claude_accepted: N | codex_candidates: N | findings: N | superpowers:requesting-code-review | CODEX-* | SREV-* | No issues found | Raw Findings]
- Remediation: [N findings fixed and re-verified | no findings]

## Findings

[brief verdict-organized findings; if zero issues: "No issues found." plus 1-2 line summary of what was reviewed]
```

**Critical structural rules** (validator-enforced):
1. `Model: haiku` MUST appear on line 1, no leading whitespace.
2. `## Agent Review` H2 on line 3, then the 8 dash-prefixed provenance fields.
3. `## Findings` H2 (or `## Review`) MUST appear after the provenance block.
4. Codex enum allows 4 values: `ran — N candidates, N accepted, N rejected` | `superpowers:requesting-code-review fallback` | `skipped — file not found` | `codex-adversarial-reviewer (orchestrator-inline fallback)`. **Critical:** when ORCHESTRATOR_INLINE path is used, the value MUST contain the literal substring `codex-adversarial-reviewer` — the production hook regex requires it. Standalone `orchestrator-inline` is rejected.
5. Dispatch mode enum allows 3 values: `foreground` | `background` | `orchestrator_inline`.

### Post-Dispatch Wrap (always — no exceptions)

The dispatched reviewer (`superpowers:requesting-code-review`, codex CLI, or any sub-agent) does NOT know the AGENT_REVIEW skeleton. Their output is raw findings — usually 200–500 bytes of markdown with verdict + a few finding lines. **This raw output is NEVER the AGENT_REVIEW artifact.**

The orchestrator MUST always:
1. Receive the reviewer's raw output (verdict + findings, or "approved").
2. Construct AGENT_REVIEW from the skeleton above (line-for-line copy of the `markdown` block).
3. Set provenance fields from the dispatch path actually taken (codex / superpowers / orchestrator_inline).
4. Paste the reviewer's findings verbatim into the `## Findings` section (preserve their wording).
5. Run the Pre-Write Verification checklist (below) BEFORE the Write tool call.

**Fast path (preferred — collapses steps 2–3 into one Bash call; saves the manual skeleton construction):**
```bash
SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID}}"   # full UUID, same var the artifact path uses
bash "${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/v}/references/v-emit-agent-review-skeleton.sh" \
  --sid "$SID" --out "${V_TMP_DIR:-.}/AGENT_REVIEW_draft_${SID}.md"
```
It emits a draft that PASSES the validator on arrival — `Model: haiku` line 1, all 8 provenance fields, and
`Dispatch mode` / `Reviewer model` / `Agents dispatched` **DERIVED from the real `DISPATCH_PROVENANCE_${SID}.log`**
(it emits `orchestrator_inline` when no reviewer dispatch is on record — it NEVER forges `foreground`, so it cannot
manufacture a gate pass). Then do ONLY steps 4–5 on the draft: paste findings into `## Findings`, run Pre-Write
Verification, and **Write it to the canonical artifact path — the SAME path the ORCHESTRATOR_INLINE fallback uses:**
`$(bash "${CLAUDE_SKILL_DIR}/references/v-artifact-dir.sh" 2>/dev/null || echo "${REPO_ROOT}/.v/artifacts")/AGENT_REVIEW_${SID}.md`
(full UUID — never the 8-char slug, never `.claude/`). The manual steps 2–3 above remain the fallback if the script
is unavailable. (The Stop hook independently re-validates the written artifact's `Dispatch mode` via
`_agent_was_dispatched`, so the script cannot change the gate's verdict.)

**Why this rule exists:** two production sessions (cycles=3, ~62k and ~6.5k tokens wasted) wrote superpowers's raw output verbatim as AGENT_REVIEW. The 274-byte / Wave-labeled-headings format hit the stop hook and required Edit-in-place rewrites every time. Wrapping is non-negotiable.

**Anti-pattern:** "I dispatched superpowers and it returned approved, so I wrote the approval as AGENT_REVIEW." Wrong: superpowers's approval is a single field of an 8-field artifact you must construct (W13 added Reviewer model).

**⛔ STOP — Pre-Write AGENT_REVIEW Verification (READ LAST, BEFORE Write)**

**Automated self-check (run this BEFORE the Write tool call):**

```bash
DRAFT="$V_TMP_DIR/agent-review-draft-${SESSION_ID}.md"   # write your draft here first
# Validator-facing magic constant: line 1 must be EXACTLY "Model: haiku" regardless of which model actually
# performed the review (W13 tiering uses Reviewer model: instead). AUTO-FORCE it — do NOT error-and-ask the model
# to sed-fix, which was the DOMINANT AGENT_REVIEW churn class (forensic 2026-06-27: ~9 Stop-blocks/batch from a
# hallucinated model id `gpt-5.5` / a frontmatter-hidden `Model:`). Drop a wrong leading `Model:` line and prepend
# the literal, deterministically — no model behaviour in the loop.
# >>> AREV-MODEL-AUTOFORCE (extracted verbatim by v-agent-review-autoforce-test.sh — keep the body self-contained)
if [ "$(head -1 "$DRAFT" 2>/dev/null)" != "Model: haiku" ]; then
  { echo "Model: haiku"; sed '1{/^Model: /d;}' "$DRAFT"; } > "$DRAFT.tmp" 2>/dev/null && mv "$DRAFT.tmp" "$DRAFT" || rm -f "$DRAFT.tmp"
fi
# <<< AREV-MODEL-AUTOFORCE
# Required provenance fields all present?
# NOTE: "Agents dispatched:" is REQUIRED by validation.sh:validate_review_semantics — it must be
# in this loop or a draft can pass the pre-write check yet get BLOCKED by the Stop hook (bounce
# loop). "Reviewer model:" / "Status:" are advisory extras the validator does not require, but
# keeping them here is harmless (a superset of the validator's required set is the safe invariant).
for field in "Status:" "Agents dispatched:" "Codex adversarial reviewer:" "Reviewer model:" "Hostile adversarial focus:" "Dispatch mode:" "Review evidence:" "Remediation:"; do
  grep -q "^- $field" "$DRAFT" || { echo "ERROR: missing field '- $field' in draft"; exit 1; }
done
# Findings header present?
grep -qE "^## (Findings|Review)" "$DRAFT" || { echo "ERROR: missing '## Findings' or '## Review' H2"; exit 1; }
# Now safe to Write to AGENT_REVIEW_${SESSION_ID}.md
```

Then mentally grep your draft:
1. `head -1 draft` exactly equals `Model: haiku` (no whitespace, no hash, no bold)
2. `head -20 draft | grep -nE '^- Status:'` returns 1 line (dash-prefixed metadata Status, not free-form)
3. `grep -nE '^Verdict:|^## Verdict' draft` returns 0 lines — `Verdict:` is NOT an AGENT_REVIEW field (that's PRE_FLIGHT format; using it causes hook block)
4. `grep -nE '^## Findings|^## Review' draft` returns 1 line (after metadata)
5. No `Status:` or `Verdict:` text in finding body — reword to "Severity:" or "Disposition:"
6. No bold markup on the Status value: `Status: completed` ✓ ; `Status: **completed**` ✗

**Forbidden patterns (cause hook block):**
- `## Verdict: APPROVED` — H2 with status (PRE_FLIGHT format, not AGENT_REVIEW)
- `Verdict: **APPROVED**` — bold markup
- `**Status:** ...` in finding body — collides with metadata grep
- Free-form `Status:` line outside the first 20 lines

**Why it matters:** one session wrote `## Verdict:` (PRE_FLIGHT-style); another session's finding body had `Status: Acceptable` matched by the validator. Both forced costly redispatch (~80k tokens each).

### Cycle Cap (W22-4 / Rel-FND-13 — mechanical enforcement, per-class)

The skill historically said "max 2 review cycles" and "max 3 attempts per fix" in prose.
Sonnet can ignore prose. W22-4 adds counter files that the orchestrator increments at
each cycle boundary, with **separate sub-caps per class** so legitimate sessions that
exercise multiple cycle types don't trip the same counter (FND-2 fix from W22 review).

Three independent counters, each with its own cap:

| Counter | Path | Cap | Increments when |
|---|---|---|---|
| `pre-flight-cycles` | `$V_TMP_DIR/cycle-preflight-${SESSION_ID}.txt` | 3 | `/v-pre-flight` is re-run after the first invocation |
| `review-cycles` | `$V_TMP_DIR/cycle-review-${SESSION_ID}.txt` | 3 | code review is re-dispatched after the first |
| `fix-cycles` | `$V_TMP_DIR/cycle-fix-${SESSION_ID}.txt` | 3 | a fix-attempt is made on the SAME finding (i.e. the same finding ID re-appears in a re-review) |

Generic helper (call before each cycle of any class):

```bash
cycle_check_and_increment() {
  local cls="$1"   # "preflight" | "review" | "fix"
  local cap="$2"   # numeric cap
  local file="$V_TMP_DIR/cycle-$cls-${SESSION_ID}.txt"
  [ -f "$file" ] || echo "0" > "$file"
  local count
  count=$(cat "$file" | tr -d '[:space:]')
  count=$((count + 1))
  echo "$count" > "$file"
  if [ "$count" -gt "$cap" ]; then
    # FND-3: write a CYCLE_CAP_HANDOFF artifact instead of bare exit 1
    HANDOFF="$PROJECT_ROOT/CYCLE_CAP_HANDOFF_${SESSION_ID}.md"
    cat > "$HANDOFF" <<HANDOFF_EOF
Model: orchestrator
SID: ${SESSION_ID}

## Cycle Cap Handoff — $cls cap exceeded ($count > $cap)

The orchestrator hit the W22-4 cycle cap on the **$cls** retry class. This usually
indicates a fix-rerun loop on an unfixable issue, NOT routine multi-cycle work.

cycle_class: $cls
cycle_count: $count
cycle_cap: $cap
counter_file: $file
all_counters: $(ls "$V_TMP_DIR"/cycle-*-${SESSION_ID}.txt 2>/dev/null | xargs -I{} sh -c 'echo "  $(basename {}): $(cat {})"' 2>/dev/null)

## Recovery Steps

1. Inspect the most recent failure mode (last PRE_FLIGHT_REPORT / AGENT_REVIEW for this session).
2. If the same finding keeps recurring: the fix isn't actually fixing the bug — surface to the user.
3. If different findings: the workflow is making progress; raise the cap manually for THIS session by
   resetting one counter (e.g. \`echo 0 > $file\`) and continuing.

Handoff Status: BLOCKED
HANDOFF_EOF
    echo "ERROR: $cls cycle cap exceeded ($count > $cap)" >&2
    echo "ERROR: handoff written to $HANDOFF" >&2
    return 1
  fi
  return 0
}

# Usage at each cycle boundary (return non-zero blocks; orchestrator decides):
# cycle_check_and_increment "preflight" 3 || exit 1
# cycle_check_and_increment "review"    3 || exit 1
# cycle_check_and_increment "fix"       3 || exit 1
```

The `_v-review.md` rule "max 2 cycles" remains as soft guidance for review-specific
adjudication; the per-class hard caps (3-3-3) provide the safety net. Counter files
are session-scoped via $SESSION_ID and reset on each new session.

**Remediation loop:** fix all ACCEPT/MODIFY → re-run `/v-pre-flight` → max 3 attempts per fix (mechanically enforced via the counter above).

**Always add `codex-adversarial-reviewer` on ALL implementations.**

### Hostile-Context Preamble (Required Before Agent Dispatch)

3–5 line preamble in dispatch prompt BEFORE the diff. Generic adversarial review catches generic patterns; domain-specific risks need explicit framing.

```
HOSTILE CONTEXT for this review:
- Domain: <e.g., "Stripe billing webhook handler" / "user signup flow">
- Risk surface: <specific failure modes, e.g., "race conditions on subscription creation">
- Edge cases I considered: <what you already thought through>
- What I'm worried about: <specific concerns from implementing>
- Adversarial focus: <if diff touches auth/payment/data deletion/file upload/external API — name it>
```

**Adversarial-focus computation (CRITICAL — from session-writes log, NOT dirty tree):**
```bash
SESSION_WRITES_LOG="$V_TMP_DIR/session-writes-${CLAUDE_SESSION_ID}.txt"
if [ -f "$SESSION_WRITES_LOG" ] && [ -s "$SESSION_WRITES_LOG" ]; then
  HOSTILE_PATHS=$(grep -iE "(^|/)(auth|billing|cashier|stripe|webhook|payment|password|token|secret|key|credential|oauth|jwt|csrf|hmac|signature|crypto|cipher|salt|nonce|admin|2fa|mfa|sso|saml|oidc|rbac|policy|policies|middleware|cookie|private|session-token|csrf-token)([./]|$)" "$SESSION_WRITES_LOG" || true)
else
  HOSTILE_PATHS=$(git diff --name-only HEAD 2>/dev/null | grep -iE "(^|/)(auth|billing|cashier|stripe|webhook|payment|password|token|secret|key|credential|oauth|jwt|csrf|hmac|signature|crypto|cipher|salt|nonce|admin|2fa|mfa|sso|saml|oidc|rbac|policy|policies|middleware|cookie|private|session-token|csrf-token)([./]|$)" || true)
fi
[ -n "$HOSTILE_PATHS" ] && HOSTILE_FOCUS="yes — diff touches: $HOSTILE_PATHS" || HOSTILE_FOCUS="no"
```

**Word boundaries mandatory** — substring `session` matches `SESSION_LOG_*.md`. Word-bounded `(^|/)session([./]|$)` matches only real auth/session-token paths. **Anti-pattern: NEVER compute hostile-focus from `git diff HEAD` on a dirty working tree** — pre-existing dirty files trigger false-positive `HOSTILE_REVIEW_REQUIRED=1` → AGENT_REVIEW rewrite cycles. Multi-domain diffs: include both domains with separate Risk surface lines.

### Format Failure Remediation (AGENT_REVIEW)

Stop hook blocks `AGENT_REVIEW_<sid>.md` for format → Edit-in-place (~500 tokens): upgrade `### Findings` → `## Findings`, prepend `Model: haiku`, add missing provenance line. Re-attempt commit. Re-dispatch ONLY when verdicts are wrong (NOT format). Per `_v-review.md` rule 12: cycle 2 allowed once, further re-runs forbidden. See `_v-review.md` § Required AGENT_REVIEW Artifact Format for contract.

---
