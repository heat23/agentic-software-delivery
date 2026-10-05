#!/usr/bin/env bash
# commit-witness-recorder-test.sh — ORCHFIX-B2 class harness (forensics 2026-07-02).
# CLASS: landing-outside-merge-back leaves no commit witness → session-log attribution collapses
# in BOTH directions (one session claimed a SIBLING's commit; another claimed ZERO). The recorder
# writes commits-<sid>.txt on EVERY successful `git commit`, sourcing the sha ONLY from the call's
# own stdout so a concurrent sibling's HEAD movement can never be recorded as ours.
# RED oracle: the hook is NEW — the pre-fix world (no hook registered) produced no witness; T-RED
# asserts the backup settings.json carries no recorder registration.
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

HOOK="$HOME/.claude/hooks/commit-witness-recorder.sh"
TD="$(mktemp -d)"; trap 'rm -rf "$TD"' EXIT
# F7a: the provenance sidecar is HMAC-signed under the gauntlet-witness per-install secret.
# Use a TEST-OWNED key file so this harness never creates or depends on the user's real secret.
export GAUNTLET_HMAC_KEY_FILE="$TD/.test-hmac-key"
SID="66660000-ffff-4fff-8fff-000000000001"
git -C "$TD" init -q; git -C "$TD" commit -q --allow-empty -m base
( cd "$TD" && printf 'x\n' > f.txt && git add f.txt )
OUTLINE="$(cd "$TD" && git commit -m 'real commit' 2>&1 | head -1)"
FULL="$(git -C "$TD" rev-parse HEAD)"

fire(){ printf '{"tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{"stdout":"%s","is_error":false}}' "$SID" "$TD" "$1" "$2" | bash "$HOOK"; }

# T1: successful commit -> full sha appended to the main-root witness.
fire "cd $TD && git commit -m real" "$OUTLINE"
W="$TD/.v/artifacts/commits-${SID}.txt"
[ -f "$W" ] && grep -qxF "$FULL" "$W" && ok "T1: witness carries the full sha from the call's own stdout" \
                                       || no "T1: witness missing or wrong ($(cat "$W" 2>/dev/null))"

# T2: dedup — same event re-fired appends nothing.
fire "cd $TD && git commit -m real" "$OUTLINE"
[ "$(grep -c . "$W")" = "1" ] && ok "T2: duplicate fire deduped" || no "T2: witness duplicated"

# T3: attribution safety — stdout WITHOUT a commit line (e.g. 'nothing to commit') records nothing,
# even though HEAD exists; we never blind-rev-parse a sibling's HEAD.
fire "cd $TD && git commit -m real" "On branch main: nothing to commit, working tree clean"
[ "$(grep -c . "$W")" = "1" ] && ok "T3: no-commit stdout records nothing (never blind HEAD)" || no "T3: recorded from non-commit stdout"

# T4: non-commit command is a no-op fast path.
fire "cd $TD && ls" "f.txt"
[ "$(grep -c . "$W")" = "1" ] && ok "T4: non-commit command no-op" || no "T4: non-commit wrote witness"

# T5: worktree commit lands the witness in the MAIN root's durable store.
git -C "$TD" worktree add -q "$TD-wt" -b wt-b 2>/dev/null
( cd "$TD-wt" && printf 'y\n' > g.txt && git add g.txt )
OUT2="$(cd "$TD-wt" && git commit -m 'wt commit' 2>&1 | head -1)"
FULL2="$(git -C "$TD-wt" rev-parse HEAD)"
printf '{"tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"cd %s && git commit -m wt"},"tool_response":{"stdout":"%s","is_error":false}}' "$SID" "$TD-wt" "$TD-wt" "$OUT2" | bash "$HOOK"
grep -qxF "$FULL2" "$W" && ok "T5: worktree commit witnessed in MAIN root (worktree-blindness class avoided)" \
                        || no "T5: worktree commit not in main-root witness"
git -C "$TD" worktree remove --force "$TD-wt" 2>/dev/null || true

# T-RED: pre-fix settings carried no recorder registration (the witness was merge-back-only).
BAKS="$HOME/.claude/settings.json.pre-orchfix0702-bak"
if [ -f "$BAKS" ]; then
  grep -q 'commit-witness-recorder' "$BAKS" && no "T-RED: backup settings already had the recorder?!" \
                                             || ok "T-RED oracle: pre-fix settings have NO recorder (witness was merge-back-only)"
fi
grep -q 'commit-witness-recorder' "$HOME/.claude/settings.json" && grep -q 'commit-witness-recorder' "$HOME/.claude/settings.headless.json" \
  && ok "dual registration present (settings.json + settings.headless.json)" \
  || no "recorder not dual-registered"

# T6/T7 (REV-5, adversarial review 2026-07-03): forged bracket lines must not poison the witness.
GIT_COMMITTER_DATE='2026-01-01T00:00:00 -0500' GIT_AUTHOR_DATE='2026-01-01T00:00:00 -0500' \
  git -C "$TD" -c commit.gpgsign=false commit -q --allow-empty -m old-history
OLD_SHA_FULL="$(git -C "$TD" rev-parse HEAD)"
OLD_SHORT="$(git -C "$TD" rev-parse --short "$OLD_SHA_FULL")"
git -C "$TD" -c commit.gpgsign=false commit -q --allow-empty -m age-pad
# age the ROOT commit signal: forge an echo naming the OLD (stale) commit
fire "cd $TD && git commit -m nothing; echo forged" "[main ${OLD_SHORT}] forged success line"
grep -qxF "$OLD_SHA_FULL" "$W" && no "T6: forged bracket recorded a STALE pre-existing commit (REV-5 regression)" \
                                || ok "T6: stale-sha forged bracket rejected (freshness proof)"
# wrong-branch bracket: fresh sha but bracket names a branch that is not the current one
FRESH_FULL="$(git -C "$TD" rev-parse HEAD)"; FRESH_SHORT="$(git -C "$TD" rev-parse --short HEAD)"
fire "cd $TD && git commit -m x" "[some-other-branch ${FRESH_SHORT}] subject"
grep -qxF "$FRESH_FULL" "$W" && no "T7: wrong-branch bracket recorded (REV-5 regression)" \
                              || ok "T7: wrong-branch bracket rejected (branch proof)"

# T8-T10 (F7a / F6(a) sidecar, 2026-07-05): the recorder must leave verifiable provenance beside
# the witness so validate-log.py can distinguish a hook-recorded INLINE witness (legitimate,
# ORCHFIX-B2) from a generator-fabricated one (the generator-contamination class) WITHOUT trusting
# the self-reported worktree boolean.
PROV="${W}.provenance"
# T8: the T1/T5 appends above must have refreshed the sidecar, and its sha256 must match the
# witness content EXACTLY (definitively hook-recorded).
if [ -f "$PROV" ]; then
  _want="$(sed -nE 's/.*sha256=([0-9a-f]{64}).*/\1/p' "$PROV" | head -1)"
  _got="$(shasum -a 256 "$W" 2>/dev/null | awk '{print $1}')"
  [ -z "$_got" ] && _got="$(sha256sum "$W" 2>/dev/null | awk '{print $1}')"
  { [ -n "$_want" ] && [ "$_want" = "$_got" ]; } \
    && ok "T8: provenance sidecar present + sha256 matches the witness content" \
    || no "T8: sidecar sha256 mismatch (want=$_want got=$_got)"
  grep -q 'recorder=commit-witness-recorder' "$PROV" && ok "T8b: sidecar names its recorder" \
                                                     || no "T8b: sidecar missing recorder field"
  # T8c/T8d (F7a HMAC): the sidecar must carry a KEYED hmac= that verifies under the per-install
  # secret via the SAME lib helper the recorder used — an unkeyed sidecar is review-rejected
  # (forgeable by the identical one-liner a legitimate writer uses).
  _mac="$(sed -nE 's/.*hmac=([0-9a-f]{64}).*/\1/p' "$PROV" | head -1)"
  _ts8="$(sed -nE 's/.*ts=([^ ]+).*/\1/p' "$PROV" | head -1)"
  [ -n "$_mac" ] && ok "T8c: sidecar carries a keyed hmac= signature" \
                 || no "T8c: sidecar has NO hmac= (unkeyed — the review-rejected form)"
  if . "$HOME/.claude/hooks/lib/gauntlet-witness.sh" 2>/dev/null && type gw_hmac_verify_file >/dev/null 2>&1; then
    gw_hmac_verify_file "commit-witness" "$W" "$_ts8" "$_want" "$_mac" \
      && ok "T8d: sidecar HMAC verifies under the per-install secret (gw_hmac_verify_file)" \
      || no "T8d: sidecar HMAC does not verify"
    # T8e: a FORGED hmac (right shape, wrong value) must NOT verify.
    _forged="$(printf '0%.0s' $(seq 1 64))"
    gw_hmac_verify_file "commit-witness" "$W" "$_ts8" "$_want" "$_forged" \
      && no "T8e: forged hmac verified?! (keying broken)" \
      || ok "T8e: forged hmac rejected by gw_hmac_verify_file"
  else
    no "T8d: gauntlet-witness.sh helpers unavailable"
  fi
else
  no "T8: no provenance sidecar written next to the witness"
fi
# T9: a REJECTED bracket (forged/stale — T6/T7 paths) must NOT refresh the sidecar to cover
# tampered content: append a foreign sha to the witness BY HAND (simulating a generator range-walk),
# then fire a non-recording event — the sidecar must now MISMATCH the witness (tamper evidence).
printf '%s\n' "$(printf 'c%.0s' $(seq 1 40))" >> "$W"
fire "cd $TD && git commit -m x" "On branch main: nothing to commit, working tree clean"
_want9="$(sed -nE 's/.*sha256=([0-9a-f]{64}).*/\1/p' "$PROV" 2>/dev/null | head -1)"
_got9="$(shasum -a 256 "$W" 2>/dev/null | awk '{print $1}')"
[ -z "$_got9" ] && _got9="$(sha256sum "$W" 2>/dev/null | awk '{print $1}')"
{ [ -n "$_want9" ] && [ "$_want9" != "$_got9" ]; } \
  && ok "T9: hand-appended foreign sha leaves sidecar/witness MISMATCHED (tamper evidence preserved)" \
  || no "T9: sidecar was refreshed over tampered content (tamper evidence destroyed)"
# T-RED (F7a): the pre-fix recorder wrote NO sidecar — prove against the preserved backup.
BAKH="$HOME/.claude/hooks/commit-witness-recorder.sh.pre-f7a-provenance-bak"
if [ -f "$BAKH" ]; then
  TDR="$(mktemp -d)"; SIDR="66660000-ffff-4fff-8fff-000000000002"
  git -C "$TDR" init -q; git -C "$TDR" commit -q --allow-empty -m base
  ( cd "$TDR" && printf 'x\n' > f.txt && git add f.txt )
  OUTR="$(cd "$TDR" && git commit -m 'red commit' 2>&1 | head -1)"
  printf '{"tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":"cd %s && git commit -m red"},"tool_response":{"stdout":"%s","is_error":false}}' "$SIDR" "$TDR" "$TDR" "$OUTR" | bash "$BAKH"
  WR="$TDR/.v/artifacts/commits-${SIDR}.txt"
  if [ -f "$WR" ] && [ ! -f "${WR}.provenance" ]; then
    ok "T10-RED: pre-fix recorder wrote the witness but NO provenance sidecar (the F6(a) gap, reproduced)"
  else
    no "T10-RED: unexpected pre-fix state (witness=$([ -f "$WR" ] && echo yes || echo no) sidecar=$([ -f "${WR}.provenance" ] && echo yes || echo no))"
  fi
  rm -rf "$TDR"
else
  ok "T10-RED skipped: no pre-fix bak on disk"
fi

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
