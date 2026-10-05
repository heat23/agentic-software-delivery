#!/usr/bin/env bash
# v-scoped-pest-runner-test.sh — W-SCOPEDPEST: the scoped lane must use the RESOLVED php-test
# runner, not a hardcoded ./vendor/bin/pest (2026-08-04).
#
# THE BUG, MEASURED. Across 889 historical gate laps the SCOPED lane failed 37% of the time
# (145/390) against 8% for full (42/499) — 4.6x. Root cause, reproduced directly in one project:
#     ./vendor/bin/pest --parallel …   → RC=127  "No such file or directory"
#     php artisan test --filter=…      → RC=0    39 passed (510 assertions)
# The project runs PHPUnit via `php artisan test`; there is NO standalone pest binary. The
# resolver at v-run-gates.sh:411-417 already handles this correctly (PEST_CMD env → pest binary
# if executable → `php artisan test`) and the FULL lane consumes it at 1106-1109. The SCOPED lane
# bypassed it and hardcoded ./vendor/bin/pest at three call sites, so every scoped re-verify in
# such a project exits 127 within seconds → PEST_RC!=0 → ALL_PASS=0 → the orchestrator
# re-dispatches. Observed 6/6 degenerate scoped laps in one session (21 laps total), 5/5 in
# a second, 5/5 in a third — with BLIND=0, TREE_MISMATCH=0, SCOPE_N=12, i.e. a real scope that
# simply could not run.
#
# SECOND DEFECT COVERED HERE. `--parallel` is paratest-backed. A project can have ./vendor/bin/pest
# WITHOUT brianium/paratest, in which case the flag itself fails. The resolution must gate
# --parallel (and the paratest-only --passthru-php memory flag) on the paratest binary existing.
#
# RED ORACLE: V_RUN_GATES=<pre-W-SCOPEDPEST bak> still hardcodes ./vendor/bin/pest in the scoped arm.
set -u
RG="${V_RUN_GATES:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$RG" ] || { echo "  NO  v-run-gates.sh not found"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== W-SCOPEDPEST :: scoped lane no longer hardcodes the pest binary =="
# The scoped arm lives between the `scoped|dirty-tree)` case label and the `full|*)` label.
SCOPED_ARM=$(awk '/^    scoped\|dirty-tree\)/,/^    full\|\*\)/' "$RG")
[ -n "$SCOPED_ARM" ] && ok "scoped arm located" || no "could not locate the scoped arm" ""
if [ -n "$SCOPED_ARM" ]; then
  # Count real INVOCATIONS only: `xargs ./vendor/bin/pest …` or a line that starts with it.
  # A `[ -x "./vendor/bin/pest" ]` existence guard is legitimate (that is how the resolver
  # decides), and a comment explaining the fix is not an invocation — neither must count, or
  # the assertion would forbid the very code that implements it.
  n=$(printf '%s\n' "$SCOPED_ARM" | grep -v '^[[:space:]]*#' \
        | grep -cE '(xargs[[:space:]]+|^[[:space:]]*)\./vendor/bin/pest' || true)
  [ "${n:-0}" -eq 0 ] \
    && ok "scoped arm has ZERO hardcoded ./vendor/bin/pest INVOCATIONS" \
    || no "scoped arm still invokes ./vendor/bin/pest directly ($n sites) — RC=127 on any non-pest project" ""
  printf '%s' "$SCOPED_ARM" | grep -q '_PEST_SCOPED_BIN' \
    && ok "scoped arm uses the resolved runner variable" \
    || no "scoped arm does not reference the resolved runner" ""
fi

echo "== W-SCOPEDPEST :: the resolver itself picks the right runner =="
RES=$(awk '/=== W-SCOPEDPEST resolve/,/=== end W-SCOPEDPEST resolve/' "$RG")
if [ -z "$RES" ]; then
  no "W-SCOPEDPEST resolver block present" "awk range empty (pre-fix = RED)"
else
  ok "W-SCOPEDPEST resolver block present"
  resolve(){ # $1=fixture dir -> "BIN|PAR"
    ( set +eu; cd "$1" || exit 1
      V_PEST_PROCESSES_SCOPED=2; PEST_CMD="${PEST_CMD_OVERRIDE:-}"
      eval "$RES" >/dev/null 2>&1
      printf '%s|%s' "$_PEST_SCOPED_BIN" "$_PEST_SCOPED_PAR" )
  }
  # (a) no pest binary at all — the shape that produced RC=127
  mkdir -p "$WORK/nopest/vendor/bin"
  r=$(resolve "$WORK/nopest")
  [ "$r" = "php artisan test|" ] \
    && ok "no pest binary → 'php artisan test', no --parallel (the RC=127 case, fixed)" \
    || no "wrong resolution with no pest binary" "$r"
  # (b) pest present but paratest ABSENT — --parallel would fail on the flag itself
  mkdir -p "$WORK/pestonly/vendor/bin"; printf '#!/bin/sh\n' > "$WORK/pestonly/vendor/bin/pest"; chmod +x "$WORK/pestonly/vendor/bin/pest"
  r=$(resolve "$WORK/pestonly")
  case "$r" in
    "./vendor/bin/pest|") ok "pest WITHOUT paratest → pest binary, --parallel withheld" ;;
    *) no "pest-without-paratest resolution wrong" "$r" ;;
  esac
  # (c) pest AND paratest — the fast path must be preserved, not regressed away
  mkdir -p "$WORK/both/vendor/bin"
  printf '#!/bin/sh\n' > "$WORK/both/vendor/bin/pest";     chmod +x "$WORK/both/vendor/bin/pest"
  printf '#!/bin/sh\n' > "$WORK/both/vendor/bin/paratest"; chmod +x "$WORK/both/vendor/bin/paratest"
  r=$(resolve "$WORK/both")
  case "$r" in
    "./vendor/bin/pest|--parallel --processes=2") ok "pest WITH paratest → --parallel preserved (no speed regression)" ;;
    *) no "paratest fast path regressed" "$r" ;;
  esac
  # (d) explicit PEST_CMD always wins (documented contract at v-run-gates.sh:411)
  r=$(PEST_CMD_OVERRIDE="php artisan test --custom" resolve "$WORK/both")
  case "$r" in
    "php artisan test --custom|") ok "explicit PEST_CMD wins and suppresses --parallel" ;;
    *) no "PEST_CMD override not honoured" "$r" ;;
  esac
fi

echo "== W-SCOPEDPEST :: the FULL lane gates --parallel on paratest too (same class) =="
# Class sweep 2026-08-04: the scoped fix gated --parallel on the paratest binary, but the FULL
# lane at v-run-gates.sh:411-417 still emitted `--parallel` whenever ./vendor/bin/pest existed,
# regardless of paratest. Surveyed all local projects: none currently has pest WITHOUT paratest,
# so this is LATENT rather than live — but it is the identical failure (pest rejects the flag, the
# gate reads it as a test failure) and it arms itself the moment someone installs pest alone.
# Gating costs nothing today (every project with pest has paratest, so the parallel branch still
# fires) and converts a future hard break into a slower-but-correct single-process run.
FULL=$(awk '/^# Full-mode PHP test default/,/^VITEST_CMD_DEFAULT=/' "$RG")
if [ -z "$FULL" ]; then
  no "full-lane resolver located" "awk range empty"
else
  ok "full-lane resolver located"
  printf '%s' "$FULL" | grep -q 'vendor/bin/paratest' \
    && ok "full lane gates --parallel on the paratest binary" \
    || no "full lane emits --parallel without checking paratest (latent: pest-without-paratest breaks it)" ""
  # The non-paratest fallback must still USE pest (it exists) — just without the flag.
  printf '%s' "$FULL" | grep -qE 'PEST_CMD_DEFAULT="\./vendor/bin/pest"' \
    && ok "pest-without-paratest → bare pest (correct, just single-process)" \
    || no "no bare-pest fallback for the pest-without-paratest case" ""
fi

echo "== W-SCOPEDPEST :: paratest-only flags are gated on parallelism =="
if [ -n "$SCOPED_ARM" ]; then
  # --passthru-php (_PEST_MEM_PASSTHRU) is paratest-only; appending it to `php artisan test`
  # makes it reject an unknown flag — the same class of failure this whole fix removes.
  bad=$(printf '%s' "$SCOPED_ARM" | grep -c '_PEST_MEM_PASSTHRU' || true)
  gated=$(printf '%s' "$SCOPED_ARM" | grep -c '_PEST_SCOPED_PAR' || true)
  { [ "${bad:-0}" -eq 0 ] || [ "${gated:-0}" -gt 0 ]; } \
    && ok "paratest-only memory flag only appears alongside the gated parallel opts" \
    || no "memory passthru is applied unconditionally" "bad=$bad gated=$gated"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
