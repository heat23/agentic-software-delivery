# TypeScript Auto-Remediation Protocol (extracted from _v-exec.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

**Applicability:** This protocol applies ONLY when `DETECTED_STACK` includes TypeScript (check for `tsconfig.json` or `.ts`/`.tsx` files). For non-TypeScript stacks (Django, Rails, Go, Rust), skip this entire protocol — there is no `tsc` to run.

When `npx tsc --noEmit` fails during a build or pre-flight, do not immediately declare the gate failed. Instead, categorize the errors and apply known fixes automatically.

## Error Classification

Parse `tsc` output and classify each error by its TS code:

```bash
# Capture and categorize errors
TSC_OUTPUT=$(npx tsc --noEmit 2>&1 || true)
echo "$TSC_OUTPUT" | grep -oE 'TS[0-9]+' | sort | uniq -c | sort -rn
```

## Known Auto-Fix Recipes

**Note:** The recipes below are primarily for Laravel/Inertia/Vite stacks. For other stacks (Next.js, SvelteKit, Django, etc.), the remediation loop still applies — categorize errors, apply stack-appropriate fixes, and iterate — but these specific recipes may not match. When `DETECTED_STACK` is not `laravel`, skip recipes that reference Inertia/Vite-specific types and rely on the generic categorize→fix→rerun loop.

**Category 1: TS2344 — PageProps missing index signature**
Symptom: `Type 'PageProps' does not satisfy the constraint 'Record<string, unknown>'`
Root cause: Inertia's `PageProps` interface lacks `[key: string]: unknown`.
Fix: Add the index signature to the project's `types/inertia.d.ts` (or equivalent):
```typescript
// In types/inertia.d.ts or types/global.d.ts
declare module '@inertiajs/core' {
  interface PageProps {
    [key: string]: unknown;
  }
}
```
Detection: `grep -c 'TS2344' <<< "$TSC_OUTPUT"` returns > 0 and errors reference `PageProps`.

**Category 2: TS2741/TS2740 — Missing required props in test mocks**
Symptom: `Property 'X' is missing in type '{}' but required in type 'InertiaFormProps'`
Root cause: Test files create partial mock objects without satisfying all required properties.
Fix: Create or update a shared mock factory that provides all required fields:
```typescript
// tests/helpers/mock-factories.ts
import { InertiaFormProps } from '@inertiajs/core';

export function createMockInertiaForm<T extends Record<string, unknown>>(
  data: T,
  overrides: Partial<InertiaFormProps<T>> = {}
): InertiaFormProps<T> {
  return {
    data,
    isDirty: false,
    errors: {} as any,
    hasErrors: false,
    processing: false,
    wasSuccessful: false,
    recentlySuccessful: false,
    setData: vi.fn() as any,
    transform: vi.fn() as any,
    setDefaults: vi.fn() as any,
    reset: vi.fn() as any,
    clearErrors: vi.fn() as any,
    setError: vi.fn() as any,
    submit: vi.fn(),
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
    cancel: vi.fn(),
    ...overrides,
  } as InertiaFormProps<T>;
}
```
Detection: errors reference `InertiaFormProps`, `Page<PageProps>`, or show `Property '...' is missing in type '{}'` in test files.
Approach: Locate the project's existing test helper directory. If a mock factory exists, extend it. If not, create one and update failing test files to use it.

**Category 3: TS2339 — ImportMeta.env / ImportMeta.glob not typed**
Symptom: `Property 'env' does not exist on type 'ImportMeta'`
Root cause: Vite's client types aren't included in the TypeScript compilation.
Fix: Add `vite/client` to tsconfig's `types` array:
```json
// tsconfig.json → compilerOptions.types
"types": ["vite/client"]
```
Or if a `tsconfig.app.json` or `tsconfig.node.json` exists, add it there.
Detection: errors contain `ImportMeta` and `TS2339`.

**Category 4: TS2322 — Library type mismatches (Recharts, UI components)**
Symptom: `Type 'string' is not assignable to type 'Formatter<ValueType>'` or `Type '"warning"' is not assignable to type '"default" | "destructive"'`
Root cause: Library version upgrades changed expected types; wrapper components expose stale type signatures.
Fix strategy:
- For Recharts formatters: type the wrapper component against the library's current `Formatter`/`TooltipProps` type (or a narrow local type matching the datum shape). Do NOT paper over it with `as any` + a `// TODO` — that recipe is rejected by v-pre-flight Gate 4/6 (lint/ESLint-strict) and v-verify-done's `as any`+TODO scan. If the library's published types are genuinely wrong, wrap the value in a small typed adapter function rather than casting to `any`.
- For UI component variants: Check the component's actual variant union type and either add the missing variant to the component definition or map it to an existing one.
Detection: errors reference third-party component names (Recharts, Button, Badge, etc.) with `TS2322`.
Approach: Read the component source to determine the actual expected type. Apply the minimal fix.

**Category 5: TS2345 — Incomplete mock objects in tests**
Symptom: `Argument of type '{ id: number; }' is not assignable to parameter of type 'User'`
Root cause: Test files pass partial objects where full typed objects are expected.
Fix: Use the mock factory pattern from Category 2, or use `as` casting with `Partial<>`:
```typescript
const mockUser = { id: 1, name: 'Test' } as User;
// or for function args:
someFunction({ id: 1 } as Partial<User> as User);
```
Detection: TS2345 errors in test files (`*.test.ts`, `*.test.tsx`, `*.spec.ts`).
Approach: Prefer mock factories over `as` casting. Only use `as` casting when the test intentionally tests partial data handling.

## Remediation Loop

When TypeScript errors are detected:

1. **Categorize**: Parse all errors, group by TS code and root cause.
2. **Apply known fixes**: For each category above, apply the fix if the pattern matches.
3. **Re-run**: `npx tsc --noEmit` again.
4. **Iterate**: If new errors appear (fixing one category can unmask others), repeat up to 3 iterations.
5. **Report**: After 3 iterations or zero errors, report the outcome:
   - All fixed → gate passes
   - Some remain → list remaining errors with their TS codes and file locations. These are novel errors that need manual attention.

## Progress-Check-Fix Loop (Worktree Builds)

In worktree builds, the remediation integrates with the progress-checkpoint protocol:

1. **Capture implementation state** in `PROGRESS_NOTE_${CLAUDE_SESSION_ID}.md`.
2. **Run TypeScript check**: `npx tsc --noEmit 2>&1`
3. **If errors found**: Categorize and apply known fixes from the recipes above.
4. **If the live pre-commit gate is already satisfied**, optionally commit the implementation or fix batch in the worktree branch.
5. **Re-check**: Run `npx tsc --noEmit` again.
6. **Repeat**: Up to 3 iterations total.
7. **Outcome**:
   - Clean → proceed to next phase
   - Remaining errors → log in `BUILD_BLOCKER` if unfixable, or note as warnings if non-critical

This loop runs at every progress checkpoint in the build, not just at the end. Catching errors early prevents cascading type issues across phases.
