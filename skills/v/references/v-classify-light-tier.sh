#!/usr/bin/env bash
# v-classify-light-tier.sh
# Version: 1.0.0  (P1-B — light-gauntlet tier classifier, 2026-07-03)
#
# Classifies whether the current session's diff qualifies for the LIGHT GAUNTLET tier — the
# middle tier between TRIVIAL_PASS (≤3-line docs/css) and the full gauntlet. Production
# motivation: 178 turns for a 3-line onOneServer() schedule guard; the
# remediation-heavy full gauntlet is pure waste for a tiny config/guard diff that ships WITH
# a real test. Light tier = scoped pre-flight + ONE reviewer; SKIPS verify-done and the QA
# acceptance loop (and UX/workflow-verification never activate — the allowed path classes
# exclude UI). Enforcement: hooks/check-review-artifact.sh re-runs THIS classifier at Stop
# time (P1B-LIGHT-TIER) — the verdict is DIFF-SHAPE-DERIVED, never model-asserted, and the
# QA exemption applies ONLY when no QA_REPORT exists (a real QA fail always blocks).
#
# W-LIGHT2 (2026-08-03) — REACHABILITY + DEPTH. Two structural problems made this tier useless
# in practice, so every small change took the full 6-artifact gauntlet anyway:
#   (a) UNREACHABLE — the allowed-path list admitted four PHP/env shapes only, so no .ts/.tsx or
#       build-config diff could EVER match. In a Laravel+React repo that is most small changes.
#       Observed: a 14-line SSR-enablement diff (vite.config.ts + package.json + a 1-line import
#       swap) owed PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE + IMPACT_MAP + QA_REPORT + witness.
#   (b) SHALLOW — even when it fired it waived QA_REPORT alone. It now additionally waives
#       VERIFY_DONE, IMPACT_MAP and the gauntlet witness, leaving PRE_FLIGHT (scoped) + ONE
#       review: CLAUDE.md § "Small/trivial exception" verbatim.
#
# LIGHT criteria (ALL must hold):
#   1. ≥1 and ≤ V_LIGHT_MAX_FILES (default 4) non-test files changed; every one inside an allowed
#      path class — TOOLING (build/tooling config, any stack) or APPCFG (app config + non-UI
#      support code). See _TOOLING_RE / _APPCFG_RE below for the exact sets.
#      (UI, migrations/seeders, controllers/services/jobs/models, docs are NOT light.)
#   2. Total changed lines across non-test files ≤ V_LIGHT_MAX_LINES (default 30 — CLAUDE.md's
#      stated "≤~30 lines excluding tests"; whitespace-insensitive, committed session range +
#      uncommitted summed — same A4 machinery as v-classify-trivial.sh).
#   3. Accompanying test — CONDITIONAL on V_LIGHT_REQUIRE_TEST (auto|1|0, default auto). Under
#      `auto`, required iff any non-test file is APPCFG; an all-TOOLING diff is exempt because
#      it has no unit-test surface. PRE_FLIGHT still runs the suite regardless.
#   4. HARD SECURITY EXCLUSION (over-exclusion is safe — falls back to the full gauntlet):
#      no non-test file path matches SECURITY_PATH_PATTERN, and no added/removed diff line in
#      a non-test file matches SECURITY_CONTENT_PATTERN (hooks/lib/security-path-pattern.sh —
#      the single-sourced signing/HMAC/webhook/credential/host-construction/auth/payment list
#      from v-runnable-pack-convention.md § Security-bearing packs). The over-gating paradox
#      is real: only full-gauntlet sessions caught real security and exception-handling bugs. A
#      3-line change to a signing path takes the FULL gauntlet, period.
#
# Output: LIGHT=1|0, REASON=, and on LIGHT=1: FILES=, TEST_FILES=, LINES=.
# Exit code: always 0 (advisory; the Stop hook keys on the LIGHT= line).

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
# W-LIGHT2 (2026-08-03): caps raised to CLAUDE.md § "Small/trivial exception" (≤~30 lines
# excluding tests). Was 10 lines / 2 files — combined with the PHP-only path list below that
# made this tier effectively unreachable, so every small diff took the full 6-artifact gauntlet.
V_LIGHT_MAX_LINES="${V_LIGHT_MAX_LINES:-30}"
V_LIGHT_MAX_FILES="${V_LIGHT_MAX_FILES:-4}"

_SEC_LIB="${V_SECURITY_PATTERN_LIB:-$HOME/.claude/hooks/lib/security-path-pattern.sh}"
if [ -f "$_SEC_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_SEC_LIB"
else
  # Fail CLOSED: without the pattern lib we cannot prove the diff is security-free.
  echo "LIGHT=0"
  echo "REASON=security_pattern_lib_missing:$_SEC_LIB"
  exit 0
fi

# W-LIGHT2: the widened path list below reaches resources/js/**, which the old PHP-only list
# never could — so the UI exclusion that used to come for free must now be EXPLICIT. UI carries
# its own UX_CRITIQUE + WORKFLOW_VERIFICATION gates that this tier skips. Fail CLOSED, as above.
_UI_LIB="${V_UI_PATTERN_LIB:-$HOME/.claude/hooks/lib/ui-path-pattern.sh}"
if [ -f "$_UI_LIB" ]; then
  # shellcheck source=/dev/null
  source "$_UI_LIB"
else
  echo "LIGHT=0"
  echo "REASON=ui_pattern_lib_missing:$_UI_LIB"
  exit 0
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
  echo "LIGHT=0"; echo "REASON=diff_scope_lib_missing:$_SCOPE_LIB"; exit 0
fi
v_diff_scope_init

[ -z "$CHANGED_FILES" ] && { echo "LIGHT=0"; echo "REASON=no_files_changed"; exit 0; }

# ── Partition test vs non-test ─────────────────────────────────────────────────────────────
# Review L#6/CDX-5: `Test\.php$` was UNANCHORED — app/Console/Commands/PaymentGatewayTest.php (a
# plausible production command name) classified as "the accompanying test" and escaped every rule.
# PHP test files must live under a tests/ (or __tests__/) directory to count.
_TEST_RE='(^|/)tests?/|\.(test|spec)\.[jt]sx?$|/__tests__/'
TEST_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -E "$_TEST_RE" || true)
NON_TEST_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -vE "$_TEST_RE" || true)

_nt_count=$(printf '%s' "$NON_TEST_FILES" | grep -c . 2>/dev/null | head -1 | tr -d ' \n'); _nt_count=${_nt_count:-0}
_t_count=$(printf '%s' "$TEST_FILES" | grep -c . 2>/dev/null | head -1 | tr -d ' \n'); _t_count=${_t_count:-0}

[ "$_nt_count" -eq 0 ] && { echo "LIGHT=0"; echo "REASON=test_only_diff_use_trivial_or_full"; exit 0; }
[ "$_nt_count" -gt "$V_LIGHT_MAX_FILES" ] && { echo "LIGHT=0"; echo "REASON=too_many_non_test_files:${_nt_count}>max=${V_LIGHT_MAX_FILES}"; exit 0; }
# NB (W-LIGHT2): the unconditional `_t_count -eq 0 → LIGHT=0` check used to sit HERE. It now runs
# AFTER path classification, because whether a test is required depends on the path class — see
# "Rule 3 (conditional)" below. Ordering is load-bearing, not cosmetic.

# ── Rules 1+2+4 per non-test file ───────────────────────────────────────────────────────────
# Review L#5/CDX-10: `^app/Console/` (unanchored) admitted every Artisan command's full handle()
# body — arbitrary application logic, not "guard diffs". Narrowed to Kernel.php (schedule wiring
# only, the onOneServer() motivating shape); routes/console.php is already covered by the routes
# arm. Command-class changes take the full gauntlet.
#
# W-LIGHT2 (2026-08-03): split into TWO allowed classes. This stays an ALLOW-list on purpose —
# a deny-list fails OPEN (any unlisted new path class silently becomes light), an allow-list
# fails SAFE (anything unrecognised falls back to the full gauntlet). The classes differ in
# exactly one respect: whether a test can meaningfully exist for the file.
#
#   TOOLING — build/tooling config, any stack. NO unit-test surface: there is no test to write
#             for a vite.config.ts SSR flag or a dependency bump, and demanding one was the
#             second reason (after the PHP-only path list) this tier never fired in practice.
#   APPCFG  — app config + non-UI support code. HAS a test surface, so `auto` keeps requiring one.
_TOOLING_RE='(^|/)(vite|vitest|playwright|tailwind|postcss|eslint|jest|rollup|webpack|svelte|nuxt|next|astro|babel|prettier|commitlint|lint-staged|knip|vercel|netlify)\.config\.[cm]?[jt]s$|(^|/)tsconfig([.-][A-Za-z0-9_-]+)?\.json$|(^|/)(package|composer)\.json$|(^|/)(phpunit\.xml(\.dist)?|phpstan\.neon(\.dist)?|psalm\.xml|pint\.json|rector\.php|\.php-cs-fixer(\.dist)?\.php)$|(^|/)\.(editorconfig|gitignore|gitattributes|npmrc|nvmrc|prettierrc|prettierignore|eslintignore|dockerignore)$|(^|/)\.eslintrc(\.[a-z]+)?$|(^|/)\.prettierrc\.[a-z]+$|^\.env\.example$'
_APPCFG_RE='^config/.+\.php$|^routes/.+\.php$|^app/Console/Kernel\.php$|^app/(Support|Helpers)/.+\.php$|^resources/js/(lib|utils|config|types)/.+\.[cm]?tsx?$'
_nt_lines_total=0
_FILES_CSV=""
_has_appcfg=0
_has_tooling=0
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  # Rule 4a: security-shaped path → full gauntlet, regardless of size.
  if is_security_bearing_path "$_f"; then
    echo "LIGHT=0"; echo "REASON=security_path_hard_excluded:$_f"; exit 0
  fi
  # Rule 4a' (W-LIGHT2): user-facing UI → full gauntlet. The old PHP-only allow-list made this
  # unreachable; the widened one reaches resources/js/**, so state it. UI owes UX_CRITIQUE +
  # WORKFLOW_VERIFICATION, which this tier waives — a light UI change would skip both silently.
  if is_user_facing_ui_path "$_f"; then
    echo "LIGHT=0"; echo "REASON=user_facing_ui_hard_excluded:$_f"; exit 0
  fi
  # Rule 4a'' (W-LIGHT2): schema changes are never light (CLAUDE.md § Database Safety stop-list).
  # W-SCHEMA-DOC (2026-08-06): documentation under these directories cannot define or alter schema.
  # Kept byte-identical to the same predicate in v-classify-medium-tier.sh ON PURPOSE — that file's
  # SE-1 comment records the last duplicated block across these two classifiers drifting the SAME
  # DAY the second copy was written, so v-classify-schema-doc-test.sh asserts BOTH carry the
  # carve-out. Allow-list, not a looser prefix: unknown extensions still hard-exclude.
  if printf '%s' "$_f" | grep -qE '^database/(migrations|seeders)/' \
     && ! printf '%s' "$_f" | grep -qiE '\.(md|txt|rst)$'; then
    echo "LIGHT=0"; echo "REASON=migration_hard_excluded:$_f"; exit 0
  fi
  # Rule 1: allowed path class only — and remember WHICH class, for Rule 3 below.
  if printf '%s' "$_f" | grep -qE "$_TOOLING_RE"; then
    _has_tooling=1
  elif printf '%s' "$_f" | grep -qE "$_APPCFG_RE"; then
    _has_appcfg=1
  else
    echo "LIGHT=0"; echo "REASON=path_class_not_light:$_f"; exit 0
  fi
  # Rule 4b: security-shaped diff CONTENT → full gauntlet (a signing helper in an innocent path).
  if _file_diff "$_f" | diff_has_security_content; then
    echo "LIGHT=0"; echo "REASON=security_content_hard_excluded:$_f"; exit 0
  fi
  _fl=$(_changed_lines "$_f"); _nt_lines_total=$(( _nt_lines_total + ${_fl:-0} ))
  _FILES_CSV="${_FILES_CSV:+$_FILES_CSV,}$_f"
done <<EOF_NT
$NON_TEST_FILES
EOF_NT

if [ "$_nt_lines_total" -gt "$V_LIGHT_MAX_LINES" ]; then
  echo "LIGHT=0"; echo "REASON=too_many_lines:${_nt_lines_total}>max=${V_LIGHT_MAX_LINES}"; exit 0
fi
if [ "$_nt_lines_total" -eq 0 ]; then
  echo "LIGHT=0"; echo "REASON=no_non_test_lines_changed"; exit 0
fi

# ── Rule 3 (conditional, W-LIGHT2): accompanying test ───────────────────────────────────────
# V_LIGHT_REQUIRE_TEST: auto (default) | 1 | 0.
#   auto → required iff the diff touches an APPCFG file. An all-TOOLING diff is exempt: there is
#          nothing to unit-test in a config flag or a dep bump. PRE_FLIGHT still runs the suite,
#          so the tests remain the authoritative gate either way — this waives the requirement to
#          WRITE one, never the requirement to PASS them.
#   1    → always required (the pre-W-LIGHT2 behaviour).
#   0    → never required.
_require_test="${V_LIGHT_REQUIRE_TEST:-auto}"
case "$_require_test" in
  auto) _need_test="$_has_appcfg" ;;
  1)    _need_test=1 ;;
  0)    _need_test=0 ;;
  *)    echo "LIGHT=0"; echo "REASON=invalid_V_LIGHT_REQUIRE_TEST:$_require_test"; exit 0 ;;
esac

if [ "$_need_test" -eq 1 ] && [ "$_t_count" -eq 0 ]; then
  echo "LIGHT=0"; echo "REASON=no_accompanying_test_file_for_appcfg_change"; exit 0
fi

# Test files are NOT a smuggling channel (review CDX-5): whenever any are present they get the
# SAME security content scan (over-exclusion is safe), a count cap, and a line cap — regardless
# of whether they were REQUIRED. A "light" diff whose tests dwarf those caps is not light.
if [ "$_t_count" -gt 0 ]; then
  [ "$_t_count" -gt "${V_LIGHT_MAX_TEST_FILES:-3}" ] && { echo "LIGHT=0"; echo "REASON=too_many_test_files:$_t_count"; exit 0; }
  _t_lines_total=0
  while IFS= read -r _tf; do
    [ -n "$_tf" ] || continue
    if _file_diff "$_tf" | diff_has_security_content; then
      echo "LIGHT=0"; echo "REASON=security_content_in_test_file:$_tf"; exit 0
    fi
    _tl=$(_changed_lines "$_tf"); _t_lines_total=$(( _t_lines_total + ${_tl:-0} ))
  done <<EOF_T
$TEST_FILES
EOF_T
  # A REQUIRED test must carry real changed lines; an unrequired one may be listed-but-untouched.
  if [ "$_need_test" -eq 1 ] && [ "$_t_lines_total" -eq 0 ]; then
    echo "LIGHT=0"; echo "REASON=test_file_listed_but_no_changed_lines"; exit 0
  fi
  [ "$_t_lines_total" -gt "${V_LIGHT_MAX_TEST_LINES:-200}" ] && { echo "LIGHT=0"; echo "REASON=test_lines_exceed_cap:${_t_lines_total}>${V_LIGHT_MAX_TEST_LINES:-200}"; exit 0; }
fi

_class="mixed"
[ "$_has_appcfg" -eq 0 ] && _class="tooling"
[ "$_has_tooling" -eq 0 ] && _class="appcfg"

echo "LIGHT=1"
echo "REASON=light_${_class}_diff"
echo "CLASS=$_class"
echo "FILES=$_FILES_CSV"
echo "TEST_FILES=$(printf '%s' "$TEST_FILES" | tr '\n' ',' | sed 's/,$//')"
echo "LINES=$_nt_lines_total"
exit 0
