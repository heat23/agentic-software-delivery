#!/usr/bin/env bash
# v-artifact-consolidate.sh — SINGLE SOURCE for consolidating session artifacts into the
# canonical artifact dir (.v/artifacts).
#
# Extracted from v-completion-selfcheck.sh's "Location reconciliation" block (W-perf6) so
# that BOTH the completion self-check AND v-merge-back.sh consolidate with IDENTICAL move
# semantics instead of drifting. Forensic driver (2026-06-04, C-3/A-3): consolidation only
# ran when the self-check ran — sessions that skipped it (H-6, H-7,
# H-10) stranded gate artifacts at the repo root, and H-5 lost its
# artifacts entirely when `git worktree remove` destroyed the only copies. v-merge-back.sh
# now calls this script before removing a worktree (rescue) and after merging (root sweep).
#
# Move semantics (preserved EXACTLY from the self-check block — W-perf6 review CODEX-001/002,
# both data-loss bugs at the mtime boundary):
#   • cp -p PRESERVES the source mtime, so a LATER sweep (e.g. MAIN_ROOT after the worktree)
#     compares real-source-vs-real-source, NOT against a `now()`-restamped dst.
#   • "source wins unless dst is STRICTLY newer" (`! "$_dst" -nt "$_f"`): on EQUAL/same-second
#     mtime the just-written source FIX wins (`-nt` is strict, so a tie would otherwise drop it).
#   • Verified MOVE: copy → confirm dest non-empty → only then remove the source copy.
#     If the copy fails, the source is kept (no data loss).
#   • When dst is STRICTLY newer, the stale source duplicate is dropped.
#
# Usage: v-artifact-consolidate.sh <SID> [extra-source-dir ...]
#   SID              — session id (full UUID, or the unique substring used in artifact names)
#   extra-source-dir — additional dirs to sweep (e.g. a worktree root + its .v/artifacts)
#
# Default sources (same set the self-check swept): REPO_ROOT, REPO_ROOT/.v/artifacts, $PWD,
# MAIN_ROOT — then any extra dirs given as args.
# Destination: $(v-artifact-dir.sh) — the V_ARTIFACT_DIR override is respected (tests).
# Prints "  consolidated <basename> → .v/artifacts" to stderr per moved file.
# Exit: 0 always (best-effort — artifact bookkeeping must never fail a caller's merge or
# self-check); 2 on usage error (no SID).
set -u

# MEDIUM fix (2026-06-09): minimum meaningful artifact size.  A ".v/artifacts" stub that is
# STRICTLY newer but smaller than this threshold is treated as stale/incomplete — the larger
# source wins regardless of mtime.  Rationale: a dst that is both newer AND meaningfully
# larger is the correct winner (it was updated after the source).  A dst that is newer but
# tiny is almost certainly a partial write or a placeholder, and we should NOT discard the
# valid larger source in its favour.
_MIN_MEANINGFUL_BYTES=200

SID="${1:-}"
if [ -z "$SID" ]; then
  echo "usage: v-artifact-consolidate.sh <SID> [extra-source-dir ...]" >&2
  exit 2
fi
shift 2>/dev/null || true

# Resolve roots exactly as the self-check / Stop hook do (first worktree row = main checkout).
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

# LEAK-GUARD (2026-08-03, class sweep): `git rev-parse --show-toplevel || pwd` falls through to bare
# `pwd` when there is no enclosing repo. ~/.claude has none by design, so running from a skill/hook
# SOURCE subdir made this resolve there and nest .v/ inside the source tree (114 stray files over
# 8 weeks). The config dir ITSELF is a legitimate root (live .v/artifacts there), so snap only a
# STRICT DESCENDANT that is not itself a git work tree; real projects are never touched.
_lg_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "${REPO_ROOT:-}" ] && [ -n "$_lg_cfg" ] && [ "${REPO_ROOT}" != "$_lg_cfg" ]; then
  case "${REPO_ROOT}" in
    "$_lg_cfg"/*) git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO_ROOT="$_lg_cfg" ;;
  esac
fi

# item 20 (2026-07-03): use the SAME shared identity helper v-dispatch-subagent.sh's PROV_DIR
# resolution and durable-artifact-copy.sh already use (hooks/lib/git-main-root.sh:resolve_main_root),
# instead of the ad hoc `git worktree list | head -1` heuristic this script had. The heuristic
# assumes the primary checkout is always the FIRST row of `git worktree list` — true in the common
# case, but it is a path-prefix/listing-order guess, not the env-clean git-common-dir identity test
# resolve_main_root performs (Trap-3, verified against the external-worktree convention
# ~/.claude/worktrees/<repo>/<slug>). A divergent MAIN_ROOT here is exactly the cwd false-FAIL class:
# verify-done's artifact-existence check (which runs this consolidation first) can compute a
# different "main" than the dispatch/provenance path, decide the gate artifact is "missing," and the
# only workaround in use was to physically copy the artifact INTO the worktree so a wrong-root,
# cwd-relative check would still stumble onto it — a hack this fixes at the source instead of papering
# over. Falls back to the prior heuristic only if the shared helper is unavailable/fails.
_GMR_LIB_AC="$HOME/.claude/hooks/lib/git-main-root.sh"
MAIN_ROOT=""
if [ -f "$_GMR_LIB_AC" ]; then
  # shellcheck source=/dev/null
  source "$_GMR_LIB_AC" 2>/dev/null && MAIN_ROOT="$(resolve_main_root "$REPO_ROOT" 2>/dev/null || true)"
fi
if [ -z "$MAIN_ROOT" ]; then
  MAIN_ROOT=$(git worktree list 2>/dev/null | head -1 | awk '{print $1}')
fi
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"
_SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
ARTIFACT_DIR=$(bash "${_SELF_DIR:-$HOME/.claude/skills/v/references}/v-artifact-dir.sh" 2>/dev/null)
[ -n "$ARTIFACT_DIR" ] || ARTIFACT_DIR="$MAIN_ROOT/.v/artifacts"
mkdir -p "$ARTIFACT_DIR" 2>/dev/null || exit 0   # unwritable tree — nothing to do, never fail caller

# Every artifact prefix the Stop hook / self-check gate on, plus durable-worthy session records.
# P3-REGISTRY parity (2026-07-03): every prefix here MUST exist in the single-source registry
# (hooks/lib/artifact-prefix-registry.sh) — pinned by hooks/p3-artifact-prefix-registry-test.sh T5.
# This list stays a deliberate SUBSET of the registry: lifecycle-managed markers
# (SESSION_LOG_MISSING / GAUNTLET_SKIPPED — deleted by finalize / the clean-exit path) must NOT be
# consolidated or the durable copy resurrects a cleared marker; WINNER_ELECTION is slug-suffixed
# (no SID in the name — the glob below can't and shouldn't match it; its producer already writes
# straight to .v/artifacts).
_PREFIXES="PRE_FLIGHT_REPORT PRE_FLIGHT_ADDENDUM AGENT_REVIEW VERIFY_DONE_REPORT IMPACT_MAP QA_REPORT UX_CRITIQUE WORKFLOW_VERIFICATION BLOCKED TRIVIAL_PASS PLANNING_PASS HANDOFF SUCCESS_CRITERIA WORKFLOW_BLAST_RADIUS IMPLEMENTATION_REPORT QA_REMEDIATION WORKTREE_HANDOFF CYCLE_CAP_HANDOFF SID_COLLISION BITE_LEDGER PROGRESS_NOTE BUILD_BLOCKER"

# CONSOLIDATE-1 (audit 2026-06-18): physical (inode) identity for ARTIFACT_DIR. When git fails —
# e.g. the non-git ~/.claude meta-repo where self-audit work happens — REPO_ROOT/MAIN_ROOT fall back
# to a RELATIVE "." (line 51-53), so the source "$REPO_ROOT/.v/artifacts" = "./.v/artifacts" aliases
# the ABSOLUTE ARTIFACT_DIR as a different STRING. The string guards (line 66 below + the _f/_dst
# check) then failed to detect the same-file case, so a canonical artifact was cp'd onto itself and
# `rm -f "$_f"` DELETED it (data loss). Compare physical paths.
_ARTIFACT_DIR_PHYS="$(cd "$ARTIFACT_DIR" 2>/dev/null && pwd -P || echo "$ARTIFACT_DIR")"
for _pfx in $_PREFIXES; do
  for _src in "$REPO_ROOT" "$REPO_ROOT/.v/artifacts" "$PWD" "$MAIN_ROOT" "$@"; do
    [ -d "$_src" ] || continue
    _src_phys="$(cd "$_src" 2>/dev/null && pwd -P || echo "$_src")"
    { [ "$_src" = "$ARTIFACT_DIR" ] || [ "$_src_phys" = "$_ARTIFACT_DIR_PHYS" ]; } && continue   # don't reconcile the dir onto itself (string OR physical)
    for _f in "$_src/${_pfx}_"*"${SID}"*.md; do
      [ -f "$_f" ] || continue
      _dst="$ARTIFACT_DIR/$(basename "$_f")"
      # Same physical file (relative-vs-absolute alias) → already canonical, never rm it. `-ef` is the
      # data-loss safety net even if the dir-level guard above is bypassed.
      if [ "$_f" = "$_dst" ] || [ "$_f" -ef "$_dst" ]; then
        continue                                  # already canonical — nothing to do
      fi
      # Decide whether to overwrite dst with src.
      # Normal rule: src wins unless dst is STRICTLY newer.
      # Size-threshold override (MEDIUM fix 2026-06-09): if dst IS strictly newer but is
      # suspiciously small (< _MIN_MEANINGFUL_BYTES), prefer the larger src — a tiny newer
      # file is likely a partial write or stub, not a valid replacement.
      _dst_size=0
      _src_size=0
      if [ -f "$_dst" ]; then
        _dst_size=$(wc -c < "$_dst" 2>/dev/null | tr -d ' ') || _dst_size=0
      fi
      _src_size=$(wc -c < "$_f" 2>/dev/null | tr -d ' ') || _src_size=0
      _dst_is_strictly_newer=false
      [ -f "$_dst" ] && [ "$_dst" -nt "$_f" ] && _dst_is_strictly_newer=true
      _dst_too_small=false
      { [ "$_dst_is_strictly_newer" = "true" ] && [ "${_dst_size:-0}" -lt "$_MIN_MEANINGFUL_BYTES" ] && \
        [ "${_src_size:-0}" -gt "${_dst_size:-0}" ]; } && _dst_too_small=true
      if [ ! -f "$_dst" ] || [ "$_dst_is_strictly_newer" = "false" ] || [ "$_dst_too_small" = "true" ]; then
        # CODEX-001/005 (adversarial review 2026-06-04): never copy IN-PLACE over an existing
        # dst — a failed/partial cp would corrupt a valid older copy, and a symlinked dst would
        # be written THROUGH to its target. Stage to a hidden temp in the SAME dir (same fs →
        # atomic rename; leading dot + .tmp suffix keeps it outside the artifact globs), verify
        # non-empty, then mv -f (replaces a symlink itself, not its target). cp -p preserves the
        # source mtime through the temp, so later sweeps still compare real-source mtimes.
        _tmp="$ARTIFACT_DIR/.consolidate.$$.$(basename "$_f").tmp"
        if cp -p "$_f" "$_tmp" 2>/dev/null && [ -s "$_tmp" ] && mv -f "$_tmp" "$_dst" 2>/dev/null; then
          if [ "$_dst_too_small" = "true" ]; then
            echo "  consolidated $(basename "$_f") → .v/artifacts (size-override: dst ${_dst_size}B < ${_MIN_MEANINGFUL_BYTES}B threshold)" >&2
          else
            echo "  consolidated $(basename "$_f") → .v/artifacts" >&2
          fi
          rm -f "$_f" 2>/dev/null || true
        else
          rm -f "$_tmp" 2>/dev/null || true       # failed staging — source kept, dst untouched
        fi
      else
        rm -f "$_f" 2>/dev/null || true           # dst is STRICTLY newer and large enough — drop stale src
      fi
    done
  done
done

# ── P13 (forensic 2026-06-20): consolidate DISPATCH_PROVENANCE (.log) ──────
# DISPATCH_PROVENANCE_<sid>.log is a .log (not .md) and was absent from _PREFIXES AND from the .md-only
# glob above — so a WORKTREE session's provenance (written to <worktree>/.v/artifacts/ by
# v-dispatch-subagent.sh) never reached MAIN/.v/artifacts before the worktree was pruned. The gather +
# the Stop-hook independence check then read dispatch_path=none and FALSE-flagged an HONEST subagent
# dispatch as "over-claims independence" (W22-CC1b / the _independence_verdict gate), which is exactly
# what pushes the model to hand-massage AGENT_REVIEW to pass (P3/P5 death-march). Consolidate it too, but
# MERGE (append-unique) rather than overwrite: provenance is append-only and entries may exist in EITHER
# location (e.g. an inline pre-flight logged at main + worktree-dispatched reviews) — neither may be lost.
for _src in "$REPO_ROOT" "$REPO_ROOT/.v/artifacts" "$PWD" "$MAIN_ROOT" "$@"; do
  [ -d "$_src" ] || continue
  _src_phys="$(cd "$_src" 2>/dev/null && pwd -P || echo "$_src")"
  { [ "$_src" = "$ARTIFACT_DIR" ] || [ "$_src_phys" = "$_ARTIFACT_DIR_PHYS" ]; } && continue
  for _f in "$_src/DISPATCH_PROVENANCE_"*"${SID}"*.log; do
    [ -f "$_f" ] || continue
    _dst="$ARTIFACT_DIR/$(basename "$_f")"
    { [ "$_f" = "$_dst" ] || [ "$_f" -ef "$_dst" ]; } && continue
    _tmp="$ARTIFACT_DIR/.consolidate.$$.$(basename "$_f").tmp"
    # Union of existing dst (if any) + source, de-duplicated, dst lines first (stable). Stage to a temp
    # in the SAME dir → atomic mv; verify non-empty before replacing; drop the merged source on success.
    if cat "$_dst" "$_f" 2>/dev/null | awk 'NF && !seen[$0]++' > "$_tmp" 2>/dev/null && [ -s "$_tmp" ] \
         && mv -f "$_tmp" "$_dst" 2>/dev/null; then
      echo "  consolidated $(basename "$_f") → .v/artifacts (provenance append-merge)" >&2
      rm -f "$_f" 2>/dev/null || true
    else
      rm -f "$_tmp" 2>/dev/null || true
    fi
  done
done

# ── R1 (forensic 2026-06-21, post-batch live validation): consolidate the gauntlet GATE-SUMMARY + gate
# logs from the worktree's .v/tmp to MAIN/.v/tmp before the worktree is pruned. The session-log generator
# (_vtmp_file) reads gate-summary-<sid>.txt from MAIN/.v/tmp to populate gates_final; a WORKTREE session's
# gate-summary was stranded in the removed worktree, so gates_final stayed all NOT_APPLICABLE and the F12
# committed-no-gates net FALSE-failed every committed worktree session whose gauntlet PASSED (two production
# sessions logged FAILED this way). Copy (don't clobber a FRESHER main copy — a main-root pre-flight may
# have run too) so the durable gate evidence survives worktree removal. Same source set as P13.
_MAIN_VTMP="${MAIN_ROOT:-$REPO_ROOT}/.v/tmp"
mkdir -p "$_MAIN_VTMP" 2>/dev/null || true
for _src in "$@" "$PWD" "$REPO_ROOT"; do
  [ -d "$_src/.v/tmp" ] || continue
  for _gf in "$_src/.v/tmp/gate-summary-${SID}.txt" "$_src/.v/tmp/gate-"*"${SID}"*.log; do
    [ -f "$_gf" ] || continue
    # CANARY-A (DUC-001 + CRITIC-004, forensic 2026-06-22): promote to the DURABLE .v/artifacts store (survives
    # the swept .v/tmp AND worktree removal) IN ADDITION to .v/tmp (live readers). The R1-only .v/tmp copy still
    # got swept — all 3 canary sessions logged gates NOT_APPLICABLE -> F12 false-fail. The gather's _vtmp_file
    # now searches both, so .v/artifacts is the surviving fallback.
    for _gdst in "$_MAIN_VTMP/$(basename "$_gf")" "$ARTIFACT_DIR/$(basename "$_gf")"; do
      { [ "$_gf" = "$_gdst" ] || [ "$_gf" -ef "$_gdst" ]; } && continue
      [ -f "$_gdst" ] && [ "$_gdst" -nt "$_gf" ] && continue   # keep the fresher dest copy
      cp -p "$_gf" "$_gdst" 2>/dev/null && echo "  consolidated $(basename "$_gf") → ${_gdst#${MAIN_ROOT:-$REPO_ROOT}/} (gate evidence)" >&2 || true
    done
  done
done

# ── R6 (forensic 2026-06-21, post-batch live validation; comment corrected 2026-07-03 per item 20):
# consolidate a STRAY DISPATCH_LEDGER.jsonl into the canonical one. The G1 ledger is meant to live at
# MAIN/.v/artifacts, but one session's run left one at the repo ROOT (its only provenance — 3 rows) where
# the R2 dispatch_path derivation (which reads MAIN/.v/artifacts) cannot see it → dispatch_path=none
# persisted. NOTE: this was NOT a "pre-fix" one-off — v-dispatch-subagent.sh's emit_marker() wrote the
# ledger to the artifact's OWN dirname (worktree/root-local whenever --artifact was worktree-scoped),
# the same split-brain class its DISPATCH_PROVENANCE sibling already had a resolve_main_root fix for.
# That sibling idiom is now fixed at v-dispatch-subagent.sh:~319 (writes to the same resolved PROV_DIR
# the provenance log uses), so NEW stray root/worktree ledgers should stop accruing — but this sweep
# stays as a permanent backstop for anything written before that fix, or by any other future producer
# that reintroduces the same mistake. Append-MERGE (de-duplicated; the ledger is append-only and rows
# may exist in EITHER place — never lose one) any ledger found at the bare root / PWD / a worktree into
# the canonical, then drop the merged source. Mirrors the P13 DISPATCH_PROVENANCE reconciliation
# (different filename, NOT sid-scoped — the ledger is session-global).
_CANON_LEDGER="$ARTIFACT_DIR/DISPATCH_LEDGER.jsonl"
for _src in "$@" "$PWD" "$REPO_ROOT" "$MAIN_ROOT"; do
  [ -d "$_src" ] || continue
  for _lf in "$_src/DISPATCH_LEDGER.jsonl" "$_src/.v/artifacts/DISPATCH_LEDGER.jsonl"; do
    [ -f "$_lf" ] || continue
    { [ "$_lf" = "$_CANON_LEDGER" ] || [ "$_lf" -ef "$_CANON_LEDGER" ]; } && continue
    _ltmp="$ARTIFACT_DIR/.consolidate.$$.ledger.tmp"
    if cat "$_CANON_LEDGER" "$_lf" 2>/dev/null | awk 'NF && !seen[$0]++' > "$_ltmp" 2>/dev/null && [ -s "$_ltmp" ] \
         && mv -f "$_ltmp" "$_CANON_LEDGER" 2>/dev/null; then
      echo "  consolidated stray DISPATCH_LEDGER ($_lf) → .v/artifacts (append-merge)" >&2
      rm -f "$_lf" 2>/dev/null || true
    else
      rm -f "$_ltmp" 2>/dev/null || true
    fi
  done
done

# ── W5F-9 (forensic 2026-06-06): SESSION_LOG reconciliation ───────────────────────────
# SESSION_LOG_<sid>.yaml is canonical at the MAIN root (the resolver's catch-up scan,
# worktree-removal reclaim checks, and analysts all look there). A production session generated
# its log INSIDE a worktree and it never reached main — from the main root the
# session read as "unlogged" indefinitely. Same verified-move semantics as the artifact
# loop above; destination is MAIN_ROOT itself (logs do not live in .v/artifacts).
_main_phys="$(cd "$MAIN_ROOT" 2>/dev/null && pwd -P)"
for _src in "$REPO_ROOT" "$PWD" "$@"; do
  [ -d "$_src" ] || continue
  # Physical-path identity guard: the same dir reachable via two strings (symlink, trailing
  # component) must not pass the string-compare below — a self-move would end in `rm -f` of
  # the file just moved onto itself.
  _src_phys="$(cd "$_src" 2>/dev/null && pwd -P)"
  [ -n "$_src_phys" ] || continue
  [ "$_src_phys" = "$_main_phys" ] && continue
  for _f in "$_src/SESSION_LOG_"*"${SID}"*.yaml; do
    [ -f "$_f" ] || continue
    _dst="$MAIN_ROOT/$(basename "$_f")"
    [ "$_f" = "$_dst" ] && continue               # already canonical
    if [ ! -f "$_dst" ] || [ ! "$_dst" -nt "$_f" ]; then
      _tmp="$MAIN_ROOT/.consolidate.$$.$(basename "$_f").tmp"
      if cp -p "$_f" "$_tmp" 2>/dev/null && [ -s "$_tmp" ] && mv -f "$_tmp" "$_dst" 2>/dev/null; then
        echo "  consolidated $(basename "$_f") → main root" >&2
        rm -f "$_f" 2>/dev/null || true
      else
        rm -f "$_tmp" 2>/dev/null || true         # failed staging — source kept, dst untouched
      fi
    else
      rm -f "$_f" 2>/dev/null || true             # dst is STRICTLY newer — drop the stale source dup
    fi
  done
done

exit 0
