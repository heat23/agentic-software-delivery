#!/usr/bin/env bash
# session-start-head-baseline-test.sh
#
# Guards W-BASELINE-UNIVERSAL (2026-08-13): session-start-marker.sh must record HEAD at session
# start, not just a timestamp.
#
# WHY THIS EXISTS. check-review-artifact.sh's CODE_CHANGED component #2 compares
# head-baseline-<sid>.txt against HEAD to catch code landed through the Bash tool —
# track-session-writes.sh inspects Bash only for a v-dispatch-subagent marker, so `git commit` and
# `git merge` are otherwise INVISIBLE to the gate. The W-LIGHT2-CHORE commit-tag escape reads the
# same file. Component #2's own header claims it "runs UNCONDITIONALLY"; before this fix it did
# not, because the only writers were v-bootstrap.sh (runs inside /v — and inside the SUBAGENT when
# /v is dispatched as a background agent, never in the parent) and session-env-check.sh, which is
# NOT registered in settings.json and was deliberately unregistered on 2026-05-16 during a
# session-freeze incident (settings.json.bak-remove-session-env-check-*).
#
# Measured live before the fix: one session had 16 markers in .v/tmp and no head-baseline —
# its pre-flight reported "Files in scope: 0" against a 32-file range and three Bash-landed commits
# were invisible to the Stop gate.
#
# The load-bearing case here is T3, the HOSTILE one: code committed with git alone and ZERO
# Edit/Write calls must become attributable. A test that only checks "a file appeared" would pass
# against a baseline containing garbage.

set -uo pipefail

HOOK="$HOME/.claude/hooks/session-start-marker.sh"
[ -f "$HOOK" ] || { echo "SKIP: $HOOK not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
no()  { FAIL=$((FAIL+1)); echo "  FAIL $1 — expected [$2] got [$3]"; }

TMPROOT=$(mktemp -d 2>/dev/null) || { echo "SKIP: mktemp failed"; exit 0; }
trap 'rm -rf "$TMPROOT" 2>/dev/null || true' EXIT

SID="aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

new_repo() {
  local d="$TMPROOT/$1"
  mkdir -p "$d" && git init -q "$d" 2>/dev/null
  git -C "$d" config user.email t@example.test
  git -C "$d" config user.name  t
  printf 'x\n' > "$d/app.php"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm init >/dev/null 2>&1
  printf '%s' "$d"
}

# Drive the hook the way Claude Code does: SessionStart JSON on stdin.
run_hook() {
  local root="$1"
  ( cd "$root" && printf '{"session_id":"%s"}' "$SID" \
      | V_TMP_DIR="$root/.v/tmp" bash "$HOOK" >/dev/null 2>&1 )
  return 0
}

echo "== W-BASELINE-UNIVERSAL: session-start-marker.sh records HEAD =="

# T1 — the baseline is written, and equals HEAD at session start.
R=$(new_repo t1); run_hook "$R"
BL="$R/.v/tmp/head-baseline-${SID}.txt"
if [ -f "$BL" ]; then ok "T1a baseline file written"; else no "T1a baseline file written" "present" "absent"; fi
GOT=$(head -1 "$BL" 2>/dev/null || true); WANT=$(git -C "$R" rev-parse HEAD 2>/dev/null || true)
if [ -n "$GOT" ] && [ "$GOT" = "$WANT" ]; then ok "T1b baseline == HEAD at session start"
else no "T1b baseline == HEAD at session start" "$WANT" "${GOT:-<empty>}"; fi

# T2 — idempotent: an existing baseline is never overwritten, so the EARLIEST (most accurate)
# value wins and v-bootstrap.sh / a resumed SessionStart cannot move it forward.
R=$(new_repo t2); mkdir -p "$R/.v/tmp"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$R/.v/tmp/head-baseline-${SID}.txt"
run_hook "$R"
GOT=$(head -1 "$R/.v/tmp/head-baseline-${SID}.txt")
if [ "$GOT" = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ]; then ok "T2 pre-existing baseline preserved (idempotent)"
else no "T2 pre-existing baseline preserved" "deadbeef..." "$GOT"; fi

# T3 — HOSTILE, the reason this hook change exists: code landed by git ALONE (no Edit/Write) must
# become attributable, i.e. baseline != HEAD with a non-exempt code file in the range.
R=$(new_repo t3); run_hook "$R"
START=$(head -1 "$R/.v/tmp/head-baseline-${SID}.txt" 2>/dev/null || true)
printf 'malicious\n' >> "$R/app.php"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm "landed via bash" >/dev/null 2>&1
CUR=$(git -C "$R" rev-parse HEAD 2>/dev/null || true)
if [ -n "$START" ] && [ "$START" != "$CUR" ]; then ok "T3a baseline diverges from HEAD after a Bash-only commit"
else no "T3a baseline diverges from HEAD" "different" "same/empty"; fi
# Mirror component #2's own predicate: a changed path that is NOT CODE_EXT_EXEMPT.
CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
HIT=$(git -C "$R" diff --name-only "${START}..${CUR}" 2>/dev/null | grep -vE "$CODE_EXT_EXEMPT" | grep -E '\.php$' | head -1 || true)
if [ -n "$HIT" ]; then ok "T3b component #2 would set CODE_CHANGED=1 (saw $HIT)"
else no "T3b component #2 would set CODE_CHANGED=1" "app.php" "<none>"; fi

# T4 — SELF-SAFETY: the hook's own markers live under .v/ and must be CODE_EXT_EXEMPT, or writing
# them would itself trip the detector it exists to feed.
SELF=$(printf '%s\n' ".v/tmp/head-baseline-${SID}.txt" ".v/tmp/session-start-${SID}.txt" \
       | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
if [ -z "$SELF" ]; then ok "T4 hook's own markers are CODE_EXT_EXEMPT (cannot self-trigger)"
else no "T4 hook's own markers are exempt" "exempt" "$SELF leaked"; fi

# T5 — fail-open: a non-git directory (~/.claude has no repo) must not error or write a bogus SHA.
R="$TMPROOT/t5"; mkdir -p "$R/.v/tmp"
( cd "$R" && printf '{"session_id":"%s"}' "$SID" | V_TMP_DIR="$R/.v/tmp" bash "$HOOK" >/dev/null 2>&1 )
RC=$?
if [ "$RC" -eq 0 ]; then ok "T5a non-git dir exits 0 (fail-open)"; else no "T5a non-git dir exits 0" "0" "$RC"; fi
if [ ! -s "$R/.v/tmp/head-baseline-${SID}.txt" ]; then ok "T5b no bogus baseline written outside a repo"
else no "T5b no bogus baseline outside a repo" "absent/empty" "$(head -1 "$R/.v/tmp/head-baseline-${SID}.txt")"; fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
