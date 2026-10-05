#!/usr/bin/env bash
# v-suite-lock.sh — cross-session serialization for the HEAVY full test suite.
#
# Usage:
#   bash v-suite-lock.sh acquire <repo_path> <session_id> [timeout_s] [stale_s]
#   bash v-suite-lock.sh release <repo_path> <session_id>
#
# Why this exists (observed 2026-05-26): three concurrent /v sessions each ran a
# `full` pre-flight, and each `full` run launches a PARALLEL pest suite (paratest
# spawns N php workers). Two+ full suites at once OOM-kill workers mid-render
# (no "Tests:" tally → INFRA crash) and contend on CPU / the test database. The
# per-session caches were already isolated (HI-2), but the SUITES themselves had
# no cross-session lock. This serializes the heavy full suite repo-wide: the 2nd
# `full` run waits for the 1st to finish, instead of thrashing alongside it.
#
# Mechanism: atomic `mkdir` mutex (POSIX-portable). macOS has no `flock`
# (confirmed: "flock: command not found"), so — exactly as v-merge-back.sh's
# portable path — we use mkdir, whose failure-if-exists gives correct mutual
# exclusion. State is a filesystem directory, so acquire and release work across
# SEPARATE script invocations (acquire from the gate runner, release from its
# EXIT trap). The lock lives at the SHARED main-repo root (resolved via
# git-common-dir), so every worktree + inline session in one repo contends on the
# same lock.
#
# Fail-OPEN: acquire that can't get the lock within <timeout_s> prints
# `SUITE_LOCK=timeout-proceeding` and exits 0 — it NEVER blocks the gate forever.
# A crashed holder (SIGKILL, no EXIT-trap release) leaves a stale dir that the
# next acquire steals after <stale_s>. release is OWNER-CHECKED: a session that
# proceeded fail-open (someone else owns the lock) will NOT remove that owner's
# lock.
#
# Opt-out: V_NO_SUITE_LOCK=1 → acquire is an immediate no-op (exits 0).
#
# Exit code: always 0 (advisory primitive — must never break the gate runner).

set -uo pipefail

ACTION="${1:-}"
REPO_ARG="${2:-}"
SID="${3:-}"
TIMEOUT="${4:-1800}"   # waiter gives up + proceeds (fail-open) after this many seconds
STALE="${5:-3600}"     # steal a lock dir older than this (presumed-dead holder)

[ -n "$ACTION" ] || { echo "SUITE_LOCK=usage-error(no-action)"; exit 0; }
[ -n "$REPO_ARG" ] || { echo "SUITE_LOCK=usage-error(no-repo)"; exit 0; }
[ -d "$REPO_ARG" ] || { echo "SUITE_LOCK=usage-error(repo-not-dir)"; exit 0; }

# Resolve the SHARED main-repo root from any worktree OR the main checkout, so all
# sessions in one repo share ONE lock. git-common-dir is ".git" (relative) at the
# main root and "/abs/main/.git" (absolute) inside a worktree; its parent is the
# shared main repo root in both cases.
_shared_root() {
  local p="$1" cdir
  cdir=$(git -C "$p" rev-parse --git-common-dir 2>/dev/null) || { echo "$p"; return; }
  case "$cdir" in
    /*) : ;;
    *)  cdir="$(cd "$p" && cd "$cdir" 2>/dev/null && pwd)" || { echo "$p"; return; } ;;
  esac
  (cd "$cdir/.." 2>/dev/null && pwd) || echo "$p"
}

_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

SHARED="$(_shared_root "$REPO_ARG")"
LOCK_PARENT="$SHARED/.worktrees"
LOCK_DIR="$LOCK_PARENT/.suite-lock.d"
OWNER_FILE="$LOCK_DIR/owner"

case "$ACTION" in
  acquire)
    [ "${V_NO_SUITE_LOCK:-0}" = "1" ] && { echo "SUITE_LOCK=disabled"; exit 0; }
    mkdir -p "$LOCK_PARENT" 2>/dev/null || { echo "SUITE_LOCK=cannot-mkdir-parent-proceeding"; exit 0; }
    _start=$(date +%s)
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
      # Lock is held. Steal it if it's clearly stale (crashed holder).
      if [ -d "$LOCK_DIR" ]; then
        # DEAD-HOLDER fast path (cycle-2 F5 follow-up, 2026-07-04): OPT-IN ONLY. This lock is
        # session-owned across separate script invocations — acquire routinely runs in throwaway
        # $(...) subshells whose PID is dead-by-design while the SESSION still legitimately holds
        # the lock (v-perf3 regression: a naive dead-PID steal let B take A's live lock). The
        # steal therefore fires ONLY when the owner line carries the `holder-live` marker, written
        # exclusively when the acquirer passed V_SUITE_LOCK_HOLDER_PID (a PID it guarantees stays
        # alive for the whole hold — e.g. harness-test-sweep.sh passes its own $$). For such
        # holders, a dead PID proves a SIGKILL past the EXIT-trap release — reclaim NOW instead of
        # burning the wait-timeout. Guards: strictly numeric, >1, and an EMPTY/absent owner file
        # is never stealable this way (mid-acquire TOCTOU); the mtime backstop below covers those.
        _oline=$(awk 'NR==1{print}' "$OWNER_FILE" 2>/dev/null || echo "")
        _opid=$(printf '%s' "$_oline" | awk '{print $2}')
        _omark=$(printf '%s' "$_oline" | awk '{print $4}')
        if [ "$_omark" = "holder-live" ] && printf '%s' "$_opid" | grep -qE '^[0-9]+$' && [ "$_opid" -gt 1 ] 2>/dev/null && ! kill -0 "$_opid" 2>/dev/null; then
          echo "SUITE_LOCK=stealing-dead-holder(pid=${_opid})" >&2
          rm -rf "$LOCK_DIR" 2>/dev/null || true
          continue
        fi
        _age=$(( $(date +%s) - $(_mtime "$LOCK_DIR") ))
        if [ "$_age" -gt "$STALE" ]; then
          echo "SUITE_LOCK=stealing-stale(${_age}s>${STALE}s)" >&2
          rm -rf "$LOCK_DIR" 2>/dev/null || true
          continue
        fi
      fi
      # Wall-clock deadline (NOT iteration count — the steal-continue path skips the
      # sleep, so counting iterations would let the real timeout drift).
      if [ "$(( $(date +%s) - _start ))" -ge "$TIMEOUT" ]; then
        # Fail-open: do NOT block the gate forever. Proceed without the lock.
        _holder=$(awk 'NR==1{print $1}' "$OWNER_FILE" 2>/dev/null || echo unknown)
        echo "SUITE_LOCK=timeout-proceeding(${TIMEOUT}s,holder=${_holder})"
        exit 0
      fi
      sleep 1
    done
    # Owner line: `SID pid epoch [holder-live]`. The 4th field appears ONLY when the caller passed
    # V_SUITE_LOCK_HOLDER_PID — an explicit promise that this PID lives for the whole hold — and it
    # alone arms the dead-holder fast path above. Without the override, the recorded $$ (this
    # acquire subprocess, dead immediately) is kept for backward-compat/debugging and is NEVER
    # used for liveness (session-owned locks routinely outlive their acquiring subshell).
    if [ -n "${V_SUITE_LOCK_HOLDER_PID:-}" ] && printf '%s' "$V_SUITE_LOCK_HOLDER_PID" | grep -qE '^[0-9]+$'; then
      printf '%s %s %s holder-live\n' "$SID" "$V_SUITE_LOCK_HOLDER_PID" "$(date +%s)" > "$OWNER_FILE" 2>/dev/null || true
    else
      printf '%s %s %s\n' "$SID" "$$" "$(date +%s)" > "$OWNER_FILE" 2>/dev/null || true
    fi
    echo "SUITE_LOCK=acquired"
    exit 0
    ;;
  release)
    if [ -d "$LOCK_DIR" ]; then
      _owner=$(awk 'NR==1{print $1}' "$OWNER_FILE" 2>/dev/null || echo "")
      # Only remove a lock we EXPLICITLY own. Skip if another session owns it (we
      # proceeded fail-open) OR the owner file is empty/unwritten — an empty owner
      # can mean a holder mid-acquire (TOCTOU between mkdir-win and owner-write), and
      # deleting it would steal a live lock. A genuinely dead lock is reclaimed by
      # the stale-steal path instead, so skipping here is always safe.
      if [ -n "$_owner" ] && [ "$_owner" = "$SID" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        echo "SUITE_LOCK=released"
      else
        echo "SUITE_LOCK=not-owner-skip-release(owner=${_owner:-none})"
      fi
    else
      echo "SUITE_LOCK=already-clear"
    fi
    exit 0
    ;;
  *)
    echo "SUITE_LOCK=usage-error(bad-action:${ACTION})"
    exit 0
    ;;
esac
