#!/bin/bash
# dispatched-runner.sh — authenticated "am I a /v dispatched runner?" marker.
#
# W5G-8 (forensic 2026-07-10): an earlier version of this exemption was an unauthenticated
# environment flag (`V_DISPATCHED_SUBAGENT=1`). Because the tool loads persisted settings into its
# own environment at startup, a session could write that flag into its settings once and silently
# disable the check-review-artifact / uncommitted-changes Stop gates for every later session.
#
# The variable now carries an HMAC token bound to a coarse (hourly) time window, computed from the
# per-install gauntlet secret (see gauntlet-witness.sh). A statically persisted value fails
# verification within about two hours because the expected value rotates, and the legacy literal
# "1" is rejected outright. Same-UID forgery (a model reading the secret and recomputing the token
# every session) remains possible; that is the documented same-UID ceiling. Fail-closed: no HMAC
# helper, hash tool or secret means no token can be minted or accepted, so the gate runs (over-block,
# never under-block). An earlier fallback keyed the token on uid and hostname when the secret was
# missing, which any local user can compute; it was removed.
# The HMAC comes from gauntlet-witness.sh's _gw_hmac_sha256, which keeps the key off every command
# line (`openssl dgst -hmac` would expose it to any local user through `ps`).

# Load gauntlet-witness.sh into the CURRENT shell (not a $(...) subshell, where the functions it
# defines would vanish on return).
_dr_load_gw() {
  type _gw_secret >/dev/null 2>&1 && type _gw_hmac_sha256 >/dev/null 2>&1 && return 0
  local _gwlib
  _gwlib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/gauntlet-witness.sh"
  [ -f "$_gwlib" ] && . "$_gwlib" 2>/dev/null
  return 0
}

_dr_hmac_key() {
  local _secret=""
  _dr_load_gw
  type _gw_secret >/dev/null 2>&1 && _secret=$(_gw_secret 2>/dev/null || true)
  [ -n "$_secret" ] || return 1   # no secret, no key: never fall back to public values
  printf '%s' "$(id -u):${_secret}"
}

# _dispatched_runner_token [window-epoch-hours] — echo the HMAC token for a window (default: now)
_dispatched_runner_token() {
  local _win="${1:-}" _key
  _dr_load_gw
  type _gw_hmac_sha256 >/dev/null 2>&1 || return 1
  _key="$(_dr_hmac_key)" || return 1
  [ -n "$_key" ] || return 1
  [ -n "$_win" ] || _win="$(( $(date +%s 2>/dev/null || echo 0) / 3600 ))"
  _gw_hmac_sha256 "$_key" "v-dispatched-runner:${_win}"
}

# _is_dispatched_runner — 0(true) iff $V_DISPATCHED_SUBAGENT is a valid token for the current
# or immediately-prior hour window. Rejects empty and the legacy static "1"/"0"/bool values.
_is_dispatched_runner() {
  local _v="${V_DISPATCHED_SUBAGENT:-}"
  [ -n "$_v" ] || return 1
  case "$_v" in ''|0|1|true|false|yes|no) return 1 ;; esac   # never accept a static flag value
  local _now _cur _prev
  _now="$(( $(date +%s 2>/dev/null || echo 0) / 3600 ))"
  _cur="$(_dispatched_runner_token "$_now")"
  [ -n "$_cur" ] && [ "$_v" = "$_cur" ] && return 0
  _prev="$(_dispatched_runner_token "$(( _now - 1 ))")"
  [ -n "$_prev" ] && [ "$_v" = "$_prev" ] && return 0
  return 1
}
