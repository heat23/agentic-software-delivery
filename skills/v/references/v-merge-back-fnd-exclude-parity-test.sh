#!/usr/bin/env bash
# v-merge-back-fnd-exclude-parity-test.sh — R4 (2026-07-01)
# merge-back's _FND_EXCLUDE_RE is the allowlist that tells FND-3 "these /v artifacts at main root are NOT
# foreign source WIP — don't defer the merge over them." If it drifts behind the artifact set, a real fix's
# merge-back FALSE-BLOCKS on a stray artifact and the branch STRANDS. Observed 2026-07-01: an untracked
# WORKFLOW_BLAST_RADIUS_<sid>.md + a DISPATCH_LEDGER.jsonl deadlocked a whole fleet of parallel sessions.
#
# This is a CONTRACT-PARITY guard: it enumerates the artifact prefixes the stale-artifact sweep itself
# manages (single source of truth) and asserts every one is matched by the live _FND_EXCLUDE_RE — so any
# FUTURE artifact type added to the sweep list is automatically re-verified here. Plus the two explicit
# red cases from the incident, plus source-file negatives (the regex must never hide real WIP).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB="$HERE/v-merge-back.sh"
SWEEP="$HERE/v-stale-artifact-sweep.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
[ -f "$MB" ] || { echo "FATAL: merge-back missing at $MB"; exit 2; }
[ -f "$SWEEP" ] || { echo "FATAL: sweep source-of-truth missing at $SWEEP"; exit 2; }

# Pull the LIVE regex straight from the shipped script (no copy — single source of truth).
eval "$(grep -m1 '^_FND_EXCLUDE_RE=' "$MB")"
[ -n "${_FND_EXCLUDE_RE:-}" ] || { echo "FATAL: could not extract _FND_EXCLUDE_RE from $MB"; exit 2; }
SID="aaaaaaaa-1111-4222-8333-444455556666"
match(){ printf '%s' "$1" | grep -qE "$_FND_EXCLUDE_RE"; }

echo "== R4 PARITY: every artifact the stale-sweep manages must be excluded from FND-3's foreign-WIP scan =="
n=0
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  fn="${tok/\*/$SID}"           # 'SESSION_LOG_*.yaml' → SESSION_LOG_<sid>.yaml
  n=$((n+1))
  if match "$fn"; then ok "sweep artifact excluded: $fn"; else no "sweep artifact NOT excluded by _FND_EXCLUDE_RE (drift): $fn"; fi
done < <(grep -oE "'[A-Z][A-Z_]*_\*\.(md|ya?ml)'" "$SWEEP" | sed -E "s/^'//; s/'\$//")
[ "$n" -ge 10 ] && ok "enumerated $n sweep artifact patterns (parity source non-empty)" || no "sweep enumeration too small ($n) — parser drift?"

echo "== R4 explicit red cases (the exact 2026-07-01 fleet blockers) =="
match "WORKFLOW_BLAST_RADIUS_${SID}.md" && ok "WORKFLOW_BLAST_RADIUS_<sid>.md excluded" || no "WORKFLOW_BLAST_RADIUS_<sid>.md NOT excluded (the stray artifact that deadlocked the fleet)"
match "DISPATCH_LEDGER.jsonl"           && ok "DISPATCH_LEDGER.jsonl excluded (.jsonl ext)" || no "DISPATCH_LEDGER.jsonl NOT excluded (.jsonl escapes the ext anchor)"

echo "== R4 SYMMETRY: real source files must NEVER be excluded (no over-broadening → never hide real WIP) =="
for src in "app/Services/ExampleService.php" "resources/js/Pages/Settings/Example.tsx" "routes/dashboard.php" "src/index.ts" "config/app.php"; do
  if match "$src"; then no "SOURCE FILE wrongly excluded (over-broad regex hides real WIP): $src"; else ok "source file correctly NOT excluded: $src"; fi
done

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
