#!/usr/bin/env bash
# stop-drain-deferred-merges.sh — Stop + SessionStart hook (W71-F2, forensic 2026-07-02).
#
# THE GAP THIS CLOSES: v-drain-deferred-merges.sh (built 2026-07-01) had exactly ONE
# automated caller — run-v-packs' end-of-run block. Interactive multi-terminal /v
# fleets had NO drain trigger at all, so on 2026-07-02 several gauntlet-complete
# sessions deferred their merge-backs into a cyclic deferral graph (each waiting on
# another) and EVERYTHING stranded: perfect gauntlets, empty main.
# Same "wired in only one context" failure shape as the 2026-06 settings.headless
# root cause. This hook gives interactive sessions a landing owner:
#   - Stop:         the last live session out drains its dead siblings' deferred work
#   - SessionStart: the next session into the repo drains whatever was left behind
#
# SAFETY MODEL (never weakened here — the drain and merge-back own it):
#   - v-drain-deferred-merges.sh skips ALIVE sessions (lock_alive: kill-0 +
#     SID-transcript-mtime + pgrep union) and gates every land on the C-1 verdict
#     gate; each merge still goes through v-merge-back.sh's lock/ownership guards.
#   - This hook adds only TRIGGER conditions: deferred markers exist AND no other
#     /v session is provably live. It runs the drain DETACHED (a Stop hook must
#     never block on merges) and ALWAYS exits 0 (advisory; fail-open).
#   - Note: the CURRENT session's own deferred worktree is intentionally NOT
#     landed by its own Stop (its lock is alive) — it lands via the next
#     SessionStart / a later Stop once its liveness lapses. Safe > eager.
#
# Env:
#   V_STOP_DRAIN=off            kill switch
#   V_STOP_DRAIN_SCRIPT=<path>  drain-script seam (tests)
#   V_STOP_DRAIN_THROTTLE_SEC   min seconds between attempts per repo (default 600)
set -uo pipefail
trap 'exit 0' ERR

[ "${V_STOP_DRAIN:-on}" = "off" ] && exit 0

# Consume stdin (hook JSON) — best-effort SID for sibling self-exclusion.
_IN=$(cat 2>/dev/null || true)
SID=""
if command -v jq >/dev/null 2>&1; then
  SID=$(printf '%s' "$_IN" | jq -r '.session_id // empty' 2>/dev/null || true)
fi
SID="${SID:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"

# Resolve the MAIN root (worktree-safe: a linked worktree's markers live in the
# main root's .v/, and the drain wants the main root).
REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$REPO_TOP" ] || exit 0
COMMON=$(git -C "$REPO_TOP" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$COMMON" in
  /*) MAIN_ROOT=$(dirname "$COMMON") ;;
  *)  MAIN_ROOT=$(cd "$REPO_TOP/$(dirname "$COMMON")" 2>/dev/null && pwd) ;;
esac
[ -n "${MAIN_ROOT:-}" ] && [ -d "$MAIN_ROOT" ] || exit 0

# Fast path: nothing deferred → nothing to do (this is the per-Stop hot path;
# one find over two dirs, no git calls beyond the two above).
# `|| true` neutralizes pipefail's SIGPIPE from `head` closing early — under the
# ERR trap that non-zero would otherwise silently fail-open PAST the drain.
_markers=$(find "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" -maxdepth 1 -name 'merge-deferred-*.md' 2>/dev/null | head -1 || true)
if [ -z "$_markers" ]; then
  # FND-3 re-driver probe (2026-07-04): a gauntleted branch whose WORKTREE IS GONE has no marker —
  # without this, the fast path exits and the strand is invisible to every event trigger. The probe
  # is read-only and cheap-first (2 git calls when the repo has no SID-tail branches). strands>0 ⇒
  # fall through to the normal trigger chain (throttle + sibling gates + detached drain, which
  # re-attaches and lands via its own C-1/merge-back gates). Kill switch: V_STOP_DRAIN_REDRIVE=off.
  _RD="${V_STOP_DRAIN_REDRIVE:-$HOME/.claude/skills/v/references/v-strand-redrive.sh}"
  [ "$_RD" != "off" ] && [ -f "$_RD" ] || exit 0
  # CODEX-003 (adversarial review 2026-07-05): "no markers" is the STEADY state, so this probe
  # would otherwise run its per-branch git census on EVERY turn end. Throttle the PROBE itself
  # (separate stamp from the drain-launch throttle below — that one only gates launches): at most
  # one census per V_STOP_PROBE_THROTTLE_SEC (default 900). The cron actor closes the freshness
  # gap on its own cadence regardless.
  _PSTAMP="$MAIN_ROOT/.v/tmp/.redrive-probe-stamp"
  if [ -f "$_PSTAMP" ]; then
    _pnow=$(date +%s)
    _pst=$(stat -c %Y "$_PSTAMP" 2>/dev/null || stat -f %m "$_PSTAMP" 2>/dev/null || echo 0)
    printf '%s' "$_pst" | grep -qE '^[0-9]+$' || _pst=0
    [ $(( _pnow - _pst )) -lt "${V_STOP_PROBE_THROTTLE_SEC:-900}" ] && exit 0
  fi
  mkdir -p "$MAIN_ROOT/.v/tmp" 2>/dev/null || true
  touch "$_PSTAMP" 2>/dev/null || true
  _strands=$(bash "$_RD" "$MAIN_ROOT" --probe 2>/dev/null | sed -n 's/^strands=//p' | head -1 || true)
  case "$_strands" in ''|*[!0-9]*) _strands=0 ;; esac
  [ "$_strands" -gt 0 ] || exit 0
fi

# Self-register this repo with the TIME-BASED drain actor (v-cron-drain.sh, forensic 2026-07-04):
# event-driven triggers alone starve when the operator leaves fleet tabs idle-open (no further
# Stop events ever fire). The cron actor picks up any repo registered here and prunes it once
# nothing is owed. Best-effort, never blocks the Stop event.
_REG="$HOME/.claude/runtime/v-drain-repos.txt"
if mkdir -p "$HOME/.claude/runtime" 2>/dev/null; then
  grep -qxF "$MAIN_ROOT" "$_REG" 2>/dev/null || printf '%s\n' "$MAIN_ROOT" >> "$_REG" 2>/dev/null || true
fi

# Throttle CHECK: at most one drain LAUNCH per repo per window (Stop fires on
# every turn end). W71-review H3/F-1: the stamp is only WRITTEN just before the
# drain actually launches (below) — a sibling-deferred attempt must NOT burn the
# window, or fleet wind-downs (all Stops inside one window) would starve the
# "last one out drains" trigger entirely. Stamp lives in .v/tmp — if a sibling
# teardown sweeps it, worst case is one extra attempt against an idempotent,
# self-locking drain.
_THROTTLE="${V_STOP_DRAIN_THROTTLE_SEC:-600}"
STAMP="$MAIN_ROOT/.v/tmp/.stop-drain-stamp"
if [ -f "$STAMP" ]; then
  _now=$(date +%s)
  # portable stat (M2): GNU reads `stat -f` as a filesystem stat and prints garbage, so try the GNU
  # form first; BSD stat rejects -c without printing anything. Branching on uname instead breaks on
  # macOS with GNU coreutils first on PATH. See scripts/portability-test.sh.
  _st=$(stat -c %Y "$STAMP" 2>/dev/null || stat -f %m "$STAMP" 2>/dev/null || echo 0)
  printf '%s' "$_st" | grep -qE '^[0-9]+$' || _st=0
  [ $(( _now - _st )) -lt "$_THROTTLE" ] && exit 0
fi

# Live-sibling check: if ANY other /v session is provably live in this repo AND has not yet
# finished (no merge-deferred marker of its own), defer to it — the last one out (or the next
# one in) triggers the drain.
# CONSENT filter (forensic 2026-07-04, Jul-4 fleet standoff): a sibling that has already WRITTEN
# merge-deferred-<sid>.md has finished its gauntlet, run merge-back itself, and is only waiting to
# LAND — its idle-open terminal tab must not veto the trigger. Observed: several sessions idle-open all
# day, every one with a deferral marker, transcript mtimes forever fresh → this gate never passed
# and zero stop-drain-*.log lines existed despite dozens of Stop events. Only a live sibling
# WITHOUT a deferral marker (still mid-work) blocks the launch; the drain's own per-worktree
# liveness/consent + C-1 gates keep per-branch safety.
# NOTE: no stamp write on this path (see throttle comment above).
_SIBLINGS_SH="$HOME/.claude/skills/v/references/v-active-siblings.sh"
if [ -f "$_SIBLINGS_SH" ]; then
  _sibs=$(bash "$_SIBLINGS_SH" "$MAIN_ROOT" "${SID:-none}" 2>/dev/null || true)
  if [ -n "$_sibs" ]; then
    _blocking=""
    while IFS= read -r _sline; do
      [ -n "$_sline" ] || continue
      _ssid="${_sline%% *}"
      [ -f "$MAIN_ROOT/.v/artifacts/merge-deferred-${_ssid}.md" ] && continue
      [ -f "$MAIN_ROOT/.v/tmp/merge-deferred-${_ssid}.md" ] && continue
      _blocking=1; break
    done <<EOF_SIBS
$_sibs
EOF_SIBS
    [ -n "$_blocking" ] && exit 0
  fi
fi

mkdir -p "$MAIN_ROOT/.v/tmp" 2>/dev/null || true
touch "$STAMP" 2>/dev/null || true

DRAIN="${V_STOP_DRAIN_SCRIPT:-$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh}"
[ -f "$DRAIN" ] || exit 0
mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null || true
LOG="$MAIN_ROOT/.v/artifacts/stop-drain-$(date -u +%Y%m%d).log"
{
  echo "=== stop-drain trigger $(date -u +%Y-%m-%dT%H:%M:%SZ) sid=${SID:-unknown} repo=$MAIN_ROOT ==="
} >> "$LOG" 2>/dev/null || true
# Detached: never block the Stop event on merges. The drain's own guards
# (liveness skip, C-1 verdict gate, merge-back lock/ownership) do the safety work.
nohup bash "$DRAIN" "$MAIN_ROOT" >> "$LOG" 2>&1 &

exit 0
