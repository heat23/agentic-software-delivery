#!/usr/bin/env bash
# check-review-artifact.sh
# Event: Stop
# Version: 6.0.0
# Purpose: Block completion when required session-scoped quality artifacts are
# missing or semantically invalid.
#
# Changes in v6:
#   AVF-002: Headless mode now requires ALL 3 artifacts (no bypass for PRE_FLIGHT/VERIFY_DONE).
#   AVF-004: Uses shared lib/validation.sh for artifact size + section checks.
#   AVF-029: Uses shared COMPLETION_WORDS_PATTERN from lib/validation.sh.
set -euo pipefail


# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

if ! command -v jq >/dev/null 2>&1; then
  echo 'COMPLETION BLOCKED: jq is required for review-artifact enforcement. Install jq and retry.' >&2
  exit 2
fi


# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

INPUT=$(cat)

# W5G-1 (forensic 2026-06-07): do NOT blanket-exit on stop_hook_active. That made
# this gate FIRST-STOP-ONLY — after one block, remediation was never re-verified
# (a production session ended with a 600B PRE_FLIGHT below the very F8-b gate that had
# just blocked it; another session's hand-padded artifact was never re-inspected).
# Checks now RE-RUN on active stops; lib/stop-rearm.sh guarantees termination
# (identical-violation + total-block caps → loud DEADLOCK ESCAPE), so the
# original infinite-loop concern this early-exit existed for stays solved.
STOP_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)"
[ "$STOP_ACTIVE" = "true" ] || STOP_ACTIVE="false"

# W5G-8 (forensic 2026-07-10 #2): dispatched read-only runner sessions are EXEMPT. A `claude
# -p` runner spawned by v-dispatch-subagent.sh carries an HMAC token in V_DISPATCHED_SUBAGENT
# (dispatched-runner.sh — NOT a static flag; a self-persisted settings.json value fails the
# hourly-rotating verify, closing the review-CRITICAL global-disable vector). Its gauntlet
# obligations belong to the ORCHESTRATOR session that dispatched it. Without this, runners
# inherit shared-tree dirt / sibling branch commits via the attribution fallbacks below and
# spiral into 3-strike STOP_REARM escapes (a production session: a logic-reviewer runner
# blocked 3× by this very gate). The parent session's own Stop gates + the merge-back W-GATE
# still cover every file, so this narrows a false-block, it does not widen a pass. Fail-closed:
# lib missing / token invalid ⇒ NOT treated as a runner ⇒ the gate runs.
if [ -f "$HOOKS_LIB_DIR/dispatched-runner.sh" ]; then
  # shellcheck source=/dev/null
  . "$HOOKS_LIB_DIR/dispatched-runner.sh" 2>/dev/null || true
  if type _is_dispatched_runner >/dev/null 2>&1 && _is_dispatched_runner; then
    exit 0
  fi
fi

# === P2-BITE-LEDGER, ECOSYSTEM REACH (2026-08-31) ==========================================
# MUST sit ABOVE the non-git early exit below. THAT exit — not CODE_CHANGED — is the reason no
# Stop gate has ever run in ~/.claude: the config dir is deliberately never git-init'd
# (by design), so this hook returned 0 at line ~68 before parsing a SID.
# Measured by driving this hook against a session that had just edited nine files under hooks/,
# hooks/lib/ and skills/v/references/: rc=0, zero output. The P2-BITE-LEDGER gate — whose entire
# subject is exactly those directories — could never fire in the tree they live in. A BITE_LEDGER
# there was voluntary discipline, not enforcement.
#
# STRICTLY ADDITIVE, and deliberately narrow:
#   - it reads ONLY the ecosystem writes log (config-dir writes recorded by track-session-writes.sh);
#   - it does NOT touch CODE_CHANGED, IS_V_SESSION, or the git guard below;
#   - it does NOT demand the artifact gauntlet — CLAUDE.md routes ~/.claude work to the DIRECT lane,
#     so such a session owes bite evidence and nothing else;
#   - it self-bootstraps (SID + libs) because none of that has happened this early.
# Escape-safe: routed through rearm_gate exactly as _cra_block_gate does, so a session that
# genuinely cannot satisfy it deadlock-escapes instead of blocking forever.
if [ "${V_BITE_GATE:-block}" != "off" ]; then
  _eco_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _eco_cfgp="$(cd "$_eco_cfg" 2>/dev/null && pwd -P || true)"
  _eco_cwd="$(pwd -P 2>/dev/null || true)"
  # Only for a session actually operating in the config dir TREE and outside any git work tree.
  # CONTAINMENT, not equality (adversarial review 2026-08-31, CRITICAL). An exact `=` test meant a
  # Stop whose cwd was `~/.claude/hooks` or `~/.claude/skills/v/references` — two of the four
  # directories this gate exists to protect — silently exited 0. Reproduced: cwd=~/.claude blocked
  # (rc 2) while cwd=~/.claude/hooks passed (rc 0) on identical input. Any session that cd'd into a
  # subdirectory to run something and did not cd back evaded the gate with no signal. The bundled
  # harness could not see it: its stop_rc() always cd'd to the config dir root.
  _eco_in_cfg=0
  case "$_eco_cwd" in "$_eco_cfgp"|"$_eco_cfgp"/*) _eco_in_cfg=1 ;; esac
  if [ -n "$_eco_cfgp" ] && [ "$_eco_in_cfg" -eq 1 ] \
     && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for _el in resolve-sid.sh session-writes.sh validation.sh stop-rearm.sh; do
      [ -f "$HOOKS_LIB_DIR/$_el" ] && . "$HOOKS_LIB_DIR/$_el" 2>/dev/null || true
    done
    _eco_sid=""
    type resolve_sid >/dev/null 2>&1 && _eco_sid="$(resolve_sid "$INPUT" 2>/dev/null || true)"
    if [ -n "$_eco_sid" ] && type session_writes_ecosystem_log_path >/dev/null 2>&1; then
      _eco_log="$(session_writes_ecosystem_log_path "$_eco_sid" 2>/dev/null || true)"
      if [ -n "$_eco_log" ] && [ -f "$_eco_log" ]; then
        # Ghost-entry rule (ORCHFIX-H7): an entry obligates a bite only if it still exists on disk.
        # Normalize each entry before matching: an entry written by an OLDER writer (or any path
        # containing `..`) must not dodge the `^hooks/` test just because of how it was spelled.
        # Belt-and-braces with the writer-side canonicalization.
        _eco_live="$(LC_ALL=C sort -u "$_eco_log" 2>/dev/null | while IFS= read -r _ew; do
            [ -n "$_ew" ] || continue
            [ -e "$_eco_cfgp/$_ew" ] || continue
            # Case patterns inside $(...) carry a leading '(': bash 3.2 (stock macOS) otherwise reads a
            # pattern's ')' as the end of the command substitution and the whole block misparses.
            case "$_ew" in
              (*..*)
                _en_d="$(cd "$(dirname "$_eco_cfgp/$_ew")" 2>/dev/null && pwd -P || true)"
                if [ -n "$_en_d" ]; then
                  case "$_en_d/" in
                    ("$_eco_cfgp"/*) printf '%s\n' "${_en_d#"$_eco_cfgp"/}/$(basename "$_ew")" ;;
                    (*) : ;;   # resolved outside the config dir — not ours to gate
                  esac
                fi ;;
              (*) printf '%s\n' "$_ew" ;;
            esac
          done)"
        _eco_dirs=""
        for _ed in hooks/ hooks/lib/ skills/v/references/ scripts/; do
          printf '%s\n' "$_eco_live" | grep -q "^${_ed}" && _eco_dirs="${_eco_dirs}${_eco_dirs:+ }${_ed}"
        done
        if [ -n "$_eco_dirs" ]; then
          _eco_ledger=""
          [ -f "$_eco_cfgp/BITE_LEDGER_${_eco_sid}.md" ] && _eco_ledger="$_eco_cfgp/BITE_LEDGER_${_eco_sid}.md"
          _eco_reason=""
          if [ -z "$_eco_ledger" ]; then
            _eco_reason="BITE_LEDGER_${_eco_sid}.md was not found"
          elif type validate_bite_ledger >/dev/null 2>&1 \
               && ! _eco_vmsg="$(validate_bite_ledger "$_eco_ledger" "$_eco_dirs" 2>&1)"; then
            _eco_reason="BITE_LEDGER_${_eco_sid}.md is present but INVALID — ${_eco_vmsg}"
          fi
          if [ -n "$_eco_reason" ]; then
            _eco_msg="P2-BITE-LEDGER: this session changed a tracked invariant file under ${_eco_cfgp} (${_eco_dirs}) but ${_eco_reason}. TDD discipline requires proving the test was RED pre-fix and GREEN post-fix via: bash ~/.claude/skills/v/references/v-bite-ledger.sh --invariant <path> --harness <test> --red-exit <N> --green-exit 0 [--note <description>]"
            if [ "${V_BITE_GATE:-block}" = "block" ]; then
              type rearm_init >/dev/null 2>&1 && rearm_init "check-review-artifact" "$_eco_sid" "$STOP_ACTIVE"
              if type rearm_gate >/dev/null 2>&1; then
                if rearm_gate "check-review-artifact" "$_eco_sid" "$STOP_ACTIVE" "$_eco_msg"; then
                  printf '%s\n' "$_eco_msg" >&2
                  exit 2
                fi
                exit 0   # deadlock escape (rearm_gate already warned on stderr)
              fi
              printf '%s\n' "$_eco_msg" >&2
              exit 2
            else
              printf '⚠️ %s\n' "$_eco_msg" >&2
            fi
          fi
        fi
      fi
    fi
  fi
fi
# === end P2-BITE-LEDGER ecosystem reach ====================================================

# Only run inside git repositories
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Re-anchor HOOKS_LIB_DIR after the git-repo guard. PROD-NEUTRAL test-injection
# contract (audit 2026-06-18): honor $V_HOOK_LIB_DIR WHEN SET so a mutation harness
# can point this gate at a mutant lib dir; default (var unset) is the live path,
# computed from BASH_SOURCE exactly as before — zero prod-behavior change. This
# closes the line-54 blindness where an injected HOOKS_LIB_DIR/lib override was
# unconditionally discarded, making the independence-gate accept-all bypass invisible
# to the parity mutation gate.
if [ -n "${V_HOOK_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$V_HOOK_LIB_DIR"
else
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
HEADLESS_MODE=0
IMPLEMENTATION_ONLY_MODE="${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}"
if [[ -f "$HOOKS_LIB_DIR/headless-detect.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/headless-detect.sh"
  if _is_headless "$INPUT"; then
    HEADLESS_MODE=1
  fi
fi

# 2026-05-28 (bypass/WG-5): the implementation-only exemption is a RUNNER trust
# boundary, not a model-settable flag. CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1 on its
# own is unauthenticated — a model could persist it into settings.json's "env" block
# and thereby downgrade EVERY code-shipping session to "write a self-report, skip the
# gauntlet" (no PRE_FLIGHT / AGENT_REVIEW / VERIFY_DONE / witness). Honor it ONLY
# inside a trusted HEADLESS runner — the same HMAC-attested determination AVF-002
# already requires (CLAUDE_HEADLESS=1 + a valid attestation at ~/.claude/attestations/
# <sid>.json). Outside that, the var is IGNORED and the session runs the full gauntlet.
# A legitimate non-headless runner enables the exemption by creating the attestation
# (hooks/lib/headless-detect.sh::_headless_create_attestation).
IMPL_ONLY_UNTRUSTED=0
if [ "$IMPLEMENTATION_ONLY_MODE" = "1" ] && [ "$HEADLESS_MODE" != "1" ]; then
  IMPLEMENTATION_ONLY_MODE=0
  IMPL_ONLY_UNTRUSTED=1
fi

# Load shared validation functions (AVF-004, AVF-029).
# PROD-NEUTRAL test-injection contract (audit 2026-06-18): honor $V_VALIDATION_LIB
# WHEN SET (the SAME convention v-completion-selfcheck.sh already uses at its LIB= line),
# so the mutation gate can inject a mutant validation.sh that BOTH this Stop hook and the
# producer self-check load — proving _independence_verdict / _artifact_postdispatch_edited /
# the codex-forgery branch actually bite. Default (var unset) sources the live lib — zero
# prod-behavior change.
_VALIDATION_LIB="${V_VALIDATION_LIB:-$HOOKS_LIB_DIR/validation.sh}"
if [[ -f "$_VALIDATION_LIB" ]]; then
  # shellcheck disable=SC1090
  source "$_VALIDATION_LIB"
fi

# Load shared session-writes helpers (parallel-session safe attribution)
if [[ -f "$HOOKS_LIB_DIR/session-writes.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/session-writes.sh"
fi

# Load shared gauntlet-witness crypto (HMAC + content-hash) — single source of
# truth with v-gauntlet-attest.sh (Bug 6 witness hardening, 2026-05-28).
if [[ -f "$HOOKS_LIB_DIR/gauntlet-witness.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/gauntlet-witness.sh"
fi

# W5G-1: re-arm state machine (block on active stops, escape only on deadlock).
if [[ -f "$HOOKS_LIB_DIR/stop-rearm.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/stop-rearm.sh"
fi

# W65-F3: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
# Lowercased SID for files that v-gauntlet-attest.sh / SKILL.md write with a
# lowercased name (the witness + the per-invocation marker). 2026-05-28 (review L2):
# attest normalises its SID to lowercase before writing those files; if Claude Code
# ever emits an uppercase UUID, reading them with the raw SID would miss → false
# block. NOT applied to artifact globs, which must match the sub-skills' raw-case
# output. No-op today (Claude emits lowercase UUIDs); defensive for the spec edge.
SESSION_ID_LC=$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')

# W5G-1: initialise the re-arm chain for this hook×SID (natural stop = fresh
# chain) and define the single gate every block site below routes through.
#   _cra_block_gate "<message>"  → rc 0: caller emits its block + exit 2
#                                → rc 1: deadlock escape — caller MUST exit 0
# Lib missing → always block (pre-W5G behavior on the first stop, and active
# stops then also block — strictly safer than the old blanket exit-0).
if type rearm_init >/dev/null 2>&1; then
  rearm_init "check-review-artifact" "${SESSION_ID:-nosid}" "$STOP_ACTIVE"
fi
_cra_block_gate() {
  if type rearm_gate >/dev/null 2>&1; then
    rearm_gate "check-review-artifact" "${SESSION_ID:-nosid}" "$STOP_ACTIVE" "$1"
    return $?
  fi
  return 0
}

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# LEAK-GUARD (2026-08-03 class sweep, 2nd pass — this shape was missed by the first grep):
# a non-repo cwd falls through to bare pwd/"."/$PWD. ~/.claude has no git repo, so from a
# skill/hook SOURCE subdir this nests .v/ inside the source tree. Config dir ITSELF is a
# legitimate root; snap only a strict descendant that is not a git work tree.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${REPO_ROOT:-}" ] && [ -n "$_lg_cfg" ] && [ "${REPO_ROOT}" != "$_lg_cfg" ]; then
  case "${REPO_ROOT}" in
    "$_lg_cfg"/*) git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO_ROOT="$_lg_cfg" ;;
  esac
fi

# W42 review: V_TMP_DIR for PLANNING_PASS independent verification
V_TMP_DIR_RESOLVED="${V_TMP_DIR:-${CLAUDE_PROJECT_DIR:-$REPO_ROOT}/.v/tmp}"
# Item 20 sibling-sweep (cycle-3 audit 2026-07-04): resolve MAIN via the shared git-common-dir
# identity helper — the same one v-artifact-consolidate.sh/durable-artifact-copy use — so the
# Stop hook's artifact search agrees with where the consolidator PUT the artifacts. The old
# `git worktree list | head -1` heuristic is cwd-sensitive and diverged from resolve_main_root
# in external-worktree layouts (the half-closed false-"missing" class). Heuristic retained as
# the fallback when the lib is unavailable. v-completion-selfcheck.sh mirrors this in lockstep
# (it must PREDICT this hook — keep both resolutions identical).
MAIN_ROOT=""
if [ -f "$HOOKS_LIB_DIR/git-main-root.sh" ]; then
  # shellcheck source=/dev/null
  source "$HOOKS_LIB_DIR/git-main-root.sh" 2>/dev/null && MAIN_ROOT="$(resolve_main_root "$REPO_ROOT" 2>/dev/null || true)"
fi
[ -n "$MAIN_ROOT" ] || MAIN_ROOT=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"

# === SESSION-LOG INTEGRITY SWEEP (C, forensic 2026-06-16: the #3b "bypassed-canonical-never-reswept" residual) ===
# finalize-session-log.sh runs the integrity sweep at WRITE time, and /v-session-log runs it at the START of its
# NEXT invocation — but a contaminated canonical that bypassed finalize entirely (hand-written / generator-direct
# to SESSION_LOG_<sid>.yaml under a concurrent wave) AND is never followed by another finalize/invocation sits
# undetected with NO SESSION_LOG_INVALID marker, so telemetry consumers read it as truth (the same
# class). The Stop hook fires on EVERY session end, so running the sweep here closes that residual: it re-validates
# the recent canonical logs in MAIN_ROOT against the CURRENT validator and quarantines (.invalid + marker) any that
# fail. Placed BEFORE every gate so it runs even when THIS session is later blocked (the contaminated canonical may
# be a SIBLING's). Best-effort + idempotent + always-exit-0 + ≤10 logs + a no-op `find` when no recent logs exist
# (so non-/v sessions pay ~nothing). Output fully discarded — the durable SESSION_LOG_INVALID_<sid>.md IS the signal;
# it must not touch this hook's stdout/stderr contract or control flow. Opt out with V_SL_STOP_INTEGRITY=0.
# DEFAULT-SAFE inversion (framework-pitfall review): a safety net must fail toward ON — `!= "0"` means
# only the exact documented opt-out disables it; unset / "1" / "true" / any typo all keep it RUNNING (the
# `= "1"` form would have silently disabled the net on a well-meant `V_SL_STOP_INTEGRITY=true`).
if [ "${V_SL_STOP_INTEGRITY:-1}" != "0" ]; then
  _SL_INTEGRITY="${CLAUDE_SL_INTEGRITY:-$HOME/.claude/skills/v-session-log/references/v-session-log-integrity.sh}"
  if [ -f "$_SL_INTEGRITY" ] && [ -d "$MAIN_ROOT" ]; then
    bash "$_SL_INTEGRITY" "$MAIN_ROOT" >/dev/null 2>&1 || true
  fi
fi
# === end SESSION-LOG INTEGRITY SWEEP ===

# W-perf6: /v artifacts now live in `.v/artifacts/` (de-clutters the repo root). The
# `.v/artifacts/` dir is searched FIRST, then the legacy root — BACKWARD-COMPATIBLE, so a
# straggler writer that still drops a file in root keeps satisfying the gate (no bounce
# during the transition). Single source for the dir name: v-artifact-dir.sh.
ARTIFACT_SEARCH_DIRS=("$REPO_ROOT/.v/artifacts" "$REPO_ROOT")
if [[ "$MAIN_ROOT" != "$REPO_ROOT" ]]; then
  ARTIFACT_SEARCH_DIRS+=("$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT")
fi

# ── W5F-1 (forensic 2026-06-06): session-owned WORKTREE visibility ──────────────
# Wave-1 pack sessions ran in EXTERNAL worktrees (~/.claude/worktrees/<project>/build/<name>)
# while this hook fired from the MAIN root — the session's gauntlet artifacts AND its
# committed-but-unmerged work were both INVISIBLE here. Consequences (two sessions,
# 2026-06-06): honest completion could not satisfy the gate (artifacts "missing"
# although they existed in the worktree), and a worktree branch with 9 unmerged commits read
# as "no code shipped" — so a false "no implementation work was performed" HANDOFF became the
# path of least resistance and the work stranded silently. Resolve the session's worktree the
# same way v-merge-back.sh proves ownership: a `.claude-session-lock` whose first field is
# THIS SID, among `git worktree list` entries. Read-only: this only widens where the hook
# LOOKS; it never writes into the worktree.
# CAVEAT (FND-004, same-uid forgery class as the gauntlet witness): a model that DELETES its
# own `.claude-session-lock` empties SESSION_WT and re-hides the branch from W5F-1/2/3. This is
# bar-raising, not a wall — it closes the ACCIDENTAL strand (one session wrote a truthful lock and
# still stranded), not a deliberate lock-rm evasion. A full close would need a lock-independent
# "any ahead build/* branch with no satisfying artifacts" sweep at Stop.
SESSION_WT=""
SESSION_WT_BRANCH=""
SESSION_WT_AHEAD=0
SESSION_WT_STAGED_BYTES=0
if [ -n "$SESSION_ID" ]; then
  while IFS= read -r _wt_p; do
    [ -n "$_wt_p" ] || continue
    [ "$_wt_p" = "$MAIN_ROOT" ] && continue
    [ -f "$_wt_p/.claude-session-lock" ] || continue
    _wt_sid=$(awk '{print $1; exit}' "$_wt_p/.claude-session-lock" 2>/dev/null || true)
    if [ "$_wt_sid" = "$SESSION_ID" ]; then
      SESSION_WT="$_wt_p"
      SESSION_WT_BRANCH=$(git -C "$_wt_p" branch --show-current 2>/dev/null || echo "")
      break
    fi
  done < <(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
fi
# B3 (forensic F3, 2026-06-21): close the documented FND-004 gap — the lock-based scan above
# MISSES a session whose worktree was already removed (merged-then-gc, or the session ran from main
# root) while its build branch still exists ahead of main. That is exactly how a session stranded its
# docs commit and relied on a later /v-merge-all to NOTICE the advanced tip (fragile — it nearly
# missed it). Lock-INDEPENDENT fallback: resolve the session's build/fix/... branch by its
# boundary-anchored 8-hex SID slug (FNM_PATHNAME-safe — list all heads and grep, since 'refs/heads/*slug*'
# cannot cross the '/' in build/<name>), so the W5F-3 stranded-merge gate fires even when the live
# worktree/lock is gone. Anchored on -/_// boundaries so it cannot match a sibling sharing the hex run.
if [ -z "$SESSION_WT_BRANCH" ] && [ -n "${SESSION_ID:-}" ]; then
  _b3_slug="${SESSION_ID%%-*}"
  if [ -n "$_b3_slug" ] && [ "$_b3_slug" != "$SESSION_ID" ]; then
    SESSION_WT_BRANCH=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -E '^(build|fix|feature|refactor|chore|docs|test)/' \
      | grep -E "(^|[-_/])${_b3_slug}([-_/]|\$)" | head -1)
  fi
fi
if [ -n "$SESSION_WT" ]; then
  ARTIFACT_SEARCH_DIRS+=("$SESSION_WT/.v/artifacts" "$SESSION_WT")
fi

# 2026-05-28 (handoff/B4-4): broadened beyond the original web-stack set so that
# shipping code in another language + writing a HANDOFF can't escape the gauntlet.
# Covers common compiled/scripting languages, shell, and DB migrations (.sql).
# ORCHFIX-C: pattern + telemetry-artifact exemption live in the SHARED lib (single source with
# enforce-pre-commit-gates.sh — the two inline copies had drifted AND both omitted executable
# config; see hooks/lib/code-ext-pattern.sh for the incident). Inline fallback = same values.
if [ -f "$HOOKS_LIB_DIR/code-ext-pattern.sh" ]; then
  # shellcheck source=lib/code-ext-pattern.sh
  source "$HOOKS_LIB_DIR/code-ext-pattern.sh"
else
  CODE_EXT_PATTERN='\.(php|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hh|hpp|cs|scala|ex|exs|sh|bash|zsh|sql|m|mm|dart|lua|pl|pm|r|clj|cljs|erl|hs|yml|yaml|json|neon|toml|lock)$|(^|/)Dockerfile[^/]*$|(^|/)Makefile$|(^|/)\.husky/[^/.]+$|(^|/)\.github/workflows/[^/]+$'
  CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
fi
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

find_session_artifact() {
  local prefix="$1"
  [[ -n "$SESSION_ID" ]] || return 1
  # F1 (2026-07-05): the resolution algorithm (newest-mtime-across-all-dirs-wins,
  # W-perf6/CODEX-003, PLUS canonical-name-preferred-over-suffixed-variant,
  # ORCHFIX-A1) is single-sourced in hooks/lib/gauntlet-witness.sh's
  # gauntlet_find_artifact() — this hook previously carried its own inline copy that
  # had drifted from v-gauntlet-attest.sh's and enforce-pre-commit-gates.sh's (see
  # gauntlet_find_artifact's header comment for the full incident history). This
  # hook still OWNS its own search-dir resolution (ARTIFACT_SEARCH_DIRS, including the
  # W5F-1 session-worktree lookup above) — only the "which file wins" picking logic
  # moved to the shared lib.
  # Defense-in-depth (F1 regression fix, 2026-07-05): if the shared picker isn't loaded,
  # lazily source it from an absolute default INSIDE this function before failing closed.
  # This covers (a) a HOOKS_LIB_DIR resolution failure at hook top-level, and (b) the
  # awk/sed-extraction pattern several test harnesses use (postmerge-variant-resolution-
  # test.sh extracts JUST this function body into an isolated bash, where the top-level
  # `source` never ran — the bare fail-closed guard made every extracted copy FATAL).
  # Production stays fail-closed when the lib is truly gone.
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh" 2>/dev/null || true
  fi
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    echo "check-review-artifact: FATAL — gauntlet_find_artifact unavailable (hooks/lib/gauntlet-witness.sh not sourced and not loadable from \${HOOKS_LIB_DIR:-\$HOME/.claude/hooks/lib}); refusing to guess an artifact location" >&2
    return 1
  fi
  gauntlet_find_artifact "$prefix" "$SESSION_ID" "${ARTIFACT_SEARCH_DIRS[@]}"
}

# GAUNTLET_SKIPPED auto-removal (forensic 2026-06-17): clear a stale skip marker (written by a prior
# deadlock-escape, below) the moment the session is RESOLVED — i.e. ANY artifact LAYER-2 recognizes as
# "not a skip" now exists (PRE_FLIGHT / AGENT_REVIEW / VERIFY_DONE / TRIVIAL_PASS / HANDOFF / CYCLE_CAP_HANDOFF).
# Mirrors LAYER-2's own condition, so the marker is cleared exactly when the skip no longer holds, regardless
# of which exit the hook then takes (a HANDOFF-resolved session does not reach the final clean exit).
if [ -n "${REPO_ROOT:-}" ] && [ -n "${SESSION_ID:-}" ] && { [ -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" ] || [ -f "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" ]; }; then
  for _ra in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT TRIVIAL_PASS HANDOFF CYCLE_CAP_HANDOFF; do
    if find_session_artifact "$_ra" >/dev/null 2>&1; then
      rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null
      break
    fi
  done
fi

validate_implementation_report() {
  local implementation_file="$1"

  [ -f "$implementation_file" ] || return 1
  [ "$(wc -c < "$implementation_file" 2>/dev/null || echo 0)" -ge 64 ] || return 1
  grep -qiE '(finding|disposition|files changed|changed files|checks|verification|lightweight checks)' "$implementation_file" 2>/dev/null
}

# 2026-05-28 (handoff/B4-1, bypass/WG-7): completion-marker freshness.
# SessionStart fires ONCE per Claude Code conversation, so a second /v invocation
# inherits the same SID and can see a PRIOR invocation's same-SID completion
# markers (TRIVIAL_PASS / PLANNING_PASS) left on disk. Those exit-0 bypass paths
# run BEFORE the gauntlet-attestation witness gate, so a stale marker let a later
# code-shipping invocation skip the entire gauntlet. The per-invocation start
# marker (v-invocation-start-<sid>.txt, written at /v Step 0) is the freshness
# reference — identical to v-gauntlet-attest.sh's exit-5 check.
_v_file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null   # GNU first: BSD stat rejects -c silently
}

_invocation_marker_path() {
  [ -n "${SESSION_ID:-}" ] || return 1
  local _d _m
  # NB: "${TMPDIR:-}" not "${TMPDIR%/}" — the latter trips `set -u` (nounset) when
  # TMPDIR is unset (e.g. a Stop hook spawned with a scrubbed env), which would
  # abort this function, return empty, and make EVERY TRIVIAL_PASS/PLANNING_PASS
  # look stale → fail-closed false blocks.
  for _d in "$V_TMP_DIR_RESOLVED" "$REPO_ROOT/.v/tmp" "${TMPDIR:-}" "/tmp"; do
    [ -z "$_d" ] && continue
    _m="${_d%/}/v-invocation-start-${SESSION_ID_LC}.txt"
    [ -f "$_m" ] && { echo "$_m"; return 0; }
  done
  return 1
}

# _marker_is_fresh <file> <on_missing:open|closed>
# Returns 0 (fresh) iff <file> mtime >= the per-invocation start marker mtime.
# When no invocation marker exists: "open" => treat as fresh (legacy, mirrors
# attest), "closed" => treat as stale (used for code-shipping bypass paths so a
# missing marker cannot itself become a bypass).
_marker_is_fresh() {
  local _target="$1" _on_missing="${2:-open}" _mk _mk_mt _t_mt
  _mk=$(_invocation_marker_path 2>/dev/null || true)
  if [ -z "$_mk" ]; then
    [ "$_on_missing" = "closed" ] && return 1 || return 0
  fi
  _mk_mt=$(_v_file_mtime "$_mk"); _t_mt=$(_v_file_mtime "$_target")
  if [ -z "$_mk_mt" ] || [ -z "$_t_mt" ]; then
    [ "$_on_missing" = "closed" ] && return 1 || return 0
  fi
  [ "$_t_mt" -ge "$_mk_mt" ]
}

# Detect whether /v (or a /v-* sub-skill) was invoked in THIS session — via the
# append-only, SID-filtered history.jsonl. Computed EARLY (2026-05-28 interactive-
# safety fix) because it now gates the non-session-attributable git fallback below:
# this Stop hook is wired into interactive settings.json, so it fires on EVERY
# completion. Without this gate, a pure conversational turn in a repo that merely
# has PRE-EXISTING uncommitted code would trip the tree-wide git fallback
# (CODE_CHANGED=1) and get falsely blocked for "missing gauntlet" — even though the
# session never ran /v and never touched code. The gauntlet is a /v / code-session
# obligation; tree dirt alone, with no /v evidence and no session-attributed writes,
# is not.
IS_V_INVOCATION_VIA_HISTORY=0
if [ -n "$SESSION_ID" ]; then
  _hist_file="$HOME/.claude/history.jsonl"
  if [ -f "$_hist_file" ]; then
    _sid_filter='"sessionId":"'"$SESSION_ID"'"'
    # AVF-031: regex matches /v followed by space, double-quote, or hyphen+letter
    # (so /v-tdd, /v-build, etc. count as v-orchestrator invocations).
    # 2026-05-28 (review L1): CAPTURE to a var rather than piping into `grep -q`.
    # Under `set -o pipefail` (still on here; only -e was disabled), `grep -q` closes
    # the pipe on its first match and SIGPIPE-kills the upstream `grep -F`; the
    # pipeline then reports non-zero and the match is LOST — a false negative for any
    # session with enough history to overflow the ~16 KB pipe buffer. That would both
    # false-block /v abandonment HANDOFFs and unreliably gate the git fallback below.
    _v_hist_match=$( (grep -F "$_sid_filter" "$_hist_file" 2>/dev/null || true) \
      | grep -E '"display":"/v(-[a-z]|[ "])' 2>/dev/null | head -1 || true )
    [ -n "$_v_hist_match" ] && IS_V_INVOCATION_VIA_HISTORY=1
    # W4B3-PASTED-V-DETECT: When the user pastes a /v block, Claude Code stores
    # display:"[Pasted text #N +M lines]" in history.jsonl — "/v" never appears
    # in the display field, so the pattern above produces a false negative. The
    # actual "/v ..." text IS in the session transcript as a user-role message
    # with "content":"/v ...". Fall back to reading the first 30 lines of the
    # transcript when a pasted entry exists for this SID.
    # Affects ALL pasted /v sessions (W3-A, W4-A, W4-B, W4-C observed 2026-06-05).
    if [ "$IS_V_INVOCATION_VIA_HISTORY" -eq 0 ]; then
      _has_pasted=$( (grep -F "$_sid_filter" "$_hist_file" 2>/dev/null || true) \
        | grep -cF '"display":"[Pasted' 2>/dev/null || true )
      if [ "${_has_pasted:-0}" -gt 0 ]; then
        _early_tx=$(ls -1t "$HOME/.claude/projects"/*/"${SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)
        if [ -n "$_early_tx" ] && [ -f "$_early_tx" ]; then
          _pasted_v=$( head -30 "$_early_tx" \
            | grep -F '"type":"user"' \
            | grep -E '"content":"/v[ -]' 2>/dev/null | head -1 || true )
          [ -n "$_pasted_v" ] && IS_V_INVOCATION_VIA_HISTORY=1
        fi
      fi
    fi
  fi
fi

# ── OPERATOR POLICY (2026-08-03): this gate applies to /v SESSIONS ONLY ──────────────────
# Operator decision: this hook runs only for /v orchestrator sessions —
# for no other reason.
#
# Before this, enforcement keyed off CODE_CHANGED, which is derived from the git working tree and
# the session writes-log. That fires on ANY code-touching session — a one-line fix, an ecosystem
# edit, a docs commit — none of which ever ran /v and none of which have gauntlet artifacts. The
# result was repeated false blocks demanding a gauntlet the session was never obliged to produce.
#
# The gauntlet is a /v contract. If /v did not run, there is nothing here to enforce, so exit 0
# and stay silent.
#
# DELIBERATELY BROAD detection — a false "not a /v session" would silently disable the gate for a
# real /v run, which is the dangerous direction. Any ONE of these counts:
#   1. history.jsonl shows /v or /v-* for this SID (incl. the W4B3 pasted-text fallback above)
#   2. V_DEPTH >= 1            — set by /v for itself and for nested orchestration
#   3. CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1 — runner-managed /v implementation sessions
#   4. a v-invocation-start-<sid> marker exists — written by /v, and the only signal that
#      survives headless `claude -p /v ...` runs where history.jsonl display text differs
#
# Set V_STOP_GATE_ALWAYS=1 to restore the old always-on behaviour for a single run.
_V_SESSION=0
[ "${IS_V_INVOCATION_VIA_HISTORY:-0}" -eq 1 ] && _V_SESSION=1
case "${V_DEPTH:-0}" in ''|*[!0-9]*) : ;; *) [ "${V_DEPTH:-0}" -ge 1 ] && _V_SESSION=1 ;; esac
[ "${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}" = "1" ] && _V_SESSION=1
_vonly_marker="$(_invocation_marker_path 2>/dev/null || true)"
[ -n "$_vonly_marker" ] && [ -f "$_vonly_marker" ] && _V_SESSION=1
[ "${V_STOP_GATE_ALWAYS:-0}" = "1" ] && _V_SESSION=1
#   5. an UNRESOLVED GAUNTLET_OWED_<sid>.md — track-session-writes.sh anchors this the first time
#      this SID writes a real code file. It is the silent-signal case: a /v session whose history
#      display text and markers are both absent still owes a gauntlet, and skipping it here would
#      make that debt permanently invisible. Mirrors the existing IS_V_SESSION promotion further
#      down (search GAUNTLET_OWED); duplicated here because this gate returns before that runs.
#      check-review-artifact-owed-reachability-test.sh pins exactly this.
[ -n "${SESSION_ID:-}" ] && [ -f "$REPO_ROOT/.v/artifacts/GAUNTLET_OWED_${SESSION_ID}.md" ] && _V_SESSION=1
#   6. a RECOGNIZED /v artifact already exists for this SID. Those files are only ever produced by
#      /v or its sub-skills, so their presence is positive evidence — and a session that produced a
#      partial set (e.g. a lone HANDOFF) is exactly the abandonment case Part B must still judge.
#      Mirrors the recognized-artifact promotion further down (DEF-2 list); duplicated here because
#      this gate returns first. Kept to the SAME list deliberately: a bare *_<sid>.md glob would
#      re-open a laundering hole.
if [ "$_V_SESSION" -ne 1 ] && [ -n "${SESSION_ID:-}" ]; then
  for _vod in "$REPO_ROOT/.v/artifacts" "$REPO_ROOT"; do
    [ -d "$_vod" ] || continue
    for _vop in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT IMPACT_MAP QA_REPORT UX_CRITIQUE \
                WORKFLOW_VERIFICATION IMPLEMENTATION_REPORT TRIVIAL_PASS PLANNING_PASS HANDOFF \
                CYCLE_CAP_HANDOFF; do
      if [ -f "${_vod}/${_vop}_${SESSION_ID}.md" ]; then
        _V_SESSION=1
        break 2
      fi
    done
  done
fi

if [ "$_V_SESSION" -ne 1 ]; then
  exit 0
fi

CODE_CHANGED=0
ALL_CHANGED_PATHS=""
WRITES_LOG_AVAILABLE=0

# Primary attribution: per-session writes log (parallel-session safe).
# Populated by track-session-writes.sh PreToolUse hook. The git working tree
# is shared across parallel Claude sessions and CANNOT be used to attribute
# changes to a specific session.
# W49-M1: source the shared UI-path pattern library so this gate uses the
# same definition as v-classify-trivial.sh — drift between them = silent
# enforcement gap.
_UI_PATTERN_LIB="$HOOKS_LIB_DIR/ui-path-pattern.sh"
if [ -f "$_UI_PATTERN_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_UI_PATTERN_LIB"
fi

HAS_SUBAGENT_DISPATCH=0
if type get_session_writes >/dev/null 2>&1; then
  _writes=$(get_session_writes "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$_writes" ] || [ -f "$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)" ]; then
    WRITES_LOG_AVAILABLE=1
    # F1 (W0-C): strip [subagent-dispatch] markers from ALL_CHANGED_PATHS — they are
    # control signals, not file paths. Keeping them would confuse UX_CRITIQUE path detection.
    ALL_CHANGED_PATHS=$(printf '%s\n' "$_writes" | grep -v '^\[subagent-dispatch\]$' || true)
    # Note: avoid `grep -q` on a pipe under `set -o pipefail` — grep exits
    # early on match and the upstream echo may get SIGPIPE if the buffer
    # overflows, causing pipefail to report the whole pipeline as failed.
    # Capturing stdout sidesteps this entirely.
    if [ -n "$_writes" ]; then
      # F1: detect subagent-dispatch signal BEFORE filtering (marker is in raw _writes).
      _sdm=$(printf '%s\n' "$_writes" | grep -E '^\[subagent-dispatch\]$' | head -1 || true)
      [ -n "$_sdm" ] && HAS_SUBAGENT_DISPATCH=1
      _match=$(printf '%s\n' "$ALL_CHANGED_PATHS" | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
      if [ -n "$_match" ]; then
        CODE_CHANGED=1
      fi
    fi
  fi
fi

# Code-change detection splits into two attribution classes (2026-05-28 review fix
# for the Bash-write blindness, bypass/WG-2 + handoff/B4-2 + plan-n/WG-2):
#
#   • Session-ATTRIBUTABLE, commit-based signals (#2 head-baseline commits, #4
#     session-locked worktree commits ahead of main). Both are keyed to THIS
#     session's SID/baseline, so they are safe under parallel sessions and run
#     UNCONDITIONALLY (even when a writes log exists). This closes the hole where
#     code is written via the Bash tool (cat >, sed -i, git apply, tee, codegen,
#     cp) — invisible to track-session-writes.sh, which records only
#     Edit|Write|MultiEdit|NotebookEdit — and then committed. Previously, the mere
#     presence of a writes log short-circuited ALL git detection, so Bash-written
#     code set CODE_CHANGED=0 and the entire gauntlet/witness/IMPACT/QA machinery
#     never activated.
#
#   • NOT session-attributable, shared-working-tree signals (#1 uncommitted, #3
#     branch-vs-main). A shared main checkout shows every parallel session's
#     uncommitted work AND any PRE-EXISTING dirt, so attributing it to THIS session
#     would false-block siblings and (now that this hook fires interactively) any
#     conversational turn in a dirty repo. These run ONLY in the legacy no-writes-log
#     path AND ONLY when /v actually ran this session (IS_V_INVOCATION_VIA_HISTORY=1)
#     — so tree dirt with no /v evidence and no session-attributed writes is NOT
#     treated as this session's code. Uncommitted Bash-written code is instead caught
#     at commit time by uncommitted-changes-gate.sh / the precommit gate, and once
#     committed by the session-attributable #2/#4 signals below.
#
#   • W-FALSEDIRT (2026-07-14): the /v-evidence guard above is necessary but NOT
#     sufficient. Invoking /v does not make PRE-EXISTING dirt yours. Signal #1 is now
#     additionally filtered by mtime against the SessionStart marker, so a session that
#     wrote no repo code cannot inherit an already-dirty tree. See _cra_session_start_epoch.

# W-FALSEDIRT helpers. session-start-marker.sh writes $V_TMP_DIR/session-start-<sid>.txt
# (ISO-8601 UTC) for EVERY session — including ones that never invoke /v — so a start
# epoch is available wherever the legacy fallback runs. Echo empty on any failure; every
# caller treats empty as "cannot date ⇒ fail closed".
_cra_session_start_epoch() {
  local sid="${1:-}" d marker="" iso="" ep=""
  [ -n "$sid" ] || return 0
  for d in "${V_TMP_DIR_RESOLVED:-}" "${REPO_ROOT:-}/.v/tmp" "${TMPDIR:-}" "/tmp"; do
    [ -n "$d" ] || continue
    d="${d%/}"
    if [ -f "$d/session-start-${sid}.txt" ]; then marker="$d/session-start-${sid}.txt"; break; fi
  done
  [ -n "$marker" ] || return 0
  iso=$(head -1 "$marker" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$iso" ] || return 0
  ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null || true)   # BSD/macOS
  [ -n "$ep" ] || ep=$(date -u -d "$iso" +%s 2>/dev/null || true)               # GNU/Linux
  printf '%s' "$ep"
}

_cra_mtime_epoch() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true
}

# Filter repo-relative paths on stdin to those whose mtime is >= $1 (session start epoch).
# Fails CLOSED: any path that cannot be dated (deleted, renamed, stat unavailable, or a
# non-numeric mtime) is KEPT, so an unknown never silently drops out of enforcement.
_cra_filter_session_recent() {
  local start="${1:-}" p mt abs
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    abs="$p"
    [ -e "$abs" ] || abs="${REPO_ROOT:-.}/$p"
    if [ ! -e "$abs" ]; then printf '%s\n' "$p"; continue; fi
    mt=$(_cra_mtime_epoch "$abs")
    case "${mt:-}" in (''|*[!0-9]*) printf '%s\n' "$p"; continue;; esac
    if [ "$mt" -ge "$start" ]; then printf '%s\n' "$p"; fi
  done
}

if [ "$WRITES_LOG_AVAILABLE" -eq 0 ] && [ "$IS_V_INVOCATION_VIA_HISTORY" -eq 1 ]; then
  # 1) Uncommitted changes (unstaged + staged + untracked)
  _CRA_DIRTY_ALL=$(printf '%s\n%s\n%s\n' \
    "$(git diff --name-only HEAD 2>/dev/null || true)" \
    "$(git diff --cached --name-only 2>/dev/null || true)" \
    "$(git ls-files --others --exclude-standard 2>/dev/null || true)" | awk 'NF' | sort -u)

  # W-FALSEDIRT (forensic 2026-07-14): this fallback used to attribute
  # the ENTIRE dirty tree to the session whenever /v appeared in history. A session that
  # wrote no repo code (hence no writes log) but invoked a /v-* skill inherited unrelated
  # sessions' uncommitted work. One session answered a read-only question, wrote only
  # ~/.claude memory files and never moved HEAD, yet 14 files staged ~13h earlier by the
  # previous night's pack run set CODE_CHANGED=1. With a HANDOFF present that escalated
  # into the Bug 6 / Phase 2 "SHIPPED code" refusal — whose three prescribed remedies were
  # ALL unavailable: no head-baseline existed to reset to (option b would have been an
  # unguided rewind across 102 unpushed commits), the gauntlet would have attested 264
  # foreign files (option a), and TRIVIAL_PASS would assert a change never made (option c).
  # Dirt older than session start CANNOT be this session's work, so drop it. Code the
  # session wrote via Bash (mtime >= start) is still caught, so this narrows a false-block
  # without widening a pass. Fails CLOSED: no marker / unparsable stamp / undatable path
  # ⇒ prior behaviour (attribute the dirt).
  _CRA_START_EPOCH=$(_cra_session_start_epoch "${SESSION_ID:-}")
  case "${_CRA_START_EPOCH:-}" in (''|*[!0-9]*) _CRA_START_EPOCH="";; esac
  if [ -n "$_CRA_START_EPOCH" ] && [ -n "$_CRA_DIRTY_ALL" ]; then
    _CRA_DIRTY_MINE=$(printf '%s\n' "$_CRA_DIRTY_ALL" | _cra_filter_session_recent "$_CRA_START_EPOCH" || true)
    _CRA_N_ALL=$(printf '%s\n' "$_CRA_DIRTY_ALL" | awk 'NF' | wc -l | tr -d ' ')
    _CRA_N_MINE=$(printf '%s\n' "${_CRA_DIRTY_MINE:-}" | awk 'NF' | wc -l | tr -d ' ')
    if [ "${_CRA_N_MINE:-0}" -lt "${_CRA_N_ALL:-0}" ]; then
      echo "[check-review-artifact] W-FALSEDIRT: ignoring $((_CRA_N_ALL - _CRA_N_MINE)) pre-existing dirty path(s) with mtime older than session start (session ${SESSION_ID:-?}); ${_CRA_N_MINE} path(s) attributable to this session." >&2
    fi
  else
    _CRA_DIRTY_MINE="$_CRA_DIRTY_ALL"
  fi

  ALL_CHANGED_PATHS=$(printf '%s\n' "${_CRA_DIRTY_MINE:-}" | awk 'NF' | sort -u)
  # Union already covers unstaged+staged+untracked, so one code probe replaces the
  # former CHANGED_CODE/STAGED_CODE/UNTRACKED_CODE triple (all three were local to
  # this block and only ever OR-ed together).
  CHANGED_CODE=$(printf '%s\n' "$ALL_CHANGED_PATHS" | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
  if [ -n "${CHANGED_CODE}" ]; then
    CODE_CHANGED=1
  fi

  # 3) Committed changes vs main (fallback when baseline unavailable)
  if [ "$CODE_CHANGED" -eq 0 ] && [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$MAIN_BRANCH" ]; then
    MERGE_BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || echo "")
    if [ -n "$MERGE_BASE" ]; then
      ALL_CHANGED_PATHS=$(printf '%s\n%s\n' "$ALL_CHANGED_PATHS" "$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null || true)" | awk 'NF' | sort -u)
      COMMITTED_CODE=$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
      if [ -n "$COMMITTED_CODE" ]; then
        CODE_CHANGED=1
      fi
    fi
  fi
fi

# 2) Committed changes since SessionStart baseline — session-attributable, runs
#    UNCONDITIONALLY (see attribution-class note above).
if [ "$CODE_CHANGED" -eq 0 ] && [ -n "$SESSION_ID" ]; then
  # HOOK-6 (W18 alignment): head-baseline now lives in $REPO_ROOT/.v/tmp/
  # to match the Wave 18 V_TMP_DIR migration. Falls back to legacy /tmp path
  # for sessions started before the migration.
  # 2026-05-28 (handoff/B4-3): honor $V_TMP_DIR / $TMPDIR like the writer
  # (track-session-writes.sh / session-env-check.sh use v_tmp_dir()), else the
  # committed-code signal is silently dropped on macOS where TMPDIR != /tmp.
  HEAD_BASELINE_FILE="$V_TMP_DIR_RESOLVED/head-baseline-${SESSION_ID}.txt"
  if [ ! -f "$HEAD_BASELINE_FILE" ] && [ -f "$REPO_ROOT/.v/tmp/head-baseline-${SESSION_ID}.txt" ]; then
    HEAD_BASELINE_FILE="$REPO_ROOT/.v/tmp/head-baseline-${SESSION_ID}.txt"
  fi
  if [ ! -f "$HEAD_BASELINE_FILE" ] && [ -n "${TMPDIR:-}" ] && [ -f "${TMPDIR%/}/head-baseline-${SESSION_ID}.txt" ]; then
    HEAD_BASELINE_FILE="${TMPDIR%/}/head-baseline-${SESSION_ID}.txt"
  fi
  if [ ! -f "$HEAD_BASELINE_FILE" ] && [ -f "/tmp/head-baseline-${SESSION_ID}.txt" ]; then
    HEAD_BASELINE_FILE="/tmp/head-baseline-${SESSION_ID}.txt"
  fi
  if [ -f "$HEAD_BASELINE_FILE" ]; then
    START_HEAD=$(head -1 "$HEAD_BASELINE_FILE" 2>/dev/null || true)
    CURRENT_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
    if [ -n "$START_HEAD" ] && [ -n "$CURRENT_HEAD" ] && [ "$START_HEAD" != "$CURRENT_HEAD" ]; then
      ALL_CHANGED_PATHS=$(printf '%s\n%s\n' "$ALL_CHANGED_PATHS" "$(git diff --name-only "${START_HEAD}..${CURRENT_HEAD}" 2>/dev/null || true)" | awk 'NF' | sort -u)
      BASELINE_COMMITTED_CODE=$(git diff --name-only "${START_HEAD}..${CURRENT_HEAD}" 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
      if [ -n "$BASELINE_COMMITTED_CODE" ]; then
        CODE_CHANGED=1
      fi
    fi
  fi
fi

# 4) Session-owned worktree commits ahead of main — session-attributable (SID-locked
#    via .claude-session-lock), runs UNCONDITIONALLY (search both roots).
if [ "$CODE_CHANGED" -eq 0 ] && [ -n "$SESSION_ID" ]; then
  for ROOT in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$ROOT" ] && continue
    # W5F-1: the in-repo layout nests worktrees one level deeper (.worktrees/build/<name>) —
    # the original single-level glob silently missed them. Search both depths.
    for LOCK in "$ROOT"/.worktrees/*/.claude-session-lock "$ROOT"/.worktrees/*/*/.claude-session-lock; do
      [ -f "$LOCK" ] || continue
      LOCK_SID=$(awk '{print $1}' "$LOCK" 2>/dev/null || echo "")
      if [ "$LOCK_SID" = "$SESSION_ID" ]; then
        WT_DIR=$(dirname "$LOCK")
        WT_BRANCH=$(git -C "$WT_DIR" branch --show-current 2>/dev/null || echo "")
        if [ -n "$WT_BRANCH" ]; then
          AHEAD=$(git log "${MAIN_BRANCH}..${WT_BRANCH}" --oneline 2>/dev/null | wc -l | tr -d ' ')
          if [ "$AHEAD" -gt 0 ]; then
            CODE_CHANGED=1
          fi
        fi
        break 2
      fi
    done
  done
fi

# 4b) W5F-1: session-owned EXTERNAL worktree (resolved via git worktree list above).
#     Runs UNCONDITIONALLY (not only when CODE_CHANGED=0): SESSION_WT_AHEAD feeds the
#     W5F-3 stranded-merge gate below even when code change was already detected.
#     This is the signal the wave-1 forensics showed missing: one session committed 9
#     finding-commits to a build/pack branch (an external worktree, absolute-path edits
#     invisible to track-session-writes.sh), never merged, and ended with a HANDOFF
#     claiming "No code changes in this session" — every prior signal was blind to it.
if [ -n "$SESSION_WT_BRANCH" ]; then
  SESSION_WT_AHEAD=$(git log "${MAIN_BRANCH}..${SESSION_WT_BRANCH}" --oneline 2>/dev/null | wc -l | tr -d ' ')
  SESSION_WT_AHEAD=${SESSION_WT_AHEAD:-0}
  if [ "$SESSION_WT_AHEAD" -gt 0 ]; then
    _wt_mb=$(git merge-base "$MAIN_BRANCH" "$SESSION_WT_BRANCH" 2>/dev/null || true)
    _wt_changed=""
    [ -n "$_wt_mb" ] && _wt_changed=$(git diff --name-only "${_wt_mb}..${SESSION_WT_BRANCH}" 2>/dev/null || true)
    if [ -n "$_wt_changed" ]; then
      ALL_CHANGED_PATHS=$(printf '%s\n%s\n' "$ALL_CHANGED_PATHS" "$_wt_changed" | awk 'NF' | sort -u)
      _wt_code=$(printf '%s\n' "$_wt_changed" | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)
      [ -n "$_wt_code" ] && CODE_CHANGED=1
    fi
  fi
fi

# W-P3-13 (staged-bytes-aware stranding, plan item 13): SESSION_WT_AHEAD only sees COMMITTED
# work — a session that staged its whole fix in the worktree and never committed (a real,
# repeated shape: runner-owned packs and interrupted sessions leave `git diff --cached` non-empty
# with SESSION_WT_AHEAD=0) sails through W5F-3/FND-3 with nothing to show it ever happened. This
# computes staged-byte evidence in the session-owned worktree (only possible while the worktree
# still exists — a gone worktree with no commits has already lost the work, a separate class) and
# feeds it into the SAME gates as SESSION_WT_AHEAD below, so a staged-only worktree is treated as
# equivalent stranding evidence, not silence.
if [ -n "$SESSION_WT" ] && [ -d "$SESSION_WT" ]; then
  SESSION_WT_STAGED_BYTES=$(git -C "$SESSION_WT" diff --cached --stat 2>/dev/null | wc -c | tr -d ' ')
  SESSION_WT_STAGED_BYTES=${SESSION_WT_STAGED_BYTES:-0}
fi

# REPO-STATE GUARD (forensic 2026-06-23): a /v gate verdict issued while the
# repo is FROZEN MID-OPERATION (interrupted rebase/merge/cherry-pick/revert — e.g. /v-merge-all paused on a
# conflict) is structurally a FALSE-GREEN: the verifier is grading a partially-applied tree it has no authority
# over and cannot know what HEAD will become once the operation finishes. Two /v verification sessions stamped
# "all packs ship clean / ROI >= 8.0 PASS" against exactly such a mid-rebase tree (right by luck, not evidence)
# and left the corruption for "the next session." A /v or code-changing session must not COMPLETE on a
# mid-operation repo — surface it as a hard block so the operation is resolved/aborted and HEAD is authoritative
# first. Scoped to /v OR code-changing sessions so a non-/v conversational turn during the user's own manual
# rebase is unaffected. Placed AFTER CODE_CHANGED + BEFORE the CODE_CHANGED==0 completion-language early-exit so
# it catches a verification (/v, no-code) session too.
if [ "${IS_V_INVOCATION_VIA_HISTORY:-0}" = "1" ] || [ "${CODE_CHANGED:-0}" -eq 1 ]; then
  _cra_gitdir=$(git rev-parse --git-dir 2>/dev/null || echo "")
  _cra_repo_op=""
  if [ -n "$_cra_gitdir" ]; then
    if [ -d "$_cra_gitdir/rebase-merge" ] || [ -d "$_cra_gitdir/rebase-apply" ]; then _cra_repo_op="rebase"
    elif [ -f "$_cra_gitdir/MERGE_HEAD" ]; then _cra_repo_op="merge"
    elif [ -f "$_cra_gitdir/CHERRY_PICK_HEAD" ]; then _cra_repo_op="cherry-pick"
    elif [ -f "$_cra_gitdir/REVERT_HEAD" ]; then _cra_repo_op="revert"
    fi
  fi
  if [ -n "$_cra_repo_op" ]; then
    _cra_repostate_msg="COMPLETION BLOCKED (repo mid-operation): a git ${_cra_repo_op} is IN PROGRESS in this repository (${_cra_gitdir}). A /v session must NOT complete — and a /v gate (pre-flight, verify-done, merge-back, re-score) must NOT issue a PASS — while the repo is frozen mid-${_cra_repo_op}: the working tree is a partially-applied, non-authoritative state, so any gate result is a FALSE-GREEN that does not reflect what HEAD will be once the ${_cra_repo_op} finishes (forensic: two /v verification sessions stamped 'all packs ship clean / ROI >= 8.0 PASS' against a tree frozen mid-rebase — right by luck, not evidence — and never resolved it). ACTION REQUIRED: finish or abort the ${_cra_repo_op} (git ${_cra_repo_op} --continue / --abort, or git rebase --abort) so HEAD is authoritative, THEN re-run the /v work and its gates. Do NOT report PASS or stamp any gate against the mid-${_cra_repo_op} tree."
    if _cra_block_gate "$_cra_repostate_msg"; then
      printf '%s\n' "$_cra_repostate_msg" >&2
      exit 2
    fi
    exit 0  # rearm deadlock escape (warning already on stderr)
  fi
fi

# Resolve the final assistant message once — reused by the W71 truth gate (placed after
# the WARNINGS init below) and the completion-language gate just below.
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)

# === ABANDON-ENRICH classifier (2026-07-02, SME-panel plan v3) ===
# Detects the two prose-only /v failure classes (Final Guard no-task conclusions, W25-F11
# role-confusion) so Part A/B below can (a) enrich their block message with the user's
# ACTUAL captured task and (b) catch the no-completion-language abandonment that previously
# slipped the early-exit below (both 2026-07-01 canaries did). Fail-open everywhere.
# Dial: ${V_ABANDON_GATE:-warn}. DELIBERATE warn default (production soak per SME-A-3) —
# do NOT copy the :-block idiom from V_BITE_GATE here until the soak shows 0 false fires.
_AB_GATE_MODE="${V_ABANDON_GATE:-warn}"
_ab_class=""; _ab_capture=""; _ab_capture_src=""
if [ "$_AB_GATE_MODE" != "off" ]; then
  _ab_lastmsg="$LAST_MSG"
  if [ -z "$_ab_lastmsg" ]; then
    # SME-L-5: lightweight transcript-tail fallback (the full TX_SIGNALS buffer at Layer-4 is
    # code-changed-gated and never built for these sessions — do NOT depend on it, SME-L2-2).
    _ab_tx=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
    if [ -n "$_ab_tx" ] && [ -f "$_ab_tx" ]; then
      _ab_lastmsg=$(tail -c 200000 "$_ab_tx" 2>/dev/null | jq -rs '[.[]? | select(.type=="assistant")] | last | .message.content[]? | select(.type=="text") | .text' 2>/dev/null | tail -c 4000)
    fi
  fi
  if printf '%s' "$_ab_lastmsg" | grep -qiE 'no actionable task|no task (content|to execute)|prompt is empty|did not provide a task|only system reminders|no real task|did not find any actual task|cannot find (the |your |a )?task'; then
    _ab_class="no-task"
  elif printf '%s' "$_ab_lastmsg" | grep -qiE 'I am (a|the) ((research|task) )?sub-?agent|exceeds .{0,40}sub-?agent scope|hand(ing)? (this |it )?back to the parent|parent agent (should|must|can) re-invoke|report(ing)? (this |it )?back to the parent'; then
    _ab_class="role-confusion"
  fi
  if [ -n "$_ab_class" ] && [ -n "$SESSION_ID" ]; then
    # Capture resolution — CACHED once per session (SME-L2-1: a re-resolved capture can churn
    # between re-arms and defeat the same-fingerprint deadlock escape; SME-L2-3: Change-2 must
    # consume the SAME stale-nulled value). Priority per SME-A-2: last-skill-args FIRST.
    _ab_cache="$V_TMP_DIR_RESOLVED/abandon-capture-${SESSION_ID}.txt"
    if [ -f "$_ab_cache" ]; then
      _ab_capture=$(cat "$_ab_cache" 2>/dev/null)
      _ab_capture_src=$(head -1 "$_ab_cache.src" 2>/dev/null)
    else
      _ab_ss_marker="$V_TMP_DIR_RESOLVED/session-start-${SESSION_ID}.txt"
      for _ab_f in "$HOME/.claude/runtime/last-skill-args-${SESSION_ID}.txt" \
                   "$HOME/.claude/runtime/v-resolved-task-${SESSION_ID}.txt" \
                   "$HOME/.claude/runtime/last-user-prompt-${SESSION_ID}.txt"; do
        [ -f "$_ab_f" ] || continue
        # Stale guard (SME-L-1/L2-3): a capture older than THIS session's start marker is a
        # prior-conversation leftover — treat as absent (nulls both the quote AND the gate value).
        if [ -f "$_ab_ss_marker" ] && [ "$_ab_f" -ot "$_ab_ss_marker" ]; then continue; fi
        _ab_raw=$(tr -d '\000-\010\013-\037' < "$_ab_f" 2>/dev/null | sed -E 's/\[(Image|Pasted text) #[0-9]+( \+[0-9]+ lines)?\]//g; s/^\/v[[:space:]]+//' | tr '\n\140' '  ' | sed -E 's/[[:space:]]+/ /g' | head -c 200)
        _ab_nonws=$(printf '%s' "$_ab_raw" | tr -d '[:space:]' | wc -c | tr -d ' ')
        if [ "${_ab_nonws:-0}" -ge 10 ]; then
          _ab_capture="$_ab_raw"; _ab_capture_src="$_ab_f"
          { mkdir -p "$(dirname "$_ab_cache")" && printf '%s' "$_ab_capture" > "$_ab_cache" && printf '%s\n' "$_ab_capture_src" > "$_ab_cache.src"; } 2>/dev/null || true
          break
        fi
      done
    fi
  fi
fi
_ab_note() {  # append durable trace to the EXISTING ledger (SME-A-D3: one ledger, not a fork)
  [ -n "$SESSION_ID" ] || return 0
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SESSION_ID" --arg class "$_ab_class" \
     --arg mode "$1" --arg src "$_ab_capture_src" '{"ts":$ts,"sid":$sid,"event":"abandon-enrich","class":$class,"mode":$mode,"capture_src":$src}' \
     >> "$HOME/.claude/abandonments.jsonl" 2>/dev/null || true
}
_ab_write_suspect_marker() {
  [ -n "${REPO_ROOT:-}" ] && [ -n "$SESSION_ID" ] || return 0
  {
    printf '# /v ABANDON SUSPECT — %s\n\n' "$SESSION_ID"
    printf 'class: %s\nmode: %s\ncapture: %s\n\n' "$_ab_class" "$1" "$_ab_capture_src"
    printf 'The final message matched the %s abandonment class while the SID-scoped capture holds a task:\n> %s\n\n' "$_ab_class" "$_ab_capture"
    printf 'Route the task via /v Step 1, ask ONE clarifying AskUserQuestion, or write HANDOFF_%s.md that QUOTES the task above. Auto-removed when the gauntlet completes.\n' "$SESSION_ID"
  } > "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
}
# === ABANDON-ENRICH classifier end ===

# Completion-language gate when no code changes detected (AVF-029: extended pattern)
if [ "$CODE_CHANGED" -eq 0 ]; then
  # READ-ONLY VERIFICATION exit (2026-07-07): the runner dispatched this session as a read-only verification
  # pack (it wrote $REPO/.v/tmp/pack-readonly-<sid>.marker) AND the hook independently computed CODE_CHANGED=0
  # (from the writes-ledger + committed diff + worktree commits) — there is nothing to review, so end cleanly
  # regardless of completion language. This closes the read-only-verification hole (a read-only /v verification graded work
  # PASS then completed with no marker → fell through to the gauntlet demand, forcing fabricated gates). It is
  # the enforcement mirror of v-completion-selfcheck.sh's read-only bypass. UNSPOOFABLE by a code session:
  # this branch is gated on CODE_CHANGED=0, which a session that actually changed source can never satisfy.
  if [ -n "${SESSION_ID:-}" ] && [ -f "$V_TMP_DIR_RESOLVED/pack-readonly-${SESSION_ID}.marker" ]; then
    exit 0
  fi
  # Use shared pattern if validation.sh was loaded, else fall back to built-in
  _cw_pattern="${COMPLETION_WORDS_PATTERN:-complet|done([^a-z]|$)|finish|implement|fix(ed|ing)|resolv|ship|ready|working|merged|applied|created|updated|all[[:space:]]+(changes|files|tasks)|accomplish|deliver|deploy|land|wrap|merge|finalize}"
  if ! echo "$LAST_MSG" | grep -qiE "$_cw_pattern"; then
    # ABANDON-ENRICH: a no-task/role-confusion ending with a REAL captured task must not slip
    # out on the no-completion-language path (both 2026-07-01 canaries exited here silently).
    if [ -n "$_ab_class" ] && [ -n "$_ab_capture" ]; then
      if [ "$_AB_GATE_MODE" = "block" ]; then
        : # fall through — Part B below blocks with the enriched message
      else
        _ab_note "warn-earlyexit"; _ab_write_suspect_marker "warn"
        echo "ABANDON-ENRICH warn: final message matched '${_ab_class}' but a task exists in ${_ab_capture_src} (soak mode — V_ABANDON_GATE=block would block here)" >&2
        exit 0
      fi
    else
      exit 0
    fi
  fi
fi


# === ABANDONMENT-DETECT (Part A): detect /v invocation + HANDOFF bypass ===
# IS_V_INVOCATION_VIA_HISTORY was already computed near the top (it gates the git
# fallback). The HANDOFF abandonment-escape logic below reuses it.

# Look for a valid HANDOFF_<sid>.md (>= 80 bytes, "# Handoff" heading).
_handoff_satisfies=0
if [ -n "$SESSION_ID" ]; then
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _handoff_file="$_dir/HANDOFF_${SESSION_ID}.md"
    if [ -f "$_handoff_file" ]; then
      _h_size=$(wc -c < "$_handoff_file" 2>/dev/null | tr -d ' ')
      if [ "${_h_size:-0}" -ge 80 ] && grep -qiE '^#+[[:space:]]*Handoff\b' "$_handoff_file" 2>/dev/null; then
        _handoff_satisfies=1
        break
      fi
    fi
  done
fi

# HANDOFF-bypass: if /v ran and HANDOFF exists and NO other completion artifact
# exists, accept HANDOFF as the abandonment-escape and exit 0.
#
# Bug 6 / Phase 2 (2026-05-28): tightened so the HANDOFF cannot rescue a session
# that ALREADY SHIPPED CODE. Observed misuse (one production session): model completed
# the work, merged to main, then wrote a HANDOFF (~150B) and called /v-session-log.
# The /v-session-log resolver classified it as "Abandonment" (correct!) and wrote
# all NOT_APPLICABLE gates, but the HANDOFF escape here let the conversation end
# without the gauntlet. The model used the abandonment escape — designed for "I
# couldn't finish" — as a graceful-exit for completed-and-merged work.
#
# Fix: before accepting HANDOFF as escape, check if this session's writes log
# contains code changes. If yes, the session shipped code → require the full
# gauntlet (PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE), not a HANDOFF. Falls through
# to LAYER-2 abandonment-with-code below, which BLOCKS with a clear message.
if [ "$IS_V_INVOCATION_VIA_HISTORY" -eq 1 ] && [ "$_handoff_satisfies" -eq 1 ]; then
  _has_other_completion=0
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _prefix in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT IMPLEMENTATION_REPORT TRIVIAL_PASS PLANNING_PASS; do
      if [ -f "$_dir/${_prefix}_${SESSION_ID}.md" ]; then
        _has_other_completion=1
        break 2
      fi
    done
  done

  # 2026-05-28 (handoff/B4-2, handoff/B4-3): CODE_CHANGED is already fully computed
  # above, now including the session-attributable committed-code signals (#2
  # head-baseline, #4 worktree-lock) that run unconditionally — so code written via
  # the Bash tool and then committed is detected even though track-session-writes.sh
  # never logged it, and the head-baseline lookup honors $V_TMP_DIR/$TMPDIR rather
  # than a /tmp-only path. Reuse it directly instead of the prior weaker writes-log-
  # only re-derivation (which was blind to Bash writes and used a /tmp-only baseline).
  _handoff_shipped_code="$CODE_CHANGED"

  if [ "$_has_other_completion" -eq 0 ] && [ "$_handoff_shipped_code" -eq 0 ]; then
    # ABANDON-ENRICH Change 2 (SME-A-1 HANDOFF-laundering): a HANDOFF written to escape while
    # the final message claims no-task/role-confusion AND the capture holds a task must
    # REFERENCE that task — otherwise it launders the abandonment. Block happens AT THIS SITE
    # (SME-A-D1: Part B is structurally disarmed once HANDOFF exists — fall-through is impossible).
    if [ -n "$_ab_class" ] && [ -n "$_ab_capture" ] && [ "$_AB_GATE_MODE" != "off" ] \
       && ! grep -qF "$(printf '%s' "$_ab_capture" | head -c 40)" "$_handoff_file" 2>/dev/null; then
      if [ "$_AB_GATE_MODE" = "block" ]; then
        _ab_launder_msg="COMPLETION BLOCKED (abandon-enrich): the final message matched the '${_ab_class}' abandonment class, HANDOFF_${SESSION_ID}.md does NOT reference the user's actual task, and the SID-scoped capture at ${_ab_capture_src} holds one: \"${_ab_capture}\". Resolve by ONE of: (a) route that task through /v Step 1 now, (b) ask ONE clarifying AskUserQuestion, (c) rewrite the HANDOFF to QUOTE the task above and explain why it could not be executed."
        if _cra_block_gate "$_ab_launder_msg"; then
          _ab_note "block-launder"
          { jq -n --arg msg "$_ab_launder_msg" '{"decision":"block","reason":$msg}' 2>/dev/null; echo "$_ab_launder_msg" >&2; }  # REASON-LOSS fix 2026-07-04: stderr ALWAYS carries the reason (exit-2 surfaces stderr, not stdout)
          exit 2
        fi
        _ab_note "escape-launder"; _ab_write_suspect_marker "escape"
        exit 0  # W5G-1 deadlock escape
      fi
      _ab_note "warn-launder"; _ab_write_suspect_marker "warn"
      echo "ABANDON-ENRICH warn: HANDOFF accepted but it does not reference the captured task at ${_ab_capture_src} (class=${_ab_class}; soak mode)" >&2
    fi
    # Genuine abandonment — no code shipped, HANDOFF documents the deferral.
    jq -n --arg msg "Abandonment recorded: HANDOFF_${SESSION_ID}.md accepted as abandonment-escape (handoff §4a telemetry)" '{"systemMessage":$msg}' 2>/dev/null || true
    exit 0
  elif [ "$_has_other_completion" -eq 0 ] && [ "$_handoff_shipped_code" -eq 1 ]; then
    # Bug 6 / Phase 2 — refuse HANDOFF escape for completed-and-shipped work.
    # The session wrote code AND wrote a HANDOFF — but a HANDOFF is for "I
    # didn't finish, here's where I left off," not "I finished + merged + want
    # to skip the gauntlet." LAYER-2 won't fire (IS_V_SESSION will be 1 because
    # HANDOFF exists), so block explicitly here.
    # W5F-2 (forensic 2026-06-06): name the worktree contradiction explicitly when it is the
    # evidence — two sessions wrote HANDOFFs claiming "no implementation work was
    # performed" / "No code changes in this session" while their SID-locked worktree branches
    # held the session's commits. The false declaration is what let the work strand silently.
    _bug6_wt_detail=""
    if [ -n "$SESSION_WT_BRANCH" ] && [ "${SESSION_WT_AHEAD:-0}" -gt 0 ]; then
      _bug6_wt_detail=" CONTRADICTION EVIDENCE: this session's SID-locked worktree branch '${SESSION_WT_BRANCH}' has ${SESSION_WT_AHEAD} commit(s) not in ${MAIN_BRANCH} (worktree: ${SESSION_WT}). If the HANDOFF claims 'no code changes', it is FALSE — fix the HANDOFF text to name the branch and its commits. A MERGE_DEFERRED declaration does NOT replace the gauntlet: run it (option a), then merge back via 'bash ~/.claude/skills/v/references/v-merge-back.sh ${SESSION_ID}' or add 'MERGE_DEFERRED: ${SESSION_WT_BRANCH}' to the HANDOFF if the merge is intentionally deferred."
    fi
    _bug6_b4_msg="COMPLETION BLOCKED (Bug 6 / Phase 2): HANDOFF_${SESSION_ID}.md exists, but this session SHIPPED code (writes log or commits since SessionStart contain source-file changes).${_bug6_wt_detail} The HANDOFF abandonment-escape is for sessions that did NOT complete their work — it cannot be used to skip the gauntlet on completed-and-merged work. Observed misuse: a session wrote ~25 lines across 3 files, merged to main, then wrote a HANDOFF to avoid /v-pre-flight + agent review + /v-verify-done. Resolve by one of: (a) RUN the full gauntlet — /v-pre-flight, dispatch agent review, /v-verify-done — and produce PRE_FLIGHT_REPORT/AGENT_REVIEW/VERIFY_DONE_REPORT_${SESSION_ID}.md, (b) if the work is genuinely incomplete and HANDOFF is correct, REVERT the merged commits (git reset to head-baseline) so the HANDOFF accurately documents work-in-progress, (c) if the work is trivial enough for the TRIVIAL_PASS bypass, classify via ~/.claude/skills/v/references/v-classify-trivial.sh + write TRIVIAL_PASS_${SESSION_ID}.md."
    if _cra_block_gate "$_bug6_b4_msg"; then
      printf '%s\n' "$_bug6_b4_msg" >&2
      exit 2
    fi
    exit 0  # W5G-1 deadlock escape (warning already on stderr)
  fi
fi
# === ABANDONMENT-DETECT (Part A) end ===

IS_V_SESSION=0
if [ -n "$SESSION_ID" ]; then
  # DEF-2 (forensic 2026-06-24): require a RECOGNIZED gauntlet/completion artifact — NOT any
  # *<sid>*.md. The bare glob let a self-authored UNRECOGNIZED report (an R20_VERIFY_REPORT_<sid>.md)
  # set IS_V_SESSION=1, which DISARMED the Part-B abandonment block (gated IS_V_SESSION==0): a read-only /v
  # verification that graded work PASS then completed with NO session log + NO marker (a silent hole). A real
  # working session still promotes IS_V_SESSION=1 below via CODE_CHANGED (the writes-log) or subagent-dispatch.
  # NB (SREV-004): WORKTREE_HANDOFF / BLOCKED / GAUNTLET_SKIPPED are intentionally NOT in this list — they are
  # written at/after the gauntlet (recognized artifacts already exist) or by the hook itself; a session whose
  # ONLY artifact is one of those + no code change SHOULD fall to the Part-B abandonment block. Adding them
  # would re-open that hole (a self-authored marker laundering a no-work session into "satisfied").
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _vp in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT IMPACT_MAP QA_REPORT UX_CRITIQUE \
               WORKFLOW_VERIFICATION IMPLEMENTATION_REPORT TRIVIAL_PASS PLANNING_PASS HANDOFF \
               CYCLE_CAP_HANDOFF; do
      if [ -f "${_dir}/${_vp}_${SESSION_ID}.md" ]; then
        IS_V_SESSION=1
        break 2
      fi
    done
  done
fi

# === LAYER-2: activity-aware abandonment diagnosis ===
# Capture pre-promotion state for the abandonment-with-code path.
# The model cannot fake the writes log — track-session-writes.sh is a PreToolUse hook
# that runs OUTSIDE the model's control.
_L2_IS_V_SESSION_PRE="$IS_V_SESSION"
_L2_WRITES_HAS_CODE=0
_L2_WRITES_COUNT=0
_L2_WRITES_FILE=""
if [ -n "$SESSION_ID" ]; then
  if type session_writes_log_path >/dev/null 2>&1; then
    _L2_WRITES_FILE="$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)"
  fi
  if [ -z "$_L2_WRITES_FILE" ] || [ ! -f "$_L2_WRITES_FILE" ]; then
    _L2_WRITES_FILE="$(git rev-parse --git-common-dir 2>/dev/null)/claude-session-writes-${SESSION_ID}.txt"
  fi
  if [ -f "$_L2_WRITES_FILE" ]; then
    _L2_WRITES_COUNT=$(wc -l < "$_L2_WRITES_FILE" 2>/dev/null | tr -d ' ')
    if grep -E "$CODE_EXT_PATTERN" "$_L2_WRITES_FILE" 2>/dev/null | grep -vqE "$CODE_EXT_EXEMPT"; then
      _L2_WRITES_HAS_CODE=1
    fi
  fi
fi
# === LAYER-2 setup end ===

if [ "$IS_V_SESSION" -eq 0 ] && [ "$CODE_CHANGED" -eq 1 ]; then
  IS_V_SESSION=1
fi

# F4-item1 (2026-07-05, "0-turn-parent-skill-fork" reachability): track-session-writes.sh anchors a
# durable GAUNTLET_OWED_<sid>.md the FIRST time THIS sid writes a real code file — a PreToolUse-level
# signal, independent of transcript/turn shape. Before this fix the ONLY thing that ever looked at
# that marker was the out-of-band v-session-log-integrity.sh sweep, gated behind a 6h age floor AND
# requiring someone to actually invoke /v-session-log — a session whose own Stop hook fires but whose
# CODE_CHANGED/IS_V_SESSION heuristics above miss the write (e.g. a writes-log path mismatch between
# a forked skill's cwd and this hook's) would sail through with ZERO enforcement for up to 6 hours.
# An unresolved OWED marker for THIS exact sid is definitive, self-proving evidence the gauntlet is
# owed (track-session-writes.sh only ever writes it on a real qualifying write) — promote immediately
# so THIS Stop event enforces the full Part-B gauntlet check instead of waiting on the separate sweep.
# Harmless when the debt is already resolved: Part B below finds the existing gate artifacts and
# passes through cleanly, same as any legitimately-gated session.
if [ "$IS_V_SESSION" -eq 0 ] && [ -n "$SESSION_ID" ] && [ -f "$REPO_ROOT/.v/artifacts/GAUNTLET_OWED_${SESSION_ID}.md" ]; then
  IS_V_SESSION=1
fi

# F1 (W0-C): subagent-dispatch promotion. An orchestrator session that dispatches
# subagents via v-dispatch-subagent.sh writes NO Edit/Write calls itself, so
# CODE_CHANGED=0 and IS_V_SESSION stays 0 — the stop hook exits clean with zero
# artifacts.  track-session-writes.sh writes a [subagent-dispatch] marker for
# each such Bash call; here we use it to promote IS_V_SESSION=1 so the gauntlet
# witness requirement activates. WRITES_LOG_AVAILABLE must also be 1 (marker file
# must exist) to prevent false promotion on SIDs with no session-writes at all.
#
# CODEX-CRIT-1 (2026-07-05): report-only-contract skills ALSO produce this marker — their
# Step 9 dispatches prompt-pack generation via v-dispatch-subagent.sh (the F16 fork-safe
# mechanism). Promoting them here carries the session PAST Part B, where every report-only
# escape (REPORT-ONLY ESCAPE REGISTRY below) lives, into the MISSING_PREFLIGHT /
# MISSING_REVIEW / MISSING_VERIFY demands a report-only skill can never satisfy — a
# guaranteed false block on every successful run. So: when the session changed NO code and
# history.jsonl (or the STRICT W4B3 pasted-text transcript fallback) proves one of the
# registry's skills ran for THIS SID, skip the promotion and let Part B's history-gated +
# content-validated escapes adjudicate (valid artifact → allow; missing/forged → still
# blocked, with the actionable abandonment message). A generic "/v <task>" session has no
# such history entry and is promoted exactly as before — the laundering posture is
# unchanged (T5 "generic /v + forged doc + dispatch marker" regression case proves it).
# _ro_evidence mirrors the registry's _pb_evidence (defined later, inside Part B — gate-local
# copy so this gate never depends on Part B's block being entered). KEEP THE ERE BELOW IN
# SYNC with the registry's _PB_SKILL rows + audit-family row.
_ro_evidence() {
  local _pat="$1" _hist="$HOME/.claude/history.jsonl" _sidf _ev _haspaste _tx
  _sidf='"sessionId":"'"$SESSION_ID"'"'
  _ev=$( (grep -F "$_sidf" "$_hist" 2>/dev/null || true) \
    | grep -E "\"display\":\"/(${_pat})" 2>/dev/null | head -1 || true )
  if [ -z "$_ev" ]; then
    _haspaste=$( (grep -F "$_sidf" "$_hist" 2>/dev/null || true) \
      | grep -cF '"display":"[Pasted' 2>/dev/null || true )
    if [ "${_haspaste:-0}" -gt 0 ]; then
      _tx=$(ls -1t "$HOME/.claude/projects"/*/"${SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)
      if [ -n "$_tx" ] && [ -f "$_tx" ]; then
        _ev=$( head -30 "$_tx" | grep -F '"type":"user"' \
          | grep -E "\"content\":\"/(${_pat})[ \"-]" 2>/dev/null | head -1 || true )
      fi
    fi
  fi
  printf '%s' "$_ev"
}
# W-FX-ERE (2026-08-03): 'v-forensics' was MISSING here while the Part-B glob row that recognizes
# FORENSICS_REPORT_* was added 2026-08-02 — the recurring "a report-only skill needs BOTH an ERE row
# AND a registry row" class. Without the ERE, _ro_evidence returns empty => _ro_hist stays 0 => the
# WRITES_LOG_AVAILABLE branch below force-sets IS_V_SESSION=1 BEFORE Part-B's `IS_V_SESSION == 0`
# gate is reached, so that escape was structurally unreachable and every /v-forensics run was
# promoted to a full /v session owing the whole gauntlet.
_RO_REPORT_ONLY_ERE='v-skill-reviewer|v-activation-funnel-design|v-pricing-design|v-beta-program|v-illustration-system|v-differentiate|v-legal-docs-generate|v-audit-consolidate|v-anti-template-gauntlet|v-audit-(growth|analytics|messaging|sales-pricing|seo|admin|code)|v-bug-hunt|v-self-audit|v-next|v-prod-triage|v-traffic|v-launch|v-forensics'
_ro_hist=0
if [ "$IS_V_SESSION" -eq 0 ] && [ "$HAS_SUBAGENT_DISPATCH" -eq 1 ] && [ "$CODE_CHANGED" -eq 0 ] \
   && [ -n "$(_ro_evidence "$_RO_REPORT_ONLY_ERE")" ]; then
  _ro_hist=1
fi
if [ "$IS_V_SESSION" -eq 0 ] && [ "$HAS_SUBAGENT_DISPATCH" -eq 1 ] && [ "$WRITES_LOG_AVAILABLE" -eq 1 ] && [ "$_ro_hist" -eq 0 ]; then
  IS_V_SESSION=1
fi

# GAUNTLET_SKIPPED durable marker (forensic 2026-06-17): when a /v gauntlet-skip block is
# DEADLOCK-ESCAPED (the rearm cap is hit because the model can't resolve it — typically /v's workflow never
# loaded, so it doesn't know to run the gates), the bare `exit 0` below leaves ONLY a transient stderr
# warning. An operator who does not run /v-session-log would never learn the workflow was skipped (one session
# declared "complete" with no gauntlet + no durable trace). This writes a DURABLE, repo-root-visible record
# so a skipped /v session is UNMISSABLE (shows in `git status`; `grep -l '^# /v GAUNTLET SKIPPED' GAUNTLET_SKIPPED_*.md`).
# Auto-removed when the gauntlet later completes (the final clean exit rm's it). The block message ALWAYS
# fires first (visible); this marker only persists the ESCAPE case.
_cra_write_skipped_marker() {
  [ -n "${REPO_ROOT:-}" ] && [ -n "${SESSION_ID:-}" ] || return 0
  local _mk="$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md"
  {
    printf '# /v GAUNTLET SKIPPED — %s\n\n' "$SESSION_ID"
    printf 'A /v invocation in this session did real work but the verification gauntlet did NOT run, and the\n'
    printf 'Stop-hook block was deadlock-escaped (the model could not resolve it). This DURABLE marker exists so\n'
    printf 'the skip is visible WITHOUT running /v-session-log.\n\n'
    printf '## Resolve\n'
    printf 'Run the gauntlet for this session: /v-pre-flight, dispatch agent review, /v-verify-done, then\n'
    printf 'commit — OR write HANDOFF_%s.md if intentionally deferred. The Stop hook auto-removes this marker\n' "$SESSION_ID"
    printf 'once the gauntlet completes (AGENT_REVIEW + gates present for this session).\n\n'
    printf '## Detail\n%s\n' "${1:-gauntlet skipped}"
  } > "$_mk" 2>/dev/null || true
}

# === LAYER-2: activity-aware abandonment diagnosis ===
# Fires AFTER the CODE_CHANGED promotion, using PRE-promotion state.
# When /v ran + writes-log has code + no .md artifacts → "did real work, skipped gates".
# Distinguished from generic abandonment (Part B below) by writes-log code evidence.
if [ "$_L2_IS_V_SESSION_PRE" -eq 0 ] && [ "$IS_V_INVOCATION_VIA_HISTORY" -eq 1 ] && [ "$_L2_WRITES_HAS_CODE" -eq 1 ]; then
  _abandonment_msg="COMPLETION BLOCKED: /v was invoked AND this session modified ${_L2_WRITES_COUNT} file(s) including source code (per session writes log at ${_L2_WRITES_FILE}), but no PRE_FLIGHT_REPORT_${SESSION_ID}.md / AGENT_REVIEW_${SESSION_ID}.md / VERIFY_DONE_REPORT_${SESSION_ID}.md / TRIVIAL_PASS_${SESSION_ID}.md / HANDOFF_${SESSION_ID}.md / CYCLE_CAP_HANDOFF_${SESSION_ID}.md exists in ${REPO_ROOT}/.v/artifacts (or the legacy REPO_ROOT fallback). You did real work but skipped verification gates. Resolve by ONE of: (a) RUN /v-pre-flight then dispatch agent review then /v-verify-done — this is the standard path for code changes, (b) if you cannot run the full gauntlet (e.g., parallel-session contamination), write HANDOFF_${SESSION_ID}.md (>= 80 bytes, starting with '# Handoff') that NAMES the files you changed and explains why the gates were skipped, (c) if the W22-4 retry cap was exceeded, the cycle_check_and_increment helper writes CYCLE_CAP_HANDOFF_${SESSION_ID}.md automatically — ensure it ran. Manual artifacts not backed by actual gate runs are an anti-pattern (AR-2)."
  if _cra_block_gate "$_abandonment_msg"; then
    { jq -n --arg msg "$_abandonment_msg" '{"decision":"block","reason":$msg}' 2>/dev/null; echo "$_abandonment_msg" >&2; }  # REASON-LOSS fix 2026-07-04: stderr ALWAYS carries the reason (exit-2 surfaces stderr, not stdout)
    exit 2
  fi
  _cra_write_skipped_marker "$_abandonment_msg"  # escape → leave a DURABLE skip record
  exit 0  # W5G-1 deadlock escape (warning already on stderr)
fi
# === LAYER-2 abandonment-with-code end ===


# === ABANDONMENT-DETECT (Part B): block abandonment with no artifacts ===
# If /v ran (per history) but produced no .md artifact AND no code changes,
# block — force the session to write a HANDOFF or completion artifact.
if [ "$IS_V_SESSION" -eq 0 ] && [ "$IS_V_INVOCATION_VIA_HISTORY" -eq 1 ] && [ "$CODE_CHANGED" -eq 0 ]; then
  # === REPORT-ONLY ESCAPE REGISTRY (merged 2026-07-05, per a skill-review report P0) ===
  # Every report-only skill family (skill-review, design-tier, consolidate, and now the
  # per-dimension v-audit-* family) hits the SAME Part-B gap: correctly-completed report-only
  # work with no code change and no recognized gauntlet artifact gets blocked as "abandonment".
  # Fixing this had been done 3x as copy-pasted blocks (SKILL-REVIEW / DESIGN-FAMILY /
  # CONSOLIDATE escapes) -- a 4th copy-paste for the audit family is exactly what this merge
  # avoids. Two shared helpers (evidence-gate + content-gate) plus a data table below replace
  # all of that. Behavior for the 3 pre-existing escapes is UNCHANGED byte-for-byte: same
  # evidence gate (exact history "display" match OR the STRICT W4B3/SREV-001 pasted-text
  # fallback, gated on a "[Pasted" history entry AND a content-start transcript match -- never a
  # bare substring, which is exactly the SREV-001 laundering vector this preserves
  # against) and the same content gate (min size + every listed regex/fixed-string check) --
  # proven by the existing Tier 4/4b/5/5b regression suite staying green with zero changes.
  # Deliberately NOT added to the IS_V_SESSION recognized-artifact list above -- that list
  # disarms Part B for EVERY session shape; every row here is scoped to ONE skill (or an
  # explicit sibling set) whose contract is report-only. A session that ALSO wrote code never
  # reaches this block (CODE_CHANGED=1 fails the enclosing condition) and owes the full gauntlet
  # regardless of which row would otherwise have matched.

  # ---- shared evidence gate ----
  # $1 = skill-name ERE (without leading slash; alternation allowed, e.g.
  # "v-audit-(growth|analytics)"). Prints non-empty evidence text on success, empty otherwise.
  _pb_evidence() {
    local _pat="$1" _hist="$HOME/.claude/history.jsonl" _sidf _ev _haspaste _tx
    _sidf='"sessionId":"'"$SESSION_ID"'"'
    _ev=$( (grep -F "$_sidf" "$_hist" 2>/dev/null || true) \
      | grep -E "\"display\":\"/(${_pat})" 2>/dev/null | head -1 || true )
    if [ -z "$_ev" ]; then
      # Pasted-text fallback (STRICT W4B3/SREV-001 mirror): only when history holds a
      # "[Pasted text" entry for this SID, and the command must be AT CONTENT START -- a bare
      # substring match would let a prose mention of the skill name in some other /v session's
      # first message launder a forged artifact through the escape.
      _haspaste=$( (grep -F "$_sidf" "$_hist" 2>/dev/null || true) \
        | grep -cF '"display":"[Pasted' 2>/dev/null || true )
      if [ "${_haspaste:-0}" -gt 0 ]; then
        _tx=$(ls -1t "$HOME/.claude/projects"/*/"${SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)
        if [ -n "$_tx" ] && [ -f "$_tx" ]; then
          _ev=$( head -30 "$_tx" | grep -F '"type":"user"' \
            | grep -E "\"content\":\"/(${_pat})[ \"-]" 2>/dev/null | head -1 || true )
        fi
      fi
    fi
    printf '%s' "$_ev"
  }

  # ---- shared content gate (fixed artifact name) ----
  # $1 = artifact basename (${SESSION_ID} already substituted), $2 = min size in bytes,
  # remaining args = content checks, ALL of which must pass. Check prefix convention:
  # "F:<literal>" = fixed-string grep -qF; "I:<ere>" = case-insensitive grep -qiE;
  # otherwise = case-sensitive grep -qE. Empty checks are skipped. Prints the matched absolute
  # path and returns 0 on success.
  _pb_check_fixed() {
    local _art="$1" _minsz="$2"; shift 2
    local _dir _path _size _check _ok
    for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
      [ -z "$_dir" ] && continue
      _path="$_dir/$_art"
      [ -f "$_path" ] || continue
      _size=$(wc -c < "$_path" 2>/dev/null | tr -d ' ')
      [ "${_size:-0}" -ge "$_minsz" ] || continue
      _ok=1
      for _check in "$@"; do
        [ -z "$_check" ] && continue
        case "$_check" in
          F:*) grep -qF "${_check#F:}" "$_path" 2>/dev/null || { _ok=0; break; } ;;
          I:*) grep -qiE "${_check#I:}" "$_path" 2>/dev/null || { _ok=0; break; } ;;
          *)   grep -qE "$_check" "$_path" 2>/dev/null || { _ok=0; break; } ;;
        esac
      done
      if [ "$_ok" -eq 1 ]; then printf '%s' "$_path"; return 0; fi
    done
    return 1
  }

  # ---- shared content gate (glob artifact name -- audit-family row only) ----
  # $1 = glob pattern (${SESSION_ID} already substituted, shell wildcards), $2 = min size,
  # $3 = ERE the basename must ALSO satisfy (extra safety net beyond the glob), remaining args
  # = content checks (same convention as _pb_check_fixed, plus "J:" = must parse as JSON via
  # jq -- schema-agnostic across the heterogeneous sibling schemas, but kills garbage bytes).
  _pb_check_glob() {
    local _glob="$1" _minsz="$2" _basere="$3"; shift 3
    local _dir _f _base _size _check _ok
    for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
      [ -z "$_dir" ] && continue
      for _f in "$_dir"/$_glob; do
        [ -f "$_f" ] || continue
        _base=$(basename "$_f")
        printf '%s' "$_base" | grep -qE "$_basere" 2>/dev/null || continue
        _size=$(wc -c < "$_f" 2>/dev/null | tr -d ' ')
        [ "${_size:-0}" -ge "$_minsz" ] || continue
        _ok=1
        for _check in "$@"; do
          [ -z "$_check" ] && continue
          case "$_check" in
            J:*) jq empty "$_f" >/dev/null 2>&1 || { _ok=0; break; } ;;
            F:*) grep -qF "${_check#F:}" "$_f" 2>/dev/null || { _ok=0; break; } ;;
            I:*) grep -qiE "${_check#I:}" "$_f" 2>/dev/null || { _ok=0; break; } ;;
            *)   grep -qE "$_check" "$_f" 2>/dev/null || { _ok=0; break; } ;;
          esac
        done
        if [ "$_ok" -eq 1 ]; then printf '%s' "$_f"; return 0; fi
      done
    done
    return 1
  }

  # ---- registry: one row per fixed-name report-only escape (parallel arrays; a "::"-joined
  # single string was considered and rejected -- several checks below contain "|" alternation,
  # which collides with any single-character field delimiter). ----
  _PB_LABEL=(
    "Skill-review"
    "Design-family" "Design-family" "Design-family" "Design-family"
    "Consolidation"
    "Gauntlet"
    "Differentiate"
    "Legal-docs"
    "Portfolio-cadence"
    "Prod-triage"
    "Traffic-wizard"
    "Launch-wizard"
  )
  _PB_SKILL=(
    "v-skill-reviewer"
    "v-activation-funnel-design" "v-pricing-design" "v-beta-program" "v-illustration-system"
    "v-audit-consolidate"
    "v-anti-template-gauntlet"
    "v-differentiate"
    "v-legal-docs-generate"
    "v-next"
    "v-prod-triage"
    "v-traffic"
    "v-launch"
  )
  _PB_ARTIFACT=(
    "SKILL_REVIEW_REPORT_${SESSION_ID}.md"
    "ACTIVATION_FUNNEL_${SESSION_ID}.md" "PRICING_STRATEGY_${SESSION_ID}.md" "BETA_PROGRAM_${SESSION_ID}.md" "ILLUSTRATION_SYSTEM_${SESSION_ID}.md"
    "CONSOLIDATED_AUDIT_REPORT_${SESSION_ID}.md"
    "GAUNTLET_REPORT_${SESSION_ID}.md"
    "DIFFERENTIATION_BRIEF_${SESSION_ID}.md"
    "LEGAL_AUDIT_${SESSION_ID}.md"
    "V_NEXT_REPORT_${SESSION_ID}.md"
    "PROD_TRIAGE_${SESSION_ID}.md"
    "TRAFFIC_PLAN_${SESSION_ID}.md"
    "LAUNCH_PLAN_${SESSION_ID}.md"
  )
  _PB_MINSZ=(300 300 300 300 300 300 300 300 300 300 300 300 300)
  # Gauntlet row (2026-07-05, skill-review report P0,
  # catalog F4 recurrence): /v-anti-template-gauntlet is report-only on its audit path -- a
  # standalone pre-ship gate run writes GAUNTLET_REPORT_<sid>.md (+ optionally BASELINE_2026_
  # <sid>.md and a .v-prompt-packs/ dir) and never touches application code. Verdict enum
  # includes BLOCK_OVERRIDDEN (the --force override value per the skill's Override policy).
  # Differentiate row (2026-07-05, skill-review report P0, catalog F4 recurrence):
  # /v-differentiate is report-only on its ideation path -- a standalone run writes a divergent
  # DIFFERENTIATION_BRIEF_<sid>.md (operator-pick menu) or, when the target is too vague, a
  # target_too_vague stub under the SAME artifact name; both start with the `# DIFFERENTIATION_BRIEF`
  # heading and a `session:` line (guaranteed by SKILL.md § Output Format + § Execution Context stub
  # rule). It never touches application code -- implementation is deferred to a follow-up /v-build.
  # If the operator DOES pick + implement ideas in-session, CODE_CHANGED=1 and this block is skipped
  # (the enclosing condition fails) -- the full gauntlet is owed as normal. Content gate = heading +
  # session line (two independent signals, both present in full brief AND stub), min 300 bytes.
  # Legal-docs row (2026-07-05, skill-review report P0, catalog F4 recurrence):
  # /v-legal-docs-generate dispatches 5 analysis dimensions via v-dispatch-subagent.sh (sets
  # HAS_SUBAGENT_DISPATCH=1) but writes only non-code `.md` deliverables (content/legal/*.md +
  # LEGAL_AUDIT_<sid>.md), so CODE_CHANGED stays 0 and it fell into the gap between the code-gated
  # clean exit and the report-only registry. It is report-only-ADJACENT (it writes real content
  # drafts, not just a report), so it is gated on its terminal audit artifact exactly like the
  # design-family rows: LEGAL_AUDIT_<sid>.md with the `# Legal Compliance Audit` H1 heading AND a
  # `## Documents Generated` section (two independent structural signals, both guaranteed by
  # SKILL.md § Step 3's template), min 300 bytes. LEGAL_AUDIT has no PASS/FAIL verdict line, so
  # the content gate is heading + section presence (not a verdict enum). If the operator implements
  # a follow-up in-session (CODE_CHANGED=1) the enclosing condition fails and the full gauntlet is
  # owed as normal.
  # Portfolio-cadence + Prod-triage rows (NEW 2026-07-05, added alongside the two new skills):
  # /v-next and /v-prod-triage are report-only, read-only-on-source skills (like the rows above)
  # that dispatch no application-code writes -- CODE_CHANGED stays 0 on a standalone run. Each
  # writes exactly ONE fixed-name artifact per session: V_NEXT_REPORT_<sid>.md (`# V_NEXT_REPORT`
  # heading) and PROD_TRIAGE_<sid>.md (`# PROD_TRIAGE` heading), both per their own SKILL.md §
  # Step 4 output template. Content gate = heading + `session:` line (two independent signals,
  # same shape as the Differentiate row above), min 300 bytes -- deliberately NOT gated on any
  # verdict enum since neither artifact has a PASS/FAIL verdict line by design (both are ranked-
  # list/triage reports, not gate verdicts). If a /v-prod-triage run's restore-drill mode is ever
  # extended to touch application code paths, CODE_CHANGED=1 fails the enclosing Part-B condition
  # and the full gauntlet is owed as normal -- same escape-scoping as every row in this registry.
  _PB_CHECK1=(
    '^#+[[:space:]]*SKILL_REVIEW_REPORT'
    '^#[[:space:]]*Activation Funnel Design' '^#[[:space:]]*Pricing Strategy' '^#[[:space:]]*Beta Program' '^#[[:space:]]*Illustration System'
    '^#+[[:space:]]*CONSOLIDATED_AUDIT_REPORT'
    '^#+[[:space:]]*GAUNTLET_REPORT'
    '^#+[[:space:]]*DIFFERENTIATION_BRIEF'
    '^#+[[:space:]]*Legal Compliance Audit'
    '^#+[[:space:]]*V_NEXT_REPORT'
    '^#+[[:space:]]*PROD_TRIAGE'
    '^#+[[:space:]]*TRAFFIC_PLAN'
    '^#+[[:space:]]*LAUNCH_PLAN'
  )
  _PB_CHECK2=(
    'I:^[-* ]*(\*\*)?Mode(\*\*)?:'
    '' '' '' ''
    'I:^[-* ]*(\*\*)?verdict(\*\*)?:[[:space:]]*(\*\*)?(PASS|NEEDS-WORK|BLOCK|NOT-RUN)'
    'I:^[-* ]*(\*\*)?verdict(\*\*)?:[[:space:]]*(\*\*)?(PASS|CONDITIONAL_PASS|BLOCK|BLOCK_OVERRIDDEN)'
    'I:^[-* ]*(\*\*)?session(\*\*)?:'
    '^#+[[:space:]]*Documents Generated'
    'I:^[-* ]*(\*\*)?session(\*\*)?:'
    'I:^[-* ]*(\*\*)?session(\*\*)?:'
    'I:^[-* ]*(\*\*)?session(\*\*)?:'
    'I:^[-* ]*(\*\*)?session(\*\*)?:'
  )
  _PB_CHECK3=(
    'I:^[-* ]*(\*\*)?Overall Status(\*\*)?:[[:space:]]*(\*\*)?(PASS|NEEDS-WORK|BLOCK)'
    '' '' '' ''
    'F:Generated by v-audit-consolidate'
    ''
    ''
    ''
    ''
    ''
    ''
    ''
  )

  _pb_i=0
  while [ "$_pb_i" -lt "${#_PB_SKILL[@]}" ]; do
    _pb_ev=$(_pb_evidence "${_PB_SKILL[$_pb_i]}")
    if [ -n "$_pb_ev" ]; then
      _pb_match=$(_pb_check_fixed "${_PB_ARTIFACT[$_pb_i]}" "${_PB_MINSZ[$_pb_i]}" \
        "${_PB_CHECK1[$_pb_i]}" "${_PB_CHECK2[$_pb_i]}" "${_PB_CHECK3[$_pb_i]}")
      if [ -n "$_pb_match" ]; then
        # Clear stale deadlock-escape markers from a PRIOR blocked stop of this same session
        # (mirrors the GAUNTLET_SKIPPED auto-removal elsewhere -- the session is now resolved).
        rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
        jq -n --arg msg "${_PB_LABEL[$_pb_i]} completion: $(basename "$_pb_match") accepted (report-only ${_PB_SKILL[$_pb_i]} session; history-gated + content-validated escape)" '{"systemMessage":$msg}' 2>/dev/null || true
        exit 0
      fi
    fi
    _pb_i=$((_pb_i + 1))
  done

  # ---- audit-family row (NEW 2026-07-05) -- per-dimension v-audit-* skills ----
  # v-audit-growth (and its report-only siblings v-audit-analytics/messaging/sales-pricing/
  # seo/admin/code) each write a "<PREFIX>_AUDIT[_REPORT]_<ts>_${SID}.json" + companion .md --
  # (v-audit-code, formerly v-audit-polish, renamed 2026-07-06 — writes AUDIT_CODE_REPORT_*.md)
  # exempted from CODE_CHANGED by CODE_EXT_EXEMPT ([A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)
  # and never matched by CODE_EXT_PATTERN for .md -- so a correctly-completed standalone audit
  # was blocked exactly like /v-skill-reviewer was before its escape (a skill-review
  # report P0). Unlike the fixed-name rows above, artifact names vary per sibling (GROWTH_AUDIT_*,
  # ANALYTICS_AUDIT_*, ADMIN_AUDIT_REPORT_*, ...) so this row is glob-shaped, keyed on the SAME
  # naming convention CODE_EXT_EXEMPT already recognizes, rather than one row per audit skill.
  # v-audit-consolidate and v-audit-orchestrator are DELIBERATELY EXCLUDED from the family
  # regex below -- consolidate has its own stricter dedicated row above (different filename
  # shape, a verdict-line + provenance-line content gate) which must stay authoritative for
  # that skill; this generic row only ever runs after it, and won't match consolidate's own
  # artifact shape regardless (CONSOLIDATED_AUDIT_REPORT_<sid>.md has no numeric/timestamp
  # segment immediately after "_REPORT_", so the negative case is structural, not just ordering).
  # History-gated (per-SID evidence, same strict pasted-fallback as every row above) AND
  # content-gated -- per F14, a /v-tdd session's history never matches the family regex
  # (negative case), and a stray audit artifact belonging to a DIFFERENT SID never matches
  # (the glob is SID-suffixed). Content-gate parity with the fixed-name rows (2026-07-05
  # hostile-review round): the basename must have a NUMERIC (timestamp) segment right after
  # _(AUDIT|REPORT)_ (every sibling's produces: contract stamps date +%Y%m%d_%H%M%S there;
  # kills invented FOO_REPORT_notes_* names); .json must parse via jq AND carry the domain
  # token as a JSON KEY from the family's structural vocabulary -- "*audit*" keys
  # (audit_metadata/audit_type/...), "findings", "overall_score", or "scorecard" -- NOT free
  # text (2026-07-05 re-verification residual: a decoy {"note":"audit..."} passed a bare
  # substring check; a key-shaped match forces a STRUCTURED lie, the same fabrication bar the
  # fixed-name rows set with their heading+verdict-line checks). The key set is the least
  # common vocabulary across all 7 sibling schemas: seo has NO audit_* key (its dim schemas
  # emit "findings"/"dimension"), so requiring audit_* alone would false-block honest seo runs.
  # .md must contain a markdown heading line AND the audit token (code is md-only; md
  # heading vocabulary is heterogeneous, so the md bar deliberately stays at fixed-row-style
  # heading fabricability rather than over-fitting one skill's title).
  # SID glob-safety guard: SESSION_ID is embedded UNQUOTED in the glob below -- a SID carrying
  # glob metacharacters could widen the match to other sessions' artifacts. Fail CLOSED (skip
  # the family escape entirely) for any SID not strictly [A-Za-z0-9-]. Fixed-name rows are not
  # affected (no glob expansion: exact -f path probe + grep -F evidence).
  case "$SESSION_ID" in
    ''|*[!A-Za-z0-9-]*) _pb_af_ev="" ;;
    *) _pb_af_ev=$(_pb_evidence 'v-audit-(growth|analytics|messaging|sales-pricing|seo|admin|code)') ;;
  esac
  if [ -n "$_pb_af_ev" ]; then
    _pb_af_match=$(_pb_check_glob "*_${SESSION_ID}.json" 300 '^[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[0-9]' 'J:' 'I:"([a-z_]*audit[a-z_]*|findings|overall_score|scorecard)"[[:space:]]*:')
    if [ -z "$_pb_af_match" ]; then
      _pb_af_match=$(_pb_check_glob "*_${SESSION_ID}.md" 300 '^[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[0-9]' '^#{1,6}[[:space:]]' 'I:audit')
    fi
    if [ -n "$_pb_af_match" ]; then
      rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
      jq -n --arg msg "Audit-family completion: $(basename "$_pb_af_match") accepted (report-only v-audit-* session; history-gated + content-validated escape)" '{"systemMessage":$msg}' 2>/dev/null || true
      exit 0
    fi
  fi
  # ---- hunt-family row (NEW 2026-07-05, per v-edge-hunt SKILL review; MIGRATED 2026-07-05 -- v-edge-hunt
  # merged INTO v-bug-hunt as a `boundaries` lens and archived to
  # ~/.claude/archive/skills-merged-2026-07-05/v-edge-hunt/) -- v-bug-hunt only ----
  # v-bug-hunt is a comprehensive-tier, READ-ONLY adversarial audit (both its `bugs` and
  # `boundaries` lenses): it dispatches parallel dimension subagents + a prompt-pack subagent
  # (HAS_SUBAGENT_DISPATCH=1) and changes NO application code (CODE_CHANGED=0). Before this row
  # existed, both hunt skills were absent from BOTH escape paths, so the F1 subagent-dispatch
  # promotion above flipped IS_V_SESSION=1 and every standalone run false-blocked on the
  # gauntlet-witness demand a report-only skill can never satisfy -- the identical CODEX-CRIT-1
  # failure the audit family hit. Post-merge, v-bug-hunt writes ONE artifact shape regardless of
  # lens: BUG_HUNT_REPORT_<ts>_<sid>.md (+ optional .json, tried second) -- there is no more
  # EDGE_HUNT_REPORT_* shape; the former v-edge-hunt skill directory no longer exists, so no new
  # session can invoke it, and this row deliberately does NOT match a legacy EDGE_HUNT_REPORT_*
  # filename/heading -- a stray file with that old shape must fall through to the full gauntlet,
  # never ride this escape. This row is glob-shaped like the audit-family row above but keyed on
  # the GUARANTEED report HEADING (# BUG_HUNT_REPORT) + the timestamped REPORT filename as its two
  # independent anti-forgery signals -- deliberately NOT the audit family's loose "audit" body
  # token, because a hunt report is not guaranteed to contain the literal word "audit" (relying on
  # it would false-block honest runs). Kept SEPARATE from the audit-family regex for the same
  # reason. History-gated (per-SID evidence, same STRICT pasted-content-start fallback as every row
  # above -- never a bare substring, the SREV-001 laundering guard) AND content-gated
  # (>=300B + filename + heading). SID glob-safety guard mirrors the audit-family row: fail CLOSED
  # (skip the escape) for any SID not strictly [A-Za-z0-9-] so a metachar SID cannot widen the glob
  # to another session's artifact. A hunt session that ALSO wrote code never reaches here
  # (CODE_CHANGED=1 fails the enclosing Part-B condition) and owes the full gauntlet regardless.
  case "$SESSION_ID" in
    ''|*[!A-Za-z0-9-]*) _pb_hf_ev="" ;;
    *) _pb_hf_ev=$(_pb_evidence 'v-bug-hunt') ;;
  esac
  if [ -n "$_pb_hf_ev" ]; then
    _pb_hf_match=$(_pb_check_glob "*_${SESSION_ID}.md" 300 '^BUG_HUNT_REPORT_[0-9]' '^#{1,6}[[:space:]]*BUG_HUNT_REPORT')
    if [ -z "$_pb_hf_match" ]; then
      _pb_hf_match=$(_pb_check_glob "*_${SESSION_ID}.json" 300 '^BUG_HUNT_REPORT_[0-9]' 'J:' 'I:"(findings|priority|evidence_type|dimension)"[[:space:]]*:')
    fi
    if [ -n "$_pb_hf_match" ]; then
      rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
      jq -n --arg msg "Hunt-family completion: $(basename "$_pb_hf_match") accepted (report-only v-bug-hunt session; history-gated + content-validated escape)" '{"systemMessage":$msg}' 2>/dev/null || true
      exit 0
    fi
  fi
  # ---- self-audit row (NEW 2026-07-05, per v-self-audit review) -- /v-self-audit ----
  # /v-self-audit is context:fork + report-only: it dispatches v-orchestrator-auditor + codex
  # sub-agents (HAS_SUBAGENT_DISPATCH=1) and changes NO code (writes only .md under
  # .v/self-audit/<sid>/, all CODE_EXT-exempt via the .v/ rule). Absent from BOTH escape paths it
  # was promoted to IS_V_SESSION=1 (the F1 subagent-dispatch promotion) and false-blocked on EVERY
  # run -- the identical CODEX-CRIT-1 failure the audit/hunt families hit. Its terminal artifact
  # SELF_AUDIT_SUMMARY_<sid>.md lives -- UNLIKE every row above -- NOT in ARTIFACT_SEARCH_DIRS but
  # under .v/self-audit/<sid>/ (the skill's stop-at-plan write-confinement dir), so this row probes
  # that dir explicitly (REPO_ROOT + MAIN_ROOT) rather than reusing _pb_check_fixed. Two independent
  # anti-forgery signals, both guaranteed by SKILL.md's final-report template: the
  # '# SELF_AUDIT_SUMMARY' heading AND an 'Overall: PASS|FINDINGS|BLOCK' verdict line, min 300B --
  # the SAME two signals the skill's own self-check validates (producer≡validator parity). History-
  # gated (per-SID evidence, same STRICT pasted-content-start fallback as every row above -- never a
  # bare substring, the SREV-001 laundering guard). SID charset guard for defense-in-depth
  # parity with the glob rows (here SESSION_ID is a path segment, not a glob, but a metachar SID is
  # rejected anyway). A self-audit run that ALSO wrote code never reaches here (CODE_CHANGED=1 fails
  # the enclosing Part-B condition) and owes the full gauntlet regardless.
  case "$SESSION_ID" in
    ''|*[!A-Za-z0-9-]*) _pb_sa_ev="" ;;
    *) _pb_sa_ev=$(_pb_evidence 'v-self-audit') ;;
  esac
  if [ -n "$_pb_sa_ev" ]; then
    _pb_sa_match=""
    for _sa_root in "$REPO_ROOT" "${MAIN_ROOT:-}"; do
      [ -n "$_sa_root" ] || continue
      _sa_f="$_sa_root/.v/self-audit/${SESSION_ID}/SELF_AUDIT_SUMMARY_${SESSION_ID}.md"
      [ -f "$_sa_f" ] || continue
      _sa_sz=$(wc -c < "$_sa_f" 2>/dev/null | tr -d ' ')
      [ "${_sa_sz:-0}" -ge 300 ] || continue
      grep -qE '^#+[[:space:]]*SELF_AUDIT_SUMMARY' "$_sa_f" 2>/dev/null || continue
      grep -qiE '^[[:space:]]*Overall:[[:space:]]*(PASS|FINDINGS|BLOCK)' "$_sa_f" 2>/dev/null || continue
      _pb_sa_match="$_sa_f"; break
    done
    if [ -n "$_pb_sa_match" ]; then
      rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
      jq -n --arg msg "Self-audit completion: $(basename "$_pb_sa_match") accepted (report-only /v-self-audit session; history-gated + content-validated escape)" '{"systemMessage":$msg}' 2>/dev/null || true
      exit 0
    fi
  fi
  # ---- forensics-family row (NEW 2026-08-02, per ecosystem skill audit) -- /v-forensics + /v-forensics-pack-runner ----
  # Both forensics skills are READ-ONLY post-mortems that grant the Agent tool and dispatch
  # per-SID analyzer subagents (HAS_SUBAGENT_DISPATCH=1) while changing NO code (CODE_CHANGED=0).
  # Absent from BOTH escape paths they were promoted to IS_V_SESSION=1 by the F1 subagent-dispatch
  # promotion and false-blocked on EVERY standalone run -- the identical CODEX-CRIT-1 failure the
  # audit / hunt / self-audit families each hit before getting their row. This is a LIVE recurrence,
  # not a theoretical one: the session record logs four standalone forensic runs (Jul-10/11/16).
  # v-forensics-pack-runner already wrote PACK_RUNNER_FORENSICS_REPORT_<ts>_<sid>.md; v-forensics
  # wrote NOTHING durable until the 2026-08-02 SKILL.md change added FORENSICS_REPORT_<ts>_<sid>.md
  # (§ PERSIST THE REPORT) -- registering on history-evidence alone was rejected as architecturally
  # inconsistent (every other row is content-gated, and an evidence-only row would let a session that
  # invoked the skill then bailed early still escape). Glob-shaped like the hunt-family row above and
  # keyed on TWO independent anti-forgery signals guaranteed by each skill's own required-sections
  # list: the H1 heading AND the 'Coverage manifest' section. The two basename regexes are mutually
  # exclusive by anchoring -- '^FORENSICS_REPORT_' cannot match a PACK_RUNNER_-prefixed file, so a
  # pack-runner artifact can never satisfy the v-forensics row or vice versa. History-gated per-SID
  # (same STRICT pasted-content-start fallback as every row above -- never a bare substring, the
  # SREV-001 laundering guard). SID charset guard fails CLOSED so a metachar SID cannot
  # widen the glob onto another session's artifact. A forensics session that ALSO wrote code never
  # reaches here (CODE_CHANGED=1 fails the enclosing Part-B condition) and owes the full gauntlet.
  case "$SESSION_ID" in
    ''|*[!A-Za-z0-9-]*) _pb_fx_ev="" ;;
    *) _pb_fx_ev=$(_pb_evidence 'v-forensics') ;;
  esac
  if [ -n "$_pb_fx_ev" ]; then
    _pb_fx_match=$(_pb_check_glob "*_${SESSION_ID}.md" 300 '^FORENSICS_REPORT_[0-9]' '^#{1,6}[[:space:]]*FORENSICS_REPORT' 'I:coverage manifest')
    if [ -z "$_pb_fx_match" ]; then
      _pb_fx_match=$(_pb_check_glob "*_${SESSION_ID}.md" 300 '^PACK_RUNNER_FORENSICS_REPORT_[0-9]' '^#{1,6}[[:space:]]*PACK_RUNNER_FORENSICS_REPORT' 'I:coverage manifest')
    fi
    if [ -n "$_pb_fx_match" ]; then
      rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null || true
      jq -n --arg msg "Forensics-family completion: $(basename "$_pb_fx_match") accepted (report-only forensics session; history-gated + content-validated escape)" '{"systemMessage":$msg}' 2>/dev/null || true
      exit 0
    fi
  fi

  # === REPORT-ONLY ESCAPE REGISTRY end ===

  _abandonment_msg="COMPLETION BLOCKED: /v was invoked in this session (history.jsonl evidence) but no PRE_FLIGHT_REPORT_${SESSION_ID}.md / AGENT_REVIEW_${SESSION_ID}.md / VERIFY_DONE_REPORT_${SESSION_ID}.md / TRIVIAL_PASS_${SESSION_ID}.md / HANDOFF_${SESSION_ID}.md / CYCLE_CAP_HANDOFF_${SESSION_ID}.md was produced in ${REPO_ROOT}/.v/artifacts (or the legacy REPO_ROOT fallback). This is the abandonment failure mode (handoff §4a). Resolve by one of: (a) complete the work and produce artifacts, (b) write TRIVIAL_PASS_${SESSION_ID}.md per W39-B if scope was trivial, (c) write HANDOFF_${SESSION_ID}.md (>= 80 bytes, starting with '# Handoff') as a terminal blocked/progress artifact, (d) if the W22-4 retry cap was exceeded, ensure cycle_check_and_increment wrote CYCLE_CAP_HANDOFF_${SESSION_ID}.md, (e) if this was a /v-skill-reviewer session, write its SKILL_REVIEW_REPORT_${SESSION_ID}.md (>= 300 bytes, '# SKILL_REVIEW_REPORT' heading, Mode: line, Overall Status: PASS|NEEDS-WORK|BLOCK) — it is accepted as the report-only completion artifact, (f) if this was a design-family session (v-activation-funnel-design / v-pricing-design / v-beta-program / v-illustration-system), write its ACTIVATION_FUNNEL_${SESSION_ID}.md / PRICING_STRATEGY_${SESSION_ID}.md / BETA_PROGRAM_${SESSION_ID}.md / ILLUSTRATION_SYSTEM_${SESSION_ID}.md respectively (>= 300 bytes, matching H1 heading) — it is accepted as the report-only completion artifact, (g) if this was a /v-audit-consolidate session, write its CONSOLIDATED_AUDIT_REPORT_${SESSION_ID}.md (>= 300 bytes, '# CONSOLIDATED_AUDIT_REPORT' heading, 'verdict: PASS|NEEDS-WORK|BLOCK|NOT-RUN' line, 'Generated by v-audit-consolidate' provenance line) — it is accepted as the report-only completion artifact, (h) if this was a /v-anti-template-gauntlet session, write its GAUNTLET_REPORT_${SESSION_ID}.md (>= 300 bytes, '# GAUNTLET_REPORT' heading, 'verdict: PASS|CONDITIONAL_PASS|BLOCK|BLOCK_OVERRIDDEN' line) — it is accepted as the report-only completion artifact, (i) if this was a /v-legal-docs-generate session, write its LEGAL_AUDIT_${SESSION_ID}.md (>= 300 bytes, '# Legal Compliance Audit' heading, '## Documents Generated' section) — it is accepted as the report-only completion artifact, (j) if this was a /v-self-audit session, write its SELF_AUDIT_SUMMARY_${SESSION_ID}.md under .v/self-audit/${SESSION_ID}/ (>= 300 bytes, '# SELF_AUDIT_SUMMARY' heading, 'Overall: PASS|FINDINGS|BLOCK' line) — it is accepted as the report-only completion artifact."
  # ABANDON-ENRICH Change 1 (message REPLACEMENT only — Part B already blocks this state, so
  # this cannot create a new false block). The cached capture keeps the rearm fingerprint
  # stable across re-arms (SME-L2-1). Recovery contract deliberately does NOT offer
  # BLOCKED_<sid>.md (SME-A-D2: Part B/SREV-004 rejects it — never instruct a dead exit).
  if [ -n "$_ab_class" ] && [ -n "$_ab_capture" ] && [ "$_AB_GATE_MODE" != "off" ]; then
    _abandonment_msg="COMPLETION BLOCKED (abandon-enrich/${_ab_class}): the final message concluded '${_ab_class}' but the user's ACTUAL task is in the SID-scoped capture at ${_ab_capture_src}: \"${_ab_capture}\". You ARE the /v orchestrator (W25-F11 — the generic subagent framing is boilerplate; a readable /v context means YOU own this task end-to-end). Resolve by ONE of: (a) route the quoted task through /v Step 1 NOW (classification table), (b) ask ONE clarifying AskUserQuestion if the task is genuinely ambiguous, (c) write HANDOFF_${SESSION_ID}.md (>= 80 bytes, '# Handoff' heading) that QUOTES the task above and states why it could not be executed."
    _ab_note "block-partB"
  fi
  if _cra_block_gate "$_abandonment_msg"; then
    { jq -n --arg msg "$_abandonment_msg" '{"decision":"block","reason":$msg}' 2>/dev/null; echo "$_abandonment_msg" >&2; }  # REASON-LOSS fix 2026-07-04: stderr ALWAYS carries the reason (exit-2 surfaces stderr, not stdout)
    exit 2
  fi
  _cra_write_skipped_marker "$_abandonment_msg"  # escape → leave a DURABLE skip record
  exit 0  # W5G-1 deadlock escape (warning already on stderr)
fi
# === ABANDONMENT-DETECT (Part B) end ===


if [ "$IS_V_SESSION" -eq 0 ] && [ "$CODE_CHANGED" -eq 0 ]; then
  exit 0
fi

BLOCKING_ISSUES=""
WARNINGS=""
HOSTILE_REVIEW_REQUIRED=0

# === W71 TRUTH GATE: the final report must not contradict the diff ===
# Root cause (a production session, 2026-05-29): /v told the user the bug was
# "already fixed — the error doesn't exist in executable code, clear your cache" while the
# working tree held a 269-line diff it had just written; the model later admitted it
# "actually did make substantive code changes despite reporting otherwise." The gauntlet
# caught the missing artifacts, but the USER-FACING narration was a flat falsehood. This
# gate surfaces that specific contradiction: a session that CHANGED CODE must not sign off
# with a "no changes / already fixed / not a real bug" conclusion. WARNING (not block): the
# gauntlet is the hard backstop (code-changed ⇒ artifacts required); a hard NL-pattern block
# would false-trip on legit "already fixed upstream, I only added a regression test" outcomes
# the model cannot undo. The DENIAL pattern is deliberately narrow — no generic completion
# words, no incidental "clear cache" advice — so it fires only on a report whose THESIS is
# that no work was done. (Placed here, after WARNINGS init, so the append is nounset-safe.)
if [ "$CODE_CHANGED" -eq 1 ] && [ -n "$LAST_MSG" ]; then
  _truth_denial='already (been )?(fixed|resolved|addressed|patched)|no (code )?(change|changes|fix|edit|edits|modification|modifications)[[:space:]]*(were|was|is|are)?[[:space:]]*(needed|necessary|required|made)|(does|did)[[:space:]]*n.?t (exist|appear) in (the )?(executable|production|application|source) code|only (exists )?in the test file|not (actually )?a (real )?bug|nothing (to (fix|change|implement)|needs? (fixing|changing))|no fix (was )?(needed|required|necessary)'
  # Suppress when the SAME report also claims authorship of work this session (e.g.
  # "already fixed upstream — I added a regression test"): that is an honest MIXED report,
  # not a "did nothing" denial. Only a pure denial with NO work-claim is that
  # falsehood. (W71 review fix — avoids a redundant warning on legit mixed reports.)
  _truth_workclaim='(^|[^[:alpha:]])(added|implemented|wrote|created|refactored|introduced|modified|updated|changed|patched|committed|fixed[[:space:]]+(the|a|this|it)|made[[:space:]]+(the|a|these|this)[[:space:]]+(change|edit|fix))([^[:alpha:]]|$)'
  if echo "$LAST_MSG" | grep -qiE "$_truth_denial" && ! echo "$LAST_MSG" | grep -qiE "$_truth_workclaim"; then
    WARNINGS="$WARNINGS
  ⚠️ TRUTH GATE — your final report appears to claim no work was needed (already fixed / not a real bug / no changes required), but THIS SESSION CHANGED CODE. Reconcile your report with the diff: state what you actually changed, or revert it if unintended. A code-changing session must not sign off with a 'nothing to fix' narrative (an observed production session did exactly this)."
  fi
fi

# === SURVIVAL GATE (1A, forensic 2026-06-15: the silent-wipe class) ===
# The recurring cross-wave loss: a session WRITES source, passes every gate, then its uncommitted work
# is silently WIPED by a concurrent sibling's stash/restore on shared main — and /v reports green. The
# detectors only caught it post-hoc. This consumes the SINGLE-SOURCED _survival_verdict (validation.sh)
# that the producer self-check ALSO consumes, so the two cannot disagree (the _independence_verdict
# pattern). Mode via $V_SURVIVAL_GATE: block (default — ENFORCE, recoverable) | warn (observe) | off.
# RECOVERABLE BY DESIGN: the producer self-check runs this SAME verdict, so it fires DURING the /v
# session — the orchestrator re-applies + commits the lost work (committed work survives) and re-runs
# the gate, which then passes. The block is a "re-apply your work" loop, not a dead-end. Dial back with
# V_SURVIVAL_GATE=warn if it ever misfires in the wild.
_SURVIVAL_MODE="${V_SURVIVAL_GATE:-block}"
if [ "$_SURVIVAL_MODE" != "off" ] && [ -n "$SESSION_ID" ] && type _survival_verdict >/dev/null 2>&1; then
  _sv_verdict=$(_survival_verdict "$SESSION_ID" "$MAIN_ROOT" 2>/dev/null || echo "skip:error")
  case "$_sv_verdict" in
    lost:*)
      _sv_rest="${_sv_verdict#lost:}"; _sv_n="${_sv_rest%%:*}"; _sv_files="${_sv_rest#*:}"
      _sv_msg="SURVIVAL GATE: this session WROTE ${_sv_n} source file(s) that no longer exist in the working tree, in any commit since baseline, or in a session worktree — and there is NO HANDOFF/MERGE_DEFERRED marker. The deliverable was silently WIPED (the concurrent shared-tree clobber class: a sibling's stash/restore on shared main), yet the gates passed against work that is now gone. RECOVER — do NOT stop, this is your autonomous re-apply loop: (1) RE-CREATE your change in each file below FIRST — the work is GONE, so there is nothing to commit until you re-apply it (committing the current wiped state does nothing and the gate will still block); (2) THEN 'git add' + 'git commit' the re-applied files IMMEDIATELY — committed work cannot be clobbered by a sibling's stash; (3) re-run the self-check, which will then pass. Lost files: ${_sv_files}. ONLY if the loss is genuinely intended, declare it in HANDOFF_${SESSION_ID}.md."
      if [ "$_SURVIVAL_MODE" = "block" ]; then
        if _cra_block_gate "$_sv_msg"; then
          printf '%s\n' "COMPLETION BLOCKED — $_sv_msg" >&2
          exit 2
        fi
      else
        WARNINGS="$WARNINGS
  ⚠️ $_sv_msg (observe mode — set V_SURVIVAL_GATE=block to enforce)"
      fi ;;
  esac
fi

# === EXPOSED-INLINE-WORK GATE (1B, forensic 2026-06-16: a cross-session near-miss) ===
# Single-sourced _exposed_inline_verdict (validation.sh) — the producer self-check consumes the SAME
# verdict. Blocks (recoverably) a session that left SOURCE uncommitted inline on shared main while
# sibling /v sessions are active — the EXPOSURE that precedes the silent-wipe clobber (the survival gate
# catches the wipe; this prevents it). Recovery = a SCOPED checkpoint commit of the session's own files
# (CLAUDE.md V_DEPTH>=1 policy already authorizes it). Mode $V_EXPOSED_GATE: block (default) | warn | off.
_EXPOSED_MODE="${V_EXPOSED_GATE:-block}"
if [ "$_EXPOSED_MODE" != "off" ] && [ -n "$SESSION_ID" ] && type _exposed_inline_verdict >/dev/null 2>&1; then
  _ex_verdict=$(_exposed_inline_verdict "$SESSION_ID" "$MAIN_ROOT" 2>/dev/null || echo "skip:error")
  case "$_ex_verdict" in
    exposed:*)
      _ex_rest="${_ex_verdict#exposed:}"; _ex_n="${_ex_rest%%:*}"; _ex_files="${_ex_rest#*:}"
      # PREDICTIVE FIX (forensic 2026-08-18, deadlock class): the OLD message
      # unconditionally asserted "CLAUDE.md's V_DEPTH>=1 checkpoint policy authorizes this scoped
      # commit" as though that settled whether `git commit` would succeed. It never checked whether
      # enforce-pre-commit-gates.sh — the ONLY hook with actual commit-blocking authority, and
      # completely unaware of V_DEPTH/checkpoint semantics — was about to reject the exact commit
      # this message just told the model to make. One session hit that deadlock 29 times in ~16
      # minutes: PRE_FLIGHT_REPORT/AGENT_REVIEW generating asynchronously while this message kept
      # insisting the commit was authorized. _exposed_inline_commit_ready predicts the REAL gate's
      # verdict using the same artifact-resolution algorithm enforce-pre-commit-gates.sh itself
      # delegates to, so the message can tell the truth either way. Advisory only — changes what
      # this message says, never what enforce-pre-commit-gates.sh (unmodified) actually decides.
      _ex_ready="missing:PRE_FLIGHT_REPORT+AGENT_REVIEW"
      if type _exposed_inline_commit_ready >/dev/null 2>&1; then
        _ex_ready="$(_exposed_inline_commit_ready "$SESSION_ID" "${ARTIFACT_SEARCH_DIRS[@]}" 2>/dev/null || echo "missing:PRE_FLIGHT_REPORT+AGENT_REVIEW")"
      fi
      if [ "$_ex_ready" = "ready" ]; then
        _ex_msg="EXPOSED INLINE WORK: this session wrote ${_ex_n} source file(s) sitting UNCOMMITTED on shared main while sibling /v sessions are active — the exact state where a concurrent sibling's stash/merge-back clobbers your work. PRE_FLIGHT_REPORT and AGENT_REVIEW (or this session's light-tier waiver) appear in place and pass basic content checks, so enforce-pre-commit-gates.sh is expected to accept a scoped commit right now — this is a prediction from artifact presence + basic content validation, not the real gate's full semantic checks, so treat a rejection as informative rather than impossible. COMMIT them now — SCOPED to your OWN files, NEVER 'git add -A' (that would sweep up a sibling's uncommitted work): run 'git add ${_ex_files}' then 'git commit', then re-run. FIRST verify each listed file's CURRENT content is YOUR work — if a concurrent sibling edited the SAME file on shared main, committing it would sweep up their change too, so commit only your own (re-apply your hunks if a sibling overwrote them). CLAUDE.md's V_DEPTH>=1 checkpoint policy authorizes committing without asking the user first — it is enforce-pre-commit-gates.sh's own artifact check, predicted ready above, that actually determines this commit will succeed. Exposed: ${_ex_files}."
      else
        _ex_missing="${_ex_ready#missing:}"
        _ex_msg="EXPOSED INLINE WORK: this session wrote ${_ex_n} source file(s) sitting UNCOMMITTED on shared main while sibling /v sessions are active — the exact state where a concurrent sibling's stash/merge-back clobbers your work. A 'git commit' right now will be REJECTED: enforce-pre-commit-gates.sh independently requires ${_ex_missing} for this session (${SESSION_ID}) before it allows ANY commit — do not retry 'git commit' until that is satisfied, it will fail identically every time. Finish or dispatch ${_ex_missing} first (the same thing this Stop gate's overall gauntlet already needs); if a dispatch for it is already running, wait for it to land rather than polling in a tight retry loop. Once ${_ex_missing} exists, run the SCOPED commit ('git add ${_ex_files}' then 'git commit' — never 'git add -A', that would sweep up a sibling's uncommitted work). Exposed: ${_ex_files}."
      fi
      if [ "$_EXPOSED_MODE" = "block" ]; then
        if _cra_block_gate "$_ex_msg"; then
          printf '%s\n' "COMPLETION BLOCKED — $_ex_msg" >&2
          exit 2
        fi
      else
        WARNINGS="$WARNINGS
  ⚠️ $_ex_msg (observe mode — set V_EXPOSED_GATE=block to enforce)"
      fi ;;
  esac
fi

# === W-perf4 NAMED-TARGET GATE: did the diff touch the file the task named? ===
# Dual of the truth gate above. Catches the "honest 'I fixed it', WRONG file" misreport
# (two prod sessions: /v resolved a stale/mis-parsed paste, fixed an
# unrelated already-done bug, and reported success — the task named a specific file:line
# the diff never touched; the user caught it both times).
# WARNING, not block: a legit session can fix the ROOT CAUSE in a different file than the
# SYMPTOM the task named (a prod session named a config file:line but correctly
# fixed a service class upstream) — a hard block would wrongly reject that. The warning
# forces a reconcile (confirm, or a one-line note on why the named file wasn't the fix
# site). Fires only when the task named >=1 concrete code path AND none appear in the diff;
# a paste that resolved to a placeholder yields 0 targets, so it correctly does NOT fire.
if [ "$IS_V_SESSION" -eq 1 ] && [ "$CODE_CHANGED" -eq 1 ] && [ -n "$ALL_CHANGED_PATHS" ]; then
  _resolved_task_file="$HOME/.claude/runtime/v-resolved-task-${SESSION_ID}.txt"
  if [ -s "$_resolved_task_file" ]; then
    # Strip URLs first (a preview link like https://example.com/preview/page is not a source
    # file), then extract code-file paths with an optional :NNN suffix; drop the suffix
    # and protocol-relative // tokens. URL strip prevents false targets from deploy logs.
    _nt_src=$(sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+##g' "$_resolved_task_file" 2>/dev/null || true)
    _named_targets=$(printf '%s' "$_nt_src" \
      | grep -oE '[A-Za-z0-9_./-]+\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs)(:[0-9]+)?' \
      | sed -E 's/:[0-9]+$//' \
      | grep -vE '^//' \
      | awk 'NF' | sort -u || true)
    if [ -n "$_named_targets" ]; then
      _nt_hit=0
      while IFS= read -r _tgt; do
        [ -z "$_tgt" ] && continue
        if printf '%s\n' "$ALL_CHANGED_PATHS" | grep -qF "$(basename "$_tgt")"; then _nt_hit=1; break; fi
      done <<< "$_named_targets"
      if [ "$_nt_hit" -eq 0 ]; then
        WARNINGS="$WARNINGS
  ⚠️ NAMED-TARGET MISMATCH — the task named source file(s) [$(printf '%s' "$_named_targets" | tr '\n' ' ')] but THIS session's diff touched NONE of them. Either (a) /v resolved the WRONG task (stale/mis-parsed paste) and 'fixed' an unrelated bug while reporting success (two prod sessions), or (b) you correctly fixed the ROOT CAUSE in a different file than the symptom the task named (legit — seen in a prod session). Reconcile: confirm you addressed the file the task named, OR add a one-line note in your completion stating why the named file was not the fix site."
      fi
    fi
  fi
fi

# === F2 BOUNDARY ADVISORY (forensic 2026-06-17) ===
# verify-done's own boundary-drift check is prose AND is explicitly FORBIDDEN to compute base..HEAD on
# shared main (sibling churn → the false-positive class; dispatch-v-verify-done.md:132). So an
# out-of-declared-boundary SOURCE file lands un-flagged on an otherwise-PASS verify-done (one session shipped
# a chart component, another a util module — both outside their declared FILE BOUNDARY, neither
# flagged; P0a then has no FND-BND to block on). This is the inverse of the NAMED-TARGET gate above and,
# like it, a WARNING — NEVER a block: a hard boundary block on shared main would re-create the exact
# sibling-churn false-positive verify-done is forbidden from making. SID-SCOPED + sibling-immune: it reads
# ONLY this session's own writes log (get_session_writes), never a shared-main git diff, so a concurrent
# sibling's file can never be mis-attributed here. Scoped to SOURCE files (the risky ones); docs/config OOB
# is intentionally not flagged (low risk, high noise — e.g. a QA-requested CLAUDE.md edit).
_f2_task_file="$HOME/.claude/runtime/v-resolved-task-${SESSION_ID}.txt"
if [ "$IS_V_SESSION" -eq 1 ] && [ "$CODE_CHANGED" -eq 1 ] && [ -s "$_f2_task_file" ] \
   && type get_session_writes >/dev/null 2>&1 \
   && grep -qiE 'FILE[[:space:]]+BOUNDARY' "$_f2_task_file" 2>/dev/null; then
  # Extract the FILE BOUNDARY declaration: from the 'FILE BOUNDARY' line, up to the next blank line or the
  # next ALL-CAPS section label (CONVENTIONS:/SUCCESS:/ACCEPTANCE:/CONTEXT:/...). Then pull path-like tokens.
  _f2_block=$(awk '
    /[Ff][Ii][Ll][Ee][[:space:]]+[Bb][Oo][Uu][Nn][Dd][Aa][Rr][Yy]/ {grab=1; sub(/^.*[Bb][Oo][Uu][Nn][Dd][Aa][Rr][Yy][[:space:]]*:?/,""); print; next}
    grab==1 && /^[[:space:]]*$/ {grab=0}
    grab==1 && /^[[:space:]]*[A-Z][A-Z_ ]+:/ {grab=0; next}
    grab==1 {print}' "$_f2_task_file" 2>/dev/null)
  _f2_entries=$(printf '%s' "$_f2_block" \
    | sed -E 's#[A-Za-z][A-Za-z0-9+.-]*://[^[:space:]]+##g' \
    | grep -oE '[A-Za-z0-9_./*-]+\.(php|ts|tsx|js|jsx|vue|svelte|py|rb|go|rs|css|scss)|[A-Za-z0-9_./-]+/\*{1,2}' \
    | awk 'NF' | sort -u || true)
  if [ -n "$_f2_entries" ]; then
    _f2_oob=""
    while IFS= read -r _cf; do
      [ -z "$_cf" ] && continue
      printf '%s\n' "$_cf" | grep -E "$CODE_EXT_PATTERN" | grep -vqE "$CODE_EXT_EXEMPT" || continue  # SOURCE files only
      case "$_cf" in                                                            # in-boundary by convention
        tests/*|*/tests/*|*.test.*|*.spec.*|*Test.php) continue ;;
        *features.php|*phpunit.xml|*setup.ts|*ziggy.js) continue ;;
        .v/*|*/.v/*|.git/*|*/.git/*) continue ;;
      esac
      _cf_base=$(basename "$_cf")
      _f2_matched=0
      while IFS= read -r _be; do
        [ -z "$_be" ] && continue
        # match: basename equality, OR boundary entry is a path-substring of the changed file (suffix/dir),
        # OR a trailing /* or /** dir-glob covers it. Over-matching the boundary = fewer advisories = SAFE.
        if [ "$_cf_base" = "$(basename "$_be")" ] || printf '%s' "$_cf" | grep -qF "$_be"; then _f2_matched=1; break; fi
        case "$_be" in
          */'**') _d="${_be%/**}"; case "$_cf" in "$_d"/*) _f2_matched=1; break;; esac ;;
          */'*')  _d="${_be%/*}";  case "$_cf" in "$_d"/*) _f2_matched=1; break;; esac ;;
        esac
      done <<< "$_f2_entries"
      [ "$_f2_matched" -eq 0 ] && _f2_oob="${_f2_oob}${_cf}
"
    done <<< "$(get_session_writes "$SESSION_ID" 2>/dev/null | grep -v '^\[subagent-dispatch\]$' || true)"
    _f2_oob=$(printf '%s' "$_f2_oob" | awk 'NF' | sort -u)
    if [ -n "$_f2_oob" ]; then
      WARNINGS="$WARNINGS
  ⚠️ BOUNDARY ADVISORY (F2) — source file(s) changed but NOT in the task's declared FILE BOUNDARY: [$(printf '%s' "$_f2_oob" | tr '\n' ' ')]. verify-done can PASS without flagging this (its boundary check is unreliable on shared main). Confirm each is a legitimate in-scope expansion (e.g. a type-companion or same-feature label fix) — note it in your completion — OR move it to its own session. Advisory only — not blocking."
    fi
  fi
fi

if [ "$CODE_CHANGED" -eq 1 ] && type review_requires_hostile_focus_from_paths >/dev/null 2>&1; then
  if review_requires_hostile_focus_from_paths "$ALL_CHANGED_PATHS"; then
    HOSTILE_REVIEW_REQUIRED=1
  fi
fi

PREFLIGHT_FILE=""
REVIEW_FILE=""
VERIFY_DONE_FILE=""
IMPLEMENTATION_FILE=""
REVIEW_SEMANTIC_ERROR=""

# W39-B: TRIVIAL workflow bypass.
# Sessions that classified as TRIVIAL (1-file, ≤3-line, metadata-only changes)
# write a single TRIVIAL_PASS_<sid>.md marker. Accept it as full artifact
# satisfaction — no PRE_FLIGHT_REPORT, AGENT_REVIEW, or VERIFY_DONE_REPORT
# required. The marker contains the gate results and a brief change summary.
if [ -n "$SESSION_ID" ]; then
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _trivial_marker="$_dir/TRIVIAL_PASS_${SESSION_ID}.md"
    if [ -f "$_trivial_marker" ]; then
      # File must be > 30 bytes (catches truly-empty spoofs) and contain at
      # least the literal "TRIVIAL=1" line so it can't just be a 31-byte stub.
      _trivial_size=$(wc -c < "$_trivial_marker" 2>/dev/null | tr -d ' ')
      # W39 review F4: the marker MUST contain the structural shape that
      # only the classifier produces — TRIVIAL=1 + REASON= + FILE= + LINES=.
      # A 31-byte stub with just "TRIVIAL=1\n" is rejected. The orchestrator
      # cannot fabricate a passing marker without invoking the classifier.
      if [ "${_trivial_size:-0}" -ge 60 ] && \
         grep -q '^TRIVIAL=1$' "$_trivial_marker" 2>/dev/null && \
         grep -q '^REASON=' "$_trivial_marker" 2>/dev/null && \
         grep -q '^FILE=' "$_trivial_marker" 2>/dev/null && \
         grep -q '^LINES=' "$_trivial_marker" 2>/dev/null; then
        # 2026-05-28 (bypass/WG-7, handoff/B4-1): a TRIVIAL_PASS is a CODE-shipping
        # completion that exits BEFORE the witness gate, so the structural-shape
        # check alone is not enough — a model can hand-author the 4 lines, and a
        # stale prior same-SID marker would silently satisfy a later code-shipping
        # invocation. Independently re-verify: (a) FRESHNESS (marker written by THIS
        # /v invocation, fail-closed on a missing start marker) and (b) TRIVIALITY
        # (the session's writes log shows at most ONE code file — a multi-file change
        # cannot be trivial). Either failing ⇒ fall through to the full gauntlet.
        _trivial_reject=""
        if ! _marker_is_fresh "$_trivial_marker" closed; then
          _trivial_reject="marker is STALE (predates this /v invocation's start marker, or no start marker was written) — a prior same-SID invocation's TRIVIAL_PASS cannot satisfy this session"
        else
          _tw_codecount=0
          _tw_file=""
          if type session_writes_log_path >/dev/null 2>&1; then
            _tw_file="$(session_writes_log_path "$SESSION_ID" 2>/dev/null || true)"
          fi
          if [ -z "$_tw_file" ] || [ ! -f "$_tw_file" ]; then
            _tw_file="$(git rev-parse --git-common-dir 2>/dev/null)/claude-session-writes-${SESSION_ID}.txt"
          fi
          if [ -f "$_tw_file" ]; then
            _tw_codecount=$( ( grep -v '^$' "$_tw_file" 2>/dev/null \
              | sort -u \
              | grep -E "$CODE_EXT_PATTERN" 2>/dev/null \
              | grep -vE "$CODE_EXT_EXEMPT" 2>/dev/null \
              ) | wc -l | tr -d ' ' ) || _tw_codecount=0
          fi
          _tw_codecount=${_tw_codecount:-0}
          # 2026-05-28 (review S2): the writes log is blind to Bash-written/committed
          # code, so also count CODE files committed since this session's baseline and
          # take the larger — else a multi-file Bash-only commit reads as 0 and passes
          # the ≤1 triviality check. Mirrors the #2 head-baseline resolution.
          _tw_baseline="$V_TMP_DIR_RESOLVED/head-baseline-${SESSION_ID}.txt"
          [ -f "$_tw_baseline" ] || _tw_baseline="$REPO_ROOT/.v/tmp/head-baseline-${SESSION_ID}.txt"
          [ -f "$_tw_baseline" ] || { [ -n "${TMPDIR:-}" ] && _tw_baseline="${TMPDIR%/}/head-baseline-${SESSION_ID}.txt"; }
          [ -f "$_tw_baseline" ] || _tw_baseline="/tmp/head-baseline-${SESSION_ID}.txt"
          if [ -f "$_tw_baseline" ]; then
            _tw_sh=$(head -1 "$_tw_baseline" 2>/dev/null || true)
            _tw_ch=$(git rev-parse HEAD 2>/dev/null || true)
            if [ -n "$_tw_sh" ] && [ -n "$_tw_ch" ] && [ "$_tw_sh" != "$_tw_ch" ]; then
              _tw_commit_count=$( ( git diff --name-only "${_tw_sh}..${_tw_ch}" 2>/dev/null \
                | grep -E "$CODE_EXT_PATTERN" 2>/dev/null \
                | grep -vE "$CODE_EXT_EXEMPT" 2>/dev/null ) | wc -l | tr -d ' ' ) || _tw_commit_count=0
              [ "${_tw_commit_count:-0}" -gt "$_tw_codecount" ] && _tw_codecount=$_tw_commit_count
            fi
          fi
          # R-07: COSMETIC-classified changes (v-classify-trivial.sh COSMETIC=1) may
          # touch up to 2 UI files — raise the cap for those sessions only.
          # Non-cosmetic TRIVIAL still requires exactly ≤1 code file.
          _tw_is_cosmetic=0
          grep -q '^COSMETIC=1$' "$_trivial_marker" 2>/dev/null && _tw_is_cosmetic=1
          _tw_max_files=1
          [ "$_tw_is_cosmetic" = "1" ] && _tw_max_files=2
          if [ "$_tw_codecount" -gt "$_tw_max_files" ]; then
            _trivial_reject="session writes log shows ${_tw_codecount} code files changed — a TRIVIAL change touches at most ${_tw_max_files} (cosmetic=${_tw_is_cosmetic}), so the TRIVIAL classification is invalid for this multi-file change"
          fi
        fi
        if [ -z "$_trivial_reject" ]; then
          # Trivial workflow satisfied (freshness + triviality independently verified).
          jq -n --arg msg "TRIVIAL workflow accepted: $_trivial_marker" '{"systemMessage":$msg}' 2>/dev/null || true
          # === P1E-TRIVIAL-MARKER (2026-07-03) ===
          # A trivial session exits HERE, before the LAYER-4 telemetry gate — so it used to leave
          # NEITHER a session-log NOR a marker (an invisible hole, the raw-/v class). A full log
          # buys nothing on a ≤3-line change: write the LOUD SESSION_LOG_MISSING marker (the
          # backfill/integrity sweep's own convention) so telemetry sees the session, with zero
          # model turns and no autogen. Skipped if any telemetry already exists.
          if [ -n "${SESSION_ID:-}" ] && [ -n "${REPO_ROOT:-}" ] \
             && [ ! -e "$REPO_ROOT/SESSION_LOG_${SESSION_ID}.yaml" ] \
             && [ ! -e "$REPO_ROOT/SESSION_LOG_MISSING_${SESSION_ID}.md" ]; then
            { echo "# SESSION_LOG_MISSING — ${SESSION_ID}"
              echo ""
              echo "TRIVIAL_PASS session (P1E): full session-log intentionally skipped for a trivial change; marker written by the Stop hook (zero model tokens). Backfill via v-session-log-backfill.sh if this session's telemetry is ever needed."
            } > "$REPO_ROOT/SESSION_LOG_MISSING_${SESSION_ID}.md" 2>/dev/null || true
          fi
          # === end P1E-TRIVIAL-MARKER ===
          exit 0
        else
          echo "[check-review-artifact] TRIVIAL_PASS rejected: ${_trivial_reject}. Run the full gauntlet (/v-pre-flight + agent review + /v-verify-done) or re-classify via v-classify-trivial.sh in THIS invocation." >&2
        fi
      fi
    fi
  done
fi

# === W-LIGHT2-CHORE (2026-08-03): honor the operational commit tags at STOP ===================
# enforce-pre-commit-gates.sh has exempted [v-merge-all] / [v-ci-fix] / [v-chore] from the COMMIT
# gate since W39, but this hook never knew about them — grep it for "v-chore" pre-W-LIGHT2 and you
# get zero hits. The escape was therefore HALF-WIRED: the commit sails through, then Stop blocks on
# the same artifacts the tag was supposed to excuse, and the session is stuck with a committed
# change it cannot finish. Recognise the same three tags here so the escape is end-to-end.
#
# Deliberately strict, because unlike the light tier this verdict IS model-asserted (the tag is a
# string someone types into a commit message):
#   - requires >= 1 session commit — a tag cannot be claimed by a session that committed nothing;
#   - requires EVERY session commit to carry a tag. One untagged code commit ⇒ full gauntlet. On
#     shared main the baseline range can also catch a sibling's untagged commit, which fails SAFE
#     (over-triggering the gauntlet), never open.
if [ -n "${SESSION_ID:-}" ] && [ "${IMPLEMENTATION_ONLY_MODE:-0}" != "1" ]; then
  _chore_baseline=""
  for _cb in "$V_TMP_DIR_RESOLVED/head-baseline-${SESSION_ID}.txt" \
             "$REPO_ROOT/.v/tmp/head-baseline-${SESSION_ID}.txt" \
             "${TMPDIR:-/tmp}/head-baseline-${SESSION_ID}.txt" \
             "/tmp/head-baseline-${SESSION_ID}.txt"; do
    [ -f "$_cb" ] && { _chore_baseline="$_cb"; break; }
  done
  if [ -n "$_chore_baseline" ]; then
    _chore_sh=$(head -1 "$_chore_baseline" 2>/dev/null || true)
    _chore_ch=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
    if [ -n "$_chore_sh" ] && [ -n "$_chore_ch" ] && [ "$_chore_sh" != "$_chore_ch" ]; then
      _chore_total=$(git -C "$REPO_ROOT" log --format='%s' "${_chore_sh}..${_chore_ch}" 2>/dev/null | grep -c . | tr -d ' \n')
      _chore_tagged=$(git -C "$REPO_ROOT" log --format='%s' "${_chore_sh}..${_chore_ch}" 2>/dev/null | grep -cE '\[v-merge-all\]|\[v-ci-fix\]|\[v-chore\]' | tr -d ' \n')
      _chore_total=${_chore_total:-0}; _chore_tagged=${_chore_tagged:-0}
      if [ "$_chore_total" -gt 0 ] && [ "$_chore_tagged" -eq "$_chore_total" ]; then
        jq -n --arg msg "Operational commit-tag workflow accepted: all ${_chore_total} session commit(s) carry [v-chore]/[v-ci-fix]/[v-merge-all] — the same exemption enforce-pre-commit-gates.sh already grants at commit time." '{"systemMessage":$msg}' 2>/dev/null || true
        exit 0
      fi
    fi
  fi
fi
# === end W-LIGHT2-CHORE ======================================================================

# W42-F6: PLANNING workflow bypass.
# /v-plan sessions are planning-only (no code touched, just produce a PLAN_*.md
# document). They should not require PRE_FLIGHT_REPORT, AGENT_REVIEW, or
# VERIFY_DONE_REPORT — there is nothing to test, review, or verify.
# A planning-only session writes PLANNING_PASS_<sid>.md with structured fields
# the orchestrator cannot easily fabricate (PLAN_FILE must reference an existing
# file, FILES_MODIFIED must be exactly 0). The marker must also be ≥80 bytes.
if [ -n "$SESSION_ID" ]; then
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _planning_marker="$_dir/PLANNING_PASS_${SESSION_ID}.md"
    if [ -f "$_planning_marker" ]; then
      _planning_size=$(wc -c < "$_planning_marker" 2>/dev/null | tr -d ' ')
      _plan_file_ref=$(grep '^PLAN_FILE=' "$_planning_marker" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | head -c 256)

      # W42 review HIGH-3: PLAN_FILE name must match pattern PLAN_*_<sid>.md.
      # Reject path traversal (..), absolute paths, and arbitrary .md files.
      _plan_resolved=""
      _plan_basename=""
      if [ -n "$_plan_file_ref" ]; then
        case "$_plan_file_ref" in
          # W44-E2 fix: command substitution \$(printf '\\n') returns empty
          # string because Bash strips trailing newlines from \$() output. The
          # empty pattern then matches everything, blocking ALL plan files.
          # Use \$'\\n' (ANSI-C quoting) which produces a real newline literal.
          /*|*..*|*$'\n'*)
            _plan_resolved=""
            ;;
          *)
            _plan_basename="${_plan_file_ref##*/}"
            if echo "$_plan_basename" | grep -qE "^PLAN_[A-Za-z0-9_-]+\.md$" && \
               echo "$_plan_basename" | grep -qF "$SESSION_ID"; then
              _plan_resolved="$REPO_ROOT/$_plan_file_ref"
            fi
            ;;
        esac
      fi

      # W42 review HIGH-2: do not trust marker's self-reported FILES_MODIFIED.
      # Verify independently via session-writes log. If any file other than the
      # PLAN itself + the PLANNING_PASS marker was written, the marker is invalid.
      _files_changed_real=0
      # W25-F15: use canonical session-writes log path from lib/session-writes.sh.
      # The previous path (.v/tmp/session-writes-${SID}.log) does NOT exist;
      # the canonical path is ${git_common_dir}/claude-session-writes-${SID}.txt
      # written by ~/.claude/hooks/track-session-writes.sh.
      if ! type session_writes_log_path >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh" 2>/dev/null || true
      fi
      if type session_writes_log_path >/dev/null 2>&1; then
        _writes_log_path=$(session_writes_log_path "$SESSION_ID" 2>/dev/null || echo "")
      else
        # Last-resort fallback: match the lib's logic (common-dir for worktrees, else .git)
        _git_dir=$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null \
                   || git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null \
                   || echo "$REPO_ROOT/.git")
        _writes_log_path="${_git_dir}/claude-session-writes-${SESSION_ID}.txt"
      fi
      if [ -f "$_writes_log_path" ]; then
        # W44-E3 fix: under set -euo pipefail, grep -v exits 1 when no
        # lines pass through. Wrap with || true so an empty result == 0.
        _files_changed_real=$( ( grep -v '^$' "$_writes_log_path" 2>/dev/null \
          | sort -u \
          | grep -v -F "$_plan_file_ref" 2>/dev/null \
          | grep -v -F "PLANNING_PASS_${SESSION_ID}.md" 2>/dev/null \
          ) | wc -l | tr -d ' ' ) || _files_changed_real=0
      fi
      _files_changed_real=${_files_changed_real:-0}

      # 2026-05-28 (handoff/B4-1 follow-on): a PLANNING_PASS is valid ONLY for a
      # genuinely code-free session. The prior `_files_changed_real == 0` check read
      # the writes log, which is blind to Bash-written code; gate additionally on the
      # git-aware CODE_CHANGED (now includes committed Bash code via the head-baseline
      # /worktree signals) so a stale planning marker can't rescue a code-shipping
      # session, and add a freshness check (open: only rejects when a start marker
      # exists and this marker predates it).
      if [ "${_planning_size:-0}" -ge 80 ] && \
         grep -q '^PLANNING=1$' "$_planning_marker" 2>/dev/null && \
         grep -q '^PLAN_FILE=' "$_planning_marker" 2>/dev/null && \
         [ -n "$_plan_resolved" ] && [ -f "$_plan_resolved" ] && \
         [ "$_files_changed_real" = "0" ] && \
         [ "$CODE_CHANGED" -eq 0 ] && \
         _marker_is_fresh "$_planning_marker" open; then
        # Planning workflow satisfied (independently verified).
        jq -n --arg msg "PLANNING workflow accepted: $_planning_marker (PLAN: $_plan_basename, files_changed=0 verified independently)" '{"systemMessage":$msg}' 2>/dev/null || \
          printf 'PLANNING workflow accepted: %s\n' "$_planning_marker"
        exit 0
      elif [ "${_planning_size:-0}" -ge 80 ] && grep -q '^PLANNING=1$' "$_planning_marker" 2>/dev/null; then
        echo "[check-review-artifact] PLANNING_PASS rejected: plan_resolved='${_plan_resolved}' files_changed_real=${_files_changed_real} (need 0)" >&2
      fi
    fi
  done
fi

# === CYCLE_CAP_HANDOFF: accept as terminal when retry cap was hit ===
# A CYCLE_CAP_HANDOFF_<sid>.md is written by the orchestrator when the W22-4
# per-class retry cap is exceeded (e.g. 3 pre-flight cycles, 3 review cycles).
# Unlike HANDOFF (abandoned before completion), CYCLE_CAP_HANDOFF is valid even
# when code was shipped — the orchestrator DID work but genuinely cannot clear
# the gate in finite iterations. Accept as terminal (exit 0) if:
#   - file exists and is >= 80 bytes
#   - has "## Cycle Cap Handoff" heading (from the v-agent-review.md template)
#   - is fresh (written in this /v invocation, not a stale leftover)
# Use "closed" freshness: code-shipping bypass path; missing start marker = stale.
if [ -n "$SESSION_ID" ]; then
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _cycle_cap_file="$_dir/CYCLE_CAP_HANDOFF_${SESSION_ID}.md"
    if [ -f "$_cycle_cap_file" ]; then
      _cc_size=$(wc -c < "$_cycle_cap_file" 2>/dev/null | tr -d ' ')
      if [ "${_cc_size:-0}" -ge 80 ] && \
         grep -qE '^## Cycle Cap Handoff' "$_cycle_cap_file" 2>/dev/null && \
         _marker_is_fresh "$_cycle_cap_file" closed; then
        # === NO-DEFER witness (cycle-3 audit 2026-07-04): cross-check the artifact's claim against
        # the counter files that are the actual evidence the cap was hit — the same pattern Bug-6
        # applies to HANDOFF (writes-log) and W39-B to TRIVIAL_PASS. Graduated, never-weakening:
        #   REJECT: artifact declares a cycle_class outside preflight|review|fix (hand-written, no
        #           counter could ever back it), OR the on-disk counter EXISTS and is <= cap (the
        #           cap was provably NOT hit — a contradiction, not missing evidence).
        #   WARN-ACCEPT: counter file absent (V_TMP_DIR is swept by sibling teardowns — absence is
        #           weak evidence; durability class 2026-06-22), or artifact pre-dates the
        #           cycle_class template line. Warns loudly so forensics can audit.
        _cc_class=$(grep -m1 -E '^cycle_class:' "$_cycle_cap_file" 2>/dev/null | sed -E 's/^cycle_class:[[:space:]]*//' | tr -d '[:space:]')
        _cc_cap="${V_CYCLE_CAP:-3}"
        _cc_reject=""
        if [ -n "$_cc_class" ]; then
          case "$_cc_class" in
            preflight|review|fix)
              _cc_ctr_file="$V_TMP_DIR_RESOLVED/cycle-${_cc_class}-${SESSION_ID}.txt"
              if [ -f "$_cc_ctr_file" ]; then
                _cc_ctr=$(tr -cd '0-9' < "$_cc_ctr_file" 2>/dev/null)
                if [ -n "$_cc_ctr" ] && [ "$_cc_ctr" -le "$_cc_cap" ] 2>/dev/null; then
                  _cc_reject="counter-contradiction: cycle-${_cc_class} counter on disk is ${_cc_ctr} (cap ${_cc_cap} not exceeded) — the declared cap-exhaustion never happened"
                elif [ -z "$_cc_ctr" ]; then
                  # QA LOW (2026-07-04): a counter file with NO parseable digits used to fall
                  # through SILENTLY — the one path that violated "reject or warn, never silent".
                  # Unparseable = unverifiable, same epistemic state as absent → same loud warning.
                  echo "[check-review-artifact] CYCLE_CAP_HANDOFF accepted WITH WARNING: cycle-${_cc_class} counter at ${_cc_ctr_file} exists but holds no parseable count (artifact claim unverifiable)" >&2
                fi
              else
                echo "[check-review-artifact] CYCLE_CAP_HANDOFF accepted WITH WARNING: no cycle-${_cc_class} counter at ${_cc_ctr_file} (V_TMP_DIR sweeps make absence weak evidence; artifact claim unverifiable)" >&2
              fi
              ;;
            *)
              _cc_reject="unknown cycle_class '${_cc_class}' (not preflight|review|fix) — no counter can back this artifact"
              ;;
          esac
        else
          echo "[check-review-artifact] CYCLE_CAP_HANDOFF accepted WITH WARNING: no cycle_class: line (pre-template artifact or hand-written; counter cross-check impossible)" >&2
        fi
        if [ -n "$_cc_reject" ]; then
          echo "[check-review-artifact] CYCLE_CAP_HANDOFF found but REJECTED (no-defer witness): ${_cc_reject} — file: ${_cycle_cap_file}. The real gauntlet is still owed; a cap-exhaustion handoff must be backed by its cycle counter." >&2
        else
          jq -n --arg msg "Cycle-cap handoff accepted: ${_cycle_cap_file} (size=${_cc_size})" \
             '{"systemMessage":$msg}' 2>/dev/null || true
          exit 0
        fi
      else
        # item-28 hygiene: `grep -c ... || echo 0` double-prints "0\n0" when the count is
        # legitimately 0 (grep -c prints "0" AND exits 1, tripping the `|| echo 0` fallback
        # too). Capture once, default via ${:-0}, so this diagnostic line stays single-valued.
        _cc_heading_count=$(grep -cE '^## Cycle Cap Handoff' "$_cycle_cap_file" 2>/dev/null)
        echo "[check-review-artifact] CYCLE_CAP_HANDOFF found but rejected: size=${_cc_size:-0} heading=${_cc_heading_count:-0} fresh=$(_marker_is_fresh "$_cycle_cap_file" closed && echo yes || echo no)" >&2
      fi
    fi
  done
fi
# === CYCLE_CAP_HANDOFF end ===


if [ "$IMPLEMENTATION_ONLY_MODE" = "1" ]; then
  MISSING_IMPLEMENTATION=0

  if [ -n "$SESSION_ID" ]; then
    IMPLEMENTATION_FILE=$(find_session_artifact "IMPLEMENTATION_REPORT" || true)
  else
    MISSING_IMPLEMENTATION=1
  fi

  if [ "$MISSING_IMPLEMENTATION" -eq 0 ] && ! validate_implementation_report "$IMPLEMENTATION_FILE" 2>/dev/null; then
    MISSING_IMPLEMENTATION=1
  fi

  if [ "$MISSING_IMPLEMENTATION" -eq 1 ]; then
    # W42-F1: stderr text + exit 2 is sufficient for Stop blocking; drop
    # invalid hookSpecificOutput JSON shape (Stop has no variant per schema).
    CTX="COMPLETION BLOCKED — runner-managed implementation-only session is missing a valid IMPLEMENTATION_REPORT_${SESSION_ID}.md artifact. Write IMPLEMENTATION_REPORT with finding disposition, files changed, and lightweight checks run. PRE_FLIGHT_REPORT, AGENT_REVIEW, and VERIFY_DONE_REPORT are owned by the external remediation runner for this session."
    if _cra_block_gate "$CTX"; then
      printf '%s\n' "$CTX" >&2
      exit 2
    fi
    exit 0  # W5G-1 deadlock escape (warning already on stderr)
  fi

  exit 0
fi

# W34 Layer 2: SID-fabrication detector.
#
# Production failure (2026-05-02): bootstrap resolved a stale
# SID from a poisoned runtime file. Real artifacts were filed under
# the stale SID. This Stop hook expected the canonical SID (from hook input)
# and forced the orchestrator to fabricate replacement artifacts under the
# canonical SID — corrupting the audit trail.
#
# Detection heuristic: if BOTH conditions hold, the canonical-SID artifacts
# look fabricated:
#   1. PRE_FLIGHT_REPORT_<otherSID>.md exists in the repo (a different real session's report)
#   2. PRE_FLIGHT_REPORT_<canonicalSID>.md was written within the last 60 sec
#      (mtime), AND the file is under 4 KB (real reports are 8-40 KB)
# The 60-second + size threshold reduces false positives — legitimate report
# regeneration after a real /v session is much larger.

# W34/W35-followup tightening (review-driven):
#   B1: false-positive on legit small reports — add content check requiring
#       absence of "## Gates" header (real reports have it, fabrications don't).
#       AND require canonical file to be NEWER than the "other" — only fires
#       when the canonical was just-Written while a pre-existing other exists.
#   C1: extend coverage to AGENT_REVIEW + VERIFY_DONE_REPORT.
#   E2: fall back to REPO_ROOT (already resolved) when CLAUDE_PROJECT_DIR is empty.

# E2: fall back to REPO_ROOT when CLAUDE_PROJECT_DIR is unset.
_W34_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${REPO_ROOT:-}}"

if [ -n "$SESSION_ID" ] && [ -n "$_W34_PROJECT_DIR" ] && [ -d "$_W34_PROJECT_DIR" ]; then
  _w34_check_artifact() {
    local artifact_kind="$1"   # PRE_FLIGHT_REPORT | AGENT_REVIEW | VERIFY_DONE_REPORT
    local content_marker="$2"  # markdown anchor that real artifacts contain (e.g., "## Gates")
    local size_floor="$3"      # bytes; canonical file under this WITH no content_marker = suspicious
    local _canonical="$_W34_PROJECT_DIR/${artifact_kind}_${SESSION_ID}.md"
    [ -f "$_canonical" ] || return 0

    _now=$(date +%s)
    _c_mtime=$(stat -c %Y "$_canonical" 2>/dev/null || stat -f %m "$_canonical" 2>/dev/null || echo 0)
    _c_size=$(stat -c %s "$_canonical" 2>/dev/null || stat -f %z "$_canonical" 2>/dev/null || echo 0)
    local _c_age=$(( _now - _c_mtime ))

    # Find other-SID artifact of same kind. Prefer pre-existing (older than canonical).
    local _other
    _other=$(find "$_W34_PROJECT_DIR" -maxdepth 1 -name "${artifact_kind}_*.md" -not -name "${artifact_kind}_${SESSION_ID}.md" 2>/dev/null | head -1)
    [ -z "$_other" ] && return 0

    _o_mtime=$(stat -c %Y "$_other" 2>/dev/null || stat -f %m "$_other" 2>/dev/null || echo 0)

    # Fire only when:
    #   1. canonical is fresh (< 60s old) — just Written
    #   2. canonical is small (< size_floor) — indicates hand-crafted, not real
    #   3. canonical does NOT contain the content marker — confirms fabrication
    #   4. other is OLDER than canonical — i.e., other is the pre-existing real one
    if [ "$_c_age" -lt 60 ]        && [ "$_c_size" -lt "$size_floor" ]        && ! grep -qF "$content_marker" "$_canonical" 2>/dev/null        && [ "$_o_mtime" -lt "$_c_mtime" ]; then
      local _other_sid
      _other_sid=$(basename "$_other" | sed "s/${artifact_kind}_//;s/\.md$//")
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ W34: SID-fabrication detected — ${artifact_kind} for session ${SESSION_ID}.

     A small ${artifact_kind}_${SESSION_ID}.md (size=${_c_size}b, age=${_c_age}s, missing '${content_marker}' marker) was just Written, while a pre-existing real artifact exists at:
       $_other
     (real-session SID: $_other_sid, mtime older than canonical)

     This is the fabrication pattern: bootstrap got a stale SID, real /v artifacts went under that SID, and the orchestrator hand-crafted a replacement under the canonical SID to satisfy this hook.

     ACTION REQUIRED: Do NOT continue with fabricated artifacts.
       1. Check ~/.claude/runtime/current-session-id mtime — likely stale (> 2h).
       2. Restart your Claude Code session. SessionStart hooks refresh the runtime file.
       3. Re-run /v. Real gate results will land under the canonical SID."
    fi
  }

  # Cover all three artifact kinds. Size thresholds chosen from real-world report
  # sizes: PRE_FLIGHT typically 8-40 KB, AGENT_REVIEW 1-10 KB, VERIFY_DONE 2-15 KB.
  # Each "size_floor" is the lower bound below which a missing-content-marker file
  # is suspect.
  _w34_check_artifact "PRE_FLIGHT_REPORT" "## Gates" 1024
  _w34_check_artifact "AGENT_REVIEW" "## Findings" 512
  _w34_check_artifact "VERIFY_DONE_REPORT" "Overall" 512
fi

if [ -n "$SESSION_ID" ]; then
  PREFLIGHT_FILE=$(find_session_artifact "PRE_FLIGHT_REPORT" || true)
  REVIEW_FILE=$(find_session_artifact "AGENT_REVIEW" || true)
  VERIFY_DONE_FILE=$(find_session_artifact "VERIFY_DONE_REPORT" || true)
else
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ Session ID is missing. Session-bound artifact validation cannot run."
fi

# === W-LIGHT2 (2026-08-03): light-tier verdict, hoisted and memoized ==========================
# P1B computed the light verdict INLINE inside the QA gate, so it could only ever waive QA. The
# tier is now the middle lane it was meant to be — PRE_FLIGHT (scoped) + ONE review, per CLAUDE.md
# § "Small/trivial exception" — which means FOUR gates need the same verdict: VERIFY_DONE,
# the gauntlet witness, IMPACT_MAP and QA. Hoisted here (before the first of them) and memoized so
# the classifier runs at most once per Stop, not four times.
#
# The verdict stays DIFF-SHAPE-DERIVED at enforcement time — this hook re-runs the classifier
# itself, it never reads a model-written marker. A session cannot assert its way into this lane;
# it has to actually have a small, non-UI, non-migration, security-clear diff.
#
# SCOPE GUARD (inherited from P1B, and it applies to all four call sites): light skips the
# DISPATCH of a gate, it NEVER overrides a gate's verdict. Every caller must check that the
# artifact is ABSENT before consulting this — a PRESENT artifact that FAILS still blocks.
_LIGHT_TIER_MEMO=""
_light_tier_is_active() {
  if [ -z "$_LIGHT_TIER_MEMO" ]; then
    _LIGHT_TIER_MEMO="no"
    local _lt_script _lt_out
    _lt_script="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
    if [ -f "$_lt_script" ]; then
      _lt_out=$(CLAUDE_SESSION_ID="$SESSION_ID" REPO_ROOT="$REPO_ROOT" bash "$_lt_script" 2>/dev/null || true)
      if printf '%s\n' "$_lt_out" | grep -q '^LIGHT=1'; then
        _LIGHT_TIER_MEMO="yes"
        LIGHT_TIER_FILES=$(printf '%s\n' "$_lt_out" | sed -n 's/^FILES=//p' | head -1)
        LIGHT_TIER_LINES=$(printf '%s\n' "$_lt_out" | sed -n 's/^LINES=//p' | head -1)
        LIGHT_TIER_CLASS=$(printf '%s\n' "$_lt_out" | sed -n 's/^CLASS=//p' | head -1)
      fi
    fi
    # Classifier absent ⇒ memo stays "no" ⇒ full gauntlet. Fail-safe direction, matching the
    # classifier's own fail-CLOSED behaviour when its pattern libs are missing.
  fi
  [ "$_LIGHT_TIER_MEMO" = "yes" ]
}
# Human-readable suffix for the waiver warnings, so a light completion says WHY it was light.
_light_tier_detail() {
  printf 'files=%s, lines=%s, class=%s' \
    "${LIGHT_TIER_FILES:-?}" "${LIGHT_TIER_LINES:-?}" "${LIGHT_TIER_CLASS:-?}"
}
# === end W-LIGHT2 hoist ======================================================================

# === W-MEDIUM (2026-08-03): medium-tier verdict, hoisted =====================================
# The THIRD tier. LIGHT's allow-list admits build/tooling config + config/routes/Support/Helpers
# only, so NO application-code diff can ever reach it — an ordinary 5-file service change fell
# straight into the full 6-artifact gauntlet. CLAUDE.md § Routing already defines the missing
# middle ("Ordinary code changes (4–10 files, no hostile path): targeted tests + the full suite
# ONCE at the end, scoped lint/typecheck, ONE adversarial review pass") but nothing enforced it.
#
# FORENSIC (2026-08-03): a content-only fix — no hostile path, no UI, no migration —
# ran 76.5 min, of which ~6 min was engineering. It owed the full gauntlet because LIGHT
# returned `path_class_not_light:app/Http/Controllers/ExampleController.php`. IMPACT_MAP cost
# ~4 min and returned ZERO findings (all-'no'-with-reasons — the documented correct output for an
# isolated change).
#
# DELIBERATELY NARROW. This waives IMPACT_MAP and nothing else. QA_REPORT is NOT waived on this
# tier (operator instruction 2026-08-03: keep the QA pass, remove the NEED for repeat iterations
# — that is W-QASCALE's measurement-validity rule in v-qa-acceptance.md, not a waiver).
# PRE_FLIGHT, AGENT_REVIEW, VERIFY_DONE and the gauntlet witness all remain required.
#
# SCOPE GUARD (inherited from P1B): medium skips the DISPATCH of a gate, it NEVER overrides a
# gate's verdict — the call site must confirm the artifact is ABSENT before consulting this.
_MEDIUM_TIER_MEMO=""
_medium_tier_is_active() {
  if [ -z "$_MEDIUM_TIER_MEMO" ]; then
    _MEDIUM_TIER_MEMO="no"
    local _mt_script _mt_out
    _mt_script="${V_MEDIUM_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-medium-tier.sh}"
    if [ -f "$_mt_script" ]; then
      _mt_out=$(CLAUDE_SESSION_ID="$SESSION_ID" REPO_ROOT="$REPO_ROOT" bash "$_mt_script" 2>/dev/null || true)
      if printf '%s\n' "$_mt_out" | grep -q '^MEDIUM=1'; then
        _MEDIUM_TIER_MEMO="yes"
        MEDIUM_TIER_FILES=$(printf '%s\n' "$_mt_out" | sed -n 's/^FILES=//p' | head -1)
        MEDIUM_TIER_LINES=$(printf '%s\n' "$_mt_out" | sed -n 's/^LINES=//p' | head -1)
      fi
    fi
    # Classifier absent ⇒ memo stays "no" ⇒ full gauntlet. Fail-safe direction, matching both
    # the LIGHT hoist and the classifier's own fail-CLOSED behaviour on a missing pattern lib.
  fi
  [ "$_MEDIUM_TIER_MEMO" = "yes" ]
}
_medium_tier_detail() {
  printf 'files=%s, lines=%s' "${MEDIUM_TIER_FILES:-?}" "${MEDIUM_TIER_LINES:-?}"
}
# === end W-MEDIUM hoist ======================================================================

MISSING_PREFLIGHT=0
MISSING_REVIEW=0
MISSING_VERIFY=0

if [ -z "$PREFLIGHT_FILE" ]; then
  MISSING_PREFLIGHT=1
else
  # AVF-004: Structural validation (size + required section headers)
  if type validate_artifact >/dev/null 2>&1; then
    if ! validate_artifact "$PREFLIGHT_FILE" "PRE_FLIGHT_REPORT" 2>/dev/null; then
      MISSING_PREFLIGHT=1
    fi
  fi
  # F8-b (Item 13, content-check revision): a pure byte-count floor false-alarms on an
  # honestly-short PRE_FLIGHT_REPORT (e.g. an all-SKIP or TRIVIAL-path report — 33 SKIP rows in
  # a table is legitimately < 1024B). The ORIGINAL bug this guards (W3-31: a 960B report
  # generated from the skills repo that said FAIL for another project) was a wrong-project stub, not a
  # merely-short one — the distinguishing signal is CONTENT, not size: a real gate report has an
  # actual gate table (a "| ... | PASS/FAIL/SKIP/INCONCLUSIVE |" row) or an explicit
  # "Overall Status:" verdict line. Block ONLY when BOTH small AND missing that content;
  # small-but-content-bearing reports get a warning instead of a false block.
  if [ "$MISSING_PREFLIGHT" -eq 0 ] && [ -n "$PREFLIGHT_FILE" ] && [ -f "$PREFLIGHT_FILE" ]; then
    _pf_size=$(wc -c < "$PREFLIGHT_FILE" 2>/dev/null | tr -d ' ')
    _pf_has_gate_content=0
    if grep -qiE '^\|.*\|[[:space:]]*(PASS|FAIL|SKIP|INCONCLUSIVE)[[:space:]]*\|' "$PREFLIGHT_FILE" 2>/dev/null \
       || grep -qiE '^[[:space:]#>*-]*\**[[:space:]]*overall[[:space:]]*(status)?:' "$PREFLIGHT_FILE" 2>/dev/null; then
      _pf_has_gate_content=1
    fi
    # === W-PF-SIZE BEGIN (2026-08-05) — size branches all honour _pf_has_gate_content ===
    # The <1024B branch has always consulted _pf_has_gate_content; the 1024..3000B branch ignored
    # it and warned on byte count alone. Measured: 11 of 11 reports in that band carried 6-10 real
    # gate rows — a 100% false-positive rate, 96 emissions across 25 sessions. The predicate the
    # hook already computes is the correct one; this just applies it consistently.
    # Bite: hooks/stop-advisory-hardening-test.sh (T9-T14).
    if [ "${_pf_size:-0}" -lt 1024 ] && [ "$_pf_has_gate_content" -eq 0 ]; then
      echo "[check-review-artifact] F8-b: PRE_FLIGHT_REPORT too small (${_pf_size}B < 1024B) and missing a gate-table/Overall-Status content marker — likely a stub or generated from the wrong project." >&2
      MISSING_PREFLIGHT=1
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT is too small (${_pf_size}B < 1024B minimum) AND has no gate-table row or 'Overall Status:' line — likely a stub or generated from the wrong project (the W3-31 incident produced a 960B report from the skills repo that said FAIL for another project). Real gate reports for a Laravel+React project are 3-40 KB. Re-run /v-pre-flight from the correct project root."
    elif [ "${_pf_size:-0}" -lt 1024 ]; then
      WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT is small (${_pf_size}B < 1024B) but contains a genuine gate-table row or 'Overall Status:' line — treated as a legitimately short report (e.g. all-SKIP/TRIVIAL path), not blocked on size alone (Item 13 content-check revision)."
    elif [ "${_pf_size:-0}" -lt 3000 ] && [ "$_pf_has_gate_content" -eq 0 ]; then
      WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT is small (${_pf_size}B, between 1024B and 3000B) AND carries no gate-table row or 'Overall Status:' line. Verify this is a complete gate report and not a partial or wrong-project artifact."
    fi
    # === W-PF-SIZE END ===
    # Item 9 (2026-07-05): "blind-preflight" gap. v-run-gates.sh's F1 blind-scope guard (v-run-gates.sh
    # ~line 393) only fires under scoped/dirty-tree/POSTMERGE_REVERIFY modes — a FULL-mode run that
    # skips every gate for an UNRELATED reason (missing deps, wrong project root, stack misdetection)
    # never trips it, and the F8-b/Item-13 check above only catches a SMALL report, not a large,
    # well-formed one whose every row is SKIP. A session that committed real source changes
    # (CODE_CHANGED=1) but whose gate table contains not a single PASS or FAIL row — only
    # SKIP/SKIPPED/INCONCLUSIVE/ADVISORY/NOT_EVALUATED — validated NOTHING; that must never be
    # presented as "Overall Status: PASS". Fires only when the table has real status rows (avoids
    # double-firing with F8-b, which already blocks content-free reports) and at least one row exists,
    # so a legitimate report (which always has ≥1 PASS/FAIL for the gates relevant to the diff) never
    # false-positives here.
    if [ "$MISSING_PREFLIGHT" -eq 0 ] && [ "${CODE_CHANGED:-0}" -eq 1 ] && [ -n "$PREFLIGHT_FILE" ] && [ -f "$PREFLIGHT_FILE" ] \
       && grep -qiE '^\|.*\|[[:space:]]*(PASS|FAIL|SKIP|SKIPPED|INCONCLUSIVE|ADVISORY|NOT_EVALUATED)[[:space:]]*\|' "$PREFLIGHT_FILE" 2>/dev/null \
       && ! grep -qiE '^\|.*\|[[:space:]]*(PASS|FAIL)[[:space:]]*\|' "$PREFLIGHT_FILE" 2>/dev/null \
       && grep -qiE '^[[:space:]#>*-]*\**[[:space:]]*overall[[:space:]]*(status)?:[[:space:]]*\**[[:space:]]*PASS' "$PREFLIGHT_FILE" 2>/dev/null; then
      echo "[check-review-artifact] Item 9: PRE_FLIGHT_REPORT has a real gate table but EVERY row is SKIP/INCONCLUSIVE/ADVISORY (no PASS or FAIL row) while this session committed source changes (CODE_CHANGED=1) and the report still claims Overall Status: PASS." >&2
      MISSING_PREFLIGHT=1
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT (Item 9 blind-preflight gap): this session committed source changes (CODE_CHANGED=1) but every gate-table row is SKIP/SKIPPED/INCONCLUSIVE/ADVISORY/NOT_EVALUATED — no gate actually PASSED or FAILED — while the report still claims 'Overall Status: PASS'. A blind pre-flight (nothing was actually validated) must never be presented as a clean pass. Re-run /v-pre-flight in FULL mode from the correct project root and verify at least the gates relevant to the changed file types produce a real PASS/FAIL."
    fi
  fi
fi

# === W71 GATE-INDEPENDENCE PROVENANCE — hoisted above the AGENT_REVIEW gate (fix: 2026-06-02) ===
# _agent_was_dispatched / _independence_verdict (and the transcript-signal prep they read) MUST
# be defined before their FIRST call site, which is the AGENT_REVIEW C3b check immediately below.
# They were previously defined ~250 lines lower (just above the IMPACT_MAP gate), so the
# AGENT_REVIEW call resolved to a bash 'command not found', the case fell through, MISSING_REVIEW
# stayed 0, and orchestrator-inline self-reviews with no superpowers attempt were SILENTLY
# accepted on every code-changing session (forensics: three sessions,
# each showing "line 981: _independence_verdict: command not found"). The QA/UX/WORKFLOW/
# PRE_FLIGHT callers further down already sat after the old definitions and were unaffected;
# this hoist makes the AGENT_REVIEW caller behave identically to them.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  TRANSCRIPT_PATH=$(ls -1t "$HOME/.claude/projects"/*/"${SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)
fi
TRANSCRIPT_READABLE=0
[ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] && TRANSCRIPT_READABLE=1

# Single-pass the (potentially multi-MB) transcript ONCE into a compact buffer of the signals the
# independence checks + model guard need: dispatch subagent_types, v-dispatch-subagent.sh --agent
# invocations, and every model value. Built only for code-changing sessions with a readable transcript.
_TX_SIGNALS=""
if [ "$TRANSCRIPT_READABLE" -eq 1 ] && [ "$CODE_CHANGED" -eq 1 ]; then
  _TX_SIGNALS=$(grep -hoE '"subagent_type":"[^"]*"|v-dispatch-subagent\.sh[^"]{0,80}--agent[ ="]+[A-Za-z0-9_-]+|"model":"[^"]*"' "$TRANSCRIPT_PATH" 2>/dev/null || true)
  # O1 (forensic): also harvest INDEPENDENCE signals (subagent_type / --agent) from the session's
  # subagents/ tree. A BACKGROUND Agent-tool reviewer dispatch records its subagent_type ONLY there — not
  # the parent transcript, and with NO DISPATCH_PROVENANCE — so a parent-only scan was BLIND to 9 genuinely-
  # independent reviewers and forced the orchestrator into false 'degraded-inline' declarations + hand-
  # authored artifacts (the whole cascade). Path-scoped by SID → a real, not-self-forgeable signal.
  # Model signals are deliberately NOT harvested from the subtree (a subagent's model must not misattribute
  # the orchestrator's cost-lane in the non-blocking MODEL POLICY warning). Parity: validation.sh
  # _prep_independence_signals builds _TX_SIGNALS identically.
  # SID-glob ALL project slugs (NOT parent-relative `${TRANSCRIPT_PATH%.jsonl}/subagents`): a WORKTREE
  # session's subagents can live under a DIFFERENT project slug than the parent transcript (agents
  # dispatched while cwd=worktree). Parent-relative derivation would miss them and the Stop gate would
  # STILL block a genuinely-reviewed worktree session — re-triggering that cascade at the Stop gate
  # (codex CODEX-001). This mirrors _prep_independence_signals' SID-glob exactly so the two gates stay in parity.
  for _txsub in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"/*/"${SESSION_ID}"/subagents/*.jsonl; do
    [ -f "$_txsub" ] && _TX_SIGNALS="$_TX_SIGNALS
$(grep -hoE '"subagent_type":"[^"]*"|v-dispatch-subagent\.sh[^"]{0,80}--agent[ ="]+[A-Za-z0-9_-]+' "$_txsub" 2>/dev/null || true)"
  done
fi

# === W71 GATE-INDEPENDENCE PRIMITIVES (single-sourced 2026-06-15) =========================
# _agent_was_dispatched / _artifact_postdispatch_edited / _independence_verdict now live in
# hooks/lib/validation.sh (sourced above), so THIS Stop hook AND the producer-side
# v-completion-selfcheck.sh run the IDENTICAL independence verdict and can never disagree —
# the drift that let an earlier incident's fabricated 'Dispatch mode: subagent-dispatched'
# AGENT_REVIEW pass the self-check while this hook blocked it. The functions read the globals
# set just above: SESSION_ID, ARTIFACT_SEARCH_DIRS, TRANSCRIPT_READABLE, _TX_SIGNALS.
# Parity is locked by skills/v/references/v-completion-parity-test.sh.

if [ -z "$REVIEW_FILE" ]; then
  MISSING_REVIEW=1
else
  # AVF-004: Structural validation first, then semantic check
  if type validate_artifact >/dev/null 2>&1; then
    if ! validate_artifact "$REVIEW_FILE" "AGENT_REVIEW" 2>/dev/null; then
      MISSING_REVIEW=1
    fi
  fi
  if [ "$MISSING_REVIEW" -eq 0 ]; then
    # 5th arg 1 = allow honest-degraded (O2): this gate ALSO runs _independence_verdict below, which marks a
    # declared-inline review `declared`→warn and still blocks a forged "codex ran" (silent) — so relaxing the
    # codex-name requirement here cannot launder an unreviewed commit (codex CODEX-001).
    if ! REVIEW_SEMANTIC_ERROR=$(validate_review_semantics "$REVIEW_FILE" 1 "$HOSTILE_REVIEW_REQUIRED" "$SESSION_ID" 1 2>/dev/null); then
      MISSING_REVIEW=1
    fi
  fi
fi

# C3b: Independence verdict for AGENT_REVIEW — apply the same _independence_verdict
# machinery already used for PRE_FLIGHT_REPORT / QA_REPORT / UX_CRITIQUE / WORKFLOW_VERIFICATION.
# Root cause (AGENT_REVIEW_859): codex exec failed with stdin-EOF on a long diff → fell back to
# orchestrator-inline → labeled plain APPROVED with no degradation signal. An orchestrator that
# reviews its own diff is not an independent reviewer. Scoped to "review passed structural+semantic
# checks" (MISSING_REVIEW=0) — already-blocked reviews don't need this additional gate.
if [ "$MISSING_REVIEW" -eq 0 ] && [ -n "${REVIEW_FILE:-}" ]; then
  case "$(_independence_verdict "$REVIEW_FILE" codex-adversarial-reviewer)" in
    dispatched)
      : ;; # independent subprocess ran — OK
    edited)
      # W5G-4: dispatched, then silently modified (provenance sha256 mismatch).
      MISSING_REVIEW=1
      REVIEW_SEMANTIC_ERROR="was modified AFTER its independent dispatch (on-disk content no longer matches the sha256 the dispatcher recorded in DISPATCH_PROVENANCE). The reviewer's output is the canonical artifact — silent post-hoc edits break the independence chain (prod sessions hand-edited dispatched gate artifacts under a 'Model: haiku' header). Resolve by ONE of: (a) re-dispatch the reviewer so its output is canonical, (b) if the edit was a legitimate correction, add a 'Post-dispatch edit: <what and why>' line to the artifact — the gate then treats it as a declared (warned) fallback" ;;
    edited-declared)
      # F2 (2026-08-29): a REAL independent dispatch is on record, the artifact was edited
      # afterward, the edit is declared, and the dispatched original survives. Before the token
      # split this landed in `declared)` below, whose N5 branch demands a "superpowers fallback
      # attempted" line — i.e. it accused an honestly-declared, genuinely-reviewed artifact of
      # having skipped the fallback chain. The N5 requirement exists for the NO-dispatch case and
      # is meaningless here; do not re-apply it. Tamper protection is unchanged: an UNdeclared
      # edit is still `edited` (blocks), and a declared edit whose original was destroyed is also
      # still `edited` (ORCHFIX-E4).
      # F2-B1MIRROR (adversarial review PANEL-SECURITY-002, 2026-08-29). DO NOT DELETE without
      # replacing it. PRE_FLIGHT has its own B1 verdict-flip guard; AGENT_REVIEW has none, and the
      # I1 tamper-baseline guards on QA/WORKFLOW do NOT cover this token (they are gated on
      # `! _provenance_baseline_exists`, which is always false once `_artifact_postdispatch_edited`
      # has fired — see the WORKFLOW arm). So for AGENT_REVIEW, QA and WORKFLOW alike, THIS shared
      # check is the only content control on the path. Before the F2 token split, this
      # shape landed in `declared)`, whose N5 branch demanded a "superpowers fallback attempted"
      # line — which a genuinely-dispatched review has no reason to carry — so it BLOCKED by
      # accident. Making `edited-declared` warn-only removes a false accusation, but it would also
      # have removed that incidental block: a real reviewer returns CRITICAL findings, the
      # orchestrator edits the artifact to APPROVED, adds a bare `Post-dispatch edit:` line, and
      # passes with a warning. That is a gate that closes today opening tomorrow, which the
      # governing constraint forbids — so mirror B1's shape here: a declared post-dispatch edit may
      # fix PROSE, but disclosing a changed finding/verdict/severity BLOCKS.
      # Narrow by construction: it fires only inside the already-narrow dispatched+edited+declared
      # branch, and only on an explicit disclosure of a verdict/finding change.
      if _declared_edit_discloses_verdict_change "$REVIEW_FILE"; then
        MISSING_REVIEW=1
        REVIEW_SEMANTIC_ERROR="was edited AFTER its independent dispatch and the edit DISCLOSES a changed finding/verdict/severity. A declared post-dispatch edit may correct prose or formatting, but it must NOT alter what the independent reviewer concluded — the reviewer's output is the canonical artifact (this is the AGENT_REVIEW analogue of the PRE_FLIGHT B1 guard; a forensic case did exactly this to a WORKFLOW_VERIFICATION). Resolve by ONE of: (a) RE-DISPATCH the reviewer so a fresh verdict is canonical, (b) restore the reviewer's original finding and record your disagreement in a SEPARATE AGENT_REVIEW_ADDENDUM_${SESSION_ID}.md with its own provenance, (c) if the finding was genuinely invalid, say so in the addendum rather than editing the dispatched artifact in place"
      else
        WARNINGS="$WARNINGS
  ⚠️ AGENT_REVIEW was edited after its independent dispatch and the edit is DECLARED ('Post-dispatch edit:'). The reviewer dispatch IS on record and the dispatched original survives (see .v/archive/<session>/) — independence is intact and NO re-dispatch is required. Keep post-dispatch edits to prose/formatting: they must never change a finding or a verdict."
      fi ;;
    declared)
      # N5: 'declared' is only an accepted fallback when the mandatory fallback chain was
      # actually attempted. CLAUDE.md: "codex not installed is not an excuse, the superpowers
      # fallback exists." Same applies to "not compatible with worktree context". If the
      # AGENT_REVIEW mentions superpowers/requesting-code-review, accept with a warning.
      # If it doesn't, the chain was skipped → treat as silent (one session: "codex not compatible
      # with worktree branch context" declared inline without ever trying superpowers).
      # W5F-6 (forensic 2026-06-06): a bare superpowers MENTION is not an attempt. All five
      # wave-1 pack sessions declared inline with "codex/superpowers unavailable" while codex
      # demonstrably worked on this machine the same day — zero captured no-attempt evidence
      # anywhere. Require the superpowers line to state an attempt OUTCOME (attempted / returned
      # / failed / not installed / unknown skill / timed out / rc=N), i.e. evidence the chain was
      # actually exercised, not merely name-checked. Existing honest fixtures all carry one.
      if grep -iE 'superpowers|requesting.code.review' "$REVIEW_FILE" 2>/dev/null \
         | grep -qiE 'attempt|tried|returned|failed|error|unavailable|not[[:space:]]+installed|unknown[[:space:]]+skill|timed?[[:space:]]?out|no[[:space:]]+reviewer|rc=[0-9]|exit[[:space:]]?(code|status)?[[:space:]]?[0-9]|fell[[:space:]]+back'; then
        WARNINGS="$WARNINGS
  ⚠️ AGENT_REVIEW declares degraded fallback (superpowers was attempted). Accepted; prefer independent codex-adversarial-reviewer dispatch. Capture the failing codex/superpowers command output verbatim in the artifact so the unavailability claim is auditable (W5F-6)."
      else
        MISSING_REVIEW=1
        REVIEW_SEMANTIC_ERROR="declares inline without documenting a superpowers:requesting-code-review attempt — the mandatory fallback chain was skipped. Policy: codex unavailability (including 'not compatible with worktree context') requires a superpowers:requesting-code-review attempt before inline is accepted. Add 'superpowers fallback attempted: <result>' to the AGENT_REVIEW, or dispatch an independent reviewer. (a prior session: inline declared without superpowers attempt; subsequent codex run found HIGH/MEDIUM findings the inline missed.)"
      fi ;;
    unverifiable)
      WARNINGS="$WARNINGS
  ⚠️ AGENT_REVIEW independence could not be verified (session transcript unavailable). Ensure codex-adversarial-reviewer was dispatched independently." ;;
    silent)
      # A silent AGENT_REVIEW (orchestrator self-review with no codex-adversarial provenance) → (=BLOCK)
      # trust violation. FIX-6: distinguish a FORGED dispatch claim from an undisclosed honest inline so the
      # remediation wording is correct — single-sourced via _independence_silent_reason so this gate and
      # v-completion-selfcheck.sh print the SAME message (parity). Verdict stays 'silent'(block) both branches.
      MISSING_REVIEW=1
      if [ "$(_independence_silent_reason "$REVIEW_FILE")" = "claimed-dispatch" ]; then
        REVIEW_SEMANTIC_ERROR="claims a dispatch mode ('Dispatch mode: subagent-dispatched|foreground|background' or 'codex … ran') but NO provenance backs it — no DISPATCH_PROVENANCE record and no transcript subagent_type for the claimed reviewer. A claimed-but-unproven independent dispatch is a forged independence claim, not honest degradation. Either dispatch the reviewer for real via v-dispatch-subagent.sh (so provenance exists), or STOP claiming a dispatch and declare the inline fallback honestly with 'Dispatch mode: orchestrator-inline (reason)'. (AGENT_REVIEW_859: fabricated 'subagent-dispatched' with no evidence.)"
      else
        REVIEW_SEMANTIC_ERROR="appears to be an orchestrator-inline self-review with no honest disclosure (no independent codex-adversarial-reviewer dispatch found — no DISPATCH_PROVENANCE record, no transcript subagent_type=codex-adversarial-reviewer, and no 'Dispatch mode: orchestrator-inline' / 'dispatch: degraded-inline' declaration in the artifact). An orchestrator reviewing its own diff is not an independent reviewer. Declare the fallback explicitly with 'Dispatch mode: orchestrator-inline (reason)' so _independence_verdict returns 'declared' (not 'silent'), OR dispatch an independent reviewer via v-dispatch-subagent.sh. (C3b fix.)"
      fi ;;
  esac
fi

if [ -z "$VERIFY_DONE_FILE" ]; then
  MISSING_VERIFY=1
  # W-LIGHT2: waive the verify-done DISPATCH on a light-tier diff. Only reachable when the
  # artifact is ABSENT — the else-branch below (structural validation) and the P0a verdict gate
  # further down are untouched, so a PRESENT verify-done that is malformed or says
  # 'Overall Verdict: FAIL' still blocks exactly as before.
  if [ "${CODE_CHANGED:-0}" -eq 1 ] && _light_tier_is_active; then
    MISSING_VERIFY=0
    WARNINGS="$WARNINGS
  ⚠️ VERIFY_DONE_REPORT waived: LIGHT-TIER diff shape verified at enforcement time ($(_light_tier_detail)). Pre-flight + agent review remain required."
  fi
else
  # AVF-004: Structural validation
  if type validate_artifact >/dev/null 2>&1; then
    if ! validate_artifact "$VERIFY_DONE_FILE" "VERIFY_DONE_REPORT" 2>/dev/null; then
      MISSING_VERIFY=1
    fi
  fi
fi

# P0a (forensic 2026-06-17): VERIFY_DONE VERDICT + boundary gate.
# Root cause: the Stop hook only PRESENCE-checked VERIFY_DONE (validate_artifact = size + a
# '## '/'Overall:'/'Status:'/'Model:' content marker). validate_verify_done_w53_contract PARSES
# the verdict but was never wired in here. So a VERIFY_DONE whose final line is
# 'Overall Verdict: FAIL' (with FND-BND boundary violations) passed the gate — one session committed
# 4 files OUTSIDE its declared FILE BOUNDARY, verify-done correctly said FAIL, and the session
# COMPLETED anyway. Promote the verdict to a BLOCK. Recoverable by design: resolve the violations
# and re-run /v-verify-done so the report converges to PASS (NOT by hand-editing the verdict).
# ND-0716 (P1-9): W53 STRUCTURAL contract promoted to an ACTIVE gate leg. The validator
# (validate_verify_done_w53_contract — Mode:/Changed:/## Summary/final-verdict-line, batched
# manifest) was implemented + unit-tested + cited as "source of truth" but never CALLED here, so
# whether a report carried provenance fields depended entirely on the producing model's diligence
# (haiku-at-low-effort and sonnet diverged silently while v-merge-all/v-forensics parse
# Mode:/Changed: downstream). Same recoverable semantics as the FAIL gate below: re-run
# /v-verify-done to converge — never hand-patch fields onto a stale report. Defensive `type`
# guard mirrors AVF-004 (an injected older lib must not false-block).
VERIFY_DONE_MALFORMED=0
VERIFY_DONE_MALFORMED_DETAIL=""
# CODE_CHANGED guard (bug6-phase2 D7): artifact gates are inactive when no code changed this
# session — a stray/legacy verify-done in a docs-only session must not block on structure.
if [ "${CODE_CHANGED:-0}" -eq 1 ] && [ "$MISSING_VERIFY" -eq 0 ] && [ -n "$VERIFY_DONE_FILE" ] && type validate_verify_done_w53_contract >/dev/null 2>&1; then
  if ! VERIFY_DONE_MALFORMED_DETAIL=$(validate_verify_done_w53_contract "$VERIFY_DONE_FILE" 2>&1); then
    VERIFY_DONE_MALFORMED=1
  else
    VERIFY_DONE_MALFORMED_DETAIL=""
  fi
fi

VERIFY_DONE_FAIL=0
VERIFY_DONE_FAIL_REASON=""
if [ "$MISSING_VERIFY" -eq 0 ] && [ -n "$VERIFY_DONE_FILE" ]; then
  # (1) Overall verdict FAIL — the runner's explicit judgment. Prefer the W53 final-line contract
  #     (last non-blank line = 'Overall Verdict: PASS|FAIL'); also accept a line-anchored
  #     '(Overall )?Verdict: FAIL' for legacy formats. Anchored at line start (allowing markdown
  #     decoration) so a per-check findings-table row that happens to say 'Status: FAIL' cannot trip it.
  _vd_last=$(awk 'NF { last=$0 } END { print last }' "$VERIFY_DONE_FILE" 2>/dev/null)
  # SREV-001: two guards against false-blocking a PASS report that quotes a prior iteration's FAIL:
  # (1) the decoration class EXCLUDES '>' — a blockquoted '> Overall Verdict: FAIL' is quoted HISTORY,
  #     not this report's verdict, so it must not match; (2) the legacy scan is bounded to the LAST 5
  #     lines (the verdict is always at/near the end), not the whole body. The awk check handles the
  #     W53 final-line; tail -5 handles legacy reports whose verdict isn't the literal last line.
  # ND-0716: trailing decoration ([*_]) joined the boundary class — '**Overall Verdict: FAIL**'
  # (a model that bolds the verdict line) used to escape FAIL detection in BOTH this gate and
  # merge-back's _verify_done_untrusted (kept byte-parallel; v-merge-back-verdict-anchor-test.sh).
  # Widening is fail-closed only: 'FAILED'/'FAILURE' still excluded, PASS lines unaffected.
  if printf '%s' "$_vd_last" | grep -qiE '^[[:space:]*#-]*overall[[:space:]]+verdict:[[:space:]]*fail([[:space:]*_]|$)' \
     || tail -5 "$VERIFY_DONE_FILE" 2>/dev/null | grep -qiE '^[[:space:]*#-]*(overall[[:space:]]+)?verdict:[[:space:]]*fail([[:space:]*_]|$)'; then
    VERIFY_DONE_FAIL=1
    VERIFY_DONE_FAIL_REASON="reports a failing verdict ('Overall Verdict: FAIL')"
  fi
  # (2) Unresolved FILE-BOUNDARY violations. The verify-done runner tags these with the
  #     finding ID 'FND-BND' — unambiguous, unlike the bare word 'boundary' which appears in
  #     benign test prose ('UTC boundary case'), so we key ONLY on FND-BND (no false-block on
  #     timezone-boundary tests). Catches a laundered report whose verdict was flipped to PASS
  #     while FND-BND findings remain in the body.
  if grep -qE 'FND-BND' "$VERIFY_DONE_FILE" 2>/dev/null; then
    VERIFY_DONE_FAIL=1
    if [ -n "$VERIFY_DONE_FAIL_REASON" ]; then
      VERIFY_DONE_FAIL_REASON="${VERIFY_DONE_FAIL_REASON} and carries FILE BOUNDARY violations (FND-BND)"
    else
      VERIFY_DONE_FAIL_REASON="carries FILE BOUNDARY violations (FND-BND) — files were changed outside the task's declared FILE BOUNDARY"
    fi
  fi
  # (3) P-VD (forensic 2026-06-18 audit): post-dispatch content-binding. VERIFY_DONE was the ONLY
  #     gauntlet artifact with NO _independence_verdict call — a hand-edit that flips the verdict to PASS
  #     *and deletes the FND-BND lines* defeats both (1) and (2) above (nothing left to detect). The
  #     canonical dispatch (SKILL.md: v-dispatch-subagent.sh --agent v-verify-done-runner --mode capture)
  #     has the HELPER write the artifact and record its sha (emit_marker ok / W5G-4), so a post-dispatch
  #     edit is catchable as 'edited' — completing the QA/WF/PRE_FLIGHT tamper-evidence set. Scoped to
  #     'edited' ONLY: it fires solely on a real dispatch + sha mismatch, so a hand-authored / Agent-tool
  #     report with no sha baseline is unaffected (the P0a verdict/FND-BND re-scan is the control there) —
  #     no regression. An honest correction declares 'Post-dispatch edit:' -> 'declared' (recoverable).
  if [ "$VERIFY_DONE_FAIL" -eq 0 ] && [ -n "$VERIFY_DONE_FILE" ] \
     && [ "$(_independence_verdict "$VERIFY_DONE_FILE" v-verify-done-runner)" = "edited" ]; then
    VERIFY_DONE_FAIL=1
    VERIFY_DONE_FAIL_REASON="was modified AFTER its independent v-verify-done-runner dispatch (provenance sha256 mismatch — W5G-4); a flip to 'Overall Verdict: PASS' with the FND-BND lines deleted would otherwise be invisible. Re-dispatch /v-verify-done so the runner's output is canonical, or add an explicit 'Post-dispatch edit: <what and why>' line if the change was a legitimate correction"
  fi
  # MB-1 (2026-06-30): VERIFY_DONE was the only gauntlet artifact with NO independence signal beyond `edited`. A fully
  # hand-authored 'Overall Verdict: PASS' with no FND-BND passed entirely unflagged. WARN on `silent` (no dispatch,
  # no honest declaration) — advisory ONLY, the verdict + FND-BND re-scan stay the primary control. `declared` honest
  # inline is left untouched (verify-done is conventions, not product correctness — a block would be over-strict).
  if [ "$VERIFY_DONE_FAIL" -eq 0 ] && [ -n "$VERIFY_DONE_FILE" ] \
     && [ "$(_independence_verdict "$VERIFY_DONE_FILE" v-verify-done-runner)" = "silent" ]; then
    WARNINGS="$WARNINGS
  ⚠️ VERIFY_DONE_REPORT appears hand-authored (no independent v-verify-done-runner dispatch on record). Accepted — the Overall-Verdict + FND-BND re-scan remain the control — but an independent dispatch via v-dispatch-subagent.sh is preferred."
  fi
fi

# AVF-002: Headless mode REMOVED its gate bypass — all 3 artifacts are required.
# Headless sessions have MORE checking, not less, because no human is watching.
# (Previous v5 behavior: MISSING_PREFLIGHT=0 and MISSING_VERIFY=0 in headless — removed.)

if [ "$MISSING_PREFLIGHT" -eq 1 ]; then
  # W4B1-BARE-ARTIFACT-HINT: bare PRE_FLIGHT_REPORT.md (no SID suffix) in the
  # repo root is a prior-session artifact the model must NOT append to. When it
  # exists, add a targeted hint so the model knows EXACTLY what went wrong.
  _bare_pf_hint=""
  if [ -f "${REPO_ROOT}/PRE_FLIGHT_REPORT.md" ]; then
    _bare_pf_sid=$(grep -m1 -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      "${REPO_ROOT}/PRE_FLIGHT_REPORT.md" 2>/dev/null | head -1 || true)
    # W5G-5/M-1: ${var,,} is bash 4+ — on macOS /bin/bash 3.2 it crashed every
    # blocked Stop with "bad substitution" (prod sessions) and
    # the W4B1 hint never fired. Use tr (SESSION_ID_LC already exists above).
    _bare_pf_sid_lc=$(printf '%s' "$_bare_pf_sid" | tr '[:upper:]' '[:lower:]')
    if [ -n "$_bare_pf_sid" ] && [ "$_bare_pf_sid_lc" != "$SESSION_ID_LC" ]; then
      _bare_pf_hint=" ⚠️ W4B1: PRE_FLIGHT_REPORT.md (no SID suffix) is a STALE artifact from prior session ${_bare_pf_sid} — do NOT append to it; write PRE_FLIGHT_REPORT_${SESSION_ID}.md fresh via v-pre-flight-runner subprocess."
    fi
  fi
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT not found for this session (${SESSION_ID}).${_bare_pf_hint} ACTION REQUIRED: run /v-pre-flight and produce PRE_FLIGHT_REPORT_<session>.md."
fi

if [ "$MISSING_REVIEW" -eq 1 ]; then
  _bare_ar_hint=""
  if [ -f "${REPO_ROOT}/AGENT_REVIEW.md" ]; then
    _bare_ar_sid=$(grep -m1 -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      "${REPO_ROOT}/AGENT_REVIEW.md" 2>/dev/null | head -1 || true)
    _bare_ar_sid_lc=$(printf '%s' "$_bare_ar_sid" | tr '[:upper:]' '[:lower:]')
    if [ -n "$_bare_ar_sid" ] && [ "$_bare_ar_sid_lc" != "$SESSION_ID_LC" ]; then
      _bare_ar_hint=" ⚠️ W4B1: AGENT_REVIEW.md (no SID suffix) is a STALE artifact from prior session ${_bare_ar_sid} — do NOT append to it; write AGENT_REVIEW_${SESSION_ID}.md fresh."
    fi
  fi
  if [ -n "$REVIEW_SEMANTIC_ERROR" ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ AGENT_REVIEW is not semantically valid for this session (${SESSION_ID}): ${REVIEW_SEMANTIC_ERROR}. ACTION REQUIRED: run adversarial review fallback chain and produce a completed AGENT_REVIEW_<session>.md."
  else
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ AGENT_REVIEW not found for this session (${SESSION_ID}).${_bare_ar_hint} ACTION REQUIRED: dispatch agent review (codex-adversarial-reviewer or superpowers fallback) and produce AGENT_REVIEW_<session>.md."
  fi
fi

if [ "$MISSING_VERIFY" -eq 1 ]; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ VERIFY_DONE_REPORT not found for this session (${SESSION_ID}). ACTION REQUIRED: run /v-verify-done and produce VERIFY_DONE_REPORT_<session>.md."
fi

# ND-0716 (P1-9): present-but-STRUCTURALLY-INVALID verify-done blocks with its own actionable
# message (distinct from not-found and from FAIL-verdict — the model must REGENERATE in the
# canonical format, not resolve findings and not produce a missing file).
if [ "${VERIFY_DONE_MALFORMED:-0}" -eq 1 ]; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ VERIFY_DONE_REPORT is present but STRUCTURALLY INVALID (W53 contract) for this session (${SESSION_ID}): ${VERIFY_DONE_MALFORMED_DETAIL}. Downstream consumers (v-merge-all, v-forensics) parse Mode:/Changed: for provenance — a report without them silently degrades the audit trail. ACTION REQUIRED: re-run /v-verify-done using the canonical format (v/references/dispatch-v-verify-done.md § Required Output Format); do NOT hand-patch fields onto the existing report."
fi

# P0a: a PRESENT-but-FAILING verify-done blocks completion (recoverable). Distinct message from the
# not-found case above so the model knows to RESOLVE, not regenerate.
if [ "${VERIFY_DONE_FAIL:-0}" -eq 1 ]; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ VERIFY_DONE_REPORT ${VERIFY_DONE_FAIL_REASON} for this session (${SESSION_ID}). A failing verify-done must NOT complete. ACTION REQUIRED: resolve the convention/boundary violations — move any out-of-boundary file to its own session, or (if a finding is a genuinely pre-existing out-of-scope issue) document the justification in the report — then re-run /v-verify-done so it converges to 'Overall Verdict: PASS'. Do NOT hand-edit the verdict to PASS."
fi

# ── P0c: worktree-orphan detection (forensic 2026-06-17) ──────────────
# A /v worktree session that COMMITS to its branch but never merges back leaves the work orphaned: the
# branch tip is not reachable from main, so completion ships nothing (one session committed to
# a fix branch, never merged, then re-implemented the same fix in main = wasted work + a live
# conflict landmine). Merge-back was a TEXT contract, never machine-enforced at Stop. Detect: a registered
# worktree whose PATH carries THIS session's SID (the branch name often omits it — one observed session's did), on a
# branch whose tip is NOT an ancestor of main. BLOCK — recoverable: merge it, prune a confirmed duplicate,
# or write a HANDOFF. Exempts honest deferral markers; only fires on a definite is-ancestor=1 (FP-safe).
# SREV-002: skips when SESSION_WT is set — the W5F-3 session-lock gate above already covers THAT worktree
# (avoids a double-block whose exemptions differ). P0c is the path-SID fallback for the orphan W5F-3's
# session-lock detection MISSES — exactly the observed case (the completing session ran on main, not in the wt).
# SREV-003: exempts only a VALIDATED handoff (_handoff_satisfies: >=80 bytes + '# Handoff'), so a stub
# HANDOFF can't trivially bypass the gate.
WORKTREE_ORPHAN=0
WORKTREE_ORPHAN_DETAIL=""
if [ "$IS_V_SESSION" -eq 1 ] && [ -n "${REPO_ROOT:-}" ] && [ -n "${SESSION_ID_LC:-}" ] \
   && command -v git >/dev/null 2>&1 \
   && [ -z "${SESSION_WT:-}" ] \
   && [ "${_handoff_satisfies:-0}" -eq 0 ] \
   && [ -z "$(find_session_artifact 'WORKTREE_HANDOFF' 2>/dev/null || true)" ] \
   && [ -z "$(find_session_artifact 'CYCLE_CAP_HANDOFF' 2>/dev/null || true)" ] \
   && [ -z "$(find_session_artifact 'BLOCKED' 2>/dev/null || true)" ]; then
  _sid8=$(printf '%s' "$SESSION_ID_LC" | cut -c1-8)
  # Parse `git worktree list --porcelain` into "<path>\t<headsha>" records (first record = main worktree).
  _wt_records=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk '
    /^worktree /{ p=substr($0,10) }
    /^HEAD /{ print p "\t" $2 }')
  _main_head=$(printf '%s\n' "$_wt_records" | head -1 | cut -f2)
  if [ -n "$_main_head" ]; then
    while IFS="$(printf '\t')" read -r _wp _wh; do
      [ -n "$_wp" ] && [ -n "$_wh" ] || continue
      # Only a worktree THIS session owns (path carries the SID), and never main itself / its tip.
      case "$_wp" in *"$SESSION_ID_LC"*|*"$_sid8"*) ;; *) continue ;; esac
      [ "$_wh" = "$_main_head" ] && continue
      # is-ancestor rc: 0 = merged (fine); 1 = definitely unmerged (orphan); >1 = error (FP-safe, skip).
      if git -C "$REPO_ROOT" merge-base --is-ancestor "$_wh" "$_main_head" 2>/dev/null; then
        : # merged into main — not orphaned
      else
        if [ "$?" -eq 1 ]; then
          WORKTREE_ORPHAN=1
          WORKTREE_ORPHAN_DETAIL="${_wp} (tip ${_wh} not in main)"
          break
        fi
      fi
    done <<WT_EOF
$(printf '%s\n' "$_wt_records" | tail -n +2)
WT_EOF
  fi
fi
if [ "${WORKTREE_ORPHAN:-0}" -eq 1 ]; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ WORKTREE NOT MERGED BACK for this session (${SESSION_ID}): ${WORKTREE_ORPHAN_DETAIL} — its commits are NOT in main, so this work is ORPHANED. Completing now ships nothing and strands the branch (forensic: a worktree fix was committed, never merged, then re-done in main = duplicate + conflict landmine). ACTION REQUIRED: merge it back (bash ~/.claude/skills/v/references/v-merge-back.sh ${SESSION_ID} <worktree-path>, or run /v-merge-all), OR — if the work was already re-done in main and this branch is a confirmed stale duplicate — prune it (git worktree remove --force <path> ; git branch -D <branch>), OR write HANDOFF_${SESSION_ID}.md if you are intentionally deferring."
fi

# ── Bug 6 / Phase 2: gauntlet-attestation witness gate (system-level enforcement) ──
# Why this exists: every prior Bug-6 defense (SKILL.md ANTI-SKIP block, OBSERVABLE
# PROOF four-line rule, v-gauntlet-attest.sh) depends on the model voluntarily
# running the script. If the model writes the three artifacts but never runs the
# attest script, all upstream defenses are inert. Stop hook is the one enforcement
# point that runs regardless of model state — adding the witness requirement here
# turns "the model is supposed to run attest" into "the conversation cannot end
# until attest ran." Same architectural shape as v-session-log's resolver witness
# (which closed the equivalent gap there: Bug 4 → script extraction + LAYER-3
# attestation + --require-attestation flag).
#
# Activation: only when /v ran + code changed + all three artifacts already passed
# validation (so this isn't redundant with MISSING_* checks). Skipped for impl-only,
# trivial, planning paths (those already exited above). The witness binds the SID
# + the three artifact paths, so it cannot be reused for a different session or
# forged after the fact.
#
# Witness file: ~/.claude/runtime/v-gauntlet-attestation-<sid>.json
# Written by:   ~/.claude/skills/v/references/v-gauntlet-attest.sh
# Freshness:    V_GAUNTLET_ATTESTATION_MAX_AGE_SEC if set, else SESSION-SCOPED (session age
#               + 1h slack, floored at 7200s) — see the W-WITNESS-TTL block below. The comment
#               here said "default 1800 = 30m" long after the code moved to 7200 (W-perf4);
#               don't re-introduce a hard-coded number here, read the block.
# W-LIGHT2: the witness is waived on a light-tier diff — CLAUDE.md § "Small/trivial exception"
# lists gauntlet-attest among the steps a small change skips. ACCEPTED COST, stated plainly: the
# witness is what binds artifact CONTENT hashes, so on this lane PRE_FLIGHT and AGENT_REVIEW are
# presence+structure+verdict checked but NOT tamper-evidenced. That is a deliberate trade for a
# ≤30-line, non-UI, non-migration, security-clear diff; it is NOT extended to the full gauntlet.
_GAUNTLET_LIGHT_WAIVED=0
if [ "$IS_V_SESSION" -eq 1 ] \
   && [ "$CODE_CHANGED" -eq 1 ] \
   && [ "$IMPLEMENTATION_ONLY_MODE" != "1" ] \
   && _light_tier_is_active; then
  _GAUNTLET_LIGHT_WAIVED=1
  WARNINGS="$WARNINGS
  ⚠️ Gauntlet-attestation witness waived: LIGHT-TIER diff shape verified at enforcement time ($(_light_tier_detail)). Artifact content-hash binding does not apply on this lane."
fi

if [ "$IS_V_SESSION" -eq 1 ] \
   && [ "$CODE_CHANGED" -eq 1 ] \
   && [ "$MISSING_PREFLIGHT" -eq 0 ] \
   && [ "$MISSING_REVIEW" -eq 0 ] \
   && [ "$MISSING_VERIFY" -eq 0 ] \
   && [ "$_GAUNTLET_LIGHT_WAIVED" -eq 0 ] \
   && [ "$IMPLEMENTATION_ONLY_MODE" != "1" ]; then

  _GAUNTLET_WITNESS="$HOME/.claude/runtime/v-gauntlet-attestation-${SESSION_ID_LC}.json"
  # 2026-05-28 (plan-n/WG-5): narrowed default 14400s (4h) → 1800s (30m). A single
  # gauntlet run completes in minutes; a 4h window let one attest bless many later
  # completions. Override via V_GAUNTLET_ATTESTATION_MAX_AGE_SEC if genuinely needed.
  # W-perf4: 1800s (30m) was TOO TIGHT for long xhigh-effort Opus sessions — a session
  # that attested then did more work / idled briefly false-blocked at Stop ("witness STALE
  # age=5385s", a prod session) and had to pointlessly re-attest. Raised to 7200s
  # (2h): still far short of the multi-completion abuse the 4h window allowed, and the
  # SID-binding + content-hash binding (below) are the real anti-replay guards, not the age
  # ceiling. A genuinely stale witness (e.g. bug6-phase2 D3's 20000s) is still rejected.
  # === W-WITNESS-TTL BEGIN (2026-08-05) — session-scoped staleness ceiling ==================
  # 7200s is STILL too tight, for the same reason W-perf4 raised 1800s->7200s. Forensic sweep
  # over the 37 post-/v-inversion sessions: the witness is implicated in 173 of 277 Stop blocks
  # (62%), of which 42 are "witness is STALE". The mechanism is structural, not abusive — the
  # witness is only checked once the core trio exists (see the guard above), so a session
  # attests, then spends HOURS on QA_REPORT + IMPACT_MAP remediation, and the witness ages out
  # by WALL TIME while the three artifacts it binds are byte-identical. The forced re-attest
  # buys nothing and re-enters the loop (one session: 3.5h, 35 identical blocks).
  #
  # So: scope the ceiling to the SESSION rather than to a constant. Within one session a
  # re-attest of unchanged artifacts is ceremony; ACROSS sessions the SID binding below already
  # rejects the witness outright, which is what the original "one attest blessing many later
  # completions" concern was actually about.
  #
  # MONOTONIC RELAXATION — the floor is today's 7200s, so this can never produce a ceiling
  # STRICTER than current behaviour and therefore cannot introduce a new block. An explicit
  # V_GAUNTLET_ATTESTATION_MAX_AGE_SEC still wins outright, including when it tightens.
  #
  # NOT WEAKENED (these are the real anti-replay guards, all below and untouched): SID binding,
  # nonce length, future-timestamp rejection, per-artifact content-hash binding, HMAC.
  # Covered by hooks/witness-session-scoped-ttl-test.sh.
  _GAUNTLET_MAX_AGE="${V_GAUNTLET_ATTESTATION_MAX_AGE_SEC:-}"
  if [ -z "$_GAUNTLET_MAX_AGE" ]; then
    _GAUNTLET_MAX_AGE=7200
    _gw_sess_start=$(_cra_session_start_epoch "${SESSION_ID:-}" 2>/dev/null || true)
    # STRICT NUMERIC GUARD — do not remove. Bash arithmetic treats a bare non-numeric token as a
    # variable name, so an unvalidated 'abc' evaluates to 0 and the span becomes `now - 0 + 3600`
    # ≈ 56 years: the staleness ceiling would be silently DISABLED (fail-OPEN). Caught by the
    # bad-marker cases in hooks/witness-session-scoped-ttl-test.sh. Digits only, and it must be a
    # plausible past epoch — anything else falls through to the 7200s floor (fail-SAFE).
    case "$_gw_sess_start" in
      ''|*[!0-9]*) _gw_sess_start="" ;;
    esac
    if [ -n "$_gw_sess_start" ]; then
      _gw_now_probe=$(date -u +%s 2>/dev/null || echo 0)
      # session age + 1h slack for the tail of a long remediation pass
      _gw_span=$(( _gw_now_probe - _gw_sess_start + 3600 ))
      # Upper cap: a marker from 1970 (epoch 0) or any other absurd past value is numeric and
      # would otherwise yield a decades-wide ceiling. Longest real session observed in the
      # 2026-08-05 sweep was 24.9h, so 48h bounds the blast radius with generous headroom.
      if [ "$_gw_span" -gt 172800 ] 2>/dev/null; then _gw_span=172800; fi
      if [ "$_gw_span" -gt "$_GAUNTLET_MAX_AGE" ] 2>/dev/null; then _GAUNTLET_MAX_AGE="$_gw_span"; fi
    fi
  fi
  # === W-WITNESS-TTL END ====================================================================
  _gauntlet_witness_ok=0
  _gauntlet_witness_reason=""

  if [ ! -f "$_GAUNTLET_WITNESS" ]; then
    _gauntlet_witness_reason="witness not found at $_GAUNTLET_WITNESS"
  else
    _w_sid=$(jq -r '.sid // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_check=$(jq -r '.check // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_ts=$(jq -r '.ts // 0' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_nonce=$(jq -r '.nonce // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_pre=$(jq -r '.pre_flight // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_rev=$(jq -r '.agent_review // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_ver=$(jq -r '.verify_done // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_pre_sha=$(jq -r '.pre_sha256 // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_rev_sha=$(jq -r '.rev_sha256 // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_ver_sha=$(jq -r '.ver_sha256 // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_hmac=$(jq -r '.hmac // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    # Format 3 signs the source-tree binding too; read it here so the HMAC below covers it.
    _w_fmt=$(jq -r '.wit_ver // 0' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_tree=$(jq -r '.attested_tree // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_session_tree=$(jq -r '.attested_session_tree // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)
    _w_tree_root=$(jq -r '.attested_tree_root // empty' "$_GAUNTLET_WITNESS" 2>/dev/null)

    _now_ts=$(date -u +%s)
    _w_age=$(( _now_ts - ${_w_ts:-0} ))

    _sid_lc_w=$(printf '%s' "$_w_sid" | tr '[:upper:]' '[:lower:]')
    _cur_sid_lc_w=$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')

    if [ "$_w_check" != "gauntlet-attest" ]; then
      _gauntlet_witness_reason="witness 'check' field is '$_w_check' (expected 'gauntlet-attest') — wrong witness kind or malformed"
    elif [ "$_sid_lc_w" != "$_cur_sid_lc_w" ]; then
      _gauntlet_witness_reason="witness SID mismatch: witness binds to '$_w_sid', current session is '$SESSION_ID'"
    elif [ -z "$_w_nonce" ] || [ ${#_w_nonce} -lt 16 ]; then
      _gauntlet_witness_reason="witness nonce missing or too short (a real nonce is >=16 random chars)"
    elif [ "$_w_age" -gt "$_GAUNTLET_MAX_AGE" ]; then
      _gauntlet_witness_reason="witness is STALE: age=${_w_age}s exceeds V_GAUNTLET_ATTESTATION_MAX_AGE_SEC=${_GAUNTLET_MAX_AGE}s (re-run v-gauntlet-attest.sh against the current artifacts)"
    elif [ "$_w_age" -lt -60 ]; then
      # 2026-05-28 (shell/WG-7): a future ts gives a negative age that would slip past
      # the staleness ceiling. Reject (allow 60s clock skew).
      _gauntlet_witness_reason="witness timestamp is in the FUTURE (age=${_w_age}s) — clock tamper or forged ts; reject"
    else
      # Binding check: witness must reference the SAME files this hook just validated.
      _pre_bn=$(basename "$_w_pre" 2>/dev/null)
      _rev_bn=$(basename "$_w_rev" 2>/dev/null)
      _ver_bn=$(basename "$_w_ver" 2>/dev/null)
      _pre_act=$(basename "${PREFLIGHT_FILE:-}" 2>/dev/null)
      _rev_act=$(basename "${REVIEW_FILE:-}" 2>/dev/null)
      _ver_act=$(basename "${VERIFY_DONE_FILE:-}" 2>/dev/null)
      if [ "$_pre_bn" != "$_pre_act" ] || [ "$_rev_bn" != "$_rev_act" ] || [ "$_ver_bn" != "$_ver_act" ]; then
        _gauntlet_witness_reason="witness binds to different artifact filenames than the ones this hook validated (witness: $_pre_bn,$_rev_bn,$_ver_bn vs actual: $_pre_act,$_rev_act,$_ver_act) — the witness was written against a prior /v invocation's artifacts and is no longer valid"
      elif [ -z "$_w_hmac" ] || [ -z "$_w_pre_sha" ] || [ -z "$_w_rev_sha" ] || [ -z "$_w_ver_sha" ]; then
        # 2026-05-28 (bypass/WG-1): a v1 / hand-forged witness lacks the HMAC +
        # content hashes. Reject — re-run attest to produce a signed v2 witness.
        _gauntlet_witness_reason="witness is missing the HMAC / content-hash fields (legacy v1 format or hand-forged). Re-run v-gauntlet-attest.sh to produce a signed witness"
      elif [ "$_w_fmt" != "3" ]; then
        # Format 2 signed the content hashes but not the tree binding, so its tree fields could be
        # deleted to switch the post-attest edit check off. Accepting it would keep that door open.
        _gauntlet_witness_reason="witness format '${_w_fmt}' predates the signed source-tree binding (format 3). Re-run v-gauntlet-attest.sh to produce a current witness"
      elif ! type _gw_compute_hmac >/dev/null 2>&1; then
        # Fail-CLOSED: cannot verify the witness crypto → do not trust it.
        _gauntlet_witness_reason="witness crypto lib (hooks/lib/gauntlet-witness.sh) unavailable — cannot verify the witness HMAC; refusing to trust it"
      else
        # Content binding: recompute sha256 of the artifacts ON DISK and require they
        # match the witness — binds the witness to the EXACT attested content, so it
        # cannot be authored before the artifacts are finalized nor reused for changed
        # content (bypass/WG-1, plan-n/WG-1).
        _act_pre_sha=$(_gw_sha256 "${PREFLIGHT_FILE:-}" 2>/dev/null || true)
        _act_rev_sha=$(_gw_sha256 "${REVIEW_FILE:-}" 2>/dev/null || true)
        _act_ver_sha=$(_gw_sha256 "${VERIFY_DONE_FILE:-}" 2>/dev/null || true)
        if [ "$_act_pre_sha" != "$_w_pre_sha" ] || [ "$_act_rev_sha" != "$_w_rev_sha" ] || [ "$_act_ver_sha" != "$_w_ver_sha" ]; then
          _gauntlet_witness_reason="witness content hashes do NOT match the artifacts on disk — an artifact changed after attestation (or the witness was written against different content). Re-run v-gauntlet-attest.sh against the current artifacts"
        else
          # HMAC: recompute under the per-install key and require it matches. A witness
          # forged without the secret key cannot produce a valid HMAC.
          _calc_hmac=$(_gw_compute_hmac "$(_gw_canonical "$_w_sid" "$_w_nonce" "$_w_ts" "$_w_pre_sha" "$_w_rev_sha" "$_w_ver_sha" \
            "$_w_tree" "$_w_session_tree" "$_w_tree_root")" 2>/dev/null || true)
          if [ -z "$_calc_hmac" ]; then
            _gauntlet_witness_reason="witness HMAC could not be recomputed (a malformed field such as a colon outside the root, or no sha256 tool/secret) — refusing to trust the witness"
          elif [ "$_calc_hmac" != "$_w_hmac" ]; then
            _gauntlet_witness_reason="witness HMAC is INVALID (forged, tampered, or written by a different machine/user) — only v-gauntlet-attest.sh, running under this user, can produce a valid signature"
          else
            _gauntlet_witness_ok=1
          fi
        fi
      fi
    fi
  fi

  # ── ATTEST-TREE-BIND (forensic 2026-07-04): even a VALID witness only proves the
  # artifacts are the attested bytes — not that the SOURCE TREE still matches what the gauntlet
  # graded. One session attested, THEN a QA-found HIGH bug was fixed + committed, and the remediation
  # shipped review-unseen because nothing re-checked the tree. The witness now carries the graded
  # tree hash, signed as part of the format-3 HMAC. Compare it to the CURRENT tracked tree; on divergence,
  # surface it LOUDLY and drop a durable GAUNTLET_STALE marker. ADVISORY (a warning, not a hard
  # block) — a hard block here could strand a session on a benign post-attest tracked-file touch
  # (e.g. an auto-format), and the safe hardening is to make the stale-gauntlet condition impossible
  # to miss rather than risk a false-block on the completion path right before it lands. Bite:
  # v-gauntlet-attest-tree-bind-test.sh.
  if [ "$_gauntlet_witness_ok" -eq 1 ]; then
    # _w_tree, _w_tree_root and _w_session_tree were read above and are covered by the HMAC.
    # F5 hardening (2026-07-05): prefer the SESSION-SCOPED tree hash (only files THIS
    # SID's writes-ledger says it wrote — see _gw_scoped_tree_hash in
    # hooks/lib/gauntlet-witness.sh) over the whole-tree bind below. A shared working
    # tree with unrelated dirty files (sibling sessions/worktrees, 40+ files touched by
    # other work) previously made the whole-tree comparison see a "mismatch" that had
    # nothing to do with what THIS session's gauntlet actually graded — a false
    # GAUNTLET_STALE / false attribution. Falls back to the whole-tree compare when the
    # scoped hash is unavailable on either side (legacy witness, or an empty/missing
    # writes-log — in which case we have no positive scoping evidence and must keep the
    # broader safety net).
    _tb_root="${_w_tree_root:-$REPO_ROOT}"
    _cur_session_tree=""
    if [ -n "$_w_session_tree" ]; then
      _cur_session_tree="$(_gw_scoped_tree_hash "$_tb_root" "$SESSION_ID" 2>/dev/null || true)"
    fi
    # _tb_checked: a comparison actually ran. Only then may a stale marker be auto-cleared, and
    # when it cannot run (_tb_unchecked) the gap is reported instead of passing silently.
    _tb_checked=0; _tb_unchecked=""
    if [ -n "$_w_session_tree" ] && [ -n "$_cur_session_tree" ]; then
      _tb_scoped=1
      _tb_checked=1
      _tb_mismatch=0
      [ "$_cur_session_tree" != "$_w_session_tree" ] && _tb_mismatch=1
      _tb_attested_disp="$_w_session_tree"
      _tb_current_disp="$_cur_session_tree"
    elif [ -n "$_w_tree" ]; then
      _tb_scoped=0
      _cur_stash="$(git -C "$_tb_root" stash create 2>/dev/null || true)"
      if [ -n "$_cur_stash" ]; then
        _cur_tree="$(git -C "$_tb_root" rev-parse "${_cur_stash}^{tree}" 2>/dev/null || true)"
      else
        _cur_tree="$(git -C "$_tb_root" rev-parse 'HEAD^{tree}' 2>/dev/null || true)"
      fi
      # No commits yet: rev-parse prints its argument back. Only a real object id counts.
      case "$_cur_tree" in *[!0-9a-f]*) _cur_tree="" ;; esac
      _tb_mismatch=0
      if [ -n "$_cur_tree" ]; then
        _tb_checked=1
        [ "$_cur_tree" != "$_w_tree" ] && _tb_mismatch=1
      else
        _tb_unchecked="the current source tree at $_tb_root could not be computed"
      fi
      _tb_attested_disp="$_w_tree"
      _tb_current_disp="$_cur_tree"
    else
      _tb_scoped=0
      _tb_mismatch=0
      if git -C "$_tb_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _tb_unchecked="the witness carries no source-tree hash (attested before the repo's first commit?)"
      fi
    fi
    if [ -n "$_tb_unchecked" ]; then
      WARNINGS="$WARNINGS
  ⚠️ GAUNTLET TREE UNCHECKED (attest-tree-bind): $_tb_unchecked, so a source change made after attestation cannot be detected for this session. Re-run v-gauntlet-attest.sh once the repo has a commit."
    fi
    if [ "${_tb_mismatch:-0}" -eq 1 ]; then
      _stale_marker="$MAIN_ROOT/.v/artifacts/GAUNTLET_STALE_${SESSION_ID}.md"
      mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null || true
      if [ ! -f "$_stale_marker" ]; then
        {
          echo "# GAUNTLET_STALE — source tree changed AFTER the gauntlet graded it (${SESSION_ID})"
          echo
          echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
          echo "scope: $([ "$_tb_scoped" -eq 1 ] && echo 'session-scoped (this SID'"'"'s writes-ledger only)' || echo 'whole-tree (no usable writes-ledger scoping available)')"
          echo "attested: $_tb_attested_disp"
          echo "current:  $_tb_current_disp"
          echo "root:     $_tb_root"
          echo
          echo "The gauntlet artifacts (PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE) are valid but graded a"
          echo "DIFFERENT source tree than the one about to complete/land — a source file was edited"
          echo "AFTER v-gauntlet-attest.sh ran (the post-attest-remediation class: a QA fix"
          echo "committed after attestation ships review-unseen). Re-run the gauntlet steps whose"
          echo "output is now stale (/v-pre-flight, agent review, /v-verify-done) against the CURRENT"
          echo "tree, then re-run v-gauntlet-attest.sh. This marker is auto-cleared once the tree"
          echo "matches again (see the GAUNTLET_STALE marker-consumption gate below) — do not hand-"
          echo "delete it."
        } > "$_stale_marker" 2>/dev/null || true
      fi
      WARNINGS="$WARNINGS
  ⚠️ GAUNTLET STALE (attest-tree-bind, $([ "$_tb_scoped" -eq 1 ] && echo scoped || echo whole-tree)): the source tree changed after v-gauntlet-attest.sh graded it (attested=${_tb_attested_disp:0:12}… current=${_tb_current_disp:0:12}…). A post-attest edit (e.g. a QA remediation) is about to complete/land REVIEW-UNSEEN — the post-attest-remediation class. Re-run /v-pre-flight + agent review + /v-verify-done against the current tree and re-attest. Durable marker: $_stale_marker"
    elif [ "$_tb_checked" -eq 1 ]; then
      # Tree confirmed fresh (this run) — auto-clear any stale marker left by an
      # earlier check-review-artifact.sh invocation so a resolved staleness can never
      # strand completion forever (see GAUNTLET_STALE marker-consumption gate below).
      rm -f "$MAIN_ROOT/.v/artifacts/GAUNTLET_STALE_${SESSION_ID}.md" 2>/dev/null || true
    fi
  fi
  # ── GAUNTLET_STALE marker consumption (F5 hardening, 2026-07-05) ──────────────────
  # Ground truth: a production session
  # produced a false-PASS PRE_FLIGHT_REPORT/etc. because the attest-tree-bind check
  # above wrote a durable GAUNTLET_STALE_<sid>.md marker as WARNING-only — nothing
  # anywhere consumed the marker's PRESENCE before declaring the session complete, so
  # a session could re-run this hook (or a later invocation with a different/absent
  # witness) and the stale marker would just sit there, unread, forever. Make
  # completion hard-block while the marker exists for THIS session, regardless of
  # whether THIS invocation freshly detected the staleness (covers a marker left by a
  # prior invocation too). The auto-clear branch above removes it once the tree is
  # confirmed fresh again, so a resolved staleness cannot strand completion forever.
  _gauntlet_stale_marker="$MAIN_ROOT/.v/artifacts/GAUNTLET_STALE_${SESSION_ID}.md"
  if [ -f "$_gauntlet_stale_marker" ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ GAUNTLET_STALE marker present ($_gauntlet_stale_marker): the gauntlet artifacts graded a source tree that no longer matches — a file changed after v-gauntlet-attest.sh ran. Re-run: bash ~/.claude/skills/v/references/v-remediate-stale.sh --stale-list <path printed by v-gauntlet-attest.sh, normally .v/artifacts/GAUNTLET_STALE_LIST_${SESSION_ID}.txt> — it batches every dispatchable stale artifact in ONE blocking call, in dependency order. If the sidecar file is missing, re-run v-gauntlet-attest.sh first to regenerate it. IMPACT_MAP cannot be dispatched by that script (it is orchestrator-authored, not a subprocess) — redo Step 1.8 yourself if it is named. Then re-run v-gauntlet-attest.sh LAST (this also auto-clears this marker once the tree matches again). W-OPT-STALE (2026-08-11): the stale set can cover IMPACT_MAP and QA_REPORT when present, not just PRE_FLIGHT_REPORT/AGENT_REVIEW/VERIFY_DONE."
  fi

  if [ "$_gauntlet_witness_ok" -eq 0 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ Bug 6 / Phase 2: gauntlet-attestation ${_gauntlet_witness_reason}.

     The three gauntlet artifacts exist (PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT) but the witness from v-gauntlet-attest.sh is missing/stale/forged/unbound. Three production sessions (2026-05-28) shipped code to main with NO gauntlet because the Stop hook only validated artifact PRESENCE, not whether they were produced by THIS /v invocation. The witness fixes that gap.

     ACTION REQUIRED: from the project root, run

       bash ~/.claude/skills/v/references/v-gauntlet-attest.sh

     and quote the four lines it prints (GAUNTLET_ATTESTED: yes / PRE_FLIGHT_REPORT: ... / AGENT_REVIEW: ... / VERIFY_DONE_REPORT: ...) verbatim in your completion narration. The script validates the three artifacts are present, ≥200 B (not placeholder), and fresher than this /v invocation's start marker, and writes the witness file that this hook checks.

     If the script EXITS NON-ZERO, do NOT continue — its stderr names the missing/stale/placeholder artifact. Dispatch the corresponding sub-skill (/v-pre-flight, agent review, /v-verify-done) and re-run the attest script. Hand-writing the witness JSON does NOT work: it is signed with an HMAC over the SID, nonce, timestamp, and the sha256 of each artifact's content, keyed on a 0600 per-install secret — only v-gauntlet-attest.sh (run under this user, after the real artifacts exist) produces a valid signature, and changing any artifact after attestation invalidates the content-hash binding."
  fi
fi
# ── End Bug 6 / Phase 2 gauntlet-attestation witness gate ──

# === P1A-LOOKAHEAD-WITNESS (2026-07-03) ===
# Collapse the round-2 block. When the artifact trio is incomplete, the witness gate above is
# SKIPPED (it activates only at MISSING_*=0) — so a session fixes the artifacts, stops again,
# and burns a whole extra block→remediate round on "witness not found" (forensic: 4
# sequential rounds in one session; 62.8% of session cost on remediation turns in another). Surface the witness
# requirement IN THE SAME first block. Gate semantics unchanged: this branch only runs when the
# trio already appended to BLOCKING_ISSUES (any MISSING_*=1 ⇒ an ❌ item exists above), so WHAT
# blocks is identical — only the first block's message is complete. Bite: hooks/p1a-consolidated-block-test.sh.
if [ "$IS_V_SESSION" -eq 1 ] && [ "$CODE_CHANGED" -eq 1 ] && [ "$IMPLEMENTATION_ONLY_MODE" != "1" ] \
   && { [ "$MISSING_PREFLIGHT" -eq 1 ] || [ "$MISSING_REVIEW" -eq 1 ] || [ "$MISSING_VERIFY" -eq 1 ]; }; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ (round-2 lookahead) gauntlet-attestation witness will ALSO be required once the artifacts above exist: run 'bash ~/.claude/skills/v/references/v-gauntlet-attest.sh' from the project root IN THE SAME remediation pass (after producing/fixing the artifacts) — otherwise the next stop blocks again on the witness alone."
fi
# === end P1A-LOOKAHEAD-WITNESS ===

# ── W5F-3 (forensic 2026-06-06): STRANDED WORKTREE-MERGE gate ────────────────────
# A worktree session that claims completion must show its work actually REACHED main —
# or explicitly declare the deferral. Production failure (a pack-runner session): the session
# committed 8 finding-commits + artifacts to a build/pack-… branch, reported
# "COMPLETE … All 8 commits are in", never ran merge-back, and ended via a HANDOFF
# describing an unrelated catch-up task. The commits stranded on the branch for hours with the
# final report reading as shipped. Gate: SID-locked worktree branch ahead of main at Stop time
# ⇒ BLOCK unless HANDOFF_<sid>.md carries an explicit `MERGE_DEFERRED: <branch>` line (the
# documented "implemented but intentionally not merging now" path — it does NOT waive the
# artifact/witness gates above, which have already run by this point).
if [ "$IS_V_SESSION" -eq 1 ] && [ -n "$SESSION_WT_BRANCH" ] \
   && { [ "${SESSION_WT_AHEAD:-0}" -gt 0 ] || [ "${SESSION_WT_STAGED_BYTES:-0}" -gt 0 ]; }; then
  # W-P3-13: a worktree with 0 commits but a non-empty staged diff is the SAME stranding
  # shape (staged-bytes blindness) — SESSION_WT_AHEAD alone missed it. Track it separately
  # so the message below can say "staged, uncommitted" rather than a misleading commit count.
  _w5f3_staged_only=0
  [ "${SESSION_WT_AHEAD:-0}" -eq 0 ] && [ "${SESSION_WT_STAGED_BYTES:-0}" -gt 0 ] && _w5f3_staged_only=1
  _w5f3_deferred=0
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _w5f3_hf="$_dir/HANDOFF_${SESSION_ID}.md"
    [ -f "$_w5f3_hf" ] || continue
    # FND-006: match the branch as a WHOLE token after MERGE_DEFERRED: (delimited by start/
    # whitespace/EOL), so a deferral for 'build/x-extra' cannot waive the distinct 'build/x'.
    # Extract the first token of each MERGE_DEFERRED: line and compare exactly.
    while IFS= read -r _w5f3_decl; do
      _w5f3_tok=$(printf '%s\n' "$_w5f3_decl" | sed -E 's/^[[:space:]]*MERGE_DEFERRED:[[:space:]]*//' | awk '{print $1}')
      if [ "$_w5f3_tok" = "$SESSION_WT_BRANCH" ]; then
        _w5f3_deferred=1
        break
      fi
    done < <(grep -E '^[[:space:]]*MERGE_DEFERRED:' "$_w5f3_hf" 2>/dev/null)
    [ "$_w5f3_deferred" -eq 1 ] && break
    # W-P3-13 landing_owner escape hatch: a runner-owned pack session that intentionally
    # leaves work staged for an external landing lane (not this session's job to merge)
    # declares it explicitly — `landing_owner: <name>` — rather than being forced into a
    # MERGE_DEFERRED it cannot honor. Presence + a non-empty value is sufficient (mirrors
    # the existing HANDOFF-bypass forge surface; this is a documentation requirement, not
    # a cryptographic one).
    if grep -E '^[[:space:]]*landing_owner:[[:space:]]*[^[:space:]]' "$_w5f3_hf" >/dev/null 2>&1; then
      _w5f3_deferred=1
      break
    fi
  done
  # F10 (W5F-3 sibling-aware — mirrors FND-3 at the gate below): a machine-written merge-deferred-<sid>.md
  # (v-merge-back.sh exit-3) WHILE an active sibling still holds the merge is an INVOLUNTARY deferral, not
  # a stranded ship — accept it like FND-3 (which stays silent while a sibling is active). Once the sibling
  # clears: if the session is still OPEN, W5F-3 fires on its next stop (and FND-3 demands the merge); if it
  # already CLOSED, strand detection falls to v-batch-health / the RC-4a .v/artifacts sweep (SREV-003 — the
  # clean-stop is the intentional trade that ends an 8-block thrash). Forge surface ≤ the existing
  # HANDOFF bypass (both model-writable; marker now also branch-matched below, SREV-002).
  if [ "$_w5f3_deferred" -eq 0 ]; then
    _w5f3_mach=0
    for _w5f3_md in "$REPO_ROOT/.v/tmp" "${MAIN_ROOT:-$REPO_ROOT}/.v/tmp" "$REPO_ROOT/.v/artifacts" "${MAIN_ROOT:-$REPO_ROOT}/.v/artifacts"; do
      [ -f "$_w5f3_md/merge-deferred-${SESSION_ID}.md" ] || continue
      # Require the marker's worktree_branch to match THIS session's branch (mirrors FND-3's read), so F10's
      # forge-specificity equals the HANDOFF bypass — not bare existence (security review SREV-002).
      _w5f3_mb=$(sed -nE 's/^worktree_branch:[[:space:]]*//p' "$_w5f3_md/merge-deferred-${SESSION_ID}.md" 2>/dev/null | head -1)
      [ -n "$SESSION_WT_BRANCH" ] && [ "$_w5f3_mb" = "$SESSION_WT_BRANCH" ] && { _w5f3_mach=1; break; }
    done
    if [ "$_w5f3_mach" -eq 1 ]; then
      _w5f3_sib=0; _w5f3_now=$(date +%s 2>/dev/null || echo 0)
      for _w5f3_lk in "$REPO_ROOT"/.worktrees/*/.claude-session-lock "$REPO_ROOT"/.worktrees/*/*/.claude-session-lock "$MAIN_ROOT"/.worktrees/*/.claude-session-lock; do
        [ -f "$_w5f3_lk" ] || continue
        _w5f3_osid=$(awk '{print $1}' "$_w5f3_lk" 2>/dev/null); [ -z "$_w5f3_osid" ] && continue
        [ "$_w5f3_osid" = "$SESSION_ID" ] && continue
        _w5f3_m=$(stat -c %Y "$_w5f3_lk" 2>/dev/null || stat -f %m "$_w5f3_lk" 2>/dev/null || echo 0)
        [ "$_w5f3_now" -gt 0 ] && [ "${_w5f3_m:-0}" -gt 0 ] && [ $(( (_w5f3_now - _w5f3_m) / 60 )) -lt 240 ] && { _w5f3_sib=1; break; }
      done
      [ "$_w5f3_sib" -eq 1 ] && _w5f3_deferred=1
    fi
  fi
  if [ "$_w5f3_deferred" -eq 0 ]; then
    if [ "$_w5f3_staged_only" -eq 1 ]; then
      _w5f3_evidence="has a STAGED, UNCOMMITTED diff (${SESSION_WT_STAGED_BYTES} bytes of \`git diff --cached --stat\`) that is not reachable from '${MAIN_BRANCH}' — 0 commits, so SESSION_WT_AHEAD alone would have missed this (staged-bytes blindness)"
    else
      _w5f3_evidence="has ${SESSION_WT_AHEAD} commit(s) not reachable from '${MAIN_BRANCH}'"
    fi
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ W5F-3: STRANDED WORKTREE MERGE — this session's worktree branch '${SESSION_WT_BRANCH}' ${_w5f3_evidence} (worktree: ${SESSION_WT}). A completion claim with unmerged/unlanded session work is a false 'shipped' state (a pack session stranded 9 commits this way on 2026-06-06; staged-only strands are the same shape with 0 commits). Resolve by ONE of: (a) commit + merge back through the lifecycle script — bash ~/.claude/skills/v/references/v-merge-back.sh ${SESSION_ID} (NEVER a manual 'git merge' — it bypasses the merge lock + artifact gate + commit witness), (b) if the merge is INTENTIONALLY deferred, write HANDOFF_${SESSION_ID}.md containing the exact line 'MERGE_DEFERRED: ${SESSION_WT_BRANCH}' plus the commit/diff range being deferred, or (c) if this is a runner-owned pack session whose landing is explicitly owned by a DIFFERENT lane, write HANDOFF_${SESSION_ID}.md containing 'landing_owner: <name-of-owning-lane>' — this documents the stranded state instead of misreporting it as shipped. W-W5F3-EXEC (2026-08-12): deciding internally that (b) or (c) applies does NOT clear this gate — only the file on disk does. If an operator instruction is the reason you are waiting, that is exactly what (b)/(c) exist to record: write the HANDOFF now, in this turn, before doing anything else."
  fi
fi
# ── End W5F-3 stranded worktree-merge gate ──

# ── FND-3 resolvable-deferral gate (forensic 2026-06-19: 4 of 6 wave sessions stranded) ─────────
# An FND-3 involuntary merge-back deferral writes .v/tmp/merge-deferred-<sid>.md: v-merge-back.sh
# refused to stash over a concurrent sibling's uncommitted main WIP and DEFERRED (correct in the
# moment). But the marker exempted the survival gate (validation.sh _survival_has_marker) and nothing
# re-ran the merge after the sibling cleared, so the worktree's commits stranded silently and the
# session read as "complete". This gate keys on the DURABLE marker (robust to the live worktree-
# detection that also failed here), and fires ONLY when the deferral is now RESOLVABLE — no active
# sibling still blocks it — and the deferred branch is STILL ahead of main. Block is recoverable (the
# merge can proceed now). While a sibling is still active, stay silent: the deferral is genuinely
# un-resolvable and blocking would deadlock the wave.
if [ "$IS_V_SESSION" -eq 1 ]; then
  _fnd3_marker=""
  for _fnd3_d in "$REPO_ROOT/.v/tmp" "${MAIN_ROOT:-$REPO_ROOT}/.v/tmp" "$REPO_ROOT/.v/artifacts" "${MAIN_ROOT:-$REPO_ROOT}/.v/artifacts"; do   # F7: also read the durable RC-4a copy
    [ -f "$_fnd3_d/merge-deferred-${SESSION_ID}.md" ] && { _fnd3_marker="$_fnd3_d/merge-deferred-${SESSION_ID}.md"; break; }
  done
  if [ -n "$_fnd3_marker" ]; then
    # Resolvable iff NO other /v worktree session still holds a fresh (<240min) lock.
    _fnd3_sib=0; _fnd3_now=$(date +%s 2>/dev/null || echo 0)
    for _fnd3_lk in "$REPO_ROOT"/.worktrees/*/.claude-session-lock "$REPO_ROOT"/.worktrees/*/*/.claude-session-lock "$MAIN_ROOT"/.worktrees/*/.claude-session-lock; do
      [ -f "$_fnd3_lk" ] || continue
      _fnd3_osid=$(awk '{print $1}' "$_fnd3_lk" 2>/dev/null); [ -z "$_fnd3_osid" ] && continue
      [ "$_fnd3_osid" = "$SESSION_ID" ] && continue
      _fnd3_m=$(stat -c %Y "$_fnd3_lk" 2>/dev/null || stat -f %m "$_fnd3_lk" 2>/dev/null || echo 0)
      [ "$_fnd3_now" -gt 0 ] && [ "${_fnd3_m:-0}" -gt 0 ] && [ $(( (_fnd3_now - _fnd3_m) / 60 )) -lt 240 ] && { _fnd3_sib=1; break; }
    done
    _fnd3_branch=$(sed -nE 's/^worktree_branch:[[:space:]]*//p' "$_fnd3_marker" 2>/dev/null | head -1)
    _fnd3_ahead=0
    [ -n "$_fnd3_branch" ] && _fnd3_ahead=$(git -C "$REPO_ROOT" rev-list --count "${MAIN_BRANCH}..${_fnd3_branch}" 2>/dev/null || echo 0)
    # Explicit MERGE_DEFERRED: <branch> in a HANDOFF is the intentional escape hatch — if the
    # operator declared the deferral on purpose, don't double-block it (parity with the W5F-3 gate).
    _fnd3_declared=0
    for _fnd3_hd in "$REPO_ROOT" "$MAIN_ROOT" "$REPO_ROOT/.v/artifacts" "$MAIN_ROOT/.v/artifacts"; do
      [ -f "$_fnd3_hd/HANDOFF_${SESSION_ID}.md" ] || continue
      if grep -E '^[[:space:]]*MERGE_DEFERRED:' "$_fnd3_hd/HANDOFF_${SESSION_ID}.md" 2>/dev/null \
         | sed -E 's/^[[:space:]]*MERGE_DEFERRED:[[:space:]]*//' | awk '{print $1}' | grep -qxF "$_fnd3_branch"; then
        _fnd3_declared=1; break
      fi
    done
    if [ "$_fnd3_sib" -eq 0 ] && [ "${_fnd3_ahead:-0}" -gt 0 ] && [ "$_fnd3_declared" -eq 0 ]; then
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ FND-3 STRANDED DEFERRAL: merge-back for this session was DEFERRED (${_fnd3_marker}) because a concurrent sibling held uncommitted main WIP — but no active sibling blocks it now and the worktree branch '${_fnd3_branch}' still has ${_fnd3_ahead} commit(s) NOT in '${MAIN_BRANCH}'. A deferral is RETRYABLE, not done: nothing re-ran the merge after the sibling cleared, so the work is stranded (forensic 2026-06-19: 4 of 6 R15 wave sessions lost their fixes this way). RESOLVE — do NOT stop: re-run the lifecycle merge — bash ~/.claude/skills/v/references/v-merge-back.sh ${SESSION_ID} (it will land the work now that the blocker is gone; NEVER a manual 'git merge'). If the merge is genuinely impossible (still-conflicting), write HANDOFF_${SESSION_ID}.md with 'MERGE_DEFERRED: ${_fnd3_branch}' to declare the stranded state explicitly instead of leaving it silent."
    fi
  fi
fi
# ── End FND-3 resolvable-deferral gate ──

# ── IMPACT_MAP gate (cross-subsystem blast-radius; code-changing /v sessions) ──
# /v Step 1.8 enumerates the downstream subsystems a change can silently break
# (functional flow, reporting/metrics, admin, async jobs, notification emails,
# cache invalidation, DB data integrity, API contract, authorization) and routes
# impacted consumers to tests/review. A diff-scoped reviewer CANNOT see a consumer
# that wasn't changed, so this artifact is the only record the enumeration happened.
# Required when code changed (Feature/Bug-Fix/Refactor). Always cheaply satisfiable:
# a genuinely isolated change is all-`no`-with-reasons. Trivial/planning/handoff/
# impl-only sessions already exited above, so they are exempt.
# === W71 GATE-INDEPENDENCE PROVENANCE: helpers hoisted (fix 2026-06-02) ===
# _agent_was_dispatched / _independence_verdict and their transcript-signal prep now live
# ABOVE the AGENT_REVIEW gate (search "hoisted above the AGENT_REVIEW gate"). They used to be
# defined HERE — AFTER the AGENT_REVIEW call site at the C3b check — so that one caller hit
# "line 981: _independence_verdict: command not found", its case fell through, and the
# independent-review gate was silently un-enforced on every code-changing session. The
# QA / UX_CRITIQUE / WORKFLOW_VERIFICATION / PRE_FLIGHT callers below still resolve them
# (they always sat after the definitions).

if [ "$CODE_CHANGED" -eq 1 ]; then
  IMPACT_MAP_FILE=$(find_session_artifact "IMPACT_MAP" || true)
  MISSING_IMPACT=0
  IMPACT_REASON=""
  # W-perf5: single-source validator (lib/validation.sh) — the SAME function the /v
  # orchestrator self-check (v-completion-selfcheck.sh) calls, so the producer-side
  # check and this gate cannot drift. A `## Subsystem triage` TABLE that lacks the
  # `^subsystems:` anchor (prod sessions) is now caught in BOTH places.
  # Behaviour + reason strings are byte-identical to the prior inline checks (the
  # YAML-key anchoring rationale moved into the lib function).
  if IMPACT_REASON=$(validate_impact_map_semantics "$IMPACT_MAP_FILE" 2>/dev/null); then
    MISSING_IMPACT=0
  else
    MISSING_IMPACT=1
  fi

  # W-LIGHT2: waive the blast-radius enumeration on a light-tier diff. The 9-subsystem walk is
  # the right instrument for a feature; on a ≤30-line config/tooling change it is ceremony that
  # always comes back all-'no'-with-reasons. Scope guard: only when the artifact is ABSENT — a
  # PRESENT-but-invalid IMPACT_MAP keeps its original blocking reason rather than being waived.
  if [ "$MISSING_IMPACT" -eq 1 ] && [ -z "$IMPACT_MAP_FILE" ] && _light_tier_is_active; then
    MISSING_IMPACT=0
    WARNINGS="$WARNINGS
  ⚠️ IMPACT_MAP waived: LIGHT-TIER diff shape verified at enforcement time ($(_light_tier_detail)). Cross-subsystem enumeration is not required on this lane."
  fi

  # === W-MEDIUM-IMPACT (2026-08-03) ===
  # Same waiver, one tier out: an ordinary bounded app-code change (≤10 non-test files, ≤400
  # lines, WITH an accompanying test, and hard-excluded on security path/content, user-facing UI
  # and migrations) does not need the 9-subsystem walk either. Verified at enforcement time by
  # re-running v-classify-medium-tier.sh — diff-shape-derived, never model-asserted.
  # Ordering: runs AFTER the LIGHT waiver so a LIGHT diff is attributed to the narrower tier in
  # the warning text. Scope guard is identical — ABSENT artifact only; a PRESENT-but-invalid
  # IMPACT_MAP keeps its own blocking reason. QA is NOT waived here (see the W-MEDIUM hoist).
  # Bite: skills/v/references/v-classify-medium-tier-test.sh (both directions + scope guard).
  if [ "$MISSING_IMPACT" -eq 1 ] && [ -z "$IMPACT_MAP_FILE" ] && _medium_tier_is_active; then
    MISSING_IMPACT=0
    WARNINGS="$WARNINGS
  ⚠️ IMPACT_MAP waived: MEDIUM-TIER diff shape verified at enforcement time ($(_medium_tier_detail)). Ordinary bounded code change with an accompanying test — PRE_FLIGHT, AGENT_REVIEW, VERIFY_DONE and QA all remain required."
  fi
  # === end W-MEDIUM-IMPACT ===

  if [ "$MISSING_IMPACT" -eq 1 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ IMPACT_MAP ${IMPACT_REASON} for this session (${SESSION_ID}). Application code changed — /v Step 1.8 Impact Analysis is mandatory regardless of classification (the gate keys on code change, not Feature/Bug-Fix/Refactor). If this was a direct sub-skill invocation (e.g. /v-build, /v-maintenance) rather than the /v orchestrator, either re-run via /v (which produces this artifact) or write IMPACT_MAP yourself; if you are handing off mid-task, write HANDOFF_${SESSION_ID}.md instead. ACTION REQUIRED: produce IMPACT_MAP_<session>.md enumerating EVERY connected subsystem (functional flow, reporting/metrics, admin, async jobs, notification emails, cache invalidation, DB data integrity, API contract, authorization) as impacted:yes (with consumers + verification) or impacted:no (with a one-line reason). Always satisfiable — a genuinely isolated change is all-'no'-with-reasons. This forces the cross-subsystem enumeration a diff-scoped review structurally cannot do. Protocol: ~/.claude/skills/v/references/v-impact-analysis.md."
  fi
fi

# ── P7-B: SUCCESS_CRITERIA / WORKFLOW_BLAST_RADIUS validate-if-present (Step 1.7/1.6) ──
# These artifacts are CONDITIONALLY produced (Feature/bug-fix+UI only), so absence is legitimate —
# NEVER block on absence. Only a PRESENT-but-malformed artifact blocks: a >150B stub lacking the
# 'criteria'/'workflow_states' (SC) or 'states_to_verify' (BR) field-key silently narrows the RED
# tests /v-tdd generates while /v declares done. Single-sourced with v-completion-selfcheck.sh via
# the same validators so the producer self-check and this gate agree (parity locked by
# skills/v/references/v-completion-parity-test.sh). [review 2026-06-22, validate-if-present]
if [ "$CODE_CHANGED" -eq 1 ] && [ -n "${SESSION_ID:-}" ]; then
  _SC_FILE=$(find_session_artifact "SUCCESS_CRITERIA" || true)
  if [ -n "$_SC_FILE" ] && ! _sc_reason=$(validate_success_criteria_structure "$_SC_FILE" 2>/dev/null); then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ SUCCESS_CRITERIA present but malformed (${_sc_reason}) for session (${SESSION_ID}). A present /v Step 1.7 artifact must carry the 'criteria:' + 'workflow_states:' blocks /v-tdd turns into RED tests. Regenerate via Step 1.7 or delete the stub (absence is allowed — Step 1.7 is Feature-only)."
  fi
  _BR_FILE=$(find_session_artifact "WORKFLOW_BLAST_RADIUS" || true)
  if [ -n "$_BR_FILE" ] && ! _br_reason=$(validate_blast_radius_structure "$_BR_FILE" 2>/dev/null); then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ WORKFLOW_BLAST_RADIUS present but malformed (${_br_reason}) for session (${SESSION_ID}). A present /v Step 1.6 artifact must carry the 'states_to_verify:' list (the per-state RED tests that catch the leftover-sibling-bug class). Regenerate via Step 1.6 or delete the stub (absence is allowed — Step 1.6 is bug-fix+UI only)."
  fi
fi

# ── QA_REPORT gate (independent QA acceptance verdict; code-changing /v sessions) ──
# /v Step 6.4.9 runs the autonomous QA loop (assess → SME analysis → fix → re-test,
# capped at 3 iterations). It must converge to `verdict: pass`, or escalate to
# `verdict: escalated` WITH a BLOCKED_<sid>.md companion documenting the unresolved
# findings + SME analyses. Required when code changed. Here-string (not head|grep
# pipe) avoids the SIGPIPE-under-pipefail false-negative documented above.
if [ "$CODE_CHANGED" -eq 1 ]; then
  QA_REPORT_FILE=$(find_session_artifact "QA_REPORT" || true)
  MISSING_QA=0
  QA_REASON=""
  _qa_verdict=""
  # W-perf5: structural validation via the single-source lib validator (the SAME one
  # v-completion-selfcheck.sh calls) — size + `Model:` header + `## QA Acceptance`
  # heading + the AUTHORITATIVE (first, col-0) `verdict:` extraction. A QA_REPORT
  # missing its `Model:` header (prod sessions) is caught in BOTH places now.
  # On structural success the function echoes the verdict; on failure it echoes the
  # reason. The verdict-case decision + W71 independence check below stay here (they
  # need find_session_artifact + the session transcript).
  # ORCHFIX-H6 (forensics 2026-07-02, F-6): substance floor, PRE_FLIGHT-style but
  # WARN-only. A QA re-dispatch overwrote the 4,967B substantive report with a 244B verdict-only
  # stub that passed every validator (QA had no size floor), and the durable copy became BETTER
  # than the canonical — inverted durability. Warn below 1024B so a stub is visible; not blocking
  # (a genuinely tiny clean-pass QA on a one-line change is legitimate).
  if [ -n "$QA_REPORT_FILE" ] && [ -f "$QA_REPORT_FILE" ]; then
    _qa_size=$(wc -c < "$QA_REPORT_FILE" 2>/dev/null | tr -d ' ')
    if [ "${_qa_size:-0}" -gt 0 ] && [ "${_qa_size:-0}" -lt 1024 ]; then
      WARNINGS="$WARNINGS
  ⚠️ QA_REPORT is small (${_qa_size}B < 1024B). A verdict-only stub may have overwritten the substantive findings report (observed: 244B stub vs 4,967B durable copy) — carry the findings table forward on QA re-dispatch, or restore from .v/artifacts."
    fi
  fi
  if _qa_verdict=$(validate_qa_report_structure "$QA_REPORT_FILE" 2>/dev/null); then
    case "$_qa_verdict" in
      pass)
        : # allow
        ;;
      fail)
        MISSING_QA=1
        QA_REASON="verdict: fail — QA found unresolved critical/high issues; the Step 6.4.9 loop must converge to pass or escalate"
        ;;
      escalated)
        # escalated is acceptable ONLY with a BLOCKED companion documenting the unresolved
        # work. Use find_session_artifact (same glob semantics as the report lookup).
        if [ -z "$(find_session_artifact "BLOCKED" 2>/dev/null || true)" ]; then
          MISSING_QA=1
          QA_REASON="verdict: escalated but no BLOCKED_${SESSION_ID} companion (escalation requires the BLOCKED artifact with unresolved findings + SME analyses)"
        fi
        ;;
      *)
        MISSING_QA=1
        QA_REASON="missing or unrecognized top 'verdict:' line (expected pass|fail|escalated)"
        ;;
    esac
  else
    MISSING_QA=1
    QA_REASON="$_qa_verdict"
  fi

  # === W-QASCALE-BASIS (2026-08-03) ===
  # W-QASCALE (v-qa-acceptance.md § Measurement validity) lets QA move a quantitative threshold
  # finding out of a blocking `fail` and into a non-blocking `## Scale-unverified findings` bucket
  # when the fixture is not production-representative. That is the right call for the observed
  # false-fail class (a tiny local seed judged against a 200-word threshold, then retracted an
  # iteration later at real scale) — and it is ALSO a reward-hacking surface, because "the fixture
  # was unrepresentative" is unfalsifiable. Without a check, a pressured agent can launder a REAL
  # threshold failure through the same door that was opened to stop false ones.
  # Minimum mechanical guard (deliberately NOT semantic — the hook cannot judge representativeness):
  # a report that CLAIMS pass while carrying scale-unverified CONTENT must also state the basis it
  # actually measured against. That forces the claim to be written down where a reviewer can weigh
  # it, instead of remaining implicit. The unfilled skeleton placeholder ('- <...>') is not content.
  # Scoped to verdict: pass — same "a claimed green is the dangerous case" rule as W71 below.
  # Bite: skills/v/references/p1d-qa-vise-test.sh § W-QASCALE-BASIS.
  if [ "${_qa_verdict:-}" = "pass" ] && [ "${MISSING_QA:-0}" -eq 0 ] && [ -n "${QA_REPORT_FILE:-}" ]; then
    if grep -qiE '^##[[:space:]]+Scale-unverified findings' "$QA_REPORT_FILE" 2>/dev/null; then
      _qa_su_body=$(awk '/^##[[:space:]]+[Ss]cale-unverified findings/{f=1;next} /^##[[:space:]]/{f=0} f' "$QA_REPORT_FILE" 2>/dev/null \
                    | grep -vE '^[[:space:]]*$' | grep -vE '^[[:space:]]*-[[:space:]]*<' | head -1)
      if [ -n "$_qa_su_body" ] && ! grep -qiE '^measurement_basis:' "$QA_REPORT_FILE" 2>/dev/null; then
        MISSING_QA=1
        QA_REASON="reports verdict: pass and carries '## Scale-unverified findings' CONTENT, but no 'measurement_basis:' line. W-QASCALE (v-qa-acceptance.md § Measurement validity) permits downgrading a quantitative threshold finding to non-blocking ONLY when the report states the fixture/data scale it actually measured against — otherwise 'the fixture was unrepresentative' is an unfalsifiable way to launder a real failure past the gate. Add a 'measurement_basis:' line naming the scale you measured at (and what scale would settle it)"
      fi
    fi
  fi
  # === end W-QASCALE-BASIS ===

  # W71 independence: a structurally-valid QA_REPORT must come from an INDEPENDENT
  # v-qa-reviewer, not be hand-authored by the orchestrator (the observed failure).
  # SCOPED TO verdict: pass — a claimed green is the dangerous case. verdict: escalated
  # (with its required BLOCKED companion) is the DOCUMENTED honest fallback when dispatch
  # failed; it already admits non-completion, so it must NOT be re-blocked here.
  if [ "$MISSING_QA" -eq 0 ] && [ -n "$QA_REPORT_FILE" ] && [ "${_qa_verdict:-}" = "pass" ]; then
    case "$(_independence_verdict "$QA_REPORT_FILE" v-qa-reviewer)" in
      edited)
        MISSING_QA=1
        QA_REASON="was modified AFTER its independent v-qa-reviewer dispatch (provenance sha256 mismatch — W5G-4). The reviewer's output is canonical; re-dispatch QA, or add an explicit 'Post-dispatch edit: <reason>' line if the change was legitimate" ;;
      edited-declared)
        # F2 (2026-08-29): an independent v-qa-reviewer dispatch IS on record. Before the token
        # split this fell into `declared)` below, which requires a parenthetical REASON for an
        # inline self-grade — a demand that only makes sense when nobody was dispatched.
        #
        # F2-B1MIRROR (codex adversarial review, CRITICAL — this was a REGRESSION I introduced).
        # Pre-split, this shape resolved to `declared`, and the declared) arm's regex requires a
        # `Dispatch mode: … (reason)` shape which a bare `Post-dispatch edit:` line NEVER matches —
        # so it fell to the else branch and set MISSING_QA=1. It BLOCKED, by accident. Making this
        # arm an unconditional warn re-opened exactly the QA-laundering shape:
        # real dispatch returns `verdict: escalated` + a CRITICAL, orchestrator rewrites it to
        # `verdict: pass` with a bare edit line, gate passes. QA has NO other content control (the
        # I1 baseline check is unreachable here — see the WORKFLOW arm's note). Restore the block
        # for a disclosed verdict/finding change; an honest prose-only edit still warns.
        if _declared_edit_discloses_verdict_change "$QA_REPORT_FILE"; then
          MISSING_QA=1
          QA_REASON="was edited AFTER its independent v-qa-reviewer dispatch and the edit DISCLOSES a changed verdict/finding/severity. QA is the final behavioral filter and a post-dispatch edit must never change what the independent reviewer concluded — the reviewer's output is canonical (forensic: one session hand-authored a QA verdict; another shipped an unverifiable pass). Resolve by ONE of: (a) RE-DISPATCH v-qa-reviewer so a fresh verdict is canonical, (b) restore the reviewer's verdict and record your disagreement in a separate QA_ADDENDUM_${SESSION_ID}.md with its own provenance"
        else
          WARNINGS="$WARNINGS
  ⚠️ QA_REPORT was edited after its independent v-qa-reviewer dispatch and the edit is DECLARED ('Post-dispatch edit:'). The dispatch IS on record and the dispatched original survives (see .v/archive/<session>/) — this is NOT a self-graded pass and NO re-dispatch is required. A post-dispatch edit must never change the verdict."
        fi ;;
      declared)
        # P1-1 (2026-06-30): QA is the final behavioral-correctness filter; an inline self-graded `verdict: pass`
        # is its weakest path. Mirror AGENT_REVIEW's "require evidence the independent path was exercised": accept
        # (warn) ONLY when the inline declaration carries a substantive REASON (a parenthetical ≥4 chars after the
        # inline keyword — the honest-degradation marker, same shape as a documented failed-dispatch note). A BARE
        # `orchestrator-inline` self-grade with no reason → BLOCK. SAFETY: must NOT false-block honest documented
        # inline QA, e.g. `Dispatch mode: orchestrator-inline (meta-repo: no product surface to QA)` (bite-proven).
        # SREV-004: the reason is an honesty-friction AUDIT TRAIL (parity with AGENT_REVIEW's declared path), NOT
        # cryptographic proof — a 4-char reason suffices; the value is a LOUD, DELIBERATE written declaration on record.
        if grep -qiE 'dispatch[[:space:]:_-]*(mode)?[[:space:]:_-]*(orchestrator[_-]?inline|inline|degraded[_-]?inline|degraded|manual)[^(]*\([^)]{4,}\)' "$QA_REPORT_FILE" 2>/dev/null; then
          WARNINGS="$WARNINGS
  ⚠️ QA_REPORT declares a self-authored/degraded fallback (no independent v-qa-reviewer dispatch found) — a reason is documented, so accepted; an independent dispatch via v-dispatch-subagent.sh is strongly preferred."
        else
          MISSING_QA=1
          QA_REASON="declares an inline 'verdict: pass' with NO documented reason and no v-qa-reviewer dispatch — QA is the final behavioral filter and a bare self-grade is not an independent check (parity with AGENT_REVIEW, which blocks a declared inline review lacking a documented fallback attempt). Dispatch v-qa-reviewer via v-dispatch-subagent.sh, OR document why QA ran inline: 'Dispatch mode: orchestrator-inline (<reason>)'"
        fi ;;
      unverifiable)
        if _provenance_baseline_exists "$(basename "$QA_REPORT_FILE")"; then
          WARNINGS="$WARNINGS
  ⚠️ QA_REPORT independence could not be verified (session transcript unavailable to the Stop hook); a tamper-evidence sha baseline IS on record, so a post-hoc edit remains auditable. Ensure v-qa-reviewer was actually dispatched, not hand-authored."
        else
          # I1 (forensic 2026-06-17): verdict:pass + transcript unreadable + NO
          # DISPATCH_PROVENANCE sha baseline = ZERO tamper-evidence — a later fail->pass flip would be
          # undetectable (the inline-QA hole: QA produced inline-on-main with no provenance). Fail-close,
          # RECOVERABLE. This does NOT punish honest inline (that path declares -> 'declared', accepted);
          # it fires only when there is neither a transcript NOR a baseline NOR a declaration.
          MISSING_QA=1
          QA_REASON="reports verdict: pass but carries NO tamper-evidence baseline — the Stop hook cannot read this session's transcript AND no DISPATCH_PROVENANCE status=ok sha256 line records QA_REPORT, so a post-hoc fail->pass flip would be undetectable (the inline-QA hole: QA produced inline-on-main with no provenance). Dispatch v-qa-reviewer via v-dispatch-subagent.sh (it self-records its sha baseline), or — if QA genuinely ran inline — declare it honestly ('dispatch: inline (reason)') AND append a DISPATCH_PROVENANCE status=ok line with the QA_REPORT sha256"
        fi ;;
      silent)
        MISSING_QA=1
        QA_REASON="appears hand-authored — no independent v-qa-reviewer ran this session (no Agent/Task dispatch with subagent_type=v-qa-reviewer, no v-dispatch-subagent.sh subprocess, no DISPATCH_PROVENANCE record) and the report carries no honest 'dispatch: inline'/'degraded:' declaration. The orchestrator writing its own QA verdict defeats the independent-QA gate (a production session did exactly this while the real reviewer was still running). Dispatch v-qa-reviewer, or — if dispatch is genuinely unavailable — declare the degraded fallback explicitly in the report" ;;
    esac
  fi

  # === P1B-LIGHT-TIER (2026-07-03) ===
  # QA exemption for the LIGHT gauntlet tier — DIFF-SHAPE-VERIFIED AT ENFORCEMENT TIME, never
  # model-asserted: this hook re-runs v-classify-light-tier.sh itself (≤10 changed lines, config/
  # routes/app/Console path classes only, a REAL accompanying test, and the single-sourced
  # signing/HMAC/webhook/credential/host-construction/auth/payment HARD exclusion — over-exclusion
  # falls back to the full gauntlet). Motivation: 178 turns for a 3-line onOneServer()
  # guard — the QA loop is the dominant per-session cost line on tiny guard diffs.
  # SCOPE GUARD: applies ONLY when NO QA_REPORT exists at all — a PRESENT QA_REPORT with
  # verdict: fail / escalated-without-BLOCKED / independence problems blocks exactly as before
  # (light tier skips the dispatch, it never overrides a real QA verdict). PRE_FLIGHT,
  # AGENT_REVIEW, VERIFY_DONE, and the gauntlet witness remain required — this exempts QA only.
  # Bite: skills/v/references/p1b-light-tier-test.sh (both directions + fail-closed).
  # W-LIGHT2: this used to run the classifier inline here — the only call site, which is why the
  # tier could only ever waive QA. It now consults the memoized hoist (search "W-LIGHT2 hoist"),
  # so all four waivers share ONE verdict from ONE classifier run and cannot drift apart.
  if [ "$MISSING_QA" -eq 1 ] && [ -z "$QA_REPORT_FILE" ] && _light_tier_is_active; then
    MISSING_QA=0
    WARNINGS="$WARNINGS
  ⚠️ QA_REPORT waived: LIGHT-TIER diff shape verified at enforcement time ($(_light_tier_detail)). Pre-flight + agent review remain required."
  fi
  # === end P1B-LIGHT-TIER ===

  if [ "$MISSING_QA" -eq 1 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ QA_REPORT ${QA_REASON} for this session (${SESSION_ID}). Code changed — /v Step 6.4.9 QA Acceptance is mandatory. ACTION REQUIRED: run the autonomous QA loop — dispatch \`v-qa-reviewer\` via the fork-safe subprocess helper (\`bash ~/.claude/skills/v/references/v-dispatch-subagent.sh v-qa-reviewer\`) to produce QA_REPORT_<session>.md; for each critical/high finding route to the domain SME for analysis, implement the prescribed fix, re-verify, and re-dispatch QA (cap 3 iterations). Converge to 'verdict: pass', or 'verdict: escalated' WITH a BLOCKED_<session>.md. Protocol: ~/.claude/skills/v/references/v-qa-acceptance.md."
  fi
fi

# ── W49-F1: UX_CRITIQUE gate (UI-touching sessions only) ────────────────────
# A production session (post-W48) skipped Step 3.5 entirely. W48-F2
# left UX_CRITIQUE advisory; W49-F1 promotes it to mandatory when session-owned
# writes include user-facing UI files. Mirrors PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE
# gate semantics (find_session_artifact lookup + structural validation +
# BLOCKING_ISSUES append).
#
# Review-fix mapping:
#   C1: uses ALL_CHANGED_PATHS (already populated via lib/session-writes.sh
#       at line ~108) instead of a custom V_TMP_DIR path.
#   C2: appends to existing BLOCKING_ISSUES accumulator (single hook).
#   H1: ALL_CHANGED_PATHS already includes git-state fallback at line ~134
#       — covers Bash-mediated UI mods that bypass track-session-writes.
#   H2: implementation-only mode skipped per CLAUDE.md exception.
#   H3: structural validation (Model: line + ## UX Critique or ## Heuristic header).
#   H4: uses find_session_artifact "UX_CRITIQUE" — same lookup as the trio.
#   M1: UI detection delegated to lib/ui-path-pattern.sh's is_user_facing_ui_path.
#   M4: gated behind IS_V_SESSION=1 (line ~214) so non-/v sessions aren't blocked.
W49_GATE_ACTIVE=0
W49_IMPL_ONLY_NEEDS_DEFER=0
# >>> W49-SCOPE (2026-06-28, forensic): scope the UI-gate trigger to THIS session's OWN paths.
# ALL_CHANGED_PATHS source #2 diffs START_HEAD..CURRENT_HEAD over a FROZEN base (line ~500), so under concurrent
# sessions on shared main it CAPTURES a sibling's committed files (drift) — that fired the UX_CRITIQUE +
# WORKFLOW_VERIFICATION gates on a sibling's .tsx for a session that touched no UI (~15min wasted incl. a 10m
# verifier timeout). Subtract files PROVABLY attributable to ANOTHER session (in a sibling's writes-log, not in
# mine) via the canonical primitive. SAFE DIRECTION: files_attributable_to_other_sessions FAILS OPEN (subtracts
# nothing) when this session authored nothing trackable, and NEVER removes a file that is in MY writes-log — so
# own UI changes ALWAYS still trigger (under-trigger = quality gap; over-trigger = mere friction). Bash-written
# sibling files (untracked by the writes-log) remain in scope → still the safe over-trigger direction.
# Bite: hooks/ui-gate-own-scope-test.sh.
W49_UI_SCOPE_PATHS="$ALL_CHANGED_PATHS"
if type files_attributable_to_other_sessions >/dev/null 2>&1 && [ -n "$ALL_CHANGED_PATHS" ]; then
  _w49_foreign="$(printf '%s\n' "$ALL_CHANGED_PATHS" | files_attributable_to_other_sessions "$SESSION_ID" 2>/dev/null || true)"
  if [ -n "$_w49_foreign" ]; then
    # awk, NOT grep -vxF: grep exits 1 when ZERO lines survive the filter, so on an ALL-FOREIGN scope (every
    # path attributable to a sibling) its `|| fallback` would RESTORE the full foreign set and over-fire the
    # gate on pure-foreign UI — re-introducing the very contamination this block removes (codex SREV-001 /
    # logic-review HIGH). awk exits 0 whether its output is empty or not, so "all foreign → empty → gate off"
    # is preserved; the `|| printf` fallback then fires ONLY on a genuine awk failure → ALL_CHANGED_PATHS (safe
    # over-trigger). `$0!=""` drops the printf trailing-newline blank line. Own files are never in _w49_foreign
    # (files_attributable_to_other_sessions skips anything in MY writes-log), so this never under-triggers.
    W49_UI_SCOPE_PATHS="$(awk 'NR==FNR{f[$0]=1;next} ($0!="" && !($0 in f))' <(printf '%s\n' "$_w49_foreign") <(printf '%s\n' "$ALL_CHANGED_PATHS") 2>/dev/null || printf '%s' "$ALL_CHANGED_PATHS")"
  fi
fi
# <<< W49-SCOPE
if [ "$IS_V_SESSION" -eq 1 ] \
   && type any_user_facing_ui >/dev/null 2>&1 \
   && any_user_facing_ui "$W49_UI_SCOPE_PATHS"; then
  if [ "${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}" != "1" ]; then
    # Normal /v session — require UX_CRITIQUE artifact.
    W49_GATE_ACTIVE=1
  else
    # Implementation-only mode — runner-managed session that touches UI.
    # Plan H2 review-fix: require IMPLEMENTATION_REPORT to declare
    # `UX_CRITIQUE_DEFERRED=<orchestrator_sid>` so the parent orchestrator's
    # responsibility chain is preserved. Without that line, runner sessions
    # could bypass UX critique entirely.
    W49_IMPL_ONLY_NEEDS_DEFER=1
  fi
fi

if [ "$W49_GATE_ACTIVE" -eq 1 ]; then
  UX_CRITIQUE_FILE=$(find_session_artifact "UX_CRITIQUE" || true)
  MISSING_UX_CRITIQUE=0
  UX_CRITIQUE_REASON=""
  # W-perf5: single-source structural validator (lib/validation.sh) — the SAME function
  # v-completion-selfcheck.sh calls, so a malformed UX_CRITIQUE can't pass the producer
  # self-check and bounce here. Behaviour + reason strings preserved (incl. the awk
  # Model-check, which is here-string/pipefail-immune). The W71 independence check stays below.
  if UX_CRITIQUE_REASON=$(validate_ux_critique_structure "$UX_CRITIQUE_FILE" 2>/dev/null); then
    MISSING_UX_CRITIQUE=0
  else
    MISSING_UX_CRITIQUE=1
  fi

  # W71 independence: UX_CRITIQUE must come from an independent v-ux-critique-reviewer.
  if [ "$MISSING_UX_CRITIQUE" -eq 0 ] && [ -n "$UX_CRITIQUE_FILE" ]; then
    case "$(_independence_verdict "$UX_CRITIQUE_FILE" v-ux-critique-reviewer)" in
      edited)
        WARNINGS="$WARNINGS
  ⚠️ UX_CRITIQUE was modified after its independent dispatch (provenance sha256 mismatch — W5G-4). Advisory artifact, so not blocking — but add a 'Post-dispatch edit: <reason>' line or re-dispatch to keep the independence chain auditable." ;;
      edited-declared)
        # F2 (2026-08-29): dispatch on record + declared edit + original survives.
        WARNINGS="$WARNINGS
  ⚠️ UX_CRITIQUE was edited after its independent v-ux-critique-reviewer dispatch and the edit is DECLARED ('Post-dispatch edit:'). The dispatch IS on record and the dispatched original survives (see .v/archive/<session>/) — the independence chain is intact and NO re-dispatch is required." ;;
      declared)
        WARNINGS="$WARNINGS
  ⚠️ UX_CRITIQUE declares a self-authored/degraded fallback (no independent v-ux-critique-reviewer dispatch found). Accepted; prefer an independent dispatch when available." ;;
      unverifiable)
        WARNINGS="$WARNINGS
  ⚠️ UX_CRITIQUE independence could not be verified (transcript unavailable). Ensure v-ux-critique-reviewer was dispatched, not hand-authored." ;;
      silent)
        MISSING_UX_CRITIQUE=1
        UX_CRITIQUE_REASON="appears hand-authored — no independent v-ux-critique-reviewer ran this session (no Agent/Task dispatch, no v-dispatch-subagent.sh subprocess, no DISPATCH_PROVENANCE) and no honest 'dispatch: inline'/'degraded:' declaration. Dispatch the reviewer, or declare the degraded fallback explicitly" ;;
    esac
  fi

  if [ "$MISSING_UX_CRITIQUE" -eq 1 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ UX_CRITIQUE_REPORT ${UX_CRITIQUE_REASON} for this session (${SESSION_ID}). UI files were modified — Step 3.5 UX critique is mandatory. ACTION REQUIRED: dispatch \`v-ux-critique-reviewer\` via the fork-safe subprocess helper (\`bash ~/.claude/skills/v/references/v-dispatch-subagent.sh v-ux-critique-reviewer\`) and produce UX_CRITIQUE_<session>.md. See ~/.claude/skills/v/references/dispatch-ux-critique.md for the prompt template. Manual-write fallback is allowed if dispatch unavailable — file MUST start with the line Model: and contain a level-2 heading reading exactly 'UX Critique', 'Heuristic coverage', or 'UX findings' (bare 'Findings' rejected — AGENT_REVIEW reuses that header)."
  fi
fi

# ── WORKFLOW_VERIFICATION gate (behavioral; UI-touching /v sessions) ─────────
# Companion to the W49 UX_CRITIQUE gate above. UX_CRITIQUE judges heuristics
# (advisory); WORKFLOW_VERIFICATION judges whether the user-facing flow actually
# works when driven in a real browser (behavioral, blocking). Same activation
# condition as W49 (IS_V_SESSION + user-facing UI in session-owned writes + not
# impl-only), so it reuses W49_GATE_ACTIVE. Accepts `status: pass` and
# `status: degraded` (browser env genuinely unavailable — surfaced loudly, not
# silently skipped). Blocks on missing / structurally-invalid / `status: fail`.
# Written by the v-workflow-verifier agent in /v Step 3.5.
if [ "${W49_GATE_ACTIVE:-0}" -eq 1 ]; then
  WF_VERIFY_FILE=$(find_session_artifact "WORKFLOW_VERIFICATION" || true)
  MISSING_WF_VERIFY=0
  WF_VERIFY_REASON=""
  # W-perf5: single-source structural validator (lib/validation.sh) — the SAME function
  # v-completion-selfcheck.sh calls. On structural success it echoes the status
  # (pass|degraded|fail); `fail` blocks here (a flow broke in the browser). Behaviour +
  # reason strings preserved. The W71 independence check stays below.
  WF_VERIFY_REASON=""
  if _wf_status=$(validate_workflow_verification_structure "$WF_VERIFY_FILE" 2>/dev/null); then
    if [ "$_wf_status" = "fail" ]; then
      MISSING_WF_VERIFY=1
      WF_VERIFY_REASON="status: fail — a workflow is broken when driven in a browser"
    else
      MISSING_WF_VERIFY=0
    fi
  else
    MISSING_WF_VERIFY=1
    WF_VERIFY_REASON="$_wf_status"
  fi

  # W-perf7 (review CODEX-001): ENFORCE the cosmetic fast-lane — a `status: degraded` whose
  # degraded_reason claims `cosmetic-ui-change` must actually BE cosmetic. Re-run the SAME
  # single-source classifier on the session's changed UI files (base = the session's head-baseline,
  # so it works for committed-on-branch changes too). A DEFINITIVE behavioral verdict (matched token
  # or non-UI file) → block (a behavioral change cannot degrade-skip the browser gate). The
  # INDETERMINATE case ("could not compute a diff" — the hook can't reconstruct it) → warn, not
  # block, to avoid false-blocking a legit cosmetic change. Without this, the fast-lane is advisory.
  if [ "$MISSING_WF_VERIFY" -eq 0 ] && [ -n "$WF_VERIFY_FILE" ] \
     && grep -qiF 'cosmetic-ui-change' "$WF_VERIFY_FILE" 2>/dev/null; then
    _cos_refs="$HOME/.claude/skills/v/references/v-cosmetic-ui-check.sh"
    _cos_ui=$(printf '%s\n' "$W49_UI_SCOPE_PATHS" | grep -iE '\.(tsx|jsx|vue|svelte|css|scss|less|styl|ts|js|mjs|cjs)$' | awk 'NF' || true)  # W49-SCOPE: scope the cosmetic re-check to THIS session's own paths too (codex SREV-002 / logic F3) — else a sibling's behavioral .tsx could block a genuinely-cosmetic own session
    if [ -f "$_cos_refs" ] && [ -n "$_cos_ui" ]; then
      # shellcheck disable=SC2086 — intentional word-split: one classifier arg per changed file.
      _cos_out=$(bash "$_cos_refs" "${START_HEAD:-}" $_cos_ui 2>&1 || true)
      if printf '%s' "$_cos_out" | grep -q '^COSMETIC$'; then
        : # genuinely cosmetic — fast-lane honestly taken
      elif printf '%s' "$_cos_out" | grep -qiE 'could not compute a diff|only test files'; then
        WARNINGS="$WARNINGS
  ⚠️ WORKFLOW_VERIFICATION took the cosmetic fast-lane but the Stop hook could not re-confirm it (${_cos_out}). Accepted — verify the change was genuinely styling-only."
      else
        MISSING_WF_VERIFY=1
        WF_VERIFY_REASON="cosmetic fast-lane CLAIMED (status: degraded / cosmetic-ui-change) but the classifier re-check on the session diff says: ${_cos_out}. A behavioral change cannot degrade-skip the browser workflow verification — run the full v-workflow-verifier (or, if the change is genuinely cosmetic, re-run v-cosmetic-ui-check.sh to see why it classified BEHAVIORAL)"
      fi
    fi
  fi

  # W71 independence: WORKFLOW_VERIFICATION must come from an independent
  # v-workflow-verifier. (status: degraded already reads as a 'declared' honest fallback.)
  if [ "$MISSING_WF_VERIFY" -eq 0 ] && [ -n "$WF_VERIFY_FILE" ]; then
    case "$(_independence_verdict "$WF_VERIFY_FILE" v-workflow-verifier)" in
      edited)
        # Blocking-grade: a tampered status:pass would otherwise stand as browser proof.
        BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ WORKFLOW_VERIFICATION was modified AFTER its independent v-workflow-verifier dispatch (provenance sha256 mismatch — W5G-4). The verifier's browser-driven output is canonical. Re-dispatch the verifier, or add an explicit 'Post-dispatch edit: <reason>' line if the change was legitimate (downgrades to a declared, warned fallback)." ;;
      edited-declared)
        # F2-B1MIRROR (codex adversarial review, HIGH).
        # CORRECTION: an earlier version of this comment claimed the I1-WF baseline guard below
        # "still applies and can still block" for this token. That was FALSE, and provably so:
        # I1-WF is gated on `! _provenance_baseline_exists`, but `_artifact_postdispatch_edited`
        # (the only way to reach `edited`/`edited-declared`) and `_provenance_baseline_exists` use
        # the IDENTICAL provenance grep — `\|status=ok\|.*\|artifact=<base>\|sha256=<64hex>$` —
        # over the same dirs and SID. So a baseline ALWAYS exists here, the negation is always
        # false, and I1-WF never evaluates its case for this token. Do not restore that claim.
        # This arm is therefore the ONLY control on this path — which is the exact shape of
        # a forensic case (verifier returned status: fail + a CRITICAL; the artifact was
        # hand-edited to status: degraded / golden_path: pass). Note this path was already
        # unprotected BEFORE the F2 split (the old declared) arm was a bare warn), so this closes
        # a pre-existing hole rather than one F2 opened.
        if _declared_edit_discloses_verdict_change "$WF_VERIFY_FILE"; then
          MISSING_WF_VERIFY=1
          WF_VERIFY_REASON="was edited AFTER its independent v-workflow-verifier dispatch and the edit DISCLOSES a changed status/finding. The verifier's browser-driven output is canonical and a post-dispatch edit must never change 'status:' (forensic: the verifier returned status: fail + a CRITICAL, the artifact was hand-edited to status: degraded/golden_path: pass, and the flip shipped). Re-dispatch v-workflow-verifier, or record the disagreement in a separate WORKFLOW_VERIFICATION_ADDENDUM_${SESSION_ID}.md with its own provenance"
        else
          WARNINGS="$WARNINGS
  ⚠️ WORKFLOW_VERIFICATION was edited after its independent v-workflow-verifier dispatch and the edit is DECLARED ('Post-dispatch edit:'). The dispatch IS on record and the dispatched original survives (see .v/archive/<session>/) — NO re-dispatch is required. A post-dispatch edit must never change 'status:'."
        fi ;;
      declared)
        WARNINGS="$WARNINGS
  ⚠️ WORKFLOW_VERIFICATION declares a degraded/self-authored fallback (no independent v-workflow-verifier dispatch found). Accepted; prefer a real browser-driven dispatch when available." ;;
      unverifiable)
        WARNINGS="$WARNINGS
  ⚠️ WORKFLOW_VERIFICATION independence could not be verified (transcript unavailable). Ensure v-workflow-verifier was dispatched, not hand-authored." ;;
      silent)
        MISSING_WF_VERIFY=1
        WF_VERIFY_REASON="appears hand-authored — no independent v-workflow-verifier ran this session (no Agent/Task dispatch, no v-dispatch-subagent.sh subprocess, no DISPATCH_PROVENANCE) and no 'status: degraded'/'dispatch: inline' declaration. Dispatch the verifier, or write the degraded artifact honestly (status: degraded + degraded_reason:)" ;;
    esac
  fi

  # I1-WF (forensic 2026-06-18): a WORKFLOW_VERIFICATION that would PASS
  # the gate (status: pass|degraded) needs a tamper-evidence sha baseline, else a post-hoc 'status: fail
  # -> degraded/pass' flip is UNDETECTABLE. The v-workflow-verifier returned status: fail + a
  # CRITICAL; the orchestrator hand-edited the artifact to status: degraded / golden_path: pass and
  # deleted the findings. Because the Agent-tool dispatch recorded no DISPATCH_PROVENANCE sha line,
  # _independence_verdict saw 'declared' (status: degraded) and only WARNed — the laundered pass shipped.
  # Mirror QA_REPORT's I1 fail-close (recoverable BLOCK): with NO sha baseline AND no proof of an
  # untampered dispatch (declared/edited-declared/unverifiable), BLOCK. NOTE (F2 close-out): the
  # edited-declared token can never actually reach this guard -- _artifact_postdispatch_edited and
  # _provenance_baseline_exists use byte-identical provenance greps, so a baseline always exists
  # once that token is possible. It is enumerated in the case only so the arm cannot silently lapse
  # if that predicate ever changes. The real control on that path is the arm above.'dispatched' (sha matches) and 'edited' (sha
  # mismatch — already blocked above) both carry a baseline and never reach here, so the honest
  # browser-driven path is unaffected. The honest inline-degraded path is preserved in substance: it
  # appends a DISPATCH_PROVENANCE line, or dispatches via v-dispatch-subagent.sh / the self-recording
  # agent (agents/v-workflow-verifier.md) — both one-step, never a dead-end.
  if [ "$MISSING_WF_VERIFY" -eq 0 ] && [ -n "$WF_VERIFY_FILE" ] \
     && ! _provenance_baseline_exists "$(basename "$WF_VERIFY_FILE")"; then
    case "$(_independence_verdict "$WF_VERIFY_FILE" v-workflow-verifier)" in
      # F2 PRESERVATION (2026-08-29): `edited-declared` is enumerated here DELIBERATELY. This guard
      # is not an "was a verifier dispatched?" test — it is a TAMPER-EVIDENCE test ("is there a sha
      # baseline that would expose a post-hoc status flip?"). Splitting `declared` without listing
      # the new token here would have silently OPENED this block for exactly that shape.
      declared|edited-declared|unverifiable)
        MISSING_WF_VERIFY=1
        WF_VERIFY_REASON="reports status: ${_wf_status:-pass} but carries NO tamper-evidence baseline — no DISPATCH_PROVENANCE status=ok sha256 line records WORKFLOW_VERIFICATION, so a post-hoc 'status: fail -> degraded/pass' flip would be undetectable (forensic: v-workflow-verifier returned status: fail + a CRITICAL, then the artifact was hand-edited to status: degraded/golden_path: pass; the Agent-tool dispatch left no sha line so the flip was invisible). Dispatch v-workflow-verifier via v-dispatch-subagent.sh (it self-records its sha baseline), or — if the verifier genuinely ran inline/degraded (e.g. a real cosmetic-only change with no browser) — append a provenance line: \`printf 'DISPATCH|ts=%s|agent=v-workflow-verifier|mode=agent-self|status=ok|submodel=sonnet|cost_usd=0|duration_ms=0|artifact=%s|sha256=%s\\\\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"WORKFLOW_VERIFICATION_${SESSION_ID}.md\" \"\$(shasum -a 256 WORKFLOW_VERIFICATION_${SESSION_ID}.md | awk '{print \$1}')\" >> DISPATCH_PROVENANCE_${SESSION_ID}.log\`" ;;
    esac
  fi

  if [ "$MISSING_WF_VERIFY" -eq 1 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ WORKFLOW_VERIFICATION ${WF_VERIFY_REASON} for this session (${SESSION_ID}). UI/workflow files were modified — browser workflow verification (Step 3.5) is mandatory. ACTION REQUIRED: dispatch \`v-workflow-verifier\` via the fork-safe subprocess helper (\`V_DISPATCH_TIMEOUT_SEC=540 bash ~/.claude/skills/v/references/v-dispatch-subagent.sh v-workflow-verifier\` — the 540s cap is BELOW the 600s tool timeout so a hung browser env self-terminates cleanly to a degraded fallback instead of stalling ~10min) and produce WORKFLOW_VERIFICATION_<session>.md with status: pass (or degraded). 'status: fail' means a flow is broken in the browser — fix the WF-* findings and re-run the verifier. If the browser env is genuinely unavailable, write the artifact with 'status: degraded' and a 'degraded_reason:' line (accepted, not blocking). Template: ~/.claude/skills/v/references/dispatch-workflow-verifier.md."
  fi
fi

# H-2 review-fix: implementation-only mode UX deferral check.
# When a runner-managed session (CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1) touches
# UI files, the parent orchestrator must own the UX critique. The runner's
# IMPLEMENTATION_REPORT must declare UX_CRITIQUE_DEFERRED=<orchestrator_sid>
# so the gate trail is preserved.
if [ "${W49_IMPL_ONLY_NEEDS_DEFER:-0}" -eq 1 ]; then
  IMPL_FILE_W49=$(find_session_artifact "IMPLEMENTATION_REPORT" || true)
  if [ -z "$IMPL_FILE_W49" ] || ! grep -qE '^UX_CRITIQUE_DEFERRED=' "$IMPL_FILE_W49" 2>/dev/null; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ UX_CRITIQUE_DEFERRED reference missing in IMPLEMENTATION_REPORT for this implementation-only session (${SESSION_ID}). UI files were modified. ACTION REQUIRED: the runner-managed session touched UI; the parent orchestrator must own the UX critique. Add a line of the form 'UX_CRITIQUE_DEFERRED=<orchestrator_session_id>' to IMPLEMENTATION_REPORT_<session>.md so the gate trail is preserved."
  fi
fi


# Model provenance warning (non-blocking)
if [ -n "$REVIEW_FILE" ] && [ -f "$REVIEW_FILE" ]; then
  MODEL_LINE=$(head -3 "$REVIEW_FILE" | grep -iE '^Model:' | head -1 || true)
  if [ -z "$MODEL_LINE" ]; then
    WARNINGS="$WARNINGS
  ⚠️ AGENT_REVIEW has no 'Model:' declaration on first 3 lines — expected 'Model: sonnet' for code review (haiku|sonnet|opus all validate; mechanical runners may declare haiku)."
  else
    DECLARED_MODEL=$(echo "$MODEL_LINE" | sed 's/^[Mm]odel:[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    # HOOK-9: accept haiku|sonnet|opus|fable per W13 tiered review models (+W71:
    # fable, the Claude 5 tier — honest labels must never be punished). Emit warning
    # only on truly unrecognized models (e.g., a typo or stale claude-3 reference).
    case "$DECLARED_MODEL" in
      haiku|sonnet|opus|fable|*haiku*|*sonnet*|*opus*|*fable*) ;;
      *)
        WARNINGS="$WARNINGS
  ⚠️ AGENT_REVIEW declares 'Model: ${DECLARED_MODEL}' — expected one of haiku|sonnet|opus|fable."
        ;;
    esac
  fi
fi

# PRE_FLIGHT content validation
if [ -n "$PREFLIGHT_FILE" ] && [ -f "$PREFLIGHT_FILE" ]; then
  FAILED_GATES=$(grep -iE '(❌|FAILED|FAIL|✗)[[:space:]]*(tests?|build|lint|typecheck|type.check|phpunit|vitest)' \
    "$PREFLIGHT_FILE" 2>/dev/null | grep -v '^\s*#' | head -5 || true)
  if [ -n "$FAILED_GATES" ]; then
    GATE_LIST=$(echo "$FAILED_GATES" | sed 's/^/    /')
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT has FAILED gates:
${GATE_LIST}
    Fix all failing gates before completing."
  fi

  # I2-PF (forensic 2026-06-18): BLOCK a CATASTROPHIC test-failure count
  # laundered as "BASELINE / pre-existing". The FAILED_GATES grep above needs FAIL *adjacent* to a gate
  # keyword, which "6712 passed, 7880 failed — pre-existing" evades; and the only pre-existing check
  # below is a non-blocking keyword grep silenced by the literal word "baseline". A run where failures
  # rival/exceed passes is a BROKEN TEST ENV (an unprovisioned worktree with no DB/.env), not a baseline.
  # Block (recoverable) UNLESS a REAL baseline diff is cited — a named base SHA / merge-base, not the
  # bare word. Threshold: >=100 failed, OR failed>=passed (broken env even at small N).
  # SREV-001..005 (adversarial review 2026-06-18): comma-tolerant, order-independent, with a standalone
  # failure-count arm gated on a pre-existing/baseline claim (the laundering signature) to stay FP-safe.
  _pf_block=""
  # Substantiation: a REAL baseline diff — named base SHA / merge-base / HEAD~ — NOT the bare word
  # "baseline" (SREV-003: a hex must be keyword-introduced as a SHA/commit, or sit next to merge-base,
  # so a git issue id like '#abc1234 ... baseline' cannot suppress the block).
  _pf_baseline_cited=0
  grep -qiE 'merge.?base|clean[[:space:]]*HEAD|HEAD~|base[[:space:]]*SHA|(commit|sha)[[:space:]:#=]*[0-9a-f]{7,40}|[0-9a-f]{7,40}[^.]{0,40}merge.?base' "$PREFLIGHT_FILE" 2>/dev/null && _pf_baseline_cited=1
  # W-PF-COMMA (2026-08-09): the count class below is `[0-9]([0-9]|,[0-9]){0,8}` — a comma is only
  # valid BETWEEN digits (a thousands separator), never trailing. It used to be `[0-9][0-9,]{0,8}`,
  # which happily matched a trailing FIELD separator, so "<N>, Failures" parsed <N> as the failure
  # count. Against PHPUnit's standard summary line that is catastrophic in BOTH directions:
  #
  #   Tests: 6105, Assertions: 25486, Failures: 1   old => 25486 (FALSE POSITIVE — blocked
  #                                                  a session on 2026-08-09 claiming
  #                                                  "25486 failed" for a 1-failure run)
  #   Tests: 6105, Assertions: 0, Failures: 6105    old => 0     (FALSE NEGATIVE — grep -o
  #                                                  consumes "Failures" inside the wrong match,
  #                                                  so the real count is never seen and the
  #                                                  broken-env case this detector EXISTS for
  #                                                  sails through)
  #
  # The number before "Failures" in that line is the ASSERTION count, never the failure count.
  # Guard the value where it is decided (the `Failures: N` field), not the token that precedes it.
  # Both arms share the class deliberately — the same swallow applies to either.
  # Bite: hooks/pf-catastrophic-comma-test.sh (8 cases incl. both directions above).
  #
  # (a) Paired "N passed, M failed" in EITHER order (SREV-002), comma-tolerant (SREV-001). Broken env =
  #     failed>=passed OR failed>=100.
  _pf_counts=$(grep -oiE '[0-9]([0-9]|,[0-9]){0,8}[[:space:]]+passed,?[[:space:]]+[0-9]([0-9]|,[0-9]){0,8}[[:space:]]+failed|[0-9]([0-9]|,[0-9]){0,8}[[:space:]]+failed,?[[:space:]]+[0-9]([0-9]|,[0-9]){0,8}[[:space:]]+passed' "$PREFLIGHT_FILE" 2>/dev/null | head -1 | tr -d ',')
  if [ -n "$_pf_counts" ]; then
    _pf_pass=$(printf '%s\n' "$_pf_counts" | grep -oiE '[0-9]+[[:space:]]+passed' | grep -oE '[0-9]+' | head -1)
    _pf_fail=$(printf '%s\n' "$_pf_counts" | grep -oiE '[0-9]+[[:space:]]+failed' | grep -oE '[0-9]+' | head -1)
    _pf_pass=${_pf_pass:-0}; _pf_fail=${_pf_fail:-0}
    if { [ "$_pf_fail" -ge 100 ] || { [ "$_pf_fail" -gt 0 ] && [ "$_pf_fail" -ge "$_pf_pass" ]; }; } 2>/dev/null; then
      _pf_block="${_pf_fail} failed / ${_pf_pass} passed"
    fi
  fi
  # (b) Standalone failure count with NO paired pass count (SREV-002/005: "7880 failures",
  #     "failures: 7880"). >=100 failures alone is unambiguous broken-env evidence — but to stay FP-safe
  #     it only fires when the report ALSO claims pre-existing/baseline (the exact laundering signature;
  #     a report bragging it "fixed 150 failures" carries no such claim).
  if [ -z "$_pf_block" ] && grep -qiE 'pre.?existing|baseline' "$PREFLIGHT_FILE" 2>/dev/null; then
    _pf_fail_only=$(grep -oiE '[0-9]([0-9]|,[0-9]){0,8}[[:space:]]+(tests?[[:space:]]+)?(failed|failures?)|(failed|failures?)[[:space:]:=]+[0-9]([0-9]|,[0-9]){0,8}' "$PREFLIGHT_FILE" 2>/dev/null | grep -oE '[0-9,]+' | tr -d ',' | sort -rn | head -1)
    _pf_fail_only=${_pf_fail_only:-0}
    [ "$_pf_fail_only" -ge 100 ] 2>/dev/null && _pf_block="${_pf_fail_only} failed"
  fi
  if [ -n "$_pf_block" ] && [ "$_pf_baseline_cited" -eq 0 ]; then
    BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT reports a CATASTROPHIC test-failure count (${_pf_block}) yet presents a clean gate. A run where failures rival or exceed passes is almost always a BROKEN TEST ENVIRONMENT (a worktree missing its DB/.env), not a pre-existing baseline — classifying it 'BASELINE/pre-existing' launders a non-functional gate into a PASS (forensic: 7880 failed in an unprovisioned worktree → 'BASELINE' → nearly shipped). ACTION REQUIRED: provision the test env and re-run so the suite actually executes, OR substantiate the pre-existing claim against a REAL baseline diff (failing-test NAMES vs a named base SHA / merge-base — the literal word 'baseline' is not proof). If the env is genuinely unrunnable, write BLOCKED_${SESSION_ID}.md instead of a PASS."
  fi

  # === W-perf-runner: PRE_FLIGHT independence (no silent inline degradation) ===
  # A CLEAN pre-flight on a code-changing session must come from an INDEPENDENT
  # v-pre-flight-runner subprocess, OR honestly declare the sanctioned degraded-inline
  # fallback. Root cause: a production session whose runner subprocess errored
  # (DISPATCH_PROVENANCE status=error/no_artifact) re-dispatched repeatedly, then
  # HAND-WROTE a clean PRE_FLIGHT_REPORT and presented it as a pass — the exact silent
  # inline degradation v-verbatim-dispatch.md §"NO SILENT INLINE DEGRADATION" forbids
  # (it loses the independent model + the W35 read-only scope protection; observed
  # incident). The documented fallback is retry-ONCE then BLOCKED_<sid>.md — never a
  # hand-written clean gate. This mirrors the W71 QA/UX/WF independence gate, reusing the
  # same _independence_verdict + DISPATCH_PROVENANCE machinery, and is SCOPED to a claimed
  # PASS (no FAILED_GATES) — a FAIL already blocks above, so independence is moot there.
  # silent → block; unverifiable (transcript unreadable) → warn, never block (no
  # false-block on sessions the hook can't introspect); declared/dispatched → allowed.
  if [ "$CODE_CHANGED" -eq 1 ] && [ -z "$FAILED_GATES" ]; then
    _PF_INDEP="$(_independence_verdict "$PREFLIGHT_FILE" v-pre-flight-runner)"
    case "$_PF_INDEP" in
      edited)
        # Blocking-grade: a hand-padded PRE_FLIGHT is exactly this shape.
        BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT was modified AFTER its independent v-pre-flight-runner dispatch (provenance sha256 mismatch — W5G-4). The runner's output is the canonical gate record (a prod session hand-padded a 766B runner report to 1425B under 'Model: haiku'). Re-dispatch /v-pre-flight via v-dispatch-subagent.sh, or — if the edit was a legitimate correction — add an explicit 'Post-dispatch edit: <what and why>' line (downgrades to a declared, warned fallback)." ;;
      edited-declared)
        # F2 (2026-08-29): dispatch on record + declared edit + original survives. The B1
        # verdict-flip guard below ALSO enumerates `edited-declared` and still fires — a declared
        # edit may fix prose but must never flip a dispatched gate's verdict (B1).
        WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT was edited after its independent v-pre-flight-runner dispatch and the edit is DECLARED ('Post-dispatch edit:'). The runner dispatch IS on record and the dispatched original survives (see .v/archive/<session>/) — this is NOT a hand-authored gate artifact and NO re-dispatch is required. The edit must not have changed any gate verdict." ;;
      declared)
        WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT declares a degraded-inline fallback (no independent v-pre-flight-runner dispatch found). Accepted as the sanctioned last resort, but the independent model + read-only scope protection are lost — prefer a real v-dispatch-subagent.sh dispatch when the subprocess is available." ;;
      unverifiable)
        WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT independence could not be verified (session transcript unavailable to the Stop hook). Ensure /v-pre-flight ran via v-dispatch-subagent.sh, not hand-authored." ;;
      silent)
        BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT appears hand-authored — it claims a clean pass, but no independent v-pre-flight-runner ran this session (no v-dispatch-subagent.sh --agent v-pre-flight-runner subprocess, no DISPATCH_PROVENANCE 'status=ok' record) and the report carries no honest 'Dispatch: degraded-inline' declaration. After a runner subprocess fails, the documented fallback is retry ONCE, then write BLOCKED_${SESSION_ID}.md — NOT to hand-write a clean gate artifact (the silent inline degradation v-verbatim-dispatch.md forbids; a production incident lost the independent model + read-only scope guard this way). ACTION REQUIRED: re-dispatch /v-pre-flight via v-dispatch-subagent.sh; if dispatch is genuinely unavailable, run the gate inline AND stamp the report with a 'Dispatch: degraded-inline (subprocess errored, independence lost)' header line so the lost independence is visible." ;;
    esac

    # B1 (forensic, 2026-06-21): a post-dispatch edit may correct PROSE/formatting (the
    # 'declared' escape above downgrades 'edited' -> warned), but it MUST NOT flip a dispatched gate's
    # VERDICT. One runner left the Pest gate INCONCLUSIVE (W57-F1 scanner-test); the orchestrator
    # hand-edited the dispatched artifact to PASS(baseline) AND declared the edit, so the 'declared' arm
    # only WARNed and the laundered pass shipped. When the report was edited/declared post-dispatch AND
    # still carries an INCONCLUSIVE/unresolved gate verdict (or discloses correcting/overriding a gate
    # verdict) under an overall PASS, the edit changed the verdict — BLOCK. FP-safe: scoped to the
    # already-narrow edited|declared + clean-PASS branch; an untampered ('dispatched') runner verdict
    # and a genuinely-clean report (no INCONCLUSIVE, no verdict-correction disclosure) never match.
    # F2 PRESERVATION (2026-08-29): `edited-declared` MUST be listed here. B1's whole premise IS the
    # dispatched-then-edited-then-declared shape, which is precisely what the new token
    # names — before the split that case arrived as `declared`. Omitting it would have removed the
    # anti-laundering guard from the only shape it was ever written to catch.
    if { [ "$_PF_INDEP" = "edited" ] || [ "$_PF_INDEP" = "declared" ] || [ "$_PF_INDEP" = "edited-declared" ]; } \
       && grep -qiE 'INCONCLUSIVE|correct(s|ed|ing)[^.]{0,40}(classification|verdict)|overr(o|i)d[^.]{0,30}(verdict|gate|classification)|flip[^.]{0,20}(verdict|gate)' "$PREFLIGHT_FILE" 2>/dev/null; then
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT was edited/declared AFTER dispatch AND still carries an INCONCLUSIVE/unresolved gate verdict (or discloses correcting a gate verdict) under an overall PASS. A post-dispatch edit may fix prose but MUST NOT flip a dispatched gate's verdict — the runner's verdict is canonical (forensic: the runner left Pest INCONCLUSIVE/W57-F1, the orchestrator hand-edited it to PASS). Resolve by ONE of: (a) RE-DISPATCH /v-pre-flight via v-dispatch-subagent.sh so a fresh runner verdict is canonical, (b) if the INCONCLUSIVE is a genuine false-positive scanner-test, clear it via a baseline diff-by-name (~/.claude/skills/references/v-core-pre-existing.md) and RE-RUN the runner — not by overwriting the verdict in place, (c) record the correction in a separate PRE_FLIGHT_ADDENDUM_${SESSION_ID}.md (its own provenance) rather than editing the dispatched artifact."
    fi

    # DURABLE GATE-SUMMARY CROSS-CHECK (forensic 2026-06-23): the verdict-flip detector ABOVE greps
    # the report PROSE for 'INCONCLUSIVE' — which one session SCRUBBED to dodge it, while the durable MACHINE record
    # gate-summary-<sid>.txt still recorded PEST_RC=INCONCLUSIVE (the worktree's vendor was symlinked to main so
    # Pest never validly ran; the report relabeled the unrun gate a 'pre-existing baseline' under PASS). The
    # machine record — not the scrubbable prose — is ground truth. A gate whose EFFECTIVE rc is INCONCLUSIVE
    # produced NO valid result and can NEVER be a clean pass. Block independent of prose + edit-status, so
    # scrubbing the word no longer hides an unrun gate. FP-safe: keys on '_RC=INCONCLUSIVE' (the effective
    # verdict) NOT '_RC_RAW=' (a downgraded/baseline-cleared raw is the legitimate case and is excluded); and is
    # scoped to CODE_CHANGED && no-FAILED_GATES (the report CLAIMS a clean PASS — no ❌/FAIL-prefixed gate row).
    # SREV-001 fix: search ARTIFACT_SEARCH_DIRS (computed above), NOT a hardcoded $REPO_ROOT pair — a WORKTREE
    # session (the actual observed shape) consolidates gate-summary to MAIN_ROOT/.v/artifacts, so a REPO_ROOT-only
    # search left FIX-3 silently inert for the exact case it closes.
    _GS_FILE=""
    # P1-3 (2026-06-30): prepend .v/tmp (where v-run-gates.sh WRITES the gate-summary). The CANARY-A cp to
    # .v/artifacts is `|| true` and can fail under fleet pressure (disk/perm/concurrent teardown), leaving an
    # INCONCLUSIVE record visible ONLY in .v/tmp — which ARTIFACT_SEARCH_DIRS omits → false-clear (same class).
    # v-stop-readiness.sh already searches .v/tmp; this aligns the real gate. SID-keyed filename ⇒ no cross-session
    # contamination. LOCAL candidate list ONLY — do NOT mutate the global ARTIFACT_SEARCH_DIRS (used at 7+ sites).
    for _gsd in "$REPO_ROOT/.v/tmp" "${MAIN_ROOT:-$REPO_ROOT}/.v/tmp" "${ARTIFACT_SEARCH_DIRS[@]}"; do
      [ -f "$_gsd/gate-summary-${SESSION_ID}.txt" ] || continue
      _GS_FILE="$_gsd/gate-summary-${SESSION_ID}.txt"; break
    done
    if [ -n "$_GS_FILE" ] && grep -qE '^[A-Z_]+_RC=INCONCLUSIVE$' "$_GS_FILE" 2>/dev/null; then
      _GS_INC=$(grep -oE '^[A-Z_]+_RC=INCONCLUSIVE$' "$_GS_FILE" 2>/dev/null | sed 's/_RC=INCONCLUSIVE//' | tr '\n' ' ' | sed 's/ *$//')
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT claims a clean PASS but the DURABLE gate-summary machine record ($_GS_FILE) records gate(s) [$_GS_INC] as RC=INCONCLUSIVE — a gate that produced NO valid result (broken vendor/symlink, an unrunnable suite, a scanner-test the runner could not classify) CANNOT be presented as a clean pass, regardless of the report's prose (forensic: the worktree vendor was symlinked to main so Pest never validly ran; the report SCRUBBED the word 'INCONCLUSIVE' and relabeled the unrun gate a 'pre-existing baseline' under PASS). The machine record is canonical. ACTION REQUIRED: fix the gate environment and RE-RUN the gate so it yields a valid PASS/FAIL, or — if it is a genuine W57-F1 scanner false-positive — clear it via baseline diff-by-name (~/.claude/skills/references/v-core-pre-existing.md) and RE-RUN the runner so the durable record shows a real verdict. Do NOT relabel an INCONCLUSIVE gate as PASS."
    fi
  fi

  # W44-E1 fix: same class as W40-A — `grep -c ... || echo "0"` produces a
  # two-line "0\n0" string when grep finds zero matches AND its `|| echo "0"`
  # fires. Use grep + wc -l instead; wc always exits 0 with a single integer.
  # W71-F13 (forensic 2026-07-02): the old grep was CASE-SENSITIVE while the canonical
  # report's gate column is Title-Case ("| PASS | Lint |", "| PASS | Build |", "| PASS | TypeScript |")
  # — a fully-populated 6-gate PASS table counted 0 rows and every complete report drew the
  # "may be incomplete" warning (specimen: a PRE_FLIGHT_REPORT counted 0, real rows 6).
  # Review RF2-1: count only real TABLE ROWS (line-start pipe, status as the first cell — the exact
  # shape v-run-gates.sh's skeleton emits) so case-insensitive STATUS words in prose ("passed: all
  # unit tests…") can never inflate the count and silence the warning on a gate-less report.
  # Threshold unchanged (never weaken).
  # === W-PF-GATEROWS BEGIN (2026-08-05) — count a verdict cell in ANY column =================
  # SECOND OCCURRENCE OF THIS CLASS. W71-F13 (2026-07-02) already fixed a CASE-SENSITIVITY variant
  # of this same regex for this same symptom ("every complete report drew the may-be-incomplete
  # warning"). It fixed the specific shape and kept the underlying assumption — that the verdict is
  # the FIRST table cell — so the bug recurred the moment the runner's skeleton put it elsewhere.
  # v-run-gates.sh now emits `| # | Gate | Command | Result | Notes |`, verdict in column 4.
  # Specimen: a PRE_FLIGHT_REPORT — 26,125 bytes, 10 fully-populated PASS rows — counted 0.
  # 4 of 5 trips in the corpus were false; the corrected pattern fixes 6 of 7 and preserves the one
  # report that genuinely has no gate rows.
  #
  # The anchor is now "a markdown table row (line-start pipe) whose verdict is a COMPLETE CELL, in
  # any column, optionally bold". `([^|]*\|)*` allows zero-or-more preceding cells, so the legacy
  # verdict-first shape still counts. The prose guard W71-F13 installed is intact and pinned by
  # T19: prose lines do not start with a pipe, so they can never inflate the count and silence a
  # genuinely gate-less report. Threshold unchanged at 2 (never weaken).
  # Bite: hooks/stop-advisory-hardening-test.sh (T15-T21).
  HAS_GATE_TABLE=$( ( grep -icE '^[[:space:]]*\|([^|]*\|)*[[:space:]]*(\*\*)?(PASS|FAIL|SKIP|SKIPPED|NOT_EVALUATED|ADVISORY|INCONCLUSIVE|✅|❌|✗|⚠️)(\*\*)?[[:space:]]*\|' \
    "$PREFLIGHT_FILE" 2>/dev/null || echo 0 ) | tr -d ' \n' )
  HAS_GATE_TABLE=${HAS_GATE_TABLE:-0}
  if [ "$HAS_GATE_TABLE" -lt 2 ]; then
    WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT may be incomplete — fewer than 2 gate results found."
  fi
  # === W-PF-GATEROWS END =====================================================================

  # === W71: a code-changing session may NOT satisfy the gate with the FULL TEST SUITE
  # skipped for time/budget reasons. A production session (2026-05-29) shipped a
  # PRE_FLIGHT_REPORT marking Build + Full Test Suite as SKIP ("exceeds wall-clock budget")
  # — not a sanctioned skip — and it passed; a later manual full run surfaced 150 failures
  # the report never saw. Legit skips (no test framework / no relevant files changed) state
  # that reason and are NOT matched by this time/budget pattern, so they remain allowed.
  if [ "$CODE_CHANGED" -eq 1 ]; then
    # W5G-4 DOUBLE-BIND FIX (forensic 2026-07-09): the sanctioned
    # 'Post-dispatch edit:' disclosure line — which the W5G-4 provenance gate REQUIRES on any
    # legitimate hand-correction — routinely NARRATES a historical partial pass ("the runner's
    # first dispatch skipped php/js…, full suite re-run three times…") and therefore matched
    # this scanner, making the two checks mutually unsatisfiable: adding the required disclosure
    # tripped the skip-block, and rewording looped (observed live: 2 reword cycles, identical
    # dual-blocks, which then pressured the session toward coaching the runner's verdict).
    # Exclude ONLY the disclosure line(s) from the BLOCK scan; the scanner still covers the
    # entire report body, so a skip admission anywhere else blocks exactly as before. A
    # disclosure line that itself matches the skip pattern surfaces as a WARNING below
    # (visibility preserved, no dead end).
    # W71-FP (2026-08-03): an honest gate row that PASSED and merely reports a NUMERIC
    # skipped-test count matched all 4 stages and silent-BLOCKED, e.g.
    #   | PHP Test Suite | PASS | 6077 tests, 10 skipped, 102s wall-clock |
    # Every real suite skips a few tests, so this false-fired on nearly every truthful
    # full-suite report. Exempt ONLY rows with an explicit PASS cell AND a numeric count;
    # '| Full Test Suite | PASS | skipped for time |' still BLOCKS (no vacuous-pass path).
    _pf_timeskip=$(grep -ivE '^[[:space:]]*Post-dispatch edit:' "$PREFLIGHT_FILE" 2>/dev/null \
      | grep -ivE '\|[[:space:]]*PASS[[:space:]]*\|.*[0-9]+[[:space:]]*skipped' \
      | grep -iE '(skip|partial|defer|not.?run|did.?n.?t run)' \
      | grep -iE '(full[[:space:]_-]*(test|suite)|test[[:space:]_-]*suite|pest|phpunit|vitest|jest|pytest)' \
      | grep -iE '(wall.?clock|budget|time|too[[:space:]]*(long|slow)|exceed|duration|minutes?|expensive)' \
      | head -3 || true)
    if [ -n "$_pf_timeskip" ]; then
      _ts_list=$(echo "$_pf_timeskip" | sed 's/^/    /')
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT skipped the FULL TEST SUITE for time/budget reasons — not a sanctioned skip. Code changed this session, so the full suite MUST run (policy: targeted tests during iteration, FULL suite once at the end via pre-flight). Re-dispatch /v-pre-flight to completion and record the real PASS/FAIL test result. Offending line(s):
${_ts_list}"
    else
      _pf_timeskip_note=$(grep -iE '^[[:space:]]*Post-dispatch edit:' "$PREFLIGHT_FILE" 2>/dev/null \
        | grep -iE '(skip|partial|defer|not.?run|did.?n.?t run)' \
        | grep -iE '(full[[:space:]_-]*(test|suite)|test[[:space:]_-]*suite|pest|phpunit|vitest|jest|pytest)' \
        | grep -iE '(wall.?clock|budget|time|too[[:space:]]*(long|slow)|exceed|duration|minutes?|expensive)' \
        | head -1 || true)
      if [ -n "$_pf_timeskip_note" ]; then
        WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT's 'Post-dispatch edit:' disclosure narrates a skipped/partial suite pass in its history. The disclosure line is exempt from the full-suite skip BLOCK (it is the sanctioned W5G-4 correction channel), but verify the Gates table reflects a COMPLETE final run, not the partial pass the note describes."
      fi
    fi

    # FAIL-VERDICT GATE (forensic 2026-07-09): nothing previously blocked a
    # PRE_FLIGHT_REPORT whose own verdict is FAIL/BLOCK — a failing gate report could complete a
    # code-changing session (artifact-presence, structure, and provenance checks all pass on an
    # honest FAIL). That gap also fed verdict-coaching: with no gate consuming FAIL, the only
    # pressure on the verdict word was cosmetic. Block explicitly and name the sanctioned exits.
    # Adversarial-review hardening (same forensic): judge only the LAST 'Overall Status' line —
    # a report documenting a failed-then-fixed history must not false-block on the earlier FAIL —
    # and tolerate whitespace before the colon so 'Overall Status : FAIL' cannot evade the gate.
    _pf_last_verdict="$(grep -iE '^[-* ]*(\*\*)?Overall Status(\*\*)?[[:space:]]*:' "$PREFLIGHT_FILE" 2>/dev/null | tail -1 || true)"
    if printf '%s\n' "$_pf_last_verdict" | grep -qiE ':[[:space:]]*(\*\*)?(FAIL|BLOCK)([^A-Za-z_-]|$)'; then
      BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ PRE_FLIGHT_REPORT's own verdict is FAIL/BLOCK — a failing pre-flight cannot complete a code-changing session. Resolve by ONE of: (a) fix the failing gates and re-dispatch /v-pre-flight to a real PASS, or (b) if EVERY failure is pre-existing, prove it via a baseline diff (failing-test NAME reproduced on clean HEAD/merge-base, per v-core-pre-existing.md) and re-dispatch the RUNNER with that baseline evidence in its prompt so it records 'Overall Status: PASS' with a 'PRE-EXISTING (baseline <sha>)' annotation itself — never hand-edit the verdict word (W5G-4 provenance) and never instruct a resumed runner to flip it without the baseline proof."
    fi

    # Pre-existing-failure classification requires a baseline diff (per v-core-pre-existing.md:
    # filename non-overlap is NOT proof of pre-existence — a changed source file can break an
    # unchanged scanner/contract test). If the report asserts pre-existing failures with no
    # baseline reference, warn so a session-introduced break can't hide among them.
    if grep -qiE 'pre.?existing' "$PREFLIGHT_FILE" 2>/dev/null \
       && ! grep -qiE 'baseline|merge.?base|clean[[:space:]]*HEAD|HEAD~|before[[:space:]]*(this[[:space:]]*)?session|predates' "$PREFLIGHT_FILE" 2>/dev/null; then
      WARNINGS="$WARNINGS
  ⚠️ PRE_FLIGHT_REPORT claims 'pre-existing' failures without a baseline reference. Filename non-overlap is NOT proof of pre-existence — a changed source file can break an unchanged (scanner/contract) test. Confirm each via a baseline diff (failing-test NAME vs clean HEAD/merge-base) or treat it as session-relevant."
    fi
  fi
fi

# === W71 MODEL POLICY (non-blocking): surface active /v cost lane ===
# Claude Code does NOT honor skill frontmatter for INLINE `/v` invocations; /v inherits
# the user's active /model. The old W71 posture warned on non-Opus sessions, which
# nudged routine work into the highest-cost lane. Keep the visibility, invert the nudge:
# Sonnet is expected for routine /v, while Opus is surfaced as a high-cost lane that
# should be reserved for planning/security/payment/data-loss review slices.
if [ "$CODE_CHANGED" -eq 1 ] && [ "${IS_V_INVOCATION_VIA_HISTORY:-0}" -eq 1 ] && [ "${TRANSCRIPT_READABLE:-0}" -eq 1 ]; then
  # Reads the pre-extracted $_TX_SIGNALS buffer (built once above), not the transcript file.
  _seen_model=$(printf '%s\n' "$_TX_SIGNALS" | grep -oE '"model":"claude-[A-Za-z0-9._-]*"' | tail -1 | sed -E 's/"model":"//; s/"$//')
  if printf '%s\n' "$_TX_SIGNALS" | grep -qE '"model":"[^"]*opus[^"]*"'; then
    WARNINGS="$WARNINGS
  V_MODEL_POLICY=opus_active_high_cost:${_seen_model:-opus}. Inline /v inherits your active /model; Opus is the high-cost lane and should be reserved for high-risk planning/security/payment/data-loss slices."
  elif printf '%s\n' "$_TX_SIGNALS" | grep -qE '"model":"[^"]*sonnet[^"]*"'; then
    WARNINGS="$WARNINGS
  V_MODEL_POLICY=sonnet_active_expected:${_seen_model:-sonnet}. Routine inline /v is on the expected lower-cost lane."
  elif [ -n "$_seen_model" ]; then
    WARNINGS="$WARNINGS
  V_MODEL_POLICY=active_model:${_seen_model}. Inline /v inherits the active /model; routine work should normally run on Sonnet."
  fi
fi

# === P2-BITE-LEDGER: TDD bite evidence gate (audit 2026-06-19) ===
# When a session changes a "tracked invariant" file (hooks/, hooks/lib/,
# skills/v/references/, or scripts/) it MUST record a bite in BITE_LEDGER_<sid>.md
# via v-bite-ledger.sh proving the test was RED pre-fix and GREEN post-fix.
# Mode: V_BITE_GATE=block|warn|off  (default=block; set V_BITE_GATE=warn or off to dial back)
# NOTE (adversarial review 2026-08-31): an earlier version of this change ALSO read the ecosystem
# writes log here and merged it into this repo's invariant-dir determination. That was removed.
# Two reasons. (a) REDUNDANT: the ecosystem log is only ever WRITTEN when the session is NOT inside
# a git work tree, while this gate only runs when it IS — a single session with a stable cwd can
# never legitimately populate both. (b) UNSOUND: that path is keyed ONLY by SESSION_ID and resolves
# against $HOME/.claude regardless of which repo is running, with no repo/cwd binding on the read
# side — so any context where one SID spans two working directories could make a real project repo
# inherit ~/.claude entries and demand a bite for a file that does not exist in it. The ~/.claude
# case is fully covered by the dedicated block near the top of this file, which IS cwd-scoped.
if [ "${V_BITE_GATE:-block}" != "off" ] && [ "${CODE_CHANGED:-0}" -eq 1 ] && [ -n "${SESSION_ID:-}" ]; then
  # _BITE_INVARIANT_DIRS is single-sourced at the ecosystem-reach block above so the two bite
  # checks can never drift on WHICH directories are invariant.
  : "${_BITE_INVARIANT_DIRS:=hooks/ hooks/lib/ skills/v/references/ scripts/}"
  _bite_invariant_changed=0
  _bite_changed_dirs=""
  # ORCHFIX-H7 (forensics 2026-07-02, F-7): filter GHOST writes-log entries — a file
  # created then DELETED during the session stays in the writes-log and demanded a bite for work
  # that no longer exists; the session then RESTORED the deleted file as a new deliverable just to
  # satisfy the gate (inverted causality, scope expansion beyond the finding). An entry obligates a
  # bite only if it still exists ON DISK or appears in the session's COMMITTED diff
  # (head-baseline..HEAD) — a committed deletion of an invariant file still counts (removing a
  # guard deserves a bite); an uncommitted create-then-delete is a no-op.
  _bite_base=""
  for _bbf in "${V_TMP_DIR_RESOLVED:-}/head-baseline-${SESSION_ID}.txt" "$REPO_ROOT/.v/tmp/head-baseline-${SESSION_ID}.txt"; do
    [ -n "$_bbf" ] && [ -f "$_bbf" ] && { _bite_base="$(head -1 "$_bbf" 2>/dev/null)"; break; }
  done
  _bite_committed=""
  [ -n "$_bite_base" ] && _bite_committed="$(git -C "$REPO_ROOT" diff --name-only "${_bite_base}..HEAD" 2>/dev/null || true)"
  _bite_writes_live="$(get_session_writes "$SESSION_ID" 2>/dev/null | while IFS= read -r _bw; do
      [ -z "$_bw" ] && continue
      if [ -e "$REPO_ROOT/$_bw" ] || { [ -n "$_bite_committed" ] && printf '%s\n' "$_bite_committed" | grep -qxF "$_bw"; }; then
        printf '%s\n' "$_bw"
      fi
    done)"
  for _bdir in $_BITE_INVARIANT_DIRS; do
    _bite_hit=0
    if printf '%s\n' "$_bite_writes_live" | grep -q "^${_bdir}"; then
      _bite_hit=1
    # Fallback (NOT session-attributed — only when the writes log is unavailable, mirroring
    # the CODE_CHANGED gate's WRITES_LOG_AVAILABLE guard at ~line 435). Without this guard a
    # CONCURRENT session's uncommitted invariant-dir change in the shared working tree would
    # falsely trip THIS session's bite gate. [SREV-002, codex review 2026-06-19]
    elif [ "$WRITES_LOG_AVAILABLE" -eq 0 ] && [ -n "${REPO_ROOT:-}" ] && git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | grep -q "^${_bdir}"; then
      _bite_hit=1
    fi
    # Accumulate ALL changed dirs (no early break) so the ledger content-check below can require a
    # bite that names a file under a dir THIS session actually changed. [P2-LEDGER-CONTENT, 2026-06-19]
    if [ "$_bite_hit" -eq 1 ]; then
      _bite_invariant_changed=1
      _bite_changed_dirs="${_bite_changed_dirs}${_bite_changed_dirs:+ }${_bdir}"
    fi
  done

  if [ "$_bite_invariant_changed" -eq 1 ]; then
    # v-bite-ledger.sh writes the ledger to $HOME/.claude by DEFAULT, but a /v session's
    # REPO_ROOT is the PROJECT repo — search BOTH locations or the escape never matches for
    # project-repo sessions (the ledger would be permanently invisible). [SREV-001, codex review 2026-06-19]
    _bite_ledger_file=""
    for _bld in "${REPO_ROOT:-$HOME/.claude}" "$HOME/.claude"; do
      if [ -f "$_bld/BITE_LEDGER_${SESSION_ID}.md" ]; then _bite_ledger_file="$_bld/BITE_LEDGER_${SESSION_ID}.md"; break; fi
    done
    # P2-LEDGER-CONTENT (audit 2026-06-19): existence is NOT enough — a `touch`ed / hand-forged ledger
    # used to satisfy the now-BLOCKING gate. Validate the content: a missing OR invalid ledger blocks.
    # Defensive `type` guard: if validate_bite_ledger is not defined (validation.sh failed to load, OR a
    # test injected an OLDER lib via V_VALIDATION_LIB that predates this fn), fall back to existence-only
    # so a lib-load/version-skew can never FALSE-block (the e2e/parity guards inject pre-fn baks this way).
    # SREV-003 (codex review 2026-06-19): this fallback IS reachable by a same-UID actor who sets
    # V_VALIDATION_LIB=/dev/null — but that is WITHIN the documented same-UID forgery ceiling (such an actor
    # can hand-craft a valid-looking ledger anyway), so fail-OPEN here is the right trade vs false-blocking
    # the test infra. Do NOT "harden" to fail-closed without accounting for the V_VALIDATION_LIB bak seam.
    _bite_reason=""
    if [ -z "$_bite_ledger_file" ]; then
      _bite_reason="BITE_LEDGER_${SESSION_ID}.md was not found"
    elif type validate_bite_ledger >/dev/null 2>&1 && ! _bite_vmsg="$(validate_bite_ledger "$_bite_ledger_file" "$_bite_changed_dirs" 2>&1)"; then
      _bite_reason="BITE_LEDGER_${SESSION_ID}.md is present but INVALID — ${_bite_vmsg}"
    fi
    if [ -n "$_bite_reason" ]; then
      _bite_msg="P2-BITE-LEDGER: this session changed a tracked invariant file (${_bite_changed_dirs}) but ${_bite_reason}. TDD discipline requires proving the test was RED pre-fix and GREEN post-fix via: bash ~/.claude/skills/v/references/v-bite-ledger.sh --invariant <path> --harness <test> --red-exit <N> --green-exit 0 [--note <description>]"
      if [ "${V_BITE_GATE:-block}" = "block" ]; then
        BLOCKING_ISSUES="${BLOCKING_ISSUES}
  ${_bite_msg}"
      else
        WARNINGS="${WARNINGS}
  ⚠️ ${_bite_msg}"
      fi
    fi
  fi
fi
# === end P2-BITE-LEDGER ===

# === WAIT-STRAND net (H4-1b, PLAN_2026-07-02_orchestrator-hardening-4) ===
# Closes the third wait-strand enforcement gap alongside block-v-polling.sh's PreToolUse denial
# (H4-1a) and v-merge-back.sh's synchronous re-verify (H4-1c). PreToolUse only catches a
# wait-shaped TOOL CALL (Monitor/until-sleep); it cannot see a turn that ends on a *prose* promise
# to wait (no further tool call at all) — e.g. one fork hung waiting on
# v-dispatch-subagent.sh's internal watchdog child with no notification, and two other sessions
# ended turns waiting on backgrounded Agent reviews. Detect the pattern at Stop time instead: code
# changed, the gauntlet is incomplete, and the final assistant message reads like a promise to
# wait rather than an in-progress poll. Same dial idiom as ABANDON-ENRICH: default WARN (durable
# trace + stderr guidance), never silently BLOCK until soak proves 0 false fires.
_WS_GATE_MODE="${V_WAIT_GATE:-warn}"
if [ "$_WS_GATE_MODE" != "off" ] && [ "${CODE_CHANGED:-0}" -eq 1 ] \
   && { [ "${MISSING_PREFLIGHT:-0}" -eq 1 ] || [ "${MISSING_REVIEW:-0}" -eq 1 ] || [ "${MISSING_VERIFY:-0}" -eq 1 ]; }; then
  if printf '%s' "$LAST_MSG" | grep -qiE 'wait(ing)?[[:space:]]+for[[:space:]].{0,60}(notification|monitor|to[[:space:]]+land|report[[:space:]]+to[[:space:]]+arrive)|I.?ll[[:space:]]+(pause|resume)[[:space:]]+(here|when)'; then
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "${SESSION_ID:-nosid}" \
       '{"ts":$ts,"sid":$sid,"event":"wait-strand"}' >> "$HOME/.claude/abandonments.jsonl" 2>/dev/null || true
    _ws_msg="WAIT-STRAND (H4-1b, mode=${_WS_GATE_MODE}): the final message reads like a promise to wait for a notification/monitor/report to land, while the gauntlet is still incomplete (code changed, pre-flight/review/verify-done not all present). Waiting passively STRANDS the session — poll via the BashOutput tool or re-issue the dispatch as a BLOCKING foreground call; never end a turn on 'I'll wait/pause here'."
    if [ "$_WS_GATE_MODE" = "block" ]; then
      BLOCKING_ISSUES="${BLOCKING_ISSUES}
  ❌ ${_ws_msg}"
    else
      WARNINGS="${WARNINGS}
  ⚠️ ${_ws_msg}"
    fi
  fi
fi
# === end WAIT-STRAND net ===

# === P1A-LOOKAHEAD-W59 (2026-07-03) ===
# Single-source predicate for the LAYER-3 hostile-inline signature, so the aggregation-time
# lookahead below and the LAYER-3 gate itself cannot drift (the dup-grep/contract-drift class).
# Reproduces LAYER-3's exact nested structure: hostile-focus grep AND any dispatch-mode-inline grep.
_w59_f2_signature() {  # $1 = AGENT_REVIEW file; rc 0 = hostile-focus + inline-dispatch admitted
  local _f="$1"
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  grep -qiE '(\*\*)?Hostile[[:space:]]+adversarial[[:space:]]+focus(\*\*)?:[[:space:]]*\**yes\**' "$_f" || return 1
  grep -qiE '(\*\*)?Dispatch[[:space:]]+mode(\*\*)?:[[:space:]]*\**(orchestrator[-_]inline|inline)\**' "$_f" \
    || grep -qiE 'orchestrator[-_]inline[[:space:]]+fallback' "$_f" \
    || grep -qiE 'inline[[:space:]]+(self[-_])?review' "$_f" \
    || grep -qiE 'same[-_]model[[:space:]]+review' "$_f"
}
# If we are about to block anyway AND the present AGENT_REVIEW carries the hostile-inline
# signature, surface the LAYER-3 verdict in the SAME message instead of letting it burn its own
# round after the artifact issues are fixed (round-3 of a death-march). LAYER-3 below
# still owns the standalone case (BLOCKING_ISSUES empty) — WHAT blocks is unchanged.
if [ -n "$BLOCKING_ISSUES" ] && [ -n "${SESSION_ID:-}" ] && _w59_f2_signature "${REVIEW_FILE:-}"; then
  BLOCKING_ISSUES="$BLOCKING_ISSUES
  ❌ (round-2 lookahead, W59-F2) AGENT_REVIEW declares 'Hostile adversarial focus: yes' AND admits orchestrator-inline dispatch — hostile-focus sessions REQUIRE a subagent-dispatched review (codex-adversarial-reviewer or superpowers fallback). Fix IN THE SAME pass: dispatch the hostile reviewer properly and replace AGENT_REVIEW, or (only if the diff genuinely is not sensitive) remove the 'Hostile adversarial focus: yes' line."
fi
# === end P1A-LOOKAHEAD-W59 ===

# === W-GATECONC RETIRED (2026-08-05) — do NOT rebuild a timestamp-spread detector ==========
# What stood here: a detector warning when N distinct gate agents' FIRST dispatch timestamps
# spread over >90s, on the theory that batched dispatch lands within seconds and an
# await-then-dispatch loop spreads over minutes. It was measured against the real corpus and had
# NO discriminating power whatsoever. Over 105 dispatch rounds in 47 sessions:
#
#   * the canonical known-SERIALIZED forensic (an observed session, "each awaited before the next") measured
#     161s — the 15th PERCENTILE. It is one of the TIGHTEST rounds in the whole corpus.
#   * the median round measured 726s, and 85% of ALL rounds exceeded the 90s threshold, including
#     rounds verified by hand as correctly batched (round 2 of one session: 5 agents in 126s).
#   * so any threshold catching the motivating case fires on ~85% of sessions, and any threshold
#     sparing good batches misses that case by ~10x. It fired on 40 of 47 sessions.
#
# WHY THE PROXY IS STRUCTURALLY WRONG: provenance rows are written when a subprocess starts or
# completes, not when the orchestrator EMITS the dispatch — and the recommended concurrent path
# (v-agent-review.md "Concurrent reviewer dispatch") writes `--mode capture` rows at COMPLETION.
# One perfectly-batched round whose slowest agent takes 20 min therefore "spreads" 20 min and is
# indistinguishable from serial dispatch.
#
# AND NO CORRECT SIGNAL EXISTS TO REBUILD IT FROM:
#   - interval overlap is impossible: `agent-tool` provenance rows carry duration_ms=0 (0 of 235
#     usable in the corpus) — precisely the rows for the dispatches most likely to serialize.
#   - the transcript cannot measure batching either: 0 of 14,802 assistant records hold >=2
#     tool_use blocks, i.e. the writer splits every tool call into its own record, so
#     "gate agents dispatched per message" is not observable there.
#
# Concurrent dispatch remains the documented DEFAULT (v-agent-review.md).
# It is simply not measurable from here, and an advisory that
# fires on 85% of sessions is noise that trains the reader to ignore the whole channel.
# Guard: hooks/stop-advisory-hardening-test.sh (T22/T23).
# === end W-GATECONC RETIRED ================================================================

if [ -n "$BLOCKING_ISSUES" ]; then
  # === W-BLOCK-REPEAT BEGIN (2026-08-06) — compact an unchanged repeat block ==================
  # A blocked session WAITING on in-flight gate dispatches re-Stops every turn and re-prints the
  # identical message. One session: 87 block messages, 63 CONSECUTIVE-IDENTICAL (72%),
  # longest identical run 10, ~69k tokens of verbatim repetition in ONE session. Corpus-wide the
  # blocking channel carries ~598k tokens of byte-identical repeats — 27x the advisory channel.
  #
  # SEPARABLE CONCERNS: whether to block, and how much text to print, are different decisions.
  # This changes only the second. The gate still exits 2, and BLOCKING_ISSUES — the actionable
  # list — is ALWAYS printed in full. Only derived/static sections are dropped on a repeat: the
  # artifact BOARD (re-derived each time), the static ONE-PASS ORDER, and non-blocking WARNINGS.
  #
  # KEYED ON BLOCKING_ISSUES + WARNINGS, not on the rendered message, so the board subprocess can
  # be SKIPPED entirely on a repeat — saving a process spawn per wait-tick as well as the tokens.
  # CAPPED so an unbroken run re-emits in full periodically: context compaction can evict the
  # earlier copy, and a session that never sees the order again is the death-march P1D-ORDER
  # exists to prevent. Any change to the blocking set re-emits immediately.
  # FAILS OPEN: no SESSION_ID / no tmp dir / unhashable / unwritable state => always FULL.
  # Bite: hooks/stop-advisory-hardening-test.sh (T24-T31).
  _blk_compact=0
  _blk_key=""
  if [ -n "${SESSION_ID:-}" ] && [ -n "${V_TMP_DIR_RESOLVED:-}" ]; then
    _blk_key=$(printf '%s\n---\n%s' "$BLOCKING_ISSUES" "$WARNINGS" | shasum -a 256 2>/dev/null | awk '{print $1}')
    case "$_blk_key" in ''|*[!0-9a-fA-F]*) _blk_key="" ;; esac
  fi
  if [ -n "$_blk_key" ]; then
    _blk_state="$V_TMP_DIR_RESOLVED/block-digest-${SESSION_ID}.txt"
    _blk_prev=""; _blk_n=0
    if [ -r "$_blk_state" ]; then
      _blk_prev=$(awk 'NR==1{print $1}' "$_blk_state" 2>/dev/null || true)
      _blk_n=$(awk 'NR==1{print $2}' "$_blk_state" 2>/dev/null || true)
      case "$_blk_n" in ''|*[!0-9]*) _blk_n=0 ;; esac
    fi
    if [ "$_blk_prev" = "$_blk_key" ] && [ "$_blk_n" -lt "${V_BLOCK_REPEAT_MAX:-3}" ]; then
      _blk_compact=1; _blk_n=$((_blk_n + 1))
    else
      _blk_n=0
    fi
    mkdir -p "$V_TMP_DIR_RESOLVED" 2>/dev/null || true
    printf '%s %s\n' "$_blk_key" "$_blk_n" > "$_blk_state" 2>/dev/null || true
  fi
  # === W-BLOCK-REPEAT END ====================================================================
  WARN_SECTION=""
  if [ -n "$WARNINGS" ] && [ "${_blk_compact:-0}" -eq 0 ]; then
    WARN_SECTION=$'\n\nWarnings (non-blocking):\n'"$WARNINGS"
  fi
  # === P1A-BOARD (2026-07-03) ===
  # Embed the full artifact board (v-artifact-validate-all.sh — the SAME validators this hook
  # uses, via hooks/lib/validation.sh) in the FIRST block message, so the session sees every
  # present/absent/invalid artifact at once and remediates in ONE pass instead of a
  # guess-and-check round per artifact. Runs ONLY on the block path (zero cost on clean stops);
  # best-effort — a missing/failed board script degrades to the plain message, never blocks on
  # its own. Bounded to 30 lines so a pathological validator message cannot flood the context.
  _P1A_BOARD_SCRIPT="${V_ARTIFACT_BOARD:-$HOME/.claude/skills/v/references/v-artifact-validate-all.sh}"
  _p1a_board=""
  if [ -f "$_P1A_BOARD_SCRIPT" ] && [ -n "${SESSION_ID:-}" ] && [ "${_blk_compact:-0}" -eq 0 ]; then
    _p1a_board=$(bash "$_P1A_BOARD_SCRIPT" "$SESSION_ID" "${ARTIFACT_SEARCH_DIRS[@]}" 2>/dev/null | head -30 || true)
  fi
  BOARD_SECTION=""
  [ -n "$_p1a_board" ] && BOARD_SECTION=$'\n\nFULL ARTIFACT BOARD (structure state of every gauntlet artifact — fix everything below in ONE pass):\n'"$_p1a_board"
  # === end P1A-BOARD ===
  # === P1D-ORDER (2026-07-07) ===
  # Forensic: 14 block-rounds of remediation churn — artifacts were produced one
  # round at a time, and the attest witness went STALE after every later artifact edit (it
  # binds artifact content hashes), so the session re-blocked on the witness ~8 times. The
  # board (P1A) shows WHAT is missing; this section states the ORDER so the whole remediation
  # fits in ONE round. Message-only — gating logic unchanged.
  # W-BLOCK-REPEAT: on an unchanged repeat this static text is replaced by a one-line pointer.
  # It reappears in full on any change to the blocking set, and periodically within a long run.
  ORDER_SECTION=$'\n\n(unchanged since the previous block — artifact board, remediation order and non-blocking warnings omitted as a verbatim repeat. They reappear in full on any change, and periodically if nothing changes. If gate dispatches are still in flight, this block is expected: wait for them rather than re-dispatching.)'
  [ "${_blk_compact:-0}" -eq 0 ] && ORDER_SECTION=$'\n\nONE-PASS REMEDIATION ORDER (complete ALL applicable items in THIS round, then stop once; skip items the board already marks ok):\n  1) /v-pre-flight — full suite, explicit Bash timeout 600000 (a 2-min-truncated \'partial\' suite is rejected, not a sanctioned skip) — and agent review (may run concurrently)\n  2) /v-verify-done\n  3) IMPACT_MAP (Step 1.8 protocol; UI sessions: also UX_CRITIQUE + WORKFLOW_VERIFICATION)\n  4) QA acceptance loop (v-qa-reviewer) to verdict: pass\n  5) scoped git checkpoint of session-owned files (never git add -A)\n  6) LAST: bash ~/.claude/skills/v/references/v-gauntlet-attest.sh — the witness binds artifact CONTENT hashes, so it MUST be re-run after ANY artifact is edited; running it before steps 1-5 finish guarantees another block on a stale witness.'
  # === end P1D-ORDER ===
  # W42-F1: stderr text + exit 2 is sufficient for Stop blocking (see above).
  # === W-INFLIGHT (2026-09-05, cohort forensic) — name the agents still running ========
  # 121 Stop blocks in 43 min, 107 of them turns whose only action was a ListAgents poll: the
  # session had dispatched background Agent-tool subagents to PRODUCE the missing artifacts, then
  # ended its turn to wait for them — and a Stop with unmet gates is blocked every time, so each
  # wait became a full-context turn (144 M cache-read tokens). 117 of those 120 blocks had
  # ≥1 Agent call with no completion notification yet. The gates were RIGHT; the turns were waste.
  # MESSAGE-ONLY: appended to $CTX, never to $_blk_fp_ctx (W-BLOCK-FP: presentation must not move
  # the escape counter) and never to BLOCKING_ISSUES/WARNINGS. Fails open: an unreadable transcript,
  # a missing `date -j`, or any parse oddity yields an empty section. Cost: two greps over the
  # transcript. An Agent tool_use is "in flight" when no <task-notification> carries its
  # <tool-use-id> and it was launched within the last 90 min (a killed agent never notifies —
  # the age bound keeps a dead one from haunting every later block).
  # Bite: hooks/inflight-advisory-test.sh.
  # One line per Agent tool_use block: "<toolu id> <record timestamp> <subagent_type|agent>".
  # A transcript LINE is one assistant message and may hold SEVERAL parallel Agent blocks, so ids
  # are cut per block (grep -o) and paired positionally with the line's subagent_type values —
  # never one sed over the whole line, which would collapse N parallel dispatches into one.
  _if_list() {
    local _l _ts _ids _tys
    grep -E '"type":"tool_use","id":"toolu_[A-Za-z0-9]+","name":"Agent"' "$1" 2>/dev/null \
    | while IFS= read -r _l; do
        _ts=$(printf '%s' "$_l" | sed -nE 's/^.*"timestamp":"([^"]+)".*$/\1/p')
        # Split the line into one segment PER tool_use block, then read id + type from the SAME
        # segment (repro panel 2026-09-08: a whole-line type scan paired positionally shifted every
        # label after a block that lacked subagent_type). The type is read from the block's own
        # input only: a segment's text ends where the next tool_use block begins.
        printf '%s\n' "$_l" | sed 's/{"type":"tool_use","id":"/\
{"type":"tool_use","id":"/g' \
        | grep -E '^\{"type":"tool_use","id":"toolu_[A-Za-z0-9]+","name":"Agent"' \
        | while IFS= read -r _seg; do
            _id=$(printf '%s' "$_seg" | sed -nE 's/^\{"type":"tool_use","id":"(toolu_[A-Za-z0-9]+)".*$/\1/p')
            _ty=$(printf '%s' "$_seg" | grep -oE '"subagent_type":"[A-Za-z0-9_:-]*"' | head -1 | sed -E 's/^.*:"([^"]*)"$/\1/')
            [ -n "$_id" ] && printf '%s %s %s\n' "$_id" "${_ts:-1970-01-01T00:00:00Z}" "${_ty:-agent}"
          done
      done
  }
  INFLIGHT_SECTION=""
  if [ "${TRANSCRIPT_READABLE:-0}" -eq 1 ]; then
    _if_now=$(date -u +%s 2>/dev/null || echo 0)
    _if_done=$(grep -oE '<tool-use-id>toolu_[A-Za-z0-9]+' "$TRANSCRIPT_PATH" 2>/dev/null | sed 's/<tool-use-id>//' | sort -u)
    _if_n=0; _if_types=""
    while IFS= read -r _if_line; do
      [ -n "$_if_line" ] || continue
      _if_id="${_if_line%% *}"; _if_rest="${_if_line#* }"; _if_ts="${_if_rest%% *}"; _if_type="${_if_rest#* }"
      case "$_if_id" in toolu_*) ;; *) continue ;; esac
      printf '%s\n' "$_if_done" | grep -qx "$_if_id" && continue
      _if_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${_if_ts%%.*}" +%s 2>/dev/null || date -u -d "${_if_ts%%.*}" +%s 2>/dev/null || echo "")
      case "$_if_epoch" in ''|*[!0-9]*) continue ;; esac
      [ $(( _if_now - _if_epoch )) -le 5400 ] || continue
      _if_n=$((_if_n + 1)); _if_types="${_if_types}${_if_types:+, }${_if_type}"
    done <<EOF_IF
$(_if_list "$TRANSCRIPT_PATH")
EOF_IF
    if [ "$_if_n" -gt 0 ] 2>/dev/null; then
      INFLIGHT_SECTION=$'\n\n'"⏳ IN-FLIGHT SUBAGENTS: ${_if_n} Agent tool call(s) launched in the last 90 min have not returned a completion notification (${_if_types}). If the missing artifacts above are being produced by those agents, do NOT end the turn to wait for them — every Stop with unmet gates is blocked, and each block re-runs this hook and costs a full-context turn (measured: 107 no-op turns in one session). Wait on them synchronously instead: call TaskOutput (blocking) for each task id, or Monitor, then re-check the gates in the SAME turn."
    fi
  fi
  # === end W-INFLIGHT ==========================================================================
  CTX="COMPLETION BLOCKED — artifact gates not satisfied:"$'\n'"$BLOCKING_ISSUES$BOARD_SECTION$ORDER_SECTION$WARN_SECTION$INFLIGHT_SECTION"$'\n\n'"Address all issues before the session can complete."
  # === W-BLOCK-FP BEGIN (2026-08-06) — fingerprint the VIOLATION, never the rendered text ====
  # rearm_gate() fingerprints whatever string it is handed and counts CONSECUTIVE identical
  # fingerprints; exceeding STOP_REARM_MAX_SAME (default 2) triggers the deadlock escape that
  # stops a session looping forever. Handing it $CTX coupled that safety counter to PRESENTATION:
  # once W-BLOCK-REPEAT began alternating full/compact renderings, the fingerprint alternated too
  # and `same` stopped accumulating. Measured against the real rearm_gate: escape slipped from
  # block 3 to block 4 (a delay, not a defeat — STOP_REARM_MAX_TOTAL still bounds it).
  #
  # The general principle, and the reason this is a separate sentinel: a change to how a message
  # is DISPLAYED must never move control state. Fingerprint the stable violation set
  # (BLOCKING_ISSUES + WARNINGS) — identical whether the render was full or compact — so the
  # escape counter behaves exactly as it did before compaction existed, and any future rendering
  # change is inert here by construction.
  # Bite: hooks/stop-advisory-hardening-test.sh (T32).
  _blk_fp_ctx="COMPLETION BLOCKED — artifact gates not satisfied:"$'\n'"$BLOCKING_ISSUES"$'\n'"$WARNINGS"
  # === W-BLOCK-FP END =======================================================================
  if _cra_block_gate "$_blk_fp_ctx"; then
    printf '%s\n' "$CTX" >&2
    exit 2
  fi
  exit 0  # W5G-1 deadlock escape (warning already on stderr)
fi

# === W-ADVISORY-IDEM BEGIN (2026-08-05) — do not replay an advisory the session already saw ===
# The Stop hook fires on EVERY assistant turn, and CODE_CHANGED is SESSION-cumulative (writes-log
# + commits since the SessionStart head-baseline). Once a session has changed code, every advisory
# above is re-evaluated and re-printed on every later Stop — including turns whose only content was
# a user question. Two advisory families can never clear in-session at all, because they derive
# from append-only history rather than from current artifact state (V_MODEL_POLICY reads the
# transcript's model records; you cannot un-run Opus), so they repeated until the session ended.
#
# Measured over 34 sessions / 191 advisory emissions (2026-07-25..2026-08-05): 106 (55%) were
# BYTE-IDENTICAL replays, ~88 KB / ~22k tokens of pure re-injection. One session printed the
# same pair 33 times. Worst observed: 7 emissions of 1 unique advisory.
#
# FIX: hold a digest of the advisory SET per session and emit only when it CHANGES. Any change to
# any advisory re-emits the whole block, so no new information is ever withheld.
#
# FAILS OPEN, DELIBERATELY. Missing SESSION_ID, an unhashable payload, or an unwritable state dir
# all fall through to emitting — suppressing an advisory because bookkeeping broke is the unsafe
# direction. The BLOCKING path above is untouched: a blocked Stop always carries its warnings, and
# this block never reads or writes BLOCKING_ISSUES.
# Bite: hooks/stop-advisory-hardening-test.sh (T1-T8).
if [ -n "$WARNINGS" ]; then
  # W42-F1: Stop event has no hookSpecificOutput variant in Claude Code's
  # output schema — use top-level systemMessage for advisory text.
  CTX="Completion warnings:$WARNINGS"
  _adv_emit=1
  if [ -n "${SESSION_ID:-}" ] && [ -n "${V_TMP_DIR_RESOLVED:-}" ]; then
    _adv_hash=$(printf '%s' "$CTX" | shasum -a 256 2>/dev/null | awk '{print $1}')
    # STRICT HEX GUARD — a partial/garbled digest must not be treated as a match.
    case "$_adv_hash" in ''|*[!0-9a-fA-F]*) _adv_hash="" ;; esac
    if [ -n "$_adv_hash" ]; then
      _adv_state="$V_TMP_DIR_RESOLVED/advisory-digest-${SESSION_ID}.txt"
      if [ "$(cat "$_adv_state" 2>/dev/null || true)" = "$_adv_hash" ]; then
        _adv_emit=0
      else
        mkdir -p "$V_TMP_DIR_RESOLVED" 2>/dev/null || true
        printf '%s' "$_adv_hash" > "$_adv_state" 2>/dev/null || true
      fi
    fi
  fi
  if [ "$_adv_emit" -eq 1 ]; then
    jq -n --arg msg "$CTX" '{"systemMessage":$msg}'
  fi
fi
# === W-ADVISORY-IDEM END ===================================================================


# === LAYER-3: W59-F2 hostile-dispatch gate ===
# Closes HOSTILE_REVIEW_INLINE_BYPASS.
# Fires when AGENT_REVIEW admits BOTH:
#   (a) Hostile adversarial focus: yes
#   (b) Dispatch mode: orchestrator_inline (or documented synonym)
# Evidence: an observed AGENT_REVIEW artifact has both signals on lines 10-11.
#
# 2026-05-28 review fix (shell/WG-5): use the already-resolved absolute $REVIEW_FILE
# (set at line ~655 via find_session_artifact, which iterates the absolute
# ARTIFACT_SEARCH_DIRS) instead of a bare relative "AGENT_REVIEW_<sid>.md". The
# relative path resolved against the Stop hook's process cwd, so launching Claude
# from a repo SUBDIRECTORY (monorepo package, backend/, etc.) made `[ -f ]` miss and
# the hostile-inline gate silently failed OPEN. We only reach this block when
# BLOCKING_ISSUES is empty (all three artifacts present + valid), so $REVIEW_FILE is
# guaranteed non-empty here.
if [ -n "${SESSION_ID:-}" ]; then
  _W59_AR_FILE="${REVIEW_FILE:-}"
  # P1A-LOOKAHEAD-W59: signature detection single-sourced into _w59_f2_signature() (defined
  # above the aggregation block) so this gate and the aggregation-time lookahead cannot drift.
  if _w59_f2_signature "$_W59_AR_FILE"; then
    # ── W59-F2-DEGRADE (forensic 2026-07-04, deadlock→escape): when the adversarial
    # CLI is provably unreachable (codex quota walls) the old gate had NO satisfiable remediation
    # — it re-blocked the same fingerprint 3× and the rearm ESCAPE completed the session with the
    # violation masked and NOTHING queued to re-review. If DISPATCH_PROVENANCE proves ≥2
    # INDEPENDENT subagent reviewers actually ran (status=ok row whose recorded sha256 MATCHES
    # the on-disk artifact hash — printf-forged rows fail this), independent coverage existed:
    # DEGRADE to a durable REVIEW_DEBT marker (hostile re-review owed) + loud warn + allow.
    # No witnessed reviewers → block exactly as before; on rearm-escape, write the debt marker
    # anyway so the violation queues work instead of vanishing.
    # Bite: w59-f2-degrade-debt-test.sh (red vs .pre-reasondebt0704-bak). The hash-verified
    # reviewer count is single-sourced in validation.sh::_w59_witnessed_independent_reviews so this
    # gate and its bite test cannot drift (the _w59_f2_signature convention).
    _w59_witnessed=0
    if type _w59_witnessed_independent_reviews >/dev/null 2>&1; then
      _w59_witnessed="$(_w59_witnessed_independent_reviews "$SESSION_ID" "${ARTIFACT_SEARCH_DIRS[@]}" 2>/dev/null || echo 0)"
    fi
    case "$_w59_witnessed" in ''|*[!0-9]*) _w59_witnessed=0 ;; esac
    _w59_debt(){ # write the durable debt marker (idempotent)
      local _dbt="$MAIN_ROOT/.v/artifacts/REVIEW_DEBT_${SESSION_ID}.md"
      [ -f "$_dbt" ] && return 0
      mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null || return 0
      {
        echo "# REVIEW_DEBT — hostile adversarial re-review OWED for ${SESSION_ID}"
        echo
        echo "when: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        echo "witnessed_independent_reviewers: ${_w59_witnessed}"
        echo "reason: AGENT_REVIEW declares hostile focus but the adversarial slot ran orchestrator-inline"
        echo "        (typically: codex CLI quota-walled). Re-run codex-adversarial-reviewer against this"
        echo "        session's diff when the CLI is available, then delete this marker."
        echo "resolve: dispatch codex-adversarial-reviewer on the session branch/diff; on findings, fix +"
        echo "         re-verify; then rm this file. Surfaced at every SessionStart until resolved."
      } > "$_dbt" 2>/dev/null || true
    }
    if [ "$_w59_witnessed" -ge 2 ]; then
      _w59_debt
      echo "WARN (W59-F2 degrade): hostile-focus review slot was inline, but $_w59_witnessed hash-verified independent subagent reviews ran (DISPATCH_PROVENANCE). Completion allowed; durable REVIEW_DEBT_${SESSION_ID}.md queues the hostile re-review — do NOT treat this as a waiver." >&2
    else
      _W59_F2_MSG="COMPLETION BLOCKED (W59-F2): AGENT_REVIEW_${SESSION_ID}.md declares 'Hostile adversarial focus: yes' AND admits orchestrator-inline dispatch, and DISPATCH_PROVENANCE shows <2 hash-verified independent subagent reviews. Hostile-focus sessions REQUIRE a subagent-dispatched review (codex-adversarial-reviewer or superpowers fallback). Resolve by ONE of: (a) dispatch the hostile reviewer agent properly and replace the AGENT_REVIEW artifact, (b) dispatch ≥2 independent specialist reviewers (security/logic/fit) as real subprocesses — the gate degrades to a REVIEW_DEBT marker on hash-verified provenance, (c) if the diff genuinely is not sensitive, remove the 'Hostile adversarial focus: yes' line, (d) escalate to operator if dispatch infrastructure is broken. Do NOT bypass."
      if _cra_block_gate "$_W59_F2_MSG"; then
        { jq -n --arg msg "$_W59_F2_MSG" '{"decision":"block","reason":$msg}' 2>/dev/null; echo "$_W59_F2_MSG" >&2; }  # REASON-LOSS fix 2026-07-04
        exit 2
      fi
      _w59_debt   # rearm-escape path: the violation queues durable work instead of vanishing
      echo "WARN (W59-F2 escape): rearm deadlock escape fired — REVIEW_DEBT_${SESSION_ID}.md written; the hostile re-review is OWED, not waived." >&2
      exit 0
    fi
  fi
fi
# === end LAYER-3 W59-F2 ===

# === LAYER-4: SESSION-LOG TELEMETRY gate (forensic 2026-06-20: 43 MISSING) ===
# Closes the SILENT-HOLE class: a /v session that ships commits but ends with NO session-log of any
# kind. The integrity sweep only DETECTS this post-hoc (writes a MISSING marker after V_SL_MISSING_AGE
# = 6h), so 27/43 sessions committed to main and went INVISIBLE to telemetry. This makes it a
# real-time Stop gate. Keyed on the commit-witness the MISSING sweep itself uses; satisfied by ANY
# telemetry (canonical .yaml, a quarantined .yaml.invalid, a loud FAILED/INVALID/INCOMPLETE marker,
# OR a finalize-in-progress pending log) — a loud failure is acceptable, only the SILENT hole blocks.
# Same rearm/escape contract as the other layers (cannot deadlock; the 6h sweep still backstops escape).
if [ -n "${SESSION_ID:-}" ] && [ -n "${MAIN_ROOT:-}" ] \
   && { [ "${IS_V_SESSION:-0}" = "1" ] || [ "${IS_V_INVOCATION_VIA_HISTORY:-0}" = "1" ]; }; then
  # Witness lookup across every plausible .v/tmp root (SREV-001): the session's resolved tmp dir, plus
  # MAIN_ROOT/.v/tmp (v-merge-back.sh R4c COPIES commits-<sid>.txt there before pruning a worktree) and
  # REPO_ROOT/.v/tmp. Keying on V_TMP_DIR_RESOLVED alone would MISS a worktree session whose V_TMP_DIR
  # points at a now-pruned path — an under-block of the most common /v mode.
  _sl_witness=""
  # RC-4b (2026-06-26): also search the DURABLE .v/artifacts copy (v-merge-back writes commits-<sid>.txt there at
  # 997-998). Keying on .v/tmp alone means a concurrent sibling that swept .v/tmp leaves _sl_witness empty -> the
  # block is skipped -> a code-shipping session ends with no log, undetected for up to 6h. Finding the witness can
  # only TIGHTEN this gate (it gates a COMMITTED session that still has no telemetry); it can never false-block a
  # session that DID log (the telemetry check below would find the log first).
  for _sl_wdir in "$V_TMP_DIR_RESOLVED" "$MAIN_ROOT/.v/tmp" "$REPO_ROOT/.v/tmp" "$MAIN_ROOT/.v/artifacts" "$REPO_ROOT/.v/artifacts"; do
    [ -n "$_sl_wdir" ] || continue
    if [ -s "$_sl_wdir/commits-${SESSION_ID}.txt" ]; then _sl_witness="$_sl_wdir/commits-${SESSION_ID}.txt"; break; fi
  done
  if [ -n "$_sl_witness" ]; then   # this /v session shipped commits
    _sl_has_telemetry=0
    # Check BOTH the session's own repo root (finalize-session-log.sh writes the canonical to
    # REPO_ROOT — the WORKTREE for a worktree session) AND MAIN_ROOT (where a merged-back log lands /
    # where the integrity sweep re-validates). Dedup when they are the same path (non-worktree).
    # SREV-002 (review 2026-06-26): this telemetry check searches REPO_ROOT + MAIN_ROOT only — the documented
    # session-log write contract (finalize-session-log.sh -> MAIN_ROOT/SESSION_LOG_<sid>.yaml). RC-4b widened the
    # WITNESS search to include .v/artifacts (the witness migrated there); if the session-LOG location ever
    # migrates to .v/artifacts too, extend THIS loop as well or a logged session would be false-blocked.
    for _slroot in "$REPO_ROOT" "$MAIN_ROOT"; do
      [ -n "$_slroot" ] || continue
      for _slf in \
        "$_slroot/SESSION_LOG_${SESSION_ID}.yaml" \
        "$_slroot/SESSION_LOG_${SESSION_ID}.yaml.invalid" \
        "$_slroot/SESSION_LOG_FAILED_${SESSION_ID}.md" \
        "$_slroot/SESSION_LOG_INVALID_${SESSION_ID}.md" \
        "$_slroot/SESSION_LOG_INCOMPLETE_${SESSION_ID}.md"; do
        [ -e "$_slf" ] && { _sl_has_telemetry=1; break; }
      done
      [ "$_sl_has_telemetry" -eq 1 ] && break
    done
    # finalize-in-progress (pending) also counts — the orchestrator is mid-/v-session-log. Search the
    # same tmp roots; guard each glob with a dir test so a missing dir can't leave a literal pattern
    # under set -u / nullglob-off (SREV-002).
    if [ "$_sl_has_telemetry" -eq 0 ]; then
      for _sl_wdir in "$V_TMP_DIR_RESOLVED" "$MAIN_ROOT/.v/tmp" "$REPO_ROOT/.v/tmp"; do
        [ -d "$_sl_wdir" ] || continue
        for _slp in "$_sl_wdir"/session-log-"${SESSION_ID}"-pending-*; do
          [ -e "$_slp" ] && { _sl_has_telemetry=1; break 2; }
        done
      done
    fi
    # === P1E-FREE-TELEMETRY (2026-07-03) ===
    # Interactive sessions used to close this gap by burning model turns (the /v-session-log fork:
    # autogen→validate→resolver narration). The pack lane's capture_telemetry proved the whole
    # pipeline is pure bash — so run it HERE, in the hook, with zero model involvement.
    #   (a) light-tier diff (shape re-derived by the classifier, never model-asserted): a full log
    #       buys nothing — write the LOUD SESSION_LOG_MISSING marker (the backfill sweep's own
    #       convention) and treat telemetry as satisfied. No autogen.
    #   (b) otherwise: run v-session-log-autogen.sh (resolve→gather→finalize, 0 model tokens, the
    #       same lever as the pack runner's capture_telemetry). Success ⇒ canonical log exists, no
    #       gap. Any failure ⇒ fall through to the existing warn/marker path UNCHANGED.
    # Dial: V_SL_AUTOGEN=0 disables both branches (test seam + emergency off).
    if [ "$_sl_has_telemetry" -eq 0 ] && [ "${V_SL_AUTOGEN:-1}" = "1" ]; then
      _p1e_light=0
      _P1E_LT="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
      # Capture to a variable FIRST, then match — do not pipe the classifier straight into `grep -q`
      # under this script's `set -euo pipefail` (line 12): `grep -q` exits the moment it matches, the
      # classifier then dies of SIGPIPE, pipefail adopts that as the pipeline status, and the `if`
      # reads FALSE on exactly the runs where the pattern WAS found — live-reproduced here at a 66%
      # (33/50) failure rate with the real 6-line classifier output shape (bonus fix, 2026-08-19,
      # found while fixing the same bug class at this file's own exposed:*) block and at
      # enforce-pre-commit-gates.sh's W-LIGHT2 check, whose own comment documents this exact class).
      _p1e_lt_out=""
      [ -f "$_P1E_LT" ] && _p1e_lt_out="$(CLAUDE_SESSION_ID="$SESSION_ID" REPO_ROOT="$REPO_ROOT" bash "$_P1E_LT" 2>/dev/null || true)"
      if printf '%s\n' "$_p1e_lt_out" | grep -q '^LIGHT=1'; then
        _p1e_light=1
      fi
      if [ "$_p1e_light" -eq 1 ]; then
        { echo "# SESSION_LOG_MISSING — ${SESSION_ID}"
          echo ""
          echo "Light-tier session (P1E): full session-log intentionally skipped for a ≤10-line gated guard diff; marker written by the Stop hook (zero model tokens). Commits witness: ${_sl_witness}. Backfill via v-session-log-backfill.sh if needed."
        } > "${MAIN_ROOT}/SESSION_LOG_MISSING_${SESSION_ID}.md" 2>/dev/null && _sl_has_telemetry=1
      else
        _P1E_AUTOGEN="${V_SL_AUTOGEN_SCRIPT:-$HOME/.claude/skills/v-session-log/references/v-session-log-autogen.sh}"
        if [ -f "$_P1E_AUTOGEN" ]; then
          # CDX-7 (review): bound the autogen — an UNbounded subprocess here hangs the Stop hook
          # itself (the W38 class: "no max wall-clock guard"). Portable watchdog (macOS has no
          # `timeout`): background child + 1s-tick bounded wait; overrun → kill → fall through to
          # the existing warn/marker path exactly like any other autogen failure.
          ( cd "${MAIN_ROOT}" 2>/dev/null && V_SESSION_LOG_FORCE_CATCHUP=1 bash "$_P1E_AUTOGEN" "$SESSION_ID" >/dev/null 2>&1 ) &
          _p1e_pid=$!
          _p1e_max="${V_SL_AUTOGEN_TIMEOUT_SEC:-60}"; _p1e_t=0; _p1e_rc=124
          while [ "$_p1e_t" -lt "$_p1e_max" ]; do
            kill -0 "$_p1e_pid" 2>/dev/null || { wait "$_p1e_pid" 2>/dev/null; _p1e_rc=$?; break; }
            sleep 1; _p1e_t=$((_p1e_t + 1))
          done
          if [ "$_p1e_rc" -eq 124 ] && kill -0 "$_p1e_pid" 2>/dev/null; then
            kill "$_p1e_pid" 2>/dev/null; wait "$_p1e_pid" 2>/dev/null
            echo "P1E: autogen exceeded ${_p1e_max}s — killed; falling through to the warn/marker path (V_SL_AUTOGEN_TIMEOUT_SEC to adjust)." >&2
          elif [ "$_p1e_rc" -eq 0 ]; then
            _sl_has_telemetry=1
            echo "P1E: session-log auto-generated by the Stop hook via v-session-log-autogen.sh (pure bash, zero model tokens)." >&2
          fi
        fi
      fi
    fi
    # === end P1E-FREE-TELEMETRY ===
    if [ "$_sl_has_telemetry" -eq 0 ]; then
      _sl_msg="COMPLETION BLOCKED (session-log telemetry): this /v session shipped commits (witness ${_sl_witness}) but produced NO session-log of any kind — no SESSION_LOG_${SESSION_ID}.yaml, no .yaml.invalid, and no SESSION_LOG_FAILED/INVALID/INCOMPLETE_${SESSION_ID}.md marker. A code-shipping session that ends with zero telemetry is a SILENT hole (forensic 2026-06-20: 43 such sessions went invisible to telemetry). Resolve: run /v-session-log to finalize the canonical SESSION_LOG_${SESSION_ID}.yaml before stopping. A loud FAILED/INVALID marker is an ACCEPTABLE outcome (schema complexity is not a 'cannot log' outcome) — only a silent hole is blocked. If logging is genuinely impossible (parallel-session contamination), /v-session-log itself records a FAILED marker; run it."
      # EFF-SLGATE (2026-06-28): the session-log apparatus is TEMPORARY hardening scaffolding the operator is
      # retiring -> this gate DEFAULTS TO WARN (kills the block->remediate churn, ~the dominant turn-cost lever)
      # while STILL writing the durable GAUNTLET_SKIPPED marker + a stderr warning, so the telemetry signal
      # survives for the 6h integrity sweep. V_SESSION_LOG_GATE=block restores hard real-time enforcement (opt-in).
      # SCOPE: the session-log telemetry gate ONLY -- AGENT_REVIEW / PRE_FLIGHT / worktree-merge / SURVIVAL gates
      # are untouched, so output quality + data-safety enforcement is unchanged. Bite: hooks/sessionlog-warn-gate-test.sh.
      if [ "${V_SESSION_LOG_GATE:-warn}" = "block" ] && _cra_block_gate "$_sl_msg"; then
        { jq -n --arg msg "$_sl_msg" '{"decision":"block","reason":$msg}' 2>/dev/null; echo "$_sl_msg" >&2; }  # REASON-LOSS fix 2026-07-04: stderr ALWAYS carries the reason (exit-2 surfaces stderr, not stdout)
        exit 2
      fi
      _cra_write_skipped_marker "$_sl_msg"  # RC-2A (2026-06-26): leave a DURABLE GAUNTLET_SKIPPED marker so an escaped commit-shipping-no-log session is git-status-visible (mirrors 781/796), not just stderr; the 6h sweep still backstops
      # EFF-SLGATE: emit the warning on BOTH the warn-default normal path AND a block-mode re-arm escape (rc 1
      # from _cra_block_gate short-circuited the exit-2 above) — neither should be a silent fallthrough (codex
      # SREV-001). Label the ACTUAL dial value, not a hardcoded 'warn' (logic-review F2).
      printf '%s\n' "⚠️ session-log telemetry gap (mode=${V_SESSION_LOG_GATE:-warn}; default=warn): /v session ${SESSION_ID} shipped commits but wrote no session-log — durable marker left for the 6h sweep. Set V_SESSION_LOG_GATE=block to enforce real-time blocking." >&2
      exit 0  # W5G-1 deadlock escape (warning on stderr; the 6h integrity sweep still backstops this)
    fi
  else
    # === P2-NO-SILENT-HOLE (2026-07-03) ===
    # NO commits witness: a raw-/v-paste or inline session that changed code leaves NEITHER a log
    # NOR any marker today — invisible, worse than a hole (synthesis N-item: "Stop gate must emit
    # marker unconditionally"). Write the LOUD SESSION_LOG_MISSING marker (the backfill sweep's
    # convention) when code changed and no telemetry of any kind exists. INFORMATIONAL ONLY —
    # never blocks, never changes the exit path; finalize-session-log.sh removes the marker if a
    # real log lands later. Bite: hooks/p1e-free-telemetry-test.sh (no-witness case).
    if [ "${CODE_CHANGED:-0}" -eq 1 ] && [ -n "${MAIN_ROOT:-}" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_${SESSION_ID}.yaml" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_${SESSION_ID}.yaml.invalid" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_FAILED_${SESSION_ID}.md" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_INVALID_${SESSION_ID}.md" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_INCOMPLETE_${SESSION_ID}.md" ] \
       && [ ! -e "$MAIN_ROOT/SESSION_LOG_MISSING_${SESSION_ID}.md" ]; then
      { echo "# SESSION_LOG_MISSING — ${SESSION_ID}"
        echo ""
        echo "Code-changing /v-shaped session ended with no commits witness and no session-log (raw-/v-paste / inline class — P2-NO-SILENT-HOLE). Marker written by the Stop hook so telemetry sees the session; backfill via v-session-log-backfill.sh."
      } > "$MAIN_ROOT/SESSION_LOG_MISSING_${SESSION_ID}.md" 2>/dev/null || true
    fi
    # === end P2-NO-SILENT-HOLE ===
  fi
fi
# === end LAYER-4 session-log telemetry ===

# W5G-1: clean pass — close out any active re-arm chain for this hook×SID.
if type rearm_clear >/dev/null 2>&1; then
  rearm_clear "check-review-artifact" "${SESSION_ID:-nosid}"
fi
# Gauntlet completed (reached the final clean exit = all gates satisfied) → clear any stale
# GAUNTLET_SKIPPED marker left by a prior deadlock-escape for this session.
[ -n "${REPO_ROOT:-}" ] && [ -n "${SESSION_ID:-}" ] && rm -f "$REPO_ROOT/GAUNTLET_SKIPPED_${SESSION_ID}.md" "$REPO_ROOT/ABANDON_SUSPECT_${SESSION_ID}.md" 2>/dev/null
exit 0

# W59-F5: Stop-hook JSON schema fix applied
