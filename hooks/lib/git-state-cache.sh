#!/usr/bin/env bash
# git-state-cache.sh — Shared git state cache for Claude Code hooks
# Version: 1.1.0  (AVF-019: replaced source with safe key=value parser)
#
# PROBLEM: 22+ hooks fire simultaneously on the same tool event. Each runs
# git diff / git ls-files / git worktree list independently, causing:
#   1. git index.lock contention (errors within milliseconds)
#   2. ~2s overhead per edit from redundant subprocess spawning
#
# SOLUTION: First hook to call _gc_load() runs git once and writes results
# to a temp file keyed on repo + epoch-second. Subsequent hooks in the same
# event batch (same second) read the cached file — zero git calls.
#
# EXPORTED VARIABLES after _gc_load:
#   GC_REPO_ROOT        — absolute path to repo root
#   GC_REPO_HASH        — 8-char hash of repo root (for marker files)
#   GC_CURRENT_BRANCH   — current branch name (empty if detached)
#   GC_MAIN_BRANCH      — main branch name (from env or "main")
#   GC_IS_WORKTREE      — "true" if inside a linked worktree, "false" otherwise
#   GC_WT_COUNT         — number of worktrees (from git worktree list)
#   GC_CHANGED_FILES    — newline-separated list of all changed files (staged+unstaged+untracked, deduplicated)
#   GC_TOTAL_CHANGED    — integer count of changed files
#   GC_CHANGED_CODE     — first code file found in changes (for quick "any code changed?" check)
#   GC_CACHE_HIT        — "true" if loaded from cache, "false" if freshly computed
#
# CACHE LIFETIME: ~1 second (keyed on epoch second). Stale caches from prior
# seconds are ignored. Cache files are cleaned up opportunistically.
#
# SECURITY (AVF-019):
#   Cache directory is chmod 700 and ownership-verified before use.
#   Cache file is read with a safe key=value parser (no source/eval) —
#   values are base64-encoded to handle multi-line content and special chars.
#   Symlinks in the cache path are rejected before reading.

# Guard: don't source twice in the same shell
if [[ "${_GC_LOADED:-}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

_GC_LOADED=true

# Defaults
GC_REPO_ROOT=""
GC_REPO_HASH=""
GC_CURRENT_BRANCH=""
GC_MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
GC_IS_WORKTREE="false"
GC_WT_COUNT="1"
GC_CHANGED_FILES=""
GC_TOTAL_CHANGED="0"
GC_CHANGED_CODE=""
GC_CACHE_HIT="false"

_gc_compute_hash() {
  local input="$1"
  if command -v md5sum >/dev/null 2>&1; then
    echo "$input" | md5sum | cut -c1-8
  elif command -v md5 >/dev/null 2>&1; then
    echo "$input" | md5 | cut -c1-8
  else
    printf '%s' "$input" | cksum | cut -d' ' -f1
  fi
}

# Base64-encode a value into a single line (strips newlines from wrapped output).
# Works on both macOS (BSD base64) and Linux (GNU base64).
_gc_b64enc() {
  printf '%s' "$1" | base64 | tr -d '\n\r'
}

# Safe cache reader: parses KEY=base64value lines without eval/source.
#
# Security properties:
#   - Validates each line matches ^[A-Z_]+=<base64chars>$ before assignment
#   - Only assigns to a whitelist of known GC_* variable names
#   - Uses printf -v for assignment (no shell evaluation of value content)
#   - Rejects any line with shell metacharacters (;, $, backticks, parens)
#
# This eliminates the code-execution risk of `source`-ing a potentially
# tampered or symlink-attacked cache file.
_gc_safe_load_cache() {
  local cache_file="$1"
  local line key b64val val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    # Validate: key must be [A-Z_]+, value must be standard base64 chars only.
    # This pattern rejects any shell metacharacter in either key or value.
    if [[ "$line" =~ ^([A-Z_]+)=([A-Za-z0-9+/=]*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      b64val="${BASH_REMATCH[2]}"
      # Strict whitelist — never assign arbitrary variable names from cache
      case "$key" in
        GC_REPO_ROOT|GC_REPO_HASH|GC_CURRENT_BRANCH|GC_MAIN_BRANCH|\
        GC_IS_WORKTREE|GC_WT_COUNT|GC_TOTAL_CHANGED|GC_CHANGED_CODE|GC_CHANGED_FILES)
          val=$(printf '%s' "$b64val" | base64 -d 2>/dev/null || echo "")
          # printf -v assigns without evaluation — safe even if val contains
          # shell metacharacters, command substitutions, or backticks
          printf -v "$key" '%s' "$val"
          ;;
      esac
    fi
  done < "$cache_file"
}

_gc_load() {
  # Step 1: Get repo root (fast, no lock contention)
  GC_REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -z "$GC_REPO_ROOT" ]]; then
    return 1
  fi

  GC_REPO_HASH=$(_gc_compute_hash "$GC_REPO_ROOT")

  # Step 2: Set up cache directory with secure permissions
  local cache_dir="${TMPDIR:-/tmp}/claude-git-cache"
  local epoch_sec
  epoch_sec=$(date +%s)
  local cache_file="$cache_dir/state-${GC_REPO_HASH}-${epoch_sec}"

  # Create cache directory if needed
  mkdir -p "$cache_dir" 2>/dev/null

  # Enforce 700 permissions: only the owning user can read/write/enter
  chmod 700 "$cache_dir" 2>/dev/null || true

  # Ownership check: refuse to use a cache dir owned by another user.
  # This prevents a privilege-escalation scenario where a higher-privileged
  # process pre-creates /tmp/claude-git-cache owned by root (or another user)
  # and then waits for us to write or source a file there.
  local dir_uid
  if [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    dir_uid=$(stat -c %u "$cache_dir" 2>/dev/null || stat -f %u "$cache_dir" 2>/dev/null || echo "-1")
  else
    dir_uid=$(stat -c %u "$cache_dir" 2>/dev/null || echo "-1")
  fi
  if [[ "$dir_uid" != "$(id -u)" ]]; then
    # Cache dir not owned by us — skip cache entirely to avoid security risk
    return 1
  fi

  # Step 3: Check cache — verify it's a regular file (not a symlink)
  if [[ -f "$cache_file" && ! -L "$cache_file" ]]; then
    # Cache hit — load variables using the safe parser (no source/eval)
    _gc_safe_load_cache "$cache_file"
    GC_CACHE_HIT="true"
    return 0
  fi

  # Step 4: Cache miss — compute everything once
  # Clean old caches (anything not from this second) — synchronous to prevent
  # race where background delete removes a cache file while another hook sources it.
  find "$cache_dir" -name "state-${GC_REPO_HASH}-*" ! -name "state-${GC_REPO_HASH}-${epoch_sec}" -delete 2>/dev/null || true

  # Branch detection
  GC_CURRENT_BRANCH=$(git -C "$GC_REPO_ROOT" branch --show-current 2>/dev/null || echo "")

  # Worktree detection — canonical method: git-common-dir differs from git-dir in linked worktrees
  local git_common_dir git_dir
  git_common_dir=$(git -C "$GC_REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
  git_dir=$(git -C "$GC_REPO_ROOT" rev-parse --git-dir 2>/dev/null || echo "")
  if [[ -n "$git_common_dir" && -n "$git_dir" && "$git_common_dir" != "$git_dir" ]]; then
    GC_IS_WORKTREE="true"
  else
    GC_IS_WORKTREE="false"
  fi

  # Worktree count
  GC_WT_COUNT=$(git -C "$GC_REPO_ROOT" worktree list 2>/dev/null | wc -l | tr -d ' ' || echo "1")

  # Changed files (staged + unstaged + untracked, deduplicated)
  GC_CHANGED_FILES=$(cd "$GC_REPO_ROOT" && {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u | sed '/^$/d')

  GC_TOTAL_CHANGED=$(echo "$GC_CHANGED_FILES" | sed '/^$/d' | wc -l | tr -d ' ')

  # Quick check: any code file changed?
  GC_CHANGED_CODE=$(echo "$GC_CHANGED_FILES" | grep -E '\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)$' | head -1 || echo "")

  GC_CACHE_HIT="false"

  # Step 5: Write cache atomically (write to tmp, then move).
  # Values are base64-encoded so the file contains only alphanumeric+/+= chars
  # on value lines — safe to parse without eval or source.
  local tmp_cache="${cache_file}.$$"
  cat > "$tmp_cache" <<CACHE_EOF
GC_REPO_ROOT=$(_gc_b64enc "$GC_REPO_ROOT")
GC_REPO_HASH=$(_gc_b64enc "$GC_REPO_HASH")
GC_CURRENT_BRANCH=$(_gc_b64enc "$GC_CURRENT_BRANCH")
GC_MAIN_BRANCH=$(_gc_b64enc "$GC_MAIN_BRANCH")
GC_IS_WORKTREE=$(_gc_b64enc "$GC_IS_WORKTREE")
GC_WT_COUNT=$(_gc_b64enc "$GC_WT_COUNT")
GC_TOTAL_CHANGED=$(_gc_b64enc "$GC_TOTAL_CHANGED")
GC_CHANGED_CODE=$(_gc_b64enc "$GC_CHANGED_CODE")
GC_CHANGED_FILES=$(_gc_b64enc "$GC_CHANGED_FILES")
CACHE_EOF
  # Restrict cache file to owner-read-write only before making it visible
  chmod 600 "$tmp_cache" 2>/dev/null || true
  mv "$tmp_cache" "$cache_file" 2>/dev/null || true

  return 0
}
