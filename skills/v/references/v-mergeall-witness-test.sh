#!/usr/bin/env bash
# v-mergeall-witness-test.sh — FIX-A (forensic 2026-06-23). /v-merge-all's per-SID commit-witness write
# (skills/v-merge-all/SKILL.md, Step 3d-i) must:
#   (1) resolve the FULL SID from the worktree .claude-session-lock when the branch carries only the 8-char
#       short SID (the common '<type>/<slug>-<sid8>' naming). The old full-UUID-ONLY regex returned empty for
#       those branches -> the witness was SKIPPED -> every merge-all'd session fell to the COARSE
#       session_writes_log (over-attribution + shared-tip end_sha; a multi-session 06-23 fleet, all of them).
#   (2) write the DURABLE .v/artifacts copy (the .v/tmp copy is swept by a concurrent sibling's teardown).
# Behavioral: EXTRACTS + RUNS the actual SKILL.md witness snippet. GREEN on live SKILL.md, RED on the backup
# (.pre-witness2-bak) which lacks both. NEVER weaken an assertion — RED-oracle-absent is a hard fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SKILL="$HERE/../../v-merge-all/SKILL.md"
BAK="$HERE/../../v-merge-all/SKILL.md.pre-witness2-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

# Extract the witness stanza: from the `_MERGE_AFTER=$(git rev-parse HEAD)` line through the 2nd top-level (4-space) `fi`.
_extract(){ awk '/_MERGE_AFTER=\$\(git rev-parse HEAD\)/{p=1} p{print} p&&/^    fi$/{n++; if(n==2) exit}' "$1"; }

# Build a repo: base commit on main, branch off + 1 commit, merge --no-ff back. Returns "REPO|BRANCH|WT|MERGE_BEFORE".
setup(){ # $1=fullsid  $2=branch-name
  local sid="$1" br="$2" R WT MB before
  R=$(mktemp -d 2>/dev/null); git -C "$R" init -q 2>/dev/null
  git -C "$R" config user.email t@t.dev; git -C "$R" config user.name t
  printf 'base\n' > "$R/base.txt"; git -C "$R" add -A; git -C "$R" commit -qm base
  MB=$(git -C "$R" branch --show-current); before=$(git -C "$R" rev-parse HEAD)
  git -C "$R" checkout -qb "$br"
  printf 'work\n' > "$R/work.txt"; git -C "$R" add -A; git -C "$R" commit -qm "feat: work"
  git -C "$R" checkout -q "$MB"; git -C "$R" merge -q --no-ff -m "Merge branch '$br'" "$br"
  WT=$(mktemp -d 2>/dev/null); printf '%s worktree-lock\n' "$sid" > "$WT/.claude-session-lock"
  printf '%s|%s|%s|%s' "$R" "$br" "$WT" "$before"
}
run_block(){ # $1=SKILL.md  $2=repo  $3=branch  $4=wt  $5=merge_before
  ( cd "$2" && env BRANCH="$3" WORKTREE_PATH="$4" REPO_ROOT="$2" _MERGE_BEFORE="$5" bash -c "$(_extract "$1")" ) >/dev/null 2>&1
}
have(){ [ -s "$1/.v/artifacts/commits-$2.txt" ]; }       # durable witness present + non-empty
have_tmp(){ [ -s "$1/.v/tmp/commits-$2.txt" ]; }

# The pre-fix backup is not shipped in the public snapshot: its RED comparisons print a visible skip.
HAVE_BAK=1; [ -f "$BAK" ] || { HAVE_BAK=0; echo "  skip RED comparisons — pre-fix backup not shipped ($BAK)"; }

FULL=abcd1234-5e6f-7a8b-9c0d-112233445566; SID8=${FULL:0:8}

echo "== Scenario 1: SHORT-SID branch 'fix/slug-${SID8}' — full SID resolved from the worktree lock =="
IFS='|' read -r R BR WT MB <<<"$(setup "$FULL" "fix/some-slug-${SID8}")"
run_block "$SKILL" "$R" "$BR" "$WT" "$MB"
have "$R" "$FULL" && ok "live: durable witness commits-${FULL}.txt written (8-char branch -> full SID via lock)" || no "live: no durable witness for short-SID branch" "missing $R/.v/artifacts/commits-$FULL.txt"
rm -rf "$R" "$WT" 2>/dev/null || true
IFS='|' read -r R BR WT MB <<<"$(setup "$FULL" "fix/some-slug-${SID8}")"
if [ "$HAVE_BAK" = 1 ]; then
  run_block "$BAK" "$R" "$BR" "$WT" "$MB"
  ! have "$R" "$FULL" && ! have_tmp "$R" "$FULL" && ok "RED: backup writes NO witness for a short-SID branch (full-UUID-only regex -> _BRANCH_SID empty)" || no "RED: backup unexpectedly wrote a witness for short-SID" "found one — fix not isolating the gap"
fi
rm -rf "$R" "$WT" 2>/dev/null || true

echo "== Scenario 2: FULL-UUID branch — durable .v/artifacts copy (independent of SID resolution) =="
IFS='|' read -r R BR WT MB <<<"$(setup "$FULL" "fix/slug-${FULL}")"
run_block "$SKILL" "$R" "$BR" "$WT" "$MB"
have "$R" "$FULL" && ok "live: durable .v/artifacts witness written" || no "live: durable copy missing" "no .v/artifacts witness"
rm -rf "$R" "$WT" 2>/dev/null || true
IFS='|' read -r R BR WT MB <<<"$(setup "$FULL" "fix/slug-${FULL}")"
if [ "$HAVE_BAK" = 1 ]; then
  run_block "$BAK" "$R" "$BR" "$WT" "$MB"
  have_tmp "$R" "$FULL" && ! have "$R" "$FULL" && ok "RED: backup writes .v/tmp ONLY, no durable .v/artifacts copy (swept-under-concurrency gap)" || no "RED: backup durability behavior unexpected" "tmp=$(have_tmp "$R" "$FULL" && echo y || echo n) artifacts=$(have "$R" "$FULL" && echo y || echo n)"
fi
rm -rf "$R" "$WT" 2>/dev/null || true

echo "== Scenario 3 (review #1): slug contains an 8-hex run before the trailing SID — must resolve the TRAILING token =="
IFS='|' read -r R BR WT MB <<<"$(setup "$FULL" "build/oauth-deadbeef-${SID8}")"
run_block "$SKILL" "$R" "$BR" "$WT" "$MB"
have "$R" "$FULL" && ok "live: 'oauth-deadbeef-${SID8}' resolves the TRAILING SID -> witness under the correct full SID (not 'deadbeef')" || no "live: mis-picked the in-slug hex run, witness not under the true SID" "missing commits-$FULL.txt"
_dead=$(ls "$R/.v/artifacts/commits-deadbeef"*.txt "$R/.v/tmp/commits-deadbeef"*.txt 2>/dev/null | grep -c .)
[ "$_dead" -eq 0 ] && ok "live: NO witness written under the in-slug 'deadbeef' token" || no "wrote a witness under the wrong (in-slug) token" "$_dead deadbeef-named file(s)"
rm -rf "$R" "$WT" 2>/dev/null || true

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
