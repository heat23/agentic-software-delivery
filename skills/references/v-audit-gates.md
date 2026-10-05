# v-audit-gates — Shared verification gates for audit skills

_Last reviewed: 2026-07-06 (theme-consistency sweep A: SEO/AEO + growth-motion + copy/voice alignment; prev 2026-07-06)._

Audit skills (`v-audit-admin`, `v-audit-analytics`, `v-audit-growth`,
`v-audit-messaging`, `v-audit-sales-pricing`, `v-audit-seo`) MUST
apply these gates before declaring an audit complete. Adapted from
v-ui-audit v3.8.5 (retired 2026-07-06) — the most-iterated audit
skill in this library's history.

**`v-audit-code` does not run these gates.** It absorbed
`v-ui-audit`'s deep UX/a11y depth into
`v-audit-code/references/deep-ux-audit.md`, but it is a
flexible-framework audit (`rating-framework.md`: "no mandated
category list or scale") with no per-dim numbered checklist — so
there is no Gate 0 per-dim exploration block, no Gate 2 per-dim
floor + mandatory re-task loop, and no numbered-gate sequence to
apply. `v-audit-code` still verifies its own work (citation
discipline, evidence-before-claim, artifact-existence checks before
methodology) — see its SKILL.md's own guardrails and workflow steps —
just not through these numbered Gates 0/1/2/8. It appears in the
calibration table below only because its `v-audit-floors.md` table is
retained as historical reference data; treat that row as
non-enforcing.

**How to use this file:** each skill's SKILL.md adds one line
under its verification/output section: *"Apply Gates 0, 1, 2, and 8 from
`~/.claude/skills/references/v-audit-gates.md`."* The skill
inherits these gates without duplicating their bodies.

---

## Gate 0 — "Show your work" (per-dim exploration block)

Every subagent / dimension run MUST include an exploration block
listing what was actually read and grepped. The block is rejected
if it lacks evidence; the subagent is re-tasked with the specific
missing investigations called out.

### Required output format

After producing findings for a dimension, the subagent appends:

```markdown
## Per-dim exploration

### Dim {N} — {name}
- **Files read:** `path1`, `path2`, `path3`, ... (paths only; full
  reads, not glances)
- **Greps run:**
  - `grep -rn "pattern1" {dir}/` → N hits, key result line: "..."
  - `grep -rn "pattern2" {dir}/` → 0 hits (verified absent)
- **Verifications done:**
  - "Verified Route::fallback exists in routes/web.php:42"
  - "Confirmed analytics catalog at lib/analytics.ts has 48 events"
```

If the per-dim block is missing or substantially empty, **the
finding set for that dim is rejected** and the subagent re-tasked
with: *"Your return omitted the per-dim exploration block.
Re-investigate dim {N}: list every file you read, every grep you
ran, and every verification you performed. Then re-submit
findings."*

### Hallucination spot-check (orchestrator-side)

The orchestrator picks 2 random `path:line` citations per
subagent's findings and verifies the cited line actually contains
content matching the finding's description (use `Read` tool on the
exact lines).

- Both spot-checks match → subagent passes Gate 0.
- 1 of 2 doesn't match → re-task with: *"Citation {X} at
  {file:line} was checked; the line does not contain what your
  finding describes. Re-verify all your citations and drop any
  that don't hold."*
- 2 of 2 don't match → that subagent's entire return is rejected
  as fabricated. Methodology emits: *"Subagent {X} failed Gate 0
  hallucination spot-check. Findings dropped. Coverage on dims
  {list} is unverified — recommend manual review."*

### Anti-hallucination on the exploration block itself

The same anti-hallucination rule that applies to findings ALSO
applies to the per-dim exploration block:

- Files listed as "read" must produce at least one file:line
  citation in the subagent's findings, OR an explicit "no
  findings surfaced from {file}" line — proving the file was
  actually opened.
- Greps listed as "run" must include the actual hit count and at
  least one quoted result line if hits > 0.
- Verifications must cite the file:line that was checked.

---

## Gate 1 — Citation format parseability

Every finding MUST cite at least one `path:line` location. The
citation format is parseable when it matches one of:

- Plain form: `path/to/file.ext:42` or `path/to/file.ext:42-50`
  (single line or multi-line range)
- Clickable form: `[path/to/file.ext:42](path/to/file.ext#L42)` or
  `[path/to/file.ext:42-50](path/to/file.ext#L42-L50)` (preferred —
  see "Output conventions" in each skill's body)

### Verification

```bash
# Pseudo-grep — find findings missing parseable citations
grep -nE '^[[:space:]]*-[[:space:]]+\[' {audit-output} \
  | grep -vE '\[?[A-Za-z0-9._/-]+\.[a-z]+:[0-9]+'
```

If a finding has no `path.ext:N` substring (in either plain or
clickable form), it fails Gate 1 and is **dropped** — not reported,
not even at Low severity. This is consistent with v-ui-audit's
v3.8.5 rule: "Findings without `:N` line numbers get DROPPED."

### Anti-hallucination tie-in

Gate 1 only checks parseability. Gate 0's spot-check verifies the
cited line actually exists and contains relevant content. Both
gates are required — a finding can be parseably-cited but
fabricated, OR genuinely-rooted but mis-formatted. Gates 0+1
together close both holes.

## Gate 2 — Per-dim minimum-findings floor with mandatory re-task

Each audit skill defines a minimum-findings floor per dim
(documented in that skill's checklist or briefing). Returns below
floor are not silently accepted.

**Motion-gate interaction (applies to every step below):** when a dim is
motion-gated (`~/.claude/skills/references/v-core-solo-motion.md`, e.g.
v-audit-sales-pricing Dims 3/5 under `OUTBOUND_OK=0`), `"correctly absent
— zero-outreach motion"` statuses count toward the floor exactly like
findings, and every re-task / depth-booster prompt inherits the motion
gate verbatim. Gate 2 must never pressure a subagent into fabricating
out-of-motion findings to clear a floor — that outcome is a P0 per
v-core-solo-motion.md § Note for reviewers, worse than the floor miss
itself.

### Process (in order)

**Step 1 — MANDATORY re-task.** When a dim returns below floor:
re-task the subagent with the dim's specific checklist as a
✅/⚠️/❌ tick-list AND any required investigations from the skill's
own briefing. Auto-justification is FORBIDDEN until a re-task has
been attempted. Skipping straight to auto-justify fails Gate 2
hard — the audit cannot ship.

**Step 2 — Single auto-justification cap.** At most ONE dim per
audit may use floor-miss auto-justification. If 2+ dims would
qualify after re-task: pick the dim with the smallest
delta-from-floor for auto-justification; re-task every other
below-floor dim a second time using a depth-booster prompt that
explicitly cites high-leverage findings the dim hasn't yet
surfaced. If a dim still fails after the second re-task,
methodology emits *"Dim X coverage limited; recommend manual
review"* — NOT the auto-justify line.

**Step 3 — Floor-miss auto-justification (anchored to Gate 0).**
If after Steps 1-2 the count is still below floor on exactly one
dim, methodology emits:

```
Dim {N} returned {found} findings against a {floor} floor. The
under-floor return is justified by {operator-light coverage |
project's strong baseline on this dim}. Per Gate 0 the subagent's
per-dim exploration block confirmed full required-investigation
coverage:
- Files read: {N} files (listed in subagent return)
- Greps run: {M} required investigations (listed in subagent
  return), each reporting hit count
No additional findings surfaced after re-task. Coverage is
complete; the floor miss reflects project state, not investigation
shallowness.
```

The Gate 0 exploration block IS the falsifiable evidence. Operators
can audit the listed greps to verify.

---

## Gate 8 — File-existence verification before methodology

Audit skills produce one or more output artifacts (JSON,
Markdown, dashboard HTML, prompts folder). The methodology block
MUST NOT claim "phase ran" without verifying the output exists.

### Process

After each artifact phase completes, BEFORE writing the
methodology block, verify each expected file exists using the
**Glob tool** (preferred — returns empty array on miss,
unambiguous). Use `Read` or bash `ls` as fallback only if Glob
unavailable.

For each expected artifact:

```bash
# Example for an audit producing JSON + prompts
ls audits/{skill-name}_REPORT_${TIMESTAMP}.json    # or .md
ls .v-prompt-packs/{skill-name}/00-README.md
ls audits/{skill-name}_REPORT_${TIMESTAMP}.html    # if dashboard mode
```

Or via Glob:

```
.v-prompt-packs/{skill-name}/*.md
audits/{skill-name}_REPORT_*.{json,md,html}
```

### Methodology block requirement

For every artifact the skill is supposed to produce, methodology
MUST include a one-line status entry:

```
- {Artifact name}: {one of}
  - "Generated at {path} — verified by Glob/Read"
  - "Not generated this run. Specific reason: {budget exhausted
    after writing X / write error / Phase N produced 0 items / ...}"
  - "Partially generated: {N} of {M} expected files written.
    Reason: {specific}"
```

### Forbidden methodology language (Gate 8 violations)

These phrases are HARD FAILURES — the audit cannot ship if any
appear in methodology:

- "All phases ran" without per-artifact verification entries
- "Phase {6/7} follow" / "are documented as separate file outputs
  in chat summary" / "will be generated next" — these are the lie
  patterns observed in a past v-ui-audit run
- Any "phases skipped: none" claim that isn't backed by file
  existence checks
- Vague "context budget" as a skip reason — must cite what the
  budget was actually spent on (e.g., "writing 128KB markdown
  report")

### Silent skip is FORBIDDEN

If an artifact phase doesn't produce its expected file, methodology
MUST emit a specific reason. Acceptable reasons:

- "Phase {N} produced 0 items (audit found nothing material)" — rare
- "audits/ directory is read-only or write failed" — log the
  filesystem error
- "Budget exhausted; pack truncated to N files" — log how many
  files made it
- "Skipped per orchestrator decision: {specific reason}"

A silent skip without methodology entry is itself a hard Gate 8
failure. Re-run the artifact phase OR add the methodology line
before shipping.

---

## How to apply these gates in your skill

Add this line to your skill's SKILL.md under its verification or
output section:

> **Verification gates:** Apply Gates 0, 1, 2, and 8 from
> `~/.claude/skills/references/v-audit-gates.md` before declaring
> the audit complete. Gate 0 enforces "show your work" with
> hallucination spot-check; Gate 1 enforces citation-format
> parseability; Gate 2 enforces per-dim floors with mandatory
> re-task before auto-justification; Gate 8 enforces
> file-existence verification before methodology emission.

Define your skill's per-dim floors and required investigations
in the skill's own body (or its `references/checklist.md` if
present). The gates above operate on those floors.

---

## Skill-specific calibration table

Each audit skill should declare its per-dim floor and key
required investigations in its own SKILL.md or references/. The
table below summarizes current floors (as of 2026-04-29):

| Skill | Heavy dims | Default floor (mature) | Light/skip dims | Floor table |
|---|---|---|---|---|
| v-audit-code — **NOT Gate-2-enforced** (deep UX/a11y mode absorbed from retired v-ui-audit 2026-07-06; row kept for cross-reference only) | n/a — no live per-dim checklist | n/a | n/a; a11y + Security-UI are non-demotable compliance floors enforced in PROSE via `deep-ux-audit.md` § "Compliance floors (non-demotable in deep-UX mode)", not via a numeric floor | `v-audit-floors.md` § `## v-audit-code floors (historical calibration, not enforced)` — historical `v-ui-audit` numbers, not a runtime lookup target |
| v-audit-admin | 1, 5, 6 | 5-6 by dim | 2, 3, 4 (— at Early) | `v-audit-floors.md` § `## v-audit-admin floors` |
| v-audit-seo | 1, 2, 3, 7 | 3-4 by dim | 4, 5, 6, 8, 9 | `v-audit-floors.md` § `## v-audit-seo floors` |
| v-audit-messaging | 1, 2, 4, 5, 6 | 3 (default rows) | 3 (Features), 7 (Cross-Surface — degrades) | `v-audit-floors.md` § `## v-audit-messaging floors (first iteration)` |
| v-audit-sales-pricing | 1, 6, 7, 8, 10 | 3 (default rows) | 2, 3, 4, 5, 9 | `v-audit-floors.md` § `## v-audit-sales-pricing floors (first iteration)` |
| v-audit-analytics | 1, 2, 3, 6 (provisional) | 3 (default rows) | 4, 5 | `v-audit-floors.md` § `### v-audit-analytics (provisional)` |
| v-audit-growth | 1, 2, 4 (provisional) | 3 (default row) | 3 (Feedback Loops) | `v-audit-floors.md` § `### v-audit-growth (provisional)` |
| v-check | 1, 2, 3, 5, 8, 12 (provisional; Dim 5 promoted to HEAVY for AI-built code) | 3 (default-priority dim floor — Dims 4, 6, 11) | 7, 9 (LIGHT — triage / full-mode-only); 10 (— process domain, no findings) | `v-audit-floors.md` § `## v-check floors (provisional)` |

**Floor-table lookup convention:** every audit skill declares
its floor table in `~/.claude/skills/references/v-audit-floors.md`.
The "Floor table" column above gives the exact section header to
match — Gate 2 enforcement scans for that header to load the
right table at runtime.

**Provisional vs first-iteration vs calibrated:**
- *Provisional* (v-audit-analytics, v-audit-growth, v-check) — values are
  conservative defaults; promote after ≥3 audits.
- *First iteration* (v-audit-messaging, v-audit-sales-pricing) —
  per-dim values set from priority + expected finding density;
  promote after ≥3 audits show stability.
- *Calibrated* (v-audit-admin, v-audit-seo) — values derived from
  observed audit history.

These three states activate Gate 2 enforcement for the 6 skills that
run it. **`v-audit-code` is a fourth, separate state — historical —
and does not activate Gate 2 enforcement at all**; its table in
`v-audit-floors.md` is retired `v-ui-audit` calibration data kept for
reference, not a live floor.
