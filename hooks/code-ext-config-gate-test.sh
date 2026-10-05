#!/usr/bin/env bash
# code-ext-config-gate-test.sh — ORCHFIX-C class harness (forensics 2026-07-02).
# CLASS: executable-config-invisible-to-gates + gate-pattern drift between consumers.
# RED oracle: hooks/check-review-artifact.sh.pre-orchfix0702-bak (pattern lacks yml/yaml/json) and
# hooks/enforce-pre-commit-gates.sh.pre-orchfix0702-bak (10-extension drifted copy).
set -uo pipefail
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }

LIB="$HOME/.claude/hooks/lib/code-ext-pattern.sh"
[ -f "$LIB" ] || { echo "  NO  shared lib missing"; exit 1; }
# shellcheck source=lib/code-ext-pattern.sh
source "$LIB"

m(){ printf '%s\n' "$1" | grep -E "$CODE_EXT_PATTERN" | grep -vqE "$CODE_EXT_EXEMPT"; }

# Behavior: executable config now counts as code.
m ".github/workflows/phpstan-ratchet.yml" && ok "workflows yml -> code (the originally-missed file)" || no "workflows yml missed"
m "config/app.yaml"        && ok "yaml -> code"        || no "yaml missed"
m "phpstan.neon"           && ok "neon -> code"        || no "neon missed"
m "package.json"           && ok "json -> code"        || no "json missed"
m "composer.lock"          && ok "lockfile -> code"    || no "lockfile missed"
m ".husky/pre-commit"      && ok "extensionless .husky hook -> code" || no ".husky missed"
m "docker/Dockerfile.prod" && ok "Dockerfile -> code"  || no "Dockerfile missed"
m "app/Services/X.php"     && ok "php still code"      || no "php regressed"
# Exemptions: the orchestrator's own telemetry must NOT classify as code.
m "SESSION_LOG_1234abcd-0000-4000-8000-000000000000.yaml" && no "SESSION_LOG yaml wrongly counts as code" || ok "SESSION_LOG yaml exempt"
m ".v/artifacts/OP_TELEMETRY_x.json" && no ".v path wrongly counts" || ok ".v/ exempt"
m "OP_TELEMETRY_1234abcd-0000-4000-8000-000000000000.json" && no "OP_TELEMETRY wrongly counts" || ok "OP_TELEMETRY exempt"
m "ANALYTICS_AUDIT_20260101_000000_deadbeef.json" && no "audit-report JSON wrongly counts as code" || ok "UPPER_SNAKE_(AUDIT|REPORT) json exempt"
m ".v/analytics-qa-taxonomy.json" && no ".v/ audit scratch wrongly counts" || ok ".v/ audit scratch exempt"
m "analytics-qa-taxonomy.json" && ok "root-level qa scratch still counts as code (scratch belongs under .v/)" || no "root qa scratch regressed to exempt"
# .audit<N>/ (2026-09-08): per-dimension audit scratch. The exemption is
# deliberately SHAPE-BOUND — leading dot, "audit", digits only, then a slash — so it covers the
# dirs already written (.audit3/, .audit4/) without re-opening root-level scratch above.
m ".audit4/dim7.json"             && no ".audit<N>/ scratch wrongly counts as code" || ok ".audit<N>/ scratch exempt"
m "docs/site/.audit4/dim9.json" && no "nested .audit<N>/ scratch wrongly counts"  || ok "nested .audit<N>/ scratch exempt"
m ".audit/consolidated.json"      && no ".audit/ (no digits) wrongly counts"        || ok ".audit/ (no digits) exempt"
m "audit4/dim7.json"  && ok "dotless audit4/ still counts as code (not the scratch convention)" || no "dotless audit4/ regressed to exempt"
m ".audits/app.php"   && ok ".audits/ still counts as code (not the scratch convention)"        || no ".audits/ wrongly exempted"
m "README.md" && no "md wrongly counts as code" || ok "md not code"
# Per-line safety: a writes-log containing an audit-report json AND real source must still trip on the source.
printf 'ADMIN_AUDIT_REPORT_2026-07-05_1200_sid.json\napp/Http/UserController.php\n' | grep -E "$CODE_EXT_PATTERN" | grep -vqE "$CODE_EXT_EXEMPT" \
  && ok "mixed writes-log still trips on real source" || no "audit-json exemption swallowed a real source change"
# .seo/ is deliberately NOT exempt (2026-10-01 review panel): its CSV/MD data never
# matched CODE_EXT_PATTERN, so an exemption would only have exempted scripts placed there.
m "site/.seo/build_page_tables.py"       && ok ".seo/ scripts still count as code (no .seo/ exemption)" || no ".seo/ scripts wrongly exempted"
m "site/.seo/search-export-queries.csv" && no ".seo/ csv data wrongly counts as code" || ok ".seo/ csv data is not code (needs no exemption)"
# Fallback parity: every lib-missing fallback copy of CODE_EXT_EXEMPT must equal the shared lib's value,
# so an exemption added in one place cannot silently diverge from the copies used when the lib is absent.
_canon=$(grep -E "^CODE_EXT_EXEMPT=" "$LIB" | head -1 | sed -E 's/^CODE_EXT_EXEMPT=//')
for f in "$HOME/.claude/hooks/check-review-artifact.sh" "$HOME/.claude/hooks/enforce-pre-commit-gates.sh" \
         "$HOME/.claude/hooks/stop-completion-check.sh" "$HOME/.claude/hooks/lib/validation.sh" \
         "$HOME/.claude/hooks/session-start-head-baseline-test.sh"; do
  _copy=$(grep -E "^[[:space:]]*CODE_EXT_EXEMPT='" "$f" | head -1 | sed -E 's/^[[:space:]]*CODE_EXT_EXEMPT=//')
  [ -n "$_copy" ] && [ "$_copy" = "$_canon" ] && ok "$(basename "$f") CODE_EXT_EXEMPT copy matches the shared lib" \
                                             || no "$(basename "$f") CODE_EXT_EXEMPT copy drifted from the shared lib"
done

# Parity: ALL pattern consumers must SOURCE the shared lib (no inline drift).
# ND-0716: stop-completion-check.sh added — it carried its own stale private copy
# (no .sh/.sql/.yml/.json, no Dockerfile/workflows), the THIRD recurrence of the
# ORCHFIX-C duplicated-detector class; advisory-only but its "code not changed"
# signal lied on config/schema-only diffs.
for f in "$HOME/.claude/hooks/check-review-artifact.sh" "$HOME/.claude/hooks/enforce-pre-commit-gates.sh" "$HOME/.claude/hooks/stop-completion-check.sh"; do
  grep -q 'code-ext-pattern.sh' "$f" && ok "$(basename "$f") sources the shared lib" \
                                     || no "$(basename "$f") does NOT source the shared lib (drift door reopened)"
done
# ND-0716: no consumer may re-declare a PRIVATE inline pattern outside the documented
# lib-missing fallback (which must carry the canonical value — spot-checked via yml coverage).
for f in "$HOME/.claude/hooks/stop-completion-check.sh"; do
  _decl=$(grep -E "^CODE_EXT_PATTERN=" "$f" || true)
  if [ -z "$_decl" ] || printf '%s' "$_decl" | grep -q 'yml'; then
    ok "$(basename "$f") has no stale private pattern (absent or canonical-valued fallback)"
  else
    no "$(basename "$f") re-declares a STALE private CODE_EXT_PATTERN: $_decl"
  fi
done
# Consumers must pair pattern with exemption (a lone pattern grep re-opens the telemetry false-positive).
n_pat=$(grep -c 'grep -E "\$CODE_EXT_PATTERN"' "$HOME/.claude/hooks/check-review-artifact.sh" || true)
n_ex=$(grep -c 'CODE_EXT_EXEMPT' "$HOME/.claude/hooks/check-review-artifact.sh" || true)
[ "${n_ex:-0}" -ge "${n_pat:-0}" ] && ok "every Stop-gate pattern grep is exemption-paired ($n_pat/$n_ex)" \
                                   || no "unpaired CODE_EXT_PATTERN grep in Stop gate ($n_pat pattern vs $n_ex exempt)"

# RED oracle: both backups lack yml coverage (the hole this closes).
for b in "$HOME/.claude/hooks/check-review-artifact.sh.pre-orchfix0702-bak" \
         "$HOME/.claude/hooks/enforce-pre-commit-gates.sh.pre-orchfix0702-bak"; do
  if [ -f "$b" ]; then
    grep -E "^CODE_EXT_PATTERN=" "$b" | grep -q 'yml' \
      && no "RED oracle: backup $(basename "$b") already had yml?!" \
      || ok "RED oracle: $(basename "$b") pattern lacks yml (pre-fix hole confirmed)"
  fi
done

echo; echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
