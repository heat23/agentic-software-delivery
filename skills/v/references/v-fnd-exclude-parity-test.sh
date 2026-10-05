#!/usr/bin/env bash
# v-fnd-exclude-parity-test.sh — class bite-test for _FND_EXCLUDE_RE (FND3-EXCL, forensic 2026-07-03)
#
# CLASS UNDER TEST: enumeration drift in v-merge-back.sh's FND-3 "foreign source WIP"
# exclusion. On 2026-07-03 a PRE_FLIGHT_ADDENDUM_*.md that slipped the list stranded
# 4 gauntleted fixes in a production repo.
# This test pins BOTH directions:
#   1. every artifact filename shape the fleet emits at repo root is EXCLUDED
#      (incl. a synthetic FUTURE artifact type — the generic-shape rule must catch it), and
#   2. real source/user paths are NOT excluded (the rule must never eat source WIP).
# RED oracle: the regex in v-merge-back.sh.pre-fnd3exclude-bak must FAIL case set 1
# (proves the test bites on the pre-fix code, not vacuously green).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

extract_re() { grep -m1 "^_FND_EXCLUDE_RE=" "$1" | sed -e "s/^_FND_EXCLUDE_RE='//" -e "s/'\$//"; }

RE_LIVE="$(extract_re "$DIR/v-merge-back.sh")"
[ -n "$RE_LIVE" ] || { echo "FAIL: could not extract _FND_EXCLUDE_RE from live v-merge-back.sh"; exit 1; }

# ── Case set 1: orchestrator exhaust — every prefix observed in the wild 2026-07-03
# (repo roots + .v/artifacts of two production repos) plus generic future shapes.
EXCLUDED=(
  "PRE_FLIGHT_ADDENDUM_aaaa0000-1111-4111-8111-000000000001.md"
  "PRE_FLIGHT_REPORT_bbbb0000-1111-4111-8111-000000000002.md"
  "PRE_FLIGHT_REPORT_0a0a0a0a-1111-4111-8111-00000000c002.md.stale.67109"
  "SESSION_LOG_MISSING_11110000-1111-2222-3333-444455556666.md"
  "SESSION_LOG_FAILED_22220000-1111-4111-8111-000000000003.md"
  "SESSION_LOG_33330000-1111-4111-8111-000000000004.yaml"
  "SESSION_LOG_33330000-1111-4111-8111-000000000004.yaml.invalid"
  "DISPATCH_PROVENANCE_44440000-0000-1111-2222-333344445555.log"
  "DISPATCH_LEDGER.jsonl"
  "OP_TELEMETRY_33330000-1111-4111-8111-000000000004.json"
  "TRIVIAL_PASS_99990000-aaaa-bbbb-cccc-ddddeeeeffff.md"
  "PLANNING_PASS_99990000-aaaa-bbbb-cccc-ddddeeeeffff.md"
  "STOP_REARM_ESCAPE_99990000-aaaa-bbbb-cccc-ddddeeeeffff.md"
  "MERGE_ALL_REPORT_20260101_000000.md"
  "BITE_LEDGER_55550000-1111-4111-8111-000000000005.md"
  "GAUNTLET_SKIPPED_99990000-aaaa-bbbb-cccc-ddddeeeeffff.md"
  "AGENT_REVIEW_66660000-1111-2222-3333-444455556666.md"
  "IMPLEMENTATION_REPORT_77770000-1111-4111-8111-000000000006.md"
  "MERGE_DEFERRED_88880000-1111-4111-8111-000000000007.md"
  # the CLASS case: an artifact type that does not exist yet — generic-shape rule must catch it
  # (full session-UUID suffix, the fleet's ${CLAUDE_SESSION_ID} naming convention)
  "SOME_FUTURE_ARTIFACT_1a2b3c4d-0000-1111-2222-333344445555.md"
)

# ── Case set 2: real source / user files — must NEVER be excluded.
# Includes the adversarial-review F1-1 corpus (2026-07-03): ordinary SCREAMING_SNAKE files with
# hex8/decimal/timestamp suffixes are REAL user files, not fleet artifacts — a bare hex8/timestamp
# generic rule swallowed all of these (empirically). Only a FULL-UUID suffix marks fleet exhaust.
NOT_EXCLUDED=(
  "app/Adapters/Contracts/ApiClient.php"
  "app/Http/Controllers/Billing/StripeWebhookController.php"
  "routes/console.php"
  "config/app.php"
  "tests/Feature/Adapters/HmacApiClientTest.php"
  "README.md"
  "CHANGELOG.md"
  "NOTES.md"
  "docs/prompt-packs/plan.md"
  "resources/js/pages/Dashboard.tsx"
  "INVOICE_12345678.md"
  "CHANGELOG_20260703.md"
  "RELEASE_NOTES_20260703.md"
  "API_CREDENTIALS_a1b2c3d4.json"
  "USER_EXPORT_cafebabe.log"
  "MIGRATION_NOTES_2026070312.md"
  "ANOTHER_NEW_THING_20260815_101500.yaml"
)

fails=0
for f in "${EXCLUDED[@]}"; do
  if ! printf '%s\n' "$f" | grep -qE "$RE_LIVE"; then
    echo "FAIL (live): artifact NOT excluded -> would inflate FND-3: $f"
    fails=$((fails+1))
  fi
done
for f in "${NOT_EXCLUDED[@]}"; do
  if printf '%s\n' "$f" | grep -qE "$RE_LIVE"; then
    echo "FAIL (live): source path wrongly excluded -> FND-3 blind to real WIP: $f"
    fails=$((fails+1))
  fi
done

# ── RED oracle: pre-fix snapshot must fail at least the ADDENDUM + TRIVIAL_PASS cases.
BAK="$DIR/v-merge-back.sh.pre-fnd3exclude-bak"
if [ -f "$BAK" ]; then
  RE_OLD="$(extract_re "$BAK")"
  red_hits=0
  for f in "PRE_FLIGHT_ADDENDUM_aaaa0000-1111-4111-8111-000000000001.md" \
           "TRIVIAL_PASS_99990000-aaaa-bbbb-cccc-ddddeeeeffff.md" \
           "SOME_FUTURE_ARTIFACT_1a2b3c4d-0000-1111-2222-333344445555.md"; do
    printf '%s\n' "$f" | grep -qE "$RE_OLD" || red_hits=$((red_hits+1))
  done
  if [ "$red_hits" -eq 0 ]; then
    echo "FAIL (red-oracle): pre-fix regex already excludes all class cases — test does not bite"
    fails=$((fails+1))
  else
    echo "red-oracle ok: pre-fix regex misses $red_hits/3 class cases (test bites)"
  fi
else
  echo "WARN: red-oracle snapshot missing ($BAK) — live assertions still enforced"
fi

if [ "$fails" -eq 0 ]; then
  echo "PASS: fnd-exclude-parity — ${#EXCLUDED[@]} artifact shapes excluded, ${#NOT_EXCLUDED[@]} source paths preserved"
  exit 0
fi
echo "FAIL: $fails assertion(s)"
exit 1
