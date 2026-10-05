#!/usr/bin/env bash
# v-dispatch-subagent-stdin-test.sh — RED/GREEN for the _run_bounded background-stdin fix.
#
# BUG (macOS / no timeout|gtimeout → PATH C): `_run_bounded` backgrounded the child with a bare
# `"$@" &`. bash redirects a background job's stdin to /dev/null unless explicitly redirected, so
# the caller's `claude "${ARGS[@]}" < "$PROMPT_TMP"` never reached `claude -p`, which errored
# "Input must be provided either through stdin or as a prompt argument when using --print" — making
# EVERY subprocess dispatch (pre-flight/verify-done/QA/reviewers) fail and silently fall back to
# orchestrator-inline (observed in production sessions).
# FIX: `"$@" <&0 &` — an explicit redirection that defeats the /dev/null default.
#
# This test extracts _run_bounded from the FIXED script and the pre-fix BACKUP, forces PATH C by
# restricting PATH to a fakebin (so `command -v timeout|gtimeout` both fail), and checks whether a
# piped prompt reaches the backgrounded child. GREEN: fixed propagates stdin. RED: backup loses it.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CURRENT="$HERE/v-dispatch-subagent.sh"
BACKUP="$HERE/v-dispatch-subagent.sh.pre-stdin-fix-bak"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# fakebin with ONLY cat + sleep → command -v timeout/gtimeout fail → _run_bounded takes PATH C
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
for b in cat sleep; do ln -s "$(command -v "$b")" "$FAKEBIN/$b" 2>/dev/null; done

extract_fn(){ awk '/^_run_bounded\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$1"; }

probe(){ # $1 = script path → echoes what the backgrounded child saw on stdin
  local src="$WORK/fn.sh"; extract_fn "$1" > "$src"
  printf 'STDIN_REACHED_CHILD' > "$WORK/in.txt"
  # bash is located via the inherited PATH; we restrict PATH to the fakebin INSIDE the shell
  # (after bash is running) so `command -v timeout|gtimeout` fail → PATH C, while cat/sleep resolve.
  bash -c '
    set -u
    export PATH="'"$FAKEBIN"'"
    source "$1"
    _run_bounded 5 cat < "$2"
  ' _ "$src" "$WORK/in.txt" 2>/dev/null
}

echo "== _run_bounded :: background-stdin propagation (PATH C) =="

# The pre-fix BACKUP is an optional RED-proving fixture: it isn't retained on every machine (these
# .pre-*-bak files get cleaned up). When it's absent we can still fully verify the LIVE code (the GREEN
# half + the static fix idiom); only the RED repro is unprovable. So SKIP the BACKUP-dependent halves
# rather than FAILing for a non-reason (audit 2026-06-18 determinism fix — same class as the existing
# 'SKIP: jq unavailable' guards; do NOT weaken the GREEN checks).
HAVE_BACKUP=0
if [ -f "$BACKUP" ]; then HAVE_BACKUP=1; fi

# sanity: the FIXED version must define the function we extracted (always checked)
[ -n "$(extract_fn "$CURRENT")" ] && ok "extracted _run_bounded from FIXED" || no "could not extract _run_bounded from FIXED"
if [ "$HAVE_BACKUP" -eq 1 ]; then
  [ -n "$(extract_fn "$BACKUP")" ]  && ok "extracted _run_bounded from BACKUP" || no "could not extract _run_bounded from BACKUP"
else
  echo "  -- SKIP: pre-stdin-fix backup absent ($BACKUP) — RED repro unprovable; GREEN checks still run"
fi

out_fixed="$(probe "$CURRENT")"
[ "$out_fixed" = "STDIN_REACHED_CHILD" ] \
  && ok "FIXED: piped stdin reaches the backgrounded child (GREEN)" \
  || no "FIXED: child got '$out_fixed' (expected STDIN_REACHED_CHILD)"

if [ "$HAVE_BACKUP" -eq 1 ]; then
  out_backup="$(probe "$BACKUP")"
  [ "$out_backup" != "STDIN_REACHED_CHILD" ] \
    && ok "BACKUP: bare '\"\$@\" &' loses stdin to /dev/null (RED as expected; got '$out_backup')" \
    || no "BACKUP unexpectedly propagated stdin — the bug repro is invalid"
fi

# static: the fix idiom is present in the live script (always checked); the backup-absent idiom is
# only asserted when the backup exists.
grep -qE '"\$@" <&0 &' "$CURRENT" && ok "FIXED contains the '<&0' redirect" || no "FIXED missing the '<&0' redirect"
if [ "$HAVE_BACKUP" -eq 1 ]; then
  grep -qE '"\$@" <&0 &' "$BACKUP" && no "BACKUP already had '<&0' (bad backup)" || ok "BACKUP lacked '<&0' (confirms fix added it)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
