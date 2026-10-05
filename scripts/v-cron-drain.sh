#!/usr/bin/env bash
# v-cron-drain.sh — time-based drain actor (forensic 2026-07-04, fleet standoff).
#
# WHY: every previous drain trigger was EVENT-driven (run-v-packs end-of-run, Stop hook,
# SessionStart hook). A solo operator who leaves fleet tabs idle-open emits no further events —
# "the last one out drains" never fires, and gauntleted branches sat stranded
# while zero stop-drain-*.log lines were written. Landing must not depend on a session event.
#
# WHAT: every cron tick, walk the self-registering repo registry
# (~/.claude/runtime/v-drain-repos.txt — appended by stop-drain-deferred-merges.sh whenever it
# sees deferral markers in a repo) and run v-drain-deferred-merges.sh on each repo that still has
# merge-deferred markers. Repos with no markers left are pruned from the registry.
#
# SAFETY: this script adds ZERO merge logic. All safety lives in the drain it invokes —
# per-worktree owner-liveness/consent gates, the C-1 verdict gate, and v-merge-back's own
# lock/ownership/W-GATE guards. A per-repo lock dir prevents overlapping drains. Exit always 0.
#
# INSTALL: example crontab entry
#   */20 * * * * $HOME/.claude/scripts/v-cron-drain.sh >> $HOME/.claude/runtime/v-cron-drain.log 2>&1
# REMOVE: crontab -e and delete that line.  Kill switch: touch ~/.claude/runtime/v-cron-drain.off
set -uo pipefail

RUNTIME="${V_RUNTIME_DIR:-$HOME/.claude/runtime}"
REGISTRY="$RUNTIME/v-drain-repos.txt"
DRAIN="${V_CRON_DRAIN_SCRIPT:-$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh}"
LOG_MAX_LINES=4000

[ -f "$RUNTIME/v-cron-drain.off" ] && exit 0
[ -f "$REGISTRY" ] || exit 0
[ -f "$DRAIN" ] || exit 0

# Keep our own log bounded (we append via crontab redirection).
_SELF_LOG="$RUNTIME/v-cron-drain.log"
if [ -f "$_SELF_LOG" ] && [ "$(wc -l < "$_SELF_LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_LINES" ]; then
  tail -n "$((LOG_MAX_LINES / 2))" "$_SELF_LOG" > "$_SELF_LOG.tmp" 2>/dev/null && mv "$_SELF_LOG.tmp" "$_SELF_LOG" 2>/dev/null || true
fi

_kept=""
while IFS= read -r repo; do
  [ -n "$repo" ] && [ -d "$repo" ] || continue
  # still has deferral markers?
  _mk=$(find "$repo/.v/artifacts" "$repo/.v/tmp" -maxdepth 1 -name 'merge-deferred-*.md' 2>/dev/null | head -1 || true)
  if [ -z "$_mk" ]; then
    # FND-3 re-driver probe (2026-07-04): markers are not the only landing debt — a gauntleted
    # branch whose WORKTREE IS GONE has no marker yet. Read-only census; strands>0 keeps the repo
    # and runs the drain (which re-attaches + lands them through its own C-1/merge-back gates).
    _rd="${V_CRON_REDRIVE_SCRIPT:-$HOME/.claude/skills/v/references/v-strand-redrive.sh}"
    _strands=0
    [ -f "$_rd" ] && _strands=$(bash "$_rd" "$repo" --probe 2>/dev/null | sed -n 's/^strands=//p' | head -1 || true)
    case "$_strands" in ''|*[!0-9]*) _strands=0 ;; esac
    if [ "$_strands" -eq 0 ]; then
      # nothing owed → prune from registry (repo re-registers itself via the Stop hook if needed)
      continue
    fi
  fi
  _kept="${_kept}${repo}"$'\n'
  # per-repo overlap lock (mkdir is atomic); stale after 2h → break it
  _lockdir="$RUNTIME/v-cron-drain-lock-$(printf '%s' "$repo" | tr '/' '-')"
  if ! mkdir "$_lockdir" 2>/dev/null; then
    _lage=$(( $(date +%s) - $(stat -c %Y "$_lockdir" 2>/dev/null || stat -f %m "$_lockdir" 2>/dev/null || date +%s) ))
    [ "$_lage" -gt 7200 ] && rmdir "$_lockdir" 2>/dev/null && mkdir "$_lockdir" 2>/dev/null || continue
  fi
  echo "=== v-cron-drain $(date -u +%Y-%m-%dT%H:%M:%SZ) repo=$repo ==="
  bash "$DRAIN" "$repo" 2>&1 || true
  # mirror into the repo's own durable drain log so per-repo forensics see cron-driven drains too
  {
    echo "=== cron-drain $(date -u +%Y-%m-%dT%H:%M:%SZ) (v-cron-drain.sh) ==="
  } >> "$repo/.v/artifacts/stop-drain-$(date -u +%Y%m%d).log" 2>/dev/null || true
  rmdir "$_lockdir" 2>/dev/null || true
done < <(sort -u "$REGISTRY" 2>/dev/null)

# rewrite the registry with only repos that still owe landings
printf '%s' "$_kept" | sort -u > "$REGISTRY.tmp" 2>/dev/null && mv "$REGISTRY.tmp" "$REGISTRY" 2>/dev/null || true
exit 0
