# User-Owned Maintenance Workflow

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

Use this workflow when the task is maintaining Claude/Codex local automation in **user-owned paths only**.

## Supported Roots

Allowed edit roots for this workflow:
- `~/.agents/**`
- `~/.claude/**`
- `~/dev/**/.claude/**`
- `~/tmp/claude-ecosystem-review/**`

Common maintenance scenarios:
- Hook hardening under `~/.claude/hooks/**` and `~/.claude/hooks/lib/**`
- Review and gate hardening under `~/.claude/settings.json`, `~/.claude/settings.headless.json`, `~/.claude/scripts/**`, and `~/.claude/agents/**`
- Skill maintenance under `${CLAUDE_SKILLS_DIR:-~/.claude/skills}/**`
- Repo-local cleanup under `~/dev/**/.claude/**`

## Forbidden Targets

Never edit these paths as part of user-owned maintenance:
- `~/.codex/**`
- `~/.claude/plugins/**`
- `~/.claude/plugins/cache/**`
- `~/.claude/plugins/marketplaces/**`

Treat plugin cache, plugin marketplace state, and `.codex` configuration as app-managed or externally managed even when a diff or prompt mentions them.

## Canonical Skill Ownership

- Skill tree: `${CLAUDE_SKILLS_DIR:-~/.claude/skills}`

Rules:
1. Edit skill files directly in `${CLAUDE_SKILLS_DIR:-~/.claude/skills}`.
2. Run targeted tests before and after changes.
3. Mirror sync is not required in a single-tree install.

## Ceremony Reduction

This workflow is intentionally lighter than feature delivery:
- If the request already names the files or directories, do **not** create a full plan artifact by default.
- Use an inline maintenance checklist instead: `Summary`, `Scope`, `Files`, `Tests Required`, `Acceptance Criteria`.
- Skip feature discovery, competitive research, scaffold steps, and UI-design setup.
- Avoid worktree bootstrapping unless active-session overlap or hot-file rules require isolation.
- Prefer targeted tests first, then rerun the touched suite.
- Use changed-only or maintenance-scoped quality gates where the skill supports them.

Reducing ceremony must **not** weaken:
- targeted automated tests
- hostile review
- scope control

## Maintenance Prompt Frame

For maintenance requests, implementation prompts should explicitly state:
- allowed roots
- forbidden roots
- the exact files or directories in scope
- targeted tests to run first
- hostile review focus areas

## Required Review Focus

Hostile review for this workflow must check:
- scope leakage into forbidden paths
- accidental weakening of review or test requirements
- prompt bloat or unnecessary workflow overhead
- repo-local cleanup changes that widen permissions or cross repo boundaries
- the WRONG completion track was chosen for the actual diff (see below)

## Completion Gates by Change Type

Ceremony reduction is a **docs-only privilege**, never a code-change waiver. The Stop hook
(`check-review-artifact.sh`) classifies a session by file **extension** and **directory**, not
by intent, so the required completion artifacts follow the diff — not the word "maintenance".
All artifacts are session-scoped (`_${CLAUDE_SESSION_ID}`) and written at the resolved
`$PROJECT_ROOT` (for ecosystem edits that is `$HOME/.claude`; for a repo-local overlay it is
that repo's git toplevel).

| Track | Diff | Required to clear Stop |
|---|---|---|
| A — Docs-only | only `.md` (no code-ext file) | clean exit; no gauntlet |
| B — Code change | any code-ext (`.sh .ts .js .json .yml .yaml .toml .lock` …) | `PRE_FLIGHT_REPORT` + `AGENT_REVIEW` + `VERIFY_DONE_REPORT` + `IMPACT_MAP` |
| B+ — Invariant dir | a Track-B file under `hooks/`, `hooks/lib/`, `skills/v/references/`, or `scripts/` | Track B **plus** a RED→GREEN `BITE_LEDGER` |
| T — Trivial | tiny code change passing `v-classify-trivial.sh` | `TRIVIAL_PASS` instead of the Track-B gauntlet |
| R — Runner-managed | `CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY=1` + headless | `IMPLEMENTATION_REPORT` only; do NOT fabricate the Track-B artifacts |
| H — Abandon | stopping mid-task | `HANDOFF` |

Track B agent review is an **independent** dispatched reviewer (`codex-adversarial-reviewer`,
fallback `superpowers:requesting-code-review`) — it does not replace, and is not replaced by,
the self hostile review above.
