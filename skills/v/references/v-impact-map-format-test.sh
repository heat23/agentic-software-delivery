#!/usr/bin/env bash
# v-impact-map-format-test.sh — P2h (forensic 2026-06-17, NEW-CI-004 + NEW-UX-01).
# validate_impact_map_semantics (single-sourced; called by BOTH the Stop hook and v-completion-selfcheck.sh)
# must accept the markdown-BULLET checklist the model NATURALLY writes (`- reporting_metrics: ...`), not just
# the YAML/table forms — the prior decoration class rejected bullets, forcing a hand-patch round (`- key:` ->
# `  key:`) in BOTH those sessions. Prose mentions must still be rejected (the enumeration guarantee).
set -u
LIB="$HOME/.claude/hooks/lib/validation.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
[ -f "$LIB" ] || { echo "NO validation.sh missing"; exit 1; }
# shellcheck disable=SC1090
. "$LIB" 2>/dev/null
type validate_impact_map_semantics >/dev/null 2>&1 || { echo "NO validate_impact_map_semantics not defined after sourcing"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Build a complete IMPACT_MAP body (>=200 bytes, all 9 subsystems enumerated) parameterised on the
# per-subsystem line decoration ($2 = leading token, $3 = trailing token for the table form).
mk(){  # $1=outfile  $2=prefix  $3=suffix
  {
    printf '# Impact Map\n\nsubsystems:\n'
    for k in functional_flow reporting_metrics admin async_jobs notification_emails cache_invalidation db_integrity api_contract authorization; do
      printf '%s%s: impacted: no%s — not touched by this change; padding to clear the 200-byte minimum body size.\n' "$2" "$k" "$3"
    done
  } > "$1"
}

echo "== IMPACT_MAP subsystem-checklist format tolerance (P2h) =="

# 1. BULLET form `- key:` — the model's natural markdown, the CI-004/UX-01 drift -> VALID.
mk "$TMP/bullet.md" "- " ""
validate_impact_map_semantics "$TMP/bullet.md" >/dev/null 2>&1 \
  && ok "1 markdown-bullet '- key:' -> valid (no hand-patch needed)" || no "1 bullet form rejected"

# 2. indented YAML `  key:` — already supported -> VALID (regression).
mk "$TMP/yaml.md" "  " ""
validate_impact_map_semantics "$TMP/yaml.md" >/dev/null 2>&1 \
  && ok "2 indented '  key:' -> valid (regression)" || no "2 yaml form rejected"

# 3. table `| key |` — already supported -> VALID (regression).
mk "$TMP/table.md" "| " " |"
validate_impact_map_semantics "$TMP/table.md" >/dev/null 2>&1 \
  && ok "3 table '| key |' -> valid (regression)" || no "3 table form rejected"

# 4. prose-only (keys mentioned mid-sentence, NOT enumerated at line-start) -> INVALID.
{
  printf '# Impact Map\n\nThis change is isolated. The reporting_metrics field is unaffected, the\n'
  printf 'cache_invalidation keys are not touched, and db_integrity is preserved. Nothing else.\n'
  printf 'Padding sentence to clear the 200-byte minimum size requirement for this artifact body here.\n'
} > "$TMP/prose.md"
validate_impact_map_semantics "$TMP/prose.md" >/dev/null 2>&1 \
  && no "4 prose-only mentions wrongly accepted (enumeration guarantee broken)" || ok "4 prose-only mentions -> INVALID (enumeration guarantee preserved)"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
