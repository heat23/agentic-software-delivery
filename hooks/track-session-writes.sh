#!/usr/bin/env bash
# track-session-writes.sh
# Event: PreToolUse (matchers: Edit, Write, MultiEdit, NotebookEdit)
# Version: 1.0.0
# Purpose: Record file paths that THIS session writes via tool calls.
#
# Why: Stop-event quality hooks need to know which files this session
# actually modified. Inferring this from `git status` is unreliable when
# multiple Claude sessions touch the same repo in parallel — they all
# share the same working tree, so one session's writes show up in
# another session's git output. The Claude Code hook protocol gives us
# the file path directly via tool_input, which is unambiguous.
#
# Storage: ${git_common_dir}/claude-session-writes-${SESSION_ID}.txt
# (anchored to .git so it survives cwd changes between main and
# worktrees and is immune to /tmp cleanup races)
#
# This hook MUST be fast and MUST NOT block tool execution. All errors
# are silently swallowed; the worst case is that a write goes
# unrecorded, which falls back to the legacy git-state path in the
# downstream Stop hook.
set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "track-session-writes"
fi



# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip
# W83-F5: lightweight git-path cache (per-SID, 60s TTL). resolve_git_paths
# exports GIT_ROOT / GIT_DIR / GIT_COMMON_DIR. Heavy git state (diffs, worktree
# list) is still in git-state-cache.sh — this only caches path lookups.
source "$HOOKS_LIB_DIR/git-path-cache.sh"

INPUT=$(cat)

# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")

# W25-followup: runtime-file fallback (W23 v2 hook persists SID here for cases
# where Claude Code's PreToolUse JSON omits session_id and CLAUDE_SESSION_ID
# isn't propagated into the hook's subshell environment). Production evidence:
# a session had a non-zero total_edit_calls in its
# SESSION_LOG but a 0-byte session-writes-${SID}.txt — consistent with this
# silent-skip path. Falling back to the runtime file recovers attribution.
if [ -z "$SESSION_ID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  CANDIDATE=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
  # Accept canonical UUID shape only — defensive against stale or partial writes
  # that might race against the SessionStart hook.
  if echo "$CANDIDATE" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    SESSION_ID="$CANDIDATE"
  fi
fi

# Stderr diagnostic when SID still missing — previously this exited silently,
# which produced the 0-byte log without any visible cause. Now an operator
# inspecting hook logs can see the failure mode directly. Production gate is
# unchanged (still exits 0 — track-session-writes is advisory, not blocking).
if [ -z "$SESSION_ID" ]; then
  echo "WARN: track-session-writes.sh skipped — no session_id in JSON, no \$CLAUDE_SESSION_ID env, no runtime file (W25-followup)" >&2
  profile_done
  exit 0
fi

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$TOOL" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  Bash)
    # F1 (W0-C): an orchestrator session that dispatches subagents via
    # v-dispatch-subagent.sh writes NO Edit/Write calls itself, so session-writes
    # stays empty and the stop hook cannot prove code-changing activity.  Write a
    # [subagent-dispatch] marker so the stop hook can promote IS_V_SESSION=1 and
    # require the gauntlet witness for this SID even when no direct file-writes exist.
    BASH_CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
    case "$BASH_CMD" in
      *v-dispatch-subagent*)
        # Resolve the git common dir and write the marker.
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          source "$HOOKS_LIB_DIR/git-path-cache.sh" 2>/dev/null || true
          resolve_git_paths 2>/dev/null || true
          _cdir="${GIT_COMMON_DIR:-$(git rev-parse --git-common-dir 2>/dev/null || true)}"
          if [ -n "$_cdir" ]; then
            _wf="${_cdir}/claude-session-writes-${SESSION_ID}.txt"
            printf '%s\n' "[subagent-dispatch]" >> "$_wf" 2>/dev/null || true
          fi
        fi
        ;;
    esac
    profile_done
    exit 0
    ;;
  *) exit 0 ;;
esac

# Edit/Write/MultiEdit use tool_input.file_path; NotebookEdit uses notebook_path.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
[ -n "$FILE_PATH" ] || exit 0

# Only record paths inside a git repo (the writes log lives in .git/).
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # ECOSYSTEM WRITES LOG (2026-08-31). ~/.claude is deliberately never git-init'd, so this early
  # exit meant NOTHING was ever recorded there — and with no writes log, check-review-artifact.sh's
  # CODE_CHANGED stayed 0 and the P2-BITE-LEDGER gate (itself gated on CODE_CHANGED) could never
  # fire in the very tree whose hooks/, hooks/lib/, skills/v/references/ and scripts/ it protects.
  # Record config-dir writes to a SEPARATE log that ONLY the bite gate reads (see
  # session_writes_ecosystem_log_path) — deliberately not wired into get_session_writes/CODE_CHANGED,
  # so the full gauntlet is NOT newly demanded of direct-lane ecosystem sessions.
  _tw_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _tw_cfgp="$(cd "$_tw_cfg" 2>/dev/null && pwd -P || true)"
  _tw_fp="$FILE_PATH"
  case "$_tw_fp" in
    /*) : ;;
    *) _tw_fp="$(pwd -P)/$_tw_fp" ;;
  esac
  # CANONICALIZE before slicing (adversarial review 2026-08-31, HIGH). A bare `${path#$cfg/}` strip
  # records the LITERAL string, so `~/.claude/agents/../hooks/lib/session-writes.sh` — which the OS
  # resolves to a protected file — was recorded as `agents/../hooks/lib/...` and defeated every
  # `^hooks/` invariant-dir match downstream. Reproduced: a real edit to a protected file, rc=0, no
  # bite demanded. Resolving the DIRECTORY (the file itself may not exist yet on a Write) also fixes
  # the symlinked-HOME case, where the literal path and the physically-resolved config dir diverge
  # and containment silently failed. Falls back to the literal path if the dir cannot be resolved.
  _tw_dir="$(dirname "$_tw_fp")"
  _tw_base="$(basename "$_tw_fp")"
  _tw_dirp="$(cd "$_tw_dir" 2>/dev/null && pwd -P || true)"
  [ -n "$_tw_dirp" ] && _tw_fp="${_tw_dirp}/${_tw_base}"
  if [ -n "$_tw_cfgp" ]; then
    case "$_tw_fp" in
      "$_tw_cfgp"/*)
        _tw_rel="${_tw_fp#"$_tw_cfgp"/}"
        # Same self-artifact skip the git path applies below: never record BITE_LEDGER_*/AGENT_REVIEW_*
        # etc., or writing the ledger would itself read as an invariant-file change.
        _tw_apr="${V_ARTIFACT_PREFIX_REGISTRY:-$HOME/.claude/hooks/lib/artifact-prefix-registry.sh}"
        if [ -f "$_tw_apr" ] && . "$_tw_apr" 2>/dev/null && [ -n "${V_ARTIFACT_PREFIX_PATH_RE:-}" ]; then
          if printf '%s' "$_tw_rel" | grep -qE "$V_ARTIFACT_PREFIX_PATH_RE"; then profile_done; exit 0; fi
        fi
        case "$_tw_rel" in *$'\n'*|'') profile_done; exit 0 ;; esac
        _tw_log="$(. "$HOOKS_LIB_DIR/session-writes.sh" 2>/dev/null && session_writes_ecosystem_log_path "$SESSION_ID" 2>/dev/null || true)"
        if [ -n "$_tw_log" ]; then
          mkdir -p "$(dirname "$_tw_log")" 2>/dev/null || true
          # Same 1 MB growth cap as the git-backed log.
          if [ -f "$_tw_log" ]; then
            _tw_sz=$(wc -c < "$_tw_log" 2>/dev/null | tr -d ' ')
            case "$_tw_sz" in (''|*[!0-9]*) _tw_sz=0 ;; esac
            [ "$_tw_sz" -ge 1048576 ] && { profile_done; exit 0; }
          fi
          printf '%s\n' "$_tw_rel" >> "$_tw_log" 2>/dev/null || true
        fi
        ;;
    esac
  fi
  profile_done
  exit 0
fi

# W83-F5: prefer cached git paths (one rev-parse per SID per repo per 60s).
resolve_git_paths
REPO_ROOT="$GIT_ROOT"
[ -n "$REPO_ROOT" ] || exit 0

# Normalize to repo-relative path so it matches git output. Only paths that
# live inside the current repo are recorded — out-of-repo writes (e.g., to
# ~/.claude/ or /tmp/) cannot affect this repo's artifact gates and would
# only create false positives if the hook's consumers grep for code
# extensions.
case "$FILE_PATH" in
  "$REPO_ROOT"/*) REL_PATH="${FILE_PATH#$REPO_ROOT/}" ;;
  /*)
    # C-3 (round-3 2026-07-02, strand): membership by REPO-ROOT PATH PREFIX is blind to the
    # EXTERNAL worktree convention (~/.claude/worktrees/<repo>/…) — a worktree session's every Edit was
    # silently dropped here as "outside repo", its ledger held only [subagent-dispatch] rows, and the P12
    # absorption gate then false-blocked its own commit as foreign (a finished, review-approved
    # multi-file feature stranded uncommitted). Same class as the drain's R18 external-path fix: membership = SAME
    # git-common-dir, never a path shape. If the file's own repo shares this repo's common dir, record it
    # relative to ITS worktree top-level — worktree-toplevel-relative IS repo-relative, the same invariant
    # CANARY-C below maintains for in-repo worktrees (no .worktrees/ prefix exists on this path shape).
    # pwd -P canonicalizes both sides (symlinked tmp dirs, /var→/private/var). A file whose dir doesn't
    # exist yet or whose repo differs stays ignored — behavior for genuinely-outside paths is unchanged.
    # env -u GIT_*: git-path-cache exports RELATIVE GIT_DIR=.git / GIT_COMMON_DIR=.git, and git honors
    # BOTH as env overrides of discovery — `git -C <worktree-dir>` then resolves them against the NEW cwd
    # and dies ("not a git repository"). The membership probe must rediscover from the file's own dir with
    # a clean git env (verified live: with only GIT_DIR unset, the exported GIT_COMMON_DIR still broke
    # linked-worktree discovery).
    # CYCLE-2 F-2: canonicalize the file's DIR first (git returns --show-toplevel canonicalized, so a
    # raw FILE_PATH reached via a symlinked ancestor — /var vs /private/var, symlinked mounts — passes
    # the membership check but misses the toplevel prefix-strip and gets silently dropped). All later
    # comparisons use the canonical dir + basename.
    _fdir="${FILE_PATH%/*}"
    _fdir="$(cd "$_fdir" 2>/dev/null && pwd -P || true)"
    [ -n "$_fdir" ] || exit 0                                  # dir doesn't exist (yet) — cannot attribute; ignore
    _fcanonpath="$_fdir/${FILE_PATH##*/}"
    _fcommon="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$_fdir" rev-parse --git-common-dir 2>/dev/null || true)"
    [ -n "$_fcommon" ] || exit 0
    case "$_fcommon" in /*) ;; *) _fcommon="$_fdir/$_fcommon" ;; esac
    _fcanon="$(cd "$_fcommon" 2>/dev/null && pwd -P || true)"
    _mycanon="$(cd "${GIT_COMMON_DIR:-.git}" 2>/dev/null && pwd -P || true)"
    { [ -n "$_fcanon" ] && [ "$_fcanon" = "$_mycanon" ]; } || exit 0   # different/unknown repo — ignore
    _ftop="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$_fdir" rev-parse --show-toplevel 2>/dev/null || true)"
    case "$_fcanonpath" in
      "$_ftop"/*) [ -n "$_ftop" ] || exit 0; REL_PATH="${_fcanonpath#$_ftop/}" ;;
      *) exit 0 ;;
    esac
    ;;
  *)              REL_PATH="$FILE_PATH" ;;  # already relative (cwd must be in repo)
esac

# CANARY-C (F-ROOT, forensic 2026-06-22): a worktree session edits files at <main>/.worktrees/<name>/<rel>,
# so REL_PATH above carries a ".worktrees/<name>/" prefix while git diff/diff-tree and the staged set are
# REPO-RELATIVE. The canonical writes-log (shared via GIT_COMMON_DIR across all worktrees) MUST store
# repo-relative paths so the P12 commit gate, gather commit-attribution, dirty-tree filter, and files_changed
# all match. The prefix caused P12 false-blocks, "sibling file leakage", and dropped worktree-commit
# attribution (3-canary forensic). Strip the worktree prefix at the producer.
case "$REL_PATH" in
  .worktrees/*/*)
    # CANARY-C2 (forensic 2026-06-27, hardened by review SREV-002): the worktree layout is MIXED — FLAT
    # `.worktrees/<wt>/<rel>` AND NESTED `.worktrees/<type>/<wt>/<rel>` coexist; a FIXED-depth strip is wrong for
    # one (the old 1-level left `<slug>/app/...` on a NESTED path -> one session ate P12 false-blocks; a blanket
    # 2-level over-strips a FLAT path to `Foo.php`). Classify by whether the SECOND `.worktrees/` segment is itself
    # a worktree (carries `.git`): TRUE only for NESTED (its 2nd segment IS the worktree). For FLAT the 2nd segment
    # is a repo dir (app/, resources/, tests/...) which never carries `.git` — so this stays correct for a FLAT
    # worktree even while its OWN `.git` is mid-prune (the flat-prune race a 1st-level probe would mis-strip).
    # REPO_ROOT is the MAIN root whenever this prefix is present (that is why it appears, per CANARY-C above).
    # Residuals (rare): a NESTED worktree whose leaf `.git` is mid-prune falls back to FLAT; a 3+-level layout
    # (none exist — /v uses at most <type>/<slug>) would leave one segment. Add a deeper probe if either appears.
    _seg1="${REL_PATH#.worktrees/}"; _seg1="${_seg1%%/*}"
    _rest="${REL_PATH#.worktrees/*/}"; _seg2="${_rest%%/*}"
    if [ -e "$REPO_ROOT/.worktrees/$_seg1/$_seg2/.git" ]; then
      REL_PATH="${REL_PATH#.worktrees/*/*/}"    # NESTED: .worktrees/<type>/<wt>/<rel> -> strip two levels
    else
      REL_PATH="${REL_PATH#.worktrees/*/}"      # FLAT: .worktrees/<wt>/<rel> -> strip one level (robust to flat-prune)
    fi ;;
esac

# Reject paths containing newlines — they break line-based log parsing and
# are pathological in practice.
case "$REL_PATH" in
  *$'\n'*) exit 0 ;;
esac

# Empty path after normalization — nothing to record.
[ -n "$REL_PATH" ] || exit 0

# W53-F2 (producer-side defense-in-depth — mirrors lib/session-writes.sh F0).
# Skip self-written session artifacts. PreToolUse fires for the agent's own
# writes of PRE_FLIGHT_REPORT_<sid>.md / AGENT_REVIEW_<sid>.md / etc.
# Recording these pollutes session-attribution downstream (verify-done would
# treat them as session-modified files).
case "$REL_PATH" in
  *AGENT_REVIEW_*|*AGENT_REVIEW_ADDENDUM_*|*PRE_FLIGHT_*|*VERIFY_DONE_REPORT_*|*UX_CRITIQUE_*|*HANDOFF_*|*BLOCKED_*|*IMPLEMENTATION_REPORT_*|*SESSION_LOG_*|*PROGRESS_NOTE_*|*PLAN_*|*AUDIT_REPORT_*|*REFACTOR_PLAN_*|*POLISH_PLAN_*|*BUILD_BLOCKER_*|*LAUNCH_CHECKLIST_*|*LAUNCH_PLAN_*|*GAUNTLET_*|*ADMIN_AUDIT_REPORT_*|*QA_REPORT_*|*QA_REMEDIATION_*|*QA_ADDENDUM_*|*IMPACT_MAP_*|*TRIVIAL_PASS_*|*PLANNING_PASS_*|*WORKFLOW_VERIFICATION_*|*WORKFLOW_VERIFICATION_ADDENDUM_*|*SUCCESS_CRITERIA_*|*WORKFLOW_BLAST_RADIUS_*|*SID_COLLISION_*|*STOP_LIVELOCK_*|*BITE_LEDGER_*|*ABANDON_SUSPECT_*|*BILLING_REVIEWED_*|*AGENT_REVIEW_STAGED_*|*CYCLE_CAP_HANDOFF_*|*WORKTREE_HANDOFF_*|*REVIEW_DEBT_*|*FND3_ORPHAN_ESCAPE_*|*ACTIVATION_FUNNEL_*|*PRICING_STRATEGY_*|*BETA_PROGRAM_*|*ILLUSTRATION_SYSTEM_*|*SKILL_REVIEW_REPORT_*|*CONSOLIDATED_AUDIT_REPORT_*|*SELF_AUDIT_SUMMARY_*|*LEGAL_AUDIT_*|*DIFFERENTIATION_BRIEF_*|*TRAFFIC_PLAN_*|*PROD_TRIAGE_*|*V_NEXT_REPORT_*)
    # P3-REGISTRY (2026-07-03): the case-glob above is only a cheap PRE-FILTER (hot path);
    # the authoritative prefix set + anchored UUID-suffix shape come from the single-source
    # registry (hooks/lib/artifact-prefix-registry.sh) — this file's copy had drifted from
    # session-writes.sh's (missed QA_REPORT/IMPACT_MAP/TRIVIAL_PASS/SID_COLLISION/…).
    # Registry missing → legacy anchored UUID-suffix grep (same fail-open direction as before).
    # Parity: hooks/p3-artifact-prefix-registry-test.sh.
    _APR_LIB="${V_ARTIFACT_PREFIX_REGISTRY:-$HOME/.claude/hooks/lib/artifact-prefix-registry.sh}"
    if [ -f "$_APR_LIB" ] && . "$_APR_LIB" 2>/dev/null && [ -n "${V_ARTIFACT_PREFIX_PATH_RE:-}" ]; then
      if echo "$REL_PATH" | grep -qE "$V_ARTIFACT_PREFIX_PATH_RE"; then
        profile_done
        exit 0
      fi
    elif echo "$REL_PATH" | grep -qE '_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(\.[a-z]+)?\.(md|yaml|yml|json)$'; then
      profile_done
      exit 0
    fi
    ;;
esac

# W53-F2: skip paths containing unexpanded shell metacharacters. A production
# session recorded a literal $$ from a v-session-log heredoc that
# didn't expand. M1: low-risk false-positive on user files containing literal
# $( in their names — rare in practice. Worst case: that single write is not
# tracked; the consumer-side F0 filter catches it again downstream.
# The actual emit-site bug is tracked separately as W53-INV1.
case "$REL_PATH" in
  *'$$'*|*'$('*|*'${'*|*'$RANDOM'*) exit 0 ;;
esac

# W83-F5: GIT_COMMON_DIR already populated by resolve_git_paths above
# (falls back to GIT_DIR internally when --git-common-dir is unsupported).
[ -n "$GIT_COMMON_DIR" ] || exit 0
WRITES_FILE="${GIT_COMMON_DIR}/claude-session-writes-${SESSION_ID}.txt"

# Log growth cap (1 MB). Beyond this we stop appending — the session has
# written so many distinct files that missing a few more won't meaningfully
# change the attribution signal. Prevents runaway growth if a pathological
# loop writes the same file 100k times.
MAX_LOG_BYTES=1048576
if [ -f "$WRITES_FILE" ]; then
  _size=$(wc -c < "$WRITES_FILE" 2>/dev/null | tr -d ' ')
  if [ -n "$_size" ] && [ "$_size" -ge "$MAX_LOG_BYTES" ]; then
    profile_done
    exit 0
  fi
fi

# Single-line append is atomic on POSIX when the write is smaller than
# PIPE_BUF (4096 bytes on macOS/Linux) and the fd is opened with O_APPEND
# (which `>>` guarantees). A typical path is <256 bytes, so concurrent
# subagent writes to the same log do not interleave. Dedup happens on read
# in get_session_writes(), not on write — keeps this hook fast.
#
# Verified empirically: subagents dispatched via the Task tool write to the
# PARENT session's log, not a separate subagent log. Claude Code passes the
# parent session_id to PreToolUse hooks even for subagent tool calls.
printf '%s\n' "$REL_PATH" >> "$WRITES_FILE" 2>/dev/null || true

# P3-14 (plan item 14, "EMITTED" class fix): a 0-turn-parent skill fork writes real code but the
# PARENT session's own Stop event carries no signal the check-review-artifact.sh gauntlet gate
# listens on (its own transcript reads as trivial/empty), so the gauntlet is never even evaluated
# for that SID — worse than a block, it is INVISIBLE. Anchor the obligation at the ONE event that
# fires unconditionally whenever code is actually written, independent of transcript/turn shape:
# this PreToolUse hook. First qualifying write for a SID writes a durable GAUNTLET_OWED_<sid>.md
# marker (idempotent — do not refresh its timestamp on every write, only the FIRST write's time
# matters for staleness) so a later sweep (v-session-log-integrity.sh) can detect "this SID wrote
# code and NOTHING ever evaluated its gauntlet obligation" even when that SID's own Stop hook never
# ran the check. Best-effort/advisory: failure to write this marker never blocks the tool call.
if [ -n "$REPO_ROOT" ]; then
  _p314_dir="$REPO_ROOT/.v/artifacts"
  _p314_marker="$_p314_dir/GAUNTLET_OWED_${SESSION_ID}.md"
  if [ ! -f "$_p314_marker" ]; then
    # P3-14b (forensic 2026-07-10): anchor the obligation ONLY on real
    # CODE writes. The marker's own body asserts "wrote code", but this mint had zero extension
    # awareness — pack-writer/agent-memory sessions (.txt / .claude/agent-memory/*.md only) minted
    # false debt that the integrity sweep then escalated into false GAUNTLET_SKIPPED alarms
    # ("Session wrote code" — factually wrong). Use the SAME single-source pattern pair every
    # gauntlet consumer uses (hooks/lib/code-ext-pattern.sh). Fail direction: if the lib is
    # missing/unreadable, mint anyway (old behavior — never silently drop real debt). Cost note:
    # this branch runs only while the marker is absent, so it adds one lib source + two greps per
    # write ONLY for sessions that have not yet written code — sub-ms, off the steady-state path.
    _p314_ce="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}/code-ext-pattern.sh"
    if [ -z "${CODE_EXT_PATTERN:-}" ] && [ -f "$_p314_ce" ]; then
      # shellcheck disable=SC1090
      . "$_p314_ce" 2>/dev/null || true
    fi
    if [ -n "${CODE_EXT_PATTERN:-}" ]; then
      if ! printf '%s\n' "$REL_PATH" | grep -qE "$CODE_EXT_PATTERN" \
         || printf '%s\n' "$REL_PATH" | grep -qE "${CODE_EXT_EXEMPT:-^$}"; then
        profile_done
        exit 0
      fi
    fi
    mkdir -p "$_p314_dir" 2>/dev/null || true
    {
      printf '# GAUNTLET OWED — %s\n\n' "$SESSION_ID"
      printf 'sid: %s\n' "$SESSION_ID"
      printf 'first_write_path: %s\n' "$REL_PATH"
      printf 'first_write_at: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
      printf '\nThis SID wrote code via a tool call. If PRE_FLIGHT_REPORT/AGENT_REVIEW/VERIFY_DONE_REPORT\n'
      printf 'never materialize for this SID and this marker goes stale, the periodic integrity sweep\n'
      printf '(v-session-log-integrity.sh) will surface it as a GAUNTLET_SKIPPED marker — this is the\n'
      printf 'anchor that makes that possible even when this SID never triggers its own Stop hook (the\n'
      printf '0-turn-parent skill-fork class, plan item 14).\n'
    } > "$_p314_marker" 2>/dev/null || true
  fi
fi

profile_done
exit 0
