# V Resilience — Documented Fallback Protocol

_Last reviewed: 2026-08-03 (content-quality remediation pass — cross-checked against `v/references/v-run-gates.sh`, `v/references/v-bootstrap.sh`, and `references/v-orchestrator-map.md` for any since-built heartbeat/journal/recovery-sweep capability; none found — every "What's NOT here" item below is still accurate. No decidability, currency, or fabricated-API defects found in this file._

**Status:** Active. This file documents the orchestrator's fallback behavior when an autonomous decision can't be made cleanly. There is no autonomous crash-recovery, no heartbeat-based session reaper, and no triage matrix — the orchestrator falls back to documented sensible defaults and writes a `BLOCKED_<sid>.md` artifact when a situation is genuinely ambiguous.

This file exists so cross-references from `_v-core.md` and other shared modules resolve to a real anchor describing what the orchestrator actually does today.

## What's NOT here

The orchestrator does not implement any of the following. Treat references in older docs as historical:

- Heartbeat schema for session liveness detection
- Append-only journal at `~/.claude/sessions/<project_hash>/<sid>/journal.md`
- Autonomous triage matrix for orphaned worktrees
- Automatic recovery sweep at `/v` startup
- Per-phase atomic commits with end-of-session squash
- Per-session token meter

If any of these capabilities is needed, the path is to design and ship them as a versioned change to `_v-exec.md` and `/v` SKILL.md — not to assume they exist.

## Documented fallback paths (current behavior)

When the orchestrator hits a situation that prior docs called out as needing "self-healing recovery" or "quorum reviewer escalation":

1. **Apply the documented sensible default** per `_v-exec.md` § Safety Gates (autonomous safety judgment). The default is always the conservative path — do not delete uncommitted work, do not auto-merge ambiguous state, do not silently overwrite an artifact whose schema doesn't match.
2. **If the situation is genuinely ambiguous** (no documented default applies, or the default itself would lose work), write a `BLOCKED_<sid>.md` artifact at the project root describing what couldn't be resolved. Include: the operation that was attempted, the state that prevented progress, the documented defaults that were considered, and the next concrete steps the operator (or a future session) can take.
3. **Continue with the safer path** — the orchestrator does not stop the entire session unless the BLOCKED state would corrupt outputs already written. When in doubt, finish the work that is unambiguous, document the rest in `BLOCKED_<sid>.md`, and let the next session iteration pick up.

## Common BLOCKED scenarios

| Trigger | Default action | When to write BLOCKED |
|---|---|---|
| Worktree on non-main branch with uncommitted changes during merge-back | Stop merge-back; require the operator to commit or stash | Always (the merge-back is unrecoverable until resolved) |
| `MERGE_HEAD` exists in the repo at session start | Refuse to start new work | Always (mid-merge state requires manual judgment) |
| Stop-hook artifact validation fails after retry | Re-run validation; if still failing, write BLOCKED with the validator output | Only after retry — transient failures often clear |
| Two parallel sessions detect the same lock file | The earlier session continues; the later session writes BLOCKED and exits | Always (the orchestrator does not arbitrate between siblings) |
| Pre-flight gate fails three times with the same error | Stop; do not attempt a fourth retry | Always (loop suggests a problem the orchestrator can't fix) |

## When the protocol should change

This protocol is intentionally conservative. If a class of failures is showing up frequently in production (≥5 BLOCKED artifacts of the same shape across recent sessions), that's the signal to design a real autonomous recovery path for it — likely as new content in `_v-exec.md` § Safety Gates and a new step in `/v` SKILL.md. Update this file when that happens.
