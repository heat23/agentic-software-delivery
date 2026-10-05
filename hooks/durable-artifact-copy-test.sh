#!/usr/bin/env bash
# durable-artifact-copy-test.sh — bite for C-2 (handoff-3, 2026-07-02): write-time durable copy of
# verdict-bearing /v artifacts. Prior to this fix, the ONLY durable copy happened at merge/finalize
# (v-artifact-consolidate.sh) — a session that aborts, crashes, or is QA-failed before merge-back never
# reaches that step, so its evidence (QA_REPORT, AGENT_REVIEW, BLOCKED, ...) is lost to worktree teardown.
# Verified real losses: a QA_REPORT (sha256 in provenance, file gone) and another session's
# PRE_FLIGHT/AGENT_REVIEW/BLOCKED (worktree-only, protected only by chance via the M2 dirty-guard).
#
# Asserts the REAL hook (hooks/durable-artifact-copy.sh), PostToolUse matcher "Write":
#   GREEN-1: Write of QA_REPORT_<sid>.md inside a linked worktree -> durable byte-identical copy lands at
#            <main-root>/.v/artifacts/QA_REPORT_<sid>.md (main root resolved via git-common-dir identity,
#            NOT a path-prefix guess — the exact class C-3 fixed for session-writes capture).
#   GREEN-2: teardown survival — `rm -rf` the worktree AFTER the write -> the durable copy still exists
#            and is byte-identical to what was written (the actual production failure mode).
#   GREEN-3: idempotence — writing the SAME artifact twice (e.g. a pre-flight retry) does not error and the
#            durable copy reflects the LATEST content (write-time semantics, not append).
#   neg-1: Write of a non-verdict file (e.g. a source .php file) -> no durable copy created for it.
#   neg-2: Write of a verdict-named file OUTSIDE any git repo -> silent no-op (fail-open, no crash).
#   neg-3: irrelevant tool (Edit) -> no-op (matcher scope; the hook must also self-guard since some
#          registrations may be broader).
# RED (bite-ledger oracle): point V_DAC_HOOK at a neutered copy whose copy-step is stripped -> GREEN-1
# assertion fails (no durable copy) -> exit 1.
set -u
HOOK="${V_DAC_HOOK:-$HOME/.claude/hooks/durable-artifact-copy.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO durable-artifact-copy.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
SID="dac-test-sid-abcdef01"

# Build a MAIN repo + a LINKED worktree off it (mirrors the external-worktree convention C-3 fixed).
MAIN="$WORK/main"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com; git -C "$MAIN" config user.name t
: > "$MAIN/.gitkeep"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init
WT="$WORK/wt-external/fix-slug-${SID}"
mkdir -p "$WORK/wt-external"
git -C "$MAIN" worktree add -q -b "fix/slug-${SID}" "$WT" >/dev/null 2>&1

run_hook() {  # $1=tool $2=cwd $3=file_path -> writes the artifact THEN fires the hook (mirrors real
              # PostToolUse ordering — the Write already landed before the hook fires).
  local tool="$1" cwd="$2" fp="$3"
  printf '{"tool_name":"%s","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' \
    "$tool" "$SID" "$cwd" "$fp" | bash "$HOOK" >/dev/null 2>&1
}

echo "== C-2 :: durable-artifact-copy.sh (write-time evidence durability) =="

# GREEN-1: QA_REPORT written in the linked worktree -> durable copy at MAIN's .v/artifacts.
QA="$WT/QA_REPORT_${SID}.md"
printf 'Model: haiku\n\n## QA Report\n\nverdict: fail\n' > "$QA"
run_hook "Write" "$WT" "$QA"
DUR="$MAIN/.v/artifacts/QA_REPORT_${SID}.md"
if [ -f "$DUR" ] && diff -q "$QA" "$DUR" >/dev/null 2>&1; then
  ok "worktree Write of QA_REPORT -> durable byte-identical copy at <main>/.v/artifacts/"
else
  no "no durable copy (or content mismatch) after worktree QA_REPORT write" "expected=$DUR"
fi

# GREEN-2: teardown survival — remove the worktree entirely, durable copy must remain untouched.
CONTENT_BEFORE="$(cat "$DUR" 2>/dev/null)"
rm -rf "$WT"
if [ -f "$DUR" ] && [ "$(cat "$DUR" 2>/dev/null)" = "$CONTENT_BEFORE" ]; then
  ok "durable copy survives worktree teardown (rm -rf) — the actual production failure mode"
else
  no "durable copy did not survive worktree removal"
fi

# GREEN-3: idempotence — re-add the worktree, write a DIFFERENT verdict, re-fire -> durable copy updates
# to the latest content (write-time semantics), no error on double-write.
git -C "$MAIN" worktree prune >/dev/null 2>&1
git -C "$MAIN" worktree add -q "$WT" "fix/slug-${SID}" >/dev/null 2>&1
QA2="$WT/QA_REPORT_${SID}.md"
printf 'Model: haiku\n\n## QA Report\n\nverdict: pass\n' > "$QA2"
run_hook "Write" "$WT" "$QA2"
if [ -f "$DUR" ] && grep -q 'verdict: pass' "$DUR" 2>/dev/null; then
  ok "re-write (retry) updates the durable copy to latest content — no append/duplication"
else
  no "durable copy not updated on re-write" "content=$(cat "$DUR" 2>/dev/null | tail -3)"
fi

# neg-1: non-verdict file (source .php) -> no durable copy created for it.
SRC="$WT/app/Foo.php"
mkdir -p "$(dirname "$SRC")"; printf '<?php\n' > "$SRC"
run_hook "Write" "$WT" "$SRC"
if [ ! -f "$MAIN/.v/artifacts/Foo.php" ]; then
  ok "non-verdict source file -> no durable copy created (scope guard holds)"
else
  no "source file was incorrectly copied to .v/artifacts"
fi

# neg-2: verdict-named file OUTSIDE any git repo -> silent no-op, must not crash / must not error loudly.
NOGIT="$WORK/no-git-dir"; mkdir -p "$NOGIT"
BLK="$NOGIT/BLOCKED_${SID}.md"; printf 'blocked\n' > "$BLK"
if printf '{"tool_name":"Write","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$NOGIT" "$BLK" | bash "$HOOK" >/dev/null 2>&1; then
  ok "non-repo verdict-file write -> hook exits cleanly (fail-open, no crash)"
else
  no "hook exited non-zero on a non-repo write (must be fail-open)"
fi

# GREEN-3 (ORCHFIX-A2, was neg-3): Edit MUST now mirror. The old assertion pinned the Write-only
# hole — every Edit to a root artifact left the .v/artifacts copy stale, and validators/attest
# resolve that copy (repeated false Stop-blocks on already-fixed content, then a
# hand-sync workaround). Edit/MultiEdit are now in-scope for the durable copy.
git -C "$MAIN" worktree add -q "$WT" "fix/slug-${SID}" >/dev/null 2>&1 || true
EDITFILE="$WT/IMPACT_MAP_${SID}-edit-probe.md"
printf 'edit-probe\n' > "$EDITFILE"
run_hook "Edit" "$WT" "$EDITFILE"
if [ -f "$MAIN/.v/artifacts/IMPACT_MAP_${SID}-edit-probe.md" ] \
   && cmp -s "$EDITFILE" "$MAIN/.v/artifacts/IMPACT_MAP_${SID}-edit-probe.md"; then
  ok "Edit tool call -> durable byte-identical copy (ORCHFIX-A2 Edit coverage)"
else
  no "Edit tool call did NOT produce a durable copy (Write-only mirror-desync hole is back)"
fi

# neg-3b: a genuinely irrelevant tool (Read) on a verdict filename -> still no durable copy.
READPROBE="$WT/IMPACT_MAP_${SID}-read-probe.md"
printf 'read-probe\n' > "$READPROBE"
run_hook "Read" "$WT" "$READPROBE"
if [ ! -f "$MAIN/.v/artifacts/IMPACT_MAP_${SID}-read-probe.md" ]; then
  ok "Read tool call -> no durable copy (tool scope still bounded)"
else
  no "Read tool call incorrectly triggered a durable copy"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
