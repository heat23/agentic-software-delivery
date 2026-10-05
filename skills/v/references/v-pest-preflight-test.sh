#!/usr/bin/env bash
# v-pest-preflight-test.sh — P1e (forensic 2026-06-17, NEW-CI-003).
# v-pest-preflight.sh must: no-op on a real vendor / no vendor (fast path); detect a SYMLINKED vendor and
# repair it via worktree-php-setup.sh; and if it STILL can't (signal INCONCLUSIVE via exit 3) warn loudly.
set -u
H="$HOME/.claude/skills/v/references/v-pest-preflight.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$H" ] || { echo "NO v-pest-preflight.sh missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OUTF="$TMP/out"; RC=0
run(){  # $1=workdir  $2=fake-HOME ("" = real HOME)
  if [ -n "$2" ]; then ( cd "$1" && HOME="$2" bash "$H" ) > "$OUTF" 2>&1
  else ( cd "$1" && bash "$H" ) > "$OUTF" 2>&1; fi
  RC=$?
}

echo "== v-pest-preflight (P1e / NEW-CI-003) =="

# 1. real vendor dir -> exit 0, no repair.
D1="$TMP/d1"; mkdir -p "$D1/vendor/bin"
run "$D1" ""
{ [ "$RC" -eq 0 ] && ! grep -q "SYMLINKED" "$OUTF"; } && ok "1 real vendor -> exit 0 (no-op)" || no "1 real vendor (rc=$RC)"

# 2. no vendor at all (non-PHP) -> exit 0.
D2="$TMP/d2"; mkdir -p "$D2"
run "$D2" ""
[ "$RC" -eq 0 ] && ok "2 no vendor -> exit 0 (no-op)" || no "2 no vendor (rc=$RC)"

# 3. symlinked vendor + repair UNAVAILABLE -> exit 3 (INCONCLUSIVE) + loud warning.
D3="$TMP/d3"; mkdir -p "$D3/realtarget/bin"; ( cd "$D3" && ln -s realtarget vendor )
FH3="$TMP/home3"; mkdir -p "$FH3/.claude/hooks"   # deliberately NO worktree-php-setup.sh inside
run "$D3" "$FH3"
{ [ "$RC" -eq 3 ] && grep -q "STILL symlinked" "$OUTF"; } && ok "3 symlinked + no repairer -> exit 3 (INCONCLUSIVE)" || no "3 symlinked-unrepairable (rc=$RC)"

# 4. symlinked vendor + a repairer that fixes it -> exit 0.
D4="$TMP/d4"; mkdir -p "$D4/realtarget/bin"; ( cd "$D4" && ln -s realtarget vendor )
FH4="$TMP/home4"; mkdir -p "$FH4/.claude/hooks"
cat > "$FH4/.claude/hooks/worktree-php-setup.sh" <<'STUB'
#!/usr/bin/env bash
cd "${1:-.}" 2>/dev/null || exit 0
rm -f vendor 2>/dev/null; mkdir -p vendor/bin 2>/dev/null
exit 0
STUB
run "$D4" "$FH4"
{ [ "$RC" -eq 0 ] && grep -q "repairing" "$OUTF"; } && ok "4 symlinked + repairer fixes it -> exit 0 (vendor now real)" || no "4 symlinked-repaired (rc=$RC)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
