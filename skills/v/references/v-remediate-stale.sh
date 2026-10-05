#!/usr/bin/env bash
# v-remediate-stale.sh — Recommendation #2 batched remediation.
#
# SCOPE: of the 5 gauntlet artifacts, only THREE are genuinely single-subprocess-dispatchable the
# way this script needs:
#   - PRE_FLIGHT_REPORT   -> v-pre-flight-runner, --mode capture   (v-concurrent-dispatch.md)
#   - VERIFY_DONE_REPORT  -> v-verify-done-runner, --mode capture  (same "verbatim dispatch"
#                            family per SKILL.md's Step-4/6 dispatch contract)
#   - QA_REPORT           -> v-qa-reviewer, --mode self-write      (dispatch-v-qa-reviewer.md) —
#                            BUT needs {{ORIGINAL_TASK}} verbatim, which lives only in the
#                            orchestrator's conversation, not on disk. This script therefore
#                            REQUIRES --original-task-file for QA_REPORT remediation; if it's
#                            stale and that flag is absent, this script does NOT guess — it
#                            skips QA_REPORT and tells the model to supply the file.
# The other two are NOT single-subprocess-dispatchable, confirmed by reading their own protocol
# docs (not assumed):
#   - IMPACT_MAP    (v-impact-analysis.md) is written by the ORCHESTRATOR ITSELF — there is no
#     `v-dispatch-subagent.sh --agent ...` line anywhere in that doc. It requires the model's own
#     conversational judgment about the diff. No child process can produce it. This script NEVER
#     attempts to dispatch it — it prints a loud MANUAL instruction and excludes it from every tier.
#   - AGENT_REVIEW (v-agent-review.md "the adversarial PANEL") is a 2-stage generate/refute
#     multi-child process PLUS an orchestrator-authored skeleton+Findings step
#     (v-emit-agent-review-skeleton.sh, then the model fills ## Findings by hand). This script
#     CAN batch the mechanical part — the stage-1 "generate" panel children, via the supervisor —
#     which is a real, provable win (N reviewer dispatch turns -> 1 supervised call). It CANNOT
#     eliminate the orchestrator's own skeleton-generation + Findings-authoring step afterward.
#
# Net effect on the "~2 turns for N stale artifacts" framing: TRUE only when the stale set is a
# subset of {PRE_FLIGHT_REPORT, VERIFY_DONE_REPORT, QA_REPORT-with-task-file}. IMPACT_MAP staleness
# always costs at least one manual orchestrator turn no matter what tooling exists. AGENT_REVIEW
# staleness costs one batched dispatch turn (this script) PLUS one authoring turn (skeleton +
# Findings) that this script cannot remove.
#
# TAMPER-EVIDENCE (adversarial-review finding, 2026-08-17): the original design's exit criterion
# was "every named artifact file is now non-empty" combined with `--fallback-artifacts enabled` on
# the supervisor — and write_fallback_artifact() (v-supervise-children.sh:80-184) GUARANTEES a
# non-empty artifact on ANY child failure, so that criterion is satisfied by design regardless of
# whether the dispatch actually worked. This script instead runs a CONTENT oracle per artifact:
#   1. HARD REJECT if the artifact contains any of write_fallback_artifact()'s own template
#      markers — these strings are unique to that function's output; a real reviewer/gate/QA
#      artifact never contains them verbatim.
#   2. For PRE_FLIGHT_REPORT / VERIFY_DONE_REPORT, reuse the EXACT verdict-line greps
#      check-review-artifact.sh already uses, so this script's notion of "pass" cannot silently
#      diverge from the Stop hook's.
#   3. For QA_REPORT, source hooks/lib/validation.sh and call the REAL validate_qa_report_structure()
#      directly — never a re-derived subset of its logic. That function strips quote/backtick/
#      bold/underscore wrappers around the verdict value (`verdict: "pass"` is an observed
#      self-write shape); a hand-rolled reimplementation that skipped this would WRONGLY REJECT a
#      legitimately-passing report (caught by adversarial code review before this shipped).
#   4. AGENT_REVIEW / IMPACT_MAP do not get a lightweight full-fidelity verdict parser here (their
#      real checks — _independence_verdict's transcript walk, validate_impact_map_semantics — are
#      multi-line functions in hooks/lib/validation.sh this script deliberately does not fork a
#      second copy of). The fallback-marker hard-reject (step 1) is this script's full oracle for
#      those two; a non-fallback, non-empty file is treated as tentatively ok. The Stop hook's own
#      full validators are ALWAYS the authoritative check on the next pass regardless of what this
#      script concludes — this script's job is only "did the mechanical dispatch actually run",
#      never a replacement for the real gate.
#
# THIS SCRIPT NEVER TRUSTS THE SIDECAR AS A TRUST BOUNDARY. It is a convenience input (avoids
# hand-parsing v-gauntlet-attest.sh's prose message) — the real gate is always the NEXT run of
# v-gauntlet-attest.sh, which re-derives staleness from live mtimes independent of anything this
# script did or claimed.
set -uo pipefail

HELPER="${V_DISPATCH_HELPER:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
SUPERVISOR="${V_SUPERVISOR:-$HOME/.claude/skills/v/references/v-supervise-children.sh}"
EMIT_PROMPT="${V_EMIT_PROMPT:-$HOME/.claude/skills/v/references/v-emit-prompt.sh}"
VALIDATION_LIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
TMP_DIR="${V_TMP_DIR:-$(mktemp -d)}"
mkdir -p "$TMP_DIR"

# Source the REAL QA structural validator — never reimplement its quote/backtick/bold-stripping
# logic. Fails open to a conservative local fallback ONLY if the lib is genuinely unavailable
# (matches the fail-open convention v-gauntlet-attest.sh itself uses for its own optional-lib
# loads), and that fallback is intentionally STRICTER (rejects unrecognized shapes) rather than
# looser, so an unavailable lib can never turn a real failure into a false pass.
if [ -f "$VALIDATION_LIB" ]; then
  # shellcheck source=/dev/null
  . "$VALIDATION_LIB" 2>/dev/null || true
fi
if ! type validate_qa_report_structure >/dev/null 2>&1; then
  echo "WARNING: could not load $VALIDATION_LIB — validate_qa_report_structure unavailable, QA_REPORT verdicts will fail closed (rejected as unverifiable) rather than risk a false pass" >&2
  validate_qa_report_structure() { echo "validation lib unavailable"; return 1; }
fi

STALE_LIST=""
ORIGINAL_TASK_FILE=""
MAX_CONC="${V_REMEDIATE_MAX_CONC:-2}"   # named explicitly per adversarial-review fix — never unlimited

while [ $# -gt 0 ]; do
  case "$1" in
    --stale-list) STALE_LIST="${2:-}"; shift 2 || exit 2 ;;
    --original-task-file) ORIGINAL_TASK_FILE="${2:-}"; shift 2 || exit 2 ;;
    --max-concurrency) MAX_CONC="${2:-2}"; shift 2 || exit 2 ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ -n "$STALE_LIST" ] || { echo "ERROR: --stale-list <path> required (v-gauntlet-attest.sh prints the exact path on FAIL)" >&2; exit 2; }
[ -f "$STALE_LIST" ] || { echo "ERROR: stale-list file not found: $STALE_LIST — re-run v-gauntlet-attest.sh to regenerate it (the sidecar is advisory, not a trust boundary, but this script needs SOME input list)" >&2; exit 2; }

# bash 3.2 (macOS /bin/bash) has no `mapfile`. This script is `#!/usr/bin/env bash`, so it picks
# up Homebrew bash 5 whenever PATH has it — but under a stripped PATH (cron, launchd, a minimal
# hook env) `env bash` resolves to /bin/bash 3.2 and this line died with
# "mapfile: command not found" (rc 127). It also violated the tree-wide no-bash-4isms invariant
# asserted by v-w5g-forensic-test.sh case G1. Portable read instead.
# DELIBERATE DIFFERENCE FROM mapfile: blank lines are SKIPPED. The sidecar is a machine-written
# one-path-per-line list, so a blank would become a bogus artifact path; dropping it is strictly
# safer than carrying an empty string into the remediation loop.
STALE_ARTIFACTS=()
while IFS= read -r _l || [ -n "$_l" ]; do
  [ -n "$_l" ] || continue
  STALE_ARTIFACTS+=("$_l")
done < "$STALE_LIST"
[ "${#STALE_ARTIFACTS[@]}" -gt 0 ] || { echo "ERROR: $STALE_LIST is empty — nothing to remediate" >&2; exit 2; }

# Portable mtime (same idiom as hooks/lib/validation.sh's _v_mtime_epoch): GNU `stat -c` first, BSD `stat -f` fallback.
_mtime_epoch() {
  [ -f "$1" ] || return 1
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null   # GNU first
}
# STALE_LIST is written by v-gauntlet-attest.sh AFTER it evaluates every named artifact as stale, so
# by construction each artifact's mtime is <= STALE_LIST's mtime at generation time. Any artifact
# whose mtime is NEWER than that, right now, was genuinely regenerated by an EARLIER invocation of
# this script against this same sidecar (Bug 2 fix — no new persisted state file needed). This is
# used ONLY for the pre-dispatch "already fixed by a prior call" skip decision below — the closing
# verdict loop for anything THIS invocation actually attempted uses the content oracle alone (see
# Bug 1b note there), never this timestamp, so a same-second dispatch can never read as a false FAIL.
STALE_LIST_MTIME="$(_mtime_epoch "$STALE_LIST")" \
  || { echo "ERROR: cannot stat $STALE_LIST for mtime comparison — refusing to guess (a silent 0 fallback would let every artifact read as unconditionally 'fresh', reintroducing the false-ok this check exists to close)" >&2; exit 2; }
_artifact_fresh_since_stale_list() {   # <artifact-path> -> 0 if an EARLIER invocation already fixed it
  local _m
  _m="$(_mtime_epoch "$1")" || return 1
  [ "${_m:-0}" -gt "${STALE_LIST_MTIME:-0}" ] 2>/dev/null || return 1
  artifact_verdict_ok "$1"
}

# ── content oracle ────────────────────────────────────────────────────────────────────────────
_is_fallback_artifact() {
  grep -qE 'supervised-fallback|Supervised reviewer .*exited|## Supervised Child Failure|supervised child .*exited' "$1" 2>/dev/null
}

artifact_verdict_ok() {
  local base f last vd_last qv
  base="$(basename "$1")"; f="$1"
  [ -f "$f" ] && [ -s "$f" ] || return 1
  if _is_fallback_artifact "$f"; then
    echo "    -> REJECT $base: matches write_fallback_artifact()'s own template marker (a supervised-child failure stub, not a real result)" >&2
    return 1
  fi
  case "$base" in
    PRE_FLIGHT_REPORT_*.md)
      last="$(grep -iE '^[-* ]*(\*\*)?Overall Status(\*\*)?[[:space:]]*:' "$f" 2>/dev/null | tail -1)"
      if [ -z "$last" ]; then echo "    -> REJECT $base: no 'Overall Status:' line found" >&2; return 1; fi
      if printf '%s\n' "$last" | grep -qiE ':[[:space:]]*(\*\*)?(FAIL|BLOCK)([^A-Za-z_-]|$)'; then
        echo "    -> REJECT $base: Overall Status is FAIL/BLOCK" >&2; return 1
      fi
      return 0 ;;
    VERIFY_DONE_REPORT_*.md)
      vd_last="$(awk 'NF { last=$0 } END { print last }' "$f" 2>/dev/null)"
      if printf '%s' "$vd_last" | grep -qiE '^[[:space:]*#-]*overall[[:space:]]+verdict:[[:space:]]*fail([[:space:]*_]|$)' \
         || tail -5 "$f" 2>/dev/null | grep -qiE '^[[:space:]*#-]*(overall[[:space:]]+)?verdict:[[:space:]]*fail([[:space:]*_]|$)'; then
        echo "    -> REJECT $base: Overall Verdict is FAIL" >&2; return 1
      fi
      return 0 ;;
    QA_REPORT_*.md)
      # Reuse the REAL validator (see header) — it echoes the lowercased verdict on rc=0, or the
      # structural failure reason on rc=1. Never re-derive the quote/wrapper-stripping logic here.
      qv="$(validate_qa_report_structure "$f" 2>/dev/null)"
      qvrc=$?
      if [ "$qvrc" -ne 0 ]; then
        echo "    -> REJECT $base: structurally invalid ($qv)" >&2; return 1
      fi
      case "$qv" in
        pass) return 0 ;;
        escalated)
          if ls "$(dirname "$f")"/BLOCKED_*.md >/dev/null 2>&1; then return 0; fi
          echo "    -> REJECT $base: verdict escalated with no BLOCKED_<sid>.md companion" >&2; return 1 ;;
        *) echo "    -> REJECT $base: no recognized top verdict (got '$qv')" >&2; return 1 ;;
      esac ;;
    AGENT_REVIEW_*.md|IMPACT_MAP_*.md)
      # No full-fidelity parser here by design (see header). Non-fallback + non-empty = tentative
      # ok; the Stop hook's real validators are authoritative on the next pass regardless.
      return 0 ;;
    *)
      echo "    -> REJECT $base: unrecognized artifact basename pattern" >&2; return 1 ;;
  esac
}

# ── tier classification ──────────────────────────────────────────────────────────────────────
TIER_PREFLIGHT=() TIER_VERIFYDONE=() TIER_QA=() TIER_AGENTREVIEW=() TIER_IMPACTMAP_MANUAL=() TIER_UNKNOWN=()
ATTEMPTED_PREFLIGHT=0 ATTEMPTED_VERIFYDONE=0 ATTEMPTED_QA=0
for a in "${STALE_ARTIFACTS[@]}"; do
  [ -n "$a" ] || continue
  case "$(basename "$a")" in
    PRE_FLIGHT_REPORT_*.md)  TIER_PREFLIGHT+=("$a") ;;
    VERIFY_DONE_REPORT_*.md) TIER_VERIFYDONE+=("$a") ;;
    QA_REPORT_*.md)          TIER_QA+=("$a") ;;
    AGENT_REVIEW_*.md)       TIER_AGENTREVIEW+=("$a") ;;
    IMPACT_MAP_*.md)         TIER_IMPACTMAP_MANUAL+=("$a") ;;
    *)                       TIER_UNKNOWN+=("$a") ;;
  esac
done

if [ "${#TIER_UNKNOWN[@]}" -gt 0 ]; then
  echo "ERROR: unrecognized artifact(s) in stale list, refusing to guess: ${TIER_UNKNOWN[*]}" >&2
  exit 2
fi

if [ "${#TIER_IMPACTMAP_MANUAL[@]}" -gt 0 ]; then
  echo "MANUAL — IMPACT_MAP is orchestrator-authored (v-impact-analysis.md: no subprocess dispatch exists for it). This script CANNOT regenerate: ${TIER_IMPACTMAP_MANUAL[*]}. Re-run Step 1.8 yourself against the current diff before/alongside the batched tiers below. If AGENT_REVIEW is also stale, its reviewer_scope input may be derived from a stale IMPACT_MAP until you do this." >&2
fi

# Derive SID + PROJECT_ROOT from the first classified artifact's filename/path (all 5 basenames
# share the same _<uuid>.md suffix and project-root-relative .v/artifacts/ parent by convention).
_first="${TIER_PREFLIGHT[0]:-${TIER_VERIFYDONE[0]:-${TIER_QA[0]:-${TIER_AGENTREVIEW[0]:-${TIER_IMPACTMAP_MANUAL[0]:-}}}}}"
SID="$(basename "${_first:-}" .md | sed -E 's/^[A-Z_]+_([a-f0-9-]{36})$/\1/')"
ART_DIR="$(dirname "${_first:-.}")"
PROJECT_ROOT="$(cd "$ART_DIR/.." 2>/dev/null && pwd || echo "$PWD")"
[ -n "$SID" ] || { echo "ERROR: could not derive SID from stale-list entries" >&2; exit 2; }

# All-manual case (e.g. only IMPACT_MAP was stale): nothing left for this script to dispatch —
# exit cleanly with the MANUAL guidance already printed above, not a generic error.
if [ "${#TIER_PREFLIGHT[@]}" -eq 0 ] && [ "${#TIER_VERIFYDONE[@]}" -eq 0 ] \
   && [ "${#TIER_QA[@]}" -eq 0 ] && [ "${#TIER_AGENTREVIEW[@]}" -eq 0 ]; then
  echo "REMEDIATE|status=manual-only|artifacts_refreshed=0|manual_remaining=${TIER_IMPACTMAP_MANUAL[*]}"
  exit 1
fi

RESULTS=()  # "artifact|status"

# $2.. are raw "name::timeout::artifact::cmd_file" child SPECS — the --child flag is added here,
# once per spec, so the child COUNT this function logs matches the real number of children.
run_tier() {
  local tier_name="$1"; shift
  local specs=("$@")
  [ "${#specs[@]}" -gt 0 ] || return 0
  local summary="$TMP_DIR/supervisor-${SID}-${tier_name}.summary"
  local sv_args=(--summary "$summary" --retry-transient once --fallback-artifacts enabled --max-concurrency "$MAX_CONC")
  local spec
  for spec in "${specs[@]}"; do sv_args+=(--child "$spec"); done
  echo "== Tier: $tier_name (${#specs[@]} child(ren), max-concurrency=$MAX_CONC) ==" >&2
  bash "$SUPERVISOR" "${sv_args[@]}" >&2
  local rc=$?
  echo "-- supervisor rc=$rc summary=$summary --" >&2
}

# ── Tier 1: PRE_FLIGHT_REPORT (independent) ──────────────────────────────────────────────────
if [ "${#TIER_PREFLIGHT[@]}" -gt 0 ]; then
  a="${TIER_PREFLIGHT[0]}"
  if _artifact_fresh_since_stale_list "$a"; then
    echo "-- tier1-preflight: $a already refreshed since $STALE_LIST was generated and passes the content oracle -- skipping redundant re-dispatch --" >&2
  else
    ATTEMPTED_PREFLIGHT=1
    DISPATCH_PF="$TMP_DIR/dispatch-${SID}-v-pre-flight.txt"
    bash "$EMIT_PROMPT" v-pre-flight > "$DISPATCH_PF"
    PF_CMD="$TMP_DIR/child-${SID}-v-pre-flight.sh"
    cat > "$PF_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent v-pre-flight-runner --prompt-file "$DISPATCH_PF" --artifact "$a" --mode capture
EOF
    run_tier "tier1-preflight" "preflight::900::$a::$PF_CMD"
  fi
fi

# ── Tier 2: AGENT_REVIEW panel — MECHANICAL PART ONLY (see header) ──────────────────────────
if [ "${#TIER_AGENTREVIEW[@]}" -gt 0 ]; then
  a="${TIER_AGENTREVIEW[0]}"
  PANEL_DIR="$(dirname "$a")"
  children=()
  for LENS in correctness repro security; do
    DISPATCH_LENS="$TMP_DIR/dispatch-${SID}-panel-${LENS}.txt"
    # NOT independently verified: the exact prompt-substitution steps adversarial-panel-reviewer
    # expects per lens (v-agent-review.md's own preceding dispatch-file construction) — implementer
    # must confirm before this tier is relied on in production; disclosed, not papered over.
    printf 'LENS=%s SESSION_ID=%s MODE=generate\n' "$LENS" "$SID" > "$DISPATCH_LENS"
    LENS_CMD="$TMP_DIR/child-${SID}-panel-${LENS}.sh"
    cat > "$LENS_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent adversarial-panel-reviewer --prompt-file "$DISPATCH_LENS" \\
  --artifact "$PANEL_DIR/panel-${LENS}-${SID}.md" --mode capture
EOF
    children+=("panel-${LENS}::900::$PANEL_DIR/panel-${LENS}-${SID}.md::$LENS_CMD")
  done
  run_tier "tier2-agentreview-panel" "${children[@]}"
  echo "MANUAL FOLLOW-UP for AGENT_REVIEW: the 3 panel-*.md files above are stage-1 (generate) only. Run stage 2 (refute), then bash \"$HOME/.claude/skills/v/references/v-emit-agent-review-skeleton.sh\" --sid \"$SID\" --out \"$a\" and fill in ## Findings yourself — this script does not (and structurally cannot) do that authoring step." >&2
fi

# ── Tier 3: VERIFY_DONE_REPORT (depends on tiers 1+2 completing first — sequential by construction)
if [ "${#TIER_VERIFYDONE[@]}" -gt 0 ]; then
  a="${TIER_VERIFYDONE[0]}"
  if _artifact_fresh_since_stale_list "$a"; then
    echo "-- tier3-verifydone: $a already refreshed since $STALE_LIST was generated and passes the content oracle -- skipping redundant re-dispatch --" >&2
  else
    ATTEMPTED_VERIFYDONE=1
    DISPATCH_VD="$TMP_DIR/dispatch-${SID}-v-verify-done.txt"
    bash "$EMIT_PROMPT" v-verify-done > "$DISPATCH_VD"
    VD_CMD="$TMP_DIR/child-${SID}-v-verify-done.sh"
    cat > "$VD_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent v-verify-done-runner --prompt-file "$DISPATCH_VD" --artifact "$a" --mode capture
EOF
    run_tier "tier3-verifydone" "verifydone::900::$a::$VD_CMD"
  fi
fi

# ── Tier 4: QA_REPORT (depends on tiers 1-3; needs ORIGINAL_TASK from the model) ─────────────
if [ "${#TIER_QA[@]}" -gt 0 ]; then
  a="${TIER_QA[0]}"
  if _artifact_fresh_since_stale_list "$a"; then
    echo "-- tier4-qa: $a already refreshed since $STALE_LIST was generated and passes the content oracle -- skipping redundant re-dispatch --" >&2
  elif [ -z "$ORIGINAL_TASK_FILE" ] || [ ! -f "$ORIGINAL_TASK_FILE" ]; then
    echo "MANUAL — QA_REPORT is stale ($a) but --original-task-file was not supplied. QA_REPORT's dispatch prompt requires {{ORIGINAL_TASK}} verbatim (the user's request), which only you hold. Write it to a file and re-invoke with --original-task-file <path>. Skipping tier 4." >&2
  else
    ATTEMPTED_QA=1
    DISPATCH_QA="$TMP_DIR/dispatch-${SID}-v-qa-reviewer.txt"
    # NOT independently verified: the exact perl -0pe substitution block (dispatch-v-qa-reviewer.md
    # references it as done in v-qa-acceptance.md § (A)) — this does the substitution directly
    # rather than re-deriving that exact perl invocation. Disclosed, not papered over.
    ORIGINAL_TASK="$(cat "$ORIGINAL_TASK_FILE")"
    CHANGED_FILES="$(cd "$PROJECT_ROOT" && git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null | sort -u)"
    # OT/CF must PRECEDE perl to reach $ENV: placed after it (as before 2026-10-01) they are read as input
    # FILE names, perl prints nothing with rc 0, and QA was dispatched with an EMPTY prompt. The replacement
    # interpolates $ENV{..} literally; \Q..\E there would backslash every space and punctuation mark.
    { sed -e "s/{{SESSION_ID}}/$SID/g" -e "s#{{PROJECT_ROOT}}#$PROJECT_ROOT#g" -e "s/{{ITERATION}}/1/g" \
          "$HOME/.claude/skills/v/references/dispatch-v-qa-reviewer.md"
    # One pass (code review M1, 2026-10-02): two sequential s/// let a {{CHANGED_FILES}} token INSIDE the task text be
    # rewritten, and a guard that greps the output for {{ORIGINAL_TASK}} refused tasks that quote that token.
    } | OT="$ORIGINAL_TASK" CF="$CHANGED_FILES" \
        perl -0pe 's/\{\{(ORIGINAL_TASK|CHANGED_FILES)\}\}/$ENV{$1 eq "ORIGINAL_TASK" ? "OT" : "CF"}/ge' > "$DISPATCH_QA"
    _qa_rc=$?   # pipefail is on: non-zero if sed OR perl failed (e.g. perl "Argument list too long")
    if [ -z "${ORIGINAL_TASK//[[:space:]]/}" ] || [ "$_qa_rc" -ne 0 ] || [ ! -s "$DISPATCH_QA" ]; then
      echo "ERROR: QA dispatch prompt not built (empty task, substitution failed rc=$_qa_rc, or empty output: $DISPATCH_QA); not dispatching QA" >&2
      exit 2
    fi
    QA_CMD="$TMP_DIR/child-${SID}-v-qa-reviewer.sh"
    cat > "$QA_CMD" <<EOF
#!/usr/bin/env bash
bash "$HELPER" --agent v-qa-reviewer --prompt-file "$DISPATCH_QA" --artifact "$a" --mode self-write
EOF
    run_tier "tier4-qa" "qa::900::$a::$QA_CMD"
  fi
fi

# ── content-oracle verdict pass over everything this script attempted ────────────────────────
# Ordering matters (adversarial-review finding): an artifact THIS invocation actually dispatched is
# judged by the content oracle ALONE (artifact_verdict_ok) — never by the mtime-freshness check,
# which is whole-second-granularity and can otherwise misread a just-written pass as "not fresh"
# and wrongly report FAIL. The freshness check is reserved for artifacts this invocation did NOT
# attempt, where its only job is distinguishing "an earlier invocation already fixed this" (ok) from
# "still genuinely stale" (skipped) — a same-second false negative there just costs one redundant
# redispatch next time, never a false FAIL on real work this run just did.
FAILED=()
SKIPPED=()
_attempted_this_invocation() {
  case "$(basename "$1")" in
    PRE_FLIGHT_REPORT_*.md)  [ "${ATTEMPTED_PREFLIGHT:-0}" = 1 ] ;;
    VERIFY_DONE_REPORT_*.md) [ "${ATTEMPTED_VERIFYDONE:-0}" = 1 ] ;;
    QA_REPORT_*.md)          [ "${ATTEMPTED_QA:-0}" = 1 ] ;;
    *) return 1 ;;
  esac
}
# ${arr[@]+"${arr[@]}"}: bash before 4.4 treats an empty array as unset under set -u.
for a in ${TIER_PREFLIGHT[@]+"${TIER_PREFLIGHT[@]}"} ${TIER_VERIFYDONE[@]+"${TIER_VERIFYDONE[@]}"} ${TIER_QA[@]+"${TIER_QA[@]}"}; do
  [ -n "$a" ] || continue
  if _attempted_this_invocation "$a"; then
    if artifact_verdict_ok "$a"; then
      RESULTS+=("$a|ok")
    else
      RESULTS+=("$a|FAIL")
      FAILED+=("$a")
    fi
  elif _artifact_fresh_since_stale_list "$a"; then
    RESULTS+=("$a|ok")
  else
    RESULTS+=("$a|skipped")
    SKIPPED+=("$a")
  fi
done
# AGENT_REVIEW_<sid>.md is NEVER claimed "ok" by this script — Tier 2 structurally cannot write it
# (only the panel-*.md stage-1 files; see header), so any "ok" here would overclaim this script's
# own contribution regardless of the file's actual mtime/content.
for a in ${TIER_AGENTREVIEW[@]+"${TIER_AGENTREVIEW[@]}"}; do
  [ -n "$a" ] || continue
  RESULTS+=("$a|PARTIAL-stage1-only")
done

echo
echo "REMEDIATE_RESULTS:"
for r in "${RESULTS[@]}"; do echo "  $r"; done
if [ "${#TIER_IMPACTMAP_MANUAL[@]}" -gt 0 ]; then
  echo "  ${TIER_IMPACTMAP_MANUAL[*]}|MANUAL-NOT-ATTEMPTED"
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "REMEDIATE|status=fail|artifacts_refreshed=$(( ${#RESULTS[@]} - ${#FAILED[@]} - ${#SKIPPED[@]} - ${#TIER_AGENTREVIEW[@]} ))|still_failing=${FAILED[*]}"
  exit 1
fi
if [ "${#TIER_IMPACTMAP_MANUAL[@]}" -gt 0 ] || [ "${#TIER_AGENTREVIEW[@]}" -gt 0 ] || [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "REMEDIATE|status=partial|artifacts_refreshed=$(( ${#RESULTS[@]} - ${#SKIPPED[@]} - ${#TIER_AGENTREVIEW[@]} ))|manual_remaining=${TIER_IMPACTMAP_MANUAL[*]} ${TIER_AGENTREVIEW[*]}|skipped=${SKIPPED[*]}"
  exit 1
fi
echo "REMEDIATE|status=pass|artifacts_refreshed=${#RESULTS[@]}"
echo "Now re-run v-gauntlet-attest.sh LAST — it re-derives staleness from live mtimes; this script's verdict is not a substitute."
exit 0
