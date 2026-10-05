#!/usr/bin/env bash
# v-owns-check-test.sh — verifies the OWNS-contract advisory checker (forensic A-7 2026-06-04):
# bullet normalization, built-in allowances (tests / bookkeeping / release stanzas), custom
# --allow globs, dir-prefix OWNS entries, changed-set derivation from session-writes + commit
# witness (and the REFUSAL to fall back to a sibling-leaking base..HEAD window), exit-code
# contract (0 pass / 3 drift / 4 unverifiable / 2 usage), and that the documented IMPACT_MAP
# `owns_contract:` lines round-trip through the REAL validator (extra lines must not bounce).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/v-owns-check.sh"
SKELETON="$HERE/v-artifact-skeleton.sh"
VALIDATION="$(cd "$HERE/../../.." && pwd)/hooks/lib/validation.sh"
[ -f "$VALIDATION" ] || VALIDATION="$HOME/.claude/hooks/lib/validation.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SID="0wn5dead-0000-4000-8000-000000000000"

# Temp repo (the checker resolves REPO_ROOT/.v/tmp and the commit witness via git).
MR="$WORK/repo"
mkdir -p "$MR/.v/tmp"
git -C "$MR" init -q
git -C "$MR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# OWNS file in raw prompt-bullet form (the normalizer's job)
OWNS="$WORK/owns.txt"
cat > "$OWNS" <<'EOF'
- `app/Services/ExampleOAuthService.php`
- `app/Http/Controllers/ExampleConnectionController.php` (verify routing)
app/Services/ExampleHandshakeService.php
- plugin-dir/example-plugin/includes/admin.php (settings page)
- `app/Owned`
EOF

run() { # run <files...> -> sets OUT/RC ; one changed file per arg
  local ff="$WORK/files.txt"; : > "$ff"
  local f; for f in "$@"; do printf '%s\n' "$f" >> "$ff"; done
  OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$OWNS" --files "$ff") 2>&1 ); RC=$?
}

echo "== v-owns-check :: classification =="

# 1. all-owned (backtick bullet, annotated bullet, bare line, non-backtick annotated bullet)
run app/Services/ExampleOAuthService.php app/Http/Controllers/ExampleConnectionController.php \
    app/Services/ExampleHandshakeService.php plugin-dir/example-plugin/includes/admin.php
[ "$RC" -eq 0 ] && ok "all-owned set → exit 0" || no "all-owned exit $RC (out: $OUT)"
echo "$OUT" | head -1 | grep -q '^OWNS-CHECK: PASS (4 changed files' && ok "PASS line machine-readable with count" || no "PASS first line wrong: $(echo "$OUT" | head -1)"

# 2. dir-prefix OWNS entry
run app/Owned/DeepFile.php
[ "$RC" -eq 0 ] && ok "dir-prefix OWNS entry covers nested file" || no "dir-prefix failed (out: $OUT)"

# 3. drift: production file outside OWNS (a sibling-file drift class)
run app/Services/ExampleOAuthService.php app/Services/ApiClient.php
[ "$RC" -eq 3 ] && ok "outside-OWNS production file → exit 3" || no "drift exit $RC (want 3)"
echo "$OUT" | head -1 | grep -q '^OWNS-CHECK: DRIFT (1 of 2' && ok "DRIFT first line carries counts" || no "DRIFT first line wrong: $(echo "$OUT" | head -1)"
echo "$OUT" | grep -q '^  - app/Services/ApiClient.php$' && ok "drifted file listed" || no "drifted file not listed"

# 4. built-in allowances: tests at any depth + *Test.php + *.test.* + *.spec.*
run tests/Feature/Sync/ExampleSyncTest.php plugin-dir/example-plugin/tests/bootstrap.php \
    resources/js/Pages/Reports/View.test.tsx app/Services/FooSpecHelperTest.php src/x.spec.ts
[ "$RC" -eq 0 ] && ok "test files never drift (TDD allowance)" || no "test files flagged as drift (out: $OUT)"

# 5. bookkeeping: .v/**, session artifacts, handoffs, session logs
run .v/artifacts/IMPACT_MAP_${SID}.md "PRE_FLIGHT_REPORT_${SID}.md" \
    "WORKTREE_HANDOFF_${SID}.md" "SESSION_LOG_${SID}.yaml"
[ "$RC" -eq 0 ] && ok "session bookkeeping never drifts" || no "bookkeeping flagged (out: $OUT)"

# 6. release stanzas allowed; version-bump CODE file still drifts (deliberate)
run plugin-dir/example-plugin/CHANGELOG.md plugin-dir/example-plugin/readme.txt plugin-dir/example-plugin/example-plugin.php
[ "$RC" -eq 3 ] && ok "CHANGELOG/readme allowed but version-bump code file still drifts" || no "release-file case exit $RC (out: $OUT)"
echo "$OUT" | grep -q 'example-plugin.php' && ok "the code file is the one reported" || no "wrong file reported"

# 7. --allow custom convention glob
_ff="$WORK/files.txt"; printf 'plugin-dir/example-plugin/example-plugin.php\n' > "$_ff"
OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$OWNS" --files "$_ff" --allow 'plugin-dir/*/example-plugin.php') 2>&1 ); RC=$?
[ "$RC" -eq 0 ] && ok "--allow glob admits convention file" || no "--allow glob failed (rc=$RC out: $OUT)"

# 8. absolute paths normalized to repo-relative (use git's PHYSICAL root — on macOS mktemp
# yields /var/... while git reports /private/var/..., and the checker strips git's form)
MR_PHYS=$(git -C "$MR" rev-parse --show-toplevel)
run "$MR_PHYS/app/Services/ExampleOAuthService.php"
[ "$RC" -eq 0 ] && ok "absolute path normalized against REPO_ROOT" || no "absolute path not normalized (out: $OUT)"

echo "== v-owns-check :: changed-set derivation =="

# 9. derives from session-writes log when --files omitted
printf 'app/Services/ExampleOAuthService.php\napp/Services/ApiClient.php\n' > "$MR/.v/tmp/session-writes-${SID}.txt"
OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$OWNS") 2>&1 ); RC=$?
[ "$RC" -eq 3 ] && ok "derived from session-writes log (drift found)" || no "session-writes derivation rc=$RC (out: $OUT)"
rm -f "$MR/.v/tmp/session-writes-${SID}.txt"

# 10. derives from the commit witness (merge-back ground truth)
mkdir -p "$MR/app/Services"
printf '<?php\n' > "$MR/app/Services/ApiClient.php"
git -C "$MR" add app/Services/ApiClient.php
git -C "$MR" -c user.email=t@t -c user.name=t commit -q -m "outside owns"
git -C "$MR" rev-parse HEAD > "$MR/.v/tmp/commits-${SID}.txt"
OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$OWNS") 2>&1 ); RC=$?
[ "$RC" -eq 3 ] && ok "derived from commit witness (drift found)" || no "witness derivation rc=$RC (out: $OUT)"
echo "$OUT" | grep -q 'app/Services/ApiClient.php' && ok "witness-derived file reported" || no "witness file missing from report"
rm -f "$MR/.v/tmp/commits-${SID}.txt"

# 11. NO evidence → UNVERIFIABLE (never a base..HEAD sibling-leak fallback)
OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$OWNS") 2>&1 ); RC=$?
[ "$RC" -eq 4 ] && ok "no evidence → exit 4 UNVERIFIABLE" || no "no-evidence rc=$RC (out: $OUT)"
echo "$OUT" | head -1 | grep -q '^OWNS-CHECK: UNVERIFIABLE' && ok "UNVERIFIABLE first line" || no "UNVERIFIABLE line wrong"
# sentinel: no non-comment `git diff`/`git rev-list` window fallback may ever appear (B-1:
# a shared base..HEAD window counts SIBLING sessions' commits → false drift). Comments and
# the refusal message legitimately mention base..HEAD — only executable use is forbidden.
if grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE 'git ([^|;&]*[[:space:]])?(diff|rev-list)'; then
  no "checker contains an executable git diff/rev-list window fallback (sibling-leak risk)"
else
  ok "no executable base..HEAD fallback in checker (B-1 guard)"
fi

echo "== v-owns-check :: input hygiene =="

# 12. missing owns file → UNVERIFIABLE 4 ; junk-only owns → UNVERIFIABLE 4
OUT=$(bash "$SCRIPT" "$SID" --owns "$WORK/nope.txt" 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "missing owns file → exit 4" || no "missing owns rc=$RC"
printf '## Task\n**MUST NOT TOUCH:**\n\n' > "$WORK/junk.txt"
OUT=$(bash "$SCRIPT" "$SID" --owns "$WORK/junk.txt" 2>&1); RC=$?
[ "$RC" -eq 4 ] && ok "junk-only owns file → exit 4" || no "junk owns rc=$RC (out: $OUT)"

# 12b. CODEX-006: a deny-list line carrying a BACKTICK path must never become an allowed entry
cat > "$WORK/deny.txt" <<'EOF'
- `app/Services/ExampleOAuthService.php`
**MUST NOT TOUCH:** `app/Services/OtherSessionService.php` (another session owns it)
- DO NOT EDIT `app/Services/BackgroundSyncService.php`
EOF
_ff="$WORK/files.txt"; printf 'app/Services/OtherSessionService.php\napp/Services/BackgroundSyncService.php\n' > "$_ff"
OUT=$( (cd "$MR" && bash "$SCRIPT" "$SID" --owns "$WORK/deny.txt" --files "$_ff") 2>&1 ); RC=$?
[ "$RC" -eq 3 ] && ok "backtick deny-list lines do NOT become OWNS entries (CODEX-006 false-PASS guard)" || no "deny-list line inverted into allowance (rc=$RC out: $OUT)"
echo "$OUT" | grep -q 'OtherSessionService.php' && echo "$OUT" | grep -q 'BackgroundSyncService.php' \
  && ok "both deny-listed files reported as drift" || no "deny-listed files not reported"

# 13. usage errors → exit 2
bash "$SCRIPT" >/dev/null 2>&1; [ $? -eq 2 ] && ok "no args → exit 2" || no "no-args exit wrong"
bash "$SCRIPT" "$SID" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --owns → exit 2" || no "missing --owns exit wrong"
bash "$SCRIPT" "$SID" --owns "$OWNS" --bogus x >/dev/null 2>&1; [ $? -eq 2 ] && ok "unknown flag → exit 2" || no "unknown flag exit wrong"

echo "== IMPACT_MAP round-trip :: owns_contract lines must not bounce the validator =="
if [ -f "$VALIDATION" ] && [ -f "$SKELETON" ]; then
  # shellcheck source=/dev/null
  if source "$VALIDATION" 2>/dev/null && type validate_impact_map_semantics >/dev/null 2>&1; then
    bash "$SKELETON" --type impact_map --sid "$SID" > "$WORK/im.md" 2>/dev/null
    {
      echo "owns_contract: drift"
      echo "owns_drift_files:"
      echo "  - app/Services/ApiClient.php"
    } >> "$WORK/im.md"
    if validate_impact_map_semantics "$WORK/im.md" >/dev/null 2>&1; then
      ok "IMPACT_MAP + owns_contract lines still passes validate_impact_map_semantics"
    else
      no "owns_contract lines BOUNCE the IMPACT_MAP validator: $(validate_impact_map_semantics "$WORK/im.md" 2>&1)"
    fi
  else
    no "could not source validation.sh / find validate_impact_map_semantics"
  fi
else
  no "validation.sh or v-artifact-skeleton.sh missing (cannot round-trip)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
