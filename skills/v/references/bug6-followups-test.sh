#!/usr/bin/env bash
# bug6-followups-test.sh — regression harness for the 2026-05-28 Opus-4.8 review
# fixes that are NOT covered by bug6-test.sh / bug6-phase2-test.sh.
#
# Groups:
#   F  — settings.json registration (the Stop + precommit gauntlet hooks are wired
#        interactively, not only in settings.headless.json). This is the load-bearing
#        fix: without it, every other defense is dead code in interactive sessions.
#   P  — protect-main-branch.sh quote-strip fix (E3): echo/printf MENTIONING a push
#        no longer false-DENIES, while real pushes to protected branches still DENY.
#   C  — CODE_CHANGED Bash-write blindness (C1): committed code is detected via the
#        always-run head-baseline signal even when the writes log shows no code.
#   M  — per-invocation marker SID resolution (C2): the SKILL.md Step-0 block resolves
#        the SID from the runtime file when $CLAUDE_SESSION_ID is empty, so the marker
#        lands where v-gauntlet-attest.sh / the Stop hook look for it.
#   T  — TRIVIAL_PASS freshness + triviality (C3): a stale or multi-file TRIVIAL_PASS
#        no longer satisfies the gate; a fresh single-file one still does.
#
# Re-run: bash <thisfile>. Self-contained; isolated $HOME for the hook tests.
set -uo pipefail
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ATTEST="$REF_DIR/v-gauntlet-attest.sh"
SKILL_MD="$(cd "$REF_DIR/.." && pwd)/SKILL.md"
REAL_HOME="$HOME"
HOOK="$REAL_HOME/.claude/hooks/check-review-artifact.sh"
PMB="$REAL_HOME/.claude/hooks/protect-main-branch.sh"
SETTINGS="$REAL_HOME/.claude/settings.json"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

BASE=$(mktemp -d /tmp/bug6-fu.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT

# Isolated HOME for the Stop-hook tests (symlink hooks/agents so libs resolve).
FHOME="$BASE/home"; mkdir -p "$FHOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks" "$FHOME/.claude/hooks"
[ -d "$REAL_HOME/.claude/agents" ] && ln -s "$REAL_HOME/.claude/agents" "$FHOME/.claude/agents"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
SID="aaaaaaaa-1111-4111-8111-1111111111ff"

new_repo(){ local R="$BASE/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && echo x>.keep && git add -A && git commit -qm init ) >/dev/null 2>&1; REPLY="$(cd "$R" && pwd -P)"; }

run_stop(){ # repo sid [last_msg]
  local repo="$1" sid="$2" msg="${3:-Implementation complete. Done.}" j
  j=$(jq -nc --arg s "$sid" --arg m "$msg" '{session_id:$s,last_assistant_message:$m,stop_hook_active:false}')
  ( cd "$repo" && env -i HOME="$FHOME" PATH="$PATH" HOOKS_LIB_DIR="$FHOME/.claude/hooks/lib" CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" <<<"$j" )
}
plant_v_history(){ printf '{"sessionId":"%s","display":"/v fix"}\n' "$1" >> "$FHOME/.claude/history.jsonl"; }
writes_log_path(){ local repo="$1" sid="$2" gd; gd=$(cd "$repo" && git rev-parse --git-common-dir 2>/dev/null); case "$gd" in /*) ;; *) gd="$repo/$gd";; esac; gd=$(cd "$gd" 2>/dev/null && pwd -P); echo "$gd/claude-session-writes-${sid}.txt"; }
plant_writes(){ local repo="$1" sid="$2"; shift 2; local f; f=$(writes_log_path "$repo" "$sid"); : > "$f"; for p in "$@"; do printf '%s\n' "$p" >> "$f"; done; }

# ── Group F: settings.json registration ─────────────────────────────────────
echo "=== F1: settings.json registers check-review-artifact.sh under Stop ==="
if jq -e '.hooks.Stop[].hooks[].command | select(test("check-review-artifact.sh"))' "$SETTINGS" >/dev/null 2>&1; then
  ok "Stop hook check-review-artifact.sh is wired in interactive settings.json"
else
  no "F1: check-review-artifact.sh NOT registered under .hooks.Stop in settings.json (interactive enforcement would be dead)"
fi

echo "=== F2: settings.json registers enforce-pre-commit-gates.sh under PreToolUse Bash ==="
if jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command | select(test("enforce-pre-commit-gates.sh"))' "$SETTINGS" >/dev/null 2>&1; then
  ok "enforce-pre-commit-gates.sh is wired in the interactive PreToolUse Bash chain"
else
  no "F2: enforce-pre-commit-gates.sh NOT in PreToolUse Bash chain"
fi

# ── Group P: protect-main-branch quote-strip (E3) ───────────────────────────
# Capture to a var first (avoids the SIGPIPE-under-pipefail trap the hooks document),
# and match the deny decision allowing for jq's pretty-printed `: ` spacing.
pmb(){ local _o; _o=$(jq -nc --arg c "$1" '{tool_input:{command:$c}}' | bash "$PMB" 2>/dev/null); printf '%s' "$_o" | grep -qE '"permissionDecision":[[:space:]]*"deny"' && echo DENY || echo ALLOW; }
new_repo p_repo; PR="$REPLY"
( cd "$PR" && git branch feature-x 2>/dev/null && git symbolic-ref HEAD refs/heads/feature-x ) >/dev/null 2>&1
pushd "$PR" >/dev/null
echo "=== P1: echo MENTIONING 'git push ... main' -> ALLOW (false-positive fixed) ==="
[ "$(pmb 'echo "does any hook block git push origin main?"')" = ALLOW ] \
  && ok "echo mentioning push→main is allowed" || no "P1: benign echo false-DENIED"
echo "=== P2: real 'git push origin main' from feature branch -> DENY ==="
[ "$(pmb 'git push origin main')" = DENY ] \
  && ok "real push to main still denied" || no "P2: real push→main NOT denied (SECURITY regression)"
echo "=== P3: real force push -> DENY ==="
[ "$(pmb 'git push --force origin feature-x')" = DENY ] \
  && ok "force push still denied" || no "P3: force push NOT denied (SECURITY regression)"
echo "=== P4: 'git push --force' only inside an echo string -> ALLOW ==="
[ "$(pmb "echo 'never git push --force'")" = ALLOW ] \
  && ok "echo of force is allowed" || no "P4: benign echo of force false-DENIED"
echo "=== P5: real feature-branch push -> ALLOW ==="
[ "$(pmb 'git push origin feature-x')" = ALLOW ] \
  && ok "feature-branch push allowed" || no "P5: feature push wrongly denied"
echo "=== P6: command word that is NOT a skip-builtin still gets push detection (S1 guard) ==="
# The command-word skip must skip ONLY echo/printf/:/true/false. A 'git push origin
# main' wrapped after an env-assignment (real push) must still be detected + denied —
# proving the skip didn't swallow real pushes.
[ "$(pmb 'GIT_SSH_COMMAND=ssh git push origin main')" = DENY ] \
  && ok "env-prefixed real push to main still denied (skip is narrow)" \
  || no "P6: env-prefixed push→main was NOT denied (S1 regression)"
popd >/dev/null

# ── Group C: committed Bash-written code detected even with a writes log (C1) ─
# 2026-08-03 fixture re-anchor: the Stop gate now applies to /v SESSIONS ONLY (check-review-artifact.sh
# § _V_SESSION, operator policy 2026-08-03) — a non-/v session exits 0 before CODE_CHANGED is ever
# evaluated. Both C1 cases predate that change and planted no /v signal, so C1a began FAILING (the
# gate exited 0, reading as "Bash-write blindness") and C1b began passing VACUOUSLY (it never reached
# the code-detection logic it claims to control). Planting /v evidence restores what both were always
# meant to assert; the assertions themselves are unchanged. Same pattern as bug6-phase2-test.sh, which
# calls plant_v_history in every group.
# C1 uses its OWN sid: plant_v_history appends to a single shared history.jsonl keyed by sessionId,
# and every other group reuses the global $SID. Planting /v evidence under $SID here would leak
# forward and turn later NON-/v cases (notably I1, whose whole premise is "NO /v") into /v sessions.
# The pre-existing plant at I2 sits late in the file for exactly this reason.
C1_SID="aaaaaaaa-1111-4111-8111-1111111111c1"
echo "=== C1a: writes-log has NO code + a COMMITTED .ts since baseline -> CODE detected -> BLOCK ==="
new_repo c1a; R="$REPLY"
plant_v_history "$C1_SID"                     # /v session → the gauntlet contract applies at all
plant_writes "$R" "$C1_SID" "README.md"       # writes log present, NO code → WRITES_LOG_AVAILABLE=1, CODE_CHANGED=0 from log
BASE_SHA=$(cd "$R" && git rev-parse HEAD)
mkdir -p "$R/.v/tmp"; printf '%s\n' "$BASE_SHA" > "$R/.v/tmp/head-baseline-${C1_SID}.txt"
( cd "$R" && mkdir -p src && echo 'export const x=1;' > src/foo.ts && git add -A && git commit -qm 'bash-written code' ) >/dev/null 2>&1
ERR=$( run_stop "$R" "$C1_SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ] && echo "$ERR" | grep -q 'PRE_FLIGHT_REPORT not found'; } \
  && ok "committed .ts (absent from writes log) -> CODE_CHANGED=1 -> gauntlet required" \
  || no "C1a (rc=$RC) — committed Bash-written code was NOT detected (Bash-write blindness)"

echo "=== C1b (control): writes-log NO code + a COMMITTED .md since baseline -> no code -> ALLOW ==="
new_repo c1b; R="$REPLY"
# same C1_SID: /v evidence already planted above, so rc=0 here proves CODE_CHANGED=0 rather than
# _V_SESSION=0 — without it this control passed vacuously, never reaching the code-detection logic.
# A /v session that ships no code still needs a completion artifact or it is judged ABANDONED and
# blocked (see L1's HANDOFF escape) — that block is unrelated to code detection and would mask what
# this control exists to prove. Plant the same valid HANDOFF L1 uses, so the ONLY remaining reason
# to block would be a docs commit being misread as code.
printf '# Handoff for %s\n\nStatus: deferred. Escalating to a fresh session because the context ran out mid-task. Next: resume from the notes above.\n' "$C1_SID" > "$R/HANDOFF_${C1_SID}.md"
plant_writes "$R" "$C1_SID" "README.md"
BASE_SHA=$(cd "$R" && git rev-parse HEAD)
mkdir -p "$R/.v/tmp"; printf '%s\n' "$BASE_SHA" > "$R/.v/tmp/head-baseline-${C1_SID}.txt"
( cd "$R" && mkdir -p docs && echo 'doc' > docs/x.md && git add -A && git commit -qm 'docs only' ) >/dev/null 2>&1
ERR=$( run_stop "$R" "$C1_SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "committed docs-only -> CODE_CHANGED=0 -> no false block" \
  || no "C1b (rc=$RC) — doc commit wrongly flagged as code: $(echo "$ERR" | head -1)"

# ── Group M: SKILL.md marker block resolves SID from runtime file (C2) ───────
echo "=== M1: bootstrap writes the marker under the RESOLVED sid (CLAUDE_SESSION_ID empty; runtime-file fallback) ==="
# 2026-07-01 re-anchor: the Bug-6 marker write was FOLDED from an inline SKILL.md bash block into
# v-bootstrap.sh (run via the Step-0 wrapper). Same intent — with env SIDs unset, the writer must
# resolve the SID from ~/.claude/runtime/current-session-id and write the marker the readers
# (v-gauntlet-attest.sh, check-review-artifact.sh) look for — retargeted at the real writer.
M1_WRAP="$REF_DIR/v-bootstrap-wrapper.sh"
if [ -f "$M1_WRAP" ]; then
  MR=$(mktemp -d "$BASE/mrk.XXXXXX")
  mkdir -p "$MR/repo" "$MR/home/.claude/runtime"
  printf '%s' "$SID" > "$MR/home/.claude/runtime/current-session-id"
  ( cd "$MR/repo" && git init -q >/dev/null 2>&1 \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m i >/dev/null 2>&1
    env -i HOME="$MR/home" PATH="$PATH" \
      bash -c "unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID SESSION_ID; bash '$M1_WRAP'" ) >/dev/null 2>&1
  if [ -f "$MR/repo/.v/tmp/v-invocation-start-${SID}.txt" ]; then
    ok "bootstrap resolved SID from runtime file -> wrote v-invocation-start-${SID}.txt to V_TMP_DIR"
  else
    no "M1: marker NOT written under the resolved SID (freshness check would silently no-op). Files: $(ls "$MR/repo/.v/tmp" 2>/dev/null | tr '\n' ' ')"
  fi
else
  no "M1: v-bootstrap-wrapper.sh not found at $M1_WRAP"
fi

# ── Group T: TRIVIAL_PASS freshness + triviality (C3) ────────────────────────
mk_trivial(){ local repo="$1" sid="$2" file="${3:-README.md}"; cat > "$repo/TRIVIAL_PASS_${sid}.md" <<EOF
TRIVIAL=1
REASON=one-line metadata tweak
FILE=${file}
LINES=2
EOF
}
echo "=== T1: FRESH TRIVIAL_PASS + 1 code file -> ACCEPT (exit 0) ==="
new_repo t1; R="$REPLY"
plant_writes "$R" "$SID" "src/foo.ts"
mkdir -p "$R/.v/tmp"; touch -t 202601010000 "$R/.v/tmp/v-invocation-start-${SID}.txt"
mk_trivial "$R" "$SID" "src/foo.ts"; touch -t 202605280000 "$R/TRIVIAL_PASS_${SID}.md"  # newer than marker
ERR=$( run_stop "$R" "$SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } && ok "fresh single-file TRIVIAL_PASS accepted" \
  || no "T1 (rc=$RC) — fresh trivial wrongly rejected: $(echo "$ERR" | head -1)"

echo "=== T2: STALE TRIVIAL_PASS (predates invocation marker) + code -> REJECT (exit 2) ==="
new_repo t2; R="$REPLY"
plant_writes "$R" "$SID" "src/foo.ts"
mk_trivial "$R" "$SID" "src/foo.ts"; touch -t 202601010000 "$R/TRIVIAL_PASS_${SID}.md"  # older than marker
mkdir -p "$R/.v/tmp"; touch -t 202605280000 "$R/.v/tmp/v-invocation-start-${SID}.txt"
ERR=$( run_stop "$R" "$SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ]; } && ok "stale TRIVIAL_PASS rejected -> gauntlet required" \
  || no "T2 (rc=$RC) — stale trivial marker wrongly accepted (same-SID reuse hole)"

echo "=== T3: FRESH TRIVIAL_PASS but writes log has 2 code files -> REJECT (not trivial) ==="
new_repo t3; R="$REPLY"
plant_writes "$R" "$SID" "src/foo.ts" "src/bar.ts"
mkdir -p "$R/.v/tmp"; touch -t 202601010000 "$R/.v/tmp/v-invocation-start-${SID}.txt"
mk_trivial "$R" "$SID" "src/foo.ts"; touch -t 202605280000 "$R/TRIVIAL_PASS_${SID}.md"
ERR=$( run_stop "$R" "$SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ]; } && ok "multi-file change rejected despite TRIVIAL_PASS marker" \
  || no "T3 (rc=$RC) — multi-file change wrongly accepted as trivial"

echo "=== T4: TRIVIAL_PASS + writes-log shows 0 code but 2 .ts COMMITTED -> REJECT (S2 guard) ==="
# Bash-committed code is invisible to the writes log; triviality must also count
# committed code since baseline, else a multi-file Bash-only commit reads as trivial.
new_repo t4; R="$REPLY"
plant_writes "$R" "$SID" "README.md"   # writes-log: NO code
BASE_SHA=$(cd "$R" && git rev-parse HEAD)
mkdir -p "$R/.v/tmp"; printf '%s\n' "$BASE_SHA" > "$R/.v/tmp/head-baseline-${SID}.txt"
( cd "$R" && mkdir -p src && echo 'export const a=1;' > src/a.ts && echo 'export const b=2;' > src/b.ts && git add -A && git commit -qm '2 files via bash' ) >/dev/null 2>&1
touch -t 202601010000 "$R/.v/tmp/v-invocation-start-${SID}.txt"
mk_trivial "$R" "$SID" "src/a.ts"; touch -t 202605280000 "$R/TRIVIAL_PASS_${SID}.md"
ERR=$( run_stop "$R" "$SID" 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ]; } \
  && ok "2 committed .ts (absent from writes log) -> TRIVIAL_PASS rejected" \
  || no "T4 (rc=$RC) — multi-file Bash-committed change wrongly accepted as trivial (S2 regression)"

echo "=== L1: LARGE history + /v + HANDOFF (no code) -> exit 0 (SIGPIPE-resistant /v detect) ==="
# >16 KB of SID-matching history.jsonl lines would SIGPIPE-kill `grep -F | grep -q`
# under pipefail, false-negating IS_V_INVOCATION and false-blocking the abandonment
# escape. The fix captures to a var. Use a dedicated SID + isolated history file.
SID_L="dddddddd-4444-4444-8444-444444444444"
HF="$FHOME/.claude/history.jsonl"
{ i=0; while [ "$i" -lt 1500 ]; do printf '{"sessionId":"%s","display":"Bash: ran a command number %s with some padding text"}\n' "$SID_L" "$i"; i=$((i+1)); done; printf '{"sessionId":"%s","display":"/v fix the thing"}\n' "$SID_L"; } >> "$HF"
new_repo l1; R="$REPLY"
# valid HANDOFF (>=80 bytes, '# Handoff' heading), no code shipped
printf '# Handoff for %s\n\nStatus: deferred. Escalating to a fresh session because the context ran out mid-task. Next: resume from the notes above.\n' "$SID_L" > "$R/HANDOFF_${SID_L}.md"
ERR=$( run_stop "$R" "$SID_L" 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "large history -> /v still detected -> HANDOFF abandonment escape works (exit 0)" \
  || no "L1 (rc=$RC) — large history SIGPIPE-false-negated /v detection -> false block: $(echo "$ERR" | grep -i 'BLOCKED\|not found' | head -1)"

# ── Group I: interactive-safety — tree dirt without /v evidence must NOT block ─
# Now that the Stop hook fires interactively (Group F), a conversational turn in a
# repo with PRE-EXISTING uncommitted code must not be falsely blocked. The tree-wide
# git fallback is gated on /v evidence (history) + no session writes log.
echo "=== I1: NO /v, NO writes-log, PRE-EXISTING uncommitted .ts + 'done' message -> ALLOW ==="
new_repo i1; R="$REPLY"
mkdir -p "$R/src" && echo 'export const wip = 1;' > "$R/src/wip.ts"   # uncommitted, NOT this session's
# no writes-log, no /v history, no head-baseline
ERR=$( run_stop "$R" "$SID" "Here is my analysis. Implementation complete." 2>&1 ); RC=$?
{ [ "$RC" -eq 0 ]; } \
  && ok "non-/v chat turn in a dirty repo is NOT blocked (tree dirt not attributed)" \
  || no "I1 (rc=$RC) — pure-chat in a dirty repo FALSE-BLOCKED: $(echo "$ERR" | grep -i 'BLOCKED\|not found' | head -1)"

echo "=== I2 (control): /v DID run + same uncommitted .ts + no artifacts -> BLOCK ==="
new_repo i2; R="$REPLY"
mkdir -p "$R/src" && echo 'export const wip = 1;' > "$R/src/wip.ts"
plant_v_history "$SID"     # /v evidence present → tree fallback is allowed to attribute
ERR=$( run_stop "$R" "$SID" "Implementation complete. Done." 2>&1 ); RC=$?
{ [ "$RC" -eq 2 ]; } \
  && ok "/v session with uncommitted code + no gauntlet -> blocked (enforcement intact)" \
  || no "I2 (rc=$RC) — /v session with code was NOT enforced"

# ── Group SL: session-log target advisory check (Finding-7) ─────────────────
# v-gauntlet-attest.sh checks whether a session-log attestation witness exists
# for this SID, and if so whether the target_log path it references is present.
# It must warn on stderr but still exit 0 (advisory — /v-session-log may not
# have run yet when attest is called).

_sl_sid="cccccccc-2222-4222-8222-2222222222cc"

# Helper: build a minimal but valid attest environment (all three gauntlet
# artifacts present + non-empty, no start marker so freshness check is skipped).
# H4-6 (PLAN_2026-07-02_orchestrator-hardening-4): v-gauntlet-attest.sh now runs the SAME
# Stop-grade semantic validation the Stop hook runs (validate_artifact + validate_review_semantics).
# The old bare "PRE_FLIGHT: pass" / "AGENT_REVIEW: ok" content lacked BOTH a recognized content
# marker (Status:/##/Overall:/Model:) AND the AGENT_REVIEW 6-metadata-field + session-id
# requirements — content this test never cared about (it's testing the session-log advisory
# check, not artifact semantics) but which the new gate correctly rejects, same as the real Stop
# hook always would have. Use minimal-but-COMPLIANT content instead.
_sl_setup_attest_env() {
  local root="$1" sid="$2"
  mkdir -p "$root/.v/artifacts"
  local pad; pad=$(printf '%0.s.' {1..201})  # 201 bytes > 200B minimum
  printf 'Model: haiku\nStatus: PASS\n## Gates\n%s\n' "$pad" > "$root/.v/artifacts/PRE_FLIGHT_REPORT_${sid}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n%s\n' \
    "$sid" "$pad" > "$root/.v/artifacts/AGENT_REVIEW_${sid}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$pad" > "$root/.v/artifacts/VERIFY_DONE_REPORT_${sid}.md"
}

_write_sl_witness() {
  local hdir="$1" sid="$2" target_log="$3"
  mkdir -p "$hdir/.claude/runtime"
  printf '{"skill":"v-session-log","check":"session-log-attest","sid":"%s","target_log":"%s"}\n' \
    "$sid" "$target_log" > "$hdir/.claude/runtime/v-session-log-attestation-${sid}.json"
}

echo "=== SL1: SL witness references a non-existent target_log -> WARNING on stderr, exit 0 ==="
new_repo sl1; R="$REPLY"
SL1_HOME="$BASE/sl1-home"; mkdir -p "$SL1_HOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks"  "$SL1_HOME/.claude/hooks"
_sl_setup_attest_env "$R" "$_sl_sid"
_write_sl_witness "$SL1_HOME" "$_sl_sid" "/tmp/nonexistent-session-log-${_sl_sid}.jsonl"
SL1_ERR=$(
  env -i HOME="$SL1_HOME" PATH="$PATH" GW_LIB="$REAL_HOME/.claude/hooks/lib/gauntlet-witness.sh" \
    PROJECT_ROOT="$R" \
    bash "$ATTEST" "$_sl_sid" 2>&1 1>/dev/null
); SL1_RC=$?
{ [ "$SL1_RC" -eq 0 ] && echo "$SL1_ERR" | grep -q "WARNING.*target_log"; } \
  && ok "SL1: missing target_log -> WARNING on stderr + exit 0 (advisory)" \
  || no "SL1 (rc=$SL1_RC) — expected exit 0 + WARNING; got: $(echo "$SL1_ERR" | head -2 | tr '\n' ' ')"

echo "=== SL2: SL witness references an EXISTING target_log -> no SL warning, exit 0 ==="
new_repo sl2; R="$REPLY"
SL2_HOME="$BASE/sl2-home"; mkdir -p "$SL2_HOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks"  "$SL2_HOME/.claude/hooks"
_sl_setup_attest_env "$R" "$_sl_sid"
SL2_LOG="$BASE/sl2-session-log-${_sl_sid}.jsonl"
printf '{"sessionId":"%s"}\n' "$_sl_sid" > "$SL2_LOG"
_write_sl_witness "$SL2_HOME" "$_sl_sid" "$SL2_LOG"
SL2_ERR=$(
  env -i HOME="$SL2_HOME" PATH="$PATH" GW_LIB="$REAL_HOME/.claude/hooks/lib/gauntlet-witness.sh" \
    PROJECT_ROOT="$R" \
    bash "$ATTEST" "$_sl_sid" 2>&1 1>/dev/null
); SL2_RC=$?
{ [ "$SL2_RC" -eq 0 ] && ! echo "$SL2_ERR" | grep -q "WARNING.*target_log"; } \
  && ok "SL2: existing target_log -> no SL warning + exit 0" \
  || no "SL2 (rc=$SL2_RC) — unexpected result; stderr: $(echo "$SL2_ERR" | head -2 | tr '\n' ' ')"

echo "=== SL3: no SL witness at all -> exit 0, no SL warning ==="
new_repo sl3; R="$REPLY"
SL3_HOME="$BASE/sl3-home"; mkdir -p "$SL3_HOME/.claude/runtime"
ln -s "$REAL_HOME/.claude/hooks"  "$SL3_HOME/.claude/hooks"
_sl_setup_attest_env "$R" "$_sl_sid"
# deliberately do NOT write any SL witness
SL3_ERR=$(
  env -i HOME="$SL3_HOME" PATH="$PATH" GW_LIB="$REAL_HOME/.claude/hooks/lib/gauntlet-witness.sh" \
    PROJECT_ROOT="$R" \
    bash "$ATTEST" "$_sl_sid" 2>&1 1>/dev/null
); SL3_RC=$?
{ [ "$SL3_RC" -eq 0 ] && ! echo "$SL3_ERR" | grep -q "WARNING.*target_log"; } \
  && ok "SL3: no SL witness -> no SL warning + exit 0" \
  || no "SL3 (rc=$SL3_RC) — unexpected result; stderr: $(echo "$SL3_ERR" | head -2 | tr '\n' ' ')"

echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ]
