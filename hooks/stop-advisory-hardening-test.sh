#!/usr/bin/env bash
# stop-advisory-hardening-test.sh
# Version: 1.0.0 (W-ADVISORY-HARDENING, 2026-08-05)
#
# Covers three defects in the Stop hook's ADVISORY channel (non-blocking `WARNINGS`).
# All three were found by measuring the real corpus, not by reading the code.
#
# CORPUS EVIDENCE (34 sessions with advisories, 191 advisory emissions, 2026-07-25 .. 2026-08-05):
#
#   D1 NO IDEMPOTENCE — 106 of 191 emissions (55%) are BYTE-IDENTICAL replays of an advisory the
#      session already saw; ~88 KB / ~22k tokens of pure re-injection. Root cause: the Stop hook
#      fires on EVERY assistant turn, `CODE_CHANGED` is SESSION-cumulative (writes-log + commits
#      since the SessionStart head-baseline), and no advisory site tests "changed since last Stop".
#      Two advisories can NEVER clear in-session because they derive from append-only history
#      (V_MODEL_POLICY from the transcript's model records; the retired W-GATECONC from the
#      provenance log), so they re-fired on every Stop forever — one session emitted the
#      same pair 33 times, including on a turn whose only content was a user question.
#
#   D2 PRE_FLIGHT SIZE ADVISORY IGNORES ITS OWN PREDICATE — the hook computes
#      `_pf_has_gate_content` and uses it for the <1024B branch, then the 1024..3000B branch
#      ignores it and warns on size alone. 11 of 11 reports in that band carried 6-10 real gate
#      rows: a 100% false-positive rate. 96 emissions across 25 sessions.
#
#   D3 GATE-ROW COUNT ASSUMES VERDICT-FIRST COLUMN ORDER — the counting regex required the status
#      to be the FIRST table cell (`| PASS | Lint |`). v-run-gates.sh actually emits
#      `| # | Gate | Command | Result | Notes |` with the verdict in column 4. Specimen:
#      a real PRE_FLIGHT_REPORT specimen — 26,125 bytes, 10 fully-populated PASS rows — counted 0 and drew
#      "may be incomplete — fewer than 2 gate results found". 4 of 5 trips were false.
#      THIS IS THE SECOND OCCURRENCE OF THE SAME CLASS: W71-F13 (2026-07-02) already fixed a
#      CASE-SENSITIVITY variant of this exact regex for this exact symptom. Fixing the specific
#      shape and not the assumption is what made it recur, so the pattern below is now anchored on
#      "a table row with a verdict as a COMPLETE CELL, in any column" and pinned by both orders.
#
# WHAT MUST NOT CHANGE (asserted below):
#   - the BLOCKING path is never deduped — a blocked Stop always shows its warnings
#   - dedup fails OPEN: no SESSION_ID, no hash, or an unwritable state dir => emit
#   - <1024B with no gate content still BLOCKS (F8-b), never downgraded to a warning
#   - prose can never be counted as a gate row
#   - a report with genuinely <2 gate rows still warns (true positives preserved)
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
HOOK="${HOOK_UNDER_TEST:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

# Blocks are lifted VERBATIM from the file under test via sentinels, so harness/hook drift shows up
# as a behaviour failure rather than a silent false pass.
blk(){ awk "/# === $1 BEGIN/,/# === $1 END/" "$HOOK"; }

echo "== D1 :: advisory idempotence =="

if [ -z "$(blk W-ADVISORY-IDEM)" ]; then
  no "T1 W-ADVISORY-IDEM sentinel block present" "block defining the dedup" "not found (pre-fix = RED)"
else
  ok "T1 W-ADVISORY-IDEM sentinel block present"
fi

# Resolve the advisory block once under a given env; echoes stdout (the jq systemMessage or empty).
emit(){ # $1=warnings $2=session_id $3=tmpdir
  local s="$TMP/idem.sh"
  { printf 'V_TMP_DIR_RESOLVED=%q\nSESSION_ID=%q\nWARNINGS=%q\n' "$3" "$2" "$1"; blk W-ADVISORY-IDEM; } > "$s"
  ( set +u; bash "$s" 2>/dev/null )
}

D="$TMP/state"; mkdir -p "$D"
a1=$(emit $'\n  ⚠️ alpha' sid-1 "$D")
a2=$(emit $'\n  ⚠️ alpha' sid-1 "$D")
if [ -n "$a1" ] && [ -z "$a2" ]; then
  ok "T2 identical advisory on the next Stop is suppressed"
else
  no "T2 identical advisory suppressed on repeat" "first non-empty, second empty" "first='${a1:0:24}' second='${a2:0:24}'"
fi

a3=$(emit $'\n  ⚠️ alpha\n  ⚠️ beta' sid-1 "$D")
[ -n "$a3" ] && ok "T3 a CHANGED advisory set re-emits" \
             || no "T3 changed advisory set re-emits" "non-empty" "empty (new information was swallowed)"

a4=$(emit $'\n  ⚠️ alpha' sid-1 "$D")
[ -n "$a4" ] && ok "T4 reverting to a previously-seen set re-emits (only the LAST digest is held)" \
             || no "T4 revert re-emits" "non-empty" "empty"

# Fail-OPEN paths. Suppressing an advisory because bookkeeping broke is the unsafe direction.
b1=$(emit $'\n  ⚠️ gamma' "" "$D")
b2=$(emit $'\n  ⚠️ gamma' "" "$D")
if [ -n "$b1" ] && [ -n "$b2" ]; then
  ok "T5 no SESSION_ID -> always emits (fail-OPEN)"
else
  no "T5 no SESSION_ID fails open" "both non-empty" "first='${b1:0:16}' second='${b2:0:16}'"
fi

RO="$TMP/readonly"; mkdir -p "$RO"; chmod 500 "$RO"
c1=$(emit $'\n  ⚠️ delta' sid-2 "$RO/nested")
c2=$(emit $'\n  ⚠️ delta' sid-2 "$RO/nested")
chmod 700 "$RO" 2>/dev/null || true
if [ -n "$c1" ] && [ -n "$c2" ]; then
  ok "T6 unwritable state dir -> always emits (fail-OPEN)"
else
  no "T6 unwritable state dir fails open" "both non-empty" "first='${c1:0:16}' second='${c2:0:16}'"
fi

d1=$(emit $'\n  ⚠️ eps' sid-A "$D"); d2=$(emit $'\n  ⚠️ eps' sid-B "$D")
if [ -n "$d1" ] && [ -n "$d2" ]; then
  ok "T7 digest is per-SESSION (a sibling session is not silenced)"
else
  no "T7 digest is per-session" "both non-empty" "A='${d1:0:16}' B='${d2:0:16}'"
fi

# The dedup must live on the standalone advisory path ONLY. If the blocking variable is referenced
# in CODE inside the block, the blocking message is being gated by a digest — never acceptable.
# Comment lines are stripped first: the rationale legitimately NAMES the variable in prose, and
# grepping raw text made this assertion fail on its own documentation.
if blk W-ADVISORY-IDEM | sed 's/#.*//' | grep -q 'BLOCKING_ISSUES'; then
  no "T8 dedup never gates the BLOCKING path" "no BLOCKING_ISSUES reference inside the block" "found one"
else
  ok "T8 dedup never gates the BLOCKING path"
fi

echo
echo "== D2 :: pre-flight size advisory honours _pf_has_gate_content =="

size_case(){ # $1=bytes $2=has_gate_content -> prints WARN=y/n BLOCK=y/n
  local s="$TMP/sz.sh"
  { printf 'PREFLIGHT_FILE=/dev/null\n_pf_size=%q\n_pf_has_gate_content=%q\nWARNINGS=""\nBLOCKING_ISSUES=""\nMISSING_PREFLIGHT=0\n' "$1" "$2"
    blk W-PF-SIZE
    printf 'case "$WARNINGS" in *"between 1024B and 3000B"*) printf "WARN=y ";; *) printf "WARN=n ";; esac\n'
    printf 'case "$BLOCKING_ISSUES" in *"too small"*) printf "BLOCK=y";; *) printf "BLOCK=n";; esac\n'; } > "$s"
  ( set +u; bash "$s" 2>/dev/null )
}
if [ -z "$(blk W-PF-SIZE)" ]; then
  no "T9 W-PF-SIZE sentinel block present" "block present" "not found (pre-fix = RED)"
else
  ok "T9 W-PF-SIZE sentinel block present"
  r=$(size_case 2422 1)
  [ "$r" = "WARN=n BLOCK=n" ] && ok "T10 2422B WITH gate content -> no size warning (was 11/11 FP)" \
                              || no "T10 2422B with gate content" "WARN=n BLOCK=n" "$r"
  r=$(size_case 2422 0)
  [ "$r" = "WARN=y BLOCK=n" ] && ok "T11 2422B WITHOUT gate content -> still warns (signal preserved)" \
                              || no "T11 2422B without gate content" "WARN=y BLOCK=n" "$r"
  r=$(size_case 800 0)
  [ "$r" = "WARN=n BLOCK=y" ] && ok "T12 800B without gate content -> still BLOCKS (F8-b intact)" \
                              || no "T12 800B without gate content still blocks" "WARN=n BLOCK=y" "$r"
  r=$(size_case 800 1)
  case "$r" in WARN=n\ BLOCK=n) ok "T13 800B WITH gate content -> not blocked (Item-13 short-report path)";;
               *) no "T13 800B with gate content not blocked" "WARN=n BLOCK=n" "$r";; esac
  r=$(size_case 9000 1)
  [ "$r" = "WARN=n BLOCK=n" ] && ok "T14 9000B normal report -> silent" \
                              || no "T14 9000B normal report silent" "WARN=n BLOCK=n" "$r"
fi

echo
echo "== D3 :: gate-row counting is column-order agnostic =="

rows(){ # $1=file -> count using the hook's OWN extracted pattern
  local s="$TMP/rows.sh"
  { printf 'PREFLIGHT_FILE=%q\n' "$1"; blk W-PF-GATEROWS; printf 'printf "%%s" "$HAS_GATE_TABLE"\n'; } > "$s"
  ( set +u; bash "$s" 2>/dev/null )
}
if [ -z "$(blk W-PF-GATEROWS)" ]; then
  no "T15 W-PF-GATEROWS sentinel block present" "block present" "not found (pre-fix = RED)"
else
  ok "T15 W-PF-GATEROWS sentinel block present"

  # The real v-run-gates.sh skeleton: verdict in column 4.
  printf '| # | Gate | Command | Result | Notes |\n|---|---|---|---|---|\n| 1 | PHP test suite | `pest` | PASS | 1200 passed |\n| 2 | Frontend tests | `vitest` | PASS | ok |\n| 3 | Static analysis | `phpstan` | PASS | 0 errors |\n' > "$TMP/namefirst.md"
  n=$(rows "$TMP/namefirst.md")
  [ "${n:-0}" -ge 3 ] 2>/dev/null && ok "T16 name-first table (real runner shape) counts $n rows" \
                                  || no "T16 name-first table counted" ">=3" "${n:-<empty>}"

  # Backward compatibility: the legacy verdict-first shape must still count.
  printf '| PASS | Lint |\n| PASS | Build |\n' > "$TMP/verdictfirst.md"
  n=$(rows "$TMP/verdictfirst.md")
  [ "${n:-0}" -ge 2 ] 2>/dev/null && ok "T17 legacy verdict-first table still counts $n rows (no regression)" \
                                  || no "T17 verdict-first table counted" ">=2" "${n:-<empty>}"

  # Bold-wrapped verdict cells appear in real reports.
  printf '| 1 | Tests | x | **PASS** | y |\n| 2 | Build | x | **FAIL** | y |\n' > "$TMP/bold.md"
  n=$(rows "$TMP/bold.md")
  [ "${n:-0}" -ge 2 ] 2>/dev/null && ok "T18 bold-wrapped verdict cells count ($n)" \
                                  || no "T18 bold verdict cells counted" ">=2" "${n:-<empty>}"

  # NEGATIVE CONTROL — prose must never inflate the count (the guard W71-F13 installed).
  printf 'Passed: all unit tests ran fine.\nFAIL happened in the build earlier.\n- PASS: lint\nOverall Status: PASS\n' > "$TMP/prose.md"
  n=$(rows "$TMP/prose.md")
  [ "${n:-0}" -eq 0 ] 2>/dev/null && ok "T19 prose counts 0 (cannot silence a gate-less report)" \
                                  || no "T19 prose counts 0" "0" "${n:-<empty>}"

  # A genuinely thin report must still warn — true positives are preserved.
  printf '| Gate | Result |\n|---|---|\n| Tests | PASS |\n' > "$TMP/thin.md"
  n=$(rows "$TMP/thin.md")
  [ "${n:-0}" -lt 2 ] 2>/dev/null && ok "T20 single-row report still under threshold ($n < 2)" \
                                  || no "T20 single-row report under threshold" "<2" "${n:-<empty>}"

  # REGRESSION PIN on the real specimen, when it is still on disk.
  # Bounded glob, NOT `find $HOME/dev` — the unbounded walk cost 15s of which 10s was sys time
  # spent traversing node_modules, and this harness runs inside the vitest sweep.
  SPEC=""
  for _c in "$HOME"/dev/*/*/.v/artifacts/PRE_FLIGHT_REPORT_00000000*.md; do
    [ -f "$_c" ] && { SPEC="$_c"; break; }
  done
  if [ -n "$SPEC" ] && [ -f "$SPEC" ]; then
    n=$(rows "$SPEC")
    [ "${n:-0}" -ge 2 ] 2>/dev/null && ok "T21 REGRESSION PIN: real 26KB/10-gate specimen counts $n (was 0)" \
                                    || no "T21 real specimen counts >=2" ">=2" "${n:-<empty>}"
  else
    ok "T21 specimen absent from disk — pin skipped (not a failure)"
  fi
fi

echo
echo "== R1 :: W-GATECONC stays retired =="
# Retired 2026-08-05: the metric had NO discriminating power. Measured over 105 dispatch rounds in
# 47 sessions: the canonical known-serialized forensic (161s) sat at the 15th PERCENTILE
# — tighter than the median round (726s) — while 85% of all rounds exceeded the 90s threshold,
# including rounds verified by hand as correctly batched. No correct signal exists to rebuild it
# from: provenance `agent-tool` rows carry duration_ms=0 (0 of 235 usable, so overlap arithmetic is
# impossible), and the transcript cannot help either — 0 of 14,802 assistant records hold >=2
# tool_use blocks, i.e. the writer splits every tool call into its own record, so "agents dispatched
# per message" is unmeasurable there. Anything reintroducing a timestamp-spread detector must first
# defeat this evidence.
if grep -q 'GATE-SERIALIZATION' "$HOOK"; then
  no "T22 no timestamp-spread gate-serialization detector in the hook" \
     "retired (see header)" "GATE-SERIALIZATION re-appeared — read the retirement note before restoring"
else
  ok "T22 no timestamp-spread gate-serialization detector in the hook"
fi
if grep -q 'W-GATECONC RETIRED' "$HOOK"; then
  ok "T23 retirement rationale retained in-file (so it is not rebuilt from scratch)"
else
  no "T23 retirement rationale retained in-file" "'W-GATECONC RETIRED' note present" "missing"
fi

echo
echo "== D4 :: repeated BLOCK messages are compacted (blocking is never relaxed) =="
# WHY. A blocked session that is WAITING on in-flight gate dispatches re-Stops every turn and
# re-prints the identical ~4.4KB block message. Measured on one production session (the pasted
# transcript): 87 block messages, 63 of them CONSECUTIVE-IDENTICAL (72%), longest identical run
# 10 in a row, ~69k tokens of verbatim repetition in ONE session. Corpus-wide the blocking channel
# carries ~598k tokens of byte-identical repeats.
#
# WHAT IS COMPACTED: only the derived/static sections — the artifact BOARD, the static ONE-PASS
# ORDER, and the non-blocking WARNINGS. The session saw them moments ago and nothing changed.
# WHAT IS NEVER COMPACTED: the BLOCKING_ISSUES list itself, and the block itself (exit 2). The
# compaction is a MESSAGE-SIZE decision, never a gating decision — those are separable, and
# conflating them is how a "quieter" hook becomes a weaker one.
#
# COMPACTION-LOSS INSURANCE: the run is capped, so the full board/order reappear periodically even
# while nothing changes, and immediately on ANY change to the blocking set.
blkrun(){ # $1=issues $2=warnings $3=sid $4=tmpdir -> "MODE" per invocation
  local s="$TMP/blk.sh"
  { printf 'V_TMP_DIR_RESOLVED=%q\nSESSION_ID=%q\nBLOCKING_ISSUES=%q\nWARNINGS=%q\n' "$4" "$3" "$1" "$2"
    blk W-BLOCK-REPEAT
    printf 'printf "%%s" "${_blk_compact:-x}"\n'; } > "$s"
  ( set +u; bash "$s" 2>/dev/null )
}
if [ -z "$(blk W-BLOCK-REPEAT)" ]; then
  no "T24 W-BLOCK-REPEAT sentinel block present" "block present" "not found (pre-fix = RED)"
else
  ok "T24 W-BLOCK-REPEAT sentinel block present"
  D2="$TMP/blkstate"; mkdir -p "$D2"
  r1=$(blkrun "❌ alpha" "" sidB "$D2")
  r2=$(blkrun "❌ alpha" "" sidB "$D2")
  r3=$(blkrun "❌ alpha" "" sidB "$D2")
  [ "$r1" = "0" ] && ok "T25 first block emits FULL (compact=0)" \
                  || no "T25 first block emits full" "0" "$r1"
  { [ "$r2" = "1" ] && [ "$r3" = "1" ]; } && ok "T26 identical repeats are compacted" \
                  || no "T26 identical repeats compacted" "1 then 1" "$r2 then $r3"
  r4=$(blkrun "❌ alpha
❌ beta" "" sidB "$D2")
  [ "$r4" = "0" ] && ok "T27 a CHANGED blocking set immediately re-emits FULL" \
                  || no "T27 changed blocking set re-emits full" "0" "$r4"
  # Compaction-loss insurance: an unbroken identical run must periodically re-emit in full.
  D3="$TMP/blkstate2"; mkdir -p "$D3"; seq=""
  for _ in 1 2 3 4 5 6 7 8; do seq="${seq}$(blkrun "❌ same" "" sidC "$D3")"; done
  case "$seq" in
    *0*1*0*) ok "T28 an unbroken identical run re-emits FULL periodically (seq=$seq)" ;;
    *) no "T28 unbroken run re-emits full periodically" "a 0 must recur within the run" "seq=$seq" ;;
  esac
  # Warnings-only change must also re-emit: they ride in the same message.
  D4="$TMP/blkstate3"; mkdir -p "$D4"
  blkrun "❌ x" "⚠️ w1" sidD "$D4" >/dev/null
  r5=$(blkrun "❌ x" "⚠️ w2" sidD "$D4")
  [ "$r5" = "0" ] && ok "T29 a changed WARNING set re-emits FULL" \
                  || no "T29 changed warning set re-emits full" "0" "$r5"
  # FAIL-OPEN: no session id => never compact.
  f1=$(blkrun "❌ y" "" "" "$D2"); f2=$(blkrun "❌ y" "" "" "$D2")
  { [ "$f1" = "0" ] && [ "$f2" = "0" ]; } && ok "T30 no SESSION_ID -> never compacts (fail-OPEN)" \
                  || no "T30 no SESSION_ID fails open" "0 then 0" "$f1 then $f2"
  # The compaction must not be able to touch the block decision.
  if blk W-BLOCK-REPEAT | sed 's/#.*//' | grep -qE 'exit[[:space:]]+[02]|_cra_block_gate'; then
    no "T31 compaction never alters the block decision" "no exit/_cra_block_gate in the block" "found one"
  else
    ok "T31 compaction never alters the block decision (message size only)"
  fi

  # T32 — the deadlock-escape counter must be keyed on the VIOLATION, not the rendering.
  # rearm_gate() counts CONSECUTIVE identical fingerprints of whatever string it receives. Passing
  # the rendered $CTX coupled that safety counter to presentation: alternating full/compact renders
  # reset the counter and slipped the escape from block 3 to block 4. Regression guard: the gate
  # must be called with the stable basis, and that basis must NOT include the board/order sections.
  if grep -q '_cra_block_gate "\$_blk_fp_ctx"' "$HOOK"; then
    ok "T32 deadlock-escape gate is fed the stable violation fingerprint, not the rendered text"
  else
    no "T32 deadlock-escape gate fed the stable fingerprint" \
       '_cra_block_gate "$_blk_fp_ctx"' "still fingerprinting the rendered message (escape couples to rendering)"
  fi
  if blk W-BLOCK-FP | sed 's/#.*//' | grep -qE 'BOARD_SECTION|ORDER_SECTION'; then
    no "T33 stable fingerprint excludes the compactable sections" \
       "no BOARD_SECTION/ORDER_SECTION in the fingerprint basis" "found one — the coupling is back"
  else
    ok "T33 stable fingerprint excludes the compactable sections"
  fi
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
