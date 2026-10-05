#!/usr/bin/env bash
# v-classify-medium-tier.sh
# Version: 1.0.0  (W-MEDIUM — ordinary-code-change tier, 2026-08-03)
#
# THE THIRD TIER. The ecosystem had exactly two outcomes for a code diff:
#   LIGHT  (v-classify-light-tier.sh) — build/tooling config + non-UI app config ONLY, <=4 files,
#          <=30 lines. Application code (controllers/services/models/jobs) can NEVER match: the
#          allow-list admits config/, routes/, app/Console/Kernel.php, app/{Support,Helpers}/ and
#          resources/js/{lib,utils,config,types}/ and nothing else.
#   FULL   — everything else: PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE + IMPACT_MAP + QA_REPORT
#          + gauntlet witness.
# So an ordinary 5-file service change fell off a cliff into the full 6-artifact gauntlet. CLAUDE.md
# already defines the missing middle — § Routing, "Ordinary code changes (4–10 files, no hostile
# path): targeted tests + the full suite ONCE at the end, scoped lint/typecheck, ONE adversarial
# review pass" — but nothing enforced it, so the policy was advisory and the hook was absolute.
#
# FORENSIC (2026-08-03): an ordinary content fix — no hostile path, no UI, no migration — took
# 76.5 min wall-clock, of which ~6 min was engineering. LIGHT was structurally unreachable
# (`REASON=path_class_not_light:app/Http/Controllers/ExampleController.php`), so it owed the full
# gauntlet. IMPACT_MAP cost ~4 min and returned ZERO findings (all-'no'-with-reasons, which is the
# documented correct output for an isolated change).
#
# WHAT MEDIUM WAIVES (deliberately narrow):
#   - IMPACT_MAP        — the cross-subsystem enumeration. Justified only when a diff plausibly
#                         reaches beyond its own files; an ordinary bounded change with an
#                         accompanying test does not.
#   - convergence re-gauntlet — the "run the full gauntlet ONCE more over the final tree" step in
#                         v-qa-acceptance.md § (E). Still REQUIRED if a QA iteration changed code.
# WHAT MEDIUM KEEPS (all of it):
#   PRE_FLIGHT (full suite), AGENT_REVIEW (panel: scope + correctness floor), VERIFY_DONE,
#   QA_REPORT, and the gauntlet-attest witness. QA is explicitly NOT waived — the operator's
#   instruction (2026-08-03) was to keep the QA pass and remove the NEED for repeat iterations
#   (that is W-QASCALE's measurement-validity rule), not to remove QA.
#
# MEDIUM criteria (ALL must hold):
#   1. 1..V_MEDIUM_MAX_FILES (default 10) non-test files changed — CLAUDE.md's "4–10 files".
#   2. Total changed lines across non-test files <= V_MEDIUM_MAX_LINES (default 400),
#      whitespace-insensitive, session commits + session-owned uncommitted.
#   3. An accompanying test file with real changed lines. Non-negotiable here: MEDIUM waives the
#      cross-subsystem enumeration, so the diff's own regression guard is what remains.
#   4. HARD EXCLUSIONS (over-exclusion is safe — falls back to FULL):
#        - SECURITY_PATH_PATTERN / SECURITY_CONTENT_PATTERN (hooks/lib/security-path-pattern.sh)
#        - user-facing UI (hooks/lib/ui-path-pattern.sh) — owes UX_CRITIQUE + WORKFLOW_VERIFICATION
#        - database/{migrations,seeders}/ — CLAUDE.md § Database Safety stop-list
#
# Output: MEDIUM=1|0, REASON=, and on MEDIUM=1: FILES=, TEST_FILES=, LINES=.
# Exit code: always 0 (advisory; the Stop hook keys on the MEDIUM= line).
#
# RELATIONSHIP TO LIGHT: independent and additive. This script never reads or writes LIGHT's output
# and LIGHT's contract is untouched. A diff that is LIGHT is also (trivially) MEDIUM-eligible by
# size; the Stop hook applies LIGHT first because it waives strictly more.

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
V_MEDIUM_MAX_LINES="${V_MEDIUM_MAX_LINES:-400}"
V_MEDIUM_MAX_FILES="${V_MEDIUM_MAX_FILES:-10}"

_SEC_LIB="${V_SECURITY_PATTERN_LIB:-$HOME/.claude/hooks/lib/security-path-pattern.sh}"
if [ -f "$_SEC_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_SEC_LIB"
else
  # Fail CLOSED: without the pattern lib we cannot prove the diff is security-free.
  echo "MEDIUM=0"; echo "REASON=security_pattern_lib_missing:$_SEC_LIB"; exit 0
fi

_UI_LIB="${V_UI_PATTERN_LIB:-$HOME/.claude/hooks/lib/ui-path-pattern.sh}"
if [ -f "$_UI_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_UI_LIB"
else
  echo "MEDIUM=0"; echo "REASON=ui_pattern_lib_missing:$_UI_LIB"; exit 0
fi

# ── Session-scoped changed-file set ────────────────────────────────────────────────────────
# SE-1 (2026-08-03): SINGLE-SOURCED in hooks/lib/v-diff-scope.sh. This was a byte-identical copy
# in each classifier and it DRIFTED the same day the second copy was written — W-UNTRACKED
# (brand-new files invisible to `git diff HEAD`/`--cached`) was fixed in one and not the other,
# leaving a 2-line config edit + 9 untracked services still scoring LIGHT=1. One copy is the fix.
# Fail CLOSED if the lib is unavailable: without it we cannot establish what this session changed,
# and every fallback in this file must err toward MORE files, never fewer.
_SCOPE_LIB="${V_DIFF_SCOPE_LIB:-$HOME/.claude/hooks/lib/v-diff-scope.sh}"
if [ -f "$_SCOPE_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_SCOPE_LIB"
else
  echo "MEDIUM=0"; echo "REASON=diff_scope_lib_missing:$_SCOPE_LIB"; exit 0
fi
v_diff_scope_init

[ -z "$CHANGED_FILES" ] && { echo "MEDIUM=0"; echo "REASON=no_files_changed"; exit 0; }

# ── Partition test vs non-test (anchored: a PHP test must live under tests/, per LIGHT CDX-5) ──
_TEST_RE='(^|/)tests?/|\.(test|spec)\.[jt]sx?$|/__tests__/'
TEST_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -E "$_TEST_RE" || true)
NON_TEST_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -vE "$_TEST_RE" || true)

_nt_count=$(printf '%s' "$NON_TEST_FILES" | grep -c . 2>/dev/null | head -1 | tr -d ' \n'); _nt_count=${_nt_count:-0}
_t_count=$(printf '%s' "$TEST_FILES" | grep -c . 2>/dev/null | head -1 | tr -d ' \n'); _t_count=${_t_count:-0}

[ "$_nt_count" -eq 0 ] && { echo "MEDIUM=0"; echo "REASON=test_only_diff_use_trivial_or_full"; exit 0; }
[ "$_nt_count" -gt "$V_MEDIUM_MAX_FILES" ] && { echo "MEDIUM=0"; echo "REASON=too_many_non_test_files:${_nt_count}>max=${V_MEDIUM_MAX_FILES}"; exit 0; }

# ── Hard exclusions + line tally, per non-test file ────────────────────────────────────────────
_nt_lines_total=0
_FILES_CSV=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  if is_security_bearing_path "$_f"; then
    echo "MEDIUM=0"; echo "REASON=security_path_hard_excluded:$_f"; exit 0
  fi
  if is_user_facing_ui_path "$_f"; then
    echo "MEDIUM=0"; echo "REASON=user_facing_ui_hard_excluded:$_f"; exit 0
  fi
  # W-SCHEMA-DOC (2026-08-06): the property is "can this file define or alter schema", and a bare
  # path prefix is a PROXY for it. One session made an ordinary 6-file bounded change with an
  # accompanying test, no security path and no UI, and was denied MEDIUM by ONE file:
  #   MEDIUM=0 REASON=migration_hard_excluded:database/migrations/CLAUDE.md
  # — the repo's own migration-WRITING GUIDE, edited to correct a stale prose
  # claim. Removing just that file from the diff flipped it to MEDIUM=1. Prose cannot
  # carry a schema change; the prefix could not tell prose from a migration.
  #
  # Narrowed by an explicit DOC allow-list, not by loosening the prefix. Everything else under
  # these directories — .php, .sql, .sqlite, extensionless, anything unrecognised — still
  # hard-excludes, so an unknown file type is still treated as schema-bearing. The failure
  # direction stays SAFE. Bite: skills/v/references/v-classify-schema-doc-test.sh.
  if printf '%s' "$_f" | grep -qE '^database/(migrations|seeders)/' \
     && ! printf '%s' "$_f" | grep -qiE '\.(md|txt|rst)$'; then
    echo "MEDIUM=0"; echo "REASON=migration_hard_excluded:$_f"; exit 0
  fi
  if _file_diff "$_f" | diff_has_security_content; then
    echo "MEDIUM=0"; echo "REASON=security_content_hard_excluded:$_f"; exit 0
  fi
  _fl=$(_changed_lines "$_f"); _nt_lines_total=$(( _nt_lines_total + ${_fl:-0} ))
  _FILES_CSV="${_FILES_CSV:+$_FILES_CSV,}$_f"
done <<EOF_NT
$NON_TEST_FILES
EOF_NT

if [ "$_nt_lines_total" -gt "$V_MEDIUM_MAX_LINES" ]; then
  echo "MEDIUM=0"; echo "REASON=too_many_lines:${_nt_lines_total}>max=${V_MEDIUM_MAX_LINES}"; exit 0
fi
if [ "$_nt_lines_total" -eq 0 ]; then
  echo "MEDIUM=0"; echo "REASON=no_non_test_lines_changed"; exit 0
fi

# ── Accompanying test: REQUIRED and must carry real changed lines ──────────────────────────────
if [ "$_t_count" -eq 0 ]; then
  echo "MEDIUM=0"; echo "REASON=no_accompanying_test_file"; exit 0
fi
_t_lines_total=0
while IFS= read -r _tf; do
  [ -n "$_tf" ] || continue
  # Tests are not a smuggling channel: same security-content scan as non-test files.
  if _file_diff "$_tf" | diff_has_security_content; then
    echo "MEDIUM=0"; echo "REASON=security_content_in_test_file:$_tf"; exit 0
  fi
  _tl=$(_changed_lines "$_tf"); _t_lines_total=$(( _t_lines_total + ${_tl:-0} ))
done <<EOF_T
$TEST_FILES
EOF_T
if [ "$_t_lines_total" -eq 0 ]; then
  echo "MEDIUM=0"; echo "REASON=test_file_listed_but_no_changed_lines"; exit 0
fi

echo "MEDIUM=1"
echo "REASON=medium_ordinary_code_diff"
echo "FILES=$_FILES_CSV"
echo "TEST_FILES=$(printf '%s' "$TEST_FILES" | tr '\n' ',' | sed 's/,$//')"
echo "LINES=$_nt_lines_total"
exit 0
