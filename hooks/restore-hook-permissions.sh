#!/usr/bin/env bash
# restore-hook-permissions.sh
# Event: PostToolUse/Write|Edit (async)
# Version: 1.0.0
#
# WHY: The Claude Code Edit and Write tools create files with 0600 permissions,
# stripping +x from hook scripts. This silently disables the entire safety layer.
# This happened across a large share of the hooks in production, disabling guards
# such as database destruction and force push protection.
#
# BEHAVIOUR: After any Write/Edit, if the file is inside ~/.claude/hooks/,
# restore execute permission. One stat + one chmod — negligible cost.

set -euo pipefail



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly so the hook works under any $HOME (CI, sandbox, mirrored config).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.path // .tool_input.file_path // ""')

[ -z "$FILE" ] && exit 0

# Only act on hook scripts
case "$FILE" in
  */.claude/hooks/*.sh)
    if [ -f "$FILE" ] && [ ! -x "$FILE" ]; then
      chmod +x "$FILE" 2>/dev/null || true
    fi
    ;;
esac

exit 0
