#!/usr/bin/env bash
# codex-review.sh — Run Codex adversarial review with semantic fallback signaling.
# Called by: codex-adversarial-reviewer agent
# Classification: mandatory dispatch helper — never silently skips review.
set -euo pipefail

TIMEOUT_SECONDS=120
MAX_DIFF_CHARS=50000
MAX_FINDINGS=10
LOG_PREFIX="[codex-adversarial-reviewer]"
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
# DEFAULT FLIPPED 2026-08-03 (was gpt-5.3-codex). Verified live on a ChatGPT-login Codex account:
#   codex exec --model gpt-5.3-codex  -> HTTP 400 "The 'gpt-5.3-codex' model is not supported when
#                                        using Codex with a ChatGPT account"   (100% failure)
#   codex exec --model gpt-5.5        -> exit 0
# The 400 was documented in comments here since 2026-06-03 but the DEFAULT was never changed, so every
# review paid a guaranteed-failed round trip before retrying the model that actually works. The retry
# below is kept (gpt-5.3-codex now the fallback) so an account that DOES support it still gets it.
CODEX_REVIEW_MODEL="${CODEX_REVIEW_MODEL:-gpt-5.5}"
# Fallback model: gpt-5.3-codex 400s on ChatGPT accounts ("not supported"); gpt-5.5 is the
# verified-working model there (probed 2026-06-03). On a non-timeout failure of the primary, the
# review retries once with this so the codex path doesn't degrade to semantic-fallback when a
# working model is available. Mirrors the canonical /v path (references/v-agent-review.md:114-115).
CODEX_REVIEW_MODEL_FALLBACK="${CODEX_REVIEW_MODEL_FALLBACK:-gpt-5.3-codex}"

# Shared timeout compatibility (timeout on Linux, gtimeout on macOS, or fallback)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TIMEOUT_LIB="${SCRIPT_DIR}/../hooks/lib/timeout-compat.sh"
if [ -f "$TIMEOUT_LIB" ]; then
    # shellcheck disable=SC1090
    source "$TIMEOUT_LIB"
fi

emit_fallback_required() {
    local reason="$1"
    echo "## Codex Adversarial Review"
    echo "status: fallback_required"
    echo "reason: ${reason}"
    echo "fallback: superpowers:requesting-code-review"
    echo "findings: 0"
}

emit_completed_no_findings() {
    local note="$1"
    echo "## Codex Adversarial Review"
    echo "status: completed"
    echo "findings: 0"
    echo "note: ${note}"
}

# --- FIX-6 (self-audit 2026-06-18): durable dispatch evidence -----------------
# A genuine codex review via this canonical helper must leave evidence the independence gate
# recognizes, so its forgery-check (hooks/lib/validation.sh:_independence_verdict — an AGENT_REVIEW
# that claims "codex … ran" with NO dispatch evidence anywhere → "silent" → BLOCK) does not fire on
# legitimate runs. Two signals, BOTH already honored by validation.sh:_agent_was_dispatched:
#   (1) a DISPATCH_PROVENANCE status=ok line (mode=codex_cli), written ONLY on codex exit 0; and
#   (2) a durable codex-review-<sid>.log proxy (the helper previously kept codex output only in a
#       mktemp file deleted on EXIT, leaving no proxy — the NEW-B gap).
# SID resolution mirrors v-dispatch-subagent.sh; an empty SID ⇒ skip the write (better no record
# than a session_id-less one). The artifact dir is resolved through the single-source
# v-artifact-dir.sh so this writer and the Stop hook's ARTIFACT_SEARCH_DIRS never drift.
CODEX_PROV_SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
CODEX_PROV_DIR=""
if [ -n "$CODEX_PROV_SID" ]; then
    CODEX_PROV_DIR=$(bash "${SCRIPT_DIR}/../skills/v/references/v-artifact-dir.sh" 2>/dev/null || true)
    if [ -z "$CODEX_PROV_DIR" ]; then
        # LEAK-GUARD (2026-08-02): independent reimplementation of root resolution — the bare
        # `pwd` fallback leaked provenance into skill source trees under the git-less config dir.
        _cpd_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        _cpd_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
        if [ -n "$_cpd_cfg" ] && [ "$_cpd_root" != "$_cpd_cfg" ]; then
            case "$_cpd_root" in
                "$_cpd_cfg"/*) git -C "$_cpd_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || _cpd_root="$_cpd_cfg" ;;
            esac
        fi
        CODEX_PROV_DIR="$_cpd_root/.v/artifacts"
    fi
    mkdir -p "$CODEX_PROV_DIR" 2>/dev/null || CODEX_PROV_DIR=""
fi
CODEX_START_S=""

write_codex_provenance() {  # <status>  (ok | error)
    [ -n "$CODEX_PROV_SID" ] && [ -n "$CODEX_PROV_DIR" ] || return 0
    local _status="$1" _dur="" _now_s
    if [ -n "$CODEX_START_S" ]; then
        _now_s=$(date +%s 2>/dev/null || echo "")
        [ -n "$_now_s" ] && _dur=$(( (_now_s - CODEX_START_S) * 1000 ))
    fi
    printf 'DISPATCH|ts=%s|agent=codex-adversarial-reviewer|mode=codex_cli|status=%s|submodel=%s|cost_usd=|duration_ms=%s|artifact=codex-review-%s.log\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_status" "${CODEX_REVIEW_MODEL_USED:-${CODEX_REVIEW_MODEL:-unknown}}" "$_dur" "$CODEX_PROV_SID" \
        >> "${CODEX_PROV_DIR}/DISPATCH_PROVENANCE_${CODEX_PROV_SID}.log" 2>/dev/null || true
}

save_codex_proxy() {  # <content>
    [ -n "$CODEX_PROV_SID" ] && [ -n "$CODEX_PROV_DIR" ] || return 0
    local _content="$1"
    [ -n "$_content" ] || _content="codex-adversarial-reviewer completed for session ${CODEX_PROV_SID} (no textual findings output)"
    printf '%s\n' "$_content" > "${CODEX_PROV_DIR}/codex-review-${CODEX_PROV_SID}.log" 2>/dev/null || true
}

merge_base=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    merge_base=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || true)
fi

# --- 1. Check codex availability ---
if ! command -v codex >/dev/null 2>&1; then
    echo "${LOG_PREFIX} codex CLI not found — semantic fallback required" >&2
    emit_fallback_required "codex CLI not installed"
    exit 0
fi

# --- 1b. H4-10 (PLAN_2026-07-02_orchestrator-hardening-4): codex-down TTL memo ---
# Ground truth: one session exec'd codex 3x in one run, KNOWING codex is usage-limit-locked
# until a known future date — every /v session re-probes codex cold, paying the ~2min TIMEOUT_SECONDS
# hang each time before falling back. If a PRIOR run recorded a usage-limit error + its reset date,
# skip straight to fallback with ONE log line — no exec attempted — until that date passes.
CODEX_DOWN_MEMO="${CODEX_DOWN_MEMO_FILE:-$HOME/.claude/runtime/codex-down-until.txt}"
if [ -f "$CODEX_DOWN_MEMO" ]; then
    # SET-E SUBSTITUTION GUARDS (forensic 2026-07-09, a production-repo codex review): a failing
    # command substitution in a PLAIN assignment aborts the whole script under `set -euo pipefail`
    # — an unreadable memo, or a malformed memo date that macOS `date -j -f` rejects, exited this
    # script 1 with EMPTY stdout BEFORE any emit_fallback_required, so the dispatching skill saw a
    # silent failure instead of `status: fallback_required`. Every substitution on this early path
    # must degrade to empty (the [ -n ] checks below already handle empty correctly).
    _cdm_until=$(tr -d '[:space:]' < "$CODEX_DOWN_MEMO" 2>/dev/null || true)
    _cdm_now_epoch=$(date -u +%s 2>/dev/null || echo 0)
    _cdm_until_epoch=""
    if [ -n "$_cdm_until" ]; then
        # SLIDING-MEMO FIX (2026-08-03): parse at an EXPLICIT midnight. macOS `date -j -f "%Y-%m-%d"`
        # fills unspecified time fields from the CURRENT time-of-day, so "2026-08-03" parsed at 17:00
        # yielded Aug-3 17:00 and, with the +86400 below, an `until` of Aug-4 17:00. Because `now`
        # advanced in lockstep with the parse result, `now < until` stayed true for the WHOLE of the
        # memo's own day and the memo could never expire during it — a 1-day outage suppressed codex
        # for up to 2. Observed live: a memo written 2026-08-02 for a reset that had already happened
        # was still suppressing on 2026-08-03 while `codex exec --model gpt-5.5` returned exit 0.
        # Anchoring to midnight makes +86400 mean exactly "end of the stated day", as documented.
        _cdm_until_epoch=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$_cdm_until 00:00:00" +%s 2>/dev/null || true)
        [ -n "$_cdm_until_epoch" ] || _cdm_until_epoch=$(date -u -d "$_cdm_until 00:00:00" +%s 2>/dev/null || true)
        # DAY-GRANULARITY FIX (2026-07-06): the memo stores only a DATE, but the real reset happens
        # at some TIME on that date ("try again at <month day, year, time>" → memo `<that date>`).
        # Comparing against the START of the stated day treated the memo as expired the moment that
        # calendar day began — re-probing codex up to ~24h early, exactly the cold-probe cost the
        # memo exists to avoid (surfaced live 2026-07-06: a memo written the previous evening for a
        # same-day reset stopped suppressing at midnight). A day-granularity "down until <date>"
        # must hold through the END of that date: +86400s. (On macOS, `date -j -f "%Y-%m-%d"` fills
        # unspecified time fields with the CURRENT time-of-day, so the raw epoch is not even a
        # stable midnight — the +86400 also papers over that parse quirk in the conservative
        # direction.) Cost ceiling: at most a few extra fallback-path hours after the true reset.
        [ -n "$_cdm_until_epoch" ] && _cdm_until_epoch=$(( _cdm_until_epoch + 86400 ))
    fi
    if [ -n "$_cdm_until_epoch" ] && [ "$_cdm_now_epoch" -lt "$_cdm_until_epoch" ] 2>/dev/null; then
        echo "${LOG_PREFIX} codex-down memo active (usage-limit-locked until end of ${_cdm_until}) — skipping codex exec, going straight to fallback (${CODEX_DOWN_MEMO})" >&2
        emit_fallback_required "codex usage-limit-locked until end of ${_cdm_until} (memo: ${CODEX_DOWN_MEMO})"
        exit 0
    fi
    # memo expired (or unparseable) — clear it so it self-heals instead of lingering stale.
    rm -f "$CODEX_DOWN_MEMO" 2>/dev/null || true
fi

# --- 1c. E2 (2026-07-06): also honor the fleet-wide minute-granularity quota cache -------------
# hooks/lib/codex-quota-cache.sh is the SHARED suppression layer the PRIMARY direct-Bash codex
# path (v-agent-review.md supervisor child) and the codex-exec witness hook
# (record-codex-dispatch-provenance.sh) write on a genuine quota signature. Honoring it here means
# a quota wall discovered by ANY dispatch path suppresses THIS path too (and vice versa — the
# usage-limit classifier below records into the same cache), so the fleet pays the discovery cost
# once, not once per mechanism. The day-memo above stays authoritative for explicit reset DATES;
# this cache covers the 45-min TTL case. Fail-open: lib missing → behavior unchanged.
_CQ_LIB="$HOME/.claude/hooks/lib/codex-quota-cache.sh"
if [ -f "$_CQ_LIB" ]; then
    # shellcheck disable=SC1090
    . "$_CQ_LIB" 2>/dev/null || true
    if declare -F codex_quota_is_blocked >/dev/null 2>&1 && _cq_reason=$(codex_quota_is_blocked); then
        echo "${LOG_PREFIX} ${_cq_reason} — skipping codex exec, going straight to fallback" >&2
        emit_fallback_required "${_cq_reason}"
        exit 0
    fi
fi

# --- 2. Collect changed files (includes committed worktree changes) ---
changed_files=$(
    {
        if [ -n "${CODEX_REVIEW_FILES:-}" ]; then
            echo "${CODEX_REVIEW_FILES}" | tr ',;' '\n'
        fi
        if [ -n "$merge_base" ]; then
            git diff --name-only "$merge_base"..HEAD 2>/dev/null || true
        fi
        git diff --name-only HEAD 2>/dev/null || true
        git diff --name-only --cached 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^[[:space:]]*$/d' | sort -u | grep -E '\.(php|ts|tsx|js|jsx|py|rs|go|sh|bash|zsh)$' || true
)

if [ -z "$changed_files" ]; then
    emit_completed_no_findings "No changed code files detected for review scope."
    exit 0
fi

# --- 3. Build the diff (includes committed worktree diff + staged/unstaged) ---
diff_content=$(
    {
        if [ -n "$merge_base" ]; then
            git diff "$merge_base"..HEAD 2>/dev/null || true
        fi
        git diff HEAD 2>/dev/null || true
        git diff --cached 2>/dev/null || true
    } | head -c "${MAX_DIFF_CHARS}"
)

if [ -z "$diff_content" ]; then
    emit_completed_no_findings "Changed files detected, but no textual diff payload was available."
    exit 0
fi

# --- 4. Get project context ---
project_context=""
if [ -f "CLAUDE.md" ]; then
    project_context=$(head -50 CLAUDE.md 2>/dev/null || true)
elif [ -f ".claude/CLAUDE.md" ]; then
    project_context=$(head -50 .claude/CLAUDE.md 2>/dev/null || true)
fi

# --- 5. Build prompt ---
review_prompt="You are a hostile code reviewer. Your job is to find bugs, security issues, and logic errors that the original author missed. Focus on:

1. Security vulnerabilities (injection, auth bypass, mass assignment, XSS, CSRF)
2. Logic errors and off-by-one mistakes
3. Race conditions and concurrency issues
4. Missing error handling and edge cases
5. Performance problems (N+1 queries, unbounded loops, missing indexes)
6. Type safety violations

Be specific. For each issue, provide:
- File and line number
- What the bug is
- How to exploit or trigger it
- Suggested fix

If the code looks correct, say ONLY: No issues found.
Do NOT invent problems. Do NOT pad with generic advice.
Limit to ${MAX_FINDINGS} most important issues.

Project context:
${project_context}

Diff to review:
${diff_content}"

# --- 6. Execute codex with timeout ---
codex_output=""
codex_exit=0
codex_last_message=$(mktemp 2>/dev/null || mktemp -t codex-review-last-message)
# H4-10: capture stderr (where usage-limit errors surface) so a failure can be classified as
# usage-limit-locked vs a generic error, instead of discarding it to /dev/null unread.
codex_err_capture=$(mktemp 2>/dev/null || mktemp -t codex-review-err-capture)
cleanup_codex_last_message() {
    rm -f "$codex_last_message" "$codex_err_capture"
}
trap cleanup_codex_last_message EXIT
# Run codex for ONE model under whichever timeout shim is available, with stdin pinned to
# /dev/null. The </dev/null is mandatory: without a stdin EOF, `codex exec` can block on
# "Reading additional input from stdin" and hang the whole gate (observed 2026-05-24) —
# and on macOS the no-timeout branch below has nothing else to interrupt it.
run_codex() {
    local model="$1" rc=0
    local cmd=(codex exec --model "$model" --full-auto --color never -o "$codex_last_message" "$review_prompt")
    if declare -F run_with_timeout >/dev/null 2>&1; then
        run_with_timeout "${TIMEOUT_SECONDS}" "${cmd[@]}" </dev/null >/dev/null 2>>"$codex_err_capture" || rc=$?
    elif [[ -n "${TIMEOUT_CMD:-}" ]]; then
        "${TIMEOUT_CMD}" "${TIMEOUT_SECONDS}" "${cmd[@]}" </dev/null >/dev/null 2>>"$codex_err_capture" || rc=$?
    else
        "${cmd[@]}" </dev/null >/dev/null 2>>"$codex_err_capture" || rc=$?
    fi
    return "$rc"
}

# H4-10: on failure, classify a usage-limit error and memo the reset date so future runs skip
# straight to fallback (see the "1b" check near the top of this script). Best-effort — never fails
# the caller. Recognizes an explicit reset date in the error text (several common phrasings); falls
# back to a conservative 24h TTL when the limit is confirmed but no date is stated.
_write_codex_down_memo_if_usage_limited() {
    local capture="$1"
    [ -s "$capture" ] || return 0
    grep -qiE 'usage limit|rate limit|quota exceeded|too many requests|429' "$capture" 2>/dev/null || return 0
    local memo="${CODEX_DOWN_MEMO_FILE:-$HOME/.claude/runtime/codex-down-until.txt}"
    mkdir -p "$(dirname "$memo")" 2>/dev/null || return 0
    local _reset_date
    # `|| true`: the final grep exits 1 on no-match; under `set -e` a failing assignment inside
    # this function aborts the WHOLE script at its call site — which sits directly BEFORE
    # emit_fallback_required on the codex-failure path (silent exit 1, no status line).
    _reset_date=$(grep -ioE '(until|after|on)[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' "$capture" 2>/dev/null \
        | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [ -z "$_reset_date" ]; then
        # No explicit date in the message — conservative 24h TTL default (never lock out longer
        # than confirmed by the message itself).
        _reset_date=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d '+1 day' +%Y-%m-%d 2>/dev/null)
    fi
    if [ -n "$_reset_date" ]; then
        printf '%s\n' "$_reset_date" > "$memo" 2>/dev/null || true
        echo "${LOG_PREFIX} usage-limit error detected — memoized codex-down-until=${_reset_date} (${memo})" >&2
    fi
    # E2 (2026-07-06): mirror the discovery into the fleet-wide minute-granularity quota cache so
    # the OTHER codex dispatch paths (direct-Bash supervisor child, witness hook consumers) skip
    # their own doomed probe too. Best-effort; the day-memo above remains this script's own layer.
    if declare -F codex_quota_record_exhausted >/dev/null 2>&1; then
        codex_quota_record_exhausted "$(grep -iE 'usage limit|rate limit|quota exceeded|too many requests|429' "$capture" 2>/dev/null | head -1)" 2>/dev/null || true
    fi
}

# Track the model that ACTUALLY produced the findings, not the one we tried first. The fallback
# retry below can switch models; emitting CODEX_REVIEW_MODEL (the primary) on a fallback run
# mislabels gpt-5.5 findings as gpt-5.3-codex and corrupts cost/provenance telemetry.
CODEX_REVIEW_MODEL_USED="$CODEX_REVIEW_MODEL"

CODEX_START_S=$(date +%s 2>/dev/null || echo "")   # FIX-6: elapsed for provenance duration_ms
run_codex "$CODEX_REVIEW_MODEL" || codex_exit=$?
# Model fallback (see CODEX_REVIEW_MODEL_FALLBACK above): on a NON-timeout failure of the primary
# model, retry once with the fallback so a model-availability 400 doesn't silently drop the whole
# codex review to semantic-fallback. A timeout (124) is NOT retried — that's a genuine hang/slow,
# not a wrong-model error, and retrying would just burn another TIMEOUT_SECONDS.
if [ "${codex_exit}" -ne 0 ] && [ "${codex_exit}" -ne 124 ] \
   && [ -n "${CODEX_REVIEW_MODEL_FALLBACK:-}" ] \
   && [ "${CODEX_REVIEW_MODEL_FALLBACK}" != "${CODEX_REVIEW_MODEL}" ]; then
    echo "${LOG_PREFIX} model '${CODEX_REVIEW_MODEL}' failed (exit ${codex_exit}); retrying with '${CODEX_REVIEW_MODEL_FALLBACK}'" >&2
    codex_exit=0
    CODEX_REVIEW_MODEL_USED="$CODEX_REVIEW_MODEL_FALLBACK"
    run_codex "${CODEX_REVIEW_MODEL_FALLBACK}" || codex_exit=$?
fi

if [ "${codex_exit}" -ne 0 ]; then
    case "${codex_exit}" in
        124) reason="timeout after ${TIMEOUT_SECONDS}s" ;;
        *)   reason="exit code ${codex_exit}" ;;
    esac
    echo "${LOG_PREFIX} codex failed (${reason}) — semantic fallback required" >&2
    _write_codex_down_memo_if_usage_limited "$codex_err_capture"   # H4-10
    write_codex_provenance error   # FIX-6: record the failed attempt; never status=ok
    emit_fallback_required "${reason}"
    exit 0
fi

if [ -s "$codex_last_message" ]; then
    codex_output=$(cat "$codex_last_message" 2>/dev/null || true)
fi

# --- 7. Check for empty or no-issues output ---
# FIX-6 + security-review F2: only a run that produced REAL output credits independence. codex can
# exit 0 with an EMPTY capture file (model printed nothing); that is a degenerate non-review, so it
# records status=error (NOT ok) and writes NO proxy — otherwise an empty no-op would permanently
# satisfy _agent_was_dispatched for the session.
if [ -z "$codex_output" ]; then
    write_codex_provenance error
    emit_completed_no_findings "Codex produced no output (empty review — not credited as a dispatch)."
    exit 0
fi

# Codex produced substantive output (findings OR an explicit "no issues found") ⇒ a genuine review
# ran. Record provenance + a durable proxy so the independence gate recognizes the dispatch.
write_codex_provenance ok
save_codex_proxy "$codex_output"

if echo "$codex_output" | grep -qi "no issues found"; then
    emit_completed_no_findings "Codex found no issues in the changed files."
    exit 0
fi

# --- 8. Output raw findings (dispatching skill parses into FINDING_FORMAT) ---
echo "## Codex Adversarial Review"
echo "status: completed"
echo "source: codex-adversarial-reviewer (external model — all findings confidence: low)"
echo "model: ${CODEX_REVIEW_MODEL_USED}"
echo ""
echo "### Raw Findings"
echo ""
echo "$codex_output"
echo ""
echo "---"
echo "Note: These findings are from an external model and start at confidence: low."
echo "The dispatching skill must independently verify before escalating confidence."
exit 0
