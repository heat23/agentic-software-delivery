#!/usr/bin/env bash
# capture-quarantine-test.sh — item 17b (2026-07-03): v-merge-all capture-commit hygiene.
#
# v-merge-all's Step 2a capture commit used to `git add -u` + stage recognized-extension
# untracked files INDISCRIMINATELY — sweeping (a) telemetry/per-session artifacts
# (SESSION_LOG*/markers matched the `*.md` untracked-file allowlist) and (b) `app/*` WIP
# provably authored by ANOTHER live/unlogged session (shared-index absorption, the same class
# P12 hard-blocks on at commit time — but a capture step should gracefully EXCLUDE, not just
# fail) onto main's history.
#
# COVERAGE: this EXTRACTS the `_v_merge_all_capture_quarantine` function VERBATIM from
# skills/v-merge-all/SKILL.md (real coverage, not a re-impl, mirroring
# hooks/sessionlog-warn-gate-test.sh) and runs it against a real temp git repo + the REAL
# production libs (hooks/lib/artifact-prefix-registry.sh, hooks/lib/session-writes.sh) copied
# into a sandboxed $HOME, with a synthetic sibling writes-ledger proving foreign ownership.
#
# RED on the pre-fix SKILL.md (no _v_merge_all_capture_quarantine function): extraction empty,
# harness reports the function missing and fails loudly rather than silently skipping.
set -u
SKILL="${V_MERGE_ALL_SKILL_OVERRIDE:-$HOME/.claude/skills/v-merge-all/SKILL.md}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

[ -f "$SKILL" ] || { echo "NO SKILL.md missing: $SKILL"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

FN="$(awk '/^_v_merge_all_capture_quarantine\(\) \{/,/^\}$/' "$SKILL")"
[ -n "$FN" ] || { echo "NO _v_merge_all_capture_quarantine function not found in SKILL.md"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# ── Sandbox $HOME with the REAL production libs (real coverage) ──────────────────────────────
SANDBOX_HOME="$WORK/home"
mkdir -p "$SANDBOX_HOME/.claude/hooks/lib"
cp "$HOME/.claude/hooks/lib/artifact-prefix-registry.sh" "$SANDBOX_HOME/.claude/hooks/lib/" 2>/dev/null
cp "$HOME/.claude/hooks/lib/session-writes.sh" "$SANDBOX_HOME/.claude/hooks/lib/" 2>/dev/null
cp "$HOME/.claude/hooks/lib/session-lock-parse.sh" "$SANDBOX_HOME/.claude/hooks/lib/" 2>/dev/null
[ -f "$SANDBOX_HOME/.claude/hooks/lib/artifact-prefix-registry.sh" ] || { echo "NO could not stage sandbox libs"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

REPO="$WORK/repo"
mkdir -p "$REPO/app"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
: > "$REPO/app/.gitkeep"
git -C "$REPO" add -A >/dev/null
git -C "$REPO" commit -qm init

MY_SID="my-11111111-1111-1111-1111-111111111111"
SIB_SID="sib-22222222-2222-2222-2222-222222222222"
GITDIR="$REPO/.git"

# my own log: non-empty (SREV-001 requirement) but does NOT include the sibling file
echo "app/mine.php" > "$GITDIR/claude-session-writes-${MY_SID}.txt"
# sibling log: proves sibling authored app/Foo.php
echo "app/Foo.php" > "$GITDIR/claude-session-writes-${SIB_SID}.txt"

run_quarantine() {
  ( cd "$REPO" && HOME="$SANDBOX_HOME" CLAUDE_SESSION_ID="$MY_SID" bash -c "$FN"$'\n'"_v_merge_all_capture_quarantine" )
}

echo "== item 17b :: v-merge-all capture-commit quarantine =="

# Case 1: telemetry file staged alongside legit own-authored file → telemetry excluded, own file stays.
printf 'gap\n' > "$REPO/SESSION_LOG_MISSING_33333333-3333-3333-3333-333333333333.md"
printf '<?php // mine\n' > "$REPO/app/mine.php"
git -C "$REPO" add -A >/dev/null
OUT1="$(run_quarantine)"
STAGED1="$(git -C "$REPO" diff --cached --name-only)"
if printf '%s\n' "$OUT1" | grep -q "QUARANTINED (telemetry" && ! printf '%s\n' "$STAGED1" | grep -q "SESSION_LOG_MISSING"; then
  ok "1 telemetry file (SESSION_LOG_MISSING_*.md) unstaged + logged"
else
  no "1 telemetry file NOT quarantined" "out=$OUT1 staged=$STAGED1"
fi
printf '%s\n' "$STAGED1" | grep -q "app/mine.php" && ok "1b own legit file remains staged" || no "1b own file wrongly dropped" "staged=$STAGED1"
git -C "$REPO" reset -q HEAD -- . >/dev/null 2>&1
rm -f "$REPO/SESSION_LOG_MISSING_33333333-3333-3333-3333-333333333333.md"

# Case 2: sibling-owned app file staged → excluded; own file stays.
printf '<?php // sibling WIP\n' > "$REPO/app/Foo.php"
git -C "$REPO" add -A >/dev/null
OUT2="$(run_quarantine)"
STAGED2="$(git -C "$REPO" diff --cached --name-only)"
if printf '%s\n' "$OUT2" | grep -q "QUARANTINED (sibling-owned" && ! printf '%s\n' "$STAGED2" | grep -q "app/Foo.php"; then
  ok "2 sibling-owned app/Foo.php unstaged + logged"
else
  no "2 sibling-owned file NOT quarantined" "out=$OUT2 staged=$STAGED2"
fi
printf '%s\n' "$STAGED2" | grep -q "app/mine.php" && ok "2b own legit file remains staged" || no "2b own file wrongly dropped" "staged=$STAGED2"
git -C "$REPO" reset -q HEAD -- . >/dev/null 2>&1
rm -f "$REPO/app/Foo.php"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
