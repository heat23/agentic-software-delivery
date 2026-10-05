#!/usr/bin/env bash
# d2-provenance-deathloop-guidance-test.sh — D2 (forensic F3 / MR-2, 2026-06-21). The orchestrator
# must NOT yield to the Stop hook while a provenance-bearing reviewer (QA / verify-done / codex) dispatch is
# still in-flight: the Stop hook is blind to the not-yet-landed background artifact + provenance (the deferred
# P2 continuation-provenance gap), blocks on the "missing" artifact, and forces a paid foreground re-dispatch
# (one observed session re-dispatched v-qa-reviewer 3x + v-verify-done 2x). The foreground-first directive is
# the actionable mitigation (the deep fix is the deferred P2 gap). Doc-guard: the directive must stay in
# SKILL.md. (Consistent with the repo's spec-convention SKILL.md greps.) Re-run: bash <thisfile>
set -u
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SKILL="$ROOT/skills/v/SKILL.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
[ -f "$SKILL" ] || { echo "SKIP: SKILL.md missing"; exit 0; }

echo "== D2 :: provenance death-loop foreground-first directive present =="
grep -q 'D2 provenance death-loop' "$SKILL" \
  && ok "D2 directive present in SKILL.md (anti-removal)" || no "D2 directive removed from SKILL.md" "grep miss"
grep -qiE 'NEVER end your turn / yield to the Stop hook while a provenance-bearing reviewer' "$SKILL" \
  && ok "foreground-first rule: do not yield while a provenance-bearing dispatch is in-flight" || no "foreground-first rule text missing" "grep miss"
grep -qiE 'ON DISK before the turn ends' "$SKILL" \
  && ok "confirms artifact + provenance must be ON DISK before yielding" || no "on-disk-before-yield confirmation missing" "grep miss"
# The directive must cite the forensic + the recurring cost so it isn't trimmed as boilerplate.
grep -qiE 'observed session re-dispatched' "$SKILL" && grep -qiE '2×, recurring' "$SKILL" \
  && ok "cites the death-loop evidence (3x qa + 2x verify, recurring)" || no "forensic evidence citation missing" "grep miss"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
