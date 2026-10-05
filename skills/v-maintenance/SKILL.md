---
name: v-maintenance
description: "Use when maintaining or repairing Claude config, hooks, settings, installed skills, or repo-local overlays."
model: sonnet
context: fork
allowed-tools: Read, Write, Edit, Bash, Glob, Grep, AskUserQuestion
user-invocable: true
disable-model-invocation: true
---
<!-- skill: v-maintenance | version: 1.3.3 | last-updated: 2026-08-12 -->
<!-- 1.3.2 (2026-08-03): added a reciprocal "Use instead" pointer to /v-setup-project — that
     skill already routed global ~/.claude/ edits here (SKILL.md:60,66) but this file never
     mentioned it back, so bootstrapping a NEW project's repo-local .claude/ assets had no
     redirect out of this skill's description-collision surface (hooks/settings/skills). -->
<!-- 1.3.1 (2026-08-02): added an explicit "Not for" boundary redirecting product-own
     dependency/security-patch/deploy upkeep to /v, /v-audit-code, and /v-next — this skill's
     name invites that request but its fence has always been ~/.claude meta-tooling only. -->


# 2026 Canonical Contract

Tier: User-facing entry point.

This contract overrides older sections below on conflict.

Follow `_v-core.md` (V_DEPTH parsing, PROJECT_ROOT + SID resolution), `_v-exec.md` (shell/edit safety), and `_v-review.md` (§ Agent Dispatch Protocol — the code-change gauntlet depends on it).

For path rules and ceremony reduction, read `~/.claude/skills/references/v-core-maintenance.md`.
For changed-file detection, read `~/.claude/skills/references/v-core-changed-files.md`.
For hook inventory and live enforcement vocabulary, read `~/.claude/skills/references/v-exec-hooks.md`.

Rules:
- operate only in the allowed roots from `~/.claude/skills/references/v-core-maintenance.md`
- never edit plugin, cache, marketplace, or `.codex` paths
- canonical skill edits happen in `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}` directly
- prefer an inline maintenance checklist over a PLAN artifact when the scope is already explicit
- run targeted tests first, then rerun the touched suite
- preserve hostile review and final verification; lower ceremony is not a waiver
- **the Stop hook gates on WHAT changed, not on "this is maintenance"** — pick the completion track from § Completion Gates by Change Type; lower ceremony is a *docs-only* privilege, never a code-change waiver

## Execution Context (read first)

Parse the invocation context before any edit, per `_v-core.md`:

- **V_DEPTH** — search the invocation prompt for `[V_DEPTH=N`, then bare `V_DEPTH=N`; default `0` (direct user invocation). `V_DEPTH >= 1` means `/v` invoked this skill and owns the entry-point question AND the post-change gauntlet (`/v-pre-flight`, agent review, `/v-verify-done`).
- **CLAUDE_SESSION_ID** — resolve via the canonical cascade, never synthesize: `$CLAUDE_SESSION_ID` env → `$CLAUDE_CODE_SESSION_ID` env → the persisted `~/.claude/runtime/current-session-id` file (`SID="${CLAUDE_SESSION_ID:-$(cat ~/.claude/runtime/current-session-id 2>/dev/null | tr -d '[:space:]')}"`). Bash state does not persist between tool calls — re-derive `SID` at the top of every Bash block that names an artifact. Every artifact this skill writes carries `_${SID}` so concurrent sessions never clobber each other.
- **PROJECT_ROOT (artifact root)** — where the Stop hook (`check-review-artifact.sh`) looks for this session's completion artifacts. Resolve per `_v-core.md § Project Root Detection`: invocation-prompt `PROJECT_ROOT=` → `git rev-parse --show-toplevel` from the tree that holds the files you are editing → **stop and ask; NEVER fall back to bare `pwd`** (under `context: fork`, `pwd` is the Claude session dir, not the repo). Concretely:
  - **Ecosystem maintenance** (editing `~/.claude/**` or `~/.agents/**`) → `PROJECT_ROOT="$HOME/.claude"`.
  - **Repo-local overlay** (editing `~/dev/<repo>/.claude/**`) → `PROJECT_ROOT` = that repo's `git rev-parse --show-toplevel`.
  Write PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT, IMPACT_MAP, BITE_LEDGER, IMPLEMENTATION_REPORT, and any HANDOFF under `$PROJECT_ROOT/.v/artifacts/` (Phase-2 — create the dir; the hook + Stop gate dual-search `$PROJECT_ROOT` as a legacy fallback, and BITE_LEDGER additionally under `$HOME/.claude`).
- **Real timestamps only** — any `generated:`/dated field uses `date -u +%Y-%m-%dT%H:%M:%SZ` via Bash. NEVER fabricate a timestamp.

## Headless / Orchestrated Execution

When `V_DEPTH >= 1` or `HEADLESS_BATCH=1` is present in the invocation:
- skip all `AskUserQuestion` calls and infer the narrowest safe maintenance path from the prompt
- do not stop for a planning artifact when the scope is explicit
- keep the workflow inline and path-scoped; do not expand into repo-wide maintenance
- **treat `/v-pre-flight`, agent review, and `/v-verify-done` as caller-owned** — the orchestrator runs the gauntlet after this skill returns — UNLESS the prompt explicitly says to run them inside this session
- **Runner-managed (`CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1`):** write ONLY `IMPLEMENTATION_REPORT_${SID}.md`; do NOT run `git add`/`git commit`; do NOT fabricate PRE_FLIGHT_REPORT, AGENT_REVIEW, or VERIFY_DONE_REPORT (the external runner owns those). If UI files changed, add a `UX_CRITIQUE_DEFERRED=<orchestrator_sid>` line to the report.

```yaml
contract:
  tier: user-facing
  accepts: [raw maintenance prompt, explicit file paths]
  produces:
    # Which set is REQUIRED depends on WHAT changed — see § Completion Gates by Change Type.
    - IMPLEMENTATION_REPORT_${CLAUDE_SESSION_ID}.md   # runner-managed sessions
    - PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md        # any code-ext change (interactive, V_DEPTH==0)
    - AGENT_REVIEW_${CLAUDE_SESSION_ID}.md             # any code-ext change (interactive, V_DEPTH==0)
    - VERIFY_DONE_REPORT_${CLAUDE_SESSION_ID}.md       # any code-ext change (interactive, V_DEPTH==0)
    - IMPACT_MAP_${CLAUDE_SESSION_ID}.md               # any code-ext change
    - BITE_LEDGER_${CLAUDE_SESSION_ID}.md              # change under hooks/, hooks/lib/, skills/v/references/, scripts/
    - TRIVIAL_PASS_${CLAUDE_SESSION_ID}.md             # genuinely trivial code change (classified)
    - HANDOFF_${CLAUDE_SESSION_ID}.md                  # mid-task abandonment
  invokes: [/v-pre-flight, /v-verify-done]
  conditional-invokes:
    - codex-adversarial-reviewer (agent review on code-ext changes; superpowers:requesting-code-review fallback)
    - v-pre-flight-runner (fork-safe subprocess dispatch)
  invoked-by: [/v, user]
  estimated_tokens: 10k-30k
  estimated_duration: 2-8 min
```

# /v-maintenance - User-Owned Maintenance

Use this skill for narrow maintenance work on the local Claude/Codex setup when the task should stay inside user-owned paths and avoid plugin or app-managed state.

## Skill Boundaries

**SME persona:** This skill is run by a **senior maintenance engineer focused on scope discipline** — specialty is staying inside the user-owned maintenance fence (config tweaks, doc updates, dependency bumps within reason) without escalating into feature work, repo-wide refactors, or planning sessions that the operator did not ask for — while still clearing the exact completion gate the change earns.

### Best fit

- Explicit maintenance tasks in `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}`, `$HOME/.claude/hooks`, `$HOME/.claude/settings*.json`, `$HOME/.claude/scripts`, `$HOME/.claude/agents`, or repo-local `.claude` overlays
- Canonical-first skill maintenance
- Practical maintenance work that still needs targeted tests, agent review, and final verification without product-level ceremony

### Use instead

- Use `/v-plan` if the maintenance scope is ambiguous enough that a separate plan artifact is required
- Use `/v-help` for workflow guidance only
- Use `/v-check` when the task is a broad product audit rather than a user-owned maintenance pass
- Use `/v-skill-reviewer` when the task is to review/audit skills without editing them (it routes fixes back here)
- Use `/v-setup-project` when the task is bootstrapping a **new** project's repo-local `.claude/` assets (hooks, agents, settings, skills, stack-aware `CLAUDE.md` rules) from scratch, not maintaining/repairing an existing installation

### Not for

- Editing plugin, cache, marketplace, or `.codex` paths
- Expanding a small maintenance task into unnecessary repo-wide migration or sync work
- **A product repo's own upkeep** — despite the name, this skill's fence is
  `~/.claude`/`~/.agents`/repo-local `.claude` overlays ONLY, never the product repo's own
  dependency hygiene, security-patch cadence, or deploy rules. For that: run
  `composer audit` / `npm audit --audit-level=critical` in the PRODUCT repo on a routine
  cadence (§ Dependency Update Doctrine below is the maintenance-fence version of this same
  doctrine — apply the same sequence, just to the product's own manifests); route the actual
  product-code fix through `/v`, a broader dependency/security sweep through `/v-audit-code`,
  and let `/v-next` flag when that cadence has gone stale
  (`~/.claude/skills/v-next/references/signal-sources.md` § 6. Dependency & security-audit
  staleness and § 7. Legal-doc staleness). This skill does not silently absorb "update my
  app's dependencies" — redirect it.

## Best-Fit Scenarios

- Hardening custom hooks in `$HOME/.claude/hooks/**` or `$HOME/.claude/hooks/lib/**` (→ code-ext + invariant-dir → gauntlet + BITE_LEDGER)
- Tightening review and gating behavior in `$HOME/.claude/settings.json`, `$HOME/.claude/settings.headless.json`, `$HOME/.claude/scripts/**`, and `$HOME/.claude/agents/**`
- Maintaining canonical skill docs or tests in `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/**` (docs-only `.md` → light path; `__tests__/*.ts` → code-ext → gauntlet)
- Cleaning up repo-local overlays in repo-local `.claude` directories under your dev tree

## Entry Rule

If the request already includes explicit files or directories, do **not** stop for a planning artifact. Build an inline checklist with:
- `Summary`
- `Scope`
- `Files`
- `Tests Required`
- `Acceptance Criteria`

Only write a separate plan artifact when the maintenance work is ambiguous, phased, or crosses multiple domains with uncertain ordering. At `V_DEPTH == 0`, if the scope is genuinely ambiguous, ask ONE `AskUserQuestion` to confirm the file set before editing; never ask under `V_DEPTH >= 1`.

## Path Guardrails

Before editing anything:
1. Resolve every planned file path.
2. Confirm every path is allowed by `~/.claude/skills/references/v-core-maintenance.md`.
3. If any path lands in a forbidden root (`~/.codex/**`, `~/.claude/plugins/**`, `.../cache/**`, `.../marketplaces/**`), stop and report the blocked path instead of broadening scope.

## Canonical-First Skill Maintenance

When the task touches skill files:
1. Edit files in `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}` directly.
2. Update `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/__tests__/**` for any changed logic (this makes the session code-ext — see gates below).
3. Run targeted tests before and after the change.

## Scenario Guidance

### Hooks

For hook hardening under `$HOME/.claude/hooks/**`:
- align prose and tests to the live hook registration in `$HOME/.claude/settings.json` and `$HOME/.claude/settings.headless.json`
- keep fixes local to the touched hook, its helper in `hooks/lib`, and the tests that cover it
- prefer advisory maintenance prompts over destructive cleanup behavior unless the user explicitly asks for deletion or removal
- **this is an invariant-dir + code-ext change** → the RED→GREEN BITE_LEDGER is mandatory (§ Completion Gates)

### Review / Gating

For review and gating hardening under settings, hooks, scripts, or agents:
- align headless behavior with `hooks/lib/headless-detect.sh`
- keep semantic review requirements intact
- treat weakened review gates, presence-only checks, or broadened bypasses as hostile-review targets

### Canonical Skills

For canonical skill maintenance under `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/**`:
- keep instructions concrete and path-scoped
- remove references that would cause edits in forbidden roots
- keep prompts practical: exact paths, exact tests, exact review focus

### Repo-Local Overlays

For repo-local `.claude/**` overlay cleanup:
- stay inside the target repo's `.claude` directory
- avoid cross-repo `additionalDirectories`
- narrow wildcard permissions when possible without breaking the repo's stated workflow

### Dependencies

For dependency bumps within the maintenance fence (e.g. the skills test harness
`package.json`/`package-lock.json` under `${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}`,
a repo-local overlay's `composer.json`/`package.json`, or a devDependency used by a
hook/script): follow the **Dependency Update Doctrine** below. A lockfile change is a
code-ext change (Track B) — it clears the same gauntlet as any other code edit.

## Dependency Update Doctrine

Dependency maintenance is a first-class maintenance task, but it is NOT "bump everything
to latest." Follow this sequence; never blind-bump.

**1. Inventory before touching anything.**
```bash
# PHP
composer outdated --direct 2>/dev/null            # direct deps only — ignore transitive noise
# JS
npm outdated 2>/dev/null                            # current vs wanted vs latest
```

**2. Security first — audit gates are non-negotiable.** A known-vulnerable dependency is
fixed even if the bump is a major:
```bash
composer audit                                      # PHP advisories
npm audit --audit-level=critical                    # JS — CRITICAL is the block threshold
```
Any CRITICAL/HIGH advisory → update that package to the first patched version regardless of
the patch/minor/major classification below. Security overrides the auto/gated split.

**3. Update strategy by semver delta.**

| Delta | Policy | Action |
|---|---|---|
| **patch** (`x.y.Z`) | auto | Apply within the wanted range; lockfile-only change. Run targeted tests. |
| **minor** (`x.Y.z`) | auto (SemVer-honest ecosystems) | Apply, read the changelog for the specific packages you touched, run the touched suite. |
| **major** (`X.y.z`) | **gated** | Do NOT auto-apply. One major per session, read the UPGRADE/CHANGELOG, plan the code changes, treat as a Track-B change with full gauntlet + agent review. At `V_DEPTH == 0` with genuine ambiguity, ask ONE `AskUserQuestion` before a major bump; never ask under `V_DEPTH >= 1`. |

Framework majors (Laravel, Tailwind, etc.) are always gated and usually warrant their own
session, not a drive-by bump — see the framework-version notes in the operator CLAUDE.md.

**4. Lockfile discipline.**
- Commit the lockfile (`composer.lock` / `package-lock.json`) in the SAME change as the
  manifest edit — never a manifest bump without its regenerated lock.
- Use the CI-equivalent install (`composer install` / `npm ci`), not `composer update` /
  `npm install`, to VERIFY the locked graph resolves before finishing.
- Never hand-edit a lockfile. Regenerate it with the package manager.
- One coherent bump set per commit so a regression bisects cleanly.

**5. Two-phase for breaking dependency changes.** When a dependency removes or renames an
API the codebase still calls, mirror the DB two-phase rule: first land the code that stops
using the old API (against the pinned old version), then bump the dependency in a second
change. Do not bump-and-break in one shot.

**6. Verify.** Run the touched suite (§ Testing Flow), then the change-type gate
(§ Completion Gates by Change Type — a lockfile edit is Track B). A major bump additionally
takes agent review with adversarial focus on the changed call sites.

## Testing Flow

Run the narrowest useful checks first:

```bash
# Skill tests (targeted files only during iteration — never the full suite mid-fix)
npm -C "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" test -- [targeted test files]

# Rerun the touched suite after fixes
npm -C "${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}" test -- [touched suite]
```

Then satisfy the completion gate for the change track below. Do not jump straight to a full product-style gate run when the change set is confined to user-owned maintenance roots.

## Completion Gates by Change Type

The Stop hook (`check-review-artifact.sh`) classifies the session by file **extension** and **directory**, not by intent. Pick the track that matches your diff. All artifacts are session-scoped (`_${SID}`) and written at `$PROJECT_ROOT`.

| Track | What you changed | Required to clear Stop |
|---|---|---|
| **A — Docs-only** | Only `.md` (SKILL.md, `references/*.md`) — no code-ext file | Nothing beyond a clean exit. No gauntlet. This is the light path. |
| **B — Code change** | Any code-ext file: `.sh .bash .zsh .ts .tsx .js .mjs .cjs .json .yml .yaml .toml .lock`, etc. | `PRE_FLIGHT_REPORT` + `AGENT_REVIEW` + `VERIFY_DONE_REPORT` + `IMPACT_MAP` |
| **B+ — Invariant dir** | A Track-B file also under `hooks/`, `hooks/lib/`, `skills/v/references/`, or `scripts/` | Track B **plus** `BITE_LEDGER` (RED→GREEN proof) |
| **T — Trivial** | A tiny code change that passes `v-classify-trivial.sh` | `TRIVIAL_PASS` instead of the Track-B gauntlet |
| **R — Runner-managed** | `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` + headless | `IMPLEMENTATION_REPORT` only — do NOT fabricate the Track-B artifacts |
| **H — Abandon** | Stopping mid-task | `HANDOFF` (documents WIP; not a gauntlet skip for completed work) |

**Track B — code change (interactive, `V_DEPTH == 0`, not runner-managed).** This skill is `context: fork`, so dispatch reviewers via the subprocess helper, never the Agent/Skill tool:

1. **Impact map** — write `IMPACT_MAP_${SID}.md` per `~/.claude/skills/v/references/v-impact-analysis.md`, enumerating every connected subsystem as impacted yes/no. For ecosystem edits the honest answer is usually a short all-`no`-with-reason list (a hook change may impact: other sessions' gating, headless parity, the test suite).
2. **Pre-flight** — emit the prompt with `~/.claude/skills/v/references/v-emit-prompt.sh`, then run `~/.claude/skills/v/references/v-dispatch-subagent.sh --agent v-pre-flight-runner --prompt-file <emitted> --mode capture --artifact "$PROJECT_ROOT/PRE_FLIGHT_REPORT_${SID}.md"` (maintenance/changed-only scope; the haiku runner executes independently despite `context: fork`). `--prompt-file` is required — the helper exits 2 without it.
3. **Agent review** — dispatch `codex-adversarial-reviewer` (fallback `superpowers:requesting-code-review`) per `_v-review.md § Agent Dispatch Protocol`, via `v-dispatch-subagent.sh --agent codex-adversarial-reviewer`. Do NOT pass `--model haiku`: code review runs on **sonnet** (operator policy, 2026-08-06), and `--agent` dispatch is governed by the agent's own `sonnet` frontmatter pin. Note this is a `context: fork` subprocess, so the Agent-tool review-floor hook cannot see it — the frontmatter pin is the only safety net, so never resync it to haiku. The `AGENT_REVIEW_${SID}.md` MUST start with a `Model: <haiku|sonnet|opus>` line and contain a `## Findings` section (the validator rejects the YAML-block form). Fix all CRITICAL/HIGH before finishing. This is an **independent** reviewer — it does NOT replace, and is not replaced by, the self hostile-review below.
4. **Verify-done** — run `/v-verify-done` (or dispatch `v-verify-done-runner`) → `VERIFY_DONE_REPORT_${SID}.md`.

**Track B+ — BITE_LEDGER.** Editing `hooks/`, `hooks/lib/`, `skills/v/references/`, or `scripts/` requires proving the guarding test failed before the fix and passes after:
```bash
bash ~/.claude/skills/v/references/v-bite-ledger.sh \
  --invariant <changed-file> --harness <test-script> \
  --red-exit <N> --green-exit 0 --note "<what the bite proves>"
```
`touch`ing or hand-forging the ledger is content-validated and will still block. Write real RED/GREEN exit codes.

**Track T — trivial bypass.** Classify with `bash ~/.claude/skills/v/references/v-classify-trivial.sh`; if it qualifies, write `TRIVIAL_PASS_${SID}.md` instead of the Track-B gauntlet. Do not self-declare trivial — let the classifier decide.

## Hostile Review

On every change track, before invoking the independent agent review, self-review the changed files:
1. Did any edit escape the allowed roots?
2. Did anything touch `.codex`, plugin cache, marketplace, or other app-managed state?
3. Did any prompt text add unnecessary complexity or ceremony back into the maintenance path?
4. Did the lighter workflow accidentally weaken testing, review, or verification requirements?
5. Did you pick the WRONG completion track (e.g. skipped BITE_LEDGER on a hook edit, or ran Track A on a `.ts`/`.json` change)?

Fix all critical and high issues before finishing. If medium issues remain, list them explicitly with rationale.

## Completion

Before claiming done:
1. Targeted tests passed; touched suites were rerun.
2. The correct completion track (§ Completion Gates by Change Type) was identified from the actual diff and its required artifacts exist at `$PROJECT_ROOT`, session-scoped.
3. Self hostile review is complete AND (Track B/B+) the independent `AGENT_REVIEW_${SID}.md` is present and semantically complete.
4. `/v-verify-done` has been run when the track requires it.
5. No forbidden-root path was touched; no completion track was downgraded to skip a gate.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | Maintenance request expanded into feature work | Scope fence not honored | Maintenance scope: hooks, settings, skills, repo-local .claude overlays. Anything outside = STOP, recommend appropriate skill |
| 2 | Hook script edited but settings.json `hooks` field not updated | Edit-without-config-update | Hooks have config layer + script layer; both update together OR hook is unreachable |
| 3 | "Repair my .claude folder" deletes user's customizations | No backup before destructive change | Before any rm/replace: copy existing file to `.bak.$(date +%s)`; restore on regret |
| 4 | Skill update breaks downstream skill that referenced old API | Cross-skill dependency check skipped | Before changing a shared reference (anything in `~/.claude/skills/references/`), grep for callers |
| 5 | Maintenance run bypasses pre-flight gates | "Maintenance is small, skip gates" | Pre-flight applies to ALL code-ext changes including maintenance; the Stop hook keys on file type, not intent |
| 6 | Hook/script edit hard-blocks at Stop for "missing BITE_LEDGER" | Flagship invariant-dir change treated as low-ceremony | Any change under `hooks/`, `hooks/lib/`, `skills/v/references/`, `scripts/` needs a RED→GREEN `BITE_LEDGER_${SID}.md` (Track B+) |
| 7 | Session blocks for missing AGENT_REVIEW after a "done" self-review | Self hostile review ≠ independent agent review | Track B code changes need a dispatched `AGENT_REVIEW_${SID}.md` (`Model:` + `## Findings`), separate from the self hostile review |
| 8 | IMPLEMENTATION_REPORT written but session still blocks | IMPLEMENTATION_REPORT-only is honored ONLY under `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` + headless | Interactive sessions use Track A/B/B+/T, not the runner-managed report |
| 9 | Artifact written but hook can't find it | `context: fork` `pwd` is the session dir, not the repo | Resolve `$PROJECT_ROOT` (§ Execution Context) and write every artifact there; never rely on `pwd` |

## Idempotency

**Idempotent for the maintenance request.** Re-running on the same request is a no-op if already applied. Mutates only files within the maintenance scope fence. Completion artifacts are SID-scoped, so a re-run or a concurrent session never clobbers another session's gauntlet evidence.
