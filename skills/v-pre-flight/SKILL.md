---
name: v-pre-flight
description: "Use after code changes to run mandatory quality gates before claiming completion."
user-invocable: true
allowed-tools: Bash, Read, Edit, Write, Glob, Grep, AskUserQuestion
context: fork
model: sonnet
---
<!-- skill: v-pre-flight | version: 1.2.2 | last-updated: 2026-08-12 -->


# 2026 Canonical Contract

Tier: Orchestration primitive. Most users should let `v` or `v-build` call this automatically.

This contract overrides older sections below on conflict.

Follow `_v-core.md` and `_v-exec.md`.

For changed file detection, read `~/.claude/skills/references/v-core-changed-files.md`.
For TypeScript errors, read `~/.claude/skills/references/v-exec-typescript.md`.
For pre-existing failures, read `~/.claude/skills/references/v-core-pre-existing.md`.
For user-owned maintenance scope, read `~/.claude/skills/references/v-core-maintenance.md`.

Rules:
- run all detectable blocking gates before failing the overall run
- classify each gate as `pass`, `fail`, `skipped`, or `not_evaluated`
- missing optional tooling is not a silent pass

Output:
- `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md`

```yaml
contract:
  tier: orchestration-primitive
  accepts: [project state]
  produces: [PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md]
  invokes: []
  invoked-by: [/v, /v-build, /v-check, /v-merge-all, /v-maintenance, user, /v-audit-orchestrator]
  estimated_tokens: 8k-25k
  estimated_duration: 2-8 min
```

# /v-pre-flight - Quality Gate Runner

**Boundary:** v-pre-flight owns "does the project build and pass automated checks?" — tests, builds, linting, type checking, security audits. v-verify-done owns "does the code follow conventions and avoid AI-specific mistakes?" — TODO markers, debug statements, missing test files, anti-patterns. If unsure which skill a check belongs in: if a CI server would run it, it's pre-flight. If a human reviewer would catch it, it's verify-done.

Run all available quality gates for the current project. Auto-detects tools, runs checks sequentially, and collects all blocking failures before failing the overall run.

**Conventions:** Follow `_v-core.md` for artifact behavior and `_v-exec.md` for execution rules.

## Skill Boundaries

**SME persona:** This audit is run by a **senior CI/release engineer** — someone whose specialty is executable, deterministic gates that produce binary pass/fail per check. Pre-flight gates either pass or fail; there's no judgment-call output. The artifact (`PRE_FLIGHT_REPORT_*.md`) is consumed downstream by Stop hooks and CI/CD pipelines as a structured pass/fail record.

**Distinct from `/v-verify-done`:** v-pre-flight runs **DETERMINISTIC EXECUTABLE GATES** (tests/build/lint/types/security audits — pass or fail, no nuance). v-verify-done runs **JUDGMENT-CALL CONVENTION CHECKS** (lazy loading, DOMPurify usage, type safety, AI-test anti-patterns — warnings + recommendations with confidence levels). Run BOTH after implementation — different question types, different output styles.

### Best fit

- Running ALL quality gates before declaring work done: tests, build, lint, type-check, security audits, bundle size
- Pre-merge / pre-push verification when the change set has been implemented
- Incremental mode for fast iteration (`--changed-only` runs only against modified files)
- Producing the `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` artifact that downstream skills consume

### Use instead

- `/v-verify-done` — for convention/pattern checks (lazy loading, DOMPurify, types, contracts, AI test anti-patterns); runs **in addition to** pre-flight, not instead
- Direct `npm test` / `php artisan test` — for TDD red-green iteration when only the failing test matters
- `/v-check` — for codebase-wide quality audits across multiple domains (this skill is per-change quality gates only)

### Not for

- Single-test debugging — use direct test commands with `--filter` / `--changed`
- Replacing test writing or implementation — this is verification, not creation
- Audit dispatching across the project — `/v-check` is the codebase-wide audit
- Performance benchmarking — gates here are pass/fail, not measurement

## Workflow

1. Resolve project root per `_v-core.md` § Project Root Detection: use `PROJECT_ROOT` from invocation prompt if present, else `git rev-parse --show-toplevel`; if that does not yield a safe repo root, stop and ask for PROJECT_ROOT explicitly. Do not fall back to `pwd`.
1a. **Worktree resolution (CRITICAL):** If `WORKTREE_PATH` is present in the invocation args, `cd $WORKTREE_PATH` BEFORE running any gate. ALL test/build/lint commands must execute from the worktree directory, not the main repo root. Without this, pre-flight runs against main's dirty tree and produces meaningless results for the worktree's changes.
   ```bash
   # Extract WORKTREE_PATH from args if present
   # Then: cd "$WORKTREE_PATH" before any gate execution
   ```
   Verify the cd succeeded and ABORT if it failed — running gates against the wrong directory produces invalid results:
   ```bash
   cd "$WORKTREE_PATH" || { echo "ABORT: failed to cd to $WORKTREE_PATH — worktree may have been deleted"; exit 1; }
   [ "$(pwd)" = "$WORKTREE_PATH" ] || { echo "ABORT: pwd is $(pwd), expected $WORKTREE_PATH"; exit 1; }
   ```
2. Detect available tools
3. Run each gate sequentially — collect results for every detectable gate
4. Fail overall after all blocking gates have run if any blocking gate failed
5. Report PASS/FAIL summary

### User-Owned Maintenance Mode

When the working directory or changed files fall entirely inside the roots allowed by `~/.claude/skills/references/v-core-maintenance.md`:
- set `mode: user-owned-maintenance` in the report
- prefer targeted maintenance tests before generic repo gates
- for canonical skill maintenance, run `$HOME/.agents/skills/__tests__` first
- run mirrored tests only after an explicit mirror sync and only for the synced files
- never fan out into `.codex`, `.claude/plugins`, plugin cache, or marketplace paths
- if no meaningful automated gate exists for a touched maintenance file, mark it `not_evaluated` and require hostile review coverage in the report rather than pretending it passed

This mode still runs `/v-pre-flight`; it just keeps the gate set proportional to the maintenance scope.

### Baseline-Aware Failure Reporting (Dirty Tree Mode)

When running on main (not in a worktree) and the uncommitted file count exceeds 30, pre-existing test failures will dominate the report. To distinguish session-introduced failures from pre-existing noise:

1. **Before running gates**, count the dirty files:
   ```bash
   DIRTY_COUNT=$(git diff --name-only HEAD 2>/dev/null | wc -l | tr -d ' ')
   ```
2. **If DIRTY_COUNT > 30 and NOT in a worktree**: note this in the report header as `mode: dirty-tree-baseline`. This signals that failures may be pre-existing.
3. **For test gates (PHP, JS)**: ALWAYS run the FULL suite first — it is mandatory and is NEVER skipped (the Stop hook blocks a code-changing session whose pre-flight report skipped it). **MANDATORY — full-suite Bash calls MUST pass an explicit `timeout: 600000` (10 min) tool parameter.** The Bash tool's default 2-minute timeout truncates large suites mid-run; a truncated run reported as `partial (timeout at 2m limit)` is NOT a sanctioned skip — the Stop hook rejects it and forces a full re-dispatch (observed 2026-07-07: cost a full extra pre-flight round). If a suite is killed by ANY timeout, the gate is INCONCLUSIVE — re-run with the full budget; never record a truncated run as PASS or "partial pass". The separate **targeted** re-run on this session's changed files exists for ONE purpose: to classify a full-suite FAILURE as pre-existing vs session-introduced (step 5). So gate it on the full-suite result:
   - **Full suite GREEN (zero failures) → SKIP the targeted re-run.** It is pure redundancy — the changed-file tests are a subset of the green full suite, so they necessarily passed. Record the Session-tests section as `PASS (covered by the green full suite)`. (Lever B, token/wall-clock: avoids a redundant second test execution on the common green path. The FULL suite still ran — this is NOT a full-suite skip; do NOT phrase the report as the *suite* being skipped for time/budget.)
   - **Full suite has FAILURES → run the targeted subset** to classify which failures this session introduced:
   ```bash
   # PHP: ./vendor/bin/pest --filter=<ClassName of a changed source file>   (derive from: git diff --name-only HEAD -- '*.php')
   # JS:  npx vitest run --changed
   ```
4. **In the report**: separate results into two sections:
   - "Session tests (targeted):" — pass/fail for tests covering this session's changes (on a GREEN full suite this is `PASS (covered by the green full suite)` — the targeted re-run was skipped as redundant per step 3)
   - "Full suite:" — pass/fail for all tests (may include pre-existing failures)
5. **Gate verdict**: If session-targeted tests pass but full suite fails, mark the gate as `PASS (pre-existing failures in full suite)` — do NOT mark it as FAIL. Only mark FAIL if session-targeted tests fail.
   - **"Not in the changed-file set" is NOT proof of pre-existence.** A changed *source* file can break an *unchanged* test file — this is the dominant failure mode for whole-codebase scanner tests (`tests/Contracts/`, `*CopyScanner*`, architecture/convention tests) which scan the entire source tree. A scanner test that fails AFTER your source change is **session-introduced**, even though the test file itself never appears in the diff. You may only classify a full-suite failure as "pre-existing" when a baseline comparison (per `~/.claude/skills/references/v-core-pre-existing.md`, diff by failing-test NAME against clean HEAD/merge-base) confirms it failed BEFORE this session. Absent a confirmed baseline, treat the failure as session-relevant — do not assume pre-existence from filename non-overlap.

### Read-only / deferral mode does NOT suppress the verdict (CRITICAL)

A request to run pre-flight **read-only** ("don't fix anything", "record issues for a later wave/hardening pack", "capture evidence only") governs whether you EDIT source — it does **not** change the pass/fail verdict.

- A **session-introduced** failure forces overall `status: fail`, even when you are told not to fix it. Record it under `## Blocking Failures` as a deferred-but-blocking item (e.g., "DEFERRED to Wave 3 — still blocks") — never demote it to a non-blocking `## Advisories` line. Deferring the *fix* is a workflow decision; the *verdict* must still reflect that the change set is not green.
- Report-integrity rule #2 is absolute: **no gate may be `failed` (or hold a session-introduced failure) while the overall verdict is `passed`.** "It's read-only" / "it's going in a later wave" is not an exception. If you find yourself writing `Overall: PASS` next to an acknowledged session-introduced failure, the verdict is wrong — flip it to FAIL.
- Pre-existing failures (baseline-confirmed) are the ONLY failures that may coexist with an overall PASS, and only via the `PASS (pre-existing failures in full suite)` path above.

## Tool Detection

Run once at start:

```bash
test -f composer.json && echo "PHP_PROJECT=true"
test -f package.json && echo "JS_PROJECT=true"
test -f vendor/bin/pest && echo "PEST=true"
test -f vendor/bin/phpunit && echo "PHPUNIT=true"
test -f vendor/bin/pint && echo "PINT=true"
{ test -f vendor/bin/phpstan || test -f vendor/bin/larastan; } && echo "PHPSTAN=true"
test -f node_modules/.bin/vitest && echo "VITEST=true"
test -f node_modules/.bin/jest && echo "JEST=true"
test -f node_modules/.bin/eslint && echo "ESLINT=true"
test -f tsconfig.json && echo "TYPESCRIPT=true"
test -d tests/Contracts && echo "CONTRACT_TESTS=true"
test -f playwright.config.ts && echo "PLAYWRIGHT=true"
grep -rq "@visual" tests/e2e/ 2>/dev/null && echo "VISUAL_TESTS=true"
find tests/e2e -name '*.spec.*' 2>/dev/null | grep -q . && echo "E2E_SPECS=true"
# Pest browser testing (auth-integrated E2E lane) — CAPABILITY detection: the plugin
# package OR an existing tests/Browser/ spec directory, never a version string.
grep -q '"pestphp/pest-plugin-browser"' composer.json 2>/dev/null && echo "PEST_BROWSER=true"
{ test -d tests/Browser && find tests/Browser -name '*.php' 2>/dev/null | grep -q .; } && echo "PEST_BROWSER_SPECS=true"
test -f vendor/bin/infection && echo "INFECTION=true"
test -f node_modules/.bin/stryker && echo "STRYKER=true"
# Pest-native mutation testing (shipped Pest 3+) — version-RANGE probe (major 3-99),
# NOT a pinned version, so this keeps detecting correctly on Pest 4/5/6/... forever.
test -f vendor/bin/pest && ./vendor/bin/pest --version 2>/dev/null | grep -qE '^Pest ([3-9]|[1-9][0-9])\.' && echo "PEST_MUTATION=true"
test -f Cargo.toml && echo "RUST=true"
test -f pyproject.toml && echo "PYTHON=true"
test -f go.mod && echo "GO=true"
test -f Gemfile && echo "RUBY=true"
command -v ruff &>/dev/null && echo "RUFF=true"
command -v mypy &>/dev/null && echo "MYPY=true"
test -f node_modules/.bin/svelte-check && echo "SVELTE_CHECK=true"
command -v golangci-lint &>/dev/null && echo "GOLANGCI_LINT=true"
command -v brakeman &>/dev/null && echo "BRAKEMAN=true"
command -v rubocop &>/dev/null && echo "RUBOCOP=true"
# a11y (European Accessibility Act in force since 2025-06-28 — accessibility is a compliance gate, not a nicety)
test -f node_modules/.bin/axe && echo "AXE=true"
{ test -f node_modules/.bin/pa11y || test -f node_modules/.bin/pa11y-ci; } && echo "PA11Y=true"
grep -q '@axe-core/playwright' package.json 2>/dev/null && echo "AXE_PLAYWRIGHT=true"
grep -q 'eslint-plugin-jsx-a11y\|"jsx-a11y"' package.json 2>/dev/null && echo "JSX_A11Y=true"
# Core Web Vitals / Lighthouse budget (opportunistic — only fires when the project
# already has a measurement capability; never fabricate a Lighthouse run it hasn't set up)
{ test -f node_modules/.bin/lhci || command -v lhci &>/dev/null; } && echo "LHCI=true"
{ test -f .lighthouserc.js || test -f .lighthouserc.json || test -f .lighthouserc.yml || test -f .lighthouserc.yaml; } && echo "LHCI_CONFIG=true"
command -v lighthouse &>/dev/null && echo "LIGHTHOUSE_CLI=true"
```

## Convention Discovery (Test Commands)

Before running gates, detect the stack and check for custom test commands:

```bash
# 1. Check CLAUDE.md for custom test commands (any framework)
grep -A2 "test" CLAUDE.md 2>/dev/null | grep -oE '(./vendor/bin|npx|pytest|cargo test|go test|bundle exec|php artisan).*' | head -3

# 2. Check package.json scripts for JS projects
[ -f package.json ] && jq -r '.scripts | to_entries[] | select(.key | test("test|lint|build|check")) | "\(.key): \(.value)"' package.json 2>/dev/null

# 3. Check for parallel test support
grep -E "pest.*--parallel|phpunit.*--parallel" CLAUDE.md 2>/dev/null | head -1
```

**Custom command priority:** CLAUDE.md commands > package.json/composer.json scripts > detected tool defaults.
**Single-core override:** If a custom test command enables parallelism, clamp it back to one worker before running it.

**Flag validation:** Before using `--parallel` or other advanced flags, verify the installed tool version supports them:
```bash
# Pest parallel (requires >= 2.0)
./vendor/bin/pest --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1
```
If the flag is unsupported, fall back to the default command without it.

### Single-Core Test Execution (CRITICAL)

All test-capable commands invoked by this skill must stay on one core. Do not scale workers based on worktrees or CPU count.

```bash
# Hard cap for all test runners
PROCESSES=1
```

**Apply the single-core cap to every runner that can fan out work:**
- Pest/PHPUnit parallel mode: `php artisan test --parallel --processes=$PROCESSES`
- pytest-xdist: `pytest -n $PROCESSES` (plain `pytest` is already serial)
- Vitest: `npx vitest run --pool-options.threads.maxThreads=$PROCESSES --pool-options.threads.minThreads=$PROCESSES`
- Jest: `npx jest --runInBand`
- Playwright: `npx playwright test --workers=$PROCESSES`
- Cargo: `cargo test -- --test-threads=$PROCESSES`
- Go: `go test -p $PROCESSES ./...`

If a custom command or hook introduces higher parallelism, rewrite it back to a single worker before execution. The `parallel-test-throttle.sh` PreToolUse hook is the backstop for Bash commands.

### Framework-Specific Gate Mapping

The gate execution table below is the superset. Skip gates that don't apply to the detected stack:

| Stack | Test Gate | Build Gate | Lint Gate | Type Check | SAST / Security | Dependency Audit |
|-------|-----------|------------|-----------|------------|-----------------|------------------|
| Laravel | Pest/PHPUnit (`--processes=$PROCESSES` when parallel mode is used) | `npm run build` | Pint (`--test`) | `npx tsc --noEmit` + PHPStan/Larastan (Gate 23) | — | `composer audit` + `npm audit` |
| Next.js | Vitest (`maxThreads=$PROCESSES`) or Jest (`--runInBand`) | `npm run build` | ESLint | `npx tsc --noEmit` | — | `npm audit` |
| SvelteKit | Vitest (`maxThreads=$PROCESSES`) | `npm run build` | ESLint | `svelte-check` | — | `npm audit` |
| Nuxt | Vitest (`maxThreads=$PROCESSES`) | `nuxi build` | ESLint | `nuxi typecheck` | — | `npm audit` |
| Django | `pytest -n $PROCESSES` or `pytest` | `python manage.py collectstatic --noinput` | ruff/flake8 | mypy/pyright | bandit | `pip-audit` |
| FastAPI | `pytest -n $PROCESSES` or `pytest` | — | ruff/flake8 | mypy/pyright | bandit | `pip-audit` |
| Rails | RSpec/Minitest | `bundle exec rake assets:precompile` | RuboCop | Sorbet (if configured) | Brakeman | `bundle-audit` |
| Rust | `cargo test -- --test-threads=$PROCESSES` | `cargo build --release` | `cargo clippy` | Built-in | — | `cargo audit` |
| Go | `go test -p $PROCESSES ./...` | `go build ./...` | `golangci-lint run` | Built-in | — | `govulncheck ./...` |

**Accessibility (Gate 24):** for any consumer-facing web stack (Laravel+Inertia/React, Next.js, SvelteKit, Nuxt) also run the detected a11y tool — `@axe-core/playwright` (via Gate 11.5), `pa11y-ci`, standalone `axe`, or the `jsx-a11y` ESLint rules (via Gate 4). The EAA has been in force since 2025-06-28; do not ship a consumer UI with zero a11y coverage.

When a framework-specific tool isn't detected, skip that gate as `not_evaluated` — don't fail.

## Incremental Mode (--changed-only)

When invoked with `--changed-only` or when the calling skill passes a file list:

1. Find changed files using the worktree-aware pattern from `~/.claude/skills/references/v-core-changed-files.md`.

2. Run abbreviated gates:
   | Gate | Incremental Behavior |
   |------|---------------------|
   | PHP Tests | Run only test files matching changed source files: `./vendor/bin/pest --filter=ClassName` |
   | JS Tests | `npx vitest run --changed --pool-options.threads.maxThreads=$PROCESSES --pool-options.threads.minThreads=$PROCESSES` |
   | Frontend Build | Full build (can't be scoped) |
   | Lint | `npm run lint -- {changed .ts/.tsx files only}` |
   | TypeScript | Full check (can't be scoped) |
   | ESLint strict | Already scoped to changed files |
   | Audits | Skip (not file-scoped) |
   | Contract tests | Full run (fast enough) |

3. Mark skipped gates as `status: skipped (incremental mode)` in the report.
4. Note: Incremental mode is for iteration speed. Always run full mode before `/v-check`.

## Gate Result Schema reference (NEW — Round 3)

Every gate's pass/fail conditions, evidence format, and elevation
behavior is formalized in `references/gate-schema.md`. The
PRE_FLIGHT_REPORT structure is enforceable against that schema:
- Status taxonomy (`pass` / `fail` / `failed_non_blocking` /
  `skipped` / `not_evaluated` — short forms canonical per gate-schema.md § Status
  taxonomy; `passed`/`failed` are read-side legacy synonyms only)
- Per-gate detection signals + thresholds
- Report-integrity rules (every applicable gate must have a status
  entry; failures must propagate to the overall verdict; ≥4
  `not_evaluated` results signals broken infra)

When adding a new gate, update both this SKILL.md table AND
`references/gate-schema.md` in lockstep.

## Gate Execution Order

Run in this order. Skip gates where the tool isn't detected. Do not stop after the first blocking failure; record every blocking result, then fail overall at the end.

| # | Gate | Command | When |
|---|------|---------|------|
| 1 | PHP Tests | Project CLAUDE.md test command after clamping to one worker, or `php artisan test` / `./vendor/bin/pest` / `./vendor/bin/phpunit` | PEST or PHPUNIT |
| 2 | JS Tests | `npx vitest run --pool-options.threads.maxThreads=$PROCESSES --pool-options.threads.minThreads=$PROCESSES` or `npx jest --runInBand` | VITEST or JEST |
| 3 | Frontend Build | `BUILD_OUTPUT=$(npm run build 2>&1); echo "$BUILD_OUTPUT"` | JS_PROJECT |
| 3.1 | Smoke Test | See Smoke Test section below | Always (stack-specific) |
| 3.5 | Bundle Size | `echo "$BUILD_OUTPUT" \| grep -i 'size\|chunk\|gzip'` (reuse gate 3 output) | JS_PROJECT |
| 4 | Lint | `npm run lint` | ESLINT |
| 5 | TypeScript | `npx tsc --noEmit` (with auto-remediation) | TYPESCRIPT |
| 6 | ESLint strict (changed files) | `npx eslint --max-warnings=0 {files}` | ESLINT + changed .ts/.tsx files |
| 7 | Pint (Laravel formatting) | `./vendor/bin/pint --test` | PINT |
| 8 | Composer audit | `composer audit` | PHP_PROJECT |
| 9 | npm audit | `npm audit --audit-level=critical` | JS_PROJECT |
| 10 | Contract tests | `./vendor/bin/pest tests/Contracts/` | CONTRACT_TESTS |
| 11 | Visual regression | `npx playwright test --grep @visual --workers=$PROCESSES` | PLAYWRIGHT + VISUAL_TESTS |
| 11.5 | E2E / browser workflow specs (BLOCKING) | See Gate 11.5 section below — routes to Pest browser and/or Playwright by detected lane | PEST_BROWSER_SPECS or E2E_SPECS (skip in incremental mode) |
| 12 | Mutation testing | See Gate 12 section below — routes to Pest-native / Infection / Stryker by detected engine | PEST_MUTATION or INFECTION or STRYKER + changed source files |
| 13 | Rust tests | `cargo test -- --test-threads=$PROCESSES` | RUST |
| 14 | Python tests | `pytest` | PYTHON |
| 15 | Go tests | `go test -p $PROCESSES ./...` | GO |
| 16 | Ruby tests | `bundle exec rspec` or `bundle exec rails test` | RUBY |
| 17 | Ruby lint | `bundle exec rubocop {changed .rb files}` | RUBOCOP |
| 18 | Ruby security | `bundle exec brakeman -q` | BRAKEMAN |
| 19 | Python lint | `ruff check {changed .py files}` or `flake8 {changed .py files}` | RUFF or PYTHON |
| 20 | Python type check | `mypy {changed .py files}` | MYPY |
| 21 | Migration rollback | `php artisan migrate:rollback --step=1 --env=testing && php artisan migrate --env=testing` | PHP_PROJECT + changed migration files (conditionally blocking — see Non-Blocking Gates) |
| 22 | Seeder compatibility | `php artisan db:seed --env=testing 2>&1` | PHP_PROJECT + changed migration or model files (conditionally blocking — requires test DB) |
| 23 | PHPStan / Larastan (static analysis) | `./vendor/bin/phpstan analyse --no-progress --error-format=raw` | PHPSTAN |
| 24 | Accessibility (a11y / EAA) | See Gate 24 section below | A11Y tooling detected (axe / jsx-a11y) |
| 25 | Core Web Vitals / performance budget | See Gate 25 section below | LHCI or LIGHTHOUSE_CLI detected |

For gate 6, find changed TS/TSX files:
```bash
git diff --name-only HEAD -- '*.ts' '*.tsx' 2>/dev/null
```

### Gate 3.1: Smoke Test (Blocking)

Verifies the app can actually boot and resolve routes — catches missing env vars, broken service providers, and invalid route registrations that tests miss (because tests use `.env.testing` with different defaults).

**Laravel:**
```bash
# Verify routes resolve (catches middleware renames, missing controllers, broken service providers)
php artisan route:list --json > /dev/null 2>&1
ROUTE_EXIT=$?

# Verify config is valid (catches missing env vars referenced in config)
# Use a subshell with trap to ensure cached config is always cleared, even on interrupt
CONFIG_EXIT=0
(trap 'php artisan config:clear 2>/dev/null' EXIT; php artisan config:cache 2>&1) || CONFIG_EXIT=$?

# Verify event/listener discovery works
php artisan event:list > /dev/null 2>&1
EVENT_EXIT=$?

if [ $ROUTE_EXIT -ne 0 ] || [ $CONFIG_EXIT -ne 0 ] || [ $EVENT_EXIT -ne 0 ]; then
  echo "SMOKE TEST FAILED"
  [ $ROUTE_EXIT -ne 0 ] && echo "  route:list failed — broken route registration or missing controller"
  [ $CONFIG_EXIT -ne 0 ] && echo "  config:cache failed — missing or invalid environment variable"
  [ $EVENT_EXIT -ne 0 ] && echo "  event:list failed — broken event/listener wiring"
fi
```

**Node.js/Next.js:**
```bash
# Detect start/preview script (prefer start/preview over dev to avoid HMR overhead)
START_CMD=$(jq -r '.scripts.start // .scripts.preview // empty' package.json 2>/dev/null)
if [ -n "$START_CMD" ]; then
  # Detect port from package.json scripts or default to common ports
  PORT=$(echo "$START_CMD" | grep -oE '\-p\s*[0-9]+|port\s+[0-9]+' | grep -oE '[0-9]+' | head -1)
  [ -z "$PORT" ] && PORT=3000

  # Portable timeout: macOS ships no `timeout` binary. Prefer it if present
  # (Linux CI runners have it), fall back to `gtimeout` (coreutils via brew),
  # else a background-pid + watcher-kill pattern that works everywhere.
  TIMEOUT_BIN=""
  command -v timeout >/dev/null 2>&1 && TIMEOUT_BIN="timeout"
  [ -z "$TIMEOUT_BIN" ] && command -v gtimeout >/dev/null 2>&1 && TIMEOUT_BIN="gtimeout"

  SMOKE_SCRIPT="
    $START_CMD &
    SERVER_PID=\$!
    # Poll for readiness instead of fixed sleep
    for i in \$(seq 1 20); do
      curl -sf http://localhost:$PORT > /dev/null 2>&1 && break
      sleep 1
    done
    CURL_EXIT=\$(curl -sf -o /dev/null -w '%{http_code}' http://localhost:$PORT 2>/dev/null)
    # Kill process group to avoid zombie child processes
    kill -- -\$SERVER_PID 2>/dev/null || kill \$SERVER_PID 2>/dev/null
    [ \"\$CURL_EXIT\" = '200' ] && exit 0 || exit 1"

  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 30 bash -c "$SMOKE_SCRIPT"
    SMOKE_EXIT=$?
  else
    # `set -m` enables job control so the backgrounded bash gets its OWN
    # process group — without it, `kill -- -$PID` is a no-op (the pid is not
    # a group leader) and the watcher never actually stops a hung command.
    set -m
    bash -c "$SMOKE_SCRIPT" &
    SMOKE_BASH_PID=$!
    ( sleep 30; kill -0 "$SMOKE_BASH_PID" 2>/dev/null && kill -- -"$SMOKE_BASH_PID" 2>/dev/null ) &
    WATCHER_PID=$!
    wait "$SMOKE_BASH_PID" 2>/dev/null
    SMOKE_EXIT=$?
    kill "$WATCHER_PID" 2>/dev/null
    set +m
  fi
  [ $SMOKE_EXIT -ne 0 ] && echo "SMOKE TEST FAILED — app did not respond on localhost:$PORT"
fi
```

**Python (Django/FastAPI):**
```bash
# Django: verify management commands work
python manage.py check --deploy 2>&1 || echo "SMOKE TEST FAILED — Django check --deploy failed"
```

If no stack-specific smoke test applies, mark as `skipped`.

### Gate 3.5: Bundle Size Check

After the frontend build completes, parse the SAME build output from gate 3 (do NOT run `npm run build` again). Capture size AND chunk identity, not just bare numbers — Vite/webpack/esbuild all suffix chunk filenames with a content hash, so two builds never share an exact filename for "the same" chunk. Key on a stable **stem** (filename with the trailing hash stripped) so growth can be compared chunk-for-chunk across runs:

```bash
# Extract bundle sizes from gate 3's captured BUILD_OUTPUT (Vite format), keyed by stem
# so the SAME logical chunk can be matched across two different builds.
CURRENT_CHUNKS=$(echo "$BUILD_OUTPUT" | grep -E '\.(js|css)[[:space:]]' | \
  sed -E 's#^.*/([A-Za-z0-9_.-]+)-[A-Za-z0-9]{6,}\.(js|css).*[^0-9]([0-9]+\.[0-9]+)[[:space:]]*kB.*$#\1.\2:\3#')
```

**Threshold rule (single source of truth — do NOT fabricate a default budget):** this gate is warn-only and never blocks. It flags a chunk when EITHER of these fires, and stays silent otherwise:
1. A **project-configured** budget exists (in `package.json` `bundlesize`/`size-limit`, `vite.config.*` `build.chunkSizeWarningLimit`, or equivalent) AND a chunk exceeds it.
2. A **previous pre-flight report** exists AND a chunk grew by >10% vs that report.

**Previous-report lookup (concrete — this was previously undocumented and the branch likely never fired):** reports are named `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` (SID, no timestamp), so "the previous one" means "most recent OTHER report by file mtime" — mirroring `v-check`'s Delta Mode (`v-check/SKILL.md` § Delta Mode), which solves the identical problem with an intentionally session-agnostic `ls -t` because the comparison is explicitly cross-session:
```bash
# This session's own report doesn't exist yet at Gate 3.5 time, so no self-exclusion
# needed — ls -t of everything at repo root naturally surfaces the most recent PRIOR run.
PREV_REPORT=$(ls -t PRE_FLIGHT_REPORT_*.md 2>/dev/null | head -1)
```

**Extraction + comparison:** the prior report's Gate 3.5 evidence line records `stem:size` pairs in the same format `CURRENT_CHUNKS` uses above (this IS that format — adopt it going forward). A report written before this convention existed simply produces no matches, which correctly degrades to "no comparable prior data" rather than a false failure or a crash:
```bash
if [ -n "$PREV_REPORT" ]; then
  PREV_CHUNKS=$(grep -A3 '^\s*name: Bundle Size' "$PREV_REPORT" 2>/dev/null | grep -oE '[A-Za-z0-9_.-]+\.(js|css):[0-9.]+')
  if [ -n "$PREV_CHUNKS" ]; then
    echo "$CURRENT_CHUNKS" | while IFS=: read -r stem size; do
      [ -z "$stem" ] && continue
      prev_size=$(echo "$PREV_CHUNKS" | grep "^${stem}:" | head -1 | cut -d: -f2)
      [ -z "$prev_size" ] && continue   # new chunk this run — nothing to compare against, not a growth finding
      awk -v new="$size" -v old="$prev_size" -v stem="$stem" 'BEGIN {
        if (old > 0) {
          growth = ((new - old) / old) * 100
          if (growth > 10) printf "GREW >10%%: %s %.1fkB -> %.1fkB (+%.1f%%)\n", stem, old, new, growth
        }
      }'
    done
  fi
fi
```

Write THIS run's `stem:size` pairs into its own Gate 3.5 evidence field (same format — see the report template below) so the NEXT session's Gate 3.5 has something to compare against. The comparison only has data to work with once at least one report has been written under this format.

If NEITHER a configured budget NOR a prior report (in the comparable format) exists, the gate is informational only — record the observed sizes as evidence and mark `passed` (no fabricated absolute default such as "200KB"). This matches Gotcha #4 and `references/gate-schema.md` Gate 3.5. Never invent a numeric budget the project did not set.

### Gate 5: TypeScript Auto-Remediation

When `npx tsc --noEmit` fails, do NOT immediately mark the gate as failed. Instead, apply `~/.claude/skills/references/v-exec-typescript.md` (up to 3 iterations, 5 known fix categories). Report both the original error count and the remediated count in evidence. All errors resolved → PASS; errors remain after 3 iterations → FAIL with only unresolvable errors listed.

> **Remediation must not weaken type safety.** The auto-remediation recipes may NOT introduce `as any` or leave a `// TODO`/`// FIXME` marker in delivered code — those are banned by Gate 4 (lint), Gate 6 (ESLint strict on changed files), and v-verify-done's universal checks. Prefer a typed mock factory, a precise cast (`as Partial<T> as T` only in tests), or fixing the actual type. If an error is genuinely unresolvable without an `any` escape, leave it as a reported FAIL rather than laundering it past the type checker with `as any`. (`references/v-exec-typescript.md` Category 4 was corrected 2026-07-05 to teach a typed adapter instead of the old `as any` + TODO recipe.)

### Gate 7: Pint (Laravel formatting)

Laravel's code-style fixer. Run in `--test` mode so the gate is read-only (reports drift, does not rewrite files):
```bash
./vendor/bin/pint --test 2>&1
```
- **Pass:** exit 0 (no style violations).
- **Fail:** exit non-zero → block. List the files Pint would reformat as evidence. Do NOT auto-run `pint` (without `--test`) inside pre-flight — formatting rewrites are an implementation action, not a gate.
- **Skipped:** `PINT` not detected.

### Gate 23: PHPStan / Larastan (static analysis)

Static analysis catches type errors, undefined methods, and dead branches that the test suite misses. Use the project's configured level (from `phpstan.neon` / `phpstan.neon.dist`); do NOT override it on the command line.
```bash
./vendor/bin/phpstan analyse --no-progress --error-format=raw 2>&1
```
- **Pass:** exit 0 (zero errors at the project's configured level).
- **Fail:** exit non-zero → block. Report the error count and top offending file:line entries as evidence.
- **Skipped:** `PHPSTAN` not detected (neither `vendor/bin/phpstan` nor `vendor/bin/larastan`).
- **not_evaluated:** binary present but `phpstan.neon*` config missing (analysis has no defined level) — surface as a prominent advisory, never a silent pass.

### Gate 24: Accessibility (a11y / EAA)

The European Accessibility Act has been in force since 2025-06-28 — accessibility is a compliance gate for consumer-facing SaaS, not a nicety. Run whatever a11y tooling the project already has; never fabricate a tool that isn't installed.

- **`AXE_PLAYWRIGHT`** (`@axe-core/playwright`) → the a11y assertions live inside the Playwright specs; they run as part of Gate 11.5. Record `covered by Gate 11.5 (axe-core assertions)`.
- **`PA11Y`** → `npx pa11y-ci` (uses the project's `.pa11yci` config) or `npx pa11y <url>` against the booted smoke-test URL.
- **`AXE`** (standalone axe CLI) → `npx axe <url>` against the smoke-test URL.
- **`JSX_A11Y`** only (ESLint plugin, no runtime tool) → the a11y lint rules already run under Gate 4 / Gate 6. Record `covered by ESLint jsx-a11y rules`.

- **Pass:** the a11y runner reports zero violations at its configured level.
- **Fail (warn-only by default; blocking when the project sets an a11y budget or CI already enforces it):** violations found → REVIEW-RECOMMENDED, listing rule id + selector as evidence. Treat WCAG-A/AA violations on new/changed pages as blocking when the project's CI treats them as blocking. This gate's warn-only default is a tooling statement, not a severity ruling — it does NOT demote a deep-UX audit's P0 a11y finding (v-audit-code's `deep-ux-audit.md` compliance floors remain the blocking authority for public/consumer surfaces).
- **Skipped:** no a11y tooling detected. Note the absence as an advisory for consumer-facing projects (EAA exposure), but do not fabricate a runtime a11y check the project hasn't set up.

### Gate 25: Core Web Vitals / Performance Budget

Opportunistic front-end performance floor — runs ONLY when the project already has a Lighthouse/CWV measurement capability; never fabricates one. Thresholds are cited, not restated: `_v-design.md` § Runtime-Critical Quality Bar (Core Web Vitals floor, 75th percentile field data) is the canonical owner (`~/.claude/skills/references/v-theme-owners.md` — Performance row points here for wall-clock/N+1, but the CWV numbers specifically live in `_v-design.md`; cite it, do not copy the LCP/INP/CLS values into this file — they may be re-verified/updated there without this gate drifting).

**Target-URL note (why LHCI is the primary lane):** pre-flight does not keep a live server running for a Laravel/Inertia stack — Gate 3.1's Laravel smoke test is `route:list`/`config:cache`/`event:list`, never a booted HTTP server, and Gate 11.5's Playwright `webServer` boots-and-tears-down inside that gate's own run. `lhci autorun` is the lane that fits this constraint: an `.lighthouserc.*` with its own `ci.collect.startServerCommand` (or `staticDistDir`) is self-contained — the PROJECT owns the boot mechanism, so this gate never needs to invent one. The bare-CLI lane is scoped down accordingly: it only fires when Gate 3.1's Node/Next.js smoke test already produced a reachable `localhost:$PORT` (see Gate 3.1 above) — on a Laravel stack with `LIGHTHOUSE_CLI` but no `.lighthouserc.*`, there is no capability-appropriate URL to hit, so the gate degrades to `not_evaluated` (below) rather than fabricating a boot step.

```bash
if [ -n "$LHCI_CONFIG" ]; then
  npx lhci autorun 2>&1   # self-contained: the project's own .lighthouserc.* owns server boot + assertions
elif [ -n "$LIGHTHOUSE_CLI" ] && [ -n "$PORT" ]; then
  # Only reachable when Gate 3.1's Node/Next.js smoke test booted localhost:$PORT.
  lighthouse "http://localhost:$PORT" --output=json --output-path=/tmp/lighthouse-${CLAUDE_SESSION_ID}.json --chrome-flags="--headless" 2>&1
fi
```

- **Pass:** LHCI assertions all pass (when `.lighthouserc.*` is configured), OR — bare `lighthouse` CLI against the Node smoke-test URL — the reported LCP/INP (or FID, on an older Lighthouse that hasn't picked up the 2024 metric swap)/CLS are within the thresholds cited from `_v-design.md` § Runtime-Critical Quality Bar at the time this gate runs (re-read the section fresh each run; do not cache the numbers across sessions — that file is the owner and can change them).
- **Fail (warn-only by default; blocking when the project's own `.lighthouserc.*` marks assertions as `error` level, or CI already enforces a budget):** any metric misses its cited threshold → REVIEW-RECOMMENDED, listing metric + observed value + threshold as evidence.
- **Skipped:** no consumer-facing web stack detected at all.
- **not_evaluated (known-absent capability — say so explicitly, never silently pass):** covers TWO distinct absent-capability shapes, both surfaced the same way: (a) neither `LHCI_CONFIG` nor `LIGHTHOUSE_CLI` detected at all; (b) `LIGHTHOUSE_CLI` is present but there's no capability-appropriate URL to hit (Laravel stack, no `.lighthouserc.*`, so no self-contained boot mechanism, and Gate 3.1 produced no `$PORT`). Record: `core_web_vitals: not_available — no Lighthouse/CWV measurement capability detected (checked: node_modules/.bin/lhci, .lighthouserc.*, lighthouse CLI, and — for the bare-CLI lane — a reachable smoke-test URL). Install @lhci/cli (\`npm install -D @lhci/cli\` + a \`.lighthouserc.js\` with its own startServerCommand, asserting the _v-design.md § Runtime-Critical Quality Bar thresholds) to enable this gate on this stack.` This is the SAME shape as the Gate 12 / Gate 11.5 "capability absent" advisories — absent must read differently from present-but-failing, and this note is what makes that distinction machine-greppable in the report.
- **Evidence:** which lane ran (LHCI vs bare CLI), metric values, threshold source citation.
- **Elevation:** warn-only → REVIEW-RECOMMENDED; blocking only when the project's own config/CI already treats it as blocking (never invent stricter enforcement than the project opted into).

### Gate 12: Mutation Testing

Verifies the test suite would actually catch a bug, not just execute the code — see `v-tdd/references/v-testing-patterns.md` § Mutation Testing for the underlying concept. **Detect the CAPABILITY, never assume one specific tool is installed:** this operator's stack ships mutation testing natively via Pest — a Pest-only project must never report "not installed."

**Engine priority (first detected wins per session — mutation testing is slow, don't run more than one engine):**

1. **`PEST_MUTATION`** (preferred — no separate install, matches this operator's actual stack). Scope to THIS session's changed PHP source classes (exclude tests), map each changed file to its FQCN via the project's PSR-4 root (`app/` → `App\` is the Laravel default; if `composer.json` overrides `psr-4`, resolve against that instead), and run one class at a time:
   ```bash
   git diff --name-only HEAD -- '*.php' 2>/dev/null | grep -v test | grep '^app/' | while read -r f; do
     FQCN=$(echo "$f" | sed -E 's#^app/#App/#; s#/#\\#g; s#\.php$##')
     ./vendor/bin/pest --mutate --class="$FQCN" --min=70 --ignore-min-score-on-zero-mutations 2>&1
   done
   ```
   - **Flag-compatibility guard:** if the output contains `Unknown option` / `does not exist` / `invalid option` (the installed Pest minor doesn't support `--min` or `--ignore-min-score-on-zero-mutations` on `--mutate`), do NOT read that as a mutation failure. Re-run bare (`./vendor/bin/pest --mutate --class="$FQCN"`), read the reported score from output, and mark the gate `not_evaluated` with: "Pest mutation flags unsupported at installed version — score read manually, threshold not machine-enforced. Upgrade Pest to enable automatic enforcement." This is a DEGRADED advisory, not a silent pass.
   - **Zero-mutations case (handle explicitly):** if Pest reports no mutations were generated for a class (pure interface/config/DTO, no mutable branches), that class does NOT fail the gate — record it `skipped (no mutable code in this class)`, never a 0% score. `--ignore-min-score-on-zero-mutations` does this automatically when the flag is supported; the flag-compatibility guard's manual read must apply the same rule by hand.
2. **`INFECTION`** (PHP, explicit legacy install): `vendor/bin/infection --filter={changed-php} --min-msi=70 --threads=$PROCESSES` (changed-file list per the snippet under Non-Blocking Gates below) — same 70% threshold, same zero-mutations handling: Infection reports something like "no mutations were generated" on a filtered set with no mutable code — treat that as `skipped`, not a fail.
3. **`STRYKER`** (JS, changed JS files): `npx stryker run --mutate '{changed-js-files}' --thresholds.high=70 --thresholds.low=60`.
4. **None detected:** this is now genuinely "no mutation-testing capability exists" (neither Pest ≥3, Infection, nor Stryker) — see the advisory text in Non-Blocking Gates below.

- **Pass:** mutation score ≥ 70% on changed classes/files, OR every changed class hit the zero-mutations skip.
- **Fail:** any changed class/file scores < 70% WITH mutants actually generated → block (only when explicitly enabled — see Non-Blocking Gates below for the conditional-blocking rule).
- **not_evaluated:** engine detected but the run errored for a reason OTHER than the flag-compatibility guard above (missing coverage driver, timeout) → prominent advisory, never a silent pass.
- **Skipped:** none of PEST_MUTATION / INFECTION / STRYKER detected, OR no changed PHP/JS source files this session.

### Gate 11.5: E2E / Browser Workflow Specs (Blocking when present)

Runs the committed browser-driven workflow specs — the golden paths frozen by `v-workflow-verifier` (/v Step 3.5) plus any authenticated-flow specs authored directly with Pest browser testing. This is the deterministic regression net for "the user-facing flow actually works", re-verified on every pre-flight / CI run. Distinct from Gate 11 (visual regression, `@visual`-tagged, non-blocking) — Gate 11.5 covers **functional** workflow specs and is **blocking**.

**Two lanes, detected independently by CAPABILITY (plugin package / spec directory), never by version string — run whichever are present, a project may use both:**

1. **Pest browser testing lane (`PEST_BROWSER_SPECS`)** — preferred for authenticated Inertia/Laravel flows: it reuses `actingAs()` and the rest of Pest's Laravel test helpers instead of re-implementing login as a raw browser fixture (authoring pattern: `v-tdd/references/pest-browser-test-skeleton.md`).
   ```bash
   # Single worker per the single-core cap.
   ./vendor/bin/pest tests/Browser --parallel=false
   ```
2. **Playwright lane (`E2E_SPECS`)** — for cross-framework flows, pixel-level visual-diff needs, or specs written before the Pest browser plugin was adopted. **Build-before-browser (CRITICAL):** this project serves built front-end artifacts. The command prepends `npm run build` so specs never run against stale assets, and the committed `playwright.config.*` `webServer.command` should also build-then-serve (e.g. `npm run build && php artisan serve`). The Playwright `webServer` block boots and tears down the app; do not start a server manually.
   ```bash
   # Only when E2E_SPECS=true. Excludes @visual (Gate 11 owns those).
   # --pass-with-no-tests: a project whose only specs are @visual-tagged matches zero here → skipped, not failed.
   npm run build && npx playwright test --grep-invert @visual --pass-with-no-tests --workers=$PROCESSES
   ```

**Neither lane replaces the other.** Pest browser testing is the better default for NEW authenticated-flow specs on this stack (less brittle, no re-implemented login), but standalone Playwright remains the right tool for cross-framework projects or pixel-level visual-diff assertions (Gate 11 already owns `@visual`). Do not migrate existing passing Playwright specs just to consolidate tooling.

- **Pass:** every detected lane's command exits 0 (all functional specs green in that lane).
- **Fail (BLOCKING):** any functional spec in EITHER lane fails → block. A failing committed golden-path spec means a previously-verified workflow regressed.
- **Skipped:** neither `tests/Browser/*.php` nor `tests/e2e/*.spec.*` exist, OR incremental mode (`--changed-only`) — e2e is a full-suite check; mark `skipped (incremental mode)`.
- **not_evaluated (DEGRADED):** a lane's plugin/config is present but its runner can't launch — Playwright: browser binary missing (`npx playwright install` never run); Pest browser: `pestphp/pest-plugin-browser` in `composer.json` but its browser driver isn't installed. Surface as a prominent advisory per lane — NOT a silent pass — mirroring the mutation-testing not-available advisory.

## Output

After all gates complete, write `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` (AI-only artifact; structured YAML inside markdown for fast machine parse + grep-friendly status checks). Console summary remains for operator visibility.

### MANDATORY ARTIFACT — Stop hook enforces this

The Stop hook (`enforce-pre-commit-gates.sh`) blocks staged code commits unless this session has produced `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` at the repository root with `status: pass` (or with explicitly-acknowledged failures). Filename rules (mirrors v-build § MANDATORY FINAL ARTIFACT):

- Prefix MUST be the literal string `PRE_FLIGHT_REPORT_` followed by your session id and `.md`. No other variants.
- File MUST live at the repository root OR under `.v/artifacts/` (both are searched by the hook's `ARTIFACT_SEARCH_DIRS`); not under `.claude/` or other subdirectories.
- The file is consumed by hooks and downstream skills as a machine-readable record. A summary in chat is NOT a substitute — call the `Write` tool.
- Missing file or filename mismatch → the next staged commit is blocked; `wip:` commit messages are not exempt. Operator-visible failure mode: "pre-flight gates not satisfied for this session."

**File template (AI-optimized — minimal prose, structured fields):**

```markdown
<!-- v-pre-flight PASS template — `## Gates` and `## Blocking Failures`
     are required artifact headings per the Format rules section below (line
     numbers drift; cite sections). Do NOT rename. The duplicate at the
     FAIL-case template below is intentional. -->
# PRE_FLIGHT_REPORT
session: ${CLAUDE_SESSION_ID}
generated: <ISO timestamp>
Mode: <full|scoped>
status: pass
overall_summary: "<X> of <Y> gates passed"

## Gates

\`\`\`yaml
# gate numbers/names match the canonical Gate Execution Order table + references/gate-schema.md
- gate: 1
  name: PHP Tests
  status: pass
  evidence: "3500 tests, 0 failures, 12.4s"
- gate: 3
  name: Frontend Build
  status: pass
  evidence: "vite build, 12s, 238kb gzip"
- gate: 3.5
  name: Bundle Size
  status: pass
  evidence: "chunks (kB gzip): app.js:238.4 vendor.js:156.2 — no configured budget, no growth >10% vs prior report"
- gate: 4
  name: Lint
  status: pass
  evidence: "0 warnings (max-warnings=0 honored)"
- gate: 5
  name: TypeScript
  status: pass
  evidence: "tsc --noEmit, 0 errors"
- gate: 8
  name: Composer Audit
  status: pass
  evidence: "0 vulnerabilities"
- gate: 9
  name: NPM Audit
  status: pass
  evidence: "0 critical (HIGH advisory only)"
\`\`\`

## Blocking Failures

(none)

## Advisories

(none — or list non-blocking warnings here)

Overall Status: PASS
```

**File template — FAILURE case** (uses `[FAIL]` markers + `status: fail` for hook detection):

```markdown
<!-- v-pre-flight FAIL template — `## Gates` and `## Blocking Failures`
     are required artifact headings per the Format rules section below (cite
     sections, not line numbers — they drift). Do NOT rename. The duplicate
     above is the PASS-case template. -->
# PRE_FLIGHT_REPORT
session: ${CLAUDE_SESSION_ID}
generated: <ISO timestamp>
Mode: <full|scoped>
status: fail
overall_summary: "6 of 8 gates passed; 2 BLOCKING failures"

## Gates

\`\`\`yaml
- gate: 1
  name: PHP Tests
  status: pass
  evidence: "3500 tests, 0 failures"
- gate: 5
  name: TypeScript
  status: fail
  evidence: "3 errors"
  failures:
    - "src/Pages/Foo.tsx:15 — Property 'bar' does not exist"
    - "src/Hooks/useBar.ts:42 — Type 'number' not assignable to type 'string'"
\`\`\`

## Blocking Failures
- [FAIL] Gate 5 TypeScript: 3 errors

## Next Action
Fix TypeScript errors, re-run `/v-pre-flight`.

Overall Status: FAIL
```

**Format rules:**
1. A final **`Overall Status: PASS|FAIL`** line is REQUIRED and authoritative — the Stop hook (`check-review-artifact.sh`) reads ONLY the LAST `Overall Status:` line to detect FAIL/BLOCK; the legacy `^status:` anchor never matched it (`enforce-pre-commit-gates.sh:10-11`). Keep `status: pass|fail` for back-compat, but a report lacking `Overall Status:` can let a FAILING pre-flight clear the Stop gate. Also include a `Mode:` line.
2. `## Gates` header MUST be present (hook validation; `## Test Results` is alternative legacy header)
3. `[FAIL]` marker on failed gates in the Blocking Failures section (hook grep)
4. File size ≥1024 bytes (the pre-flight-specific Stop-hook floor at `check-review-artifact.sh:2351`; sub-1KB stub PASS reports are bounced)
5. YAML inside fenced ```yaml blocks for machine parse — no narrative prose

**Token savings vs prior format:** ~50-70% fewer lines on typical pass-runs (most prose was "all gates passed" boilerplate); ~30% on failure runs (failure detail still needs space, but structure is denser).

**Console summary (operator-facing, NOT written to the artifact):**

```
========================================
  PRE-FLIGHT RESULTS
========================================
[PASS] PHP Tests           3500 tests, 0 failures
[PASS] Frontend Build      completed in 12s
[PASS] Lint                0 warnings
[FAIL] TypeScript          3 errors
       src/Pages/Foo.tsx:15 — Property 'bar' does not exist
========================================
  BLOCKED: Fix TypeScript errors
========================================
```

## Non-Blocking Gates

Gate 11 (visual regression) is **non-blocking** — failures are reported but do NOT stop the pipeline.

Gate 11.5 (E2E / browser workflow specs) is **blocking** per lane: the Pest browser lane when `tests/Browser/*.php` exist AND the browser driver can launch; the Playwright lane when `tests/e2e/*.spec.*` exist AND the Playwright runner can launch. When a lane's runner cannot launch (browser binary/driver missing), that lane degrades to a prominent `not_evaluated` advisory — never a silent pass. Install browsers with `npx playwright install` (Playwright lane) to enable it. Both lanes are skipped entirely in incremental mode.

Gate 12 (mutation testing) is **conditionally blocking** — full engine-priority / zero-mutations logic lives in `### Gate 12: Mutation Testing` above. Summary:
- **When PEST_MUTATION, Infection (PHP), or Stryker (JS) is detected:** blocking with a minimum score threshold of 70% (parity across all three engines). Fail the gate if score < 70% on changed source WITH mutants actually generated — a changed unit that generates zero mutants is `skipped`, not a fail (see the zero-mutations case above).
- **When NONE of the three is detected:** report a prominent advisory: `mutation_testing: not_available — no mutation-testing capability detected (checked: Pest ≥3 --mutate, vendor/bin/infection, node_modules/.bin/stryker). Test quality cannot be independently verified. Upgrade Pest to ≥3, or install Infection/Stryker, to enable this gate.` This advisory does NOT fail the overall run but MUST appear prominently in the report under a `## Mutation Testing Advisory` section. Do NOT phrase this as "not_installed" on a Pest≥3 project — Pest-native mutation testing requires no install, so that wording would be factually wrong on exactly this operator's stack.

Gate 21 (migration rollback) is **conditionally blocking**:
- **When `.env.testing` exists with a configured database:** blocking. The `migrate:rollback && migrate` cycle is the most reliable reversibility check.
- **When no test database is configured:** non-blocking (informational only).
- Detection: `grep -q 'DB_DATABASE' .env.testing 2>/dev/null && echo "TEST_DB=true"`

For gate 12's Infection/Stryker engines, find changed PHP source files (exclude tests) — the Pest-native engine derives its own changed-class list inline in `### Gate 12` above (it needs FQCNs, not raw paths):
```bash
git diff --name-only HEAD -- '*.php' 2>/dev/null | grep -v test | tr '\n' ','
```

## Warning Aggregation

After all gates complete, aggregate non-blocking warnings across categories. (**Honesty note, ND-0716:** this whole section is ADVISORY — no hook parses `REVIEW-RECOMMENDED`/`SYSTEMIC-PATTERN`/`BASELINE-DEGRADED` and nothing machine-checks that the counting happened; the elevation labels exist for the operator and downstream skills reading the report. Do the counting anyway — skipping it is exactly the silent-quality-drift this note exists to name — but never present these labels as hook-enforced.)

| Condition | Elevation |
|-----------|-----------|
| Any single category has > 3 non-blocking warnings | Elevate to `REVIEW-RECOMMENDED` — flag in the report summary |
| Total non-blocking warnings across all categories > 10 | Elevate to `REVIEW-RECOMMENDED` — suggest running `/v-check` for a deeper audit |
| Any non-blocking warning pattern repeats in > 3 files | Flag as `SYSTEMIC-PATTERN` — likely needs a project-wide fix, not per-file fixes |
| Baseline-confirmed pre-existing failures > 25 (`BASELINE_HEALTH=degraded`) | Flag as `BASELINE-DEGRADED` — does not change pass/fail, but a noisy baseline can hide real regressions; suggest a dedicated test-health session (see `v-core-pre-existing.md`) |

Include the aggregation summary at the top of the `PRE_FLIGHT_REPORT` under a `## Warning Summary` section (before gate results) when any elevation triggers.

## On Failure

Show the full output for every failing gate. Continue through subsequent blocking gates so the user sees the full set of blockers in one pass, then fail the overall run.

## Progress Checklist (copy into your response, check off as you go)

```markdown
## Pre-flight progress

Mirror the section headers from this skill's body workflow (the 8 quality gates documented below) into your response — one checkbox per ### Step / ### Phase / ### Gate as you progress. The body workflow is the single source of truth for what gates exist; treat the checklist as a render of THAT structure, not a parallel definition.

Example (replace with your actual sections as you go):
- [ ] Step 1: <skill-specific name>
- [ ] Step 2: <skill-specific name>
- ...
- [ ] Final: <output artifact written>
```

This avoids drift between the checklist and the body workflow when the body changes — only one source of truth (the body's `### Step N:` headers) needs to stay current. Operator-facing visibility comes from the AI rendering the actual current sections into its response, not from a hard-coded duplicate.

Operators reading the response know exactly which gates ran and which (if any) were skipped. AI updates checkboxes as gates execute.

## Gotchas

| # | Symptom | Root cause | Rule |
|---|---|---|---|
| 1 | "All gates passed" reported but `npm audit` was skipped because output was noisy | Audit gate output parsing incorrectly classified noise as pass | `npm audit --audit-level=critical` exit code is the truth; parsing output text is unreliable |
| 2 | TypeScript errors auto-remediated but real bugs masked by type-coercion fixes | TS auto-remediation iteration cap not enforced | Cap at 3 iterations per `~/.claude/skills/references/v-exec-typescript.md`; beyond that, log + fail (don't keep coercing) |
| 3 | Pre-existing test failures cause pre-flight to fail on unchanged code | Baseline not captured | Capture failure baseline before changes; pre-flight FAILs only on NEW failures, per `~/.claude/skills/references/v-core-pre-existing.md` |
| 4 | Bundle-size budget violation reported but project has no budget config | Default budget applied incorrectly | Budget is project-defined (in `package.json`/`vite.config.js`); if no budget exists, this gate is N/A — log and skip, don't fabricate a default |
| 5 | Re-running pre-flight produces different verdicts | Test parallelism flakiness | Use `--processes=1` for deterministic test runs in pre-flight; or run flaky tests 3x and require all-green |
| 6 | PRE_FLIGHT_REPORT written but Stop hook reverts session anyway | Filename mismatch (no SID, wrong location) | Filename MUST be `PRE_FLIGHT_REPORT_${CLAUDE_SESSION_ID}.md` exactly, at repo root |
## Idempotency

**Not read-only — bounded and convergent.** Re-running produces a fresh PRE_FLIGHT_REPORT, but this skill CAN mutate project state: Gate 5's TypeScript auto-remediation edits source files (up to 3 iterations), and the report artifact itself is written to the repo root on every run. This is safe to re-run because the mutation is bounded (capped iterations, reported original-vs-remediated counts) and convergent (re-running after a clean pass is a no-op) — but "no mutations" is false; do not describe this gate as read-only.
