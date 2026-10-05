#!/usr/bin/env bash
# readonly-edit-guard-test.sh — behavioral harness for readonly-edit-guard.sh (PreToolUse, W57-F4).
#
# WHY THIS EXISTS (audit 2026-06-17): readonly-edit-guard.sh had ZERO behavioral coverage — its only
# reference was a quoted token in v-token-budget-test.sh's anchor list. This harness drives the REAL
# hook over stdin in a scratch git repo and asserts the deny/allow matrix: a read-only-marked session
# editing a TRACKED source file is denied; artifact/untracked/no-marker/override paths are allowed
# (the documented fail-open boundaries — this guard must never brick legitimate editing).
set -uo pipefail
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/readonly-edit-guard.sh"
[ -f "$HOOK" ] || { echo "NO readonly-edit-guard.sh missing"; exit 1; }

BASE=$(mktemp -d /tmp/roeg-test.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Isolated HOME so the readonly marker lives in OUR sandbox runtime dir; symlink the real hooks lib
# so resolve-sid.sh is found at $HOOK's own dir (it resolves lib relative to BASH_SOURCE, which stays
# the real tree — good — but the marker path uses $HOME, which we sandbox here).
export HOME="$BASE/home"; mkdir -p "$HOME/.claude/runtime"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.local GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.local
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID V_READONLY_OVERRIDE 2>/dev/null || true

SID="11111111-2222-4333-8444-555555555555"
REPO="$BASE/repo"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && echo 'x' > tracked.php && git add -A && git commit -qm init )

# run from inside the repo so the hook's `git rev-parse` sees it
run(){ local json="$1"; ( cd "$REPO" && printf '%s' "$json" | bash "$HOOK" 2>/dev/null ); }
# [ -n ] first: jq 1.6 (Debian 12) exits 0 for `jq -e` on empty input, which read "no output" as a deny.
is_deny(){ [ -n "$1" ] && printf '%s' "$1" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; }
mark_readonly(){ : > "$HOME/.claude/runtime/readonly-session-${SID}"; }
unmark(){ rm -f "$HOME/.claude/runtime/readonly-session-${SID}"; }

J_TRACKED='{"session_id":"'"$SID"'","tool_input":{"file_path":"'"$REPO"'/tracked.php"}}'
J_REPORT='{"session_id":"'"$SID"'","tool_input":{"file_path":"'"$REPO"'/AUDIT_FINDINGS.md"}}'
J_UNTRACKED='{"session_id":"'"$SID"'","tool_input":{"file_path":"'"$REPO"'/new_scratch.php"}}'

echo "=== T1: read-only session editing a TRACKED source file -> DENY ==="
mark_readonly; OUT=$(run "$J_TRACKED")
is_deny "$OUT" && ok "tracked source edit blocked in read-only session" || no "T1: expected deny (out=$OUT)"

echo "=== T2: read-only session editing an *_FINDINGS.md artifact -> ALLOW ==="
mark_readonly; OUT=$(run "$J_REPORT")
is_deny "$OUT" && no "T2: artifact write wrongly blocked (out=$OUT)" || ok "artifact write allowed under read-only"

echo "=== T3: read-only session creating an UNTRACKED new file -> ALLOW ==="
mark_readonly; OUT=$(run "$J_UNTRACKED")
is_deny "$OUT" && no "T3: untracked new file wrongly blocked (out=$OUT)" || ok "untracked new file allowed"

echo "=== T4: NO read-only marker -> ALLOW (normal session) ==="
unmark; OUT=$(run "$J_TRACKED")
is_deny "$OUT" && no "T4: tracked edit blocked without marker (out=$OUT)" || ok "no marker -> tracked edit allowed"

echo "=== T5: read-only marker + V_READONLY_OVERRIDE=1 -> ALLOW (escape hatch) ==="
mark_readonly; OUT=$( cd "$REPO" && printf '%s' "$J_TRACKED" | V_READONLY_OVERRIDE=1 bash "$HOOK" 2>/dev/null )
is_deny "$OUT" && no "T5: override did not bypass (out=$OUT)" || ok "V_READONLY_OVERRIDE bypasses the guard"

# ═══ ND-0716 AGENT FENCE — the three "read-only on source" reviewer agents ═══
# Ground truth (live probe 2026-07-16): PreToolUse hooks fire inside subagent tool calls and
# the payload's .agent_type carries the agent NAME. These agents' read-only-ness was PROSE-ONLY:
# `memory: project` silently re-grants Edit/Write regardless of tools: allowlist, and the session
# read-only marker never exists in a normal code-changing /v session. NO marker is set below —
# the fence must key on agent_type alone.
unmark
jf(){ printf '{"session_id":"%s","agent_type":"%s","tool_input":{"file_path":"%s"}}' "$SID" "$1" "$2"; }

echo "=== T6: v-qa-reviewer editing SOURCE (no marker) -> DENY ==="
OUT=$(run "$(jf v-qa-reviewer "$REPO/tracked.php")")
is_deny "$OUT" && ok "qa-reviewer source edit fenced" || no "T6: v-qa-reviewer allowed to edit source (out=$OUT)"

echo "=== T6b: v-qa-reviewer creating a NEW UNTRACKED source file -> DENY (stricter than session guard) ==="
OUT=$(run "$(jf v-qa-reviewer "$REPO/new_probe.php")")
is_deny "$OUT" && ok "qa-reviewer new source file fenced" || no "T6b: new source file allowed (out=$OUT)"

echo "=== T7: v-qa-reviewer writing its OWN artifact -> ALLOW (root + .v/artifacts) ==="
OUT=$(run "$(jf v-qa-reviewer "$REPO/QA_REPORT_${SID}.md")")
is_deny "$OUT" && no "T7: QA_REPORT write blocked (out=$OUT)" || ok "QA_REPORT at repo root allowed"
OUT=$(run "$(jf v-qa-reviewer "$REPO/.v/artifacts/QA_REPORT_${SID}.md")")
is_deny "$OUT" && no "T7: .v/artifacts QA_REPORT blocked (out=$OUT)" || ok "QA_REPORT under .v/artifacts allowed"

echo "=== T7c (CODEX-001): artifact-token EXTENSION laundering -> DENY ==="
OUT=$(run "$(jf v-qa-reviewer "$REPO/QA_REPORT_payload.php")")
is_deny "$OUT" && ok "QA_REPORT_*.php (executable laundered under artifact token) denied" || no "T7c: .php laundering allowed (out=$OUT)"
OUT=$(run "$(jf v-ux-critique-reviewer "$REPO/src/UX_CRITIQUE_backdoor.sh")")
is_deny "$OUT" && ok "UX_CRITIQUE_*.sh laundering denied" || no "T7c: .sh laundering allowed (out=$OUT)"

echo "=== T7b: v-qa-reviewer writing ANOTHER agent's artifact -> DENY (no cross-artifact laundering) ==="
OUT=$(run "$(jf v-qa-reviewer "$REPO/UX_CRITIQUE_${SID}.md")")
is_deny "$OUT" && ok "qa-reviewer cannot write UX_CRITIQUE" || no "T7b: cross-artifact write allowed (out=$OUT)"

echo "=== T8: v-ux-critique-reviewer matrix ==="
OUT=$(run "$(jf v-ux-critique-reviewer "$REPO/UX_CRITIQUE_${SID}.md")")
is_deny "$OUT" && no "T8: UX_CRITIQUE write blocked (out=$OUT)" || ok "ux-critique own artifact allowed"
OUT=$(run "$(jf v-ux-critique-reviewer "$REPO/tracked.php")")
is_deny "$OUT" && ok "ux-critique source edit fenced" || no "T8: ux-critique allowed to edit source (out=$OUT)"

echo "=== T9: v-workflow-verifier matrix (artifact + Playwright spec lane) ==="
OUT=$(run "$(jf v-workflow-verifier "$REPO/WORKFLOW_VERIFICATION_${SID}.md")")
is_deny "$OUT" && no "T9: WORKFLOW_VERIFICATION blocked (out=$OUT)" || ok "workflow-verifier own artifact allowed"
OUT=$(run "$(jf v-workflow-verifier "$REPO/tests/e2e/golden-path.spec.ts")")
is_deny "$OUT" && no "T9: e2e spec write blocked (out=$OUT)" || ok "workflow-verifier Playwright spec allowed"
OUT=$(run "$(jf v-workflow-verifier "$REPO/playwright.config.ts")")
is_deny "$OUT" && no "T9: playwright.config write blocked (out=$OUT)" || ok "workflow-verifier playwright.config allowed"
OUT=$(run "$(jf v-workflow-verifier "$REPO/app/Http/Controller.php")")
is_deny "$OUT" && ok "workflow-verifier app source fenced" || no "T9: workflow-verifier allowed to edit app source (out=$OUT)"

echo "=== T10: scratchpad/.v paths allowed for fenced agents (bare /tmp is NOT) ==="
OUT=$(run "$(jf v-qa-reviewer "/private/tmp/claude-1000/some-session/scratchpad/note.md")")
is_deny "$OUT" && no "T10: claude scratchpad write blocked (out=$OUT)" || ok "claude scratchpad allowed"
OUT=$(run "$(jf v-qa-reviewer "$REPO/.v/tmp/probe.json")")
is_deny "$OUT" && no "T10: .v/tmp write blocked (out=$OUT)" || ok ".v/ scratch allowed"
OUT=$(run "$(jf v-qa-reviewer "/tmp/not-a-scratchpad/evil.php")")
is_deny "$OUT" && ok "bare /tmp source stash denied" || no "T10: bare /tmp write allowed (out=$OUT)"

echo "=== T11: NON-fenced agents unaffected (sibling-session safety) ==="
OUT=$(run "$(jf general-purpose "$REPO/tracked.php")")
is_deny "$OUT" && no "T11: general-purpose agent wrongly fenced (out=$OUT)" || ok "general-purpose untouched"
OUT=$(run "$(jf codex-adversarial-reviewer "$REPO/AGENT_REVIEW_${SID}.md")")
is_deny "$OUT" && no "T11: codex reviewer artifact write blocked (out=$OUT)" || ok "codex reviewer untouched"

echo "=== T12: fence honors V_READONLY_OVERRIDE=1 (same escape hatch) ==="
OUT=$( cd "$REPO" && printf '%s' "$(jf v-qa-reviewer "$REPO/tracked.php")" | V_READONLY_OVERRIDE=1 bash "$HOOK" 2>/dev/null )
is_deny "$OUT" && no "T12: override did not bypass fence (out=$OUT)" || ok "override bypasses fence"

echo "─────────────────────────────────────────"
echo "readonly-edit-guard-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
