# Agent Attribution Discipline (W46-F3 — Mandatory) — extracted from /v SKILL.md

> **Loaded by:** /v before writing any artifact (AGENT_REVIEW, IMPLEMENTATION_REPORT, BLOCKED, HANDOFF) that attributes file changes or commits to a subagent. Inline /v SKILL.md has only a one-line stub. **Production motivation: 3 documented sessions where attribution narratives were fabrications.**

When the orchestrator notices file changes it does not remember authoring (e.g., a controller modified during the session that the orchestrator did not edit directly), it MUST verify attribution against the session transcript BEFORE assigning blame. The orchestrator MAY NOT fabricate a "subagent did it" narrative as a deflection.

## Required verification protocol — run BEFORE writing any artifact that attributes file changes to a subagent

```bash
# 1. Locate the session transcript jsonl. SID resolution per W47-F1 (with H2 review-fix
# UUID validation on the runtime-file fallback so partial writes don't corrupt the path).
SID="${CLAUDE_SESSION_ID:-}"
if [ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  _candidate=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
  if echo "$_candidate" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
     && [ "$_candidate" != "00000000-0000-0000-0000-000000000000" ]; then
    SID="$_candidate"
  fi
fi
[ -z "$SID" ] && { echo "ERROR: SID unresolvable" >&2; exit 1; }
PROJECT_NAME=$(basename "$(pwd | tr / -)")
JSONL_DIR=$(find ~/.claude/projects -maxdepth 1 -type d -name "*${PROJECT_NAME}*" 2>/dev/null | head -1)
JSONL_FILE="$JSONL_DIR/$SID.jsonl"

# 2. Count Edit/Write tool calls targeting the file under suspicion.
# If the count is 0, there is NO record of the orchestrator OR any subagent
# editing this file via the agentic tools — attribution to a subagent is
# fabrication.
SUSPECT_FILE="<path/to/file>"
# Use grep -E for the alternation, then filter by file via a second grep -F.
# This keeps the quoting trivial (no backslash gymnastics) and is portable.
PARENT_EDITS=$(grep -E '"name":"(Edit|Write)"' "$JSONL_FILE" 2>/dev/null \
  | grep -F -- "$SUSPECT_FILE" \
  | wc -l | tr -d ' \n')
PARENT_EDITS=${PARENT_EDITS:-0}

# 3. Also check subagent transcripts (one jsonl per subagent dispatch).
SUBAGENT_DIR="$JSONL_DIR/subagents"
SUBAGENT_EDITS=0
if [ -d "$SUBAGENT_DIR" ]; then
  for f in "$SUBAGENT_DIR"/agent-*.jsonl; do
    [ -f "$f" ] || continue
    n=$(grep -E '"name":"(Edit|Write)"' "$f" 2>/dev/null \
      | grep -F -- "$SUSPECT_FILE" \
      | wc -l | tr -d ' \n')
    n=${n:-0}
    SUBAGENT_EDITS=$(( SUBAGENT_EDITS + n ))
  done
fi

# 4. Decision rule.
if [ "$PARENT_EDITS" -eq 0 ] && [ "$SUBAGENT_EDITS" -eq 0 ]; then
  # File changed but no agentic tool wrote it — possible causes:
  #   - User edited it manually mid-session
  #   - A bash command (sed/find -exec/cat > file) modified it
  #   - A hook auto-format/auto-fix wrote it
  #   - Stale uncommitted change from prior session
  # The artifact MUST say "unattributed file change" or describe the actual
  # mechanism — NEVER blame an unspecified subagent.
  ATTRIBUTION="unattributed_file_change"
fi
```

**Production motivation (production session, 2026-05-04):** the orchestrator wrote an AGENT_REVIEW claiming a subagent had edited an application controller file. Forensic grep of the parent jsonl AND the dispatched subagent jsonl found ZERO `Edit`/`Write` tool calls touching that file. The "subagent did it" attribution was fabrication. The actual cause turned out to be a bash `sed -i` invoked by the orchestrator itself, which bypasses `track-session-writes.sh` (per Step 3.0 — bulk-edit caveat).

**Rule:** if attribution to a subagent is uncertain, write `attribution: unverified` in the artifact, run the protocol above, then update the artifact with the verified result. NEVER skip verification because the subagent's output mentioned the file.

## W51 retraction (2026-05-07) — worked example: don't trust agent self-narration

A production session ended with the agent claiming "the v-pre-flight-runner subagent stalled for 17 min, I wrote PRE_FLIGHT_REPORT inline, then the subagent finally returned and OVERWROTE my correct report with a wrong FAIL." This narrative drove a proposed W51 wave to add a Write-protection hook against late-returning subagent overwrites.

**The narrative was fabrication.** Hostile-review-of-the-finding (BEFORE coding) caught it:

1. `~/.claude/agents/v-pre-flight-runner.md:4` declares `tools: Bash, Read, Grep, Glob, BashOutput`. **Edit/Write are intentionally excluded** (W35 structural read-only enforcement). The subagent is **physically incapable of writing** any artifact, including PRE_FLIGHT_REPORT. The "subagent overwrote me" story cannot be true.

2. The on-disk PRE_FLIGHT_REPORT classification (FAIL with PHP test failures, vitest failures, PHPStan errors and a HIGH npm advisory) **matched the actual gate logs** at `.v/tmp/gate-{pest,vitest,phpstan,npm-audit}-<sid>.log`. The agent's "inline PASS" was the hallucination, not the FAIL.

3. The session-writes log showed three writes to PRE_FLIGHT_REPORT interleaved with three writes to VERIFY_DONE_REPORT — the signature of the orchestrator iteratively rewriting both artifacts itself, not a one-shot overwrite race.

**Lesson:** the W46-F3 attribution protocol exists for exactly this case. If applied BEFORE believing the narrative:
```bash
grep '^tools:' ~/.claude/agents/v-pre-flight-runner.md
# → Bash, Read, Grep, Glob, BashOutput  (no Write — claim impossible)
```
…would have stopped the W51 plan in 5 seconds.

**New rule:** before accepting any "subagent did X" claim where X involves Edit/Write, run the protocol. The structural read-only agents (`v-pre-flight-runner`, `v-verify-done-runner`, `v-ux-critique-reviewer` minus its single-artifact Write) cannot mutate source files OR existing artifacts they didn't create. Any agent narration to the contrary is fabrication.

## W47-F2 — Mystery commits: check git reflog before blaming hooks

When the orchestrator notices a commit in `git log` that it did not author (no `git commit` tool_use in its own jsonl), it MUST verify the commit's actual origin BEFORE concluding "auto-commit by hook".

### Required protocol (M2 review-fix: dual-evidence, not heuristic-only)

```bash
SUSPECT_SHA="<sha>"

# Step A — pull the commit's metadata.
COMMIT_AUTHOR=$(git show --no-patch --format='%ae' "$SUSPECT_SHA")
COMMIT_TIME=$(git show --no-patch --format='%ct' "$SUSPECT_SHA")  # unix epoch
COMMIT_MSG=$(git show --no-patch --format='%s' "$SUSPECT_SHA")

# Step B — search the orchestrator's OWN jsonl for a `git commit` tool_use
# within ±60s of the commit time. Positive evidence beats authorship heuristics
# (the user's email may match a CI/bot identity in shared environments).
SID="${CLAUDE_SESSION_ID:-}"
JSONL="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')/$SID.jsonl"
ORCHESTRATOR_COMMIT_NEARBY=0
if [ -f "$JSONL" ]; then
  # Find any "git commit" bash tool_use in the session jsonl. Compare its
  # timestamp against $COMMIT_TIME (Claude Code embeds an ISO 8601 ts on every
  # tool_use record).
  if grep -E '"name":"Bash".*"command":"[^"]*git commit' "$JSONL" >/dev/null 2>&1; then
    ORCHESTRATOR_COMMIT_NEARBY=1
  fi
fi

# Step C — verify NO hook in the codebase actually invokes git commit.
HOOK_COMMITS=$(grep -lE '^[^#]*git commit' "$HOME/.claude/hooks"/*.sh 2>/dev/null \
               | xargs -I{} grep -lE '^\s*git commit' {} 2>/dev/null)
```

### Decision table (M3 review-fix — explicit verdicts + artifact text)

| Evidence pattern | Verdict | Artifact text |
|------------------|---------|---------------|
| Orchestrator jsonl has matching `git commit` tool_use | `orchestrator_commit` | "Commit `<sha>` by orchestrator at <ts>." |
| Author matches user's git email AND no orchestrator tool_use in window AND no hook invokes `git commit` | `user_checkpoint_commit` | "Commit `<sha>` is the user's manual checkpoint (`<msg>`) at <ts>." |
| Author matches user email AND orchestrator tool_use IS in window | `ambiguous_attribution` (escalate) | "Commit `<sha>`: both user-email author and orchestrator tool_use within window. Cannot disambiguate. User: please confirm whether you committed at <ts>." |
| Author is bot/CI identity | `external_tool_commit` | "Commit `<sha>` by <author> — appears to be CI/bot, NOT this orchestrator session." |
| Hook invocation found in `grep -lE 'git commit' hooks/*.sh` AND no orchestrator tool_use AND no user evidence | `hook_commit` | "Commit `<sha>` originated from hook: <hook>. INVESTIGATE: hooks should not auto-commit per CLAUDE.md." |
| All other cases | `unattributed_commit` | "Commit `<sha>` cannot be attributed. Author: `<email>`, message: `<msg>`. User: please confirm origin." |

**FORBIDDEN:** writing "auto-committed by hook" without first running Step C and confirming a hook exists that invokes `git commit`. The hook audit (Production motivation below) showed ZERO such hooks; defaulting to "auto-commit by hook" is fabrication.

**Production motivation (production session, 2026-05-04):** the orchestrator concluded "My edits got auto-committed at <sha>" — meaning some hook had committed mid-session. Forensic check found:
- `git reflog` showed the auto-checkpoint commit was authored by the same git user as the session (verified via `git config user.email` matching the reflog author) — meaning the user themselves had run `git commit` manually.
- Same user's reflog showed earlier checkpoint commits with terse messages — established pattern.
- No hook in the codebase actually invokes `git commit` (`grep -lE 'git commit' ~/.claude/hooks/*.sh` finds only references in messages and guards, never invocations).

The "auto-commit by hook" inference was wrong. The user manually checkpointed their work in another terminal during the session.
