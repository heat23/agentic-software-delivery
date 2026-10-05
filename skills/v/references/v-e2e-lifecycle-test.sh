#!/usr/bin/env bash
# v-e2e-lifecycle-test.sh — END-TO-END lifecycle harness for the /v orchestrator (multi-scenario).
#
# WHY THIS EXISTS (audit 2026-06-18, Phase 2 — the biggest missing test layer):
# Every other harness drives ONE real script against SYNTHETIC fixtures; none runs the real scripts
# in SEQUENCE so step N's REAL output becomes step N+1's REAL input. That seam — "does the Stop hook
# evaluate the SAME end-state a real merge-back just produced?" — is exactly where the documented
# prod escapes live (an observed silent-wipe; Stop-hook-sees-different-state). The backtest proved a 0%
# PROACTIVE catch rate precisely because cross-step integration is untested. This runs whole SESSION
# LIFECYCLES against throwaway repos + a temp HOME, driving the REAL v-merge-back.sh and the REAL
# check-review-artifact.sh Stop hook, asserting cross-step invariants.
#
# Scenarios (each hermetic — own repo + SID):
#   A  survival + stop-gate : worktree merge-back keeps a sibling's WIP, lands the change, then the
#                             Stop hook BLOCKS the finished code session (no review) and ALLOWS it
#                             once a valid TRIVIAL_PASS exists.
#   B  FND-3 defer prevention: merge-back DEFERS (exit 3, nothing stashed, foreign WIP untouched,
#                             worktree NOT merged) when an ACTIVE sibling holds WIP on main.
#   C  survival gate         : the REAL Stop hook BLOCKS a session that claims a source write but left
#                             no trace ("existence != survival"); no false positive when the
#                             session's real work survives.
#   D  (reserved — independence-gate BLOCK; recipe verified, deferred)
#   E  gauntlet witness/HMAC : full-gauntlet ALLOW via the REAL v-gauntlet-attest.sh witness, then
#                             no-witness / post-attest tamper / forged-HMAC all BLOCK (the real
#                             production accept path + its tamper-evidence, end-to-end).
#
# Deterministic + hermetic: fresh mktemp repos + a temp HOME with the REAL ~/.claude/hooks copied in
# read-only (the Stop hook hardcodes $HOME/.claude/...). Session env unset. Self-skips (SKIP:) when
# git/jq are unavailable. Prints "RESULT: N passed, M failed" for the vitest wrapper. Honors
# V_MERGE_BACK_OVERRIDE (the v-concurrency-test.sh convention) so the mutation-gate can inject a
# pre-fix merge-back mutant and prove the survival assertions actually bite.

set -u
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
fail() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "RESULT: 0 passed, 0 failed"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable";  echo "RESULT: 0 passed, 0 failed"; exit 0; }

CLAUDE_SRC="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Unified injection (audit 2026-06-18): honor V_MERGE_BACK_OVERRIDE so the mutation-gate can drive
# these lifecycles against a pre-fix merge-back mutant and prove the survival assertions bite.
MB="${V_MERGE_BACK_OVERRIDE:-$CLAUDE_SRC/skills/v/references/v-merge-back.sh}"
HOOK_SRC="$CLAUDE_SRC/hooks"
[ -f "$MB" ] || { echo "SKIP: v-merge-back.sh not found"; echo "RESULT: 0 passed, 0 failed"; exit 0; }
[ -f "$HOOK_SRC/check-review-artifact.sh" ] || { echo "SKIP: stop hook not found"; echo "RESULT: 0 passed, 0 failed"; exit 0; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/v-e2e.XXXXXX")"
trap 'rm -rf "$ROOT" 2>/dev/null' EXIT
export GIT_CONFIG_NOSYSTEM=1

# Hermetic temp HOME with the REAL hooks copied in (the Stop hook hardcodes $HOME/.claude/...).
HOME_T="$ROOT/home"
mkdir -p "$HOME_T/.claude/hooks" "$HOME_T/.claude/runtime" "$HOME_T/.claude/projects/proj"
cp -R "$HOOK_SRC/." "$HOME_T/.claude/hooks/"
: > "$HOME_T/.claude/history.jsonl"

# Phase-2 extension (audit 2026-06-18): the FULL-CHAIN scenarios (F+) drive step scripts that resolve
# their own siblings via $HOME/.claude/skills/... (v-completion-selfcheck.sh shells out to
# v-artifact-dir.sh + v-artifact-consolidate.sh; the session-log gate uses build-skeleton.py +
# validate-log.py). Copy those skill subtrees into the temp HOME so the chain runs hermetically under
# $HOME_T with ZERO reads of the operator's real ~/.claude. Best-effort: a scenario that needs a
# missing script self-skips its assertions rather than failing.
mkdir -p "$HOME_T/.claude/skills/v/references" "$HOME_T/.claude/skills/v-session-log/references"
cp -R "$CLAUDE_SRC/skills/v/references/." "$HOME_T/.claude/skills/v/references/" 2>/dev/null || true
cp -R "$CLAUDE_SRC/skills/v-session-log/references/." "$HOME_T/.claude/skills/v-session-log/references/" 2>/dev/null || true

# new_repo <dir> — fresh git repo with a committed baseline (app.py code + other.py). Echoes BASE sha.
new_repo() {
  local d="$1"; mkdir -p "$d"; ( cd "$d"
    git init -q; git config user.email t@t.local; git config user.name t
    printf 'print("v1")\nx = 1\ny = 2\n' > app.py
    printf 'other = 1\n'                 > other.py
    git add -A; git commit -qm init
    git rev-parse HEAD )
}

# Run the REAL Stop hook against <repo> for <sid>; returns its exit code, captures combined output
# into the global STOP_OUT (so a caller can attribute a block to a specific gate message).
# MUST run with cwd INSIDE the repo: the hook exits 0 early when `git rev-parse --is-inside-work-tree`
# fails, so an outside-the-repo invocation never reaches the gates.
STOP_OUT=""
run_stop_hook() {
  local repo="$1" sid="$2"
  STOP_OUT="$( cd "$repo" && printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"done"}' "$sid" \
    | env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID -u CLAUDE_HEADLESS -u CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY \
        CLAUDE_SESSION_ID="$sid" V_TMP_DIR="$repo/.v/tmp" HOME="$HOME_T" \
        bash "$HOME_T/.claude/hooks/check-review-artifact.sh" 2>&1 )"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario A — worktree merge-back survival, then the REAL Stop hook on the SAME end-state.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_a() {
  echo "== Scenario A :: worktree -> REAL merge-back (survival) -> REAL Stop hook (block then allow) =="
  local SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"; local SID8="${SID:0:8}"
  local REPO="$ROOT/repoA"; local BASE; BASE="$(new_repo "$REPO")"
  local DEF; DEF="$(git -C "$REPO" symbolic-ref --short HEAD)"

  # Worktree session: branch carries -<sid8> (ownership), commit a code change.
  git -C "$REPO" worktree add -q "$ROOT/wtA" -b "build/feature-${SID8}" HEAD
  printf 'print("v1")\nx = 1\ny = 2\nWT_change = True\n' > "$ROOT/wtA/app.py"
  git -C "$ROOT/wtA" add -A; git -C "$ROOT/wtA" commit -qm "wt app change"
  # Sibling's UNCOMMITTED WIP on main (the silent-wipe bait).
  printf 'other = 1\nFOREIGN_sibling_wip = True\n' > "$REPO/other.py"
  # Session bookkeeping the Stop hook reads. --git-common-dir can be RELATIVE (to $REPO), so resolve
  # it to an absolute path before writing the session-writes log under it.
  local GCD; GCD="$(cd "$REPO" && git rev-parse --git-common-dir)"
  case "$GCD" in /*) ;; *) GCD="$REPO/$GCD" ;; esac
  mkdir -p "$REPO/.v/tmp"
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n'     > "$GCD/claude-session-writes-$SID.txt"
  printf '{"sessionId":"%s","display":"/v fix the thing"}\n' "$SID" >> "$HOME_T/.claude/history.jsonl"

  local out rc
  out="$(CLAUDE_MAIN_BRANCH="$DEF" V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_TMP_DIR="$REPO/.v/tmp" \
    REPO_ROOT="$REPO" HOME="$HOME_T" env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$MB" "$SID" "$ROOT/wtA" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && pass "A/L0 merge-back exits 0 (merged)" || fail "A/L0 merge-back rc=$rc — ${out:0:300}"
  grep -q 'WT_change' "$REPO/app.py" 2>/dev/null \
    && pass "A/L2 worktree change LANDED on main" || fail "A/L2 worktree change missing from main"
  grep -q 'FOREIGN_sibling_wip' "$REPO/other.py" 2>/dev/null \
    && pass "A/L1 sibling WIP SURVIVED merge-back (no silent wipe)" \
    || fail "A/L1 sibling WIP LOST — silent overwrite of a concurrent session's work"

  # Re-assert code-change signals (defensive: merge-back may churn .v/tmp), then drive the Stop hook.
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n'     > "$GCD/claude-session-writes-$SID.txt"
  run_stop_hook "$REPO" "$SID"; rc=$?
  [ "$rc" -eq 2 ] && pass "A/L3 Stop hook BLOCKS finished code session with NO review artifacts (rc=2)" \
    || fail "A/L3 Stop hook did NOT block missing-review session (rc=$rc, expected 2)"

  printf 'start\n' > "$REPO/.v/tmp/v-invocation-start-$SID.txt"; sleep 1
  printf 'TRIVIAL=1\nREASON=one-line documented change\nFILE=app.py\nLINES=1\nTrivial change, no gauntlet required.\n' \
    > "$REPO/TRIVIAL_PASS_$SID.md"
  run_stop_hook "$REPO" "$SID"; rc=$?
  [ "$rc" -eq 0 ] && pass "A/L4 Stop hook ALLOWS once a valid TRIVIAL_PASS is present (rc=0)" \
    || fail "A/L4 Stop hook still blocks with valid TRIVIAL_PASS (rc=$rc, expected 0)"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario B — FND-3 DEFER: merge-back must defer (exit 3), NOT stash-over, when an ACTIVE sibling
# session holds uncommitted WIP on main. The data-loss PREVENTION path (forensic 2026-06-15).
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_b() {
  echo "== Scenario B :: FND-3 — merge-back DEFERS on foreign WIP + active sibling (no stash-over) =="
  local SID="bbbbbbbb-cccc-dddd-eeee-ffffffffffff"; local SID8="${SID:0:8}"
  local SIB="cccccccc-dddd-eeee-ffff-000000000000"
  local REPO="$ROOT/repoB"; new_repo "$REPO" >/dev/null
  local DEF; DEF="$(git -C "$REPO" symbolic-ref --short HEAD)"

  git -C "$REPO" worktree add -q "$ROOT/wtB" -b "build/feature-${SID8}" HEAD
  printf 'print("v1")\nx = 1\ny = 2\nWT_change = True\n' > "$ROOT/wtB/app.py"
  git -C "$ROOT/wtB" add -A; git -C "$ROOT/wtB" commit -qm "wt app change"
  # Foreign sibling's UNCOMMITTED source WIP on main.
  printf 'other = 1\nFOREIGN_sibling_wip = True\n' > "$REPO/other.py"
  # ACTIVE sibling worktree lock (different SID, fresh mtime) — the wave signal v-active-siblings sees.
  mkdir -p "$REPO/.worktrees/sib"
  printf '%s %s %s\n' "$SIB" "$$" "$(date +%s)" > "$REPO/.worktrees/sib/.claude-session-lock"
  # FND3-ORPHAN escape (2026-07-04): defer requires the WIP be write-ledger-claimed by the LIVE
  # sibling — unclaimed WIP is user-owned (UX-FND-4) and auto-stashes through.
  printf 'other.py\n' > "$REPO/.git/claude-session-writes-$SIB.txt"
  mkdir -p "$REPO/.v/tmp"

  local before after rc out
  before="$(git -C "$REPO" stash list 2>/dev/null | wc -l | tr -d ' ')"
  out="$(CLAUDE_MAIN_BRANCH="$DEF" V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_TMP_DIR="$REPO/.v/tmp" \
    REPO_ROOT="$REPO" HOME="$HOME_T" env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$MB" "$SID" "$ROOT/wtB" 2>&1)"; rc=$?
  after="$(git -C "$REPO" stash list 2>/dev/null | wc -l | tr -d ' ')"

  [ "$rc" -eq 3 ] && pass "B/D1 merge-back DEFERS (exit 3) on foreign WIP + active sibling" \
    || fail "B/D1 expected exit 3 (defer), got $rc — ${out:0:300}"
  [ "$before" = "$after" ] && pass "B/D2 nothing stashed — sibling WIP untouched (before=$before after=$after)" \
    || fail "B/D2 a stash was created (before=$before after=$after)"
  { grep -q 'FOREIGN_sibling_wip' "$REPO/other.py" && [ -n "$(git -C "$REPO" status --porcelain other.py)" ]; } \
    && pass "B/D3 foreign WIP left in place + still uncommitted on main" \
    || fail "B/D3 foreign WIP was moved/committed/stashed"
  grep -q 'WT_change' "$REPO/app.py" 2>/dev/null \
    && fail "B/D4 worktree was MERGED despite defer (app.py advanced — silent risk)" \
    || pass "B/D4 worktree NOT merged (deferred cleanly, main unchanged)"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario C — SURVIVAL gate (_survival_verdict): a session that CLAIMS it wrote a source file but
# left no trace (file reverted to baseline, clean tree, no diff, no commit) must be BLOCKED — the
# "existence != survival" data-loss class. This drives the survival GATE behaviorally
# through the REAL Stop hook (the mutation audit's survivor B, but verified end-to-end here).
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_c() {
  echo "== Scenario C :: SURVIVAL gate — wrote source but no trace => REAL Stop hook BLOCKS =="
  local SID="dddddddd-eeee-ffff-0000-111111111111"
  local REPO="$ROOT/repoC"; local BASE; BASE="$(new_repo "$REPO")"
  local GCD; GCD="$(cd "$REPO" && git rev-parse --git-common-dir)"; case "$GCD" in /*) ;; *) GCD="$REPO/$GCD" ;; esac
  mkdir -p "$REPO/.v/tmp"
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n'     > "$GCD/claude-session-writes-$SID.txt"   # writes-log paths MUST be repo-relative
  printf '{"sessionId":"%s","display":"/v fix the thing"}\n' "$SID" >> "$HOME_T/.claude/history.jsonl"
  # A RECOGNIZED gauntlet artifact sets IS_V_SESSION (a real /v session has one) so the LAYER-2 abandonment
  # block (earlier) is skipped and we REACH the survival gate. The session claims app.py but it is unchanged
  # from baseline => LOST. (2026-06-24: was a bare SCRATCH_<sid>.md, which exploited the pre-DEF-2 bare
  # *<sid>*.md glob — exactly the hole DEF-2 closed; an unrecognized .md no longer sets IS_V_SESSION,
  # so reach the gate via a recognized PRE_FLIGHT_REPORT the way a real session does. The assertion is unchanged.)
  printf 'Model: haiku\n# Pre-Flight\nOverall Status: PASS\n' > "$REPO/PRE_FLIGHT_REPORT_$SID.md"

  run_stop_hook "$REPO" "$SID"; local rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'SURVIVAL'; } \
    && pass "C/S1 survival gate BLOCKS a wrote-without-trace session (rc=2 + SURVIVAL message)" \
    || fail "C/S1 survival gate did not block (rc=$rc, SURVIVAL msg=$(printf '%s' "$STOP_OUT" | grep -ci SURVIVAL))"

  # Control: a REAL uncommitted change to app.py => the work survives => the survival gate must NOT fire.
  printf 'print("v1")\nx = 1\ny = 2\nREAL_change = True\n' > "$REPO/app.py"
  run_stop_hook "$REPO" "$SID"
  printf '%s' "$STOP_OUT" | grep -qi 'SURVIVAL' \
    && fail "C/S2 survival gate WRONGLY fired when the session's real work is present" \
    || pass "C/S2 survival gate does NOT fire when real work survives (no false positive)"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario E — GAUNTLET WITNESS / HMAC gate (hooks/check-review-artifact.sh ~L1581,
# hooks/lib/gauntlet-witness.sh). The REAL production accept path: a fully-gated /v code session is
# ALLOWED only when the real v-gauntlet-attest.sh wrote an HMAC + content-hash-bound witness. E2-E4
# prove that binding is load-bearing (no witness / tampered artifact / corrupted HMAC all BLOCK);
# E5-E7 prove the source-tree fields are signed too (deleted / repointed / downgraded all BLOCK);
# E8 proves a post-attestation source edit BLOCKS.
# NON-UI change (app.py) so UX_CRITIQUE/WORKFLOW gates stay inactive; V_SURVIVAL_GATE/V_EXPOSED_GATE
# forced off to drop concurrency-dependent noise. Uses a LOCAL stop-hook invocation (run_stop_hook
# does not forward those two env vars).
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_e() {
  echo "== Scenario E :: GAUNTLET WITNESS / HMAC gate — full-gauntlet ALLOW, then no-witness / tamper / forged-HMAC BLOCK =="
  local SID="eeeeeeee-1111-2222-3333-444444444444"; local SID8="${SID:0:8}"
  local REPO="$ROOT/repoE"; local BASE; BASE="$(new_repo "$REPO")"
  local GCD; GCD="$(cd "$REPO" && git rev-parse --git-common-dir)"; case "$GCD" in /*) ;; *) GCD="$REPO/$GCD" ;; esac
  mkdir -p "$REPO/.v/tmp"

  # sha256 helper (macOS: shasum; Linux: sha256sum).
  local _sha
  if command -v shasum >/dev/null 2>&1; then _sha() { shasum -a 256 "$1" | awk '{print $1}'; }
  elif command -v sha256sum >/dev/null 2>&1; then _sha() { sha256sum "$1" | awk '{print $1}'; }
  else echo "  SKIP E: no shasum/sha256sum"; return 0; fi

  # Session bookkeeping: baseline, code-change writes-log (repo-relative), /v history line.
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n'     > "$GCD/claude-session-writes-$SID.txt"
  printf '{"sessionId":"%s","display":"/v fix the thing"}\n' "$SID" >> "$HOME_T/.claude/history.jsonl"
  # A REAL uncommitted code change so the SURVIVAL invariant (even if re-enabled) sees surviving work
  # and CODE_CHANGED is unambiguous.
  printf 'print("v1")\nx = 1\ny = 2\nE_change = True\n' > "$REPO/app.py"
  # Per-invocation start marker — artifacts written AFTER it satisfy attest's freshness check.
  printf 'start\n' > "$REPO/.v/tmp/v-invocation-start-$SID.txt"
  sleep 1

  # ── Build the five real artifacts ──
  # PRE_FLIGHT_REPORT: Mode: scoped, ## Gates, >=2 rows, Overall Status: PASS, >=1024 bytes.
  {
    printf 'Mode: scoped\nModel: haiku\n\n## Gates\n\n'
    printf '| gate | result |\n| --- | --- |\n'
    printf '| tsc --noEmit | PASS |\n'
    printf '| eslint | PASS |\n'
    printf '| pest (scoped) | PASS |\n'
    printf '| vitest (changed) | PASS |\n'
    printf '\n## Gate detail\n'
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
      printf -- '- detail line %02d: scoped pre-flight gate executed against the session diff (app.py), no regressions, bounded query budget respected, lint clean, types clean.\n' "$_i"
    done
    printf '\nOverall Status: PASS\n'
  } > "$REPO/PRE_FLIGHT_REPORT_$SID.md"

  # AGENT_REVIEW: Model: haiku, Status: APPROVED, 6 fields, evidence marker (findings: 0),
  # Dispatch mode: orchestrator-inline (codex unavailable), superpowers attempt-with-OUTCOME.
  # NB: 'Hostile adversarial focus: no' is load-bearing — 'yes' on an inline dispatch trips the W59-F2
  # hostile-dispatch gate and BLOCKS before the witness gate (the diff is genuinely non-sensitive).
  {
    printf 'Model: haiku\n'
    printf 'Status: APPROVED\n'
    printf 'Session: %s\n\n' "$SID"
    printf '## Findings\n\n'
    printf 'findings: 0\n\n'
    printf 'Agents dispatched: logic-reviewer, security-reviewer (inline, codex CLI unavailable)\n'
    printf 'Codex adversarial reviewer: codex-adversarial-reviewer (orchestrator-inline fallback — codex CLI unavailable on this host)\n'
    printf 'Hostile adversarial focus: no — non-sensitive diff (single print/flag change in app.py; no auth/payment/data paths)\n'
    printf 'Dispatch mode: orchestrator-inline (codex unavailable)\n'
    printf 'Review evidence: findings: 0 — diff is a single non-UI print/flag change in app.py; no auth/payment/data paths touched.\n'
    printf 'Remediation: none required — no CRITICAL/HIGH findings.\n'
    printf 'superpowers:requesting-code-review fallback attempted, returned: skill unavailable\n'
  } > "$REPO/AGENT_REVIEW_$SID.md"

  # VERIFY_DONE_REPORT: Mode: scoped, Changed: 1, ## Summary, Overall Verdict: PASS (no FND-BND).
  {
    printf 'Mode: scoped\nModel: haiku\nChanged: 1\nSession: %s\n\n' "$SID"
    printf '## Summary\n\nSingle-file non-UI change to app.py; conventions hold, no boundary violations.\n\n'
    printf '## Convention Checks\n- naming: ok\n- no TODO/FIXME left\n- no SoftDeletes added\n\n'
    printf 'Overall Verdict: PASS\n'
  } > "$REPO/VERIFY_DONE_REPORT_$SID.md"

  # IMPACT_MAP: >=200 bytes, subsystems + reporting_metrics + cache_invalidation + db_integrity.
  {
    printf '# Impact Map — %s\n\n' "$SID"
    printf 'subsystems:\n'
    printf '  functional_flow: impacted: no — local flag only\n'
    printf '  reporting_metrics: impacted: no — no metrics emitted\n'
    printf '  cache_invalidation: impacted: no — no cache keys touched\n'
    printf '  db_integrity: impacted: no — no schema/data writes\n'
    printf '  async_jobs: impacted: no\n'
    printf '  api_contract: impacted: no\n'
    printf '  authorization: impacted: no\n'
  } > "$REPO/IMPACT_MAP_$SID.md"

  # QA_REPORT: Model: in first 5 lines, ## QA Acceptance, verdict: pass.
  {
    printf 'Model: haiku\nSession: %s\n\n' "$SID"
    printf '## QA Acceptance\n\n'
    printf 'verdict: pass\n\n'
    printf 'Acceptance: the requested non-UI change is present in app.py; exploratory + regression checks clean.\n'
  } > "$REPO/QA_REPORT_$SID.md"

  # DISPATCH_PROVENANCE: status=ok sha256 lines for PRE_FLIGHT (v-pre-flight-runner) + QA (v-qa-reviewer)
  # so their independence resolves 'dispatched' / their tamper-baseline exists.
  local _pf_sha _qa_sha
  _pf_sha="$(_sha "$REPO/PRE_FLIGHT_REPORT_$SID.md")"
  _qa_sha="$(_sha "$REPO/QA_REPORT_$SID.md")"
  {
    printf 'ts=%s|agent=v-pre-flight-runner|mode=subprocess|status=ok|artifact=PRE_FLIGHT_REPORT_%s.md|sha256=%s\n' "$(date -u +%s)" "$SID" "$_pf_sha"
    printf 'ts=%s|agent=v-qa-reviewer|mode=subprocess|status=ok|artifact=QA_REPORT_%s.md|sha256=%s\n' "$(date -u +%s)" "$SID" "$_qa_sha"
  } > "$REPO/DISPATCH_PROVENANCE_$SID.log"

  # ── Local stop-hook runner that forces the two gate modes off (run_stop_hook can't) ──
  _run_stop_e() {
    STOP_OUT="$( cd "$REPO" && printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"done"}' "$SID" \
      | env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID -u CLAUDE_HEADLESS -u CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY \
          CLAUDE_SESSION_ID="$SID" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
          V_SURVIVAL_GATE=off V_EXPOSED_GATE=off \
          bash "$HOME_T/.claude/hooks/check-review-artifact.sh" 2>&1 )"
  }

  # Run the REAL attest script to write the HMAC witness (must be FRESHER than the artifacts).
  local _att_rc
  sleep 1
  CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$REPO" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$CLAUDE_SRC/skills/v/references/v-gauntlet-attest.sh" "$SID" >/dev/null 2>&1
  _att_rc=$?

  # E1 — FULL-GAUNTLET ALLOW.
  local rc
  _run_stop_e; rc=$?
  if [ "$_att_rc" -ne 0 ]; then
    fail "E1 attest did not succeed (rc=$_att_rc) — cannot assert full-gauntlet ALLOW"
  elif [ "$rc" -eq 0 ]; then
    pass "E1 full gauntlet + valid HMAC witness => Stop hook ALLOWS (rc=0)"
  else
    fail "E1 expected ALLOW (rc=0), got rc=$rc — $(printf '%s' "$STOP_OUT" | grep -iE 'BLOCK' | head -2)"
  fi

  # E1-SL — LAYER-4 SESSION-LOG TELEMETRY gate (forensic 2026-06-20: 43 MISSING silent holes).
  # The E1 end-state is a clean ALLOW (full valid gauntlet + HMAC witness) that reaches LAYER-4. Add a
  # commit-witness (= this /v session shipped commits) and assert: a silent hole BLOCKS, ANY telemetry
  # (canonical .yaml, a quarantined .yaml.invalid, or a loud marker) ALLOWS, and a no-commit session is
  # NEVER over-blocked. V_SL_STOP_INTEGRITY=0 disables the integrity SWEEP so each fixture is tested on
  # the path it claims (SREV-003: otherwise the sweep quarantines the minimal .yaml stub to .yaml.invalid
  # and E1-SL-b would silently exercise the .invalid path). Explicit cleanup of ALL session-log residue
  # + the witness leaves E2-E4 byte-identical (SREV-004).
  if [ "$_att_rc" -eq 0 ]; then
    local _cw="$REPO/.v/tmp/commits-$SID.txt"
    _sl_clean() { rm -f "$REPO"/SESSION_LOG_$SID.yaml "$REPO"/SESSION_LOG_$SID.yaml.invalid \
      "$REPO"/SESSION_LOG_FAILED_$SID.md "$REPO"/SESSION_LOG_INVALID_$SID.md "$REPO"/SESSION_LOG_INCOMPLETE_$SID.md 2>/dev/null; }
    export V_SL_STOP_INTEGRITY=0   # isolate LAYER-4 from the sweep so each path is tested as labeled
    _sl_clean
    printf '%s\n' "$BASE" > "$_cw"   # 1 commit witnessed -> this session shipped code
    # (a) commits + NO session-log telemetry: EFF-SLGATE (2026-06-28) makes this WARN by default (the session-log
    #     apparatus is temporary scaffolding the operator is retiring) => ALLOW (rc=0). Under V_SESSION_LOG_GATE=block
    #     it still BLOCKS (rc=2 + session-log message). Assert BOTH modes; restore the default after.
    unset V_SESSION_LOG_GATE
    _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] \
      && pass "E1-SL-a commits + NO session-log => WARN-default ALLOW (rc=0, EFF-SLGATE churn-kill)" \
      || fail "E1-SL-a expected warn-default ALLOW (rc=$rc) — $(printf '%s' "$STOP_OUT" | grep -i block | head -1)"
    export V_SESSION_LOG_GATE=block
    _run_stop_e; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'session-log'; } \
      && pass "E1-SL-a2 + V_SESSION_LOG_GATE=block => BLOCK (rc=2 + session-log message, opt-in enforcement)" \
      || fail "E1-SL-a2 expected BLOCK under =block (rc=$rc) — $(printf '%s' "$STOP_OUT" | grep -i block | head -1)"
    unset V_SESSION_LOG_GATE
    # (b) a canonical SESSION_LOG .yaml satisfies the gate => ALLOW (sweep off => genuinely the .yaml path).
    printf 'schema_version: 2\nsession_id: %s\n' "$SID" > "$REPO/SESSION_LOG_$SID.yaml"
    _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] && [ -f "$REPO/SESSION_LOG_$SID.yaml" ] \
      && pass "E1-SL-b commits + canonical SESSION_LOG.yaml => ALLOW (rc=0, .yaml path)" \
      || fail "E1-SL-b expected ALLOW with canonical .yaml (rc=$rc) — $(printf '%s' "$STOP_OUT" | grep -i block | head -1)"
    _sl_clean
    # (b2) a QUARANTINED .yaml.invalid (a log that failed validation) also satisfies the gate => ALLOW.
    printf 'schema_version: 2\nsession_id: %s\n' "$SID" > "$REPO/SESSION_LOG_$SID.yaml.invalid"
    _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] \
      && pass "E1-SL-b2 commits + quarantined .yaml.invalid => ALLOW (loud-failure telemetry)" \
      || fail "E1-SL-b2 expected ALLOW with .yaml.invalid (rc=$rc)"
    _sl_clean
    # (c) a LOUD failure marker also satisfies the gate => ALLOW (loud failure > silent hole).
    printf '# Session-log finalize FAILED — %s\n' "$SID" > "$REPO/SESSION_LOG_FAILED_$SID.md"
    _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] \
      && pass "E1-SL-c commits + loud FAILED marker => ALLOW (loud failure accepted)" \
      || fail "E1-SL-c expected ALLOW with FAILED marker (rc=$rc)"
    _sl_clean
    # (d) NEGATIVE: no commit-witness => never blocked for a missing log (no over-block of no-code sessions).
    rm -f "$_cw"
    _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] \
      && pass "E1-SL-d no commit-witness => ALLOW even without session-log (no over-block)" \
      || fail "E1-SL-d expected ALLOW for no-commit session (rc=$rc)"
    unset V_SL_STOP_INTEGRITY   # restore sweep for E2-E4
  fi

  # E2 — NO WITNESS => BLOCK. Remove the witness, re-run.
  local _WIT="$HOME_T/.claude/runtime/v-gauntlet-attestation-$SID.json"
  rm -f "$_WIT"
  _run_stop_e; rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'witness'; } \
    && pass "E2 missing witness => BLOCK (rc=2 + witness gate message)" \
    || fail "E2 expected BLOCK on missing witness (rc=$rc)"

  # Re-attest to restore a valid witness for E3 (artifacts unchanged, marker still older).
  sleep 1
  CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$REPO" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$CLAUDE_SRC/skills/v/references/v-gauntlet-attest.sh" "$SID" >/dev/null 2>&1

  # E3 — TAMPER an artifact AFTER attest (append a byte) => content-hash mismatch => BLOCK.
  printf '\n<!-- tamper -->\n' >> "$REPO/VERIFY_DONE_REPORT_$SID.md"
  _run_stop_e; rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'content hashes do NOT match'; } \
    && pass "E3 tampered artifact after attest => BLOCK (rc=2 + content-hash mismatch)" \
    || fail "E3 expected BLOCK on tamper (rc=$rc)"

  # Restore VERIFY_DONE to its attested bytes, re-attest, then corrupt the HMAC field.
  {
    printf 'Mode: scoped\nModel: haiku\nChanged: 1\nSession: %s\n\n' "$SID"
    printf '## Summary\n\nSingle-file non-UI change to app.py; conventions hold, no boundary violations.\n\n'
    printf '## Convention Checks\n- naming: ok\n- no TODO/FIXME left\n- no SoftDeletes added\n\n'
    printf 'Overall Verdict: PASS\n'
  } > "$REPO/VERIFY_DONE_REPORT_$SID.md"
  sleep 1
  CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$REPO" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$CLAUDE_SRC/skills/v/references/v-gauntlet-attest.sh" "$SID" >/dev/null 2>&1

  # E4 — CORRUPT the witness hmac field => HMAC invalid => BLOCK. Flip the hmac to all-zeros (64 hex).
  if command -v jq >/dev/null 2>&1; then
    local _tmpw; _tmpw="$(mktemp)"
    jq '.hmac = "0000000000000000000000000000000000000000000000000000000000000000"' "$_WIT" > "$_tmpw" 2>/dev/null && mv "$_tmpw" "$_WIT"
  fi
  _run_stop_e; rc=$?
  { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'HMAC is INVALID'; } \
    && pass "E4 corrupted witness HMAC => BLOCK (rc=2 + HMAC invalid)" \
    || fail "E4 expected BLOCK on forged HMAC (rc=$rc)"

  # E5-E7 — the source-tree binding is signed (witness format 3). Each case starts from a fresh,
  # valid witness and edits only tree fields. In format 2 these fields sat outside the HMAC, so
  # each edit verified and quietly switched off the post-attest source-edit check.
  # A failed re-attest would leave the previous case's edited witness on disk, and the next case
  # could then pass on that stale edit. So each case runs only after a successful re-attest.
  _reattest_e() {
    local _rc
    sleep 1
    CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$REPO" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
      env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
      bash "$CLAUDE_SRC/skills/v/references/v-gauntlet-attest.sh" "$SID" >/dev/null 2>&1
    _rc=$?
    [ "$_rc" -eq 0 ] || fail "$1 re-attest failed (rc=$_rc), so the case cannot run"
    return "$_rc"
  }
  _edit_wit_e() { local _t; _t="$(mktemp)"; jq "$1" "$_WIT" > "$_t" 2>/dev/null && mv "$_t" "$_WIT"; }
  if command -v jq >/dev/null 2>&1; then
    _reattest_e E5-pre && { _run_stop_e; rc=$?
    [ "$rc" -eq 0 ] \
      && pass "E5-pre fresh witness after E4 => ALLOW (so E5-E7 blocks come from the edit alone)" \
      || fail "E5-pre expected ALLOW on a fresh witness (rc=$rc) — $(printf '%s' "$STOP_OUT" | grep -i block | head -1)"; }

    _reattest_e E5 && { _edit_wit_e 'del(.attested_tree, .attested_session_tree)'
    _run_stop_e; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'HMAC is INVALID'; } \
      && pass "E5 tree hashes deleted from the witness => BLOCK (rc=2 + HMAC invalid)" \
      || fail "E5 expected BLOCK when the tree hashes are deleted (rc=$rc)"; }

    _reattest_e E6 && { _edit_wit_e '.attested_tree_root = "/tmp/some-other-checkout"'
    _run_stop_e; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'HMAC is INVALID'; } \
      && pass "E6 tree root repointed at another checkout => BLOCK (rc=2 + HMAC invalid)" \
      || fail "E6 expected BLOCK when the tree root is repointed (rc=$rc)"; }

    _reattest_e E7 && { _edit_wit_e '.wit_ver = 2 | del(.attested_tree, .attested_session_tree, .attested_tree_root)'
    _run_stop_e; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'predates the signed source-tree binding'; } \
      && pass "E7 downgraded to format 2 with the tree fields stripped => BLOCK (rc=2 + format message)" \
      || fail "E7 expected BLOCK on a format-2 downgrade (rc=$rc)"; }

    # E8 — a valid witness, then the session's own source changes: the signed tree no longer
    # matches, the stale marker is written and the marker gate holds completion.
    _reattest_e E8 && { printf 'E8_post_attest_edit = True\n' >> "$REPO/app.py"
    _run_stop_e; rc=$?
    { [ "$rc" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -q 'GAUNTLET_STALE'; } \
      && pass "E8 session source edited after attestation => BLOCK (rc=2 + GAUNTLET_STALE)" \
      || fail "E8 expected BLOCK on a post-attestation source edit (rc=$rc)"; }
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════════
# PHASE-2 EXTENSION (audit 2026-06-18) — FULL step-script chain, BOTH dispatch modes, the 4 seeded
# prod-incident shapes as proof-carrying scenarios, plus a real session-log validation seam.
#
# WHY THESE EXTEND (do NOT reinvent) A/B/C/E above:
#   A/B/C/E test a merge-back→Stop slice with hand-built artifacts. They do NOT (1) run the WHOLE step
#   chain — bootstrap → active-siblings → pre-flight → review-dispatch → merge-back → completion-
#   selfcheck → Stop hook → session-log validate — so step N's REAL output is step N+1's REAL input
#   end-to-end; (2) exercise BOTH dispatch modes (inline-interactive AND forked
#   CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1); (3) prove the selfcheck↔Stop PARITY contract behaviorally;
#   (4) prove the abandonment-no-provenance independence verdict; (5) close the loop through the real
#   validate-log.py. F/G/H/I add exactly those seams.
#
# ── LLM/DISPATCH BOUNDARY STUB (the ONE thing that is faked) ──────────────────────────────────────
#   _shim_dispatch is the deterministic stand-in for the `claude -p --agent <name>` / `codex exec`
#   model call. It takes the SAME contract surface the real v-dispatch-subagent.sh exposes
#   (--agent/--mode/--artifact) and writes the canned review/QA/pre-flight artifact for that agent —
#   so the ORCHESTRATION around the call (gate sequencing, merge-back, selfcheck, Stop hook, session-
#   log) is REAL while the model output is deterministic and offline. We stub the BOUNDARY, not the
#   gates: every artifact the shim emits is then judged by the REAL validation.sh (via the real Stop
#   hook + the real selfcheck), so a gate regression still bites.
#
# ── RESIDUAL HONESTY (what this harness still does NOT model) ───────────────────────────────────────
#   - Bugs INSIDE the real `claude -p` / `codex exec` transport (arg construction in
#     v-dispatch-subagent.sh, allowedTools derivation, json result parsing, timeout/backgrounding)
#     stay UNMODELED — that surface is covered by its own unit harnesses; here it is replaced by the
#     boundary shim by design.
#   - N>2 concurrent racing sessions remain out of scope for this phase (A/B exercise a single active
#     sibling; true multi-process racing lives in v-concurrency-test.sh).
#   - The shim emits VALID artifacts by default; a scenario that needs a malformed/fabricated/forged
#     artifact mutates the shim output explicitly (G/H), so the negative cases are first-class, not
#     accidental.
# ═══════════════════════════════════════════════════════════════════════════════════════════════════

# Merge-back resolver for the full-chain scenarios: prefer the mutation-gate override (so a clobber
# mutant flips F's survival rows red too), else the hermetic temp-HOME copy.
MB_T="${V_MERGE_BACK_OVERRIDE:-$HOME_T/.claude/skills/v/references/v-merge-back.sh}"
SELFCHECK_T="$HOME_T/.claude/skills/v/references/v-completion-selfcheck.sh"
BOOTSTRAP_T="$HOME_T/.claude/skills/v/references/v-bootstrap-wrapper.sh"
SIBLINGS_T="$HOME_T/.claude/skills/v/references/v-active-siblings.sh"
ATTEST_T="$HOME_T/.claude/skills/v/references/v-gauntlet-attest.sh"
BUILD_SKEL="$HOME_T/.claude/skills/v-session-log/references/build-skeleton.py"
VALIDATE_LOG="$HOME_T/.claude/skills/v-session-log/references/validate-log.py"

# sha256 helper (macOS: shasum; Linux: sha256sum). Echoes empty if neither exists (callers guard).
_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  fi
}

# Epoch -> UTC ISO8601 (portable: BSD `date -r`, GNU `date -d @`).
_iso_utc() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# Build a schema-valid session-log facts.kv for <repo>/<sid> at <facts_path>. CRITICAL: derive
# start_time/end_time from the ACTUAL HEAD commit time (+a small window) so validate-log.py's TF5
# "impossible end_sha" check (end_sha must be committed BEFORE session.end_time) passes — a hardcoded
# wall-clock would falsely trip TF5 because the scratch repo commits at run-time "now". Token total is
# deliberately NON-round (the F5 round-number advisory is non-blocking, but keep it clean).
_write_sessionlog_facts() {
  local repo="$1" sid="$2" facts="$3"
  local def end ct start_iso end_iso base
  def="$(git -C "$repo" symbolic-ref --short HEAD)"
  end="$(git -C "$repo" rev-parse HEAD)"
  base="$(git -C "$repo" rev-parse HEAD~1 2>/dev/null || echo "$end")"
  ct="$(git -C "$repo" show -s --format=%ct HEAD)"
  start_iso="$(_iso_utc $((ct-605)))"; end_iso="$(_iso_utc $((ct+5)))"
  {
    printf 'session_id=%s\nproject_root=%s\nproject_name=%s\nbranch_at_end=%s\n' "$sid" "$repo" "$(basename "$repo")" "$def"
    # commit_attribution_method: these scenarios seed a real .git/claude-session-writes-<sid> log, so the
    # production gather resolves session_writes_log. Threading it keeps the hand-built facts realistic —
    # without it build-skeleton defaults method='unknown' and the P0 over-claim guard (2026-06-22) blocks
    # a commits_added>0 log, which is correct behaviour for an un-attributed claim, not a valid fixture.
    printf 'end_sha=%s\nbase_sha=%s\nbase_sha_source=head_baseline_file\ncommits_added=1\ncommit_attribution_method=session_writes_log\n' "$end" "$base"
    printf 'start_time=%s\nend_time=%s\nduration_seconds=605\n' "$start_iso" "$end_iso"
    printf 'token_total=51234\ntoken_cache_read=204816\ntoken_by_model={"sonnet": 41234, "haiku": 10000}\n'
  } > "$facts"
}

# ── _shim_dispatch <agent> <artifact_path> <sid> [verdict] ─────────────────────────────────────────
# THE LLM/DISPATCH BOUNDARY STUB. Deterministically writes the canned artifact a real
# `claude -p --agent <agent>` capture/self-write dispatch would have produced. <verdict> defaults to
# PASS/pass/APPROVED; pass "fail"/"FAIL" to emit a gate-failing artifact (planted-failure scenarios).
# Emits the same DISPATCH_PROVENANCE_<sid>.log line the real helper records (mode=subprocess|status=ok)
# UNLESS <agent>=__no_provenance__ is requested by the caller appending a 5th arg "noprov".
_shim_dispatch() {
  local agent="$1" art="$2" sid="$3" verdict="${4:-pass}" prov="${5:-prov}"
  case "$agent" in
    v-pre-flight-runner)
      local _ov="PASS"; [ "$verdict" = "fail" ] && _ov="FAIL"
      {
        printf 'Mode: scoped\nModel: haiku\n\n## Gates\n\n'
        printf '| gate | result |\n| --- | --- |\n'
        printf '| tsc --noEmit | %s |\n' "$_ov"
        printf '| eslint | PASS |\n| pest (scoped) | PASS |\n| vitest (changed) | PASS |\n'
        printf '\n## Gate detail\n'
        local _i; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
          printf -- '- detail line %02d: scoped pre-flight gate executed against the session diff (app.py); bounded query budget, lint clean, types clean.\n' "$_i"
        done
        printf '\nOverall Status: %s\n' "$_ov"
      } > "$art" ;;
    v-verify-done-runner)
      local _ov="PASS"; [ "$verdict" = "fail" ] && _ov="FAIL"
      {
        printf 'Mode: scoped\nModel: haiku\nChanged: 1\nSession: %s\n\n' "$sid"
        printf '## Summary\n\nSingle-file non-UI change to app.py; conventions hold, no boundary violations.\n\n'
        printf '## Convention Checks\n- naming: ok\n- no TODO/FIXME left\n- no SoftDeletes added\n\n'
        printf 'Overall Verdict: %s\n' "$_ov"
      } > "$art" ;;
    v-qa-reviewer)
      local _v="pass"; [ "$verdict" = "fail" ] && _v="fail"
      {
        printf 'Model: haiku\nSession: %s\n\n## QA Acceptance\n\n' "$sid"
        printf 'verdict: %s\n\n' "$_v"
        printf 'Acceptance: the requested non-UI change is present in app.py; exploratory + regression checks clean.\n'
      } > "$art" ;;
    codex|codex-adversarial-reviewer|agent-review)
      # AGENT_REVIEW artifact. prov=noprov => emit the "dispatched inline via Agent tool, NO provenance"
      # shape (incident #4): a hostile-focus claim with NO DISPATCH_PROVENANCE line written.
      {
        printf 'Model: haiku\nStatus: APPROVED\nSession: %s\n\n' "$sid"
        printf '## Findings\n\nfindings: 0\n\n'
        printf 'Agents dispatched: logic-reviewer, security-reviewer (inline, codex CLI unavailable)\n'
        printf 'Codex adversarial reviewer: codex-adversarial-reviewer (orchestrator-inline fallback — codex CLI unavailable on this host)\n'
        printf 'Hostile adversarial focus: no — non-sensitive diff (single print/flag change in app.py; no auth/payment/data paths)\n'
        printf 'Dispatch mode: orchestrator-inline (codex unavailable)\n'
        printf 'Review evidence: findings: 0 — single non-UI print/flag change in app.py; no auth/payment/data paths.\n'
        printf 'Remediation: none required — no CRITICAL/HIGH findings.\n'
        printf 'superpowers:requesting-code-review fallback attempted, returned: skill unavailable\n'
      } > "$art" ;;
    impact-map)
      {
        printf '# Impact Map — %s\n\nsubsystems:\n' "$sid"
        printf '  functional_flow: impacted: no — local flag only\n'
        printf '  reporting_metrics: impacted: no — no metrics emitted\n'
        printf '  cache_invalidation: impacted: no — no cache keys touched\n'
        printf '  db_integrity: impacted: no — no schema/data writes\n'
        printf '  async_jobs: impacted: no\n  api_contract: impacted: no\n  authorization: impacted: no\n'
      } > "$art" ;;
  esac
}

# Write the per-agent DISPATCH_PROVENANCE line (the real helper's status=ok|sha256 record). Skipped
# entirely for the noprov path (incident #4: the reviewer leaves NO provenance trace).
_shim_provenance() {
  local repo="$1" sid="$2" agent="$3" art="$4"
  local _s; _s="$(_sha256 "$art")"
  printf 'ts=%s|agent=%s|mode=subprocess|status=ok|artifact=%s|sha256=%s\n' \
    "$(date -u +%s)" "$agent" "$(basename "$art")" "$_s" >> "$repo/DISPATCH_PROVENANCE_$sid.log"
}

# Build the COMPLETE, valid five-artifact gauntlet set + provenance for <repo>/<sid> via the boundary
# shim, then run the REAL v-gauntlet-attest.sh to bind the HMAC witness. This is the orchestration the
# /v Step-4/5/6 chain performs, with the model call replaced by _shim_dispatch. Echoes attest rc.
_gauntlet_via_shim() {
  local repo="$1" sid="$2" qa_verdict="${3:-pass}" provmode="${4:-prov}"
  _shim_dispatch v-pre-flight-runner  "$repo/PRE_FLIGHT_REPORT_$sid.md" "$sid"
  _shim_dispatch agent-review         "$repo/AGENT_REVIEW_$sid.md"      "$sid" pass "$provmode"
  _shim_dispatch v-verify-done-runner "$repo/VERIFY_DONE_REPORT_$sid.md" "$sid"
  _shim_dispatch impact-map           "$repo/IMPACT_MAP_$sid.md"        "$sid"
  _shim_dispatch v-qa-reviewer        "$repo/QA_REPORT_$sid.md"         "$sid" "$qa_verdict"
  : > "$repo/DISPATCH_PROVENANCE_$sid.log"
  if [ "$provmode" != "noprov" ]; then
    _shim_provenance "$repo" "$sid" v-pre-flight-runner "$repo/PRE_FLIGHT_REPORT_$sid.md"
    _shim_provenance "$repo" "$sid" v-qa-reviewer       "$repo/QA_REPORT_$sid.md"
  fi
  sleep 1
  CLAUDE_SESSION_ID="$sid" PROJECT_ROOT="$repo" V_TMP_DIR="$repo/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
    bash "$ATTEST_T" "$sid" >/dev/null 2>&1
  return $?
}

# Run the REAL completion self-check against <repo>/<sid> under the temp HOME. Captures combined output
# into SELFCHECK_OUT; returns the script's exit code (0 PASS / 1 FAIL / 2 env). FORCES the same two
# concurrency-dependent gate modes off that scenario E does, so F/G stay deterministic.
# Both runners FORWARD $V_VALIDATION_LIB / $V_HOOK_LIB_DIR when set (unset → live paths, zero prod
# behavior change) so the mutation-gate can inject a mutant validation.sh that BOTH the self-check and
# the Stop hook source — the parity/independence guards bite end-to-end here too.
SELFCHECK_OUT=""
run_selfcheck() {
  local repo="$1" sid="$2"
  SELFCHECK_OUT="$( cd "$repo" && env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID \
      CLAUDE_SESSION_ID="$sid" V_TMP_DIR="$repo/.v/tmp" HOME="$HOME_T" \
      V_SURVIVAL_GATE=off V_EXPOSED_GATE=off \
      V_VALIDATION_LIB="${V_VALIDATION_LIB:-}" \
      bash "$SELFCHECK_T" 2>&1 )"
}
# Stop-hook runner with the two gate modes forced off (parity counterpart to run_selfcheck).
run_stop_modes_off() {
  local repo="$1" sid="$2"
  STOP_OUT="$( cd "$repo" && printf '{"session_id":"%s","stop_hook_active":false,"last_assistant_message":"done"}' "$sid" \
    | env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID -u CLAUDE_HEADLESS -u CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY \
        CLAUDE_SESSION_ID="$sid" V_TMP_DIR="$repo/.v/tmp" HOME="$HOME_T" \
        V_SURVIVAL_GATE=off V_EXPOSED_GATE=off \
        V_VALIDATION_LIB="${V_VALIDATION_LIB:-}" V_HOOK_LIB_DIR="${V_HOOK_LIB_DIR:-}" \
        bash "$HOME_T/.claude/hooks/check-review-artifact.sh" 2>&1 )"
}

# Seed the session bookkeeping every chained scenario needs: head-baseline, repo-relative writes-log
# (code change in app.py), a /v history line, a real uncommitted code change, and a fresh per-
# invocation start marker (artifacts written AFTER it pass attest freshness).
_seed_session() {
  local repo="$1" sid="$2" base="$3"
  local gcd; gcd="$(cd "$repo" && git rev-parse --git-common-dir)"; case "$gcd" in /*) ;; *) gcd="$repo/$gcd" ;; esac
  mkdir -p "$repo/.v/tmp"
  printf '%s\n' "$base"  > "$repo/.v/tmp/head-baseline-$sid.txt"
  printf 'app.py\n'      > "$gcd/claude-session-writes-$sid.txt"
  printf '{"sessionId":"%s","display":"/v fix the thing"}\n' "$sid" >> "$HOME_T/.claude/history.jsonl"
  printf 'print("v1")\nx = 1\ny = 2\nCHAIN_change = True\n' > "$repo/app.py"
  printf 'start\n' > "$repo/.v/tmp/v-invocation-start-$sid.txt"
  sleep 1
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario F — FULL STEP-SCRIPT CHAIN in BOTH dispatch modes. Drives the real scripts in sequence:
#   bootstrap (v-bootstrap-wrapper.sh) → active-siblings (v-active-siblings.sh) → pre-flight + review
#   + QA (via the boundary shim) → real attest → completion-selfcheck (v-completion-selfcheck.sh) →
#   real Stop hook (check-review-artifact.sh) → session-log validate (build-skeleton.py →
#   validate-log.py). Asserts WORK SURVIVES, the selfcheck and Stop hook AGREE on ALLOW, and the
#   session-log validates. Run once inline-interactive, once forked
#   (CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1) — the forked runner is the runner-managed path the
#   ecosystem uses, and the cross-step outcome must be identical.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
_scenario_f_one() {
  local mode="$1" SID="$2"
  echo "== Scenario F[$mode] :: full chain bootstrap→siblings→shim-gates→attest→selfcheck→Stop→session-log =="
  local REPO="$ROOT/repoF_$mode"; local BASE; BASE="$(new_repo "$REPO")"
  local DEF; DEF="$(git -C "$REPO" symbolic-ref --short HEAD)"
  local fork_env=()
  [ "$mode" = "forked" ] && fork_env=(CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1)

  # STEP 1 — bootstrap. Must detect the scratch repo as PROJECT_ROOT and emit the key=value contract.
  # The bootstrap resolves the PHYSICAL path (macOS /var -> /private/var), so compare against the
  # repo's physical path, not the mktemp form. Use a LITERAL string match (fgrep), not a regex — the
  # mktemp path contains '.' (and could contain other regex metacharacters via $TMPDIR), which under
  # grep -E would silently mis-match and could make this assertion a false pass/fail.
  local REPO_PHYS; REPO_PHYS="$(cd "$REPO" && pwd -P)"
  local boot rc emitted_root
  boot="$( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID ${fork_env[@]+"${fork_env[@]}"} \
    CLAUDE_SESSION_ID="$SID" HOME="$HOME_T" bash "$BOOTSTRAP_T" 2>&1 )"; rc=$?
  emitted_root="$(printf '%s\n' "$boot" | grep '^PROJECT_ROOT=' | head -1 | cut -d= -f2-)"
  { [ "$rc" -eq 0 ] && { [ "$emitted_root" = "$REPO" ] || [ "$emitted_root" = "$REPO_PHYS" ]; }; } \
    && pass "F[$mode]/1 bootstrap detects scratch repo as PROJECT_ROOT (rc=0)" \
    || fail "F[$mode]/1 bootstrap rc=$rc / PROJECT_ROOT mismatch (got '$emitted_root') — ${boot:0:160}"

  # STEP 2 — active-siblings: a lone session must see NO sibling (empty output).
  local sib; sib="$(bash "$SIBLINGS_T" "$REPO" "$SID" 2>/dev/null)"
  [ -z "$sib" ] && pass "F[$mode]/2 active-siblings reports none for a lone session" \
    || fail "F[$mode]/2 active-siblings wrongly reported a sibling: $sib"

  # STEP 3 — worktree session lands a change; merge-back is the real survival-bearing step.
  _seed_session "$REPO" "$SID" "$BASE"
  git -C "$REPO" worktree add -q "$ROOT/wtF_$mode" -b "build/feature-${SID:0:8}" HEAD
  printf 'print("v1")\nx = 1\ny = 2\nCHAIN_change = True\n' > "$ROOT/wtF_$mode/app.py"
  git -C "$ROOT/wtF_$mode" add -A; git -C "$ROOT/wtF_$mode" commit -qm "wt chain change"
  local mbout; mbout="$( CLAUDE_MAIN_BRANCH="$DEF" V_MERGE_BACK_SKIP_ARTIFACT_GATE=1 V_TMP_DIR="$REPO/.v/tmp" \
    REPO_ROOT="$REPO" HOME="$HOME_T" env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SESSION_ID ${fork_env[@]+"${fork_env[@]}"} \
    bash "$MB_T" "$SID" "$ROOT/wtF_$mode" 2>&1 )"; rc=$?
  { [ "$rc" -eq 0 ] && grep -q 'CHAIN_change' "$REPO/app.py"; } \
    && pass "F[$mode]/3 WORK SURVIVES — merge-back landed the change on main (rc=0)" \
    || fail "F[$mode]/3 work did NOT land (rc=$rc) — ${mbout:0:200}"
  # Re-assert code-change signals merge-back may have churned, then re-seed a surviving uncommitted edit.
  local gcd; gcd="$(cd "$REPO" && git rev-parse --git-common-dir)"; case "$gcd" in /*) ;; *) gcd="$REPO/$gcd" ;; esac
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n'     > "$gcd/claude-session-writes-$SID.txt"
  printf 'print("v1")\nx = 1\ny = 2\nCHAIN_change = True\nE_more = True\n' > "$REPO/app.py"
  printf 'start\n' > "$REPO/.v/tmp/v-invocation-start-$SID.txt"; sleep 1

  # STEP 4/5/6 — the full gauntlet via the boundary shim + real attest.
  local att_rc; _gauntlet_via_shim "$REPO" "$SID" pass prov; att_rc=$?
  [ "$att_rc" -eq 0 ] && pass "F[$mode]/4 attest bound a valid HMAC witness over the shim gauntlet (rc=0)" \
    || fail "F[$mode]/4 attest failed (rc=$att_rc) — cannot assert the ALLOW path"

  # STEP 7 — completion self-check (producer side) must PASS.
  run_selfcheck "$REPO" "$SID"
  printf '%s' "$SELFCHECK_OUT" | grep -q 'V-COMPLETION-SELFCHECK: PASS' \
    && pass "F[$mode]/5 completion self-check PASSES on the full shim gauntlet" \
    || fail "F[$mode]/5 selfcheck did not pass — $(printf '%s' "$SELFCHECK_OUT" | grep -iE 'FAIL|-' | head -3)"

  # STEP 7.5 — LAYER-4: a COMPLETE /v session finalizes its session-log BEFORE the final Stop. This
  # commit-shipping session must therefore carry session-log telemetry, else the LAYER-4 gate correctly
  # BLOCKS it as a silent hole (forensic 2026-06-20: 43 such holes). Drop canonical telemetry
  # (the gate is an existence check; generator-FIDELITY of the log content is asserted separately at /7
  # against a clean clone, per the note below).
  printf 'schema_version: 2\nsession_id: %s\n' "$SID" > "$REPO/SESSION_LOG_$SID.yaml"

  # STEP 8 — real Stop hook (enforcement side) must ALLOW (rc=0) on the SAME end-state.
  run_stop_modes_off "$REPO" "$SID"; rc=$?
  [ "$rc" -eq 0 ] && pass "F[$mode]/6 Stop hook ALLOWS the fully-gated session WITH finalized session-log (rc=0)" \
    || fail "F[$mode]/6 Stop hook BLOCKED a valid session (rc=$rc) — $(printf '%s' "$STOP_OUT" | grep -iE 'BLOCK' | head -2)"

  # STEP 9 — session-log validate: build a valid skeleton from this run's REAL facts, validate it.
  # The log's session record is built from a pristine clone of MAIN (real end_sha/base/branch), NOT
  # the gated REPO — the leftover gauntlet witnesses (commits-<sid>.txt / DISPATCH_PROVENANCE) in REPO
  # are F's PRE-completion artifacts, and the validator's ground-truth cross-check would (correctly)
  # flag a session-log that records them under a generic skeleton's worktree=false/files_changed=[]
  # defaults. That session-log generator-fidelity surface is its OWN test (scenario I + the session-log
  # suites); here we only need the chain's LAST step to close on a valid log. Clone gives a clean
  # object store with the same commits and none of the gauntlet scratch.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null && [ -f "$BUILD_SKEL" ] && [ -f "$VALIDATE_LOG" ]; then
    local clean="$ROOT/sl_clean_$mode"
    git clone -q "$REPO" "$clean" 2>/dev/null
    local facts="$clean/facts-$SID.kv" skel="$clean/SESSION_LOG_$SID.yaml"
    _write_sessionlog_facts "$clean" "$SID" "$facts"
    python3 "$BUILD_SKEL" "$facts" > "$skel" 2>/dev/null
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID python3 "$VALIDATE_LOG" "$skel" >/dev/null 2>&1 \
      && pass "F[$mode]/7 session-log built from REAL run facts VALIDATES (validate-log.py rc=0)" \
      || fail "F[$mode]/7 session-log did NOT validate — $(env -u CLAUDE_SESSION_ID python3 "$VALIDATE_LOG" "$skel" 2>&1 | grep -iE 'VALIDATION FAILED|^  - ' | head -3)"
  else
    pass "F[$mode]/7 session-log validate SKIPPED (python3/PyYAML/scripts unavailable) — non-fatal"
  fi
}
scenario_f() { _scenario_f_one inline   "ffffffff-1111-2222-3333-444444444401"
               echo
               _scenario_f_one forked   "ffffffff-1111-2222-3333-444444444402"; }

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario G — INCIDENT #3: selfcheck ↔ Stop-hook PARITY. The producer-side self-check and the
# enforcement-side Stop hook MUST agree on every artifact set (single-sourced through validation.sh).
# A divergence (selfcheck PASSES what the Stop hook BLOCKS, or vice-versa) is exactly the "lied about
# finishing" class — it must fail LOUD. We assert agreement on THREE planted shapes.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_g() {
  echo "== Scenario G :: INCIDENT #3 — selfcheck↔Stop parity (must AGREE; divergence = loud RED) =="
  # IMPORTANT: each parity sub-case uses a FRESH repo. The self-check CONSOLIDATES artifacts up into
  # MAIN's .v/artifacts (shared with the Stop hook's search), so deleting/tampering a root-level copy
  # in a re-used repo would leave the consolidated copy intact and both gates would still find it —
  # masking the very divergence we test. A fresh repo per case guarantees the planted shape is the
  # ONLY artifact set either gate can see.

  # G1 — VALID full gauntlet: BOTH must accept (selfcheck PASS + Stop ALLOW).
  local SID1="99999999-aaaa-bbbb-cccc-000000000031"
  local R1="$ROOT/repoG1"; local B1; B1="$(new_repo "$R1")"; _seed_session "$R1" "$SID1" "$B1"
  local att_rc; _gauntlet_via_shim "$R1" "$SID1" pass prov; att_rc=$?
  run_selfcheck "$R1" "$SID1"; local sc_ok=1; printf '%s' "$SELFCHECK_OUT" | grep -q 'V-COMPLETION-SELFCHECK: PASS' || sc_ok=0
  run_stop_modes_off "$R1" "$SID1"; local st_rc=$?
  { [ "$att_rc" -eq 0 ] && [ "$sc_ok" -eq 1 ] && [ "$st_rc" -eq 0 ]; } \
    && pass "G1 parity on VALID gauntlet — selfcheck PASS && Stop ALLOW agree" \
    || fail "G1 parity broke on valid gauntlet (att=$att_rc selfcheck_pass=$sc_ok stop_rc=$st_rc)"

  # G2 — MISSING QA_REPORT (never produced): BOTH must reject (selfcheck FAIL + Stop BLOCK). A silent
  # accept on EITHER side while the other rejects IS incident #3. Build the gauntlet WITHOUT QA, do
  # NOT run the consolidating selfcheck before the Stop check on the first pass — assert each gate
  # independently sees the same gap.
  local SID2="99999999-aaaa-bbbb-cccc-000000000032"
  local R2="$ROOT/repoG2"; local B2; B2="$(new_repo "$R2")"; _seed_session "$R2" "$SID2" "$B2"
  _shim_dispatch v-pre-flight-runner  "$R2/PRE_FLIGHT_REPORT_$SID2.md" "$SID2"
  _shim_dispatch agent-review         "$R2/AGENT_REVIEW_$SID2.md"      "$SID2"
  _shim_dispatch v-verify-done-runner "$R2/VERIFY_DONE_REPORT_$SID2.md" "$SID2"
  _shim_dispatch impact-map           "$R2/IMPACT_MAP_$SID2.md"        "$SID2"
  : > "$R2/DISPATCH_PROVENANCE_$SID2.log"
  _shim_provenance "$R2" "$SID2" v-pre-flight-runner "$R2/PRE_FLIGHT_REPORT_$SID2.md"
  sleep 1
  CLAUDE_SESSION_ID="$SID2" PROJECT_ROOT="$R2" V_TMP_DIR="$R2/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID bash "$ATTEST_T" "$SID2" >/dev/null 2>&1
  run_stop_modes_off "$R2" "$SID2"; local st2=$?
  run_selfcheck "$R2" "$SID2"; local sc2=0; printf '%s' "$SELFCHECK_OUT" | grep -q 'V-COMPLETION-SELFCHECK: FAIL' && sc2=1
  { [ "$sc2" -eq 1 ] && [ "$st2" -eq 2 ]; } \
    && pass "G2 parity on MISSING QA_REPORT — selfcheck FAIL && Stop BLOCK agree (no silent-accept split)" \
    || fail "G2 parity DIVERGED on missing QA_REPORT (selfcheck_fail=$sc2 stop_rc=$st2 — must be 1 && 2)"

  # G3 — STRUCTURALLY-BROKEN AGENT_REVIEW (wrong Status: value): BOTH must reject. This is the TRUE
  # parity contract — both gates single-source hooks/lib/validation.sh's validate_review_semantics, so
  # a malformed artifact must fail on BOTH sides identically. (A structural break, unlike a post-attest
  # byte-tamper, is exactly where a producer↔enforcement DIVERGENCE would be the "lied about finishing"
  # bug — selfcheck accepting what Stop blocks.)
  local SID3="99999999-aaaa-bbbb-cccc-000000000033"
  local R3="$ROOT/repoG3"; local B3; B3="$(new_repo "$R3")"; _seed_session "$R3" "$SID3" "$B3"
  _gauntlet_via_shim "$R3" "$SID3" pass prov >/dev/null 2>&1
  # Break AGENT_REVIEW's Status: to an invalid value (validator requires completed/pass/passed).
  sed -i.bak 's/^Status: APPROVED/Status: bogus-not-an-accepted-value/' "$R3/AGENT_REVIEW_$SID3.md" 2>/dev/null \
    || perl -i -pe 's/^Status: APPROVED/Status: bogus-not-an-accepted-value/' "$R3/AGENT_REVIEW_$SID3.md"
  rm -f "$R3/AGENT_REVIEW_$SID3.md.bak"
  run_selfcheck "$R3" "$SID3"; local sc3=0; printf '%s' "$SELFCHECK_OUT" | grep -q 'V-COMPLETION-SELFCHECK: FAIL' && sc3=1
  run_stop_modes_off "$R3" "$SID3"; local st3=$?
  { [ "$sc3" -eq 1 ] && [ "$st3" -eq 2 ]; } \
    && pass "G3 parity on MALFORMED AGENT_REVIEW — selfcheck FAIL && Stop BLOCK agree (single-sourced validator)" \
    || fail "G3 parity DIVERGED on malformed review (selfcheck_fail=$sc3 stop_rc=$st3 — must be 1 && 2)"

  # G4 — STRICT-BACKSTOP asymmetry (documented, NOT a bug): a post-attest byte-tamper that leaves the
  # artifact STRUCTURALLY valid is caught by the Stop hook's HMAC/content-hash witness binding but NOT
  # by the lenient producer-side selfcheck (which intentionally has no witness check — see its header:
  # "this is a PRODUCER-side self-check ... the Stop hook is the strict backstop"). The contract we
  # assert: the Stop hook (the authority) BLOCKS the tamper. A producer-side PASS here is acceptable
  # ONLY because the strict gate independently catches it — that is the asymmetry the whole design
  # depends on, so we pin it.
  local SID4="99999999-aaaa-bbbb-cccc-000000000034"
  local R4="$ROOT/repoG4"; local B4; B4="$(new_repo "$R4")"; _seed_session "$R4" "$SID4" "$B4"
  _gauntlet_via_shim "$R4" "$SID4" pass prov >/dev/null 2>&1
  printf '\n<!-- tamper -->\n' >> "$R4/VERIFY_DONE_REPORT_$SID4.md"
  run_stop_modes_off "$R4" "$SID4"; local st4=$?
  { [ "$st4" -eq 2 ] && printf '%s' "$STOP_OUT" | grep -qi 'content hashes do NOT match'; } \
    && pass "G4 strict backstop — Stop hook BLOCKS a post-attest tamper the lenient selfcheck cannot (content-hash binding)" \
    || fail "G4 Stop hook did NOT catch post-attest tamper (rc=$st4) — the strict enforcement backstop failed"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario H — INCIDENT #4: ABANDONMENT / NO-PROVENANCE. A reviewer "dispatched" inline via the Agent
# tool that leaves NO DISPATCH_PROVENANCE trace must NOT silently pass independence — the Stop hook's
# independence verdict must BLOCK (the "fabricated Dispatch mode: subagent-dispatched"
# laundering class). Negative control: a REAL provenance record => independence resolves 'dispatched'
# and the same gauntlet ALLOWS — proving the gate is not just blocking everything.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_h() {
  echo "== Scenario H :: INCIDENT #4 — abandonment / no-provenance review must NOT pass independence =="
  local SID="88888888-bbbb-cccc-dddd-000000000004"
  local REPO="$ROOT/repoH"; local BASE; BASE="$(new_repo "$REPO")"
  _seed_session "$REPO" "$SID" "$BASE"

  # H1 — NO-PROVENANCE gauntlet: build the full artifact set but write NO DISPATCH_PROVENANCE lines,
  # AND flip the AGENT_REVIEW to claim a self-recorded 'Dispatch mode: subagent-dispatched' with no
  # backing trace (the forged-independence shape). The Stop hook must BLOCK.
  local att_rc; _gauntlet_via_shim "$REPO" "$SID" pass noprov; att_rc=$?
  # Forge the independence claim inside AGENT_REVIEW (an observed failure shape) with no provenance file.
  sed -i.bak 's/^Dispatch mode:.*/Dispatch mode: subagent-dispatched (v-pre-flight-runner)/' "$REPO/AGENT_REVIEW_$SID.md" 2>/dev/null \
    || perl -i -pe 's/^Dispatch mode:.*/Dispatch mode: subagent-dispatched (v-pre-flight-runner)/' "$REPO/AGENT_REVIEW_$SID.md"
  rm -f "$REPO/AGENT_REVIEW_$SID.md.bak" "$REPO/DISPATCH_PROVENANCE_$SID.log"
  # Re-attest over the edited artifact so ONLY the independence/provenance gate (not freshness/HMAC) can block.
  sleep 1
  CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$REPO" V_TMP_DIR="$REPO/.v/tmp" HOME="$HOME_T" \
    env -u CLAUDE_CODE_SESSION_ID -u SESSION_ID bash "$ATTEST_T" "$SID" >/dev/null 2>&1
  run_stop_modes_off "$REPO" "$SID"; local rc=$?
  [ "$rc" -eq 2 ] \
    && pass "H1 forged 'subagent-dispatched' review with NO provenance => Stop hook BLOCKS (rc=2)" \
    || fail "H1 no-provenance forged review SILENTLY PASSED (rc=$rc, expected 2) — independence laundering"

  # H2 — negative control: SAME gauntlet WITH real provenance => Stop hook ALLOWS (rc=0). Proves the
  # block above is the provenance gate biting, not blanket rejection.
  local SID2="88888888-bbbb-cccc-dddd-000000000044"
  local REPO2="$ROOT/repoH2"; local BASE2; BASE2="$(new_repo "$REPO2")"
  _seed_session "$REPO2" "$SID2" "$BASE2"
  _gauntlet_via_shim "$REPO2" "$SID2" pass prov >/dev/null 2>&1
  run_stop_modes_off "$REPO2" "$SID2"; local rc2=$?
  [ "$rc2" -eq 0 ] \
    && pass "H2 negative control — SAME gauntlet WITH real provenance => Stop hook ALLOWS (rc=0)" \
    || fail "H2 provenance-backed gauntlet wrongly BLOCKED (rc=$rc2) — gate over-blocks correct work"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario I — SESSION-LOG validation seam. A valid log (build-skeleton.py from real facts) must
# VALIDATE; a FABRICATED/ABANDONED log must be REFUSED. Closes the chain's last step (validate-log.py)
# with both a positive and a negative case so the validator is proven non-vacuous here too.
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_i() {
  echo "== Scenario I :: session-log validate — valid log PASSES, fabricated/abandoned log REFUSED =="
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null || [ ! -f "$BUILD_SKEL" ] || [ ! -f "$VALIDATE_LOG" ]; then
    pass "I SKIPPED (python3/PyYAML/build-skeleton/validate-log unavailable) — non-fatal"
    return 0
  fi
  local SID="77777777-cccc-dddd-eeee-000000000005"
  local REPO="$ROOT/repoI"; new_repo "$REPO" >/dev/null
  printf 'print("v2")\n' > "$REPO/app.py"; git -C "$REPO" add -A; git -C "$REPO" commit -qm "i change"
  local facts="$ROOT/facts-I.kv" good="$ROOT/SESSION_LOG_GOOD.yaml" bad="$ROOT/SESSION_LOG_BAD.yaml"
  _write_sessionlog_facts "$REPO" "$SID" "$facts"
  python3 "$BUILD_SKEL" "$facts" > "$good" 2>/dev/null

  # I1 — the real-facts log VALIDATES.
  env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID python3 "$VALIDATE_LOG" "$good" >/dev/null 2>&1 \
    && pass "I1 valid session-log (skeleton from real facts) PASSES validate-log.py (rc=0)" \
    || fail "I1 valid log was REFUSED — $(env -u CLAUDE_SESSION_ID python3 "$VALIDATE_LOG" "$good" 2>&1 | grep -iE 'FAIL|error' | head -2)"

  # I2 — FABRICATED end_sha (a hallucinated SHA never committed) must be REFUSED (the W-perf11 /
  #      forensic-2026-06-14 class: project.end_sha must be a real commit in the repo). NB: end_sha is
  #      NESTED under `project:` so it is INDENTED — match `  end_sha:` (leading whitespace), not a
  #      column-0 anchor, or the substitution silently no-ops and the bad log keeps the real SHA.
  sed -E 's/^([[:space:]]+)end_sha:.*/\1end_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "$good" > "$bad" 2>/dev/null \
    || perl -pe 's/^(\s+)end_sha:.*/${1}end_sha: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/' "$good" > "$bad"
  # Sanity: confirm the fabricated SHA actually landed in the bad log (guard against a silent no-op
  # sed making this assertion vacuously "refuse").
  if ! grep -q 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' "$bad"; then
    fail "I2 setup error — end_sha substitution did not apply (the negative case would be vacuous)"
  else
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID python3 "$VALIDATE_LOG" "$bad" >/dev/null 2>&1 \
      && fail "I2 fabricated end_sha log WRONGLY validated — abandonment/fabrication not refused" \
      || pass "I2 fabricated end_sha log is REFUSED by validate-log.py (rc!=0)"
  fi

  # I3 — ABANDONED log: strip a required top-level block (gates_final) — a truncated/abandoned log
  #      must be refused, not silently accepted.
  grep -v '^gates_final:' "$good" | grep -v '^  tsc:' > "$bad" 2>/dev/null || cp "$good" "$bad"
  env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID python3 "$VALIDATE_LOG" "$bad" >/dev/null 2>&1 \
    && fail "I3 abandoned/truncated log (missing gates_final) WRONGLY validated" \
    || pass "I3 abandoned/truncated log (missing required block) is REFUSED (rc!=0)"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────────
# Scenario J — LIVE _survival_verdict direct integration (P3, audit 2026-06-19).
# Unlike Scenario C (which drives _survival_verdict through the Stop hook wrapper), J calls
# _survival_verdict DIRECTLY after sourcing validation.sh so the function-level contract is
# tested in isolation — catches regressions that survive the Stop hook's outer guards.
#
# J1: session that claimed a source write but left no trace → verdict "lost:..."
# J2: session that made a real uncommitted change → verdict "ok"
# J3: session with empty writes log → verdict "skip:..."
# J4: session with no baseline → verdict "skip:no-baseline"
# ─────────────────────────────────────────────────────────────────────────────────────────────────
scenario_j() {
  echo "== Scenario J :: LIVE _survival_verdict direct integration (P3) =="
  local SID="jjjjjjjj-aaaa-bbbb-cccc-dddddddddddd"
  local REPO="$ROOT/repoJ"; local BASE; BASE="$(new_repo "$REPO")"
  local GCD; GCD="$(cd "$REPO" && git rev-parse --git-common-dir)"; case "$GCD" in /*) ;; *) GCD="$REPO/$GCD" ;; esac
  mkdir -p "$REPO/.v/tmp"

  # Source validation.sh helper (V_VALIDATION_LIB honors injection so mutation gate can cover this path)
  local VLIB="${V_VALIDATION_LIB:-$HOME_T/.claude/hooks/lib/validation.sh}"
  if [ ! -f "$VLIB" ]; then
    pass "J SKIPPED (validation.sh not found at $VLIB) — non-fatal"
    return 0
  fi

  # get_session_writes: reads GIT_COMMON_DIR/claude-session-writes-<sid>.txt
  # We set up the writes-log manually below so the function sees our fixture data.

  # J1 — claimed source write, no actual change in tree (silent-wipe class)
  printf '%s\n' "$BASE" > "$REPO/.v/tmp/head-baseline-$SID.txt"
  printf 'app.py\n' > "$GCD/claude-session-writes-${SID}.txt"
  # app.py exists (baseline content) but was NOT modified — no diff vs baseline
  local verdict
  verdict=$( cd "$REPO" && bash -c "
    SID='$SID'; REPO='$REPO'
    . '$VLIB'
    _survival_verdict \"\$SID\" \"\$REPO\"
  " 2>/dev/null ) || true
  if printf '%s' "$verdict" | grep -q '^lost:'; then
    pass "J1 _survival_verdict emits 'lost:' when source claimed but unchanged (silent-wipe class)"
  else
    fail "J1 _survival_verdict should emit 'lost:' (got: ${verdict:-empty})"
  fi

  # J2 — real uncommitted change to claimed file → verdict "ok"
  printf 'print("J change")\n' > "$REPO/app.py"
  verdict=$( cd "$REPO" && bash -c "
    SID='$SID'; REPO='$REPO'
    . '$VLIB'
    _survival_verdict \"\$SID\" \"\$REPO\"
  " 2>/dev/null ) || true
  if [ "$verdict" = "ok" ]; then
    pass "J2 _survival_verdict emits 'ok' when real uncommitted source change present"
  else
    fail "J2 _survival_verdict should emit 'ok' (got: ${verdict:-empty})"
  fi

  # J3 — empty writes log → verdict "skip:empty-writes-log"
  printf '' > "$GCD/claude-session-writes-${SID}.txt"
  verdict=$( cd "$REPO" && bash -c "
    SID='$SID'; REPO='$REPO'
    . '$VLIB'
    _survival_verdict \"\$SID\" \"\$REPO\"
  " 2>/dev/null ) || true
  if printf '%s' "$verdict" | grep -q '^skip:'; then
    pass "J3 _survival_verdict emits 'skip:' on empty writes log (read-only/artifact-only session)"
  else
    fail "J3 _survival_verdict should emit 'skip:' on empty writes log (got: ${verdict:-empty})"
  fi

  # J4 — no baseline file → verdict "skip:no-baseline"
  printf 'app.py\n' > "$GCD/claude-session-writes-${SID}.txt"
  rm -f "$REPO/.v/tmp/head-baseline-$SID.txt"
  verdict=$( cd "$REPO" && bash -c "
    SID='$SID'; REPO='$REPO'
    . '$VLIB'
    _survival_verdict \"\$SID\" \"\$REPO\"
  " 2>/dev/null ) || true
  if printf '%s' "$verdict" | grep -q '^skip:'; then
    pass "J4 _survival_verdict emits 'skip:' when no baseline present (gate inactive, safe direction)"
  else
    fail "J4 _survival_verdict should emit 'skip:' with no baseline (got: ${verdict:-empty})"
  fi
}

scenario_a
echo
scenario_b
echo
scenario_c
echo
scenario_e
echo
scenario_f
echo
scenario_g
echo
scenario_h
echo
scenario_i
echo
scenario_j
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
