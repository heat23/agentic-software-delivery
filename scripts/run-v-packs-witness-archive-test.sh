#!/usr/bin/env bash
# run-v-packs-witness-archive-test.sh — the CRASH-AFTER-MERGE archive (F8, 2026-07-07).
#
# WHY: a /v session can COMMIT + MERGE its work to main (writing the durable commits-<sid>.txt witness at merge
# time) and THEN crash/park before the runner sees a clean `done` verdict — e.g. the post-merge session-log step
# crashes (observed: a production session merged its work, then SESSION_LOG_FAILED → the pack was never archived →
# re-dispatched → the retry parked at num_turns==0 → the landing barrier DEADLOCKED behind on-main work). Fix:
# for any PARKING verdict, if THIS pack's OWN session's commit witness is fully on main, archive it as done.
# OWN-sid only ⇒ zero cross-session false-attribution. RED-ORACLE: case A archives only with the fix in place.
# Portable bash 3.2/macOS; needs git.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "  (skipped — git unavailable)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }
SID="dddddddd-1111-2222-3333-444444444444"

# Build a repo + a queued pack file + a commit witness. $1 = witness {onmain|offmain|none}. Echoes root.
mkfix(){
  local root repo; root="$(mktemp -d)"; repo="$root/repo"
  mkdir -p "$repo/.v/tmp" "$repo/.v/artifacts" "$root/done" "$root/needs" "$root/logs"
  ( cd "$repo" && git init -q . && git config user.email t@t.t && git config user.name t \
      && git commit -q --allow-empty -m c1 && git branch -m main \
      && git checkout -q -b side && git commit -q --allow-empty -m side && git checkout -q main ) >/dev/null 2>&1
  local sha_main sha_side; sha_main="$(git -C "$repo" rev-parse main)"; sha_side="$(git -C "$repo" rev-parse side)"
  printf '/v remediate findings\n' > "$root/w2.txt"
  case "${1:-onmain}" in
    onmain)  printf '%s\n' "$sha_main" > "$repo/.v/tmp/commits-${SID}.txt" ;;   # ancestor of main → work landed
    offmain) printf '%s\n' "$sha_side" > "$repo/.v/tmp/commits-${SID}.txt" ;;   # valid commit, NOT on main
    none)    : ;;
  esac
  printf '%s' "$root"
}
run_afp(){ # $1=root  $2=env assignments
  ( source "$RUNNER" >/dev/null 2>&1
    verdict(){ printf '%s' "${STUB_VERDICT:-inconclusive}"; }
    sid_of(){ printf '%s' "${STUB_SID:-}"; }
    _main_branch(){ printf 'main'; }
    _gauntlet_verdicts_not_failed(){ [ "${STUB_GNF:-0}" = 0 ]; }
    _inconclusive_kind(){ printf 'already-done'; }
    REPO="$1/repo"; DONE_DIR="$1/done"; NEEDS_DIR="$1/needs"; LOG_DIR="$1/logs"; ARCHIVE=1
    eval "${2:-}"
    _archive_finished_pack w2 "$1/w2.txt" 2>&1 )
}
archived(){ [ -f "$1/done/w2.txt" ] && [ ! -e "$1/w2.txt" ]; }
parked(){   [ -f "$1/needs/w2.txt" ] && [ ! -e "$1/done/w2.txt" ]; }

echo "── A. inconclusive verdict + own-sid witness ON MAIN → archived done [red-oracle: neutered leaves it parked] ──"
R="$(mkfix onmain)"; OUT="$(run_afp "$R" "STUB_VERDICT=inconclusive STUB_SID=$SID")"
archived "$R" && ok "A archived on-main work despite inconclusive" || no "A" "not archived ($OUT)"
printf '%s' "$OUT" | grep -q 'crashed/parked before clean completion' && ok "A message explains the crash-after-merge archive" || no "A msg" "missing explanation"
rm -rf "$R"

echo "── B. inconclusive + witness NOT on main → stays parked (work not landed) ──"
R="$(mkfix offmain)"; run_afp "$R" "STUB_VERDICT=inconclusive STUB_SID=$SID" >/dev/null
parked "$R" && ok "B off-main witness → parked" || no "B" "archived work that isn't on main!"; rm -rf "$R"

echo "── C. inconclusive + NO witness → stays parked (normal inconclusive) ──"
R="$(mkfix none)"; run_afp "$R" "STUB_VERDICT=inconclusive STUB_SID=$SID" >/dev/null
parked "$R" && ok "C no witness → parked" || no "C" "archived without a witness!"; rm -rf "$R"

echo "── D. opt-out V_PACK_WITNESS_ARCHIVE=0 + witness on main → stays parked ──"
R="$(mkfix onmain)"; run_afp "$R" "STUB_VERDICT=inconclusive STUB_SID=$SID V_PACK_WITNESS_ARCHIVE=0" >/dev/null
parked "$R" && ok "D opt-out honored" || no "D" "archived despite opt-out"; rm -rf "$R"

echo "── E. witness on main BUT gauntlet verdict FAILS → stays parked (FALSE-DONE backstop still bites) ──"
R="$(mkfix onmain)"; run_afp "$R" "STUB_VERDICT=inconclusive STUB_SID=$SID STUB_GNF=1" >/dev/null
parked "$R" && ok "E explicit-FAIL not archived" || no "E" "archived over a FAIL verdict!"; rm -rf "$R"

echo "── F. timeout verdict + witness on main → archived (covers any parking verdict, not just inconclusive) ──"
R="$(mkfix onmain)"; run_afp "$R" "STUB_VERDICT=timeout STUB_SID=$SID" >/dev/null
archived "$R" && ok "F timeout+on-main → archived" || no "F" "not archived on timeout verdict"; rm -rf "$R"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
