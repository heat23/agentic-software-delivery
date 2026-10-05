#!/usr/bin/env bash
# gauntlet-witness.sh — shared HMAC + content-hash helpers for the Bug 6 gauntlet
# attestation witness. Sourced by BOTH the writer (skills/v/references/
# v-gauntlet-attest.sh) and the verifier (hooks/check-review-artifact.sh) so the
# two cannot drift — a single source of truth for the witness crypto.
#
# Added 2026-05-28 (bypass/WG-1, shell/WG-1, tests/WG-1): the previous witness was
# trivially forgeable — the only nonce test was length>=16, and there was no
# element a model could not reproduce in one `Write` call, so a hand-authored
# witness passed the Stop hook with NO gauntlet run. This lib binds the witness to
# (a) an HMAC keyed on a 0600 per-install secret + the UID, and (b) the sha256 of
# each gauntlet artifact's CONTENT at attest time.
#
# HONEST SECURITY NOTE — read before "hardening" further:
#   This raises the forgery bar from "write a JSON file with a dummy nonce"
#   (trivial for any model) to "locate + read a 0600 secret this same UID owns,
#   replicate the exact HMAC construction, AND bind the precise artifact content
#   hashes." It is NOT a cryptographic wall against a SAME-UID model determined to
#   forge — no file-based scheme can be, because the model shares the UID that owns
#   every input (key file, artifacts, witness). What it DOES do is convert a
#   one-line rationalized shortcut ("I'll just write the witness, the work is fine")
#   into a deliberate, multi-step act of fabrication. That matches the real threat
#   (a model SKIPPING the gauntlet under deadline pressure), not a malicious actor.
#   The durable enforcement is that the Stop hook FIRES at all (settings.json
#   registration) + the no-deception silent-skip holes being closed; the witness is
#   defense-in-depth on top of those.

# Location of the per-install HMAC secret (overridable for tests).
_gw_secret_file() { echo "${GAUNTLET_HMAC_KEY_FILE:-$HOME/.claude/runtime/.gauntlet-hmac-key}"; }

# Per-install secret; created once at 0600 if absent. Echoes the secret, empty on
# failure. 64 hex chars of CSPRNG entropy.
_gw_secret() {
  local f; f=$(_gw_secret_file)
  if [ ! -s "$f" ]; then
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    local s=""
    s=$(head -c 32 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    [ -z "$s" ] && s=$(openssl rand -hex 32 2>/dev/null)
    [ -z "$s" ] && return 1
    ( umask 077; printf '%s' "$s" > "$f" 2>/dev/null ) || return 1
    chmod 600 "$f" 2>/dev/null || true
  fi
  cat "$f" 2>/dev/null
}

# HMAC key = "<uid>:<per-install-secret>". Deliberately does NOT use $HOSTNAME:
# it is empty under `env -i` (Stop hooks run with a scrubbed env), which would make
# the writer's key differ from the verifier's. `id -u` is a command (always
# resolvable) and the secret file carries the real entropy.
_gw_hmac_key() {
  local secret; secret=$(_gw_secret) || return 1
  [ -n "$secret" ] || return 1
  printf '%s' "$(id -u 2>/dev/null):${secret}"
}

# sha256 of a file's content. Empty (rc 1) if the file is missing/unhashable.
# Reads the file on stdin: given a filename containing a backslash or newline, shasum and sha256sum
# prefix their output line with `\`, which `awk '{print $1}'` would return as part of the hash.
_gw_sha256() {
  [ -f "$1" ] || return 1
  _gw_sha256_stdin < "$1"
}

_gw_hex_is_sha256() { case "$1" in *[!0-9a-f]*|'') return 1 ;; esac; [ ${#1} -eq 64 ]; }

# _gw_hmac_sha256 <key> <data> — HMAC-SHA256 (RFC 2104), lowercase hex. Empty (rc 1)
# on failure. Built from bash builtins plus the plain sha256 tool so the key never
# appears in any process's arguments: `openssl dgst -hmac "$key"` puts it on a command
# line that any local user can read with `ps`. The key is only ever expanded inside
# builtins (printf, arithmetic); od and the hash tool receive it, or bytes derived from
# it, on stdin. Output is byte-identical to openssl's (gauntlet-witness-test.sh).
_gw_hmac_sha256() {
  local LC_ALL=C key="$1" data="$2" khex ipad="" opad="" inner inner_esc="" i b e
  if [ ${#key} -gt 64 ]; then
    khex=$(printf '%s' "$key" | _gw_sha256_stdin) || return 1
    _gw_hex_is_sha256 "$khex" || return 1
  else
    khex=$(printf '%s' "$key" | od -An -v -tx1 | tr -d ' \n') || return 1
  fi
  while [ ${#khex} -lt 128 ]; do khex="${khex}00"; done
  i=0
  while [ $i -lt 128 ]; do
    b=${khex:$i:2}
    printf -v e '\\x%02x' $(( 16#$b ^ 0x36 )); ipad="$ipad$e"
    printf -v e '\\x%02x' $(( 16#$b ^ 0x5c )); opad="$opad$e"
    i=$((i + 2))
  done
  inner=$({ printf "$ipad"; printf '%s' "$data"; } | _gw_sha256_stdin) || return 1
  _gw_hex_is_sha256 "$inner" || return 1
  i=0
  while [ $i -lt 64 ]; do printf -v e '\\x%s' "${inner:$i:2}"; inner_esc="$inner_esc$e"; i=$((i + 2)); done
  { printf "$opad"; printf "$inner_esc"; } | _gw_sha256_stdin
}

# HMAC-SHA256 of <data-string> under the per-install key. Empty (rc 1) on failure
# (no hash tool / no secret). Callers MUST treat empty as fail-closed.
_gw_compute_hmac() {
  local data="$1" key
  [ -n "$data" ] || return 1   # a failed _gw_canonical yields "", which must not be signed
  key=$(_gw_hmac_key) || return 1
  [ -n "$key" ] || return 1
  _gw_hmac_sha256 "$key" "$data"
}

# Canonical signed string (witness format 3). Pins SID, nonce, ts, the three artifact
# content hashes, AND the source-tree binding: the whole-tree hash, the session-scoped
# tree hash and the repo root they were taken from. Format 2 left the tree fields
# unsigned, so deleting them from the witness silently disabled the post-attest edit
# check. The root is last because it is the only free-form field. Every earlier field
# must be colon-free, and this function enforces it (returns 1, prints nothing) rather
# than trusting the writer: the verifier rebuilds the string from witness fields an
# attacker can edit, and a colon moved into the session-tree field would otherwise let
# (.., S, "/a:b") and (.., "S:/a", "b") sign identically.
# Args: sid nonce ts pre_sha rev_sha ver_sha tree session_tree root
_gw_canonical() {
  case "$1$2$3$4$5$6$7$8" in *:*) return 1 ;; esac
  printf 'v3:%s:%s:%s:%s:%s:%s:%s:%s:%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# ── F7a (2026-07-05): GENERIC keyed file-sign helpers ─────────────────────────────
# The commit-witness provenance sidecar's first cut was a bare unkeyed sha256(witness) —
# forgeable by the same one-liner a legitimate writer uses, i.e. ZERO incremental defense
# against the generator-fabrication threat it targets (adversarial review HIGH). These
# helpers reuse THIS lib's keyed-HMAC + 0600 per-install secret machinery for arbitrary
# single-file witnesses. Canonical: "<label>|<basename(file)>|<sha256>|<ts>" — binds the
# signature to the witness IDENTITY (basename embeds the SID for commits-<sid>.txt), its
# exact CONTENT, and the signing time, so a sidecar cannot be re-bound to another SID's
# witness nor replayed over modified content. Same honest posture as the rest of this lib:
# bar-raising against the one-line rationalized forgery, not a wall against a determined
# same-UID actor (who owns the key file).
#
# gw_hmac_sign_file <label> <file> <ts> — echoes the HMAC; rc 1 (empty) on any failure
# (missing file / no hash tool / no openssl / no secret). Callers MUST treat empty as
# "do not write a sidecar at all" (degrade to the legacy no-sidecar path), never as
# "write an unsigned sidecar".
gw_hmac_sign_file() {
  local label="$1" f="$2" ts="$3" sha
  [ -n "$label" ] && [ -n "$ts" ] || return 1
  sha=$(_gw_sha256 "$f") || return 1
  [ -n "$sha" ] || return 1
  _gw_compute_hmac "${label}|$(basename "$f")|${sha}|${ts}"
}

# gw_hmac_verify_file <label> <file> <ts> <sha256> <hmac> — rc 0 iff the file's CURRENT
# content matches <sha256> AND the HMAC verifies under the per-install key. rc 1 on any
# mismatch or when crypto is unavailable (fail-closed for callers that require proof;
# callers wanting a graceful "cannot judge" path must test crypto availability first).
gw_hmac_verify_file() {
  local label="$1" f="$2" ts="$3" sha="$4" mac="$5" cur calc
  [ -n "$label" ] && [ -n "$ts" ] && [ -n "$sha" ] && [ -n "$mac" ] || return 1
  cur=$(_gw_sha256 "$f") || return 1
  [ "$cur" = "$sha" ] || return 1
  calc=$(_gw_compute_hmac "${label}|$(basename "$f")|${sha}|${ts}") || return 1
  [ -n "$calc" ] && [ "$calc" = "$mac" ]
}

# sha256 of STDIN (the whole-file _gw_sha256 above requires a real file path;
# this is used by _gw_scoped_tree_hash to hash a synthetic multi-line manifest).
# Same fallback chain as _gw_sha256. Empty (rc 1) on failure.
_gw_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  else
    return 1
  fi
}

# ── F5 hardening (2026-07-05): SESSION-SCOPED tree hash ───────────────────────────
# attest-tree-bind (see v-gauntlet-attest.sh's ATTEST-TREE-BIND and check-review-
# artifact.sh's mirroring compare) originally bound the whole TRACKED WORKING TREE
# (via `git stash create` / HEAD^{tree}). In a shared working tree — e.g. multiple
# /v sessions or worktrees whose changes land in the same checkout, or 40+ unrelated
# dirty files from other work — that whole-tree hash changes for reasons that have
# NOTHING to do with the files THIS session's gauntlet graded, producing a false
# GAUNTLET_STALE. This computes a hash scoped to ONLY the files this SID's own
# track-session-writes.sh ledger says it wrote (via the existing, already-filtered
# get_session_writes() helper in lib/session-writes.sh — it already drops gauntlet/
# artifact bookkeeping paths via the artifact-prefix registry), so unrelated tree
# churn cannot false-attribute staleness to a session that never touched those files.
#
# Args: <project_root> <session_id>
# Echoes a sha256 over a sorted "<relpath>=<blob-sha-or-MISSING>" manifest, or
# returns 1 (no output) if the session-writes ledger is unavailable/empty — callers
# MUST fall back to the whole-tree comparison in that case (this only NARROWS the
# check when we have positive evidence of what the session wrote; it never widens
# it and never fabricates a "no changes" verdict from missing data).
_gw_scoped_tree_hash() {
  local _root="$1" _sid="$2"
  [ -n "$_root" ] && [ -n "$_sid" ] || return 1
  if ! type get_session_writes >/dev/null 2>&1; then
    local _sw_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-writes.sh"
    [ -f "$_sw_lib" ] && . "$_sw_lib" 2>/dev/null
  fi
  type get_session_writes >/dev/null 2>&1 || return 1
  local _writes
  _writes="$(cd "$_root" 2>/dev/null && get_session_writes "$_sid" 2>/dev/null)" || true
  [ -n "$_writes" ] || return 1
  local _lines="" _wf _blob
  while IFS= read -r _wf; do
    [ -n "$_wf" ] || continue
    if [ -f "$_root/$_wf" ]; then
      _blob=$(git -C "$_root" hash-object "$_root/$_wf" 2>/dev/null || true)
      [ -n "$_blob" ] || _blob="UNHASHABLE"
    else
      _blob="MISSING"
    fi
    _lines="${_lines}${_wf}=${_blob}
"
  done <<_GW_WRITES_EOF
$_writes
_GW_WRITES_EOF
  [ -n "$_lines" ] || return 1
  printf '%s' "$_lines" | LC_ALL=C sort -u | _gw_sha256_stdin
}

# ── F1 (2026-07-05): shared artifact-resolution — single source of truth ──────────
# Added because THREE call sites independently reimplemented "find the artifact file
# for SID X across a set of candidate directories" with subtly different logic that had
# drifted out of sync:
#   1. check-review-artifact.sh's find_session_artifact — the MOST hardened of the
#      three: newest-mtime-wins across ALL search dirs (W-perf6/CODEX-003), PLUS
#      canonical-name-preferred-over-suffixed-variant (ORCHFIX-A1, e.g. a `-postmerge`
#      re-verify copy must never masquerade as the primary record).
#   2. enforce-pre-commit-gates.sh's find_session_artifact (the W5G-5/M-2 fix) — has
#      newest-mtime-wins across dirs, but NEVER got the ORCHFIX-A1 canonical/variant fix.
#   3. v-gauntlet-attest.sh's _resolve_artifact — the least hardened: FIRST-DIR-WINS in
#      priority order (NOT newest-mtime), with no canonical/variant distinction. A stale
#      `.v/artifacts` copy could therefore outrank a fresher repo-root fix here while the
#      Stop hook (newest-mtime-wins) picked the fresher one — exactly the kind of
#      cross-gate disagreement that produces a livelock.
# This function converges all three onto the MOST hardened behavior (check-review-
# artifact.sh's). Callers keep owning their OWN search-dir resolution (worktree lookup,
# MAIN_ROOT detection, etc. legitimately differ per caller) and just pass the resolved
# list of directories in; this function owns ONLY the "which file wins" algorithm.
#
# Usage: gauntlet_find_artifact <prefix> <session_id> <dir1> [<dir2> ...]
#   Echoes the winning absolute path and returns 0, or returns 1 with no output if no
#   file matches `<prefix>_<sid>*.md` in any given directory. Empty/nonexistent dirs are
#   silently skipped (callers may pass unresolved optional dirs as "").
#
# Algorithm:
#   1. Canonical name `<prefix>_<sid>.md` is preferred over suffixed variants whenever
#      ANY canonical file exists anywhere in the given dirs — newest-mtime-wins among
#      canonical candidates.
#   2. Only when NO canonical file exists in ANY dir do we fall back to variant globs
#      `<prefix>_<sid>*.md` (e.g. `-postmerge`, `-v2`), again newest-mtime-wins.
#   3. "Newest mtime wins" applies ACROSS all directories, never "first dir with any
#      match wins" — a dir's position in the argument list is a search-order hint only,
#      never a tiebreaker over an actual fresher file in a later dir.
gauntlet_find_artifact() {
  local prefix="$1" sid="$2"; shift 2 2>/dev/null || return 1
  [ -n "$prefix" ] && [ -n "$sid" ] || return 1
  local _dir _g _newest
  local _canon=() _cands=()
  for _dir in "$@"; do
    [ -n "$_dir" ] || continue
    [ -f "${_dir}/${prefix}_${sid}.md" ] && _canon+=("${_dir}/${prefix}_${sid}.md")
    for _g in "${_dir}/${prefix}_"*"${sid}"*.md; do
      [ -f "$_g" ] && _cands+=("$_g")
    done
  done
  if [ ${#_canon[@]} -gt 0 ]; then
    _newest=$(ls -t "${_canon[@]}" 2>/dev/null | head -1)
    [ -n "$_newest" ] && { echo "$_newest"; return 0; }
  fi
  [ ${#_cands[@]} -eq 0 ] && return 1
  _newest=$(ls -t "${_cands[@]}" 2>/dev/null | head -1)
  [ -n "$_newest" ] && { echo "$_newest"; return 0; }
  return 1
}
