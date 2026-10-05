#!/usr/bin/env bash
# worktree-php-setup.sh — W62-F1 v3 — worktree PHP vendor provisioning.
#
# Gives a git worktree its OWN real, INDEPENDENT vendor/ (a copy-on-write clone of main's),
# so the worktree's own vendor/bin/<tool> (pest, phpunit) resolves __DIR__ to the worktree and
# loads the WORKTREE autoloader / WORKTREE source.
#
# Replaces the v2 "split symlink" (copy autoload.php + composer/ real, symlink the rest): that
# left vendor/bin symlinked to main, and PHP resolves __DIR__ THROUGH symlinks (php.net #46260),
# so `./vendor/bin/pest` ran MAIN's binary which loaded MAIN's vendor/autoload.php. Because a
# worktree shares main's composer.lock, both autoloaders carry the SAME
# `ComposerAutoloaderInit<lock-content-hash>` class → "Cannot redeclare class" FATAL once
# phpunit's bootstrap also loads the worktree autoload; and even absent a crash, main's loader
# (registered first) shadowed the worktree's App\ source so tests SILENTLY exercised main's code.
# Proven end-to-end with a real composer repro on 2026-05-27 (redeclare reproduced under split;
# CoW clone runs the worktree's own code in ~8ms). Fail-open: every error path → exit 0.
#
# Invoked by /v EXPLICITLY after `git worktree add` (the WorktreeCreate *event* does NOT fire for
# a Bash `git worktree add`); also wired as the WorktreeCreate hook for native worktree creation.
#
# Skip conditions (any one → exit 0 cleanly):
#   - CLAUDE_DISABLE_WORKTREE_PHP_SETUP=1
#   - No composer.json in repo root (not a PHP project)
#   - No vendor/ in repo root (operator must `composer install` first)
#   - Cannot resolve WORKTREE_PATH or REPO_ROOT
#   - WORKTREE_PATH resolves to the same canonical path as REPO_ROOT (catastrophic-guard)
#   - worktree already has its OWN real vendor (real dir + real vendor/bin, idempotent re-run)
#
# Resolution strategies for WORKTREE_PATH (tried in order):
#   1. stdin JSON  (.worktree_path  or  .worktree)
#   2. env var CLAUDE_WORKTREE_PATH
#   3. positional $1
#   4. git worktree list — last-added entry
#
# Environment escape: CLAUDE_DISABLE_WORKTREE_PHP_SETUP=1 → exit 0 immediately.

set -euo pipefail
trap 'exit 0' ERR

# ── env escape ───────────────────────────────────────────────────────────────
[ "${CLAUDE_DISABLE_WORKTREE_PHP_SETUP:-0}" = "1" ] && exit 0

# ── Resolve WORKTREE_PATH (4 fallback strategies — HIGH-4) ───────────────────
INPUT=$(cat 2>/dev/null || true)
WORKTREE_PATH=$(printf '%s' "$INPUT" | jq -r '.worktree_path // .worktree // empty' 2>/dev/null || true)
REPO_ROOT=$(printf '%s' "$INPUT" | jq -r '.repo_root // .main_worktree // empty' 2>/dev/null || true)

[ -z "$WORKTREE_PATH" ] && WORKTREE_PATH="${CLAUDE_WORKTREE_PATH:-}"
[ -z "$WORKTREE_PATH" ] && [ $# -gt 0 ] && WORKTREE_PATH="$1"

if [ -z "$WORKTREE_PATH" ]; then
    WORKTREE_PATH=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / {p=$2} END {print p}')
fi

[ -d "${WORKTREE_PATH:-}" ] || exit 0

if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT=$(git -C "$WORKTREE_PATH" worktree list --porcelain 2>/dev/null | awk '/^worktree / {print $2; exit}')
fi
[ -d "${REPO_ROOT:-}" ] || exit 0

# ── HIGH-4 catastrophic guard: refuse if WORKTREE_PATH IS the main repo ──────
WT_REAL=$(cd "$WORKTREE_PATH" 2>/dev/null && pwd -P)
RR_REAL=$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)
[ -z "$WT_REAL" ] && exit 0
[ -z "$RR_REAL" ] && exit 0
[ "$WT_REAL" = "$RR_REAL" ] && exit 0

# ── PHP project detection ────────────────────────────────────────────────────
[ -f "$REPO_ROOT/composer.json" ] || exit 0

# ── Read vendor-dir BEFORE existence check (HIGH-3) ──────────────────────────
VENDOR_DIR_NAME=$(python3 - "$REPO_ROOT/composer.json" <<'PYEOF' 2>/dev/null || echo "vendor"
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    import re
    vd = (cfg.get("config") or {}).get("vendor-dir", "vendor")
    # SECURITY: vendor-dir feeds a `rm -rf "$WORKTREE_PATH/$vd"`. Restrict to a SINGLE safe path
    # component (no "/", no "..", no leading dot) so it can NEVER escape the worktree — e.g. a
    # malicious/buggy "vendor-dir": "../../.." must not become `rm -rf <parent>`. Else → "vendor".
    if isinstance(vd, str) and re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9._-]*', vd) and '..' not in vd:
        print(vd)
    else:
        print("vendor")
except Exception:
    print("vendor")
PYEOF
)
VENDOR_DIR_NAME="${VENDOR_DIR_NAME:-vendor}"
SRC="$REPO_ROOT/$VENDOR_DIR_NAME"
DST="$WORKTREE_PATH/$VENDOR_DIR_NAME"

[ -d "$SRC" ] || exit 0  # main has no vendor

# ── Idempotency: skip if the worktree already has its OWN real vendor ────────
# "Own real vendor" = $DST is a REAL dir (not a symlink) AND vendor/bin is REAL (not a symlink
# to main). A symlinked $DST or $DST/bin is precisely the broken state we must FIX (PHP resolves
# __DIR__ through symlinks → main's bin/autoload), so it is NOT treated as idempotent.
if [ -d "$DST" ] && [ ! -L "$DST" ] \
   && [ -e "$DST/bin" ] && [ ! -L "$DST/bin" ] \
   && [ -f "$DST/autoload.php" ] && [ ! -L "$DST/autoload.php" ]; then
    exit 0
fi

# ── Safety re-check IMMEDIATELY before the destructive rm (defense-in-depth) ──
# Re-resolve $DST's parent NOW (not just at the earlier WT_REAL!=RR_REAL guard): this defends
# against a TOCTOU symlink swap of WORKTREE_PATH between that guard and here, and against any path
# surprise. VENDOR_DIR_NAME is already validated to a single safe component, so dirname($DST) is
# exactly WORKTREE_PATH. Require it to still resolve to THIS worktree and NOT to main. Bail fail-open.
_DST_PARENT=$(cd "$(dirname "$DST")" 2>/dev/null && pwd -P || echo "")
if [ -z "$_DST_PARENT" ] || [ "$_DST_PARENT" != "$WT_REAL" ] || [ "$_DST_PARENT" = "$RR_REAL" ]; then
    exit 0
fi

# ── Clear any pre-existing worktree vendor (plain symlink / old split / partial) ──
# $DST is GUARANTEED under THIS worktree (re-verified just above), so this never touches main.
if [ -L "$DST" ]; then
    rm -f "$DST"            # symlink (plain or split) → unlink only, never recurse
elif [ -d "$DST" ]; then
    rm -rf "$DST"           # stale/partial real dir (e.g. an old split) → clear it
fi
# If removal failed (perms/immutable), refuse to clone INTO a stale dir (cp -R into an existing
# dir would nest a corrupt vendor/vendor). Fail-open — the caller's composer-install fallback copes.
[ -e "$DST" ] && exit 0

# ── Clone main's vendor as REAL, INDEPENDENT files (copy-on-write where possible) ──
# NOT a symlink: PHP resolves __DIR__ through symlinks (#46260), so a symlinked vendor/bin makes
# the worktree run MAIN's binary + autoloader (redeclare fatal, or silent main-code tests — see
# header). A real vendor makes the worktree's own bin resolve to the worktree autoloader.
# CoW = near-instant + ~0 extra disk:
#   macOS/APFS → `cp -c` (clonefile);  Linux → `cp --reflink=auto` (CoW on btrfs/xfs, else a
#   transparent real byte-copy). Both yield independent real files; never a cross-tree symlink.
CLONE_OK=0
if [ "$(uname)" = "Darwin" ]; then
    cp -c -R "$SRC" "$DST" 2>/dev/null && CLONE_OK=1
else
    cp -R --reflink=auto "$SRC" "$DST" 2>/dev/null && CLONE_OK=1
fi
# Fallback 1: plain real copy (non-CoW FS / clonefile unsupported). Correct, just slower.
if [ "$CLONE_OK" != 1 ]; then
    rm -rf "$DST" 2>/dev/null
    cp -R "$SRC" "$DST" 2>/dev/null && CLONE_OK=1
fi
# Fallback 2 (last resort): a fresh composer install in the worktree.
if [ "$CLONE_OK" != 1 ]; then
    rm -rf "$DST" 2>/dev/null
    command -v composer >/dev/null 2>&1 && \
        ( cd "$WORKTREE_PATH" && composer install --no-interaction --no-scripts ) >/dev/null 2>&1 || true
fi

# ── Regenerate the worktree autoloader so any --optimize classmap ABSOLUTE paths point at the
# worktree, not main (PSR-4 prefixes are already runtime-relative via __FILE__, but an optimized
# classmap bakes absolute paths). Safe + cheap: the cloned files are independent and every package
# is present. The suffix stays = main's lock-hash, which is FINE now — only the worktree's own bin
# loads it, so there is no second autoloader to collide with.
# Only after a cp-based clone (CLONE_OK=1): composer-install fallback already dumped a correct
# worktree autoloader, and a failed/partial clone must NOT be dumped over.
if [ "$CLONE_OK" = "1" ] && [ -d "$DST" ] && [ ! -L "$DST" ] && command -v composer >/dev/null 2>&1; then
    ( cd "$WORKTREE_PATH" && composer dump-autoload --no-interaction ) >/dev/null 2>&1 || true
fi

exit 0
