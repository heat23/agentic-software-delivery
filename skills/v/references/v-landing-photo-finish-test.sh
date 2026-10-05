#!/usr/bin/env bash
# v-landing-photo-finish-test.sh — BITE for the 2026-07-01 wave-2 landing forensics fixes:
#
#   T-ACT  run-v-packs: the timeout watchdog records WHY it killed (sidecar content "active"|"wedged" by
#          log-mtime freshness) and the park message stops calling actively-working sessions "WEDGED"
#          (observed: sessions killed near the end of a passing gauntlet were labeled WEDGED).
#   F1b    run-v-packs: settle window before the end-of-run drain when anything was timeout-killed, plus
#          ONE re-drain when the drain hits a W-GATE artifact block — the photo-finish class (merge-back
#          declared PRE_FLIGHT_REPORT missing shortly before the killed session's surviving gate subagent wrote
#          it → a fully-gauntleted QA-passed branch was reported NEEDS-MANUAL).
#   F-WG   v-drain-deferred-merges.sh: a merge-back W-GATE artifact block is reported as its OWN class
#          (with the actual missing-artifact reason + re-drain hint), not "see its WORKTREE_HANDOFF"
#          (no handoff exists for this class — that pointer was archaeology bait).
#   F-QS   v-drain-deferred-merges.sh: a QA-FAIL HOLD whose branch tip POST-DATES the QA report says the
#          verdict may be STALE (remediation commit landed after the verdict; session killed before QA
#          iteration 2) — still HOLDS (never auto-lands on the inference).
#   F5     run-v-packs: _drain_verdict_for recognizes HOLD / W-GATE-block / LIVE-skip lines so the footer
#          stops printing "session still live, or not yet drained — re-run to retry" for a branch the SAME
#          run's drain just HELD.
#   F6     run-v-packs: reconcile_parked_by_proof moves a parked pack to .done/ when its session's durable
#          commit-witness (commits-<sid>.txt) is fully on main — works after the worktree/branch are gone
#          (observed: wave-1 packs renagged forever though their merges had landed).
#          FAIL-CLOSED: missing witness, unresolvable sha (session rewrote history — observed live), or any
#          non-ancestor sha → not moved.
#
# Red oracle: run with RUNNER_OVERRIDE / DRAINER_OVERRIDE pointing at the pre-fix copies → must FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAINER="${DRAINER_OVERRIDE:-$HERE/v-drain-deferred-merges.sh}"
RUNNER="${RUNNER_OVERRIDE:-$HOME/.local/bin/run-v-packs}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq";  echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }
[ -f "$DRAINER" ] || { echo "FATAL: drainer missing at $DRAINER"; exit 2; }
[ -f "$RUNNER" ]  || { echo "FATAL: run-v-packs missing at $RUNNER"; exit 2; }

BASE="$(mktemp -d)"
sleep 300 & HANG_PID=$!
trap 'kill "$HANG_PID" 2>/dev/null; rm -rf "$BASE" 2>/dev/null' EXIT

# ── drain-side fixture repo: one stranded ENDED worktree with gauntlet evidence ───────────────────
R="$BASE/repo"; mkdir -p "$R"
# .v/ + .worktrees/ MUST be gitignored (as in real repos): the branch fixtures below use `git add -A`,
# and without the ignore the artifacts get committed to the branch — the checkout back to main then
# DELETES them from the working tree, silently emptying the drain's evidence store mid-test.
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main && printf '.v/\n.worktrees/\n' > .gitignore \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
SIDW="ab12cd34-1111-4222-8333-444455556666"
( cd "$R" && git checkout -q -b "fix/photo-ab12cd34" && echo x > x.f && git add -A && git commit -qm x && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/photo" "fix/photo-ab12cd34" >/dev/null 2>&1
rm -f "$R/.worktrees/photo/.claude-session-lock" 2>/dev/null
mkdir -p "$R/.v/artifacts" "$R/.v/tmp"
printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${SIDW}.md"   # verdict gate passes → reaches merge-back

echo "== F-WG: a merge-back W-GATE artifact block is its OWN reported class (not 'see its WORKTREE_HANDOFF') =="
WGSTUB="$BASE/wgstub.sh"
cat > "$WGSTUB" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: W-GATE artifact-presence merge precondition FAILED for SID=$1." >&2
echo "ERROR:   required (code session): MISSING: PRE_FLIGHT_REPORT (present: AGENT_REVIEW, VERIFY_DONE_REPORT)" >&2
echo "ERROR:   searched: /x/.v/artifacts, /x, /y[/.v/artifacts]" >&2
echo "══════════════════════════════════════════════════════════════════════" >&2
echo "⛔ DO NOT FALL BACK TO A MANUAL git merge." >&2
echo "══════════════════════════════════════════════════════════════════════" >&2
exit 1
EOF
chmod +x "$WGSTUB"
WGOUT="$(V_DRAIN_MERGEBACK="$WGSTUB" bash "$DRAINER" "$R" 2>&1)"
printf '%s\n' "$WGOUT" | grep -F "for fix/photo-ab12cd34 (left intact" | grep -qF 'W-GATE artifact block' \
  && ok "W-GATE block reported as its own class" || no "W-GATE block not classified" "$WGOUT"
printf '%s\n' "$WGOUT" | grep -qF 'MISSING: PRE_FLIGHT_REPORT' \
  && ok "the actual missing artifact is named on the line" || no "missing-artifact reason absent" "$WGOUT"
printf '%s\n' "$WGOUT" | grep -qF 'RE-RUN THIS DRAIN' \
  && ok "re-drain hint present (photo-finish remediation)" || no "no re-drain hint" "$WGOUT"
printf '%s\n' "$WGOUT" | grep -F "for fix/photo-ab12cd34" | grep -qF 'see its WORKTREE_HANDOFF' \
  && no "still points at a WORKTREE_HANDOFF that does not exist for this class" "$WGOUT" \
  || ok "no phantom WORKTREE_HANDOFF pointer on a W-GATE block"

echo "== F-WG control: a NON-W-GATE failure still reports the WORKTREE_HANDOFF class unchanged =="
GENSTUB="$BASE/genstub.sh"
printf '#!/usr/bin/env bash\necho "ERROR: merge conflict in f" >&2\nexit 1\n' > "$GENSTUB"; chmod +x "$GENSTUB"
GENOUT="$(V_DRAIN_MERGEBACK="$GENSTUB" bash "$DRAINER" "$R" 2>&1)"
printf '%s\n' "$GENOUT" | grep -F "for fix/photo-ab12cd34" | grep -qF 'see its WORKTREE_HANDOFF' \
  && ok "generic failure keeps the conflict/handoff message" || no "generic failure message drifted" "$GENOUT"

echo "== F-QS: QA-FAIL HOLD notes a possibly-STALE verdict when the branch tip post-dates the report =="
SIDQ="cd34ef56-1111-4222-8333-444455556666"
( cd "$R" && git checkout -q -b "fix/staleqa-cd34ef56" && echo q > q.f && git add -A && git commit -qm q && git checkout -q main ) >/dev/null 2>&1
git -C "$R" worktree add -q "$R/.worktrees/staleqa" "fix/staleqa-cd34ef56" >/dev/null 2>&1
rm -f "$R/.worktrees/staleqa/.claude-session-lock" 2>/dev/null
printf 'APPROVED\n' > "$R/.v/artifacts/AGENT_REVIEW_${SIDQ}.md"
printf 'HANDOFF\n' > "$R/.v/artifacts/WORKTREE_HANDOFF_${SIDQ}.md"   # stranding proof for the lockless worktree
printf 'verdict: fail\n' > "$R/.v/artifacts/QA_REPORT_${SIDQ}.md"
touch -t 202601010000 "$R/.v/artifacts/QA_REPORT_${SIDQ}.md"        # report far older than the branch tip
MBSTUB="$BASE/mbstub.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$MBSTUB"; chmod +x "$MBSTUB"
QSOUT="$(V_DRAIN_MERGEBACK="$MBSTUB" bash "$DRAINER" "$R" 2>&1)"
printf '%s\n' "$QSOUT" | grep -F "HOLD fix/staleqa-cd34ef56" | grep -qF 'may be STALE' \
  && ok "stale-verdict NOTE on a post-verdict-commit QA-fail HOLD" || no "no stale note" "$QSOUT"
printf '%s\n' "$QSOUT" | grep -qF "HOLD fix/staleqa-cd34ef56" \
  && ok "…and it still HOLDS (never auto-lands on the staleness inference)" || no "hold lost" "$QSOUT"
touch "$R/.v/artifacts/QA_REPORT_${SIDQ}.md"                         # now newer than the tip → fresh verdict
QFOUT="$(V_DRAIN_MERGEBACK="$MBSTUB" bash "$DRAINER" "$R" 2>&1)"
printf '%s\n' "$QFOUT" | grep -F "HOLD fix/staleqa-cd34ef56" | grep -qF 'may be STALE' \
  && no "fresh QA verdict wrongly flagged stale" "$QFOUT" \
  || ok "a verdict NEWER than the branch tip carries no stale note"

# ── runner-side: source run-v-packs for unit-level checks ─────────────────────────────────────────
# shellcheck disable=SC1090
source "$RUNNER" 2>/dev/null
[ "$(type -t _drain_verdict_for)" = function ] || { echo "FATAL: sourcing $RUNNER did not expose _drain_verdict_for"; exit 1; }

echo "== F5: _drain_verdict_for recognizes HOLD / W-GATE-block / LIVE-skip drain lines =="
DOUT="  ⏸ HOLD fix/h-11111111 — QA verdict FAIL (QA_REPORT_x.md). Not landing ungated work
  ✗ merge-back rc=1 for fix/w-22222222 (left intact; W-GATE artifact block — no WORKTREE_HANDOFF exists for this class): MISSING: PRE_FLIGHT_REPORT
  ⏭ skip fix/l-33333333 — owning session is ALIVE (pid 123); not touching a live worktree
  ✗ merge-back rc=2 for fix/f-44444444 (left intact; see its WORKTREE_HANDOFF): ERROR: ownership unprovable."
[ "$(_drain_verdict_for "$DOUT" "fix/h-11111111")" = held ]   && ok "HOLD line → held"   || no "held classification" "$(_drain_verdict_for "$DOUT" "fix/h-11111111")"
[ "$(_drain_verdict_for "$DOUT" "fix/w-22222222")" = wgate ]  && ok "W-GATE line → wgate" || no "wgate classification" "$(_drain_verdict_for "$DOUT" "fix/w-22222222")"
[ "$(_drain_verdict_for "$DOUT" "fix/l-33333333")" = live ]   && ok "LIVE-skip line → live" || no "live classification" "$(_drain_verdict_for "$DOUT" "fix/l-33333333")"
[ "$(_drain_verdict_for "$DOUT" "fix/f-44444444")" = failed ] && ok "generic failure still → failed" || no "failed classification regressed" "$(_drain_verdict_for "$DOUT" "fix/f-44444444")"

echo "== T-ACT: _timeout_kind reads the sidecar; empty/missing sidecar stays 'wedged' (legacy-safe) =="
LOG_DIR="$BASE/logs"; mkdir -p "$LOG_DIR"
printf 'active\n' > "$LOG_DIR/ta.log.timedout"
[ "$(_timeout_kind ta)" = active ] && ok "sidecar 'active' → active" || no "active kind" "$(_timeout_kind ta)"
: > "$LOG_DIR/tw.log.timedout"
[ "$(_timeout_kind tw)" = wedged ] && ok "empty (legacy) sidecar → wedged" || no "legacy sidecar kind" "$(_timeout_kind tw)"
[ "$(_timeout_kind tmissing)" = wedged ] && ok "missing sidecar → wedged" || no "missing sidecar kind"

echo "== T-ACT behavioral: _watchdog stamps active vs wedged by log-mtime freshness (and still kills) =="
LFA="$BASE/logs/wda.log"; printf 'events\n' > "$LFA"                 # fresh mtime = active at kill time
sleep 300 & WP1=$!
PACK_TIMEOUT=1 _watchdog "$WP1" "$LFA"
[ "$(head -1 "$LFA.timedout" 2>/dev/null)" = active ] && ok "fresh-log kill stamped 'active'" || no "active stamp" "$(cat "$LFA.timedout" 2>/dev/null)"
kill -0 "$WP1" 2>/dev/null && { no "watchdog failed to kill the active-case process"; kill "$WP1" 2>/dev/null; } || ok "…and the process was still killed (park behavior unchanged)"
LFW="$BASE/logs/wdw.log"; printf 'old\n' > "$LFW"; touch -t 202601010000 "$LFW"   # stale mtime = wedged
sleep 300 & WP2=$!
PACK_TIMEOUT=1 _watchdog "$WP2" "$LFW"
[ "$(head -1 "$LFW.timedout" 2>/dev/null)" = wedged ] && ok "stale-log kill stamped 'wedged'" || no "wedged stamp" "$(cat "$LFW.timedout" 2>/dev/null)"
kill "$WP2" 2>/dev/null || true
[ "$(verdict wda 2>/dev/null || true)" = timeout ] && ok "verdict() still reads a content-bearing sidecar as timeout" || no "verdict drift on non-empty sidecar" "$(verdict wda)"

echo "== F1b wiring: settle + one re-drain on W-GATE block, gated on HAD_TIMEOUT; proof-reconcile wired =="
# W-LAND (2026-07-02): the settle/drain/re-drain/reconcile sequence moved from main() into the shared
# _land_and_reconcile (ONE copy serving both the per-wave landing barrier and the end-of-run sweep).
# The pin follows the call chain — BOTH links asserted, so an unwired main() or a gutted landing pass
# still bites exactly as the old single-level grep did.
mn="$(declare -f main 2>/dev/null)"
lr="$(declare -f _land_and_reconcile 2>/dev/null)"
echo "$mn" | grep -q '_land_and_reconcile' && ok "main() calls _land_and_reconcile (the shared landing pass)" || no "_land_and_reconcile not wired into main()"
echo "$lr" | grep -q 'V_PACK_SETTLE_SEC' && ok "landing pass has the pre-drain settle window" || no "no settle window in _land_and_reconcile()"
echo "$lr" | grep -q 'W-GATE artifact block' && ok "landing pass re-drains on a W-GATE artifact block" || no "no W-GATE re-drain in _land_and_reconcile()"
echo "$lr" | grep -q 'HAD_TIMEOUT' && ok "settle/re-drain is gated on HAD_TIMEOUT (no pointless waits on clean runs)" || no "HAD_TIMEOUT gate missing"
echo "$lr" | grep -q 'reconcile_parked_by_proof' && ok "landing pass calls reconcile_parked_by_proof" || no "proof-reconcile not wired into _land_and_reconcile()"
# 2026-07-04 refactor (sibling hardening pass): the reap loop's disposal logic was factored out of
# run_pass_wave into the shared _archive_finished_pack helper. Assert BOTH links of the call chain —
# run_pass_wave must delegate to the helper, and the helper must carry the timeout logic — exactly as
# the main()→_land_and_reconcile pin above does, so the bite survives factoring but still fires if
# the logic is deleted or unwired.
rw="$(declare -f run_pass_wave 2>/dev/null)"
afp="$(declare -f _archive_finished_pack 2>/dev/null)"
if [ -n "$afp" ]; then
  echo "$rw" | grep -q '_archive_finished_pack' && ok "run_pass_wave delegates disposal to _archive_finished_pack" || no "run_pass_wave does not call _archive_finished_pack (disposal unwired)"
  rw="$rw$afp"
fi
echo "$rw" | grep -q 'HAD_TIMEOUT=1' && ok "run_pass_wave (incl. disposal helper) sets HAD_TIMEOUT on a timeout park" || no "HAD_TIMEOUT never set"
echo "$rw" | grep -q '_timeout_kind' && ok "timeout park message keys off _timeout_kind (active vs wedged)" || no "park message still unconditionally WEDGED"

echo "== F6 behavioral: reconcile_parked_by_proof moves ONLY provably-landed parked packs =="
R2="$BASE/repo2"; mkdir -p "$R2"
( cd "$R2" && git init -q && git config user.email t@t && git config user.name t \
  && git symbolic-ref HEAD refs/heads/main && printf '.v/\n.worktrees/\n' > .gitignore \
  && echo base > f && git add -A && git commit -qm base ) >/dev/null 2>&1
SHA_MAIN="$(git -C "$R2" rev-parse HEAD)"
( cd "$R2" && git checkout -q -b side && echo s > s.f && git add -A && git commit -qm side && git checkout -q main ) >/dev/null 2>&1
SHA_SIDE="$(git -C "$R2" rev-parse side)"
REPO="$R2"; PACK_ABS="$BASE/packs2"; LOG_DIR="$PACK_ABS/.runlogs"; DONE_DIR="$PACK_ABS/.done"; NEEDS_DIR="$PACK_ABS/.needs-review"
mkdir -p "$LOG_DIR" "$DONE_DIR" "$NEEDS_DIR" "$R2/.v/artifacts"
SID_A="aaaa0001-1111-4222-8333-444455556666"; SID_B="aaaa0002-1111-4222-8333-444455556666"; SID_D="aaaa0004-1111-4222-8333-444455556666"
printf '/v landed pack\n' > "$NEEDS_DIR/pa.txt"
printf '{"type":"system","subtype":"task_started","session_id":"%s"}\n' "$SID_A" > "$LOG_DIR/pa.log"   # NO result event → fallback sid extraction
printf '%s\n' "$SHA_MAIN" > "$R2/.v/artifacts/commits-${SID_A}.txt"
printf '/v unlanded pack\n' > "$NEEDS_DIR/pb.txt"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":0,"session_id":"%s"}\n' "$SID_B" > "$LOG_DIR/pb.log"
printf '%s\n' "$SHA_SIDE" > "$R2/.v/artifacts/commits-${SID_B}.txt"                                    # NOT an ancestor of main
printf '/v witnessless pack\n' > "$NEEDS_DIR/pc.txt"
printf '{"type":"system","session_id":"aaaa0003-1111-4222-8333-444455556666"}\n' > "$LOG_DIR/pc.log"   # no commits-<sid>.txt at all
printf '/v rewritten pack\n' > "$NEEDS_DIR/pd.txt"
printf '{"type":"system","session_id":"%s"}\n' "$SID_D" > "$LOG_DIR/pd.log"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$R2/.v/artifacts/commits-${SID_D}.txt"          # unresolvable sha (history rewritten)
# AR-1 (adversarial review, HIGH): a parked pack whose BASENAME matches logs in TWO waves is ambiguous —
# `head -1` could attribute the wrong wave's session and move a still-unlanded pack. Must SKIP loudly.
SID_E="aaaa0005-1111-4222-8333-444455556666"
printf '/v collide pack\n' > "$NEEDS_DIR/pe.txt"
mkdir -p "$LOG_DIR/wave-1" "$LOG_DIR/wave-2"
printf '{"type":"system","session_id":"%s"}\n' "$SID_E" > "$LOG_DIR/wave-1/pe.log"          # landed sid…
printf '{"type":"system","session_id":"aaaa0006-1111-4222-8333-444455556666"}\n' > "$LOG_DIR/wave-2/pe.log"  # …vs a different session
printf '%s\n' "$SHA_MAIN" > "$R2/.v/artifacts/commits-${SID_E}.txt"
# AR-5: a witness fully on main but the SAME session still has an unmerged branch → NOT done yet.
SID_F="aaaa0007-1111-4222-8333-444455556666"
printf '/v openbranch pack\n' > "$NEEDS_DIR/pf.txt"
printf '{"type":"system","session_id":"%s"}\n' "$SID_F" > "$LOG_DIR/pf.log"
printf '%s\n' "$SHA_MAIN" > "$R2/.v/artifacts/commits-${SID_F}.txt"
( cd "$R2" && git branch "fix/still-open-${SID_F%%-*}" side ) >/dev/null 2>&1               # sid-matching branch, 1 commit ahead
reconcile_parked_by_proof > "$BASE/recon.out" 2>&1
[ -f "$DONE_DIR/pa.txt" ] && [ ! -f "$NEEDS_DIR/pa.txt" ] && ok "fully-landed pack reconciled → .done/ (sid via fallback extraction, no result event)" || no "landed pack not reconciled" "$(ls "$DONE_DIR" "$NEEDS_DIR" 2>/dev/null | tr '\n' ' ')"
[ -f "$NEEDS_DIR/pb.txt" ] && ok "non-ancestor witness → NOT moved (fail-closed)" || no "unlanded pack wrongly reconciled"
[ -f "$NEEDS_DIR/pc.txt" ] && ok "missing witness → NOT moved (fail-closed)" || no "witnessless pack wrongly reconciled"
[ -f "$NEEDS_DIR/pd.txt" ] && ok "unresolvable sha (rewritten history) → NOT moved (fail-closed)" || no "rewritten-history pack wrongly reconciled"
[ -f "$NEEDS_DIR/pe.txt" ] && grep -q 'cannot attribute' "$BASE/recon.out" && ok "AR-1: cross-wave basename collision → NOT moved, loud skip" || no "AR-1: ambiguous-attribution pack was moved or skipped silently" "$(cat "$BASE/recon.out")"
[ -f "$NEEDS_DIR/pf.txt" ] && ok "AR-5: same-session branch still ahead of main → NOT moved" || no "AR-5: pack reconciled while its session still has unmerged work"

echo "== AR-2/AR-3 wiring: VERIFY-pack timeout arms HAD_TIMEOUT; footer classifies against the LAST drain attempt =="
# PHASE 6 (2026-07-04): the VERIFY-pack block lives in _run_verify_pack (a main() skeleton helper) —
# pin BOTH links of the chain (main calls the helper; the helper arms HAD_TIMEOUT on a timeout verdict).
mn2="$(declare -f main 2>/dev/null)"
rv2="$(declare -f _run_verify_pack 2>/dev/null)"
printf '%s\n' "$mn2" | grep -q '_run_verify_pack' && ok "AR-2: main() calls _run_verify_pack (VERIFY runs last)" || no "AR-2: _run_verify_pack not wired into main()"
printf '%s\n' "$rv2" | grep -B3 'verify TIMEOUT' | grep -q 'HAD_TIMEOUT=1' && ok "AR-2: verify-pack timeout sets HAD_TIMEOUT (settle+re-drain armed for the heaviest pack)" || no "AR-2: verify-pack timeout does not arm HAD_TIMEOUT"
printf '%s\n' "$mn2" | grep -q '_drain_last' && ok "AR-3: footer verdicts read the LAST drain attempt (_drain_last), not the combined text" || no "AR-3: footer still classifies against combined drain output"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
