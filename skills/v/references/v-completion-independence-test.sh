#!/usr/bin/env bash
# v-completion-independence-test.sh — W22-P2 (review independence), single-sourced.
#
# v-completion-selfcheck.sh's review-independence decision is now made by the SHARED
# hooks/lib/validation.sh `_independence_verdict` — the SAME function the Stop hook calls — so the
# producer self-check and the Stop gate cannot disagree (production incident: a fabricated AGENT_REVIEW
# claiming "Dispatch mode: subagent-dispatched" with no dispatch evidence passed the OLD self-check's
# inline-signature regex while the Stop hook blocked it as 'silent' → /v lied about finishing).
#
# This harness asserts the self-check reaches the verdict the Stop hook would, in isolation:
#   silent (claimed/implied dispatch, no evidence, transcript readable) -> BLOCK
#   dispatched (DISPATCH_PROVENANCE or transcript subagent_type)        -> accept
#   declared + documented superpowers attempt                          -> accept
#   unverifiable (no transcript located)                               -> accept (FP-safe)
# Cross-gate parity with the REAL Stop hook is locked separately by v-completion-parity-test.sh.
set -u
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SELFCHK="${V_SELFCHECK_OVERRIDE:-$HOME/.claude/skills/v/references/v-completion-selfcheck.sh}"
ok()  { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PAD=$(printf 'x%.0s' $(seq 1 1200))   # exceed any size floor
SID="1a2b3c4d-1111-2222-3333-444455556666"

# Full gauntlet artifact set; $1=repo, $2=AGENT_REVIEW body. QA is made independent (provenance)
# so REVIEW independence is the ONLY variable under test.
setup_repo() {
  local repo="$1" review_body="$2" d
  mkdir -p "$repo/.v/artifacts"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
  d="$repo/.v/artifacts"
  printf 'Model: haiku\nMode: scoped\n## Gates\n| PASS | Tests | 10/0 |\n%s\nOverall Status: PASS\n' "$PAD" > "$d/PRE_FLIGHT_REPORT_${SID}.md"
  printf '%s\n%s\n' "$review_body" "$PAD" > "$d/AGENT_REVIEW_${SID}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$PAD" > "$d/VERIFY_DONE_REPORT_${SID}.md"
  printf 'Model: haiku\nsubsystems:\n- functional_flow\nreporting_metrics: n/a\ncache_invalidation: n/a\ndb_integrity: n/a\n%s\n' "$PAD" > "$d/IMPACT_MAP_${SID}.md"
  printf 'Model: haiku\n\n## QA Acceptance\nverdict: pass\n%s\n' "$PAD" > "$d/QA_REPORT_${SID}.md"
  printf 'DISPATCH|ts=2026-06-15T00:00:00Z|agent=v-qa-reviewer|mode=self-write|status=ok|artifact=QA_REPORT_%s.md\n' "$SID" > "$d/DISPATCH_PROVENANCE_${SID}.log"
}
# plant a transcript so TRANSCRIPT_READABLE=1; $2 = "codex" (subagent_type) | "none"
make_cfg() {
  local cfg="$1" kind="$2"; mkdir -p "$cfg/projects/p"
  if [ "$kind" = codex ]; then
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"codex-adversarial-reviewer"}}]}}\n' > "$cfg/projects/p/$SID.jsonl"
  elif [ "$kind" = codex_subtree ]; then
    # O1 (forensic): a BACKGROUND Agent dispatch records its subagent_type ONLY in the
    # session's subagents/ tree, NOT the parent transcript. The parent stays signal-free.
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"work"}}\n' > "$cfg/projects/p/$SID.jsonl"
    mkdir -p "$cfg/projects/p/$SID/subagents"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"codex-adversarial-reviewer"}}]}}\n' > "$cfg/projects/p/$SID/subagents/agent-aaa111.jsonl"
  elif [ "$kind" = security ]; then
    # B-FALLBACK (forensic 2026-06-16): codex CLI unavailable → a REAL hostile security-reviewer (the
    # sanctioned superpowers/Agent-tool fallback per CLAUDE.md) ran; its subagent_type lands in the parent.
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"security-reviewer"}}]}}\n' > "$cfg/projects/p/$SID.jsonl"
  elif [ "$kind" = security_subtree ]; then
    # B-FALLBACK + O1: the fallback security-reviewer ran as a BACKGROUND Agent → subagent_type lands ONLY
    # in the subagents/ tree (parent stays signal-free), exactly like T3c's background codex.
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"work"}}\n' > "$cfg/projects/p/$SID.jsonl"
    mkdir -p "$cfg/projects/p/$SID/subagents"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"security-reviewer"}}]}}\n' > "$cfg/projects/p/$SID/subagents/agent-bbb222.jsonl"
  else
    printf '{"type":"assistant","message":{"model":"claude-sonnet-4-6","content":"work"}}\n' > "$cfg/projects/p/$SID.jsonl"
  fi
}
add_codex_prov() { printf 'DISPATCH|ts=2026-06-15T00:00:00Z|agent=codex-adversarial-reviewer|mode=foreground|status=ok\n' >> "$1/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"; }
# Injection contract (audit 2026-06-18): $V_VALIDATION_LIB is forwarded into the self-check (which
# honors it at its LIB= line) so the mutation gate can inject a mutant validation.sh and prove the
# codex-forgery branch bites — removing it lets a forged 'codex … ran' claim laundered behind a real
# fallback dispatch (T8) through. Default (unset) → live lib, zero behavior change.
run() { ( cd "$1" && CLAUDE_CONFIG_DIR="$2" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" \
          V_VALIDATION_LIB="${V_VALIDATION_LIB:-}" bash "$SELFCHK" 2>&1 ); }
W="W22-P2|orchestrator-inline / self-review with no independent dispatch"

echo "== v-completion-selfcheck :: W22-P2 review independence (single-sourced _independence_verdict) =="

# T1 — bare orchestrator-inline, NO superpowers, NO provenance, transcript readable -> silent -> BLOCK
R="$TMP/t1"; C="$TMP/c1"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: codex-adversarial-reviewer (orchestrator-inline fallback — codex unsupported)\n- Dispatch mode: orchestrator_inline\nOverall: APPROVED')"
make_cfg "$C" none
if run "$R" "$C" | grep -qiE "$W"; then ok "T1 bare orchestrator-inline (transcript, no dispatch) -> BLOCK"; else bad "T1" "silent inline review not caught"; fi

# T2 — orchestrator-inline BUT documents a superpowers fallback ATTEMPT -> declared -> accept
R="$TMP/t2"; C="$TMP/c2"
# NB: the machine-recognized declaration is a line-start 'dispatch:'/'degraded_reason:' (NO bullet),
# same as the Stop hook's _independence_verdict regex — a bulleted '- dispatch:' is NOT recognized.
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: orchestrator-inline fallback; superpowers:requesting-code-review attempted (returned no findings)\ndispatch: inline (codex unavailable)\nOverall: APPROVED')"
make_cfg "$C" none
if run "$R" "$C" | grep -qiE "$W"; then bad "T2" "declared+superpowers wrongly blocked"; else ok "T2 declared inline + superpowers attempt -> accepted"; fi

# T3 — codex DISPATCH_PROVENANCE status=ok -> dispatched -> accept
R="$TMP/t3"; C="$TMP/c3"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: codex-adversarial-reviewer dispatched\n- Dispatch mode: subagent\nOverall: APPROVED')"
add_codex_prov "$R"; make_cfg "$C" none
if run "$R" "$C" | grep -qiE "$W"; then bad "T3" "codex provenance wrongly blocked"; else ok "T3 codex DISPATCH_PROVENANCE -> accepted"; fi

# T3b — codex dispatch via transcript subagent_type -> dispatched -> accept
R="$TMP/t3b"; C="$TMP/c3b"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: codex-adversarial-reviewer dispatched (Agent tool)\n- Dispatch mode: subagent\nOverall: APPROVED')"
make_cfg "$C" codex
if run "$R" "$C" | grep -qiE "$W"; then bad "T3b" "transcript codex dispatch wrongly blocked"; else ok "T3b transcript subagent_type=codex -> accepted"; fi

# T3c — O1 (forensic): codex dispatched as a BACKGROUND Agent → subagent_type lands ONLY in the
# session's subagents/ tree, not the parent transcript. The independence scan must read the subagents tree;
# otherwise a genuinely-independent reviewer reads as 'silent' and the gate forces a false 'degraded-inline'
# declaration + hand-authored artifacts (the entire cascade).
R="$TMP/t3c"; C="$TMP/c3c"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: codex-adversarial-reviewer dispatched (background Agent)\n- Dispatch mode: subagent\nOverall: APPROVED')"
make_cfg "$C" codex_subtree
if run "$R" "$C" | grep -qiE "$W"; then bad "T3c" "background-Agent subagent_type in subagents/ tree NOT detected (O1 gap)"; else ok "T3c subagents-tree subagent_type=codex -> accepted (O1 fix)"; fi

# T4 — RECLASSIFIED (this assertion used to ENSHRINE the bug): a forged 'foreground codex ran' claim
# with NO provenance and a readable transcript is 'silent' at the Stop hook, so it MUST block here too.
R="$TMP/t4"; C="$TMP/c4"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: ran — codex exec, foreground dispatch, findings reviewed\n- Dispatch mode: foreground\nOverall: APPROVED')"
make_cfg "$C" none
if run "$R" "$C" | grep -qiE "$W"; then ok "T4 forged 'foreground codex ran' (no provenance) -> BLOCK"; else bad "T4" "forged foreground-codex claim NOT caught (the old T4 hole — /v would lie)"; fi

# T5 — genuine UNVERIFIABLE: a positive dispatch CLAIM with NO provenance and NO transcript locatable
# -> unverifiable -> accept (FP-safe, mirrors the Stop hook). Contrast T6: the SAME claim WITH a
# readable transcript is 'silent' -> BLOCK, so transcript presence is what flips can't-verify into
# caught. (B-2: an honest 'Dispatch mode: orchestrator-inline' FIELD is now a RECOGNIZED declaration —
# consistent with the 'dispatch: inline' line format — so that path is covered by T1 (no superpowers ->
# block) and T2 (superpowers attempt -> accept), and transcript-absence no longer launders it. This
# fixture therefore uses a bare dispatch CLAIM, the true source of an 'unverifiable' verdict.)
R="$TMP/t5"; C="$TMP/c5-empty"; mkdir -p "$C/projects"
setup_repo "$R" "$(printf '## Agent Review\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: codex-adversarial-reviewer subagent-dispatched (claude_accepted: 1)\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED')"
if run "$R" "$C" | grep -qiE "$W"; then bad "T5" "false-positive when transcript unavailable"; else ok "T5 dispatch claim, no transcript -> unverifiable -> accepted"; fi

# T6 — INCIDENT regression: fabricated 'Dispatch mode: subagent-dispatched' (a positive
# dispatch CLAIM) with no evidence + readable transcript -> silent -> BLOCK. The old inline-signature
# self-check accepted this exact artifact; the single-sourced verdict catches it.
R="$TMP/t6"; C="$TMP/c6"
setup_repo "$R" "$(printf '## Agent Review\n- Agents dispatched: logic-reviewer\n- Codex adversarial reviewer: codex-adversarial-reviewer subagent-dispatched (claude_accepted: 1)\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED')"
make_cfg "$C" none
if run "$R" "$C" | grep -qiE "$W"; then ok "T6 incident 'subagent-dispatched' fabrication -> BLOCK"; else bad "T6" "the 'subagent-dispatched' fabrication slipped through (regression)"; fi

# T7 — B-FALLBACK (forensic 2026-06-16): codex CLI UNAVAILABLE → the session dispatched a
# REAL hostile security-reviewer (the sanctioned superpowers/Agent-tool fallback per CLAUDE.md). That
# subagent_type=security-reviewer signal IS a genuine independent review of THIS diff → 'dispatched' →
# accept. Pre-fix the gate credited ONLY subagent_type=codex-adversarial-reviewer, so this HONEST fallback
# false-BLOCKED and the model laundered it into a fake 'Dispatch mode: manual'. NOTE: T6 above
# (same 'subagent-dispatched' claim but NO real fallback in the transcript) MUST still block — the
# discriminator is the real transcript signal, not the artifact prose.
R="$TMP/t7"; C="$TMP/c7"
setup_repo "$R" "$(printf '## Agent Review\n- Agents dispatched: security-reviewer (hostile adversarial)\n- Codex adversarial reviewer: codex-adversarial-reviewer CLI unavailable; superpowers:requesting-code-review fallback — security-reviewer subagent dispatched\n- Hostile adversarial focus: yes\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED')"
make_cfg "$C" security
if run "$R" "$C" | grep -qiE "$W"; then bad "T7" "real security-reviewer fallback (codex unavailable) wrongly BLOCKED — the false-block that taught the model to launder via 'manual'"; else ok "T7 honest security-reviewer fallback (transcript subagent_type) -> dispatched -> accepted"; fi

# T7b — same as T7 but the fallback reviewer ran as a BACKGROUND Agent → subagent_type lands ONLY in the
# subagents/ tree (parity with T3c). Must still be credited.
R="$TMP/t7b"; C="$TMP/c7b"
setup_repo "$R" "$(printf '## Agent Review\n- Agents dispatched: security-reviewer (background)\n- Codex adversarial reviewer: codex unavailable; superpowers fallback — security-reviewer Agent dispatched (background)\n- Hostile adversarial focus: yes\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED')"
make_cfg "$C" security_subtree
if run "$R" "$C" | grep -qiE "$W"; then bad "T7b" "background security-reviewer in subagents/ tree NOT credited (O1-parity gap for the fallback path)"; else ok "T7b subagents-tree security-reviewer fallback -> accepted"; fi

# T8 — ORDERING SAFETY (forgery detector preserved): a FORGED 'codex … ran' claim must STILL block even
# when a real fallback reviewer WAS dispatched — the forgery/wrong-tree 'silent' checks are ordered BEFORE
# the B-FALLBACK credit, so a false 'codex ran' cannot be laundered behind a real security-reviewer run.
# The model must drop the false claim (→ T7's honest path then passes). Recoverable, not a dead-end.
R="$TMP/t8"; C="$TMP/c8"
setup_repo "$R" "$(printf '## Agent Review\n- Codex adversarial reviewer: ran — codex exec foreground, findings reviewed\n- Hostile adversarial focus: yes\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED')"
make_cfg "$C" security
if run "$R" "$C" | grep -qiE "$W"; then ok "T8 forged 'codex ran' + real fallback dispatch -> STILL BLOCK (honest-label required; forgery detector intact)"; else bad "T8" "forged 'codex ran' laundered behind a real security-reviewer dispatch (B-FALLBACK ordered before forgery — ordering hole)"; fi

# ── FIX-6 (self-audit survivor): _independence_silent_reason classifies WHY a review is 'silent' so the
#    Stop hook and the self-check print the SAME, clearer remediation message (parity by single-sourcing).
#    The verdict itself stays 'silent' (=BLOCK) — only the wording differs. Unit-test the shared helper.
LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/validation.sh"
if [ -f "$LIB" ]; then
  # shellcheck source=/dev/null
  . "$LIB"
  if type _independence_silent_reason >/dev/null 2>&1; then
    # F6a — a FORGED dispatch CLAIM (subagent-dispatched, no provenance) → 'claimed-dispatch'
    f="$TMP/f6a.md"; printf 'Model: haiku\n## Agent Review\n- Dispatch mode: subagent-dispatched\nOverall: APPROVED\n' > "$f"
    r=$(_independence_silent_reason "$f")
    [ "$r" = "claimed-dispatch" ] && ok "F6a 'Dispatch mode: subagent-dispatched' -> claimed-dispatch" || bad "F6a" "expected claimed-dispatch, got '$r'"

    # F6a2 — a forged 'codex … ran' assertion → 'claimed-dispatch'
    f="$TMP/f6a2.md"; printf 'Model: haiku\n## Agent Review\n- Codex adversarial reviewer: ran — foreground\nOverall: APPROVED\n' > "$f"
    r=$(_independence_silent_reason "$f")
    [ "$r" = "claimed-dispatch" ] && ok "F6a2 'codex … ran' -> claimed-dispatch" || bad "F6a2" "expected claimed-dispatch, got '$r'"

    # F6a3 — a decorated/blockquoted dispatch CLAIM ('> Dispatch mode: foreground') still classifies
    f="$TMP/f6a3.md"; printf 'Model: haiku\n## Agent Review\n> Dispatch mode: foreground\nOverall: APPROVED\n' > "$f"
    r=$(_independence_silent_reason "$f")
    [ "$r" = "claimed-dispatch" ] && ok "F6a3 decorated '> Dispatch mode: foreground' -> claimed-dispatch" || bad "F6a3" "expected claimed-dispatch, got '$r'"

    # F6b — an honest inline review with NO dispatch claim → 'honest-inline' (the FP-safe default)
    f="$TMP/f6b.md"; printf 'Model: haiku\n## Agent Review\n- Reviewed the diff inline.\nOverall: APPROVED\n' > "$f"
    r=$(_independence_silent_reason "$f")
    [ "$r" = "honest-inline" ] && ok "F6b no dispatch claim -> honest-inline (FP-safe default)" || bad "F6b" "expected honest-inline, got '$r'"

    # F6c — an explicit honest orchestrator-inline declaration is NOT a forged claim → 'honest-inline'
    f="$TMP/f6c.md"; printf 'Model: haiku\n## Agent Review\n- Dispatch mode: orchestrator-inline (codex unavailable)\nOverall: APPROVED\n' > "$f"
    r=$(_independence_silent_reason "$f")
    [ "$r" = "honest-inline" ] && ok "F6c 'Dispatch mode: orchestrator-inline (reason)' -> honest-inline" || bad "F6c" "expected honest-inline, got '$r'"

    # F6d — PARITY: BOTH consumers reference the shared helper, so neither hard-codes the distinction.
    SC="$HOME/.claude/skills/v/references/v-completion-selfcheck.sh"
    CRA="$HOME/.claude/hooks/check-review-artifact.sh"
    if grep -q '_independence_silent_reason' "$SC" 2>/dev/null && grep -q '_independence_silent_reason' "$CRA" 2>/dev/null; then
      ok "F6d both consumers (self-check + Stop hook) call _independence_silent_reason (parity)"
    else
      bad "F6d" "a consumer does not call _independence_silent_reason -> parity drift risk"
    fi

    # ── H1 (audit 2026-06-18): codex hand-rolled-path PROXY files must bind to REAL content, not a
    #    touch/empty forgery. Pre-fix _agent_was_dispatched credited any proxy by `[ -f ]` (existence),
    #    so a 0-byte `touch codex-review-<sid>.log` (writable same-uid) laundered an orchestrator
    #    self-review past the independence gate (confirmed by live repro). Unit-test the proxy path.
    if type _proxy_file_has_content >/dev/null 2>&1 && type _agent_was_dispatched >/dev/null 2>&1; then
      H1DIR="$TMP/h1/.v/artifacts"; mkdir -p "$H1DIR"
      SESSION_ID="$SID"; ARTIFACT_SEARCH_DIRS=("$H1DIR"); TRANSCRIPT_READABLE=0; _TX_SIGNALS=""
      : > "$H1DIR/codex-review-${SID}.log"   # 0-byte forgery
      if _agent_was_dispatched "codex-adversarial-reviewer"; then bad "H1a" "empty 0-byte codex-review proxy still credited as dispatched (the confirmed forgery hole)"; else ok "H1a empty 0-byte proxy -> NOT dispatched"; fi
      rm -f "$H1DIR/codex-review-${SID}.log"
      printf 'diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new\n' > "$H1DIR/review-diff-${SID}.patch"
      if _agent_was_dispatched "codex-adversarial-reviewer"; then ok "H1b real review-diff (diff content) -> dispatched (FP-safe: legit proxy still works)"; else bad "H1b" "legitimate review-diff proxy wrongly rejected"; fi
      rm -f "$H1DIR/review-diff-${SID}.patch"
      printf 'this is not a diff\n' > "$H1DIR/review-diff-${SID}.patch"
      if _agent_was_dispatched "codex-adversarial-reviewer"; then bad "H1c" "non-diff review-diff stub credited as dispatched"; else ok "H1c non-diff review-diff stub -> NOT dispatched"; fi
      rm -f "$H1DIR/review-diff-${SID}.patch"
      printf 'codex review: reviewed 3 files, no findings.\n' > "$H1DIR/codex-review-${SID}.log"
      if _agent_was_dispatched "codex-adversarial-reviewer"; then ok "H1d non-empty codex-review log -> dispatched (no size FP on terse logs)"; else bad "H1d" "non-empty codex log wrongly rejected"; fi
    else
      bad "H1" "_proxy_file_has_content / _agent_was_dispatched not defined in validation.sh"
    fi
  else
    bad "F6" "_independence_silent_reason not defined in validation.sh"
  fi
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
