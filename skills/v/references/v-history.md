# /v Orchestrator — Production History (DESCOPED)

**Status:** descoped after Round 3 adversarial review (2026-05-11).

## Why this file is intentionally empty

Round 3's audit identified ~6 historical anecdotes in SKILL.md (e.g., "Production
motivation (Session XXX, 2026-MM-DD)") and planned to extract them here to reduce
cognitive load on every `/v` invocation.

Closer inspection during implementation showed every candidate anecdote is
immediately followed by a `**Rule:**` or `**Correct pattern:**` paragraph that
DEPENDS on the anecdote for concrete grounding:

- A production-session citation (SKILL.md line 975) → anchors W47-F1 SID resolution rule
- A production-session citation (SKILL.md line 1796) → anchors "subagent attribution must be
  verified" rule
- A production-session citation (SKILL.md line 1868) → anchors "check reflog before blaming
  hooks" rule
- A production-session citation (SKILL.md line 1812) → W51 retraction; teaches hostile-review-
  of-findings pattern

Extracting these would either (a) leave the adjacent rule paragraphs un-anchored,
or (b) require duplicating the rule logic here. Neither is a net win.

The two W25-F11 session citations (referenced in CRITICAL ROLE CONTEXT)
are kept inline as 1-line proof-of-concrete; they are not anecdote prose, just
session citations.

If a future audit identifies anecdotes that are TRULY standalone war-stories with
no adjacent rule dependency, this file is the right destination for them.
