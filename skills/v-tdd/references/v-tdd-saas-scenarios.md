# SaaS-Critical Test Scenarios — v-tdd Reference

_Last reviewed: 2026-07-05_

Domain-specific test scenarios for SaaS classes. Select the relevant set based on the class under test — do NOT use all scenarios at once. Pick 3-5 per TDD session and work through them one at a time (red → green → refactor).

## Subscription Lifecycle Tests

For any class that manages subscription state transitions:

```
- it('transitions from trial to active on payment')
- it('transitions from active to past_due on payment failure')
- it('transitions from past_due to active on payment retry success')
- it('transitions from active to cancelled on user cancellation')
- it('transitions from cancelled to active on reactivation within grace period')
- it('transitions from cancelled to expired after grace period')
- it('denies access to premium features when subscription is past_due')
- it('preserves data when subscription is cancelled — does not delete')
- it('handles concurrent subscription modifications gracefully')
- it('rejects invalid state transitions — e.g., expired to active without new payment')
```

## Payment Edge Cases

For billing services, webhook handlers, or payment-related controllers:

```
- it('handles declined payment with user-facing error message')
- it('handles disputed/chargeback webhook and suspends access')
- it('handles refund webhook and adjusts subscription accordingly')
- it('processes webhook with idempotency — duplicate event is safe')
- it('handles out-of-order webhook delivery — event B before event A')
- it('rejects webhook with invalid signature')
- it('handles partial refund differently from full refund')
- it('handles currency mismatch or amount mismatch gracefully')
```

## Tenant Data Isolation

For any model or query that operates in a multi-tenant context:

```
- it('scopes all queries to the current team by default')
- it('prevents accessing resources belonging to another team')
- it('prevents updating resources belonging to another team')
- it('prevents deleting resources belonging to another team')
- it('handles team switching — queries reflect the new team immediately')
- it('does not leak tenant data in API responses or error messages')
```

## Permission Boundary Tests

For policies, middleware, or any authorization logic:

```
- it('allows owner to perform all team actions')
- it('allows admin to manage members but not delete team')
- it('restricts editor to content operations only')
- it('restricts viewer to read-only operations')
- it('denies access when user has no role on the team')
- it('handles permission check when user is removed from team mid-session')
- it('prevents privilege escalation — editor cannot grant admin role')
```

## Race Condition Scenarios

For operations where concurrent access is plausible:

```
- it('handles concurrent subscription modifications without double-charging')
- it('handles double-submit on payment form — only one charge created')
- it('handles parallel webhook processing for same event — idempotent')
- it('handles concurrent team member invitation for same email')
- it('handles simultaneous resource creation with unique constraint')
```

## Scenario Selection Guide

| Class Keywords | Recommended Scenarios |
|---------------|----------------------|
| Subscription, Plan, Trial | Subscription Lifecycle (pick 3-5) |
| Billing, Payment, Invoice, Charge | Payment Edge Cases (pick 3-5) |
| Webhook, StripeWebhook | Payment Edge Cases (idempotency + signature) + Race Conditions |
| Team, Tenant, Organization | Tenant Data Isolation (all 6 — these are critical) |
| Policy, Permission, Role, Gate | Permission Boundary (pick 4-5) |
| Any SaaS model with team_id | Tenant Data Isolation (minimum) + relevant domain set |
