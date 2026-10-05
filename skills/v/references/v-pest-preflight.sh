#!/usr/bin/env bash
# v-pest-preflight.sh — ensure ./vendor is a REAL directory (not a symlink) before Pest runs in a worktree.
#
# Forensic 2026-06-17 (NEW-CI-003): the model ran `./vendor/bin/pest` MANUALLY in a
# worktree during the TDD red/green loop and burned MANY turns on "facade root has not been set" /
# `worktrees\fix\...` namespace errors. Cause: a SYMLINKED vendor makes PHP resolve __DIR__ THROUGH the
# symlink, so `./vendor/bin/pest` runs MAIN's autoloader → MAIN's Tests\ namespace → thousands of false
# failures (php.net #46260). The gate runner (v-run-gates.sh) already guards this via _vendor_symlinked,
# but the MANUAL TDD loop did NOT — this helper closes that gap. Call it before any worktree Pest run:
#   bash ~/.claude/skills/v/references/v-pest-preflight.sh   # from the worktree dir
# Idempotent + fail-open. Exit 0 = vendor is real (or no vendor / not PHP). Exit 3 = STILL symlinked after
# an attempted repair (caller should treat the ensuing Pest output as INCONCLUSIVE, not as real failures).
set -u
_symlinked() { [ -L vendor ] || { [ -d vendor ] && [ -L vendor/bin ]; }; }

[ -e vendor ] || exit 0      # no vendor at all (non-PHP project, or not yet bootstrapped) — nothing to do
_symlinked || exit 0         # already a real vendor — fast path, the common case

_setup="$HOME/.claude/hooks/worktree-php-setup.sh"
if [ -f "$_setup" ]; then
  echo "v-pest-preflight: vendor is SYMLINKED — repairing via worktree-php-setup.sh (CoW-clone) BEFORE Pest, to avoid the 'facade root not set' / namespace break that runs MAIN's autoloader." >&2
  # SREV-002: worktree-php-setup.sh takes the worktree path as its positional arg ($1) and derives the
  # repo root itself (it ignores REPO_ROOT/WORKTREE_PATH env vars — they read JSON stdin). Pass $PWD only;
  # don't construct a REPO_ROOT here (the dead env var also dragged in a macOS /private/var-vs-/var mismatch).
  bash "$_setup" "$PWD" >/dev/null 2>&1 || true
else
  echo "v-pest-preflight: WARNING worktree-php-setup.sh not found — cannot repair a symlinked vendor automatically." >&2
fi

if _symlinked; then
  echo "v-pest-preflight: WARNING vendor is STILL symlinked after repair — Pest will load MAIN's autoloader and may report FALSE failures. Fix manually ('bash ~/.claude/hooks/worktree-php-setup.sh \"$PWD\"') or run Pest from the main checkout; treat this run's output as INCONCLUSIVE." >&2
  exit 3
fi
exit 0
