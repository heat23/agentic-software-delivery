#!/usr/bin/env bash
# v-diff-scope-test.sh — SE-1: ONE source for session diff scope (2026-08-03).
#
# WHY. v-classify-light-tier.sh and v-classify-medium-tier.sh each carried a byte-identical copy of
# the session-scoping machinery. That drift is not hypothetical: W-UNTRACKED (brand-new files
# invisible to `git diff HEAD`/`--cached`) was found in one copy, fixed there, and the ORIGINAL kept
# the bug until it was found a SECOND time — a 2-line config edit + 9 untracked services still
# returning LIGHT=1, the lane that waives QA + VERIFY_DONE + IMPACT_MAP + the gauntlet witness.
#
# The load-bearing assertion here is the NEGATIVE one: neither classifier may define its own
# _changed_lines/_file_diff/CHANGED_FILES assembly. A parity test that merely compares two
# implementations still lets both be wrong together; a single-source assertion cannot.
#
# RED ORACLE: V_LIGHT_CLS/V_MEDIUM_CLS pointed at a .pre-se1-bak (local copies still present).
set -u
LIB="${V_DIFF_SCOPE_LIB:-$HOME/.claude/hooks/lib/v-diff-scope.sh}"
LIGHT_CLS="${V_LIGHT_CLS:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
MED_CLS="${V_MEDIUM_CLS:-$HOME/.claude/skills/v/references/v-classify-medium-tier.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== SE-1 :: the shared lib exists and exports the contract =="
if [ ! -f "$LIB" ]; then
  no "v-diff-scope.sh present" "absent (pre-SE1 = RED)"
else
  ok "v-diff-scope.sh present"
  for fn in v_diff_scope_init _changed_lines _file_diff; do
    grep -qE "^${fn}\(\)" "$LIB" && ok "lib defines ${fn}()" || no "lib missing ${fn}()" ""
  done
fi

echo "== SE-1 :: neither classifier keeps a LOCAL copy (the anti-drift assertion) =="
for pair in "LIGHT:$LIGHT_CLS" "MEDIUM:$MED_CLS"; do
  nm="${pair%%:*}"; f="${pair#*:}"
  [ -f "$f" ] || { no "$nm classifier present" "$f"; continue; }
  # A local definition is the drift vector. Sourcing + CALLING is required instead.
  if grep -qE '^_changed_lines\(\)|^_file_diff\(\)' "$f"; then
    no "$nm classifier has NO local _changed_lines/_file_diff definition" "local copy still present"
  else
    ok "$nm classifier has NO local _changed_lines/_file_diff definition"
  fi
  grep -q 'v-diff-scope.sh' "$f" \
    && ok "$nm classifier references the shared lib" \
    || no "$nm classifier does not reference v-diff-scope.sh" ""
  grep -q 'v_diff_scope_init' "$f" \
    && ok "$nm classifier CALLS v_diff_scope_init (sourcing alone sets nothing)" \
    || no "$nm classifier never calls v_diff_scope_init" ""
done

echo "== SE-1 :: fail-CLOSED when the shared lib is unavailable =="
mkrepo() {
  local r="$WORK/$1"; mkdir -p "$r/config" "$r/tests/Feature"
  git -C "$r" init -q -b main 2>/dev/null || return 1
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  printf '<?php\nreturn [];\n' > "$r/config/app.php"
  printf '<?php\n// t\n' > "$r/tests/Feature/AppTest.php"
  printf '.v/\n' > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '%s' "$r"
}
R=$(mkrepo failclosed) || { no "fixture repo" "git init failed"; R=""; }
if [ -n "$R" ]; then
  printf '<?php\nreturn ["a"=>1];\n' > "$R/config/app.php"
  printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/AppTest.php"
  for pair in "LIGHT:$LIGHT_CLS:LIGHT" "MEDIUM:$MED_CLS:MEDIUM"; do
    nm="${pair%%:*}"; rest="${pair#*:}"; f="${rest%%:*}"; key="${rest#*:}"
    out=$( cd "$R" && CLAUDE_SESSION_ID=se1-sid REPO_ROOT="$R" \
           V_DIFF_SCOPE_LIB=/nonexistent/v-diff-scope.sh bash "$f" 2>/dev/null )
    { printf '%s' "$out" | grep -q "^${key}=0" && printf '%s' "$out" | grep -q 'diff_scope_lib_missing'; } \
      && ok "$nm fails CLOSED when the shared lib is missing" \
      || no "$nm did not fail closed on a missing lib" "$(printf '%s' "$out" | tr '\n' ' ')"
  done
fi

echo "== SE-1 :: lib behaviour — tracked AND untracked are both in scope =="
R2=$(mkrepo behaviour) || R2=""
if [ -n "$R2" ]; then
  printf '<?php\nreturn ["a"=>1];\n' > "$R2/config/app.php"     # tracked, modified
  mkdir -p "$R2/app/Services"
  printf '<?php\nclass New1 { public function go(){ return 1; } }\n' > "$R2/app/Services/New1.php"  # untracked
  # shellcheck source=/dev/null
  out=$( cd "$R2" && REPO_ROOT="$R2" CLAUDE_SESSION_ID=se1-sid bash -c '
      . "'"$LIB"'" || exit 9
      v_diff_scope_init
      printf "%s\n" "$CHANGED_FILES"
      printf "TRACKED_LINES=%s\n"   "$(_changed_lines config/app.php)"
      printf "UNTRACKED_LINES=%s\n" "$(_changed_lines app/Services/New1.php)"' 2>/dev/null )
  printf '%s' "$out" | grep -q '^config/app.php$' \
    && ok "tracked modified file is in CHANGED_FILES" || no "tracked file missing" "$out"
  printf '%s' "$out" | grep -q '^app/Services/New1.php$' \
    && ok "UNTRACKED new file is in CHANGED_FILES (W-UNTRACKED, single-sourced)" || no "untracked file missing" "$out"
  t=$(printf '%s' "$out" | sed -n 's/^TRACKED_LINES=//p'); u=$(printf '%s' "$out" | sed -n 's/^UNTRACKED_LINES=//p')
  [ "${t:-0}" -gt 0 ] 2>/dev/null && ok "tracked file reports >0 changed lines ($t)" || no "tracked line count is 0" "t=$t"
  [ "${u:-0}" -gt 0 ] 2>/dev/null && ok "untracked file reports >0 changed lines ($u — whole body)" || no "untracked line count is 0" "u=$u"
  # DIRECTION PIN (self-review 2026-08-03). The first implementation counted NON-BLANK lines,
  # which under-counts vs the tracked path (`^[+-][^+-]` matches `+   `, a whitespace-only added
  # line). Under-counting makes a tier cap EASIER to clear — the one direction this lib forbids.
  # A file whose body is mostly blank/whitespace must still be counted at full height.
  printf '<?php\n\n\n   \n\nclass Sparse {}\n\n\n' > "$R2/app/Services/Sparse.php"
  sparse=$( cd "$R2" && REPO_ROOT="$R2" CLAUDE_SESSION_ID=se1-sid bash -c \
    '. "'"$LIB"'"; v_diff_scope_init; _changed_lines app/Services/Sparse.php' 2>/dev/null )
  [ "${sparse:-0}" -ge 8 ] 2>/dev/null \
    && ok "untracked line count OVER-counts, never under-counts (sparse 8-line file → $sparse)" \
    || no "untracked count under-counts a sparse file — fail-safe direction inverted" "got $sparse, want >=8"
  # Noise filter must survive extraction.
  printf 'x\n' > "$R2/composer.lock"
  out2=$( cd "$R2" && REPO_ROOT="$R2" CLAUDE_SESSION_ID=se1-sid bash -c '. "'"$LIB"'"; v_diff_scope_init; printf "%s\n" "$CHANGED_FILES"' 2>/dev/null )
  printf '%s' "$out2" | grep -q 'composer.lock' \
    && no "composer.lock leaked into CHANGED_FILES (noise filter lost in extraction)" "" \
    || ok "noise filter survived extraction (composer.lock excluded)"
fi

echo "== SE-1 :: WORKTREE branch — the session-range path, previously untested =="
# Coverage gap called out in the 2026-08-03 self-review: every other fixture here runs in the main
# root with no session lock, so _SESSION_RANGE stays empty and the ENTIRE worktree resolution arm
# (worktree list → .claude-session-lock match → merge-base → committed-file set) was inherited from
# the LIGHT classifier untested. That arm is what attributes a session's COMMITTED work; if it
# silently failed, a session that committed its changes would look like it changed nothing —
# and "no files changed" is a fast-lane verdict.
R3=$(mkrepo wt) || R3=""
if [ -n "$R3" ]; then
  SIDW="wt51ab00-0000-4000-8000-000000000000"
  WT="$WORK/wt-checkout"
  if git -C "$R3" worktree add -q -b "session-${SIDW%%-*}" "$WT" >/dev/null 2>&1; then
    printf '%s main\n' "$SIDW" > "$WT/.claude-session-lock"
    mkdir -p "$WT/app/Services"
    printf '<?php\nclass Committed { public function go(){ return 1; } }\n' > "$WT/app/Services/Committed.php"
    git -C "$WT" add app/Services/Committed.php
    git -C "$WT" -c user.email=t@t.t -c user.name=t commit -qm "session work"
    out3=$( cd "$R3" && REPO_ROOT="$R3" CLAUDE_SESSION_ID="$SIDW" bash -c '
        . "'"$LIB"'" || exit 9
        v_diff_scope_init
        printf "RANGE=%s\n" "${_SESSION_RANGE:-}"
        printf "%s\n" "$CHANGED_FILES"' 2>/dev/null )
    printf '%s' "$out3" | grep -qE '^RANGE=.+\.\..+' \
      && ok "worktree session lock resolves a merge-base RANGE" \
      || no "session range not resolved from the worktree lock" "$(printf '%s' "$out3" | head -1)"
    printf '%s' "$out3" | grep -q '^app/Services/Committed.php$' \
      && ok "a COMMITTED session file is attributed via the session range" \
      || no "committed session work is invisible — would read as 'no files changed'" "$out3"
    git -C "$R3" worktree remove --force "$WT" >/dev/null 2>&1 || true
  else
    no "worktree fixture could not be created" "git worktree add failed"
  fi
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
