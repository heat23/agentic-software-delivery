#!/usr/bin/env bash
# tc-batch-health-test.sh — bite for T-C (+ T-B/T-D/T-E folded in): v-batch-health.sh classifies a window of /v
# sessions (LOGGED/INVALID/ACTIVE/...), counts dispatch-path over-claims (T-E), and surfaces Stop-block churn
# (T-B). Behavioral over a fixture repo. RED via V_BH_OVERRIDE pointed at a mutant with the over-claim grep broken.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BH="${V_BH_OVERRIDE:-$HERE/v-batch-health.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$BH" ] || { echo "NO v-batch-health.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

CFG="$(mktemp -d)"; trap 'rm -rf "$CFG" 2>/dev/null' EXIT
export CLAUDE_CONFIG_DIR="$CFG"
REPO="$CFG/repo"; mkdir -p "$REPO/.v/tmp"
TD="$CFG/projects/$(printf '%s' "$REPO" | sed 's#/#-#g')"; mkdir -p "$TD"
S1=11111111-1111-4111-8111-111111111111   # LOGGED
S2=22222222-2222-4222-8222-222222222222   # INVALID + dispatch_path over-claim + a Stop-block
S3=33333333-3333-4333-8333-333333333333   # ACTIVE (no terminal marker, fresh transcript)
S4=44444444-4444-4444-8444-444444444444   # INVALID via ONLY .yaml.invalid (no .md) — SREV-003 OR-semantics
S5=55555555-5555-4555-8555-555555555555   # DEFERRED via ONLY HANDOFF (single glob) — SREV-003 OR-semantics
for s in "$S1" "$S2" "$S3" "$S4" "$S5"; do
  printf 'export CLAUDE_SESSION_ID=%s\n' "$s" > "$REPO/.v/tmp/bootstrap-$s-100.env"
  printf '{"type":"assistant","message":{"id":"a-%s","role":"assistant","model":"claude-opus-4","usage":{"cache_read_input_tokens":10,"input_tokens":1,"output_tokens":1}}}\n' "$s" > "$TD/$s.jsonl"
done
printf 'schema_version: 2\nsession_id: %s\n' "$S1" > "$REPO/SESSION_LOG_$S1.yaml"
printf '{}\n' > "$REPO/SESSION_LOG_$S2.yaml.invalid"
printf '# VALIDATION FAILED\n  - W22-CC1 dispatch_path over-claims independence: agent_review.dispatch_path=codex but artifact says orchestrator-inline\n' > "$REPO/SESSION_LOG_INVALID_$S2.md"
printf '{"type":"user","message":{"content":"Stop hook feedback: COMPLETION BLOCKED — gates not satisfied"}}\n' >> "$TD/$S2.jsonl"
printf '{}\n' > "$REPO/SESSION_LOG_$S4.yaml.invalid"            # SREV-003: ONLY the quarantine, no INVALID.md yet
printf '# Handoff\nMERGE_DEFERRED: branch x\n' > "$REPO/HANDOFF_$S5-deferred.md"  # SREV-003: ONLY a HANDOFF (single glob)

OUT=$(bash "$BH" --repo "$REPO" --since-hours 24 --active-min 60 2>&1)
echo "== T-C :: batch-health classification + over-claim (T-E) + block-churn (T-B) =="
printf '%s' "$OUT" | grep -qE 'LOGGED 1\b'   && ok "T-D: LOGGED session classified (SESSION_LOG.yaml)" || no "LOGGED count wrong" "$(printf '%s' "$OUT"|grep SESSIONS)"
printf '%s' "$OUT" | grep -qE 'INVALID 2\b'  && ok "T-D/SREV-003: INVALID counts BOTH the .md case AND the .yaml.invalid-ONLY case (OR semantics)" || no "INVALID count wrong (SREV-003: ls-AND regressed?)" "$(printf '%s' "$OUT"|grep SESSIONS)"
printf '%s' "$OUT" | grep -qE 'DEFERRED 1\b' && ok "T-D/SREV-003: DEFERRED counts a session with ONLY a HANDOFF (single-glob OR)" || no "DEFERRED count wrong (SREV-003)" ""
printf '%s' "$OUT" | grep -qE 'ACTIVE 1\b'   && ok "T-D: ACTIVE session classified (no marker + fresh transcript)" || no "ACTIVE count wrong" ""
printf '%s' "$OUT" | grep -qE 'OVER-CLAIMS.*: 1\b' && ok "T-E: dispatch_path over-claim counted (1)" || no "over-claim not counted" "$(printf '%s' "$OUT"|grep -i over)"
printf '%s' "$OUT" | grep -qE '· [1-9][0-9]* Stop-blocks' && ok "T-B: Stop-block churn surfaced (>=1) on the WALL line" || no "block churn not surfaced" "$(printf '%s' "$OUT"|grep -i 'stop-block'|tail -1)"
printf '%s' "$OUT" | grep -qiE 'WALL:.*active' && ok "wall-clock (active minutes) surfaced — the efficiency headline" || no "wall-clock not surfaced" "$(printf '%s' "$OUT"|grep -i wall|tail -1)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
