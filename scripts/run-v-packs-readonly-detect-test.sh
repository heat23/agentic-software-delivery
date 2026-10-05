#!/usr/bin/env bash
# run-v-packs-readonly-detect-test.sh — class regression test for the run-v-packs read-only DETECTOR
# (2026-07-07 forensic).
#
# CLASS: run-v-packs-lib/50-pack-exec.sh `_pack_is_readonly` tags a pack read-only from its PROSE. If the
# detector misses the directive form the pack PRODUCER actually emits, the pack false-negatives → the runner
# never writes $logf.readonly → the verdict read-only lane (30-verdict.sh) can't fire → a genuinely-complete
# read-only verification pack (w1-pre-flight / 99-verify) PARKS to .needs-review/ forever and the per-wave
# barrier deadlocks the whole batch. Observed live: the v-audit-code producer emits `READ-ONLY —` (EM-DASH),
# but the pre-fix detector only matched `read-only[:.]` (colon/period) → every em-dash directive re-stranded.
# This is the deadlock the 2026-07-07 read-only-completion lane exists to close; the detector gap re-opened it.
#
# The PRIOR contract test (skills/v/references/v-readonly-completion-test.sh) hardcodes the runner tag and
# NEVER exercises _pack_is_readonly, so it was false-green against this bug. This test closes that gap: it
# feeds _pack_is_readonly the REAL directive forms and carries an intrinsic RED oracle (the pre-fix regex).
#
# GREEN on the live 50-pack-exec.sh; the RED oracle proves the pre-fix regex false-negatives the em-dash form.
# Portable bash 3.2 / macOS. No side effects (works on temp fixtures only).
set -uo pipefail

LIB="${V_PACK_EXEC_LIB:-$HOME/.local/bin/run-v-packs-lib/50-pack-exec.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB (set V_PACK_EXEC_LIB)"; exit 2; }
# shellcheck disable=SC1090
. "$LIB" || { echo "FATAL: could not source $LIB"; exit 2; }
type _pack_is_readonly >/dev/null 2>&1 || { echo "FATAL: _pack_is_readonly not defined after sourcing"; exit 2; }

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t rvpro)"; trap 'rm -rf "$TMP"' EXIT
mkpack(){ printf '%b' "$2" > "$TMP/$1"; printf '%s' "$TMP/$1"; }
is_ro(){ _pack_is_readonly "$1" && echo readonly || echo CODE; }

echo "── (1) live detector: real producer directive forms are tagged read-only ──"
# The exact forms the v-audit-code / prompt-pack producer emits, plus the other separator variants.
EMDASH=$(mkpack emdash.txt   '/v Run pre-flight gates.\nRun the suite. READ-ONLY — do not edit source; capture failures and report them.\n')
ENDASH=$(mkpack endash.txt   '/v Final verification.\nREAD-ONLY – no edits; if anything fails, report it, do not fix here.\n')
HYPHEN=$(mkpack hyphen.txt    '/v Review the batch.\nREAD-ONLY - dispatch reviewers and collect findings; do not fix.\n')
COLON=$(mkpack  colon.txt     '/v Audit.\nREAD-ONLY: confirm each fix landed; report only.\n')
PERIOD=$(mkpack period.txt    '/v Audit.\nThis pack is READ-ONLY. Report findings, do not fix.\n')
NOSRC=$(mkpack  nosrc.txt     '/v Review.\nDispatch reviewers. Acceptance: No source edited in this pack.\n')
# forensic (a review pack in a production repo): the review-dispatch producer's ACTUAL acceptance phrasing puts a noun
# phrase ("files were") between "source" and the verb — the exact form R4 pre-2026-07-13 false-negatived,
# leaving the pack untagged → CODE dispatch contract → hung on a background reviewer-wait → 0-turn park.
NOSRC2=$(mkpack nosrc2.txt    '/v Dispatch codex-adversarial-reviewer and codebase-fit-reviewer; report findings.\n## Acceptance\n- [ ] No source files were modified by this pack.\n')
MARKER=$(mkpack marker.txt    '/v Verify.\n<!-- v-pack: read-only -->\nRun gates and report.\n')
for f in "$EMDASH" "$ENDASH" "$HYPHEN" "$COLON" "$PERIOD" "$NOSRC" "$NOSRC2" "$MARKER"; do
  bn=$(basename "$f")
  [ "$(is_ro "$f")" = readonly ] && ok "read-only form tagged: $bn" || no "read-only form NOT tagged: $bn" "$(is_ro "$f")"
done

echo "── (2) live detector: code packs / bare mentions are NOT tagged (no false-positive strand of real work) ──"
CODE1=$(mkpack code1.txt  '/v Triage and harden the fix batch. Fix all CRITICAL findings, re-run gates until green.\n## Files\napp/Models/User.php\n')
CODE2=$(mkpack code2.txt  '/v Add a read-only flag to the model and expose it in the admin UI. Implement and test.\n')
for f in "$CODE1" "$CODE2"; do
  bn=$(basename "$f")
  [ "$(is_ro "$f")" = CODE ] && ok "code/bare-mention pack NOT tagged: $bn" || no "code pack WRONGLY tagged read-only: $bn" ""
done

echo "── (3) RED oracle: the PRE-FIX detector regex FALSE-NEGATIVES the em-dash directive (this is the bug) ──"
# The pre-fix R1 (matched only a colon/period immediately after read-only).
pre_fix_r1(){ grep -qiE '(^|[^[:alnum:]])read-?only[:.]' "$1" 2>/dev/null; }
if pre_fix_r1 "$EMDASH"; then
  no "RED oracle broken: pre-fix regex already matched the em-dash form" "the test cannot prove the fix bites"
else
  ok "RED: pre-fix regex MISSES 'READ-ONLY —' (em-dash) — reproduces the false-negative the fix closes"
fi
# and the live (fixed) detector MUST catch exactly what the pre-fix one missed:
[ "$(is_ro "$EMDASH")" = readonly ] && ok "GREEN: live detector catches the em-dash form the pre-fix regex missed" \
  || no "live detector still misses the em-dash form" "the fix did not land"

# RED oracle for R4 (forensic): the pre-fix R4 required the verb IMMEDIATELY after "source", so the
# "No source files were modified" acceptance form false-negatived. The live (fixed) R4 must catch it.
pre_fix_r4(){ grep -qiE 'no source (was |is )?(modified|changed|edited)' "$1" 2>/dev/null; }
if pre_fix_r4 "$NOSRC2"; then
  no "RED oracle broken: pre-fix R4 already matched 'No source files were modified'" "the test cannot prove the R4 fix bites"
else
  ok "RED: pre-fix R4 MISSES 'No source files were modified' (noun phrase before the verb) — reproduces the strand"
fi
[ "$(is_ro "$NOSRC2")" = readonly ] && ok "GREEN: live R4 catches the 'files were modified' form the pre-fix regex missed" \
  || no "live R4 still misses the 'files were modified' form" "the fix did not land"

echo "── (4) verdict read-only lane: honors the SESSION-side marker when the runner tag is missing (F1b) ──"
# Defense-in-depth: even if the detector ever drifts again and the runner never writes $logf.readonly, a
# read-only /v session's own sid-keyed marker + the terminal V-COMPLETION-SELFCHECK: PASS must still yield
# `readonly-done` instead of parking. RED oracle: with NO read-only signal at all it must fall through.
VERDICT_LIB="${V_VERDICT_LIB:-$HOME/.local/bin/run-v-packs-lib/30-verdict.sh}"
if [ -f "$VERDICT_LIB" ]; then
  vres="$(
    set +u
    VR="$TMP/vrepo"; VL="$TMP/vlogs"; mkdir -p "$VR/.v/tmp" "$VL"
    export REPO="$VR" LOG_DIR="$VL"
    sid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; name="w1-pre-flight"
    printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s","result":"V-COMPLETION-SELFCHECK: PASS — read-only verification (no product code changed)"}\n' "$sid" > "$VL/$name.log"
    # NO runner tag ($VL/$name.log.readonly absent); session-side marker present:
    printf 'read-only verification pack\n' > "$VR/.v/tmp/pack-readonly-${sid}.marker"
    . "$VERDICT_LIB" 2>/dev/null
    printf 'GREEN=%s\n' "$(verdict "$name" 2>/dev/null)"
    rm -f "$VR/.v/tmp/pack-readonly-${sid}.marker"   # remove the only read-only signal
    printf 'RED=%s\n'   "$(verdict "$name" 2>/dev/null)"
  )"
  case "$vres" in *"GREEN=readonly-done"*) ok "verdict honors the session marker fallback → readonly-done (no runner tag needed)";; *) no "verdict did NOT fire the session-marker fallback" "$vres";; esac
  case "$vres" in *"RED=readonly-done"*) no "verdict fired readonly-done with NO read-only signal (marker removed)" "$vres";; *) ok "RED: with no read-only signal the fallback does NOT fire (falls through to park)";; esac
else
  echo "  -- skipped: verdict lib not found at $VERDICT_LIB (set V_VERDICT_LIB)"
fi

echo "── (5) dispatch contract: read-only packs are TOLD to emit the completion token ──"
# The read-only /v session strands when it summarizes findings in prose but never emits the machine token
# the archive gate reads. The runner's read-only dispatch-contract appendix must MANDATE emitting
# `V-COMPLETION-SELFCHECK: PASS` (running the self-check), and must NOT append that mandate to code packs.
if type _pack_prompt >/dev/null 2>&1; then
  ROP="$(_pack_prompt "$EMDASH" emdash 2>/dev/null)"
  CDP="$(_pack_prompt "$CODE1"  code1  2>/dev/null)"
  case "$ROP" in *"V-COMPLETION-SELFCHECK: PASS"*) ok "read-only dispatch contract mandates the completion token";; *) no "read-only contract does NOT instruct emitting the token" "";; esac
  case "$ROP" in *"MANDATORY"*|*"PARKS to .needs-review"*) ok "read-only contract warns that a prose summary strands the pack";; *) no "read-only contract missing the strand warning" "";; esac
  case "$CDP" in *"COMPLETION TOKEN IS MANDATORY"*) no "code pack WRONGLY got the read-only token mandate" "";; *) ok "code pack does NOT get the read-only token mandate (gets landing/worktree contract)";; esac
else
  echo "  -- skipped: _pack_prompt not defined"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"   # the form scripts/run-tests.sh counts
if [ "$FAIL" -eq 0 ]; then echo "PASS — $PASS check(s), 0 failures"; exit 0
else echo "FAIL — $FAIL failure(s) / $PASS ok"; exit 1; fi
