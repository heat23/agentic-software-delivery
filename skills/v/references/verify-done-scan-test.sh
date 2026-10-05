#!/usr/bin/env bash
# verify-done-scan-test.sh — fixtures + bidirectional contract for verify-done-scan.sh.
#
# Locks: (1) every mechanical check flags its planted hit; (2) the codex-found FALSE-CLEAN shapes stay
# caught (pipe-in-filename, line-start debugger/dbg!, Record<string,any>, mixed sanitized/unsanitized
# in one file) — these are NEGATIVE regression fixtures, one per finding; (3) a clean file produces
# nothing; (4) missing/binary files are DISCLOSED as SKIPPED (never a silent gap); (5) the CONTRACT —
# the scan's `# checks:` id set EQUALS the prompt's `verify-done-scan-checks:` manifest, BOTH
# directions (sorted-set compare, immune to prose collisions), so script and prompt cannot drift.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/verify-done-scan.sh"
PROMPT="$HERE/dispatch-v-verify-done.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1"; }
# is check $2 reported as [HIT] in scan output $1 ?  (anchored to the status+id columns)
is_hit(){ printf '%s\n' "$1" | grep -qE "^\[HIT\][[:space:]]+$2( |\$)"; }

echo "== verify-done-scan guardrail =="
[ -f "$SCAN" ] || { echo "  NO  verify-done-scan.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
cat > "$TD/bad.php" <<'EOF'
<?php
// TODO: refactor this
$key = 'sk_live_abc123XYZ0';
dd($user);
EOF
cat > "$TD/bad.tsx" <<'EOF'
const x: any = 1;
// @ts-ignore
console.log(x);
return <div dangerouslySetInnerHTML={{__html: userHtml}} />;
EOF
cat > "$TD/safe.tsx" <<'EOF'
import DOMPurify from 'dompurify';
const y: string = '';
return <div dangerouslySetInnerHTML={{__html: DOMPurify.sanitize(y)}} />;
EOF
printf '<?php\nreturn config("x");\n' > "$TD/clean.php"
printf '\x00\x01\x02binary\x00' > "$TD/blob.bin"
# ── negative regression fixtures (one per codex false-clean finding) ──
printf '// TODO: pipe-name\n' > "$TD/a|b.ts"                                   # CRITICAL-1
printf 'debugger;\ndbg!(val);\n' > "$TD/linestart.js"                          # CRITICAL-2
printf 'type C = Record<string, any>;\n' > "$TD/generics.ts"                   # HIGH-3
printf 'const ok = DOMPurify.sanitize(a);\nreturn <b dangerouslySetInnerHTML={{__html: raw}} />;\n' > "$TD/mixed.tsx"  # LOW-7

OUT=$(bash "$SCAN" "$TD/bad.php" "$TD/bad.tsx" "$TD/safe.tsx" "$TD/clean.php" "$TD/blob.bin" \
  "$TD/a|b.ts" "$TD/linestart.js" "$TD/generics.ts" "$TD/mixed.tsx" "$TD/missing.php" 2>&1)
RC=$?

[ "$RC" = 0 ] && ok "exit 0 (reporter never non-zero)" || no "exit $RC (expected 0)"
for chk in todo-fixme secrets debug ts-any type-suppression unsanitized-html; do
  is_hit "$OUT" "$chk" && ok "flags $chk on planted fixture" || no "MISSED planted $chk"
done

# sanitized file must NOT appear (clean on every check incl. the DOMPurify same-line exclusion)
printf '%s\n' "$OUT" | grep -q 'safe.tsx' && no "safe.tsx (sanitized) wrongly flagged" \
  || ok "safe.tsx (DOMPurify same-line) not flagged"
printf '%s\n' "$OUT" | grep -q 'clean.php' && no "clean.php produced a spurious hit" \
  || ok "clean.php produced no hit"

# NEGATIVE regressions — each tricky violation must reach the runner (HIT or, fail-safe, SKIPPED) — never clean
printf '%s\n' "$OUT" | grep -q 'a|b.ts:1' && ok "CRITICAL-1: pipe-in-filename TODO surfaced (no sed false-clean)" \
  || no "CRITICAL-1 REGRESSED: pipe-in-filename TODO not surfaced (silent false-clean)"
printf '%s\n' "$OUT" | grep -q 'linestart.js:1' && printf '%s\n' "$OUT" | grep -q 'linestart.js:2' \
  && ok "CRITICAL-2: line-start debugger; AND dbg! both caught" \
  || no "CRITICAL-2 REGRESSED: line-start debugger/dbg! missed"
printf '%s\n' "$OUT" | grep -q 'generics.ts:1' && ok "HIGH-3: Record<string, any> caught" \
  || no "HIGH-3 REGRESSED: Record<string, any> missed"
# mixed: the UNsanitized line (2) is HIT; the sanitized line (1) is NOT
printf '%s\n' "$OUT" | grep -q 'mixed.tsx:2' && ! printf '%s\n' "$OUT" | grep -q 'mixed.tsx:1' \
  && ok "LOW-7: mixed file flags only the unsanitized line" \
  || no "LOW-7 REGRESSED: mixed sanitized/unsanitized mishandled"

# fail-safe disclosure
printf '%s\n' "$OUT" | grep -q 'missing.php(missing)' && ok "missing file disclosed as SKIPPED" \
  || no "missing file NOT disclosed (silent gap)"
printf '%s\n' "$OUT" | grep -q 'blob.bin(binary)' && ok "binary file disclosed as SKIPPED" \
  || no "binary file NOT disclosed (silent gap)"

# ── CONTRACT (bidirectional, id-SET, manifest-based — immune to prose collisions) ─────────────────
SIDS=$(printf '%s\n' "$OUT" | sed -n 's/^# checks: //p' | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
[ -n "$SIDS" ] && ok "scan self-describes its check ids ($SIDS)" || no "scan emitted no '# checks:' line"
if [ -f "$PROMPT" ]; then
  grep -Fq 'verify-done-scan.sh' "$PROMPT" \
    && ok "dispatch-v-verify-done.md invokes verify-done-scan.sh" \
    || no "dispatch-v-verify-done.md does NOT invoke verify-done-scan.sh (scan unused)"
  PIDS=$(sed -n 's/.*verify-done-scan-checks: *//p' "$PROMPT" | sed 's/ *-->.*//' | tr ' ' '\n' | grep . | sort | tr '\n' ' ')
  [ -n "$PIDS" ] && ok "prompt carries a verify-done-scan-checks manifest ($PIDS)" \
    || no "prompt has NO verify-done-scan-checks manifest (cannot verify contract)"
  [ "$SIDS" = "$PIDS" ] && ok "CONTRACT: scan id set == prompt manifest (no drift, either direction)" \
    || no "CONTRACT DRIFT: scan ids [$SIDS] != prompt manifest [$PIDS]"
else
  no "dispatch-v-verify-done.md missing: $PROMPT"
fi

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
