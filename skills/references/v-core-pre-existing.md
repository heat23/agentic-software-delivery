# Pre-existing Failure Baseline Protocol (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (SKILL-CONTENT-REVIEW-2026-07-05 P0 #1 — baseline-laundering fix)._

## Pre-existing Failure Baseline Protocol (Mandatory)

This protocol is **mandatory** for all build and pre-flight sessions. It prevents wasted time
debugging failures that existed before the session started — **without** letting a regression
you just introduced launder itself into "pre-existing".

**When to capture baseline:** At pre-flight time, NOT at session start.

### The invariant (why the old approach was broken)

A baseline is only trustworthy if it measures the code **as it was before this session's
changes**. The failed prior design captured the baseline from the *current* (already-modified)
tree and then **re-saved the current failures over the baseline** on every run — so re-running
pre-flight converted a freshly-introduced regression into "pre-existing" → PASS. It was also
keyed by repo-hash + a `<4h` mtime, so concurrent sessions clobbered each other's baseline.

Two hard rules fix the class:

1. **Baseline is measured at the pre-change base state only** — the merge-base of this branch
   with `main` (the commit the session diverged from), in an **isolated detached worktree** so
   the live tree is never touched.
2. **Never overwrite the baseline with post-change failures.** The cache is keyed by the
   immutable base-commit SHA and written exactly once per base commit (cache-miss path). The
   current session's failing tests are NEVER written to it.

### How it works

```bash
set -o pipefail
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo"; }
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"

# Base = the commit this session diverged from (pre-change state). Immutable across the session.
BASE_SHA="$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || git rev-parse "$MAIN_BRANCH" 2>/dev/null)"

# Cache key = base commit SHA (content-addressed, immutable, safe to share across sessions on
# the SAME base — same base ⇒ same expected baseline). NOT time-based, NOT repo-hash-only.
BASELINE_DIR="${TMPDIR:-/tmp}/v-preexisting-baseline"
mkdir -p "$BASELINE_DIR"
BASELINE_FILE="$BASELINE_DIR/base-${BASE_SHA:-unknown}.txt"

# Step 1: current failing tests (this session's tree). Cap at 200 (not 40) so a session-introduced
# regression past the 40th sorted line is not silently dropped from the NEW-failure diff; warn loudly
# if the true count exceeds the cap so truncation can never masquerade as "no new failures".
_ALL_FAILING=$(php artisan test --parallel 2>&1 | grep -E '^[[:space:]]*(FAIL|✗|×)' | sort)
# JS: _ALL_FAILING=$(npm test -- --run 2>&1 | grep -E '^[[:space:]]*(FAIL|✗|×)' | sort)
FAILING_TESTS=$(printf '%s\n' "$_ALL_FAILING" | head -200)
[ "$(printf '%s\n' "$_ALL_FAILING" | grep -c .)" -gt 200 ] && \
  echo "WARN: >200 failing tests — baseline comparison truncated at 200; investigate manually before trusting PASS" >&2

# Step 2: obtain the base-state baseline (compute ONCE per base commit, in isolation)
if [ -f "$BASELINE_FILE" ]; then
  :                                                        # cached base baseline — reuse, never rewrite
elif [ -n "$BASE_SHA" ]; then
  BT="$BASELINE_DIR/wt-${BASE_SHA}-$$"   # PID-suffixed so concurrent same-base sessions don't race on the temp worktree
  rm -rf "$BT" 2>/dev/null
  if git worktree add --detach "$BT" "$BASE_SHA" >/dev/null 2>&1; then
    # Deps MUST reflect the base state, not the session's post-change deps — else a dependency-bump
    # regression fails identically in both runs and launders to "pre-existing". Reuse live deps ONLY
    # when every lockfile is byte-identical to the base; otherwise install the BASE's own deps.
    LOCK_CHANGED=0
    for lf in composer.lock package-lock.json yarn.lock pnpm-lock.yaml; do
      [ -f "$REPO_ROOT/$lf" ] && ! cmp -s "$REPO_ROOT/$lf" "$BT/$lf" 2>/dev/null && LOCK_CHANGED=1
    done
    if [ "$LOCK_CHANGED" = "1" ]; then
      ( cd "$BT" && { [ -f composer.json ] && composer install --no-interaction --no-progress -q >/dev/null 2>&1; \
                      [ -f package-lock.json ] && npm ci --silent >/dev/null 2>&1; :; } )
    else
      for d in vendor node_modules; do
        [ -d "$REPO_ROOT/$d" ] && [ ! -e "$BT/$d" ] && ln -s "$REPO_ROOT/$d" "$BT/$d" 2>/dev/null
      done
    fi
    ( cd "$BT" && php artisan test --parallel 2>&1 | grep -E '^[[:space:]]*(FAIL|✗|×)' | sort > "$BASELINE_FILE" ) \
      || : > "$BASELINE_FILE"
    git worktree remove --force "$BT" 2>/dev/null; git worktree prune 2>/dev/null
  else
    : > "$BASELINE_FILE"                                   # base checkout failed → empty baseline (conservative)
  fi
else
  : > "$BASELINE_FILE"                                     # no base resolvable → treat all failures as new
fi

# Step 3: NEW failures = current failures NOT present in the base baseline.
NEW_FAILURES=$(comm -23 <(printf '%s\n' "$FAILING_TESTS") "$BASELINE_FILE" 2>/dev/null || printf '%s\n' "$FAILING_TESTS")
# NOTE: the baseline file is NEVER rewritten here. There is no Step-3 "save current as baseline".
```

**Decision logic:**
- If `NEW_FAILURES` is empty → all current failures already failed on the base commit →
  pre-existing → pre-flight PASSES (with note).
- If `NEW_FAILURES` has entries → these are session-introduced → pre-flight FAILS on these only.

**Reporting:** Pre-existing failures go in the PRE_FLIGHT_REPORT under a
`## Pre-existing Failures (not blocking)` section. Session-introduced failures go under
`## FAILED Gates` as normal.

**Cost note:** the base-state suite runs at most once per base commit (cached by `$BASE_SHA`);
subsequent pre-flights on the same base reuse it. When the session's lockfiles are byte-identical
to the base, the base worktree symlinks the live `vendor`/`node_modules` (fast). When a lockfile
differs, the base worktree installs the **base's own** deps (`composer install`/`npm ci`) so a
dependency-bump regression cannot launder itself into the baseline — this is automatic, no manual
cache deletion required.

When dispatching parallel sessions, designate ONE session as the "test health" session
responsible for fixing pre-existing failures. All other sessions note them and move on.
