#!/bin/bash
# vd-artifact-bothloc-test.sh — F19a bite test (forensic 2026-07-11).
# CLASS: a gate-runner artifact-presence check that looks at ONE side of the worktree
# boundary false-FAILs when the sibling gate wrote to the other side (wasted
# verify-done dispatches + provoked a verdict-tamper attempt). The verify-done
# dispatch template must instruct checking BOTH {{PROJECT_ROOT}}/.v/artifacts AND the
# RUN_ROOT's .v/artifacts on the AGENT_REVIEW step — and only report missing-from-BOTH.
# RED against dispatch-v-verify-done.md.pre-f19a-bak (single-side check), GREEN after.
# Usage: [VD_FILE=<template>] bash vd-artifact-bothloc-test.sh
set -u
F="${VD_FILE:-$HOME/.claude/skills/v/references/dispatch-v-verify-done.md}"
[ -f "$F" ] || { echo "FAIL: template missing: $F"; exit 1; }
LINE="$(grep -F 'AGENT_REVIEW_$SESSION_ID.md' "$F" | grep -v '^#' | head -1)"
[ -n "$LINE" ] || { echo "FAIL: AGENT_REVIEW check step missing entirely"; exit 1; }
echo "$LINE" | grep -qF '{{PROJECT_ROOT}}/.v/artifacts' || { echo "FAIL: AGENT_REVIEW step does not name {{PROJECT_ROOT}}/.v/artifacts"; exit 1; }
echo "$LINE" | grep -q 'RUN_ROOT' || { echo "FAIL: AGENT_REVIEW step does not name the RUN_ROOT side"; exit 1; }
echo "$LINE" | grep -qi 'missing from BOTH' || { echo "FAIL: step lacks the missing-from-BOTH condition"; exit 1; }
echo "vd-artifact-bothloc-test: PASS"
