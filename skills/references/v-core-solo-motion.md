# Solo-Operator / Zero-Outreach Motion Gate (shared)

_Last reviewed: 2026-08-02 (SKILL-CONTENT-REVIEW-2026-08-02 Theme 5: added the synchronous-1:1-sessions-with-existing-users clause below, the root-cause fix for v-beta-program's live-call defaults; prev 2026-07-06 theme-consistency sweep A)._

Single source of truth for the operator's go-to-market motion constraint. Every growth,
messaging, pricing, launch, differentiation, and prelaunch skill MUST cite and apply this
gate before emitting a finding, recommendation, benchmark target, or prompt-pack task.

## The constraint

The operator is a **solo founder running a self-serve subscription SaaS with NO sales team
and NO outbound motion.** All acquisition/retention must be **passive and asset-based**:
organic search, AI-assistant citation/discoverability, product-led/self-serve activation,
owned content, lifecycle email to people who already signed up, and referral loops that run
without the founder in the loop.

## Prohibited findings/targets (NEVER emit unless the project CLAUDE.md declares that motion)

A finding is **out of motion** and MUST NOT be emitted — or must be reframed — if executing it
would require any of:

- **Cold outreach** — cold email/DM sequences, "5–7 touches over N days", SDR/BDR cadences,
  lead lists, outbound prospecting.
- **Founder-led sales** — "book a demo", discovery calls, sales-assisted onboarding, "get on
  a call", hand-selling, quote-based/"contact us" pricing as the primary path.
- **Community posting/farming** — ongoing community presence as a growth channel:
  karma-farming, reciprocal-engagement farming, vote-soliciting, "build in public" as a
  prerequisite, Product Hunt as a required launch gate, or any recurring "post in
  communities / engage with threads" cadence.
  **One-time launch carve-out (operator's stated policy):**
  ONE-TIME, no-relationship-building self-posts and listings (Product Hunt, Show HN, a
  subreddit launch post, IndieHackers, directory submissions) under the `/v-launch-channels`
  playbook rules ARE permitted, as are reactive replies to inbound comments on the
  operator's own posts. The banned line is *ongoing human effort* and *initiating contact
  with individuals* — those stay prohibited regardless of channel.
- **Manual network recruitment** — hand-picking beta invitees from a personal network,
  influence-network seeding, "reach out to N people you know".
- **Guest posting / PR / link-begging** — pitching publications, guest-post campaigns,
  manual backlink outreach, HARO-style pitching.
- **Synchronous 1:1 sessions with users — including users who ALREADY signed up.** Live calls,
  "white-glove"/"founder personally onboards each user", 15-min feedback calls, scheduled
  screen-shares, user-interview cadences, office hours. **This clause exists because the rest of
  this list is scoped to GTM/acquisition, so a live call with an *existing* user fell through
  every sweep** — `v-beta-program` gated its follow-up *emails* behind `OUTBOUND_OK=1` while
  leaving a founder-call cadence completely ungated (2026-08-02 content review, Theme 5). The
  prohibited property is **recurring synchronous human time**, not whether the person is a
  stranger: a solo operator cannot staff 1:1 calls at any user count, and the cost scales with
  adoption exactly when there is least slack.
  *Passive equivalents:* async survey, in-product feedback widget, session replay, a recorded
  Loom walkthrough, an async written interview the user answers on their own schedule.
  *Permitted:* a **one-way recorded** asset sent to many (a launch video, a Loom), and reactive
  replies to inbound support the user initiated.
- **Anything requiring a team** the operator does not have (support org, sales org, CSM).

## How to apply (three outcomes, in order)

1. **Reframe to a passive equivalent when one exists.** This is the default. Examples:
   - cold outreach → SEO/AEO asset, comparison page, or lifecycle email to existing signups
   - "book a demo" CTA → interactive product tour / self-serve trial / async Loom
   - ongoing community presence → one-time launch-day self-posts/listings (permitted per the
     carve-out above) + AI-assistant-discoverability assets (structured, citable content;
     llms.txt is optional/LOW-value per `seo-volatile-knowledge-2026.md` § AI Search and Bot
     Guidance) + organic/owned channels
   - hand-picked beta → public waitlist / in-product opt-in / inbound-sourced cohort
   - guest posts / earned links → linkable owned assets that attract links passively
2. **Score as "correctly absent", not as a gap.** When a skill's rubric checks for an
   outbound artifact (a demo CTA, an outreach sequence, a sales page), the *absence* of that
   artifact in a self-serve product is **correct** — score it neutral/pass, never a deduction
   or a P0/P1 finding. Do not manufacture a finding to fill an outbound-shaped hole.
3. **Only emit as-is when the project CLAUDE.md explicitly declares an outbound/sales motion.**
   Absent that declaration, assume zero-outreach. If genuinely uncertain whether a
   recommendation is passive, treat it as prohibited.

## Motion-declaration check (one line, cite at the gate)

```bash
# Outbound findings are allowed ONLY if the project opts in with an EXPLICIT structured
# declaration. Default = zero-outreach. The match is anchored to a real `motion:` key so that
# NEGATION prose ("solo shop with no sales team", "no outbound sales") — exactly how a
# zero-outreach operator describes themselves — does NOT trip the opt-in. Substring matching on
# "sales team"/"outbound sales" is a gate-bypass; do not use it. `[[:space:]]` (not `\s`) for
# portability on stock BSD grep.
OUTBOUND_OK=0
grep -qiE '^[[:space:]]*motion:[[:space:]]*(outbound|sales-led|sales-assisted)([[:space:]]|$)' \
  "${PROJECT_ROOT:-.}/CLAUDE.md" 2>/dev/null && OUTBOUND_OK=1
# When OUTBOUND_OK=0: reframe/score-absent per outcomes 1–2 above; never emit prohibited findings.
```

## Note for reviewers

A skill that emits any prohibited finding without a CLAUDE.md motion opt-in is a **P0**
(it can drive an autonomously-executed prompt pack to build outbound infrastructure the
operator will never use — or worse, cold-email real people). Absence of an outbound artifact
is never a finding.
