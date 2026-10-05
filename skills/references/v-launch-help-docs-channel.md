# Help docs and first-mile support channel decision

_Last reviewed: 2026-08-02 (fixed dangling deliverability citation now that `v-launch-deliverability.md` exists; stripped stale "deferred — Batch 2" markers now that `v-launch-week-ops.md` is written; prev 2026-07-06 theme-consistency sweep A)._

Bound by the zero-outreach gate (`~/.claude/skills/references/v-core-solo-motion.md`):
support intake here is INBOUND only (docs, help widget, email people send first) — never
recommend proactive outreach to users as a support or activation channel.

> **Persona for this reference:** senior solo-SaaS launch
> operator with experience picking the support intake channel
> at the 0–100 customer stage. Loaded by `v-prelaunch-readiness`
> Surface 5 (Docs) when no support channel is configured, and
> by `v-activation-funnel-design` when designing post-signup
> flows that need a "Need help?" affordance.
>
> **Last verified:** 2026-05-10. Support-tool landscape shifts
> on 18-month horizons; verify pricing and feature sets before
> adopting any specific tool.

The decision is about *where customers go when something is
broken or unclear*, not about how good the docs are. Docs answer
the questions the operator anticipates. The support channel
catches everything else — and "everything else" is where
product learning lives in the first 30 days post-launch.

---

## Decision frame

Pick the smallest support surface that meets the actual need.
At 0–50 customers, more tooling = more places to forget to check
= worse signal-to-noise.

| Stage | Recommended channel | Why |
|---|---|---|
| Pre-launch | Email-only (`support@yourproduct.com` → personal inbox) | Minimal setup; founder reads everything; no missed messages |
| Launch + first 30 customers | Email + in-app feedback widget | Widget reduces friction 10× on minor issues; email handles "real" support |
| 30–100 customers | Same OR upgrade to lightweight ticketing (Plain, Help Scout) | Threading + search become valuable; still founder-fielded |
| 100+ customers | Plain / Intercom / Crisp with playbooks | Volume requires triage tools and canned responses |

**At your stage (pre-launch / 0–30 customers), the answer is
almost always: email + in-app widget.** Heavier tools introduce
more failure modes than they prevent.

---

## Tool category survey (last-verified 2026-05-10)

### Email-only

- A real address (`support@yourproduct.com`) forwarded to your
  inbox. Set SPF/DKIM/DMARC on this domain before relying on it —
  see `~/.claude/skills/references/v-launch-deliverability.md`
  § Minimum-viable setup.
- Pros: zero setup; nothing to forget; nothing to break
- Cons: no threading; no shared inbox if you eventually hire;
  can't easily mine for patterns

### In-app feedback widget

- Examples: Plain widget, Crisp widget, custom button → mailto
- Pros: 10× lower friction than email for minor issues; captures
  page context automatically; users will report things they
  wouldn't email about
- Cons: noise can swamp signal; need a triage rule

The "custom button → mailto" option (a `<button>` that opens a
prefilled email with current URL + user's email) is a 1-hour
implementation that captures 80% of the widget benefit at zero
vendor cost.

### Live chat

- Examples: Intercom, Crisp, Plain (with chat add-on),
  Drift (B2B-shaped)
- When to use: B2B SaaS where prospects ask questions during the
  trial-to-paid decision; consumer SaaS at scale
- When to skip: pre-launch, low traffic, solo operator who
  cannot maintain SLA — broken-promise live chat is worse than
  no live chat (visible-but-unattended widget signals abandoned)

### Async ticketing

- Examples: Plain (modern, minimal), Help Scout (mature, popular),
  Front (multi-channel; heavier)
- When to use: Volume exceeds threading capacity in personal
  inbox (~30+ emails/day); hiring is on the horizon
- When to skip: <100 customers, solo, low support volume

### Community-driven (Discord, Slack Connect, Github Issues)

- When to use: Developer products (Github Issues for OSS-shaped
  products); community that benefits from peer support
- When to skip: B2B SaaS where buyers expect 1:1 support; PII /
  privacy concerns prevent open community

---

## Anti-patterns to avoid

| Mistake | Why it bites | Fix |
|---|---|---|
| Multiple channels (email + chat + Discord + Twitter DMs) | Operator can't keep up; messages slip; users feel ignored | Pick ONE primary; route everything else there |
| Live chat widget without SLA | Customers wait, see "agent not available" hours later, churn | Either commit to <30-min response during business hours OR don't show the widget |
| Help Scout / Intercom installed pre-launch with 5 articles | Looks unfinished; signals abandoned project | Email-only at pre-launch; bring up help center when you have 20+ articles |
| `support@` forwarded to a Gmail label that isn't watched | Misses 30% of support volume silently | Forward to operator's primary inbox; treat support emails as P0 during work hours |
| Discord support-channel where the operator isn't online | Unanswered questions become public failure signals | Don't open a Discord until you'll be in it daily |

---

## What goes in the pre-launch readiness check (Surface 5: Docs)

In addition to the existing Surface 5 docs checks, also confirm:
- [ ] Support channel decided and documented (email address,
      widget tool, or both)
- [ ] If email: address is real, monitored, with auto-reply that
      sets expectation ("Replies within 24 business hours")
- [ ] If widget: SLA is realistic for solo operator; widget hidden
      outside business hours OR shows "we'll reply within X hours"
      messaging
- [ ] Support address visible from at least 3 surfaces:
      footer of marketing pages, footer of in-app, signup
      confirmation email
- [ ] Three pre-written canned responses ready — see
      `~/.claude/skills/references/v-launch-week-ops.md`
      § The three canned responses (pre-written, copy-paste ready):
      1. "Spike-related slowness" template
      2. "Known issue with workaround" template
      3. "Need more info to repro" template

---

## Migration triggers

Upgrade from email-only to ticketing when:
- Support email volume exceeds 20/day for 2 consecutive weeks
- Two support emails are missed in a month (slipping below the
  inbox-zero discipline)
- You hire a second person who needs visibility into support

Upgrade from ticketing to live chat when:
- Sales-cycle conversations consistently start in the support
  channel (B2B mid-market signal)
- You have a dedicated support person (so SLA can be enforced)

---

## Cross-references

- Pre-launch readiness Surface 5 (Docs): `~/.claude/skills/v-prelaunch-readiness/references/surface-checks.md`
- Activation funnel design (where the support affordance lives in-app): `~/.claude/skills/v-activation-funnel-design/SKILL.md`
- Launch-week ops (3 canned responses + escalation rules): `~/.claude/skills/references/v-launch-week-ops.md`
- Beta program feedback widget guidance: `~/.claude/skills/v-beta-program/references/beta-program-playbook.md` § In-product feedback widget
