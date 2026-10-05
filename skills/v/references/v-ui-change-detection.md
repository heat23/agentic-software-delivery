# Step 3.5: UI Change Detection & Scoped Polish (extracted from /v SKILL.md)

> **Loaded by:** /v Step 3.5, after implementation completes (or alongside Step 4 if W55-F1 concurrent dispatch was chosen). Inline /v SKILL.md should have only a one-line stub. UX-critique is **mandatory** when UI files changed (W49 Stop-hook enforces).

> **W55-F1 NOTE:** if Step 3.4 chose concurrent dispatch, Step 3.5's UX-critique Agent call has ALREADY been initiated alongside Step 4's pre-flight. Skip the dispatch portion below and proceed directly to "Output handling" once the Agent tool returns the UX_CRITIQUE artifact path. Sequential dispatch (the protocol below) applies when Step 3.4 selected the sequential fallback.

## UI file detection

After implementation, before quality gates. Use worktree-aware pattern from `_v-core.md` → Changed File Detection, then filter for UI files:

```bash
MAIN_BRANCH="${CLAUDE_MAIN_BRANCH:-main}"
IS_WORKTREE=false
if [ "$(git rev-parse --git-common-dir 2>/dev/null)" != "$(git rev-parse --git-dir 2>/dev/null)" ]; then
  IS_WORKTREE=true
fi

if $IS_WORKTREE; then
  MERGE_BASE=$(git merge-base HEAD "$MAIN_BRANCH" 2>/dev/null || echo "HEAD~10")
  UI_FILES=$(git diff --name-only "$MERGE_BASE"..HEAD -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null; git diff --name-only HEAD -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null; git ls-files --others --exclude-standard -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null)
else
  UI_FILES=$(git diff --name-only HEAD -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null; git diff --cached --name-only -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null; git ls-files --others --exclude-standard -- '*.tsx' '*.jsx' '*.css' '*.html' '*.vue' '*.svelte' '*.blade.php' 2>/dev/null)
fi
UI_FILES=$(echo "$UI_FILES" | sort -u)
```

UI files found → store as `POLISH_SCOPE`, invoke `/v-polish` (Skill tool — forks to sonnet via frontmatter) in scoped mode with POLISH_SCOPE. No UI files → skip.

## Design Craft Gate (New UI Only)

After `/v-polish` scoped mode, check if new `.tsx`/`.jsx` files were **created**:
```bash
git ls-files --others --exclude-standard -- '*.tsx' '*.jsx' 2>/dev/null
git diff --name-only --diff-filter=A HEAD -- '*.tsx' '*.jsx' 2>/dev/null
```

**New UI files created (new pages, component patterns, layouts):**
1. Invoke `/interface-design:critique` — conformance critique against the shared
   design system (`_v-design.md` § Canonical Token Set +
   `references/design-system-spec.md`): canonical tokens, Inter/JetBrains Mono
   typography, component library, `html[data-theme]` theming, breakpoints.
   Per-product freedom is judged against the `.interface-design/system.md`
   overlay (accent, category colors, branding, domain components). If the
   canonical tokens are not yet installed in the project, suggest
   `/interface-design` (install) first, then critique.
2. Findings advisory — fix flagged, don't block.

**Only existing UI files modified:** skip critique. `_v-design.md` spec-conformance checks (Spec-Deviation Detection Table + BLOCK checks) + v-polish scoped mode is sufficient.

**Anti-patterns (do NOT skip polish):** "Admin UI follows established patterns"; "No customer-facing UX impact". ALL UI files, no exceptions.

## UX Critique (W48-F2 + W49 enforcement — Mandatory when UI files changed)

**ENFORCEMENT (W49):** the Stop hook `check-review-artifact.sh` blocks completion when session-owned writes include user-facing UI files AND `UX_CRITIQUE_<sid>.md` is missing or invalid. UX critique is no longer advisory — skipping it leaves the session incomplete. Production motivation: a production session (post-W48) skipped Step 3.5 entirely; W49-F1 closes that bypass.

After `/v-polish` (and `/interface-design:critique` if applicable), dispatch a haiku UX-critique reviewer. This is the heuristic check that `/v-polish` (token/consistency) and `codex-adversarial-reviewer` (correctness) do NOT cover. Production motivation: UX tweaks shipped without inspection of contrast, focus states, microcopy, state coverage.

### Dispatch protocol

Substitute the canonical prompt and dispatch as an INDEPENDENT `claude -p --agent` subprocess (W-fork-fix — Agent-tool dispatch fails from /v's `context: fork`; a Bash-spawned subprocess is independent and bypasses the no-nested-subagent limit):

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
SRC="${CLAUDE_SKILL_DIR}/references/dispatch-ux-critique.md"
DISPATCH_FILE="$V_TMP_DIR/dispatch-${SESSION_ID}-ux-critique.txt"
# perl -0pe slurps the whole file so the multiline {{UI_FILES}} value substitutes cleanly.
SID="$SESSION_ID" PROJ="$PROJECT_ROOT" UIF="$UI_FILES" perl -0pe \
  's/\{\{SESSION_ID\}\}/$ENV{SID}/g; s/\{\{PROJECT_ROOT\}\}/$ENV{PROJ}/g; s/\{\{UI_FILES\}\}/$ENV{UIF}/g;' \
  "$SRC" > "$DISPATCH_FILE"
bash "$HELPER" --agent v-ux-critique-reviewer --prompt-file "$DISPATCH_FILE" \
  --artifact "$PROJECT_ROOT/.v/artifacts/UX_CRITIQUE_${SESSION_ID}.md" --mode self-write
```

The helper loads `~/.claude/agents/v-ux-critique-reviewer.md` frontmatter (`tools: Bash, Read, Grep, Glob, BashOutput, Write`, `model: sonnet`) — Edit/MultiEdit/NotebookEdit PHYSICALLY UNAVAILABLE (W48-F2 / W35 read-only enforcement preserved); the single Write is scoped to the artifact. `--mode self-write`: the agent writes `.v/artifacts/UX_CRITIQUE_${SESSION_ID}.md` under the project root (severity/issue/fix table over 10 heuristics: information hierarchy, scannability, Fitts' law, contrast, microcopy, state coverage, focus states, consistency, cognitive load, affordance); the helper verifies it landed.

**NO restart needed for a new agent** — the subprocess reads the agent registry fresh each run (the old W38 "Agent type not found → restart" failure mode is gone). If the helper exits non-zero (`DISPATCH_STATUS=error`), write the W49 manual fallback artifact (below) — do NOT silently skip; the Stop hook blocks on a missing/invalid `UX_CRITIQUE`. Do NOT replace the helper with an in-context `Agent(model:"haiku")` dispatch (it fails from the fork and loses the read-only enforcement).

### Failure mode (W49 — gate is now enforcing)

As of W49, the Stop hook DOES require `UX_CRITIQUE_<sid>.md` when session-owned writes include user-facing UI files. If the helper dispatch errors (`DISPATCH_STATUS=error` — agent file missing, network failure, etc.), the orchestrator MUST write a manual fallback artifact at `UX_CRITIQUE_<sid>.md` with: line 1 `Model: haiku`, a `## UX Critique` (or `## Heuristic` or `## Findings`) section header, total file size >100 bytes. State explicitly that the dispatch failed and a manual review was performed. Do NOT silently skip — the gate will block.

### Output handling

Findings are advisory. Orchestrator reads `UX_CRITIQUE_${SESSION_ID}.md` after dispatch and:
- Critical/high → must remediate before Step 4 pre-flight (or write justification in AGENT_REVIEW).
- Medium → remediate if scope permits.
- Low/info → log only.

## Workflow Verification (Mandatory when UI files changed — behavioral gate)

UX critique judges *heuristics* (advisory); workflow verification judges *whether the flow actually works in a real browser* (behavioral, blocking). Both run when UI files changed. This is the gate that closes the "unit tests pass but the workflow is broken" gap.

**ENFORCEMENT:** the Stop hook `check-review-artifact.sh` blocks completion when session-owned writes include user-facing UI files AND `WORKFLOW_VERIFICATION_<sid>.md` is missing or has `status: fail`. `status: degraded` is accepted (env genuinely unavailable) but surfaced loudly in Step 7. This mirrors the W49 UX-critique gate semantics.

### Dispatch protocol

Substitute the canonical prompt and dispatch as an INDEPENDENT `claude -p --agent` subprocess (W-fork-fix — Agent-tool dispatch fails from /v's `context: fork`):

```bash
HELPER="${CLAUDE_SKILL_DIR}/references/v-dispatch-subagent.sh"
SRC="${CLAUDE_SKILL_DIR}/references/dispatch-workflow-verifier.md"
DISPATCH_FILE="$V_TMP_DIR/dispatch-${SESSION_ID}-workflow-verifier.txt"
SID="$SESSION_ID" PROJ="$PROJECT_ROOT" UIF="$UI_FILES" perl -0pe \
  's/\{\{SESSION_ID\}\}/$ENV{SID}/g; s/\{\{PROJECT_ROOT\}\}/$ENV{PROJ}/g; s/\{\{UI_FILES\}\}/$ENV{UIF}/g;' \
  "$SRC" > "$DISPATCH_FILE"
# EFF-WFTIMEOUT (2026-06-28): cap the verifier BELOW the 600s Bash-tool foreground timeout so a
# hung browser build/boot self-terminates cleanly (rc124 -> degraded fallback) instead of auto-backgrounding into a
# ~10-min passive-wait stall. 540s does not cut legitimate runs (FE build budgeted ~1-3 min); mirrors QA's override.
V_DISPATCH_TIMEOUT_SEC=540 bash "$HELPER" --agent v-workflow-verifier --prompt-file "$DISPATCH_FILE" \
  --artifact "$PROJECT_ROOT/.v/artifacts/WORKFLOW_VERIFICATION_${SESSION_ID}.md" --mode self-write
```

The helper loads `~/.claude/agents/v-workflow-verifier.md` frontmatter (`tools: Bash, Read, Grep, Glob, BashOutput, Write`, `model: sonnet`) — Edit/MultiEdit/NotebookEdit PHYSICALLY UNAVAILABLE; Write scoped to `tests/e2e/**`, root `playwright.config.*`, and the artifact. This agent uses the Playwright **CLI** (`npx playwright test`), NOT live MCP browser tools. The agent runs `npm run build` (fresh front-end artifacts — this project serves built assets), boots the app, commits a deterministic Playwright spec to `tests/e2e/<flow>.spec.ts` covering the golden path AND sad paths (console-error + failed-request assertions encoded in the spec via `page.on(...)` / `page.route(...)`) (+ scaffolds `playwright.config.*` with a build-then-serve `webServer` if absent), runs it via `npx playwright test` asserting zero console errors / failed requests, and writes `WORKFLOW_VERIFICATION_${SESSION_ID}.md` (`status: pass|degraded|fail`; degraded when Playwright/the browser binary is absent). `--mode self-write`: the helper verifies the artifact landed.

**NO restart needed for a new agent** (subprocess reads the registry fresh). If the helper exits non-zero, write the manual fallback (below). Do NOT replace the helper with an in-context `Agent` dispatch — it fails from the fork.

### Scope source

The verifier reads `SUCCESS_CRITERIA_<sid>.md` (`verify_by: browser|both` + the `workflow_states` block + `human_success_check`) for features, and `WORKFLOW_BLAST_RADIUS_<sid>.md` (`browser_only_states`) for bug-fixes. If neither exists it derives the golden path from `{{UI_FILES}}`.

### Failure mode (gate is enforcing)

If the helper dispatch errors (`DISPATCH_STATUS=error` — agent file missing, network failure), the orchestrator MUST write a manual fallback `WORKFLOW_VERIFICATION_<sid>.md`: line 1 `Model: sonnet`, a `## Workflow Verification` header, a `status: degraded` line, and a `degraded_reason:` stating the dispatch failed. Do NOT silently skip — the gate will block on a missing artifact.

### Output handling

- `status: fail` → critical/high WF-* findings MUST be remediated before Step 4 pre-flight, then re-dispatch the verifier (re-verify). This is the loop that kills "narrow fix → sibling still broken."
- `status: degraded` → allowed; surface `degraded_reason` on Step 7 line 4 so the UI is known to be NOT browser-verified this session.
- `status: pass` → committed golden-path specs are now part of the suite; the pre-flight e2e gate re-runs them every session.
