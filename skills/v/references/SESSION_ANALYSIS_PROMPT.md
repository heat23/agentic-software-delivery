# /v Session Analysis — Reusable Prompt

Copy everything in the fenced block below into a fresh Claude Code session (run it from
the repo where the `/v` session(s) executed, so the git tree and `.v/artifacts` are reachable).
Paste your terminal transcript where indicated. Append other reviewers' findings if you have them.

---

```
Do a multi-faceted analysis of the /v orchestration session(s) below. Treat this as a
forensic post-mortem of MY skill, not a code review of the product diff.

GROUND-TRUTH FIRST (do this before forming any opinion):
The terminal paste and the session-log narration are SUSPECT — they are what I'm auditing.
Reconstruct what actually happened from unforgeable sources, reading them DIRECTLY:
  - git reflog + `git log --all --oneline` + `git cat-file -e <sha>` for every sha the
    session claims (base_sha, end_sha) — verify they exist and are reachable, not hallucinated.
  - The session-log YAML for each SID (commits_added, files_changed, base/end_sha, duration,
    generated_at vs end_time ordering, token_cost, model).
  - `.v/artifacts/` for that session: PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT,
    QA/UX/WORKFLOW reports, DISPATCH_PROVENANCE_*.log, witness/attest markers, *.output.
  - The live validators: run `validate-log.py` (and v-completion-selfcheck / contract-audit)
    against the actual logs — does it PASS something it shouldn't?
  - The session transcript tree itself (<sid>.jsonl and <sid>/subagents/*) for real token
    counts (output AND cache-read), real wall-clock span (min..max .timestamp), and whether
    gates were DISPATCHED as independent subagents vs hand-authored inline.
When narration and ground truth disagree, ground truth wins — and the disagreement is itself
a P0 finding (the telemetry is untrustworthy).

ANALYZE THESE FACETS:
1. FLOW / orchestration — correct routing, no stranded gates (background-dispatch then passive),
   no redundant work (e.g. pre-flight run twice with no rerun-after-fix justification), correct
   worktree lifecycle, correct merge-back + re-verify.
2. CORRECTNESS — did the shipped code actually do what the prompt asked? Trace it against the
   real diff. Were the gates real (independent dispatch) or degraded/forged (codex EOF fallback
   labeled APPROVED, hand-written PRE_FLIGHT, skip-as-pass)?
3. EFFICIENCY / COST — measure the RIGHT lever. Output tokens are noise; cache-read is the
   billing driver and the Opus orchestrator context is ~99% of spend. Flag wall-clock wasted
   on serial-where-parallel, full-suite-where-scoped, redundant gates.
4. TELEMETRY FIDELITY — session-log provenance: impossible timestamps, commits_added:0 despite
   real commits, base_sha==end_sha, inflated/zero duration, inline-vs-worktree misreport,
   wrong-model banner, a sibling session's work logged under this SID.

FOR EACH FINDING report:
  - Severity: P0/CRITICAL | HIGH | MEDIUM | LOW
  - Evidence: the exact ground-truth artifact + line/value that proves it (not narration)
  - Root cause + the CLASS of bug (so the fix kills the class, not the instance)
  - Concrete fix (which file/script/contract), and whether it gates implementation

IF I PASTE OTHER REVIEWERS' FINDINGS: reconcile all of them against the ground truth you read
directly. Return one unified ACCEPTED / REJECTED list with per-item rationale and risk/reward —
don't defer to any reviewer (including a prior me) over the artifacts.

THEN ACT (per my CLAUDE.md — autonomous, no permission-gate):
Fix every accepted CRITICAL/HIGH end-to-end. Add a regression test that catches the CLASS
(template≡validator round-trip / regex corpus / cross-contract invariant). Keep the whole
harness green. Adversarially review your own fix diff. Do NOT end with "want me to fix this?".
Only pause for the hard stop-list (destructive ops, security trade-offs, genuine ambiguity).

=== SESSION TRANSCRIPT(S) ===
[paste your /v terminal output here — include the banner so model/version/effort is captured]

=== OTHER REVIEWERS (optional) ===
[paste any external AI findings here, or delete this section]
```

---

## Why this prompt is shaped this way

Derived from a production post-mortem session (and the W-perf post-mortem series). The failures
you keep finding are almost never in the product diff — they're in **telemetry that lies** and
**gates that degrade silently**. So the prompt's load-bearing move is *read the unforgeable
sources first, treat the paste as the thing under audit*. Every recurring class is a known failure mode:
provenance fabrication (W-perf10/11), stranded background gates (W-perf9), log inversion
(W-perf9b), forged independence (W71/W-perf-runner), wrong cost lever (cache-read vs output).
