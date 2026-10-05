#!/usr/bin/env bash
# validate-audit-prompt-packs-test.sh — regression test for the F2 2026-07-05 sync of
# validate-audit-prompt-packs.sh with the hardened v-runnable-pack-convention.md § Self-validate:
#
#   1. exactly-one-99-* is a HARD failure (was an advisory "(note: …)" — the phantom wave-0 forensic
#      tree shipped with no verify pack and "looked done" forever): zero 99-* fails, two fail, one passes.
#   3. BYTE-CAP parity (2026-09-11): a pack over run-v-packs' PACK_MAX_BYTES=25000 is SKIPPED by the
#      runner (is_pack()/oversized_packs(), run-v-packs-lib/10-discovery.sh) and never runs, while both
#      validators reported PACK TREE OK — two live misses the same day. >25000 fails, exactly 25000 passes.
#
#   2. '## Verified context' truth-stamping: every claim bullet needs '[verified main@<sha>]' (or an
#      explicit UNVERIFIED downgrade) + the 'Generation-time verification: … git show main:' evidence
#      line, on top of the pre-existing-in-the-fence requires:/BLOCKED/IMPLEMENTATION_REPORT checks that
#      this script had NEVER carried at all (it advertised "the same checks" as the fence — drift).
#
# WHY branch-2 (full parity, no audit-family exemption): audit-family packs are remediation/
# IMPLEMENTATION packs in the unified runnable wave form with MANDATORY closing waves + 99-verify.txt
# (_v-audit.md § pack emission; v-audit-code SKILL.md Step 5; v-core-prompt-pack.md — producer
# carve-outs retired 2026-07-05). The audit REPORT is read-only; the emitted packs land code. The skills
# document this script and the convention fence as interchangeable ("run § Self-validate … or
# validate-audit-prompt-packs.sh"), so the two MUST stay in parity — this test pins that.
#
# Style: standalone bash, ok()/no() counters, final "TOTAL: N passed, M failed" (per
# hooks/enforce-branch-gate-test.sh). Runs the LIVE script against synthetic pack trees.
set -u
SCRIPT="${VALIDATOR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/scripts/validate-audit-prompt-packs.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

run_v(){ bash "$SCRIPT" "$1" 2>&1; }

mk_impl_pack(){ # $1=path — compliant implementation pack (stamped Verified context, witness, no commit)
  cat > "$1" <<'EOF'
/v Fix the audited finding.

## Goal
Fix the finding.

## Context
The finding, inlined with file:line evidence.

## Requires (verify BEFORE editing)
requires: grep -n "targetHelper" src/Thing.php
Runtime precondition check: STOP and write BLOCKED_<sid>.md if the anchor above is missing.

## Verified context
Generation-time verification: every claim below was live-checked via git show main:src/Thing.php | grep 'targetHelper' at main@abcdef1 on 2026-07-05.
- src/Thing.php:12 — targetHelper exists [verified main@abcdef1]

## Files
- src/Thing.php — apply the fix

## Changes
Apply the fix.

## Acceptance criteria
- [ ] fixed

## Tests
- test the fix

## Constraints
Read the project's CLAUDE.md first.

## Dependencies
Wave 0. Requires: none.

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
}

mk_verify_pack(){ # $1=path — read-only 99-* closer
  cat > "$1" <<'EOF'
/v-verify-done Final gate-runner for this tree.

## Goal
Re-assert every wave landed on main. Read-only.

## Checks
- grep the landed symbols on main
- run the targeted gate commands

## Acceptance
- gates pass
EOF
}

mk_readme(){ # $1=dir $2=names
  { echo "# Pack tree"; echo "| # | Pack file | Wave | Theme | Domain | Findings | Can Parallel? |"; echo "|---|---|---|---|---|---|---|"
    i=0; for p in $2; do i=$((i+1)); echo "| $i | $p | 0 | t | d | 1 | yes |"; done
  } > "$1/00-README.md"
}

echo "== validate-audit-prompt-packs.sh F2 sync (parity with convention § Self-validate) =="

# ── (1) GREEN baseline: compliant tree (stamped claims + exactly one 99-*) passes ──
D1="$TMP/t1"; mkdir -p "$D1"
mk_impl_pack "$D1/fix-thing.txt"; mk_verify_pack "$D1/99-verify.txt"
mk_readme "$D1" "fix-thing.txt 99-verify.txt"
o="$(run_v "$D1")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q "PACK TREE OK"; } && ok "compliant audit-family-shaped tree passes (exit 0)" || no "compliant tree failed: $o"

# ── (2) HARD 99 gate: zero 99-* fails (was advisory pre-F2) ──
D2="$TMP/t2"; mkdir -p "$D2"
mk_impl_pack "$D2/fix-thing.txt"
mk_readme "$D2" "fix-thing.txt"
o="$(run_v "$D2")"; rc=$?
printf '%s' "$o" | grep -qi "exactly ONE is REQUIRED" && ok "tree without 99-* is a HARD failure message" || no "missing 99-* not flagged hard: $o"
[ "$rc" -eq 1 ] && ok "tree without 99-* exits 1 (blocking, not advisory)" || no "missing 99-* did not exit 1 (rc=$rc)"

# ── (3) HARD 99 gate: TWO 99-* packs also fail (runner runs only the first) ──
D3="$TMP/t3"; mkdir -p "$D3"
mk_impl_pack "$D3/fix-thing.txt"; mk_verify_pack "$D3/99-verify.txt"; mk_verify_pack "$D3/99-verify-extra.txt"
mk_readme "$D3" "fix-thing.txt 99-verify.txt 99-verify-extra.txt"
o="$(run_v "$D3")"; rc=$?
{ printf '%s' "$o" | grep -qi "exactly ONE is REQUIRED" && [ "$rc" -eq 1 ]; } && ok "tree with two 99-* packs fails (exactly one)" || no "duplicate 99-* not caught (rc=$rc): $o"

# ── (4) Truth-stamp gate: unstamped 'already added by wave-N' claim fails (F2 false-already-landed class) ──
D4="$TMP/t4"; mkdir -p "$D4"
cat > "$D4/wire-example.txt" <<'EOF'
/v Wire the example operation.

## Goal
Wire it.

## Context
Finding inlined.

## Requires (verify BEFORE editing)
requires: grep -n "ExampleCase" app/Enums/ExampleOperation.php
Runtime precondition check: STOP and write BLOCKED_<sid>.md if the anchor above is missing.

## Verified context
- app/Enums/ExampleOperation.php — ExampleOperation::ExampleCase already added by wave-0 example-registry — do NOT edit ExampleOperation.php

## Files
- app/Jobs/ExampleJob.php — wire the new case

## Changes
Wire it.

## Acceptance criteria
- [ ] wired

## Tests
- test it

## Constraints
Read the project's CLAUDE.md first.

## Dependencies
Wave 1. Requires: example-registry.

## After
Run the touched tests. Write IMPLEMENTATION_REPORT_<sid>.md. Do NOT commit; leave staged for the next wave.
EOF
mk_verify_pack "$D4/99-verify.txt"
mk_readme "$D4" "wire-example.txt 99-verify.txt"
o="$(run_v "$D4")"; rc=$?
printf '%s' "$o" | grep -qi "lacks a generation-time truth stamp" && ok "unstamped 'already added by wave-N' claim is caught" || no "unstamped claim not caught: $o"
printf '%s' "$o" | grep -qi "no 'Generation-time verification:" && ok "missing evidence line is caught" || no "missing evidence line not caught: $o"
[ "$rc" -eq 1 ] && ok "faith-based Verified-context tree exits 1" || no "faith-based tree did not exit 1 (rc=$rc)"

# ── (5) Structural Verified-context parity (this script NEVER had these — drift closed): no requires:/BLOCKED ──
D5="$TMP/t5"; mkdir -p "$D5"
cat > "$D5/bare.txt" <<'EOF'
/v Do the thing.

## Goal
Do it.

## Context
Finding inlined.

## Verified context
Generation-time verification: every claim below was live-checked via git show main:src/X.php | grep 'x' at main@abcdef1 on 2026-07-05.
- src/X.php:1 — x exists [verified main@abcdef1]

## Files
- src/X.php — fix

## Changes
Fix.

## Acceptance criteria
- [ ] fixed

## Tests
- t

## Constraints
CLAUDE.md.

## Dependencies
Wave 0. Requires: none.
EOF
mk_verify_pack "$D5/99-verify.txt"
mk_readme "$D5" "bare.txt 99-verify.txt"
o="$(run_v "$D5")"
printf '%s' "$o" | grep -qi "no machine-checkable 'requires:' precondition grep" && ok "Verified-context pack without requires: grep is caught (parity with fence)" || no "missing requires: not caught: $o"
printf '%s' "$o" | grep -qi "no runtime precondition STOP+BLOCKED" && ok "missing BLOCKED instruction is caught (parity with fence)" || no "missing BLOCKED not caught: $o"

# ── (6) UNVERIFIED downgrade is accepted (the explicit honest form never hard-fails) ──
D6="$TMP/t6"; mkdir -p "$D6"
mk_impl_pack "$D6/fix-thing.txt"
# add an UNVERIFIED claim line into the Verified context section (still has evidence line + requires/BLOCKED)
awk '{print} /\[verified main@abcdef1\]/{print "- app/Enums/ExampleOperation.php — ExampleCase claim failed its live check [UNVERIFIED — verify before relying]"}' "$D6/fix-thing.txt" > "$D6/fix-thing.txt.new" && mv "$D6/fix-thing.txt.new" "$D6/fix-thing.txt"
mk_verify_pack "$D6/99-verify.txt"
mk_readme "$D6" "fix-thing.txt 99-verify.txt"
o="$(run_v "$D6")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q "PACK TREE OK"; } && ok "explicit [UNVERIFIED] downgrade is accepted (honest form passes)" || no "UNVERIFIED downgrade wrongly failed: $o"

# ── (7) BYTE-CAP parity with run-v-packs (2026-09-11) ──
# run-v-packs rejects a pack over PACK_MAX_BYTES=25000 (is_pack: `-le`; oversized_packs: `-gt`): it is
# SKIPPED, never run, and --dry-run still exits 0. The line bounds (<10 / >3500) cannot catch it — the
# padded fixtures below stay ~40 lines, which is exactly why a 28KB pack shipped green twice.
pad_to(){ # $1=file $2=target bytes — append filler so `wc -c` lands EXACTLY on $2 (one long line, no newline)
  local sz need; sz=$(wc -c < "$1" | tr -d ' '); need=$(( $2 - sz ))
  if [ "$need" -gt 0 ]; then head -c "$need" /dev/zero | tr '\0' 'x' >> "$1"; fi
}
D7="$TMP/t7"; mkdir -p "$D7"
mk_impl_pack "$D7/fix-thing.txt"; mk_verify_pack "$D7/99-verify.txt"
mk_readme "$D7" "fix-thing.txt 99-verify.txt"
pad_to "$D7/fix-thing.txt" 25001
o="$(run_v "$D7")"; rc=$?
{ printf '%s' "$o" | grep -q "PACK_MAX_BYTES" && [ "$rc" -eq 1 ]; } \
  && ok "oversized pack (25001 B) fails — the runner would skip it, so green here was a false pass" \
  || no "oversized pack not caught (rc=$rc): $o"
[ "$(wc -l < "$D7/fix-thing.txt" | tr -d ' ')" -le 3500 ] \
  && ok "oversized fixture stays inside the >3500-line bound (proves BYTES caught it, not lines)" \
  || no "oversized fixture also tripped the line bound — the case no longer isolates the byte cap"

D8="$TMP/t8"; mkdir -p "$D8"
mk_impl_pack "$D8/fix-thing.txt"; mk_verify_pack "$D8/99-verify.txt"
mk_readme "$D8" "fix-thing.txt 99-verify.txt"
pad_to "$D8/fix-thing.txt" 25000
o="$(run_v "$D8")"; rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q "PACK TREE OK"; } \
  && ok "pack of exactly 25000 B passes (boundary byte-identical to the runner's -gt)" \
  || no "boundary pack wrongly failed (rc=$rc): $o"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
