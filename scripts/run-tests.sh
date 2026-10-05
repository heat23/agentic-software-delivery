#!/usr/bin/env bash
# run-tests.sh — run every shipped test, plus the mutation gate, in an isolated scratch $HOME.
#
# The snapshot's scripts resolve their siblings under ~/.claude, so this copies the repository into
# a temporary $HOME/.claude and runs each test with HOME pointed there. Nothing outside the
# temporary directory is read or written. Requires bash, git, jq, python3, openssl, perl and shasum.
#
#   bash scripts/run-tests.sh
#   bash scripts/run-tests.sh run-v-packs-exit-code hooks/   (only tests whose path contains an argument)
#
# Verdicts: PASS; FAIL; KNOWN (listed in scripts/known-issues.txt for this platform, failing no more
# than the listed number of checks); SKIP (the whole file skipped because an optional tool such as php
# isn't installed: reported, not a failure). A file that skips for any other reason, such as a missing
# script, counts as a failure: the runner provides every file a shipped test needs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/.claude"
(cd "$ROOT" && tar cf - --exclude=.git .) | (cd "$SCRATCH/.claude" && tar xf -)
# The pack runner is installed on PATH as ~/.local/bin/run-v-packs, and its tests look for it there.
# It loads its library from the run-v-packs-lib/ directory beside it.
mkdir -p "$SCRATCH/.local/bin"
ln -s "$SCRATCH/.claude/bin/run-v-packs" "$SCRATCH/.local/bin/run-v-packs"
ln -s "$SCRATCH/.claude/bin/run-v-packs-lib" "$SCRATCH/.local/bin/run-v-packs-lib"
# The pack runner refuses to start without the claude CLI on PATH, including on test paths that never
# call it (an empty or oversized pack folder). Where the CLI isn't installed, as on CI runners, a
# stand-in satisfies that check and fails loudly if anything actually invokes it. Tests that exercise
# real runs put their own fake claude first on PATH.
TEST_PATH="$PATH"
if ! command -v claude >/dev/null 2>&1; then
  mkdir -p "$SCRATCH/.stub-bin"
  printf '#!/bin/sh\necho "claude stand-in: the Claude Code CLI is not installed here; this test path needs it" >&2\nexit 127\n' \
    > "$SCRATCH/.stub-bin/claude"
  chmod +x "$SCRATCH/.stub-bin/claude"
  TEST_PATH="$SCRATCH/.stub-bin:$PATH"
  echo "(claude CLI not installed: using a stand-in that fails if a test actually calls it)"
fi
# Git: ignore the machine's system and user configuration, and set the one default the tests assume.
# Apple's git ships a system config with init.defaultBranch=main; Linux git still defaults to master.
printf '[init]\n\tdefaultBranch = main\n' > "$SCRATCH/.gitconfig-tests"
# Drop the caller's Claude Code and orchestrator settings (CLAUDE*, V_*), so every test sees only the
# scratch $HOME whether it runs from a plain shell, CI or inside a Claude Code session.
UNSETS=()
for v in $(env | awk -F= '/^(CLAUDE|V_)[A-Za-z0-9_]*=/ { print $1 }'); do UNSETS+=(-u "$v"); done

failed=0; passed_total=0; skipped_total=0; known=0; stale=0; ran=0; skipped_files=0
# Platform tags for scripts/known-issues.txt: bash3 = bash 3.x is the shell running the tests; linux = GNU stat.
_plat="any"; bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null && _plat="$_plat bash3"
stat -c %Y / >/dev/null 2>&1 && _plat="$_plat linux"
# Prints the listed maximum failure count when the test is listed for a tag this platform has.
_known_count(){ [ -f "$ROOT/scripts/known-issues.txt" ] || return 0
  awk -v t="$1" -v plat=" $_plat " '$1 == t && index(plat, " " $2 " ") { print $3; exit }' "$ROOT/scripts/known-issues.txt"; }
_select(){ if [ "$#" -eq 0 ]; then cat; else local a; local pats=(); for a in "$@"; do pats+=(-e "$a"); done; grep -F "${pats[@]}"; fi; }

if [ "$#" -eq 0 ]; then echo "Running the shipped tests in a scratch \$HOME (about ten minutes)..."
else echo "Running the shipped tests whose path contains: $*"; fi
while IFS= read -r t; do
  ran=$((ran + 1))
  [ "$t" = scripts/mutation-gate.sh ] && echo "  (mutation gate next: about 2-3 minutes with no output until it finishes)"
  out="$(cd "$SCRATCH/.claude" && env ${UNSETS[@]+"${UNSETS[@]}"} HOME="$SCRATCH" PATH="$TEST_PATH" \
          GIT_CONFIG_GLOBAL="$SCRATCH/.gitconfig-tests" GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com \
          GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com bash "$t" </dev/null 2>&1)"
  rc=$?
  summary="$(printf '%s\n' "$out" | grep -E '[0-9]+ passed' | tail -1 | sed -E 's/[═ ]+$//; s/^[═ ]+//')"
  verdict=PASS; [ $rc -eq 0 ] || verdict=FAIL
  if [ $rc -eq 0 ] && [ -z "$summary" ] && printf '%s\n' "$out" | grep -q '^SKIP'; then
    summary="$(printf '%s\n' "$out" | grep '^SKIP' | head -1 | sed "s#$SCRATCH#~#g")"
    # A bare tool name ("SKIP: git", "SKIP: 'php' not available") is a missing optional tool.
    if printf '%s\n' "$summary" | grep -qE "^SKIP:? '?[A-Za-z0-9_.+-]+'?( (unavailable|not available|absent|not installed))?\$"; then
      verdict=SKIP; skipped_files=$((skipped_files + 1))
    else verdict=SKIP; rc=1; fi
  fi
  exp="$(_known_count "$t")"
  if [ -n "$exp" ] && [ "$verdict" != SKIP ]; then
    nfail="$(printf '%s' "$summary" | sed -nE 's/(^|.*[^0-9])([0-9]+) failed.*/\2/p')"
    if [ $rc -ne 0 ] && [ -n "$nfail" ] && [ "$nfail" -ge 1 ] && [ "$nfail" -le "$exp" ]; then verdict=KNOWN; known=$((known + 1)); rc=0
    elif [ $rc -eq 0 ]; then summary="$summary  (listed in known-issues.txt but passed here)"; stale=$((stale + 1))
    else summary="$summary  (known-issues.txt allows at most $exp failed)"; fi
  fi
  printf '%-58s %s  %s\n' "$t" "$verdict" "$summary"
  p=$(printf '%s' "$summary" | sed -nE 's/(^|.*[^0-9])([0-9]+) passed.*/\2/p'); passed_total=$((passed_total + ${p:-0}))
  s=$(printf '%s' "$summary" | sed -nE 's/(^|.*[^0-9])([0-9]+) skipped.*/\2/p'); skipped_total=$((skipped_total + ${s:-0}))
  if [ "$rc" -ne 0 ]; then
    failed=$((failed + 1))
    # show why, instead of hiding it: every failure line, then the end of the output
    printf '%s\n' "$out" | grep -E '^[[:space:]]*(FAIL|NO|not ok|ERROR|FATAL)([[:space:]:]|$)' | head -25 | sed 's/^/      ! /'
    printf '%s\n' "$out" | tail -10 | sed 's/^/      | /'
  fi
done < <(cd "$SCRATCH/.claude" && { find . -name '*-test.sh' | sed 's#^\./##' | sort; echo scripts/mutation-gate.sh; } | _select "$@")

[ "$ran" -gt 0 ] || { echo "no test path contains: $*" >&2; exit 2; }
echo
line="checks passed: $passed_total   skipped: $skipped_total   failing files: $failed   known issues: $known"
[ "$skipped_files" -eq 0 ] || line="$line   skipped files (tool not installed): $skipped_files"
[ "$stale" -eq 0 ] || line="$line   stale known-issue entries: $stale"
echo "$line"
exit $((failed > 0))
