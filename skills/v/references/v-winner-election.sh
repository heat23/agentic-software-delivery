#!/usr/bin/env bash
# v-winner-election.sh — P2 winner-election manifest (2026-07-03).
#
# WHY (forensic 2026-07-03, a third-party API adapter task): SIX same-slug duplicate copies of one
# task existed at once (worktrees + a staged-on-main copy). Landing picked by narration/first-staged
# and chose the WRONG winner — the staged copy had a region guard but ZERO ConnectionException
# handling, while another worktree held the superset (6 handling sites, 11 findings fixed,
# 736/736 tests). Reconciliation-by-narration is the class; this script replaces it with a MACHINE
# ranking by gauntlet depth, so landing picks the strongest copy, not the first-staged one.
#
# Usage: v-winner-election.sh [<repo-root>] <task-slug>
#   <task-slug>  the wave-stripped task name (e.g. api-client-adapter). Candidates = every git
#                worktree/branch whose name contains the slug (build/<slug>-<sid>… convention).
#
# Scoring (per candidate; all mechanically derived — no narration is read):
#   +8  valid gauntlet-attest witness for the candidate's SID (runtime/v-gauntlet-attestation-<sid>.json
#       exists AND its three content-hashes match the artifacts on disk — checked via jq+shasum)
#   +4  QA_REPORT verdict: pass
#   +3  PRE_FLIGHT_REPORT present (+1 more if no FAILED gate rows)
#   +3  AGENT_REVIEW present (+ up to 3 for adjudicated findings: count of ACCEPT/MODIFY lines, capped)
#   +3  VERIFY_DONE_REPORT with Overall Verdict: PASS
#   +2  branch has REAL commits ahead of main (N2: a zero-commit staged copy is NEVER "landed" and
#       ranks below any committed copy at equal artifact depth)
#   +0–5 test breadth: changed test-file lines vs main (committed range + staged), 1 point per 50 lines
#
# Output: ranked TSV on stdout (score, sid8, branch, worktree, components), and a durable manifest at
# <repo-root>/.v/artifacts/WINNER_ELECTION_<slug>.md. Advisory — this script never merges or deletes.
set -uo pipefail

if [ "$#" -ge 2 ]; then REPO_ROOT="$1"; SLUG="$2"; else REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; SLUG="${1:-}"; fi
[ -n "$SLUG" ] || { echo "usage: v-winner-election.sh [<repo-root>] <task-slug>" >&2; exit 2; }
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "ERROR: $REPO_ROOT is not a git repo" >&2; exit 2; }
MAIN="${CLAUDE_MAIN_BRANCH:-main}"

_score_artifact_dirs() { # $1=sid $2=worktree-path → echoes newline list of dirs to search
  printf '%s\n' "$2/.v/artifacts" "$2" "$REPO_ROOT/.v/artifacts" "$REPO_ROOT"
}
_find_art() { # $1=prefix $2=sid $3=wt → path or empty (canonical name first, same rule as the Stop hook)
  local d
  while IFS= read -r d; do
    [ -f "$d/${1}_${2}.md" ] && { printf '%s' "$d/${1}_${2}.md"; return 0; }
  done < <(_score_artifact_dirs "$2" "$3")
  return 1
}

# Candidates: worktrees whose branch OR path contains the slug.
CANDIDATES=$(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null | awk '
  /^worktree /{p=substr($0,10)}
  /^branch /{b=substr($0,8); print p "\t" b}' | grep -i -- "$SLUG" || true)
[ -n "$CANDIDATES" ] || { echo "NO-CANDIDATES: no worktree/branch matching slug '$SLUG'" >&2; exit 1; }

ROWS=""
while IFS="$(printf '\t')" read -r WT BR; do
  [ -n "$WT" ] || continue
  BR_SHORT="${BR#refs/heads/}"
  # SID: prefer the full UUID embedded in the branch/path; fall back to 8-hex slug.
  SID=$(printf '%s\n%s\n' "$BR_SHORT" "$WT" | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
  SID8=$(printf '%s' "${SID:-$(printf '%s\n' "$BR_SHORT" | grep -oiE '[0-9a-f]{8}' | head -1)}" | cut -c1-8)
  SCORE=0; PARTS=""

  # commits ahead of main (N2: zero-commit ≠ landed, and it scores lower)
  AHEAD=$(git -C "$REPO_ROOT" rev-list --count "$MAIN..$BR_SHORT" 2>/dev/null || echo 0)
  if [ "${AHEAD:-0}" -gt 0 ]; then SCORE=$((SCORE+2)); PARTS="${PARTS}commits=${AHEAD}(+2) "; else PARTS="${PARTS}commits=0(staged-only,+0) "; fi

  if [ -n "${SID:-}" ]; then
    # gauntlet witness (content-hash bound)
    WITNESS="$HOME/.claude/runtime/v-gauntlet-attestation-$(printf '%s' "$SID" | tr '[:upper:]' '[:lower:]').json"
    if [ -f "$WITNESS" ] && command -v jq >/dev/null 2>&1; then
      _wok=1
      for _pair in "pre_flight:pre_sha256" "agent_review:rev_sha256" "verify_done:ver_sha256"; do
        _pf=$(jq -r ".${_pair%%:*} // empty" "$WITNESS" 2>/dev/null)
        _ps=$(jq -r ".${_pair##*:} // empty" "$WITNESS" 2>/dev/null)
        if [ -n "$_pf" ] && [ -f "$_pf" ] && [ -n "$_ps" ]; then
          [ "$(shasum -a 256 "$_pf" 2>/dev/null | awk '{print $1}')" = "$_ps" ] || { _wok=0; break; }
        else _wok=0; break; fi
      done
      [ "$_wok" = "1" ] && { SCORE=$((SCORE+8)); PARTS="${PARTS}witness=valid(+8) "; } || PARTS="${PARTS}witness=stale/unbound(+0) "
    else PARTS="${PARTS}witness=none(+0) "; fi

    # QA verdict
    QA=$(_find_art QA_REPORT "$SID" "$WT" || true)
    if [ -n "$QA" ] && grep -qE '^verdict:[[:space:]]*pass' "$QA" 2>/dev/null; then SCORE=$((SCORE+4)); PARTS="${PARTS}qa=pass(+4) "; else PARTS="${PARTS}qa=$([ -n "$QA" ] && echo present-notpass || echo none)(+0) "; fi

    # pre-flight
    PF=$(_find_art PRE_FLIGHT_REPORT "$SID" "$WT" || true)
    if [ -n "$PF" ]; then
      SCORE=$((SCORE+3)); _pfx="present(+3"
      grep -qiE '(❌|FAILED|✗)[[:space:]]*(tests?|build|lint|typecheck)' "$PF" 2>/dev/null || { SCORE=$((SCORE+1)); _pfx="${_pfx},clean+1"; }
      PARTS="${PARTS}preflight=${_pfx}) "
    else PARTS="${PARTS}preflight=none(+0) "; fi

    # agent review + adjudicated findings
    AR=$(_find_art AGENT_REVIEW "$SID" "$WT" || true)
    if [ -n "$AR" ]; then
      SCORE=$((SCORE+3))
      # W40-A idiom (review L#1 CRITICAL, reproduced): `grep -c ... || echo 0` emits "0\n0" on zero
      # matches (grep prints 0 AND exits 1) → arithmetic crash → the candidate with the CLEANEST
      # review silently vanished from the ranking. grep -c always prints exactly one count; no fallback.
      NF=$(grep -ciE '^[[:space:]-]*(ACCEPT|MODIFY)' "$AR" 2>/dev/null | tr -d ' \n'); NF=${NF:-0}
      NF=$(( NF > 3 ? 3 : NF )); SCORE=$((SCORE+NF))
      PARTS="${PARTS}review=present(+3,findings+${NF}) "
    else PARTS="${PARTS}review=none(+0) "; fi

    # verify-done PASS
    VD=$(_find_art VERIFY_DONE_REPORT "$SID" "$WT" || true)
    if [ -n "$VD" ] && grep -qiE '^Overall Verdict:[[:space:]]*PASS' "$VD" 2>/dev/null; then SCORE=$((SCORE+3)); PARTS="${PARTS}verify=pass(+3) "; else PARTS="${PARTS}verify=$([ -n "$VD" ] && echo present-notpass || echo none)(+0) "; fi
  else
    PARTS="${PARTS}sid=unresolved(artifact-scoring-skipped) "
  fi

  # test breadth: committed (merge-base..branch) + staged test-line delta
  MB=$(git -C "$REPO_ROOT" merge-base "$MAIN" "$BR_SHORT" 2>/dev/null || true)
  TLINES=0
  if [ -n "$MB" ]; then
    TLINES=$(git -C "$REPO_ROOT" diff --numstat "$MB" "$BR_SHORT" -- 'tests/' '*Test.php' '*.test.*' '*.spec.*' 2>/dev/null | awk '{s+=$1+$2} END{print s+0}')
  fi
  STAGED_T=$(git -C "$WT" diff --cached --numstat -- 'tests/' '*Test.php' '*.test.*' '*.spec.*' 2>/dev/null | awk '{s+=$1+$2} END{print s+0}')
  TLINES=$(( ${TLINES:-0} + ${STAGED_T:-0} ))
  TB=$(( TLINES / 50 )); [ "$TB" -gt 5 ] && TB=5
  SCORE=$((SCORE+TB)); PARTS="${PARTS}test-lines=${TLINES}(+${TB})"

  ROWS="${ROWS}${SCORE}	${SID8:-????????}	${BR_SHORT}	${WT}	${PARTS}
"
done <<CAND_EOF
$CANDIDATES
CAND_EOF

RANKED=$(printf '%s' "$ROWS" | grep -v '^$' | sort -t"$(printf '\t')" -k1,1 -rn)
echo "SCORE	SID8	BRANCH	WORKTREE	COMPONENTS"
printf '%s\n' "$RANKED"

MANIFEST_DIR="$REPO_ROOT/.v/artifacts"; mkdir -p "$MANIFEST_DIR" 2>/dev/null || true
MANIFEST="$MANIFEST_DIR/WINNER_ELECTION_${SLUG}.md"
{
  echo "# Winner election — task slug '${SLUG}'"
  echo ""
  echo "Machine ranking by gauntlet depth (v-winner-election.sh). Landing MUST pick the top row"
  echo "or document why not — reconciliation-by-narration chose the wrong copy on 2026-07-03."
  echo ""
  echo '```'
  echo "SCORE	SID8	BRANCH	WORKTREE	COMPONENTS"
  printf '%s\n' "$RANKED"
  echo '```'
  echo ""
  echo "N2 note: commits=0 rows are STAGED-ONLY — never treat them as landed (zero-commit branches"
  echo "read as is-ancestor=true), and never GC them before the winner lands."
} > "$MANIFEST" 2>/dev/null || true
echo "manifest: $MANIFEST" >&2
exit 0
