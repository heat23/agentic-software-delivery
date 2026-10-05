# Operator readiness — pre-mortem and pre-commitment (T-30 → T-7)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

> **Persona for this reference:** senior solo-SaaS launch
> operator with experience watching otherwise-ready launches
> fail because the *operator* wasn't ready. Loaded by
> `v-prelaunch-readiness` Phase 9 (Operator readiness) when the
> launch window answer is "today / this week" or "next 2-4 weeks."
>
> **Firing window:** T-30 → T-7. Explicitly NOT launch week
> (T-7 → T+0): pre-mortem at T-0 is theatre. At T-7 the
> operator can still cut scope; at T-3 they can't.

This phase exists because every other surface in
`v-prelaunch-readiness` checks the *product*. None check the
*operator*. Solo SaaS launches fail more often from a tired,
overcommitted, sunk-cost-trapped operator than from a broken
hero or a missing OG image. This phase forces a 5-minute
ruthless self-audit before the launch window narrows.

---

## What this is, what it isn't

**This IS:** a forced-binary 5-line pre-commitment that gets
read back to the operator when triggers fire on launch day.
Pre-commitments survive motivated reasoning in a way that vague
"I'll cut scope if I need to" intentions don't.

**This is NOT:** a workbook, a reflection journal, or a
checklist of operator-psychology surfaces. Those get skip-buttoned
at T-7. The single forced-binary artifact does not.

---

## The 5-line pre-commitment

The artifact this phase produces is exactly 5 lines, each of
which forces a binary decision the operator could otherwise
delay indefinitely.

```
LAUNCH PRE-COMMITMENT — [Product Name] — committed at T-[N] by [Operator]

1. SCOPE-TO-SHIP: If launch slips 48 hours, the ONE thing I will
   cut is: [specific feature / surface / asset]
2. DEAD-MAN: If [specific metric] is below [specific threshold]
   at [specific time on launch day], I will stop launching
   that channel and pivot to [next channel / engagement-only mode]
3. ENERGY-FLOOR: If I have slept <6 hours for 3 consecutive
   nights before launch, I will [defer launch by N days |
   not launch on this date]
4. SUNK-COST-EXIT: I am willing to cancel this launch if a
   different agent (not the one helping me build it) reviews
   the case and recommends cancellation. I will run that review
   at T-3.
5. POST-LAUNCH-FLOOR: If [specific outcome] does not happen by
   T+7, I will [pivot product direction | extend runway plan |
   stop non-essential spending] before T+30.
```

Each line is a forced binary — no "maybe", no "depending on" —
because the failure mode is the operator at 3am of launch day
trying to decide. The pre-commitment is the answer; the moment
of decision is the read-back, not the decision itself.

---

## How to elicit good answers (subagent dispatch pattern)

The operator's first draft of any of these lines will be vague
("I'll see how it goes" / "depends on the metrics"). Vague
pre-commitments don't survive launch day; they collapse into
default action (continue launching).

The skill body that loads this reference should dispatch ONE
subagent (`--model sonnet`, persona: hostile launch reviewer) per
line, with this brief:

> **Dispatch mechanism:** both consumers (`v-prelaunch-readiness`,
> `v-launch-channels`) run `context: fork`, so the Agent tool is
> unavailable — dispatch via
> `~/.claude/skills/v/references/v-dispatch-subagent.sh --model sonnet --mode capture`.
> The former `model: opus` here was stale (opus tier retired 2026-07-07) and
> `enforce_model_policy()` now rejects it outright with exit 2.

> "The operator just wrote: '[their first answer]'. Your job
> is to make this answer specific enough that it can't be
> rationalized away on launch day. Push back on every weasel
> word ('maybe', 'depending', 'I'll see'). Do not accept any
> answer that doesn't include: a specific feature/metric/
> threshold/time/action. If they refuse to commit, output
> 'OPERATOR REFUSED COMMITMENT — flag for self-review at
> T-3'."

After 5 dispatches (one per line), the artifact is captured.

---

## Sunk-cost exit subagent (line 4)

Line 4 commits the operator to running an adversarial review of
the cancellation case at T-3. The same skill ecosystem that
helped build the launch is biased toward shipping it; a
separately-dispatched subagent is necessary for honest
sunk-cost detection.

The T-3 sunk-cost subagent receives:
- The operator's pre-commitment artifact
- Current product readiness state (from prior `v-prelaunch-readiness` runs)
- A simple brief: "Argue for cancelling this launch. List every
  reason cancellation would be the right move. Steelman the
  cancellation case. Do NOT moderate toward 'launch with
  caveats' — your role is to articulate the strongest argument
  for *not* launching."

The operator reads the cancellation case, then makes the call.
Most of the time the case is unconvincing and the operator
proceeds with a clearer head. Sometimes the case lands. Either
outcome is a better decision than the unexamined-momentum
default.

---

## Operator-state telemetry (line 3)

Energy floors are the most-skipped commitment. Solo founders
launching tired make worse decisions: they engage hostilely with
HN comments, they over-promise in support replies, they ship
hot-fixes that introduce regressions, they defend design choices
they would have changed if rested.

The 6-hour / 3-night threshold is a heuristic, not a rule.
Adjust if the operator has historical data (some operators
genuinely run on 5 hours; most do not). If the operator can't
honestly self-report sleep, the heuristic is "feel like garbage
3 days running" — same threshold, different metric.

---

## Launch-slip branch

If the operator decides to slip the launch (line 1 trigger
fires, or sunk-cost exit triggers, or energy floor trips):

1. Re-run `v-prelaunch-readiness` with the new launch date.
2. The pre-commitment artifact is regenerated for the new date
   — DO NOT carry forward the old commitments. New date, new
   reality, new commitments.
3. Document the slip cause in the artifact metadata so post-
   launch retro can identify whether the slip was structural
   (real obstacle) or operational (fixable in next launch).

---

## What goes in the readiness report

Phase 9 result lands as one section in the
`PRELAUNCH_READINESS_REPORT_*.md`:

```markdown
## Phase 9: Operator readiness

Pre-commitment captured: [yes | no | refused]
Firing window honored: [T-N where N >= 7]
Sunk-cost exit subagent dispatched at T-3: [yes | no | scheduled]
Energy floor commitment: [specific threshold + action]

[5-line pre-commitment artifact verbatim]
```

If the operator refused any of the 5 lines, flag MUST-FIX:
launching without a pre-commitment when the operator was given
the chance is itself a strong sunk-cost-trap signal.

---

## Cross-references

- Pre-launch readiness gate (host): `~/.claude/skills/v-prelaunch-readiness/SKILL.md` § Phase 9
- Launch-week real-time operations (where commitments get tested): `~/.claude/skills/references/v-launch-week-ops.md`
- Channel launch playbook: `~/.claude/skills/v-launch-channels/SKILL.md`
- Adversarial / sparring partner pattern: `~/.claude/skills/references/persona-lens.md`
