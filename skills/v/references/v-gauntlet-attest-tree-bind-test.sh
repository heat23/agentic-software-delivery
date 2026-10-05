#!/usr/bin/env bash
# v-gauntlet-attest-tree-bind-test.sh — ATTEST-TREE-BIND class (forensic 2026-07-04).
#
# The gauntlet witness binds artifact CONTENT (sha256) but NOT the source tree the gauntlet graded.
# A production session attested, THEN a QA-found HIGH bug was fixed + committed — artifacts unchanged, witness
# still verified, remediation shipped review-unseen. The attest witness must now record the graded
# tracked-tree hash so the Stop hook can detect a post-attest source edit. Proves:
#   T1: attest writes a non-empty `attested_tree` matching the tracked working-tree hash.
#   T2: committing the EXACT attested tree leaves current-tree == attested_tree (normal flow, no stale).
#   T3: editing a source file AFTER attest makes current-tree != attested_tree (the observed bug).
#   T4: the Stop-hook comparison method (stash-create-or-HEAD) is content-addressed and consistent.
#   T5 (red fixture): the pre-fix attest writes NO attested_tree field.
#   T6: in a repo with no commits, attest signs an EMPTY tree rather than the literal `HEAD^{tree}`
#       that `git rev-parse` prints back (which would read as STALE after the first commit).
#   T7: a project root containing `"` and `\` is JSON-escaped, so the signed root comes back from
#       `jq -r` byte for byte instead of corrupting the witness.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ATTEST="$HERE/v-gauntlet-attest.sh"; ATTEST_BAK="$HERE/v-gauntlet-attest.sh.pre-treebind0704-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq"; exit 0; }
[ -f "$HOME/.claude/hooks/lib/gauntlet-witness.sh" ] || { echo "SKIP: gauntlet-witness.sh"; exit 0; }

SID="deadd00d-1111-4222-8333-000000000001"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
( cd "$TD" && git init -q -b main && echo base > app.php && G add -A && G commit -qm base ) >/dev/null 2>&1
mkdir -p "$TD/.v/tmp"
pad="$(printf 'x%.0s' $(seq 1 220))"
mk_artifacts(){
  local TD="${1:-$TD}"
  printf 'Model: haiku\nStatus: PASS\n## Gates\n%s\n' "$pad" > "$TD/PRE_FLIGHT_REPORT_${SID}.md"
  printf 'Model: haiku\nOverall Verdict: PASS\n%s\n' "$pad" > "$TD/VERIFY_DONE_REPORT_${SID}.md"
  printf 'Model: haiku\n\n## Agent Review — %s\n\n- Status: completed\n- Agents dispatched: none\n- Codex adversarial reviewer: none\n- Hostile adversarial focus: no\n- Dispatch mode: orchestrator_inline\n- Review evidence: No issues found\n- Remediation: no findings\n\n## Findings\n\nNone.\n%s\n' "$SID" "$pad" > "$TD/AGENT_REVIEW_${SID}.md"
}
attest(){ local TD="${2:-$TD}"; ( cd "$TD" && CLAUDE_SESSION_ID="$SID" PROJECT_ROOT="$TD" V_TMP_DIR="$TD/.v/tmp" bash "$1" "$SID" >/dev/null 2>&1 ); }
WIT="$HOME/.claude/runtime/v-gauntlet-attestation-${SID}.json"
# tree hash via the SAME stash-create-or-HEAD method the hook uses
tree_now(){ local s; s="$(git -C "$TD" stash create 2>/dev/null || true)"; [ -n "$s" ] && git -C "$TD" rev-parse "${s}^{tree}" 2>/dev/null || git -C "$TD" rev-parse 'HEAD^{tree}' 2>/dev/null; }

# ── T1: uncommitted source edit graded → attested_tree recorded ──
rm -f "$WIT"
( cd "$TD" && echo "feature" > feature.php && G add feature.php ) >/dev/null 2>&1   # staged, uncommitted
mk_artifacts
attest "$ATTEST"
WT="$(jq -r '.attested_tree // empty' "$WIT" 2>/dev/null || true)"
if [ -n "$WT" ] && [ "$WT" = "$(tree_now)" ]; then
  ok "T1 witness records attested_tree == the current tracked tree hash ($WT)"
else
  no "T1 attested_tree missing or mismatched" "witness=$WT current=$(tree_now)"
fi

# ── T2: commit EXACTLY the attested tree → current tree still == attested (normal flow) ──
( cd "$TD" && G commit -qm feat ) >/dev/null 2>&1
if [ "$(tree_now)" = "$WT" ]; then
  ok "T2 committing the graded tree leaves current-tree == attested_tree (no false stale in the normal flow)"
else
  no "T2 normal commit flow diverged" "current=$(tree_now) attested=$WT"
fi

# ── T3: a post-attest SOURCE edit diverges the tree (the observed bug) ──
( cd "$TD" && echo "qa-fix" >> feature.php && G add feature.php && G commit -qm "post-attest QA fix" ) >/dev/null 2>&1
if [ "$(tree_now)" != "$WT" ]; then
  ok "T3 post-attest source edit → current-tree != attested_tree (stale gauntlet detectable)"
else
  no "T3 post-attest edit not detected" "trees still equal"
fi

# ── T4: untracked artifacts do NOT change the tracked-tree hash (no false stale from gauntlet output) ──
BEFORE="$(tree_now)"
( cd "$TD" && echo "untracked" > NEW_ARTIFACT_${SID}.md ) >/dev/null 2>&1   # untracked → not in tree
[ "$(tree_now)" = "$BEFORE" ] \
  && ok "T4 an untracked artifact write does NOT change the tracked-tree hash (no false stale)" \
  || no "T4 untracked file changed the tree hash" "before=$BEFORE after=$(tree_now)"

# ── T5 (red fixture): pre-fix attest writes NO attested_tree ──
if [ -f "$ATTEST_BAK" ]; then
  rm -f "$WIT"; ( cd "$TD" && G reset -q --hard HEAD ) >/dev/null 2>&1
  ( cd "$TD" && echo f > f2.php && G add f2.php ) >/dev/null 2>&1
  mk_artifacts
  attest "$ATTEST_BAK"
  BV="$(jq -r '.attested_tree // "ABSENT"' "$WIT" 2>/dev/null || echo ABSENT)"
  [ "$BV" = "ABSENT" ] \
    && ok "T5 red-fixture: pre-fix attest writes no attested_tree (the unbound witness)" \
    || no "T5 red-fixture vacuous: pre-fix already wrote attested_tree=$BV"
else
  ok "T5 skipped: no pre-fix bak on disk"
fi
# ── T6: no commits yet → empty signed tree, never the literal rev-parse argument ──
NC="$TD/nocommit"; mkdir -p "$NC/.v/tmp"
( cd "$NC" && git init -q -b main && echo x > a.php ) >/dev/null 2>&1
rm -f "$WIT"; mk_artifacts "$NC"; attest "$ATTEST" "$NC"
NT="$(jq -r 'if has("attested_tree") then .attested_tree else "ABSENT" end' "$WIT" 2>/dev/null || echo NOWITNESS)"
[ -z "$NT" ] && ok "T6 repo with no commits: attested_tree is empty (no literal HEAD^{tree} signed)" \
             || no "T6 no-commit repo signed a non-hash tree value" "attested_tree=[$NT]"

# ── T7: quote and backslash in the root survive the JSON round trip ──
QR="$TD/we\"ird\\dir"; mkdir -p "$QR/.v/tmp"
( cd "$QR" && git init -q -b main && echo base > app.php && G add -A && G commit -qm base ) >/dev/null 2>&1
rm -f "$WIT"; mk_artifacts "$QR"; attest "$ATTEST" "$QR"
RR="$(jq -r '.attested_tree_root' "$WIT" 2>/dev/null || echo JQ-PARSE-ERROR)"
[ "$RR" = "$QR" ] && ok "T7 a root containing a quote and a backslash round-trips through the witness JSON" \
                  || no "T7 root did not round-trip" "wrote=[$QR] read=[$RR]"
rm -f "$WIT" 2>/dev/null || true

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
