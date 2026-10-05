#!/usr/bin/env bash
# block-v-polling.sh
# Event: PreToolUse / Bash | Monitor | mcp__workspace__bash | BashOutput
# Version: 1.3.0  (W28 → W32 → W41 → W41 review-fixes — tool-class generalisation)
#
# DENIES polling-style commands that target v orchestrator artifacts or test
# runners, regardless of which shell-capable tool is used. Both Bash and
# Cowork's Monitor tool expose tool_input.command as a shell command; the
# same regex pipeline applies.
#
# Production motivation:
#   - W28: orchestrator wrote `until tail -1 .../gate-summary | grep -q DONE_AT; do sleep 5; done`
#   - W32: `while ps aux | grep pest; do tail -1 .../tasks/*.output; sleep 20; done`
#   - W41: Cowork Monitor invocations such as
#       Monitor(description="Watch for gate-summary to be written",
#               command="until grep -q DONE_AT .../gate-summary-*.txt; do sleep 3; done")
#     bypassed earlier hook because matcher was "Bash" only.
#   - W41 review-fixes: extended tool list to anticipate the next bypass
#     (mcp__workspace__bash, BashOutput); tightened gate-* and runner regexes
#     to avoid false positives on benign command lines.
#
# Each per-SID path is novel, triggering Cowork permission prompts.
# Prose rules cannot enforce; this hook does.

set -uo pipefail

if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi
source "$HOOKS_LIB_DIR/require-jq.sh"

# W41 review-fix #7: when jq is missing, emit "ask" rather than silent allow.
# A safety hook that fail-opens defeats its purpose.
if ! command -v jq >/dev/null 2>&1; then
  # echo is a bash builtin — works even with empty PATH, unlike cat-heredoc.
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"block-v-polling.sh: jq not found; cannot validate this tool call. Install jq and retry."}}'
  exit 0
fi

INPUT=$(cat 2>/dev/null)
# W41 review-fix #7: degrade gracefully on malformed JSON / empty stdin
# rather than crashing under set -e (which Claude Code may treat as allow).
if [ -z "$INPUT" ]; then
  exit 0
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# W41 review-fix #1: explicit allowlist of shell-capable tools. Adding
# mcp__workspace__bash (sandboxed shell available in Cowork) and BashOutput
# (legitimate but the orchestrator might write tail-equivalents through it
# in the future). Keep the list narrow — adding non-shell tools here would
# pointlessly run the regex on Read/Write/Edit payloads.
case "$TOOL_NAME" in
  Bash|Monitor|mcp__workspace__bash|BashOutput) ;;
  *) exit 0 ;;
esac

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

# W41 review-fix #6: read multiple description-equivalent fields so a Cowork
# rename of "description" doesn't silently degrade detection. Defensive: any
# of these fields, if present, is concatenated onto CMD before regex match.
if [[ "$TOOL_NAME" == "Monitor" ]]; then
  EXTRA=$(echo "$INPUT" | jq -r '[.tool_input.description, .tool_input.intent, .tool_input.summary, .tool_input.reason] | map(select(. != null)) | join("\n")' 2>/dev/null)
  if [[ -n "$EXTRA" ]]; then
    CMD="$EXTRA"$'\n'"$CMD"
  fi
fi

[[ -z "$CMD" ]] && exit 0

# ── W-perf9: background-and-strand guard ─────────────────────────────────
# A gauntlet GATE (pre-flight runner / codex adversarial review / v-dispatch-subagent /
# v-supervise-children / v-run-gates)
# launched with the Bash tool's run_in_background:true hands control straight back to the model,
# which then "waits for the completion notification" and STRANDS the gauntlet. A production
# session dispatched pre-flight + codex exactly this way, went passive across several turns, and
# NEVER ran verify-done / QA / merge-back — the implemented fix never merged. This is NOT a poll
# loop (so the Step-2 logic below misses it) and v-dispatch-subagent / codex-exec are not
# test-runners (so the Step-1 artifact regex misses them too). Deny here and steer to the BLOCKING
# `& … & wait` single-Bash pattern. No legitimate parent dispatch uses run_in_background:true — the
# prescribed forms are run_in_background:false (single gate) or one blocking Bash call that
# backgrounds each subprocess with `&` and ends with `wait` (concurrent Step 3.4/3.5+4/5).
# Cover every background-capable shell tool, not just Bash (review SREV-004: mcp__workspace__bash
# could otherwise carry the same run_in_background dispatch and slip past).
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__workspace__bash" ]; then
  RUN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background // empty' 2>/dev/null)
  # F-11 (forensic 2026-07-04): the pattern caught bare `codex exec` but NOT the canonical
  # `codex-review.sh` wrapper nor the `codex-adversarial-reviewer` agent form — so a backgrounded
  # codex review via the wrapper slipped the guard and stranded the gauntlet (two production sessions:
  # W-perf9 fired on QA but not on the codex dispatch launched the same way minutes earlier). Widen
  # to cover both. Only ever fires when run_in_background:true, so widening can only catch MORE
  # strand-risk — a legitimate (blocking) codex review is never touched.
  _V_RE_GATE_DISPATCH='v-dispatch-subagent|v-supervise-children|v-pre-flight-runner|dispatch-v-pre-flight|v-run-gates|codex-review|codex-adversarial|(^|[[:space:];&|()`])codex[[:space:]]+exec'
  # truthy = JSON boolean true (jq -r → "true") OR integer 1 (→ "1") OR string "true" (review SREV-001).
  if { [ "$RUN_BG" = "true" ] || [ "$RUN_BG" = "1" ]; } && echo "$CMD" | grep -qE "$_V_RE_GATE_DISPATCH"; then
    BG_MSG="W-perf9 BLOCKED: a /v gauntlet gate (pre-flight runner / codex review / v-dispatch-subagent / supervisor) was launched with the Bash tool's run_in_background:true.\n\nThat hands control back to you, and waiting for the completion notification STRANDS the gauntlet -- a production session dispatched pre-flight + codex this way, went passive across several turns, and NEVER ran verify-done / QA / merge-back. The fix was implemented but never merged.\n\nRun the gates with a BLOCKING wait instead:\n  - CONCURRENT: ONE Bash call with run_in_background FALSE invoking references/v-supervise-children.sh. Spec format (W5G/L-1 — an earlier session burned 3 attempts guessing it): required --summary <path>, then each child as ONE argument 'name::timeout_secs::artifact_path::cmd_file' where cmd_file is an executable file containing the dispatch command. Example:\n      bash ~/.claude/skills/v/references/v-supervise-children.sh --summary \"\$VTMP/sup.txt\" --child \"pre-flight::900::\$PROJ/PRE_FLIGHT_REPORT_\$SID.md::\$VTMP/cmd-pf.sh\"\n  - SINGLE gate: run it with run_in_background:false (omit the flag).\n\nRe-issue this command WITHOUT run_in_background:true."
    echo "[block-v-polling] DENIED: gauntlet gate dispatched with run_in_background:true (strands the gauntlet)" >&2
    echo "[block-v-polling] command (truncated): ${CMD:0:200}" >&2
    jq -n --arg reason "$BG_MSG" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
  fi
fi

# ── W-perf9c (2026-09-01, cohort forensic): FOREGROUND gate dispatch with NO / SHORT Bash timeout ──
# A direct `v-dispatch-subagent.sh --agent <runner>` call runs the whole `claude -p` gate in the
# foreground, so the Bash tool's timeout is the gate's hard ceiling. The tool default is 120 s; a
# pre-flight runner alone needs 3-9 min and a QA reviewer 3-10 min. Cohort 2026-09-01 (36 sessions):
# 4 gate dispatches were launched with NO timeout and killed at exactly 2 m ("Command timed out after
# 2m 0s"), each one re-dispatched from scratch (pre-flight, verify-done,
# codex, +1) — and the dispatcher's own internal `timeout 900` never gets a say because the
# tool kills the wrapper first. CLAUDE.md already says gate runs MUST pass `timeout: 600000`; this
# makes the omission mechanical instead of advisory. Floor is 300 000 ms (5 min): every legitimate
# dispatch observed in the cohort passed 300000-600000, so nothing in current practice is denied;
# only the "forgot the parameter" shape is. Scope is deliberately narrow: ONLY a direct
# `v-dispatch-subagent.sh … --agent …` invocation (the `[^|;&]*` gap forbids a pipe/`;`/`&` between
# the script and `--agent`, so `grep/sed <script> | grep -- --agent` reads of the file never match),
# never `--detach` (returns immediately by design), never `--print-resolved-model` (the dispatcher's
# only info-only flag — it exits at its arg parser before `claude -p`; review PANEL-SECURITY-001 caught
# a fictional `--print-model|--help` exemption here that matched no real flag), never the
# supervisor (v-supervise-children owns its children's budgets). Denying is cheap — the model
# re-issues the same call with the parameter — while a 2-minute kill throws away the gate AND
# re-dispatches it. Bite: hooks/orch-r2-bgyield-test.sh (W-perf9c cases).
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__workspace__bash" ]; then
  # Normalize first (review PANEL-CORRECTNESS 2026-09-01): backslash-continuation lines are ONE
  # command (the emit-prompt templates write the dispatch that way), a bare newline is a command
  # separator, tabs are spaces — grep is line-based, so without this a continuation-style dispatch
  # never matched. Then take only the dispatcher's OWN argument segment (up to the next |;&) so the
  # exemption test cannot be satisfied by a decoy `--detach` elsewhere in the command, and accept
  # the agent name bare OR shell-quoted (`--agent "v-qa-reviewer"` is ordinary shell).
  # awk, not a sed N-loop: BSD sed's N on the LAST line exits without printing, which turned every
  # single-line command into an empty string (caught by the harness before shipping).
  _C1="$(printf '%s\n' "$CMD" | tr '\t' ' ' | awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else printf "%s;", $0 }')"
  _DSEG="$(printf '%s' "$_C1" | grep -oE 'v-dispatch-subagent\.sh[^|;&]*[[:space:]]--agent[[:space:]]+["'"'"']?[A-Za-z0-9_-]+[^|;&]*' | head -1)"
  if [ -n "$_DSEG" ] \
     && ! printf '%s' "$_DSEG" | grep -qE -- '(^|[[:space:]])--(detach|print-resolved-model)([[:space:]]|$)' \
     && ! printf '%s' "$_C1" | grep -qE '(^|[[:space:];&|(]|bash[[:space:]]+|sh[[:space:]]+)[^[:space:];&|]*v-supervise-children\.sh'; then
    _TO_MS=$(echo "$INPUT" | jq -r '.tool_input.timeout // empty' 2>/dev/null)
    _TO_BAD=0
    case "$_TO_MS" in
      '') _TO_BAD=1 ;;
      *[!0-9]*) _TO_BAD=1 ;;
      *) [ "$_TO_MS" -lt 300000 ] && _TO_BAD=1 ;;
    esac
    if [ "$_TO_BAD" = "1" ]; then
      TO_MSG="W-perf9c BLOCKED: a foreground gate dispatch (v-dispatch-subagent.sh --agent …) was launched with ${_TO_MS:+a Bash timeout of ${_TO_MS} ms}${_TO_MS:-NO Bash timeout (tool default = 120000 ms)}.\n\nThe Bash tool's timeout is this gate's hard ceiling — the runner's own budget never gets a say. A pre-flight runner needs 3-9 min and a QA reviewer 3-10 min; at 2 min the tool kills the dispatch, the work is discarded, and you re-dispatch from scratch (cohort 2026-09-01: 4 gate dispatches lost this way).\n\nRe-issue the SAME command with the Bash tool parameter timeout: 600000 (CLAUDE.md § Model Policy: full-suite gate runs MUST pass explicit timeout: 600000). Minimum accepted here is 300000. Do NOT switch to run_in_background:true (W-perf9) and do NOT hand-roll claude -p (W4-413)."
      echo "[block-v-polling] DENIED: foreground gate dispatch without a >=300000 ms Bash timeout (W-perf9c)" >&2
      echo "[block-v-polling] command (truncated): ${CMD:0:200}" >&2
      jq -n --arg reason "$TO_MSG" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
    fi
  fi
fi

# ── W-perf9b (2026-06-30): RAW test runner + run_in_background:true → yield → STRAND ──
# W-perf9 covers gate DISPATCH scripts but NOT raw runners (php artisan test / vendor/bin/pest / npx vitest).
# A production session backgrounded a raw pest suite then yielded waiting for the notification; the gauntlet never resumed
# and its commit stranded unmerged. SCOPED to an ACTIVE /v session (fresh bootstrap marker, like F2) so a non-/v
# dev session backgrounding tests for parallel work is NOT blocked. NB: Claude Code's AUTO-backgrounding happens
# AFTER this PreToolUse hook, so this only ever catches a MODEL-set run_in_background:true (no auto-bg false-block).
if { [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__workspace__bash" ]; } \
   && { [ "${RUN_BG:-}" = "true" ] || [ "${RUN_BG:-}" = "1" ]; }; then
  # LOGIC-LOW2: the bare-name catch-all requires a runner FLAG after the name (parity with the Step-1 _V_RE_RUNNER
  # pattern) so it can't false-block `grep pest results.txt` / `echo 'pest passing'` etc.
  _V_RE_RAW_RUNNER='php[[:space:]]+artisan[[:space:]]+test\b|vendor/bin/(pest|phpunit)\b|npx[[:space:]]+(vitest|jest|pest)\b|node_modules/\.bin/(vitest|jest)\b|(^|[[:space:];&|()`])(pest|vitest|jest|phpunit)[[:space:]]+(-{1,2}|run[[:space:]]|tests?/)'
  if echo "$CMD" | grep -qE "$_V_RE_RAW_RUNNER"; then
    _wp9b_root="$(git -C "${PWD:-.}" rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-}")"
    _wp9b_active=0; _wp9b_now=$(date +%s 2>/dev/null || echo 0)
    if [ -n "$_wp9b_root" ]; then
      for _wp9b_m in "$_wp9b_root"/.v/tmp/bootstrap-*.env; do
        [ -f "$_wp9b_m" ] || continue
        _wp9b_mt=$(stat -c %Y "$_wp9b_m" 2>/dev/null || stat -f %m "$_wp9b_m" 2>/dev/null || echo 0)
        [ "$_wp9b_now" -gt 0 ] && [ "${_wp9b_mt:-0}" -gt 0 ] && [ $(( (_wp9b_now - _wp9b_mt) / 60 )) -lt "${V_FORK_DISPATCH_TTL_MIN:-480}" ] && { _wp9b_active=1; break; }
      done
    fi
    if [ "$_wp9b_active" -eq 1 ] && [ "${V_PERF9B_GUARD:-${V_FORK_DISPATCH_GUARD:-on}}" != "off" ]; then   # SREV-003: dedicated per-guard dial, defaults to the shared V_FORK_DISPATCH_GUARD
      RAW_MSG="W-perf9b BLOCKED: a raw test runner was launched with run_in_background:true inside an active /v session. Backgrounding the test suite then yielding STRANDS the gauntlet — a production session ran a raw pest suite this way, went passive, and never ran review/verify-done/QA/merge-back; its commit stranded unmerged. Run it FOREGROUND (run_in_background:false / omit the flag) and let the gate runner own it. If Claude Code AUTO-backgrounds a long run (that happens AFTER this hook, not via this flag), read it with the BashOutput tool — do NOT set run_in_background:true yourself, and do NOT end your turn waiting on a completion notification. (Deliberate non-gauntlet background test: re-run with V_FORK_DISPATCH_GUARD=off.)"
      echo "[block-v-polling] DENIED: raw test runner + run_in_background:true in a /v session (strands the gauntlet)" >&2
      jq -n --arg reason "$RAW_MSG" \
        '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
    fi
  fi
fi

# ── W4-413: hand-rolled gate-runner dispatch guard ───────────────────────
# A gauntlet runner/reviewer (pre-flight, verify-done, qa, ux-critique, workflow-verifier,
# handoff, codex-adversarial-reviewer) dispatched by hand-rolling a raw `claude -p --agent <name>`
# Bash command -- INSTEAD of references/v-dispatch-subagent.sh -- drops the helper's allowlist
# derivation + capture-mode Write-stripping AND, fatally, the `_run_bounded` timeout watchdog.
# Production session / W4-413 (2026-06-03): the orchestrator distrusted the helper (misread a
# NON-FATAL parse WARNING), hand-rolled the pre-flight `claude -p` itself, and the unbounded
# foreground child STRANDED for over an hour -- the 900s watchdog that would have capped it lives ONLY
# inside the helper. Prose forbids this in 4 places (v-verbatim-dispatch.md:146, SKILL.md:971/996)
# and was ignored mid-spiral, so enforce it here.
# Detection (FP-safe, verified against W4-413's own inspection commands): `claude` invoked AT
# COMMAND POSITION (start / after | ; & ( ` &&) AND a `--agent <gate-runner>` flag present AND NOT
# the helper. The helper's form is `bash …/v-dispatch-subagent.sh --agent X` (no command-position
# `claude`); `cat`/`grep …v-dispatch-subagent.sh` inspections carry `v-dispatch-subagent` (excluded)
# and put `claude` only as a grep ARG (not command position). `codex exec` is a different binary.
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__workspace__bash" ]; then
  _V_RE_CLAUDE_CMDPOS='(^|[|;&(`]|&&)[[:space:]]*claude[[:space:]]'
  _V_RE_GATE_AGENT='[-][-]agent[[:space:]=]+(v-pre-flight-runner|v-verify-done-runner|v-qa-reviewer|v-ux-critique-reviewer|v-workflow-verifier|v-handoff|codex-adversarial-reviewer)'
  if echo "$CMD" | grep -qE "$_V_RE_CLAUDE_CMDPOS" \
     && echo "$CMD" | grep -qE "$_V_RE_GATE_AGENT" \
     && ! echo "$CMD" | grep -qE 'v-dispatch-subagent'; then
    HR_MSG="W4-413 BLOCKED: hand-rolled gate-runner dispatch. You invoked a raw 'claude -p --agent <runner>' directly instead of through references/v-dispatch-subagent.sh.\n\nA hand-rolled dispatch drops the allowlist derivation + capture-mode Write-stripping AND the _run_bounded timeout watchdog -- prod session W4-413 hand-rolled the pre-flight 'claude -p' and the unbounded child STRANDED for over an hour (the watchdog that caps it at 900s lives ONLY inside the helper).\n\nUse the helper: bash \"\${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh\" --agent <name> --prompt-file <f> --artifact <path> [--mode capture|self-write].\n\nIf the helper APPEARED to fail: a 'WARNING: could not parse tools:' line is NON-FATAL (it falls back to a read-only allowlist). Do NOT debug the helper, test 'claude -p' variants, or hand-roll a replacement -- retry the EXACT helper call; on DISPATCH_STATUS=error apply the documented fallback (orchestrator-inline ONLY for the Step-5 review, never for gate runners)."
    echo "[block-v-polling] DENIED: hand-rolled gate-runner claude -p --agent dispatch (bypasses helper watchdog -- W4-413 stranded the session)" >&2
    echo "[block-v-polling] command (truncated): ${CMD:0:200}" >&2
    jq -n --arg reason "$HR_MSG" \
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
  fi
fi

# (Removed 2026-06-25: the W-perf-RD redundant-re-dispatch guard. A 2-pass review found it INERT on the real
# dispatch path — production dispatches pass `--artifact "$PROJECT_ROOT/..._${CLAUDE_SESSION_ID}.md"` (quoted +
# variable-interpolated), so the literal-leading-`/` extractor never matched and it ALLOWed every time — AND its
# bite test was green on a non-production shape (false coverage). It also targeted a near-non-problem: a gate
# re-dispatch almost always follows a code fix, so the writes-log is newer and the "no change since" block never
# fires. Removed rather than resurrected. The real turn-cost levers are the FIX-C narration directive + .v/
# bookkeeping; track with skills/v/references/v-efficiency-report.sh.)

# ── Step 1: does this command reference any v-orchestrator artifact OR
# anything that should never be polled in shell? ─────────────────────────

TOUCHES_V_ARTIFACT=0

# W41 review-fix #3: anchor gate-* to filename-context to avoid matching
# benign prose like "fix gate-summary parsing" in a commit message. We
# accept either the SID-suffixed form (gate-summary-<hex>) or filename
# extensions (.txt|.output) or path boundary (preceded by `/` or whitespace
# AND followed by a non-word/EOL).
_V_RE_CORE='(^|[[:space:]/])v-run-gates([[:space:]/.]|$)|gate-(summary|pest|vitest|build|tsc|lint)(-[A-Za-z0-9-]+)?(\.txt|\.output)?([[:space:]:/]|$)|\.v/tmp/|(^|[[:space:]/])(PRE_FLIGHT_REPORT|AGENT_REVIEW|VERIFY_DONE_REPORT|QA_REPORT|UX_CRITIQUE|WORKFLOW_VERIFICATION)_[A-Za-z0-9-]+(\.md)?([[:space:]:/;&|)]|$)'

# Claude Code BashOutput task path (W32 — production poll target)
_V_RE_TASKS='/private/tmp/claude-[0-9]+/[^[:space:]]*tasks/[^[:space:]]+\.output'

# W41 review-fix #4: tighten runner regex. Match real invocations, not bare
# `pest` words inside `composer require pestphp/pest` or `git log --grep pest`.
# Accept invocation forms: vendor/bin/pest, npx <runner>, ./vendor/bin/<runner>,
# node_modules/.bin/<runner>, and `<runner> --|-f|run|tests/|--filter|--parallel|
# --changed|--coverage|--dirty`.
_V_RE_RUNNER='\bvendor/bin/(pest|phpunit)\b|\bnpx[[:space:]]+(vitest|jest|pest)\b|\bnode_modules/\.bin/(vitest|jest)\b|(^|[[:space:];&|()`])(pest|vitest|jest|phpunit)[[:space:]]+(-{1,2}[a-z]|run|tests/|test/)'

# Tail -1/-f against any /tasks/ output path (W32)
_V_RE_TAILTASKS='tail[[:space:]]+(-1|-f|-n[[:space:]]*[0-9]+)[[:space:]]+[^[:space:]]+/tasks/'

# C8: raw cat against any /tasks/*.output path (confirmed gap: `cat .../tasks/<id>.output`
# in the pasted terminal — the _V_RE_TASKS pattern above only catches the specific Claude Code
# /private/tmp/claude-NNN/… prefix; a bare `cat` against any tasks/ path slips through).
_V_RE_CAT_TASKS='(^|[[:space:];&|()`])cat[[:space:]]+[^[:space:]]*/tasks/[^[:space:]]*\.output'

if echo "$CMD" | grep -qE "$_V_RE_CORE"; then TOUCHES_V_ARTIFACT=1; fi
if [ "$TOUCHES_V_ARTIFACT" = "0" ] && echo "$CMD" | grep -qE "$_V_RE_TASKS"; then TOUCHES_V_ARTIFACT=1; fi
if [ "$TOUCHES_V_ARTIFACT" = "0" ] && echo "$CMD" | grep -qE "$_V_RE_RUNNER"; then TOUCHES_V_ARTIFACT=1; fi
if [ "$TOUCHES_V_ARTIFACT" = "0" ] && echo "$CMD" | grep -qE "$_V_RE_TAILTASKS"; then TOUCHES_V_ARTIFACT=1; fi
if [ "$TOUCHES_V_ARTIFACT" = "0" ] && echo "$CMD" | grep -qE "$_V_RE_CAT_TASKS"; then TOUCHES_V_ARTIFACT=1; fi

# W41 review-fix #4 follow-up: for Monitor descriptions, accept verb-context
# bare runner names ("wait for pest tests", "monitor pest", "watch the build")
# even when no test-invocation flag is present in the command. This is
# scoped to Monitor only — Bash gets the strict invocation regex.
_V_RE_VERB_CTX='\b(wait|watch|monitor|poll)\b[[:space:]]+(for[[:space:]]+|until[[:space:]]+|the[[:space:]]+)?(run-gates|gate-summary|gate-pest|gate-vitest|gate-build|gate-tsc|gate-lint|v-run-gates)\b|\b(wait|watch|monitor|poll)\b[[:space:]]+(for[[:space:]]+|until[[:space:]]+|the[[:space:]]+)?(pest|vitest|jest|phpunit)[[:space:]]+(tests?|run|complete|completion|finish|finished|done|to[[:space:]]+complete|to[[:space:]]+finish)\b|\b(wait|watch|monitor|poll)\b[[:space:]]+(for[[:space:]]+|until[[:space:]]+|the[[:space:]]+)?(pre-?flight|agent[[:space:]]+review|verify-?done|report|review|artifact)\b'
if [ "$TOUCHES_V_ARTIFACT" = "0" ] && [ "$TOOL_NAME" = "Monitor" ]; then
  if echo "$CMD" | grep -qiE "$_V_RE_VERB_CTX"; then TOUCHES_V_ARTIFACT=1; fi
fi

[[ "$TOUCHES_V_ARTIFACT" = "0" ]] && exit 0

# ── Step 2: does it contain a polling/waiting pattern? ───────────────────
POLLING=0
POLLING_REASON=""

# W41 review-fix #5: catch indirect sleep dispatch via python/perl/node and
# `at`/`crontab` scheduling.
if echo "$CMD" | grep -qE '\btail[[:space:]]+-[fF]\b'; then
  POLLING=1
  POLLING_REASON="tail -f against a v artifact"
elif echo "$CMD" | grep -qE '\binotifywait\b'; then
  POLLING=1
  POLLING_REASON="inotifywait against a v artifact"
elif echo "$CMD" | grep -qE 'until[[:space:]].*\bsleep\b' || echo "$CMD" | grep -qE 'while[[:space:]].*\bsleep\b'; then
  POLLING=1
  POLLING_REASON="until/while + sleep loop wrapping a v artifact"
elif echo "$CMD" | grep -qE 'until[[:space:]].*(time\.sleep|setTimeout|usleep|Time::HiRes::sleep)' || \
     echo "$CMD" | grep -qE 'while[[:space:]].*(time\.sleep|setTimeout|usleep|Time::HiRes::sleep)'; then
  POLLING=1
  POLLING_REASON="until/while + python/node/perl indirect sleep"
elif echo "$CMD" | grep -qE 'ps[[:space:]]+(aux|-ef|-A).*grep.*(v-run-gates|gate-|pest|vitest|jest)'; then
  POLLING=1
  POLLING_REASON="ps + grep watching v-run-gates / gate / test-runner process"
elif echo "$CMD" | grep -qE 'pgrep[[:space:]].*(v-run-gates|gate-|pest|vitest|jest|node)'; then
  POLLING=1
  POLLING_REASON="pgrep watching v-run-gates / gate / test-runner process"
elif echo "$CMD" | grep -qE 'tail[[:space:]]+(-1|-f|-n[[:space:]]*[0-9]+)[[:space:]]+[^[:space:]]*tasks/[^[:space:]]+\.output'; then
  POLLING=1
  POLLING_REASON="tail -1/-f against Claude Code BashOutput task file (use BashOutput tool instead)"
elif echo "$CMD" | grep -qE '\b(at[[:space:]]+now|atq|crontab[[:space:]]+-)'; then
  POLLING=1
  POLLING_REASON="at/crontab scheduling against a v artifact"
elif echo "$CMD" | grep -qE "$_V_RE_CAT_TASKS"; then
  # C8: raw cat against any /tasks/*.output is polling by another name — the BashOutput tool
  # provides clean streaming without per-session novel paths that trigger permission prompts.
  POLLING=1
  POLLING_REASON="raw cat against Claude Code BashOutput task file (use the BashOutput tool instead)"
fi

# W41 review-fix #8 + #10: For Monitor tool, also deny on description-only
# wait/watch/poll intent. Add build|tsc|lint to the verb noun list.
# Require co-occurrence of an artifact match (already true at this point —
# we only reach Step 2 if TOUCHES_V_ARTIFACT=1) so this isn't a frustration
# vector for benign Monitor calls.
if [ "$POLLING" = "0" ] && [ "$TOOL_NAME" = "Monitor" ]; then
  if echo "$CMD" | grep -qiE '(\bwait\b[[:space:]]+(for|until)|\bwatch\b[[:space:]]+(for|until|the)|\bpoll\b|monitor[[:space:]]+(for|until|gate|pest|vitest|jest|run-gates|build|tsc|lint))'; then
    POLLING=1
    POLLING_REASON="Monitor description expresses wait/watch/poll intent against a v artifact"
  fi
fi

[[ "$POLLING" = "0" ]] && exit 0

# ── Step 3: emit deny ───────────────────────────────────────────────────
DENY_MESSAGE=$(cat <<EOF
W41 BLOCKED: polling loop wrapping a v orchestrator artifact.

Tool: $TOOL_NAME
Detected pattern: $POLLING_REASON
Touched artifact: yes (matched v-run-gates / gate-summary-* / .v/tmp/ / /tasks/*.output / pest|vitest|jest invocation)

This call was almost certainly generated to wait for v-run-gates.sh
completion. There are exactly TWO correct patterns:

Option A — foreground (preferred):
  bash "\${CLAUDE_SKILL_DIR}/references/v-run-gates.sh"
  cat "\${V_TMP_DIR}/gate-summary-\${SESSION_ID}.txt"
  ↑ Two SEPARATE Bash tool calls. The first blocks (foreground). The second
    reads the result. The helper emits a heartbeat every 20s to keep Claude
    Code from auto-backgrounding it.

Option B — if Claude Code DID auto-background (rare, but happens on >2min runs):
  Use the \`BashOutput\` tool with the bash_id returned by the original Bash
  call. NEVER write a shell \`tail -f\` / \`tail -1\` / \`cat\` against the task
  output file at /private/tmp/claude-NNN/.../tasks/*.output. The BashOutput
  tool reads the live stream cleanly with no per-session novel path that
  triggers Cowork permission prompts.

NO Monitor() calls, NO \`while ... sleep\`, \`until ... sleep\`, \`tail -f\`,
\`tail -1 ... tasks/*.output\`, \`ps aux | grep\`, \`pgrep\`, indirect
\`time.sleep\` / \`setTimeout\` / \`usleep\`, or \`at\`/\`crontab\` scheduling.
The Monitor tool IS a poll-with-extra-steps; v-run-gates.sh foreground +
BashOutput cover every legitimate wait scenario without per-session novel
paths or Cowork permission prompts. (W41)
EOF
)

echo "[block-v-polling] DENIED: $POLLING_REASON" >&2
echo "[block-v-polling] tool=$TOOL_NAME command (truncated): ${CMD:0:200}" >&2

jq -n --arg reason "$DENY_MESSAGE" \
  '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'

exit 0
