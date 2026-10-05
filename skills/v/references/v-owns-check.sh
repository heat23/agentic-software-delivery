#!/usr/bin/env bash
# v-owns-check.sh — ADVISORY check: did the session's changeset stay inside the prompt's
# declared OWNS contract?
#
# Forensic driver (A-7, 2026-06-04): in one multi-prompt run, two prompts each shipped edits to
# service, exception, notification and controller files — all outside
# their prompts' "OWNS (only edit these)" lists — with no record anywhere. The drift was only
# discovered by a post-hoc forensic diff. This check makes OWNS drift VISIBLE at Step 6.2.6
# (IMPACT_MAP reconciliation).
#
# ⚠️ ADVISORY ONLY — MUST NEVER GATE. Prompts legitimately under-declare: TDD test files,
# mandated CHANGELOG/version bumps, and review-fix collateral all land outside OWNS in healthy
# sessions. Drift is a reviewable fact to record in the IMPACT_MAP, not a failure. Callers
# must not branch a completion decision on the exit code.
#
# Usage:
#   v-owns-check.sh <SID> --owns <owns-file> [--files <changed-files-file>] [--allow <glob>]...
#
#   <owns-file>  one OWNS entry per line. Raw prompt bullets are fine:
#                  - `app/Services/ExampleService.php` (settings UI + option)
#                normalizes to app/Services/ExampleService.php (first backtick span wins;
#                otherwise the bullet marker is stripped and the line trimmed). Entries that
#                name a directory (trailing "/" or not) match everything beneath them.
#   --files      newline-separated changed files (repo-relative). If omitted, derived as the
#                union of:
#                  .v/tmp/session-writes-merged-<SID>.txt
#                  .v/tmp/session-writes-<SID>.txt
#                  $(git rev-parse --git-common-dir)/claude-session-writes-<SID>.txt
#                  files touched by the commits listed in .v/tmp/commits-<SID>.txt (witness)
#                It deliberately NEVER falls back to `git diff <base>..HEAD`: under concurrent
#                sessions that window contains SIBLING commits (forensic B-1, the 17-commit
#                leakage class) and would report false drift.
#   --allow      extra allowed glob (shell pattern, matched against the repo-relative path),
#                repeatable — for project conventions beyond the built-ins. NOTE (CODEX-007):
#                matching uses `case`, where `*` crosses `/` — globs are RECURSIVE
#                (`plugin-dir/*` matches plugin-dir/a/b/c.php). Scope patterns accordingly.
#
# Built-in allowances (never reported as drift):
#   • test files     — tests/** at any depth, *Test.php, *.test.*, *.spec.*
#   • bookkeeping    — .v/**, any *_<SID>*.md session artifact, WORKTREE_HANDOFF_*,
#                      SESSION_LOG_*, HANDOFF_*
#   • release files  — CHANGELOG.md / readme.txt at any depth (convention-mandated stanzas).
#     Version-bump CODE files are NOT auto-allowed — a mandated bump outside OWNS is still
#     real drift worth recording.
#
# Output (first line is machine-readable for IMPACT_MAP embedding):
#   OWNS-CHECK: PASS (<n> changed files; all within OWNS contract or allowed conventions)
#   OWNS-CHECK: DRIFT (<m> of <n> changed files outside OWNS contract)   [+ "  - <file>" lines]
#   OWNS-CHECK: UNVERIFIABLE (<reason>)
# Exit codes: 0 PASS · 3 DRIFT (advisory!) · 4 UNVERIFIABLE · 2 usage error.
set -u

SID="${1:-}"
if [ -z "$SID" ] || [ "${SID#--}" != "$SID" ]; then
  echo "usage: v-owns-check.sh <SID> --owns <owns-file> [--files <changed-files-file>] [--allow <glob>]..." >&2
  exit 2
fi
shift

OWNS_FILE=""
FILES_FILE=""
ALLOW_GLOBS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --owns)  OWNS_FILE="${2:-}";  shift 2 || { echo "ERROR: --owns needs a file argument" >&2; exit 2; } ;;
    --files) FILES_FILE="${2:-}"; shift 2 || { echo "ERROR: --files needs a file argument" >&2; exit 2; } ;;
    --allow) [ -n "${2:-}" ] || { echo "ERROR: --allow needs a glob argument" >&2; exit 2; }
             ALLOW_GLOBS+=("$2"); shift 2 ;;
    *) echo "ERROR: unknown argument '$1'" >&2
       echo "usage: v-owns-check.sh <SID> --owns <owns-file> [--files <changed-files-file>] [--allow <glob>]..." >&2
       exit 2 ;;
  esac
done

if [ -z "$OWNS_FILE" ]; then
  echo "ERROR: --owns <owns-file> is required" >&2
  exit 2
fi
if [ ! -f "$OWNS_FILE" ]; then
  echo "OWNS-CHECK: UNVERIFIABLE (owns file '$OWNS_FILE' not found — was the OWNS list captured at Step 1.8?)"
  exit 4
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
V_TMP_DIR="$REPO_ROOT/.v/tmp"

# ── Normalize the OWNS entries ────────────────────────────────────────────────
# Backtick span wins; else strip a leading bullet marker and trim. Headings / blank
# lines yield nothing. Trailing "/" is stripped (directory matching is prefix-based).
OWNS_ENTRIES=()
while IFS= read -r _line || [ -n "$_line" ]; do   # `|| -n` keeps a final line without trailing \n
  # CODEX-006 (adversarial review 2026-06-04): a deny-list line that carries a backtick path —
  # e.g. `**MUST NOT TOUCH:** \`ExampleSyncService\`` — must NEVER become an *allowed* OWNS entry
  # (that would silently invert the contract into a false-PASS). Skip deny-marker lines outright.
  if printf '%s' "$_line" | grep -qiE 'MUST[[:space:]]+NOT[[:space:]]+TOUCH|DO[[:space:]]+NOT[[:space:]]+(EDIT|TOUCH)|MUST[[:space:]]+NOT[[:space:]]+EDIT'; then
    continue
  fi
  _entry=""
  case "$_line" in
    *\`*\`*) _entry=$(printf '%s' "$_line" | sed -n 's/[^`]*`\([^`][^`]*\)`.*/\1/p') ;;
    *)       _entry=$(printf '%s' "$_line" | sed -e 's/^[[:space:]]*[-*+][[:space:]]*//' -e 's/[[:space:]]\{1,\}(.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//') ;;
  esac
  case "$_entry" in
    ''|\#*|\*\**) continue ;;                       # blank / heading / bold-label line — not a path
  esac
  _entry="${_entry%/}"                              # strip trailing slash; matching is prefix-based
  [ -n "$_entry" ] && OWNS_ENTRIES+=("$_entry")
done < "$OWNS_FILE"

if [ ${#OWNS_ENTRIES[@]} -eq 0 ]; then
  echo "OWNS-CHECK: UNVERIFIABLE (owns file '$OWNS_FILE' contains no usable path entries)"
  exit 4
fi

# ── Collect the changed-file set ──────────────────────────────────────────────
_collect_changed() {
  if [ -n "$FILES_FILE" ]; then
    if [ ! -f "$FILES_FILE" ]; then
      return 1
    fi
    cat "$FILES_FILE" 2>/dev/null
    return 0
  fi
  # Union of the session-scoped write logs + the merge-back commit witness.
  cat "$V_TMP_DIR/session-writes-merged-${SID}.txt" 2>/dev/null
  cat "$V_TMP_DIR/session-writes-${SID}.txt" 2>/dev/null
  local _gcd
  _gcd=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
  [ -n "$_gcd" ] && cat "$_gcd/claude-session-writes-${SID}.txt" 2>/dev/null
  if [ -f "$V_TMP_DIR/commits-${SID}.txt" ]; then
    local _sha
    while IFS= read -r _sha; do
      case "$_sha" in
        *[!0-9a-f]*|'') continue ;;               # not a bare hex sha — skip
      esac
      git -C "$REPO_ROOT" show --name-only --format= "$_sha" 2>/dev/null
    done < "$V_TMP_DIR/commits-${SID}.txt"
  fi
  return 0
}

if ! _raw_changed=$(_collect_changed); then
  echo "OWNS-CHECK: UNVERIFIABLE (--files '$FILES_FILE' not found)"
  exit 4
fi

# Normalize: strip absolute REPO_ROOT prefix, drop blanks, dedupe.
CHANGED=()
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  case "$_f" in
    "$REPO_ROOT"/*) _f="${_f#"$REPO_ROOT"/}" ;;
  esac
  CHANGED+=("$_f")
done < <(printf '%s\n' "$_raw_changed" | sed -e 's/[[:space:]]*$//' | grep -v '^[[:space:]]*$' | sort -u)

if [ ${#CHANGED[@]} -eq 0 ]; then
  echo "OWNS-CHECK: UNVERIFIABLE (no changed-file evidence: no --files, empty session-writes logs, no commit witness — refusing to fall back to a shared base..HEAD window that would count sibling sessions' commits)"
  exit 4
fi

# ── Classify each changed file ────────────────────────────────────────────────
_is_owned() {
  local f="$1" e
  for e in "${OWNS_ENTRIES[@]}"; do
    [ "$f" = "$e" ] && return 0
    case "$f" in "$e"/*) return 0 ;; esac          # entry as directory prefix
  done
  return 1
}

_is_allowed() {
  local f="$1" b g
  b=$(basename "$f")
  # Test files (TDD output is expected outside OWNS)
  case "$f" in
    tests/*|*/tests/*) return 0 ;;
  esac
  case "$b" in
    *Test.php|*.test.*|*.spec.*) return 0 ;;
  esac
  # Session bookkeeping / artifacts
  case "$f" in
    .v/*|*/.v/*) return 0 ;;
  esac
  case "$b" in
    *_*"${SID}"*.md|WORKTREE_HANDOFF_*|SESSION_LOG_*|HANDOFF_*) return 0 ;;
    CHANGELOG.md|readme.txt) return 0 ;;           # convention-mandated release stanzas
  esac
  # Caller-supplied conventions
  for g in ${ALLOW_GLOBS[@]+"${ALLOW_GLOBS[@]}"}; do
    # shellcheck disable=SC2254
    case "$f" in $g) return 0 ;; esac
  done
  return 1
}

DRIFT=()
for _f in "${CHANGED[@]}"; do
  _is_owned "$_f" && continue
  _is_allowed "$_f" && continue
  DRIFT+=("$_f")
done

_total=${#CHANGED[@]}
if [ ${#DRIFT[@]} -eq 0 ]; then
  echo "OWNS-CHECK: PASS (${_total} changed files; all within OWNS contract or allowed conventions)"
  exit 0
fi

echo "OWNS-CHECK: DRIFT (${#DRIFT[@]} of ${_total} changed files outside OWNS contract)"
for _f in "${DRIFT[@]}"; do
  echo "  - $_f"
done
echo "note: advisory only — record under 'owns_contract:' in the IMPACT_MAP (Step 6.2.6); do NOT gate completion on this." >&2
exit 3
