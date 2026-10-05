#!/usr/bin/env bash
set -euo pipefail

SKILLS_ROOT="${CLAUDE_RUNTIME_DOCS_SKILLS_ROOT:-$HOME/.claude/skills}"
OUTPUT_ROOT="${CLAUDE_RUNTIME_DOCS_OUTPUT_ROOT:-$SKILLS_ROOT}"
SCRIPT_PATH="${CLAUDE_RUNTIME_DOCS_SCRIPT_PATH:-$HOME/.claude/scripts/generate-runtime-skill-docs.sh}"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

extract_runtime_sections() {
  local source_file="$1"

  awk '
    BEGIN { in_block = 0; block_count = 0 }
    /^<!-- runtime -->$/ {
      if (block_count > 0) {
        print ""
      }
      in_block = 1
      block_count++
      next
    }
    /^<!-- end-runtime -->$/ {
      in_block = 0
      next
    }
    in_block { print }
    END {
      if (block_count == 0) {
        exit 42
      }
    }
  ' "$source_file"
}

write_runtime_doc() {
  local source_name="$1"
  local output_name="$2"
  local title="$3"
  local source_path="$SKILLS_ROOT/$source_name"
  local output_path="$OUTPUT_ROOT/$output_name"
  local runtime_body

  [ -f "$source_path" ] || {
    echo "ERROR: runtime doc source not found: $source_path" >&2
    return 1
  }

  runtime_body="$(extract_runtime_sections "$source_path")" || {
    rc=$?
    if [ "$rc" -eq 42 ]; then
      echo "ERROR: no runtime markers found in $source_path" >&2
    fi
    return "$rc"
  }

  mkdir -p "$OUTPUT_ROOT"
  {
    echo "# AUTO-GENERATED from $source_name — do not edit directly"
    echo "# Generated: $GENERATED_AT"
    echo "# Source:    $source_path"
    echo "# To update: bash $SCRIPT_PATH"
    echo
    echo "# $title"
    echo
    printf '%s\n' "$runtime_body"
  } > "$output_path"
}

write_runtime_doc "_v-core.md" "_v-core-runtime.md" "V Core Runtime"
write_runtime_doc "_v-review.md" "_v-review-runtime.md" "V Review Runtime"
