# Runnable Prompt-Pack Convention

_Last reviewed: 2026-08-02 (stamp corrected — this file was substantively edited 2026-07-16 to add the `<!-- v-verify-gate: ... -->` directive and promote its self-validate check to a HARD failure, but the stamp was never bumped past 2026-07-05; confirmed current as of this pass)._

> The single source of truth for the shape `run-v-packs` consumes. Producers (`/v-prompt-pack-generate`,
> the `v-audit-*` skills) emit the **canonical** form below; the runner is a **liberal consumer** that also
> accepts the documented variants so nothing the operator already has goes unrun.

`run-v-packs <dir>` is the fire-and-forget executor: it runs each pack as a headless `claude -p "/v …"`
session, ≤5 in parallel, honoring waves, archiving only packs that attest the full gauntlet
(`GAUNTLET_ATTESTED`) to `<dir>/.done/`, and resuming on re-run. (`~/.local/bin/run-v-packs`.) Each pack is
archived **the moment it finishes** (not at pass-end), so `.done/` grows live and a fast pack is never held
hostage by a slow/wedged sibling. A session still alive past `--timeout` (default 75 min) is killed and parked
to `.needs-review/` — a wedged pack can never hold a parallel slot forever.

---

## Orchestrator contract — the tokens the runner greps (NORMATIVE)

`run-v-packs` decides a pack's fate ONLY by grepping the headless session log for tokens the **orchestrator**
emits. If either side's literal drifts, nothing errors — the runner silently loops a finished pack forever or
archives an unfinished one. These three couplings are LOAD-BEARING and are pinned by
`scripts/run-v-packs-orchestrator-contract-test.sh` (runs on every harness sweep; goes red if either side drifts):

| Outcome | Orchestrator emits | …in | run-v-packs `verdict()` reads |
|---|---|---|---|
| **archive (done)** | `GAUNTLET_ATTESTED` | `v-gauntlet-attest.sh` | greps `GAUNTLET_ATTESTED` |
| **archive (no-op)** | `V-COMPLETION-SELFCHECK: PASS` **plus an already-done phrase** (e.g. `non-code completion`) | `v-completion-selfcheck.sh` | greps `V-COMPLETION-SELFCHECK:\s*PASS` AND an already-done phrase |
| **keep + re-run** | `no task content` | `SKILL.md` (empty task-capture path) | greps `no task( was found\| content)` |
| **park (inconclusive)** | *nothing* — the session exits clean having done **0 turns** and emits none of the above | (an already-done 0-file fix whose self-check emits `FAIL` for lack of artifacts; or a headless `/v` that stalls on an interactive wait) | infers it from `num_turns==0` + clean exit + no token → moves the pack to `<dir>/.needs-review/` (NOT re-run, NOT archived — held for a human) |
| **park (timeout)** | *nothing* — the session is still **alive past `PACK_TIMEOUT`** (default 75 min; `--timeout <min>`) | a wedged session — a failed subagent dispatch it keeps polling, a rate-limit stall, an interactive wait — that never returns and would hold its parallel slot forever | a per-pack **watchdog** kills it and drops a race-free `<log>.timedout` **sidecar** (not a log write — that races claude's open fd); `verdict()` keys off the sidecar FIRST → parks to `<dir>/.needs-review/` |

The **park** rules are what make parallel runs safe: without them a 0-turn or wedged pack either loops forever as `partial` (quota burn) or holds a `-jN` slot indefinitely (starving the run — observed live: packs stuck at 0 turns for ~1h). Parking is deliberately **not** an archive — the two-signal contract still governs "done"; a parked pack is verified by the operator (already on main → `mv` it to `.done/`; genuinely unfinished → raise `--timeout` / run it interactively). The `timeout` sidecar is a **separate file** on purpose: writing the marker into the session log races claude's still-open redirect fd and gets clobbered. The proper way to make an already-done pack **auto-archive** is orchestrator-side: its no-op completion must drop a non-code-completion marker so `v-completion-selfcheck.sh` emits `PASS` (row 2), not `FAIL`.

Separately, `run-v-packs` reports any **unmerged worktree branches** at the end of a run (finished work stranded off `main` by concurrent merge-lock contention) so a parallel fire-and-forget run never silently leaves a fix un-landed — it lists each with its `git merge` command (report-only; it never auto-merges).

**Before changing any of these emitters** — `v-gauntlet-attest.sh`, `v-completion-selfcheck.sh`, the SKILL.md
no-task phrasing — **or `run-v-packs`'s `verdict()`, run the contract test and keep both sides in sync.** A rename
on one side without the other strands every pack in an infinite re-run (or archives unfinished work as "done").

---

## What is a "pack"

A pack is **one file = one `/v` session**. The runner identifies a pack structurally, not by extension:

- its first non-blank line is a `/v …` (or `/v-<skill> …`) invocation, **and**
- it is not a `README`, **and**
- it is a single session's worth of work (≤ ~25KB — a much larger `/v` file is a concatenated *bundle*,
  not one pack; the runner refuses to run it as a single session and warns loudly instead of silently).

This is why `00-README.md`, `*_PLAN.md`, `validate.py`, and JSON artifacts are never executed — they don't
start with `/v`. Keep one pack per file; never concatenate packs into one `*_ALL.txt`.

---

## Canonical form (what producers SHOULD emit)

**Directory ownership (NORMATIVE — shared with the `NN-*.md` pack family):** the parent directory
location and per-skill dated-folder naming (`.v-prompt-packs/<full-skill-name>-<MM-DD>/`) is owned
by `v-core-prompt-pack.md` § Unified folder convention — this file does NOT restate it. ALL producers
share that ONE directory rule, whichever internal pack shape they emit (the audit-family `NN-*.md`
form OR this file's runnable `w<N>-*.txt` wave form): only the file-naming-WITHIN-the-directory
differs by shape. A producer that diverges the directory (a bare undated `.v-prompt-packs/<skill>/`,
or a legacy `<skill>-prompts/` root) is a contract violation, same as diverging the wave-naming rule
below — `prompt-pack-output-dir-parity.test.ts` sweeps the whole `skills/` tree for both.

```
.v-prompt-packs/<slug>-<MM-DD>/        ← one dated dir at project root (gitignore: .v-prompt-packs/)
  00-README.md                         ← master map (wave table, deps, invariants) — NOT a pack
  <name>.txt                           ← wave 0: no prefix = unordered, runs first/in parallel (the common case)
  w1-<name>.txt   w1-<name>.txt        ← wave 1: all parallel within the wave
  w2-<name>.txt                        ← wave 2: starts only after wave 1 fully completes
  99-<name>.txt                        ← VERIFY: always runs last, after every wave
```

- **Flat** (no subfolders) and **`.txt`**. One `ls` shows every pack and its wave order.
- **Wave = filename prefix.** `w<N>-` or `w<N>_` (e.g. `w1-`, `w2-`, `w10-`). No prefix ⇒ wave 0.
  `99-` ⇒ the final verify pack. A pack belongs in wave N only if it is parallel-safe with every other
  wave-N pack (disjoint files, no dependency between them) — that is the whole point of the wave number.
- **Each wave is LANDED ON MAIN before the next wave starts** (W-LAND, 2026-07-02): after a wave drains,
  run-v-packs runs the safe PID-gated drain and a landing barrier verifies nothing is stranded off main or
  parked unverified — so a wave-N+1 pack MAY rely on wave-N's files/commits being present on main, and the
  `99-*` verify pack always judges a main that contains every landed wave (it is skipped, loudly, if a wave
  could not fully land). Producers can therefore write later-wave packs that import/extend earlier-wave output
  without re-checking it exists.
- **First line is the invocation** (`/v …` or a direct `/v-<skill> …`), no YAML frontmatter, no commentary
  above it, no "generated by" footer. Paste-ready: every placeholder substituted.
- **No commit/PR instructions** inside implementation packs — they end with "leave staged; do not commit"
  (the verify pack is read-only and omits it).
  **The footer is RUNNER-LANE-ONLY (forensic 2026-07-09, two production sessions):** it exists
  because run-v-packs' landing layer owns commits (its dispatch contract explicitly overrides the
  footer at dispatch time). A pack **pasted into an interactive `/v` session is commit-owning**:
  the Stop hook's stranded-worktree gate demands commit + merge-back (or a MERGE_DEFERRED
  handoff), and the global CLAUDE.md worktree exception directs a scoped checkpoint commit —
  following those IS honoring this convention, not violating the footer. Two live sessions lost
  ~an hour each to the apparent contradiction (permission classifiers enforced the footer against
  the sanctioned merge script); this sentence is the anchor: interactive execution follows the
  Stop-hook commit/merge path, and the footer binds only runner-managed staged-handoff sessions.

**Single producer standard (2026-07-05):** every pack producer emits THIS wave form — flat **`.txt`**
packs + a single **`00-README.md`** map. The older audit-family `NN-*.md` shape is **deprecated for
producers** (the runner still executes any pre-existing `.md` pack whose first line is `/v`, so nothing
already on disk breaks — see Accepted variants — but new output MUST be `.txt`).

---

## Pack body schema (NORMATIVE — the planning context `/v` needs to implement cleanly)

A pack is a **cold-start brief**: the agent that runs it has ONLY this one file — not the audit JSON,
not the plan, not a sibling pack (packs sit unrun for days and run in isolated parallel sessions). So
every pack MUST **inline** the context from the planning that produced it. Line 1 is the `/v …`
invocation (the orchestrator receives everything after it as its task); the body below MUST contain,
in this order:

| Section | Content | Why `/v` needs it |
|---|---|---|
| `## Goal` | The outcome and why, tied to the originating finding/task (1–3 sentences). | Orchestrator intent + classification. |
| `## Context` | The specific finding(s)/decision inlined with `file:line` evidence + current-vs-desired behavior. **No reference to the audit JSON, the plan, or another pack.** | Self-contained understanding — the agent never has the source artifact. |
| `## Files` | Every file to create/modify, one per line with what changes. **REQUIRED, literal H2 `## Files`.** | **v-build's scope guard keys on this exact heading — without it every file reads as "unplanned" and the multi-file build path degrades.** The load-bearing section. |
| `## Changes` | The concrete steps. | Implementation plan. |
| `## Acceptance criteria` | Observable, testable done-conditions (checkbox list). | Drives `/v-verify-done` + the QA reviewer's "done?" judgment. |
| `## Tests` | The tests to add/run that prove the change. | The `/v-tdd` red→green anchor. |
| `## Constraints` | Conventions to honor / what must not break; cite any domain guardrail that applies (hard-delete, zero-outreach, framework version). | Prevents convention/guardrail regressions. |
| `## Dependencies` | `Wave <N>. Requires: <prior packs / none>.` | `run-v-packs` ordering. |

A **read-only** pack (`w<N>-review.txt`, `w<N>-pre-flight.txt`, `99-verify.txt`) carries `## Goal` +
`## Checks` + `## Acceptance` and OMITS `## Files`/`## Tests` and the "leave staged" line.

---

## Wave assignment (how a producer decides a pack's wave) — NORMATIVE

> The single source of truth for the partitioning. Both producers run THIS algorithm: `/v-prompt-pack-generate`
> over plan tasks, `v-audit-consolidate` over its deduped findings. The unit is a **work item** (one plan
> task, or one consolidated finding); the output is a set of packs each tagged with a wave number.

1. **File set per item.** List every file each work item creates/modifies — source + test + config.
2. **Conflict edge.** Two items conflict if their file sets intersect. Conflicting items must NOT share a
   wave (parallel packs touching the same file race + merge-collide). Put them in different waves — or, if
   tightly coupled (one imports/renders the other, or the fix is one indivisible change across both), MERGE
   them into a single pack owned by one agent.
3. **Dependency edge.** Item A → B when B consumes A's output (model before its consumers; backend contract
   before the frontend that mirrors it; a new type/module before its importers; a component before the file
   that imports it). B's wave must be strictly after A's.
4. **Assign waves.** Two packs may share a wave **only if their file sets are disjoint AND neither depends on
   the other's output.** Order waves by dependency: foundation → services/contract → wiring → frontend types
   → leaf components → coupled components. Put each independent track in the EARLIEST wave its dependencies
   allow (never serialize work that could run in parallel).
5. **Wave 0 is the common case.** An item with no conflict and no dependency edge takes NO prefix
   (`<name>.txt`) ⇒ wave 0, runs first/in parallel. Use `w<N>-` prefixes only where ordering actually matters.
   For a batch of independent fixes touching disjoint files, most packs are wave 0.
6. **Same file, different fix ⇒ different waves.** The dedup step merges same-file+same-remedy items into one
   pack; two items touching the same file with DIFFERENT remedies are not duplicates but DO conflict — they
   cannot share a wave. This is the one invariant a producer must never violate.

Size each pack as a sensible single-session unit; prefer fewer well-scoped packs over many trivial ones, but
honor the disjoint-files rule absolutely.

## Security-bearing packs carry their own adversarial review — NORMATIVE

Forensic 2026-07-03 (a third-party API adapter): a Wave-0 pack whose contract gate was pest+pint
built request-signing code; injection-class flaws in such code are structurally invisible to a test+lint
gate, and only a sibling session that happened to over-gate would catch one. Deferring ALL adversarial
review to the closing verification wave means staged Wave-0…N code can carry HIGH security bugs for the
fleet's entire lifetime (and whichever copy an operator lands first wins).

Rule: when a pack's file set touches ANY of — request signing / HMAC / signature or webhook verification,
credential or secret handling, host/URL construction from variables, auth/authz decisions, payment flows —
the generator MUST write into THAT pack's prompt: "This pack touches security-bearing code: dispatch an
adversarial reviewer (codex-adversarial-reviewer, fallback superpowers:requesting-code-review) on your own
diff before finishing; fix CRITICAL/HIGH findings in-session." The closing verification wave still runs —
this is defense-in-depth for the window between staging and landing, not a replacement.

## Live-write packs carry a headless confirmation contract — NORMATIVE (2026-09-09)

Forensic (a production-site pack fleet, run headless via `run-v-packs`): of six wave-0
packs, **two applied live production changes without the explicit confirmation their own Constraints
demanded** — one deleted a live file from a web root, and another rewrote many live records and
configuration rows.
Both then correctly escalated with `BLOCKED_<sid>.md` and refused to merge. A third pack
faced identical conditions and **staged instead**. Same tree, same
runner, same missing operator — three different self-assessments.

Execution quality was not the problem: both applying packs dry-ran first, took per-row backups with
write-verification, read back every write, proved the whole set (not a sample), added
compare-and-swap guards, and passed their own codex review and site-audit. The failure was that each
pack **resolved its own authorization question by private risk calculus** — reasoning that headless
mode made a staged deliverable unable to satisfy acceptance criteria phrased against live server
state. That reasoning is plausible and was, in the end, ratified. It is still the pack deciding
something that is not the pack's to decide, and the operator learned of it only after the writes
were live.

Rule — a pack whose Changes write to ANY system outside the repo (production DB, web docroot, DNS,
CDN/edge config, a third-party API, published content) MUST carry a `## Headless execution` section:

```
## Headless execution
This pack performs live writes to <named target>. Under `run-v-packs` — or any non-interactive
dispatch — there is NO operator present to confirm. Do NOT resolve that by applying anyway.
STAGE instead: produce the exact commands or diff, the backup, and the tested rollback, then write
NEEDS_CONFIRMATION_<sid>.md naming precisely what awaits approval, and exit WITHOUT applying.
An acceptance criterion phrased in terms of live server state is satisfied, in headless mode, by
the staged artifact plus its verification plan — NOT by applying unattended.
```

Two corollaries, both load-bearing:

1. **Acceptance criteria MUST be writable in staged form.** A producer that emits "the live site
   returns 404 for /legacy-file.txt" as the ONLY acceptance criterion has built the trap this rule exists to
   prevent — the pack cannot pass without applying. Pair every live-state criterion with its staged
   equivalent ("the delete command and a restorable backup exist, and the post-apply check is
   scripted").
2. **Unattended apply requires a CITED authorization record — not the pack's own judgement.** The one
   pack in that run that applied live and was right to is the one that carried
   `Publishing <post-id> is pre-authorised (operator decision, recorded <date>, target <date>)`.
   A named, dated, specific prior approval is what licenses an unattended write. "No operator was
   available and the criteria demanded it" is not. Where a pack has such a record, the generator MUST
   quote it in the `## Headless execution` section and scope it to exactly the write it covers —
   pre-authorisation for one post's publish does not extend to editing other posts' bodies.
3. **EVERY pack that references a production target declares its posture — including "none".** The
   self-validate linter fires on production target nouns (`/home/…`, `docroot`, production-DB table
   names, …), not only on shell write verbs. That is deliberate and was learned by
   testing: a verb-only detector MISSED the live-file-delete pack entirely, because that pack expresses its
   production delete in prose ("delete it from the docroot") and never as a command — the single pack
   most responsible for the incident would have sailed through. The detector therefore over-fires on
   docs-only packs, and the fix for those is one line inside the section: "makes no live writes". The
   obligation is to STATE posture, not to prove absence — inferring posture is exactly what failed.

## Verified-context claims are TRUTH-checked at generation — NORMATIVE (F2, 2026-07-05)

Forensic ground truth: a wave-0 enum-registry pack was never written, yet two downstream packs
shipped `## Verified context: ExampleEnum::ExampleCase already added — do NOT edit
ExampleEnum.php` — one executing session violated its own scope guard trying to route around the
false premise, another stranded. The claim was emitted on FAITH (prior-pack-plan text passed through),
never checked against the repo.

Rule — a producer emitting any `## Verified context` claim (especially the "X already added/landed by
<pack/wave/session>" shape) MUST, at generation time, per claim:

1. **Live-check the claim against the target repo's `main`** — a real content check, e.g.
   `git show main:<path> | grep -F '<symbol>'` (file-existence form: `git cat-file -e main:<path>`), never
   the plan/prior-pack prose alone.
2. **Record the backing SHA in the claim line** — stamp each verified claim
   `[verified main@<sha>]` (7–40 hex, from `git rev-parse --short main` at check time), and put one
   evidence line directly under the `## Verified context` heading:
   `Generation-time verification: every claim below was live-checked via git show main:<path> | grep '<symbol>' at main@<sha> on <date>.`
3. **A claim that FAILS verification is never emitted as "Verified".** Either (a) FAIL generation of
   that pack — the grounding found the premise false, same STOP path as a materially-wrong plan — or
   (b) if the pack stands without the claim, downgrade the line to
   `[UNVERIFIED — verify before relying]` AND back it with a `requires:` grep + runtime
   STOP+`BLOCKED_<sid>.md` gate so the executing session re-checks before trusting it.

The stamp is a generation-time snapshot, not an execution-time guarantee — the `requires:`/runtime
precondition check (§ Self-validate) still applies on top. The self-validate below enforces the stamp
shape mechanically; it cannot re-run the grep for you (it has no target-repo context), so the live
check in step 1 is the producer's NORMATIVE obligation, not optional hygiene.

## Closing waves (always append) — NORMATIVE

Never hand over a tree that stops at "implemented." After the last implementation wave, append — as the
highest wave prefixes, so they run last — these packs (each is itself a paste-ready `/v` prompt, first
character `/`):

- **Verification wave (parallel, READ-ONLY)** — two `w<N>-` packs at the next wave after the last
  implementation wave: `w<N>-pre-flight.txt` runs the project's full quality gates (`/v-pre-flight` if
  present, else the gate command from CLAUDE.md); `w<N>-review.txt` dispatches the review agents (whatever
  lives in the project's `.claude/agents/` matching the changed file types, ALWAYS an adversarial/second-
  opinion reviewer — codex-adversarial-reviewer, fallback `superpowers:requesting-code-review` — and a
  framework-pitfall reviewer ONLY when the diff touches queues/listeners/middleware/signature-verification/
  cache-key/audit-schema/env-gated runtime). Both are READ-ONLY (assess, never fix) → they OMIT the "leave
  staged / do not commit" line.
- **Hardening pack (sequential, single — the next wave `w<N+1>-hardening.txt`):** triages the verification
  findings, fixes CRITICAL/HIGH, re-runs gates until green, runs `/v-verify-done`, walks the acceptance
  criteria. The ONLY post-implementation wave that edits source.
- **Final verify gate-runner (`99-verify.txt`, REQUIRED — hardened F2 2026-07-05, was "recommended"):**
  one READ-ONLY `/v` pack that re-asserts every pack landed (cheap greps + targeted gates). `99-` is the
  convention's always-last prefix, so the runner runs it dead last, after every wave. A tree without it can
  never truthfully be declared done (the phantom wave-0 forensic tree had NO verify pack and looked complete);
  the self-validate below now HARD-fails a tree that does not contain exactly one `99-*` pack — a producer
  must refuse to hand over such a tree, not emit it with a note.
  **Emit a machine-readable gate directive (REQUIRED — 2026-07-07):** the verify pack MUST carry a single
  HTML-comment line `<!-- v-verify-gate: <the project's full gate command> -->` (the SAME green-bar command
  the pack's `## Checks` prose names — e.g. `<!-- v-verify-gate: ./vendor/bin/pest --parallel && npm run build && ./vendor/bin/pint --test && composer audit && npm audit --audit-level=critical -->`).
  WHY: the verify `/v` session runs headless under `claude -p`, and if it dispatches gates/bug-hunts as
  background subprocesses and parks on a Monitor wait that never fires under `-p`, it closes at 0 turns
  without emitting the completion token — so a fully-green batch reports the GO/NO-GO as FAILED (exit 2).
  When that happens `run-v-packs` re-runs THIS directive's command synchronously itself and keys the final
  banner on its real exit code (a positive green proof — it never false-greens a red batch; a failing gate
  still trips the failure). Omit it and a fork-parked verify session strands the run at exit 2 even when
  green. Keep the command to deterministic, non-interactive gates only (no `/v-bug-hunt` re-runs — those
  fork; the gate suite + the regression tests the hardening wave added already cover no-regression).

## Self-validate the emitted tree — NORMATIVE

Before handing the tree over, a producer MUST self-validate (this is the same detection the runner uses, so
passing it proves the runner will see every pack and resolve waves as intended):

```bash
PACK_ROOT=".v-prompt-packs/<slug>-<MM-DD>"   # substitute actual
FAIL=0; note(){ FAIL=1; echo "  - $1"; }
[ -f "$PACK_ROOT/00-README.md" ] || note "master 00-README.md missing"
packs=0; n99=0
# same discovery the runner uses (depth ≤2 so a stray nested wave-N/ is still seen; dot-dirs pruned)
while IFS= read -r f; do
  b=$(basename "$f"); case "$b" in 00-README.md|README.md) continue ;; esac
  first=$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)   # first non-blank line
  case "$first" in '/v '*|'/v-'*|'/v') : ;; *) note "$b first line is not a /v invocation"; continue ;; esac
  packs=$((packs+1)); case "$b" in 99-*) n99=$((n99+1)) ;; esac
  lc=$(wc -l < "$f" | tr -d ' ')
  [ "$lc" -ge 10 ] || note "$b looks like a stub (<10 lines)"   # stub detector, not a verbosity gate
  [ "$lc" -le 3500 ] || note "$b is $lc lines (>3500) — split into narrower packs, don't trim detail a cold agent needs"
  # Byte cap — RUNNER PARITY with is_pack()/oversized_packs() (run-v-packs-lib/10-discovery.sh,
  # PACK_MAX_BYTES=25000, `-gt` ⇒ exactly 25000 passes). § What is a "pack" states the ≤25KB rule
  # NORMATIVELY, but nothing enforced it: an oversized pack validated OK here and was then silently
  # skipped by the runner (two live misses 2026-09-11). Kept in parity with
  # scripts/validate-audit-prompt-packs.sh, pinned by validate-audit-prompt-packs-test.sh.
  bytes=$(wc -c < "$f" | tr -d ' ')
  [ "${bytes:-0}" -le 25000 ] || note "$b is $bytes bytes (>25000 = run-v-packs' PACK_MAX_BYTES) — the runner SKIPS it as a concatenated bundle (it never runs, and --dry-run still exits 0); split into self-contained -part1/-part2 packs in consecutive waves"
  head -2 "$f" | grep -q '^---' && note "$b has YAML frontmatter (forbidden)"
  # Body-schema: implementation packs MUST carry the load-bearing '## Files' section (v-build scope guard).
  # Read-only packs (review / pre-flight / 99-verify) are exempt — they touch no files.
  case "$b" in *review*|*pre-flight*|99-*) : ;;
    *) grep -qE '^##[[:space:]]+Files\b' "$f" || note "$b (implementation pack) is missing the required '## Files' section — v-build's scope guard keys on it; without it every file reads as unplanned" ;;
  esac
  # Final verify pack MUST carry a runner-runnable gate directive (2026-07-07; ENFORCED — was mislabeled
  # "soft note" but note() sets FAIL=1, and a fork-parked verify session stranded a fully-green batch at
  # exit 2 on 2026-07-16 precisely because the directive was absent). If the headless `/v` verify session
  # fork-parks (0 turns, no completion token), run-v-packs re-runs THIS command synchronously to key the final
  # banner on a real exit code instead of stranding a green batch at exit 2. This is a HARD failure: fix and
  # re-emit. The ONLY legitimate omission is a project with genuinely no runnable gate command at all (rare —
  # every /v project has a pre-flight gate); such a tree must consciously drop this check, not silently ship.
  case "$b" in 99-*) grep -qE '<!--[[:space:]]*v-verify-gate:.*-->' "$f" || note "$b (final verify pack) has no '<!-- v-verify-gate: <gate command> -->' directive — if its headless verify session fork-parks, run-v-packs cannot deterministically re-confirm green and the run strands at exit 2 even when the batch is green (observed live 2026-07-16)" ;; esac
  # Self-contained: a pack must inline its context, never send the cold agent to the source artifact.
  # Narrow patterns (only the real "go read the source" anti-phrasings) to avoid flagging a legitimate
  # 'edit config.json' file reference.
  grep -qiE 'see (the )?(audit|plan)( (json|report|file))?\b|per the (audit|plan)\b|refer to (the )?(audit|plan|00-README|README)|the audit (json|report)|as (described|shown) in (the plan|00-README|pack [0-9])' "$f" \
    && note "$b points the agent at an external artifact (audit JSON / plan / sibling pack / README) — packs must be SELF-CONTAINED; inline the needed context into ## Context"
  # Catch a commit/push INSTRUCTION in any of its real shapes (line-start bare command; prose-prefixed
  # "Commit with: `git …`"; "git add … && git commit"; "git commit/push … -m") — the original `^git` anchor
  # missed the prose-prefixed form entirely. Deliberately does NOT match a prohibition ("do NOT run git
  # commit") or a plain incidental mention ("the last_deploy git commit hash") — same 4 shapes as the vitest
  # guard (audit-pack-no-commit-footer.test.ts); keep the two in sync. ACCEPTED TRADEOFF: a narrative mention
  # that itself contains "-m" (e.g. "the operator runs git commit -m later") DOES match — a false positive
  # here is a loud `note` that gets a human look (safe direction); tightening it risks missing a real
  # instruction (unsafe direction). No live pack text trips it.
  grep -qiE '^[[:space:]]*git[[:space:]]+(commit|push)|commit( with)?:[[:space:]]*.?[[:space:]]*git|git[[:space:]]+add.*&&.*git[[:space:]]+commit|git[[:space:]]+(commit|push).*[[:space:]]-[a-z]*m' "$f" && note "$b contains a git commit/push instruction (operator/orchestrator commits — packs end 'leave staged; do not commit')"
  # Precondition-check-present + staged-handoff-witness (R3 P0-1 future-fact "Verified context" class:
  # a guard helper existed nowhere in app/ except comments citing it — a pack's grounded anchors are a
  # SNAPSHOT from generation time, not a guarantee at execution time, since packs can sit unrun for days).
  # Only fires for packs that carry a "## Verified context" section (this producer's cross-wave-claim shape).
  if grep -q '^## Verified context' "$f" 2>/dev/null; then
    grep -qi '^requires:' "$f" || note "$b has '## Verified context' but no machine-checkable 'requires:' precondition grep (R3 P0-1 phantom-context class)"
    grep -qi 'BLOCKED' "$f" || note "$b has '## Verified context' but no runtime precondition STOP+BLOCKED instruction for a drifted/missing anchor"
    if grep -qi 'leave staged' "$f" 2>/dev/null; then
      grep -qi 'IMPLEMENTATION_REPORT' "$f" || note "$b ends 'leave staged' (a runner-managed staged-handoff exit) but never instructs writing IMPLEMENTATION_REPORT_<sid>.md (the resolver witness the staged-handoff contract checks for)"
    fi
    # TRUTH-stamping (F2 2026-07-05 — § Verified-context claims are TRUTH-checked at generation):
    # (a) every claim bullet in the section carries a backing-SHA stamp [verified main@<sha>] or an
    #     explicit UNVERIFIED downgrade; (b) the section carries the generation-time evidence line.
    # This catches the false-"already landed" class mechanically (two packs shipped a phantom
    # "ExampleEnum::ExampleCase already added" claim on faith; one session scope-guard-violated,
    # one stranded). The stamp shape is checkable here; the live grep behind it is the producer's job.
    while IFS= read -r vb; do
      [ -z "$vb" ] && continue
      printf '%s\n' "$vb" | grep -qE '\[verified main@[0-9a-f]{7,40}\]|UNVERIFIED' \
        || note "$b Verified-context claim lacks a generation-time truth stamp — every claim needs '[verified main@<sha>]' (from a real git show main:<path> grep) or an explicit '[UNVERIFIED — verify before relying]' downgrade (false-already-landed class, F2 2026-07-05): $vb"
    done < <(awk '/^## Verified context/{s=1;next} s&&/^## /{exit} s&&/^- /' "$f")
    grep -qE '^Generation-time verification:.*git show main:' "$f" \
      || note "$b has '## Verified context' but no 'Generation-time verification: … git show main:<path> …' evidence line under the heading (the recorded proof the claims were live-checked, not passed through on faith)"
  fi
  # Headless confirmation contract (2026-09-09 — § Live-write packs carry a headless confirmation
  # contract). QA finding F5: the prose rule shipped with ZERO mechanical enforcement, so nothing
  # stopped a third recurrence of the 2026-09-08 class (a live web-root file delete and dozens of live
  # post-body rewrites, both executed headless without the confirmation those packs' own Constraints demanded).
  #
  # ⚠ PLACEMENT IS LOad-BEARING — this check MUST stay at per-pack scope, NOT nested inside the
  # `## Verified context` block above. It was first written inside that block, so it only ran for
  # packs that happened to carry a Verified-context section — and the real live-delete pack has none, so
  # the check could never have fired on the very pack that caused the incident. Caught by QA's
  # positive-control test, not by the author's own detector test, which exercised the regex in
  # isolation and therefore passed while the integrated check was dead. Same failure shape as the
  # bug it exists to prevent: an enforcement that does not fire where it matters.
  #
  # DETECTOR DESIGN — learned by testing against the real tree that produced the incident.
  # A write-VERB-only detector (wp post update / rm -f /home/ / ssh … >) MISSED the live-delete pack
  # outright: that pack expresses its production delete in PROSE ("delete it from the docroot"),
  # never as a literal command. Same for a pack that only says "configure the production
  # endpoint". So the detector also keys on production TARGET nouns. That deliberately over-fires — a docs-only pack that merely
  # mentions a /home/<user>/www or /home/<user>/public_html docroot trips it too. Correct trade: a false positive costs the producer ONE
  # declaration line, a false negative costs a production incident. The requirement is therefore not
  # "prove you write live" but "state your live-write posture explicitly", which is auditable;
  # inferring posture is what failed. A pack may satisfy the check by declaring it makes NO live
  # writes — but it must SAY so, where a reader and this linter can both see it.
  _hx_verb='wp +(post|option|db|user|term|plugin) +(update|create|delete|query|set)|wp +eval-file|rm +-f +/home/|(^|[^a-z])scp +|ssh +[^|]*(rm |mv |cp |tee |>>|> )'
  _hx_target='/home/[a-z0-9_-]+/(www|public_html)|/www/|docroot|wp_posts|wp_options|post_content|post_title'
  if grep -qE "$_hx_verb" "$f" 2>/dev/null || grep -qE "$_hx_target" "$f" 2>/dev/null; then
    if grep -qE '^## +Headless execution' "$f" 2>/dev/null; then
      # Heading present — require the BODY to resolve posture one of three admissible ways.
      awk '/^## +Headless execution/{s=1;next} s&&/^## /{exit} s' "$f" \
        | grep -qiE 'NEEDS_CONFIRMATION|pre-authoris|pre-authoriz|no live writes|read-only|makes no live write' \
        || note "$b has a '## Headless execution' heading whose body resolves nothing — it must do exactly one of: (a) instruct STAGE + write NEEDS_CONFIRMATION_<sid>.md and exit without applying, (b) cite a specific dated operator pre-authorisation scoped to that write, or (c) declare it makes no live writes. A heading with neither is prose a headless pack reasons around — precisely how the 2026-09-08 packs self-authorized (QA F5)"
    else
      note "$b references production targets or write verbs but carries no '## Headless execution' section — under run-v-packs no operator exists to confirm, so the pack decides its own authorization. Add the section and resolve posture: STAGE + NEEDS_CONFIRMATION_<sid>.md, OR cite a dated pre-authorisation, OR state plainly that it makes no live writes. If this pack really is docs-only, saying so costs one line and removes the ambiguity that let two packs self-authorize"
    fi
  fi
done < <(find "$PACK_ROOT" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) -not -path "$PACK_ROOT/.*" 2>/dev/null | sort)
[ "$packs" -ge 1 ] || note "no packs found (a pack = .txt/.md whose first line is /v)"
# HARD gate (F2 2026-07-05, was an advisory note): a tree MUST contain exactly ONE 99-* final verify
# pack. Zero ⇒ nothing ever re-asserts the waves landed (the phantom wave-0 tree shipped with no verify
# pack and "looked done" forever); more than one ⇒ the runner runs only the first and silently ignores
# the rest. A producer that hits this must fix and re-emit, never hand the tree over.
[ "$n99" -eq 1 ] || note "tree has $n99 '99-*' final verify pack(s) — exactly ONE is REQUIRED (hard gate; refuse to emit the tree without it)"

# --- wave-map <-> pack-file parity (R3 P0-1 phantom-wave class: 00-README's wave-map table named 4 of 6
# wave-0 packs that were NEVER WRITTEN — no file, no history, no SID, no branch; the tree looked complete
# because nothing checked the map against the filesystem). Bidirectional: a name in the map with no file is
# a phantom pack (silently lost work); a file on disk absent from the map is an orphan (silently unscheduled).
if [ -f "$PACK_ROOT/00-README.md" ]; then
  readme_names=$(grep -oE '[A-Za-z0-9_.-]+\.(txt|md)' "$PACK_ROOT/00-README.md" 2>/dev/null | sort -u | grep -vE '^(00-README\.md|README\.md)$')
  while IFS= read -r rn; do
    [ -z "$rn" ] && continue
    found=$(find "$PACK_ROOT" -maxdepth 2 -type f -name "$rn" 2>/dev/null | head -1)
    [ -n "$found" ] || note "wave-map names '$rn' in 00-README.md but no such pack file exists on disk (phantom-wave class — R3 P0-1)"
  done <<< "$readme_names"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    b=$(basename "$f")
    case "$b" in 00-README.md|README.md) continue ;; esac
    printf '%s\n' "$readme_names" | grep -qxF "$b" || note "$b exists on disk but is not named anywhere in 00-README.md's wave map (orphan pack)"
  done < <(find "$PACK_ROOT" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) -not -path "$PACK_ROOT/.*" 2>/dev/null | sort)
else
  note "master 00-README.md missing (cannot check wave-map<->pack-file parity)"
fi

[ "$FAIL" = 0 ] && echo "PACK TREE OK ($packs packs)" || echo "PACK TREE ISSUES (fix then re-validate)"
```

Then **cross-check with the real runner** (proves the waves resolve as intended, nothing silently unseen) and
do the two manual passes the shell can't reliably:

```bash
run-v-packs "$PACK_ROOT" --dry-run     # confirm packs= and waves=[…] match what you assigned; 99 listed "VERIFY last"
```

Then run the **conflict lint** (2026-07-11 — mechanizes the old manual parallel-safety pass, and extends it
across batches). It intersects every pack's DECLARED `## Files` scope: identical normalized bodies ⇒
DUPLICATE; two same-wave packs naming the same file (or a `dir/*.ext` glob overlapping it) ⇒ SAME-WAVE
COLLISION; the same file declared by packs in DIFFERENT batch dirs ⇒ CROSS-BATCH OVERLAP. Exit 1 = fix
(merge / re-wave / de-dupe) and re-emit. Run it against the standing queue too — a new batch must be born
de-conflicted against batches already queued for the repo, not just against itself:

```bash
~/.claude/scripts/check-pack-conflicts.sh "$PACK_ROOT"                    # this tree alone
~/.claude/scripts/check-pack-conflicts.sh "$(dirname "$PACK_ROOT")"      # vs every sibling batch still queued
# optional: --judge adjudicates each flagged pair via a headless LLM call (DUPLICATE/CONFLICT/COMPLEMENTARY);
#           --quarantine parks exact-duplicate copies into .needs-review/ (recoverable, never deletes)
```

(run-v-packs runs the same lint itself before wave 1 — warn-only by default, blocking under
`V_PACK_CONFLICT_GATE=1` — but the producer-side run is where a finding is still cheap to fix.)

Finally the manual pass the shell can't do:
1. **Commit discipline:** every IMPLEMENTATION pack ends with "do NOT commit; leave staged"; the READ-ONLY
   verification packs correctly omit it.

---

## Accepted variants (what the runner ALSO consumes — be liberal)

So an operator never has to convert anything by hand, the runner also accepts:

- **`.md` packs (legacy, backward-compat only)** — pre-existing `NN-*.md` packs run as-is (first line
  still `/v`). Producers no longer emit this shape (deprecated 2026-07-05 → the `.txt` wave form above);
  the runner stays liberal so nothing already on disk goes unrun, but new packs must be `.txt`.
- **Subfolder waves** — `<dir>/wave-1/…`, `<dir>/wave-2/…`, or `<dir>/w3/…`. The subfolder name sets the
  wave (so pointing the runner at a parent that contains `wave-1/ wave-2/` runs them in order instead of
  silently skipping them). A subfolder wave and a filename prefix mean the same thing.
- **A bare flat dir of unprefixed packs** — all wave 0, run together, then `99-` last. (This is the
  pre-wave behavior, preserved exactly.)

The wave number is resolved as: `99-*` ⇒ last; else the `wave-N/`/`wN/` **subfolder** if present; else the
`w<N>-` **filename** prefix; else **0**.

---

## Run it

```bash
run-v-packs .v-prompt-packs/<slug>-<MM-DD>/      # parallel, isolated, walk away
run-v-packs .v-prompt-packs/<slug>-<MM-DD>/ --serial   # one at a time (race-free)
run-v-packs .v-prompt-packs/<slug>-<MM-DD>/ --dry-run  # show the wave plan, run nothing
```

Re-running the same command resumes (finished packs are already in `.done/`). On a session/usage limit it
waits out the reset and continues. If a wave can't finish after retries, it stops **before** the dependent
waves rather than running them on a broken dependency.

**One batch per child run — a multi-batch root auto-sequences.** Pointing the runner at a parent dir
holding several batch dirs (each with its own `00-README.md`) runs them SEQUENTIALLY by default
(2026-07-11): oldest `00-README.md` first, one full child run per batch (own waves, own lock, own
`99-verify` gate — nothing interleaves), stop at the first batch that exits nonzero, resume by re-running
the same command. The cross-batch conflict lint (`check-pack-conflicts.sh`) runs first every time: exact
DUPLICATE packs are auto-quarantined to `.needs-review/`, cross-batch `## Files` overlaps are
informational (sequential execution is their remedy), and batch-internal SAME-WAVE/MULTI-99 findings warn
(block with `V_PACK_CONFLICT_GATE=1`). `V_PACK_MULTI_BATCH_SEQ=0` restores the old refusal;
`V_PACK_ALLOW_MULTI_BATCH=1` forces ONE combined interleaved run (know what you're doing).
