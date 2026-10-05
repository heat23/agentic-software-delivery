#!/usr/bin/env bash
# v-run-waves-test.sh — locks v-run-waves.sh with a STUBBED claude (no real sessions, mutation-safe).
# Covers: dry-run launches nothing; success writes .done; waves run sequentially; resume skips .done
# (claude NOT re-invoked); failure is skip-and-continue (exit 1, siblings still run); --force re-runs;
# --stop-on-fail halts the next wave; a flat (no-subdir) dir is one wave; --prefix is honored.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/v-run-waves.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
echo "== v-run-waves driver =="
[ -f "$DRIVER" ] || { echo "  NO  v-run-waves.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
bash -n "$DRIVER" || { echo "  NO  v-run-waves.sh syntax error"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null || true' EXIT
CALLLOG="$BASE/calls.log"
STUB="$BASE/claude-stub"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
# stub claude: --print is a flag; --model takes a VALUE (skip it, like the real CLI);
# first remaining non-flag arg is the prompt. Log it; exit 1 on FAILME.
prompt=""; skip=0
for a in "$@"; do
  if [ "$skip" = "1" ]; then skip=0; continue; fi
  case "$a" in --model) skip=1 ;; --*) ;; *) [ -z "$prompt" ] && prompt="$a";; esac
done
printf '%s\n' "$prompt" >> "$STUB_CALLLOG"
case "$prompt" in *FAILME*) exit 1;; *) exit 0;; esac
STUBEOF
chmod +x "$STUB"

mkwaves() { local d="$1"; rm -rf "$d"; mkdir -p "$d/wave-01" "$d/wave-02"
  printf 'TASK-A\n' > "$d/wave-01/01-a.txt"; printf 'TASK-B\n' > "$d/wave-01/02-b.txt"
  printf 'TASK-C\n' > "$d/wave-02/01-c.txt"; }
calls() { [ -f "$CALLLOG" ] && wc -l < "$CALLLOG" | tr -d ' ' || echo 0; }
run() { : > "$CALLLOG"; OUT="$(CLAUDE_BIN="$STUB" STUB_CALLLOG="$CALLLOG" bash "$DRIVER" "$@" 2>&1)"; RC=$?; }

# T1 — dry-run: enumerate, launch nothing
W="$BASE/w1"; mkwaves "$W"; run "$W" --dry-run
[ "$RC" -eq 0 ] && ok "T1: dry-run exits 0" || no "T1: rc=$RC"
[ "$(calls)" = "0" ] && ok "T1: dry-run invoked claude 0x" || no "T1: dry-run called claude $(calls)x"
[ ! -f "$W/wave-01/01-a.txt.done" ] && ok "T1: dry-run wrote no .done" || no "T1: dry-run wrote .done"
{ echo "$OUT" | grep -q 'wave-01/01-a.txt' && echo "$OUT" | grep -q 'wave-02/01-c.txt'; } && ok "T1: lists all prompts" || no "T1: plan missing prompts"

# T2 — real run (concurrency 1): all pass, .done written, wave order, summary
W="$BASE/w2"; mkwaves "$W"; run "$W" --concurrency 1
[ "$RC" -eq 0 ] && ok "T2: all-pass exits 0" || no "T2: rc=$RC | $OUT"
{ [ -f "$W/wave-01/01-a.txt.done" ] && [ -f "$W/wave-01/02-b.txt.done" ] && [ -f "$W/wave-02/01-c.txt.done" ]; } && ok "T2: all 3 .done written" || no "T2: missing .done"
[ "$(calls)" = "3" ] && ok "T2: claude invoked exactly 3x" || no "T2: claude calls=$(calls)"
a=$(grep -n 'TASK-A' "$CALLLOG" | head -1 | cut -d: -f1); c=$(grep -n 'TASK-C' "$CALLLOG" | head -1 | cut -d: -f1)
{ [ -n "$a" ] && [ -n "$c" ] && [ "$a" -lt "$c" ]; } && ok "T2: wave-01 ran before wave-02" || no "T2: wave order wrong (A@$a C@$c)"
echo "$OUT" | grep -q 'passed=3  failed=0' && ok "T2: summary passed=3 failed=0" || no "T2: summary wrong"

# T3 — resume: re-run skips .done, claude NOT re-invoked
run "$W" --concurrency 1
[ "$RC" -eq 0 ] && ok "T3: resume exits 0" || no "T3: rc=$RC"
[ "$(calls)" = "0" ] && ok "T3: resume invoked claude 0x (all skipped)" || no "T3: resume re-called claude $(calls)x"
echo "$OUT" | grep -q 'skipped=3' && ok "T3: summary skipped=3" || no "T3: skipped count wrong"

# T4 — --force re-runs everything
run "$W" --concurrency 1 --force
[ "$(calls)" = "3" ] && ok "T4: --force re-invoked claude 3x" || no "T4: force calls=$(calls)"

# T5 — failure is skip-and-continue: exit 1, failed prompt no .done, siblings .done
W="$BASE/w5"; mkwaves "$W"; printf 'FAILME-X\n' > "$W/wave-01/02-b.txt"; run "$W" --concurrency 1
[ "$RC" -eq 1 ] && ok "T5: a failure makes the run exit 1" || no "T5: rc=$RC (expected 1)"
[ ! -f "$W/wave-01/02-b.txt.done" ] && ok "T5: failed prompt has NO .done" || no "T5: failed prompt wrongly marked done"
{ [ -f "$W/wave-01/01-a.txt.done" ] && [ -f "$W/wave-02/01-c.txt.done" ]; } && ok "T5: continued past failure (siblings ran)" || no "T5: did not continue"
echo "$OUT" | grep -q 'failed=1' && ok "T5: summary failed=1" || no "T5: failed count wrong"

# T6 — --stop-on-fail halts before the next wave
W="$BASE/w6"; mkwaves "$W"; printf 'FAILME-Y\n' > "$W/wave-01/01-a.txt"; run "$W" --concurrency 1 --stop-on-fail
[ ! -f "$W/wave-02/01-c.txt.done" ] && ok "T6: --stop-on-fail halted before wave-02" || no "T6: continued past stop-on-fail"

# T7 — flat dir (no subdirs) = one wave
W="$BASE/w7"; rm -rf "$W"; mkdir -p "$W"; printf 'FLAT-1\n' > "$W/01.txt"; printf 'FLAT-2\n' > "$W/02.txt"; run "$W" --concurrency 1
{ [ "$RC" -eq 0 ] && [ -f "$W/01.txt.done" ] && [ -f "$W/02.txt.done" ]; } && ok "T7: flat single-wave dir works" || no "T7: flat dir failed (rc=$RC)"

# T8 — --prefix honored (default '/v '; '' passes raw)
W="$BASE/w8"; rm -rf "$W"; mkdir -p "$W"; printf 'PFXTEST\n' > "$W/01.txt"
run "$W" --concurrency 1; grep -q '^/v PFXTEST' "$CALLLOG" && ok "T8: default prefix '/v ' prepended" || no "T8: prefix not applied ($(head -1 "$CALLLOG"))"
run "$W" --concurrency 1 --force --prefix ""; grep -q '^PFXTEST$' "$CALLLOG" && ok "T8: --prefix '' passes raw content" || no "T8: empty prefix wrong ($(head -1 "$CALLLOG"))"

# T9 — logs dotdir is NOT mistaken for a wave on re-run
W="$BASE/w9"; mkwaves "$W"; run "$W" --concurrency 1; run "$W" --concurrency 1 --force
echo "$OUT" | grep -q 'wave: .v-run-waves-logs' && no "T9: logs dotdir treated as a wave" || ok "T9: logs dotdir excluded from wave discovery"

# T10 — ND-0716 model pin: spawned `claude --print` sessions read the GLOBAL settings.json
# default when no --model is passed (NOT the invoking session's model) — under a fable[1m]
# operator default that's the "model refuses the /v role → silent no-op" class + premium
# [1m] cost on every prompt. The driver must pin sonnet by default (parity with run-v-packs'
# PACK_MODEL) and route any override through the sonnet-max allowlist.
ARGSLOG="$BASE/args.log"
STUB2="$BASE/claude-stub2"
cat > "$STUB2" <<'STUB2EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB2_ARGSLOG"
exit 0
STUB2EOF
chmod +x "$STUB2"
run2() { : > "$ARGSLOG"; OUT="$(CLAUDE_BIN="$STUB2" STUB2_ARGSLOG="$ARGSLOG" bash "$DRIVER" "$@" 2>&1)"; RC=$?; }

W="$BASE/w10"; rm -rf "$W"; mkdir -p "$W"; printf 'MDL\n' > "$W/01.txt"
run2 "$W" --concurrency 1
grep -q -- '--model sonnet' "$ARGSLOG" && ok "T10: default run pins --model sonnet (never the settings.json session default)" || no "T10: no sonnet pin (argv: $(head -1 "$ARGSLOG" 2>/dev/null))"

run2 "$W" --concurrency 1 --force --model haiku
grep -q -- '--model haiku' "$ARGSLOG" && ok "T10: --model haiku honored" || no "T10: --model haiku not honored (argv: $(head -1 "$ARGSLOG" 2>/dev/null))"

run2 "$W" --concurrency 1 --force --model opus
if [ "$RC" -eq 2 ] && [ ! -s "$ARGSLOG" ]; then
  ok "T10: --model opus rejected before launch (sonnet-max, exit 2)"
else
  no "T10: --model opus not rejected (rc=$RC, launched=$([ -s "$ARGSLOG" ] && echo yes || echo no))"
fi

: > "$ARGSLOG"
OUT="$(CLAUDE_BIN="$STUB2" STUB2_ARGSLOG="$ARGSLOG" V_MODEL_POLICY_OVERRIDE=1 bash "$DRIVER" "$W" --concurrency 1 --force --model opus 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ] && grep -q -- '--model opus' "$ARGSLOG"; } && ok "T10: V_MODEL_POLICY_OVERRIDE=1 lets an explicit opus through (operator lane)" || no "T10: override lane broken (rc=$RC)"

: > "$ARGSLOG"
OUT="$(CLAUDE_BIN="$STUB2" STUB2_ARGSLOG="$ARGSLOG" CLAUDE_FLAGS="--model sonnet" bash "$DRIVER" "$W" --concurrency 1 --force 2>&1)"; RC=$?
_mcount=$(head -1 "$ARGSLOG" 2>/dev/null | grep -o -- '--model' | wc -l | tr -d ' ')
[ "$_mcount" = "1" ] && ok "T10: CLAUDE_FLAGS-supplied --model is not double-added" || no "T10: --model appears ${_mcount}x in argv (expected 1)"

# T11 — --timeout kills a hung session (opt-in; default stays unbounded — T1-T10 never pass --timeout)
STUB3="$BASE/claude-stub3"
cat > "$STUB3" <<'STUB3EOF'
#!/usr/bin/env bash
# stub claude: prompt is "SLEEP<N>" (with --prefix "" so no "/v " is prepended); exec straight into
# `sleep N` so a SIGTERM sent to this process's pid terminates the sleep directly (matches how the
# real claude binary is exec'd in place with no wrapper layer in between).
prompt=""; skip=0
for a in "$@"; do
  if [ "$skip" = "1" ]; then skip=0; continue; fi
  case "$a" in --model) skip=1 ;; --*) ;; *) [ -z "$prompt" ] && prompt="$a";; esac
done
n="${prompt#SLEEP}"
exec sleep "$n"
STUB3EOF
chmod +x "$STUB3"

W="$BASE/w11"; rm -rf "$W"; mkdir -p "$W"
printf 'SLEEP20\n' > "$W/01-hang.txt"
printf 'SLEEP0\n' > "$W/02-fast.txt"
T0=$(date +%s)
OUT="$(CLAUDE_BIN="$STUB3" bash "$DRIVER" "$W" --concurrency 2 --timeout 2 --prefix "" 2>&1)"; RC=$?
T1=$(date +%s); ELAPSED=$((T1-T0))
[ "$RC" -eq 1 ] && ok "T11: a hung session past --timeout makes the run exit 1" || no "T11: rc=$RC (expected 1)"
[ ! -f "$W/01-hang.txt.done" ] && ok "T11: timed-out session has no .done" || no "T11: timed-out session wrongly marked done"
[ -f "$W/02-fast.txt.done" ] && ok "T11: fast sibling still completed" || no "T11: fast sibling did not complete"
# Bound is deliberately tight (not just "well under the 20s hang"): this invocation is wrapped in
# `$(...)` (command substitution == a pipe), which is exactly the context that previously exposed a
# real bug — the watchdog subshell inherited the driver's stdout/stderr, so its own `sleep 5`
# grace-period child (forked before the watchdog got killed) kept that pipe's write end open for 5
# extra seconds after the real work finished (~7s observed instead of ~2s). The watchdog now
# redirects its whole subshell to the log file instead of inheriting the pipe. A regression back to
# the old behavior would push elapsed to ~7s+, which this bound catches; --timeout(2) + normal
# overhead alone should never approach it.
[ "$ELAPSED" -lt 6 ] && ok "T11: --timeout enforced promptly, no pipe-holding regression (elapsed=${ELAPSED}s vs. a 20s hang)" || no "T11: timeout too slow or pipe-holding regression (elapsed=${ELAPSED}s, expected ~2s)"

# T12 — no --timeout (default) never kills a session even if it outlives a would-be short timeout
W="$BASE/w12"; rm -rf "$W"; mkdir -p "$W"; printf 'SLEEP3\n' > "$W/01.txt"
OUT="$(CLAUDE_BIN="$STUB3" bash "$DRIVER" "$W" --concurrency 1 --prefix "" 2>&1)"; RC=$?
{ [ "$RC" -eq 0 ] && [ -f "$W/01.txt.done" ]; } && ok "T12: no --timeout lets a slower session finish normally" || no "T12: rc=$RC done=$([ -f "$W/01.txt.done" ] && echo yes || echo no)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
