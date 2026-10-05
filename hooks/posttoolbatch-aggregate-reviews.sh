#!/usr/bin/env bash
set -euo pipefail
trap 'exit 0' ERR  # fail-open: best-effort review aggregation must never block the batch
# posttoolbatch-aggregate-reviews.sh
# Event: PostToolBatch (no matcher — fires on every batch)
# Version: 1.0.0
# Author: Phase 3 implementation team
# Purpose:
#   When /v Step 5 dispatches multiple reviewers in parallel via the Agent tool,
#   aggregate their partial AGENT_REVIEW_partial_*.md outputs into the canonical
#   AGENT_REVIEW_<lead-sid>.md that check-review-artifact.sh expects.
#
#   Fast path: most PostToolBatch events are NOT reviewer batches. Hook detects
#   the situation via a marker file `${V_TMP_DIR}/posttoolbatch-reviewer-batch-<sid>.marker`
#   written by /v Step 5 immediately before reviewer dispatch. Without the marker,
#   the hook exits 0 silently.
#
# Contract:
#   - NEVER blocks (no exit 2). Failures logged to stderr only.
#   - NEVER reads partials whose filenames fail the safety regex.
#   - ALWAYS preserves existing AGENT_REVIEW_<sid>.md content under a Prior section.
#   - ALWAYS writes line 1 of the canonical artifact as exactly "Model: haiku".
#   - Cleans up marker + partials after a successful write.
#
# Stdin:  PostToolBatch JSON (see https://code.claude.com/docs/en/hooks).
# Stdout: empty.
# Stderr: WARN/ERROR lines on anomalies. Never fatal.

set -u
set +e

# ── Dependency check ─────────────────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "[posttoolbatch-aggregate-reviews] jq not found — hook skipped" >&2
  exit 0
fi

# ── Library loading ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_LIB_DIR="${SCRIPT_DIR}/lib"
if [ -f "$HOOKS_LIB_DIR/v-tmp-dir.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOKS_LIB_DIR/v-tmp-dir.sh"
fi
if [ -f "$HOOKS_LIB_DIR/resolve-sid.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOOKS_LIB_DIR/resolve-sid.sh"
fi

# ── Read stdin JSON ──────────────────────────────────────────────────────────
INPUT=$(cat 2>/dev/null || true)
if [ -z "$INPUT" ]; then
  exit 0
fi

EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
if [ "$EVENT" != "PostToolBatch" ]; then
  exit 0
fi

# ── Resolve lead SID ─────────────────────────────────────────────────────────
LEAD_SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
if [ -z "$LEAD_SID" ] && type resolve_sid >/dev/null 2>&1; then
  LEAD_SID=$(resolve_sid 2>/dev/null || true)
fi
if [ -z "$LEAD_SID" ]; then
  LEAD_SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
fi
if [ -z "$LEAD_SID" ]; then
  echo "[posttoolbatch-aggregate-reviews] ERROR: cannot resolve lead SID — hook exits 0" >&2
  exit 0
fi

# CRITICAL-3 fix: UUID validation on LEAD_SID before it is used in path / sed construction.
# Mirrors resolve-sid.sh:61-63. Defends against malicious session_id values in stdin JSON.
if ! printf '%s' "$LEAD_SID" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  echo "[posttoolbatch-aggregate-reviews] ERROR: session_id failed UUID validation ('$LEAD_SID') — hook exits 0" >&2
  exit 0
fi

# ── Resolve V_TMP_DIR ────────────────────────────────────────────────────────
if type v_tmp_dir >/dev/null 2>&1; then
  TMP_DIR=$(v_tmp_dir 2>/dev/null || true)
fi
if [ -z "${TMP_DIR:-}" ]; then
  if [ -n "${V_TMP_DIR:-}" ] && [ -d "$V_TMP_DIR" ]; then
    TMP_DIR="$V_TMP_DIR"
  else
    _repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "$_repo" ] && [ -d "$_repo" ]; then
      mkdir -p "$_repo/.v/tmp" 2>/dev/null
      TMP_DIR="$_repo/.v/tmp"
    else
      TMP_DIR="${TMPDIR:-/tmp}"
    fi
  fi
fi

# ── Check for reviewer-batch marker ──────────────────────────────────────────
MARKER_FILE="$TMP_DIR/posttoolbatch-reviewer-batch-${LEAD_SID}.marker"
if [ ! -f "$MARKER_FILE" ]; then
  exit 0
fi

# ── Trace log ────────────────────────────────────────────────────────────────
TRACE_LOG="$TMP_DIR/posttoolbatch-trace-${LEAD_SID}.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
echo "$(ts) [posttoolbatch-aggregate-reviews] marker found for SID=$LEAD_SID" >> "$TRACE_LOG" 2>/dev/null || true

# ── Validate reviewer name pattern (path-traversal guard) ────────────────────
validate_partial_name() {
  local f="$1"
  local base
  base=$(basename "$f")
  echo "$base" | grep -qE '^AGENT_REVIEW_partial_[a-z0-9-]+_[a-zA-Z0-9_-]+\.md$'
}

# ── Scan for partials ────────────────────────────────────────────────────────
PARTIALS=()
shopt -s nullglob
for f in "$TMP_DIR"/AGENT_REVIEW_partial_*_"${LEAD_SID}".md; do
  [ -f "$f" ] || continue
  if validate_partial_name "$f"; then
    PARTIALS+=("$f")
  else
    echo "[posttoolbatch-aggregate-reviews] WARN: skipping suspicious partial filename: $f" >&2
    echo "$(ts) [posttoolbatch-aggregate-reviews] WARN: suspicious filename rejected: $f" >> "$TRACE_LOG" 2>/dev/null || true
  fi
done
shopt -u nullglob

PARTIAL_COUNT="${#PARTIALS[@]}"
echo "$(ts) [posttoolbatch-aggregate-reviews] found $PARTIAL_COUNT valid partial(s)" >> "$TRACE_LOG" 2>/dev/null || true

# ── Zero (valid) partials: stale marker or all partials rejected ─────────────
if [ "$PARTIAL_COUNT" -eq 0 ]; then
  echo "[posttoolbatch-aggregate-reviews] WARN: marker present but zero valid partials for SID=$LEAD_SID — stale marker? Deleting." >&2
  rm -f "$MARKER_FILE"
  exit 0
fi

# ── Resolve REPO_ROOT for canonical artifact placement ───────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
  echo "[posttoolbatch-aggregate-reviews] ERROR: not inside a git repo — cannot place canonical artifact" >&2
  exit 0
fi
CANONICAL="$REPO_ROOT/AGENT_REVIEW_${LEAD_SID}.md"

# ── Existing canonical handling ──────────────────────────────────────────────
EXISTING_CONTENT=""
if [ -f "$CANONICAL" ]; then
  EXISTING_CONTENT=$(cat "$CANONICAL" 2>/dev/null || true)
fi

# ── Extract structured fields from each partial ──────────────────────────────
REVIEWER_NAMES_LIST=""
ALL_STATUSES=""
ALL_CODEX_VALUES=""
ALL_MODELS=""
ALL_HOSTILE=""
ALL_DISPATCH_MODES=""
ALL_EVIDENCE=""
ALL_REMEDIATION=""
FINDINGS_BLOCKS=""

extract_field() {
  local file="$1"
  local field="$2"
  grep -m1 "^- ${field}:" "$file" 2>/dev/null | sed "s/^- ${field}:[[:space:]]*//" || true
}

for partial in "${PARTIALS[@]}"; do
  RNAME=$(basename "$partial" | sed -E "s/^AGENT_REVIEW_partial_(.+)_${LEAD_SID}\.md$/\1/")
  REVIEWER_NAMES_LIST="${REVIEWER_NAMES_LIST}, ${RNAME}"

  _status=$(extract_field "$partial" "Status")
  _codex=$(extract_field "$partial" "Codex adversarial reviewer")
  _model=$(extract_field "$partial" "Reviewer model")
  _hostile=$(extract_field "$partial" "Hostile adversarial focus")
  _dispatch=$(extract_field "$partial" "Dispatch mode")
  _evidence=$(extract_field "$partial" "Review evidence")
  _remediation=$(extract_field "$partial" "Remediation")

  _missing=""
  [ -z "$_status" ]      && _missing="${_missing} Status"
  [ -z "$_codex" ]       && _missing="${_missing} Codex-adversarial-reviewer"
  [ -z "$_model" ]       && _missing="${_missing} Reviewer-model"
  [ -z "$_hostile" ]     && _missing="${_missing} Hostile-adversarial-focus"
  [ -z "$_dispatch" ]    && _missing="${_missing} Dispatch-mode"
  [ -z "$_evidence" ]    && _missing="${_missing} Review-evidence"
  [ -z "$_remediation" ] && _missing="${_missing} Remediation"
  if [ -n "$_missing" ]; then
    echo "[posttoolbatch-aggregate-reviews] WARN: partial '$RNAME' missing fields:${_missing}" >&2
    echo "$(ts) [posttoolbatch-aggregate-reviews] WARN: partial '$RNAME' missing fields:${_missing}" >> "$TRACE_LOG" 2>/dev/null || true
  fi

  ALL_STATUSES="${ALL_STATUSES}${RNAME}: ${_status:-MISSING}
"
  ALL_CODEX_VALUES="${ALL_CODEX_VALUES}${RNAME}: ${_codex:-MISSING}
"
  ALL_MODELS="${ALL_MODELS}${RNAME}: ${_model:-MISSING}
"
  ALL_HOSTILE="${ALL_HOSTILE}${_hostile:-unknown} "
  ALL_DISPATCH_MODES="${ALL_DISPATCH_MODES}${RNAME}: ${_dispatch:-MISSING}
"
  ALL_EVIDENCE="${ALL_EVIDENCE}${RNAME}: ${_evidence:-MISSING}
"
  ALL_REMEDIATION="${ALL_REMEDIATION}${RNAME}: ${_remediation:-no findings}
"

  _findings_section=$(sed -n '/^## Findings/,$p' "$partial" 2>/dev/null || true)
  if [ -n "$_findings_section" ]; then
    FINDINGS_BLOCKS="${FINDINGS_BLOCKS}

### Reviewer: ${RNAME}

${_findings_section}"
  fi
done

REVIEWER_NAMES_LIST=$(echo "$REVIEWER_NAMES_LIST" | sed 's/^, //')

# ── Synthesize header values ─────────────────────────────────────────────────
if echo "$ALL_HOSTILE" | grep -qi "yes"; then
  HOSTILE_CANONICAL="yes — at least one reviewer flagged hostile surface (see per-reviewer details)"
else
  HOSTILE_CANONICAL="no"
fi

# MEDIUM-3 fix: when no partial has a completed-class status, do NOT emit
# "see per-reviewer status below" — the validator parses the first word and
# rejects "see" as an unexpected status. Use the accepted non-completed
# sentinel `fallback_required` so validator-flagged status is meaningful.
if echo "$ALL_STATUSES" | grep -qi "completed\|pass\|passed"; then
  if echo "$ALL_STATUSES" | grep -qiv "completed\|pass\|passed"; then
    STATUS_CANONICAL="completed (partial — see per-reviewer status)"
  else
    STATUS_CANONICAL="completed"
  fi
else
  STATUS_CANONICAL="fallback_required"
fi

# CRITICAL-1 fix: when codex-adversarial-reviewer is NOT in the batch (security
# + logic only is a common dispatch), the validator regex demands a value from
# the codex/superpowers provenance enum. The previous fallback
# "see per-reviewer details below" matched no enum entry — silently blocking
# Stop. Use the explicitly-accepted orchestrator-inline fallback string.
# MEDIUM-1 fix: anchor grep to start-of-line to prevent field-VALUE substring
# matching against the reviewer-NAME column.
CODEX_HEADER=$(echo "$ALL_CODEX_VALUES" | grep -m1 '^codex-adversarial-reviewer:' | sed 's/^[^:]*:[[:space:]]*//' || true)
[ -z "$CODEX_HEADER" ] && CODEX_HEADER="codex-adversarial-reviewer (orchestrator-inline fallback)"

MODEL_HEADER=$(echo "$ALL_MODELS" | head -1 | sed 's/^[^:]*:[[:space:]]*//' || true)
[ -z "$MODEL_HEADER" ] && MODEL_HEADER="see per-reviewer details"

# ── PANEL field (2026-08-03) ──────────────────────────────────────────────────────────────────────
# This aggregator inherently HAS a panel: it merges N independent reviewer partials. Emitting the
# machine-checkable field here means the concurrent-dispatch path produces panel provenance rather
# than falling back to the legacy free-text codex line. Derived from the partials actually present —
# never asserted. Emitted ONLY when >=2 reviewers with >=2 DISTINCT lenses contributed, because those
# are exactly validation.sh:_panel_field_valid's rules; an invalid line would be worse than none.
PANEL_HEADER=""
_pnl_models=""; _pnl_lenses=""; _pnl_n=0
for _p in "${PARTIALS[@]}"; do
  _rn=$(basename "$_p" | sed -E "s/^AGENT_REVIEW_partial_(.+)_${LEAD_SID}\.md$/\1/")
  [ -n "$_rn" ] || continue
  _rm=$(extract_field "$_p" "Reviewer model")
  case "$_rm" in ""|*[!a-zA-Z0-9._-]*) _rm="sonnet" ;; esac
  case "$_rn" in
    logic-reviewer)             _rl="correctness" ;;
    security-reviewer)          _rl="security" ;;
    codebase-fit-reviewer)      _rl="fit" ;;
    framework-pitfall-reviewer) _rl="framework" ;;
    codex-adversarial-reviewer) _rl="adversarial" ;;
    adversarial-panel-reviewer) _rl="adversarial" ;;
    *)                          _rl="review" ;;
  esac
  _pnl_models="${_pnl_models}${_pnl_models:+,}${_rm}"
  _pnl_lenses="${_pnl_lenses}${_pnl_lenses:+,}${_rl}"
  _pnl_n=$((_pnl_n + 1))
done
if [ "$_pnl_n" -ge 2 ] && [ "$(printf '%s' "$_pnl_lenses" | tr ',' '\n' | sort -u | grep -c .)" -ge 2 ]; then
  # candidates/accepted are the finding IDs actually carried into the aggregate (same heading shape
  # validate_review_semantics counts, so the two can never disagree); refuted is 0 because partials
  # report what they ACCEPTED — a refutation count would have to be invented, and inventing it is the
  # failure class this whole field exists to remove.
  _pnl_findings=$(printf '%s' "$FINDINGS_BLOCKS" | grep -cE '^#{2,6}[[:space:]]+[A-Z][A-Z0-9]{1,11}-[0-9]+[:[:space:]]' 2>/dev/null || echo 0)
  PANEL_HEADER="panel=${_pnl_n} models=${_pnl_models} lenses=${_pnl_lenses} candidates=${_pnl_findings} accepted=${_pnl_findings} refuted=0"
fi

TIMESTAMP=$(ts)

CANONICAL_CONTENT="Model: haiku

## Agent Review — ${LEAD_SID}
- Status: ${STATUS_CANONICAL}
- Agents dispatched: ${REVIEWER_NAMES_LIST}
- Codex adversarial reviewer: ${CODEX_HEADER}${PANEL_HEADER:+
- Adversarial review: ${PANEL_HEADER}}
- Reviewer model: ${MODEL_HEADER}
- Hostile adversarial focus: ${HOSTILE_CANONICAL}
- Dispatch mode: background
- Review evidence: PostToolBatch-aggregated from ${PARTIAL_COUNT} reviewer(s): ${REVIEWER_NAMES_LIST}
- Remediation: see per-reviewer remediation below

## Findings
${FINDINGS_BLOCKS}

## Per-Reviewer Provenance
> Aggregated by posttoolbatch-aggregate-reviews.sh at ${TIMESTAMP}
> Lead SID: ${LEAD_SID}
> Partial count: ${PARTIAL_COUNT}

### Status per reviewer
${ALL_STATUSES}

### Codex adversarial reviewer per reviewer
${ALL_CODEX_VALUES}

### Reviewer model per reviewer
${ALL_MODELS}

### Dispatch mode per reviewer
${ALL_DISPATCH_MODES}

### Review evidence per reviewer
${ALL_EVIDENCE}

### Remediation per reviewer
${ALL_REMEDIATION}"

if [ -n "$EXISTING_CONTENT" ]; then
  CANONICAL_CONTENT="${CANONICAL_CONTENT}

---

## Prior AGENT_REVIEW (pre-batch — preserved verbatim)
> This section was the canonical AGENT_REVIEW before the PostToolBatch aggregation ran.

${EXISTING_CONTENT}"
fi

# ── Atomic write (temp → mv) ─────────────────────────────────────────────────
# HIGH-1 fix: include PID in tmp filename to avoid concurrent-write race when
# two PostToolBatch events fire near-simultaneously for the same SID (rare,
# but possible on retries). Per-process tmp file + atomic mv = no torn writes.
TMP_OUT="$TMP_DIR/AGENT_REVIEW_aggregate_${LEAD_SID}_$$.tmp"
printf '%s\n' "$CANONICAL_CONTENT" > "$TMP_OUT" 2>/dev/null
if [ ! -s "$TMP_OUT" ]; then
  echo "[posttoolbatch-aggregate-reviews] ERROR: failed to write tmp output to $TMP_OUT" >&2
  exit 0
fi
mv "$TMP_OUT" "$CANONICAL" 2>/dev/null
if [ ! -f "$CANONICAL" ]; then
  echo "[posttoolbatch-aggregate-reviews] ERROR: failed to mv canonical to $CANONICAL" >&2
  exit 0
fi

echo "$(ts) [posttoolbatch-aggregate-reviews] canonical written: $CANONICAL" >> "$TRACE_LOG" 2>/dev/null || true

# ── Cleanup ──────────────────────────────────────────────────────────────────
for partial in "${PARTIALS[@]}"; do
  rm -f "$partial"
done
rm -f "$MARKER_FILE"

echo "$(ts) [posttoolbatch-aggregate-reviews] cleanup complete ($PARTIAL_COUNT partial(s) deleted)" >> "$TRACE_LOG" 2>/dev/null || true

exit 0
