#!/usr/bin/env bash
# ~/.claude/hooks/lib/v-tmp-dir.sh — shared marker/baseline directory resolver
# Version: 1.0.0   ← W24
#
# Purpose: replace the multiple `${TMPDIR:-/tmp}/claude-hooks` and
# `/tmp/<baseline>-${sid}.txt` patterns scattered across hooks with one
# canonical resolution: prefer repo-local $REPO_ROOT/.v/tmp/, fall back to
# /tmp only when the repo isn't available or its .v/ is unwritable.
#
# Why this matters:
#   1. User rule: never write to host /tmp; use repo-local .v/tmp.
#   2. /tmp markers leak across repos on the same machine — e.g.,
#      `auto-branch-on-scope.sh` writes a marker keyed only by SID, so two
#      sessions in two different repos with the same SID-prefix collide.
#   3. /tmp is wiped on reboot but .v/tmp is gitignored and persists across
#      reboots in the repo's own filesystem — better lifecycle for tracking
#      session state across long-running orchestrator runs.
#   4. Migration path: writers should use this helper now; readers should
#      check both .v/tmp AND /tmp during the migration window so old
#      sessions don't break when their baselines are at the legacy path.
#
# Usage:
#   source "${HOME}/.claude/hooks/lib/v-tmp-dir.sh"
#
#   # For a writable destination:
#   tmp_dir=$(v_tmp_dir)
#   echo "data" > "$tmp_dir/baseline-${SID}.txt"
#
#   # For a readable source (try .v/tmp first, then /tmp legacy):
#   baseline=$(v_tmp_find "baseline-${SID}.txt")
#   [ -n "$baseline" ] && cat "$baseline"
#
# Performance: zero subshells if .v/tmp is already known via $V_TMP_DIR env;
# falls back to one `git rev-parse` if not. Cached per-invocation.

# ── v_tmp_dir: emit a writable marker/baseline directory ────────────────────
# Resolution order:
#   1. $V_TMP_DIR env var (set by /v Step 0 bootstrap; trust it)
#   2. $REPO_ROOT/.v/tmp where REPO_ROOT = `git rev-parse --show-toplevel`
#   3. ${TMPDIR:-/tmp} (last-resort fallback when not in a repo)
#
# Always emits a writable, existing directory — creates .v/tmp if needed.
# Never errors; falls through to /tmp on any failure.
v_tmp_dir() {
  # 1. Honor pre-resolved env var (orchestrator-set; cheapest)
  if [ -n "${V_TMP_DIR:-}" ] && [ -d "$V_TMP_DIR" ] && [ -w "$V_TMP_DIR" ]; then
    printf '%s\n' "$V_TMP_DIR"
    return 0
  fi

  # 2. Repo-local
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$repo_root" ] && [ -d "$repo_root" ]; then
    # Refuse symlinked .v/ OR .v/tmp/ (Sec-FND-5: could redirect writes outside repo).
    # Adversarial review: checking only .v leaves a TOCTOU gap if .v/tmp is the
    # symlink. Check both before any write.
    if [ -L "$repo_root/.v" ] || [ -L "$repo_root/.v/tmp" ]; then
      echo "WARN: v_tmp_dir refusing symlinked $repo_root/.v or .v/tmp; falling back to \${TMPDIR:-/tmp}" >&2
      printf '%s\n' "${TMPDIR:-/tmp}"
      return 0
    fi
    local d="$repo_root/.v/tmp"
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
      printf '%s\n' "$d"
      return 0
    fi
    # mkdir -p or -w failed — adversarial review: this used to be silent.
    # Emit a one-line diagnostic so operators see WHY writes are leaking to /tmp.
    echo "WARN: v_tmp_dir cannot use $d (mkdir or -w failed: $(test -d "$d" && echo not-writable || echo not-creatable)); falling back to \${TMPDIR:-/tmp}" >&2
  fi

  # 3. Fallback
  printf '%s\n' "${TMPDIR:-/tmp}"
}

# ── v_tmp_find: locate an existing file by name across both locations ──────
# Searches .v/tmp first, then /tmp. Used during the migration window so
# hooks reading session state can still find files written by older code.
# Emits the full path if found, empty string + exit 1 if not.
#
# Usage: baseline=$(v_tmp_find "head-baseline-${SID}.txt") && cat "$baseline"
v_tmp_find() {
  local name="$1"
  [ -z "$name" ] && return 1

  # Adversarial review (path-traversal): reject any name containing slashes or
  # parent-dir refs. Callers pass simple file basenames like "head-baseline-${SID}.txt".
  # A name like "../../../etc/passwd" would otherwise escape the search dirs.
  case "$name" in
    */*|*..*|*$'\n'*|*$'\r'*)
      echo "WARN: v_tmp_find rejecting suspicious name: $name" >&2
      return 1
      ;;
  esac

  # 1. Pre-resolved
  if [ -n "${V_TMP_DIR:-}" ] && [ -f "$V_TMP_DIR/$name" ] && [ ! -L "$V_TMP_DIR/$name" ]; then
    printf '%s\n' "$V_TMP_DIR/$name"
    return 0
  fi

  # 2. Repo-local — refuse if .v/tmp itself is a symlink
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$repo_root" ] && [ ! -L "$repo_root/.v" ] && [ ! -L "$repo_root/.v/tmp" ] \
     && [ -f "$repo_root/.v/tmp/$name" ] && [ ! -L "$repo_root/.v/tmp/$name" ]; then
    printf '%s\n' "$repo_root/.v/tmp/$name"
    return 0
  fi

  # 3. Legacy /tmp (and $TMPDIR if set) — read-only fallback during the
  # migration window. Symlink check applies here too.
  local fallback="${TMPDIR:-/tmp}"
  if [ -f "$fallback/$name" ] && [ ! -L "$fallback/$name" ]; then
    printf '%s\n' "$fallback/$name"
    return 0
  fi
  if [ "$fallback" != "/tmp" ] && [ -f "/tmp/$name" ] && [ ! -L "/tmp/$name" ]; then
    printf '%s\n' "/tmp/$name"
    return 0
  fi

  return 1
}

# ── v_tmp_marker_dir: shared inter-hook marker dir ──────────────────────────
# Hooks like enforce-scope-guard.sh and auto-branch-on-scope.sh use a marker
# dir to deduplicate warnings within a session. Returns "<v_tmp_dir>/hook-markers".
# All callers can rely on the dir existing.
v_tmp_marker_dir() {
  local d
  d="$(v_tmp_dir)/hook-markers"
  mkdir -p "$d" 2>/dev/null
  printf '%s\n' "$d"
}
