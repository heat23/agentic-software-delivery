#!/usr/bin/env bash
# artifact-location-check.sh
# Event: PreToolUse (matcher: Write|Edit registered; script filters to Write only via early-exit)
# Version: 4.0.0   ← Phase-2 artifact relocation (2026-07-06): the planning/report families
#                    (PLAN, AUDIT_REPORT, POLISH_PLAN, IMPLEMENTATION_REPORT, HANDOFF, TRAFFIC_PLAN,
#                    DOCS_AUDIT, LAUNCH_PLAN, ADMIN/CONSOLIDATED/PRELAUNCH audit reports, the
#                    report-only design/audit families, …) now ALSO redirect into .v/artifacts.
#                    ONLY SESSION_LOG* stays at the repo root (Phase 3). 3.0.0 = Phase-1 gauntlet
#                    families; 2.0.0 = W26-followup PreToolUse auto-redirect (v1.x = PostToolUse warn).
#
# Purpose: when a /v session artifact (any of the families in the line-~80 basename regex) is being
# Write-tool'd into a worktree subdirectory (.worktrees/<branch>/...), auto-redirect the file_path
# OUT of the worktree via Claude Code's `updatedInput` mechanism. As of Phase 2 EVERY /v artifact
# family redirects to <repo_root>/.v/artifacts/ (the canonical dir) EXCEPT SESSION_LOG* (+ its
# MISSING/FAILED/INVALID markers), which stay at the bare repo root until their Phase-3 migration.
#
# Why: worktrees are deleted at merge-back. Artifacts written inside them are LOST.
# v1.x was a PostToolUse async warning — by the time it fired, the file was already
# committed at the wrong path and the haiku had moved on. v2 fires BEFORE the Write
# completes and silently corrects the path, making the misplacement impossible.
#
# Production evidence (W26 audit, a production session):
# "PRE_FLIGHT_REPORT initially written to worktree path; corrected to repo root" —
# the v1 hook noticed AFTER the fact and the haiku had to manually re-write to the
# correct location. Cost: extra turn + ~800 tokens. v2 eliminates the round-trip.
#
# Behavior matrix:
#   Tool != Write                                  -> allow silent
#   Filename not a session artifact pattern        -> allow silent
#   File path NOT inside .worktrees/               -> allow silent
#   File path INSIDE .worktrees/<wt>/<artifact>    -> return updatedInput with
#                                                     file_path = <repo_root>/<artifact>
#                                                     + stderr note for visibility
#
# Exit code: always 0 (Claude Code reads the JSON output, not the exit code).

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "artifact-location-check"
fi




# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only intercept Write -- Edit modifies existing files which are already in the
# right place; the redirect would move existing content, which is wrong.
if [[ "$TOOL_NAME" != "Write" ]]; then
  profile_done
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# Match session artifact filename patterns.
BASENAME=$(basename "$FILE_PATH")
if ! echo "$BASENAME" | grep -qE '^(PLAN|PLANNING_PASS|AUDIT_REPORT|CONSOLIDATED_AUDIT_REPORT|REFACTOR_PLAN|POLISH_PLAN|BUILD_BLOCKER|IMPLEMENTATION_REPORT|PROGRESS_NOTE|PRE_FLIGHT_REPORT|PRE_FLIGHT_ADDENDUM|VERIFY_DONE_REPORT|LAUNCH_CHECKLIST|LAUNCH_PLAN|PRELAUNCH_READINESS_REPORT|TRAFFIC_PLAN|DOCS_AUDIT|AGENT_REVIEW|HANDOFF|BLOCKED|SESSION_LOG|UX_CRITIQUE|WORKFLOW_VERIFICATION|WORKFLOW_BLAST_RADIUS|SUCCESS_CRITERIA|IMPACT_MAP|QA_REPORT|QA_REMEDIATION|TRIVIAL_PASS|DIFFERENTIATION_BRIEF|SKILL_REVIEW_REPORT|GAUNTLET_REPORT|BUG_HUNT_REPORT|LEGAL_AUDIT|PROD_TRIAGE|V_NEXT_REPORT|ACTIVATION_FUNNEL|PRICING_STRATEGY|BETA_PROGRAM|ILLUSTRATION_SYSTEM|FEATURE_ROADMAP|PACK_RUNNER_FORENSICS_REPORT)_.*\.(md|yaml|yml|json)$'; then
  profile_done
  exit 0
fi

# Detect worktree containment. Pattern: .../.worktrees/<wt-name>/...
# Anchor on the literal `.worktrees/` segment to avoid false positives on filenames
# that happen to contain "worktrees" outside that path.
if ! echo "$FILE_PATH" | grep -qE '/\.worktrees/'; then
  profile_done
  exit 0
fi

# Compute the parent repo root: everything before /.worktrees/
REPO_ROOT="${FILE_PATH%%/.worktrees/*}"

# Defensive: refuse to redirect if computed REPO_ROOT looks malformed (empty,
# system path, or unreadable). Falling through to allow lets the original Write
# happen at the worktree path -- v1's PostToolUse warning behavior, still useful
# as a backstop if both hooks are registered.
case "${REPO_ROOT:-}" in
  ""|"/"|"/Users"|"/home"|"/root"|"/tmp"|"/var"|"/usr"|"/etc"|"/bin"|"/sbin"|"/opt"|"/private"|"/System"|"/Library"|"/Volumes"|"/dev"|"/proc"|"/sys")
    echo "WARN: artifact-location-check refusing to redirect: computed REPO_ROOT=$REPO_ROOT looks unsafe (worktree path: $FILE_PATH)" >&2
    profile_done
    exit 0
    ;;
esac

# Defensive: target dir must exist + be writable. Otherwise we'd redirect into
# the void and the Write would fail at a different path. Allow original.
if [[ ! -d "$REPO_ROOT" ]] || [[ ! -w "$REPO_ROOT" ]]; then
  echo "WARN: artifact-location-check: REPO_ROOT not writable ($REPO_ROOT); allowing original worktree write at $FILE_PATH" >&2
  profile_done
  exit 0
fi

# Artifact relocation (single source: skills/v/references/v-artifact-dir.sh; every reader —
# Stop hook ARTIFACT_SEARCH_DIRS, selfcheck, gauntlet-attest, merge-back, run-v-packs, and the
# skill-side `ls`/`find` globs — is dual-search with root as a read-only legacy fallback).
# As of Phase 2 (2026-07-06) EVERY /v artifact family redirects to `.v/artifacts/` (the `*)`
# default below). The ONLY family still root-cased is SESSION_LOG* (+ its MISSING/FAILED/INVALID
# markers) — Phase 3, its own ~14-file decentralized root contract. Keep this split in sync with
# skills/v/references/v-contract-audit-test.sh §G4b (asserts the Phase-2 families are ABSENT from
# the root-case) and §G4c (live-fires PLAN→.v/artifacts, SESSION_LOG→root).
case "$BASENAME" in
  SESSION_LOG*)
    # Phase 3 (not yet migrated): SESSION_LOG_<sid>.yaml + its MISSING/FAILED/INVALID markers are a
    # separate ~14-file decentralized root contract (finalize/integrity/resolver/abandonment +
    # -maxdepth 1 finds + worktree-safety lock-reclaim). They STAY at the repo root until Phase 3.
    # Every other /v artifact family — gauntlet (Phase 1) AND planning/report (Phase 2) — is now
    # canonical under .v/artifacts.
    TARGET_DIR="$REPO_ROOT"
    ;;
  *)
    TARGET_DIR="$REPO_ROOT/.v/artifacts"
    # SREV-001 (codex review 2026-07-06): guard the DIRECTORY segments, not just the final file.
    # `mkdir -p` succeeds straight through a pre-existing symlinked dir, and the later `-L` check
    # on $CORRECTED can't see a symlinked PARENT — so a planted `.v` -> /elsewhere symlink would
    # silently route the redirected Write outside the repo. Refuse the nested target instead
    # (root fallback is safe: readers are dual-search).
    if [[ -L "$REPO_ROOT/.v" ]] || [[ -L "$TARGET_DIR" ]]; then
      echo "WARN: artifact-location-check: $REPO_ROOT/.v(/artifacts) is a symlink; refusing nested redirect, using repo root" >&2
      TARGET_DIR="$REPO_ROOT"
    elif mkdir -p "$TARGET_DIR" 2>/dev/null; then
      # Canon-vs-canon containment: tolerate benign symlinks ABOVE the repo root (/tmp -> /private/tmp)
      # while rejecting any resolution that escapes <canonical repo root>/.v/artifacts.
      if command -v realpath >/dev/null 2>&1; then
        _ALC_TD_CANON=$(realpath "$TARGET_DIR" 2>/dev/null || echo "")
        _ALC_RR_CANON=$(realpath "$REPO_ROOT" 2>/dev/null || echo "")
        # Enforce ONLY when both resolved (macOS realpath lacks -e; an empty result means
        # "cannot canonicalize", NOT "escaped" — the -L guards above still cover the direct
        # symlink case, matching the pre-existing REPO_ROOT canonicalization tolerance below).
        if [[ -n "$_ALC_TD_CANON" && -n "$_ALC_RR_CANON" && "$_ALC_TD_CANON" != "$_ALC_RR_CANON/.v/artifacts" ]]; then
          echo "WARN: artifact-location-check: $TARGET_DIR resolves to [$_ALC_TD_CANON], outside [$_ALC_RR_CANON/.v/artifacts]; falling back to repo root" >&2
          TARGET_DIR="$REPO_ROOT"
        fi
      fi
      # Mirror v-artifact-dir.sh's self-ignoring .v/.gitignore (missing-file case only; the
      # stale-content self-heal stays v-artifact-dir.sh's job — it runs every /v bootstrap).
      if [[ "$TARGET_DIR" != "$REPO_ROOT" ]] && [[ ! -f "$REPO_ROOT/.v/.gitignore" ]]; then
        printf '*\n!.gitignore\n' > "$REPO_ROOT/.v/.gitignore" 2>/dev/null || true
      fi
    else
      echo "WARN: artifact-location-check: cannot create $TARGET_DIR; falling back to repo root" >&2
      TARGET_DIR="$REPO_ROOT"
    fi
    ;;
esac
CORRECTED="$TARGET_DIR/$BASENAME"

# Don't bother redirecting to the same path (race-safe no-op).
if [[ "$CORRECTED" == "$FILE_PATH" ]]; then
  profile_done
  exit 0
fi

# W26-followup-2 hardening (security review): refuse to redirect THROUGH a
# symlink at the target path. If $CORRECTED is a pre-existing symlink, the
# Write would follow it — an attacker who pre-created
# `<repo>/PRE_FLIGHT_REPORT_<sid>.md` as a symlink to `/etc/passwd` could
# weaponize this auto-redirector. Allow the original (worktree) write to
# happen instead — it'''s less harmful than overwriting through a symlink.
if [[ -L "$CORRECTED" ]]; then
  echo "WARN: artifact-location-check refusing redirect: $CORRECTED is a symlink (potential attack); allowing original worktree write" >&2
  profile_done
  exit 0
fi

# W26-followup-2 hardening: canonicalize REPO_ROOT via realpath to defeat
# `..` traversal and intermediate symlinks that might bypass the blacklist.
# realpath -e errors on nonexistent paths; we already verified -d/-w above.
if command -v realpath >/dev/null 2>&1; then
  REPO_ROOT_CANON=$(realpath -e "$REPO_ROOT" 2>/dev/null || echo "")
  if [[ -n "$REPO_ROOT_CANON" ]] && [[ "$REPO_ROOT_CANON" != "$REPO_ROOT" ]]; then
    # Re-check blacklist against canonical form
    case "$REPO_ROOT_CANON" in
      ""|"/"|"/Users"|"/home"|"/root"|"/tmp"|"/var"|"/usr"|"/etc"|"/bin"|"/sbin"|"/opt"|"/private"|"/System"|"/Library"|"/Volumes"|"/dev"|"/proc"|"/sys")
        echo "WARN: artifact-location-check: canonical REPO_ROOT=$REPO_ROOT_CANON is blacklisted; allowing original" >&2
        profile_done
        exit 0
        ;;
    esac
    REPO_ROOT="$REPO_ROOT_CANON"
    # Recompute the target under the canonicalized root, preserving the Phase-1 class split
    # AND the SREV-001 dir-level symlink guard + gitignore self-heal (SREV-002).
    case "$TARGET_DIR" in
      */.v/artifacts)
        TARGET_DIR="$REPO_ROOT/.v/artifacts"
        if [[ -L "$REPO_ROOT/.v" ]] || [[ -L "$TARGET_DIR" ]]; then
          echo "WARN: artifact-location-check: canonical $REPO_ROOT/.v(/artifacts) is a symlink; using repo root" >&2
          TARGET_DIR="$REPO_ROOT"
        elif mkdir -p "$TARGET_DIR" 2>/dev/null; then
          if [[ ! -f "$REPO_ROOT/.v/.gitignore" ]]; then
            printf '*\n!.gitignore\n' > "$REPO_ROOT/.v/.gitignore" 2>/dev/null || true
          fi
        else
          TARGET_DIR="$REPO_ROOT"
        fi
        ;;
      *)
        TARGET_DIR="$REPO_ROOT"
        ;;
    esac
    CORRECTED="$TARGET_DIR/$BASENAME"
    # Re-check the symlink guard against the canonicalized target
    if [[ -L "$CORRECTED" ]]; then
      echo "WARN: artifact-location-check: canonical $CORRECTED is a symlink; allowing original" >&2
      profile_done
      exit 0
    fi
  fi
fi

# Inject the corrected file_path via Claude Code's PreToolUse updatedInput.
# Same pattern as enforce-haiku-dispatch.sh uses for model auto-fix on Agent.
UPDATED=$(echo "$INPUT" | jq --arg p "$CORRECTED" '.tool_input | .file_path = $p')

echo "[artifact-location-check] auto-redirected: $FILE_PATH -> $CORRECTED (artifact moved out of worktree)" >&2

jq -n --argjson updated "$UPDATED" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":$updated}}'

profile_done
exit 0
