#!/usr/bin/env bash
# v-emit-prompt.sh — single-call dispatch prompt extractor for /v Step 5
# Version: 1.0.0
#
# Purpose: collapse the multi-step "cp + sed + grep" dance the orchestrator
# does inline before each haiku dispatch into ONE bash invocation. Eliminates:
#   - Cowork-mode permission prompts for ad-hoc bash commands (one named call
#     can be globally allowed; an open-ended pipeline cannot).
#   - Sonnet improvisation (the deny-message in enforce-haiku-dispatch.sh used
#     to direct the orchestrator at a stale `sed -n '/^## Appendix A/...'`
#     pattern; W12 externalized those prompts to v/references/dispatch-*.md
#     and the documented `cp` was not always followed).
#   - Per-skill duplication of the SID resolution + MODE selection logic.
#
# Usage:
#   bash ~/.claude/skills/v/references/v-emit-prompt.sh <skill> > "$DISPATCH_FILE"
#   <skill> ∈ {v-pre-flight, v-verify-done, v-handoff}
#
# Then the orchestrator's only remaining work is:
#   Read "$DISPATCH_FILE"  →  Agent(model: "haiku", prompt: <verbatim Read result>)
#
# Substitutions performed (canonical list mirrors v-verbatim-dispatch.md D2):
#   {{PROJECT_ROOT}}     ← $PROJECT_ROOT or `git rev-parse --show-toplevel`
#   {{WORKTREE_PATH}}    ← $WORKTREE_PATH (empty is valid — means "use PROJECT_ROOT")
#   {{SESSION_ID}}       ← $SESSION_ID, $CLAUDE_SESSION_ID, then runtime file (W23 v2)
#   {{PRE_FLIGHT_MODE}}  ← $MODE, else resolved from $WORKFLOW + $DIRTY_COUNT
#                          (overridden to "dirty-tree" when $PARALLEL_SESSIONS_DETECTED=true
#                           and $DIRTY_COUNT > 0).
#
# Inputs are env vars the orchestrator's Step 0 bootstrap already sets. The
# helper falls back to safe defaults when an env var is missing. The only
# hard requirement is a resolvable SESSION_ID — without that, the Stop hook
# will reject any artifacts haiku writes, so we abort early with a clear
# diagnostic instead of dispatching into a doomed run.
#
# Temp file policy (W18 + user rule):
#   Helper's scratch file is written to $V_TMP_DIR (= $PROJECT_ROOT/.v/tmp by
#   default). NEVER /tmp — host /tmp is off-limits per workspace policy.
#
# Exit codes:
#   0 = OK; substituted prompt on stdout
#   2 = bad usage (missing or unknown skill arg)
#   3 = source dispatch file missing
#   4 = SESSION_ID could not be resolved
#   5 = unsubstituted {{PLACEHOLDER}} remains after substitution
#   6 = sentinel header check failed (first line ≠ "You are <skill>")
#   7 = output suspiciously short (< 80 lines)
#   8 = $V_TMP_DIR not writable (orchestrator Step 0 bootstrap probably failed)
#   9 = resolved RUN_ROOT is not a directory (stale WORKTREE_PATH / removed worktree)
#  10 = F7 PRE-DISPATCH STACK GATE fired: this tree has no gate-bearing stack, so NO
#       runner was dispatched. PRE_FLIGHT_REPORT_<sid>.md was already written mechanically
#       from v-run-gates.sh's own skeleton. stdout carries a DO-NOT-DISPATCH instruction.
#       Opt out with V_PREDISPATCH_STACK_GATE=0. (v-pre-flight only.)
#
# Stderr: human-readable diagnostics; stdout: prompt content only (no banners).

set -euo pipefail

# ── 1. Skill arg ────────────────────────────────────────────────────────────

SKILL_NAME="${1:-}"
case "$SKILL_NAME" in
  v-pre-flight|v-verify-done|v-handoff) ;;
  "")
    echo "USAGE: $0 <v-pre-flight|v-verify-done|v-handoff>" >&2
    exit 2
    ;;
  *)
    echo "ERROR: unknown skill '$SKILL_NAME' (expected v-pre-flight, v-verify-done, or v-handoff)" >&2
    exit 2
    ;;
esac

# ── 2. Locate dispatch source ───────────────────────────────────────────────

# This script lives in v/references/ alongside the dispatch sources.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH_SRC="${SCRIPT_DIR}/dispatch-${SKILL_NAME}.md"

if [ ! -f "$DISPATCH_SRC" ]; then
  echo "ERROR: dispatch source missing: $DISPATCH_SRC" >&2
  echo "       Expected at v/references/dispatch-<skill>.md (W12 location)." >&2
  echo "       If you see this, /v installation is incomplete or a file was deleted." >&2
  exit 3
fi

# ── 3. Resolve SESSION_ID ───────────────────────────────────────────────────
# H1 review-fix (W47 phase 2): single source of truth — source the shared lib.
# The lib uses the canonical priority $CLAUDE_SESSION_ID > $SESSION_ID > runtime file
# (env-var preferred when both are set; SESSION_ID is the orchestrator-set
# subagent-dispatch variable). It performs case-insensitive UUID4 validation
# and rejects the zero-UUID sentinel.
RESOLVE_SID_LIB="$HOME/.claude/hooks/lib/resolve-sid.sh"
if [ -f "$RESOLVE_SID_LIB" ]; then
  # shellcheck source=/dev/null
  source "$RESOLVE_SID_LIB"
else
  # H5 (audit 2026-06-18): DEGRADE, don't hard-abort. A missing shared lib (partial install,
  # disk/perm error) used to `exit 4` here and take down EVERY gate dispatch (pre-flight,
  # verify-done, handoff) with no recovery. Define an inline resolve_sid covering the canonical
  # priority ($CLAUDE_SESSION_ID > $SESSION_ID > runtime file) with the same UUID4 + zero-UUID
  # rejection. If this still yields no valid SID the existing `[ -z "$SID" ]` block below exits 4
  # with its full diagnostic — so the hard stop only fires when the SID truly cannot be resolved.
  echo "WARN: $RESOLVE_SID_LIB missing — using inline SID fallback (degraded; reinstall W47-F1 helper)." >&2
  resolve_sid() {
    # Priority mirrors hooks/lib/resolve-sid.sh: $CLAUDE_SESSION_ID > $CLAUDE_CODE_SESSION_ID >
    # $SESSION_ID > runtime file (review LOW: include CLAUDE_CODE_SESSION_ID so a degraded
    # direct invocation with only that var set does not fall through to a stale runtime-file SID).
    local s="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-${SESSION_ID:-}}}"
    if [ -z "$s" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
      s=$(head -1 "$HOME/.claude/runtime/current-session-id" 2>/dev/null | tr -d '[:space:]')
    fi
    # Zero-UUID sentinel → clear and fall through to the printf path (mirrors the canonical lib's
    # `sid=""` contract; an unconditional `return 0` here would diverge from resolve-sid.sh).
    [ "$s" = "00000000-0000-0000-0000-000000000000" ] && s=""
    echo "$s" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' && printf '%s' "$s"
  }
fi

SID=$(resolve_sid)
SID_SOURCE="env"
# resolve_sid prefers $CLAUDE_SESSION_ID then $SESSION_ID; if neither was set,
# it returned the runtime-file value. Determine which path produced the value
# for SID_SOURCE telemetry (best-effort — purely informational).
if [ -z "${CLAUDE_SESSION_ID:-}" ] && [ -z "${SESSION_ID:-}" ]; then
  SID_SOURCE="runtime_file"
fi

if [ -z "$SID" ]; then
  echo "ERROR: SESSION_ID could not be resolved." >&2
  echo "       Tried: \$CLAUDE_SESSION_ID, \$SESSION_ID, ~/.claude/runtime/current-session-id" >&2
  echo "       Likely cause: session-start-export-sid.sh v2 is not registered, or this" >&2
  echo "       session predates the W23-followup hook fix. Start a new session and retry." >&2
  exit 4
fi

# ── 4. Resolve PROJECT_ROOT ─────────────────────────────────────────────────

PROJ="${PROJECT_ROOT:-}"
if [ -z "$PROJ" ]; then
  PROJ="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (114 stray files over
# 8 weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${PROJ:-}" ] && [ -n "$_lg_cfg" ] && [ "${PROJ}" != "$_lg_cfg" ]; then
  case "${PROJ}" in
    "$_lg_cfg"/*) git -C "${PROJ}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || PROJ="$_lg_cfg" ;;
  esac
fi

fi

# ── 5. Resolve WORKTREE_PATH ────────────────────────────────────────────────
# Empty is valid and intended — RUN_ROOT (§8, W71-F9) resolves to PROJECT_ROOT
# when no worktree exists; the dispatch prompts cd to RUN_ROOT unconditionally.

WT="${WORKTREE_PATH:-}"
# MAINROOT EXCLUSION (forensic 2026-07-09): the MAIN checkout is never a valid
# WORKTREE_PATH target — an inline session's correct expression is WT="" (RUN_ROOT falls back to
# PROJECT_ROOT). But the main checkout can carry the session's bootstrap markers (an inline start
# writes head-baseline-<SID> to the main .v/tmp before any worktree exists), and when $PROJ is
# env-skewed away from the main root — or merely differs TEXTUALLY (macOS /var vs /private/var
# symlink) — the `!= "$PROJ"` guards alone no longer exclude it. Observed live: the marker loop
# resolved WORKTREE_PATH to the MAIN repo root, producing a no-isolation verify-done that
# merge-back rejects (a wasted dispatch + a re-run). The main checkout is ALWAYS the first entry
# in `git worktree list --porcelain` (in git's own physical-path form); exclude it from ALL three
# resolution paths below.
_MAIN_TOP=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1 || true)
if [ -z "$WT" ]; then
  CUR_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  # If we're inside a worktree (cwd's toplevel ≠ PROJECT_ROOT), surface that
  # as WORKTREE_PATH so the dispatched skill cd's correctly.
  if [ -n "$CUR_TOP" ] && [ "$CUR_TOP" != "$PROJ" ] && [ "$CUR_TOP" != "${_MAIN_TOP:-}" ]; then
    WT="$CUR_TOP"
  fi
fi
# Secondary fallback: the orchestrator may run from PROJECT_ROOT while the session's
# worktree is an EXTERNAL worktree at ~/.claude/worktrees/ (CUR_TOP == PROJ above, so
# the primary path stays empty). Scan `git worktree list` for a live worktree whose path
# or branch name contains the session's short SID — if found, that IS the verify-done
# target. This fixes the verify-done scope gap (observed pattern: runner saw 41 dirty files
# from the main tree instead of the 2 session files still in the un-merged worktree).
if [ -z "$WT" ] && [ -n "$SID" ]; then
  _SID_SHORT="${SID:0:8}"
  _PROV=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null || true)
  # (_MAIN_TOP exclusion — see the MAINROOT EXCLUSION comment above §5's primary path.)
  if [ -n "$_PROV" ]; then
    # R-02: guard the grep chain against no-match exits under set -euo pipefail.
    # `grep -B3` exits 1 when the SID_SHORT does not appear in the worktree list
    # (inline / no-worktree sessions). The `|| true` absorbs the non-zero so the
    # pipeline exit does not kill the script — it simply leaves _WT_FOUND empty.
    _WT_FOUND=$(printf '%s\n' "$_PROV" | grep -B3 "$_SID_SHORT" 2>/dev/null | grep "^worktree " | awk '{print $2}' | tail -1 || true)
    if [ -n "$_WT_FOUND" ] && [ "$_WT_FOUND" != "$PROJ" ] && [ "$_WT_FOUND" != "$_MAIN_TOP" ] && [ -d "$_WT_FOUND" ]; then
      WT="$_WT_FOUND"
      echo "[v-emit-prompt] WORKTREE_PATH resolved via SID worktree scan: $WT" >&2
    fi
  fi
fi
# FIX-4 (CANARY2, forensic 2026-06-22): the path/branch SID-scan above MISSES worktrees named by
# TASK slug (e.g. build/<task-slug>-… with no SID in the path/branch) — so the pre-flight runner ran in
# MAIN and graded main's pre-existing failures instead of the session's worktree (branch=main in the report).
# Bind by the per-SID BOOTSTRAP MARKER instead: the worktree whose .v/tmp carries head-baseline-<SID> or
# session-start-<SID> IS this session's tree (v-bootstrap writes those there), independent of naming.
if [ -z "$WT" ] && [ -n "$SID" ]; then
  # MAINROOT EXCLUSION applies here too (see §5's comment): an inline session start legitimately
  # leaves head-baseline-<SID> in the MAIN root's .v/tmp — that marker means "the session started
  # here", NOT "this is the isolated worktree".
  while IFS= read -r _wt_cand; do
    [ -n "$_wt_cand" ] && [ "$_wt_cand" != "$PROJ" ] && [ "$_wt_cand" != "${_MAIN_TOP:-}" ] && [ -d "$_wt_cand" ] || continue
    if [ -f "$_wt_cand/.v/tmp/head-baseline-${SID}.txt" ] || [ -f "$_wt_cand/.v/tmp/session-start-${SID}.txt" ]; then
      WT="$_wt_cand"
      echo "[v-emit-prompt] WORKTREE_PATH resolved via per-SID bootstrap marker: $WT" >&2
      break
    fi
  done < <(git -C "$PROJ" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
fi

# ── 6. Resolve PRE_FLIGHT_MODE ──────────────────────────────────────────────
# Only consumed by v-pre-flight; substitution in the other prompts is a no-op
# (they don't contain the {{PRE_FLIGHT_MODE}} token).

PFM="${MODE:-}"
# W5G (2026-06-07): MODE is a GENERIC env name — Vite/Vitest export MODE=test into
# every worker process, silently overriding the gate mode with garbage that then
# flows into the runner prompt as an unknown scoping directive. Accept only the
# known mode enum; anything else is ignored (loudly) and resolved normally.
case "$PFM" in
  full|scoped|dirty-tree|user-owned-maintenance|"") : ;;
  *)
    echo "[v-emit-prompt] WARN: ignoring unknown MODE='$PFM' (generic env collision — e.g. Vite/Vitest export MODE=test); resolving PRE_FLIGHT_MODE from workflow/writes instead" >&2
    PFM=""
    ;;
esac
if [ -z "$PFM" ]; then
  WF="${WORKFLOW:-}"
  # W-perf3b (2026-06-02): when DIRTY_COUNT is NOT explicitly passed, derive the diff size
  # from THIS session's writes-log (W52 — the SID-attributed source the gates already use),
  # NOT the old blind 999 default. A bare `v-emit-prompt.sh v-pre-flight` (the QA-loop
  # re-verify form) previously defaulted DC=999 -> the `*) DC>40` arm -> PRE_FLIGHT_MODE=full
  # on EVERY iteration (a production session re-ran the full suite 3x this way, then W16-2
  # ran it a 4th time at completion). Positive SMALL footprint -> scoped (fast); large or NO
  # evidence -> conservative full. The authoritative full suite still runs at completion
  # (v-completion.md § W16-2), so scoping here loses no regression coverage. An explicitly
  # passed DIRTY_COUNT always wins. Kill-switch: V_W16_DC_FROM_WRITESLOG=0.
  if [ -n "${DIRTY_COUNT:-}" ]; then
    DC="$DIRTY_COUNT"
  elif [ "${V_W16_DC_FROM_WRITESLOG:-1}" = "1" ] && [ -f "$HOME/.claude/hooks/lib/session-writes.sh" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.claude/hooks/lib/session-writes.sh" 2>/dev/null || true
    _SW_COUNT=""
    if type get_session_writes >/dev/null 2>&1; then
      _SW_COUNT=$( cd "$PROJ" 2>/dev/null && get_session_writes "$SID" 2>/dev/null | grep -c '.' || true )
    fi
    if [ -n "$_SW_COUNT" ] && [ "$_SW_COUNT" -gt 0 ] 2>/dev/null; then DC="$_SW_COUNT"; else DC=999; fi
  else
    DC=999
  fi
  case "$WF" in
    maintenance|feature_tiny|feature_small) PFM="scoped" ;;
    *)
      # W-perf3: bug fixes + medium/large features now default to SCOPED per-session
      # pre-flight too (was `full` — the catch-all that made a bug-fix session
      # run the 12-min full suite). The full suite is NOT skipped: it runs bounded-
      # parallel at the Step-6 worktree/scoped final check (v-completion.md § W16-2),
      # the authoritative regression gate before merge-to-main — so scoped here is a
      # safe fast-iteration default. Escape to an EARLY `full` only for a very large
      # diff, where catching breakage before review/polish beats fast iteration.
      if [ "${DC:-999}" -gt 40 ] 2>/dev/null; then PFM="full"; else PFM="scoped"; fi
      ;;
  esac
  # W5G-5/M-3 (forensic 2026-06-07): a scoped pre-flight over ZERO dirty session
  # files tests nothing. Production sessions (post-merge remediation turns —
  # all session changes already committed/merged) got 418–600B stub PASS reports,
  # each bouncing off the Stop hook's F8-b size gate and burning a re-dispatch;
  # one session's FINAL on-disk PRE_FLIGHT was a 600B stub. If every session-written
  # file is git-clean (committed, merged, or untouched), escalate to the full
  # suite — that is the only meaningful gate left at that point.
  if [ "$PFM" = "scoped" ]; then
    _w5g5_writes=""
    if ! type get_session_writes >/dev/null 2>&1 && [ -f "$HOME/.claude/hooks/lib/session-writes.sh" ]; then
      # shellcheck source=/dev/null
      . "$HOME/.claude/hooks/lib/session-writes.sh" 2>/dev/null || true
    fi
    if type get_session_writes >/dev/null 2>&1; then
      _w5g5_writes=$( cd "$PROJ" 2>/dev/null && get_session_writes "$SID" 2>/dev/null | awk 'NF' || true )
    fi
    if [ -n "$_w5g5_writes" ]; then
      _w5g5_dirty=0
      # Heredoc (not a herestring/pipe): bash-3.2 herestrings poison the next
      # command substitution (W-perf5), and a pipe's subshell would drop the flag.
      while IFS= read -r _w5g5_p; do
        [ -n "$_w5g5_p" ] || continue
        if [ -n "$(git -C "$PROJ" status --porcelain -- "$_w5g5_p" 2>/dev/null)" ]; then
          _w5g5_dirty=1
          break
        fi
      done <<W5G5EOF
$_w5g5_writes
W5G5EOF
      if [ "$_w5g5_dirty" -eq 0 ]; then
        PFM="full"
      fi
    fi
  fi
  # Override: parallel sessions in a dirty tree → conservative dirty-tree mode. Accept BOTH conventions
  # (QA-F4): bootstrap emits PARALLEL_SESSIONS_DETECTED=1 while the gather/docs use "true".
  if { [ "${PARALLEL_SESSIONS_DETECTED:-false}" = "true" ] || [ "${PARALLEL_SESSIONS_DETECTED:-}" = "1" ]; } && [ "${DC:-0}" -gt 0 ] 2>/dev/null; then
    PFM="dirty-tree"
  fi
fi

# ── 7. Resolve $V_TMP_DIR for our scratch file (NEVER /tmp) ────────────────

V_TMP="${V_TMP_DIR:-}"
if [ -z "$V_TMP" ]; then
  V_TMP="${PROJ}/.v/tmp"
fi

# Refuse symlink (Sec-FND-5: same rule as v-bootstrap.sh — could redirect
# writes outside the repo).
if [ -L "${PROJ}/.v" ]; then
  echo "ERROR: ${PROJ}/.v is a symlink — refusing to write through it (Sec-FND-5)." >&2
  exit 8
fi

# Idempotent mkdir, then check writability via -w (no probe file — some
# sandboxed runtimes won't let us delete files we just touched, and a leftover
# probe would clutter $V_TMP_DIR. The kernel's -w check is sufficient).
if ! mkdir -p "$V_TMP" 2>/dev/null || [ ! -w "$V_TMP" ]; then
  echo "ERROR: V_TMP_DIR not writable: $V_TMP" >&2
  echo "       Run /v Step 0 bootstrap first, or check filesystem permissions." >&2
  exit 8
fi

# ── 8. Substitute ───────────────────────────────────────────────────────────

# Escape sed-special chars in replacement values (& and \). The sed delimiter
# below is | so we also escape that. Realistic SID/path values don't contain
# these, but defense-in-depth — the substitution must never inject sed metas.
sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

PROJ_ESC=$(sed_escape "$PROJ")
WT_ESC=$(sed_escape "$WT")
SID_ESC=$(sed_escape "$SID")
PFM_ESC=$(sed_escape "$PFM")
# W71-F9 (forensic 2026-07-02): the dispatcher — not the runner model —
# decides the run tree. Two gate subprocesses mis-cd'd into the main root because
# the templates asked the MODEL to interpret a "set/non-empty/not-literal"
# sentinel condition on WORKTREE_PATH. RUN_ROOT is resolved HERE, deterministically
# (worktree when one exists for this session, else PROJECT_ROOT), and substituted
# as an unconditional cd target.
RUN_ROOT="${WT:-$PROJ}"
# W71-review L1: a stale/deleted WORKTREE_PATH must fail HERE with a diagnosis, not
# downstream as a runner cd-failure → refusal → re-dispatch loop into the same dead path.
if [ ! -d "$RUN_ROOT" ]; then
  echo "ERROR: resolved RUN_ROOT '$RUN_ROOT' is not a directory (stale WORKTREE_PATH env, or the worktree was removed mid-session)." >&2
  echo "       Re-resolve the worktree (unset WORKTREE_PATH to let §5's scan/bootstrap-marker fallbacks run) and re-emit." >&2
  exit 9
fi
RR_ESC=$(sed_escape "$RUN_ROOT")

# ── 8b. F7 PRE-DISPATCH STACK GATE (2026-08-29) — v-pre-flight only ─────────
# Measured defect: 18 pre-flight dispatches each SPAWNED a v-pre-flight-runner subagent and
# loaded its context purely to learn there was nothing to run — 32 per-gate logs with zero tool
# output (largest 135 bytes). The runner only invokes v-run-gates.sh AFTER it is spawned, so
# nothing upstream could see that the tree carries no gate-bearing stack.
#
# W-NOGATE (v-gauntlet-attest.sh) is COMPLEMENTARY, not a replacement: it suppresses a
# RE-dispatch but requires a gate-summary to already exist, so it can never collapse the FIRST
# dispatch. This gate can.
#
# The 15-sentinel list is NOT restated here — it is sourced from hooks/lib/stack-sentinels.sh,
# the single source of truth v-gauntlet-attest.sh also consumes (a second copy is exactly the
# drift defect the F1 parity check exists to catch).
#
# FAIL-CLOSED IN EVERY DIRECTION — any doubt dispatches normally:
#   - helper missing / not sourceable      -> dispatch
#   - ANY sentinel found under ANY root    -> dispatch
#   - v-run-gates.sh missing/errors/times out, or emits no usable skeleton -> dispatch
#   - a PRE_FLIGHT_REPORT for this SID already exists -> dispatch (never clobber a real report,
#     and this keeps the gate strictly a FIRST-dispatch optimization)
# Opt out entirely with V_PREDISPATCH_STACK_GATE=0.
# Bound the direct v-run-gates.sh run with V_PREDISPATCH_STACK_GATE_TIMEOUT_SEC (default 300).
# A missing `timeout` binary is itself a fail-closed branch: this gate refuses to run the gates
# unbounded and dispatches normally instead.
#
# The report is written MECHANICALLY from v-run-gates.sh's own skeleton — never model-authored
# prose. That also closes two live falsehoods model prose produced on this path
# (a PRE_FLIGHT_REPORT declared "Stack: PHP, no JS" in a tree with no composer.json, and
# claimed a 9th gate with no *_RC field and no gate log). Because the skeleton comes from a REAL
# v-run-gates.sh run, the verdict is never assumed: if the sentinel read were somehow wrong, the
# gates actually execute and the report tells the truth (including FAIL).
if [ "$SKILL_NAME" = "v-pre-flight" ] && [ "${V_PREDISPATCH_STACK_GATE:-1}" != "0" ]; then
  _f7_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/stack-sentinels.sh"
  _f7_stackless=0
  if [ -f "$_f7_lib" ]; then
    # shellcheck source=/dev/null
    . "$_f7_lib" 2>/dev/null || true
  fi
  if ! command -v stack_has_gate_bearing_stack >/dev/null 2>&1; then
    echo "[v-emit-prompt] F7: stack-sentinels.sh unavailable ($_f7_lib) — dispatching normally (fail-closed)." >&2
  elif stack_has_gate_bearing_stack "$RUN_ROOT" "$PROJ" "${_MAIN_TOP:-}"; then
    : # a gate-bearing stack IS present — the runner has real work; dispatch normally.
  else
    _f7_stackless=1
  fi

  if [ "$_f7_stackless" -eq 1 ]; then
    _f7_art="$(bash "$HOME/.claude/skills/v/references/v-artifact-dir.sh" 2>/dev/null || true)"
    [ -n "$_f7_art" ] && [ -d "$_f7_art" ] || _f7_art="${PROJ}/.v/artifacts"

    # ROOT-CONTAINMENT (adversarial review PANEL-SECURITY-001, 2026-08-29) — REQUIRED.
    # This gate decides WHICH TREE to test from $RUN_ROOT/$PROJECT_ROOT, but v-artifact-dir.sh
    # resolves WHERE TO WRITE independently (its own CWD-based git resolution, or $V_ARTIFACT_DIR
    # verbatim). Nothing reconciled the two, and ~/.claude has no enclosing git repo to self-heal
    # the mismatch. Reproduced by the reviewer: PROJECT_ROOT=<empty decoy> with
    # V_ARTIFACT_DIR=<real project>/.v/artifacts wrote an "Overall Status: PASS" report for the REAL
    # session id into the REAL project, while the gates ran against the decoy. A report describing
    # tree A must never be filed as tree B's gate evidence.
    # So: the artifact dir MUST live inside a tree this gate actually consulted. Physical paths
    # (`pwd -P`) on both sides — macOS /var vs /private/var would otherwise defeat the prefix test.
    # Any mismatch, or any path that cannot be resolved, DISPATCHES NORMALLY (fail-closed).
    _f7_artp="$(cd "$_f7_art" 2>/dev/null && pwd -P || true)"
    _f7_contained=0
    if [ -n "$_f7_artp" ]; then
      for _f7_r in "$RUN_ROOT" "$PROJ" "${_MAIN_TOP:-}"; do
        [ -n "$_f7_r" ] || continue
        _f7_rp="$(cd "$_f7_r" 2>/dev/null && pwd -P || true)"
        [ -n "$_f7_rp" ] || continue
        case "$_f7_artp/" in "$_f7_rp"/*) _f7_contained=1; break ;; esac
      done
    fi
    # LEAK-GUARD (close-out audit, 2026-08-29): containment alone is not enough when the tested tree
    # IS the config dir. v-artifact-dir.sh honors $V_ARTIFACT_DIR VERBATIM, bypassing its own
    # strict-descendant snap — so a value like <config>/skills/v/references/.v/artifacts would satisfy
    # the containment test above (PROJ snaps to the config dir, and that path descends from it) and
    # F7 would file a gate verdict inside a SKILL SOURCE TREE. That is the documented leak class
    # (114 stray files over 8 weeks). Not currently reachable here — ~/.claude carries package-lock.json
    # so the gate never fires on it — but that is a coincidence of one file's presence, not a guard.
    # Allow ONLY the config dir's own .v/ tree; reject any other strict descendant of it.
    _f7_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    _f7_cfgp="$(cd "$_f7_cfg" 2>/dev/null && pwd -P || true)"
    if [ "$_f7_contained" -eq 1 ] && [ -n "$_f7_cfgp" ] && [ -n "$_f7_artp" ]; then
      case "$_f7_artp/" in
        "$_f7_cfgp"/.v/*) : ;;                       # the config dir's own artifact tree — legitimate
        "$_f7_cfgp"/*)
          echo "[v-emit-prompt] F7: artifact dir '${_f7_art}' is a source subdirectory of the config dir (${_f7_cfgp}) — refusing to nest a gate artifact inside a skill/hook source tree (LEAK-GUARD); dispatching normally (fail-closed)." >&2
          _f7_contained=0 ;;
      esac
    fi
    if [ "$_f7_contained" -ne 1 ]; then
      echo "[v-emit-prompt] F7: artifact dir '${_f7_art}' is OUTSIDE every tree this gate tested (RUN_ROOT='${RUN_ROOT}', PROJECT_ROOT='${PROJ}', MAIN='${_MAIN_TOP:-}') — refusing to file a gate verdict for a tree it does not describe; dispatching normally (fail-closed)." >&2
      # (No `_f7_stackless=0` here: control is already inside `if [ "$_f7_stackless" -eq 1 ]` and the
      #  variable is never read again — the branches below key on `_f7_contained`. A dead write here
      #  would read as if it controlled something.)
    fi
    _f7_report="${_f7_art}/PRE_FLIGHT_REPORT_${SID}.md"
    if [ "$_f7_contained" -ne 1 ]; then
      : # containment failed — already explained on stderr above; fall through to a normal dispatch.
    elif [ -e "$_f7_report" ]; then
      echo "[v-emit-prompt] F7: stackless tree, but ${_f7_report} already exists — NOT overwriting it; dispatching normally (fail-closed; this gate only ever collapses a FIRST dispatch)." >&2
    else
      _f7_gates="$HOME/.claude/skills/v/references/v-run-gates.sh"
      _f7_skel="${V_TMP}/pre-flight-skeleton-${SID}.md"
      _f7_log="${V_TMP}/f7-predispatch-gates-${SID}.log"
      _f7_to="${V_PREDISPATCH_STACK_GATE_TIMEOUT_SEC:-300}"
      case "$_f7_to" in ''|*[!0-9]*) _f7_to=300 ;; esac
      rm -f "$_f7_skel" 2>/dev/null || true
      _f7_ok=0
      # PANEL-CORRECTNESS-003: `timeout` is NOT part of a stock macOS install (it arrives with GNU
      # coreutils). Running v-run-gates.sh unbounded would contradict this gate's own documented
      # "times out -> dispatch normally" guarantee: a hung gate would block the whole pre-flight
      # step instead of falling back. Treat a missing `timeout` as one more fail-closed branch —
      # never run the gates here without a bound.
      if [ -f "$_f7_gates" ] && ! command -v timeout >/dev/null 2>&1; then
        echo "[v-emit-prompt] F7: 'timeout' unavailable — refusing to run v-run-gates.sh unbounded; dispatching normally (fail-closed)." >&2
      elif [ -f "$_f7_gates" ]; then
        ( cd "$RUN_ROOT" && SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$PROJ" \
            WORKTREE_PATH="$WT" V_TMP_DIR="$V_TMP" PRE_FLIGHT_MODE="$PFM" \
            timeout "$_f7_to" bash "$_f7_gates" ) >"$_f7_log" 2>&1 || true
        # A usable skeleton is the ONLY accepted evidence: it must carry the Mode: line the
        # w53 contract requires and end on the Overall Status: line the validators anchor on.
        if [ -s "$_f7_skel" ] \
           && grep -qE '^Mode: ' "$_f7_skel" 2>/dev/null \
           && [ -n "$(awk 'NF { last=$0 } END { print last }' "$_f7_skel" 2>/dev/null | grep -E '^Overall Status: (PASS|FAIL)$' || true)" ]; then
          _f7_ok=1
        fi
      fi
      if [ "$_f7_ok" -ne 1 ]; then
        echo "[v-emit-prompt] F7: stackless tree, but v-run-gates.sh produced no usable skeleton (see $_f7_log) — dispatching normally (fail-closed)." >&2
      else
        mkdir -p "$_f7_art" 2>/dev/null || true
        _f7_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _f7_tmp="${_f7_report}.f7tmp.$$"
        {
          echo "Model: none — mechanically generated by v-emit-prompt.sh (F7 pre-dispatch stack gate); NO subagent was dispatched."
          echo "Dispatch mode: manual (F7 pre-dispatch stack gate: this tree carries none of the 15 gate-bearing stack sentinels in hooks/lib/stack-sentinels.sh, so v-run-gates.sh was run directly and every gate SKIPped; spawning a v-pre-flight-runner could not have changed the verdict)"
          echo "Generated-At: ${_f7_now}"
          echo "Gate-Log: ${_f7_log}"
          echo ""
          echo "Reason: no gate-bearing stack sentinel found under any of: ${RUN_ROOT} | ${PROJ} | ${_MAIN_TOP:-<none>}."
          echo "Body below is v-run-gates.sh's own skeleton, copied verbatim — no prose was authored for this report."
          echo ""
          cat "$_f7_skel"
        } > "$_f7_tmp" 2>/dev/null && mv -f "$_f7_tmp" "$_f7_report" 2>/dev/null || {
          rm -f "$_f7_tmp" 2>/dev/null || true
          echo "[v-emit-prompt] F7: could not write ${_f7_report} — dispatching normally (fail-closed)." >&2
          _f7_ok=0
        }
      fi
      if [ "$_f7_ok" -eq 1 ]; then
        echo "[v-emit-prompt] F7: NO DISPATCH. Stackless tree; ${_f7_report} written mechanically from v-run-gates.sh's skeleton. Gate log: ${_f7_log}" >&2
        cat <<F7EOF
F7 PRE-DISPATCH STACK GATE — DO NOT DISPATCH v-pre-flight-runner.

This tree carries NONE of the 15 gate-bearing stack sentinels
(hooks/lib/stack-sentinels.sh), so there is no gate for a runner to execute.
Spawning a subagent here loads a full context to learn exactly that.

ALREADY DONE FOR YOU — no further pre-flight action is required:
  - v-run-gates.sh was run directly against ${RUN_ROOT} (every gate SKIPped).
  - PRE_FLIGHT_REPORT_${SID}.md was written MECHANICALLY from that run's own
    skeleton (no model-authored prose) at:
        ${_f7_report}
  - Gate log: ${_f7_log}

DO NOT call the Agent tool for v-pre-flight-runner for this session, and do NOT
hand-write or "improve" the report — it is the runner's verbatim gate skeleton.
If you believe this tree really does have a stack, re-run with
V_PREDISPATCH_STACK_GATE=0 to force a normal dispatch.
F7EOF
        exit 10
      fi
    fi
  fi
fi

# Repo-local scratch file (NEVER /tmp). Use mktemp's atomic XXXXXX expansion
# instead of $$ — bash subshells can share their parent's $$, so two parallel
# helper invocations within the same orchestrator (e.g., dispatch v-pre-flight
# and v-verify-done back-to-back) could collide. mktemp avoids that entirely.
# Adversarial-review hardening; original $$ pattern surfaced as Conc-FND-7.
TMP=$(mktemp "${V_TMP}/v-emit-${SID}-${SKILL_NAME}-XXXXXX.tmp" 2>/dev/null) || {
  # Fall back to $$ + nanosecond if mktemp fails (read-only $V_TMP, etc.) —
  # extremely rare; the helper exits immediately if we can't create the file.
  TMP="${V_TMP}/v-emit-${SID}-${SKILL_NAME}-$$-$(date +%N).tmp"
  : > "$TMP" 2>/dev/null || {
    echo "ERROR: cannot create scratch file in $V_TMP" >&2
    exit 8
  }
}
# Suppress trap stderr/exit — if cleanup fails (locked filesystem, sandboxed
# runtime, race with parallel run), don't poison the script's success exit.
# A leftover .tmp in $V_TMP_DIR is harmless and gets cleared at session end.
trap 'rm -f "$TMP" 2>/dev/null || true' EXIT INT TERM

sed \
  -e "s|{{PROJECT_ROOT}}|${PROJ_ESC}|g" \
  -e "s|{{WORKTREE_PATH}}|${WT_ESC}|g" \
  -e "s|{{RUN_ROOT}}|${RR_ESC}|g" \
  -e "s|{{SESSION_ID}}|${SID_ESC}|g" \
  -e "s|{{PRE_FLIGHT_MODE}}|${PFM_ESC}|g" \
  "$DISPATCH_SRC" > "$TMP"

# ── 9. Validate ─────────────────────────────────────────────────────────────

# 9a. No remaining {{PLACEHOLDER}} tokens — catches new placeholders added to
#     a dispatch source without a corresponding sed line being added here.
if grep -qE '\{\{[A-Z_]+\}\}' "$TMP"; then
  REMAINING=$(grep -oE '\{\{[A-Z_]+\}\}' "$TMP" | sort -u | head -5 | tr '\n' ' ')
  echo "ERROR: unsubstituted placeholders remain after substitution: ${REMAINING}" >&2
  echo "       Either add the substitution to v-emit-prompt.sh § 8, or remove the" >&2
  echo "       placeholder from $DISPATCH_SRC." >&2
  exit 5
fi

# 9b. Sentinel header — first line must announce the skill identity. Catches
#     accidentally-edited dispatch sources (e.g. a stray edit that drops the
#     "You are v-pre-flight" line and substitutes a markdown header).
EXPECTED="You are ${SKILL_NAME}"
FIRST_LINE=$(head -1 "$TMP")
if ! printf '%s' "$FIRST_LINE" | grep -qF "$EXPECTED"; then
  echo "ERROR: first line of substituted prompt does not begin with '$EXPECTED'." >&2
  echo "       Got: ${FIRST_LINE}" >&2
  echo "       Likely cause: $DISPATCH_SRC was edited and lost its sentinel header." >&2
  exit 6
fi

# 9c. Length sanity — real dispatch prompts are 100-300 lines. < 80 means
#     the file was truncated, mostly comments, or the wrong file got staged.
LINES=$(wc -l < "$TMP" | tr -d ' ')
if [ "${LINES:-0}" -lt 80 ]; then
  echo "ERROR: substituted prompt suspiciously short (${LINES} lines, expected ≥80)." >&2
  echo "       Likely cause: $DISPATCH_SRC truncated, or sed substitution mangled output." >&2
  exit 7
fi

# ── 10. Emit ────────────────────────────────────────────────────────────────

cat "$TMP"
exit 0
