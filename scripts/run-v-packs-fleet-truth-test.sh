#!/usr/bin/env bash
# run-v-packs-fleet-truth-test.sh — BITE for the 2026-07-02 wave-4 forensic fixes (fleet truthfulness):
#
#   T4-F2  model pin: every pack session launches with an explicit --model (default sonnet) instead of
#          inheriting the user's INTERACTIVE default — a live specimen: an inherited Fable default
#          left the /v parent loop at 0 turns while the fork spent its full budget and both deliverables were
#          written but never verify-done'd/committed/attested. `--model inherit` restores old behavior.
#   T4-F3  fork-work triage: a num_turns==0 result whose modelUsage shows substantial output tokens is
#          triaged "FORK DID REAL WORK" (deliverables may be on disk), NOT "headless /v STALLED on a
#          Monitor notification" — the old invariant ("tree changes always spend main-loop turns") was
#          disproven live.
#   T4-F4  final line: with parked packs present, the runner must not print "nothing left to do".
#   T4-F1  wave-order warning: invoking from INSIDE wave-N/ while a lower wave still has queued packs
#          next to it prints a loud WAVE ORDER warning (observed: a GO/NO-GO verification wave silently
#          ran before its dependency wave).
#   T4-F6  sid_of falls back to per-JSONL-line parsing for result-less (killed) logs so their sessions
#          get telemetry-logged.
#   T4-RD  v-stop-readiness.sh reports a present-but-malformed artifact as INVALID (fix the field), not
#          ABSENT (regenerate) — the validator prints `FAIL`, the old grep looked for `invalid`.
#
# Red oracle: RUNNER_OVERRIDE / READINESS_OVERRIDE at the pre-fix copies → must FAIL.
set -uo pipefail
RUNNER="${RUNNER_OVERRIDE:-$HOME/.local/bin/run-v-packs}"
READINESS="${READINESS_OVERRIDE:-$HOME/.claude/skills/v/references/v-stop-readiness.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "── result: 0 passed, 0 failed (skipped) ──"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq";  echo "── result: 0 passed, 0 failed (skipped) ──"; exit 0; }
[ -f "$RUNNER" ] || { echo "FATAL: runner missing at $RUNNER"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP" 2>/dev/null' EXIT
export FAKE_ARGS_FILE="$TMP/claude-args.txt"

# fake claude: records its argv (one per line), emits per FAKE_CLAUDE_RESULT:
#   attest (default) — clean attested result;  zero — success result with num_turns=0, tiny usage
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${FAKE_ARGS_FILE:-/dev/null}" 2>/dev/null
sid="none"; prev=""
for a in "$@"; do [ "$prev" = "--session-id" ] && sid="$a"; prev="$a"; done
case "${FAKE_CLAUDE_RESULT:-attest}" in
  zero)
    printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s","modelUsage":{"claude-sonnet-5":{"outputTokens":12}}}\n' "$sid" ;;
  *)
    printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"session_id":"%s"}\nGAUNTLET_ATTESTED: yes\n' "$sid" ;;
esac
EOF
chmod +x "$TMP/fakebin/claude"
export PATH="$TMP/fakebin:$PATH"
# disable every end-of-run side quest so subprocess runs are hermetic + fast
# V_PACK_DONE_RENAME=0 (2026-07-12): the T4-F2 fixture re-seeds packs/a.txt between three subprocess runs;
# the done-rename feature (2026-07-11) renames packs/ -> DONE-packs/ on run 1's clean exit, so the re-seed
# wrote into a vanished dir and both later --model subtests false-failed. Rename behavior has its own
# dedicated fixture (run-v-packs-done-rename-test.sh); keep it out of this one.
export V_PACK_DRAIN=0 V_PACK_BACKFILL_CHECK=0 V_PACK_BRANCH_GC=0 V_PACK_TELEMETRY=0 V_PACK_RECONCILE_PROOF=0 V_PACK_SETTLE_SEC=0 V_PACK_DONE_RENAME=0

mkrepo(){ # $1=dir — init a git repo with a packs/ subdir
  mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
}

echo "== T4-F2: pack sessions launch with a PINNED --model (default sonnet; overridable; inherit = unpinned) =="
R1="$TMP/r1"; mkrepo "$R1"; mkdir -p "$R1/packs"; printf '/v do the thing\n\nbody\n' > "$R1/packs/a.txt"
FAKE_CLAUDE_RESULT=attest PACK_TIMEOUT=60 bash "$RUNNER" "$R1/packs" --once -j1 > "$TMP/out1.txt" 2>&1
OUT1="$(cat "$TMP/out1.txt")"
grep -qE -- '--model$|^--model$' "$FAKE_ARGS_FILE" || grep -q -- '--model' "$FAKE_ARGS_FILE" \
  && grep -A1 -- '--model' "$FAKE_ARGS_FILE" | grep -q 'sonnet' \
  && ok "default launch passes --model sonnet to claude" || no "no default model pin in launch args" "$(cat "$FAKE_ARGS_FILE" 2>/dev/null | head -12 | tr '\n' ' ')"
printf '%s\n' "$OUT1" | grep -q 'model=sonnet' && ok "startup line reports model=sonnet" || no "startup line lacks model=" "$(printf '%s\n' "$OUT1" | head -1)"
printf '/v do the thing\n\nbody\n' > "$R1/packs/a.txt"   # re-queue (was archived)
FAKE_CLAUDE_RESULT=attest PACK_TIMEOUT=60 bash "$RUNNER" "$R1/packs" --once -j1 --model haiku > "$TMP/out1b.txt" 2>&1
grep -A1 -- '--model' "$FAKE_ARGS_FILE" | grep -q 'haiku' && ok "--model haiku overrides the default" || no "--model override ignored" "$(head -12 "$FAKE_ARGS_FILE" | tr '\n' ' ')"
printf '/v do the thing\n\nbody\n' > "$R1/packs/a.txt"
FAKE_CLAUDE_RESULT=attest PACK_TIMEOUT=60 bash "$RUNNER" "$R1/packs" --once -j1 --model inherit > "$TMP/out1c.txt" 2>&1
grep -q -- '--model' "$FAKE_ARGS_FILE" && no "--model inherit still pinned a model" "$(head -12 "$FAKE_ARGS_FILE" | tr '\n' ' ')" || ok "--model inherit launches un-pinned (legacy behavior preserved)"
# CODEX-003: a flag-like --model value must die loudly, not silently eat the NEXT flag
bash "$RUNNER" --model --timeout 120 "$R1/packs" > "$TMP/out1d.txt" 2>&1
rc1d=$?
[ "$rc1d" -ne 0 ] && grep -q 'bad --model' "$TMP/out1d.txt" && ok "CODEX-003: '--model --timeout' dies with a clear message (nothing swallowed)" || no "CODEX-003: flag-like model value accepted (rc=$rc1d)" "$(head -2 "$TMP/out1d.txt")"

echo "== T4-F3: fork-work triage — big modelUsage output at num_turns==0 is NOT 'STALLED' =="
# shellcheck disable=SC1090
source "$RUNNER" 2>/dev/null
[ "$(type -t _inconclusive_kind)" = function ] || { no "_inconclusive_kind missing after sourcing runner"; echo "── result: $PASS passed, $((FAIL)) failed ──"; exit 1; }
LOG_DIR="$TMP/logs"; mkdir -p "$LOG_DIR"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","modelUsage":{"claude-sonnet-5":{"outputTokens":46227},"claude-haiku-4-5":{"outputTokens":900}}}\n' > "$LOG_DIR/fw.log"
[ "$(_result_out_tokens fw)" = 47127 ] && ok "_result_out_tokens sums across models (47127)" || no "_result_out_tokens wrong" "$(_result_out_tokens fw)"
[ "$(_inconclusive_kind fw)" = fork-work ] && ok "0 turns + 46K output tokens → fork-work (not stalled)" || no "fork-work kind" "$(_inconclusive_kind fw)"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","modelUsage":{"claude-sonnet-5":{"outputTokens":12}}}\n' > "$LOG_DIR/st.log"
[ "$(_inconclusive_kind st)" = stalled ] && ok "0 turns + trivial tokens → stalled (unchanged)" || no "stalled kind" "$(_inconclusive_kind st)"
# R3: the PASS token lives in the terminal result's .result text — _inconclusive_kind now scopes its greps
# there (same hay rule as verdict()), so echoed PROMPT text can no longer dress a stalled park up as
# "completed". The old bare-line fixture form was exactly the echo shape the scoping must now IGNORE.
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","result":"V-COMPLETION-SELFCHECK: PASS — merge deferred","modelUsage":{"claude-sonnet-5":{"outputTokens":46227}}}\n' > "$LOG_DIR/cp.log"
[ "$(_inconclusive_kind cp)" = completed ] && ok "self-check PASS (in result text) outranks fork-work (ordering preserved)" || no "completed ordering" "$(_inconclusive_kind cp)"
printf '{"type":"user","message":"prompt quoting V-COMPLETION-SELFCHECK: PASS"}\n{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","result":"waited on Monitor","modelUsage":{"claude-sonnet-5":{"outputTokens":12}}}\n' > "$LOG_DIR/cpe.log"
[ "$(_inconclusive_kind cpe)" = stalled ] && ok "echoed PASS in a prompt event does NOT read as completed (hay-scoped)" || no "echo-spoof guard" "$(_inconclusive_kind cpe)"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x"}\n' > "$LOG_DIR/nm.log"
[ "$(_result_out_tokens nm)" = 0 ] && ok "missing modelUsage → 0 tokens (safe default)" || no "missing-usage default" "$(_result_out_tokens nm)"
# CODEX-001: STRING-typed outputTokens must be IGNORED, never string-concatenated into a bogus number
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","modelUsage":{"a":{"outputTokens":"1"},"b":{"outputTokens":"999"}}}\n' > "$LOG_DIR/str.log"
[ "$(_result_out_tokens str)" = 0 ] && ok "CODEX-001: all-string outputTokens → 0 (not concatenated '1999')" || no "CODEX-001: string tokens mis-summed" "$(_result_out_tokens str)"
[ "$(_inconclusive_kind str)" = stalled ] && ok "CODEX-001: string-token log cannot fake fork-work" || no "CODEX-001 kind" "$(_inconclusive_kind str)"
# CODEX-002: a pack PROMPT echoed into the log containing already-done phrasing must NOT suppress fork-work
printf '{"type":"user","message":"if the fix is already implemented, say so and stop","session_id":"x"}\n{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"x","modelUsage":{"claude-sonnet-5":{"outputTokens":46227}}}\n' > "$LOG_DIR/pe.log"
[ "$(_inconclusive_kind pe)" = fork-work ] && ok "CODEX-002: prompt boilerplate cannot mask the structural fork-work signal" || no "CODEX-002: already-done prose outranked token evidence" "$(_inconclusive_kind pe)"
# 2026-07-04: the inconclusive-park disposal (including the _inconclusive_kind consumption + the FORK DID
# REAL WORK message) was factored out of run_pass_wave into the shared _archive_finished_pack (so crash-
# recovery orphan adoption can reuse the SAME disposal decision) — run_pass_wave now WIRES to it via the
# verdict-name case arm instead of inlining the triage itself. Check the actual call-chain: run_pass_wave
# must dispatch to the helper, and the helper must still consume _inconclusive_kind / carry the message.
rw="$(declare -f run_pass_wave 2>/dev/null)"
af="$(declare -f _archive_finished_pack 2>/dev/null)"
printf '%s\n' "$rw" | grep -q '_archive_finished_pack' && ok "run_pass_wave wires inconclusive/timeout/done/noop disposal to _archive_finished_pack" || no "triage not wired to helper"
printf '%s\n' "$af" | grep -q '_inconclusive_kind' && ok "run_pass_wave triage consumes _inconclusive_kind (via _archive_finished_pack)" || no "triage not wired to helper"
printf '%s\n' "$af" | grep -q 'FORK DID REAL WORK' && ok "fork-work park message wired" || no "fork-work message missing"

echo "== T4-F6: sid_of falls back to structural JSONL parse on a result-less (killed) log =="
printf '{"type":"system","subtype":"task_started","session_id":"abcd1234-1111-4222-8333-444455556666"}\n' > "$LOG_DIR/killed.log"
[ "$(sid_of killed)" = "abcd1234-1111-4222-8333-444455556666" ] && ok "result-less log resolves sid from event lines" || no "sid_of fallback" "'$(sid_of killed)'"
printf '{"type":"system","session_id":"abcd1234-1111-4222-8333-444455556666"}\n{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"eeee1234-1111-4222-8333-444455556666"}\n' > "$LOG_DIR/both.log"
[ "$(sid_of both)" = "eeee1234-1111-4222-8333-444455556666" ] && ok "result-line sid still wins when present" || no "result-sid precedence" "'$(sid_of both)'"

echo "== T4-F4 behavioral: parked pack ⇒ final line must NOT claim 'nothing left to do' =="
R2="$TMP/r2"; mkrepo "$R2"; mkdir -p "$R2/packs"; printf '/v park me\n\nbody\n' > "$R2/packs/z.txt"
FAKE_CLAUDE_RESULT=zero PACK_TIMEOUT=60 bash "$RUNNER" "$R2/packs" --once -j1 > "$TMP/out2.txt" 2>&1
OUT2="$(cat "$TMP/out2.txt")"
printf '%s\n' "$OUT2" | grep -q 'nothing left to do' && no "printed 'nothing left to do' over a parked pack" "$(printf '%s\n' "$OUT2" | tail -3)" \
  || ok "no false 'nothing left to do' with a parked pack"
printf '%s\n' "$OUT2" | grep -q 'await your review' && ok "final line names the parked packs as open work" || no "final line lacks the parked-pack callout" "$(printf '%s\n' "$OUT2" | tail -2)"
printf '%s\n' "$OUT2" | grep -q 'STALLED' && ok "trivial-usage 0-turn park still reads STALLED (triage not blunted)" || no "stalled message lost" "$(printf '%s\n' "$OUT2" | grep INCONCLUSIVE)"

echo "== T4-F1 behavioral: running wave-2 subdir while wave-1 is queued warns; lowest wave does not =="
R3="$TMP/r3"; mkrepo "$R3"; mkdir -p "$R3/vp/wave-1" "$R3/vp/wave-2"
printf '/v first wave task\n\nbody\n' > "$R3/vp/wave-1/p1.txt"
printf '/v second wave task\n\nbody\n' > "$R3/vp/wave-2/p2.txt"
FAKE_CLAUDE_RESULT=attest PACK_TIMEOUT=60 bash "$RUNNER" "$R3/vp/wave-2" --once -j1 > "$TMP/out3.txt" 2>&1
OUT3="$(cat "$TMP/out3.txt")"
printf '%s\n' "$OUT3" | grep -q 'WAVE ORDER' && ok "wave-2-with-queued-wave-1 prints the WAVE ORDER warning" || no "no wave-order warning" "$(printf '%s\n' "$OUT3" | head -4)"
printf '/v second wave task\n\nbody\n' > "$R3/vp/wave-2/p2.txt"   # re-queue for the control run
FAKE_CLAUDE_RESULT=attest PACK_TIMEOUT=60 bash "$RUNNER" "$R3/vp/wave-1" --once -j1 > "$TMP/out4.txt" 2>&1
OUT4="$(cat "$TMP/out4.txt")"
printf '%s\n' "$OUT4" | grep -q 'WAVE ORDER' && no "lowest wave falsely warned" "$(printf '%s\n' "$OUT4" | head -4)" || ok "lowest-wave run stays silent (no false warning)"

echo "== T4-RD behavioral (CODEX-005): readiness classifies from the validator's STATUS COLUMN =="
# Run a COPY of the real readiness script with a stub v-artifact-validate-all.sh beside it (readiness
# resolves the validator via its own dir), so we test the actual printed classification, not source text.
[ -f "$READINESS" ] || no "readiness script missing at $READINESS"
RD="$TMP/rd"; mkdir -p "$RD"; cp "$READINESS" "$RD/v-stop-readiness.sh"
cat > "$RD/v-artifact-validate-all.sh" <<'EOF'
#!/usr/bin/env bash
echo "── v-artifact-validate-all: stub ──"
echo "  FAIL    PRE_FLIGHT_REPORT    "
echo "          ↳ pre-flight: missing 'Mode:' line"
echo "  ok      AGENT_REVIEW          (AGENT_REVIEW_my-fail-test.md)"
echo "  absent  VERIFY_DONE_REPORT   "
echo "  absent  IMPACT_MAP           "
echo "  absent  QA_REPORT            "
EOF
chmod +x "$RD/v-artifact-validate-all.sh"
R4="$TMP/r4"; mkrepo "$R4"
RDOUT="$(cd "$R4" && bash "$RD/v-stop-readiness.sh" "my-fail-test" "$R4" 2>&1 || true)"
printf '%s\n' "$RDOUT" | grep -q 'PRE_FLIGHT_REPORT is INVALID' && ok "FAIL-status artifact reported INVALID (fix-the-field), not ABSENT" || no "FAIL artifact not classified INVALID" "$(printf '%s\n' "$RDOUT" | head -6)"
printf '%s\n' "$RDOUT" | grep -q 'PRE_FLIGHT_REPORT is ABSENT' && no "FAIL artifact still misreported ABSENT (regenerate advice)" "$(printf '%s\n' "$RDOUT" | head -6)" || ok "no ABSENT misreport for a present-but-malformed artifact"
printf '%s\n' "$RDOUT" | grep -qE 'AGENT_REVIEW valid' && ok "CODEX-004: 'fail' inside a FILENAME does not false-INVALID an ok artifact" || no "ok artifact with 'fail' in filename misclassified" "$(printf '%s\n' "$RDOUT" | grep AGENT_REVIEW)"

echo ""
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
