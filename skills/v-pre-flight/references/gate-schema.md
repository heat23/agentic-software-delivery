# v-pre-flight Gate Result Schema

Formal specification of every gate's pass/fail conditions,
evidence format, and elevation triggers. The PRE_FLIGHT_REPORT
artifact MUST include a status entry for every gate that was
applicable to the detected stack.

## Status taxonomy

Each gate produces one of these status values. **Canonical spelling (ND-0716): `pass` / `fail`** —
this matches the SKILL.md worked templates, the dominant production artifact corpus, and the
hook parsers (`enforce-pre-commit-gates.sh` matches `status: fail(ed)` as a whole token). The
legacy long forms `passed` / `failed` are ACCEPTED synonyms on read (parsers match both) but new
reports must emit the short forms — one spelling, no per-model drift. The multi-word states
(`failed_non_blocking`, `skipped`, `not_evaluated`) have exactly one spelling.

| Status | Meaning | Affects exit code? |
|---|---|---|
| `pass` (legacy synonym: `passed`) | Gate ran and all assertions cleared | No |
| `fail` (legacy synonym: `failed`) | Gate ran and at least one assertion didn't clear | **Yes — pre-flight fails** |
| `failed_non_blocking` | Gate ran, didn't clear, but is configured non-blocking (gate 11 + conditional 12, 21, 22) | No (warns only) |
| `skipped` | Gate's preconditions weren't met (tool not detected, no relevant changed files) | No |
| `not_evaluated` | Gate is applicable but couldn't run (env error, command unavailable) | **Yes — surface as ambiguous** |

`skipped` and `not_evaluated` are NOT the same:
- `skipped` is intentional (e.g., no Python files changed, so don't run mypy)
- `not_evaluated` is unintentional (e.g., the runner can't find `mypy` even though `pyproject.toml` exists)

The PRE_FLIGHT_REPORT must distinguish them. A pile of
`not_evaluated` results indicates infra drift, not a clean run.

---

## Per-gate schema

### Gate 1 — PHP Tests
- **Detection:** `vendor/bin/pest` OR `vendor/bin/phpunit` exists
- **Pass:** exit 0, output contains "Tests:" with `failed=0`
- **Fail:** exit non-zero OR output contains "FAILED"
- **Skipped:** PHP project not detected (no `composer.json`)
- **not_evaluated:** test runner present but command itself errors
  (e.g., DB unavailable, fatal startup error)
- **Evidence:** test command invoked, exit code, last 30 lines of output
- **Elevation:** any failure → block

### Gate 2 — JS Tests
- **Detection:** `node_modules/.bin/vitest` OR `node_modules/.bin/jest` exists
- **Pass:** exit 0
- **Fail:** exit non-zero
- **Skipped:** no JS project (no `package.json` test script)
- **not_evaluated:** runner present but throws config error
- **Evidence:** command invoked, pass/fail counts, exit code
- **Elevation:** any failure → block

### Gate 3 — Frontend Build
- **Detection:** `package.json` has `build` script
- **Pass:** exit 0, build artifacts produced (e.g., `dist/`, `.next/`, `public/build/manifest.json`)
- **Fail:** exit non-zero OR no artifacts written
- **Skipped:** no JS project
- **Evidence:** build command, exit code, artifact path verification
- **Elevation:** failure → block

### Gate 3.1 — Smoke Test (BLOCKING)
- **Detection:** stack-specific (Laravel: route list; Next: build success; Django: `manage.py check`)
- **Pass:** smoke command exits 0
- **Fail:** smoke command errors
- **Skipped:** no recognized stack
- **Evidence:** smoke command + tail of output
- **Elevation:** failure → block (catches "tests pass but app won't boot" mismatches)

### Gate 3.5 — Bundle Size Check
- **Detection:** Gate 3 ran successfully AND build output contains size info
- **Pass:** no configured budget is exceeded AND (if a prior report exists) no chunk grew >10% vs it. When NEITHER a project-configured budget NOR a prior report exists, the gate is informational — record sizes and pass; do NOT fabricate an absolute default (matches SKILL.md Gate 3.5 + Gotcha #4).
- **Fail (warn-only):** a chunk exceeds a **project-configured** budget (`package.json` bundlesize/size-limit, `vite.config.*` chunkSizeWarningLimit, etc.) OR grew >10% vs the prior report
- **Skipped:** Gate 3 didn't run or no bundle data
- **Evidence:** chunk sizes from build output; the budget source (config path / prior report) when a threshold fired
- **Elevation:** warn-only — never blocks (REVIEW-RECOMMENDED flag if exceeded)

### Gate 4 — Lint
- **Detection:** ESLint config present (`.eslintrc*` or `eslint.config.*`)
- **Pass:** exit 0
- **Fail:** exit non-zero (any error or warning above threshold)
- **Skipped:** no lint config
- **Evidence:** lint command, count of errors/warnings, top 5 violations
- **Elevation:** errors → block; warnings → REVIEW-RECOMMENDED

### Gate 5 — TypeScript (with auto-remediation)
- **Detection:** `tsconfig.json` exists
- **Pass:** `tsc --noEmit` exits 0
- **Fail:** type errors after auto-remediation pass
- **Auto-remediation:** see Gate 5 section in SKILL.md (attempts simple fixes before failing)
- **Skipped:** no TS config
- **Evidence:** type-check command, count of errors, list of error locations
- **Elevation:** failure → block

### Gate 6 — ESLint strict (changed files only)
- **Detection:** ESLint configured AND changed `.ts`/`.tsx`/`.js`/`.jsx` files exist
- **Pass:** `npx eslint --max-warnings=0 {files}` exits 0
- **Fail:** any warning or error on changed files (strict mode)
- **Skipped:** no changed JS/TS files
- **Evidence:** files checked, violations per file
- **Elevation:** failure → block (warnings count as failures here unlike gate 4)

### Gate 7 — Pint (Laravel formatting)
- **Detection:** `vendor/bin/pint` exists
- **Pass:** `./vendor/bin/pint --test` exits 0 (no style drift)
- **Fail:** exit non-zero (files would be reformatted)
- **Skipped:** no Pint binary
- **Evidence:** count + names of files Pint would reformat
- **Elevation:** failure → block. Runs in `--test` mode only — pre-flight never rewrites files.

### Gate 8 — Composer audit
- **Detection:** `composer.lock` exists
- **Pass:** exit 0 with no critical/high vulns
- **Fail:** critical vulns
- **Fail (warn-only):** high vulns (continue-on-error per project policy)
- **Skipped:** no composer.lock
- **Evidence:** advisory list with severity
- **Elevation:** critical → block; high → REVIEW-RECOMMENDED

### Gate 9 — npm audit
- **Detection:** `package-lock.json` OR `yarn.lock` OR `pnpm-lock.yaml`
- **Pass:** exit 0 OR only low/moderate vulns
- **Fail:** critical vulns (per `--audit-level=critical`)
- **Skipped:** no lockfile
- **Evidence:** advisory summary
- **Elevation:** critical → block; high → warn

### Gate 10 — Contract tests
- **Detection:** `tests/Contracts/` directory exists
- **Pass:** all contract tests pass
- **Fail:** any contract violation
- **Skipped:** no contract test directory
- **Evidence:** failed contract list
- **Elevation:** failure → block (contract violations break consumers)

### Gate 11 — Visual regression (NON-BLOCKING)
- **Detection:** Playwright + visual test markers (`@visual` grep)
- **Pass:** all visual snapshots match
- **Fail:** snapshot mismatches found
- **Skipped:** no Playwright OR no @visual tests
- **Evidence:** mismatched test names + diff URLs
- **Elevation:** never blocks — always REVIEW-RECOMMENDED on failure

### Gate 11.5 — E2E / Browser workflow specs (BLOCKING when present)
- **Detection:** two lanes, either or both may fire, CAPABILITY-based (never a version string): `tests/Browser/*.php` (Pest browser testing lane — `PEST_BROWSER_SPECS`, detected via `pestphp/pest-plugin-browser` in `composer.json` OR the spec directory itself) OR `tests/e2e/*.spec.*` (Playwright lane — `E2E_SPECS`). Golden-path specs frozen by `v-workflow-verifier`.
- **Pass:** every detected lane's command exits 0 — Pest lane: `./vendor/bin/pest tests/Browser --parallel=false`; Playwright lane: `npm run build && npx playwright test --grep-invert @visual --pass-with-no-tests` exits 0
- **Fail:** any functional spec in EITHER lane fails — a previously-verified workflow regressed
- **Skipped:** neither lane's spec directory exists, OR (Playwright lane specifically) only `@visual` specs exist (zero functional specs matched — `--pass-with-no-tests` makes this a per-lane skip, not a fail), OR incremental mode (full-suite check only)
- **not_evaluated:** a lane's plugin/config is present but its runner/browser can't launch — Playwright: `playwright.config.*` present but browser binary missing (`npx playwright install` not run); Pest browser: `pestphp/pest-plugin-browser` present but its browser driver isn't installed — surface as a prominent DEGRADED advisory per lane, never a silent pass
- **Evidence:** per lane — build exit code (Playwright only), command run, pass/fail spec counts, first failing spec name + step
- **Elevation:** failure → block (distinct from Gate 11 visual regression, which is non-blocking). Playwright lane builds first so specs never execute against stale front-end artifacts. Neither lane demotes the other — a project may run both.

### Gate 12 — Mutation testing (CONDITIONALLY BLOCKING)
- **Detection:** CAPABILITY-based, engine priority (first match wins, run only one engine per session):
  1. `PEST_MUTATION` — `vendor/bin/pest` exists AND `./vendor/bin/pest --version` major is in the range 3-99 (version-RANGE probe: `grep -qE '^Pest ([3-9]|[1-9][0-9])\.'` — NOT a pinned version, so this keeps detecting correctly on Pest 4/5/6/... without ever needing an edit). This is this operator's actual stack — mutation testing ships in Pest natively, no separate install.
  2. `INFECTION` — `vendor/bin/infection` present (PHP, explicit legacy install)
  3. `STRYKER` — `node_modules/.bin/stryker` present (JS)

  All three additionally require changed source files in the relevant language.
- **Pass:** mutation score ≥ 70% on changed classes/files (parity across all three engines — same threshold, same meaning), OR every changed class/file hits the zero-mutations skip (below)
- **Fail:** score < 70% on a changed class/file WITH mutants actually generated (BLOCKS only when gate 12 explicitly enabled in config)
- **Zero-mutations case (must be handled explicitly, not left to fall through as a 0% score):** a changed file/class that generates NO mutants (pure interface/config/DTO, no mutable branches) does not fail the gate — record `skipped (no mutable code)` for that unit. Pest: pass `--ignore-min-score-on-zero-mutations` when the installed version supports it (probe by grepping the run's own stderr for an "unknown option" class of message — see SKILL.md § Gate 12: Mutation Testing); Infection: treat an explicit "no mutations generated" report line the same way. Absent this handling, a file with zero mutable lines silently reads as a 0%-score failure — that is the vacuous-gate failure mode this rule exists to prevent.
- **Skipped:** none of PEST_MUTATION / INFECTION / STRYKER detected, OR no changed source files in the applicable language
- **not_evaluated:** an engine is detected but the run errors for a reason OTHER than the zero-mutations case (missing coverage driver, an installed Pest minor that doesn't support `--min`/`--ignore-min-score-on-zero-mutations`, timeout) — prominent advisory, never a silent pass. Do NOT phrase the "nothing detected" case as `not_installed` when Pest ≥3 is present but mutation testing simply hasn't been run yet — Pest-native requires no install, so `not_installed` would be a factually wrong label on this operator's stack; the only true `not_available` case is when NONE of the three engines is detected at all.
- **Evidence:** which engine ran, mutation score, list of escaped mutants (or the zero-mutations note per unit)
- **Elevation:** below threshold → block IF `MUTATION_BLOCKING=1`, else REVIEW-RECOMMENDED

### Gate 25 — Core Web Vitals / Performance budget (WARN-ONLY by default)
- **Detection:** CAPABILITY-based: `LHCI_CONFIG` (`.lighthouserc.js`/`.json`/`.yml`/`.yaml` present — self-contained, the project owns its own server-boot mechanism via `ci.collect.startServerCommand`/`staticDistDir`) OR `LIGHTHOUSE_CLI` (bare `lighthouse` binary on PATH) AND a reachable smoke-test URL (only available when Gate 3.1's Node/Next.js smoke test booted `localhost:$PORT` — Laravel's Gate 3.1 never boots a live server, so the bare-CLI lane is effectively Node/Next-only; Laravel projects need `LHCI_CONFIG` to use this gate at all)
- **Pass:** LHCI: all configured assertions pass. Bare CLI: reported LCP/INP/CLS are within the thresholds cited from `_v-design.md` § Runtime-Critical Quality Bar, re-read fresh each run (do not cache the numeric thresholds here — that file is the sole owner and can update them)
- **Fail (warn-only by default; blocking only when the project's own `.lighthouserc.*` marks an assertion `error`-level, or CI already enforces the budget):** any metric misses its cited threshold → REVIEW-RECOMMENDED, metric + observed value + threshold as evidence
- **Skipped:** no consumer-facing web stack detected at all
- **not_evaluated (known-absent capability, explicit — never a silent pass):** neither `LHCI_CONFIG` nor `LIGHTHOUSE_CLI` detected, OR `LIGHTHOUSE_CLI` present with no capability-appropriate URL to hit (the Laravel-without-LHCI-config case above). Record `core_web_vitals: not_available` with the specific missing piece named, mirroring Gate 12's absent-vs-failing distinction
- **Evidence:** which lane ran, metric values, threshold source citation (`_v-design.md` § Runtime-Critical Quality Bar)
- **Elevation:** warn-only → REVIEW-RECOMMENDED; block only when the project's own config/CI already treats it as blocking

### Gate 13 — Rust tests
- **Detection:** `Cargo.toml` exists
- **Pass:** `cargo test` exits 0
- **Fail:** test failures
- **Skipped:** no Rust project
- **Evidence:** test summary, failed test names
- **Elevation:** failure → block

### Gate 14 — Python tests
- **Detection:** `pytest.ini`, `pyproject.toml [tool.pytest]`, OR `tests/` with Python files
- **Pass:** pytest exits 0
- **Fail:** test failures
- **Skipped:** no Python test config
- **Evidence:** pytest summary
- **Elevation:** failure → block

### Gate 15 — Go tests
- **Detection:** `go.mod` exists
- **Pass:** `go test ./...` exits 0
- **Fail:** test failures or build errors
- **Skipped:** no Go module
- **Evidence:** package list, failed package count
- **Elevation:** failure → block

### Gate 16 — Ruby tests
- **Detection:** `Gemfile` AND (`spec/` OR `test/`)
- **Pass:** rspec/rails-test exits 0
- **Fail:** test failures
- **Skipped:** no Ruby project
- **Evidence:** test summary
- **Elevation:** failure → block

### Gate 17 — Ruby lint (changed files)
- **Detection:** `bundle exec rubocop` available AND changed `.rb` files
- **Pass:** rubocop exits 0
- **Fail:** lint violations on changed files
- **Skipped:** no rubocop OR no changed Ruby files
- **Evidence:** violations per file
- **Elevation:** failure → block

### Gate 18 — Ruby security
- **Detection:** brakeman gem present
- **Pass:** exit 0 (no warnings)
- **Fail:** any warning
- **Skipped:** no brakeman
- **Evidence:** warning summary
- **Elevation:** failure → block (security gates always block)

### Gate 19 — Python lint (changed files)
- **Detection:** `ruff` or `flake8` available AND changed `.py` files
- **Pass:** linter exits 0
- **Fail:** violations
- **Skipped:** no linter OR no changed Python files
- **Evidence:** violations per file
- **Elevation:** failure → block

### Gate 20 — Python type check
- **Detection:** `mypy` configured AND changed `.py` files
- **Pass:** mypy exits 0
- **Fail:** type errors
- **Skipped:** no mypy OR no changed Python files
- **Evidence:** error summary
- **Elevation:** failure → block

### Gate 21 — Migration rollback (CONDITIONALLY BLOCKING)
- **Detection:** PHP project + changed migration files
- **Pass:** rollback + re-migrate cycle completes without error
- **Fail:** rollback errors OR re-migration errors
- **Skipped:** no PHP project OR no changed migrations
- **not_evaluated:** test DB unavailable
- **Evidence:** rollback output, migration output
- **Elevation:** failure → block IF `MIGRATION_ROLLBACK_BLOCKING=1` (default 1)

### Gate 22 — Seeder compatibility (CONDITIONALLY BLOCKING)
- **Detection:** PHP project + changed migration OR model files
- **Pass:** `db:seed` completes without error
- **Fail:** seeder errors (FK drift, missing column, etc.)
- **Skipped:** no PHP project OR no relevant changes
- **not_evaluated:** test DB unavailable OR seeder dependency unsatisfied
- **Evidence:** seed output
- **Elevation:** failure → block IF seeders exist

### Gate 23 — PHPStan / Larastan (static analysis)
- **Detection:** `vendor/bin/phpstan` OR `vendor/bin/larastan` exists
- **Pass:** `./vendor/bin/phpstan analyse --no-progress` exits 0 at the project's configured level
- **Fail:** exit non-zero (static-analysis errors)
- **Skipped:** no PHPStan/Larastan binary
- **not_evaluated:** binary present but no `phpstan.neon*` config (no defined level) — prominent advisory, never a silent pass
- **Evidence:** error count + top file:line offenders
- **Elevation:** failure → block. Uses the project's configured level; never overridden on the command line.

### Gate 24 — Accessibility (a11y / EAA)
- **Detection:** any of `@axe-core/playwright` (AXE_PLAYWRIGHT), `pa11y`/`pa11y-ci` (PA11Y), standalone `axe` (AXE), or `eslint-plugin-jsx-a11y` (JSX_A11Y)
- **Pass:** the detected a11y runner reports zero violations at its configured level. When only `AXE_PLAYWRIGHT` or `JSX_A11Y` is present, this gate is satisfied by Gate 11.5 / Gate 4 respectively (record which)
- **Fail (warn-only by default):** violations found → REVIEW-RECOMMENDED. Blocking when the project sets an a11y budget or its CI already enforces a11y (then WCAG-A/AA violations on changed pages block)
- **Skipped:** no a11y tooling detected (note EAA exposure as an advisory for consumer-facing projects; do NOT fabricate a runtime check)
- **Evidence:** rule id + selector per violation, and which tool ran
- **Elevation:** warn-only → REVIEW-RECOMMENDED; block only when project CI enforces a11y

---

## REVIEW-RECOMMENDED flag

When a gate produces `failed_non_blocking` OR a non-blocking
warning on a non-trivial gate (3.5, 4 warnings, 8 high, 9 high,
11), the report sets the REVIEW-RECOMMENDED flag at the top.

The flag does NOT cause exit non-zero. It signals to the operator
(or to the next phase, e.g., `/v-check`) that human review is
warranted before shipping.

---

## Report integrity rules

The PRE_FLIGHT_REPORT is structurally invalid if:

1. **Any APPLICABLE gate is missing a status entry.** A gate is
   "applicable" only when its detection signal fires (per each
   gate's "Detection" line above). Specifically:
   - Gate 1 requires `vendor/bin/{pest,phpunit}` —
     not just `composer.json`. A fresh clone before
     `composer install` correctly skips this gate.
   - Gate 8 requires `composer.lock`.
   - Gates 21, 22 require changed migration / model files in the
     diff against base.

   Each applicable gate must have a status entry — even if the
   status is `skipped` (e.g., gate 21 if no migration changes
   despite a vendor-installed PHP project).

   Gates whose detection signal didn't fire are NOT included in
   the report. Listing them as `skipped` would conflate "tool not
   present" with "tool present, no relevant changes" — those are
   semantically different.

2. **Any gate has a status of `failed` but the report's overall
   verdict is `passed`.** Failure must propagate. This holds even
   in read-only / "don't fix" / "defer to a later wave" runs: read-only
   governs whether source is EDITED, not the verdict. A session-introduced
   failure that is deferred (not fixed) is still `failed` and still forces
   overall `failed` — it belongs under `## Blocking Failures` (annotated
   "DEFERRED"), never demoted to a non-blocking advisory. The ONLY failures
   that may coexist with an overall `passed` are baseline-confirmed
   pre-existing failures (status `failed_non_blocking` via the
   pre-existing path).

2a. **A full-suite failure classified "pre-existing" without a baseline
   diff.** "The failing test file is not in the changed set" is NOT
   sufficient — a changed source file can break an unchanged test file
   (the dominant case for whole-codebase scanner tests: `tests/Contracts/`,
   `*CopyScanner*`, architecture/convention tests). Pre-existence may only be
   asserted when a baseline comparison (diff by failing-test NAME against
   clean HEAD/merge-base, per `v-core-pre-existing.md`) confirms the failure
   predates the session. Filename non-overlap alone → treat as
   session-relevant, not pre-existing.

3. **`not_evaluated` count ≥ 4.** Surface as a separate WARN at
   the top of the report — that many gates not running is itself
   a signal of broken infra. (Inclusive lower bound; matches the
   threshold language in SKILL.md "Gate Result Schema reference".)

3a. **Pre-existing failure pile > 25 (BASELINE-DEGRADED).** When the
   total baseline-confirmed pre-existing failure count across gates
   exceeds 25, set a `BASELINE-DEGRADED` REVIEW-RECOMMENDED flag at
   the top of the report. This does NOT change pass/fail (pre-existing
   failures are still non-blocking) — it warns that the baseline the
   classifier compares against is noisy enough that a real regression
   could hide inside the pile. `v-run-gates.sh` emits
   `BASELINE_HEALTH=degraded` + `BASELINE_PRE_EXISTING_TOTAL=<n>` for
   this. A growing pile is a standing invitation to designate a
   test-health session (see `v-core-pre-existing.md`).

4. **Evidence section is empty.** Every gate entry must have at
   least the command that ran and the exit code.

These rules are enforceable by a downstream consumer (e.g., the
orchestrator's Stop hook). Tests in `tests/PreFlight/` should
verify the report against this schema.

---

## How to add a new gate

1. Define the gate's detection signal (what file / config triggers it)
2. Define pass / fail / skipped / not_evaluated conditions
3. Define elevation behavior (block / warn / review-recommended)
4. Add an entry to the table in SKILL.md "Gate Execution Order"
5. Add a per-gate schema entry in this file
6. Update the report-integrity rules above if the new gate is
   universally applicable (must always have a status entry)

Last update: 2026-08-02. (Gate 12 now detects Pest-native mutation testing — capability/version-range probe, not a pinned tool — ahead of Infection/Stryker, with explicit zero-mutations handling; Gate 11.5 gained a Pest browser testing lane alongside Playwright; added Gate 25 Core Web Vitals / Lighthouse budget, citing `_v-design.md` § Runtime-Critical Quality Bar rather than restating thresholds.)
