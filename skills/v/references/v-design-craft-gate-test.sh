#!/usr/bin/env bash
# v-design-craft-gate-test.sh
# Contract harness: /v Step 3.5 Design Craft Gate (v-ui-change-detection.md)
# must be anchored to the shared prescriptive design system (2026-07 design
# migration) — conformance critique against design-system-spec.md — and must
# not regress to the legacy per-project model (swap/signature tests, critique
# gated on .interface-design/system.md existing as the authority).
set -u
DOC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-ui-change-detection.md"
FAIL=0

must_contain() {
  if grep -qF "$1" "$DOC"; then echo "PASS: contains: $1"; else echo "FAIL: missing: $1"; FAIL=1; fi
}
must_not_contain() {
  if grep -qF "$1" "$DOC"; then echo "FAIL: stale legacy content present: $1"; FAIL=1; else echo "PASS: absent: $1"; fi
}

must_contain "design-system-spec.md"
must_contain "conformance critique"
must_not_contain "swap/squint/signature tests"
must_not_contain "rely on \`_v-design.md\` token governance"

exit $FAIL
