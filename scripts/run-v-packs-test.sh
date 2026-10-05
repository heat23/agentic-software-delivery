#!/usr/bin/env bash
# run-v-packs-test.sh — behavioral harness for the wave-aware runner.
# Sources run-v-packs (main is guarded), builds fixture pack trees, asserts pack
# detection + wave grouping. Also shows the OLD runner could NOT see .md/subfolders (the bite).
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
OLD="${OLD:-$HOME/.local/bin/run-v-packs.pre-wave-bak}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     got:      %s\n' "$1" "$2" "$3"; }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "$2" "$3"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# minimal git repo so any code path that calls git has a root (functions under test don't, but be safe)
git -C "$TMP" init -q 2>/dev/null || true

# ── source the runner without executing main ──────────────────────────────────
# shellcheck disable=SC1090
source "$RUNNER"
[ "$(type -t wave_of)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose wave_of (main guard broken)"; exit 1; }

# ── build a fixture pack tree ─────────────────────────────────────────────────
PK="$TMP/.v-prompt-packs/demo-06-29"; mkdir -p "$PK"
vpack(){ printf '/v %s\n\nbody line\nmore\n' "$2" >"$PK/$1"; }     # a real pack: line1 = /v …
vpack "alpha.txt"            "unordered pack A"
vpack "beta.md"              "unordered pack B (markdown)"
vpack "w1-foundation.txt"    "wave 1 pack"
vpack "w2-wiring.txt"        "wave 2 pack"
vpack "w10-late.txt"         "wave 10 pack (two-digit)"
vpack "99-VERIFY.txt"        "final verify pack"
vpack "webhook-thing.txt"    "starts with w but not a wave prefix"
# non-packs that MUST be ignored
printf '# Master map\nnot a pack\n'              >"$PK/00-README.md"
printf '# Plan\nsome plan text\n'                >"$PK/AUDIT_FIX_PLAN.md"
printf 'print("validator")\n'                    >"$PK/validate.py"
printf 'Just notes, no slash-v here.\n'          >"$PK/notes.md"
# subfolder waves (legacy/skill layout)
mkdir -p "$PK/wave-1" "$PK/w3"
vpack_sub(){ printf '/v %s\n\nbody\nmore\n' "$3" >"$PK/$1/$2"; }
vpack_sub "wave-1" "sub-early.txt" "subfolder wave 1"
vpack_sub "w3"     "sub-mid.md"    "subfolder wave 3 markdown"
# an oversized concatenated bundle (must NOT be treated as one pack)
{ printf '/v bundle\n'; head -c 30000 /dev/zero | tr '\0' 'x'; } >"$PK/PACKS_ALL.txt"
# stuff that lives in the runner's own dot-dirs (must be pruned)
mkdir -p "$PK/.done" "$PK/.runlogs"
vpack ".done/already.txt" "archived — must be ignored" 2>/dev/null || printf '/v archived\n\nx\n' >"$PK/.done/already.txt"
printf '{"type":"result"}\n' >"$PK/.runlogs/alpha.log"

PACK_ABS="$PK"   # functions read this global

echo "── is_pack ──"
is_pack "$PK/alpha.txt"          && ok "alpha.txt is a pack"            || no "alpha.txt is a pack" "0" "1"
is_pack "$PK/beta.md"            && ok ".md /v is a pack"               || no ".md /v is a pack" "0" "1"
is_pack "$PK/00-README.md"       && no "README excluded" "1(reject)" "0(accept)" || ok "README excluded"
is_pack "$PK/AUDIT_FIX_PLAN.md"  && no "PLAN.md excluded" "1" "0"       || ok "PLAN.md excluded (no /v line 1)"
is_pack "$PK/validate.py"        && no "validate.py excluded" "1" "0"   || ok "validate.py excluded"
is_pack "$PK/notes.md"           && no "non-/v md excluded" "1" "0"     || ok "non-/v md excluded"
is_pack "$PK/PACKS_ALL.txt"      && no "oversized bundle excluded" "1" "0" || ok "oversized bundle excluded (> PACK_MAX_BYTES)"

echo "── wave_of ──"
eq "alpha.txt -> 0"            0    "$(wave_of "$PK/alpha.txt")"
eq "beta.md -> 0"             0    "$(wave_of "$PK/beta.md")"
eq "w1-foundation -> 1"       1    "$(wave_of "$PK/w1-foundation.txt")"
eq "w2-wiring -> 2"           2    "$(wave_of "$PK/w2-wiring.txt")"
eq "w10-late -> 10"           10   "$(wave_of "$PK/w10-late.txt")"
eq "99-VERIFY -> 9999"        9999 "$(wave_of "$PK/99-VERIFY.txt")"
eq "webhook-thing -> 0"       0    "$(wave_of "$PK/webhook-thing.txt")"
eq "wave-1/ subfolder -> 1"   1    "$(wave_of "$PK/wave-1/sub-early.txt")"
eq "w3/ subfolder -> 3"       3    "$(wave_of "$PK/w3/sub-mid.md")"

echo "── waves_present (ordered, no verify, no dups) ──"
eq "waves present"  "0 1 2 3 10"  "$(waves_present | tr '\n' ' ' | sed 's/ $//')"

echo "── list_packs_in_wave ──"
eq "wave 0 count"  3  "$(list_packs_in_wave 0 | grep -c .)"     # alpha, beta, webhook-thing
eq "wave 1 count"  2  "$(list_packs_in_wave 1 | grep -c .)"     # w1-foundation + wave-1/sub-early
eq "wave 2 count"  1  "$(list_packs_in_wave 2 | grep -c .)"
eq "wave 3 count"  1  "$(list_packs_in_wave 3 | grep -c .)"
eq "wave 10 count" 1  "$(list_packs_in_wave 10 | grep -c .)"

echo "── list_all_packs / verify_pack / pruning ──"
eq "all packs (no verify)" 8 "$(list_all_packs | grep -c .)"   # 5 flat + webhook + 2 subfolder = 8
eq "verify pack basename"  "99-VERIFY.txt" "$(basename "$(verify_pack)")"
list_all_packs | grep -q '/.done/'    && no ".done pruned" "absent" "present"    || ok ".done pruned from listing"
list_all_packs | grep -q '/.runlogs/' && no ".runlogs pruned" "absent" "present" || ok ".runlogs pruned from listing"
list_all_packs | grep -q 'PACKS_ALL'  && no "bundle not listed" "absent" "present" || ok "oversized bundle not in pack listing"

echo "── back-compat: a plain flat .txt dir behaves exactly like before (all wave 0 + 99 last) ──"
FLAT="$TMP/flat"; mkdir -p "$FLAT"; PACK_ABS="$FLAT"
printf '/v do a\n\nx\ny\n' >"$FLAT/a.txt"; printf '/v do b\n\nx\ny\n' >"$FLAT/b.txt"; printf '/v verify\n\nx\ny\n' >"$FLAT/99-v.txt"
eq "flat: single wave 0"  "0" "$(waves_present | tr '\n' ' ' | sed 's/ $//')"
eq "flat: 2 packs"        2   "$(list_all_packs | grep -c .)"
eq "flat: verify found"   "99-v.txt" "$(basename "$(verify_pack)")"

echo "── the BITE: the OLD runner could not see .md or subfolder packs ──"
if [ -f "$OLD" ]; then
  # old list_packs: find -maxdepth 1 -name '*.txt' ! -name '99-*'  (no .md, no subfolders)
  OLD_CNT="$( ( cd "$PK"; find . -maxdepth 1 -name '*.txt' ! -name '99-*' | grep -c . ) )"
  NEW_CNT="$(PACK_ABS="$PK" ; list_all_packs | grep -c .)"
  if [ "$NEW_CNT" -gt "$OLD_CNT" ]; then ok "new runner sees $NEW_CNT packs vs old runner's $OLD_CNT (was blind to .md + wave-*/ subfolders)"
  else no "new > old coverage" ">$OLD_CNT" "$NEW_CNT"; fi
else
  printf '  --   (no pre-wave backup to contrast; skipping bite)\n'
fi

echo "── SREV-002: malformed wave prefix yields a PURE INTEGER (no silent sort -nu drop) ──"
PACK_ABS="$PK"
eq "w1x-foo -> 1 (not '1x')"  1  "$(wave_of "$PK/w1x-foo.txt")"
# a dir with BOTH w1-a and w1x-b: both are wave 1, neither is dropped by sort -nu
SR2="$TMP/sr2"; mkdir -p "$SR2"; PACK_ABS="$SR2"
printf '/v a\n\n%s\n' "$(seq 1 12)" >"$SR2/w1-a.txt"; printf '/v b\n\n%s\n' "$(seq 1 12)" >"$SR2/w1x-b.txt"
eq "w1- and w1x- both land in wave 1"  2  "$(list_packs_in_wave 1 | grep -c .)"
eq "no spurious non-integer wave"      "1"  "$(waves_present | tr '\n' ' ' | sed 's/ $//')"
PACK_ABS="$PK"

echo "── SREV-003: pack_name keeps path structure → subfolder + flat packs never collide on one log ──"
a="$(pack_name "$PK/wave-1/foo.txt")"; b="$(pack_name "$PK/wave-1-foo.txt")"
[ "$a" != "$b" ] && ok "wave-1/foo.txt ($a) ≠ flat wave-1-foo.txt ($b) — distinct log names" || no "pack_name unique" "different" "both=$a"
eq "pack_name preserves subdir"  "wave-1/foo"  "$a"

echo "── SREV-001: dot-dir prune survives glob metachars in PACK_ABS (find -path fnmatch trap) ──"
BR="$TMP/br[1]"; mkdir -p "$BR/.done"; PACK_ABS="$BR"
printf '/v real\n\n%s\n' "$(seq 1 12)" >"$BR/real.txt"
printf '/v archived\n\nx\n' >"$BR/.done/already.txt"
if list_all_packs | grep -q '/.done/'; then no "SREV-001 .done pruned under bracket path" "absent" "present (re-runs archived work!)"
else ok ".done pruned even when PACK_ABS contains [ ] (metachar-safe)"; fi
eq "bracket path still finds the real pack"  1  "$(list_all_packs | grep -c .)"
PACK_ABS="$PK"

echo "── verdict(): done / noop(already-done) / partial / no-task / ratelimit classification ──"
VT="$TMP/verdict"; mkdir -p "$VT"; LOG_DIR="$VT"
printf '{"type":"result","subtype":"success","is_error":false,"result":"done GAUNTLET_ATTESTED"}\n' >"$VT/g.log"
printf '{"type":"result","subtype":"success","is_error":false,"result":"V-COMPLETION-SELFCHECK: PASS — non-code completion. already implemented and committed on main."}\n' >"$VT/n.log"
printf '{"type":"result","subtype":"success","is_error":false,"result":"I implemented it and stopped."}\n' >"$VT/p.log"
printf '{"type":"result","subtype":"success","is_error":false,"result":"V-COMPLETION-SELFCHECK: PASS. freshly implemented the feature now."}\n' >"$VT/guard.log"
printf '{"type":"result","subtype":"success","is_error":false,"result":"didnt receive a task"}\n' >"$VT/nt.log"
eq "GAUNTLET_ATTESTED -> done"                 done    "$(verdict g)"
eq "already-done self-check -> noop"           noop    "$(verdict n)"
eq "clean exit, no markers -> partial"         partial "$(verdict p)"
eq "self-check PASS w/o already-done -> partial (guard: fresh work must NOT archive)" partial "$(verdict guard)"
eq "no-task phrasing -> no-task"               no-task "$(verdict nt)"

echo "── V-FORK-1 (2026-07-06): 0-turn PARENT + fork OP_TELEMETRY ledger — fork turns recovered, hay-scoped tokens ──"
# CLASS: /v is context:fork — under `claude -p` the parent reports num_turns=0 for EVERY session, real
# fully-attested work included (live 5/5-pack batch: 0/7 landed because verdict() parked everything
# INCONCLUSIVE). Fix: recover the real turn count from the fork's durable OP_TELEMETRY_<sid>.json ledger,
# and scope the done/noop token greps to the terminal result TEXT (the parent-turn gate doubled as the
# echo-spoof guard; a pack PROMPT echoed into the task event must still never read as attestation).
FSID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
FREPO="$TMP/forkrepo"; mkdir -p "$FREPO/.v/artifacts"
_OLD_REPO="${REPO:-}"; REPO="$FREPO"
printf '[{"sid":"%s","turns":[{"out":10},{"out":20},{"out":5}]}]\n' "$FSID" >"$FREPO/.v/artifacts/OP_TELEMETRY_${FSID}.json"
# (a) attested result text + 0 parent turns + ledger -> done (was: inconclusive, the live 5-pack park)
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s","result":"Bug fix complete. GAUNTLET_ATTESTED: yes"}\n' "$FSID" >"$VT/fk-done.log"
eq "fork ledger + attested result text -> done"        done         "$(verdict fk-done)"
eq "_fork_turns reads the ledger's real turn count"    3            "$(_fork_turns fk-done)"
# (b) already-done self-check in result text + ledger -> noop
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s","result":"V-COMPLETION-SELFCHECK: PASS — non-code completion. already implemented and committed on main."}\n' "$FSID" >"$VT/fk-noop.log"
eq "fork ledger + already-done self-check -> noop"     noop         "$(verdict fk-noop)"
# (c) SPOOF GUARD: token only ECHOED in the task event (pack prompt), NOT in the result text -> NEVER done.
# With real fork turns recovered it classifies as `partial` (retry — correct: the session DID work but never
# attested; the retry carries the adoption continuity note). The assertion that matters: never done/noop.
printf '{"type":"task","content":"pack prompt quoting GAUNTLET_ATTESTED and V-COMPLETION-SELFCHECK: PASS","session_id":"%s"}\n{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s","result":"merge deferred; see handoff."}\n' "$FSID" "$FSID" >"$VT/fk-spoof.log"
eq "fork ledger + token only in task event -> partial, never done (echo-spoof guard holds)" partial "$(verdict fk-spoof)"
# (d) NO ledger + 0 parent turns -> park exactly as before (missing telemetry keeps the safe default)
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee","result":"Bug fix complete. GAUNTLET_ATTESTED: yes"}\n' >"$VT/fk-noledger.log"
eq "no ledger + 0 parent turns -> inconclusive (pre-fix behavior preserved)" inconclusive "$(verdict fk-noledger)"
REPO="$_OLD_REPO"
LOG_DIR="$TMP"

echo "── V-DISPATCH-CONTRACT: _pack_prompt appends the landing contract + retry continuity ──"
PPD="$TMP/ppd"; mkdir -p "$PPD"; _OLD_LOG_DIR2="$LOG_DIR"; LOG_DIR="$PPD"
printf '/v Fix THING per spec. Do NOT commit; leave changes staged.\n\nbody\n' >"$PPD/mypack.txt"
pp="$(_pack_prompt "$PPD/mypack.txt" mypack)"
printf '%s' "$pp" | grep -q 'Do NOT commit; leave changes staged' && ok "pack body preserved verbatim" || no "pack body preserved" "present" "absent"
printf '%s' "$pp" | grep -q 'RUN-V-PACKS DISPATCH CONTRACT' && ok "dispatch contract appended" || no "dispatch contract appended" "present" "absent"
printf '%s' "$pp" | grep -q 'scopes to the REPO ROOT working tree ONLY' && ok "no-commit clause scoped to root" || no "no-commit scoping" "present" "absent"
printf '%s' "$pp" | grep -q 'RETRY CONTINUITY' && no "fresh pack has NO retry note" "absent" "present" || ok "fresh pack has NO retry note"
# retry attempt: a rotated prior log exists -> continuity note with the prior sid
printf '{"type":"result","subtype":"success","is_error":false,"session_id":"cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee","result":"killed"}\n' >"$PPD/mypack.log.1"
pp2="$(_pack_prompt "$PPD/mypack.txt" mypack)"
printf '%s' "$pp2" | grep -q 'RETRY CONTINUITY' && ok "retry gets the continuity note" || no "retry continuity note" "present" "absent"
printf '%s' "$pp2" | grep -q 'cccccccc-bbbb-cccc-dddd-eeeeeeeeeeee' && ok "continuity note names the prior attempt's sid" || no "prior sid in note" "present" "absent"
printf '%s' "$pp2" | grep -q 'ADOPT it: re-key its session lock' && ok "continuity note instructs adoption, not duplicate-park" || no "adoption instruction" "present" "absent"
LOG_DIR="$_OLD_LOG_DIR2"

echo "── parallel-safety: run_pack pins a unique session-id + pre-seeds the task (anti-clobber, verified live ALPHA/BRAVO) ──"
rp="$(declare -f run_pack 2>/dev/null)"
echo "$rp" | grep -q -- '--session-id'   && ok "run_pack pins --session-id"            || no "run_pack pins --session-id" "present" "absent"
echo "$rp" | grep -q 'last-user-prompt'  && ok "run_pack pre-seeds last-user-prompt"   || no "run_pack pre-seeds task channel" "present" "absent"
echo "$rp" | grep -q 'uuidgen'           && ok "run_pack generates a unique sid"        || no "run_pack uuidgen" "present" "absent"
echo "$rp" | grep -q 'CLAUDE_CODE_SESSION_ID' && ok "run_pack forces per-process sid env" || no "run_pack sets CLAUDE_CODE_SESSION_ID" "present" "absent"

echo "── reset_epoch: only a REAL block sets the reset — an allowed_warning's weekly boundary must NOT strand the run ──"
# Regression guard for the 3-day blind-wait bug: reset_epoch once took MAX resetsAt across ALL rate_limit_events,
# incl. allowed_warning events whose resetsAt is a days-away WEEKLY boundary → the runner idled for days on a
# session limit that had already reset.
RLD="$TMP/rl-epoch"; mkdir -p "$RLD"; LOG_DIR="$RLD"
_now=$(date +%s); _near=$((_now+600)); _far=$((_now+300000))
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":%s}}\n{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":null}}\n' "$_far" >"$RLD/only-allowed.log"
eq "allowed/allowed_warning only -> empty (no weekly-boundary blind-wait)"  ""       "$(reset_epoch)"
: >"$RLD/only-allowed.log"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"limited","resetsAt":%s}}\n{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":%s}}\n' "$_near" "$_far" >"$RLD/mixed.log"
eq "mixed block+allowed_warning -> the real block's reset (weekly ignored)"  "$_near"  "$(reset_epoch)"
LOG_DIR="$TMP"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
