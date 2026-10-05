#!/usr/bin/env bash
# v-strand-redrive.sh [REPO_ROOT] [--probe] — FND-3 LIVENESS RE-DRIVER (forensic 2026-07-04 residual #1).
#
# WHY: v-drain-deferred-merges.sh walks `git worktree list` ONLY. A gauntleted-but-unmerged branch
# whose WORKTREE IS GONE (GC'd, pruned, manually removed) is invisible to every drain trigger —
# a past recovery had to leave checkpoint worktrees parked on disk "intentionally kept so
# drain sees them" because nothing else would ever land those branches. This script closes the
# class: it enumerates LOCAL BRANCHES (not worktrees), finds unmerged /v-session branches whose
# owning session is provably not alive, and RE-ATTACHES them to the drain surface by materializing
# a plain worktree at .worktrees/redrive-<sid8>-<slug>. The next drain pass (same invocation — the
# drain calls this first) then applies ALL existing safety gates unchanged.
#
# SAFETY CONTRACT — this script adds ZERO merge logic and NEVER lands anything itself:
#   • It only MATERIALIZES a worktree (git worktree add, no branch mutation, no lock file).
#     Landing still goes drain → C-1 verdict gate → v-merge-back (W-GATE artifact preconditions,
#     ownership, per-repo merge lock) — the full existing gauntlet-evidence chain.
#   • A branch is a candidate ONLY when ALL hold:
#       - its name ENDS in a /v SID fragment (8-hex or full UUID, tail-anchored — the drain's own
#         regex; user branches like `release-notes` can never match);
#       - it is NOT attached to any registered worktree (attached strands are the drain's job);
#       - it is NOT an ancestor of MAIN (worktree-less ⇒ no staged bytes ⇒ ancestor = landed);
#       - commits-ahead > 0;
#       - no registered worktree lock carries the same SID with a LIVE pid, and the SID is not
#         reported live by v-active-siblings.sh (fail toward SKIP);
#       - the branch tip is at least V_REDRIVE_MIN_TIP_AGE_MIN old (default 60) — never race a
#         session that just committed (a live /v session normally holds a locked worktree, but a
#         freshly-dead one may still have gate subagents flushing artifacts).
#   • GAUNTLET EVIDENCE PRE-CHECK (C-1 mirror, LAND-enabling side only): a worktree is materialized
#     ONLY when an AGENT_REVIEW_<sid>* / GAUNTLET_SKIPPED_<sid>* artifact exists durably (full-SID
#     match when known — F4 parity; sid8-UUID-shaped fallback otherwise). This avoids worktree
#     churn for ungated strands; the drain's C-1 gate independently re-verifies (incl. QA-fail /
#     BLOCKED / merge-hold HOLD-side evidence this pre-check deliberately does not duplicate).
#   • UNGAUNTLETED worktree-less strands are NEVER silent: an idempotent merge-deferred-<sid>.md
#     record (reason: ungauntleted) is written so the strand is durable, registry-sticky, visible
#     to the integrity sweep, and auto-GC'd by the drain's gc_markers once the branch lands.
#     The named manual path is "gauntlet it via a runner pack, or review + v-merge-back".
#   • --probe: read-only census. Prints `strands=<n>` (n = materializable candidates + ungated
#     strands not yet recorded) so hot-path hooks can trigger a full drain cheaply. Changes nothing.
#   • V_REDRIVE_DRY_RUN=1 previews. Exit is ALWAYS 0 — a re-driver must not become a failure surface.
#
# Bite: v-strand-redrive-test.sh (red vs v-drain-deferred-merges.sh.pre-redrive0704-bak — the
# pre-fix drain never considers a worktree-less branch, the strand-liveness class).
set -uo pipefail

_SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
PROBE=0; _repo_arg=""
for _a in "$@"; do
  case "$_a" in --probe) PROBE=1 ;; *) [ -n "$_repo_arg" ] || _repo_arg="$_a" ;; esac
done
REPO_ROOT="${_repo_arg:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
DRY="${V_REDRIVE_DRY_RUN:-0}"
MIN_TIP_AGE_MIN="${V_REDRIVE_MIN_TIP_AGE_MIN:-60}"

command -v git >/dev/null 2>&1 || { [ "$PROBE" = 1 ] && echo "strands=0"; exit 0; }
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { [ "$PROBE" = 1 ] && echo "strands=0"; exit 0; }

# Resolve the MAIN worktree root (same derivation as the drain — markers/worktrees belong there).
_gcd="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
case "$_gcd" in /*) ;; ?*) _gcd="$REPO_ROOT/$_gcd" ;; *) _gcd="" ;; esac
[ -n "$_gcd" ] && MAIN_ROOT="$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd)" || MAIN_ROOT="$REPO_ROOT"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$REPO_ROOT"
git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$MAIN_BRANCH" 2>/dev/null \
  || { [ "$PROBE" = 1 ] && echo "strands=0"; exit 0; }
_now="$(date +%s 2>/dev/null || echo 0)"

# Shared lock parser (same lib the drain sources) — used only to detect a LIVE same-SID lock on
# some OTHER registered worktree. Lib absent ⇒ that check is skipped (tip-age + active-siblings
# still guard); it can only make us MORE conservative, never less.
_LOCK_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
# shellcheck disable=SC1090
[ -f "$_LOCK_LIB" ] && . "$_LOCK_LIB" || true

# ── Cheap-first candidate enumeration (this runs from per-Stop hot-path probes) ──────────────────
# 1) attached-branch set (one worktree-list call)  2) sid-tail branches only  3) ancestry/ahead last.
_attached="$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^branch refs\/heads\///p')"
_branch_attached(){ printf '%s\n' "$_attached" | grep -qxF "$1"; }

# Live-SID census: every registered worktree lock whose pid is alive (worktree-attached sessions).
_live_sids=""
if command -v _lock_sid >/dev/null 2>&1 && command -v _lock_pid >/dev/null 2>&1; then
  while IFS= read -r _wt; do
    [ -n "$_wt" ] && [ -f "$_wt/.claude-session-lock" ] || continue
    _lp="$(_lock_pid "$_wt/.claude-session-lock" 2>/dev/null)"
    case "$_lp" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$_lp" 2>/dev/null || continue
    _live_sids="${_live_sids}$(_lock_sid "$_wt/.claude-session-lock" 2>/dev/null)"$'\n'
  done < <(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
fi
# v-active-siblings union (transcript-mtime aware) — best-effort, fail-open.
_SIBLINGS_SH="$_SD/v-active-siblings.sh"
if [ -f "$_SIBLINGS_SH" ]; then
  _live_sids="${_live_sids}$(bash "$_SIBLINGS_SH" "$MAIN_ROOT" none 2>/dev/null | awk '{print $1}')"$'\n'
fi
_sid_alive(){ # $1=sid (full or sid8) — substring-prefix match against the live census
  [ -n "$1" ] || return 1
  printf '%s\n' "$_live_sids" | grep -qE "^${1%%-*}" 2>/dev/null
}

# LAND-enabling gauntlet evidence (C-1 mirror, F4 full-SID parity). $1=sid → 0 when present.
_gauntlet_evidence(){
  local sid="$1" sid8 pat d hit=""
  sid8="${sid%%-*}"
  case "$sid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) pat="$sid" ;;
    *) pat="${sid8}-*-*-*-*" ;;
  esac
  for d in "$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp"; do
    [ -d "$d" ] || continue
    hit="$(find "$d" -maxdepth 1 \( -name "AGENT_REVIEW_${pat}*" -o -name "GAUNTLET_SKIPPED_${pat}*" \) 2>/dev/null | head -1 || true)"
    [ -n "$hit" ] && return 0
  done
  return 1
}

# Full-SID expansion via SID-bearing proof-artifact filenames (P0-2 parity with the drain —
# v-merge-back hard-refuses short SIDs, so record full UUIDs whenever one is recoverable).
_expand_sid(){
  local short="$1" d g full
  case "$short" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) printf '%s' "$short"; return 0 ;;
  esac
  for d in "$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp"; do
    [ -d "$d" ] || continue
    for g in "$d"/AGENT_REVIEW_"${short}"*.md "$d"/GAUNTLET_SKIPPED_"${short}"* "$d"/merge-deferred-"${short}"*.md \
             "$d"/VERIFY_DONE_REPORT_"${short}"*.md "$d"/PRE_FLIGHT_REPORT_"${short}"*.md "$d"/HANDOFF_"${short}"*.md; do
      [ -f "$g" ] || continue
      full="$(basename "$g" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
      [ -n "$full" ] && { printf '%s' "$full"; return 0; }
    done
  done
  printf '%s' "$short"
  return 1
}

_deferred_record_exists(){ # $1=sid (full or sid8)
  local d
  for d in "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp"; do
    [ -n "$(find "$d" -maxdepth 1 -name "merge-deferred-${1%%-*}*.md" 2>/dev/null | head -1 || true)" ] && return 0
  done
  return 1
}

candidates=0; materialized=0; held=0; skipped_live=0; skipped_young=0; skipped_dup=0; failed=0; probe_strands=0
while IFS= read -r br; do
  [ -n "$br" ] || continue
  [ "$br" = "$MAIN_BRANCH" ] && continue
  # QA-1 (2026-07-05): only /v-namespace branches are candidates. An 8-hex tail alone is NOT proof
  # of a /v session — human branches like release/v1-1a2b3c4d (short-SHA/ticket suffix) matched the
  # SID regex and got noise strand-records. /v names every session branch <mode>/<slug>-<sid> with
  # mode ∈ build|fix (v-worktree-adopt-or-create.sh contract; run-v-packs GC uses the same family).
  printf '%s' "$br" | grep -qE "${V_REDRIVE_BRANCH_RE:-^(build|fix)/}" || continue
  _branch_attached "$br" && continue                       # attached ⇒ the drain's normal walk owns it
  # Tail-anchored SID fragment (drain-parity regex; tail-anchor kills the slug-embedded-UUID head-1 trap).
  sid="$(printf '%s' "$br" | sed -nE 's/.*[-_/]([0-9a-f]{8}(-[0-9a-f]{4}){0,3}(-[0-9a-f]{12})?)$/\1/p')"
  [ -n "$sid" ] || continue                                # no SID tail ⇒ user branch ⇒ never touch
  git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null && continue   # landed
  _ahead="$(git -C "$MAIN_ROOT" rev-list --count "${MAIN_BRANCH}..${br}" 2>/dev/null || echo 0)"
  case "$_ahead" in ''|*[!0-9]*) _ahead=0 ;; esac
  [ "$_ahead" -gt 0 ] || continue
  candidates=$((candidates+1))
  if _sid_alive "$sid"; then
    skipped_live=$((skipped_live+1))
    [ "$PROBE" = 1 ] || echo "  ⏭ skip $br — SID ${sid%%-*} is LIVE elsewhere (lock/sibling census); not re-driving a live session's branch"
    continue
  fi
  _tipct="$(git -C "$MAIN_ROOT" log -1 --format=%ct "$br" 2>/dev/null || echo 0)"
  case "$_tipct" in ''|*[!0-9]*) _tipct=0 ;; esac
  if [ "$_tipct" -le 0 ] || [ $(( (_now - _tipct) / 60 )) -lt "$MIN_TIP_AGE_MIN" ]; then
    skipped_young=$((skipped_young+1))
    [ "$PROBE" = 1 ] || echo "  ⏭ skip $br — tip younger than ${MIN_TIP_AGE_MIN}m (or unreadable); never race a freshly-dead session's flushing artifacts"
    continue
  fi
  # SUPERSEDED duplicate lane (batch-3, 2026-07-05): every commit patch-equivalent to a commit
  # already on MAIN (`git cherry` shows no `+`) ⇒ the task landed via another lane (the
  # duplicate-lane class). NOT a strand — recording it as one would trigger drains forever for
  # work that is already shipped. Report as a prune candidate (v-dup-lane-detect.sh prunes).
  _cherry="$(git -C "$MAIN_ROOT" cherry "$MAIN_BRANCH" "$br" 2>/dev/null || true)"
  if [ -n "$_cherry" ] && ! printf '%s\n' "$_cherry" | grep -q '^+'; then
    skipped_dup=$((skipped_dup+1))
    [ "$PROBE" = 1 ] || echo "  ▲ skip $br — SUPERSEDED duplicate lane (all commits patch-equivalent to $MAIN_BRANCH); prune via v-dup-lane-detect.sh V_DUP_PRUNE=1"
    continue
  fi
  # DUPLICATE-WORKTREE guard (batch-3, 2026-07-05): a same-slug family sibling already has an
  # ATTACHED worktree — that lane (live or dead) is already on the drain's surface and its landing
  # adjudicates the task. Materializing THIS lane too would put two same-task lanes on the drain
  # simultaneously (double-land risk for divergent twins). Skip; once the sibling resolves, this
  # branch reads superseded (pruned) or becomes the sole lane (re-attached next pass).
  # CODEX-001 (adversarial review 2026-07-05, PoC'd): the sibling match must be the FULL
  # end-anchored SID shape — `fam-[0-9a-f]` alone let an UNRELATED longer family sharing a
  # hex-letter-starting suffix (build/cache vs build/cache-adapter) permanently veto a legitimate
  # strand's re-drive. Same tail-anchored discipline as the SID extraction above.
  _fam="${br%-"$sid"}"
  if [ -n "$_fam" ] && [ "$_fam" != "$br" ] && printf '%s\n' "$_attached" | grep -qE "^$(printf '%s' "$_fam" | sed 's/[.[\*^$+?{}()|]/\\&/g')-[0-9a-f]{8}(-[0-9a-f]{4}){0,3}(-[0-9a-f]{12})?$"; then
    skipped_dup=$((skipped_dup+1))
    [ "$PROBE" = 1 ] || echo "  ⏭ skip $br — same-slug sibling lane already has an attached worktree (duplicate-worktree guard); its landing adjudicates this task"
    continue
  fi
  sid="$(_expand_sid "$sid" || true)"
  # An operator/detector merge-hold for this lane ⇒ the drain would HOLD it anyway — do not
  # materialize worktree churn for a deliberately held lane.
  if [ -n "$(find "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" -maxdepth 1 -name "merge-hold-${sid%%-*}*" 2>/dev/null | head -1 || true)" ]; then
    held=$((held+1))
    [ "$PROBE" = 1 ] || echo "  ⏸ skip $br — merge-hold marker present; not re-attaching a held lane"
    continue
  fi
  if ! _gauntlet_evidence "$sid"; then
    # UNGAUNTLETED worktree-less strand — never silent, never landed from here.
    if _deferred_record_exists "$sid"; then
      held=$((held+1)); continue                           # already durably recorded ⇒ no probe re-trigger
    fi
    probe_strands=$((probe_strands+1)); held=$((held+1))
    [ "$PROBE" = 1 ] && continue
    if [ "$DRY" = 1 ]; then
      echo "  [dry-run] would record UNGAUNTLETED worktree-less strand: $br (sid=${sid%%-*}, ${_ahead} ahead)"
      continue
    fi
    _mk="$MAIN_ROOT/.v/artifacts/merge-deferred-${sid}.md"
    if mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null; then
      {
        echo "# UNGAUNTLETED WORKTREE-LESS STRAND discovered by v-strand-redrive — ${sid}"
        echo
        echo "deferred_sid:    ${sid}"
        echo "worktree_branch: ${br}"
        echo "merge_target:    ${MAIN_BRANCH}"
        echo "commits_ahead:   ${_ahead}"
        echo "reason:          ungauntleted (no AGENT_REVIEW/GAUNTLET_SKIPPED artifact on disk)"
        echo "discovered_at:   $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
        echo
        echo "This branch has ${_ahead} unmerged commit(s), no worktree, no live owner, and NO gauntlet"
        echo "evidence — it must NOT be auto-landed (SESSION-ENDED ≠ GAUNTLET-COMPLETE). Manual path:"
        echo "gauntlet it via a runner pack (run-v-packs) or review it and land with v-merge-back."
        echo "This record auto-clears (gc_markers) once the branch lands."
      } > "$_mk" 2>/dev/null \
        && echo "  ✎ recorded ungauntleted worktree-less strand $br → $(basename "$_mk")"
    fi
    continue
  fi
  # Gauntleted, dead-owner, worktree-less ⇒ MATERIALIZE so the drain's walk (with its full C-1 +
  # merge-back gate chain) can land it. No lock is written: the drain's lockless path requires a
  # stranding proof — commits-ahead>0 (H-4) plus the very AGENT_REVIEW that passed the pre-check.
  probe_strands=$((probe_strands+1))
  [ "$PROBE" = 1 ] && continue
  _slug="$(printf '%s' "$br" | tr '/' '-' | tr -cd 'a-zA-Z0-9._-' | tail -c 48)"
  _wt="$MAIN_ROOT/.worktrees/redrive-${_slug}"
  if [ "$DRY" = 1 ]; then
    echo "  [dry-run] would materialize worktree for gauntleted strand: $br → $_wt"
    materialized=$((materialized+1)); continue
  fi
  mkdir -p "$MAIN_ROOT/.worktrees" 2>/dev/null || true
  if [ -d "$_wt" ]; then
    echo "  ℹ $br — redrive worktree already exists ($_wt); leaving it for the drain"
    materialized=$((materialized+1))
  elif git -C "$MAIN_ROOT" worktree add --quiet "$_wt" "$br" 2>/dev/null; then
    materialized=$((materialized+1))
    echo "  ✓ re-attached gauntleted strand $br → $_wt (drain's C-1 + merge-back gates decide the landing)"
  else
    failed=$((failed+1))
    echo "  ✗ could not materialize worktree for $br (git worktree add failed) — left untouched"
  fi
done < <(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

if [ "$PROBE" = 1 ]; then
  echo "strands=$probe_strands"
else
  echo "v-redrive: candidates=$candidates materialized=$materialized held-ungauntleted=$held skipped-LIVE=$skipped_live skipped-young=$skipped_young skipped-dup=$skipped_dup failed=$failed"
fi
exit 0
