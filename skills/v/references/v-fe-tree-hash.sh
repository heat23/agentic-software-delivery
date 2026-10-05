#!/usr/bin/env bash
# v-fe-tree-hash.sh — emit a single deterministic sha256 over the TRACKED front-end
# source + build-config files of a project (Lever B — shared FE build reuse).
#
# Usage: [PROJECT_ROOT=<dir>] bash v-fe-tree-hash.sh
# Output: one 64-hex sha256 on stdout (nothing else), exit 0.
#
# Properties (relied on by the build-reuse contract in v-run-gates.sh and the
# workflow-verifier):
#   - TRACKED-only: derived from `git ls-files`, so untracked scratch / node_modules /
#     build output never perturb the hash (deterministic, junk-immune).
#   - WORKING-TREE content: hashes the on-disk bytes of each tracked file, so an
#     uncommitted edit to a tracked FE source DOES change the hash (reuse must rebuild).
#   - Stack-agnostic: matches the common JS/TS/Vue/Svelte/CSS extensions + the build
#     config + lockfiles that change build output.
set -uo pipefail

PROJ="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Portable sha256 (macOS ships shasum, Linux ships sha256sum).
_sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi; }

FILES=$(git -C "$PROJ" ls-files -z 2>/dev/null \
  | tr '\0' '\n' \
  | grep -iE '\.(ts|tsx|js|jsx|mjs|cjs|vue|svelte|css|scss|sass|less|styl)$|(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb|(vite|tailwind|postcss|svelte|rollup|webpack|next)\.config\.[a-z0-9]+)$' \
  | LC_ALL=C sort)

if [ -z "$FILES" ]; then
  # No FE surface — emit the hash of the empty set (stable, never errors).
  printf '' | _sha256 | awk '{print $1}'
  exit 0
fi

# Hash "<relpath>:<content-sha>" per file (relpath keeps it machine-stable; content-sha
# captures working-tree edits), then fold into one digest.
printf '%s\n' "$FILES" | while IFS= read -r f; do
  [ -f "$PROJ/$f" ] && printf '%s:%s\n' "$f" "$(_sha256 < "$PROJ/$f" | awk '{print $1}')"
done | _sha256 | awk '{print $1}'
