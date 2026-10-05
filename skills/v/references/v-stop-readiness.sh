#!/usr/bin/env bash
# v-stop-readiness.sh <sid> [repo]
#
# ADVISORY pre-stop readiness preview. Runs the DOMINANT /v Stop-gate checks in one shot and prints a
# ✅/❌ checklist with the exact fix per blocker, so a /v session clears EVERY blocker in ONE remediation
# pass instead of the block→fix→block→fix thrash that dominates cost (forensic: 7 Stop-blocks ->
# 677 of 939 turns post-block = 76% of a run's cost; another session rewrote AGENT_REVIEW 5x guessing
# the format). NON-AUTHORITATIVE: the real Stop hook (check-review-artifact.sh) still enforces — this only
# FRONT-RUNS it, so being incomplete just costs one extra cycle, never a weakened gate. Reuses the SAME
# validators (v-artifact-validate-all.sh + validation.sh verdict functions) to minimize drift. Every check
# is defensive; the script ALWAYS exits 0 (advisory; never blocks, never crashes a session).
set -uo pipefail
SID="${1:-${CLAUDE_SESSION_ID:-}}"
REPO="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -n "$SID" ] || { echo "usage: v-stop-readiness.sh <sid> [repo]"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || HERE="$PWD"
HLIB="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}"
# shellcheck source=/dev/null
[ -f "$HLIB/validation.sh" ] && . "$HLIB/validation.sh" 2>/dev/null || true
# The validation.sh verdict functions key on the global SESSION_ID and search ARTIFACT_SEARCH_DIRS for
# DISPATCH_PROVENANCE — populate BOTH exactly as the Stop hook does (check-review-artifact.sh:184-186) so
# the verdict here matches the real gate, and so the `${ARTIFACT_SEARCH_DIRS[@]}` ref does not trip set -u.
SESSION_ID="$SID"
MAIN="$(git -C "$REPO" worktree list 2>/dev/null | awk 'NR==1{print $1}')"; [ -n "$MAIN" ] || MAIN="$REPO"
ARTIFACT_SEARCH_DIRS=("$REPO/.v/artifacts" "$REPO" "$MAIN/.v/artifacts" "$MAIN")
# Transcript dispatch signals the independence verdict also consults — computed the SAME way the Stop hook
# does (check-review-artifact.sh:1382-1399) so a real Agent-tool reviewer dispatch (transcript subagent_type
# but maybe no DISPATCH_PROVENANCE) is recognized, AND so the unbound refs don't trip set -u.
TRANSCRIPT_PATH="$(ls -1 "$HOME/.claude/projects/"*"/${SID}.jsonl" 2>/dev/null | head -1)"
TRANSCRIPT_READABLE=0; [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ] && TRANSCRIPT_READABLE=1
_TX_SIGNALS=""
if [ "$TRANSCRIPT_READABLE" -eq 1 ]; then
  _TX_SIGNALS="$(grep -hoE '"subagent_type":"[^"]*"|v-dispatch-subagent\.sh[^"]{0,80}--agent[ ="]+[A-Za-z0-9_-]+|"model":"[^"]*"' "$TRANSCRIPT_PATH" 2>/dev/null || true)"
  _subdir="$(dirname "$TRANSCRIPT_PATH")/${SID}/subagents"
  [ -d "$_subdir" ] && _TX_SIGNALS="$_TX_SIGNALS
$(grep -rhoE '"subagent_type":"[^"]*"' "$_subdir" 2>/dev/null || true)"
fi

# Find a session artifact the SAME way the Stop hook does (check-review-artifact.sh find_session_artifact):
# search ALL ARTIFACT_SEARCH_DIRS (root + .v/artifacts + main, for worktree/consolidated sessions), newest
# by mtime — manual "root then .v/artifacts" lookups MISS $MAIN/.v/artifacts and false-absent a worktree
# session (codex SREV-002: a false READY where the gate would block = the exact thrash this tool prevents).
_find_art(){ local _p="$1" _d _f; for _d in "${ARTIFACT_SEARCH_DIRS[@]}"; do [ -n "$_d" ] || continue
  _f="$(ls -t "$_d/${_p}_${SID}"*.md 2>/dev/null | head -1)"; [ -n "$_f" ] && { printf '%s' "$_f"; return 0; }
done; return 1; }

BLOCKERS=0
ok(){   printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad(){  printf '  \033[31m✗ %s\033[0m\n      ↳ fix: %s\n' "$1" "$2"; BLOCKERS=$((BLOCKERS+1)); }
warn(){ printf '  \033[33m!\033[0m %s\n' "$1"; }

echo "── /v stop-readiness · session ${SID:0:8} · $(basename "$REPO") ──"
echo "   (advisory preview of the Stop gates — fix every ✗ in ONE pass, then stop)"

# ── 1. Artifacts: structure + presence (reuse v-artifact-validate-all.sh, the SAME validator the Stop hook
#       and the per-turn board use). 'invalid' is always a blocker; 'absent' blocks for the required set.
AV="$HERE/v-artifact-validate-all.sh"
REQUIRED="PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT IMPACT_MAP QA_REPORT"
if [ -f "$AV" ]; then
  avout="$(bash "$AV" "$SID" "${ARTIFACT_SEARCH_DIRS[@]}" 2>/dev/null || true)"   # EXACTLY the dirs the Stop hook searches (root + .v/artifacts + main) — worktree/consolidated safe
  for art in $REQUIRED; do
    line="$(printf '%s\n' "$avout" | grep -E "[[:space:]]${art}([[:space:]]|\$)" | head -1)"
    # T4 (2026-07-02): the validator prints `FAIL`, not `invalid` — the old grep misread every INVALID
    # artifact as ABSENT, telling the operator to REGENERATE a file that exists and needs one field fixed
    # (observed live: a present-but-Mode-less PRE_FLIGHT_REPORT reported "is ABSENT" for three fix cycles).
    # CODEX-004: anchor to the validator's STATUS COLUMN (first non-whitespace token) — a whole-line
    # substring match false-INVALIDated an `ok` artifact whose operator-chosen SID/filename contained
    # the substring "fail" (hex UUIDs can't, ad-hoc test SIDs can).
    if   printf '%s' "$line" | grep -qiE '^[[:space:]]*(FAIL|invalid)([[:space:]]|$)'; then bad "$art is INVALID (present but malformed)" "run: bash $HERE/v-artifact-validate-all.sh $SID   — it names the exact field to fix; do NOT regenerate the file"
    elif printf '%s' "$line" | grep -qE  '^[[:space:]]*ok([[:space:]]|$)'; then ok "$art valid"
    else bad "$art is ABSENT" "produce ${art}_${SID}.md (run the corresponding gauntlet step)"
    fi
  done
else
  warn "v-artifact-validate-all.sh not found — cannot preview artifact structure"
fi

# ── 1b. Gauntlet-attestation witness (Bug 6 / Phase 2). The #1 terminal block the model hits AFTER a
#        false-green readiness (observed in fleet sessions): the 3 core artifacts exist but v-gauntlet-attest.sh
#        was never run (or its witness is stale). Faithful to the real gate's common sub-conditions; fail-open.
_gw_pf="$(_find_art PRE_FLIGHT_REPORT || true)"; _gw_ar="$(_find_art AGENT_REVIEW || true)"; _gw_vd="$(_find_art VERIFY_DONE_REPORT || true)"
if [ -n "$_gw_pf" ] && [ -n "$_gw_ar" ] && [ -n "$_gw_vd" ]; then
  _GW="$HOME/.claude/runtime/v-gauntlet-attestation-$(printf '%s' "$SID" | tr 'A-Z' 'a-z').json"
  if ! command -v jq >/dev/null 2>&1; then
    warn "gauntlet-attestation: jq unavailable — cannot preview the witness; run v-gauntlet-attest.sh before stopping to be safe (the real gate re-checks)"
  elif [ ! -f "$_GW" ]; then
    bad "gauntlet-attestation witness missing ($_GW)" \
        "run: bash ~/.claude/skills/v/references/v-gauntlet-attest.sh   then quote its 4 printed lines verbatim in your completion — this is the LAST step of every code-changing /v session and the gate most often forgotten"
  else
    _gw_sid="$(jq -r '.sid // empty' "$_GW" 2>/dev/null | tr 'A-Z' 'a-z')"
    _gw_ts="$(jq -r '.ts // 0' "$_GW" 2>/dev/null)"; _gw_now="$(date -u +%s 2>/dev/null || echo 0)"
    _gw_max="${V_GAUNTLET_ATTESTATION_MAX_AGE_SEC:-7200}"; _sid_lc="$(printf '%s' "$SID" | tr 'A-Z' 'a-z')"
    if [ -n "$_gw_sid" ] && [ "$_gw_sid" != "$_sid_lc" ]; then
      bad "gauntlet-attestation witness is for a DIFFERENT session ($_gw_sid)" "re-run v-gauntlet-attest.sh for THIS session"
    elif [ "$_gw_now" -gt 0 ] && [ "${_gw_ts:-0}" -gt 0 ] && [ "$(( _gw_now - _gw_ts ))" -gt "$_gw_max" ]; then
      bad "gauntlet-attestation witness is STALE (age $(( _gw_now - _gw_ts ))s > ${_gw_max}s) — an artifact likely changed since attestation" "re-run v-gauntlet-attest.sh AFTER all artifacts are final"
    else
      # Item 23 (2026-07-03, R1 MED-3): witness CONTENT-HASH parity with the real Stop gate. The
      # checks above (SID match, age) are necessary but NOT sufficient — the real Stop hook
      # (check-review-artifact.sh) ALSO recomputes sha256 of each artifact ON DISK and requires it
      # match the witness's pre_sha256/rev_sha256/ver_sha256 (an artifact hand-edited AFTER
      # attestation is otherwise invisible to an age/SID-only preview: still fresh, still the right
      # SID, but no longer the content that was actually attested). Mirrors
      # check-review-artifact.sh's content-hash binding block exactly, using the SAME shared
      # crypto lib (hooks/lib/gauntlet-witness.sh) so this preview and the real gate can never
      # disagree on what "matches" means. Fail-open (advisory) if the lib or a hash tool is
      # unavailable — this AUGMENTS the existing checks above, it never weakens them.
      _GWLIB="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh"
      if [ -f "$_GWLIB" ]; then
        # shellcheck source=/dev/null
        . "$_GWLIB" 2>/dev/null || true
      fi
      if type _gw_sha256 >/dev/null 2>&1; then
        _gw_w_pre_sha="$(jq -r '.pre_sha256 // empty' "$_GW" 2>/dev/null)"
        _gw_w_rev_sha="$(jq -r '.rev_sha256 // empty' "$_GW" 2>/dev/null)"
        _gw_w_ver_sha="$(jq -r '.ver_sha256 // empty' "$_GW" 2>/dev/null)"
        if [ -z "$_gw_w_pre_sha" ] || [ -z "$_gw_w_rev_sha" ] || [ -z "$_gw_w_ver_sha" ]; then
          bad "gauntlet-attestation witness is missing content-hash fields (legacy/hand-forged v1 witness)" "re-run v-gauntlet-attest.sh to produce a signed v2 witness"
        else
          # WITNESS-PATH PARITY (forensic 2026-07-09): hash the artifact PATHS
          # the witness itself recorded (v-gauntlet-attest.sh stores them as pre_flight/
          # agent_review/verify_done), not this preview's own re-resolution. Re-resolving via
          # _find_art picks the NEWEST duplicate copy across the search dirs (main root,
          # .v/artifacts, worktree .v/artifacts) — when a sibling copy of a just-attested
          # artifact carries a fresher mtime, the preview hashed a DIFFERENT file than the one
          # attested and reported a false MISMATCH three times in one session while the real
          # gate passed. Parity means "compare what was attested"; fall back to the resolved
          # paths only when the witness predates the path fields or the recorded file is gone.
          _gw_h_pf="$(jq -r '.pre_flight // empty' "$_GW" 2>/dev/null)";   { [ -n "$_gw_h_pf" ] && [ -f "$_gw_h_pf" ]; } || _gw_h_pf="$_gw_pf"
          _gw_h_ar="$(jq -r '.agent_review // empty' "$_GW" 2>/dev/null)"; { [ -n "$_gw_h_ar" ] && [ -f "$_gw_h_ar" ]; } || _gw_h_ar="$_gw_ar"
          _gw_h_vd="$(jq -r '.verify_done // empty' "$_GW" 2>/dev/null)";  { [ -n "$_gw_h_vd" ] && [ -f "$_gw_h_vd" ]; } || _gw_h_vd="$_gw_vd"
          _gw_act_pre_sha="$(_gw_sha256 "$_gw_h_pf" 2>/dev/null || true)"
          _gw_act_rev_sha="$(_gw_sha256 "$_gw_h_ar" 2>/dev/null || true)"
          _gw_act_ver_sha="$(_gw_sha256 "$_gw_h_vd" 2>/dev/null || true)"
          if [ "$_gw_act_pre_sha" != "$_gw_w_pre_sha" ] || [ "$_gw_act_rev_sha" != "$_gw_w_rev_sha" ] || [ "$_gw_act_ver_sha" != "$_gw_w_ver_sha" ]; then
            bad "gauntlet-attestation witness content-hash MISMATCH — an artifact changed on disk after attestation (witness is stale even though it's fresh + same-SID)" "re-run v-gauntlet-attest.sh AFTER all three artifacts are truly final — do NOT hand-edit an already-attested artifact"
          else
            ok "gauntlet-attestation witness present + fresh + content-hash matches all 3 artifacts on disk"
          fi
        fi
      else
        ok "gauntlet-attestation witness present + fresh"
        warn "content-hash parity check unavailable here (gauntlet-witness.sh lib not loadable) — the real gate still verifies this"
      fi
    fi
  fi
fi

# ── 1e. INCONCLUSIVE / broken-env (F6a). A gate INCONCLUSIVE in the durable gate-summary produced NO valid
#        result (commonly an unprovisioned worktree test env) — the real gate BLOCKS and there is NO
#        BLOCKED_<sid>.md escape (CRA:2346-2373). Route to the SANCTIONED exit (fix env + re-dispatch), never
#        an edit/relabel (trips W5G-4 + the gate-summary cross-check = an observed thrash).
for _gsd in "$REPO/.v/tmp" "$REPO/.v/artifacts" "${MAIN:-$REPO}/.v/tmp" "${MAIN:-$REPO}/.v/artifacts"; do
  [ -f "$_gsd/gate-summary-${SID}.txt" ] || continue
  if grep -qE '^[A-Z_]+_RC=INCONCLUSIVE$' "$_gsd/gate-summary-${SID}.txt" 2>/dev/null; then
    bad "a gate is INCONCLUSIVE in the durable gate-summary ($_gsd/gate-summary-${SID}.txt) — it produced NO valid result (likely a broken/unprovisioned worktree test env)" \
        "FIX the env (re-provision the worktree's vendor/node_modules), then RE-DISPATCH the runner. Do NOT edit/relabel the dispatched report to PASS (trips W5G-4 + the gate-summary cross-check), and do NOT write BLOCKED_<sid>.md (there is no INCONCLUSIVE escape). If the env genuinely cannot be provisioned, leave the work on its branch — never fake a PASS."
  fi
  break
done

# ── 2. Review independence (the W22/_independence_verdict gate — the #1 provenance thrash in a production session).
AR_FILE="$(_find_art AGENT_REVIEW || true)"
if [ -n "$AR_FILE" ] && [ -f "$AR_FILE" ] && type _independence_verdict >/dev/null 2>&1; then
  iv="$(_independence_verdict "$AR_FILE" "codex-adversarial-reviewer" 2>/dev/null || echo skip)"
  case "$iv" in
    dispatched)        ok  "review independence proven (a reviewer subagent dispatch is on record)" ;;
    edited)            bad "AGENT_REVIEW was modified AFTER its independent dispatch (provenance sha256 mismatch — W5G-4)" \
                           "re-dispatch the reviewer via v-dispatch-subagent.sh; OR add a 'Post-dispatch edit: <what and why>' line (downgrades to a declared/warned fallback)" ;;
    # F2 (2026-08-29), corrected by the close-out audit. An earlier version of this arm claimed it
    # "mirrors the real gate — warn, never bad". That was FALSE: check-review-artifact.sh's
    # edited-declared arm BLOCKS (MISSING_REVIEW=1) when the declared edit changes a
    # finding/verdict/severity. This script is an ADVISORY PREVIEW OF THE STOP GATES — a warn where
    # the gate blocks is precisely the divergence it exists to eliminate. Call the SAME shared guard.
    edited-declared)
      if type _declared_edit_discloses_verdict_change >/dev/null 2>&1 \
         && _declared_edit_discloses_verdict_change "$AR_FILE"; then
        bad "AGENT_REVIEW was edited after its independent dispatch and the edit CHANGES a finding/verdict/severity — the Stop hook blocks this" \
            "re-dispatch the reviewer, OR restore its conclusion and record your disagreement in AGENT_REVIEW_ADDENDUM_<sid>.md with its own provenance"
      else
        warn "AGENT_REVIEW was edited after its independent dispatch and the edit is DECLARED; the dispatch is on record and the original survives — independence intact, no re-dispatch needed"
      fi ;;
    declared)
      # Mirror CRA:1459-1460 VERBATIM: 'declared' is accepted ONLY when the superpowers line states an
      # attempt OUTCOME (a bare mention is not enough — N5/W5F-6). Without it the real gate BLOCKS.
      if grep -iE 'superpowers|requesting.code.review' "$AR_FILE" 2>/dev/null \
         | grep -qiE 'attempt|tried|returned|failed|error|unavailable|not[[:space:]]+installed|unknown[[:space:]]+skill|timed?[[:space:]]?out|no[[:space:]]+reviewer|rc=[0-9]|exit[[:space:]]?(code|status)?[[:space:]]?[0-9]|fell[[:space:]]+back'; then
        warn "AGENT_REVIEW declares a degraded fallback (superpowers attempted) — accepted; prefer an independent dispatch"
      else
        bad "AGENT_REVIEW declares inline WITHOUT a documented superpowers:requesting-code-review attempt — the mandatory fallback chain was skipped" \
            "add a 'superpowers fallback attempted: <result>' line (e.g. 'superpowers fallback attempted: rc=1 / unknown skill'), OR dispatch an independent reviewer via v-dispatch-subagent.sh"
      fi ;;
    silent)            bad "AGENT_REVIEW claims an independent/codex review with NO dispatch provenance" \
                           "either dispatch a real reviewer via v-dispatch-subagent.sh, OR set 'Dispatch mode: orchestrator-inline (<reason>)' and remove any 'codex … ran' wording" ;;
    *)                 warn "review independence: unverifiable here (the real gate will re-check)" ;;
  esac
fi

# ── 3. QA acceptance verdict (code sessions require verdict: pass | escalated+BLOCKED).
QA="$(_find_art QA_REPORT || true)"
if [ -n "$QA" ] && [ -f "$QA" ]; then
  if grep -qiE 'verdict[^a-z]*pass' "$QA" 2>/dev/null; then ok "QA verdict: pass"
  elif grep -qiE 'verdict[^a-z]*fail' "$QA" 2>/dev/null; then
    bad "QA verdict: FAIL (unresolved critical/high)" "run the Step 6.4.9 QA loop: route each finding to the SME, fix, re-dispatch QA until 'verdict: pass'"
  elif grep -qiE 'verdict[^a-z]*escalat' "$QA" 2>/dev/null; then
    [ -f "$REPO/BLOCKED_${SID}.md" ] && warn "QA escalated WITH a BLOCKED_${SID}.md (accepted)" \
      || bad "QA verdict: escalated but no BLOCKED_${SID}.md" "write BLOCKED_${SID}.md documenting the unresolved finding, or drive QA to pass"
  else bad "QA_REPORT has no clear pass/escalated verdict" "ensure the QA loop wrote 'verdict: pass'"
  fi
fi

# ── 4. Survival: did this session's changes actually reach the tree the gates graded? (lost-write class)
if type _survival_verdict >/dev/null 2>&1; then
  sv="$(_survival_verdict "$SID" "$REPO" 2>/dev/null || echo skip:error)"
  case "$sv" in
    lost:*) bad "session changes appear LOST from the graded tree ($sv)" "re-apply the changes to the worktree/branch the gates ran against, or re-run the gates where the code actually is" ;;
    skip:*|"") : ;;
    *) ok "session changes present in the graded tree" ;;
  esac
fi

# ── 5. Repo state: a gate verdict against a mid-rebase/merge tree is a false-green (REPO-STATE guard).
gd="$(git -C "$REPO" rev-parse --git-path . 2>/dev/null)"
for op in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD; do
  if [ -e "$REPO/.git/$op" ] || { [ -n "$gd" ] && [ -e "$gd/$op" ]; }; then
    bad "repo is mid-operation ($op) — any gate result is a false-green" "finish or abort it (git rebase --continue/--abort, git merge --abort), then re-run the gates"
    break
  fi
done

# ── 6. Uncommitted session-owned changes + worktree merge-back (FND-3): code-shipping sessions must not
#       stop with dangling session changes, and a worktree branch must be merged (ancestor of main).
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git -C "$REPO" status --porcelain 2>/dev/null | grep -cE '^[ MARC]M|^M' || true)"
  [ "${dirty:-0}" -gt 0 ] 2>/dev/null && warn "${dirty} tracked file(s) with unstaged changes (may include pre-existing — the Stop gate counts only SESSION-OWNED writes; commit those before stopping on an isolated/feature session)"
  br="$(git -C "$REPO" branch 2>/dev/null | grep -oE "(build|fix|refactor)-[a-z0-9-]*-${SID:0:8}" | head -1)"
  if [ -n "$br" ]; then
    # Check against MAIN's checked-out branch, NOT $REPO's HEAD — in a worktree session HEAD *is* $br, and a
    # commit is its own ancestor, so 'is-ancestor $br HEAD' false-passes an unmerged branch (logic-HIGH).
    _mainbr="$(git -C "$MAIN" symbolic-ref --short HEAD 2>/dev/null || echo main)"
    if git -C "$MAIN" merge-base --is-ancestor "$br" "$_mainbr" 2>/dev/null; then
      ok "worktree branch $br merged (ancestor of $(basename "$MAIN"):$_mainbr)"
    else
      bad "worktree branch $br is NOT merged into main ($(basename "$MAIN"):$_mainbr) — FND-3" "merge it: bash ~/.claude/skills/v/references/v-merge-back.sh ${SID}  (or add 'MERGE_DEFERRED: $br' to a HANDOFF)"
    fi
  fi
fi

echo "────────────────────────────────────────"
if [ "$BLOCKERS" -eq 0 ]; then
  echo "READY: 0 blockers in this preview. (The Stop hook still runs the full semantic gate — if it blocks on something here unseen, fix that ONE thing and stop.)"
else
  echo "NOT READY: ${BLOCKERS} blocker(s) above. Fix ALL of them in this pass, re-run this check, THEN stop — do not stop-and-retry one at a time (that is the cost sink)."
fi
exit 0
