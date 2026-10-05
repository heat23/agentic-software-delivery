#!/usr/bin/env bash
# record-codex-dispatch-provenance.sh — PostToolUse (matcher: Bash)
#
# WHY (forensic 2026-07-04): codex-adversarial-reviewer is the ONE reviewer invoked as a
# raw `codex exec` CLI subprocess, not through v-dispatch-subagent.sh (which self-records) nor always
# through v-agent-review.md's supervisor-child snippet (which records via _v_record_subprocess_provenance).
# When the orchestrator HAND-ROLLS `codex exec` (the documented PRIMARY fork-compatible path), a
# failure leaves NO provenance line — yet the AGENT_REVIEW narrated "Provenance recorded (status=failed)".
# A codex-quota session thus shipped with a provenance log that had ZERO codex rows, so no
# gate/forensic could distinguish "codex never attempted" from "attempted and failed". This hook is the
# WITNESS: it records a DISPATCH line for EVERY codex-exec Bash call, keyed off the call's own result —
# unforgeable by narration, independent of which dispatch path was used.
#
# Idempotency: the W59-F2 degrade gate and forensics key on `status=ok`+sha256 (a failed row never
# counts as a review). Duplicate rows for the same (artifact,status) are harmless (append-only,
# counters key on status=ok). Fail-open: PostToolUse must NEVER block or error.
set -uo pipefail
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0
[ "$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -n "$CMD" ] || exit 0
# Only a REAL codex-review invocation — `codex exec` or the canonical wrapper. A mention of the
# word "codex" in some other command (e.g. this very hook's path) must not trigger a phantom row.
printf '%s' "$CMD" | grep -qE '\bcodex[[:space:]]+exec\b|codex-review\.sh\b' || exit 0

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -n "$SID" ] || exit 0
case "$SID" in *[!a-zA-Z0-9-]*) exit 0 ;; esac   # strict SID shape (path-safety)

# Item 7 (2026-07-05, foreign-SID bleed): SID-bind against THIS process's own local identity —
# same defense as record-agent-dispatch-provenance.sh. A payload .session_id that DISAGREES
# with the local env/runtime identity is a foreign-SID bleed; refuse to write under it rather
# than contaminate a different session's DISPATCH_PROVENANCE log. Fail-open when no local
# identity is resolvable (nothing to cross-check; behavior unchanged).
_LOCAL_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -z "$_LOCAL_SID" ] && [ -f "$HOME/.claude/runtime/current-session-id" ]; then
  _LOCAL_SID="$(tr -d '[:space:]' < "$HOME/.claude/runtime/current-session-id" 2>/dev/null)"
fi
if [ -n "$_LOCAL_SID" ] && [ "$_LOCAL_SID" != "$SID" ]; then
  echo "record-codex-dispatch-provenance: REJECTED foreign-SID row (payload sid=$SID, local identity=$_LOCAL_SID) — refusing to write DISPATCH_PROVENANCE for a different session" >&2
  exit 0
fi

# Resolve MAIN_ROOT (worktree-safe): provenance belongs to the main checkout's .v/artifacts.
REPO_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$REPO_TOP" ] || exit 0
COMMON="$(git -C "$REPO_TOP" rev-parse --git-common-dir 2>/dev/null || true)"; [ -n "$COMMON" ] || exit 0
case "$COMMON" in /*) MAIN_ROOT="$(dirname "$COMMON")" ;; *) MAIN_ROOT="$(cd "$REPO_TOP/$(dirname "$COMMON")" 2>/dev/null && pwd)" ;; esac
[ -n "${MAIN_ROOT:-}" ] && [ -d "$MAIN_ROOT" ] || exit 0

# Result / status. The codex CLI prints its usage-limit wall to the OUTPUT (not a distinct exit signal
# the harness surfaces here), so classify from BOTH the harness error flag AND the captured text.
IS_ERR="$(printf '%s' "$INPUT" | jq -r '.tool_response.is_error // .is_error // false' 2>/dev/null || true)"
# FABLE-STDERR (2026-07-04): classify from stdout AND stderr — the codex CLI prints its
# usage-limit/auth walls to stderr; stdout-only sniffing recorded status=ok for a quota-failed
# run (the F5 false-ok class) whenever stdout happened to be non-empty.
OUT="$(printf '%s' "$INPUT" | jq -r '[.tool_response.stdout // "", .tool_response.stderr // ""] | join("\n")' 2>/dev/null || true)"
case "$OUT" in *[![:space:]]*) : ;; *) OUT="$(printf '%s' "$INPUT" | jq -r '.tool_response | tostring' 2>/dev/null || true)" ;; esac
STATUS=ok
# F17 (forensic 2026-07-11): the bare tokens `quota` and `rate.?limit`
# matched the PRODUCT DOMAIN of the reviewed diff (quota-related class names discussed
# throughout a genuinely-successful exit-0 codex transcript),
# recording status=failed twice for a real review — which cascaded into an attest refusal
# and a blocked session log. Tightened to exhaustion/limit-wall SIGNATURES only (matching
# the deliberately-narrow codex_quota_looks_like_exhaustion philosophy below); real walls
# stay covered by IS_ERR + "hit your usage limit|usage limit" + the auth/stream tokens.
if [ "$IS_ERR" = "true" ] \
   || printf '%s' "$OUT" | grep -qiE "hit your usage limit|usage limit|quota exceeded|quota.?exhaust|rate.?limit exceeded|rate.?limited|error: you.?ve hit|Usage: codex exec|stream error|not authenticated|401 Unauthorized"; then
  STATUS=failed
fi

# E2 (efficiency, 2026-07-05): this hook is the ONE witness that fires for EVERY codex-exec Bash
# call regardless of which dispatch path triggered it — the natural, already-wired place to record
# a fleet-wide "codex quota exhausted" cache so OTHER sessions (and later dispatch points in THIS
# session) skip a doomed re-attempt instead of each independently paying the network round-trip to
# rediscover the same exhaustion. Narrower than the STATUS=failed classifier above on purpose
# (codex_quota_looks_like_exhaustion) — a generic auth/stream error should not lock codex out for
# 30-60 min fleet-wide, only a genuine usage-limit/quota signature should.
if [ "$STATUS" = failed ]; then
  _CQ_LIB="$HOME/.claude/hooks/lib/codex-quota-cache.sh"
  if [ -f "$_CQ_LIB" ]; then
    # shellcheck disable=SC1090
    . "$_CQ_LIB" 2>/dev/null || true
    if declare -F codex_quota_looks_like_exhaustion >/dev/null 2>&1 && codex_quota_looks_like_exhaustion "$OUT"; then
      codex_quota_record_exhausted "$(printf '%s' "$OUT" | grep -iE "hit your usage limit|usage limit|quota exceeded|quota.?exhaust|rate.?limit exceeded|rate.?limited" | head -1)" 2>/dev/null || true
    fi
  fi
fi

# Best-effort artifact: a `> REVIEW_CODEX_<sid>...` / `> $ART_CODEX` redirect in the command, else blank.
ART="$(printf '%s' "$CMD" | grep -oE '(REVIEW_CODEX|AGENT_REVIEW)_[0-9a-f-]+\.md' | head -1 || true)"
SHA=""
if [ -n "$ART" ]; then
  for d in "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT" "$REPO_TOP" "$REPO_TOP/.v/artifacts"; do
    [ -f "$d/$ART" ] && { SHA="$(shasum -a 256 "$d/$ART" 2>/dev/null | awk '{print $1}')"; break; }
  done
fi

# W59-BIND (2026-08-03): if the caller did NOT redirect codex's output to a named artifact, PERSIST it
# ourselves so the row is hash-bindable. Without this the row carries artifact=/sha256= empty, and
# `_w59_witnessed_independent_reviews` (validation.sh) — which counts only rows whose recorded sha256
# matches a real on-disk artifact — scores the review as ZERO. Observed live: a session
# ran codex SIX times, all status=ok, and still minted a REVIEW_DEBT marker reading
# "witnessed_independent_reviewers: 0". That debt was UNDISCHARGEABLE: re-running codex the same way
# reproduced the same unbindable rows, so the marker could never be satisfied by doing what it asked.
# Only persist a NEW file — never overwrite an existing artifact, because a prior row's recorded sha
# would stop matching and that review would silently stop counting.
if [ -z "$ART" ] && [ -n "${OUT:-}" ] && [ -n "$SID" ]; then
  _bind_dir="$MAIN_ROOT/.v/artifacts"
  if mkdir -p "$_bind_dir" 2>/dev/null; then
    _cand="REVIEW_CODEX_${SID}.md"
    if [ -e "$_bind_dir/$_cand" ]; then
      _n=2
      while [ -e "$_bind_dir/REVIEW_CODEX_${SID}-${_n}.md" ] && [ "$_n" -lt 50 ]; do _n=$((_n+1)); done
      _cand="REVIEW_CODEX_${SID}-${_n}.md"
    fi
    if [ ! -e "$_bind_dir/$_cand" ] && printf '%s\n' "$OUT" > "$_bind_dir/$_cand" 2>/dev/null; then
      ART="$_cand"
      SHA="$(shasum -a 256 "$_bind_dir/$_cand" 2>/dev/null | awk '{print $1}')"
      [ -n "$SHA" ] || ART=""      # fail-open: an unhashable artifact must not be claimed as witnessed
    fi
  fi
fi

PROV="$MAIN_ROOT/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null || exit 0
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
MODEL="$(printf '%s' "$CMD" | grep -oE -- '--model[[:space:]=]+[^[:space:]"'\'']+' | head -1 | sed -E 's/^--model[[:space:]=]+//' || true)"
[ -n "$MODEL" ] || MODEL=codex

# Don't double-record: if an identical (agent,status,artifact) codex row already exists for this
# call's artifact+status, skip (the supervisor-snippet path may have already written it).
if [ -f "$PROV" ] && [ -n "$ART" ] \
   && grep -qE "agent=codex-adversarial-reviewer\|.*status=${STATUS}\|.*artifact=${ART}" "$PROV" 2>/dev/null; then
  exit 0
fi
printf 'DISPATCH|ts=%s|agent=codex-adversarial-reviewer|mode=codex_cli_witness|status=%s|submodel=%s|cost_usd=|duration_ms=|artifact=%s|sha256=%s\n' \
  "$TS" "$STATUS" "$MODEL" "${ART:-}" "$SHA" >> "$PROV" 2>/dev/null || true
exit 0
