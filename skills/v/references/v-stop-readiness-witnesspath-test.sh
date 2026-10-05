#!/usr/bin/env bash
# v-stop-readiness-witnesspath-test.sh — WITNESS-PATH PARITY (forensic 2026-07-09).
# CLASS: advisory-preview-drift — the readiness preview re-resolved the three gauntlet artifacts
# via _find_art (newest duplicate across root/.v/artifacts wins by mtime) instead of hashing the
# exact paths the witness recorded, so a fresher DUPLICATE copy of a just-attested artifact made
# the preview report a content-hash MISMATCH while the real gate (and the witness) were correct —
# observed repeatedly in one session, training the operator to ignore the preview.
# RED oracle: v-stop-readiness.sh.pre-witnesspath-bak reports MISMATCH on the decoy fixture.
set -u
SCRIPT_DEFAULT="$HOME/.claude/skills/v/references/v-stop-readiness.sh"
SCRIPT="${V_READINESS_OVERRIDE:-$SCRIPT_DEFAULT}"
BAK="$SCRIPT_DEFAULT.pre-witnesspath-bak"
REAL_LIB_DIR="$HOME/.claude/hooks/lib"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$SCRIPT" ] || { echo "NO v-stop-readiness.sh missing"; exit 1; }
[ -f "$REAL_LIB_DIR/gauntlet-witness.sh" ] || { echo "SKIP: gauntlet-witness.sh lib missing"; exit 0; }

TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"; trap 'rm -rf "$TMP"' EXIT
HOMEDIR="$TMP/home"; REPO="$TMP/repo"
SID="ffffffff-71dd-4666-8666-ffffffffffff"
mkdir -p "$HOMEDIR/.claude/runtime" "$HOMEDIR/.claude/projects/p" "$REPO/.v/artifacts"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1

sha(){ shasum -a 256 "$1" | awk '{print $1}'; }

# Resolver-divergence fixture. readiness's _find_art is FIRST-DIR-WINS (.v/artifacts before repo
# root); attest's gauntlet_find_artifact is NEWEST-WINS across dirs. Reproduce the live drift:
# a STALE different-content copy sits in .v/artifacts (readiness resolves it), while the copy the
# witness actually attested lives at the repo ROOT (what attest's newest-wins resolution hashed).
for art in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  { printf 'Model: haiku\nSID: %s\nMode: full\nSTALE sibling copy — different content\n\n## Gates\n\n| Status | Gate |\n| --- | --- |\n| PASS | tests |\n\nOverall Status: PASS\n' "$SID"
    head -c 400 /dev/zero | tr '\0' 'y'; printf '\n'; } > "$REPO/.v/artifacts/${art}_${SID}.md"
done
sleep 1
for art in PRE_FLIGHT_REPORT AGENT_REVIEW VERIFY_DONE_REPORT; do
  { printf 'Model: haiku\nSID: %s\nMode: full\n\n## Gates\n\n| Status | Gate |\n| --- | --- |\n| PASS | tests |\n\nOverall Status: PASS\n' "$SID"
    head -c 400 /dev/zero | tr '\0' 'x'; printf '\n'; } > "$REPO/${art}_${SID}.md"
done
PF="$REPO/PRE_FLIGHT_REPORT_${SID}.md"
AR="$REPO/AGENT_REVIEW_${SID}.md"
VD="$REPO/VERIFY_DONE_REPORT_${SID}.md"

# Witness recording the attested paths + their hashes (readiness does not verify the HMAC).
NOW="$(date -u +%s)"
printf '{"skill":"v","check":"gauntlet-attest","wit_ver":2,"sid":"%s","nonce":"t","ts":%s,"pid":1,"pre_flight":"%s","agent_review":"%s","verify_done":"%s","pre_sha256":"%s","rev_sha256":"%s","ver_sha256":"%s","hmac":"t"}\n' \
  "$SID" "$NOW" "$PF" "$AR" "$VD" "$(sha "$PF")" "$(sha "$AR")" "$(sha "$VD")" \
  > "$HOMEDIR/.claude/runtime/v-gauntlet-attestation-${SID}.json"

runread(){ # $1=script → output file $TMP/out
  ( cd "$REPO" && HOME="$HOMEDIR" V_HOOK_LIB_DIR="$REAL_LIB_DIR" \
      CLAUDE_SESSION_ID="$SID" bash "$1" "$SID" ) > "$TMP/out" 2>&1 || true
}

echo "== v-stop-readiness :: witness-path parity vs newest-duplicate re-resolution =="

runread "$SCRIPT"
if grep -q 'content-hash MISMATCH' "$TMP/out"; then
  no "T1: preview still reports MISMATCH with a fresher decoy duplicate present"
else
  ok "T1: no false MISMATCH — preview hashed the witness-recorded paths"
fi
grep -q 'content-hash matches' "$TMP/out" \
  && ok "T1b: positive parity line present" \
  || no "T1b: parity ok-line missing (block may not have run — check fixture reach)"

# T2 — REAL post-attest edit of the ATTESTED file must still MISMATCH (guard not weakened).
printf 'tamper\n' >> "$PF"
runread "$SCRIPT"
grep -q 'content-hash MISMATCH' "$TMP/out" \
  && ok "T2: tampering with the attested file still reports MISMATCH" \
  || no "T2: tamper undetected — parity check weakened"
# restore
( printf 'Model: haiku\nSID: %s\nMode: full\n\n## Gates\n\n| Status | Gate |\n| --- | --- |\n| PASS | tests |\n\nOverall Status: PASS\n' "$SID"
  head -c 400 /dev/zero | tr '\0' 'x'; printf '\n'; ) > "$PF"

# RED oracle — pre-fix preview MISMATCHes on the decoy fixture.
if [ -f "$BAK" ]; then
  runread "$BAK"
  grep -q 'content-hash MISMATCH' "$TMP/out" \
    && ok "RED: pre-fix preview reports the false MISMATCH (drift reproduced)" \
    || no "RED: pre-fix preview did not mismatch — bite not isolating the drift (did _find_art pick the decoy?)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
