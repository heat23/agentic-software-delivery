# SaaS-Specific Safeguards Reference

These risks require escalated care regardless of scope. Reference: `audit/04-risk-register.md`.

| Trigger | Required Action |
|---------|----------------|
| Billing files touched (Cashier, subscription, Stripe, webhooks, plans) | Hooks enforce commit guard. Additionally: elevate adversarial review to hostile mode; verify eager-loading pattern preserved on billing method calls. |
| Upgrade / upsell / "Upgrade to X" CTA or nudge added or changed | **Gate every upsell CTA on the VIEWER's CURRENT plan/entitlement, not just a feature flag or a usage count.** A user already on (or above) the advertised tier must NEVER see "upgrade to <that tier>". TDD-assert it: a trial-or-subscribed user on the target tier sees the manage-plan path, NOT the upsell; only a user genuinely below the tier sees it. (Recurring AI mistake — observed in production more than once: users already on the advertised tier were shown an upsell for it.) The "at cap → degrade" copy must name the user's actual next step (manage plan / higher tier), never their current tier. |
| New routes added or auth middleware changed | Route auth audit hook fires automatically. Verify no unauthenticated route added to authenticated resource. |
| User/tenant model queries in controllers | Scope guard hook fires automatically. Confirm multi-tenant scoping is preserved; unscoped queries are a data leakage risk. |
| Data deletion (drop, truncate, cascade delete) | Database destruction guard hook blocks. Explicit user confirmation required before proceeding. |
| `.env`, secrets, credentials | `.env*` files are allowed to contain secrets and may be committed per project policy. For non-env files, detection hook fires — never write secrets to application code, configs, or docs. |
| CI/CD files changed (.github/workflows, Dockerfile, deploy scripts) | CI/CD tamper guard hook blocks. Require explicit user authorization. |
| SoftDeletes removed, PII logged, forceDelete on User | Privacy compliance hook fires. Confirm intent; document in CHANGELOG. |
| MCP tools that write files, push code, or execute code (GitHub MCP, Playwright execute, etc.) | Never delegate unsafe operations to MCP tools or subagents. All git operations must use the Bash tool so safety hooks intercept them. Never invoke Agent-based subagents for file writes, git push, or database operations. |
| `console.log` / `Log::info` in diff touches env vars (`process.env.*`), request bodies (`$request->all()`), or auth tokens | Review all logging before committing. Log IDs and redacted values only — never raw env vars, full request payloads, or auth tokens. |
