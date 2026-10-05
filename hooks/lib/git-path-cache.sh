#!/usr/bin/env bash
# git-path-cache.sh — Lightweight per-SID cache of git path lookups (W83-F5).
#
# Scope: ONLY git path lookups (repo root, git_dir, git_common_dir).
# Heavy state (diffs, worktree list, changed files) belongs in
# `git-state-cache.sh` — this file does NOT replace or wrap it.
#
# Why a separate cache:
#   - 22+ hooks fire per tool event. Most touch 1-2 git rev-parse calls each.
#   - Each rev-parse subprocess is ~10-30ms cold.
#   - This cache turns N rev-parse calls per SID per repo into ONE (60s TTL).
#
# Contract (PLAN-FINAL.md A8):
#   - Cache file: ~/.claude/runtime/git-paths-${SID}-${repo_hash}  (chmod 600)
#   - Cache dir:  ~/.claude/runtime                                (chmod 700)
#   - Atomic write: mktemp in same dir → mv -f → final path
#   - Parse:  grep "^KEY=" | cut -d= -f2-     (never `source` or `eval`)
#   - TTL:    60 seconds (mtime comparison; stale → re-compute)
#   - Public API: resolve_git_paths()  exports GIT_ROOT / GIT_DIR / GIT_COMMON_DIR
#
# Safe under 22 concurrent hook spawns — mktemp+mv is atomic on the same
# filesystem; readers that hit a partial write fall through to live rev-parse.

# Guard: don't define twice in the same shell.
if [ "${_GPC_LOADED:-}" = "1" ]; then
  return 0 2>/dev/null || true
fi
_GPC_LOADED=1

_gpc_compute_hash() {
  local input="$1"
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s' "$input" | md5sum | cut -c1-8
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s' "$input" | md5 | cut -c1-8
  else
    # Fallback: cksum (POSIX). Always 8 hex chars.
    printf '%08x' "$(printf '%s' "$input" | cksum | cut -d' ' -f1)"
  fi
}

_gpc_runtime_dir() {
  local d="${HOME}/.claude/runtime"
  if [ ! -d "$d" ]; then
    mkdir -p "$d" 2>/dev/null || return 1
  fi
  # Best-effort tighten perms; ignore failure (e.g., shared install).
  chmod 700 "$d" 2>/dev/null || true
  # Ownership-verify: refuse to use a runtime dir owned by another user.
  local owner
  owner=$(ls -ld "$d" 2>/dev/null | awk 'NR==1 {print $3}')
  if [ -n "$owner" ] && [ "$owner" != "$(whoami)" ]; then
    return 1
  fi
  printf '%s' "$d"
  return 0
}

# resolve_git_paths
#   Exports GIT_ROOT, GIT_DIR, GIT_COMMON_DIR for the CURRENT working directory.
#   Returns 0 even when not in a git repo (exports empty values).
#   Cache key: per-SID + per-repo-hash. 60s TTL.
resolve_git_paths() {
  GIT_ROOT=""
  GIT_DIR=""
  GIT_COMMON_DIR=""

  # SID resolution (env wins; fall back to "no-sid" for shared runs)
  local sid="${CLAUDE_SESSION_ID:-no-sid}"

  # Need a runtime dir we own
  local runtime_dir
  runtime_dir=$(_gpc_runtime_dir) || {
    # Cache unavailable — compute live and return.
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
    GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "$GIT_DIR")
    export GIT_ROOT GIT_DIR GIT_COMMON_DIR
    return 0
  }

  # Compute repo hash from PWD (cheap, no rev-parse needed for key construction)
  local repo_key="${PWD}"
  local repo_hash
  repo_hash=$(_gpc_compute_hash "$repo_key")
  local cache_file="${runtime_dir}/git-paths-${sid}-${repo_hash}"

  # TTL check (60s). If cache is fresh AND readable AND owned-by-us, use it.
  if [ -r "$cache_file" ]; then
    local cache_age=999
    if command -v stat >/dev/null 2>&1; then
      # macOS: stat -f %m ; Linux: stat -c %Y
      local mtime
      mtime=$(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null) || mtime=0
      if [ -n "$mtime" ] && [ "$mtime" != "0" ]; then
        cache_age=$(( $(date +%s) - mtime ))
      fi
    fi
    if [ "$cache_age" -lt 60 ]; then
      # Parse with grep|cut — never source/eval the cache file.
      GIT_ROOT=$(grep '^GIT_ROOT=' "$cache_file" 2>/dev/null | head -1 | cut -d= -f2-)
      GIT_DIR=$(grep '^GIT_DIR=' "$cache_file" 2>/dev/null | head -1 | cut -d= -f2-)
      GIT_COMMON_DIR=$(grep '^GIT_COMMON_DIR=' "$cache_file" 2>/dev/null | head -1 | cut -d= -f2-)
      # If parse succeeded (any key present), trust it.
      if [ -n "$GIT_ROOT" ] || [ -n "$GIT_DIR" ] || [ -n "$GIT_COMMON_DIR" ]; then
        export GIT_ROOT GIT_DIR GIT_COMMON_DIR
        return 0
      fi
    fi
  fi

  # Live compute
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo "")
  GIT_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "$GIT_DIR")

  # Atomic write — mktemp in same dir + mv -f. Race-safe under concurrent fires.
  local tmp
  tmp=$(mktemp "${cache_file}.tmp.XXXXXX" 2>/dev/null) || {
    export GIT_ROOT GIT_DIR GIT_COMMON_DIR
    return 0  # cache unavailable, still return live values
  }
  {
    printf 'GIT_ROOT=%s\n' "$GIT_ROOT"
    printf 'GIT_DIR=%s\n' "$GIT_DIR"
    printf 'GIT_COMMON_DIR=%s\n' "$GIT_COMMON_DIR"
  } > "$tmp" 2>/dev/null
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cache_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null

  export GIT_ROOT GIT_DIR GIT_COMMON_DIR
  return 0
}
