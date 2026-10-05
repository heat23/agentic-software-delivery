# Hook Enforcement Layer (extracted from _v-exec.md)

_Last reviewed: 2026-08-03 (registration audit: this table was documenting 13 hooks as live that are
registered in NEITHER settings file. Verified mechanically against `settings.json` +
`settings.headless.json`, not by reading the table. Prior stamp 2026-07-05 "ecosystem review sweep" —
that pass reviewed this file's PROSE without ever cross-checking it against the settings files, which
is exactly how a doc comes to assert enforcement that does not exist)._

The worktree safety rules above are enforced by Claude Code hooks in `~/.claude/hooks/`.

> ## ⚠️ READ THIS BEFORE TRUSTING THE TABLE BELOW
>
> **A hook file existing in `~/.claude/hooks/` does NOT mean it runs.** A hook runs only if it is
> registered in `settings.json` (interactive) and/or `settings.headless.json` (headless/fleet).
> As of the 2026-08-03 audit, **13 of the hooks described in this table are registered in NEITHER
> file.** They exist on disk, they pass `bash -n`, and they never execute. Do not rely on them, and
> do not assume the protection they describe is in place:
>
> `check-worktree-preconditions.sh` · `completion-summary.sh` · `detect-branch-drift.sh` ·
> `enforce-scope-guard.sh` · `lint-on-edit.sh` ·
> `migration-down-method-check.sh` · `session-audit.sh` · `session-env-check.sh` ·
> `todo-fixme-guard.sh` · `typecheck-on-edit.sh` · `worktree-create.sh` · `worktree-lifecycle.sh`
>
> Three of those describe enforcement CLAUDE.md treats as mandatory, so their absence is
> load-bearing, not cosmetic: TODO/FIXME/HACK blocking
> (`todo-fixme-guard.sh`), migration `down()` safety (`migration-down-method-check.sh`), and
> `git worktree add` preconditions (`check-worktree-preconditions.sh`). Until they are re-registered
> or formally retired, **treat those three rules as unenforced by machinery and enforce them by hand.**
>
> **`detect-secrets.sh` and `detect-secrets-in-write.sh` are FORMALLY RETIRED (2026-08-03, owner
> request — no secret-leak scanning, `.env*` secrets are policy-allowed).** Both moved to
> `~/.claude/hooks/.attic/*.disabled-2026-08-03`; `detect-secrets-in-write.sh`'s `settings.json`
> registration was removed; `/v-setup-project` no longer creates or registers either for new
> projects. Do not re-add without an explicit owner request.
>
> **Registered, but interactive-only** (absent from `settings.headless.json`, so dark in fleet/pack
> mode): `artifact-location-check.sh`, `check-session-branch.sh`, `enforce-agent-review.sh`,
> `enforce-haiku-dispatch.sh`, `pre-compact-worktree.sh`, `worktree-remove.sh`.
> **Registered in both:** `check-review-artifact.sh`, `enforce-pre-commit-gates.sh`,
> `uncommitted-changes-gate.sh`, `worktree-safety.sh`.
>
> **Re-derive this rather than trusting the prose — the prose is what drifted:**
> ```bash
> cd ~/.claude
> grep -oE '~/\.claude/hooks/[a-z0-9-]+\.sh' settings.json settings.headless.json \
>   | sed 's|.*/||' | sort -u > /tmp/live.txt
> grep -oE '`[a-z0-9-]+\.sh' skills/references/v-exec-hooks.md | tr -d '`' | sort -u > /tmp/doc.txt
> comm -23 /tmp/doc.txt /tmp/live.txt   # documented here but NOT registered => must be re-flagged above
> ```
> Run that whenever this file is edited. A row in the table is a DESCRIPTION of a script's intent;
> only the settings files decide whether it fires.

| Hook | Type | Version | What it enforces |
|------|------|---------|-----------------|
| `session-env-check.sh` | SessionStart | 2.0.0 | Validates environment, injects `additionalContext` with active worktree info into Claude's context |
| `check-session-branch.sh` | SessionStart | 1.0.0 | Warns if session starts on non-main branch (worktrees would inherit wrong base). Uses `CLAUDE_MAIN_BRANCH` / `CLAUDE_ALLOW_NON_MAIN` env vars. Non-blocking (exit 0 + additionalContext). |
| `worktree-safety.sh` | PreToolUse (Bash) | 1.5.0 | `git stash` ban, branch-switch ban (blocks ALL of: `git checkout <branch>`, `git checkout -b`, `git switch <branch>`, `git switch -c` — **`-b`/`-B`/`-c`/`-C` flags are NOT exempt**; **Branch creation is safe only via `git worktree add -b`**), `git gc/prune/repack` ban, **destructive ops ban** (`git reset --hard`, `git checkout -- .`, `git clean -f`), session-aware locked worktree removal. Uses `exit 2` + stderr for blocking. |
| `check-worktree-preconditions.sh` | PreToolUse (Bash) | 1.0.0 | Blocks `git worktree add` off non-main branch (exit 2). Warns on uncommitted changes and stale worktrees. |
| `enforce-pre-commit-gates.sh` | PreToolUse (Bash) | 4.0.0 | Blocks `git commit` for staged code unless this session already has a passing `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` and a semantically completed `AGENT_REVIEW_${CLAUDE_SESSION_ID}.md`. Headless sessions still go through the same artifact gate checks; `wip:` commit messages are **not** exempt. |
| `enforce-haiku-dispatch.sh` | PreToolUse (Skill\|Agent) | 3.0.0 | Enforces the haiku-only dispatch path for designated skills. Blocks direct Skill-tool runs for `v-pre-flight`, `v-verify-done`, and `v-handoff`, and auto-corrects Agent-tool dispatches to `model: "haiku"` via `updatedInput`. |
| `artifact-location-check.sh` | PostToolUse (Write, async) | 1.3.0 | Detects session artifacts written inside worktrees (would be lost on cleanup). Runs async — does not block tool execution. |
| `lint-on-edit.sh` | PostToolUse (Write+Edit) | 1.0.0 | Runs `eslint --max-warnings=0` on TS/TSX files after edits. Gracefully skips projects without ESLint config. |
| `worktree-lifecycle.sh` | PostToolUse (Bash, async) | 1.3.0 | Fallback lock creation for manual `git worktree add` (skips if WorktreeCreate hook already fired), checks for stray artifacts on `git worktree remove`. Runs async. |
| `detect-branch-drift.sh` | PostToolUse (Bash, async) | 1.0.0 | Records expected branch at session start; warns if branch changes mid-session. Uses `CLAUDE_MAIN_BRANCH` / `CLAUDE_ALLOW_NON_MAIN` env vars. |
| `enforce-scope-guard.sh` | PostToolUse (Bash, async) | 1.0.0 | Counts changed files after each Bash command. Warns when count reaches Medium (>=4 files) or Large (>10 files) thresholds without worktree isolation. Matches canonical scope: Small=1–3, Medium=4–10, Large=10+. One-shot per session. |
| `session-audit.sh` | PostToolUse (Write+Edit+Bash, async) | 1.0.0 | Consolidated observability hook. Replaces separate bash-command, file-change, and critical-path trackers with async audit logs under `~/.claude/audit-log/` and skips subagent contexts. |
| `enforce-agent-review.sh` | UserPromptSubmit (async) | 1.0.0 | Injects one-shot reminder when `/v` or `/v-build` is invoked that adversarial review is mandatory and Superpower Review is the fallback. |
| `check-review-artifact.sh` | Stop | 6.0.0 | Blocks session completion when this session's required artifacts are missing or semantically invalid. Checks session-scoped `PRE_FLIGHT_REPORT`, `AGENT_REVIEW`, and `VERIFY_DONE_REPORT`; validates review status/evidence markers; and requires all three artifacts even in trusted headless mode. |
| `uncommitted-changes-gate.sh` | Stop | 3.0.0 | Blocks completion when this session leaves unstaged tracked changes behind. Pre-existing dirty files are warnings only; session-introduced tracked changes block until committed or cleaned up. |
| `todo-fixme-guard.sh` | Stop | 1.x | Blocks completion when delivered code still contains TODO/FIXME/HACK markers. |
| `migration-down-method-check.sh` | Stop | 1.x | Blocks completion when new migrations omit a safe `down()` path. |
| `completion-summary.sh` | Stop (async) | 1.x | Advisory-only completion digest. It does not gate completion and must not be described as blocking. |
| `worktree-create.sh` | WorktreeCreate | 1.5.0 | Primary lock creator — auto-creates `.claude-session-lock` when Claude Code creates a worktree, then provisions common worktree runtime needs such as `.env` copy and Laravel storage directories. |
| `worktree-remove.sh` | WorktreeRemove | 1.3.0 | Native lifecycle hook — checks for stray artifacts and lock ownership before Claude Code removes a worktree. Uses `exit 2` to block removal of another session's worktree. Guards against corrupted lock files. |
| `pre-compact-worktree.sh` | PreCompact | 1.3.0 | Preserves active worktree state (paths, branches, lock status) in `additionalContext` before context compaction, so Claude retains worktree awareness across compaction boundaries. |

Worktree-specific hooks (worktree-safety, worktree-lifecycle, check-worktree-preconditions, detect-branch-drift) are context-aware: their safety blocks only activate when worktrees are active (`git worktree list` shows >1 entry). Always-on guards (protect-main-branch, dependency-install-guard, etc.) fire regardless of worktree state. Most hooks fail open if `jq` is missing, but critical completion enforcement such as `check-review-artifact.sh` fails closed and blocks until required parsing support exists.

**Blocking pattern:** PreToolUse hooks use `exit 0` with `hookSpecificOutput` JSON on stdout containing `permissionDecision: "deny"` — Claude Code parses stdout on exit 0 and blocks the tool programmatically. PostToolUse hooks also use `exit 0` with `additionalContext` on stdout for Claude to receive as injected context. Stop and WorktreeRemove hooks use `exit 2` with JSON on **stderr** (`>&2`) to block session completion or worktree removal — Claude Code reads stderr on exit 2 as error text. Set `hookEventName` to match the hook's actual event type. The `permissionDecision` field is only meaningful for PreToolUse hooks — all other hook types use `additionalContext`.

**Session identity:** All hooks read `session_id` from the JSON input (provided by Claude Code on every hook invocation). This enables session-aware lock files — a session can always remove its own worktree but cannot remove another session's worktree while the lock is fresh.

**Native lifecycle hooks:** `WorktreeCreate` and `WorktreeRemove` fire on native `isolation: "worktree"` subagent creation and `--worktree` CLI usage. These complement the PostToolUse (Bash) monitoring of `git worktree add/remove` — together they cover both manual and native worktree operations.

**Async PostToolUse:** The `artifact-location-check.sh`, `worktree-lifecycle.sh`, and `session-audit.sh` hooks run with `"async": true` — they don't block tool execution since they're advisory or observability-only.

**Context injection:** `session-env-check.sh` (SessionStart) and `pre-compact-worktree.sh` (PreCompact) return `additionalContext` JSON — a string injected directly into Claude's context. This ensures Claude always knows about active worktrees, even after context compaction in long sessions.

**Native `--worktree` flag:** Claude Code supports `isolation: "worktree"` on subagents and `--worktree` on the CLI. This creates an isolated worktree automatically with session-scoped cleanup. When available, prefer native worktree isolation over manual `git worktree add` — it handles creation, branch naming, and cleanup automatically. The hooks above protect both manual and native worktrees.

**Hook timeouts:** All PostToolUse hooks should complete within 10 seconds. If a hook (e.g., `lint-on-edit.sh`, `typecheck-on-edit.sh`) takes longer, it should use `timeout 10s` internally to avoid blocking the user's workflow. Async hooks are exempt from this since they don't block.

## Branch Creation Safety Model

**Branch creation is safe only via `git worktree add -b`** — the documented and enforced pattern in parallel-session workflows.

The `worktree-safety.sh` hook allows:
- ✅ `git worktree add .worktrees/name -b branchname` — safe, creates isolated branch context
- ✅ `git worktree add .worktrees/name branchname` — safe, uses existing branch in isolation
- ✅ `git worktree remove` (when owned by this session) — safe, session-aware lock verification

The `worktree-safety.sh` hook blocks:
- ❌ `git checkout -b newbranch` — unsafe, mutates main directory branch state
- ❌ `git checkout --orphan newbranch` — unsafe, mutates main directory branch state
- ❌ `git switch -c newbranch` — unsafe, mutates main directory branch state
- ❌ `git checkout <existing-branch>` — unsafe, mutates main directory branch state when worktrees exist

This enforcement ensures the main working directory stays on the base branch (usually main) for the entire duration of parallel execution. All feature development happens in isolated worktrees.

## Hook Troubleshooting

**If a hook blocks unexpectedly (false positive):**

1. Read the deny reason on stderr — it explains which rule triggered and why.
2. Verify the condition: run `git worktree list` to check if worktrees are active. If the count is 1 (only main), the hook should not have blocked — file a bug.
3. If the block is a genuine false positive, temporarily disable the hook by commenting it out in `~/.claude/settings.json` under the relevant hook event. Re-enable after completing the operation.

**If hooks cause errors (not blocks):**

1. Check that `jq` is installed: `command -v jq`. Hooks fail open without `jq` but print a warning.
2. Check that hook files are executable: `ls -la ~/.claude/hooks/`. All hooks need `chmod +x`.
3. Check the `# Version:` comment at the top of each hook against the version column in the table above. If they don't match, the hooks are stale — re-copy from the skill repo.

**Known limitations:**

- **TOCTOU on lock files:** Between checking the lock age and attempting worktree removal, another session could write a new lock. The window is tiny and the consequence is only a warning (not data loss).
- **`stat` cross-platform:** Lock age uses `stat -c %Y` (Linux) with `stat -f %m` (macOS) fallback. If neither works (e.g., Alpine BusyBox `stat`), the age defaults to 0 and blocks removal (safe default).
- **`session_id` availability:** If Claude Code doesn't provide `session_id` in the hook input (older versions), lock files fall back to manual creation and lock ownership checks are skipped.
