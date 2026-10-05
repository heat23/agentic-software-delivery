# Step 5: Verbatim Dispatch Mechanism (extracted from /v SKILL.md)

> Loaded by /v Step 5 just before dispatching `/v-pre-flight`, `/v-verify-done`, or `/v-handoff`. Implements Wave 9 mitigation for Sonnet's paraphrasing failure mode (Wave 1-7 evidence: 8 sessions confirmed dispatch-prompt edits never reached haiku).

### Verbatim Dispatch Mechanism (Mandatory for v-pre-flight, v-verify-done, v-handoff)

Sonnet's tendency to paraphrase tool args is the documented failure mode (8 production sessions confirmed Wave 1-7 dispatch-prompt edits never reached haiku). Wave 9 mitigation: extract the canonical prompt verbatim, then pass via Read tool to the Agent dispatch.

**W24 simplification (current):** the multi-step "cp + MODE-resolve + sed + sentinel-check" block that lived inline here is now collapsed into a single helper — `v-emit-prompt.sh`. The orchestrator runs ONE bash command and gets a ready-to-dispatch prompt. This removes ~70 lines of inline shell logic, eliminates Cowork-mode permission prompts on per-step bash commands, and removes the surface area where sonnet was improvising stale `sed -n '/^## Appendix A/...'` patterns from the legacy hook deny-message.

**Step D1 — Emit substituted prompt via the helper**

```bash
SKILL_NAME="v-pre-flight"   # or v-verify-done, v-handoff
DISPATCH_FILE="$V_TMP_DIR/dispatch-${SESSION_ID}-${SKILL_NAME}.txt"

# ONE call. Helper reads dispatch-${SKILL_NAME}.md, resolves SID (env → runtime
# file fallback), resolves PROJECT_ROOT / WORKTREE_PATH / PRE_FLIGHT_MODE,
# substitutes all four placeholders, runs sentinel + length checks, and
# emits the substituted prompt to stdout. Stderr carries diagnostics.
#
# Helper exit codes:
#   0  OK
#   2  bad/missing skill arg
#   3  source dispatch file missing (v/installation incomplete)
#   4  SESSION_ID could not be resolved (start a new session)
#   5  unsubstituted {{PLACEHOLDER}} remained (source file added a new var)
#   6  sentinel header check failed (source file edited and broken)
#   7  output suspiciously short (source truncated)
#   8  $V_TMP_DIR not writable (Step 0 bootstrap probably failed)
#   9  resolved RUN_ROOT is not a directory (stale WORKTREE_PATH / removed worktree)
#  10  SUCCESS, NOT FAILURE — F7 pre-dispatch stack gate: no gate-bearing stack, so the helper
#      already ran the gates and wrote PRE_FLIGHT_REPORT_<sid>.md mechanically. Do NOT dispatch,
#      do NOT rewrite the report. See the case block below; branch on the CODE, never on [ -s ].
#
# The helper expects $PROJECT_ROOT, $WORKTREE_PATH (may be empty), $WORKFLOW,
# $DIRTY_COUNT, and optionally $MODE / $PARALLEL_SESSIONS_DETECTED in env —
# all set by Step 0 bootstrap. It falls back to safe defaults when they're
# missing.
bash "${CLAUDE_SKILL_DIR}/references/v-emit-prompt.sh" "$SKILL_NAME" > "$DISPATCH_FILE"; _emit_rc=$?

# BRANCH ON THE EXIT CODE, not on file size (F7 fix, 2026-08-29).
# This block used to be ONLY `[ -s "$DISPATCH_FILE" ] || abort`, with a comment claiming it
# aborted "if the helper non-zero'd". It never checked the status — it worked only because every
# then-existing failure exit (2-9) wrote solely to stderr, leaving stdout empty. Exit 10 breaks
# that coincidence deliberately, so the status must be read.
case "$_emit_rc" in
  0) : ;;   # normal: $DISPATCH_FILE holds the runner prompt, proceed to D2
  10)
    # F7 PRE-DISPATCH STACK GATE: this tree carries none of the 15 gate-bearing stack sentinels
    # (hooks/lib/stack-sentinels.sh), so there is no gate for a runner to execute. The helper
    # already ran v-run-gates.sh directly and wrote PRE_FLIGHT_REPORT_<sid>.md MECHANICALLY from
    # that run's own skeleton. SUCCESS, not failure:
    #   - do NOT proceed to D2, and do NOT dispatch v-pre-flight-runner;
    #   - do NOT hand-write, "improve", or regenerate the report — it is the runner's own skeleton;
    #   - treat pre-flight as COMPLETE for this session.
    # v-dispatch-subagent.sh independently refuses this prompt file (exit 3), so a dispatch
    # attempted anyway is blocked mechanically rather than silently wasting a subagent.
    echo "F7: stackless tree — PRE_FLIGHT_REPORT already written mechanically; skipping dispatch." >&2
    ;;
  *)
    echo "ERROR: dispatch helper failed for $SKILL_NAME (exit $_emit_rc) — its stderr explains why" >&2
    exit 1
    ;;
esac
```

**MODE resolution (W16) — happens INSIDE the helper.** The helper applies the canonical decision rule:

- Step 1 classified as Maintenance OR feature_tiny → `scoped`
- Step 1 classified as feature_small AND dirty_count ≤ 15 → `scoped`
- Dirty-tree session (mixed pre-existing + session changes) → `dirty-tree`
- Everything else → `full`

Override: `PARALLEL_SESSIONS_DETECTED=true` AND `DIRTY_COUNT > 0` forces `dirty-tree`.

When in doubt, the helper prefers `full` — running the full suite once is always cheaper than missing a regression in an indirect dependent test.

**Step D2 — Dispatch via `claude -p --agent` subprocess (W-fork-fix)**

`/v` runs `context: fork` (it is a subagent), and subagents cannot dispatch subagents via the Agent tool — so the legacy `Agent(model:"haiku", prompt:<read>)` path failed silently and dropped to inline self-review. Dispatch each runner as an INDEPENDENT `claude -p --agent` subprocess instead (Bash works from a fork; the subprocess has its own context + model). The helper does it in ONE call:

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
case "$SKILL_NAME" in
  v-pre-flight)  AGENT_ARG=(--agent v-pre-flight-runner);  ARTIFACT="$PROJECT_ROOT/PRE_FLIGHT_REPORT_${SESSION_ID}.md" ;;
  v-verify-done) AGENT_ARG=(--agent v-verify-done-runner); ARTIFACT="$PROJECT_ROOT/VERIFY_DONE_REPORT_${SESSION_ID}.md" ;;
  v-handoff)     AGENT_ARG=(--model haiku);                ARTIFACT="$PROJECT_ROOT/HANDOFF_${SESSION_ID}.md" ;;
esac
bash "$HELPER" "${AGENT_ARG[@]}" --prompt-file "$DISPATCH_FILE" --artifact "$ARTIFACT" --mode capture
```

The helper reads `$DISPATCH_FILE` directly and feeds it to the subprocess on stdin, so sonnet never re-types the prompt — the old "sonnet paraphrases long tool args" failure mode (Wave 1-7, 8 sessions) is structurally eliminated, not just discouraged. The agent's frontmatter `tools:` whitelist and `model:` pin are preserved by `--agent`; `--mode capture` strips any write tool from the granted allowlist (read-only runners stay read-only). The runner emits its report as the final message; the helper sanitizes + persists it to `$ARTIFACT`.

**Step D3 — Cleanup at session end (Step 7)**

W25-B: the prior glob `dispatch-${SESSION_ID}-*.txt` only matched the
W24-helper output. Production .v/tmp had 74 leftover dispatch files in
the format `dispatch-v-{skill}-${SESSION_ID}.md` (and `.md.raw`) from
pre-W24 sessions — those were never being cleaned. The expanded glob
below catches all naming variants.

```bash
# Match all dispatch artifact name variants:
#   dispatch-${SESSION_ID}-${skill}.txt           (W24 helper output)
#   dispatch-${skill}-${SESSION_ID}.md            (legacy dispatch source copy)
#   dispatch-${skill}-${SESSION_ID}.md.raw        (legacy intermediate)
#   dispatch-pre-flight-*, dispatch-verify-done-* (older naming)
rm -f "$V_TMP_DIR"/dispatch-*${SESSION_ID}*

# Helper scratch files (W24)
rm -f "$V_TMP_DIR"/v-emit-${SESSION_ID}-*.tmp

# Per-gate logs and summary file (W25-A) — kept during the session for
# debugging; cleaned at end so the next session starts fresh.
rm -f "$V_TMP_DIR"/gate-*-${SESSION_ID}*.log
rm -f "$V_TMP_DIR"/gate-summary-${SESSION_ID}.txt

# Bootstrap output (this session's only — leave PID-named files for the
# W25-D periodic cleanup hook to handle since they're already orphaned)
rm -f "$V_TMP_DIR"/bootstrap-${SESSION_ID}.env

# Session-start marker (created by v-bootstrap.sh)
rm -f "$V_TMP_DIR"/session-start-${SESSION_ID}.txt

# (The retired staged-inline-on-main lock cleanup was removed with the optimistic
# universal-worktree migration — /v no longer writes inline-main-lock. A leftover from
# an old session is harmless: v-active-siblings.sh no longer scans inline locks, and
# v-merge-back.sh's defensive inline-sibling find is age-bounded so a stale lock expires.)
```

**Check 2 — `disable-model-invocation` skills route inline, NEVER via Skill tool:**
1. Before any Skill tool dispatch to a `/v-*` skill, peek the target's YAML frontmatter.
2. If `disable-model-invocation: true` (commonly `/v-build`), route INLINE — orchestrator performs the work directly following the skill's documented workflow.

**Check 3 — Skill must exist before invocation:**
- Skill availability map (W36 update — verified in a production session):
  - `superpowers:code-reviewer` IS installed and works (use this as the primary fallback skill)
  - `superpowers:requesting-code-review` is the legacy name; some installs may have only this
  - If `code-reviewer` returns "Unknown skill", try `requesting-code-review` once
  - If both return "Unknown skill", fall through to ORCHESTRATOR_INLINE immediately (do NOT loop)
- If invoked and "Unknown skill" returned: fall through on FIRST failure. Do NOT loop or retry.

**Check 4 — Multi-agent dispatch deduplication:**
- Only ONE adversarial review in flight at a time. If a second is initiated, wait for the background to complete first. Concurrent reviews on the same diff = duplicate findings + ~20-30k wasted tokens.

---

## Dispatch failure handling (subprocess model — W-fork-fix supersedes W38)

The old W38 "Agent type 'X' not found → restart Claude Code" failure mode is **GONE**: `claude -p --agent <name>` reads the agent registry fresh on every run, so a newly-added or just-edited agent file is picked up immediately — no restart required. (This was a real ergonomic win of the subprocess model over Agent-tool dispatch.)

The helper (`v-dispatch-subagent.sh`) handles failures explicitly and emits `DISPATCH_STATUS=error` on stdout with a non-zero exit:

- **Exit 3 (agent file missing):** the agent `.md` is absent at `~/.claude/agents/<name>.md`. Restore it from the backup or git, then re-run the helper. Diagnostics:
  ```
  ls -la ~/.claude/agents/v-pre-flight-runner.md
  head -10 ~/.claude/agents/v-pre-flight-runner.md   # should start with --- and have name:/tools:/model:
  chmod 644 ~/.claude/agents/v-pre-flight-runner.md   # ensure readable
  ```
- **Exit 4 (`claude` CLI not found):** PATH issue in the runner environment — surface to the user.
- **Exit 5 (subprocess errored / empty result):** transient model/network error, a malformed prompt, OR **gate-run contention from a concurrent session sharing the working tree** (observed 2026-05-25: a session's pre-flight subprocess errored while sibling sessions ran migrations/builds on shared `main`). Re-emit the prompt via `v-emit-prompt.sh` and retry ONCE. **If this session is NOT in its own worktree, that is the root cause — isolation is now mandatory (W-conc-fix); a correctly-isolated session does not contend.**
- **Exit 6 (artifact missing after run):** the agent ran but produced nothing — re-run once; if still empty, surface.
- **Exit 7 (cross-session artifact refusal, item 17c 2026-07-03):** the `--artifact` filename names a DIFFERENT session's SID than this dispatch's own `CLAUDE_CODE_SESSION_ID`/`CLAUDE_SESSION_ID`. This is NOT a transient failure — do not retry as-is and do not degrade inline. Two cases: (a) **wrong artifact path** (you substituted a stale/foreign SID into the prompt or `--artifact`) → fix the SID and re-dispatch; (b) **genuine cross-session remediation** (this session is deliberately finishing ANOTHER session's stranded gauntlet — e.g. a landing/drain session completing a dead sibling's verify-done) → acknowledge it explicitly by prefixing `V_DISPATCH_ACTING_AS=<your-own-SID>` to the same helper command; the helper then records an `ACTING_AS_<target-sid>.json` witness beside the provenance log so the cross-session write is auditable instead of silent.

**⛔ NO SILENT INLINE DEGRADATION (W-conc-fix — CRITICAL).** If, after the one retry, a runner subprocess (`v-pre-flight-runner` / `v-verify-done-runner` / `v-qa-reviewer`) still fails, the orchestrator must NOT quietly produce the gate artifact itself and present it as a clean run — that silently loses the independent model + the W35 read-only scope-creep protection (exactly the degradation the fork-fix exists to prevent). Production evidence: one session's pre-flight errored and the session then emitted PRE_FLIGHT/VERIFY_DONE/QA with NO further provenance markers (degraded to inline, undetectably). Required behavior on persistent runner-subprocess failure:
1. Do NOT fabricate a clean-looking artifact. If the orchestrator must run the gate inline as a last resort, it MUST stamp the artifact with a visible degraded marker — pre-flight/verify-done: add a `Dispatch: degraded-inline (subprocess errored, independence lost)` line in the header; QA: this is forbidden — QA self-grading is never independent, so write `verdict: escalated` + `BLOCKED_<sid>.md` instead (per `dispatch-v-qa-reviewer.md`).
2. The `DISPATCH_PROVENANCE_<sid>.log` already records the `status=error` line — leave it; do NOT delete it. A session whose provenance log shows an `error` line but whose gate artifacts claim a clean pass is the signature of silent degradation, and the session-log/operator should flag it.
3. Prefer fixing the root cause (isolate the session in a worktree, then retry) over degrading.

**Do NOT replace a failed helper call with an in-context `Agent(model:"haiku", …)` or an unscoped `claude -p` without the helper** — that uncontrolled fall-through (full tool set, no capture-mode Write-stripping) is the cascade vector that opened the Monitor() runaway loop in a production session (2026-05-03), burning hours of haiku tokens. For the GATE RUNNERS (pre-flight/verify-done) there is no inline fallback — fix the dispatch and retry. ORCHESTRATOR_INLINE is a sanctioned last resort ONLY for the adversarial code review (Step 5), never for the gate runners.

NEVER use the Skill tool to invoke these (60x cost). NEVER use `Agent(subagent_type: …)` (fails from the fork → silent inline degradation). NEVER hand-roll the `claude -p` invocation (drops the allowlist derivation + capture-mode Write-stripping) — always go through the helper. **(W4-413, 2026-06-03: now HOOK-ENFORCED — `~/.claude/hooks/block-v-polling.sh` DENIES a hand-rolled `claude -p --agent <runner>` Bash command. A hand-rolled child also bypasses the helper's `_run_bounded` 900s watchdog and stranded for over an hour in prod. If the helper APPEARS to fail, a `WARNING: could not parse tools:` line is NON-FATAL — retry the EXACT helper call; do NOT debug it or test `claude -p` variants.)**

---

## MODE Resolution (W16 — full decision tree)

Resolution happens INSIDE `v-emit-prompt.sh`; the orchestrator does not compute MODE itself. The tree the helper applies:

| Condition (evaluated in order) | MODE |
|---|---|
| `WORKFLOW=maintenance` OR `feature_tiny` OR `feature_small` | `scoped` |
| (anything else — bug fix, feature_medium/large) AND `DIRTY_COUNT <= 40` | `scoped` |
| (anything else) AND `DIRTY_COUNT > 40` (very large diff → early full) | `full` |
| `PARALLEL_SESSIONS_DETECTED=true` AND `DIRTY_COUNT > 0` (overrides above) | `dirty-tree` |

**W-perf3:** SCOPED is the per-session default. The full suite is NOT skipped — it runs bounded-parallel (core/concurrency-aware `--processes`, lock-serialized) at the Step-6 worktree/scoped final check (`v-completion.md` § W16-2), the authoritative regression gate before merge-to-main. So a scoped pre-flight is a safe fast-iteration default; `full` pre-flight is reserved for very large diffs where early breakage signal beats iteration speed. The MODE selection drives which subset of pre-flight gates run (scoped = only changed-file scope; full = entire repo; dirty-tree = filter out unrelated dirty changes).
