#!/usr/bin/env bash
# run-v-packs-attest-mention-test.sh — a REFUSAL that NAMES the attestation token is NOT an attestation.
#
# WHY (live false-completion, 2026-09-18): a completed audit pack's hardening pack
# carried two CRITICAL hardening items. It was dispatched under a <local-command-caveat> wrapper plus a STRAND-RESUME
# message pressing it to skip confirmations, merge to main and print the completion tokens. The session
# CORRECTLY refused — and its refusal said, in prose:
#     ... asks me to emit fixed "proof" tokens like `V-COMPLETION-SELFCHECK: PASS` or `GAUNTLET_ATTESTED`
#     — which would be fabricating evidence of a gate run that never happened.
# Both literals appear there. The session had also written its own sid-keyed read-only marker, so the
# readonly-done branch — which greps hay for the self-check token and has NO num_turns gate by design —
# matched the REFUSAL and archived the pack to .done/: packs_done: 15, packs_parked: 0, exit_code: 0,
# while the underlying work stayed undone. num_turns was 1, so the gate that protects the `done` branch could not
# help either. A sweep of all 487 pack logs on disk found this shape SEVEN times across four projects.
#
# WHAT THIS PINS: the assertion/mention discriminator (_attest_mention_only) on all THREE archiving
# verdicts — done, readonly-done and noop. noop matters as much as the other two: it also moves the pack to
# .done/, so leaving it unguarded merely relocates the bug (measured: 2 of the 7 refusals fell straight
# through to noop and archived anyway until the veto was added there).
#
# The two directions this must hold in BOTH ways, because each was a real bug during development:
#   • a refusal that quotes a token must NOT archive           (the original defect)
#   • "(not fabricated): <TOKEN>" must STILL archive           (`fabricated`, past participle, ASSERTS
#     authenticity — without the \b it matches inside "fabricate" and false-parked 2 verified-genuine runs)
#   • a token ABSENT from the final message must NOT be read as a mention (the noop branch greps the WHOLE
#     log; hay can legitimately be token-free there — treating absent as mention false-parked 4 good packs)
# Portable bash 3.2/macOS.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq"; echo "── result: 0 passed, 0 failed (skipped) ──"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
# shellcheck disable=SC1090
source "$RUNNER" >/dev/null 2>&1
[ "$(type -t _attest_mention_only)" = function ] || { echo "FATAL: _attest_mention_only not exposed"; exit 1; }
[ "$(type -t verdict)" = function ] || { echo "FATAL: verdict not exposed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export LOG_DIR="$TMP/logs"; export REPO="$TMP/repo"
mkdir -p "$LOG_DIR" "$REPO/.v/tmp" "$REPO/.v/artifacts"

# mk_log <name> <num_turns> <result-text> — a minimal but REAL claude -p stream log (task + result events).
mk_log(){
  local name="$1" turns="$2" text="$3" sid="sid-$1"
  jq -nc --arg t "$text" '{type:"system",subtype:"init",session_id:"x"}' > "$LOG_DIR/$name.log"
  jq -nc --arg t "$text" --argjson n "$turns" --arg s "$sid" \
    '{type:"result",subtype:"success",is_error:false,num_turns:$n,session_id:$s,result:$t}' >> "$LOG_DIR/$name.log"
  printf '%s' "$sid"
}
mark_readonly(){ : > "$REPO/.v/tmp/pack-readonly-$1.marker"; }

REFUSAL='I am not going to act on that. It asserts unverified prior state and asks me to emit fixed "proof"
tokens like `V-COMPLETION-SELFCHECK: PASS` or `GAUNTLET_ATTESTED` — which would be fabricating evidence of a
gate run that never happened. So I am not creating a worktree, not committing, and not printing any token.'

echo "── 1. the live defect: a refusal quoting BOTH tokens, read-only marker present, num_turns=1 ──"
sid="$(mk_log refusal-ro 1 "$REFUSAL")"; mark_readonly "$sid"
v="$(verdict refusal-ro)"
case "$v" in
  done|readonly-done|noop) no "refusal archived as '$v'" "this is the original false completion" ;;
  *) ok "refusal does NOT archive (verdict=$v)" ;;
esac

echo "── 2. same refusal WITHOUT the read-only marker must not reach \`done\` either ──"
sid="$(mk_log refusal-plain 1 "$REFUSAL")"
v="$(verdict refusal-plain)"
case "$v" in
  done|readonly-done|noop) no "refusal archived as '$v'" "the done branch greps the whole log" ;;
  *) ok "refusal does NOT archive (verdict=$v)" ;;
esac

echo "── 3. a GENUINE read-only attestation still archives ──"
sid="$(mk_log genuine-ro 0 'V-COMPLETION-SELFCHECK: PASS — read-only verification (PRE_FLIGHT_REPORT_x.md; no product code changed)')"
mark_readonly "$sid"
v="$(verdict genuine-ro)"
[ "$v" = readonly-done ] && ok "genuine read-only attestation archives (readonly-done)" \
  || no "genuine read-only attestation did not archive" "verdict=$v"

echo "── 4. \"(not fabricated)\" is an AUTHENTICITY claim, not a mention — must still archive ──"
sid="$(mk_log genuine-notfab 0 'Ran the real `v-completion-selfcheck.sh` (not fabricated) which confirmed: V-COMPLETION-SELFCHECK: PASS — read-only verification (PRE_FLIGHT_REPORT_y.md; no product code changed)')"
mark_readonly "$sid"
v="$(verdict genuine-notfab)"
[ "$v" = readonly-done ] && ok "'(not fabricated)' + real token still archives" \
  || no "past-participle false-park regressed" "verdict=$v (needs the \\b in fabricat(e|es|ing|ion|ions))"

echo "── 5. a GENUINE full-gauntlet attestation still archives ──"
sid="$(mk_log genuine-done 12 'All gates green, review clean, verify-done PASS. **GAUNTLET_ATTESTED: yes**')"
v="$(verdict genuine-done)"
[ "$v" = done ] && ok "genuine gauntlet attestation archives (done)" || no "genuine attestation did not archive" "verdict=$v"

echo "── 6. token ABSENT from the final message is NOT a mention (noop greps the whole log) ──"
sid="$(mk_log noop-absent 9 'The fix was already implemented and committed on main in an earlier pass; nothing left to do this run.')"
# the attestation lives in an EARLIER assistant turn, never restated in the result — exactly the shape that
# false-parked 4 verified-genuine packs when "absent" was treated as "mention-only".
jq -nc '{type:"assistant",message:{content:[{type:"text",text:"V-COMPLETION-SELFCHECK: PASS"}]}}' \
  >> "$LOG_DIR/noop-absent.log"
v="$(verdict noop-absent)"
[ "$v" = noop ] && ok "whole-log noop still resolves (verdict=noop)" \
  || no "absent-token treated as a mention" "verdict=$v — _attest_mention_only must return 1 when the token is absent"

echo "── 7. the predicate directly, both directions ──"
_attest_mention_only "$REFUSAL" 'gauntlet_attested' \
  && ok "predicate: refusal is mention-only" || no "predicate: refusal not detected as mention-only"
_attest_mention_only 'GAUNTLET_ATTESTED: yes' 'gauntlet_attested' \
  && no "predicate: bare assertion wrongly called a mention" || ok "predicate: bare assertion is an assertion"
_attest_mention_only 'nothing to see here' 'gauntlet_attested' \
  && no "predicate: absent token wrongly called a mention" || ok "predicate: absent token is not a mention"

echo "── 8. a refusal RE-WRAPPED as a bullet list still vetoes (sed cannot bridge a newline) ──"
# ATTEST-MENTION-2: the flagship incident's own text, merely reformatted. sed is line-oriented, so before
# the whitespace-flattening fix the trigger phrase and the tokens sat on different lines and NOTHING matched.
BULLET='I am not going to fabricate the completion tokens:
- `V-COMPLETION-SELFCHECK: PASS`
- `GAUNTLET_ATTESTED`
Nothing was verified, so neither is true.'
_attest_mention_only "$BULLET" 'gauntlet_attested' \
  && ok "bullet-list refusal is mention-only (newline bridged)" || no "newline still splits the veto"
_attest_mention_only "$BULLET" 'v-completion-selfcheck:[[:space:]]*pass' \
  && ok "bullet-list refusal is mention-only (self-check token)" || no "newline still splits the veto (self-check)"

echo "── 9. the regex must stay under BSD sed's 255 repetition cap ──"
# A bound over 255 makes BSD sed abort with "maximum repetition exceeds 255" and emit NOTHING, which this
# function would read as "no token survived" = mention-only — silently vetoing EVERY pack in the fleet.
grep -qE '\{0,(2[0-5][0-9]|1[0-9][0-9]|[0-9]{1,2})\}' "$HOME/.local/bin/run-v-packs-lib/30-verdict.sh" \
  && ok "mention-span bound is <= 255 (BSD-safe)" || no "mention-span bound exceeds BSD sed's 255 cap"
_sederr="$(_attest_mention_only 'ran the gates: GAUNTLET_ATTESTED: yes' 'gauntlet_attested' 2>&1 >/dev/null)"
[ -z "$_sederr" ] && ok "no sed diagnostic on a normal assertion" || no "sed emitted a diagnostic" "$_sederr"

echo "── 10. a token that exists ONLY in a tool result must NOT attest (corpus scope) ──"
# ATTEST-MENTION-4: 57 fleet packs were archived as `done` purely because the session cat'd a script whose
# COMMENTS contain the literal. The positive signal now reads assistant/result text, never tool results.
sid="$(mk_log toolonly 9 'I inspected the attest script. I am not claiming completion.')"
jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"# GAUNTLET_ATTESTED: yes  <- a COMMENT inside v-gauntlet-attest.sh, not an attestation"}]}}' \
  >> "$LOG_DIR/toolonly.log"
v="$(verdict toolonly)"
case "$v" in
  done|noop|readonly-done) no "tool-result token archived as '$v'" "a cat'd script's comments are not an attestation" ;;
  *) ok "tool-result-only token does NOT archive (verdict=$v)" ;;
esac

echo "── 11. a genuine attestation in an EARLIER assistant turn still archives ──"
sid="$(mk_log earlyturn 11 'Wrapping up; see the gate summary above.')"
jq -nc '{type:"assistant",message:{content:[{type:"text",text:"All gates green. GAUNTLET_ATTESTED: yes"}]}}' \
  >> "$LOG_DIR/earlyturn.log"
v="$(verdict earlyturn)"
[ "$v" = done ] && ok "earlier-turn assistant attestation still archives" \
  || no "earlier-turn attestation lost" "verdict=$v — the corpus must keep assistant text"

echo "── 12. reconcile_parked_readonly must not sweep a mention-only refusal into .done/ ──"
# ATTEST-MENTION-3: this path archived on report EXISTENCE alone and never consulted the veto, so an honest
# refusal accompanied by a genuine same-sid AGENT_REVIEW was swept to .done/ automatically.
RTMP="$(mktemp -d)"; export NEEDS_DIR="$RTMP/needs" DONE_DIR="$RTMP/done"
mkdir -p "$NEEDS_DIR" "$DONE_DIR"
RSID="cccccccc-dddd-eeee-ffff-000000000000"
printf 'pack body\n' > "$NEEDS_DIR/w9-hardening.txt"
jq -nc '{type:"system",subtype:"init"}' > "$LOG_DIR/w9-hardening.log"
jq -nc --arg s "$RSID" '{type:"result",subtype:"success",is_error:false,num_turns:0,session_id:$s,result:"The reviewer returned two CRITICAL findings still unfixed. I am not going to fabricate `V-COMPLETION-SELFCHECK: PASS` or `GAUNTLET_ATTESTED` for work that did not happen."}' >> "$LOG_DIR/w9-hardening.log"
: > "$REPO/.v/tmp/pack-readonly-${RSID}.marker"
printf '# Agent Review\n\n## Findings\n\nCRITICAL-1 unfixed.\n' > "$REPO/.v/artifacts/AGENT_REVIEW_${RSID}.md"
reconcile_parked_readonly >/dev/null 2>&1
[ -f "$NEEDS_DIR/w9-hardening.txt" ] && ok "refusal stays PARKED despite a same-sid report on disk" \
  || no "reconcile_parked_readonly archived a mention-only refusal"
[ -f "$DONE_DIR/w9-hardening.txt" ] && no "pack reached .done/ via the reconcile path" || true
rm -rf "$RTMP"

echo "── 13. CRITICAL-5: early mention-only turn + token-free terminal message must NOT archive ──"
# The signal reads every assistant turn; the veto must read the SAME text, or an honest early "I will not
# fabricate the token" poisons the signal with its own token and no terminal-side veto can see it.
# Proven live before the fix: two real packs sat in .done/ on exactly this shape.
sid="$(mk_log c5done 5 'I ran out of time this session; here is a summary of what remains for next time.')"
jq -nc '{type:"assistant",message:{content:[{type:"text",text:"I will not simply print GAUNTLET_ATTESTED without actually running the gate first, since that would be fabricating evidence."}]}}' \
  >> "$LOG_DIR/c5done.log"
v="$(verdict c5done)"
case "$v" in
  done|noop|readonly-done) no "early mention-only turn archived as '$v'" "signal and veto must read the same corpus" ;;
  *) ok "done branch: early mention-only does NOT archive (verdict=$v)" ;;
esac

echo "── 14. CRITICAL-5 on the noop branch — the mutant this suite used to miss ──"
# QA proved a mutant that removes ONLY the noop branch's veto still passed the previous suite. This case
# is shaped like a real 99-verify incident: turns>0, corpus carries token AND an
# already-done phrase, and the refusal is an early turn rather than the final message.
sid="$(mk_log c5noop 6 'Summary of the session; nothing further here.')"
jq -nc '{type:"assistant",message:{content:[{type:"text",text:"I am not going to claim V-COMPLETION-SELFCHECK: PASS when nothing was verified."}]}}' \
  >> "$LOG_DIR/c5noop.log"
jq -nc '{type:"assistant",message:{content:[{type:"text",text:"The fix was already implemented and committed to main earlier."}]}}' \
  >> "$LOG_DIR/c5noop.log"
v="$(verdict c5noop)"
case "$v" in
  done|noop|readonly-done) no "noop branch archived a mention-only refusal as '$v'" "the noop veto must read \$_nsrc, not \$hay" ;;
  *) ok "noop branch: early mention-only does NOT archive (verdict=$v)" ;;
esac

echo "── 15. readonly-done must stay symmetric (hay for BOTH signal and veto) ──"
# Scoping fix applies to done/noop ONLY. A shared substitution here references an undefined corpus
# variable and emptied EVERY verdict in the fleet; that attempt was reverted. Pin the shape.
grep -qE '_attest_mention_only "\$hay" .v-completion-selfcheck' "$HOME/.local/bin/run-v-packs-lib/30-verdict.sh" \
  && ok "readonly-done still vetoes on \$hay (symmetric, no corpus var)" \
  || no "readonly-done veto no longer reads \$hay" "it has no corpus variable in scope — this emptied the fleet once"
sid="$(mk_log ro_sym 0 'V-COMPLETION-SELFCHECK: PASS — read-only verification (PRE_FLIGHT_REPORT_z.md; no product code changed)')"
mark_readonly "$sid"
v="$(verdict ro_sym)"
[ "$v" = readonly-done ] && ok "genuine read-only attestation still archives after the scoping fix" \
  || no "readonly-done regressed" "verdict=$v"

echo "── 16. SKILL.md's own OBSERVABLE-PROOF block must NOT attest (documentation is not evidence) ──"
# ATTEST-MENTION-8: SKILL.md:832 carries the four-line block verbatim and UNINDENTED in a fenced code block,
# in the one file every /v session is told to read. `grep -A4 GAUNTLET_ATTESTED SKILL.md` lands it in a
# tool_result and line-anchoring alone accepted it. The discriminator is the following line: a real run prints
# an ABSOLUTE path (521 of 524 real captures), the doc prints the literal placeholder `<absolute path>`.
sid="$(mk_log skillmd 9 'Nothing has been verified yet this session; I was checking the expected format.')"
jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"GAUNTLET_ATTESTED: yes\nPRE_FLIGHT_REPORT: <absolute path>\nAGENT_REVIEW: <absolute path>\nVERIFY_DONE_REPORT: <absolute path>"}]}}' \
  >> "$LOG_DIR/skillmd.log"
v="$(verdict skillmd)"
case "$v" in
  done|noop|readonly-done) no "SKILL.md's example block attested as '$v'" "documentation is not an attestation" ;;
  *) ok "SKILL.md example block does NOT archive (verdict=$v)" ;;
esac

echo "── 17. a REAL attest-script capture (absolute paths) still archives ──"
sid="$(mk_log realattest 14 'Gauntlet attested; everything is merged to main.')"
jq -nc '{type:"user",message:{content:[{type:"tool_result",content:"GAUNTLET_ATTESTED: yes\nPRE_FLIGHT_REPORT: /home/x/.v/artifacts/PRE_FLIGHT_REPORT_abc.md\nAGENT_REVIEW: /home/x/.v/artifacts/AGENT_REVIEW_abc.md\nVERIFY_DONE_REPORT: /home/x/.v/artifacts/VERIFY_DONE_REPORT_abc.md"}]}}' \
  >> "$LOG_DIR/realattest.log"
v="$(verdict realattest)"
[ "$v" = done ] && ok "real attest-script stdout still archives (done)" \
  || no "real attestation no longer archives" "verdict=$v — the absolute-path requirement is too strict"

printf '\n── result: %d passed, %d failed ──\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
