#!/usr/bin/env bash
# v-drain-deferred-merges.sh [REPO_ROOT] — land STRANDED /v worktree fixes whose owning session has ENDED.
#
# WHY (forensic 2026-07-01): under heavy concurrency (observed: dozens of sessions on one repo), EVERY /v
# session's merge-back hits FND-3 and DEFERS — main carries sibling uncommitted WIP, so it writes a
# merge-deferred marker + leaves the worktree unmerged. Nothing ever re-runs merge-back when the siblings
# finish, so fully-gated fixes STRAND on their branches (observed: a P1 fix stayed off main, bug
# still live) and merge-deferred markers pile up (observed: 35, most stale). merge-back is idempotent; the ONLY
# missing piece is a driver that re-drives it for every worktree whose SESSION HAS ENDED, and GCs stale markers.
#
# SAFETY CONTRACT — it must NEVER touch a worktree whose session is still running:
#   • Liveness is decided PER-WORKTREE by the OWNING PROCESS, not a global mtime heuristic. The
#     .claude-session-lock records "SID PID EPOCH"; if that PID is alive (kill -0), the session is running →
#     the worktree is SKIPPED. (v-active-siblings' 240-min mtime cutoff is deliberately NOT used as the gate:
#     it reads an 11-hour-old lock as "dead" even when the session is alive — observed live on one project.)
#   • lock ABSENT ⇒ session ended (it removes its lock on exit) ⇒ drainable. lock with a DEAD pid ⇒ drainable.
#     lock with NO numeric pid ⇒ fall back to mtime: only drainable once older than V_DRAIN_DEAD_AGE_MIN
#     (default 360 = 6 h, well beyond any real session) — otherwise SKIP. Every ambiguous case fails toward SKIP.
#   • Each merge still goes through v-merge-back.sh UNCHANGED: its own lock/ownership guard applies, it is
#     idempotent (already-merged → just cleans up), and it re-DEFERS (exit 3) if MAIN still carries a live
#     sibling's WIP — so per-worktree draining can never tangle a concurrent merge. This driver adds NO merge logic.
#   • C-1 VERDICT GATE (round-3, 2026-07-01): SESSION-ENDED ≠ GAUNTLET-COMPLETE. A dead owner proves the
#     session ENDED — not that its work was GATED (observed: auto-landed a session's un-reviewed deletion
#     scope-creep with an INVALID log; nearly landed a QA-FAILED branch after its fail evidence was erased).
#     Before LANDING (already-merged cleanup is exempt — that's not a landing, and merge-back's M2 dirty-guard
#     protects content), the SID must show gauntlet completeness from DURABLE ARTIFACTS: an
#     AGENT_REVIEW_<sid8>* or deliberate GAUNTLET_SKIPPED_<sid8>* artifact, no QA_REPORT verdict:fail, no
#     BLOCKED_<sid8>*, and no operator merge-hold-<sid8>* marker (drop one in .v/artifacts to SME-hold a
#     branch). NEVER keyed on DISPATCH_PROVENANCE rows — rows are absent for legitimate v-dispatch-subagent
#     reviews (observed: zero rows) and forgeable by plain printf (observed: mode=capture rows, empty sha256).
#     Ambiguity fails toward HOLD; a HOLD is loud, tallied, and names the manual path (v-merge-back after review).
#   • Dry run (V_DRAIN_DRY_RUN=1) previews and changes nothing. Exit is ALWAYS 0 — a drain driver must not
#     become a new failure surface. Prints a one-line tally.
set -uo pipefail

_SD="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
MERGEBACK="${V_DRAIN_MERGEBACK:-$_SD/v-merge-back.sh}"   # overridable seam (bite injects a stub)
DRY="${V_DRAIN_DRY_RUN:-0}"
DEAD_AGE_MIN="${V_DRAIN_DEAD_AGE_MIN:-360}"

# Shared lock-format parser (2026-07-02 fix): a lock may be positional 3-field "SID PID EPOCH",
# positional 2-field "SID EPOCH" (no pid), or key=value "sid=... pid=... started=...". Both this
# script and v-active-siblings.sh source the SAME parser so a format fix lands once, not twice.
_LOCK_LIB="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
# shellcheck disable=SC1090
[ -f "$_LOCK_LIB" ] && . "$_LOCK_LIB" || true

command -v git >/dev/null 2>&1 || { echo "v-drain: git unavailable — nothing to do"; exit 0; }
git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "v-drain: $REPO_ROOT is not a git repo — nothing to do"; exit 0; }
# Resolve the MAIN worktree root (markers/merges belong to the shared repo, not a worktree cwd).
_gcd="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
case "$_gcd" in /*) ;; ?*) _gcd="$REPO_ROOT/$_gcd" ;; *) _gcd="" ;; esac
[ -n "$_gcd" ] && MAIN_ROOT="$(cd "$(dirname "$_gcd")" 2>/dev/null && pwd)" || MAIN_ROOT="$REPO_ROOT"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$REPO_ROOT"
_now="$(date +%s 2>/dev/null || echo 0)"

# ── PER-WORKTREE liveness: is a live process still working in this worktree? (0 = ALIVE ⇒ do NOT drain) ──────
# Delegates to the shared session-lock-parse.sh lib (all 3 observed lock formats); if the lib failed to
# load, fail SAFE (treat as alive — never touch a worktree we can't positively prove is dead).
_session_alive(){
  local wt="$1" lock="$1/.claude-session-lock"
  [ -f "$lock" ] || return 1                          # no lock ⇒ session ended (removes its lock on exit)
  if command -v lock_alive >/dev/null 2>&1; then
    lock_alive "$lock" "$DEAD_AGE_MIN"
    return $?
  fi
  return 0   # lib unavailable — fail-safe: assume alive
}

# ── CONSENT-DRAIN (forensic 2026-07-04, Jul-4 fleet standoff): a session that has WRITTEN a
# merge-deferred marker has FINISHED its gauntlet, run merge-back itself, and requested landing —
# draining that branch needs no owner-death. Requiring death starved the drain all day: 7 sessions
# sat "alive" in idle-open terminal tabs (transcript-mtime refreshed forever) with all 7 branches
# deferred, and NOTHING landed. Consent + quiescence beats liveness:
#   • merge-deferred-<sid>.md exists (durable .v/artifacts or .v/tmp) — the owner's own consent;
#   • the worktree is CLEAN (no staged/unstaged content beyond the git-excluded session lock); and
#   • the branch tip PREDATES the marker (owner did not resume and commit after deferring); and
#   • the marker is ≥10 min old (never race the owner's own in-flight merge-back retry).
# Any miss → the ALIVE skip stands (owner may be mid-work). merge-back's own guards + the C-1
# verdict gate still apply downstream — this only lifts the liveness veto, never the safety gates.
# Bite: v-drain-consent-test.sh (red vs .pre-consent0704-bak).
_deferred_consent(){
  local wt="$1" sid="$2" mk="" d mmt tipct dirty
  [ -n "$sid" ] || return 1
  for d in "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp"; do
    [ -f "$d/merge-deferred-${sid}.md" ] && { mk="$d/merge-deferred-${sid}.md"; break; }
  done
  [ -n "$mk" ] || return 1
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | grep -v '\.claude-session-lock$' || true)"
  [ -z "$dirty" ] || return 1
  mmt="$(stat -c %Y "$mk" 2>/dev/null || stat -f %m "$mk" 2>/dev/null || echo 0)"
  tipct="$(git -C "$wt" log -1 --format=%ct 2>/dev/null || echo 0)"
  [ "${mmt:-0}" -gt 0 ] && [ "${tipct:-0}" -gt 0 ] || return 1
  [ "$tipct" -le "$mmt" ] || return 1
  [ $(( _now - mmt )) -ge "${V_DRAIN_CONSENT_MIN_AGE_SEC:-600}" ] || return 1
  return 0
}

# ── GC stale merge-deferred markers (safe regardless of any session state — only removes a spent signal file) ─
gc_markers(){
  local gc=0 mk sid br wtp wdirty
  while IFS= read -r mk; do
    [ -f "$mk" ] || continue
    sid="$(sed -n 's/^deferred_sid:[[:space:]]*//p;s/^sid:[[:space:]]*//p' "$mk" 2>/dev/null | head -1)"
    [ -n "$sid" ] || sid="$(printf '%s' "$mk" | sed -E 's/.*merge-deferred-([0-9a-f-]{8,})\.md$/\1/')"
    br="$(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${sid%%-*}([-_/]|\$)" | head -1)"
    if [ -z "$br" ] || git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null; then
      # FALSE-LANDED-BY-RESET guard (forensic 2026-07-04): is-ancestor is FORGEABLE — a branch reset
      # onto a main ancestor reads ahead=0/"landed" while the feature exists only as STAGED bytes in
      # the worktree (observed ×4 on feature branches).
      # If a worktree for this branch still holds uncommitted content, the work has NOT landed —
      # KEEP the marker (it is the only durable record that landing is still owed).
      wtp="$(sed -n 's/^worktree_path:[[:space:]]*//p' "$mk" 2>/dev/null | head -1)"
      if [ -z "$wtp" ] && [ -n "$br" ]; then
        wtp="$(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$br" '/^worktree /{w=substr($0,10)} $0=="branch "b{print w; exit}')"
      fi
      if [ -n "$wtp" ] && [ -d "$wtp" ]; then
        wdirty="$(git -C "$wtp" status --porcelain 2>/dev/null | grep -v '\.claude-session-lock$' || true)"
        if [ -n "$wdirty" ]; then
          echo "  ⏸ KEEP marker $(basename "$mk") — branch reads landed but its worktree still holds UNCOMMITTED content (false-landed-by-reset guard)"
          continue
        fi
      fi
      [ "$DRY" = 1 ] && echo "  [dry-run] would GC stale marker: $(basename "$mk")" || rm -f "$mk" 2>/dev/null
      gc=$((gc+1))
    fi
  done < <(find "$MAIN_ROOT/.v" -maxdepth 2 -name 'merge-deferred-*.md' 2>/dev/null)
  echo "$gc"
}

# ── GC locks whose owning PID is PROVABLY dead (2026-07-02: hygiene — lock_alive() already correctly
# classifies these as dead via kill -0, so this never creates a false-alive risk; it just stops a spent
# lock file from sitting around and confusing a human/future reader). Never touches a lock with no
# resolvable pid (can't prove dead) or a live pid.
gc_dead_locks(){
  local gc=0 wt lock pid
  while IFS= read -r wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    lock="$wt/.claude-session-lock"
    [ -f "$lock" ] || continue
    command -v _lock_pid >/dev/null 2>&1 || continue
    pid="$(_lock_pid "$lock" 2>/dev/null)"
    [ -n "$pid" ] || continue                       # no resolvable pid ⇒ cannot prove dead ⇒ leave it
    kill -0 "$pid" 2>/dev/null && continue           # alive ⇒ never touch
    if [ "$DRY" = 1 ]; then
      echo "  [dry-run] would GC dead-pid lock: $lock (pid=$pid)"
    else
      rm -f "$lock" 2>/dev/null
    fi
    gc=$((gc+1))
  done < <(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)
  echo "$gc"
}

# ── C-5 (round-3, 2026-07-01): GC SPENT session-writes ledgers. <git-common-dir>/claude-session-writes-<sid>.txt
# files were never reaped (observed: 1,282 on one project) and the P12 absorption gate greps ALL of them — two
# long-merged historical sessions' rows false-blocked a live session's own commit (a strand). A ledger
# is SPENT only when ALL hold: older than V_LEDGER_KEEP_DAYS (default 7 — forensics window), its SID owns no
# registered worktree lock with a live PID, and no unmerged SID-matching branch still carries its work.
# Every ambiguous case (non-numeric lock pid, unmerged branch, young file) KEEPS the ledger — this GC must
# never weaken P12's evidence for plausibly-active work; it only removes provably-historical files.
gc_session_ledgers(){
  local gc=0 lf sid sid8 br live wt lsid lpid mt gdir keep_days="${V_LEDGER_KEEP_DAYS:-7}"
  # F3 (adversarial review 2026-07-01, PoC'd data loss): lock parsing MUST go through the shared
  # session-lock-parse.sh lib — a raw `awk '{print $1/$2}'` parse misses the key=value lock format
  # ("sid=… pid=…"), so a LIVE session's ledger was GC'd in the same run where _session_alive correctly
  # read that very lock as ALIVE. If the lib didn't load, we cannot prove ANY session dead ⇒ GC nothing.
  command -v _lock_sid >/dev/null 2>&1 && command -v _lock_pid >/dev/null 2>&1 || { echo 0; return; }
  gdir="$(git -C "$MAIN_ROOT" rev-parse --git-common-dir 2>/dev/null)"
  case "$gdir" in /*) ;; ?*) gdir="$MAIN_ROOT/$gdir" ;; *) gdir="" ;; esac
  [ -n "$gdir" ] && [ -d "$gdir" ] || { echo 0; return; }
  for lf in "$gdir"/claude-session-writes-*.txt; do
    [ -f "$lf" ] || continue
    sid="$(basename "$lf" | sed -E 's/^claude-session-writes-(.*)\.txt$/\1/')"; sid8="${sid%%-*}"
    # W5G-14 (forensic 2026-07-10 #2): an OPEN STOP_REARM_ESCAPE marker for this SID means the
    # escape is unadjudicated — the ledger is the primary evidence for judging what the escaped
    # session actually owned (an earlier escape cluster could not be attributed
    # because no ledger survived). KEEP the ledger, regardless of age, until the escape marker
    # is archived/cleared by an operator or forensics pass.
    if [ -f "$MAIN_ROOT/.v/artifacts/STOP_REARM_ESCAPE_${sid}.md" ]; then
      continue
    fi
    mt="$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo "$_now")"
    [ $(( (_now - ${mt:-_now}) / 86400 )) -ge "$keep_days" ] || continue        # young ⇒ KEEP
    live=0
    while IFS= read -r wt; do
      [ -n "$wt" ] && [ -f "$wt/.claude-session-lock" ] || continue
      lsid="$(_lock_sid "$wt/.claude-session-lock" 2>/dev/null)"; [ "$lsid" = "$sid" ] || continue
      lpid="$(_lock_pid "$wt/.claude-session-lock" 2>/dev/null)"
      case "$lpid" in ''|*[!0-9]*) live=1 ;; *) kill -0 "$lpid" 2>/dev/null && live=1 ;; esac
      # FALSE-LANDED-BY-RESET guard (forensic 2026-07-04): the SID's worktree still holds
      # uncommitted content ⇒ its work has NOT landed regardless of what the branch ancestry says
      # ⇒ the ledger is live attribution evidence — KEEP it.
      if [ "$live" = 0 ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | grep -v '\.claude-session-lock$' | head -1 || true)" ]; then
        live=1
      fi
    done < <(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    [ "$live" = 1 ] && continue                                                  # live session ⇒ KEEP
    br="$(git -C "$MAIN_ROOT" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | grep -E "(^|[-_/])${sid8}([-_/]|$)" | head -1)"
    if [ -n "$br" ] && ! git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null; then
      continue                                                                    # unmerged work ⇒ KEEP
    fi
    [ "$DRY" = 1 ] && echo "  [dry-run] would GC spent session-writes ledger: $(basename "$lf")" || rm -f "$lf" 2>/dev/null
    gc=$((gc+1))
  done
  echo "$gc"
}

# ── Full-SID expansion (P0-2, 2026-07-02): v-merge-back.sh HARD-requires a full UUID (its _UUID_RE)
# and _die's with exit 2 on anything else — passing a short-8 branch-suffix SID was a DETERMINISTIC,
# PERMANENT rc=2 loop (every future drain pass fails identically on that branch). Expand via any
# SID-bearing proof-artifact filename already on disk before ever invoking merge-back.
_expand_sid(){
  local short="$1" wt="$2" d g full
  case "$short" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) printf '%s' "$short"; return 0 ;;
  esac
  for d in "$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" "$wt"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    for g in "$d"/merge-deferred-"${short}"*.md "$d"/HANDOFF_"${short}"*.md "$d"/WORKTREE_HANDOFF_"${short}"*.md \
             "$d"/VERIFY_DONE_REPORT_"${short}"*.md "$d"/PRE_FLIGHT_REPORT_"${short}"*.md \
             "$d"/AGENT_REVIEW_"${short}"*.md "$d"/DISPATCH_PROVENANCE_"${short}"*.log; do
      [ -f "$g" ] || continue
      full="$(basename "$g" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
      [ -n "$full" ] && { printf '%s' "$full"; return 0; }
    done
  done
  printf '%s' "$short"
  return 1
}

# ── FND-3 LIVENESS RE-DRIVER (forensic 2026-07-04 residual #1): a gauntleted-but-unmerged branch
# whose WORKTREE IS GONE is invisible to the walk below — re-attach it first (v-strand-redrive.sh
# materializes a plain worktree for dead-owner strands with durable gauntlet evidence; it adds no
# merge logic — the C-1 gate + merge-back below still decide every landing). Kill switch:
# V_DRAIN_REDRIVE=off. Bite: v-strand-redrive-test.sh (red vs .pre-redrive0704-bak).
REDRIVE="${V_DRAIN_REDRIVE:-$_SD/v-strand-redrive.sh}"
if [ "$REDRIVE" != "off" ] && [ -f "$REDRIVE" ]; then
  V_REDRIVE_DRY_RUN="$DRY" bash "$REDRIVE" "$MAIN_ROOT" 2>&1 | sed 's/^/  /' || true
fi

# ── DUPLICATE-DISPATCH lane detection (batch-3, 2026-07-05): report-first census of same-slug
# duplicate lanes (superseded / zero-divergence twins / divergent) so a duplicate can never read as
# "unmerged work owed". Detection only here — pruning stays operator-opt-in (V_DUP_PRUNE=1 on the
# detector directly). Kill switch: V_DRAIN_DUPDETECT=off. Bite: v-dup-lane-detect-test.sh.
DUPDETECT="${V_DRAIN_DUPDETECT:-$_SD/v-dup-lane-detect.sh}"
if [ "$DUPDETECT" != "off" ] && [ -f "$DUPDETECT" ]; then
  # CODEX-004: V_DUP_PRUNE is FORCED to 0 on this automated path — an operator's ambient
  # `export V_DUP_PRUNE=1` from a manual terminal must never leak branch deletion into an
  # autonomous drain. Pruning requires a deliberate, direct detector invocation.
  V_DUP_DRY_RUN="$DRY" V_DUP_PRUNE=0 bash "$DUPDETECT" "$MAIN_ROOT" 2>&1 | sed 's/^/  /' || true
fi

drained=0; failed=0; deferred=0; already=0; skipped_live=0; skipped_proof=0; held_ungated=0; considered=0
while IFS= read -r wt; do
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  # NB: no path-shape filter here. /v worktrees live under TWO conventions — the in-repo <repo>/.worktrees/…
  # AND the harness-managed ~/.claude/worktrees/<repo>/… (segment '/worktrees/', no leading dot). A
  # '*"/.worktrees/"*' filter silently skipped the latter (observed: 3 of 4 fleet worktrees stranded). Safety
  # does NOT rely on the path shape — every worktree still passes the branch!=main check, the PID-liveness gate,
  # and the mid-setup stranding-proof requirement below; a non-feature or non-/v worktree is skipped by those.
  br="$(git -C "$wt" branch --show-current 2>/dev/null || true)"; [ -n "$br" ] || continue
  # A worktree parked on the MAIN branch (observed on one project: a maintenance session left one on `main`) is NOT a
  # stranded feature branch — never feed it to merge-back, which would try to merge main into itself. Skip silently.
  [ "$br" = "$MAIN_BRANCH" ] && continue
  considered=$((considered+1))
  # SID is resolved BEFORE the liveness skip (2026-07-04): the consent-drain check below needs it.
  if command -v _lock_sid >/dev/null 2>&1; then
    sid="$(_lock_sid "$wt/.claude-session-lock" 2>/dev/null || true)"
  else
    sid="$(awk 'NR==1{print $1}' "$wt/.claude-session-lock" 2>/dev/null || true)"
  fi
  [ -n "$sid" ] || sid="$(printf '%s' "$br" | sed -E 's/.*[-_/]([0-9a-f]{8}(-[0-9a-f]{4}){0,3}(-[0-9a-f]{12})?)$/\1/')"
  # MED-1 (forensic 2026-07-07): `sed` returns its INPUT UNCHANGED when the branch has no
  # UUID suffix, so a SID-less branch (e.g. 'fix/example-bounds-check') leaves the raw branch —
  # WITH its '/' — in $sid. That '/' then builds an invalid marker path
  # '.v/artifacts/merge-deferred-fix/example-bounds-check.md' → "No such file or directory", and
  # `${sid%%-*}` yields 'fix/example' which can never match any real artifact. If no UUID was extracted
  # (sid still holds non-hex chars or a slash), fall back to a filesystem-safe slug of the branch.
  case "$sid" in
    ''|*[!0-9a-f-]*|*/*) sid="$(printf '%s' "$br" | tr '/ ' '--' | tr -cd 'A-Za-z0-9._-')" ;;
  esac
  # A2a (forensic 2026-07-07): a SID-less branch (e.g. 'fix/example-bounds-check') with NO lock
  # leaves $sid as a branch SLUG that matches no SID-keyed artifact — so the C-1 gauntlet-artifact lookup below
  # false-reports "gauntlet incomplete (no AGENT_REVIEW)" even when PRE_FLIGHT_<realsid>/AGENT_REVIEW_<realsid>
  # DO exist (the observed false-HOLD). Recover the REAL session SID from the HMAC-provenanced commit-witness
  # record: exactly one commits-<realsid>.txt lists this branch's tip sha. Only fires when $sid is NOT already a
  # real UUID (never overrides a lock/suffix-resolved SID) and only on an exact tip-sha match — so it cannot
  # mis-attribute. Read-only. Makes the drain report the ACCURATE gate state and lets a genuinely-gauntleted
  # SID-less branch land instead of parking forever on a wrong reason.
  # A2a-EXT (2026-07-07 adoption, forensic): the original A2a recovered the real SID ONLY
  # when $sid was NOT a UUID (a SID-less branch slug). But an OUT-OF-BAND ADOPTED worktree resolves $sid to
  # the branch-suffix UUID of the MINTER — which committed NOTHING (empty commit-witness, no-isolation
  # verify-done) — while an adopter session did the real work and filed its gauntlet + commits under ITS sid.
  # Trusting the suffix UUID then false-blocks landable, fully-gauntleted work at the merge-back W-GATE.
  # Recover the witness owner in BOTH shapes: the SID whose HMAC-provenanced commit-witness lists this
  # branch's EXACT tip sha is the true owner. Require EXACTLY ONE owning witness (fail-closed on 0/ambiguous
  # — a foreign branch's tip never appears in an unrelated witness, and a >1 match is never blindly picked),
  # and only override when the recovered UUID DIFFERS from $sid (a correctly-attributed branch is untouched).
  # Read-only: the recovered sid's gauntlet is STILL fully gated by C-1 below + merge-back's W-GATE — this
  # only points those gates at the RIGHT session's artifacts, it never bypasses them. merge-back ownership
  # proof (3)/A2b accepts the SAME commit-witness, so the reassigned sid lands the LOCKED merge.
  _a2_tip="$(git -C "$MAIN_ROOT" rev-parse "$br" 2>/dev/null || true)"
  if [ -n "$_a2_tip" ] && [ -d "$MAIN_ROOT/.v/artifacts" ]; then
    _a2_matches="$(grep -lF "$_a2_tip" "$MAIN_ROOT/.v/artifacts/"commits-*.txt 2>/dev/null \
                   | sed -E 's#.*/commits-([0-9a-f-]{8,})\.txt$#\1#')"
    if [ "$(printf '%s\n' "$_a2_matches" | grep -c . 2>/dev/null || echo 0)" = 1 ]; then
      case "$_a2_matches" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*)
          if [ "$_a2_matches" != "$sid" ]; then
            echo "  ℹ re-attributed $br → commit-witness owner $_a2_matches (provenance names tip ${_a2_tip%${_a2_tip#????????????}}; dir/suffix SID '$sid' committed nothing — SID-less or out-of-band adoption)"
            sid="$_a2_matches"
          fi ;;
      esac
    fi
  fi
  # A2a-PID (forensic 2026-07-10, a production repo / phantom SID): a REBASE performed on a
  # stranded branch (v-merge-all rebased pack-06 onto fresh main) moves the tip, so the
  # HMAC-provenanced commit-witness still names the PRE-rebase sha — the exact-tip match above
  # then finds nothing, re-attribution silently stops firing, and the drain REGRESSES from a
  # correct HOLD-on-BLOCKED (observed in two runs) to a phantom-SID "gauntlet incomplete"
  # with a dead-end remediation command (two later runs). Fallback: match by PATCH-ID — a
  # rebase preserves patch content, and the pre-rebase commits survive as dangling objects.
  # Bounded (≤50 branch commits; ≤8 shas per witness, each cheap-rejected via cat-file before any
  # patch-id work) and fail-closed identically to A2a: exactly ONE owning witness file, full-UUID
  # shape, only overrides when it differs from $sid. Runs ONLY when the exact-tip match was empty.
  if [ -z "${_a2_matches:-}" ] && [ -n "$_a2_tip" ] && [ -d "$MAIN_ROOT/.v/artifacts" ]; then
    _a2p_shas="$(git -C "$MAIN_ROOT" rev-list --max-count=51 "${MAIN_BRANCH}..${br}" 2>/dev/null || true)"
    _a2p_n="$(printf '%s\n' "$_a2p_shas" | grep -c . 2>/dev/null || echo 0)"
    if [ "${_a2p_n:-0}" -ge 1 ] 2>/dev/null && [ "${_a2p_n:-0}" -le 50 ] 2>/dev/null; then
      _a2p_set=""
      while IFS= read -r _a2p_c; do
        [ -n "$_a2p_c" ] || continue
        _a2p_id="$(git -C "$MAIN_ROOT" diff-tree -p "$_a2p_c" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
        [ -n "$_a2p_id" ] && _a2p_set="${_a2p_set}${_a2p_id}
"
      done <<A2PID_EOF
$_a2p_shas
A2PID_EOF
      _a2p_owner=""; _a2p_multi=0
      for _a2p_w in "$MAIN_ROOT/.v/artifacts/"commits-*.txt; do
        [ -f "$_a2p_w" ] || continue
        while IFS= read -r _a2p_ws; do
          [ -n "$_a2p_ws" ] || continue
          git -C "$MAIN_ROOT" cat-file -e "${_a2p_ws}^{commit}" 2>/dev/null || continue
          _a2p_wid="$(git -C "$MAIN_ROOT" diff-tree -p "$_a2p_ws" 2>/dev/null | git patch-id --stable 2>/dev/null | cut -d' ' -f1)"
          [ -n "$_a2p_wid" ] || continue
          if printf '%s' "$_a2p_set" | grep -qxF "$_a2p_wid"; then
            _a2p_this="$(printf '%s' "$_a2p_w" | sed -E 's#.*/commits-([0-9a-f-]{8,})\.txt$#\1#')"
            if [ -z "$_a2p_owner" ]; then _a2p_owner="$_a2p_this"
            elif [ "$_a2p_owner" != "$_a2p_this" ]; then _a2p_multi=1; fi
            break
          fi
        done < <(grep -oE '[0-9a-f]{40}' "$_a2p_w" 2>/dev/null | head -8)
      done
      if [ "$_a2p_multi" -eq 0 ] && [ -n "$_a2p_owner" ]; then
        case "$_a2p_owner" in
          [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*)
            if [ "$_a2p_owner" != "$sid" ]; then
              echo "  ℹ re-attributed $br → commit-witness owner $_a2p_owner via PATCH-ID (witness tip predates a rebase of this branch; exact-tip match found nothing — A2a-PID)"
              sid="$_a2p_owner"
            fi ;;
        esac
      fi
    fi
  fi
  if _session_alive "$wt"; then
    if [ -n "$sid" ] && _deferred_consent "$wt" "$sid"; then
      echo "  ▶ $br — owner is ALIVE but already DEFERRED its merge and the worktree is quiescent; landing by consent (2026-07-04 idle-tab standoff fix)"
    else
      skipped_live=$((skipped_live+1))
      _dpid="$(command -v _lock_pid >/dev/null 2>&1 && _lock_pid "$wt/.claude-session-lock" 2>/dev/null)"
      echo "  ⏭ skip $br — owning session is ALIVE (pid ${_dpid:-unknown}) with no quiescent deferral consent; not touching a live worktree"
      continue
    fi
  fi
  [ -n "$sid" ] || { echo "  skip $br — cannot resolve a SID (no lock, no sid suffix)"; continue; }
  # P0-2: expand a short-8 branch-suffix SID to the full UUID BEFORE ever calling merge-back — it
  # hard-refuses (exit 2) on anything that isn't a full UUID, so passing a short SID is a deterministic,
  # permanent failure loop. Expand via any SID-bearing proof-artifact filename already on disk.
  case "$sid" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) : ;;   # already full UUID
    *)
      _full="$(_expand_sid "$sid" "$wt")"
      if [ "$_full" != "$sid" ]; then
        echo "  ℹ expanded short SID '$sid' → full '$_full' via proof artifact"
        sid="$_full"
      fi
      ;;
  esac
  # MID-SETUP RACE GUARD: a worktree with NO lock is ambiguous — an ENDED stranded session (removed its lock)
  # OR a sibling still SETTING UP (worktree created, lock not yet written). A dead-PID lock already PROVES the
  # session ended, so it needs no further proof; but a lockless worktree is drained ONLY with a positive
  # stranding artifact (HANDOFF / merge-deferred / VERIFY_DONE / PRE_FLIGHT / DISPATCH_PROVENANCE for this SID,
  # searched in MAIN_ROOT + its .v subdirs + the WORKTREE ROOT ITSELF), OR — H-4 (2026-07-02): a
  # SIGKILLed/timeout-killed session never gets to write ANY named artifact but DID commit real work, and a
  # true mid-setup worktree by construction has ZERO commits (nothing is committed before the gauntlet
  # starts) — so commits-ahead-of-main > 0 with no lock is unambiguous stranding proof too.
  if [ ! -f "$wt/.claude-session-lock" ]; then
    _sid8="${sid%%-*}"; _proof=""
    for _d in "$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" "$wt"; do
      [ -n "$_d" ] && [ -d "$_d" ] || continue
      _proof="$(find "$_d" -maxdepth 1 \( -name "HANDOFF_${_sid8}*" -o -name "WORKTREE_HANDOFF_${_sid8}*" -o -name "merge-deferred-${_sid8}*" -o -name "VERIFY_DONE_REPORT_${_sid8}*" -o -name "PRE_FLIGHT_REPORT_${_sid8}*" -o -name "DISPATCH_PROVENANCE_${_sid8}*" \) 2>/dev/null | head -1)"
      [ -n "$_proof" ] && break
    done
    _ahead=0
    [ -n "$_proof" ] || _ahead="$(git -C "$MAIN_ROOT" rev-list --count "${MAIN_BRANCH}..${br}" 2>/dev/null || echo 0)"
    if [ -z "$_proof" ] && { [ -z "${_ahead:-}" ] || [ "${_ahead:-0}" -le 0 ] 2>/dev/null; }; then
      # DIRTY-WORKTREE STRAND (forensic 2026-07-07): "0 commits ahead +
      # no artifact" is NOT proof of mid-setup — a session whose FORK did real work but whose parent closed
      # at 0 turns (or that timed out before committing) leaves its deliverables UNCOMMITTED in the worktree
      # working tree: 326 lines of hardening work, 0 commits ahead, no lock, no marker. A true mid-setup
      # worktree is CLEAN (nothing done yet); a dirty one holds real, un-committed work. The drain cannot
      # LAND uncommitted work (nothing is committed to merge) — but it must not MISLABEL it as "likely a
      # sibling mid-setup", which reads as "nothing here, safe to prune" and invites the operator to destroy
      # it. Report it accurately and point at the resume path. Same porcelain idiom as the false-landed-by-
      # reset guard above (excludes the lock line). Bite: v-drain-dirty-midsetup-test.sh.
      _wdirty="$(git -C "$wt" status --porcelain 2>/dev/null | grep -v '\.claude-session-lock$' | grep -c . || echo 0)"
      if [ "${_wdirty:-0}" -gt 0 ] 2>/dev/null; then
        echo "  ⚠ HOLD $br — lockless worktree holds ${_wdirty} file(s) of UNCOMMITTED work, 0 commits ahead of $MAIN_BRANCH: an ENDED session's un-committed deliverables (NOT a sibling mid-setup). Cannot auto-land — nothing is committed to merge. RESUME it: run-v-packs --resume <pack-dir> (adopts this worktree), or finish it interactively. Do NOT prune $wt"
        skipped_proof=$((skipped_proof+1)); continue
      fi
      echo "  ⏭ skip $br — no lock AND no stranding proof (no artifact, 0 commits ahead of $MAIN_BRANCH, clean worktree; likely a sibling mid-setup)"; skipped_proof=$((skipped_proof+1)); continue
    fi
    [ -n "$_proof" ] || echo "  ℹ no proof artifact for $br, but ${_ahead} commit(s) ahead of $MAIN_BRANCH — treating as stranded, not mid-setup (H-4)"
  fi
  # UNDOCUMENTED-STRAND record (forensic 2026-07-04, HIGH-3): a dead session that committed
  # to its build branch but left NO HANDOFF and NO merge-deferred marker is "misreported-by-omission"
  # — the drain finds it (lock-absent/dead ⇒ drainable) but nothing documents that a strand existed or
  # why it was processed. Before the land attempt, if the branch is unmerged with commits ahead and no
  # deferral doc exists for this SID, emit a durable merge-deferred-style record so the strand is
  # visible to the integrity sweep's merge-deferred loop, to forensics, and to the operator regardless
  # of the land/HOLD/defer outcome below. Idempotent (only writes when absent); read-only w.r.t. the
  # branch. Bite: v-drain-undocumented-strand-test.sh.
  if [ "$DRY" != 1 ] && ! git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null; then
    _us_ahead="$(git -C "$MAIN_ROOT" rev-list --count "${MAIN_BRANCH}..${br}" 2>/dev/null || echo 0)"
    if [ "${_us_ahead:-0}" -gt 0 ] 2>/dev/null; then
      _us_doc=""
      for _ud in "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" "$MAIN_ROOT" "$wt"; do
        [ -d "$_ud" ] || continue
        for _uf in "$_ud/merge-deferred-${sid}.md" "$_ud/HANDOFF_${sid}.md" "$_ud/WORKTREE_HANDOFF_${sid}.md"; do
          [ -f "$_uf" ] && { _us_doc="$_uf"; break 2; }
        done
      done
      if [ -z "$_us_doc" ]; then
        _us_mk="$MAIN_ROOT/.v/artifacts/merge-deferred-${sid}.md"
        if mkdir -p "$MAIN_ROOT/.v/artifacts" 2>/dev/null; then
          {
            echo "# UNDOCUMENTED STRAND discovered by v-drain — ${sid}"
            echo
            echo "deferred_sid:    ${sid}"
            echo "worktree_path:   ${wt}"
            echo "worktree_branch: ${br}"
            echo "merge_target:    ${MAIN_BRANCH}"
            echo "commits_ahead:   ${_us_ahead}"
            echo "discovered_at:   $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
            echo
            echo "This session committed ${_us_ahead} commit(s) to an UNMERGED build branch but left NO"
            echo "HANDOFF and NO merge-deferred marker — it was misreported-by-omission until the drain"
            echo "discovered it. The drain will attempt to land it (subject to the C-1 verdict gate below)."
            echo "This record makes the strand visible to the integrity sweep + forensics; it auto-clears"
            echo "once the branch lands (gc_markers) or any telemetry exists for the session."
          } > "$_us_mk" 2>/dev/null \
            && echo "  ✎ recorded undocumented strand for $br (${_us_ahead} commit(s) ahead, no HANDOFF/marker) → $(basename "$_us_mk")"
        fi
      fi
    fi
  fi
  # C-1 VERDICT GATE (see SAFETY CONTRACT above): gate LANDING only — an already-merged branch skips straight
  # to merge-back's idempotent cleanup (its M2 dirty-guard protects any uncommitted content). Evidence is
  # searched across MAIN root, its durable .v dirs, AND the worktree itself (pre-write-time-copy sessions'
  # artifacts are often worktree-only). Provenance rows are deliberately NOT evidence (forgeable, incomplete).
  if ! git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null; then
    _c1_sid8="${sid%%-*}"; _c1_hold=""; _c1_review=""; _c1_qafail=""; _c1_blocked=""; _c1_q=""; _c1_rcand=""; _c1_v=""
    # F4 (adversarial review, PoC'd): sid8 alone (32 bits) let an UNRELATED session's review artifact
    # sharing the prefix satisfy the gate. LAND-enabling evidence matches the FULL SID when we have it;
    # only a short-8 fallback (no lock, short branch suffix) accepts a UUID-shaped remainder. HOLD-side
    # evidence (merge-hold/BLOCKED) stays sid8 — a collision there only over-holds (safe + operator-friendly).
    case "$sid" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-*) _c1_pat="$sid" ;;
      *) _c1_pat="${_c1_sid8}-*-*-*-*" ;;
    esac
    for _d in "$MAIN_ROOT" "$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT/.v/tmp" "$wt"; do
      [ -n "$_d" ] && [ -d "$_d" ] || continue
      [ -n "$_c1_hold" ]    || _c1_hold="$(find "$_d" -maxdepth 1 -name "merge-hold-${_c1_sid8}*" 2>/dev/null | head -1)"
      if [ -z "$_c1_review" ]; then
        _c1_rcand="$(find "$_d" -maxdepth 1 \( -name "AGENT_REVIEW_${_c1_pat}*" -o -name "GAUNTLET_SKIPPED_${_c1_pat}*" \) 2>/dev/null | head -1)"
        # F1 (adversarial review, PoC'd): evidence found in the WORKTREE ROOT counts only if UNTRACKED —
        # a "review artifact" committed inside the very branch being gated is self-attestation (a branch
        # shipped a forged AGENT_REVIEW in its own diff and landed). Untracked files are out-of-band
        # writes by the gauntlet machinery; tracked ones are part of the diff under judgment.
        if [ -n "$_c1_rcand" ] && [ "$_d" = "$wt" ] && git -C "$wt" ls-files --error-unmatch "$(basename "$_c1_rcand")" >/dev/null 2>&1; then
          _c1_rcand=""
        fi
        _c1_review="$_c1_rcand"
      fi
      [ -n "$_c1_blocked" ] || _c1_blocked="$(find "$_d" -maxdepth 1 -name "BLOCKED_${_c1_sid8}*" 2>/dev/null | head -1)"
      if [ -z "$_c1_qafail" ]; then
        for _c1_q in "$_d"/QA_REPORT_${_c1_pat}*; do
          [ -f "$_c1_q" ] || continue
          # C1-SIDECAR (2026-07-12 forensic, operator-approved remediation): the glob also sweeps
          # in v-dispatch-subagent's *.dispatch-runlog / *.dispatch-status SIDECARS, whose free text echoes
          # the verdict line of whatever iteration they dispatched ("**Verdict: fail**"). A later official
          # QA refresh rewrites the REPORT (.md) but not a dead prior dispatch's runlog — a stale iteration-1
          # fail echo held a branch whose current authoritative QA_REPORT.md said pass (landed only after the
          # operator archived the sidecars by hand). Sidecars are dispatch LOGS, not verdict artifacts —
          # merge-back's own _qa_report_fail (the real W-GATE) already scopes to *.md; mirror that here so the
          # pre-gate and the gate can never disagree. Same class fixed in run-v-packs-lib/30-verdict.sh (QA-2).
          case "$_c1_q" in *.dispatch-runlog|*.dispatch-status|*.stale.*|*.invalid|*.provenance) continue ;; esac
          # F2+F8 (adversarial review, PoC'd): the FIRST `verdict:` line is authoritative (an appendix
          # "verdict: fail" must not override a top-level pass → needless HOLD), and the value may be
          # quote/backtick/bold-wrapped (`verdict: "fail"` evaded the bare-token match and LANDED).
          _c1_v="$(grep -iE '^[[:space:]]*[*_`]*[[:space:]]*verdict[[:space:]]*:' "$_c1_q" 2>/dev/null | head -1 \
                   | sed -E 's/^[^:]*:[[:space:]]*//; s/^["`*_ '"'"']*//; s/["`*_ '"'"']*$//' | tr '[:upper:]' '[:lower:]')"
          case "$_c1_v" in fail*) _c1_qafail="$_c1_q"; break ;; esac
        done
      fi
    done
    _c1_why=""
    [ -n "$_c1_hold" ] && _c1_why="operator merge-hold marker ($(basename "$_c1_hold"))"
    if [ -z "$_c1_why" ] && [ -n "$_c1_qafail" ]; then
      _c1_why="QA verdict FAIL ($(basename "$_c1_qafail"))"
      # F-QS (2026-07-01 forensic): a QA-FAIL verdict can be STALE — the session fixed the
      # finding in a later commit and re-ran gates green, but was killed before QA iteration 2 could
      # rewrite the verdict. The HOLD is still correct (fail-toward-HOLD; never auto-land on this
      # inference), but say so — the operator's manual step is then "re-run v-qa-reviewer", not archaeology.
      # AR-6 (adversarial review): if either timestamp can't be resolved, say NOTHING — a failed stat
      # defaulting to 0 made "tip > qa" trivially true, false-flagging fresh verdicts as stale.
      _c1_qamt="$(stat -c %Y "$_c1_qafail" 2>/dev/null || stat -f %m "$_c1_qafail" 2>/dev/null || echo 0)"
      _c1_tipct="$(git -C "$MAIN_ROOT" log -1 --format=%ct "$br" 2>/dev/null || echo 0)"
      if [ "${_c1_qamt:-0}" -gt 0 ] && [ "${_c1_tipct:-0}" -gt "${_c1_qamt:-0}" ] 2>/dev/null; then
        _c1_why="$_c1_why — NOTE: the branch tip POST-DATES this QA verdict (a remediation commit may have addressed it); the verdict may be STALE — re-run v-qa-reviewer against the worktree to refresh it, then re-drain"
      fi
    fi
    [ -z "$_c1_why" ] && [ -n "$_c1_blocked" ] && _c1_why="BLOCKED artifact ($(basename "$_c1_blocked"))"
    [ -z "$_c1_why" ] && [ -z "$_c1_review" ] && _c1_why="gauntlet incomplete (no AGENT_REVIEW_${_c1_sid8}*/GAUNTLET_SKIPPED_${_c1_sid8}* artifact on disk)"
    if [ -n "$_c1_why" ]; then
      held_ungated=$((held_ungated+1))
      echo "  ⏸ HOLD $br — $_c1_why. Not landing ungated work (SESSION-ENDED ≠ GAUNTLET-COMPLETE). Review it, then land manually: v-merge-back.sh $sid $wt — or clear the blocker / remove the hold marker and re-drain."
      continue
    fi
  fi
  if [ "$DRY" = 1 ]; then
    if git -C "$MAIN_ROOT" merge-base --is-ancestor "$br" "$MAIN_BRANCH" 2>/dev/null; then
      echo "  [dry-run] $br already merged → would clean up"; already=$((already+1))
    else
      echo "  [dry-run] would drain (session ended): v-merge-back.sh $sid $wt"; drained=$((drained+1))
    fi
    continue
  fi
  _out="$(bash "$MERGEBACK" "$sid" "$wt" 2>&1)"; _rc=$?
  case "$_rc" in
    # F1 (2026-07-02): report the LANDED worktree's own session-id on the success line — this is the
    # SAME pinned --session-id the pack runner (run-v-packs) originally assigned this worktree's
    # session (it's what /v embedded into .claude-session-lock at worktree creation), so a caller can
    # correlate "this drain just landed session X" back to "pack P was launched under session X" and
    # reconcile a still-parked pack folder instead of leaving it silently contradicting main.
    0) drained=$((drained+1));  echo "  ✓ merged+cleaned: $br (sid=$sid)" ;;
    3) deferred=$((deferred+1)); echo "  ⏸ still deferred: $br (main still carries live sibling WIP — left intact, retry later)" ;;
    *)
      failed=$((failed+1))
      # P0-2 bonus fix: v-merge-back.sh prints a "════…" DO-NOT-BYPASS banner as the LAST lines of
      # every error exit — `tail -1` grabbed that decorative border, not the actual reason. Report the
      # last real `ERROR:` line instead; fall back to the last non-banner/non-blank line if none matched.
      # F-WG (2026-07-01 forensic, photo-finish): a W-GATE artifact-presence block is a DISTINCT
      # class from a merge conflict — it writes SESSION_LOG_PENDING (never a WORKTREE_HANDOFF), and when the
      # owning session was timeout-killed mid-gauntlet the "missing" report is often still being flushed by a
      # surviving gate subagent (observed: PRE_FLIGHT_REPORT landed 41s AFTER merge-back declared it missing).
      # Name the class + the actual missing artifact and say re-draining may resolve it — the old blanket
      # "see its WORKTREE_HANDOFF" pointed at a file that does not exist for this class.
      if printf '%s\n' "$_out" | grep -qF 'W-GATE artifact-presence merge precondition FAILED'; then
        _errline="$(printf '%s\n' "$_out" | grep -E '^ERROR:[[:space:]]+required \(code session\):' | head -1 | sed -E 's/^ERROR:[[:space:]]*//')"
        [ -n "$_errline" ] || _errline="$(printf '%s\n' "$_out" | grep -E '^ERROR:' | head -2 | tail -1 | sed -E 's/^ERROR:[[:space:]]*//')"
        echo "  ✗ merge-back rc=$_rc for $br (left intact; W-GATE artifact block — no WORKTREE_HANDOFF exists for this class): ${_errline:-artifact missing}. If this session was killed while its gauntlet subagents were still writing reports, the artifact may already be on disk now — RE-RUN THIS DRAIN before landing manually."
      else
        _errline="$(printf '%s\n' "$_out" | grep -E '^ERROR:' | tail -1)"
        [ -n "$_errline" ] || _errline="$(printf '%s\n' "$_out" | grep -vE '^(═+|⛔|[[:space:]]*)$' | tail -1)"
        echo "  ✗ merge-back rc=$_rc for $br (left intact; see its WORKTREE_HANDOFF): ${_errline:-<no output>}"
      fi
      ;;
  esac
done < <(git -C "$MAIN_ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2)

_gc="$(gc_markers)"
_gcl="$(gc_dead_locks)"
_gcw="$(gc_session_ledgers)"
echo "v-drain: considered=$considered drained=$drained deferred=$deferred failed=$failed already-merged=$already skipped-LIVE=$skipped_live skipped-proof-miss=$skipped_proof held-ungated=$held_ungated; GC'd $_gc stale marker(s), $_gcl dead-pid lock(s), $_gcw spent ledger(s)."
exit 0
