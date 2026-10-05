#!/usr/bin/env bash
# block-cross-session-add.sh
# Event: PreToolUse / Bash
# Version: 1.1.0 (forensic 2026-06-16 — the last concurrency data-safety mode)
#   1.1.0: codex round — CODEX-001 (commit -a excludes untracked from the scan), CODEX-002 (match flags
#          on a quote-stripped command so a flag-like commit MESSAGE can't false-trigger), CODEX-003
#          (resolve SID via the canonical resolver, fail-open when truly unknown).
#
# DENIES a SWEEPING `git add -A` / `git add .` / `git add --all` / `git commit -a[m]` / `git commit --all`
# on the SHARED MAIN checkout WHEN it would stage a file that belongs to a CONCURRENT SIBLING /v session
# (the file is in that sibling's writes-log, is currently UNCOMMITTED in the working tree, and is NOT in
# this session's own writes-log). Committing a sibling's uncommitted work under THIS session is
# cross-session commit-theft: it misattributes the sibling's work AND ships its
# possibly-incomplete, un-gated changes under this session's commit.
#
# This is the prevention layer that complements the survival gate (catches a WIPE) and the exposed-inline
# gate (catches uncommitted-source-on-shared-main at completion). SKILL.md already says "never git add -A
# on shared main" — a read-surface rule; this enforces it at the only point it can be enforced: before
# the command runs.
#
# FAIL-OPEN by design: this is a data-INTEGRITY guard, not a security gate. It DENIES only on a POSITIVE
# theft detection (a sibling-owned dirty file would be swept); on ANY uncertainty (no SID, no writes-log,
# a worktree session, parse error, no git) it ALLOWS — a missed theft is rare + recoverable + caught by
# the survival/exposed backstops, whereas a false DENY would block legitimate commits (a regression).
set -uo pipefail

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

# jq missing → allow (fail-open: a theft guard must not block all commits when it can't parse).
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null); [ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null); [ -n "$CMD" ] || exit 0

# --- Is this a SWEEPING add/commit? (scoped `git add <file>` and `git commit -m` are NOT) ---
# Match flags on a QUOTE-STRIPPED copy of the command so a commit MESSAGE that happens to contain a
# flag-like token — `git commit -m "document the -all flag"` (CODEX-002), or even
# `git commit -m "git add -A notes"` (the add-regex analogue) — cannot false-trigger. Real flags always
# live OUTSIDE quotes, so stripping quoted substrings never hides a TRUE sweep (only fails open).
# Bounded to a single statement segment ([^&|;]*) so `git status; ls -A` can't false-match.
_SCAN=$(printf '%s' "$CMD" | sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g')
_sweep_add=0 _sweep_commit=0
printf '%s' "$_SCAN" | grep -qE '\bgit\b([^&|;]*[[:space:]])?add\b[^&|;]*([[:space:]]-A\b|[[:space:]]--all\b|[[:space:]]\.([[:space:]]|$))' && _sweep_add=1
printf '%s' "$_SCAN" | grep -qE '\bgit\b([^&|;]*[[:space:]])?commit\b[^&|;]*([[:space:]]-a\b|[[:space:]]--all\b|[[:space:]]-[A-Za-z]*a[A-Za-z]*\b)' && _sweep_commit=1
[ "$_sweep_add" = 1 ] || [ "$_sweep_commit" = 1 ] || exit 0

# --- PATHSPEC-SCOPE (forensic 2026-07-04, false-deny): `git add -A -- app/Services/…`
# can only stage files UNDER its pathspec — the old purely-textual `-A` match denied it for
# prompt-pack files it could not possibly sweep. Extract pathspecs after ` -- ` in the add
# statement; when present (and not repo-wide like `.`/`:/`), the theft scan below is restricted to
# dirty files under them. Quoted pathspecs were stripped with the quotes (rare) → no scoping →
# the original conservative behavior. ---
_PATHSPECS=""
if [ "$_sweep_add" = 1 ]; then
  _addseg=$(printf '%s' "$_SCAN" | grep -oE '\bgit\b[^&|;]*' | grep -E '[[:space:]]add\b' | head -1 || true)
  case "$_addseg" in
    *" -- "*) _PATHSPECS=$(printf '%s' "${_addseg#* -- }" | tr ' \t' '\n\n' | grep -vE '^-|^$' || true) ;;
  esac
fi

# --- Shared-main only: a worktree session is isolated, so -A there cannot steal main's WIP. ---
# (CODEX-005, accepted FN: `git -C <other> add -A` / `GIT_DIR=… git add -A` target a DIFFERENT repo than
#  CWD and so escape this CWD-anchored scan — a missed theft, never a false-deny. Out of /v's real surface.)
GITDIR=$(git rev-parse --git-dir 2>/dev/null || true)
case "$GITDIR" in *"/worktrees/"*) exit 0 ;; esac   # linked worktree → isolated → allow
REPO=$(git rev-parse --show-toplevel 2>/dev/null || true); [ -n "$REPO" ] || exit 0
GCD=$(git rev-parse --git-common-dir 2>/dev/null || true); [ -n "$GCD" ] || exit 0
case "$GCD" in /*) ;; *) GCD="$(cd "$GCD" 2>/dev/null && pwd)" || exit 0 ;; esac

# --- Resolve THIS session's id the SAME way track-session-writes.sh named my writes-log (canonical
# resolver: stdin JSON .session_id → env → runtime file). Without a reliable SID we cannot tell "mine"
# from "a sibling's", so the gate would flag my OWN files → fail-open (CODEX-003: the unset-SID headless
# runner is exactly where /v does its merge `git add`). ---
SID=""
if [ -f "$HOOKS_LIB_DIR/resolve-sid.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS_LIB_DIR/resolve-sid.sh" 2>/dev/null || true
  type resolve_sid >/dev/null 2>&1 && SID=$(resolve_sid "$INPUT" 2>/dev/null || true)
fi
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SID" ] || exit 0   # cannot identify "mine" → fail-open (never block my own commit)

# --- What the sweep would STAGE. `git add -A`/`.`/`--all` stage UNTRACKED files too; `git commit -a`
# stages ONLY tracked modifications/deletions, never untracked (CODEX-001). So when ONLY the commit
# class matched, exclude untracked (`??`) — else we'd false-deny a `commit -a` for an untracked sibling
# file it could not possibly sweep. Strip the XY status prefix + rename arrow. ---
if [ "$_sweep_add" = 1 ]; then
  DIRTY=$(git status --porcelain 2>/dev/null | sed -e 's/^...//' -e 's/.* -> //' | sort -u)
else
  DIRTY=$(git status --porcelain 2>/dev/null | grep -vE '^\?\?' | sed -e 's/^...//' -e 's/.* -> //' | sort -u)
fi
[ -n "$DIRTY" ] || exit 0

# Apply the pathspec scope (see above): only files a scoped add can actually reach are theft targets.
if [ -n "$_PATHSPECS" ]; then
  _scoped_ok=1
  while IFS= read -r _ps; do
    [ -n "$_ps" ] || continue
    case "$_ps" in "."|":/"|":/*") _scoped_ok=0; break ;; esac
  done <<EOF_PS
$_PATHSPECS
EOF_PS
  if [ "$_scoped_ok" = 1 ]; then
    DIRTY=$(printf '%s\n' "$DIRTY" | while IFS= read -r _df; do
      printf '%s\n' "$_PATHSPECS" | while IFS= read -r _ps; do
        [ -n "$_ps" ] || continue
        _psn="${_ps%/}"
        case "$_df" in ("$_psn"|"$_psn"/*) printf '%s\n' "$_df" ;; esac   # leading ( for bash 3.2 inside $(...)
      done
    done | sort -u)
    [ -n "$DIRTY" ] || exit 0
  fi
fi

# --- My own writes (never flag my own files). ---
MINE=""
[ -n "$SID" ] && [ -f "$GCD/claude-session-writes-${SID}.txt" ] && MINE=$(grep -v '^\[' "$GCD/claude-session-writes-${SID}.txt" 2>/dev/null || true)

# --- A dirty file that is in a CONCURRENT (unfinished) sibling's writes-log AND not mine = theft target. ---
# DEAD-OWNER awareness (forensic 2026-07-04): the guard called a dead session "a concurrent sibling"
# long after that session died — misdiagnosing orphaned WIP as live contention. The deny
# STANDS either way (sweeping a dead session's WIP into this session's commit is still
# mis-scoped/mis-attributed work), but the message must tell the operator the truth: dead-owner
# WIP needs ADJUDICATION (commit/stash it on main deliberately), not waiting.
_slp="$HOOKS_LIB_DIR/session-lock-parse.sh"
# shellcheck source=/dev/null
[ -f "$_slp" ] && . "$_slp" 2>/dev/null || true
_theft="" _victims="" _any_live=0
for _wl in "$GCD"/claude-session-writes-*.txt; do
  [ -f "$_wl" ] || continue
  _osid="${_wl##*/claude-session-writes-}"; _osid="${_osid%.txt}"
  [ -n "$_osid" ] && [ "$_osid" = "$SID" ] && continue                 # skip self
  [ -f "$REPO/SESSION_LOG_${_osid}.yaml" ] && continue                 # sibling already FINISHED (logged) → not live
  _vtag="(DEAD)"
  if type _lock_sid_alive >/dev/null 2>&1 && _lock_sid_alive "$_osid" 2>/dev/null; then _vtag=""; _any_live=1; fi
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    # NOTE (CODEX-004, accepted FN): paths with spaces/specials are C-quoted by `git status --porcelain`
    # so they won't grep-match the raw writes-log path → theft on such a file is MISSED (fail-open, never
    # a false-deny). Acceptable: the survival/exposed backstops still catch the resulting wipe.
    printf '%s\n' "$DIRTY" | grep -Fxq -- "$_f" || continue            # the sibling's file is dirty in MY tree
    printf '%s\n' "$MINE"  | grep -Fxq -- "$_f" && continue            # also mine (hot-file overlap) → not pure theft
    case "$_theft" in *"$_f"*) ;; *) _theft="${_theft}${_theft:+ }$_f"; _victims="${_victims}${_victims:+,}${_osid:0:8}${_vtag}" ;; esac
  done < <(grep -v '^\[' "$_wl" 2>/dev/null || true)
done

[ -n "$_theft" ] || exit 0   # nothing sibling-owned would be swept → allow

if [ "$_any_live" = 1 ]; then
  REASON="block-cross-session-add: this sweeping 'git add -A' / 'git commit -a' on shared main would STAGE file(s) that belong to a concurrent sibling /v session and are still UNCOMMITTED: ${_theft} (owned by session(s) ${_victims}). Committing a sibling's work under THIS session is cross-session commit-theft — it misattributes their work and ships their possibly-incomplete, un-gated changes. Stage ONLY your own files: 'git add <your files>', then 'git commit' (no -a). Your own work is unaffected; this blocks only the sibling-owned files."
else
  REASON="block-cross-session-add: this sweeping 'git add -A' / 'git commit -a' on shared main would STAGE file(s) that belong to a DEAD /v session (no longer running): ${_theft} (owned by ${_victims}). This is ORPHANED WIP, not live contention — do not sweep it into this session's commit. Adjudicate it deliberately: commit it on main as its own housekeeping commit, stash it (git stash push --include-untracked -- <those files>), or discard it if unwanted; then re-run your own scoped add/commit."
fi
jq -nc --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
