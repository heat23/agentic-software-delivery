---
name: v-forensics
description: "Read-only post-mortem of completed /v sessions via git+artifact ground truth: flow, landing, claims, gates, telemetry, cost. Not for pack audits or code review."
argument-hint: "[repo path or SID(s) — defaults to the current repo, recent sessions (last 72h or 20 SIDs)]"
allowed-tools: Read, Grep, Glob, Bash, Agent
model: sonnet
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-forensics | version: 1.0.0 | last-updated: 2026-08-12 (added model/version metadata) -->

# 2026 Canonical Contract

Tier: comprehensive (READ-ONLY forensic post-mortem of the /v orchestration system). User-invocable. Analysis only — never edits, fixes, drains, or GCs; output is the report.

This contract overrides older sections below on conflict.

```yaml
contract:
  tier: comprehensive
  accepts: [optional repo path or SID(s) via $ARGUMENTS — defaults to the current repo; default scope = sessions from the last 72h OR the 20 most recent SIDs, whichever is smaller (state the bound + anything dropped in the coverage manifest)]
  produces: [FORENSICS_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md (durable file under .v/artifacts/ — Phase-2; create the dir) — the SAME post-mortem also rendered in-conversation; findings cite durable per-SID artifacts + git ground truth]
  invoked-by: [user]
  invokes: []
  dispatches: optional read-only per-SID analyzer subagents (bounded evidence packets)
  estimated_tokens: 100k-400k
  estimated_duration: 15-60 min
```

## Idempotency

Fully idempotent: READ-ONLY by hard constraint (see below) — no repo, artifact, marker, worktree, or telemetry state of the AUDITED system is mutated. The sole write is this skill's own per-session deliverable, `.v/artifacts/FORENSICS_REPORT_<ts>_<sid>.md` (see § PERSIST THE REPORT); it is SID-stamped, so a re-run writes a new file rather than clobbering a prior post-mortem. Re-running re-derives the same post-mortem from the same durable artifacts (modulo sibling sessions mutating the live repo between runs, which the skill flags as moving-target signals rather than findings). Any validator that writes by design is redirected to a disposable temp path.

# /v Orchestration Forensic Audit — Multi-Faceted Post-Mortem

You are running the **v-forensics** skill: a READ-ONLY forensic post-mortem of the `/v` orchestration system (skill, hooks, gates, validators, worktree/merge machinery, telemetry) reconstructing what REALLY happened across recently-run — typically PARALLEL — `/v` sessions. This audits the ORCHESTRATOR and its TELEMETRY, **not** product code.

Your mandate is COMPREHENSIVE and ADVERSARIAL. The axes below are a FLOOR, not a ceiling — do not tunnel on them. Actively hunt for classes not listed; treat "nothing found in category X" as a claim you must justify with what you inspected. The sessions ran CONCURRENTLY on a shared repo, so contention, sibling cross-contamination, mutual-deferral, and emergent cross-session failures are FIRST-CLASS subjects.

**SIBLING SKILL — `/v-forensics-pack-runner`** audits the LANDING LAYER (`run-v-packs`, merge-drain, worktree lifecycle). Hand off across the boundary so nothing falls in the crack: if you find a TELEMETRY-CAPTURE gap (0 / sparse `SESSION_LOG.yaml`), do NOT merely speculate "the runner never invoked the writer" — record it and escalate to `/v-forensics-pack-runner` (was `run-v-packs` invoked at all, and did it dispatch `/v` with the session-log writer enabled? — the documented "fleet telemetry BLACKOUT" root). Conversely, if this audit traces a symptom to the runner/drain (a pack that never launched, a drain mis-classification), name it as out-of-lane and point at the sibling skill.

## READ-ONLY MODE (hard constraint)
Analysis only. Do NOT edit files, write fixes, run formatters, modify artifacts, commit, merge, clean worktrees, drain, GC markers, or change tests. You may run read-only inspection commands and validators that do not mutate state. If a validator writes output BY DESIGN, say so first, prefer a dry-run/read-only mode, and send output to a disposable temp path scoped to THIS session (e.g. the session scratchpad or `$(mktemp -d)/<this-sid>/`) — never a shared or per-audited-SID path. **The repo is LIVE under concurrency** — sibling sessions may mutate `main`, add/remove worktrees, and overwrite shared runtime files (e.g. `~/.claude/runtime/current-session-id`) WHILE you inspect. Prefer durable per-SID artifacts over live repo scans, and flag any signal that could be a moving-target/concurrency artifact rather than a real finding. Do NOT ask "want me to fix this?" — output is the report only. **The SOLE permitted write is this skill's own deliverable** — the `FORENSICS_REPORT_<ts>_${CLAUDE_SESSION_ID}.md` artifact written ONCE at the end (see § PERSIST THE REPORT); it never touches the audited system's files, markers, worktrees, or branches.

## TARGET & PATHS (compute — do not hardcode)
- **Target repo**: if `$ARGUMENTS` is a path, use it; else `git rev-parse --show-toplevel` from cwd. If cwd is not a git repo and no path was given, say so and stop — do not fabricate a target.
- `$ARGUMENTS` disambiguation: a token that exists on disk or contains `/` is a repo path; a UUID-shaped token is a SID; anything else, say how you interpreted it.
- If `$ARGUMENTS` names specific SID(s), focus there but STILL run full session-discovery (within the same default scope bound) to catch sibling leakage. A supplied SID with ZERO footprint across all discovery sources is reported as NOT-FOUND (typo / wrong repo — distinct from "ran but left nothing") — never fabricate an evidence table for it.
- **Transcript dir**: `~/.claude/projects/<slug>/` where `<slug>` = the session cwd's absolute path with every NON-ALPHANUMERIC char → `-` (dots too: `/home/user/.claude` → `-home-user--claude`). Per-SID: `<slug>/<sid>.jsonl` and `<slug>/<sid>/subagents/*`.
- **Worktree sessions have their OWN slug**: parallel/headless `/v` sessions run inside `.worktrees/<branch>-<sid>` — a DIFFERENT absolute path, so their transcripts live under a different `<slug>` than the main repo's. Compute one slug PER worktree path from `git worktree list --porcelain` (including recently-removed ones recoverable from reflog/locks), or you will falsely report those sessions as transcript-missing. Also glob each live worktree's own working copy for `SESSION_LOG_*.yaml`, `.v/artifacts/*`, and gauntlet artifacts not yet merged to main.
- **Per-session writes logs** live at `$(git rev-parse --git-common-dir)/claude-session-writes-<sid>.txt` — ONE shared dir across all worktrees of a repo; a worktree's local `.git` is a pointer FILE, not the log's home.
- Everything else is relative to the repo root, `.v/artifacts/`, `.v/tmp/`, and the git common dir.

## MANAGE CONTEXT — targeted extraction, not full dumps
Transcript `.jsonl` and gate logs can be many MB. Do NOT read them whole. Use `jq`/`grep` to pull only what you need: token-usage records (input/`cache_read`/output), first/last timestamps, `model`, `num_turns`, tool_use↔tool_result pairs for wall-clock, and gate-dispatch evidence. Grep the field; don't `cat` the file. Verified recipes (schema-checked 2026-07-05; adapt if fields drift):
- tokens (MUST dedupe by `message.id` keeping the LAST occurrence per id — summing raw assistant events double-counts [the documented 47%-style artifact], and `unique_by` keeps the FIRST occurrence, which on streamed/growing usage rows undercounts output tokens up to ~10x — verified 2026-07-10 vs a SESSION_LOG's own OP_TELEMETRY, exact match with last-occurrence): `jq -s '[.[]|select(.message.usage)]|group_by(.message.id)|map(.[-1])|{in:(map(.message.usage.input_tokens)|add),cw:(map(.message.usage.cache_creation_input_tokens)|add),cr:(map(.message.usage.cache_read_input_tokens)|add),out:(map(.message.usage.output_tokens)|add)}' <sid>.jsonl` — and sum the parent PLUS every `<sid>/subagents/*.jsonl` the same way (a fork/dispatch-heavy parent transcript is near-empty on its own)
- wall-clock span: `jq -rs 'map(select(.timestamp))|(first.timestamp),(last.timestamp)' <sid>.jsonl`

If more than ~5 SIDs are in scope, you MAY dispatch ONE read-only analyzer subagent per SID (`v-orchestrator-auditor`; `general-purpose` as fallback) — each returns a bounded evidence packet (SID, sources found, artifact verdicts, commit attribution, landed-on-main verdict, ≤5-line anomaly summary) and you synthesize; below that threshold work inline. Dispatch all per-SID analyzers CONCURRENTLY in a single message, each with an explicit READ-ONLY instruction. Every claim still gets verified against durable artifacts here.

## STEP 1 — SESSION DISCOVERY & COVERAGE MANIFEST (do this before opinions)
Enumerate EVERY session with any footprint — a MISSING/absent log is itself a finding, not "nothing to analyze." Discover SIDs from ALL of:
- `SESSION_LOG_<sid>.yaml` (+ `.yaml.invalid`) at repo root AND `.v/artifacts/`
- telemetry-HOLE markers (at the repo ROOT — SESSION_LOG family stays there, Phase 3): `SESSION_LOG_{MISSING,FAILED,INVALID,PENDING}_<sid>.md`, `SESSION_LOG_RESOLVER_BLOCKED.md`
- gauntlet + planning/report artifacts — **canonical under `.v/artifacts/` since the Phase-1+2 relocation (2026-07-06); glob BOTH `.v/artifacts/` AND the legacy repo root, plus each live worktree's own `.v/artifacts/`** (a session that only produced a PLAN/AUDIT is discoverable here): `PRE_FLIGHT_REPORT_`, `AGENT_REVIEW_`, `VERIFY_DONE_REPORT_`, `QA_REPORT_`, `QA_REMEDIATION_`, `UX_CRITIQUE_`, `WORKFLOW_VERIFICATION_`, `IMPACT_MAP_`, `SUCCESS_CRITERIA_`, `HANDOFF_`, `WORKTREE_HANDOFF_`, `CYCLE_CAP_HANDOFF_`, `BLOCKED_`, `IMPLEMENTATION_REPORT_`, `PLAN_`, `AUDIT_REPORT_`, `POLISH_PLAN_`, `TRAFFIC_PLAN_`, `PROGRESS_NOTE_`, `TRIVIAL_PASS_`, `PLANNING_PASS_`. (EXCEPTIONS still at repo root: SESSION_LOG* above, the `GAUNTLET_SKIPPED_`/`ABANDON_SUSPECT_` alarm markers, and the specialist audit JSON `*_AUDIT_*.json` consumed by the external ecosystem-review-runner.)
- `DISPATCH_PROVENANCE_<sid>.log`, attest/witness markers, `merge-deferred-<sid>.md`
- transcripts (see paths above), per-session writes logs at `$(git rev-parse --git-common-dir)/claude-session-writes-<sid>.txt` (see TARGET & PATHS)
- `git worktree list --porcelain` (+ each `.claude-session-lock` → `SID PID EPOCH`), and run-v-packs `<pack-dir>/.runlogs/**`, `.done/`, `.needs-review/`
- **branch census**: `git for-each-ref refs/heads --format='%(refname:short) %(committerdate:iso) %(upstream:track)'` — a session branch whose worktree was cleaned and whose artifacts were lost is discoverable ONLY here; also `git stash list`. Flag DUP-LANES: two+ branches implementing the same feature/pack (same feature name embedded in the branch name, different SIDs) are divergent duplicates needing adjudication, not independent work.

Emit a **COVERAGE MANIFEST**: the full SID set, which sources exist per SID, which SIDs have NO valid `SESSION_LOG.yaml` (capture gaps), and what you deliberately skipped and why (including the default scope bound if it truncated anything). Emit it IMMEDIATELY after discovery, before any deep per-SID analysis — a run that dies mid-analysis must still leave the manifest in-conversation.

## STEP 2 — GROUND TRUTH (authoritative beats narration)
Trust hierarchy (high→low): git object store + reflog → per-SID durable artifacts + witnesses + session-writes logs → transcript `.jsonl` timestamps/token counts → SESSION_LOG structured fields → SESSION_LOG prose → terminal paste / model narration. **When narration and ground truth disagree, ground truth wins.**

Per SID build an evidence table from:
- `git reflog`, `git log --all --oneline`, `git cat-file -e <sha>` for every claimed `base_sha`/`end_sha`/commit; `git merge-base --is-ancestor <branch> main` + `git rev-list --count main..<branch>` to test whether work actually LANDED
- SESSION_LOG fields: `commits_added`, `files_changed`, base/end sha, `generated_at`/`end_time`, `token_cost`, `model`, `duration`, `turn_count`, `user_intent_matched`
- forensic packet when present: `forensics.evidence_sources`, `artifact_verdicts`, `commit_attribution`, `contract_adherence` (required vs satisfied, missing, degraded paths, `completion_should_have_blocked`), `efficiency`, `functionality_claims`
- `.v/artifacts/<sid>*`, `DISPATCH_PROVENANCE`, attest/witness, `*.output`
- transcript: real token split, wall-clock span, and **whether gates were actually DISPATCHED (subprocess) vs hand-authored inline**

**Artifact presence ≠ success — parse content**: PRE_FLIGHT `Overall Status` + failing rows; AGENT_REVIEW dispatch mode + reviewer provenance (independent vs `orchestrator_inline`) + were findings actually ADJUDICATED or rubber-stamped; VERIFY_DONE `Overall Verdict`; DISPATCH_PROVENANCE = were claimed gates/reviews really dispatched (did codex actually run). Use `artifact_verdicts` as an index, then verify raw artifacts.

## STEP 3 — ANALYSIS AXES (cover every one; add your own)
**A. FLOW / lifecycle** — routing correctness, trivial/fast-path vs full-gauntlet appropriateness, stranded/redundant/skipped gates, worktree create→commit→merge→cleanup, re-verify loops, sequential-vs-parallelizable steps, dispatch retries/timeouts.

**B. LAND / merge-back / STRANDING** *(often the dominant failure — never skip)* — For each SID: is the work ACTUALLY ON MAIN, or COMPLETE-BUT-STRANDED on a branch? A gauntlet that PASSED + ATTESTED but never merged means the value never shipped and (for a bug fix) the bug is STILL LIVE. Verify via `merge-base --is-ancestor`, `main..branch` count, `merge-deferred`/`WORKTREE_HANDOFF` markers, and whether the fix's code is present on `main`'s working tree. **`is-ancestor` alone can FALSE-LAND**: a branch with 0 commits (`base_sha == end_sha` collapse, or a post-reset branch) is vacuously an ancestor — `main..branch` count 0 means EITHER "landed" OR "never committed"; disambiguate via content-on-main + the session's writes log. **STAGED-ONLY strands** (a documented repeat loss class): per live worktree run `git status --porcelain` + `git diff --cached --stat` — work staged but never committed is invisible to every ancestry check (`ahead=0` hides it) and is DESTROYED by any prune/reset; call it out before anyone cleans. **Photo-finish kills**: a session killed by watchdog/timeout may have had a PASSING gauntlet at kill time — check kill timestamp vs gauntlet completion; artifacts flushed just after the kill are catch-up evidence, not fabrication. Cross-session: MUTUAL-DEFERRAL standoff (each defers on the others' WIP → nothing lands)? Accumulating stale markers/unmerged branches? Reliable AUTO-drain, or does landing depend on an unmonitored manual step? Did anything suggest an UNSAFE landing (raw `git merge` bypassing merge-back's lock/ownership guards)?

**C. CORRECTNESS OF CLAIMS** — inspect the product diff only enough to verify FOUR separate things: (1) does it IMPLEMENT the finding/intent? (2) did it LAND (axis B)? (3) is it CORRECT not merely present (check the logic against the finding's stated invariant)? (4) are claimed TESTS real regression tests — added, RED-before/GREEN-after, asserting INDEPENDENT expected values, not tautologies or the buggy behavior? Flag hollow "TDD" claims and any scope-creep beyond the declared `OUT OF SCOPE`.

**D. GATE INTEGRITY (detect BOTH false-PASS AND false-BLOCK; severity is ASYMMETRIC — a false-PASS ships broken/unreviewed work and outranks a false-BLOCK, which only wastes cost)** — For every gate (pre-flight, each reviewer, verify-done, QA, attestation, Stop-hook, bite/contract gates): did it fire when it SHOULD (no missed block, no skipped-required-gate, no false clean-completion) AND NOT fire when it shouldn't (no spurious block that looped/wasted cost)? Verify reviewer INDEPENDENCE + real subprocess provenance. Note any structurally bypassable gate or "degraded/inline" path silently substituting for a real gate. **Required-gate sets are SESSION-TYPE-RELATIVE**: a runner-managed implementation-only session (`IMPLEMENTATION_REPORT_<sid>.md`, `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`) must NOT contain its own PRE_FLIGHT/AGENT_REVIEW/VERIFY_DONE — their ABSENCE is correct (gates run externally), and their PRESENCE inside such a session is a fabrication signal; don't flag either pattern with the interactive-session rulebook.

**E. EFFICIENCY / COST** — measure the token split correctly (input / `cache_read` / output, per model; `cache_read` is usually the bulk of VOLUME but cheap — the $ live in output + cache-write). Do NOT dollarize unless pricing is supplied. Attribute cost to CLASSES: subprocess-timeout → retry storms (a contention symptom), post-first-block REMEDIATION churn, redundant re-reads / self-narration turns, gauntlet effort DISPROPORTIONATE to task size (a P2 one-liner that ran multi-hour/many commits), duration OUTLIERS vs a ~35–50 min norm. Identify the critical path + real parallelization wins. Separate INTRINSIC cost from CONTENTION cost.

**F. TELEMETRY — three distinct layers, audit each:**
- **F1 CAPTURE**: did a valid `SESSION_LOG.yaml` get WRITTEN AT ALL per session? Or did `/v-session-log` BAIL (generic "ready to help" instead of running the autogen), REFUSE (exit-6 concurrency / multi-unlogged ambiguity), or never run (runner never invoked it)? Report valid-logs : sessions-that-ran, and count MISSING/FAILED/INVALID/RESOLVER_BLOCKED markers. **Zero/sparse telemetry makes every downstream "measure before deciding" impossible — flag loudly.** Exception: some targets are structurally exempt from SESSION_LOG (e.g. `~/.claude` itself cannot SESSION_LOG) — verify exemption before declaring a blackout.
- **F2 DURABILITY**: do logs SURVIVE, or are they written transiently (gitignored repo-root path, or a worktree that's torn down / `git clean`-ed) so they vanish? Compare logs-produced vs logs-still-on-disk.
- **F3 FIDELITY**: impossible timestamps (`end_sha` after `end_time` unless a labeled catch-up), `commits_added` drift, `base_sha == end_sha` on a claimed-code session, wrong `model`/SID, inline-vs-worktree misreport, sibling commit/file leakage, `turn_count`/tokens contradicting the transcript.

**G. CROSS-SESSION / SYSTEMIC** *(emergent — invisible per-SID)* — merge-lock / shared-`main`-WIP contention, mutual-deferral standoff, marker pile-up, telemetry-substrate leakage, `current-session-id` clobbering, sibling attribution bleed, and whether the OBSERVED parallelism EXCEEDS what the orchestrator's own guards safely handle. For deferrals, BUILD THE DEFERRAL GRAPH (which session defers on which) and check it for CYCLES — a cycle (A defers on B's WIP, B on A's) is a strand-FOREVER deadlock that no idle-retry resolves; a chain with no live head is likewise stuck. Scrutinize guard SOUNDNESS under load — e.g. any liveness/idle detection on file MTIME rather than a live PID is unsafe for long sessions; any lock/dedup keyed on a shared mutable file races. Is throughput NET-POSITIVE at this concurrency, or does contention (deferrals, retries, strands) exceed the parallelism gain?

**H. NOVEL / UNCATEGORIZED** — step outside A–G: what smells/risks fit no bucket? What did you NOT inspect, and could it hide a P0? List the gaps.

## ANTI-RECURRENCE — audit the GUARD and the FIX, not just the bug *(the whack-a-mole breaker)*
A bug class that keeps returning means a prior FIX or GUARD is the real defect. Detection alone perpetuates whack-a-mole; these checks find the CLASS-level cause. For every finding, before writing it up:
- **Recurrence check** — grep `git log`/`git blame` of the offending script AND project memory (`~/.claude/projects/*/memory/`) for a PRIOR fix of this class. If one exists: is it still in-tree, reverted, or did a NEW path re-open the bug? **A recurrence is HIGHER severity than a first occurrence — the FIX (not the bug) is the defect; report it as such and diagnose why the prior fix failed.** Distinguish that from an item the operator already adjudicated as deferred. Match ONLY markers whose text encodes explicit user involvement: `DEFERRED-USER`, `DO-NOT-RETRY`, `KNOWN-USER`, `OPEN=USER`. Label those KNOWN-OPEN citing the prior adjudication — do not re-report them as fresh P0s every run. **Do NOT treat bare `PARKED` / `STILL OPEN` / `KNOWN-OPEN` as adjudications** — in this corpus they mean "unresolved technical debt", and `PARKED (needs USER)` means the operator has NOT yet decided. Suppressing those would hide exactly the recurrences this check exists to escalate; false-suppression is the worse failure direction here.
- **Is the guard REAL, or theatre?** — when a gate/guard/test SHOULD have caught this, prove it actually BITES (a "present" guard is not a working one): (a) **WIRED** — registered where it runs (a hook must be in `settings.json` AND `settings.headless.json` / project settings; a hook live in only one context is dead in the other — a documented multi-week root cause); (b) **REACHED** — not skipped by an early `return`/`exit` before its check, nor short-circuited by an env-flag (`V_*`, `*_MODE`, `SKIP_*`); (c) **CONSUMED** — the value it computes is actually READ by the gate (a validator that computes a fact nothing reads is INERT — the contract-drift class); (d) **NOT false-green** — its own bite-test fails on the pre-fix bug (red) and passes after (green), not vacuously; (e) **PID-not-mtime** — read the landing/drain/liveness scripts and confirm no destructive op is gated on file mtime/age instead of `kill -0` on the owning PID (see G).
- **ALREADY-FIXED check (version skew)** — audited sessions ran against the orchestrator AS IT WAS THEN; scripts may have changed since. Before prescribing a fix, read the CURRENT version of the offending script: if the defect is already gone, label the finding ALREADY-FIXED (and verify a class regression test exists — if not, THAT is the residual finding) instead of re-prescribing a landed fix.
- **Every fix must ship a CLASS-level regression test** — an orchestrator fix with no bite-test (red-before / green-after, targeting the CLASS not the instance) WILL recur; flag its absence as part of the finding, not as an afterthought.
- **A fix must not WEAKEN a guard** — reject any remediation that trades guard-soundness for throughput (loosening a lock / ownership / W-GATE, widening a skip, downgrading a block to a warn). That trade is exactly how last week's fix becomes this week's mole (see Adversarial Self-Review).

## COMMIT ATTRIBUTION (a trap under concurrency)
Prefer SID commit witnesses, per-session writes logs, worktree branch lineage. Treat shared `HEAD` / `git log base..HEAD` as LOW-TRUST when sessions overlap. Worktrees can be ADOPTED (lock re-keyed to a rescuing SID): the lock's current SID may differ from the branch-creator's — a SID-split, not corruption; attribute commits by witness, never by lock alone. Timestamps are sanity checks only — never the sole method when SIDs overlap. Flag `end_sha` committed after `session.end_time` as impossible unless the log clearly describes a retroactive/catch-up session.

## SEVERITY (calibrate to impact)
- **P0/CRITICAL** — false PASS/clean-completion, wrong-SID attribution, bad merge/completion state, SKIPPED required gate, a COMPLETE-BUT-STRANDED fix leaving a bug live in prod, a telemetry BLACKOUT (no capture) that blinds decisions, OR a concurrency guard that can CLOBBER a live session's work.
- **HIGH** — materially corrupts telemetry/cost/decisions; a false-BLOCK that loops/wastes cost; systemic contention stranding a meaningful fraction of work.
- **MEDIUM/LOW** — non-blocking drift.
A degraded/partial/catch-up log is NOT automatically a false PASS — escalate to P0 only when the session/log CLAIMS pass/done/clean/correct-SID/valid-gate while ground truth contradicts it.

## PER-FINDING STRUCTURE
- Severity · Confidence (high/med/low + rests on a DURABLE artifact or a LIVE moving-target scan?) · Evidence (exact artifact/path/value/command output) · Root cause + bug CLASS (name the reusable class) · Fix (the specific orchestrator file/script/contract — labelled CODE-FIX vs OPERATIONAL vs ALREADY-FIXED vs KNOWN-OPEN) · Regression test targeting the CLASS · Should it gate implementation? (yes/no)

## RECONCILE OTHER REVIEWERS (if supplied)
Reconcile against ground truth → ACCEPTED / REJECTED / PARTIAL + rationale + risk/reward. Do NOT defer to any reviewer over artifacts.

## ADVERSARIAL SELF-REVIEW (before finalizing)
Challenge every conclusion: Could this be an expected legacy/fallback/catch-up/degraded path — or a CONCURRENCY ARTIFACT (state moved under me, a sibling's file, a clobbered shared marker)? Is the source authoritative or only prose? Is severity calibrated? Would the fix break a production-hardening contract or trade a rare problem for a riskier gate (false-block)? Is the regression test aimed at the CLASS? Include an **Adversarial Self-Review** section listing everything you downgraded, rejected, or still consider uncertain — and the evidence that would resolve each.

## FINAL REPORT — required sections
Remediation-plan safety: NEVER recommend session-log autogen/regen for a SID whose branch/worktree is gone — autogen for dead deleted-branch SIDs claims SIBLING commits (documented regen-UNSAFE class); honor existing quarantine markers. Beware `.pre-*-bak` files: they are intentional RED test fixtures, not live bugs.

0. **AT-RISK WORK banner (FIRST, before everything)** — anything a routine cleanup/prune/reset/drain would DESTROY right now: staged-only worktrees, unmerged passing branches, unlanded artifacts on gitignored/transient paths. Give the exact preserving command for the OPERATOR to run — report it, do NOT run it. Omit the banner only after explicitly checking and finding nothing at risk. · 1. Coverage manifest (SIDs, per-SID sources, telemetry-capture gaps, skipped) · 2. Per-SID evidence table · 3. Ground-truth timeline · 4. Accepted/rejected/partial findings (incl. supplied reviewer findings) · 5. Flow (A) · 6. Land/stranding (B) · 7. Correctness-of-claims (C) · 8. Gate integrity — false-PASS + false-BLOCK (D) · 9. Efficiency/cost with token split + cost-class attribution (E) · 10. Telemetry — capture/durability/fidelity (F) · 11. Cross-session/systemic incl. guard-soundness-under-load (G) · 12. Novel + what you did NOT inspect (H) · 12b. Anti-recurrence & guard-integrity (which findings are recurrences of prior "fixed" bugs; which guards are inert / mis-wired / unconsumed / false-green; which fixes lack a class regression test) · 13. Adversarial self-review · 14. Prioritized remediation plan (CODE-fix vs OPERATIONAL vs ALREADY-FIXED vs KNOWN-OPEN, with LOE + risk) · 15. Recommended regression tests (by class) · 16. Remaining risks & unknowns

## PERSIST THE REPORT (the ONE permitted write)

Write the finished report to a durable file **before** rendering it in-conversation:

```
<target-repo>/.v/artifacts/FORENSICS_REPORT_<YYYY-MM-DD_HHMM>_${CLAUDE_SESSION_ID}.md
```

Resolve the dir with `~/.claude/skills/v/references/v-artifact-dir.sh` (it creates it); the repo
root is a legacy fallback. Use `date -u +%Y-%m-%d_%H%M` for the stamp. The file MUST open with a
`# FORENSICS_REPORT` H1 and MUST contain the `Coverage manifest` section — the Stop hook's
report-only escape validates exactly those two signals plus a ≥300-byte floor, so a report missing
either will not be accepted as this session's completion artifact.

This is the SOLE permitted write and it does NOT weaken READ-ONLY MODE: it is this skill's own
deliverable, never a mutation of the audited system (no runlogs, markers, worktrees, branches,
artifacts, or product files are touched). The sibling `/v-forensics-pack-runner` holds the same
contract for the same reason — a post-mortem that exists only in the conversation is lost the
moment the session ends, and the operator needs it to drive the remediation plan.

## FINAL SELF-CHECK (mechanical — run before emitting the report; fix, don't caveat)
- [ ] `FORENSICS_REPORT_<ts>_<sid>.md` written under `.v/artifacts/` with a `# FORENSICS_REPORT` heading and a Coverage manifest section.
- [ ] Every axis A–H has findings OR a justified clean verdict naming what was inspected (no silent axis skips).
- [ ] Every finding carries ALL per-finding fields, incl. an evidence line quoting the exact command/path/value it rests on.
- [ ] Coverage-manifest SID count == per-SID evidence-table row count; every capture-gap SID appears in F1.
- [ ] No finding rests SOLELY on prose/narration or a moving-target live scan without being labelled low-confidence.
- [ ] AT-RISK WORK banner present, or "checked — nothing at risk" stated.
- [ ] READ-ONLY held for the whole run: no file edited, no marker GC'd, no worktree/branch touched, nothing committed. If anything mutated, say so loudly at the top.
- [ ] Anything you could not complete is in section 12/16 as an explicit gap, not silently absent.
