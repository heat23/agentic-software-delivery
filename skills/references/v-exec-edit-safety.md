# Edit Tool Safety (extracted from _v-exec.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Edit Tool Safety: `replace_all` Corruption

The Edit tool's `replace_all: true` mode has a known bug: it sometimes appends trailing content from the original file (extra `}`, `);`, partial identifiers). This caused 16 fix cycles in one session.

**Mitigation:**
- After **every** `replace_all: true` edit, immediately run `tail -3 <file>` to verify no trailing content corruption. Do not batch — check each file right after editing.
- For mass string replacements across >5 files, prefer `sed -i.bak 's/old/new/g' <file> && rm <file>.bak` via Bash over Edit tool `replace_all`. The `-i.bak` form is portable across both macOS BSD sed and GNU sed (unlike `sed -i ''` which fails on GNU, or bare `sed -i` which fails on macOS). Clean up the `.bak` file afterward. Sed doesn't corrupt but doesn't update the Edit tool's file cache — follow with a Read to sync.
- After using `replace_all: true` on >3 files, run `npm run build` or `tsc --noEmit` to catch any corruption the tail check missed.
- After every Edit on a TSX/TS/PHP file, verify the file ends correctly: `tail -3 <file>` should show clean closing braces.

## Copy Change Protocol

When changing user-visible strings (UI copy, email text, CTA labels, error messages), test assertions will break. This caused 2-3 extra test fix rounds in every copy-change session.

**Before editing any user-visible string:**
1. `grep -rn 'old_string' tests/ resources/js/tests/` — find all test assertions referencing the old value
2. Update source files AND test assertions in the same pass — do not wait for test failures
3. For strings in `messages.ts` or Blade templates, check BOTH PHP and JS test suites

**Pattern:**
```
# WRONG — update copy, run tests, fix tests, run tests again
Edit 1: change "Upgrade to Pro" → "Go Pro" in UpgradeBanner.tsx
[run tests — fail]
Edit 2: fix upgrade-banner.test.tsx assertion
[run tests — pass]

# RIGHT — update both together
grep -rn "Upgrade to Pro" tests/ resources/js/tests/
Edit 1: change in UpgradeBanner.tsx + update upgrade-banner.test.tsx
[run tests — pass on first try]
```
