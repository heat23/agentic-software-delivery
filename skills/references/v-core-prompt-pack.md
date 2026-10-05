# Prompt Pack Contract (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (unified pack standard: .txt wave form + mandatory body schema)._

## Prompt Pack Contract (Mandatory)

Every audit skill that produces prompt-pack files MUST follow this contract. Prompt packs are the primary deliverable — the audit JSON/report is an intermediate artifact; the prompt files are what the user actually runs.

---

## Unified folder convention (2026-05 sweep — REQUIRED)

**Path:** `.v-prompt-packs/<full-skill-name>-<MM-DD>/` — a `00-README.md` map plus flat `w<N>-*.txt` wave packs.

**This file owns the FOLDER convention (below). The pack SHAPE and mandatory body schema are the single
standard defined in [`v-runnable-pack-convention.md`](v-runnable-pack-convention.md) — flat `.txt` wave
packs (`w<N>-` prefix, `99-verify` last), first line `/v `, each carrying the `## Goal / ## Context /
## Files / ## Changes / ## Acceptance criteria / ## Tests / ## Constraints / ## Dependencies` body so a
cold agent can implement it from that one file. The older `NN-*.md` shape is deprecated (2026-07-05); the
runner still executes any pre-existing `.md` pack for backward compat, but producers emit `.txt` only.**

Where:
- `<full-skill-name>` is the skill's directory name verbatim (e.g., `v-audit-messaging`, `v-audit-seo`, `v-audit-admin`, `v-anti-template-gauntlet`, `v-prelaunch-readiness`, `v-audit-code`, `v-check`, `v-audit-consolidate`). NEVER abbreviate — `v-audit-messaging`, not `v-positioning`.
- `<MM-DD>` is the run date as `MM-DD` (e.g., `05-01` for May 1). Computed dynamically at dispatch time via `$(date +%m-%d)`. Each calendar-day run produces its own sibling directory at `.v-prompt-packs/` root; runs on different days never collide.
- pack files inside that dated dir follow the wave form: `00-README.md`, then `w0`/no-prefix (`fix-hero.txt`), `w1-*.txt`, `w2-*.txt`, `99-verify.txt`.

**Examples:**
- `.v-prompt-packs/v-audit-messaging-05-01/00-README.md`
- `.v-prompt-packs/v-audit-messaging-05-01/fix-homepage-hero.txt` (wave 0)
- `.v-prompt-packs/v-audit-seo-05-01/w1-add-schema-markup.txt`
- `.v-prompt-packs/v-audit-seo-05-01/99-verify.txt`

**Year-collision note:** the MM-DD form is intentionally short for ergonomics. Re-running the same audit on the same MM-DD across different years (e.g., `2026-12-31` then `2027-12-31`) collides at the same path; the second run's archive logic moves the prior to `.bak-<timestamp>` (see Re-run behavior below). Operators wanting cross-year history retention should rename or relocate prior-year `.v-prompt-packs/v-X-MM-DD/` dirs before re-running on the same MM-DD a year later.

**Rationale:**
1. **Single top-level namespace** — operator finds all generated prompt packs under `.v-prompt-packs/` at project root, not scattered as `v-*-prompts/` siblings or buried in `.claude/`
2. **Visible, project-root location** — `.v-prompt-packs/` is intentionally NOT inside `.claude/` so the operator can see prompt packs in their normal file tree without spelunking into Claude's config dir
3. **Skill traceability** — each pack subdir starts with the skill name (no abbreviation drift) and ends with the run date
4. **Run history at-a-glance** — `ls .v-prompt-packs/` shows every audit run with its date in the directory name; no need to descend into archive .bak siblings to see what ran when
5. **Gitignore-friendly** — single rule (`.v-prompt-packs/`) ignores all generated prompt artifacts
6. **No nested `/prompts/`** — the parent name already says "prompt-packs", so the extra subdir would be redundant
7. **Cross-day runs never collide** — re-running an audit a day or week later creates a new dated dir; no archive dance needed for the common case

**Re-run behavior:**
- **Different-day re-run:** new `<skill>-<new-MM-DD>/` directory created naturally; prior dated dirs preserved at `.v-prompt-packs/` root as siblings. No archive logic fires; both runs visible side-by-side.
- **Same-day re-run:** the existing dated dir is non-empty, so per `_v-audit.md` § Step 3 the pre-dispatch shell archives it to `<PROMPT_DIR>.bak-YYYYMMDD-HHMMSS-XXXX/` and starts the new pack from an empty dir. This preserves the prior same-day pack while allowing the new run to ship cleanly.
- Audit JSON+MD at `$PROJECT_ROOT` remain SID-stamped for history per existing convention.
- The operator deletes accumulated `.bak-*` siblings (and old dated dirs they no longer need) when convenient.

**Migration status (2026-04 folder sweep — historical).** The 2026-07-05 standardization SUPERSEDES the pack-*shape* distinctions below: every producer listed here (audit-, design-, AND plan/feature-family) now emits the single `.txt` wave form + body schema and is validated by the wave-form self-validate / `validate-audit-prompt-packs.sh`. The folder-migration detail below remains accurate; ignore any "plan-derived structure" / "exempt from validation" shape carve-outs — those are retired.

- **Audit-family — migrated:** v-audit-admin, v-audit-analytics, v-audit-consolidate, v-audit-growth, v-audit-messaging, v-audit-sales-pricing, v-audit-seo, v-anti-template-gauntlet, v-prelaunch-readiness, v-audit-code (writes `.v-prompt-packs/v-audit-code-<MM-DD>/`; absorbed v-refactor + v-ui-audit 2026-07-06 — the retired skills' legacy `v-refactor-prompts/` alias is still scanned by `/v` for backward compat with old on-disk packs, see below), v-check, v-bug-hunt (both its `bugs` and `boundaries` lenses share this one producer — v-edge-hunt merged into v-bug-hunt 2026-07-05, no longer a separate producer).
- **Design-family — migrated:** v-pricing-design, v-beta-program, v-illustration-system, v-activation-funnel-design.
- **Plan/feature-family — migrated to `.v-prompt-packs/<skill>-<MM-DD>/` (keep a legacy alias):** v-plan (writes `.v-prompt-packs/v-plan-<MM-DD>/`), v-discover-features (writes `.v-prompt-packs/v-discover-features-<MM-DD>/`). These emit the unified `.txt` wave form + body schema (validated by `validate-audit-prompt-packs.sh` like every other producer — the former plan-derived/exempt carve-out is retired).
- **No remaining un-migrated producers.** Every skill that emits a session-paste prompt pack now writes under the single `.v-prompt-packs/<full-skill-name>-<MM-DD>/` root (this file's Unified folder convention above). `prompt-pack-output-dir-parity.test.ts` (in `skills/__tests__/`) is the ecosystem-wide sweep that fails if any producer — new or existing — references a bare, undated `.v-prompt-packs/<skill>/` path or reintroduces a legacy `<skill>-prompts/` root as its primary output.
- **No prompt-pack output:** v-content-create (all brief types — `article`, `aeo`, and `comparison`, the latter two absorbed from the former standalone `v-aeo-content`/`v-comparison-page` skills 2026-07-05), v-launch-channels, v-marketing-design, v-build emit different artifact types (drafts, briefs, code) and do not produce session-paste prompt packs. **Batch-mode note for `brief_type: comparison`:** when invoked in batch mode (`all five competitors`), it produces N independent `content/compare/{slug}.md` files (NOT `content/blog/` — see `v-content-create/references/comparison-protocol.md` § Output contract) — each page IS the deliverable; no manifest or session-paste pack is generated. Operators discover the batch via `ls content/compare/*-vs-*.md` or the equivalent slug pattern.

---

## Per-skill MUST-USE values

When invoking the prompt-pack subagent, set `PROMPT_DIR` by computing the date suffix dynamically at dispatch time. Each skill's PROMPT_DIR template:

```bash
PROMPT_DIR=".v-prompt-packs/<skill-name>-$(date +%m-%d)"
```

Per-skill values:

| Audit skill | `PROMPT_DIR` (computed at dispatch) |
|---|---|
| v-audit-admin | `.v-prompt-packs/v-audit-admin-$(date +%m-%d)` |
| v-audit-analytics | `.v-prompt-packs/v-audit-analytics-$(date +%m-%d)` |
| v-audit-consolidate | `.v-prompt-packs/v-audit-consolidate-$(date +%m-%d)` |
| v-audit-growth | `.v-prompt-packs/v-audit-growth-$(date +%m-%d)` |
| v-audit-messaging | `.v-prompt-packs/v-audit-messaging-$(date +%m-%d)` |
| v-audit-sales-pricing | `.v-prompt-packs/v-audit-sales-pricing-$(date +%m-%d)` |
| v-audit-seo | `.v-prompt-packs/v-audit-seo-$(date +%m-%d)` |
| v-anti-template-gauntlet | `.v-prompt-packs/v-anti-template-gauntlet-$(date +%m-%d)` |
| v-prelaunch-readiness | `.v-prompt-packs/v-prelaunch-readiness-$(date +%m-%d)` |
| v-audit-code | `.v-prompt-packs/v-audit-code-$(date +%m-%d)` (absorbed v-refactor + v-ui-audit 2026-07-06) |
| v-check | `.v-prompt-packs/v-check-$(date +%m-%d)` |
| v-bug-hunt (both lenses) | `.v-prompt-packs/v-bug-hunt-$(date +%m-%d)` |
| v-pricing-design | `.v-prompt-packs/v-pricing-design-$(date +%m-%d)` |
| v-beta-program | `.v-prompt-packs/v-beta-program-$(date +%m-%d)` |
| v-illustration-system | `.v-prompt-packs/v-illustration-system-$(date +%m-%d)` |
| v-activation-funnel-design | `.v-prompt-packs/v-activation-funnel-design-$(date +%m-%d)` |
| v-differentiate | `.v-prompt-packs/v-differentiate-$(date +%m-%d)` (only when the operator picks 1+ ideas to implement in-session) |

Setting `PROMPT_DIR` to anything else (omitting the date suffix, using YYYY-MM-DD instead of MM-DD, hardcoding a fixed date) is a contract violation; the post-generation validator will fail.

**Why dynamic at dispatch:** the date is captured at the moment the audit runs. A long-running audit started at 23:55 may complete after midnight; the directory name reflects the START date. Re-running the next day produces a different dir naturally; same-day re-runs trigger the archive logic per `_v-audit.md` § Step 3.

---

**Generation requirements:**
1. Prompt generation MUST be dispatched as a separate subagent, never generated inline. By the time prompt generation happens, the main context has consumed 50k-200k+ tokens on audit dimensions; inline generation will truncate or skip files. **Dispatch mechanism depends on the calling skill's own context:**
   - **`context: fork` skills (the common case — nearly every audit/design skill in this catalog runs forked)** are themselves subagents, and a subagent cannot dispatch another subagent via the **Agent tool** (Claude Code platform limit, re-verified 2026-05-24 on 2.1.150) — the call either errors or silently degrades to inline generation, defeating the whole point of this requirement. These skills MUST dispatch a fork-safe `claude -p` subprocess via `~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode self-write` (Bash works from a fork; the subprocess is a genuinely independent process with its own context). This is the pattern `v-check` Step 4, `v-audit-growth`, and the design-family skills (`v-activation-funnel-design`, etc.) already use.
   - **Non-forked skills** (rare) may use the **Agent tool** (`Agent(model: "sonnet", prompt: "...")`) directly.
   - If unsure which applies, check the calling skill's own frontmatter for `context: fork`.
2. The dispatch prompt MUST include the **complete text** of sections 3a (dependency graph), 3b (session assignment), and 3c (file format) — not a reference like `[see below]`. The subagent/subprocess has no access to the skill file; it only sees what you put in the prompt.
3. Every pack named in `00-README.md`'s wave map MUST have a matching `w<N>-*.txt` (or wave-0 `*.txt`) file, and vice-versa (no phantom/orphan packs — the convention's self-validate checks this both ways).
4. Every pack file MUST start on line 1 with `/v ` (the orchestrator routing prefix) and be `.txt`.
5. Every pack MUST include the instruction `Read the project's CLAUDE.md first` and specify the tech stack (in `## Constraints`).
6. Every pack MUST be **self-contained** — no references to other prompt files, the audit JSON, or the plan. Inline the needed context into `## Context` (the cold agent has only this one file).
7. Every pack MUST carry the **body schema** (`## Goal / ## Context / ## Files / ## Changes / ## Acceptance criteria / ## Tests / ## Constraints / ## Dependencies`; read-only verify packs use `## Goal / ## Checks / ## Acceptance`) and have non-trivial content (>=50 lines). The literal `## Files` H2 is REQUIRED on implementation packs — v-build's scope guard keys on it. Empty or stub files are generation failures.
8. Every pack MUST be **paste-ready** — the operator copies the entire file content and pastes it verbatim into a fresh `/v` session. This means:
   - All placeholders like `[Project Name]`, `[tech stack]`, `[detected X]` MUST be substituted with actual values from the audit/orientation. Unsubstituted brackets force the operator to edit before pasting.
   - **Carve-out for intentional edit-flags:** the sigils `[REVIEW]` and `[unverified]` are operator-edit hints (e.g., for content drafts where the operator MUST review before publishing). These are intentional and not validator violations. v-content-create's `comparison` and `aeo` brief types (formerly the standalone v-comparison-page/v-aeo-content skills) use these sigils explicitly.
   - No pre-paste meta-instructions in the file body (e.g., "Run this in a parallel session" — the operator already knows; they're pasting it).
   - No frontmatter (no YAML front-matter, no `---` separators), no commentary above the `/v ` line, no "this file was generated by …" footer.
   - The first character of the file is `/`, the last meaningful content is the closing of the prompt body (verification, final fix, or the "leave staged; do not commit" closer). Nothing after. A pack MUST NOT instruct the session to `git commit`/`git push` — the operator/orchestrator owns commits (same commit-discipline rule as `v-runnable-pack-convention.md`; this line previously sanctioned a "commit message" ending, which contradicted that rule).

**Post-generation validation (mandatory — run in the MAIN context after the dispatched subagent/subprocess returns):**

**Canonical validator (wave form):** run the **§ Self-validate** block from `v-runnable-pack-convention.md`
(it checks `.txt` packs, first-line `/v `, the required `## Files` section, self-containedness, the
wave-map↔file parity, and stub/oversize bounds) followed by `run-v-packs "$PROMPT_DIR" --dry-run` to confirm
the wave plan resolves. `scripts/validate-audit-prompt-packs.sh` runs the same checks in CI. Failures trigger
one retry; a second failure is reported in the audit artifact under `## Prompt Pack`.

_The bash block below is the **legacy `NN-*.md` validator**, retained only so a project still holding
pre-2026-07-05 `.md` packs can be re-checked. New producers use the wave-form validator above, not this._

```bash
# ── Prompt pack structural validator ──────────────────────────────────────────
# PROMPT_DIR is set per-skill per the table above with the MM-DD date suffix
# (e.g., .v-prompt-packs/v-audit-messaging-05-01)
# Caller MUST compute date dynamically AND archive any same-day prior pack before subagent dispatch
# (per _v-audit.md § Step 3 — same-day re-run archive logic):
#   PROMPT_DIR=".v-prompt-packs/<skill-name>-$(date +%m-%d)"
#   if [ -d "$PROJECT_ROOT/$PROMPT_DIR" ] && [ -n "$(ls -A "$PROJECT_ROOT/$PROMPT_DIR" 2>/dev/null)" ]; then
#     mv "$PROJECT_ROOT/$PROMPT_DIR" "$PROJECT_ROOT/$PROMPT_DIR.bak-$(date +%Y%m%d-%H%M%S)-$(printf %04x $RANDOM)"
#   fi
#   mkdir -p "$PROJECT_ROOT/$PROMPT_DIR"
PROMPT_DIR="${PROMPT_DIR:?ERROR: PROMPT_DIR not set — see Per-skill MUST-USE values above}"
VALIDATION_FAILED=0
FAIL_MSGS=""

# Define fail() FIRST — bash does not hoist function definitions, so it must exist before any call site below.
fail() { VALIDATION_FAILED=1; FAIL_MSGS="${FAIL_MSGS}"$'\n'"  $1"; }

# Verify path is under .v-prompt-packs/ AND has -MM-DD suffix
# (catches skills that forgot the date suffix or use legacy non-dated form)
case "$PROMPT_DIR" in
  .v-prompt-packs/v-*-[0-9][0-9]-[0-9][0-9]) : ;;  # ok — .v-prompt-packs/<full-skill-name>-<MM-DD>
  .v-prompt-packs/v-*) fail "PROMPT_DIR=$PROMPT_DIR — missing -MM-DD suffix (per 2026-05 sweep convention; use \$(date +%m-%d))" ;;
  *) fail "PROMPT_DIR=$PROMPT_DIR — expected .v-prompt-packs/<full-skill-name>-<MM-DD> (per v-core-prompt-pack.md unified convention)" ;;
esac

# 1. Count files — expect README + session files (minimum 4 total)
FILE_COUNT=$(ls "$PROMPT_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
[ "$FILE_COUNT" -ge 4 ] || fail "expected at least 4 files (README + 3 sessions), found $FILE_COUNT"

# 2. Verify README exists
[ -f "$PROMPT_DIR/00-README.md" ] || fail "00-README.md missing"

# 3. Verify each SESSION file (exclude 00-README.md) starts with /v and has content
for f in "$PROMPT_DIR"/[0-9][0-9]-*.md; do
  [ -f "$f" ] || continue
  fname=$(basename "$f")
  [ "$fname" = "00-README.md" ] && continue
  [ -s "$f" ] || { fail "$fname is empty"; continue; }
  LINE_COUNT=$(wc -l < "$f" | tr -d ' ')
  [ "$LINE_COUNT" -ge 50 ] || fail "$fname has only $LINE_COUNT lines (requirement: >=50)"
  HEAD=$(head -1 "$f")
  echo "$HEAD" | grep -q '^/v ' || fail "$fname does not start with /v"
  # Detect unsubstituted placeholders — operator should never have to edit before pasting
  PLACEHOLDERS=$(grep -cE '\[(Project Name|tech stack|brief tech stack|detected [^]]+|brand voice|target audience|billing provider|current pricing|funnel stage|dimensions covered|domains covered|priority range|admin prefix|analytics provider)\]' "$f" 2>/dev/null || echo 0)
  [ "$PLACEHOLDERS" -eq 0 ] || fail "$fname has $PLACEHOLDERS unsubstituted placeholder(s) — operator must edit before pasting"
  # Detect pre-paste meta-instructions
  if grep -qE 'Run this (prompt )?in a (dedicated |parallel )?(Claude )?(session|worktree)' "$f"; then
    fail "$fname contains 'Run this in a session/worktree' meta-instruction (pre-paste cruft — remove)"
  fi
  # Forbid YAML frontmatter — first line must be /v, not ---
  if head -2 "$f" | grep -q '^---'; then
    fail "$fname has YAML frontmatter (forbidden — first line must be /v)"
  fi
done

# 4. Verify README session count matches file count
README_SESSIONS=$(grep -cE '^\| [0-9]' "$PROMPT_DIR/00-README.md" 2>/dev/null || echo "0")
ACTUAL_SESSIONS=$((FILE_COUNT - 1))  # subtract README
[ "$README_SESSIONS" -eq "$ACTUAL_SESSIONS" ] || fail "README lists $README_SESSIONS sessions but $ACTUAL_SESSIONS files exist"

# 5. Report result
if [ "$VALIDATION_FAILED" -eq 1 ]; then
  echo "PROMPT PACK VALIDATION FAILED:$FAIL_MSGS"
  # Trigger retry (see On validation failure below)
else
  echo "PROMPT PACK VALIDATION PASSED: $FILE_COUNT files"
fi
```

**On validation failure (`VALIDATION_FAILED=1`):**
- Re-dispatch the subagent/subprocess (per Generation requirements #1 above — the same mechanism used for the first dispatch) **once**, passing all `FAIL_MSGS` as context so it knows exactly what to fix.
- **Second attempt also fails:** Set `VALIDATION_FAILED=1` in the audit report under `## Prompt Pack`. Do NOT silently omit the prompt pack or claim the audit is complete without it. The audit score should reflect the generation failure.

**Skills that MUST implement this contract:** v-audit-admin, v-audit-analytics, v-audit-consolidate, v-audit-growth, v-audit-messaging, v-audit-sales-pricing, v-audit-seo, v-anti-template-gauntlet, v-prelaunch-readiness, v-audit-code, v-check, v-bug-hunt (both lenses), plus the design-family skills (v-pricing-design, v-beta-program, v-illustration-system, v-activation-funnel-design) which were migrated to `.v-prompt-packs/<full-skill-name>-<MM-DD>/` in the same 2026-04 sweep.

> **All producers emit the runnable wave form (2026-07-05 standardization):** every skill above writes the
> dated dir (`.v-prompt-packs/<skill>-<MM-DD>/`, same-day re-run archive) containing a `00-README.md` map +
> flat `w<N>-*.txt` wave packs (`99-verify` last) with the body schema, per
> `~/.claude/skills/references/v-runnable-pack-convention.md`, and self-validates via that convention's
> § Self-validate (+ `run-v-packs --dry-run`). A single-audit skill typically emits all findings as wave-0
> `*.txt` (disjoint files ⇒ parallel); `v-audit-consolidate` is distinguished only in that it dedups across
> MULTIPLE audits and therefore assigns real multi-wave ordering across the merged set.

**Validated like every other producer (carve-out retired 2026-07-05):** v-plan and v-discover-features now emit the unified `.txt` wave form + body schema (legacy aliases `v-plan-prompts/`, `v-feature-prompts/` still scanned by `/v` for backward compat; `v-refactor-prompts/` also still scanned as a read-only legacy alias for packs written before v-refactor was retired 2026-07-06) and self-validate with `scripts/validate-audit-prompt-packs.sh` + `run-v-packs --dry-run` — the old "plan-derived structure, exempt from validation" carve-out no longer applies. **Genuinely out of scope** (emit no session-paste pack at all): `v-polish` (writes a single `POLISH_PLAN_*.md`) and `v-content-create` (all brief types — `article`/`aeo`/`comparison`) / `v-marketing-design` / `v-launch-channels` / `v-build` (drafts, briefs, code, or content pages — not packs).

## Locating legacy/scattered packs (migration helper)

If you can't find a prompt pack you expect, older packs may still sit at a pre-migration or non-canonical location. One-liner to find every pack-shaped directory under a project root, canonical or legacy:

```bash
find "$PROJECT_ROOT" -maxdepth 2 -type d \( \
  -path "$PROJECT_ROOT/.v-prompt-packs/*" -o \
  -name 'v-plan-prompts' -o -name 'v-refactor-prompts' -o -name 'v-feature-prompts' -o -name 'v-prompts' \
\) 2>/dev/null | sort
```

Canonical packs are the `.v-prompt-packs/<full-skill-name>-<MM-DD>/` entries; anything matching the bare `v-*-prompts/`/`v-prompts` names is a legacy pre-migration pack — safe to run as-is (still `/v`-prefixed files) or to delete once superseded.
