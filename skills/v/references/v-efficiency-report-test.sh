#!/usr/bin/env bash
# v-efficiency-report-test.sh — coverage + smoke for v-efficiency-report.sh (the one-stop efficiency
# dashboard that combines v-cache-burn.py (cache_read burn) + v-telemetry-aggregate.sh (per-dispatch cost)).
# It must emit its two sections + the header even on an empty/fresh repo (no transcripts, no dispatch provenance).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/v-efficiency-report.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$REPORT" ] || { echo "  NO  v-efficiency-report.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

echo "== v-efficiency-report :: emits its sections on a fresh repo =="
T=$(mktemp -d)
OUT=$(bash "$REPORT" --repo "$T" --since-hours 999 --packs-per-day 100 2>&1)
printf '%s' "$OUT" | grep -qF "EFFICIENCY REPORT"        && ok "report header present"                 || no "no report header"
printf '%s' "$OUT" | grep -qiE "cache_read burn"         && ok "section 1 (cache_read burn) present"   || no "section 1 missing"
printf '%s' "$OUT" | grep -qiE "per-dispatch"            && ok "section 2 (dispatch cost) present"     || no "section 2 missing"
# fresh repo => no dispatch provenance => the no-data hint, not a crash
printf '%s' "$OUT" | grep -qiE "no DISPATCH_PROVENANCE" && ok "fresh repo degrades gracefully (no-data hint)" || no "no graceful no-data path"
rm -rf "$T"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
