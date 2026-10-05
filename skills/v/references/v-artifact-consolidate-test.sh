#!/usr/bin/env bash
# v-artifact-consolidate-test.sh — verifies the extracted single-source consolidation script
# (forensic C-3/A-3 2026-06-04) preserves the W-perf6 move semantics the self-check carried
# (cp -p mtime preservation, strictly-newer-dst wins, tie→source wins, verified move, no data
# loss on empty copy), handles the NEW merge-back rescue path (extra source dirs = worktree),
# and that BOTH callers (v-completion-selfcheck.sh + v-merge-back.sh) are actually wired to it
# (drift sentinels — the whole point of extraction is that the two can never diverge).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/v-artifact-consolidate.sh"
SELFCHK="$HERE/v-completion-selfcheck.sh"
MERGEBACK="$HERE/v-merge-back.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SID="cafe0001-0000-4000-8000-000000000000"
OTHER_SID="beef0002-0000-4000-8000-000000000000"

# A temp MAIN repo so REPO_ROOT / `git worktree list` resolution works.
MR="$WORK/mainrepo"
mkdir -p "$MR"
git -C "$MR" init -q
git -C "$MR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

echo "== v-artifact-consolidate :: move semantics =="

# 1. root artifact → .v/artifacts (verified move; root cleaned; message emitted)
printf 'Model: haiku\nOverall Status: PASS\n' > "$MR/PRE_FLIGHT_REPORT_${SID}.md"
_msg=$( (cd "$MR" && bash "$SCRIPT" "$SID") 2>&1 ); _rc=$?
[ "$_rc" -eq 0 ] && ok "exit 0 on normal run" || no "exit $_rc on normal run"
[ -f "$MR/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" ] && ok "root artifact moved into .v/artifacts" || no "root artifact not in .v/artifacts"
[ ! -f "$MR/PRE_FLIGHT_REPORT_${SID}.md" ] && ok "root copy removed (de-clutter)" || no "root copy still present"
echo "$_msg" | grep -q "consolidated PRE_FLIGHT_REPORT_${SID}.md" && ok "consolidation message emitted" || no "no consolidation message (got: $_msg)"

# 2. extra source dir (the merge-back worktree rescue path)
WT="$WORK/fakeworktree"
mkdir -p "$WT/.v/artifacts"
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer (independent subprocess)\n- Codex adversarial reviewer: ran — 0 candidates (background agent)\n- Reviewer model: sonnet\n- Hostile adversarial focus: no\n- Dispatch mode: foreground\n- Review evidence: findings: 0\n- Remediation: 0 — no findings\n\n## Findings\n\nNo issues found.\n' "${SID}" > "$WT/AGENT_REVIEW_${SID}.md"
printf 'verdict: pass\n' > "$WT/.v/artifacts/QA_REPORT_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID" "$WT" "$WT/.v/artifacts") 2>/dev/null
[ -f "$MR/.v/artifacts/AGENT_REVIEW_${SID}.md" ] && ok "worktree-root artifact rescued via extra source dir" || no "worktree-root artifact NOT rescued"
[ -f "$MR/.v/artifacts/QA_REPORT_${SID}.md" ] && ok "worktree .v/artifacts artifact rescued" || no "worktree .v/artifacts artifact NOT rescued"
[ ! -f "$WT/AGENT_REVIEW_${SID}.md" ] && ok "worktree source removed after verified move" || no "worktree source still present"

# 2b. P7-B / CODEX-001 (review 2026-06-22): SUCCESS_CRITERIA + WORKFLOW_BLAST_RADIUS must consolidate
# too. They are now gated validate-if-present in BOTH the Stop hook and v-completion-selfcheck.sh, but
# the selfcheck's find_at_main does NOT search SESSION_WT/.v/artifacts while the Stop hook does — so a
# worktree-stranded artifact (or one destroyed on worktree removal) creates a parity gap (Stop blocks,
# selfcheck accepts → /v lies about finishing). Consolidating both into the canonical .v/artifacts (which
# BOTH gates search) closes it. Bite: absent from _PREFIXES → not swept (RED); present → swept (GREEN).
WT2="$WORK/fakeworktree2"
mkdir -p "$WT2/.v/artifacts"
printf 'Model: haiku\ncriteria:\n- SC-1: x\nworkflow_states:\n- empty\n' > "$WT2/.v/artifacts/SUCCESS_CRITERIA_${SID}.md"
printf 'Model: haiku\nstates_to_verify:\n- empty\n' > "$WT2/WORKFLOW_BLAST_RADIUS_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID" "$WT2" "$WT2/.v/artifacts") 2>/dev/null
[ -f "$MR/.v/artifacts/SUCCESS_CRITERIA_${SID}.md" ] && ok "SUCCESS_CRITERIA swept worktree→.v/artifacts (CODEX-001 parity gap closed)" || no "SUCCESS_CRITERIA NOT consolidated — Stop-hook⟺selfcheck parity gap"
[ -f "$MR/.v/artifacts/WORKFLOW_BLAST_RADIUS_${SID}.md" ] && ok "WORKFLOW_BLAST_RADIUS swept worktree→.v/artifacts (CODEX-001 parity gap closed)" || no "WORKFLOW_BLAST_RADIUS NOT consolidated — parity gap"

# 3. dst STRICTLY newer → stale source dropped, dst content preserved
printf 'NEWER CANONICAL\n' > "$MR/.v/artifacts/IMPACT_MAP_${SID}.md"
printf 'stale root copy\n' > "$MR/IMPACT_MAP_${SID}.md"
touch -t 202001010000 "$MR/IMPACT_MAP_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
grep -q 'NEWER CANONICAL' "$MR/.v/artifacts/IMPACT_MAP_${SID}.md" && ok "strictly-newer dst preserved" || no "newer dst was clobbered by stale source"
[ ! -f "$MR/IMPACT_MAP_${SID}.md" ] && ok "stale source duplicate dropped" || no "stale source duplicate kept"

# 4. source newer (or tie) → source wins, mtime preserved (cp -p)
printf 'old canonical\n' > "$MR/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
touch -t 202001010000 "$MR/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md"
printf 'FRESH ROOT FIX\n' > "$MR/VERIFY_DONE_REPORT_${SID}.md"
touch -t 202501010000 "$MR/VERIFY_DONE_REPORT_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
grep -q 'FRESH ROOT FIX' "$MR/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md" && ok "newer source wins over stale dst" || no "newer source did not replace stale dst"
_src_epoch=$(date -r "$MR/.v/artifacts/VERIFY_DONE_REPORT_${SID}.md" +%Y%m 2>/dev/null || echo "")
[ "$_src_epoch" = "202501" ] && ok "cp -p preserved source mtime (real-source-vs-real-source on later sweeps)" || no "mtime not preserved (got $_src_epoch, want 202501)"

# 4b. EXACT mtime tie → source wins (`-nt` is strict; a tie must not drop a just-written fix)
printf 'old tie dst\n' > "$MR/.v/artifacts/UX_CRITIQUE_${SID}.md"
printf 'TIE SOURCE FIX\n' > "$MR/UX_CRITIQUE_${SID}.md"
touch -t 202403150930.00 "$MR/.v/artifacts/UX_CRITIQUE_${SID}.md" "$MR/UX_CRITIQUE_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
grep -q 'TIE SOURCE FIX' "$MR/.v/artifacts/UX_CRITIQUE_${SID}.md" && ok "mtime TIE → source wins (CODEX-002 strict -nt guard)" || no "mtime tie dropped the source fix"

# 5. other sessions' artifacts untouched
printf 'sibling\n' > "$MR/PRE_FLIGHT_REPORT_${OTHER_SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
[ -f "$MR/PRE_FLIGHT_REPORT_${OTHER_SID}.md" ] && ok "sibling SID artifact left untouched" || no "sibling SID artifact was moved/removed"
rm -f "$MR/PRE_FLIGHT_REPORT_${OTHER_SID}.md"

# 6. empty source file → NOT moved blindly, source kept (no data loss; [ -s dst ] guard)
: > "$MR/HANDOFF_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
[ -f "$MR/HANDOFF_${SID}.md" ] && ok "empty source kept (verified-move guard refused 0-byte copy)" || no "empty source removed despite failed verified copy"
rm -f "$MR/HANDOFF_${SID}.md" "$MR/.v/artifacts/HANDOFF_${SID}.md"

# T-stray-move-mtime (MEDIUM fix 2026-06-09): dst strictly newer BUT below size threshold →
# source wins (stub artifact in .v/artifacts must not discard valid ROOT copy)
printf '%0.s.' $(seq 1 300) > "$MR/.v/artifacts/PRE_FLIGHT_REPORT_stray_${SID}.md"  # ~300B stub
printf '%.0s.' $(seq 1 2048) > "$MR/PRE_FLIGHT_REPORT_stray_${SID}.md"              # ~2KB valid
# Make the stub in .v/artifacts strictly newer
touch "$MR/.v/artifacts/PRE_FLIGHT_REPORT_stray_${SID}.md"
sleep 0.05 2>/dev/null || true
touch "$MR/PRE_FLIGHT_REPORT_stray_${SID}.md"
# force dst mtime ahead (macOS touch -A not portable; use a second-resolution safe approach)
# Strategy: make the source OLDER than stub so the mtime test fires correctly
touch -t 202001010000 "$MR/PRE_FLIGHT_REPORT_stray_${SID}.md"
# But the source (root copy) must be LARGER — rename it to the canonical name so the test
# checks the size-threshold guard (dst newer but tiny → source wins regardless of mtime)
# Use the actual artifact names (must match _PREFIXES in the consolidate script)
STRAY_SID="cafe0099-0000-4000-8000-000000000099"
printf '%0.s.' $(seq 1 2048) > "$MR/PRE_FLIGHT_REPORT_${STRAY_SID}.md"   # ~2KB
printf 'stub'                > "$MR/.v/artifacts/PRE_FLIGHT_REPORT_${STRAY_SID}.md"  # 4B
touch -t 202601010000 "$MR/.v/artifacts/PRE_FLIGHT_REPORT_${STRAY_SID}.md"  # dst strictly newer
touch -t 202001010000 "$MR/PRE_FLIGHT_REPORT_${STRAY_SID}.md"               # src older
(cd "$MR" && bash "$SCRIPT" "$STRAY_SID") 2>/dev/null
_sz=$(wc -c < "$MR/.v/artifacts/PRE_FLIGHT_REPORT_${STRAY_SID}.md" 2>/dev/null | tr -d ' ')
[ "${_sz:-0}" -ge 2000 ] && ok "T-stray-move-mtime: larger ROOT overrides newer-but-tiny stub in .v/artifacts" || no "T-stray-move-mtime: stub (${_sz}B) NOT replaced by large ROOT (~2048B)"
rm -f "$MR/PRE_FLIGHT_REPORT_stray_${SID}.md" "$MR/.v/artifacts/PRE_FLIGHT_REPORT_stray_${SID}.md"
rm -f "$MR/.v/artifacts/PRE_FLIGHT_REPORT_${STRAY_SID}.md"

# 6b. CODEX-005: a SYMLINKED dst is replaced as a link, never written THROUGH to its target
_target="$WORK/symlink-target.md"
printf 'PROTECTED TARGET\n' > "$_target"
touch -t 202001010000 "$_target"
ln -s "$_target" "$MR/.v/artifacts/BLOCKED_${SID}.md"
printf 'fresh source\n' > "$MR/BLOCKED_${SID}.md"
(cd "$MR" && bash "$SCRIPT" "$SID") 2>/dev/null
grep -q 'PROTECTED TARGET' "$_target" && ok "symlink target NOT written through (CODEX-005 mv-replaces-link guard)" || no "symlink target was clobbered through the link"
[ ! -L "$MR/.v/artifacts/BLOCKED_${SID}.md" ] && grep -q 'fresh source' "$MR/.v/artifacts/BLOCKED_${SID}.md" && ok "symlink dst replaced by real file with source content" || no "dst not replaced correctly"
rm -f "$MR/.v/artifacts/BLOCKED_${SID}.md" "$MR/BLOCKED_${SID}.md"

# 6c. CODEX-001: no stray staging temps left behind in .v/artifacts after sweeps
ls "$MR/.v/artifacts"/.consolidate.* >/dev/null 2>&1 && no "staging temp files leaked into .v/artifacts" || ok "no staging temps leaked"

# 7. V_ARTIFACT_DIR override respected (test isolation contract)
OD="$WORK/override-artifacts"
printf 'x\n' > "$MR/QA_REPORT_${OTHER_SID}.md"
(cd "$MR" && V_ARTIFACT_DIR="$OD" bash "$SCRIPT" "$OTHER_SID") 2>/dev/null
[ -f "$OD/QA_REPORT_${OTHER_SID}.md" ] && ok "V_ARTIFACT_DIR override consolidates into override dir" || no "override dir not used"

# 8. usage error
bash "$SCRIPT" >/dev/null 2>&1; _rc=$?
[ "$_rc" -eq 2 ] && ok "missing SID → exit 2" || no "missing SID exit was $_rc (want 2)"

echo "== drift sentinels :: both callers wired to the single source =="
grep -q 'v-artifact-consolidate.sh' "$SELFCHK" && ok "v-completion-selfcheck.sh delegates to v-artifact-consolidate.sh" || no "self-check lost the consolidate delegation"
_mb_calls=$(grep -c 'v-artifact-consolidate.sh' "$MERGEBACK" || true)
[ "${_mb_calls:-0}" -ge 2 ] && ok "v-merge-back.sh calls consolidate at BOTH worktree-removal sites ($_mb_calls refs)" || no "v-merge-back.sh consolidate call sites: ${_mb_calls:-0} (want >=2: idempotent-cleanup + success-path)"
# the self-check must NOT retain a private copy of the move loop (that's the drift this kills)
grep -q 'cp -p "\$_f" "\$_dst"' "$SELFCHK" && no "self-check still carries a private move loop (drift risk)" || ok "self-check no longer carries a private move loop"
for _pfx in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT IMPACT_MAP QA_REPORT UX_CRITIQUE WORKFLOW_VERIFICATION BLOCKED TRIVIAL_PASS PLANNING_PASS HANDOFF SUCCESS_CRITERIA WORKFLOW_BLAST_RADIUS; do
  grep -q "$_pfx" "$SCRIPT" || { no "consolidate prefix list lost $_pfx"; continue; }
done
ok "consolidate prefix list covers all gate artifact types"

echo "== E2E :: v-merge-back rescues a worktree-stranded artifact before removal =="
# Real worktree, SID-named branch, artifact ONLY inside the worktree's .v/artifacts (the
# H-5 stranded location). After merge-back: branch merged, worktree
# gone, artifact alive in MAIN's .v/artifacts.
ER="$WORK/e2erepo"
ESID="ab12cd34-0000-4000-8000-00000000e2e0"
ESHORT="ab12cd34"
mkdir -p "$ER"
git -C "$ER" init -q
printf '.v/\n.worktrees/\n' > "$ER/.gitignore"
git -C "$ER" add .gitignore
git -C "$ER" -c user.email=t@t -c user.name=t commit -q -m init
EWT="$WORK/e2e-worktree"
git -C "$ER" worktree add -q -b "build/e2e-rescue-$ESHORT" "$EWT" >/dev/null 2>&1
printf 'work\n' > "$EWT/feature.txt"
git -C "$EWT" add feature.txt
git -C "$EWT" -c user.email=t@t -c user.name=t commit -q -m "feat: e2e"
mkdir -p "$EWT/.v/artifacts"
printf 'Model: haiku\nOverall Status: PASS\n' > "$EWT/.v/artifacts/PRE_FLIGHT_REPORT_${ESID}.md"
# W-GATE: AGENT_REVIEW is also required by the artifact-presence merge precondition — placing
# it ONLY in the worktree additionally proves the gate sees worktree-local artifacts (via the
# pre-gate consolidate sweep).
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer (independent subprocess)\n- Codex adversarial reviewer: ran — 0 candidates (background agent)\n- Reviewer model: sonnet\n- Hostile adversarial focus: no\n- Dispatch mode: foreground\n- Review evidence: findings: 0\n- Remediation: 0 — no findings\n\n## Findings\n\nNo issues found.\n' "${ESID}" > "$EWT/.v/artifacts/AGENT_REVIEW_${ESID}.md"
# W-GATE: VERIFY_DONE_REPORT is ALSO required by the artifact-presence merge precondition for a code
# session (the precondition grew to the full PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE triad AFTER this
# harness was written; without it the merge correctly blocks). Plant it worktree-local too — same rescue path.
printf 'Model: haiku\nOverall Verdict: PASS\n' > "$EWT/.v/artifacts/VERIFY_DONE_REPORT_${ESID}.md"
# F3 (2026-06-17): the precondition grew again — a code session also needs IMPACT_MAP + QA_REPORT. Plant
# them worktree-local too (same rescue path; without them the merge correctly blocks).
printf 'Model: haiku\nsubsystems:\n- functional_flow\n' > "$EWT/.v/artifacts/IMPACT_MAP_${ESID}.md"
printf 'Model: haiku\n## QA Acceptance\nverdict: pass\n' > "$EWT/.v/artifacts/QA_REPORT_${ESID}.md"
_mb_out=$(bash "$MERGEBACK" "$ESID" "$EWT" 2>&1); _mb_rc=$?
[ "$_mb_rc" -eq 0 ] && ok "E2E merge-back exit 0" || no "E2E merge-back exit $_mb_rc — $_mb_out"
grep -q 'work' "$ER/feature.txt" 2>/dev/null && ok "E2E branch content merged into main" || no "E2E merged content missing"
[ ! -d "$EWT" ] && ok "E2E worktree removed" || no "E2E worktree still present"
[ -f "$ER/.v/artifacts/PRE_FLIGHT_REPORT_${ESID}.md" ] && ok "E2E worktree-stranded artifact RESCUED into main .v/artifacts (the H-5 loss class)" || no "E2E artifact LOST with the worktree (rescue failed): $_mb_out"

# ── CONSOLIDATE-1 (audit 2026-06-18): in a NON-GIT dir (the ~/.claude meta-repo), git rev-parse
#    fails so REPO_ROOT/MAIN_ROOT fall back to "." → the source "./.v/artifacts" aliases the ABSOLUTE
#    ARTIFACT_DIR as a different string. The string-only same-file guard let the loop cp a canonical
#    artifact onto itself and then `rm -f "$_f"` DELETED it. Assert the file SURVIVES.
NG="$WORK/nongit"; mkdir -p "$NG/.v/artifacts"   # deliberately NOT a git repo
NGSID="abcd1234-0000-1111-2222-333344445555"
printf 'Mode: scoped\nartifact body must survive consolidation\nOverall Status: PASS\n' > "$NG/.v/artifacts/PRE_FLIGHT_REPORT_${NGSID}.md"
( cd "$NG" && CLAUDE_SESSION_ID="$NGSID" bash "$SCRIPT" "$NGSID" ) >/dev/null 2>&1
[ -f "$NG/.v/artifacts/PRE_FLIGHT_REPORT_${NGSID}.md" ] \
  && ok "CONSOLIDATE-1 non-git relative-root: canonical artifact survives (not rm'd by self-alias)" \
  || no "CONSOLIDATE-1 REGRESSION: consolidate DELETED a canonical artifact via relative/absolute self-alias (the data-loss bug)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
