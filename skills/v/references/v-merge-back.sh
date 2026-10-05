#!/usr/bin/env bash
# v-merge-back.sh — Mandatory worktree merge-back, parallel-safe.
#
# Usage: bash v-merge-back.sh <SESSION_ID> [<WORKTREE_PATH>]
#
# Exit codes:
#   0 — merged + cleaned up successfully (or no worktree to merge)
#   1 — merge failed; WORKTREE_HANDOFF artifact written; worktree intact for manual recovery
#   2 — usage / config error
#   3 — DEFERRED (retryable, FND-3): main carries a concurrent active sibling's uncommitted SOURCE
#       WIP; we refuse to stash over it (orphan risk). Worktree INTACT, nothing stashed/merged.
#       Wait for the sibling to finish, then re-run — do NOT manual-merge, do NOT discard the WIP.
#
# Parallel safety:
#   - Per-project lock at $REPO_ROOT/.worktrees/.merge-lock (flock -w 120)
#   - Stale-lock detection (>$LOCK_STALE, default 600s — unified across flock + mkdir paths)
#   - Idempotent: returns 0 if branch already merged
#   - Cross-project safe: lock is repo-scoped (different REPO_ROOT → different lock)
#   - Ownership check: branch name must contain SESSION_ID

set -euo pipefail

# === DO-NOT-BYPASS BANNER (always print on any error exit) ===
# Observed 2026-05-27: orchestrator passed args in wrong order, this
# script exited 2, orchestrator then fell back to a MANUAL `git merge` from main —
# silently bypassing the merge lock + ownership guard + handoff fallback. Every error
# path below MUST surface this banner so the model can't read "exit 2" as "do it
# yourself instead."
_print_never_manual_banner() {
  cat >&2 <<'BANNER'

══════════════════════════════════════════════════════════════════════
⛔ DO NOT FALL BACK TO A MANUAL `git merge`.
   This script's exit-2 means "FIX YOUR INVOCATION", not "do it yourself."
   A manual `git merge` bypasses:
     - per-project merge lock (concurrent sessions will tangle)
     - ownership guard (you may clobber a sibling session's work)
     - conflict → WORKTREE_HANDOFF escalation
   Correct invocation:  bash v-merge-back.sh <SESSION_ID_UUID> [<WORKTREE_PATH>]
   Use /v-merge-all for cross-session consolidation.
══════════════════════════════════════════════════════════════════════
BANNER
}
_die() { echo "ERROR: $*" >&2; _print_never_manual_banner; exit 2; }

# Resolve our own directory BEFORE any cd (this script cd's to REPO_ROOT later, which would
# break a relative $0). Used to locate sibling helper scripts (v-artifact-consolidate.sh).
# (|| true inside the substitution: this script runs `set -e` — a failing cd here must fall
# through to the $HOME default, not kill the merge-back before it starts.)
_SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
[ -n "$_SCRIPT_DIR" ] || _SCRIPT_DIR="$HOME/.claude/skills/v/references"

SESSION_ID="${1:-}"
# LOCK-SCAN-RESOLVE (forensic 2026-07-04, adopted worktree): track whether the caller gave
# an explicit worktree path. If not, we default to $(pwd) BUT — for an ADOPTED worktree whose branch
# is named with a DIFFERENT session's SID — resolving by cwd lands on the main checkout ("nothing to
# merge") and the operator had to hunt for the path. Below, when no path was given, we lock-scan the
# registered worktrees for the one whose .claude-session-lock SID matches SESSION_ID (authoritative,
# adoption-safe — the lock is re-keyed to the adopting session even when the branch name is not).
_WT_ARG_GIVEN=0; [ -n "${2:-}" ] && _WT_ARG_GIVEN=1
WORKTREE_PATH="${2:-$(pwd)}"

_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

[ -z "$SESSION_ID" ] && _die "SESSION_ID required as first arg (UUID, e.g. 5e55a000-0000-4000-8000-000000000004)."

# ARG-SWAP DETECTION: if SESSION_ID looks like a path (contains /) OR is an existing dir,
# the operator probably swapped <SESSION_ID> and <WORKTREE_PATH>. Catch + explain.
case "$SESSION_ID" in
  */*)  _die "first arg '$SESSION_ID' looks like a PATH — args appear swapped. Pass SESSION_ID (UUID) FIRST, worktree path SECOND." ;;
esac
if [ -d "$SESSION_ID" ]; then
  _die "first arg '$SESSION_ID' is a directory — args appear swapped. Pass SESSION_ID (UUID) FIRST, worktree path SECOND."
fi
# Reject garbage SIDs early with a usage example (rather than silently failing the ownership guard later).
if ! printf '%s' "$SESSION_ID" | grep -qE "$_UUID_RE"; then
  _die "first arg '$SESSION_ID' is not a UUID. Expected format: ########-####-####-####-############ (e.g. \$CLAUDE_SESSION_ID)."
fi

# LOCK-SCAN-RESOLVE (see note at arg parsing): no explicit path given → find the worktree whose
# .claude-session-lock SID matches SESSION_ID. Handles the adopted-worktree case (branch named with a
# sibling's SID) that a cwd/branch-name resolution misses. Only runs when the path was defaulted AND
# the cwd is NOT already a linked worktree for this session (respect an explicit/local worktree).
if [ "$_WT_ARG_GIVEN" -eq 0 ]; then
  _cwd_gcd=$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
  _cwd_gd=$(git -C "$WORKTREE_PATH" rev-parse --git-dir 2>/dev/null || echo "")
  # only scan when cwd is the MAIN checkout (common-dir == git-dir) — i.e. not already in a worktree
  if [ -n "$_cwd_gcd" ] && [ "$_cwd_gcd" = "$_cwd_gd" ]; then
    _mb_lock_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
    # shellcheck source=/dev/null
    [ -f "$_mb_lock_lib" ] && . "$_mb_lock_lib" 2>/dev/null || true
    if command -v _lock_sid >/dev/null 2>&1; then
      while IFS= read -r _mb_wt; do
        [ -n "$_mb_wt" ] && [ -d "$_mb_wt" ] || continue
        [ -f "$_mb_wt/.claude-session-lock" ] || continue
        if [ "$(_lock_sid "$_mb_wt/.claude-session-lock" 2>/dev/null)" = "$SESSION_ID" ]; then
          echo "INFO: lock-scan resolved worktree for $SESSION_ID → $_mb_wt (adoption-safe; branch name not required to carry the SID)" >&2
          WORKTREE_PATH="$_mb_wt"; break
        fi
      done < <(git -C "$WORKTREE_PATH" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
    fi
  fi
fi

[ ! -d "$WORKTREE_PATH" ] && _die "WORKTREE_PATH '$WORKTREE_PATH' is not a directory."

# Resolve git dirs
GIT_COMMON_DIR=$(cd "$WORKTREE_PATH" && git rev-parse --git-common-dir 2>/dev/null || echo "")
GIT_DIR=$(cd "$WORKTREE_PATH" && git rev-parse --git-dir 2>/dev/null || echo "")

if [ -z "$GIT_COMMON_DIR" ]; then
  _die "$WORKTREE_PATH is not a git working tree."
fi

# Detect: are we actually in a worktree (not the main checkout)?
if [ "$GIT_COMMON_DIR" = "$GIT_DIR" ]; then
  echo "INFO: $WORKTREE_PATH is the main checkout; nothing to merge"
  exit 0
fi

# REPO_ROOT = parent of git-common-dir
REPO_ROOT=$(cd "$WORKTREE_PATH" && cd "$GIT_COMMON_DIR" && cd .. && pwd)
WORKTREE_PATH=$(cd "$WORKTREE_PATH" && pwd)
WORKTREE_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null || echo "")
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"

# If main branch unset/wrong, try to detect
if ! git -C "$REPO_ROOT" rev-parse --verify "$MAIN_BRANCH" >/dev/null 2>&1; then
  for candidate in main master develop; do
    if git -C "$REPO_ROOT" rev-parse --verify "$candidate" >/dev/null 2>&1; then
      MAIN_BRANCH="$candidate"
      break
    fi
  done
fi

[ -z "$WORKTREE_BRANCH" ] && _die "could not determine worktree branch."

# W18: V_TMP_DIR — repo-local transient directory (no /tmp pollution)
V_TMP_DIR="$REPO_ROOT/.v/tmp"
mkdir -p "$V_TMP_DIR" 2>/dev/null
[ -f "$REPO_ROOT/.v/.gitignore" ] || printf '%s\n' '*' '!.gitignore' > "$REPO_ROOT/.v/.gitignore" 2>/dev/null

# === P2-WINNER-ELECTION wiring (2026-07-03, review CDX-1) ===
# When ≥2 worktrees carry the SAME task slug (the 2026-07-03 6-way duplicate-task
# class), landing must not pick by narration/first-staged: run the machine ranking BEFORE merging
# and surface it. ADVISORY this round (never blocks a legitimate single-copy merge): the manifest
# + stderr directive give the orchestrator/operator the ranked table; if THIS branch is not the
# top row, the directive says to land the winner instead or document why. Best-effort — an
# election failure never blocks the merge machinery itself. Dial: V_WINNER_ELECTION=0 disables.
if [ "${V_WINNER_ELECTION:-1}" = "1" ]; then
  # NB: this script runs `set -euo pipefail` — every pipeline here MUST be `|| true`-guarded or a
  # zero-match grep (rc 1) kills the whole merge-back silently (the L1105/rc128 class; bitten
  # LIVE by v-merge-back-missing-artifact-msg-test going 0/3 on first wiring).
  _WE_SLUG="${WORKTREE_BRANCH#*/}"
  _WE_SLUG="$(printf '%s' "$_WE_SLUG" | sed -E 's/-[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$//; s/-[0-9a-f]{8}$//' || true)"
  _WE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/v-winner-election.sh"
  if [ -n "$_WE_SLUG" ] && [ -f "$_WE_SCRIPT" ]; then
    _WE_N=$( { git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | grep -ci -- "$_WE_SLUG" 2>/dev/null | head -1 | tr -d ' \n'; } || true )
    if [ "${_WE_N:-0}" -ge 2 ]; then
      echo "WARN: ${_WE_N} worktrees match task slug '${_WE_SLUG}' — running winner election (machine ranking by gauntlet depth; landing-by-narration picked the WRONG copy on 2026-07-03)." >&2
      _WE_OUT=$(bash "$_WE_SCRIPT" "$REPO_ROOT" "$_WE_SLUG" 2>/dev/null || true)
      if [ -n "$_WE_OUT" ]; then
        { printf '%s\n' "$_WE_OUT" | head -8 >&2; } || true
        _WE_TOP_BR=$( { printf '%s\n' "$_WE_OUT" | sed -n '2p' | cut -f3; } || true )
        if [ -n "$_WE_TOP_BR" ] && [ "$_WE_TOP_BR" != "$WORKTREE_BRANCH" ]; then
          echo "WARN: WINNER-ELECTION — this branch ($WORKTREE_BRANCH) is NOT the top-ranked copy ($_WE_TOP_BR). Land the winner instead, or document in your merge narration WHY this copy was chosen (manifest: $REPO_ROOT/.v/artifacts/WINNER_ELECTION_${_WE_SLUG}.md)." >&2
        fi
      fi
    fi
  fi
fi
# === end P2-WINNER-ELECTION wiring ===

# OWNERSHIP CHECK: branch name must contain the SESSION_ID, OR its 8-char short prefix.
# 2026-05-26: the orchestrator names worktree branches `<type>/<slug>-<short8>` using only the
# first 8 chars of the SID (observed in 5/5 real sessions), NOT the full UUID that
# v-completion.md passes here. The old full-UUID-only match therefore ALWAYS failed for those
# branches → exit 2 → the orchestrator fell back to a MANUAL, UNLOCKED `git merge` (observed
# in a production session), silently bypassing this script's merge-lock serialization — defeating the
# whole parallel-safety guarantee. Accept the 8-char prefix too: 8 hex chars is ample entropy
# to identify the owning session (collision ~1 in 4e9, and only relevant if two same-prefix
# sessions merge the SAME repo concurrently), preserving the anti-clobber guard while matching
# the real naming convention.
SID_SHORT=$(printf '%s' "$SESSION_ID" | cut -c1-8)
case "$WORKTREE_BRANCH" in
  *"$SESSION_ID"*) ;;                          # full UUID (spec-compliant naming)
  *"-$SID_SHORT"*) ;;                          # 8-char short prefix as a `-`-delimited SID token
                                               # (the `<slug>-<sid>` naming always precedes it with
                                               # `-`; anchoring on `-` avoids matching 8 hex chars
                                               # that merely appear inside a slug).
  *)
    # P1d (forensic 2026-06-17): the branch was named
    # `fix/<ticket>-<slug>` — no SID, no `-<sid8>` — so this guard hard-refused (exit 2) and
    # the orchestrator fell back to a MANUAL, UNLOCKED `git merge` (the EXACT bypass this guard exists to
    # prevent). The guard's real job is not to clobber a CONCURRENT sibling. So before refusing, accept
    # three ownership proofs that don't depend on branch naming; refuse only when a sibling could be hurt
    # AND ownership is unprovable.
    _own_proof=""
    # (1) the worktree's own session-lock binds it to this SID (written at creation).
    if [ -f "$WORKTREE_PATH/.claude-session-lock" ]; then
      _lock_sid=$(awk 'NR==1{print $1}' "$WORKTREE_PATH/.claude-session-lock" 2>/dev/null)
      # SREV-001: the lock is written with the FULL UUID (creation: `printf '%s ...' "$CLAUDE_SESSION_ID"`),
      # so match it exactly — no partial-prefix arm (which would be dead code that implies false tolerance).
      case "$_lock_sid" in "$SESSION_ID") _own_proof="session-lock" ;; esac
    fi
    # (2) the worktree PATH carries the SID (the standard .worktrees/<slug>-<sid8> layout). SREV-001: anchor
    #     the short form on `-` (the convention is `<slug>-<sid8>`), mirroring the branch check at line ~125,
    #     so a repo dir that merely CONTAINS 8 matching hex chars cannot falsely satisfy the proof.
    if [ -z "$_own_proof" ]; then
      case "$WORKTREE_PATH" in *"$SESSION_ID"*|*"-$SID_SHORT"*) _own_proof="path" ;; esac
    fi
    # (3) commit-witness provenance binds this SID to this branch's commits. The commits-<sid>.txt written by
    #     commit-witness-recorder (HMAC-provenanced sidecar) lists every sha THIS SID committed; if the branch
    #     tip is in this SID's record, the branch is provably OURS even with no lock AND a SID-less branch/path
    #     (an observed SID-less branch name + dead-session case, which the lock/path proofs above
    #     both miss). This is a POSITIVE per-commit binding — strictly STRONGER than the naming-convention proofs
    #     (1)/(2), which only assert a string appears in a name — so it tightens, never loosens, the anti-clobber
    #     guard: a FOREIGN branch's tip will not appear in OUR SID's witness record. (A2b, forensic 2026-07-07.)
    if [ -z "$_own_proof" ]; then
      _mb_tip=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null)
      _mb_cw="$REPO_ROOT/.v/artifacts/commits-${SESSION_ID}.txt"
      if [ -n "$_mb_tip" ] && [ -f "$_mb_cw" ] && grep -qF "$_mb_tip" "$_mb_cw" 2>/dev/null; then
        _own_proof="commit-witness-provenance"
      fi
    fi
    # NOTE: there is deliberately NO "no active sibling -> proceed" fallback. A FOREIGN branch (another
    # session's worktree) must be rejected even when no sibling is *currently* active — the other session
    # may have just ended, and its committed-but-unmerged work is not ours to merge under this SID (the
    # T16 anti-clobber case). Ownership must be PROVEN (lock or path carry the SID), never assumed from the
    # absence of a concurrent peer. Spec-compliant worktrees always satisfy (1) or (2): creation names the
    # branch `<type>/<slug>-${SID}` AND writes a `.claude-session-lock` carrying the SID.
    if [ -n "$_own_proof" ]; then
      echo "NOTE: worktree branch '$WORKTREE_BRANCH' lacks the SID, but ownership is proven via ${_own_proof} — proceeding with the LOCKED merge (P1d; safer than the manual-merge fallback the refusal used to force)." >&2
    else
      echo "ERROR: worktree branch '$WORKTREE_BRANCH' does not contain SESSION_ID '$SESSION_ID' (nor '$SID_SHORT'), its path does not carry the SID, and it has no .claude-session-lock binding it to this session — ownership is unprovable." >&2
      echo "ERROR: Refusing to merge — would risk clobbering another session's work." >&2
      echo "ERROR: This is a parallel-safety guard. Run /v-merge-all to consolidate this branch safely, or re-create the worktree with the SID in its branch name (do NOT 'git merge' manually — that bypasses the merge-lock serialization)." >&2
      _print_never_manual_banner
      exit 2
    fi
    ;;
esac

# IDEMPOTENCY: if branch already merged, just clean up
if git -C "$REPO_ROOT" merge-base --is-ancestor "$WORKTREE_BRANCH" "$MAIN_BRANCH" 2>/dev/null; then
  echo "OK: branch '$WORKTREE_BRANCH' already merged into $MAIN_BRANCH; cleaning up worktree"
  cd "$REPO_ROOT"
  # C-3/A-3 (forensic 2026-06-04): rescue session artifacts stranded in the WORKTREE before
  # `git worktree remove` destroys the only copies (H-5: a session merged and lost its gate
  # artifacts exactly this way). Best-effort — never fails the cleanup. Subshell-cd: the
  # consolidator resolves roots from CWD.
  ( cd "$REPO_ROOT" && bash "$_SCRIPT_DIR/v-artifact-consolidate.sh" "$SESSION_ID" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts" ) || true
  # M2 (SME review 2026-06-21): this idempotency cleanup must NOT --force-remove a worktree that still holds
  # UNCOMMITTED/UNTRACKED work — the SAME irreversible data-loss class as v-worktree-gc.sh (GC-DIRTY-WORKTREE).
  # "branch already merged" proves only COMMITTED ancestry; the working tree can carry unmerged edits the
  # artifact-rescue above does not cover (only telemetry). Porcelain-guard (allow only the session lock); if
  # dirty, KEEP the worktree + branch and report loudly rather than destroying the work.
  _mb_dirty="$(git -C "$WORKTREE_PATH" status --porcelain 2>/dev/null | grep -vE '[[:space:]]\.claude-session-lock$' || true)"
  if [ -n "$_mb_dirty" ]; then
    echo "KEEP — '$WORKTREE_PATH' is merged but has UNCOMMITTED/UNTRACKED changes; NOT removing (would destroy them). Inspect: git -C '$WORKTREE_PATH' status" >&2
    exit 0
  fi
  git worktree remove "$WORKTREE_PATH" 2>/dev/null || git worktree remove --force "$WORKTREE_PATH"
  git branch -d "$WORKTREE_BRANCH" 2>/dev/null || git branch -D "$WORKTREE_BRANCH"
  exit 0
fi

# Pre-merge: must have no uncommitted changes. Exclude /v's OWN bookkeeping file
# `.claude-session-lock` — it's created at the worktree root by the WorktreeCreate hook,
# is never user work, and (since the worktree is its own working-tree top level, the
# parent `.worktrees/.gitignore` does NOT apply inside it) always shows as an untracked
# `??` entry. Without this exclusion every locked worktree session would falsely fail
# here with "Commit before merge-back". The lock is removed with the worktree at cleanup.
#
# W71: match ANY git status code for the lock (`?? `, ` M `, `D  `, `A  `…), not just the
# untracked form. As of W71 the WorktreeCreate hook also git-excludes the lock so it
# shouldn't appear at all, but if a prior session committed it (tracked) or staged it, the
# old `^\?\? ` anchor missed it and this check false-failed. The porcelain path always
# follows "<XY> " so a leading-space anchor on the basename is safe.
# HIGH-1 (forensic 2026-07-07; REVISED after a node_modules landmine): the two
# dirty classes need DIFFERENT handling.
#   • TRACKED modifications (any porcelain XY code that is NOT '??' — staged/unstaged edits or deletes to
#     files git tracks) → genuinely make the in-worktree `git rebase $MAIN_BRANCH` below unsafe; KEEP the
#     hard block (conservative, unchanged).
#   • ONLY UNTRACKED files ('??') → they do NOT participate in the merge and do NOT block `git rebase`
#     (rebase refuses only on unstaged TRACKED changes; a genuine untracked-overwrite collision is surfaced
#     loudly as a conflict). The OLD blanket block stranded real commits off main forever on a single
#     untracked, session-generated `.spec.ts` (3 commits; the same class one batch earlier). So do
#     NOT block on untracked — PROCEED and let the rebase land the committed work. Do NOT commit them
#     either: an interim fix `git add -A`'d ALL untracked, which in a repo with node_modules un-ignored
#     (an embedded repo) would have committed node_modules ONTO main. Untracked files stay in the worktree
#     (recover a real deliverable there; the post-merge M2 guard keeps a dirty worktree, never destroys it).
# Opt-out V_MERGE_STRICT_CLEAN=1 restores the strict "any dirt blocks" behavior.
_mb_status="$(git -C "$WORKTREE_PATH" status --porcelain | grep -vE '[[:space:]]\.claude-session-lock$' || true)"
if [ -n "$_mb_status" ]; then
  _mb_tracked="$(printf '%s\n' "$_mb_status" | grep -vE '^\?\? ' || true)"
  if [ -n "$_mb_tracked" ] || [ "${V_MERGE_STRICT_CLEAN:-0}" = "1" ]; then
    echo "ERROR: worktree '$WORKTREE_PATH' has uncommitted changes. Commit before merge-back." >&2
    printf '%s\n' "$_mb_status" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "INFO: '$WORKTREE_PATH' has only UNTRACKED files; proceeding without committing them (they do not merge and are left in the worktree):" >&2
  printf '%s\n' "$_mb_status" | sed 's/^/  /' >&2
fi

# Acquire merge lock (PER-PROJECT, parallel-safe).
# W-conc-fix: PORTABLE locking. The original code used `flock` ONLY — but macOS has no
# `flock` ("flock: command not found"), so EVERY merge-back failed on darwin and the
# serialization that protects concurrent merge-backs never engaged (caught by the
# concurrency regression harness 2026-05-25). We now prefer flock where available
# (Linux/CI) and fall back to an atomic `mkdir` mutex (POSIX-portable) elsewhere.
mkdir -p "$REPO_ROOT/.worktrees"
MERGE_LOCK="$REPO_ROOT/.worktrees/.merge-lock"
MERGE_LOCK_DIR="$REPO_ROOT/.worktrees/.merge-lock.d"
LOCK_TIMEOUT=120
LOCK_STALE=600
_lock_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

if command -v flock >/dev/null 2>&1; then
  # ── flock path (Linux/CI) ──
  if [ -f "$MERGE_LOCK" ]; then
    LOCK_AGE=$(( $(date +%s) - $(_lock_mtime "$MERGE_LOCK") ))
    if [ "$LOCK_AGE" -gt "$LOCK_STALE" ]; then
      if exec 8>"$MERGE_LOCK" && flock -n 8 2>/dev/null; then
        flock -u 8 2>/dev/null || true; exec 8>&- 2>/dev/null || true; rm -f "$MERGE_LOCK"
      else
        exec 8>&- 2>/dev/null || true
      fi
    fi
  fi
  exec 9>"$MERGE_LOCK"
  if ! flock -w "$LOCK_TIMEOUT" 9; then
    echo "ERROR: could not acquire merge lock at $MERGE_LOCK within ${LOCK_TIMEOUT}s" >&2
    echo "ERROR: Another session is merging in this project. Retry: bash $0 $SESSION_ID $WORKTREE_PATH" >&2
    exec 9>&-; exit 1
  fi
  trap 'flock -u 9 2>/dev/null; exec 9>&-' EXIT INT TERM
else
  # ── portable mkdir-mutex path (macOS / no flock) ──
  # `mkdir` is atomic: it fails if the dir exists, giving correct mutual exclusion.
  _waited=0
  while ! mkdir "$MERGE_LOCK_DIR" 2>/dev/null; do
    if [ -d "$MERGE_LOCK_DIR" ]; then
      _age=$(( $(date +%s) - $(_lock_mtime "$MERGE_LOCK_DIR") ))
      if [ "$_age" -gt "$LOCK_STALE" ]; then
        echo "WARN: stale merge-lock dir (${_age}s > ${LOCK_STALE}s) — stealing" >&2
        rm -rf "$MERGE_LOCK_DIR" 2>/dev/null || true
        continue
      fi
    fi
    _waited=$((_waited + 1))
    if [ "$_waited" -ge "$LOCK_TIMEOUT" ]; then
      echo "ERROR: could not acquire merge lock (mkdir mutex) within ${LOCK_TIMEOUT}s" >&2
      echo "ERROR: Another session is merging in this project. Retry: bash $0 $SESSION_ID $WORKTREE_PATH" >&2
      exit 1
    fi
    sleep 1
  done
  printf '%s %s %s\n' "$SESSION_ID" "$$" "$(date +%s)" > "$MERGE_LOCK_DIR/owner" 2>/dev/null || true
  trap 'rm -rf "$MERGE_LOCK_DIR" 2>/dev/null' EXIT INT TERM
fi

echo "INFO: merge lock acquired ($MERGE_LOCK)"
echo "INFO: merging $WORKTREE_BRANCH → $MAIN_BRANCH (REPO_ROOT=$REPO_ROOT)"

# Fetch latest main (best-effort; works offline too)
git -C "$REPO_ROOT" fetch origin "$MAIN_BRANCH" 2>/dev/null || true

# FND-15: capture worktree branch HEAD BEFORE rebase. After rebase + before ff-merge,
# verify the branch ref hasn't drifted (e.g., parallel process force-pushed). If it did,
# bail with a clear "ref drifted, retry safe" message rather than failing ff-only opaquely.
WORKTREE_HEAD_BEFORE=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")

# W-conc-fix: capture whether main ADVANCED since this session forked. If it did,
# sibling sessions merged commits this session's gates never ran against — so even a
# clean (conflict-free) rebase+merge can leave main semantically broken (this branch
# may depend on, or be invalidated by, what a sibling changed). We signal the
# orchestrator (Step 6.5) to re-run pre-flight on the MERGED main before completing.
MAIN_HEAD_BEFORE=$(git -C "$REPO_ROOT" rev-parse "$MAIN_BRANCH" 2>/dev/null || echo "")
FORK_BASE=$(git -C "$REPO_ROOT" merge-base "$WORKTREE_BRANCH" "$MAIN_BRANCH" 2>/dev/null || echo "")

# W-conc-fix: refuse to merge OVER an actively-editing inline-on-main session. An
# inline-on-main editor (now only a Maintenance fast-path session, or a manual/legacy
# lock) edits main directly (uncommitted). Stashing + merging on top of that mid-edit is
# the tangle observed 2026-05-25 (worktree merge-back collided with a concurrent inline
# session's routes/web.php). This is a SELF-CONTAINED, age-bounded defensive find — it no
# longer routes through v-active-siblings.sh (which, post optimistic-universal-worktree,
# only scans worktree locks). The age bound (default 45min — short, leftover-tolerant)
# means a stale lock from a crashed inline session expires instead of blocking forever.
_INLINE_LOCK_AGE="${V_INLINE_LOCK_AGE:-45}"
_INLINE_SIBS=""
while IFS= read -r _lk; do
  [ -f "$_lk" ] || continue
  _lk_sid=$(awk 'NR==1{print $1}' "$_lk" 2>/dev/null)
  [ -n "$_lk_sid" ] && [ "$_lk_sid" != "$SESSION_ID" ] && _INLINE_SIBS="${_INLINE_SIBS}${_lk_sid} ${_lk}"$'\n'
done < <(find "$REPO_ROOT/.v/tmp" -name 'inline-main-lock-*' -mmin "-$_INLINE_LOCK_AGE" 2>/dev/null)
# ============================================================================
# W-GATE (forensic A-3 2026-06-04, P0-batch): ARTIFACT-PRESENCE MERGE PRECONDITION.
# H-5 merged to main with ZERO gate artifacts anywhere — no PRE_FLIGHT_REPORT, no
# AGENT_REVIEW — because nothing between the gauntlet and the merge verified the evidence
# exists. Merging is the irreversible step, so it carries the check: a code-bearing worktree
# may only merge when PRE_FLIGHT_REPORT_<sid> + AGENT_REVIEW_<sid> exist at MAIN's canonical
# artifact dir (or legacy roots / the worktree — consolidated first), OR a structurally-present
# non-code bypass marker (TRIVIAL_PASS / PLANNING_PASS / HANDOFF / CYCLE_CAP_HANDOFF) exists
# for the SID. Escape hatch for unusual flows: V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 (logged).
# Exit 1 (worktree intact, retry-safe) — NOT a reason for a manual merge (banner printed).
# ============================================================================
# Rescue/consolidate FIRST so artifacts living only in the worktree count toward the gate
# (and survive the later worktree removal regardless of gate outcome). Run FROM $REPO_ROOT:
# the consolidator resolves its roots from CWD, and merge-back has not cd'd yet here — an
# invocation from an unrelated directory would otherwise consolidate into THAT directory's
# .v/artifacts (caught by v-merge-artifact-gate-test.sh).
( cd "$REPO_ROOT" && bash "$_SCRIPT_DIR/v-artifact-consolidate.sh" "$SESSION_ID" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts" ) || true
if [ "${V_MERGE_BACK_SKIP_ARTIFACT_GATE:-0}" = "1" ]; then
  echo "WARN: V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 — artifact-presence merge precondition SKIPPED (W-GATE)" >&2
else
  # LAYERING (CODEX open item): W-GATE checks artifact PRESENCE only, by design — it is the
  # backstop for the H-5 "zero artifacts anywhere" class. CONTENT validation (semantic anchors,
  # independence) lives in the Stop hook + v-completion-selfcheck.sh; do not assume this gate
  # validates content.
  _gate_have() {  # <prefix> — present in canonical dir, either root, or the worktree.
    # NB: one glob per iteration — a multi-glob `ls a b c d` exits non-zero unless ALL
    # patterns match, which would demand the artifact exist in every location at once.
    local _d _g
    for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts"; do
      for _g in "$_d/${1}_"*"${SESSION_ID}"*.md; do
        [ -f "$_g" ] && return 0
      done
    done
    return 1
  }
  # P0-1 (forensic 2026-06-13): verify-done is a MANDATORY merge precondition
  # for CODE sessions, and an EXPLICIT FAIL verdict BLOCKS the merge. Two real failures motivated this:
  #   - One session (a concurrency/locking change) merged to main with verify-done NEVER run
  #     (its VERIFY_DONE_REPORT was backfilled 32 min POST-merge). The old gate required only
  #     PRE_FLIGHT + AGENT_REVIEW, so the mandatory verify-done step did not gate the irreversible merge.
  #   - Another session merged ~1 min AFTER its verify-done wrote "Overall Verdict: FAIL".
  # finalize-session-log.sh already mandates a VERIFY_DONE_REPORT for code sessions (session-writes
  # non-empty); the merge — the IRREVERSIBLE step — must enforce the same, plus refuse a FAIL verdict.
  # Bypass markers (non-code sessions) skip this entirely; V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 remains
  # the logged emergency hatch. This is a deliberate, narrow CONTENT exception to W-GATE's
  # presence-only design: only an explicit verdict VALUE token of `fail` blocks.
  _vdr_block_reason=""
  _verify_done_untrusted() {  # 0(true) iff a VERIFY_DONE_REPORT_<sid> must NOT gate a merge
    local _d _g
    for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts"; do
      for _g in "$_d/VERIFY_DONE_REPORT_"*"${SESSION_ID}"*.md; do
        [ -f "$_g" ] || continue
        # (A) EXPLICIT FAIL verdict — AUTHORITATIVE POSITIONS ONLY (ND-0716). The old unanchored
        # whole-file substring grep matched a NARRATIVE mention of a past fail ("## Notes: iteration 1
        # verdict: fail — fixed in iteration 2") and false-blocked a true final-line PASS (live-repro'd).
        # Mirror the Stop hook's VERIFY_DONE_FAIL detector (check-review-artifact.sh § VERIFY_DONE_FAIL)
        # so merge-back and the Stop hook read the SAME verdict: (1) final non-blank line matches the
        # W53 contract 'Overall Verdict: FAIL'; (2) legacy lane: a line-anchored '(Overall )?Verdict:
        # FAIL' within the LAST 5 lines only. Decoration class excludes '>' — a blockquoted
        # '> Overall Verdict: FAIL' is quoted history, not this report's verdict (SREV-001 parity).
        _vd_last=$(awk 'NF { last=$0 } END { print last }' "$_g" 2>/dev/null)
        if printf '%s' "$_vd_last" | grep -qiE '^[[:space:]*#-]*overall[[:space:]]+verdict:[[:space:]]*fail([[:space:]*_]|$)' \
           || tail -5 "$_g" 2>/dev/null | grep -qiE '^[[:space:]*#-]*(overall[[:space:]]+)?verdict:[[:space:]]*fail([[:space:]*_]|$)'; then
          _vdr_block_reason="VERIFY_DONE_REPORT verdict is FAIL"
          return 0
        fi
        # (B) UNTRUSTED SCOPE (HIGH-3 + security-review #4). Mode `scoped(...:no-isolation)` means
        # verify-done could NOT isolate the changed set to THIS session's worktree (it ran on shared
        # main / a post-merge or WRONG worktree), so even a PASS does not actually verify this
        # session's diff — accepting it would let the wrong-tree class merge on a
        # meaningless PASS. A non-isolated verify-done is not a valid merge gate: re-run /v-verify-done
        # in the session's own worktree, or HANDOFF.
        if grep -iqE '^Mode:.*no-isolation' "$_g"; then
          _vdr_block_reason="VERIFY_DONE_REPORT ran with no-isolation scope (could not isolate to this session's worktree — its verdict does not verify this diff)"
          return 0
        fi
      done
    done
    return 1
  }
  _qa_report_fail() {  # 0(true) iff a QA_REPORT_<sid> carries an explicit TOP verdict:fail → block the merge (R10)
    local _d _g _v
    for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts"; do
      for _g in "$_d/QA_REPORT_"*"${SESSION_ID}"*.md; do
        [ -f "$_g" ] || continue
        # Authoritative TOP verdict only: the FIRST col-0 `verdict:` line — IDENTICAL extraction to
        # validate_qa_report_structure() in hooks/lib/validation.sh, so merge-back and the Stop hook read
        # the SAME verdict. Col-0 anchor + first-match ⇒ an iteration-history / prose "verdict: fail" line
        # can never false-block a genuine top-line PASS (R10 hardening).
        # F2-upstream (round-3 2026-07-02): accept quote/backtick/bold-wrapped verdict VALUES — a
        # `verdict: "fail"` evaded the bare-token match (adversarial-review PoC landed a QA-failed
        # branch through the drain's identical blind spot). BYTE-IDENTICAL to validation.sh's
        # validate_qa_report_structure() pipeline — pinned by qa-verdict-wrapped-parity-test.sh.
        _v=$(grep -iE '^verdict:[[:space:]]*["'"'"'`*_]*(pass|escalated|fail)' "$_g" 2>/dev/null | head -1 \
             | sed -E 's/^[[:space:]]*[Vv][Ee][Rr][Dd][Ii][Cc][Tt]:[[:space:]]*//' | tr -d '"*_\140\047' | awk '{print tolower($1)}')
        if [ "$_v" = fail ]; then
          _qa_block_reason="QA_REPORT verdict is FAIL — QA acceptance rejected this change (resolve the findings via the SME remediation loop or HANDOFF; do NOT merge QA-rejected work). (F3 / R10)"
          return 0
        fi
      done
    done
    return 1
  }
  # H4-6 (PLAN_2026-07-02_orchestrator-hardening-4): AGENT_REVIEW Stop-grade semantic check at the
  # merge point itself (defense-in-depth alongside v-gauntlet-attest.sh's own H4-6 check). Ground
  # truth: a session attested + merged with an AGENT_REVIEW the Stop hook LATER ruled semantically
  # invalid (hostile review required but undeclared) — the merge's OWN gate only checked PRESENCE,
  # never validate_review_semantics, so the irreversible merge step never saw this class of defect.
  # Uses the SAME single-sourced hostile verdict (v-hostile-required.sh, H4-5) the Stop hook uses.
  _agent_review_semantic_invalid() {  # 0(true) iff AGENT_REVIEW fails Stop-grade semantic validation
    local _d _g _vallib _hr _hreq _err
    _vallib="$HOME/.claude/hooks/lib/validation.sh"
    [ -f "$_vallib" ] || return 1
    # shellcheck source=/dev/null
    . "$_vallib" 2>/dev/null || return 1
    type validate_review_semantics >/dev/null 2>&1 || return 1
    _hr="$HOME/.claude/skills/v/references/v-hostile-required.sh"
    _hreq=0
    if [ -f "$_hr" ]; then
      # Capture to a variable FIRST, then match — this file runs under `set -euo pipefail` (line 21).
      # The old form piped `bash "$_hr" | grep -m1 ... | cut ...` directly: `grep -m1` can exit the
      # instant it matches line 1 of the real script's output (v-hostile-required.sh prints
      # HOSTILE_REQUIRED= first, before a multi-line HOSTILE_PATHS block), SIGPIPE-killing the
      # upstream `bash "$_hr"` process; under pipefail the pipeline's status becomes that SIGPIPE
      # death, and under `set -e` that non-zero status can abort THIS WHOLE SCRIPT mid-merge — a
      # more severe failure than a wrong value (bonus fix, 2026-08-19, found while fixing the same
      # SIGPIPE-under-pipefail class in check-review-artifact.sh; live-reproduced here at 4/30 runs
      # aborting outright, matching this codebase's own documented instances of this bug class).
      _hr_out=""
      _hr_out="$(bash "$_hr" --sid "$SESSION_ID" --worktree-root "$REPO_ROOT" 2>/dev/null || true)"
      _hreq="$(printf '%s\n' "$_hr_out" | grep -m1 '^HOSTILE_REQUIRED=' | cut -d= -f2)"
      [ "$_hreq" = "1" ] || _hreq=0
    fi
    for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts"; do
      for _g in "$_d/AGENT_REVIEW_"*"${SESSION_ID}"*.md; do
        [ -f "$_g" ] || continue
        if ! _err=$(validate_review_semantics "$_g" 1 "$_hreq" "$SESSION_ID" 1 2>&1); then
          _ar_block_reason="AGENT_REVIEW failed Stop-grade semantic validation (hostile_required=${_hreq}) — ${_err}. Fix the artifact (re-dispatch the failing gate); do NOT merge a semantically-invalid review. (H4-6)"
          return 0
        fi
        return 1
      done
    done
    return 1
  }
  # W5G-4-MERGE (forensic 2026-07-10): provenance/tamper check at the merge point
  # itself. One session's AGENT_REVIEW + VERIFY_DONE_REPORT were hand-edited after their independent
  # dispatches (on-disk sha256 matched NO recorded status=ok sha; the dispatched originals were
  # destroyed, so even the honest 'Post-dispatch edit:' declarations could not downgrade). The Stop
  # hook's W5G-4 gate blocked 3× and was then MASKED by the rearm-escape — and this script landed
  # the branch anyway, because the merge's own gate checked presence + semantics but never
  # provenance. Merge is the irreversible step: enforce the SAME verdict via the SAME lib
  # primitives (no reimplementation → no drift). Resolutions are identical to the Stop hook's:
  # re-dispatch the gate so its output is canonical, or keep the dispatched original under
  # .v/archive/<sid>/ alongside a 'Post-dispatch edit:' line (v-dispatch-subagent.sh now archives
  # originals automatically at ok-time — W5G-4c, so this state should be rare going forward).
  # Self-written artifacts with no recorded dispatch sha are exempt exactly as in the lib (rc 1 =
  # no recorded hash); V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 above skips this with the rest of W-GATE.
  _tamper_block_reason=""
  _artifact_tamper_unresolved() {  # 0(true) iff a dispatched gate artifact is post-dispatch-edited with no surviving original
    local _d _g _vallib="$HOME/.claude/hooks/lib/validation.sh"
    [ -f "$_vallib" ] || return 1
    # shellcheck source=/dev/null
    . "$_vallib" 2>/dev/null || return 1
    type _artifact_postdispatch_edited >/dev/null 2>&1 || return 1
    type _dispatched_original_survives >/dev/null 2>&1 || return 1
    # The lib primitives read these globals (same contract the Stop hook fulfills before calling).
    # The worktree-scoped archive dir is included for the survives-scan (adversarial review
    # 2026-07-10, MED-HIGH): if the archiver's main-root resolution ever falls back to a
    # worktree-local ART_DIR, the preserved original lands in <worktree>/.v/archive/<sid>/ —
    # a store _dispatched_original_survives's own two extra dirs never cover ($REPO_ROOT-only).
    # Without this, a genuinely-preserved original could still read as UNRESOLVED tamper here —
    # reintroducing the exact declared-edit false-block this gate's W5G-4c companion fix closed.
    # W5G-11 (review MED-HIGH): include the MAIN-ROOT archive too, so this trio searches the
    # SAME dirs the attest-time gate (v-gauntlet-attest.sh) does — else a dispatched original
    # preserved only under $REPO_ROOT/.v/archive/<sid>/ satisfies attest but FALSE-BLOCKS here
    # on a check that is supposed to be identical.
    ARTIFACT_SEARCH_DIRS=("$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "${WORKTREE_PATH:-}/.v/artifacts" "${WORKTREE_PATH:-}" "${WORKTREE_PATH:-}/.v/archive/${SESSION_ID}" "$REPO_ROOT/.v/archive/${SESSION_ID}")
    for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "${WORKTREE_PATH:-}" "${WORKTREE_PATH:-}/.v/artifacts"; do
      [ -n "$_d" ] && [ -d "$_d" ] || continue
      for _g in "$_d/AGENT_REVIEW_${SESSION_ID}.md" "$_d/VERIFY_DONE_REPORT_${SESSION_ID}.md" "$_d/PRE_FLIGHT_REPORT_${SESSION_ID}.md"; do
        [ -f "$_g" ] || continue
        if _artifact_postdispatch_edited "$_g"; then
          if grep -qiE '^Post-dispatch edit:' "$_g" 2>/dev/null && _dispatched_original_survives "$_g"; then
            continue  # declared + original preserved → the Stop hook's own warned-fallback path
          fi
          _tamper_block_reason="$(basename "$_g") was modified AFTER its independent dispatch (on-disk sha256 matches no recorded status=ok sha in DISPATCH_PROVENANCE) and the dispatched original does not survive in any durable store — the W5G-4 tamper state is UNRESOLVED. Do NOT merge: re-dispatch that gate so its output is canonical (or restore the dispatched original under .v/archive/${SESSION_ID}/ and add a 'Post-dispatch edit:' line), then re-run merge-back. A rearm-escape does NOT waive this. (W5G-4-MERGE)"
          return 0
        fi
      done
    done
    return 1
  }
  _gate_ok=0; _gate_via_gauntlet=0
  # E1 (forensic 2026-06-17): name EXACTLY which of the three gauntlet artifacts is
  # absent. A production session ran merge-back while VERIFY_DONE was still being produced (dispatched with
  # run_in_background); the old generic "PRE_FLIGHT, AGENT_REVIEW, and/or VERIFY_DONE missing" message
  # forced the model to manually probe root vs .v/artifacts to discover only VERIFY_DONE was absent
  # (minutes of thrash + premature re-runs). A precise present/MISSING split + a "wait for backgrounded
  # gates" hint points straight at the gap. Control-flow-identical to the old `&&` chain (all-present ⟺
  # $_absent empty); only the diagnostic message changes.
  _present=""; _absent=""
  for _ga in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
    if _gate_have "$_ga"; then _present="${_present:+$_present, }$_ga"; else _absent="${_absent:+$_absent, }$_ga"; fi
  done
  _gate_missing="MISSING: ${_absent:-none} (present: ${_present:-none}). Searched $REPO_ROOT/.v/artifacts + repo root + the worktree. If a gate was dispatched with run_in_background, WAIT for it to finish writing its report BEFORE re-running merge-back — do NOT background gauntlet gates (W-perf9)."
  if [ -z "$_absent" ]; then
    if _verify_done_untrusted; then
      _gate_ok=0
      _gate_missing="(verify-done not mergeable: ${_vdr_block_reason}. Resolve and re-run /v-verify-done in the session's worktree; do NOT merge. P0-1/HIGH-3)"
    elif _agent_review_semantic_invalid; then
      _gate_ok=0
      _gate_missing="($_ar_block_reason)"
    elif _artifact_tamper_unresolved; then
      _gate_ok=0
      _gate_missing="($_tamper_block_reason)"
    else
      _gate_ok=1; _gate_via_gauntlet=1
    fi
  else
    for _byp in TRIVIAL_PASS PLANNING_PASS HANDOFF CYCLE_CAP_HANDOFF; do
      if _gate_have "$_byp"; then _gate_ok=1; break; fi
    done
  fi
  # ── F3 IMPACT_MAP + QA merge gate (forensic 2026-06-17) ────────────────────────────────────────
  # One session merged with PRE_FLIGHT+AGENT_REVIEW+VERIFY_DONE present but IMPACT_MAP + QA_REPORT ABSENT —
  # the Stop hook (which requires BOTH for code sessions) caught them only POST-merge, after the code was
  # on main + the model reactively hand-authored the missing artifacts. Merge is the irreversible step, so
  # it carries the SAME hard-artifact requirements the Stop hook enforces for code sessions (identical
  # pattern to the P1.1 UI gate below). PRESENCE only — content/independence stay with the Stop hook
  # (W-GATE layering). Applies ONLY when the full gauntlet path set _gate_ok (a code session); a bypass
  # marker (non-code/deferred) is exempt. V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 remains the emergency hatch.
  if [ "$_gate_ok" = 1 ] && [ "${_gate_via_gauntlet:-0}" = 1 ]; then
    if ! _gate_have IMPACT_MAP; then
      _gate_ok=0
      _gate_missing="code session ran the gauntlet but IMPACT_MAP_${SESSION_ID}.md is missing — /v Step 1.8 Impact Analysis is mandatory for code changes (the Stop hook blocks without it POST-merge; the merge must enforce it PRE-merge). Write IMPACT_MAP enumerating every connected subsystem, or re-run via /v. Do NOT merge. (F3)"
    elif ! _gate_have QA_REPORT; then
      _gate_ok=0
      _gate_missing="code session ran the gauntlet but QA_REPORT_${SESSION_ID}.md is missing — /v Step 6.4.9 QA Acceptance is mandatory for code changes. Dispatch v-qa-reviewer (bash ~/.claude/skills/v/references/v-dispatch-subagent.sh v-qa-reviewer); do NOT merge unverified. (F3)"
    elif _qa_report_fail; then
      _gate_ok=0
      _gate_missing="$_qa_block_reason"
    fi
  fi
  # ── P1.1 UI-verification merge gate (forensic 2026-06-15) ──────────────────────────────────────
  # One session shipped React .tsx changes to main with NO UX_CRITIQUE and NO WORKFLOW_VERIFICATION:
  # the orchestrator never self-flagged it UI (V_UI_SESSION unset), so the producer self-check passed
  # and merge-back proceeded; the Stop hook's path-based W49 gate only fired POST-merge (too late).
  # Merge is the irreversible step, so it carries the UI check too — mirroring the Stop hook's
  # any_user_facing_ui detection, but from the COMMITTED worktree diff (FORK_BASE..branch), since the
  # session-writes log is unreliable in the forked/headless runner (HOOK-5). A code session whose diff
  # touches user-facing UI may only merge with UX_CRITIQUE present AND WORKFLOW_VERIFICATION present
  # with status pass|degraded (status: fail = a broken flow, blocks). PRESENCE/STATUS only — content +
  # independence stay with the Stop hook + self-check (W-GATE layering). degraded is the honest escape.
  if [ "$_gate_ok" = 1 ]; then
    _ui_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/ui-path-pattern.sh"
    [ -f "$_ui_lib" ] && . "$_ui_lib"
    _ui_diff_base="${FORK_BASE:-$MAIN_BRANCH}"
    _ui_diff=$(git -C "$REPO_ROOT" diff --name-only "${_ui_diff_base}".."$WORKTREE_BRANCH" 2>/dev/null || true)
    if [ -n "$_ui_diff" ] && type any_user_facing_ui >/dev/null 2>&1 && any_user_facing_ui "$_ui_diff"; then
      if ! _gate_have UX_CRITIQUE; then
        _gate_ok=0
        _gate_missing="UI files changed but UX_CRITIQUE_${SESSION_ID}.md is missing — Step 3.5 UX critique is mandatory for UI changes. Dispatch v-ux-critique-reviewer (bash ~/.claude/skills/v/references/v-dispatch-subagent.sh v-ux-critique-reviewer); do NOT merge UI work unverified. (P1.1)"
      else
        _wf_status=""
        for _d in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts"; do
          for _g in "$_d/WORKFLOW_VERIFICATION_"*"${SESSION_ID}"*.md; do
            [ -f "$_g" ] || continue
            if grep -iqE '^status:[[:space:]]*\**[[:space:]]*fail' "$_g"; then _wf_status="fail"
            elif grep -iqE '^status:[[:space:]]*\**[[:space:]]*(pass|degraded)' "$_g"; then _wf_status="ok"; fi
            break 2
          done
        done
        if [ -z "$_wf_status" ]; then
          _gate_ok=0
          _gate_missing="UI files changed but WORKFLOW_VERIFICATION_${SESSION_ID}.md is missing — Step 3.5 browser workflow verification is mandatory for UI changes. Dispatch v-workflow-verifier; if the browser env is genuinely unavailable write the artifact with 'status: degraded' + a 'degraded_reason:' line. Do NOT merge. (P1.1)"
        elif [ "$_wf_status" = "fail" ]; then
          _gate_ok=0
          _gate_missing="UI files changed and WORKFLOW_VERIFICATION status is FAIL — a user-facing flow is broken in the browser. Fix the WF-* findings and re-run v-workflow-verifier; do NOT merge a broken flow to main. (P1.1)"
        fi
      fi
    fi
  fi
  if [ "$_gate_ok" != 1 ]; then
    echo "ERROR: W-GATE artifact-presence merge precondition FAILED for SID=$SESSION_ID." >&2
    echo "ERROR:   required (code session): $_gate_missing" >&2
    echo "ERROR:   searched: $REPO_ROOT/.v/artifacts, $REPO_ROOT, $WORKTREE_PATH[/.v/artifacts]" >&2
    echo "ERROR:   (no TRIVIAL_PASS / PLANNING_PASS / HANDOFF / CYCLE_CAP_HANDOFF bypass marker found either)" >&2
    echo "ERROR: Run the gauntlet (/v-pre-flight + agent review + /v-verify-done) and re-run this script —" >&2
    echo "ERROR: the worktree is intact. Merging unreviewed/unverified code is the H-5 class." >&2
    _print_never_manual_banner
    # P1-C (2026-06-30): drop a SESSION_LOG_PENDING marker. A W-GATE-blocked session writes NO commit-witness and
    # NO merge-deferred marker, so the integrity sweep only catches it after V_SL_MISSING_AGE_SEC (6h); in that
    # window 2+ such sessions make the session-log resolver refuse on "multiple unlogged sessions" (exit-6). This
    # marker is consumed by resolve-session-sid.sh's _sid_marked() so the session is no longer an unmarked candidate.
    # Suppressed by precedence once a SESSION_LOG is written (the resolver checks _sid_logged FIRST); an aged-out
    # PENDING (> V_SL_PENDING_AGE_SEC) is promoted to MISSING by resolve-session-sid.sh. Best-effort; never fails the script.
    for _pdir in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT"; do
      [ -d "$_pdir" ] || continue
      printf '# SESSION_LOG_PENDING — %s\n\nThe gauntlet ran but merge-back was BLOCKED at the W-GATE (artifacts incomplete: %s).\nA session log is owed; the work is still on the build branch. Remove once logged or abandoned.\nWhen: %s\n' \
        "$SESSION_ID" "${_gate_missing:-<unknown>}" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" \
        > "$_pdir/SESSION_LOG_PENDING_${SESSION_ID}.md" 2>/dev/null && break
    done
    exit 1
  fi
fi

if [ -n "$_INLINE_SIBS" ]; then
  HANDOFF_FILE="$REPO_ROOT/.v/artifacts/WORKTREE_HANDOFF_$SESSION_ID.md"; mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null || HANDOFF_FILE="$REPO_ROOT/WORKTREE_HANDOFF_$SESSION_ID.md"
  {
    echo "Model: orchestrator"; echo "SID: $SESSION_ID"; echo
    echo "## Worktree Handoff — merge-back deferred (active inline-on-main session)"
    echo
    echo "An inline-on-main session is actively editing main (uncommitted), so merging this"
    echo "worktree now would tangle/clobber its work. Active inline sibling(s):"
    echo "$_INLINE_SIBS"
    echo
    echo "Resolution: wait for the inline session to finish (commit or stage + release its"
    echo "lock at \$REPO_ROOT/.v/tmp/inline-main-lock-*), then re-run:"
    echo "  bash $0 $SESSION_ID $WORKTREE_PATH"
    echo
    echo "Handoff Status: BLOCKED"
  } > "$HANDOFF_FILE"
  echo "ERROR: active inline-on-main session detected — deferring merge-back to avoid tangling main." >&2
  echo "ERROR: handoff written to $HANDOFF_FILE" >&2
  exit 1
fi

# ============================================================================
# W17-2: Autonomous conflict resolution.
#
# When `git rebase $MAIN_BRANCH` produces conflicts, we resolve them by file
# type rather than aborting. Strategy by file class:
#
#   1. Lockfiles (composer.lock, package-lock.json, yarn.lock, pnpm-lock.yaml,
#      Gemfile.lock, Cargo.lock, poetry.lock, uv.lock, go.sum) →
#      take main's version (--theirs in rebase semantics) and queue regeneration
#      after rebase completes (composer install / npm install / etc.).
#
#   2. Generated/cached files (paths matching .cache/, public/build/, dist/,
#      bootstrap/cache/, storage/framework/cache/, _next/, .next/, build/,
#      coverage/, .nyc_output/) → take main's version (--theirs); these are
#      regeneratable.
#
#   3. Files in this session's session-writes log (
#      $V_TMP_DIR/session-writes-${SESSION_ID}.txt) → take worktree's version (--ours
#      in rebase semantics). The session deliberately changed these; main's
#      version is from a parallel session that didn't know about ours, but
#      the user invoked /v on these files specifically.
#
#   4. Documentation (*.md, docs/**, README*) → take worktree's version
#      (newer iteration; if main has a meaningful conflicting change, the
#      session-writes log already covers it via #3).
#
#   5. Anything else (code files NOT in session-writes log) → take main's
#      version (--theirs). These weren't session-owned; main's version is
#      what other sessions or the user already merged.
#
# After resolving each conflicted commit, `git add` resolved files and
# `git rebase --continue`. The rebase may surface new conflicts on later
# commits — repeat resolution until clean or 10 cycles (real-world cap).
#
# Only fall back to WORKTREE_HANDOFF if a single conflict can't be resolved
# by ANY rule (e.g., a binary file requiring true 3-way merge).
# ============================================================================

# HOOK-5 (CRITICAL fix): the AUTHORITATIVE session-writes log is written by
# the track-session-writes.sh PreToolUse hook to ${git_common_dir}/claude-session-writes-${SID}.txt.
# The orchestrator's W18 path ($V_TMP_DIR/session-writes-...) is only populated if the
# orchestrator itself appends; it may be empty or stale. Read both and union the contents
# so the resolve_conflict_file "session-owned → take-WORKTREE" classification fires
# correctly regardless of which writer was active.
SESSION_WRITES_ORCH="$V_TMP_DIR/session-writes-${SESSION_ID}.txt"
SESSION_WRITES_HOOK_DIR=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
SESSION_WRITES_HOOK=""
if [ -n "$SESSION_WRITES_HOOK_DIR" ]; then
  SESSION_WRITES_HOOK="$SESSION_WRITES_HOOK_DIR/claude-session-writes-${SESSION_ID}.txt"
fi
SESSION_WRITES="$V_TMP_DIR/session-writes-merged-${SESSION_ID}.txt"
{
  [ -f "$SESSION_WRITES_ORCH" ] && cat "$SESSION_WRITES_ORCH" 2>/dev/null
  [ -n "$SESSION_WRITES_HOOK" ] && [ -f "$SESSION_WRITES_HOOK" ] && cat "$SESSION_WRITES_HOOK" 2>/dev/null
} | sort -u > "$SESSION_WRITES" 2>/dev/null || : > "$SESSION_WRITES"
LOCKFILE_REGEX='(^|/)(composer\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile\.lock|Cargo\.lock|poetry\.lock|uv\.lock|go\.sum)$'
GENERATED_REGEX='(^|/)(\.cache/|public/build/|dist/|bootstrap/cache/|storage/framework/cache/|_next/|\.next/|build/|coverage/|\.nyc_output/)'
DOCS_REGEX='(^|/)(.*\.md$|docs/|README)'
RESOLVED_LOCKFILES=""
RESOLVE_LOG="$V_TMP_DIR/merge-resolve-${SESSION_ID}.log"
: > "$RESOLVE_LOG"
# A1 (forensic 2026-06-21): record the worktree path + branch as a STRUCTURED header so the
# session-log generator can recover classification.worktree.created=true with a C4-valid EXTERNAL
# path. Without this the merge-resolve log proved a worktree ran (R6g) but carried no path line (0 of
# 69 logs on disk), so the generator's path-recovery sed came up empty and left created=false -> R6g
# quarantine (3 of 4 sessions on 2026-06-21). pwd -P resolves the in-project .worktrees/ compat
# symlink to the real ~/.claude/worktrees/<repo>/<name> external path (C4 requires the path UNDER the
# external base). Header lines precede the rebase output; downstream parsers key on the prefix.
{
  printf 'worktree_path: %s\n'   "$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P || printf '%s' "$WORKTREE_PATH")"
  printf 'worktree_branch: %s\n' "$WORKTREE_BRANCH"
} >> "$RESOLVE_LOG"

# Per-file resolver. Returns 0 if resolved, 1 if requires manual intervention.
#
# CRITICAL semantic note: during `git rebase main`, the meaning of --ours and
# --theirs is INVERTED relative to a normal merge:
#   --ours   = main (the base we're rebasing onto)
#   --theirs = worktree branch (the commits being replayed)
# This is counterintuitive but documented in `git rebase` help.
# We deliberately use the rebase-correct names below, with comments explaining
# which physical branch each side maps to.
resolve_conflict_file() {
  local f="$1"
  if [ "$(basename "$f")" = ".claude-session-lock" ]; then
    # W-perf4: the session lock is per-worktree bookkeeping, NEVER real work. If a stale
    # TRACKED copy committed on main (a prod session's branch did exactly this)
    # collides with this worktree's lock, take MAIN's (--ours during rebase) so the
    # conflict can't ESCALATE or land the lock in the merged tree. The durable fix is
    # upstream (worktree-lock-exclude.sh assume-unchanged keeps it out of commits at all);
    # this is the belt-and-suspenders for branches that already committed it.
    git -C "$WORKTREE_PATH" checkout --ours -- "$f" 2>/dev/null \
      || git -C "$WORKTREE_PATH" rm -f --cached -- "$f" 2>/dev/null || return 1
    git -C "$WORKTREE_PATH" add -- "$f" 2>/dev/null || true
    echo "  $f → take-MAIN (session-lock bookkeeping; never real work)" >> "$RESOLVE_LOG"
    return 0
  fi
  if echo "$f" | grep -qE "$LOCKFILE_REGEX"; then
    # Take MAIN's lockfile (--ours during rebase) and regenerate after rebase.
    git -C "$WORKTREE_PATH" checkout --ours -- "$f" 2>/dev/null || return 1
    git -C "$WORKTREE_PATH" add -- "$f"
    RESOLVED_LOCKFILES="${RESOLVED_LOCKFILES}${f}\n"
    echo "  $f → take-MAIN (lockfile, will regenerate)" >> "$RESOLVE_LOG"
    return 0
  fi
  if echo "$f" | grep -qE "$GENERATED_REGEX"; then
    # Take MAIN's version (--ours); these are regeneratable.
    git -C "$WORKTREE_PATH" checkout --ours -- "$f" 2>/dev/null || return 1
    git -C "$WORKTREE_PATH" add -- "$f"
    echo "  $f → take-MAIN (generated/cache)" >> "$RESOLVE_LOG"
    return 0
  fi
  if echo "$f" | grep -qE "$DOCS_REGEX"; then
    # Docs: take WORKTREE's version (--theirs); newer iteration usually wins for docs.
    git -C "$WORKTREE_PATH" checkout --theirs -- "$f" 2>/dev/null || return 1
    git -C "$WORKTREE_PATH" add -- "$f"
    echo "  $f → take-WORKTREE (docs/markdown)" >> "$RESOLVE_LOG"
    return 0
  fi
  # W-conc-fix (LOST-UPDATE GUARD — hook-independent): everything reaching here is a
  # CODE/CONFIG file with a genuine rebase CONFLICT, which means BOTH this session and
  # `main` (a parallel session, or a direct commit) changed the SAME region since this
  # session forked. EITHER silent pick loses a real change:
  #   - take-MAIN  (the old default) silently drops THIS session's work;
  #   - take-WORKTREE silently drops the sibling's work.
  # Both ship wrong code, and the per-session merge-back has NO downstream cross-session
  # review to catch it. So we NEVER guess on a code/config conflict — escalate to
  # WORKTREE_HANDOFF and let it be resolved with full context (the orchestrator, or
  # `/v-merge-all` Step 4f which can combine/revert). This is deliberately NOT gated on
  # the session-writes log: that log depends on the track-session-writes hook firing,
  # which is unreliable in the forked/headless runner — so type-based escalation is the
  # only robust guard. (Lockfiles/generated/docs were already auto-resolved above.)
  echo "  $f → ESCALATE (code/config conflict = cross-session SAME-region overlap; refusing to silently pick a side — would lose one session's work)" >> "$RESOLVE_LOG"
  return 1
}

MAX_CYCLES=10
CYCLE=0
echo "INFO: starting rebase $WORKTREE_BRANCH onto $MAIN_BRANCH" >&2
# Wrap with || true to prevent `set -e` from killing the script on conflict.
REBASE_RC=0
git -C "$WORKTREE_PATH" rebase "$MAIN_BRANCH" >> "$RESOLVE_LOG" 2>&1 || REBASE_RC=$?

while [ $REBASE_RC -ne 0 ] && [ $CYCLE -lt $MAX_CYCLES ]; do
  CYCLE=$((CYCLE + 1))
  CONFLICT_FILES=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null)
  if [ -z "$CONFLICT_FILES" ]; then
    echo "WARN: rebase failed (rc=$REBASE_RC) but no conflict files reported — aborting" >&2
    git -C "$WORKTREE_PATH" rebase --abort 2>/dev/null || true
    break
  fi
  echo "INFO: cycle $CYCLE — resolving $(echo "$CONFLICT_FILES" | wc -l | tr -d ' ') conflicts" >&2
  echo "Cycle $CYCLE conflicts:" >> "$RESOLVE_LOG"

  UNRESOLVABLE=""
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! resolve_conflict_file "$f"; then
      UNRESOLVABLE="${UNRESOLVABLE}${f}\n"
    fi
  done <<< "$CONFLICT_FILES"

  if [ -n "$UNRESOLVABLE" ]; then
    echo "ERROR: cannot autonomously resolve:" >&2
    echo -e "$UNRESOLVABLE" >&2
    git -C "$WORKTREE_PATH" rebase --abort 2>/dev/null || true
    break
  fi

  # Continue rebase (next commit may have its own conflicts → loop)
  CONTINUE_RC=0
  GIT_EDITOR=true git -C "$WORKTREE_PATH" rebase --continue >> "$RESOLVE_LOG" 2>&1 || CONTINUE_RC=$?
  if [ $CONTINUE_RC -eq 0 ]; then
    REBASE_RC=0
    echo "INFO: rebase continued cleanly after cycle $CYCLE" >&2
    break
  else
    REBASE_RC=$CONTINUE_RC
    # If new conflicts surfaced, loop again. If something else failed, exit loop.
    if [ -z "$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null)" ]; then
      echo "WARN: rebase --continue failed (rc=$REBASE_RC) without new conflicts — aborting" >&2
      git -C "$WORKTREE_PATH" rebase --abort 2>/dev/null || true
      break
    fi
  fi
done

# Regenerate lockfiles if any were take-theirs'd
if [ -n "$RESOLVED_LOCKFILES" ]; then
  echo "INFO: regenerating lockfiles after take-MAIN (lockfile) resolution" >&2
  if echo -e "$RESOLVED_LOCKFILES" | grep -q 'composer\.lock'; then
    (cd "$WORKTREE_PATH" && composer install --no-interaction --quiet 2>&1) >> "$RESOLVE_LOG" ||       echo "WARN: composer install after lockfile resolution failed; manual review needed" >&2
  fi
  if echo -e "$RESOLVED_LOCKFILES" | grep -qE 'package-lock\.json|yarn\.lock|pnpm-lock\.yaml'; then
    (cd "$WORKTREE_PATH" && npm install --silent 2>&1) >> "$RESOLVE_LOG" ||       echo "WARN: npm install after lockfile resolution failed; manual review needed" >&2
  fi
fi

if [ $REBASE_RC -ne 0 ]; then
  # Truly unresolvable — write handoff and exit
  HANDOFF_FILE="$REPO_ROOT/.v/artifacts/WORKTREE_HANDOFF_$SESSION_ID.md"; mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null || HANDOFF_FILE="$REPO_ROOT/WORKTREE_HANDOFF_$SESSION_ID.md"
  REMAINING_CONFLICTS=$(git -C "$WORKTREE_PATH" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
  cat > "$HANDOFF_FILE" <<HANDOFF_EOF
Model: orchestrator
SID: $SESSION_ID

## Worktree Handoff

worktree_path: $WORKTREE_PATH
worktree_branch: $WORKTREE_BRANCH
last_commit: $(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo unknown)
merge_target: $MAIN_BRANCH
cycles_attempted: $CYCLE
remaining_conflicts: $REMAINING_CONFLICTS

## Resolution Log

See: $RESOLVE_LOG

## Recovery Steps

The autonomous resolver handled most cases by file type (lockfiles, generated files,
session-owned files, docs). What remains needs human attention — likely a binary file
or a true 3-way merge that the strategies couldn't categorize.

1. cd $WORKTREE_PATH
2. git rebase $MAIN_BRANCH
3. Resolve remaining conflicts in: $REMAINING_CONFLICTS
4. git rebase --continue
5. cd $REPO_ROOT && git merge --ff-only $WORKTREE_BRANCH
6. git worktree remove $WORKTREE_PATH
7. git branch -d $WORKTREE_BRANCH

Or invoke: /v-merge-all (handles batch consolidation)

Handoff Status: BLOCKED
HANDOFF_EOF
  echo "ERROR: autonomous merge exhausted after $CYCLE cycles; worktree intact for manual recovery" >&2
  echo "ERROR: handoff written to $HANDOFF_FILE" >&2
  echo "ERROR: resolution log at $RESOLVE_LOG" >&2
  exit 1
fi

echo "INFO: autonomous merge succeeded ($CYCLE conflict-resolution cycle$([ $CYCLE -ne 1 ] && echo s))"

# FND-15: verify the worktree branch ref still points where our local rebase left it.
# If something force-pushed the branch between rebase and now, ff-only would fail
# with an opaque error. Bail with a retry-safe message instead.
if [ -n "$WORKTREE_HEAD_BEFORE" ]; then
  WORKTREE_HEAD_LOCAL=$(git -C "$WORKTREE_PATH" rev-parse HEAD 2>/dev/null || echo "")
  WORKTREE_BRANCH_REF=$(git -C "$WORKTREE_PATH" rev-parse "refs/heads/$WORKTREE_BRANCH" 2>/dev/null || echo "")
  if [ -n "$WORKTREE_HEAD_LOCAL" ] && [ -n "$WORKTREE_BRANCH_REF" ] && [ "$WORKTREE_HEAD_LOCAL" != "$WORKTREE_BRANCH_REF" ]; then
    echo "ERROR: branch ref $WORKTREE_BRANCH drifted during rebase (local HEAD=$WORKTREE_HEAD_LOCAL, branch ref=$WORKTREE_BRANCH_REF)" >&2
    echo "ERROR: A parallel process likely force-pushed. Retry is safe — exiting non-zero so the orchestrator can re-run." >&2
    exit 1
  fi
fi

# Fast-forward merge into main
cd "$REPO_ROOT"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# UX-FND-4: NEVER auto-commit user's WIP in main to "unblock" merge-back. Auto-stash
# is acceptable (non-destructive: user's changes are preserved, can be popped after).
# Auto-commit (the historical anti-pattern AUTO_COMMIT_WITHOUT_REQUEST) is FORBIDDEN.
#
# FND-1b (forensic 2026-06-15): the auto-stash RESTORE used
# `git stash drop "$STASH_REF"` where STASH_REF is a raw commit SHA (captured by FND-1 for
# index-stability). But `git stash drop <sha>` ERRORS ("'<sha>' is not a stash reference") —
# drop ONLY accepts a stash@{n} ref. The `|| ...` swallowed the failure, so EVERY auto-stash
# leaked (298 accumulated in prod), and the lingering entries made the repo-wide LIFO stack a
# minefield for the next concurrent stash/restore. This resolver keeps FND-1's SHA stability
# (immune to a parallel `git stash` shifting numeric indices) by resolving the stable SHA to
# its CURRENT stash@{n} index AT DROP TIME, then dropping that index.
# CAUTION (codex CODEX-004): returns 1 on not-found/empty-arg; this script runs `set -e`, so ALWAYS
# call it `||`-guarded (every current call site is) — a bare `_drop_stash_by_sha "$x"` would abort.
_drop_stash_by_sha() {
  local _sha="$1" _i=0 _ref
  [ -n "$_sha" ] || return 1
  while _ref=$(git -C "$REPO_ROOT" rev-parse "stash@{$_i}" 2>/dev/null); do
    if [ "$_ref" = "$_sha" ]; then
      git -C "$REPO_ROOT" stash drop "stash@{$_i}" >/dev/null 2>&1
      return $?
    fi
    _i=$((_i + 1)); [ "$_i" -gt 1000 ] && break
  done
  return 1
}

# H4-12 (PLAN_2026-07-02_orchestrator-hardening-4): a stash push/apply round-trip can RESURRECT a
# hook-GC'd marker file. Ground truth: a GAUNTLET_SKIPPED_<sid> marker was resurrected by another session's FND-2
# auto-stash restore (mtime proved it was the restored copy) — the marker existed on disk when
# stash push captured main's WIP snapshot, was legitimately GC'd (rm -f) by another process in the
# window before this merge-back's stash APPLY ran, and the apply recreated the stale file. Excluding
# these globs from `stash push` itself is NOT safe (git hard-fails a `stash push` pathspec exclusion
# for a file that doesn't currently exist — the common case — which would break the stash mechanism
# entirely; tested and confirmed). Instead, re-run marker GC AFTER every restore: for each marker
# glob, if ALL THREE gauntlet artifacts for its SID are present (the artifact-presence condition
# check-review-artifact.sh itself uses to legitimately clear these markers on clean completion), the
# restored copy is provably stale — remove it. NEVER removes a marker whose SID's gauntlet is
# genuinely still incomplete.
_gc_stale_gauntlet_markers() {
  local _root="${1:-$REPO_ROOT}" _f _sid _base _d
  [ -d "$_root" ] || return 0
  _gc_have() {  # <prefix> <sid> -> 0 if present in canonical dir or repo root (mirrors _gate_have)
    for _d in "$_root/.v/artifacts" "$_root"; do
      [ -f "$_d/${1}_${2}.md" ] && return 0
    done
    return 1
  }
  for _f in "$_root"/GAUNTLET_SKIPPED_*.md "$_root"/ABANDON_SUSPECT_*.md \
            "$_root"/SESSION_LOG_MISSING_*.md "$_root"/SESSION_LOG_FAILED_*.md "$_root"/SESSION_LOG_PENDING_*.md; do
    [ -f "$_f" ] || continue
    _base=$(basename "$_f")
    _sid=$(printf '%s' "$_base" | sed -E 's/^(GAUNTLET_SKIPPED|ABANDON_SUSPECT|SESSION_LOG_MISSING|SESSION_LOG_FAILED|SESSION_LOG_PENDING)_//; s/\.md$//')
    [ -n "$_sid" ] || continue
    if _gc_have PRE_FLIGHT_REPORT "$_sid" && _gc_have AGENT_REVIEW "$_sid" && _gc_have VERIFY_DONE_REPORT "$_sid"; then
      rm -f "$_f" 2>/dev/null && echo "INFO: H4-12 — removed stale resurrected marker $_base (SID ${_sid}'s gauntlet is provably complete)" >&2
    fi
  done
}
STASH_REF=""
# Shared exclusion: paths that are never "source WIP" (docs, gate artifacts, the session lock,
# /v's own transient trees). Defined ONCE so the FND-3 defer-detection below and the FND-2
# stashed-files witness further down use the SAME rule — no drift between detect and witness.
# B-1 (forensic 2026-06-15): the trailing (\.invalid)? lets P2's session-log QUARANTINE artifacts
# (validate-log-failing canonical logs renamed `<x>.yaml` → `<x>.yaml.invalid`) stay EXCLUDED. Without
# it the `.invalid` suffix defeats the `\.(ext)$` anchor, so a quarantined log persisting untracked in
# main's tree counts as "foreign source WIP" and inflates FND-3 deferral + the FND-2 witness on EVERY
# future merge-back (observed in wild sessions — the orchestrator named "a stale
# .invalid log" among the WIP it deferred on). The artifact PREFIX is still required, so no real source
# file gains the tolerance.
# W71-F8 (forensic 2026-07-02): one fleet's deferral markers listed the
# orchestrator's OWN exhaust as "foreign source WIP" — OP_TELEMETRY_*.json,
# GAUNTLET_SKIPPED_*.md, .claude/agent-memory/** (QA-reviewer memory writes), and
# bootstrap/ssr/ssr-manifest.json (a build artifact the gates themselves
# regenerate). None of these are ever a sibling's source work; counting them
# inflates the FND-3 defer condition with files that never clear on their own.
# FND3-EXCL (forensic 2026-07-03): the Jul-3 fleet stranded 4 gauntleted fixes
# because PRE_FLIGHT_ADDENDUM_*.md
# slipped this list — enumeration-by-name drifts every time a hook grows a new artifact
# type. Two-part class fix: (a) PRE_FLIGHT_REPORT widened to the PRE_FLIGHT_ prefix and
# the other observed-in-the-wild prefixes added (TRIVIAL_PASS, PLANNING_PASS,
# STOP_REARM_ESCAPE, DISPATCH_PROVENANCE, MERGE_ALL_REPORT, BITE_LEDGER); (b) a GENERIC
# final alternative excludes ANY SCREAMING_SNAKE-prefixed file whose suffix is a FULL
# session UUID (8-4-4-4-12 hex) with a doc extension — the fleet's artifact naming
# convention (${CLAUDE_SESSION_ID}) — so a FUTURE artifact type is excluded by shape,
# not by being remembered here. Adversarial review F1-1 (2026-07-03): the suffix MUST be
# a full UUID — a bare hex8/timestamp suffix also matched ordinary real files
# (INVOICE_12345678.md, CHANGELOG_20260703.md, AWS_CREDENTIALS_a1b2c3d4.json), silently
# swallowing genuine sibling WIP. Short-8/timestamp-suffixed artifacts are covered by the
# enumerated prefixes, never by the generic rule. Source code can never match either
# alternative (extension allowlist has no code extensions).
# Trailing tolerance also gains \.stale\.<pid> (observed: PRE_FLIGHT_REPORT…md.stale.67109).
# Interval syntax ({8}) validated against this host's BSD grep 2.6.0-FreeBSD -E.
# Bite-test: v-fnd-exclude-parity-test.sh (red vs .pre-fnd3exclude-bak).
_FND_EXCLUDE_RE='^\.v/|^\.worktrees/|\.claude-session-lock$|^\.claude/agent-memory/|^bootstrap/ssr/ssr-manifest\.json$|(^|/)(SESSION_LOG_|PRE_FLIGHT_|VERIFY_DONE_REPORT|AGENT_REVIEW|IMPACT_MAP|QA_REPORT|UX_CRITIQUE|WORKFLOW_VERIFICATION|IMPLEMENTATION_REPORT|WORKTREE_HANDOFF|HANDOFF|CYCLE_CAP_HANDOFF|BLOCKED|MAIN_WIP_STASHED|MERGE_DEFERRED|AUDIT_REPORT|REVIEW_REPORT|BUG_HUNT_REPORT|EDGE_HUNT_REPORT|GAUNTLET_REPORT|GAUNTLET_SKIPPED|OP_TELEMETRY_|ASYNC_LIFECYCLE_TRACE|WORKFLOW_BLAST_RADIUS|SUCCESS_CRITERIA|QA_REMEDIATION|DISPATCH_LEDGER|DISPATCH_PROVENANCE|ABANDON_SUSPECT|TRIVIAL_PASS|PLANNING_PASS|STOP_REARM_ESCAPE|MERGE_ALL_REPORT|BITE_LEDGER)[^/]*\.(md|ya?ml|jsonl?|log|txt)(\.invalid|\.stale\.[0-9]+)?$|(^|/)[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[^/]*\.(md|ya?ml|jsonl?|log|txt)(\.invalid|\.stale\.[0-9]+)?$'
# MED-1 (codex 2026-06-15): capture full porcelain ONCE, WITHOUT a `| head -1` pipe. Under
# `set -euo pipefail`, `git status --porcelain | head -1` SIGPIPE-aborts git (rc 141) when main
# carries thousands of dirty paths (head closes the read end before git finishes writing past the
# pipe buffer) — killing the merge-back before this logic runs, with no `141)` arm downstream.
# Derive the dirty-flag by string slice, and reuse the SAME snapshot for the FND-3 scan below.
MAIN_STATUS=$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)
MAIN_DIRTY=${MAIN_STATUS%%$'\n'*}
if [ -n "$MAIN_DIRTY" ]; then
  # ── FND-3 (forensic 2026-06-15): PREVENT the orphaned-work data-loss class (not just witness it) ──
  # A worktree session NEVER edits main's working tree (its work lives in the worktree), so any
  # uncommitted SOURCE file on main here is FOREIGN — typically a concurrent no-isolation sibling
  # editing shared main directly (the SKILL.md:329 / H-7 anti-pattern). FND-2 (below) makes a
  # stash-over recoverable+loud; FND-3 PREVENTS the orphan outright when a sibling is provably
  # active: rather than stash the sibling's WIP across our merge (where wave churn can orphan it),
  # we DEFER our own merge (exit 3, retryable) and leave the sibling's WIP UNTOUCHED on main.
  #
  # SOLO-USER GUARD (UX-FND-4): if NO other /v session is active, dirty main is the user's OWN WIP
  # → we must NOT defer (that would break the transparent auto-stash). v-active-siblings.sh prints
  # empty ⇒ no active worktree sibling ⇒ fall straight through to the auto-stash, exactly as before.
  # (Residual: a LONE no-isolation sibling registers no worktree lock, so it's invisible here; that
  # narrow case is still caught loud+recoverable by the FND-2 witness below. Full coverage would
  # need no-isolation sessions to take a lock — SKILL.md:787 already mandates worktrees to avoid it.)
  _FOREIGN_SRC_WIP=$(printf '%s\n' "$MAIN_STATUS" \
      | sed -e 's/^...//' -e 's/.* -> //' \
      | grep -vE "$_FND_EXCLUDE_RE" || true)
  if [ -n "$_FOREIGN_SRC_WIP" ]; then
    _ACTIVE_SIBS=$(bash "$_SCRIPT_DIR/v-active-siblings.sh" "$REPO_ROOT" "$SESSION_ID" 2>/dev/null || true)
    # ── FND3-ORPHAN escape (forensic 2026-07-04, Jul-4 fleet standoff) ──────────────────────────
    # The defer below existed to protect a LIVE sibling's main WIP. But worktree siblings NEVER
    # edit main's tree (this file's own doctrine, line ~958) — the Jul-4 fleet deferred 7 gauntleted
    # branches for a full day on WIP owned by a session DEAD for 27 hours, because the
    # gate counted "any live worktree sibling" instead of asking WHO OWNS THE WIP. Attribute each
    # foreign path via the per-session write-ledgers (<git-common-dir>/claude-session-writes-*.txt):
    #   • ANY path claimed by a session that is ALIVE (active-sibling list or SID liveness) → defer
    #     exactly as before (their WIP really is at risk).
    #   • ALL paths claimed only by DEAD sessions, or unclaimed (= the user's own work — the same
    #     UX-FND-4 solo semantics as the no-siblings branch) → do NOT defer forever on a ghost:
    #     fall through to the EXISTING FND-2 transparent auto-stash (recoverable + loud, stash-SHA
    #     witness) and leave a durable FND3_ORPHAN_ESCAPE receipt naming the dead owner(s).
    # Fail-safe: if the ledger dir is unreadable, treat as live-claimed (defer — old behavior).
    # Bite: v-merge-back-fnd3-orphan-escape-test.sh (red vs .pre-orphan0704-bak).
    _FND3_LIVE_CLAIM=""; _FND3_ATTRIB=""
    if [ -n "$_ACTIVE_SIBS" ]; then
      command -v _lock_sid_alive >/dev/null 2>&1 || { _slp="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"; [ -f "$_slp" ] && . "$_slp" 2>/dev/null || true; }
      _gcd_f3="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
      case "$_gcd_f3" in /*) ;; ?*) _gcd_f3="$REPO_ROOT/$_gcd_f3" ;; *) _gcd_f3="" ;; esac
      if [ -n "$_gcd_f3" ] && [ -d "$_gcd_f3" ]; then
        while IFS= read -r _wf; do
          [ -n "$_wf" ] || continue
          _wf_owner=""
          for _lg in "$_gcd_f3"/claude-session-writes-*.txt; do
            [ -f "$_lg" ] || continue
            grep -qF -- "$_wf" "$_lg" 2>/dev/null || continue
            _lsid="$(basename "$_lg" | sed -E 's/^claude-session-writes-(.*)\.txt$/\1/')"
            [ "$_lsid" = "$SESSION_ID" ] && continue
            _wf_owner="$_lsid"
            if printf '%s\n' "$_ACTIVE_SIBS" | grep -qF -- "$_lsid" \
               || { command -v _lock_sid_alive >/dev/null 2>&1 && _lock_sid_alive "$_lsid"; }; then
              _FND3_LIVE_CLAIM="$_wf (live owner: $_lsid)"
              break 2
            fi
          done
          _FND3_ATTRIB="${_FND3_ATTRIB}${_wf} -> ${_wf_owner:-unclaimed (user-own per UX-FND-4)}"$'\n'
        done <<< "$_FOREIGN_SRC_WIP"
      else
        _FND3_LIVE_CLAIM="write-ledger dir unavailable (fail-safe: treat as live-claimed)"
      fi
      if [ -z "$_FND3_LIVE_CLAIM" ]; then
        _OE="$REPO_ROOT/.v/artifacts/FND3_ORPHAN_ESCAPE_${SESSION_ID}.md"
        mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null || true
        {
          echo "# FND3-ORPHAN escape — foreign main WIP owned by NO LIVE session; auto-stash path taken"
          echo
          echo "merging_sid: $SESSION_ID"
          echo "active_worktree_siblings_present: yes (none of them claims this WIP; worktree sessions never edit main)"
          echo
          echo "## Attribution (write-ledger evidence — dead or unclaimed owners only):"
          printf '%s' "$_FND3_ATTRIB" | sed 's/^/- /'
          echo
          echo "The WIP was NOT discarded: the FND-2 transparent auto-stash below captures it with a"
          echo "SHA-stable stash witness (main-wip-stashed-${SESSION_ID}.md). Recover any of it from"
          echo "that stash SHA. Forensic 2026-07-04: the Jul-4 fleet stranded 7 gauntleted branches"
          echo "for a day deferring on a 27h-dead session's WIP."
        } > "$_OE" 2>/dev/null || true
        echo "INFO: FND3-ORPHAN escape — main's foreign WIP is owned by no live session (receipt: $_OE); proceeding via the FND-2 recoverable auto-stash instead of deferring on a ghost" >&2
      fi
    fi
    if [ -n "$_ACTIVE_SIBS" ] && [ -n "$_FND3_LIVE_CLAIM" ]; then
      _DW="$REPO_ROOT/.v/tmp/merge-deferred-${SESSION_ID}.md"
      mkdir -p "$REPO_ROOT/.v/tmp" 2>/dev/null || true
      {
        echo "# FND-3: merge-back DEFERRED — foreign uncommitted source WIP on main + active sibling(s)"
        echo
        echo "deferred_sid:    $SESSION_ID"
        echo "worktree_path:   $WORKTREE_PATH"
        echo "worktree_branch: $WORKTREE_BRANCH"
        echo "merge_target:    $MAIN_BRANCH"
        echo
        echo "## Active sibling session(s) (their work may BE the uncommitted WIP on main):"
        printf '%s\n' "$_ACTIVE_SIBS" | sed 's/^/- /'
        echo
        echo "## Foreign uncommitted SOURCE files on main (left UNTOUCHED — NOT stashed):"
        printf '%s\n' "$_FOREIGN_SRC_WIP" | sed 's/^/- /'
        echo
        echo "Why deferred: stashing a concurrent no-isolation sibling's uncommitted main WIP across"
        echo "this merge is exactly where that work gets orphaned under wave churn."
        echo "We leave it in place and retry instead of stashing over it."
        echo
        echo "## To resolve (pick one — the worktree is INTACT; its branch WAS rebased onto main (SHAs rewritten), nothing was merged or stashed):"
        echo "  - WAIT for the sibling(s) above to finish, then re-run: bash $0 $SESSION_ID $WORKTREE_PATH"
        echo "  - If the WIP is YOUR OWN work: commit or stash it on main, then re-run the merge-back."
        echo
        echo "Forensic 2026-06-15 (FND-3 prevention atop FND-1b/FND-2 detection+recovery)."
      } > "$_DW" 2>/dev/null || true
      # RC-4a (forensic 2026-06-26): `exit 3` below returns BEFORE the DUC consolidate sweep (~1011), so without
      # this the marker lives ONLY in the sweepable .v/tmp — a concurrent sibling's teardown / `git clean` can
      # delete it before the 6h integrity sweep, and FIX-B's `.v/artifacts/merge-deferred-*.md` arm would never
      # match a real file. Mirror the commit-witness durability copy (994-998): also write the durable .v/artifacts
      # copy so the deferred session stays sweep-discoverable (MISSING-telemetry) under concurrency.
      if mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null; then
        cp -p "$_DW" "$REPO_ROOT/.v/artifacts/merge-deferred-${SESSION_ID}.md" 2>/dev/null || true
      fi
      # F-3 (forensic 2026-07-03): the rebase above REWRITES the branch SHAs, and this defer
      # returns before the success-path witness writer (~1150) — so an existing commits-<sid>.txt still
      # cites the PRE-rebase (now-orphaned) commits, and any log/attribution keyed on it points at
      # dangling objects. Refresh the witness to the post-rebase branch range (SID-scoped: it is this
      # session's own branch) in BOTH the .v/tmp working copy and the durable .v/artifacts mirror.
      # Only when one already exists — deferring must not fabricate a witness for a witness-less session.
      for _wc in "$V_TMP_DIR/commits-${SESSION_ID}.txt" "$REPO_ROOT/.v/artifacts/commits-${SESSION_ID}.txt"; do
        [ -f "$_wc" ] || continue
        git -C "$REPO_ROOT" rev-list "${MAIN_BRANCH}..${WORKTREE_BRANCH}" > "$_wc" 2>/dev/null \
          && echo "INFO: refreshed post-rebase commit witness -> $_wc" >&2 || true
      done
      cat >&2 <<DEFERMSG

══════════════════════════════════════════════════════════════════════
⏸  MERGE-BACK DEFERRED (retryable, exit 3) — this is NOT a failure.
   main carries a concurrent sibling's uncommitted SOURCE WIP and a /v
   sibling session is still active. Stashing it across this merge risks
   orphaning the sibling's work. The worktree is INTACT;
   NOTHING was stashed or merged.
   ▸ Do NOT fall back to a manual git merge. Do NOT discard the foreign WIP.
   ▸ Wait for the sibling to finish (poll v-active-siblings.sh / the
     dependency-recover loop), then re-run:
        bash $0 $SESSION_ID $WORKTREE_PATH
   ▸ OR stop cleanly NOW (do NOT loop the merge): write HANDOFF_${SESSION_ID}.md with the line
        MERGE_DEFERRED: ${WORKTREE_BRANCH}
     to declare the deferral and satisfy the W5F-3 Stop gate. NEVER hand-write a PASS or a manual merge.
   Detail: $_DW
══════════════════════════════════════════════════════════════════════
DEFERMSG
      exit 3
    fi
  fi
  echo "INFO: main has uncommitted changes — stashing transparently before checkout (W22 / UX-FND-4)" >&2
  if git -C "$REPO_ROOT" stash push --include-untracked --message "v-merge-back auto-stash for SID=$SESSION_ID" 2>&1 | tee -a "$RESOLVE_LOG" | grep -q "Saved working directory"; then
    # FND-1: capture stash by SHA, not by numeric ref. Numeric refs (stash@{0}) shift
    # if another stash is pushed in parallel (from another terminal, hook, or tool).
    # SHA is stable for the lifetime of the stash entry.
    STASH_SHA=$(git -C "$REPO_ROOT" rev-parse stash@\{0\} 2>/dev/null)
    STASH_REF="$STASH_SHA"
    echo "INFO: stashed main's WIP at $STASH_REF (sha-stable, not stash@{0} numeric ref)" >&2
    # FND-2 (forensic 2026-06-15, an observed wave data loss): a worktree session's merge NEVER
    # edits main's working tree (its work lives in the worktree), so any file in this auto-stash is
    # FOREIGN — a concurrent no-isolation sibling editing shared main directly without a worktree/
    # inline-main-lock (the SKILL.md:329 / H-7 anti-pattern). Stashing it across the merge is where
    # that sibling's uncommitted work can get orphaned under wave churn (it was: one session's fix
    # survived this merge's restore but was orphaned by later parallel churn, sitting only in the
    # stash while the session reported success). We do NOT block (UX-FND-4 keeps the auto-stash for
    # the solo-user case), but we record a DURABLE, loud witness — stash SHA + foreign files — so
    # orphaned sibling work is always recoverable+attributable, never silent. Full prevention (block
    # no-isolation main edits during a wave) is a separate hook-level change. Witness lives in .v/tmp
    # (gitignored — no commit-risk); the WARN gives the loudness.
    #   - TRACKED foreign changes:   diff ^1..W  (^1=base HEAD, W=worktree state ⇒ staged+unstaged).
    #   - UNTRACKED foreign files:   ls-tree ^3  (the --include-untracked parent; absent ⇒ empty).
    #     Both matter: that loss was a MODIFIED .php (tracked) PLUS a NEW test file (untracked)
    #     — a tracked-only scan (codex CODEX-001) would have missed the new file.
    #   - Exclusion is EXTENSION-anchored to doc types so a real source file like `monthly_REPORT.php`
    #     is never wrongly dropped (codex CODEX-002 — the old `.*_REPORT` was over-broad).
    _STASHED_FILES=$( {
        git -C "$REPO_ROOT" diff --name-only "${STASH_REF}^1" "$STASH_REF" 2>/dev/null
        git -C "$REPO_ROOT" ls-tree -r --name-only "${STASH_REF}^3" 2>/dev/null
      } | sort -u | grep -vE "$_FND_EXCLUDE_RE" || true)
    if [ -n "$_STASHED_FILES" ]; then
      _FW="$REPO_ROOT/.v/tmp/main-wip-stashed-${SESSION_ID}.md"
      mkdir -p "$REPO_ROOT/.v/tmp" 2>/dev/null || true
      {
        echo "# FND-2: foreign uncommitted WIP on main was auto-stashed during this merge-back"
        echo
        echo "merging_sid: $SESSION_ID"
        echo "stash_sha:   $STASH_REF   # SHA-stable; recover: git -C $REPO_ROOT stash apply $STASH_REF"
        echo
        echo "## Files captured (a concurrent no-isolation sibling's work on shared main — tracked + untracked):"
        printf '%s\n' "$_STASHED_FILES" | sed 's/^/- /'
        echo
        echo "Restored after the ff-merge; if later parallel churn orphaned them they remain"
        echo "recoverable from stash_sha above. Root: sibling edited main without a worktree/"
        echo "inline-main-lock (SKILL.md:329 / H-7). Forensic 2026-06-15."
      } > "$_FW" 2>/dev/null || true
      # CODEX-003: this script runs `set -euo pipefail`; a `tee` failure here would otherwise abort
      # the merge BEFORE the stash restore (orphaning the WIP this very block exists to surface).
      # The `|| true` keeps this diagnostic strictly non-blocking.
      echo "WARN: FND-2 — foreign WIP on main auto-stashed (concurrent no-isolation sibling); durable recoverable witness: $_FW" | tee -a "$RESOLVE_LOG" >&2 || true
    fi
  else
    # Stash failed (e.g., already conflicted, or .gitignore issue). Write handoff and bail.
    HANDOFF_FILE="$REPO_ROOT/.v/artifacts/WORKTREE_HANDOFF_$SESSION_ID.md"; mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null || HANDOFF_FILE="$REPO_ROOT/WORKTREE_HANDOFF_$SESSION_ID.md"
    cat > "$HANDOFF_FILE" <<HANDOFF_EOF
Model: orchestrator
SID: $SESSION_ID

## Worktree Handoff — main has uncommitted WIP, stash failed

worktree_path: $WORKTREE_PATH
worktree_branch: $WORKTREE_BRANCH
merge_target: $MAIN_BRANCH
reason: main directory has uncommitted changes; auto-stash failed.

## Recovery Steps

The autonomous merge-back refused to auto-commit your WIP (UX-FND-4 — would lose
explicit consent). To complete the merge:

1. cd $REPO_ROOT
2. Inspect: git status
3. Either commit (\`git add . && git commit\`), stash (\`git stash push -u\`), or discard (\`git checkout .\`).
4. Re-run: bash $0 $SESSION_ID $WORKTREE_PATH

Handoff Status: BLOCKED
HANDOFF_EOF
    echo "ERROR: main is dirty AND stash failed; refusing to auto-commit your WIP (UX-FND-4)" >&2
    echo "ERROR: handoff written to $HANDOFF_FILE" >&2
    exit 1
  fi
fi

if [ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]; then
  if ! git checkout "$MAIN_BRANCH" 2>/dev/null; then
    echo "ERROR: could not switch to $MAIN_BRANCH (currently on $CURRENT_BRANCH)" >&2
    # Restore stash if we made one, before exiting
    # FND-1: restore via apply+drop using SHA, not numeric ref
    if [ -n "$STASH_REF" ]; then
      git -C "$REPO_ROOT" stash apply "$STASH_REF" 2>/dev/null && \
        { _drop_stash_by_sha "$STASH_REF"; _gc_stale_gauntlet_markers "$REPO_ROOT"; } || \
        echo "WARN: could not auto-restore stash $STASH_REF; recover with: git stash apply $STASH_REF" >&2
    fi
    exit 1
  fi
fi

if ! git merge --ff-only "$WORKTREE_BRANCH"; then
  echo "ERROR: ff-only merge failed despite successful rebase. Manual investigation needed." >&2
  if [ -n "$STASH_REF" ]; then
    git -C "$REPO_ROOT" stash apply "$STASH_REF" 2>/dev/null && \
      { _drop_stash_by_sha "$STASH_REF"; _gc_stale_gauntlet_markers "$REPO_ROOT"; } || \
      echo "WARN: could not auto-restore stash $STASH_REF; recover with: git stash apply $STASH_REF" >&2
  fi
  exit 1
fi

# Restore main's WIP if we stashed
if [ -n "$STASH_REF" ]; then
  echo "INFO: restoring main's WIP from $STASH_REF (apply+drop, SHA-stable)" >&2
  echo "=== STASH RESTORE ===" >> "$RESOLVE_LOG"
  if git -C "$REPO_ROOT" stash apply "$STASH_REF" 2>&1 | tee -a "$RESOLVE_LOG"; then
    _drop_stash_by_sha "$STASH_REF" || echo "WARN: applied main's WIP but could not drop stash $STASH_REF (leak); inspect: git stash list" >&2
    _gc_stale_gauntlet_markers "$REPO_ROOT"   # H4-12: remove any resurrected-but-stale gauntlet marker
  else
    echo "WARN: stash apply produced conflicts — your WIP is at SHA $STASH_REF" >&2
    echo "WARN: recover with: git stash apply $STASH_REF; (resolve conflicts); git stash drop $STASH_REF" >&2
    # Don't drop — keep the stash intact for the user to recover. Don't exit 1 —
    # the merge succeeded; only restoration is partial.
  fi
fi

# W-attr: persist a durable SID-scoped commit witness BEFORE deleting the build branch, so a later
# /v-session-log attributes EXACTLY this session's commits — immune to concurrent siblings on the
# shared main HEAD and surviving this branch's deletion below. MAIN_HEAD_BEFORE..HEAD is precisely
# the commits this ff-merge added (the merge lock serialized us, so no sibling commit landed in
# between). This is the ground truth validate-log.py's _check_sid_commit_witness reads to reject the
# sibling-leakage class (a prod session logged commits_added=4 listing 3 commits from a concurrent
# one observed session). Best-effort: never fail the merge over witness bookkeeping (|| true).
if [ -n "${V_TMP_DIR:-}" ] && [ -n "${MAIN_HEAD_BEFORE:-}" ]; then
  _MERGED_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$_MERGED_HEAD" ] && [ "$MAIN_HEAD_BEFORE" != "$_MERGED_HEAD" ]; then
    mkdir -p "$V_TMP_DIR" 2>/dev/null || true
    if git -C "$REPO_ROOT" rev-list "${MAIN_HEAD_BEFORE}..${_MERGED_HEAD}" > "$V_TMP_DIR/commits-${SESSION_ID}.txt" 2>/dev/null; then
      # item-28 hygiene: `grep -c ... || echo 0` double-prints "0\n0" when the file has zero
      # matching lines (grep -c always prints a count, even 0, but still exits 1 on no-match,
      # which used to trigger the `|| echo 0` fallback too). Capture once, default via ${:-0}.
      _commit_witness_count=$(grep -c . "$V_TMP_DIR/commits-${SESSION_ID}.txt" 2>/dev/null)
      echo "INFO: wrote SID commit witness (${_commit_witness_count:-0} commit(s)) -> .v/tmp/commits-${SESSION_ID}.txt" >&2
      # CANARY-A-rest (DUC-003, forensic 2026-06-22): also write the witness to the DURABLE .v/artifacts store
      # (REPO_ROOT = MAIN root here). The .v/tmp copy is swept by a concurrent sibling before /v-session-log
      # reads it -> shared_head_fallback zeroes commits + uses the sibling-contaminated base..HEAD range.
      if mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null; then
        cp -p "$V_TMP_DIR/commits-${SESSION_ID}.txt" "$REPO_ROOT/.v/artifacts/commits-${SESSION_ID}.txt" 2>/dev/null || true
      fi
    fi
  fi
fi

# C-3/A-3 (forensic 2026-06-04): rescue session artifacts stranded in the WORKTREE before it
# is removed (H-5 merged to main with its gate artifacts lost with the worktree), and
# sweep legacy repo-root copies into .v/artifacts (H-6/H-7/H-10 stranded PRE_FLIGHT/AGENT_REVIEW
# at the root when the self-check's reconciliation never ran). Shares move semantics with
# v-completion-selfcheck.sh via the single-source script. Best-effort — never fails the merge.
# Subshell-cd: the consolidator resolves roots from CWD (we are already at $REPO_ROOT here,
# but make it explicit so a future re-order can't reintroduce the wrong-CWD consolidation).
( cd "$REPO_ROOT" && bash "$_SCRIPT_DIR/v-artifact-consolidate.sh" "$SESSION_ID" "$WORKTREE_PATH" "$WORKTREE_PATH/.v/artifacts" ) || true

# R4c (forensic 2026-06-20): reconcile the session's .v/tmp EVIDENCE into main BEFORE the prune
# destroys it. head-baseline-<sid>.txt (the pre-session HEAD, written by v-bootstrap.sh into the
# WORKTREE's .v/tmp) is otherwise never copied to main — so after prune the /v-session-log gather falls
# to merge_base_fallback → BASE_SHA==END_SHA → files_changed=[] → HIGH-5 hollow-log finalize BLOCK (the
# class that lost ~90% of worktree-session telemetry this wave). Also back-stop the commit witness in
# case the reconstruction above (~L971) didn't run. cp -p preserves mtime; copy ONLY when main lacks the
# file so we never clobber the authoritative post-rebase witness. Best-effort — never fail the merge.
if [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH/.v/tmp" ]; then
  mkdir -p "$REPO_ROOT/.v/tmp" "$REPO_ROOT/.v/artifacts" 2>/dev/null || true
  for _ev in "head-baseline-${SESSION_ID}.txt" "commits-${SESSION_ID}.txt" "session-start-${SESSION_ID}.txt"; do
    _ev_src="$WORKTREE_PATH/.v/tmp/$_ev"
    _ev_dst="$REPO_ROOT/.v/tmp/$_ev"
    if [ -s "$_ev_src" ] && [ ! -s "$_ev_dst" ]; then
      cp -p "$_ev_src" "$_ev_dst" 2>/dev/null \
        && echo "INFO: reconciled $_ev (worktree -> main .v/tmp) for the session-log gather" >&2 || true
    fi
    # DURABILITY (forensic 2026-06-23, DUC class): ALSO write the durable .v/artifacts copy so a later
    # `git clean` / concurrent-sibling teardown that sweeps .v/tmp does not strand the gather. session-start
    # grounds base_sha/start_time (one session logged base_sha:null after its .v/tmp was swept witness-less);
    # the gather now reads .v/artifacts as a fallback for all three markers. cp ONLY when the durable copy is
    # absent (never clobber an authoritative post-rebase copy); prefer the freshest source. Best-effort.
    _ev_dur="$REPO_ROOT/.v/artifacts/$_ev"
    if [ ! -s "$_ev_dur" ]; then
      for _ev_pick in "$_ev_src" "$_ev_dst"; do
        [ -s "$_ev_pick" ] && { cp -p "$_ev_pick" "$_ev_dur" 2>/dev/null \
          && echo "INFO: durable .v/artifacts copy of $_ev written (DUC sweep-survival)" >&2 || true; break; }
      done
    fi
  done
fi

# DURABILITY (forensic 2026-06-23, DUC class — merge-resolve member): the merge-resolve log lives ONLY in MAIN
# .v/tmp and is the gather's worktree.created=true evidence (+ validate-log.py R6g's safety-net signal). A later
# `git clean` / concurrent-sibling teardown that sweeps .v/tmp before /v-session-log runs would silently flip
# classification.worktree.created to false for a session that PROVABLY ran a worktree — with no quarantine
# (R6g's merge-resolve arm was also .v/tmp-only). Write the durable .v/artifacts copy; the gather (~L190) and
# R6g now read it as a fallback. Best-effort — never fail the merge.
if [ -s "$RESOLVE_LOG" ] && mkdir -p "$REPO_ROOT/.v/artifacts" 2>/dev/null; then
  cp -p "$RESOLVE_LOG" "$REPO_ROOT/.v/artifacts/$(basename "$RESOLVE_LOG")" 2>/dev/null \
    && echo "INFO: durable .v/artifacts copy of $(basename "$RESOLVE_LOG") written (DUC sweep-survival)" >&2 || true
fi

# Cleanup: remove worktree, delete branch.
# FIND-2 (forensic 2026-07-02): the ff-merge ABOVE has already LANDED by
# this point, so worktree teardown is pure cleanup and must NEVER invert the merge's success. A
# `git worktree remove` that fails "fatal: not a working tree" (rc=128 — observed when a concurrent
# sibling teardown/prune deregistered this worktree between the merge and here) used to abort the whole
# script under `set -euo pipefail` (L21), so the drain reported a LANDED feature as failed=1/NEEDS-MANUAL.
# Best-effort now: remove, then --force, then a repo prune (clears a deregistered/broken entry); never fail.
# SREV-001 (adversarial review 2026-07-02): `git worktree prune` only DEREGISTERS the entry from git's
# bookkeeping — it leaves the worktree's on-disk directory in place, and once deregistered that dir is
# invisible to the P6 `git worktree list`-based GC below, so it would leak permanently (the "723MB observed"
# class). By this point the pre-merge dirty-check + artifact-consolidation already ran, so nothing of value
# remains in the worktree → after a prune fallback, also `rm -rf` the dir (guarded against ""/repo-root).
git worktree remove "$WORKTREE_PATH" 2>/dev/null \
  || git worktree remove --force "$WORKTREE_PATH" 2>/dev/null \
  || { git -C "$REPO_ROOT" worktree prune 2>/dev/null; [ -n "$WORKTREE_PATH" ] && [ "$WORKTREE_PATH" != "$REPO_ROOT" ] && rm -rf "$WORKTREE_PATH" 2>/dev/null; } \
  || true
# SREV-002 (adversarial review 2026-07-02): the branch is provably already merged here, so a delete failure
# is inert clutter — but keep a diagnostic (was silently swallowed by `|| true`) so accumulating stale refs
# are visible. echo returns 0, so this stays best-effort under set -e.
git branch -d "$WORKTREE_BRANCH" 2>/dev/null || git branch -D "$WORKTREE_BRANCH" 2>/dev/null \
  || echo "WARN: could not delete merged branch '$WORKTREE_BRANCH' (best-effort; already merged into $MAIN_BRANCH — remove manually: git branch -D $WORKTREE_BRANCH)" >&2

# Final assertion: worktree gone. FIND-2: a worktree still listed here whose branch ALREADY landed
# (merge-base --is-ancestor main) is cleanup RESIDUE, not a merge failure — WARN and let the P6
# worktree-GC below reclaim it; do NOT `exit 1` (that would invert the successful merge, the exact
# success-inversion bug). Only a still-listed worktree whose branch did NOT land is a genuine error.
if git worktree list --porcelain 2>/dev/null | grep -q "$SESSION_ID"; then
  if git -C "$REPO_ROOT" merge-base --is-ancestor "$WORKTREE_BRANCH" "$MAIN_BRANCH" 2>/dev/null; then
    echo "WARN: worktree for SESSION_ID '$SESSION_ID' still listed after cleanup, but '$WORKTREE_BRANCH' is merged into $MAIN_BRANCH — leaving residue for worktree-GC, not failing the landed merge" >&2
  else
    echo "ERROR: worktree containing SESSION_ID '$SESSION_ID' still listed after cleanup" >&2
    exit 1
  fi
fi

echo "OK: merged $WORKTREE_BRANCH into $MAIN_BRANCH; worktree removed; branch deleted"

# P6 (fleet forensic 2026-06-20): opportunistically GC OTHER leaked worktrees whose work is SAFELY merged
# (branch is an ancestor of main = 0 commits ahead) AND whose session is done (no fresh .claude-session-lock).
# v-worktree-gc.sh is conservative — it NEVER removes an ahead-of-main (unmerged) or lock-active worktree —
# so this cannot orphan work. Best-effort + isolated in a subshell; it must never affect this merge's exit
# status. Fixes the cross-fleet worktree accumulation (723MB observed) left by sessions that merged but whose
# worktree-prune never ran. Opt out with V_NO_WORKTREE_GC=1.
if [ "${V_NO_WORKTREE_GC:-0}" != "1" ] && [ -f "$_SCRIPT_DIR/v-worktree-gc.sh" ]; then
  ( bash "$_SCRIPT_DIR/v-worktree-gc.sh" "$REPO_ROOT" --apply >/dev/null 2>&1 ) || true
fi

# W-conc-fix: if main advanced since this session forked, the merge integrated sibling
# work this session's gates never saw. Signal the orchestrator to re-verify the COMBINED
# main. (We do NOT run gates here — that would hold nothing useful and the worktree is
# already removed; the orchestrator re-runs pre-flight on main, off the merge lock.)
if [ -n "$MAIN_HEAD_BEFORE" ] && [ -n "$FORK_BASE" ] && [ "$MAIN_HEAD_BEFORE" != "$FORK_BASE" ]; then
  echo "MERGE_BACK_REVERIFY_REQUIRED=1"
  echo "MERGE_BACK_REVERIFY_REASON=main advanced from $FORK_BASE to $MAIN_HEAD_BEFORE since session forked; sibling work was integrated and this session's gates never ran against it"
  # H4-4a (PLAN_2026-07-02_orchestrator-hardening-4): explicit PRE-merge base for the re-verify diff.
  # Evidence: a gate summary used BASE_SHA_FOR_DIFF=post-merge HEAD (a 0-diff base against
  # itself), so every stack SKIPped and the run "passed" in 1s having verified nothing. FORK_BASE is
  # the SHA this branch actually forked from — HEAD..FORK_BASE covers BOTH the sibling work that
  # landed AND this session's own commits. The orchestrator MUST pass BASE_SHA=$FORK_BASE
  # (never $MAIN_HEAD_BEFORE, never the post-merge HEAD) to the re-verify gate run.
  echo "MERGE_BACK_REVERIFY_BASE_SHA=$FORK_BASE"
  echo "INFO: main advanced during this session — orchestrator MUST re-run pre-flight on the merged main before declaring done (combined-state verification), passing BASE_SHA=$FORK_BASE (never HEAD) and POSTMERGE_REVERIFY=1 to v-run-gates.sh so the summary lands in a -postmerge file and a blind re-run cannot masquerade as PASS." >&2
fi
exit 0
