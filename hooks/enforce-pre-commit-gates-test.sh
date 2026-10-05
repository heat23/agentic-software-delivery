#!/usr/bin/env bash
# enforce-pre-commit-gates-test.sh — behavioral + mutation coverage for the HOOK-2 CRITICAL block
# (audit 2026-06-18). enforce-pre-commit-gates.sh must DENY a `git commit` of staged code when the
# session's PRE_FLIGHT_REPORT contains a FAILED gate row. The original incident (HOOK-2): the v4 regex
# missed the W12-3 `| FAIL | <Gate> |` status-first table format, so commits with failing pre-flight
# gates were SILENTLY ALLOWED. precommit-accept-all (mutation-gate) only proves the hook isn't a no-op
# at the TOP; this harness isolates the FAIL-detection branch specifically so a regression that neuters
# JUST that check (FAILED pre-flight slips through to the AGENT_REVIEW stage) is caught.
#
# V_PRECOMMIT_OVERRIDE (mutation-gate seam): the gate injects a mutant copy of the hook here;
# HOOKS_LIB_DIR is exported to the real lib so the relocated copy loads its libs. Default → live hook.
# Self-contained; isolated temp repo. Re-run: env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

REAL_HOME="$HOME"
PRECOMMIT="${V_PRECOMMIT_OVERRIDE:-$REAL_HOME/.claude/hooks/enforce-pre-commit-gates.sh}"
[ -f "$PRECOMMIT" ] || { echo "SKIP: missing $PRECOMMIT"; exit 0; }
export HOOKS_LIB_DIR="$REAL_HOME/.claude/hooks/lib"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — got: $2"; }

SID="abcd1234-0000-0000-0000-000000000001"
BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo x > a.php && git add a.php && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
# Stage a code change so STAGED_CODE is non-empty (the gate only runs for staged code).
( cd "$R" && printf 'v2\n' >> a.php && git add a.php ) >/dev/null 2>&1

fire(){ # $1 = command
  ( cd "$R" && printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"session_id":"%s"}' "$1" "$SID" \
      | CLAUDE_SESSION_ID="$SID" bash "$PRECOMMIT" 2>&1 )
}

echo "== enforce-pre-commit-gates :: HOOK-2 FAILED-gate block =="

# Case 1 (the bite): PRE_FLIGHT with a W12-3 status-first FAILED gate row must BLOCK with 'FAILED gates'.
# (Structurally valid: >=100 bytes + Model:/## Gates markers; left UNSTAGED so W5F-10 doesn't pre-empt.)
printf 'Model: haiku\n## Gates\n| Status | Gate |\n| FAIL | tests |\nSynthetic pre-flight report body padding to comfortably clear the 100-byte structural-validation minimum.\n' > "$R/PRE_FLIGHT_REPORT_${SID}.md"
OUT="$(fire 'git commit -m x')"
if printf '%s' "$OUT" | grep -q "FAILED gates"; then
  ok "FAILED pre-flight gate -> commit BLOCKED (HOOK-2)"
else
  no "FAILED pre-flight gate was NOT blocked at the FAIL-detection branch" "$OUT"
fi

# Case 2 (no-false-positive control): an all-PASS PRE_FLIGHT must NOT trip the FAIL block — the gate
# proceeds past it (it will then deny for the missing AGENT_REVIEW, but NEVER with 'FAILED gates').
printf 'Model: haiku\n## Gates\n| Status | Gate |\n| PASS | tests |\nSynthetic pre-flight report body padding to comfortably clear the 100-byte structural-validation minimum.\n' > "$R/PRE_FLIGHT_REPORT_${SID}.md"
OUT2="$(fire 'git commit -m x')"
if printf '%s' "$OUT2" | grep -q "FAILED gates"; then
  no "all-PASS pre-flight false-tripped the FAILED-gates block" "$OUT2"
else
  ok "all-PASS pre-flight -> FAIL block does NOT fire (no false positive)"
fi

# Case 3 (ND-0716): `status: failed_non_blocking` is explicitly NON-blocking per
# references/gate-schema.md ("No (warns only)") — the old substring regex `status:\s*fail`
# matched it and false-blocked the commit on an advisory-only gate result.
printf 'Model: haiku\n## Gates\nstatus: pass\nstatus: failed_non_blocking\nSynthetic pre-flight report body padding to comfortably clear the 100-byte structural-validation minimum.\nOverall Status: PASS\n' > "$R/PRE_FLIGHT_REPORT_${SID}.md"
OUT3="$(fire 'git commit -m x')"
if printf '%s' "$OUT3" | grep -q "FAILED gates"; then
  no "failed_non_blocking (advisory-only) false-tripped the FAILED-gates block" "$OUT3"
else
  ok "failed_non_blocking -> FAIL block does NOT fire (advisory-only status respected)"
fi

# Case 4 (boundary control): bare `status: fail` and legacy `status: failed` must STILL block.
for _s in "status: fail" "status: failed"; do
  printf 'Model: haiku\n## Gates\n%s\nSynthetic pre-flight report body padding to comfortably clear the 100-byte structural-validation minimum.\n' "$_s" > "$R/PRE_FLIGHT_REPORT_${SID}.md"
  OUT4="$(fire 'git commit -m x')"
  if printf '%s' "$OUT4" | grep -q "FAILED gates"; then
    ok "'$_s' still BLOCKS (boundary did not under-match)"
  else
    no "'$_s' no longer blocks after boundary fix" "$OUT4"
  fi
done

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
