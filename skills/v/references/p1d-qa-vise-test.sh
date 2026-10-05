#!/usr/bin/env bash
# p1d-qa-vise-test.sh — P1-D QA vise (2026-07-03).
#
# Two halves:
#   (1) PROMPT SHAPE — dispatch-v-qa-reviewer.md must carry the evidence-pointer section
#       (gate-summary / IMPACT_MAP / PRE_FLIGHT pointers + the "do NOT re-run the full suite"
#       directive + a time budget) with the substitution placeholders intact. Forensic: QA
#       re-derived context from scratch → 529s+, killed at the 600s cap,
#       double-billed on retry.
#   (2) DETACH DISPATCH — v-dispatch-subagent.sh --detach returns immediately, re-execs the
#       SAME argv minus --detach as a disowned child, and maintains <artifact>.dispatch-status
#       (RUNNING → appended DONE rc=N). Exercised with a stubbed `claude`+`jq` on PATH so the
#       REAL helper runs end-to-end. Also: the status file is append-only after spawn (a fast
#       child's DONE line must survive).
#
# RED ORACLE: V_QA_PROMPT_OVERRIDE=<pre-p1d bak> fails half 1; V_DSA_OVERRIDE=<pre-p1d bak>
# fails half 2 (unknown arg --detach → exit 2). Proven at ship time; see BITE_LEDGER.
set -u
PROMPT="${V_QA_PROMPT_OVERRIDE:-$HOME/.claude/skills/v/references/dispatch-v-qa-reviewer.md}"
DSA="${V_DSA_OVERRIDE:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== P1-D (1) :: evidence-pointer prompt shape =="
grep -q '## Evidence shortcuts' "$PROMPT" \
  && ok "evidence-shortcuts section present" \
  || no "evidence-shortcuts section missing (pre-P1D = RED)" ""
grep -q 'gate-summary-{{SESSION_ID}}.txt' "$PROMPT" \
  && ok "points at the machine gate-summary (with SID placeholder intact)" \
  || no "gate-summary pointer missing/broken" ""
grep -q 'Do NOT re-run the full pest/vitest suite' "$PROMPT" \
  && ok "forbids re-running the full test suite (pre-flight owns it)" \
  || no "full-suite prohibition missing" ""
grep -q 'IMPACT_MAP_{{SESSION_ID}}.md' "$PROMPT" \
  && ok "points at IMPACT_MAP for the cross-feature lens" \
  || no "IMPACT_MAP pointer missing" ""
grep -qE 'under ~?300s' "$PROMPT" \
  && ok "carries an explicit time budget" \
  || no "time budget missing" ""
# Placeholders the § (A) perl substitution fills must all still exist (a rename breaks dispatch).
for ph in SESSION_ID PROJECT_ROOT ITERATION ORIGINAL_TASK CHANGED_FILES; do
  grep -q "{{${ph}}}" "$PROMPT" \
    && ok "placeholder {{${ph}}} intact" \
    || no "placeholder {{${ph}}} LOST — § (A) substitution would break" ""
done

echo "== P1-D (2) :: --detach dispatch path =="
# Stub claude + jq on PATH: claude writes the artifact (self-write shape) after a short delay.
STUB="$WORK/bin"; mkdir -p "$STUB"
cat > "$STUB/claude" <<EOF
#!/usr/bin/env bash
sleep 1
printf 'Model: sonnet\n\n## QA Acceptance — stub\n\nverdict: pass\n' > "$WORK/QA_REPORT_stub.md"
printf '{"result":"done","is_error":false}\n'
EOF
chmod +x "$STUB/claude"
AGENT_DIR="$WORK/agents"; mkdir -p "$AGENT_DIR"
printf -- '---\nname: stub-agent\ntools: Bash, Read, Write\nmodel: sonnet\n---\nstub\n' > "$AGENT_DIR/stub-agent.md"
PROMPTF="$WORK/prompt.txt"; echo "stub prompt" > "$PROMPTF"
ART="$WORK/QA_REPORT_stub.md"

if ! grep -q 'P1D-DETACH' "$DSA"; then
  no "P1D-DETACH block present in helper" "absent (pre-P1D = RED)"
else
  ok "P1D-DETACH block present in helper"
  start=$(date +%s)
  out=$(cd "$WORK" && PATH="$STUB:$PATH" HOME="$WORK/fakehome" bash -c '
    mkdir -p "$HOME/.claude/agents"; cp '"$AGENT_DIR"'/stub-agent.md "$HOME/.claude/agents/"
    bash '"$DSA"' --agent stub-agent --prompt-file '"$PROMPTF"' --artifact '"$ART"' --mode self-write --detach' 2>/dev/null)
  rc=$?
  el=$(( $(date +%s) - start ))
  { [ "$rc" -eq 0 ] && [ "$el" -le 5 ] && printf '%s' "$out" | grep -q 'DISPATCH_DETACHED=1'; } \
    && ok "--detach returns immediately (rc=0, ${el}s) with DISPATCH_DETACHED=1" \
    || no "--detach did not return fast/clean" "rc=$rc el=${el}s out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
  STATUS="$ART.dispatch-status"
  [ -f "$STATUS" ] && grep -q '^RUNNING' "$STATUS" \
    && ok "status file created with RUNNING line before handback" \
    || no "status file missing/malformed at handback" "$(cat "$STATUS" 2>/dev/null)"
  # Wait for the child to finish (bounded, not a production path — test-only wait).
  for _i in $(seq 1 20); do grep -q '^DONE' "$STATUS" 2>/dev/null && break; sleep 1; done
  grep -q '^DONE rc=' "$STATUS" \
    && ok "child completion appended DONE rc= line (RUNNING line preserved: $(grep -c '^RUNNING' "$STATUS"))" \
    || no "DONE line never appeared — detached child lost" "$(cat "$STATUS" 2>/dev/null)"
  grep -q '^RUNNING' "$STATUS" \
    && ok "append-only contract held (RUNNING history survives DONE)" \
    || no "RUNNING line clobbered — truncating write raced the child" ""
fi

# Guidance side: § (A) must document the detach fallback and forbid foreground retry.
QAA="${V_QAA_OVERRIDE:-$HOME/.claude/skills/v/references/v-qa-acceptance.md}"
grep -q 'Contention fallback (P1-D' "$QAA" \
  && ok "v-qa-acceptance § (A) documents the detach contention fallback" \
  || no "§ (A) detach guidance missing" ""
grep -q 'dispatch-status' "$QAA" \
  && ok "§ (A) names the status-file contract" \
  || no "§ (A) status-file contract missing" ""

# ── W-QASCALE (2026-08-03): measurement-validity rule ────────────────────────────────────
# Forensic (production session): QA measured several SSR pages against a word-count threshold using the
# DEFAULT tiny local seed, returned a blocking `fail`, and burned a full extra iteration (~18 min)
# whose only output was RETRACTING that verdict at real scale.
# A quantitative `fail` from an unrepresentative fixture is a false negative that costs a whole
# loop turn. The cap is NOT the fix (cap=1 + a real iteration-1 fail forces a BLOCKED stop —
# see v-qa-acceptance § "Loop cap"); preventing the FALSE fail is.
# RED ORACLE: V_QAA_OVERRIDE=<pre-w-qascale bak> fails these four.
echo "== W-QASCALE :: threshold findings need a representative measurement =="
grep -q '## Measurement validity' "$QAA" \
  && ok "measurement-validity section present" \
  || no "measurement-validity section missing (pre-W-QASCALE = RED)" ""
grep -q 'Scale-unverified findings' "$QAA" \
  && ok "non-blocking bucket for unrepresentative threshold findings is named" \
  || no "Scale-unverified findings bucket missing" ""
grep -q 'measurement_basis' "$QAA" \
  && ok "QA_REPORT shape carries measurement_basis" \
  || no "measurement_basis field missing from QA_REPORT shape" ""
grep -qE 'MUST NOT return .?fail' "$QAA" \
  && ok "rule is imperative (MUST NOT return fail on an unrepresentative measurement)" \
  || no "imperative prohibition missing — advisory phrasing does not bind" ""

# ── W-QASCALE-BASIS (2026-08-03): the downgrade must state its basis ───────────────────────
# W-QASCALE (v-qa-acceptance.md § Measurement validity) lets QA move a quantitative threshold
# finding from a blocking `fail` into a non-blocking `## Scale-unverified findings` bucket when
# the fixture is not production-representative. Correct for that false-fail class — and
# ALSO a reward-hacking surface: "the fixture was unrepresentative" is unfalsifiable, so a
# pressured agent can launder a REAL threshold failure through it. Minimum mechanical guard: a
# report CLAIMING pass while carrying scale-unverified content must state the basis it had.
# RED ORACLE: V_CRA_OVERRIDE=<pre-wqascalebasis bak> lacks the block.
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
BASIS="$(awk '/=== W-QASCALE-BASIS/,/=== end W-QASCALE-BASIS/' "$HOOK")"
echo "== W-QASCALE-BASIS :: a scale-downgraded pass must name its measurement basis =="
if [ -z "$BASIS" ]; then
  no "W-QASCALE-BASIS block present in hook" "awk range empty (pre-fix = RED)"
else
  ok "W-QASCALE-BASIS block present in hook"
  mkqa() { # $1=file $2=include-scale-section $3=include-basis
    { printf 'Model: sonnet\n\n## QA Acceptance — t\n\nverdict: pass\n'
      [ "$3" = "yes" ] && printf 'measurement_basis: "full-scale production snapshot"\n'
      printf '\n## Findings (current iteration)\nNone.\n'
      if [ "$2" = "yes" ]; then
        printf '\n## Scale-unverified findings (threshold observations without a representative measurement — NOT blocking)\n'
        printf -- '- /listing measured 176 words against the default tiny seed; needs full-scale data to settle\n'
      fi
      printf '\n## Summary\nverdict: pass\n'
    } > "$1"
  }
  run_basis() { # $1=qa file -> MISSING_QA after the block
    ( set +eu
      SESSION_ID="p1d-sid"; MISSING_QA=0; QA_REPORT_FILE="$1"; _qa_verdict="pass"; QA_REASON=""
      eval "$BASIS" >/dev/null 2>&1
      printf '%s' "$MISSING_QA" )
  }
  mkqa "$WORK/qa_nobasis.md" yes no
  [ "$(run_basis "$WORK/qa_nobasis.md")" = "1" ] \
    && ok "pass + scale-unverified content + NO measurement_basis → BLOCKED" \
    || no "unfalsifiable scale downgrade was accepted" ""
  mkqa "$WORK/qa_basis.md" yes yes
  [ "$(run_basis "$WORK/qa_basis.md")" = "0" ] \
    && ok "pass + scale-unverified content + measurement_basis → accepted" \
    || no "a properly-attributed downgrade was wrongly blocked" ""
  mkqa "$WORK/qa_none.md" no no
  [ "$(run_basis "$WORK/qa_none.md")" = "0" ] \
    && ok "pass with NO scale-unverified section → rule does not apply (no over-trigger)" \
    || no "rule fired on a report with no threshold downgrade" ""
  # Template placeholder must not count as content (the skeleton ships '- <...>').
  { printf 'Model: sonnet\n\n## QA Acceptance — t\n\nverdict: pass\n\n'
    printf '## Scale-unverified findings (threshold observations without a representative measurement — NOT blocking)\n'
    printf -- '- <observed value | basis measured against | what scale would settle it>\n'
    printf '\n## Summary\nverdict: pass\n'; } > "$WORK/qa_tmpl.md"
  [ "$(run_basis "$WORK/qa_tmpl.md")" = "0" ] \
    && ok "unfilled template placeholder is not treated as a real downgrade" \
    || no "empty template bucket falsely triggered the rule" ""
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
