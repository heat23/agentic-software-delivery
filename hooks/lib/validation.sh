#!/usr/bin/env bash
# lib/validation.sh — shared artifact validation functions.
#
# Usage:
#   source "$HOOKS_LIB_DIR/lib/validation.sh"
#   validate_artifact "$path" "AGENT_REVIEW" || echo "invalid"
#   is_completion_language "$msg" && echo "completion detected"
#
# AVF-004: Centralises artifact validation to prevent trivial spoofing via
# keyword grep. Checks file size (>=${VALIDATION_MIN_SIZE} bytes; lowered from 500 by W39-D) and required section headers.
# AVF-029: Centralises completion language patterns to close false-negative gaps.
#
# === HOOK AUDIT W22+ PATCHES ===
# HOOK-1 (CRITICAL): Accept Model: (haiku|sonnet|opus) — W13 tiered review models.
# HOOK-4 (CRITICAL): Accept ORCHESTRATOR_INLINE / superpowers fallback provenance instead of
#   blanket-rejecting "self-review" / "degraded" — those are valid Wave 13 fallbacks.
# HOOK-8 (HIGH): Harmonize HOSTILE_REVIEW_PATH_PATTERN with orchestrator's W20 pattern.

# Minimum artifact size in bytes — guards against trivial spoofs.
# W39-D: lowered from 500 to 100. The 500 floor caused production rewrite
# loops on legitimate small reports (e.g., a 499-byte report
# rejected as 1 byte under). 100 still catches ~all real spoofs while
# accommodating concise but valid artifacts.
VALIDATION_MIN_SIZE=100

# 1A (survival gate): make the per-session writes-log helpers (get_session_writes /
# session_writes_log_path) available to ANY caller of this lib, so _survival_verdict resolves the
# SAME writes-log under BOTH the Stop hook and the producer self-check (parity by construction).
# Guarded + idempotent — a caller that already sourced it is unaffected.
if ! type get_session_writes >/dev/null 2>&1; then
  # FIX-#33 (forensic 2026-06-22): robust sub-lib resolution. The single BASH_SOURCE/cwd-derived path had NO
  # fallback — if that one resolution ever hiccupped, get_session_writes was silently left undefined, which is
  # the intermittent, sweep-context-only "_survival_verdict/get_session_writes not available from validation.sh"
  # flake. A flaky GATE can mask a real regression, so harden the resolution: try the BASH_SOURCE-derived dir,
  # then HOOKS_LIB_DIR, then the canonical install path — additive + idempotent; the helper is found via
  # whichever resolves first. (The flake did not reproduce in 24 serial+parallel runs; this eliminates the one
  # no-fallback fragility on the source path rather than guess at the unreproduced race.)
  _vdir_sw="$(cd "$(dirname "${BASH_SOURCE[0]:-$HOME/.claude/hooks/lib/validation.sh}")" 2>/dev/null && pwd)"
  for _swc in "${_vdir_sw:-}/session-writes.sh" "${HOOKS_LIB_DIR:-}/session-writes.sh" "$HOME/.claude/hooks/lib/session-writes.sh"; do
    [ -f "$_swc" ] && { . "$_swc"; break; }
  done
  unset _vdir_sw _swc
fi

# Completion language detection pattern (AVF-029 — extended phrase list).
# Used by: check-review-artifact.sh, uncommitted-changes-gate.sh
COMPLETION_WORDS_PATTERN="complet|done([^a-z]|\$)|finish|implement|fix(ed|ing)|resolv|ship|ready|working|merged|applied|created|updated|all[[:space:]]+(changes|files|tasks)|accomplish|deliver|deploy|land|wrap|merge|finalize"

# HOOK-8: Sensitive-path pattern — harmonized with orchestrator's W20 pattern.
# Matches paths whose changes warrant hostile adversarial review focus.
# Keep this path-based and explicit to avoid turning every routine UI/session
# change into a false-positive hostile-review requirement.
HOSTILE_REVIEW_PATH_PATTERN='(^|/)(auth|oauth|jwt|sso|saml|oidc|login|register|password|session-token|csrf|csrf-token|hmac|signature|cookie|nonce|salt|token|secret|key|credential|crypto|cipher|encrypt|encryption|sanctum|passport|billing|payment|stripe|cashier|subscription|checkout|invoice|webhook|upload|storage|admin|2fa|mfa|rbac|policy|policies|middleware|private)([/_.-]|$)'

# Allowed review-model values (HOOK-1: W13 introduced sonnet/opus tiering).
# When validation.sh checks the AGENT_REVIEW Model: line, accept any of these.
# W71 (2026-07-02): + fable — the Claude 5 family tier above opus is now a real
# reviewer model (codex-quota-degraded sessions dispatch Fable subprocess
# reviewers); rejecting the honest label would force mislabeling the model.
ALLOWED_REVIEW_MODELS='haiku|sonnet|opus|fable'

# validate_artifact <artifact_path> <artifact_type>
#
# artifact_type values: PRE_FLIGHT_REPORT | AGENT_REVIEW | VERIFY_DONE_REPORT
#
# Checks:
#   1. File exists and is non-empty
#   2. Minimum file size >=${VALIDATION_MIN_SIZE} bytes (trivial-spoof guard; lowered from 500 by W39-D)
#   3. Required section headers present for the given artifact type
#
# Returns: 0 if valid, 1 if invalid (reason printed to stderr)
validate_artifact() {
  local artifact_path="$1"
  local artifact_type="${2:-UNKNOWN}"

  # 1. File existence
  if [[ ! -f "$artifact_path" ]]; then
    echo "artifact does not exist: $artifact_path" >&2
    return 1
  fi

  # 2. Non-empty
  if [[ ! -s "$artifact_path" ]]; then
    echo "artifact is empty: $artifact_path" >&2
    return 1
  fi

  # 3. Minimum size (wc -c counts bytes; compatible with macOS/Linux)
  local file_size
  file_size=$(wc -c < "$artifact_path" 2>/dev/null | tr -d ' ')
  if [[ -z "$file_size" || "$file_size" -lt "$VALIDATION_MIN_SIZE" ]]; then
    echo "artifact too small (${file_size:-0} bytes, min ${VALIDATION_MIN_SIZE}): $artifact_path" >&2
    return 1
  fi

  # 3.5. W39 review F6: content-marker check. Even at 100-byte minimum, a
  # garbage 105-byte file could pass. Require the artifact to contain at
  # LEAST one of: a Status line, a section header (## ...), or an Overall:
  # marker. This catches "lorem ipsum" stubs without requiring strict format.
  if ! grep -qiE '^([[:space:]#>*-]*\**[[:space:]]*status:|##[[:space:]]|overall:[[:space:]]|[[:space:]#>*-]*\**[[:space:]]*model:[[:space:]])' "$artifact_path" 2>/dev/null; then
    echo "artifact missing minimum content marker (no Status:, ## section, Overall:, or Model: line): $artifact_path" >&2
    return 1
  fi

  # 4. Required section headers by artifact type — W39-D: ADVISORY ONLY.
  #
  # Production friction: every session ended in a 3-5 minute rewrite loop
  # because the section-header strict check would reject a valid report that
  # used "## Convention Checks" instead of "## Verification" or "## Checks",
  # or "## Gate Results" instead of "## Test Results" / "## Gates".
  # The orchestrator would rewrite the report repeatedly until the validator
  # accepted it. None of these rewrites caught real bugs — they were pure
  # format friction.
  #
  # W39-D: Emit a warning to stderr but return 0 (success). Real fabrication
  # is caught by the W34 fabrication detector at content level (small file +
  # missing content marker + older real twin). The format check here is now
  # purely informational.
  case "$artifact_type" in
    PRE_FLIGHT_REPORT)
      if ! grep -qiE '^##[[:space:]]+(Test Results|Gates|Gate Results|Pre-Flight)' "$artifact_path" 2>/dev/null; then
        echo "ADVISORY: PRE_FLIGHT_REPORT preferred section header is '## Gates' or '## Test Results' (W39-D: not blocking)" >&2
      fi
      ;;
    AGENT_REVIEW)
      if ! grep -qiE '^##[[:space:]]+(Findings|Review|Issues)' "$artifact_path" 2>/dev/null; then
        echo "ADVISORY: AGENT_REVIEW preferred section header is '## Findings' or '## Review' (W39-D: not blocking)" >&2
      fi
      ;;
    VERIFY_DONE_REPORT)
      if ! grep -qiE '^##[[:space:]]+(Verification|Checks|Convention Checks|Convention)' "$artifact_path" 2>/dev/null; then
        echo "ADVISORY: VERIFY_DONE_REPORT preferred section header is '## Checks' or '## Verification' (W39-D: not blocking)" >&2
      fi
      ;;
    *)
      ;;
  esac

  return 0
}

# validate_verify_done_w53_contract <path>
# W53-F1: enforce structural contract on VERIFY_DONE_REPORT.
# Returns 0 if valid, 1 if not (reason printed to stderr).
# Permissive on Mode VALUE (legacy enums accepted) — strict on PRESENCE.
#
# Production motivation: two production sessions (May 2026) demonstrated
# that haiku verify-done runners drop the W52-F2 Mode/Changed/Summary/Verdict
# contract entirely while validate_artifact's W39-D advisory check let them
# through. This contract is FIELDS-based, not header-keyword based — safer for
# backward compat than re-introducing strict header-keyword enforcement.
validate_verify_done_w53_contract() {
  local f="$1"
  [ -f "$f" ] || { echo "verify-done: file missing"; return 1; }

  # Skip YAML frontmatter when scanning for Mode: (mirrors the AGENT_REVIEW
  # frontmatter handling at line 223). M3 review-fix.
  local _head
  _head=$(awk 'BEGIN{in_fm=0; n=0}
    NR==1 && /^---[[:space:]]*$/ {in_fm=1; next}
    in_fm==1 && /^---[[:space:]]*$/ {in_fm=0; next}
    in_fm==1 {next}
    {print; n++; if(n>=12) exit}' "$f" 2>/dev/null)

  # E1 (efficiency, 2026-07-05): these four checks are mutually INDEPENDENT
  # (Mode:/Changed:/## Summary/Overall Verdict: each scan a different part of
  # the file) — batch them into ONE manifest instead of returning on the
  # first miss. Before this fix, a report missing both 'Mode:' and 'Changed:'
  # round-tripped a full dispatch cycle per field (fix Mode, re-dispatch,
  # discover Changed is ALSO missing, fix, re-dispatch...). Mirrors the O4/P1
  # batching precedent already applied to validate_review_semantics above —
  # same rationale, same convention: foundational file-existence checks stay
  # early-return, independent field-presence checks batch into one message.
  local _errs=""
  _vd_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }

  # 1. Mode: line present. Permissive value matcher: accepts the W52 enum
  #    (full|scoped(writes-log)|scoped(fallback-git-state)|user-owned-maintenance)
  #    plus legacy values (scoped, dirty-tree) plus optional trailing
  #    parenthetical or descriptive text. Only PRESENCE is enforced — the W52
  #    enum is dispatch-side advisory.
  if ! echo "$_head" | grep -qE '^Mode:[[:space:]]+(full|scoped(\([^)]*\))?|dirty-tree|user-owned-maintenance)([[:space:]].*)?[[:space:]]*$'; then
    _vd_add "verify-done: missing 'Mode:' line in first 12 lines (or value not recognized — accepted forms: full | scoped | scoped(writes-log) | scoped(fallback-git-state) | dirty-tree | user-owned-maintenance, with optional trailing free-text)"
  fi

  # 2. Changed: line present (integer value).
  if ! echo "$_head" | grep -qE '^Changed:[[:space:]]+[0-9]+[[:space:]]*$'; then
    _vd_add "verify-done: missing 'Changed: <N>' line in first 12 lines"
  fi

  # 3. ## Summary H2 present (allow trailing free-text per B2).
  if ! grep -qE '^##[[:space:]]+Summary([[:space:]].*)?$' "$f"; then
    _vd_add "verify-done: missing '## Summary' H2 section"
  fi

  # 4. Final non-empty line is 'Overall Verdict: PASS|FAIL' (allow trailing
  #    parenthetical per B3). awk pipeline finds the last non-blank line.
  local _last
  _last=$(awk 'NF { last=$0 } END { print last }' "$f")
  if ! echo "$_last" | grep -qE '^Overall Verdict:[[:space:]]+(PASS|FAIL)([[:space:]]+\(.*\))?[[:space:]]*$'; then
    _vd_add "verify-done: final non-empty line must be 'Overall Verdict: PASS' or 'Overall Verdict: FAIL' (got: '$_last')"
  fi

  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# validate_pre_flight_w53_contract <path>
# W53-F1 (H1 review-fix): mirror the structural enforcement on PRE_FLIGHT_REPORT.
# Same motivation: silent fallback hides regressions; PRE_FLIGHT and VERIFY_DONE
# both leak the same way under W52.
validate_pre_flight_w53_contract() {
  local f="$1"
  [ -f "$f" ] || { echo "pre-flight: file missing"; return 1; }

  local _head
  _head=$(awk 'BEGIN{in_fm=0; n=0}
    NR==1 && /^---[[:space:]]*$/ {in_fm=1; next}
    in_fm==1 && /^---[[:space:]]*$/ {in_fm=0; next}
    in_fm==1 {next}
    {print; n++; if(n>=12) exit}' "$f" 2>/dev/null)

  # E1 (efficiency, 2026-07-05): batch the two independent presence checks
  # into one manifest — same rationale as validate_verify_done_w53_contract
  # above (a report missing BOTH 'Mode:' and 'Overall Status:' used to cost
  # two dispatch round-trips to discover, one field at a time).
  local _errs=""
  _pf_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }

  # PRE_FLIGHT historically uses Mode: scoped|full|dirty-tree (per
  # dispatch-v-pre-flight.md:339). Same permissive matcher as VERIFY_DONE.
  if ! echo "$_head" | grep -qE '^Mode:[[:space:]]+(full|scoped(\([^)]*\))?|dirty-tree|user-owned-maintenance)([[:space:]].*)?[[:space:]]*$'; then
    _pf_add "pre-flight: missing 'Mode:' line in first 12 lines"
  fi

  # Final non-empty line is 'Overall Status: PASS|FAIL' (PRE_FLIGHT uses
  # 'Status' not 'Verdict' per its own template at dispatch-v-pre-flight.md:358).
  local _last
  _last=$(awk 'NF { last=$0 } END { print last }' "$f")
  if ! echo "$_last" | grep -qE '^Overall Status:[[:space:]]+(PASS|FAIL)([[:space:]]+\(.*\))?[[:space:]]*$'; then
    _pf_add "pre-flight: final non-empty line must be 'Overall Status: PASS' or 'Overall Status: FAIL' (got: '$_last')"
  fi

  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# is_completion_language <message>
# Returns 0 if the message contains completion language, 1 otherwise.
is_completion_language() {
  local msg="$1"
  echo "$msg" | grep -qiE "$COMPLETION_WORDS_PATTERN"
}

# review_requires_hostile_focus_from_paths <newline-delimited-paths>
# Returns 0 when any changed path implies hostile review focus is required.
#
# W45-D: filter out pure UI asset paths before matching. Production saw
# `plugins/example-plugin/assets/admin.css` and similar trip the hostile-
# focus requirement just because the filename contained the substring
# "admin". CSS / images / markdown / static-asset changes cannot introduce
# auth, payment, crypto, or data-mutation issues regardless of their
# directory name; they shouldn't auto-trigger a hostile review.
#
# Code files (.php, .ts/.tsx/.js, route configs, migrations, JSON/YAML
# config-as-code) ARE still in scope — composer.json, package.json,
# .github/workflows/*.yml all CAN affect security and stay in the matcher.
review_requires_hostile_focus_from_paths() {
  local paths="${1:-}"
  [ -n "$paths" ] || return 1
  # Pure UI assets — extensions where a change cannot meaningfully alter
  # auth/payment/data flow. Stripped BEFORE the security-pattern match.
  local code_paths
  code_paths=$(echo "$paths" \
    | grep -ivE '\.(css|scss|sass|less|html?|png|jpe?g|gif|svg|webp|ico|bmp|tiff|md|markdown|txt|rst)$' \
    || true)
  [ -n "$code_paths" ] || return 1
  echo "$code_paths" | grep -qiE "$HOSTILE_REVIEW_PATH_PATTERN"
}

# validate_review_semantics <review_file> [require_executed=1] [hostile_required=0] [session_id]
#
# Semantic validation for AGENT_REVIEW artifacts. Presence-only checks are too
# weak; this requires provenance that proves the mandated codex/superpowers
# review path actually ran for sessions with code changes.
validate_review_semantics() {
  local review_file="$1"
  local require_executed="${2:-1}"
  local hostile_required="${3:-0}"
  local expected_session_id="${4:-}"
  # O2 (codex CODEX-001): the honest-degraded relaxation below is OPT-IN. Only callers that ALSO run
  # _independence_verdict on this artifact (the Stop hook check-review-artifact.sh + the producer
  # v-completion-selfcheck.sh) may pass 1 — they have the forgery backstop that blocks a fake "codex ran"
  # and marks an honest inline review `declared`→warn. The STANDALONE commit-deny gates
  # (enforce-pre-commit-gates.sh / uncommitted-changes-gate.sh) leave this 0 → strict (a code session must
  # show real codex/superpowers provenance before it may commit), exactly as before O2 (no regression).
  local allow_declared_degraded="${5:-0}"
  local status=""
  local model_line=""
  local agents_line=""
  local codex_line=""
  local hostile_line=""
  local dispatch_line=""
  local evidence_line=""
  local remediation_line=""
  # P1 (fleet forensic 2026-06-20): accumulate the CONTENT-HONESTY failures (evidence-markers, dispatch
  # cluster, hostile-focus, unresolved-serious) and flush them in ONE error at the end, instead of
  # returning on the FIRST. One session rewrote AGENT_REVIEW 9× / another re-blocked 6× because provenance
  # surfaced one Stop-cycle and hostile-focus the next. These checks are mutually INDEPENDENT and any one
  # still blocks, so batching changes only the MESSAGE, never the block/accept DECISION. The foundational
  # checks above (file/status/model/session-id/self-review/field-presence) stay early-return: they gate
  # whether the artifact is even well-formed enough to evaluate content, and (O4) field-presence is
  # already batched. Append with _verr_add; flushed just before `return 0`.
  local _errs=""
  _verr_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }

  [ -f "$review_file" ] || {
    echo "review artifact file does not exist"
    return 1
  }

  # Bound search to first 20 lines (metadata block) to prevent finding-body Status: text from being parsed as the metadata status. A production session hit this with 'Status: Acceptable given tech stack' in a finding description.
  # W36-B: extract only the FIRST WORD as status. Prior version stripped ALL
  # spaces ("approved — no critical findings" → "approved—nocriticalorhighfindings"
  # after lowercase + tr -d ' '), causing the case match to reject perfectly valid
  # statuses with descriptive trailing text. A production session (2026-05-02)
  # hit this with "**Status:** APPROVED — no critical or high findings".
  #
  # Extraction pipeline:
  #   1. grep status line in first 20 lines
  #   2. strip leading markdown/list/quote chars + "Status:" prefix
  #   3. take first whitespace-delimited token (awk '{print $1}')
  #   4. lowercase
  #   5. strip trailing punctuation (em-dash, hyphen, asterisk, period, comma)
  status=$(head -20 "$review_file" 2>/dev/null \
    | grep -iE '^[[:space:]#>*-]*\**[[:space:]]*status\**:[[:space:]]*' \
    | head -1 \
    | sed 's/^[[:space:]#>*-]*\**[[:space:]]*[Ss]tatus\**:[[:space:]]*//' \
    | awk '{print $1}' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[*.,—-]*$//')
  if [ -z "$status" ]; then
    echo "missing status line"
    return 1
  fi

  case "$status" in
    completed|pass|passed|approved)
      ;;
    skipped|skip|fallback_required|fail|failed|error|blocked|not_applicable)
      echo "non-completed review status: $status"
      return 1
      ;;
    *)
      echo "unexpected review status: $status"
      return 1
      ;;
  esac

  # HOOK-1: accept Model: (haiku|sonnet|opus) — W13 tiered review models.
  # The orchestrator's W12-2 wrap rule writes line 1 as `Model: haiku` regardless
  # of the actual reviewer model (the actual model goes in `Reviewer model:` field).
  # But if the orchestrator forgot to wrap, the dispatched agent's line 1 is the
  # actual model. Accept either.
  # W42-F4: skip YAML frontmatter (--- ... ---) before scanning for Model:.
  # Some runner agents emit frontmatter, pushing the Model: line past line 5.
  # awk skips lines until past the closing --- (if any), then takes first 15.
  model_line=$(awk 'BEGIN{in_fm=0; fm_done=0} NR==1 && /^---[[:space:]]*$/ {in_fm=1; next} in_fm==1 && /^---[[:space:]]*$/ {in_fm=0; fm_done=1; next} in_fm==1 {next} {print; n++; if(n>=15) exit}' "$review_file" 2>/dev/null | grep -iE '^Model:[[:space:]]*' | head -1 || true)
  if [ -z "$model_line" ]; then
    echo "missing Model: declaration near top of artifact"
    return 1
  fi
  # N1 (forensic 2026-06-17): also accept the FULL model id the dispatched reviewer agent
  # naturally reports on line 1 (e.g. `Model: claude-sonnet-4-6`, `Model: claude-haiku-4-5-20251001`),
  # not just the bare alias. Optional `claude-` prefix + a trailing `[-_]` (version suffix) — so
  # `Model: sonnet` AND `Model: claude-sonnet-4-6` both pass. (Was: bare-alias-only → every codex/agent
  # review that wrote its real id got a false BLOCK + a manual relabel; the W13 dual-bookkeeping note.)
  if ! echo "$model_line" | grep -qiE "^Model:[[:space:]]*(claude-)?(${ALLOWED_REVIEW_MODELS})([[:space:]_-]|$)"; then
    echo "review model must be one of: ${ALLOWED_REVIEW_MODELS}"
    return 1
  fi

  if [ -n "$expected_session_id" ] && ! grep -qF "$expected_session_id" "$review_file" 2>/dev/null; then
    echo "missing session identifier ${expected_session_id}"
    return 1
  fi

  # HOOK-4: ORCHESTRATOR_INLINE / superpowers fallback ARE valid Wave 13 paths.
  # Reject only the specific anti-patterns: `review_mode: self-review (degraded)` as a
  # standalone provenance claim WITHOUT the surrounding W13 fallback declaration.
  # We accept `Codex adversarial reviewer: codex-adversarial-reviewer (orchestrator-inline fallback)`
  # and `Codex adversarial reviewer: superpowers:requesting-code-review fallback` since those
  # explicitly document a known fallback path.
  #
  # Strict reject: `review_mode: self-review` line WITHOUT a corresponding Codex line
  # naming `orchestrator-inline` or `superpowers fallback` — that means the reviewer
  # didn't follow the Wave 13 fallback chain.
  if grep -qiE '^review_mode:[[:space:]]*self-review|self-review[[:space:]]*\(degraded\)|degradation_note:|manual adversarial review substituted' "$review_file" 2>/dev/null; then
    # Self-review claim found. Check for explicit W13 fallback documentation.
    if ! grep -qiE 'orchestrator-inline|superpowers:requesting-code-review|superpowers fallback' "$review_file" 2>/dev/null; then
      echo "self-review claimed without explicit Wave 13 fallback documentation"
      return 1
    fi
    # If they're claiming self-review BUT also documented orchestrator-inline / superpowers,
    # accept — that's the W13 fallback path operating correctly.
  fi
  # Always reject the explicit DEGRADED token (uppercase) — that's the unambiguous
  # "I gave up" pattern.
  if grep -qE '\bDEGRADED\b' "$review_file" 2>/dev/null; then
    echo "explicit DEGRADED marker present — review path failed"
    return 1
  fi

  agents_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Agents dispatched\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)
  codex_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Codex adversarial reviewer\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)
  # PANEL (2026-08-03): the vendor-neutral alternative to the legacy codex field. When present AND
  # structurally valid it satisfies the same required-field slot and SUPPRESSES the codex prose checks
  # below — there is no codex claim to police on a panel artifact, and policing prose is what induced
  # the fabrication loop in the first place. $panel_size is the declared size for the independence
  # cross-check; empty when no valid panel field is present (⇒ every legacy path is byte-identical).
  local panel_line panel_size=""
  panel_line=$(_panel_field_extract "$review_file")
  if [ -n "$panel_line" ]; then
    panel_size=$(_panel_field_valid "$panel_line") || panel_size=""
    # A malformed panel field is a HARD error, never a silent downgrade to the legacy path: a typo'd
    # token that quietly stopped counting as a panel would reopen the unverifiable-prose hole.
    if [ -z "$panel_size" ] && [ -z "$codex_line" ]; then
      _verr_add "malformed 'Adversarial review:' field (need panel=N models=<N csv> lenses=<N csv, >=2 distinct> candidates=N accepted=N refuted=N, accepted+refuted<=candidates, panel>=2)"
    fi
  fi
  hostile_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Hostile adversarial focus\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)
  dispatch_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Dispatch mode\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)
  evidence_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Review evidence\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)
  remediation_line=$(grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Remediation\**:[[:space:]]*' "$review_file" 2>/dev/null | head -1 || true)

  # O4 (forensic, production session): report ALL missing required fields in ONE error, not one-per-Stop-cycle. The
  # orchestrator fixed AGENT_REVIEW fields serially across ~7 Stop blocks (~11 min) because each missing
  # field returned on the FIRST one. These six are INDEPENDENT presence checks, so batching them cannot
  # change the block/accept decision (any missing field still blocks) — it only collapses N cycles into 1.
  local _missing_fields=""
  [ -n "$agents_line" ]      || _missing_fields="${_missing_fields}${_missing_fields:+, }Agents dispatched"
  # Either provenance shape satisfies this slot: the legacy codex field (358 historical artifacts) or
  # the panel field. Requiring the codex-NAMED field on a review that never used codex is precisely
  # what manufactured the 147 unverifiable "ran — N candidates…" strings in the corpus.
  [ -n "$codex_line" ] || [ -n "$panel_line" ] || _missing_fields="${_missing_fields}${_missing_fields:+, }Codex adversarial reviewer (or 'Adversarial review:' panel field)"
  [ -n "$hostile_line" ]     || _missing_fields="${_missing_fields}${_missing_fields:+, }Hostile adversarial focus"
  [ -n "$dispatch_line" ]    || _missing_fields="${_missing_fields}${_missing_fields:+, }Dispatch mode"
  [ -n "$evidence_line" ]    || _missing_fields="${_missing_fields}${_missing_fields:+, }Review evidence"
  [ -n "$remediation_line" ] || _missing_fields="${_missing_fields}${_missing_fields:+, }Remediation"
  [ -z "$_missing_fields" ] || { echo "missing required AGENT_REVIEW field(s): ${_missing_fields}"; return 1; }

  # T5 (2026-07-02): this session's own AGENT_REVIEW artifacts used CDX-N finding IDs (codex's actual
  # naming convention when it self-numbers findings, e.g. CDX-1/CDX-2 — see that day's BITE_LEDGER from then
  # onward) but the marker regex only recognized the literal CODEX- prefix. Those artifacts still passed
  # because `findings: N` was also present, so this was latent, not yet blocking — but a CDX-N-only review
  # (no findings: N line) would wrongly report "missing review evidence markers". CDX- added alongside
  # CODEX- as an equally-valid finding-ID marker. codex review (CDX-2): require a trailing digit
  # (CDX-[0-9]+) rather than a bare `CDX-` substring, so this new marker doesn't accept arbitrary
  # unrelated prose that happens to contain the string "CDX-" — matches the intended CDX-N ID shape
  # exactly (the pre-existing bare CODEX- alternative is left as-is; not this fix's scope).
  if ! grep -qiE '(claude_accepted:|codex_candidates:|findings:[[:space:]]*[0-9]+|superpowers:requesting-code-review|CODEX-|CDX-[0-9]+|SREV-|No issues found|Raw Findings)' "$review_file" 2>/dev/null; then
    _verr_add "missing review evidence markers"
  fi

  if [ "$require_executed" = "1" ]; then
    # O2 (forensic, production session): is this an HONESTLY-DECLARED degraded review? Keyed on the same degraded
    # Dispatch mode values _independence_verdict resolves to 'declared' (warn) — orchestrator-inline /
    # inline / manual / degraded — OR an explicit superpowers fallback. When so, the codex-NAME provenance
    # requirements below (skip / provenance-words / agents-none) must NOT block: the review honestly used
    # the documented W13 fallback instead of codex, and _independence_verdict already makes that
    # degradation VISIBLE (declared→warn). Hard-blocking an honest "codex n/a, inline review performed"
    # here is exactly what INDUCED fabrication of a fake "codex ran" (observed in a production session). This relaxes ONLY the
    # codex-name checks — status / model / evidence-marker / findings-resolution (W22-#1) all still apply,
    # and a forged "codex ran" + inline claim is still caught by the independence gate's forgery branch
    # (codex…ran with no DISPATCH_PROVENANCE / subagent_type / proxy evidence → silent → block).
    # CODEX-004: key ONLY on the extracted $dispatch_line (NOT a file-wide grep) so a findings-body mention
    # of "superpowers"/"inline" can't relax a foreground dispatch-claim artifact. A genuine superpowers
    # fallback still passes via the codex/superpowers provenance-word check below (its codex line names
    # `superpowers:requesting-code-review`), so it does not depend on this flag.
    local _declared_degraded=0
    if [ "$allow_declared_degraded" = "1" ] \
       && echo "$dispatch_line" | grep -qiE ':[[:space:]]*\**[[:space:]]*(orchestrator[_-]?inline|inline|manual|degraded)([[:space:](_-]|$)'; then
      _declared_degraded=1
    fi

    # W5G-4b precision (forensic 2026-07-10, one project): "no code changes REQUIRED/needed/
    # necessary" is a clean-review OUTCOME idiom ("review ran, found nothing to fix"), not a skip
    # claim. The bare "no code changes"/"no code" substring match false-blocked a genuine full
    # review whose summary line ended "…no CRITICAL/HIGH surfaced, no code changes required",
    # which then drove a 3-block rearm-escape spiral + validator-gaming attempts. Scrub the benign
    # idiom BEFORE the skip-claim match; a real skip claim ("no code changes to review") survives
    # the scrub untouched. Lowercased once so the sed needs no GNU-only /I flag (BSD portability),
    # and the greps below drop -i accordingly (input is already lowercase).
    _ncc_scrub() {
      printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/(no|zero) (new )?code (changes|edits|fixes|modifications)( were| was)? (required|needed|necessary)//g'
    }
    if _ncc_scrub "$agents_line" | grep -qE '(copy-only|zero code|no code|nothing to review)'; then
      _verr_add "agents dispatched line claims no code review was needed"
    fi

    # A FALSE "no code changes / nothing to review / file not found" codex claim on a code session ALWAYS
    # blocks — it asserts no review was needed, contradicting require_executed=1. NOT relaxed by a degraded
    # mode (honesty about codex being unavailable ≠ claiming the diff had nothing to review).
    # PANEL: every check from here down interrogates the codex-NAMED prose field. A structurally valid
    # panel field carries its own machine-checked provenance (and is cross-verified against real
    # dispatch rows by _independence_verdict), so the prose greps are not just unnecessary — applying
    # them would re-create the false-block→fabrication loop on the very path built to end it. A FORGED
    # codex claim sitting alongside a panel field is still caught: _independence_verdict runs its
    # forgery branch on $codex_line independently of this suppression.
    # PANEL staleness: the skeleton emits candidates=0 accepted=0 refuted=0 (honest at emit time,
    # before adjudication). If the orchestrator pastes findings but never updates the counts, the
    # artifact would claim "0 candidates" over a body full of them — the same never-filled-template
    # failure the old `# FILL N from adjudication` placeholder produced in 4 on-disk drafts. Anchored
    # to the canonical finding-heading shape (`#### CODEX-001:`) so ordinary prose cannot trip it.
    if [ -n "$panel_size" ] \
       && printf '%s' "$panel_line" | grep -qE 'candidates=0([^0-9]|$)' \
       && grep -qE '^#{2,6}[[:space:]]+[A-Z][A-Z0-9]{1,11}-[0-9]+[:[:space:]]' "$review_file" 2>/dev/null; then
      _verr_add "panel field says candidates=0 but the body lists finding IDs — update candidates/accepted/refuted after adjudication"
    fi

    # DELIBERATELY NOT panel-guarded (unlike the checks below): this one catches a FALSE claim that the
    # diff had nothing to review, which is orthogonal to which reviewer ran — a real panel plus "no code
    # changes to review" is still a lie about the diff. It is a no-op on panel-only artifacts anyway
    # ($codex_line is empty ⇒ nothing matches), so keeping it strict costs the panel path nothing.
    if _ncc_scrub "$codex_line" | grep -qE '(no code changes|nothing to review|file not found)'; then
      _verr_add "codex adversarial reviewer was skipped"
    fi

    # W-perf4: word-boundary the n/a alternative. Bare `n/?a` matched the "na"
    # SUBSTRING inside legitimate words ("fi-na-l pass", "a-na-lysis"), false-blocking
    # a genuine codex run as "skipped" (observed in a production session). `\b` is BSD/macOS
    # grep-portable; "N/A","n/a","na","(N/A)","[N/A]" still match, "final"/"analysis" don't.
    # O2: a codex-unavailable line blocks ONLY when NO honest fallback is declared; with a declared-degraded
    # mode it's accepted honest degradation (the independence gate marks it warn).
    if [ -z "$panel_size" ] && [ "$_declared_degraded" -ne 1 ] && echo "$codex_line" | grep -qiE '(skipped|not applicable|\bn/?a\b)'; then
      _verr_add "codex adversarial reviewer was skipped (no documented fallback review)"
    fi

    # codex/superpowers provenance WORDS required only when NOT honestly degraded — an inline/manual
    # fallback legitimately names no codex agent (its provenance is the declared dispatch mode, which the
    # independence gate verifies).
    if [ -z "$panel_size" ] && [ "$_declared_degraded" -ne 1 ] && ! echo "$codex_line" | grep -qiE '(superpowers:requesting-code-review|codex-adversarial-reviewer|(^|[^a-z])ran([^a-z]|$)|background agent|foreground agent)'; then
      _verr_add "missing codex/superpowers review provenance"
    fi

    if [ -z "$panel_size" ] && [ "$_declared_degraded" -ne 1 ] && echo "$agents_line" | grep -qiE '\bnone\b' && ! echo "$codex_line" | grep -qi 'superpowers:requesting-code-review'; then
      _verr_add "agents dispatched cannot be none unless superpowers fallback ran"
    fi
  fi

  if [ "$hostile_required" = "1" ] && ! echo "$hostile_line" | grep -qiE ':[[:space:]]*yes([[:space:]]|$)'; then
    _verr_add "hostile adversarial focus required but not declared"
  fi

  # ── W22-#1: a PASSED/APPROVED code-session review must not leave a CRITICAL/HIGH finding
  #            UNRESOLVED (anti-rubber-stamp) ───────────────────────────────────────────────
  # The gate validated a review's STATUS + provenance but never that the findings it RAISED were
  # resolved — so a review could find a serious bug, "address" it cosmetically, and still APPROVE.
  # Forensics: the /v gauntlet reported PASS / "findings closed" while two
  # substantive findings were still live in the code; only the human re-asking caught it. This
  # mechanically enforces CLAUDE.md's "Fix all CRITICAL/HIGH findings before claiming done": a
  # terminal-pass review that leaves a CRITICAL/HIGH finding unresolved is rejected. A finding is
  # RESOLVED iff its block carries a fix:/Remediation: line that is NOT a deferral, or an explicit
  # FIXED/RESOLVED/REMEDIATED marker. Severity is matched UPPERCASE/labelled so the lowercase "high"
  # CONFIDENCE column never false-triggers, and only blocks that follow a finding header are scored
  # (a lowercase summary line cannot trip it). A bash gate cannot verify a fix is SEMANTICALLY
  # correct — that is the job of the independent re-review the P2/P0b gates now force; this is the
  # policy backstop that stops a serious finding from shipping unaddressed.
  if [ "$require_executed" = "1" ]; then
    case "$status" in
      completed|pass|passed|approved)
        local _unresolved_serious
        # Robust, low-false-positive finding-resolution scan, tuned against the real artifact zoo:
        #  • Severity is read POSITIONALLY from the finding header (first severity keyword,
        #    left-to-right) so an UPPERCASE *confidence* column ("FND | file | LOW | HIGH") is
        #    never misread as the severity.
        #  • Resolution is judged from the START of the finding's own `fix:` line — a real fix that
        #    merely MENTIONS "out of scope" as an aside (FND-003) is NOT a deferral; a
        #    `fix:` line that STARTS with a deferral (deferred / out-of-scope / will-fix / n/a /
        #    informational / no-action …) IS.
        #  • A finding with no per-finding `fix:` line is resolved by an explicit
        #    FIXED/RESOLVED/REMEDIATED marker OR by a GLOBAL remediation statement (e.g.
        #    "Remediation: all CRITICAL/HIGH fixed before sign-off").
        local _grem=0
        grep -qiE 'remediation[^a-z]*:?.*(fixed|resolved|remediated|no unresolved|no findings|0[[:space:]]*(critical|high)|no actionable)' "$review_file" 2>/dev/null && _grem=1
        grep -qiE 'no unresolved (critical|high)|0 actionable finding' "$review_file" 2>/dev/null && _grem=1
        _unresolved_serious=$(awk -v grem="$_grem" '
          BEGIN { u=0; open=0; b=""; fx=""; fxblock=0 }
          function hdr(l){ return (l ~ /^[[:space:]]*###?#?[[:space:]]*\**(FND|SREV|CODEX|REV|Finding)/ || l ~ /^[[:space:]]*[-*][[:space:]]*\**(FND|SREV|CODEX)[-_ ]/ || l ~ /^[[:space:]]*[Ss]everity[:=]/) }
          function sevof(l,  n,a,i,t,s){ if(l ~ /[Ss]everity[:=]/){ s=l; sub(/.*[Ss]everity[:=][[:space:]]*/,"",s); sub(/[^A-Za-z].*/,"",s); return toupper(s) } n=split(l,a,"|"); for(i=1;i<=n;i++){ t=a[i]; gsub(/[^A-Za-z]/,"",t); t=toupper(t); if(t=="CRITICAL"||t=="HIGH"||t=="MEDIUM"||t=="MED"||t=="LOW"||t=="INFO"||t=="INFORMATIONAL") return t } return "" }
          function deferral(t){ return (t ~ /^(deferred|defer |out.of.scope|out of scope|n\/a|will fix|to be fixed|informational|no action|won.?t fix|wont fix|will not fix|follow.?up|pending|todo|not addressed|left unfixed|unfixed|not fixed|skip)/) }
          # PRE-EXISTING carve-out (forensic 2026-06-16): a CRITICAL/HIGH finding whose fix:
          # disposition asserts the issue PREDATES this change is NOT a rubber-stamp — a scoped change is
          # not obliged to fix unrelated pre-existing issues (the system models this as pre_existing_baseline;
          # CLAUDE.md "fix all CRITICAL/HIGH" means findings the session INTRODUCED). So a temporal-provenance
          # claim rescues an otherwise-deferral-looking fix line. This is a PROVENANCE claim, NOT a generic
          # "out of scope" dodge: "out of scope for THIS SESSION" alone (no pre-existing assertion) still fires.
          # GATE HARDENING (codex CODEX-001/002): the rescue is gated by a disqualifier so a NEGATED or
          # UNCERTAIN claim (and a session ADMITTING it introduced the bug) does NOT slip through — e.g.
          # "deferred — NOT pre-existing, this diff introduced it" / "unclear if pre-existing" still FIRE.
          # Only unambiguous TEMPORAL markers count (no bare "already present" — that means "present elsewhere
          # too", a different claim). pe_marker(rescue) AND NOT pe_disq(negation/uncertainty/admitted-new).
          function pe_marker(t){ return (t ~ /pre.?existing|predates this|exists in (the )?baseline|present before this (diff|change|session)/) }
          function pe_disq(t){ return (t ~ /not[ -]?pre.?existing|isn.?t[ -]?pre.?existing|never[ -]?pre.?existing|newly introduced|unclear|uncertain|unsure|not sure|maybe|might be|possibly|probably|likely|could be|\?/) }
          function preexisting(t){ return ( pe_marker(t) && !pe_disq(t) ) }
          function flush(){ if(open){ r=0;
            if(fx!=""){ if(!deferral(fx) || preexisting(fx)) r=1 }
            else { if(b ~ /(FIXED|RESOLVED|REMEDIATED|fixed and re-verified)/) r=1; else if(grem==1) r=1 }
            if(!r) u++ } b=""; open=0; fx=""; fxblock=0 }
          # ND-0716: the codex-adversarial-reviewer template writes `fix: |` (YAML block scalar) with
          # the real disposition on the NEXT indented line. Capturing the literal `|` as the fix text
          # made deferral() vacuously false — every templated CRITICAL/HIGH scored RESOLVED (fail-open).
          # A bare block-scalar indicator now arms fxblock; the next non-empty line is the disposition.
          # `fix: |` with NO body leaves fx empty → falls to the marker/grem path (no fix evidence).
          { if(hdr($0)){ flush(); s=sevof($0); if(s=="CRITICAL"||s=="HIGH") open=1 } b=b "\n" $0;
            if(open && fxblock && fx==""){ if($0 ~ /[^[:space:]]/){ fx=tolower($0); sub(/^[[:space:]]+/,"",fx); fxblock=0 } }
            else if(open && fx=="" && $0 ~ /[Ff]ix:[[:space:]]*[^[:space:]]/){
              t=tolower($0); sub(/.*[Ff]ix:[[:space:]]*/,"",t);
              if(t ~ /^[|>][0-9]*[+-]?[[:space:]]*$/){ fxblock=1 } else { fx=t } } }
          END { flush(); print u+0 }' "$review_file" 2>/dev/null || echo 0)
        # P1: W22-#1 (anti-rubber-stamp) only applies to an OTHERWISE-VALID approved review. If content-
        # honesty failures already accumulated (e.g. missing provenance), THOSE are the blocking reasons —
        # don't also pile on the unresolved-serious message (it presumes a well-formed PASS, and historically
        # an earlier content return short-circuited before this scan ran). Preserves prior behavior + the
        # real-artifact FP-safety contract (review-finding-resolution-test.sh).
        if [ -z "$_errs" ] && [ "${_unresolved_serious:-0}" -gt 0 ] 2>/dev/null; then
          _verr_add "approved review leaves ${_unresolved_serious} CRITICAL/HIGH finding(s) UNRESOLVED — CLAUDE.md requires fixing all CRITICAL/HIGH findings before done. A reviewer that reports a serious finding and still APPROVES is a rubber-stamp (observed: gauntlet reported PASS with substantive findings unfixed). Fix the finding(s) and re-run an INDEPENDENT review, or set the review status to FAIL / CHANGES_REQUESTED."
        fi
        ;;
    esac
  fi

  # P1 flush: emit ALL accumulated content-honesty failures in one block (any one still blocks).
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# W-perf5: SINGLE-SOURCE artifact validators (IMPACT_MAP + QA_REPORT structure).
#
# WHY (three production sessions — 45–62 min each, all bounced):
# the /v orchestrator's pre-completion self-check used `test -f IMPACT_MAP_<sid>.md`
# (mere file EXISTENCE) while the Stop hook (check-review-artifact.sh) gates on the
# SEMANTIC anchor `^subsystems:`. A `## Subsystem triage` TABLE IMPACT_MAP — or a
# QA_REPORT missing its `Model:` header — passed the orchestrator's `test -f`, so it
# declared DONE, then the Stop hook bounced it, forcing a full MANUAL gauntlet re-run
# in the parent session. These two functions are the ONE implementation that BOTH the
# Stop hook AND the orchestrator self-check (v-completion-selfcheck.sh) call, so the
# producer-side check and the gate can never drift again. A drift sentinel in
# v-contract-audit-test.sh (Section F) asserts the Stop hook actually CALLS them.
#
# Convention (same as validate_review_semantics): on failure echo the human reason
# and `return 1`; on success `return 0`.

# validate_impact_map_semantics <file>
#   0 = structurally valid (Stop-hook-equivalent); else echoes the reason, returns 1.
#   Reasons are byte-identical to the Stop hook's IMPACT_MAP block so messages don't change.
validate_impact_map_semantics() {
  local f="${1:-}" sz
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 200 ]; then
    echo "too small (${sz} bytes — subsystem checklist not filled)"; return 1
  fi
  # W-perf8 (2026-05-30): tolerate the markdown-TABLE enumeration the model naturally reaches
  # for, not just the documented `key:` YAML form. Two production sessions wrote a
  # perfectly valid `| reporting_metrics | no | … |` triage table and got BOUNCED here (then
  # thrashed re-formatting to anchored lines) — a table enumerates the subsystems just as well,
  # which is the whole point ("the enumeration is the point"). Each anchor now accepts an
  # OPTIONAL leading bullet `-`/`*` (P2h), `|` (table cell), or `#` (heading), key at line-start,
  # followed by `:` OR `|`. P2h (forensic 2026-06-17): the model naturally
  # writes the checklist as markdown BULLETS (`- reporting_metrics: impacted: no`), which the prior
  # `#*\|?` decoration class REJECTED — forcing a hand-patch round (`- key:` → `  key:`) in BOTH those
  # sessions. The `[-*#]*` class accepts bullets/headings/tables uniformly. Prose mentions
  # ("…the reporting_metrics field…") still fail: the key must be at line-start after only a single
  # optional bullet/heading run + pipe + space, so the enumeration guarantee is preserved. ugrep-safe
  # (no `\{n,}` interval — that form crashes ugrep 7.x).
  # E1 (efficiency, 2026-07-05): batch ALL independent checklist-key checks into one
  # manifest naming exactly which key(s) are missing, instead of one generic
  # "incomplete subsystem checklist" message that forced the caller to guess (or
  # re-dispatch) to discover WHICH of the three fields still needed adding.
  local _errs=""
  _im_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }
  if ! grep -qiE '^[[:space:]]*[-*#]*[[:space:]]*\|?[[:space:]]*subsystems?[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _im_add "missing 'subsystems:' checklist block"
  fi
  if ! grep -qiE '^[[:space:]]*[-*#]*[[:space:]]*\|?[[:space:]]*reporting_metrics[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _im_add "missing 'reporting_metrics' checklist key"
  fi
  if ! grep -qiE '^[[:space:]]*[-*#]*[[:space:]]*\|?[[:space:]]*cache_invalidation[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _im_add "missing 'cache_invalidation' checklist key"
  fi
  if ! grep -qiE '^[[:space:]]*[-*#]*[[:space:]]*\|?[[:space:]]*db_integrity[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _im_add "missing 'db_integrity' checklist key"
  fi
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# validate_qa_report_structure <file>
#   0 = structurally valid → echoes the lowercased top verdict (pass|fail|escalated|"");
#       else echoes the structural reason, returns 1.
#   Validates ONLY the drift-prone structure (size, Model: header, `## QA Acceptance`
#   heading) + extracts the authoritative top `verdict:` (col-0 anchor). The verdict-case
#   decision (fail→block, escalated→needs BLOCKED) and the W71 independence check stay in
#   the caller, which needs find_session_artifact + the session transcript.
validate_qa_report_structure() {
  local f="${1:-}" sz v
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 100 ]; then
    echo "too small (${sz} bytes)"; return 1
  fi
  # E1 (efficiency, 2026-07-05): the Model:/heading checks below are
  # independent structural checks (different parts of the file) — batch them
  # into one manifest so a report missing BOTH doesn't cost two round-trips.
  # The size check above stays early-return (foundational: a too-small file
  # can't meaningfully be evaluated for structure at all).
  local _errs=""
  _qa_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }
  # Model: in the first 5 lines. awk (NOT `grep -q <<<"$(head -5)"`) — the
  # command-substituted here-string form silently poisons the NEXT command
  # substitution (the verdict extraction below) under macOS bash 3.2, yielding an
  # empty verdict. awk uses no pipe and no here-string, so it is portable across
  # bash 3.2/5.x AND immune to the pipefail-SIGPIPE false-negative the inline
  # here-string was originally chosen to avoid. Same semantics as `^Model:` (ci).
  if ! awk 'NR<=5 && tolower($0) ~ /^model:/ {ok=1} END{exit ok?0:1}' "$f" 2>/dev/null; then
    _qa_add "missing 'Model:' header in first 5 lines"
  fi
  if ! grep -qiE '^##[[:space:]]*QA[[:space:]]+Acceptance' "$f" 2>/dev/null; then
    _qa_add "missing required '## QA Acceptance' heading"
  fi
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  # The grep finds the col-0 verdict line case-insensitively; the strip must ALSO be
  # case-insensitive (full char classes — BSD sed lacks a portable `I` flag) so an
  # all-caps `VERDICT: PASS` strips correctly instead of leaking `VERDICT:` → `*)` block.
  # F2-upstream (round-3 2026-07-02, adversarial-review PoC): the VALUE may be quote/backtick/bold-wrapped
  # (`verdict: "fail"` — observed shape from self-write QA reports) and the bare-token match let a FAIL
  # through as "no verdict". Accept optional wrappers in the grep, strip them with tr (octal \047=' \140=`
  # — portable where sed escapes are not). Pipeline must stay BYTE-IDENTICAL to v-merge-back.sh's
  # _qa_report_fail() — pinned by qa-verdict-wrapped-parity-test.sh, no longer only by this comment.
  v=$(grep -iE '^verdict:[[:space:]]*["'"'"'`*_]*(pass|escalated|fail)' "$f" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*[Vv][Ee][Rr][Dd][Ii][Cc][Tt]:[[:space:]]*//' | tr -d '"*_\140\047' | awk '{print tolower($1)}')
  echo "$v"
  return 0
}

# validate_ux_critique_structure <file>
#   0 = structurally valid (Stop-hook-equivalent); else echoes the reason, returns 1.
#   Same single-source rationale as IMPACT/QA: the orchestrator self-check
#   (v-completion-selfcheck.sh) and the Stop hook BOTH call this, so a UX_CRITIQUE that
#   exists-but-is-malformed can't pass the producer check and bounce at the gate.
#   Heading match is case-INSENSITIVE (forensic 2026-06-19: the case-SENSITIVE `-qE` rejected
#   '## UX Findings' (capital F) while QA/Workflow headings were already case-insensitive — a
#   gratuitous death-march trap. '-qiE' still rejects a bare '## Findings' masquerade (no UX/Heuristic
#   token), so the anti-masquerade guard is preserved. Single-source: the Stop hook + self-check both
#   call this function, so this one change is authoritative everywhere.
validate_ux_critique_structure() {
  local f="${1:-}" sz
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 100 ]; then
    echo "too small (${sz} bytes — fabrication suspected)"; return 1
  fi
  # E1 (efficiency, 2026-07-05): batch the two independent structural checks
  # (Model:/heading) into one manifest — same rationale as
  # validate_qa_report_structure above.
  local _errs=""
  _ux_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }
  if ! awk 'NR<=5 && tolower($0) ~ /^model:/ {ok=1} END{exit ok?0:1}' "$f" 2>/dev/null; then
    _ux_add "missing 'Model:' header in first 5 lines"
  fi
  if ! grep -qiE '^##[[:space:]]*(UX[[:space:]]+Critique|Heuristic[[:space:]]+coverage|UX[[:space:]]+findings)' "$f" 2>/dev/null; then
    _ux_add "missing required level-2 heading '## UX Critique', '## Heuristic coverage', or '## UX findings' (bare '## Findings' is rejected to prevent AGENT_REVIEW masquerading)"
  fi
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# validate_success_criteria_structure <file>
#   0 = structurally valid; else echoes the reason, returns 1. SUCCESS_CRITERIA (/v Step 1.7,
#   Feature Tiny/Small) is the declarative definition-of-done that /v-tdd reads for RED tests and
#   Step 6 reads as the stopping condition — a BLANK/fabricated stub silently narrows coverage while
#   completion passes (Part-3 P0, audit 2026-06-21). VALIDATE-IF-PRESENT: the gate never DEMANDS
#   presence (bug-fix/Maintenance/Audit legitimately skip Step 1.7) — but a present artifact must
#   carry the real structure. Permissive anchors (bullet/table/heading/yaml, ci) mirror
#   validate_impact_map_semantics so the natural format the model writes is accepted; only a stub is
#   rejected. Single-sourced: the Stop hook + v-completion-selfcheck.sh both call this, so they agree.
validate_success_criteria_structure() {
  local f="${1:-}" sz
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 150 ]; then
    echo "too small (${sz} bytes — criteria/state block not filled, fabrication suspected)"; return 1
  fi
  # 'criteria' block — the declarative SC-* list. `[-*#|>]*` accepts the natural bullet/heading/table/
  # blockquote decoration; the trailing `[:|]` REQUIRES the field-key form (`criteria:` or a `| criteria |`
  # table cell) so a prose mention ("…the criteria for…") OR a bare `## Criteria` / `## Success Criteria`
  # heading (decoration, no field block behind it) does not satisfy it (codex SREV-006; mirrors
  # validate_impact_map_semantics' delimiter anchor).
  # E1 (efficiency, 2026-07-05): 'criteria' and 'workflow_states' are independent
  # blocks (different keys) — batch into one manifest instead of returning on
  # the first miss (same rationale as validate_qa_report_structure above).
  local _errs=""
  _sc_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }
  if ! grep -qiE '^[[:space:]]*[-*#|>]*[[:space:]]*criteria[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _sc_add "missing 'criteria' block (the declarative SC-* list /v-tdd reads for RED tests)"
  fi
  # 'workflow_states' coverage block — the state matrix the narrow happy-path misses. Trailing `[:|]`
  # pins the field-key form so a decorative heading alone does not satisfy it (codex SREV-006).
  if ! grep -qiE '^[[:space:]]*[-*#|>]*[[:space:]]*workflow_states?[[:space:]]*[:|]' "$f" 2>/dev/null; then
    _sc_add "missing 'workflow_states' coverage block (empty/loading/error/permission_denied/concurrent/double_submit)"
  fi
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  return 0
}

# validate_blast_radius_structure <file>
#   0 = structurally valid; else echoes the reason, returns 1. WORKFLOW_BLAST_RADIUS (/v Step 1.6,
#   bug-fix + UI/flow) carries the `states_to_verify` list /v-tdd turns into one RED test each — a
#   blank stub means the fix is tested for the reported symptom ONLY (the recurring "narrow fix →
#   leftover sibling bug" class, Part-3 P0). VALIDATE-IF-PRESENT (non-UI/backend bug-fixes legitimately
#   skip Step 1.6); a present artifact must carry the list. Permissive anchor (ci); single-sourced.
validate_blast_radius_structure() {
  local f="${1:-}" sz
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 150 ]; then
    echo "too small (${sz} bytes — states_to_verify not filled, fabrication suspected)"; return 1
  fi
  # Trailing `[:|]` pins the `states_to_verify:` field-key form so a bare `## states_to_verify` heading
  # (decoration, no list behind it) is not enough (codex SREV-006).
  if ! grep -qiE '^[[:space:]]*[-*#|>]*[[:space:]]*states_to_verify[[:space:]]*[:|]' "$f" 2>/dev/null; then
    echo "missing 'states_to_verify' list (the per-state RED tests /v-tdd consumes — a symptom-only fix is the leftover-sibling-bug class)"; return 1
  fi
  return 0
}

# validate_workflow_verification_structure <file>
#   0 = structurally valid → echoes the status (pass|degraded|fail|""); else echoes the
#   reason, returns 1. The caller decides: status fail → block (mirrors the QA verdict
#   pattern). Heading match is case-insensitive (matches the Stop hook's `grep -qiE`).
validate_workflow_verification_structure() {
  local f="${1:-}" sz s
  [ -n "$f" ] && [ -f "$f" ] || { echo "not found"; return 1; }
  sz=$(wc -c < "$f" 2>/dev/null | tr -d ' \n' || echo 0)
  if [ "${sz:-0}" -lt 100 ]; then
    echo "too small (${sz} bytes — fabrication suspected)"; return 1
  fi
  # E1 (efficiency, 2026-07-05): Model:/heading/status are three independent
  # presence checks — batch into one manifest (same rationale as
  # validate_qa_report_structure above) instead of one round-trip per field.
  local _errs=""
  _wv_add() { _errs="${_errs}${_errs:+$'\n'}$1"; }
  if ! awk 'NR<=5 && tolower($0) ~ /^model:/ {ok=1} END{exit ok?0:1}' "$f" 2>/dev/null; then
    _wv_add "missing 'Model:' header in first 5 lines"
  fi
  if ! grep -qiE '^##[[:space:]]*Workflow[[:space:]]+Verification' "$f" 2>/dev/null; then
    _wv_add "missing required '## Workflow Verification' heading"
  fi
  s=$(grep -iE '^status:[[:space:]]*(pass|degraded|fail)' "$f" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*[Ss][Tt][Aa][Tt][Uu][Ss]:[[:space:]]*//' | awk '{print tolower($1)}')
  if [ -z "$s" ]; then
    _wv_add "missing 'status: pass|degraded|fail' line"
  fi
  [ -z "$_errs" ] || { printf '%s\n' "$_errs"; return 1; }
  # Normalize the fail-FAMILY to `fail` so the callers' `= fail` test still blocks a broken
  # flow reported as `status: failed` / `failure` / `FAILED`. The prior inline gate used a
  # `^status:\s*fail` PREFIX grep, so ANY status starting `fail` blocked — token-equality
  # alone would silently let `status: failed` ship a broken workflow (W-perf5 review, MED).
  case "$s" in fail*) s="fail" ;; esac
  echo "$s"
  return 0
}

# ============================================================================================
# W71 GATE-INDEPENDENCE PRIMITIVES — single source of truth (extracted from
# check-review-artifact.sh, 2026-06-15). BOTH the Stop hook AND v-completion-selfcheck.sh call
# these, so the producer-side gate and the enforcement gate can NEVER disagree on whether a
# reviewer/QA artifact came from an INDEPENDENT dispatch (production incident: a fabricated
# 'subagent-dispatched' review passed the self-check while the Stop hook blocked it → /v lied
# about finishing). Callers MUST set these globals first:
#   SESSION_ID           - the session whose artifacts/transcript we judge
#   ARTIFACT_SEARCH_DIRS - array of dirs holding DISPATCH_PROVENANCE_<sid>.log + proxy files
#   TRANSCRIPT_READABLE  - 1 if the session transcript was located, else 0
#   _TX_SIGNALS          - compact buffer of transcript subagent_type / --agent / model signals
# _prep_independence_signals (below) populates TRANSCRIPT_READABLE + _TX_SIGNALS exactly the
# way the Stop hook does (the session's top-level transcript), so the producer matches by
# construction. Parity is locked by skills/v/references/v-completion-parity-test.sh.
# H1 (audit 2026-06-18): _proxy_file_has_content <file> -> 0 if a codex hand-rolled-path proxy
# file binds to REAL session content, not a touch/empty forgery. The proxy loop below previously
# accepted any proxy by `[ -f ]` (existence only) — a single 0-byte `touch codex-review-<sid>.log`
# (writable same-uid, BELOW the documented same-uid crypto ceiling) flipped _agent_was_dispatched
# to 'dispatched' and short-circuited the `codex…ran`-forgery check, laundering an orchestrator
# self-review past the independence gate (confirmed by live repro). This restores the proxy to the
# same-uid ceiling: an empty proxy never counts, and diff/patch proxies must carry an actual diff
# line. FP-safe — a genuine review-diff/session-diff always has a diff header or +/- line; codex
# log proxies need only be non-empty (a terse "no findings" log must still pass, so no size floor).
# SREV-003 (codex review 2026-06-18): this raises the bar from a 0-byte `touch` to *some* diff-shaped
# content; a same-uid forger can still craft a 1-char `+` line (or forge DISPATCH_PROVENANCE outright)
# — that is the acknowledged same-uid ceiling, not a regression. The `[+-]` branch is deliberately
# loose (matches a bare `+`/`-` so blank-line-only diffs are not FP-rejected); real review-diffs also
# carry a `diff `/`@@`/`--- `/`+++ `/`Binary files ` header, so genuine proxies always pass.
_proxy_file_has_content() {  # <file>
  local _f="$1"
  [ -s "$_f" ] || return 1   # 0-byte = touch-forgery
  case "$_f" in
    *review-diff-*|*session-diff-*)
      grep -qE '^(diff |@@|index |--- |\+\+\+ |Binary files |[+-])' "$_f" 2>/dev/null || return 1 ;;
  esac
  return 0
}

# ============================================================================================
# _agent_was_dispatched <agent> -> 0 if an INDEPENDENT instance ran this session via any path:
#   (1) Agent/Task tool with subagent_type=<agent>          (main-session dispatch)
#   (2) a Bash command running v-dispatch-subagent.sh --agent <agent>  (in-fork claude -p)
#   (3) a DISPATCH_PROVENANCE_<sid>.log line agent=<agent> ... status=ok
_agent_was_dispatched() {
  local _agent="$1" _sid_short _dir _log _a1b_matches _a1b_row _a1b_ts _a1b_ts_epoch _a1b_any_grandfathered
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      # SREV-004 (forensic 2026-06-17): `mode=agent-self` lines are an artifact's OWN tamper-baseline
      # self-record (e.g. v-qa-reviewer writes its QA_REPORT sha), NOT proof the orchestrator dispatched
      # an independent reviewer — the same process that could forge the report can write that line. So
      # they do NOT establish independence here (a forged self-record must not manufacture 'dispatched').
      # They REMAIN the sha baseline for _artifact_postdispatch_edited (which reads any status=ok sha256
      # line), so a REAL dispatch (transcript/subprocess below) + this self-record still catches a flip.
      #
      # A-1b (HANDOFF_orchestrator-hardening-3.md, 2026-07-02): a `mode=capture|status=ok` row with an
      # EMPTY/malformed sha256 is exactly the fabrication vector this grep used to accept — a
      # hand-printf'd row bypassing v-dispatch-subagent.sh's `emit_marker()`, which ALWAYS computes a
      # real sha256 on a genuine `status=ok` capture-mode dispatch (it hashes the on-disk artifact right
      # after the subprocess writes it). Corpus-backtested (v-a1b-corpus-backtest.sh) across 257
      # historical DISPATCH_PROVENANCE_*.log files / 459 mode=capture rows in ~/.claude + ~/dev: the
      # ONLY empty-sha mode=capture row found was the KNOWN fabricated
      # fit-reviewer row the forensic audit had already independently identified — zero false positives.
      # GRANDFATHERED by the row's OWN `ts=` field (Trap 2 in the plan: "ships LAST with a grandfather
      # cutoff... else Stop false-blocks fleet-wide on historical degraded rows") — a row TIMESTAMPED
      # before this fix's ship time keeps the OLD lenient behavior, so no already-completed session is
      # retroactively broken. Deliberately NOT file mtime: a log can be legitimately rewritten/copied
      # long after its rows were dispatched (v-artifact-consolidate.sh's durable-copy mirroring, C-2;
      # also every w71-hardening-test.sh fixture that plants an old `ts=` in a freshly-written file) —
      # mtime would misclassify that as "post-cutoff" and false-block genuinely historical content.
      # Scope is deliberately narrow: other modes (agent-tool, self-write, codex_cli, foreground, ...)
      # are untouched — the corpus showed no comparable fabrication signature there, and tightening
      # beyond what's evidenced risks a false-block surface the plan explicitly warns against.
      _a1b_matches=$(grep -E "agent=${_agent}\|mode=[^|]*\|status=ok" "$_log" 2>/dev/null | grep -vE '\|mode=agent-self\|')
      if [ -n "$_a1b_matches" ]; then
        if printf '%s\n' "$_a1b_matches" | grep -qvE '\|mode=capture\|'; then
          return 0   # a non-capture-mode independent-dispatch row matched — untouched by A-1b
        fi
        if printf '%s\n' "$_a1b_matches" | grep -qE '\|mode=capture\|.*sha256=[0-9a-fA-F]{64}$'; then
          return 0   # a mode=capture row WITH a valid sha256 — real dispatch, always accepted
        fi
        # every matching row is mode=capture with an empty/malformed sha256. Grandfather PER ROW by
        # its own `ts=` field — if ANY such row predates the cutoff, that row alone is enough to
        # accept (old lenient behavior); only if EVERY such row is BOTH unhashed AND post-cutoff is
        # this agent+log treated as not-dispatched.
        _a1b_any_grandfathered=0
        while IFS= read -r _a1b_row; do
          [ -n "$_a1b_row" ] || continue
          _a1b_ts=$(printf '%s' "$_a1b_row" | grep -oE '\|ts=[^|]*\|' | head -1 | sed 's/^|ts=//; s/|$//')
          _a1b_ts_epoch=""
          if [ -n "$_a1b_ts" ]; then
            _a1b_ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$_a1b_ts" +%s 2>/dev/null)
            [ -n "$_a1b_ts_epoch" ] || _a1b_ts_epoch=$(date -d "$_a1b_ts" +%s 2>/dev/null)
          fi
          if [ -z "$_a1b_ts_epoch" ] || [ "$_a1b_ts_epoch" -lt "${A1B_SHIP_CUTOFF_EPOCH:-1782968169}" ] 2>/dev/null; then
            _a1b_any_grandfathered=1
            break
          fi
        done <<A1B_ROWS
$(printf '%s\n' "$_a1b_matches" | grep -E '\|mode=capture\|')
A1B_ROWS
        [ "$_a1b_any_grandfathered" = 1 ] && return 0
        # every mode=capture match is unhashed AND post-cutoff — NOT accepted as dispatched.
      fi
    done
  done
  if [ -n "$_TX_SIGNALS" ]; then
    printf '%s\n' "$_TX_SIGNALS" | grep -qE "\"subagent_type\":\"${_agent}\"$|--agent[ =\"]+${_agent}$" && return 0
  fi
  # Proxy evidence for codex dispatched via bash subprocess (no DISPATCH_PROVENANCE or
  # subagent_type signal): the orchestrator writes review-diff / session-diff / codex-review
  # log files to .v/artifacts. These bind to the session's REAL diff or codex's REAL output,
  # so their presence confirms a real independent review was attempted for this session.
  #
  # F3 (audit 2026-06-17): codex-review-prompt-* is DELIBERATELY EXCLUDED. The prompt file is a
  # generic template written BEFORE `codex exec` runs (v-agent-review.md:119) — it requires no
  # session-specific work and proves nothing about whether codex executed or its output was read.
  # Accepting it let a lone prompt file satisfy 'dispatched'. The canonical path still passes via
  # its DISPATCH_PROVENANCE status=ok line (checked above), and hand-rolled paths still pass via
  # the diff/log proxies below — both bind to real session content, unlike the prompt.
  if [ "$_agent" = "codex-adversarial-reviewer" ] || [ "$_agent" = "codex" ]; then
    for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
      [ -z "$_dir" ] && continue
      for _f in \
        "$_dir/codex-review-${SESSION_ID}.log" \
        "$_dir/codex-review-${_sid_short}.log" \
        "$_dir/codex-review-dispatch-${SESSION_ID}.log" \
        "$_dir/codex-review-dispatch-${_sid_short}.log" \
        "$_dir/review-diff-${SESSION_ID}.patch" \
        "$_dir/review-diff-${SESSION_ID}.txt" \
        "$_dir/review-diff-${_sid_short}.patch" \
        "$_dir/review-diff-${_sid_short}.txt" \
        "$_dir/session-diff-${SESSION_ID}.txt" \
        "$_dir/session-diff-${_sid_short}.txt"; do
        [ -f "$_f" ] && _proxy_file_has_content "$_f" && return 0
      done
    done
  fi
  return 1
}

# _fallback_reviewer_dispatched -> 0 if a SANCTIONED independent reviewer subagent genuinely ran this
# session. When the codex CLI is unavailable, CLAUDE.md mandates the superpowers:requesting-code-review /
# Agent-tool fallback, which dispatches one of these adversarial reviewer subagents. Evidence is the REAL
# Task-dispatch subagent_type signal in the transcript (parent OR subagents/ tree) or a status=ok
# DISPATCH_PROVENANCE line — both produced by a genuine dispatch and absent on an orchestrator-inline
# self-review (hard to forge). Consulted ONLY to satisfy the codex-adversarial-reviewer independence
# requirement (see _independence_verdict); the codex-vs-fallback preference stays a warn-level nudge (W5F-6).
# Forensic 2026-06-16 (production session): codex was down, the session dispatched a real hostile
# security-reviewer, but the gate credited ONLY subagent_type=codex-adversarial-reviewer → false-block →
# the model laundered the honest fallback into a fake 'Dispatch mode: manual'.
_FALLBACK_REVIEWERS_RE='security-reviewer|logic-reviewer|codebase-fit-reviewer|framework-pitfall-reviewer|adversarial-panel-reviewer'

# ── PANEL (2026-08-03): vendor-neutral adversarial-review provenance ──────────────────────────────
# WHY this exists. The legacy `Codex adversarial reviewer:` field is FREE TEXT that the gate polices
# with substring greps. Ground truth over 358 final AGENT_REVIEW artifacts: only 24 (6.7%) positively
# evidence a successful codex CLI run, 139 record failure/fallback, and 147 say `ran — N candidates…`
# naming NO model and NO mechanism — unverifiable prose the validator nonetheless accepts. Policing
# prose is why validation.sh accumulated ~15 special-cases: every false-block on an honest fallback
# induced the model to launder it into a fake "codex ran" (two production forensics), which drove
# another regex, which drove another escape.
#
# The panel field ends that loop by making the value MACHINE-CHECKABLE and cross-checkable against
# DISPATCH_PROVENANCE, so there is no prose left to wordsmith and no passing string that can be
# written without matching dispatch rows:
#
#   - Adversarial review: panel=3 models=sonnet,sonnet,haiku lenses=correctness,security,repro \
#                         candidates=7 accepted=2 refuted=5
#
# Independence here is PANEL-shaped, not vendor-shaped: N independent reviewers with DISTINCT lenses,
# each prompted to REFUTE. Cross-vendor diversity (codex) becomes an optional extra voice, never the
# gate — it was already absent from ~93% of reviews, so requiring it only bought fabrication pressure.
# BACK-COMPAT is absolute: the legacy codex field remains fully accepted (358 artifacts must not
# retro-fail); a panel field is an ALTERNATIVE way to satisfy the same requirement, never a new one.
_PANEL_REVIEWERS_RE='security-reviewer|logic-reviewer|codebase-fit-reviewer|framework-pitfall-reviewer|adversarial-panel-reviewer|codex-adversarial-reviewer'

# _panel_field_extract <review_file> -> prints the raw `Adversarial review:` value (empty if absent)
_panel_field_extract() {
  grep -iE '^[[:space:]#>*-]*\**[[:space:]]*Adversarial review\**:[[:space:]]*' "$1" 2>/dev/null | head -1 || true
}

# _panel_field_valid <line> -> 0 when the token block is structurally well-formed.
# Prints the declared panel size on success. Strict by construction: every key must be present and
# internally consistent, so a hand-written approximation fails loudly instead of degrading to prose.
_panel_field_valid() {
  local _l="$1" _n _models _lenses _cand _acc _ref _nm _nl _distinct
  _n=$(printf '%s' "$_l"      | grep -oE 'panel=[0-9]+'       | head -1 | cut -d= -f2)
  _models=$(printf '%s' "$_l" | grep -oE 'models=[A-Za-z0-9_.,-]+'  | head -1 | cut -d= -f2)
  _lenses=$(printf '%s' "$_l" | grep -oE 'lenses=[A-Za-z0-9_.,-]+'  | head -1 | cut -d= -f2)
  _cand=$(printf '%s' "$_l"   | grep -oE 'candidates=[0-9]+'  | head -1 | cut -d= -f2)
  _acc=$(printf '%s' "$_l"    | grep -oE 'accepted=[0-9]+'    | head -1 | cut -d= -f2)
  _ref=$(printf '%s' "$_l"    | grep -oE 'refuted=[0-9]+'     | head -1 | cut -d= -f2)
  [ -n "$_n" ] && [ -n "$_models" ] && [ -n "$_lenses" ] || return 1
  [ -n "$_cand" ] && [ -n "$_acc" ] && [ -n "$_ref" ]     || return 1
  # A "panel" of one is a single reviewer wearing a panel label — the exact dressed-up self-review
  # this field exists to make impossible to claim.
  [ "$_n" -ge 2 ] 2>/dev/null || return 1
  _nm=$(printf '%s' "$_models" | tr ',' '\n' | grep -c .)
  _nl=$(printf '%s' "$_lenses" | tr ',' '\n' | grep -c .)
  [ "$_nm" -eq "$_n" ] && [ "$_nl" -eq "$_n" ] || return 1
  # Lens diversity is the point: N reviewers all running the SAME lens is redundancy, not a panel.
  _distinct=$(printf '%s' "$_lenses" | tr ',' '\n' | grep . | sort -u | grep -c .)
  [ "$_distinct" -ge 2 ] || return 1
  # Adjudication arithmetic must close. `<=` not `==`: dedup legitimately drops candidates.
  [ $(( _acc + _ref )) -le "$_cand" ] 2>/dev/null || return 1
  printf '%s' "$_n"
  return 0
}

# _panel_was_dispatched <n> -> 0 when >= n distinct panel MEMBERS have a status=ok dispatch row.
# This is the forgery backstop: the declared panel size must be BACKED by real dispatch records, so
# `panel=3` cannot be typed into an artifact without three reviewers actually having run.
#
# MEMBERSHIP IS KEYED ON `artifact=`, NOT ON `agent=` (fixed 2026-08-03 by live-fire, before ship).
# The first cut counted DISTINCT AGENT NAMES, which silently broke the actual architecture: a panel is
# ONE agent (`adversarial-panel-reviewer`) dispatched N times with DIFFERENT LENSES, so a real 2-lens
# run writes two rows that both say `agent=adversarial-panel-reviewer`. Distinct-name counting scored
# that as 1 and REJECTED it — every panel session would have dead-ended at the Stop gate with no way
# for automation to clear it (the H4-6 unattended-deadlock class). Verified live: two real
# `claude -p --agent` dispatches over a real diff produced exactly that false rejection.
# Each panel member writes its OWN `--artifact`, so distinct artifacts == distinct members, and
# repeated dispatches of the same member (retries) still collapse to one — the dedup that matters.
# Falls back to distinct agent names for dispatch paths that record no artifact, taking the LARGER of
# the two counts so neither shape under-counts a genuine panel.
_panel_was_dispatched() {
  local _want="${1:-2}" _sid_short _dir _log _rows="" _n_art _n_agent
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      _rows="${_rows}$(grep -E "agent=(${_PANEL_REVIEWERS_RE})\|mode=[^|]*\|status=ok" "$_log" 2>/dev/null \
        | grep -vE '\|mode=agent-self(-[a-z0-9]+)?\|')
"
    done
  done
  [ -n "$(printf '%s' "$_rows" | tr -d '[:space:]')" ] || return 1
  _n_art=$(printf '%s\n' "$_rows"   | grep -oE '\|artifact=[^|]+' | sed 's/|artifact=//' | grep . | sort -u | grep -c .)
  _n_agent=$(printf '%s\n' "$_rows" | grep -oE 'agent=[^|]+'      | sed 's/agent=//'     | grep . | sort -u | grep -c .)
  [ "${_n_art:-0}" -ge "${_n_agent:-0}" ] 2>/dev/null || _n_art="$_n_agent"
  [ "${_n_art:-0}" -ge "$_want" ] 2>/dev/null
}

_fallback_reviewer_dispatched() {
  local _sid_short _dir _log
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  if [ -n "${_TX_SIGNALS:-}" ]; then
    printf '%s\n' "$_TX_SIGNALS" | grep -qE "\"subagent_type\":\"(${_FALLBACK_REVIEWERS_RE})\"$|--agent[ =\"]+(${_FALLBACK_REVIEWERS_RE})$" && return 0
  fi
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      grep -qE "agent=(${_FALLBACK_REVIEWERS_RE})\|mode=[^|]*\|status=ok" "$_log" 2>/dev/null && return 0
    done
  done
  return 1
}

# W5G-4 (forensic 2026-06-07): post-dispatch tamper detection. v-dispatch-subagent.sh
# now appends `sha256=<hash>` of the artifact to its status=ok provenance line. If the
# on-disk artifact no longer matches the hash the dispatcher recorded, the content is
# NOT what the independent runner produced — one production session hand-padded the runner's
# 766B PRE_FLIGHT to 1425B via Write (keeping `Model: haiku`), and another hand-wrote
# an AGENT_REVIEW under a haiku header; both passed as 'dispatched' because provenance
# was checked by EXISTENCE, not content. rc 0 = definite mismatch; rc 1 = no recorded
# hash / no tool / hash matches (legacy provenance lines without sha256= stay exempt).
_artifact_postdispatch_edited() {
  local _file="$1" _base _sid_short _dir _log _lines="" _rec_sha _cur_sha _sha_cmd
  [ -n "$_file" ] && [ -f "$_file" ] || return 1
  # FIX-5 (self-audit 2026-06-18): portable sha256 — Linux CI ships `sha256sum` but not
  # `shasum`. Without this fallback, tamper detection silently returned 1 (no-mismatch) on
  # such hosts, effectively disabling the gate. Both tools emit the same 64-hex SHA-256, so a
  # marker written by either (v-dispatch-subagent.sh emit_marker, same fallback) verifies here.
  # When NEITHER tool exists, behavior is UNCHANGED: return 1 (graceful degradation — the gate
  # never falsely claims tampering when it cannot compute a hash).
  if command -v shasum >/dev/null 2>&1; then _sha_cmd="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then _sha_cmd="sha256sum"
  else return 1; fi
  _base=$(basename "$_file")
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      _lines="${_lines}$(grep -E "\|status=ok\|.*\|artifact=${_base}\|sha256=[0-9a-fA-F]{64}$" "$_log" 2>/dev/null)
"
    done
  done
  # Newest ok-record wins (ISO ts field sorts lexically; QA-loop re-dispatches
  # legitimately re-hash the artifact on every iteration).
  _rec_sha=$(printf '%s' "$_lines" | awk 'NF' | sort | tail -1 | sed -nE 's/.*\|sha256=([0-9a-fA-F]{64})$/\1/p')
  [ -n "$_rec_sha" ] || return 1
  _cur_sha=$($_sha_cmd "$_file" 2>/dev/null | awk '{print $1}')
  [ -n "$_cur_sha" ] || return 1
  [ "$_cur_sha" != "$_rec_sha" ]
}

# ORCHFIX-E4 (forensics 2026-07-02): _dispatched_original_survives <artifact_file> -> 0|1
# Precondition helper for the W5G-4 'Post-dispatch edit:' declared-edit downgrade: at least ONE
# dispatcher-recorded status=ok sha256 for this artifact basename must still match SOME file in the
# durable stores (ARTIFACT_SEARCH_DIRS, .v/tmp, .v/archive/<sid>) — under ANY filename, so renames,
# -postmerge variants, .stale copies, and archived originals all count; only DELETION fails. Callers
# invoke this only after _artifact_postdispatch_edited proved a recorded-sha mismatch, so at least one
# recorded sha exists (rc 1 with no recorded sha is therefore unreachable in practice, and safe).
# Candidate files are bounded to SID-tagged / variant / stale / rejected names — never a full-root scan.
_dispatched_original_survives() {
  local _file="$1" _base _sid_short _dir _log _lines="" _sha_cmd _rec_shas _cand _cand_sha _scan_dirs=()
  [ -n "$_file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then _sha_cmd="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then _sha_cmd="sha256sum"
  else return 0; fi   # cannot hash → cannot prove destruction → fail-open (matches W5G-4's degradation)
  _base=$(basename "$_file")
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _scan_dirs+=("$_dir")
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      _lines="${_lines}$(grep -E "\|status=ok\|.*\|artifact=${_base}\|sha256=[0-9a-fA-F]{64}$" "$_log" 2>/dev/null)
"
    done
  done
  _rec_shas=$(printf '%s' "$_lines" | sed -nE 's/.*\|sha256=([0-9a-fA-F]{64})$/\1/p' | sort -u)
  [ -n "$_rec_shas" ] || return 0   # no recorded sha → nothing provably destroyed → fail-open
  [ -n "${REPO_ROOT:-}" ] && _scan_dirs+=("$REPO_ROOT/.v/tmp" "$REPO_ROOT/.v/archive/${SESSION_ID}")
  for _dir in "${_scan_dirs[@]}"; do
    [ -d "$_dir" ] || continue
    for _cand in "$_dir"/*"${_sid_short}"* "$_dir"/*.stale.* "$_dir"/rejected-*; do
      [ -f "$_cand" ] || continue
      _cand_sha=$($_sha_cmd "$_cand" 2>/dev/null | awk '{print $1}')
      [ -n "$_cand_sha" ] || continue
      if printf '%s\n' "$_rec_shas" | grep -qxF "$_cand_sha"; then return 0; fi
    done
  done
  return 1
}

# validate_bite_ledger <ledger_file> [changed_invariant_dirs] -> 0 if the ledger carries >=1 WELL-FORMED
# bite entry, 1 otherwise. Closes the EXISTENCE-only trust hole in the P2-BITE-LEDGER gate (audit
# 2026-06-19): a `touch BITE_LEDGER_<sid>.md` (empty / hand-forged) used to satisfy the now-BLOCKING
# gate, which checked `[ -f ]` only. A VALID entry must prove a real TDD bite — red-exit non-zero (the
# test BIT the pre-fix oracle), green-exit 0 (passes after the fix), a harness, AND an invariant path
# under a tracked dir that ACTUALLY changed this session (so you cannot satisfy the gate by recording a
# bite for an unrelated/unchanged file). v-bite-ledger.sh enforces red!=0/green==0 at WRITE time; this
# RE-checks at the GATE so a ledger hand-authored around the tool is caught.
# CEILING (audit 2026-06-19): this raises the forgery bar but does NOT fully close it — a same-UID actor
# can still hand-craft a well-formed entry naming a real changed file (the documented same-UID forgery
# ceiling, identical to every other witness). It eliminates the trivial empty/touch/zero-red bypass.
validate_bite_ledger() {
  local _ledger="$1"
  local _dirs="${2:-hooks/ hooks/lib/ skills/v/references/ scripts/}"
  [ -f "$_ledger" ] || { echo "bite ledger file does not exist"; return 1; }
  if ! grep -qE '^##[[:space:]]+Bite' "$_ledger" 2>/dev/null; then
    echo "bite ledger has no '## Bite' entries (empty or hand-touched file)"
    return 1
  fi
  if awk -v dirs="$_dirs" '
    function check() { if (in_entry && have_inv && have_harness && red_ok && green_ok) valid=1 }
    BEGIN { ndirs=split(dirs, D, " ") }
    /^##[[:space:]]+Bite/ { check(); in_entry=1; have_inv=0; have_harness=0; red_ok=0; green_ok=0; next }
    in_entry && /^\|[[:space:]]*invariant/ {
      if (match($0, /`[^`]+`/)) {
        p=substr($0, RSTART+1, RLENGTH-2)
        # PREFIX match (index==1), NOT substring — else "not-a-real-hooks/x" or a "plugins/.../hooks/x"
        # path would forge membership in the changed dir. Consistent with the trigger-side grep "^${dir}".
        # [SREV-001, codex review 2026-06-19]
        for (i=1;i<=ndirs;i++) { if (D[i]!="" && index(p, D[i])==1) have_inv=1 }
      }
    }
    in_entry && /^\|[[:space:]]*harness/ { if (match($0, /`[^`]+`/)) have_harness=1 }
    # red/green: take the FIRST whitespace/pipe-delimited token and require it to be a STRICT integer —
    # "0.5" must NOT parse as 0 (first-[0-9]+-wins would accept a non-integer forgery). [SREV-002, codex 2026-06-19]
    in_entry && /^\|[[:space:]]*red-exit/ {
      v=$0; sub(/^\|[^|]*\|[[:space:]]*/, "", v); split(v, T, /[[:space:]|]/); if (T[1] ~ /^[0-9]+$/ && T[1]+0 != 0) red_ok=1
    }
    in_entry && /^\|[[:space:]]*green-exit/ {
      v=$0; sub(/^\|[^|]*\|[[:space:]]*/, "", v); split(v, T, /[[:space:]|]/); if (T[1] ~ /^[0-9]+$/ && T[1]+0 == 0) green_ok=1
    }
    END { check(); exit (valid?0:1) }
  ' "$_ledger"; then
    return 0
  fi
  echo "bite ledger has no VALID bite entry (need ONE entry with: invariant under a changed tracked dir + harness + red-exit!=0 + green-exit==0)"
  return 1
}

# _independence_verdict <artifact_file> <agent> -> dispatched | edited | edited-declared | declared | silent | unverifiable
#   declared = NO independent dispatch is on record; the artifact honestly states it was
#              self-authored/degraded (the documented inline-fallback path)
#   edited-declared = F2 (2026-08-29): an independent dispatch DID run, the artifact was edited
#              afterward, the edit is honestly declared (`Post-dispatch edit:`) AND the dispatched
#              original still survives. Split out of `declared` because the two are OPPOSITE
#              situations that every consumer was reporting with the same words: each `declared)`
#              arm asserts "no independent <agent> dispatch found", which is FALSE here and told
#              honest sessions to re-dispatch a reviewer that had already run. Measured: 22
#              artifacts machine-wide carry the signature, 3 currently resolve here.
#              CONSUMER CONTRACT: `edited-declared` is informational, BUT anywhere `declared`
#              feeds a TAMPER / VERDICT-FLIP guard (not an "was anything dispatched?" test) the
#              new token MUST be handled identically. Live example: check-review-artifact.sh's
#              PRE_FLIGHT B1 verdict-flip guard enumerates it explicitly.
#              DO NOT cite the I1-WF baseline guard as protection for this token. It is gated on
#              `! _provenance_baseline_exists`, and that predicate uses the SAME provenance grep as
#              `_artifact_postdispatch_edited` — which must have fired for this token to exist at
#              all. So a baseline is ALWAYS present here and I1-WF never evaluates. It enumerates
#              the token only so the arm cannot silently lapse if that predicate ever changes.
#              The real control on the three edited-declared arms is
#              _declared_edit_discloses_verdict_change below.
#   edited   = W5G-4: an independent dispatch ran, but the artifact was modified AFTERWARD
#              (provenance sha256 mismatch) with no explicit `Post-dispatch edit:` declaration,
#              or with one whose dispatched original no longer survives (ORCHFIX-E4)
# _declared_edit_discloses_verdict_change <artifact_file>
#   rc 0 = the artifact's own text DISCLOSES that a post-dispatch edit changed a finding, verdict,
#          severity or status (i.e. the edit was not prose-only)
#   rc 1 = no such disclosure
#
# F2-B1MIRROR-SHARED (2026-08-29, adversarial review PANEL-SECURITY-002 + codex CRITICAL/HIGH).
# WHY THIS IS A SHARED FUNCTION AND NOT THREE INLINE COPIES: the `edited-declared` token needs this
# check at THREE consumer arms (AGENT_REVIEW, QA_REPORT, WORKFLOW_VERIFICATION). Three inline
# regexes is precisely the drift defect F1 exists to catch — they would silently diverge, and the
# weakest copy would become the real gate. One definition, three call sites.
#
# WHY IT IS NEEDED AT ALL: before the F2 token split, the dispatched-then-edited-then-declared shape
# resolved to `declared`, and each `declared)` arm happened to BLOCK it for the wrong reason —
# AGENT_REVIEW demanded a "superpowers fallback attempted" line, QA_REPORT demanded a
# `Dispatch mode: … (reason)` shape that a bare `Post-dispatch edit:` line never matches. Both were
# accidental blocks, but they WERE blocks. Splitting the token to an informational arm removed them,
# which is a gate that closes today opening tomorrow. This restores the block for the only sub-case
# that is actually dangerous — an edit that changed what the independent reviewer concluded —
# while leaving an honest prose-only correction as a warning.
#
# CEILING, stated honestly (SREV-004's framing): this is keyword-based HONESTY FRICTION, not
# cryptographic proof. An edit that silently deletes a CRITICAL finding and discloses nothing does
# not match. It narrows the hole rather than closing it; the durable fix is a content diff against
# the archived original, which no consumer performs today.
#
# TWO INDEPENDENT SIGNALS, OR'd. The keyword scan alone is NOT sufficient: the codex adversarial
# review's actual fixture disclosed `Post-dispatch edit: fixed a formatting typo.` — a LIE — while
# the verdict went escalated→pass. No keyword matches a lie, so signal (2) compares the artifact's
# own verdict/status line against the SURVIVING DISPATCHED ORIGINAL and blocks on any difference.
# That closes the case the keyword scan cannot see, and it is evidence-based rather than lexical.
_dispatched_original_path() {
  # Echo the path of a durable file whose sha256 matches a RECORDED status=ok dispatch sha for this
  # artifact's basename; echo nothing when none is found or the answer cannot be determined.
  # Mirrors _dispatched_original_survives' candidate search deliberately and is kept SEPARATE from
  # it: that function's fail-OPEN returns ("cannot hash", "no recorded sha") must not change, and a
  # caller of this one must treat "empty" as "unknown", never as proof of anything. Because the
  # comparison below only ever ADDS a block when a real original is found, an empty answer can
  # never weaken an existing gate.
  local _file="${1:-}" _base _sid_short _dir _log _lines="" _sha_cmd _rec_shas _cand _cand_sha
  local _scan_dirs=()
  [ -n "$_file" ] || return 1
  if command -v shasum >/dev/null 2>&1; then _sha_cmd="shasum -a 256"
  elif command -v sha256sum >/dev/null 2>&1; then _sha_cmd="sha256sum"
  else return 1; fi
  _base=$(basename "$_file")
  _sid_short=$(printf '%s' "${SESSION_ID:-}" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    _scan_dirs+=("$_dir")
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID:-}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      _lines="${_lines}$(grep -E "\|status=ok\|.*\|artifact=${_base}\|sha256=[0-9a-fA-F]{64}$" "$_log" 2>/dev/null)
"
    done
  done
  _rec_shas=$(printf '%s' "$_lines" | sed -nE 's/.*\|sha256=([0-9a-fA-F]{64})$/\1/p' | sort -u)
  [ -n "$_rec_shas" ] || return 1
  [ -n "${REPO_ROOT:-}" ] && _scan_dirs+=("$REPO_ROOT/.v/tmp" "$REPO_ROOT/.v/archive/${SESSION_ID:-}")
  for _dir in "${_scan_dirs[@]}"; do
    [ -d "$_dir" ] || continue
    for _cand in "$_dir"/*"${_sid_short}"* "$_dir"/*.stale.* "$_dir"/rejected-*; do
      [ -f "$_cand" ] || continue
      [ "$_cand" = "$_file" ] && continue          # the edited file is not its own original
      _cand_sha=$($_sha_cmd "$_cand" 2>/dev/null | awk '{print $1}')
      [ -n "$_cand_sha" ] || continue
      if printf '%s\n' "$_rec_shas" | grep -qxF "$_cand_sha"; then printf '%s' "$_cand"; return 0; fi
    done
  done
  return 1
}

_artifact_verdict_tokens() {
  # Normalized verdict/status lines: the fields a laundering edit has to change to be useful.
  # Covers AGENT_REVIEW (Overall / Status), QA_REPORT (verdict:) and WORKFLOW_VERIFICATION
  # (status:, golden_path:). Lowercased and whitespace-collapsed so pure reformatting is not a diff.
  local _f="${1:-}"
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  grep -ioE '^[[:space:]#>*-]*(overall[[:space:]]*status|overall|verdict|status|golden_path)[[:space:]]*:[[:space:]]*[a-z_()-]+' "$_f" 2>/dev/null \
    | tr 'A-Z' 'a-z' | tr -s '[:space:]' ' ' | sed 's/[[:space:]]*$//' | sort
}

_declared_edit_discloses_verdict_change() {
  local _f="${1:-}" _orig
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  # (1) the edit's own prose admits a finding/verdict/severity change
  if grep -qiE 'correct(s|ed|ing)?[^.]{0,40}(finding|verdict|severity|status)|overr(o|i)d[^.]{0,30}(finding|verdict|severity|status)|flip[^.]{0,20}(verdict|finding|status)|(remov|delet|drop|strik)(e|ed|ing)?[^.]{0,30}(finding|critical|high)|downgrad[^.]{0,30}(severity|finding|verdict|status)|(reject|fail)(ed)?[^.]{0,20}(to|->|→)[^.]{0,20}(approv|pass)' \
      "$_f" 2>/dev/null; then
    return 0
  fi
  # (2) the verdict/status actually differs from the surviving dispatched original — catches the
  # lying disclosure the keyword scan cannot. Only fires when an original is genuinely located.
  _orig="$(_dispatched_original_path "$_f" 2>/dev/null || true)"
  [ -n "$_orig" ] && [ -f "$_orig" ] || return 1
  [ "$(_artifact_verdict_tokens "$_orig")" = "$(_artifact_verdict_tokens "$_f")" ] || return 0
  return 1
}

_independence_verdict() {
  local _file="$1" _agent="$2"
  local _forg_lines
  if _agent_was_dispatched "$_agent"; then
    if _artifact_postdispatch_edited "$_file"; then
      # An honest declaration downgrades to the documented-fallback path (warn),
      # exactly like a declared inline review — the independence loss is visible.
      # ORCHFIX-E4 (forensics 2026-07-02): the declaration is honored ONLY while the
      # originally-dispatched content still exists somewhere durable. A production session overwrote the
      # canonical pre-merge report with a -postmerge variant, rm'd the variant, then used this
      # escape — the signed provenance chain was destroyed end-to-end and the downgrade waved it
      # through. An escape that accepts "original destroyed" defeats the exact hand-padding case
      # W5G-4 exists to stop. Renames/archives are fine; deletion is not.
      if grep -qiE '^Post-dispatch edit:' "$_file" 2>/dev/null; then
        # F2: `edited-declared`, NOT `declared` — a real dispatch IS on record here.
        if _dispatched_original_survives "$_file"; then echo "edited-declared"; return; fi
        echo "edited"; return
      fi
      echo "edited"; return
    fi
    echo "dispatched"; return
  fi
  # Artifact explicitly claims an external tool "ran" but no dispatch evidence exists anywhere
  # (no DISPATCH_PROVENANCE, no transcript subagent_type signal) → trust violation regardless of
  # what dispatch-mode the artifact claims. This covers both inline self-review ("Dispatch mode:
  # orchestrator-inline") AND forged foreground claims ("Dispatch mode: foreground") that have no
  # backing provenance — the observed pattern: artifact said "ran" + "foreground" but DISPATCH_PROVENANCE
  # was absent and TRANSCRIPT_READABLE=0, causing "unverifiable" (warn-only) instead of a block.
  # ORCHFIX-E3 (forensics 2026-07-02 — 2nd live specimen of the substring-trap class):
  # an HONEST fallback description ("Codex adversarial reviewer: codex CLI unavailable — ...;
  # adversarial review instead RAN as an independent logic-reviewer subprocess") matched this
  # branch and silent-BLOCKED, driving artifact-wordsmithing loops. A matching line that NEGATES
  # codex execution (unavailable / not executed / did not run) or attributes 'ran' to a FALLBACK
  # ("instead") is not a codex-ran claim. Only lines WITHOUT such context count as forged claims.
  # The honest-labeling requirement is UNCHANGED: a bare "codex ... ran" with no provenance still
  # blocks, and the fallback-provenance rescue below still requires a REAL dispatch record.
  # REV-1 hardening (adversarial review 2026-07-03): only STRONG codex-negations exempt a line —
  # 'unavailable' / 'not executed|run|available' / 'did not run' / 'never ran'. The weak lone
  # tokens 'fallback'/'instead' were plantable anywhere in a forged line ("Codex adversarial
  # reviewer: ran the full scan instead of anything else" escaped). A negation-planted claim that
  # somehow escapes here still only reaches 'dispatched' when REAL fallback provenance exists
  # (B-FALLBACK below), so the outcome stays truthful.
  _forg_lines=$(grep -iE '(codex[[:space:]_-]adversarial[[:space:]_-]reviewer|codex[[:space:]_-]cli)[[:space:]]*:.*\bran\b' "$_file" 2>/dev/null || true)
  if [ -n "$_forg_lines" ] \
     && printf '%s\n' "$_forg_lines" | grep -qivE 'unavailab|not[[:space:]]+(executed|run|available)|did[[:space:]]+not[[:space:]]+run|never[[:space:]]+ran'; then
    echo "silent"; return
  fi
  # Wrong-tree admission (Wave-H H-10; single-sourced into _independence_verdict 2026-06-15
  # so BOTH the Stop hook and v-completion-selfcheck.sh detect it — previously only the producer
  # self-check's inline-signature regex did, a producer↔gate gap). A review that admits it examined
  # MAIN / the wrong diff did NOT review THIS session's changes, so it is not independent for this
  # diff → silent (blocks) when no independent dispatch is on record above. CODEX-004 FP-guard: the
  # bare 'ran from main' needs an admission keyword (diff/fallback/instead) on the same line, so
  # benign post-merge prose ("tests ran from main checkout after merge") cannot trip it.
  # codex review (LOW): bound the 'ran from main … (diff|fallback|instead)' gap to the SAME clause
  # ([^.;]{0,40}, no line-spanning .*) so a benign single-line co-occurrence ("the suite ran from main;
  # the worktree diff was identical") cannot FP, while the H-10 admission ("ran from main (examined main
  # diff, not H-10 diff)") still matches.
  if grep -qiE '(examined|reviewed)[[:space:]]+(the[[:space:]]+)?main[^[:space:]]{0,2}[[:space:]]+diff|ran[[:space:]]+from[[:space:]]+main[^a-z][^.;]{0,40}(diff|fallback|instead)|wrong[[:space:]_-](tree|diff|branch)' "$_file" 2>/dev/null; then
    echo "silent"; return
  fi
  # B-FALLBACK (forensic 2026-06-16, production session): the codex CLI is intermittently unavailable; the
  # SANCTIONED fallback (CLAUDE.md) is an independent superpowers / Agent-tool reviewer subagent. A REAL
  # dispatch of one (transcript subagent_type — parent or subagents/ tree — or a status=ok provenance line)
  # IS an independent adversarial review of THIS diff, so it satisfies the codex-independence requirement.
  # Scoped to the codex agent ONLY (the QA/UX independence checks pass a different <agent> and never reach
  # here). Ordered AFTER the forgery + wrong-tree 'silent' checks above so a FALSE 'codex … ran' claim
  # (no codex evidence) still BLOCKS even when a fallback ran — the model must label honestly, which then
  # passes via this path (recoverable, never a dead-end). Pre-fix this false-blocked the honest fallback and
  # the model laundered it into 'Dispatch mode: manual' (which the declared allowlist below still accepts).
  # ── PANEL branch (2026-08-03) ────────────────────────────────────────────────────────────────────
  # A structurally valid `Adversarial review: panel=N …` field IS an independent adversarial review of
  # this diff when >= N distinct reviewer agents have real status=ok dispatch rows. That cross-check is
  # the whole point: unlike the free-text codex field, the declared number cannot be typed into the
  # artifact without the dispatches existing. Ordered deliberately AFTER the forgery + wrong-tree
  # 'silent' branches above, so an artifact that pairs a panel field with a fabricated "codex … ran"
  # claim, or that admits reviewing the wrong tree, still BLOCKS. Mirrors the other branches' W5G-4
  # edited handling (ORCHFIX-H1's lesson: a rescue that skips the edited check lets a hand-edited
  # AGENT_REVIEW through on the most common review path).
  local _pnl_line _pnl_n
  _pnl_line=$(_panel_field_extract "$_file")
  if [ -n "$_pnl_line" ] && _pnl_n=$(_panel_field_valid "$_pnl_line") && _panel_was_dispatched "$_pnl_n"; then
    if _artifact_postdispatch_edited "$_file"; then
      if grep -qiE '^Post-dispatch edit:' "$_file" 2>/dev/null && _dispatched_original_survives "$_file"; then
        # F2: panel dispatches ARE on record — `edited-declared`, not `declared`.
        echo "edited-declared"; return
      fi
      echo "edited"; return
    fi
    echo "dispatched"; return
  fi

  if { [ "$_agent" = "codex-adversarial-reviewer" ] || [ "$_agent" = "codex" ]; } && _fallback_reviewer_dispatched; then
    # ORCHFIX-H1 (P0, forensics 2026-07-02, one project): this rescue returned 'dispatched'
    # WITHOUT the W5G-4 edited check. The dispatcher records the artifact sha256 on fallback
    # dispatches exactly as on codex ones, but NOTHING consumed it on this path (the
    # computed-but-not-consumed inert-guard class) — a silently hand-edited AGENT_REVIEW passed
    # the Stop gate whenever the review ran via the sanctioned fallback reviewer, which is the
    # MOST COMMON review path in this environment (codex CLI unavailable). The affected session's on-disk
    # review no longer matched its dispatch record and carried no
    # declaration, yet attest+Stop passed. Mirror the primary branch: edited → block; an honest
    # declaration downgrades only while the dispatched original still survives (ORCHFIX-E4).
    if _artifact_postdispatch_edited "$_file"; then
      if grep -qiE '^Post-dispatch edit:' "$_file" 2>/dev/null && _dispatched_original_survives "$_file"; then
        # F2: the sanctioned FALLBACK reviewer really was dispatched — `edited-declared`.
        echo "edited-declared"; return
      fi
      echo "edited"; return
    fi
    echo "dispatched"; return
  fi
  # B-2 (forensic 2026-06-15, OPEN #1): an HONEST inline declaration in the documented
  # "Dispatch mode: orchestrator-inline (reason)" FIELD format — the exact format the Stop hook's own
  # error text recommends — must resolve to 'declared' (warn, honest degradation), NOT silent→BLOCK.
  # The prior declared-regex below only recognized a line-start `dispatch:`/`degraded:`/`status: degraded`,
  # so the recommended field format fell through to 'silent' and punished honesty. The forgery branch
  # above (codex/external tool "ran" without provenance) already fired FIRST, so a FABRICATED independence
  # claim is still blocked regardless of declared dispatch-mode → order-safe. We accept ONLY the
  # honest-degradation values; 'foreground'/'subagent-dispatched' are dispatch CLAIMS that REQUIRE
  # evidence (resolved by _agent_was_dispatched / the silent branch) and are deliberately excluded here.
  if grep -qiE '^[[:space:]#>*-]*dispatch[[:space:]]+mode[[:space:]]*:[[:space:]]*(orchestrator[_-]?inline|inline|degraded|manual)' "$_file" 2>/dev/null; then
    echo "declared"; return
  fi
  if grep -qiE '^[[:space:]]*(dispatch|provenance):[[:space:]]*(inline|orchestrator|manual|self|degraded|unavailable)|^[[:space:]]*degraded(_reason)?:|^status:[[:space:]]*degraded|dispatch[[:space:]_-]*(unavailable|inline|manual|degraded)' "$_file" 2>/dev/null; then
    echo "declared"; return
  fi
  # ORCHFIX-E (forensics 2026-07-02): default the var — standalone sourcing (readiness probes,
  # tests) left it unset and crashed here with `[: : integer expected`, muddying diagnostics.
  if [ "${TRANSCRIPT_READABLE:-0}" -eq 1 ]; then echo "silent"; else echo "unverifiable"; fi
}

# FIX-6 (self-audit survivor): _independence_silent_reason <artifact_file> -> claimed-dispatch | honest-inline
#
# When _independence_verdict returns 'silent' (=BLOCK), there are two materially-different causes the
# consumers' error messages used to conflate:
#   • claimed-dispatch — the artifact CLAIMS an independent dispatch ("Dispatch mode: subagent-dispatched
#     | foreground | background", or "codex … ran") but NO provenance backs it → a forged/fabricated
#     independence claim. The operator must STOP claiming and either dispatch for real or declare inline.
#   • honest-inline    — the artifact makes no dispatch claim at all; it is just an undisclosed inline
#     self-review → the operator should DECLARE the inline fallback ("Dispatch mode: orchestrator-inline
#     (reason)") so the verdict downgrades to 'declared' (warn).
# The VERDICT is unchanged (both still BLOCK); this ONLY selects clearer remediation wording. Single-
# sourced so the Stop hook (check-review-artifact.sh) and the producer self-check (v-completion-
# selfcheck.sh) print the SAME message and can never drift. FP-safe default: honest-inline.
_independence_silent_reason() {  # <artifact_file>
  local _file="$1"
  [ -f "$_file" ] || { echo "honest-inline"; return; }
  # A dispatch-mode CLAIM that requires evidence (foreground/background/subagent-dispatched/dispatched),
  # OR an external-tool "ran" assertion — both with no provenance is what brought us to 'silent'.
  if grep -qiE '^[[:space:]#>*-]*\**[[:space:]]*dispatch[[:space:]]+mode[[:space:]]*:[[:space:]]*(subagent[_-]?dispatched|foreground|background|dispatched)' "$_file" 2>/dev/null \
     || grep -qiE '(codex[[:space:]_-]adversarial[[:space:]_-]reviewer|codex[[:space:]_-]cli)[[:space:]]*:.*\bran\b' "$_file" 2>/dev/null; then
    echo "claimed-dispatch"; return
  fi
  echo "honest-inline"
}

# I1 (forensic 2026-06-17, HARDEN-SCOPE): tamper-evidence BASELINE presence.
# A verdict:pass QA_REPORT needs at least ONE recorded sha256 baseline — a status=ok DISPATCH_PROVENANCE
# line naming the artifact — so a later fail->pass hand-flip is catchable by _artifact_postdispatch_edited.
# One session ran QA inline-on-main and wrote NO provenance line at all; when the Stop hook ALSO could not
# read the transcript, the QA independence verdict was 'unverifiable' (warn) with ZERO tamper-evidence —
# a post-hoc flip would have been invisible. This helper distinguishes "unverifiable but a baseline exists"
# (some evidence — keep the warn) from "unverifiable AND no baseline" (zero evidence — fail-close).
# Returns 0 (true) iff a status=ok sha256 baseline for <basename> exists in any artifact search dir, in
# ANY mode (incl. agent-self — this is the TAMPER baseline, a different axis from independence: SREV-004
# keeps agent-self OUT of _agent_was_dispatched, which is the independence check, not this one).
_provenance_baseline_exists() {
  local _base="$1" _sid_short _dir _log
  [ -n "$_base" ] || return 1
  _sid_short=$(printf '%s' "$SESSION_ID" | cut -c1-8)
  for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
    [ -z "$_dir" ] && continue
    for _log in "$_dir/DISPATCH_PROVENANCE_${SESSION_ID}.log" "$_dir/DISPATCH_PROVENANCE_${_sid_short}.log"; do
      [ -f "$_log" ] || continue
      grep -qE "\|status=ok\|.*\|artifact=${_base}\|sha256=[0-9a-fA-F]{64}$" "$_log" 2>/dev/null && return 0
    done
  done
  return 1
}

# ── Survival invariant (1A, forensic 2026-06-15: the silent-wipe class) ─────────
# THE recurring cross-wave failure: a session WRITES source files, passes every gate, then its
# uncommitted work is silently WIPED (a concurrent sibling's stash/restore on shared main) — and /v
# reports green. Detectors only ever caught it POST-HOC (v-session-log diff-grounding). This promotes
# that signal to a LIVE, single-sourced verdict that BOTH the Stop hook and the producer self-check
# consume, so they cannot disagree (the _independence_verdict pattern).
#
# Invariant: every SOURCE file a session wrote must still produce a NET diff vs the session baseline
# somewhere recoverable — the working tree, a commit since baseline, or the session's worktree branch.
# A wrote source file byte-IDENTICAL to baseline everywhere = its change was undone. NOTE: the file may
# still EXIST on disk (reverted to baseline content); existence is NOT survival — the *diff* is. That
# is exactly why the original incident slipped every prior check: View.tsx still existed, just reverted to baseline.
#
# Echoes exactly one of:
#   ok               — every wrote source file survives, or the session wrote no source (read-only)
#   skip:<reason>    — cannot assess (no writes-log / no baseline / declared-incomplete) → FP-SAFE, never blocks
#   lost:<n>:<files> — n wrote source files vanished with no handoff/deferral marker = the silent-wipe signature
#
# CONSERVATIVE BY DESIGN: fires ONLY when ALL wrote source files vanished (the "built X, nothing of X
# remains" signature). A partial loss is far likelier an intentional revert, so it is NOT blocked here
# (it still surfaces in the session-log). Skips on ANY uncertainty. Mode is chosen by the CALLER via
# $V_SURVIVAL_GATE (warn|block|off) — shipped WARN-first, promoted to block once the racing harness
# proves no false-fire.
# ORCHFIX-C: single-sourced from hooks/lib/code-ext-pattern.sh (the Stop/commit gates' pattern —
# survival-gate test S17 pins the lock-step; this was the THIRD drifted inline copy). Config
# extensions are equally survival-relevant: a vanished .github/workflows edit is exactly the
# same class. Telemetry artifacts are filtered by CODE_EXT_EXEMPT at the two consumer
# pipelines below (SESSION_LOG_*.yaml written to root must never read as un-survived source).
if [ -f "${BASH_SOURCE[0]%/*}/code-ext-pattern.sh" ]; then
  # shellcheck source=code-ext-pattern.sh
  source "${BASH_SOURCE[0]%/*}/code-ext-pattern.sh"
  _SURVIVAL_CODE_EXT_RE="$CODE_EXT_PATTERN"
else
  _SURVIVAL_CODE_EXT_RE='\.(php|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hh|hpp|cs|scala|ex|exs|sh|bash|zsh|sql|m|mm|dart|lua|pl|pm|r|clj|cljs|erl|hs|yml|yaml|json|neon|toml|lock)$|(^|/)Dockerfile[^/]*$|(^|/)Makefile$|(^|/)\.husky/[^/.]+$|(^|/)\.github/workflows/[^/]+$'
  CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
fi
# Dependency manifests (forensic 2026-06-19): an inline-on-main session left composer.json/composer.lock
# UNCOMMITTED on shared main, which deadlocked FOUR concurrent worktree merge-backs (FND-3 deferred over
# the foreign WIP rather than stash it) → all four stranded. These are build-critical, basename-specific
# (not an extension), and must count as exposed/survival "source" so an inline session is forced to
# commit them (scoped) before the wave's siblings deadlock on them.
_SURVIVAL_DEP_MANIFEST_RE='(^|/)(composer\.(json|lock)|package(-lock)?\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile(\.lock)?|go\.(mod|sum)|Cargo\.(toml|lock)|requirements\.txt|Pipfile(\.lock)?)$'
# Never "source": transient trees, vcs/agent dirs, dependency dirs. CODE_EXT filtering already drops
# .md/.yaml gate artifacts; this drops source-extension files that live in non-deliverable trees.
_SURVIVAL_EXCLUDE_RE='^\.v/|^\.git/|^\.claude/|^\.worktrees/|(^|/)node_modules/|(^|/)vendor/'

_survival_baseline_sha() {  # <sid> <repo> -> echo baseline SHA ("" if none)
  local _sid="$1" _repo="$2" _f
  for _f in "${V_TMP_DIR:-$_repo/.v/tmp}/head-baseline-${_sid}.txt" \
            "$_repo/.v/tmp/head-baseline-${_sid}.txt" \
            "${TMPDIR:+${TMPDIR%/}/head-baseline-${_sid}.txt}" \
            "/tmp/head-baseline-${_sid}.txt"; do
    # CDX-005: strip trailing CR/whitespace (a CRLF baseline file would otherwise yield "<sha>\r",
    # fail cat-file -e, and silently skip the gate) — parity with v-completion-selfcheck.sh's reader.
    [ -n "$_f" ] && [ -f "$_f" ] && { head -1 "$_f" 2>/dev/null | tr -d '[:space:]'; return; }
  done
}

_survival_has_marker() {  # <sid> <repo> -> 0 if a marker declares incompletion / non-code completion
  local _sid="$1" _repo="$2" _d _sz
  [ -f "$_repo/.v/tmp/merge-deferred-${_sid}.md" ] && return 0   # FND-3 worktree DEFER
  [ -f "$_repo/.v/artifacts/merge-deferred-${_sid}.md" ] && return 0   # F7: RC-4a durable copy (.v/tmp may be swept by a sibling git-clean)
  for _d in "$_repo" "$_repo/.v/artifacts"; do
    [ -d "$_d" ] || continue
    if [ -f "$_d/HANDOFF_${_sid}.md" ]; then
      _sz=$(wc -c < "$_d/HANDOFF_${_sid}.md" 2>/dev/null | tr -d ' ')
      [ "${_sz:-0}" -ge 80 ] && grep -qiE '^#+[[:space:]]*Handoff\b|MERGE_DEFERRED:' "$_d/HANDOFF_${_sid}.md" 2>/dev/null && return 0
    fi
    [ -f "$_d/BLOCKED_${_sid}.md" ] && return 0
    [ -f "$_d/MERGE_DEFERRED_${_sid}.md" ] && return 0
    # CDX-002: the producer self-check exits PASS on a TRIVIAL_PASS / PLANNING_PASS bypass BEFORE the
    # survival gate (v-completion-selfcheck.sh) — so the Stop hook must ALSO skip survival on those, or
    # the two gates disagree (self-check PASS, Stop BLOCK = the exact "lied about finishing" class the
    # single-sourcing exists to kill). These are honest "tiny/no-code change" declarations, like HANDOFF.
    # I1-B (audit 2026-06-18): require NON-EMPTY (-s, not bare -f) — a 0-byte `touch
    # TRIVIAL_PASS_<sid>.md` must not silently bypass the survival gate. The Stop hook's full
    # TRIVIAL validation (TRIVIAL=1/REASON=/FILE=/LINES=) is the structural gate; this is the
    # cheap FP-safe floor (a genuine marker always has content) that keeps the two gates in step.
    [ -s "$_d/TRIVIAL_PASS_${_sid}.md" ] && return 0
    [ -s "$_d/PLANNING_PASS_${_sid}.md" ] && return 0
  done
  return 1
}

_survival_wt_dir() {  # <sid> <repo> -> echo the session's worktree dir ("" if none)
  local _sid="$1" _repo="$2" _lock _w _b
  for _lock in "$_repo"/.worktrees/*/.claude-session-lock "$_repo"/.worktrees/*/*/.claude-session-lock; do
    [ -f "$_lock" ] || continue
    [ "$(awk '{print $1}' "$_lock" 2>/dev/null)" = "$_sid" ] && { dirname "$_lock"; return; }
  done
  # external worktrees: branch ends with the SID or its 8-char prefix (build/<name>-<sid8>)
  while IFS= read -r _line; do
    case "$_line" in
      worktree\ *) _w="${_line#worktree }" ;;
      branch\ *)   _b="${_line#branch }"
                   case "$_b" in *"$_sid"|*"-${_sid:0:8}") printf '%s\n' "$_w"; return ;; esac ;;
    esac
  done < <(git -C "$_repo" worktree list --porcelain 2>/dev/null || true)
}

_v_mtime_epoch() {  # <file> -> epoch mtime; "" if absent (codex CDX-005). GNU stat reads -f as a
  # *filesystem* stat, so a BSD-first chain returns garbage on Linux; try the GNU form first (BSD stat
  # rejects -c silently). Unlike branching on uname, this also holds on macOS with GNU coreutils first
  # on PATH. Guarded by scripts/portability-test.sh.
  [ -f "$1" ] || return 1
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _exposed_concurrency <sid> <repo> -> 0 if ANOTHER /v session was active concurrently with <sid>.
# ROBUST replacement for the worktree-only v-active-siblings signal, which is blind to INLINE siblings
# (no worktree lock) AND point-in-time-fragile (worktree siblings that cleaned up just before our Stop).
# Forensic 2026-06-16 (production incident): a 5-of-8-INLINE wave left no worktree lock at the inline session's Stop,
# so the exposed gate skipped (skip:no-active-siblings) and its work shipped UNCOMMITTED + exposed. The
# durable signal: ANY OTHER session's writes-log modified AT/AFTER this session's start (the head-baseline
# mtime, written once at Step 0) = that session wrote during my lifetime = real concurrency. The legacy
# worktree-lock check stays as a fast first signal. FP-safe: a genuinely-solo session finds no other
# writes-log touched during its window → returns 1 → the gate skips (the user's review-first flow is kept).
_exposed_concurrency() {  # <sid> <repo>
  # Initialize ALL locals — `local x` alone leaves x UNSET, and `[ -n "$x" ]` then errors under set -u
  # when no baseline exists (the no-baseline path); the v-exposed-inline-test.sh harness runs set -u.
  local _sid="$1" _repo="$2" _scr="" _gcd="" _start="" _f="" _omt="" _b="" _osid=""
  _scr="${V_ACTIVE_SIBLINGS_SCRIPT:-$HOME/.claude/skills/v/references/v-active-siblings.sh}"
  [ -f "$_scr" ] && [ -n "$(bash "$_scr" "$_repo" "$_sid" 2>/dev/null)" ] && return 0
  # My session start = head-baseline mtime. CDX-004: use the SAME 4-tier path list as
  # _survival_baseline_sha (incl. $TMPDIR + /tmp) so the forked/headless-runner layout, where the
  # baseline lands outside .v/tmp, is covered — otherwise the gate silently disables there.
  for _b in "${V_TMP_DIR:-$_repo/.v/tmp}/head-baseline-${_sid}.txt" \
            "$_repo/.v/tmp/head-baseline-${_sid}.txt" \
            "${TMPDIR:+${TMPDIR%/}/head-baseline-${_sid}.txt}" \
            "/tmp/head-baseline-${_sid}.txt"; do
    [ -n "$_b" ] && [ -f "$_b" ] && { _start=$(_v_mtime_epoch "$_b"); break; }
  done
  [ -n "$_start" ] || return 1   # cannot bound my window → make no concurrency claim (FP-safe)
  _gcd=$( cd "$_repo" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null ) || return 1
  case "$_gcd" in /*) ;; *) _gcd=$( cd "$_repo" 2>/dev/null && cd "$_gcd" 2>/dev/null && pwd ) || return 1 ;; esac
  for _f in "$_gcd"/claude-session-writes-*.txt; do
    [ -f "$_f" ] || continue
    case "$_f" in *"claude-session-writes-${_sid}.txt") continue ;; esac   # never count self
    _omt=$(_v_mtime_epoch "$_f"); [ -n "$_omt" ] || continue
    [ "$_omt" -ge "$_start" ] || continue   # only siblings active at/after my start
    # CDX-001 (FP guard): a sibling that already FINISHED (wrote its canonical SESSION_LOG) is not a
    # live clobberer — exclude it, so a stale prior session whose writes-log mtime gets bumped
    # (backup/AV/editor touch) during a solo window cannot false-fire. Still-running siblings have no
    # canonical log yet (it's written last) → they correctly count.
    _osid="${_f##*/claude-session-writes-}"; _osid="${_osid%.txt}"
    [ -f "$_repo/SESSION_LOG_${_osid}.yaml" ] && continue
    return 0   # an UNFINISHED sibling wrote during my window → genuine concurrency
  done
  return 1
}

_survival_file_survives() {  # <file> <base> <repo> <wt_dir> <sid> -> 0 if the file's change survives somewhere
  local _f="$1" _base="$2" _repo="$3" _wt="$4" _sid="$5" _owtpath _d2_owner _d2_branch _d2_short
  # (a) ANY uncommitted presence/modification in the main checkout — a NON-EMPTY porcelain line
  #     (modified / added / untracked / renamed / deleted) means the work is physically present in the
  #     tree. PRIMARY signal, and immune to git content normalization (CRLF / text=auto / whitespace),
  #     which can make `git diff` report no net change on a file that is visibly dirty (CDX-001 FP).
  [ -n "$(git -C "$_repo" status --porcelain -- "$_f" 2>/dev/null)" ] && return 0
  # (b) a net change vs the session baseline reflected in the main checkout (committed since baseline):
  [ -n "$(git -C "$_repo" diff --name-only "$_base" -- "$_f" 2>/dev/null)" ] && return 0
  # (c) the session's worktree (a worktree session's work lives on its branch, not main's tree):
  if [ -n "$_wt" ] && [ -d "$_wt" ]; then
    [ -n "$(git -C "$_wt" status --porcelain -- "$_f" 2>/dev/null)" ] && return 0
    [ -n "$(git -C "$_wt" diff --name-only "$_base" -- "$_f" 2>/dev/null)" ] && return 0
  fi
  # (d) FIX (forensic 2026-08-18): _survival_wt_dir can only identify "the" session
  # worktree via a .claude-session-lock file or a branch name ending in the session ID/prefix — both
  # conventions a /v-provisioned worktree follows, but a worktree created BY HAND (or by an earlier,
  # unrelated part of the same conversation, for a different purpose, with a human-chosen branch name
  # like "docs/example-study") matches neither, so $_wt above is empty and check (c) never
  # engages. Fall back to every OTHER worktree the repo actually has (skip $_repo and $_wt, already
  # checked).
  #
  # (d2) FIX (forensic 2026-08-18/19, follow-up — adversarial review): (d) as
  # originally shipped is ATTRIBUTION-BLIND — "some OTHER worktree is dirty at this path" was
  # trusted as proof MY change survived there, even when that worktree is demonstrably a DIFFERENT
  # session's own, unrelated work. Reproduced live (scratchpad/s20b_repro.sh): an unrelated sibling
  # worktree with its own uncommitted edit to the same path masked a genuine wipe of THIS session's
  # file (reverted to baseline, no marker — the exact S1 signature) — case (d) returned 0 for a real
  # loss. Fix: before trusting a match in another worktree, check whether that worktree is
  # ATTRIBUTABLE to a different session, using the SAME two signals _survival_wt_dir itself uses to
  # attribute a worktree to a session — a `.claude-session-lock` file, or a branch ending in either
  # the FULL session UUID or its 8-char PREFIX (both forms _survival_wt_dir:1540 matches; a
  # hostile-review pass, 2026-08-19, found the first cut of this fix only matched the full-UUID form
  # and still false-"ok"'d on the short-prefix form, which is this codebase's own common
  # /v-provisioned-worktree naming convention — see v-e2e-lifecycle-test.sh et al.'s
  # "-b build/feature-${SID:0:8}" fixtures) — just evaluated for "belongs to someone else" instead
  # of "belongs to me". A worktree with NEITHER signal (S19's shape: genuinely unattributed, e.g.
  # hand-created) is NOT excluded here — excluding it would reintroduce the exact false-"lost" case
  # (d) exists to fix. This narrows, but does not fully close, the false-"ok" surface: an
  # unattributed sibling worktree (no lock, no session-id-shaped branch suffix) with its own
  # unrelated dirty edit to the same path remains an open gap — there is no signal in this repo's
  # data model to disambiguate that shape from S19's genuine-survival shape, so it is disclosed
  # rather than silently claimed fixed.
  while IFS= read -r _owtpath; do
    [ -n "$_owtpath" ] || continue
    [ "$_owtpath" = "$_repo" ] && continue
    [ "$_owtpath" = "$_wt" ] && continue
    [ -d "$_owtpath" ] || continue
    _d2_owner=""
    if [ -f "$_owtpath/.claude-session-lock" ]; then
      _d2_owner="$(awk '{print $1}' "$_owtpath/.claude-session-lock" 2>/dev/null)"
    fi
    if [ -z "$_d2_owner" ]; then
      _d2_branch="$(git -C "$_owtpath" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      # Full-UUID suffix form (mirrors _survival_wt_dir's `*"$_sid"` form).
      _d2_owner="$(printf '%s' "$_d2_branch" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' 2>/dev/null)"
      if [ -z "$_d2_owner" ]; then
        # Short 8-hex-prefix suffix form (mirrors _survival_wt_dir's `*"-${_sid:0:8}"` form). A
        # match equal to MY OWN 8-char prefix is ambiguous (could genuinely be mine, already
        # excluded above via $_wt, or an 8-hex coincidence) and must NOT be treated as "someone
        # else's" — only a DIFFERING short prefix counts as attributable-to-another-session.
        _d2_short="$(printf '%s' "$_d2_branch" | grep -oE -- '-[0-9a-f]{8}$' 2>/dev/null)"
        _d2_short="${_d2_short#-}"
        if [ -n "$_d2_short" ] && [ "$_d2_short" != "${_sid:0:8}" ]; then
          _d2_owner="$_d2_short"
        fi
      fi
    fi
    if [ -n "$_d2_owner" ] && [ "$_d2_owner" != "$_sid" ]; then
      continue   # demonstrably a different session's worktree — its dirty state proves nothing about mine
    fi
    [ -n "$(git -C "$_owtpath" status --porcelain -- "$_f" 2>/dev/null)" ] && return 0
    [ -n "$(git -C "$_owtpath" diff --name-only "$_base" -- "$_f" 2>/dev/null)" ] && return 0
  done < <(git -C "$_repo" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')
  return 1
}

_survival_verdict() {  # <sid> <repo>
  local _sid="$1" _repo="${2:-$PWD}" _writes _base _wt _src _f _lost="" _nlost=0 _ntot=0 _line
  type get_session_writes >/dev/null 2>&1 || { echo "skip:no-writes-helpers"; return; }
  command -v git >/dev/null 2>&1 || { echo "skip:no-git"; return; }
  git -C "$_repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "skip:not-a-repo"; return; }
  # get_session_writes resolves the log from CWD's git-common-dir; resolve it from $_repo so the verdict
  # is identical regardless of the caller's CWD (the writes-log lives in the SHARED main .git, so this
  # is correct for worktree sessions too).
  _writes=$( cd "$_repo" 2>/dev/null && get_session_writes "$_sid" 2>/dev/null || true )
  [ -n "$_writes" ] || { echo "skip:empty-writes-log"; return; }
  _base=$(_survival_baseline_sha "$_sid" "$_repo")
  { [ -n "$_base" ] && git -C "$_repo" cat-file -e "${_base}^{commit}" 2>/dev/null; } || { echo "[survival-gate] WARNING: skip:no-baseline — HEAD-baseline not found for session ${_sid:-unknown}; survival gate inactive this session" >&2; echo "skip:no-baseline"; return; }
  _survival_has_marker "$_sid" "$_repo" && { echo "skip:declared-incomplete"; return; }
  _src=$(printf '%s\n' "$_writes" \
    | grep -v '^\[subagent-dispatch\]$' \
    | grep -vE "$_SURVIVAL_EXCLUDE_RE" \
    | grep -E "$_SURVIVAL_CODE_EXT_RE|$_SURVIVAL_DEP_MANIFEST_RE" \
    | grep -vE "${CODE_EXT_EXEMPT:-__none__}" \
    | sort -u || true)
  [ -n "$_src" ] || { echo "ok"; return; }   # read-only / artifact-only session
  _wt=$(_survival_wt_dir "$_sid" "$_repo")
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    _ntot=$((_ntot+1))
    _survival_file_survives "$_f" "$_base" "$_repo" "$_wt" "$_sid" && continue
    _lost="${_lost}${_lost:+ }$_f"; _nlost=$((_nlost+1))
  done <<SURVIVAL_EOF
$_src
SURVIVAL_EOF
  if [ "$_ntot" -gt 0 ] && [ "$_nlost" -eq "$_ntot" ]; then
    echo "lost:${_nlost}:${_lost}"; return
  fi
  # FIX-7 (self-audit survivor, 2026-06-18): some-but-not-all source files missing is a PARTIAL wipe.
  # The all-or-nothing block above (_nlost == _ntot) is intentional FP-avoidance and stays UNCHANGED.
  # A partial loss was previously indistinguishable from 'ok'. Emit a NON-BLOCKING advisory — but to
  # STDERR ONLY, so the STDOUT verdict contract ("echoes exactly ONE of ok/skip:/lost: on stdout") is
  # preserved byte-for-byte (an earlier interpretation emitted a 4th 'partial-warn:' token on STDOUT,
  # which broke that contract and any consumer that switches on only ok/skip:/lost: — reverted here).
  # Opt-in via $V_SURVIVAL_PARTIAL_WARN, and only when MORE THAN HALF (but not all) are lost, so the
  # default path stays silent and the signal is high.
  if [ -n "${V_SURVIVAL_PARTIAL_WARN:-}" ] && [ "$_ntot" -gt 1 ] && [ "$_nlost" -gt 0 ] \
     && [ "$_nlost" -lt "$_ntot" ] && [ $(( _nlost * 2 )) -gt "$_ntot" ]; then
    echo "SURVIVAL ADVISORY (partial loss): ${_nlost}/${_ntot} wrote-source files no longer survive (lost: ${_lost}). Not blocking (the all-lost condition did not fire), but verify this was intended." >&2
  fi
  echo "ok"
}

# ── Exposed-inline-work gate (1B, forensic 2026-06-16: a cross-session near-miss) ────────────────
# The survival gate catches a WIPE (work gone). This catches the EXPOSURE that precedes it: a session
# that wrote SOURCE inline on shared main, left it UNCOMMITTED, while sibling /v sessions are active —
# the exact uncommitted-on-shared-main state a concurrent sibling's stash/merge-back clobbers.
# SKILL.md already FORBIDS inline-with-active-siblings, but that is a read-surface rule the orchestrator
# violated (one session reasoned "no file overlap" instead of running v-active-siblings.sh). This ENFORCES
# it at the completion gate (hook-level), single-sourced so the Stop hook + self-check agree.
#
# RECOVERABLE: committed work cannot be clobbered, and CLAUDE.md's V_DEPTH>=1 checkpoint exception
# already authorizes a scoped commit when a stop hook blocks on session-owned unstaged changes — so the
# orchestrator commits its OWN files (scoped, NEVER `git add -A`) and re-runs → passes. No worktree
# setup needed. FP-safe: skips on worktree sessions, no active siblings, or any uncertainty.
#
# Echoes: ok | skip:<reason> | exposed:<n>:<files>
_exposed_inline_verdict() {  # <sid> <repo>
  local _sid="$1" _repo="${2:-$PWD}" _asib _writes _src _f _dirty="" _n=0 _scr
  type get_session_writes >/dev/null 2>&1 || { echo "skip:no-writes-helpers"; return; }
  command -v git >/dev/null 2>&1 || { echo "skip:no-git"; return; }
  git -C "$_repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "skip:not-a-repo"; return; }
  # A worktree session's work lives on its branch (committed via checkpoints), never on main's tree.
  [ -n "$(_survival_wt_dir "$_sid" "$_repo")" ] && { echo "skip:worktree"; return; }
  # CDX-002 (parity with _survival_verdict): an honest incompletion declaration (HANDOFF /
  # MERGE_DEFERRED / TRIVIAL_PASS / PLANNING_PASS / BLOCKED) means the orchestrator INTENTIONALLY left
  # WIP — do not block it for being uncommitted. Same marker set both gates honor.
  _survival_has_marker "$_sid" "$_repo" && { echo "skip:declared-incomplete"; return; }
  # No active sibling ⇒ nothing can stash/clobber main mid-session ⇒ the user's normal review-first
  # "/commit when ready" flow is safe. Active-sibling truth comes ONLY from v-active-siblings.sh.
  # Robust concurrency signal (worktree siblings OR any other session's writes-log activity during my
  # lifetime — _exposed_concurrency). No concurrency ⇒ solo ⇒ the user's review-first flow is safe.
  _exposed_concurrency "$_sid" "$_repo" || { echo "skip:no-active-siblings"; return; }
  _writes=$( cd "$_repo" 2>/dev/null && get_session_writes "$_sid" 2>/dev/null || true )
  [ -n "$_writes" ] || { echo "skip:empty-writes-log"; return; }
  _src=$(printf '%s\n' "$_writes" \
    | grep -v '^\[subagent-dispatch\]$' \
    | grep -vE "$_SURVIVAL_EXCLUDE_RE" \
    | grep -E "$_SURVIVAL_CODE_EXT_RE|$_SURVIVAL_DEP_MANIFEST_RE" \
    | grep -vE "${CODE_EXT_EXEMPT:-__none__}" \
    | sort -u || true)
  [ -n "$_src" ] || { echo "ok"; return; }   # no source written (read-only / artifact-only)
  while IFS= read -r _f; do
    [ -n "$_f" ] || continue
    # Uncommitted = dirty in main's working tree (modified/untracked/staged-not-committed). Any such
    # session-source file is exposed to a sibling's stash. A committed file shows clean porcelain.
    [ -n "$(git -C "$_repo" status --porcelain -- "$_f" 2>/dev/null)" ] && { _dirty="${_dirty}${_dirty:+ }$_f"; _n=$((_n+1)); }
  done <<EXPOSED_EOF
$_src
EXPOSED_EOF
  [ "$_n" -gt 0 ] && { echo "exposed:${_n}:${_dirty}"; return; }
  echo "ok"
}

# _exposed_inline_commit_ready <sid> <search_dir> [<search_dir> ...]
# Predicts, using the SAME artifact-resolution algorithm enforce-pre-commit-gates.sh's own
# find_session_artifact() delegates to (gauntlet_find_artifact(), single-sourced in
# gauntlet-witness.sh), whether a `git commit` right now would be ACCEPTED by that gate — i.e. does
# PRE_FLIGHT_REPORT exist AND pass its content checks, and does AGENT_REVIEW exist (structurally
# valid) or is this session's diff light-tier-waived.
# ADVISORY ONLY: this cannot itself authorize or block a commit — it only changes what the
# EXPOSED-INLINE-WORK gate message (check-review-artifact.sh) tells the model to do next.
# enforce-pre-commit-gates.sh remains the sole authority and is untouched by this function existing.
#
# Content depth (hostile-review finding, 2026-08-19): existence alone overclaims — a PRE_FLIGHT_REPORT
# that exists but shows a FAILED gate, or an AGENT_REVIEW that exists but is a garbage/empty stub,
# is NOT "ready" (enforce-pre-commit-gates.sh rejects both, lines ~419-450/501-506). Mirrors that
# gate's own two PRE_FLIGHT checks (validate_artifact structural check + its exact FAILED_GATES/
# OVERALL_FAIL grep) and, for AGENT_REVIEW, validate_artifact only — deliberately NOT the deeper
# validate_review_semantics (hostile-focus/session-id checks need the staged-diff path list, which
# does not exist yet at advisory time since nothing is staged pre-commit; replicating it partially
# would risk drifting from the real gate rather than under-predicting safely). This mirrors
# v-remediate-stale.sh's own documented design choice for this exact artifact type: "no full-fidelity
# parser by design... non-fallback + non-empty = tentative ok". Disclosed, not silently narrowed.
#
# Deliberately does NOT call check-review-artifact.sh's _light_tier_is_active() even though that is
# the correct, already-memoized implementation of this exact check: that function is defined much
# LATER in check-review-artifact.sh (after the EXPOSED-INLINE-WORK gate block that is this
# function's only caller already runs), so `type _light_tier_is_active` is false at the call site
# and reusing it would silently always skip the light-tier waiver. This duplicates the SAFE
# capture-then-grep idiom instead (capture the classifier's full output to a variable FIRST, THEN
# grep the captured string) rather than piping the live classifier process straight into `grep -q`
# — that pattern kills the classifier with SIGPIPE the instant grep matches its first of six output
# lines, and under `set -o pipefail` (which check-review-artifact.sh runs under) the pipeline's exit
# status becomes the classifier's SIGPIPE death, not grep's match, silently forcing a real LIGHT=1
# to read as "not light" — a bug class this codebase has already shipped and fixed twice elsewhere
# (enforce-pre-commit-gates.sh's own documented comment on this; _light_tier_is_active's correct
# capture-first form).
#
# Echoes: ready | missing:PRE_FLIGHT_REPORT | missing:AGENT_REVIEW | missing:PRE_FLIGHT_REPORT+AGENT_REVIEW
_exposed_inline_commit_ready() {
  local _sid="$1"; shift
  local _pf="" _ar="" _lt=0 _lt_script="" _lt_out=""
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    echo "missing:PRE_FLIGHT_REPORT+AGENT_REVIEW"; return
  fi
  _pf=$(gauntlet_find_artifact "PRE_FLIGHT_REPORT" "$_sid" "$@" 2>/dev/null || true)
  if [ -n "$_pf" ]; then
    if type validate_artifact >/dev/null 2>&1 && ! validate_artifact "$_pf" "PRE_FLIGHT_REPORT" >/dev/null 2>&1; then
      _pf=""
    elif grep -qiE '\|[[:space:]]*(FAIL|FAILED)[[:space:]]*\||\[(FAIL|FAILED)\]|❌|✗|status:[[:space:]]*fail(ed)?([[:space:]]|$)' "$_pf" 2>/dev/null \
         || grep -qiE '^(Overall[[:space:]]+)?Status:[[:space:]]*(FAIL|FAILED)([[:space:]]|$)' "$_pf" 2>/dev/null; then
      _pf=""
    fi
  fi
  _ar=$(gauntlet_find_artifact "AGENT_REVIEW" "$_sid" "$@" 2>/dev/null || true)
  if [ -n "$_ar" ] && type validate_artifact >/dev/null 2>&1 && ! validate_artifact "$_ar" "AGENT_REVIEW" >/dev/null 2>&1; then
    _ar=""
  fi
  if [ -z "$_ar" ]; then
    _lt_script="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
    if [ -f "$_lt_script" ]; then
      _lt_out="$(CLAUDE_SESSION_ID="$_sid" REPO_ROOT="${REPO_ROOT:-$PWD}" bash "$_lt_script" 2>/dev/null || true)"
      printf '%s\n' "$_lt_out" | grep -q '^LIGHT=1' && _lt=1
    fi
  fi
  if [ -n "$_pf" ] && { [ -n "$_ar" ] || [ "$_lt" -eq 1 ]; }; then echo "ready"; return; fi
  if   [ -z "$_pf" ] && [ -z "$_ar" ]; then echo "missing:PRE_FLIGHT_REPORT+AGENT_REVIEW"
  elif [ -z "$_pf" ]; then echo "missing:PRE_FLIGHT_REPORT"
  else echo "missing:AGENT_REVIEW"
  fi
}

# _prep_independence_signals <session_id> [explicit_transcript_path]
# Populates TRANSCRIPT_READABLE + _TX_SIGNALS the SAME way the Stop hook does, so a producer-side
# caller (v-completion-selfcheck.sh) and the Stop hook resolve identical signals for the same
# session and _independence_verdict cannot diverge. Scans the session's TOP-LEVEL transcript
# ($CLAUDE_CONFIG_DIR/projects/*/<sid>.jsonl, plus the explicit path if given) AND the session's
# subagents/ tree (O1, forensic) — the same scope the Stop hook reads. A background Agent-tool
# dispatch records its subagent_type ONLY in the subagents/ tree (not the parent, no DISPATCH_PROVENANCE),
# so the subtree must be scanned directly; v-dispatch-subagent.sh dispatches additionally leave a
# DISPATCH_PROVENANCE record. FP-safe: no transcript -> READABLE=0 -> _independence_verdict returns
# 'unverifiable' (warn, never block).
_prep_independence_signals() {
  local _sid="$1" _explicit="${2:-}" _cfg _f
  _cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  _PREP_FILES=()
  [ -n "$_explicit" ] && [ -f "$_explicit" ] && _PREP_FILES+=("$_explicit")
  for _f in "$_cfg/projects"/*/"${_sid}.jsonl"; do
    [ -f "$_f" ] && _PREP_FILES+=("$_f")
  done
  if [ "${#_PREP_FILES[@]}" -gt 0 ]; then
    TRANSCRIPT_READABLE=1
    _TX_SIGNALS=$(grep -hoE '"subagent_type":"[^"]*"|v-dispatch-subagent\.sh[^"]{0,80}--agent[ ="]+[A-Za-z0-9_-]+|"model":"[^"]*"' "${_PREP_FILES[@]}" 2>/dev/null || true)
    # O1 (forensic): also harvest INDEPENDENCE signals from the session's subagents/ tree. A
    # BACKGROUND Agent-tool reviewer dispatch records its subagent_type ONLY there (not the parent
    # transcript, and with NO DISPATCH_PROVENANCE), so a parent-only scan was blind to 9 genuinely-
    # independent reviewers and forced false 'degraded-inline' + hand-authored artifacts. The subagents/
    # tree is written by Claude Code for THIS session (path-scoped by SID) → a real, not-self-forgeable
    # signal. Harvest ONLY subagent_type/--agent here (NOT "model": — a subagent's model must not
    # misattribute the orchestrator's cost-lane in the non-blocking MODEL POLICY warning). Parity:
    # check-review-artifact.sh builds _TX_SIGNALS identically.
    local _sub
    for _sub in "$_cfg/projects"/*/"${_sid}"/subagents/*.jsonl; do
      [ -f "$_sub" ] && _TX_SIGNALS="$_TX_SIGNALS
$(grep -hoE '"subagent_type":"[^"]*"|v-dispatch-subagent\.sh[^"]{0,80}--agent[ ="]+[A-Za-z0-9_-]+' "$_sub" 2>/dev/null || true)"
    done
  else
    TRANSCRIPT_READABLE=0
    _TX_SIGNALS=""
  fi
}

# _w59_witnessed_independent_reviews <sid> <search_dir> [<search_dir> ...]
# -> prints the count of INDEPENDENT specialist-reviewer dispatches in DISPATCH_PROVENANCE_<sid>.log
#    that are HASH-VERIFIED: status=ok AND the row's recorded sha256 matches the on-disk artifact.
#
# W59-F2-DEGRADE (forensic 2026-07-04): when the hostile adversarial slot ran inline
# (codex quota-walled) the W59-F2 gate had NO satisfiable remediation and looped into a rearm
# ESCAPE that masked the violation. If ≥2 genuinely-independent subprocess reviewers actually ran,
# independent coverage existed and the gate can DEGRADE to a REVIEW_DEBT marker instead of masking.
# The count is HASH-GATED so a printf-forged provenance row (empty/wrong sha256, or an artifact that
# no longer matches) never counts — the row must correspond to a real artifact on disk byte-for-byte.
# Single-sourced here so the Stop hook and its bite test compute it identically (the _w59_f2_signature
# convention). Read-only; never errors the caller.
_w59_witnessed_independent_reviews() {
  local _sid="${1:-}"; shift || true
  [ -n "$_sid" ] || { printf '0\n'; return 0; }
  command -v shasum >/dev/null 2>&1 || { printf '0\n'; return 0; }
  local _prov="" _d
  for _d in "$@"; do
    [ -n "$_d" ] && [ -f "$_d/DISPATCH_PROVENANCE_${_sid}.log" ] && { _prov="$_d/DISPATCH_PROVENANCE_${_sid}.log"; break; }
  done
  [ -n "$_prov" ] || { printf '0\n'; return 0; }
  # Field layout (10 pipe-delimited): DISPATCH|ts|agent|mode|status|submodel|cost_usd|duration_ms|artifact|sha256
  local _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10 _ag _st _art _sha _artf _dsha _n=0
  # Dedup by artifact so two rows for the same reviewer artifact count once.
  local _seen=" "
  while IFS='|' read -r _f1 _f2 _f3 _f4 _f5 _f6 _f7 _f8 _f9 _f10; do
    _ag="${_f3#agent=}"; _st="${_f5#status=}"; _art="${_f9#artifact=}"; _sha="${_f10#sha256=}"
    case "$_ag" in
      security-reviewer|logic-reviewer|codebase-fit-reviewer|codex-adversarial-reviewer|framework-pitfall-reviewer|adversarial-panel-reviewer) : ;;
      *) continue ;;
    esac
    [ "$_st" = "ok" ] && [ -n "$_sha" ] && [ -n "$_art" ] || continue
    case "$_seen" in *" $_art "*) continue ;; esac
    _artf=""
    for _d in "$@"; do [ -n "$_d" ] && [ -f "$_d/$_art" ] && { _artf="$_d/$_art"; break; }; done
    [ -n "$_artf" ] || continue
    _dsha="$(shasum -a 256 "$_artf" 2>/dev/null | awk '{print $1}')"
    [ -n "$_dsha" ] && [ "$_dsha" = "$_sha" ] || continue
    _seen="$_seen$_art "
    _n=$((_n+1))
  done < <(grep '^DISPATCH|' "$_prov" 2>/dev/null || true)
  printf '%s\n' "$_n"
}

# verify_done_no_isolation <path> -> 0 (true) iff the VERIFY_DONE_REPORT ran with a no-isolation
# scope (Mode line contains "no-isolation"). Such a report could NOT isolate the changed set to the
# session's own worktree, so even a PASS does not verify THIS session's diff — v-merge-back.sh's
# W-GATE hard-blocks the merge on it (the load-bearing gate). This shared predicate lets the
# artifact BOARD surface the same condition at COMPLETION (advisory) so the model re-runs verify-done
# in isolation in one pass instead of discovering it only at the merge step (forensic 2026-07-04,
# F-3: "port the W-GATE no-isolation precedent up a layer"). SINGLE-SOURCE with merge-back's inline
# check — kept in parity by v-verify-done-noiso-parity-test.sh. Read-only; never errors the caller.
verify_done_no_isolation() {
  local f="$1"
  [ -f "$f" ] || return 1
  grep -iqE '^Mode:.*no-isolation' "$f"
}
