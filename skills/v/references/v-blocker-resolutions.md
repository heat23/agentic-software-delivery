# v-blocker-resolutions.md

Concrete autonomous resolutions for common blockers. Read from the SELF-SUFFICIENCY DIRECTIVE
in SKILL.md when the inline pointer directs here.

---

## Blocker: `DETECTION_ERROR=not_inside_git_repo` (Step 0 bootstrap)

This usually means the user invoked /v from a non-project directory (e.g.,
`~/.claude/skills`, `~/`). Your task content almost certainly references
specific file paths that resolve under exactly one project.

Autonomous resolution sequence:

1. Extract all file paths from the resolved task content via regex. Patterns:
   `app/[A-Za-z0-9_/.]+\.(php|js|ts|tsx|jsx|vue)`,
   `routes/[A-Za-z0-9_.]+\.php`,
   `database/migrations/[0-9_a-z]+\.php`,
   `tests/[A-Za-z0-9_/.]+\.php`,
   `src/[A-Za-z0-9_/.]+\.(ts|tsx|js|jsx|vue|py)`,
   `package.json`, `composer.json`.
2. Search common project roots:
   ```bash
   for dir in ~/dev/*/*/ ~/dev/*/ ~/projects/*/ ~/code/*/ ~/work/*/ ~/repos/*/ ~/src/*/; do
     [ -e "$dir/.git" ] || continue
     candidates+=("$dir")
   done
   ```
3. For each candidate, check whether ALL extracted file paths exist relative
   to its root. The project that contains ALL paths is the target.
4. If exactly ONE candidate matches all paths → `cd "$candidate"` and re-run
   `v-bootstrap-wrapper.sh`. Continue silently. Log
   `AUTO-RESOLVED-PROJECT_ROOT=<candidate>` so the user can see the decision
   in your transcript.
5. If multiple candidates match → take the one most-recently modified
   (`git log -1 --format=%ct`). Log the choice + the alternatives that were
   rejected so the user can correct if wrong.
6. If zero candidates match → THEN ask the user, but with specific options
   you've enumerated, not a generic "please specify PROJECT_ROOT".

---

## Blocker: HIGH findings on session-owned diff from adversarial review

Default behavior is to **fix them in the same session**, not defer. The
adversarial review ran on your diff; the findings are about code YOU just
wrote or touched. "Out of scope" / "deferred to follow-up" is only valid
when:
- The user's original /v invocation explicitly bounded scope (e.g.,
  "fix BILL-P0-1 only")
- The finding is in pre-existing code that your diff did not touch
- The fix would expand the diff to >2x its current size (genuine scope
  creep)

If none of these apply, fix the HIGH findings. Then re-run the same
adversarial review on the updated diff before final commit.

---

## Blocker: orphaned files in `git status` not authored by this session

Run `git log --follow --oneline -- <path>` on each unexpected file. If git
has no history for it, it's truly orphaned (uncommitted from a prior
session). If you authored it (per session-writes tracking), keep it. If
not:
- If it passes tests AND is in a directory your diff touches → include it,
  add a note to the commit message
- If unrelated to your diff → exclude it from the commit (do NOT stage)
- Never delete an orphaned file autonomously — leave it unstaged

---

## Blocker: stop-hook artifact gates (PRE_FLIGHT_REPORT, AGENT_REVIEW, VERIFY_DONE_REPORT) missing

These artifacts are required for completion. Run the corresponding
sub-skills (`/v-pre-flight`, dispatch adversarial reviewer, `/v-verify-done`)
in parallel if possible. Do NOT ask the user — the gate told you exactly
what artifacts to produce.
