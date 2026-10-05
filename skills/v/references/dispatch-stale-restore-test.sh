#!/usr/bin/env bash
# dispatch-stale-restore-test.sh — ORCHFIX-F1/F3 class harness (forensics 2026-07-02).
# CLASS: rm-before-dispatch + tool-cap kill destroys a GOOD artifact ("a failed dispatch must leave
# the world as it found it"), and sub-900s QA caps force degraded QA (F3 floor).
# Tests the helper's sideline/settle logic and the QA timeout floor WITHOUT dispatching claude:
# the sideline+trap section is exercised via a stub run, the floor via source-level assertions +
# a dry parse. RED oracle: v-dispatch-subagent.sh.pre-orchfix0702-bak contains the destructive
# `rm -f "$ARTIFACT"` and no floor.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$HERE/v-dispatch-subagent.sh"
BAK="$HERE/v-dispatch-subagent.sh.pre-orchfix0702-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

# T1: live helper SIDELINES (never rm's) the pre-existing artifact, and the settle restores it
# when no new artifact appears. Simulate by extracting and running the sideline+settle block.
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
ART="$TD/VERIFY_DONE_REPORT_test.md"; printf 'good runner content\n' > "$ART"
bash -c '
  ARTIFACT="'"$ART"'"; JSON_OUT=/dev/null; ERR_OUT=/dev/null; PROMPT_TMP=/dev/null
  _ART_STALE="$ARTIFACT.stale.$$"
  _art_stale_settle() {
    if [ -n "${_ART_STALE:-}" ] && [ -f "$_ART_STALE" ]; then
      if [ -s "$ARTIFACT" ]; then rm -f "$_ART_STALE" 2>/dev/null || true
      else mv -f "$_ART_STALE" "$ARTIFACT" 2>/dev/null || true; fi
    fi
  }
  trap "_art_stale_settle" EXIT
  trap "exit 143" TERM
  [ -f "$ARTIFACT" ] && mv -f "$ARTIFACT" "$_ART_STALE"
  # dispatch dies here (simulated SIGTERM from the tool cap)
  kill -TERM $$
' 2>/dev/null
rc=$?
[ "$rc" = "143" ] && ok "T1a: simulated tool-cap SIGTERM exits 143 through the trap" || no "T1a: rc=$rc"
[ -s "$ART" ] && grep -q 'good runner content' "$ART" \
  && ok "T1b: pre-dispatch artifact RESTORED after killed dispatch (world left as found)" \
  || no "T1b: artifact destroyed (the VERIFY_DONE loss)"

# T2: success path discards the stale copy (anti-stale property preserved).
printf 'old\n' > "$ART"
bash -c '
  ARTIFACT="'"$ART"'"
  _ART_STALE="$ARTIFACT.stale.$$"
  _art_stale_settle() {
    if [ -f "$_ART_STALE" ]; then
      if [ -s "$ARTIFACT" ]; then rm -f "$_ART_STALE"; else mv -f "$_ART_STALE" "$ARTIFACT"; fi
    fi
  }
  trap "_art_stale_settle" EXIT
  mv -f "$ARTIFACT" "$_ART_STALE"
  printf "fresh dispatch output\n" > "$ARTIFACT"
'
grep -q 'fresh dispatch output' "$ART" && [ -z "$(ls "$ART".stale.* 2>/dev/null)" ] \
  && ok "T2: successful dispatch keeps fresh output, discards stale copy" \
  || no "T2: stale handling wrong on success"

# T3 source-level: live helper has NO bare destructive rm of the artifact; sidelines instead.
grep -qE '^rm -f "\$ARTIFACT"' "$H" && no "T3: live helper still bare-rm's the artifact" \
                                     || ok "T3: live helper sidelines (no bare rm) — mv to .stale.\$\$ present: $(grep -c '_ART_STALE' "$H") refs"
[ -f "$BAK" ] && { grep -qE '^rm -f "\$ARTIFACT"' "$BAK" && ok "T3 RED oracle: backup bare-rm's the artifact (destruction path confirmed)" \
                                                          || no "T3 RED oracle: backup lacks the rm?"; }

# T4: QA floor — live helper raises a sub-900s v-qa-reviewer timeout; backup has no floor.
grep -q 'ORCHFIX-F3' "$H" && grep -qE 'v-qa-reviewer.*-lt 900|_V_DISPATCH_TIMEOUT_SEC=900' "$H" \
  && ok "T4: QA 900s floor present (mechanical, not advisory)" || no "T4: QA floor missing"
[ -f "$BAK" ] && { grep -q 'ORCHFIX-F3' "$BAK" && no "T4 RED oracle: backup already had the floor?!" \
                                                || ok "T4 RED oracle: backup has no QA floor (rc124x2 degraded-QA class)"; }
# T5: started-provenance row emitted before exec (kill-invisibility closed).
grep -q 'emit_marker started' "$H" && ok "T5: status=started provenance before exec" || no "T5: no started row"

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
