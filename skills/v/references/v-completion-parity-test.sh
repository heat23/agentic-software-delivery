#!/usr/bin/env bash
# v-completion-parity-test.sh — the "/v never lies about finishing" invariant.
#
# THE BUG THIS CATCHES (incident, 2026-06-15):
#   The /v orchestrator hand-authored an AGENT_REVIEW that *claimed*
#   "Dispatch mode: subagent-dispatched" with no DISPATCH_PROVENANCE and no
#   transcript codex signal. The producer-side gate (v-completion-selfcheck.sh)
#   ACCEPTED the claim (its W22-P2 check only challenged an artifact that
#   *confessed* to being inline), so /v reported "Bug fix complete … review PASS".
#   But the enforcement gate (check-review-artifact.sh _independence_verdict)
#   demands POSITIVE evidence of an independent dispatch and returned 'silent' →
#   BLOCK. Two code paths, two different rules → /v lied about finishing and the
#   Stop hook blocked it later.
#
# THE INVARIANT (the thing no prior test asserted):
#   For the SAME artifacts, the producer self-check must reach the SAME
#   accept/block decision on review- and QA-independence as the Stop hook.
#   selfcheck blocks  ⟺  stop hook blocks.   No disagreement is permitted.
#   (The existing v-completion-independence-test.sh / -qa-independence-test.sh
#    exercise each gate ALONE — they cannot see a disagreement, and one of them
#    even ENSHRINED the buggy behavior. This harness runs BOTH gates and compares.)
#
# Run: bash v-completion-parity-test.sh   (self-contained; isolated $HOME)
set -uo pipefail
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }

REAL_HOME="$HOME"
# Injection contract (audit 2026-06-18): BOTH gates must load the SAME (possibly mutant) lib so the
# mutation gate can prove _independence_verdict / _artifact_postdispatch_edited / the codex-forgery
# branch bite. $V_HOOK_OVERRIDE swaps the Stop-hook script; $V_SELFCHECK_OVERRIDE swaps the self-check
# script; $V_VALIDATION_LIB (forwarded into BOTH gates below) swaps the shared validation.sh they each
# source. Unset → live paths (zero prod-behavior change). The Stop hook now honors $V_VALIDATION_LIB /
# $V_HOOK_LIB_DIR; the self-check already honors $V_VALIDATION_LIB.
HOOK="${V_HOOK_OVERRIDE:-$REAL_HOME/.claude/hooks/check-review-artifact.sh}"
SELFCHK="${V_SELFCHECK_OVERRIDE:-$REAL_HOME/.claude/skills/v/references/v-completion-selfcheck.sh}"
[ -f "$HOOK" ] || { echo "SKIP: Stop hook not found"; exit 0; }
[ -f "$SELFCHK" ] || { echo "SKIP: self-check not found"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

BASE=$(mktemp -d /tmp/vparity.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
FHOME="$BASE/home"; mkdir -p "$FHOME/.claude/runtime" "$FHOME/.claude/projects/p"
ln -s "$REAL_HOME/.claude/hooks" "$FHOME/.claude/hooks"
[ -d "$REAL_HOME/.claude/agents" ] && ln -s "$REAL_HOME/.claude/agents" "$FHOME/.claude/agents"
[ -d "$REAL_HOME/.claude/skills" ] && ln -s "$REAL_HOME/.claude/skills" "$FHOME/.claude/skills"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PAD=$(printf 'x%.0s' $(seq 1 1300))   # clear every size floor

new_repo(){ local R="$BASE/$1"; mkdir -p "$R"; ( cd "$R" && git init -q && echo x>.keep && git add -A && git commit -qm init ) >/dev/null 2>&1; REPLY="$(cd "$R" && pwd -P)"; }
plant_v_history(){ printf '{"sessionId":"%s","display":"/v fix"}\n' "$1" >> "$FHOME/.claude/history.jsonl"; }
make_code_changed(){ local R="$1" sid="$2" b; b=$(cd "$R" && git rev-parse HEAD); mkdir -p "$R/.v/tmp"; printf '%s\n' "$b" > "$R/.v/tmp/head-baseline-${sid}.txt"; ( cd "$R" && mkdir -p src && echo 'export const x=1;' > src/foo.ts && git add -A && git commit -qm code ) >/dev/null 2>&1; }

valid_preflight(){ printf 'Model: haiku\nMode: scoped\n\n## Gates\n\n| PASS | TSC | ok |\n| PASS | Build | ok |\n| PASS | Full Test Suite (Pest) | 1200 passed |\n%s\nOverall Status: PASS\n' "$PAD" > "$1"; }
valid_verify_done(){ printf 'Model: haiku\n%s\n\n## Verify Done — %s\n\nOverall Verdict: PASS\n' "$PAD" "$2" > "$1"; }
valid_impact_map(){ printf 'Model: haiku\n%s\n\nsubsystems:\n- functional_flow\n\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\n' "$PAD" > "$1"; }
valid_qa_pass(){ printf 'Model: haiku\n\n## QA Acceptance — %s\n\nverdict: pass\n\n%s\n\nChecked the full acceptance surface; it holds.\n' "$2" "$PAD" > "$1"; }
# write_review $1 file  $2 sid  $3 Dispatch-mode VALUE  $4 Codex-reviewer VALUE
# Emits EVERY field validate_review_semantics(require_executed=1) demands, so the review is
# structurally valid (MISSING_REVIEW=0) and the Stop hook actually REACHES its C3b independence
# verdict. The ONLY per-fixture variables are the Dispatch-mode + Codex-reviewer values (and the
# DISPATCH_PROVENANCE/transcript signals planted separately).
write_review(){ printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: %s\n- Hostile adversarial focus: no\n- Dispatch mode: %s\n- Review evidence: findings: 0 — no issues found\n- Remediation: none required\n\nOverall: APPROVED\n\n%s\n' "$2" "$4" "$3" "$PAD" > "$1"; }

# Plant a transcript at the location BOTH gates resolve ($FHOME/.claude/projects/p/<sid>.jsonl).
# $3 = "codex" (subagent_type=codex) | "qa" (subagent_type=v-qa-reviewer) | "none".
plant_tx(){ local sid="$1" kind="${2:-none}" f="$FHOME/.claude/projects/p/$1.jsonl"
  case "$kind" in
    codex) printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"codex-adversarial-reviewer"}}]}}\n' > "$f" ;;
    qa)    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"v-qa-reviewer"}}]}}\n' > "$f" ;;
    *)     printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"working"}}\n' > "$f" ;;
  esac
  echo "$f"; }

run_stop(){ local repo="$1" sid="$2" tx="${3:-}" j
  j=$(jq -nc --arg s "$sid" --arg m "Done." --arg t "$tx" '{session_id:$s,last_assistant_message:$m,transcript_path:$t,stop_hook_active:false}')
  # env -i wipes the environment, so the mutant-lib override would never reach the hook unless
  # forwarded EXPLICITLY (audit 2026-06-18). Pass $V_VALIDATION_LIB / $V_HOOK_LIB_DIR through so the
  # injected mutant validation.sh is the one the Stop hook actually sources — defaulting to empty
  # (the hook then uses its live path), preserving the live parity run.
  ( cd "$repo" && env -i HOME="$FHOME" PATH="$PATH" HOOKS_LIB_DIR="$FHOME/.claude/hooks/lib" \
      V_VALIDATION_LIB="${V_VALIDATION_LIB:-}" V_HOOK_LIB_DIR="${V_HOOK_LIB_DIR:-}" \
      CLAUDE_PROJECT_DIR="$repo" bash "$HOOK" <<<"$j" 2>&1 ) || true; }
run_selfcheck(){ local repo="$1" sid="$2"
  # Forward $V_VALIDATION_LIB so the self-check loads the SAME mutant validation.sh the Stop hook does
  # (the self-check already honors it at its LIB= line). Default empty → live path. This is the other
  # half of the one-injection contract: a mutant that disables a shared primitive must flip BOTH gates.
  ( cd "$repo" && env HOME="$FHOME" CLAUDE_CONFIG_DIR="$FHOME/.claude" \
      V_VALIDATION_LIB="${V_VALIDATION_LIB:-}" \
      CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_SESSION_ID="$sid" bash "$SELFCHK" 2>&1 ) || true; }

# Decision extractors — each gate's OWN block phrasing (kept stable on both sides).
# FIX-6: the 'silent' BLOCK message now varies by cause (claimed-dispatch vs honest-inline) via the shared
# _independence_silent_reason helper — recognize BOTH wordings so a forged-claim block (F1/F2) is detected.
sc_blk_rev(){ printf '%s' "$1" | grep -qiE 'AGENT_REVIEW is an orchestrator-inline|orchestrator-inline / self-review with no independent dispatch|AGENT_REVIEW claims a dispatch mode|W22-P2[^b]'; }
hk_blk_rev(){ printf '%s' "$1" | grep -qiE 'appears to be an orchestrator-inline self-review|declares inline without documenting a superpowers|claims a dispatch mode'; }
sc_blk_qa(){  printf '%s' "$1" | grep -qiE 'no independent v-qa-reviewer dispatch|W22-P2b|tamper-evidence baseline'; }
hk_blk_qa(){  printf '%s' "$1" | grep -qiE 'QA_REPORT appears hand-authored|tamper-evidence baseline'; }

# Structural validation extractors — for N1/O2/bfallback fixtures that test validate_review_semantics
# structural paths (not independence paths). Checked separately from the independence extractors above.
# N1 (model header): pre-n1n2-bak rejects "claude-sonnet-4-6" with "review model must be one of"
sc_blk_n1(){     printf '%s' "$1" | grep -qiE 'AGENT_REVIEW invalid:.*review model must be|review model must be one of'; }
hk_blk_n1(){     printf '%s' "$1" | grep -qiE 'AGENT_REVIEW is not semantically valid.*review model must be|review model must be one of'; }
# O2 (allow_declared_degraded): pre-o2-bak fires "codex adversarial reviewer was skipped" on n/a lines
sc_blk_o2(){     printf '%s' "$1" | grep -qiE 'AGENT_REVIEW invalid:.*codex adversarial reviewer was skipped'; }
hk_blk_o2(){     printf '%s' "$1" | grep -qiE 'AGENT_REVIEW is not semantically valid.*codex adversarial reviewer was skipped'; }
# bfallback: pre-bfallback-bak returns "silent" → stop hook fires "orchestrator-inline self-review"; selfcheck fires W22-P2
sc_blk_bf(){     sc_blk_rev "$1"; }   # same as independence block (selfcheck uses W22-P2 for silent)
hk_blk_bf(){     hk_blk_rev "$1"; }   # same as independence block (hook uses "orchestrator-inline self-review")

# agree_structural: for structural-rejection fixtures. Checks that BOTH gates detect the structural block
# using the provided block-detector functions ($5=stop_blk_fn, $6=selfcheck_blk_fn). $4=expected(block|accept).
agree_structural(){ local lbl="$1" so="$2" sc="$3" want="$4" hk_fn="$5" sc_fn="$6" h s
  "$hk_fn" "$so" && h=block || h=accept
  "$sc_fn" "$sc" && s=block || s=accept
  if [ "$h" != "$want" ]; then no "$lbl :: SANITY — hook gave '$h', fixture expected '$want'"
  elif [ "$s" != "$h" ]; then no "$lbl :: DISAGREE — stop=$h selfcheck=$s  (← /v would lie about finishing)"
  else ok "$lbl :: parity ($h)"; fi; }

# Build a full, structurally-valid gauntlet artifact set whose ONLY variable is the
# review/QA independence signals. Returns repo path in REPLY.
build(){ # $1 reponame  $2 sid
  local name="$1" sid="$2"
  new_repo "$name"; local R="$REPLY"
  plant_v_history "$sid"; make_code_changed "$R" "$sid"
  valid_preflight    "$R/PRE_FLIGHT_REPORT_${sid}.md" "$R"
  valid_verify_done  "$R/VERIFY_DONE_REPORT_${sid}.md" "$sid"
  valid_impact_map   "$R/IMPACT_MAP_${sid}.md" "$sid"
  prov "$R" v-pre-flight-runner "PRE_FLIGHT_REPORT_${sid}.md" "$sid"   # isolate review/QA as the only independence variables
  REPLY="$R"
}
prov(){ printf 'DISPATCH|ts=2026-06-15T00:00:00Z|agent=%s|mode=self-write|status=ok|submodel=haiku|cost_usd=|duration_ms=|artifact=%s\n' "$2" "$3" >> "$1/DISPATCH_PROVENANCE_${4}.log"; }

# The Stop hook is the SOURCE OF TRUTH. Each check asserts (1) the self-check reaches the SAME
# accept/block decision as the hook (THE INVARIANT — /v can't claim done on what the gate blocks),
# and (2) a sanity expectation that the hook itself produced the intended verdict (so an
# under-specified fixture fails LOUDLY instead of passing vacuously). $4 = expected hook verdict.
agree_rev(){ local lbl="$1" so="$2" sc="$3" want="$4" h s
  hk_blk_rev "$so" && h=block || h=accept
  sc_blk_rev "$sc" && s=block || s=accept
  if [ "$h" != "$want" ]; then no "$lbl :: SANITY — hook gave '$h', fixture expected '$want' (fixture under-specified, not reaching C3b?)"
  elif [ "$s" != "$h" ]; then no "$lbl :: review DISAGREE — stop=$h selfcheck=$s  (← /v would lie about finishing)"
  else ok "$lbl :: review parity ($h)"; fi; }
agree_qa(){ local lbl="$1" so="$2" sc="$3" want="$4" h s
  hk_blk_qa "$so" && h=block || h=accept
  sc_blk_qa "$sc" && s=block || s=accept
  if [ "$h" != "$want" ]; then no "$lbl :: SANITY — hook gave '$h', fixture expected '$want' (fixture under-specified)"
  elif [ "$s" != "$h" ]; then no "$lbl :: QA DISAGREE — stop=$h selfcheck=$s  (← /v would lie about finishing)"
  else ok "$lbl :: QA parity ($h)"; fi; }

echo "== v-completion parity :: producer self-check ⟺ Stop hook (review + QA independence) =="

# ── F1: THE LIE — AGENT_REVIEW claims 'subagent-dispatched', no provenance, no signal ──
S=f1aaaaaa-1111-4111-8111-aaaaaaaaaaaa; build F1 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent-dispatched" "codex-adversarial-reviewer subagent-dispatched (claude_accepted: 1)"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"   # QA legit -> isolate review
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F1 fabricated 'subagent-dispatched'" "$SO" "$SC" block
agree_qa  "F1 (QA legit via provenance)"        "$SO" "$SC" accept

# ── F2: fabricated 'foreground codex ran', no provenance, no signal ──
S=f2bbbbbb-2222-4222-8222-bbbbbbbbbbbb; build F2 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "foreground" "ran via foreground codex exec; findings reviewed (claude_accepted: 1)"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F2 fabricated 'foreground codex ran'" "$SO" "$SC" block

# ── F3: REAL codex dispatch on record (DISPATCH_PROVENANCE status=ok) → accept ──
S=f3cccccc-3333-4333-8333-cccccccccccc; build F3 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent" "codex-adversarial-reviewer dispatched (claude_accepted: 1)"
prov "$R" codex-adversarial-reviewer "AGENT_REVIEW_${S}.md" "$S"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F3 real codex provenance"  "$SO" "$SC" accept
agree_qa  "F3 real v-qa provenance"   "$SO" "$SC" accept

# ── F4: B-2 FIX (forensic 2026-06-15, OPEN #1). 'Dispatch mode: orchestrator-inline' is the EXACT
#    format the Stop hook's own error text recommends, and _independence_verdict now recognizes the
#    FIELD (not only a line-start 'dispatch:'). With a documented superpowers attempt this is an HONEST
#    degraded fallback → 'declared' → ACCEPT (warn) on BOTH gates, exactly like F7. This assertion used
#    to expect BLOCK, which ENSHRINED the bug: the field-only format fell through to 'silent'. ──
S=f4dddddd-4444-4444-8444-dddddddddddd; build F4 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "orchestrator-inline (codex unsupported in worktree)" "superpowers:requesting-code-review fallback attempted; returned no findings"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F4 'Dispatch mode: orchestrator-inline' + superpowers attempt -> declared/ACCEPT (B-2)" "$SO" "$SC" accept

# ── F4b: NEGATIVE CONTROL — B-2 did NOT open a bypass. The SAME recognized 'Dispatch mode:
#    orchestrator-inline' FIELD but WITHOUT a documented superpowers attempt is 'declared' yet STILL
#    BLOCKS on BOTH gates (the N5 superpowers-attempt requirement governs the declared path).
#    Proves honesty is accepted only when the mandatory fallback chain was actually exercised. ──
S=f4bdddd4-4444-4444-8444-dddddddddddd; build F4b "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "orchestrator-inline (codex unsupported in worktree)" "codex-adversarial-reviewer (orchestrator-inline fallback — codex unsupported in worktree)"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F4b 'Dispatch mode: orchestrator-inline' WITHOUT superpowers -> declared/BLOCK (no bypass)" "$SO" "$SC" block

# ── F5: hand-authored QA verdict:pass, no provenance, no signal → block (QA side) ──
S=f5eeeeee-5555-4555-8555-eeeeeeeeeeee; build F5 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent" "codex-adversarial-reviewer dispatched (claude_accepted: 1)"
prov "$R" codex-adversarial-reviewer "AGENT_REVIEW_${S}.md" "$S"   # review legit -> isolate QA
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"                          # NO QA provenance, NO qa signal
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_qa  "F5 hand-authored QA verdict:pass"  "$SO" "$SC" block
agree_rev "F5 (review legit via provenance)"  "$SO" "$SC" accept

# ── F6: fabricated review BUT no transcript locatable → unverifiable. REVIEW side stays accept
#    (FP-safe: a real review the hook can't see must not be blocked). QA side BLOCKS under I1
#    (forensic review): verdict:pass + no transcript + NO sha baseline = zero tamper-evidence, so a
#    later fail->pass flip would be invisible — both gates fail-close in parity. (Baseline-present
#    unverifiable stays accept — see F6b.) ──
S=f6ffffff-6666-4666-8666-ffffffffffff; build F6 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent-dispatched" "codex-adversarial-reviewer (claude_accepted: 1)"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"                          # no QA provenance either
# deliberately DO NOT plant a transcript for this SID
SO=$(run_stop "$R" "$S" "$BASE/nope-${S}.jsonl"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F6 fabricated review, no transcript -> unverifiable -> accept" "$SO" "$SC" accept
agree_qa  "F6 hand QA, no transcript, NO baseline -> I1 fail-close (BLOCK)" "$SO" "$SC" block

# ── F6b: I1 NEGATIVE CONTROL — unverifiable (no transcript) BUT a tamper-evidence sha baseline IS on
#    record → both gates ACCEPT (warn). Proves I1 fail-closes only the ZERO-evidence corner and does not
#    over-block a session that recorded its QA sha (the FP-safety requirement). ──
S=f6b66666-6666-4666-8666-bbbbbbbbbbbb; build F6b "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent" "codex-adversarial-reviewer dispatched (claude_accepted: 1)"
prov "$R" codex-adversarial-reviewer "AGENT_REVIEW_${S}.md" "$S"   # review legit -> isolate QA
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"
# a tamper baseline for QA (status=ok sha256 line) — but still NO transcript planted
printf 'DISPATCH|ts=2026-06-15T00:00:00Z|agent=v-qa-reviewer|mode=agent-self|status=ok|submodel=haiku|cost_usd=0|duration_ms=0|artifact=QA_REPORT_%s.md|sha256=%s\n' \
  "$S" "$(shasum -a 256 "$R/QA_REPORT_${S}.md" | awk '{print $1}')" >> "$R/DISPATCH_PROVENANCE_${S}.log"
SO=$(run_stop "$R" "$S" "$BASE/nope-${S}.jsonl"); SC=$(run_selfcheck "$R" "$S")
agree_qa  "F6b unverifiable BUT sha baseline present -> accept (I1 FP-safe)" "$SO" "$SC" accept

# ── F7: POSITIVE CONTROL for the honest-declared path. A review that carries a machine-recognized
#    'dispatch: inline' declaration line (own line, no bullet) + a documented superpowers attempt is
#    an HONEST degraded fallback: the hook returns 'declared' → ACCEPT (warn). The fix must preserve
#    this — over-blocking honest fallbacks would also keep /v from finishing autonomously. ──
S=f7777777-7777-4777-8777-777777777777; build F7 "$S"; R="$REPLY"
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: superpowers:requesting-code-review fallback attempted; returned no findings\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator-inline (codex unavailable)\ndispatch: inline (forked context — codex unavailable in this worktree)\n- Review evidence: findings: 0 — no issues found\n- Remediation: none required\n\nOverall: APPROVED\n\n%s\n' "$S" "$PAD" > "$R/AGENT_REVIEW_${S}.md"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F7 honest 'dispatch: inline' + superpowers -> declared" "$SO" "$SC" accept

# ── F8: CODEX-001 (forensic worktree shape). The parent transcript is under project slug 'p',
#    but the SID's subagents/ tree (the REAL background-Agent codex dispatch) lives under a DIFFERENT slug
#    'wt' — agents dispatched while cwd=worktree are keyed to the worktree's project slug, not the parent's.
#    BOTH gates must SID-glob ALL slugs for the subtree; a parent-relative derivation (the pre-CODEX-001
#    Stop hook) misses the 'wt' subtree → the Stop gate BLOCKS a genuinely-reviewed worktree session while
#    the self-check (SID-glob) ACCEPTS → divergence → the cascade recurs at the Stop gate. ──
S=f8888888-8888-4888-8888-888888888888; build F8 "$S"; R="$REPLY"
write_review "$R/AGENT_REVIEW_${S}.md" "$S" "subagent" "codex-adversarial-reviewer dispatched (background Agent)"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)   # parent transcript under slug 'p' — signal-free
mkdir -p "$FHOME/.claude/projects/wt/$S/subagents"   # codex dispatch under a DIFFERENT slug 'wt'
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"codex-adversarial-reviewer"}}]}}\n' > "$FHOME/.claude/projects/wt/$S/subagents/agent-x.jsonl"
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_rev "F8 cross-slug worktree subtree (codex under a different slug) -> accept (CODEX-001 parity)" "$SO" "$SC" accept

# ── N1: full model-ID format accepted (audit 2026-06-19 backtest, 86%→100%). The N1/N2 fix
#    extended the ALLOWED_REVIEW_MODELS grep from bare-alias-only to accept the full
#    "claude-<alias>-<ver>" form. An AGENT_REVIEW with `Model: claude-sonnet-4-6` is ACCEPTED
#    by the current validation.sh but REJECTED by pre-n1n2-bak (bare-alias regex misses the
#    "claude-" prefix) → the fixture must pass both gates (parity=accept) and fail pre-bak alone.
#    BITE-PROVE: run this fixture against V_VALIDATION_LIB=pre-n1n2-bak → must FAIL (both gates
#    reject the model header) → restore current lib → PASS. ──
S=a1111111-1111-4111-8111-111111111111; build N1 "$S"; R="$REPLY"
# Model: claude-sonnet-4-6 — full model ID (N1 fix).
# Structural path: validate_review_semantics checks the Model: header on line 1.
# Current lib: "(claude-)?(haiku|sonnet|opus)([[:space:]_-]|$)" → "claude-sonnet-4-6" matches.
# Pre-n1n2-bak: "(haiku|sonnet|opus)([[:space:]]|$)" → "claude-sonnet-4-6" does NOT match → BLOCKS.
# Detected via: agree_structural with hk_blk_n1/sc_blk_n1 (structural model-header block).
printf 'Model: claude-sonnet-4-6\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: codex-adversarial-reviewer dispatched (claude_accepted: 1)\n- Hostile adversarial focus: no\n- Dispatch mode: subagent\n- Review evidence: findings: 0 — no issues found\n- Remediation: none required\n\nOverall: APPROVED\n\n%s\n' "$S" "$PAD" > "$R/AGENT_REVIEW_${S}.md"
prov "$R" codex-adversarial-reviewer "AGENT_REVIEW_${S}.md" "$S"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
# Use structural detectors: current lib → accept (N1 fix in place); pre-n1n2-bak → block.
agree_structural "N1 full model-ID 'claude-sonnet-4-6' accepted (N1/N2 structural parity)" "$SO" "$SC" accept hk_blk_n1 sc_blk_n1
agree_qa         "N1 (QA legit via provenance)"                                             "$SO" "$SC" accept

# ── O2: allow_declared_degraded opt-in path (audit 2026-06-19 backtest). The O2 fix adds the
#    5th param (allow_declared_degraded=1) to validate_review_semantics, which skips the codex-
#    provenance and codex-skipped checks when dispatch_line declares "orchestrator-inline". An
#    artifact with "Dispatch mode: orchestrator-inline (codex unavailable)" + "Codex adversarial
#    reviewer: n/a (codex unavailable)" is ACCEPTED by the current validation.sh (declared_degraded
#    path → codex n/a check bypassed) but REJECTED by pre-o2-bak (no allow_declared_degraded param
#    → _declared_degraded never set → n/a fires "codex adversarial reviewer was skipped"). The
#    _independence_verdict also returns "declared" (dispatch-mode recognized as inline) → accept.
#    BITE-PROVE: run this fixture against V_VALIDATION_LIB=pre-o2-bak → must FAIL → restore → PASS. ──
S=a2222222-2222-4222-8222-222222222222; build O2 "$S"; R="$REPLY"
# O2 fixture: codex line says "n/a" BUT also documents the superpowers:requesting-code-review attempt.
# Current: _declared_degraded=1 (dispatch=orchestrator-inline) → n/a check SKIPPED by allow_declared_degraded →
#   validate_review_semantics passes → _independence_verdict returns "declared" → N5: superpowers
#   attempt found (superpowers:requesting-code-review) → ACCEPT (warn).
# Pre-o2-bak: validate_review_semantics has no allow_declared_degraded → _declared_degraded never set
#   → n/a check fires ("(skipped|not applicable|\bn/?a\b)") → "codex adversarial reviewer was skipped" → BLOCK.
#   Never reaches _independence_verdict. That's the key difference: O2 moves the n/a gating
#   responsibility from validate_review_semantics (structural) to _independence_verdict (semantic).
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: n/a (codex unavailable; superpowers:requesting-code-review attempted, returned no skill found)\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator-inline (codex unavailable)\n- Review evidence: findings: 0 — no issues found\n- Remediation: none required\n\nOverall: APPROVED\n\n%s\n' "$S" "$PAD" > "$R/AGENT_REVIEW_${S}.md"
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
# Use structural detectors: current lib → accept (O2 fix in place); pre-o2-bak → block (n/a fired).
agree_structural "O2 allow_declared_degraded: orchestrator-inline + codex n/a + superpowers (O2 structural parity)" "$SO" "$SC" accept hk_blk_o2 sc_blk_o2
agree_qa         "O2 (QA legit via provenance)"                                                                      "$SO" "$SC" accept

# ── bfallback: B-FALLBACK path (audit 2026-06-19 backtest). The bfallback
#    fix adds _fallback_reviewer_dispatched() so a session that dispatched a REAL independent
#    sanctioned reviewer subagent (logic-reviewer, security-reviewer, etc.) when codex was
#    unavailable gets "dispatched" (accept) rather than "silent" (block). An artifact with
#    "Dispatch mode: subagent" + "Codex adversarial reviewer: codex-adversarial-reviewer
#    unavailable; logic-reviewer dispatched instead" is ACCEPTED by the current validation.sh
#    (_fallback_reviewer_dispatched finds logic-reviewer in DISPATCH_PROVENANCE → "dispatched")
#    but REJECTED by pre-bfallback-bak (no _fallback_reviewer_dispatched → B-2 declared check:
#    "subagent" ≠ inline/degraded/manual → "silent" → BLOCK).
#    BITE-PROVE: run this fixture against V_VALIDATION_LIB=pre-bfallback-bak → must FAIL → restore → PASS. ──
S=bf111111-1111-4111-8111-bf1bf1bf1bf1; build BFALLBACK "$S"; R="$REPLY"
# Codex line: codex-adversarial-reviewer is NAMED (passes validate_review_semantics codex provenance check)
# but no "ran" keyword (so forgery "codex : ran" check doesn't fire).
# Dispatch mode: subagent (not inline/degraded — so B-2 declared branch doesn't short-circuit).
# DISPATCH_PROVENANCE: logic-reviewer with status=ok (so _fallback_reviewer_dispatched returns 0).
printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: codex-adversarial-reviewer unavailable; logic-reviewer dispatched instead (claude_accepted: 1)\n- Hostile adversarial focus: no\n- Dispatch mode: subagent\n- Review evidence: findings: 0 — no issues found\n- Remediation: none required\n\nOverall: APPROVED\n\n%s\n' "$S" "$PAD" > "$R/AGENT_REVIEW_${S}.md"
prov "$R" logic-reviewer "AGENT_REVIEW_${S}.md" "$S"   # _fallback_reviewer_dispatched evidence
valid_qa_pass "$R/QA_REPORT_${S}.md" "$S"; prov "$R" v-qa-reviewer "QA_REPORT_${S}.md" "$S"
TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
# Independence detectors: current lib → _fallback_reviewer_dispatched finds logic-reviewer → "dispatched" → accept.
# Pre-bfallback-bak → no _fallback_reviewer_dispatched → "silent" → block (uses same hk_blk_rev/sc_blk_rev).
agree_rev "bfallback _fallback_reviewer_dispatched: logic-reviewer fallback accepted (B-FALLBACK parity)" "$SO" "$SC" accept
agree_qa  "bfallback (QA legit via provenance)"                                                           "$SO" "$SC" accept

# ── P7-B (review 2026-06-22): SUCCESS_CRITERIA / WORKFLOW_BLAST_RADIUS validate-if-present parity ──
# Step 1.7/1.6 artifacts are CONDITIONALLY produced (Feature/bug-fix+UI only). The gate must:
#   absent           -> BOTH accept  (no false-block on the legitimate-skip majority)
#   present+valid     -> BOTH accept
#   present+malformed -> BOTH block   (a >150B stub w/o the field-key silently narrows /v-tdd coverage)
# C1: wiring ONLY the Stop hook (not v-completion-selfcheck.sh) makes the selfcheck ACCEPT a malformed
# artifact the Stop hook BLOCKS -> /v lies about finishing. agree_structural catches the disagreement.
valid_sc(){ printf 'Model: haiku\n%s\n\ncriteria:\n- SC-1: empty state renders\n\nworkflow_states:\n- empty\n- error\n- concurrent\n' "$PAD" > "$1"; }
malformed_sc(){ printf 'Model: haiku\n%s\n\ncriteria:\n- SC-1: only the happy path (no state matrix)\n' "$PAD" > "$1"; }
valid_br(){ printf 'Model: haiku\n%s\n\nstates_to_verify:\n- empty\n- error\n- double_submit\n' "$PAD" > "$1"; }
malformed_br(){ printf 'Model: haiku\n%s\n\nsymptom-only fix, no sibling-state list\n' "$PAD" > "$1"; }
hk_blk_sc(){ printf '%s' "$1" | grep -qiE 'SUCCESS_CRITERIA present but malformed'; }
sc_blk_sc(){ printf '%s' "$1" | grep -qiE 'SUCCESS_CRITERIA present but malformed'; }
hk_blk_br(){ printf '%s' "$1" | grep -qiE 'WORKFLOW_BLAST_RADIUS present but malformed'; }
sc_blk_br(){ printf '%s' "$1" | grep -qiE 'WORKFLOW_BLAST_RADIUS present but malformed'; }
# build_pass: a fully-valid gauntlet ACCEPTING on both gates (review+QA via real provenance, mirrors F3)
# so the SC/BR artifact is the only variable the agree_structural detectors observe.
build_pass(){ local name="$1" sid="$2"; build "$name" "$sid"; local R="$REPLY"
  write_review "$R/AGENT_REVIEW_${sid}.md" "$sid" "subagent" "codex-adversarial-reviewer dispatched (claude_accepted: 1)"
  prov "$R" codex-adversarial-reviewer "AGENT_REVIEW_${sid}.md" "$sid"
  valid_qa_pass "$R/QA_REPORT_${sid}.md" "$sid"; prov "$R" v-qa-reviewer "QA_REPORT_${sid}.md" "$sid"
  REPLY="$R"; }

# SC absent -> accept (validate-if-present: absence is a legitimate skip)
S=5ca00000-0000-4000-8000-000000000001; build_pass SCABS "$S"; R="$REPLY"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "SC absent -> accept (validate-if-present)" "$SO" "$SC" accept hk_blk_sc sc_blk_sc
# SC present+valid -> accept
S=5ca00000-0000-4000-8000-000000000002; build_pass SCOK "$S"; R="$REPLY"; valid_sc "$R/SUCCESS_CRITERIA_${S}.md"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "SC present+valid -> accept" "$SO" "$SC" accept hk_blk_sc sc_blk_sc
# SC present+malformed -> block on BOTH (THE BITE + C1 parity)
S=5ca00000-0000-4000-8000-000000000003; build_pass SCBAD "$S"; R="$REPLY"; malformed_sc "$R/SUCCESS_CRITERIA_${S}.md"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "SC present+malformed -> block (parity: stop hook + selfcheck)" "$SO" "$SC" block hk_blk_sc sc_blk_sc

# BR absent -> accept
S=b4a00000-0000-4000-8000-000000000001; build_pass BRABS "$S"; R="$REPLY"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "BR absent -> accept (validate-if-present)" "$SO" "$SC" accept hk_blk_br sc_blk_br
# BR present+valid -> accept
S=b4a00000-0000-4000-8000-000000000002; build_pass BROK "$S"; R="$REPLY"; valid_br "$R/WORKFLOW_BLAST_RADIUS_${S}.md"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "BR present+valid -> accept" "$SO" "$SC" accept hk_blk_br sc_blk_br
# BR present+malformed -> block on BOTH
S=b4a00000-0000-4000-8000-000000000003; build_pass BRBAD "$S"; R="$REPLY"; malformed_br "$R/WORKFLOW_BLAST_RADIUS_${S}.md"; TX=$(plant_tx "$S" none)
SO=$(run_stop "$R" "$S" "$TX"); SC=$(run_selfcheck "$R" "$S")
agree_structural "BR present+malformed -> block (parity: stop hook + selfcheck)" "$SO" "$SC" block hk_blk_br sc_blk_br

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
