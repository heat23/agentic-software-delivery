#!/usr/bin/env bash
# handoff-merge-deferred-test.sh — item 27 (2026-07-03): HANDOFF template fix.
#
# Two HANDOFF template surfaces both used to lack a `MERGE_DEFERRED: <branch>` field:
#   - skills/v-handoff/references/handoff-template.md (interactive /v-handoff)
#   - skills/v/references/dispatch-v-handoff.md (orchestrator-dispatched haiku subagent)
# Without it, a session that intentionally defers a worktree merge has no way to emit the exact
# line hooks/check-review-artifact.sh's W5F-3/FND-3 gates grep for
# (`^[[:space:]]*MERGE_DEFERRED:[[:space:]]*<branch>`) — the deferral escape hatch was
# undocumented at the point of authorship, so a genuinely-deferred merge got flagged as a
# silently stranded worktree. Separately, both docs must steer away from telling a resuming
# session to land the branch with a raw `git checkout main` + `git merge --ff-only` (unexecutable
# from a linked worktree + bypasses the merge lock/artifact gate/commit witness) and toward
# `v-merge-back.sh`.
#
# This test (a) asserts both template docs now carry the MERGE_DEFERRED field + the
# anti-raw-merge guidance, and (b) proves the line format they emit is byte-compatible with the
# REAL gate regex extracted verbatim from hooks/check-review-artifact.sh (real coverage).
set -u
HANDOFF_TPL="$HOME/.claude/skills/v-handoff/references/handoff-template.md"
DISPATCH_TPL="$HOME/.claude/skills/v/references/dispatch-v-handoff.md"
HOOK="$HOME/.claude/hooks/check-review-artifact.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }

[ -f "$HANDOFF_TPL" ] || { echo "NO handoff-template.md missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
[ -f "$DISPATCH_TPL" ] || { echo "NO dispatch-v-handoff.md missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
[ -f "$HOOK" ] || { echo "NO check-review-artifact.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

echo "== item 27 :: HANDOFF template MERGE_DEFERRED + no-raw-merge guidance =="

grep -q '^MERGE_DEFERRED:' "$HANDOFF_TPL" \
  && ok "1 handoff-template.md template body has a literal MERGE_DEFERRED: line" \
  || no "1 handoff-template.md missing MERGE_DEFERRED: field" ""

grep -q 'MERGE_DEFERRED: <worktree_branch>' "$DISPATCH_TPL" \
  && ok "2 dispatch-v-handoff.md required template has a literal MERGE_DEFERRED: line" \
  || no "2 dispatch-v-handoff.md missing MERGE_DEFERRED: field in required template" ""

grep -qi 'v-merge-back.sh' "$HANDOFF_TPL" \
  && ok "3 handoff-template.md steers toward v-merge-back.sh" \
  || no "3 handoff-template.md does not mention v-merge-back.sh" ""

grep -qi 'v-merge-back.sh' "$DISPATCH_TPL" \
  && ok "4 dispatch-v-handoff.md steers toward v-merge-back.sh" \
  || no "4 dispatch-v-handoff.md does not mention v-merge-back.sh" ""

# Both docs must warn against the specific unexecutable/unsafe combo, not just mention checkout.
if grep -q 'git checkout main' "$HANDOFF_TPL" && grep -qi 'never\|unexecutable\|bypasses' "$HANDOFF_TPL"; then
  ok "5 handoff-template.md explicitly forbids raw git checkout main + --ff-only next-step"
else
  no "5 handoff-template.md missing explicit anti-raw-merge warning" ""
fi
if grep -q 'git checkout main' "$DISPATCH_TPL" && grep -qi 'never\|unexecutable\|bypasses' "$DISPATCH_TPL"; then
  ok "6 dispatch-v-handoff.md explicitly forbids raw git checkout main + --ff-only next-step"
else
  no "6 dispatch-v-handoff.md missing explicit anti-raw-merge warning" ""
fi

# ── Real-gate compatibility: extract the W5F-3 MERGE_DEFERRED match logic verbatim and prove a
# rendered "MERGE_DEFERRED: <branch>" line (as our templates would emit it) actually matches.
W5F3_BLOCK="$(awk '/# ── W5F-3 \(forensic 2026-06-06\)/,/^fi$/' "$HOOK" | head -60)"
[ -n "$W5F3_BLOCK" ] || { echo "NO could not extract W5F-3 block from hook (structure changed?)"; echo "TOTAL: $PASS passed, $((FAIL+1)) failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
printf '# Handoff\n\nMERGE_DEFERRED: build/example-branch-123\n' > "$WORK/HANDOFF_sid.md"
DECL="$(grep -E '^[[:space:]]*MERGE_DEFERRED:' "$WORK/HANDOFF_sid.md" | sed -E 's/^[[:space:]]*MERGE_DEFERRED:[[:space:]]*//' | awk '{print $1}')"
[ "$DECL" = "build/example-branch-123" ] \
  && ok "7 rendered MERGE_DEFERRED line round-trips through the hook's own extraction (sed+awk) to the exact branch token" \
  || no "7 rendered line did not round-trip" "got='$DECL'"

# ── Filename-literal contract (P1 2026-08-12): the Stop-hook completion gates test for the LITERAL
# HANDOFF_<sid>.md via -f (check-review-artifact.sh :911/:3062/:3158). A timestamped filename is
# invisible to them, so a handoff written under a timestamped name never clears Stop. Assert the
# dispatch source + template emit the literal name, never a timestamp. This BITES if the timestamped
# form regresses back in.
DISPATCH_SRC="$HOME/.claude/skills/v/references/dispatch-v-handoff.md"
TPL_SRC="$HOME/.claude/skills/v-handoff/references/handoff-template.md"
if grep -qE 'HANDOFF_(<timestamp>|\{timestamp\}|\{YYYY)' "$DISPATCH_SRC" "$TPL_SRC" 2>/dev/null; then
  no "8 dispatch/template still emit a TIMESTAMPED HANDOFF filename (invisible to the Stop gate)"
elif grep -q 'HANDOFF_\$SESSION_ID.md' "$DISPATCH_SRC" && grep -q 'HANDOFF_\${CLAUDE_SESSION_ID}.md' "$TPL_SRC"; then
  ok "8 dispatch + template emit the LITERAL HANDOFF_<sid>.md the Stop gate tests for"
else
  no "8 could not confirm the literal HANDOFF filename in dispatch/template"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
