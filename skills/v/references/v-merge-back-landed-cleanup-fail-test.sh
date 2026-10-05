#!/usr/bin/env bash
# v-merge-back-landed-cleanup-fail-test.sh — BITE for FIND-2 (forensic 2026-07-02):
#   a `git worktree remove` failure DURING post-merge cleanup (observed rc=128 "not a working tree" when a
#   concurrent sibling teardown deregistered the worktree between the ff-merge and cleanup) must NOT invert
#   the merge's success. Pre-fix: `set -euo pipefail` aborted the whole script at the worktree-remove line
#   AFTER the ff-merge had already landed → merge-back exited 128 → the drain reported a LANDED feature as
#   failed=1 / NEEDS-MANUAL.
#
# Reproduction is deterministic and faithful: a `git` shim first on PATH passes EVERY git call through to the
# real git EXCEPT `git worktree remove ...`, which it fails with the exact incident message + rc 128. So the
# rebase+ff-merge land for real (branch becomes an ancestor of main), then cleanup hits the injected fault —
# exactly the incident's post-merge state, without needing to race a real concurrent teardown.
#
# RED oracle: point MB_OVERRIDE at the pre-fix copy (scratch/oracles/v-merge-back.sh.PRE) → merge-back rc=128.
# GREEN: the in-tree fixed v-merge-back.sh → rc=0 AND the change is on main (merge preserved).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MB="${MB_OVERRIDE:-$HERE/v-merge-back.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$MB" ] || { echo "FATAL: merge-back not found at $MB"; exit 2; }
REAL_GIT="$(command -v git)"
export GIT_CONFIG_NOSYSTEM=1

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE" 2>/dev/null' EXIT

# git shim: pass through everything except `worktree remove` (fail 128 like the incident).
BIN="$BASE/bin"; mkdir -p "$BIN"
cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "worktree" ] && [ "\${2:-}" = "remove" ]; then
  # emulate the observed failure: "fatal: '<path>' is not a working tree" + rc 128
  last="\${@: -1}"; echo "fatal: '\$last' is not a working tree" >&2; exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$BIN/git"

# Hermetic HOME so merge-back's helper shell-outs (v-artifact-*.sh, worktree-gc) resolve without touching
# the operator's real ~/.claude. Best-effort copy; a missing helper self-skips inside merge-back.
HOME_T="$BASE/home"; mkdir -p "$HOME_T/.claude/skills/v/references" "$HOME_T/.claude/runtime"
cp -R "$HERE/." "$HOME_T/.claude/skills/v/references/" 2>/dev/null || true

SID="dddddddd-1111-4222-8333-444455556666"; SID8="${SID:0:8}"
REPO="$BASE/repo"; mkdir -p "$REPO"
( cd "$REPO"
  "$REAL_GIT" init -q
  "$REAL_GIT" config user.email t@t.local; "$REAL_GIT" config user.name t
  printf 'print("v1")\n' > app.py
  "$REAL_GIT" add -A; "$REAL_GIT" commit -qm init )
DEF="$("$REAL_GIT" -C "$REPO" symbolic-ref --short HEAD)"

# Worktree session: branch carries -<sid8> (ownership); commit a landable change (no divergence on main → ff).
WT="$BASE/wt"
"$REAL_GIT" -C "$REPO" worktree add -q "$WT" -b "build/feature-${SID8}" HEAD
printf 'print("v1")\nLANDED_CHANGE = True\n' > "$WT/app.py"
"$REAL_GIT" -C "$WT" add -A; "$REAL_GIT" -C "$WT" commit -qm "wt change"
mkdir -p "$REPO/.v/tmp"; printf '%s\n' "$("$REAL_GIT" -C "$REPO" rev-parse HEAD)" > "$REPO/.v/tmp/head-baseline-$SID.txt"

echo "== FIND-2: worktree-remove failure AFTER a landed ff-merge must NOT invert success =="
out="$(PATH="$BIN:$PATH" CLAUDE_MAIN_BRANCH="$DEF" V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_NO_WORKTREE_GC=1 \
  V_TMP_DIR="$REPO/.v/tmp" REPO_ROOT="$REPO" HOME="$HOME_T" \
  env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
  bash "$MB" "$SID" "$WT" 2>&1)"; rc=$?

# Ground truth #1: the change MUST be on main regardless of cleanup outcome (proves the merge landed).
if "$REAL_GIT" -C "$REPO" cat-file -p "$DEF:app.py" 2>/dev/null | grep -q 'LANDED_CHANGE'; then
  ok "the ff-merge LANDED on $DEF (change present on main)"
  LANDED=1
else
  no "the change did NOT land on $DEF — fixture did not reach the merge" "${out: -400}"; LANDED=0
fi

# Ground truth #2: with the change landed, merge-back MUST report success (rc=0), not invert to failure.
if [ "$LANDED" = 1 ]; then
  if [ "$rc" -eq 0 ]; then
    ok "merge-back returns 0 despite the worktree-remove fault (success not inverted)"
  else
    no "merge-back returned rc=$rc after a LANDED merge (success inverted — the FIND-2 bug)" "${out: -400}"
  fi
fi

# Ground truth #3 (SREV-001, adversarial review): the worktree's on-disk directory must NOT be left behind.
# The prune fallback only deregisters; without the rm -rf follow-up the dir leaks invisibly to the GC.
if [ "$LANDED" = 1 ] && [ "$rc" -eq 0 ]; then
  if [ ! -d "$WT" ]; then
    ok "SREV-001: worktree directory removed from disk (no orphaned residue)"
  else
    no "SREV-001: worktree directory '$WT' still on disk after cleanup (prune deregistered but left the dir — GC-invisible leak)"
  fi
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
