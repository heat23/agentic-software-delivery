#!/usr/bin/env bash
# v-run-gates-triggers.sh — extract v-run-gates.sh's FILE TRIGGERS from source (F1, 2026-08-29).
#
# WHY: the W-NOGATE staleness exemption in v-gauntlet-attest.sh is granted when a tree carries none
# of the 15 sentinels in hooks/lib/stack-sentinels.sh. That is only sound while the sentinel list
# covers every file that would actually make v-run-gates.sh RUN a gate. The parity test that was
# supposed to guard this iterated a HARDCODED list and never read v-run-gates.sh, so it was
# one-directional: it caught a DELETED sentinel, but a NEW trigger added to v-run-gates.sh passed
# silently — the unsafe direction (exemption granted to a repo whose gate really runs).
#
# This script supplies the missing side: the triggers, derived from source.
#
# v-run-gates.sh expresses a file trigger in THREE syntactic forms. All three are extracted —
# handling only the obvious one would miss the npm-audit lockfiles entirely (they are a regex, not
# a -f test) and would reproduce the very blind spot this exists to close:
#   (1) literal test    :  [ -f "package.json" ]   [ -x "./vendor/bin/pest" ]
#   (2) config for-loop :  for _tsc_cfg in tsconfig.json tsconfig.base.json ...; do [ -f "$_tsc_cfg" ]
#   (3) changed-file rx :  _changed_matches '(^|/)(package-lock\.json|yarn\.lock|bun\.lockb?)$'
#
# Usage:  bash v-run-gates-triggers.sh [path-to-v-run-gates.sh]
# Output: one trigger path per line, sorted, unique, './' stripped.
# Exit:   0 = extracted a plausible set; 1 = source unreadable; 2 = extraction looks BROKEN
#         (fewer than MIN_TRIGGERS). Callers MUST treat 2 as RED, never as "no triggers found" —
#         a silently-empty result is how a parity check passes while proving nothing.
set -uo pipefail

# V_RUN_GATES_SRC lets a harness point this at a MUTATED copy to prove the parity check really
# goes RED on new drift (a check that has never failed proves nothing).
RG="${1:-${V_RUN_GATES_SRC:-$HOME/.claude/skills/v/references/v-run-gates.sh}}"
MIN_TRIGGERS="${V_RG_MIN_TRIGGERS:-8}"

[ -f "$RG" ] || { echo "v-run-gates-triggers: source not readable: $RG" >&2; exit 1; }

# (1) literal -f/-x/-e tests on a quoted path containing no shell expansion.
lit=$(grep -oE '\-[fxe] +"[^"$]+"' "$RG" 2>/dev/null | sed -E 's/^-[fxe] +"//; s/"$//')

# (2) `for VAR in <items>; do` where the script elsewhere tests "$VAR" with -f/-x/-e.
loop=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  var=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*for[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+in[[:space:]].*/\1/')
  items=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]+(.*);[[:space:]]*do.*/\1/')
  [ -n "$var" ] && [ -n "$items" ] || continue
  # Only count the list if the loop variable is genuinely used in a file test.
  if grep -qE "\-[fxe] +\"\\\$$var\"" "$RG" 2>/dev/null; then
    for it in $items; do
      # Items may be quoted in source (`for _p in "vendor/bin/phpstan" "./vendor/bin/phpstan"`).
      # Strip surrounding quotes or the trigger reaches the caller as a literal `"path"` and no
      # sentinel can ever match it — a false DRIFT report, which is just as bad as a missed one.
      it="${it%\"}"; it="${it#\"}"
      it="${it%\'}"; it="${it#\'}"
      case "$it" in
        *'$'*|'') : ;;                 # skip expansions
        *.*|*/*) loop="${loop}${it}
" ;;                                    # keep things that look like paths
      esac
    done
  fi
done <<EOF
$(grep -E '^[[:space:]]*for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]][^;]*;[[:space:]]*do' "$RG" 2>/dev/null)
EOF

# (3) _changed_matches '<regex>' -> filename alternations.
#     Strip the (^|/) prefix group and the $ anchor, drop backslash escapes, split on |, then
#     expand a trailing `?` (bun.lockb? means BOTH bun.lockb and bun.lock).
rx=$(grep -oE "_changed_matches '[^']+'" "$RG" 2>/dev/null \
      | sed -E "s/^_changed_matches '//; s/'$//" \
      | sed -E 's/\(\^\|\/\)//g' \
      | tr -d '$' \
      | tr -d '\\' \
      | tr '|' '\n' \
      | tr -d '()' \
      | sed -E '/^[[:space:]]*$/d')
rx_expanded=""
while IFS= read -r tok; do
  [ -n "$tok" ] || continue
  case "$tok" in
    *[!A-Za-z0-9._?/-]*) continue ;;   # anything still carrying regex metachars is not a filename
  esac
  case "$tok" in
    *\?) rx_expanded="${rx_expanded}${tok%?}
${tok%??}
" ;;                                    # bun.lockb? -> bun.lockb AND bun.lock
    *)   rx_expanded="${rx_expanded}${tok}
" ;;
  esac
done <<EOF
$rx
EOF

out=$(printf '%s\n%s\n%s\n' "$lit" "$loop" "$rx_expanded" \
      | sed -E 's#^\./##' \
      | sed -E '/^[[:space:]]*$/d' \
      | sort -u)

n=$(printf '%s\n' "$out" | grep -c . || true)
printf '%s\n' "$out"
if [ "${n:-0}" -lt "$MIN_TRIGGERS" ]; then
  echo "v-run-gates-triggers: EXTRACTION LOOKS BROKEN — only ${n:-0} triggers (min $MIN_TRIGGERS) from $RG" >&2
  exit 2
fi
exit 0
