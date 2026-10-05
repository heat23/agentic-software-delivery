#!/usr/bin/env bash
# p2-winner-election-test.sh — P2 winner-election manifest (2026-07-03).
#
# Forensic: 6 same-slug copies; landing-by-narration picked the staged-on-main copy (guard only,
# ZERO ConnectionException handling) over the committed superset. This proves the machine
# ranking: a committed + gauntleted copy MUST outrank a staged-only artifact-less copy, and
# zero-commit rows must be labeled staged-only (N2: never read as landed).
# RED ORACLE: pre-P2 the script does not exist (absence = red; pinned in BITE_LEDGER).
set -u
ELECT="$HOME/.claude/skills/v/references/v-winner-election.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$ELECT" ] || { echo "NO v-winner-election.sh missing (pre-P2 = RED)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
R="$WORK/repo"
SIDA="aaaa1111-2222-3333-4444-555566667777"
SIDB="bbbb1111-2222-3333-4444-555566667777"

mkdir -p "$R"; git -C "$R" init -q -b main 2>/dev/null || { git -C "$R" init -q; git -C "$R" checkout -q -b main; }
git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
mkdir -p "$R/app" "$R/tests"
echo '<?php // base' > "$R/app/Base.php"; git -C "$R" add -A; git -C "$R" commit -qm base

# Candidate A: committed work + deep gauntlet artifacts + real tests
git -C "$R" worktree add -q -b "build/client-adapter-$SIDA" "$WORK/wtA" main 2>/dev/null
mkdir -p "$WORK/wtA/app" "$WORK/wtA/tests"
printf '<?php\nclass Adapter { /* handles ConnectionException */ }\n' > "$WORK/wtA/app/Adapter.php"
for i in $(seq 1 120); do echo "it('case $i', fn() => expect(true)->toBeTrue());"; done > "$WORK/wtA/tests/AdapterTest.php"
git -C "$WORK/wtA" add -A; git -C "$WORK/wtA" commit -qm "feat: adapter with handling + tests"
mkdir -p "$WORK/wtA/.v/artifacts"
printf 'Model: haiku\n## Pre-flight\nall gates passed\n' > "$WORK/wtA/.v/artifacts/PRE_FLIGHT_REPORT_${SIDA}.md"
printf 'Model: haiku\n## Findings\n- ACCEPT F1 fixed\n- MODIFY F2 fixed\n' > "$WORK/wtA/.v/artifacts/AGENT_REVIEW_${SIDA}.md"
printf 'Model: haiku\nMode: scoped(writes-log)\nOverall Verdict: PASS\n' > "$WORK/wtA/.v/artifacts/VERIFY_DONE_REPORT_${SIDA}.md"
printf 'Model: sonnet\n\n## QA Acceptance\n\nverdict: pass\n' > "$WORK/wtA/.v/artifacts/QA_REPORT_${SIDA}.md"

# Candidate B: staged-only duplicate, NO artifacts (the wrong winner of 2026-07-03)
git -C "$R" worktree add -q -b "build/client-adapter-$SIDB" "$WORK/wtB" main 2>/dev/null
printf '<?php\nclass Adapter { /* guard only */ }\n' > "$WORK/wtB/app/Adapter.php"
git -C "$WORK/wtB" add -A   # staged, never committed

# Review L#1 CRITICAL regression case: a candidate whose AGENT_REVIEW is CLEAN (zero
# ACCEPT/MODIFY lines — the best outcome) must still appear in the ranking (the W40-A
# grep -c || echo 0 crash silently dropped it).
printf 'Model: haiku\n## Findings\nno findings — clean review\n' > "$WORK/wtA/.v/artifacts/AGENT_REVIEW_${SIDA}.md.clean-probe"

echo "== P2 :: winner election ranks gauntlet depth, not staging order =="
OUT=$(bash "$ELECT" "$R" "client-adapter" 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && ok "election ran (rc=0)" || no "election failed" "rc=$rc"
TOP=$(printf '%s\n' "$OUT" | sed -n '2p')
printf '%s' "$TOP" | grep -q "aaaa1111" \
  && ok "committed + gauntleted copy ranks FIRST (sid8=aaaa1111)" \
  || no "wrong winner ranked first" "$TOP"
printf '%s\n' "$OUT" | grep "bbbb1111" | grep -q 'staged-only' \
  && ok "zero-commit copy labeled staged-only (N2: never read as landed)" \
  || no "staged-only label missing on zero-commit row" "$(printf '%s\n' "$OUT" | grep bbbb1111)"
# score ordering is strict
SA=$(printf '%s\n' "$OUT" | grep "aaaa1111" | cut -f1); SB=$(printf '%s\n' "$OUT" | grep "bbbb1111" | cut -f1)
[ "${SA:-0}" -gt "${SB:-0}" ] \
  && ok "score strictly higher for the gauntleted copy ($SA > $SB)" \
  || no "scores not ordered" "A=$SA B=$SB"
[ -f "$R/.v/artifacts/WINNER_ELECTION_client-adapter.md" ] \
  && ok "durable manifest written to .v/artifacts" \
  || no "manifest missing" ""
grep -q 'N2 note' "$R/.v/artifacts/WINNER_ELECTION_client-adapter.md" 2>/dev/null \
  && ok "manifest carries the N2 staged-only warning" \
  || no "N2 warning missing from manifest" ""
# no-candidate slug → loud non-zero, not a silent empty win
bash "$ELECT" "$R" "no-such-slug" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "unknown slug exits non-zero (no silent empty election)" || no "unknown slug exited 0" ""

# L#1 regression: swap in the CLEAN review (0 ACCEPT/MODIFY) and re-run — candidate A must
# still appear (pre-fix: arithmetic crash dropped the row entirely).
mv "$WORK/wtA/.v/artifacts/AGENT_REVIEW_${SIDA}.md.clean-probe" "$WORK/wtA/.v/artifacts/AGENT_REVIEW_${SIDA}.md"
OUT2=$(bash "$ELECT" "$R" "client-adapter" 2>/dev/null)
printf '%s\n' "$OUT2" | grep -q "aaaa1111" \
  && ok "candidate with a CLEAN review (0 ACCEPT/MODIFY) still ranks (L#1 crash fixed)" \
  || no "clean-review candidate dropped from ranking (L#1 regression)" "$(printf '%s\n' "$OUT2" | head -3)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
