# v-next — Signal Sources & Staleness Thresholds

Loaded on-demand by v-next Step 2. Exact commands + thresholds per signal.

## 1. Last-audit timestamps

```bash
# Per project root $PROJ:
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "AUDIT_REPORT_*.md" -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "SEO_AUDIT_*.md" -o -name "SEO_AUDIT_*.json" -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "*_AUDIT_*.json" -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "BUG_HUNT_REPORT_*.md" -exec ls -t {} + 2>/dev/null | head -1
```

Always select by mtime (`ls -t`), never filename-lexicographic sort — several report filenames
embed a UUID session ID with no sortable timestamp component.

**Staleness thresholds (days since last run, per audit family):**

| Family | Fresh | Due | Overdue |
|---|---|---|---|
| `v-check` (general audit) | <30 | 30-60 | >60 |
| `v-audit-seo` | <30 | 30-90 | >90 (per `v-audit-sales-pricing`/comparison quarterly cadence norms) |
| `v-audit-growth` | <45 | 45-90 | >90 |
| `v-bug-hunt` (either lens) | <60 | 60-120 | >120 (behavioral defects drift slower than content/SEO) |
| `v-audit-code` | <90 | 90-180 | >180 |

These are starting defaults — a project's own `CLAUDE.md` may state a different cadence; prefer
that when present.

## 1b. Wizard-plan & operational freshness

The one-door wizards and prod-triage each write a dated plan; surface these ALONGSIDE the audit
staleness above so ONE `/v-next` covers the whole operating surface (growth, launch, prod, content),
not just audits. Same mtime-select + `.v/artifacts`-then-root dual-search as § 1.

```bash
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "TRAFFIC_PLAN_*.md"     -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "LAUNCH_PLAN_*.md"      -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "PROD_TRIAGE_*.md"      -exec ls -t {} + 2>/dev/null | head -1
find "$PROJ/.v/artifacts" "$PROJ" -maxdepth 2 -name "CONTENT_CALENDAR_*.md" -exec ls -t {} + 2>/dev/null | head -1
```

| Plan | Fresh | Due | Overdue | Recommend when due/overdue |
|---|---|---|---|---|
| `TRAFFIC_PLAN_*` (organic growth) | <14 | 14-30 | >30 | `/v-traffic` (refresh — shows what moved since last run) |
| `CONTENT_CALENDAR_*` | <14 | 14-30 | >30 | `/v-content-ops` (regenerate the calendar) |
| `PROD_TRIAGE_*` (runtime health) | <7 | 7-21 | >21 | `/v-prod-triage` (re-check prod) |
| `LAUNCH_PLAN_*` | verdict-gated (see below) | | | `/v-launch` |

**Two are content-gated, not just staleness-gated — read the latest plan, don't just check its age:**
- `LAUNCH_PLAN_*`: grep its `## Verdict` line. A `NO-GO` (open MUST-FIX blockers) is a TOP-ranked
  item ("N launch blockers open") regardless of the plan's age — a `GO` verdict just means launch
  readiness is clean, no action.
- `PROD_TRIAGE_*`: grep its `### P0` / `### P0_CRITICAL` section. An open P0 (e.g. a growing
  failed-jobs backlog, a silently-stopped scheduler) is URGENT and outranks a 60-day-old SEO audit —
  runtime health beats content freshness. Recommend `/v-prod-triage` (or `/v` to fix the specific P0).

If a plan artifact is absent entirely, that is NOT a staleness signal (the operator may simply not
use that wizard yet) — only surface plans that EXIST and are due/overdue or carry an open verdict.

## 2. Unresolved findings

Grep the most recent `AUDIT_REPORT_*.md` / consolidated report for open P0/P1/P2 counts:

```bash
grep -oE '"?severity"?:\s*"?(critical|high|medium|low)"?' "$LATEST_REPORT" | sort | uniq -c
```

(Consolidated reports render `critical|high|medium|low`, which maps 1:1 to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md` — treat critical/high counts as open P0/P1.)

A finding counts as resolved only if a later report/commit explicitly supersedes it — absent
that, treat every finding in the latest report as still open. Do not assume silent resolution.

## 3. Launch stage detection

Reuse the SAME greenfield/growth/mature heuristic every audit skill already applies — do not
invent a new one:

```bash
PUBLISHED_ARTICLES=$(find "$PROJ/content/blog" "$PROJ/public/blog" "$PROJ/resources/content" -name "*.md" 2>/dev/null | wc -l)
HAS_GSC_DATA=$([ -n "$(ls "$PROJ"/.seo/gsc-export-* 2>/dev/null | head -1)" ] && echo 1 || echo 0)
HAS_REVENUE_MENTIONS=$(grep -rlE '\b(MRR|ARR|paying customers?)\b' "$PROJ/CLAUDE.md" 2>/dev/null | wc -l)
```

`PUBLISHED_ARTICLES=0` AND `HAS_GSC_DATA=0` → greenfield. `HAS_REVENUE_MENTIONS>=1` → growth or
mature (read CLAUDE.md context to disambiguate). Otherwise → growth (the common middle case).

## 4. Stranded worktrees/branches

```bash
git -C "$PROJ" worktree list --porcelain 2>/dev/null
git -C "$PROJ" branch --no-merged "$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo main)" 2>/dev/null
```

A worktree is "stranded" when its directory mtime (or the mtime of its most-recently-changed
tracked file) is >7 days old AND it has no corresponding open PR. A branch is "stranded" when
it's unmerged into main/master AND has had no commits in >14 days.

## 5b. Pending pack-inbox work

Distinct from "no audit has run in N days" — this signal is "there is already-generated,
already-validated work sitting queued and not yet run." Read
`~/.claude/skills/references/v-core-pack-inbox.md` for the full convention; the check itself is a
plain file count, read-only:

```bash
INBOX="$PROJ/.v/packs/inbox"
PENDING=$(find "$INBOX" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' ')
```

`PENDING>0` means the project has one or more generated packs waiting in its stable inbox — surface
this alongside the staleness signals above (e.g. "3 packs queued in .v/packs/inbox, last queued
<date>") rather than only reporting on audit recency. This is a read-only detection signal; v-next
itself never invokes `run-v-packs` or `v-inbox` — it only reports the count and recommends the
operator run `v-inbox` themselves.

## 6. Dependency & security-audit staleness

Distinct from the audit-family staleness in § 1 — this tracks whether the project's OWN
dependency manifests have had a security-audit pass run recently, per
`~/.claude/CLAUDE.md` § Quality Gates (`composer audit` / `npm audit --audit-level=critical`)
and `v-maintenance/SKILL.md` § Not for (product-repo dependency hygiene is explicitly routed
here, not to `/v-maintenance`).

```bash
# Per project root $PROJ — the lockfile's last-commit date is the best available proxy for
# "when was a security-audit-gated dependency pass last run" (there is no dedicated
# AUDIT_REPORT_*-style artifact for this signal):
git -C "$PROJ" log -1 --format=%cI -- composer.lock package-lock.json 2>/dev/null
```

If neither lockfile exists (no PHP/JS deps in the project), this signal is
`data_source: not_applicable` — not stale, just inapplicable.

**Staleness thresholds (days since the lockfile's last commit):**

| Signal | Fresh | Due | Overdue |
|---|---|---|---|
| `security_audit` (composer/npm audit cadence) | <14 | 14-30 | >30 |

A lockfile untouched >30 days is NOT proof an audit never ran (the operator can run
`composer audit` / `npm audit` without touching the lockfile) — treat this as a conservative
proxy; if the project's own `CLAUDE.md` documents a different cadence, prefer that. Recommend
running `composer audit` / `npm audit --audit-level=critical` directly in the product repo
(never `/v-maintenance` — its fence is `~/.claude` meta-tooling, not the product's own
dependencies, per its § Not for), escalating any CRITICAL/HIGH finding to `/v` for the code fix.

## 7. Legal-doc staleness

```bash
# Per project root $PROJ — read the last_updated frontmatter field each
# v-legal-docs-generate-produced doc carries (v-legal-docs-generate/SKILL.md § Step 2):
for f in "$PROJ"/content/legal/*.md "$PROJ"/resources/legal/*.md "$PROJ"/app/legal/*.md; do
  [ -f "$f" ] && grep -H "^last_updated:" "$f"
done 2>/dev/null
```

Absent legal docs entirely is NOT a staleness signal here — that's `/v-launch`'s Legal risk
gate's job (`v-launch/SKILL.md` § Step 2), not v-next's. This signal only fires for a project
that HAS legal docs and they've gone stale.

**Staleness thresholds (days since `last_updated`, oldest doc in the set governs):**

| Signal | Fresh | Due | Overdue |
|---|---|---|---|
| `legal_docs` | <180 | 180-365 | >365 |

**Escalation trigger distinct from age:** if the project's `CLAUDE.md` or codebase signals the
applicable-jurisdiction set changed since the docs were last generated (a new
`JURISDICTION_STATE` mentioned, a new EU/UK-targeting signal per
`v-legal-docs-generate/references/legal-analysis-dimensions.md` § Dimension 5, or a new
AI feature landed per § 4b of Dimension 3's brief) — treat as `overdue` regardless of age and
recommend a `/v-legal-docs-generate` re-run, not just a refresh nudge. This is CONTENT-gated,
the same shape as `LAUNCH_PLAN_*`'s verdict-gating in § 1b above.

## 5. CI state

```bash
if command -v gh >/dev/null 2>&1 && git -C "$PROJ" remote get-url origin 2>/dev/null | grep -q github.com; then
  gh run list --repo "$(git -C "$PROJ" remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')" --limit 5 --json status,conclusion,createdAt 2>/dev/null
else
  echo '{"data_source":"unavailable"}'
fi
```

If the JSON parse fails, the `gh` CLI errors, or there's no GitHub remote: tag
`ci_data_source: unavailable`. Never report a CI status without a successful read.
