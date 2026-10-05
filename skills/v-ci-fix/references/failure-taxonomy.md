# v-ci-fix CI failure taxonomy

When triaging a red CI run, classify the failure into ONE of the
13 buckets below before deciding the fix strategy. Each bucket
has signature log patterns, root-cause questions, fix strategies,
and a ship-or-defer rule.

Misclassification is the most expensive bug in CI repair —
fixing a "race condition" with a snapshot update wastes time AND
masks the real failure. Spend 2-5 minutes on classification.

**Two vocabularies.** These 13 numbered buckets are the fine-grained
diagnostic classes (used in commit messages + the decision tree). The
`CI_FIX_SUMMARY` and `v-ci-fix-failures.md` log roll them up into 6
coarse SUMMARY classes. Record BOTH. Mapping (**this file is the sole
authoritative copy** — SKILL.md's inline bucket list was deleted on
2026-08-02 after it silently drifted to "10 buckets"; it now cites this
file instead. Do not reintroduce a copy there or anywhere else):

| Summary class | Buckets |
|---|---|
| `FLAKY`     | 4, 7 |
| `DEP-DRIFT` | 3, 5 |
| `TEST-BUG`  | 1, 6, 11 |
| `CONFIG`    | 2, 9, 10, 13 |
| `CODE-BUG`  | 12, plus any other bucket rooted in production code |
| `INFRA`     | 8, plus any bucket deferred to operator |

---

## Bucket 1 — Snapshot mismatch

**Symptom:** Test runner reports "snapshot does not match",
"received differs from snapshot", or "obsolete snapshot."

**Detection patterns (greps against the CI log).** Anchor to error
context, NOT to the test-runner's summary line — `Snapshots: 5 passed, 0 failed`
contains the word `failed` and would false-positive every passing run.

```bash
# Match snapshot diff/mismatch error lines, not summary stats lines
grep -iE "snapshot.*(does not match|did not match|mismatched|is obsolete|differs from)" "$LOG"
grep -iE "received differs from snapshot|expected snapshot.*received|snapshot test failed" "$LOG"
grep -iE "[0-9]+ snapshot.*(failed|obsolete)" "$LOG" | grep -viE "^\s*Snapshots:.*0 failed"
```

**Common test runners:**
- Jest: `Snapshot did not match`
- Vitest: `Snapshot \`X\` mismatched`
- Pest: `__snapshots__/` directory diff
- pytest-snapshot: `assert_match_snapshot` failure

**Root-cause questions:**
1. Did the rendered output legitimately change (refactor, copy
   change, locale change)?
2. Or did the test code shift assertion semantics (mock changed,
   timezone shift, etc.)?
3. Was the snapshot ever reviewed, or was it auto-accepted from
   a previous AI-generated test?

**Fix strategy:**

- Read the snapshot diff carefully BEFORE updating. The diff is
  the new ground-truth claim.
- If the change is intentional (new feature, copy change, layout
  fix): regenerate snapshot with `--updateSnapshot` /
  `--update-snapshots`, commit the snapshot file change, and
  call out the diff in the commit message.
- If the change is unintentional (test broke because mock data
  shifted, timezone problem, randomized ID): fix the underlying
  determinism issue, do NOT update the snapshot.

**Ship-or-defer:** ship if change is intentional and reviewed.
Defer to operator if the diff is large (>50 lines) or covers
multiple unrelated surfaces — that's a refactor, not a CI fix.

**Anti-pattern:** auto-accepting all snapshot diffs ("just run
update-snapshots and push") without reading them. This is the
most common CI-fix-by-AI failure mode.

---

## Bucket 2 — Environment-specific (Linux vs macOS, Node 18 vs 20, etc.)

**Symptom:** Test passes locally but fails in CI; or passes on
one matrix runner but fails on another.

**Detection patterns:**

```bash
# Matrix-runner divergence
grep -iE "Linux|Ubuntu|macos|windows" "$LOG" | head -5
# Locale issues
grep -iE "encoding|UTF-8|charset|locale" "$LOG"
# Path separators
grep -E "C:\\\\|/usr/|/var/|/home/" "$LOG"
# Node/Python version
grep -iE "Node v?[0-9]+|Python [0-9][.][0-9]+|engines" "$LOG"
```

**Common signatures:**
- File path tests: forward vs backslash separator
- Date/time tests: timezone differences (CI runs UTC; local often
  isn't)
- Floating-point precision: arch-specific (x86_64 vs arm64)
- Default locale: CI is `C` or `en_US.UTF-8`, local may be different
- Line endings: `\r\n` (Windows) vs `\n` (Unix)
- Node API differences: e.g., `crypto.randomUUID()` added in 14.17

**Root-cause questions:**
1. What does CI's environment actually look like? (`echo $LANG`,
   `node --version`, `uname -a`)
2. Is the test asserting on environment-coupled values without
   normalizing?
3. Is there a test setup helper that should set timezone / locale
   / line endings explicitly?

**Fix strategy:**

- Normalize the assertion to be environment-agnostic:
  - Dates: assert on UTC ISO strings, never local-formatted dates
  - Paths: use `path.normalize()` or compare segments, not strings
  - Numbers: assert on rounded values or use `.toBeCloseTo()`
  - Locales: explicitly set `process.env.LC_ALL = 'C'` in test setup
- If the production code itself has the env-coupling, fix the
  code (not just the test) — or ship a CI-only env override
  with a comment explaining why.

**Ship-or-defer:** ship the normalization fix immediately.
Production-code env-coupling is a real bug; defer that to a
proper feature branch.

---

## Bucket 3 — Version drift (lockfile out of sync)

**Symptom:** "Module not found" / "Cannot find package" / "Invalid
lockfile" / hash mismatch between lockfile and manifest.

**Detection patterns:**

```bash
grep -iE "(yarn|npm|pnpm) (install|ci) failed" "$LOG"
grep -iE "lockfile.*out of (sync|date)|invalid.*lockfile" "$LOG"
grep -iE "package-lock\\.json|yarn\\.lock|pnpm-lock\\.yaml.*conflict" "$LOG"
grep -iE "composer\\.lock.*out of (sync|date)" "$LOG"
grep -iE "could not (resolve|find).*package" "$LOG"
```

**Common signatures:**
- `package.json` modified but `package-lock.json` not regenerated
- Merge conflict resolved by hand-editing the lockfile
- Branch added a dep but lockfile committed from another branch
- `npm install` used locally instead of `npm ci` in CI

**Root-cause questions:**
1. When was the lockfile last regenerated?
2. Does `git log -- package-lock.json` show the lockfile changing
   in lockstep with `package.json`?
3. Is there a recent merge commit that may have re-introduced an
   old lockfile?

**Fix strategy:**

- Regenerate the lockfile from scratch:
  - npm: `rm package-lock.json && npm install` (or `npm ci`
    failure should auto-suggest this)
  - yarn: `yarn install --frozen-lockfile=false` then commit
  - pnpm: `pnpm install --no-frozen-lockfile`
  - composer: `composer update --lock`
- Commit the lockfile change separately with message: "Regenerate
  lockfile after dep change in {commit}"
- Verify `npm ci` (or equivalent) passes locally before pushing.

**Ship-or-defer:** ship. Lockfile drift is a CI-blocker and
delaying makes it worse (more deps may drift in parallel).

**Anti-pattern:** running `npm install` (which mutates the
lockfile based on local resolution) when CI uses `npm ci` (which
requires lockfile to be exact). Always use the CI's install
command locally for verification.

---

## Bucket 4 — Race condition / flaky test

**Symptom:** Test passes on retry but failed initially; passes
when run in isolation but fails in the suite.

**Detection patterns:**

```bash
grep -iE "(timed out|timeout).*[0-9]+ms" "$LOG"
grep -iE "flaky|intermittent|race condition" "$LOG"
# Asymmetric pass/fail across retries (TTY-independent — works on CI logs)
grep -iE "(retry|attempt) [0-9]+.*(pass|fail)" "$LOG"
grep -iE "test (retried|rerun).*[0-9]+ time" "$LOG"
```

**Common signatures:**
- Async assertion without proper `await` / `waitFor`
- Shared global state between tests (database, in-memory cache,
  process env)
- Order-dependent test (works in isolation, fails in suite)
- Timer / setTimeout / setInterval not mocked

**Root-cause questions:**
1. Does the test reach across `beforeEach` boundaries
   (e.g., `let cached;` declared at file scope)?
2. Is there an async operation that the test doesn't await?
3. Are timers used? Real timers in tests cause flakiness;
   `vi.useFakeTimers()` / `jest.useFakeTimers()` fixes it.
4. Does the test depend on database state that another test
   might mutate concurrently?

**Fix strategy:**

- Use proper async patterns (`waitFor`, `await`, `findBy*` queries
  in Testing Library).
- Reset shared state in `beforeEach` (clear DB, clear in-memory
  caches, reset module state).
- Mock timers explicitly.
- If the test must run in order, use `describe.serial` /
  `--runInBand` / `--no-parallel` — but mark this as tech-debt;
  serial test suites scale poorly.

**Ship-or-defer:** ship the fix. Flaky tests degrade trust in CI
for everyone.

**Anti-pattern:** retrying the failed job hoping it passes the
next time. This is the #2 most common CI-fix-by-AI failure mode
(after blind snapshot acceptance).

---

## Bucket 5 — Lockfile / version pin mismatch

**Symptom:** Subset of Bucket 3 with an explicit version conflict
across branches. Different from bucket 3 in that the lockfile
itself is structurally valid; it just pins a different version
than another branch's lockfile.

**Detection patterns:**

```bash
grep -iE "version conflict|incompatible.*peer" "$LOG"
grep -iE "expected version.*found" "$LOG"
```

**Common signatures:**
- Two branches both bumped a transitive dep to different versions;
  merge conflict in lockfile resolved badly
- Peer dep version constraint violated by a transitive bump

**Fix strategy:**

- Run `npm ls {package}` (or equivalent) to see the resolved
  version tree.
- Pin the offending package in `package.json` with `overrides`
  (npm 8+) / `resolutions` (yarn) if needed.
- Re-run lockfile generation, commit.

**Ship-or-defer:** ship. Pinned version overrides should have a
comment explaining the constraint.

---

## Bucket 6 — Mock / fixture issue

**Symptom:** Test fails with "expected X, received Y" where Y is
clearly stale data (e.g., a date 6 months old, a status that's
been deprecated, a user role that no longer exists).

**Detection patterns:**

```bash
grep -iE "expected.*to (be|equal).*received" "$LOG" | head -5
grep -iE "([0-9]{4}-[0-9]{2}-[0-9]{2})" "$LOG"  # dates in error output
grep -iE "fixture|seed|factory" "$LOG"
```

**Common signatures:**
- HTTP mock returns canned response that's now obsolete
- Database fixture has a status / role / enum value that was
  removed
- Stripe / GitHub / external-API recording is stale (test cassette
  doesn't match new API response shape)

**Root-cause questions:**
1. When was the fixture / mock last updated?
2. Did the production code change its expected response shape?
3. Is the mock too tightly coupled (asserts exact JSON) when a
   schema-shape assertion would be more durable?

**Fix strategy:**

- Update the fixture / mock to match current production reality.
- For external-API recordings (VCR / nock cassettes / Stripe test
  fixtures): re-record against the live test environment.
- Loosen overly-specific assertions where appropriate (assert on
  schema shape, not exact values).

**Ship-or-defer:** ship. Stale mocks are a CI velocity tax.

---

## Bucket 7 — Network / external service flake

**Symptom:** Failure mentions DNS, timeout, connection refused,
or 5xx from an external service the test doesn't own.

**Detection patterns:**

```bash
grep -iE "ECONNREFUSED|ETIMEDOUT|ENOTFOUND|getaddrinfo" "$LOG"
grep -iE "5[0-9][0-9].*server error|503.*unavailable" "$LOG"
grep -iE "rate limit|429.*too many" "$LOG"
```

**Common signatures:**
- npm registry timeout
- GitHub API rate limit (without authenticated token)
- Stripe test webhook unreachable
- DNS resolution failure (rare but happens on CI infra)

**Fix strategy:**

- For transient flakes: add a retry-with-backoff to the install /
  CI command (`npm ci --fetch-retry-mintimeout=...`).
- For persistent flakes: use a private registry mirror (Verdaccio),
  cache deps in CI, or vendor the dep.
- For rate limits: ensure CI has authenticated token available.
  GitHub API + GH_TOKEN is a common gap.

**Ship-or-defer:** transient → ship retry. Persistent → defer to
infra work; CI repair isn't the right vehicle.

**Anti-pattern:** retrying without diagnostic — if 3 retries all
fail, it's not a flake, it's a real outage or infra bug.

---

## Bucket 8 — Secret / credential issue

**Symptom:** Failure mentions "401", "unauthorized", "missing
secret", "API key not found", or env-var-related "undefined".

**Detection patterns:**

```bash
grep -iE "(401|403).*unauthorized|forbidden|access denied" "$LOG"
grep -iE "api[_ ]?key.*(missing|undefined|empty)" "$LOG"
grep -iE "secret.*not found|env.*not (set|defined)" "$LOG"
grep -iE "GITHUB_TOKEN|GH_TOKEN|STRIPE_KEY|.*_TOKEN" "$LOG"
```

**Common signatures:**
- New secret added to code, not yet added to GitHub Actions
  secrets / repo settings
- Secret expired (e.g., Stripe test keys rotated)
- Secret leaked in PR (CI auto-disabled secret access on forks)
- Branch protections strip secret access in matrix jobs

**Fix strategy:**

- Verify the secret exists in repo settings (GitHub: Settings →
  Secrets and variables → Actions).
- For PR-from-fork: secrets are deliberately unavailable. The
  fix is either to allow the secret on PRs (security tradeoff)
  or to mock the dependency for PR runs.
- For expired secrets: rotate in the upstream service first,
  then update repo secret.

**Ship-or-defer:** ship the secret addition / rotation. Defer if
the failure is on a fork-PR where secrets are intentionally
unavailable — that's a workflow design issue, not a fix-now bug.

**Anti-pattern:** committing a secret to the repo to "fix" CI.
This is a security incident, not a CI fix.

---

## Bucket 9 — Cache / stale build artifact

**Symptom:** Test passes after `clean install` locally; CI fails
with errors that look like missing or outdated build outputs.

**Detection patterns:**

```bash
grep -iE "(stale|outdated).*cache" "$LOG"
grep -iE "cannot find module.*built|cannot find module.*dist" "$LOG"
grep -iE "schema.*outdated|migration.*not run" "$LOG"
```

**Common signatures:**
- CI cached `node_modules` from a prior run; new dep not installed
- `tsc --build` cached output from a prior commit
- Tailwind purge cache stale, classes missing in CSS
- Database migrations not re-run (test DB carrying stale schema)

**Fix strategy:**

- Bust the relevant cache key (often the lockfile hash or
  `package.json` hash).
- For schema-related: ensure CI runs `migrate:fresh` (or
  equivalent) on test DB.
- For build artifacts: prefix the build step with a clean
  (`rm -rf dist .next .build`) when in doubt.

**Ship-or-defer:** ship. Cache busts are cheap.

---

## Bucket 10 — Matrix-specific (one runner, not all)

**Symptom:** CI matrix has e.g. {Linux, macOS, Windows} × {Node
18, 20} = 6 jobs. One specific cell fails; others pass.

**Detection patterns:**

```bash
# Compare which matrix cells passed vs failed
grep -B 1 "✓\\|✗\\|FAIL" "$LOG" | head -30
```

**Common signatures:**
- Bucket 2 (env-specific) when only one OS/arch combo fails
- Bucket 8 (secret) when matrix runners have different access
- Bucket 9 (cache) when matrix uses keyed caches that diverge
- A genuinely-runner-specific bug (rare; usually one of the above
  in a narrow form)

**Fix strategy:**

- Identify which matrix cell is failing.
- Apply the appropriate Bucket 1-9 fix targeted to that cell.
- If the failure is genuinely runner-specific (e.g., works on
  Node 18 but not 20): either fix the code to work on both, or
  drop the failing cell from the matrix with a comment
  explaining why.

**Ship-or-defer:** ship if the fix is targeted. Defer matrix
restructuring to a separate task.

---

## Bucket 11 — Coverage-threshold regression (untested new file drags an aggregate gate below its floor)

**Symptom:** A coverage gate (global or per-file, in whatever tool the
project uses — Vitest thresholds, Jest `coverageThreshold`, a custom
PHP coverage script, pytest-cov `--cov-fail-under`) fails immediately
after a commit that shipped a new page/file/command with zero or
near-zero test coverage. The failing metric itself is otherwise
uninteresting — no logic bug, no environment quirk — the aggregate
number just moved because the denominator grew without a matching
numerator.

**Detection patterns (confirmed against logged entries in
`v-ci-fix-failures.md` — do not narrow to only the exact wording
below; the underlying shape is "an aggregate coverage number crossed
its configured floor," and tooling varies):**

```bash
# Vitest / Jest-style aggregate threshold message
grep -iE "coverage for (functions|branches|lines|statements) \([0-9.]+%\) does not meet global threshold" "$LOG"
grep -iE "does not meet global threshold" "$LOG"
# Custom per-file coverage scripts (e.g. scripts/check-*-coverage.php)
grep -iE "per-file coverage below [0-9]+%" "$LOG"
grep -iE "coverage below [0-9]+%" "$LOG"
# pytest-cov
grep -iE "required test coverage of [0-9.]+% not reached" "$LOG"
```

**Common signatures:**
- A new `resources/js/pages/**/*.tsx` (or equivalent) ships with zero
  smoke-render test, dragging the global function/branch/line average
  below the configured gate.
- A new `app/Console/Commands/*.php` (or any new backend file) ships
  with zero test coverage, tripping a per-file coverage floor.
- The failure often only surfaces AFTER an unrelated failure earlier
  in the same job is fixed — many coverage-check scripts run as a
  later step and never execute while an earlier step is still red
  (composer's "stop on first script error" is the common cause; see
  an entry logged 2026-07-06).

**Root-cause questions:**
1. Which specific file(s) sit at or near 0% in the coverage report? (Scan
   the coverage table for 0%-or-near-0% rows before assuming broad new
   test-writing is needed — usually 1-2 untested files are the whole gap.)
2. Is there a sibling test file this new file should have been added
   to (project convention — e.g. one shared smoke-test suite per page
   directory), rather than a brand-new test file per component?
3. Has this exact pattern recurred in this project before? (Check this
   log — three occurrences in the same project is common for this
   bucket, since the same "ship a new page without its smoke test"
   habit repeats until a standing rule is adopted.)

**Fix strategy:**
- Add a smoke-render (frontend) or minimal-coverage (backend) test for
  the specific under-covered file(s) identified above — mirror an
  existing sibling test's pattern rather than inventing a new shape.
- Do NOT chase the number with tautological tests
  (`expect(true).toBe(true)`, rendering with zero assertions just to
  execute lines) — that satisfies the gate without satisfying its
  intent; cross-check new tests against
  `~/.claude/skills/references/v-tdd-anti-patterns.md` before shipping.
- If the same project trips this bucket a third time, recommend a
  standing rule to the operator (e.g. "every new `resources/js/pages/**/*.tsx`
  ships a smoke-render test in the SAME commit") rather than only
  fixing the immediate instance again.

**Ship-or-defer:** ship — this is pure test-writing with no production
risk. Defer only if the untested file is large and the required
behavioral test needs domain knowledge beyond a smoke-render (that's a
TEST-BUG session, not a CI-fix-cycle-sized task).

**Anti-pattern:** treating this as a CODE-BUG and "fixing" the
threshold number down instead of adding the missing test — that
just moves the debt, it doesn't pay it off.

---

## Bucket 12 — Registry / schedule drift (parallel hand-maintained lookup falls out of sync with its source-of-truth)

**Symptom:** A hand-maintained registry/lookup table (slug → builder,
id → handler, route → resolver) is missing an entry for a key that a
SEPARATE schedule or source-of-truth already considers active/released.
Often TIME-BOMB shaped: the code was correct-looking and every test
passed at author time, and the failure only appears weeks or months
later, purely because calendar time advanced past a date-gated
condition (a release schedule, a feature-flag rollout date) that
exposes the missing registry entry. Distinct from Bucket 2
(environment-specific) — nothing about the environment changed; only
the clock did. Also distinct from ordinary registry/schema drift that
fails immediately at commit time (that's typically Bucket 6, stale
mock/fixture) — this bucket is specifically the delayed-onset case.

**Detection patterns (confirmed against the logged entry in
`v-ci-fix-failures.md`):**

```bash
grep -iE "no [a-z0-9_]+ mapping for" "$LOG"
grep -iE "no (mapping|entry|handler) (for|found)" "$LOG"
grep -iE "unmapped (slug|key|id|route)" "$LOG"
```

**Common signatures:**
- A content/release schedule (e.g. `ReleaseSchedule::SCHEDULE`)
  and a SEPARATE hand-maintained registry (e.g.
  `FeedController::SCHEDULED_ITEM_META`) that must contain a
  matching entry for every released item — nothing enforces
  referential completeness between the two.
- The registry's own doc-comment may already warn about this exact
  drift risk (a signal this is a known, accepted-but-unenforced
  footgun in the codebase, not a novel bug).
- Was PASSING at commit time because the schedule hadn't yet marked
  the item as released; started failing only once the session's
  current date passed the release gate.

**Root-cause questions:**
1. What is the schedule/source-of-truth, and what is the SEPARATE
   registry that must mirror it? Confirm both by reading the failing
   test, not just the error message.
2. Are there other near-term schedule entries that lack a matching
   registry entry RIGHT NOW, which will trip this same failure the
   next time calendar time advances past THEIR release gate? Grep for
   the schedule's other entries and cross-check each has a registry
   counterpart before closing this out — this is the preemptive check
   that turns a recurring bucket into a one-time fix.
3. Could the registry be derived programmatically from the schedule
   instead of hand-maintained in parallel? (Worth flagging as a
   follow-up refactor recommendation — out of scope for the CI-fix
   itself, since it's a design change, not a fix-forward.)

**Fix strategy:**
- Add the missing registry entry, mirroring the shape of existing
  entries exactly.
- Run the preemptive check from root-cause question 2 and flag (don't
  silently fix) any other near-term entries missing their registry
  counterpart, so the operator can decide whether to fix them now or
  accept the risk.

**Ship-or-defer:** ship the missing entry now — it's a small, safe,
targeted fix. Defer the "derive the registry automatically" refactor
suggested above; that's a design change requiring its own review, not
a CI-repair action.

**Anti-pattern:** fixing only the one reported key without checking
for sibling near-term entries with the same gap — this bucket's
defining trait is that it re-triggers on a schedule, so a single-key
fix without the preemptive sweep just delays the next occurrence
rather than closing the class.

---

## Bucket 13 — Test-runner internal warning fails the build with zero real test failures (silent exit-1)

**Symptom:** A CI job running the test suite (PHPUnit/Pest, or an
equivalent runner with a "fail on internal warning" mode) exits
non-zero while its own summary line reports `0 failed` — e.g. `Tests:
N risky, N skipped, N passed` followed immediately by `Process
completed with exit code 1`. No failed-test block, no stack trace, no
visible warning text anywhere in the log — the job fails and gives no
reason. Distinct from Bucket 9 (cache/stale artifact): the tests
genuinely ran and genuinely passed; the runner itself decided to fail
the *process* over an issue unrelated to any test's correctness.

**Detection patterns:**

```bash
# The tell: a clean summary line immediately followed by a non-zero exit.
grep -A2 -iE "Tests:.*[0-9]+ passed" "$LOG" | grep -iE "0 failed|passed \(" 
grep -iE "Process completed with exit code 1" "$LOG"
# Confirm no actual FAILED/ERROR block exists anywhere in the same job's log
grep -ciE "^\s*FAILED\s|Failed asserting" "$LOG"   # expect 0 for this bucket
```

**Root cause (confirmed instance — Pest + PHPUnit, 2026-08):** PHPUnit's
`failOnPhpunitWarning` XSD default is `true` (every other `failOn*`
flag defaults `false` — this one alone defaults `true`), and it is
tripped by `TestRunnerWarningTriggered`/`PhpunitWarningTriggered`
events that are **internal to the runner**, not tied to any test's
assertions. Two compounding facts make this silent instead of loud:
1. Pest's own compact printer never renders these event categories
   (a Pest limitation, not a PHPUnit one) — `--display-warnings` /
   `--display-errors` / `--display-notices` do NOT surface them
   because those flags cover *test-level* issues, and there is no
   `--display-phpunit-warnings` CLI flag in PHPUnit at all.
2. The concrete trigger in the confirmed instance: Pest's `Coverage`
   plugin (`vendor/pestphp/pest/src/Plugins/Coverage.php
   handleArguments()`) ALWAYS appends its own `--coverage-php
   <internal-path>` to the forwarded argument list whenever the bare
   `--coverage` flag is present — it filters `--coverage`/`--min`/
   `--exactly`/`--only-covered` out of the passthrough args but does
   **not** filter `--coverage-php`. A CI command that passes both
   `--coverage` AND an explicit `--coverage-php=<custom-path>` (a
   completely reasonable pattern for a project that shards coverage
   across parallel jobs and needs a per-shard output path) ends up
   invoking PHPUnit with `--coverage-php` specified twice, which
   PHPUnit rejects with `Option --coverage-php cannot be used more
   than once` — a `TestRunnerWarningTriggered` event, which
   `failOnPhpunitWarning` then turns into shell exit code 1 with zero
   test failures.

**How to actually SEE the swallowed warning (required before fixing —
do not guess):** re-run the exact failing shard/command with
`--log-events-text=<file>` appended (works even combined with `-d
pcov.enabled=1` and `--coverage-php`). This streams every raw PHPUnit
event to a file regardless of which printer is active, bypassing
Pest's printer entirely. Grep the result for `Triggered Warning`:

```bash
php -d pcov.enabled=1 vendor/bin/pest <same args as CI> \
  --log-events-text=/tmp/events.txt
grep -n "Triggered Warning\|Test Runner Started\|PHPUnit Finished" /tmp/events.txt
```

A warning appearing BEFORE the `Test Runner Started` line whose text
contains "No tests found in class" is a harmless, self-purged
Pest artifact (`Pest\Subscribers\EnsureIgnorableTestCasesAreIgnored`
removes it from the result collector at `Started` — confirmed by
reproducing a suite with ONLY that warning present and observing
`PHPUnit Finished (Shell Exit Code: 0)`). Any OTHER warning text is
the real cause — Pest's purge subscriber only matches that one exact
substring.

**Fix strategy:**
- Reproduce locally FIRST with the runner's exact flags (including
  `--coverage`/`--shard`/DB driver) plus `--log-events-text` — do not
  patch blind. A local run missing one of these flags (e.g. no
  `--coverage`, no real MySQL) will NOT reproduce a coverage-path or
  driver-specific instance of this bucket and will falsely clear it.
- For the confirmed Pest `--coverage` + `--coverage-php` collision:
  drop the bare `--coverage` flag from the CI command and keep only
  `--coverage-php=<path>` — it is a native PHPUnit option and does not
  route through Pest's `Coverage` plugin at all, so no duplicate
  injection occurs. Verify the resulting `--coverage-php` artifact is
  still a valid serialized `CodeCoverage` object (`include`
  it and check `instanceof
  SebastianBergmann\CodeCoverage\CodeCoverage`) before trusting the
  fix — don't just trust a green exit code.
- This is legitimately a CI-config fix, not an application-code fix —
  the workflow's own flag combination is the defect. It does not
  violate the "prefer fixing code over CI config" rule, which exists
  to stop reflexive workflow edits masking real code bugs; here the
  code and tests are correct and the invocation itself is wrong.

**Ship-or-defer:** ship — this is a narrowly-scoped, verifiable CI
command fix with no product-code risk. Defer only if the swallowed
warning text (once surfaced via `--log-events-text`) points at
something environment/infra-specific this skill can't fix (e.g., a
genuinely missing coverage driver) rather than a CLI flag collision.

**Anti-pattern:** adding `--do-not-fail-on-phpunit-warning` (or
`failOnPhpunitWarning="false"` in phpunit.xml) as a first resort. That
silences the entire warning category project-wide, including future
real ones, instead of fixing the one flag collision that's actually
firing. Only reach for a blanket suppression after `--log-events-text`
shows the warning is something genuinely unfixable at the invocation
level.

---

## Triage decision tree

**Order matters.** Run from longest-fingerprint-first to shortest
match — earlier checks would otherwise false-positive on lines
that contain the keyword but aren't actually that bucket. (E.g.,
`Snapshots: 5 passed, 0 failed` should NOT route to Bucket 1.)

```
1. Does the failure mention auth (401/403, "unauthorized",
   "forbidden", "access denied"), missing env var, or "secret not
   found"?
   → Bucket 8 (Secret / credential)

2. Does the failure mention DNS (ECONNREFUSED, ENOTFOUND), 5xx,
   or rate limit (429, "too many requests")?
   → Bucket 7 (Network / external service)

3. Does the failure mention "lockfile out of sync", "version
   conflict", "could not resolve package", or "incompatible peer"?
   → Bucket 3 (Version drift) — if the lockfile structure is
   valid but pins differ across branches, treat as Bucket 5
   (subset of Bucket 3, same fix path)

4. Does the failure happen only on one matrix cell?
   → Bucket 10 (Matrix-specific) — apply 1-9 to that cell

5. Does the failure mention "timed out", "flaky", "intermittent",
   "race condition", or pass on retry?
   → Bucket 4 (Race condition / flaky)

6. Does the test fail with stale-looking values (old dates older
   than current quarter, deprecated enums, removed columns)?
   → Bucket 6 (Mock / fixture)

7. Does the test pass with `rm -rf node_modules && npm ci` locally
   but fail on CI with a cached build?
   → Bucket 9 (Cache)

8. Does the test pass locally but fail on CI with environment
   differences (path, locale, timezone, Node version)?
   → Bucket 2 (Environment-specific)

9. Does the failure mention "snapshot does not match", "received
   differs from snapshot", or "snapshot is obsolete"?
   → Bucket 1 (Snapshot mismatch). Do NOT classify as Bucket 1
   based on the test-runner's summary line ("Snapshots: N passed,
   M failed") — that's status, not a failure indication.

10. Does the failure mention "does not meet global threshold",
    "per-file coverage below N%", or "required test coverage of N%
    not reached"?
    → Bucket 11 (Coverage-threshold regression). Confirm a specific
    0%-or-near-0% file in the coverage table before writing new
    tests — don't chase the aggregate number blind.

11. Does the failure mention "no mapping for", "no entry for", "no
    handler for", or an unmapped slug/key/id in a hand-maintained
    registry that's separate from a schedule/source-of-truth?
    → Bucket 12 (Registry / schedule drift). Check for other
    near-term schedule entries missing the same registry counterpart
    before closing out.
```

If none match cleanly, the failure may be a NEW class — document
in `CI_BLOCKER_*.md` and ask the operator before guessing.

Note Bucket 5 (lockfile pin mismatch) intentionally folds into
Bucket 3 here — both have the same fix path (regenerate lockfile
+ commit + verify with `npm ci`).

## After the fix

Before pushing:

1. **Verify locally** with the same command CI runs (e.g., `npm ci`
   then `npm test`, not just `npm install` and `npm test`).
2. **Read the diff** — does it match the bucket's fix strategy?
3. **Commit message** names the bucket explicitly (e.g.,
   "ci-fix: bucket 3 — regenerate package-lock after axios bump").

## Update cadence

Add a new bucket here when a CI failure mode emerges that doesn't
fit any of the 12. Three audits showing a recurring pattern
warrants a new bucket. Don't dilute the taxonomy with one-off
exotic failures.

Last update: 2026-08-02 (added Bucket 11 — Coverage-threshold regression — and Bucket 12 — Registry / schedule drift — both backfilled from `v-ci-fix-failures.md` log entries that had been carrying free-form labels with no bucket number, defeating the cross-session pattern-matching the "three audits" rule above and SKILL.md Step 5b depend on; updated the summary-class mapping table and decision tree to match. Bucket content otherwise last substantively revised 2026-04-29).
