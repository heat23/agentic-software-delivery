#!/usr/bin/env bash
# p1e-free-telemetry-test.sh — P1-E free interactive telemetry (2026-07-03).
#
# The pack lane's capture_telemetry proved session-logging is pure bash; the interactive lane
# still burned model turns (the /v-session-log fork). P1E moves the capture INTO the Stop hook:
#   LAYER-4 gap + autogen succeeds        → canonical log exists, no warn/marker round, 0 model tokens
#   LAYER-4 gap + light-tier diff         → SESSION_LOG_MISSING marker written, telemetry satisfied, no autogen
#   LAYER-4 gap + autogen fails           → existing warn/marker path UNCHANGED
#   V_SL_AUTOGEN=0                        → both branches off (dial)
#   TRIVIAL exit path                     → P1E-TRIVIAL-MARKER block present + writes the marker
#
# Executes the LAYER-4 block EXTRACTED VERBATIM from the production hook (sessionlog-warn-gate-test
# idiom), with the autogen + classifier stubbed via their env seams (V_SL_AUTOGEN_SCRIPT /
# V_LIGHT_TIER_CLASSIFIER). RED ORACLE: V_CRA_OVERRIDE=<pre-p1e bak> → P1E blocks absent → fails.
set -u
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO hook missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

L4="$(awk '/=== LAYER-4: SESSION-LOG TELEMETRY/,/=== end LAYER-4 session-log telemetry/' "$HOOK")"
echo "== P1-E :: free telemetry in the Stop hook =="
printf '%s' "$L4" | grep -q 'P1E-FREE-TELEMETRY' \
  && ok "P1E-FREE-TELEMETRY block present inside LAYER-4" \
  || no "P1E block absent from LAYER-4 (pre-P1E = RED)" ""

# Stubs
AUTOGEN_OK="$WORK/autogen-ok.sh"
cat > "$AUTOGEN_OK" <<EOF
#!/usr/bin/env bash
# simulates a successful pure-bash autogen: writes the canonical log where the caller cd'd to
printf 'schema: v2\n' > "\$PWD/SESSION_LOG_\${1}.yaml"
exit 0
EOF
chmod +x "$AUTOGEN_OK"
AUTOGEN_FAIL="$WORK/autogen-fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$AUTOGEN_FAIL"; chmod +x "$AUTOGEN_FAIL"
LIGHT_YES="$WORK/light-yes.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=1"\n' > "$LIGHT_YES"; chmod +x "$LIGHT_YES"
LIGHT_NO="$WORK/light-no.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=0"\n' > "$LIGHT_NO"; chmod +x "$LIGHT_NO"
# Real v-classify-light-tier.sh output is multiple lines (LIGHT=/REASON=/CLASS=/FILES=/TEST_FILES=/
# LINES=); the single-line LIGHT_YES stub above never exercises the SIGPIPE-under-pipefail race that
# a multi-line producer piped into `grep -q` can hit (bonus fix, 2026-08-19: found live at ~66%
# failure with this realistic shape, while the single-line stub passed 10/10 against the SAME
# vulnerable code — a real coverage gap in this suite's own fixture, not just the production bug).
LIGHT_YES_REALISTIC="$WORK/light-yes-realistic.sh"
printf '#!/usr/bin/env bash\necho "LIGHT=1"\necho "REASON=trivial config tweak"\necho "CLASS=config"\necho "FILES=1"\necho "TEST_FILES=0"\necho "LINES=4"\n' > "$LIGHT_YES_REALISTIC"
chmod +x "$LIGHT_YES_REALISTIC"

run_l4() { # $1=autogen-stub $2=light-stub $3=V_SL_AUTOGEN → globals LAST_RC, ROOT, ERRF
  ROOT="$WORK/r$$-$RANDOM"; mkdir -p "$ROOT/.v/tmp"
  ERRF="$ROOT/err.txt"; MKR="$ROOT/marker.flag"
  echo "deadbeefcommitsha" > "$ROOT/.v/tmp/commits-p1e-sid.txt"
  (
    set +eu
    # pipefail ON (bonus fix, 2026-08-19): production check-review-artifact.sh runs under
    # `set -euo pipefail` (line 12) — without pipefail here too, this subshell's eval'd LAYER-4
    # block can NEVER exercise the SIGPIPE-under-pipefail class (case 2b below would pass 20/20
    # even against the confirmed-vulnerable pre-fix code with this omitted — verified live). -e/-u
    # deliberately stay OFF (the extracted block references orchestrator globals this harness does
    # not fully replicate); pipefail alone is safe to add — it only changes pipeline exit-status
    # semantics, never aborts execution on its own.
    set -o pipefail
    SESSION_ID="p1e-sid"; MAIN_ROOT="$ROOT"; REPO_ROOT="$ROOT"; V_TMP_DIR_RESOLVED="$ROOT/.v/tmp"
    IS_V_SESSION=1; IS_V_INVOCATION_VIA_HISTORY=0
    V_SL_AUTOGEN="$3"; V_SL_AUTOGEN_SCRIPT="$1"; V_LIGHT_TIER_CLASSIFIER="$2"
    unset V_SESSION_LOG_GATE
    _cra_block_gate(){ return 0; }
    _cra_write_skipped_marker(){ : > "$MKR"; }
    eval "$L4"
  ) >/dev/null 2>"$ERRF"
  LAST_RC=$?
}

# 1. autogen success ⇒ canonical log written by pure bash; NO gap warning at all
run_l4 "$AUTOGEN_OK" "$LIGHT_NO" 1
{ [ "$LAST_RC" -eq 0 ] && [ -f "$ROOT/SESSION_LOG_p1e-sid.yaml" ] && grep -q 'P1E: session-log auto-generated' "$ERRF" && ! grep -qi 'telemetry gap' "$ERRF"; } \
  && ok "gap + autogen OK ⇒ canonical log on disk, zero model tokens, no gap warning" \
  || no "autogen-success path broken" "rc=$LAST_RC log=$([ -f "$ROOT/SESSION_LOG_p1e-sid.yaml" ] && echo yes || echo NO) err=$(head -1 "$ERRF" 2>/dev/null)"

# 2. light-tier ⇒ MISSING marker, satisfied, autogen NOT invoked
run_l4 "$AUTOGEN_FAIL" "$LIGHT_YES" 1
{ [ "$LAST_RC" -eq 0 ] && [ -f "$ROOT/SESSION_LOG_MISSING_p1e-sid.md" ] && ! grep -qi 'telemetry gap' "$ERRF"; } \
  && ok "gap + light-tier ⇒ SESSION_LOG_MISSING marker written, satisfied, no autogen needed" \
  || no "light-tier marker path broken" "rc=$LAST_RC mkr=$([ -f "$ROOT/SESSION_LOG_MISSING_p1e-sid.md" ] && echo yes || echo NO)"

# 2b (bonus fix, 2026-08-19): SAME scenario as #2, but with the REALISTIC multi-line classifier
# output shape, repeated 20x. A single run of the vulnerable SIGPIPE-under-pipefail pattern only
# fails ~2/3 of the time (probabilistic race) — 20 consecutive successes deterministically proves
# immunity (0.34^20 chance of a false pass), while the buggy pattern reliably fails within a few
# iterations. Must NOT be conflated with case #2's single-line stub, which cannot detect this class.
_p1e_2b_fail=0
for _p1e_i in $(seq 1 20); do
  run_l4 "$AUTOGEN_FAIL" "$LIGHT_YES_REALISTIC" 1
  { [ "$LAST_RC" -eq 0 ] && [ -f "$ROOT/SESSION_LOG_MISSING_p1e-sid.md" ] && ! grep -qi 'telemetry gap' "$ERRF"; } || _p1e_2b_fail=$((_p1e_2b_fail+1))
done
[ "$_p1e_2b_fail" -eq 0 ] \
  && ok "gap + light-tier, REALISTIC multi-line classifier output, 20x ⇒ marker written every time (no SIGPIPE-under-pipefail flake)" \
  || no "light-tier marker path flaked under the realistic multi-line classifier shape (SIGPIPE-under-pipefail class)" "${_p1e_2b_fail}/20 iterations failed"

# 3. autogen fails ⇒ existing warn/marker path unchanged (default warn mode)
run_l4 "$AUTOGEN_FAIL" "$LIGHT_NO" 1
{ [ "$LAST_RC" -eq 0 ] && grep -qi 'telemetry gap' "$ERRF" && [ -f "$ROOT/marker.flag" ]; } \
  && ok "gap + autogen FAILS ⇒ falls through to the existing warn + durable marker path" \
  || no "fallback path broken" "rc=$LAST_RC err=$(head -1 "$ERRF" 2>/dev/null)"

# 4. dial off ⇒ neither branch runs; legacy behavior exactly
run_l4 "$AUTOGEN_OK" "$LIGHT_YES" 0
{ [ "$LAST_RC" -eq 0 ] && [ ! -f "$ROOT/SESSION_LOG_p1e-sid.yaml" ] && [ ! -f "$ROOT/SESSION_LOG_MISSING_p1e-sid.md" ] && grep -qi 'telemetry gap' "$ERRF"; } \
  && ok "V_SL_AUTOGEN=0 ⇒ P1E fully off, legacy warn path only" \
  || no "dial did not disable P1E" "rc=$LAST_RC"

# 4b. NO commits witness + code changed ⇒ P2-NO-SILENT-HOLE marker (raw-/v-paste class)
ROOT="$WORK/nowit"; mkdir -p "$ROOT/.v/tmp"   # NO commits-<sid>.txt
(
  set +eu
  SESSION_ID="p1e-nowit-sid"; MAIN_ROOT="$ROOT"; REPO_ROOT="$ROOT"; V_TMP_DIR_RESOLVED="$ROOT/.v/tmp"
  IS_V_SESSION=1; IS_V_INVOCATION_VIA_HISTORY=0; CODE_CHANGED=1
  V_SL_AUTOGEN=0
  _cra_block_gate(){ return 0; }
  _cra_write_skipped_marker(){ :; }
  eval "$L4"
) >/dev/null 2>&1
grep -q 'P2-NO-SILENT-HOLE' "$ROOT/SESSION_LOG_MISSING_p1e-nowit-sid.md" 2>/dev/null \
  && ok "no-witness code-changing session ⇒ SESSION_LOG_MISSING marker (invisible-hole class closed)" \
  || no "no-witness marker not written (pre-P2 = RED)" "$(ls "$ROOT" 2>/dev/null | head -3)"
# ...and a session that DID log gets no marker (no false MISSING)
ROOT="$WORK/nowit2"; mkdir -p "$ROOT/.v/tmp"; touch "$ROOT/SESSION_LOG_p1e-nowit2-sid.yaml"
(
  set +eu
  SESSION_ID="p1e-nowit2-sid"; MAIN_ROOT="$ROOT"; REPO_ROOT="$ROOT"; V_TMP_DIR_RESOLVED="$ROOT/.v/tmp"
  IS_V_SESSION=1; IS_V_INVOCATION_VIA_HISTORY=0; CODE_CHANGED=1
  V_SL_AUTOGEN=0
  _cra_block_gate(){ return 0; }
  _cra_write_skipped_marker(){ :; }
  eval "$L4"
) >/dev/null 2>&1
[ ! -f "$ROOT/SESSION_LOG_MISSING_p1e-nowit2-sid.md" ] \
  && ok "logged no-witness session gets NO marker (no false MISSING — the split-brain class)" \
  || no "false MISSING marker on a logged session" ""

# 5. TRIVIAL exit path carries the marker block (structural + behavioral via extraction)
TRV="$(awk '/=== P1E-TRIVIAL-MARKER/,/=== end P1E-TRIVIAL-MARKER/' "$HOOK")"
if [ -z "$TRV" ]; then
  no "P1E-TRIVIAL-MARKER block present at the trivial exit (pre-P1E = RED)" ""
else
  ok "P1E-TRIVIAL-MARKER block present at the trivial exit"
  TROOT="$WORK/triv"; mkdir -p "$TROOT"
  (
    set +eu
    SESSION_ID="p1e-triv-sid"; REPO_ROOT="$TROOT"
    eval "$TRV"
  ) >/dev/null 2>&1
  grep -q 'TRIVIAL_PASS session (P1E)' "$TROOT/SESSION_LOG_MISSING_p1e-triv-sid.md" 2>/dev/null \
    && ok "trivial exit writes the SESSION_LOG_MISSING marker (silent hole closed)" \
    || no "trivial marker not written" "$(ls "$TROOT" 2>/dev/null)"
  # idempotent: an existing canonical log suppresses the marker
  TROOT2="$WORK/triv2"; mkdir -p "$TROOT2"; touch "$TROOT2/SESSION_LOG_p1e-triv-sid.yaml"
  (
    set +eu
    SESSION_ID="p1e-triv-sid"; REPO_ROOT="$TROOT2"
    eval "$TRV"
  ) >/dev/null 2>&1
  [ ! -f "$TROOT2/SESSION_LOG_MISSING_p1e-triv-sid.md" ] \
    && ok "existing canonical log suppresses the trivial marker (no false MISSING)" \
    || no "marker written despite existing log — false MISSING (the split-brain class)" ""
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
