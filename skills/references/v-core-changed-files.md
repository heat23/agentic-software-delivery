# Changed File Detection (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Changed File Detection (Worktree-Aware)

Multiple skills need to detect which files changed during the current session. In worktree workflows, `git diff HEAD` only shows uncommitted changes — after checkpoint commits, it shows nothing.

**Canonical pattern for detecting all session changes:**

```bash
# Detect if inside a worktree
IS_WORKTREE=false
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
if [ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]; then
  IS_WORKTREE=true
fi

if $IS_WORKTREE; then
  # In a worktree: show all changes since branching from main
  MERGE_BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || git rev-list --max-parents=0 HEAD 2>/dev/null | head -1 || echo "HEAD")
  CHANGED=$(git diff --name-only "$MERGE_BASE"..HEAD 2>/dev/null)
  # Also include uncommitted changes on top of the worktree branch
  UNCOMMITTED=$(git diff --name-only HEAD 2>/dev/null)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  ALL_CHANGED=$(printf "%s\n%s\n%s\n" "$CHANGED" "$UNCOMMITTED" "$UNTRACKED" | sed '/^$/d' | sort -u)
else
  # Not in a worktree: standard detection (unstaged + staged + untracked)
  CHANGED=$(git diff --name-only HEAD 2>/dev/null)
  STAGED=$(git diff --cached --name-only 2>/dev/null)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null)
  if [ -z "$CHANGED" ] && [ -z "$STAGED" ] && [ -z "$UNTRACKED" ]; then
    CHANGED=$(git diff --name-only HEAD~1 2>/dev/null)
  fi
  ALL_CHANGED=$(printf "%s\n%s\n%s\n" "$CHANGED" "$STAGED" "$UNTRACKED" | sed '/^$/d' | sort -u)
fi

echo "$ALL_CHANGED"
```

All skills that detect changed files (`v-verify-done`, `v-pre-flight`, `v-build`, `v-check`, `v-polish`, `/v` orchestrator) MUST use this pattern instead of bare `git diff --name-only HEAD`. The merge-base approach ensures checkpoint commits in worktrees don't hide the session's full changeset.
