#!/usr/bin/env bash
# run-v-packs-readonly-reconcile-test.sh — the READ-ONLY-VERIFY DEADLOCK BREAKER (2026-07-07).
#
# WHY: a read-only verify pack (/v-pre-flight, /v-verify-done — "Do NOT edit source") ships ZERO commits, so
# parking it can never be an unlanded-CODE dependency — yet the landing barrier (land_wave) counts ANY parked
# pack as blocking, so a read-only verify wave that legitimately FAILS / surfaces findings DEADLOCKS the fix
# wave meant to address them (observed live: a w1-pre-flight FAIL + w1-review both parked, permanently
# blocking w2-hardening; --resume just re-fails the pre-flight and re-parks). reconcile_parked_readonly
# archives such a pack ONCE its durable verify report proves the verification RAN, so it stops blocking —
# while a stalled read-only pack (no report) and any normal CODE pack (no read-only tag) stay PARKED.
# RED-ORACLE: the positive cases (A/B/C) fail against a runner with reconcile_parked_readonly neutered.
# Portable bash 3.2/macOS; requires jq (skips cleanly without it).
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "  (skipped — jq unavailable)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
# Build a temp world: <root>/{repo/.v/{artifacts,tmp}, packdir/{.needs-review,.done,.runlogs}} with a parked
# read-only pre-flight pack. $1=readonly tag {sidecar|marker|none}  $2=report {preflight|verifydone|agentreview|rootreport|none}
mkfix(){
  local root repo pd; root="$(mktemp -d)"; repo="$root/repo"; pd="$root/packdir"
  mkdir -p "$repo/.v/artifacts" "$repo/.v/tmp" "$pd/.needs-review" "$pd/.done" "$pd/.runlogs"
  printf '/v-pre-flight\n\nRead-only verification. Do NOT edit source.\n' > "$pd/.needs-review/w1-pre-flight.txt"
  printf '{"type":"result","subtype":"success","session_id":"%s","num_turns":0}\n' "$SID" > "$pd/.runlogs/w1-pre-flight.log"
  case "${1:-sidecar}" in
    sidecar) : > "$pd/.runlogs/w1-pre-flight.log.readonly" ;;
    marker)  : > "$repo/.v/tmp/pack-readonly-${SID}.marker" ;;
    none)    : ;;
  esac
  case "${2:-preflight}" in
    preflight)   printf 'FAIL: 2 pint\n' > "$repo/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" ;;
    verifydone)  printf '4 HIGH\n'       > "$repo/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md" ;;
    agentreview) printf '4 HIGH\n'       > "$repo/.v/artifacts/AGENT_REVIEW_${SID}.md" ;;
    rootreport)  printf 'FAIL: 2 pint\n' > "$repo/PRE_FLIGHT_REPORT_${SID}.md" ;;
    none)        : ;;
  esac
  printf '%s' "$root"
}
run_rc(){ # $1=root  $2=env assignments
  ( source "$RUNNER" >/dev/null 2>&1
    REPO="$1/repo"; LOG_DIR="$1/packdir/.runlogs"; NEEDS_DIR="$1/packdir/.needs-review"; DONE_DIR="$1/packdir/.done"
    eval "${2:-}"
    reconcile_parked_readonly >/dev/null 2>&1 )
}
archived(){ [ -f "$1/packdir/.done/w1-pre-flight.txt" ] && [ ! -e "$1/packdir/.needs-review/w1-pre-flight.txt" ]; }
parked(){   [ -f "$1/packdir/.needs-review/w1-pre-flight.txt" ] && [ ! -e "$1/packdir/.done/w1-pre-flight.txt" ]; }

echo "── A. read-only (sidecar) + PRE_FLIGHT_REPORT → archived [red-oracle: neutered runner leaves it parked] ──"
R="$(mkfix sidecar preflight)"; run_rc "$R" ""; archived "$R" && ok "A archived" || no "A" "not archived"; rm -rf "$R"

echo "── B. read-only via MARKER fallback (no sidecar) + VERIFY_DONE_REPORT → archived ──"
R="$(mkfix marker verifydone)"; run_rc "$R" ""; archived "$R" && ok "B archived via marker" || no "B" "not archived"; rm -rf "$R"

echo "── C. report at repo ROOT (legacy location) → archived ──"
R="$(mkfix sidecar rootreport)"; run_rc "$R" ""; archived "$R" && ok "C archived via root report" || no "C" "not archived"; rm -rf "$R"

echo "── D. NOT read-only (no tag) → stays PARKED (never archive code work here) ──"
R="$(mkfix none preflight)"; run_rc "$R" ""; parked "$R" && ok "D code pack stays parked" || no "D" "archived a non-readonly pack!"; rm -rf "$R"

echo "── E. read-only but NO report (stalled) → stays PARKED (fail-closed) ──"
R="$(mkfix sidecar none)"; run_rc "$R" ""; parked "$R" && ok "E stalled readonly stays parked" || no "E" "archived without a report!"; rm -rf "$R"

echo "── F. opt-out V_PACK_READONLY_RECONCILE=0 → stays PARKED ──"
R="$(mkfix sidecar preflight)"; run_rc "$R" "V_PACK_READONLY_RECONCILE=0"; parked "$R" && ok "F opt-out honored" || no "F" "archived despite opt-out"; rm -rf "$R"

echo "── G. ambiguous basename (2 runlogs across waves) → NOT archived (fail-closed attribution) ──"
R="$(mkfix sidecar preflight)"; mkdir -p "$R/packdir/.runlogs/wave2"; cp "$R/packdir/.runlogs/w1-pre-flight.log" "$R/packdir/.runlogs/wave2/w1-pre-flight.log"
run_rc "$R" ""; parked "$R" && ok "G ambiguous attribution → parked" || no "G" "archived under ambiguous attribution"; rm -rf "$R"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
