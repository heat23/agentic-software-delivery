# Remediation format — self-contained fix packs

Turn each material finding into a **fix pack**: a single-subject, self-contained brief an implementer (human or coding agent) can execute without re-consulting you. This is the difference between "here are problems" and "here is the work."

**Delivery form:** each pack ships as a runnable `/v` prompt file — a flat **`.txt`** file (wave 0: `<finding-id>.txt`; ordered: `w1-<finding-id>.txt`, etc. — NOT `NN-<FINDING-ID>.md`), line 1 starting with `/v `, paste-ready, self-contained — per `~/.claude/skills/references/v-runnable-pack-convention.md` (canonical form + wave assignment; folder rule owned by `~/.claude/skills/references/v-core-prompt-pack.md`). That convention owns the file/directory structure; this document owns the **body** of each pack.

## Rules that make a pack good
- **One concrete change per pack, single-subject.** If a change spans tightly-coupled edits across a few files, keep it one pack and list each edit — but don't bundle unrelated fixes.
- **Verified anchors only.** Open the files; cite real `file:line`/symbol anchors at HEAD. Never write an anchor you haven't confirmed.
- **File-disjoint where possible.** Note what each pack touches (and what's out of scope) so independent packs can run in parallel without colliding. Push edits to a shared file into a later wave.
- **In-app remediation only** (no new vendors/services; conservative on new deps).
- **Test-first, and the test must not bless the bug.** Specify the test to write *before* the change; assert independent expected values; exercise the real persisted path, not an in-memory shortcut that bypasses the guard.
- **Real verify commands.** Use the project's actual test/lint/build/audit commands, plus a grep/assertion proxy that proves the specific fix landed.
- **No fabrication.** If a change surfaces a number, claim, or metric to a user, wire it to real computed data with an honest empty state — never invented values or placeholder testimonials/logos/counts.

## Pack-body shape (mandatory schema)
This is the brief that follows the `/v ` opener inside each `.txt` pack. Per `~/.claude/skills/references/v-runnable-pack-convention.md` § Pack body schema, the sections below MUST appear, in this order, on every implementation pack — literal H2 headings, not the labelled-line shape this file used before the 2026-07-05 standardization:

Severity `[P0|P1|P2|P3]` below is the canonical scale defined in `~/.claude/skills/references/v-core-severity.md` ([[v-core-severity]]) — use its definitions and verdict-impact rules, don't invent a per-pack meaning.

```
/v Fix production-readiness finding <ID> for [Project Name].

## Goal
Fix <ID> [P0|P1|P2|P3] (launch-gating|hardening|polish) — <short title>. <1-3 sentences: the outcome and why>.

## Context
Read the project's CLAUDE.md first for architecture context, conventions, and quality gate commands.
Tech stack: [from orientation].
**Problem:** <the wrong behavior + how to reproduce, OR current state + the gap; cite file:line — verified anchors only>
**Edge cases:** <empty / null / boundary / concurrency / error inputs relevant here>

## Files
- <path:line> — <what changes>
- <path> — <new/updated test file>
(name what is explicitly OUT of scope so parallel packs stay disjoint)

## Changes
<ordered, concrete edits per file: signatures, queries, exact changes — the design of the single change, in this project's idioms>

## Acceptance criteria
- [ ] <the fix lands and the reproduction/gap from ## Context no longer holds>
- [ ] No success-path regression
- [ ] Idempotent/concurrency-safe where state changes
- [ ] Gates stay green

## Tests
<the exact test(s) to write before the change, asserting independent values, exercising the real persisted path — never an in-memory shortcut that bypasses the guard>

## Constraints
- Read the project's CLAUDE.md first
- <the specific project idioms this change must follow>
- <in-app remediation only — no new vendors/services; conservative on new deps>

## Dependencies
Wave <N>. Requires: <prior pack name(s), or "none">.

Verify: <the project's real commands + a named grep/assertion proxy for this fix>

Leave all changes staged; do NOT commit — the operator/orchestrator owns commits.
```

Give each pack a unique UPPERCASE-WITH-HYPHENS finding ID (embed it in `## Goal`'s first line, e.g. `Fix OG-01 [P0] ...` — no separate `FINDING` line required). The **closing waves are the full triad, not just `99-verify.txt`** — SKILL.md Step 5 and `~/.claude/skills/references/v-runnable-pack-convention.md` § `## Closing waves (always append)` own the exact sequence (parallel `w<N>-pre-flight.txt` + `w<N>-review.txt`, then sequential `w<N+1>-hardening.txt`, then `99-verify.txt` last). Each read-only pack (`99-verify.txt`, the pre-flight/review packs) uses `## Goal` · `## Checks` · `## Acceptance` and omits `## Files`/`## Tests`/the staged closer, per the convention's read-only pack shape. Do not treat `99-verify.txt` as the sole closer — that is the last wave, not the whole closing set.

## Ship a validator
Two layers, both must PASS before the batch is done:
1. **Structural** — run the self-validate block from `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree — or `~/.claude/scripts/validate-audit-prompt-packs.sh "$PROMPT_DIR"` (00-README.md present, every pack is `.txt` and starts with `/v `, non-stub, `## Files` present on implementation packs, wave-map table matches files on disk both ways), then `run-v-packs "$PROMPT_DIR" --dry-run` to confirm the wave plan resolves.
2. **Content** — drop a `validate.py` next to the packs for the body checks below, and run it until it prints PASS. (If `python3` isn't available, ship an equivalent `validate.sh` with the same checks and exit-code contract.) Adapt these checks to your chosen pack shape:
- every pack file's first line is `/v ` and the file is `.txt`;
- no markdown fences or stray formatting that would confuse an executing agent;
- exactly one finding ID embedded in `## Goal` per implementation pack, with a unique ID (no duplicates across packs);
- required sections present (`## Files`, `## Tests`, and an acceptance-criteria checklist at minimum);
- the batch verification pack (`99-verify.txt`) is exempt from the per-pack structural checks.
Print `PASS: <n> packs ...` or `FAIL` with the offending `file:line`, exiting non-zero on failure.

One gotcha worth hard-coding: if your validator flags "verify" packs by filename, don't let an implementation pack whose name merely *contains* "verify" (e.g. `BACKUP-VERIFY-ALERT`) get mis-classified and skipped — match the batch verifier explicitly, or name implementation packs to avoid the token.

## Waves
If some packs must touch the same file, group the file-disjoint ones into a wave that runs in parallel and defer the second editor of any shared file to the next wave. Keep the whole batch in one folder; state the dependency order.
