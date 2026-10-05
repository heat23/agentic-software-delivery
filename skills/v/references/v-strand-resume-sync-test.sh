#!/bin/bash
# v-strand-resume-sync-test.sh — pins the STRAND-RESUME machinery (50-pack-exec.sh) added 2026-07-12.
# FND-001/FND-002 (adversarial review): the strand predicate's limit/auth/no-task exclusions MUST be
# single-sourced from 30-verdict.sh's _VD_*_RE constants (a hand-maintained copy drifted within hours),
# and the predicate's behavior is pinned against fixture logs: resume ONLY a clean 0-turn exit with real
# fork work and no terminal token; never a limit/auth/no-task/timeout/terminal result; fail closed when
# the shared constants are absent.
set -u
LIB=$HOME/.local/bin/run-v-packs-lib
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  ok  $1"; }
no(){ fail=$((fail+1)); echo "  NO  $1"; }

# ── 1) structural parity: one source of truth ────────────────────────────────────────────────
grep -q '_VD_RATELIMIT_RE=' "$LIB/30-verdict.sh" && grep -q '_VD_AUTHDROP_RE=' "$LIB/30-verdict.sh" \
  && grep -q '_VD_NOTASK_RE=' "$LIB/30-verdict.sh" \
  && ok "30-verdict.sh defines the three _VD_*_RE constants" \
  || no "30-verdict.sh missing one of the _VD_*_RE constants"

# verdict() must consume the constants, not inline literals, for all three lanes
v_body="$(sed -n '/^verdict()/,/^}/p' "$LIB/30-verdict.sh")"
printf '%s' "$v_body" | grep -q 'grep -qiE "\$_VD_RATELIMIT_RE"' \
  && printf '%s' "$v_body" | grep -q 'grep -qiE "\$_VD_AUTHDROP_RE"' \
  && printf '%s' "$v_body" | grep -q 'grep -qiE "\$_VD_NOTASK_RE"' \
  && ok "verdict() consumes all three shared constants" \
  || no "verdict() does not consume all three shared constants (drift risk reopened)"

s_body="$(sed -n '/^_strand_is_stranded()/,/^}/p' "$LIB/50-pack-exec.sh")"
printf '%s' "$s_body" | grep -q '{_VD_RATELIMIT_RE}|\${_VD_AUTHDROP_RE}|\${_VD_NOTASK_RE}' \
  && ok "_strand_is_stranded() consumes the same shared constants" \
  || no "_strand_is_stranded() does not reference the shared constants"
printf '%s' "$s_body" | grep -qiE 'hit your \(session' \
  && no "_strand_is_stranded() still carries a hand-rolled limit-phrase literal" \
  || ok "_strand_is_stranded() carries no hand-rolled limit/auth/no-task literals"

# ── 2) behavioral fixtures ────────────────────────────────────────────────────────────────────
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# minimal source harness: both libs are function-only at top level (plus guarded defaults)
LOG_DIR="$T"; REPO="$T"; export LOG_DIR REPO
# shellcheck source=/dev/null
. "$LIB/30-verdict.sh" 2>/dev/null || { no "sourcing 30-verdict.sh failed"; echo "TOTAL: $pass passed, $fail failed"; exit 1; }
# shellcheck source=/dev/null
. "$LIB/50-pack-exec.sh" 2>/dev/null || { no "sourcing 50-pack-exec.sh failed"; echo "TOTAL: $pass passed, $fail failed"; exit 1; }

mk(){ # $1=file $2=num_turns $3=out_tokens $4=result-text
  jq -cn --argjson nt "$2" --argjson out "$3" --arg res "$4" \
    '{"type":"result","subtype":"success","is_error":false,"num_turns":$nt,"result":$res,"session_id":"11111111-2222-3333-4444-555555555555","modelUsage":{"claude-sonnet-5":{"outputTokens":$out}}}' > "$1"
}

mk "$T/stranded.log" 0 50000 "Pausing here — waiting for the background codex dispatch notification before continuing."
_strand_is_stranded "$T/stranded.log" && ok "genuine strand (0 turns, 50k out, wait text) → resume" || no "genuine strand NOT classified for resume"

mk "$T/auth.log" 0 50000 "Your session has expired — please sign in again to continue."
_strand_is_stranded "$T/auth.log" && no "auth-expired result WOULD burn a resume (FND-001 regression)" || ok "auth-expired result excluded"

mk "$T/limit.log" 0 50000 "You've hit your session limit · resets 4:40pm (UTC)"
_strand_is_stranded "$T/limit.log" && no "session-limit result WOULD burn a resume" || ok "session-limit result excluded"

mk "$T/resetonly.log" 0 50000 "Usage cap reached; resets 6pm today."
_strand_is_stranded "$T/resetonly.log" && no "reset-time-only phrasing WOULD burn a resume (drifted pattern)" || ok "reset-time-only phrasing excluded"

mk "$T/notask.log" 0 50000 "I did not receive a task; no content followed the command. Re-invoke with /v <task>."
_strand_is_stranded "$T/notask.log" && no "no-task result WOULD burn a resume" || ok "no-task result excluded"

mk "$T/attested.log" 0 50000 "All gates green. GAUNTLET_ATTESTED: yes"
_strand_is_stranded "$T/attested.log" && no "attested result WOULD spuriously resume" || ok "terminal token excluded"

mk "$T/lowout.log" 0 200 "ok"
_strand_is_stranded "$T/lowout.log" && no "no-real-work (200 tok) result WOULD spuriously resume" || ok "below V_FORK_WORK_MIN_OUT excluded"

mk "$T/turns.log" 7 50000 "done some turns, no token"
_strand_is_stranded "$T/turns.log" && no "num_turns>0 result WOULD spuriously resume (partial lane owns it)" || ok "num_turns>0 excluded (partial lane owns it)"

mk "$T/timedout.log" 0 50000 "working..."
: > "$T/timedout.log.timedout"
_strand_is_stranded "$T/timedout.log" && no "watchdog-killed log WOULD spuriously resume (timeout lane owns it)" || ok "timedout sidecar excluded"

# fail-closed when the shared constants are absent (standalone sourcing)
( unset _VD_RATELIMIT_RE _VD_AUTHDROP_RE _VD_NOTASK_RE
  _strand_is_stranded "$T/stranded.log" ) && no "constants unset but predicate still resumed (must fail closed)" || ok "fail-closed when shared constants unset"

echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
