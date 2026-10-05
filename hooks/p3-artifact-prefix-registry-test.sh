#!/usr/bin/env bash
# p3-artifact-prefix-registry-test.sh — P3 CLASS-1 fix: single-source artifact-prefix registry
# (2026-07-03). The session-writes attribution filter (lib/session-writes.sh) and the producer-
# side skip (track-session-writes.sh) each carried their OWN copy of "the set of per-session
# artifact prefixes" and had ALREADY drifted (both missed QA_REPORT/IMPACT_MAP/TRIVIAL_PASS/
# SESSION_LOG_MISSING/SID_COLLISION → those writes polluted session attribution). Both now
# source hooks/lib/artifact-prefix-registry.sh.
#
# This harness catches the WHOLE class, not the instance:
#   T1  registry exists + exports the alternation, the anchored RE, and the helper fn
#   T2  registry COMPLETENESS: every `<PREFIX>_${SESSION_ID}`-shaped artifact filename literally
#       written by hooks/ + skills/*/references/ appears in the registry (a NEW artifact writer
#       without a registry entry turns this RED — the anti-rot net)
#   T3  session-writes.sh filter behavior: registry prefixes filtered, real files kept,
#       no-UUID lookalikes kept (tests/PLAN_helper.md)
#   T4  track-session-writes parity: its authoritative check uses the registry RE (structural),
#       and its pre-filter case covers every registry prefix (drift check)
# RED ORACLE: with V_ARTIFACT_PREFIX_REGISTRY pointed at /dev/null AND the pre-p3reg snapshots
# restored, T2/T3(new-prefix cases)/T4 fail (proven at ship time; see BITE_LEDGER).
set -u
REG="${V_APR_OVERRIDE:-$HOME/.claude/hooks/lib/artifact-prefix-registry.sh}"
SW="${V_SW_OVERRIDE:-$HOME/.claude/hooks/lib/session-writes.sh}"
TW="${V_TW_OVERRIDE:-$HOME/.claude/hooks/track-session-writes.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== P3 :: artifact-prefix registry (single source + completeness net) =="

# T1
if [ ! -f "$REG" ]; then
  no "registry lib exists" "missing (pre-P3 = RED)"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
. "$REG"
{ [ -n "${V_ARTIFACT_PREFIX_ALTERNATION:-}" ] && [ -n "${V_ARTIFACT_PREFIX_PATH_RE:-}" ] && type is_session_artifact_path >/dev/null 2>&1; } \
  && ok "T1 registry exports alternation + anchored RE + helper" \
  || no "T1 registry exports incomplete" ""

# T2 — completeness net: scan writers for literal <PREFIX>_${SESSION_ID / <sid>} artifact names.
FOUND_PREFIXES=$(grep -rhoE '[A-Z][A-Z0-9_]{2,40}_\$\{?SESSION_ID' \
    "$HOME/.claude/hooks" "$HOME/.claude/skills" 2>/dev/null \
  | sed -E 's/_\$\{?SESSION_ID$//' | sort -u \
  | grep -vE '^(CLAUDE|CLAUDE_CODE|V|CC)$' || true)
MISSING=""
for p in $FOUND_PREFIXES; do
  printf '%s' "$p" | grep -qE "^(${V_ARTIFACT_PREFIX_ALTERNATION})$" || MISSING="$MISSING $p"
done
# Known non-artifact variable-shaped hits (uppercase vars that aren't filenames) — keep this
# allowlist SHORT and reviewed; a growing allowlist means the grep needs tightening instead.
ALLOW_RE='^(DISPATCH_PROVENANCE|OP_TELEMETRY|WORKTREE_LOCK|DISPATCH_LEDGER|INCOMPLETE|GAUNTLET_STALE_LIST)$'
# GAUNTLET_STALE_LIST (added 2026-08-29, close-out audit): NOT a missing registration — it is
# OUT OF CONTRACT. The registry's own contract (hooks/lib/artifact-prefix-registry.sh) defines a
# per-session artifact as `<PREFIX>_<uuid>[.<sub>].(md|yaml|yml|json)`, and this writer emits
# `GAUNTLET_STALE_LIST_${SID}.txt` (v-gauntlet-attest.sh, the W-REMEDIATE-SIDECAR advisory
# sidecar). The grep above ignores the extension, so it flagged a .txt writer the contract
# deliberately excludes; registering it would make consumers treat .txt sidecars as gauntlet
# artifacts. If the contract is ever widened to .txt, remove this entry and register it properly.  # INCOMPLETE: prose-only hit — gate messages say "FAILED/INVALID/INCOMPLETE_${SESSION_ID}.md"; the real prefix SESSION_LOG_INCOMPLETE is registered
REAL_MISSING=""
for p in $MISSING; do printf '%s' "$p" | grep -qE "$ALLOW_RE" || REAL_MISSING="$REAL_MISSING $p"; done
[ -z "$REAL_MISSING" ] \
  && ok "T2 completeness: every <PREFIX>_\${SESSION_ID} writer in hooks/+skills/ is in the registry (or the reviewed allowlist)" \
  || no "T2 registry MISSING prefixes written by the ecosystem" "$REAL_MISSING"

# T3 — behavior through the REAL session-writes filter
SID="dddd1111-2222-3333-4444-555566667777"
R="$WORK/repo"; mkdir -p "$R"; git -C "$R" init -q 2>/dev/null
GITDIR=$(git -C "$R" rev-parse --git-dir)
cat > "$R/$GITDIR/claude-session-writes-${SID}.txt" <<EOF
app/Services/Real.php
QA_REPORT_${SID}.md
IMPACT_MAP_${SID}.md
TRIVIAL_PASS_${SID}.md
SID_COLLISION_${SID}.md
SESSION_LOG_MISSING_${SID}.md
AGENT_REVIEW_${SID}.md
tests/PLAN_helper.md
EOF
OUT=$(cd "$R" && bash -c ". '$SW'; get_session_writes '$SID'")
{ printf '%s\n' "$OUT" | grep -q 'app/Services/Real.php' && printf '%s\n' "$OUT" | grep -q 'tests/PLAN_helper.md'; } \
  && ok "T3 real files + no-UUID lookalikes survive the filter" \
  || no "T3 over-filtering: real files dropped" "$OUT"
LEAKED=$(printf '%s\n' "$OUT" | grep -cE 'QA_REPORT|IMPACT_MAP|TRIVIAL_PASS|SID_COLLISION|SESSION_LOG_MISSING|AGENT_REVIEW' || true)
[ "${LEAKED:-0}" -eq 0 ] \
  && ok "T3 all registry artifacts filtered from attribution (incl. the previously-leaking QA_REPORT/IMPACT_MAP/TRIVIAL_PASS/SID_COLLISION)" \
  || no "T3 artifacts LEAKED into attribution (pre-P3 = RED)" "$(printf '%s\n' "$OUT" | grep -E 'QA_REPORT|IMPACT_MAP|TRIVIAL|SID_COLL|MISSING' | head -3)"

# T4 — track-session-writes parity
grep -q 'V_ARTIFACT_PREFIX_PATH_RE' "$TW" \
  && ok "T4 track-session-writes authoritative check uses the registry RE (structural)" \
  || no "T4 track-session-writes does not consume the registry (pre-P3 = RED)" ""
CASE_LINE=$(grep -E '^\s*\*AGENT_REVIEW_\*' "$TW" | head -1)
T4_MISS=""
for p in $(printf '%s' "$V_ARTIFACT_PREFIX_ALTERNATION" | tr '|' ' '); do
  case "$p" in
    SESSION_LOG_*|PRE_FLIGHT_*|GAUNTLET_*) continue ;;  # covered by the *SESSION_LOG_*/*PRE_FLIGHT_*/*GAUNTLET_* globs
  esac
  printf '%s' "$CASE_LINE" | grep -q "\*${p}_\*" || T4_MISS="$T4_MISS $p"
done
[ -z "$T4_MISS" ] \
  && ok "T4 pre-filter case covers every registry prefix (no re-drift)" \
  || no "T4 pre-filter case missing registry prefixes" "$T4_MISS"

# T5 — consolidate parity: every _PREFIXES entry in v-artifact-consolidate.sh must be a
# registry member (consolidate is a deliberate SUBSET; a prefix here that the registry doesn't
# know is a typo or rot).
CONS="$HOME/.claude/skills/v/references/v-artifact-consolidate.sh"
CONS_PREFIXES=$(sed -n 's/^_PREFIXES="\(.*\)"$/\1/p' "$CONS" | head -1)
T5_MISS=""
for p in $CONS_PREFIXES; do
  printf '%s' "$p" | grep -qE "^(${V_ARTIFACT_PREFIX_ALTERNATION})$" || T5_MISS="$T5_MISS $p"
done
{ [ -n "$CONS_PREFIXES" ] && [ -z "$T5_MISS" ]; } \
  && ok "T5 v-artifact-consolidate _PREFIXES ⊆ registry (no rot/typos)" \
  || no "T5 consolidate prefixes unknown to registry" "$T5_MISS"
printf '%s' "$CONS_PREFIXES" | grep -q 'SID_COLLISION' \
  && ok "T5b consolidate covers the 2026-07 additions (SID_COLLISION present)" \
  || no "T5b consolidate list not extended (pre-fix = RED)" ""

# T6 — readonly-edit-guard consumes the registry (structural) + behavioral: a QA_REPORT write
# is allowlisted in a read-only session.
ROG="$HOME/.claude/hooks/readonly-edit-guard.sh"
grep -q 'is_session_artifact_path' "$ROG" \
  && ok "T6 readonly-edit-guard consults the registry helper (pre-fix = RED)" \
  || no "T6 readonly-edit-guard does not consume the registry" ""

# T7 — inventory knows the gate artifacts it used to undercount.
INV="$HOME/.claude/scripts/session-artifact-inventory.sh"
T7_MISS=""
for p in QA_REPORT IMPACT_MAP TRIVIAL_PASS UX_CRITIQUE SID_COLLISION; do
  grep -q "^  $p\$" "$INV" || T7_MISS="$T7_MISS $p"
done
[ -z "$T7_MISS" ] \
  && ok "T7 session-artifact-inventory enumerates the previously-undercounted types" \
  || no "T7 inventory still missing types (pre-fix = RED)" "$T7_MISS"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
