#!/usr/bin/env bash
# d1-skill-structural-integrity-test.sh — D1 Tier-A anti-bloat + anti-mistrim guard (2026-06-21).
#
# The post-batch telemetry proved cache_read (the resident SKILL.md prefix re-read every orchestrator
# turn) is 80-100% of every /v session's cost — so KEEPING the prefix small is a real, recurring cost
# lever. But the file is ALSO the orchestration spine: 21 Step headings, ~57 MANDATORY/FORBIDDEN/CRITICAL
# rules, ~70 references/ pointers (already heavily sharded, "Wave 12 slim"). A careless trim that drops a
# Step, a rule, or un-shards a body back inline is an untestable behavioral regression. This guard makes
# the trade-off SAFE both ways:
#   (1) anti-bloat: SKILL.md must stay UNDER the token ceiling (mirrors v-token-budget-test; ratchets down).
#   (2) anti-mistrim: the Step / rule / references-pointer COUNTS must not drop below their floors — so a
#       trim can shrink PROSE but cannot silently delete execution structure or re-inline an extracted body.
# This is the gate the D1 A/B batch runs behind. Re-run: bash <thisfile>
set -u
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SK="$ROOT/skills/v/SKILL.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
[ -f "$SK" ] || { echo "SKIP: SKILL.md missing"; exit 0; }

# Floors = the 2026-06-21 baseline. RAISE a floor only when you deliberately ADD structure; the guard
# fails if a trim drops below — catching an accidental Step/rule deletion or a re-inlined (un-sharded) body.
STEP_FLOOR=21          # '## Step ' headings (21 today)
RULE_FLOOR=55          # MANDATORY|FORBIDDEN|CRITICAL|🚫|NEVER|MUST lines (57 today; 2-line slack for rewording)
PTR_FLOOR=63           # references/<f>.(sh|md) pointer LINES (65 today; sharding must not regress)
TOK_CEIL=29500         # ratcheted 2026-07-07 (was 32344; file at 29072) — CHARS//4 (multibyte-safe, same as v-token-budget SKILL_MAX_TOKENS) — anti-bloat

_steps=$(grep -cE '^## Step ' "$SK")
_rules=$(grep -cE 'MANDATORY|FORBIDDEN|CRITICAL|🚫|NEVER|MUST ' "$SK")
_ptrs=$(grep -cE 'references/[A-Za-z0-9_-]+\.(sh|md)' "$SK")   # LINES carrying a pointer
_tok=$(python3 -c "print(len(open('$SK',encoding='utf-8').read())//4)" 2>/dev/null || echo $(( $(wc -c < "$SK") / 4 )))

echo "== D1 :: SKILL.md structural integrity (anti-bloat + anti-mistrim) =="
echo "  steps=$_steps rules=$_rules pointers=$_ptrs tokens=$_tok"
[ "$_steps" -ge "$STEP_FLOOR" ] && ok "Step headings preserved ($_steps >= $STEP_FLOOR)" || no "a ## Step heading was DELETED ($_steps < $STEP_FLOOR)" "execution structure lost"
[ "$_rules" -ge "$RULE_FLOOR" ] && ok "MANDATORY/FORBIDDEN/CRITICAL rule lines preserved ($_rules >= $RULE_FLOOR)" || no "a binding rule line was DELETED ($_rules < $RULE_FLOOR)" "behavioral rule lost"
[ "$_ptrs" -ge "$PTR_FLOOR" ] && ok "references/ pointers preserved ($_ptrs >= $PTR_FLOOR — sharding not regressed)" || no "an extracted body was RE-INLINED ($_ptrs < $PTR_FLOOR)" "un-sharded -> bloat"
[ "$_tok" -le "$TOK_CEIL" ] && ok "SKILL.md under the token ceiling ($_tok <= $TOK_CEIL — prefix cost bounded)" || no "SKILL.md GREW past the ceiling ($_tok > $TOK_CEIL)" "trim/shard or raise the ceiling deliberately"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
