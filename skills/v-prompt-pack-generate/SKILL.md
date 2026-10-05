---
name: v-prompt-pack-generate
description: "Use when turning a finished PLAN_*.md into runnable wave-organized /v prompt packs (flat w<N>-*.txt, executable unattended via run-v-packs)."
allowed-tools: Read, Glob, Grep, Bash, Agent, AskUserQuestion, Write
argument-hint: "[PLAN_*.md] (optional — defaults to the plan matching this session)"
user-invocable: true
model: sonnet
---
<!-- skill: v-prompt-pack-generate | version: 1.6.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: User-facing. Plan-to-execution transform — input is a finished plan, output is a paste-ready, **runnable** wave/pack tree (no code is written).

Follow `_v-core.md` for stack detection, changed-file detection, and shared conventions. Reuse the prompt-pack folder rationale from `~/.claude/skills/references/v-core-prompt-pack.md`. The output is **runner-ready** — it follows `~/.claude/skills/references/v-runnable-pack-convention.md` so the operator can `run-v-packs <dir>` it directly. That convention is also the **single source of truth for wave assignment, closing waves, and the self-validate** (Steps 2–3 and 5 below cite it rather than restate it).

```yaml
contract:
  tier: user-facing
  accepts:
    - plan_path: string (optional — a PLAN_*.md; defaults to the plan matching $CLAUDE_SESSION_ID, else most-recent)
  produces:
    - .v-prompt-packs/<slug>-<MM-DD>/ runnable wave tree (00-README master map + FLAT wave-prefixed paste-ready
      /v packs: w1-*.txt, w2-*.txt, …, 99-*.txt verify last) per v-runnable-pack-convention.md — `run-v-packs`-ready
    - OPTIONAL (Step 7, explicit operator opt-in only) — copies of the packs queued into
      <project_root>/.v/packs/inbox/ + registry line via register-pack-inbox.sh, per v-core-pack-inbox.md
  invokes: []
  conditional-invokes:
    - /v-plan (referral when no usable plan exists)
    - /v-build (referral to execute a plan directly without packs)
    - /v-audit-consolidate (referral when the input is several audit reports to consolidate, not a plan)
  invoked-by: [/v, user]
  estimated_tokens: 20k-60k
  estimated_duration: 5-20 min
```

# /v-prompt-pack-generate — Runnable wave-organized prompt packs from a plan

Takes a finished `PLAN_*.md` and produces an executable pack tree: **waves** (sequential) of **packs** (parallel-safe within the wave), each pack a self-contained `/v` prompt the operator pastes into a fresh session **or hands to `run-v-packs`**. The defining feature vs. a mechanical split is **Step 1 grounding**: the skill opens the real files the plan references and verifies them before partitioning, so packs reflect the tree as it actually is (catching drift, already-done items, and stale plan mistakes).

## Execution Context (read first)

Parse the invocation context before any work, per `_v-core.md` § V_DEPTH Parsing Protocol (Mandatory) and § Project Root Detection:

- **V_DEPTH** — search the invocation prompt for `[V_DEPTH=N`, then bare `V_DEPTH=N` as a fallback; default `0` (direct user invocation). `V_DEPTH >= 1` means `/v` (or a sibling) invoked this skill and owns entry-point questions — this skill must NOT ask.
- **PROJECT_ROOT** — invocation-prompt `PROJECT_ROOT=` → `git rev-parse --show-toplevel 2>/dev/null`. At `V_DEPTH == 0` and not a repo, ask for the root. At `V_DEPTH >= 1`, or on any unresolved/forbidden root (`$HOME`, `/`, `/Users`, `/tmp`, `/var`, `/usr`, `/System`, `/Library`, `/Volumes`), do NOT fall back to `pwd` — write `BLOCKED_${CLAUDE_SESSION_ID}.md` naming the unresolved root and stop. Every pack-tree write is anchored under `$PROJECT_ROOT`.
- **Real dates only** — `$(date +%m-%d)` for the pack dir and `$(date +%Y%m%d-%H%M%S)` for the archive suffix; never fabricate a date from memory.

**Non-interactive fallback (V_DEPTH >= 1):** `AskUserQuestion` and every "confirm with the operator" step hang when orchestrator-invoked. In that context resolve everything autonomously and NEVER ask:
- **Plan resolution (Step 0.2)** — explicit arg path → deterministic session match `PLAN_*_${CLAUDE_SESSION_ID}.md` → single most-recent `PLAN_*.md` at repo root. If the most-recent branch is genuinely ambiguous (multiple candidates, none session-matched) or no plan exists, do NOT ask and do NOT invent one — write `BLOCKED_${CLAUDE_SESSION_ID}.md` naming what's missing and stop. The `/v-plan` referral (Step 0.2) is the interactive **V_DEPTH == 0** path; at depth ≥ 1 it degrades to a `BLOCKED_${CLAUDE_SESSION_ID}.md` marker so a headless fleet run never strands on a prompt. (`/v-audit-consolidate` and `/v-build` are scope-clarifications in § Use instead, not gated STOP branches.)

The Step 0.2 operator confirmation fires ONLY at `V_DEPTH == 0`.

## Skill Boundaries

**SME persona:** Run by a **delivery/release engineer** who converts an approved plan into a parallelizable execution schedule — file-level dependency analysis, wave sequencing, and paste-ready session prompts.

### Best fit
- An approved `PLAN_*.md` exists and the operator wants to execute it as parallel sessions.
- Run immediately after `/v-plan` in the same session (warm context = better grounding, cheaper).
- Plans large enough to benefit from parallelism (roughly 4+ implementation tasks).

### Use instead
- `/v-plan` — to author or revise the plan itself.
- `/v-build` — to execute a plan directly without packs.
- **`/v-audit-consolidate`** — when the input is several `v-audit-*` outputs (finding reports) rather than a plan. It owns audit dedup (finding-fingerprint + severity normalization + provenance) and emits the SAME runnable wave form this skill emits (both follow `v-runnable-pack-convention.md`). A single audit's pack dir already runs as-is — just `run-v-packs` it.

### Not for
- Plans under ~8h / 1–2 sessions — emit a lightweight inline checklist instead of a pack tree (note this to the operator and stop; at `V_DEPTH >= 1` also write the checklist to `BLOCKED_${CLAUDE_SESSION_ID}.md` so the headless run leaves a durable marker).
- Writing code. This skill only authors prompt files.

### Relationship to /v-plan's built-in pack step
`/v-plan` already emits session-based packs at its step 6 (flat `NN-*.md`, layer-grouped, generated from the plan without a fresh grounding pass). Use THIS skill when you want the heavier treatment: a **codebase-grounding pass** (Step 1), **wave** organization (parallel-within-wave, sequential-across) instead of coarse layer sessions, and built-in **verification + hardening** waves. It also runs standalone on a plan that was never packed, or to RE-pack a plan after the tree drifted. The two are complementary, not redundant — this one trades more up-front analysis for tighter parallelism and trustworthier anchors.

### Finding the plan in the same session
This skill is meant to run right after `/v-plan` in one session. `/v-plan` writes `PLAN_[timestamp]_${CLAUDE_SESSION_ID}.md`, so the Step 0 glob `PLAN_*_${CLAUDE_SESSION_ID}.md` matches it deterministically — `$CLAUDE_SESSION_ID` is the same env var in both invocations. If the operator hand-named the plan (no session id) or runs in a fresh session, fall through to the explicit-arg / most-recent-plan branches and confirm.

## Inheriting conventions

Follow the project's `CLAUDE.md` (root + any subdir CLAUDE.md for touched areas) for stack, gates, and rules. Reuse the prompt-pack folder rationale from `~/.claude/skills/references/v-core-prompt-pack.md` (single top-level `.v-prompt-packs/` namespace, no nested `/prompts/`, paste-ready files starting with `/v`). Output the **runnable** form in `~/.claude/skills/references/v-runnable-pack-convention.md`: a **flat** dir whose **wave is a filename prefix** (`w1-…`, `w2-…`, `99-…` verify last), each pack a `.txt` file — so the operator can `run-v-packs <dir>` it with no conversion.

## Workflow

### Step 0 — Resolve the plan
1. **Project root:** resolve `$PROJECT_ROOT` per **§ Execution Context** (invocation-prompt `PROJECT_ROOT=` → `git rev-parse --show-toplevel` → at `V_DEPTH == 0` ask; at `V_DEPTH >= 1` or a forbidden root write `BLOCKED_${CLAUDE_SESSION_ID}.md` and stop). Never fall back to `pwd` blindly. All writes below anchor under `$PROJECT_ROOT`.
2. **Resolve a single `PLAN_*.md`** in priority order: explicit arg path → the plan matching this session `PLAN_*_${CLAUDE_SESSION_ID}.md` → most-recent `PLAN_*.md` under `.v/artifacts/` then repo root (**V_DEPTH == 0 only:** confirm with the operator, `ls -t .v/artifacts/PLAN_*.md PLAN_*.md | head`; at V_DEPTH >= 1 take the single most-recent autonomously, or BLOCKED if ambiguous — see § Execution Context).
   - If args are empty AND no session plan exists AND no recent plan exists, STOP and refer to `/v-plan` (at V_DEPTH >= 1, write `BLOCKED_${CLAUDE_SESSION_ID}.md` instead of referring interactively). (If the operator actually has several `v-audit-*` reports to turn into one queue, that's `/v-audit-consolidate`, not this skill.)
3. **Slug:** kebab slug from the plan's H1 title (fallback: filename minus timestamp/UUID). `# PLAN — Example Feature MERGED …` → `example-feature-merged`. Keep it short.
4. **Pack root:** `.v-prompt-packs/<slug>-$(date +%m-%d)/`. If it exists and is non-empty (same-day re-run), archive it to `<dir>.bak-$(date +%Y%m%d-%H%M%S)` before writing (mirror the re-run behavior in `v-core-prompt-pack.md`).

### Step 1 — GROUND against the codebase (the step that makes packs trustworthy)
Do NOT trust the plan's anchors blindly. For every target file the plan's `## Files` section names (modify + create):
- **Modify targets:** `Read` the file (don't infer from the plan text) — verify the cited line anchors, that the described code actually exists, and that the change isn't already done. Re-grep any symbol/helper/route the plan assumes exists.
- **Create targets:** confirm they don't already exist.
- Capture a short **verified-state note**: `already-done` (skip), `drifted` (corrected anchor), `plan-wrong` (the plan's premise is off — flag it, don't silently propagate).
- **"Already added / already landed" claims are LIVE-checked against `main`, per claim, before any pack carries them (F2, 2026-07-05 — NORMATIVE, convention § Verified-context claims are TRUTH-checked at generation).**
  - **What to check:** any statement destined for a pack's `## Verified context` asserting prior work exists ("X already added by wave-0 <pack>", "landed in <session>") must be verified with a real content check against the target repo's `main` at generation time — `git show main:<path> | grep -F '<symbol>'` (file-existence form: `git cat-file -e main:<path>`) — NEVER passed through from plan/prior-pack/transcript prose on faith.
  - **How to stamp:** stamp each verified claim `[verified main@<sha>]` (`git rev-parse --short main` at check time) and put the evidence line `Generation-time verification: every claim below was live-checked via git show main:<path> | grep '<symbol>' at main@<sha> on <date>.` directly under the `## Verified context` heading.
  - **On failure:** **a claim that fails the check is never emitted as "Verified":** either FAIL generation of that pack (the premise is false — same STOP path as a materially-wrong plan, Gotcha 4), or, if the pack stands without it, downgrade the line to `[UNVERIFIED — verify before relying]` backed by a `requires:` grep + runtime STOP+`BLOCKED_<sid>.md` gate.
  - Ground truth: a wave-0 registry pack was never written, yet two downstream packs shipped `Verified context: ExampleOperation::ExampleCase already added — do NOT edit ExampleOperation.php`; one executing session violated its own scope guard, another stranded.

**If the plan has no `## Files` section or no per-task file breakdown** (e.g. a Quick-depth sketch): you cannot build a reliable dependency graph. Either (a) reconstruct file targets by grounding each task description against the codebase yourself, or (b) if the plan is too thin to ground, STOP and tell the operator to re-run `/v-plan` at Standard/Comprehensive depth (at `V_DEPTH >= 1`, write `BLOCKED_${CLAUDE_SESSION_ID}.md` naming the too-thin plan instead of a prose message no headless run will read). Do not invent a file partition from task titles alone.

If running in the warm planning session, reuse what's already in context instead of re-reading — but still spot-check anything the packs will hard-code (anchors, helper names, enum cases). If grounding reveals the plan is materially wrong, STOP and report to the operator rather than generating packs against a bad premise.

### Step 2–3 — Partition into waves (per `v-runnable-pack-convention.md` § Wave assignment)
The grounded plan tasks are the **work items**. Partition them with the convention's algorithm — read `~/.claude/skills/references/v-runnable-pack-convention.md` § Wave assignment and apply it verbatim:
- file set per task (source + test + config) → **conflict edges** (file intersection) → **dependency edges** (B consumes A's output) → assign waves so two packs share a wave **only if their file sets are disjoint AND neither depends on the other**;
- order waves foundation → services/contract → wiring → frontend types → leaf components → coupled components; put each independent track in the earliest wave its dependencies allow;
- wave 0 (no prefix) is the common case; same file / different fix ⇒ different waves; merge tightly-coupled files into one pack.

Then append the standard **closing waves** per the convention's § Closing waves: a verification wave (`w<N>-pre-flight.txt` + `w<N>-review.txt`, parallel READ-ONLY), a `w<N+1>-hardening.txt` (sequential, the only post-impl wave that edits source), and `99-verify.txt` (final gate-runner, always last). **`99-verify.txt` MUST carry a single `<!-- v-verify-gate: <the project's full green-bar gate command> -->` HTML-comment line** (the SAME command its `## Checks` prose names — e.g. `<!-- v-verify-gate: php artisan test --parallel && npm run build && composer audit && npm audit --audit-level=critical -->`). This is the runner's fork-park backstop: the verify pack runs headless under `claude -p`, and if its session dispatches gates/bug-hunts as backgrounded subprocesses it exits at 0 turns with no completion token — so `run-v-packs` re-runs THIS command synchronously to key the GO/NO-GO on a real exit code instead of stranding a fully-green batch at exit 2 (observed live 2026-07-16). Omit it and a fork-parked verify session forces human intervention on a green batch — the self-validate (§ below) flags its absence. For the review pack, defer to the project's `.claude/agents/` matching the changed file types, always include an adversarial reviewer (codex-adversarial-reviewer, fallback `superpowers:requesting-code-review`), and include a framework-pitfall reviewer ONLY when the diff touches queues/listeners/middleware/signature-verification/cache-key/audit-schema/env-gated runtime.

**Security-bearing packs carry their OWN adversarial review** (per `v-runnable-pack-convention.md` § Security-bearing packs — NORMATIVE, forensic 2026-07-03, an external API client adapter pack). While auditing each pack's file set, flag any pack that touches **request signing / HMAC / signature or webhook verification, credential or secret handling, host/URL construction from variables, auth/authz decisions, or payment flows**. Into THAT pack's prompt (not just the closing wave) write: *"This pack touches security-bearing code — dispatch an adversarial reviewer (codex-adversarial-reviewer, fallback `superpowers:requesting-code-review`) on your own diff before finishing; fix CRITICAL/HIGH findings in-session."* Deferring ALL adversarial review to the closing wave means staged Wave-0…N security code carries HIGH bugs for the fleet's entire lifetime and whichever copy lands first wins — this per-pack pass is defense-in-depth for the stage→land window, not a replacement for the closing verification wave.

**The grounding (Step 1) and the wave assignment here are done by the main skill, not delegated** — the Step 4 subagent only writes the files from the assignment you hand it.

### Step 4 — Write the pack tree
**Flat, runner-ready layout** (`v-runnable-pack-convention.md`): one dir, wave encoded as a filename prefix, packs are `.txt`:
```
.v-prompt-packs/<slug>-<MM-DD>/
  00-README.md                         ← master: wave map, deps, invariants (NOT a pack)
  <task-a>.txt   <task-b>.txt          ← wave 0: NO prefix; independent, runs first/in parallel (DISTINCT names; the common case)
  w1-<task-a>.txt   w1-<task-b>.txt    ← wave 1: parallel packs (disjoint files, DISTINCT names); each a /v prompt
  w2-<slug>.txt                        ← wave 2: starts after wave 1 completes
  …
  w<N>-pre-flight.txt  w<N>-review.txt ← verification wave (parallel, read-only)
  w<N+1>-hardening.txt                 ← hardening (sequential, single)
  99-verify.txt                        ← final gate-runner, always runs last
```
Wave 0 packs (no dependency on anything) take **no prefix**; they run first/in parallel. Each still needs a **distinct descriptive name** (`<task>.txt`) — only a lone wave-0 pack may use the bare `<slug>.txt` (two wave-0 packs both named `<slug>.txt` would collide and one would silently overwrite the other). Use prefixes only where ordering actually matters.

For a large/complex plan, dispatch the file-writing to an **Agent subagent** (`Agent(model: "sonnet", …)`) with the COMPLETE grounded task list, dependency graph, wave assignment, the per-pack **security-bearing flags** from Step 2–3, and the pack/README templates pasted in full (the subagent can't see this skill). For small inputs, write inline. Either way, the grounding (Step 1) and wave assignment (Steps 2–3) are done by the main skill, not delegated. (This skill runs in the main context — it is NOT `context: fork` — so the Agent dispatch executes; if for any reason a dispatch is unavailable, fall back to writing the tree inline rather than silently skipping it.)

**Master `00-README.md` includes:** project + source plan filename + slug; how-to-run note (**"`run-v-packs <this dir>` runs it end-to-end: packs in a wave run in parallel, a wave starts only after the prior wave completes; or paste a single pack into a fresh `/v` session"**); a wave-map table `| Wave | Prefix | Parallel packs | Depends on | Gate |`; dependency rationale; cross-cutting invariants distilled from the plan + CLAUDE.md (e.g. no migrations/routes unless specified, TDD for backend logic, no `any`, run-only-changed-tests during dev, **no auto-commit — leave staged**); and any corrections found in Step 1.

**Each pack `w<N>-<slug>.txt`** (paste-ready — first character is `/`, no frontmatter, no commentary above the `/v` line, no "generated by" footer):
```
/v <imperative task title>.

Read <the PLAN file> (cite the relevant decisions/seams/acceptance) and CLAUDE.md (+ relevant subdir CLAUDE.md) first. <one line of stack + hard constraints, e.g. NO migration/route change>.

## Requires (verify BEFORE editing — this is a snapshot from generation time, not a live guarantee)
requires: <grep -n "<symbol/anchor>" <file>>  — <what this pins, e.g. "exampleGuard() must exist on ExampleGuard">
requires: <one line per anchor the task below depends on that isn't self-evident from the diff>
Runtime precondition check (run FIRST, before any edit): re-run every `requires:` grep above against the CURRENT tree. A pack can sit unrun for days — grounding done at generation time is not proof the anchor still exists at execution time (forensic R3 P0-1: a pack claimed `exampleGuard()` existed; it existed nowhere in the source tree except comments citing it). If any anchor is missing or no longer matches, STOP — do NOT reconstruct or invent it from the plan text — write `BLOCKED_<sid>.md` naming the missing anchor and end the session.

## Verified context (as of generation — re-verify via the `requires:` greps above before trusting it)
Generation-time verification: every claim below was live-checked via git show main:<path> | grep '<symbol>' at main@<sha> on <date>.
- <file:anchor> — <what's there now, corrected if drifted; "re-grep before editing if drifted"> [verified main@<sha>]
- <dependency this pack consumes from an earlier wave> [verified main@<sha>]  (a claim whose live check FAILED is either dropped with the pack — see Step 1 — or written as [UNVERIFIED — verify before relying] with its own requires:/BLOCKED gate)

## Task(s)
<for backend logic: TDD — failing test first, then implement>
<exact change: model fields/relationships, controller actions + form-request rules, enum cases, or for UI the props/component structure + route names>

## Tests
<exact test cases to write/update>

## After
<the per-pack gate command — run ONLY the touched tests>. The full gauntlet (pre-flight, review, verify-done) is NOT skipped — it is DEFERRED to this tree's closing verification (`w<N>-pre-flight.txt`/`w<N>-review.txt`) and hardening (`w<N+1>-hardening.txt`) waves; this pack's own gate is scoped to its own diff only. Before finishing, write `.v/artifacts/IMPLEMENTATION_REPORT_<sid>.md` (`$CLAUDE_SESSION_ID`-keyed; Phase-2 — create the dir; the runner's Stop hook dual-searches `.v/artifacts/` then root) recording files changed and "gates deferred to w<N>" — this is the witness the runner-managed staged-handoff contract checks for (a session that leaves work staged with no commit needs this marker to resolve cleanly). Do NOT commit; leave staged for the next wave.
```

Pack-writing rules:
- **First line is an invocation:** `/v <task>` for implementation packs (orchestrator routes them), OR a direct sub-skill call `/v-<skill> <args>` when the pack maps cleanly to one (e.g. a verification pack is `/v-pre-flight`, a convention pass is `/v-verify-done`). Either way the file's first character is `/` and the first token is `/v…`.
- Self-contained — reference the PLAN file by path, but no references to sibling pack files.
- Substitute all placeholders with real values (project name, stack, paths, verified anchors).
- Include the specific tests + the gate so the implementing agent knows when it's done.
- Carry the plan's relevant seams/decisions inline so a cold agent has them.
- **Size budget: one single session's worth of work — hard ceiling ~25KB (bytes), structural ceiling ~3500 lines, whichever the pack hits first.** The cold agent executing a pack has no other context — don't under-fill it to hit a smaller number; use the room for verified anchors, full acceptance criteria, and edge cases. But the **binding limit is ~25KB**: `run-v-packs` treats a single file larger than that as a concatenated *bundle*, refuses to run it as one session, and warns loudly (convention § What is a "pack"). A pack that approaches either ceiling is carrying too many unrelated concerns — split it into narrower packs, don't trim the detail a cold agent needs.
- **`requires:` greps + runtime precondition check, not a future-fact "Verified context".** Anything the pack asserts exists (a helper, a guard function, a config key) must be backed by a `requires: <grep>` line AND the instruction to re-run it before editing — grounding is a snapshot from generation time, and a pack tree can sit unrun for days (the R3 P0-1 forensic; see the runtime precondition check in the Step 4 pack template above). A missing anchor at execution time means STOP + `BLOCKED_<sid>.md`, never silently reconstructing it from the plan.
- **Every Verified-context claim carries its truth stamp.** Per Step 1's live-check rule (F2): each claim line ends `[verified main@<sha>]` (or `[UNVERIFIED — verify before relying]` after a failed check), and the `Generation-time verification: … git show main:<path> …` evidence line sits directly under the heading. The convention's self-validate (Step 5) hard-fails any pack whose Verified-context bullets lack the stamp or whose section lacks the evidence line — a bare "already added/landed" assertion can no longer pass generation.
- **Security-bearing packs get an in-pack adversarial-review instruction.** If the pack's file set touches request signing / HMAC / signature or webhook verification, secret/credential handling, host/URL construction from variables, auth/authz, or payment flows, add a `## Security review (before finishing)` line telling the executing agent to run codex-adversarial-reviewer (fallback `superpowers:requesting-code-review`) on its own diff and fix CRITICAL/HIGH in-session — do NOT rely solely on the closing verification wave (convention § Security-bearing packs).
- **Staged-handoff exits write the resolver witness.** Every implementation pack ends "leave staged; do not commit" — that is a runner-managed staged-handoff exit, and it must instruct writing `IMPLEMENTATION_REPORT_<sid>.md` before finishing so the session-log resolver can bind it (a staged-only exit with no witness reads as an unaccounted-for session). The "## After" section also restates that the full gauntlet is deferred to the closing waves, not skipped.

### Step 5 — Self-validate output
Run the self-validate from `~/.claude/skills/references/v-runnable-pack-convention.md` § Self-validate the emitted tree (substitute the real `PACK_ROOT`): the structural check (each pack's first non-blank line is `/v…`, no frontmatter, no bare `git commit`/`git push`, ≥10 lines, `00-README.md` present), the **wave-map↔pack-file parity check** (every pack name in `00-README.md`'s wave-map table exists on disk and vice versa — fails loudly rather than silently generating a tree with phantom or orphan packs), the **precondition-check-present** check (any pack with "## Verified context" also carries a `requires:` grep + a BLOCKED-on-mismatch instruction, and any "leave staged" pack also instructs writing `IMPLEMENTATION_REPORT_<sid>.md`), the **truth-stamp check** (every Verified-context claim bullet carries `[verified main@<sha>]` or `[UNVERIFIED …]`, and the section carries the `Generation-time verification: … git show main:` evidence line — F2), the **exactly-one-`99-*` HARD gate** (a tree with zero or multiple final verify packs is refused — fix and re-emit, never hand it over), then the runner cross-check, then the conflict lint and the remaining manual pass:
```bash
# Cross-check with the real runner IF it's installed. --dry-run confirms packs= and
# waves=[…] match what you assigned and lists 99 "VERIFY last". Absent → skip, don't fail.
if command -v run-v-packs >/dev/null 2>&1; then
  run-v-packs "$PACK_ROOT" --dry-run
else
  echo "NOTE: run-v-packs not on PATH — skipping runner cross-check; the shell self-validate above already proved the tree is canonical. Operator can run-v-packs it on a machine that has ~/.local/bin/run-v-packs."
fi
```
If `run-v-packs` is absent, do NOT treat that as a validation failure — the emitted tree still follows the canonical form and the structural + wave-map-parity self-validate above is authoritative. Just note the skipped cross-check in the Step 6 report.

**Byte-size gate (run regardless of whether `run-v-packs` is installed).** The convention's self-validate checks line count only; the runner's *binding* limit is bytes (`≤ ~25KB`, else it refuses the file as a concatenated bundle — § What is a "pack"). Line count can pass while bytes fail, and the dry-run guard above may be skipped — so check bytes explicitly here:
```bash
for f in $(find "$PACK_ROOT" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) -not -path "$PACK_ROOT/.*"); do
  b=$(basename "$f"); case "$b" in 00-README.md|README.md) continue ;; esac
  sz=$(wc -c < "$f" | tr -d ' ')
  [ "$sz" -le 25000 ] || echo "  - $b is ${sz}B (> ~25KB) — run-v-packs will refuse it as a bundle; split into narrower packs"
done
```
**Conflict lint (2026-07-11 — mechanizes the old manual parallel-safety pass, and extends it across the standing queue).** Run `~/.claude/scripts/check-pack-conflicts.sh` twice: on `$PACK_ROOT` alone (SAME-WAVE COLLISIONS inside the new tree — the wave-assignment invariant, checked mechanically against declared `## Files`/globs) and on `$(dirname "$PACK_ROOT")` (DUPLICATE bodies and CROSS-BATCH OVERLAPS against every batch still queued for the repo — a new batch must be born de-conflicted against the queue, not just against itself). Exit 1 = merge, re-wave, or drop the offending pack and re-emit; never hand over a tree with hard findings. (run-v-packs re-runs the same lint before wave 1 as a backstop — warn-only unless `V_PACK_CONFLICT_GATE=1`.)

Then do the one manual pass the shell can't:
1. **Commit discipline:** every IMPLEMENTATION pack ends with "do NOT commit; leave staged"; the READ-ONLY verification packs correctly omit it.

Fix and re-validate on failure.

### Step 6 — Report
Print the tree (`find "$PACK_ROOT" -type f | sort`) and a one-paragraph summary: wave count, what parallelizes, and any corrections found during grounding. End with the **handoff line**: `run-v-packs "$PACK_ROOT"` (parallel + isolated, walk away) or `… --serial` (race-free), plus a reminder that Step 7 can queue the tree for later execution via `v-inbox` instead. Do NOT commit unless the operator asks.

### Step 7 — Optional: queue for later execution (v-inbox)
Only when the operator explicitly asked to queue this pack tree for later/batch execution instead of running it now (e.g. "queue it", "add to the inbox", `--queue-inbox`) — never by default. Follows `references/v-core-pack-inbox.md` (read it before first use):
1. **Copy — never move** — each self-validated pack file from `$PACK_ROOT` into `$PROJECT_ROOT/.v/packs/inbox/` (`mkdir -p` first). Exclude `00-README.md` (human map, no `/v` first line). Real files only, never symlinks (discovery uses `find -type f`).
2. **Collision check:** if `[ -e "$INBOX/$(basename "$f")" ]`, suffix the incoming copy with this tree's `-MM-DD` tag (`<name>.MM-DD.txt`) instead of overwriting a still-pending pack.
3. **Register:** `bash ~/.claude/scripts/register-pack-inbox.sh "$PROJECT_ROOT"` (idempotent, deduped).
4. Report what was queued and how to run it: `v-inbox` (no args) lists pending packs across every registered project; `v-inbox run` runs all of them now; `v-inbox run "$PROJECT_ROOT"` runs just this one. Nothing runs automatically — say so.

## Quality rules
1. **Grounding is mandatory** — packs that hard-code unverified anchors are the main failure mode. Open the files.
2. **Real parallelism only** — same-wave packs must have disjoint file sets. When in doubt, serialize or merge.
3. **Don't duplicate the whole plan** into each pack — reference it; inline only the verified specifics that pack needs. That still means real detail: up to ~3500 lines per pack is normal when the task warrants it (see Pack-writing rules).
4. **Paste-ready + runnable** — first char `/`, `.txt`, no frontmatter, no meta-instructions in the body; the tree must pass `run-v-packs --dry-run`.
5. **End with verification + hardening waves** — never hand over a tree that stops at "implemented."
6. **Respect commit policy** — packs say leave changes staged; no auto-commit, no PRs (unless the operator's CLAUDE.md says otherwise).

## Gotchas
| # | Symptom | Rule |
|---|---|---|
| 1 | Pack cites a line that moved → agent edits the wrong place | Step 1 grounding + "re-grep before editing if drifted" in every pack |
| 2 | Two same-wave packs edit the same file → merge conflicts | Disjoint-files (same wave prefix) rule; merge coupled files into one pack |
| 3 | Frontend wave starts before backend contract lands | Order waves by dependency edges; a later wave runs only after the earlier completes |
| 4 | Plan was wrong; packs propagate the error | If grounding finds a material defect (plan wrong, or item already-fixed), STOP/skip and report — don't generate against a bad premise |
| 5 | Tree ends at "implemented", no review | Always append verification + hardening waves (convention § Closing waves) |
| 6 | Tiny plan gets heavyweight pack ceremony | < ~8h / 1–2 sessions → inline checklist, not a pack tree |
| 7 | Emitted nested `wave-N/` folders | The runner tolerates them, but the canonical form is **flat** wave-prefix `.txt`; emit flat |
| 8 | Pack claims a symbol/guard exists as a bare fact; it's gone or never existed by execution time | Every claim gets a `requires:` grep + a runtime precondition check that STOPs + writes `BLOCKED_<sid>.md` on mismatch, instead of a future-fact "Verified context" |
| 9 | 00-README.md's wave-map table names a pack that was never written (or a written pack that's unlisted) | Step 5 self-validate cross-checks the wave-map table against the files actually on disk, both directions, and fails loudly on any mismatch |
| 10 | Staged-only pack leaves no witness → the session-log resolver can't tell it apart from an abandoned session | Every "leave staged; do not commit" pack instructs writing `IMPLEMENTATION_REPORT_<sid>.md` before finishing |
| 11 | Security-bearing pack (signing/secrets/URL-from-var/auth/payments) staged with only a test+lint gate; a HIGH-severity bug rides Wave-0 code until whichever copy lands first wins | Flag those packs in Step 2–3 and write an in-pack "dispatch adversarial reviewer on your own diff, fix CRITICAL/HIGH in-session" line (convention § Security-bearing packs) — not just the closing wave |
| 12 | Headless/orchestrator (`V_DEPTH >= 1`) run hits the Step 0.2 operator-confirm or a `/v-plan` referral and hangs waiting for a human who isn't there | § Execution Context: at `V_DEPTH >= 1` never ask — resolve the plan autonomously or write `BLOCKED_<sid>.md`; the confirm/referral is the `V_DEPTH == 0` path only |
| 13 | `run-v-packs` not on PATH → Step 5 cross-check errors and the run aborts even though the tree is valid | Guard the dry-run with `command -v run-v-packs`; on absence skip the cross-check (the shell self-validate is authoritative) and note it in the report |
| 14 | Two independent wave-0 packs both emitted as `<slug>.txt` → one silently overwrites the other | Wave-0 packs take no prefix but still need distinct descriptive names; only a lone wave-0 pack uses the bare slug |
| 15 | Pack passes through an "X already added/landed by wave-N" claim on faith; the prior work never existed → executing sessions scope-guard-violate or strand (live forensic: a phantom wave-0 registry pack + a false `ExampleOperation::ExampleCase already added` claim in two packs) | Step 1 F2 rule: live-check every such claim via `git show main:<path> | grep` at generation, stamp `[verified main@<sha>]`; a failed check FAILS that pack's generation or downgrades the line to `[UNVERIFIED]` + `requires:`/BLOCKED gate — Step 5's self-validate hard-fails an unstamped claim |

## Idempotency
Filesystem-mutating: writes a pack tree under `.v-prompt-packs/<slug>-<MM-DD>/`. Same-day re-runs archive the prior tree to `.bak-<timestamp>`. Re-running on the same plan yields a structurally stable tree; specific pack boundaries may shift if the codebase changed between runs (grounding re-reads current state).
