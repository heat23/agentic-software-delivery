#!/usr/bin/env bash
# v-dependency-recover.sh <repo_root> <worktree_path> <branch> <fork_base|auto> <self_sid>
#
# THE optimistic-concurrency "detect + recover" step (HANDOFF 2026-05-25, rule 6).
#
# Context: every /v request runs in its OWN worktree off `main` and runs its own
# gates INSIDE that worktree. Request B can depend on request A's not-yet-merged
# code (B calls a function A just added). File overlap is only knowable post-hoc, so
# we do NOT predict dependencies up front — we DETECT them when B's gates fail while a
# sibling is in flight + main has advanced, then RECOVER by rebasing onto the updated
# main and retrying gates exactly once.
#
# Invoked ONLY from SKILL.md's Step 4 gate-FAIL branch, for worktree sessions. The
# caller has already observed that this session's pre-flight gates failed.
#
# TRIGGER (what makes recovery applicable):
#   - main HEAD advanced past this branch's FORK_BASE  (a sibling merged real work),
#     AND this session is in a worktree (branch != main).
#   If main did NOT advance, the gate failure is this session's OWN bug, not a stale
#   base / cross-session dependency → emit NOT_APPLICABLE so the caller runs its
#   normal "fix it, re-invoke, 3 attempts" loop.
#
# RECOVERY:
#   - If ≥1 sibling is STILL active (v-active-siblings.sh non-empty): bounded bash
#     poll loop (sleep DEP_POLL_INTERVAL, hard cap DEP_POLL_TIMEOUT) until all siblings
#     clear their locks / merge, OR timeout. Timeout → BLOCKED (bounded; no infinite
#     A-waits-B / B-waits-A deadlock — retry is once, with a cap).
#   - Once siblings are clear (or already clear), rebase this branch onto the updated
#     main. Clean rebase → RETRY_GATES (caller re-runs gates exactly ONCE). Rebase
#     conflict = real code/config overlap → abort + BLOCKED (escalate to handoff).
#
# Uses a bash until-loop, NOT ScheduleWakeup: ScheduleWakeup is a main-loop tool the
# forked /v runner cannot call.
#
# OUTPUT CONTRACT (last DEP_RECOVER= line is authoritative; DEP_RECOVER_REASON= gives detail):
#   DEP_RECOVER=NOT_APPLICABLE   → caller: normal fix loop (this is not a dependency case)
#   DEP_RECOVER=RETRY_GATES      → caller: re-run pre-flight ONCE; pass→continue, fail→BLOCKED
#   DEP_RECOVER=BLOCKED          → caller: write BLOCKED_<sid>.md, stop (do NOT merge-back)
#
# Exit codes: 0 = NOT_APPLICABLE or RETRY_GATES (caller proceeds per signal); 1 = BLOCKED;
#             2 = usage/config error.
#
# Tunables (env): DEP_POLL_INTERVAL (default 45s), DEP_POLL_TIMEOUT (default 540s / 9min).
# NOTE on the timeout cap: the orchestrator invokes this via the Bash tool, whose hard
# max timeout is 600s (10min). A single invocation therefore CANNOT poll longer than
# that, so the default cap is 540s (safely under it) and the caller MUST pass the Bash
# tool `timeout: 600000`. (The handoff's aspirational "~20min" is unreachable in one
# Bash call; 9min is plenty for a sibling merge to land in practice.)

set -u

REPO="${1:?usage: v-dependency-recover.sh <repo_root> <worktree_path> <branch> <fork_base|auto> <self_sid>}"
WORKTREE="${2:?worktree_path required}"
BRANCH="${3:?branch required}"
FORK_BASE_ARG="${4:-auto}"
SELF="${5:?self_sid required}"

POLL_INTERVAL="${DEP_POLL_INTERVAL:-45}"
POLL_TIMEOUT="${DEP_POLL_TIMEOUT:-540}"
# Floor the interval at 1s — a 0 (mis-set env) would spin the poll loop forever since
# WAITED would never advance toward POLL_TIMEOUT. Likewise floor the timeout: a blank or
# non-integer DEP_POLL_TIMEOUT would make the `-ge` check error to stderr + evaluate false,
# so the timeout would never fire and the loop would run until the outer Bash-tool cap.
[ "$POLL_INTERVAL" -ge 1 ] 2>/dev/null || POLL_INTERVAL=1
[ "$POLL_TIMEOUT" -ge 1 ] 2>/dev/null || POLL_TIMEOUT=540
SIB_HELPER="$(dirname "$0")/v-active-siblings.sh"

emit() { echo "DEP_RECOVER=$1"; [ -n "${2:-}" ] && echo "DEP_RECOVER_REASON=$2"; }

[ -d "$REPO/.git" ] || [ -e "$REPO/.git" ] || { echo "ERROR: $REPO is not a git repo root" >&2; exit 2; }
[ -d "$WORKTREE" ] || { echo "ERROR: worktree path '$WORKTREE' not a directory" >&2; exit 2; }

# Resolve main branch.
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if ! git -C "$REPO" rev-parse --verify "$MAIN_BRANCH" >/dev/null 2>&1; then
  for c in main master develop; do
    git -C "$REPO" rev-parse --verify "$c" >/dev/null 2>&1 && { MAIN_BRANCH="$c"; break; }
  done
fi

# A session working directly on main is not a worktree session → recovery N/A.
if [ "$BRANCH" = "$MAIN_BRANCH" ]; then
  emit NOT_APPLICABLE "session is on $MAIN_BRANCH (no worktree); dependency-recover only applies to worktree branches"
  exit 0
fi

MAIN_HEAD=$(git -C "$REPO" rev-parse "$MAIN_BRANCH" 2>/dev/null || echo "")
if [ "$FORK_BASE_ARG" = "auto" ] || [ -z "$FORK_BASE_ARG" ]; then
  FORK_BASE=$(git -C "$REPO" merge-base "$BRANCH" "$MAIN_BRANCH" 2>/dev/null || echo "")
else
  FORK_BASE="$FORK_BASE_ARG"
fi

_advanced() { [ -n "$MAIN_HEAD" ] && [ -n "$FORK_BASE" ] && [ "$MAIN_HEAD" != "$FORK_BASE" ]; }
_siblings() { [ -f "$SIB_HELPER" ] && bash "$SIB_HELPER" "$REPO" "$SELF" 2>/dev/null || true; }

# APPLICABILITY (the relaxation that makes the 2-session A→B case work): recovery applies
# if EITHER main already advanced past our fork point (a sibling merged real work) OR a
# sibling is still in flight (it may merge work we depend on — poll until it does). With
# exactly two dependent sessions, when A merges its lock clears AS main advances, so the
# strict "advanced AND sibling-active" conjunction never holds at one instant — the OR
# (poll-on-active, then re-check advanced) is what lets B wait for A and then recover.
SIBS=$(_siblings)
if ! _advanced && [ -z "$SIBS" ]; then
  emit NOT_APPLICABLE "main HEAD ($MAIN_HEAD) has not advanced past FORK_BASE ($FORK_BASE) and no sibling is active — gate failure is this session's own, not a cross-session dependency"
  exit 0
fi

echo "INFO: gates failed with $( _advanced && echo 'main advanced' || echo 'main not yet advanced'), sibling(s)=$([ -n "$SIBS" ] && echo active || echo none) — entering dependency detect-and-recover." >&2

# Poll for in-flight siblings to clear (bounded). If none active, skip straight to rebase.
WAITED=0
while [ -n "$SIBS" ]; do
  if [ "$WAITED" -ge "$POLL_TIMEOUT" ]; then
    echo "ERROR: dependency-recover poll timed out after ${WAITED}s with siblings still active:" >&2
    echo "$SIBS" >&2
    # Distinguish a real stuck dependency from two independent sessions that merely
    # happened to run concurrently. Re-check advancement: if main advanced, a dependency
    # DID merge but a sibling is wedged → BLOCKED. If main NEVER advanced, no dependency
    # materialized → this session's gate failure is its own, so fall through to its normal
    # fix loop (NOT_APPLICABLE) instead of a false BLOCKED. Prevents two independently-failing
    # concurrent sessions from each polling to timeout and both wrongly reporting BLOCKED.
    MAIN_HEAD=$(git -C "$REPO" rev-parse "$MAIN_BRANCH" 2>/dev/null || echo "$MAIN_HEAD")
    if _advanced; then
      emit BLOCKED "poll timeout (${POLL_TIMEOUT}s) — main advanced (a dependency merged) but sibling(s) never cleared; bounded, no A-waits-B deadlock"
      exit 1
    fi
    emit NOT_APPLICABLE "poll timeout (${POLL_TIMEOUT}s) and main never advanced past FORK_BASE — no cross-session dependency materialized; gate failure is this session's own (fall through to fix loop)"
    exit 0
  fi
  echo "INFO: ${WAITED}s — sibling(s) still active, waiting ${POLL_INTERVAL}s:" >&2
  echo "$SIBS" | sed 's/^/  /' >&2
  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
  SIBS=$(_siblings)
done

# Refresh main HEAD (a sibling likely merged while we polled) and re-check advancement.
MAIN_HEAD=$(git -C "$REPO" rev-parse "$MAIN_BRANCH" 2>/dev/null || echo "$MAIN_HEAD")
if ! _advanced; then
  emit NOT_APPLICABLE "sibling(s) cleared but main HEAD ($MAIN_HEAD) still at FORK_BASE ($FORK_BASE) — no dependency merged; gate failure is this session's own"
  exit 0
fi

# Make the branch rebasable. At gate-fail time the worktree's session work is typically
# UNCOMMITTED (in /v, worktree commits happen at merge-back, AFTER gates), and `git rebase`
# refuses on unstaged changes to TRACKED files. We must NOT use `git stash`/`--autostash`
# (the worktree workflow bans stash — it's a repo-wide LIFO stack, unsafe with parallel
# sessions). Instead checkpoint-commit the session work onto this build branch (sanctioned
# by CLAUDE.md for worktree/V_DEPTH≥1 sessions; the branch merges to main anyway), NEVER
# staging the untracked .claude-session-lock.
if [ -n "$(git -C "$WORKTREE" status --porcelain 2>/dev/null | grep -vE '^\?\? \.claude-session-lock$')" ]; then
  echo "INFO: worktree has uncommitted session work — checkpoint-committing before rebase (lock excluded)." >&2
  git -C "$WORKTREE" add -A -- . ':(exclude).claude-session-lock' >/dev/null 2>&1 || true
  # Commit runs project hooks normally (no --no-verify — CLAUDE.md forbids skipping hooks
  # unless the user asks). If a pre-commit hook rejects it, that surfaces as an honest
  # BLOCKED rather than a silently bypassed gate.
  if ! git -C "$WORKTREE" commit -q -m "v-dependency-recover: checkpoint session work before rebase onto $MAIN_BRANCH" >/dev/null 2>&1; then
    emit BLOCKED "worktree has uncommitted changes that could not be checkpoint-committed (nothing stageable, or a commit hook rejected it) — resolve manually then retry"
    exit 1
  fi
fi

echo "INFO: no active siblings remain and main advanced — rebasing $BRANCH onto updated $MAIN_BRANCH @ $MAIN_HEAD." >&2

# Rebase the worktree branch onto the updated main so gates re-run against COMBINED state.
REBASE_RC=0
GIT_EDITOR=true git -C "$WORKTREE" rebase "$MAIN_BRANCH" >/dev/null 2>&1 || REBASE_RC=$?
if [ "$REBASE_RC" -ne 0 ]; then
  CONFLICTS=$(git -C "$WORKTREE" diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')
  git -C "$WORKTREE" rebase --abort >/dev/null 2>&1 || true
  if [ -n "$CONFLICTS" ]; then
    emit BLOCKED "rebase onto $MAIN_BRANCH conflicts (code/config overlap with sibling: $CONFLICTS) — escalate to WORKTREE_HANDOFF, do not silently pick a side"
  else
    emit BLOCKED "rebase onto $MAIN_BRANCH failed (rc=$REBASE_RC, no conflict files) — worktree state unexpected; resolve manually then retry"
  fi
  exit 1
fi

emit RETRY_GATES "rebased $BRANCH onto $MAIN_BRANCH @ $MAIN_HEAD; re-run pre-flight ONCE against the combined state"
exit 0
