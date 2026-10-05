# Runtime Prerequisites (W22-2 + W23 follow-up + W24) (extracted from /v SKILL.md)

> The orchestrator's bash environment and production hooks both require two pieces of runtime infrastructure to be in place. Read this on first /v invocation in a new operator environment to verify both prereqs are met. Subsequent invocations skip the verification (the bootstrap script's W21 DETECTION_ERROR check surfaces missing prereqs at Step 0 anyway).

## Runtime Prerequisites (W22-2 / W23-followup / W24)

Before /v can run reliably, two pieces of runtime infrastructure MUST be in place. The orchestrator's bash environment and the production hooks both depend on these.

### Prereq 1: `CLAUDE_SESSION_ID` resolvable at bootstrap

`/v` resolves all artifact filenames from `$CLAUDE_SESSION_ID`. Wave 6/Wave 11 production logs showed Claude Code does NOT consistently export `CLAUDE_SESSION_ID` into the orchestrator's bash environment. W12-1 added literal sed substitution that masks this for sub-agent dispatches, but the orchestrator's own bash still needs it for `git worktree add -b "build/<scope>-${SESSION_ID}"`, session-writes log naming, etc.

**W23 follow-up (FND-19) — important correction:** the original W22 instructions in this file recommended a SessionStart hook of the form `[ -n "$CLAUDE_SESSION_ID" ] && export CLAUDE_SESSION_ID`. This is a no-op. Production logs (4 sessions, 2026-04-29) confirmed Claude Code's SessionStart hook stdout becomes the model's `additionalContext`, not the bash environment — so a `printf 'export CLAUDE_SESSION_ID=...'` line is never sourced into the orchestrator's bash. The W23 v2 hook persists the SID to a runtime file instead, and the bootstrap script reads it as a fallback when the env var is empty.

**Install the v2 SessionStart hook** at `~/.claude/hooks/session-start-export-sid.sh`:

```bash
#!/usr/bin/env bash
# session-start-export-sid.sh — v2.0.0 (W23 follow-up FND-19)
# Persists the current session's CLAUDE_SESSION_ID to a runtime file so
# bash invocations later in the session (orchestrator Step 0 bootstrap,
# stop-hook validators, etc.) can resolve it even though Claude Code does
# not export it into bash env automatically.
set -euo pipefail

RUNTIME_DIR="$HOME/.claude/runtime"
mkdir -p "$RUNTIME_DIR"

# Resolve SID from stdin (preferred — Claude Code passes session_id as JSON)
# or from CLAUDE_SESSION_ID env var if it happens to be set.
INPUT=$(cat 2>/dev/null || true)
SID=""
if command -v jq >/dev/null 2>&1 && [ -n "$INPUT" ]; then
  SID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi
[ -z "$SID" ] && SID="${CLAUDE_SESSION_ID:-}"

# Validate canonical UUID shape before persisting (reject garbage so a stale
# file never tricks downstream consumers into accepting a non-session ID).
if echo "$SID" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  printf '%s' "$SID" > "$RUNTIME_DIR/current-session-id"
  # Also export — useful when this hook IS sourced (some operator setups source
  # SessionStart hooks via shell wrappers). Harmless when it's not.
  export CLAUDE_SESSION_ID="$SID"
else
  # Empty out the file so a previous session's SID isn't misread as the current.
  : > "$RUNTIME_DIR/current-session-id"
  echo "WARN: session-start-export-sid.sh could not resolve SID; runtime file emptied." >&2
fi
exit 0
```

Register in `~/.claude/settings.json` — note Claude Code wraps each event's hook list in a `{ "hooks": [...] }` object inside an array (verify against your existing settings.json structure):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/session-start-export-sid.sh"
          }
        ]
      }
    ]
  }
}
```

If `~/.claude/settings.json` already has a `SessionStart` array, append a new hook entry to the existing inner `hooks: []` array rather than replacing the structure. Mis-shaped JSON will silently drop the hook (Claude Code parses but doesn't validate against schema).

**How resolution works at /v Step 0:** the bootstrap script (`v/references/v-bootstrap.sh` v2) checks `$CLAUDE_SESSION_ID` first, then falls back to `~/.claude/runtime/current-session-id`. If both are empty, it emits `DETECTION_ERROR=session_id_unset_at_bootstrap` and Step 0 exits with a clear error rather than silently producing fallback IDs. The W24 dispatch helper (`v-emit-prompt.sh`) does the same fallback chain when emitting haiku dispatch prompts.

### Prereq 2: `validation.sh` accepts all 3 review models

W13 introduced tiered review models (haiku/sonnet/opus). The W12-2 Post-Dispatch Wrap rule says the orchestrator constructs AGENT_REVIEW from a canonical skeleton with `Model: haiku` literal as line 1, regardless of the actual reviewer model — this preserves the existing validator contract. **However**, if the orchestrator forgets to wrap (Wave 11 evidence: 3/5 sessions did), the dispatched agent's first line is the dispatched model name, and `validation.sh` rejects the artifact.

To make the validator forgiving regardless of orchestrator wrap behavior, update the regex:

```bash
# ~/.claude/hooks/lib/validation.sh — find the AGENT_REVIEW Model line check
# OLD:  head -1 "$file" | grep -qx "Model: haiku" || { echo "..." ; return 1; }
# NEW:  head -1 "$file" | grep -qE "^Model: (haiku|sonnet|opus)$" || { echo "..." ; return 1; }
```

Until this prereq is met, prefer the orchestrator's wrap path (default behavior; ensures `Model: haiku` line 1 regardless of review model). The new `Reviewer model:` provenance field carries the semantic truth.

### Prereq 3 (W24): hook lib `v-tmp-dir.sh` present

Hooks that previously wrote markers and baselines to `${TMPDIR:-/tmp}/claude-hooks` or `/tmp/<baseline>-${SID}.txt` now route through `~/.claude/hooks/lib/v-tmp-dir.sh`, which prefers `$REPO_ROOT/.v/tmp/` and only falls back to `/tmp` when the repo isn't available. This keeps marker/baseline state per-repo (no cross-repo leakage) and respects the workspace policy of not polluting host `/tmp`.

Affected hooks (must source the lib): `session-env-check.sh`, `stop-completion-check.sh`, `enforce-agent-review.sh`, `enforce-scope-guard.sh`, `auto-branch-on-scope.sh`, `post-build-validate.sh`. Each sources the lib and uses `v_tmp_dir`, `v_tmp_find`, or `v_tmp_marker_dir` instead of inlining the `${TMPDIR:-/tmp}/claude-hooks` pattern.

If the lib is missing, sourcing it fails — the hooks then `set -e` out of scope on the source line and the session start aborts with a clear error. This is desired: don't run with broken state.

### Verifying prereqs

```bash
# Prereq 1: SID resolvable from env OR runtime file (full UUID validation)
{ [ -n "${CLAUDE_SESSION_ID:-}" ] || \
  grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    ~/.claude/runtime/current-session-id 2>/dev/null; } \
  && echo "Prereq 1: OK" \
  || echo "Prereq 1: MISSING — install session-start-export-sid.sh v2"

# Prereq 2: validation.sh accepts all 3 models
grep -qE 'Model: \(haiku\|sonnet\|opus\)' ~/.claude/hooks/lib/validation.sh \
  && echo "Prereq 2: OK" \
  || echo "Prereq 2: MISSING — update validation.sh regex"

# Prereq 3 (W24): v-tmp-dir lib present, sourceable, AND prefers the
# repo-local path (not /tmp fallback). The lib always emits SOMETHING from
# v_tmp_dir, so testing -n is too weak — verify it picked .v/tmp.
( cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" && \
  source ~/.claude/hooks/lib/v-tmp-dir.sh 2>/dev/null && \
  [ "$(v_tmp_dir)" = "$(pwd)/.v/tmp" ] ) \
  && echo "Prereq 3: OK" \
  || echo "Prereq 3: MISSING or fallback active — install lib/v-tmp-dir.sh AND ensure .v/tmp writable"
```

If any prereq fails, /v will work for routine sessions but exhibit confusing errors on edge cases (parallel sessions, hostile reviews, headless attestation). Install all three before heavy use.

---
