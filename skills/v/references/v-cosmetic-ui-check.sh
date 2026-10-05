#!/usr/bin/env bash
# v-cosmetic-ui-check.sh — classify a /v session's diff as COSMETIC vs BEHAVIORAL UI (W-perf7).
#
# WHY: Step 3.5 forces the full browser workflow-verification (npm run build + boot app +
# Playwright) for ANY changed UI file — disproportionate for a pure styling change (badge
# variant / color token / copy), which then degrades anyway in an env without auth/seed.
# This is the SINGLE SOURCE both the /v orchestrator (to take the cosmetic fast-lane) AND the
# harness (to validate the classification) call, so the "is this cosmetic?" decision can't drift.
#
# A change is COSMETIC only when EVERY non-test changed file is a UI/style file AND the diff's
# added/removed lines contain NO behavioral code (hooks, event handlers, data/control flow,
# function defs, interactive JSX). BIASED CONSERVATIVE: anything ambiguous → BEHAVIORAL (the
# safe default = full gate; a false-negative just runs the slow path, a false-positive would
# skip a browser drive — and even then pre-flight tests + UX-critique + codex + QA still run).
#
# Usage:  v-cosmetic-ui-check.sh <BASE_REF|""> <changed-file>...
#   BASE_REF — ref to diff against (the session baseline). Empty → auto (merge-base w/ main, else HEAD).
# Output:  "COSMETIC" + exit 0, or "BEHAVIORAL: <reason>" + exit 1. Exit 2 = usage/no-files.
# CALLER SAFETY (W-perf8): the non-zero exit is BY DESIGN (BEHAVIORAL=1). Callers MUST read the
# stdout WORD and capture exit-safe — `V=$(… || true)` — and must NOT batch this call with
# uncommitted Edit calls: a batch that aborted on this exit‑1 lost a session's .tsx edits
# (observed in a production session). The Stop hook re-validation and the orchestrator both call it with `|| true`.
set -u

BASE="${1:-}"; shift 2>/dev/null || { echo "BEHAVIORAL: usage (no files)"; exit 2; }
[ "$#" -ge 1 ] || { echo "BEHAVIORAL: no changed files given"; exit 2; }

MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if [ -z "$BASE" ]; then
  BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || git rev-parse HEAD 2>/dev/null || echo "")
fi

FILES=("$@")

# Test/spec files are support (they legitimately contain render/expect/behavioral code) — they
# don't disqualify a cosmetic change, but they're excluded from the behavioral-line scan.
is_test() { case "$1" in *.test.*|*.spec.*|*/__tests__/*|*/tests/*|*/e2e/*) return 0;; *) return 1;; esac; }

# UI/style file? .tsx/.jsx/.vue/.svelte/.css/.scss/.less always; a bare .ts/.js counts only as
# a style/variant/token file (its content is checked by the behavioral scan regardless).
is_ui_ext() {
  case "$1" in
    *.tsx|*.jsx|*.vue|*.svelte|*.css|*.scss|*.less|*.styl) return 0 ;;
    *.ts|*.js|*.mjs|*.cjs)
      # W-perf7 review (CODEX-003): a bare .ts/.js counts as cosmetic-eligible ONLY with a
      # style/variant/token/theme filename signal. A plain config/store/api/reducer/util .ts is
      # PURE LOGIC — its value-only changes (PAGE_SIZE 20→100, DEFAULT_VISIBILITY 'private'→'public')
      # carry NO behavioral TOKEN to catch, so without the signal it must default to BEHAVIORAL.
      case "$1" in
        *style*|*Style*|*variant*|*Variant*|*token*|*Token*|*theme*|*Theme*|*tailwind*|*color*|*Color*|*badge*|*Badge*|*.css.ts|*.css.js) return 0 ;;
        *) return 1 ;;   # non-style .ts/.js → treated as a non-UI file → BEHAVIORAL
      esac ;;
    *) return 1 ;;
  esac
}

# A non-UI non-test file present → not a pure UI change → BEHAVIORAL (e.g. a .php/.py/route/migration).
_src_files=()
for f in "${FILES[@]}"; do
  [ -n "$f" ] || continue
  if is_test "$f"; then continue; fi
  if ! is_ui_ext "$f"; then
    echo "BEHAVIORAL: non-UI file changed ($f) — not a pure styling change"; exit 1
  fi
  _src_files+=("$f")
done
[ ${#_src_files[@]} -ge 1 ] || { echo "BEHAVIORAL: only test files changed (nothing to classify)"; exit 1; }

# Behavioral signals in ADDED/REMOVED code lines (conservative). ugrep-safe (no \b / no \{n,}).
# BEHAVIORAL signals (ugrep-safe: no \b, no {n,}). W-perf7 review additions (CODEX-002/004):
#  • (&&|\|\||\?)[[:space:]]*<  — JSX conditional render / guard / ternary (`{cond && <X/>}`,
#    `cond ? <A/> : <B/>`, a REMOVED `{isOwner && <DeleteButton/>}` guard) — value changes on these
#    lines have no token but change WHICH subtree renders (incl. auth/visibility regressions).
#  • extra state props open|visible|loading|readOnly|multiple|selected|required|expanded|active.
#  • extra interactive components (DatePicker/Dropdown/Combobox/Menu/Tabs/… — headless-UI/Radix).
BEHAVIORAL_RE='(useState|useEffect|useCallback|useMemo|useRef|useReducer|useLayoutEffect|useContext|useQuery|useMutation|useForm|useRouter|useSWR)|on(Click|Submit|Change|Input|KeyDown|KeyUp|KeyPress|Focus|Blur|Scroll|MouseEnter|MouseLeave|Drag|Drop|Toggle)=|(fetch\(|axios\.|axios\(|router\.(push|replace|visit|get|post)|navigate\(|\.then\(|\.catch\(|await |dispatch\()|(^|[^A-Za-z_])(if|for|while|switch)[[:space:]]*\(|(^|[^A-Za-z_])function[[:space:]]|=>[[:space:]]*\{|(&&|\|\||\?)[[:space:]]*<[A-Za-z]|<(button|Button|a|Link|Input|input|Form|form|Select|select|Textarea|textarea|Checkbox|Radio|Switch|Dialog|Modal|DatePicker|Dropdown|Combobox|Menu|Tabs|Accordion|Slider|Toggle|Popover|Drawer|Sheet|Listbox|RadioGroup)([[:space:]>/])|[[:space:]](href|to|action|formAction|disabled|checked|open|visible|loading|readOnly|multiple|selected|required|expanded|active)='

# Examine only ADDED (+) and REMOVED (-) lines of the non-test source files, stripping the
# +/- marker, and ignoring comment-only / blank lines (comments + types can't be behavioral).
for f in "${_src_files[@]}"; do
  _diff=$(git diff "$BASE" -- "$f" 2>/dev/null)
  [ -n "$_diff" ] || _diff=$(git diff -- "$f" 2>/dev/null)        # fall back to working-tree diff
  [ -n "$_diff" ] || _diff=$(git diff HEAD -- "$f" 2>/dev/null)
  [ -n "$_diff" ] || _diff=$(git diff --cached -- "$f" 2>/dev/null) # staged
  # If NO diff can be computed, we cannot prove the change is cosmetic → BEHAVIORAL (conservative).
  # (An empty diff would otherwise match no behavioral pattern and fall through to COSMETIC — a
  # silent false-positive that would skip browser verification. Default-deny instead.)
  if [ -z "$_diff" ]; then
    echo "BEHAVIORAL: could not compute a diff for $f (cannot verify it is cosmetic)"; exit 1
  fi
  # changed code lines = +/- but not the +++/--- headers
  _changed=$(printf '%s\n' "$_diff" | grep -E '^[+-]' | grep -Ev '^(\+\+\+|---)' \
            | sed -E 's/^[+-]//' \
            | grep -Ev '^[[:space:]]*(//|/\*|\*|$)' )      # drop comment-only + blank lines
  if printf '%s\n' "$_changed" | grep -Eq "$BEHAVIORAL_RE"; then
    _hit=$(printf '%s\n' "$_changed" | grep -E "$BEHAVIORAL_RE" | head -1 | sed -E 's/^[[:space:]]+//' | cut -c1-80)
    echo "BEHAVIORAL: $f has a behavioral change [$_hit]"; exit 1
  fi
done

echo "COSMETIC"
exit 0
