#!/usr/bin/env bash
# v-completion-selfcheck.sh — the /v orchestrator's PRE-COMPLETION gate (W-perf5).
#
# WHY (three production sessions — 45–62 min each, all bounced):
# the orchestrator declared "done" after a weak `test -f IMPACT_MAP_<sid>.md`
# existence check, then the Stop hook (check-review-artifact.sh) bounced it because
# (a) the IMPACT_MAP was a `## Subsystem triage` TABLE lacking the `^subsystems:`
# anchor, (b) the QA_REPORT was missing its `Model:` header, or (c) the QA / UX /
# WORKFLOW artifacts were written in the WORKTREE and never reached MAIN_ROOT (where
# the Stop hook's find_session_artifact looks). The model then re-ran the entire
# gauntlet by hand in the parent session.
#
# This script closes that loop. It runs the SAME single-source validators the Stop
# hook runs (hooks/lib/validation.sh), against the artifacts AT MAIN_ROOT, after
# first RECONCILING (copying up) any session artifact that exists only in the CWD or
# a session worktree. So the producer-side check and the gate can never disagree.
#
# Prints exactly one of:
#   V-COMPLETION-SELFCHECK: PASS[ — <bypass note>]
#   V-COMPLETION-SELFCHECK: FAIL\n  - <reason> ...
# Exit: 0 PASS, 1 FAIL (missing/malformed artifacts), 2 usage/env error.
#
# Invoked by the /v "ABSOLUTE COMPLETION GATE" in SKILL.md for code-changing
# completions. Non-code completions (TRIVIAL_PASS / PLANNING_PASS / HANDOFF /
# BLOCKED) are detected and pass through.
set -u

SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [ -z "$SID" ]; then
  echo "V-COMPLETION-SELFCHECK: FAIL"
  echo "  - no session id (CLAUDE_CODE_SESSION_ID / CLAUDE_SESSION_ID both unset)"
  exit 2
fi

# Resolve MAIN_ROOT exactly as the Stop hook does — item 20 sibling-sweep (cycle-3 audit
# 2026-07-04): BOTH now use the shared resolve_main_root (git-common-dir identity), with the
# old first-worktree-row heuristic only as the lib-missing fallback. Lockstep with
# check-review-artifact.sh is the contract: this script exists to PREDICT that hook.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
MAIN_ROOT=""
_GMR="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/git-main-root.sh"
if [ -f "$_GMR" ]; then
  # shellcheck source=/dev/null
  source "$_GMR" 2>/dev/null && MAIN_ROOT="$(resolve_main_root "$REPO_ROOT" 2>/dev/null || true)"
fi
[ -n "$MAIN_ROOT" ] || MAIN_ROOT=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"
ARTIFACT_DIR=$(bash "$HOME/.claude/skills/v/references/v-artifact-dir.sh" 2>/dev/null)
[ -n "$ARTIFACT_DIR" ] || ARTIFACT_DIR="$MAIN_ROOT/.v/artifacts"
mkdir -p "$ARTIFACT_DIR" 2>/dev/null || true

LIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
if [ ! -f "$LIB" ]; then
  echo "V-COMPLETION-SELFCHECK: FAIL"
  echo "  - single-source validators lib not found ($LIB)"
  exit 2
fi
# shellcheck disable=SC1090
. "$LIB"

# Single-source guard (codex review, 2026-06-15): the gate-independence primitives MUST be defined
# after sourcing the lib. If validation.sh ever partial-sources (mid-file parse error), the
# _independence_verdict calls below would be 'command not found', the case would fall through, and
# this self-check would VACUOUSLY PASS a session the Stop hook will block — i.e. /v would lie about
# finishing, the exact failure this gate exists to prevent. Fail closed.
if ! type _independence_verdict >/dev/null 2>&1 || ! type _prep_independence_signals >/dev/null 2>&1; then
  echo "V-COMPLETION-SELFCHECK: FAIL"
  echo "  - hooks/lib/validation.sh did not define the gate-independence primitives (_independence_verdict / _prep_independence_signals) — partial source? Cannot verify reviewer/QA independence, refusing to pass."
  exit 2
fi

# ── SID cross-fallback (W-perf8) ─────────────────────────────────────────────
# Artifacts are named with whatever SID the /v session used. Under a per-workstream override the
# WORK sid (exported CLAUDE_SESSION_ID, e.g. <work-sid>) differs from the immutable process sid
# (CLAUDE_CODE_SESSION_ID, e.g. <process-sid>). This gate reads CLAUDE_CODE_SESSION_ID first, so it
# FAILED looking for <process-sid> while gauntlet-attest (CLAUDE_SESSION_ID first) PASSED on <work-sid>
# — the "self-check insists on the wrong SID / harness quirk" the prod session rationalized as
# benign. Non-destructive fix: if the primary SID owns NO gauntlet artifacts but the ALTERNATE
# env-var SID does, adopt the alternate. Precedence is unchanged when both/neither own artifacts.
#
# SAFETY MODEL (adversarial review SREV-002 + framework-pitfall HIGH): this is a PRODUCER-side
# self-check — it is intentionally LENIENT (adopt-the-SID-that-owns-the-work) to kill the
# self-check-vs-attest split that made prod sessions thrash. It is NOT the enforcement gate. The
# Stop hook (check-review-artifact.sh → hooks/lib/resolve-sid.sh) is the strict backstop and is
# DELIBERATELY given NO artifact-presence fallback — so a producer-side mis-attribution here (e.g.
# a stale CLAUDE_SESSION_ID leaked from another session) CANNOT ship bad code: the strict Stop hook
# independently re-resolves + re-validates. v-contract-audit-test.sh Section I locks that asymmetry
# (the enforcement resolver must never gain this fallback — that would open a forge-a-pass hole).
# The two candidates are this PROCESS's own two env vars (both set by the /v bootstrap for THIS
# session), not a sibling's — so in normal operation the alternate IS this session's work-sid.
_sid_owns_artifact() {
  local s="$1" d g
  [ -n "$s" ] || return 1
  for d in "$ARTIFACT_DIR" "$MAIN_ROOT" "$REPO_ROOT" "$REPO_ROOT/.v/artifacts"; do
    [ -d "$d" ] || continue
    for g in "$d"/PRE_FLIGHT_REPORT_*"$s"*.md "$d"/AGENT_REVIEW_*"$s"*.md "$d"/VERIFY_DONE_REPORT_*"$s"*.md "$d"/IMPACT_MAP_*"$s"*.md; do
      [ -f "$g" ] && return 0
    done
  done
  return 1
}
_alt_sid="${CLAUDE_SESSION_ID:-}"
[ "$_alt_sid" = "$SID" ] && _alt_sid="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$_alt_sid" ] && [ "$_alt_sid" != "$SID" ] && ! _sid_owns_artifact "$SID" && _sid_owns_artifact "$_alt_sid"; then
  echo "  note: primary SID=$SID owns no artifacts — adopting alternate env SID=$_alt_sid (it owns the gauntlet artifacts; per-workstream SID override, W-perf8)" >&2
  SID="$_alt_sid"
fi

# ── Location reconciliation ──────────────────────────────────────────────────
# Consolidate any session artifact found in a worktree / CWD / legacy-root location into the
# canonical ARTIFACT_DIR (.v/artifacts) — never clobbering a copy already there. This makes a
# gauntlet that ran (or wrote legacy-style) anywhere satisfy the Stop hook, which searches
# .v/artifacts FIRST then the legacy root.
#
# The move loop is EXTRACTED to v-artifact-consolidate.sh (single source — shared with
# v-merge-back.sh's pre-worktree-removal rescue, forensic C-3/A-3 2026-06-04) so the
# self-check and the merge-back can never drift on move semantics (W-perf6 cp -p /
# strictly-newer-dst / verified-move guards live THERE now). It resolves ARTIFACT_DIR via
# the same v-artifact-dir.sh resolver (V_ARTIFACT_DIR override flows through the env) and
# sweeps the same source set this block used: REPO_ROOT, REPO_ROOT/.v/artifacts, $PWD,
# MAIN_ROOT. Best-effort: consolidation must never fail the self-check itself.
_CONSOLIDATE="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/v-artifact-consolidate.sh"
[ -f "$_CONSOLIDATE" ] || _CONSOLIDATE="$HOME/.claude/skills/v/references/v-artifact-consolidate.sh"
if [ -f "$_CONSOLIDATE" ]; then
  bash "$_CONSOLIDATE" "$SID" || true
else
  echo "  warn: v-artifact-consolidate.sh not found — skipping location reconciliation (artifacts outside .v/artifacts are still found via the legacy-root search below)" >&2
fi

# Find a session artifact: .v/artifacts FIRST (canonical), then the legacy roots (backward
# compat) — same precedence as the Stop hook's ARTIFACT_SEARCH_DIRS.
find_at_main() {
  # W-perf6 (review CODEX-003): newest-by-mtime across .v/artifacts + the legacy roots, so a
  # fresh root fix beats a stale .v/artifacts copy (matches the Stop hook's find_session_artifact).
  local _cands=() _d _g _newest
  for _d in "$ARTIFACT_DIR" "$MAIN_ROOT" "$REPO_ROOT"; do
    [ -d "$_d" ] || continue
    for _g in "${_d}/${1}_"*"${SID}"*.md; do
      [ -f "$_g" ] && _cands+=("$_g")
    done
  done
  [ ${#_cands[@]} -eq 0 ] && return 1
  _newest=$(ls -t "${_cands[@]}" 2>/dev/null | head -1)
  [ -n "$_newest" ] && { echo "$_newest"; return 0; }
  return 1
}

# ── Non-code completion bypass (TRIVIAL_PASS / PLANNING_PASS / HANDOFF) ───────
# A bypass marker short-circuits ONLY if it is STRUCTURALLY sound, using the SAME anchors
# the Stop hook validates (check-review-artifact.sh: TRIVIAL=1/REASON=/FILE=/LINES=;
# HANDOFF ≥80B + `^#+ Handoff`; PLANNING ≥80B + PLAN_FILE=/PLANNING=1). The Stop hook
# ADDITIONALLY enforces freshness + a code-shipping/≤1-file rule (TRIVIAL) and refuses the
# HANDOFF escape on shipped code (Bug-6 Phase 2) — this producer-side check can't see that
# session state, so a structurally-valid marker is NECESSARY-not-sufficient (advisory says so).
# A present-but-MALFORMED marker does NOT bypass — fall through to the full check so the model
# fixes it now instead of discovering the bounce at the gate (W-perf5 review, HIGH).
# A drift sentinel in v-contract-audit-test.sh (F5) asserts these anchors match the Stop hook.
_bypass=""
for _marker in TRIVIAL_PASS PLANNING_PASS HANDOFF; do
  _m=$(find_at_main "$_marker"); [ -n "$_m" ] || continue
  _ms=$(wc -c < "$_m" 2>/dev/null | tr -d ' \n' || echo 0)
  case "$_marker" in
    TRIVIAL_PASS)
      grep -q '^TRIVIAL=1$' "$_m" 2>/dev/null && grep -q '^REASON=' "$_m" 2>/dev/null \
        && grep -q '^FILE=' "$_m" 2>/dev/null && grep -q '^LINES=' "$_m" 2>/dev/null && _bypass="$_m" ;;
    PLANNING_PASS)
      [ "${_ms:-0}" -ge 80 ] && { grep -q '^PLAN_FILE=' "$_m" 2>/dev/null || grep -q '^PLANNING=1$' "$_m" 2>/dev/null; } && _bypass="$_m" ;;
    HANDOFF)
      [ "${_ms:-0}" -ge 80 ] && grep -qiE '^#+[[:space:]]*Handoff\b' "$_m" 2>/dev/null && _bypass="$_m" ;;
  esac
  [ -n "$_bypass" ] && break
done
if [ -n "$_bypass" ]; then
  echo "V-COMPLETION-SELFCHECK: PASS — non-code completion ($(basename "$_bypass"))"
  echo "  advisory: the Stop hook ALSO validates this marker's freshness + code-shipping rules (TRIVIAL ≤1 file; HANDOFF refused on shipped code) — a structurally-valid marker here is necessary, not sufficient" >&2
  exit 0
fi
# (A present-but-malformed bypass marker falls through to the full artifact check below.)

# READ-ONLY VERIFICATION completion (2026-07-07): a session the runner dispatched as a read-only
# verification pack (it wrote $REPO/.v/tmp/pack-readonly-<sid>.marker) that provably changed ZERO product
# code and produced a findings artifact is COMPLETE — there is nothing for the code-change gauntlet to
# review, so demanding PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE would force the model to FABRICATE gates (the
# spurious-QA-loop class). This is the producer mirror of the Stop hook's CODE_CHANGED=0
# read-only exit (check-review-artifact.sh). TRIPLE-GATED so a CODE session can NEVER take it: (1) the
# runner's read-only marker, (2) provably no product-code writes via the SHARED CODE_EXT_PATTERN/EXEMPT
# (the same predicate the Stop hook computes CODE_CHANGED from — fail-closed: if the classifier lib is
# unavailable we do NOT bypass), (3) a findings artifact on disk proving the audit actually ran.
_ro_marker=""
for _rod in "$MAIN_ROOT" "$REPO_ROOT"; do
  [ -f "$_rod/.v/tmp/pack-readonly-${SID}.marker" ] && { _ro_marker="$_rod/.v/tmp/pack-readonly-${SID}.marker"; break; }
done
if [ -n "$_ro_marker" ]; then
  for _rolib in "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh" "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/code-ext-pattern.sh"; do
    [ -f "$_rolib" ] && . "$_rolib" 2>/dev/null || true
  done
  _ro_code=unknown
  if type get_session_writes >/dev/null 2>&1 && [ -n "${CODE_EXT_PATTERN:-}" ]; then
    _ro_code="$(get_session_writes "$SID" 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "${CODE_EXT_EXEMPT:-^$}" | head -1)"
  fi
  _ro_findings=""
  for _rop in BLOCKED PRE_FLIGHT_REPORT AGENT_REVIEW; do
    _rof="$(find_at_main "$_rop" 2>/dev/null)"; [ -n "$_rof" ] && { _ro_findings="$_rof"; break; }
  done
  # (2) classifier ran AND found no product-code line (empty), AND (3) a findings artifact exists.
  if [ "$_ro_code" != unknown ] && [ -z "$_ro_code" ] && [ -n "$_ro_findings" ]; then
    echo "V-COMPLETION-SELFCHECK: PASS — read-only verification ($(basename "$_ro_findings"); no product code changed)"
    echo "  advisory: a runner-tagged read-only verification session with zero product-code writes completes on its findings artifact; the Stop hook mirrors this on CODE_CHANGED=0. If source was actually changed this bypass does NOT apply — it re-checks the writes-ledger." >&2
    exit 0
  fi
fi

REASONS=""
add_fail() { REASONS="${REASONS}
  - $1"; }

# ── Code-changing completion: validate the full artifact set at MAIN_ROOT ─────
PRE=$(find_at_main PRE_FLIGHT_REPORT)
[ -n "$PRE" ] || add_fail "PRE_FLIGHT_REPORT_${SID}.md not found in .v/artifacts ($ARTIFACT_DIR) or repo root"
if [ -n "$PRE" ]; then
  # F1-b: validate PRE_FLIGHT has Overall Status: PASS (not FAIL from wrong project or broken gates)
  if type validate_pre_flight_w53_contract >/dev/null 2>&1; then
    if ! _pf_contract_err=$(validate_pre_flight_w53_contract "$PRE" 2>&1); then
      add_fail "PRE_FLIGHT_REPORT contract: ${_pf_contract_err}"
    else
      # Contract passes — check specifically for PASS verdict
      _pf_last=$(awk 'NF { last=$0 } END { print last }' "$PRE")
      if ! echo "$_pf_last" | grep -qE '^Overall Status:[[:space:]]+PASS'; then
        add_fail "PRE_FLIGHT_REPORT Overall Status is not PASS (got: '${_pf_last}') — gates failed or report is from the wrong project; fix failing gates before completing"
      fi
    fi
  fi
  # F1-a: verify Repo: identity field matches this project (catches wrong-project pre-flight)
  _pf_repo=$(grep -E '^Repo:[[:space:]]' "$PRE" 2>/dev/null | head -1 | sed 's/^Repo:[[:space:]]*//')
  if [ -n "$_pf_repo" ] && [ "$_pf_repo" != "$MAIN_ROOT" ] && [ "$_pf_repo" != "$REPO_ROOT" ]; then
    add_fail "PRE_FLIGHT_REPORT identity mismatch: report Repo='${_pf_repo}' but this session's root is '${MAIN_ROOT}' — pre-flight ran against the wrong project (W3-31: pre-flight ran against ~/.claude/skills instead of the session's own project, producing a 960B FAIL report)"
  fi
fi

REV=$(find_at_main AGENT_REVIEW)
if [ -n "$REV" ]; then
  # 5th arg 1 = allow honest-degraded (O2): the self-check pairs _independence_verdict (parity with the Stop
  # hook), so the forgery backstop is present — relaxing the codex-name requirement here is safe (CODEX-001).
  if ! _r=$(validate_review_semantics "$REV" 1 "" "$SID" 1 2>/dev/null); then
    add_fail "AGENT_REVIEW invalid: ${_r}"
  fi
fi
if [ -z "$REV" ]; then
  add_fail "AGENT_REVIEW_${SID}.md not found in .v/artifacts (or root)"
fi

# ── W22-P2: producer-side review-INDEPENDENCE — SINGLE-SOURCED via _independence_verdict ─────────
# This file's whole purpose: "the producer-side check and the Stop gate can NEVER disagree." It used
# to RE-IMPLEMENT the independence decision (an inline-signature regex), and that re-implementation
# DRIFTED — a past incident: a fabricated AGENT_REVIEW claiming "Dispatch mode: subagent-dispatched"
# had no inline signature, so this self-check ACCEPTED it, while the Stop hook's _independence_verdict
# (which demands POSITIVE dispatch evidence) returned 'silent' (=BLOCK). /v reported "review PASS" and
# then got blocked at Stop — it lied about finishing. The fix: call the SAME hooks/lib/validation.sh
# function the Stop hook calls, with the SAME inputs, and mirror C3b's verdict→action exactly. They
# now run identical code → cannot disagree. Parity is locked by v-completion-parity-test.sh.
#
# Gather the independence signals the shared verdict reads (SESSION_ID + provenance search dirs +
# transcript signals) the SAME way the Stop hook does, so the verdict matches by construction.
SESSION_ID="$SID"
ARTIFACT_SEARCH_DIRS=("$ARTIFACT_DIR" "$MAIN_ROOT" "$REPO_ROOT")
_prep_independence_signals "$SID"
if [ -n "$REV" ]; then
  case "$(_independence_verdict "$REV" codex-adversarial-reviewer)" in
    # F2 (2026-08-29): `edited-declared` = a real dispatch IS on record, the edit is declared, and
    # the dispatched original survives. Accept, exactly as the Stop hook's new arm does. Listed
    # EXPLICITLY rather than left to fall through this armless case: an unhandled token here would
    # be accepted only by accident, and the next reader could not tell that was intended.
    dispatched|unverifiable) : ;;   # independent dispatch on record, or transcript absent (FP-safe)
    edited-declared)
      # PARITY (close-out audit, 2026-08-29): this arm previously accepted `edited-declared`
      # UNCONDITIONALLY, while the Stop hook BLOCKS it when the declared edit discloses (or the
      # archived original proves) a changed finding/verdict/severity — check-review-artifact.sh sets
      # MISSING_REVIEW=1 there. This file exists precisely so the producer self-check and the Stop
      # hook cannot disagree; an unconditional accept re-created the divergence it guards against
      # (a session would self-report READY and then be blocked at Stop). Call the SAME shared guard.
      if type _declared_edit_discloses_verdict_change >/dev/null 2>&1 \
         && _declared_edit_discloses_verdict_change "$REV"; then
        add_fail "AGENT_REVIEW was edited AFTER its independent dispatch and the edit changes a finding/verdict/severity (declared edits may fix prose, never the reviewer's conclusion). Re-dispatch the reviewer, or record the disagreement in a separate AGENT_REVIEW_ADDENDUM_${SID}.md with its own provenance. The Stop hook blocks exactly this. (F2-B1MIRROR parity.)"
      fi ;;
    declared)
      # Honest inline/degraded is accepted ONLY when the mandatory superpowers:requesting-code-review
      # fallback was actually ATTEMPTED — mirror check-review-artifact.sh C3b (N5/W5F-6): a bare
      # mention is not an attempt; require an outcome token. Regex kept byte-identical to the gate.
      if grep -iE 'superpowers|requesting.code.review' "$REV" 2>/dev/null \
         | grep -qiE 'attempt|tried|returned|failed|error|unavailable|not[[:space:]]+installed|unknown[[:space:]]+skill|timed?[[:space:]]?out|no[[:space:]]+reviewer|rc=[0-9]|exit[[:space:]]?(code|status)?[[:space:]]?[0-9]|fell[[:space:]]+back'; then
        :   # declared + documented superpowers attempt → accepted (warn-only at the Stop hook)
      else
        add_fail "AGENT_REVIEW declares an inline/degraded fallback without documenting a superpowers:requesting-code-review attempt — the mandatory fallback chain was skipped, and the Stop hook blocks exactly this. Add 'superpowers fallback attempted: <result>' to the AGENT_REVIEW, or dispatch codex-adversarial-reviewer. (W22-P2, single-sourced via _independence_verdict.)"
      fi ;;
    edited)
      add_fail "AGENT_REVIEW was modified AFTER its independent dispatch (provenance sha256 mismatch — W5G-4); the reviewer's output is canonical. Re-dispatch the reviewer, or add a 'Post-dispatch edit: <reason>' line. (W22-P2, single-sourced.)" ;;
    silent)
      # FIX-6: parity with check-review-artifact.sh — distinguish a FORGED dispatch claim from an
      # undisclosed honest inline via the SAME shared _independence_silent_reason helper.
      if [ "$(_independence_silent_reason "$REV")" = "claimed-dispatch" ]; then
        add_fail "AGENT_REVIEW claims a dispatch mode ('Dispatch mode: subagent-dispatched|foreground|background' or 'codex … ran') but NO provenance backs it — a forged independence claim, not honest degradation. Dispatch the reviewer for real via v-dispatch-subagent.sh (so provenance exists), or STOP claiming a dispatch and declare the inline fallback honestly with 'Dispatch mode: orchestrator-inline (reason)'. The Stop hook's _independence_verdict returns 'silent' (=BLOCK) on exactly this. (W22-P2; a past incident fabricated 'Dispatch mode: subagent-dispatched'.)"
      else
        add_fail "AGENT_REVIEW is an orchestrator-inline / self-review with no independent dispatch and no documented superpowers:requesting-code-review fallback — an orchestrator reviewing its own diff is not an independent reviewer, and the Stop hook's _independence_verdict returns 'silent' (=BLOCK) on exactly this. Dispatch codex-adversarial-reviewer (or superpowers) and re-run, OR honestly declare the inline fallback. (W22-P2, single-sourced via _independence_verdict.)"
      fi ;;
  esac
fi

VD=$(find_at_main VERIFY_DONE_REPORT)
[ -n "$VD" ] || add_fail "VERIFY_DONE_REPORT_${SID}.md not found in .v/artifacts (or root)"

IM=$(find_at_main IMPACT_MAP)
if ! _r=$(validate_impact_map_semantics "$IM" 2>/dev/null); then
  add_fail "IMPACT_MAP ${_r}"
fi

# P7-B: SUCCESS_CRITERIA / WORKFLOW_BLAST_RADIUS validate-if-present (Step 1.7/1.6) — single-sourced
# with check-review-artifact.sh so the producer self-check and Stop hook agree (C1 parity, review
# 2026-06-22). Absence is legitimate (conditionally produced); only a present-but-malformed stub fails.
SC=$(find_at_main SUCCESS_CRITERIA)
if [ -n "$SC" ] && ! _r=$(validate_success_criteria_structure "$SC" 2>/dev/null); then
  add_fail "SUCCESS_CRITERIA present but malformed: ${_r}"
fi
BR=$(find_at_main WORKFLOW_BLAST_RADIUS)
if [ -n "$BR" ] && ! _r=$(validate_blast_radius_structure "$BR" 2>/dev/null); then
  add_fail "WORKFLOW_BLAST_RADIUS present but malformed: ${_r}"
fi

QA=$(find_at_main QA_REPORT)
if _qv=$(validate_qa_report_structure "$QA" 2>/dev/null); then
  case "$_qv" in
    pass) : ;;
    escalated)
      [ -n "$(find_at_main BLOCKED)" ] || add_fail "QA verdict: escalated but no BLOCKED_${SID}.md companion at MAIN_ROOT" ;;
    *) add_fail "QA verdict is '${_qv:-none}', not pass — the Step 6.4.9 loop must converge to pass or escalate (with BLOCKED)" ;;
  esac
else
  add_fail "QA_REPORT ${_qv}"
fi

# ── W22-P2b: producer-side QA-INDEPENDENCE — SINGLE-SOURCED via _independence_verdict ────────────
# validate_qa_report_structure (above) checks the VERDICT, not independence. This used to RE-IMPLEMENT
# the QA-independence decision and DRIFTED from the Stop hook (one session hand-authored a
# verdict:pass QA that the self-check accepted and only the Stop hook caught). Now it calls the SAME
# _independence_verdict the Stop hook calls, with the SAME signals prepped above, and mirrors the
# Stop hook's QA verdict→action exactly. Scoped to verdict:pass — an escalated QA (with its required
# BLOCKED companion) is the honest non-completion fallback and must NOT be independence-blocked.
if [ -n "$QA" ] && [ "${_qv:-}" = "pass" ]; then
  case "$(_independence_verdict "$QA" v-qa-reviewer)" in
    dispatched|declared) : ;;   # real dispatch, or honest declared fallback
    edited-declared)
      # PARITY (close-out audit, 2026-08-29): mirrors check-review-artifact.sh's QA arm, which sets
      # MISSING_QA=1 when the declared edit changes the verdict. Unconditional accept here would let
      # a session self-report READY on a QA report the Stop hook will block.
      if type _declared_edit_discloses_verdict_change >/dev/null 2>&1 \
         && _declared_edit_discloses_verdict_change "$QA"; then
        add_fail "QA_REPORT was edited AFTER its independent v-qa-reviewer dispatch and the edit changes the verdict/finding/severity. QA is the final behavioral filter; the reviewer's verdict is canonical. Re-dispatch QA, or record the disagreement in a separate QA_ADDENDUM_${SID}.md with its own provenance. The Stop hook blocks exactly this. (F2-B1MIRROR parity.)"
      fi ;;
    unverifiable)
      # I1 (forensic 2026-06-17): transcript unreadable here too — accept ONLY if a tamper
      # baseline sha exists; otherwise zero tamper-evidence -> fail-close (PARITY with the Stop hook,
      # which mirrors this exactly). A baseline-present unverifiable stays FP-safe (accepted).
      _provenance_baseline_exists "$(basename "$QA")" || add_fail "QA_REPORT reports verdict: pass but carries NO tamper-evidence baseline — independence is unverifiable (no transcript) AND no DISPATCH_PROVENANCE status=ok sha256 line records QA_REPORT, so a post-hoc fail->pass flip would be undetectable. Dispatch v-qa-reviewer (it self-records its sha), or declare inline honestly AND append a DISPATCH_PROVENANCE sha line. (I1, single-sourced via _provenance_baseline_exists.)" ;;
    edited)
      add_fail "QA_REPORT was modified AFTER its independent v-qa-reviewer dispatch (provenance sha256 mismatch — W5G-4); the reviewer's output is canonical. Re-dispatch QA, or add a 'Post-dispatch edit: <reason>' line. (W22-P2b, single-sourced.)" ;;
    silent)
      add_fail "QA_REPORT shows no independent v-qa-reviewer dispatch (no subagent_type=v-qa-reviewer, no v-dispatch-subagent.sh subprocess, no DISPATCH_PROVENANCE status=ok) and no honest 'dispatch: inline'/'degraded:' declaration — an orchestrator writing its own QA verdict defeats the independent-QA gate, and the Stop hook blocks exactly this as 'silent'. Dispatch v-qa-reviewer (Agent tool or v-dispatch-subagent.sh), or declare the degraded fallback in the report. (W22-P2b, single-sourced via _independence_verdict; a past incident hand-authored its QA_REPORT.)" ;;
  esac
fi

# UI sessions additionally need UX_CRITIQUE + WORKFLOW_VERIFICATION (Step 3.5).
# Treat the session as UI if the orchestrator says so (V_UI_SESSION=1) OR either
# artifact already exists for this SID (presence implies a UI session ran them).
_is_ui=0
[ "${V_UI_SESSION:-0}" = "1" ] && _is_ui=1
{ [ -n "$(find_at_main UX_CRITIQUE)" ] || [ -n "$(find_at_main WORKFLOW_VERIFICATION)" ]; } && _is_ui=1
# P1.1 (forensic finding): ALSO path-detect UI the SAME way the Stop hook does — via
# any_user_facing_ui over the session's changed paths (get_session_writes). The old detection relied
# on the orchestrator self-flagging V_UI_SESSION=1; that session didn't, so this producer gate PASSED a
# UI session the Stop hook blocks (UX_CRITIQUE/WORKFLOW missing) → the producer↔Stop-hook contract
# ("what passes here passes there") was violated on the UI axis. Additive — only ADDS _is_ui=1.
if [ "$_is_ui" != "1" ]; then
  for _uilib in "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/ui-path-pattern.sh" "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh"; do
    [ -f "$_uilib" ] && . "$_uilib"
  done
  if type get_session_writes >/dev/null 2>&1 && type any_user_facing_ui >/dev/null 2>&1; then
    _ui_changed=$(get_session_writes "$SID" 2>/dev/null | grep -v '^\[subagent-dispatch\]$' || true)
    # codex review (MEDIUM): the writes log is empty/unreliable in the forked/headless runner, but the
    # Stop hook ALSO derives changed paths from a git diff (committed START_HEAD..HEAD). Without the
    # same fallback an inline-on-main UI session with an empty writes log would PASS here while the Stop
    # hook BLOCKS it — re-opening the producer↔gate disagreement on the empty-writes axis. Mirror the
    # Stop hook: when the writes log is empty, fall back to the session's COMMITTED diff vs its baseline.
    if [ -z "$_ui_changed" ]; then
      _hb="$MAIN_ROOT/.v/tmp/head-baseline-${SID}.txt"
      if [ -f "$_hb" ]; then
        _base=$(head -1 "$_hb" 2>/dev/null | tr -d '[:space:]')
        if [ -n "$_base" ] && git -C "$MAIN_ROOT" cat-file -e "${_base}^{commit}" 2>/dev/null; then
          _ui_changed=$(git -C "$MAIN_ROOT" diff --name-only "${_base}..HEAD" 2>/dev/null || true)
        fi
      fi
    fi
    [ -n "$_ui_changed" ] && any_user_facing_ui "$_ui_changed" && _is_ui=1
  fi
fi
if [ "$_is_ui" = "1" ]; then
  # Structural validation via the SAME lib validators the Stop hook calls (not mere
  # existence) — closes the self-check↔gate axis for UX/WORKFLOW too, so a malformed
  # UX_CRITIQUE / WORKFLOW_VERIFICATION fails HERE instead of bouncing at the gate.
  if ! _r=$(validate_ux_critique_structure "$(find_at_main UX_CRITIQUE)" 2>/dev/null); then
    add_fail "UX_CRITIQUE ${_r} (UI session — Step 3.5)"
  fi
  if _ws=$(validate_workflow_verification_structure "$(find_at_main WORKFLOW_VERIFICATION)" 2>/dev/null); then
    [ "$_ws" = "fail" ] && add_fail "WORKFLOW_VERIFICATION status: fail — a flow broke in the browser (fix WF-* findings, re-run the verifier)"
  else
    add_fail "WORKFLOW_VERIFICATION ${_ws} (UI session — Step 3.5)"
  fi
fi

# ── SURVIVAL GATE (1A, single-sourced via _survival_verdict) ─────────────────────────────────────
# The producer↔Stop-hook contract on the SURVIVAL axis: a session whose WRITTEN source silently
# vanished (a shared-tree clobber) must be caught HERE too, so /v cannot report
# "done" on work the Stop hook will block. Mode MIRRORS the Stop hook ($V_SURVIVAL_GATE): block →
# add_fail (so /v knows it will bounce); warn (default) → observe only (no completion failure) → keeps
# self-check ⟺ Stop-hook accept/block parity in BOTH modes. A HANDOFF/TRIVIAL/PLANNING session already
# exited PASS above, and _survival_verdict itself skips on a deferral marker — so a declared-incomplete
# session never reaches a 'lost' verdict here.
_SV_MODE="${V_SURVIVAL_GATE:-block}"
if [ "$_SV_MODE" != "off" ] && [ -n "$SID" ] && type _survival_verdict >/dev/null 2>&1; then
  # Mirror the Stop hook EXACTLY: evaluate in BOTH block and warn modes (framework-pitfall review —
  # gating the CALL on block left the self-check silent in warn mode while the Stop hook still warned).
  # block (default) → add_fail; warn → stderr advisory (observable, non-failing). RECOVERABLE: this
  # fires DURING the session, so the orchestrator re-applies + commits the lost work and re-runs → PASS.
  case "$(_survival_verdict "$SID" "$MAIN_ROOT" 2>/dev/null)" in
    lost:*)
      if [ "$_SV_MODE" = "block" ]; then
        add_fail "SURVIVAL GATE: this session's WRITTEN source files no longer exist in the working tree, any commit since baseline, or a session worktree (and there is no HANDOFF/MERGE_DEFERRED marker) — the deliverable was silently wiped (a shared-tree clobber) and the Stop hook blocks exactly this. RECOVER (do NOT stop — this is your autonomous re-apply loop): RE-CREATE each lost file FIRST (the work is gone — committing the current wiped state does nothing), THEN 'git add' + 'git commit' it IMMEDIATELY (committed work cannot be clobbered), then re-run THIS self-check — it will pass. (1A, single-sourced via _survival_verdict.)"
      else
        echo "  advisory (survival, observe mode): this session's written source appears wiped (no diff vs baseline anywhere, no HANDOFF/MERGE_DEFERRED) — a shared-tree clobber. Set V_SURVIVAL_GATE=block to enforce. (1A)" >&2
      fi ;;
  esac
fi

# ── EXPOSED-INLINE-WORK GATE (1B, single-sourced via _exposed_inline_verdict) ─────────────────────
# Producer↔Stop-hook contract on the EXPOSURE axis: a session that left source UNCOMMITTED inline on
# shared main while siblings are active must be caught HERE too. Mode mirrors the Stop hook
# ($V_EXPOSED_GATE: block default | warn | off). RECOVERABLE: commit your own files (scoped) → re-run → PASS.
_EX_MODE="${V_EXPOSED_GATE:-block}"
if [ "$_EX_MODE" != "off" ] && [ -n "$SID" ] && type _exposed_inline_verdict >/dev/null 2>&1; then
  case "$(_exposed_inline_verdict "$SID" "$MAIN_ROOT" 2>/dev/null)" in
    exposed:*)
      if [ "$_EX_MODE" = "block" ]; then
        add_fail "EXPOSED INLINE WORK: this session's written source is sitting UNCOMMITTED on shared main while sibling /v sessions are active — a concurrent sibling's stash can clobber it, and the Stop hook blocks exactly this. RECOVER: commit your OWN files now — SCOPED, never 'git add -A' (that sweeps up a sibling's work): 'git add <your files> && git commit', then re-run THIS self-check — it will pass. FIRST confirm each file's current content is YOUR work — if a sibling concurrently edited the same file, commit only your own hunks. (1B, single-sourced via _exposed_inline_verdict; CLAUDE.md V_DEPTH>=1 checkpoint policy authorizes the scoped commit.)"
      else
        echo "  advisory (exposed-inline, observe mode): written source is uncommitted on shared main with active siblings — commit your own files (scoped) to protect them. Set V_EXPOSED_GATE=block to enforce. (1B)" >&2
      fi ;;
  esac
fi

if [ -n "$REASONS" ]; then
  echo "V-COMPLETION-SELFCHECK: FAIL${REASONS}"
  exit 1
fi

# Advisory only (NOT a fail): uncommitted changes. The Stop hook's session-scoped
# writes gate is authoritative; a blanket porcelain check here would false-fail on a
# parallel session's dirt (cross-session contamination).
if [ -n "$(git -C "$MAIN_ROOT" status --porcelain 2>/dev/null | grep -v '^??' | head -1)" ]; then
  echo "  advisory: uncommitted tracked changes remain at MAIN_ROOT — commit session-owned work before the Stop hook runs" >&2
fi

# Advisory only (W5G-4 mirror, 2026-06-07): post-dispatch artifact tampering. The Stop
# hook BLOCKS a dispatched artifact whose on-disk sha256 no longer matches the hash the
# dispatcher recorded in DISPATCH_PROVENANCE (a production session hand-padded the runner's
# 766B PRE_FLIGHT to 1425B under 'Model: haiku'). Warn HERE so the model learns before
# the gate bounces it. Advisory (not add_fail) keeps this producer check FP-free:
# legacy provenance lines without sha256= are skipped; a re-dispatch re-records the hash.
# E-D3 (audit 2026-06-18): dual shasum/sha256sum detection — `shasum` is macOS-only; on Linux CI
# only `sha256sum` exists, so the prior `shasum`-only guard silently skipped the W5G-4 tamper
# advisory there. Parity with FIX-5 in validation.sh / v-dispatch-subagent.sh.
_sc_sha_cmd=""
if command -v shasum >/dev/null 2>&1; then _sc_sha_cmd="shasum -a 256"
elif command -v sha256sum >/dev/null 2>&1; then _sc_sha_cmd="sha256sum"; fi
if [ -n "$_sc_sha_cmd" ]; then
  for _w5g4_f in "$(find_at_main PRE_FLIGHT_REPORT)" "$(find_at_main QA_REPORT)" "$(find_at_main AGENT_REVIEW)" "$(find_at_main WORKFLOW_VERIFICATION)"; do
    [ -n "$_w5g4_f" ] && [ -f "$_w5g4_f" ] || continue
    _w5g4_base=$(basename "$_w5g4_f")
    _w5g4_rec=""
    for _d in "$ARTIFACT_DIR" "$MAIN_ROOT" "$REPO_ROOT"; do
      [ -d "$_d" ] || continue
      _pl="$_d/DISPATCH_PROVENANCE_${SID}.log"
      if [ -f "$_pl" ]; then
        _w5g4_rec=$(grep -E "\|status=ok\|.*\|artifact=${_w5g4_base}\|sha256=[0-9a-fA-F]{64}$" "$_pl" 2>/dev/null | sort | tail -1 | sed -nE 's/.*\|sha256=([0-9a-fA-F]{64})$/\1/p')
        [ -n "$_w5g4_rec" ] && break
      fi
    done
    [ -n "$_w5g4_rec" ] || continue
    _w5g4_cur=$($_sc_sha_cmd "$_w5g4_f" 2>/dev/null | awk '{print $1}')
    if [ -n "$_w5g4_cur" ] && [ "$_w5g4_cur" != "$_w5g4_rec" ] \
       && ! grep -qiE '^Post-dispatch edit:' "$_w5g4_f" 2>/dev/null; then
      echo "  advisory (W5G-4): ${_w5g4_base} was modified AFTER its independent dispatch (provenance sha256 mismatch) — the Stop hook will BLOCK this. Re-dispatch the gate, or add an explicit 'Post-dispatch edit: <reason>' line." >&2
    fi
  done
fi

echo "V-COMPLETION-SELFCHECK: PASS"
exit 0
