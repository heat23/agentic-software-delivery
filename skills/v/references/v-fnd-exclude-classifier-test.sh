#!/usr/bin/env bash
# v-fnd-exclude-classifier-test.sh — W71-F8 (forensic 2026-07-02).
#
# CLASS UNDER TEST: the FND-3 "foreign source WIP" classifier counting the
# orchestrator's own exhaust as a sibling's source work. On 2026-07-02 every
# fleet deferral marker listed OP_TELEMETRY_*.json, GAUNTLET_SKIPPED_*.md,
# .claude/agent-memory/** and bootstrap/ssr/ssr-manifest.json as "foreign
# uncommitted SOURCE files" — inflating the defer condition with files that
# never clear on their own.
#
# Table test over _FND_EXCLUDE_RE extracted from the LIVE v-merge-back.sh
# (single definition, shared by FND-3 detect + FND-2 witness — the parity
# test pins that sharing; this test pins the CLASSIFICATION).
#
# Run: bash v-fnd-exclude-classifier-test.sh [/path/to/v-merge-back.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MB="${1:-${V_MERGE_BACK_SCRIPT:-$HERE/v-merge-back.sh}}"
[ -f "$MB" ] || { echo "SKIP: script-under-test not found ($MB)"; exit 0; }

_re_line=$(grep -m1 "^_FND_EXCLUDE_RE=" "$MB")
[ -n "$_re_line" ] || { echo "FATAL: _FND_EXCLUDE_RE not found in $MB"; exit 1; }
eval "$_re_line"

PASS=0; FAIL=0
excluded(){ # $1=path — must be classified as orchestrator exhaust (excluded)
  if printf '%s\n' "$1" | grep -qE "$_FND_EXCLUDE_RE"; then
    PASS=$((PASS+1)); printf '  ok  excluded: %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  NO  NOT excluded (counts as foreign source WIP): %s\n' "$1"
  fi
}
included(){ # $1=path — must still count as real source WIP (deferral-worthy)
  if printf '%s\n' "$1" | grep -qE "$_FND_EXCLUDE_RE"; then
    FAIL=$((FAIL+1)); printf '  NO  wrongly excluded (real source WIP ignored): %s\n' "$1"
  else
    PASS=$((PASS+1)); printf '  ok  included: %s\n' "$1"
  fi
}

echo "== FND-3 classifier :: orchestrator exhaust vs real source WIP =="

# Orchestrator exhaust — every class observed in the 2026-07-02 deferral markers
excluded 'OP_TELEMETRY_11110000-0000-4000-8000-000000000001.json'
excluded 'GAUNTLET_SKIPPED_11110000-0000-4000-8000-000000000002.md'
excluded '.claude/agent-memory/v-qa-reviewer/MEMORY.md'
excluded '.claude/agent-memory/v-qa-reviewer/project_example_note.md'
excluded 'bootstrap/ssr/ssr-manifest.json'
# Pre-existing exclusions must keep holding (regression guard)
excluded 'SESSION_LOG_11110000-0000-4000-8000-000000000003.yaml'
excluded 'SESSION_LOG_11110000-0000-4000-8000-000000000004.yaml.invalid'
excluded '.v/tmp/anything.txt'
excluded '.worktrees/foo/bar.php'
excluded 'sub/dir/.claude-session-lock'
excluded 'HANDOFF_11110000-0000-4000-8000-000000000003.md'

# Real source WIP — must STILL trigger the FND-3 defer (never weaken the guard)
included 'app/Services/ExampleImportService.php'
included 'resources/js/Components/widgets/ExampleTrendChart.tsx'
included 'SKILL.md'
included 'audits/validate_v_changes.py'
included 'mockup-1-bold-dark.html'
included 'database/migrations/2026_07_02_000001_add_x.php'
# near-misses: exhaust-LOOKING names that are actually source must count
included 'app/Telemetry/OP_TELEMETRY_helper.php'
included 'bootstrap/ssr/ssr.js'
included '.claude/agents/custom-agent.md'

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
