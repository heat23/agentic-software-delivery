# Feature Workflow (Medium/Large) — Worktree Setup Snippet

This file holds the conditional dependency-install bash for the Feature Workflow (Medium/Large) Step 1 (Isolate). Loaded only by `/v` SKILL.md when scope is Medium/Large.

## Conditional Install + Symlink

`PLANNED_FILES` must be populated upstream by the orchestrator before this snippet (PLANNED_FILES must be set in the environment) (newline-separated list of file paths the session intends to modify, derived from the plan or implementation prompt):

```bash
# REQUIRED: PLANNED_FILES populated upstream by orchestrator from plan/prompt
# (newline-separated planned change paths). Example:
#   PLANNED_FILES=$'resources/css/app.css\nresources/js/Components/X.tsx'
: "${PLANNED_FILES:?orchestrator must set PLANNED_FILES before running conditional install}"

NEEDS_INSTALL=false
# Check 1: dependency manifests in planned diff?
# Anchored path-boundary regex so monorepo paths (apps/web/package.json) match too.
for manifest in package.json composer.json package-lock.json composer.lock; do
  if echo "$PLANNED_FILES" | grep -qE "(^|/)${manifest//./\\.}$"; then
    NEEDS_INSTALL=true; break
  fi
done
# Check 2: dependency manifests dirty on MAIN's working tree (queried from $REPO_ROOT, not worktree)?
# Worktree branched from latest commit; if main is dirty re: manifests, worktree should reflect that.
if ! $NEEDS_INSTALL; then
  for manifest in package.json composer.json package-lock.json composer.lock; do
    if git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | grep -qE "(^|/)${manifest//./\\.}$"; then
      NEEDS_INSTALL=true; break
    fi
  done
fi

if $NEEDS_INSTALL; then
  cd "$WORKTREE_ABS_PATH" && composer install --no-scripts --no-cache && npm install
else
  # Symlink to skip ~90s install — safe when manifests unchanged. Surface failures.
  if [ -d "$REPO_ROOT/node_modules" ]; then
    if ! ln -s "$REPO_ROOT/node_modules" "$WORKTREE_ABS_PATH/node_modules"; then
      echo "WARN: ln -s node_modules failed; falling back to npm install"
      cd "$WORKTREE_ABS_PATH" && npm install
    fi
  else
    cd "$WORKTREE_ABS_PATH" && npm install
  fi
  if [ -d "$REPO_ROOT/vendor" ]; then
    # W62/2026-05-27 fix: do NOT symlink vendor (plain OR partial "split") — PHP resolves
    # __DIR__ through symlinks (#46260), so a symlinked vendor/bin/pest runs MAIN's binary +
    # autoloader → "Cannot redeclare class ComposerAutoloaderInit<lock-hash>" fatal, or silently
    # tests MAIN's code. The setup script copy-on-write CLONES main's vendor into the worktree as
    # REAL independent files (cp -c / cp --reflink=auto; near-instant, ~0 disk) then dump-autoload.
    # Invoked EXPLICITLY because the WorktreeCreate *event* hook does NOT fire for a Bash
    # `git worktree add`. Idempotent + self-corrects a pre-existing symlinked/partial vendor.
    # Fail-open → verify the worktree got a REAL vendor + fall back to composer install.
    bash ~/.claude/hooks/worktree-php-setup.sh "$WORKTREE_ABS_PATH"
    if [ ! -f "$WORKTREE_ABS_PATH/vendor/autoload.php" ] || [ -L "$WORKTREE_ABS_PATH/vendor" ]; then
      echo "WARN: vendor clone did not yield a real worktree-local vendor; falling back to composer install"
      # vendor only needs removing when it's a SYMLINK (else `composer install` writes THROUGH
      # it into main). `rm -f` on a symlink unlinks ONLY the link — it never recurses — so even a
      # mis-set/empty WORKTREE_ABS_PATH cannot trigger a destructive `rm -rf` tree delete. A real
      # but partial vendor dir needs no removal (composer install populates it in place).
      [ -L "$WORKTREE_ABS_PATH/vendor" ] && rm -f "$WORKTREE_ABS_PATH/vendor"
      cd "$WORKTREE_ABS_PATH" && composer install --no-scripts --no-cache
    fi
  else
    cd "$WORKTREE_ABS_PATH" && composer install --no-scripts --no-cache
  fi
fi
cd "$WORKTREE_ABS_PATH" && npm run build
```

**Why this is safe:** (1) when no manifest is in the planned diff, worktree's manifests match main's HEAD exactly; (2) when main has dirty manifests, Check 2 forces fresh install to match; (3) symlink failures fall back to install rather than leaving an empty `node_modules` / `vendor`. Saves ~90s wall-clock per session that touches only source/template/CSS files.

