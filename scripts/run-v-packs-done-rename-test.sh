#!/usr/bin/env bash
# run-v-packs-done-rename-test.sh — the DONE- completion-rename guard (2026-07-07).
#
# WHY: on a truly-clean finish (_rc==0) the runner renames the pack-run dir to DONE-<name>/ so a completed batch
# is obvious and is not re-scanned. That `mv` is cosmetic, but pointed at the wrong dir it is catastrophic — the
# runner can be aimed at ANY directory, so the rename MUST fire ONLY for a real, fully-finished pack-run dir and
# NEVER for a repo/home/worktree/fs root, an incomplete (exit≠0) run, an empty dir, a dry-run, or the opt-out.
# This suite drives the REAL _maybe_rename_done and the REAL _finish_report gate.
# RED-ORACLE: cases A and Z (rename happens on clean finish) FAIL against the pre-change runner (no rename at all);
# every guard case (B–H) also fails if a future edit drops a guard and over-renames.
# Portable bash 3.2/macOS: no mapfile, no arrays-of-arrays, no GNU-only tools.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

# Build a realistic pack-run dir under a fresh temp parent: <parent>/<name>/{.done,.runlogs,.needs-review}
# with N archived packs in .done/. Echoes the pack dir's absolute path.
mkpackdir(){ # $1=name  $2=done_count(default 1)
  local p n d; p="$(mktemp -d)"; n="${1:-batch}"; d="$p/$n"
  mkdir -p "$d/.done" "$d/.runlogs" "$d/.needs-review"
  local n_done="${2:-1}" i=1        # counter loop — avoids BSD `seq 1 0` emitting "1 0" (would create packs for count 0)
  while [ "$i" -le "$n_done" ]; do printf '/v do thing %s\n' "$i" > "$d/.done/PACK-$i.txt"; i=$((i+1)); done
  printf '%s' "$d"
}

# Call the REAL _maybe_rename_done against a given PACK_ABS. Args after path = env assignments.
run_rename(){ # $1=pack_abs  $2=env-string
  ( source "$RUNNER" >/dev/null 2>&1
    count_done(){ ls -1 "$PACK_ABS/.done" 2>/dev/null | grep -c '\.txt$' || echo 0; }
    PACK_ABS="$1"; REPO="__no_repo__"; DRY=0; ARCHIVE=1
    eval "${2:-}"
    _maybe_rename_done >/dev/null 2>&1 )
}
# renamed? → the DONE-<name> sibling exists AND the original is gone
renamed(){ local d="$1" base parent; base="$(basename "$d")"; parent="$(dirname "$d")"
  [ -d "$parent/DONE-$base" ] && [ ! -e "$d" ]; }

echo "── A. clean finish on a real pack-run dir → renamed to DONE-<name>/ [red-oracle: old runner never renames] ──"
D="$(mkpackdir batch-a 2)"; run_rename "$D" ""
renamed "$D" && ok "A renamed to DONE-batch-a" || no "A rename" "expected DONE- sibling, dir still at $D"
# ND-0716 CATASTROPHIC-CLEANUP FIX: the old first command here was
#   rm -rf "$(dirname "$(dirname "$D")")"
# — D is <mktemp-dir>/batch-a, so the GRANDPARENT is $TMPDIR itself (/var/folders/…/T).
# Every run of this harness wiped the machine's per-user temp dir, deleting sibling
# harnesses' fixtures and the harness-test-sweep result dir mid-flight (the "N produced
# no result" sweep failures since 2026-07-13). Delete ONLY the mktemp parent we created.
rm -rf "$(dirname "$D")" 2>/dev/null

echo "── B. already DONE- prefixed → left alone (idempotent) ──"
P="$(mktemp -d)"; D="$P/DONE-batch-b"; mkdir -p "$D/.done"; printf '/v x\n' > "$D/.done/P.txt"
run_rename "$D" ""
[ -d "$D" ] && [ ! -e "$P/DONE-DONE-batch-b" ] && ok "B no double-prefix" || no "B idempotent" "DONE- dir was re-renamed"
rm -rf "$P"

echo "── C. PACK_ABS == REPO (repo root) → NEVER renamed ──"
D="$(mkpackdir batch-c)"; run_rename "$D" "REPO='$D'"
[ -d "$D" ] && ok "C repo-root guard holds" || no "C repo-root" "renamed a repo root — CATASTROPHIC"
rm -rf "$(dirname "$D")"

echo "── D. a .git present (worktree/repo toplevel) → NEVER renamed ──"
D="$(mkpackdir batch-d)"; mkdir -p "$D/.git"; run_rename "$D" ""
[ -d "$D" ] && ok "D .git guard holds" || no "D dot-git" "renamed a git toplevel — CATASTROPHIC"
rm -rf "$(dirname "$D")"

echo "── E. PACK_ABS == \$HOME → NEVER renamed ──"
D="$(mkpackdir batch-e)"; run_rename "$D" "HOME='$D'"
[ -d "$D" ] && ok "E home-root guard holds" || no "E home-root" "renamed \$HOME — CATASTROPHIC"
rm -rf "$(dirname "$D")"

echo "── F. 0 archived packs (incidental/empty dir) → not renamed ──"
D="$(mkpackdir batch-f 0)"; run_rename "$D" ""
[ -d "$D" ] && ok "F empty-.done guard holds" || no "F no-packs" "renamed a dir with 0 archived packs"
rm -rf "$(dirname "$D")"

echo "── G. opt-out V_PACK_DONE_RENAME=0 → not renamed ──"
D="$(mkpackdir batch-g)"; run_rename "$D" "V_PACK_DONE_RENAME=0"
[ -d "$D" ] && ok "G opt-out honored" || no "G opt-out" "renamed despite V_PACK_DONE_RENAME=0"
rm -rf "$(dirname "$D")"

echo "── H. --dry-run (DRY=1) → not renamed ──"
D="$(mkpackdir batch-h)"; run_rename "$D" "DRY=1"
[ -d "$D" ] && ok "H dry-run guard holds" || no "H dry-run" "renamed under DRY=1"
rm -rf "$(dirname "$D")"

echo "── I. destination collision → not renamed, warns ──"
P="$(mktemp -d)"; D="$P/batch-i"; mkdir -p "$D/.done" "$P/DONE-batch-i"; printf '/v x\n' > "$D/.done/P.txt"
OUT="$( ( source "$RUNNER" >/dev/null 2>&1
  count_done(){ echo 1; }; PACK_ABS="$D"; REPO="__nr__"; DRY=0; ARCHIVE=1
  _maybe_rename_done 2>&1 ) )"
[ -d "$D" ] && printf '%s' "$OUT" | grep -q 'already exists' && ok "I collision safe + warned" || no "I collision" "clobbered or silent on existing DONE- dir"
rm -rf "$P"

echo "── Z. INTEGRATION: _finish_report clean (exit 0) renames; parked (exit 2) does NOT ──"
# clean: 0 left / 0 parked / 0 stranded → _rc 0 → _maybe_rename_done fires
D="$(mkpackdir batch-z 1)"
( source "$RUNNER" >/dev/null 2>&1
  count_left(){ echo 0; }; count_needs(){ echo 0; }; count_done(){ echo 1; }
  list_all_packs(){ :; }; _unlanded_branches(){ :; }
  PACK_ABS="$D"; LOG_DIR="$D/.runlogs"; DONE_DIR="$D/.done"; NEEDS_DIR="$D/.needs-review"
  REPO="__nr__"; DRY=0; ARCHIVE=1; ONCE=0; WAVE_BLOCKED=0; VERIFY_FAILED=0
  _finish_report >/dev/null 2>&1 ); _zrc=$?
renamed "$D" && ok "Z clean finish (exit $_zrc) renamed the dir" || no "Z clean rename" "exit $_zrc but dir not renamed"
# RUN_SUMMARY must have moved WITH the dir (written before the rename)
ZP="$(dirname "$D")"; ls "$ZP/DONE-batch-z/.runlogs/"RUN_SUMMARY_*.txt >/dev/null 2>&1 \
  && ok "Z RUN_SUMMARY moved with the renamed dir" || no "Z run-summary" "RUN_SUMMARY not inside DONE- dir"
rm -rf "$ZP"
# parked (needs=1) → _rc 2 → dir must remain (never rename an incomplete run)
D2="$(mkpackdir batch-z2 1)"
( source "$RUNNER" >/dev/null 2>&1
  count_left(){ echo 0; }; count_needs(){ echo 1; }; count_done(){ echo 1; }
  list_all_packs(){ :; }; _unlanded_branches(){ :; }
  PACK_ABS="$D2"; LOG_DIR="$D2/.runlogs"; DONE_DIR="$D2/.done"; NEEDS_DIR="$D2/.needs-review"
  REPO="__nr__"; DRY=0; ARCHIVE=1; ONCE=0; WAVE_BLOCKED=0; VERIFY_FAILED=0
  _finish_report >/dev/null 2>&1 ); _z2rc=$?
[ -d "$D2" ] && [ "$_z2rc" = 2 ] && ok "Z2 parked run (exit $_z2rc) NOT renamed" || no "Z2 incomplete guard" "exit $_z2rc, dir renamed despite outstanding work"
rm -rf "$(dirname "$D2")"

echo "── Y. REAL runner re-run of an already-complete dir (all packs in .done/, nothing queued) → renames to DONE- ──"
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  YR="$(mktemp -d)"; ( cd "$YR" && git init -q . && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  YD="$YR/audit-packs"; mkdir -p "$YD/.done" "$YD/.runlogs" "$YD/.needs-review"
  printf '/v already ran\n' > "$YD/.done/DONE-PACK.txt"        # an archived (completed) pack, nothing queued
  "$HOME/.local/bin/run-v-packs" "$YD" >/dev/null 2>&1; _yrc=$?
  if [ -d "$YR/DONE-audit-packs" ] && [ ! -e "$YD" ]; then ok "Y real re-run renamed → DONE-audit-packs (exit $_yrc)"
  else no "Y real re-run" "exit $_yrc, dir not renamed (still $YD)"; fi
  rm -rf "$YR"
else
  echo "  (skipped — git/jq unavailable)"
fi

echo "── W. acknowledged-quarantine pack still parked → _maybe_rename_done SELF-SKIPS (held work must stay visible) ──"
D="$(mkpackdir batch-w 1)"
printf '/v held pack\n' > "$D/.needs-review/seo-split.txt"
printf 'seo-split  # held for interactive completion\n' > "$D/.needs-review/.acknowledged"
run_rename "$D" ""
[ -d "$D" ] && ok "W acked-quarantine blocks the DONE- rename" || no "W ack-guard" "renamed away held work — buries acknowledged quarantine"
rm -rf "$(dirname "$D")"

echo "── X. INTEGRATION: real re-run of an already-complete dir with an ACKNOWLEDGED-quarantine pack → exit 0, NOT renamed ──"
if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  XR="$(mktemp -d)"; ( cd "$XR" && git init -q . && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  XD="$XR/held-packs"; mkdir -p "$XD/.done" "$XD/.runlogs" "$XD/.needs-review"
  printf '/v already ran\n' > "$XD/.done/DONE-PACK.txt"
  printf '/v held pack\n'   > "$XD/.needs-review/w1-review.txt"
  printf 'w1-review\n'      > "$XD/.needs-review/.acknowledged"
  _xo="$("$HOME/.local/bin/run-v-packs" "$XD" 2>&1)"; _xrc=$?
  [ "$_xrc" = 0 ] && ok "X exit 0 (acknowledged quarantine is non-blocking)" || no "X exit" "expected 0, got $_xrc"
  { [ -d "$XD" ] && [ ! -e "$XR/DONE-held-packs" ]; } && ok "X dir kept visible (not DONE-renamed)" || no "X rename" "buried held work under DONE-"
  printf '%s' "$_xo" | grep -qi 'acknowledged quarantine' && ok "X reports the held quarantine" || no "X message" "no held-quarantine notice"
  rm -rf "$XR"
else
  echo "  (skipped — git/jq unavailable)"
fi

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
