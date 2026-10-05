#!/usr/bin/env bash
# PreToolUse hook: Enforces worktree safety rules for parallel sessions.
# Blocks: git stash, branch switching on main, git gc/prune/repack during worktrees,
# destructive ops (reset --hard, checkout -- ., clean -f).
# Version: 1.10.0  (Rule 9: block branch switch on main dir unconditionally, not only when worktrees are active)
#
# Exit codes:
#   0 = allow the command (or deny via hookSpecificOutput permissionDecision on stdout)
#   deny() helper outputs hookSpecificOutput JSON with permissionDecision:deny on stdout

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "worktree-safety"
fi




# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny
source "$HOOKS_LIB_DIR/constants.sh"
# W83-F5: lightweight git-path cache (per-SID, 60s TTL). Heavy git state
# remains in git-state-cache.sh — this only caches path lookups.
source "$HOOKS_LIB_DIR/git-path-cache.sh"

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
SEGMENT_LIB="$HOOKS_LIB_DIR/command-segments.sh"
WORKTREE_LIB="$HOOKS_LIB_DIR/worktree-command.sh"
if [[ ! -f "$SEGMENT_LIB" ]]; then
  echo "WARNING: command-segments helper missing — worktree-safety checks skipped" >&2
  profile_done
  exit 0
fi
source "$SEGMENT_LIB"
if [[ -f "$WORKTREE_LIB" ]]; then
  source "$WORKTREE_LIB"
fi

# Read the tool input from stdin
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
HOOK_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
HOOK_CWD="${HOOK_CWD:-$PWD}"

if [ -z "$COMMAND" ]; then
  profile_done
  exit 0  # Not a command, allow
fi

# Helper: block a command with hookSpecificOutput JSON on stdout (exit 0 lets Claude Code parse permissionDecision:deny)
deny() {
  jq -n --arg reason "$1" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  profile_done
  exit 0
}

# Helper: check if any worktrees exist (beyond the main one)
# Returns 1 (false) if not inside a git repo — fail open
# git worktree list outputs one line per worktree (main + linked), so >1 means parallel sessions
has_active_worktrees() {
  git rev-parse --git-dir >/dev/null 2>&1 || return 1
  local count
  count=$(git worktree list 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 1 ]
}

# Normalize the macOS /private symlink (/private/var ↔ /var, /private/tmp ↔ /tmp) so a repo-root
# membership test compares apples to apples (git rev-parse returns the physical /private/... path while
# a relative/mktemp path may be the symlinked form). No-op on Linux.
_mv_norm() { case "$1" in /private/var/*|/private/tmp/*) printf '%s' "${1#/private}" ;; *) printf '%s' "$1" ;; esac; }

SEGMENT=""
# W-conc-fix: anchor git-subcommand detection to the SEGMENT START so we match REAL
# invocations, not mentions of "git checkout/switch/stash" inside grep/echo/quoted
# arguments (e.g. `grep "git checkout" file` must NOT be blocked — that false-positive
# blocked benign reads, observed 2026-05-25). Segments are pre-split on ;/&&/||/| by
# split_shell_command_segments, so a real git command is the FIRST token of its segment.
# Allow optional leading `VAR=val ` env prefixes so `FOO=1 git checkout` is still caught.
_GIT_AT_START='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+'
while IFS= read -r SEGMENT; do
  [ -z "$SEGMENT" ] && continue

  # --- Rule 7: git stash is BANNED in worktree workflows ---
  # The stash is a repo-wide LIFO stack shared across all worktrees.
  # Only enforce when worktrees are active (normal single-session stash is fine).
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}stash\b"; then
    if has_active_worktrees; then
      deny "BLOCKED: git stash is forbidden in worktree workflows. The stash is a repo-wide LIFO stack shared across all worktrees — parallel sessions will corrupt each other's stash. Use commits instead. If you were about to stash to CLASSIFY a test failure as pre-existing-vs-introduced, use the purpose-built helper instead — it reverts your changed files to a BASE commit with backup/trap-restore and ZERO git-state mutation: bash ~/.claude/skills/v/references/v-baseline-run.sh <BASE_SHA> \"<changed files>\" <test-cmd>."
    fi
  fi

  # --- Rule 13 (W-mv, forensic 2026-06-19): block relocating working-tree files OUT of the repo ---
  # A production session tried `git merge` (Rule 12 blocked) then `git stash` (Rule 7 blocked), then
  # physically `mv`-ed SIBLING sessions' untracked files (generated *.md / *.json files and a design-notes dir)
  # to /tmp to clear the MAIN_DIRTY check so its deferred merge-back would proceed — risking loss of the
  # siblings' uncommitted work. The merge/stash gates were defeated by emptying the dirty set out-of-band.
  # When parallel worktrees are active, moving a working-tree file to a destination OUTSIDE the repo is
  # forbidden: commit your own files; never relocate the tree to satisfy a dirty-tree gate. (`mv` WITHIN
  # the repo, and moving files INTO the repo, stay allowed.)
  if printf '%s\n' "$SEGMENT" | grep -qE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*mv[[:space:]]'; then
    if has_active_worktrees; then
      # Destination resolution. GNU `mv -t DIR src...` / `--target-directory[=]DIR` put the dest FIRST
      # (codex MEDIUM); otherwise the dest is the LAST token. Then strip surrounding quotes — a quoted
      # '/tmp/x' would otherwise start with a quote char and dodge the '/*' absolute test (quoted-dest
      # bypass, codex CRITICAL).
      if printf '%s\n' "$SEGMENT" | grep -qE '(^|[[:space:]])(-t[[:space:]]|--target-directory[=[:space:]])'; then
        _mv_dest=$(printf '%s\n' "$SEGMENT" | sed -E 's/.*(-t[[:space:]]+|--target-directory[=[:space:]]+)//; s/[[:space:]].*$//')
      else
        _mv_dest=$(printf '%s\n' "$SEGMENT" | awk '{print $NF}')
      fi
      _mv_dest=$(printf '%s' "$_mv_dest" | sed -e "s/^[\"']//" -e "s/[\"']$//")
      _mv_root=$(_mv_norm "$(git rev-parse --show-toplevel 2>/dev/null || printf '')")
      _mv_nd=$(_mv_norm "$_mv_dest")
      # A move is OUTSIDE only if: the dest escapes via ../, OR it is an absolute path NOT under the
      # repo root. Plain relative dests resolve inside the repo (cwd). Repo-root membership is checked
      # FIRST so an absolute in-repo move (even one that happens to live under /var/folders in tests) is
      # always allowed; /tmp, $TMPDIR, $HOME, etc. fall out naturally as "absolute & not under root".
      _mv_outside=0
      case "$_mv_dest" in
        ../*|*/../*) _mv_outside=1 ;;
        /*) case "$_mv_nd" in "${_mv_root}"/*|"${_mv_root}") _mv_outside=0 ;; *) _mv_outside=1 ;; esac ;;
        *) _mv_outside=0 ;;
      esac
      [ -n "$_mv_root" ] || _mv_outside=0   # not in a git repo / unknown root -> fail open
      if [ "$_mv_outside" -eq 1 ]; then
        deny "BLOCKED (W-mv): moving working-tree files to '${_mv_dest}' (outside the repo) is forbidden while parallel worktree sessions are active. Forensic 2026-06-19: a session relocated SIBLING sessions' untracked files to /tmp to clear a dirty-tree merge gate — risking loss of their uncommitted work. Do NOT empty the working tree to satisfy a gate. If your merge-back DEFERRED on a sibling's WIP, that is RETRYABLE: re-run 'bash ~/.claude/skills/v/references/v-merge-back.sh <SID>' once the sibling clears (it lands automatically), or wait. To set aside files you OWN, commit them on your branch. Never move another session's working-tree files. (This gates 'mv' specifically; cp/install/rsync/redirection are not blocked — but relocating the tree to satisfy a gate is never the answer.)"
      fi
    fi
  fi

  # --- Rule 9: Never switch branches on the main working directory ---
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}(checkout|switch)\b"; then
    # Allow file-restore operations (git checkout -- file.txt, git checkout HEAD -- file, git restore)
    # Keep strict "--\s" semantics (double-dash + whitespace), not single-dash variants.
    # FB-27b (forensic 2026-07-03): this carve-out must NOT swallow the MASS restore `checkout -- .`
    # — the unconditional `continue` skipped the whole segment, making Rule 10's `checkout -- .`
    # blocker UNREACHABLE dead code (its own target command was always allowed here first).
    if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+(checkout|switch)[[:space:]]+--[[:space:]]' \
       && ! printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+checkout[[:space:]]+--[[:space:]]+\.([[:space:]]|$)'; then
      continue
    fi
    # Allow read-only / patch operations
    if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+checkout[[:space:]]+(-p|--patch)\b'; then
      continue
    fi

    # Check if we're in the main working directory (not inside a worktree).
    # Block unconditionally — even with no parallel worktrees, switching branches
    # on the main directory undermines the worktree workflow and lets later
    # parallel sessions inherit the wrong base branch.
    # W83-F5: use cached git paths (resolve_git_paths exports GIT_ROOT/DIR/COMMON_DIR).
    resolve_git_paths
    common_dir="$GIT_COMMON_DIR"
    git_dir="$GIT_DIR"

    # In a worktree, .git is a file pointing elsewhere; in main, .git is a directory
    is_main_dir=false
    if [ -n "$GIT_ROOT" ] && [ -d "$GIT_ROOT/.git" ] 2>/dev/null; then
      is_main_dir=true
    elif [ "$common_dir" = "$git_dir" ] || [ "$common_dir" = ".git" ]; then
      is_main_dir=true
    fi

    if [ "$is_main_dir" = "true" ]; then
      # Detect branch-creating checkout/switch variants (-b, -B, -c, -C, --orphan).
      # Branch creation is safe only via `git worktree add -b`, never via checkout/switch on main.
      if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+(checkout|switch)[[:space:]]+(-[bBcC]|--orphan)\b'; then
        deny "BLOCKED: 'git checkout -b' / 'git switch -c' create a new branch AND switch the main working directory to it. Use 'git worktree add .worktrees/<name> -b <branch>' to create an isolated branch without touching the main directory."
      fi
      deny "BLOCKED: Never switch branches on the main working directory. Running git checkout/switch here changes the branch for every session that uses this directory, and any later parallel worktrees will inherit the wrong base. All feature work must happen inside worktrees (git worktree add). The main directory should stay on the base branch (usually main)."
    fi
  fi

  # --- Rule 11: Block git checkout --theirs/--ours during parallel sessions ---
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}checkout[[:space:]]+--(theirs|ours)\b"; then
    if has_active_worktrees; then
      deny "BLOCKED: 'git checkout --theirs/--ours' is forbidden during parallel sessions. Conflicts in parallel work involve OTHER sessions' changes — blindly picking one side destroys their work. Resolve each conflicting file manually: read both sides (ours = your changes, theirs = other session's changes), understand the intent, then edit the file to combine both changes."
    fi

    # Solo session: still block mass operations (. or * or multiple files)
    if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+checkout[[:space:]]+--(theirs|ours)[[:space:]]+(--[[:space:]]+)?(\.[[:space:]]*$|\*[[:space:]]*$)'; then
      deny "BLOCKED: 'git checkout --theirs/--ours .' blindly picks one side of every conflict, destroying the other side's changes entirely. Resolve each conflicting file individually: read both sides, understand the intent, then edit the file to combine changes."
    fi

    file_args=$(printf '%s\n' "$SEGMENT" | sed -E 's/.*git[[:space:]]+checkout[[:space:]]+--(theirs|ours)[[:space:]]+//' | sed -E 's/^--[[:space:]]+//' | tr ' ' '\n' | grep -v '^$' | wc -l | tr -d ' ')
    if [ "$file_args" -gt 1 ]; then
      deny "BLOCKED: 'git checkout --theirs/--ours' with multiple files risks losing changes. Resolve each file individually — read both sides and merge the intent."
    fi
  fi

  # --- Rule 10: Block destructive git operations that destroy uncommitted work ---
  # git reset --hard, git checkout -- . (mass restore), git clean -f/-fd
  # These are ALWAYS dangerous — block regardless of worktree state.
  # FB-27 (forensic 2026-07-03): anchor to SEGMENT START (same W-conc-fix
  # precedent as the checkout/stash rules above) — the old \b-anywhere match fired on the literal
  # phrase inside a commit-message heredoc and inside an echoed test command, costing ≥2 reword
  # turns per hit. A REAL invocation is the first token of its segment (env-prefix tolerated);
  # prose mentions mid-segment are data. Residual: a heredoc body LINE that itself begins with
  # the command still matches — fail-toward-block is the right bias for a destruction guard.
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}reset[[:space:]]+--hard\b"; then
    deny "BLOCKED: git reset --hard destroys uncommitted work irreversibly. Commit or stash changes first (stash only in non-worktree sessions). If you truly need to discard all changes, the user must confirm explicitly."
  fi

  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}checkout[[:space:]]+--[[:space:]]+\.([[:space:]]|\$)"; then
    deny "BLOCKED: git checkout -- . discards ALL uncommitted changes in the working directory. This is irreversible. If specific files need restoring, use git checkout -- <specific-file> instead."
  fi

  # Also catch git restore . and git restore --staged --worktree . (modern equivalent)
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}restore([[:space:]]+\\S+)*[[:space:]]+\.([[:space:]]|\$)"; then
    deny "BLOCKED: git restore . discards ALL uncommitted changes in the working directory. This is irreversible. If specific files need restoring, use git restore <specific-file> instead."
  fi

  # FB-27c (2026-07-03): the old `-[a-zA-Z]*f\b` NEVER matched `-fd`/`-fx` (no word boundary between
  # f and the next flag letter) nor `-n -f` (only inspected the first flag cluster) — `git clean -fd`,
  # the most common destructive form, sailed through. Match f in ANY flag cluster + --force.
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}clean\b.*[[:space:]]-([a-zA-Z]*f[a-zA-Z]*|-force)([[:space:]]|\$)"; then
    deny "BLOCKED: git clean -f permanently deletes untracked files. This is irreversible. If you need to remove specific files, delete them individually."
  fi

  # --- Rule 10b (W71): block branch-pointer-moving resets ---
  # `git reset [--soft|--mixed|--keep] <commit>` (commit other than HEAD / HEAD~N / HEAD^)
  # moves the branch ref BACKWARD and can ORPHAN commits — including a concurrent sibling
  # session's work that was merged into the same line. Near-miss in production session
  # a production session: a planned `git reset --mixed <base-sha>` would have destroyed a sibling
  # commit; only a tool-classifier outage cancelled it before it ran. (`--hard` is already
  # blocked by Rule 10 above.) UNSTAGING stays allowed — `git reset`, `git reset HEAD`,
  # `git reset [HEAD] -- <paths>` — as does own-recent-history adjustment (HEAD~N / HEAD^).
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}reset\b"; then
    # Strip the leading `[env=...] git reset` anchored at segment start. NOTE: no `\b` here
    # — `\b` is a GNU-sed extension that BSD/macOS sed does NOT support; on darwin it would
    # fail to strip and leave _reset_first="git", blocking EVERY reset (incl. safe unstage).
    _reset_tail=$(printf '%s\n' "$SEGMENT" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*git[[:space:]]+reset[[:space:]]*//')
    # strip leading quiet flags, then a single mode flag, then any more quiet flags
    _reset_tail=$(printf '%s\n' "$_reset_tail" | sed -E 's/^((-q|--quiet)[[:space:]]+)*//; s/^(--(soft|mixed|keep|merge)[[:space:]]+)//; s/^((-q|--quiet)[[:space:]]+)*//')
    _reset_first=$(printf '%s\n' "$_reset_tail" | awk '{print $1}')
    case "$_reset_first" in
      ""|--|HEAD|HEAD~*|HEAD^*|-*) : ;;   # unstage / reset-to-HEAD / own recent history / leftover opts → safe
      *)
        deny "BLOCKED (W71): 'git reset ${_reset_first}' moves the branch pointer backward and can ORPHAN commits — including a concurrent sibling session's merged work (an observed near-miss). In a worktree workflow never reset to a base/older SHA or branch. To undo your OWN last commit use 'git reset --soft HEAD~1' or 'git revert'; to recover orphaned commits use 'git reflog'. Unstaging files is fine: 'git reset -- <file>'."
        ;;
    esac
  fi

  # --- Rule 12 (W5F-5, forensic 2026-06-06): session-branch merges must go through ---
  # --- the lifecycle scripts (v-merge-back.sh / v-merge-all), never a manual merge ---
  # All four sessions of one parallel batch merged their
  # worktree branches into main with a RAW `git merge` — bypassing v-merge-back.sh's
  # per-project merge lock, W-GATE artifact-presence precondition, and the SID commit
  # witness (commits-<sid>.txt) that session-log attribution depends on. The script's
  # "DO NOT FALL BACK TO MANUAL git merge" banner is read-surface only; this rule is the
  # hook-level enforcement. Scope: only refs that are (a) the /v worktree naming
  # convention (build/*) or (b) a branch checked out in a .claude-session-lock'd worktree.
  # Generic merges (git merge main, git merge origin/main, user feature branches) are
  # untouched. The sanctioned lifecycle scripts run their merge inside an already-approved
  # Bash process, so they do not re-enter this PreToolUse hook.
  # NB: also match global git options BEFORE `merge` — those batch sessions merged FROM a
  # worktree CWD into main, and a bare `git merge` anchor would make any global option a
  # one-token bypass. Covers `-C <path>` and `-c <key=val>` (both take a separate-token arg;
  # FND-001) and `--long[=val]` forms. The FIRST bare `merge` token then ends the option run.
  _W5F5_GITOPTS='([-][cC][[:space:]]+[^[:space:]]+[[:space:]]+|--[A-Za-z-]+(=[^[:space:]]+)?[[:space:]]+)*'
  if printf '%s\n' "$SEGMENT" | grep -qE "${_GIT_AT_START}${_W5F5_GITOPTS}merge[[:space:]]"; then
    if printf '%s\n' "$SEGMENT" | grep -qE '[[:space:]]merge[[:space:]]+(-[a-zA-Z-]+[[:space:]]+)*--(abort|continue|quit)\b'; then
      : # conflict-state management — always allowed
    elif printf '%s\n' "$SEGMENT" | grep -qE '(^|[[:space:]])V_MERGE_AUTHORIZED=1[[:space:]]'; then
      : # authorized lifecycle fence (v-merge-all Step 3d)
    else
      # FND-002: take the tail after the FIRST `merge` token (anchored, non-greedy) so a
      # `-m '…merge…'` message can't shift the strip past the real ref. Then read REFS as the
      # positional (non-flag) tokens — options and refs INTERLEAVE (`git merge --ff-only build/x`
      # AND `git merge build/x -m msg` are both valid), so SKIP flag tokens rather than stopping
      # at the first one, and also skip the ARGUMENT of an option that takes a separate-token
      # value (-m/-F/-s/-X/-S/-O/--message/--file/--strategy*/--gpg-sign/--into-name) so a
      # `-m <msg>` / `-s <strategy>` value is never misread as a ref.
      _merge_tail=$(printf '%s\n' "$SEGMENT" | sed -E 's/^[^ ]*[[:space:]]+merge[[:space:]]+//')
      _merge_refs=""
      _skip_next=0
      # shellcheck disable=SC2086 — deliberate word-split of the tail into tokens.
      for _tok in $_merge_tail; do
        if [ "$_skip_next" = "1" ]; then _skip_next=0; continue; fi
        case "$_tok" in
          --) continue ;;                                    # end-of-options marker; refs follow
          -m|-F|-s|-X|-S|-O|--message|--file|--strategy|--strategy-option|--gpg-sign|--into-name)
            _skip_next=1; continue ;;                         # consumes a separate-token argument
          -*) continue ;;                                     # any other flag (incl. --opt=val) — skip
        esac
        _tok=$(printf '%s' "$_tok" | tr -d '"'"'")
        [ -n "$_tok" ] && _merge_refs="${_merge_refs}${_tok}
"
      done
      _merge_blocked_ref=""
      if [ -n "$_merge_refs" ]; then
        # Branches checked out in session-locked worktrees (one porcelain pass).
        _locked_branches=$(git worktree list --porcelain 2>/dev/null | awk '
          $1=="worktree" { wt=substr($0,10) }
          $1=="branch"   { br=substr($0,8); sub("^refs/heads/","",br);
                           if (wt != "" && br != "") print wt "\t" br }
        ' | while IFS=$'\t' read -r _wp _wb; do
              [ -f "$_wp/.claude-session-lock" ] && printf '%s\n' "$_wb"
            done)
        while IFS= read -r _ref; do
          [ -z "$_ref" ] && continue
          case "$_ref" in
            build/*) _merge_blocked_ref="$_ref"; break ;;
          esac
          if [ -n "$_locked_branches" ] && printf '%s\n' "$_locked_branches" | grep -qxF "$_ref"; then
            _merge_blocked_ref="$_ref"; break
          fi
        done <<< "$_merge_refs"
      fi
      if [ -n "$_merge_blocked_ref" ]; then
        deny "BLOCKED (W5F-5): manual 'git merge ${_merge_blocked_ref}' bypasses the worktree merge-back lifecycle — the per-project merge lock, the W-GATE artifact-presence precondition (PRE_FLIGHT_REPORT + AGENT_REVIEW must exist before a session branch may merge), and the SID commit witness that session attribution depends on. All four sessions of one parallel batch (2026-06-06) merged manually and corrupted attribution/gating this way. Use instead: 'bash ~/.claude/skills/v/references/v-merge-back.sh <SESSION_ID_UUID>' for your own session's worktree, or /v-merge-all for cross-session consolidation. If the script exits non-zero, FIX THE INVOCATION per its stderr — do not fall back to a manual merge."
      fi
    fi
  fi

  # --- Rule 8: Never run repo-wide git maintenance during parallel sessions ---
  # git gc, git prune, git repack operate on the shared object store.
  if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+(gc|prune|repack)\b'; then
    if has_active_worktrees; then
      deny "BLOCKED: git gc/prune/repack are forbidden while parallel worktrees are active. These commands operate on the shared object store and can remove objects another worktree still references, causing corruption or missing-object errors. Defer to idle periods when no worktrees exist."
    fi
  fi

  # --- Guard: Warn about git worktree remove without lock check ---
  if printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+worktree[[:space:]]+remove\b'; then
    WT_PATH=""
    if declare -F extract_git_worktree_path >/dev/null 2>&1; then
      WT_PATH=$(extract_git_worktree_path "$SEGMENT" "$HOOK_CWD" 2>/dev/null || echo "")
    fi
    if [[ -z "$WT_PATH" ]]; then
      WT_PATH=$(printf '%s\n' "$SEGMENT" | grep -oE '\.worktrees/[^ "'"'"']+|"\.worktrees/[^"]+"|'"'"'\.worktrees/[^'"'"']+'"'"'' | tr -d '"' | tr -d "'" | head -1 || echo "")
    fi
    # === V-9 DIRTY-TREE GUARD (2026-07-06 forensics) ===
    # NEVER allow removal of a worktree that still holds uncommitted content — staged OR unstaged —
    # regardless of lock presence, lock age, PID liveness, or owner-ended state. Every guard below this
    # point lives inside the lock-EXISTS branch and gates on age/PID: a retry session live-fired
    # `git worktree remove --force` + `git branch -D` at a dead sibling's worktree carrying staged-only
    # insertions and was saved ONLY by the lock happening to be under the 4h threshold; the same command
    # a little later would have destroyed the work, and a lock-LESS dirty worktree (the same batch left three) had NO
    # protection at all. Staged-only work reads as ahead=0/"landed" to every commit-based check — removal is
    # unrecoverable. ADDITIVE-ONLY: fires before (and independent of) the lock logic; never loosens anything.
    # A human who truly intends to discard the content: commit/stash it first, or re-run with
    # V_WT_REMOVE_DIRTY_OK=1 (explicit, single-command escape hatch).
    if [ -n "$WT_PATH" ] && [ -d "$WT_PATH" ] && [ "${V_WT_REMOVE_DIRTY_OK:-0}" != 1 ]; then
      _wt_dirty="$(git -C "$WT_PATH" status --porcelain 2>/dev/null | grep -vE '\.claude-session-lock' | head -5 || true)"
      if [ -n "$_wt_dirty" ]; then
        _wt_dirty_flat="$(printf '%s\n' "$_wt_dirty" | tr '\n' ';')"
        deny "BLOCKED (V-9 dirty-tree): Worktree $WT_PATH holds UNCOMMITTED content (staged and/or unstaged) — removing it would destroy work that exists nowhere else (staged-only strands read as ahead=0/'landed' to every commit-based check). First entries: ${_wt_dirty_flat}. Rescue first: git -C '$WT_PATH' add -A && git -C '$WT_PATH' commit -m 'rescue: worktree content before removal' (or stash). Only a human who truly intends to DISCARD the content may re-run with V_WT_REMOVE_DIRTY_OK=1."
      fi
    fi
    # === V-9 DIRTY-TREE GUARD end ===
    if [ -n "$WT_PATH" ] && [ -f "$WT_PATH/.claude-session-lock" ]; then
      LOCK_CONTENT=$(cat "$WT_PATH/.claude-session-lock" 2>/dev/null || echo "")
      LOCK_SESSION_ID=$(echo "$LOCK_CONTENT" | awk '{print $1}')
      LOCK_TS_TOKEN=$(echo "$LOCK_CONTENT" | awk '{print $2}')

      # === LOCK-CORRUPTION-DETECT: spec-compliant rename ===
      # Per v-exec-worktree.md:89 — corrupt locks must be renamed to
      # .claude-session-lock.corrupt, preserved for debugging, and treated as
      # "no lock". Definition of corrupt (additive — existing empty-SID deny
      # remains for defense-in-depth):
      #   - column 1 is non-empty BUT not UUID4-shaped (live case: digits-only)
      #   - column 2 is non-empty BUT not a positive integer epoch
      _lock_is_corrupt=0
      if [ -n "$LOCK_SESSION_ID" ] && ! echo "$LOCK_SESSION_ID" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
        _lock_is_corrupt=1
      elif [ -n "$LOCK_TS_TOKEN" ] && ! echo "$LOCK_TS_TOKEN" | grep -qE '^[0-9]+$'; then
        _lock_is_corrupt=1
      fi
      if [ "$_lock_is_corrupt" = "1" ]; then
        _lock_first_80=$(printf '%s' "$LOCK_CONTENT" | head -c 80 | tr '\n' ' ')
        _corrupt_path="$WT_PATH/.claude-session-lock.corrupt"
        # Preserve any existing .corrupt by timestamping (never overwrite forensic evidence)
        if [ -e "$_corrupt_path" ]; then
          _corrupt_path="${_corrupt_path}.$(date +%s)"
        fi
        if mv "$WT_PATH/.claude-session-lock" "$_corrupt_path" 2>/dev/null; then
          echo "worktree-safety: lock_corrupt path='$WT_PATH' content='$_lock_first_80' renamed_to='$_corrupt_path'" >&2
        else
          echo "worktree-safety: lock_corrupt path='$WT_PATH' content='$_lock_first_80' rename_failed" >&2
        fi
        # Treat as if no lock exists — fall through, do NOT deny
        continue
      fi
      # === LOCK-CORRUPTION-DETECT end ===

      # Guard: corrupted or empty lock file — block for safety only when current session is known
      if [ -z "$LOCK_SESSION_ID" ]; then
        if [ -n "$SESSION_ID" ]; then
          deny "BLOCKED: Worktree $WT_PATH has a corrupted or empty lock file. Cannot verify ownership. Inspect the lock file manually before removing."
        fi
        continue
      fi

      # This session owns the lock — allow this remove segment for own worktree.
      if [ -n "$SESSION_ID" ] && [ "$LOCK_SESSION_ID" = "$SESSION_ID" ]; then
        continue
      fi

      LOCK_AGE_SECONDS=0
      LOCK_MTIME=$(stat -c %Y "$WT_PATH/.claude-session-lock" 2>/dev/null || stat -f %m "$WT_PATH/.claude-session-lock" 2>/dev/null || echo "0")
      NOW=$(date +%s)
      LOCK_AGE_SECONDS=$((NOW - LOCK_MTIME))

      # F3-item2/4 (2026-07-05): the checks below this point gate SOLELY on the lock FILE's mtime
      # age (plus the terminal-artifact heuristic) — neither confirms the owning PROCESS is
      # actually gone. A slow, long-running session (mid multi-hour build/test) that has not
      # rewritten its own lock in 4h+ would otherwise be reclaimable by a sibling's
      # `git worktree remove` while genuinely still alive. kill -0 on the lock's recorded PID
      # (3-field "SID PID EPOCH" format) is a hard, unambiguous "this process still exists"
      # signal — additive only: when it fires, deny REGARDLESS of age/owner_ended (never loosens
      # existing protection, only strengthens it — the safe direction per F3's "never silently
      # strand or destroy live work" theme).
      _wt_safety_lock_pid=""
      if [ -f "$HOOKS_LIB_DIR/session-lock-parse.sh" ]; then
        # shellcheck disable=SC1091
        source "$HOOKS_LIB_DIR/session-lock-parse.sh" 2>/dev/null
        if declare -F _lock_pid >/dev/null 2>&1; then
          _wt_safety_lock_pid=$(_lock_pid "$WT_PATH/.claude-session-lock" 2>/dev/null)
        fi
      fi
      if [ -n "$_wt_safety_lock_pid" ] && kill -0 "$_wt_safety_lock_pid" 2>/dev/null; then
        deny "BLOCKED: Worktree $WT_PATH's session lock names PID $_wt_safety_lock_pid, which kill -0 confirms is STILL RUNNING — the owning session (${LOCK_SESSION_ID}) is alive even though its lock is ${LOCK_AGE_SECONDS}s old. Never remove a live session's worktree; wait for it to finish or verify the PID independently before retrying."
      fi

      # W-perf4: a lock from a session that DEFINITIVELY ENDED (it wrote a terminal
      # artifact — SESSION_LOG_<sid>.yaml or HANDOFF_<sid>.md) is reclaimable regardless of
      # age. The 4h age heuristic alone false-blocked cleanup of an abandoned sibling
      # worktree whose owner had already written BOTH its HANDOFF and SESSION_LOG (a
      # production session had to leave it as a manual follow-up). Resolve the lock owner's
      # MAIN repo root via git-common-dir and look for its terminal artifacts there.
      _owner_ended=0
      _repo_root_for_lock=$(git -C "$WT_PATH" rev-parse --git-common-dir 2>/dev/null || echo "")
      case "$_repo_root_for_lock" in
        /*) : ;;
        ?*) _repo_root_for_lock="$(cd "$WT_PATH" 2>/dev/null && cd "$_repo_root_for_lock" 2>/dev/null && pwd || echo "")" ;;
      esac
      [ -n "$_repo_root_for_lock" ] && _repo_root_for_lock="$(cd "$_repo_root_for_lock/.." 2>/dev/null && pwd || echo "")"
      if [ -n "$LOCK_SESSION_ID" ] && [ -n "$_repo_root_for_lock" ]; then
        if ls "$_repo_root_for_lock/SESSION_LOG_"*"${LOCK_SESSION_ID}"*.yaml >/dev/null 2>&1 \
           || ls "$_repo_root_for_lock/HANDOFF_"*"${LOCK_SESSION_ID}"*.md >/dev/null 2>&1; then
          _owner_ended=1
        fi
      fi

      # If lock is < 4 hours old ($CLAUDE_SESSION_TIMEOUT seconds), block removal — UNLESS
      # the owner definitively ended (terminal artifact) AND the lock is also >=600s old.
      # W-perf4 review (codex+logic, LOW-MED): the age floor closes the narrow window where a
      # session wrote a HANDOFF/SESSION_LOG seconds ago but is STILL running — without it, a
      # concurrent removal could reclaim it out from under that session. Genuinely abandoned
      # worktrees (terminal artifact + minutes idle) still reclaim; <600s ones stay protected.
      if [ "$LOCK_AGE_SECONDS" -lt $CLAUDE_SESSION_TIMEOUT ] \
         && { [ "$_owner_ended" -eq 0 ] || [ "$LOCK_AGE_SECONDS" -lt 600 ]; }; then
        deny "BLOCKED: Worktree $WT_PATH has an active session lock (age: ${LOCK_AGE_SECONDS}s, owner: $LOCK_SESSION_ID). Lock is less than 4 hours old — another session may own this worktree. Verify session ownership before removing. (If that session truly ended, no SESSION_LOG_<sid>.yaml / HANDOFF_<sid>.md was found for it at the repo root — write one, then retry; or wait out the 4h window.)"
      fi
    fi
  fi
done < <(split_shell_command_segments "$COMMAND")

# All checks passed — allow the command
profile_done
exit 0
