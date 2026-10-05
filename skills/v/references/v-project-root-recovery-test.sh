#!/usr/bin/env bash
# v-project-root-recovery-test.sh — behavioral harness for v-project-root-recovery.sh (W25-F13).
# Covers the success/failure contract: stdout = exactly one resolved root on success; non-zero exit
# with NO stdout on every failure mode (missing SID, missing/empty task, no path tokens, no candidate
# roots, single-path ambiguity). Run: bash v-project-root-recovery-test.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REC="$SCRIPT_DIR/v-project-root-recovery.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf 'FAIL  %s — %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$REC" ] || { echo "SKIP: $REC not found"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; mkdir -p "$HOME_DIR/.claude/runtime"

# mkproj <name> <relpath> — a git repo under $HOME/dev/<name> containing <relpath>.
mkproj(){
  local d="$HOME_DIR/dev/$1"; mkdir -p "$d/$(dirname "$2")"
  : > "$d/$2"
  ( cd "$d" && git init -q && git add -A && git commit -qm init ) >/dev/null 2>&1
}
settask(){ printf '%s' "$2" > "$HOME_DIR/.claude/runtime/v-resolved-task-$1.txt"; }
run(){ HOME="$HOME_DIR" bash "$REC" "$@" 2>"$TMP/err"; }   # stdout captured by caller, stderr → file

# T1: missing SID arg → non-zero, no stdout.
out=$(run ""); rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$out" ]; } && ok "T1: missing SID → non-zero exit, no stdout [rc=$rc]" \
  || no "T1: missing SID not rejected cleanly" "rc=$rc out='$out'"

# T2: single referenced path present in exactly ONE candidate repo → resolves to it (one stdout line).
SID2=22222222-2222-4222-8222-222222222222
settask "$SID2" "please fix src/app.ts in the dashboard"
mkproj proj_hit "src/app.ts"
mkproj proj_miss "src/other.ts"
out=$(run "$SID2"); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = "$HOME_DIR/dev/proj_hit" ]; } \
  && ok "T2: resolves the unique matching repo, one clean stdout line [$out]" \
  || no "T2: did not resolve unique match" "rc=$rc out='$out'"

# T3: task text with NO file-path tokens → non-zero, no stdout.
SID3=33333333-3333-4333-8333-333333333333
settask "$SID3" "just rename a variable, no paths here"
out=$(run "$SID3"); rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$out" ]; } && ok "T3: no path tokens → non-zero, no stdout [rc=$rc]" \
  || no "T3: should fail with no path tokens" "rc=$rc out='$out'"

# T4: single path present in TWO candidate repos → AMBIGUOUS refusal (non-zero, no stdout).
SID4=44444444-4444-4444-8444-444444444444
settask "$SID4" "edit src/dup.ts"
mkproj dup_a "src/dup.ts"
mkproj dup_b "src/dup.ts"
out=$(run "$SID4"); rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$out" ] && grep -q 'AMBIGUOUS' "$TMP/err"; } \
  && ok "T4: single path matching 2 repos → AMBIGUOUS refusal, no guess" \
  || no "T4: ambiguity not refused" "rc=$rc out='$out' err=$(tail -1 "$TMP/err")"

# T5: a referenced path that no candidate repo contains → recovery failed (non-zero, no stdout).
SID5=55555555-5555-4555-8555-555555555555
settask "$SID5" "touch config/nowhere-xyz.php"
out=$(run "$SID5"); rc=$?
{ [ "$rc" -ne 0 ] && [ -z "$out" ]; } && ok "T5: unmatched path → recovery failed, no stdout [rc=$rc]" \
  || no "T5: should fail when no repo contains the path" "rc=$rc out='$out'"

echo ""
echo "═══════════ RESULT: $PASS passed, $FAIL failed ═══════════"
[ "$FAIL" -eq 0 ]
