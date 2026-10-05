# Email deliverability: SPF/DKIM/DMARC + launch-day warm-up

_Last reviewed: 2026-08-02 (created)._

> **Persona for this reference:** senior solo-SaaS launch operator who has watched a
> launch-day traffic spike land signup-confirmation email in spam because the sending
> domain had zero reputation history. Loaded by
> `~/.claude/skills/references/v-launch-help-docs-channel.md` (support-domain DKIM/DMARC
> step) and by `v-prelaunch-readiness` when transactional email is unconfigured or a
> launch-day send-volume spike is expected.
>
> **Last verified:** 2026-08-02. SPF/DKIM/DMARC are IETF standards (RFC 7208, RFC 6376,
> RFC 7489) — the mechanics below are stable. Re-verify on a 12–18 month horizon:
> ESP-specific setup UI/steps, and mailbox-provider warm-up/throttling behavior (Gmail,
> Outlook, Yahoo retune spam models independently of the standards).

A failed or spam-foldered verification email is a broken activation funnel on day one —
before the operator even knows there's a problem, because the user who never got the
email doesn't file a support ticket, they just leave. This is inbox-arrival infrastructure,
not a nice-to-have.

---

## Why this needs a launch-day-specific plan, not just "set up email once"

A solo SaaS has near-zero send volume pre-launch, then suddenly sends hundreds or
thousands of signup-confirmation + welcome emails in a single-day traffic spike. To
receiving mailbox providers, a volume spike from a low-reputation, newly-active sending
domain looks exactly like a spam burst — the two failure modes (misconfigured auth,
un-warmed domain) compound at the exact moment first-impression email matters most.

---

## Minimum-viable setup

### 1. SPF (Sender Policy Framework)

- One TXT record at the sending domain listing every authorized sending source (your
  ESP's documented `include:` — Postmark/SendGrid/SES/Resend/Mailgun all provide one).
- **Never publish more than one SPF TXT record per domain** — merge into a single record.
  Multiple SPF records is a common, easy-to-introduce bug; receiving MTAs may honor only
  the first or fail validation entirely (RFC 7208).
- Stay under 10 DNS lookups (SPF "too many DNS lookups" permanent error) — keep `include:`
  chains minimal.

### 2. DKIM (DomainKeys Identified Mail)

- Generate the key pair in the ESP dashboard (all major transactional ESPs auto-generate).
- Publish the CNAME/TXT record the ESP provides at `<selector>._domainkey.yourdomain.com`.
- Verify with a real test send: view raw headers for a `DKIM-Signature` field and confirm
  `dkim=pass` in the receiving side's `Authentication-Results` header.

### 3. DMARC (Domain-based Message Authentication, Reporting & Conformance)

- Publish a `_dmarc.yourdomain.com` TXT record.
- **Start at `p=none`** (monitor-only). Do not jump to `p=reject` before watching aggregate
  reports for at least 1–2 weeks and confirming every legitimate sending source (ESP, and
  any personal-inbox forwarding) passes.
- Progression: `p=none` (2+ weeks, watch reports) → `p=quarantine` → `p=reject` once
  confident no legitimate mail fails.
- Add `rua=mailto:dmarc-reports@yourdomain.com` (or an ESP's free DMARC-digest tool) —
  without a monitored reporting address, DMARC gives zero visibility into what's failing.

### 4. From-domain hygiene

- Send transactional email from a **subdomain** of the marketing domain (e.g.
  `mail.yourproduct.com`, `notify.yourproduct.com`), not the bare apex. This isolates
  transactional sending reputation from marketing/cold-email reputation in either
  direction — a subdomain problem never poisons the root domain, and vice versa.
- Never send transactional and bulk/marketing email from the same sending domain.

---

## Launch-day warm-up

- **Warm the domain before launch day, not on it.** Send a trickle of real transactional
  email (test signups, beta-tester welcome emails) for 1–2 weeks pre-launch so the
  sending domain has reputation history before the spike hits.
- **Confirm the ESP's shared-vs-dedicated IP posture.** Most transactional ESPs
  (Postmark, SES, Resend) use shared IP pools that are pre-warmed by the provider at
  solo-operator volume — no action needed. A dedicated IP (typically a higher-volume
  plan tier) shifts warm-up responsibility to the operator — check which posture the
  plan uses before assuming it's handled.
- **Rate-limit-aware queueing.** If the launch spike could exceed the ESP plan's
  documented sending-rate limit, queue transactional sends through the job queue at that
  rate rather than firing synchronously — this is the same discipline as
  `~/.claude/skills/_v-jobs.md` (external API calls belong in jobs, never the request
  lifecycle), and it doubles as spike absorption.
- **Watch bounce/complaint rate live during launch day.** Most ESPs auto-pause sending
  above roughly 2% hard-bounce or 0.1% spam-complaint rate (exact thresholds are
  ESP-specific — check the plan's docs, they shift). A climbing rate is almost always a
  list-hygiene problem (invalid addresses from a bot-signup burst), not a deliverability
  config regression — diagnose there first.

---

## What goes in the pre-launch checklist

- [ ] SPF record published as a single record, resolves cleanly (`dig TXT yourdomain.com`)
- [ ] DKIM record published and verified with a real test send
- [ ] DMARC record published at minimum `p=none` with a monitored `rua=` address
- [ ] Transactional email sent from a subdomain, not the bare marketing domain
- [ ] Domain warmed with real send volume for 1–2 weeks before the expected launch-day spike
- [ ] Bounce/complaint-rate dashboard bookmarked for launch-day monitoring

If none of the above is in place and the product has any signup/billing/password-reset
flow (true for essentially every SaaS), flag **MUST-FIX** in the readiness report.

---

## Cross-references

- Support channel + domain setup (cites this file for the DKIM/DMARC step):
  `~/.claude/skills/references/v-launch-help-docs-channel.md`
- Pre-launch readiness gate: `~/.claude/skills/v-prelaunch-readiness/SKILL.md`
- Background jobs / external API call discipline: `~/.claude/skills/_v-jobs.md`
- Launch-day monitoring thresholds: `~/.claude/skills/references/v-launch-week-ops.md`
  § Section 1: Day-of monitoring
