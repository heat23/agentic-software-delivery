#!/usr/bin/env bash
# portability-test.sh — static guard for bug classes that pass on one platform and fail on another.
#
#   P1: every BSD-form `stat -f` is a fallback after a GNU-form `stat -c` on the same line. GNU stat
#       reads `-f` as "filesystem status", treats `%m` as a missing file, prints the filesystem
#       summary and exits 1, so a BSD-first `stat -f %m X || stat -c %Y X` chain hands the caller
#       several lines of text instead of a number. Branching on `uname` fails the same way on macOS
#       with GNU coreutils first on PATH. GNU first (`stat -c %Y X || stat -f %m X`) is correct
#       everywhere: BSD stat rejects `-c` without printing anything.
#   P2: no `{n}` / `{n,m}` interval in an awk program or awk -v value. mawk before
#       1.3.4-20200717 (the default awk on Debian 12 and Ubuntu 22.04) reads the braces literally,
#       so the regex silently stops matching. Spell repetitions out (`###?#?`, `[0-9a-f]` x 8).
#   P3: inside a multi-line `$(...)`, every `case` pattern starts with `(`. bash 3.2 (stock macOS)
#       reads a bare `pattern)` there as the end of the command substitution, so the block misparses
#       at run time; `bash -n` does not catch it. `(pattern)` is valid in every bash.
#   P4: every shell file parses under bash 3.2 (`/bin/bash` on macOS) when that shell is present.
#       bash 3.2 rejects some constructs newer bash accepts, e.g. a here-document containing an
#       apostrophe inside $(...); the hook then fails to load at all. Skipped where /bin/bash is
#       not bash 3.x (Linux CI); the macOS CI job runs it.
#   P5: no `\t` inside a quoted grep or sed pattern. GNU grep reads `\t` as a plain `t` and BSD sed
#       does the same, so the pattern silently stops matching on one platform (a quarantine step
#       never fired on Linux this way). Use `"$(printf '\t')"` or `$'\t'`, which are real tabs.
#   P0: positive controls — each detector flags a planted instance, so a clean result is not blind.
#
# A line checked by hand (a probed flavour branch, fixture text) can carry `# portability-ok: <why>`
# and is skipped by P1, P3 and P5.
#
# The detectors read shell text line by line; they are heuristics, not a shell parser. P2 follows a
# single-quoted awk program across lines but cannot see a regex built in a variable elsewhere and
# passed in later, a program in an `awk -f` file, or an `awk` call split with a line continuation.
# The CI matrix's mawk job is the backstop for those.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
SELF="scripts/portability-test.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n%s\n' "$1" "${2:-}"; }

# P1: drop the comment (a `#` that starts a word, so `$#` and `${#a[@]}` survive); then the text
# just before EVERY `stat -f` on the line must end in `stat -c <args> ||`.
STAT_AWK=""
read -r -d '' STAT_AWK <<'AWK' || true
/portability-ok/ { next }
{
  code = $0
  sub(/(^|[[:space:]])#.*/, "", code)
  pre = ""; rest = code
  while ((i = index(rest, "stat -f")) > 0) {
    pre = pre substr(rest, 1, i - 1)
    if (pre !~ /stat -c [^|;&()]*\|\|[[:space:]]*$/) { print FILENAME ":" FNR ": " $0; next }
    pre = pre "stat -f"; rest = substr(rest, i + 7)
  }
}
AWK
scan_stat(){ awk "$STAT_AWK" "$@"; }

# P2: a small shell-word reader. For every `awk` on a line it scans the option values (-F, -v and
# their attached forms) and the program word, and stops there, so a later `| grep -E 'x{8}'` is not
# counted. A program left open at the end of a line is followed to its closing quote; the text after
# that quote is scanned again as ordinary shell, so a second awk later in the line is still seen.
AWK_AWK=""
read -r -d '' AWK_AWK <<'AWK' || true
BEGIN { q = sprintf("%c", 39); dq = "\"" }
function repl(s, pat,   i, out) {
  out = ""
  while ((i = index(s, pat)) > 0) { out = out substr(s, 1, i - 1); s = substr(s, i + length(pat)) }
  return out s
}
function strip(s) { return repl(repl(s, q dq q dq q), q "\\" q q) }   # '"'"' and '\'' quote idioms
function interval(s) { return s ~ /(^|[^$@{])\{[0-9]+(,[0-9]*)?\}/ }
function hit() { if (!flagged) { print FILENAME ":" FNR ": " $0; flagged = 1 } }
function readword(s,   i, n, c, w, inq) {
  w = ""; inq = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (inq == "") {
      if (c ~ /[[:space:]]/ || c == "|" || c == ";" || c == "&" || c == ")") break
      if (c == q || c == dq) inq = c
    } else if (c == inq) {
      inq = ""
    } else if (inq == dq && c == "\\") {
      w = w c; i++; c = substr(s, i, 1)
    }
    w = w c
  }
  WREST = substr(s, i); WOPEN = (inq == q)
  return w
}
function scanshell(s,   r, w, v) {
  while (match(s, /(^|[^A-Za-z0-9_.-])awk([[:space:]]|$)/)) {
    r = substr(s, RSTART + RLENGTH)
    while (1) {
      sub(/^[[:space:]]+/, "", r)
      if (r == "") return
      w = readword(r); r = WREST
      if (w ~ /^-/) {
        if (w == "-F" || w == "-v" || w == "-f") { sub(/^[[:space:]]+/, "", r); v = readword(r); r = WREST; if (interval(v)) hit() }
        else if (interval(w)) hit()
        continue
      }
      if (interval(w)) hit()
      if (WOPEN) { inawk = 1; return }
      break
    }
    s = r
  }
}
FNR == 1 { inawk = 0 }
{
  flagged = 0
  t = strip($0)
  if (inawk) {
    k = index(t, q)
    prog = (k > 0) ? substr(t, 1, k - 1) : t
    if (prog !~ /^[[:space:]]*#/ && interval(prog)) hit()
    if (k == 0) next
    inawk = 0
    t = substr(t, k + 1)
  }
  if (t ~ /^[[:space:]]*#/) next
  scanshell(t)
}
AWK
scan_awk(){ awk "$AWK_AWK" "$@"; }

# P3: follow a command substitution that stays open past its first line (single-quoted text and
# escaped characters removed before counting parentheses; double-quoted text is kept, since a $(
# inside double quotes is real); inside it, flag a case pattern without a leading (. A one-line
# `case ... in pattern) ...;; esac` inside a $(...) is checked too, on any line: bash 3.2 rejects its
# bare first pattern just the same (a hook failed open on stock macOS this way).
CASE_AWK=""
read -r -d '' CASE_AWK <<'AWK' || true
function bare(s) { gsub(/\\./, "", s); gsub(/'[^']*'/, "", s); return s }
function opens(s,  t) { t = s; return gsub(/\(/, "", t) }
function closes(s,  t) { t = s; return gsub(/\)/, "", t) }
# 1 when s has `case ... in` followed on the same line by a pattern that does not start with (
function bare_first(s,  post) {
  if (!match(s, /(^|[^a-z_])case[[:space:]][^;]*[[:space:]]in[[:space:]]+/)) return 0
  post = substr(s, RSTART + RLENGTH)
  return (post != "" && substr(post, 1, 1) != "(")
}
# 1 when the case on this line sits inside a $( opened earlier on the same line
function in_subst(s,  pre) {
  if (!match(s, /(^|[^a-z_])case[[:space:]]/)) return 0
  pre = substr(s, 1, RSTART)
  return (index(pre, "$(") > 0 && opens(pre) > closes(pre))
}
FNR == 1 { depth = 0; incase = 0 }
{
  if ($0 ~ /^[[:space:]]*#/ || $0 ~ /portability-ok/) next
  t = bare($0); sub(/(^|[[:space:]])#.*/, "", t)
  # the direct `$(case ... in pattern)` form, matched on the raw line: quote stripping cannot be trusted
  # there, since an apostrophe inside a double-quoted message looks like the start of a quoted string
  if ($0 ~ /\$\([[:space:]]*case[[:space:]][^;]*[[:space:]]in[[:space:]]+[^([:space:]]/) { print FILENAME ":" FNR ": " $0; next }
  if (depth == 0) {
    if (in_subst(t) && bare_first(t)) { print FILENAME ":" FNR ": " $0; next }
    if (index(t, "$(") && opens(t) > closes(t)) {
      depth = opens(t) - closes(t); incase = 0
      if (in_subst(t) && t !~ /(^|[^a-z_])esac([^a-z_]|$)/) incase = 1
    }
    next
  }
  d = opens(t) - closes(t)
  if (t ~ /(^|[^a-z_])case[[:space:]].*[[:space:]]in([[:space:]]|$)/ && t !~ /(^|[^a-z_])esac([^a-z_]|$)/) incase++
  else if (t ~ /(^|[^a-z_])case[[:space:]].*[[:space:]]in([[:space:]]|$)/) { if (bare_first(t)) print FILENAME ":" FNR ": " $0 }   # case ... esac on one line
  else if (incase && t ~ /(^|[^a-z_])esac([^a-z_]|$)/) incase--
  else if (incase && t ~ /^[[:space:]]*[^([:space:]][^()]*\)([[:space:]]|$)/) { print FILENAME ":" FNR ": " $0; d++ }
  depth += d
  if (depth <= 0) { depth = 0; incase = 0 }
}
AWK
scan_case(){ awk "$CASE_AWK" "$@"; }

# P5: for each grep or sed on a line, skip its options (taking the argument after -e), read the
# pattern argument (single- or double-quoted, or a bare word) and flag it if it contains \t.
# $'...' strings and printf formats are dropped first: those produce real tab characters.
TAB_AWK=""
read -r -d '' TAB_AWK <<'AWK' || true
/portability-ok/ { next }
/^[[:space:]]*#/ { next }
{
  # a $'...' string starts where a word can start; the $' inside a pattern such as '^$' does not
  line = ""; rest = $0
  while ((i = index(rest, "$'")) > 0) {
    c = (i > 1) ? substr(rest, i - 1, 1) : " "
    if (c != " " && c != "\t" && c != "=" && c != "(" && c != "|" && c != ";") {
      line = line substr(rest, 1, i + 1); rest = substr(rest, i + 2); continue
    }
    tail = substr(rest, i + 2); j = index(tail, "'")
    if (j == 0) break
    line = line substr(rest, 1, i - 1); rest = substr(tail, j + 1)
  }
  line = line rest
  gsub(/printf '[^']*'/, "printf ''", line)
  gsub(/printf "[^"]*"/, "printf \"\"", line)
  s = line
  while (match(s, /(^|[^A-Za-z0-9_.\/-])(grep|sed)[[:space:]]+/)) {
    s = substr(s, RSTART + RLENGTH)
    while (substr(s, 1, 1) == "-") {
      if (match(s, /^-e[[:space:]]+/)) { s = substr(s, RLENGTH + 1); break }
      if (!match(s, /^-[^[:space:]]*[[:space:]]+/)) break
      o = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
      if (o ~ /^-i[[:space:]]+$/ && match(s, /^(''|"")[[:space:]]+/)) s = substr(s, RLENGTH + 1)   # BSD sed -i ''
    }
    q = substr(s, 1, 1)
    if (q == "'" || q == "\"") { rest = substr(s, 2); j = index(rest, q); arg = (j ? substr(rest, 1, j - 1) : rest) }
    else { match(s, /^[^[:space:]|;&)]*/); arg = substr(s, 1, RLENGTH) }
    if (index(arg, "\\t") > 0) { print FILENAME ":" FNR ": " $0; next }
  }
}
AWK
scan_tab(){ awk "$TAB_AWK" "$@"; }

FILES=()
while IFS= read -r f; do
  case "$f" in "$ROOT/$SELF") continue ;; esac
  FILES+=("$f")
done < <({ find "$ROOT/hooks" "$ROOT/skills" "$ROOT/scripts" "$ROOT/bin" -name '*.sh' -type f
           [ -f "$ROOT/bin/run-v-packs" ] && echo "$ROOT/bin/run-v-packs"; } 2>/dev/null | sort)
[ ${#FILES[@]} -gt 0 ] || { echo "FAIL: no shell files found under $ROOT"; exit 1; }

# ── P0: positive controls ──
FX="$(mktemp -d)"; trap 'rm -rf "$FX"' EXIT
cat > "$FX/stat-bad.sh" <<'EOF'
_m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
case "$(uname -s)" in
  Darwin|*BSD) stat -f %m "$1" 2>/dev/null ;;
  *)           stat -c %Y "$1" 2>/dev/null ;;
esac
[ "${#a[@]}" -gt 0 ] && stat -f %m "$f"
a=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f"); b=$(stat -f %z "$f")
EOF
cat > "$FX/stat-ok.sh" <<'EOF'
n=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
[ $# -gt 0 ] && s=$(stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null)
m() {  # a comment that mentions `stat -f %m` is not code
  :
}
EOF
cat > "$FX/case-bad.sh" <<'EOF'
x="$(printf 'a\n' | while read -r l; do
  case "$l" in
    a) echo yes ;;
    *) echo no ;;
  esac
done)"
r=$(case "$y" in a) echo 1 ;; *) echo 2 ;; esac)
m="see $(case "$y" in b) printf b;; esac) here"
n="the orchestrator's note: $(case "$y" in c) printf c;; esac)"
t=$(case "$y" in
  c) echo 3 ;;
esac)
EOF
cat > "$FX/case-oneline-ok.sh" <<'EOF'
y="$(printf 'a\n' | while read -r l; do
  case "$l" in (a) echo yes ;; esac
done | sort -u)"
EOF
cat > "$FX/case-ok.sh" <<'EOF'
x="$(printf 'a\n' | while read -r l; do
  case "$l" in
    (a) echo yes ;;
    (*) echo no ;;
  esac
done)"
case "$x" in
  yes) echo top-level patterns need no paren ;;
esac
r=$(case "$y" in (a) echo 1 ;; (*) echo 2 ;; esac)
case "$y" in a) echo top-level one-liner ;; esac
y="$(printf '%s' "(unbalanced in a string" | wc -c)"
EOF
cat > "$FX/awk-bad.sh" <<'EOF'
x=$(awk '
  /^#{2,4} FND/ { n++ }
  END { print n }' "$f")
y=$(awk -v re="[0-9a-f]{8}" '$0 ~ re' "$f")
a=$(awk -F'|' '/x{8}/ { print }' "$f")
b=$(awk -v n='1' '/x{8}/' "$f")
c=$(awk '{ print }' "$f" | awk '/y{3}/')
EOF
cat > "$FX/awk-ok.sh" <<'EOF'
z=$(awk '/^###?#? FND/ { n++ } END { print n }' "$f"); echo "${10}" "stash@{0}"
w=$(awk '{ print $1 }' "$f" | grep -E '[0-9a-f]{8}')
v=$(awk '
  { print $1 }' "$f" | grep -E '[0-9a-f]{8}')
# awk '/x{8}/' in a comment
EOF
cat > "$FX/tab-bad.sh" <<'EOF'
grep -qE '^DUPLICATE\t' "$f"
n=$(grep -c "a\tb" "$f")
sed 's/\t/ /g' "$f"
sed -e 's/x/\t/' "$f" | sort
x=$(cut -f1 "$f" | grep -E '^[a-z]+\t[0-9]+$')
sed -i '' 's/\t/ /' "$f"
EOF
cat > "$FX/tab-ok.sh" <<'EOF'
grep -q "^DUPLICATE$(printf '\t')" "$f"
grep -q $'\tmain\t' "$f"
awk -F'\t' '{ print $1 }' "$f" | grep -E 'x'
printf 'a\tb\n' | tr '\t' ' '
# grep '\t' in a comment
r=$(printf '%s' "$x" | grep -v '^$' | sort -t"$(printf '\t')" -k1,1 -rn)
EOF
count(){ "$1" "$2" | wc -l | tr -d ' '; }
p0="$( [ "$(count scan_stat "$FX/stat-bad.sh")" -eq 4 ] && [ "$(count scan_stat "$FX/stat-ok.sh")" -eq 0 ] \
    && [ "$(count scan_awk "$FX/awk-bad.sh")" -eq 5 ] && [ "$(count scan_awk "$FX/awk-ok.sh")" -eq 0 ] \
    && [ "$(count scan_case "$FX/case-bad.sh")" -eq 6 ] && [ "$(count scan_case "$FX/case-ok.sh")" -eq 0 ] \
    && [ "$(count scan_case "$FX/case-oneline-ok.sh")" -eq 0 ] \
    && [ "$(count scan_tab "$FX/tab-bad.sh")" -eq 6 ] && [ "$(count scan_tab "$FX/tab-ok.sh")" -eq 0 ] && echo y )"
[ "$p0" = y ] && ok "P0 detectors flag all 21 planted bad lines (4 stat, 5 awk, 6 case, 6 tab) and none of the fixed forms" \
              || no "P0 a detector is blind or over-matches" "$(scan_stat "$FX"/*.sh; scan_awk "$FX"/*.sh; scan_case "$FX"/*.sh; scan_tab "$FX"/*.sh)"

# ── P1 / P2 over the shipped scripts ──
hits="$(scan_stat "${FILES[@]}")"
[ -z "$hits" ] && ok "P1 every stat -f is a fallback after stat -c, in ${#FILES[@]} shell files" \
               || no "P1 stat -f that is not a fallback after stat -c (wrong output on GNU stat)" "$(printf '%s\n' "$hits" | sed "s#^$ROOT/#    #")"
hits="$(scan_awk "${FILES[@]}")"
[ -z "$hits" ] && ok "P2 no regex interval in an awk program or -v value in ${#FILES[@]} shell files" \
               || no "P2 awk interval (silently literal on older mawk)" "$(printf '%s\n' "$hits" | sed "s#^$ROOT/#    #" | cut -c1-160)"

hits="$(scan_case "${FILES[@]}")"
[ -z "$hits" ] && ok "P3 every case pattern inside a multi-line \$(...) starts with ( in ${#FILES[@]} shell files" \
               || no "P3 bare case pattern inside \$(...) (bash 3.2 misparses the block)" "$(printf '%s\n' "$hits" | sed "s#^$ROOT/#    #" | cut -c1-160)"

hits="$(scan_tab "${FILES[@]}")"
[ -z "$hits" ] && ok "P5 no \\t in a quoted grep or sed pattern in ${#FILES[@]} shell files" \
               || no "P5 \\t in a grep/sed pattern (a plain t to GNU grep and BSD sed)" "$(printf '%s\n' "$hits" | sed "s#^$ROOT/#    #" | cut -c1-160)"

if /bin/bash -c '[ "${BASH_VERSINFO[0]}" -eq 3 ]' 2>/dev/null; then
  hits=""
  for f in "${FILES[@]}"; do /bin/bash -n "$f" 2>/dev/null || hits="$hits    ${f#$ROOT/}
"; done
  printf 'x=$(cat <<EOF\ndon'"'"'t\nEOF\n)\n' > "$FX/heredoc-bad.sh"
  if ! /bin/bash -n "$FX/heredoc-bad.sh" 2>/dev/null; then
    [ -z "$hits" ] && ok "P4 all ${#FILES[@]} shell files parse under bash 3.2 (control: a planted bad file is rejected)" \
                   || no "P4 shell files that bash 3.2 cannot parse" "$hits"
  else
    no "P4 control: bash 3.2 accepted a known-bad here-document, so this check cannot be trusted"
  fi
else
  echo "  skip P4 — /bin/bash is not bash 3.x here"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
