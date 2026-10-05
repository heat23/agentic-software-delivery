# Prompt Pack Detection (extracted from /v SKILL.md Entry section)

> **Loaded by:** /v Entry sequence, after Handoff Check. Inline /v SKILL.md should
> have only a one-line stub naming this reference. Triggers only when prompt pack
> directories exist on the filesystem AND the user typed `/v` with empty args.

## Detection bash

```bash
# Every producer now writes under the single canonical root .v-prompt-packs/<full-skill-name>-<MM-DD>/
# (v-core-prompt-pack.md § Unified folder convention) — but the pack SHAPE inside that dir differs by
# producer: the audit-family + v-plan/v-discover-features emit NN-*.md (v-audit-code, which absorbed
# v-refactor 2026-07-06, is part of the audit-family shape); v-audit-consolidate and
# v-prompt-pack-generate emit the runnable wave form (flat w<N>-*.txt / 99-*.txt per
# v-runnable-pack-convention.md). Detect BOTH shapes or the wave-form packs are silently invisible here.
PROMPT_PACKS=""

if [ -d "$PROJECT_ROOT/.v-prompt-packs" ]; then
  for D in "$PROJECT_ROOT/.v-prompt-packs"/v-*; do
    [ -d "$D" ] || continue
    [ -f "$D/00-README.md" ] || continue
    # Shape A: audit-family / plan-family NN-*.md
    TOTAL_MD=$(ls "$D"/[0-9][0-9]-*.md 2>/dev/null | wc -l | tr -d ' ')
    # Shape B: runnable wave form — unprefixed *.txt, w<N>-*.txt, and 99-*.txt (excludes 00-README.md)
    TOTAL_TXT=$(find "$D" -maxdepth 2 -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
    TOTAL=$((TOTAL_MD + TOTAL_TXT))
    [ "$TOTAL" -eq 0 ] && continue
    DNAME=".v-prompt-packs/$(basename "$D")"
    PROMPT_PACKS="${PROMPT_PACKS}${DNAME} (${TOTAL} sessions)\n"
  done
fi

# Legacy pre-migration packs (bare, undated root — kept only for backward compat with packs written
# before a producer migrated to the dated .v-prompt-packs/<skill>-<MM-DD>/ root; every current producer
# writes the canonical form above, so a hit here is always an OLD pack).
for DIR in v-plan-prompts v-refactor-prompts v-feature-prompts v-prompts; do
  if [ -d "$PROJECT_ROOT/$DIR" ] && [ -f "$PROJECT_ROOT/$DIR/00-README.md" ]; then
    TOTAL=$(ls "$PROJECT_ROOT/$DIR"/[0-9][0-9]-*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$TOTAL" -eq 0 ] && continue
    PROMPT_PACKS="${PROMPT_PACKS}${DIR} (${TOTAL} sessions)\n"
  fi
done
```

## Missing-final-verify guard (F2, 2026-07-05)

A wave-form tree (Shape B) that has any `w<N>-*.txt` file but no `99-*` final verify pack is an
INCOMPLETE tree — the closing verification wave (`v-runnable-pack-convention.md` § Closing waves) was
never appended. Silently presenting such a tree as "ready to run" defeats the whole verify-last
contract: nothing ever re-asserts the waves actually landed clean. Run this alongside the Detection
bash above, per Shape-B dir `$D` that produced a nonzero `TOTAL_TXT`:

```bash
HAS_WAVE=$(find "$D" -maxdepth 1 -type f -name 'w[0-9]*-*.txt' 2>/dev/null | head -1)
HAS_99=$(find "$D" -maxdepth 1 -type f -name '99-*' 2>/dev/null | head -1)
if [ -n "$HAS_WAVE" ] && [ -z "$HAS_99" ]; then
  echo "WARNING: $(basename "$D") has wave-prefixed packs but no 99-* final verify pack — this tree is incomplete; do not treat it as done until a 99-verify pack is added (by the producer) and executed."
fi
```

Surface any such WARNING to the user alongside the pack listing (append it to the `PROMPT_PACKS` entry
or print separately) rather than silently proceeding — a missing final-verify pack means "done" can
never be truthfully asserted for that tree.

## Execution-time claim verification — `## Verified context` / `requires:` (F2, 2026-07-05)

A session file may carry a `## Verified context` section asserting prior work already landed (e.g.
`app/Services/ExampleReader.php ... landed in wave-0 example-gateway`) with a machine-checkable
`requires:` line. This is a SNAPSHOT taken at GENERATION time — packs can sit unrun for days, and by
execution time the claim may be stale, reverted, or never true (the phantom-context class: R3 P0-1 saw
a claimed function existing nowhere but in comments). The generator side is hardened too (F2 same day:
`v-runnable-pack-convention.md` § Verified-context claims are TRUTH-checked at generation — every claim
must be live-checked against main and stamped `[verified main@<sha>]`, and the self-validate hard-fails
unstamped claims), but that stamp is still a GENERATION-time snapshot and the self-validate runs only
once, at generation time. Do not trust the prose — or the stamp — as an execution-time guarantee.

**Before executing (Step 5 below) any session file with a `## Verified context` block**, re-verify each
`requires:` claim against the CURRENT repo state, right before running it — this is real verification,
not a re-statement of the pack's own text:

```bash
# $PROJECT_ROOT = repo root; REQ_PATH/REQ_SYMBOL parsed from the pack's `requires: <path>: <symbol>` line.
VERIFY_SHA="$(cd "$PROJECT_ROOT" && git rev-parse main 2>/dev/null)"
if [ -z "$VERIFY_SHA" ]; then
  echo "BLOCKED: cannot resolve main — cannot verify claimed context; do not proceed on the unverified claim"
elif ! (cd "$PROJECT_ROOT" && git show "main:$REQ_PATH" 2>/dev/null | grep -qF "$REQ_SYMBOL"); then
  echo "BLOCKED: claimed context '$REQ_PATH: $REQ_SYMBOL' not found in main@$VERIFY_SHA — the pack's Verified context is stale or false; stop and surface this to the user instead of proceeding"
else
  echo "VERIFIED: $REQ_PATH: $REQ_SYMBOL present in main@$VERIFY_SHA"
fi
```

If any `requires:` entry comes back `BLOCKED`, do not silently execute the pack's task as written —
surface the discrepancy (plain report or AskUserQuestion) instead of proceeding on the unverified
assertion. If every entry comes back `VERIFIED`, record the `VERIFY_SHA` used (e.g. in the session's own
notes/first message) as the proof — "verified" means a live `git show`+`grep` against main confirmed it
at this specific SHA, never the pack author's prose alone.

## Branch logic

**If packs found AND the args string is empty or whitespace-only (the user typed literally `/v` with no content):** present option:

```yaml
question: "I found unexecuted prompt packs from previous sessions. Want to run one?"
header: "Prompt Packs"
multiSelect: false
options:
  - label: "Run next prompt pack (Recommended)"
    description: "I'll show you the available packs and execute the next session file"
  - label: "Ignore and start fresh"
    description: "Skip prompt packs and classify your request as a new task"
```

**If "Run next" selected:**
1. Multiple pack dirs → AskUserQuestion to pick.
2. Read `00-README.md` for session map.
3. Determine unexecuted sessions: check for matching `IMPLEMENTATION_REPORT_*` / `AUDIT_REPORT_*` artifacts referencing session topic, or `git log --grep="<topic>"`. Uncertain → present list, ask user. **A `99-*` final verify pack is never marked "unexecuted-evidence-found" by an earlier wave's `IMPLEMENTATION_REPORT_*`/`git log` hit** — those only prove the implementation waves ran, not that the read-only verify pack itself did. Only direct evidence the verify pack itself ran (its own `VERIFY_DONE_REPORT_*`/explicit pass output referencing it by name) counts.
4. Read next unexecuted session file. Shape depends on which producer generated the dir: `NN-*.md` (audit/plan family — e.g. `01-topic.md`) OR the runnable wave form's flat `*.txt`/`w<N>-*.txt` (e.g. `w1-topic.txt`, unprefixed first, then `w1-`, `w2-`, … , `99-` last per `v-runnable-pack-convention.md`). Either shape: pick the earliest-wave file not yet executed. If the file carries a `## Verified context` block, run the Execution-time claim verification above FIRST and resolve any `BLOCKED` before proceeding.
5. Session file content IS the prompt — starts with `/v`, self-contained. Execute it as if user typed it directly. Normal Step 1 onward takes over. **If the file is the `99-*` final verify pack: it is NOT optional.** Never let earlier waves "looking done" substitute for actually running it — a wave-based tree is only truthfully done once its own 99-verify pack has executed and passed.

**If the args string contains any non-whitespace content:** treat as a specific task — skip this entire Prompt Pack Detection section, including the AskUserQuestion above. (Tightened W25-F2 — previously this said "not just `/v`" which left the empty-vs-non-empty judgment to the model and caused misfires on short image-attached prompts.)

**If packs found AND user has specific task:** append at session end: `"Note: You have unexecuted prompt packs in [directories]. Run /v to pick up where you left off."` Don't interrupt current task.
