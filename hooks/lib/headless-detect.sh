#!/usr/bin/env bash
# headless-detect.sh — shared helper for hooks to detect trusted headless sessions.
#
# Usage (call AFTER reading INPUT via cat):
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/headless-detect.sh"
#   _is_headless "$INPUT" && exit 0
#
# Security model (AVF-002):
# Headless bypass is allowed only when BOTH conditions are true:
#   1) A headless marker is present (CLAUDE_HEADLESS=1 OR attestation file)
#   2) A trusted-runner attestation exists at ~/.claude/attestations/<sid>.json
#      with a valid HMAC binding the session_id to the local machine identity.
#
# Attestation schema:
# {
#   "session_id":    "<session_id>",
#   "trusted_runner": true,
#   "timestamp":     <unix_seconds>,
#   "hmac":          "<sha256_hex>"
# }
#
# HMAC key: HOSTNAME + UID  — deterministic within a machine/user pair,
#           unpredictable to external attackers (who lack hostname + uid knowledge).
# HMAC input: "<session_id>:<timestamp>"
#
# Attestation directory: ~/.claude/attestations/ (chmod 700, files chmod 600)
# Old /tmp attestations are no longer created; if present they are ignored (HMAC
# field absent → verification fails → not trusted). No crash occurs.

_headless_attest_dir() {
  echo "${HOME}/.claude/attestations"
}

_headless_session_id() {
  local input="$1"
  local sid=""
  if command -v jq >/dev/null 2>&1; then
    sid=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi
  if [[ -z "$sid" ]]; then
    sid="${CLAUDE_SESSION_ID:-}"
  fi
  echo "$sid"
}

_headless_hmac_key() {
  # 2026-05-28 (review S3): mix the per-install secret (shared with the gauntlet
  # witness) so the key is NOT derivable from env alone and is STABLE regardless of
  # $HOSTNAME — which is empty under a scrubbed Stop-hook env, and previously made
  # the key differ between attestation-write and attestation-verify contexts. This
  # matters now that the IMPLEMENTATION_ONLY exemption in check-review-artifact.sh is
  # gated on this attestation. Falls back to the legacy HOSTNAME+UID key when the
  # secret lib is unavailable (preserves prior behavior; never weaker).
  local _secret=""
  if ! type _gw_secret >/dev/null 2>&1; then
    local _gwlib
    _gwlib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/gauntlet-witness.sh"
    [ -f "$_gwlib" ] && . "$_gwlib" 2>/dev/null
  fi
  type _gw_secret >/dev/null 2>&1 && _secret=$(_gw_secret 2>/dev/null || true)
  if [ -n "$_secret" ]; then
    printf '%s' "$(id -u):${_secret}"
  else
    printf '%s' "${HOSTNAME:-}$(id -u)"
  fi
}

_headless_compute_hmac() {
  local sid="$1"
  local ts="$2"
  printf '%s' "${sid}:${ts}" | openssl dgst -sha256 -hmac "$(_headless_hmac_key)" 2>/dev/null | awk '{print $NF}'
}

_headless_attestation_path() {
  local sid="$1"
  local attest_dir
  attest_dir=$(_headless_attest_dir)

  # Primary: new secure location
  local primary="${attest_dir}/${sid}.json"
  if [[ -f "$primary" ]]; then
    echo "$primary"
    return 0
  fi

  # Legacy /tmp paths — read-only for migration period; HMAC check will reject
  # them because old format lacks the "hmac" field (returns 1 from _headless_has_trusted_attestation).
  local legacy_primary="/tmp/claude-headless-attestation-${sid}.json"
  local legacy_alt="/tmp/claude-headless-${sid}.attestation.json"
  if [[ -f "$legacy_primary" ]]; then
    echo "$legacy_primary"
    return 0
  fi
  if [[ -f "$legacy_alt" ]]; then
    echo "$legacy_alt"
    return 0
  fi

  return 1
}

# _headless_create_attestation <session_id>
# Creates a fresh attestation file at ~/.claude/attestations/<sid>.json.
# Callable by trusted runners. Cleans up attestations older than 24 hours.
# Outputs the attestation file path on success.
_headless_create_attestation() {
  local sid="$1"
  [[ -n "$sid" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v openssl >/dev/null 2>&1 || return 1

  local attest_dir
  attest_dir=$(_headless_attest_dir)

  # Create directory with restrictive permissions (owner-only)
  mkdir -p "$attest_dir"
  chmod 700 "$attest_dir"

  # Prune old attestations (>24h = 1440 minutes) during creation
  find "$attest_dir" -name "*.json" -mmin +1440 -delete 2>/dev/null || true

  local ts
  ts=$(date +%s)
  local hmac
  hmac=$(_headless_compute_hmac "$sid" "$ts")

  local attest_file="${attest_dir}/${sid}.json"
  jq -n \
    --arg sid "$sid" \
    --argjson ts "$ts" \
    --arg hmac "$hmac" \
    '{session_id: $sid, trusted_runner: true, timestamp: $ts, hmac: $hmac}' \
    > "$attest_file"
  chmod 600 "$attest_file"

  echo "$attest_file"
}

_headless_marker_present() {
  local sid="$1"
  # Explicit env override (CI/CD environments)
  if [[ "${CLAUDE_HEADLESS:-0}" = "1" ]]; then
    return 0
  fi
  # New location: attestation file presence acts as marker
  if [[ -n "$sid" ]] && _headless_attestation_path "$sid" >/dev/null 2>&1; then
    return 0
  fi
  # Legacy /tmp marker (no longer created; recognised for migration compat)
  [[ -n "$sid" && -f "/tmp/claude-headless-${sid}" ]]
}

_headless_has_trusted_attestation() {
  local sid="$1"
  local attestation_file=""

  command -v jq >/dev/null 2>&1 || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  [[ -n "$sid" ]] || return 1

  attestation_file=$(_headless_attestation_path "$sid" 2>/dev/null || true)
  [[ -n "$attestation_file" ]] || return 1

  # Verify basic fields. Non-empty first: jq 1.6 exits 0 for `-e` on empty input.
  [[ -s "$attestation_file" ]] || return 1
  jq -e \
    --arg sid "$sid" \
    '(.session_id // "") == $sid and (.trusted_runner // false) == true' \
    "$attestation_file" >/dev/null 2>&1 || return 1

  # Verify HMAC — old-format attestations (missing "hmac") are rejected here
  local stored_hmac ts computed_hmac
  stored_hmac=$(jq -r '.hmac // empty' "$attestation_file" 2>/dev/null || true)
  ts=$(jq -r '.timestamp // empty' "$attestation_file" 2>/dev/null || true)

  # Both fields required; absent → reject (not trusted)
  [[ -n "$stored_hmac" ]] || return 1
  [[ -n "$ts" ]] || return 1

  computed_hmac=$(_headless_compute_hmac "$sid" "$ts")
  [[ "$stored_hmac" = "$computed_hmac" ]]
}

_is_headless() {
  local input="$1"
  local sid
  sid=$(_headless_session_id "$input")
  _headless_marker_present "$sid" || return 1
  _headless_has_trusted_attestation "$sid"
}
