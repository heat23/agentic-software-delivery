#!/usr/bin/env bash
# v-prompt-pack-precondition-witness-test.sh — round-trip bite test for
# PLAN_forensics-remediation-20260703.md Phase 3 item 15 ("Pack-mode witness + template fixes"):
#   (a) a pack that hard-codes claims under "## Verified context" must ALSO carry a machine-checkable
#       `requires:` grep + a runtime precondition check that STOPs + writes BLOCKED_<sid>.md on drift —
#       not a bare future-fact assertion (R3 P0-1 forensic: a pack claimed `exampleGuard()` existed;
#       it existed nowhere in app/ except comments citing it, and nothing caught the drift at exec time).
#   (b) a pack whose "## After" ends "leave staged" (a runner-managed staged-handoff exit, since the
#       session commits nothing) must instruct writing IMPLEMENTATION_REPORT_<sid>.md — the witness the
#       session-log resolver's staged-handoff contract looks for.
#
# Extracts the literal self-validate bash fence from v-runnable-pack-convention.md (same fence item 16's
# test extracts) and runs it against fixture packs, so this test rides the real doc and can't drift
# from it silently.
set -uo pipefail

CONVENTION="${CONVENTION:-$HOME/.claude/skills/references/v-runnable-pack-convention.md}"
[ -f "$CONVENTION" ] || { echo "FATAL: convention doc not found: $CONVENTION"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

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
grep -q "precondition-check-present\|Precondition-check-present" "$SV" || { echo "FATAL: extracted fence has no precondition/witness block (doc drifted from this test)"; exit 2; }
sed -i.bak '/^PACK_ROOT=.*substitute actual/d' "$SV"

run_selfvalidate(){
  local root="$1"
  ( PACK_ROOT="$root"; eval "$(cat "$SV")" ) 2>&1
}

mk_readme(){ # $1=dir $2=pack-basename-list (space separated)
  { echo "# Pack tree"; echo "| Wave | Prefix | Parallel packs | Depends on | Gate |"; echo "|---|---|---|---|---|"
    for p in $2; do echo "| 0 | (none) | $p | - | tests |"; done
  } > "$1/00-README.md"
}

echo "── (1) GREEN: full template (requires: + BLOCKED + IMPLEMENTATION_REPORT) validates clean ──"
# Fixture upgraded 2026-07-05 (F2): the compliant shape now also carries the [verified main@<sha>]
# truth stamp per Verified-context claim + the Generation-time verification evidence line, and the
# tree carries its (now REQUIRED, exactly-one) 99-* final verify pack.
R1="$TMP/tree1"; mkdir -p "$R1"
cat > "$R1/good.txt" <<'EOF'
/v Do the thing.

## Requires (verify BEFORE editing — this is a snapshot from generation time, not a live guarantee)
requires: grep -n "exampleGuard" src/Support/ExampleGuard.php

## Verified context
Generation-time verification: every claim below was live-checked via git show main:src/Support/ExampleGuard.php | grep 'exampleGuard' at main@abcdef1 on 2026-07-05.
- src/Support/ExampleGuard.php:29 — exampleGuard() exists [verified main@abcdef1]

Runtime precondition check: re-run the requires: grep above; if the anchor is missing, STOP and write BLOCKED_<sid>.md naming it.

## Files
- src/Support/ExampleGuard.php — apply the change

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md before finishing. Do NOT commit; leave staged for the next wave.
EOF
cat > "$R1/99-verify.txt" <<'EOF'
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
mk_readme "$R1" "good.txt 99-verify.txt"
o="$(run_selfvalidate "$R1")"
printf '%s\n' "$o" | grep -q "PACK TREE OK" && ok "fully-compliant pack validates clean" || no "compliant pack unexpectedly flagged" "$o"

echo "── (2) RED: 'Verified context' with NO requires: grep (bare future-fact assertion, R3 P0-1 shape) ──"
R2="$TMP/tree2"; mkdir -p "$R2"
cat > "$R2/bare-context.txt" <<'EOF'
/v Do the thing.

## Verified context
- src/Support/ExampleGuard.php:29 — exampleGuard() exists

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
mk_readme "$R2" "bare-context.txt"
o="$(run_selfvalidate "$R2")"
printf '%s\n' "$o" | grep -qi "no machine-checkable 'requires:' precondition grep" && ok "missing requires: grep is caught" || no "missing requires: NOT caught" "$o"
printf '%s\n' "$o" | grep -qi "no runtime precondition STOP+BLOCKED instruction" && ok "missing BLOCKED instruction is caught" || no "missing BLOCKED instruction NOT caught" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "bare future-fact pack fails loudly" || no "bare future-fact pack did not fail" "$o"

echo "── (3) RED: has requires: + BLOCKED, but 'leave staged' exit has no IMPLEMENTATION_REPORT witness ──"
R3="$TMP/tree3"; mkdir -p "$R3"
cat > "$R3/no-witness.txt" <<'EOF'
/v Do the thing.

## Requires (verify BEFORE editing)
requires: grep -n "exampleGuard" src/Support/ExampleGuard.php
Runtime precondition check: STOP and write BLOCKED_<sid>.md if the anchor above is missing.

## Verified context
- src/Support/ExampleGuard.php:29 — exampleGuard() exists

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Do NOT commit; leave staged for the next wave.
EOF
mk_readme "$R3" "no-witness.txt"
o="$(run_selfvalidate "$R3")"
printf '%s\n' "$o" | grep -qi "leave staged.*runner-managed staged-handoff exit.*IMPLEMENTATION_REPORT\|never instructs writing IMPLEMENTATION_REPORT" && ok "staged-handoff exit with no witness is caught" || no "missing IMPLEMENTATION_REPORT witness NOT caught" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "witness-less staged-handoff pack fails loudly" || no "witness-less pack did not fail" "$o"

echo "── (4) GREEN: a pack with no 'Verified context' section at all (e.g. a pure-verify pack) is exempt ──"
R4="$TMP/tree4"; mkdir -p "$R4"
cat > "$R4/w2-pre-flight.txt" <<'EOF'
/v-pre-flight

Run the project's full quality gates and report results. Read-only.
EOF
mk_readme "$R4" "w2-pre-flight.txt"
o="$(run_selfvalidate "$R4")"
printf '%s\n' "$o" | grep -qi "requires:\|BLOCKED\|IMPLEMENTATION_REPORT" && no "verify-only pack (no Verified context) falsely flagged" "$o" || ok "verify-only pack correctly exempt from the precondition/witness check"

echo "── (5) RED (F2 2026-07-05): 'Verified context' claim with NO truth stamp / evidence line — the false-'already landed' class ──"
# The forensic-derived shape: a pack asserting "ExampleOperation::ExampleTeardown already added" on faith,
# no backing SHA, no generation-time evidence — must now fail the self-validate even though it has the
# structural requires:/BLOCKED lines (structure-checking alone laundered the false claim).
R5="$TMP/tree5"; mkdir -p "$R5"
cat > "$R5/unstamped-claim.txt" <<'EOF'
/v Wire the example operation.

## Requires (verify BEFORE editing)
requires: grep -n "ExampleTeardown" app/Enums/ExampleOperation.php
Runtime precondition check: STOP and write BLOCKED_<sid>.md if the anchor above is missing.

## Verified context
- app/Enums/ExampleOperation.php — ExampleOperation::ExampleTeardown already added by wave-0 example-operation-registry — do NOT edit ExampleOperation.php

## Files
- app/Jobs/ExampleJob.php — wire the new case

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
cat > "$R5/99-verify.txt" <<'EOF'
/v-verify-done Final gate-runner for this tree.

## Goal
Re-assert every wave landed on main. Read-only.

## Checks
- grep the landed symbols on main

## Acceptance
- gates pass
EOF
mk_readme "$R5" "unstamped-claim.txt 99-verify.txt"
o="$(run_selfvalidate "$R5")"
printf '%s\n' "$o" | grep -qi "lacks a generation-time truth stamp" && ok "unstamped 'already added by wave-N' claim is caught (truth-stamp gate)" || no "unstamped claim NOT caught" "$o"
printf '%s\n' "$o" | grep -qi "no 'Generation-time verification:" && ok "missing generation-time evidence line is caught" || no "missing evidence line NOT caught" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "faith-based Verified-context pack fails loudly" || no "faith-based pack did not fail" "$o"

echo "── (6) GREEN→RED pair (F2 2026-07-05): exactly-one 99-* verify pack is a HARD gate ──"
# RED: wave tree with NO 99-* (the phantom wave-0 forensic tree shipped with no verify pack and
# 'looked done' forever). Was an advisory '(note: …)' pre-F2 — must now be a hard failure.
R6="$TMP/tree6"; mkdir -p "$R6"
cat > "$R6/w1-impl.txt" <<'EOF'
/v Do the thing.

## Files
- src/Foo.php — apply the change

## Task(s)
Do the change.

## Tests
- test the change

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
mk_readme "$R6" "w1-impl.txt"
o="$(run_selfvalidate "$R6")"
printf '%s\n' "$o" | grep -qi "exactly ONE is REQUIRED" && ok "tree without a 99-* verify pack is a HARD failure (not advisory)" || no "missing 99-* NOT a hard failure" "$o"
printf '%s\n' "$o" | grep -q "PACK TREE ISSUES" && ok "verify-less tree fails loudly" || no "verify-less tree did not fail" "$o"
# RED: TWO 99-* packs — the runner runs only the first and silently ignores the rest.
cat > "$R6/99-verify.txt" <<'EOF'
/v-verify-done Final gate-runner.

## Goal
Re-assert every wave landed. Read-only.

## Checks
- grep landed symbols

## Acceptance
- gates pass
EOF
cp "$R6/99-verify.txt" "$R6/99-verify-extra.txt"
mk_readme "$R6" "w1-impl.txt 99-verify.txt 99-verify-extra.txt"
o="$(run_selfvalidate "$R6")"
printf '%s\n' "$o" | grep -qi "exactly ONE is REQUIRED" && ok "tree with TWO 99-* packs is also a hard failure (exactly one)" || no "duplicate 99-* NOT caught" "$o"
# GREEN: exactly one 99-* satisfies the gate (no 99-count note).
rm -f "$R6/99-verify-extra.txt"; mk_readme "$R6" "w1-impl.txt 99-verify.txt"
o="$(run_selfvalidate "$R6")"
printf '%s\n' "$o" | grep -qi "exactly ONE is REQUIRED" && no "single-99 tree falsely flagged by the 99 gate" "$o" || ok "tree with exactly one 99-* passes the 99 gate"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
