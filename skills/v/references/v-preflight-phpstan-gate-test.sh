#!/usr/bin/env bash
# v-preflight-phpstan-gate-test.sh — RETIRED
#
# W22-P0 (deferred-PHPStan-false-PASS guard) was removed when PHPStan was
# purged from all gates and workflows. This file is kept as a stub so that
# any harness that sources it does not fail with "file not found".
#
# The W22-P0 logic lived in validate_pre_flight_w53_contract() inside
# ~/.claude/hooks/lib/validation.sh; that block was deleted as part of the
# PHPStan removal (2026-06-08).
set -u
echo "v-preflight-phpstan-gate-test: PHPStan gate removed — test suite retired"
echo "TOTAL: 0 passed, 0 failed"
exit 0
