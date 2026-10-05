#!/usr/bin/env bash
# v-diff-scope.sh — SINGLE SOURCE for "what did THIS session change?"
# Version: 1.0.0  (SE-1 de-duplication, 2026-08-03)
#
# WHY THIS EXISTS. v-classify-light-tier.sh and v-classify-medium-tier.sh each carried their own
# byte-identical copy of this machinery. The drift that predicts is not hypothetical — it happened
# the same day MEDIUM was written: W-UNTRACKED (brand-new files invisible because `git diff HEAD`
# and `git diff --cached` list only TRACKED paths) was found in one copy, fixed there, and the
# ORIGINAL kept the bug until it was found a second time. A 2-line config edit plus 9 untracked
# services was still returning LIGHT=1 — the fast lane, which waives QA, VERIFY_DONE, IMPACT_MAP
# AND the gauntlet witness. One copy is the fix; a parity test is not.
#
# CONTRACT. Source this file, then call `v_diff_scope_init`. It sets:
#   CHANGED_FILES          newline-separated, session-scoped, sorted -u, noise-filtered
#   _SESSION_RANGE         "<base>..<branch>" when a session worktree/branch was resolved, else ""
#   _SESSION_COMMIT_FILES  files from this session's commits (may be empty)
# and defines two helpers usable afterwards:
#   _changed_lines <path>  whitespace-insensitive changed-line count (whole body if untracked)
#   _file_diff     <path>  full diff text (session range + uncommitted + staged)
#
# REQUIRES: REPO_ROOT set by the caller. Reads SID from CLAUDE_SESSION_ID /
# CLAUDE_CODE_SESSION_ID / SESSION_ID / ~/.claude/runtime/current-session-id.
#
# FAIL-SAFE DIRECTION (the invariant every change here must preserve): every fallback in this file
# OVER-includes. A superset of files can only make a tier's caps HARDER to clear — it can never
# promote a diff INTO a fast lane. If you add a path here, check it moves in that direction.

# ── session-scoped changed-file set (A4 machinery) ─────────────────────────────────────────────
v_diff_scope_init() {
  SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${SESSION_ID:-}}}"
  [ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ] && SID="$(tr -d ' \n\r' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)"
  _SESSION_RANGE=""
  _SESSION_COMMIT_FILES=""
  if [ -n "$SID" ]; then
    local _SID_SLUG="${SID%%-*}" _WT_BRANCH="" _wt_p _B _wt_tmp _c
    while IFS= read -r _wt_p; do
      [ -n "$_wt_p" ] && [ -f "$_wt_p/.claude-session-lock" ] || continue
      [ "$(awk '{print $1; exit}' "$_wt_p/.claude-session-lock" 2>/dev/null)" = "$SID" ] && { _WT_BRANCH="$(git -C "$_wt_p" branch --show-current 2>/dev/null)"; break; }
    done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    [ -z "$_WT_BRANCH" ] && [ -n "$_SID_SLUG" ] && [ "$_SID_SLUG" != "$SID" ] && \
      _WT_BRANCH="$(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${_SID_SLUG}([-_/]|\$)" | head -1)"
    if [ -n "$_WT_BRANCH" ]; then
      _B=$(git -C "$REPO_ROOT" merge-base "${CLAUDE_MAIN_BRANCH:-main}" "$_WT_BRANCH" 2>/dev/null || true)
      if [ -n "$_B" ]; then
        _SESSION_RANGE="${_B}..${_WT_BRANCH}"
        _SESSION_COMMIT_FILES="$(git -C "$REPO_ROOT" diff --name-only "$_SESSION_RANGE" 2>/dev/null || true)"
      fi
    fi
    if [ -z "$_SESSION_COMMIT_FILES" ]; then
      for _wt_tmp in "$REPO_ROOT/.v/tmp" "${V_TMP_DIR:-}"; do
        [ -n "$_wt_tmp" ] && [ -s "$_wt_tmp/commits-${SID}.txt" ] || continue
        _SESSION_COMMIT_FILES="$(while IFS= read -r _c; do [ -n "$_c" ] && git -C "$REPO_ROOT" diff-tree --no-commit-id --name-only -r "$_c" 2>/dev/null; done < "$_wt_tmp/commits-${SID}.txt")"
        [ -n "$_SESSION_COMMIT_FILES" ] && break
      done
    fi
  fi

  # W-LIGHT-SCOPE (2026-08-03): scope the UNCOMMITTED/STAGED half to THIS session's own writes.
  # _SESSION_COMMIT_FILES above is ALREADY session-scoped; only the git-diff lines were whole-tree,
  # which made the caps unclearable in any repo carrying unrelated dirty WIP (one project: 43 stale
  # files ⇒ LIGHT/TRIVIAL structurally unreachable). This ALSO scopes the per-file security/UI/
  # migration hard-excludes, which is the POINT: your OWN migration still excludes you from the
  # fast lane; a SIBLING session's dirty migration no longer does.
  # FAIL STRICT: if the writes log is unavailable (lib absent / no SID / log empty) keep the
  # whole-tree view — a SUPERSET, so the fallback can only ADD files, never make caps easier.
  # NOTE: get_session_writes resolves the git dir from CWD, not $REPO_ROOT — run it there.
  local _SW_LIB="${V_SESSION_WRITES_LIB:-$HOME/.claude/hooks/lib/session-writes.sh}"
  local _SESSION_WRITES=""
  if [ -f "$_SW_LIB" ]; then
    # shellcheck source=/dev/null
    . "$_SW_LIB" 2>/dev/null || true
    if [ -n "$SID" ] && type get_session_writes >/dev/null 2>&1; then
      _SESSION_WRITES=$( cd "$REPO_ROOT" 2>/dev/null && get_session_writes "$SID" 2>/dev/null || true )
    fi
  fi

  # W-UNTRACKED (2026-08-03): `diff HEAD` / `diff --cached` list only TRACKED paths, so a session
  # that CREATES files had them INVISIBLE and was scored on whatever tracked file it also touched.
  # Reproduced live: a 2-line config edit + 9 brand-new untracked services returned LIGHT=1
  # (FILES=config/app.php, LINES=2). `--exclude-standard` honours .gitignore, so build output and
  # vendor stay out; what remains is real session work.
  local _UNCOMMITTED_ALL _UNCOMMITTED_SCOPED
  _UNCOMMITTED_ALL=$( {
    git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null
    git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null
    git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null
  } | grep -v '^$' | sort -u )

  if [ -n "$_SESSION_WRITES" ]; then
    _UNCOMMITTED_SCOPED=$(printf '%s\n' "$_UNCOMMITTED_ALL" \
      | grep -Fxf <(printf '%s\n' "$_SESSION_WRITES") 2>/dev/null || true)
  else
    _UNCOMMITTED_SCOPED="$_UNCOMMITTED_ALL"
  fi

  CHANGED_FILES=$( {
    printf '%s\n' "$_UNCOMMITTED_SCOPED"
    printf '%s\n' "$_SESSION_COMMIT_FILES"
  } | grep -v '^$' | sort -u | grep -vE '\.lock$|package-lock\.json$|composer\.lock$|ziggy\.js$|^vendor/|^node_modules/' || true)
}

# whitespace-insensitive changed-line count: session range + uncommitted (disjoint).
# An untracked file is in NEITHER `diff HEAD` nor `diff --cached`, so the tracked-only path scored
# it 0 lines even once its PATH was visible. Count its whole body — a new file is 100% added.
_changed_lines() {
  local _f="$1" _n=0 _u=0
  if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$_f" >/dev/null 2>&1; then
    [ -n "${_SESSION_RANGE:-}" ] && _n=$(git -C "$REPO_ROOT" diff -w "$_SESSION_RANGE" -- "$_f" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l | tr -d ' ')
    _u=$(git -C "$REPO_ROOT" diff -w HEAD -- "$_f" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l | tr -d ' ')
  else
    # DIRECTION FIX (self-review 2026-08-03): this was `grep -cve '^[[:space:]]*$'` (non-blank
    # lines), which is NOT the conservative choice. The tracked path's `grep -E '^[+-][^+-]'`
    # DOES count a whitespace-only added line (`+   ` matches — the second char is a space), so
    # excluding them here made an untracked file score FEWER lines than the equivalent tracked
    # diff — i.e. easier to stay under a tier cap. Every fallback in this file must over-count.
    # `wc -l` is unambiguously >= any diff-derived count for a wholly-new file.
    _u=$(wc -l < "$REPO_ROOT/$_f" 2>/dev/null | tr -d ' ' || echo 0)
  fi
  printf '%s' "$(( ${_n:-0} + ${_u:-0} ))"
}

# full diff text for one file (session range + uncommitted + staged)
_file_diff() {
  local _f="$1"
  [ -n "${_SESSION_RANGE:-}" ] && git -C "$REPO_ROOT" diff "$_SESSION_RANGE" -- "$_f" 2>/dev/null
  git -C "$REPO_ROOT" diff HEAD -- "$_f" 2>/dev/null
  git -C "$REPO_ROOT" diff --cached -- "$_f" 2>/dev/null
}
