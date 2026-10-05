#!/usr/bin/env bash
# v-artifact-dir.sh — SINGLE SOURCE for the /v session-artifact directory (W-perf6).
#
# Prints the canonical artifact dir ($MAIN_ROOT/.v/artifacts) and ensures it exists with
# a self-ignoring `.gitignore` so the artifacts never pollute git OR the repo-root listing.
# ALL /v artifact WRITERS (orchestrator + dispatched reviewers) write here; the Stop hook
# (check-review-artifact.sh ARTIFACT_SEARCH_DIRS) and the orchestrator self-check
# (v-completion-selfcheck.sh) SEARCH here FIRST (then the legacy root, backward-compatible).
# Resolving the location through this one script is what keeps writers and searchers from
# drifting (a drift sentinel in v-contract-audit-test.sh asserts all three use `.v/artifacts`).
#
# Usage:   DIR=$(bash ~/.claude/skills/v/references/v-artifact-dir.sh)
# Override the parent with V_ARTIFACT_DIR (absolute path) for tests.
# Exit 0 always (best-effort); on a non-git/unwritable tree it falls back to CWD/.v/artifacts.
set -u

# Resolve the MAIN checkout root exactly as the Stop hook does (first worktree row = main).
_repo=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
_main=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
_main="${_main:-$_repo}"

# === LEAK-GUARD (2026-08-02 — 18-file telemetry leak into skill source trees) ================
# ~/.claude has NO git repo by design. Inside any skill/hook
# SOURCE subdirectory both `git rev-parse --show-toplevel` and `git worktree list` fail, so
# `_main` falls through to bare `pwd` and every caller then nests `.v/artifacts` INSIDE the
# source tree. That produced 18 stray provenance/ledger/trace files across 6 skill dirs between
# 2026-06-07 and 2026-08-02 — and this script reports the bad path with exit 0, so the callers'
# own `|| $PWD` fallbacks never fire and never noticed.
#
# The config dir ITSELF is a LEGITIMATE root: ecosystem-maintenance sessions genuinely treat
# ~/.claude as their project (see the live ~/.claude/.v/artifacts/BITE_LEDGER_*.md +
# AGENT_REVIEW_*.md this very workflow writes). So do NOT blanket-refuse ~/.claude — refuse only
# a STRICT DESCENDANT of it that is not itself inside a real git work tree, and snap that UP to
# the config dir (never deeper). A deliberately git-init'd repo nested under ~/.claude is left
# alone by the `--is-inside-work-tree` check. Real projects never reach this branch at all.
_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "$_CONFIG_DIR" ] && [ "$_main" != "$_CONFIG_DIR" ]; then
  case "$_main" in
    "$_CONFIG_DIR"/*)
      if ! git -C "$_main" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "v-artifact-dir: non-repo root '$_main' resolved INSIDE the config dir — snapping artifact root up to '$_CONFIG_DIR' (would have leaked .v/ into a skill/hook source tree)" >&2
        _main="$_CONFIG_DIR"
      fi
      ;;
  esac
fi
# === end LEAK-GUARD ==========================================================================

_dir="${V_ARTIFACT_DIR:-$_main/.v/artifacts}"

if mkdir -p "$_dir" 2>/dev/null; then
  # Ensure the PARENT `.v/.gitignore` exists with the SAME self-ignoring pattern the
  # bootstrap writes (`*` + `!.gitignore`). This ignores everything under `.v/` — including
  # `.v/artifacts/*` — so the artifacts never get committed AND no stray per-dir `.gitignore`
  # is left tracked (the parent's `!.gitignore` would otherwise un-ignore a child one).
  _vroot=$(dirname "$_dir")
  if [ ! -f "$_vroot/.gitignore" ]; then
    printf '*\n!.gitignore\n' > "$_vroot/.gitignore" 2>/dev/null || true
  elif ! grep -qxF '*' "$_vroot/.gitignore" 2>/dev/null; then
    # P4 (fleet forensic 2026-06-20): SELF-HEAL a STALE .v/.gitignore that predates the `*` self-ignore
    # template (e.g. an old `tmp/ archive/ traces/` one). Without `*`, top-level `.v/<role>-<sid>.*` scratch
    # files (fe-build/gate-summary/pre-flight-skeleton/tsbuildinfo) LEAK into `git status` and could be
    # `git add -A`-staged into history (a production repo had exactly this). Append the self-ignore pattern — additive
    # (pre-existing entries preserved) and idempotent (only when a bare `*` line is absent).
    printf '*\n!.gitignore\n' >> "$_vroot/.gitignore" 2>/dev/null || true
  fi
else
  # Unwritable (rare) — fall back so the caller still gets a usable path; the Stop hook's
  # legacy-root search means a write that lands in root is still found.
  _dir="$_main"
fi

printf '%s\n' "$_dir"
