#!/usr/bin/env bash
# v-dup-lane-detect.sh [REPO_ROOT] — DUPLICATE-DISPATCH lane detector (forensic 2026-07-04, batch-3).
#
# THE CLASS: two dispatches of the SAME task mint same-slug branches under different SIDs (observed:
# two same-slug lanes, one winner landed on main, both loser lanes left
# ahead=1 forever). W71-F11/F11b block this at DISPATCH time; nothing detects the lanes that already
# exist (pre-guard debris, guard overrides, inline-on-main copies). Undetected duplicate lanes read as
# "unmerged work owed" to every driver (drain, redrive, integrity sweeps) and can double-land a task.
#
# WHAT IT DOES (report-first, act-opt-in):
#   For every UNMERGED local branch shaped `<mode>/<slug>-<sid>` (uuid or 8-hex tail), grouped by
#   `<mode>/<slug>` family:
#   • SUPERSEDED  — `git cherry <main> <br>` shows NO `+` lines (every commit patch-equivalent to a
#     commit already on main): the task landed via another lane. Prune candidate. With V_DUP_PRUNE=1
#     the branch is deleted — ONLY when no worktree is attached (an attached worktree may hold
#     uncommitted content — the false-landed-by-reset lesson) — otherwise it is only reported.
#   • ZERO-DIVERGENCE — two+ unmerged family members whose `git diff <main>...<br>` patch-ids are
#     IDENTICAL: literal duplicate dispatches. The OLDEST tip is left free to land through its own
#     gates; each younger twin gets a durable `merge-hold-<sid8>-dup-lane.md` marker (the drain's
#     C-1 gate already honors merge-hold-* — so a twin can never auto-land) naming the kept sibling.
#   • DIVERGENT-FAMILY — same-slug unmerged members whose content differs (and is not on main):
#     a real duplicate-dispatch that needs SME adjudication. Reported loudly; NO automatic hold
#     (over-holding divergent work hides it from the operator's normal landing path).
#   Everything goes to stdout AND a durable .v/artifacts/DUP_LANE_REPORT_<yyyymmdd>.md (appended,
#   deduped per run-stamp) so forensics/sweeps see what was found even if the terminal scrolled away.
#
# SAFETY: read-only by default. V_DUP_PRUNE=1 deletes ONLY SUPERSEDED+worktree-less branches whose
# content is provably on main (patch-equivalence via git cherry). Markers are additive signal files.
# Exit is ALWAYS 0. Bite: v-dup-lane-detect-test.sh.
set -uo pipefail

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
PRUNE="${V_DUP_PRUNE:-0}"
DRY="${V_DUP_DRY_RUN:-0}"

command -v git >/dev/null 2>&1 || exit 0
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || exit 0
_gcd="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
case "$_gcd" in /*) ;; ?*) _gcd="$REPO_ROOT/$_gcd" ;; *) _gcd="" ;; esac
[ -n "$_gcd" ] && MAIN_ROOT="$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd)" || MAIN_ROOT="$REPO_ROOT"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$REPO_ROOT"
git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" 2>/dev/null || exit 0

_SID_TAIL_RE='[0-9a-f]{8}(-[0-9a-f]{4}){0,3}(-[0-9a-f]{12})?$'
_attached_wt(){ # $1=branch → prints worktree path if attached
  git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null \
    | awk -v b="refs/heads/$1" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w; exit}'
}
_patch_id(){ # $1=branch → stable patch-id of its full diff vs main (empty on error/empty diff)
  git -C "$MAIN_ROOT" diff "${MAIN_BRANCH}...$1" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1}' | head -1
}
_superseded(){ # $1=branch → 0 when every commit is patch-equivalent to main (no `+` lines)
  local ch
  ch="$(git -C "$MAIN_ROOT" cherry "$MAIN_BRANCH" "$1" 2>/dev/null)" || return 1
  [ -n "$ch" ] || return 1                        # no commits at all ⇒ not our case (ahead=0)
  printf '%s\n' "$ch" | grep -q '^+' && return 1  # something genuinely new ⇒ not superseded
  return 0
}

REPORT="$MAIN_ROOT/.v/artifacts/DUP_LANE_REPORT_$(date -u +%Y%m%d 2>/dev/null || echo undated).md"
_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
_report_lines=""
_say(){ echo "$1"; _report_lines="${_report_lines}${1}"$'\n'; }

# ── collect unmerged slug-family members: "family<TAB>branch<TAB>sid" ────────────────────────────
_rows=""
while IFS= read -r br; do
  [ -n "$br" ] || continue
  [ "$br" = "$MAIN_BRANCH" ] && continue
  # QA-1 parity with v-strand-redrive.sh: only /v-namespace (build/|fix/) branches — an 8-hex
  # tail on a human branch (release/v1-1a2b3c4d) is not a /v lane.
  printf '%s' "$br" | grep -qE "${V_REDRIVE_BRANCH_RE:-^(build|fix)/}" || continue
  sid="$(printf '%s' "$br" | grep -oE "$_SID_TAIL_RE" | tail -1)"
  [ -n "$sid" ] || continue
  fam="${br%-"$sid"}"
  case "$fam" in */*) ;; *) continue ;; esac      # need a mode/slug shape
  git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null && continue
  _ahead="$(git -C "$MAIN_ROOT" rev-list --count "${MAIN_BRANCH}..${br}" 2>/dev/null || echo 0)"
  case "$_ahead" in ''|*[!0-9]*) _ahead=0 ;; esac
  [ "$_ahead" -gt 0 ] || continue
  _rows="${_rows}${fam}"$'\t'"${br}"$'\t'"${sid}"$'\n'
done < <(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

superseded=0; twins=0; divergent=0; pruned=0
# ── pass 1: SUPERSEDED lanes (content provably on main) ─────────────────────────────────────────
_live_rows=""
while IFS=$'\t' read -r fam br sid; do
  [ -n "$br" ] || continue
  if _superseded "$br"; then
    superseded=$((superseded+1))
    wt="$(_attached_wt "$br")"
    if [ "$PRUNE" = 1 ] && [ -z "$wt" ]; then
      if [ "$DRY" = 1 ]; then
        _say "  [dry-run] SUPERSEDED $br — would prune (all commits patch-equivalent to $MAIN_BRANCH)"
      elif git -C "$MAIN_ROOT" branch -D "$br" >/dev/null 2>&1; then
        pruned=$((pruned+1))
        _say "  ✂ pruned SUPERSEDED duplicate lane $br (every commit patch-equivalent to $MAIN_BRANCH; no worktree)"
      else
        _say "  ✗ SUPERSEDED $br — prune failed (git branch -D error); left in place"
      fi
    else
      [ -n "$wt" ] \
        && _say "  ⏸ SUPERSEDED $br — content already on $MAIN_BRANCH but a WORKTREE is attached ($wt); not pruning (it may hold uncommitted content) — inspect + remove the worktree, then re-run with V_DUP_PRUNE=1" \
        || _say "  ▲ SUPERSEDED duplicate lane $br — every commit patch-equivalent to $MAIN_BRANCH (prune candidate; re-run with V_DUP_PRUNE=1 to delete)"
    fi
    continue
  fi
  _live_rows="${_live_rows}${fam}"$'\t'"${br}"$'\t'"${sid}"$'\n'
done <<EOF_ROWS
$_rows
EOF_ROWS

# ── pass 2: same-family comparison (zero-divergence twins vs divergent duplicates) ──────────────
# CODEX-002 (adversarial review 2026-07-05, PoC'd): twins are found by grouping ALL family members
# by patch-id — NOT by comparing each member only against the family eldest. Eldest-only comparison
# missed a genuine twin PAIR among the non-eldest members of a 3+-way family (reported both as
# "DIVERGENT, no action" → both could land = the exact double-landing this tool exists to prevent).
# Within each equal-patch-id group the OLDEST tip stays free; every younger group member is held.
_fams="$(printf '%s' "$_live_rows" | cut -f1 | sort | uniq -d)"
while IFS= read -r fam; do
  [ -n "$fam" ] || continue
  _members="$(printf '%s' "$_live_rows" | awk -F'\t' -v f="$fam" '$1==f{print $2}')"
  # "ct <TAB> branch <TAB> patch-id" per member, oldest first (empty patch-id → literal '-')
  _rows2="$(while IFS= read -r m; do
      [ -n "$m" ] || continue
      _p="$(_patch_id "$m")"; [ -n "$_p" ] || _p='-'
      printf '%s\t%s\t%s\n' "$(git -C "$MAIN_ROOT" log -1 --format=%ct "$m" 2>/dev/null || echo 0)" "$m" "$_p"
    done <<EOF_M
$_members
EOF_M
)"
  _sorted="$(printf '%s\n' "$_rows2" | sort -n)"
  _eldest="$(printf '%s\n' "$_sorted" | head -1 | cut -f2)"
  while IFS=$'\t' read -r _ct m _mpid; do
    [ -n "$m" ] || continue
    _msid="$(printf '%s' "$m" | grep -oE "$_SID_TAIL_RE" | tail -1)"; _msid8="${_msid%%-*}"
    # twin group = same non-empty patch-id; the group's oldest member stays free
    _twin_elder=""
    if [ "$_mpid" != "-" ]; then
      _twin_elder="$(printf '%s\n' "$_sorted" | awk -F'\t' -v p="$_mpid" '$3==p{print $2; exit}')"
    fi
    if [ -n "$_twin_elder" ] && [ "$_twin_elder" != "$m" ]; then
      twins=$((twins+1))
      _mk="$MAIN_ROOT/.v/artifacts/merge-hold-${_msid8}-dup-lane.md"
      if [ "$DRY" = 1 ]; then
        _say "  [dry-run] ZERO-DIVERGENCE twin $m ≡ $_twin_elder — would write $(basename "$_mk")"
      elif [ ! -f "$_mk" ] && mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null; then
        {
          echo "# merge-hold — ZERO-DIVERGENCE duplicate lane (v-dup-lane-detect, $_stamp)"
          echo
          echo "branch:        $m"
          echo "identical_to:  $_twin_elder (patch-id $_mpid)"
          echo
          echo "This lane's full diff vs $MAIN_BRANCH is byte-for-byte patch-identical to its elder"
          echo "same-slug sibling — a duplicate dispatch. The elder lane lands normally through its"
          echo "own gates; this one is HELD (the drain's C-1 gate honors merge-hold-*). Once the"
          echo "elder lands, this branch becomes SUPERSEDED and prunable (V_DUP_PRUNE=1)."
          echo "To land THIS lane instead: delete this marker and hold/prune the sibling."
        } > "$_mk" 2>/dev/null
        _say "  ⛔ ZERO-DIVERGENCE twin $m ≡ $_twin_elder — held via $(basename "$_mk") (elder lands, twin waits)"
      else
        _say "  ⛔ ZERO-DIVERGENCE twin $m ≡ $_twin_elder — hold marker already present"
      fi
    elif [ "$m" != "$_eldest" ]; then
      divergent=$((divergent+1))
      _say "  ⚠ DIVERGENT same-slug duplicate: $m vs $_eldest (family $fam) — two dispatches implemented this task DIFFERENTLY; SME adjudication needed (diff them, keep one, hold/prune the other). No automatic action taken."
    fi
  done <<EOF_S
$_sorted
EOF_S
done <<EOF_F
$_fams
EOF_F

_tally="v-dup-lane: superseded=$superseded pruned=$pruned zero-divergence-held=$twins divergent-reported=$divergent"
echo "$_tally"
if [ "$DRY" != 1 ] && [ -n "$_report_lines" ] && mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null; then
  {
    echo "## v-dup-lane-detect run $_stamp"
    printf '%s' "$_report_lines"
    echo "$_tally"
    echo
  } >> "$REPORT" 2>/dev/null || true
fi
exit 0
