#!/usr/bin/env bash
# v-classify-schema-doc-test.sh
# Version: 1.0.0 (W-SCHEMA-DOC, 2026-08-06)
#
# Guards the migrations/seeders hard exclusion in BOTH tier classifiers.
#
# THE INCIDENT. A production session made an ordinary bounded code change — 6 non-test
# files, an accompanying test file with real changed lines, no security path, no UI, no schema
# change of any kind — and was denied the MEDIUM tier, owing the full gauntlet including IMPACT_MAP.
# Live-firing the classifier against its exact file set isolated the cause to ONE file:
#
#   MEDIUM=0  REASON=migration_hard_excluded:database/migrations/CLAUDE.md
#
# Removing that single file from the diff flipped it to MEDIUM=1 medium_ordinary_code_diff.
# `database/migrations/CLAUDE.md` is DOCUMENTATION — the repo's own migration-writing guide. It
# cannot define or alter a schema. The session had edited it to correct a stale
# infrastructure claim.
#
# THE CLASS. The exclusion matched a PATH PREFIX as a proxy for the property "does this file define
# or alter database schema". Editing prose inside the directory is indistinguishable from adding a
# migration, to a prefix match. Same shape as the other guards fixed this week: a detector measuring
# dispatch-spread instead of batching, a regex pinning a column position instead of "is this a gate
# row", frontmatter instead of the dispatched model.
#
# THE FIX, AND ITS DIRECTION. Narrow the exclusion to files that can actually carry schema. Only a
# short, explicit DOC extension allow-list (.md/.txt/.rst) is admitted; everything else under
# database/{migrations,seeders}/ — .php, .sql, .sqlite, extensionless, anything unrecognised —
# still hard-excludes. So the failure direction stays SAFE: an unknown file type is treated as
# schema-bearing, never as documentation.
#
# WHY BOTH FILES. The predicate is duplicated in v-classify-medium-tier.sh AND
# v-classify-light-tier.sh. v-classify-medium-tier.sh's own SE-1 comment records that the last
# duplicated block in these two files drifted THE SAME DAY the second copy was written. This
# harness asserts both, so a fix to one and not the other fails here.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MED="${V_MEDIUM_CLASSIFIER:-$ROOT/skills/v/references/v-classify-medium-tier.sh}"
LIGHT="${V_LIGHT_CLASSIFIER:-$ROOT/skills/v/references/v-classify-light-tier.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# Build a repo whose diff is an ordinary MEDIUM-eligible code change, plus $1 as one extra file.
# Mirrors the real incident shape: app code + config + an accompanying test.
mk(){ # $1 = extra file path (may be empty)
  local R="$WORK/r$RANDOM$RANDOM"; mkdir -p "$R"; ( cd "$R" && git init -q )
  local base="app/Console/Commands/AlphaCommand.php app/Services/Metrics/BetaClient.php config/metrics.php tests/Feature/Commands/AlphaCommandTest.php"
  local all="$base ${1:-}"
  for f in $all; do mkdir -p "$R/$(dirname "$f")"; printf 'base\n' > "$R/$f"; done
  ( cd "$R" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m base )
  for f in $all; do printf 'base\nchanged\n' > "$R/$f"; done
  printf '%s' "$R"
}
verdict(){ # $1=classifier $2=repo -> "TIER=<0|1> REASON=<...>"
  local out; out=$( REPO_ROOT="$2" bash "$1" 2>/dev/null )
  printf '%s %s' "$(printf '%s\n' "$out" | grep -E '^(MEDIUM|LIGHT)=' | head -1)" \
                 "$(printf '%s\n' "$out" | grep -E '^REASON=' | head -1)"
}

echo "== W-SCHEMA-DOC :: docs under database/migrations are not schema changes =="

# ── control: the same diff with NO database/ file at all must reach MEDIUM ──
R=$(mk ""); v=$(verdict "$MED" "$R")
case "$v" in
  MEDIUM=1*) ok "control: ordinary code diff with no database/ file -> MEDIUM=1" ;;
  *) no "control: ordinary diff reaches MEDIUM" "MEDIUM=1" "$v" ;;
esac

# ── the incident: a DOC under database/migrations/ must not deny the tier ──
for doc in database/migrations/CLAUDE.md database/migrations/README.md database/seeders/NOTES.txt; do
  R=$(mk "$doc"); v=$(verdict "$MED" "$R")
  case "$v" in
    MEDIUM=1*) ok "doc '$doc' does not hard-exclude MEDIUM" ;;
    *) no "doc '$doc' does not hard-exclude MEDIUM" "MEDIUM=1" "$v" ;;
  esac
done

# ── REAL schema files must STILL hard-exclude. This is the half that must not regress. ──
for sch in \
  database/migrations/2026_08_06_000000_add_column.php \
  database/seeders/ItemSeeder.php \
  database/migrations/0001_init.sql \
  database/migrations/legacy_dump.sqlite \
  database/migrations/run_me ; do
  R=$(mk "$sch"); v=$(verdict "$MED" "$R")
  case "$v" in
    MEDIUM=0*migration_hard_excluded*) ok "schema-bearing '$sch' still hard-excluded" ;;
    *) no "schema-bearing '$sch' still hard-excluded" "MEDIUM=0 migration_hard_excluded" "$v" ;;
  esac
done

# ── a .md ELSEWHERE under database/ (not migrations/seeders) was never excluded; unchanged ──
R=$(mk "database/factories/NOTES.md"); v=$(verdict "$MED" "$R")
case "$v" in
  MEDIUM=1*) ok "database/factories/NOTES.md unaffected (outside the excluded dirs)" ;;
  *) no "database/factories/NOTES.md unaffected" "MEDIUM=1" "$v" ;;
esac

echo
echo "== the SAME narrowing must land in the LIGHT classifier (SE-1 drift guard) =="
# LIGHT admits no application code, so it is asserted at the PREDICATE level: both files must carry
# the doc-extension carve-out, or one has been fixed and the other left behind — the exact drift
# v-classify-medium-tier.sh's SE-1 comment records happening the same day the copy was made.
for f in "$MED" "$LIGHT"; do
  if grep -qE 'database/\(migrations\|seeders\)/' "$f" 2>/dev/null; then
    if grep -qE '\(md\|txt\|rst\)|\\.md\|\\.txt' "$f" 2>/dev/null; then
      ok "$(basename "$f") carries the documentation carve-out"
    else
      no "$(basename "$f") carries the documentation carve-out" \
         "a doc-extension exemption beside the migrations exclusion" "prefix-only match (still denies docs)"
    fi
  else
    no "$(basename "$f") still has a migrations exclusion" "the exclusion present" "not found — the stop-list was removed, not narrowed"
  fi
done

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
