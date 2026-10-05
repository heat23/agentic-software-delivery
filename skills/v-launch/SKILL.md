---
name: v-launch
description: "Use when launching a solo SaaS — one door that gates readiness, fixes blockers, generates legal docs, and plans launch-day channels."
allowed-tools: Read, Write, Bash, Skill, TaskCreate, TaskUpdate
user-invocable: true
disable-model-invocation: true
context: fork
model: sonnet
---
<!-- skill: v-launch | version: 1.1.1 | last-updated: 2026-08-12 -->
<!-- 1.1.0 (2026-08-02): added a third "Legal risk" gate tier (above SHOULD-FIX, below MUST-FIX) —
     an OUT_OF_SCOPE_* jurisdiction gap or an undocumented accessibility posture now blocks GO
     the same way a MUST-FIX does, with the same explicit --override-legal-risk acknowledgement
     mechanism --skip-gate already uses. Previously these read as SHOULD-FIX, identical to
     cosmetic polish. -->

_Last reviewed: 2026-08-02 (added Legal risk gate tier; prev 2026-07-06 authored)._

# 2026 Canonical Contract

Tier: User-facing entry point. WIZARD orchestrator — one door over the launch pipeline
(`/v-prelaunch-readiness` gate → fix loop → `/v-legal-docs-generate` → `/v-launch-channels`). Owns
sequencing + a single go/no-go `LAUNCH_PLAN` so the operator never picks a skill or juggles reports.

This contract overrides older sections below on conflict.

Follow `_v-core.md`, `_v-exec.md`, `_v-review.md`, and `_v-growth.md`. **Bound by the zero-outreach gate** —
read `~/.claude/skills/references/v-core-solo-motion.md` and apply it: the launch plan is owned/earned
channels + assets (Product Hunt, Hacker News, Show HN, Reddit, X, LinkedIn, IndieHackers) only — these
one-time launch-day self-posts/listings are licensed by that file's **one-time launch carve-out**
(§ Prohibited findings/targets); never cold DMs, mass outreach, paid placement, hand-pitching
individuals, or any ongoing community-posting cadence.

For subprocess dispatch of the chained specialists, read `~/.claude/skills/v/references/v-dispatch-subagent.sh`.

```yaml
contract:
  tier: user-facing
  accepts: [project state, optional --skip-legal (docs already exist), optional --skip-gate (re-run after fixes), optional --override-legal-risk (explicit acknowledgement to GO with an open Legal risk item — mirrors --skip-gate), optional "fix N[,M]" execute directive on re-invocation]
  produces: [LAUNCH_PLAN_${CLAUDE_SESSION_ID}.md (the single go/no-go board + launch sequence), drafts/fixes via /v on one-tap execute, BLOCKED_${CLAUDE_SESSION_ID}.md + HANDOFF_${CLAUDE_SESSION_ID}.md companion (terminal-block exits)]
  invokes: [/v-prelaunch-readiness, /v-legal-docs-generate, /v-launch-channels]
  conditional-invokes: [/v (one-tap fix of MUST-FIX punch-list items)]
  invoked-by: [/v, user]
  estimated_tokens: 20k-60k
  estimated_duration: 10-30 min
  # orchestration + synthesis only — the chained specialists run on their own budgets
```

## Skill Boundaries

**SME persona:** This wizard is run by a **launch operator for a solo subscription-SaaS founder** who treats launch as a sequence, not an event — product readiness, legal basics, launch-day posting — and whose job is to hand the operator ONE go/no-go call plus the shortest path to green, not four separate reports to reconcile.

### Best fit

- "I want to launch — walk me through it" in ONE command
- An operator who doesn't want to remember `/v-prelaunch-readiness` vs `/v-legal-docs-generate` vs `/v-launch-channels`, in what order
- Getting a single go/no-go verdict with a prioritized blocker list and a launch-day channel sequence
- Re-running after fixing blockers to confirm the gate is now clean

### Use instead

- **`/v-prelaunch-readiness`** directly — when you only want the readiness audit artifact, not the full launch sequence. This wizard *invokes* it as its gate.
- **`/v-legal-docs-generate`** directly — when you only need the baseline legal docs.
- **`/v-launch-channels`** directly — when readiness + legal are already handled and you only want the channel plan.
- **`/v-traffic`** — for ongoing organic-traffic growth AFTER launch. This wizard is the launch moment; v-traffic is the post-launch loop.
- **`/v-audit-orchestrator` [Bundle]** — for the broad multi-audit pre-launch *sweep* (SEO + messaging + check + consolidate). This wizard is the narrower launch-day path (readiness gate → legal → channels), not a full audit bundle.

### Not for

- Paid acquisition / ads / influencer deals (organic + owned/earned channels only)
- Cold outreach, mass DMs, or hand-pitching (prohibited by the zero-outreach gate)
- Writing the actual product code that fixes a blocker (it hands MUST-FIX items to `/v`)
- Post-launch growth (that's `/v-traffic`) or funnel design (that's `/v-activation-funnel-design`)

## Why This Exists

Launching solo is a sequence — readiness gate, legal baseline, channel plan — spread across three skills the
operator has to remember, run in the right order, and reconcile by hand. Worse, the readiness gate produces a
punch list that then has to be fixed and re-checked before it's safe to post anywhere. This wizard collapses it
to: **run one command, get a go/no-go with the blocker list, reply `fix 1,3` to clear blockers, and walk away
with the launch-day sequence.** It produces no findings of its own; it sequences the specialists and
synthesizes their output into one decision-ready board.

## Entry Point

Resolve project root per `_v-core.md § Project Root Detection`; parse `V_DEPTH`. Initialize a task list
(`TaskCreate`/`TaskUpdate` — the current tools this session grants; never a name from memory).

### Step 0 — Orient (no questions)

Read `CLAUDE.md` / `README` for product context. Detect prior state: newest `PRELAUNCH_READINESS_REPORT_*`,
existing legal docs (`content/legal/*.md` / `privacy-policy.md`), and a prior `LAUNCH_PLAN_*`. Never quote
secrets from any `.env*`.

### Step 1 — Readiness gate (the go/no-go)

Run `/v-prelaunch-readiness` (reuse a `< 3-day-fresh` report unless the operator asked to re-run) → its
prioritized punch list of **MUST-FIX** / **SHOULD-FIX** findings. This is the gate — **three tiers, ranked
by what blocks GO**, not two:

- **Any open MUST-FIX → NO-GO.** Surface the MUST-FIX list at the top of the board with a one-tap fix
  affordance (`reply "fix 1,3"`). Do NOT proceed to publish-ready launch assets while a MUST-FIX is open —
  the plan is produced but stamped `NO-GO — clear MUST-FIX first`. (The operator may `--skip-gate` to override
  with an explicit acknowledgement; record the override in the plan.)
- **Legal risk (blocks GO unless explicitly overridden).** A detected cross-border privacy gap or an
  undocumented accessibility posture is real exposure, not cosmetic polish — it does NOT get folded into
  SHOULD-FIX, where it would read identically to a nice-to-have while the board says ship. See Step 2 for
  what populates this bucket. If any Legal risk item is open, the plan is produced but stamped
  `NO-GO — legal risk open`. The operator may pass `--override-legal-risk` to GO anyway — **the same
  explicit-acknowledgement mechanism `--skip-gate` uses for MUST-FIX**: the override is a deliberate
  operator decision, recorded in the plan (which item, why overridden), never silently applied or assumed
  from a plain re-invocation.
- **MUST-FIX AND Legal risk both clear (SHOULD-FIX may remain) → GO**, with SHOULD-FIX listed as "nice to
  clear before launch."

### Step 2 — Legal baseline (unless `--skip-legal` or docs exist)

Run `/v-legal-docs-generate` → privacy policy / terms / cookie policy (+ DPA when the codebase implies it).
Report which docs were generated vs already present. Two things route into the **Legal risk** bucket
(Step 1), never here:

- An `OUT_OF_SCOPE_*` emission (non-US/CA jurisdiction detected — e.g. EU/UK exposure): surface the
  evidence and the recommended path (qualified attorney, or re-scope) verbatim from that file.
- The generated `LEGAL_AUDIT_*.md` § Compliance Gaps Found items explicitly tagged `LEGAL RISK` — as of
  `v-legal-docs-generate/SKILL.md` § Step 3 this currently includes the accessibility-posture gap (no
  accessibility statement / no documented WCAG conformance posture — ADA Title III and state
  web-accessibility-law litigation have no small-business exemption) and an open state AI-transparency
  applicability finding for an AI-featured product. Any OTHER `LEGAL_AUDIT` recommendation not tagged
  `LEGAL RISK` stays SHOULD-FIX (routed per Step 1, never here).

### Step 3 — Channel plan

Run `/v-launch-channels` → the owned/earned channel bundle + cross-channel sequence + follow-up cadence, all
passing the zero-outreach gate. Before publishing, its assets go through `/v-anti-template-gauntlet` (its own
conditional-invoke) so nothing ships with AI-template tells.

**Dispatch mechanism.** Prefer **Path A** (the `Skill` tool) to invoke each specialist in-context. When
Skill-tool dispatch is unavailable (headless/blocked), fall back to **Path B**: dispatch each as an
independent `claude -p` subprocess via `~/.claude/skills/v/references/v-dispatch-subagent.sh` — same shape as
`/v-audit-orchestrator § Path B` (NO `--agent` — these are SKILL slash-commands; `--mode self-write` because
each writes its own report):

```bash
printf '%s\n' "/v-prelaunch-readiness [V_DEPTH=1]" > /tmp/vl-dispatch-${CLAUDE_SESSION_ID}.txt
~/.claude/skills/v/references/v-dispatch-subagent.sh \
  --model sonnet --mode self-write \
  --prompt-file /tmp/vl-dispatch-${CLAUDE_SESSION_ID}.txt \
  --artifact "$PROJECT_ROOT/PRELAUNCH_READINESS_REPORT_${TIMESTAMP}_${CLAUDE_SESSION_ID}.md"
# then /v-legal-docs-generate and /v-launch-channels, same shape.
```

On non-zero exit (helper codes 2-7) record the failure and continue. Never hand the operator a manual
paste-plan of sub-steps — that reintroduces the cognitive load this skill exists to remove.

### Step 4 — Synthesize the ONE launch board

Write `.v/artifacts/LAUNCH_PLAN_${CLAUDE_SESSION_ID}.md` (Phase-2: under `.v/artifacts/` — create the dir via `~/.claude/skills/v/references/v-artifact-dir.sh`; gate + cadence readers dual-search) — plain English, decision-ready. Essentials (H1 is `# LAUNCH_PLAN`
+ a `session:` line so the Stop-hook report-only registry can content-validate it):

- **`## Verdict`** — `GO` / `NO-GO — clear N MUST-FIX first` / `NO-GO — legal risk open` /
  `GO (gate overridden)` / `GO (legal risk overridden)`, one line.
- **`## Blockers (MUST-FIX)`** — each: one-line what + why + a one-tap fix affordance (`→ reply "fix 1"`).
- **`## Legal risk (blocks GO unless explicitly overridden)`** — each open item (an `OUT_OF_SCOPE_*`
  jurisdiction gap, an undocumented accessibility posture, an open state AI-transparency finding) with
  evidence + recommended path; write "none open" when clear — never omit the section. Any
  `--override-legal-risk` use is recorded here: which item, the operator's stated reason.
- **`## Before launch (SHOULD-FIX)`** — the nice-to-clear list, collapsed. Legal-risk items are routed
  per Step 1, never here.
- **`## Legal`** — which baseline docs exist / were generated; any SHOULD-FIX-tier legal audit
  recommendation not already routed to Legal risk above.
- **`## Launch day`** — the channel sequence (which channel, in what order, with the post/asset), from
  `/v-launch-channels`; plus the follow-up cadence.
- **`## snapshot`** — machine block for a re-run's diff (open MUST-FIX ids).
- Every item passes the zero-outreach gate.

### Step 5 — One-tap execute (fix the blockers)

Operator replies `fix N` / `fix N,M` (or re-invokes `/v-launch fix 1,3`). For each picked MUST-FIX, hand off
to `/v` (`/v <blocker as a task>`) — `/v` owns the TDD/build/gate loop and the Stop-hook artifact contract a
launch session can't satisfy mid-flight. Then re-run Step 1's gate to confirm the blocker cleared. Never
auto-fix items the operator didn't pick.

### Step 6 — Cadence & state

On re-invocation where a prior `LAUNCH_PLAN_*` exists, OPEN with the delta: which MUST-FIX and which Legal
risk items are now cleared, what's newly failing, and the remaining go/no-go gap — so the operator sees
progress toward GO, not a cold re-audit.

## Idempotency

**Idempotent as a planner; delegation is the only mutation path.** Re-running produces a fresh SID-qualified `LAUNCH_PLAN_${CLAUDE_SESSION_ID}.md` (prior plans are never clobbered — different SID, and the re-invocation delta view reads them, per "On re-invocation" above) and reuses `< 3-day-fresh` specialist reports instead of re-running them. The skill itself never modifies project source; a `fix N` execute directive hands the item to `/v`, whose own gauntlet owns that mutation. Chained specialists own their own artifacts' idempotency.

## Completion Contract

- **Interactive (`V_DEPTH == 0`):** produce `LAUNCH_PLAN_${CLAUDE_SESSION_ID}.md` and present the board. A
  plan-only run emits `.md` artifacts (+ the chained specialists' own reports/docs) and does not owe the code
  gauntlet. **One-tap execute changes this:** handing a MUST-FIX to `/v` runs a real build → that session owes
  the code gauntlet, which `/v` itself satisfies via its own pre-flight/verify-done contract. Do NOT claim "no
  code" once a `fix` directive has run.
- **Headless (`V_DEPTH >= 1`):** run non-interactively with documented defaults; never call `AskUserQuestion`
  headless. If it can't run the gate (no project readable) it writes `BLOCKED_${CLAUDE_SESSION_ID}.md` +
  `HANDOFF_${CLAUDE_SESSION_ID}.md` (a terminal blocked-exit: a `BLOCKED_` naming the reason + a `# Handoff` companion) and stops — never fabricate a GO verdict.
- Do NOT git commit. Do NOT open PRs (per global policy: publishing/launching is a separate explicit step the
  operator runs; this skill produces the plan + assets, it never posts them anywhere itself).
