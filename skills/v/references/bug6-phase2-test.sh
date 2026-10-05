#!/usr/bin/env bash
# bug6-phase2-test.sh — Bug 6 PHASE 2 enforcement harness.
#
# Phase 1 (bug6-test.sh) added MODEL-DISCIPLINE defenses:
#   - /v SKILL.md ANTI-SKIP GUARD (names 3 rationalizations)
#   - v-gauntlet-attest.sh (script the model is told to run)
#   - Stale-artifact-sweep arbitration (per-invocation marker)
#   - resolve-session-sid.sh cross-session reject
#
# Phase 2 (this harness) tests SYSTEM-LEVEL ENFORCEMENT — defenses that fire
# regardless of model self-discipline:
#   B3: Stop hook (check-review-artifact.sh) REQUIRES the v-gauntlet-attest.sh
#       witness file (~/.claude/runtime/v-gauntlet-attestation-<sid>.json) in
#       addition to the three artifact files. If the model skips the script,
#       the witness doesn't exist, the Stop hook blocks. Closes the gap where
#       Phase 1's OBSERVABLE PROOF rule could be ignored.
#   B4: HANDOFF abandonment-escape rejects sessions that SHIPPED code (writes
#       log or commits-since-baseline contain source-file changes). Closes the
#       gap where a production session used HANDOFF as a graceful-exit for completed work.
#
# Test groups:
#   D1-D9: Stop hook witness enforcement (B3)
#   E1-E4: HANDOFF tightening (B4)
#
# Re-run: bash <thisfile>. Self-contained; isolated $HOME; no runtime pollution.
set -uo pipefail
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ATTEST="$REF_DIR/v-gauntlet-attest.sh"
HOOK="$HOME/.claude/hooks/check-review-artifact.sh"
HOOK_LIB="$HOME/.claude/hooks/lib"

[ -x "$HOOK" ] || { echo "SKIP: Stop hook not found/executable at $HOOK"; exit 0; }
[ -d "$HOOK_LIB" ] || { echo "SKIP: hook libs dir not found at $HOOK_LIB"; exit 0; }
[ -f "$ATTEST" ] || { echo "SKIP: attest script not found at $ATTEST"; exit 0; }

# Save user's real ~/.claude/runtime so we don't pollute it.
REAL_HOME="$HOME"
BASE=$(mktemp -d /tmp/bug6-ph2.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# Isolate HOME for runtime artifacts (witness files, history.jsonl).
# Symlink hooks/ + agents/ from REAL_HOME so the Stop hook can find its libs
# (it hardcodes $HOME/.claude/hooks/lib/resolve-sid.sh — HOOKS_LIB_DIR env doesn't
# cover that line). runtime/ stays isolated under fake HOME.
export HOME="$BASE/home"
mkdir -p "$HOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks" "$HOME/.claude/hooks"
[ -d "$REAL_HOME/.claude/agents" ] && ln -s "$REAL_HOME/.claude/agents" "$HOME/.claude/agents"
export HOOKS_LIB_DIR="$HOME/.claude/hooks/lib"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.local GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.local
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID 2>/dev/null || true
unset CLAUDE_PROJECT_DIR V_TMP_DIR V_GAUNTLET_ATTESTATION_MAX_AGE_SEC 2>/dev/null || true

SID_A="aaaaaaaa-1111-4111-8111-111111111111"
SID_B="bbbbbbbb-2222-4222-8222-222222222222"
SID_C="cccccccc-3333-4333-8333-333333333333"

new_repo(){
  local R="$BASE/$1"; mkdir -p "$R"
  ( cd "$R" && git init -q && echo x > .keep && git add -A && git commit -qm init ) >/dev/null 2>&1
  REPLY="$(cd "$R" && pwd -P)"
}

# Plant a substantive artifact (>200B, with the structural markers the hook validates).
plant_pre_flight(){
  local repo="$1" sid="$2"
  # Realistic-size PRE_FLIGHT (>3000B). check-review-artifact F8-b BLOCKS a PRE_FLIGHT < 1024B
  # (stub / wrong-project guard, added 2026-06-02) and WARNS between 1024-3000B; a 299B stub fixture
  # tripped F8-b FIRST and short-circuited every D-case (rc=2 before the intended witness/HMAC
  # checks). Real Laravel+React gate reports are 3-40 KB — this fixture mirrors that so the test
  # exercises the gauntlet-witness gate it is actually about, not the artifact-size guard.
  cat > "$repo/PRE_FLIGHT_REPORT_${sid}.md" <<EOF
Model: haiku

## Pre-Flight Report — ${sid}

Status: completed
Stack: laravel, inertia, react, typescript
Mode: full (all gates)
Working dir: ${repo}

## Gates

| Status | Gate | Duration | Notes |
|--------|------|----------|-------|
| PASS | PHP Tests (pest --parallel --processes=4) | 58.4s | 1200 passed, 0 failed, 0 skipped |
| PASS | JS Tests (vitest run) | 22.1s | 300 passed, 0 failed |
| PASS | TypeScript (tsc --noEmit) | 16.0s | exit 0, 0 type errors |
| PASS | Lint (eslint --max-warnings=0) | 7.3s | 0 warnings, 0 errors |
| PASS | Build (vite build) | 11.2s | bundle ok, 0 chunk-size warnings over budget |
| PASS | composer audit | 2.1s | No security advisories |
| PASS | npm audit --audit-level=critical | 3.0s | 0 critical |

## Timing
- phase_1_wallclock_seconds: 35
- phase_2_wallclock_seconds: 41
- phases_total_wallclock_seconds: 76

## Per-gate detail

### PHP Tests
Ran the full Pest suite under ParaTest (4 workers). 1200 tests covering services,
controllers, jobs, observers, and feature flows. No N+1 regressions (query-count
assertions green). No flaky retries.

### TypeScript / Lint / Build
\`tsc --noEmit\` clean. ESLint clean with --max-warnings=0 (the \`any\` ban holds).
\`vite build\` produced the production bundle with modulepreload links intact.

## Pre-existing Baseline
| Count | Gate | Note |
|-------|------|------|
| 0 | Tests | no pre-existing failures fingerprinted before implementation |

## Commands run (evidence)
- ./vendor/bin/pest --parallel --processes=4  -> 1200 passed
- npx vitest run                              -> 300 passed
- npx tsc --noEmit                            -> exit 0
- npm run lint                                -> 0 warnings
- npm run build                               -> ok

## Security audit
composer audit: no advisories across 100 packages. npm audit: 0 critical, 2 moderate
(advisory only, continue-on-error in CI per project policy). No secrets committed; .env*
files excluded from the diff. CSRF + rate-limit middleware unchanged on the auth routes.

## Performance & eager-loading
Every model method that touches a relationship is guarded by ->load()/->loadMissing()
before access (lazy loading is globally disabled in dev/test and would otherwise throw).
Query counts asserted in tests; no unbounded queries introduced; Cashier methods receive
pre-loaded subscriptions. No N+1 across the changed controllers or jobs.

## Summary
All gates pass. No blocking issues, no session-introduced regressions, no pre-existing
baseline drift. Safe to proceed to adversarial review and verify-done.
EOF
}
plant_agent_review(){
  local repo="$1" sid="$2"
  cat > "$repo/AGENT_REVIEW_${sid}.md" <<EOF
Model: haiku

## Agent Review — ${sid}

- Status: completed
- Agents directory: ~/.claude/agents
- Agents dispatched: codex-adversarial-reviewer
- Codex adversarial reviewer: codex-adversarial-reviewer dispatched (4 candidates, 4 accepted, 0 rejected)
- Reviewer model: haiku
- Hostile adversarial focus: no
- Dispatch mode: subagent
- Review evidence: codex_candidates: 4, findings: 0
- Remediation: no findings

## Findings

No issues found.

## Summary
critical:0 high:0 medium:0 low:0

Overall: APPROVED
EOF
}
plant_verify_done(){
  local repo="$1" sid="$2"
  # ND-0716: fixture upgraded to the W53 structural contract (Mode:/Changed:/## Summary) —
  # the Stop hook now actively validates it (VERIFY_DONE_MALFORMED gate), so a "valid
  # artifact" fixture must carry the fields a real /v-verify-done report carries.
  cat > "$repo/VERIFY_DONE_REPORT_${sid}.md" <<EOF
Model: haiku
SID: ${sid}
Mode: full
Changed: 1

Status: completed

## Checks

No findings. Naming, imports, route middleware, and factory conventions all verified
clean against the session's changed files (fixture body sized past the attest
script's 200-byte placeholder floor).

## Summary
critical:0 high:0 medium:0 low:0

Overall Verdict: PASS
EOF
}
plant_impact_map(){
  local repo="$1" sid="$2"
  cat > "$repo/IMPACT_MAP_${sid}.md" <<EOF
# Impact Map — ${sid}

subsystems:
  functional_flow: impacted=no, reason=ui-only change
  reporting_metrics: impacted=no, reason=no metric writers touched
  admin: impacted=no, reason=admin views not touched
  async_jobs: impacted=no, reason=no jobs touched
  notification_emails: impacted=no, reason=no email senders touched
  cache_invalidation: impacted=no, reason=no cache keys touched
  db_integrity: impacted=no, reason=no migrations
  api_contract: impacted=no, reason=no api routes changed
  authorization: impacted=no, reason=no policy changes
EOF
}
plant_qa_report(){
  local repo="$1" sid="$2"
  cat > "$repo/QA_REPORT_${sid}.md" <<EOF
Model: haiku

verdict: pass

## QA Acceptance

acceptance: full
iterations: 0
findings: []

## Detail

All gates pass for session ${sid}; no remediation required. Autonomous QA loop converged on first iteration.
EOF
}
plant_handoff(){
  local repo="$1" sid="$2"
  cat > "$repo/HANDOFF_${sid}.md" <<EOF
# Handoff for session ${sid}

Status: deferred
Reason: Out of context, escalating to fresh session.

## Next steps
1. Read this handoff
2. Resume from where prior session left off

(Pad to >80 bytes with this filler text so the size guard accepts it.)
EOF
}

# Plant writes-log entries (track-session-writes.sh would normally write these).
# git rev-parse --git-common-dir returns ".git" (relative) from a main checkout,
# which is only valid from inside the repo. Resolve to absolute so the file lands
# where the hook will look for it (the hook resolves relative-to-its-own-cwd).
plant_writes_log(){
  local repo="$1" sid="$2"; shift 2
  local git_dir; git_dir=$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null)
  [ -n "$git_dir" ] || return
  case "$git_dir" in
    /*) ;;
    *)  git_dir="$repo/$git_dir" ;;
  esac
  git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P)
  [ -d "$git_dir" ] || return
  local logf="$git_dir/claude-session-writes-${sid}.txt"
  : > "$logf"
  for path in "$@"; do
    printf '%s\n' "$path" >> "$logf"
  done
}

# Plant /v invocation history (history.jsonl) so IS_V_INVOCATION_VIA_HISTORY=1.
plant_v_history(){
  local sid="$1"
  local hf="$HOME/.claude/history.jsonl"
  printf '{"sessionId":"%s","display":"/v fix the bug"}\n' "$sid" >> "$hf"
}

# Plant a head-baseline so the Stop hook's commits-since-baseline check has data.
plant_head_baseline(){
  local repo="$1" sid="$2"; local baseline_sha="$3"
  local vt="$repo/.v/tmp"
  mkdir -p "$vt"
  printf '%s\n' "$baseline_sha" > "$vt/head-baseline-${sid}.txt"
}

# Plant a HAND-FORGED (v1-shape) witness: no HMAC, no content hashes — exactly what
# a model could author in one Write call. Used by negative tests; the hardened hook
# MUST reject it once it reaches the HMAC/content-hash checks.
plant_witness(){
  local sid="$1" pre="$2" rev="$3" ver="$4" ts="$5"; local nonce="${6:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  local witness="$HOME/.claude/runtime/v-gauntlet-attestation-${sid}.json"
  cat > "$witness" <<EOF
{"skill":"v","check":"gauntlet-attest","sid":"${sid}","nonce":"${nonce}","ts":${ts},"pid":1234,"pre_flight":"${pre}","agent_review":"${rev}","verify_done":"${ver}"}
EOF
}

# Produce a REAL witness by running the actual attest script against planted
# artifacts — the genuine happy path (tests/WG-1, WG-2: the prior harness planted a
# dummy-nonce witness AS the happy path, which masked the forgeability bug).
attest_witness(){
  local repo="$1" sid="$2"
  ( cd "$repo" && PROJECT_ROOT="$repo" CLAUDE_SESSION_ID="$sid" HOME="$HOME" bash "$ATTEST" "$sid" ) >/dev/null 2>&1
}

# Run the Stop hook with synthetic stdin + appropriate env.
run_stop_hook(){
  local repo="$1" sid="$2"; local last_msg="${3:-Implementation complete. All tests pass. Done.}"
  local stdin_json
  stdin_json=$(jq -nc --arg sid "$sid" --arg msg "$last_msg" '{
    session_id: $sid, last_assistant_message: $msg, stop_hook_active: false
  }')
  ( cd "$repo" && env -i HOME="$HOME" PATH="$PATH" HOOKS_LIB_DIR="$HOOKS_LIB_DIR" CLAUDE_PROJECT_DIR="$repo" \
    bash "$HOOK" <<<"$stdin_json" )
}

# ─────────────────────────────────────────────────────────────────────────────
# Group D — Stop hook witness enforcement (B3)
# ─────────────────────────────────────────────────────────────────────────────

# Helper: full happy-path setup minus the witness.
setup_full_artifacts(){
  local repo="$1" sid="$2"
  plant_pre_flight   "$repo" "$sid"
  plant_agent_review "$repo" "$sid"
  plant_verify_done  "$repo" "$sid"
  plant_impact_map   "$repo" "$sid"
  plant_qa_report    "$repo" "$sid"
  plant_writes_log   "$repo" "$sid" "src/foo.ts"  # code change → CODE_CHANGED=1
  # Plant codex + QA DISPATCH_PROVENANCE so the AGENT_REVIEW (C3b) and QA independence gates resolve
  # 'dispatched'. The harness runs the Stop hook in an isolated HOME with NO transcript, so provenance
  # is the ONLY evidence the independence gate can read; without it a 'dispatched' claim is 'silent' →
  # BLOCK on review/QA BEFORE the witness gate this harness is actually about (forensic AGENT_REVIEW_859).
  printf 'DISPATCH|ts=2026-06-16T00:00:00Z|agent=codex-adversarial-reviewer|mode=foreground|status=ok|artifact=AGENT_REVIEW_%s.md\n' "$sid" >> "$repo/DISPATCH_PROVENANCE_${sid}.log"
  printf 'DISPATCH|ts=2026-06-16T00:00:00Z|agent=v-qa-reviewer|mode=self-write|status=ok|artifact=QA_REPORT_%s.md\n' "$sid" >> "$repo/DISPATCH_PROVENANCE_${sid}.log"
  plant_v_history    "$sid"
}

echo "=== D1: full artifacts + REAL attest witness (HMAC+content-hash) -> PASS (exit 0) ==="
new_repo r_d1; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
attest_witness "$R" "$SID_A"   # genuine signed witness, not a hand-written stub
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "happy path: all artifacts + REAL attest-produced witness -> exit 0" \
  || no "D1 (rc=$RC stderr=[$(echo "$ERR" | head -3 | tr '\n' '|')])"

echo "=== D2: full artifacts + NO witness -> BLOCK exit 2 with 'gauntlet-attestation' message ==="
new_repo r_d2; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
# DO NOT plant witness
rm -f "$HOME/.claude/runtime/v-gauntlet-attestation-${SID_A}.json"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] \
  && echo "$ERR" | grep -qi 'gauntlet-attestation' \
  && echo "$ERR" | grep -q 'v-gauntlet-attest.sh'; } \
  && ok "missing witness -> exit 2 + message names attest script" \
  || no "D2 (rc=$RC msg snippet: $(echo "$ERR" | grep -i 'gauntlet' | head -1))"

echo "=== D3: full artifacts + STALE witness (>14400s old) -> BLOCK ==="
new_repo r_d3; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
OLD=$(( $(date -u +%s) - 20000 ))
plant_witness "$SID_A" \
  "$R/PRE_FLIGHT_REPORT_${SID_A}.md" \
  "$R/AGENT_REVIEW_${SID_A}.md" \
  "$R/VERIFY_DONE_REPORT_${SID_A}.md" \
  "$OLD"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'STALE'; } \
  && ok "stale witness -> exit 2 + 'STALE' message" \
  || no "D3 (rc=$RC msg: $(echo "$ERR" | grep -i 'stale\|gauntlet' | head -1))"

echo "=== D4: full artifacts + witness with WRONG SID -> BLOCK ==="
new_repo r_d4; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
NOW=$(date -u +%s)
# Witness file is named for SID_A (so the resolver finds it) but its internal sid is SID_B.
cat > "$HOME/.claude/runtime/v-gauntlet-attestation-${SID_A}.json" <<EOF
{"skill":"v","check":"gauntlet-attest","sid":"${SID_B}","nonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ts":${NOW},"pid":1,"pre_flight":"$R/PRE_FLIGHT_REPORT_${SID_A}.md","agent_review":"$R/AGENT_REVIEW_${SID_A}.md","verify_done":"$R/VERIFY_DONE_REPORT_${SID_A}.md"}
EOF
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'SID mismatch'; } \
  && ok "SID-mismatched witness -> exit 2 + 'SID mismatch' message" \
  || no "D4 (rc=$RC msg: $(echo "$ERR" | grep -i 'mismatch\|gauntlet' | head -1))"

echo "=== D5: full artifacts + witness with WRONG artifact bindings -> BLOCK ==="
new_repo r_d5; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
NOW=$(date -u +%s)
plant_witness "$SID_A" \
  "$R/PRE_FLIGHT_REPORT_OTHER.md" \
  "$R/AGENT_REVIEW_OTHER.md" \
  "$R/VERIFY_DONE_REPORT_OTHER.md" \
  "$NOW"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'binding\|different artifact'; } \
  && ok "wrong-binding witness -> exit 2 + binding error" \
  || no "D5 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|binding\|witness' | head -1))"

echo "=== D6: full artifacts + witness with short nonce (forge attempt) -> BLOCK ==="
new_repo r_d6; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
NOW=$(date -u +%s)
cat > "$HOME/.claude/runtime/v-gauntlet-attestation-${SID_A}.json" <<EOF
{"skill":"v","check":"gauntlet-attest","sid":"${SID_A}","nonce":"short","ts":${NOW},"pid":1,"pre_flight":"$R/PRE_FLIGHT_REPORT_${SID_A}.md","agent_review":"$R/AGENT_REVIEW_${SID_A}.md","verify_done":"$R/VERIFY_DONE_REPORT_${SID_A}.md"}
EOF
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'nonce'; } \
  && ok "short-nonce witness -> exit 2 + 'nonce' error" \
  || no "D6 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|nonce' | head -1))"

echo "=== D7: NO code change + all 3 artifacts + no witness -> PASS (gate inactive when CODE_CHANGED=0) ==="
new_repo r_d7; R="$REPLY"
plant_pre_flight "$R" "$SID_A"
plant_agent_review "$R" "$SID_A"
plant_verify_done "$R" "$SID_A"
plant_impact_map "$R" "$SID_A"   # IMPACT_MAP only required when CODE_CHANGED=1
plant_qa_report  "$R" "$SID_A"   # same
plant_v_history "$SID_A"
# No writes log → CODE_CHANGED=0; witness gate doesn't fire.
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "no code change -> witness gate inactive, exit 0" \
  || no "D7 (rc=$RC stderr=[$(echo "$ERR" | head -3 | tr '\n' '|')])"

echo "=== D8: IMPLEMENTATION_ONLY + TRUSTED headless attestation + code change + no witness -> PASS (exempt) ==="
# Uses SID_B so the attestation created here does not leak into the SID_A tests.
new_repo r_d8; R="$REPLY"
setup_full_artifacts "$R" "$SID_B"
cat > "$R/IMPLEMENTATION_REPORT_${SID_B}.md" <<EOF
# Implementation Report — ${SID_B}

## Findings: none
## Files changed: src/foo.ts
## Lightweight checks: tsc clean, lint clean
EOF
rm -f "$HOME/.claude/runtime/v-gauntlet-attestation-${SID_B}.json"
# A real runner establishes a trusted-headless attestation; create it the SAME way
# (same scrubbed env the hook runs under, so the HMAC key matches) — D2 / bypass/WG-5.
( env -i HOME="$HOME" PATH="$PATH" bash -c '. "$HOME/.claude/hooks/lib/headless-detect.sh"; _headless_create_attestation "'"$SID_B"'"' ) >/dev/null 2>&1
stdin_json=$(jq -nc --arg sid "$SID_B" '{session_id: $sid, last_assistant_message: "Implementation complete.", stop_hook_active: false}')
ERR=$( cd "$R" && env -i HOME="$HOME" PATH="$PATH" HOOKS_LIB_DIR="$HOOKS_LIB_DIR" CLAUDE_PROJECT_DIR="$R" \
       CLAUDE_HEADLESS=1 CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1 bash "$HOOK" <<<"$stdin_json" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "impl-only + trusted headless attestation -> exempt, exit 0" \
  || no "D8 (rc=$RC stderr=[$(echo "$ERR" | head -3 | tr '\n' '|')])"

echo "=== D9: only PRE_FLIGHT (partial-gauntlet case) — AGENT_REVIEW + VERIFY_DONE missing -> BLOCK ==="
new_repo r_d9; R="$REPLY"
plant_pre_flight "$R" "$SID_A"
# Intentionally NO AGENT_REVIEW, NO VERIFY_DONE.
plant_writes_log "$R" "$SID_A" "src/foo.tsx"
plant_v_history "$SID_A"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] \
  && echo "$ERR" | grep -q 'AGENT_REVIEW not found' \
  && echo "$ERR" | grep -q 'VERIFY_DONE_REPORT not found'; } \
  && ok "partial gauntlet (only PRE_FLIGHT) -> exit 2 names missing AGENT_REVIEW + VERIFY_DONE" \
  || no "D9 (rc=$RC stderr=[$(echo "$ERR" | grep -i 'not found' | head -3 | tr '\n' '|')])"

echo "=== D10: HAND-FORGED witness (valid sid/nonce/binding, NO HMAC) -> BLOCK (bypass/WG-1 regression) ==="
# The headline regression: a model writes a structurally-valid witness in one Write
# call (correct SID, 32-char nonce, fresh ts, correct artifact basenames) WITHOUT
# running attest. Pre-hardening this passed (exit 0 = ship with no gauntlet). Now the
# missing HMAC/content-hash fields must cause a block.
new_repo r_d10; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
NOW=$(date -u +%s)
plant_witness "$SID_A" \
  "$R/PRE_FLIGHT_REPORT_${SID_A}.md" \
  "$R/AGENT_REVIEW_${SID_A}.md" \
  "$R/VERIFY_DONE_REPORT_${SID_A}.md" \
  "$NOW"   # default 32-'a' nonce, v1 shape (no hmac/hashes)
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qiE 'HMAC|content-hash|forged'; } \
  && ok "hand-forged v1 witness -> exit 2 (HMAC/content-hash binding rejects it)" \
  || no "D10 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|hmac\|forged\|witness' | head -1))"

echo "=== D11: REAL witness then an artifact is MODIFIED after attest -> BLOCK (content-hash) ==="
new_repo r_d11; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
attest_witness "$R" "$SID_A"
# Tamper with an artifact AFTER attestation — content hash no longer matches.
printf '\n## sneaky post-attest edit\n' >> "$R/AGENT_REVIEW_${SID_A}.md"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'content hashes do NOT match'; } \
  && ok "post-attest artifact edit -> exit 2 (content-hash binding)" \
  || no "D11 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|hash\|witness' | head -1))"

echo "=== D12: REAL witness with TAMPERED hmac field -> BLOCK (invalid HMAC) ==="
new_repo r_d12; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
attest_witness "$R" "$SID_A"
WF="$HOME/.claude/runtime/v-gauntlet-attestation-${SID_A}.json"
# Flip the hmac to a wrong-but-well-formed value.
jq '.hmac = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$WF" > "$WF.tmp" && mv "$WF.tmp" "$WF"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'HMAC is INVALID'; } \
  && ok "tampered HMAC -> exit 2 (HMAC verification)" \
  || no "D12 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|hmac\|witness' | head -1))"

echo "=== D13: witness with FUTURE timestamp -> BLOCK (negative-age guard) ==="
new_repo r_d13; R="$REPLY"
setup_full_artifacts "$R" "$SID_A"
FUTURE=$(( $(date -u +%s) + 9000 ))
plant_witness "$SID_A" \
  "$R/PRE_FLIGHT_REPORT_${SID_A}.md" \
  "$R/AGENT_REVIEW_${SID_A}.md" \
  "$R/VERIFY_DONE_REPORT_${SID_A}.md" \
  "$FUTURE"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'FUTURE'; } \
  && ok "future-ts witness -> exit 2 (negative-age guard)" \
  || no "D13 (rc=$RC msg: $(echo "$ERR" | grep -i 'gauntlet\|future\|witness' | head -1))"

echo "=== D14: IMPLEMENTATION_ONLY env var WITHOUT trusted attestation (self-declare forge) -> BLOCK (bypass/WG-5) ==="
# A model persists CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1 (e.g. into settings.json)
# but there is no CLAUDE_HEADLESS marker and no HMAC attestation → untrusted. The
# exemption must be ignored and the session must run the full gauntlet. Uses SID_C
# (no attestation anywhere) to prove the var alone grants nothing.
new_repo r_d14; R="$REPLY"
cat > "$R/IMPLEMENTATION_REPORT_${SID_C}.md" <<EOF
# Implementation Report — ${SID_C}
## Findings: none
## Files changed: src/foo.ts
## Lightweight checks: tsc clean
EOF
plant_writes_log "$R" "$SID_C" "src/foo.ts"
plant_v_history "$SID_C"
rm -f "$HOME/.claude/attestations/${SID_C}.json" 2>/dev/null
stdin_json=$(jq -nc --arg sid "$SID_C" '{session_id: $sid, last_assistant_message: "Implementation complete.", stop_hook_active: false}')
ERR=$( cd "$R" && env -i HOME="$HOME" PATH="$PATH" HOOKS_LIB_DIR="$HOOKS_LIB_DIR" CLAUDE_PROJECT_DIR="$R" \
       CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1 bash "$HOOK" <<<"$stdin_json" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ]; } \
  && ok "untrusted impl-only self-declare -> ignored, full gauntlet required (exit 2)" \
  || no "D14 (rc=$RC stderr=[$(echo "$ERR" | head -3 | tr '\n' '|')])"

# ─────────────────────────────────────────────────────────────────────────────
# Group E — HANDOFF abandonment-escape tightening (B4)
# ─────────────────────────────────────────────────────────────────────────────

echo "=== E1: HANDOFF + writes log has code change -> BLOCK (Bug 6 / Phase 2) ==="
new_repo r_e1; R="$REPLY"
plant_handoff "$R" "$SID_A"
plant_writes_log "$R" "$SID_A" "resources/js/Pages/Foo.tsx"
plant_v_history "$SID_A"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'SHIPPED code' && echo "$ERR" | grep -q 'Bug 6'; } \
  && ok "HANDOFF + shipped code -> exit 2 + 'SHIPPED code' Bug 6 message" \
  || no "E1 (rc=$RC msg: $(echo "$ERR" | head -3 | tr '\n' '|'))"

echo "=== E2: HANDOFF + writes log has NO code (only docs) -> PASS (genuine abandonment) ==="
new_repo r_e2; R="$REPLY"
plant_handoff "$R" "$SID_A"
plant_writes_log "$R" "$SID_A" "README.md" "docs/foo.md"  # no source files
plant_v_history "$SID_A"
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "HANDOFF + docs-only changes -> exit 0 (legitimate abandonment escape)" \
  || no "E2 (rc=$RC msg: $(echo "$ERR" | head -3 | tr '\n' '|'))"

echo "=== E3: HANDOFF + commits since baseline contain code -> BLOCK ==="
new_repo r_e3; R="$REPLY"
plant_handoff "$R" "$SID_A"
plant_v_history "$SID_A"
# Capture baseline THEN make a code commit so HEAD differs from baseline.
BASELINE=$(cd "$R" && git rev-parse HEAD)
plant_head_baseline "$R" "$SID_A" "$BASELINE"
( cd "$R" && mkdir -p src && echo 'export const x = 1;' > src/foo.ts && git add -A && git commit -qm 'add code' )
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -qi 'SHIPPED code'; } \
  && ok "HANDOFF + committed code since baseline -> exit 2 + 'SHIPPED code'" \
  || no "E3 (rc=$RC msg: $(echo "$ERR" | head -3 | tr '\n' '|'))"

echo "=== E4: HANDOFF + no writes log + clean head -> PASS (true abandonment) ==="
new_repo r_e4; R="$REPLY"
plant_handoff "$R" "$SID_A"
plant_v_history "$SID_A"
# No writes log, no baseline divergence.
ERR=$( run_stop_hook "$R" "$SID_A" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "HANDOFF + no work done -> exit 0 (true abandonment, escape works)" \
  || no "E4 (rc=$RC msg: $(echo "$ERR" | head -3 | tr '\n' '|'))"

echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ]
