#!/usr/bin/env bash
# uncommitted-changes-gate.sh
# QUALITY HOOK — P2
# Version: 3.2.0
# Event: Stop
# Purpose: Block session completion when there are unstaged modifications to
#          tracked files that were INTRODUCED by this session.
#          Pre-existing dirty files (captured at SessionStart by session-env-check.sh)
#          are reported as warnings but do NOT block.
#
# Changes in v3:
#   AVF-029: Uses shared lib/validation.sh for completion language detection.
#
# Changes in v3.1:
#   - Maintenance-only inline main-root sessions no longer hard-block on
#     unstaged session files. Code changes on main still require a scoped
#     checkpoint or a worktree/feature branch.
#   - Blocked guidance no longer references a nonexistent /commit skill.
#
# Changes in v3.2:
#   - W-attr-gate (Residual #1): the LEGACY no-writes-log-witness fallback no
#     longer attributes a SHARED primary tree's dirty files to this session.
#     Parallel sessions share the `main` checkout, so the shared-tree diff (and
#     the no-baseline "all dirty" path) swallowed concurrent siblings' edits and
#     false-blocked read-mostly sessions (analysis/log/handoff) into committing
#     files they never touched. On the shared primary tree (main/master,
#     non-worktree) with no witness the gate now degrades safe (advisory, no
#     block); session-PRIVATE trees (worktree / feature branch) keep their
#     legacy attribution. The writes-log path is unchanged. Covered by
#     uncommitted-changes-gate-test.sh.

set -euo pipefail

is_inline_maintenance_path() {
  local path="${1:-}"

  case "$path" in
    CLAUDE.md|AGENTS.md|README.md|README.*|docs/*|.claude/*|.claude-branch-lock|*/CLAUDE.md|*/AGENTS.md)
      return 0
      ;;
  esac

  return 1
}


# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat)

# W5G-1 (forensic 2026-06-07): do NOT blanket-exit on stop_hook_active — that made
# this gate FIRST-STOP-ONLY. Two production sessions: the artifact gate blocked once,
# the model's remediation EDITED code (QA fixes), and the next stop (active=true)
# sailed through here — fixes sat unstaged on a shared main for hours.
# Checks now re-run on active stops; lib/stop-rearm.sh caps the chain (deadlock
# escape), so the infinite-loop concern stays solved.
STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] || STOP_ACTIVE="false"

# W5G-8 (forensic 2026-07-10 #2): dispatched read-only runner sessions are EXEMPT (see
# check-review-artifact.sh W5G-8 for the full rationale; HMAC-authenticated via
# dispatched-runner.sh, NOT a static flag). Read-only runners are NOT commit-owning — they
# can never satisfy "create a scoped git checkpoint", so blocking them guarantees a 3-strike
# escape chain (two production sessions escaped THIS gate with the identical fingerprint —
# shared main-root dirt attributed to sessions that never wrote a file). COMMITTING runners
# (v-workflow-verifier) are NOT issued the token, so they keep this gate. The orchestrator
# session that owns the tree still gets blocked for the same files. Fail-closed on any doubt.
if [ -f "$HOOKS_LIB_DIR/dispatched-runner.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS_LIB_DIR/dispatched-runner.sh" 2>/dev/null || true
  if type _is_dispatched_runner >/dev/null 2>&1 && _is_dispatched_runner; then
    exit 0
  fi
fi

# Only run in git repositories
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# HOOKS_LIB_DIR was already resolved above (exported override honored, else derived from
# BASH_SOURCE). Do NOT re-derive it unconditionally here — that clobbered an exported value and
# made the gate impossible to load from a relocated/mutant copy, so the mutation gate could never
# exercise this data-loss-prevention enforcement (audit 2026-06-18, same survivor class as
# enforce-pre-commit-gates S-2). Seam: caller exports HOOKS_LIB_DIR=<real lib> and points at the
# mutant copy via V_UNCOMMITTED_GATE_OVERRIDE.

# Load shared validation functions (AVF-029)
if [[ -f "$HOOKS_LIB_DIR/validation.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/validation.sh"
fi

# Load shared session-writes helpers (parallel-session safe attribution)
if [[ -f "$HOOKS_LIB_DIR/session-writes.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/session-writes.sh"
fi

# W5G-1: re-arm state machine (see check-review-artifact.sh for rationale).
if [[ -f "$HOOKS_LIB_DIR/stop-rearm.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/stop-rearm.sh"
fi

# Get session ID for baseline lookup
# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
# (Moved ABOVE the completion-language check: the W5G-1 rearm-state lookup
# below needs the SID.)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")

if type rearm_init >/dev/null 2>&1; then
  rearm_init "uncommitted-changes-gate" "${SESSION_ID:-nosid}" "$STOP_ACTIVE"
fi

# Check last assistant message — only run for completion-language responses
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)

# Use shared pattern if available (AVF-029), else built-in fallback
_cw_pattern="${COMPLETION_WORDS_PATTERN:-complete|completed|done|finished|implemented|fixed|resolved|shipped|all.*pass|ready|working|accomplish|deliver|deploy|land|wrap|merge|finalize}"
if ! echo "$LAST_MSG" | grep -qiE "$_cw_pattern"; then
  # W5G-1: once this gate has blocked in the current chain, completion intent
  # is already established — a remediation message like "Committed the
  # checkpoint" must not dodge the re-check just because it lacks a completion
  # word. Skip-by-language only applies when no block is pending.
  if [ "$STOP_ACTIVE" != "true" ] || ! { type rearm_state_file >/dev/null 2>&1 && [ -f "$(rearm_state_file "uncommitted-changes-gate" "${SESSION_ID:-nosid}")" ]; }; then
    # WITNESS-OVER-FRAMING (forensic 2026-06-23): the completion-language heuristic must NOT
    # let a session that wrote tracked files (now still unstaged) DODGE the data-loss block by ending on a
    # no-completion-word message. One production session changed 2 .tsx files, then MISREPORTED "read-only research session,
    # no code changes, No log created" — its per-session writes-log witness pointed straight at the 2 still-
    # unstaged files, yet this language-skip stranded a real fix SILENTLY (one `git checkout` from loss, no
    # session log). The model's framing of its own completion must not override the on-disk witness. When the
    # writes-log witness (parallel-SAFE + attributable — NOT a shared-tree `git status`) shows session-owned
    # UNSTAGED TRACKED files, do NOT skip: fall through to the block. Legacy no-writes-log sessions keep the
    # language-skip (no sound attribution on a shared tree → could misattribute a concurrent sibling's files).
    _ucg_data_loss_witness=0
    if type get_session_writes >/dev/null 2>&1; then
      _ucg_sw=$(get_session_writes "$SESSION_ID" 2>/dev/null || true)
      if [ -n "$_ucg_sw" ]; then
        while IFS= read -r _ucg_wp; do
          [ -z "$_ucg_wp" ] && continue
          # Two-step capture (matches the line-~178 witness pattern in this file): separate the git-exit
          # case from the grep-exit case so a git failure can't be read as a (false) witness.
          _ucg_state=$(git status --porcelain -- "$_ucg_wp" 2>/dev/null || true)
          [ -z "$_ucg_state" ] && continue
          if printf '%s\n' "$_ucg_state" | grep -qE '^.[MADRC]'; then
            _ucg_data_loss_witness=1; break
          fi
        done <<< "$_ucg_sw"
      fi
    fi
    if [ "$_ucg_data_loss_witness" -eq 0 ]; then
      exit 0  # Not a completion response AND no data-loss witness — skip check (status quo)
    fi
    # else: a real session-owned-unstaged witness exists — a no-completion-word framing must not bury it.
  fi
fi

IMPLEMENTATION_ONLY_MODE="${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}"

if [ "$IMPLEMENTATION_ONLY_MODE" = "1" ]; then
  exit 0
fi

# Primary attribution: per-session writes log (parallel-session safe).
# The git working tree is shared across parallel Claude sessions, so
# `git status` cannot be used to attribute changes to a specific session.
# track-session-writes.sh records every Edit/Write/MultiEdit/NotebookEdit
# tool call into the writes log; this hook checks which of those paths
# are still in an unstaged state at session stop.
SESSION_WRITTEN=""
WRITES_LOG_AVAILABLE=0
if type get_session_writes >/dev/null 2>&1; then
  SESSION_WRITTEN=$(get_session_writes "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$SESSION_WRITTEN" ] || [ -f "$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)" ]; then
    WRITES_LOG_AVAILABLE=1
  fi
fi

NEW_UNSTAGED=""
if [ "$WRITES_LOG_AVAILABLE" -eq 1 ]; then
  # New path: only consult files THIS session wrote via tool calls.
  if [ -n "$SESSION_WRITTEN" ]; then
    while IFS= read -r _wp; do
      [ -z "$_wp" ] && continue
      # Per-path porcelain — uses pathspec so we don't fight rename detection.
      _state=$(git status --porcelain -- "$_wp" 2>/dev/null || true)
      [ -z "$_state" ] && continue
      # Y position (col 2) is unstaged state. Match unstaged tracked changes
      # only — skip clean (empty), pure-staged (Y is space), and untracked (??).
      if printf '%s\n' "$_state" | grep -qE '^.[MADRC]'; then
        NEW_UNSTAGED="${NEW_UNSTAGED}${_state}"$'\n'
      fi
    done <<< "$SESSION_WRITTEN"
    NEW_UNSTAGED=$(printf '%s' "$NEW_UNSTAGED" | awk 'NF' | head -10 || true)
  fi
else
  # Legacy fallback: session predates the track-session-writes.sh hook.
  # Use the old dirty-baseline diff so the gate doesn't silently disable.
  CURRENT_DIRTY=$(LC_ALL=C git status --porcelain 2>/dev/null | LC_ALL=C sort || true)
  # W25-F16: route through v_tmp_dir/v_tmp_find. New writes go to .v/tmp/;
  # legacy reads from old /tmp paths still load via v_tmp_find's migration check.
  if ! type v_tmp_dir >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/v-tmp-dir.sh" 2>/dev/null || true
  fi
  if type v_tmp_find >/dev/null 2>&1; then
    BASELINE_FILE=$(v_tmp_find "dirty-baseline-${SESSION_ID}.txt" 2>/dev/null || true)
    if [ -z "$BASELINE_FILE" ]; then
      BASELINE_FILE="$(v_tmp_dir 2>/dev/null || echo "${TMPDIR:-/tmp}")/dirty-baseline-${SESSION_ID}.txt"
    fi
    _VTMP_DIR_RESOLVED=$(v_tmp_dir 2>/dev/null || echo "${TMPDIR:-/tmp}")
  else
    BASELINE_FILE="${TMPDIR:-/tmp}/dirty-baseline-${SESSION_ID}.txt"
    _VTMP_DIR_RESOLVED="${TMPDIR:-/tmp}"
  fi
  BASELINE_DIRTY=""
  if [ -n "$SESSION_ID" ] && [ -f "$BASELINE_FILE" ]; then
    BASELINE_DIRTY=$(cat "$BASELINE_FILE" 2>/dev/null || true)
  fi
  if [ -n "$BASELINE_DIRTY" ]; then
    _tmp_current=$(mktemp "$_VTMP_DIR_RESOLVED/ucg-current.XXXXXX")
    _tmp_baseline=$(mktemp "$_VTMP_DIR_RESOLVED/ucg-baseline.XXXXXX")
    echo "$CURRENT_DIRTY" > "$_tmp_current"
    echo "$BASELINE_DIRTY" > "$_tmp_baseline"
    NEW_DIRTY=$(comm -23 "$_tmp_current" "$_tmp_baseline" || true)
    rm -f "$_tmp_current" "$_tmp_baseline" 2>/dev/null
  else
    NEW_DIRTY=$(echo "$CURRENT_DIRTY" | grep -E '^.[MADRC]' | grep -v '^?' || true)
  fi
  NEW_UNSTAGED=$(echo "$NEW_DIRTY" | grep -E '^.[MADRC]' | grep -v '^?' | head -10 || true)

  # W-attr-gate (Residual #1, 2026-06-02): the legacy fallback above attributes
  # via a SHARED-tree `git status` diff (or, with no baseline, ALL dirty tracked
  # files). On the shared primary tree (main/master, non-worktree) that cannot
  # tell THIS session's edits apart from a concurrent sibling session's — both
  # mutate the same checkout — so it false-blocks this session into committing
  # files it never touched (same shared-tree-attribution root cause fixed for
  # session-log commit attribution). Without the per-session writes-log witness
  # there is no sound attribution here, so discard it and DO NOT block. A
  # session-PRIVATE tree (linked worktree, or a non-main feature-branch checkout)
  # is not shared, so its legacy attribution stands.
  # Canonicalize to absolute paths before comparing: `git rev-parse --git-common-dir`
  # and `--git-dir` can return differently-formatted strings (one relative, one
  # absolute) for the SAME directory when cwd is a subdirectory of the repo root
  # rather than the root itself (observed: "../.git" vs "/repo/.git"). A raw
  # string compare then falsely concludes IS_WORKTREE, which skips this shared-
  # tree discard safety net entirely and lets the legacy fallback misattribute
  # every pre-existing dirty file in the repo to a session that touched nothing.
  _UCG_GCD_RAW=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  _UCG_GD_RAW=$(git rev-parse --git-dir 2>/dev/null || echo "")
  _UCG_GCD=""
  _UCG_GD=""
  [ -n "$_UCG_GCD_RAW" ] && _UCG_GCD=$(cd "$_UCG_GCD_RAW" 2>/dev/null && pwd -P || echo "$_UCG_GCD_RAW")
  [ -n "$_UCG_GD_RAW" ] && _UCG_GD=$(cd "$_UCG_GD_RAW" 2>/dev/null && pwd -P || echo "$_UCG_GD_RAW")
  _UCG_BR=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$NEW_UNSTAGED" ] \
    && { [ -z "$_UCG_GCD" ] || [ "$_UCG_GCD" = "$_UCG_GD" ]; } \
    && { [ "$_UCG_BR" = "${CLAUDE_MAIN_BRANCH:-main}" ] || [ "$_UCG_BR" = "master" ]; }; then
    printf 'NOTE: uncommitted-changes-gate skipped its unstaged-changes block — no per-session writes-log witness on a shared %s tree, so working-tree changes could not be attributed to this session (avoiding misattribution of files owned by a concurrent session).\n' "$_UCG_BR" >&2
    NEW_UNSTAGED=""
  fi
fi

if [ -n "$NEW_UNSTAGED" ]; then
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "")
  MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
  GCD=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
  GD=$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
  IS_WORKTREE=0
  FILE_LIST_RAW=$(echo "$NEW_UNSTAGED" | sed 's/^...//' || true)
  if [[ -n "$GCD" && -n "$GD" && "$GCD" != "$GD" ]]; then
    IS_WORKTREE=1
  fi

  ONLY_MAINTENANCE=1
  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    if ! is_inline_maintenance_path "$changed_path"; then
      ONLY_MAINTENANCE=0
      break
    fi
  done <<< "$FILE_LIST_RAW"

  # Inline sessions on the main working tree can leave maintenance/docs edits
  # unstaged. Source changes on main still require a scoped checkpoint or the
  # user can switch to a worktree/feature branch.
  if [ "$IS_WORKTREE" -eq 0 ] \
    && { [ "$CURRENT_BRANCH" = "$MAIN_BRANCH" ] || [ "$CURRENT_BRANCH" = "master" ]; } \
    && [ "$ONLY_MAINTENANCE" -eq 1 ]; then
    exit 0
  fi

  # Use sed to strip the 3-char porcelain prefix (XY + space), preserving full filenames with spaces
  FILE_LIST=$(echo "$FILE_LIST_RAW" | sed 's/^/  /')
  FILE_COUNT=$(echo "$NEW_UNSTAGED" | wc -l | tr -d ' ')

  # Check if there are also pre-existing dirty files (for context)
  PRE_EXISTING_COUNT=0
  if [ -n "${BASELINE_DIRTY:-}" ]; then
    PRE_EXISTING_COUNT=$(echo "$BASELINE_DIRTY" | grep -c . 2>/dev/null || echo "0")
  elif [ "$WRITES_LOG_AVAILABLE" -eq 1 ]; then
    # In the writes-log path we didn't load BASELINE_DIRTY; compute
    # pre-existing count directly from git for the context note.
    PRE_EXISTING_COUNT=$(LC_ALL=C git status --porcelain 2>/dev/null | grep -c . 2>/dev/null || echo "0")
    # Subtract this session's written files (they're not "pre-existing")
    if [ -n "$SESSION_WRITTEN" ]; then
      _session_count=$(printf '%s\n' "$SESSION_WRITTEN" | awk 'NF' | wc -l | tr -d ' ')
      PRE_EXISTING_COUNT=$((PRE_EXISTING_COUNT - _session_count))
      [ "$PRE_EXISTING_COUNT" -lt 0 ] && PRE_EXISTING_COUNT=0
    fi
  fi

  PRE_EXISTING_NOTE=""
  if [ "$PRE_EXISTING_COUNT" -gt 0 ]; then
    PRE_EXISTING_NOTE=$(printf '\n\nNote: %s pre-existing dirty files from prior sessions were excluded from this check.' "$PRE_EXISTING_COUNT")
  fi

  # ── Check if AGENT_REVIEW exists for THIS session's code changes ────────────
  # Session-bound + semantic check (not recency-based fallback).
  CODE_FILES=$(echo "$NEW_UNSTAGED" | grep -E '\.(php|ts|tsx|js|jsx)$' || true)
  REVIEW_NOTE=""

  if [[ -n "$CODE_FILES" ]]; then
    AGENT_REVIEW=""
    HOSTILE_REVIEW_REQUIRED=0
    if [ -n "$SESSION_ID" ]; then
      # W5G-6c: `.v/artifacts` first — W-perf6 consolidation moves artifacts there;
      # a root-only search false-claims "AGENT_REVIEW missing" right after the model
      # follows the W5F-10 guidance to consolidate (the observed whipsaw).
      # `|| true`: find exits non-zero when .v/artifacts doesn't exist yet, and
      # this hook runs with `set -euo pipefail` — without it the whole gate dies
      # rc=1 (no block at all) on any repo without a .v dir.
      AGENT_REVIEW=$(find "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" -maxdepth 1 -name "AGENT_REVIEW_*${SESSION_ID}*.md" 2>/dev/null | head -1 || true)
    fi
    if type review_requires_hostile_focus_from_paths >/dev/null 2>&1; then
      UNSTAGED_PATHS=$(echo "$NEW_UNSTAGED" | sed 's/^...//' || true)
      if review_requires_hostile_focus_from_paths "$UNSTAGED_PATHS"; then
        HOSTILE_REVIEW_REQUIRED=1
      fi
    fi
    if [[ -z "$AGENT_REVIEW" ]]; then
      REVIEW_NOTE=$'\n\nAGENT_REVIEW for this session is missing — dispatch agent review (codex adversarial reviewer or superpowers fallback) before committing.'
    elif ! validate_review_semantics "$AGENT_REVIEW" 1 "$HOSTILE_REVIEW_REQUIRED" "$SESSION_ID"; then
      REVIEW_NOTE=$'\n\nAGENT_REVIEW exists but is not semantically completed for this session — rerun review before committing.'
    fi
  fi

  CTX=$(printf 'BLOCKED: %s file(s) with unstaged changes introduced by THIS session.\n\nFiles with unstaged changes:\n%s\n\nACTION REQUIRED: Create a scoped git checkpoint before finishing this isolated session. Commit only files introduced by THIS session; do not include pre-existing dirty files you did not modify. Only maintenance/docs-only inline main-root sessions are exempt; feature-branch, worktree, and code-changing main sessions must not stop with dangling session-owned changes.%s%s' "$FILE_COUNT" "$FILE_LIST" "$PRE_EXISTING_NOTE" "$REVIEW_NOTE")
  # W42-F1: stderr text + exit 2 is sufficient for Stop (no invalid JSON)
  # W5G-1: route through the re-arm gate — block while progress is possible,
  # escape loudly on a genuine deadlock.
  if ! type rearm_gate >/dev/null 2>&1 || rearm_gate "uncommitted-changes-gate" "${SESSION_ID:-nosid}" "$STOP_ACTIVE" "$CTX"; then
    printf '%s\n' "$CTX" >&2
    exit 2
  fi
  exit 0  # W5G-1 deadlock escape (warning already on stderr)
fi

# W5G-1: clean pass — close out any active re-arm chain for this hook×SID.
if type rearm_clear >/dev/null 2>&1; then
  rearm_clear "uncommitted-changes-gate" "${SESSION_ID:-nosid}"
fi
exit 0
