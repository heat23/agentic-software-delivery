#!/usr/bin/env bash
# v-dispatch-subagent.sh — fork-compatible independent subagent dispatcher for /v
# Version: 1.0.0
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# /v runs `context: fork`, i.e. it IS a subagent. Claude Code forbids a subagent
# from dispatching another subagent via the Agent/Task tool ("subagents cannot
# spawn subagents" — documented platform limit, re-verified 2026-05-24 on
# Claude Code 2.1.150). So every `Agent(subagent_type: ...)` call inside /v
# silently failed and dropped to inline self-review on the orchestrator's own
# model, defeating the entire independent-verification architecture (several
# production sessions all ran `dispatch_path: orchestrator_inline`).
#
# Bash, however, works fine from a fork, and a `claude -p` subprocess is an
# INDEPENDENT process with its OWN context and model — bypassing the
# no-nested-subagent limit. This helper wraps that subprocess invocation so each
# reviewer/runner gets a real, independent second opinion again.
#
# Empirically validated 2026-05-24 (Claude Code 2.1.150):
#   - `claude -p --agent <name>` loads ~/.claude/agents/<name>.md frontmatter
#     (tools whitelist + model pin) and runs headless. A haiku-pinned agent ran
#     on claude-haiku-4-5 regardless of the parent model → true independence.
#   - The subprocess inherits cwd, so it sees the repo's uncommitted git diff.
#   - Scoped `--allowedTools` is honored; blanket `--permission-mode
#     bypassPermissions` is rejected by the host auto-mode classifier, so this
#     helper NEVER uses bypass — it grants exactly the agent's declared tools.
#   - `--session-id <live-parent-sid>` is REFUSED ("session id already in use"),
#     so we never pass it. Artifact naming flows through the parent SID that
#     v-emit-prompt.sh already substituted into the prompt text; the runner reads
#     its in-prompt $SESSION_ID (NOT $CLAUDE_CODE_SESSION_ID). `--no-session-
#     persistence` keeps the subprocess from writing a throwaway session JSONL.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   v-dispatch-subagent.sh --agent NAME --prompt-file FILE --artifact PATH \
#       --mode capture|self-write [--model M] [--extra-tools "T1 T2"]
#
#   --agent NAME    agent under ~/.claude/agents/<name>.md. Omit for a plain
#                   model dispatch (then --model is required; used for v-handoff
#                   which has no dedicated agent).
#   --model M       model alias for a no-agent dispatch (e.g. haiku). Ignored
#                   when --agent is set (the agent frontmatter pins the model).
#                   `parent` (alias `inherit`) resolves to the operator's own
#                   session model — V_PARENT_MODEL > CLAUDE_CODE_SUBAGENT_MODEL >
#                   .model in project/user settings > `sonnet`. Still gated by
#                   enforce_model_policy: a premium resolution needs the caller
#                   to set V_MODEL_POLICY_OVERRIDE=1 (W-PARENT-MODEL, 2026-08-11).
#   --prompt-file F fully-substituted dispatch prompt (SID + paths already
#                   filled in by v-emit-prompt.sh or the caller's substitution).
#   --artifact PATH absolute path of the artifact this dispatch must produce.
#   --mode MODE     capture    → agent has NO Write; it emits the full artifact
#                                markdown as its final message; this helper
#                                sanitizes + writes <artifact> (read-only runners
#                                v-pre-flight-runner / v-verify-done-runner /
#                                v-handoff — preserves the W35 no-source-edit
#                                enforcement: Write stays out of the allowlist).
#                   self-write → agent writes <artifact> itself via its scoped
#                                Write tool; this helper verifies it landed
#                                (writer agents v-qa-reviewer /
#                                v-ux-critique-reviewer / v-workflow-verifier).
#   --extra-tools T tool names to ADD to the derived allowlist, space-separated
#                   (e.g. "mcp__playwright__*" for v-workflow-verifier).
#
# ── EXIT CODES ───────────────────────────────────────────────────────────────
#   0  dispatch ran AND artifact present + non-empty
#   2  bad usage
#   3  agent file missing (when --agent given)  -- OR (F7, 2026-08-29) the --prompt-file is
#      v-emit-prompt.sh's DO-NOT-DISPATCH notice (its exit-10 stack-gate output). Both mean
#      "refused to dispatch"; the stderr text distinguishes them. The F7 case is a SUCCESS
#      condition upstream (the report is already written) -- do not retry the dispatch.
#   4  required CLI not found in PATH (`claude` or `jq`)
#   5  subprocess errored (non-zero / is_error / empty result)
#   6  subprocess ran but artifact missing/empty afterwards
#   7  17c (2026-07-03): --artifact names a DIFFERENT session than this dispatch's own
#      CLAUDE_CODE_SESSION_ID/CLAUDE_SESSION_ID, and the caller did not acknowledge the
#      cross-session write via V_DISPATCH_ACTING_AS=<this-session-sid>. A genuine
#      cross-session remediation (one session finishing another's gauntlet) must set
#      that env var explicitly; a SILENT mismatch is refused before the subprocess runs.
#   8  E3-SANITY (2026-07-05, opt-in via V_DISPATCH_SANITY_STRICT=1 only): the artifact
#      claims "Changed: 0" but a cheap `git status --porcelain` shows a wildly implausible
#      number of dirty entries. Default behavior (STRICT unset) is WARN-only (rc unaffected,
#      a DISPATCH_SANITY_WARN= line is emitted) — see the "§E3-SANITY" block near step 7b.
#   9  F8-2 (SID-leakage hardening, 2026-07-05): a SIBLING artifact of the same TYPE, freshly
#      touched during THIS dispatch's own window, carries a DIFFERENT session id in its
#      filename than the one this dispatch is authorized to write for — the subprocess wrote
#      (or attempted to write) under the wrong SID (e.g. its own forked sub-session's id
#      instead of the parent's). The intended artifact is preserved at a `.rejected-sidleak-*`
#      sidecar under $V_TMP for inspection; this is NEVER silently accepted as a pass.
#
# On ANY non-zero exit the CALLER owns the documented fallback (manual degraded
# artifact for UI gates; superpowers → ORCHESTRATOR_INLINE for code review).
# This helper NEVER falls through to a broad / full-tool dispatch itself — that
# uncontrolled fall-through was the W38 Monitor() runaway vector (one
# session, 2+ hours of haiku tokens).
#
# Stdout: a DISPATCH_* key=value provenance block (parsed by the orchestrator
#         for AGENT_REVIEW provenance), then `----RESULT----` and the agent's
#         raw final message.
# Stderr: human-readable diagnostics.

set -uo pipefail   # NOT -e: we handle non-zero explicitly and emit provenance.

# P1D-DETACH: keep the ORIGINAL argv so --detach can re-exec self (minus the flag).
_ORIG_ARGS=("$@")

# ── 1. Parse args ─────────────────────────────────────────────────────────────
AGENT="" MODEL="" PROMPT_FILE="" ARTIFACT="" MODE="" EXTRA_TOOLS="" DETACH=0 PRINT_MODEL=0
# Note `${2:-}` (not bare `$2`): a valued flag passed as the LAST arg must yield a
# clean `exit 2`, not a `set -u` "unbound variable" crash (codex review #2).
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)       AGENT="${2:-}"; shift 2 || exit 2 ;;
    --model)       MODEL="${2:-}"; shift 2 || exit 2 ;;
    --prompt-file) PROMPT_FILE="${2:-}"; shift 2 || exit 2 ;;
    --artifact)    ARTIFACT="${2:-}"; shift 2 || exit 2 ;;
    --mode)        MODE="${2:-}"; shift 2 || exit 2 ;;
    --extra-tools) EXTRA_TOOLS="${2:-}"; shift 2 || exit 2 ;;
    --detach)      DETACH=1; shift ;;
    # W-PARENT-MODEL (2026-08-11): resolve-and-print only, no dispatch. Exists so the few
    # sites that must call `claude -p` DIRECTLY (generic-prompt workers that are not
    # registered agents — e.g. v-audit-consolidate's parse/pack-writer) can obtain the
    # operator's model from THIS resolver instead of keeping a second copy of the
    # precedence rules that would silently drift. The CLI rejects a literal
    # `--model parent` ("not a model this version of Claude Code recognizes", rc 1), so a
    # raw site has to substitute a concrete alias before it invokes the CLI.
    --print-resolved-model) PRINT_MODEL=1; shift ;;
    *) echo "ERROR: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# --print-resolved-model short-circuits BEFORE the dispatch-arg validation below: it performs no
# dispatch, so --prompt-file/--artifact/--mode are meaningless for it. Placed after the resolver
# definition further down would be too late (the validation would already have exited 2), so the
# resolution itself is deferred to the PRINT_MODEL block just past resolve_parent_model().
if [ "$PRINT_MODEL" -eq 0 ]; then
  [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ] || { echo "ERROR: --prompt-file missing/unreadable: '$PROMPT_FILE'" >&2; exit 2; }
  # F7-GUARD (2026-08-29, adversarial review PANEL-CORRECTNESS-001): refuse to dispatch a prompt
  # file that is actually v-emit-prompt.sh's DO-NOT-DISPATCH notice (its exit-10 stack-gate output).
  #
  # WHY THIS IS MECHANICAL AND NOT A DOC FIX. v-verbatim-dispatch.md's D1 comment says "if the
  # helper non-zero'd, abort", but the CHECK it actually performs is `[ -s "$DISPATCH_FILE" ]` —
  # non-emptiness, not the exit status. That worked only by accident: every other non-zero exit
  # (2-9) writes solely to stderr and leaves stdout empty. Exit 10 deliberately writes an
  # explanatory notice to stdout, so the `-s` guard PASSES and D2 would dispatch the runner with
  # the notice as its task input — wasting the exact dispatch F7 exists to eliminate, and under
  # `--mode capture` letting a confused subagent overwrite the correct mechanically-written
  # PRE_FLIGHT_REPORT with a hallucinated one. The docs are being fixed too, but a gate that
  # depends on the orchestrator reading a doc is not a gate. This refusal is the actual control.
  #
  # Exit 3 (not 2): this is a "nothing to do, and that is the correct outcome" signal, distinct
  # from a usage error. The report is already on disk; the caller must NOT retry the dispatch.
  if head -5 "$PROMPT_FILE" 2>/dev/null | grep -q 'F7 PRE-DISPATCH STACK GATE — DO NOT DISPATCH'; then
    echo "ERROR: --prompt-file is v-emit-prompt.sh's F7 DO-NOT-DISPATCH notice, not a runner prompt." >&2
    echo "       This tree has no gate-bearing stack; PRE_FLIGHT_REPORT_<sid>.md was ALREADY written" >&2
    echo "       mechanically from a real v-run-gates.sh run. Do NOT dispatch, and do NOT rewrite the" >&2
    echo "       report. Treat pre-flight as complete. (v-emit-prompt.sh exited 10; see its stderr.)" >&2
    exit 3
  fi
  [ -n "$ARTIFACT" ] || { echo "ERROR: --artifact required" >&2; exit 2; }
  case "$MODE" in capture|self-write) ;; *) echo "ERROR: --mode must be capture|self-write (got '$MODE')" >&2; exit 2 ;; esac
  [ -n "$AGENT" ] || [ -n "$MODEL" ] || { echo "ERROR: one of --agent or --model required" >&2; exit 2; }
else
  # Checked here, not at the print block below: enforce_model_policy() runs first and would
  # reject an empty MODEL with a misleading "model '' violates the sonnet-max policy".
  [ -n "$MODEL" ] || { echo "ERROR: --print-resolved-model requires --model (use '--model parent')" >&2; exit 2; }
fi

# === W-PARENT-MODEL (2026-08-11) — `--model parent` resolves the operator's own session model ===
# Operator instruction 2026-08-11 (all audit phases use the operator-selected parent model). The
# CLI rejects the literal string `--model inherit`, so a dispatch site can never forward the
# frontmatter sentinel; it has to name a REAL alias. This resolver turns `parent` (alias:
# `inherit`) into that alias, read from the same sources the interactive session reads.
#
# This resolver deliberately does NOT touch the sonnet-max gate below. The resolved value is
# subject to enforce_model_policy exactly like any other --model string: if the operator's session
# model is outside the allowlist, the CALLER must set V_MODEL_POLICY_OVERRIDE=1 in the environment
# on an explicit operator instruction. Self-granting the bypass here would have made every
# `--model parent` dispatch site a silent hole in the gate.
resolve_parent_model() {  # -> echoes a concrete alias; never empty
  local _p=""
  # 1. Explicit override wins (lets a caller/test pin the resolution deterministically).
  if [ -n "${V_PARENT_MODEL:-}" ]; then echo "$V_PARENT_MODEL"; return 0; fi
  # 2. The env var Claude Code itself uses to route subagents, when the operator has set it.
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then echo "$CLAUDE_CODE_SUBAGENT_MODEL"; return 0; fi
  # 3. The settings files, most-specific first. `/model` writes `.model` into the user settings
  #    when the operator saves the choice as their default.
  if command -v jq >/dev/null 2>&1; then
    local _f
    for _f in "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.local.json" \
              "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json" \
              "$HOME/.claude/settings.local.json" \
              "$HOME/.claude/settings.json" \
              "$HOME/.claude.json"; do
      [ -f "$_f" ] || continue
      _p=$(jq -r '.model // empty' "$_f" 2>/dev/null)
      if [ -n "$_p" ] && [ "$_p" != "null" ]; then echo "$_p"; return 0; fi
    done
  fi
  # 4. Fail SAFE, not premium: an unresolvable parent falls back to the sonnet-max default rather
  #    than guessing a premium tier. A silent expensive fan-out is worse than a silent downgrade.
  echo "sonnet"
}
case "$MODEL" in
  parent|inherit|PARENT|INHERIT)
    _RESOLVED_PARENT="$(resolve_parent_model)"
    echo "NOTICE: --model '$MODEL' resolved to '$_RESOLVED_PARENT' (operator session model; W-PARENT-MODEL). Still subject to the sonnet-max gate below." >&2
    MODEL="$_RESOLVED_PARENT"
    ;;
esac
# === end W-PARENT-MODEL ===

# === ND-MODEL-POLICY (ND-0716) — sonnet-max allowlist at the dispatch chokepoint ===
# The 2026-07-07 sonnet-max sweep (CLAUDE.md Model Policy: /v dispatches = Sonnet 5 + Haiku
# ONLY; opus/fable only by explicit per-session operator choice; never [1m]) fixed frontmatter
# but this helper still forwarded ANY --model string verbatim to `claude -p` — the structural
# gap that made stale in-body `--model opus` prose executable (opus-leak class, round 2)
# and let typos ("oups") through silently. Unknown aliases are rejected as typos (fail-closed):
# a mistyped model reaching the CLI either errors opaquely or resolves to something unintended.
# V_MODEL_POLICY_OVERRIDE=1 is the operator-explicit lane; it announces itself on stderr so the
# session log always records that the policy was consciously bypassed.
enforce_model_policy() {  # <model-value> <origin-label> -> 0 allowed | 2 policy violation
  local _m="${1:-}" _org="${2:-model}"
  [ -z "$_m" ] && return 0
  if [ "${V_MODEL_POLICY_OVERRIDE:-0}" = "1" ]; then
    echo "NOTICE: V_MODEL_POLICY_OVERRIDE=1 — model '$_m' ($_org) bypasses the sonnet-max allowlist (operator-explicit lane, CLAUDE.md Model Policy)." >&2
    return 0
  fi
  case "$_m" in
    *\[1m\]*) ;;  # [1m] context variants are banned in every form — fall through to reject
    sonnet|haiku) return 0 ;;
    claude-sonnet*|claude-haiku*|claude-3-5-haiku*) return 0 ;;
  esac
  echo "ERROR: model '$_m' ($_org) violates the sonnet-max policy (CLAUDE.md Model Policy 2026-07-07: /v dispatches are Sonnet 5 + Haiku ONLY — no opus/fable/[1m]; unknown aliases are rejected as typos). Use --model sonnet|haiku, or set V_MODEL_POLICY_OVERRIDE=1 only on an explicit per-session operator instruction." >&2
  return 2
}
# === end ND-MODEL-POLICY ===
if [ -z "$AGENT" ]; then
  enforce_model_policy "$MODEL" "--model flag" || exit 2
fi

# W-PARENT-MODEL (2026-08-11): resolve-only exit, deliberately placed AFTER enforce_model_policy.
# A raw `claude -p` caller takes this value straight to the CLI, bypassing every gate downstream
# of here — so if the print path skipped the allowlist it would become exactly the "silent hole in
# the gate" the resolver comment above warns against, reachable by any site that prefers printing
# over dispatching. Gated here, a raw site inherits the identical contract as a helper dispatch:
# an out-of-allowlist parent model exits 2 unless the caller set V_MODEL_POLICY_OVERRIDE=1.
if [ "$PRINT_MODEL" -eq 1 ]; then
  echo "$MODEL"
  exit 0
fi

command -v claude >/dev/null 2>&1 || { echo "ERROR: 'claude' CLI not found in PATH" >&2; exit 4; }
# jq is required to parse the subprocess JSON. Without it, a SUCCESSFUL run would
# be misread as a failure (empty RESULT → exit 5), silently disabling the whole
# dispatch pipeline. Fail loud with a distinct, actionable message (codex review #4).
command -v jq >/dev/null 2>&1 || { echo "ERROR: 'jq' not found in PATH — required to parse subprocess output. Install jq." >&2; exit 4; }

# === W-REATTACH (2026-09-05, cohort forensic 2026-08-31..09-03) ===============================
# 82 dispatches ended `status=aborted` in 4 days — 549 min of child work thrown away and 56
# re-dispatched from scratch on the same artifact. The abort elapsed clusters at 9–10 min (the
# Bash tool's 600 s ceiling; 76 "Command timed out after 10m" tool results) and 2 min (the tool
# default, since closed by W-perf9c). Interactive `cli` sessions KILL the call at the ceiling
# (sdk-cli sessions merely background it), the helper's TERM trap exits 143, and the `claude`
# child — same process tree — dies with it.
#
# Design (three SME reviews, 2026-09-08): the child is double-forked into its OWN SESSION
# (PPID 1, new pgrp) so neither a process-group kill nor a PPID-tree walk from the tool reaches
# it; the helper polls for the child's exit instead of `wait`ing. All state lives INSIDE the
# W-DISPATCHLOCK dir (one liveness primitive, not three): `lease` (signed), `child.pid` (written
# by the child itself), `prompt`/`json`/`err`/`rc`/`stale`. On a kill with the child alive the
# EXIT trap emits `status=detached`, KEEPS the lock dir and touches nothing else; the next
# invocation of the same dispatch (same agent/mode/SID/artifact) finds the lease, verifies its
# HMAC (per-install 0600 secret — the same-UID ceiling every gate here accepts), and RE-ATTACHES:
# `status=reattached`, then the UNCHANGED post-run path. A lease whose child is alive but which
# belongs to a different dispatch is REFUSED (W-DISPATCHLOCK LIVE-ONLY, extended to the child).
# Anything else (bad HMAC, dead child with no rc = SIGKILL, implausible epoch) restores the
# sidelined artifact and starts fresh — exactly today's behaviour. Plausibility clamps on the
# adopted start epoch and result files (rc/json newer than the lease; duration ≤ elapsed) plus the
# detach PROOF (`detached.sig`, signed only by a helper that observed the child alive) keep a
# hand-crafted lease + rc + json from laundering content through emit_marker without a child
# having run — same-UID friction on top of the documented ceiling, not a cryptographic wall
# (see gauntlet-witness.sh).
# Bite: v-dispatch-subagent-reattach-test.sh.
_WR_REATTACH=0; _WR_DETACHED=0; _WR_START=""; _WR_TIMEOUT=""
_wr_gwlib="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh"
if [ -f "$_wr_gwlib" ]; then . "$_wr_gwlib" 2>/dev/null || true; fi
_wr_sid() { printf '%s' "${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"; }
_wr_canon() {  # <agent> <mode> <sid> <artbase> <start> <timeout> <helper_pid>
  printf 'v-dispatch-lease|%s|%s|%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
_wr_child_pid() { tr -dc '0-9' < "$1/child.pid" 2>/dev/null; }
_wr_child_alive() {  # <lockdir> — PID alive AND its command line names THIS dir's rc file (PID-reuse guard)
  local _d="$1" _p; _p="$(_wr_child_pid "$_d")"
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null || return 1
  # argv carries "$_d/rc" once the wrapper has exec'd; for the few ms before exec it is still perl
  # whose argv carries "$_d/child.pid" — both are this dispatch's own paths (PID-reuse guard).
  # Fixed-string match (no regex escaping to get wrong: a lock-dir path may carry + ( ) | ? { }).
  ps -o command= -p "$_p" 2>/dev/null | grep -qF -e "$_d/rc" -e "$_d/child.pid"
}
_wr_lease_field() { sed -n "s/^$2=//p" "$1/lease" 2>/dev/null | head -1; }
_wr_lease_write() {  # <lockdir> <start> <timeout> -> 0 if signed lease written
  local _d="$1" _st="$2" _to="$3" _h
  command -v _gw_compute_hmac >/dev/null 2>&1 || return 1
  _h="$(_gw_compute_hmac "$(_wr_canon "${AGENT:-model:${MODEL:-?}}" "$MODE" "$(_wr_sid)" "$(basename "$ARTIFACT")" "$_st" "$_to" "$$")" 2>/dev/null || true)"
  [ -n "$_h" ] || return 1
  printf 'V=1\nAGENT=%s\nMODE=%s\nSID=%s\nARTIFACT=%s\nSTART_EPOCH=%s\nTIMEOUT=%s\nHELPER_PID=%s\nHMAC=%s\n' \
    "${AGENT:-model:${MODEL:-?}}" "$MODE" "$(_wr_sid)" "$(basename "$ARTIFACT")" "$_st" "$_to" "$$" "$_h" > "$_d/lease.tmp.$$" 2>/dev/null \
    && mv -f "$_d/lease.tmp.$$" "$_d/lease" 2>/dev/null
}
_wr_lease_state() {  # <lockdir> -> echoes: none | reattach | foreign-live | stale ; sets _WR_START/_WR_TIMEOUT on reattach
  local _d="$1" _a _m _s _b _st _to _hp _h _calc _now _lm _rcm
  [ -f "$_d/lease" ] || { echo none; return 0; }
  _a="$(_wr_lease_field "$_d" AGENT)"; _m="$(_wr_lease_field "$_d" MODE)"; _s="$(_wr_lease_field "$_d" SID)"
  _b="$(_wr_lease_field "$_d" ARTIFACT)"; _st="$(_wr_lease_field "$_d" START_EPOCH)"; _to="$(_wr_lease_field "$_d" TIMEOUT)"
  _hp="$(_wr_lease_field "$_d" HELPER_PID)"; _h="$(_wr_lease_field "$_d" HMAC)"
  case "$_st$_to$_hp" in ''|*[!0-9]*) echo stale; return 0 ;; esac
  command -v _gw_compute_hmac >/dev/null 2>&1 || { echo stale; return 0; }
  _calc="$(_gw_compute_hmac "$(_wr_canon "$_a" "$_m" "$_s" "$_b" "$_st" "$_to" "$_hp")" 2>/dev/null || true)"
  { [ -n "$_calc" ] && [ "$_calc" = "$_h" ]; } || { echo stale; return 0; }
  # Plausibility clamps (HMAC proves self-consistency, not truth): start ≤ now, and not older than
  # the lease file's own mtime minus the budget; rc/json (when present) must post-date the lease.
  _now="$(date -u +%s)"; _lm="$(stat -c %Y "$_d/lease" 2>/dev/null || stat -f %m "$_d/lease" 2>/dev/null || echo 0)"
  [ "$_st" -le "$_now" ] && [ "$_st" -ge $(( _lm - _to - 60 )) ] || { echo stale; return 0; }
  if [ -f "$_d/rc" ]; then
    _rcm="$(stat -c %Y "$_d/rc" 2>/dev/null || stat -f %m "$_d/rc" 2>/dev/null || echo 0)"
    [ "$_rcm" -ge "$_lm" ] && [ -s "$_d/json" ] || { echo stale; return 0; }
  fi
  if _wr_child_alive "$_d" || { [ -f "$_d/rc" ] && _wr_proof_ok "$_d"; }; then
    if [ "$_a" = "${AGENT:-model:${MODEL:-?}}" ] && [ "$_m" = "$MODE" ] && [ "$_s" = "$(_wr_sid)" ] && [ "$_b" = "$(basename "$ARTIFACT")" ]; then
      _WR_START="$_st"; _WR_TIMEOUT="$_to"; echo reattach; return 0
    fi
    _wr_child_alive "$_d" && { echo foreign-live; return 0; }
  fi
  echo stale
}
# Detach PROOF (security panel 2026-09-08): a finished-while-detached child (rc present, pid gone)
# may be harvested ONLY if a real helper's detached branch — the one place with un-forgeable
# evidence of liveness — signed `detached.sig` over the lease's own HMAC. Without it a pre-staged
# lease + rc + json (same-UID actor) would launder content through emit_marker with no child
# having run. A LIVE child needs no proof: liveness is checked directly.
_wr_proof_write() { local _h; _h="$(_gw_compute_hmac "v-dispatch-detached|$(_wr_lease_field "$1" HMAC)" 2>/dev/null || true)"; [ -n "$_h" ] && printf '%s\n' "$_h" > "$1/detached.sig" 2>/dev/null; }
_wr_proof_ok()    { local _h _c; _h="$(tr -d ' \n\r' < "$1/detached.sig" 2>/dev/null)"; _c="$(_gw_compute_hmac "v-dispatch-detached|$(_wr_lease_field "$1" HMAC)" 2>/dev/null || true)"; [ -n "$_h" ] && [ -n "$_c" ] && [ "$_h" = "$_c" ]; }
_wr_reclaim() {  # <lockdir> — a dead/foreign-free lease: put the world back as helper #1 found it, then clear
  local _d="$1"
  if [ -f "$_d/stale" ] && [ ! -s "$ARTIFACT" ]; then mv -f "$_d/stale" "$ARTIFACT" 2>/dev/null || true; fi
  rm -f "$_d/lease" "$_d/detached.sig" "$_d/child.pid" "$_d/rc" "$_d/json" "$_d/err" "$_d/prompt" "$_d/stale" 2>/dev/null || true
}
# === end W-REATTACH helpers ==================================================================
# === P1D-DETACH (2026-07-03) ===
# Contention-surviving dispatch. Forensic: a long QA `claude -p` overran the
# 600s foreground Bash-tool cap, was killed, then DOUBLE-BILLED on retry; under fleet load the
# orchestrator then degraded to inline self-graded QA (the false deploy-safety-claim path).
# --detach re-execs this same helper (same args, minus --detach) as a DISOWNED background child
# and returns immediately, so the Bash tool call itself stays a fast FOREGROUND call — W-perf9
# (which keys on run_in_background:true tool calls) is not implicated, and the tool timeout can
# never kill the child. Liveness contract replacing the foreground wait:
#   <artifact>.dispatch-status  — 'RUNNING pid=<pid> ...' then 'DONE rc=<rc> ...' appended.
#   The caller CONTINUES other gauntlet work and re-checks the status file between steps (single
#   reads — never a sleep/poll loop, W41); the Stop artifact gate blocks completion until the
#   artifact lands, so a detached dispatch cannot silently strand the gauntlet.
# The W-perf9b V_DISPATCH_TIMEOUT_SEC ceiling still bounds the re-exec'd child (a hung child
# self-terminates rc=124 and the status file records it) — detach never becomes an unbounded run.
if [ "$DETACH" = "1" ]; then
  _DETACH_STATUS="${ARTIFACT}.dispatch-status"
  _DETACH_RUNLOG="${ARTIFACT}.dispatch-runlog"
  # CDX-8 (review): refuse a SECOND --detach while a prior child for the same artifact is still
  # alive — the truncating RUNNING write would destroy the first child's status history and two
  # children would race to self-write the same artifact (last Write wins, non-deterministic).
  if [ -f "$_DETACH_STATUS" ] && ! grep -q '^DONE ' "$_DETACH_STATUS" 2>/dev/null; then
    _prev_pid=$(sed -n 's/^PID pid=\([0-9][0-9]*\)$/\1/p' "$_DETACH_STATUS" 2>/dev/null | head -1)
    if [ -n "$_prev_pid" ] && kill -0 "$_prev_pid" 2>/dev/null; then
      echo "DISPATCH_DETACHED=already-running"
      echo "DISPATCH_STATUS_FILE=$_DETACH_STATUS"
      echo "DISPATCH_PID=$_prev_pid"
      echo "NOTE: a detached dispatch for this artifact is STILL RUNNING (pid $_prev_pid) — not re-spawning. Re-check the status file between other steps; re-issue only after a DONE line appears." >&2
      exit 0
    fi
  fi
  # W-REATTACH (correctness panel 2026-09-08): the wrapper above is only the OUTER shell — when it
  # dies (kill -9, session teardown) its DONE line never lands, yet the real work lives on in the
  # lock dir's own-session child. A re-issued --detach must not re-run that work: a LIVE child →
  # already-running (report its pid); a FINISHED, proof-bearing child → fall through and spawn, the
  # re-exec'd helper re-attaches, harvests, and this wrapper finally writes the DONE line.
  _wr_dl="${ARTIFACT}.dispatch-lock"
  if [ -d "$_wr_dl" ] && [ ! -f "$_wr_dl/rc" ] && _wr_child_alive "$_wr_dl" 2>/dev/null; then
    echo "DISPATCH_DETACHED=already-running"
    echo "DISPATCH_STATUS_FILE=$_DETACH_STATUS"
    echo "DISPATCH_PID=$(_wr_child_pid "$_wr_dl")"
    echo "NOTE: the previous detached wrapper is gone, but its dispatched subprocess is STILL RUNNING (pid $(_wr_child_pid "$_wr_dl"), lock dir $_wr_dl) — not re-spawning. Re-issue after it exits; the next helper re-attaches and harvests its result." >&2
    exit 0
  fi
  _DETACH_ARGS=()
  for _a in "${_ORIG_ARGS[@]}"; do [ "$_a" = "--detach" ] || _DETACH_ARGS+=("$_a"); done
  # Status is created BEFORE the spawn and only ever APPENDED to afterwards — a truncating
  # write after the spawn could destroy a fast-failing child's DONE line (write-order race).
  printf 'RUNNING started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_DETACH_STATUS"
  (
    # W-REATTACH: the re-exec'd helper writes its OWN DONE line from its EXIT trap (env below), so
    # a wrapper that dies (kill -9, session teardown) no longer leaves the status stuck at RUNNING
    # while the work completes — the line here is only the fallback when the helper could not.
    _V_DETACH_STATUS_FILE="$_DETACH_STATUS" "${BASH:-bash}" "${BASH_SOURCE[0]}" "${_DETACH_ARGS[@]}" >> "$_DETACH_RUNLOG" 2>&1
    _rc=$?
    grep -q '^DONE ' "$_DETACH_STATUS" 2>/dev/null || printf 'DONE rc=%s finished=%s\n' "$_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_DETACH_STATUS"
  ) </dev/null >/dev/null 2>&1 &
  _DETACH_PID=$!
  disown "$_DETACH_PID" 2>/dev/null || true
  printf 'PID pid=%s\n' "$_DETACH_PID" >> "$_DETACH_STATUS"
  echo "DISPATCH_DETACHED=1"
  echo "DISPATCH_STATUS_FILE=$_DETACH_STATUS"
  echo "DISPATCH_RUNLOG=$_DETACH_RUNLOG"
  echo "DISPATCH_PID=$_DETACH_PID"
  echo "NOTE: detached child running; do OTHER gauntlet work now and re-check the status file between steps (single reads, no sleep loops). The Stop gate blocks until the artifact lands." >&2
  exit 0
fi
# === end P1D-DETACH ===

# === W-DISPATCHLOCK (2026-08-04): one LIVE dispatch per artifact ===
# Observed live: one session ran TWO independent chains against the same artifact —
# one lasting 8m13s and one 5m06s, both QA iteration 3/3 for one pack.
# There was no flock/lockfile guard of any kind, so they raced: double spend, and the LAST writer
# won regardless of which verdict was better.
#
# Placed AFTER the detach branch on purpose: the --detach parent exits at once, so it must not
# own a lock the detached child still needs. The child re-execs without --detach and lands here.
#
# THREE INVARIANTS, each load-bearing:
#   FAIL OPEN  — this may only ever PREVENT a duplicate, never block a legitimate dispatch. Any
#                failure of the lock mechanism itself ⇒ proceed unlocked (worst case = today).
#   LIVE ONLY  — refuse only on a `kill -0`-proven live holder. A stale dir from a SIGKILLed
#                dispatch is taken over, else one kill would wedge that artifact permanently.
#   NO 2nd TRAP— the helper already installs an EXIT trap below; a trap added here would be
#                silently clobbered by it and leak the lock every run. Release is folded into
#                that existing trap via $_DL_DIR.
# The env guard lets the watchdog subshell (same argv in ps) and any nested re-exec pass through.
_DL_DIR=""
if [ -n "${ARTIFACT:-}" ] && [ -z "${_V_DISPATCH_LOCK_HELD:-}" ]; then
  _dl_try="${ARTIFACT}.dispatch-lock"
  if mkdir "$_dl_try" 2>/dev/null; then
    printf '%s\n' "$$" > "$_dl_try/pid" 2>/dev/null || true
    _DL_DIR="$_dl_try"; export _V_DISPATCH_LOCK_HELD="$ARTIFACT"
  else
    _dl_holder=$(tr -d ' \n\r' < "$_dl_try/pid" 2>/dev/null || true)
    _dl_refuse=""
    if [ -n "$_dl_holder" ] && kill -0 "$_dl_holder" 2>/dev/null; then
      _dl_refuse="a LIVE dispatch (pid=$_dl_holder) already owns"
    else
      # W-REATTACH: helper gone — but its CHILD may still be running in its own session. Same
      # dispatch → re-attach below; a different dispatch's live child → refuse (LIVE-ONLY rule
      # extended to the child); anything else → reclaim (restores the sidelined artifact first).
      case "$(_wr_lease_state "$_dl_try")" in
        reattach) _WR_REATTACH=1; _WR_START="$(_wr_lease_field "$_dl_try" START_EPOCH)"; _WR_TIMEOUT="$(_wr_lease_field "$_dl_try" TIMEOUT)" ;;   # (re-read: _wr_lease_state ran in a $(...) subshell)
        foreign-live) _dl_refuse="a LIVE child (pid=$(_wr_child_pid "$_dl_try")) of a DIFFERENT dispatch (agent=$(_wr_lease_field "$_dl_try" AGENT) sid=$(_wr_lease_field "$_dl_try" SID)) — its helper was killed but the work is still running — still owns" ;;
        *) _wr_reclaim "$_dl_try" ;;
      esac
    fi
    if [ -n "$_dl_refuse" ]; then
      echo "W-DISPATCHLOCK REFUSED: ${_dl_refuse} $(basename "$ARTIFACT"). Two concurrent dispatches to one artifact race and the last writer wins — observed in a production session, where two QA iteration-3 chains ran 8m13s and 5m06s against the same report. Wait for the running dispatch (check ${ARTIFACT}.dispatch-status) or target a different artifact. Override only if you know the holder is wedged: rm -rf '$_dl_try'." >&2
      exit 10
    fi
    # Stale (holder gone, or pid unreadable) → TAKE OVER the dir in place. W-REATTACH (2026-09-05):
    # the dir may hold a signed lease + the sidelined pre-dispatch artifact + a child that is
    # STILL RUNNING after the tool-cap killed the previous helper, so it is never `rm -rf`'d here;
    # the lease is evaluated (re-attach / refuse / reclaim) once AGENT/MODE/SID are resolved below.
    if [ -d "$_dl_try" ] || mkdir "$_dl_try" 2>/dev/null; then
      printf '%s\n' "$$" > "$_dl_try/pid" 2>/dev/null || true
      _DL_DIR="$_dl_try"; export _V_DISPATCH_LOCK_HELD="$ARTIFACT"
    fi
  fi
fi
# === end W-DISPATCHLOCK ===

AGENT_FILE=""
AGENT_PINNED_MODEL=""
if [ -n "$AGENT" ]; then
  AGENT_FILE="$HOME/.claude/agents/${AGENT}.md"
  if [ ! -f "$AGENT_FILE" ]; then
    echo "ERROR: agent file not found: $AGENT_FILE" >&2
    echo "       (subprocess dispatch reads the registry fresh each run, so NO Claude Code restart is needed — just create/restore the file.)" >&2
    exit 3
  fi
  # The agent's frontmatter `model:` pin is authoritative for an --agent dispatch
  # (`claude --agent` uses it; the helper's --model is NOT passed alongside --agent).
  # Surface it so the caller/session-log records the ACTUAL model, and warn loudly if
  # the caller passed a --model that this pin overrides — otherwise a "(model: haiku)"
  # request is silently ignored and then mis-logged (observed 2026-05-25: reviewers
  # requested at haiku actually ran opus per their frontmatter pin).
  AGENT_PINNED_MODEL="$(grep -m1 -iE '^model:' "$AGENT_FILE" | sed -E 's/^[Mm]odel:[[:space:]]*//; s/[[:space:]]+$//')"
  if [ -n "$MODEL" ] && [ -n "$AGENT_PINNED_MODEL" ] && [ "$MODEL" != "$AGENT_PINNED_MODEL" ]; then
    echo "NOTICE: --model '$MODEL' is IGNORED for agent '$AGENT' — its frontmatter pins model: '$AGENT_PINNED_MODEL', which wins. Report/log the pinned model, not the requested one." >&2
  fi
  # ND-0716: the agent's frontmatter pin is what actually dispatches — validate it against the
  # same sonnet-max allowlist so a future opus/fable-pinned agent file can't slip past the gate.
  enforce_model_policy "$AGENT_PINNED_MODEL" "agent '$AGENT' frontmatter pin" || exit 2
fi

# ── 2. Resolve repo root + scratch dir ────────────────────────────────────────
PROJ="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

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

V_TMP="${V_TMP_DIR:-$PROJ/.v/tmp}"
mkdir -p "$V_TMP" 2>/dev/null || V_TMP="${TMPDIR:-/tmp}"

# ── 2b. Durable dispatch-provenance marker ────────────────────────────────────
# The session-log generator otherwise GUESSES how each reviewer/runner was
# dispatched (it mislabels codex as `tool: Agent`, and can't tell subprocess from
# inline) and ESTIMATES model/cost. We record the GROUND TRUTH — one append-only
# line per dispatch — so v-session-log reports the real submodel/cost/duration/
# mode instead of an estimate, and so a real session can PROVE the reviewers ran
# as independent subprocesses (not inline).
ART_DIR="$(cd "$(dirname "$ARTIFACT")" 2>/dev/null && pwd || dirname "$ARTIFACT")"
ART_BASE="$(basename "$ARTIFACT")"
# Resolve the provenance SID robustly so the log is SID-scoped — NOT a shared
# `_unknown` file that co-mingles dispatches across sessions (observed 2026-05-25:
# every dispatch landed in DISPATCH_PROVENANCE_unknown.log, blending two sessions'
# reviewers, because the only source was a FULL-UUID regex on the artifact name —
# which fails for artifacts carrying just the short 8-char SID, or none at all).
# Priority: (1) the env session id (authoritative, full UUID); (2) a full UUID in
# the artifact basename; (3) an 8-hex short SID in the artifact basename. Only a
# truly SID-less context falls to `unknown`.
PROV_SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [ -z "$PROV_SID" ]; then
  PROV_SID="$(printf '%s' "$ART_BASE" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
fi
if [ -z "$PROV_SID" ]; then
  PROV_SID="$(printf '%s' "$ART_BASE" | grep -oiE '[0-9a-f]{8}' | head -1)"
fi
# A-1a (handoff-3, 2026-07-02): write the provenance log to the MAIN checkout's
# `.v/artifacts/`, never `dirname "$ARTIFACT"` (which is worktree-local whenever the
# caller passes a worktree-scoped artifact path, or cwd-relative in general). Prior
# behavior caused a "worktree split-brain": a session dispatching from inside a
# worktree wrote DISPATCH_PROVENANCE_<sid>.log INTO the worktree, where a later
# forensic grep of the MAIN repo's tree found zero rows for that session's
# dispatches even though they were faithfully recorded — just in the wrong place.
# Resolve via the Trap-3 shared identity helper (hooks/lib/git-main-root.sh, same
# one C-2's durable-artifact-copy.sh consumes) so this agrees with every other
# main-root consumer regardless of whether $ARTIFACT/$PWD is inside a linked
# worktree. Falls back to $ART_DIR (prior behavior) only if git resolution fails
# entirely (e.g. a non-git sandbox in a test harness).
_GMR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../../hooks/lib" 2>/dev/null && pwd)/git-main-root.sh"
PROV_MAIN_ROOT=""
if [ -f "$_GMR_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_GMR_LIB" 2>/dev/null && PROV_MAIN_ROOT="$(resolve_main_root "$ART_DIR" 2>/dev/null || true)"
fi
if [ -z "$PROV_MAIN_ROOT" ] && [ -f "$_GMR_LIB" ]; then
  # H4-7a (PLAN_2026-07-02_orchestrator-hardening-4): an out-of-repo --artifact (e.g. the session
  # SCRATCHPAD — a hostile-review dispatch) makes resolve_main_root(ART_DIR) fail even
  # though the CALLER's cwd is the repo. Prefer an EXPLICIT $PROJECT_ROOT (review MEDIUM: $PWD
  # alone could name an UNRELATED repo if the caller cd'd away), then $PWD, before surrendering
  # to the artifact dir — otherwise the provenance witness lands OUTSIDE the repo and invites
  # hand-copying lines into the canonical log (the exact witness-integrity breach observed
  # 2026-07-02).
  if [ -n "${PROJECT_ROOT:-}" ] && [ -d "${PROJECT_ROOT:-}" ]; then
    PROV_MAIN_ROOT="$(resolve_main_root "$PROJECT_ROOT" 2>/dev/null || true)"
  fi
  [ -z "$PROV_MAIN_ROOT" ] && PROV_MAIN_ROOT="$(resolve_main_root "$PWD" 2>/dev/null || true)"
fi
if [ -n "$PROV_MAIN_ROOT" ] && [ -d "$PROV_MAIN_ROOT" ]; then
  PROV_DIR="$PROV_MAIN_ROOT/.v/artifacts"
  mkdir -p "$PROV_DIR" 2>/dev/null || PROV_DIR="$ART_DIR"
else
  PROV_DIR="$ART_DIR"   # fallback: prior behavior (co-located with the artifact)
fi
PROV_LOG="${PROV_DIR}/DISPATCH_PROVENANCE_${PROV_SID:-unknown}.log"

# === 17c (R4 HIGH-2 downgraded, forensic 2026-07-03): witness SID-match / acting_as ===
# PROV_SID (this dispatch's OWN identity, from CLAUDE_CODE_SESSION_ID/CLAUDE_SESSION_ID) may differ
# from the session the ARTIFACT is named for (ART_BASE's embedded SID) — e.g. a landing/remediation
# session dispatching verify-done to finish ANOTHER session's gauntlet. That is
# a LEGITIMATE cross-session act, not forgery — but a SILENT mismatch (no caller acknowledgment) must
# be refused, mirroring resolve-session-sid.sh's V_SESSION_LOG_FORCE_CATCHUP guard (Bug 6) for the
# session-log writer. Deliberately does NOT touch the DISPATCH_PROVENANCE line format itself (the
# sha256=…$-anchored regexes in hooks/lib/validation.sh require sha256 to stay the LAST field) —
# acting_as is recorded in its own side-channel marker instead.
_ART_SID="$(printf '%s' "$ART_BASE" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
[ -z "$_ART_SID" ] && _ART_SID="$(printf '%s' "$ART_BASE" | grep -oiE '[0-9a-f]{8}' | head -1)"
ACTING_AS=""
if [ -n "$_ART_SID" ] && [ -n "$PROV_SID" ]; then
  # FULL-SID-MATCH (forensic 2026-07-04, pre-flight #3): the comparison used to key on the
  # 8-char PREFIX only. A model-transcribed artifact path with a mis-typed LATER UUID segment
  # (two session ids that shared their first 24 hex characters)
  # therefore PASSED the prefix check and wrote every gauntlet artifact under a NON-EXISTENT SID,
  # severing the evidence chain (QA read the wrong ledger and concluded the gates never ran). When
  # BOTH the artifact SID and an env identity are FULL UUIDs, compare the FULL strings so a
  # transcription error anywhere in the UUID is caught. Fall back to the 8-char prefix only when the
  # artifact SID is a bare 8-char slug (the legacy short-form some artifacts still use).
  _is_full_uuid() { printf '%s' "$1" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; }
  _art_lc="$(printf '%s' "$_ART_SID" | tr '[:upper:]' '[:lower:]')"
  _art_short_lc="$(printf '%s' "${_ART_SID:0:8}" | tr '[:upper:]' '[:lower:]')"
  _prov_lc="$(printf '%s' "$PROV_SID" | tr '[:upper:]' '[:lower:]')"
  _prov_short_lc="$(printf '%s' "${PROV_SID:0:8}" | tr '[:upper:]' '[:lower:]')"
  _art_is_full=0; _is_full_uuid "$_ART_SID" && _art_is_full=1
  # cmp(): 0 iff the artifact SID matches the given env SID at the strongest available resolution.
  _sid_cmp() {  # $1 = an env/prov sid
    local _e="$1" _e_lc
    [ -n "$_e" ] || return 1
    _e_lc="$(printf '%s' "$_e" | tr '[:upper:]' '[:lower:]')"
    if [ "$_art_is_full" -eq 1 ] && _is_full_uuid "$_e"; then
      [ "$_art_lc" = "$_e_lc" ]        # both full → FULL-string compare (catches later-segment typos)
    else
      [ "$_art_short_lc" = "$(printf '%s' "${_e:0:8}" | tr '[:upper:]' '[:lower:]')" ]   # legacy 8-char
    fi
  }
  # A same-session write is one where the artifact SID matches ANY of this dispatch's env
  # identities — not just the PROV_SID precedence winner. CLAUDE_CODE_SESSION_ID leaks from the
  # OUTER session into nested/sandboxed contexts (the known test-env SID-leak trap), so requiring
  # the precedence winner alone false-blocks a dispatch whose CLAUDE_SESSION_ID matches the
  # artifact exactly (h4-3 regression, 2026-07-03).
  _sid_matches_any_env=0
  for _env_sid in "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"; do
    if _sid_cmp "$_env_sid"; then _sid_matches_any_env=1; break; fi
  done
  if ! _sid_cmp "$PROV_SID" && [ "$_sid_matches_any_env" -eq 0 ]; then
    if [ "${V_DISPATCH_ACTING_AS:-}" = "$PROV_SID" ]; then
      ACTING_AS="$PROV_SID"
      _aa_tmp=$(mktemp "${PROV_DIR}/ACTING_AS_${_ART_SID}.json.XXXXXX" 2>/dev/null || echo "${PROV_DIR}/ACTING_AS_${_ART_SID}.json.$$.tmp")
      printf '{"target_sid":"%s","acting_as":"%s","agent":"%s","artifact":"%s","ts":"%s"}\n' \
        "$_ART_SID" "$ACTING_AS" "${AGENT:-model:${MODEL:-unknown}}" "$ART_BASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
        > "$_aa_tmp" 2>/dev/null && mv "$_aa_tmp" "${PROV_DIR}/ACTING_AS_${_ART_SID}.json" 2>/dev/null || rm -f "$_aa_tmp" 2>/dev/null
      echo "NOTE: acting_as=$ACTING_AS recorded — this dispatch (session $PROV_SID) is writing an artifact for session $_ART_SID (${PROV_DIR}/ACTING_AS_${_ART_SID}.json)" >&2
    else
      echo "ERROR: v-dispatch-subagent: artifact '$ART_BASE' names session '$_ART_SID' but this dispatch is running as session '$PROV_SID' (CLAUDE_CODE_SESSION_ID/CLAUDE_SESSION_ID) — a cross-session write." >&2
      echo "  Refused: a silently-mismatched cross-session write is indistinguishable from writing over a sibling's live gauntlet artifact." >&2
      echo "  If the two SIDs share a leading prefix but differ in a LATER UUID segment, this is almost certainly a TRANSCRIPTION ERROR (a hand-typed SID in a dispatch command) — re-issue with \$CLAUDE_SESSION_ID interpolated, never a copy-pasted UUID (forensic 2026-07-04)." >&2
      echo "  If this IS a genuine cross-session remediation (one session finishing another's gauntlet), re-run with:" >&2
      echo "    V_DISPATCH_ACTING_AS=$PROV_SID bash ${BASH_SOURCE[0]:-$0} ${_ORIG_ARGS[*]}" >&2
      exit 7
    fi
  fi
fi
# === end 17c ===

# CEREMONY-D3 (2026-06-30): drop a discoverable POINTER to the prov log under the repo's .v/tmp so the orchestrator
# can `cat` one known path instead of probing 4-8 dirs (the prov log location varies: root vs consolidated .v/artifacts,
# and the stdout echo at the end is easily missed). Best-effort, never fails the dispatch.
_prov_ptr_dir="${V_TMP_DIR:-$(git -C "$ART_DIR" rev-parse --show-toplevel 2>/dev/null)/.v/tmp}"
if [ -n "${_prov_ptr_dir:-}" ] && [ "${_prov_ptr_dir}" != "/.v/tmp" ] && mkdir -p "$_prov_ptr_dir" 2>/dev/null; then
  printf '%s\n' "$PROV_LOG" > "${_prov_ptr_dir}/dispatch-prov-loc-${PROV_SID:-unknown}.txt" 2>/dev/null || true
fi
TRACE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/v-trace-span.sh"
TRACE_SID="${PROV_SID:-unknown}"
TRACE_SPAN="dispatch:${AGENT:-model:${MODEL:-unknown}}"
trace_event() {
  [ -x "$TRACE_HELPER" ] || return 0
  local _event="${1:-}"; shift 2>/dev/null || true
  "$TRACE_HELPER" "$_event" "$TRACE_SID" "$TRACE_SPAN" \
    --repo "$PROJ" \
    --parent "subprocess-dispatch" \
    --runner "${AGENT:-model:${MODEL:-unknown}}" \
    --mode "$MODE" \
    --artifact "$ARTIFACT" \
    "$@" >/dev/null 2>&1 || true
}
# emit_marker <status> — append one pipe-delimited key=value record. Best-effort:
# provenance must NEVER fail the dispatch (|| true).
# W5G-4 (forensic 2026-06-07): the record now BINDS the artifact content via
# sha256, appended as the LAST field (append-only schema change — existing
# key=value parsers are unaffected). `emit_marker ok` runs AFTER the artifact is
# persisted in both modes, so the hash captures exactly what the independent
# runner produced. The Stop hook compares this against the on-disk artifact: a
# silent post-dispatch hand-edit (one production session padded the runner's 766B
# PRE_FLIGHT to 1425B via Write, keeping `Model: haiku`) no longer passes as
# 'dispatched' — it must carry an explicit `Post-dispatch edit:` declaration.
emit_marker() {
  _em_sha=""
  # FIX-5 (self-audit 2026-06-18): portable sha256 — Linux CI ships `sha256sum` but not
  # `shasum`; macOS ships `shasum` but not always `sha256sum`. Both emit `<64hex>  <file>`,
  # so the `awk '{print $1}'` and the marker's `sha256=[0-9a-fA-F]{64}` pattern are unchanged.
  # Verified atomically with hooks/lib/validation.sh:_artifact_postdispatch_edited (same fallback).
  if [ "$1" = "ok" ] && [ -s "$ARTIFACT" ]; then
    if command -v shasum >/dev/null 2>&1; then
      _em_sha=$(shasum -a 256 "$ARTIFACT" 2>/dev/null | awk '{print $1}')
    elif command -v sha256sum >/dev/null 2>&1; then
      _em_sha=$(sha256sum "$ARTIFACT" 2>/dev/null | awk '{print $1}')
    fi
    # W5G-4c (forensic 2026-07-10, one project): preserve the dispatched ORIGINAL at ok-time.
    # hooks/lib/validation.sh:_dispatched_original_survives honors a 'Post-dispatch edit:'
    # declaration ONLY while some durable copy still hashes to a recorded ok-sha — but nothing
    # ever CREATED that copy, so the declared-edit downgrade was unsatisfiable in practice: every
    # legitimate post-dispatch correction stayed hard-'edited' (BLOCK), which livelocked sessions
    # between Item-19 artifact-staleness and W5G-4 and drove 3 rearm-escapes in one evening.
    # Archive into the exact store the survives-scan already searches (.v/archive/<sid>/, matched
    # via its sid-substring candidate glob — hence the sid-bearing filename prefix). One
    # timestamped copy per ok so a later re-dispatch never clobbers an earlier original.
    # Canonical-layout only; best-effort (a failed cp degrades to today's behavior, never fails
    # the dispatch); small files only (5MB cap).
    if [ -n "$_em_sha" ]; then
      case "$PROV_DIR" in
        */.v/artifacts)
          _em_asz=$(wc -c < "$ARTIFACT" 2>/dev/null | tr -d ' ')
          if [ "${_em_asz:-0}" -le 5242880 ] 2>/dev/null; then
            _em_arch="${PROV_DIR%/artifacts}/archive/${PROV_SID:-unknown}"
            mkdir -p "$_em_arch" 2>/dev/null \
              && cp -f "$ARTIFACT" "$_em_arch/dispatched-${PROV_SID:-unknown}-$(date -u +%Y%m%dT%H%M%SZ)-${ART_BASE}" 2>/dev/null \
              || true
          fi
          ;;
      esac
    fi
  fi
  # F6-closer (forensic 2026-07-10, one project): track open/terminal state so the EXIT trap
  # can guarantee every `started` row gets a terminal row — a v-qa-reviewer dispatch died leaving
  # status=started with NO closer and no artifact, a silent provenance hole nothing noticed.
  # `transient` counts as terminal FOR THIS PROCESS: emit_marker transient is immediately followed
  # by `exit` (the caller retries in a FRESH invocation), so excluding it here made the EXIT trap
  # append a spurious contradictory `aborted` row after every ordinary rate-limit retry — exactly
  # the silent-death signature this closer exists to detect (adversarial review 2026-07-10, HIGH).
  case "$1" in
    started|reattached) _EM_STARTED=1 ;;   # W-REATTACH: a re-attaching helper is mid-dispatch too — its own kill must take the detached branch
    *) _EM_TERMINAL=1 ;;
  esac
  # H4-7c (PLAN_2026-07-02_orchestrator-hardening-4): `ts=` is PINNED to dispatch END time (the
  # instant this line is written), NOT the dispatch start — emit_marker is called AFTER the
  # subprocess/agent has finished and (for `ok`) the artifact has been persisted, so `ts` and
  # `sha256` describe the SAME moment. This must stay in sync with the OTHER provenance writer (the
  # direct codex-exec snippet in v-agent-review.md, which computes its own `_TS` after codex exits,
  # for the same reason) — downstream consumers (gather, dedup) assume ts=END across BOTH writers.
  printf 'DISPATCH|ts=%s|agent=%s|mode=%s|status=%s|submodel=%s|cost_usd=%s|duration_ms=%s|artifact=%s|sha256=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${AGENT:-model:${MODEL:-?}}" "$MODE" "$1" \
    "${SUBMODEL:-${AGENT_PINNED_MODEL:-${MODEL:-unknown}}}" "${COST:-}" "${DURATION:-}" "$ART_BASE" "$_em_sha" \
    >> "$PROV_LOG" 2>/dev/null || true
  # C2 (telemetry 2026-06-21): mirror this dispatch into the UNIFIED DISPATCH_LEDGER.jsonl so the fork's
  # PRIMARY path — the `claude -p` SUBPROCESS dispatch — is captured. The G1 PostToolUse hook only sees
  # Agent-TOOL dispatches, which a forked orchestrator structurally CANNOT use (subagents can't spawn
  # subagents) → the ledger was blind to ~82% of cross-process dispatches (G1-1). Records the ACTUAL
  # billed model (model_used=SUBMODEL from .modelUsage) alongside the request (G1-4), and the real
  # dispatch_path (the --mode). One row per dispatch: skip the transient retry marker.
  if [ "$1" != "transient" ]; then
    # review MED (2026-06-21): strip "/\ from the interpolated identifiers so a stray quote in an agent/
    # model string can never produce a malformed JSON row (these are identifiers — no legit quotes/backslashes).
    local _j_sid _j_ag _j_mr _j_mu _j_ma
    _j_sid="${PROV_SID:-unknown}"; _j_ag="${AGENT:-model:${MODEL:-unknown}}"
    _j_mr="${MODEL:-inherit}"; _j_mu="${SUBMODEL:-${AGENT_PINNED_MODEL:-${MODEL:-unknown}}}"
    # W-SUBMODEL-DOMINANT (2026-08-11): model_used is now the highest-SPEND entry; model_used_all
    # carries every entry in .modelUsage so the built-in tool helper models (WebSearch's haiku) stay
    # auditable instead of masquerading as the dispatch's own model. New field — JSONL readers that
    # select known keys are unaffected.
    _j_ma="${SUBMODEL_ALL:-}"
    _j_sid="${_j_sid//[\"\\]/}"; _j_ag="${_j_ag//[\"\\]/}"; _j_mr="${_j_mr//[\"\\]/}"; _j_mu="${_j_mu//[\"\\]/}"
    _j_ma="${_j_ma//[\"\\]/}"
    # item-20 (2026-07-03, same worktree split-brain class as PROV_LOG above): use PROV_DIR
    # (resolve_main_root-resolved canonical .v/artifacts, falling back to ART_DIR only when
    # resolution fails) instead of the raw ART_DIR — a dispatch launched with a worktree-scoped
    # --artifact previously wrote DISPATCH_LEDGER.jsonl INTO the worktree, invisible to a later
    # main-root read (the exact class PROV_LOG was already fixed for; this sibling idiom was
    # missed in the same sweep).
    printf '{"ts":"%s","parent_sid":"%s","agent_type":"%s","model_requested":"%s","model_used":"%s","model_used_all":"%s","dispatch_path":"%s","status":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_j_sid" "$_j_ag" "$_j_mr" "$_j_mu" "$_j_ma" "$MODE" "$1" \
      >> "${PROV_DIR:-$ART_DIR}/DISPATCH_LEDGER.jsonl" 2>/dev/null || true
  fi
}

# ── 3. Derive the tool allowlist from the agent frontmatter ───────────────────
# `claude -p` auto-denies any tool not in --allowedTools (it cannot prompt). We
# grant exactly the tools the agent declares — no more. The agent's own
# frontmatter `tools:` line is the ceiling; we never exceed it. For capture mode
# we additionally strip Write/Edit/MultiEdit/NotebookEdit so a read-only runner
# physically cannot touch source even if its frontmatter were mis-edited.
declare -a ALLOWED=()
if [ -n "$AGENT_FILE" ]; then
  TOOLS_LINE=$(grep -m1 -E '^tools:' "$AGENT_FILE" | sed -E 's/^tools:[[:space:]]*//')
  # Tolerate the inline-YAML-array style too (`tools: [Bash, Read]`): strip the
  # surrounding brackets and any quotes before splitting on commas (codex review #3).
  TOOLS_LINE=$(printf '%s' "$TOOLS_LINE" | sed -E 's/^\[//; s/\]$//; s/["'\'']//g')
  IFS=',' read -ra _raw <<< "$TOOLS_LINE"
  for t in "${_raw[@]}"; do
    t="$(printf '%s' "$t" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$t" ] && ALLOWED+=("$t")
  done
fi
# Safe default when there was no tools line, no --agent (model dispatch), or the
# parse yielded nothing (e.g. multiline YAML-list frontmatter the inline parser
# can't read). NEVER proceed with an empty allowlist — that would make the
# variadic `--allowedTools` swallow `--output-format`, producing a malformed
# invocation / non-JSON output (codex review #3 + #5). Warn so frontmatter drift
# is visible rather than silently degrading.
if [ ${#ALLOWED[@]} -eq 0 ]; then
  [ -n "$AGENT_FILE" ] && echo "WARNING: could not parse a 'tools:' allowlist from $AGENT_FILE — falling back to read-only default. If the agent needs Write/MCP tools, check its frontmatter style." >&2
  ALLOWED=( Bash Read Grep Glob BashOutput )
fi
# Capture mode: defensively drop any write-capable tool.
if [ "$MODE" = "capture" ]; then
  declare -a _filtered=()
  for t in "${ALLOWED[@]}"; do
    case "$t" in Write|Edit|MultiEdit|NotebookEdit) ;; *) _filtered+=("$t") ;; esac
  done
  ALLOWED=("${_filtered[@]}")
fi
# Append caller-supplied extra tools (e.g. mcp__playwright__*).
if [ -n "$EXTRA_TOOLS" ]; then
  for t in $EXTRA_TOOLS; do ALLOWED+=("$t"); done
fi
# Final guard: NEVER invoke claude with an empty --allowedTools (it would swallow
# the next flag). Re-default if filtering emptied the list (codex review #5).
if [ ${#ALLOWED[@]} -eq 0 ]; then
  ALLOWED=( Bash Read Grep Glob BashOutput )
fi

# ── 4. Build the prompt (base + mode epilogue) ────────────────────────────────
EPILOGUE_CAPTURE=$'\n\n---\n⚠️ SUBPROCESS CAPTURE MODE (read this LAST, it OVERRIDES any earlier "use the Write tool" instruction):\nYou do NOT have the Write tool. Do NOT attempt to write, edit, or create any file. After completing your analysis, emit the COMPLETE artifact markdown as your FINAL message. Begin that message with the exact first line the format requires (e.g. `Model: haiku`) with NOTHING before it, and NO commentary, preamble, or sign-off after the artifact. Output RAW markdown — do NOT wrap it in a ``` code fence. The parent process captures your final message verbatim and persists it.'
EPILOGUE_SELFWRITE=$'\n\n---\n⚠️ SUBPROCESS SELF-WRITE MODE (read this LAST):\nWrite your artifact using the Write tool to EXACTLY this path:\n  '"$ARTIFACT"$'\nUse this literal path regardless of any other path derived from your environment. After writing, emit a one-line confirmation. Do NOT edit any source file.'

PROMPT="$(cat "$PROMPT_FILE")"
if [ "$MODE" = "capture" ]; then
  PROMPT="${PROMPT}${EPILOGUE_CAPTURE}"
else
  PROMPT="${PROMPT}${EPILOGUE_SELFWRITE}"
fi

# ── 5. Run the subprocess ─────────────────────────────────────────────────────
declare -a ARGS=( -p --no-session-persistence )
if [ -n "$AGENT" ]; then
  ARGS+=( --agent "$AGENT" )
elif [ -n "$MODEL" ]; then
  ARGS+=( --model "$MODEL" )
fi
# --allowedTools is variadic; --output-format (a flag) terminates it. Prompt is
# fed on stdin so there is no positional arg for the variadic to swallow.
ARGS+=( --allowedTools "${ALLOWED[@]}" --output-format json )

JSON_OUT="$V_TMP/dispatch-sub-$$-$(date +%s).json"
ERR_OUT="$V_TMP/dispatch-sub-$$-$(date +%s).err"
# W-REATTACH: with the artifact lock held, every per-dispatch scratch file is a FIXED name inside
# the lock dir — derived here, never read from the lease — so a second helper can find them after
# the first was killed, and a forged lease can never point the helper at a path outside the dir.
if [ -n "${_DL_DIR:-}" ]; then JSON_OUT="$_DL_DIR/json"; ERR_OUT="$_DL_DIR/err"; fi
# C3a: write the prompt to a temp file and redirect stdin from it, rather than piping
# via printf. A large prompt (e.g. one containing a long git diff) can trigger
# stdin-EOF when piped through a shell variable — the claude subprocess closes its
# stdin before reading all content, causing codex exec to report "stdin EOF on long diff"
# and fall back to orchestrator-inline review (observed incident). File-based
# stdin is fully written before the reader opens it, eliminating the EOF race.
PROMPT_TMP="$V_TMP/dispatch-prompt-$$-$(date +%s).txt"
[ -n "${_DL_DIR:-}" ] && PROMPT_TMP="$_DL_DIR/prompt"

# ORCHFIX-F1 (forensics 2026-07-02): sideline the pre-existing artifact instead of
# DESTROYING it. The old `rm -f` here, combined with a tool-cap SIGTERM/timeout killing this
# helper mid-dispatch, deleted a GOOD runner-produced VERIFY_DONE_REPORT before the child could
# write its replacement — the session then had to re-dispatch from nothing. The codex cycle-2 #1
# anti-stale property is PRESERVED: during the dispatch window $ARTIFACT is absent, so a non-empty
# $ARTIFACT still means the agent/helper produced it THIS run. The EXIT-trap settle then enforces
# the invariant "a failed dispatch leaves the world as it found it": new artifact produced → the
# stale copy is discarded; dispatch failed/killed (SIGTERM runs the EXIT trap) → the pre-dispatch
# artifact is restored, and its content still matches its ORIGINAL provenance sha, so the tamper
# gate keeps treating it as the earlier dispatch's canonical output.
_ART_STALE="$ARTIFACT.stale.$$"
[ -n "${_DL_DIR:-}" ] && _ART_STALE="$_DL_DIR/stale"

_art_stale_settle() {
  if [ -n "${_ART_STALE:-}" ] && [ -f "$_ART_STALE" ]; then
    if [ -s "$ARTIFACT" ]; then rm -f "$_ART_STALE" 2>/dev/null || true
    else mv -f "$_ART_STALE" "$ARTIFACT" 2>/dev/null || true; fi
  fi
}
# F6-closer (forensic 2026-07-10, one project): if we emitted `started` but never reached a
# terminal emit (SIGTERM/timeout/INT or an unexpected exit path), write status=aborted from the
# EXIT trap so the provenance log never carries a dangling `started` row. Counters/dedup key on
# `status=ok`, so an extra aborted row is additive-safe (same contract as the existing note that
# started rows are additive-safe). SIGKILL remains uncoverable — the started row itself stays the
# evidence for that case, unchanged.
_em_close_guard() {
  # W-REATTACH: the child is in its own session and STILL RUNNING (no rc yet) → this helper is
  # dying out from under it (tool timeout / signal), whether or not it got as far as emitting its
  # own started/reattached row (a re-attaching helper killed during startup emits nothing, yet the
  # child it was about to adopt is just as alive). Sign the detach proof, record `detached` when a
  # row is open, keep the lock dir (lease + scratch + stale) and touch nothing else, so the same
  # dispatch command re-attaches instead of re-running the work.
  if [ -n "${_DL_DIR:-}" ] && [ ! -f "$_DL_DIR/rc" ] && _wr_child_alive "$_DL_DIR" 2>/dev/null; then
    _WR_DETACHED=1
    _wr_proof_write "$_DL_DIR"
    if [ "${_EM_STARTED:-0}" = "1" ] && [ "${_EM_TERMINAL:-0}" != "1" ]; then emit_marker detached; fi
    echo "DISPATCH_STATUS=detached"
    echo "DISPATCH_LOCK_DIR=$_DL_DIR"
    echo "DISPATCH_CHILD_PID=$(_wr_child_pid "$_DL_DIR")"
    echo "NOTICE (W-REATTACH): this helper was terminated (tool timeout / signal) but the dispatched subprocess is STILL RUNNING in its own session (pid $(_wr_child_pid "$_DL_DIR")). Nothing was lost. Re-issue the SAME dispatch command (same --agent/--mode/--artifact, timeout: 600000) and it will RE-ATTACH to that child instead of starting over." >&2
    return 0
  fi
  if [ "${_EM_STARTED:-0}" = "1" ] && [ "${_EM_TERMINAL:-0}" != "1" ]; then
    emit_marker aborted
  fi
}
# W-DISPATCHLOCK: release folded in HERE rather than via a second trap — an EXIT trap installed
# earlier in this script would be silently clobbered by this one, leaking the lock dir every run.
# `${_DL_DIR:-}` is empty whenever we did not acquire (nested subshell, or fail-open), so the rm
# is a no-op in exactly those cases.
trap '_wr_rc=$?; _em_close_guard; if [ "${_WR_DETACHED:-0}" != 1 ] && [ -n "${_V_DETACH_STATUS_FILE:-}" ] && ! grep -q "^DONE " "$_V_DETACH_STATUS_FILE" 2>/dev/null; then printf "DONE rc=%s finished=%s\n" "$_wr_rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_V_DETACH_STATUS_FILE" 2>/dev/null; fi; if [ "${_WR_DETACHED:-0}" != 1 ]; then _art_stale_settle; [ -n "${_DL_DIR:-}" ] && rm -rf "$_DL_DIR" 2>/dev/null; rm -f "$JSON_OUT" "$ERR_OUT" "$PROMPT_TMP" 2>/dev/null; fi; true' EXIT
# Bash does NOT run the EXIT trap on an UNTRAPPED fatal signal — and SIGTERM is exactly what the
# Bash tool's timeout sends (exit 143, the artifact-destruction case). Trap it so the
# settle runs; `exit` inside the handler then fires the EXIT trap (settle is idempotent).
trap 'exit 143' TERM
trap 'exit 130' INT
if [ "$_WR_REATTACH" -ne 1 ]; then
  if [ -f "$ARTIFACT" ]; then
    mv -f "$ARTIFACT" "$_ART_STALE" 2>/dev/null || rm -f "$ARTIFACT" 2>/dev/null || true
  fi
  printf '%s' "$PROMPT" > "$PROMPT_TMP"
fi
trace_event start --detail "claude subprocess dispatch"

# W-perf9b (2026-06-02): hard TIMEOUT CEILING on the gate child. A FOREGROUND gate
# dispatch (run_in_background:false) that overruns the Bash tool's timeout is
# AUTO-BACKGROUNDED by the runtime, and the orchestrator then "waits for the completion
# notification" and goes passive — a production session stranded ~81 minutes on exactly
# this (a QA `claude -p` that ran long under a 10-min tool timeout). W-perf9 in
# block-v-polling.sh only catches run_in_background:TRUE, so it cannot see this case.
# Capping the child here means it self-terminates (normalized to rc 124, the supervisor's
# known timeout code) and the caller applies its DOCUMENTED fallback instead of stalling.
# Default 900s; override with V_DISPATCH_TIMEOUT_SEC. For SHORT gates set it BELOW the
# orchestrator's Bash tool timeout (e.g. 540 when the tool timeout is 600) to kill the child
# before the runtime auto-backgrounds it — eliminating the passive-wait stall entirely. Happy
# path (child finishes first) is byte-identical to the previous direct call.
# EXCEPTION — v-qa-reviewer is dispatched with V_DISPATCH_TIMEOUT_SEC=900 (the full ceiling, ABOVE
# the 600s foreground tool cap): exploratory/adversarial QA legitimately runs long (forensic
# a QA dispatch was killed at 600s twice → escalated with no QA_REPORT). That dispatch WILL auto-
# background; the caller MUST poll via BashOutput (never go passive). This 900s cap still bounds a
# truly-hung QA child (self-terminates → rc124 → escalate), so the longer budget stays safe.
_run_bounded() {
  # $1 = ceiling seconds; $2.. = command. Caller supplies stdin/stdout/stderr redirection;
  # the backgrounded child + watchdog inherit it (watchdog's own output is sent to /dev/null
  # so it never pollutes the captured JSON/stderr files).
  local _to="$1"; shift
  local _rc
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 30 "$_to" "$@"; _rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 30 "$_to" "$@"; _rc=$?
  else
    # Portable bash watchdog (macOS ships no `timeout`/`gtimeout`). The `<&0` is REQUIRED:
    # bash redirects an asynchronous (backgrounded) command's stdin to /dev/null UNLESS there
    # is an explicit redirection — so the caller's `< "$PROMPT_TMP"` would NOT reach a bare
    # `"$@" &`, starving `claude -p` of its prompt ("Input must be provided either through
    # stdin or as a prompt argument when using --print" → every dispatch fails → all gates
    # silently degrade to orchestrator-inline). `<&0` is an explicit redirection that ties the
    # backgrounded child to the caller-supplied stdin, defeating the /dev/null default.
    "$@" <&0 &
    local _cpid=$!
    ( sleep "$_to"; kill -TERM "$_cpid" 2>/dev/null; sleep 30; kill -KILL "$_cpid" 2>/dev/null ) >/dev/null 2>&1 &
    local _wpid=$!
    wait "$_cpid" 2>/dev/null; _rc=$?
    kill "$_wpid" 2>/dev/null || true   # child done → cancel the watchdog so it can't linger
    wait "$_wpid" 2>/dev/null || true
  fi
  # Normalize a timeout-kill (SIGTERM=143 / SIGKILL=137) to 124 so the existing
  # "rc != 0 → error → caller fallback" path (and the supervisor's rc-124 retry) handles it.
  if [ "${_rc:-0}" -eq 137 ] || [ "${_rc:-0}" -eq 143 ]; then _rc=124; fi
  return "$_rc"
}
# A-1c (handoff-3, 2026-07-02): timeout-race honesty check. `_run_bounded`'s watchdog kills the
# `claude` child at the ceiling and normalizes the kill to rc 124 — but the UNDERLYING gate work
# (v-run-gates.sh, invoked BY the dispatched agent) may have already finished and written its own
# `gate-summary-<sid>.txt` with a `DONE_AT=` timestamp BEFORE the kill landed; only the wrapper's
# OWN JSON-formatting/teardown overran the ceiling. Recording that as a flat `status=error` (a) is
# dishonest telemetry (the real work succeeded, just slow to report) and (b) creates "row-
# fabrication pressure" — a human reconstructing what actually happened is tempted to hand-edit the
# provenance log to say what they know is true. Detecting it lets the log say so honestly instead:
# `status=ok_late`. This does NOT change the exit code (the wrapper still cannot prove the FINAL
# required $ARTIFACT was produced — that is verified separately in step 7 — so the caller still
# applies its documented fallback), it only makes the provenance record honest.
_check_ok_late() {  # <dispatch_start_epoch> <sid> <v_tmp_dir> -> 0 iff gate-summary proves the
                     # underlying work completed within [dispatch_start, now]
  local _start="$1" _sid="$2" _vtmp="$3"
  local _summary="${_vtmp}/gate-summary-${_sid}.txt"
  [ -f "$_summary" ] || return 1
  # A summary carrying DETECTION_ERROR= (gate_timeout_*, pest_worker_crash_or_oom, ...) is a
  # NON-completed / non-authoritative run — v-run-gates.sh writes DONE_AT even on its own
  # internal timeout summary, so DONE_AT alone is not proof the work completed (codex CDX-1).
  if grep -q '^DETECTION_ERROR=' "$_summary" 2>/dev/null; then return 1; fi
  local _done_line _done_ts _done_epoch _now
  _done_line="$(grep -m1 '^DONE_AT=' "$_summary" 2>/dev/null)"
  [ -n "$_done_line" ] || return 1
  _done_ts="${_done_line#DONE_AT=}"
  _done_epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$_done_ts" +%s 2>/dev/null \
    || date -u -d "$_done_ts" +%s 2>/dev/null || echo 0)
  [ "$_done_epoch" -gt 0 ] 2>/dev/null || return 1
  _now=$(date -u +%s)
  # Must fall within THIS dispatch's window — never treat a STALE summary left over from a prior
  # dispatch attempt (e.g. an earlier retry) as evidence for the current one.
  [ "$_done_epoch" -ge "$_start" ] && [ "$_done_epoch" -le "$_now" ]
}

_V_DISPATCH_TIMEOUT_SEC="${V_DISPATCH_TIMEOUT_SEC:-900}"
# ORCHFIX-F3 (forensics 2026-07-02 — QA rc124×2 in one session, QA killed×2 in another, plus
# pre-flight-adjacent churn): the QA reviewer's 900s budget is documented in TWO places above,
# yet sessions keep passing sub-600s caps ("below the tool timeout" generic guidance misapplied)
# and shipping DEGRADED QA after two dead dispatches. A comment-level fix recurred within days —
# make it mechanical: a v-qa-reviewer dispatch below 900s is auto-raised. The dispatch WILL
# auto-background past the foreground tool cap; poll BashOutput, never go passive.
if [ "${AGENT:-}" = "v-qa-reviewer" ] && [ "${_V_DISPATCH_TIMEOUT_SEC}" -lt 900 ] 2>/dev/null; then
  echo "WARN (ORCHFIX-F3): V_DISPATCH_TIMEOUT_SEC=${_V_DISPATCH_TIMEOUT_SEC} is below the sanctioned 900s v-qa-reviewer budget — auto-raised to 900. Sub-600s QA caps killed the reviewer twice in each of two production sessions and forced degraded QA declarations." >&2
  _V_DISPATCH_TIMEOUT_SEC=900
fi
DISPATCH_START_EPOCH=$(date -u +%s)
[ "$_WR_REATTACH" -eq 1 ] && DISPATCH_START_EPOCH="$_WR_START"   # W-REATTACH: ok_late/sid-leak windows anchor on the ORIGINAL start
# F8-1 (SID-leakage hardening, forensic 2026-07-05): explicitly export the PARENT session's SID
# into the subprocess's own environment via the CLAUDE_SESSION_ID alias. Empirically verified
# (2026-07-05, claude 2.1.201): `claude -p` ALWAYS overwrites CLAUDE_CODE_SESSION_ID with a
# freshly-minted CHILD session id for its own internal tool calls (confirmed via a live subprocess
# dispatch reporting a distinct `.session_id` in its JSON result, and a distinct
# CLAUDE_CODE_SESSION_ID inside its own `env` output) — so that var can NEVER carry the parent's
# identity down. CLAUDE_SESSION_ID, in contrast, is NOT special-cased by the `claude` binary and
# passes through process inheritance completely unchanged (verified the same way). Every v-*.sh
# script's canonical SID resolver (hooks/lib/resolve-sid.sh, v-bootstrap.sh, v-gauntlet-attest.sh,
# ...) checks CLAUDE_SESSION_ID FIRST — so if the runner subprocess internally invokes any of those
# scripts (e.g. an artifact/session helper), this export is what lets it resolve the PARENT's SID
# instead of silently falling through to its own unrelated child CLAUDE_CODE_SESSION_ID. Without
# this, a dispatching session whose own environment never happened to carry CLAUDE_SESSION_ID
# (only CLAUDE_CODE_SESSION_ID, which the subprocess overwrites) would leave the runner with NO
# reliable way to learn who dispatched it via env — exactly the "SID leakage" this hardening closes.
export CLAUDE_SESSION_ID="${PROV_SID:-${CLAUDE_SESSION_ID:-}}"
# W5G-8 (forensic 2026-07-10 #2, one project): mark the child as a
# DISPATCHED RUNNER so session-lifecycle Stop gates (check-review-artifact.sh,
# uncommitted-changes-gate.sh) can exempt it. Runner sessions inherit shared-tree /
# branch-commit attribution and otherwise spiral into 3-strike STOP_REARM escapes (5 in one
# afternoon). The marker is an HMAC token (dispatched-runner.sh), NOT a static flag — a
# statically-persisted settings.json value can never satisfy the hourly-rotating verify
# (review-CRITICAL: the bare `=1` flag was self-settable and would have disabled both gates
# globally). COMMITTING runners are EXCLUDED (review-MED, v-workflow-verifier commits a
# Playwright spec by design): exempting them from uncommitted-changes-gate would move leftover-
# WIP detection from runner-local to a coarser merge-time check. Read-only reviewer/runner
# agents (the escape-spiral victims) get the token; committers keep the full gate.
case "${AGENT:-}" in
  *workflow-verifier*) : ;;   # write-capable / commits by contract → NOT exempt
  *)
    _dr_lib="${V_HOOK_LIB_DIR:-$HOME/.claude/hooks/lib}/dispatched-runner.sh"
    if [ -f "$_dr_lib" ]; then
      # shellcheck source=/dev/null
      . "$_dr_lib" 2>/dev/null || true
      if type _dispatched_runner_token >/dev/null 2>&1; then
        _dr_tok="$(_dispatched_runner_token 2>/dev/null || true)"
        [ -n "$_dr_tok" ] && export V_DISPATCHED_SUBAGENT="$_dr_tok"
      fi
    fi
    ;;
esac
# ORCHFIX-F2: a `status=started` row BEFORE exec so a dispatch killed by the OUTER tool cap
# (SIGKILL/9 — untrappable) still leaves provenance evidence. Counters/dedup key on `status=ok`
# and (agent, sha256) respectively, so started rows are additive-safe. A started row with no
# terminal row after it is the killed-dispatch signature forensics previously could not see.
# W-REATTACH launch/poll. Fresh: sign the lease, double-fork the child into its own session, poll.
# Re-attach: skip straight to the poll. No perl / no lock dir / no HMAC → today's in-tree run.
_wr_spawn() {  # -> 0 if the detached child was spawned and wrote child.pid
  local _perl="${V_REATTACH_PERL:-perl}" _i
  [ -n "${_DL_DIR:-}" ] || { echo "WARN (W-REATTACH): no artifact lock dir (lock fail-open) — running the subprocess in-tree; a tool-timeout kill will NOT be survivable for this dispatch." >&2; return 1; }
  command -v "$_perl" >/dev/null 2>&1 || { echo "WARN (W-REATTACH): '$_perl' not found — running the subprocess in-tree; a tool-timeout kill will NOT be survivable for this dispatch." >&2; return 1; }
  _wr_lease_write "$_DL_DIR" "$DISPATCH_START_EPOCH" "$_V_DISPATCH_TIMEOUT_SEC" || { echo "WARN (W-REATTACH): could not sign the lease (openssl / per-install secret unavailable) — running the subprocess in-tree; a tool-timeout kill will NOT be survivable for this dispatch." >&2; return 1; }
  rm -f "$_DL_DIR/child.pid" "$_DL_DIR/rc" 2>/dev/null || true
  export -f _run_bounded; export _WR_GWLIB="$_wr_gwlib"
  "$_perl" -e '
    use POSIX qw(setsid);
    my ($pidf, @cmd) = @ARGV;
    my $p = fork(); defined $p or exit 3; exit 0 if $p;
    setsid() or exit 3;
    my $q = fork(); defined $q or exit 3; exit 0 if $q;
    open(my $fh, ">", $pidf) or exit 3; print $fh $$; close $fh;
    exec @cmd; exit 3;' -- "$_DL_DIR/child.pid" \
    bash -c '
      # W-REATTACH child wrapper. RESULT BINDING (security panel 2026-09-08, live PoCs): a same-UID
      # writer can `mv` a forged json over the path while claude keeps writing to the old inode, and
      # `touch -t` defeats any mtime rule — so the wrapper hashes the bytes IT wrote through its own
      # descriptor on an UNLINKED file (no path for anyone to swap or overwrite) and signs
      # rc|sha with the per-install secret. The harvester recomputes sha(json) and verifies. Forging
      # this costs exactly what forging a provenance row costs (the documented same-UID ceiling).
      . "$_WR_GWLIB" 2>/dev/null || true
      # ANONYMOUS OUTPUT FILE (security round 3): open three independent descriptions on a fresh
      # file — 7 read (hash), 8 write (claude stdout), 9 read (copy-out) — then UNLINK the path.
      # With no directory entry there is nothing a second writer can open; an in-place `>` from
      # another process now creates an unrelated file. Only an fd obtained in the microseconds
      # between the create and the unlink could reach the inode — a race, not a door.
      # Round 4: the name must be UNGUESSABLE (child.pid is visible before this line, so a PID-named
      # file could be pre-opened by a same-UID watcher) and the create must be EXCLUSIVE (noclobber:
      # a pre-created file is never adopted). Only the create→unlink microseconds remain.
      _w=""; for _t in 1 2 3 4 5; do _c="$3.w.$$.$RANDOM$RANDOM$RANDOM$RANDOM"; ( set -o noclobber; : > "$_c" ) 2>/dev/null && { _w="$_c"; break; }; done
      [ -n "$_w" ] || { printf "rc=124\n" > "$5"; exit 124; }
      exec 7< "$_w" && exec 8> "$_w" && exec 9< "$_w" && rm -f "$_w"
      _run_bounded "$1" "${@:6}" < "$2" >&8 2> "$4"; _rc=$?
      exec 8>&-
      if command -v shasum >/dev/null 2>&1; then _sha=$(shasum -a 256 <&7 | awk "{print \$1}"); else _sha=$(sha256sum <&7 | awk "{print \$1}"); fi
      exec 7<&-
      cat <&9 > "$3.tmp.$$" 2>/dev/null && mv -f "$3.tmp.$$" "$3" 2>/dev/null
      exec 9<&-
      _h=$(_gw_compute_hmac "v-dispatch-result|${_sha}|${_rc}" 2>/dev/null || true)
      printf "rc=%s\nsha=%s\nhmac=%s\n" "$_rc" "$_sha" "$_h" > "$5"' _ \
    "$_V_DISPATCH_TIMEOUT_SEC" "$PROMPT_TMP" "$JSON_OUT" "$ERR_OUT" "$_DL_DIR/rc" claude "${ARGS[@]}" </dev/null >/dev/null 2>&1
  for _i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$_DL_DIR/child.pid" ] && return 0; sleep 0.5; done
  [ -s "$_DL_DIR/child.pid" ]
}
_wr_poll() {  # sets RC. HARVEST RULES (security panel 2026-09-08, live PoC): an rc file is NEVER
  # trusted while the child is alive (a same-UID writer could plant rc+json mid-run and have the
  # genuine helper sign it — the lock dir is a predictable path that lives for minutes); the child
  # writes json and THEN a SIGNED rc (rc|sha256|HMAC over the bytes it actually wrote); the harvest
  # verifies the signature against json, so a swapped/rewritten json is refused.
  local _to="${_WR_TIMEOUT:-$_V_DISPATCH_TIMEOUT_SEC}" _deadline _cp _jm _rm
  _deadline=$(( DISPATCH_START_EPOCH + _to + 60 ))
  while :; do
    if _wr_child_alive "$_DL_DIR"; then
      if [ "$(date -u +%s)" -ge "$_deadline" ]; then
        _cp="$(_wr_child_pid "$_DL_DIR")"; [ -n "$_cp" ] && { kill -TERM "$_cp" 2>/dev/null; sleep 5; kill -KILL "$_cp" 2>/dev/null; }
        RC=124; return 0
      fi
      sleep 1; continue
    fi
    # child gone: rc lands before the wrapper exits, so one short grace covers the exit race
    [ -f "$_DL_DIR/rc" ] || { sleep 1; [ -f "$_DL_DIR/rc" ] || { RC=124; return 0; }; }   # dead with no rc = SIGKILL-class → the caller's documented fallback
    break
  done
  # HARVEST VERIFICATION: rc carries rc|sha256(json as written)|HMAC. Recompute sha(json) and check
  # the signature; any mismatch (mv-swapped json, in-place rewrite after completion, unsigned or
  # legacy rc) refuses the result — never adopted, never signed by emit_marker.
  local _rcv _sha _hm _calc _now _priv="" _c _t
  _rcv="$(sed -n 's/^rc=//p' "$_DL_DIR/rc" 2>/dev/null | head -1)"; _sha="$(sed -n 's/^sha=//p' "$_DL_DIR/rc" 2>/dev/null | head -1)"; _hm="$(sed -n 's/^hmac=//p' "$_DL_DIR/rc" 2>/dev/null | head -1)"
  # VERIFY-THEN-CONSUME on a PRIVATE copy (security round 5): the shared lock-dir json is read by
  # path again at extraction, so a swap between the hash check and the jq read would bypass the
  # signature. Copy once into an unguessable noclobber file, hash THAT, and point JSON_OUT at it.
  for _t in 1 2 3 4 5; do _c="$V_TMP/dispatch-verified-$$-$RANDOM$RANDOM$RANDOM$RANDOM.json"; ( set -o noclobber; : > "$_c" ) 2>/dev/null && { _priv="$_c"; break; }; done
  [ -n "$_priv" ] && cp -f "$_DL_DIR/json" "$_priv" 2>/dev/null || { echo "ERROR (W-REATTACH harvest): could not take a private copy of the result." >&2; RC=124; return 0; }
  if command -v shasum >/dev/null 2>&1; then _now="$(shasum -a 256 "$_priv" 2>/dev/null | awk '{print $1}')"; else _now="$(sha256sum "$_priv" 2>/dev/null | awk '{print $1}')"; fi
  _calc="$(_gw_compute_hmac "v-dispatch-result|${_sha}|${_rcv}" 2>/dev/null || true)"
  case "$_rcv" in ''|*[!0-9]*) _rcv="" ;; esac
  if [ -z "$_rcv" ] || [ -z "$_sha" ] || [ -z "$_hm" ] || [ -z "$_calc" ] || [ "$_calc" != "$_hm" ] || [ "$_now" != "$_sha" ]; then
    echo "ERROR (W-REATTACH harvest): the result signature does not verify (json sha ${_now:-?} vs signed ${_sha:-?}; rc record ${_rcv:-unsigned}) — the json was replaced or rewritten after the child wrote it. Refusing to adopt it as this dispatch's result." >&2
    : > "$_DL_DIR/json"; rm -f "$_priv" 2>/dev/null; RC=124; return 0
  fi
  _WR_PRIV_JSON="$_priv"; JSON_OUT="$_priv"   # every later read is of the verified private copy; the EXIT trap removes it
  RC="$_rcv"
  case "$RC" in 137|143) RC=124 ;; esac
  return 0
}
if [ "$_WR_REATTACH" -eq 1 ]; then
  emit_marker reattached
  echo "DISPATCH_REATTACHED=1"
  echo "NOTICE (W-REATTACH): re-attached to the subprocess started at $(date -u -r "$DISPATCH_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$DISPATCH_START_EPOCH") by a previous helper (pid $(_wr_lease_field "$_DL_DIR" HELPER_PID)) — its work was NOT lost." >&2
  _wr_poll
else
  _WR_SPAWNED=0; _wr_spawn && _WR_SPAWNED=1
  [ "$_WR_SPAWNED" -eq 1 ] || { [ -n "${_DL_DIR:-}" ] && rm -f "$_DL_DIR/lease" "$_DL_DIR/child.pid" 2>/dev/null; }
# Column-0 on purpose: forensic-fixbatch-0710b-test.sh T10 anchors `^emit_marker started$` to prove
# the W5G-8 runner token is exported BEFORE the started row (bash is indentation-blind).
emit_marker started
  if [ "$_WR_SPAWNED" -eq 1 ]; then
    _wr_poll
  else
    _run_bounded "$_V_DISPATCH_TIMEOUT_SEC" claude "${ARGS[@]}" < "$PROMPT_TMP" > "$JSON_OUT" 2>"$ERR_OUT"
    RC=$?
  fi
fi

# ── 6. Parse result ───────────────────────────────────────────────────────────
IS_ERROR="" RESULT="" COST="" DURATION="" SUBMODEL="" SUBMODEL_ALL=""
# SINGLE-DOCUMENT RULE (security round 4): `jq -r .result` streams EVERY top-level value in the file,
# so a second JSON document appended to the output would emit two results and the artifact would
# carry both. Exactly one top-level value is the only accepted shape; anything else is an error.
if command -v jq >/dev/null 2>&1 && [ -s "$JSON_OUT" ]; then
  _nd="$(jq -c . "$JSON_OUT" 2>/dev/null | wc -l | tr -d ' ')"
  jq -e . "$JSON_OUT" >/dev/null 2>&1 || _nd="malformed"   # jq streams the first value THEN fails on trailing garbage; require a clean parse too
  if [ "${_nd:-0}" != "1" ]; then
    echo "ERROR (result integrity): the subprocess output holds ${_nd:-0} top-level JSON values (expected exactly 1) — refusing to extract a result from it." >&2
    : > "$JSON_OUT"; [ "$RC" -eq 0 ] && RC=124
  fi
fi
if command -v jq >/dev/null 2>&1 && [ -s "$JSON_OUT" ]; then
  IS_ERROR=$(jq -r '.is_error // empty' "$JSON_OUT" 2>/dev/null)
  RESULT=$(jq -r '.result // empty' "$JSON_OUT" 2>/dev/null)
  COST=$(jq -r '.total_cost_usd // empty' "$JSON_OUT" 2>/dev/null)
  DURATION=$(jq -r '.duration_ms // empty' "$JSON_OUT" 2>/dev/null)
  # W-SUBMODEL-DOMINANT (2026-08-11): report the model that did the REASONING, i.e. the
  # highest-spend entry in .modelUsage — NOT `keys[0]`.
  #
  # `jq keys` sorts ALPHABETICALLY. Every built-in tool that calls a helper model (WebSearch is
  # the reproducible one — verified live 2026-08-11: `claude -p --model sonnet` + one WebSearch
  # yields modelUsage keys ["claude-haiku-4-5-20251001","claude-sonnet-5"]) puts a haiku entry in
  # the map, and "claude-haiku…" sorts BEFORE "claude-sonnet…" / "claude-opus…". So keys[0]
  # reported `submodel=claude-haiku-4-5-20251001` for EVERY search-using dispatch regardless of
  # what actually ran. Measured damage: the 2026-08-11 multi-dimension audit run recorded 5 of 9 dimensions
  # as haiku — precisely the 5 WebSearch-heavy ones — while their per-dispatch cost
  # matched the sonnet dimensions. The audit then reported "37% of score weight ran
  # on haiku" to the operator. Nothing had been substituted; the extractor was lying.
  #
  # costUSD is the right discriminator, not token count: a haiku helper can emit MANY tokens for
  # a fraction of a cent, so max_by(tokens) would reproduce the same false positive at lower
  # frequency. Fall back to tokens only when costUSD is absent from the payload.
  SUBMODEL=$(jq -r '(.modelUsage // {}) | to_entries
    | map(select(.key != null))
    | if length == 0 then empty
      else (max_by((.value.costUSD // -1) as $c
                   | if $c >= 0 then $c
                     else (((.value.inputTokens // 0) + (.value.outputTokens // 0)) / 1e9) end)).key
      end' "$JSON_OUT" 2>/dev/null)
  # Full set, cheapest-first-by-name, so a reviewer can always see the helper models too. Goes to
  # the JSONL ledger only — the DISPATCH| line format is load-bearing for hook consumers that
  # regex `submodel=[^|]*` and is deliberately left byte-compatible.
  SUBMODEL_ALL=$(jq -r '(.modelUsage // {}) | keys | join(",")' "$JSON_OUT" 2>/dev/null)
fi

# F8-3 (SID-leakage hardening, forensic 2026-07-05): a runner/reviewer subprocess mints its OWN,
# entirely distinct session id for its internal tool calls (verified empirically 2026-07-05: the
# JSON `.session_id` field differs from this dispatch's own PROV_SID on every real invocation). If
# that subprocess's own Write/Edit tool calls touch a file that is NOT one of the recognized
# report-artifact name patterns hooks/track-session-writes.sh already skips (e.g.
# v-workflow-verifier legitimately commits a Playwright spec file as part of its normal job), the
# P3-14 anchor in track-session-writes.sh stamps a GAUNTLET_OWED_<child-sid>.md marker for that
# child SID — flagging a dispatched, read-only-by-design runner as though it were an independent
# session that "owes" a gauntlet it structurally can never run (it has no Stop hook of its own once
# this dispatch returns). We now KNOW (from this dispatch's own JSON result) that this specific
# child SID was OURS — a runner we dispatched, not an independent code-changing session — so remove
# any such marker. Never touches a marker for any OTHER SID, and NEVER for the parent/dispatching
# session's own SID (belt-and-suspenders equality guard below), so a genuine orchestrator gauntlet
# obligation is never affected by this cleanup.
CHILD_SID=""
if command -v jq >/dev/null 2>&1 && [ -s "$JSON_OUT" ]; then
  CHILD_SID=$(jq -r '.session_id // empty' "$JSON_OUT" 2>/dev/null)
fi
if [ "$_WR_REATTACH" -eq 1 ]; then
  _wr_el=$(( $(date -u +%s) - DISPATCH_START_EPOCH ))
  case "${DURATION:-}" in ''|*[!0-9]*) : ;; *)
    [ "$DURATION" -le $(( (_wr_el + 60) * 1000 )) ] || echo "WARNING (W-REATTACH plausibility): adopted result reports duration_ms=${DURATION} but only ${_wr_el}s elapsed since the lease's start — the json may not be this dispatch's output. Treat with suspicion." >&2 ;;
  esac
fi
_exempt_subprocess_gauntlet() {  # <child_sid> <parent_sid> <project_root> <prov_dir>
  local _child="${1:-}" _parent="${2:-}" _proj="${3:-}" _provdir="${4:-}"
  [ -n "$_child" ] || return 0
  printf '%s' "$_child" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 0
  local _child_lc _parent_lc
  _child_lc="$(printf '%s' "$_child" | tr '[:upper:]' '[:lower:]')"
  _parent_lc="$(printf '%s' "$_parent" | tr '[:upper:]' '[:lower:]')"
  [ "$_child_lc" != "$_parent_lc" ] || return 0
  local _p
  for _p in "${_proj}/.v/artifacts/GAUNTLET_OWED_${_child}.md" "${_provdir}/GAUNTLET_OWED_${_child}.md"; do
    if [ -n "$_p" ] && [ -f "$_p" ]; then
      rm -f "$_p" 2>/dev/null \
        && echo "NOTE: removed stray GAUNTLET_OWED marker for this dispatch's OWN runner subprocess (SID $_child — a dispatched runner, not an independent session): $_p" >&2
    fi
  done
  return 0
}
_exempt_subprocess_gauntlet "$CHILD_SID" "${PROV_SID:-}" "$PROJ" "$PROV_DIR"

if [ "$RC" -ne 0 ] || [ "$IS_ERROR" = "true" ] || [ -z "$RESULT" ]; then
  # A-1c: on a TIMEOUT specifically (rc 124, _run_bounded's normalized kill code — never on a
  # genuine API/transport error or malformed output), check whether the underlying gate work
  # actually finished before stamping this as a flat failure.
  _OK_LATE=0
  if [ "$RC" -eq 124 ] && _check_ok_late "$DISPATCH_START_EPOCH" "${PROV_SID:-unknown}" "$V_TMP"; then
    _OK_LATE=1
  fi
  if [ "$_OK_LATE" -eq 1 ]; then
    echo "DISPATCH_STATUS=ok_late"
  else
    echo "DISPATCH_STATUS=error"
  fi
  echo "DISPATCH_RC=$RC"
  echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
  # Blocker-2 fix (supervisor transient retry): signal infra-transience via an
  # UNFORGEABLE EXIT CODE (75 = EX_TEMPFAIL), classified ONLY from `claude`'s own
  # TRANSPORT stderr ($ERR_OUT, the CLI's API-error channel) — NEVER from the
  # gate's workload/test output (which travels in the JSON .result on stdout, not
  # here). An exit code is set by THIS helper process, so a workload that prints
  # the literal string "DISPATCH_TRANSIENT=1" on its own stdout cannot forge it
  # (codex MEDIUM-1). The stdout line is kept as human-readable annotation only;
  # the supervisor keys retry on rc 75 / 124, not on log text. So a DETERMINISTIC
  # test failure whose body mentions "503"/"timeout"/"connection reset" is never
  # misclassified as transient. Octet boundary `[^0-9.]` rejects IPs like
  # 10.0.0.503 (codex LOW-1). Terms anchored to Anthropic API / transport shapes.
  _DISPATCH_EXIT=5
  if [ "$_OK_LATE" -eq 0 ] && grep -qiE 'overloaded_error|rate[_ -]?limit|(^|[^0-9.])(429|529|502|503|504)([^0-9]|$)|ECONNRESET|EAI_AGAIN|ETIMEDOUT|connection reset by peer|could not connect|temporarily unavailable|service unavailable|request timed out' "$ERR_OUT" 2>/dev/null; then
    echo "DISPATCH_TRANSIENT=1"
    _DISPATCH_EXIT=75
  fi
  if [ "$_OK_LATE" -eq 1 ]; then
    echo "NOTICE: subprocess was killed at the timeout ceiling, but gate-summary-${PROV_SID:-unknown}.txt shows the underlying gate work completed within this dispatch's window (ok_late). The caller may be able to salvage the result instead of a full re-dispatch." >&2
  else
    echo "ERROR: subprocess dispatch failed (rc=$RC is_error=${IS_ERROR:-?}). Caller must apply its documented fallback." >&2
  fi
  echo "----- subprocess stderr (tail) -----" >&2
  tail -15 "$ERR_OUT" >&2 2>/dev/null || true
  # Forensic 2026-06-14 (#1a): record WHY the dispatch failed, not a flat `error`. Across the
  # 4-session wave every `v-pre-flight-runner` line was `status=error` with no way to tell an
  # infra/transport blip (retry-worthy) from a permanent runner failure. The rc classification
  # above already split them (75=EX_TEMPFAIL from `claude`'s own transport stderr); surface it in
  # the durable provenance so forensics + any future retry/binding logic can distinguish them.
  # A-1c adds a THIRD class: `ok_late` (timeout raced a genuinely-completed gate). Append-only +
  # back-compatible: counters key on the exact string `status=ok` (e.g. pre_flight_dispatches), so
  # `transient`/`ok_late` lines are still correctly treated as non-`ok` everywhere downstream —
  # this only makes the dishonest "flat error" case rarer, it never fabricates a success.
  if [ "${_DISPATCH_EXIT}" -eq 75 ]; then
    emit_marker transient
    trace_event end --status transient --duration-ms "${DURATION:-}" --detail "subprocess dispatch failed (transient transport error)"
  elif [ "$_OK_LATE" -eq 1 ]; then
    emit_marker ok_late
    trace_event end --status ok_late --duration-ms "${DURATION:-}" --detail "subprocess timed out but gate-summary proves the underlying work completed within the dispatch window"
  else
    emit_marker error
    trace_event end --status error --duration-ms "${DURATION:-}" --detail "subprocess dispatch failed"
  fi
  exit "$_DISPATCH_EXIT"
fi

# ── 7. Persist / verify the artifact ──────────────────────────────────────────
# Derive a terminal-line regex from the artifact type. The PRE_FLIGHT / VERIFY_DONE
# validators require the LAST non-blank line to be the verdict line, so any trailing
# model chatter ("Let me know if you need anything else!") fails the Stop hook. In
# capture mode we truncate everything after the verdict line. Caller-free (keyed off
# the artifact basename) so the orchestrator cannot forget to pass it.
# Strict regex (prefix + PASS|FAIL), NOT a bare prefix: a finding body line that
# merely mentions "Overall Verdict:" in prose must NOT trigger early truncation
# (codex cycle-2 #2). Only the real terminal verdict line matches.
case "$(basename "$ARTIFACT")" in
  PRE_FLIGHT_REPORT_*)  TERMINAL_RE='^Overall Status: *(PASS|FAIL)' ;;
  VERIFY_DONE_REPORT_*) TERMINAL_RE='^Overall Verdict: *(PASS|FAIL)' ;;
  *)                    TERMINAL_RE='' ;;
esac

if [ "$MODE" = "capture" ]; then
  # Sanitize: (1) slice from the first `Model:` line (drop any preamble); (2) strip
  # fence-delimiter lines (``` / ```lang) the model may have wrapped around it;
  # (3) truncate after the terminal verdict line (drop trailing chatter).
  printf '%s\n' "$RESULT" \
    | awk 'BEGIN{f=0} /^Model:/{f=1} f{print}' \
    | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' \
    | awk -v re="$TERMINAL_RE" '{print} (re!="" && $0 ~ re){exit}' \
    > "$ARTIFACT"
  # If no `Model:` line was found, awk emitted nothing — fall back to raw result.
  if [ ! -s "$ARTIFACT" ]; then
    printf '%s\n' "$RESULT" \
      | sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d' \
      | awk -v re="$TERMINAL_RE" '{print} (re!="" && $0 ~ re){exit}' \
      > "$ARTIFACT"
  fi
else
  # self-write: the agent owns writing the artifact. If it did NOT, we must NOT
  # fabricate the gate artifact from its chat text (codex review #1, CRITICAL):
  # the result could contain `Model:` + `verdict: pass` and would then falsely
  # satisfy the Stop-hook gate as an independent QA pass. Instead, fail loud
  # (exit 6) and stash the result in a sidecar for debugging. The caller then
  # applies its DOCUMENTED fallback (manual degraded/escalated artifact — an
  # explicit non-pass), never a silent green.
  if [ ! -s "$ARTIFACT" ]; then
    SIDECAR="$V_TMP/dispatch-unwritten-$(basename "$ARTIFACT").txt"
    printf '%s\n' "$RESULT" > "$SIDECAR" 2>/dev/null || true
    echo "DISPATCH_STATUS=no_artifact"
    echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
    echo "ERROR: self-write agent did NOT write $ARTIFACT. Refusing to fabricate it from chat text (would risk a false gate pass). Result stashed at: $SIDECAR" >&2
    echo "ERROR: caller must apply the documented fallback (manual degraded/escalated artifact), NOT treat this as a pass." >&2
    emit_marker no_artifact
    trace_event end --status no_artifact --duration-ms "${DURATION:-}" --detail "self-write artifact missing"
    exit 6
  fi
fi

if [ ! -s "$ARTIFACT" ]; then
  echo "DISPATCH_STATUS=no_artifact"
  echo "ERROR: artifact still missing/empty after dispatch: $ARTIFACT" >&2
  emit_marker no_artifact
  trace_event end --status no_artifact --duration-ms "${DURATION:-}" --detail "artifact missing after dispatch"
  exit 6
fi

# ── 7c. F8-2: post-dispatch SID-filename-leak scan (defense-in-depth) ────────────────────────
# Independently reconfirm, AFTER the subprocess has run and could have written ANYTHING to disk,
# that no SIBLING artifact of the same TYPE — freshly created/modified during THIS dispatch's own
# window — carries a DIFFERENT session id in its filename than the one this dispatch is authorized
# to write for (the artifact's own accepted SID: $_ART_SID when the 17c ACTING_AS cross-session
# override applies, else $PROV_SID). A stray file like `PRE_FLIGHT_REPORT_<wrong-sid>.md` left
# behind by a self-write agent that mis-transcribed its OWN forked sub-session id instead of the
# literal $ARTIFACT path it was told to use would otherwise sit undetected — invisible to the
# emptiness check above (which only verifies $ARTIFACT itself), yet fully capable of confusing a
# later glob-based consumer that isn't strictly SID-scoped. Best-effort and scoped tightly (same
# type prefix + touched within the dispatch window only) so an unrelated, older artifact for a
# genuinely different session sitting in the same directory is never flagged.
_artifact_type_prefix() {  # <basename> -> the portion before a trailing _<sid>.<ext>
  printf '%s' "$1" | sed -E 's/_[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?\.[A-Za-z0-9]+$//'
}
_extract_sid_from_name() {  # <basename> -> sid (full UUID preferred, else 8-hex) or empty
  local _s
  _s=$(printf '%s' "$1" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  if [ -z "$_s" ]; then
    _s=$(printf '%s' "$1" | grep -oiE '_[0-9a-f]{8}\.' | head -1 | tr -d '_.')
  fi
  printf '%s' "$_s"
}
_sid_is_fleet_sibling() {  # <sid-lc> <artifact_dir> -> 0 when the sid provably belongs to a REAL concurrent session
  # FLEET-AWARE sid-leak scoping (2026-07-06 forensics): under -jN parallel /v sessions sharing one
  # <repo>/.v/artifacts dir, a CONCURRENT SIBLING legitimately writes its own same-type artifact during this
  # dispatch's window — that is NOT a leak. Live false-positive: one session's pre-flight dispatches were
  # failed TWICE (status=sid_leak) because a sibling session wrote its own PRE_FLIGHT_REPORT in-window;
  # the rejected good dispatches fed a 63-min full-gate retry storm and the session died at the runner ceiling.
  # A mismatched SID is a real session's — not a mis-transcribed forked sub-session id (the class F8-2 exists
  # for) — when it has its OWN dispatch-provenance ledger in the same dir, or a registered worktree whose
  # session lock names it. Fail-open stance matches the parent scan (diagnostic net, never primary truth).
  local _sib_sid="$1" _sib_dir="$2" _wt_line _lock _tok
  [ -n "$_sib_sid" ] || return 1
  if [ -f "$_sib_dir/DISPATCH_PROVENANCE_${_sib_sid}.log" ]; then return 0; fi
  while IFS= read -r _wt_line; do
    case "$_wt_line" in "worktree "*) _lock="${_wt_line#worktree }/.claude-session-lock" ;; *) continue ;; esac
    [ -f "$_lock" ] || continue
    _tok="$(head -1 "$_lock" 2>/dev/null | awk '{print tolower($1)}')"
    [ -n "$_tok" ] || continue
    if [ "$_tok" = "$_sib_sid" ] || [ "$(printf '%.8s' "$_tok")" = "$(printf '%.8s' "$_sib_sid")" ]; then return 0; fi
  done < <(git -C "$_sib_dir" worktree list --porcelain 2>/dev/null)
  return 1
}
_check_sid_leak() {  # <artifact_path> <accepted_sid> <dispatch_start_epoch>
  # Prints (one per line) any sibling file of the same TYPE PREFIX, touched during the dispatch
  # window, whose filename embeds a DIFFERENT session id than <accepted_sid>. Prints nothing when
  # none are found. Fail-open on any lookup error (a diagnostic net, never the primary source of
  # truth for dispatch success/failure).
  local _art="$1" _accepted="$2" _start="$3"
  local _dir _base _prefix _accepted_lc
  _dir="$(dirname "$_art" 2>/dev/null)"; _base="$(basename "$_art" 2>/dev/null)"
  [ -n "$_dir" ] && [ -d "$_dir" ] && [ -n "$_base" ] || return 0
  _prefix="$(_artifact_type_prefix "$_base")"
  [ -n "$_prefix" ] || return 0
  _accepted_lc="$(printf '%s' "$_accepted" | tr '[:upper:]' '[:lower:]')"
  local _f _fbase _fsid _fsid_lc _fmtime
  for _f in "$_dir/${_prefix}"_*; do
    [ -f "$_f" ] || continue
    _fbase="$(basename "$_f")"
    [ "$_fbase" = "$_base" ] && continue
    _fsid="$(_extract_sid_from_name "$_fbase")"
    [ -n "$_fsid" ] || continue
    _fsid_lc="$(printf '%s' "$_fsid" | tr '[:upper:]' '[:lower:]')"
    [ "$_fsid_lc" = "$_accepted_lc" ] && continue
    _fmtime="$(stat -c '%Y' "$_f" 2>/dev/null || stat -f '%m' "$_f" 2>/dev/null || echo 0)"
    [ "${_fmtime:-0}" -ge "${_start:-0}" ] 2>/dev/null || continue
    # a real concurrent sibling's own artifact is not a leak (see _sid_is_fleet_sibling header)
    _sid_is_fleet_sibling "$_fsid_lc" "$_dir" && continue
    printf '%s\n' "$_f"
  done
  return 0
}
_ACCEPTED_SID="${_ART_SID:-$PROV_SID}"
_SID_LEAK="$(_check_sid_leak "$ARTIFACT" "$_ACCEPTED_SID" "$DISPATCH_START_EPOCH")"
if [ -n "$_SID_LEAK" ]; then
  _SID_LEAK_FIRST="$(printf '%s\n' "$_SID_LEAK" | head -1)"
  _rej="$V_TMP/rejected-sidleak-$(basename "$ARTIFACT").$(date +%s).md"
  mv -f "$ARTIFACT" "$_rej" 2>/dev/null || cp -p "$ARTIFACT" "$_rej" 2>/dev/null
  echo "DISPATCH_STATUS=sid_leak"
  echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
  echo "SID_LEAK_FILE=$_SID_LEAK_FIRST"
  echo "DISPATCH_REJECTED_ARTIFACT=$_rej"
  echo "ERROR: subprocess dispatch left a SIBLING artifact with a MISMATCHED session id in its filename ($_SID_LEAK_FIRST) — this indicates the subprocess wrote (or attempted to write) under the WRONG SID (e.g. its own forked sub-session's SID instead of the parent's). The intended artifact was preserved at $_rej for inspection; treating this dispatch as FAILED. Caller must apply its documented fallback." >&2
  emit_marker sid_leak
  trace_event end --status sid_leak --duration-ms "${DURATION:-}" --detail "sibling artifact SID mismatch: $_SID_LEAK_FIRST"
  exit 9
fi

# ── 7b. H4-3 wrong-tree HARD REFUSAL (PLAN_2026-07-02_orchestrator-hardening-4) ──────────────
# The P0-2 worktree-identity contract (dispatch-v-verify-done.md) has the runner disclose
# `WrongTree: <branch>` when the tree it landed in does not belong to this SID. That disclosure
# was WARN-only: the report still got written and one session (fleet 2026-07-02) consumed TWO
# consecutive factually-false VERIFY_DONE reports, caught only by the orchestrator fact-checking
# them — and the false reports were then overwritten (evidence lost). Per anti-recurrence rules
# the warning IS the defect: a wrong-tree gate artifact must never be accepted as this session's.
# Refuse loud: preserve the rejected artifact under .v/tmp (never overwrite-in-place), emit a
# distinct status + the offending branch, and exit non-zero so the orchestrator re-dispatches
# with an explicit WORKTREE_PATH.
if grep -qiE '^[[:space:]>*_-]*WrongTree:' "$ARTIFACT" 2>/dev/null; then
  _wt_branch="$(grep -iE '^[[:space:]>*_-]*WrongTree:' "$ARTIFACT" 2>/dev/null | head -1 | sed 's/.*[Ww]rong[Tt]ree:[[:space:]]*//')"
  _rej="$V_TMP/rejected-$(basename "$ARTIFACT").$(date +%s).md"
  mv -f "$ARTIFACT" "$_rej" 2>/dev/null || { cp -p "$ARTIFACT" "$_rej" 2>/dev/null; : > "$ARTIFACT"; }
  echo "DISPATCH_STATUS=wrong_tree"
  echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
  echo "WRONG_TREE=${_wt_branch:-unknown}"
  echo "DISPATCH_REJECTED_ARTIFACT=$_rej"
  echo "ERROR: runner reported it landed in the WRONG worktree ('${_wt_branch:-unknown}' does not contain this SID). The artifact was REJECTED (preserved at $_rej) — it verifies a DIFFERENT session's diff. Re-dispatch with an explicit WORKTREE_PATH for this SID." >&2
  emit_marker wrong_tree
  trace_event end --status wrong_tree --duration-ms "${DURATION:-}" --detail "wrong-tree artifact rejected: ${_wt_branch:-unknown}"
  exit 4
fi

# ── 7c. W5G-10 no-scope HARD REFUSAL (forensic 2026-07-10 #2, one project) ─────────────
# The verify-done runner emits `NoScope: <sid>` when it has no attributable scope (non-isolated
# tree, writes-log AND commit-witness both empty) instead of grading unattributable shared-tree
# WIP — one session's final VERIFY_DONE "verified" a sibling's uncommitted Dashboard.tsx and PASSed
# over none of the session's real diff. Same contract as the WrongTree refusal above: reject
# loud, preserve the artifact, exit non-zero so the orchestrator re-dispatches with an explicit
# POSTMERGE_REVERIFY range or WORKTREE_PATH. Without this hard-reject, a haiku runner that prints
# the refusal but then keeps going could still leave a normal-shaped vacuous-PASS report.
if grep -qiE '^[[:space:]>*_-]*NoScope:' "$ARTIFACT" 2>/dev/null; then
  _ns_sid="$(grep -iE '^[[:space:]>*_-]*NoScope:' "$ARTIFACT" 2>/dev/null | head -1 | sed 's/.*[Nn]o[Ss]cope:[[:space:]]*//')"
  _rej="$V_TMP/rejected-noscope-$(basename "$ARTIFACT").$(date +%s).md"
  mv -f "$ARTIFACT" "$_rej" 2>/dev/null || { cp -p "$ARTIFACT" "$_rej" 2>/dev/null; : > "$ARTIFACT"; }
  echo "DISPATCH_STATUS=no_scope"
  echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
  echo "NO_SCOPE_SID=${_ns_sid:-unknown}"
  echo "DISPATCH_REJECTED_ARTIFACT=$_rej"
  echo "ERROR: verify-done runner REFUSED — no attributable scope (non-isolated tree, writes-log + commit-witness both empty for '${_ns_sid:-unknown}'). The artifact was REJECTED (preserved at $_rej) to prevent a vacuous-PASS over foreign/sibling WIP. Re-dispatch with POSTMERGE_REVERIFY=1 BASE_SHA=<pre-merge> END_SHA=<post-merge>, or from this SID's worktree (W5G-10)." >&2
  emit_marker no_scope
  trace_event end --status no_scope --duration-ms "${DURATION:-}" --detail "no-scope refusal: ${_ns_sid:-unknown}"
  exit 4
fi

# === E3-SANITY (efficiency, 2026-07-05): cheap MECHANICAL post-dispatch sanity gate ===
# A dispatched runner's own narration/artifact content is exactly what a confused (or adversarial)
# runner can get wrong or fabricate — checking it with ANOTHER LLM call would defeat the whole point
# of a cheap gate. These checks are pure grep/count-compare, run immediately after the artifact is
# accepted (step 7) and BEFORE the orchestrator is told to trust it (step 8):
#   (a) filename-SID vs the requested SID — ALREADY enforced above (§17c, hard `exit 7` on a silent
#       mismatch); not re-implemented here.
#   (b) reported `Mode:` vs an OPTIONAL caller-declared expected mode (V_DISPATCH_EXPECT_MODE).
#       Advisory only: the F9-2 contract (dispatch-v-pre-flight.md:196) already has runners
#       self-disclose "(requested: X)" when v-run-gates.sh auto-up/downgrades mode — a LEGITIMATE
#       divergence. Hard-blocking every mismatch would false-block that documented path; this only
#       flags a SILENT divergence (no disclosed "(requested:" parenthetical) for the orchestrator.
#   (c) claimed "Changed: N" (VERIFY_DONE_REPORT's w53 field) vs a cheap `git status --porcelain`
#       count — the flagship check (motivating example: a runner claiming "0 files changed, all
#       tests pass" while dozens of files are actually dirty).
# Both (b) and (c) default to WARN (a `DISPATCH_SANITY_WARN=` line the orchestrator must read before
# trusting the artifact), NOT a hard block — this is a brand-new heuristic with no production
# false-positive history, and this fleet legitimately runs multiple concurrent /v sessions against
# shared checkouts (a sibling session's uncommitted work can inflate `git status` independent of
# fabrication). Set V_DISPATCH_SANITY_STRICT=1 to escalate an unresolved (c) mismatch to a hard
# reject (mirrors the wrong_tree precedent: artifact preserved under .v/tmp, non-zero exit) once a
# caller has observed an acceptable false-positive rate for its own dispatch shape.
_sanity_warn() {  # <reason> — best-effort; never raises (a warn must never crash the dispatcher).
  echo "DISPATCH_SANITY_WARN=$1"
  echo "WARN (E3 sanity gate): $1" >&2
}

if [ -n "${V_DISPATCH_EXPECT_MODE:-}" ]; then
  _san_mode_line="$(grep -iE '^Mode:[[:space:]]*' "$ARTIFACT" 2>/dev/null | head -1)"
  if [ -n "$_san_mode_line" ] \
     && ! printf '%s' "$_san_mode_line" | grep -qiE "^Mode:[[:space:]]*${V_DISPATCH_EXPECT_MODE}([[:space:](]|\$)" \
     && ! printf '%s' "$_san_mode_line" | grep -qi '(requested:'; then
    _sanity_warn "reported '${_san_mode_line}' does not match the requested mode '${V_DISPATCH_EXPECT_MODE}' and discloses no divergence — possible scope mismatch"
  fi
fi

_san_claimed_changed="$(grep -iE '^Changed:[[:space:]]*[0-9]+' "$ARTIFACT" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)"
if [ -n "${_san_claimed_changed:-}" ] && [ "$_san_claimed_changed" -eq 0 ] 2>/dev/null; then
  _san_repo="${PROV_MAIN_ROOT:-$(git -C "$ART_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"
  if [ -n "$_san_repo" ] && [ -d "$_san_repo" ]; then
    _san_actual_dirty=$(git -C "$_san_repo" status --porcelain 2>/dev/null | grep -c . || echo 0)
    if [ "${_san_actual_dirty:-0}" -ge 10 ] 2>/dev/null; then
      _san_msg="artifact claims 'Changed: 0' but \`git status --porcelain\` shows ${_san_actual_dirty} dirty entries in ${_san_repo} — implausible for a session that changed nothing (a sibling session's concurrent uncommitted work can also explain this; verify before trusting the artifact)"
      if [ "${V_DISPATCH_SANITY_STRICT:-0}" = "1" ]; then
        _rej="$V_TMP/rejected-$(basename "$ARTIFACT").$(date +%s).md"
        mv -f "$ARTIFACT" "$_rej" 2>/dev/null || { cp -p "$ARTIFACT" "$_rej" 2>/dev/null; : > "$ARTIFACT"; }
        echo "DISPATCH_STATUS=implausible_claim"
        echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
        echo "DISPATCH_REJECTED_ARTIFACT=$_rej"
        echo "ERROR (E3 sanity gate, STRICT): ${_san_msg}. Artifact REJECTED (preserved at $_rej). Re-dispatch or investigate." >&2
        emit_marker implausible_claim
        trace_event end --status implausible_claim --duration-ms "${DURATION:-}" --detail "Changed:0 vs ${_san_actual_dirty} dirty entries"
        exit 8
      fi
      _sanity_warn "$_san_msg"
    fi
  fi
fi
# === end E3-SANITY ===

# ── 8. Provenance (consumed by the orchestrator for AGENT_REVIEW) ─────────────
echo "DISPATCH_STATUS=ok"
echo "DISPATCH_MODE=subprocess"          # NOT orchestrator_inline — real independence
echo "DISPATCH_AGENT=${AGENT:-<model:$MODEL>}"
echo "DISPATCH_SUBMODEL=${SUBMODEL:-${AGENT_PINNED_MODEL:-unknown}}"
echo "DISPATCH_PINNED_MODEL=${AGENT_PINNED_MODEL:-}"
echo "DISPATCH_COST_USD=${COST:-unknown}"
echo "DISPATCH_DURATION_MS=${DURATION:-unknown}"
echo "DISPATCH_ARTIFACT=$ARTIFACT"
echo "DISPATCH_PROVENANCE_LOG=$PROV_LOG"
emit_marker ok
trace_event end --status ok --duration-ms "${DURATION:-}" --detail "subprocess dispatch completed"
echo "----RESULT----"
printf '%s\n' "$RESULT"
exit 0
