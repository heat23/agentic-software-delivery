# v-bug-hunt Quick Reference

Operator-facing cheat sheet. The full contract lives in `SKILL.md`.

## When to run

| Situation | Run? |
|---|---|
| You just shipped a feature and want to verify it's actually production-ready | YES (target = the feature) |
| Pre-launch sweep on a specific revenue-critical or data-critical flow | YES (target = the flow) |
| You don't trust "tests pass" as proof of correctness on AI-generated code | YES |
| A real bug shipped — what other latent bugs are similar? | YES (target = the affected subsystem) |
| You want a full-codebase audit | NO — run `/v-check` first |
| You want boundary/edge-case coverage (empty, unicode, DST, currency, limits, entitlement) | NO — run this SAME skill with `--lens=boundaries` (after the default bugs-lens pass) |
| You want a visual / UX / brand audit | NO — run `/v-audit-code` (absorbed `/v-ui-audit` 2026-07-06) |
| You want to know if tests pass | NO — run `/v-pre-flight` |
| You want a pre-launch operational-readiness checklist | NO — run `/v-prelaunch-readiness` |

## Invocation

```
/v-bug-hunt
/v-bug-hunt auth
/v-bug-hunt onboarding
/v-bug-hunt "checkout flow"
/v-bug-hunt async pipeline thorough
```

If you don't pass a target, the skill will ask. **One target per session, always.**

## Outputs

| Artifact | Path | Purpose |
|---|---|---|
| Report | `BUG_HUNT_REPORT_[timestamp]_${SID}.md` | Read this. Prioritized findings with repro. |
| JSON | `BUG_HUNT_REPORT_[timestamp]_${SID}.json` | Only when `--format=json`. For pipeline tooling. |
| Prompt pack | `.v-prompt-packs/v-bug-hunt-<MM-DD>/` | Paste a file into a fresh `/v` session to land the fixes. |

## Severity rubric

| Tier | Means | Example |
|---|---|---|
| P0 | Data loss, auth bypass, payment correctness, prod crash on real path | "Refresh during checkout 500s and the cart is lost" |
| P1 | User strands, race condition under normal use, silent failure on golden path | "Concurrent submits create duplicate records" |
| P2 | Degraded UX, missing fallback, error UX, log gap | "Generic 'something went wrong' hides actionable 422" |
| P3 | Suspected / pattern-match-only / unverified UI | "Possible race in JobX (couldn't reproduce in session)" |

## Read the report in this order

1. **EXECUTIVE_SUMMARY** — how many findings at each priority.
2. **STOP_CONDITIONS_HIT** — was the run cut short?
3. **Baseline (from prior audits)** — what was excluded from this report (already known).
4. **P0_CRITICAL** then **P1_IMPORTANT** — fix in IMPLEMENTATION_ORDER.
5. **FINDINGS_REQUIRING_HUMAN_DECISION** — operator-only calls.
6. **P3_SUSPECTED** — last; manual repro to promote or drop.
7. **VERIFIED_GOOD** — what's already correct (useful for confidence).

## Fix workflow

```
# 1. Read the report
cat BUG_HUNT_REPORT_*.md

# 2. Open the prompt pack
ls .v-prompt-packs/v-bug-hunt-*/

# 3. Pick the highest-priority session
cat .v-prompt-packs/v-bug-hunt-*/critical-path.txt

# 4. Paste it into a fresh /v session and let v-build execute

# 5. After all fixes land, re-run v-bug-hunt on the same target to verify
/v-bug-hunt <same target>
```

## Composition with other skills

```
/v-pre-flight  (must pass before bug-hunt)
    ↓
/v-check       (broad sweep — run first if you haven't recently)
    ↓
/v-bug-hunt    (this skill — one target per pass)
    ↓
/v-build .v-prompt-packs/v-bug-hunt-<MM-DD>/critical-path.txt   (per session, wave order per 00-README.md)
    ↓
/v-pre-flight  (post-fix gate)
    ↓
/v-verify-done (convention check)
    ↓
/v-bug-hunt <same target>  (verify zero regressions)
    ↓
/v-bug-hunt <same target> --lens=boundaries  (optional boundary companion — reads the same-target BUG_HUNT_REPORT as baseline)
```

## What this skill will NOT do

- Run tests, builds, lint, or any quality gate (that's `/v-pre-flight`)
- Edit application source, tests, or config files (read-only audit)
- Find visual / brand / copy issues (that's `/v-audit-code`, absorbed `/v-ui-audit` 2026-07-06)
- Audit the whole codebase in one pass (pick a target)
- Auto-fix anything (fixes land in `/v-build` from the prompt pack)
- Decide product / business policy (those go in FINDINGS_REQUIRING_HUMAN_DECISION)
