#!/usr/bin/env bash
# stale-sweep-sessionlog-exclusion-test.sh — ORCHFIX-A3 class harness (forensics 2026-07-02).
# CLASS: telemetry-store split-brain — the W25 sweep archived
# canonical SESSION_LOGs into .v/archive/, which every detector/resolver is blind to, producing
# provably-false MISSING markers shortly afterward and resurrecting quarantined .invalid content
# under clean names. Session logs are the RECORD, never sweepable pollution.
# Runs the REAL sweep bash block on a fixture. RED oracle: the .pre-orchfix0702-bak sweep doc
# still lists 'SESSION_LOG_*.yaml' as a sweep pattern.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$HERE/v-stale-artifact-sweep.md"
BAK="$HERE/v-stale-artifact-sweep.md.pre-orchfix0702-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT

# Source-level contract.
awk '/^```bash/{f=1;next}/^```/{f=0}f' "$DOC" | grep -q "SESSION_LOG_\*\.yaml" \
  && no "live sweep still lists SESSION_LOG_*.yaml as sweepable" \
  || ok "live sweep excludes SESSION_LOG_* (telemetry is the record)"
[ -f "$BAK" ] && { awk '/^```bash/{f=1;next}/^```/{f=0}f' "$BAK" | grep -q "SESSION_LOG_\*\.yaml" \
  && ok "RED oracle: pre-fix sweep archived SESSION_LOGs (the split-brain producer)" \
  || no "RED oracle: backup lacks the pattern?"; }

# Behavioral round-trip: run the real block; a prior-session SESSION_LOG must STAY, a
# prior-session UX_CRITIQUE must be archived.
git -C "$TD" init -q >/dev/null 2>&1
OLD="99990000-2222-4222-8222-000000000001"
CUR="99990000-2222-4222-8222-000000000002"
printf 'log\n' > "$TD/SESSION_LOG_${OLD}.yaml"
printf 'crit\n' > "$TD/UX_CRITIQUE_${OLD}.md"
mkdir -p "$TD/.v/tmp"; date +%s > "$TD/.v/tmp/v-invocation-start-${CUR}.txt"
touch -t 202601010000 "$TD/SESSION_LOG_${OLD}.yaml" "$TD/UX_CRITIQUE_${OLD}.md"
( cd "$TD" && PROJECT_ROOT="$TD" CLAUDE_SESSION_ID="$CUR" bash -c "$(awk '/^```bash/{f=1;next}/^```/{f=0}f' "$DOC")" ) >/dev/null 2>&1
[ -f "$TD/SESSION_LOG_${OLD}.yaml" ] && ok "round-trip: prior-session SESSION_LOG stays in place" \
                                     || no "round-trip: SESSION_LOG was archived (split-brain live again)"
[ ! -f "$TD/UX_CRITIQUE_${OLD}.md" ] && [ -f "$TD/.v/archive/${OLD}/UX_CRITIQUE_${OLD}.md" ] \
  && ok "round-trip: prior-session UX_CRITIQUE still archived (sweep function intact)" \
  || no "round-trip: sweep no longer archives at all (over-fixed)"

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
