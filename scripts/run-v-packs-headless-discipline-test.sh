#!/usr/bin/env bash
# run-v-packs-headless-discipline-test.sh — BITE for A1 (forensic 2026-07-07).
#
# CLASS: the dominant strand cause. A headless `claude -p /v` pack session dispatched its gauntlet gates
# (codex/agent review, verify-done) with run_in_background, then ENDED its turn "waiting for the background
# notification" that never arrives under -p — so the session died mid-gauntlet (no VERIFY_DONE, a stub
# AGENT_REVIEW) and its committed work stranded ungated (W-GATE refuses it forever). Two packs died this way.
#
# FIX: _pack_prompt (50-pack-exec.sh) appends a HEADLESS GAUNTLET DISCIPLINE clause to EVERY dispatched pack
# telling the session to run every gate synchronously/foreground and never end a turn owing a gate report.
#
# BITE: the composed dispatch prompt MUST carry the discipline for both a code pack and a read-only pack;
# RED = the pre-fix _pack_prompt (clause stripped) omits it.
set -uo pipefail
LIB="${LIB:-$HOME/.local/bin/run-v-packs-lib/50-pack-exec.sh}"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB"; exit 2; }

pass=0; fail=0
ok(){ echo "  ok   $1"; pass=$((pass+1)); }
no(){ echo "  FAIL $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export LOG_DIR="$TMP/logs" REPO="$TMP/repo"; mkdir -p "$LOG_DIR" "$REPO"

codepack="$TMP/code.txt";  printf 'Fix the widget bug.\n## Files\napp/Widget.php\n' > "$codepack"
ropack="$TMP/ro.txt";      printf 'READ-ONLY: audit the widget and report findings. Do not edit source.\n' > "$ropack"

# GREEN: the shipped lib emits the discipline for both pack kinds.
( set -uo pipefail; source "$LIB"; _pack_prompt "$codepack" "code" ) > "$TMP/code.out" 2>/dev/null
( set -uo pipefail; source "$LIB"; _pack_prompt "$ropack"   "ro"   ) > "$TMP/ro.out"   2>/dev/null

grep -q "RUN EVERY GATE SYNCHRONOUSLY" "$TMP/code.out" && ok "code pack carries the headless discipline" || no "code pack MISSING headless discipline"
grep -q "RUN EVERY GATE SYNCHRONOUSLY" "$TMP/ro.out"   && ok "read-only pack carries the headless discipline" || no "read-only pack MISSING headless discipline"
grep -qi "run_in_background" "$TMP/code.out" && ok "names the run_in_background anti-pattern" || no "does not name run_in_background"
# the clause line-wraps ("NEVER end a" / "turn with 'I'll wait...'"); match on the stable head.
grep -qi "NEVER end a" "$TMP/code.out" && ok "forbids ending a turn owing a gate report" || no "missing the 'never end a turn' rule"

# RED-on-revert: strip the discipline printf block from a COPY and prove the bite fails on the pre-fix shape.
cp "$LIB" "$TMP/lib-prefix.sh"
# delete the contiguous block from the 'HEADLESS GAUNTLET DISCIPLINE' comment through its closing printf arg.
awk '
  /HEADLESS GAUNTLET DISCIPLINE/ {skip=1}
  skip && /An unfinished/ {skip2=1}
  skip2 && /gauntlet is a FAILED pack, not a deferral\."/ {skip=0; skip2=0; next}
  !skip {print}
' "$TMP/lib-prefix.sh" > "$TMP/lib-red.sh"
bash -n "$TMP/lib-red.sh" || { echo "  (revert copy failed to parse — adjust stripper)"; }
( set -uo pipefail; source "$TMP/lib-red.sh"; _pack_prompt "$codepack" "code" ) > "$TMP/red.out" 2>/dev/null
if grep -q "RUN EVERY GATE SYNCHRONOUSLY" "$TMP/red.out"; then
  no "RED proof: pre-fix lib STILL emits the clause (stripper missed — bite not proven)"
else
  ok "RED: pre-fix lib omits the discipline (bite proven)"
fi

echo; echo "TOTAL: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
