#!/usr/bin/env bash
# v-stale-artifact-sweep-test.sh — W-perf10 FIX-8 regression net.
#
# Proves the load-bearing invariant: the stale-artifact sweep NEVER dirties main with another
# session's git-TRACKED state. It extracts and runs the LIVE bash block from
# v-stale-artifact-sweep.md (anti-drift — tests the real code, not a copy) inside a throwaway git
# repo, then asserts:
#   - a TRACKED prior-session artifact is left in place (still on disk, still tracked, tree clean)
#   - an UNTRACKED prior-session artifact is archived into .v/archive/<sid>/
#   - `git status --porcelain` is EMPTY after the sweep (housekeeping introduced no dirty state)
#
# Exit 0 = all pass; 1 = a failure.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SWEEP_MD="$HERE/v-stale-artifact-sweep.md"
PASS=0; FAIL=0
ok()  { echo "  ok  $1"; PASS=$((PASS+1)); }
bad() { echo "  BAD $1 — $2"; FAIL=$((FAIL+1)); }

[ -f "$SWEEP_MD" ] || { echo "FATAL: $SWEEP_MD not found"; exit 1; }

# Extract the single ```bash ... ``` implementation block from the .md (the live sweep code).
SWEEP_BLOCK="$(awk '/^```bash$/{f=1;next} /^```$/{if(f)exit} f' "$SWEEP_MD")"
[ -n "$SWEEP_BLOCK" ] || { echo "FATAL: could not extract bash block from $SWEEP_MD"; exit 1; }

WORK="$(mktemp -d 2>/dev/null)" || { echo "FATAL: mktemp failed"; exit 1; }
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1

git init -q . 2>/dev/null
git config user.email t@t.t; git config user.name t
git commit -q --allow-empty -m init 2>/dev/null

OTHER_TRACKED=11111111-1111-1111-1111-111111111111
OTHER_UNTRACKED=22222222-2222-2222-2222-222222222222
SELF=33333333-3333-3333-3333-333333333333

# A TRACKED prior-session artifact (a previous session committed it to main — the anomaly case).
echo "tracked blast radius" > "WORKFLOW_BLAST_RADIUS_${OTHER_TRACKED}.md"
git add "WORKFLOW_BLAST_RADIUS_${OTHER_TRACKED}.md"
git commit -q -m "prior session committed an artifact"

# An UNTRACKED prior-session artifact (the normal pollution the sweep is meant to clear).
echo "untracked blast radius" > "WORKFLOW_BLAST_RADIUS_${OTHER_UNTRACKED}.md"

# Make the env look like an active /v invocation for SELF, with a fresh invocation marker.
# bootstrap normally writes .v/.gitignore so the transient .v/ tree is ignored — mirror that.
export CLAUDE_SESSION_ID="$SELF"
mkdir -p ".v/tmp"
printf 'tmp/\narchive/\n' > ".v/.gitignore"
echo '.v/' > ".gitignore"
git add .gitignore; git commit -q -m "gitignore"
date -u +%s > ".v/tmp/v-invocation-start-${SELF}.txt"

# Run the LIVE sweep block.
PROJECT_ROOT="$WORK" SESSION_ID="$SELF" bash -c "$SWEEP_BLOCK" >/dev/null 2>&1

# --- Assertions ---
if [ -f "WORKFLOW_BLAST_RADIUS_${OTHER_TRACKED}.md" ]; then
  ok "tracked artifact left on disk (not archived)"
else
  bad "tracked artifact left on disk" "the sweep moved a git-tracked file — this dirties main"
fi

if git ls-files --error-unmatch -- "WORKFLOW_BLAST_RADIUS_${OTHER_TRACKED}.md" >/dev/null 2>&1; then
  ok "tracked artifact still tracked by git"
else
  bad "tracked artifact still tracked" "git no longer tracks it (it was moved away)"
fi

PORCELAIN="$(git status --porcelain 2>/dev/null)"
if [ -z "$PORCELAIN" ]; then
  ok "git tree clean after sweep (no tracked-file deletion introduced)"
else
  bad "git tree clean after sweep" "sweep dirtied main: $PORCELAIN"
fi

if [ ! -f "WORKFLOW_BLAST_RADIUS_${OTHER_UNTRACKED}.md" ] \
   && [ -f ".v/archive/${OTHER_UNTRACKED}/WORKFLOW_BLAST_RADIUS_${OTHER_UNTRACKED}.md" ]; then
  ok "untracked prior-session artifact archived to .v/archive/"
else
  bad "untracked artifact archived" "the untracked pollution was NOT archived (sweep regressed)"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
