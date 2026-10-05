# Classification & Routing Reference

## Step 1: Parse & Classify

Read the user's prompt and classify it:

| Signal in Prompt | Category |
|-----------------|----------|
| "CI failing", "red CI", "CI is red", "GitHub Actions failing", "pipeline failing", "failing workflow", "fix the build on CI", "green the build" (a CI/GitHub-Actions job is red) | **CI Fix** → invoke `/v-ci-fix` (end-to-end from the Actions logs to verified pass). Takes precedence over the Bug-fix row below whenever the failure is a CI/pipeline job, not a locally-reproduced code defect. |
| "fix", "bug", "broken", "error", "crash", "failing" | **Bug fix** → see [Bug-fix Completeness Pattern](#bug-fix-completeness-pattern-w57-f3--advisory) below. (A *CI*-specific failure routes to the CI Fix row above, not here.) |
| "build", "add", "create", "implement", "new" | **Feature** |
| "scaffold", "generate", "stub", "create a service/job/model/page" | **Scaffold** → invoke `/v-scaffold` |
| "audit the /v system", "check my skills", "review the v-* skills", "audit the orchestrator", "skill regression", "audit my Claude Code setup" (the target is the /v machinery itself, NOT product code) | **Self-Audit** → invoke `/v-self-audit`. Takes precedence over the generic Audit row below — `/v-check` audits product code and explicitly does NOT cover the /v skill system. |
| "review", "audit", "check", "scan" | **Audit** |
| "refactor", "clean up", "improve", "simplify", "modernize" | **Refactor** → invoke `/v-audit-code` (it absorbed `/v-refactor` on 2026-07-06 — its code-quality + modernization lenses and `references/refactor-modernization.md` own refactor analysis, incl. the DEBT_TREND trend register; produces findings + runnable fix packs that hand off to `/v`). |
| "polish", "UX", "animation", "empty state", "dark mode", "accessibility", "WCAG", "UI audit", "design review", "visual/brand audit" | **Audit** — a quick UX sweep routes to `/v-check` (its UX domains 4/6, low resolution); a **deep/comprehensive UX + accessibility + brand** pass routes to `/v-audit-code` (it absorbed `/v-ui-audit` on 2026-07-06 — see `references/deep-ux-audit.md`: WCAG 2.2 AA, anti-AI-tells, pixel-perfect, forms/brand/SEO-UI). `/v-polish` is orchestrator-only scoped auto-fix. |
| "document", "docs", "API docs", "README" | **Docs** |
| "launch", "deploy", "ship", "go live", "production", "ready to launch", "pre-launch" | **Ship / Launch** → invoke `/v-audit-orchestrator` (the CANONICAL launch/ship owner — its [Bundle] pre-launch path dispatches + consolidates the ecosystem audits; see `v-audit-routing.md`). Do NOT route ship/launch to `/v-check` (code-only) — that was the old contradictory target. |
| "launch my product", "walk me through launching", "how do I launch", "launch day plan", "get me ready to launch end-to-end", "launch checklist + legal + channels" | **Launch Wizard** → invoke `/v-launch` — one door that runs the readiness gate (`/v-prelaunch-readiness`) → fix blockers → `/v-legal-docs-generate` → `/v-launch-channels`, producing one go/no-go `LAUNCH_PLAN_*.md`. Distinct from the **Ship / Launch** row above: that runs the pre-launch AUDIT sweep only; `/v-launch` is the guided launch *sequence* (gate + legal + channel plan + go/no-go). Route a pure "audit before launch" to the orchestrator; route "walk me through launching" here. |
| "design pricing", "set pricing", "initial pricing", "pricing tiers", "value metric", "willingness to pay", "price anchoring", "packaging" **when designing pricing that does not yet exist** | **Design (Pricing)** → invoke `/v-pricing-design`. Distinct from a pricing **audit** of EXISTING pricing/sales-ops (route those to `/v-audit-sales-pricing` per `v-audit-routing.md`). |
| "hook", "hooks", "settings", "settings.headless", "mirror sync", "repo-local .claude", "user-owned path", "skill tree", "canonical skill", "maintenance" | **Maintenance** → invoke `/v-maintenance` |
| "merge all", "consolidate", "merge worktrees", "merge branches", "push everything", "clean up worktrees" | **Merge All** → invoke `/v-merge-all` |
| "plan", "design", "spec", "architecture" | **Plan** |
| "content calendar", "content pipeline", "content ops", "what to write", "content status", "schedule refreshes", "content briefs", "prioritize content" | **Content Ops** → invoke `/v-content-ops` |
| "grow traffic", "increase/improve organic traffic", "more traffic", "traffic ideas", "grow SEO traffic (no outreach)", "here's my GSC/GA data — what should I do", "Search Console growth", "what should I do to get more visitors" | **Traffic Wizard** → invoke `/v-traffic` — the single-door zero-outreach traffic pipeline (intake GSC/GA4 → `/v-audit-seo` → `/v-content-ops` → one ranked `TRAFFIC_PLAN_*.md` + one-tap draft). Distinct from **Content Ops** (calendar from an existing audit) and a bare "run an SEO audit" (route that to `/v-audit-seo` directly). |
| "X vs Y", "vs {competitor}", "compare {A} and {B}", "alternatives to {competitor}", "{competitor} alternatives", "{competitor} pricing", "{competitor} cost", "{competitor} review", "comparison page" (a specific named competitor + comparison/alternatives/pricing intent) | **Comparison Page** → invoke `/v-content-create --type=comparison` (produces `content/compare/{slug}.md` + schema JSON-LD + asset specs — formerly the standalone `/v-comparison-page` skill, merged into v-content-create 2026-07-05). Distinct from **Content Ops** (which plans a content calendar) and general **Content** blog posts (route those to `/v-content-create` with the default `article` type). If no specific competitor is named ("generic feature comparison"), do NOT route here — the type requires a named competitor; falls through to `/v-content-create` (`article` type). |
| "AEO", "answer engine optimization", "AI citation", "get cited by ChatGPT/Perplexity/AI Overviews", "GEO content" | **AEO Content** → invoke `/v-content-create --type=aeo` (formerly the standalone `/v-aeo-content` skill, merged into v-content-create 2026-07-05). Distinct from general **Content** (route those to `/v-content-create` with the default `article` type, which already applies AEO discipline as ordinary technique). |
| "activation funnel", "signup flow", "lifecycle email cadence", "onboarding design", "design an empty state strategy" / "empty states" **when the request is designing/planning a first-run activation strategy from scratch** (pre-launch, no funnel yet, or redesigning after activation stalls) | **Design (Activation Funnel)** → invoke `/v-activation-funnel-design` — produces `ACTIVATION_FUNNEL_${SID}.md` + implementation prompt pack. Distinct from a plain "empty state" polish/bug request (still routes to `/v-check`/Audit per the row above) and from `/v-audit-growth` (audits an EXISTING funnel; this skill designs one that doesn't exist yet) |
| "beta program", "beta pricing", "beta cohort", "beta feedback cadence", "graduation criteria", "first 30-50 users" **when designing a NEW beta program from scratch** | **Design (Beta Program)** → invoke `/v-beta-program` — beta pricing, feedback cadence, and graduation criteria for the first 30-50 users. No audit skill covers this (`v-audit-orchestrator/references/audit-family-map.md` lists it as "no audit equivalent"), so it has no family router either — this row is its only reachable path from `/v`. |
| "launch channels", "Product Hunt", "Hacker News", "launch on PH/HN/Reddit/IH", "which channels to launch on", "cross-channel launch sequence", "launch day announcement plan" | **Launch Channels** → invoke `/v-launch-channels` — channel-specific launch asset + sequencing plan across owned (X, LinkedIn) + earned (PH, HN, IH, Reddit) channels. Run AFTER the Ship/Launch readiness gate above is clean (`/v-prelaunch-readiness` recommends this skill as its next step once MUST-FIX/SHOULD-FIX are clear) — this row exists because that recommendation is prose, not a dispatch. |
| "make this more memorable", "screenshot-worthy", "stress-test this idea", "contrarian take", "differentiation ideas", "how do we stand out", "luxury-bar polish" **when the request wants a divergent menu of alternatives, not one recommendation** | **Differentiate** → invoke `/v-differentiate` — generates 5+ provocative/luxury-bar alternatives for a surface, feature, or decision (operator picks). Distinct from `/v-plan` (single recommended approach) and `/v-anti-template-gauntlet` (defense/QA on already-built output, run AFTER an idea is picked and implemented). No other skill invokes or recommends this one — this row is its only reachable path from `/v`. |
| "what should I work on next", "what's overdue", "portfolio check", "which project needs attention", "stale audits across my projects", "cadence check" (asking across MULTIPLE projects, not auditing one specific project in depth) | **Portfolio Cadence** → invoke `/v-next` — read-only cross-project scan (stale audits, unresolved findings, stranded worktrees, CI health) producing ONE ranked next-action list. Recommends which skill to run next; never dispatches it. Distinct from `/v-audit-orchestrator` (runs a specific audit ON one project already in view) and `/v-self-audit` (audits the `/v` system itself, not product projects). |
| "is production healthy", "prod health check", "error spike", "failed jobs", "queue backlog", "scheduled task stopped running", "smoke test production", "backup restore drill", "does our backup actually restore" | **Production Triage** → invoke `/v-prod-triage` — read-only runtime health triage (error clustering, queue/failed-jobs, scheduled-task drift, post-deploy smoke check; opt-in backup-restore drill against a throwaway scratch DB, never production). Distinct from `/v-pre-flight` (pre-deploy static gates) and `/v-bug-hunt` (adversarially exercises a specific subsystem; this skill reads passive runtime signals). |
| References a `PLAN_*.md`, `AUDIT_REPORT_*.md`, `REFACTOR_PLAN_*.md`, `POLISH_PLAN_*.md`, or `ADMIN_AUDIT_REPORT_*.md` filename (written under `.v/artifacts/` since Phase-2; the disk-scan dual-searches root as a legacy fallback) | **Build from artifact** → invoke `/v-build` with the artifact path |
| References a `SEO_AUDIT_*.json` / `SEO_AUDIT_*.md` filename (from `/v-audit-seo`) | **Content Ops** → invoke `/v-content-ops` with the audit path (it turns the audit's content calendar into `CONTENT_BRIEF_*.md` files for `/v-content-create`); if the prompt names specific technical-SEO findings to implement, route to **Build from artifact** instead |
| User provides a detailed implementation plan inline (numbered steps, file lists, specific changes) | **Plan-provided** → treat as Medium/Large Feature (see fast path below) |

**Routing confidence rule:** If routing confidence is high, proceed. If routing confidence is medium, proceed with explicit assumptions stated to the user. If routing confidence is low, ask one clarifying question using AskUserQuestion (present the top 2-3 likely categories as options with descriptions).

### Specialist skills reached via a family router (not direct `/v` NL classification)

These `user-invocable` skills are deliberately NOT direct classification-table entries — they are dispatched (or menu-offered) by a family router once the router itself is reached, so routing there is intentional design, not a gap. A user can still invoke any of them by exact slash-command name regardless of this table.

| Specialist skill | Family router | How it's reached |
|---|---|---|
| `/v-bug-hunt` (`bugs` lens, default) | `/v-audit-orchestrator` | Explicit `invokes:` entry + `[Specialist] Adversarial bug hunt` menu row |
| `/v-bug-hunt --lens=boundaries` (formerly `/v-edge-hunt`, merged 2026-07-05) | `/v-audit-orchestrator` | Same `invokes:` entry as above + `[Specialist] Edge-case / boundary hunt` menu row |
| `/v-prelaunch-readiness` | `/v-audit-orchestrator` | Dispatched by both `[Bundle]` paths (pre-launch sweep / full sweep); also recommended by `/v-setup-project` Step 7 for greenfield projects |

`/v-beta-program`, `/v-launch-channels`, and `/v-differentiate` do NOT have a working family router (see the direct rows added above) — they were the genuine gaps, not intentional family-router scoping.

## Bug-fix Completeness Pattern (W57-F3 — advisory)

When classification routes to **Bug fix**, before proposing a single-location fix, the orchestrator SHOULD broaden the search. This pattern is advisory — no hard gate enforces it — but skipping it has produced a documented class of "user reports the same bug multiple sessions in a row" failures.

### 1. Search for the same code pattern elsewhere

If the bug is a code pattern (a comparison, an API misuse, a validation gap), grep the codebase for OTHER instances of the same pattern. Generic example:

```bash
# If the bug is "X !== null should be X.isReady()", search for ALL occurrences:
grep -rn "X !== null\|X != null" <source_dirs>
```

If 3+ occurrences found: fix all together in one wave. If 1-2 found: fix together if scope permits. **Do not fix only the reported instance** — that ships the bug class to the next user-reported recurrence.

### 2. Audit registries for sibling gaps

If the bug is a registry/manifest miss (a class file exists but isn't loaded; a route exists but isn't registered; a feature flag exists but isn't documented), audit the ENTIRE registry for other gaps. Generic example:

```bash
# Symbols referenced in a registry vs. symbols actually loaded.
# Stack-specific specifics live in project CLAUDE.md (e.g., "loader is at <X>, manifest is at <Y>").
grep -oE "<NamespacePrefix>_[A-Za-z_]+" <registry_file>      # what the registry claims to load
grep -oE "<load_directive>.*<NamespacePrefix>" <loader_file>  # what's actually loaded
diff -y <(echo "$claimed") <(echo "$loaded")                  # surface gaps
```

When the audit finds 2+ gaps in 30 days, propose the structural alternative explicitly (auto-discovery, glob-load, decorator registration) — not another one-line patch.

### 3. Check local-vs-deployed divergence

For every fix, ask:
- Is any artifact gitignored (build outputs, vendor dirs, generated configs) yet referenced by source?
- Does deployment regenerate it, or rely on the artifact being committed?
- If gitignored AND deployment doesn't regenerate it: that's the root cause class for "works locally, fails in production."

### 4. Recurring-bug signal

If the user's prompt contains signal phrases:
- "I still cannot connect/build/deploy/run/access/load/find/get/push/pull/sync/publish/save/sign in/log in"
- "after you/we/I have tried..."
- "this keeps happening"
- "not the first time"

This is the THIRD+ recurrence of the same bug class. The orchestrator MUST propose the structural fix (not just patch the immediate symptom), even if a one-line patch would resolve the reported case. The user is signaling the deeper issue.

The exact phrase set is enforced by `~/.claude/hooks/detect-recurrence-signal.sh` (subsection 5 below); the list above is illustrative. Bare phrases like `multiple times`, `repeatedly`, `again and again`, `tried before`, `third/fourth time`, `broken again`, and `still cannot <any verb>` were dropped from the regex during W58 because they over-matched routine engineering prompts (verified false-positives in W58-IMPL-REVIEW).

### 5. Detection marker (W58-F1 — automated)

The `UserPromptSubmit` hook `~/.claude/hooks/detect-recurrence-signal.sh` automatically scans every user prompt for recurrence signal phrases. When matched, it writes:

```
${V_TMP_DIR}/recurrence-detected-${SID}.txt
```

containing the matched phrase + a 300-char prompt excerpt. The hook also injects an `additionalContext` advisory into the session.

**When this marker exists, the orchestrator MUST**:
1. Investigate the underlying pattern (use rules 1-3 above to enumerate sibling/registry/deploy issues).
2. Document the result explicitly in the AGENT_REVIEW. Either:
   - `Structural alternative: <substantive description ≥40 chars>` — propose the deeper fix
   - `One-line patch justified: <substantive reason ≥40 chars>` — explain why the symptom-patch IS the right call

The Stop-hook check `check-review-artifact.sh` enforces this. AGENT_REVIEW lacking BOTH lines (or with token-only content like `TODO`, `pending`, `N/A`) blocks completion when the marker exists.

**Rationale:** the prompt-only advisory in W57-F3 caught the user's pain conceptually but didn't shift behavior. The marker + Stop-hook gate makes the consideration mandatory and visible.

### Enforcement

This pattern is ADVISORY at the prompt level. There is no Stop-hook gate that enforces production of an audit artifact. Future waves may add `BUG_FIX_AUDIT_<sid>.md` as a required artifact for bug-fix sessions; that's deferred until the advisory has measured impact.

### Anti-patterns this section deliberately catches

- "Fix the one line the user pointed at, ship, move on" — when the same pattern lives in N other places.
- "I'll patch this, leave the structural question for later" — when the user has already reported the recurrence.
- "Local tests pass, ship" — when production diverges in known ways (gitignored artifacts, env-driven configs, cached state).

## Plan-Provided Fast Path

When the user provides a pre-built plan (either inline in the prompt or from a prior planning session), the full scope classification and `/v-new-feature` planning steps are unnecessary — the plan already exists. However, the quality chain is NOT optional.

**Flow:** Skip Step 2 scope classification → Skip `/v-new-feature` → **Create worktree** (based on plan's estimated file count; if unclear, assume Medium) → **Invoke `/v-build`** with the plan → Continue with polish → check → pre-flight → agent review → verify-done → merge-back as normal.

**Critical:** A pre-built plan does NOT skip quality gates. The full chain from `/v-build` onward MUST execute. Sessions that receive a plan and implement it without invoking any sub-skills have failed — see `_v-core.md` "Zero-skills is a failure state."

**Anti-pattern (observed in 9/9 analyzed sessions):** "The user provided a complete plan with code snippets, so `/v` was unnecessary." This is WRONG. `/v` exists precisely for this case — the Plan-Provided Fast Path skips planning but enforces the quality chain (build → pre-flight → agent review → verify-done). Without `/v`, sessions skip agent review (6/9 sessions), skip verify-done (8/9), and miss scope classification entirely. Agent review in one session caught a CRITICAL logic inversion bug that would have shipped without it.

### Verify-Before-Reading Rule (Universal — applies to ANY input that names file paths or claims a count)

**Originally added for Plan-Provided fast path; generalized in Wave 3 because one production session hit it on a "Surface/Files/Evidence/Fix" structured bug report (not a labeled plan): user said "2 lines in app.blade.php"; actual scope was 31 changes across 5 files. The grep-first rule didn't fire because the input wasn't classified as Plan-Provided.**

**Generalized rule:** ANY input that names specific file paths or claims a file count — whether labeled as a "plan", "audit report", "bug report", "Surface/Files/Evidence/Fix" prompt, or unstructured prose — triggers a one-shot grep to verify the universe BEFORE reading the named files.

**Triggers (any of these):**
- Input mentions specific file paths (`app/Http/Controllers/X.php`, `resources/js/Pages/Y.tsx`, etc.)
- Input claims a count of affected files (`7 files have hardcoded colors`, `12 templates need updating`)
- Input describes a search pattern (`all references to old-image.png`, `every page with brand suffix`)
- Input is structured as `Surface: X / Files: Y / Evidence: Z / Fix: W`
- Input cites line numbers without giving the surrounding pattern

When the plan/input claims N affected files, names specific paths, or describes a pattern of files to change, run a one-shot grep to verify the universe BEFORE reading the named files.

**Observed waste (one production session):**
- Spec said: "7 chart files in Charts/ have hardcoded HSL values"
- Reality: 1 of 9 chart files actually had hardcoded values
- Cost of trusting spec verbatim: 6 unnecessary file reads, ~5–8k tokens

**Pattern:**
```bash
# Spec says: hardcoded HSL/RGB values in resources/js/Components/Charts/ (7 files)
# Verify before reading 7 files:
rg '#[0-9a-fA-F]{3,6}|rgba?\(|hsla?\(' resources/js/Components/Charts/ -l
# If output shows 1 file, only read that one — saves 6+ unnecessary reads.
```

**Decision flow:**
- **grep result = spec count** → proceed to read all named files. Spec was accurate.
- **grep result < spec count** → read only the matching files. Note in implementation report: "Spec claimed N files, grep verified M. Implementation scope was M."
- **grep result > spec count** → read all matching files. The spec missed some — flag the bonus discoveries in the implementation report (these are positive findings, often parallel bugs of the same type).
- **grep result = 0** → spec claim is wrong. Investigate via different grep (different pattern, broader scope) before assuming nothing to do. Do NOT silently skip.

**When to skip this sub-step:** when the plan provides exact line numbers (e.g., "BillingService.php:45-67") rather than file counts or patterns. Exact line references are already verified by the act of reading them.

**Cost:** ~10 seconds of grep time per plan. Saves 5–8k tokens per affected plan-provided session. Also surfaces plan-vs-reality drift as a signal to the orchestrator (which may want to re-classify scope based on actual file count rather than claimed count).

### Test-Upkeep Sub-Step (Before Claiming Plan Complete)

When a plan changes user-visible strings (page titles, error messages, copy, button labels, page headers, route paths, URL patterns, schema field names visible in API responses), grep for test files referencing those strings BEFORE claiming the plan is complete.

**Why:** Test assertions on those strings are predictably stale after the change. Catching them at plan time is cheaper than catching them after a pre-flight failure.

**Observed waste (one production session):**
- Plan: change 12 page template titles (strip brand suffix)
- Reality: 6 stale assertions in a feature test file referenced the old titles
- Avoidable with a pre-implementation grep

**Pattern:**
```bash
# For each user-visible string fragment that's changing:
for STRING_FRAGMENT in "Brand Name" "Old Page Title" "Old Error Message"; do
  rg "$STRING_FRAGMENT" tests/ -l
done
# Read every matched test file and update assertions in the same wave as the source change.
```

**Categories that trigger this rule:**
- Template title changes (HTML `<title>`, OG tags, schema names)
- Error message rewording (validation errors, exception messages)
- Page header changes (h1, h2 visible to users)
- Button label changes (CTA text)
- Route path or URL pattern changes (`/old-path` → `/new-path`)
- API response field name changes (visible to consumers, including frontend tests)
- Email subject line / template name changes
- Database column changes that surface in tests via factory definitions or seeders

**Decision flow:**
- Run greps before implementing.
- Add matched test files to the planned-changes file list (so they're updated in the same implementation wave).
- After implementing, verify all test files matched by greps were updated — flag any unmodified matches in the implementation report.

**Cost:** ~15 seconds of grep per plan. Saves 3–5k tokens per affected session and prevents the test-failure-after-pre-flight retry cycle.
