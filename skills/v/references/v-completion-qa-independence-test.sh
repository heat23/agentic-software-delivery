#!/usr/bin/env bash
# v-completion-qa-independence-test.sh — W22-P2b
#
# v-completion-selfcheck.sh must MIRROR the Stop hook's QA-independence gate: a QA_REPORT is OK
# iff v-qa-reviewer was dispatched (transcript subagent_type / v-dispatch-subagent.sh /
# DISPATCH_PROVENANCE status=ok) OR the report honestly declares a degraded/inline fallback. A
# hand-authored QA_REPORT with neither must FAIL the self-check — closing the producer↔Stop-gate
# disagreement that let W4-412's hand-authored QA pass the producer check. FP-safe: when
# the transcript can't be located, the verdict is 'unverifiable' and must NOT block.
set -u
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SELFCHK="${V_SELFCHECK_OVERRIDE:-$HOME/.claude/skills/v/references/v-completion-selfcheck.sh}"
ok()  { PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "$2"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

PAD=$(printf 'x%.0s' $(seq 1 1200))
SID="2b3c4d5e-2222-3333-4444-555566667777"

setup_repo() {  # $1=repo  $2=QA body
  local repo="$1" qa_body="$2" d
  mkdir -p "$repo/.v/artifacts"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
  d="$repo/.v/artifacts"
  printf 'Model: haiku\nMode: scoped\n## Gates\n| PASS | Tests | 10/0 |\n%s\nOverall Status: PASS\n' "$PAD" > "$d/PRE_FLIGHT_REPORT_${SID}.md"
  # AGENT_REVIEW: real foreground codex (no inline signature) so W22-P2 stays quiet.
  printf '## Agent Review\n- Status: completed\n- Codex adversarial reviewer: ran — foreground dispatch\n- Dispatch mode: foreground\nOverall: APPROVED\n%s\n' "$PAD" > "$d/AGENT_REVIEW_${SID}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$PAD" > "$d/VERIFY_DONE_REPORT_${SID}.md"
  printf 'Model: haiku\nsubsystems:\n- functional_flow\n%s\n' "$PAD" > "$d/IMPACT_MAP_${SID}.md"
  printf '%s\n' "$qa_body" > "$d/QA_REPORT_${SID}.md"
}

make_cfg() {  # $1=cfg dir  $2=plain|withqa
  local cfg="$1" kind="$2"
  mkdir -p "$cfg/projects/p"
  if [ "$kind" = withqa ]; then
    printf '{"type":"assistant","timestamp":"2026-06-03T02:00:00Z","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"v-qa-reviewer"}}]}}\n' > "$cfg/projects/p/$SID.jsonl"
  else
    printf '{"type":"user","timestamp":"2026-06-03T02:00:00Z","message":{"content":"hi"}}\n' > "$cfg/projects/p/$SID.jsonl"
  fi
}

run() { ( cd "$1" && CLAUDE_CONFIG_DIR="$2" CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_SESSION_ID="$SID" bash "$SELFCHK" 2>&1 ); }
W="W22-P2b|no independent v-qa-reviewer dispatch"
# Structurally VALID QA (Model + '## QA Acceptance' + verdict: pass) so validate_qa_report_structure
# yields verdict:pass and the verdict-scoped independence check is reached (mirrors the Stop hook,
# which scopes QA independence to MISSING_QA=0 && verdict==pass).
QA_PLAIN="$(printf 'Model: haiku\n\n## QA Acceptance\n\nverdict: pass\n%s' "$PAD")"

echo "== v-completion-selfcheck :: W22-P2b producer-side QA independence =="

# T1 — hand-authored QA, transcript present w/o v-qa-reviewer, no provenance, no declaration -> FIRE
R1="$TMP/r1"; setup_repo "$R1" "$QA_PLAIN"; C1="$TMP/c1"; make_cfg "$C1" plain
if run "$R1" "$C1" | grep -qiE "$W"; then ok "T1 hand-authored QA (transcript, no dispatch) FAILS"; else bad "T1" "silent hand-authored QA not caught"; fi

# T2 — QA + v-qa-reviewer DISPATCH_PROVENANCE status=ok -> accept
R2="$TMP/r2"; setup_repo "$R2" "$QA_PLAIN"; C2="$TMP/c2"; make_cfg "$C2" plain
printf 'DISPATCH|agent=v-qa-reviewer|mode=foreground|status=ok\n' > "$R2/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
if run "$R2" "$C2" | grep -qiE "$W"; then bad "T2" "W22-P2b fired despite v-qa-reviewer provenance"; else ok "T2 v-qa-reviewer provenance -> accepted"; fi

# T3 — QA + transcript subagent_type=v-qa-reviewer (Agent-tool dispatch) -> accept
R3="$TMP/r3"; setup_repo "$R3" "$QA_PLAIN"; C3="$TMP/c3"; make_cfg "$C3" withqa
if run "$R3" "$C3" | grep -qiE "$W"; then bad "T3" "W22-P2b fired despite transcript v-qa-reviewer dispatch"; else ok "T3 transcript v-qa-reviewer dispatch -> accepted"; fi

# T4 — QA honestly declares a degraded fallback -> accept
R4="$TMP/r4"; setup_repo "$R4" "$(printf 'Model: haiku\n\n## QA Acceptance\ndispatch: degraded\ndegraded_reason: no agent runtime\nverdict: pass\n%s' "$PAD")"; C4="$TMP/c4"; make_cfg "$C4" plain
if run "$R4" "$C4" | grep -qiE "$W"; then bad "T4" "W22-P2b fired despite honest degraded declaration"; else ok "T4 declared degraded -> accepted"; fi

# T5 — transcript not locatable -> unverifiable -> accept (FP-safe)
R5="$TMP/r5"; setup_repo "$R5" "$QA_PLAIN"; C5="$TMP/c5-empty"; mkdir -p "$C5/projects"
if run "$R5" "$C5" | grep -qiE "$W"; then bad "T5" "W22-P2b false-positive when transcript unavailable"; else ok "T5 no transcript -> unverifiable -> accepted"; fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
