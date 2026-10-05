#!/usr/bin/env bash
# v-light-tier-session-scope-test.sh — W-LIGHT-SCOPE regression harness (2026-08-03)
#
# WHY THIS EXISTS: v-classify-light-tier.sh and v-classify-trivial.sh built CHANGED_FILES from
# WHOLE-TREE `git diff --name-only HEAD` + `--cached`. With caps of 4 files / 30 lines, any repo
# carrying unrelated dirty WIP made the LIGHT and TRIVIAL fast lanes STRUCTURALLY UNREACHABLE —
# every session paid the full 7-artifact gauntlet no matter how small its own diff. Observed live:
# a repo with dozens of stale dirty files classified a 2-file CI-config change as
# `LIGHT=0 too_many_non_test_files:30>max=4`. Corroborating telemetry: TRIVIAL_PASS fired only a
# handful of times across several repos, against dozens each of STOP_REARM_ESCAPE, GATE_MODE_DOWNGRADE
# and FND3_ORPHAN_ESCAPE events.
#
# The fix scopes the uncommitted/staged legs to THIS session's writes (hooks/lib/session-writes.sh).
# `_SESSION_COMMIT_FILES` was already session-scoped (A4 machinery) and is untouched.
#
# THE FOUR PROPERTIES THIS GUARDS (all four matter — 2 and 3 are what keep it from being a hole):
#   1. GREEN      — foreign dirty files no longer sink a small own-diff.
#   2. NON-VACUITY— a session's OWN oversized diff is still capped. Without this leg the fix could
#                   degrade to "always LIGHT=1" and the test would still pass.
#   3. FAIL-STRICT— writes-log missing/empty falls back to WHOLE-TREE, never to the fast lane.
#                   Whole-tree is a superset ⇒ can only make the caps harder to clear.
#   4. SECURITY   — scoping also scopes the per-file security/UI/migration hard-excludes. That is
#                   INTENDED: your OWN migration still excludes you; a SIBLING session's dirty
#                   migration no longer does. Same attribution rule as uncommitted-changes-gate.sh.
#
# Usage: bash v-light-tier-session-scope-test.sh [PRE_SCRIPT] [POST_SCRIPT]
#   PRE  defaults to ./v-classify-light-tier.sh.pre-lightscope-bak (FROZEN red oracle — never sweep;
#        if absent the RED leg is skipped loudly, it is never silently passed)
#   POST defaults to ./v-classify-light-tier.sh
set -u

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE="${1:-$_HERE/v-classify-light-tier.sh.pre-lightscope-bak}"
POST="${2:-$_HERE/v-classify-light-tier.sh}"
# run() cd's into a temp repo, so both paths MUST be absolute.
case "$PRE"  in /*) ;; *) PRE="$(cd "$(dirname "$PRE")"  && pwd)/$(basename "$PRE")"  ;; esac
case "$POST" in /*) ;; *) POST="$(cd "$(dirname "$POST")" && pwd)/$(basename "$POST")" ;; esac

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); echo "  ok    $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL  $1 :: ${2:-}"; }
sk(){ SKIP=$((SKIP+1)); echo "  SKIP  $1"; }

mkrepo(){
  local r; r=$(mktemp -d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  mkdir -p "$r/config" "$r/database/migrations"
  local i; for i in $(seq 1 40); do printf '<?php return [];\n' > "$r/config/other$i.php"; done
  printf 'export default {};\n' > "$r/vite.config.ts"
  printf '{"name":"fx"}\n'      > "$r/package.json"
  printf '<?php // mig\n'       > "$r/database/migrations/2024_01_01_000000_x.php"
  git -C "$r" add -A; git -C "$r" commit -qm base
  printf '%s' "$r"
}
wlog(){ local r="$1" sid="$2"; shift 2; local g
  g=$(git -C "$r" rev-parse --git-common-dir); case "$g" in /*) ;; *) g="$r/$g";; esac
  printf '%s\n' "$@" > "$g/claude-session-writes-${sid}.txt"; }
run(){ ( cd "$2" && CLAUDE_SESSION_ID="$3" REPO_ROOT="$2" bash "$1" 2>/dev/null ); }

echo "== W-LIGHT-SCOPE :: session-scoped classifier =="

R=$(mkrepo); SID=aaaaaaaa-1111-4111-8111-111111111111
for i in $(seq 1 40); do printf '// foreign wip\n' >> "$R/config/other$i.php"; done
printf 'export const x=1;\n' >> "$R/vite.config.ts"; printf '{"name":"fx","v":2}\n' > "$R/package.json"
wlog "$R" "$SID" vite.config.ts package.json

if [ -f "$PRE" ]; then
  if run "$PRE" "$R" "$SID" | grep -q '^LIGHT=0'; then ok "RED: pre-fix oracle blocks a 2-file session diff (bite proven)"
  else no "RED not reproduced — oracle may be stale" "$(run "$PRE" "$R" "$SID" | tr '\n' ' ')"; fi
else
  sk "RED: frozen oracle absent ($PRE) — bite NOT proven this run"
fi

if run "$POST" "$R" "$SID" | grep -q '^LIGHT=1'; then ok "GREEN: 40 foreign dirty files no longer sink the session's 2-file diff"
else no "GREEN failed" "$(run "$POST" "$R" "$SID" | tr '\n' ' ')"; fi

R2=$(mkrepo); S2=bbbbbbbb-2222-4222-8222-222222222222
for i in 1 2 3 4 5 6; do printf '// own\n' >> "$R2/config/other$i.php"; done
wlog "$R2" "$S2" config/other1.php config/other2.php config/other3.php config/other4.php config/other5.php config/other6.php
O=$(run "$POST" "$R2" "$S2")
if printf '%s' "$O" | grep -q '^LIGHT=0'; then ok "NON-VACUITY: session's OWN 6-file diff still capped"
else no "NON-VACUITY: own 6-file diff wrongly passed" "$(printf '%s' "$O" | tr '\n' ' ')"; fi

R3=$(mkrepo); S3=cccccccc-3333-4333-8333-333333333333
for i in $(seq 1 40); do printf '// foreign wip\n' >> "$R3/config/other$i.php"; done
printf 'export const x=1;\n' >> "$R3/vite.config.ts"
O=$(run "$POST" "$R3" "$S3")   # deliberately NO writes-log
if printf '%s' "$O" | grep -q '^LIGHT=0'; then ok "FAIL-STRICT: missing writes-log falls back to whole-tree (denies fast lane)"
else no "FAIL-STRICT: missing writes-log went PERMISSIVE" "$(printf '%s' "$O" | tr '\n' ' ')"; fi

R4=$(mkrepo); S4=dddddddd-4444-4444-8444-444444444444
printf '<?php // FOREIGN edit\n' >> "$R4/database/migrations/2024_01_01_000000_x.php"
printf 'export const x=1;\n' >> "$R4/vite.config.ts"
wlog "$R4" "$S4" vite.config.ts
O=$(run "$POST" "$R4" "$S4")
if printf '%s' "$O" | grep -q '^LIGHT=1'; then ok "SECURITY: a SIBLING's dirty migration no longer blocks this session"
else no "SECURITY: foreign migration still blocks" "$(printf '%s' "$O" | tr '\n' ' ')"; fi

R5=$(mkrepo); S5=eeeeeeee-5555-4555-8555-555555555555
printf '<?php // MY edit\n' >> "$R5/database/migrations/2024_01_01_000000_x.php"
wlog "$R5" "$S5" database/migrations/2024_01_01_000000_x.php
O=$(run "$POST" "$R5" "$S5")
if printf '%s' "$O" | grep -q '^LIGHT=0'; then ok "SECURITY: the session's OWN migration STILL hard-excludes it"
else no "SECURITY: OWN migration LEAKED into the fast lane" "$(printf '%s' "$O" | tr '\n' ' ')"; fi

rm -rf "$R" "$R2" "$R3" "$R4" "$R5" 2>/dev/null
echo
echo "TOTAL: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
