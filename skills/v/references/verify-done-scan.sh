#!/usr/bin/env bash
# verify-done-scan.sh — deterministic mechanical convention scan for the v-verify-done gate.
#
# WHY: the verify-done runner used to issue ~12 sequential single-grep Bash calls (one check per
# turn), each re-reading its full subagent context (forensic: ~12 probe turns, each re-reading the
# whole context). This collapses every CLEANLY-GREPPABLE check into ONE deterministic pass and
# emits a structured table, so the runner makes ~1 Bash call and only `Read`s files that have a HIT.
# Deterministic grep is ALSO more reliable than the model running each check ad-hoc (no missed or
# mistyped pattern).
#
# NOT A VERDICT MACHINE — a candidate-finder. The runner still ADJUDICATES each HIT by reading the
# flagged file (e.g. `dangerouslySetInnerHTML` WITH DOMPurify is fine), and still performs the
# SEMANTIC checks this script deliberately does NOT cover (lazy-loading, Cashier `->load`, Form
# Request, Mockery identity, Queue::fake side-effects, Factory FK drift, missing-test, unused imports).
#
# FAIL-SAFE: never report a false `clean`. A file that cannot be read (missing/binary/non-regular) is
# SKIPPED and listed (never silently dropped). Patterns lean toward OVER-flagging (the runner
# adjudicates HITs); the dangerous direction is a missed violation, so checks err that way.
# NOTE (CRITICAL-1, codex 2026-06-15): the hit prefix is built with printf in the loop, NOT
# `sed "s|^|$f:|"` — a filename containing `|`/`&` would break that sed, drop the hits to empty, and
# print a false `[clean]` while counting the file as scanned. Never interpolate a filename into a sed
# program here.
#
# CONTRACT: the mechanical checks here MUST stay in sync with dispatch-v-verify-done.md (the prompt
# carries a `verify-done-scan-checks:` manifest). verify-done-scan-test.sh asserts the id SETS are
# equal BOTH directions. NEVER let a check silently appear/disappear on one side.
#
# Usage:  bash verify-done-scan.sh <changed-file> [<changed-file> ...]
#    or:  printf '%s\n' f1 f2 | bash verify-done-scan.sh -      # newline list on stdin
# Output (stdout): a header, one `[STATUS] check-id` row per check (+ indented file:line for HITs),
#   then a SKIPPED line and a `# checks:` manifest. STATUS ∈ HIT | clean | n/a.
# Exit: 0 always (this is a reporter — the TABLE is the result; never gate on its exit code).

set -u

CAP=25   # max detail lines printed per check (bounds output; full count still reported)

# ── 1. collect input list (args, or newline list on stdin when $1 == '-') ──────────────────────────
files=()
if [ "${1:-}" = "-" ]; then
  while IFS= read -r _l; do [ -n "$_l" ] && files+=("$_l"); done
else
  for _a in "$@"; do [ -n "$_a" ] && files+=("$_a"); done
fi

# ── 2. partition: scannable (existing, text) vs skipped (missing/binary — disclosed, never dropped) ─
scan=(); skipped=()
for f in ${files[@]+"${files[@]}"}; do
  if [ ! -e "$f" ]; then skipped+=("$f(missing)"); continue; fi
  if [ ! -f "$f" ]; then skipped+=("$f(not-regular)"); continue; fi
  if grep -Iq . "$f" 2>/dev/null; then scan+=("$f"); else skipped+=("$f(binary)"); fi
done

# subset of scan[] whose path matches an extension ERE
_subset(){ local re="$1" f; for f in ${scan[@]+"${scan[@]}"}; do
  printf '%s\n' "$f" | grep -qiE "$re" && printf '%s\n' "$f"; done; }

emitted_ids=""   # for the self-describing coverage manifest

# grep-based check: $1 id, $2 ext-ERE ("" = all scannable text files), $3 grep-ERE, $4 label
run_check(){
  local id="$1" extre="$2" pat="$3" label="$4"
  emitted_ids="$emitted_ids $id"
  local subset
  if [ -n "$extre" ]; then subset=$(_subset "$extre")
  else subset=$(for f in ${scan[@]+"${scan[@]}"}; do printf '%s\n' "$f"; done); fi
  if [ -z "$subset" ]; then printf '[n/a]   %-18s (no files in scope) — %s\n' "$id" "$label"; return; fi
  # build "file:line:match" WITHOUT sed-interpolating the filename (CRITICAL-1 fail-safe)
  local hits; hits=$(printf '%s\n' "$subset" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -nIE -- "$pat" "$f" 2>/dev/null | while IFS= read -r ln; do printf '%s:%s\n' "$f" "$ln"; done
  done)
  if [ -z "$hits" ]; then printf '[clean] %-18s — %s\n' "$id" "$label"; return; fi
  local n; n=$(printf '%s\n' "$hits" | grep -c .)
  printf '[HIT]   %-18s %s match(es) — %s\n' "$id" "$n" "$label"
  printf '%s\n' "$hits" | head -n "$CAP" | sed 's/^/          /'   # static indent only — no $f in the sed
  [ "$n" -gt "$CAP" ] && printf '          … (%s more; Read the file)\n' "$((n-CAP))"
}

echo "# verify-done-scan v1 — ${#scan[@]} file(s) scanned, ${#skipped[@]} skipped"
echo "# HIT = candidate (Read the file to adjudicate); clean = no match; n/a = no in-scope files."

# ── 3. the mechanical checks (mirror dispatch-v-verify-done.md manifest — keep in lockstep) ─────────
run_check todo-fixme       ""  '\b(TODO|FIXME|HACK|XXX)\b' \
  "TODO/FIXME/HACK markers"
run_check secrets          ""  'sk_live_[0-9A-Za-z]|AKIA[0-9A-Z]{16}|ghp_[0-9A-Za-z]{20,}|Bearer [0-9A-Za-z._-]{12,}' \
  "Secrets (sk_live_/AKIA/ghp_/Bearer)"
# debug: anchor each helper to (^|non-word) so a line-START debugger;/dd(/dbg! is caught (CRITICAL-2)
run_check debug            ""  'console\.(log|debug)[[:space:]]*\(|(^|[^A-Za-z_>])dd\(|(^|[^A-Za-z_])dump\(|(^|[^A-Za-z_])debugger([^A-Za-z_]|$)|binding\.pry|(^|[^A-Za-z_])dbg!' \
  "Debug statements (console.log/dd/dump/debugger/binding.pry/dbg!)"
# ts-any: broad candidate — any standalone `any` token (catches Record<string, any>, unions, etc.);
# over-flags (comments) but the runner adjudicates HITs — the dangerous direction is a MISS (HIGH-3)
run_check ts-any           '\.(ts|tsx|mts|cts|vue)$'  '(^|[^A-Za-z0-9_$])any([^A-Za-z0-9_$]|$)' \
  "TS \`any\` type (candidate — adjudicate)"
run_check type-suppression ''  '@ts-ignore|@ts-nocheck|@ts-expect-error|eslint-disable' \
  "Type/lint suppressions (@ts-ignore/@ts-nocheck/eslint-disable)"

# unsanitized-html: PER-LINE (HIGH-3/LOW-7) — flag every dangerouslySetInnerHTML line whose SAME line
# lacks DOMPurify/.sanitize(. Per-line (not file-level) so a file mixing a sanitized + an unsanitized
# use cannot false-clean. A HIT is still a candidate; the runner confirms the binding is sanitized.
emitted_ids="$emitted_ids unsanitized-html"
html_files=$(_subset '\.(ts|tsx|js|jsx|mjs|cjs|vue)$')
if [ -z "$html_files" ]; then
  printf '[n/a]   %-18s (no files in scope) — %s\n' "unsanitized-html" "dangerouslySetInnerHTML without DOMPurify"
else
  unsan=$(printf '%s\n' "$html_files" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -nIF 'dangerouslySetInnerHTML' "$f" 2>/dev/null | while IFS= read -r ln; do
      printf '%s' "$ln" | grep -qiE 'DOMPurify|\.sanitize\(' || printf '%s:%s\n' "$f" "$ln"
    done; done)
  if [ -z "$unsan" ]; then
    printf '[clean] %-18s — %s\n' "unsanitized-html" "dangerouslySetInnerHTML all same-line sanitized / absent"
  else
    n=$(printf '%s\n' "$unsan" | grep -c .)
    printf '[HIT]   %-18s %s match(es) — %s\n' "unsanitized-html" "$n" "dangerouslySetInnerHTML without same-line DOMPurify"
    printf '%s\n' "$unsan" | head -n "$CAP" | sed 's/^/          /'
    [ "$n" -gt "$CAP" ] && printf '          … (%s more; Read the file)\n' "$((n-CAP))"
  fi
fi

# ── 4. disclose skipped files (fail-safe: the runner must hand-check these; never a silent gap) ────
if [ "${#skipped[@]}" -gt 0 ]; then
  printf 'SKIPPED (hand-check — not scanned): %s\n' "${skipped[*]}"
else
  echo "SKIPPED (hand-check — not scanned): none"
fi
echo "# checks: ${emitted_ids# }"
exit 0
