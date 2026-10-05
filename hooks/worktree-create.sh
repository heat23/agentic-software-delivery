#!/usr/bin/env bash
# worktree-create.sh
# Event: WorktreeCreate
# WorktreeCreate hook: Automatically creates .claude-session-lock when a worktree is created.
# Also auto-provisions the worktree with .env, storage dirs, and dependency installation hints.
# This fires on native `isolation: "worktree"` subagent creation and `--worktree` CLI usage,
# catching cases that PostToolUse (Bash) monitoring of `git worktree add` would miss.
# Version: 2.0.0
#
# Input JSON may include either:
#   - current contract: name (requested worktree name; hook must create it and print its absolute path)
#   - legacy contract: worktree_path (absolute path to an already-created worktree)
# Exit 0 = success. Outputs on stderr are advisory (shown to Claude).

set -euo pipefail


# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Debug mode: set CLAUDE_HOOK_DEBUG=1 to trace execution
if [ "${CLAUDE_HOOK_DEBUG:-0}" = "1" ]; then
  set -x
fi


# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat)
if [ -z "$INPUT" ]; then
  echo "ERROR: WorktreeCreate hook received empty input — no JSON payload from Claude Code" >&2
  echo "WORKTREE_CREATE_HOOK: FAILED — empty input" >&2
  exit 0
fi

# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
WT_NAME=$(echo "$INPUT" | jq -r '.name // .worktree_name // empty')
WT_PATH=$(echo "$INPUT" | jq -r '.worktree_path // empty')
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

if [ -z "$WT_PATH" ]; then
  if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: WorktreeCreate hook could not determine git repo root from cwd='$(pwd)'." >&2
    echo "WORKTREE_CREATE_HOOK: FAILED — repo root missing" >&2
    exit 0
  fi
  if [ -z "$WT_NAME" ]; then
    echo "ERROR: WorktreeCreate fired without a worktree name or worktree_path. Input keys: $(echo "$INPUT" | jq -r 'keys | join(\", \")' 2>/dev/null || echo 'unparseable')" >&2
    echo "WORKTREE_CREATE_HOOK: FAILED — name/worktree_path missing" >&2
    exit 0
  fi

  WT_NAME_SAFE=$(printf '%s' "$WT_NAME" | sed 's#[^A-Za-z0-9._/-]#-#g; s#//*#/#g; s#^/*##; s#/*$##')
  if [ -z "$WT_NAME_SAFE" ]; then
    echo "ERROR: WorktreeCreate received an unusable name '$WT_NAME'." >&2
    echo "WORKTREE_CREATE_HOOK: FAILED — invalid name" >&2
    exit 0
  fi

  WT_PATH="$REPO_ROOT/.worktrees/$WT_NAME_SAFE"
  BRANCH_NAME="$WT_NAME_SAFE"
  mkdir -p "$(dirname "$WT_PATH")"
  if [ -d "$WT_PATH" ]; then
    echo "INFO: Worktree path already exists, reusing $WT_PATH" >&2
  else
    if ! git -C "$REPO_ROOT" worktree add -q -b "$BRANCH_NAME" "$WT_PATH" HEAD 2>/dev/null; then
      if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        if ! git -C "$REPO_ROOT" worktree add -q "$WT_PATH" "$BRANCH_NAME" 2>/dev/null; then
          echo "ERROR: Failed to create worktree '$WT_NAME_SAFE' at '$WT_PATH' using existing branch '$BRANCH_NAME'." >&2
          echo "WORKTREE_CREATE_HOOK: FAILED — git worktree add existing-branch failed" >&2
          exit 0
        fi
      else
        echo "ERROR: Failed to create worktree '$WT_NAME_SAFE' at '$WT_PATH' from HEAD." >&2
        echo "WORKTREE_CREATE_HOOK: FAILED — git worktree add failed" >&2
        exit 0
      fi
    fi
    echo "AUTO: Created git worktree at '$WT_PATH' on branch '$BRANCH_NAME'" >&2
  fi
fi

if [ ! -d "$WT_PATH" ]; then
  echo "ERROR: WorktreeCreate fired for '$WT_PATH' but directory does not exist. Possible race condition or path error." >&2
  echo "WORKTREE_CREATE_HOOK: FAILED — directory not found: $WT_PATH" >&2
  exit 0
fi

# Auto-create lock file with session_id and Unix epoch timestamp (portable across Linux/macOS)
# Write atomically (temp file + mv) to prevent corruption if worktree-lifecycle.sh
# also tries to create the lock file concurrently as a fallback.
# Lock format (2026-07-02, H-3 forensic): canonical positional 3-field "SID PID EPOCH", matching the
# /v inline worktree-creation template (v-build-workflows.md) — one shape everywhere, so a reader never
# has to guess which field is which. PID is best-effort: $PPID is the process that invoked this hook
# (the long-lived Claude Code CLI process for a real WorktreeCreate event), NOT this hook subshell's own
# transient $$. If that PID isn't actually the owning session (an unusual invocation chain), the reader
# (session-lock-parse.sh's lock_alive) degrades gracefully to the epoch/mtime fallback exactly as it did
# for the old PID-less 2-field format — never worse than before, and correct in the common case.
if [ -n "$SESSION_ID" ]; then
  LOCK_TMP=$(mktemp "$WT_PATH/.claude-session-lock.XXXXXX" 2>/dev/null) || LOCK_TMP=""
  if [ -n "$LOCK_TMP" ]; then
    echo "$SESSION_ID ${PPID:-0} $(date +%s)" > "$LOCK_TMP"
    mv "$LOCK_TMP" "$WT_PATH/.claude-session-lock" 2>/dev/null && \
      echo "AUTO: Created .claude-session-lock in '$WT_PATH' with session_id=$SESSION_ID (via WorktreeCreate hook)" >&2 || \
      { rm -f "$LOCK_TMP" 2>/dev/null; echo "WARNING: Failed to create lock file in '$WT_PATH'" >&2; }
  else
    echo "WARNING: Failed to create temp lock file in '$WT_PATH' — directory may have been removed" >&2
  fi
else
  echo "WARNING: WorktreeCreate fired for '$WT_PATH' but no session_id available. Lock file not created." >&2
fi

# W71: hide the lock from git so it never shows in `git status` (prevents the model
# from manually committing it to "clean up before merge-back" — root cause of the
# stray-commit-on-main corruption in a production session). Best-effort; never fatal.
if [ -f "$HOOKS_LIB_DIR/worktree-lock-exclude.sh" ]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/worktree-lock-exclude.sh"
  exclude_session_lock_from_git "$WT_PATH"
  command -v exclude_build_artifacts_from_git >/dev/null 2>&1 && exclude_build_artifacts_from_git "$WT_PATH"  # RC-1: node_modules/vendor never show as untracked
fi

link_shared_dependency_dir() {
  local source_dir="$1"
  local target_dir="$2"
  local label="$3"

  [ -d "$source_dir" ] || return 0
  [ -e "$target_dir" ] && return 0

  if ln -s "$source_dir" "$target_dir" 2>/dev/null; then
    echo "AUTO: Linked shared $label into worktree" >&2
  fi
}

# ── Auto-provision worktree for Laravel projects ────────────────────────────
if [ -n "$REPO_ROOT" ] && [ -n "$WT_PATH" ]; then
  # Copy .env if it exists in the parent (worktrees don't inherit it)
  if [ -f "$REPO_ROOT/.env" ] && [ ! -f "$WT_PATH/.env" ]; then
    cp "$REPO_ROOT/.env" "$WT_PATH/.env" 2>/dev/null && \
      echo "AUTO: Copied .env from repo root to worktree" >&2

    # W-conc-fix: the copied .env points every worktree at the SAME stateful
    # resources (cache/redis keyspace, dev DB). Under concurrent /v sessions that
    # causes cache-key collisions and dev-DB data races during browser verification.
    # Worktrees isolate the filesystem, NOT these — so isolate them here, keyed off
    # the session id. Portable env rewrite (no `sed -i` — BSD/GNU differ).
    if [ -f "$WT_PATH/.env" ] && [ -n "$SESSION_ID" ]; then
      WT_TOKEN=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9' | cut -c1-8)
      _set_env_var() {  # file key value — replace existing key or append; temp-file+mv
        local f="$1" k="$2" v="$3" t
        t=$(mktemp "${f}.XXXXXX" 2>/dev/null) || return 0
        grep -vE "^${k}=" "$f" 2>/dev/null > "$t" || true
        printf '%s=%s\n' "$k" "$v" >> "$t"
        mv "$t" "$f" 2>/dev/null || rm -f "$t" 2>/dev/null
      }
      # Unique cache/redis keyspace so concurrent worktrees don't read/evict each other.
      _set_env_var "$WT_PATH/.env" CACHE_PREFIX "wt_${WT_TOKEN}"
      _set_env_var "$WT_PATH/.env" REDIS_PREFIX "wt_${WT_TOKEN}_"
      # Dev DB isolation. sqlite file → unique per-worktree copy (isolated AND seeded).
      # :memory:/unset → already per-process isolated. Non-sqlite (mysql/pgsql) → cannot
      # safely auto-create a DB here; warn so the operator isolates the test/dev DB.
      _db_conn=$(grep -E '^DB_CONNECTION=' "$WT_PATH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
      if [ "$_db_conn" = "sqlite" ]; then
        _db_file=$(grep -E '^DB_DATABASE=' "$WT_PATH/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ')
        case "$_db_file" in
          ""|:memory:) : ;;  # per-process isolated; nothing to do
          *)
            _new_db="$WT_PATH/database/database-${WT_TOKEN}.sqlite"
            mkdir -p "$WT_PATH/database" 2>/dev/null
            if [ -f "$_db_file" ]; then
              cp "$_db_file" "$_new_db" 2>/dev/null && echo "AUTO: isolated dev sqlite DB → $_new_db (copied+seeded)" >&2
            else
              : > "$_new_db" 2>/dev/null && echo "AUTO: isolated dev sqlite DB → $_new_db (fresh; run migrations)" >&2
            fi
            [ -f "$_new_db" ] && _set_env_var "$WT_PATH/.env" DB_DATABASE "$_new_db"
            ;;
        esac
      elif [ -n "$_db_conn" ]; then
        echo "WARNING (W-conc-fix): DB_CONNECTION=$_db_conn — worktrees SHARE this dev DB. Concurrent browser verification will race on data. Configure a per-session test/dev DB (e.g. DB_DATABASE suffix) before running concurrent /v sessions on this repo." >&2
      fi
      echo "AUTO: isolated worktree cache prefix (wt_${WT_TOKEN}) for concurrency safety" >&2
    fi
  fi

  # Create Laravel storage directories (required for artisan commands)
  if [ -d "$WT_PATH/app" ] && [ -f "$WT_PATH/artisan" ]; then
    mkdir -p "$WT_PATH/storage/logs" "$WT_PATH/storage/framework/cache" "$WT_PATH/storage/framework/sessions" "$WT_PATH/storage/framework/views" 2>/dev/null && \
      echo "AUTO: Created storage directories in worktree" >&2
  fi

  # Reuse parent dependency installs when they already exist so worktree sessions
  # can run framework commands and targeted tests without a fresh install.
  link_shared_dependency_dir "$REPO_ROOT/vendor" "$WT_PATH/vendor" "vendor/"
  link_shared_dependency_dir "$REPO_ROOT/node_modules" "$WT_PATH/node_modules" "node_modules/"
fi

# Ensure stdout always has output on success — callers (EnterWorktree) check for non-empty stdout.
# Without this, the hook appears to "fail silently" even when everything worked.
echo "WORKTREE_CREATE_HOOK: OK — worktree provisioned at $WT_PATH" >&2
echo "$WT_PATH"
exit 0
