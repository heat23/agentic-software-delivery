#!/usr/bin/env bash
# run-v-packs-inbox-nightly.sh — detect/execute/digest engine for the pack-inbox convention
# (~/.claude/skills/references/v-core-pack-inbox.md). MANUAL, operator-invoked only — reworked
# 2026-07-06 to drop the scheduled/launchd design; the operator-facing entry point is the `v-inbox`
# command (~/.local/bin/v-inbox), which is a thin wrapper around this script. There is no cron, no
# launchd job, no auto-arm — this file's name is legacy (kept to avoid churning its several
# cross-references) but nothing in it runs unless `v-inbox` (or this script directly) is invoked.
#
# SAFE-BY-DEFAULT (read this first): this script does NOT launch new autonomous /v sessions
# unless the caller explicitly opts in. By default (`v-inbox`, no args) it only DETECTS registered
# projects with a non-empty .v/packs/inbox/, writes a digest, and fires a notification naming the
# exact `run-v-packs <inbox> --once` command the operator can run by hand. Set
# PACK_INBOX_NIGHTLY_EXECUTE=1 to arm actual execution — `v-inbox run` sets this internally; you
# normally never set it by hand.
#
# WHAT (detect mode, the default — `v-inbox`): walks the self-registering project registry
# (~/.claude/runtime/pack-inbox-registry.txt, appended to by register-pack-inbox.sh whenever a
# producer queues packs into a project's <root>/.v/packs/inbox/) and, for each registered project
# whose inbox is non-empty, records it as pending in the digest.
#
# WHAT (execute mode, PACK_INBOX_NIGHTLY_EXECUTE=1 — `v-inbox run`): additionally runs
#   run-v-packs "<root>/.v/packs/inbox" --once
# for each pending project. --once runs a single wave pass then returns (exit 0 = drained, exit 2
# = ran fine but work remains — both are SUCCESS from this wrapper's point of view; only exit 1 is
# a hard error).
#
# WHY A SEPARATE SCRIPT (not folded into v-cron-drain.sh): that script drains already-gauntleted
# merge-deferred branches (a DIFFERENT queue — finished work waiting to land, pure git plumbing).
# This one is about NEW, not-yet-run packs — a different, higher-risk surface (it spends model
# budget and launches new coding-agent sessions when executed), so it keeps its own explicit arm
# flag and its own log rather than inheriting v-cron-drain's always-on posture.
#
# DIGEST / NOTIFICATION: aggregates results into one digest, written to a dated log plus a
# rolling "-latest" pointer, and (macOS only, best-effort) fires a native notification via
# osascript. Never fails the run if osascript is unavailable (Linux/CI/headless).
#
# USAGE: never invoke this script directly — run `v-inbox` / `v-inbox run` / `v-inbox run
# <project_root>` (~/.local/bin/v-inbox). See that command's --help or
# ~/.claude/skills/references/v-core-pack-inbox.md § Running it.
#
# SAFETY: in execute mode this script adds zero merge/execution logic of its own — it only
# decides WHICH directories to hand to the real `run-v-packs`, which owns every safety property
# documented in v-runnable-pack-convention.md (parallel isolation, wave landing, gauntlet-attested
# archiving, crash recovery). A per-run lock prevents overlapping invocations. Exit is always 0 —
# per-project failures are recorded in the digest, never surfaced as this wrapper's exit code.
set -uo pipefail

RUNTIME_DIR="${V_RUNTIME_DIR:-$HOME/.claude/runtime}"
REGISTRY="$RUNTIME_DIR/pack-inbox-registry.txt"
RUN_V_PACKS="${RUN_V_PACKS_BIN:-run-v-packs}"
LOG_MAX_LINES=4000
# Accept common truthy spellings so a caller setting EXECUTE=true/yes doesn't silently stay
# in detect-only mode with no warning (fails safe either way — this only affects discoverability).
case "${PACK_INBOX_NIGHTLY_EXECUTE:-0}" in
  1|true|TRUE|True|yes|YES|Yes) EXECUTE=1 ;;
  *) EXECUTE=0 ;;
esac

mkdir -p "$RUNTIME_DIR" 2>/dev/null || exit 0

[ -f "$REGISTRY" ] || exit 0

# Overlap guard — a slow prior invocation (or two concurrent `v-inbox` calls) must not
# double-launch packs.
LOCK_DIR="$RUNTIME_DIR/pack-inbox-nightly.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  _lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_DIR" 2>/dev/null || stat -f %m "$LOCK_DIR" 2>/dev/null || date +%s) ))
  # Stale after 6h (a single v-inbox pass across a modest project count should never take this
  # long — --once caps each project at one wave); break it rather than starving forever.
  if [ "$_lock_age" -gt 21600 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null
    mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

DATE_TAG="$(date -u +%Y%m%d-%H%M%S)"
DIGEST_LOG="$RUNTIME_DIR/pack-inbox-nightly-$DATE_TAG.log"
LATEST_LOG="$RUNTIME_DIR/pack-inbox-nightly-latest.log"

# Bound our own historical logs (keep the newest 20; this wrapper writes one per run).
# NOTE: `head -n -N` (negative count) is a GNU-ism — BSD/macOS head rejects it outright ("illegal
# line count"), which would silently no-op this whole block under `set -uo pipefail` (no `set -e`).
# Compute the "all but the newest 20" list portably instead.
_all_logs=$(find "$RUNTIME_DIR" -maxdepth 1 -type f -name 'pack-inbox-nightly-*.log' ! -name '*-latest.log' 2>/dev/null | sort)
_log_count=$(printf '%s\n' "$_all_logs" | grep -c . || true)
if [ "$_log_count" -gt 20 ]; then
  _old_logs=$(printf '%s\n' "$_all_logs" | head -n "$((_log_count - 20))")
  printf '%s\n' "$_old_logs" | xargs rm -f 2>/dev/null
fi

{
  echo "════════════════════════════════════════════════════════════════"
  echo "  pack-inbox run — $(date -u +%Y-%m-%dT%H:%M:%SZ)  (mode: $([ "$EXECUTE" = 1 ] && echo EXECUTE || echo detect-only))"
  echo "════════════════════════════════════════════════════════════════"
} > "$DIGEST_LOG"

TOTAL_PROJECTS=0
TOTAL_PENDING=0
TOTAL_DONE=0
TOTAL_PARKED=0
TOTAL_QUEUED=0
TOTAL_ERRORS=0
_kept=""

is_pending_inbox() {
  # $1 = inbox dir. "Pending" = at least one real .txt/.md file directly inside it (not in the
  # run-v-packs-owned .done/.needs-review/.runlogs subdirs, which -maxdepth 1 already excludes).
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -n "$(find "$dir" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | head -1)" ]
}

while IFS= read -r project; do
  [ -n "$project" ] && [ -d "$project" ] || continue
  TOTAL_PROJECTS=$((TOTAL_PROJECTS + 1))
  inbox="$project/.v/packs/inbox"

  if ! is_pending_inbox "$inbox"; then
    # Nothing pending — drop from the registry (it self-re-registers the moment a producer
    # queues new packs; see register-pack-inbox.sh). Covers both "inbox fully drained" and
    # "inbox directory doesn't exist yet/anymore." In detect-only mode this is also how a
    # project a prior EXECUTE run fully drained falls out of future digests.
    continue
  fi

  TOTAL_PENDING=$((TOTAL_PENDING + 1))

  {
    echo
    echo "── project: $project ──"
  } >> "$DIGEST_LOG"

  if [ "$EXECUTE" != 1 ]; then
    # Detect-only: nothing can drain, so the project stays registered unconditionally.
    _kept="${_kept}${project}"$'\n'
    echo "  pending packs in $inbox — detect-only mode, NOT executed." >> "$DIGEST_LOG"
    echo "  to run by hand:  $RUN_V_PACKS \"$inbox\" --once" >> "$DIGEST_LOG"
    continue
  fi

  if ! command -v "$RUN_V_PACKS" >/dev/null 2>&1; then
    _kept="${_kept}${project}"$'\n'
    echo "  !! $RUN_V_PACKS not on PATH — cannot execute" >> "$DIGEST_LOG"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    continue
  fi

  _out="$("$RUN_V_PACKS" "$inbox" --once 2>&1)"
  _rc=$?
  printf '%s\n' "$_out" >> "$DIGEST_LOG"

  # Pull the counts straight out of run-v-packs's own "SELF-AUDIT SUMMARY" line
  # ("packs: N done · M parked (.needs-review/) · L queued") rather than re-deriving them —
  # single source of truth, stays in sync automatically if that line's wording changes shape
  # (a missing match just contributes 0 to the digest, never a hard failure).
  _summary_line=$(printf '%s\n' "$_out" | grep -m1 'packs: .* done .* parked .* queued' || true)
  if [ -n "$_summary_line" ]; then
    _d=$(printf '%s\n' "$_summary_line" | sed -nE 's/.*packs: ([0-9]+) done.*/\1/p')
    _p=$(printf '%s\n' "$_summary_line" | sed -nE 's/.*· ([0-9]+) parked.*/\1/p')
    _q=$(printf '%s\n' "$_summary_line" | sed -nE 's/.*· ([0-9]+) queued.*/\1/p')
    case "$_d" in ''|*[!0-9]*) _d=0 ;; esac
    case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
    case "$_q" in ''|*[!0-9]*) _q=0 ;; esac
    TOTAL_DONE=$((TOTAL_DONE + _d))
    TOTAL_PARKED=$((TOTAL_PARKED + _p))
    TOTAL_QUEUED=$((TOTAL_QUEUED + _q))
  fi

  if [ "$_rc" != 0 ] && [ "$_rc" != 2 ]; then
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    echo "  !! run-v-packs exited $_rc (hard error) for $project" >> "$DIGEST_LOG"
  fi

  # Execute mode: re-check the inbox AFTER the run so a project this pass fully drained is
  # pruned NOW, not one cycle late (it self-re-registers on the next queued pack anyway).
  if is_pending_inbox "$inbox"; then
    _kept="${_kept}${project}"$'\n'
  fi
done < <(sort -u "$REGISTRY" 2>/dev/null)

# Rewrite the registry with only projects that still have a pending inbox. In detect-only mode
# this just re-lists the same pending set every night (nothing was drained); in execute mode it
# reflects what's actually still queued after this pass.
printf '%s' "$_kept" | sort -u > "$REGISTRY.tmp" 2>/dev/null && mv "$REGISTRY.tmp" "$REGISTRY" 2>/dev/null || true

{
  echo
  echo "════════════════════════════════════════════════════════════════"
  if [ "$EXECUTE" = 1 ]; then
    echo "  DIGEST: $TOTAL_PROJECTS registered project(s), $TOTAL_PENDING with pending work"
    echo "  packs: $TOTAL_DONE done · $TOTAL_PARKED parked · $TOTAL_QUEUED still queued · $TOTAL_ERRORS project(s) errored"
  else
    echo "  DIGEST (detect-only): $TOTAL_PROJECTS registered project(s), $TOTAL_PENDING with pending packs"
    echo "  Run 'v-inbox run' to have them actually run."
  fi
  echo "════════════════════════════════════════════════════════════════"
} >> "$DIGEST_LOG"

cp "$DIGEST_LOG" "$LATEST_LOG" 2>/dev/null || true

# Best-effort native notification (macOS only; silently skipped everywhere else).
if command -v osascript >/dev/null 2>&1; then
  if [ "$TOTAL_PENDING" -eq 0 ]; then
    _msg="Pack-inbox: nothing pending across $TOTAL_PROJECTS project(s)."
  elif [ "$EXECUTE" = 1 ]; then
    _msg="Pack-inbox: $TOTAL_DONE done, $TOTAL_PARKED parked, $TOTAL_QUEUED queued across $TOTAL_PENDING project(s)."
    [ "$TOTAL_ERRORS" -gt 0 ] && _msg="$_msg $TOTAL_ERRORS errored — check pack-inbox-nightly-latest.log."
  else
    _msg="Pack-inbox: $TOTAL_PENDING project(s) have packs waiting (detect-only — not run). See pack-inbox-nightly-latest.log."
  fi
  osascript -e "display notification \"$_msg\" with title \"Claude pack-inbox\"" >/dev/null 2>&1 || true
fi

# Keep our own bounded trailing log too, in case something redirects stdout here directly.
_SELF_LOG="$RUNTIME_DIR/run-v-packs-inbox-nightly.log"
cat "$DIGEST_LOG" >> "$_SELF_LOG" 2>/dev/null || true
if [ -f "$_SELF_LOG" ] && [ "$(wc -l < "$_SELF_LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_LINES" ]; then
  tail -n "$((LOG_MAX_LINES / 2))" "$_SELF_LOG" > "$_SELF_LOG.tmp" 2>/dev/null && mv "$_SELF_LOG.tmp" "$_SELF_LOG" 2>/dev/null || true
fi

exit 0
