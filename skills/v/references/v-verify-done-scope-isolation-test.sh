#!/usr/bin/env bash
# v-verify-done-scope-isolation-test.sh — HIGH-3 / P0-2 (forensic 2026-06-13).
#
# Observed case: verify-done ran in scoped(fallback-git-state) and computed `git diff base..HEAD` against
# a tree where HEAD had absorbed 5 CONCURRENT SIBLING merges → an 8-file frontend session was scoped
# as 29 files spanning sibling backend commits → a false-positive boundary-drift FAIL. The fix in
# dispatch-v-verify-done.md guards `base..HEAD`: use it ONLY inside THIS session's own worktree on a
# session branch with HEAD ≠ main tip; otherwise restrict to in-flight tree edits and disclose the
# degraded scope.
#
# CONTRACT UPDATE (2026-08-02): the non-isolated branch no longer emits
# `scoped(fallback-git-state:no-isolation)` and no longer grades dirty in-flight edits. W5G-10
# (2026-07-10) replaced it with a hard `Mode: refused` + `NoScope: <sid>` after a
# production incident where that path graded a SIBLING session's uncommitted WIP as a void PASS.
# The two non-isolated cases below therefore assert `refused`, not `no-isolation` — the literal
# `CHANGED_MODE="scoped(fallback-git-state:no-isolation)"` assignment no longer exists in the
# executable bash of dispatch-v-verify-done.md. This is NOT a regression: the dispatch helper
# transparently re-dispatches on a refusal (POSTMERGE_REVERIFY=1 / explicit WORKTREE_PATH), so no
# real /v-verify-done run is blocked — 29 `rejected-noscope-VERIFY_DONE_REPORT_*` artifacts in the
# live corpus confirm the reject-and-re-dispatch path fires as designed. Do NOT "fix" this back to
# no-isolation: that would re-open the void-PASS hole W5G-10 closed.
#
# This suite (a) asserts the BINDING contracts are present in the dispatch prompt and (b) functionally
# extracts the fallback bash block and exercises it across the isolated / non-isolated scenarios.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="$HERE/dispatch-v-verify-done.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

[ -f "$DISPATCH" ] || { echo "FATAL: dispatch prompt not found: $DISPATCH"; exit 2; }

echo "== contract: BINDING rules present =="
grep -q "HIGH-3 scope-isolation" "$DISPATCH" && ok "HIGH-3 scope-isolation BINDING present" || no "HIGH-3 BINDING missing"
grep -q "P0-2 worktree-identity" "$DISPATCH" && ok "P0-2 worktree-identity BINDING present" || no "P0-2 BINDING missing"
grep -q "scoped(fallback-git-state:no-isolation)" "$DISPATCH" && ok "no-isolation Mode disclosed" || no "no-isolation Mode missing"
# W52 enum must list the new variant (lockstep doc maintenance)
grep -q "scoped(fallback-git-state:no-isolation)" "$DISPATCH" && grep -q "literal value of .*CHANGED_MODE" "$DISPATCH" && ok "W52 enum updated in lockstep" || no "W52 enum not updated"

# Extract the fallback bash fence (the block that resolves CHANGED/CHANGED_MODE).
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
SCOPE="$WORK/scope.sh"
# Select the bash fence that actually contains the scope resolver (CHANGED_MODE="scoped(unknown)"),
# not merely the first fence (the P0-2 assertion + SID-resolution stanzas are also bash fences).
awk '
  /^[[:space:]]*```bash[[:space:]]*$/ { inblk=1; buf=""; next }
  inblk && /^[[:space:]]*```[[:space:]]*$/ { if (buf ~ /scoped\(unknown\)/) { printf "%s", buf; exit } inblk=0; next }
  inblk { buf = buf $0 "\n" }
' "$DISPATCH" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then no "could not extract fallback bash block"; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; fi

# Harness: stub the writes-log primary to be empty (force the fallback path), then run the block.
run_block() {  # $1=cwd  -> prints "MODE|FILES"
  local cwd="$1"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -u'
    echo 'export HOME="'"$WORK"'/fakehome"; mkdir -p "$HOME"'   # no session-writes.sh there → fallback
    echo 'SESSION_ID="dead0000-0000-4000-8000-000000000000"'
    echo 'get_session_writes(){ :; }'
    cat "$WORK/block.sh"
    echo 'printf "%s|%s\n" "$CHANGED_MODE" "$(printf "%s" "$CHANGED" | tr "\n" "," )"'
  } > "$SCOPE"
  ( cd "$cwd" && bash "$SCOPE" 2>/dev/null )
}

echo "== syntax: extracted block parses =="
bash -n <(printf 'set -u\nSESSION_ID=x\nget_session_writes(){ :; }\n'; cat "$WORK/block.sh") && ok "extracted fallback block is valid bash" || no "extracted block has syntax error"

# Build a repo: main has base C1 + a SIBLING commit (sib.php). A session worktree forks at C1 and
# adds feat.ts. This mirrors the observed case (FE session) racing a sibling backend merge on main.
R="$WORK/repo"; mkdir -p "$R"; ( cd "$R"
  git init -q; git config user.email t@t; git config user.name t
  echo base > base.txt; git add base.txt; git commit -q -m C1
  git worktree add -q -b build/feat-dead0000 "$WORK/wt" >/dev/null 2>&1
  echo sibling > sib.php; git add sib.php; git commit -q -m "SIBLING merge (concurrent backend)"
) >/dev/null 2>&1
( cd "$WORK/wt" && echo feat > feat.ts && git add feat.ts && git commit -q -m "feat work" ) >/dev/null 2>&1

echo "== ISOLATED: session worktree, on session branch, HEAD != main tip =="
OUT=$(run_block "$WORK/wt"); MODE="${OUT%%|*}"; FILES="${OUT#*|}"
echo "$MODE" | grep -q 'scoped(fallback-git-state)$' && ok "isolated → Mode scoped(fallback-git-state)" || no "isolated wrong mode: $MODE"
echo "$FILES" | grep -q 'feat.ts' && ok "isolated → includes this session's feat.ts" || no "isolated missing feat.ts: $FILES"
echo "$FILES" | grep -q 'sib.php' && no "isolated WRONGLY swept sibling sib.php: $FILES" || ok "isolated → sibling sib.php NOT swept"

echo "== NON-ISOLATED: worktree whose HEAD == main tip (post-merge / wrong-tree, the observed class) =="
# Fast-forward the worktree branch to main's tip so HEAD == main tip (simulates a polluted/post-merge tree).
( cd "$WORK/wt" && git reset --hard main >/dev/null 2>&1 )
OUT=$(run_block "$WORK/wt"); MODE="${OUT%%|*}"; FILES="${OUT#*|}"
echo "$MODE" | grep -q 'refused' && ok "HEAD==main tip → Mode refused (W5G-10 NoScope)" || no "expected Mode refused, got: $MODE"
echo "$FILES" | grep -q 'sib.php' && no "non-isolated WRONGLY swept sibling sib.php (base..HEAD pollution): $FILES" || ok "non-isolated → no base..HEAD sweep (sibling NOT attributed)"

echo "== NON-ISOLATED: shared main checkout (not a linked worktree) =="
OUT=$(run_block "$R"); MODE="${OUT%%|*}"; FILES="${OUT#*|}"
echo "$MODE" | grep -q 'refused' && ok "main checkout → Mode refused (W5G-10 NoScope)" || no "expected Mode refused on main, got: $MODE"
echo "$FILES" | grep -q 'sib.php' && no "main checkout swept committed sib.php via base..HEAD: $FILES" || ok "main checkout → no base..HEAD (committed siblings not swept)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "RESULT: PASS"
