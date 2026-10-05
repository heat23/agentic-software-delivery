#!/usr/bin/env bash
# v-audit-routing-coverage-test.sh — guards the deep UI-audit reachability fix
# (skill-review 2026-07-05 P1: v-ui-audit declared `invoked-by: [/v, ...]` but
# /v's routing table + invokes list never mentioned it, so "audit my UI"
# routed to /v-check and the deeper 13-dim audit was unreachable via /v).
#
# 2026-07-06: v-ui-audit was RETIRED and absorbed into /v-audit-code (see
# references/deep-ux-audit.md). Re-pointed to guard the successor skill so the
# same reachability regression can't recur under the new name.
#
# BITES when either side of the contract regresses:
#   1. v-audit-routing.md loses its /v-audit-code classification row / section
#   2. /v SKILL.md's `invokes:` list drops v-audit-code
#
# Env overrides (for red-oracle runs against .pre-*-bak / pre-image copies):
#   V_ROUTING_FILE  — path to v-audit-routing.md under test
#   V_VSKILL_FILE   — path to /v SKILL.md under test
#
# Exit: 0 = routing contract intact; 1 = regressed (with reasons on stderr).
set -uo pipefail

ROUTING="${V_ROUTING_FILE:-$HOME/.claude/skills/v/references/v-audit-routing.md}"
VSKILL="${V_VSKILL_FILE:-$HOME/.claude/skills/v/SKILL.md}"

fail=0

if ! grep -q '`/v-audit-code`' "$ROUTING"; then
  echo "FAIL: $ROUTING has no /v-audit-code routing entry (classification row + deeper-tier section expected)" >&2
  fail=1
else
  # The classification TABLE row specifically (a trigger-phrase row, not just prose)
  if ! grep -E '^\|.*"(UI audit|UX audit)".*\|.*/v-audit-code' "$ROUTING" >/dev/null; then
    echo "FAIL: $ROUTING mentions /v-audit-code but the Audit Classification table row with UI/UX trigger phrases is gone" >&2
    fail=1
  fi
fi

if ! grep -E '^\s+invokes:.*(/?v-audit-code)' "$VSKILL" >/dev/null; then
  echo "FAIL: $VSKILL invokes: list does not include v-audit-code" >&2
  fail=1
fi

exit "$fail"
