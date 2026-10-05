#!/usr/bin/env bash
# orch-eff-readiness-test.sh — BITE for F3 (2026-06-30).
# v-stop-readiness.sh must PREVIEW the gauntlet-attestation-witness gate (the #1 terminal block the model
# hits AFTER a false-green readiness). With the 3 core artifacts present and NO witness, the preview must
# flag "gauntlet-attestation witness missing". RED against the pre-F3 v-stop-readiness.sh.bak (no check).
set -uo pipefail
RS="${V_READINESS_SCRIPT:-$HOME/.claude/skills/v/references/v-stop-readiness.sh}"
[ -f "$RS" ] || { echo "FAIL: readiness script not found: $RS"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }
SID="bitef3-$$-4444-4444-444444444444"   # hermetic per-process id ($$), not date +%s (collides under concurrent sweep)
for a in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  printf 'Model: haiku\nSID: %s\nMode: full\n\n## Body\nplaceholder content for the F3 bite fixture, padded to clear any size floor.\n\nOverall Status: PASS\n' \
    "$SID" > "$TMP/${a}_${SID}.md"
done
rm -f "$HOME/.claude/runtime/v-gauntlet-attestation-${SID}.json" 2>/dev/null || true   # ensure no witness

OUT="$(bash "$RS" "$SID" "$TMP" 2>&1 || true)"
if printf '%s' "$OUT" | grep -qiE 'gauntlet-attestation witness (missing|not)'; then
  echo "PASS (F3): readiness previews the missing attestation witness"
  exit 0
else
  echo "FAIL (F3): readiness did NOT flag the missing attestation witness (pre-F3 — no such check)"
  exit 1
fi
