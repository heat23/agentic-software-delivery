#!/usr/bin/env bash
# item4-fnd-exclude-staleness-test.sh — Item 4 regression test (2026-07-05).
#
# Item 19 (v-gauntlet-attest.sh) compares each gauntlet artifact's mtime against the NEWEST mtime
# among files in the session-writes ledger, to catch "source touched after the artifact was
# written, same invocation". But the ledger also contains non-source bookkeeping paths —
# DISPATCH_PROVENANCE logs (appended after every codex dispatch), REVIEW_* drafts, resolution/
# progress-note files — that get touched repeatedly throughout a long session. Before this fix,
# an append to one of THOSE after the gauntlet artifacts were written falsely tripped rc=8 (the
# "re-attest cascade" reported on very long sessions) even though no source code changed. This test
# proves: (a) a DISPATCH_PROVENANCE append after the artifacts does NOT trip rc=8 (the fix), and
# (b) a genuine source-file write after the artifacts still DOES trip rc=8 (Item 19 regression
# guard — this fix must not weaken the original bite).
set -u
SCRIPT="$HOME/.claude/skills/v/references/v-gauntlet-attest.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-gauntlet-attest.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

if ! grep -q '_FND_EXCLUDE_RE' "$SCRIPT" 2>/dev/null; then
  no "Item 4 exclude-filter present in v-gauntlet-attest.sh" "no _FND_EXCLUDE_RE reference found (pre-fix = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "Item 4 exclude-filter present in v-gauntlet-attest.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q 2>/dev/null
git -C "$REPO" config user.email test@test.local 2>/dev/null
git -C "$REPO" config user.name test 2>/dev/null
echo "seed" > "$REPO/README.md"
git -C "$REPO" add -A 2>/dev/null
git -C "$REPO" commit -qm seed 2>/dev/null

SID="66666666-7777-8888-9999-000000000000"
mkdir -p "$REPO/.v/artifacts"
BODY="$(head -c 260 < /dev/zero | tr '\0' 'x')"

write_artifacts() {
  printf 'Mode: full\n%s\n' "$BODY" > "$REPO/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
  printf 'Dispatch mode: orchestrator-inline (test)\n%s\n' "$BODY" > "$REPO/.v/artifacts/AGENT_REVIEW_${SID}.md"
  printf 'Convention check\n%s\n' "$BODY" > "$REPO/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
}

run_attest() {
  ( cd "$REPO" && PROJECT_ROOT="$REPO" GW_LIB="$HOME/.claude/hooks/lib/gauntlet-witness.sh" \
    V_VALIDATION_LIB="/nonexistent-skip-semantic-validation-for-this-test" \
    bash "$SCRIPT" "$SID" >/tmp/item4-out.$$.log 2>/tmp/item4-err.$$.log )
  echo $?
}

echo "== Item 4 :: non-source bookkeeping appends must not count as source mutations =="

write_artifacts
GCD="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
mkdir -p "$REPO/.v/artifacts"
printf '.v/artifacts/DISPATCH_PROVENANCE_%s.log\n' "$SID" > "$GCD/claude-session-writes-${SID}.txt"
touch -t 202001010000 "$REPO/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log" 2>/dev/null || \
  printf 'DISPATCH|ts=2020-01-01\n' > "$REPO/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"

# Case 1: append to the DISPATCH_PROVENANCE bookkeeping file AFTER the gauntlet artifacts exist.
sleep 1
printf 'DISPATCH|ts=%s|agent=codex-adversarial-reviewer|status=ok\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  >> "$REPO/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
rc1="$(run_attest)"
[ "$rc1" != "8" ] \
  && ok "DISPATCH_PROVENANCE append after artifact-write does NOT trip rc=8 (the fix)" \
  || no "false-positive: a non-source bookkeeping append still tripped the staleness gate" "rc=$rc1"

# Case 2: a GENUINE source-file write after the artifacts must still trip rc=8 (Item 19 regression
# guard — the exclude filter must not blanket-disable the original staleness check).
mkdir -p "$REPO/src"
printf 'src/app.php\n.v/artifacts/DISPATCH_PROVENANCE_%s.log\n' "$SID" > "$GCD/claude-session-writes-${SID}.txt"
echo "old" > "$REPO/src/app.php"
touch -t 202001010000 "$REPO/src/app.php" 2>/dev/null || true
sleep 1
echo "changed after pre-flight" >> "$REPO/src/app.php"
rc2="$(run_attest)"
[ "$rc2" = "8" ] \
  && ok "genuine source-file write after artifact-write still trips rc=8 (Item 19 regression intact)" \
  || no "exclude filter over-broadly suppressed a REAL source staleness case" "rc=$rc2 (expected 8) — $(cat /tmp/item4-err.$$.log 2>/dev/null | tail -5)"

rm -f /tmp/item4-out.$$.log /tmp/item4-err.$$.log 2>/dev/null

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
