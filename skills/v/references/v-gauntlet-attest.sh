#!/usr/bin/env bash
# harness-sweep-skip: RUNTIME SCRIPT, NOT A TEST. This file matches a `*test*.sh` glob ONLY because
# "at-test" contains the substring "test". Run bare (no /v gauntlet context — e.g. a harness smoke
# sweep), it CORRECTLY exits 3: the ambient session has no gauntlet artifacts to attest. That is not
# a test failure. harness-test-sweep.sh skips any file carrying this `harness-sweep-skip:` marker so
# the sweep stays trustworthy. Do NOT "fix" this by weakening the exit-3 path — exit 3 is the gate.
# v-gauntlet-attest.sh — single source of truth for "the post-implementation gauntlet
# (pre-flight + adversarial review + verify-done) actually ran for THIS SID, in THIS
# /v invocation, against THIS session's code change."
#
# WHY THIS EXISTS (Bug 6, observed 2026-05-28 across 3 of 5 sessions):
#   The forked /v skill model self-authorized skipping the gauntlet with three different
#   rationalizations — "no additional safety signal", "forked subagent can't dispatch
#   subagents", "would re-run full PHP test suite". The Stop hook check-review-artifact.sh
#   validates artifact EXISTENCE for the current SID, but if a prior /v invocation in the
#   same Claude Code conversation left PRE_FLIGHT_REPORT_<sid>.md/AGENT_REVIEW_<sid>.md/
#   VERIFY_DONE_REPORT_<sid>.md in PROJECT_ROOT (same SID — SessionStart fires once per
#   conversation), the Stop hook is satisfied by STALE artifacts the current /v never
#   produced. Combined with model rationalization, three sessions shipped code to main
#   with no review.
#
# WHAT IT DOES:
#   1. Verifies all three gauntlet artifacts exist for the resolved SID at PROJECT_ROOT
#   2. Reads each artifact's first lines to check it's NOT empty/placeholder
#   3. Validates each artifact's mtime is fresher than this /v invocation's start marker
#      (catches the same-SID prior-invocation case — stale artifacts FAIL freshness)
#   4. Writes a single-use attestation witness at
#      ~/.claude/runtime/v-gauntlet-attestation-<sid>.json (consumed once, then deleted)
#   5. Emits the OBSERVABLE PROOF four-line block on stdout — the model MUST quote these
#      verbatim in its completion narration. No quoted block = no proof of gauntlet run.
#
# Stdout contract (the OBSERVABLE PROOF block) — keys are stable; values vary:
#   GAUNTLET_ATTESTED: yes
#   PRE_FLIGHT_REPORT: <absolute_path>
#   AGENT_REVIEW: <absolute_path>
#   VERIFY_DONE_REPORT: <absolute_path>
#
# Exit codes:
#   0 = all three artifacts present + fresh + non-empty; witness written; proof emitted
#   2 = bad arguments / cannot resolve PROJECT_ROOT / cannot resolve SID
#   3 = one or more artifacts missing
#   4 = artifact too small / placeholder (likely fabricated)
#   5 = artifact mtime is older than this invocation's start marker (stale = prior /v)
#   6 = crypto tools unavailable (gauntlet-witness.sh missing, or sha256sum/shasum/openssl
#       absent so the nonce/hash/HMAC cannot be computed) — refuse to write an unsigned witness
#   7 = H4-6: a gauntlet artifact failed STOP-GRADE semantic validation (validate_artifact /
#       validate_review_semantics, hostile-aware via v-hostile-required.sh) — presence+size
#       passed but the content would fail the Stop hook anyway; refuse to attest
#   8 = Item 19 (R1 HIGH-3 / R3 M-3): an artifact is stale relative to the LAST SOURCE MUTATION
#       this session made (per track-session-writes.sh's per-SID ledger) — distinct from exit 5,
#       which only catches staleness vs the invocation-start marker, not a same-invocation
#       re-touch of source after the artifact was written
#
# Usage:
#   bash v-gauntlet-attest.sh                       # resolves SID + project from env/git
#   bash v-gauntlet-attest.sh <sid>                 # explicit SID override
#   PROJECT_ROOT=/path bash v-gauntlet-attest.sh    # explicit project override
#
# The model MUST run this script after Step 6 (verify-done) completes and BEFORE
# emitting its final-report narration. The four stdout lines are the OBSERVABLE PROOF
# that all three gauntlet artifacts were produced by THIS /v invocation (not stale).
#
# Bug 6 / Phase 2 (2026-05-28) — SYSTEM ENFORCEMENT:
#   The Stop hook (~/.claude/hooks/check-review-artifact.sh) REQUIRES the witness
#   file this script writes (~/.claude/runtime/v-gauntlet-attestation-<sid>.json)
#   for any /v session that touched code. The model has historically been able to
#   skip this script by self-authorizing — Phase 1 added an ANTI-SKIP block in
#   /v SKILL.md Step 4, but a docs-only rule is only as strong as the model's
#   discipline. Phase 2 moves enforcement into the hook: if this script never
#   runs, the witness is missing, and the Stop hook BLOCKS the conversation.
#
#   Witness freshness window: V_GAUNTLET_ATTESTATION_MAX_AGE_SEC if set; otherwise
#   SESSION-SCOPED (session age + 1h slack, floored at 7200s) — resolved in the
#   W-WITNESS-TTL block of hooks/check-review-artifact.sh, which is authoritative.
#   History: 4h -> 1800s (2026-05-28, plan-n/WG-5) -> 7200s (W-perf4, long xhigh
#   sessions false-blocked) -> session-scoped (2026-08-05, W-WITNESS-TTL: 42 of 277
#   post-/v-inversion Stop blocks were pure time-staleness on UNCHANGED artifacts).
#   The "one attest cannot bless many later completions" property is carried by the
#   SID binding — a witness never crosses sessions — not by the age ceiling.
#
#   Witness binding (v2, 2026-05-28): the witness records {sid, nonce, ts,
#   pre_flight, agent_review, verify_done, pre_sha256, rev_sha256, ver_sha256, hmac}.
#   The Stop hook (1) recomputes the sha256 of each artifact ON DISK and checks it
#   matches the witness — so the witness is bound to the EXACT artifact content and
#   cannot be authored before the artifacts are finalized — and (2) recomputes the
#   HMAC under a 0600 per-install secret (~/.claude/runtime/.gauntlet-hmac-key) and
#   checks it matches. See hooks/lib/gauntlet-witness.sh.
#
#   HONESTY: this is bar-RAISING, not a cryptographic wall. A model runs as the same
#   UID that owns the secret file, so a determined model could read the key and forge
#   a valid witness. The point is to turn a one-line rationalized shortcut into a
#   deliberate multi-step fabrication; the load-bearing defenses are that the Stop
#   hook is actually REGISTERED (settings.json) and that the no-deception silent-skip
#   holes (Bash-write blindness, marker drift, stale TRIVIAL_PASS) are closed.
set -uo pipefail

# Shared witness crypto (HMAC + content-hash), single source of truth with the
# Stop hook verifier. See the HONEST SECURITY NOTE in the lib. Resolve the lib via
# (1) explicit GW_LIB override, (2) THIS script's own install location (stable under
# an isolated $HOME, e.g. test harnesses), (3) $HOME-based path.
_GW_LIB="${GW_LIB:-}"
if [ -z "$_GW_LIB" ] || [ ! -f "$_GW_LIB" ]; then
  _gw_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
  for _gw_cand in \
    "$_gw_self_dir/../../../hooks/lib/gauntlet-witness.sh" \
    "$HOME/.claude/hooks/lib/gauntlet-witness.sh"; do
    if [ -f "$_gw_cand" ]; then _GW_LIB="$_gw_cand"; break; fi
  done
fi
if [ -n "$_GW_LIB" ] && [ -f "$_GW_LIB" ]; then
  # shellcheck source=/dev/null
  . "$_GW_LIB"
else
  echo "v-gauntlet-attest: ERROR — witness crypto lib (gauntlet-witness.sh) not found near $_gw_self_dir or \$HOME/.claude/hooks/lib" >&2
  exit 6
fi

_UUID_RE='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# Resolve PROJECT_ROOT.
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$PROJECT_ROOT" ] || { echo "v-gauntlet-attest: ERROR — PROJECT_ROOT not a directory: $PROJECT_ROOT" >&2; exit 2; }

# Resolve SID — explicit arg → env → runtime file.
SID="${1:-}"
[ -z "$SID" ] && SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${SESSION_ID:-}}}"
if [ -z "$SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  SID=$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)
fi
echo "$SID" | grep -qiE "^$_UUID_RE$" || {
  echo "v-gauntlet-attest: ERROR — cannot resolve a valid UUID SID (got: '$SID')" >&2; exit 2;
}
SID=$(echo "$SID" | tr '[:upper:]' '[:lower:]')

# Locate each artifact. W-perf4: resolve against BOTH PROJECT_ROOT (current cwd toplevel)
# AND the canonical MAIN root (dirname of git-common-dir) — same set the Stop hook searches
# (check-review-artifact.sh REPO_ROOT+MAIN_ROOT). Artifacts in a worktree session can land
# at the MAIN root while attest runs from the worktree (or vice versa); a single-location
# resolve then false-fails "witness not found" and BLOCKS a fully-gated session (prod
# sessions (three observed) all hit the worktree-vs-main artifact split).
_ART_MAIN_ROOT=""
_gcd=$(git -C "$PROJECT_ROOT" rev-parse --git-common-dir 2>/dev/null || echo "")
if [ -n "$_gcd" ]; then
  case "$_gcd" in /*) : ;; *) _gcd="$(cd "$PROJECT_ROOT" && cd "$_gcd" 2>/dev/null && pwd || echo "")" ;; esac
  [ -n "$_gcd" ] && _ART_MAIN_ROOT="$(cd "$_gcd/.." 2>/dev/null && pwd || echo "")"
fi
# W-perf8: SID cross-fallback. Under a per-workstream SID override the WORK sid (exported
# CLAUDE_SESSION_ID) differs from the immutable process sid (CLAUDE_CODE_SESSION_ID); artifacts
# are named with whichever the /v session used. attest reads CLAUDE_SESSION_ID first while the
# completion self-check reads CLAUDE_CODE_SESSION_ID first — so they could resolve to DIFFERENT
# sids and disagree (one PASS, one FAIL on the same gated session). If the resolved SID owns no
# gauntlet artifacts but the alternate env-var SID does, adopt the alternate so both gates agree.
# NOTE (adversarial review): this is a PRODUCER-side convenience to converge attest with the
# self-check; the STRICT backstop is the Stop hook's hooks/lib/resolve-sid.sh, which deliberately
# has NO such fallback (see its INVARIANT comment). The two candidates are this process's own two
# env vars, so the adopted SID is this session's work-sid, not a sibling's.
_attest_sid_owns() {
  local s="$1" d
  [ -n "$s" ] || return 1
  for d in "$PROJECT_ROOT/.v/artifacts" "${_ART_MAIN_ROOT:-}/.v/artifacts" "$PROJECT_ROOT" "${_ART_MAIN_ROOT:-}"; do
    [ -n "$d" ] && [ -f "$d/PRE_FLIGHT_REPORT_${s}.md" ] && return 0
  done
  return 1
}
_alt_sid="$(printf '%s' "${CLAUDE_SESSION_ID:-}" | tr '[:upper:]' '[:lower:]')"
[ "$_alt_sid" = "$SID" ] && _alt_sid="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr '[:upper:]' '[:lower:]')"
if [ -n "$_alt_sid" ] && [ "$_alt_sid" != "$SID" ] && ! _attest_sid_owns "$SID" && _attest_sid_owns "$_alt_sid"; then
  echo "v-gauntlet-attest: note — SID=$SID owns no artifacts; adopting alternate env SID=$_alt_sid (per-workstream override, W-perf8)" >&2
  SID="$_alt_sid"
fi

# READ-ONLY VERIFICATION safety net (2026-07-07): if the runner dispatched this session as a read-only
# verification pack (pack-readonly-<sid>.marker) AND it provably changed no product code, there are no
# code-review artifacts to attest — emit a read-only attestation instead of exit-3 (which would demand the
# three code-change artifacts a zero-diff session cannot legitimately have). The read-only /v flow completes
# via the completion self-check, not this step; this branch only stops a DEFENSIVE attest call from hard-
# failing. Gated identically to the self-check + Stop hook (marker + zero product-code writes) — never fires
# for a code session, and emits a DISTINCT `readonly` token so the code-path `GAUNTLET_ATTESTED: yes` contract
# (bug6-test) is untouched.
_ro_m=""
for _rod in "$PROJECT_ROOT" "${_ART_MAIN_ROOT:-}"; do
  [ -n "$_rod" ] && [ -f "$_rod/.v/tmp/pack-readonly-${SID}.marker" ] && { _ro_m="$_rod/.v/tmp/pack-readonly-${SID}.marker"; break; }
done
if [ -n "$_ro_m" ]; then
  for _rolib in "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh" "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/code-ext-pattern.sh"; do
    [ -f "$_rolib" ] && . "$_rolib" 2>/dev/null || true
  done
  if type get_session_writes >/dev/null 2>&1 && [ -n "${CODE_EXT_PATTERN:-}" ] \
     && [ -z "$(get_session_writes "$SID" 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "${CODE_EXT_EXEMPT:-^$}" | head -1)" ]; then
    printf 'GAUNTLET_ATTESTED: readonly\n'
    printf 'READONLY_VERIFICATION: %s\n' "$SID"
    printf 'note: read-only verification session — zero product-code changes; no code-review gauntlet applies.\n'
    exit 0
  fi
fi

# _resolve_artifact <PREFIX> → echoes the winning path (or the default PROJECT_ROOT path if
# none exists, so downstream "missing" messaging is unchanged). W-perf8: search dirs are
# .v/artifacts FIRST (the W-perf6 canonical dir — the completion self-check CONSOLIDATES
# artifacts there), then the legacy roots (PROJECT_ROOT, MAIN root).
#
# F1 (2026-07-05): the actual PICKING algorithm now delegates to hooks/lib/gauntlet-witness.sh's
# gauntlet_find_artifact() — this function previously did FIRST-DIR-WINS in priority order, which
# is a real divergence from check-review-artifact.sh's and enforce-pre-commit-gates.sh's
# newest-mtime-across-all-dirs-wins: a STALE `.v/artifacts` copy could outrank a FRESHER
# PROJECT_ROOT fix here while the Stop hook picked the fresher one, producing exactly the kind of
# cross-gate disagreement/livelock this convergence closes. gauntlet_find_artifact also adds the
# ORCHFIX-A1 canonical-name-preferred-over-suffixed-variant behavior the Stop hook already has.
# Falls back to the pre-existing first-dir-wins behavior ONLY if the lib somehow isn't loaded
# (defense-in-depth — _GW_LIB is required earlier in this script, so this should be unreachable).
_resolve_artifact() {
  local _p="$1" _c _found
  # Lazy in-function source (F1 regression class, 2026-07-05): an awk/sed-extracted copy of
  # this function runs without the script top-level lib load; try the absolute default before
  # degrading to the legacy inline fallback. No-op in normal runs (lib already sourced).
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh" 2>/dev/null || true
  fi
  if type gauntlet_find_artifact >/dev/null 2>&1; then
    _found=$(gauntlet_find_artifact "$_p" "$SID" "$PROJECT_ROOT/.v/artifacts" "${_ART_MAIN_ROOT:-}/.v/artifacts" "$PROJECT_ROOT" "$_ART_MAIN_ROOT")
    [ -n "$_found" ] && { echo "$_found"; return 0; }
  else
    for _d in "$PROJECT_ROOT/.v/artifacts" "${_ART_MAIN_ROOT:-}/.v/artifacts" "$PROJECT_ROOT" "$_ART_MAIN_ROOT"; do
      [ -n "$_d" ] || continue
      _c="$_d/${_p}_${SID}.md"
      [ -f "$_c" ] && { echo "$_c"; return 0; }
    done
  fi
  echo "$PROJECT_ROOT/${_p}_${SID}.md"
}
PRE_FLIGHT="$(_resolve_artifact PRE_FLIGHT_REPORT)"
AGENT_REVIEW="$(_resolve_artifact AGENT_REVIEW)"
VERIFY_DONE="$(_resolve_artifact VERIFY_DONE_REPORT)"
# W-OPT-STALE (2026-08-11): IMPACT_MAP and QA_REPORT are resolved for the Item-19 SOURCE-staleness
# comparison below ONLY. They are deliberately NOT added to the existence check, the >=200B size
# check, or the invocation-marker staleness loop: those three treat their list as REQUIRED, and
# these two artifacts are only CONDITIONALLY owed (waived on the LIGHT tier, and the Stop hook —
# not this script — decides what a given diff owes). Adding them there would make attest invent a
# requirement and block every session that legitimately never owed one.
#
# NOTE: _resolve_artifact returns a DEFAULT path when nothing is found, so a non-empty value here
# does NOT mean the file exists. Item 19 guards on [ -f ] for exactly that reason.
IMPACT_MAP="$(_resolve_artifact IMPACT_MAP)"
QA_REPORT="$(_resolve_artifact QA_REPORT)"

# Existence check.
_missing=""
for _f in "$PRE_FLIGHT" "$AGENT_REVIEW" "$VERIFY_DONE"; do
  [ -f "$_f" ] || _missing="$_missing $(basename "$_f")"
done
if [ -n "$_missing" ]; then
  cat >&2 <<EOF
v-gauntlet-attest: FAIL — gauntlet artifact(s) missing for SID=$SID:
 missing:$_missing
 PROJECT_ROOT: $PROJECT_ROOT

You skipped the post-implementation gauntlet. CLAUDE.md says:
 "No humans review this code. The AI review is the ONLY safety net.
  These gates are NEVER optional."

The three forbidden rationalizations (each observed in production):
 (a) "no additional safety signal for this class of change" → FALSE; codex
     adversarial review has caught real race conditions on UI-only diffs.
 (b) "forked subagent cannot dispatch further Agent-tool subagents" → use
     the v-dispatch-subagent.sh subprocess path (see /v SKILL.md Step 5).
 (c) "would re-run full PHP test suite ~60s" → that is the cost. Pay it.

Required next action:
 1. Dispatch /v-pre-flight   → writes PRE_FLIGHT_REPORT_${SID}.md
 2. Dispatch agent review    → writes AGENT_REVIEW_${SID}.md
 3. Dispatch /v-verify-done  → writes VERIFY_DONE_REPORT_${SID}.md
 4. Re-run this attest script.
EOF
  exit 3
fi

# Non-empty + minimal-content check (catches placeholder/fabricated empties).
for _f in "$PRE_FLIGHT" "$AGENT_REVIEW" "$VERIFY_DONE"; do
  _size=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
  [ -z "$_size" ] && _size=0
  if [ "$_size" -lt 200 ]; then
    echo "v-gauntlet-attest: FAIL — artifact too small (${_size}B < 200B), likely placeholder: $_f" >&2
    exit 4
  fi
done

# === H4-6 (PLAN_2026-07-02_orchestrator-hardening-4): STOP-GRADE SEMANTIC VALIDATION ===
# Ground truth: a production session attested + merged with an AGENT_REVIEW the Stop hook LATER ruled
# semantically invalid (hostile review required but undeclared/inline) — the attest+merge path
# consumed WEAKER validation (presence + size only) than the Stop hook (validate_artifact +
# validate_review_semantics, hostile-aware). This runs the SAME validators the Stop hook runs,
# BEFORE attesting, so a semantically-invalid gauntlet can never be attested + merged in the first
# place — closing the gap where the invalid work already landed before the Stop hook caught it.
# Uses H4-5's single-sourced hostile verdict (v-hostile-required.sh) so this can never disagree
# with the Stop hook's own hostile computation.
_VALLIB="${V_VALIDATION_LIB:-$HOME/.claude/hooks/lib/validation.sh}"
if [ -f "$_VALLIB" ]; then
  # shellcheck source=/dev/null
  . "$_VALLIB" 2>/dev/null || true
fi
if type validate_artifact >/dev/null 2>&1; then
  _sem_fail=""
  if ! validate_artifact "$PRE_FLIGHT" "PRE_FLIGHT_REPORT" 2>/dev/null; then
    _sem_fail="PRE_FLIGHT_REPORT failed structural validation (validate_artifact)"
  elif ! validate_artifact "$VERIFY_DONE" "VERIFY_DONE_REPORT" 2>/dev/null; then
    _sem_fail="VERIFY_DONE_REPORT failed structural validation (validate_artifact)"
  fi
  if [ -z "$_sem_fail" ] && type validate_review_semantics >/dev/null 2>&1; then
    _hr_script="$HOME/.claude/skills/v/references/v-hostile-required.sh"
    _hostile_required=0
    if [ -f "$_hr_script" ]; then
      # ${V_TMP_DIR:-} inline default: this block runs BEFORE the script-level V_TMP_DIR
      # assignment (line ~279); under set -u a bare $V_TMP_DIR here killed the subshell,
      # silently degrading the hostile input to 0 (observed live 2026-07-02, this session).
      _hr_out=$(bash "$_hr_script" --sid "$SID" --tmp-dir "${V_TMP_DIR:-$PROJECT_ROOT/.v/tmp}" --worktree-root "$PROJECT_ROOT" 2>/dev/null)
      _hostile_required=$(printf '%s\n' "$_hr_out" | grep -m1 '^HOSTILE_REQUIRED=' | cut -d= -f2)
      [ "$_hostile_required" = "1" ] || _hostile_required=0
    fi
    # 5th arg 1 = allow-declared-degraded (O2), matching the Stop hook's OWN call
    # (check-review-artifact.sh) exactly — an honestly-declared inline/manual/degraded review is
    # a valid W13 fallback path, not a validation failure, in BOTH gates identically.
    if ! _sem_err=$(validate_review_semantics "$AGENT_REVIEW" 1 "$_hostile_required" "$SID" 1 2>&1); then
      _sem_fail="AGENT_REVIEW failed semantic validation (validate_review_semantics, hostile_required=${_hostile_required}) — ${_sem_err}"
    fi
  fi
  if [ -n "$_sem_fail" ]; then
    cat >&2 <<EOF
v-gauntlet-attest: FAIL — a gauntlet artifact failed STOP-GRADE semantic validation for SID=$SID:
  $_sem_fail

This is the SAME validation the Stop hook runs — attesting here would have shipped work the
Stop hook was always going to reject anyway (a production session: attested + merged with an AGENT_REVIEW
later ruled semantically invalid — hostile review required but undeclared). Fix the artifact
(re-dispatch the failing gate) and re-run this attest script. Do NOT hand-edit the artifact to
satisfy the validator.
EOF
    exit 7
  fi
else
  echo "v-gauntlet-attest: WARNING — could not load $_VALLIB; skipping Stop-grade semantic validation (structural/size checks still applied)" >&2
fi
# === end H4-6 semantic validation ===

# === W5G-11 (forensic 2026-07-10 #2): ATTEST-TIME TAMPER-DISCLOSURE GATE ===
# Ground truth: one production session's ATTESTED PRE_FLIGHT was a 4th, undisclosed post-dispatch revision —
# its sha matched NO DISPATCH_PROVENANCE status=ok row and it had DROPPED the earlier revision's
# 'Post-dispatch edit:' disclosure. Attest happily bound the content hash (this script checks
# presence/semantics/freshness but not provenance), the session died before any Stop-hook
# re-check, and the undisclosed revision became the attested record. Run the SAME W5G-4 trio the
# merge gate runs (v-merge-back.sh _artifact_tamper_unresolved): an artifact whose on-disk sha
# matches no recorded ok-sha must carry a 'Post-dispatch edit:' line AND a surviving dispatched
# original (satisfiable since W5G-4c archive-on-ok), or attest REFUSES. No-provenance sessions
# are untouched (_artifact_postdispatch_edited returns 1 when no ok-sha rows exist). Escape
# hatch for genuine emergencies: V_ATTEST_SKIP_TAMPER_GATE=1 (logged loudly, never default).
if [ "${V_ATTEST_SKIP_TAMPER_GATE:-0}" != "1" ] \
   && type _artifact_postdispatch_edited >/dev/null 2>&1 \
   && type _dispatched_original_survives >/dev/null 2>&1; then
  SESSION_ID="${SESSION_ID:-$SID}"
  ARTIFACT_SEARCH_DIRS=("$PROJECT_ROOT/.v/artifacts" "$PROJECT_ROOT" \
    "${_ART_MAIN_ROOT:-}/.v/artifacts" "${_ART_MAIN_ROOT:-}" \
    "$PROJECT_ROOT/.v/archive/${SID}" "${_ART_MAIN_ROOT:-}/.v/archive/${SID}")
  for _w511_f in "$PRE_FLIGHT" "$AGENT_REVIEW" "$VERIFY_DONE"; do
    [ -n "$_w511_f" ] && [ -f "$_w511_f" ] || continue
    if _artifact_postdispatch_edited "$_w511_f"; then
      if grep -qiE '^Post-dispatch edit:' "$_w511_f" 2>/dev/null && _dispatched_original_survives "$_w511_f"; then
        continue  # declared + original preserved — the sanctioned warned-fallback path
      fi
      cat >&2 <<EOF
v-gauntlet-attest: FAIL — $(basename "$_w511_f") was modified AFTER its independent dispatch
(on-disk sha256 matches no recorded status=ok sha in DISPATCH_PROVENANCE) without a
'Post-dispatch edit:' disclosure + surviving dispatched original. Attesting would bind an
undisclosed revision as the permanent gauntlet record (a production session: a 4th undisclosed PRE_FLIGHT
revision got attested because only merge-back ran this check, and the session died before any
Stop-hook re-check). Fix: re-dispatch that gate, OR restore the dispatched original under
.v/archive/${SID}/ and add a 'Post-dispatch edit:' line explaining the change, then re-attest.
(W5G-11; emergency override: V_ATTEST_SKIP_TAMPER_GATE=1)
EOF
      exit 7
    fi
  done
fi
# === end W5G-11 attest tamper-disclosure gate ===

# Freshness check — artifact mtime must be NEWER than this invocation's start marker.
# The start marker is written by /v Step 0 at bootstrap; if it doesn't exist, we skip
# this check (legacy sessions) but emit a stderr advisory.
V_TMP_DIR="${V_TMP_DIR:-$PROJECT_ROOT/.v/tmp}"
START_MARKER="$V_TMP_DIR/session-start-${SID}.txt"
_invocation_mark="$V_TMP_DIR/v-invocation-start-${SID}.txt"

# T3 (2026-07-02): worktree-safe marker lookup, mirroring the artifact search a few lines above
# (_ART_MAIN_ROOT). v-bootstrap.sh writes these markers under $PROJECT_ROOT/.v/tmp AS RESOLVED AT
# BOOTSTRAP TIME; this script's own PROJECT_ROOT is independently re-resolved from the current cwd
# (line ~108) and can legitimately differ — a worktree session's Step 0 bootstrap runs from the
# worktree, but a later /v invocation (or a merge-back that cd's back to main) can call this script
# from the main root, or vice versa. Without a fallback, a genuinely-fresh marker at the OTHER root's
# .v/tmp is invisible here and every attest on that session degrades to "legacy session" (skips the
# freshness check silently) even though the marker exists and is fresh. Only ADDS search locations —
# never removes the primary PROJECT_ROOT-derived path — so this can only turn a false "legacy session"
# into a correct freshness check; it cannot weaken an already-working lookup.
_invocation_mark_main="${_ART_MAIN_ROOT:+$_ART_MAIN_ROOT/.v/tmp/v-invocation-start-${SID}.txt}"
START_MARKER_MAIN="${_ART_MAIN_ROOT:+$_ART_MAIN_ROOT/.v/tmp/session-start-${SID}.txt}"

_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# T3 (2026-07-02, codex CDX-1 hardening): pick the NEWEST mtime among all candidate markers that
# exist, not first-found-in-priority-order. codex review caught a real weakening: first-found-wins
# could select an OLDER main-root marker (e.g. a genuinely prior /v invocation's leftover) ahead of a
# NEWER local marker in a mixed-marker state (local per-invocation marker absent/degraded, but a
# newer local session-start marker present) — silently LOWERING the freshness bar and letting a
# stale-relative-to-the-real-invocation artifact through. The newest mtime is always the strictest
# (most recent) baseline available, so this can only tighten the check relative to any single
# candidate, never loosen it.
MARKER=""; _mark_mt=""
for _cand in "$_invocation_mark" "$_invocation_mark_main" "$START_MARKER" "$START_MARKER_MAIN"; do
  [ -n "$_cand" ] && [ -f "$_cand" ] || continue
  _cand_mt=$(_file_mtime "$_cand")
  [ -n "$_cand_mt" ] || continue
  if [ -z "$_mark_mt" ] || [ "$_cand_mt" -gt "$_mark_mt" ]; then
    MARKER="$_cand"; _mark_mt="$_cand_mt"
  fi
done

if [ -n "$MARKER" ]; then
  _mark_mt=$(_file_mtime "$MARKER")
  if [ -n "$_mark_mt" ]; then
    for _f in "$PRE_FLIGHT" "$AGENT_REVIEW" "$VERIFY_DONE"; do
      _art_mt=$(_file_mtime "$_f")
      if [ -z "$_art_mt" ] || [ "$_art_mt" -lt "$_mark_mt" ]; then
        cat >&2 <<EOF
v-gauntlet-attest: FAIL — artifact is STALE (older than this /v invocation):
  artifact:        $_f
  artifact mtime:  $_art_mt
  invocation mtime:$_mark_mt
  marker:          $MARKER

This artifact was written by a PRIOR /v invocation that shared this SID
(SessionStart fires once per Claude Code conversation; if you ran /v
earlier in the same conversation, its artifacts have the same SID as
yours). The Step 0.5 stale-artifact-sweep should have archived them —
if you see this error, either (a) Step 0.5 was skipped, or (b) the
sweep's current-SID guard fired (Bug 6 fix removes that guard).

Required next action:
 1. Verify Step 0.5 ran for this invocation.
 2. Dispatch the three gauntlet sub-skills to write FRESH artifacts.
 3. Re-run this attest script.
EOF
        exit 5
      fi
    done
  fi
else
  echo "v-gauntlet-attest: WARNING — no /v start marker found at $_invocation_mark or $START_MARKER; skipping freshness check (legacy session)" >&2
fi

# === Item 19 (2026-07-03, R1 HIGH-3 / R3 M-3): freshness vs LAST SOURCE MUTATION ===
# The freshness check above compares each artifact's mtime against this INVOCATION's start
# marker — it catches "artifact left over from a PRIOR /v invocation" but NOT "source touched
# again AFTER this invocation's gauntlet artifact was written, still within the SAME invocation".
# Bite: touch a source file after PRE_FLIGHT_REPORT is written (still inside the same /v
# invocation window) — the invocation-marker check alone stays green (both the touch and the
# artifact postdate invocation start), so attest wrongly proceeds on a report that graded a tree
# that no longer exists. This is a DISTINCT check: it compares artifact mtime against the newest
# mtime among files THIS SESSION actually wrote, using hooks/track-session-writes.sh's read-only
# per-SID ledger (${git_common_dir}/claude-session-writes-<sid>.txt) — consumed here, not owned or
# modified by this script. Fail-open (advisory-only) if the ledger is absent/unreadable — this
# augments the existing gate, it never weakens it.
# Item 4 (2026-07-05): non-source artifact appends must NOT count as "source mutations" here.
# REVIEW_*/DISPATCH_PROVENANCE/*_REPORT_*/BITE_LEDGER-class files get appended-to or rewritten
# repeatedly throughout a long session (every codex dispatch appends a DISPATCH_PROVENANCE row;
# every remediation cycle rewrites AGENT_REVIEW) — none of that is a SOURCE code change, but
# because they land in the same session-writes ledger their mtime kept winning "newest write",
# making PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE look stale relative to the gauntlet's OWN
# bookkeeping and forcing a re-attest cascade on long (340-turn) sessions. Reuse the SAME
# artifact-name allowlist v-merge-back.sh's FND-3 sweep already maintains as the single source
# of truth for "this path is orchestrator bookkeeping, not a source file" (parity enforced by
# v-fnd-exclude-parity-test.sh / v-merge-back-fnd-exclude-parity-test.sh) — never hand-roll a
# second regex that can drift from it.
_ITEM4_MB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/v-merge-back.sh"
[ -f "$_ITEM4_MB" ] || _ITEM4_MB="$HOME/.claude/skills/v/references/v-merge-back.sh"
_FND_EXCLUDE_RE=""
[ -f "$_ITEM4_MB" ] && eval "$(grep -m1 '^_FND_EXCLUDE_RE=' "$_ITEM4_MB" 2>/dev/null)"

_GCD_FOR_WRITES="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "")"
_SESSION_WRITES_LEDGER="${_GCD_FOR_WRITES:+$_GCD_FOR_WRITES/claude-session-writes-${SID}.txt}"
if [ -n "$_SESSION_WRITES_LEDGER" ] && [ -s "$_SESSION_WRITES_LEDGER" ]; then
  _newest_src_mt=0
  _newest_src_path=""
  while IFS= read -r _wf; do
    [ -n "$_wf" ] || continue
    # Ledger stores repo-relative paths (track-session-writes.sh REL_PATH); resolve against
    # PROJECT_ROOT. A path that no longer exists (deleted since) cannot be "stale", skip it.
    case "$_wf" in
      /*) _wf_abs="$_wf" ;;
      *)  _wf_abs="$PROJECT_ROOT/$_wf" ;;
    esac
    [ -f "$_wf_abs" ] || continue
    # Item 4: skip non-source bookkeeping artifacts (REVIEW_*/provenance/resolution/etc.) —
    # they are not "source" and must not drive the staleness comparison below.
    if [ -n "$_FND_EXCLUDE_RE" ] && printf '%s' "$_wf" | grep -qE "$_FND_EXCLUDE_RE"; then
      continue
    fi
    _wf_mt=$(_file_mtime "$_wf_abs")
    [ -n "$_wf_mt" ] || continue
    if [ "$_wf_mt" -gt "$_newest_src_mt" ]; then
      _newest_src_mt="$_wf_mt"; _newest_src_path="$_wf_abs"
    fi
  done < "$_SESSION_WRITES_LEDGER"
  if [ "$_newest_src_mt" -gt 0 ]; then
    # W-ATTEST-ENUM (2026-08-09): report EVERY stale artifact in ONE run, not the first.
    #
    # WHY: this loop used to `exit 8` on the first stale artifact. The session re-ran the one
    # gauntlet step named, re-invoked attest, and was then told about the NEXT one — against the
    # SAME source file. Measured on the 2026-08-06→09 corpus: the witness was 30.6% of all
    # Stop-gate violations (77 of 252) across 11 of 12 blocked sessions, with 24 failed attest
    # invocations before success. One session fixed PRE_FLIGHT staleness, re-ran, and was
    # then told VERIFY_DONE was stale against the same test file it had just written.
    #
    # THE COLLISION THAT MAKES THIS EXPENSIVE: rearm_gate escapes at STOP_REARM_MAX_SAME=2
    # (i.e. the 3rd identical block), and this loop can serially reject exactly 3 artifacts.
    # A session owing all three refreshes therefore burns its whole deadlock budget on
    # discovery and trips the escape while it is legitimately converging — 17 of 17 escapes
    # since 2026-08-02 were followed by a successful attestation, shortest gap 53 seconds.
    # Enumerating collapses that discovery into one round.
    #
    # SECURITY POSTURE UNCHANGED: same comparison, same threshold, same exit code. This only
    # changes how many failures are reported before exiting — it can never make a stale
    # artifact pass. Bite: skills/v/references/v-gauntlet-attest-source-staleness-test.sh.
    #
    # W-OPT-STALE (2026-08-11): IMPACT_MAP and QA_REPORT are compared here too. They were checked
    # for PRESENCE by the Stop hook and for nothing else — no freshness check existed for either in
    # this script (they appeared nowhere in it) or in check-review-artifact.sh. Measured on one session:
    # QA_REPORT and IMPACT_MAP were each written once on the first day, then
    # never rewritten while 45 further commits landed and the three core artifacts were refreshed
    # two days later. The structural board reported both "ok" the entire time. Net
    # effect: a long multi-feature session ships under a QA acceptance and an impact analysis that
    # only ever graded its FIRST feature.
    # === W-NOGATE (2026-08-17): PRE_FLIGHT exemption on a repo with NO gate-bearing stack =======
    #
    # MEASURED: one session (run from a parent directory holding no project) dispatched v-pre-flight-runner 14 times in one session. Every
    # run wrote a gate-summary reading TSC/PHPSTAN/COMPOSER_AUDIT/NPM_AUDIT/LINT/BUILD/PEST/VITEST
    # = SKIP at PHASES_TOTAL_WALLCLOCK_SEC=0 — that directory has no package.json, composer.json or tests/,
    # so there is no gate to run and ALL_PASS=1 was vacuous. Six consecutive runs were
    # identical in scope (SCOPE_N=99) and verdict.
    #
    # SCOPE OF THIS FIX — corrected 2026-08-17 after a transcript pass, because the first version
    # of this comment overstated it. THIS LOOP fired 5 times in that session and twice in an
    # orchestrator session — NOT once per round. The other pre-flight dispatches came from the
    # GAUNTLET_STALE tree-hash path (check-review-artifact.sh) and ordinary /v flow, which this
    # exemption does not touch. Reach is ~7 events across both sessions.
    #
    # AND IT IS NOT A COST FIX. Priced from transcript usage fields, the pre-flight lane cost
    # a negligible amount across all 15 dispatches (it runs on Haiku); the whole executor gauntlet was a
    # small fraction of a two-day spend. What this buys back is round-trips, Stop-hook churn and operator
    # waiting. Do not re-derive a cost justification from this block — there isn't one.
    #
    # ARGUMENT: a gate that executes nothing cannot detect anything, so re-running pre-flight
    # against a different tree cannot change its verdict. This exempts PRE_FLIGHT ONLY.
    # AGENT_REVIEW / VERIFY_DONE / IMPACT_MAP / QA_REPORT all READ THE DIFF — they stay fully
    # staleness-bound, which is what keeps a docs edit reviewed by something.
    #
    # TWO CONDITIONS, both required (either alone is unsafe):
    #  1. CORROBORATION — this SID's gate-summary exists AND every *_RC= reads SKIP AND
    #     PHASES_TOTAL_WALLCLOCK_SEC=0. A MISSING summary is not evidence of absent gates; it
    #     means no runner has reported yet, so this fails CLOSED. A summary carrying any real
    #     verdict (e.g. PEST_RC=0) describes a repo that HAS gates and disqualifies the exemption.
    #  2. RE-ARM — no stack sentinel exists in the tree AT ATTEST TIME. Re-derived from the tree
    #     on every run, never cached: a package.json or composer.json appearing mid-session makes
    #     the gates real again and instantly revokes the exemption. (Operator condition on approval:
    #     key on stack-detection inputs, not on the summary.)
    #
    # SENTINELS — the list is a MIRROR of v-run-gates.sh's gate triggers, and drift re-opens the hole
    # in the unsafe direction (exemption granted while a gate would really run, so PRE_FLIGHT never
    # re-runs and a real regression goes ungraded). The first version carried only tsconfig.json and
    # missed four TSC/npm-audit triggers; caught by adversarial review the same day.
    #
    # THE LIST AND ITS SENTINEL->GATE MAPPING NOW LIVE IN hooks/lib/stack-sentinels.sh (F7,
    # 2026-08-29) — sourced below and shared with v-emit-prompt.sh's pre-dispatch stack gate.
    # A prose copy used to sit here; it was removed deliberately. Do NOT restate the list (or the
    # mapping) in this file: two copies is the exact drift this mirror is trying to survive, and the
    # single-source assertion in v-predispatch-stack-gate-test.sh case G checks for a restatement here.
    #
    # Bite: v-gauntlet-attest-source-staleness-test.sh — W-NOGATE cases B/B2/B3 (live-fire) AND case
    # B4 (DERIVED PARITY, F1 2026-08-29), which extracts v-run-gates.sh's own triggers from source
    # via v-run-gates-triggers.sh and fails on any trigger no sentinel covers. B4 is the case that
    # actually closes the drift direction; B/B2/B3 only live-fire sentinels that already exist.
    _nogate_surface=0
    _ngs_summary=""
    for _ngd in "$PROJECT_ROOT/.v/artifacts" "${_ART_MAIN_ROOT:-}/.v/artifacts"; do
      [ -n "$_ngd" ] && [ -f "$_ngd/gate-summary-${SID}.txt" ] && { _ngs_summary="$_ngd/gate-summary-${SID}.txt"; break; }
    done
    if [ -n "$_ngs_summary" ] \
       && grep -qE '^[A-Z_]+_RC=' "$_ngs_summary" 2>/dev/null \
       && [ -z "$(grep -E '^[A-Z_]+_RC=' "$_ngs_summary" 2>/dev/null | grep -v '=SKIP$' | head -1)" ] \
       && grep -qE '^PHASES_TOTAL_WALLCLOCK_SEC=0$' "$_ngs_summary" 2>/dev/null; then
      # F7 (2026-08-29): the 15-sentinel list moved to hooks/lib/stack-sentinels.sh so the
      # pre-dispatch stack gate in v-emit-prompt.sh consumes the IDENTICAL list rather than a
      # second copy (a second copy is exactly the drift defect F1's parity check exists to catch).
      # FAIL-CLOSED: `_ngs_stack=0` is what unlocks the W-NOGATE exemption, so if the helper cannot
      # be sourced we assert a stack IS present and the staleness check keeps applying (stricter).
      _ngs_stack=1
      _ngs_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/stack-sentinels.sh"
      if [ -f "$_ngs_lib" ]; then
        # shellcheck source=/dev/null
        . "$_ngs_lib" 2>/dev/null || true
      fi
      if command -v stack_has_gate_bearing_stack >/dev/null 2>&1; then
        if stack_has_gate_bearing_stack "$PROJECT_ROOT" "${_ART_MAIN_ROOT:-}"; then
          _ngs_stack=1
        else
          _ngs_stack=0
        fi
      else
        echo "v-gauntlet-attest: W-NOGATE — stack-sentinels.sh unavailable ($_ngs_lib); assuming a gate-bearing stack IS present (fail-closed) and keeping PRE_FLIGHT under the staleness check." >&2
      fi
      if [ "$_ngs_stack" -eq 0 ]; then
        _nogate_surface=1
        echo "v-gauntlet-attest: W-NOGATE — no gate-bearing stack in this tree (no package.json/composer.json/vendor bins) and $(basename "$_ngs_summary") reports every gate SKIP at 0s. PRE_FLIGHT_REPORT is EXEMPT from the item-19 source-staleness check: re-running a runner that executes no gates cannot change its verdict. AGENT_REVIEW/VERIFY_DONE/IMPACT_MAP/QA_REPORT remain staleness-checked." >&2
      fi
    fi
    # === end W-NOGATE ===
    _stale_list=""
    _stale_n=0
    _stale_paths=()
    for _f in "$PRE_FLIGHT" "$AGENT_REVIEW" "$VERIFY_DONE" "$IMPACT_MAP" "$QA_REPORT"; do
      # W-NOGATE: skip PRE_FLIGHT when this tree provably has no gate for it to run.
      [ "$_nogate_surface" -eq 1 ] && [ "$_f" = "$PRE_FLIGHT" ] && continue
      # Skip comparing the newest-written file against ITSELF (a gauntlet artifact can legitimately
      # appear in the writes ledger — e.g. a hand-edited PRE_FLIGHT_REPORT — and naturally postdates
      # its own write).
      [ "$_f" = "$_newest_src_path" ] && continue
      # An ABSENT optional artifact is not stale — it is simply not owed, and that call belongs to
      # the Stop hook. The `[ -z "$_art_mt" ] => stale` rule below is correct for the three core
      # artifacts (the existence check above already proved those exist, so a missing mtime there
      # is a real anomaly) but would fire on every session that never owed an IMPACT_MAP/QA_REPORT.
      if { [ "$_f" = "$IMPACT_MAP" ] || [ "$_f" = "$QA_REPORT" ]; } && [ ! -f "$_f" ]; then
        continue
      fi
      _art_mt=$(_file_mtime "$_f")
      if [ -z "$_art_mt" ] || [ "$_art_mt" -lt "$_newest_src_mt" ]; then
        _stale_n=$((_stale_n + 1))
        _stale_paths+=("$_f")
        _stale_list="${_stale_list}  [${_stale_n}] $_f
      artifact mtime: ${_art_mt:-<missing>}
"
      fi
    done
    if [ "$_stale_n" -gt 0 ]; then
      # W-REMEDIATE-SIDECAR (2026-08-17): dump the SAME staleness computation the loop above just
      # did — never re-derive it. _stale_paths is populated in the identical branch that built the
      # human-readable _stale_list, so there is exactly ONE staleness computation in this script;
      # the sidecar is a byproduct of it, not a second implementation (closes the divergence risk
      # an independent re-check would introduce). ADVISORY ONLY: v-remediate-stale.sh, and this
      # script's own next invocation, must always re-derive freshness from live mtimes — this file
      # is a convenience pointer, never a trust boundary.
      _stale_sidecar="$(dirname "$PRE_FLIGHT")/GAUNTLET_STALE_LIST_${SID}.txt"
      printf '%s\n' "${_stale_paths[@]}" > "$_stale_sidecar" 2>/dev/null || true
      cat >&2 <<EOF
v-gauntlet-attest: FAIL — ${_stale_n} artifact(s) STALE relative to a SOURCE FILE this session
touched AFTER they were written (Item 19 / R1 HIGH-3):

${_stale_list}
  newest session write:  $_newest_src_path
  write mtime:           $_newest_src_mt

These artifacts graded a tree that no longer matches this session's latest edit.

ACTION REQUIRED: run
  bash "\$HOME/.claude/skills/v/references/v-remediate-stale.sh" --stale-list "$_stale_sidecar"
— it reads the sidecar list above (machine-readable, avoids hand-parsing this message), fires
every tier-independent dispatch in ONE blocking Bash call, and sequences AGENT_REVIEW /
VERIFY_DONE_REPORT / QA_REPORT only after their real inputs are fresh. Only PRE_FLIGHT_REPORT and
IMPACT_MAP are mutually independent of every other artifact in this set — AGENT_REVIEW reads
IMPACT_MAP's reviewer_scope, VERIFY_DONE_REPORT reads pre-flight + agent-review, QA_REPORT reads
pre-flight + verify-done — so this is NOT a flat parallel batch. IMPACT_MAP itself cannot be
dispatched by that script at all (it is orchestrator-authored, not a subprocess) — re-run Step 1.8
yourself if it is listed above. Then re-run THIS script LAST. If the sidecar file is missing (e.g.
this script already cleared it on a later run), re-run this script first to regenerate it.
EOF
      exit 8
    fi
  fi
fi
# === end Item 19 ===

# Finding-7: if the session-log resolver has already attested this SID, verify the target log exists.
# A gauntlet witness and session log witness that disagree on the session's state is a sign the
# session log was never generated (or was deleted). This is advisory — warn, do not block, because
# /v-session-log can legitimately run after the gauntlet.
_SL_WIT="$HOME/.claude/runtime/v-session-log-attestation-${SID}.json"
if [ -f "$_SL_WIT" ]; then
  _sl_target=$(grep -oE '"target_log":"[^"]+"' "$_SL_WIT" 2>/dev/null | head -1 | sed -E 's/.*:"([^"]+)"/\1/')
  if [ -n "$_sl_target" ] && [ ! -f "$_sl_target" ]; then
    echo "v-gauntlet-attest: WARNING — session-log witness references target_log='$_sl_target' but that file does not exist. If /v-session-log was expected, run it before final completion. (Attestation will proceed — this is advisory.)" >&2
  fi
fi

# Write the attestation witness (HMAC + content-hash bound).
WITNESS_DIR="$HOME/.claude/runtime"
mkdir -p "$WITNESS_DIR" 2>/dev/null
WITNESS="$WITNESS_DIR/v-gauntlet-attestation-${SID}.json"

# Fail-CLOSED nonce: a 32-char base64-ish token. If entropy is unavailable, we must
# NOT write a witness with an empty/weak nonce (the Stop hook would otherwise reject
# it and block a legitimate gauntlet — worse, a "" nonce is the opposite of unique).
NONCE=$(head -c 24 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '/+=' | head -c 32)
if [ -z "$NONCE" ] || [ ${#NONCE} -lt 16 ]; then
  NONCE=$(openssl rand -hex 16 2>/dev/null)
fi
if [ -z "$NONCE" ] || [ ${#NONCE} -lt 16 ]; then
  echo "v-gauntlet-attest: ERROR — could not generate a secure nonce (/dev/urandom + openssl both unavailable). Refusing to write a weak witness." >&2
  exit 6
fi
TS=$(date -u +%s)

# Content-hash each artifact — binds the witness to the EXACT bytes that exist now,
# so a witness cannot be authored before the artifacts are finalized, nor reused for
# different content. Fail-closed if any artifact cannot be hashed.
PRE_SHA=$(_gw_sha256 "$PRE_FLIGHT" || true)
REV_SHA=$(_gw_sha256 "$AGENT_REVIEW" || true)
VER_SHA=$(_gw_sha256 "$VERIFY_DONE" || true)
if [ -z "$PRE_SHA" ] || [ -z "$REV_SHA" ] || [ -z "$VER_SHA" ]; then
  echo "v-gauntlet-attest: ERROR — could not sha256 one or more artifacts (no shasum/sha256sum/openssl?). Cannot write a content-bound witness." >&2
  exit 6
fi

# ATTEST-TREE-BIND (forensic 2026-07-04): the HMAC binds artifact CONTENT (sha256) but
# NOTHING binds the SOURCE TREE the gauntlet graded. A production session attested, THEN QA found a
# HIGH bug, the fix was committed minutes later — the artifacts were unchanged (content-hashes still
# matched) so the witness verified, but they graded a tree that no longer existed and the
# remediation shipped review-unseen. Record the tracked-source tree hash the gauntlet graded so the
# Stop hook (which runs AFTER any post-attest edit) can detect divergence. Method: `git stash create`
# captures the tracked working tree (staged+unstaged, NOT untracked artifacts) as a content-addressed
# tree; on a clean tree it returns empty → fall back to HEAD's tree. Because git trees are
# content-addressed, the SAME content yields the SAME hash whether it is uncommitted (attest time)
# or committed (Stop time) — so the normal "attest then commit that exact tree" flow matches, while a
# post-attest source edit does not. Signed: the tree fields are part of the HMAC canonical below
# (witness format 3), so deleting or editing them invalidates the witness instead of quietly
# switching the comparison off.
_ATTESTED_TREE=""
_stash_c="$(git -C "$PROJECT_ROOT" stash create 2>/dev/null || true)"
if [ -n "$_stash_c" ]; then
  _ATTESTED_TREE="$(git -C "$PROJECT_ROOT" rev-parse "${_stash_c}^{tree}" 2>/dev/null || true)"
else
  _ATTESTED_TREE="$(git -C "$PROJECT_ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
fi
# In a repo with no commits, `git rev-parse 'HEAD^{tree}'` prints its argument back. Keep only a
# real object id so that literal is never signed (it would read as STALE after the first commit).
case "$_ATTESTED_TREE" in *[!0-9a-f]*|'') _ATTESTED_TREE="" ;; esac

# F5 hardening (2026-07-05): ALSO record a SESSION-SCOPED tree hash (only the files
# THIS SID's track-session-writes.sh ledger says it wrote — see _gw_scoped_tree_hash
# in hooks/lib/gauntlet-witness.sh). The whole-tree _ATTESTED_TREE above is a false-
# positive hazard in a shared working tree (sibling sessions'/worktrees' unrelated
# edits change the whole-tree hash too); the Stop hook prefers this narrower field
# when it is present and falls back to the whole-tree compare only when it is not
# (empty ledger, or an older witness written before this field existed).
_ATTESTED_SESSION_TREE="$(_gw_scoped_tree_hash "$PROJECT_ROOT" "$SID" 2>/dev/null || true)"
case "$_ATTESTED_SESSION_TREE" in *[!0-9a-f]*|'') _ATTESTED_SESSION_TREE="" ;; esac

# HMAC over the format-3 canonical (sid, nonce, ts, the three content hashes and the tree
# binding) under the per-install key. Fail-closed if crypto is unavailable — better to block
# (no witness) than to ship an unsigned one.
HMAC=$(_gw_compute_hmac "$(_gw_canonical "$SID" "$NONCE" "$TS" "$PRE_SHA" "$REV_SHA" "$VER_SHA" \
  "$_ATTESTED_TREE" "$_ATTESTED_SESSION_TREE" "$PROJECT_ROOT")" || true)
if [ -z "$HMAC" ]; then
  echo "v-gauntlet-attest: ERROR — could not compute the witness HMAC (no sha256 tool, or the secret-key write failed). Refusing to write an unsigned witness." >&2
  exit 6
fi

# JSON-escape the path fields. The root is signed, so it must come back from `jq -r` byte for byte;
# a path with a control character cannot, so refuse it rather than write a witness that never verifies.
_json_esc() {
  case "$1" in *[[:cntrl:]]*) return 1 ;; esac
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\"/\\\"}"
}
if ! { _J_PRE=$(_json_esc "$PRE_FLIGHT") && _J_REV=$(_json_esc "$AGENT_REVIEW") \
       && _J_VER=$(_json_esc "$VERIFY_DONE") && _J_ROOT=$(_json_esc "$PROJECT_ROOT"); }; then
  echo "v-gauntlet-attest: ERROR — a project or artifact path contains a control character; cannot write a verifiable witness." >&2
  exit 6
fi

_tmp=$(mktemp "$WITNESS.XXXXXX" 2>/dev/null || echo "${WITNESS}.${$}.tmp")
{
  printf '{'
  printf '"skill":"v","check":"gauntlet-attest","wit_ver":3,"sid":"%s","nonce":"%s","ts":%s,"pid":%s,' \
    "$SID" "$NONCE" "$TS" "$$"
  printf '"pre_flight":"%s","agent_review":"%s","verify_done":"%s",' \
    "$_J_PRE" "$_J_REV" "$_J_VER"
  printf '"attested_tree":"%s","attested_tree_root":"%s","attested_session_tree":"%s",' "$_ATTESTED_TREE" "$_J_ROOT" "$_ATTESTED_SESSION_TREE"
  printf '"pre_sha256":"%s","rev_sha256":"%s","ver_sha256":"%s","hmac":"%s"' \
    "$PRE_SHA" "$REV_SHA" "$VER_SHA" "$HMAC"
  printf '}\n'
} > "$_tmp" 2>/dev/null
mv "$_tmp" "$WITNESS" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
chmod 600 "$WITNESS" 2>/dev/null || true

# The OBSERVABLE PROOF block — the model MUST quote these four lines verbatim.
printf 'GAUNTLET_ATTESTED: yes\n'
printf 'PRE_FLIGHT_REPORT: %s\n' "$PRE_FLIGHT"
printf 'AGENT_REVIEW: %s\n' "$AGENT_REVIEW"
printf 'VERIFY_DONE_REPORT: %s\n' "$VERIFY_DONE"
exit 0
