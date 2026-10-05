#!/usr/bin/env bash
# v-project-root-recovery.sh — W25-F13 autonomous project-root discovery.
#
# Usage: bash v-project-root-recovery.sh <SID>
#
# Input:  $1 = CLAUDE_SESSION_ID (required). Used to locate the persisted task
#              file written by Step -3 (v-resolve-task.sh).
#
# Success contract: stdout = EXACTLY ONE LINE containing the absolute path of
#                   the resolved repo root. All diagnostics go to stderr only.
#
# Failure contract: non-zero exit; diagnostics to stderr; no stdout on failure.
#
# Caller responsibility (parent Step 0 must do this after success):
#   - validate the returned path (non-empty, is a directory, IS a git root)
#   - cd to the returned path
#   - re-run v-bootstrap-wrapper.sh
#   - re-resolve PROJECT_ROOT_TMP / BOOTSTRAP_ENV in the parent shell
#
# DO NOT perform cd, bootstrap re-run, or env re-resolution inside this script.

_SID="${1:-}"
if [ -z "$_SID" ]; then
  echo "W63: W25-F13 RECOVERY — SID argument missing; cannot locate persisted task; aborting." >&2
  exit 1
fi

# Read the task text persisted by Step -3 (v-resolve-task.sh).
_RESOLVED_TASK_FILE="$HOME/.claude/runtime/v-resolved-task-${_SID}.txt"
_TASK_TEXT=""
if [ -s "$_RESOLVED_TASK_FILE" ]; then
  _TASK_TEXT=$(cat "$_RESOLVED_TASK_FILE" 2>/dev/null || echo "")
  echo "W25-F13b-READ-FROM=$_RESOLVED_TASK_FILE (${#_TASK_TEXT} bytes)" >&2
else
  echo "W25-F13b: persisted task file missing or empty: $_RESOLVED_TASK_FILE" >&2
fi

# Extract file-path tokens from task text. Patterns cover common Laravel/Node/Python repos.
_CANDIDATE_PATHS=$(printf '%s\n' "$_TASK_TEXT" | \
  grep -oE '(app|routes|database|tests|src|resources|config)/[A-Za-z0-9_/.-]+\.(php|js|ts|tsx|jsx|vue|py|md)' \
  2>/dev/null | sort -u | head -20)

if [ -z "$_CANDIDATE_PATHS" ]; then
  echo "W25-F13-NO-PATHS-IN-TASK: no file-path tokens found in task content; cannot auto-discover project root." >&2
  exit 1
fi

echo "W25-F13-CANDIDATE-PATHS:" >&2
printf '%s\n' "$_CANDIDATE_PATHS" | sed 's/^/  /' >&2

# Build candidate project list from well-known locations.
_CANDIDATES=()
for _glob in "$HOME"/dev/*/*/ "$HOME"/dev/*/ "$HOME"/projects/*/ \
             "$HOME"/code/*/ "$HOME"/work/*/ "$HOME"/work/*/*/ \
             "$HOME"/repos/*/ "$HOME"/src/*/ \
             "$HOME"/Documents/code/*/ "$HOME"/Documents/*/ \
             "$HOME"/*/; do
  [ -d "$_glob" ] || continue
  [ -e "$_glob/.git" ] || continue
  _CANDIDATES+=("$_glob")
done

# User-curated project list (one absolute path per line, # comments stripped).
if [ -f "$HOME/.claude/known-projects.txt" ]; then
  while IFS= read -r _line; do
    _line=$(printf '%s' "$_line" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$_line" ] && continue
    [ -e "$_line/.git" ] && _CANDIDATES+=("${_line%/}/")
  done < "$HOME/.claude/known-projects.txt"
fi

# Dedup candidate list.
if [ ${#_CANDIDATES[@]} -gt 0 ]; then
  _CANDIDATES=($(printf '%s\n' "${_CANDIDATES[@]}" | sort -u))
fi

if [ ${#_CANDIDATES[@]} -eq 0 ]; then
  echo "W25-F13-RECOVERY-FAILED: no candidate git roots found under well-known locations." >&2
  exit 1
fi

# Score each candidate: R2-4 partial-match policy.
#   _total == 1: STRICT — only accept if EXACTLY ONE project contains the path.
#   _total >= 2: allow partial match; threshold = ceil(_total / 2).
_BEST_CANDIDATE=""
_BEST_SCORE=0
_BEST_MTIME=0
_total=$(printf '%s\n' "$_CANDIDATE_PATHS" | wc -l | tr -d ' ')
_threshold=$(( (_total + 1) / 2 ))
[ "$_threshold" -lt 1 ] && _threshold=1
_SINGLE_PATH_MATCHES=0

for _cand in "${_CANDIDATES[@]}"; do
  _score=0
  while IFS= read -r _path; do
    [ -e "$_cand$_path" ] && _score=$((_score + 1))
  done <<< "$_CANDIDATE_PATHS"
  if [ "$_score" -ge "$_threshold" ]; then
    _mt=$(git -C "$_cand" log -1 --format=%ct 2>/dev/null || echo 0)
    if [ "$_total" -eq 1 ]; then
      _SINGLE_PATH_MATCHES=$(( _SINGLE_PATH_MATCHES + 1 ))
      _BEST_CANDIDATE="$_cand"
      _BEST_SCORE="$_score"
      _BEST_MTIME="$_mt"
    else
      if [ "$_score" -gt "$_BEST_SCORE" ] || \
         { [ "$_score" -eq "$_BEST_SCORE" ] && [ "$_mt" -gt "$_BEST_MTIME" ]; }; then
        _BEST_CANDIDATE="$_cand"
        _BEST_SCORE="$_score"
        _BEST_MTIME="$_mt"
      fi
    fi
  fi
done

# Single-path ambiguity: if one path matched multiple projects, refuse to guess.
if [ "$_total" -eq 1 ] && [ "$_SINGLE_PATH_MATCHES" -gt 1 ]; then
  echo "W25-F13-AMBIGUOUS: single-path task matched $_SINGLE_PATH_MATCHES projects; refusing to guess." >&2
  echo "ERROR: write BLOCKED_<sid>.md with the candidate projects and the missing disambiguator." >&2
  exit 1
fi

if [ -z "$_BEST_CANDIDATE" ]; then
  echo "W25-F13-RECOVERY-FAILED: no project root contains all referenced paths." >&2
  echo "W25-F13-SCANNED:" >&2
  printf '  %s\n' "${_CANDIDATES[@]:-(none)}" >&2
  echo "ERROR: write BLOCKED_<sid>.md with scanned roots and the missing project-root fact." >&2
  exit 1
fi

# Strip trailing slash.
_BEST_CANDIDATE="${_BEST_CANDIDATE%/}"
echo "W25-F13-AUTO-RESOLVED-PROJECT_ROOT=$_BEST_CANDIDATE" >&2
echo "W25-F13-MATCH-SCORE=$_BEST_SCORE matched paths" >&2

# SUCCESS: emit exactly one line to stdout (the resolved path, nothing else).
printf '%s\n' "$_BEST_CANDIDATE"
