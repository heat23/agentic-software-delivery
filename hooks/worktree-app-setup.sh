#!/usr/bin/env bash
# worktree-app-setup.sh — W-conc-fix v2 — explicit worktree app provisioning (Laravel).
#
# Gives a git worktree the app-level state it needs to BOOT and to stay concurrency-isolated:
#   1. Copies main's `.env` into the worktree (worktrees don't inherit it — without it the app
#      can't boot, so browser/workflow verification silently DEGRADES to unit tests).
#   2. Per-worktree isolation of shared stateful resources (the W-conc-fix): unique CACHE_PREFIX
#      / REDIS_PREFIX, and a unique sqlite dev-DB copy — so concurrent /v worktree sessions don't
#      collide on cache/redis keyspace or race the dev DB. Non-sqlite → warn (can't auto-create).
#   3. Creates Laravel storage dirs (artisan needs them).
#
# WHY THIS EXISTS AS AN EXPLICIT SCRIPT (2026-05-27): this logic used to live in
# `worktree-create.sh`, which is wired to NO hook event (and the `WorktreeCreate` event does not
# fire for a Bash `git worktree add` — the orchestrator's actual path — confirmed: settings.json
# has no PostToolUse Bash trigger). So it NEVER ran: bug-fix/small worktrees booted with no `.env`
# (workflow verification degraded in real sessions), and the concurrency isolation was dead. /v
# now invokes this EXPLICITLY after `git worktree add`, exactly like worktree-php-setup.sh.
#
# Usage:  bash worktree-app-setup.sh <worktree_path> [session_id]
# Idempotent, fail-open: every error path → exit 0; never blocks the session.
set -uo pipefail
trap 'exit 0' EXIT

# W70 canonical SID resolution (mirrors worktree-create.sh:47-48). Replaces the old inline
# `${CLAUDE_SESSION_ID:-}` — resolve_sid additionally honors the CLAUDE_CODE_SESSION_ID alias and the
# runtime/current-session-id file, and validates the UUID shape. Sourced defensively (fail-open hook):
# if the lib is absent, resolve_sid is undefined and the `$2`/lock-file/basename fallbacks still apply.
# Single-line guarded source (keep `. … lib/resolve-sid` on ONE line — the W65/W70 laggard detector
# greps line-by-line for a hook that both assigns SESSION_ID and sources lib/resolve-sid).
# shellcheck source=/dev/null
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/resolve-sid.sh" ] && . "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/lib/resolve-sid.sh"

WORKTREE_PATH="${1:-${CLAUDE_WORKTREE_PATH:-}}"
SESSION_ID="${2:-$(resolve_sid 2>/dev/null || true)}"
[ -d "${WORKTREE_PATH:-}" ] || exit 0

# Resolve REPO_ROOT = the MAIN checkout (parent of git-common-dir), from inside the worktree.
GIT_COMMON_DIR=$(git -C "$WORKTREE_PATH" rev-parse --git-common-dir 2>/dev/null) || exit 0
case "$GIT_COMMON_DIR" in
  /*) : ;;
  *)  GIT_COMMON_DIR="$(cd "$WORKTREE_PATH" && cd "$GIT_COMMON_DIR" 2>/dev/null && pwd)" || exit 0 ;;
esac
REPO_ROOT="$(cd "$GIT_COMMON_DIR/.." 2>/dev/null && pwd)" || exit 0
[ -d "$REPO_ROOT" ] || exit 0

# ── CATASTROPHIC GUARD: refuse if WORKTREE_PATH IS the main repo ─────────────
# Otherwise we'd copy/rewrite (and CACHE_PREFIX-munge) MAIN's own .env. Compare realpaths.
WT_REAL=$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P) || exit 0
RR_REAL=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P) || exit 0
[ -z "$WT_REAL" ] && exit 0
[ -z "$RR_REAL" ] && exit 0
[ "$WT_REAL" = "$RR_REAL" ] && exit 0

# Session token for isolation. SID from arg/env → .claude-session-lock → worktree basename.
[ -z "$SESSION_ID" ] && [ -f "$WORKTREE_PATH/.claude-session-lock" ] && \
  SESSION_ID=$(awk 'NR==1{print $1}' "$WORKTREE_PATH/.claude-session-lock" 2>/dev/null)
[ -z "$SESSION_ID" ] && SESSION_ID=$(basename "$WORKTREE_PATH")
WT_TOKEN=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9' | cut -c1-8)
[ -n "$WT_TOKEN" ] || WT_TOKEN="wtdefault"

# ── 1. Copy main's .env if the worktree doesn't have one yet ─────────────────
if [ -f "$REPO_ROOT/.env" ] && [ ! -f "$WT_REAL/.env" ]; then
  cp "$REPO_ROOT/.env" "$WT_REAL/.env" 2>/dev/null && echo "AUTO: copied .env into worktree" >&2
fi

# ── 2. Per-worktree isolation — applied whenever the worktree .env exists but is NOT yet isolated.
# Keyed off CACHE_PREFIX=wt_ (not just .env existence) so a pre-existing or partially-provisioned
# .env still gets isolated, and so re-runs are idempotent (skip once already wt_-prefixed). [SREV-002]
if [ -f "$WT_REAL/.env" ] && ! grep -qE '^CACHE_PREFIX=wt_' "$WT_REAL/.env"; then
  _set_env_var() {  # file key value — replace existing key or append; temp-file+mv (portable)
    local f="$1" k="$2" v="$3" t
    t=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
    grep -vE "^${k}=" "$f" 2>/dev/null > "$t" || true
    printf '%s=%s\n' "$k" "$v" >> "$t"
    mv "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null
  }
  _set_env_var "$WT_REAL/.env" CACHE_PREFIX "wt_${WT_TOKEN}"
  _set_env_var "$WT_REAL/.env" REDIS_PREFIX "wt_${WT_TOKEN}_"
  _db_conn=$(grep -E '^DB_CONNECTION=' "$WT_REAL/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
  if [ "$_db_conn" = "sqlite" ]; then
    _db_file=$(grep -E '^DB_DATABASE=' "$WT_REAL/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
    case "$_db_file" in
      ""|:memory:) : ;;
      *)
        # SREV-001: a RELATIVE DB_DATABASE (copied from main's .env) is relative to the MAIN repo
        # root — where the .env + its seeded DB live — NOT this script's CWD. Resolve it against
        # $REPO_ROOT so the seed copy finds the real source instead of silently making an empty DB.
        case "$_db_file" in /*) : ;; *) _db_file="$REPO_ROOT/$_db_file" ;; esac
        _new_db="$WT_REAL/database/database-${WT_TOKEN}.sqlite"
        mkdir -p "$WT_REAL/database" 2>/dev/null
        if [ -f "$_db_file" ]; then
          cp "$_db_file" "$_new_db" 2>/dev/null && echo "AUTO: isolated dev sqlite DB → $_new_db (copied+seeded)" >&2
        else
          : > "$_new_db" 2>/dev/null && echo "AUTO: isolated dev sqlite DB → $_new_db (fresh; run migrations)" >&2
        fi
        [ -f "$_new_db" ] && _set_env_var "$WT_REAL/.env" DB_DATABASE "$_new_db"
        ;;
    esac
  elif [ -n "$_db_conn" ]; then
    echo "WARNING (W-conc-fix): DB_CONNECTION=$_db_conn — worktrees SHARE this dev DB. Concurrent verification will race on data; configure a per-session test/dev DB before running concurrent /v sessions." >&2
  fi
  echo "AUTO: isolated worktree cache/redis prefix (wt_${WT_TOKEN}) for concurrency safety" >&2
fi

# ── 3. Laravel storage dirs (artisan needs them) ────────────────────────────
if [ -f "$WT_REAL/artisan" ]; then
  mkdir -p "$WT_REAL/storage/logs" "$WT_REAL/storage/framework/cache" \
           "$WT_REAL/storage/framework/sessions" "$WT_REAL/storage/framework/views" 2>/dev/null \
    && echo "AUTO: created Laravel storage dirs in worktree" >&2
fi

# ── 4. Per-worktree phpunit.xml / Pest.php / .env base-path templating (item 27a, 2026-07-03) ──
# Extends the RUN_ROOT templating mechanism (previously runner-only) to every worktree creation
# path (interactive /v worktrees, not just the run-v-packs runner). WHY: `git worktree add` checks
# out phpunit.xml/Pest.php/.env as ordinary tracked (or copied, for .env) files, but if any of
# them carry a value HARDCODED to the MAIN repo's absolute path (a literal `<server
# name="APP_BASE_PATH" value="$REPO_ROOT">` in phpunit.xml, an `APP_BASE_PATH=$REPO_ROOT` line in
# .env, or an absolute-path string baked into Pest.php), the worktree's own test run still boots
# against MAIN's root — isolation theatre under concurrency (worktrees observed
# booting the main root during tests). Fix: rewrite any occurrence of the literal REPO_ROOT
# absolute path string to WT_REAL in the worktree's OWN copies of these three files. This never
# touches main's files (only $WT_REAL/* paths) and is idempotent (a no-op once already rewritten,
# since the search string no longer matches).
if [ -n "${REPO_ROOT:-}" ] && [ "$REPO_ROOT" != "$WT_REAL" ]; then
  for _f in "$WT_REAL/phpunit.xml" "$WT_REAL/phpunit.xml.dist" "$WT_REAL/Pest.php" "$WT_REAL/.env"; do
    [ -f "$_f" ] || continue
    grep -qF "$REPO_ROOT" "$_f" 2>/dev/null || continue
    _tf=$(mktemp "${_f}.XXXXXX" 2>/dev/null) || continue
    # Literal string substitution (not regex) — REPO_ROOT may contain characters that are ERE
    # metacharacters (., -, etc.); sed with a non-slash delimiter + escaped replacement avoids
    # both the delimiter-collision and the metacharacter-in-pattern classes.
    # Pattern side: escape ALL BRE metacharacters (] [ \ . * ^ $) plus the | delimiter — a path
    # like /srv/x.y/proj would otherwise match /srv/xZy/proj (`.` as wildcard; logic review
    # 2026-07-03). Replacement side: only \ & and the | delimiter are special. WT_REAL appears in
    # BOTH positions (pattern in the protect step, replacement in the substitute/restore steps),
    # so it gets one variant per position.
    _repo_esc=$(printf '%s' "$REPO_ROOT" | sed 's/[][\.*^$|&]/\\&/g')
    _wt_pat=$(printf '%s' "$WT_REAL" | sed 's/[][\.*^$|&]/\\&/g')
    _wt_esc=$(printf '%s' "$WT_REAL" | sed 's/[\&|]/\\&/g')
    # Worktrees in this ecosystem are usually NESTED under the main repo (.worktrees/<slug>), so
    # WT_REAL contains REPO_ROOT as a PREFIX — a naive REPO_ROOT→WT_REAL substitution re-matches
    # the prefix of already-rewritten paths on every run and corrupts them
    # ($M/.worktrees/t3 → $M/.worktrees/t3/.worktrees/t3 → …). Protect existing WT_REAL
    # occurrences with a placeholder first, substitute, then restore — true idempotence.
    _ph=$'\x01'"__V27A_WT_PLACEHOLDER__"$'\x01'
    if sed "s|${_wt_pat}|${_ph}|g; s|${_repo_esc}|${_wt_esc}|g; s|${_ph}|${_wt_esc}|g" "$_f" > "$_tf" 2>/dev/null; then
      mv "$_tf" "$_f" 2>/dev/null && echo "AUTO: rewrote main-root path → worktree path in $(basename "$_f") (item 27a base-path isolation)" >&2
    else
      rm -f "$_tf" 2>/dev/null
    fi
  done
fi

exit 0
