#!/usr/bin/env bash
# v-artifact-consolidate-p13-test.sh — DISPATCH_PROVENANCE (.log) must be consolidated from a worktree
# source into MAIN/.v/artifacts, APPEND-MERGED so no entry is lost. Before the fix (P13) the .log was
# absent from _PREFIXES and the copy glob was .md-only, so worktree provenance was dropped on prune →
# the independence gate read dispatch_path=none and false-flagged an honest dispatch.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
TOOL="$HOME/.claude/skills/v/references/v-artifact-consolidate.sh"
[ -f "$TOOL" ] || { echo "SKIP: missing $TOOL"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R/.v/artifacts"
( cd "$R" && git init -q -b main && printf '.v/\n' > .gitignore && git add -A && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
SID="eeeeeeee-0000-0000-0000-00000000eeee"
WT="$BASE/wt/.v/artifacts"; mkdir -p "$WT"
DST="$R/.v/artifacts/DISPATCH_PROVENANCE_${SID}.log"
mk_wt(){ printf 'DISPATCH|ts=t|agent=codex-adversarial-reviewer|mode=capture|status=ok|cost_usd=0.5|duration_ms=1|artifact=AGENT_REVIEW_%s.md|sha256=wt\n' "$SID" > "$WT/DISPATCH_PROVENANCE_${SID}.log"; }

# Case 1: no main-side provenance → the worktree one is consolidated into MAIN/.v/artifacts.
mk_wt
( cd "$R" && bash "$TOOL" "$SID" "$WT" ) >/dev/null 2>&1
[ -f "$DST" ] && grep -q 'sha256=wt' "$DST" \
  && ok "worktree DISPATCH_PROVENANCE consolidated to MAIN/.v/artifacts" \
  || no "provenance .log NOT consolidated" "$(ls -la "$R/.v/artifacts" 2>&1)"

# Case 2 (append-merge): a DISTINCT main-side entry + a distinct worktree entry → BOTH must survive.
printf 'DISPATCH|ts=t|agent=v-pre-flight-runner|mode=capture|status=ok|cost_usd=0.1|duration_ms=1|artifact=PRE_FLIGHT_REPORT_%s.md|sha256=main\n' "$SID" > "$DST"
mk_wt
( cd "$R" && bash "$TOOL" "$SID" "$WT" ) >/dev/null 2>&1
if grep -q 'sha256=main' "$DST" && grep -q 'sha256=wt' "$DST"; then
  ok "append-merge: main-side AND worktree-side entries both survive (no loss)"
else
  no "append-merge lost an entry" "$(cat "$DST" 2>&1)"
fi

# Case 3 (partial-overlap dedup): main has {A,B}, worktree has {B,C} → merged = {A,B,C}, shared line B once.
printf 'DISPATCH|line=A|sha256=aaa\nDISPATCH|line=B|sha256=bbb\n' > "$DST"
printf 'DISPATCH|line=B|sha256=bbb\nDISPATCH|line=C|sha256=ccc\n' > "$WT/DISPATCH_PROVENANCE_${SID}.log"
( cd "$R" && bash "$TOOL" "$SID" "$WT" ) >/dev/null 2>&1
_a=$(grep -c 'sha256=aaa' "$DST"); _b=$(grep -c 'sha256=bbb' "$DST"); _c=$(grep -c 'sha256=ccc' "$DST")
if [ "$_a" = 1 ] && [ "$_b" = 1 ] && [ "$_c" = 1 ]; then
  ok "partial-overlap merge: union {A,B,C} with the shared line de-duplicated (each once)"
else no "partial-overlap dedup wrong (a=$_a b=$_b c=$_c)" "$(cat "$DST" 2>&1)"; fi

# Case 4 (no worktree source): only main has provenance, the worktree dir has none → main left intact (no-op).
rm -f "$WT/DISPATCH_PROVENANCE_${SID}.log"
printf 'DISPATCH|line=ONLYMAIN|sha256=zzz\n' > "$DST"
( cd "$R" && bash "$TOOL" "$SID" "$WT" ) >/dev/null 2>&1
{ grep -q 'sha256=zzz' "$DST" && [ "$(grep -c 'DISPATCH' "$DST")" = 1 ]; } \
  && ok "no worktree source -> main provenance left intact (no-op, no corruption/loss)" \
  || no "main provenance altered/lost with no worktree source" "$(cat "$DST" 2>&1)"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
