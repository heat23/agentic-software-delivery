#!/usr/bin/env bash
# lib/codex-quota-cache.sh — E2 (efficiency, 2026-07-05): SHARED, fleet-wide cache recording
# "codex quota exhausted, retry after <timestamp>" so multiple /v sessions (or multiple dispatch
# points inside one session) don't each independently pay a real network round-trip + a wasted turn
# discovering the SAME already-known-exhausted codex quota.
#
# WHY: direct evidence (2026-07-05) — `codex exec` on the primary model failed as unsupported, the
# documented fallback model then failed with a "usage limit ... try again at <timestamp>" error
# (a full quota exhaustion).
# Nothing before this fix recorded that outcome anywhere the PRIMARY direct-`codex exec` Bash path
# (references/v-agent-review.md's supervisor-child snippet) could see it — every session, and every
# repeated dispatch point in the SAME session, re-attempted codex cold and paid the full network
# round-trip again before falling back.
#
# NOTE on the pre-existing DAY-granularity memo: ~/.claude/scripts/codex-review.sh (used by the
# codex-adversarial-reviewer AGENT-dispatch fallback path) already maintains its OWN separate
# day-granularity memo at ~/.claude/runtime/codex-down-until.txt (H4-10). That script is out of this
# fix's scope (scripts/ is not one of the directories this hardening pass may touch) and is left
# untouched. This library adds a SEPARATE, finer-grained (minute-level TTL, per the task's 30-60 min
# ask) cache for the PRIMARY direct-Bash codex-exec path plus any other in-scope caller — it does not
# attempt to unify with the day-based memo (different granularity, different owner, different file).
# Both mechanisms degrade the SAME way (skip codex, go to fallback) so a session honoring EITHER one
# never wastes a round-trip discovering what the other already recorded.
#
# Usage:
#   source "$HOOKS_LIB_DIR/lib/codex-quota-cache.sh"
#   if codex_quota_is_blocked; then
#     # skip codex exec entirely; codex_quota_is_blocked already printed the reason to stdout
#   else
#     # attempt codex exec as normal; on a quota-exhaustion failure:
#     codex_quota_record_exhausted "<human reason, e.g. captured codex stderr>"
#   fi
#
# File format (deliberately NOT parsed with jq — no new hard dependency for callers that may not
# have jq, e.g. the bash snippet embedded in a supervisor-child heredoc): flat single-line JSON with
# a fixed, self-generated shape, read back with grep/sed against the known field names. Still valid
# JSON (readable/greppable by humans and other tooling), just not parsed with a JSON library here.

# Resolve the cache file path. Overridable (CODEX_QUOTA_STATE_FILE) so tests never touch the real
# fleet-wide file.
codex_quota_cache_file() {
  printf '%s' "${CODEX_QUOTA_STATE_FILE:-$HOME/.claude/runtime/codex-quota-state.json}"
}

# Default TTL: 45 minutes (2700s) — mid-point of the requested 30-60 min window. A caller with a
# real "retry after <timestamp>" from the codex error text should pass an explicit ttl computed from
# that timestamp instead (see codex_quota_record_exhausted's optional 2nd arg).
CODEX_QUOTA_DEFAULT_TTL_SECONDS=2700

# codex_quota_is_blocked -> 0 (blocked — skip codex, go straight to fallback) if a live,
# non-expired exhaustion record exists; 1 (not blocked — proceed with codex) otherwise.
# On rc 0, prints a one-line human-readable reason to stdout (caller may log/relay it).
# Self-healing: an expired record is treated as not-blocked (rc 1) WITHOUT needing to delete the
# file — the next codex_quota_record_exhausted call overwrites it. Fail-open on any parse error
# (never falsely blocks a working codex path because of a malformed cache file).
codex_quota_is_blocked() {
  local _f _retry_epoch _now_epoch _reason
  _f="$(codex_quota_cache_file)"
  [ -f "$_f" ] || return 1
  _retry_epoch=$(grep -oE '"retry_after_epoch"[[:space:]]*:[[:space:]]*[0-9]+' "$_f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  [ -n "$_retry_epoch" ] || return 1
  _now_epoch=$(date -u +%s 2>/dev/null || echo 0)
  if [ "$_now_epoch" -lt "$_retry_epoch" ] 2>/dev/null; then
    _reason=$(grep -oE '"reason"[[:space:]]*:[[:space:]]*"[^"]*"' "$_f" 2>/dev/null | head -1 | sed -E 's/^"reason"[[:space:]]*:[[:space:]]*"//; s/"$//')
    local _retry_iso
    _retry_iso=$(grep -oE '"retry_after"[[:space:]]*:[[:space:]]*"[^"]*"' "$_f" 2>/dev/null | head -1 | sed -E 's/^"retry_after"[[:space:]]*:[[:space:]]*"//; s/"$//')
    echo "codex quota cache: BLOCKED until ${_retry_iso:-unknown} (fleet-wide cache: $_f) — ${_reason:-previously recorded exhaustion}"
    return 0
  fi
  return 1
}

# codex_quota_record_exhausted <reason> [ttl_seconds]
# Writes/overwrites the shared cache. ttl_seconds defaults to CODEX_QUOTA_DEFAULT_TTL_SECONDS.
# Best-effort: never fails the caller (mkdir/write failures are swallowed — a cache-write failure
# must never block or crash the actual dispatch flow).
codex_quota_record_exhausted() {
  local _reason="${1:-codex quota exhausted}" _ttl="${2:-$CODEX_QUOTA_DEFAULT_TTL_SECONDS}"
  local _f _now_epoch _retry_epoch _now_iso _retry_iso _dir
  _f="$(codex_quota_cache_file)"
  _dir="$(dirname "$_f")"
  mkdir -p "$_dir" 2>/dev/null || return 0
  _now_epoch=$(date -u +%s 2>/dev/null || echo 0)
  _retry_epoch=$(( _now_epoch + _ttl ))
  _now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
  _retry_iso=$(date -u -r "$_retry_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${_retry_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
  # Escape double quotes/backslashes in the reason so it can't break the flat JSON shape, and
  # collapse embedded newlines to spaces (tr, not a multi-line sed label — BSD sed's `N;$!bN`
  # GNU-style label idiom is not portable to macOS sed).
  local _reason_esc
  _reason_esc=$(printf '%s' "$_reason" | tr '\n' ' ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  {
    printf '{"exhausted":true,"exhausted_at":"%s","retry_after_epoch":%s,"retry_after":"%s","ttl_seconds":%s,"reason":"%s","recorded_by_sid":"%s"}\n' \
      "$_now_iso" "$_retry_epoch" "$_retry_iso" "$_ttl" "$_reason_esc" "${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-unknown}}"
  } > "$_f" 2>/dev/null || true
}

# codex_quota_clear -> best-effort remove the cache (used by tests / manual recovery). Never fails.
codex_quota_clear() {
  rm -f "$(codex_quota_cache_file)" 2>/dev/null || true
}

# codex_quota_looks_like_exhaustion <text> -> 0 if the text carries a genuine quota/usage-limit
# signature (NOT a generic failure like a transient network error or an unrelated 4xx) — narrower
# than record-codex-dispatch-provenance.sh's broader failure classifier by design: this gates a
# 30-60 min fleet-wide SKIP, so it must not fire on noise unrelated to quota exhaustion.
codex_quota_looks_like_exhaustion() {
  local _text="${1:-}"
  printf '%s' "$_text" | grep -qiE "hit your usage limit|usage limit|quota exceeded|quota|rate.?limit exceeded"
}
