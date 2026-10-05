#!/usr/bin/env bash
# v-prompt-pack-wave-map-parity-test.sh — round-trip bite test for PLAN_forensics-remediation-20260703.md
# Phase 3 item 16 (R3 P0-1 "Generator completeness"): the self-validate script in
# v-runnable-pack-convention.md must catch a wave-map <-> pack-file MISMATCH, in both directions:
#   - a pack NAMED in 00-README.md's wave-map table that was never written to disk (phantom pack —
#     the live forensic: 4 of 6 wave-0 packs had no file, no history, no SID, no branch; the tree
#     LOOKED complete because nothing cross-checked the map against the filesystem)
#   - a pack file on disk that the wave-map table never mentions (orphan pack — silently unscheduled)
#
# This test does NOT hand-copy the check's logic — it EXTRACTS the literal bash fence under
# "## Self-validate the emitted tree — NORMATIVE" from the convention doc and runs it verbatim
# against fixture pack trees, so the test rides the real doc and cannot drift from it silently.
set -uo pipefail

CONVENTION="${CONVENTION:-$HOME/.claude/skills/references/v-runnable-pack-convention.md}"
[ -f "$CONVENTION" ] || { echo "FATAL: convention doc not found: $CONVENTION"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

# Extract the fenced bash block that begins right after the "## Self-validate the emitted tree" heading.
extract_selfvalidate(){
  awk '
    /^## Self-validate the emitted tree/ { seen_heading=1 }
    seen_heading && /^```bash/ { infence=1; next }
    infence && /^```/ { exit }
    infence { print }
  ' "$CONVENTION"
}
SV="$TMP/self-validate.sh"
extract_selfvalidate > "$SV"
[ -s "$SV" ] || { echo "FATAL: could not extract self-validate fence from $CONVENTION"; exit 2; }
grep -q "wave-map <-> pack-file parity" "$SV" || { echo "FATAL: extracted fence has no wave-map parity block (doc drifted from this test)"; exit 2; }
# The doc's own first line hard-codes a PACK_ROOT placeholder ("substitute actual") — strip it so the
# caller-supplied PACK_ROOT (the real fixture dir) isn't clobbered when the fence is eval'd verbatim.
sed -i.bak '/^PACK_ROOT=.*substitute actual/d' "$SV"

run_selfvalidate(){
  local root="$1"
  ( PACK_ROOT="$root"; eval "$(cat "$SV")" ) 2>&1
}

mk_valid_pack(){ # $1=path
  # Fixture upgraded 2026-07-05 (F2): Verified-context claims now REQUIRE a [verified main@<sha>]
  # truth stamp + the Generation-time verification evidence line (convention § Verified-context
  # claims are TRUTH-checked at generation) — the pre-F2 bare-claim shape is now a self-validate
  # failure by design (covered by v-prompt-pack-detection-test.sh + the witness test's RED cases).
  cat > "$1" <<'EOF'
/v Do the thing.

## Requires (verify BEFORE editing — this is a snapshot from generation time, not a live guarantee)
requires: grep -n "fooHelper" src/Foo.php
Runtime precondition check: re-run the requires: grep above; if missing, STOP and write BLOCKED_<sid>.md.

## Verified context
Generation-time verification: every claim below was live-checked via git show main:src/Foo.php | grep 'fooHelper' at main@abcdef1 on 2026-07-05.
- src/Foo.php:10 — fooHelper exists [verified main@abcdef1]

## Files
- src/Foo.php — apply the change

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
}

mk_verify_pack(){ # $1=path — minimal READ-ONLY 99-* final verify pack (F2: exactly one is REQUIRED per tree)
  # <!-- v-verify-gate --> present since 2026-07-11: the convention's self-validate gained a soft note for a
  # missing gate directive (2026-07-07) and a "validates clean" fixture must carry one to stay compliant.
  cat > "$1" <<'EOF'
/v-verify-done Final gate-runner for this tree.

## Goal
Re-assert every wave landed on main (cheap greps + targeted gates). Read-only.

## Checks
- grep the landed symbols on main
- run the targeted gate commands

## Acceptance
- every wave's work is present on main and gates pass

<!-- v-verify-gate: true -->
EOF
}

echo "── (1) Baseline: README wave-map names exactly the packs on disk → PACK TREE OK ──"
R1="$TMP/tree1"; mkdir -p "$R1"
mk_valid_pack "$R1/foo.txt"
mk_valid_pack "$R1/w1-bar.txt"
mk_verify_pack "$R1/99-verify.txt"
cat > "$R1/00-README.md" <<'EOF'
# Pack tree
| Wave | Prefix | Parallel packs | Depends on | Gate |
|---|---|---|---|---|
| 0 | (none) | foo.txt | - | tests |
| 1 | w1- | w1-bar.txt | foo.txt | tests |
| 99 | 99- | 99-verify.txt | all | verify |
EOF
o="$(run_selfvalidate "$R1")"
printf '%s\n' "$o" | grep -q "PACK TREE OK" && ok "matched tree validates clean" || no "matched tree unexpectedly flagged" "$o"
printf '%s\n' "$o" | grep -qi "phantom-wave\|orphan pack" && no "matched tree falsely flagged phantom/orphan" || ok "no false phantom/orphan on matched tree"

echo "── (2) RED: 00-README.md names a pack that was NEVER WRITTEN (the live R3 P0-1 shape) ──"
R2="$TMP/tree2"; mkdir -p "$R2"
mk_valid_pack "$R2/foo.txt"
cat > "$R2/00-README.md" <<'EOF'
# Pack tree
| Wave | Prefix | Parallel packs | Depends on | Gate |
|---|---|---|---|---|
| 0 | (none) | foo.txt | - | tests |
| 0 | (none) | example-phantom-pack.txt | - | tests |
EOF
o="$(run_selfvalidate "$R2")"
printf '%s\n' "$o" | grep -qi "wave-map names 'example-phantom-pack.txt'.*no such pack file" && ok "phantom pack (named, never written) is caught" || no "phantom pack NOT caught" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "tree with a phantom pack fails loudly" || no "tree with a phantom pack did not fail" "$o"

echo "── (3) RED: an orphan pack file exists on disk but the wave map never names it ──"
R3="$TMP/tree3"; mkdir -p "$R3"
mk_valid_pack "$R3/foo.txt"
mk_valid_pack "$R3/stray-unscheduled.txt"
cat > "$R3/00-README.md" <<'EOF'
# Pack tree
| Wave | Prefix | Parallel packs | Depends on | Gate |
|---|---|---|---|---|
| 0 | (none) | foo.txt | - | tests |
EOF
o="$(run_selfvalidate "$R3")"
printf '%s\n' "$o" | grep -qi "stray-unscheduled.txt exists on disk but is not named anywhere in 00-README.md" && ok "orphan pack (written, never mapped) is caught" || no "orphan pack NOT caught" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "tree with an orphan pack fails loudly" || no "tree with an orphan pack did not fail" "$o"

echo "── (4) RED: 00-README.md missing entirely → parity check refuses silently-passing ──"
R4="$TMP/tree4"; mkdir -p "$R4"
mk_valid_pack "$R4/foo.txt"
o="$(run_selfvalidate "$R4")"
printf '%s\n' "$o" | grep -qi "master 00-README.md missing" && ok "missing README is flagged (parity check has nothing to cross-check against)" || no "missing-README case not flagged" "$o"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
