#!/usr/bin/env bash
# v-run-gates-vendor-guard-test.sh — F1 (forensic 2026-06-17).
#
# A worktree with a SYMLINKED vendor/ makes PHP resolve __DIR__ through the symlink → ./vendor/bin/pest runs
# MAIN's binary against the worktree's tests → thousands of false BindingResolutionException failures + a
# misleading pre-flight (a production session burned ~12 min). v-run-gates.sh now detects this BEFORE running the
# suite and, if a repair can't fix it, marks the PHP gate INCONCLUSIVE with the real reason instead of running
# the false failures. This locks that guard.
set -u
RG="$HOME/.claude/skills/v/references/v-run-gates.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$RG" ] || { echo "NO v-run-gates.sh missing"; exit 1; }

echo "== v-run-gates :: F1 broken-worktree-vendor guard =="

# 1. bash -n
bash -n "$RG" && ok "v-run-gates.sh parses (bash -n)" || no "v-run-gates.sh syntax error"

# 2. _vendor_symlinked detection (extract + exercise): symlinked vendor -> true; real -> false.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
sed -n '/^_vendor_symlinked() {/p' "$RG" > "$TMP/fn.sh"
if [ -s "$TMP/fn.sh" ]; then
  ( cd "$TMP"; . "$TMP/fn.sh"
    mkdir realvendor; ln -s realvendor vendor   # symlinked vendor
    _vendor_symlinked && echo SYMLINK_DETECTED ) | grep -q SYMLINK_DETECTED && ok "_vendor_symlinked detects a symlinked vendor" || no "_vendor_symlinked missed a symlinked vendor"
  ( cd "$TMP"; rm -f vendor; mkdir vendor vendor/bin; . "$TMP/fn.sh"
    _vendor_symlinked && echo BROKEN || echo REAL ) | grep -q REAL && ok "_vendor_symlinked: a REAL vendor (real dir + real bin) is not flagged" || no "_vendor_symlinked false-positived a real vendor"
else
  no "could not extract _vendor_symlinked from v-run-gates.sh"
fi

# 3. WIRING (structural — a full v-run-gates run is not a reliable vehicle here: unrelated gates like
#    composer-audit hang on a synthetic repo; the detection above is the behavioral core). Assert the
#    pest decision's FIRST arm routes a broken vendor to INCONCLUSIVE, before the normal pest arms.
PEST_SECTION=$(awk '/^VENDOR_BROKEN=0/{f=1} f; /elif \[ -f "composer.json"/{if(f)exit}' "$RG" 2>/dev/null)
printf '%s\n' "$PEST_SECTION" | grep -qE 'if _vendor_symlinked; then' \
  && ok "guard computes VENDOR_BROKEN from _vendor_symlinked before the pest decision" \
  || no "VENDOR_BROKEN not computed from _vendor_symlinked"
printf '%s\n' "$PEST_SECTION" | grep -qE 'WORKTREE_PATH="\$PWD".*worktree-php-setup\.sh|bash "\$_wt_setup"' \
  && ok "guard attempts a repair (re-run worktree-php-setup.sh CoW-clone) before giving up" \
  || no "guard does not attempt a worktree-php-setup repair"
# the FIRST arm of the pest if-chain must be VENDOR_BROKEN -> INCONCLUSIVE
FIRST_ARM=$(awk '/^if \[ "\$VENDOR_BROKEN" -eq 1 \]; then/{f=1} f{print} /^elif \[ "\$PHP_FILES_TOUCHED"/{if(f)exit}' "$RG" 2>/dev/null)
if printf '%s\n' "$FIRST_ARM" | grep -qE 'PEST_RC="INCONCLUSIVE"' && printf '%s\n' "$FIRST_ARM" | grep -qiE 'symlinked'; then
  ok "pest decision's FIRST arm: VENDOR_BROKEN -> PEST_RC=INCONCLUSIVE with the root-cause reason (not a false-failure run)"
else
  no "pest decision does not route a broken vendor to INCONCLUSIVE-with-reason first"
fi
# INCONCLUSIVE must NOT be treated as a hard failure downstream (it is a recognized non-fail verdict)
grep -qE '\[ "\$PEST_RC" != "INCONCLUSIVE" \]' "$RG" 2>/dev/null \
  && ok "downstream treats PEST_RC=INCONCLUSIVE as a recognized (non-fail) verdict" \
  || no "INCONCLUSIVE not recognized downstream (would be mis-aggregated)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
