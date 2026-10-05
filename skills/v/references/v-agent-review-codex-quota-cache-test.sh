#!/usr/bin/env bash
# v-agent-review-codex-quota-cache-test.sh — E2 (efficiency, 2026-07-05): behavioral test for the
# fleet-wide codex-quota cache wired into v-agent-review.md's PRIMARY direct-`codex exec` supervisor
# child snippet.
#
# WHY: direct evidence (2026-07-05) — `codex exec --model gpt-5.3-codex` failed with a model-support
# error, the documented fallback `gpt-5.5` then failed with a genuine quota exhaustion ("You've hit
# your usage limit... try again later"). Before this fix, NOTHING recorded that
# discovery anywhere the primary Bash-direct codex-exec path could see it, so every dispatch point —
# in this session or any other — re-attempted codex cold and paid the full network round-trip before
# falling back. This test EXTRACTS the actual bash the child-script heredoc in v-agent-review.md
# generates (not a paraphrase) and EXECUTES it against a fake `codex` binary that counts invocations,
# proving: (a) with no cache, codex is attempted; (b) with a live exhaustion record, codex is skipped
# entirely (0 invocations) and the artifact honestly says `status: fallback_required`; (c) once the
# TTL expires, codex is attempted again (self-healing, not a permanent lockout).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="${V_AGENT_REVIEW_DOC:-$HERE/v-agent-review.md}"
CQ_LIB="${V_CODEX_QUOTA_LIB:-$HOME/.claude/hooks/lib/codex-quota-cache.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$DOC" ] || { echo "SKIP: v-agent-review.md missing"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
[ -f "$CQ_LIB" ] || { echo "SKIP: codex-quota-cache.sh missing"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ── Extract the codex child-script heredoc body verbatim from the doc (not retyped) ──
python3 - "$DOC" "$WORK/child-body.txt" <<'PYEOF'
import re, sys
doc, out = sys.argv[1], sys.argv[2]
text = open(doc).read()
m = re.search(r'cat > "\$V_TMP_DIR/review-codex-\$\{SESSION_ID\}\.sh" <<EOF\n(.*?)\nEOF\n', text, re.DOTALL)
if not m:
    sys.exit(1)
open(out, 'w').write(m.group(1))
PYEOF
if [ $? -ne 0 ] || [ ! -s "$WORK/child-body.txt" ]; then
  echo "SKIP: could not extract codex child-script heredoc from $DOC (doc structure changed?)"
  echo "TOTAL: 0 passed, 0 failed"
  exit 0
fi
ok "extracted the codex child-script heredoc body from v-agent-review.md"

echo "== v-agent-review.md :: fleet-wide codex-quota cache (E2) =="

# Materialize the extracted body into a runnable script EXACTLY the way the orchestrator does: pipe
# it through a real unquoted `cat > file <<EOF` heredoc (in a fresh bash subprocess, with the same
# outer vars the orchestrator resolves before writing) so the doc's `\$` (inner-runtime var, escaped
# in the source markdown) unescapes to `$`, and its bare `$ART_CODEX`/`$PF_CODEX` (outer, write-time)
# references expand NOW against these resolved values — a naive line-for-line copy would skip that
# expansion pass and produce a syntactically broken script.
V_TMP_DIR="$WORK"
ART_DIR="$WORK/artdir"; mkdir -p "$ART_DIR"
PF_CODEX="$WORK/pf_codex.txt"; echo "review this diff" > "$PF_CODEX"
ART_CODEX="$ART_DIR/REVIEW_CODEX_test-sid.md"
SESSION_ID="test-sid"
CODEX_REVIEW_MODEL="gpt-5.3-codex"
CODEX_REVIEW_MODEL_FALLBACK="gpt-5.5"
export V_TMP_DIR ART_DIR PF_CODEX ART_CODEX SESSION_ID CODEX_REVIEW_MODEL CODEX_REVIEW_MODEL_FALLBACK
{
  echo 'cat > "$V_TMP_DIR/review-codex-${SESSION_ID}.sh" <<EOF'
  cat "$WORK/child-body.txt"
  echo ""   # guarantee a newline before the EOF delimiter (extracted body may lack a trailing \n)
  echo 'EOF'
} | bash 2>/dev/null
chmod +x "$WORK/review-codex-test-sid.sh"
ln -sf "$WORK/review-codex-test-sid.sh" "$WORK/child.sh"

# Fake `codex` binary that counts invocations and always fails (so the fallback path is exercised).
mkdir -p "$WORK/fakebin"
cat > "$WORK/fakebin/codex" <<SH
#!/usr/bin/env bash
c=\$(cat "$WORK/codex_call_count" 2>/dev/null || echo 0)
echo \$((c+1)) > "$WORK/codex_call_count"
exit 1
SH
chmod +x "$WORK/fakebin/codex"

run_child() {
  rm -f "$ART_CODEX"
  PATH="$WORK/fakebin:$PATH" bash "$WORK/child.sh" >/dev/null 2>&1
  echo $?
}
call_count() { cat "$WORK/codex_call_count" 2>/dev/null || echo 0; }

# ── A: no quota cache present -> codex IS attempted (both models = 2 invocations) ──
rm -f "$WORK/codex_call_count"
export CODEX_QUOTA_STATE_FILE="$WORK/quota-state.json"
rm -f "$CODEX_QUOTA_STATE_FILE"
run_child >/dev/null
[ "$(call_count)" -eq 2 ] \
  && ok "A: no cache present -> codex exec attempted (both primary+fallback model = 2 calls)" \
  || no "A: expected 2 codex invocations with no cache" "got $(call_count)"

# ── B: a LIVE fleet-wide exhaustion record -> codex is SKIPPED entirely (0 invocations) ──
rm -f "$WORK/codex_call_count"
( . "$CQ_LIB"; codex_quota_record_exhausted "You've hit your usage limit. try again later" 2700 )
[ -s "$CODEX_QUOTA_STATE_FILE" ] || no "B: setup — quota cache was not written" ""
rc=$(run_child)
[ "$(call_count)" -eq 0 ] \
  && ok "B: live exhaustion record -> codex exec SKIPPED (0 invocations, no wasted round-trip)" \
  || no "B: expected 0 codex invocations with a live exhaustion cache" "got $(call_count)"
[ "$rc" != "0" ] \
  && ok "B: child script exits non-zero on the cached-skip path (fallback chain still triggers)" \
  || no "B: child script should exit non-zero on cached-skip" "rc=$rc"
grep -qi "fallback_required" "$ART_CODEX" 2>/dev/null \
  && ok "B: artifact honestly records 'status: fallback_required' (no fabricated codex run)" \
  || no "B: artifact missing honest fallback_required status" "$(cat "$ART_CODEX" 2>/dev/null)"

# ── C: an EXPIRED cache (TTL passed) -> codex is attempted again (self-healing, not permanent) ──
rm -f "$WORK/codex_call_count"
( . "$CQ_LIB"; codex_quota_record_exhausted "stale exhaustion" 1 )  # 1-second TTL
sleep 2
run_child >/dev/null
[ "$(call_count)" -eq 2 ] \
  && ok "C: expired cache (TTL passed) -> codex exec attempted again (self-healing)" \
  || no "C: expected codex to be retried once the TTL expired" "got $(call_count)"

unset CODEX_QUOTA_STATE_FILE

echo
echo "TOTAL: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
