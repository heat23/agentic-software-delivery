#!/usr/bin/env bash
# uncommitted-changes-gate-test.sh
# Regression harness for uncommitted-changes-gate.sh.
#
# Focus: W-attr-gate (Residual #1) — the LEGACY (no-writes-log-witness) fallback
# must NOT attribute a SHARED working tree's dirty files to this session.
# Parallel /v sessions share the primary `main` checkout, so a shared-tree
# `git status` diff (or the no-baseline "all dirty" fallback) swallows a
# concurrent sibling's edits and false-blocks THIS session into committing files
# it never touched. The fix degrades safe on the shared primary tree while
# preserving the block on session-PRIVATE trees (worktree / feature branch) and
# leaving the writes-log path completely untouched.
#
# These cases invoke the REAL hook end-to-end inside throwaway git repos, with
# the session id pinned via stdin JSON (resolve-sid.sh priority 0) so the harness
# is immune to the operator's real session env / runtime-id file.
#
# Expected: on the PRE-fix gate -> T1 + T6 FAIL (the bug); post-fix -> all PASS.

# V_UNCOMMITTED_GATE_OVERRIDE (mutation-gate seam, audit 2026-06-18): the gate injects a mutant copy
# of uncommitted-changes-gate.sh here. HOOKS_LIB_DIR is exported below to the real lib dir so the
# relocated copy still loads its libs (resolve-sid is sourced from $HOME, which stays real). Default
# (unset) → live gate, zero behavior change.
GATE="${V_UNCOMMITTED_GATE_OVERRIDE:-$HOME/.claude/hooks/uncommitted-changes-gate.sh}"
export HOOKS_LIB_DIR="$HOME/.claude/hooks/lib"
TEST_UUID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"   # valid UUID4 shape; never a real session
DEFAULT_MSG="All done and tests pass; feature complete."

PASS=0
FAIL=0
LAST_RC=""
LAST_ERR=""

# ── setup helpers (run with cwd = throwaway repo) ───────────────────────────
_dirty_php() {            # commit app.php, then leave an unstaged modification
  printf 'v1\n' > app.php
  git add app.php >/dev/null 2>&1
  git -c commit.gpgsign=false commit -q -m add-app >/dev/null 2>&1
  printf 'v2\n' >> app.php
}
_setup_main_dirty()         { _dirty_php; }
_setup_feature_dirty()      { git checkout -q -b feature/topic >/dev/null 2>&1; _dirty_php; }
_setup_main_dirty_witness() { _dirty_php; printf 'app.php\n' > ".git/claude-session-writes-${TEST_UUID}.txt"; }
_setup_main_maint() {
  printf 'a\n' > README.md
  git add README.md >/dev/null 2>&1
  git -c commit.gpgsign=false commit -q -m add-readme >/dev/null 2>&1
  printf 'b\n' >> README.md
}

# _run_case <setup_fn> [sid] [msg] -> sets LAST_RC, LAST_ERR
_run_case() {
  local setup_fn="$1"
  local sid="${2:-$TEST_UUID}"
  local msg="${3:-$DEFAULT_MSG}"
  local repo errf
  repo=$(mktemp -d)
  errf=$(mktemp)
  (
    cd "$repo" 2>/dev/null || exit 99
    git init -q . >/dev/null 2>&1
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    git config user.email t@example.com >/dev/null 2>&1
    git config user.name tester >/dev/null 2>&1
    git -c commit.gpgsign=false commit -q --allow-empty -m init >/dev/null 2>&1
    # Hermetic SID: stdin JSON is resolve-sid priority 0. Clear envs that could
    # otherwise steer the gate to a real session or flip its branch/mode logic.
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID \
          CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY CLAUDE_MAIN_BRANCH
    "$setup_fn" "$repo" >/dev/null 2>&1
    printf '{"session_id":"%s","last_assistant_message":"%s","stop_hook_active":false}' "$sid" "$msg" \
      | bash "$GATE" >/dev/null 2>"$errf"
    exit $?
  )
  LAST_RC=$?
  LAST_ERR=$(cat "$errf" 2>/dev/null || true)
  rm -rf "$repo" "$errf" 2>/dev/null || true
}

# _run_worktree_case [sid] [msg] -> sets LAST_RC, LAST_ERR
# Gate runs from a LINKED worktree (feature branch), dirty tracked file, no
# witness — the operator's real parallel-build topology. Must still BLOCK: a
# worktree is session-private, so its dirty files ARE this session's.
_run_worktree_case() {
  local sid="${1:-$TEST_UUID}"
  local msg="${2:-$DEFAULT_MSG}"
  local main wt errf
  main=$(mktemp -d)
  wt="${main}.wt"
  errf=$(mktemp)
  (
    cd "$main" 2>/dev/null || exit 99
    git init -q . >/dev/null 2>&1
    git symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    git config user.email t@example.com >/dev/null 2>&1
    git config user.name tester >/dev/null 2>&1
    printf 'v1\n' > app.php
    git add app.php >/dev/null 2>&1
    git -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    git worktree add -q -b feature/wt "$wt" >/dev/null 2>&1
    cd "$wt" 2>/dev/null || exit 98
    printf 'v2\n' >> app.php
    unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID \
          CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY CLAUDE_MAIN_BRANCH
    printf '{"session_id":"%s","last_assistant_message":"%s","stop_hook_active":false}' "$sid" "$msg" \
      | bash "$GATE" >/dev/null 2>"$errf"
    exit $?
  )
  LAST_RC=$?
  LAST_ERR=$(cat "$errf" 2>/dev/null || true)
  git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || true
  rm -rf "$main" "$wt" "$errf" 2>/dev/null || true
}

# _check <name> <expected_rc> <actual_rc> [stderr_substr]
_check() {
  local name="$1" exp="$2" act="$3" errsub="${4:-}"
  local ok=1
  [ "$exp" = "$act" ] || ok=0
  if [ -n "$errsub" ] && ! printf '%s' "$LAST_ERR" | grep -qF "$errsub"; then ok=0; fi
  if [ "$ok" = "1" ]; then
    printf '  ok  %s (rc=%s)\n' "$name" "$act"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s (want rc=%s%s, got rc=%s)\n' "$name" "$exp" \
      "${errsub:+ +stderr~'$errsub'}" "$act"
    FAIL=$((FAIL + 1))
  fi
}

echo "== uncommitted-changes-gate :: W-attr-gate (shared-tree attribution) =="

_run_case _setup_main_dirty
_check "T1 shared-main + no witness + dirty code -> degrade-safe (no false block)" 0 "$LAST_RC"

_run_case _setup_main_dirty_witness
_check "T2 writes-log witness path still BLOCKS (attribution intact)" 2 "$LAST_RC"

_run_case _setup_feature_dirty
_check "T3 private feature-branch + no witness still BLOCKS (legacy attribution kept)" 2 "$LAST_RC"

_run_case _setup_main_maint
_check "T4 main + maintenance-only edit -> exempt (no block)" 0 "$LAST_RC"

_run_case _setup_main_dirty "$TEST_UUID" "Investigating the current behavior."
_check "T5 non-completion message -> early skip" 0 "$LAST_RC"

_run_case _setup_main_dirty
_check "T6 shared-main degrade emits advisory NOTE on stderr" 0 "$LAST_RC" "could not be attributed"

_run_worktree_case
_check "T7 linked worktree + no witness still BLOCKS (private tree, not degraded)" 2 "$LAST_RC"

# T8 (WITNESS-OVER-FRAMING, forensic finding): a session WITH a writes-log witness pointing at an unstaged
# tracked file must BLOCK even when the final message has NO completion word — a "read-only no-op, no changes"
# MISREPORT must not strand real session work via the completion-language skip. RED on .pre-orch-bak (skips → 0).
_run_case _setup_main_dirty_witness "$TEST_UUID" "The current session produced no artifacts; nothing to log."
_check "T8 witness + NON-completion no-op misreport -> BLOCK (language-skip cannot bury the witness)" 2 "$LAST_RC"

# T8b: the SAME no-completion-word message but NO witness still skips (the fix is witness-gated, not a blanket
# removal of the language skip — a genuine read-only session with no session-owned unstaged files is unaffected).
_run_case _setup_main_dirty "$TEST_UUID" "The current session produced no artifacts; nothing to log."
_check "T8b non-completion message + NO witness -> still skip (fix is witness-gated, no false block)" 0 "$LAST_RC"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
