#!/usr/bin/env bash
# v-artifact-validate-all.sh <sid> [search_dir ...] — validate ALL gauntlet artifacts for a session in
# ONE shot and report EVERY format problem, not one-per-Stop-hook-cycle.
#
# WHY (forensic 2026-06-19, 4-session wave): the artifact gauntlet was a guess-and-check death-march —
# the Stop hook surfaces one format error per completion attempt (missing Model: line, then a status
# line, then a field, then a heading case…), so sessions burned 15–40 min iterating AND, cornered,
# drifted into fabricating provenance / renaming .invalid logs. Running this BEFORE finishing collapses
# that loop: it prints a PASS/FAIL line for each of the 7 gauntlet artifacts with the validator's exact
# message, so every fixable problem is visible at once.
#
# SCOPE: this checks artifact STRUCTURE via the same functions the Stop hook uses (hooks/lib/validation.sh).
# It does NOT evaluate the diff-dependent gates (W59-F2 hostile-dispatch requirement, the gauntlet-attest
# HMAC witness, FND-3 merge state); those are reported by the Stop hook itself. A clean run here means
# "format will not block you," which is ~90% of the historical death-march.
#
# Exit: 0 if no PRESENT artifact is invalid; 1 if any present artifact fails its validator. Absent
# artifacts are reported as "absent" (informational — the Stop hook decides which are required).
set -u

SID="${1:-${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
[ -n "$SID" ] || { echo "usage: v-artifact-validate-all.sh <session-id> [search_dir ...]" >&2; exit 2; }
shift 2>/dev/null || true

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
VALIDATION_LIB="${V_VALIDATION_LIB:-$CLAUDE_DIR/hooks/lib/validation.sh}"
[ -f "$VALIDATION_LIB" ] || { echo "ERROR: validation lib not found: $VALIDATION_LIB" >&2; exit 2; }
# shellcheck source=/dev/null
. "$VALIDATION_LIB" 2>/dev/null || { echo "ERROR: could not source $VALIDATION_LIB" >&2; exit 2; }

# Search dirs: explicit args win; else the conventional locations the Stop hook also searches.
#
# W-CWD1 (forensic 2026-07-14): the default was ("$PWD/.v/artifacts" "$PWD"), which
# made the verdict depend on the caller's cwd. The Bash tool's cwd drifts routinely (to a scratch
# subdir, to ~/.claude after editing a hook), so a session with a full, VALID artifact set on disk got
# "0 ok, 0 invalid, 7 absent" — a false TOTAL-LOSS reading. That is the exact trigger for the
# fabrication drift this script exists to prevent (see header): believing the artifacts vanished, a
# cornered session re-creates them from prose. Anchor to the REPO ROOT instead, and mirror the Stop
# hook's own ARTIFACT_SEARCH_DIRS (repo + main, each with .v/artifacts then the legacy root) so this
# validator and the gate it previews can never disagree on WHERE to look.
#
# GIT_* are scrubbed per the protect-main-branch.sh `_pmb_git` precedent: resolve_git_paths exports a
# RELATIVE GIT_COMMON_DIR (../.git) when invoked from a subdirectory, which silently poisons
# rev-parse/worktree-list in exactly the subdir case this fix targets.
if [ "$#" -gt 0 ]; then
  SEARCH_DIRS=("$@")
else
  _vaa_git(){ env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE git "$@"; }
  _vaa_repo="$(_vaa_git rev-parse --show-toplevel 2>/dev/null)" || _vaa_repo=""
  [ -n "$_vaa_repo" ] || _vaa_repo="${CLAUDE_PROJECT_DIR:-$PWD}"
  _vaa_main="$(_vaa_git worktree list 2>/dev/null | head -1 | awk '{print $1}')"
  _vaa_main="${_vaa_main:-$_vaa_repo}"
  SEARCH_DIRS=("$_vaa_repo/.v/artifacts" "$_vaa_repo")
  # Only add the main checkout when it differs (worktree sessions) — keeps the list dedup'd.
  [ "$_vaa_main" = "$_vaa_repo" ] || SEARCH_DIRS+=("$_vaa_main/.v/artifacts" "$_vaa_main")
fi

_find_artifact() {  # <PREFIX> -> echoes the newest matching file path, or empty
  # ORCHFIX-A1 (-postmerge split-brain): prefer the exact CANONICAL name over suffixed
  # variants (-postmerge, -v2, …) — same disambiguation rule as the Stop hook's
  # find_session_artifact and v-gauntlet-attest's canonical binding, so all verdict
  # consumers agree when a variant coexists. Variants are only considered when no canonical
  # file exists in ANY search dir.
  #
  # F1 (2026-07-05): delegate the picking algorithm to hooks/lib/gauntlet-witness.sh's
  # gauntlet_find_artifact() — single source of truth with check-review-artifact.sh,
  # enforce-pre-commit-gates.sh, and v-gauntlet-attest.sh. This fixes a residual divergence:
  # the inline copy below was FIRST-DIR-WINS within each pass (canonical, then variant),
  # not newest-mtime-across-ALL-dirs — so with a canonical copy in TWO dirs, this validator
  # could grade a different (staler) file than the Stop hook validates. Lazily source the lib
  # in-function (covers awk-extraction harnesses like postmerge-variant-resolution-test.sh);
  # keep the prior inline logic as a defense-in-depth fallback only.
  local prefix="$1" d f
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh" 2>/dev/null || true
  fi
  if type gauntlet_find_artifact >/dev/null 2>&1; then
    gauntlet_find_artifact "$prefix" "$SID" "${SEARCH_DIRS[@]}"
    return $?
  fi
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    [ -f "$d/${prefix}_${SID}.md" ] && { printf '%s' "$d/${prefix}_${SID}.md"; return 0; }
  done
  for d in "${SEARCH_DIRS[@]}"; do
    [ -d "$d" ] || continue
    f=$(ls -1t "$d/${prefix}_${SID}"*.md 2>/dev/null | head -1 || true)
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

OK=0; FAIL=0; ABSENT=0

_check() {  # <prefix> <display-name> — finds the artifact and runs its validator (file-first arg order)
  local prefix="$1" name="$2" file msg rc
  if ! file=$(_find_artifact "$prefix"); then
    printf '  absent  %s\n' "$name"; ABSENT=$((ABSENT + 1)); return 0
  fi
  case "$prefix" in
    PRE_FLIGHT_REPORT)     msg=$(validate_pre_flight_w53_contract "$file" 2>&1); rc=$? ;;
    VERIFY_DONE_REPORT)    msg=$(validate_verify_done_w53_contract "$file" 2>&1); rc=$? ;;
    AGENT_REVIEW)          msg=$(validate_review_semantics "$file" 1 0 "$SID" 1 2>&1); rc=$? ;;
    IMPACT_MAP)            msg=$(validate_impact_map_semantics "$file" 2>&1); rc=$? ;;
    QA_REPORT)             msg=$(validate_qa_report_structure "$file" 2>&1); rc=$? ;;
    UX_CRITIQUE)           msg=$(validate_ux_critique_structure "$file" 2>&1); rc=$? ;;
    WORKFLOW_VERIFICATION) msg=$(validate_workflow_verification_structure "$file" 2>&1); rc=$? ;;
    *) printf '  ERROR   unknown prefix %s\n' "$prefix"; FAIL=$((FAIL + 1)); return 0 ;;
  esac
  if [ "$rc" -eq 0 ]; then
    printf '  ok      %s (%s)\n' "$name" "$(basename "$file")"; OK=$((OK + 1))
    # F-3 (forensic 2026-07-04): a structurally-VALID VERIFY_DONE that ran no-isolation still cannot
    # gate a merge (v-merge-back W-GATE rejects it). Surface it HERE at completion (advisory — not a
    # board FAIL) so the fix happens in one pass, not at the later merge step. A session's fabricated
    # PASS narration sailing through artifact validation was the same seam.
    if [ "$prefix" = "VERIFY_DONE_REPORT" ] && type verify_done_no_isolation >/dev/null 2>&1 \
       && verify_done_no_isolation "$file"; then
      printf '          ↳ ADVISORY: ran no-isolation scope — v-merge-back will REJECT this at merge (its verdict does not verify this session'"'"'s diff). Re-run /v-verify-done in the session'"'"'s worktree before merging.\n'
    fi
  else
    # SREV-001 emission contract (2026-07-05): EVERY line of the validator reason must carry the
    # `↳ ` prefix, not just the first. Validator reasons can embed artifact-derived content (e.g.
    # verify-done's "(got: '<artifact last line>')"), and line-oriented consumers strip that detail
    # by dropping ↳-marked lines (v-artifact-board.sh's injection guard). The old single printf
    # (`↳ %s` with a multi-line $msg) prefixed only line 1 — continuation lines from a batched
    # multi-error manifest (E1 in hooks/lib/validation.sh; validate_review_semantics' P1 flush
    # predates E1 with the same shape) sailed through the strip and REOPENED the SREV-001
    # prompt-injection surface. Pinned by v-artifact-board-test.sh (SREV-001 case, end-to-end) +
    # v-artifact-validate-all-test.sh Scenario 5 (emission contract, red-proven vs this printf).
    printf '  FAIL    %s\n' "$name"
    printf '%s\n' "$msg" | sed 's/^/          ↳ /'
    FAIL=$((FAIL + 1))
  fi
}

echo "── v-artifact-validate-all: session $SID ──"
# LEGEND (2026-08-03): 'absent' means NOT PRESENT — it does NOT mean REQUIRED. This board checks all
# seven prefixes unconditionally; the Stop hook alone decides which are actually owed for a given
# diff. Rows tagged below are conditionally gated and are frequently NOT required at all:
#   UX_CRITIQUE / WORKFLOW_VERIFICATION — fire only when the diff touches user-facing UI paths
#     (hooks/lib/ui-path-pattern.sh: tsx|jsx|css|scss|sass|vue|svelte, .blade.php,
#     resources/{css,styles,views}/, tailwind.config). A .ts/.yml/config-only diff owes NEITHER.
#   IMPACT_MAP / QA_REPORT — gated on CODE_CHANGED, and waived on a LIGHT-tier diff.
# WHY THIS LEGEND EXISTS: on 2026-08-03 a full-context reader with every file open misread this
# board as a seven-artifact demand on a 2-file CI-config change, when only ~4 were actually owed.
# An unqualified 'absent' next to a gate name reads as an obligation. It is not one.
echo "   legend: 'absent' = not present, NOT 'required' — the Stop hook decides what is owed."
_check PRE_FLIGHT_REPORT     "PRE_FLIGHT_REPORT    "
_check AGENT_REVIEW          "AGENT_REVIEW         "
_check VERIFY_DONE_REPORT    "VERIFY_DONE_REPORT   "
_check IMPACT_MAP            "IMPACT_MAP            (code diffs; waived on LIGHT tier)"
_check QA_REPORT            "QA_REPORT             (code diffs; waived on LIGHT tier)"
_check UX_CRITIQUE          "UX_CRITIQUE           (UI-path diffs ONLY)"
_check WORKFLOW_VERIFICATION "WORKFLOW_VERIFICATION (UI-path diffs ONLY)"
echo "── ${OK} ok, ${FAIL} invalid, ${ABSENT} absent ──"
echo "   NOTE: STRUCTURE only. A clean run here does NOT guarantee the Stop hook passes — it does NOT run the"
echo "   semantic/independence gates: review-dispatch provenance (_independence_verdict), W59-F2 hostile-dispatch,"
echo "   the gauntlet-attest HMAC witness, FND-3 merge-back state, or QA verdict adjudication. Those need a REAL"
echo "   dispatch + merge — do not fabricate them to make this pass."
[ "$FAIL" -eq 0 ]
