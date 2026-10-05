#!/usr/bin/env bash
# v-classify-trivial.sh
# Version: 1.0.0  (W39-B — trivial workflow classifier)
#
# Classifies whether the current session's diff qualifies as TRIVIAL — a
# small change that doesn't need the full /v gauntlet (pre-flight + agent
# review + verify-done). Production motivation: 1-line CSS or hide-a-menu-item
# changes were taking 10+ minutes through the full workflow. This is wasted
# time and tokens for no quality benefit.
#
# Trivial criteria (ALL must hold):
#   1. ≤1 file changed (excluding lockfiles, generated files)
#   2. ≤3 lines changed (added + removed combined, ignoring whitespace)
#   3. File matches a metadata-only or low-risk pattern:
#      - .md / .mdx / .txt / .yml / .yaml / .json (config, not migrations)
#      - .css / .scss
#      - resources/js/config/*.ts (config files only)
#      - settings.json / *.config.* / .env.example
#      - plugin .css / .md
#      - Comment-only changes in .php / .ts / .tsx (verified by removing
#        comments and seeing if the diff is empty)
#
# Excluded from trivial (always full workflow):
#   - app/ source code (controllers, services, jobs, models)
#   - database/migrations/*
#   - app/Http/Middleware/*
#   - Anything matching the hostile-review path pattern
#
# Output: prints "TRIVIAL=1" or "TRIVIAL=0" plus REASON= line.
# Exit code: always 0 (advisory).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# A4 (forensic 2026-06-21): a /v session COMMITS its work — to an isolated worktree BRANCH (build/<sid>)
# or to main — so by classification time `git diff HEAD` (UNCOMMITTED) is empty or shows only a
# concurrent sibling's auto-stashed WIP. One session's feature was committed to its
# worktree branch while this classifier saw only a sibling's test file and called it "trivial
# test-only", bypassing the gauntlet a schema co-typing warrants. Bind the changed-file set (and the
# per-file line counts) to THIS session's OWN commits: resolve the SID's worktree branch (lock-owned,
# else slug match), use merge-base(main, branch)..branch; fall back to the commit witness; union with
# any uncommitted work. Without a resolvable SID this degrades to the legacy uncommitted-only behavior.
SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${SESSION_ID:-}}}"
[ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ] && SID="$(tr -d ' \n\r' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)"
_SESSION_RANGE=""
_SESSION_COMMIT_FILES=""
if [ -n "$SID" ]; then
  _SID_SLUG="${SID%%-*}"; _WT_BRANCH=""
  while IFS= read -r _wt_p; do
    [ -n "$_wt_p" ] && [ -f "$_wt_p/.claude-session-lock" ] || continue
    [ "$(awk '{print $1; exit}' "$_wt_p/.claude-session-lock" 2>/dev/null)" = "$SID" ] && { _WT_BRANCH="$(git -C "$_wt_p" branch --show-current 2>/dev/null)"; break; }
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  # NB: for-each-ref 'refs/heads/*slug*' uses FNM_PATHNAME and will NOT cross the '/' in build/<name>;
  # list all heads and grep the slug so a slashed build branch is matched.
  # Anchor the 8-hex slug on a -/_/ boundary so it cannot match a sibling branch that merely CONTAINS
  # the hex run (review MED-2): 'fea70000' must be bounded by start/-/_// , not match '1fea70000-foo'.
  [ -z "$_WT_BRANCH" ] && [ -n "$_SID_SLUG" ] && [ "$_SID_SLUG" != "$SID" ] && \
    _WT_BRANCH="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${_SID_SLUG}([-_/]|\$)" | head -1)"
  if [ -n "$_WT_BRANCH" ]; then
    _B=$(git -C "$REPO_ROOT" merge-base "${CLAUDE_MAIN_BRANCH:-main}" "$_WT_BRANCH" 2>/dev/null || true)
    if [ -n "$_B" ]; then
      _SESSION_RANGE="${_B}..${_WT_BRANCH}"
      _SESSION_COMMIT_FILES="$(git -C "$REPO_ROOT" diff --name-only "$_SESSION_RANGE" 2>/dev/null || true)"
    fi
  fi
  if [ -z "$_SESSION_COMMIT_FILES" ]; then
    for _wt_tmp in "$REPO_ROOT/.v/tmp" "${V_TMP_DIR:-}"; do
      [ -n "$_wt_tmp" ] && [ -s "$_wt_tmp/commits-${SID}.txt" ] || continue
      _SESSION_COMMIT_FILES="$(while IFS= read -r _c; do [ -n "$_c" ] && git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$_c" 2>/dev/null; done < "$_wt_tmp/commits-${SID}.txt")"
      [ -n "$_SESSION_COMMIT_FILES" ] && break
    done
  fi
fi

# Changed-line count for a file, preferring THIS session's commit range over the (often-empty)
# uncommitted diff — so a committed multi-line change is not undercounted to 0 lines (A4).
_changed_lines() {
  # SUM the committed (session range) and uncommitted (vs HEAD) change counts — they are DISJOINT sets
  # (committed-on-branch vs working-tree), so a file with both must not be undercounted to just the
  # range count (codex MEDIUM 2026-06-21: 2 committed + 2 uncommitted must read as 4, not slip the
  # 3-line gate). With an empty range, _n=0 and this reduces to the uncommitted count alone.
  local _f="$1" _n=0 _u=0
  [ -n "$_SESSION_RANGE" ] && _n=$(git -C "$REPO_ROOT" diff -w "$_SESSION_RANGE" -- "$_f" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l | tr -d ' ')
  _u=$(git -C "$REPO_ROOT" diff -w HEAD -- "$_f" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l | tr -d ' ')
  printf '%s' "$(( ${_n:-0} + ${_u:-0} ))"
}

# Get the changed files (session commits ∪ SESSION-SCOPED uncommitted/staged), excluding
# generated/lockfiles.
# W-LIGHT-SCOPE (2026-08-03): identical bug and fix as v-classify-light-tier.sh — see that file for
# the full rationale. The uncommitted/staged legs were whole-tree, so unrelated dirty WIP made the
# ≤2-file TRIVIAL cap unclearable (TRIVIAL_PASS fired 3 times ever across 5 repos).
# FAIL STRICT: writes log unavailable => keep the whole-tree view (a superset, so strictly harder
# to qualify, never easier). get_session_writes resolves its git dir from CWD, not $REPO_ROOT.
_SW_LIB="${V_SESSION_WRITES_LIB:-$HOME/.claude/hooks/lib/session-writes.sh}"
_SESSION_WRITES=""
if [ -f "$_SW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_SW_LIB" 2>/dev/null || true
  if [ -n "$SID" ] && type get_session_writes >/dev/null 2>&1; then
    _SESSION_WRITES=$( cd "$REPO_ROOT" 2>/dev/null && get_session_writes "$SID" 2>/dev/null || true )
  fi
fi

_UNCOMMITTED_ALL=$( {
  git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null
  git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null
} | grep -v '^$' | sort -u )

if [ -n "$_SESSION_WRITES" ]; then
  _UNCOMMITTED_SCOPED=$(printf '%s\n' "$_UNCOMMITTED_ALL" \
    | grep -Fxf <(printf '%s\n' "$_SESSION_WRITES") 2>/dev/null || true)
else
  _UNCOMMITTED_SCOPED="$_UNCOMMITTED_ALL"
fi

CHANGED_FILES=$( {
  printf '%s\n' "$_UNCOMMITTED_SCOPED"
  printf '%s\n' "$_SESSION_COMMIT_FILES"
} | grep -v '^$' | sort -u | grep -vE '\.lock$|package-lock\.json$|composer\.lock$|ziggy\.js$|^vendor/|^node_modules/' || true)

# Count files. W46-F1: prior code was `grep -c . || echo 0`; when CHANGED_FILES
# is empty grep prints "0" then exits 1, the `|| echo 0` then prints another "0",
# producing FILE_COUNT='0\n0' (3-char two-line string) that breaks `[ "$FILE_COUNT" -eq 0 ]`
# with "integer expression expected". Same bug class as W40-A in v-bootstrap.sh.
# wc -l always exits 0 with a single integer; tr strips macOS BSD `wc`'s leading space.
FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . 2>/dev/null | head -1 | tr -d ' \n')
FILE_COUNT=${FILE_COUNT:-0}

if [ "$FILE_COUNT" -eq 0 ]; then
  echo "TRIVIAL=0"
  echo "REASON=no_files_changed"
  exit 0
fi

if [ "$FILE_COUNT" -gt 2 ]; then
  echo "TRIVIAL=0"
  echo "REASON=multiple_files_changed_count=$FILE_COUNT"
  exit 0
fi

# R-07: COSMETIC fast-path for ≤2 UI files.
# When FILE_COUNT is 2 (or 1 with a UI file that would otherwise be blocked
# by the is_user_facing_ui_path check below), probe v-cosmetic-ui-check.sh.
# A COSMETIC verdict means no behavioral code changed: safe to skip the full
# gauntlet (pre-flight + agent review + verify-done) because:
#   - No logic paths are altered → no functional regression risk.
#   - UX critique still runs in Step 3.5 (it is NOT skipped on COSMETIC).
#   - The full suite remains the authoritative gate at merge-back.
# We add COSMETIC=1 to the output so the Stop hook can independently
# verify the file count (≤2 instead of ≤1) and accept the marker.
#
# Guard: excluded paths (hostile, migrations, app source) are already blocked
# by the existing per-file checks further below; we rely on v-cosmetic-ui-check.sh
# returning BEHAVIORAL for those, which falls back to TRIVIAL=0.
if [ "$FILE_COUNT" -ge 1 ]; then
  _COSMETIC_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/v-cosmetic-ui-check.sh"
  if [ -x "$_COSMETIC_SCRIPT" ] || [ -f "$_COSMETIC_SCRIPT" ]; then
    # Collect the file list for the cosmetic checker (no BASE_REF → auto-detect)
    _UI_FILES=$(echo "$CHANGED_FILES" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    # shellcheck disable=SC2086
    _COSMETIC_RESULT=$(bash "$_COSMETIC_SCRIPT" "" $( echo "$_UI_FILES" ) 2>/dev/null || true)
    if [ "$_COSMETIC_RESULT" = "COSMETIC" ]; then
      # All files are cosmetic UI-only changes — TRIVIAL_PASS is safe.
      # Compute total changed lines across all files for the marker.
      _TOTAL_LINES=0
      _ALL_FILES_CSV=""
      while IFS= read -r _cf; do
        [ -n "$_cf" ] || continue
        _fl=$(_changed_lines "$_cf")
        _TOTAL_LINES=$(( _TOTAL_LINES + ${_fl:-0} ))
        _ALL_FILES_CSV="${_ALL_FILES_CSV:+$_ALL_FILES_CSV,}$_cf"
      done <<_COSMETIC_FILES_EOF
$CHANGED_FILES
_COSMETIC_FILES_EOF
      echo "TRIVIAL=1"
      echo "COSMETIC=1"
      echo "REASON=cosmetic_ui_change_no_behavioral_code"
      echo "FILE=$_ALL_FILES_CSV"
      echo "LINES=$_TOTAL_LINES"
      exit 0
    fi
  fi
fi

if [ "$FILE_COUNT" -gt 1 ]; then
  # Not COSMETIC (or cosmetic check unavailable) — fall back to non-trivial for 2-file changes.
  echo "TRIVIAL=0"
  echo "REASON=multiple_files_changed_count=$FILE_COUNT"
  exit 0
fi

# Single file — check the line count and pattern
FILE=$(echo "$CHANGED_FILES" | head -1)

# Check excluded patterns first (always full workflow, never trivial)
if echo "$FILE" | grep -qE '^app/(Http|Services|Jobs|Models|Console|Providers|Exceptions)/|^database/migrations/|^app/Http/Middleware/|^app/Http/Controllers/'; then
  echo "TRIVIAL=0"
  echo "REASON=excluded_path:$FILE"
  exit 0
fi

# W39 review F3: CLAUDE.md / README / ARCHITECTURE / SETUP / CONTRIBUTING
# document conventions and behaviors the codebase relies on. A 3-line edit
# can change the rules ("lazy loading is now opt-in") and warrant full review.
# Always full workflow for these critical docs.
if echo "$FILE" | grep -qiE '(^|/)(CLAUDE\.md|README\.md|ARCHITECTURE\.md|SETUP\.md|CONTRIBUTING\.md|AGENTS\.md)$'; then
  echo "TRIVIAL=0"
  echo "REASON=critical_doc:$FILE"
  exit 0
fi

# Hostile-review path? Always full workflow.
HOSTILE_PATTERN='(^|/)(auth|oauth|jwt|sso|saml|login|password|csrf|hmac|signature|cookie|salt|token|secret|key|credential|crypto|cipher|encrypt|sanctum|passport|billing|payment|stripe|cashier|webhook|admin|2fa|mfa)([/_.-]|$)'
if echo "$FILE" | grep -qiE "$HOSTILE_PATTERN"; then
  echo "TRIVIAL=0"
  echo "REASON=hostile_path:$FILE"
  exit 0
fi

# W48-F1 / W49-M1: User-facing UI changes are NEVER trivial. A 3-line
# color/spacing/copy change can still introduce contrast bugs, dark-mode
# regressions, or UX inconsistencies. Force these through the full gauntlet
# (Step 3.5 polish + UX critique + agent review).
#
# W49 review-fix M1: pattern definitions extracted to ~/.claude/hooks/lib/ui-path-pattern.sh
# so the W49 Stop hook (check-review-artifact.sh UX_CRITIQUE gate) and the
# classifier never drift apart.
_UI_PATTERN_LIB="$HOME/.claude/hooks/lib/ui-path-pattern.sh"
if [ -f "$_UI_PATTERN_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_UI_PATTERN_LIB"
  if is_user_facing_ui_path "$FILE"; then
    echo "TRIVIAL=0"
    echo "REASON=user_facing_ui_change_requires_review:$FILE"
    exit 0
  fi
else
  # Fallback: lib not installed (older deployment). Use inline patterns
  # matching W48-F1 originals so the classifier still works correctly.
  TEST_OR_CONFIG_PATTERN='\.(test|spec|stories)\.[jt]sx?$|/__snapshots__/|/__tests__/|(^|/)(jest|vitest|playwright)\.config\.|(^|/)tests/'
  UI_PATH_PATTERN='\.(tsx|jsx|css|scss|sass|vue|svelte)$|\.blade\.php$|(^|/)resources/(js|css|styles|views)/|(^|/)tailwind\.config\.'
  if echo "$FILE" | grep -qE "$UI_PATH_PATTERN"; then
    if ! echo "$FILE" | grep -qE "$TEST_OR_CONFIG_PATTERN"; then
      echo "TRIVIAL=0"
      echo "REASON=user_facing_ui_change_requires_review:$FILE"
      exit 0
    fi
  fi
fi

# Count changed lines (excluding pure-whitespace), preferring the session commit range (A4).
LINES=$(_changed_lines "$FILE")
LINES=${LINES:-0}

if [ "$LINES" -gt 3 ]; then
  # Allow up to 6 lines if the file is metadata-only (.md, .css, .yaml, .json config)
  case "$FILE" in
    *.md|*.mdx|*.txt|*.yml|*.yaml|*.css|*.scss)
      if [ "$LINES" -gt 6 ]; then
        echo "TRIVIAL=0"
        echo "REASON=too_many_lines_metadata:$LINES"
        exit 0
      fi
      ;;
    *)
      echo "TRIVIAL=0"
      echo "REASON=too_many_lines:$LINES"
      exit 0
      ;;
  esac
fi

# Now check the file pattern
TRIVIAL=0
case "$FILE" in
  # Documentation, copy, content
  *.md|*.mdx|*.txt|README*|CHANGELOG*|CONTRIBUTING*)
    TRIVIAL=1; REASON="docs_or_markdown"
    ;;
  # Styling
  *.css|*.scss|*.sass)
    TRIVIAL=1; REASON="stylesheet"
    ;;
  # Config files
  *.yml|*.yaml|*.toml|*.ini)
    TRIVIAL=1; REASON="config_yaml_toml_ini"
    ;;
  # Frontend config (navigation menus, route lists)
  resources/js/config/*.ts|resources/js/config/*.tsx)
    TRIVIAL=1; REASON="frontend_config"
    ;;
  # Plugin assets (no logic)
  plugin/*/assets/*.css|plugin/*/assets/*.js|plugin/*/readme.txt)
    TRIVIAL=1; REASON="plugin_asset"
    ;;
  # Tests don't qualify as trivial — they verify behavior (be safe)
  # Fall through
esac

# JSON config (not package.json or composer.json — those have semantic impact)
if [ "$TRIVIAL" -eq 0 ]; then
  case "$FILE" in
    *.config.json|*.config.js|*.config.ts|.env.example)
      TRIVIAL=1; REASON="build_config"
      ;;
  esac
fi

if [ "$TRIVIAL" -eq 1 ]; then
  echo "TRIVIAL=1"
  echo "REASON=$REASON:$FILE"
  echo "FILE=$FILE"
  echo "LINES=$LINES"
  exit 0
fi

echo "TRIVIAL=0"
echo "REASON=non_trivial_path:$FILE"
exit 0
