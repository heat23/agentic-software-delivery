# AI Test Anti-Patterns — REDIRECT STUB

_Last reviewed: 2026-07-05_

This file is a redirect.

**Canonical catalog (shared with `/v-verify-done`):**
```
~/.claude/skills/references/v-tdd-anti-patterns.md
```

## Why

`/v-tdd` used to ship two anti-pattern catalogs (this file, plus the global one). They drifted over time, creating a regression risk: v-tdd could generate tests matching one catalog while `/v-verify-done` rejected them under the other.

Tier-1 fix (2026-05-18): designate the global file as canonical. This file is a stub that exists only to prevent broken pointers from older `/v-tdd` versions or external skills that linked here.

## What to do

Open `~/.claude/skills/references/v-tdd-anti-patterns.md` for the full anti-pattern catalog (definitions, detection patterns, and re-task prompts). That file's own completeness contract is the authoritative entry count — do not restate a number here (it drifts when entries are added/removed).

The full historical version of this file is preserved at `~/.claude/skills/v-tdd/.attic/anti-patterns-full-<timestamp>.md` for reference only — do NOT load it; it may have drifted from the canonical version.
