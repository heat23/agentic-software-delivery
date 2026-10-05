#!/usr/bin/env bash
# worktree-lock-exclude.sh — make `.claude-session-lock` invisible to git.
#
# WHY (W71, root cause of a production session, 2026-05-29):
# The session lock lives at the worktree ROOT (`.worktrees/<name>/.claude-session-lock`).
# A worktree is its own working-tree top level, so the parent `.worktrees/.gitignore`
# does NOT apply inside it — the lock shows up as an untracked `?? .claude-session-lock`
# entry in `git status`. Under a classifier outage the orchestrator fell back to manual
# git surgery, saw that stray untracked file while "cleaning up before merge-back", and
# ran `git rm`/`git add` + `git commit` on it — landing a junk commit
# ("chore: remove session lock before merge-back") on `main` while the ACTUAL fix never
# merged. The merge-back script's grep-exclusion (`^\?\? \.claude-session-lock$`) only
# papered over the untracked case for the SCRIPT; it did nothing about the model's
# manual-commit temptation, and broke entirely if the lock ever became tracked.
#
# The durable fix: add `.claude-session-lock` to the worktree's git exclude at creation
# time, so it NEVER appears in `git status` at all — no untracked entry, nothing to
# "clean up", nothing to accidentally commit. `git rev-parse --git-path info/exclude`
# resolves to the shared common-dir exclude (one file for all worktrees of the repo);
# the main checkout has no lock at its root, so this is inert there. Idempotent +
# best-effort: a failure here must NEVER break worktree creation.

# exclude_session_lock_from_git <worktree_path>
exclude_session_lock_from_git() {
  local wt_path="$1"
  [ -n "$wt_path" ] && [ -d "$wt_path" ] || return 0

  # W-perf4: git's info/exclude only suppresses UNTRACKED files. If a prior session
  # COMMITTED .claude-session-lock (so `main` now carries it TRACKED), a fresh worktree
  # inherits it tracked — the worktree's own lock write then shows as ` M` and `git add .`
  # stages it, landing the lock in a commit → merge-back conflict + manual squash-merge
  # (observed in a production session). `assume-unchanged` makes git ignore modifications to the
  # tracked file (no ` M`, never staged by `git add`), and survives rebase. Harmless no-op
  # (exit 128 swallowed) when the lock is untracked — the exclude below covers that case.
  # Run unconditionally (before the exclude early-return) so it always applies.
  git -C "$wt_path" update-index --assume-unchanged .claude-session-lock 2>/dev/null || true

  local excl
  excl=$(git -C "$wt_path" rev-parse --git-path info/exclude 2>/dev/null || echo "")
  [ -n "$excl" ] || return 0
  # rev-parse may return a path relative to the worktree cwd — resolve to absolute.
  case "$excl" in
    /*) : ;;
    *)  excl="$wt_path/$excl" ;;
  esac

  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  # Already present? (exact-line match) — nothing to do.
  if [ -f "$excl" ] && grep -qxF '.claude-session-lock' "$excl" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' '.claude-session-lock' >> "$excl" 2>/dev/null \
    && echo "AUTO: excluded .claude-session-lock from git (W71 — keeps it out of \`git status\`)" >&2 \
    || true
  return 0
}

# exclude_build_artifacts_from_git <worktree_path>
# RC-1 (forensic 2026-07-07): worktrees minted by v-worktree-adopt-or-create.sh (the pack-runner
# path) BYPASS the native WorktreeCreate hook, so a /v session's `npm install` / `composer install` leaves
# `node_modules/` + `vendor/` as UNTRACKED entries whenever the branch's .gitignore doesn't cover them
# (observed on a production repo: node_modules un-ignored / an embedded repo → `?? node_modules`). That untracked
# entry blocked merge-back's clean-tree precondition (stranding the branch's real commits), and under an
# interim blanket `git add -A` would have committed node_modules ONTO main. Excluding these keeps them out
# of `git status` entirely — nothing to block on, nothing to mis-commit; `git add -A` never stages an
# info/exclude'd path. info/exclude only suppresses UNTRACKED paths, so a project that genuinely TRACKS one
# of these is unaffected (its tracked files still show + commit). Idempotent, best-effort — must NEVER
# break worktree creation. Bite: worktree-build-exclude-test.sh.
exclude_build_artifacts_from_git() {
  local wt_path="$1" excl p
  [ -n "$wt_path" ] && [ -d "$wt_path" ] || return 0
  excl=$(git -C "$wt_path" rev-parse --git-path info/exclude 2>/dev/null || echo "")
  [ -n "$excl" ] || return 0
  case "$excl" in /*) : ;; *) excl="$wt_path/$excl" ;; esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  for p in 'node_modules/' 'vendor/'; do
    grep -qxF "$p" "$excl" 2>/dev/null || printf '%s\n' "$p" >> "$excl" 2>/dev/null || true
  done
  return 0
}
