#!/usr/bin/env bash
# lib/ui-path-pattern.sh
# Shared definitions for "user-facing UI file" detection.
# Version: 1.1.0  (W49 review-fix M1 — extract from W48-F1 to avoid duplication;
#                  1.1.0 adds the content-embedded-asset exemption, W-content-ui-fp)
#
# Two consumers today:
#   - v/references/v-classify-trivial.sh (W48-F1: blocks UI from TRIVIAL fast-path)
#   - hooks/check-review-artifact.sh (W49-F1: gates UX_CRITIQUE artifact requirement)
#
# Add new consumers here, not by re-encoding the regex.

# UI_PATH_PATTERN — files that indicate user-facing UI changes.
# Coverage matches /v SKILL.md Step 3.5 UI_FILES glob (W48-F1 review-fix C2):
#   - Component/page extensions: .tsx .jsx .vue .svelte
#   - Stylesheets: .css .scss .sass
#   - Markup: .html .blade.php
#   - Tailwind config (affects every UI surface)
#   - Common project layouts: resources/{css,styles,views}/
#
# INTENTIONALLY EXCLUDED: resources/js/ directory without extension filter.
# Plain .ts files in resources/js/lib/, resources/js/types/, etc. are TypeScript
# utilities/constants — NOT user-facing UI. They are caught only when they have
# a UI extension (.tsx/.jsx). Adding `js` to the directory catch caused every
# session touching a constants .ts file or types/index.ts to require UX_CRITIQUE
# and WORKFLOW_VERIFICATION, which the orchestrator never dispatches for .ts files
# (SKILL.md Step 3.5 uses *.tsx *.jsx *.css *.html *.vue *.svelte globs only).
# The mismatch made those sessions permanently unresolvable (W-ui-ts-fp fix).
export UI_PATH_PATTERN='\.(tsx|jsx|css|scss|sass|vue|svelte)$|\.blade\.php$|(^|/)resources/(css|styles|views)/|(^|/)tailwind\.config\.'

# TEST_OR_CONFIG_PATTERN — files that LOOK like UI but are dev-only.
# A 1-line storybook tweak doesn't warrant the full UX critique gauntlet.
# W56-F1.1: widen exemption to common test/spec directory conventions.
# Catches: tests/, test/, __tests__/, __test__/, specs/, spec/, __specs__/, __spec__/.
# Cypress/Playwright config files surface via .config.* matcher.
export TEST_OR_CONFIG_PATTERN='\.(test|spec|stories)\.[jt]sx?$|/__snapshots__/|(^|/)__?tests?__?/|(^|/)__?specs?__?/|(^|/)(jest|vitest|playwright|cypress)\.config\.|(^|/)tests?/|(^|/)specs?/'

# CONTENT_ASSET_PATTERN — content-embedded interactive components (W-content-ui-fp).
# Content-generating skills (v-content-create Mode 1 Step 15; the blog storage policy in
# ~/.claude/skills/references/v-core-blog-storage.md applies to v-content-create,
# v-interactive-showcase, v-scaffold, v-build) write React components into the article's
# slug directory alongside the .md article:
#   blog/<slug>/interactive-calculator.tsx
#   content/blog/<slug>/interactive-quiz.jsx
#   resources/content/<slug>/interactive-widget.tsx
# These are ARTICLE ASSETS, not application UI. The UX_CRITIQUE / WORKFLOW_VERIFICATION
# gates (W49) are application-workflow machinery a content-drafting session has no steps
# to satisfy — its quality gates are the content-quality gates, output grading, and
# critic dispatch. Extension-only matching classified these assets as UI and
# dead-ended pure-content sessions on gates that could never be met.
# SAFE-DIRECTION scoping (same lesson as the W-ui-ts-fp note above):
#   - Only .tsx/.jsx files DIRECTLY inside a slug dir under a recognized content root
#     (blog/, content/, content/blog/, resources/content/) are exempt.
#   - CONTENT_ASSET_EXCLUDE keeps anything under an app-source root in the UI gate even
#     when it path-matches: resources/js/pages/blog/<slug>/Show.tsx is REAL application
#     UI and still fires the gate. Ambiguity resolves toward over-triggering (safe).
export CONTENT_ASSET_PATTERN='(^|/)(content/blog|content|blog|resources/content)/[^/]+/[^/]+\.(tsx|jsx)$'
export CONTENT_ASSET_EXCLUDE='(^|/)(resources/js|resources/ts|src|app|pages|components|layouts)/'

# is_content_embedded_asset <path>
# Returns 0 (true) if the path is a content-embedded article asset (exempt from UI
# gating). Returns 1 otherwise. App-source roots always win over the content match.
is_content_embedded_asset() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  echo "$p" | grep -qE -- "$CONTENT_ASSET_PATTERN" || return 1
  if echo "$p" | grep -qE -- "$CONTENT_ASSET_EXCLUDE"; then
    return 1
  fi
  return 0
}

# is_user_facing_ui_path <path>
# Returns 0 (true) if the path matches UI_PATH_PATTERN AND does NOT match
# the test/config exemption AND is not a content-embedded article asset.
# Returns 1 otherwise.
is_user_facing_ui_path() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  if echo "$p" | grep -qE -- "$UI_PATH_PATTERN"; then
    if ! echo "$p" | grep -qE -- "$TEST_OR_CONFIG_PATTERN"; then
      if ! is_content_embedded_asset "$p"; then
        return 0
      fi
    fi
  fi
  return 1
}

# any_user_facing_ui <newline-separated paths>
# Returns 0 if at least one path matches user-facing UI criteria.
# Returns 1 if no paths match or input is empty.
any_user_facing_ui() {
  local input="${1:-}"
  [ -n "$input" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if is_user_facing_ui_path "$p"; then
      return 0
    fi
  done <<< "$input"
  return 1
}
