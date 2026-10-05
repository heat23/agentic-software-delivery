#!/usr/bin/env bash
# protect-main-branch.sh
# SAFETY HOOK — P0
# Version: 1.3.0  (AVF-018 fix: bare push detection + HMAC bypass; grep -qP -> -qE)
# Event: PreToolUse/Bash
# Blocks: direct push to protected branches, force push, broadcast flags
# Allows: git push to feature branches (non-main, non-master)
#         explicit solo push to main/master from the main working tree when no
#         linked worktrees are active

set -euo pipefail

# W83-F3 opt-in profiling — no-op unless CLAUDE_HOOK_PROFILE=1
if [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh" ]; then
  source "$(dirname "${BASH_SOURCE[0]}")/lib/profile.sh"
  profile_start "protect-main-branch"
fi



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: jq is required for protect-main-branch enforcement. Install jq and retry."}}'
  profile_done
  exit 0
fi


# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny
# W83-F5: lightweight git-path cache (per-SID, 60s TTL).
source "$HOOKS_LIB_DIR/git-path-cache.sh"

HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
SEGMENT_LIB="$HOOKS_LIB_DIR/command-segments.sh"
if [[ ! -f "$SEGMENT_LIB" ]]; then
  jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: command-segments helper is missing for protect-main-branch enforcement. Restore $HOOKS_LIB_DIR/command-segments.sh before running bash commands."}}'
  profile_done
  exit 0
fi

source "$SEGMENT_LIB"

# ── Helper: run git with cwd-poisoning location env vars neutralized ──────────
# resolve_git_paths (git-path-cache.sh) EXPORTS GIT_DIR / GIT_COMMON_DIR for the
# hook's OWN cwd. GIT_COMMON_DIR is frequently RELATIVE (e.g. "../.git" when the
# hook fires from a repo subdirectory such as .v-prompt-packs). Those exported
# vars then leak into the `git -C <repo_root>` queries below, so git resolves the
# common dir against the wrong base and `branch --show-current` returns empty.
# Effect before this fix: the sanctioned solo-main-push allow-path wrongly DENIED
# (empty branch => "not protected"), and bare-push detection wrongly UNDER-blocked
# (empty branch => treated as non-main). Neutralizing the inherited git-location
# env lets these queries auto-discover from their own -C / cwd. Enforcement is
# unaffected for non-git reasoning (force/broadcast/refspec checks are pure text).
# BSD (macOS) and GNU env both support -u.
_pmb_git() {
  env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE git "$@"
}

# ── Helper: detect bare/remote-only push that would target main via tracking ──
#
# Returns 0 (true) if the segment is "git push" with no explicit refspec
# AND the current branch is a protected branch (main/master) or tracks one.
#
# Catches patterns missed by explicit branch-name checks:
#   git push            -> uses current branch + tracking config
#   git push origin     -> uses current branch + tracking config for that remote
#
# Only called after explicit refspec checks confirm no literal protected target.
_pmb_would_bare_push_to_main() {
  local segment="$1"
  local non_flag_args=0
  local in_push=0
  local word

  # Walk the command words, counting non-flag arguments after "git push"
  for word in $segment; do
    [[ "$word" == "git" ]] && continue
    if [[ "$word" == "push" ]]; then
      in_push=1
      continue
    fi
    [[ "$in_push" -eq 0 ]] && continue
    # Skip flags (start with -)
    [[ "$word" == -* ]] && continue
    # A colon means it's a refspec (src:dst) -- handled by the refspec check
    [[ "$word" == *:* ]] && return 1
    (( non_flag_args++ ))
    # Two+ non-flag args = "git push remote branch" -- handled by explicit checks
    [[ "$non_flag_args" -ge 2 ]] && return 1
  done

  # Bare push (0 non-flag args) or push with only remote (1 non-flag arg):
  # verify the current branch is or tracks a protected branch.
  local current_branch
  current_branch=$(_pmb_git branch --show-current 2>/dev/null | head -c 128 | tr -d '\n\r' || echo "")
  [[ -z "$current_branch" ]] && return 1  # Detached HEAD -- no tracking branch

  # Direct match: current branch IS a protected branch name
  if [[ "$current_branch" =~ ^(main|master)$ ]]; then
    return 0
  fi

  # Tracking config: branch.<name>.merge points to a protected branch
  local tracking_ref
  tracking_ref=$(_pmb_git config "branch.${current_branch}.merge" 2>/dev/null || echo "")
  if [[ "$tracking_ref" =~ refs/heads/(main|master)$ ]]; then
    return 0
  fi

  return 1
}

# ── Helper: verify HMAC-signed bypass marker ──────────────────────────────────
#
# Marker file format (single line): SESSION_ID:TIMESTAMP:HMAC
#   SESSION_ID  opaque string created when the marker was written
#   TIMESTAMP   Unix epoch when the marker was created
#   HMAC        SHA-256 HMAC of "bypass:SESSION_ID:TIMESTAMP" keyed on
#               "${HOSTNAME}$(id -u)" (host+uid derived key)
#
# Security properties:
#   - 60-second validity window (reduced from 10 minutes in v1.0)
#   - Marker is deleted after successful verification (prevents replay)
#   - HMAC prevents forgery by processes that can write files but not compute
#     the correct signature without openssl and the correct key
#   - Fails safe: any parse error, expiry, or bad HMAC results in deny
#
# Known limitation: HMAC key derived from HOSTNAME+UID is guessable by any
# process running as the same user. This prevents external process forgery
# but not same-user forgery. A future improvement would store a random key
# in ~/.claude/.bypass-key (chmod 600) and include it in the HMAC material.
#
# To create a valid marker from a skill (v-merge-all or similar):
#   SESSION_ID="${CLAUDE_SESSION_ID:-$(uuidgen)}"
#   TIMESTAMP=$(date +%s)
#   HMAC_KEY="${HOSTNAME}$(id -u)"
#   HMAC=$(printf '%s' "bypass:${SESSION_ID}:${TIMESTAMP}" \
#     | openssl dgst -sha256 -hmac "$HMAC_KEY" | awk '{print $NF}')
#   printf '%s' "${SESSION_ID}:${TIMESTAMP}:${HMAC}" > "$MARKER_FILE"
_pmb_verify_bypass_hmac() {
  local marker_file="$1"

  local content
  content=$(cat "$marker_file" 2>/dev/null || echo "")
  [[ -z "$content" ]] && return 1

  # Validate three colon-separated fields present
  [[ ! "$content" =~ ^[^:]+:[^:]+:[^:]+$ ]] && return 1

  local session_id timestamp stored_hmac
  session_id=$(printf '%s' "$content" | cut -d: -f1)
  timestamp=$(printf '%s' "$content" | cut -d: -f2)
  stored_hmac=$(printf '%s' "$content" | cut -d: -f3-)

  [[ -z "$session_id" || -z "$timestamp" || -z "$stored_hmac" ]] && return 1
  [[ ! "$timestamp" =~ ^[0-9]+$ ]] && return 1

  local now age
  now=$(date +%s)
  age=$(( now - timestamp ))
  # Reject markers older than 60 seconds or with suspicious future timestamps
  if [[ "$age" -gt 60 || "$age" -lt 0 ]]; then
    return 1
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    return 1  # Fail safe: cannot verify without openssl
  fi

  local hmac_key="${HOSTNAME}$(id -u)"
  local expected_hmac
  expected_hmac=$(printf '%s' "bypass:${session_id}:${timestamp}" \
    | openssl dgst -sha256 -hmac "$hmac_key" 2>/dev/null \
    | awk '{print $NF}')

  [[ -z "$expected_hmac" ]] && return 1
  [[ "$expected_hmac" == "$stored_hmac" ]] && return 0
  return 1
}

_pmb_allow_explicit_solo_main_push() {
  local segment="$1"
  local repo_root current_branch worktree_count branch_pattern

  # W83-F5: prefer cached git paths (resolve_git_paths is idempotent per-SID).
  resolve_git_paths
  repo_root="$GIT_ROOT"
  [[ -n "$repo_root" ]] || return 1

  current_branch=$(_pmb_git -C "$repo_root" branch --show-current 2>/dev/null | head -c 128 | tr -d '\n\r' || echo "")
  [[ "$current_branch" =~ ^(main|master)$ ]] || return 1

  worktree_count=$(_pmb_git -C "$repo_root" worktree list 2>/dev/null | wc -l | tr -d ' ' || echo "1")
  [[ "${worktree_count:-1}" -le 1 ]] || return 1

  branch_pattern=$(printf '%s' "$current_branch" | sed 's/[][(){}.^$+*?|\\-]/\\&/g')

  if printf '%s\n' "$segment" | grep -qE "git[[:space:]]+push([[:space:]]+(-[a-zA-Z]+|--[a-zA-Z-]+))*([[:space:]]+[a-zA-Z0-9_.-]+)?[[:space:]]+${branch_pattern}([[:space:]]|$)"; then
    return 0
  fi

  if printf '%s\n' "$segment" | grep -qE "git[[:space:]]+push([[:space:]]+(-[a-zA-Z]+|--[a-zA-Z-]+))*[[:space:]]+[^[:space:]]+[[:space:]]+(HEAD|${branch_pattern}|refs/heads/${branch_pattern}):(refs/heads/)?${branch_pattern}([[:space:]]|$)"; then
    return 0
  fi

  return 1
}

# ── Helper: the actual command word of a segment (after leading env-assignments) ─
# 2026-05-28 (E3, revised after adversarial review): used to skip pure output/no-op
# builtins so a banner that MENTIONS a push in a string isn't treated as one. The
# earlier quote-stripping approach was reverted — it let `git push origin 'ma'in`
# evade branch detection and broke a quoted solo `git push origin "main"`.
_pmb_command_word() {
  printf '%s' "$1" \
    | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//' \
    | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────────────────────

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

if [[ -z "$COMMAND" ]]; then
  profile_done
  exit 0
fi

HAS_PUSH_SEGMENT=0
SEGMENT=""
while IFS= read -r SEGMENT; do
  [[ -z "$SEGMENT" ]] && continue

  # E3 false-positive fix: skip segments whose actual COMMAND is a pure output/no-op
  # builtin (echo/printf/:/true/false) — a banner that merely MENTIONS "git push …
  # main" in a string must not be treated as a push. All branch detection below runs
  # on the ORIGINAL $SEGMENT (the long-proven baseline), so real pushes — including
  # `bash -c "git push … main"` — are still caught.
  case "$(_pmb_command_word "$SEGMENT")" in
    echo|printf|:|true|false) continue ;;
  esac

  if ! printf '%s\n' "$SEGMENT" | grep -qE '\bgit[[:space:]]+push\b'; then
    continue
  fi

  HAS_PUSH_SEGMENT=1

  # ── Hard-deny patterns FIRST — no marker can override these ──────────────────
  if printf '%s\n' "$SEGMENT" | grep -qE '(^|[[:space:]])(--force|-f)\b'; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Force push is prohibited. Claude never rewrites remote history. If you need to force push, do so manually after reviewing implications."}}'
    profile_done
    exit 0
  fi

  # Block push with broadcast flag (pushes all branches including protected ones)
  BROADCAST_FLAG='--all'
  if printf '%s\n' "$SEGMENT" | grep -qE "(^|[[:space:]])${BROADCAST_FLAG}\b"; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: push with broadcast flag is prohibited — it would push all branches including protected ones. Push specific feature branches individually."}}'
    profile_done
    exit 0
  fi

  # Block push with mirror flag (mirrors entire repo including protected branches)
  MIRROR_FLAG='--mirror'
  if printf '%s\n' "$SEGMENT" | grep -qE "(^|[[:space:]])${MIRROR_FLAG}\b"; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: push with mirror flag is prohibited. This would overwrite remote refs including protected branches."}}'
    profile_done
    exit 0
  fi

  # ── HMAC marker bypass — allows v-merge-all to push to protected branches ────
  # Checked AFTER hard-deny patterns (force/broadcast/mirror can never be bypassed)
  # but BEFORE protected-branch checks. Marker is consumed on use (single-use).
  # W83-F5: use cached GIT_ROOT (resolve_git_paths is idempotent).
  resolve_git_paths
  _PMB_REPO_ROOT="${GIT_ROOT:-.}"
  _PMB_MARKER_FILE="$_PMB_REPO_ROOT/.worktrees/.merge-all-push-authorized"
  if [[ -f "$_PMB_MARKER_FILE" ]]; then
    if _pmb_verify_bypass_hmac "$_PMB_MARKER_FILE"; then
      rm -f "$_PMB_MARKER_FILE"  # Consume marker — prevents replay
      continue  # Skip protected-branch checks for this segment
    else
      rm -f "$_PMB_MARKER_FILE"  # Remove invalid/expired marker
    fi
  fi

  # Block push where the final non-flag argument is a protected branch name.
  # Uses POSIX ERE (grep -E) for portability across macOS (BSD grep) and Linux.
  # Pattern: optional flags, optional remote, then branch = main|master at end.
  if printf '%s\n' "$SEGMENT" | grep -qE 'git[[:space:]]+push([[:space:]]+(-[a-zA-Z]+|--[a-zA-Z-]+))*([[:space:]]+[a-zA-Z0-9_.-]+)?[[:space:]]+(main|master)([[:space:]]|$)'; then
    if _pmb_allow_explicit_solo_main_push "$SEGMENT"; then
      continue
    fi
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Direct push to protected branch is prohibited. Use a feature branch and merge back via the worktree lifecycle in _v-exec.md."}}'
    profile_done
    exit 0
  fi

  # Block refspec pushes targeting a protected branch (src:dst where dst is main/master)
  if printf '%s\n' "$SEGMENT" | grep -qE 'git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+:(refs/heads/)?(main|master)([[:space:]]|$)'; then
    if _pmb_allow_explicit_solo_main_push "$SEGMENT"; then
      continue
    fi
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: Refspec push to a protected branch is prohibited. Use a feature branch and merge back via the worktree lifecycle in _v-exec.md."}}'
    profile_done
    exit 0
  fi

  # Block bare push when the current branch is or tracks a protected branch (AVF-018).
  # Catches: `git push` and `git push origin` when checked-out branch is protected.
  if _pmb_would_bare_push_to_main "$SEGMENT"; then
    jq -n '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BLOCKED: bare push would target a protected branch (current branch is or tracks main/master). Checkout a feature branch before pushing."}}'
    profile_done
    exit 0
  fi
done < <(split_shell_command_segments "$COMMAND")

# Non-push command; allow
if [[ "$HAS_PUSH_SEGMENT" -eq 0 ]]; then
  profile_done
  exit 0
fi

profile_done
exit 0
