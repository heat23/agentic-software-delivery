#!/usr/bin/env bash
# fork-payload-guard.sh — ORCHFIX-D (forensics 2026-07-02): detect a /v fork
# that LOST its task payload and stop the parent from "proceeding inline".
#
# WHY: two parallel sessions invoked Skill(v) seconds apart; one fork received its full args,
# the other's single short turn saw "only system-reminder context — I don't see an actual
# task". The parent then declared the routing mandate satisfied and implemented INLINE on the
# shared main tree: no worktree, no bootstrap, no in-flow gauntlet — repeated Stop-block cycles, most
# of the session spend on retrofit remediation, a P12 shared-index incident, and a corrupted session
# log (no head-baseline → commits_added: 0). A no-payload fork response is a FAILED DISPATCH,
# not compliance. This guard makes that mechanical:
#   1. writes a durable V_FORK_NO_PAYLOAD_<sid>.md marker (forensics-visible even if ignored);
#   2. injects additionalContext instructing the model to RE-INVOKE /v (task at the TOP of args),
#      and to never treat the no-op fork as having satisfied the /v-first mandate.
#
# SCOPE: PostToolUse, matcher "Skill" (DUAL registration: settings.json AND settings.headless.json
# — the dead-in-one-context trap). Fires only when tool_input.skill == "v"-family, tool_input.args
# is substantive (the parent DID pass a task), and the fork's response carries a no-task signature.
# Fail-open on every uncertainty: PostToolUse must never block or error.
#
# Bite: hooks/fork-payload-guard-test.sh.
set -uo pipefail
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL" = "Skill" ] || exit 0

SKILL="$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null || true)"
case "$SKILL" in v|v-build|v-new-feature|v-polish) ;; *) exit 0 ;; esac

ARGS="$(printf '%s' "$INPUT" | jq -r '.tool_input.args // empty' 2>/dev/null || true)"
# A payload was genuinely passed — a bare "/v" with no args legitimately asks for a task.
[ "${#ARGS}" -ge 40 ] || exit 0

# Stringify the whole tool_response defensively (string / object / content-array shapes all seen).
RESP="$(printf '%s' "$INPUT" | jq -r '.tool_response | tostring' 2>/dev/null || true)"
[ -n "$RESP" ] || exit 0

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-unknown}"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
ROOT="$(git -C "${CWD:-.}" rev-parse --show-toplevel 2>/dev/null || printf '%s' "${CLAUDE_PROJECT_DIR:-$PWD}")"

# LEAK-GUARD (2026-08-03 class sweep, 2nd pass — this shape was missed by the first grep):
# a non-repo cwd falls through to bare pwd/"."/$PWD. ~/.claude has no git repo, so from a
# skill/hook SOURCE subdir this nests .v/ inside the source tree. Config dir ITSELF is a
# legitimate root; snap only a strict descendant that is not a git work tree.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${ROOT:-}" ] && [ -n "$_lg_cfg" ] && [ "${ROOT}" != "$_lg_cfg" ]; then
  case "${ROOT}" in
    "$_lg_cfg"/*) git -C "${ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || ROOT="$_lg_cfg" ;;
  esac
fi


# No-task signatures observed in production (verbatim: "I don't see an actual task or
# question in your message — it only contains system-reminder context") + close variants.
if ! printf '%s' "$RESP" | grep -qiE "do(n'?| no)t see an? (actual )?task|no (actual )?task or question|only contains system-reminder|didn'?t receive (the |a )?task|no task payload"; then
  # ORCHFIX-H5 (forensics 2026-07-02): the fork completed its task in the SID
  # worktree (staged, uncommitted), but its return narration read as "waiting on a background
  # run"; the parent concluded the fork did nothing and RE-IMPLEMENTED from scratch in the shared
  # main root — a long stretch of duplicate work and a lengthy remediation staircase. Fork-work triage was
  # a memory-only lesson (no mechanical surface). Surface the worktree state in ONE line whenever
  # a /v fork returns and a dirty/ahead SID worktree exists.
  if [ "$SID" != "unknown" ] && [ -n "$ROOT" ]; then
    _repo_base="$(basename "$ROOT")"
    for _wt in "$HOME/.claude/worktrees/${_repo_base}"/*"${SID%%-*}"* "$HOME/.claude/worktrees/${_repo_base}"/*/*"${SID%%-*}"*; do
      [ -d "$_wt" ] && [ -e "$_wt/.git" ] || continue
      _wt_dirty_n="$(git -C "$_wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      _wt_branch="$(git -C "$_wt" branch --show-current 2>/dev/null || true)"
      _wt_ahead=0
      [ -n "$_wt_branch" ] && _wt_ahead="$(git -C "$ROOT" rev-list --count "${CLAUDE_MAIN_BRANCH:-main}..${_wt_branch}" 2>/dev/null | tr -d ' ' || echo 0)"
      if [ "${_wt_dirty_n:-0}" -gt 0 ] || [ "${_wt_ahead:-0}" -gt 0 ]; then
        jq -n --arg ctx "FORK-WORK (fork-payload-guard): the /v fork's worktree EXISTS at ${_wt} (branch ${_wt_branch:-?}, ${_wt_dirty_n} dirty file(s), ${_wt_ahead} unmerged commit(s)). INSPECT IT (git -C '${_wt}' status && git -C '${_wt}' diff) before writing ANY source file in the main root — the fork may have completed the task there. A production session once duplicated a long stretch of its own fork's finished work by skipping this check." \
          '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
        exit 0
      fi
    done
  fi
  exit 0
fi

if [ -n "$ROOT" ] && [ -d "$ROOT" ]; then
  mkdir -p "$ROOT/.v/artifacts" 2>/dev/null || true
  {
    printf '# V_FORK_NO_PAYLOAD — %s\n\n' "$SID"
    printf 'A Skill(v) fork returned a NO-TASK response although the parent passed %s chars of args.\n' "${#ARGS}"
    printf 'This is the fork-args delivery-loss class (concurrent Skill forks; observed 2026-07-02).\n'
    printf 'The dispatch FAILED — it does not satisfy the /v-first mandate. Re-invoke /v.\n\n'
    printf 'ts: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'args_head: %s\n' "$(printf '%s' "$ARGS" | head -c 200 | tr '\n' ' ')"
  } > "$ROOT/.v/artifacts/V_FORK_NO_PAYLOAD_${SID}.md" 2>/dev/null || true
fi

jq -n --arg ctx "F-PAYLOAD (fork-payload-guard): the /v fork returned WITHOUT receiving your args payload (known fork-args delivery loss under concurrent Skill invocations). This dispatch FAILED — it does NOT satisfy the /v-first mandate, and you must NOT proceed to implement inline. Re-invoke the Skill tool with skill='v' and the FULL task as args (put the task text at the very top). If a second attempt also returns no-task, embed the task in a file, pass its path in args, and note the harness bug in your final report. A durable V_FORK_NO_PAYLOAD marker was written for forensics." \
  '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":$ctx}}'
exit 0
