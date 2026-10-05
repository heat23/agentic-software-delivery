# React Component Test Skeleton (Vitest)

_Last reviewed: 2026-07-06 (design-language consistency pass)_

> Loaded by v-tdd **only when the test target is a React/Vitest component** (per Stack Detection). Not loaded for PHP/Pest targets — this keeps the framework-specific scaffold out of the always-loaded skill body. The skill body retains the workflow, boundary-test rules, and gates; this file holds the copy-paste scaffold.

## React Component Test Skeleton (Vitest)

Location: alongside component as `{Name}.test.tsx`

### Detection

**Step 1 — confirm the UI framework before assuming `@testing-library/react` (Gotcha #4).**
The skeleton below imports from `@testing-library/react`; that is WRONG for a Preact or
Solid project. Check `package.json` first:
```bash
grep -E '"(preact|solid-js)"' package.json
```
- Hit on `"preact"` → import from `@testing-library/preact` (same `render`/`screen` API); Preact projects usually alias `react`→`preact/compat`, so `@testing-library/react` may also work, but prefer the native package when present.
- Hit on `"solid-js"` → use `@solidjs/testing-library` and `@testing-library/jest-dom`; Solid's reactive `render` differs (no `renderHook` from `@testing-library/react` — use `renderHook` from `@solidjs/testing-library`).
- No hit → assume React; proceed with the skeleton below.

**Step 2 — confirm Testing Library is installed** for the resolved framework:
```bash
grep -E "@(testing-library|solidjs)/(react|preact|user-event)" package.json
```

If found, use Testing Library patterns. Otherwise, use the alternative testing approach the project already follows (read 2-3 existing component tests).

### Scenarios

Standard test cases for React components:
- `it('renders without crashing')` — Basic render
- `it('displays expected content')` — Content/text assertions
- `it('shows loading state while data fetches')` — Loading UI
- `it('shows empty state when no data')` — Empty/no-results UI
- `it('displays error state on failure')` — Error handling
- `it('handles form submission')` — User interaction (with userEvent)
- `it('responds to user events')` — Clicks, input changes

### Enhanced Skeleton with Testing Library

```typescript
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ComponentName } from './ComponentName';

describe('ComponentName', () => {
  it('renders without crashing', () => {
    render(<ComponentName />);
    expect(screen.getByRole('button')).toBeInTheDocument();
  });

  it('displays expected content', () => {
    render(<ComponentName title="Test Title" />);
    expect(screen.getByText('Test Title')).toBeInTheDocument();
  });

  it('shows loading state while data fetches', () => {
    render(<ComponentName isLoading />);
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it('shows empty state when no data', () => {
    render(<ComponentName items={[]} />);
    expect(screen.getByText(/no items/i)).toBeInTheDocument();
  });

  it('displays error state on failure', () => {
    render(<ComponentName error="Something went wrong" />);
    expect(screen.getByText('Something went wrong')).toBeInTheDocument();
  });

  it('handles form submission', async () => {
    const user = userEvent.setup();
    const mockSubmit = vi.fn();
    render(<ComponentName onSubmit={mockSubmit} />);

    const input = screen.getByRole('textbox');
    await user.type(input, 'test value');
    await user.click(screen.getByRole('button', { name: /submit/i }));

    expect(mockSubmit).toHaveBeenCalledWith('test value');
  });

  it('responds to user events', async () => {
    const user = userEvent.setup();
    render(<ComponentName />);

    const button = screen.getByRole('button');
    await user.click(button);

    expect(screen.getByText(/clicked/i)).toBeInTheDocument();
  });

  // Optional: theme support — theming is global html[data-theme] token
  // switching per _v-design.md § Canonical Token Set. Never test for a
  // `.dark` class or an isDarkMode prop: that locks the implementation
  // into a theming mechanism the design system BLOCK-gates. The theme is
  // page-level state, so the only component-level assertion that makes
  // sense is "renders correctly with the attribute set" — reuse the same
  // query the render test above uses.
  afterEach(() => {
    document.documentElement.removeAttribute('data-theme');
  });

  it('renders under the dark theme', () => {
    document.documentElement.setAttribute('data-theme', 'dark');
    render(<ComponentName />);
    // same accessible query as the base render test — the component
    // consumes var(--token) styles, so no theme-specific class exists
    expect(screen.getByRole('button')).toBeInTheDocument();
  });
});
```

### Hook Testing Pattern

For custom hooks, use `renderHook` from Testing Library:

```typescript
import { renderHook, act } from '@testing-library/react';
import { useCustomHook } from './useCustomHook';

describe('useCustomHook', () => {
  it('returns initial state', () => {
    const { result } = renderHook(() => useCustomHook());
    expect(result.current.value).toBe(0);
  });

  it('updates state on action', () => {
    const { result } = renderHook(() => useCustomHook());

    act(() => {
      result.current.increment();
    });

    expect(result.current.value).toBe(1);
  });
});
```
