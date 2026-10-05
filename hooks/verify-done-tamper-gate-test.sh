#!/usr/bin/env bash
# verify-done-tamper-gate-test.sh — VERIFY_DONE_REPORT post-dispatch content-binding (forensic
# 2026-06-18 audit, agent-A finding #1: VERIFY_DONE was the ONLY gauntlet artifact with NO
# content-binding — a hand-edit that flips 'Overall Verdict: FAIL'->PASS *and deletes the FND-BND
# lines* defeats both verdict re-checks (P0a) and leaves nothing to detect).
#
# The canonical dispatch (SKILL.md: `v-dispatch-subagent.sh --agent v-verify-done-runner --mode
# capture`) has the HELPER write the artifact and record its sha256 in DISPATCH_PROVENANCE
# (emit_marker ok / W5G-4). So a post-dispatch edit is catchable as 'edited' — the gate just never
# called _independence_verdict for VERIFY_DONE. This harness drives the REAL Stop hook and asserts the
# new 'edited' arm, plus FP-safety (untampered + honest Post-dispatch edit + hand-authored-no-provenance
# all NOT edited-blocked).
set -u
HOOK="${V_HOOK_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v jq     >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
command -v git    >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v shasum >/dev/null 2>&1 || { echo "SKIP: shasum unavailable"; exit 0; }
[ -f "$HOOK" ] || { echo "NO check-review-artifact.sh missing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOMEDIR="$TMP/home"; REPO="$TMP/repo"
mkdir -p "$HOMEDIR/.claude/projects/p" "$REPO"
ln -s "$HOME/.claude/hooks" "$HOMEDIR/.claude/hooks" 2>/dev/null
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
: > "$HOMEDIR/.claude/history.jsonl"
GITDIR="$(cd "$REPO" && git rev-parse --git-common-dir 2>/dev/null)"; case "$GITDIR" in /*) ;; *) GITDIR="$REPO/$GITDIR";; esac

mk_session(){  # $1=sid
  printf '{"sessionId":"%s","display":"/v Advance"}\n' "$1" >> "$HOMEDIR/.claude/history.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"/v Advance"}}\n' > "$HOMEDIR/.claude/projects/p/${1}.jsonl"
  printf 'app/Services/Foo.php\n' > "$GITDIR/claude-session-writes-${1}.txt"
}
sig(){ printf '{"type":"assistant","message":{"role":"assistant"},"subagent_type":"v-verify-done-runner"}\n' >> "$HOMEDIR/.claude/projects/p/${1}.jsonl"; }
write_vd(){  # $1=sid  $2=optional-extra-line  (a structurally-valid PASS report)
  {
    printf 'Model: haiku\n\n## Verify-Done Report — %s\n\n' "$1"
    printf 'Convention scan complete. No violations.\n\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"
    printf 'Overall Verdict: PASS\n'
  } > "$REPO/VERIFY_DONE_REPORT_${1}.md"
}
# Capture-mode provenance line, exactly as v-dispatch-subagent.sh emit_marker writes it.
write_prov(){  # $1=sid  $2=sha256
  printf 'DISPATCH|ts=2026-06-18T00:00:00Z|agent=v-verify-done-runner|mode=capture|status=ok|submodel=haiku|cost_usd=0|duration_ms=0|artifact=VERIFY_DONE_REPORT_%s.md|sha256=%s\n' \
    "$1" "$2" > "$REPO/DISPATCH_PROVENANCE_${1}.log"
}
file_sha(){ shasum -a 256 "$1" | awk '{print $1}'; }
OUTF="$TMP/out"; RC=0
run(){  ( cd "$REPO" && printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$1" "$HOMEDIR/.claude/projects/p/${1}.jsonl" "$REPO" \
    | HOME="$HOMEDIR" CLAUDE_SESSION_ID="$1" CLAUDE_CODE_SESSION_ID="$1" bash "$HOOK" ) > "$OUTF" 2>&1
  RC=$?; }
EDIT="modified AFTER its independent v-verify-done-runner dispatch"
ZERO="0000000000000000000000000000000000000000000000000000000000000000"

echo "== VERIFY_DONE post-dispatch tamper gate (forensic 2026-06-18 audit) =="

# 1. THE MOLE: helper-dispatched (capture provenance) + recorded sha != on-disk (flip+delete) -> edited -> BLOCK.
S1="aaaa9999-1111-2222-3333-aaaaaaaaaaaa"; mk_session "$S1"; sig "$S1"; write_vd "$S1"; write_prov "$S1" "$ZERO"
run "$S1"
{ grep -q "$EDIT" "$OUTF" && [ "$RC" -eq 2 ]; } \
  && ok "1 dispatched-then-edited VERIFY_DONE (sha mismatch) -> BLOCK (edited)" || no "1 tamper NOT blocked (rc=$RC)"

# 2. UNTAMPERED: recorded sha == on-disk -> no edited block.
S2="bbbb9999-1111-2222-3333-bbbbbbbbbbbb"; mk_session "$S2"; sig "$S2"; write_vd "$S2"
write_prov "$S2" "$(file_sha "$REPO/VERIFY_DONE_REPORT_${S2}.md")"
run "$S2"
grep -q "$EDIT" "$OUTF" \
  && no "2 untampered VERIFY_DONE wrongly flagged edited (false-block)" || ok "2 untampered VERIFY_DONE (sha matches) -> no edited block"

# 3. HONEST post-dispatch edit declared AND the dispatched original preserved -> NOT the edited block.
#    ORCHFIX-E4: the declaration is honored only while the original survives.
S3="cccc9999-1111-2222-3333-cccccccccccc"; mk_session "$S3"; sig "$S3"
write_vd "$S3"
_s3_orig_sha=$(file_sha "$REPO/VERIFY_DONE_REPORT_${S3}.md")
cp "$REPO/VERIFY_DONE_REPORT_${S3}.md" "$REPO/VERIFY_DONE_REPORT_${S3}.md.stale.orig"
write_vd "$S3" "Post-dispatch edit: fixed a typo in the scan note (verdict unchanged)."
write_prov "$S3" "$_s3_orig_sha"
run "$S3"
grep -q "$EDIT" "$OUTF" \
  && no "3 honest 'Post-dispatch edit:' wrongly blocked as edited" || ok "3 declared post-dispatch edit (original preserved) -> not the edited block"

# 3b. ORCHFIX-E4 pin: declaration with the original DESTROYED -> still the edited BLOCK.
S3B="cccc9999-1111-2222-3333-cccccccccccd"; mk_session "$S3B"; sig "$S3B"
write_vd "$S3B" "Post-dispatch edit: consolidated filenames."
write_prov "$S3B" "$ZERO"
run "$S3B"
grep -q "$EDIT" "$OUTF" \
  && ok "3b declared edit with DESTROYED original -> still BLOCKS (escape precondition)" \
  || no "3b destroyed-original declaration downgraded (E4 regression)"

# 4. FP-SAFE: hand-authored PASS with NO provenance -> the edited arm must NOT fire (no regression for
#    the Agent-tool dispatch path that records no sha; the P0a verdict/FND-BND re-scan is the control there).
S4="dddd9999-1111-2222-3333-dddddddddddd"; mk_session "$S4"; write_vd "$S4"   # no provenance, no sig
run "$S4"
grep -q "$EDIT" "$OUTF" \
  && no "4 hand-authored no-provenance VERIFY_DONE wrongly edited-blocked (regression)" || ok "4 no-provenance VERIFY_DONE -> edited arm does not fire (FP-safe)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
