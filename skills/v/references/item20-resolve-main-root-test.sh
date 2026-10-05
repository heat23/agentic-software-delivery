#!/usr/bin/env bash
# item20-resolve-main-root-test.sh — regression for PLAN_forensics-remediation-20260703.md item 20
# (2026-07-03): verify-done runner artifact-existence via resolve_main_root kills the cwd false-FAIL
# AND the artifact-copy-into-worktree hack; ledger write at v-dispatch-subagent.sh:~319 uses the
# resolved canonical dir (same partial-fix class the sibling DISPATCH_PROVENANCE write already had).
#
# Two independently-verifiable claims:
#   (A) v-artifact-consolidate.sh resolves MAIN_ROOT via the SHARED resolve_main_root() helper
#       (hooks/lib/git-main-root.sh), not the ad hoc `git worktree list | head -1` heuristic — so a
#       run from inside a linked worktree still lands artifacts in the TRUE main checkout's
#       .v/artifacts, not wherever the listing-order heuristic happened to guess.
#   (B) v-dispatch-subagent.sh's DISPATCH_LEDGER.jsonl append uses PROV_DIR (the same
#       resolve_main_root-resolved dir DISPATCH_PROVENANCE already uses), not the raw ART_DIR
#       (dirname of --artifact) — closing the sibling-idiom gap that left a stray worktree-local
#       ledger even after A-1a fixed the provenance log.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CONSOLIDATE="$HERE/v-artifact-consolidate.sh"
DISPATCH="$HERE/v-dispatch-subagent.sh"
GMR="$HOME/.claude/hooks/lib/git-main-root.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$CONSOLIDATE" ] || { echo "SKIP: $CONSOLIDATE missing"; exit 0; }
[ -f "$DISPATCH" ] || { echo "SKIP: $DISPATCH missing"; exit 0; }

echo "== (A) v-artifact-consolidate.sh uses resolve_main_root, not worktree-list-order heuristic =="

if grep -q 'source "\$_GMR_LIB_AC"' "$CONSOLIDATE" && grep -q 'resolve_main_root "\$REPO_ROOT"' "$CONSOLIDATE"; then
  ok "v-artifact-consolidate.sh sources git-main-root.sh and calls resolve_main_root (wired)"
else
  no "v-artifact-consolidate.sh does not call resolve_main_root — cwd false-FAIL fix not wired"
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
MAIN="$WORK/main"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com; git -C "$MAIN" config user.name t
: > "$MAIN/.gitkeep"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init
WT="$WORK/wt-external/fix-slug-item20test"
mkdir -p "$WORK/wt-external"
git -C "$MAIN" worktree add -q -b fix/slug-item20test "$WT" >/dev/null 2>&1

SID="item20aa-bbbb-4000-8000-000000000000"
# Root-level artifact left in the WORKTREE (the shape that used to require the "copy the artifact
# into the worktree" hack for a cwd-relative check to find it).
printf 'Model: haiku\nOverall Status: PASS\n' > "$WT/PRE_FLIGHT_REPORT_${SID}.md"

# Run consolidate FROM INSIDE THE WORKTREE (cwd = worktree) — the exact cwd false-FAIL shape: a
# naive `git worktree list | head -1` run from here could, depending on listing order/environment,
# disagree with the true main checkout. resolve_main_root must always resolve to $MAIN regardless.
( cd "$WT" && bash "$CONSOLIDATE" "$SID" >/dev/null 2>&1 )

MAIN_CANON="$(cd "$MAIN" && pwd -P)"
if [ -f "$MAIN_CANON/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md" ]; then
  ok "artifact consolidated into the TRUE main checkout's .v/artifacts from a worktree cwd"
else
  no "artifact did NOT land in main .v/artifacts (cwd false-FAIL reproduced)"
fi

echo
echo "== (B) DISPATCH_LEDGER.jsonl append uses PROV_DIR (canonical), not raw ART_DIR =="

if grep -q '"\${PROV_DIR:-\$ART_DIR}/DISPATCH_LEDGER.jsonl"' "$DISPATCH"; then
  ok "ledger append targets \${PROV_DIR:-\$ART_DIR} (resolved canonical dir, same as DISPATCH_PROVENANCE)"
else
  no "ledger append still targets raw ART_DIR — worktree split-brain not fixed"
fi

# Confirm PROV_DIR is computed via the SAME resolve_main_root call before the ledger write appears
# (ordering pin — PROV_DIR must be defined above the emit_marker function that writes the ledger).
PROV_DIR_LINE=$(grep -n 'PROV_DIR="' "$DISPATCH" | head -1 | cut -d: -f1)
LEDGER_LINE=$(grep -n 'PROV_DIR:-\$ART_DIR}/DISPATCH_LEDGER.jsonl' "$DISPATCH" | head -1 | cut -d: -f1)
if [ -n "$PROV_DIR_LINE" ] && [ -n "$LEDGER_LINE" ] && [ "$PROV_DIR_LINE" -lt "$LEDGER_LINE" ]; then
  ok "PROV_DIR is defined (line $PROV_DIR_LINE) before the ledger write consumes it (line $LEDGER_LINE)"
else
  no "PROV_DIR definition does not precede the ledger write — would read an unset/empty var"
fi

# ── Cycle-3 F-item20b (2026-07-04): the CONSUMER side must resolve MAIN the same way ────────────
# v-artifact-consolidate.sh PUTS artifacts at resolve_main_root's answer; the Stop hook
# (check-review-artifact.sh) and its predictor (v-completion-selfcheck.sh) SEARCH for them via
# MAIN_ROOT. If either still uses only the cwd-sensitive `git worktree list | head -1` heuristic,
# the false-"missing" class is half-closed. Pin the call chain in BOTH consumers: a
# resolve_main_root call must appear, and must appear BEFORE the heuristic (which stays as the
# lib-missing fallback only).
for consumer in "$HOME/.claude/hooks/check-review-artifact.sh" "$HERE/v-completion-selfcheck.sh"; do
  cname=$(basename "$consumer")
  if [ ! -f "$consumer" ]; then no "$cname missing on disk"; continue; fi
  # Match the actual CALL shapes, not comment lines that merely mention either idiom.
  RMR_LINE=$(grep -n 'MAIN_ROOT="\$(resolve_main_root' "$consumer" | head -1 | cut -d: -f1)
  HEUR_LINE=$(grep -n 'MAIN_ROOT=\$(git worktree list' "$consumer" | head -1 | cut -d: -f1)
  if [ -n "$RMR_LINE" ] && [ -n "$HEUR_LINE" ] && [ "$RMR_LINE" -lt "$HEUR_LINE" ]; then
    ok "$cname resolves MAIN via resolve_main_root (line $RMR_LINE) with the heuristic only as fallback (line $HEUR_LINE)"
  else
    no "$cname MAIN_ROOT resolution not migrated (resolve_main_root=$RMR_LINE heuristic=$HEUR_LINE) — consumer/producer split-brain"
  fi
done

# Behavioral: in a fixture repo with an external linked worktree, resolve_main_root from INSIDE
# the worktree must name the main checkout — the answer the consolidator uses; proves the shared
# helper gives the same identity from both sides of the split the old heuristic could straddle.
FIX=$(mktemp -d); ( cd "$FIX" && git init -q -b main && git config user.email t@t.local && git config user.name t && echo x > f && git add -A && git commit -qm i ) >/dev/null 2>&1
EXT=$(mktemp -d)/wt; git -C "$FIX" worktree add -q "$EXT" -b b/x HEAD 2>/dev/null
# shellcheck source=/dev/null
source "$HOME/.claude/hooks/lib/git-main-root.sh" 2>/dev/null
_from_wt="$(resolve_main_root "$EXT" 2>/dev/null)"
_fix_real="$(cd "$FIX" && pwd -P)"
[ "$_from_wt" = "$_fix_real" ] \
  && ok "resolve_main_root from inside the external worktree names the main checkout ($_fix_real)" \
  || no "resolve_main_root parity broken: from-wt=[$_from_wt] expected [$_fix_real]"
git -C "$FIX" worktree remove --force "$EXT" >/dev/null 2>&1
rm -rf "$FIX" "$(dirname "$EXT")" 2>/dev/null

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
