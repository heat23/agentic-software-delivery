#!/usr/bin/env bash
# git-main-root.sh — Trap 3 shared helper (handoff-3, C-2/C-3): resolve the MAIN checkout
# root for a given directory using env-clean, canonicalized git-common-dir identity — NEVER
# a repo-root path-prefix heuristic. C-3 (hooks/track-session-writes.sh) already proved this
# is the only mechanism that survives the external-worktree convention
# (~/.claude/worktrees/<repo>/<slug>) that caused a session-strand incident (write-time captures
# silently dropped as "outside repo"). C-2 (durable-artifact-copy.sh) needs the SAME identity
# test to find the correct `.v/artifacts/` destination from inside a worktree. Two hand-rolled
# resolvers = two chances to recreate the worktree-blindness class — so this file is the ONE
# shared implementation both consume.
#
# Usage:
#   source ".../hooks/lib/git-main-root.sh"
#   MAIN_ROOT=$(resolve_main_root "<dir>")   # dir defaults to $PWD; prints absolute canonical
#                                             # path on success, empty + return 1 on failure.
# Never blocks; sourcing this file has no side effects beyond defining the function.

resolve_main_root() {
  local _dir="${1:-$PWD}"
  _dir="$(cd "$_dir" 2>/dev/null && pwd -P || true)"
  [ -n "$_dir" ] || return 1

  local _common
  # env -u: a caller's own exported GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE/GIT_COMMON_DIR (e.g. a
  # git-path-cache export from an OUTER repo context) must not leak into this lookup — git
  # honors them as overrides of discovery and will resolve against the WRONG repo otherwise
  # (verified live during C-3: a bare GIT_COMMON_DIR export broke linked-worktree discovery).
  # GIT_CEILING_DIRECTORIES caps upward discovery — inherited from a caller it makes
  # nested-dir resolution fail outright (codex CDX-3), silently no-oping every consumer.
  _common="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_CEILING_DIRECTORIES \
    git -C "$_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$_common" ] || return 1
  _common="$(cd "$_common" 2>/dev/null && pwd -P || true)"
  [ -n "$_common" ] || return 1

  if [ "$(basename "$_common")" = ".git" ]; then
    dirname "$_common"
  else
    # Submodule (codex CDX-2): the common dir is git METADATA (super/.git/modules/<name>) —
    # returning it would aim artifact copies at .git/modules/.../.v/artifacts, invisible to
    # every artifact scan. core.worktree on that git dir records the real checkout (relative
    # to the git dir); resolve it. Bare repos have no core.worktree and keep the common dir
    # as the best anchor available.
    local _cw _wt
    _cw="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
      -u GIT_CEILING_DIRECTORIES \
      git --git-dir="$_common" config --get core.worktree 2>/dev/null || true)"
    if [ -n "$_cw" ]; then
      _wt="$(cd "$_common" 2>/dev/null && cd "$_cw" 2>/dev/null && pwd -P || true)"
      if [ -n "$_wt" ]; then
        printf '%s\n' "$_wt"
        return 0
      fi
    fi
    printf '%s\n' "$_common"
  fi
}
