# Stale Artifact Sweep (extracted from /v SKILL.md — W25)

> **Loaded by:** /v Entry sequence, immediately after Step 0 bootstrap. Inline /v
> SKILL.md should have only a one-line stub that names this reference. This file
> contains the full sweep rationale + bash.

## Why this exists

The orchestrator and its sub-skills write UUID-suffixed reports (`SESSION_LOG_<sid>.yaml`, `UX_CRITIQUE_<sid>.md`, `PRE_FLIGHT_REPORT_<sid>.md`, `AGENT_REVIEW_<sid>.md`, `VERIFY_DONE_REPORT_<sid>.md`, `IMPLEMENTATION_REPORT_<sid>.md`, `GAUNTLET_REPORT_<sid>.md`, `HANDOFF_<sid>.md`, plus the verification/analysis artifacts `ASYNC_LIFECYCLE_TRACE_<sid>.md`, `WORKFLOW_BLAST_RADIUS_<sid>.md`, `SUCCESS_CRITERIA_<sid>.md`, `IMPACT_MAP_<sid>.md`, `WORKFLOW_VERIFICATION_<sid>.md`, `QA_REPORT_<sid>.md`, `QA_REMEDIATION_<sid>.md`) under `$PROJECT_ROOT/.v/artifacts/` (Phase-1 relocation 2026-07-06; the bare `$PROJECT_ROOT/` root is a legacy location older sessions used — the Stop hook validates the CURRENT session's artifacts dual-search, `.v/artifacts` first then root). But artifacts from PRIOR sessions accumulate — in both locations — and pollute the tree, eventually causing the orchestrator to misread its own input.

This sweep moves prior-session artifacts to `$PROJECT_ROOT/.v/archive/<their-sid>/`. It runs ONCE per `/v` invocation right after Step 0, is non-blocking (failures are logged but never abort `/v`), and is idempotent.

**Bug 6 hardening (2026-05-28).** The old version SKIPPED files whose SID matched the current `$SESSION_ID` ("current session — leave in place for Stop hook"). That exception was wrong: SessionStart fires once per Claude Code conversation, so a second `/v` invocation in the same conversation inherits the SAME `CLAUDE_SESSION_ID` and sees the PRIOR invocation's same-SID artifacts. The current-SID skip caused those prior artifacts to silently satisfy the Stop hook for the second invocation, even when the second invocation skipped writing fresh artifacts. Observed in three production sessions (2026-05-28). The current-SID guard is REMOVED: every `/v` invocation now archives the prior invocation's artifacts as well, treating each `/v` invocation as a fresh "tracking session" for Stop-hook purposes. To preserve genuine within-invocation artifact accumulation, the sweep skips files whose mtime is NEWER than this invocation's start marker (`$V_TMP_DIR/v-invocation-start-<sid>.txt`, written at /v Step 0).

## Implementation

```bash
# W25: Archive stale UUID-suffixed artifacts from prior sessions.
# Self-resolves $PROJECT_ROOT and $SESSION_ID — Bash tool calls do NOT inherit env from
# Step 0 (per CLAUDE.md "Each call is independent — no cwd or env carryover between calls"),
# so this block must independently re-derive both. Pattern matches detect-recurrence-signal.sh.
# Idempotent + non-blocking — mv failures (permission, read-only FS) are silently skipped
# so this never breaks /v even on hostile filesystems.

# Resolve PROJECT_ROOT via git (mirrors Step 0 fallback path).
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$PROJECT_ROOT" ] || [ ! -d "$PROJECT_ROOT" ]; then
  : # not in a git repo — silently skip, archival is a nice-to-have
else
  # Resolve SESSION_ID via W47-F1: env first, then runtime file with UUID validation.
  SESSION_ID="${CLAUDE_SESSION_ID:-${SESSION_ID:-}}"
  if [ -z "$SESSION_ID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
    _candidate=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
    if echo "$_candidate" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
       && [ "$_candidate" != "00000000-0000-0000-0000-000000000000" ]; then
      SESSION_ID="$_candidate"
    fi
  fi
fi

if [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT" ] && [ -n "${SESSION_ID:-}" ]; then
  _UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
  _ARCHIVE_BASE="$PROJECT_ROOT/.v/archive"
  _ARCHIVED_COUNT=0
  mkdir -p "$_ARCHIVE_BASE" 2>/dev/null || true
  # Extend .v/.gitignore (already written by bootstrap to ignore tmp/) to cover archive/.
  if [ -f "$PROJECT_ROOT/.v/.gitignore" ] && ! grep -qxF 'archive/' "$PROJECT_ROOT/.v/.gitignore" 2>/dev/null; then
    echo 'archive/' >> "$PROJECT_ROOT/.v/.gitignore" 2>/dev/null || true
  fi
  # Bug 6: read THIS invocation's start marker (epoch seconds). The sweep uses it to
  # distinguish "prior-invocation same-SID artifacts" (pre-marker → archive them) from
  # "current-invocation in-progress artifacts" (post-marker → leave in place). The marker
  # is written by /v Step 0 (Bug 6 section). Absence falls back to legacy behavior (skip
  # only different-SID artifacts) so this stays safe on legacy callers.
  _V_TMP_DIR="${V_TMP_DIR:-$PROJECT_ROOT/.v/tmp}"
  _invocation_mark="$_V_TMP_DIR/v-invocation-start-${SESSION_ID}.txt"
  _mark_epoch=""
  if [ -f "$_invocation_mark" ]; then
    _mark_epoch=$(tr -d '[:space:]' < "$_invocation_mark" 2>/dev/null)
    case "$_mark_epoch" in ''|*[!0-9]*) _mark_epoch="" ;; esac
  fi
  _sid_lc_self=$(echo "$SESSION_ID" | tr '[:upper:]' '[:lower:]')
  _file_mtime() {
    case "$(uname -s)" in
      Darwin|*BSD) stat -f %m "$1" 2>/dev/null ;;
      *)           stat -c %Y "$1" 2>/dev/null ;;
    esac
  }
  # ORCHFIX-A3 (forensics 2026-07-02, split-brain): SESSION_LOG_* is
  # deliberately ABSENT from this pattern list. Session logs are the CANONICAL telemetry store —
  # the integrity sweep, the resolver, and every aggregation read them at root/.v/artifacts and
  # were blind to .v/archive. Archiving them produced provably-false MISSING markers ("no
  # session-log of any kind") minutes after this sweep moved a validating log, whose
  # remediation text then invited the documented-UNSAFE dead-branch regeneration, AND
  # resurrected quarantined .yaml.invalid content under clean canonical names inside the archive
  # (byte-identical copies of three invalid logs). Telemetry files are
  # never "stale working-tree pollution"; they are the record. Do NOT re-add them here.
  # Bite: skills/v/references/stale-sweep-sessionlog-exclusion-test.sh.
  for _pattern in \
    'UX_CRITIQUE_*.md' \
    'PRE_FLIGHT_REPORT_*.md' \
    'AGENT_REVIEW_*.md' \
    'VERIFY_DONE_REPORT_*.md' \
    'IMPLEMENTATION_REPORT_*.md' \
    'GAUNTLET_REPORT_*.md' \
    'HANDOFF_*.md' \
    'ASYNC_LIFECYCLE_TRACE_*.md' \
    'WORKFLOW_BLAST_RADIUS_*.md' \
    'SUCCESS_CRITERIA_*.md' \
    'IMPACT_MAP_*.md' \
    'WORKFLOW_VERIFICATION_*.md' \
    'QA_REPORT_*.md' \
    'QA_REMEDIATION_*.md' \
    'ABANDON_SUSPECT_*.md'; do
    # Nullglob-style: skip if no match (bash glob returns the literal pattern otherwise).
    # W-perf6: scan the repo root AND .v/artifacts/ — current sessions now CONSOLIDATE their
    # artifacts into .v/artifacts at completion, so prior-session ones to archive live there
    # too (the root scan stays for any straggler written legacy-style).
    for _srcdir in "$PROJECT_ROOT" "$PROJECT_ROOT/.v/artifacts"; do
     [ -d "$_srcdir" ] || continue
     for _f in "$_srcdir"/$_pattern; do
      [ -f "$_f" ] || continue
      _base=$(basename "$_f")
      _sid=$(echo "$_base" | grep -oE "$_UUID_RE" | head -1)
      [ -z "$_sid" ] && continue
      _sid_lc=$(echo "$_sid" | tr '[:upper:]' '[:lower:]')
      # W-perf10 FIX-8: NEVER archive a git-TRACKED artifact. `mv`-ing a tracked file leaves an
      # unstaged DELETION on main (some prior session committed it), which dirties the working tree
      # and can block THIS session's ff-only merge-back (observed in production: two tracked
      # WORKFLOW_BLAST_RADIUS_<otherSID>.md deletions, archived by this sweep, nearly blocked the
      # merge-back). Session housekeeping must never dirty main with ANOTHER session's tracked git
      # state. Tracked artifacts are an anomaly (artifacts are normally untracked / .v-gitignored);
      # leave them in place for a deliberate committed cleanup rather than a silent working-tree mv.
      if git -C "$PROJECT_ROOT" ls-files --error-unmatch -- "$_f" >/dev/null 2>&1; then
        continue
      fi
      # Same-SID handling (Bug 6): when marker is available, archive same-SID files that
      # are OLDER than this invocation (prior /v in same Claude Code conversation), keep
      # files NEWER than this invocation (in-progress writes from the current /v). When
      # marker is unavailable (legacy), preserve the old "skip current-SID" behavior so
      # callers without the marker keep their Stop-hook artifacts.
      if [ "$_sid_lc" = "$_sid_lc_self" ]; then
        if [ -n "$_mark_epoch" ]; then
          _f_mt=$(_file_mtime "$_f")
          if [ -n "$_f_mt" ] && [ "$_f_mt" -ge "$_mark_epoch" ]; then
            continue  # in-progress current-invocation artifact, leave in place
          fi
          # falls through to archive — prior-invocation same-SID artifact
        else
          continue  # legacy fallback (no marker): preserve old behavior
        fi
      fi
      mkdir -p "$_ARCHIVE_BASE/$_sid_lc" 2>/dev/null || continue
      if mv "$_f" "$_ARCHIVE_BASE/$_sid_lc/" 2>/dev/null; then
        _ARCHIVED_COUNT=$((_ARCHIVED_COUNT + 1))
      fi
     done
    done
  done
  if [ "$_ARCHIVED_COUNT" -gt 0 ]; then
    echo "[W25/Bug6] archived $_ARCHIVED_COUNT stale artifact(s) (incl. same-SID prior-invocation) to .v/archive/" >&2
  fi
fi
```

## What this does NOT touch

- The current `/v` invocation's freshly-written artifacts (mtime ≥ `v-invocation-start-<sid>.txt`). The Stop hook still validates these.
- Files without a UUID suffix in their name.
- Files in subdirectories.
- The `.v/tmp/` transient files (those are managed separately by bootstrap).
- Same-SID artifacts when the per-invocation marker is absent (legacy fallback).

## Failure modes — by design, all silent

- Read-only FS → no mv, current session continues normally with the pollution still present.
- Permission denied on `.v/archive/` → no mv, same as above.
- Unparseable filename without UUID → skipped (the `grep -oE` returns empty, `[ -z "$_sid" ] && continue`).
