# Finding Enrichment Contract (produced during the audit pass)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

This contract defines four optional fields that audit skills may include on
each finding in their JSON output. These fields enable a downstream
cost-optimized remediation pipeline:

- **Patch-only findings** are applied mechanically without any model call.
- **Haiku-routed findings** run on the cheap model with a narrow execution
  contract, gated by the detection command.
- **Sonnet-routed findings** use the full reasoning model.

Since audit skills already hold the full finding context, populating these
fields during the audit pass is the cheapest way to enable the downstream
optimization — the reasoning work is done once, at review time, and every
remediation that follows reuses it.

## Four Optional Finding Fields

Audit skills may add these keys to each finding object in their JSON output.
All four are optional; when omitted, remediation falls back to the full
Sonnet flow (current behavior).

### `patch` (string, optional)

A unified diff that, when applied with `git apply` against the target
file(s), implements the fix deterministically. Only include this when the
fix is 100% mechanical — no judgment call, no cross-file reasoning, no
choice between alternatives.

**Include a patch for:**
- Missing null / undefined guards on a single expression
- Typos in strings, comments, or identifier names
- Missing imports (when the import path is unambiguous)
- Missing type annotations (when the type is trivially inferable)
- Unused variable / import removal
- Simple single-identifier renames within one file
- Adding a missing `await`, semicolon, or explicit cast
- Adding a missing DOMPurify.sanitize() wrap around an existing sanitize call

**Do NOT include a patch for:**
- Refactors, logic changes, or new functions
- Cross-file changes
- Changes that require choosing between alternatives
- Any fix where the correct code depends on context not shown in the evidence

The patch MUST be in unified-diff format valid for `git apply`, with correct
file paths (relative to repo root) in the `--- a/` and `+++ b/` headers.

### `detection` (string, optional)

A shell command that exits 0 when the finding is **FIXED** (the bad pattern
is no longer present) and non-zero when the finding is still present.
Required when `patch` is provided. Recommended for all haiku-routed
findings so the persistence gate can re-verify the fix.

Examples:
- `! grep -q "dangerouslySetInnerHTML" app/foo.tsx`
- `! rg -q "TODO|FIXME" app/bar.php`
- `php -l app/baz.php >/dev/null`
- `grep -q "DOMPurify.sanitize" app/qux.tsx`

The command runs with the repo root as cwd. Keep it fast (<2s) and
side-effect-free. Do not chain detection commands with `&&` or `;` — one
command per finding.

### `complexity` (string, optional)

Model routing hint. Valid values:

- **`"patch"`** — Fix is a deterministic patch. Include a `patch` field.
  The remediation pipeline applies this without any model call.
- **`"haiku"`** — Fix is small and prescriptive but requires writing code,
  not applying a pre-baked diff. Include a step-by-step `implementation`
  field with exact files, exact edits, and a detection command. The pipeline
  runs this on Haiku via /v-build-narrow with a strict scope contract.
- **`"sonnet"`** — Fix requires reasoning, multi-file changes, or judgment.
  The pipeline runs this on Sonnet via full /v-build (default fallback).
- **`""`** or absent — treated as `"sonnet"` (safe default).

**Decision rule:** Default to `"sonnet"` unless you are highly confident the
fix fits the `"patch"` or `"haiku"` criteria. A misclassification costs one
retry; always defaulting to `"sonnet"` costs the weekly rate limit. When in
doubt, pick the higher-complexity bucket.

### `hostile_counter` (string, optional)

Adversarial counter-analysis. A brief statement of what would make this
finding wrong or a false positive — the strongest argument against acting
on it. The remediation pipeline uses this to decide whether to execute,
downgrade, or reject the finding.

This is populated during the same review pass that produces the
finding. It replaces a separate hostile-review step that would otherwise
run as a later dispatch.

Example:
- Finding: "Missing CSRF token on form submit"
- `hostile_counter`: "Could be a false positive if the route is explicitly in
  the CSRF-exempt list (check config/csrf.php) or is a public API endpoint
  that uses a different auth scheme."

Keep it to 1-3 sentences. Not a full analysis — just the strongest
counter-argument a reviewer could make.

## Example Enriched Finding

```json
{
  "finding_id": "SEC-001",
  "title": "Missing DOMPurify.sanitize on AI-generated HTML",
  "severity": "P1",
  "category": "security",
  "evidence": "resources/js/Pages/BlogPost.tsx line 42 uses dangerouslySetInnerHTML with raw AI output",
  "files": ["resources/js/Pages/BlogPost.tsx"],
  "implementation": "STEPS:\n1. Open resources/js/Pages/BlogPost.tsx\n2. Find line 42: `dangerouslySetInnerHTML={{ __html: post.content }}`\n3. Replace with: `dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(post.content, { ALLOWED_TAGS: [...] }) }}`\n4. Add `import DOMPurify from 'dompurify'` at the top of the file if not already present\n\nDO NOT:\n- Skip the allowlist (ALLOWED_TAGS) — an empty config is unsafe\n- Call sanitize on a variable that's already been sanitized upstream",
  "detection": "grep -q 'DOMPurify.sanitize' resources/js/Pages/BlogPost.tsx",
  "complexity": "haiku",
  "hostile_counter": "Could be a false positive if post.content is already sanitized upstream in the controller (check app/Http/Controllers/BlogController.php); in that case the fix is documentation, not code."
}
```

## Backwards Compatibility

Audit skills that do not populate these fields continue to work. Findings
without enrichment fields default to:
- `patch`: empty → no patch applier path
- `detection`: empty → no persistence gate, Haiku success assumed
- `complexity`: empty → routed to Sonnet (safe default)
- `hostile_counter`: empty → no counter-argument, finding executed as-stated

The ecosystem-review-runner Python models (`ecosystem_runner/models/finding.py`)
and normalizer (`ecosystem_runner/review/normalizer.py`) accept these fields
when present and ignore their absence.
