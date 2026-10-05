#!/usr/bin/env bash
# record-codex-dispatch-provenance-test.sh — codex-provenance-witness class (forensic 2026-07-04).
#
# codex ran via a hand-rolled `codex exec` Bash call (the PRIMARY fork-compatible path), hit the quota
# wall, and left NO provenance row — while the AGENT_REVIEW narrated "Provenance recorded (status=failed)".
# This hook must witness EVERY codex-exec Bash call and record status=ok / status=failed from the call's
# own result, so no gate/forensic can be fooled by narration.
set -u
HOOK="$HOME/.claude/hooks/record-codex-dispatch-provenance.sh"
[ -f "$HOOK" ] || { echo "SKIP: hook missing"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

# E2 (efficiency, 2026-07-05): the hook now ALSO writes a shared fleet-wide codex-quota-exhaustion
# cache on a genuine quota-signature failure. Point it at a throwaway file for this whole test run —
# NEVER let a test touch the real ~/.claude/runtime/codex-quota-state.json fleet-wide cache.
CQ_TESTFILE="$(mktemp -t codex-quota-state-test 2>/dev/null || mktemp)"
rm -f "$CQ_TESTFILE"
export CODEX_QUOTA_STATE_FILE="$CQ_TESTFILE"

SID="c0dec0de-1111-4111-8111-000000000001"
# Item 7 (2026-07-05): the hook SID-binds the payload session_id against this process's local
# identity; this fixture's payload SID must match the local identity it runs under, or every
# case below would be (correctly) rejected as foreign.
export CLAUDE_SESSION_ID="$SID"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
T="$(mktemp -d)"; trap 'rm -rf "$T" "$CQ_TESTFILE"' EXIT
R="$T/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main && echo x > f && git add -A && git commit -qm i ) >/dev/null 2>&1
mkdir -p "$R/.v/artifacts"
PROV="$R/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"

run(){ # $1=command  $2=is_error  $3=stdout
  printf '%s' "$(jq -nc --arg c "$1" --arg e "$2" --arg o "$3" --arg s "$SID" \
    '{session_id:$s,tool_name:"Bash",tool_input:{command:$c},tool_response:{is_error:($e=="true"),stdout:$o}}')" \
    | ( cd "$R" && bash "$HOOK" )
}

# ── T1: a FAILED codex-exec (quota wall in stdout) → status=failed row ──
run 'codex exec --model gpt-5.5 "$(cat prompt)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
    "false" "ERROR: You've hit your usage limit. Upgrade to Pro or try again later."
if grep -qE "agent=codex-adversarial-reviewer\|.*status=failed" "$PROV" 2>/dev/null; then
  ok "T1 quota-walled codex-exec → status=failed provenance row written"
else
  no "T1 no failed row for a quota-walled codex call" "$(cat "$PROV" 2>/dev/null)"
fi

# ── T2: a SUCCESSFUL codex-exec → status=ok row ──
rm -f "$PROV"
printf 'Model: codex\nFindings: none\n' > "$R/.v/artifacts/REVIEW_CODEX_${SID}.md"
run 'codex exec --model gpt-5.3-codex "$(cat prompt)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
    "false" "## Findings\nNo issues found."
if grep -qE "agent=codex-adversarial-reviewer\|.*status=ok\|" "$PROV" 2>/dev/null; then
  ok "T2 successful codex-exec → status=ok provenance row"
else
  no "T2 no ok row for a successful codex call" "$(cat "$PROV" 2>/dev/null)"
fi
# T2b: the ok row carries the artifact sha256 (so the W59 degrade can hash-verify it)
if grep -qE "status=ok\|.*artifact=REVIEW_CODEX_${SID}\.md\|sha256=[0-9a-f]{64}" "$PROV" 2>/dev/null; then
  ok "T2b ok row includes the artifact sha256 (hash-verifiable)"
else
  no "T2b ok row missing artifact sha256" "$(cat "$PROV" 2>/dev/null)"
fi

# ── T3: harness is_error=true → status=failed even if stdout looks benign ──
rm -f "$PROV"
run 'codex exec --model gpt-5.5 "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md' "true" "partial output"
grep -qE "status=failed" "$PROV" 2>/dev/null \
  && ok "T3 harness is_error=true → status=failed" \
  || no "T3 is_error not honored" "$(cat "$PROV" 2>/dev/null)"

# ── T4: a NON-codex Bash command → NO row (no phantom provenance) ──
rm -f "$PROV"
run 'git status && echo "codex is a word here"' "false" "nothing"
[ ! -f "$PROV" ] || grep -qv codex "$PROV" 2>/dev/null
if [ ! -s "$PROV" ]; then
  ok "T4 non-codex Bash command writes no provenance row"
else
  no "T4 phantom row for a non-codex command" "$(cat "$PROV" 2>/dev/null)"
fi

# ── T5: the empty-prompt hand-roll bug (`Usage: codex exec`) → status=failed ──
rm -f "$PROV"
run 'echo "$PROMPT" | codex exec --model gpt-5.5 </dev/null > REVIEW_CODEX_'"$SID"'.md' "false" \
    "Usage: codex exec [OPTIONS] [PROMPT]"
grep -qE "status=failed" "$PROV" 2>/dev/null \
  && ok "T5 empty-prompt 'Usage: codex exec' output → status=failed (the laundered-session shape)" \
  || no "T5 usage-banner not classified failed" "$(cat "$PROV" 2>/dev/null)"

# ── T6: idempotency — same failed call twice does not stack identical rows ──
rm -f "$PROV"
for _i in 1 2; do
  run 'codex exec --model gpt-5.5 "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' "false" "hit your usage limit"
done
_cnt=$(grep -cE "agent=codex-adversarial-reviewer\|.*status=failed\|.*artifact=REVIEW_CODEX_${SID}\.md" "$PROV" 2>/dev/null || echo 0)
[ "$_cnt" -eq 1 ] \
  && ok "T6 duplicate identical failed calls → single row (idempotent)" \
  || no "T6 idempotency" "row count=$_cnt"

# ── T7: registered in BOTH settings files (dual-registration root-cause guard) ──
_reg=0
for f in "$HOME/.claude/settings.json" "$HOME/.claude/settings.headless.json"; do
  jq -e '.hooks.PostToolUse[]? | select(.matcher=="Bash") | .hooks[] | select(.command|test("record-codex-dispatch-provenance"))' "$f" >/dev/null 2>&1 && _reg=$((_reg+1))
done
[ "$_reg" -eq 2 ] \
  && ok "T7 hook registered in BOTH settings.json and settings.headless.json" \
  || no "T7 dual-registration incomplete" "registered in $_reg/2 settings files"


# ── E2 (efficiency, 2026-07-05): fleet-wide codex-quota cache ──
CQ_LIB="$HOME/.claude/hooks/lib/codex-quota-cache.sh"
if [ -f "$CQ_LIB" ]; then
  # T8: a genuine usage-limit failure writes a live (non-expired) exhaustion record.
  rm -f "$PROV" "$CQ_TESTFILE"
  run 'codex exec --model gpt-5.5 "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
      "false" "You've hit your usage limit. try again at Jan 1st, 2026 9:00 PM"
  if [ -s "$CQ_TESTFILE" ] && grep -q '"exhausted":true' "$CQ_TESTFILE" 2>/dev/null; then
    ok "T8 genuine usage-limit failure writes the fleet-wide quota cache"
  else
    no "T8 quota cache not written for a genuine usage-limit failure" "$(cat "$CQ_TESTFILE" 2>/dev/null)"
  fi

  # T8b: a fresh sub-shell sourcing the SAME cache file sees it as BLOCKED (proves the cache is
  # actually consultable by a later/different dispatch point — the whole point of E2).
  ( . "$CQ_LIB"; codex_quota_is_blocked ) >/dev/null 2>&1
  if [ $? -eq 0 ]; then
    ok "T8b codex_quota_is_blocked reports BLOCKED after a recorded exhaustion"
  else
    no "T8b codex_quota_is_blocked did not see the just-recorded exhaustion"
  fi

  # T9: a NON-quota failure (generic auth/stream error) must NOT trip the fleet-wide cache — only a
  # genuine usage-limit/quota signature should lock codex out for 30-60 min fleet-wide.
  rm -f "$PROV" "$CQ_TESTFILE"
  run 'codex exec --model gpt-5.5 "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
      "false" "stream error: connection reset"
  if [ ! -s "$CQ_TESTFILE" ]; then
    ok "T9 a non-quota failure (stream error) does NOT write the fleet-wide quota cache"
  else
    no "T9 non-quota failure wrongly wrote the quota cache" "$(cat "$CQ_TESTFILE" 2>/dev/null)"
  fi

  # T10: a SUCCESSFUL codex-exec must not write/touch the quota cache either.
  rm -f "$PROV" "$CQ_TESTFILE"
  printf 'Model: codex\nFindings: none\n' > "$R/.v/artifacts/REVIEW_CODEX_${SID}.md"
  run 'codex exec --model gpt-5.3-codex "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
      "false" "## Findings\nNo issues found."
  if [ ! -s "$CQ_TESTFILE" ]; then
    ok "T10 a successful codex-exec does NOT write the fleet-wide quota cache"
  else
    no "T10 successful call wrongly wrote the quota cache" "$(cat "$CQ_TESTFILE" 2>/dev/null)"
  fi
else
  echo "SKIP T8-T10: $CQ_LIB missing"
fi

# ── T11 (F17, forensic 2026-07-11): a SUCCESSFUL exit-0 codex review whose
# transcript legitimately DISCUSSES quota/rate-limit product code (ExampleQuotaMeter,
# ExampleQuotaService, "spend-cap quota reservation", "per-user rate limit") must record
# status=ok — the bare `quota`/`rate.?limit` tokens used to flag it failed (domain-keyword
# collision), which cascaded into attest refusal + a blocked session log. Genuine walls are
# covered by T1 (usage-limit text) and T2 (is_error=true), which must keep passing. ──
: > "$PROV" 2>/dev/null || true
run 'codex exec --model gpt-5.3-codex "$(cat p)" </dev/null > REVIEW_CODEX_'"$SID"'.md 2>&1' \
    "false" "## Findings\nFND-1: ExampleQuotaService spend-cap quota reservation has a race; ExampleQuotaMeter shows stale quota; add a per-user rate limit check.\nNo blocking issues."
if grep -qE "agent=codex-adversarial-reviewer\|.*status=ok" "$PROV" 2>/dev/null \
   && ! grep -qE "status=failed" "$PROV" 2>/dev/null; then
  ok "T11 exit-0 review discussing quota-domain product code → status=ok (no domain-keyword false-fail)"
else
  no "T11 quota-domain content false-classified as failed" "$(cat "$PROV" 2>/dev/null)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
