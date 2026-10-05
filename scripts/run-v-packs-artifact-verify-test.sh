#!/usr/bin/env bash
# run-v-packs-artifact-verify-test.sh — BEHAVIORAL harness for the opt-in on-disk gate-artifact
# self-verification (_gauntlet_artifacts_verified, 2026-07-04 resilience pass).
#
# WHY: a log's "GAUNTLET_ATTESTED: yes" text is not proof the gate artifacts it attests are still on disk
# by the time run-v-packs archives the pack (a worktree-teardown race, a dropped .v/ dir, or a bug in the
# attest script could leave the claim unbacked). This is OPT-IN (V_PACK_VERIFY_ARTIFACTS=1, default off) —
# a real fleet run (run-v-packs-wave-land-test.sh's fixtures) demonstrated that `.v/artifacts/` existing in
# a repo does NOT reliably mean every pack's OWN session left artifacts there (a sibling worktree or a
# lighter completion path can populate it for unrelated reasons), so this defaults to a no-op and only
# activates for an operator who has confirmed the convention holds for their repo.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" 2>/dev/null' EXIT
mkdir -p "$TMP/repo/packs" "$TMP/repo/.runlogs" "$TMP/repo/.done" "$TMP/repo/.needs-review"
git -C "$TMP/repo" init -q 2>/dev/null || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t _gauntlet_artifacts_verified)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose _gauntlet_artifacts_verified"; exit 1; }

REPO="$TMP/repo"; PACK_ABS="$REPO/packs"; LOG_DIR="$REPO/.runlogs"; DONE_DIR="$REPO/.done"; NEEDS_DIR="$REPO/.needs-review"
ARCHIVE=1
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
SID="cafe1234-5678-4abc-9def-0123456789ab"

echo "── (1) DEFAULT (V_PACK_VERIFY_ARTIFACTS unset/0): always verified — no behavior change from before ──"
unset V_PACK_VERIFY_ARTIFACTS
_gauntlet_artifacts_verified "$SID" && ok "default-off: verified even with .v/artifacts/ absent entirely" || no "default-off unexpectedly blocked"
mkdir -p "$REPO/.v/artifacts"
_gauntlet_artifacts_verified "$SID" && ok "default-off: verified even with .v/artifacts/ present but empty for this sid" || no "default-off unexpectedly blocked with dir present"
rm -rf "$REPO/.v"

echo "── (2) ENABLED, no .v/artifacts/ dir at all → fail-open (convention not adopted in this repo) ──"
V_PACK_VERIFY_ARTIFACTS=1 _gauntlet_artifacts_verified "$SID" && ok "fail-open when .v/artifacts/ doesn't exist" || no "wrongly blocked with no .v/artifacts/ dir"

echo "── (3) ENABLED, .v/artifacts/ exists but ZERO matching artifacts for this sid → distrust (fail) ──"
mkdir -p "$REPO/.v/artifacts"
printf 'x\n' > "$REPO/.v/artifacts/AGENT_REVIEW_some-other-sid.md"   # unrelated session's artifact
if V_PACK_VERIFY_ARTIFACTS=1 _gauntlet_artifacts_verified "$SID"; then no "did NOT distrust a sid with zero matching evidence" ""; else ok "distrusts a 'done' claim with zero matching gate artifacts for this sid"; fi

echo "── (4) ENABLED, at least ONE matching artifact for this sid (any of the 3 kinds) → verified ──"
printf 'PASS\n' > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
V_PACK_VERIFY_ARTIFACTS=1 _gauntlet_artifacts_verified "$SID" && ok "verified once at least one real artifact for this sid exists" || no "wrongly distrusted despite a real matching artifact"

echo "── (5) ENABLED, artifact found at repo ROOT (pre-relocation location) also counts ──"
rm -rf "$REPO/.v/artifacts"; mkdir -p "$REPO/.v/artifacts"   # dir must exist for the check to activate at all
printf 'PASS\n' > "$REPO/VERIFY_DONE_REPORT_${SID}.md"
V_PACK_VERIFY_ARTIFACTS=1 _gauntlet_artifacts_verified "$SID" && ok "repo-root artifact (pre-relocation) also satisfies verification" || no "root-level artifact not honored"
rm -f "$REPO/VERIFY_DONE_REPORT_${SID}.md"

echo "── (6) end-to-end: _archive_finished_pack routes an unverified 'done' to .needs-review/, not .done/ ──"
rm -rf "$REPO/.v"; mkdir -p "$REPO/.v/artifacts"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"session_id":"%s"}\nGAUNTLET_ATTESTED: yes\n' "$SID" > "$LOG_DIR/e2e.log"
printf '/v something\n\nbody\n' > "$PACK_ABS/e2e.txt"
out="$(V_PACK_VERIFY_ARTIFACTS=1 _archive_finished_pack e2e "$PACK_ABS/e2e.txt" 2>&1)"
[ -f "$NEEDS_DIR/e2e.txt" ] && ok "unverified GAUNTLET_ATTESTED claim parked to .needs-review/, not silently archived" || no "unverified done was archived anyway" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"
printf '%s' "$out" | grep -q "UNVERIFIED-DONE" && ok "output clearly flags the mismatch" || no "no UNVERIFIED-DONE message" "$out"

echo "── (7) end-to-end: with V_PACK_VERIFY_ARTIFACTS unset, the SAME unverified log still archives normally ──"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"session_id":"%s"}\nGAUNTLET_ATTESTED: yes\n' "$SID" > "$LOG_DIR/e2e2.log"
printf '/v something else\n\nbody\n' > "$PACK_ABS/e2e2.txt"
unset V_PACK_VERIFY_ARTIFACTS
_archive_finished_pack e2e2 "$PACK_ABS/e2e2.txt" >/dev/null 2>&1
[ -f "$DONE_DIR/e2e2.txt" ] && ok "with the feature off (default), the same scenario archives normally — no regression" || no "default-off path unexpectedly parked" "$(ls "$PACK_ABS" "$DONE_DIR" "$NEEDS_DIR" 2>&1)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
