# Rating framework — design your own, defend it

There is no mandated category list or scale. Pick a framework that fits *this* system and scenario, define it, and score with evidence. The framework is yours; the discipline is non-negotiable.

## Principles
- **Categories should map to how this system actually fails.** A payments backend and a static marketing site do not deserve the same taxonomy. Derive categories from the real scenario and threat model, not a generic template.
- **Score against the real audience and scenario**, not an abstract ideal. "No queue for outbound email" may be a blocker for one app and a conscious, acceptable trade-off for another. (Off-stack capabilities like offsite backups are outside the boundary entirely — never score inputs, per `_v-audit.md` § In-App Actionability Boundary.)
- **Every score needs a one-line, evidence-grounded rationale.** A number with no "because <anchor>" is noise.
- **Be honest about ceilings.** If a category can't exceed some level because of a deliberate, owner-owned deferral (or something outside the in-app boundary), say so — don't silently mark it down as a defect.
- **Keep it comparable over time.** If the user re-runs the audit after fixes, hold the scale and categories steady so deltas mean something. Show the movement (before → after) when you have a prior.

## A reasonable default (use, adapt, or replace)
A 0–10 scale reads clearly and supports deltas:
- **0–3** not ready — real blockers.
- **4–6** partial — works but has gaps that matter.
- **7–8** solid — production-grade with minor items.
- **9–10** excellent — hard to meaningfully improve.

Example category set for a typical web/SaaS backend (adapt freely): Authentication & Access Control · Secrets & Encryption · Security Hardening & Boundaries · Data Integrity & Safe Mutations · Reliability & Error Handling · In-app Observability · Testing & Quality Gates · Code Quality & Architecture · UX & Content · Feature Completeness · Modernization/Era-fit.

## Reporting the verdict
- Compute an overall signal (a mean is fine), **but** state plainly that go-live is usually **floor-gated, not averaged** — one category at 3 can block a 9.0 mean. Name the gating categories.
- **A single P0 finding forces a failing verdict on its own, independent of every category score.** Per `[[v-core-severity]]` (`~/.claude/skills/references/v-core-severity.md` § Scoring discipline): one P0 blocks even when every category rates 9-10 and the mean would otherwise read "excellent." Check for an unresolved P0 BEFORE computing or reporting the overall signal — a high mean must never paper over an unresolved P0.
- Distinguish three buckets in the verdict: genuine blockers · improvements · out-of-scope/deferred (rated honestly, framed as the owner's trade-off, not a new failure).
- If the codebase is mature and the sweep only surfaces trivia, say the returns are diminishing. That candor is worth more than a padded findings list.
