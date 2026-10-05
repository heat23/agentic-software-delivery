#!/usr/bin/env bash
# run-v-packs-portability-test.sh — BEHAVIORAL harness for the two R1/R2 claims no other suite exercises:
#
#   1. bash-3.2 PORTABILITY: the script must PARSE under macOS stock /bin/bash 3.2 (a minimal-PATH cron/
#      automation invocation resolves `env bash` there), and the version guard must RE-EXEC a direct
#      3.2 execution onto a bash 4+ (homebrew) — but NEVER re-exec when the file is merely SOURCED
#      (tests source it; a re-exec there would clobber the sourcing shell). Regression: the deferred-arm
#      apostrophe-splice crashed the 3.2 parser at line ~878, and the first guard version fired on source.
#
#   2. SIGTERM REAP: the INT/TERM trap must kill THREE levels — run_pack subshell → claude child → the
#      subagents claude spawned (pgrep -P walk). SIGTERM is the documented stop signal for detached runs
#      (bash pre-ignores SIGINT for async launches — POSIX; the trap cannot override it, so Ctrl-C is
#      interactive-only). This drives a REAL main() with a fake `claude` that forks a grandchild and
#      asserts the grandchild dies after SIGTERM.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "── (1) bash-3.2 portability ──"
if [ -x /bin/bash ] && [ "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')" = 3 ]; then
  if /bin/bash -n "$RUNNER" 2>"$TMP/parse.err"; then
    ok "parses clean under stock /bin/bash 3.2"
  else
    no "3.2 parse regression" "$(head -1 "$TMP/parse.err")"
  fi
  # direct execution under 3.2 must re-exec to a modern bash and still WORK (--dry-run, empty dir → exit 0)
  mkdir -p "$TMP/repo/packs"; git -C "$TMP/repo" init -q 2>/dev/null || true
  o="$(/bin/bash "$RUNNER" --dry-run "$TMP/repo/packs" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$o" | grep -q "no packs found"; then
    ok "direct 3.2 execution re-execs and completes --dry-run (rc=0)"
  else
    no "direct 3.2 execution broken" "rc=$rc: $(printf '%s' "$o" | tail -1)"
  fi
  # SOURCING under 3.2 must NOT re-exec (regression: the first guard version fired on source and broke the
  # sourcing shell). Sourcing may hit 3.2-only runtime limits in unrelated functions, so assert only the
  # guard behavior: the sourcing process must not be replaced (marker line still reached, same PID).
  o="$(/bin/bash -c '. "'"$RUNNER"'" 2>/dev/null; echo "STILL-HERE-$$"' 2>/dev/null)"
  if printf '%s' "$o" | grep -q "STILL-HERE-"; then
    ok "sourcing under 3.2 does NOT re-exec (guard is BASH_SOURCE==\$0 scoped)"
  else
    no "sourcing under 3.2 re-execs or dies" "$(printf '%s' "$o" | tail -1)"
  fi
else
  echo "  SKIP: /bin/bash is not 3.x here — portability leg not applicable"
fi

echo "── (2) SIGTERM reaps claude AND its subagent grandchildren ──"
mkdir -p "$TMP/fakebin" "$TMP/repo2/packs"
git -C "$TMP/repo2" init -q 2>/dev/null || { echo "SKIP: git unavailable"; exit 0; }
# fake claude: records its own pid, forks a "subagent" (sleep) whose pid it also records, then idles
cat > "$TMP/fakebin/claude" <<EOF
#!/usr/bin/env bash
echo \$\$ > "$TMP/claude.pid"
sleep 300 &
echo \$! > "$TMP/subagent.pid"
sleep 300
EOF
chmod +x "$TMP/fakebin/claude"
printf '/v test task\nbody line 2\nbody line 3\n' > "$TMP/repo2/packs/p1.txt"
# _REAP_POLL=1: bash defers trap execution until the current foreground command finishes — the reap loop's
# `sleep ${_REAP_POLL:-20}` means a TERM can take up to one poll interval to act. Shrink it so the test is fast;
# the deferral (≤20s to act on a default run) is inherent bash behavior, not a reaping bug.
PATH="$TMP/fakebin:$PATH" _REAP_POLL=1 "$RUNNER" --serial "$TMP/repo2/packs" >/dev/null 2>&1 &
RPID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/subagent.pid" ] && break; sleep 1; done
if [ ! -s "$TMP/subagent.pid" ]; then
  no "fake claude never launched" "no subagent.pid after 10s"
else
  SUB="$(cat "$TMP/subagent.pid")"; CL="$(cat "$TMP/claude.pid")"
  kill -TERM "$RPID" 2>/dev/null
  sleep 5
  kill -0 "$RPID" 2>/dev/null && { kill -KILL "$RPID" 2>/dev/null; no "runner ignored SIGTERM" "still alive 3s after TERM"; } || ok "runner exits on SIGTERM"
  kill -0 "$CL" 2>/dev/null && { kill -KILL "$CL" 2>/dev/null; no "claude child orphaned after TERM" "pid $CL alive"; } || ok "claude child reaped"
  kill -0 "$SUB" 2>/dev/null && { kill -KILL "$SUB" 2>/dev/null; no "subagent GRANDCHILD orphaned after TERM" "pid $SUB alive — quota keeps burning"; } || ok "subagent grandchild reaped (3-level kill)"
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
