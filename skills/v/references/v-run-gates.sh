#!/usr/bin/env bash
# v-run-gates.sh — single-call pre-flight gate runner (W26)
# Version: 1.0.0
#
# Purpose: run Phase 1 (TSC, audits in parallel), Phase 2 (Lint→Build
# sequential), and Phase 3 (Pest || Vitest in parallel) AS ONE BASH INVOCATION
# from the v-pre-flight haiku dispatch.
#
# Why this exists (W26 friction-reduction):
#   The dispatch prompt's bash code uses `&` + `wait $PID` for internal
#   parallelism. When haiku reads the prompt, however, it sometimes splits the
#   bash into per-gate Bash tool calls (one for tsc, one for
#   pest, one for vitest). Claude Code then auto-backgrounds the long-running
#   ones and generates Monitor commands of the form:
#
#       until [ -f /private/tmp/claude-<uid>/<proj>/<sid>/tasks/<task>.output ] \
#         && tail -1 ... | grep -q "passed|failed"; do sleep 5; done && cat ...
#
#   The Monitor path includes a per-task random ID — Cowork has never seen the
#   exact pattern before and prompts for permission. Same class of bug as W24:
#   per-step ad-hoc bash → per-step Cowork prompts.
#
#   With this helper, haiku makes ONE Bash tool call (this script). The script
#   does all parallelism internally via `&` and `wait`. Claude Code never sees
#   per-gate invocations, never backgrounds, never generates Monitor commands.
#
# Usage:
#   bash ~/.claude/skills/v/references/v-run-gates.sh
#
# Required env vars:
#   SESSION_ID       — canonical UUID; used in all gate-*.log filenames
#   V_TMP_DIR        — repo-local scratch dir (typically $REPO_ROOT/.v/tmp)
#   PRE_FLIGHT_MODE  — full | scoped | dirty-tree (per W16 decision rule)
#
# Optional env vars (defaulted from git/cwd if unset):
#   PROJECT_ROOT     — git toplevel; used as cwd if WORKTREE_PATH unset
#   WORKTREE_PATH    — if set/non-empty, cd here before running gates
#   MAIN_BRANCH      — default: main
#   BASE_SHA         — default: git merge-base with MAIN_BRANCH
#   POSTMERGE_REVERIFY — H4-4: set to 1 by the orchestrator when re-verifying the COMBINED
#                       post-merge-back main (per v-merge-back.sh's MERGE_BACK_REVERIFY_* stdout
#                       contract). Pass BASE_SHA=$FORK_BASE (never HEAD/MAIN_HEAD_BEFORE) alongside
#                       this flag. Effects: (a) the blind-scope guard runs even under PFM=full, so a
#                       0-diff base can never masquerade as a clean PASS; (b) the skeleton + summary
#                       are written to `-postmerge` SUFFIXED filenames, never overwriting the
#                       session's primary PRE_FLIGHT/gate-summary artifact.
#
# Optional CLAUDE.md command overrides (haiku reads CLAUDE.md, exports these
# before invoking the script — overrides take precedence over defaults):
#   PEST_CMD         — full pest invocation (e.g., "./vendor/bin/pest --parallel --processes=4")
#   VITEST_CMD       — full vitest invocation
#   LINT_CMD         — full lint invocation
#   BUILD_CMD        — full build invocation
#   TSC_CMD          — full tsc invocation
#
# Output:
#   $V_TMP_DIR/gate-tsc-${SID}.log
#   $V_TMP_DIR/gate-composer-audit-${SID}.log
#   $V_TMP_DIR/gate-npm-audit-${SID}.log
#   $V_TMP_DIR/gate-lint-${SID}.log
#   $V_TMP_DIR/gate-build-${SID}.log
#   $V_TMP_DIR/gate-pest-${SID}.log
#   $V_TMP_DIR/gate-vitest-${SID}.log
#   $V_TMP_DIR/gate-summary-${SID}.txt   (W25-A authoritative status file)
#   stdout: brief one-line summary per gate
#
# Exit code: 0 always. Gate failures are recorded in the summary file, NOT the
# exit code — haiku consumes the summary file directly.

# Use lenient bash: don't `set -e` because we WANT to continue past gate
# failures (each failure is captured into per-gate RC and reported in summary).
set -uo pipefail

# W38 Layer B: Hard timeout on the entire helper.
#
# A production session (2026-05-03): pest hung at 200+ seconds
# while the orchestrator sat in a Monitor() polling loop because
# the helper had no max wall-clock guard. After timeout, we emit a
# structured DETECTION_ERROR so the orchestrator can detect the situation
# and abort cleanly instead of looping indefinitely.
#
# Default 10 minutes. Override via V_RUN_GATES_TIMEOUT_SEC env var.
# Honor "already wrapped" sentinel to prevent recursive re-execution.
if [ -z "${V_RUN_GATES_TIMEOUT_WRAPPED:-}" ]; then
  _gate_timeout=${V_RUN_GATES_TIMEOUT_SEC:-900}  # W42-F3: bumped 600→900; production hit 600 cap on full Pest suites
  # W39-C: bash-native timeout (no coreutils dependency).
  #
  # Prior W38 implementation required `timeout`/`gtimeout` from GNU coreutils,
  # which is not installed by default on macOS. Production sessions on stock
  # macOS hit ERROR: 'timeout' / 'gtimeout' binary not found and were forced
  # to use V_RUN_GATES_ALLOW_NO_TIMEOUT=1 — restoring the original unbounded-hang
  # vulnerability. This pattern uses only built-in bash + sleep + kill, which
  # are available everywhere bash exists.
  #
  # Algorithm:
  #   1. Spawn the helper as a background subshell.
  #   2. Spawn a "killer" subshell that sleeps for the budget then SIGTERMs.
  #   3. wait for the helper. On natural exit, kill the killer.
  #   4. If the killer fired (helper got SIGTERM), wait reports exit 143.
  export V_RUN_GATES_TIMEOUT_WRAPPED=1
  # V-5 PGROUP KILL (2026-07-06 forensics): the killer used to TERM only $_gate_pid — the
  # WRAPPER subshell. The inner `bash "$0"` and its gate children (pest/paratest workers, vitest, npm)
  # survived the "timeout" and kept running + WRITING gate-*.log for many minutes (observed live: a pest
  # child wrote its gate log long past DETECTION_ERROR=gate_timeout, past the session's own kill,
  # silently mutating shared .v/artifacts state a later PRE_FLIGHT_REPORT no longer matched). Fix: run the
  # helper as its OWN process group leader (momentary `set -m` — bash-native, no setsid dependency) and
  # signal the NEGATIVE pgid so every descendant dies with it; plain-pid kill kept as fallback if job
  # control is unavailable.
  set -m 2>/dev/null || true
  ( bash "$0" "$@" ) &
  _gate_pid=$!
  set +m 2>/dev/null || true
  (
    sleep "$_gate_timeout"
    # Try graceful first — whole process group, fallback to the lone pid
    kill -TERM -- "-$_gate_pid" 2>/dev/null || kill -TERM "$_gate_pid" 2>/dev/null || exit 0
    # Give it 10s to clean up
    sleep 10
    kill -KILL -- "-$_gate_pid" 2>/dev/null || kill -KILL "$_gate_pid" 2>/dev/null || true
  ) &
  _killer_pid=$!

  wait "$_gate_pid" 2>/dev/null
  _rc=$?
  kill "$_killer_pid" 2>/dev/null || true
  wait "$_killer_pid" 2>/dev/null || true

  # bash exit codes for SIGTERM=143, SIGKILL=137. coreutils timeout=124.
  if [ "$_rc" -eq 124 ] || [ "$_rc" -eq 137 ] || [ "$_rc" -eq 143 ]; then
    _sid="${SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
    _v_tmp="${V_TMP_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)/.v/tmp}"
    _summary="${_v_tmp}/gate-summary-${_sid}.txt"
    mkdir -p "$_v_tmp" 2>/dev/null || true
    {
      echo "DETECTION_ERROR=gate_timeout_${_gate_timeout}s"
      echo "REMEDIATION=gates exceeded ${_gate_timeout}s wall-clock budget. Likely a stuck pest worker, deadlocked DB, or hung I/O. Investigate the slowest gate log under ${_v_tmp}/gate-*.log. Re-run after fixing — or override budget via V_RUN_GATES_TIMEOUT_SEC=N (in seconds)."
      echo "DONE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$_summary" 2>/dev/null || true
    echo "[v-run-gates] TIMEOUT after ${_gate_timeout}s — see $_summary" >&2
    exit "$_rc"
  fi
  exit "$_rc"
fi


# ── 0. Validate required env vars ──────────────────────────────────────────
if [ -z "${SESSION_ID:-}" ]; then
  echo "ERROR: SESSION_ID env var required" >&2
  exit 2
fi
if [ -z "${V_TMP_DIR:-}" ]; then
  # Try to compute from PROJECT_ROOT or git
  if [ -n "${PROJECT_ROOT:-}" ]; then
    V_TMP_DIR="$PROJECT_ROOT/.v/tmp"
  else
    REPO=$(git rev-parse --show-toplevel 2>/dev/null) || REPO="$(pwd)"

# LEAK-GUARD (2026-08-03 class sweep, 2nd pass — this shape was missed by the first grep):
# a non-repo cwd falls through to bare pwd/"."/$PWD. ~/.claude has no git repo, so from a
# skill/hook SOURCE subdir this nests .v/ inside the source tree. Config dir ITSELF is a
# legitimate root; snap only a strict descendant that is not a git work tree.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${REPO:-}" ] && [ -n "$_lg_cfg" ] && [ "${REPO}" != "$_lg_cfg" ]; then
  case "${REPO}" in
    "$_lg_cfg"/*) git -C "${REPO}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO="$_lg_cfg" ;;
  esac
fi

    V_TMP_DIR="$REPO/.v/tmp"
  fi
  mkdir -p "$V_TMP_DIR" 2>/dev/null || {
    echo "ERROR: V_TMP_DIR not writable: $V_TMP_DIR" >&2
    exit 3
  }
fi

# ── 1. cd to worktree (if set) or project root ─────────────────────────────
if [ -n "${WORKTREE_PATH:-}" ] && [ "$WORKTREE_PATH" != "{{WORKTREE_PATH}}" ] && [ -d "$WORKTREE_PATH" ]; then
  cd "$WORKTREE_PATH" || { echo "ERROR: cd to WORKTREE_PATH failed" >&2; exit 4; }
elif [ -n "${PROJECT_ROOT:-}" ] && [ -d "$PROJECT_ROOT" ]; then
  cd "$PROJECT_ROOT" || { echo "ERROR: cd to PROJECT_ROOT failed" >&2; exit 4; }
fi

# ── 2. Resolve MODE-related defaults ───────────────────────────────────────
PFM="${PRE_FLIGHT_MODE:-full}"
# F9-2: capture the ORIGINALLY-REQUESTED mode before any auto-escalation (ITEM1) or
# auto-downgrade (P1C-REVERIFY-SCOPE below) can reassign $PFM, and always surface it in the
# durable gate-summary (section 7) as PFM_REQUESTED — so a caller that asked for `full` and got
# back a report saying `Mode: scoped` can SEE that a downgrade happened instead of it being visible
# only in a transient stderr line the runner may not carry into its report.
_PFM_REQUESTED_ORIG="$PFM"
MAIN="${MAIN_BRANCH:-main}"
# F9-3 (staged-blindness hardening 2026-07-05): prefer the DURABLE session-start head-baseline
# (written ONCE at v-bootstrap.sh Step 0 — `head-baseline-${SESSION_ID}.txt`, this session's OWN
# HEAD sha at first bootstrap, immutable thereafter) over a merge-base RECOMPUTED fresh on every
# dispatch. `git merge-base HEAD "$MAIN"` drifts whenever $MAIN advances between two pre-flight
# dispatches of the SAME session (a concurrent sibling's merge landing on main, or this session's
# own merge-back landing mid-remediation-loop) — the scoped "in scope" diff then silently narrows
# or widens between iteration 1 and iteration 2 of the SAME session, instead of staying pinned to
# what this session actually started from. An explicit caller-supplied $BASE_SHA (e.g.
# POSTMERGE_REVERIFY's $FORK_BASE) always wins outright; the durable per-SID head-baseline is the
# next preference (a fixed point that only ever moves FORWARD as the session adds commits, never
# sideways); a freshly-computed merge-base is the last-resort fallback for a bare/manual invocation
# with no /v bootstrap (no SESSION_ID, or the baseline file was never written).
_F93_HB_PIN=""
if [ -z "${BASE_SHA:-}" ] && [ -n "${SESSION_ID:-}" ]; then
  _F93_MAIN_ROOT="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
  for _f93_cand in "$V_TMP_DIR/head-baseline-${SESSION_ID}.txt" \
                   "${_F93_MAIN_ROOT:+$_F93_MAIN_ROOT/.v/artifacts/head-baseline-${SESSION_ID}.txt}"; do
    [ -n "$_f93_cand" ] && [ -f "$_f93_cand" ] || continue
    _f93_sha="$(tr -d '[:space:]' < "$_f93_cand" 2>/dev/null)"
    if [ -n "$_f93_sha" ] && git cat-file -e "${_f93_sha}^{commit}" 2>/dev/null; then
      _F93_HB_PIN="$_f93_sha"
      break
    fi
  done
fi
if [ -n "$_F93_HB_PIN" ]; then
  BASE_SHA_FOR_DIFF="$_F93_HB_PIN"
  echo "v-run-gates: F9-3 — scoped diff base PINNED to this session's durable head-baseline ($_F93_HB_PIN), not a freshly-recomputed merge-base (prevents the in-scope set drifting across multiple dispatches of the same session as \$MAIN advances)." >&2
else
  BASE_SHA_FOR_DIFF="${BASE_SHA:-$(git merge-base HEAD "$MAIN" 2>/dev/null || echo '')}"
fi
# F1 (forensic 2026-06-17): a concurrent batch of /v sessions sharing main
# can leak a SIBLING's commit SHA in as $BASE_SHA. If $BASE_SHA is not an ancestor of HEAD it is a stale
# /divergent ref — `git diff $BASE_SHA..HEAD` then sweeps the WRONG file set (sibling churn, or EXCLUDES
# this session's real files), so the scoped gates test the wrong scope while reporting PASS (one session
# pinned a sibling SHA → "0 PHP in scope" → all PHP gates SKIP → shipped untested PHP; another
# scoped to a stale file set excluding real prod files). Recompute against the true merge-base and warn.
# (Empty base = full/unscoped mode — leave as-is.)
if [ -n "$BASE_SHA_FOR_DIFF" ] && ! git merge-base --is-ancestor "$BASE_SHA_FOR_DIFF" HEAD 2>/dev/null; then
  _stale_base="$BASE_SHA_FOR_DIFF"
  BASE_SHA_FOR_DIFF="$(git merge-base HEAD "$MAIN" 2>/dev/null || echo '')"
  echo "v-run-gates: F1 — BASE_SHA '${_stale_base}' is NOT an ancestor of HEAD (stale/sibling SHA from a concurrent shared-main session); recomputed base via merge-base → '${BASE_SHA_FOR_DIFF:-<none>}' so the scoped diff covers THIS session's files, not a sibling's." >&2
fi
# === ITEM1-BASE-EQ-HEAD (2026-07-05) ===
# Forensic class (post-mortem of several sessions): when BASE_SHA_FOR_DIFF
# resolves to the SAME sha as HEAD (the classic post-merge-back shape — the fork base now equals
# HEAD after a ff-merge), `git diff $BASE..HEAD` is empty BY CONSTRUCTION, not by a scoping
# miscount. The existing F1.7/blind-scope guards below correctly refuse to call this a clean PASS
# (PREFLIGHT_BLIND=1), but that still leaves the run INCONCLUSIVE and dependent on a manual
# re-dispatch (see postmerge-preflight-redispatch runbook) — pure re-dispatch-churn cost. Prefer
# the durable session-start head baseline (captured once at /v Step 0 bootstrap, immune to the
# merge that just moved "base" forward) as the real diff base; if that is ALSO unusable, escalate
# to a full gate run so this degenerate case is SELF-HEALING instead of silently collapsing to
# all-SKIP or requiring an operator retry loop.
_HEAD_SHA_I1="$(git rev-parse HEAD 2>/dev/null || echo '')"
if [ -n "$_HEAD_SHA_I1" ] && [ -n "$BASE_SHA_FOR_DIFF" ] && [ "$BASE_SHA_FOR_DIFF" = "$_HEAD_SHA_I1" ]; then
  _HEAD_BASELINE_FILE="$V_TMP_DIR/main-head-at-start-${SESSION_ID}.txt"
  _hb_sha="$(cat "$_HEAD_BASELINE_FILE" 2>/dev/null || echo '')"
  # FABLE-I1-ANCESTOR (2026-07-04): the recovered baseline must be an ANCESTOR of HEAD — the F1
  # non-ancestor guard above already ran and will NOT re-check this recovered value; a divergent
  # (rebased-away) baseline would silently re-introduce the wrong-scope class F1 exists to stop.
  if [ -n "$_hb_sha" ] && [ "$_hb_sha" != "$_HEAD_SHA_I1" ] && git cat-file -e "${_hb_sha}^{commit}" 2>/dev/null \
     && git merge-base --is-ancestor "$_hb_sha" HEAD 2>/dev/null; then
    echo "v-run-gates: ITEM1 — BASE_SHA_FOR_DIFF collapsed to HEAD ($_HEAD_SHA_I1); recovered the durable session-start head baseline from $_HEAD_BASELINE_FILE ($_hb_sha) as the real diff base instead." >&2
    BASE_SHA_FOR_DIFF="$_hb_sha"
  elif [ "$PFM" != "full" ]; then
    echo "v-run-gates: ITEM1 — BASE_SHA_FOR_DIFF collapsed to HEAD and no usable durable head-baseline was found ($_HEAD_BASELINE_FILE); auto-escalating PFM=$PFM -> full so this degenerate case cannot silently collapse to all-SKIP." >&2
    PFM=full
  fi
fi
# === end ITEM1-BASE-EQ-HEAD ===
# === P1C-REVERIFY-SCOPE (2026-07-03) ===
# Iteration-2+ auto-scoping. Forensic: a remediation loop re-dispatched SIX full
# pre-flights (+6 verify-dones) — every finding-fix re-ran the whole gate set. The scoped
# lane already has the right semantics (pest scoped to the diff, lint/build/vitest F1.7-skipped
# when no JS touched, audits keyed on lockfile change, blind-scope + tree-mismatch guards), so
# a re-verify does NOT need PFM=full: when a COMPLETED gate-summary for THIS SID already exists
# (proof iteration 1 ran), a PFM=full dispatch is auto-downgraded to scoped. This changes no
# gate's verdict logic — it selects the existing, guarded scoped lane instead of the full one.
# NEVER downgrades: the first run (no completed summary), a post-merge combined-state re-verify
# (POSTMERGE_REVERIFY=1 — must test the real merged tree), or when the operator/merge-back forces
# V_REVERIFY_FULL=1 (v-merge-back's final full-suite verify sets this). Bite: p1c-reverify-scope-test.sh.
if [ "$PFM" = "full" ] && [ "${POSTMERGE_REVERIFY:-0}" != "1" ] && [ "${V_REVERIFY_FULL:-0}" != "1" ]; then
  _P1C_PREV="$V_TMP_DIR/gate-summary-${SESSION_ID}.txt"
  # Item 18 (forensic 2026-07-03): the P1C mechanism above is correct IN ISOLATION (proven by
  # p1c-reverify-scope-test.sh) but has ZERO confirmed live firings, and the 3x-full-pre-flight
  # storm it targets RECURRED after this landed. Root-cause verified on disk: _P1C_PREV is a
  # SINGLE mutable per-SID file that is TRUNCATE-OVERWRITTEN (`{ ... } > "$SUMMARY_FILE"`, section
  # 7 below) on every invocation — there is exactly ONE DONE_AT stamp in existence at any time, not
  # one per iteration. That file also lives under THIS invocation's own $V_TMP_DIR, which is derived
  # from WORKTREE_PATH/PROJECT_ROOT/cwd (line ~143-160) and can resolve to a DIFFERENT path across
  # dispatches of the same SID (worktree recreated between remediation-loop iterations, or a dispatch
  # that runs from the main root while a prior one ran from a worktree). When that happens, the
  # "prior gate-summary" this check looks for is invisible even though iteration 1 genuinely
  # completed — so PFM never downgrades and the storm recurs. Section 7b already solves exactly
  # this class of problem for the summary file itself (CANARY-A: a durable copy at the resolved
  # MAIN root's .v/artifacts, immune to worktree-path variance) — this consults THAT durable copy
  # as a fallback when the local mutable file is absent, so an iteration-2+ dispatch from a
  # different cwd/worktree than iteration 1 still sees iteration 1's result.
  _p1c_main_root="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
  _P1C_PREV_DURABLE="${_p1c_main_root:-${PROJECT_ROOT:-}}/.v/artifacts/gate-summary-${SESSION_ID}.txt"
  _P1C_SRC=""
  if [ -f "$_P1C_PREV" ]; then
    _P1C_SRC="$_P1C_PREV"
  elif [ -f "$_P1C_PREV_DURABLE" ]; then
    _P1C_SRC="$_P1C_PREV_DURABLE"
  fi
  # Review L#2 CRITICAL + CDX-2 HIGH (both reproduced): DONE_AT alone is NOT proof iteration 1
  # evaluated anything — it is written unconditionally, including on PREFLIGHT_BLIND=1 (0-file
  # scope), TREE_MISMATCH=1 (wrong tree, W71-F10), and the W38 watchdog's timeout summary
  # (DETECTION_ERROR= + DONE_AT together). Counting those as "iteration 1 ran" would silently
  # convert every future full dispatch to scoped off a run that never looked at the diff.
  # A genuine FAIL still counts (that is the exact case P1C targets); blind/mismatch/timeout do not.
  # Item 2 (forensic: PFM_REQUESTED=full silently downgraded to scoped): the checks above prove
  # the prior summary is COMPLETE and non-degenerate, but not that it belongs to THIS /v
  # invocation. SIDs get reused loosely in this environment (a resumed handoff, a re-invoked
  # session); a completed gate-summary can be a STALE leftover from an EARLIER /v invocation of
  # the same SID (e.g. yesterday's run) rather than "iteration 1" of the current remediation
  # loop. Bootstrap rewrites v-invocation-start-<sid>.txt UNCONDITIONALLY at the start of every
  # /v invocation (Bug 6 marker), so a genuine same-invocation iteration-1 summary is always
  # NEWER than it; a leftover from a prior invocation is always OLDER (the marker was just
  # rewritten "now"). Default to fresh (preserves existing behavior/tests when no marker is
  # present, e.g. older runner versions or a direct script invocation with no /v bootstrap) —
  # ONLY downgrade the freshness verdict when a marker IS present and proves staleness.
  _P1C_FRESH=1
  for _p1c_inv_dir in "$V_TMP_DIR" "${_p1c_main_root:-}/.v/tmp"; do
    [ -n "$_p1c_inv_dir" ] || continue
    _p1c_inv_mark="$_p1c_inv_dir/v-invocation-start-${SESSION_ID}.txt"
    [ -f "$_p1c_inv_mark" ] || continue
    if [ -n "$_P1C_SRC" ] && [ ! "$_P1C_SRC" -nt "$_p1c_inv_mark" ]; then
      _P1C_FRESH=0
      echo "v-run-gates: ITEM2 — prior gate-summary $_P1C_SRC is NOT newer than this invocation's start marker ($_p1c_inv_mark); treating it as a STALE leftover from an earlier /v invocation, not this remediation loop's iteration 1 — honoring the caller's explicit PFM=full instead of silently downgrading." >&2
    fi
    break
  done
  if [ -n "$_P1C_SRC" ] && grep -q '^DONE_AT=' "$_P1C_SRC" 2>/dev/null \
     && ! grep -q '^PREFLIGHT_BLIND=1' "$_P1C_SRC" 2>/dev/null \
     && ! grep -q '^TREE_MISMATCH=1' "$_P1C_SRC" 2>/dev/null \
     && ! grep -q '^DETECTION_ERROR=' "$_P1C_SRC" 2>/dev/null \
     && [ "$_P1C_FRESH" = "1" ]; then
    PFM="scoped"
    echo "v-run-gates: P1C — iteration-2+ re-verify auto-scoped (completed, non-blind, tree-matched, THIS-invocation-fresh prior gate-summary found for this SID at $_P1C_SRC; full → scoped). The scoped lane re-runs the failed surface + this session's diff; the final merge-back re-verify still runs the real combined state. Do NOT set V_REVERIFY_FULL=1 on a remediation-loop re-dispatch — that flag is reserved for v-merge-back's final combined-state verify (cohort 2026-09-01: one worker forced repeated full suites this way for a small diff whose scoped lap tested the same files)." >&2
  fi
  # Item 18: append (never overwrite) a durable per-iteration DONE stamp so a completed PRE_FLIGHT
  # dispatch count survives the single-file overwrite above AND worktree-path variance — the
  # observability gap the "currently zero live firings" complaint was really about (nothing durable
  # recorded HOW MANY full pre-flight dispatches this SID had made, so the storm was invisible until
  # the bill made it obvious). One line per invocation; never truncated; consumed by forensics
  # / provenance, not by the scoping decision above (which stays keyed on the real gate-summary
  # content per L#2/CDX-2).
  _P1C_LEDGER_DIR="$V_TMP_DIR"
  mkdir -p "$_P1C_LEDGER_DIR" 2>/dev/null || true
  printf '%s PFM_REQUESTED=full\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_P1C_LEDGER_DIR/gate-iterations-${SESSION_ID}.txt" 2>/dev/null || true
  _p1c_ledger_main="${_p1c_main_root:-${PROJECT_ROOT:-}}"
  if [ -n "$_p1c_ledger_main" ] && [ -d "$_p1c_ledger_main" ]; then
    mkdir -p "$_p1c_ledger_main/.v/artifacts" 2>/dev/null || true
    printf '%s PFM_REQUESTED=full\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_p1c_ledger_main/.v/artifacts/gate-iterations-${SESSION_ID}.txt" 2>/dev/null || true
  fi
fi
# === end P1C-REVERIFY-SCOPE ===

SESSION_WRITES="$V_TMP_DIR/session-writes-${SESSION_ID}.txt"

# Default commands — overridden by env vars if haiku set them per CLAUDE.md
# W55-F4: --incremental cache reduces re-check time on subsequent runs.
# HI-2 fix: per-SESSION path eliminates parallel-session contention. The
# production repo runs concurrent /v sessions (W47-A) — a shared per-project
# cache could be clobbered between sessions reading/writing it.
# TS owns invalidation via file hashes; corrupt cache → rebuild from scratch (safe).
# Cache lives in V_TMP_DIR (gitignored via .v/.gitignore — verified).
TSC_INCREMENTAL_CACHE="${V_TMP_DIR}/tsbuildinfo-${SESSION_ID}"
[ -n "$TSC_INCREMENTAL_CACHE" ] || { echo "v-run-gates: BUG: TSC_INCREMENTAL_CACHE empty (V_TMP_DIR=${V_TMP_DIR:-} SESSION_ID=${SESSION_ID:-})" >&2; exit 5; }
# Item 11b (2026-07-05): a project-sanctioned TSC skip (TSC_CMD=true per CLAUDE.md policy) was
# only honored when the CALLER remembered to re-pass TSC_CMD on EVERY dispatch — the
# postmerge-preflight-redispatch runbook had to explicitly document "TSC_CMD=true" as a required
# manual env var for the re-verify dispatch. When a re-verify/remediation-loop dispatch omitted
# it (easy to forget — it's not carried by MODE/BASE_SHA/POSTMERGE_REVERIFY like the rest of the
# re-verify contract), the runner silently fell back to a REAL `npx tsc` invocation and produced a
# spurious FAIL on a project that had explicitly opted out. Make the sanctioned override STICKY
# per-SID: persist an explicit TSC_CMD to a durable marker on first use, and auto-load it on later
# dispatches of the SAME session that don't re-specify it — so the override survives across the
# whole remediation loop without the caller needing to remember it every time.
_TSC_CMD_MARKER="$V_TMP_DIR/tsc-cmd-override-${SESSION_ID}.txt"
if [ -n "${TSC_CMD:-}" ]; then
  printf '%s' "$TSC_CMD" > "$_TSC_CMD_MARKER" 2>/dev/null || true
elif [ -z "${TSC_CMD:-}" ] && [ -f "$_TSC_CMD_MARKER" ]; then
  TSC_CMD="$(cat "$_TSC_CMD_MARKER" 2>/dev/null || true)"
  [ -n "$TSC_CMD" ] && echo "v-run-gates: ITEM11b — reusing this session's previously-persisted TSC_CMD override ('$TSC_CMD') from $_TSC_CMD_MARKER (not re-specified on this dispatch)." >&2
fi
TSC_CMD_DEFAULT="${TSC_CMD:-npx tsc --noEmit --incremental --tsBuildInfoFile $TSC_INCREMENTAL_CACHE}"
LINT_CMD_DEFAULT="${LINT_CMD:-npm run lint}"
BUILD_CMD_DEFAULT="${BUILD_CMD:-npm run build}"

# ── Lever D (W-perf-D): phase-level pre-flight fail-fast ───────────────────
# V_PREFLIGHT_FAILFAST defaults to 1 (ON) for the per-session SCOPED lane. When a prior
# phase (TSC / lint / build) already FAILED, running the multi-minute
# Pest||Vitest suite is wasted wall-clock: the model must fix the static failure and
# re-run the whole gate set anyway, so testing known-broken code buys nothing. On a
# trigger the suite is skipped and a `| SKIP | tests | fail-fast: prior phase failed |`
# row is emitted. The FINAL full-suite / merge run sets V_PREFLIGHT_FAILFAST=0 (off) to
# keep collect-all semantics (report every failure at once) — see v-merge-back.sh.
V_PREFLIGHT_FAILFAST="${V_PREFLIGHT_FAILFAST:-1}"

# W-perf3: bound paratest parallelism by a core/concurrency-aware budget so concurrent
# /v sessions don't oversubscribe the machine. Production evidence
# (2026-05-29): full pre-flight ran single-process `php artisan test` for over ten minutes, while
# scoped `pest --parallel` defaulted to ALL cores (oversubscription under concurrency).
# The resolver exports V_PEST_PROCESSES_SCOPED (small, for the concurrent scoped runs)
# and V_PEST_PROCESSES_FULL (larger; the full suite runs under the cross-session lock).
_VPB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/v-proc-budget.sh"
[ -f "$_VPB" ] || _VPB="$HOME/.claude/skills/v/references/v-proc-budget.sh"
# shellcheck disable=SC1090
[ -f "$_VPB" ] && . "$_VPB"
: "${V_PEST_PROCESSES_SCOPED:=2}"; : "${V_PEST_PROCESSES_FULL:=4}"   # fallback if helper missing

# Full-mode PHP test default: prefer the project's PARALLEL pest binary (bounded by the
# FULL budget; this full path runs under the suite lock at Phase 3) over single-process
# `php artisan test`. An explicit PEST_CMD env always wins.
if [ -n "${PEST_CMD:-}" ]; then
  PEST_CMD_DEFAULT="$PEST_CMD"
elif [ -x "./vendor/bin/pest" ]; then
  # W-SCOPEDPEST class sweep (2026-08-04): `--parallel` is PARATEST-backed. Emitting it whenever
  # the pest binary exists is the same failure shape that broke the scoped lane — pest rejects the
  # flag and the gate reads the non-zero exit as a test failure. Surveyed all local projects:
  # none currently has pest WITHOUT paratest, so this is LATENT, but it arms itself the moment
  # someone installs pest alone. Gating changes nothing today (the parallel branch still fires
  # everywhere it did) and turns a future hard break into a slower-but-correct single-process run.
  if [ -x "./vendor/bin/paratest" ]; then
    PEST_CMD_DEFAULT="./vendor/bin/pest --parallel --processes=${V_PEST_PROCESSES_FULL}"
  else
    PEST_CMD_DEFAULT="./vendor/bin/pest"
  fi
else
  PEST_CMD_DEFAULT="php artisan test"
fi
VITEST_CMD_DEFAULT="${VITEST_CMD:-npx vitest run}"

# === TREEDEDUP-REUSE (2026-07-09; F6 2026-08-29 extended to PFM=scoped) ===
# Tree-hash gate dedup (backlog #1, forensic: redundant full gate runs on IDENTICAL trees —
# fleet verify lanes, back-to-back /v sessions, re-dispatch storms — are pure waste; P1C only
# covers same-SID same-invocation re-verifies). If the CURRENT working-tree CONTENT (tracked +
# staged + untracked non-ignored, .v/ and .v-prompt-packs/ excluded) hashes identical to the tree
# that already passed a fully-green run in the SAME mode (full or scoped — see F6 below), reuse
# that run's gate results verbatim instead of re-executing the suite.
#
# Safety posture (every one fail-closed — ANY doubt means run the gates for real):
#   - reuse only for effective PFM=full or PFM=scoped (F6; PFM=dirty-tree stays OUT of scope —
#     always executes for real), never POSTMERGE_REVERIFY=1 / V_REVERIFY_FULL=1 (the merge-back
#     combined-state verify is the last line of defense and ALWAYS runs), opt-out via
#     V_GATES_DEDUP=0;
#   - the memo is HMAC-signed (same 0600 per-install key as the gauntlet witness) over ALL
#     binding fields (tree hash, config hash, ts, sid, summary+skeleton sha256, and — F6 — MODE +
#     SCOPE_DIGEST) — a hand-written or field-edited memo fails verification and the gates run;
#   - F6: MODE + SCOPE_DIGEST bind a scoped run to the EXACT in-scope file set it was tested
#     against (SCOPE_DIGEST = sha256 of the sorted 4-source file-list union — same union the F1
#     blind-scope guard below uses, via the shared _td_scope_list helper); a full memo can never
#     satisfy a scoped request or the reverse (checked on the signed field, not just the
#     mode-keyed filename — see _td_memo_paths);
#   - CONFIG_HASH binds the resolved gate command set AND this script's own content — any
#     command override change or runner edit invalidates the memo;
#   - TTL-bounded (V_GATES_DEDUP_TTL_SEC, default 21600 = 6h) — bounds the residual risk from
#     state the tree hash cannot see (.env, DB, node_modules; lockfiles ARE tracked → covered);
#   - the memo is only ever WRITTEN by the companion TREEDEDUP-MEMO-WRITE block below, under
#     strictly-green conditions, with a pre/post tree-hash EQUALITY check binding it to the tree
#     the gates actually tested, AND (F6 hostile-review follow-up) a pre/post SCOPE_DIGEST
#     equality check — SESSION_WRITES lives under .v/ (excluded from the tree hash), so a
#     mid-run mutation to it would otherwise be invisible to the tree-hash check alone.
# Wording contract: the emitted prose must never contain skip/partial/defer/not-run vocabulary —
# the CRA W71 scanner blocks (skip-word AND suite-word AND time-word) lines; "reused/carried
# over/content-identical" is the sanctioned phrasing (proven against the real CRA in
# v-run-gates-treededup-test.sh).
_TD_HASH_T0=""; _TD_CONFIG_HASH=""; _TD_MAIN_ART=""
_td_tree_hash() {
  # Content hash of the ENTIRE working tree state via a throwaway index: seeded from HEAD,
  # `git add -A` layers on staged+unstaged+untracked (ignored files excluded by git itself),
  # write-tree emits the content OID. Never touches the real index. Empty output = caller
  # must fail closed (no dedup).
  local _top _idx _tree
  _top="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_top" ] || return 1
  _idx="$(mktemp "${TMPDIR:-/tmp}/vtd-idx.XXXXXX" 2>/dev/null)" && [ -n "$_idx" ] || return 1
  if ! GIT_INDEX_FILE="$_idx" git -C "$_top" read-tree HEAD 2>/dev/null; then rm -f "$_idx"; echo "v-run-gates: TREEDEDUP — tree hash unavailable (git read-tree HEAD failed); dedup disabled for this run (fail-closed)." >&2; return 1; fi
  # TREEDEDUP-IGN (2026-09-01, cohort forensic): naming a path in an `:(exclude)` pathspec makes
  # `git add` exit 1 whenever that path EXISTS and is GITIGNORED ("The following paths are ignored
  # by one of your .gitignore files: .v") — git's ignored-path check matches the exclude item
  # literally (dir.c exclude_matches_pathspec), and 2.50.1 still does. Every repo that ignores .v/
  # (several local repos) therefore returned an EMPTY hash here and
  # the whole dedup mechanism was silently OFF in all of them: 0 reuse hits across hundreds of gate
  # summaries, and the only memos ever written were in the one repo that does NOT ignore
  # .v/. An ignored path is already skipped by `git add -A`, so the exclude item is only needed for
  # NON-ignored ones: build the pathspec conditionally. Non-ignored case: byte-identical pathspec,
  # identical hash. Ignored case: goes from "no hash" to "hash" over exactly the same content (.v
  # never enters the index either way). `${_td_ps[@]+...}` keeps bash-3.2 `set -u` happy on an
  # empty array. check-ignore rc: 0 = ignored (drop the item), anything else = keep it (today's
  # behavior). Bite: v-run-gates-treededup-test.sh T11.
  local _td_ps=() _td_x
  for _td_x in .v .v-prompt-packs; do
    # --no-index (review PANEL-CORRECTNESS-4): plain check-ignore reports a directory as NOT ignored
    # once it holds any TRACKED file, yet `git add` still errors on the exclude item in that case —
    # the rule set, not the index, is what the add error keys on, so ask about the rules only.
    git -C "$_top" check-ignore -q --no-index -- "$_td_x" 2>/dev/null || _td_ps+=(":(exclude)$_td_x")
  done
  if ! GIT_INDEX_FILE="$_idx" git -C "$_top" add -A -- . ${_td_ps[@]+"${_td_ps[@]}"} 2>/dev/null; then rm -f "$_idx"; echo "v-run-gates: TREEDEDUP — tree hash unavailable (throwaway-index git add -A failed); dedup disabled for this run (fail-closed)." >&2; return 1; fi
  _tree="$(GIT_INDEX_FILE="$_idx" git -C "$_top" write-tree 2>/dev/null)"
  rm -f "$_idx"
  [ -n "$_tree" ] || { echo "v-run-gates: TREEDEDUP — tree hash unavailable (git write-tree produced nothing); dedup disabled for this run (fail-closed)." >&2; return 1; }
  printf '%s' "$_tree"
}
# === F6 TREEDEDUP-SCOPE (2026-08-29) ===
# Extends the tree-hash dedup below to cover PFM=scoped runs, not just PFM=full. A scoped run's
# "identical tree" claim is meaningless on its own: two scoped runs can share a tree hash while
# covering DIFFERENT in-scope file sets (BASE_SHA_FOR_DIFF can move between dispatches of the same
# session), so the memo key must ALSO bind the in-scope file set — never just the tree content —
# or a scoped reuse could silently carry over a verdict for files it never actually tested.
# _td_scope_list is the SAME 4-source union the F1 blind-scope guard uses below (working tree,
# staged, the SID-scoped session-writes log, base..HEAD) — reused verbatim (not reimplemented) so
# the digest and the blind-scope guard can never disagree about what "in scope" means. Deliberately
# excludes PFM=dirty-tree — out of scope for this change; dirty-tree runs never satisfy the
# eligibility gate below and always execute for real (fail-closed default, not a regression).
_TD_MODE=""; _TD_SCOPE_DIGEST=""
_td_scope_list() {
  {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    [ -f "${SESSION_WRITES:-}" ] && cat "$SESSION_WRITES"
    [ -n "${BASE_SHA_FOR_DIFF:-}" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null
  } | sed '/^[[:space:]]*$/d' | sort -u
}
_td_scope_digest() {
  # MODE=full is never file-set-scoped (it covers the whole tree, which the tree hash already
  # binds) — a fixed sentinel keeps this field always-present (so the HMAC canonical never carries
  # an empty positional field) without pretending a real file-set digest was computed for it.
  local _mode="$1"
  if [ "$_mode" = "full" ]; then
    printf '%s' "v-gates-treededup-full-scope-sentinel-v1" | _gw_sha256_stdin
    return 0
  fi
  _td_scope_list | _gw_sha256_stdin
}
_td_memo_paths() {
  # Selects the on-disk memo trio for the given mode. Full-mode filenames are BYTE-IDENTICAL to
  # the pre-F6 names (no regression to the existing full-mode path); scoped gets a distinct
  # mode-keyed filename so alternating full/scoped runs never thrash each other's memo. This
  # filename split is a lookup index ONLY — the real security boundary is the signed MODE +
  # SCOPE_DIGEST fields inside the memo, checked below regardless of which file they came from.
  local _mode="$1" _art="$2" _suf=""
  [ "$_mode" = "scoped" ] && _suf="-scoped"
  _TD_MEMO="$_art/gates-green-memo${_suf}.txt"
  _TD_MEMO_SUM="$_art/gates-green-memo${_suf}-summary.txt"
  _TD_MEMO_SKEL="$_art/gates-green-memo${_suf}-skeleton.md"
}
# === end F6 TREEDEDUP-SCOPE helpers ===
if { [ "$PFM" = "full" ] || [ "$PFM" = "scoped" ]; } && [ "${POSTMERGE_REVERIFY:-0}" != "1" ] && [ "${V_REVERIFY_FULL:-0}" != "1" ] \
   && [ "${V_GATES_DEDUP:-1}" != "0" ]; then
  _TD_GWLIB="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh"
  if [ -f "$_TD_GWLIB" ]; then
    # shellcheck source=/dev/null
    . "$_TD_GWLIB" 2>/dev/null || true
  fi
  if command -v _gw_compute_hmac >/dev/null 2>&1 && command -v _gw_sha256 >/dev/null 2>&1; then
    _TD_HASH_T0="$(_td_tree_hash || true)"
    # Self-binding: prefer the running file, but a RELATIVE $0/BASH_SOURCE stops resolving after
    # the section-1 cd — fall back to the canonical installed runner (fail-closed if neither reads).
    _TD_SELF="${BASH_SOURCE[0]:-}"
    { [ -n "$_TD_SELF" ] && [ -f "$_TD_SELF" ]; } || _TD_SELF="$HOME/.claude/skills/v/references/v-run-gates.sh"
    _TD_SELF_SHA="$(_gw_sha256 "$_TD_SELF" 2>/dev/null || true)"
    if [ -n "$_TD_HASH_T0" ] && [ -n "$_TD_SELF_SHA" ]; then
      # F6-CFG (2026-09-05, cohort forensic): TSC_CMD_DEFAULT embeds TSC_INCREMENTAL_CACHE, which is
      # "${V_TMP_DIR}/tsbuildinfo-${SESSION_ID}" — a PER-SESSION path. Hashing it verbatim made
      # CONFIG_HASH differ for every SID, so a memo written by session A could NEVER validate in
      # session B, and P1C auto-scopes every same-SID re-run, so the full memo had no reader at all:
      # 0 reuse hits across a cohort of gate-summaries while memos were being written, including two runs
      # minutes apart on the identical tree. The harness never saw it because every
      # fixture pins TSC_CMD_DEFAULT="true". The cache FILE path is not part of what the gate tests
      # (same tsc, same flags, same tree); only that path is normalised — a real change to the tsc
      # command line (user TSC_CMD override, flag edit) still changes the hash. Bite:
      # v-run-gates-treededup-test.sh T12.
      _td_tsc_cfg="${TSC_CMD_DEFAULT//"${TSC_INCREMENTAL_CACHE:-}"/<tsbuildinfo>}"
      _TD_CONFIG_HASH="$(printf '%s|%s|%s|%s|%s|%s' \
        "$_td_tsc_cfg" "$LINT_CMD_DEFAULT" "$BUILD_CMD_DEFAULT" \
        "$PEST_CMD_DEFAULT" "$VITEST_CMD_DEFAULT" "$_TD_SELF_SHA" | _gw_sha256_stdin || true)"
    fi
    _TD_MODE="$PFM"
    _TD_SCOPE_DIGEST="$(_td_scope_digest "$_TD_MODE" || true)"
    _td_main_root="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)"
    _TD_MAIN_ART="${_td_main_root:-${PROJECT_ROOT:-}}/.v/artifacts"
    _td_memo_paths "$_TD_MODE" "$_TD_MAIN_ART"
    if [ -n "$_TD_HASH_T0" ] && [ -n "$_TD_CONFIG_HASH" ] && [ -n "$_TD_SCOPE_DIGEST" ] && [ -f "$_TD_MEMO" ] \
       && [ -f "$_TD_MEMO_SUM" ] && [ -f "$_TD_MEMO_SKEL" ]; then
      _td_f(){ sed -n "s/^$1=//p" "$_TD_MEMO" 2>/dev/null | head -1; }
      _td_m_tree="$(_td_f TREE_HASH)"; _td_m_cfg="$(_td_f CONFIG_HASH)"
      _td_m_ts="$(_td_f TS)"; _td_m_epoch="$(_td_f EPOCH)"; _td_m_sid="$(_td_f SID)"
      _td_m_sumsha="$(_td_f SUMMARY_SHA256)"; _td_m_skelsha="$(_td_f SKELETON_SHA256)"
      _td_m_mode="$(_td_f MODE)"; _td_m_scopedig="$(_td_f SCOPE_DIGEST)"
      _td_m_hmac="$(_td_f HMAC)"
      _td_now="$(date +%s)"; _td_ttl="${V_GATES_DEDUP_TTL_SEC:-21600}"
      _td_ok=1; _td_why=""
      # F6-CFG: _td_why names the FIRST failed check on the fail-closed path so a production log can
      # say WHICH of tree/config/mode/scope/ttl/hmac rejected the memo (the cohort logs said only
      # "tree/config/TTL/HMAC" and the config cause went undiagnosed). Diagnostic only — every check
      # below still sets _td_ok=0 exactly as before.
      [ -n "$_td_m_tree" ] && [ -n "$_td_m_cfg" ] && [ -n "$_td_m_ts" ] && [ -n "$_td_m_epoch" ] \
        && [ -n "$_td_m_sid" ] && [ -n "$_td_m_sumsha" ] && [ -n "$_td_m_skelsha" ] \
        && [ -n "$_td_m_mode" ] && [ -n "$_td_m_scopedig" ] && [ -n "$_td_m_hmac" ] || { _td_ok=0; _td_why="fields"; }
      [ "$_td_ok" = 1 ] && { [ "$_td_m_tree" = "$_TD_HASH_T0" ] || { _td_ok=0; _td_why="tree"; }; }
      [ "$_td_ok" = 1 ] && { [ "$_td_m_cfg" = "$_TD_CONFIG_HASH" ] || { _td_ok=0; _td_why="config"; }; }
      # F6: a full memo must never satisfy a scoped request, nor the reverse — checked HERE (on
      # the signed field), not just via the filename split above, so a memo file copied/renamed
      # across the full/scoped boundary still fails closed.
      [ "$_td_ok" = 1 ] && { [ "$_td_m_mode" = "$_TD_MODE" ] || { _td_ok=0; _td_why="mode"; }; }
      [ "$_td_ok" = 1 ] && { [ "$_td_m_scopedig" = "$_TD_SCOPE_DIGEST" ] || { _td_ok=0; _td_why="scope"; }; }
      if [ "$_td_ok" = 1 ]; then
        case "$_td_m_epoch" in ''|*[!0-9]*) _td_ok=0; _td_why="ttl" ;; *) [ $(( _td_now - _td_m_epoch )) -le "$_td_ttl" ] && [ "$_td_m_epoch" -le "$_td_now" ] || { _td_ok=0; _td_why="ttl"; } ;; esac
      fi
      if [ "$_td_ok" = 1 ]; then
        [ "$(_gw_sha256 "$_TD_MEMO_SUM" 2>/dev/null)" = "$_td_m_sumsha" ] || { _td_ok=0; _td_why="summary-sha"; }
        [ "$(_gw_sha256 "$_TD_MEMO_SKEL" 2>/dev/null)" = "$_td_m_skelsha" ] || { _td_ok=0; _td_why="${_td_why:-skeleton-sha}"; }
      fi
      if [ "$_td_ok" = 1 ]; then
        _td_calc="$(_gw_compute_hmac "v-gates-treededup|${_td_m_tree}|${_td_m_cfg}|${_td_m_ts}|${_td_m_epoch}|${_td_m_sid}|${_td_m_sumsha}|${_td_m_skelsha}|${_td_m_mode}|${_td_m_scopedig}" 2>/dev/null || true)"
        { [ -n "$_td_calc" ] && [ "$_td_calc" = "$_td_m_hmac" ]; } || { _td_ok=0; _td_why="hmac"; }
      fi
      if [ "$_td_ok" = 1 ]; then
        # ── REUSE HIT: emit this SID's gate-summary + skeleton from the memoized green run. ──
        # F6: the reuse HIT must report the mode it actually reused (full or scoped) — it must
        # never hardcode "full", or a scoped reuse would emit a report claiming a full run.
        _td_mode_label="FULL"; [ "$_td_m_mode" = "scoped" ] && _td_mode_label="SCOPED"
        _td_head_now="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
        _td_done_now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        _TD_SUMMARY_OUT="$V_TMP_DIR/gate-summary-${SESSION_ID}.txt"
        {
          grep -vE '^(DONE_AT=|TREEDEDUP)' "$_TD_MEMO_SUM"
          echo "TREEDEDUP=1"
          echo "TREEDEDUP_TREE_HASH=${_TD_HASH_T0}"
          echo "TREEDEDUP_SOURCE_SID=${_td_m_sid}"
          echo "TREEDEDUP_SOURCE_TS=${_td_m_ts}"
          echo "DONE_AT=${_td_done_now}"
        } > "$_TD_SUMMARY_OUT"
        _TD_SKEL_OUT="$V_TMP_DIR/pre-flight-skeleton-${SESSION_ID}.md"
        _td_reuse_line="Reuse: tree-hash dedup — the working tree (git tree ${_TD_HASH_T0}) is content-identical (same in-scope file set) to the tree that already passed this ${_td_mode_label} gate run at ${_td_m_ts} (sid ${_td_m_sid}); gate results carried over verbatim. Force a fresh run with V_GATES_DEDUP=0."
        awk -v head="HEAD: ${_td_head_now}" -v reuse="$_td_reuse_line" '
          /^HEAD: / { print head; next }
          { print }
          /^Mode: / { print reuse }
        ' "$_TD_MEMO_SKEL" > "$_TD_SKEL_OUT"
        if mkdir -p "$_TD_MAIN_ART" 2>/dev/null; then
          cp -p "$_TD_SUMMARY_OUT" "$_TD_MAIN_ART/gate-summary-${SESSION_ID}.txt" 2>/dev/null || true
        fi
        _td_iter_line="${_td_done_now} PFM=${_td_m_mode} TREEDEDUP=1 ALL_PASS=1 DONE_AT_SOURCE=${_TD_MAIN_ART}/gate-summary-${SESSION_ID}.txt"
        printf '%s\n' "$_td_iter_line" >> "$V_TMP_DIR/gate-iterations-${SESSION_ID}.txt" 2>/dev/null || true
        printf '%s\n' "$_td_iter_line" >> "$_TD_MAIN_ART/gate-iterations-${SESSION_ID}.txt" 2>/dev/null || true
        echo "v-run-gates: TREEDEDUP — reusing the green ${_td_mode_label}-suite verdict from ${_td_m_ts} (sid ${_td_m_sid}): the current working tree is content-identical (git tree ${_TD_HASH_T0}) and the gate command set is unchanged. Gate results carried over verbatim; force a fresh run with V_GATES_DEDUP=0." >&2
        echo "=== v-run-gates summary ==="
        echo "Mode: ${_td_m_mode}"
        echo "Summary file: $_TD_SUMMARY_OUT"
        cat "$_TD_SUMMARY_OUT"
        echo "==="
        echo "v-run-gates: TREEDEDUP reuse — skeleton at $_TD_SKEL_OUT"
        exit 0
      else
        echo "v-run-gates: TREEDEDUP — memo present but did not validate (failed check: ${_td_why:-unknown}; memo tree ${_td_m_tree:-?} vs current ${_TD_HASH_T0}; memo sid ${_td_m_sid:-?}); running the gates for real (fail-closed)." >&2
      fi
    fi
  fi
fi
# === end TREEDEDUP-REUSE ===

# ── 2.5 Heartbeat (W26-followup-4) — keep Claude Code from auto-backgrounding ──
# Production evidence: pre-flight Phase 3 (pest + vitest) can run silently for
# 3-10 minutes on a real Laravel/React project. After ~60-90s of stdout silence,
# Claude Code may promote the bash invocation to a background task and return
# control to haiku, which then writes its own polling Monitor loop with
# `until ... do sleep 5 ... done` — and the per-SID gate-summary path triggers
# Cowork permission prompts on every session.
#
# Defense: print a stdout heartbeat every 20 seconds. Claude Code sees a steadily-
# producing process and keeps it foreground. The heartbeat uses STDOUT (not just
# stderr) because some Claude Code variants only inspect stdout for activity.
(
  i=0
  while sleep 20; do
    i=$((i + 20))
    printf 'v-run-gates: %ds elapsed; gates running...\n' "$i"
  done
) &
_HEARTBEAT_PID=$!
# ── W-conc-suite-lock handles (populated iff a 'full' Phase-3 acquires the lock) ──
# Cross-session serialization of the heavy full suite. Set at Phase 3; the EXIT
# trap releases as a backstop (owner-checked, so a fail-open proceed never steals).
_SUITE_LOCK_SH=""; _SUITE_LOCK_REPO=""; _SUITE_LOCK_SID="${SESSION_ID:-}"

# Cleanup on any exit path. -0 = current process group (the heartbeat is a child).
trap '_rc=$?; kill "$_HEARTBEAT_PID" 2>/dev/null; wait "$_HEARTBEAT_PID" 2>/dev/null; [ -n "${_SUITE_LOCK_SH:-}" ] && bash "$_SUITE_LOCK_SH" release "${_SUITE_LOCK_REPO:-}" "${_SUITE_LOCK_SID:-}" >/dev/null 2>&1; exit "$_rc"' EXIT INT TERM

# ── 3. Helper: change-detection across multiple sources ────────────────────

_changed_matches() {
  local regex="$1"
  git diff --name-only HEAD 2>/dev/null | grep -qE "$regex" && return 0
  git diff --cached --name-only 2>/dev/null | grep -qE "$regex" && return 0
  [ -f "$SESSION_WRITES" ] && grep -qE "$regex" "$SESSION_WRITES" && return 0
  [ -n "$BASE_SHA_FOR_DIFF" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null | grep -qE "$regex" && return 0
  return 1
}

# ── 3.5 Per-gate timing initialization (W31) ─────────────────────────────
# Initialize all *_DURATION_SEC to 0 so SKIPped gates report 0 not null.
# All times are wall-clock seconds via `date +%s`. For parallel gates we
# capture _START before the `&`-launch and _END right after `wait`.
#
# Timing semantics (W31 review):
#   _DURATION_SEC = (time `wait $PID` returned) - (time before `cmd &` ran)
#   For practical purposes this equals the gate's wall-clock run time:
#     - Bash's `wait` returns immediately on SIGCHLD (microseconds after exit).
#     - We capture _END synchronously, no other work between wait and capture.
#   Possible inflation: if a parallel gate finishes WHILE we are blocked on a
#   different `wait $OTHER_PID`, _END is delayed until our wait queue drains.
#   In practice this adds <1s for typical gate ordering — not material at
#   second-level resolution. If you ever need sub-second precision, switch
#   to per-gate child-write timestamp files.
TSC_DURATION_SEC=0; TSC_START=0; TSC_END=0
COMPOSER_AUDIT_DURATION_SEC=0; COMPOSER_AUDIT_START=0; COMPOSER_AUDIT_END=0
NPM_AUDIT_DURATION_SEC=0; NPM_AUDIT_START=0; NPM_AUDIT_END=0
LINT_DURATION_SEC=0; LINT_START=0; LINT_END=0
BUILD_DURATION_SEC=0; BUILD_START=0; BUILD_END=0
PEST_DURATION_SEC=0; PEST_START=0; PEST_END=0
VITEST_DURATION_SEC=0; VITEST_START=0; VITEST_END=0
PHASE_1_START=0; PHASE_1_END=0; PHASE_1_WALLCLOCK_SEC=0
PHASE_2_START=0; PHASE_2_END=0; PHASE_2_WALLCLOCK_SEC=0
PHASE_3_START=0; PHASE_3_END=0; PHASE_3_WALLCLOCK_SEC=0

# ── F1.7 (W56): stack-aware skip — when scoped/dirty-tree mode AND zero files
# of a stack changed, skip the gates for that stack entirely.
# W5G-9 (forensic 2026-07-10 #2): the committed diff since the pinned base
# (BASE_SHA_FOR_DIFF..HEAD) MUST be a source here, exactly as it is for the F1 blind-scope
# guard below. Without it, a post-merge/final dispatch whose session changes are already
# COMMITTED sees only working-tree dirt: that session's final pre-flight found sibling JS WIP
# (kept the run non-blind) but zero dirty .php — so Pest was SKIPPED "no PHP files changed"
# while the session's own commits touched several PHP files. Over-inclusion is the fail-safe
# direction: a swept-in sibling file can only RUN more gates, never skip them.
PHP_FILES_TOUCHED=1
JS_FILES_TOUCHED=1
if [ "$PFM" = "scoped" ] || [ "$PFM" = "dirty-tree" ]; then
  CHANGED_PHP_COUNT=$( {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    [ -f "$SESSION_WRITES" ] && cat "$SESSION_WRITES"
    [ -n "${BASE_SHA_FOR_DIFF:-}" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null
  } | sort -u | grep -cE '\.php$' || true)
  CHANGED_JS_COUNT=$( {
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    [ -f "$SESSION_WRITES" ] && cat "$SESSION_WRITES"
    [ -n "${BASE_SHA_FOR_DIFF:-}" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null
  } | sort -u | grep -cE '\.(ts|tsx|js|jsx|vue|svelte|mjs|cjs|css|scss|sass)$' || true)
  if [ "${CHANGED_PHP_COUNT:-0}" -gt 0 ]; then PHP_FILES_TOUCHED=1; else PHP_FILES_TOUCHED=0; fi
  if [ "${CHANGED_JS_COUNT:-0}" -gt 0 ]; then JS_FILES_TOUCHED=1; else JS_FILES_TOUCHED=0; fi
fi
echo "v-run-gates: F1.7 stack detection — PHP_FILES_TOUCHED=$PHP_FILES_TOUCHED JS_FILES_TOUCHED=$JS_FILES_TOUCHED" >&2

# F1 (forensic 2026-06-17): BLIND-SCOPE guard. A scoped/dirty pre-flight whose changed
# set is EMPTY across ALL sources (working tree, staged, the SID-scoped session-writes log, AND base..HEAD
# with the corrected base above) cannot see this session's diff — it ran before the implementation landed,
# or against a base that hides it. Letting every stack SKIP and then reporting a clean PASS is the observed
# false-green (it shipped PHP its own pre-flight never executed). Mark the whole run INCONCLUSIVE so it
# cannot pass as a clean gate (ALL_PASS forced to 0 + an INCONCLUSIVE Scope row below). The session-writes
# log is SID-scoped so a sibling's concurrent churn never makes a genuinely-blind run look non-blind.
PREFLIGHT_BLIND=0
# H4-4b (PLAN_2026-07-02_orchestrator-hardening-4): a post-merge re-verify (POSTMERGE_REVERIFY=1,
# set by the orchestrator per v-merge-back.sh's MERGE_BACK_REVERIFY_* contract) must ALSO run the
# blind-scope guard even when PFM=full — a re-verify is BY DEFINITION scoped to
# BASE_SHA_FOR_DIFF..HEAD (the combined sibling+session diff), so a 0-diff result there is exactly
# as blind as a scoped run seeing 0 changed files. Evidence: a gate-summary ran with
# MODE=scoped already, but nothing stopped a future re-verify dispatched with PFM=full from
# skipping this guard entirely.
if [ "$PFM" = "scoped" ] || [ "$PFM" = "dirty-tree" ] || [ "${POSTMERGE_REVERIFY:-0}" = "1" ]; then
  # F6: this is the SAME 4-source union as _td_scope_list() above (working tree, staged,
  # session-writes, base..HEAD) — computed via the shared helper so the blind-scope guard and the
  # TREEDEDUP scope digest can never drift apart on what "in scope" means. Behavior-preserving.
  _TOTAL_CHANGED=$(_td_scope_list | wc -l | tr -d ' ')
  if [ "${_TOTAL_CHANGED:-0}" -eq 0 ]; then
    PREFLIGHT_BLIND=1
    echo "v-run-gates: F1 — SCOPED pre-flight is BLIND (0 changed files across working-tree/staged/session-writes/base..HEAD) → INCONCLUSIVE, not a clean PASS. It likely ran before the implementation landed or against a base that hides this session's diff; re-run after the code is in place." >&2
  fi
fi
# F9-1 (staged-blindness fix, forensic 2026-07-05): expose the authoritative in-scope file COUNT
# (the SAME multi-source computation the blind-scope guard above just ran — working tree via
# `git diff --name-only HEAD` (already includes staged changes), PLUS an explicit `git diff
# --cached --name-only` as belt-and-suspenders, PLUS the SID-scoped session-writes log, PLUS the
# committed diff since the pinned base) so the report writer COPIES this value for "Files in
# scope: N" instead of independently (re)computing it via its own ad hoc command. A real session
# (2026-07-05) reported "Files in scope: 0 dirty files (session changes already committed/merged)"
# while several files were actually STAGED (`git add`, not yet committed) — consistent with a bare
# `git diff --name-only` (no HEAD ref, i.e. index-vs-worktree only) being used to answer that
# question: it sees ONLY unstaged changes and misses anything already staged. Left unset (empty)
# in `full` mode (where _TOTAL_CHANGED is never computed) — the report template correctly always
# cites "all" there, never a count.
IN_SCOPE_FILE_COUNT="${_TOTAL_CHANGED:-}"

# W71-F10 (forensic 2026-07-02): TREE-MISMATCH guard. That session's THIRD
# pre-flight dispatch ran in the MAIN root instead of the session worktree: it saw 0 dirty files,
# escalated scoped→full, PASSed base-tree tests containing NONE of the session's commits,
# and OVERWROTE the earlier real report — GAUNTLET_ATTESTED then pointed at an attestation of the
# wrong tree. W71-F9 (dispatcher-resolved RUN_ROOT + prompt pwd-verify + WrongTree hard-reject)
# closes the dispatch path; THIS guard is the deterministic belt inside the gate runner itself for
# any residual wrong-tree entry (runner skips the cd, stale env, manual invocation).
# Semantics: the SID's commit witness (.v/tmp/commits-<SID>.txt, newest first) lists the commits
# this session created. If the witness is non-empty and NOT ONE of its SHAs is an ancestor of the
# HEAD under test, this tree cannot contain the session's work → the run would attest base code.
# "NONE is ancestor" (not "all are") keeps amend/rebase workflows safe — any surviving session
# commit in HEAD's ancestry passes. Skipped under POSTMERGE_REVERIFY=1: merge-back REBASES the
# branch, so pre-rebase witness SHAs are legitimately absent from the post-merge HEAD.
TREE_MISMATCH=0
_COMMITS_WITNESS="$V_TMP_DIR/commits-${SESSION_ID}.txt"
if [ ! -s "$_COMMITS_WITNESS" ]; then
  # W71-F10 review F1: hooks write the commit witness to the MAIN root's .v/tmp (resolved via
  # git-common-dir), while V_TMP_DIR here follows PROJECT_ROOT env / cwd — the two can diverge
  # (custom PROJECT_ROOT, exotic cwd). Probe the common-dir root too so the guard's coverage
  # never depends on which env resolution the dispatcher happened to use.
  _tm_common="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
  if [ -n "$_tm_common" ]; then
    _tm_main_root="$(cd "$(dirname "$_tm_common")" 2>/dev/null && pwd || echo "")"
    if [ -n "$_tm_main_root" ] && [ -s "$_tm_main_root/.v/tmp/commits-${SESSION_ID}.txt" ]; then
      _COMMITS_WITNESS="$_tm_main_root/.v/tmp/commits-${SESSION_ID}.txt"
    fi
  fi
fi
if [ "${POSTMERGE_REVERIFY:-0}" != "1" ] && [ -s "$_COMMITS_WITNESS" ]; then
  _tm_any_ancestor=0; _tm_checked=0
  while IFS= read -r _tm_sha; do
    case "$_tm_sha" in ''|\#*) continue ;; esac
    _tm_sha="${_tm_sha%% *}"
    printf '%s' "$_tm_sha" | grep -qE '^[0-9a-f]{7,40}$' || continue
    _tm_checked=$((_tm_checked+1))
    if git merge-base --is-ancestor "$_tm_sha" HEAD 2>/dev/null; then
      _tm_any_ancestor=1
      break
    fi
  done < "$_COMMITS_WITNESS"
  if [ "$_tm_checked" -gt 0 ] && [ "$_tm_any_ancestor" -eq 0 ]; then
    TREE_MISMATCH=1
    echo "v-run-gates: W71-F10 — TREE MISMATCH: none of the ${_tm_checked} commit(s) in the session witness ($_COMMITS_WITNESS) is an ancestor of the HEAD under test ($(git rev-parse --short HEAD 2>/dev/null || echo unknown)). This run is testing a tree WITHOUT this session's work (wrong-root dispatch / stale cd) → INCONCLUSIVE, not a clean PASS. Re-run from the session's worktree (RUN_ROOT)." >&2
  fi
fi

# ── 4. Phase 1: TSC + PHPStan + audits in parallel ──────────────────────────

# 4a. TSC runs project-wide (can't be scoped — global type graph), but ONLY when this repo is
# actually a TypeScript project. It used to run unconditionally, which made `npx tsc` the one gate
# that could FAIL for the absence of a thing rather than for a defect: in a repo with no
# tsconfig.json and no TypeScript installed, `npx tsc --noEmit` exits 1 with "compiler not found",
# the report reads `Overall Status: FAIL`, and enforce-pre-commit-gates.sh then blocks every commit
# in that repo — with no failing code anywhere. Observed 2026-08-12 in a directory of
# unrelated projects (no root package.json/tsconfig.json; diff was only .html/.sh/.md files).
# Detection now mirrors what PHPStan does twenty lines below — "run only when the tool is actually
# present; otherwise SKIP loudly" — so the two peer static-analysis gates finally behave the same
# way. A genuine TS project always ships a tsconfig; if one is present the gate runs exactly as
# before and a missing compiler is still a FAIL, because there it means a broken toolchain.
PHASE_1_START=$(date +%s)
TSC_START=$(date +%s)
TSC_PID=""
_TSC_HAS_PROJECT=0
for _tsc_cfg in tsconfig.json tsconfig.base.json tsconfig.app.json; do
  [ -f "$_tsc_cfg" ] && { _TSC_HAS_PROJECT=1; break; }
done
if [ "$_TSC_HAS_PROJECT" = "0" ] && [ -x "node_modules/.bin/tsc" ]; then _TSC_HAS_PROJECT=1; fi
if [ "$_TSC_HAS_PROJECT" = "1" ]; then
  $TSC_CMD_DEFAULT > "$V_TMP_DIR/gate-tsc-${SESSION_ID}.log" 2>&1 &
  TSC_PID=$!
else
  TSC_RC="SKIP"
  echo "no tsconfig.json and no node_modules/.bin/tsc — not a TypeScript project, TSC gate skipped (a missing compiler is not a code defect)" \
    > "$V_TMP_DIR/gate-tsc-${SESSION_ID}.log"
fi

# 4a-bis. PHPStan — PHP static analysis, the peer of TSC (W-PHPSTAN1, forensic 2026-07-14).
# WHY: this gate did not exist. v-pre-flight-runner.md's Contract table lists "PHPStan" among the gate
# commands this runner owns, and a project's CLAUDE.md pre-flight checklist includes
# `vendor/bin/phpstan analyse --memory-limit=1G` — but v-run-gates.sh never ran it and emitted no
# PHPSTAN_RC. So a session could ship a "full" PASS with static analysis silently uncovered, and the
# PRE_FLIGHT_REPORT had no field in which the gap could even be noticed. Project-wide like TSC (the
# analysis graph is global), so it cannot be scoped to changed files.
# Detection mirrors the audit gates: run only when the tool is actually present; otherwise SKIP loudly.
PHPSTAN_PID=""
PHPSTAN_RC="SKIP"
PHPSTAN_DURATION_SEC=0
_PHPSTAN_BIN=""
for _p in "vendor/bin/phpstan" "./vendor/bin/phpstan"; do
  [ -x "$_p" ] && { _PHPSTAN_BIN="$_p"; break; }
done
if [ -n "$_PHPSTAN_BIN" ] && { [ -f "phpstan.neon" ] || [ -f "phpstan.neon.dist" ] || [ -f "phpstan.dist.neon" ]; }; then
  PHPSTAN_START=$(date +%s)
  # shellcheck disable=SC2086
  ${PHPSTAN_CMD:-$_PHPSTAN_BIN analyse --memory-limit=1G --no-progress} \
    > "$V_TMP_DIR/gate-phpstan-${SESSION_ID}.log" 2>&1 &
  PHPSTAN_PID=$!
else
  echo "phpstan binary or config not found — PHPStan skipped (no PHP static-analysis gate configured)" \
    > "$V_TMP_DIR/gate-phpstan-${SESSION_ID}.log"
fi

# 4b. composer audit — only when composer.lock changed
COMPOSER_AUDIT_PID=""
COMPOSER_AUDIT_RC="SKIP"
if [ -f "composer.lock" ] && _changed_matches '(^|/)composer\.lock$'; then
  COMPOSER_AUDIT_START=$(date +%s)
  composer audit > "$V_TMP_DIR/gate-composer-audit-${SESSION_ID}.log" 2>&1 &
  COMPOSER_AUDIT_PID=$!
else
  echo "composer.lock unchanged in session — composer audit skipped (W15)" > "$V_TMP_DIR/gate-composer-audit-${SESSION_ID}.log"
fi

# 4d. npm audit — only when JS lockfile changed
NPM_AUDIT_PID=""
NPM_AUDIT_RC="SKIP"
if _changed_matches '(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?)$'; then
  NPM_AUDIT_START=$(date +%s)
  npm audit --audit-level=critical > "$V_TMP_DIR/gate-npm-audit-${SESSION_ID}.log" 2>&1 &
  NPM_AUDIT_PID=$!
else
  echo "JS lockfile unchanged in session — npm audit skipped (W15)" > "$V_TMP_DIR/gate-npm-audit-${SESSION_ID}.log"
fi

# 4d. Wait for Phase 1
if [ -n "$TSC_PID" ]; then wait "$TSC_PID"; TSC_RC=$?; fi
TSC_END=$(date +%s); TSC_DURATION_SEC=$((TSC_END - TSC_START))
if [ -n "$PHPSTAN_PID" ]; then
  wait "$PHPSTAN_PID"; PHPSTAN_RC=$?
  PHPSTAN_END=$(date +%s); PHPSTAN_DURATION_SEC=$((PHPSTAN_END - PHPSTAN_START))
fi
if [ -n "$COMPOSER_AUDIT_PID" ]; then
  wait "$COMPOSER_AUDIT_PID"; COMPOSER_AUDIT_RC=$?
  COMPOSER_AUDIT_END=$(date +%s); COMPOSER_AUDIT_DURATION_SEC=$((COMPOSER_AUDIT_END - COMPOSER_AUDIT_START))
fi
if [ -n "$NPM_AUDIT_PID" ]; then
  wait "$NPM_AUDIT_PID"; NPM_AUDIT_RC=$?
  NPM_AUDIT_END=$(date +%s); NPM_AUDIT_DURATION_SEC=$((NPM_AUDIT_END - NPM_AUDIT_START))
fi
PHASE_1_END=$(date +%s); PHASE_1_WALLCLOCK_SEC=$((PHASE_1_END - PHASE_1_START))

echo "v-run-gates: Phase 1 done — TSC=$TSC_RC(${TSC_DURATION_SEC}s) PHPSTAN=$PHPSTAN_RC(${PHPSTAN_DURATION_SEC}s) COMPOSER=$COMPOSER_AUDIT_RC(${COMPOSER_AUDIT_DURATION_SEC}s) NPM=$NPM_AUDIT_RC(${NPM_AUDIT_DURATION_SEC}s) | wallclock=${PHASE_1_WALLCLOCK_SEC}s" >&2

# ── 5. Phase 2: JS lint → build sequential ────────────────────────────────

LINT_RC="not_run"
BUILD_RC="not_run"

PHASE_2_START=$(date +%s)
if [ -f "package.json" ]; then
  # Lint (scoped to changed JS files in scoped/dirty-tree mode)
  if [ "$JS_FILES_TOUCHED" -eq 0 ] && [ "$PFM" != "full" ]; then
    echo "F1.7: no JS files in session — eslint skipped" > "$V_TMP_DIR/gate-lint-${SESSION_ID}.log"
    LINT_RC="SKIP"
  else
  case "$PFM" in
    scoped|dirty-tree)
      CHANGED_JS=$( {
        git diff --name-only HEAD 2>/dev/null
        git diff --cached --name-only 2>/dev/null
      } | sort -u | grep -E '\.(ts|tsx|js|jsx|vue|svelte|mjs|cjs)$' || true)
      if [ -n "$CHANGED_JS" ]; then
        LINT_START=$(date +%s)
        npx eslint $CHANGED_JS > "$V_TMP_DIR/gate-lint-${SESSION_ID}.log" 2>&1
        LINT_RC=$?
        LINT_END=$(date +%s); LINT_DURATION_SEC=$((LINT_END - LINT_START))
        echo "W16: eslint scoped to $(echo "$CHANGED_JS" | wc -l | tr -d ' ') changed JS files" >&2
      else
        echo "no changed JS files — eslint skipped (W16)" > "$V_TMP_DIR/gate-lint-${SESSION_ID}.log"
        LINT_RC="SKIP"
      fi
      ;;
    full|*)
      LINT_START=$(date +%s)
      $LINT_CMD_DEFAULT > "$V_TMP_DIR/gate-lint-${SESSION_ID}.log" 2>&1
      LINT_RC=$?
      LINT_END=$(date +%s); LINT_DURATION_SEC=$((LINT_END - LINT_START))
      ;;
  esac
  fi

  # α (advisory lint, 2026-06-16): lint no longer BLOCKS. Style is already covered by
  # codebase-fit-reviewer + verify-done; lint's only unique value is a thin correctness
  # slice (react-hooks/no-undef). Keep running it (cheap, scoped) but downgrade a FAILURE
  # to ADVISORY so it never fails the gate, blocks build, or triggers a remediation loop.
  # Opt back into blocking lint with V_LINT_BLOCKING=1.
  if [ "${V_LINT_BLOCKING:-0}" != "1" ]; then
    case "$LINT_RC" in
      0|SKIP|not_run) ;;
      *) LINT_RC_RAW="$LINT_RC"; LINT_RC="ADVISORY";
         echo "v-run-gates: α — lint failed (raw RC=$LINT_RC_RAW) → ADVISORY (non-blocking)" >&2 ;;
    esac
  fi

  # Build only if lint passed (or skipped) — ADVISORY counts as non-blocking (α)
  if [ "$JS_FILES_TOUCHED" -eq 0 ] && [ "$PFM" != "full" ]; then
    echo "F1.7: no JS files in session — build skipped" > "$V_TMP_DIR/gate-build-${SESSION_ID}.log"
    BUILD_RC="SKIP"
  else
  if [ "$LINT_RC" = "0" ] || [ "$LINT_RC" = "SKIP" ] || [ "$LINT_RC" = "ADVISORY" ]; then
    BUILD_START=$(date +%s)

    # ── Lever B (W-perf-B): share the FE build with the Step 3.5 workflow-verifier ──
    # The workflow-verifier (Step 3.5) and pre-flight (here) build the SAME FE tree.
    # Whichever builds first writes fe-build-${SESSION_ID}.stamp = "<fe-tree-hash>\n<out-dir>".
    # Reuse the prior build ONLY IF (triple-gate, default-to-build on ANY doubt):
    #   (1) recorded hash == current v-fe-tree-hash.sh output, AND
    #   (2) the recorded output dir exists and is non-empty, AND
    #   (3) no tracked FE source is NEWER than the stamp (stale-asset guard).
    # Any failure / any ambiguity → build. A reuse also records FE_BUILD_REUSED=1 for
    # session-log observability (Lever G).
    _FE_BUILD_REUSED=0
    _FE_HASH_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/v-fe-tree-hash.sh"
    [ -f "$_FE_HASH_SH" ] || _FE_HASH_SH="$HOME/.claude/skills/v/references/v-fe-tree-hash.sh"
    _FE_STAMP="$V_TMP_DIR/fe-build-${SESSION_ID}.stamp"
    if [ -f "$_FE_STAMP" ] && [ -f "$_FE_HASH_SH" ]; then
      _rec_hash=$(sed -n '1p' "$_FE_STAMP" 2>/dev/null)
      _rec_out=$(sed -n '2p' "$_FE_STAMP" 2>/dev/null)
      _cur_hash=$(PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}" bash "$_FE_HASH_SH" 2>/dev/null)
      if [ -n "$_rec_hash" ] && [ "$_rec_hash" = "$_cur_hash" ] \
         && [ -n "$_rec_out" ] && [ -d "$_rec_out" ] && [ -n "$(ls -A "$_rec_out" 2>/dev/null)" ]; then
        # gate 3: stale-asset guard — no tracked FE source newer than the build stamp.
        _stale=$(git ls-files -z 2>/dev/null | tr '\0' '\n' \
          | grep -iE '\.(ts|tsx|js|jsx|mjs|cjs|vue|svelte|css|scss|sass|less|styl)$' \
          | while IFS= read -r _f; do [ -f "$_f" ] && [ "$_f" -nt "$_FE_STAMP" ] && { echo stale; break; }; done)
        [ -z "$_stale" ] && _FE_BUILD_REUSED=1
      fi
    fi

    if [ "$_FE_BUILD_REUSED" = "1" ]; then
      echo "BUILD: reused (fe-tree-hash match)" > "$V_TMP_DIR/gate-build-${SESSION_ID}.log"
      BUILD_RC=0
      printf 'FE_BUILD_REUSED=1\n' >> "$V_TMP_DIR/gate-summary-${SESSION_ID}.txt" 2>/dev/null || true
    else
      $BUILD_CMD_DEFAULT > "$V_TMP_DIR/gate-build-${SESSION_ID}.log" 2>&1
      BUILD_RC=$?
      # Record the stamp for a later consumer (workflow-verifier / merge re-verify) to reuse.
      if [ "$BUILD_RC" = "0" ] && [ -f "$_FE_HASH_SH" ]; then
        _out=""
        for _d in "${FE_BUILD_OUTPUT_DIR:-}" public/build dist build .next out; do
          [ -n "$_d" ] && [ -d "$_d" ] && { _out="$_d"; break; }
        done
        if [ -n "$_out" ]; then
          { PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}" bash "$_FE_HASH_SH" 2>/dev/null; printf '%s\n' "$_out"; } > "$_FE_STAMP" 2>/dev/null || true
        fi
      fi
    fi
    BUILD_END=$(date +%s); BUILD_DURATION_SEC=$((BUILD_END - BUILD_START))

    # FND-13: npm scripts can swallow exit codes — sniff log for known signatures
    # (skip on the reuse path — the reused log carries no build output to sniff).
    if [ "$_FE_BUILD_REUSED" != "1" ] && [ "$BUILD_RC" = "0" ] && [ -s "$V_TMP_DIR/gate-build-${SESSION_ID}.log" ]; then
      if grep -qE "(error TS[0-9]+|Module not found|Cannot find module|Build failed|ERROR in)" "$V_TMP_DIR/gate-build-${SESSION_ID}.log"; then
        BUILD_RC="nonzero_via_log_sniff"
      fi
    fi
  else
    echo "lint failed — build skipped" > "$V_TMP_DIR/gate-build-${SESSION_ID}.log"
    BUILD_RC="SKIP"
  fi
  fi
else
  echo "no package.json — lint and build skipped" > "$V_TMP_DIR/gate-lint-${SESSION_ID}.log"
  echo "no package.json — lint and build skipped" > "$V_TMP_DIR/gate-build-${SESSION_ID}.log"
  LINT_RC="SKIP"
  BUILD_RC="SKIP"
fi

PHASE_2_END=$(date +%s); PHASE_2_WALLCLOCK_SEC=$((PHASE_2_END - PHASE_2_START))
echo "v-run-gates: Phase 2 done — LINT=$LINT_RC(${LINT_DURATION_SEC}s) BUILD=$BUILD_RC(${BUILD_DURATION_SEC}s) | wallclock=${PHASE_2_WALLCLOCK_SEC}s" >&2

# ── 6. Phase 3: Pest || Vitest in parallel ────────────────────────────────

PHASE_3_START=$(date +%s)
PEST_LOG="$V_TMP_DIR/gate-pest-${SESSION_ID}.log"
VITEST_LOG="$V_TMP_DIR/gate-vitest-${SESSION_ID}.log"

# ── Lever D (W-perf-D): decide fail-fast BEFORE Phase 3 starts ─────────────
_preflight_prior_phase_failed() {
  # A "real" prior-phase failure = an RC that is neither success (0) nor SKIP nor a
  # pre-existing reclassification. Phase 3.5 reclassification has not run yet, so the
  # raw RCs are authoritative here.
  for _rc in "${TSC_RC:-0}" "${LINT_RC:-0}" "${BUILD_RC:-0}"; do
    # Trim any stray whitespace so a " " RC can't false-match the catch-all (SREV-004 hardening).
    _rc=$(printf '%s' "$_rc" | tr -d '[:space:]')
    case "$_rc" in 0|SKIP|""|INCONCLUSIVE|ADVISORY) : ;; *) return 0 ;; esac
  done
  return 1
}
_FAILFAST_SKIPPED_TESTS=0
if [ "$V_PREFLIGHT_FAILFAST" != "0" ] && [ "$PFM" != "full" ] && _preflight_prior_phase_failed; then
  _FAILFAST_SKIPPED_TESTS=1
fi

if [ "$_FAILFAST_SKIPPED_TESTS" = "1" ]; then
  # A prior phase failed → do NOT run the heavy suite this pass (pure wasted wall-clock).
  PEST_RC="SKIP"; VITEST_RC="SKIP"
  _FF_MSG="fail-fast: prior phase failed (TSC=${TSC_RC:-} LINT=${LINT_RC:-} BUILD=${BUILD_RC:-}) — Pest/Vitest not run this pass"
  printf '%s\n' "$_FF_MSG" > "$PEST_LOG"
  printf '%s\n' "$_FF_MSG" > "$VITEST_LOG"
  # Authoritative status for the PRE_FLIGHT_REPORT table (column order | Status | Gate | Notes |):
  #   | SKIP | tests | fail-fast: prior phase failed |
  printf 'PREFLIGHT_FAILFAST=1\nFAILFAST_ROW=| SKIP | tests | fail-fast: prior phase failed |\n' \
    >> "$V_TMP_DIR/gate-summary-${SESSION_ID}.txt" 2>/dev/null || true
  echo "v-run-gates: Lever D fail-fast — Phase 3 (Pest||Vitest) SKIPPED ($_FF_MSG)" >&2
  PHASE_3_END=$(date +%s); PHASE_3_WALLCLOCK_SEC=$((PHASE_3_END - PHASE_3_START))
else
# ── W-conc-suite-lock: serialize the HEAVY full suite across sessions in this repo ──
# Concurrent 'full' pre-flight runs each spawn a parallel pest suite (paratest × N
# workers); 2+ at once OOM-kill workers (observed 2026-05-26 — no "Tests:" tally,
# treated as INFRA crash) and contend on CPU/test-DB. Only 'full' mode serializes:
# scoped/dirty runs are light + fast and don't thrash. Lock is repo-wide (resolved
# to the shared main root), fail-open (waiter proceeds after timeout — never blocks
# the gate forever), and opt-out via V_NO_SUITE_LOCK=1. Released right after the
# suite (below) and by the EXIT trap as a backstop.
if [ "$PFM" = "full" ] && [ "${V_NO_SUITE_LOCK:-0}" != "1" ]; then
  _SUITE_LOCK_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/v-suite-lock.sh"
  [ -f "$_SUITE_LOCK_SH" ] || _SUITE_LOCK_SH="$HOME/.claude/skills/v/references/v-suite-lock.sh"
  if [ -f "$_SUITE_LOCK_SH" ]; then
    _SUITE_LOCK_REPO="${WORKTREE_PATH:-${PROJECT_ROOT:-$(pwd)}}"
    # Couple the lock's wait + stale windows to the gate budget so they scale
    # together: a LIVE full suite is capped at V_RUN_GATES_TIMEOUT_SEC, so a
    # stale floor of 1.5× that can never steal a live holder (even if the operator
    # raises the budget for a large monorepo); waiter gives up + proceeds at 2×.
    _SL_GT="${V_RUN_GATES_TIMEOUT_SEC:-900}"
    echo "v-run-gates: acquiring full-suite lock (serializing concurrent suites in this repo)…" >&2
    bash "$_SUITE_LOCK_SH" acquire "$_SUITE_LOCK_REPO" "$_SUITE_LOCK_SID" "$(( _SL_GT * 2 ))" "$(( _SL_GT * 3 / 2 ))" >&2 || true
  else
    _SUITE_LOCK_SH=""   # helper missing → no lock taken, nothing to release
  fi
fi

# Determine test scope per mode
case "$PFM" in
  scoped)
    CHANGED_TEST_FILES=$( {
      git diff --name-only HEAD 2>/dev/null
      git diff --cached --name-only 2>/dev/null
      [ -n "$BASE_SHA_FOR_DIFF" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null
    } | sort -u)
    SCOPE_DESC="scoped (working tree + staged + committed-since-$BASE_SHA_FOR_DIFF)"
    ;;
  dirty-tree)
    CHANGED_TEST_FILES=$( [ -n "$BASE_SHA_FOR_DIFF" ] && git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null )
    SCOPE_DESC="dirty-tree (committed-since-$BASE_SHA_FOR_DIFF only)"
    ;;
  full|*)
    CHANGED_TEST_FILES=""
    SCOPE_DESC="full (whole suite)"
    ;;
esac

PHP_TEST_FILES=$(echo "$CHANGED_TEST_FILES" | grep -E '(^|/)tests/.*\.php$' || true)
JS_TEST_FILES=$(echo "$CHANGED_TEST_FILES" | grep -E '\.(test|spec)\.(ts|tsx|js|jsx)$' || true)

PEST_PID=""
VITEST_PID=""
PEST_RC="SKIP"
VITEST_RC="SKIP"

# ── F1 broken-worktree-vendor guard (forensic 2026-06-17) ──────────────────────────────
# A worktree whose vendor/ (or vendor/bin) is a SYMLINK to main makes PHP resolve __DIR__ THROUGH the
# symlink (php.net #46260): `./vendor/bin/pest` runs MAIN's binary + autoloader, the worktree's `Tests\`
# namespace maps to MAIN's tests/, and EVERY worktree test fails to load → THOUSANDS of false
# BindingResolutionException failures + a misleading INCONCLUSIVE/FAIL pre-flight (the observed session
# burned ~12 min here, then had to re-run from main). worktree-php-setup.sh CoW-clones vendor to prevent
# this (W62-F1 v3) but FAIL-OPENS silently, so a failed/skipped clone leaves the broken symlink. Detect
# it BEFORE running the suite: attempt ONE repair (re-run the CoW-clone setup), then if STILL broken,
# hard-skip the PHP gate as INCONCLUSIVE with the real reason — never run thousands of env-artifact
# failures and report them as the session's result.
_vendor_symlinked() { [ -L vendor ] || { [ -d vendor ] && [ -L vendor/bin ]; }; }
VENDOR_BROKEN=0
if _vendor_symlinked; then
  VENDOR_BROKEN=1
  _wt_setup="$HOME/.claude/hooks/worktree-php-setup.sh"
  if [ -f "$_wt_setup" ]; then
    _gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null)
    _main_root=$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd)
    if [ -n "$_main_root" ] && [ -d "$_main_root" ] && [ "$_main_root" != "$PWD" ]; then
      echo "F1: worktree vendor is symlinked (breaks pest) — repairing via worktree-php-setup.sh (CoW-clone)" >&2
      WORKTREE_PATH="$PWD" REPO_ROOT="$_main_root" bash "$_wt_setup" >/dev/null 2>&1 || true
      _vendor_symlinked || VENDOR_BROKEN=0   # repaired
    fi
  fi
fi

# 6a. Pest (PHP)
# Optional paratest worker memory passthrough. paratest spawns each worker as its OWN
# `php` process at the php.ini default memory_limit (often 512M); when MANY tests fail,
# Collision's error renderer (token_get_all on large route/source files) OOMs the worker
# mid-render → no summary, no failure detail, just a fatal — and sessions then re-run the
# whole suite repeatedly chasing a clean result (observed 2026-05-26).
# Set PEST_PARALLEL_MEMORY (e.g. 1024M) to give workers headroom for the renderer. Opt-in
# (empty = unchanged) so we never inject a flag an older paratest might reject; the crash
# detector below points the operator here. NOTE: a too-large value (e.g. 3G×workers > RAM)
# invites the OS OOM-killer (SIGTERM) — 1024M is a sane middle.
_PEST_MEM_PASSTHRU=""
[ -n "${PEST_PARALLEL_MEMORY:-}" ] && _PEST_MEM_PASSTHRU="--passthru-php=-d memory_limit=${PEST_PARALLEL_MEMORY}"

# === W-SCOPEDPEST resolve (2026-08-04) ===
# The SCOPED lane used to hardcode ./vendor/bin/pest at three call sites while the FULL lane
# consumed the resolver at line ~411. In a project that runs PHPUnit through `php artisan test`
# and ships NO standalone pest binary, every scoped invocation therefore exited 127
# ("No such file or directory") within seconds → PEST_RC!=0 → ALL_PASS=0 → the orchestrator
# re-dispatched. MEASURED over 889 historical gate laps: scoped failed 37% (145/390) vs full 8%
# (42/499) — 4.6x. Reproduced directly in a local project:
#     ./vendor/bin/pest --parallel …  → RC=127
#     php artisan test --filter=…     → RC=0, 39 passed (510 assertions)
# and confirmed per-session by the Change-5 ledger fields: every degenerate scoped lap in
# three production sessions had BLIND=0,
# TREE_MISMATCH=0, i.e. a real scope that simply could not run.
#
# --parallel is PARATEST-backed, so it is gated on the paratest binary independently of pest:
# a project with pest but without brianium/paratest fails on the FLAG itself, which is the same
# class of error. The paratest fast path is preserved wherever it genuinely exists.
if [ -n "${PEST_CMD:-}" ]; then
  _PEST_SCOPED_BIN="$PEST_CMD"; _PEST_SCOPED_PAR=""
elif [ -x "./vendor/bin/pest" ]; then
  _PEST_SCOPED_BIN="./vendor/bin/pest"
  if [ -x "./vendor/bin/paratest" ]; then
    _PEST_SCOPED_PAR="--parallel --processes=${V_PEST_PROCESSES_SCOPED}"
  else
    _PEST_SCOPED_PAR=""
  fi
else
  _PEST_SCOPED_BIN="php artisan test"; _PEST_SCOPED_PAR=""
fi
# === end W-SCOPEDPEST resolve ===
if [ "$VENDOR_BROKEN" -eq 1 ]; then
  echo "F1: worktree vendor is SYMLINKED to main (still broken after a repair attempt). PHP resolves __DIR__ through the symlink, so ./vendor/bin/pest would run MAIN's binary against the worktree's tests → thousands of false BindingResolutionException failures, NOT a real result. Pest marked INCONCLUSIVE — fix the worktree vendor (worktree-php-setup.sh CoW-clone) or run the suite from main." > "$PEST_LOG"
  PEST_RC="INCONCLUSIVE"
elif [ "$PHP_FILES_TOUCHED" -eq 0 ] && [ "$PFM" != "full" ]; then
  echo "F1.7: no PHP files in session — pest skipped" > "$PEST_LOG"
  PEST_RC="SKIP"
elif [ -f "composer.json" ] && [ -x "./vendor/bin/pest" -o -x "./vendor/bin/phpunit" ]; then
  case "$PFM" in
    scoped|dirty-tree)
      echo "W16: Phase 3 $SCOPE_DESC" >&2
      if [ -n "$PHP_TEST_FILES" ]; then
        PEST_START=$(date +%s)
        # paratest (`pest --parallel`) accepts only a SINGLE <path> positional. Passing N changed test
        # files as positionals trips Symfony Console "Too many arguments, expected arguments 'path'" → a
        # FALSE PEST_RC=1 with 0 extractable paths (prod, 2026-06-15: 5 changed PHP test files
        # → paratest usage error, NOT a real test failure). For >1 explicit file, run the list
        # SEQUENTIALLY — pest/phpunit accept multiple <path> args. `--processes` and `--passthru-php` are
        # paratest-only (see the Phase-full note below), so neither is passed to the sequential form.
        # Scoped lists are small, so losing cross-file parallelism here is cheap; the single-file case
        # keeps `--parallel`.
        _n_php_test_files=$(printf '%s\n' "$PHP_TEST_FILES" | grep -c .)
        # W-SCOPEDPEST: use the RESOLVED runner (see the resolver above), never a hardcoded
        # ./vendor/bin/pest. The paratest-only memory passthru is expanded ONLY when the gated
        # parallel opts are actually in play — appending --passthru-php to `php artisan test`
        # would make it reject an unknown flag, reproducing the failure this fix removes.
        if [ "${_n_php_test_files:-0}" -gt 1 ]; then
          echo "$PHP_TEST_FILES" | tr '\n' ' ' | xargs $_PEST_SCOPED_BIN > "$PEST_LOG" 2>&1 &
        else
          echo "$PHP_TEST_FILES" | tr '\n' ' ' | xargs $_PEST_SCOPED_BIN $_PEST_SCOPED_PAR ${_PEST_SCOPED_PAR:+${_PEST_MEM_PASSTHRU:+"$_PEST_MEM_PASSTHRU"}} > "$PEST_LOG" 2>&1 &
        fi
        PEST_PID=$!
      elif git status --porcelain 2>/dev/null | grep -qE '\.php$'; then
        PEST_START=$(date +%s)
        $_PEST_SCOPED_BIN --dirty $_PEST_SCOPED_PAR ${_PEST_SCOPED_PAR:+${_PEST_MEM_PASSTHRU:+"$_PEST_MEM_PASSTHRU"}} > "$PEST_LOG" 2>&1 &
        PEST_PID=$!
      else
        echo "W16: no PHP test surface — pest skipped" > "$PEST_LOG"
      fi
      ;;
    full|*)
      PEST_START=$(date +%s)
      # W-perf4: when the full-mode command is paratest (`--parallel`), pass the optional
      # worker memory headroom (PEST_PARALLEL_MEMORY) the same way the scoped invocations
      # do (lines 521/525). Without it the full suite OOMs / Collision-render-crashes under
      # concurrent worktree sessions (prod sessions). `--passthru-php` is
      # paratest-only, so it is NOT appended to a non-parallel `php artisan test` fallback
      # (which would reject the unknown flag).
      case "$PEST_CMD_DEFAULT" in
        *--parallel*) $PEST_CMD_DEFAULT ${_PEST_MEM_PASSTHRU:+"$_PEST_MEM_PASSTHRU"} > "$PEST_LOG" 2>&1 & ;;
        *)            $PEST_CMD_DEFAULT > "$PEST_LOG" 2>&1 & ;;
      esac
      PEST_PID=$!
      ;;
  esac
else
  echo "no composer.json or pest/phpunit binary — pest skipped" > "$PEST_LOG"
fi

# 6b. Vitest (JS)
if [ "$JS_FILES_TOUCHED" -eq 0 ] && [ "$PFM" != "full" ]; then
  echo "F1.7: no JS files in session — vitest skipped" > "$VITEST_LOG"
  VITEST_RC="SKIP"
elif [ -f "package.json" ]; then
  PROCESSES=1
  case "$PFM" in
    scoped|dirty-tree)
      if [ -n "$JS_TEST_FILES" ]; then
        VITEST_START=$(date +%s)
        echo "$JS_TEST_FILES" | tr '\n' ' ' | xargs npx vitest run > "$VITEST_LOG" 2>&1 &
        VITEST_PID=$!
      elif [ -n "$BASE_SHA_FOR_DIFF" ]; then
        VITEST_START=$(date +%s)
        npx vitest run --changed="$BASE_SHA_FOR_DIFF" > "$VITEST_LOG" 2>&1 &
        VITEST_PID=$!
      else
        echo "W16: no BASE_SHA — vitest skipped" > "$VITEST_LOG"
      fi
      ;;
    full|*)
      VITEST_START=$(date +%s)
      $VITEST_CMD_DEFAULT > "$VITEST_LOG" 2>&1 &
      VITEST_PID=$!
      ;;
  esac
else
  echo "no package.json — vitest skipped" > "$VITEST_LOG"
fi

# 6c. Wait for Phase 3
if [ -n "$PEST_PID" ]; then
  wait "$PEST_PID"; PEST_RC=$?
  PEST_END=$(date +%s); PEST_DURATION_SEC=$((PEST_END - PEST_START))
fi
if [ -n "$VITEST_PID" ]; then
  wait "$VITEST_PID"; VITEST_RC=$?
  VITEST_END=$(date +%s); VITEST_DURATION_SEC=$((VITEST_END - VITEST_START))
fi
PHASE_3_END=$(date +%s); PHASE_3_WALLCLOCK_SEC=$((PHASE_3_END - PHASE_3_START))

# W-conc-suite-lock: release as soon as the heavy suite finishes — don't hold the
# repo-wide lock during failure-classification/reporting below. Owner-checked, so
# this is a no-op if we proceeded fail-open. Clear the handle so the EXIT trap
# (backstop for crash-before-here) doesn't double-release.
if [ -n "$_SUITE_LOCK_SH" ]; then
  bash "$_SUITE_LOCK_SH" release "$_SUITE_LOCK_REPO" "$_SUITE_LOCK_SID" >&2 2>/dev/null || true
  _SUITE_LOCK_SH=""
fi
fi  # ── end Lever D fail-fast guard (else branch: normal Phase 3 ran) ──

# 6d. Empty-output guard (W10) — empty log = INCONCLUSIVE, never PASS/FAIL
if [ -f "$PEST_LOG" ] && [ ! -s "$PEST_LOG" ]; then
  echo "WARN: $PEST_LOG empty — pest gate INCONCLUSIVE" >&2
  PEST_RC="INCONCLUSIVE"
elif [ "$PEST_RC" = "0" ] && [ -f "$PEST_LOG" ] && grep -qE 'No (dirty )?tests|^\s*0 tests' "$PEST_LOG"; then
  # Rel-FND-22: pest --dirty with no test changes prints "No dirty tests" + exits 0
  PEST_RC="SKIP"
fi
if [ -f "$VITEST_LOG" ] && [ ! -s "$VITEST_LOG" ]; then
  echo "WARN: $VITEST_LOG empty — vitest gate INCONCLUSIVE" >&2
  VITEST_RC="INCONCLUSIVE"
fi

# 6d.1 (W-fix): paratest worker-crash / render-OOM detection. When parallel workers OOM
# while Collision renders failure output (token_get_all on big route/source files), or a
# worker is SIGTERM/SIGKILL'd under memory pressure, the run dies WITHOUT a "Tests:"
# summary — every gate signal is lost, and naive callers then re-run the WHOLE suite
# repeatedly in different modes chasing a clean pass (observed 2026-05-26).
# Detect the signature and surface a distinct CRASH result with a DIRECTIVE remediation so
# the orchestrator treats it as an INFRA failure (don't re-run blindly), not a test signal.
if [ "$PEST_RC" != "0" ] && [ "$PEST_RC" != "SKIP" ] && [ "$PEST_RC" != "INCONCLUSIVE" ] && [ -f "$PEST_LOG" ]; then
  _pest_has_summary=0; grep -qE '^\s*Tests:[[:space:]]' "$PEST_LOG" && _pest_has_summary=1
  if grep -qiE 'Allowed memory size of [0-9]+ bytes exhausted|WorkerCrashedException|Exit Code (137|143)\)|received (SIGTERM|SIGKILL)' "$PEST_LOG" \
     || { [ "$_pest_has_summary" -eq 0 ] && grep -qiE 'nunomaduro/collision.*Highlighter|token_get_all|PHP Fatal error' "$PEST_LOG"; }; then
    PEST_RC="CRASH"
    echo "DETECTION_ERROR=pest_worker_crash_or_oom"
    echo "REMEDIATION=paratest workers crashed/OOM'd (Collision rendering many failures, or an OS OOM-kill of a worker) — the run produced NO authoritative Tests: tally, so this is an INFRA failure, NOT a clean test signal. Do NOT re-run the full suite repeatedly in different modes (that is the thrash this guard prevents). Instead, in order: (1) re-run gates ONCE with more worker memory by exporting PEST_PARALLEL_MEMORY=1024M; if a worker is then OS-killed (SIGTERM/137/143), LOWER it (e.g. 768M). (2) If it still cannot complete, classify the specific failing test files in ISOLATION (run each failing file alone) and compare against the merge-base via 'bash references/v-baseline-run.sh <BASE_SHA> \"<changed-files>\" <test-cmd>' (worktree-safe — NO git stash/checkout/throwaway-worktree) to separate pre-existing from session-introduced — do this ONCE, do not loop. Full log: ${PEST_LOG}."
    echo "v-run-gates: PEST gate CRASHED (worker OOM / render-OOM / SIGTERM) — see $PEST_LOG; treated as INFRA crash, not a pass/fail test signal" >&2
  fi
fi

echo "v-run-gates: Phase 3 done — PEST=$PEST_RC(${PEST_DURATION_SEC}s) VITEST=$VITEST_RC(${VITEST_DURATION_SEC}s) | wallclock=${PHASE_3_WALLCLOCK_SEC}s" >&2

# ── Phase 3.5 (W27-F1): Pre-existing vs session-introduced classification ──
# Production motivation: in a production session (W27 audit), PRE_FLIGHT haiku put
# dozens of PHP test failures in BOTH `## Gates` (FAIL) AND `## Pre-existing Baseline`,
# even though zero PHP files changed in the session. The W26-followup mirror
# rule then propagated the FAIL into SESSION_LOG. The fix: classify pre-existing
# vs session-introduced MECHANICALLY here, not via haiku discretion in the
# dispatch prompt.
#
# Heuristic: a failing test FILE that does NOT overlap with the session's
# changed-file set is pre-existing. False negatives possible (a session that
# modifies app/Foo.php could break tests/Feature/FooTest.php without touching
# the test file) but those are rare; the dominant case (test fails for reasons
# unrelated to session changes) is correctly classified.

PRE_EXISTING_PEST=0
SESSION_INTRO_PEST=0
PRE_EXISTING_VITEST=0
SESSION_INTRO_VITEST=0

# W57-F1: scanner-test blind spot. The OVERLAP heuristic (failing test FILE ∩
# changed FILE set) cannot attribute failures from WHOLE-CODEBASE SCANNER tests
# — tests/Contracts/, *CopyScanner*, architecture/convention tests — because the
# scanner test file is broken by a changed SOURCE file yet never appears in the
# diff itself. So OVERLAP=0 → it would be auto-reclassified PASS_WITH_PRE_EXISTING
# even though the session introduced the violation (production: a UI component
# change tripped a banned-copy scanner test → false-green PASS). Guard: when a scanner test is
# among the failing files AND the session changed anything, refuse the
# pre-existing downgrade and force INCONCLUSIVE (never a silent pass). Baseline-
# diff-by-name (v-core-pre-existing.md) is the only sound way to clear a scanner
# failure as pre-existing; absent that, INCONCLUSIVE demands a look.
SCANNER_FAIL_PEST=0
SCANNER_FAIL_VITEST=0
SCANNER_TEST_RE='(tests/(Contracts|Arch|Architecture|Conventions?)/)|[Bb]anned(Copy|Phrase|Word|Text)|ArchitectureTest|ArchTest|ConventionTest'

# W52-F1: CHANGED_THIS_SESSION uses primary-fallback semantics that mirror
# W47-A's `check-review-artifact.sh:111-149` ALL_CHANGED_PATHS construction:
#   - Writes-log present (file exists, even if content empty) → use it ONLY
#     (excludes pre-existing dirt from session-attribution)
#   - Writes-log absent → fall back to git-state union (legacy semantics)
# A production session had a controller file as pre-existing
# dirt; legacy git-diff-based CHANGED_THIS_SESSION captured it and the
# OVERLAP calculation falsely classified test failures as session-introduced.
# Post-W52, writes-log = [one UI file] → OVERLAP=0 → correctly
# classified as PRE_EXISTING.
CHANGED_THIS_SESSION=""
W52_WRITES_LOG_AVAILABLE=0
if [ -f "$HOME/.claude/hooks/lib/session-writes.sh" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.claude/hooks/lib/session-writes.sh"
  if type get_session_writes >/dev/null 2>&1; then
    _w52_writes=$(get_session_writes "$SESSION_ID" 2>/dev/null || true)
    _w52_path=$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)
    if [ -n "$_w52_writes" ] || { [ -n "$_w52_path" ] && [ -f "$_w52_path" ]; }; then
      W52_WRITES_LOG_AVAILABLE=1
      CHANGED_THIS_SESSION="$_w52_writes"
    fi
  fi
fi

if [ "$W52_WRITES_LOG_AVAILABLE" -eq 0 ] && [ -n "$BASE_SHA_FOR_DIFF" ]; then
  # Legacy fallback: sessions predating track-session-writes.sh hook.
  CHANGED_THIS_SESSION=$( {
    git diff --name-only "$BASE_SHA_FOR_DIFF..HEAD" 2>/dev/null
    git diff --name-only HEAD 2>/dev/null
    git diff --cached --name-only 2>/dev/null
  } | sort -u)
fi

if [ -n "$BASE_SHA_FOR_DIFF" ]; then
  # Original outer guard preserved — the OVERLAP/extraction logic below
  # only runs when we have a base for both writes-log and git-state paths.

  # Pest classification — only when pest actually ran and saw failures.
  # W50 fixes:
  #   F1: strip ANSI before regex (Pest emits \x1b[30;42;1m PASS \x1b[39;49;22m
  #       — ANSI escape comes BEFORE the FAIL/PASS keyword, breaking the legacy
  #       regex anchor `^[[:space:]]*FAIL `). A production session had
  #       a very large log with many unique failing files; legacy code extracted ZERO.
  #   F2: drop head -200 fallback. With ANSI stripped, the whole-log scan with
  #       proper marker filtering is reliable and fast (sed+grep are streaming).
  #   F3: asymmetry detection — if PEST_RC indicates failure AND extraction
  #       returns no files, set EXTRACTION_FAILED=pest and DO NOT classify as
  #       session-introduced. Caller treats this as INCONCLUSIVE.
  if [ "$PEST_RC" != "0" ] && [ "$PEST_RC" != "SKIP" ] && [ "$PEST_RC" != "INCONCLUSIVE" ] && [ "$PEST_RC" != "CRASH" ] && [ -f "$PEST_LOG" ]; then
    # F1: strip ANSI CSI sequences (\x1b[<args>m) AND cursor / erase sequences
    # (\x1b[K, \x1b[?25l, etc.) AND raw carriage returns. sed is no-op on
    # plain-text logs, so it's safe to run unconditionally.
    PEST_LOG_CLEAN=$(sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' "$PEST_LOG" 2>/dev/null)
    # W50 phase-2 review CRITICAL: Pest's FAIL header lines only contain the test
    # CLASS namespace (Tests\Foo\BarTest) — no file path. The actual file path
    # appears in stack-trace lines: `at tests/Foo/BarTest.php:45` or in Pest's
    # `   N  tests/Foo/BarTest.php:45` table format. Marker must include those
    # patterns to be functional (the legacy FAIL/⨯/Tests: marker returned 0
    # paths on real Pest output — production replay confirmed).
    PEST_PATH_RE='(tests|app|src|database|config|routes|bootstrap)/[^[:space:]]+\.php'
    # W50 phase-2 review HIGH#2: exclude framework paths that appear in stack
    # traces (vendor/, node_modules/, Illuminate/, Symfony/) — these are NOT
    # session-touchable and pollute the failing-set.
    PEST_EXCLUDE_RE='(^|/)(vendor|node_modules|Illuminate|Symfony)/'
    FAILING_PEST_FILES=$(printf '%s\n' "$PEST_LOG_CLEAN" \
      | grep -E '(^[[:space:]]*FAIL |^[[:space:]]*FAILED |^[[:space:]]*⨯ |Tests:.*[Ff]ail|^[[:space:]]*at .*\.php:|^[[:space:]]*[0-9]+[[:space:]]+[a-zA-Z_/.-]+\.php:)' 2>/dev/null \
      | grep -oE "$PEST_PATH_RE" \
      | grep -vE "$PEST_EXCLUDE_RE" \
      | sort -u)
    # Whole-log fallback (post-strip, framework-excluded). Used if marker filter
    # missed something — but the same exclude regex prevents framework path
    # contamination identified by the W50 phase-2 reviewer.
    if [ -z "$FAILING_PEST_FILES" ]; then
      FAILING_PEST_FILES=$(printf '%s\n' "$PEST_LOG_CLEAN" \
        | grep -oE "$PEST_PATH_RE" \
        | grep -vE "$PEST_EXCLUDE_RE" \
        | sort -u)
    fi
    if [ -n "$FAILING_PEST_FILES" ]; then
      # W50: use wc -l + tr to avoid the W40-A "0\n0" two-line bug class
      # (grep -c on empty input returns "0" + exit 1; || echo 0 then prints
      # another "0", breaking subsequent arithmetic).
      OVERLAP_PEST=$(comm -12 <(echo "$FAILING_PEST_FILES") <(echo "$CHANGED_THIS_SESSION") 2>/dev/null | wc -l | tr -d ' \n')
      OVERLAP_PEST=${OVERLAP_PEST:-0}
      TOTAL_PEST=$(echo "$FAILING_PEST_FILES" | wc -l | tr -d ' \n')
      TOTAL_PEST=${TOTAL_PEST:-0}
      OVERLAP_PEST=$(( ${OVERLAP_PEST:-0} ))
      TOTAL_PEST=$(( ${TOTAL_PEST:-0} ))
      SESSION_INTRO_PEST=$OVERLAP_PEST
      PRE_EXISTING_PEST=$((TOTAL_PEST - OVERLAP_PEST))
      # W57-F1: flag scanner-test failures — OVERLAP cannot attribute these.
      if echo "$FAILING_PEST_FILES" | grep -qE "$SCANNER_TEST_RE"; then
        SCANNER_FAIL_PEST=1
      fi
    else
      # F3 asymmetry detection: RC says failure but we found no paths.
      # Don't fabricate session-introduced — surface as extraction failure.
      EXTRACTION_FAILED_PEST=1
      # E1 (forensic 2026-06-15): "rc=1 but 0 paths" made the orchestrator re-dispatch the
      # WHOLE pre-flight blind. Enrich the INCONCLUSIVE row so it can be adjudicated from THIS log
      # instead — parse the Pest summary failed-count + the failing CLASS names (FAIL lines carry the
      # test class, never a file path, which is exactly why the path regex returned 0). This changes
      # NO verdict (still INCONCLUSIVE — never an auto-pass): a fatal in changed code must not slip.
      # Take the MAX failed-count across all `Tests:` summary lines (codex review): a later coverage
      # footer or `--retry` summary can emit a 2nd `Tests:` line with a lower/0 failed count; `tail -1`
      # would under-report. Max is conservative (advisory only — the verdict is FAIL regardless).
      PEST_FAILED_COUNT=$(printf '%s\n' "$PEST_LOG_CLEAN" \
        | grep -oE 'Tests:[^\n]*' | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' | sort -rn | head -1)
      PEST_FAILED_COUNT=${PEST_FAILED_COUNT:-unknown}
      PEST_FAIL_NAMES=$(printf '%s\n' "$PEST_LOG_CLEAN" \
        | grep -oE '^[[:space:]]*(FAIL|FAILED|⨯)[[:space:]]+[A-Za-z0-9_\\]+' 2>/dev/null \
        | sed -E 's/^[[:space:]]*(FAIL|FAILED|⨯)[[:space:]]+//' | sort -u | head -10 | paste -sd',' - 2>/dev/null)
      if [ "$PEST_FAILED_COUNT" = "0" ]; then
        echo "v-run-gates: E1 — pest PEST_RC=$PEST_RC but summary shows 0 FAILED tests; rc is a NON-test-failure (risky/deprecation/bootstrap), NOT a broken test. Still INCONCLUSIVE (no auto-pass); see report row." >&2
      else
        echo "v-run-gates: WARN — pest extraction returned 0 paths despite PEST_RC=$PEST_RC (summary failed=${PEST_FAILED_COUNT}); classification INCONCLUSIVE — failing classes: ${PEST_FAIL_NAMES:-none-extracted}" >&2
      fi
    fi
  fi

  # Vitest classification.
  # W50 fixes (same as Pest): F1 strip ANSI before regex, F2 drop head -200
  # fallback (whole-log scan is reliable post-strip), F3 asymmetry detection.
  if [ "$VITEST_RC" != "0" ] && [ "$VITEST_RC" != "SKIP" ] && [ "$VITEST_RC" != "INCONCLUSIVE" ] && [ -f "$VITEST_LOG" ]; then
    VITEST_LOG_CLEAN=$(sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\r//g' "$VITEST_LOG" 2>/dev/null)
    # Vitest markers: ❯ (file header), FAIL, × (test marker), "Test Files" summary,
    # plus stack-trace lines `at file:line` (W50 phase-2 review parity with pest).
    VITEST_PATH_RE='[a-zA-Z0-9_/.-]+\.(test|spec)\.(ts|tsx|js|jsx)'
    VITEST_EXCLUDE_RE='(^|/)(node_modules|vendor)/'
    FAILING_VITEST_FILES=$(printf '%s\n' "$VITEST_LOG_CLEAN" \
      | grep -E '(^[[:space:]]*❯ |^[[:space:]]*FAIL |^[[:space:]]*× |Test Files.*failed|^[[:space:]]*at .*\.(test|spec)\.)' 2>/dev/null \
      | grep -oE "$VITEST_PATH_RE" \
      | grep -vE "$VITEST_EXCLUDE_RE" \
      | sort -u)
    if [ -z "$FAILING_VITEST_FILES" ]; then
      FAILING_VITEST_FILES=$(printf '%s\n' "$VITEST_LOG_CLEAN" \
        | grep -oE "$VITEST_PATH_RE" \
        | grep -vE "$VITEST_EXCLUDE_RE" \
        | sort -u)
    fi
    if [ -n "$FAILING_VITEST_FILES" ]; then
      OVERLAP_VITEST=$(comm -12 <(echo "$FAILING_VITEST_FILES") <(echo "$CHANGED_THIS_SESSION") 2>/dev/null | wc -l | tr -d ' \n')
      OVERLAP_VITEST=${OVERLAP_VITEST:-0}
      TOTAL_VITEST=$(echo "$FAILING_VITEST_FILES" | wc -l | tr -d ' \n')
      TOTAL_VITEST=${TOTAL_VITEST:-0}
      OVERLAP_VITEST=$(( ${OVERLAP_VITEST:-0} ))
      TOTAL_VITEST=$(( ${TOTAL_VITEST:-0} ))
      SESSION_INTRO_VITEST=$OVERLAP_VITEST
      PRE_EXISTING_VITEST=$((TOTAL_VITEST - OVERLAP_VITEST))
      # W57-F1: flag scanner-test failures — OVERLAP cannot attribute these.
      if echo "$FAILING_VITEST_FILES" | grep -qE "$SCANNER_TEST_RE"; then
        SCANNER_FAIL_VITEST=1
      fi
    else
      EXTRACTION_FAILED_VITEST=1
      echo "v-run-gates: WARN — vitest extraction returned 0 paths despite VITEST_RC=$VITEST_RC; classification INCONCLUSIVE" >&2
    fi
  fi
fi

# Re-classify gate RCs based on the introduced/pre-existing split:
# - If ALL failures are pre-existing AND zero are session-introduced → reclassify to PASS
#   (downstream consumers expect "FAIL" only when session changes broke something).
# - If ANY failures are session-introduced → keep as FAIL.
# - The original RC is preserved as PEST_RC_RAW / VITEST_RC_RAW for forensics.
PEST_RC_RAW="$PEST_RC"
VITEST_RC_RAW="$VITEST_RC"

# W27-followup reliability #2: coerce integers explicitly before comparison
# to defeat empty-string / mixed-type fragility (no more `2>/dev/null` band-aid).
SESSION_INTRO_PEST=$(( ${SESSION_INTRO_PEST:-0} ))
PRE_EXISTING_PEST=$(( ${PRE_EXISTING_PEST:-0} ))
SESSION_INTRO_VITEST=$(( ${SESSION_INTRO_VITEST:-0} ))
PRE_EXISTING_VITEST=$(( ${PRE_EXISTING_VITEST:-0} ))

if [ "$PEST_RC" != "0" ] && [ "$PEST_RC" != "SKIP" ] && [ "$PEST_RC" != "INCONCLUSIVE" ] && [ "$PEST_RC" != "CRASH" ]; then
  if [ "$SESSION_INTRO_PEST" -eq 0 ] && [ "$PRE_EXISTING_PEST" -gt 0 ]; then
    if [ "$SCANNER_FAIL_PEST" -eq 1 ] && [ -n "$CHANGED_THIS_SESSION" ]; then
      # W57-F1: a whole-codebase scanner test (Contracts/arch/banned-copy) is
      # failing and this session changed files. OVERLAP=0 does NOT prove
      # pre-existence here — the scanner is broken by a changed SOURCE file it
      # scans, not by an edit to the test file. Refuse the silent pass.
      PEST_RC="INCONCLUSIVE"
      # We are explicitly declining to certify these as pre-existing, so don't
      # let the ## Pre-existing Baseline section claim they were cleared. The
      # SCANNER_FAIL_PEST flag + scanner-inconclusive baseline row carry forensics.
      PRE_EXISTING_PEST=0
      echo "v-run-gates: W57-F1 — pest scanner-test failure with session changes present; OVERLAP cannot attribute it → PEST_RC=INCONCLUSIVE (baseline-diff-by-name or manual review required; NOT auto-pre-existing)" >&2
    else
      PEST_RC="PASS_WITH_PRE_EXISTING"
      echo "v-run-gates: Phase 3.5 — pest reclassified PEST_RC=$PEST_RC_RAW → PEST_RC=$PEST_RC ($PRE_EXISTING_PEST pre-existing failures, 0 session-introduced)" >&2
    fi
  fi
fi

if [ "$VITEST_RC" != "0" ] && [ "$VITEST_RC" != "SKIP" ] && [ "$VITEST_RC" != "INCONCLUSIVE" ]; then
  if [ "$SESSION_INTRO_VITEST" -eq 0 ] && [ "$PRE_EXISTING_VITEST" -gt 0 ]; then
    if [ "$SCANNER_FAIL_VITEST" -eq 1 ] && [ -n "$CHANGED_THIS_SESSION" ]; then
      VITEST_RC="INCONCLUSIVE"
      PRE_EXISTING_VITEST=0
      echo "v-run-gates: W57-F1 — vitest scanner-test failure with session changes present; OVERLAP cannot attribute it → VITEST_RC=INCONCLUSIVE (baseline-diff-by-name or manual review required; NOT auto-pre-existing)" >&2
    else
      VITEST_RC="PASS_WITH_PRE_EXISTING"
      echo "v-run-gates: Phase 3.5 — vitest reclassified VITEST_RC=$VITEST_RC_RAW → VITEST_RC=$VITEST_RC ($PRE_EXISTING_VITEST pre-existing failures, 0 session-introduced)" >&2
    fi
  fi
fi

echo "v-run-gates: Phase 3.5 done — PEST pre-existing=$PRE_EXISTING_PEST session=$SESSION_INTRO_PEST | VITEST pre-existing=$PRE_EXISTING_VITEST session=$SESSION_INTRO_VITEST" >&2

# W56-F1.3: compute ALL_PASS for downstream consumers (F2.1 skeleton emit).
# Placed AFTER reclassification so PASS_WITH_PRE_EXISTING is reachable.
ALL_PASS=1
# W-PHPSTAN1: PHPSTAN_RC joins the blocking set. It is a hard gate like TSC (not ADVISORY like lint) —
# a static-analysis error is a real defect, and a project's own pre-flight checklist treats it as
# blocking. "SKIP" (no phpstan binary/config in this project) is accepted by the case arm below, so
# non-PHP projects are unaffected.
for _rc in "$TSC_RC" "$PHPSTAN_RC" "$LINT_RC" "$BUILD_RC" "$PEST_RC" "$VITEST_RC" "$COMPOSER_AUDIT_RC" "$NPM_AUDIT_RC"; do
  case "$_rc" in
    0|SKIP|PASS_WITH_PRE_EXISTING|not_run|ADVISORY) ;;  # ADVISORY (α): lint is non-blocking
    *) ALL_PASS=0; break ;;
  esac
done
# F1: a BLIND scoped run is never a clean PASS — every stack SKIPped only because pre-flight could not
# see the diff. Force ALL_PASS=0 so Overall Status becomes FAIL (with the INCONCLUSIVE Scope row below).
[ "${PREFLIGHT_BLIND:-0}" -eq 1 ] && ALL_PASS=0
# W71-F10: a wrong-tree run is never a clean PASS — the gates executed, but against a tree that
# does not contain this session's commits (see the TREE_MISMATCH guard above Phase 1).
[ "${TREE_MISMATCH:-0}" -eq 1 ] && ALL_PASS=0
echo "v-run-gates: F1.3 ALL_PASS=$ALL_PASS (PREFLIGHT_BLIND=${PREFLIGHT_BLIND:-0} TREE_MISMATCH=${TREE_MISMATCH:-0})" >&2

# H4-4c (PLAN_2026-07-02_orchestrator-hardening-4): a POSTMERGE_REVERIFY run writes its skeleton +
# summary to a `-postmerge` SUFFIXED path, never the session's primary artifact. Evidence
# a gate-summary OVERWROTE the earlier real (non-blind) gate-summary with a blind
# 1-second SKIP-shaped result — aliasing a stale real PASS report with a bogus SKIP summary that
# then coexisted with it. The orchestrator reads the -postmerge file explicitly for the
# combined-state verdict; it never clobbers the artifact the Stop-hook gate already validated.
_GATE_SUFFIX=""
[ "${POSTMERGE_REVERIFY:-0}" = "1" ] && _GATE_SUFFIX="-postmerge"

# W56-F2.1: emit canonical PRE_FLIGHT report skeleton.
SKELETON_FILE="$V_TMP_DIR/pre-flight-skeleton-${SESSION_ID}${_GATE_SUFFIX}.md"
{
  echo "Repo: $(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  echo "HEAD: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "Mode: ${PFM}"
  echo "## Gates"
  echo "| Status | Gate | Notes |"
  echo "|--------|------|-------|"
  _row() {
    local rc="$1" gate="$2" notes="$3"
    case "$rc" in
      0) echo "| PASS | $gate | $notes |" ;;
      ADVISORY) echo "| ADVISORY | $gate | ${notes} — lint advisory, non-blocking (α); raw RC=${LINT_RC_RAW:-?} |" ;;
      SKIP) echo "| SKIP | $gate | $notes |" ;;
      INCONCLUSIVE) echo "| INCONCLUSIVE | $gate | $notes |" ;;
      PASS_WITH_PRE_EXISTING) echo "| PASS | $gate | $notes (pre-existing failures excluded) |" ;;
      not_run) echo "| SKIP | $gate | not run for this stack |" ;;
      nonzero_via_log_sniff) echo "| FAIL | $gate | log shows error patterns despite RC=0 |" ;;
      CRASH) echo "| FAIL | $gate | INFRA CRASH — paratest worker OOM/SIGTERM, NO authoritative tally (DETECTION_ERROR=pest_worker_crash_or_oom). Do NOT re-run the suite blindly; follow the REMEDIATION (PEST_PARALLEL_MEMORY, else isolated per-file classification once). |" ;;
      *) echo "| FAIL | $gate | RC=$rc; $notes |" ;;
    esac
  }
  _row "$TSC_RC" "TypeScript" "${TSC_DURATION_SEC}s"
  # W-PHPSTAN1: emit the row even when SKIP — an ABSENT row is how the gap hid. A reader of the old
  # report could not tell "PHPStan passed" from "PHPStan never ran"; the row makes SKIP legible.
  _row "$PHPSTAN_RC" "Static analysis (PHPStan)" "${PHPSTAN_DURATION_SEC}s"
  _row "$LINT_RC" "Lint" "${LINT_DURATION_SEC}s"
  _row "$BUILD_RC" "Build" "${BUILD_DURATION_SEC}s"
  _row "$PEST_RC" "PHP Tests" "${PEST_DURATION_SEC}s"
  _row "$VITEST_RC" "JS Tests" "${VITEST_DURATION_SEC}s"
  # W56-F2.1 H1 fix: Security row mapping covers all audit-state combinations.
  # Both SKIP: lockfiles unchanged -> SKIP (existing).
  # One ran, one SKIP: only the run audit contributes; FAIL if it failed.
  # Both ran: PASS if both 0; FAIL if either non-zero.
  case "${COMPOSER_AUDIT_RC}_${NPM_AUDIT_RC}" in
    SKIP_SKIP)
      echo "| SKIP | Security | lockfiles unchanged in session |"
      ;;
    SKIP_0)
      echo "| PASS | Security | npm audit (composer skipped) |"
      ;;
    0_SKIP)
      echo "| PASS | Security | composer audit (npm skipped) |"
      ;;
    0_0)
      echo "| PASS | Security | composer + npm audit |"
      ;;
    SKIP_*)
      echo "| FAIL | Security | npm audit RC=${NPM_AUDIT_RC} |"
      ;;
    *_SKIP)
      echo "| FAIL | Security | composer audit RC=${COMPOSER_AUDIT_RC} |"
      ;;
    0_*)
      echo "| FAIL | Security | npm audit RC=${NPM_AUDIT_RC} |"
      ;;
    *_0)
      echo "| FAIL | Security | composer audit RC=${COMPOSER_AUDIT_RC} |"
      ;;
    *)
      echo "| FAIL | Security | composer RC=${COMPOSER_AUDIT_RC}, npm RC=${NPM_AUDIT_RC} |"
      ;;
  esac
  # F1: surface the blind-scope INCONCLUSIVE row so the orchestrator sees WHY the run is FAIL and what to do.
  if [ "${PREFLIGHT_BLIND:-0}" -eq 1 ]; then
    echo "| INCONCLUSIVE | Scope | BLIND: 0 changed files across working-tree/staged/session-writes/base..HEAD — pre-flight could not see this session's diff (ran before implementation landed, or a stale/sibling base). NOT a clean pass; re-run pre-flight AFTER the code is committed/in place. |"
  fi
  # W71-F10: surface the wrong-tree INCONCLUSIVE row so the orchestrator sees WHY the run is FAIL.
  if [ "${TREE_MISMATCH:-0}" -eq 1 ]; then
    echo "| INCONCLUSIVE | Tree | TREE MISMATCH: none of the session's witnessed commits (.v/tmp/commits-<SID>.txt) is an ancestor of the HEAD this run tested — the gates executed against a tree WITHOUT this session's work (wrong-root dispatch / stale cd). NOT an attestation of the session's code; re-run from the session worktree (RUN_ROOT). |"
  fi
  echo ""
  if [ "${PRE_EXISTING_PEST:-0}" -gt 0 ] || [ "${PRE_EXISTING_VITEST:-0}" -gt 0 ]; then
    echo "## Pre-existing Baseline"
    # F11: explicit machine baseline citation ⇒ satisfies CRA _pf_baseline_cited (suppresses the
    # catastrophic-count over-block on HONEST pre-existing failures). GUARDED non-empty (IR-2): an empty
    # "Base SHA:" would still match the regex with no real baseline = a laundering vector — so emit only with a SHA.
    [ -n "${BASE_SHA_FOR_DIFF:-}" ] && echo "Base SHA: ${BASE_SHA_FOR_DIFF}"
    echo "| Count | Gate | Note |"
    echo "|-------|------|------|"
    [ "${PRE_EXISTING_PEST:-0}" -gt 0 ] && echo "| ${PRE_EXISTING_PEST} | PHP Tests | pre-existing on merge-base; not session-introduced |"
    [ "${PRE_EXISTING_VITEST:-0}" -gt 0 ] && echo "| ${PRE_EXISTING_VITEST} | JS Tests | pre-existing on merge-base; not session-introduced |"
    echo ""
  fi
  if [ "$ALL_PASS" -eq 1 ]; then
    echo "Overall Status: PASS"
  else
    echo "Overall Status: FAIL"
  fi
} > "$SKELETON_FILE"

echo "v-run-gates: F2.1 skeleton emitted at $SKELETON_FILE" >&2



# ── 7. Write authoritative gate-summary file (W25-A) ───────────────────────

SUMMARY_FILE="$V_TMP_DIR/gate-summary-${SESSION_ID}${_GATE_SUFFIX}.txt"
{
  echo "TSC_RC=${TSC_RC}"
  echo "PREFLIGHT_BLIND=${PREFLIGHT_BLIND:-0}"
  echo "TREE_MISMATCH=${TREE_MISMATCH:-0}"
  echo "EXTRACTION_FAILED_PEST=${EXTRACTION_FAILED_PEST:-0}"
  echo "EXTRACTION_FAILED_VITEST=${EXTRACTION_FAILED_VITEST:-0}"
  echo "PHPSTAN_RC=${PHPSTAN_RC}"
  echo "COMPOSER_AUDIT_RC=${COMPOSER_AUDIT_RC}"
  echo "NPM_AUDIT_RC=${NPM_AUDIT_RC}"
  echo "LINT_RC=${LINT_RC}"
  echo "BUILD_RC=${BUILD_RC}"
  echo "PEST_RC=${PEST_RC}"
  echo "VITEST_RC=${VITEST_RC}"
  # W31: per-gate wall-clock duration in seconds. SKIPped gates report 0.
  # Sum of these may exceed wallclock because Phase 1 + Phase 3 run in parallel.
  echo "TSC_DURATION_SEC=${TSC_DURATION_SEC}"
  echo "PHPSTAN_DURATION_SEC=${PHPSTAN_DURATION_SEC}"
  echo "COMPOSER_AUDIT_DURATION_SEC=${COMPOSER_AUDIT_DURATION_SEC}"
  echo "NPM_AUDIT_DURATION_SEC=${NPM_AUDIT_DURATION_SEC}"
  echo "LINT_DURATION_SEC=${LINT_DURATION_SEC}"
  echo "BUILD_DURATION_SEC=${BUILD_DURATION_SEC}"
  echo "PEST_DURATION_SEC=${PEST_DURATION_SEC}"
  echo "VITEST_DURATION_SEC=${VITEST_DURATION_SEC}"
  echo "PHASE_1_WALLCLOCK_SEC=${PHASE_1_WALLCLOCK_SEC}"
  echo "PHASE_2_WALLCLOCK_SEC=${PHASE_2_WALLCLOCK_SEC}"
  echo "PHASE_3_WALLCLOCK_SEC=${PHASE_3_WALLCLOCK_SEC}"
  echo "PHASES_TOTAL_WALLCLOCK_SEC=$((PHASE_1_WALLCLOCK_SEC + PHASE_2_WALLCLOCK_SEC + PHASE_3_WALLCLOCK_SEC))"
  # W27-F1: pre-existing vs session-introduced classification (mechanical heuristic).
  # Use these to populate ## Pre-existing Baseline correctly without haiku discretion.
  echo "PEST_RC_RAW=${PEST_RC_RAW:-${PEST_RC}}"
  echo "VITEST_RC_RAW=${VITEST_RC_RAW:-${VITEST_RC}}"
  echo "PRE_EXISTING_PEST=${PRE_EXISTING_PEST:-0}"
  echo "SESSION_INTRO_PEST=${SESSION_INTRO_PEST:-0}"
  echo "PRE_EXISTING_VITEST=${PRE_EXISTING_VITEST:-0}"
  echo "SESSION_INTRO_VITEST=${SESSION_INTRO_VITEST:-0}"
  echo "SCANNER_FAIL_PEST=${SCANNER_FAIL_PEST:-0}"
  echo "SCANNER_FAIL_VITEST=${SCANNER_FAIL_VITEST:-0}"
  # W57-F2: baseline-health signal. A large pre-existing pile means the
  # baseline the classifier compares against is itself noisy — real regressions
  # are likelier to hide inside it. Advisory only (never changes pass/fail);
  # mirrors the ">=4 not_evaluated = infra drift" elevation in gate-schema.md.
  _baseline_total=$(( ${PRE_EXISTING_PEST:-0} + ${PRE_EXISTING_VITEST:-0} ))
  echo "BASELINE_PRE_EXISTING_TOTAL=${_baseline_total}"
  if [ "${_baseline_total}" -gt 25 ]; then
    echo "BASELINE_HEALTH=degraded"
  else
    echo "BASELINE_HEALTH=ok"
  fi
  echo "MODE=${PFM}"
  # F9-2: always present (never only in stderr) so a full→scoped auto-downgrade (P1C-REVERIFY-SCOPE)
  # or full-escalation (ITEM1-BASE-EQ-HEAD) is mechanically detectable: PFM_REQUESTED != MODE means
  # the effective mode differs from what was asked for. The runner's report template must cite both.
  echo "PFM_REQUESTED=${_PFM_REQUESTED_ORIG}"
  # F9-1: authoritative in-scope file count (empty in full mode — see IN_SCOPE_FILE_COUNT
  # assignment above for the exact multi-source computation, which INCLUDES staged changes).
  echo "IN_SCOPE_FILE_COUNT=${IN_SCOPE_FILE_COUNT:-}"
  echo "SCOPE_DESC=${SCOPE_DESC:-}"
  echo "BASE_SHA_FOR_DIFF=${BASE_SHA_FOR_DIFF:-}"   # F11: machine-supplied baseline SHA so the runner can cite it in prose instead of inventing un-citable attribution language
  echo "POSTMERGE_REVERIFY=${POSTMERGE_REVERIFY:-0}"   # H4-4: marks this summary as a post-merge combined-state re-verify (written to a -postmerge suffixed file, never the primary summary)

  # W45-B: ready-to-paste baseline-classification rows. The runner SHOULD
  # copy these into the report's `## Pre-existing Baseline` section verbatim
  # rather than synthesize them from raw test output (which historically
  # caused mis-classification — production saw large piles of pre-existing
  # failures repeatedly attributed to the session, forcing manual rewrite).
  echo "BASELINE_TABLE_BEGIN"
  if [ "${PRE_EXISTING_PEST:-0}" -gt 0 ] 2>/dev/null; then
    echo "| ${PRE_EXISTING_PEST} | PHP Tests (Pest) | Pre-existing failures on merge-base — NOT session-introduced (W27-F1/W50 baseline classification: PEST_RC_RAW=${PEST_RC_RAW:-${PEST_RC}}, OVERLAP=0). The session\'s changed-file set does not overlap with files referenced by these failing tests. |"
  fi
  if [ "${PRE_EXISTING_VITEST:-0}" -gt 0 ] 2>/dev/null; then
    echo "| ${PRE_EXISTING_VITEST} | JS Tests (Vitest) | Pre-existing failures on merge-base — NOT session-introduced (W27-F1/W50: VITEST_RC_RAW=${VITEST_RC_RAW:-${VITEST_RC}}, OVERLAP=0). |"
  fi
  if [ "${SCANNER_FAIL_PEST:-0}" = "1" ] && [ "$PEST_RC" = "INCONCLUSIVE" ]; then
    echo "| ? | PHP Tests (Pest) | SCANNER-TEST INCONCLUSIVE (W57-F1) — a whole-codebase scanner test (tests/Contracts/architecture/banned-copy) failed and this session changed files. File-overlap CANNOT prove pre-existence (a changed source file breaks the scanner without touching the test file). Do NOT record as pre-existing. Confirm via baseline diff-by-name vs clean HEAD or fix the source. |"
  fi
  if [ "${EXTRACTION_FAILED_PEST:-0}" = "1" ]; then
    if [ "${PEST_FAILED_COUNT:-unknown}" = "0" ]; then
      echo "| 0 | PHP Tests (Pest) | EXTRACTION INCONCLUSIVE — RC=${PEST_RC_RAW:-${PEST_RC}} but the Pest summary shows 0 FAILED tests (E1): the non-zero RC is a NON-test-failure (risky/deprecation/bootstrap/no-tests-run), NOT a broken test. Adjudicate from this row + the pest log tail; a full pre-flight re-dispatch is NOT warranted by this alone. Still not auto-passed. |"
    else
      echo "| ? | PHP Tests (Pest) | EXTRACTION INCONCLUSIVE — pest log returned 0 file paths despite RC=${PEST_RC_RAW:-${PEST_RC}} (summary failed=${PEST_FAILED_COUNT:-unknown}). Failing classes (no file path in Pest output): ${PEST_FAIL_NAMES:-none-extracted}. Target these directly (e.g. \`pest --filter\`); do NOT blind-re-run the full pre-flight. |"
    fi
  fi
  if [ "${SCANNER_FAIL_VITEST:-0}" = "1" ] && [ "$VITEST_RC" = "INCONCLUSIVE" ]; then
    echo "| ? | JS Tests (Vitest) | SCANNER-TEST INCONCLUSIVE (W57-F1) — a whole-codebase scanner test failed and this session changed files. File-overlap CANNOT prove pre-existence. Do NOT record as pre-existing. Confirm via baseline diff-by-name vs clean HEAD or fix the source. |"
  fi
  if [ "${EXTRACTION_FAILED_VITEST:-0}" = "1" ]; then
    echo "| ? | JS Tests (Vitest) | EXTRACTION INCONCLUSIVE — vitest log returned 0 file paths despite RC=${VITEST_RC_RAW:-${VITEST_RC}}. Manual review required. |"
  fi
  echo "BASELINE_TABLE_END"

  echo "DONE_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$SUMMARY_FILE"

# ── 7b. CANARY-A (DUC-001, forensic 2026-06-22): durable gate-summary copy ──
# The gitignored .v/tmp copy above is swept by a concurrent sibling's worktree teardown / git clean before
# /v-session-log runs (3-canary forensic: gates read all NOT_APPLICABLE -> F12 false-fail on a PASSED gauntlet).
# Also write the summary to the consolidated, surviving .v/artifacts store on the MAIN root, which the
# session-log gather's _vtmp_file now searches. Resolve the MAIN root explicitly — from a worktree CWD,
# $(v-artifact-dir.sh) resolves to the worktree's OWN .v/artifacts, which is removed with the worktree.
_CANARY_MAIN=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -1)
# review LOW (codex/logic 2026-06-22): if git fails, fall back to PROJECT_ROOT (the validated MAIN checkout
# passed via env), NOT $(pwd) — from a worktree CWD pwd would target the worktree's own .v/artifacts, which
# is torn down (the exact loss this fix prevents). cp -p preserves the gate-run mtime so the durable copy's
# timestamp matches the source for the consolidate -nt freshness checks (cp-time would read spuriously fresh).
_CANARY_ART="${_CANARY_MAIN:-${PROJECT_ROOT:-$(pwd 2>/dev/null)}}/.v/artifacts"
if mkdir -p "$_CANARY_ART" 2>/dev/null; then
  # FABLE-7B-SUFFIX (2026-07-04): preserve ${_GATE_SUFFIX} in the durable copy. Previously a
  # POSTMERGE_REVERIFY run's summary was durably copied WITHOUT the -postmerge suffix, clobbering
  # the durable copy of the session's PRIMARY gate-summary (the exact aliasing H4-4c forbids for
  # the local file) — and Item 3's ledger now records the suffixed durable path, which this write
  # must actually produce for the ledger to point at a real file.
  cp -p "$SUMMARY_FILE" "$_CANARY_ART/gate-summary-${SESSION_ID}${_GATE_SUFFIX}.txt" 2>/dev/null || true
fi

# ── 7c. Item 18: append (never overwrite) a durable per-iteration COMPLETION stamp ──
# Companion to the REQUESTED-side ledger written at P1C-REVERIFY-SCOPE (top of script): that one
# records "a full-mode dispatch happened" BEFORE the scoping decision; this one records "an
# invocation actually FINISHED, in this mode, with this verdict" AFTER the gates ran — so forensics
# can count completed PRE_FLIGHT dispatches for this SID regardless of mode (full/scoped/dirty-tree)
# without depending on the single mutable gate-summary file surviving between iterations (it doesn't
# — see the item-18 root-cause note above). Written to the same two durable locations as CANARY-A
# (local $V_TMP_DIR + the resolved MAIN root's .v/artifacts) so it is discoverable the same way.
# Item 3 (2026-07-05): DONE_AT_SOURCE previously recorded the raw, EPHEMERAL $SUMMARY_FILE path
# (under $V_TMP_DIR, which resolves differently per worktree/main/dirty-tree invocation for the
# SAME sid) — forensics comparing ledger entries across iterations/invocations saw the "source"
# scatter across as many as 6 different directories even though every entry described the same
# logical gate-summary. Record the CANONICAL, worktree-invariant path instead — the durable
# MAIN-root .v/artifacts copy computed at 7b (_CANARY_ART), which is the ONE location that
# survives worktree teardown and is stable regardless of which tree this particular run executed
# in. Fall back to SUMMARY_FILE only when the durable path could not be resolved (rare: git
# worktree list failed AND PROJECT_ROOT unset).
_DONE_AT_SOURCE="${_CANARY_ART:-}/gate-summary-${SESSION_ID}${_GATE_SUFFIX}.txt"
[ -n "${_CANARY_ART:-}" ] || _DONE_AT_SOURCE="$SUMMARY_FILE"
# Change 5 diagnostics (2026-08-03): four fields so a DEGENERATE lap is ATTRIBUTABLE. Forensic
# A production session logged four `PFM_REQUESTED=full → PFM=scoped ALL_PASS=0` laps that finished in 1-6s —
# impossibly fast for a real pre-flight (tsc alone is 2-7s, pest 48s). Each did nothing, reported
# failure, and the orchestrator re-dispatched; that loop is where the wasted laps came from. The
# CAUSE was unrecoverable after the fact because gate-summary is a single per-SID file that
# section 7 TRUNCATE-OVERWRITES (line ~1666), so only the last (healthy) run's summary survived —
# while THIS ledger is append-only and therefore the right place to carry the evidence.
# PFM_REQUESTED on the SAME line makes a silent full→scoped downgrade self-evident instead of
# requiring two separate lines to be correlated; BLIND / SCOPE_N / TREE_MISMATCH name the three
# candidate causes of a no-op lap. Deliberately additive and VERDICT-NEUTRAL: ALL_PASS is still
# reported (never recomputed) here, and nothing parses individual fields of this ledger — the only
# consumer reads `wc -l` (p1c-durable-fallback-test.sh:96). Fixing the downgrade itself is left
# open ON PURPOSE: doing it without knowing which of these three fired would be guessing at
# gate-mode selection, the exact class of change this ecosystem has had to revert before.
# Bite: skills/v/references/v-gate-iteration-diagnostics-test.sh.
_P1C_ITER_LINE="$(date -u +%Y-%m-%dT%H:%M:%SZ) PFM=${PFM} PFM_REQUESTED=${_PFM_REQUESTED_ORIG:-unknown} ALL_PASS=${ALL_PASS:-unknown} BLIND=${PREFLIGHT_BLIND:-0} TREE_MISMATCH=${TREE_MISMATCH:-0} SCOPE_N=${IN_SCOPE_FILE_COUNT:-unknown} DONE_AT_SOURCE=${_DONE_AT_SOURCE}"
printf '%s\n' "$_P1C_ITER_LINE" >> "$V_TMP_DIR/gate-iterations-${SESSION_ID}.txt" 2>/dev/null || true
if [ -n "${_CANARY_MAIN:-}" ] || [ -n "${_CANARY_ART:-}" ]; then
  mkdir -p "$_CANARY_ART" 2>/dev/null || true
  # Logic review 2026-07-03: a silently-failed durable append leaves the local and durable ledgers
  # divergent with no trace — warn loudly so forensics can attribute a missing durable line to the
  # write failing here rather than to the iteration never happening.
  printf '%s\n' "$_P1C_ITER_LINE" >> "$_CANARY_ART/gate-iterations-${SESSION_ID}.txt" 2>/dev/null \
    || echo "WARNING: item-18 per-iteration ledger DURABLE append failed ($_CANARY_ART/gate-iterations-${SESSION_ID}.txt) — local copy at $V_TMP_DIR is ahead of the durable one" >&2
fi

# === TREEDEDUP-MEMO-WRITE (2026-07-09) ===
# Companion to TREEDEDUP-REUSE (see that block for the design + safety posture). Record this
# run as the reusable green witness ONLY when every green condition holds — a memo may never
# exist for anything other than a fully-green, non-blind, tree-matched, primary-lane run:
#   PFM=full or PFM=scoped (effective, F6), no -postmerge suffix, ALL_PASS=1, PREFLIGHT_BLIND=0,
#   TREE_MISMATCH=0, no DETECTION_ERROR in the summary, dedup not opted out, and _TD_HASH_T0
#   (captured BEFORE the gates ran) still equals the tree hash NOW — if the tree moved mid-run,
#   the gates tested a tree we can no longer name, so nothing is memoized (fail-closed).
# _TD_MODE / _TD_SCOPE_DIGEST / _TD_MEMO* were already computed once, above, in the
# TREEDEDUP-REUSE eligibility block (same PFM=full||scoped / !POSTMERGE_REVERIFY /
# !V_REVERIFY_FULL / V_GATES_DEDUP!=0 gate) — reused here as globals, never recomputed, so this
# block's own eligibility transitively requires that block to have run (mirrors the pre-F6
# _TD_HASH_T0/_TD_CONFIG_HASH pattern).
if { [ "$PFM" = "full" ] || [ "$PFM" = "scoped" ]; } && [ -z "${_GATE_SUFFIX:-}" ] && [ "${ALL_PASS:-0}" = "1" ] \
   && [ "${PREFLIGHT_BLIND:-0}" != "1" ] && [ "${TREE_MISMATCH:-0}" != "1" ] \
   && [ "${V_GATES_DEDUP:-1}" != "0" ] \
   && [ -n "${_TD_HASH_T0:-}" ] && [ -n "${_TD_CONFIG_HASH:-}" ] \
   && [ -n "${_TD_MODE:-}" ] && [ -n "${_TD_SCOPE_DIGEST:-}" ] && [ -n "${_TD_MAIN_ART:-}" ] \
   && ! grep -q '^DETECTION_ERROR=' "$SUMMARY_FILE" 2>/dev/null \
   && command -v _gw_compute_hmac >/dev/null 2>&1; then
  _td_w_t1="$(_td_tree_hash || true)"
  # F6 hostile-review follow-up (2026-08-29, security-reviewer + logic-reviewer independently):
  # TREE_HASH gets a pre/post equality recheck below (_td_w_t1 = _TD_HASH_T0) but SCOPE_DIGEST
  # did not — SESSION_WRITES (one of _td_scope_list's 4 sources) lives under .v/, which
  # _td_tree_hash deliberately EXCLUDES, so a mid-run mutation to that log could move the
  # in-scope file set without moving the tree hash at all. Recompute it here and require
  # equality with the pre-run snapshot, symmetric to the tree-hash recheck, so a scoped memo can
  # only ever bind the EXACT scope the gates were dispatched against.
  _td_w_scope1="$(_td_scope_digest "$_TD_MODE" || true)"
  # TREEDEDUP-001 (adversarial review 2026-07-10): a TRACKED symlink resolving under an
  # excluded dir (.v/, .v-prompt-packs/), to an absolute path, or through `..` lets its TARGET
  # content change without moving the tree hash — never memoize such trees (the verdict would
  # bind to state the hash cannot see). Plain in-repo relative targets are provably covered by
  # the hash and stay eligible. String-only test, fail-closed on unreadable links.
  _td_w_symlink_ok=1
  while IFS= read -r _td_w_lpath; do
    [ -n "$_td_w_lpath" ] || continue
    _td_w_tgt="$(readlink "$_td_w_lpath" 2>/dev/null)"
    case "$_td_w_tgt" in
      ''|/*|*..*|.v|.v/*|.v-prompt-packs|.v-prompt-packs/*) _td_w_symlink_ok=0; break ;;
    esac
  done < <(git ls-files -s 2>/dev/null | awk -F'\t' '$1 ~ /^120000 /{print $2}')
  if [ "$_td_w_symlink_ok" != "1" ]; then
    echo "v-run-gates: TREEDEDUP — repo carries a tracked symlink escaping the hash's coverage (absolute / .. / .v* target); no memo written (fail-closed)." >&2
  elif [ "$_td_w_t1" = "$_TD_HASH_T0" ] && [ "$_td_w_scope1" = "$_TD_SCOPE_DIGEST" ]; then
    if mkdir -p "$_TD_MAIN_ART" 2>/dev/null; then
      _td_w_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; _td_w_epoch="$(date +%s)"
      cp -p "$SUMMARY_FILE" "$_TD_MEMO_SUM" 2>/dev/null \
        && cp -p "$SKELETON_FILE" "$_TD_MEMO_SKEL" 2>/dev/null || true
      # TREEDEDUP-006: never sign a malformed skeleton — the reuse path splices its Reuse: line
      # after 'Mode:' and the runner contract requires the PASS verdict as the last line; a
      # skeleton missing either would reuse into a report the validators reject.
      if ! grep -q '^Mode: ' "$_TD_MEMO_SKEL" 2>/dev/null \
         || [ "$(grep -v '^$' "$_TD_MEMO_SKEL" 2>/dev/null | tail -1)" != "Overall Status: PASS" ]; then
        rm -f "$_TD_MEMO_SUM" "$_TD_MEMO_SKEL" 2>/dev/null
        echo "v-run-gates: TREEDEDUP — skeleton failed the Mode:/Overall-PASS sanity check; no memo written (fail-closed)." >&2
      fi
      _td_w_sumsha="$(_gw_sha256 "$_TD_MEMO_SUM" 2>/dev/null || true)"
      _td_w_skelsha="$(_gw_sha256 "$_TD_MEMO_SKEL" 2>/dev/null || true)"
      _td_w_hmac=""
      if [ -n "$_td_w_sumsha" ] && [ -n "$_td_w_skelsha" ]; then
        _td_w_hmac="$(_gw_compute_hmac "v-gates-treededup|${_TD_HASH_T0}|${_TD_CONFIG_HASH}|${_td_w_ts}|${_td_w_epoch}|${SESSION_ID}|${_td_w_sumsha}|${_td_w_skelsha}|${_TD_MODE}|${_TD_SCOPE_DIGEST}" 2>/dev/null || true)"
      fi
      if [ -n "$_td_w_hmac" ]; then
        _td_w_tmp="$(dirname "$_TD_MEMO")/.$(basename "$_TD_MEMO").tmp.$$"
        {
          echo "TREE_HASH=${_TD_HASH_T0}"
          echo "CONFIG_HASH=${_TD_CONFIG_HASH}"
          echo "TS=${_td_w_ts}"
          echo "EPOCH=${_td_w_epoch}"
          echo "SID=${SESSION_ID}"
          echo "SUMMARY_SHA256=${_td_w_sumsha}"
          echo "SKELETON_SHA256=${_td_w_skelsha}"
          echo "MODE=${_TD_MODE}"
          echo "SCOPE_DIGEST=${_TD_SCOPE_DIGEST}"
          echo "HMAC=${_td_w_hmac}"
        } > "$_td_w_tmp" 2>/dev/null && mv -f "$_td_w_tmp" "$_TD_MEMO" 2>/dev/null \
          && echo "v-run-gates: TREEDEDUP — green ${_TD_MODE} memo written (tree ${_TD_HASH_T0}); a content-identical tree within TTL reuses this verdict." >&2 \
          || { rm -f "$_td_w_tmp" 2>/dev/null; echo "v-run-gates: TREEDEDUP — memo write failed (non-fatal; next identical run simply re-executes the gates)." >&2; }
      else
        # An unsigned memo is a laundering vector — never write one (same posture as the witness lib).
        rm -f "$_TD_MEMO_SUM" "$_TD_MEMO_SKEL" 2>/dev/null
        echo "v-run-gates: TREEDEDUP — could not HMAC-sign the memo (openssl/secret unavailable); no memo written (fail-closed)." >&2
      fi
    fi
  else
    if [ "$_td_w_t1" != "$_TD_HASH_T0" ]; then
      echo "v-run-gates: TREEDEDUP — working tree changed while the gates ran (pre-run hash != post-run hash); no memo written (the verdict cannot be bound to a nameable tree)." >&2
    else
      echo "v-run-gates: TREEDEDUP — in-scope file set changed while the gates ran (pre-run scope digest != post-run scope digest); no memo written (the verdict cannot be bound to the scope it was actually tested against)." >&2
    fi
  fi
fi
# === end TREEDEDUP-MEMO-WRITE ===

# ── 8. Stdout summary (haiku reads this for the report) ────────────────────

echo "=== v-run-gates summary ==="
echo "Mode: $PFM"
echo "Summary file: $SUMMARY_FILE"
cat "$SUMMARY_FILE"
echo "==="
echo "Per-gate logs in: $V_TMP_DIR/gate-*.log"

exit 0
