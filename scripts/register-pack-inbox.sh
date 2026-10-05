#!/usr/bin/env bash
# register-pack-inbox.sh — self-registration helper for the pack-inbox convention.
#
# WHAT: idempotently appends a project root to the shared registry
# (~/.claude/runtime/pack-inbox-registry.txt) that `v-inbox` (via run-v-packs-inbox-nightly.sh,
# its engine) walks. Mirrors the exact self-registering-registry idiom
# stop-drain-deferred-merges.sh already uses for ~/.claude/runtime/v-drain-repos.txt (grep -qxF
# ... || append), so the ecosystem has ONE pattern for "a repo now owes attention" rather than a
# second bespoke one.
#
# USAGE:
#   register-pack-inbox.sh <project_root>
#
# Called by any producer that just queued pack(s) into <project_root>/.v/packs/inbox/ (see
# ~/.claude/skills/references/v-core-pack-inbox.md). Safe to call redundantly — dedup is by exact
# path match. Never removes an entry; pruning of drained projects is run-v-packs-inbox-nightly.sh's
# job (it re-checks the inbox is actually empty before dropping a registry line).
#
# Exit codes: 0 = registered (or already present); 1 = bad/missing arg.
set -u

PROJECT_ROOT="${1:-}"
if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: register-pack-inbox.sh <project_root>" >&2
  exit 1
fi

# Normalize to an absolute path so registry entries are comparable regardless of caller cwd.
case "$PROJECT_ROOT" in
  /*) : ;;
  *) PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P)" || { echo "register-pack-inbox: cannot resolve '$1'" >&2; exit 1; } ;;
esac

RUNTIME_DIR="${V_RUNTIME_DIR:-$HOME/.claude/runtime}"
REGISTRY="$RUNTIME_DIR/pack-inbox-registry.txt"

mkdir -p "$RUNTIME_DIR" 2>/dev/null || { echo "register-pack-inbox: cannot create $RUNTIME_DIR" >&2; exit 1; }

grep -qxF "$PROJECT_ROOT" "$REGISTRY" 2>/dev/null || printf '%s\n' "$PROJECT_ROOT" >> "$REGISTRY" 2>/dev/null || true

exit 0
