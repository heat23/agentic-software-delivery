---
name: v-forensics-pack-runner
description: "Read-only post-mortem of the run-v-packs + merge-drain landing layer: did fleet work land on main, what stranded, did runner status lie? Run after a batch."
argument-hint: "[pack-run dir (with .runlogs/.done/.needs-review) and/or repo path — defaults to current repo]"
allowed-tools: Read, Grep, Glob, Bash, Agent, Write
model: sonnet
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-forensics-pack-runner | version: 1.0.0 | last-updated: 2026-08-12 (added model/version metadata) -->

# 2026 Canonical Contract

Tier: comprehensive (READ-ONLY forensic post-mortem of the run-v-packs + merge-drain landing layer). User-invocable. Analysis only — never drains, merges, GCs markers, or edits; output is the report.

This contract overrides older sections below on conflict.

```yaml
contract:
  tier: comprehensive
  accepts: [optional pack-run dir (with .runlogs/.done/.needs-review) and/or repo path via $ARGUMENTS — defaults to the current repo]
  produces: [PACK_RUNNER_FORENSICS_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md (durable file under .v/artifacts/ — Phase-2; create the dir) — the SAME forensic report also rendered in-conversation; every claim cited to runlogs, .done/.needs-review state, git ancestry, drain output]
  invoked-by: [user, /v-forensics (cross-lane escalations)]
  # /v-self-audit does NOT currently reference this skill (verified 2026-07-05: no match in its
  # SKILL.md or references/) — removed from invoked-by rather than claiming an unwired caller.
  # invokes: [] is literal — this skill NEVER Skill-invokes another skill. "Escalate to /v-forensics"
  # in the body means a REPORT-LEVEL hand-off (name the cross-lane finding, cite the sibling as its
  # owner) — NOT a `Skill(/v-forensics)` call. The operator runs the sibling; this skill only reports.
  invokes: []
  dispatches: optional read-only per-pack analyzer subagents (bounded evidence packets)
  estimated_tokens: 80k-300k
  estimated_duration: 10-45 min
```

## Idempotency

Fully idempotent: READ-ONLY by hard constraint — inspects runlogs, archive/park dirs, git ancestry, and drain markers without mutating any of them, so re-running re-derives the same landing verdicts from the same durable state (a re-run AFTER another fleet batch legitimately reports the new batch). Never runs the drain, merge-back, or branch GC as part of the audit — it reports what a re-run of those tools WOULD do, with the exact command for the operator.

# run-v-packs Pack-Runner + Merge-Drain Landing Forensics — Post-Mortem

You are running the **v-forensics-pack-runner** skill: a READ-ONLY forensic post-mortem of the SHELL LANDING LAYER — `run-v-packs`, `v-drain-deferred-merges.sh`, `v-merge-back.sh`, and the git-worktree lifecycle. This audits the LANDING LAYER and its runner telemetry, **not** product code and **not** the per-session `/v` internals (use `/v-forensics` for those). The one question it answers: **did the work the fleet produced actually LAND on `main`, was anything silently stranded / lost / duplicated, and did the runner's own status output tell the truth?**

Your mandate is COMPREHENSIVE and ADVERSARIAL. The axes below are a FLOOR, not a ceiling. Treat "nothing found in category X" as a claim you must justify with what you inspected. The batch ran a FLEET on a shared repo, so contention, mutual-deferral, sibling cross-contamination, and duplicate sessions are FIRST-CLASS subjects.

**SIBLING SKILL — `/v-forensics`** audits per-SESSION `/v` orchestration + telemetry (gate integrity, correctness of claims, telemetry fidelity). Hand off across the boundary so nothing falls in the crack: if you find a LANDING CONTRADICTION (runner claims "queue empty"/"landed"/"drained" while commits are unmerged) or dirty-`main` residue traceable to a specific SID's aborted gauntlet (`GAUNTLET_SKIPPED_<sid>`), name it and escalate to `/v-forensics` (did a gate fail / was the orchestration flow correct for that SID?). **"Escalate" here = a report-level hand-off, NOT a Skill invocation** — record the cross-lane finding in your report and name `/v-forensics` as its owner for the operator to run; do NOT call the sibling skill yourself (`invokes: []` is literal). Conversely, a per-session gate/telemetry defect is out of THIS skill's lane — record it and point at the sibling. **Runner-invocation & telemetry-capture is a shared seam**: if the runner produced sessions but zero valid `SESSION_LOG.yaml`, that BLACKOUT is a runner-dispatch bug (did `run-v-packs` pass the session-log writer?) — own the "was it dispatched" half here, hand the "why the writer bailed" half to `/v-forensics`.

## READ-ONLY MODE (hard constraint)
Analysis only. Do NOT merge, drain, run `v-merge-back.sh` / `v-drain-deferred-merges.sh` / `run-v-packs`, remove/prune worktrees, delete/force-delete branches, stash, reset, checkout, clean, GC markers, commit, or edit any file of the audited system (including its artifacts/tests). **The SOLE permitted write is this skill's own deliverable** — the `PACK_RUNNER_FORENSICS_REPORT_[timestamp]_${CLAUDE_SESSION_ID}.md` report artifact written ONCE at the end (see FINAL REPORT). Writing that report is the deliverable, not a mutation of the landing layer; it never touches runlogs, markers, worktrees, branches, or product files. Allowed read-only inspection: `git worktree list`, `git rev-list`, `git log`, `git reflog`, `git cat-file -e`, `git merge-base`, `git branch --contains`, `git diff`, `git status --porcelain`, `git merge-tree` (NEVER a real `git merge`), `ps`, `lsof`, `kill -0`. If a validator writes BY DESIGN, say so first and prefer a dry-run / disposable-temp path. **The repo may be LIVE under concurrency** — sibling sessions can mutate `main`, add/remove worktrees, and overwrite shared runtime files while you inspect; prefer durable per-worktree markers over live scans and flag any moving-target signal. Do NOT ask "want me to land/fix this?" — output is the report only.

## TARGET & PATHS (compute — do not hardcode)
- **Pack-run dir**: if `$ARGUMENTS` names a dir containing `.runlogs/` / `.done/` / `.needs-review/` / `*_PROMPT_PACKS_ALL.txt`, use it. Its `.runlogs/*.log` are the runner's own logs (suspect narration).
- **Target repo**: if `$ARGUMENTS` is/embeds a repo path use it; else `git rev-parse --show-toplevel` from cwd. The pack-run dir usually lives INSIDE the repo (e.g. `<repo>/audit-fix-packs-r3`); resolve both.
- **Worktrees**: `git -C <repo> worktree list --porcelain` — this is the SOLE authoritative enumerator; it prints every worktree's ABSOLUTE path wherever it lives. Do NOT guess a path convention — worktrees are inconsistently placed (some under `<repo>/.worktrees/**`, some flat under `~/.claude/worktrees/**`, some under a `~/.claude/worktrees/<repo-basename>/` subdir); a computed glob WILL miss some. Only `worktree list` is reliable; treat any path glob as a fallback hint, never the enumeration.
- **Per-worktree markers**: in each worktree root and its `.v/artifacts/` — `WORKTREE_HANDOFF_<sid>.md`, `.claude-session-lock` (first token = full SID, may carry PID), `GAUNTLET_SKIPPED_<sid>.md`, `PRE_FLIGHT_REPORT_<sid>.md`, `AGENT_REVIEW_<sid>.md`, `VERIFY_DONE_REPORT_<sid>.md`, `DISPATCH_PROVENANCE_<sid>.log`, `*.output`.
- **Merge lock**: `<repo>/.worktrees/.merge-lock` (+ its `owner` file: `SID PID EPOCH`).
- **The scripts** (READ their logic to interpret exit codes / classification branches — do NOT run them): `~/.claude/skills/v/references/v-merge-back.sh`, `v-drain-deferred-merges.sh`, and the drain's helpers in the same dir — `v-strand-redrive.sh` (re-attaches worktree-less stranded branches), `v-dup-lane-detect.sh` (duplicate-lane census), `v-record-unmerged-branch.sh`. `run-v-packs` (locate via `command -v run-v-packs`) is MODULARIZED: its landing/verdict/reconcile logic lives in `run-v-packs-lib/` beside the binary (`10-discovery`, `20-git-landing`, `30-verdict`, `40-archive-reconcile`, `50-pack-exec`, `60-wave`) — reading only the main file misreads the runner (the known "grep the runner FILE" scope-drift class).
- **Run knobs (recover BEFORE assigning severity)**: read the batch's env/flags from the runlog header / invocation line. `V_PACK_DRAIN=0` disables the end-of-run drain AND the per-wave landing barrier BY DESIGN (rescue packs use it) — stranded-at-end under it is EXPECTED, an operational note + drain command, NOT a P0. Also note `V_DRAIN_DUPDETECT=off`, `ONCE`, dry-run/verify-only, and any model pin. A by-design outcome misfiled as P0 is a false finding.
- **Batch-start anchor**: LANDED-vs-ALREADY-MERGED hinges on "dated after this batch started" — derive the anchor from the oldest `.runlogs/*.log` mtime (or the runner's start banner) and STATE it in the report; with interleaved runs on one repo, say which run each merge is attributed to.

## MANAGE CONTEXT — targeted extraction, not full dumps
`.runlogs/*.log` and worktree trees can be large. Grep the field; don't `cat`. Pull only: the runner's summary counters (done/parked/queued + the drain line's considered/drained/deferred/failed/already-merged/skipped-LIVE/skipped-proof-miss/held-ungated + GC counts), the `SELF-AUDIT SUMMARY` block, the runner's FINAL EXIT CODE, per-pack terminal-token + turn counts, and drain per-branch verdict lines. For a large fleet you MAY dispatch ONE read-only analyzer subagent per worktree/branch (each returns a bounded evidence packet), then verify every claim against git here.

## STEP 1 — DISCOVERY & COVERAGE MANIFEST (before opinions)
Enumerate EVERY pack and EVERY branch/worktree with any footprint — an absent log or a "0 done" is itself a finding, not "nothing to analyze."
- **Packs**: list `<pack-dir>/{.,.done,.needs-review}/*` and every wave form (`w<N>-*.txt`, `wave-<N>/`, `99-*-VERIFY.txt`). For each, note folder, terminal token, turn count, and `.runlogs/<pack>.log` verdict.
- **Branches**: `git for-each-ref --format='%(refname:short)' refs/heads` — every `fix/*`, `build/*`, `feat/*`, and any non-`main` branch, INCLUDING ones with no worktree.
- **Worktrees**: `git worktree list --porcelain` + read each `.claude-session-lock` → `SID PID EPOCH`.
- **Live processes**: `pgrep -f 'claude|run-v-packs'` then `lsof -a -p <pid> -d cwd -Fn` to find which are ROOTED in this repo; `ps -o pid,etime,command -p <pid>` for age.

Emit a **COVERAGE MANIFEST**: full pack set + folder, full branch set, worktree set, live-PID set, and what you deliberately skipped and why.

## STEP 2 — GROUND TRUTH (git + markers + PID beat narration)
Trust hierarchy (high→low): git object store + reflog + `worktree list` → per-worktree durable markers (`.claude-session-lock`, `WORKTREE_HANDOFF`, gauntlet artifacts) → PID liveness (`kill -0`) → `.runlogs` prose → pasted `run-v-packs` stdout / model narration. **When narration and ground truth disagree, ground truth wins.**

For EVERY non-`main` branch build an evidence row:
- `git rev-list --count main..<branch>` — commits genuinely ahead (0 ⇒ already landed / empty)
- `git log --oneline main..<branch>` — the actual (possibly stranded) commits + messages
- `git merge-base --is-ancestor <branch> main` — already in main?
- `git merge-tree $(git rev-parse main) <branch>` — the EXIT CODE is the signal: **0 = merges clean, 1 = CONFLICT** (modern 2-arg form takes commit-ish, not trees; on conflict it also lists the conflicted paths). Rely on the exit code, not on grepping `<<<<<<<` markers. NEVER run a real `git merge`.
- **Worktree dirtiness (ahead=0 does NOT mean landed)**: `git -C <worktree> status --porcelain` + `git diff --cached --stat` — staged/unstaged SOURCE in the worktree with 0 commits ahead is a **STAGED-ONLY strand** (the observed false-landed-by-reset class: features checkpointed only in the index, destroyed by any prune/reset). Every classification below requires the dirtiness check, not just commit counts.
- Full SID from `.claude-session-lock` / `WORKTREE_HANDOFF_<sid>.md`; LIVE only if its owning PID passes `kill -0` (**mtime is NOT liveness**)
- **SID reconciliation**: compare lock first-token vs the branch's `-<sid8>` suffix vs marker SIDs. A mismatch is EITHER a rescue-pack **ADOPTION** — the lock was legitimately RE-KEYED by the adopter (adopt by re-key only; adopt-or-create is forbidden — look for the adopter's provenance/handoff trail) — OR wrong-SID attribution (P0). Never assume the lock SID is the originating session; classify which case before judging ownership.

**Runner status is a CLAIM — verify each:** "✓ queue empty / nothing left to do", "N done", "landed", "drained", "lands automatically once idle" must each be reconciled against `main..<branch>` counts and merge commits in `git log`/`reflog`. **PARKED ≠ FAILED; LANDED-CLAIM ≠ MERGED.**

## STEP 3 — CLASSIFY EACH BRANCH (with required proof)
Assign exactly one, and state the proof:
- **LANDED** — a real merge commit for it (reflog `Merge branch '<branch>'` dated AFTER the batch-start anchor), or `merge-base --is-ancestor` true with commits that were ahead at batch start. *(Distinguish from ALREADY-MERGED by timing: this batch landed it.)*
- **STRANDED** — commits ahead of main, session ENDED (handoff marker present / PID dead), not merged. *(For a bug-fix pack this means the bug is STILL LIVE.)*
- **STAGED-ONLY STRAND** — 0 (or few) commits ahead but staged/unstaged SOURCE in the worktree; a commit-based scan reads it as landed/empty while the work exists only in the index. Loss-critical: any prune/reset/GC destroys it — name the exact files (`git diff --cached --name-only`).
- **SUPERSEDED-DUPLICATE** — its content ⊆ main, or ⊆ another branch already landing the same task (prove by `git diff <branch> main -- <files>` being empty / a subset — a duplicate is only redundant if main is a SUPERSET).
- **ALREADY-MERGED** — 0 commits ahead AND clean worktree AND no batch-dated merge commit (it was on main before this batch started; not a landing this run gets credit for).
- **LIVE** — owning PID alive (`kill -0`), session still running.
- **MID-SETUP** — no commits AND no markers AND clean tree, genuinely nascent.
- **ADOPTED** — lock re-keyed to a rescue/adopter session (SID-split with a re-key trail); classify the UNDERLYING work by the rules above and note both SIDs.

## STEP 4 — ANALYSIS AXES (cover every one; add your own)
**A. FLOW / lifecycle** — wave ordering correctness (w1 → wave-N → 99- verify last), archive-only-on-attestation, terminal-token/parking logic, re-run idempotency/safety, whether the runner auto-drains at end or leaves landing to an unmonitored manual step.

**B. LAND / STRANDING** *(usually the dominant failure — never skip)* — Which committed work is ON main vs COMPLETE-BUT-STRANDED? Cross-session: MUTUAL-DEFERRAL standoff (each defers on others' WIP → nothing lands)? accumulating stale unmerged branches/markers? Did anything do an UNSAFE raw `git merge` bypassing `v-merge-back.sh`'s lock/ownership/W-GATE?

**C. DRAIN / MERGE-BACK CLASSIFICATION** *(audit the drain summary — `considered/drained/deferred/failed/already-merged/skipped-LIVE/skipped-proof-miss/held-ungated` + GC counts — against ground truth):*
- `skipped-LIVE` / `skipped-proof-miss` ("no lock AND no stranding proof; likely a sibling mid-setup") — for EACH, check `main..<branch>` count AND worktree dirtiness. **Commits (or staged source) + any SID marker ⇒ the mid-setup verdict is WRONG and real work is stranded (P0/HIGH).** (H-4 made commits-ahead-with-no-artifact count as stranding proof — confirm that guard still bites; don't assume.)
- `deferred` (exit 3) — is there really a concurrent LIVE sibling with uncommitted SOURCE on main, or was main just dirty with disposable residue? A deferred with no live sibling will NEVER self-resolve.
- `held-ungated` — the verdict gate held an ENDED worktree (operator hold marker / QA `verdict: fail` / `BLOCKED_*` / no `AGENT_REVIEW`+no `GAUNTLET_SKIPPED`). Audit each hold: do passing gauntlet artifacts NOW exist on disk? **Photo-finish class**: a session killed at the timeout ceiling can flush its reports seconds-to-minutes AFTER the kill (observed: PRE_FLIGHT_REPORT landed seconds after merge-back declared it missing) — a hold/failure whose artifacts have since materialized is RE-DRIVABLE, not failed. Also check QA-verdict staleness (branch tip post-dating the FAIL verdict).
- `failed` / `merge-back rc=2` — rc=2 = USAGE/CONFIG (wrong/short SID, unprovable ownership); rc=1 = conflict→`WORKTREE_HANDOFF`, **EXCEPT the W-GATE artifact-presence block: a distinct class that writes `SESSION_LOG_PENDING` and NEVER a `WORKTREE_HANDOFF`** — don't hunt for a handoff that doesn't exist for it; rc=3 = deferred. Diagnose which + why (common: dirty main tree; a short-8-char-SID branch the ownership guard couldn't resolve; missing W-GATE artifacts / `GAUNTLET_SKIPPED`).
- **Consent landings** — the drain lands a CLEAN worktree whose owner left `merge-deferred-<sid>.md` (consent + quiescence). Did any consent-landing fire while the owner was actually LIVE, or land a tree that wasn't clean?
- **Drain GC side effects** — the drain GCs dead-PID locks, stale markers, and spent ledgers, and EMITS durable `merge-deferred-<sid>.md` records for misreported-by-omission strands. So a MISSING lock/marker at audit time may have been GC'd by a prior drain (not never-existed), and a present marker may be drain-authored — check reflog/marker content before inferring session behavior from absence.
- **Worktree-less strands** — a branch with commits but NO worktree is INVISIBLE to the drain's worktree walk; verify the re-driver (`v-strand-redrive.sh`) would re-attach it in ALL drain triggers, and that any adoption was by lock RE-KEY only (adopt-or-create is forbidden).
- **Dup-lane detector cross-check** — compare your axis-D clusters against the `v-dup-lane-detect.sh` census in the drain log (unless `V_DRAIN_DUPDETECT=off`). A cluster you found that the detector missed is itself a finding.
- **Liveness gating**: was any "LIVE" skip based on mtime (UNSAFE) rather than `kill -0` on the owning PID?

**D. DUPLICATE SESSIONS** — Find branches with matching name stems (e.g. two `fix/<feature-a>-*` branches, or two `fix/<feature-b>-*` branches) or heavily overlapping changed-file sets (`git diff --name-only main..<b1>` vs `..<b2>`). Per cluster: which is authoritative (fuller/superset), which redundant, do they conflict with each other. Duplicates = wasted fleet cost + divergence/strand risk.

**E. DIRTY-MAIN-TREE** *(dirty WORKTREES are Step 2/3's job — this axis is main only)* — If the runner warned "working tree is dirty": inventory `git status --porcelain` on main. Classify (a) orchestrator residue (`GAUNTLET_SKIPPED_*`, `OP_TELEMETRY_*`, `*_REPORT_*`, `AGENT_REVIEW_*`) vs (b) real tracked source. For tracked source, is it a DUPLICATE of branch work (`git diff <branch> -- <file>` empty ⇒ redundant residue) or UNIQUE uncommitted work (must not be lost)? A dirty main tree is the usual root cause of `rc=2`/deferred — call it out.

**F. CORRECTNESS OF RUNNER CLAIMS — narration, EXIT CODE, and self-audit** — the exit code is the runner's most load-bearing claim (the autonomy invariant: NEVER exit 0 while anything is queued, parked, verify-failed, or off main — stranded ⇒ exit 2; verdict backstop `_gauntlet_verdicts_not_failed`). Reconcile: (1) the FINAL EXIT CODE vs ground truth — **a false exit 0 is the P0 lie for autonomous wrappers**; (2) the `SELF-AUDIT SUMMARY` block's counts vs your own; (3) parked-pack reconcile — `reconcile_parked_by_sid`/`by_proof` should move a parked pack to `.done/` once a later drain lands its work; a stale park contradicting main is a runner bug; (4) turn counts — a "done" pack with 0 turns is a suspect model-refusal/no-op (the Fable-refuses-/v class), verify its diff exists; (5) product diff vs pack intent — symmetric: false "landed" AND false "parked/failed" (a pack parked as unfinished that is actually fully on main).

**G. EFFICIENCY / COST** — wasted duplicate-session work, serial vs parallelizable landing, wall-clock outliers, retry storms from `rc=2`/deferred loops. Do not dollarize unless pricing is supplied.

## ANTI-RECURRENCE — audit the GUARD and the FIX, not just the strand *(the whack-a-mole breaker)*
A landing failure that keeps returning means a prior FIX or GUARD in the drain/merge-back logic is the real defect. For every finding, before writing it up:
- **Recurrence check** — grep `git log`/`git blame` of `v-drain-deferred-merges.sh` / `v-merge-back.sh` / `run-v-packs` AND project memory (`~/.claude/projects/*/memory/`) for a PRIOR fix of this class (e.g. the drain mis-classification, stranding-artifact detection, short-SID ownership). If one exists: still in-tree, reverted, or did a new path re-open it? **A recurrence is HIGHER severity — the FIX is the defect; diagnose why it failed.**
- **Is the guard REAL, or theatre?** — read the actual script logic for the branch that SHOULD have caught this, and prove it BITES: (a) **WIRED** — the check runs on the real path (and hooks it depends on are in `settings.json` AND `settings.headless.json`); (b) **REACHED** — not skipped by an early `exit`/`return` before it (e.g. the drain declaring "no stranding artifact" and skipping BEFORE it checks `main..<branch>` commit count — the exact class you must confirm or refute); (c) **CONSUMED** — a computed classification is actually acted on, not discarded; (d) **PID-not-mtime** — no destructive op (merge/drain/GC) gated on file mtime/age instead of `kill -0` on the owning PID; (e) **NOT false-green** — its bite-test fails on the pre-fix state and passes after.
- **Every fix ships a CLASS-level regression test** — the durable fixture for a drain/merge-back bug is a throwaway repo with the triggering state (e.g. an ENDED worktree carrying a `WORKTREE_HANDOFF` + commits ⇒ the drain MUST land it, not skip it). A fix without such a test WILL recur; flag its absence.
- **A fix must NOT weaken a guard** — reject any remediation that trades soundness for throughput: loosening the merge lock, skipping the ownership guard, gating on mtime, bypassing W-GATE / `GAUNTLET_SKIPPED`, or widening a skip. That trade is how last week's landing fix becomes this week's stranded work.

## SEVERITY (calibrate to LANDING impact, not folder state — and to the RUN KNOBS)
- **P0 / CRITICAL** — committed OR staged-only work stranded off `main` while the runner reports success / "queue empty" / "landed" / **exits 0**; the WRONG branch merged; a merge that clobbered a concurrent sibling's work; a force op that destroyed uncommitted work; merge-back landing under wrong-SID attribution (a SID-split WITHOUT a re-key adoption trail); a dirty-tree "fix" that moved/deleted another session's files.
- **HIGH** — drain mis-classifies a real strand as `mid-setup`/`skipped-LIVE`/`skipped-proof-miss` (work silently stuck); a `held-ungated`/failed branch whose passing artifacts exist on disk (photo-finish) left unlanded with no re-drive path; duplicate sessions for one task; merge-back exit-code misread → manual-merge fallback bypassing lock/ownership/W-GATE; a destructive op gated on mtime not PID; a `deferred` that can never self-resolve.
- **MEDIUM / LOW** — noise `skipped-LIVE` of 0-commit clean worktrees; cosmetic runner-log drift; packs correctly parked as legitimate no-ops.
A parked pack / degraded run is NOT automatically P0. Escalate only when the runner CLAIMS completion/landing/queue-empty while ground truth shows unlanded commits, staged-only work, lost work, or wrong attribution — and only after checking the run knobs: under `V_PACK_DRAIN=0` (rescue mode) stranded-at-end is by-design; report it as an operational item with the exact drain command, not a P0.

## FOR EACH FINDING
- **Severity**: P0/CRITICAL | HIGH | MEDIUM | LOW (maps to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md`: CRITICAL=P0, HIGH=P1, MEDIUM=P2, LOW=P3)
- **Evidence**: exact ground-truth command output / path / value (branch, full SID, sha, commit count, marker path, PID)
- **Root cause + bug class**: which script + which branch of its logic
- **Concrete fix**: the exact script/function/contract to change (e.g. `v-drain-deferred-merges.sh` stranding-artifact detection must recognize `WORKTREE_HANDOFF`; merge-back ownership guard must resolve short-SID branches; `run-v-packs` must not print "queue empty" while unlanded commits exist)
- **Regression test targeting the CLASS**: e.g. a fixture repo with an ENDED worktree carrying a handoff marker + commits ⇒ drain MUST land it, not skip it
- **Should it gate the runner from reporting success?**

## ADVERSARIAL SELF-REVIEW (challenge before finalizing)
- Could a branch flagged STRANDED actually be LIVE (was PID used, not mtime)?
- Could an "ALREADY-MERGED"/"empty" worktree actually be a STAGED-ONLY strand (did you check the index and working tree, not just commit counts)?
- Could a SID mismatch be a legitimate rescue ADOPTION (re-key trail present) rather than wrong-SID attribution — or vice versa?
- Could a "duplicate" be intentional divergence (was CONTENT diffed, not just names)?
- Is a branch "clean into main" now but would CONFLICT after a sibling in the same batch lands first (order dependence)?
- Is the dirty tree real WIP or redundant residue (verified file-content equality vs the branches)?
- Is a `merge-back rc=2` a genuine bug or a LEGITIMATE refusal (unprovable ownership / missing W-GATE / `GAUNTLET_SKIPPED`)?
- Would a proposed drain/merge-back fix risk landing a live session's tree or bypassing the merge lock / W-GATE?
List anything downgraded, rejected, or still uncertain.

## DO NOT ACT
No merges, drain, worktree removal, branch deletion, stash, or commits. No residue cleanup. Output is the forensic report + remediation plan only.

## FINAL REPORT — persist AND render
Write the report to a durable file `PACK_RUNNER_FORENSICS_REPORT_<YYYY-MM-DD_HHMM>_${CLAUDE_SESSION_ID}.md` under the resolved target-repo's `.v/artifacts/` (Phase-2 — create the dir; the Stop hook + sibling forensics dual-search, repo root is a legacy fallback) (use `date -u +%Y-%m-%d_%H%M` for the stamp; fall back to `$(date +%s)` if `CLAUDE_SESSION_ID` is unset), then also render it in-conversation. This is the ONE permitted write (see READ-ONLY MODE) — a landing post-mortem that exists only in the conversation is lost the moment the session ends, and the operator needs it to drive the remediation commands. Do not write any other file.

The report MUST include:
- **Coverage manifest** (Step 1)
- **Per-pack table**: pack | wave | folder | terminal token? | turns | runlog verdict | GROUND-TRUTH: did its work land on main?
- **Per-branch/worktree/SID table**: branch | full SID (+ adopted-from on SID-split) | worktree path | commits ahead of main | staged/dirty tree? | merges-clean vs main? | LIVE(PID)/ENDED | markers | classification | LANDED?
- **Ground-truth timeline** (merges, aborts, drain attempts from reflog; state the batch-start anchor)
- **Runner-narration vs ground-truth contradictions** (esp. "queue empty"/"landed"/"drained"/final EXIT CODE/self-audit counts vs unlanded commits or staged-only work)
- **Flow / lifecycle findings**
- **Landing-correctness findings** (exactly what is stranded off main + risk of loss)
- **Drain / merge-back classification findings** (mis-classification, exit-code handling, liveness gating)
- **Duplicate-session findings** (clusters, authoritative vs redundant, cross-conflict)
- **Anti-recurrence & guard-integrity findings** (which findings recur from a prior "fixed" landing bug; which drain/merge-back guards are inert / early-returned-past / mtime-gated; which fixes lack a class regression test)
- **Efficiency / cost findings**
- **Adversarial self-review**
- **Prioritized remediation plan** (script/contract to change, in priority order)
- **Recommended regression tests** (bug-class fixtures)
- **Remaining risks & unknowns** (branches whose liveness/authoritativeness could not be proven read-only)
