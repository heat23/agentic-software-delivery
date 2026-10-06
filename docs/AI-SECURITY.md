# AI Security

[README](../README.md) · [Architecture](../ARCHITECTURE.md) · [Principles](PRINCIPLES.md)

This is the security write-up for the pipeline: what it assumes about the model, how the guardrails
protect themselves from the agent, how the controls map to the OWASP Top 10 for Agentic Applications
and the NIST AI RMF, and where they fall short. The guardrails themselves
are listed in the [README](../README.md#guardrails).

## Design stance and threat model

**Design stance:** treat the model as capable but fallible, and untrusted on completion claims. It
can be wrong, it can be steered by what it reads, and it will optimize for looking finished. So the
key controls run outside its reasoning, and evidence is checked before it's accepted.

| Element | Position |
|---|---|
| **Primary actor** | The agent itself: capable, sometimes wrong, steerable by content it reads, and biased toward declaring success. |
| **Assets** | Production data, git history, review integrity, spend, and the guardrails themselves. |
| **Trust boundary** | Hooks and validators run outside the model's reasoning, but as the same OS user. |
| **In scope** | An agent that cuts corners, makes mistakes, or is steered by content it reads. |
| **Out of scope** | A competent, deliberate adversary, whether the agent itself or someone planting instructions for it. |

## Guarding the guardrails

The most instructive incidents weren't bad code. They were ways the safety layer could be switched
off quietly, by the agent or by its own tools:
- **Self-persisted exemptions.** An early runner exemption was a bare environment flag that a session
  could write into its settings once, silently switching off the Stop gate for **every later
  session**. It now requires an **HMAC token bound to an hourly window**, so a persisted value stops
  working within about two hours ([`dispatched-runner.sh`](../hooks/lib/dispatched-runner.sh)).
- **Guardrails disabled by the agent's own tools.** The file-edit tool rewrote hook scripts without
  the executable bit, which silently disabled **a large share of the installed hooks**, including the
  database-destruction and force-push guards. A post-edit hook now restores hook permissions.
- **Unsigned fields beside a signature.** The witness signed the three reports, but the source-tree
  fields added later sat outside the signature. Deleting them switched off the check for code changed
  after review. A later review found it. The tree binding is now signed, and the end-to-end
  test proves that deleting, repointing or downgrading those fields each blocks. The adversarial
  review of that fix found one more: when the secret could not be created, the runner exemption
  fell back to a key built from the user ID and hostname, which anyone could compute. The fallback
  is gone, and a test proves a token forged that way is rejected.

Edits to the system's own tooling must carry test evidence: red against the pre-change code, green
after. A mutation gate proves the tests still catch the bugs they exist for.

## OWASP Top 10 for Agentic Applications (2026)

**Coverage (self-assessed):** 🟢 1 Strong · 🟡 7 Partial · 🔴 2 Gap. These ratings are my own reading of
the OWASP descriptions, not an external audit.

| Risk | Coverage | How |
|---|---|---|
| **ASI01** Agent Goal Hijack | 🟡 Partial | No injection detection is claimed. Out-of-model hooks gate destructive commands and completion, so a steered agent must still produce validated evidence. A deliberate bypass is not prevented. |
| **ASI02** Tool Misuse | 🟡 Partial | Command-text guards on destructive database and git operations, PR creation and dependency installs, plus a worktree write boundary. Tripwires, not a policy engine. |
| **ASI03** Identity & Privilege Abuse | 🟡 Partial | Gate runners have write tools denied. The two Stop-gate exemptions for runner-launched sessions (dispatched gate runners, and implementation-only sessions) require an HMAC token or a headless attestation; per-gate dial variables remain plain environment switches. |
| **ASI04** Agentic Supply Chain | 🟡 Partial | Dependency audits run as a gate, and new npm or composer packages need confirmation. Claude Code, its plugins and MCP servers, and the model are unpinned. |
| **ASI05** Unexpected Code Execution | 🔴 Gap | Agents run shell commands with the user's privileges by design, and pack sessions run with permission prompts bypassed. Pattern guards only; pair with OS- or container-level sandboxing. |
| **ASI06** Memory & Context Poisoning | 🔴 Gap | Agents keep persistent memory that isn't sanitized. A context-size guard exists, but nothing inspects memory content. |
| **ASI07** Insecure Inter-Agent Communication | 🟡 Partial | Agents communicate through artifacts, which are validated, cross-checked against the provenance log and, for the three gauntlet reports, hash-bound by attestation. The log itself is unsigned. |
| **ASI08** Cascading Failures | 🟢 Strong | A termination guarantee, retries only on timeouts or temporary failures, fast-fail on deterministic gate failures, capped QA rounds, and a merge-back that defers rather than overwrites. A wave that can't land on `main` blocks the waves after it. A wrong verdict that the builder and its reviewers share can still propagate. |
| **ASI09** Human-Agent Trust Exploitation | 🟡 Partial | Completion depends on validated artifacts, not on the agent's narrative. A warn-only truth gate flags narrow "nothing to do" claims; broader narrative claims are not checked. |
| **ASI10** Rogue Agents | 🟡 Partial | The guardrails defend against the self-disabling failures actually observed. A same-user agent determined to edit the hooks is not stopped. |

Two entries in the [OWASP Top 10 for LLM Applications (2025)](https://genai.owasp.org/resource/owasp-top-10-for-llm-applications-2025/)
overlap most with this table:
- **LLM06 Excessive Agency** maps to the ASI02 and ASI03 rows.
- **LLM10 Unbounded Consumption** is covered by model tiering, bounded retries, the termination
  guarantee and billed-cost telemetry. There is no hard spend cap.

<details>
<summary><b>NIST AI Risk Management Framework crosswalk</b></summary>

| Function | Here |
|---|---|
| **Govern** | Written operating principles, policy enforced as code, and a model-tier policy. |
| **Map** | Risk tiers from the diff, security-path heuristics, and an impact map of affected consumers. |
| **Measure** | Billed-cost telemetry, review yield, Stop-gate activity, and mutation testing of the tests. |
| **Manage** | Blocking gates, destructive-command tripwires, and the incident → guard → test loop. |

</details>

## Known limits

> [!WARNING]
> **Same-user threat model.** The agent runs as the same OS user as the hooks. It could read the
> attestation secret, forge the witness or provenance entries, or edit the hooks. The code says so
> ("bar-RAISING, not a cryptographic wall"). Pair it with OS- or container-level isolation.

- **Liveness over strict blocking.** After 2 identical blocks, or 4 in one chain, the Stop gate lets
  the session end without the evidence rather than deadlock, and logs the escape. An agent that keeps
  stopping without fixing the cause can therefore finish; the logged escape is what flags it.
  Operators can raise the limits, trading liveness back for strictness.
- **The Stop gate covers orchestrated sessions only.** A session that never ran `/v` exits the gate
  immediately; direct work is bound by the `PreToolUse` guards and by instruction.
- **Model-asserted exits.** Some exits rest partly on the session's word, and all are documented as
  such in the code: operational commit tags, handoff and merge-deferred markers, a retry-cap handoff
  that can't be verified, and the trivial-tier marker's line and path rules. Per-gate dial variables
  (environment variables that set individual checks to warn-only or off) are not authenticated.
- **Packs are trusted input.** The pack runner starts each headless session with
  `--permission-mode bypassPermissions`, and the final verify pack may declare a gate command that the
  runner evaluates in the repository. Anyone who can write a pack can run commands as the agent, so
  packs must come from the planning skills or a reviewed source, never from untrusted content.
- **Pattern-based guards.** The live guards match command text for specific tools. They catch
  accidents, not a determined or obfuscated attempt.
- **Process-level review independence.** Builder and reviewers share a model family unless the optional Codex CLI reviewer runs, which only 24
  of 358 reviews evidenced, and reviewers
  read untrusted diff content without injection hardening. The refute-and-majority step is protocol,
  not hook-verified.
- **Not implemented:** network egress control, a dedicated secret scanner, sandboxing, a hard spend
  cap, and sanitization of persistent agent memory. The convention check only pattern-matches four
  common key formats (`sk_live_`, `AKIA`, `ghp_` and bearer tokens) in changed files.
- **Evidence base.** All measurements come from one operator's workload.
