#!/usr/bin/env bash
# run-v-packs-orchestrator-contract-test.sh — PARITY GUARD for the run-v-packs ↔ /v orchestrator contract.
#
# WHY THIS EXISTS (the contract-drift CLASS):
#   `run-v-packs` is fire-and-forget: it drives headless /v sessions and decides a pack's fate by GREPPING the
#   session log for tokens the ORCHESTRATOR emits. If either side's literal drifts, NOTHING errors — run-v-packs
#   silently mis-classifies and EITHER loops a finished pack forever OR archives an unfinished one. The existing
#   run-v-packs-test.sh pins run-v-packs' READ side against hardcoded fixture strings, so a /v rename of an emitted
#   token leaves it green while real packs break. This guard pins BOTH sides: it feeds each EMITTER's *actual*
#   token through run-v-packs' *real* verdict(), so a drift on either side turns this red on the next sweep.
#
# THE CONTRACT (3 emitter tokens + 1 inferred verdict; keep this comment in sync if a 5th is added):
#   1. done   ← v-gauntlet-attest.sh emits `GAUNTLET_ATTESTED`         ← run-v-packs verdict() greps it  → archive
#   2. noop   ← v-completion-selfcheck.sh emits `V-COMPLETION-SELFCHECK: PASS` + an already-done phrase      → archive
#   3. no-task← /v (SKILL.md) emits `no task content`                  ← run-v-packs greps it → KEEP + re-run
#   4. inconclusive ← NO emitter token; verdict() INFERS "the session did nothing" from num_turns==0 + a clean
#      exit with none of the above → PARK to .needs-review/ (NOT re-run, NOT archived). Covers the two non-
#      retryable dead-ends: an already-done 0-file fix whose self-check emits FAIL (no artifacts), and a headless
#      /v that stalls on an interactive wait. Distinct from `partial` (real work, num_turns>0 → keeps retrying).
#   5. timeout ← NO emitter token; a per-pack watchdog kills a session still alive past PACK_TIMEOUT (wedged) and
#      drops a race-free `<log>.timedout` SIDECAR verdict() keys off → PARK to .needs-review/. This is what stops a
#      stuck session (failed subagent dispatch / rate-limit stall) from holding its parallel slot forever.
set -uo pipefail

RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
VREF="${VREF:-$HOME/.claude/skills/v/references}"
ATTEST="${ATTEST:-$VREF/v-gauntlet-attest.sh}"
SELFCHECK="${SELFCHECK:-$VREF/v-completion-selfcheck.sh}"
SKILL="${SKILL:-$HOME/.claude/skills/v/SKILL.md}"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

for f in "$RUNNER" "$ATTEST" "$SELFCHECK" "$SKILL"; do
  [ -f "$f" ] || { echo "FATAL: contract participant missing: $f"; exit 2; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q 2>/dev/null || true

# Source run-v-packs to get the REAL verdict() (main is sourcing-guarded; same entry as run-v-packs-test.sh).
# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t verdict)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose verdict() (main guard broke)"; exit 1; }

LOG_DIR="$TMP"   # verdict() reads "$LOG_DIR/<name>.log"
mklog(){ printf '{"type":"result","subtype":"success","is_error":false,"result":%s}\n' "$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" >"$LOG_DIR/$1.log"; }

echo "── 1. done-trigger parity: GAUNTLET_ATTESTED (emit ⇄ read ⇄ archive) ──"
# EMIT side present (the deterministic emitter still prints the literal token)
grep -qE 'GAUNTLET_ATTESTED' "$ATTEST" \
  && ok "v-gauntlet-attest.sh emits the GAUNTLET_ATTESTED token" \
  || no "v-gauntlet-attest.sh NO LONGER emits GAUNTLET_ATTESTED" "run-v-packs will never archive an attested pack → infinite re-run"
# READ side present (run-v-packs verdict() greps the same literal). MODULARIZATION (2026-07-04): verdict()
# lives in run-v-packs-lib/30-verdict.sh — assert over the runner's transitive source (runner + libs), not
# just the entry file (a comment mentioning the token in the runner must not stand in for the real grep).
grep -qE "GAUNTLET_ATTESTED" "$RUNNER" "${RUNNER}-lib"/*.sh 2>/dev/null \
  && ok "run-v-packs greps the GAUNTLET_ATTESTED token" \
  || no "run-v-packs verdict() dropped the GAUNTLET_ATTESTED grep" "attested packs would be mis-classified"
# FUNCTIONAL parity: the emitter's real success line, through the real verdict(), classifies done
mklog gatt "the gauntlet completed — GAUNTLET_ATTESTED: yes"
v="$(verdict gatt)"; [ "$v" = done ] && ok "verdict(GAUNTLET_ATTESTED line) = done" || no "verdict drift on GAUNTLET_ATTESTED" "got '$v', expected 'done'"

echo "── 2. noop-archive parity: V-COMPLETION-SELFCHECK: PASS + already-done phrase ──"
grep -qE 'V-COMPLETION-SELFCHECK: PASS' "$SELFCHECK" \
  && ok "v-completion-selfcheck.sh emits the SELFCHECK PASS token" \
  || no "v-completion-selfcheck.sh NO LONGER emits 'V-COMPLETION-SELFCHECK: PASS'" "no-op packs would never archive"
# CRITICAL coupling: run-v-packs only archives a SELFCHECK:PASS that ALSO carries an already-done phrase (else it
# treats it as fresh work → partial → re-run, to avoid archiving unfinished work). Pin that the selfcheck's no-op
# PASS emission still carries such a phrase on the SAME line.
_DONEPHRASE='already (done|implemented|committed|present|in place)|non-code completion|TRIVIAL_PASS|no code (was )?change|nothing (left )?to (do|implement|change|fix)'
if grep -E 'V-COMPLETION-SELFCHECK: PASS' "$SELFCHECK" | grep -qiE "$_DONEPHRASE"; then
  ok "selfcheck's no-op PASS emission carries a run-v-packs-recognized already-done phrase"
else
  no "selfcheck PASS no longer carries an already-done phrase run-v-packs recognizes" "no-op packs would loop (verdict=partial, never archived)"
fi
# FUNCTIONAL parity (no-op PASS → noop) and the GUARD (fresh PASS without a done-phrase must NOT archive)
mklog spass "V-COMPLETION-SELFCHECK: PASS — non-code completion (meta-repo)"
v="$(verdict spass)"; [ "$v" = noop ] && ok "verdict(no-op SELFCHECK PASS) = noop (archives)" || no "verdict drift on SELFCHECK noop" "got '$v', expected 'noop'"
mklog sfresh "V-COMPLETION-SELFCHECK: PASS. freshly implemented the feature now."
v="$(verdict sfresh)"; [ "$v" = partial ] && ok "verdict(fresh PASS, no done-phrase) = partial (re-runs, won't archive fresh work)" || no "fresh-work guard drift" "got '$v', expected 'partial'"

echo "── 3. no-task parity: the re-run/never-archive signal ──"
# EMIT side: the canonical /v phrasing for an empty task-capture lives in SKILL.md.
grep -qE 'no task content' "$SKILL" \
  && ok "SKILL.md emits the canonical 'no task content' phrasing" \
  || no "SKILL.md's no-task phrasing changed away from 'no task content'" "run-v-packs may mis-classify an empty-task boot as partial → wrongly archived"
# FUNCTIONAL parity: that phrasing, through verdict(), is no-task (KEPT, re-run — never archived)
mklog nt "Per the user's /v invocation with no task content, I will not fabricate a task."
v="$(verdict nt)"; [ "$v" = no-task ] && ok "verdict('no task content' line) = no-task (kept for re-run)" || no "verdict drift on no-task" "got '$v', expected 'no-task'"

echo "── 4. inconclusive (did-nothing) parity: num_turns==0 + no terminal token → PARK, never loop ──"
# READ side: verdict() must consult num_turns to tell a did-nothing session (park) from a real half-done partial.
# (Transitive-source scope — verdict() lives in run-v-packs-lib/30-verdict.sh since the 2026-07-04 modularization.)
grep -qE 'num_turns' "$RUNNER" "${RUNNER}-lib"/*.sh 2>/dev/null \
  && ok "run-v-packs verdict() consults num_turns (distinguishes did-nothing from partial)" \
  || no "run-v-packs verdict() no longer reads num_turns" "a 0-turn already-done/stalled pack would loop forever as partial"
# result JSON WITH num_turns (the base mklog omits it — a missing num_turns must default to partial, not park).
mklogt(){ printf '{"type":"result","subtype":"success","is_error":false,"num_turns":%s,"result":%s}\n' "$2" "$(printf '%s' "$3" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" >"$LOG_DIR/$1.log"; }
# (a) already-done, 0 turns, no attest/PASS token → inconclusive (parked, quota saved)
mklogt i_done 0 "0 files changed — already fully implemented and committed in a prior session"
v="$(verdict i_done)"; [ "$v" = inconclusive ] && ok "verdict(0-turn already-done, no token) = inconclusive (parked)" || no "verdict drift: already-done 0-turn" "got '$v', expected 'inconclusive'"
# (b) 0-file no-op whose self-check emitted FAIL (missing artifacts) — FAIL is NOT the PASS noop → inconclusive
mklogt i_fail 0 "V-COMPLETION-SELFCHECK: FAIL — missing gauntlet artifacts (0-file no-op)"
v="$(verdict i_fail)"; [ "$v" = inconclusive ] && ok "verdict(0-turn, SELFCHECK:FAIL) = inconclusive" || no "verdict drift: SELFCHECK FAIL 0-turn" "got '$v', expected 'inconclusive'"
# (c) headless /v stalled on an interactive wait, 0 turns, no phrase → inconclusive
mklogt i_stall 0 "I will wait silently for the Monitor event notification now."
v="$(verdict i_stall)"; [ "$v" = inconclusive ] && ok "verdict(0-turn headless stall) = inconclusive (parked, not looped)" || no "verdict drift: stalled 0-turn" "got '$v', expected 'inconclusive'"
# GUARD: a GENUINE partial (real work, turns>0, no token) MUST still retry — parking never steals a real partial
mklogt p_real 6 "Implemented the change and started the tests."
v="$(verdict p_real)"; [ "$v" = partial ] && ok "verdict(turns>0, no token) = partial (retries — parking never steals real half-done work)" || no "partial-retry guard drift" "got '$v', expected 'partial'"

echo "── 5. timeout (watchdog) parity: a wedged session past PACK_TIMEOUT → parked, never holds its slot forever ──"
# READ side: verdict() must key the timeout off the SIDECAR file (<log>.timedout), NOT log content — writing to
# the log races claude's still-open redirect fd (a killed process' death-message clobbered the marker in testing).
# MODULARIZATION (2026-07-04): the sidecar producers/consumers live in run-v-packs-lib/*.sh now — the contract
# is about the RUNNER's transitive source (runner + libs), same scope `source run-v-packs` delivers.
grep -qE '\.timedout' "$RUNNER" "${RUNNER}-lib"/*.sh 2>/dev/null \
  && ok "run-v-packs signals timeout via the race-free .timedout sidecar (not a log grep)" \
  || no "run-v-packs no longer uses the .timedout sidecar" "a wedged session could hold its parallel slot forever"
grep -qE '_watchdog|PACK_TIMEOUT' "$RUNNER" "${RUNNER}-lib"/*.sh 2>/dev/null \
  && ok "run-v-packs has the per-pack watchdog + PACK_TIMEOUT ceiling" \
  || no "run-v-packs lost the watchdog/PACK_TIMEOUT" "no wall-clock ceiling → a stuck pack starves the run"
# FUNCTIONAL parity: the sidecar → timeout, checked BEFORE the empty-log guard (a killed session has an empty log)
: > "$LOG_DIR/wd.log"; : > "$LOG_DIR/wd.log.timedout"
v="$(verdict wd)"; [ "$v" = timeout ] && ok "verdict(empty log + .timedout sidecar) = timeout" || no "timeout verdict drift" "got '$v', expected 'timeout'"
# GUARD: timeout takes precedence over a rate-limit line (a wedged rate-limit stall must PARK, not loop on resume)
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"limited"}}\n' > "$LOG_DIR/wd2.log"; : > "$LOG_DIR/wd2.log.timedout"
v="$(verdict wd2)"; [ "$v" = timeout ] && ok "verdict(rate-limit + .timedout) = timeout (parks, not ratelimit-loop)" || no "timeout-vs-ratelimit precedence" "got '$v', expected 'timeout'"
# GUARD: no sidecar → NOT timeout (a normal finished pack is unaffected)
mklog nowd "the gauntlet completed — GAUNTLET_ATTESTED: yes"
v="$(verdict nowd)"; [ "$v" = done ] && ok "verdict(no sidecar) = done (watchdog never false-fires)" || no "false timeout without sidecar" "got '$v', expected 'done'"

echo ""
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
