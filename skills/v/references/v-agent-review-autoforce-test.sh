#!/usr/bin/env bash
# v-agent-review-autoforce-test.sh — bite for the AGENT_REVIEW Model:-line AUTO-FORCE (forensic 2026-06-27).
# The Pre-Write check used to error on a wrong/hidden `Model:` line-1 and ask the model to sed-fix it — the
# dominant AGENT_REVIEW churn class (~9 Stop-blocks/batch: a hallucinated `gpt-5.5`, a frontmatter-hidden `Model:`).
# The wrap now AUTO-FORCES line-1 to the literal `Model: haiku`. This bite EXTRACTS the auto-force block VERBATIM
# from v-agent-review.md (real coverage of the production directive, not a re-implemented copy) and proves it forces
# line-1 for wrong / absent / already-correct drafts. RED = the old check-and-error logic (which never modified it).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="${V_AREV_DOC_OVERRIDE:-$HERE/v-agent-review.md}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$DOC" ] || { echo "NO v-agent-review.md missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

AF="$(awk '/# >>> AREV-MODEL-AUTOFORCE/{f=1;next} /# <<< AREV-MODEL-AUTOFORCE/{f=0} f' "$DOC")"
[ -n "$AF" ] || { echo "NO auto-force block not found (sentinels removed?)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T" 2>/dev/null' EXIT
run_af(){ DRAFT="$1" bash -c "$AF" >/dev/null 2>&1 || true; }   # run the extracted production block with DRAFT set

echo "== AGENT_REVIEW Model: line-1 auto-force (kills the hallucinated/hidden-Model churn) =="
printf 'Model: gpt-5.5\n## Findings\nstuff\n' > "$T/d1"; run_af "$T/d1"
[ "$(head -1 "$T/d1")" = "Model: haiku" ] && ok "hallucinated 'Model: gpt-5.5' -> forced to 'Model: haiku'" || no "wrong model not forced" "$(head -1 "$T/d1")"
printf '# AGENT REVIEW\nModel: hidden below\n## Findings\n' > "$T/d2"; run_af "$T/d2"
[ "$(head -1 "$T/d2")" = "Model: haiku" ] && ok "absent line-1 Model (frontmatter/heading first) -> prepended 'Model: haiku'" || no "Model not prepended" "$(head -1 "$T/d2")"
# SREV-003: already-correct line-1 + a body line that legitimately starts with "Model: " — auto-force must skip
# (idempotent) and NOT double-prepend; check line-2, not a whole-file grep-count (which the body line would trip).
printf 'Model: haiku\n## Findings\n- evidence: Model: gpt-4o ran the sub-review\n' > "$T/d3"; run_af "$T/d3"
{ [ "$(head -1 "$T/d3")" = "Model: haiku" ] && [ "$(sed -n '2p' "$T/d3")" != "Model: haiku" ]; } \
  && ok "already-correct draft unchanged + body 'Model:' line untouched (idempotent, no double-prepend)" || no "idempotency broken (double-prepend / body mangled)" "line2='$(sed -n '2p' "$T/d3")'"

echo "== RED: the OLD check-and-error logic does NOT force (leaves the wrong line) + no exit-1 remains =="
printf 'Model: gpt-5.5\n## Findings\n' > "$T/r1"
DRAFT="$T/r1" bash -c 'head -1 "$DRAFT" | grep -qx "Model: haiku" || { echo "ERROR: sed-fix it"; exit 1; }' >/dev/null 2>&1 || true
[ "$(head -1 "$T/r1")" = "Model: gpt-5.5" ] && ok "RED: old check-error left 'Model: gpt-5.5' unchanged (auto-force is the fix)" || no "RED: old logic already forced?!" "$(head -1 "$T/r1")"
printf '%s' "$AF" | grep -q 'exit 1' && no "auto-force block still contains exit 1 (model-in-the-loop churn not removed)" "" || ok "auto-force block has no exit-1 (deterministic, no model behaviour in the loop)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
