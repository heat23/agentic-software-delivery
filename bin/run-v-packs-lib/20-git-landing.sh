# run-v-packs-lib/20-git-landing.sh — default-branch resolution + "is there unlanded work?" helpers.
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Keeping these here — instead of
# inline in the runner — lets the 1400-line entry point stay navigable while `source run-v-packs` (every
# run-v-packs-*-test.sh harness) still transitively defines every function. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# Globals referenced at call time (late-bound, set by the runner/tests before these run): REPO,
# CLAUDE_MAIN_BRANCH. Calls count_needs() (10-discovery.sh) but no other runner helper; does not call
# die(). That call is LATE-BOUND too (fires inside main(), long after every lib is sourced), so the
# numeric-prefix load order is a navigation convention here — NOT a load-time dependency to preserve.

# ── git / landing helpers (default-branch resolution + "is there unlanded work?") ──────────────────
# R3: the repo's default branch for landing/reconcile/GC checks. CLAUDE_MAIN_BRANCH wins when set; otherwise
# DERIVE it instead of assuming the literal 'main' — on a master/trunk repo with the var unset, a bare 'main'
# made has_pending_landing() silently blind to real unmerged work (rev-list against a nonexistent ref → 0 →
# "nothing pending" → the merge-strand class this predicate exists to close). Deterministic + cheap:
# prefer refs/heads/main, then refs/heads/master, else fall back to the literal (never the CURRENT branch —
# a runner invoked from a feature branch must not treat that branch as the landing target).
_main_branch(){ # $1=repo -> branch name
  if [ -n "${CLAUDE_MAIN_BRANCH:-}" ]; then printf '%s' "$CLAUDE_MAIN_BRANCH"; return; fi
  # R4: if the repo's CURRENT branch is itself main or master, that IS the landing target — prefer it over
  # the existence-order guess. A stale never-advanced 'main' ref beside a real 'master' default otherwise
  # wins the preference, making every landed-on-master state read as "commits not on main" forever.
  local _mb_cur; _mb_cur="$(git -C "$1" symbolic-ref --short HEAD 2>/dev/null)"
  case "$_mb_cur" in main|master) printf '%s' "$_mb_cur"; return ;; esac
  if git -C "$1" show-ref --verify -q refs/heads/main; then printf 'main'
  elif git -C "$1" show-ref --verify -q refs/heads/master; then printf 'master'
  else printf 'main'; fi
}

# P1 (2026-07-02 forensic): is there LANDING work to do even when the pack-file queue is empty? A pack archives
# to .done/ on GAUNTLET_ATTESTED regardless of whether merge-back actually LANDED the branch on main (merge-back
# legitimately FND-3-defers while main carries a live sibling's WIP), and a pack can sit parked in .needs-review/.
# So "queue empty" is provably NOT "all gated work on main". Re-running the runner is the mechanism that re-drives
# the end-of-run drain — but the "nothing to do" early-exit used to short-circuit BEFORE the drain whenever the
# pack queue was empty, so gated work could strand off main forever with no further warning. This predicate lets
# the early-exit fall THROUGH to the drain/reconcile/stranded-report when a parked pack OR an unmerged worktree
# branch still exists. Returns 0 (=has pending landing) / 1 (=genuinely nothing).
has_pending_landing(){
  [ "$(count_needs)" -gt 0 ] && return 0
  # R2: respect CLAUDE_MAIN_BRANCH like every other main-aware function in this file (reconcile_parked_by_proof,
  # gc_merged_branches) — a hardcoded 'main' silently no-ops this entire predicate on a master/trunk repo,
  # defeating the exact merge-strand fix it implements.
  local br n main_branch cur; main_branch="$(_main_branch "$REPO")"
  # R4: `git worktree list --porcelain` includes the PRIMARY worktree (the repo itself) — its checked-out
  # branch is where we ARE, the landing target, never a stranded feature branch. Without this skip, a repo
  # whose current branch is ahead of a stale sibling ref reads as "pending work" forever (exit 2 every run).
  cur="$(git -C "$REPO" symbolic-ref --short HEAD 2>/dev/null)"
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    [ -n "$cur" ] && [ "$br" = "$cur" ] && continue
    n="$(git -C "$REPO" rev-list --count "${main_branch}..$br" 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && return 0
  done < <(git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^branch /{b=$2; sub(/^refs\/heads\//,"",b); print b}')
  return 1
}
