#!/usr/bin/env bash
# v-scoped-pest-multifile-test.sh — (forensic, 2026-06-15 wave): scoped pre-flight invoked
# `echo "$PHP_TEST_FILES" | tr '\n' ' ' | xargs ./vendor/bin/pest --parallel --processes=N <files...>`.
# paratest (`pest --parallel`) accepts only ONE <path> positional, so when a session changed >1 PHP
# test file (one session changed 5) paratest aborted with Symfony Console "Too many arguments, expected
# arguments 'path'" → a FALSE PEST_RC=1 with 0 extractable paths (E1 then absorbed it as INCONCLUSIVE,
# papering over the real cause). Fix: for >1 explicit scoped test file, run SEQUENTIALLY (pest/phpunit
# accept multiple <path> args) and DROP the paratest-only --parallel/--processes/--passthru-php flags.
#
# Two checks: (1) CONTRACT — the file-count branch + rationale are present in v-run-gates.sh (drift
# guard); (2) FUNCTIONAL — the decision, replicated against a stub `pest` that records argv, picks
# --parallel for 1 file and a flag-free sequential run for >1 file. The functional snippet MIRRORS
# v-run-gates.sh (kept in sync); the CONTRACT check fails loudly if the script drifts from it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GATES="$HERE/v-run-gates.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

echo "== scoped pest multi-file paratest-arity fix =="
[ -f "$GATES" ] || { echo "  NO  v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

# ── (1) CONTRACT: the fix is present (catches accidental revert / drift) ──
grep -q '_n_php_test_files' "$GATES" && ok "contract: PHP-test-file count branch present" || no "count branch missing"
grep -q "Too many arguments" "$GATES" && ok "contract: paratest-arity rationale documented" || no "rationale comment missing"
# The >1-file branch must NOT carry --parallel (that is exactly the arity bug). Verify the sequential
# xargs line (the one with no --parallel) exists alongside the parallel single-file line.
# 2026-08-05 ORPHAN-ROT FIX (found by the full harness sweep, not by a gate failure): this pinned the
# LITERAL `./vendor/bin/pest`, and v-run-gates.sh later parameterised the binary into
# `$_PEST_SCOPED_BIN` (v-run-gates.sh:1129). The assertion then failed while the FEATURE was fine —
# every functional sibling below stayed green. This is not a weakened assertion: the property under
# test is unchanged (a sequential xargs branch that carries NO --parallel); only the way the binary is
# spelled is now allowed to vary, because pinning a refactorable spelling is what rotted.
grep -qE 'xargs (\./vendor/bin/pest|\$_PEST_SCOPED_BIN) > ' "$GATES" && ok "contract: sequential (no --parallel) multi-file branch present" || no "sequential multi-file branch missing"
# Pin the THRESHOLD operator (codex LOW-1): the mirror+string-presence checks above stay green if the
# real script's `-gt 1` drifts to `-gt 0` (regresses single-file) or `-lt 1` (re-routes multi-file into
# the broken --parallel branch). This fixed-string assertion fails loudly on either mutation.
grep -qF '"${_n_php_test_files:-0}" -gt 1 ]' "$GATES" && ok "contract: threshold operator pinned (-gt 1)" || no "threshold operator drifted (-gt 1 → -gt 0/-lt 1 silently reintroduces the bug)"

# ── (2) FUNCTIONAL: replicate the decision against a stub pest that records argv ──
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/vendor/bin"
cat > "$TMP/vendor/bin/pest" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_OUT"
STUB
chmod +x "$TMP/vendor/bin/pest"

# Decision logic — MIRRORS v-run-gates.sh lines ~560-572 (keep in sync; CONTRACT above guards drift).
run_scoped_pest(){
  local PHP_TEST_FILES="$1"
  local V_PEST_PROCESSES_SCOPED="${2:-4}"
  local _PEST_MEM_PASSTHRU="${3:-}"
  local _n_php_test_files
  _n_php_test_files=$(printf '%s\n' "$PHP_TEST_FILES" | grep -c .)
  if [ "${_n_php_test_files:-0}" -gt 1 ]; then
    echo "$PHP_TEST_FILES" | tr '\n' ' ' | xargs ./vendor/bin/pest
  else
    echo "$PHP_TEST_FILES" | tr '\n' ' ' | xargs ./vendor/bin/pest --parallel --processes="${V_PEST_PROCESSES_SCOPED}" ${_PEST_MEM_PASSTHRU:+"$_PEST_MEM_PASSTHRU"}
  fi
}

cd "$TMP" || { echo "  NO  cannot cd tmp"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

# Single file → keep --parallel (paratest accepts one <path>).
ARGV_OUT="$TMP/argv1.txt"; export ARGV_OUT
run_scoped_pest "tests/Feature/ATest.php" 4 "--passthru-php=mem"
grep -q -- '--parallel' "$TMP/argv1.txt" && ok "1 file: --parallel kept" || no "1 file: --parallel missing"
grep -q 'tests/Feature/ATest.php' "$TMP/argv1.txt" && ok "1 file: path passed" || no "1 file: path missing"

# Multi file → sequential: NO --parallel, NO --processes, NO --passthru-php, ALL paths passed.
ARGV_OUT="$TMP/argv2.txt"; export ARGV_OUT
run_scoped_pest "$(printf 'tests/Feature/ATest.php\ntests/Feature/BTest.php\ntests/Feature/CTest.php')" 4 "--passthru-php=mem"
grep -q -- '--parallel'     "$TMP/argv2.txt" && no ">1 file: --parallel must be ABSENT (the arity bug)"   || ok ">1 file: no --parallel (sequential)"
grep -q -- '--processes'    "$TMP/argv2.txt" && no ">1 file: --processes must be ABSENT (paratest-only)"  || ok ">1 file: no --processes"
grep -q -- '--passthru-php' "$TMP/argv2.txt" && no ">1 file: --passthru-php must be ABSENT (paratest-only)" || ok ">1 file: no --passthru-php"
{ grep -q 'ATest.php' "$TMP/argv2.txt" && grep -q 'BTest.php' "$TMP/argv2.txt" && grep -q 'CTest.php' "$TMP/argv2.txt"; } \
  && ok ">1 file: all 3 paths passed" || no ">1 file: not all paths passed"

# Boundary: an empty list must not be treated as multi (grep -c . == 0 → single/parallel branch, which
# the caller guards with `[ -n "$PHP_TEST_FILES" ]`; here we just assert the count is 0, not >1).
[ "$(printf '%s\n' '' | grep -c .)" = "0" ] && ok "boundary: empty list counts as 0 (not multi)" || no "boundary: empty list miscounted"

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
