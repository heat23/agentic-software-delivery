#!/usr/bin/env bash
# dependency-install-guard.sh
# SAFETY HOOK — P2
# Event: PreToolUse/Bash
# Purpose: Intercept new package installations and require user confirmation.
#          Prevents typosquatting, malicious packages, and unaudited dependencies.
# NOTE: Does NOT block bare "npm install" (from package.json) or "composer install".
#       Only blocks installs of NEW named packages.

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "dependency-install-guard"
fi



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# W33: ensure HOOKS_LIB_DIR is defined before sourcing (fail-safe under set -u).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_skip

SEGMENT_LIB="$HOOKS_LIB_DIR/command-segments.sh"
if [[ ! -f "$SEGMENT_LIB" ]]; then
  profile_done
  exit 0
fi
source "$SEGMENT_LIB"

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  profile_done
  exit 0
fi

# ── Bypass: INSTALL_CONFIRMED=1 env var skips the guard (set after user approves in chat) ──
if [ "${INSTALL_CONFIRMED:-0}" = "1" ]; then
  profile_done
  exit 0
fi

# ── Bypass: runner-managed implementation-only sessions may install declared deps ──
# Consistent with peer hooks (session-context-loader.sh, check-review-artifact.sh,
# enforce-pre-commit-gates.sh) that already honor this env var. The ecosystem
# remediation runner exports this only for implementation-only subprocesses.
if [ "${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}" = "1" ]; then
  profile_done
  exit 0
fi

SEGMENT=""
while IFS= read -r SEGMENT; do
  [ -z "$SEGMENT" ] && continue

  # ── npm/pnpm/yarn: new named packages ───────────────────────────────────────
  if printf '%s\n' "$SEGMENT" | grep -qE '^\s*(npm|pnpm|yarn)\s+(install|add|i)\b'; then
    # Extract only valid package names: must start with @, a letter, or digit — not shell redirects/flags
    PACKAGES=$(printf '%s\n' "$SEGMENT" \
      | sed -E 's/^[[:space:]]*(npm|pnpm|yarn)[[:space:]]+(install|add|i)([[:space:]]+|$)//' \
      | tr ' ' '\n' \
      | grep -E '^(@[a-zA-Z0-9_-]+/)?[a-zA-Z0-9_@][a-zA-Z0-9_./@-]*$' \
      | grep -vE '^-' \
      | head -5 \
      | tr '\n' ' ')

    if [ -n "$PACKAGES" ]; then
      REASON=$(printf 'BLOCKED: New package installation requires user confirmation.\n\nPackage(s): %s\nCommand: %s\n\nBefore proceeding:\n1. Verify package name at npmjs.com (check for typosquatting)\n2. Check weekly downloads — new packages with <1000 downloads are high risk\n3. Verify publisher identity and GitHub repo\n4. Confirm with the user in chat, then run: npm audit after install\n\nTo proceed, ask the user to confirm this package installation.' "$PACKAGES" "$SEGMENT")
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      profile_done
      exit 0
    fi
  fi

  # ── composer: new named packages ────────────────────────────────────────────
  if printf '%s\n' "$SEGMENT" | grep -qE '^\s*composer\s+require\b'; then
    PACKAGES=$(printf '%s\n' "$SEGMENT" \
      | sed -E 's/^[[:space:]]*composer[[:space:]]+require([[:space:]]+|$)//' \
      | tr ' ' '\n' \
      | grep -vE '^-' \
      | grep -vE '^$' \
      | head -5 \
      | tr '\n' ' ')

    if [ -n "$PACKAGES" ]; then
      REASON=$(printf 'BLOCKED: New package installation requires user confirmation.\n\nPackage(s): %s\nCommand: %s\n\nBefore proceeding:\n1. Verify package at packagist.org\n2. Check GitHub stars and last commit date\n3. Verify this is the official package (check vendor name carefully)\n4. Run: composer audit after install\n\nTo proceed, ask the user to confirm this package installation.' "$PACKAGES" "$SEGMENT")
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      profile_done
      exit 0
    fi
  fi
done < <(split_shell_command_segments "$COMMAND")

profile_done
exit 0
