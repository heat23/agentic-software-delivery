#!/usr/bin/env bash
# v-agent-review-skeleton-wiring-test.sh — WIRING GUARD for the Lever-1 efficiency fast path (2026-06-30).
#
# WHY: v-emit-agent-review-skeleton.sh emits a valid-on-arrival AGENT_REVIEW draft with the Dispatch-mode DERIVED
# from DISPATCH_PROVENANCE, collapsing the Post-Dispatch Wrap's manual 8-field construction into ONE Bash call
# (the measured win). That savings ONLY lands if v-agent-review.md actually ROUTES the model to the script. A doc
# edit that drops the reference would silently revert every session to the slow manual build with NO test failing.
# This guard pins the wiring live: it fails if the fast path rots, the referenced script vanishes (dangling
# pointer), or the script's own bite disappears. It changes NO runtime behavior — pure wiring/orphan guard.
set -uo pipefail
DOC="${DOC:-$HOME/.claude/skills/v/references/v-agent-review.md}"
SCRIPT="${SCRIPT:-$HOME/.claude/skills/v/references/v-emit-agent-review-skeleton.sh}"
BITE="${BITE:-$HOME/.claude/skills/v/references/orch-r2-skeleton-test.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$DOC" ] || { echo "FATAL: $DOC missing"; exit 2; }

# 1. the doc routes the Post-Dispatch Wrap to the skeleton generator (the wiring itself)
grep -q 'v-emit-agent-review-skeleton.sh' "$DOC" \
  && ok "v-agent-review.md routes the Wrap to v-emit-agent-review-skeleton.sh (lever wired)" \
  || no "v-agent-review.md no longer references v-emit-agent-review-skeleton.sh — Lever-1 fast path ROTTED (model back to manual 8-field build)"

# 2. the referenced script actually exists on disk (no dangling pointer)
[ -f "$SCRIPT" ] \
  && ok "the referenced skeleton generator exists on disk" \
  || no "the doc references v-emit-agent-review-skeleton.sh but it is MISSING on disk (dangling pointer)"

# 3. the fast-path call lives INSIDE the Post-Dispatch Wrap section (so the model meets it at the right step)
awk '/### Post-Dispatch Wrap/{w=1} w&&/v-emit-agent-review-skeleton.sh/{found=1} END{exit !found}' "$DOC" \
  && ok "the script call is within the Post-Dispatch Wrap section" \
  || no "the skeleton script reference is not inside the Post-Dispatch Wrap section (stranded — model may not see it)"

# 4. the script's own behavioral bite still exists AND is non-empty (the lever stays trustworthy / no silent
# under-test). The sweep runs the bite itself independently, so a NON-EMPTY existence check here is sufficient —
# re-executing it nested would just double-run it. (-s not -f: an emptied/truncated bite must not read as present.)
[ -s "$BITE" ] \
  && ok "the script's bite (orch-r2-skeleton-test.sh) is present and non-empty" \
  || no "orch-r2-skeleton-test.sh (the skeleton script's behavioral bite) is missing or empty"

echo ""
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
