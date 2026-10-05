#!/usr/bin/env bash
# v-bootstrap-wrapper.sh — single-script Step 0 entrypoint for /v.
# Version: 1.0.0  (W46-F2)
#
# Why this exists: production sessions repeatedly reported "Exit code 1"
# from the inline bash wrapper despite valid bootstrap output. Root cause
# could not be reproduced in synthetic environments — strongly suggests
# inherited shell options (set -e, set -o pipefail, BASH_ENV side effects)
# or a hook interaction in the user's specific environment.
#
# This wrapper:
#   - Explicitly disables errexit/pipefail so inherited options can't bite.
#   - Captures ALL output (stdout+stderr) so nothing is lost on failure.
#   - Performs the DETECTION_ERROR + _BOOTSTRAP_RC checks in one place.
#   - Has a single explicit exit point — cosmetic exit 1 cannot leak.
#
# Usage:
#   bash ~/.claude/skills/v/references/v-bootstrap-wrapper.sh
# Output: same key=value lines bootstrap.sh emits, plus optional warnings.
# Exit: 0 on healthy bootstrap, 1 on DETECTION_ERROR, 2 on bootstrap fail.

# CRITICAL: explicitly disable inherited error options so a parent shell
# with `set -e` or `set -o pipefail` cannot make us exit non-zero on a
# benign command (grep returning 1 on no match, etc.).
set +e
set +o pipefail
set +u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SH="${SCRIPT_DIR}/v-bootstrap.sh"

# LEAK-GUARD (2026-08-02): this wrapper computes its OWN root and mkdir's it BEFORE invoking
# v-bootstrap.sh — bypassing that script's existing not_inside_git_repo refusal entirely. Under
# the git-less config dir the bare `pwd` fallback wrote bootstrap-*.env into skill source trees.
# Snap a non-repo root nested inside the config dir UP to the config dir; leave real projects
# and the config dir itself untouched. Mirrors the central guard in v-artifact-dir.sh.
_pr_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
_pr_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "$_pr_cfg" ] && [ "$_pr_root" != "$_pr_cfg" ]; then
  case "$_pr_root" in
    "$_pr_cfg"/*) git -C "$_pr_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || _pr_root="$_pr_cfg" ;;
  esac
fi
PROJECT_ROOT_TMP="$_pr_root/.v/tmp"
mkdir -p "$PROJECT_ROOT_TMP" 2>/dev/null

# W46-F2 review-fix-F: refuse to proceed if PROJECT_ROOT_TMP is unwritable.
# Without this, the redirection below fails silently and the wrapper exits
# with code 2 + a generic message that gives no clue about the cause
# (read-only fs, permission denied, mount point gone).
if ! ( : >"$PROJECT_ROOT_TMP/.write-test-$$" ) 2>/dev/null; then
  echo "ERROR: V_TMP_DIR is unwritable: $PROJECT_ROOT_TMP" >&2
  echo "ERROR: cannot capture bootstrap output. Possible causes:" >&2
  echo "  - read-only filesystem mount" >&2
  echo "  - permission denied on .v/ directory" >&2
  echo "  - disk full" >&2
  echo "REMEDIATION=Check write permission and free space on $PROJECT_ROOT_TMP" >&2
  exit 2
fi
rm -f "$PROJECT_ROOT_TMP/.write-test-$$" 2>/dev/null

# W46-F2 review-fix-K: include PID + nanosecond resolution to avoid two
# concurrent wrapper invocations in the same session ID stomping each
# other's BOOTSTRAP_ENV file mid-cat.
_NS=$(date +%N 2>/dev/null | head -c 6)
case "$_NS" in *N*|"") _NS="$$" ;; esac
BOOTSTRAP_ENV="$PROJECT_ROOT_TMP/bootstrap-${CLAUDE_SESSION_ID:-$$}-${_NS}.env"

# Run bootstrap, capture both stdout and stderr separately so DETECTION_ERROR
# from stderr (the W34 stale-file path emits there) is also retained.
bash "$BOOTSTRAP_SH" >"$BOOTSTRAP_ENV" 2>"$BOOTSTRAP_ENV.stderr"
_BOOTSTRAP_RC=$?

# Always emit the bootstrap output first so the orchestrator sees status
# variables even if a check below fails.
cat "$BOOTSTRAP_ENV"

# 2026-07-01: emit the captured env-file path. SKILL.md previously re-derived
# "bootstrap-<sid>.env", which MISSES the -<nanos> suffix review-fix-K adds above —
# the re-read silently pointed at a stale or nonexistent file. The emitted line is
# the only correct way to locate this run's captured env.
printf 'BOOTSTRAP_ENV=%q\n' "$BOOTSTRAP_ENV"   # %q like every other bootstrap key (CDX-2)

# If bootstrap left stderr content, surface it on stderr as well — never
# silently swallow diagnostics. Common cause: stale_runtime_file rejection.
if [ -s "$BOOTSTRAP_ENV.stderr" ]; then
  echo "--- bootstrap stderr ---" >&2
  cat "$BOOTSTRAP_ENV.stderr" >&2
fi

# Hard-fail conditions (these are the SAME checks the inline wrapper had).
if [ "$_BOOTSTRAP_RC" -ne 0 ]; then
  echo "ERROR: bootstrap exited $_BOOTSTRAP_RC — refusing to proceed." >&2
  echo "ERROR: see $BOOTSTRAP_ENV for details." >&2
  exit 2
fi

if grep -q '^DETECTION_ERROR=' "$BOOTSTRAP_ENV" 2>/dev/null; then
  echo "ERROR: bootstrap reported DETECTION_ERROR — refusing to proceed:" >&2
  grep '^DETECTION_ERROR=' "$BOOTSTRAP_ENV" | sed 's/^/  /' >&2
  if grep -q '^REMEDIATION=' "$BOOTSTRAP_ENV"; then
    echo "REMEDIATION:" >&2
    grep '^REMEDIATION=' "$BOOTSTRAP_ENV" | sed 's/^REMEDIATION=//;s/^/  /' >&2
  fi
  exit 1
fi

# W39-B (2026-07-01, folded from SKILL.md Step 0): TRIVIAL workflow classification, fail-open.
# Runs only after a HEALTHY bootstrap (the checks above). Emits TRIVIAL=0|1 (+REASON/FILE/LINES
# pass-through). Classifier missing or errored -> TRIVIAL=0 (full workflow) — same fall-through
# the SKILL.md inline block had.
_TRIV_SH="${SCRIPT_DIR}/v-classify-trivial.sh"
_TRIV_OUT=""
[ -f "$_TRIV_SH" ] && _TRIV_OUT=$(bash "$_TRIV_SH" 2>/dev/null)
if printf '%s\n' "$_TRIV_OUT" | grep -q '^TRIVIAL='; then
  printf '%s\n' "$_TRIV_OUT" | grep -E '^(TRIVIAL|REASON|FILE|LINES)='
else
  echo "TRIVIAL=0"
  echo "REASON=classifier_unavailable_or_errored_fail_open"
fi

# W46-F4: stale .git/index.lock advisory (non-blocking).
LOCK_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/.git/index.lock"
if [ -f "$LOCK_FILE" ]; then
  _now=$(date +%s)
  _lock_mtime=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
  # W46-F4 review-fix-H: if stat returns 0 (file deleted between -f and stat,
  # or stat itself failed), do NOT compute age = epoch_now. Treat as "no
  # information" and skip the warning. Otherwise the wrapper would emit a
  # bogus 1.8-billion-second age every time stat hiccups.
  if [ "$_lock_mtime" -gt 0 ] 2>/dev/null; then
    _lock_age=$(( _now - _lock_mtime ))
    if [ "$_lock_age" -gt 60 ] 2>/dev/null; then
      echo "WARNING=git_index_lock_age_${_lock_age}s_at_${LOCK_FILE} (W46-F4)"
      echo "REMEDIATION_LOCK=Lock is older than 60 seconds. Possible owners: another git process, fsmonitor, or stale from a crashed prior session. Check 'lsof \"$LOCK_FILE\"' before removing. NEVER blind-rm if fsmonitor or an IDE indexer is active." >&2
    fi
  fi
fi

# === W71 MODEL POLICY (advisory, non-fatal) ===
# /v runs inline and inherits the user's active /model. Skill frontmatter does NOT
# force the orchestrator model. Routine /v execution is expected to run on Sonnet
# or opusplan; high-risk planning/review paths must escalate only the specific
# planning/reviewer subprocesses that support explicit model routing.
# Low-severity fix: resolve the SID through the canonical side-effect-free
# resolver (hooks/lib/resolve-sid.sh) rather than a hand-rolled precedence. The
# old inline `${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}` INVERTED the
# canonical order (which is CLAUDE_SESSION_ID first) and had no runtime-file
# fallback, so in a Bash subshell where neither env var propagates the advisory
# silently vanished. resolve_sid() only READS (env + runtime file) — no writes —
# so it is safe in this producer. Telemetry-only; failure just skips the line.
_v_resolver="$HOME/.claude/hooks/lib/resolve-sid.sh"
if [ -f "$_v_resolver" ]; then
  # shellcheck source=/dev/null
  . "$_v_resolver" 2>/dev/null || true
fi
if command -v resolve_sid >/dev/null 2>&1; then
  _v_sid="$(resolve_sid 2>/dev/null || true)"
else
  # Inline fallback uses the CANONICAL precedence (CLAUDE_SESSION_ID first).
  _v_sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
fi
if [ -n "$_v_sid" ]; then
  _v_tx=$(ls -1t "$HOME/.claude/projects"/*/"${_v_sid}.jsonl" 2>/dev/null | head -1)
  if [ -n "$_v_tx" ] && [ -f "$_v_tx" ]; then
    _v_model=$(grep -oE '"model":"claude-[A-Za-z0-9._-]*"' "$_v_tx" 2>/dev/null | tail -1 | sed -E 's/"model":"//; s/"$//')
    case "$_v_model" in
      *opus*) echo "V_MODEL_POLICY=opus_active_high_cost:${_v_model}" ;;
      *sonnet*) echo "V_MODEL_POLICY=sonnet_active_expected:${_v_model}" ;;
      "") : ;;
      *) echo "V_MODEL_POLICY=active_model:${_v_model}" ;;
    esac
  fi
fi

exit 0
