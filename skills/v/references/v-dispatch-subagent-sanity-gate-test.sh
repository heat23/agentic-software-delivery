#!/usr/bin/env bash
# v-dispatch-subagent-sanity-gate-test.sh — E3 (efficiency, 2026-07-05): cheap MECHANICAL
# post-dispatch sanity gate. Extracts the REAL "E3-SANITY" block verbatim from
# v-dispatch-subagent.sh (between the `=== E3-SANITY ===` / `=== end E3-SANITY ===` markers,
# same extraction convention as v-dispatch-acting-as-test.sh's §17c test) and executes it in
# isolation against synthetic ARTIFACT/git fixtures, proving:
#   - a plausible artifact (Changed: N>0, or Changed:0 with few dirty files) -> no warning
#   - "Changed: 0" claimed while a git repo has a LOT of dirty entries -> DISPATCH_SANITY_WARN (default)
#   - the same implausible claim with V_DISPATCH_SANITY_STRICT=1 -> hard reject (exit 8),
#     artifact preserved under $V_TMP as rejected-*
#   - an OPTIONAL V_DISPATCH_EXPECT_MODE mismatch with no disclosed divergence -> WARN
#   - a mismatch that DOES self-disclose "(requested: ...)" -> no warning (F9-2 legitimate path)
set -u
SRC="${V_DISPATCH_SUBAGENT_SCRIPT:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
[ -f "$SRC" ] || { echo "SKIP: missing $SRC"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

BLOCK=$(sed -n '/# === E3-SANITY (efficiency/,/# === end E3-SANITY ===/p' "$SRC")
if [ -z "$BLOCK" ]; then
  no "E3-SANITY block present in $SRC (RED — extraction found nothing)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "E3-SANITY block extracted from the real v-dispatch-subagent.sh"

T1=$(mktemp -d); trap 'rm -rf "$T1"' EXIT
V_TMP="$T1/vtmp"; mkdir -p "$V_TMP"

# A dirty repo fixture: N untracked files -> N `git status --porcelain` entries.
mk_dirty_repo() {  # <dir> <n_dirty_files>
  local dir="$1" n="$2" i
  mkdir -p "$dir"
  git -C "$dir" init -q -b main >/dev/null 2>&1
  git -C "$dir" config user.email t@t; git -C "$dir" config user.name t
  echo base > "$dir/base.txt"; git -C "$dir" add -A >/dev/null 2>&1; git -C "$dir" commit -qm init >/dev/null 2>&1
  for i in $(seq 1 "$n"); do echo "x" > "$dir/dirty-$i.txt"; done
}

run_block() {  # <artifact_path> <art_dir> <prov_main_root> [expect_mode] [strict]
  local art="$1" artdir="$2" root="$3" expect="${4:-}" strict="${5:-}"
  ( set -e
    ARTIFACT="$art"; ART_DIR="$artdir"; PROV_MAIN_ROOT="$root"
    AGENT="v-verify-done-runner"; V_TMP="$V_TMP"; DURATION=""
    trace_event() { :; }; emit_marker() { :; }   # stubs — these helpers live earlier in the real script
    [ -n "$expect" ] && export V_DISPATCH_EXPECT_MODE="$expect" || unset V_DISPATCH_EXPECT_MODE 2>/dev/null
    [ -n "$strict" ] && export V_DISPATCH_SANITY_STRICT="$strict" || unset V_DISPATCH_SANITY_STRICT 2>/dev/null
    eval "$BLOCK"
    exit 0
  )
}

# ── T1: plausible artifact (Changed: 3, few/no dirty files) -> no warning ──
R1="$T1/repo1"; mk_dirty_repo "$R1" 1
A1="$T1/VERIFY_DONE_REPORT_t1.md"; printf 'Mode: full\nChanged: 3\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$A1"
OUT1="$(run_block "$A1" "$T1" "$R1")"; RC1=$?
if [ "$RC1" -eq 0 ] && ! printf '%s' "$OUT1" | grep -q DISPATCH_SANITY_WARN; then
  ok "T1 plausible Changed:3 claim -> no sanity warning"
else
  no "T1 plausible claim wrongly warned" "rc=$RC1 out=$OUT1"
fi

# ── T2: "Changed: 0" but repo has only 2 dirty files (below the >=10 threshold) -> no warning ──
R2="$T1/repo2"; mk_dirty_repo "$R2" 2
A2="$T1/VERIFY_DONE_REPORT_t2.md"; printf 'Mode: scoped(writes-log)\nChanged: 0\n\n## Summary\nnothing changed\n\nOverall Verdict: PASS\n' > "$A2"
OUT2="$(run_block "$A2" "$T1" "$R2")"; RC2=$?
if [ "$RC2" -eq 0 ] && ! printf '%s' "$OUT2" | grep -q DISPATCH_SANITY_WARN; then
  ok "T2 Changed:0 with only a couple dirty files -> no warning (below implausibility threshold)"
else
  no "T2 low dirty-count wrongly warned" "rc=$RC2 out=$OUT2"
fi

# ── T3 (the flagship motivating case): "Changed: 0, all tests pass" while DOZENS are dirty -> WARN ──
R3="$T1/repo3"; mk_dirty_repo "$R3" 24
A3="$T1/VERIFY_DONE_REPORT_t3.md"; printf 'Mode: full\nChanged: 0\n\n## Summary\nall tests pass, 0 files changed\n\nOverall Verdict: PASS\n' > "$A3"
OUT3="$(run_block "$A3" "$T1" "$R3")"; RC3=$?
if [ "$RC3" -eq 0 ] && printf '%s' "$OUT3" | grep -q "DISPATCH_SANITY_WARN=artifact claims 'Changed: 0'"; then
  ok "T3 flagship case (Changed:0 vs 24 dirty entries) -> DISPATCH_SANITY_WARN emitted, rc unaffected by default"
else
  no "T3 flagship implausible-claim case did not warn as expected" "rc=$RC3 out=$OUT3"
fi

# ── T4: same T3 fixture, but V_DISPATCH_SANITY_STRICT=1 -> hard reject (exit 8), artifact preserved ──
A4="$T1/VERIFY_DONE_REPORT_t4.md"; printf 'Mode: full\nChanged: 0\n\n## Summary\nall tests pass, 0 files changed\n\nOverall Verdict: PASS\n' > "$A4"
OUT4="$(run_block "$A4" "$T1" "$R3" "" "1")"; RC4=$?
if [ "$RC4" -eq 8 ] && [ ! -s "$A4" -o ! -f "$A4" ] && ls "$V_TMP"/rejected-VERIFY_DONE_REPORT_t4.md.*.md >/dev/null 2>&1; then
  ok "T4 STRICT mode -> hard reject (exit 8), original artifact path emptied/moved, rejected copy preserved under \$V_TMP"
else
  no "T4 STRICT mode did not hard-reject as expected" "rc=$RC4 out=$OUT4 artifact_exists=$([ -s "$A4" ] && echo yes || echo no)"
fi

# ── T5: V_DISPATCH_EXPECT_MODE mismatch, NO disclosed divergence -> WARN ──
A5="$T1/VERIFY_DONE_REPORT_t5.md"; printf 'Mode: scoped(writes-log)\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$A5"
OUT5="$(run_block "$A5" "$T1" "$R2" "full")"; RC5=$?
if [ "$RC5" -eq 0 ] && printf '%s' "$OUT5" | grep -q "does not match the requested mode 'full'"; then
  ok "T5 silent mode mismatch (expected full, got scoped) -> DISPATCH_SANITY_WARN"
else
  no "T5 silent mode mismatch did not warn as expected" "rc=$RC5 out=$OUT5"
fi

# ── T6: V_DISPATCH_EXPECT_MODE mismatch WITH disclosed divergence (F9-2 legitimate path) -> no WARN ──
A6="$T1/VERIFY_DONE_REPORT_t6.md"; printf 'Mode: scoped(writes-log) (requested: full — auto-downgraded per P1C-REVERIFY-SCOPE)\nChanged: 1\n\n## Summary\nok\n\nOverall Verdict: PASS\n' > "$A6"
OUT6="$(run_block "$A6" "$T1" "$R2" "full")"; RC6=$?
if [ "$RC6" -eq 0 ] && ! printf '%s' "$OUT6" | grep -q DISPATCH_SANITY_WARN; then
  ok "T6 DISCLOSED mode divergence (self-documented per F9-2) -> no warning (legitimate downgrade)"
else
  no "T6 disclosed divergence wrongly warned" "rc=$RC6 out=$OUT6"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
