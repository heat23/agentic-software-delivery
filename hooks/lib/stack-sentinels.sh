#!/usr/bin/env bash
# stack-sentinels.sh — THE single source of truth for the "does this tree carry a
# gate-bearing stack?" sentinel list (F7, 2026-08-29).
#
# WHY THIS FILE EXISTS
# The 15-sentinel list was previously inlined in v-gauntlet-attest.sh's W-NOGATE
# block ONLY. F7 needs the identical decision BEFORE a v-pre-flight-runner dispatch
# (a stackless tree spawned a subagent purely to learn there was nothing to run —
# 18 such dispatches produced 32 per-gate logs with zero tool output, largest 135B).
# Copying the list to the new caller would have recreated exactly the drift defect
# F1 exists to catch, so the list lives here and BOTH callers consume it.
#
# CONSUMERS (keep this list current — a new consumer must source, never re-list):
#   - skills/v/references/v-gauntlet-attest.sh  (W-NOGATE staleness exemption)
#   - skills/v/references/v-emit-prompt.sh      (F7 pre-dispatch stack gate)
#   - skills/v/references/v-gauntlet-attest-source-staleness-test.sh (F1 parity check)
#
# CONTRACT
#   stack_sentinel_list                     -> prints one sentinel per line, rc 0
#   stack_has_gate_bearing_stack <root>...  -> rc 0 if ANY sentinel exists under ANY
#                                              root; rc 1 if none do. Empty/unset
#                                              roots are skipped, not an error.
#
# FAIL-CLOSED POSTURE FOR CALLERS: rc 1 ("no stack") is the value that unlocks work
# avoidance, so a caller that cannot source this file must behave as if a stack IS
# present (do the expensive/safe thing). Never treat a sourcing failure as "no stack".
#
# bash 3.2 compatible (no arrays, no mapfile). Pure string test — never executes,
# stats only, so it is safe to call from a hook.

# SENTINEL -> GATE MAPPING (moved here from v-gauntlet-attest.sh, F7 close-out 2026-08-29 — it
# belongs with the list it describes, so the two cannot drift):
#   package.json .................. LINT, BUILD, VITEST   (v-run-gates.sh `[ -f "package.json" ]`)
#   tsconfig{,.base,.app}.json .... TSC      (its 3-config loop — .base/.app are Nx/Angular/Vite)
#   node_modules/.bin/tsc ......... TSC      (no-tsconfig fallback: `[ -x node_modules/.bin/tsc ]`)
#   composer.json ................. PEST     (together with vendor/bin/pest|phpunit)
#   composer.lock ................. COMPOSER_AUDIT
#   vendor/bin/{pest,phpunit} ..... PEST
#   vendor/bin/phpstan ............ PHPSTAN  (phpstan.neon* are AND-gated behind this binary, so
#                                             they need no sentinel of their own)
#   package-lock/yarn/pnpm/bun .... NPM_AUDIT (guarded on a CHANGED LOCKFILE with no package.json
#                                             check at all — so lockfiles are their own trigger)
# Parity with v-run-gates.sh is asserted from SOURCE by
# v-gauntlet-attest-source-staleness-test.sh case B4 via v-run-gates-triggers.sh.

# The list is newline-separated and consumed via deliberate word-splitting, which is
# safe because every entry is a fixed literal with no whitespace or glob character.
# Order is documentation-only; the predicate is a pure OR.
_STACK_SENTINELS="package.json composer.json composer.lock
tsconfig.json tsconfig.base.json tsconfig.app.json node_modules/.bin/tsc
package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock
vendor/bin/pest vendor/bin/phpunit vendor/bin/phpstan"

# IFS HARDENING (adversarial review PANEL-SECURITY-004, 2026-08-29). Both functions below rely on
# word-splitting the list. The original justification — "safe because every entry is a fixed literal
# with no whitespace or glob character" — reasoned only about the string's CONTENT and ignored
# ambient $IFS, which the caller controls. With `IFS=''` exported, the whole 15-line string collapses
# into ONE word, `[ -e "$root/<the entire list>" ]` is false for every root, and the predicate
# reports "no stack" on a tree that visibly contains package.json. That fails OPEN in the direction
# that matters: it hands v-gauntlet-attest.sh's W-NOGATE the staleness exemption for a repo whose
# gates really run. Reset IFS locally in each function so the split cannot be steered from outside.
# `local IFS=...` restores the caller's value on return (bash 3.2 compatible).
stack_sentinel_list() {
  local IFS=$' \t\n'
  # shellcheck disable=SC2086  # intentional word-split of a literal-only list, with IFS pinned above
  printf '%s\n' $_STACK_SENTINELS
}

stack_has_gate_bearing_stack() {
  local _sent _root
  local IFS=$' \t\n'
  # shellcheck disable=SC2086
  for _sent in $_STACK_SENTINELS; do
    for _root in "$@"; do
      [ -n "$_root" ] || continue
      [ -e "$_root/$_sent" ] && return 0
    done
  done
  return 1
}
