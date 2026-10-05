#!/usr/bin/env bash
# session-artifact-inventory.sh — read-only inventory of session artifacts.
#
# Lists `*_${SID}.{md,json}` files under PROJECT_ROOT and categorizes them by
# artifact type (PLAN, BUILD_REPORT, PRE_FLIGHT_REPORT, etc.). For each file,
# extracts the final status line (Overall Status / Overall Verdict / Handoff
# Status / etc.) for quick summary by callers like /v-handoff, /v-session-log,
# /v-verify-done, /v-merge-all.
#
# Read-only. Never writes. Safe to run concurrently from any number of sessions.
#
# Usage:
#   session-artifact-inventory.sh [--sid=SID] [--project-root=PATH]
#
# Defaults:
#   --sid           $CLAUDE_SESSION_ID (must resolve to non-empty)
#   --project-root  $PROJECT_ROOT or cwd
#
# JSON schema:
#   {
#     "session_id": "...",
#     "project_root": "/abs/path",
#     "scanned_at": "ISO-8601 UTC",
#     "partial_skips": N,
#     "total_files": N,
#     "artifacts": {
#       "PLAN":                  [ {path, mtime_unix, size_bytes, status}, ... ],
#       "BUILD_REPORT":          [ ... ],
#       "PRE_FLIGHT_REPORT":     [ ... ],
#       "VERIFY_DONE_REPORT":    [ ... ],
#       "AGENT_REVIEW":          [ ... ],
#       "HANDOFF":               [ ... ],
#       "SESSION_LOG":           [ ... ],
#       "AUDIT_REPORT":          [ ... ],
#       "REFACTOR_PLAN":         [ ... ],
#       "POLISH_PLAN":           [ ... ],
#       "BUILD_BLOCKER":         [ ... ],
#       "IMPLEMENTATION_REPORT": [ ... ],
#       "GAUNTLET_REPORT":       [ ... ],
#       "MERGE_ALL_REPORT":      [ ... ],
#       "OTHER":                 [ ... ]  # session-suffixed files with unknown prefix
#     }
#   }
#
# `status` is extracted from the last non-empty line. Patterns recognized:
#   Overall Status: PASS|FAIL|...
#   Overall Verdict: PASS|FAIL|...
#   Handoff Status: READY|...
#   Status: completed|in_progress|...
# Falls back to the raw last line if no pattern matches, or null if file is empty.
#
# Symlinks are NOT followed. Filenames with tab/newline are skipped + counted.
#
# Exit codes:
#   0  success
#   2  --project-root does not exist
#   3  invalid arguments (incl. empty SID)
#   5  bash too old

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
  echo "session-artifact-inventory: requires bash >= 4.3 (found ${BASH_VERSION})" >&2
  exit 5
fi

set -uo pipefail

SID_ARG=""
SID_SET=0
PROJECT_ROOT_RAW=""
PROJECT_ROOT_SET=0

print_help() {
  cat <<'EOF'
session-artifact-inventory.sh — read-only JSON inventory of session artifacts.

Usage:
  session-artifact-inventory.sh [--sid=SID] [--project-root=PATH]

Defaults:
  --sid          $CLAUDE_SESSION_ID
  --project-root $PROJECT_ROOT or cwd

Exit codes: 0 success, 2 bad project root, 3 bad args, 5 bash too old.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --sid=*)          SID_ARG="${arg#*=}"; SID_SET=1 ;;
    --project-root=*) PROJECT_ROOT_RAW="${arg#*=}"; PROJECT_ROOT_SET=1 ;;
    --help|-h)        print_help; exit 0 ;;
    *)
      printf 'session-artifact-inventory: unknown argument: %s\n' "$arg" >&2
      exit 3
      ;;
  esac
done

# Resolve SID. If --sid not passed, fall back to env. Either way, must be non-empty.
SID="${SID_ARG:-${CLAUDE_SESSION_ID:-}}"
if (( SID_SET )) && [[ -z "$SID_ARG" ]]; then
  printf 'session-artifact-inventory: --sid= cannot be empty\n' >&2
  exit 3
fi
if [[ -z "$SID" ]]; then
  printf 'session-artifact-inventory: --sid or $CLAUDE_SESSION_ID is required\n' >&2
  exit 3
fi
# SAI-H1 fix: tighten SID validation. SID is interpolated unquoted into a
# `find -name` glob pattern, so glob metacharacters (* ? [ ] { }) would let a
# crafted --sid='*' match every artifact in PROJECT_ROOT and leak cross-session
# data. Allow only alphanumeric, dot, dash, underscore.
if ! [[ "$SID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'session-artifact-inventory: --sid must match [A-Za-z0-9._-]+ (got %q)\n' "$SID" >&2
  exit 3
fi

if (( PROJECT_ROOT_SET )) && [[ -z "$PROJECT_ROOT_RAW" ]]; then
  printf 'session-artifact-inventory: --project-root= cannot be empty\n' >&2
  exit 3
fi
PROJECT_ROOT="${PROJECT_ROOT_RAW:-$PWD}"
PROJECT_ROOT="${PROJECT_ROOT%/}"
[[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT="/"
if [[ ! -d "$PROJECT_ROOT" ]]; then
  printf 'session-artifact-inventory: project root does not exist: %s\n' "$PROJECT_ROOT" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  printf 'session-artifact-inventory: jq is required, not found in PATH\n' >&2
  exit 3
fi

abs_project_root() {
  if command -v realpath >/dev/null 2>&1; then
    realpath "$1" 2>/dev/null && return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null && return
  fi
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s' "$1"
}
PROJECT_ROOT="$(abs_project_root "$PROJECT_ROOT")"

# ── known artifact prefixes ─────────────────────────────────────────────────
# Each prefix matches `^${PREFIX}.*_${SID}\.(md|json)$`. The PLAN prefix is
# special: it's just "PLAN_" but also matches every other "*_PLAN_..." which we
# DON'T want, so we match the start of basename exactly.

# P3-REGISTRY (2026-07-03): extended with the prefixes the ecosystem actually writes (all present
# in hooks/lib/artifact-prefix-registry.sh); previously the inventory silently undercounted
# QA/IMPACT/UX/WF/TRIVIAL and every 2026-07 addition.
ARTIFACT_TYPES=(
  PLAN
  BUILD_REPORT
  IMPLEMENTATION_REPORT
  PRE_FLIGHT_REPORT
  VERIFY_DONE_REPORT
  AGENT_REVIEW_STAGED
  AGENT_REVIEW
  HANDOFF
  SESSION_LOG
  AUDIT_REPORT
  ADMIN_AUDIT_REPORT
  REFACTOR_PLAN
  POLISH_PLAN
  BUILD_BLOCKER
  GAUNTLET_REPORT
  MERGE_ALL_REPORT
  CONSOLIDATED_AUDIT_REPORT
  QA_REPORT
  QA_REMEDIATION
  IMPACT_MAP
  UX_CRITIQUE
  WORKFLOW_VERIFICATION
  TRIVIAL_PASS
  PLANNING_PASS
  BLOCKED
  SUCCESS_CRITERIA
  WORKFLOW_BLAST_RADIUS
  SID_COLLISION
  BITE_LEDGER
  BILLING_REVIEWED
)

# Returns the artifact type of a basename or empty string if none.
classify_basename() {
  local b="$1"
  local t
  # Order matters: more-specific prefixes first (e.g. ADMIN_AUDIT_REPORT before
  # AUDIT_REPORT, IMPLEMENTATION_REPORT before BUILD_REPORT).
  for t in IMPLEMENTATION_REPORT BUILD_REPORT PRE_FLIGHT_REPORT VERIFY_DONE_REPORT \
           AGENT_REVIEW_STAGED AGENT_REVIEW WORKTREE_HANDOFF CYCLE_CAP_HANDOFF HANDOFF SESSION_LOG ADMIN_AUDIT_REPORT \
           CONSOLIDATED_AUDIT_REPORT AUDIT_REPORT REFACTOR_PLAN POLISH_PLAN \
           BUILD_BLOCKER GAUNTLET_REPORT MERGE_ALL_REPORT QA_REMEDIATION QA_REPORT IMPACT_MAP \
           UX_CRITIQUE WORKFLOW_VERIFICATION WORKFLOW_BLAST_RADIUS TRIVIAL_PASS PLANNING_PASS \
           BLOCKED SUCCESS_CRITERIA SID_COLLISION BITE_LEDGER BILLING_REVIEWED PLAN; do
    if [[ "$b" == "$t"_* ]]; then
      printf '%s' "$t"
      return
    fi
  done
  printf 'OTHER'
}

# Returns the status line for an artifact, or empty string if none recognized.
#
# SAI-H2 fix: only return RECOGNIZED sentinels. The previous fallback of "echo
# the raw last line" could leak sensitive content (Bearer tokens, DB URLs,
# stack traces) into the JSON status field, which 4 caller skills surface
# directly into handoff documents and session logs.
#
# SAI-M2 fix: strip trailing \r so CRLF line endings don't pollute the value.
# SAI-M3 fix: strip non-printable bytes so jq --rawfile cannot abort on
# invalid UTF-8 inside a corrupted artifact.
extract_status() {
  local f="$1"
  local last
  last="$(tail -n 50 "$f" 2>/dev/null \
    | awk 'NF { sub(/\r$/, ""); last=$0 } END { print last }' \
    | LC_ALL=C tr -d -c '[:print:][:space:]')"
  [[ -z "$last" ]] && { printf ''; return; }
  if [[ "$last" =~ ^(Overall[[:space:]]+Status|Overall[[:space:]]+Verdict|Handoff[[:space:]]+Status|Status):[[:space:]]+(.+)$ ]]; then
    printf '%s' "$last"
    return
  fi
  # No recognized sentinel — return empty (becomes null in JSON) rather than
  # leaking arbitrary trailing content as a "status" field.
  printf ''
}

# Probe GNU first: GNU stat reads -f as a filesystem stat, while BSD stat rejects -c outright.
if stat -c '%Y' / >/dev/null 2>&1; then
  STAT_MODE=gnu
elif stat -f '%m' / >/dev/null 2>&1; then   # portability-ok: GNU probed first, so this is BSD
  STAT_MODE=bsd
else
  printf 'session-artifact-inventory: stat command not recognized\n' >&2
  exit 3
fi
get_mtime() {
  case "$STAT_MODE" in
    bsd) stat -f '%m' "$1" 2>/dev/null ;;   # portability-ok: flavour probed above
    gnu) stat -c '%Y' "$1" 2>/dev/null ;;
  esac
}
get_size() {
  case "$STAT_MODE" in
    bsd) stat -f '%z' "$1" 2>/dev/null ;;   # portability-ok: flavour probed above
    gnu) stat -c '%s' "$1" 2>/dev/null ;;
  esac
}

PARTIAL_SKIPS=0
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sai-XXXXXX")" || {
  printf 'session-artifact-inventory: failed to create temp dir\n' >&2
  exit 3
}
trap 'rm -rf "$TMP_DIR"' EXIT

# Build per-type NUL-delimited streams (mtime\0size\0path\0status\0... × 4)

declare -A TYPE_STREAM=()
for t in "${ARTIFACT_TYPES[@]}" OTHER; do
  TYPE_STREAM[$t]="$TMP_DIR/$t.stream"
  : > "${TYPE_STREAM[$t]}"
done

# Find all files that look like `*_${SID}.{md,json}` in PROJECT_ROOT (depth 1).
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  [[ -L "$f" ]] && continue
  base="$(basename "$f")"

  if [[ "$base" == *$'\t'* || "$base" == *$'\n'* ]]; then
    printf 'session-artifact-inventory: skipping filename with tab/newline: %q\n' "$base" >&2
    PARTIAL_SKIPS=$((PARTIAL_SKIPS + 1))
    continue
  fi

  artifact_type="$(classify_basename "$base")"
  stream_file="${TYPE_STREAM[$artifact_type]}"

  mtime="$(get_mtime "$f")"
  size="$(get_size "$f")"
  if [[ -z "$mtime" || -z "$size" ]]; then
    PARTIAL_SKIPS=$((PARTIAL_SKIPS + 1))
    continue
  fi
  status="$(extract_status "$f")"

  printf '%s\0%s\0%s\0%s\0' "$mtime" "$size" "$f" "$status" >> "$stream_file"
done < <(find "$PROJECT_ROOT" -maxdepth 1 \( -type f -a ! -type l \) \
  \( -name "*_${SID}.md" -o -name "*_${SID}.json" \) -print0 2>/dev/null)

# Single jq pass: parse all per-type streams + assemble final document.

JQ_PROGRAM_HEADER='
def parse_stream:
  if length == 0 then [] else
    # Drop trailing terminator only; preserve 4-tuple alignment so empty
    # status fields stay aligned with their record.
    split("\u0000")
    | .[:-1]
    | [range(0; length; 4) as $i | {
        mtime_unix: (.[$i] | tonumber),
        size_bytes: (.[$i+1] | tonumber),
        path: .[$i+2],
        status: (if .[$i+3] == "" then null else .[$i+3] end)
      }]
    | sort_by(-.mtime_unix)
  end;
'

sanitize_var() { printf '%s' "${1//-/_}"; }

artifacts_expr='{'
first=1
final_args=()
for t in "${ARTIFACT_TYPES[@]}" OTHER; do
  vname="type_$(sanitize_var "$t")"
  (( first )) || artifacts_expr+=','
  artifacts_expr+="\"$t\": (\$$vname | parse_stream)"
  first=0
  final_args+=(--rawfile "$vname" "${TYPE_STREAM[$t]}")
done
artifacts_expr+='}'

scanned_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg session_id "$SID" \
  --arg project_root "$PROJECT_ROOT" \
  --arg scanned_at "$scanned_at" \
  --argjson partial_skips "$PARTIAL_SKIPS" \
  "${final_args[@]}" \
  "$JQ_PROGRAM_HEADER
   $artifacts_expr as \$artifacts
   | {
       session_id: \$session_id,
       project_root: \$project_root,
       scanned_at: \$scanned_at,
       partial_skips: \$partial_skips,
       total_files: (\$artifacts | to_entries | map(.value | length) | add // 0),
       artifacts: \$artifacts
     }
  "
