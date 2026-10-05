#!/usr/bin/env bash
# v-worktree-adopt-or-create.sh <mode:fix|build> <slug> <sid> [repo_root] — A-2 fix (a).
#
# WHY (orchestrator-hardening handoff A-2, forensic 2026-07-01/02): the inline SKILL.md
# worktree-creation prose (`v-build-workflows.md`) called `git worktree add` UNCONDITIONALLY, with
# NO check for "does a worktree already exist for this SID". Under a compaction/fork-restart, the
# orchestrator's bash cwd resets to the main root and Step 0/Step 2 RE-RUN with the SAME
# CLAUDE_SESSION_ID — but the {slug} chosen by the model is free text derived from the task, not
# deterministic, so the restarted run typically picks a DIFFERENT slug and mints a SECOND worktree
# for the same session (repro'd live: fork-1 made `…-job-harden-<sid>`, fork-2 made
# `…-harden-<sid>`; class test in v-worktree-adopt-or-create-test.sh shows the raw unconditional
# pattern producing 2 registered worktrees for 1 SID). Consequences: ~52min/session of wasted
# worktree+vendor-setup wall-clock, an orphaned worktree with the session's actual WIP stranded on
# the wrong branch, and WORKTREE_PATH resolution (v-emit-prompt.sh) picking whichever worktree it
# scans first — not necessarily the one with the real work.
#
# FIX: before creating anything, scan `git worktree list --porcelain` for an EXISTING worktree whose
# `.claude-session-lock` SID equals this session's SID (via the shared session-lock-parse.sh parser —
# same lib the drain/active-siblings tooling uses, so lock-format handling stays in ONE place per
# Trap 3 in the handoff). If found: ADOPT it — never mint a second worktree/slug for the same SID.
# Refresh the lock's PID (the restarted process has a NEW pid) and re-touch the compat symlink +
# active-worktree marker, since a restart may have lost both. If not found: create exactly the same
# way the old inline pattern did (byte-identical naming/marker contract), so `mode=false` behavior is
# unchanged for a session's FIRST invocation.
#
# Usage: bash v-worktree-adopt-or-create.sh <fix|build> <slug> <sid> [repo_root]
# Output (stdout, key=value, %q-quoted where a value may contain shell-special chars):
#   WORKTREE_ADOPTED=true|false
#   WORKTREE_ABS_PATH=<absolute path>
#   WORKTREE_BRANCH=<branch name>
# Exit: 0 on success (adopted or created). Non-zero + stderr diagnostic on failure (bad args, `git
# worktree add` failure, unresolvable repo root). Never partially mutates state on a detected failure
# path it can still report cleanly — `git worktree add` itself is the only truly destructive call and
# git makes that atomic (either the worktree exists after, or it errored and nothing was created).

set +e
set +o pipefail
set +u

MODE="${1:-}"
SLUG="${2:-}"
SID="${3:-}"
REPO_ROOT_ARG="${4:-}"

if [ -z "$MODE" ] || [ -z "$SLUG" ] || [ -z "$SID" ]; then
  echo "ERROR: usage: v-worktree-adopt-or-create.sh <fix|build> <slug> <sid> [repo_root]" >&2
  exit 2
fi
case "$MODE" in
  fix|build) : ;;
  *) echo "ERROR: mode must be 'fix' or 'build', got: $MODE" >&2; exit 2 ;;
esac

# ── Input sanitization (codex CDX-2): SLUG is free text chosen by the model — a space (or :?*~^
# etc.) is invalid in a git ref and fails `git worktree add` deep inside the script, which the
# call site's eval-pattern then swallows (CDX-1). Restrict to a known-safe class up front. SID is
# machine-generated and must already be ref/path-safe — reject loudly if not (never sanitize it:
# a rewritten SID would break every SID-keyed marker/artifact lookup).
_slugify(){ printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '-' | tr -s '-' | sed 's/^-//; s/-$//'; }
SLUG="$(_slugify "$SLUG")"
if [ -z "$SLUG" ]; then
  echo "ERROR: slug sanitized to empty (input was entirely ref-hostile characters) — pass a usable slug" >&2
  exit 2
fi
case "$SID" in
  *[!A-Za-z0-9-]*)
    echo "ERROR: SID contains ref/path-hostile characters (allowed: A-Za-z0-9 and dashes): $SID" >&2
    exit 2
    ;;
esac

REPO_ROOT="$REPO_ROOT_ARG"
[ -z "$REPO_ROOT" ] && REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  echo "ERROR: could not resolve repo_root (not in a git repo and none passed as \$4)" >&2
  exit 3
fi

# ── Per-SID mutex around the scan→create critical section (codex CDX-3): two same-SID
# invocations racing (forked subagents — distinct from the serial restart this fix targets) can
# both pass the Step-1 scan before either writes a lock, and both mint a worktree — the exact
# duplicate this helper exists to prevent, via TOCTOU instead of restart. Portable mkdir-lock
# (macOS has no flock), same convention as v-merge-back.sh / v-suite-lock.sh. Fail-open after
# ~10s so a kill-9'd holder cannot block forever; the trap releases only a lock WE acquired.
_ADOPT_LOCK_DIR="$REPO_ROOT/.worktrees/.adopt-${SID}.lock.d"
mkdir -p "$REPO_ROOT/.worktrees" 2>/dev/null
_lock_acquired=0; _lock_tries=0
while [ "$_lock_tries" -le 100 ]; do
  if mkdir "$_ADOPT_LOCK_DIR" 2>/dev/null; then _lock_acquired=1; break; fi
  _lock_tries=$((_lock_tries+1)); sleep 0.1
done
[ "$_lock_acquired" -eq 1 ] || echo "WARNING: adopt-lock not acquired after ~10s (stale holder?) — proceeding unlocked (fail-open, same posture as v-suite-lock.sh)" >&2
trap '[ "${_lock_acquired:-0}" -eq 1 ] && rmdir "$_ADOPT_LOCK_DIR" 2>/dev/null' EXIT

_LOCK_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
if [ -f "$_LOCK_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_LOCK_LIB"
fi

# W71-F11-B review finding (2026-07-03, hostile logic review of the WIP/lock hardening below): this
# script writes `.claude-session-lock` into every worktree it adopts/creates but never excluded it
# from git — so `git status --porcelain` on ANY worktree this script itself made always shows
# `?? .claude-session-lock`, even with zero real WIP. Step 1.5's new "ancestor branch, worktree
# clean, no live lock -> exempt" case therefore could never actually trigger for a worktree minted by
# this script: the lock file's own untracked entry made every such worktree read as dirty, silently
# inverting the fix into an ALWAYS-BLOCK for any landed/merged sibling whose worktree hadn't been
# physically torn down yet. `hooks/lib/worktree-lock-exclude.sh` already exists and is used by the
# native WorktreeCreate hook path (`hooks/worktree-create.sh`) for exactly this reason — this script's
# direct `git worktree add` bypasses that hook entirely, so it never got the exclude. Source it here so
# both lock-write sites below (adopt-refresh and create) apply it.
_LOCK_EXCLUDE_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/worktree-lock-exclude.sh"
if [ -f "$_LOCK_EXCLUDE_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_LOCK_EXCLUDE_LIB"
fi

# ── Step 1: scan for an EXISTING worktree already owned by this SID ────────────────────────────
_ADOPT_PATH=""
if command -v _lock_sid >/dev/null 2>&1; then
  while IFS= read -r _wt_line; do
    case "$_wt_line" in
      "worktree "*) _cand="${_wt_line#worktree }" ;;
      *) continue ;;
    esac
    [ -n "$_cand" ] && [ -d "$_cand" ] || continue
    [ "$_cand" = "$REPO_ROOT" ] && continue   # never "adopt" the main checkout itself
    _lock="$_cand/.claude-session-lock"
    [ -f "$_lock" ] || continue
    _found_sid="$(_lock_sid "$_lock" 2>/dev/null)"
    if [ -n "$_found_sid" ] && [ "$_found_sid" = "$SID" ]; then
      _ADOPT_PATH="$_cand"
      break
    fi
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null)
else
  echo "WARNING: session-lock-parse.sh lib unavailable at $_LOCK_LIB — cannot scan for an existing worktree to adopt; falling through to create (may mint a duplicate if one already exists)." >&2
fi

if [ -n "$_ADOPT_PATH" ]; then
  # ── Adopt path: refresh pid/marker (a restart loses the OLD pid + may have lost the marker) ──
  _branch="$(git -C "$_ADOPT_PATH" branch --show-current 2>/dev/null)"
  # WRONG-PID-LOCK fix (forensic 2026-07-04, Jul-4 fleet): stamp the OWNING claude process, never
  # the ephemeral Bash-tool subshell — `$$` dies the moment this tool call returns, so kill -0 on
  # the lock was permanently false and every PID liveness guard degraded to the idle-tab-refreshed
  # transcript-mtime tiebreaker (drain starved all day; gauntleted branches stranded).
  _lock_pid="$$"
  command -v owning_claude_pid >/dev/null 2>&1 && _lock_pid="$(owning_claude_pid)"
  printf '%s %s %s\n' "$SID" "$_lock_pid" "$(date +%s)" > "$_ADOPT_PATH/.claude-session-lock" 2>/dev/null
  command -v exclude_session_lock_from_git >/dev/null 2>&1 && exclude_session_lock_from_git "$_ADOPT_PATH"
  command -v exclude_build_artifacts_from_git >/dev/null 2>&1 && exclude_build_artifacts_from_git "$_ADOPT_PATH"  # RC-1: keep npm/composer installs out of git status
  _wt_name="$(basename "$_ADOPT_PATH")"
  mkdir -p "$REPO_ROOT/.worktrees" 2>/dev/null
  ln -sfn "$_ADOPT_PATH" "$REPO_ROOT/.worktrees/$_wt_name" 2>/dev/null
  mkdir -p "$HOME/.claude/runtime" 2>/dev/null
  echo "$SID" > "$HOME/.claude/runtime/active-worktree-${SID}" 2>/dev/null
  echo "WORKTREE_ADOPTED=true"
  printf 'WORKTREE_ABS_PATH=%q\n' "$_ADOPT_PATH"
  printf 'WORKTREE_BRANCH=%q\n' "${_branch:-unknown}"
  exit 0
fi

# ── Step 1.4: W71-F11b INLINE-ON-MAIN duplicate-task guard (forensic 2026-07-03) ────────────────
# Companion to Step 1.5 below: a parallel-fanout incident (2026-07-03) had TWO
# sessions implement the SAME task INLINE ON MAIN — no build/<slug>-<sid>
# branch ever existed for either, so Step 1.5's `for-each-ref refs/heads/${MODE}/${SLUG}-*` scan had
# nothing to see. This step instead looks at files currently DIRTY on the shared main checkout that
# belong to ANOTHER session's writes-log (same "still-live" convention block-cross-session-add.sh
# uses: a writes-log with no matching SESSION_LOG_<sid>.yaml is presumed live/unfinished) whose
# basename kebab-cases to a substring match against SLUG — i.e. another session's staged file looks
# like it implements the same named task. This is a file-naming heuristic, not a guarantee: a task
# whose file names don't echo the slug will not be caught here — Step 1.5 remains the primary belt
# for the worktree-per-task convention; this is the belt for the inline-on-main escape hatch.
# review finding (2026-07-03, hostile logic review): a RAW substring match on dash-stripped strings
# false-positives on a generic single-word slug (e.g. slug "migration" matches ANY unrelated file
# whose name merely contains that word, like "AddMigrationHelper.php" from a totally different
# task) — a length-6 floor bounds length, not specificity. _tokens_match below requires the SHORTER
# side's hyphen-tokens to appear as a CONTIGUOUS run inside the longer side's tokens, and additionally
# requires >=2 tokens (or one token >=10 chars) so a single generic noun can never match alone — the
# real incident shape (slug "third-party-api-adapter" vs file "ThirdPartyApiAdapter.php") is a 3-token exact
# run and matches easily; "migration" vs "AddMigrationHelper" is a single 9-char token and is rejected.
_tokens_match() {
  local a="$1" b="$2"
  local -a _ta _tb _short _long
  IFS='-' read -r -a _ta <<< "$a"
  IFS='-' read -r -a _tb <<< "$b"
  if [ "${#_ta[@]}" -le "${#_tb[@]}" ]; then _short=("${_ta[@]}"); _long=("${_tb[@]}"); else _short=("${_tb[@]}"); _long=("${_ta[@]}"); fi
  local _n_short="${#_short[@]}" _n_long="${#_long[@]}"
  [ "$_n_short" -ge 1 ] || return 1
  if [ "$_n_short" -eq 1 ]; then
    [ "${#_short[0]}" -ge 10 ] || return 1
  fi
  local _i _j _ok
  _i=0
  while [ $((_i + _n_short)) -le "$_n_long" ]; do
    _ok=1
    _j=0
    while [ "$_j" -lt "$_n_short" ]; do
      [ "${_long[$((_i + _j))]}" = "${_short[$_j]}" ] || { _ok=0; break; }
      _j=$((_j + 1))
    done
    [ "$_ok" -eq 1 ] && return 0
    _i=$((_i + 1))
  done
  return 1
}
if [ "${V_DUP_TASK_OK:-0}" != "1" ]; then
  _GCD="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  case "$_GCD" in /*) ;; *) [ -n "$_GCD" ] && _GCD="$(cd "$REPO_ROOT/$_GCD" 2>/dev/null && pwd)" ;; esac
  # review finding (2026-07-03): degrade LOUDLY when git-common-dir can't be resolved, matching this
  # file's existing warn-on-degraded-signal convention (see the _dup_main / missing-lib warnings below)
  # instead of silently skipping Step 1.4 with zero diagnostic.
  if [ -z "$_GCD" ] || [ ! -d "$_GCD" ]; then
    echo "WARNING: W71-F11b — could not resolve git-common-dir for $REPO_ROOT; the inline-on-main duplicate check is skipped this invocation (fail-open)." >&2
  fi
  if [ -n "$_GCD" ] && [ -d "$_GCD" ]; then
    _slug_kebab="$(printf '%s' "$SLUG" | tr 'A-Z' 'a-z')"
    if [ -n "$_slug_kebab" ] && [ "${#_slug_kebab}" -ge 6 ]; then
      _dup_inline_hits=""
      # -c core.quotePath=false (review finding, 2026-07-03): without it, git C-quotes non-ASCII/
      # special-char paths in --porcelain output while claude-session-writes-<sid>.txt stores the raw
      # unescaped path, so the exact-match grep below would miss a genuine duplicate on such filenames.
      _dirty_main="$(git -c core.quotePath=false -C "$REPO_ROOT" status --porcelain 2>/dev/null | sed -e 's/^...//' -e 's/.* -> //' | sort -u)"
      if [ -n "$_dirty_main" ]; then
        for _wl in "$_GCD"/claude-session-writes-*.txt; do
          [ -f "$_wl" ] || continue
          _osid="${_wl##*/claude-session-writes-}"; _osid="${_osid%.txt}"
          [ -n "$_osid" ] && [ "$_osid" = "$SID" ] && continue
          [ -f "$REPO_ROOT/SESSION_LOG_${_osid}.yaml" ] && continue   # sibling already FINISHED → not live
          while IFS= read -r _f; do
            [ -n "$_f" ] || continue
            printf '%s\n' "$_dirty_main" | grep -Fxq -- "$_f" || continue   # must still be dirty NOW
            _base="$(basename "$_f")"; _base="${_base%.*}"
            _base_kebab="$(printf '%s' "$_base" | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//')"
            [ -n "$_base_kebab" ] || continue
            if _tokens_match "$_slug_kebab" "$_base_kebab"; then
              _dup_inline_hits="${_dup_inline_hits}  - ${_f} (session ${_osid}, on main, uncommitted)"$'\n'
            fi
          done < <(grep -v '^\[' "$_wl" 2>/dev/null)
        done
      fi
      if [ -n "$_dup_inline_hits" ]; then
        {
          echo "ERROR: DUPLICATE-TASK guard (W71-F11b, inline-on-main): file(s) matching task slug '${SLUG}' are UNCOMMITTED on main under a DIFFERENT (apparently still-live) session:"
          printf '%s' "$_dup_inline_hits"
          echo "Another session appears to already be implementing this task inline on main. Do NOT implement it again:"
          echo "  - if that session is still active, STOP and report the duplicate dispatch instead of duplicating the work;"
          echo "  - if it is abandoned, commit/land or discard its staged files via the sanctioned path first;"
          echo "  - only for a deliberate, conscious re-attempt: re-run with V_DUP_TASK_OK=1."
        } >&2
        exit 7
      fi
    fi
  fi
fi

# ── Step 1.5: W71-F11 DUPLICATE-TASK guard (forensic 2026-07-02; hardened 2026-07-03) ───────────
# The same finding was implemented THREE times in parallel by three sessions, each on its
# own branch `fix/<slug>-<sid>`, with two mutually incompatible schema designs —
# a near-miss double-migration on merge and ~2 full gauntlets of wasted cost. Upstream causes
# (paste-cache claim W25-F14/W71-F1, capture clobber W71-F5) are fixed at their layers; this is the
# last-line belt that catches ANY residual duplicate mechanism (runner re-dispatch, a user pasting
# the same pack into two panes) at the moment it becomes a second branch.
# Fires only when an UNMERGED branch exists for the SAME mode + EXACT same slug with a SID-shaped
# suffix that is NOT this session's — i.e., another session's live/stranded attempt at this task.
# A slug that merely shares a prefix with a longer slug never blocks (the suffix must be
# SID-shaped). Deliberate re-attempts (e.g. redoing a task whose earlier branch was abandoned):
# land or delete the stale branch first via the sanctioned path, or override with V_DUP_TASK_OK=1.
#
# W71-F11-B (forensic 2026-07-03, parallel-fanout incident): `--is-ancestor branch main` alone is NOT
# sufficient evidence that a branch is "landed, safe to skip". A sibling worktree branch created off
# main and never committed to (the "leave staged, don't commit" fleet convention) is ALSO trivially
# an ancestor of main — its tip never moved past main's own history — yet its worktree can be
# sitting on live staged/untracked WIP the whole time. Ancestry only proves the branch holds nothing
# main doesn't already have; it does NOT prove the branch's WORKTREE is empty. So an ancestor branch
# is now exempt ONLY if either (a) no worktree exists for it any more (torn down / self-cleaned —
# genuinely nothing left behind), or (b) its worktree exists but is clean with no
# live session lock. A live lock OR any dirty file in that worktree means real, un-landed work is
# sitting behind this "merged" branch — treat as NOT exempt, same as an unmerged branch.
if [ "${V_DUP_TASK_OK:-0}" != "1" ]; then
  _dup_main="${MAIN_BRANCH:-main}"
  git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$_dup_main" >/dev/null 2>&1 \
    || _dup_main="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  # review F3: an unresolvable main ref means the merged-branch exemption below cannot run —
  # the guard then fails CLOSED (every same-slug sibling branch blocks). That is the intended
  # direction for a duplicate guard, but say so, or the block reads as arbitrary.
  [ -z "$_dup_main" ] && echo "WARNING: W71-F11 — could not resolve the main branch (MAIN_BRANCH env, refs/heads/main, origin/HEAD all absent); the merged-branch exemption is unavailable, so ANY same-slug sibling branch will block (fail-closed)." >&2
  _DUP_BRANCHES=""
  _sid_lc="$(printf '%s' "$SID" | tr 'A-F' 'a-f')"
  _sid_short_lc="${_sid_lc%%-*}"
  while IFS= read -r _dup_branch; do
    [ -n "$_dup_branch" ] || continue
    _dup_rest="${_dup_branch#${MODE}/${SLUG}-}"
    # review F2: compare case-insensitively — a hand-minted uppercase/mixed-case SID suffix must
    # not slip past a lowercase-only pattern.
    _dup_rest_lc="$(printf '%s' "$_dup_rest" | tr 'A-F' 'a-f')"
    # suffix must be SID-shaped (full UUID or short 8-hex) — a longer slug sharing this slug as a
    # prefix leaves a non-SID remainder and must NOT block (different task).
    printf '%s' "$_dup_rest_lc" | grep -qE '^[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$' || continue
    # our own SID (full or short) is the adopt/create path's business, not a duplicate
    if [ "$_dup_rest_lc" = "$_sid_lc" ] || [ "$_dup_rest_lc" = "$_sid_short_lc" ]; then continue; fi

    _dup_merged=1   # 1 = not an ancestor of main → always blocks (unmerged/diverged branch)
    if [ -n "$_dup_main" ] && git -C "$REPO_ROOT" merge-base --is-ancestor "refs/heads/$_dup_branch" "refs/heads/$_dup_main" 2>/dev/null; then
      _dup_merged=0   # ancestor of main → provisionally exempt, pending the WIP/lock check below
    fi

    if [ "$_dup_merged" -eq 0 ]; then
      _dup_wt=""
      while IFS= read -r _wtl; do
        case "$_wtl" in
          "worktree "*) _dup_wt_cand="${_wtl#worktree }" ;;
          "branch refs/heads/$_dup_branch") _dup_wt="$_dup_wt_cand" ;;
        esac
      done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null)
      if [ -n "$_dup_wt" ] && [ -d "$_dup_wt" ]; then
        _dup_wip=0
        [ -n "$(git -C "$_dup_wt" status --porcelain 2>/dev/null)" ] && _dup_wip=1
        _dup_lock_live=0
        if [ "$_dup_wip" -eq 0 ] && [ -f "$_dup_wt/.claude-session-lock" ] && command -v lock_alive >/dev/null 2>&1; then
          lock_alive "$_dup_wt/.claude-session-lock" && _dup_lock_live=1
        fi
        if [ "$_dup_wip" -eq 1 ] || [ "$_dup_lock_live" -eq 1 ]; then
          _dup_merged=2   # "merged" by ancestry only — its worktree still holds live/uncommitted WIP
        fi
      fi
      # no worktree at all for this branch (torn down / self-cleaned) → nothing left behind →
      # _dup_merged stays 0 → genuinely exempt below
    fi

    [ "$_dup_merged" -eq 0 ] && continue   # genuinely landed, or empty-and-abandoned → never blocks
    _DUP_BRANCHES="${_DUP_BRANCHES}  - ${_dup_branch}"$'\n'
  done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' "refs/heads/${MODE}/${SLUG}-*" 2>/dev/null)
  if [ -n "$_DUP_BRANCHES" ]; then
    {
      echo "ERROR: DUPLICATE-TASK guard (W71-F11): unmerged (or merged-but-worktree-still-live) branch(es) for the SAME task slug '${MODE}/${SLUG}-<sid>' already exist under a DIFFERENT session:"
      printf '%s' "$_DUP_BRANCHES"
      echo "Another session has live or stranded work on this exact task. Do NOT implement it again:"
      echo "  - if that session is still active, STOP and report the duplicate dispatch instead of duplicating the work;"
      echo "  - if its branch is abandoned/stranded, land or delete it via the sanctioned merge-back/drain path first;"
      echo "  - only for a deliberate, conscious re-attempt: re-run with V_DUP_TASK_OK=1."
    } >&2
    exit 7
  fi
fi

# ── Step 2: no existing worktree for this SID — create exactly as the old inline pattern did ────
_wt_name="${MODE}-${SLUG}-${SID}"
_wt_ext="${WORKTREES_EXTERNAL_BASE:-$HOME/.claude/worktrees/$(basename "$REPO_ROOT")}/$_wt_name"
mkdir -p "$(dirname "$_wt_ext")" 2>/dev/null
if ! git -C "$REPO_ROOT" worktree add "$_wt_ext" -b "${MODE}/${SLUG}-${SID}" >/dev/null 2>&1; then
  echo "ERROR: git worktree add failed for $_wt_ext (branch ${MODE}/${SLUG}-${SID}) — see git's own stderr by re-running manually." >&2
  exit 4
fi
mkdir -p "$REPO_ROOT/.worktrees" 2>/dev/null
ln -sfn "$_wt_ext" "$REPO_ROOT/.worktrees/$_wt_name" 2>/dev/null
# WRONG-PID-LOCK fix (forensic 2026-07-04): stamp the OWNING claude process (see adopt path above).
_lock_pid="$$"
command -v owning_claude_pid >/dev/null 2>&1 && _lock_pid="$(owning_claude_pid)"
printf '%s %s %s\n' "$SID" "$_lock_pid" "$(date +%s)" > "$_wt_ext/.claude-session-lock" 2>/dev/null
command -v exclude_session_lock_from_git >/dev/null 2>&1 && exclude_session_lock_from_git "$_wt_ext"
command -v exclude_build_artifacts_from_git >/dev/null 2>&1 && exclude_build_artifacts_from_git "$_wt_ext"  # RC-1: keep npm/composer installs out of git status
mkdir -p "$HOME/.claude/runtime" 2>/dev/null
echo "$SID" > "$HOME/.claude/runtime/active-worktree-${SID}" 2>/dev/null

echo "WORKTREE_ADOPTED=false"
printf 'WORKTREE_ABS_PATH=%q\n' "$_wt_ext"
printf 'WORKTREE_BRANCH=%q\n' "${MODE}/${SLUG}-${SID}"
exit 0
