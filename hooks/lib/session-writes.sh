#!/usr/bin/env bash
# lib/session-writes.sh
# Shared helpers for the per-session write log produced by track-session-writes.sh.
#
# Stop hooks should call get_session_writes() instead of inferring "what this
# session changed" from git state. Git state is shared across parallel sessions
# and cannot be used for session attribution; the writes log is the
# authoritative source of "what THIS session's tools wrote".
#
# Storage location: ${git_common_dir}/claude-session-writes-${SESSION_ID}.txt
# (anchored to .git so it survives cwd changes between main + worktrees and is
# immune to /tmp cleanup races)

# get_session_writes <session_id>
# Echoes deduped, sorted list of repo-relative paths this session wrote.
# Filters out:
#   - empty lines
#   - lines containing control characters (defense against log corruption)
#   - absolute paths (defense — track-session-writes.sh already skips these,
#     but old logs may still contain them)
# Returns 0 (with possibly empty output) if log exists.
# Returns 1 if SESSION_ID empty, .git unavailable, or log file missing.
get_session_writes() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  local git_dir
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null || true)
  [ -n "$git_dir" ] || return 1
  local writes_file="${git_dir}/claude-session-writes-${sid}.txt"
  [ -f "$writes_file" ] || return 1
  # Filter: drop empty lines, lines starting with '/' (absolute paths that
  # slipped in from pre-hardening versions), and anything with control chars.
  # W52-F0: filter session-writes log to drop:
  #   1. Empty lines (W47-A original)
  #   2. Absolute paths (W47-A original — old logs may contain them)
  #   3. Control chars (W47-A defense against log corruption)
  #   4. Session artifacts the agent self-wrote with canonical UUID-suffix
  #      shape (a session had AGENT_REVIEW_<sid>.md etc. in
  #      its writes log — pollutes session-attribution downstream)
  #   5. Unexpanded shell-meta paths (track-session-writes.sh recorded a
  #      literal `$(date +%s)` token from a v-session-log skill bug —
  #      these aren't real files; band-aid until the source is fixed)
  # The artifact-prefix regex requires UUID-shape suffix to avoid
  # false-positive matches against legitimate user files (e.g.,
  # tests/PLAN_helper.md would NOT match because it lacks a UUID).
  # P3-REGISTRY (2026-07-03): the artifact-prefix set is SINGLE-SOURCED in
  # hooks/lib/artifact-prefix-registry.sh — this copy and track-session-writes.sh's had
  # already drifted (both missed QA_REPORT/IMPACT_MAP/TRIVIAL_PASS/SESSION_LOG_MISSING/
  # SID_COLLISION). Registry missing → fall back to the last inline set (fail-open in the
  # SAFE direction: unfiltered artifacts only ADD noise to attribution, never hide writes).
  # Parity: hooks/p3-artifact-prefix-registry-test.sh.
  local _apr_lib="${V_ARTIFACT_PREFIX_REGISTRY:-$HOME/.claude/hooks/lib/artifact-prefix-registry.sh}"
  local _apr_alt='AGENT_REVIEW|PRE_FLIGHT_REPORT|VERIFY_DONE_REPORT|UX_CRITIQUE|HANDOFF|BLOCKED|IMPLEMENTATION_REPORT|SESSION_LOG|PROGRESS_NOTE|PLAN|AUDIT_REPORT|REFACTOR_PLAN|POLISH_PLAN|BUILD_BLOCKER|LAUNCH_CHECKLIST|GAUNTLET_REPORT|ADMIN_AUDIT_REPORT'
  if [ -f "$_apr_lib" ]; then
    # shellcheck source=/dev/null
    . "$_apr_lib" 2>/dev/null && [ -n "${V_ARTIFACT_PREFIX_ALTERNATION:-}" ] && _apr_alt="$V_ARTIFACT_PREFIX_ALTERNATION"
  fi
  # The UUID is spelled out without {n} intervals: mawk before 1.3.4-20200717 (Debian 12,
  # Ubuntu 22.04) reads `{8}` literally, so the filter would silently stop matching.
  local _h='[0-9a-f]' _h4
  _h4="$_h$_h$_h$_h"
  LC_ALL=C awk -v apre="(^|/)(${_apr_alt})_${_h4}${_h4}-${_h4}-${_h4}-${_h4}-${_h4}${_h4}${_h4}(\\.[a-z]+)?\\.(md|yaml|yml|json)$" '
    /^$/ { next }
    /^\// { next }
    /[[:cntrl:]]/ { next }
    # H1 phase-2 review-fix: anchor on basename so subdir artifacts (e.g.
    # .v/reports/AGENT_REVIEW_<sid>.md) are also filtered. The original ^-anchor
    # only caught artifacts at repo-root. P3-REGISTRY: alternation injected via -v
    # from the single-source registry (dynamic regex; awk ERE semantics unchanged).
    match($0, apre) { next }
    /\$\(/ { next }
    /\$\$/ { next }
    /\$\{/ { next }
    { print }
  ' "$writes_file" 2>/dev/null | LC_ALL=C sort -u 2>/dev/null
}

# session_wrote_code <session_id> <ext_pattern>
# Returns 0 if any session-written path matches the code extension pattern.
# Returns 1 if no log or no matches.
session_wrote_code() {
  local sid="${1:-}"
  local ext_pattern="${2:-}"
  [ -n "$sid" ] || return 1
  [ -n "$ext_pattern" ] || return 1
  local writes
  writes=$(get_session_writes "$sid") || return 1
  [ -n "$writes" ] || return 1
  echo "$writes" | grep -qE "$ext_pattern"
}

# files_attributable_to_other_sessions <my_sid>
# Reads candidate repo-relative paths from stdin; echoes the subset that appears
# in ANOTHER session's writes-log (proving a sibling session authored them) but
# NOT in <my_sid>'s own writes-log.
#
# This is the high-precision "commit absorption" signal (forensic 2026-06-20,
# observed): a session that `git add`-ed into the SHARED index but did
# NOT commit leaves its files staged; the NEXT session's commit sweeps them in.
# A staged file PROVABLY authored by a sibling = absorption. Files authored by
# nobody-tracked (in NO writes-log) are deliberately NOT flagged — they could be
# this session's own untracked-but-legit work; only positively-foreign files trip.
#
# SREV-004 (adversarial review 2026-06-20): NO recency cap. The earlier version consulted only the 60
# most-recent sibling logs by mtime — but a busy repo accumulates THOUSANDS of writes-logs, and a staged
# file authored by an OLDER sibling (its log far outside the 60) would slip through. This version scans
# ALL sibling logs in a single `grep` per candidate (one process over N small files — faster than 60×
# get_session_writes, and complete). Always returns 0; empty output = no foreign files.
files_attributable_to_other_sessions() {
  local my_sid="${1:-}"
  local git_dir
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null || true)
  if [ -z "$git_dir" ] || [ -z "$my_sid" ]; then cat >/dev/null 2>&1; return 0; fi
  local mine
  mine=$(get_session_writes "$my_sid" 2>/dev/null || true)
  # SREV-001 FAIL-OPEN: if THIS session authored nothing trackable (no writes-log at all, or an empty
  # one — e.g. a Bash-only session that `git add`-ed its own regeneration without ever invoking
  # Edit/Write), we CANNOT distinguish absorption from legitimate own-work staging. Flagging
  # everything-in-a-sibling-log would false-block that commit. Return nothing (the P12 guard then does
  # not fire); a genuine absorber that authored real files still has a non-empty `mine` and is caught.
  [ -n "$(printf '%s' "$mine" | tr -d '[:space:]')" ] || { cat >/dev/null 2>&1; return 0; }
  local _my_log="$git_dir/claude-session-writes-${my_sid}.txt"
  # C-4b (round-3 2026-07-02, false-block): only PLAUSIBLY-ACTIVE sessions' ledgers count as
  # absorption evidence. 1,282 never-GC'd historical ledgers made frequently-touched paths "foreign"
  # forever — two long-merged sessions' rows blocked a live session's own commit. ACTIVE = ledger mtime
  # within V_P12_FOREIGN_MAX_AGE_DAYS (default 7) OR its SID owns a registered-worktree lock with a
  # live/unresolvable PID (unresolvable → treat live: keeping evidence fails toward BLOCKING, the safe
  # direction for an absorption guard). Lock parsing via the SHARED session-lock-parse lib (never raw awk
  # — the kv-format data-loss lesson); parser unavailable → liveness contributes nothing, recency still works.
  # SREV-004 interplay: that review removed a top-60-BY-MTIME COUNT cap because an older sibling's file
  # could slip past an arbitrary truncation. This is a different shape: a principled activity predicate
  # (time window + lock liveness), and its residual — a >7-day-dead session's STILL-STAGED shared-index
  # file absorbing silently — is the same residual C-5's ledger GC already accepts; the observed harm ran
  # the other way (false-blocks stranding finished work). My own log always stays in the candidate set
  # (excluded per-match below, exactly as before).
  local _f _fsid _live_sids _wt _lpid _lsid
  local _kl=()
  _live_sids=" "
  if command -v _lock_sid >/dev/null 2>&1 || { [ -f "${BASH_SOURCE[0]%/*}/session-lock-parse.sh" ] && . "${BASH_SOURCE[0]%/*}/session-lock-parse.sh" 2>/dev/null && command -v _lock_sid >/dev/null 2>&1; }; then
    while IFS= read -r _wt; do
      [ -n "$_wt" ] && [ -f "$_wt/.claude-session-lock" ] || continue
      _lpid="$(_lock_pid "$_wt/.claude-session-lock" 2>/dev/null || true)"
      case "$_lpid" in
        ''|*[!0-9]*) : ;;                                    # unresolvable pid → keep as live (fail-safe)
        *) kill -0 "$_lpid" 2>/dev/null || continue ;;       # provably dead → not live
      esac
      _lsid="$(_lock_sid "$_wt/.claude-session-lock" 2>/dev/null || true)"
      [ -n "$_lsid" ] && _live_sids="${_live_sids}${_lsid} "
    done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  fi
  # CYCLE-2 F-1 (adversarial review, measured): a per-file `stat` fork here cost ~4.4s per `git commit`
  # at the real 1,282-ledger corpus (~75x the pre-fix single-grep). ONE bulk `find -newermt` pass (7ms
  # measured on this machine) replaces every stat. If find errors (flag unsupported), fail toward
  # PRE-FIX STRENGTH — keep ALL ledgers — never toward silently dropping recent sibling evidence.
  local _recent_list
  if ! _recent_list="$(find "$git_dir" -maxdepth 1 -name 'claude-session-writes-*.txt' -newermt "-${V_P12_FOREIGN_MAX_AGE_DAYS:-7} days" 2>/dev/null)"; then
    _recent_list="$(printf '%s\n' "$git_dir"/claude-session-writes-*.txt)"
  fi
  while IFS= read -r _f; do
    [ -n "$_f" ] && [ -f "$_f" ] && _kl+=("$_f")
  done <<< "$_recent_list"
  [ -f "$_my_log" ] && _kl+=("$_my_log")                      # mine always in the set (dups harmless to grep -l)
  for _fsid in $_live_sids; do
    _f="$git_dir/claude-session-writes-${_fsid}.txt"
    [ -f "$_f" ] && _kl+=("$_f")                              # live-locked SIDs' ledgers kept regardless of age
  done
  local cand _matching_logs
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    # Authored by me too (shared edit) → not pure absorption; skip.
    printf '%s\n' "$mine" | grep -qxF -- "$cand" && continue
    # Logs that contain `cand` as a WHOLE LINE. SREV-F1 (review 2026-06-20): capture this FIRST and skip
    # when EMPTY. If `cand` is in no writes-log (externally created — vim/cp/codegen, not Edit/Write), it
    # is NOT provably foreign (could be this session's own untracked work). Piping an empty `grep -l`
    # straight into `grep -qvxF` would exit 0 VACUOUSLY (zero lines fail the -v filter) and FALSE-FLAG it,
    # blocking a legit commit. Empty keep-list ⇒ nothing is provably foreign (subsumes the old nullglob note).
    [ "${#_kl[@]}" -gt 0 ] || continue
    _matching_logs=$(grep -lxF -- "$cand" "${_kl[@]}" 2>/dev/null || true)
    [ -n "$_matching_logs" ] || continue
    # Foreign iff at least one matching log is NOT mine.
    printf '%s\n' "$_matching_logs" | grep -qvxF -- "$_my_log" && printf '%s\n' "$cand"
  done
}

# session_writes_log_path <session_id>
# Echoes the absolute path of the writes log for this session (whether or not
# it exists). Used by cleanup hooks (worktree-remove.sh, session-env-check.sh).
# session_writes_ecosystem_log_path <sid>
# The per-session writes log for a NON-GIT tree — specifically the config dir (~/.claude), which is
# deliberately never git-init'd.
#
# WHY THIS EXISTS (measured 2026-08-29/31). session_writes_log_path() below returns 1 unless
# `git rev-parse --git-common-dir` succeeds, so in ~/.claude no writes log path resolves at all.
# Consequences, verified by driving the REAL Stop hook against a session that had just edited nine
# files under hooks/, hooks/lib/ and skills/v/references/: WRITES_LOG_AVAILABLE=0, CODE_CHANGED
# stayed 0, and check-review-artifact.sh exited 0 with ZERO output. The P2-BITE-LEDGER gate is
# itself gated on CODE_CHANGED -eq 1, so the bite gate — whose entire purpose is TDD evidence for
# changes under hooks/, hooks/lib/, skills/v/references/ and scripts/ — could never fire in the very
# tree those four directories live in. A BITE_LEDGER there was voluntary discipline, not enforcement.
#
# SCOPE, DELIBERATELY NARROW: this path is consumed ONLY by the bite gate. It is NOT wired into
# session_writes_log_path() or get_session_writes(), because CODE_CHANGED is derived from those and
# flipping it to 1 in ~/.claude would escalate IS_V_SESSION (check-review-artifact.sh:1053) and
# demand the full 5-artifact gauntlet from every ecosystem-maintenance session — contradicting
# CLAUDE.md's routing, which puts that work in the DIRECT lane. So this change can only ever ADD a
# block (bite evidence now required where it already should have been); it can never remove one.
session_writes_ecosystem_log_path() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  case "$sid" in *[!0-9a-fA-F-]*|'') return 1 ;; esac   # SID is UUID-shaped; never build a path from junk
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  [ -n "$cfg" ] && [ -d "$cfg" ] || return 1
  printf '%s/runtime/session-writes/claude-session-writes-%s.txt\n' "$cfg" "$sid"
}

session_writes_log_path() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 1
  local git_dir
  git_dir=$(git rev-parse --git-common-dir 2>/dev/null || git rev-parse --git-dir 2>/dev/null || true)
  [ -n "$git_dir" ] || return 1
  printf '%s/claude-session-writes-%s.txt\n' "$git_dir" "$sid"
}
