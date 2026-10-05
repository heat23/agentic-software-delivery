#!/usr/bin/env bash
# Pins the TSC-gate detection rule added 2026-08-12.
#
# WHY: `npx tsc` used to run unconditionally, so in a repo with no TypeScript at all the gate
# FAILED for the ABSENCE of a compiler rather than for a defect — Overall Status: FAIL, and
# enforce-pre-commit-gates.sh then blocked every commit in that repo with no failing code anywhere.
# PHPStan, its peer static-analysis gate in the same file, already skipped loudly when its tool was
# absent. These four canaries hold the two gates to the same rule, and the last two prove the fix
# did not turn the gate off for projects that DO have TypeScript.
set -uo pipefail
GATES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-run-gates.sh"
PASS=0; FAIL=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

# Extract the REAL detection block out of v-run-gates.sh and execute THAT — not a paraphrase of
# it. An earlier version of this test inlined its own copy of the logic; bypassing the guard in the
# source left the test green, which is this project's signature failure (PANEL-CORRSEC-001: "a test
# that asserts the presence of a construct is not a test that the construct behaves the same").
# Mutation-proven: replacing the guard's `if` in the source turns canaries 1 and 2 red.
_BLOCK=$(awk '/^_TSC_HAS_PROJECT=0$/,/^fi$/' "$GATES")
[ -n "$_BLOCK" ] || { echo "  FAIL  could not extract the detection block from $GATES"; exit 1; }

_detect() {
  local dir="$1"
  ( cd "$dir" || exit 9
    V_TMP_DIR="$dir"; SESSION_ID=t; TSC_CMD_DEFAULT="true"
    TSC_PID=""; TSC_RC=""
    eval "$_BLOCK"
    # "ran" == the gate spawned a child; "skipped" == it set TSC_RC=SKIP and spawned nothing.
    if [ -n "${TSC_PID:-}" ]; then wait "$TSC_PID" 2>/dev/null; echo 1; else echo 0; fi )
}

echo "=== must SKIP — nothing to typecheck ==="
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
[ "$(_detect "$d")" = "0" ] && ok "empty dir -> skip" || bad "empty dir should skip"
mkdir -p "$d/sub"; printf '<p>x</p>' > "$d/page.html"; printf 'echo hi\n' > "$d/s.sh"
[ "$(_detect "$d")" = "0" ] && ok "html + shell only -> skip" || bad "html/shell dir should skip"

echo "=== must RUN — a real TypeScript project ==="
d2=$(mktemp -d); trap 'rm -rf "$d" "$d2"' EXIT
printf '{}' > "$d2/tsconfig.json"
[ "$(_detect "$d2")" = "1" ] && ok "tsconfig.json present -> run" || bad "tsconfig.json must still run the gate"
rm -f "$d2/tsconfig.json"; mkdir -p "$d2/node_modules/.bin"; printf '#!/bin/sh\n' > "$d2/node_modules/.bin/tsc"; chmod +x "$d2/node_modules/.bin/tsc"
[ "$(_detect "$d2")" = "1" ] && ok "local tsc binary, no config -> run" || bad "installed tsc must still run the gate"

echo "=== the source must keep the guard (mutation canary) ==="
grep -q '_TSC_HAS_PROJECT' "$GATES" && ok "guard present in v-run-gates.sh" || bad "guard removed from v-run-gates.sh"
grep -q 'if \[ -n "\$TSC_PID" \]; then wait "\$TSC_PID"' "$GATES" \
  && ok "wait is conditional on a spawned child" || bad "unconditional wait on \$TSC_PID would error when skipped"

echo
echo "TSC DETECT TEST: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
