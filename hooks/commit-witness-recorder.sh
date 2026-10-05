#!/usr/bin/env bash
# commit-witness-recorder.sh — ORCHFIX-B2 (forensics 2026-07-02): write the per-SID commit witness
# on EVERY landing path, not only merge-back.
#
# WHY: `commits-<sid>.txt` was written ONLY by v-merge-back.sh (:1115). Any landing that bypasses
# merge-back — a rescue file-copy + direct commit on main, an inline-on-main session
# — leaves NO witness, so the session-log generator falls back to range heuristics and
# corrupts attribution in BOTH directions on the same night: the rescue session's log claimed a SIBLING's
# commit (worktree_branch range walked onto main history, confidence:high), the inline session's
# claimed ZERO commits while its own commit sat at end_sha. The witness is the ground-truth fix: gather's
# sid_commit_witness path is preferred over every heuristic.
#
# MECHANISM: PostToolUse on Bash. For a successful `git commit` command, parse the short sha git
# prints ("[branch abc1234] subject"), resolve it to a full sha in the repo the command targeted,
# and append it (deduped) to <main-root>/.v/artifacts/commits-<sid>.txt. Main-root resolution uses
# the SHARED hooks/lib/git-main-root.sh identity helper (same as durable-artifact-copy.sh) so
# worktree commits land in the main root's durable store. Requiring the sha to come from THIS
# call's stdout (never blind `rev-parse HEAD`) keeps the witness attribution-safe under parallel
# sessions — we only record a commit this session's own tool call reported creating.
#
# REGISTER (PostToolUse, matcher "Bash" — DUAL registration in settings.json AND
# settings.headless.json). Fail-open everywhere: PostToolUse must never block or error; every
# non-commit Bash call exits within one grep.
#
# Bite: hooks/commit-witness-recorder-test.sh.
set -uo pipefail
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat 2>/dev/null || true)"
[ -n "$INPUT" ] || exit 0

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL" = "Bash" ] || exit 0

CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
case "$CMD" in *git*commit*) ;; *) exit 0 ;; esac
printf '%s' "$CMD" | grep -qE '\bgit\b[^;|&]*\bcommit\b' || exit 0
printf '%s' "$CMD" | grep -qE -- '--dry-run' && exit 0

IS_ERR="$(printf '%s' "$INPUT" | jq -r '.tool_response.is_error // .is_error // false' 2>/dev/null || true)"
[ "$IS_ERR" != "true" ] || exit 0

SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-}"
[ -n "$SID" ] || exit 0

# The short sha MUST come from this call's own stdout — "[<branch> <shortsha>] subject" — so a
# concurrent sibling's HEAD movement can never be recorded as ours.
OUT="$(printf '%s' "$INPUT" | jq -r '.tool_response.stdout // (.tool_response | tostring) // empty' 2>/dev/null || true)"
[ -n "$OUT" ] || exit 0
BRACKETS="$(printf '%s\n' "$OUT" | grep -oE '^\[[^]]+ [0-9a-f]{7,40}\]' || true)"
[ -n "$BRACKETS" ] || exit 0

# Repo dir: `git -C <path>` wins, else a leading `cd <path>`, else the call's cwd.
DIR="$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"?([^";|&[:space:]]+)"?.*/\1/p' | head -1)"
[ -n "$DIR" ] || DIR="$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+"?([^";|&[:space:]]+)"?.*/\1/p' | head -1)"
[ -n "$DIR" ] || DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
DIR="${DIR/#\~/$HOME}"
[ -n "$DIR" ] && [ -d "$DIR" ] || exit 0
git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 || exit 0

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/git-main-root.sh
source "$HOOKS_LIB_DIR/git-main-root.sh" 2>/dev/null || exit 0
MAIN_ROOT="$(resolve_main_root "$DIR" 2>/dev/null || true)"
[ -n "$MAIN_ROOT" ] && [ -d "$MAIN_ROOT" ] || exit 0

WITNESS="$MAIN_ROOT/.v/artifacts/commits-${SID}.txt"
mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null || exit 0

# REV-5 hardening (adversarial review 2026-07-03): a bracket line alone is forgeable — a compound
# command "git commit ...; echo '[main <old-sha>] fake'" isn't is_error (the echo succeeds) and the
# old rule recorded a PRE-EXISTING commit as session-authored, poisoning the witness the generator
# treats as ground truth. Two additional proofs per line: (a) the bracket's branch must be the
# repo's CURRENT branch (a sibling's commit lives on another branch/checkout), and (b) the commit
# must be FRESH (committer time within 15 min) — a replayed old sha fails freshness. A fresh
# same-branch HEAD-adjacent commit is by construction this checkout's own latest work.
NOW_EPOCH="$(date +%s)"
CUR_BRANCH="$(git -C "$DIR" branch --show-current 2>/dev/null || true)"
_WROTE=0
while IFS= read -r _bl; do
  [ -n "$_bl" ] || continue
  _short="$(printf '%s' "$_bl" | grep -oE '[0-9a-f]{7,40}\]$' | tr -d ']')"
  _bbr="$(printf '%s' "$_bl" | sed -E 's/^\[//; s/ [0-9a-f]{7,40}\]$//')"
  [ -n "$_short" ] || continue
  case "$_bbr" in
    "$CUR_BRANCH"|"$CUR_BRANCH ("*|"detached HEAD"*) ;;   # "(root-commit)" suffix tolerated
    *) continue ;;
  esac
  FULL="$(git -C "$DIR" rev-parse --verify --quiet "${_short}^{commit}" 2>/dev/null || true)"
  [ -n "$FULL" ] || continue
  _ct="$(git -C "$DIR" show -s --format=%ct "$FULL" 2>/dev/null || echo 0)"
  [ "${_ct:-0}" -gt 0 ] && [ $(( NOW_EPOCH - _ct )) -le 900 ] || continue
  grep -qxF "$FULL" "$WITNESS" 2>/dev/null && continue
  printf '%s\n' "$FULL" >> "$WITNESS" 2>/dev/null && _WROTE=1
done <<< "$BRACKETS"

# F7a / F6(a) PROVENANCE SIDECAR (2026-07-05; HMAC-keyed same day per adversarial-review HIGH):
# validate-log.py's W22-P3-nowt check used to brand a hook-recorded witness for an INLINE
# (no-worktree) session as likely generator-fabricated, because it trusted the self-reported
# `classification.worktree.created` boolean plus the (outdated) premise that only v-merge-back.sh
# writes witnesses. This hook IS a legitimate witness writer for inline sessions (ORCHFIX-B2), so
# record verifiable provenance beside the witness. The sidecar is signed with
# hooks/lib/gauntlet-witness.sh's keyed HMAC (0600 per-install secret) over
# "commit-witness|<basename>|<sha256>|<ts>" — the first cut was a bare unkeyed sha256, which the
# review correctly rejected as forgeable by the identical one-liner a legitimate writer uses
# (zero incremental defense vs the generator-fabrication threat it targets). The validator
# ACCEPTS a non-worktree witness whose sidecar sha256 AND HMAC both verify (definitively
# hook-recorded); a sha/HMAC mismatch or an UNKEYED sidecar is hard tamper/forgery evidence.
# If the crypto lib/secret/openssl is unavailable, write NO sidecar at all (the validator then
# takes its legacy provenance-unknown NOTE path) — never an unsigned one. Refreshed on every
# real recorded append so it always covers the full current witness content; a REJECTED bracket
# never refreshes it (tamper evidence preserved). Same-UID ceiling acknowledged (see the
# HONEST SECURITY NOTE in gauntlet-witness.sh) — this converts a one-line forgery into a
# deliberate read-the-secret-and-replicate-the-HMAC fabrication.
# Bite: hooks/commit-witness-recorder-test.sh (T8-T10) + f6-f7-hardening-test.sh Group A.
if [ "$_WROTE" -eq 1 ] && [ -s "$WITNESS" ]; then
  _GWL="${GW_LIB:-$HOOKS_LIB_DIR/gauntlet-witness.sh}"
  if [ -f "$_GWL" ]; then
    # shellcheck source=lib/gauntlet-witness.sh
    . "$_GWL" 2>/dev/null || true
  fi
  if type gw_hmac_sign_file >/dev/null 2>&1 && type _gw_sha256 >/dev/null 2>&1; then
    _W_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
    _WHASH="$(_gw_sha256 "$WITNESS" 2>/dev/null || true)"
    _WHMAC="$(gw_hmac_sign_file "commit-witness" "$WITNESS" "$_W_TS" 2>/dev/null || true)"
    if [ -n "$_WHASH" ] && [ -n "$_WHMAC" ]; then
      printf 'recorder=commit-witness-recorder sha256=%s ts=%s hmac=%s\n' \
        "$_WHASH" "$_W_TS" "$_WHMAC" > "${WITNESS}.provenance" 2>/dev/null || true
    fi
  fi
fi

exit 0
