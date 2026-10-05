#!/usr/bin/env bash
# v-remediate-stale-test.sh — Recommendation #2 remediation-script bite test (W-REMEDIATE-ORACLE).
#
# House style matches v-gauntlet-attest-source-staleness-test.sh: drives the REAL script
# end-to-end against stub HELPER/SUPERVISOR/EMIT_PROMPT/VALIDATION_LIB scripts (env-var injectable
# — see V_DISPATCH_HELPER / V_SUPERVISOR / V_EMIT_PROMPT / V_VALIDATION_LIB in the script under
# test), not an extracted fragment. REMEDIATE_UNDER_TEST lets this harness point at a pre-fix copy
# to prove RED before GREEN.
#
# Central assertion (T3): the ORIGINAL design's proxy — "every named artifact file is now
# non-empty" — is satisfiable by write_fallback_artifact()'s own template output. A pre-fix
# oracle using that proxy MUST pass T3's scenario (a non-empty FALLBACK stub); the real
# content-oracle fix MUST fail it.
#
# T7 (adversarial-code-review finding, 2026-08-17): a hand-rolled QA_REPORT verdict parser that
# does not strip quote/backtick/bold wrappers WRONGLY REJECTS a legitimately-passing
# `verdict: "pass"` report (an observed self-write shape — see hooks/lib/validation.sh's own
# comment on validate_qa_report_structure). This is the bug the code-review pass caught before
# ship; T7 proves the shipped script (which sources the real validator) handles it correctly.
set -u
SCRIPT="${REMEDIATE_UNDER_TEST:-$HOME/.claude/skills/v/references/v-remediate-stale.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-remediate-stale.sh missing: $SCRIPT"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
ART="$WORK/proj/.v/artifacts"
mkdir -p "$ART" "$WORK/stubs" "$WORK/tmp"
SID="11111111-2222-3333-4444-555555555555"

cat > "$WORK/stubs/v-emit-prompt.sh" <<'EOF'
#!/usr/bin/env bash
echo "DISPATCH PROMPT for $1"
EOF

cat > "$WORK/stubs/v-dispatch-subagent.sh" <<'EOF'
#!/usr/bin/env bash
ARTIFACT=""
while [ $# -gt 0 ]; do case "$1" in --artifact) ARTIFACT="$2"; shift 2 ;; *) shift ;; esac; done
base="$(basename "$ARTIFACT")"
[ -n "${V_TEST_DISPATCH_LOG:-}" ] && echo "$base" >> "$V_TEST_DISPATCH_LOG"
if [ "${STUB_MODE:-pass}" = "fail" ]; then exit 1; fi
case "$base" in
  PRE_FLIGHT_REPORT_*)  printf 'Model: haiku\n\nOverall Status: PASS\n' > "$ARTIFACT" ;;
  VERIFY_DONE_REPORT_*) printf 'Model: haiku\n\nOverall Verdict: PASS\n' > "$ARTIFACT" ;;
  panel-*)              printf 'Model: sonnet\nfindings: none\n' > "$ARTIFACT" ;;
  QA_REPORT_*)          printf '%b' "${STUB_QA_BODY:-Model: sonnet\n\n## QA Acceptance\nverdict: pass\n}" > "$ARTIFACT" ;;
  *)                    printf 'Model: sonnet\nverdict: pass\n' > "$ARTIFACT" ;;
esac
exit 0
EOF

# Writes the REAL write_fallback_artifact() templates verbatim (v-supervise-children.sh:92-159)
# on a failing child, so this test exercises the actual marker strings the script under test must
# reject — not a synthetic stand-in.
cat > "$WORK/stubs/v-supervise-children.sh" <<'EOF'
#!/usr/bin/env bash
CHILDREN=()
while [ $# -gt 0 ]; do
  case "$1" in
    --child) CHILDREN+=("$2"); shift 2 ;;
    --summary|--retry-transient|--max-concurrency) shift 2 ;;
    --fallback-artifacts) shift 2 ;;
    *) shift ;;
  esac
done
rc=0
for c in "${CHILDREN[@]}"; do
  name="${c%%::*}"; rest="${c#*::}"; rest="${rest#*::}"; artifact="${rest%%::*}"; cmd_file="${rest#*::}"
  bash "$cmd_file" >/dev/null 2>&1
  crc=$?
  if [ "$crc" -ne 0 ] && { [ ! -f "$artifact" ] || [ ! -s "$artifact" ]; }; then
    case "$(basename "$artifact")" in
      PRE_FLIGHT_REPORT_*.md)
        { echo "Model: haiku"; echo; echo "## Gates"; echo; echo "| Status | Gate | Detail |"; echo "|---|---|---|";
          echo "| FAIL | ${name} | supervised child exited ${crc}; see log |"; echo; echo "Overall Status: FAIL"; } > "$artifact" ;;
      VERIFY_DONE_REPORT_*.md)
        { echo "Model: haiku"; echo; echo "## Verify Done"; echo; echo "Overall Verdict: FAIL";
          echo "Reason: supervised child '${name}' exited ${crc}; see log"; } > "$artifact" ;;
      AGENT_REVIEW_*.md|panel-*)
        { echo "Model: sonnet"; echo; echo "## Agent Review"; echo "- Status: completed";
          echo "- Agents dispatched: ${name} (supervised-fallback)"; echo "- Dispatch mode: orchestrator_inline"; echo;
          echo "## Findings"; echo "- [HIGH] Supervised reviewer '${name}' exited ${crc} before producing findings. Do NOT treat this as approval."; } > "$artifact" ;;
      *)
        { echo "Model: haiku"; echo; echo "## Supervised Child Failure"; echo; echo "status: failed";
          echo "child: ${name}"; echo "exit_code: ${crc}"; } > "$artifact" ;;
    esac
    rc=1
  fi
done
exit $rc
EOF
chmod +x "$WORK"/stubs/*.sh

echo "a task for the test" > "$WORK/task.txt"

run_remediate() {  # $1=stale-list-path  $2=STUB_MODE(pass|fail)  [$3=STUB_QA_BODY]  -> echoes rc
  ( STUB_MODE="$2" STUB_QA_BODY="${3:-}" \
    V_DISPATCH_HELPER="$WORK/stubs/v-dispatch-subagent.sh" \
    V_SUPERVISOR="$WORK/stubs/v-supervise-children.sh" \
    V_EMIT_PROMPT="$WORK/stubs/v-emit-prompt.sh" \
    V_TMP_DIR="$WORK/tmp" \
    V_TEST_DISPATCH_LOG="$WORK/dispatch-calls.log" \
    bash "$SCRIPT" --stale-list "$1" --original-task-file "$WORK/task.txt" > "$WORK/out.$$.log" 2>"$WORK/err.$$.log" )
  echo $?
}

# run_remediate_no_task — same as run_remediate but WITHOUT --original-task-file (T10: the harness's
# only variant until now hardcoded the task file, so Bug 1b's actual repro path was structurally
# untested — every existing T1-T8 case is blind to it).
run_remediate_no_task() {  # $1=stale-list-path  $2=STUB_MODE(pass|fail) -> echoes rc
  ( STUB_MODE="$2" \
    V_DISPATCH_HELPER="$WORK/stubs/v-dispatch-subagent.sh" \
    V_SUPERVISOR="$WORK/stubs/v-supervise-children.sh" \
    V_EMIT_PROMPT="$WORK/stubs/v-emit-prompt.sh" \
    V_TMP_DIR="$WORK/tmp" \
    V_TEST_DISPATCH_LOG="$WORK/dispatch-calls.log" \
    bash "$SCRIPT" --stale-list "$1" > "$WORK/out.$$.log" 2>"$WORK/err.$$.log" )
  echo $?
}

echo "== v-remediate-stale.sh :: content-oracle + tiering =="

# T1: clean pass — 2 genuinely-independent-dispatchable artifacts, all succeed
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
: > "$ART/PRE_FLIGHT_REPORT_${SID}.md"; : > "$ART/VERIFY_DONE_REPORT_${SID}.md"
printf '%s\n%s\n' "$ART/PRE_FLIGHT_REPORT_${SID}.md" "$ART/VERIFY_DONE_REPORT_${SID}.md" > "$ART/stale1.txt"
rc1="$(run_remediate "$ART/stale1.txt" pass)"
[ "$rc1" = "0" ] && grep -q 'REMEDIATE|status=pass|artifacts_refreshed=2' "$WORK/out.$$.log" \
  && ok "clean dispatch of 2 independent artifacts -> status=pass, both refreshed" \
  || no "clean dispatch did not report status=pass" "rc=$rc1 $(tail -3 "$WORK/out.$$.log" 2>/dev/null)"

# T2: tiering — VERIFY_DONE_REPORT (tier 3) must not start before PRE_FLIGHT_REPORT (tier 1)
t1_line=$(grep -n 'Tier: tier1-preflight' "$WORK/err.$$.log" | head -1 | cut -d: -f1)
t3_line=$(grep -n 'Tier: tier3-verifydone' "$WORK/err.$$.log" | head -1 | cut -d: -f1)
if [ -n "${t1_line:-}" ] && [ -n "${t3_line:-}" ] && [ "$t1_line" -lt "$t3_line" ]; then
  ok "tier1 (PRE_FLIGHT) dispatched before tier3 (VERIFY_DONE) — dependency order preserved"
else
  no "tier ordering not observed (tier1 line=$t1_line, tier3 line=$t3_line)" "$(cat "$WORK/err.$$.log")"
fi

# T3 (CENTRAL): a child that FAILS, with --fallback-artifacts enabled, produces a NON-EMPTY
# write_fallback_artifact() stub. The OLD proxy ("file is non-empty") would report status=pass.
# The FIXED content-oracle must report status=fail and name the artifact.
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
rm -f "$ART/PRE_FLIGHT_REPORT_${SID}.md" "$ART/VERIFY_DONE_REPORT_${SID}.md"
rc3="$(run_remediate "$ART/stale1.txt" fail)"
_pf_bytes=$(wc -c < "$ART/PRE_FLIGHT_REPORT_${SID}.md" 2>/dev/null | tr -d ' ')
if [ "${_pf_bytes:-0}" -gt 0 ] && [ "$rc3" != "0" ] && grep -q 'REMEDIATE|status=fail' "$WORK/out.$$.log" 2>/dev/null; then
  ok "fallback stub is NON-EMPTY (${_pf_bytes}B — the exact proxy the old design trusted) yet script correctly reports status=fail, not pass"
else
  no "fallback-stub tamper case did not fail correctly" "rc=$rc3 bytes=${_pf_bytes:-0} $(tail -5 "$WORK/out.$$.log" 2>/dev/null)"
fi
grep -q "REJECT PRE_FLIGHT_REPORT_${SID}.md: matches write_fallback_artifact" "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null \
  && ok "rejection reason names the fallback-marker match specifically (not a generic failure)" \
  || no "rejection reason did not cite the fallback marker" "$(cat "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null | grep -i reject)"

# T4: IMPACT_MAP-only stale list -> MANUAL guidance, no crash, no false dispatch attempt
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
echo "$ART/IMPACT_MAP_${SID}.md" > "$ART/stale-impact.txt"
rc4="$(run_remediate "$ART/stale-impact.txt" pass)"
grep -qi 'orchestrator-authored' "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null \
  && grep -q 'status=manual-only' "$WORK/out.$$.log" 2>/dev/null \
  && ok "IMPACT_MAP-only stale list -> explicit MANUAL guidance, status=manual-only, no crash" \
  || no "IMPACT_MAP-only case mishandled" "rc=$rc4 $(cat "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null)"

# T5: unrecognized artifact basename -> hard error, never silently skipped or guessed
echo "$ART/SOME_UNKNOWN_THING_${SID}.md" > "$ART/stale-bad.txt"
rc5="$(run_remediate "$ART/stale-bad.txt" pass)"
[ "$rc5" = "2" ] && grep -qi 'unrecognized artifact' "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null \
  && ok "unrecognized artifact basename -> hard error (exit 2), not a silent skip" \
  || no "unrecognized artifact was not hard-rejected" "rc=$rc5"

# T6: missing --stale-list -> exit 2, does not fabricate a default location silently
rc6="$(run_remediate "/nonexistent-$$-stale-list.txt" pass)"
[ "$rc6" = "2" ] \
  && ok "missing stale-list file -> exit 2" \
  || no "missing stale-list did not exit 2" "rc=$rc6"

# T7 (code-review finding, 2026-08-17): QA_REPORT verdict value wrapped in quotes/backticks/bold —
# an observed self-write shape (hooks/lib/validation.sh's own comment: 'verdict: "fail" — observed
# shape from self-write QA reports'). A hand-rolled parser that only strips \r and spaces WRONGLY
# REJECTS this as "no recognized top verdict". The real validate_qa_report_structure() (sourced
# from hooks/lib/validation.sh) strips '"'"'"'"'*_` wrappers and must accept it as a clean pass.
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
echo "$ART/QA_REPORT_${SID}.md" > "$ART/stale-qa.txt"
# Padded to >=100 bytes (validate_qa_report_structure's own structural size floor) so this case
# isolates the quote-stripping behavior, not the unrelated minimum-size gate.
rc7="$(run_remediate "$ART/stale-qa.txt" pass 'Model: sonnet\n\n## QA Acceptance\nverdict: "pass"\nacceptance: the staged deliverable matches the original request and all iteration findings were resolved.\n')"
[ "$rc7" = "0" ] && grep -q 'REMEDIATE|status=pass' "$WORK/out.$$.log" 2>/dev/null \
  && ok "QA_REPORT verdict wrapped in quotes (verdict: \"pass\") is correctly accepted via the real validator" \
  || no "quote-wrapped QA verdict was wrongly rejected — the QA branch is not using the real validate_qa_report_structure()" \
       "rc=$rc7 $(cat "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null)"

# T7b (2026-10-01): the QA prompt T7 just dispatched must CARRY the original task. Before the fix the
# OT=/CF= assignments sat after `perl`, so perl read them as file names, printed nothing with rc 0, and
# QA was dispatched with an EMPTY prompt (QA then failed with "original request not supplied").
# \Q..\E in the replacement also turned "a task" into "a\ task".
_qa_prompt="$WORK/tmp/dispatch-${SID}-v-qa-reviewer.txt"
[ -s "$_qa_prompt" ] && grep -qF 'a task for the test' "$_qa_prompt" && ! grep -qF '{{ORIGINAL_TASK}}' "$_qa_prompt" \
  && ok "QA dispatch prompt is non-empty and carries the original task verbatim (no backslash-escaping, no placeholder left)" \
  || no "QA dispatch prompt lacks the original task" "bytes=$(wc -c < "$_qa_prompt" 2>/dev/null) $(grep -n 'task' "$_qa_prompt" 2>/dev/null | head -3)"

# T7c (code review M1/L5b, 2026-10-02): a task text holding $, @, backslashes, \E and BOTH placeholder tokens must reach
# the QA prompt byte for byte, and must not be refused. The two-pass substitution rewrote a {{CHANGED_FILES}} token
# inside the task, and a guard that grepped for {{ORIGINAL_TASK}} refused tasks that quote it.
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"; cp "$WORK/task.txt" "$WORK/task.txt.keep"
printf '%s' 'fix $HOME and @ARGV with C:\path\E plus {{CHANGED_FILES}} and {{ORIGINAL_TASK}} verbatim' > "$WORK/task.txt"
echo "$ART/QA_REPORT_${SID}.md" > "$ART/stale-qa-t7c.txt"
rc7c="$(run_remediate "$ART/stale-qa-t7c.txt" pass 'Model: sonnet\n\n## QA Acceptance\nverdict: pass\nacceptance: the staged deliverable matches the original request and all iteration findings were resolved in this iteration\n')"
_qa_prompt="$WORK/tmp/dispatch-${SID}-v-qa-reviewer.txt"
grep -qF 'fix $HOME and @ARGV with C:\path\E plus {{CHANGED_FILES}} and {{ORIGINAL_TASK}} verbatim' "$_qa_prompt" 2>/dev/null \
  && ok "hostile task text (\$, @, backslash, \\E, both tokens) reaches the QA prompt byte for byte and is not refused" \
  || no "hostile task text was altered or refused" "rc=$rc7c $(grep -n 'ARGV' "$_qa_prompt" 2>/dev/null | head -2)"
mv "$WORK/task.txt.keep" "$WORK/task.txt"

# T8: QA_REPORT missing the required '## QA Acceptance' heading -> structurally invalid, rejected
# (proves the real validator's OTHER checks are wired too, not just the verdict-line parse). Uses ITS
# OWN fresh stale-list file (not T7's stale-qa.txt) — with the mtime-freshness pre-dispatch skip
# (Bug 2 fix, 1.2), reusing T7's already-generated, already-PASSING stale-list could let this run
# treat the untouched QA_REPORT as "already refreshed by an earlier invocation" and skip dispatch
# entirely, leaving T7's PASSING content in place instead of exercising T8's malformed body at all.
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
echo "$ART/QA_REPORT_${SID}.md" > "$ART/stale-qa-t8.txt"
rc8="$(run_remediate "$ART/stale-qa-t8.txt" pass 'Model: sonnet\nverdict: pass\n')"
[ "$rc8" != "0" ] && grep -qi 'structurally invalid' "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null \
  && ok "QA_REPORT missing '## QA Acceptance' heading -> structurally invalid, rejected (not just verdict-line parsed)" \
  || no "QA_REPORT missing the required heading was not caught" "rc=$rc8 $(cat "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null)"


# T9 (Bug 1a, adversarial-review 2026-08-18): AGENT_REVIEW_<sid>.md is NEVER reported "ok" by this
# script — Tier 2 only ever writes panel-{correctness,repro,security}-<sid>.md, never the
# AGENT_REVIEW_<sid>.md file itself, so a pre-existing, untouched, well-formed AGENT_REVIEW must not
# read as "ok" (that would overclaim a step this script structurally cannot complete).
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
printf 'Model: sonnet\n\n## Agent Review\n- Status: completed\n\n## Findings\n- none\n' > "$ART/AGENT_REVIEW_${SID}.md"
echo "$ART/AGENT_REVIEW_${SID}.md" > "$ART/stale-t9.txt"
rc9="$(run_remediate "$ART/stale-t9.txt" pass)"
grep -q "AGENT_REVIEW_${SID}.md|ok" "$WORK/out.$$.log" 2>/dev/null \
  && no "T9 AGENT_REVIEW must never read 'ok' — Tier 2 cannot write that file" "rc=$rc9 $(cat "$WORK/out.$$.log" 2>/dev/null)" \
  || ok "T9 AGENT_REVIEW never reported 'ok' (Tier 2 structurally cannot complete it)"
grep -q "AGENT_REVIEW_${SID}.md|PARTIAL-stage1-only" "$WORK/out.$$.log" 2>/dev/null \
  && ok "T9 AGENT_REVIEW reported PARTIAL-stage1-only (accurate: panel stage-1 only, not the full artifact)" \
  || no "T9 AGENT_REVIEW should report PARTIAL-stage1-only" "$(cat "$WORK/out.$$.log" 2>/dev/null)"
grep -q 'status=pass' "$WORK/out.$$.log" 2>/dev/null \
  && no "T9 status must not be 'pass' when AGENT_REVIEW is in the stale set (only stage-1 panel dispatch happened)" "$(cat "$WORK/out.$$.log" 2>/dev/null)" \
  || ok "T9 status is not 'pass' when AGENT_REVIEW was in the stale set"

# T10 (Bug 1b, adversarial-review 2026-08-18): QA_REPORT stale but --original-task-file NOT supplied.
# Pre-seed a well-formed, PASSING, UNTOUCHED QA_REPORT (simulates a stale-but-still-parseable prior
# report already on disk). Pre-fix: Tier 4 prints "Skipping tier 4" and does nothing, but the closing
# verdict loop still ran the real validate_qa_report_structure() against whatever's ALREADY on disk —
# an untouched passing file read "ok" even though this invocation touched nothing. Post-fix: this
# invocation never attempted QA_REPORT (ATTEMPTED_QA stays 0); the artifact was never touched since
# before the stale-list was generated, so it reads "skipped", never "ok".
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
printf 'Model: sonnet\n\n## QA Acceptance\nverdict: pass\nacceptance: matches the request; all iteration findings were resolved.\n' > "$ART/QA_REPORT_${SID}.md"
sleep 1
echo "$ART/QA_REPORT_${SID}.md" > "$ART/stale-t10.txt"
rc10="$(run_remediate_no_task "$ART/stale-t10.txt" pass)"
grep -q "QA_REPORT_${SID}.md|ok" "$WORK/out.$$.log" 2>/dev/null \
  && no "T10 QA_REPORT falsely reported 'ok' when --original-task-file was never supplied (this run touched nothing)" "rc=$rc10 $(cat "$WORK/out.$$.log" 2>/dev/null)" \
  || ok "T10 QA_REPORT never reported 'ok' for an untouched stale file when tier 4 was skipped (no --original-task-file)"
grep -q 'status=pass' "$WORK/out.$$.log" 2>/dev/null \
  && no "T10 must not report status=pass when tier 4 was skipped and nothing was actually fixed" "$(cat "$WORK/out.$$.log" 2>/dev/null)" \
  || ok "T10 status is not 'pass' when QA_REPORT tier was skipped, not fixed"

# T11 (Bug 2, adversarial-review 2026-08-18): TWO SEQUENTIAL invocations against the SAME stale-list
# file naming only VERIFY_DONE_REPORT. Pre-fix: no cross-invocation memory — both calls dispatch.
# Post-fix: the second invocation finds the artifact already fresh (mtime strictly newer than the
# stale-list's own mtime, from the first call) and skips the redundant re-dispatch. The `sleep 1`
# guarantees real time separation between the stale-list's mtime and the artifact's write — this
# repo's own mtime helper is whole-second granularity (adversarial-review finding), so without this
# gap the two events can land in the same epoch second and the assertion would be non-deterministic.
rm -f "$WORK/dispatch-calls.log"
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
rm -f "$ART/VERIFY_DONE_REPORT_${SID}.md"
echo "$ART/VERIFY_DONE_REPORT_${SID}.md" > "$ART/stale-t11.txt"
sleep 1
run_remediate "$ART/stale-t11.txt" pass >/dev/null
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
run_remediate "$ART/stale-t11.txt" pass >/dev/null
_t11_count=$(grep -c "^VERIFY_DONE_REPORT_${SID}.md$" "$WORK/dispatch-calls.log" 2>/dev/null || echo 0)
[ "${_t11_count:-0}" = "1" ] \
  && ok "T11 two sequential invocations against the same stale-list -> VERIFY_DONE_REPORT dispatched exactly ONCE (redundant re-dispatch skipped)" \
  || no "T11 cross-invocation dedup failed — expected exactly 1 dispatch, got ${_t11_count:-0}" "$(cat "$WORK/dispatch-calls.log" 2>/dev/null)"

# T12 (adversarial-review 2026-08-18): if the mtime helper cannot stat $STALE_LIST at all (exotic
# filesystem / stat unavailable), the script must HARD-FAIL rather than silently default the
# reference mtime to 0 — a silent 0 would make EVERY artifact read as unconditionally "fresh",
# reintroducing Bug 1b's false-ok for every stale-but-untouched file.
rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp" "$WORK/stubs/nostat"
cat > "$WORK/stubs/nostat/stat" <<'STATEOF'
#!/usr/bin/env bash
exit 1
STATEOF
chmod +x "$WORK/stubs/nostat/stat"
echo "$ART/PRE_FLIGHT_REPORT_${SID}.md" > "$ART/stale-t12.txt"
rc12="$( ( STUB_MODE=pass PATH="$WORK/stubs/nostat:$PATH" \
    V_DISPATCH_HELPER="$WORK/stubs/v-dispatch-subagent.sh" \
    V_SUPERVISOR="$WORK/stubs/v-supervise-children.sh" \
    V_EMIT_PROMPT="$WORK/stubs/v-emit-prompt.sh" \
    V_TMP_DIR="$WORK/tmp" \
    bash "$SCRIPT" --stale-list "$ART/stale-t12.txt" --original-task-file "$WORK/task.txt" > "$WORK/out.$$.log" 2>"$WORK/err.$$.log" ); echo $? )"
[ "$rc12" = "2" ] && grep -qi 'cannot stat' "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null \
  && ok "T12 stat-unavailable on \$STALE_LIST -> hard exit 2 (never silently defaults the reference mtime to 0)" \
  || no "T12 stat failure must hard-exit 2, not silently proceed" "rc=$rc12 $(cat "$WORK/out.$$.log" "$WORK/err.$$.log" 2>/dev/null)"

rm -f "$WORK"/out.*.log "$WORK"/err.*.log 2>/dev/null
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
