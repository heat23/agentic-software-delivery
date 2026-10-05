# v-* orchestrator map

_Last reviewed: 2026-08-02 (full resync: every Tier 1-3 "Loaded by" cell and
the dispatch graph were broadly stale — several 2026-07/08 skills
(`v-activation-funnel-design`, `v-anti-template-gauntlet`, `v-differentiate`,
`v-illustration-system`, `v-launch`, `v-launch-channels`, `v-prelaunch-readiness`,
`v-pricing-design`, `v-traffic`, and the `/v` orchestrator itself) were absent
from every table they actually belong in, `_v-design.md`/`_v-growth.md` rows
were missing roughly half their real consumers, `v-verify-done` was missing
from `_v-review.md`'s roster despite Follow-declaring it, and Tier 3's
`_v-audit.md` row claimed "20 SKILL.md files" — a count of any file that
merely *mentions* `_v-audit.md`, not one that loads it; the real number of
skills that actually load it is 15 (9 full-bundle + 6 opener-only opt-ins).
All rosters below were re-derived mechanically from disk — see § Maintenance
for the exact command, which is now hardened against the `Follow[^.]*`
period-truncation trap (proof included) and tested against real true-positive
and true-negative cases. Prior: 2026-08-02 earlier same-day pass fixed the
`v-help` and `v-audit-*`-bundle-count claims specifically but left the
broader rosters stale — this pass is the deferred full resync it called for.
Adversarial-review addendum, same day: the `_v-audit.md`/`_v-review.md`
char-count parentheticals in the Tier 3 table were stale by 2x/1.44x
(`wc -c` verified: 29,039 / 31,772 actual vs. `~13k`/`~22k` claimed) — this
full-resync pass re-derived every roster and count in the table except
these two char counts, which sat unchecked next to the numbers it did
verify; corrected)._

> **Purpose:** document the 13 `_v-*` orchestrator files in
> `~/.claude/skills/`, each one's responsibility, the skills that
> consume it, and the runtime contract it provides. The
> orchestrators are shared modules that v-* skills `Follow` to
> get cross-cutting policy without inline duplication.
>
> **Audience:** future-you (or any agent) trying to understand
> which orchestrator owns what. Updated when an orchestrator
> changes responsibility or a new one is added.

## Loading convention

There are exactly two idioms on disk that count as a real load. Anything
else — a bare filename mention, a prose citation ("hostile elevation in
`_v-review.md`"), a glossary/reference table entry, or a non-`Follow`
path form like `` `~/.claude/skills/_v-audit.md` § Step 3 `` — is a
**citation**, not a load, and must NOT be counted in the "Loaded by"
rosters below (this is the exact mistake the 2026-08-02 resync fixed).

**Idiom A — bundle load (all 13 orchestrators use this):**

```
Follow `_v-core.md`, `_v-exec.md`, `_v-review.md` ...
```

**Idiom B — `_v-audit.md` opener-only opt-in (this file only; a narrower
load than Idiom A — it pulls in only the PROJECT_ROOT/V_DEPTH/task-list
opener subset, not the full audit-family workflow):**

```
**Audit opener:** see `_v-audit.md` § Audit Skill Opener
```

The orchestrator names are paths relative to `~/.claude/skills/`.
Skills load them implicitly — there's no `import` statement; the
agent reading the SKILL.md is expected to also read the
referenced orchestrators before executing the skill.

## Tier 1: Core orchestrators (every v-* skill loads these)

These two govern the universal contracts that every v-* skill
must follow.

| File | Owns | Loaded by |
|---|---|---|
| `_v-core.md` (~30k chars) | Progressive disclosure rule, core skill rule, skill-boundary contract, skill-authoring hygiene, audit-domain ownership table, volatile-knowledge contract, user-owned-maintenance scope, tier glossary | **48 of 52 skills** (all 51 `v-*` skills plus `/v` itself), verified 2026-08-02 — see § Maintenance to reconfirm. **Decision rule** (matches `__tests__/v-skill-linter.test.ts:429-447`): required for every skill whose contract `tier` is `orchestration-primitive`, `user-facing`, or `orchestrator`. **4 exceptions**, each for a disk-verifiable reason: `v-help` (tier `user-facing`, but self-declares "No shared modules required" at `v-help/SKILL.md:18` — its "Shared modules" table is a reader glossary, not a load); `v-audit-code` (tier `specialized`, exempt by tier — uses inline `` `§` ``-references only, no `Follow` bundle); `v-forensics`, `v-forensics-pack-runner` (tier `comprehensive`, exempt by tier — standalone read-only forensic post-mortem tools with zero `_v-*.md` references of any kind) |
| `_v-exec.md` (~16k chars) | Progressive disclosure, user-owned-maintenance scope, worktree safety (parallel-session rules), trust boundary, AI-autonomous safety gates, shell safety, atomic edit rule, capability detection | **45 of 52 skills**, verified 2026-08-02. **Decision rule** (matches `__tests__/v-skill-linter.test.ts:449-462`): required only for `tier` ∈ {`orchestration-primitive`, `orchestrator`} — note this is a NARROWER set than `_v-core.md`'s; `user-facing` tier is exempt from the `_v-exec.md` requirement. **7 exceptions**: the same 4 as `_v-core.md` above, plus `v-prompt-pack-generate` and `v-self-audit` (both tier `user-facing`, legitimately exempt) and `v-session-log`, which Follows `_v-core.md` only despite being tier `orchestration-primitive` — by this file's own stated rule that tier should require `_v-exec.md` too; flagged here rather than silently folded into the clean exemptions, not fixed (outside this file's scope — `v-session-log/SKILL.md` isn't owned by this pass) |
| `_v-core-runtime.md` (auto-generated mirror) | Runtime-loadable subset of `_v-core.md` — extracted by `~/.claude/scripts/generate-runtime-skill-docs.sh` from `<!-- runtime -->…<!-- end-runtime -->` blocks | Hooks + runtime tooling that need a smaller load. **0 skills `Follow` it** (verified 2026-08-02) — no `SKILL.md` should ever gain a `Follow` reference to this file; it is consumed by the generator script, not by skills |

**Convention:** `_v-core.md` is the canonical source; `_v-core-runtime.md` is auto-generated. Edit only `_v-core.md`.

## Tier 2: Domain orchestrators (loaded conditionally)

These govern policy for specific domains. Skills load them when their work touches that domain.

| File | Owns | Loaded by (verified 2026-08-02 — see § Maintenance) |
|---|---|---|
| `_v-api.md` | Endpoint naming, response envelope, error response shape, pagination strategy, versioning, rate limiting, auth, input validation | **2:** `v-build`, `v-scaffold` (when API endpoints are involved) |
| `_v-design.md` | Runtime-critical quality bar, design-token discovery order, AI-generic-pattern detection, context sensitivity, visual-craft gate, spacing progression, color contrast (WCAG), z-index layers | **19:** `/v`, `v-activation-funnel-design`, `v-anti-template-gauntlet`, `v-audit-admin`, `v-audit-messaging`, `v-build`, `v-check`, `v-content-create`, `v-differentiate`, `v-illustration-system`, `v-interactive-showcase`, `v-launch-channels`, `v-marketing-design`, `v-new-feature`, `v-plan`, `v-polish`, `v-prelaunch-readiness`, `v-pricing-design`, `v-scaffold` |
| `_v-growth.md` | Growth audit entry point, growth hook + JSON schema, funnel-stage reference | **24:** `/v`, `v-activation-funnel-design`, `v-audit-analytics`, `v-audit-growth`, `v-audit-messaging`, `v-audit-sales-pricing`, `v-audit-seo`, `v-beta-program`, `v-build`, `v-check`, `v-content-create`, `v-content-ops`, `v-differentiate`, `v-docs`, `v-interactive-showcase`, `v-launch`, `v-launch-channels`, `v-marketing-design`, `v-new-feature`, `v-plan`, `v-polish`, `v-pricing-design`, `v-tdd`, `v-traffic` |
| `_v-jobs.md` | Job design rules, idempotency principle, retry policy, dispatch-after-commit pattern, dead-letter handling, timeout protection, queue selection, job testing | **2:** `v-build`, `v-scaffold` (when async jobs are involved) |
| `_v-security.md` | Authentication baseline, authorization baseline, input validation, output encoding, SQLi prevention, CSRF protection, file upload safety, secrets management | **1:** `v-build` (loaded for any security-sensitive change) |

## Tier 3: Cross-cutting orchestrators

These govern shared concerns across multiple skill families.

| File | Owns | Loaded by (verified 2026-08-02 — see § Maintenance) |
|---|---|---|
| `_v-audit.md` (~29k chars — corrected 2026-08-02; the `~13k` figure was stale by more than 2x, `wc -c` verified) | Audit-skill opener bundle (PROJECT_ROOT + V_DEPTH + TodoWrite — see § Audit Skill Opener), consolidation/batch mode contract, mandatory execution workflow pattern, Step 3 prompt-generation contract, Step 3.5 JSON validation, Step 4 post-generation validation, error handling | **15 total — NOT "20 SKILL.md files"** (that prior figure counted any file that merely *mentions* `_v-audit.md`, including pure prose citers like `v-check`, `v-content-ops`, `v-differentiate`, `v-skill-reviewer`, and `v-audit-code`, none of which load it — see § Loading convention). The real 15 split into two idioms: **9 full-bundle (`Follow` — Idiom A):** `v-audit-admin`, `v-audit-analytics`, `v-audit-consolidate`, `v-audit-growth`, `v-audit-messaging`, `v-audit-orchestrator`, `v-audit-sales-pricing`, `v-audit-seo`, `v-bug-hunt`. **6 opener-only opt-ins (Idiom B — non-audit-family skills that load only § Audit Skill Opener, not the full workflow):** `v-activation-funnel-design`, `v-anti-template-gauntlet`, `v-beta-program`, `v-illustration-system`, `v-prelaunch-readiness`, `v-pricing-design`. `v-audit-orchestrator`, though full-bundle, likewise uses only § Audit Skill Opener in practice, not the full Mandatory Execution Workflow |
| `_v-review.md` (~32k chars — corrected 2026-08-02; the `~22k` figure was stale by ~44%, `wc -c` verified) | Section index, FINDING_FORMAT, FINDING_FORMAT_JSON, confidence calibration, finding-deduplication protocol, review rules, agent-dispatch protocol, hostile-context input contract | **29:** `/v`, `v-activation-funnel-design`, `v-anti-template-gauntlet`, `v-audit-admin`, `v-audit-analytics`, `v-audit-consolidate`, `v-audit-growth`, `v-audit-messaging`, `v-audit-orchestrator`, `v-audit-sales-pricing`, `v-audit-seo`, `v-beta-program`, `v-bug-hunt`, `v-build`, `v-check`, `v-differentiate`, `v-docs`, `v-illustration-system`, `v-launch`, `v-maintenance`, `v-marketing-design`, `v-next`, `v-polish`, `v-prelaunch-readiness`, `v-pricing-design`, `v-prod-triage`, `v-skill-reviewer`, `v-traffic`, `v-verify-done` — note `v-verify-done` Follow-declares this at `v-verify-done/SKILL.md:306`, previously omitted from this file's dispatch graph. NOT `v-help`, which loads no shared modules |
| `_v-review-runtime.md` (auto-generated mirror) | Runtime-loadable subset of `_v-review.md` | Hooks + runtime tooling. **0 skills `Follow` it** (verified 2026-08-02), same reasoning as `_v-core-runtime.md` above |
| `_v-artifact-formats.md` | Canonical artifact format contracts, registered artifact types, AGENT_REVIEW carve-outs, provenance fields, anti-pattern: skipping inline spec | Skill authors writing dispatch prompts (haiku agents see inline spec, not this file directly). **0 skills `Follow` it** (verified 2026-08-02) — by design; it documents a spec other files must inline, not a bundle a skill loads wholesale |

**Convention:** `_v-review.md` is the canonical source; `_v-review-runtime.md` is auto-generated. Edit only `_v-review.md`.

## Tier 4: Documented Fallback Anchors

| File | Status | Notes |
|---|---|---|
| `_v-resilience.md` | Active (fallback protocol) | Documents the orchestrator's actual conservative-path + BLOCKED_<sid>.md behavior. No autonomous crash recovery; no triage matrix. Section anchors here exist so cross-references in `_v-core.md` and other shared modules resolve cleanly. |

## Dispatch graph

Grouped by exact Follow-signature (the set of modules a skill loads), not
listed one-skill-per-line — with 52 skills that's the only form of this
graph that won't be stale again within a month. Regenerate with the
grouping script in § Maintenance; do not hand-add a skill to a group by
eye — re-run the script and paste its output wholesale (a skill's actual
signature may not match the group you'd guess). Verified 2026-08-02, 52
skills total (51 `v-*` skills + `/v` itself), 17 distinct signatures:

| Modules (in Follow order) | Count | Skills |
|---|---|---|
| `_v-core`, `_v-exec` | 8 | `v-build-narrow`, `v-ci-fix`, `v-discover-features`, `v-handoff`, `v-legal-docs-generate`, `v-merge-all`, `v-pre-flight`, `v-setup-project` |
| `_v-core`, `_v-exec`, `_v-design`, `_v-growth` | 5 | `v-content-create`, `v-interactive-showcase`, `v-launch-channels`, `v-new-feature`, `v-plan` |
| `_v-core`, `_v-exec`, `_v-review` | 5 | `v-maintenance`, `v-next`, `v-prod-triage`, `v-skill-reviewer`, `v-verify-done` |
| `_v-core`, `_v-exec`, `_v-review`, `_v-design`, `_v-growth` | 5 | `v-check`, `v-differentiate`, `v-marketing-design`, `v-polish`, `/v` (the orchestrator itself) |
| *(none)* | 4 | `v-audit-code` (specialized tier, inline `` `§` ``-references only), `v-forensics`, `v-forensics-pack-runner` (comprehensive tier, standalone read-only tools), `v-help` (user-facing tier, explicit self-exemption at `v-help/SKILL.md:18`) |
| `_v-core`, `_v-exec`, `_v-audit`, `_v-review`, `_v-growth` | 4 | `v-audit-analytics`, `v-audit-growth`, `v-audit-sales-pricing`, `v-audit-seo` |
| `_v-core` only | 3 | `v-prompt-pack-generate`, `v-self-audit`, `v-session-log` |
| `_v-core`, `_v-exec`, `_v-audit`, `_v-review` | 3 | `v-audit-consolidate`, `v-audit-orchestrator` (opener subset only, no `_v-growth`), `v-bug-hunt` |
| `_v-core`, `_v-exec`, `_v-review`, `_v-design`, `_v-audit` (opener-only) | 3 | `v-anti-template-gauntlet`, `v-illustration-system`, `v-prelaunch-readiness` |
| `_v-core`, `_v-exec`, `_v-review`, `_v-growth` | 3 | `v-docs`, `v-launch`, `v-traffic` |
| `_v-core`, `_v-exec`, `_v-growth` | 2 | `v-content-ops`, `v-tdd` |
| `_v-core`, `_v-exec`, `_v-review`, `_v-design`, `_v-growth`, `_v-audit` (opener-only) | 2 | `v-activation-funnel-design`, `v-pricing-design` |
| `_v-core`, `_v-exec`, `_v-audit`, `_v-review`, `_v-design` | 1 | `v-audit-admin` (no `_v-growth`) |
| `_v-core`, `_v-exec`, `_v-audit`, `_v-review`, `_v-design`, `_v-growth` | 1 | `v-audit-messaging` |
| `_v-core`, `_v-exec`, `_v-design`, `_v-api`, `_v-jobs` | 1 | `v-scaffold` (no `_v-review`, no `_v-growth`) |
| `_v-core`, `_v-exec`, `_v-review`, `_v-design`, `_v-growth`, `_v-api`, `_v-jobs`, `_v-security` | 1 | `v-build` |
| `_v-core`, `_v-exec`, `_v-review`, `_v-growth`, `_v-audit` (opener-only) | 1 | `v-beta-program` |

8+5+5+5+4+4+3+3+3+3+2+2+1+1+1+1+1 = 52. If that sum stops matching the
skill-directory count, a skill was added or removed without updating this
table — re-run § Maintenance rather than eyeballing the delta.

## Adding a new orchestrator

1. Decide if the policy belongs in an EXISTING orchestrator first
   — adding a new one fragments the dependency graph.
2. If genuinely new: name it `_v-<domain>.md` (e.g.,
   `_v-i18n.md` for internationalization policy).
3. Add a section to this file (this orchestrator map) with: its
   responsibility, the skills that should load it, the
   sections it owns.
4. Update at least 2-3 v-* skills to `Follow` it; if no skills
   need it yet, defer creation.

## Adding a new skill

When authoring a new v-* skill, list its orchestrator
dependencies in the "Follow" line at the top of SKILL.md. Use
this map to pick which orchestrators apply:

- Always include: `_v-core.md`, `_v-exec.md`
- Audit-style skill: add `_v-audit.md`, `_v-review.md`
- Builds code: add `_v-review.md`, plus domain orchestrators
  (`_v-api.md`, `_v-jobs.md`, `_v-security.md`, `_v-design.md`)
  for the surfaces it touches
- Touches UI: add `_v-design.md`
- Touches growth instrumentation: add `_v-growth.md`

## Task → skill routing ownership (distinct from module loading)

This file maps the shared **`_v-*.md` module orchestrators** that
skills `Follow`. That is a *different* layer from **task → skill
routing** (deciding which `v-*` skill runs for a given operator
goal). To keep routing complete and non-contradictory, there is
exactly ONE canonical owner per routing concern — cite these, never
re-derive a private routing table:

| Routing concern | Canonical owner | Notes |
|---|---|---|
| General task → skill entry routing | `/v` (SKILL.md routing table) | The single entry point; auto-routes bug/feature/audit/refactor/docs/etc. |
| Audit-domain routing (which audit skill for which intent) | `references/v-core-audit-ownership.md` § Routing Rule | SEO→`/v-audit-seo`, pricing→`/v-audit-sales-pricing`, analytics→`/v-audit-analytics`, messaging→`/v-audit-messaging`, admin→`/v-audit-admin`, growth→`/v-audit-growth` |
| **Launch / ship / go-live / pre-launch audit routing** | **`/v-audit-orchestrator`** | **Canonical authority** (per its SKILL § "Canonical authority"): owns the bundle recipes and "which audit(s) for launch/ship." Any skill or doc that points an operator toward a launch/ship sweep MUST link here (`v-audit-orchestrator/references/audit-family-map.md`), NOT invent its own launch table. |

**Specific routes that were previously ambiguous or shadowed — now canonical:**
- "CI failing" / red pipeline → **`/v-ci-fix`** (not the generic bug-fix path).
- "comparison page" / "vs / alternative-to page" (a specific named competitor) → **`/v-content-create --type=comparison`** (the `comparison` brief type — formerly the standalone `/v-comparison-page` skill, merged 2026-07-05; requires a named competitor, or it downgrades to `--type=article`).
- "pricing design" / "design a pricing model/tiers" → **`/v-pricing-design`** (a generative design skill, reachable directly; distinct from the read-only `/v-audit-sales-pricing` audit).
- "full audit" / "production readiness" / "what do I run before launch" → **`/v-audit-orchestrator`** (single answer; supersedes the deprecated `/v-audit-full`).

Every current `v-*` skill must be reachable via one of the rows
above. When a new skill is added, register its route with the
matching canonical owner in the same change — do not leave it
orphaned.

## Cross-references

- Skill authoring hygiene: `_v-core.md` § Skill Authoring Hygiene
- Audit-skill opener: `_v-audit.md` § Audit Skill Opener
- Audit gates / floors / output conventions:
  `~/.claude/skills/references/v-audit-{gates,floors,output-conventions}.md`
- Skill template (canonical section order for audit skills):
  `~/.claude/skills/v-audit-orchestrator/references/v-audit-skill-template.md`

## Maintenance

**This map is derived, not hand-maintained.** Every roster and the dispatch
graph above are a snapshot of the query below, not a source of truth in
their own right — the source of truth is each skill's own `Follow` line
(or, for `_v-audit.md`, its `Audit opener:` line). When a skill's
dependency list changes, or a skill is added/removed, re-run the block
below and replace the affected roster cells + dispatch-graph rows
**wholesale**; never hand-patch a single name into a table by eye — that
is exactly how this file went stale twice (2026-08-02 note above).

```bash
# Re-derive every "Loaded by" roster + the dispatch-graph grouping directly
# from disk. Run from anywhere; cds into ~/.claude/skills itself.
#
# Two idioms count as a real load (see § Loading convention); everything
# else — a bare filename mention, a prose citation, a glossary table row,
# or a non-Follow path form like `~/.claude/skills/_v-audit.md § Step 3`
# (v-audit-code, v-differentiate cite it this way and are NOT loaders) —
# does not:
#   Idiom A (all 13 modules): Follow `_v-core.md`, `_v-exec.md`, ...
#   Idiom B (_v-audit.md only): **Audit opener:** see `_v-audit.md` § Audit Skill Opener
#
# PITFALL an earlier pass hit and this pattern is hardened against: a
# naive `Follow[^.]*` bound looks like a safe "stay within one sentence"
# guard but is NOT — every _v-*.md filename itself contains a period, so
# as soon as an EARLIER module in the same Follow list (always
# `_v-core.md` first) appears before the module you're testing for,
# `[^.]*` refuses to cross that earlier module's own '.md' period and the
# match silently fails — not an error, just zero results. Always use the
# unbounded `Follow.*`, and always grep per-module (never one pattern
# trying to capture an entire comma list at once).

cd ~/.claude/skills || exit 1
ORCHS="_v-core _v-exec _v-audit _v-review _v-design _v-growth _v-api _v-jobs _v-security"

for orch in $ORCHS; do
  echo "## ${orch}.md — Follow-declared by:"
  matches=$(grep -lE "Follow.*\`${orch}\.md\`" v-*/SKILL.md v/SKILL.md 2>/dev/null | sed -E 's#/SKILL\.md##' | sort)
  echo "$matches" | sed 's/^/  - /'
  echo "  count: $(echo "$matches" | grep -c .)"
  echo
done

# _v-audit.md's second idiom — opener-only opt-ins not already counted above:
echo "## _v-audit.md — ALSO opener-only opt-ins (Idiom B, narrower than the bundle):"
comm -23 \
  <(grep -lE '`_v-audit\.md` § Audit Skill Opener' v-*/SKILL.md 2>/dev/null | sed -E 's#/SKILL\.md##' | sort) \
  <(grep -lE "Follow.*\`_v-audit\.md\`" v-*/SKILL.md v/SKILL.md 2>/dev/null | sed -E 's#/SKILL\.md##' | sort)

# _v-core-runtime.md / _v-review-runtime.md / _v-artifact-formats.md / _v-resilience.md:
# no skill should ever `Follow` these (they are auto-generated mirrors or
# author-facing specs, not skill-loadable bundles) — confirm with:
for orch in _v-core-runtime _v-review-runtime _v-artifact-formats _v-resilience; do
  n=$(grep -lE "Follow.*\`${orch}\.md\`" v-*/SKILL.md v/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
  echo "## ${orch}.md — Follow-declared by: $n (must be 0)"
done

# Self-test: this pattern must produce BOTH true positives and true
# negatives, or it is not trustworthy. Expected output: 0, 0, 0, then >0.
echo "--- true-negative check (must print 0, 0, 0) ---"
grep -cE "Follow.*\`_v-core\.md\`" v-help/SKILL.md          # v-help: explicit self-exemption
grep -cE "Follow.*\`_v-audit\.md\`" v-audit-code/SKILL.md   # cites via path form, doesn't bundle-load
grep -cE "Follow.*\`_v-audit\.md\`" v-differentiate/SKILL.md # prose citation only (Step 3 archiving)
echo "--- true-positive check (must print >0) ---"
grep -cE "Follow.*\`_v-core\.md\`" v-build/SKILL.md
echo "--- period-truncation trap proof (correct=45, naive=1 — do not use the naive form) ---"
echo "correct: $(grep -lE "Follow.*_v-exec\.md" v-*/SKILL.md v/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
echo "naive:   $(grep -lE "Follow[^.]*_v-exec\.md" v-*/SKILL.md v/SKILL.md 2>/dev/null | wc -l | tr -d ' ')"
```

Optional — regenerate the compact dispatch-graph grouping (Python 3, any
version; falls back to reading the per-module lists above by hand if
Python isn't available):

```python
import re, glob
orchs = ["_v-core", "_v-exec", "_v-audit", "_v-review", "_v-design", "_v-growth", "_v-api", "_v-jobs", "_v-security"]
files = sorted(glob.glob("v-*/SKILL.md")) + ["v/SKILL.md"]
sigs = {}
for f in files:
    name = f.replace("/SKILL.md", "")
    text = open(f, encoding="utf-8").read()
    mods = [o.replace("_v-", "") for o in orchs if re.search(r"Follow[^\n]*`" + re.escape(o) + r"\.md`", text)]
    if "audit" not in mods and re.search(r"`_v-audit\.md`\s*§\s*Audit Skill Opener", text):
        mods.append("audit(opener-only)")
    sigs.setdefault(tuple(mods), []).append(name)
for sig, names in sorted(sigs.items(), key=lambda kv: (-len(kv[1]), kv[0])):
    print(f"{sig} :: {len(names)} :: {', '.join(names)}")
```

**Rule:** re-derive on every skill-authoring change, not on a size
threshold. The script is cheap; a stale table that silently under-routes
a skill is not.
