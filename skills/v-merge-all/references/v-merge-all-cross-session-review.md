# Step 4f — cross-session review dispatch mechanics

Loaded on demand by `/v-merge-all` Step 4f. The WHEN-to-run rule and the "this is the ONLY check for
cross-branch breakage — it must actually run" mandate stay inline in SKILL.md; only the dispatch
commands live here. Extracted from SKILL.md 2026-08-03.

**⛔ DISPATCH: `/v-merge-all` runs `context: fork`, where `Agent(general-purpose)` dispatch FAILS silently. Use codex via Bash, which works from a fork:**

**Two distinct trigger shapes — compute the diff differently for each (Step 2a-i / Step 4f):**
- **Cross-branch overlap** (2+ branches touched the same file, or an auto-resolved conflict): diff = `main~${N}..main`, focus = the cross-cutting files only — steps 1-2 below.
- **Unreviewed main-root capture** (`MAIN_CAPTURE_NEEDS_REVIEW=1`, no branches involved): diff = `${MAIN_ROOT_CAPTURE_SHA}~1..${MAIN_ROOT_CAPTURE_SHA}`, focus = EVERY file in that commit. Nobody has reviewed this code yet, so this is a standard hostile first-pass review, not an overlap check — tell the reviewer so explicitly:
  ```bash
  codex exec --model "${CODEX_REVIEW_MODEL:-gpt-5.3-codex}" --skip-git-repo-check </dev/null \
    "Review this diff (git diff ${MAIN_ROOT_CAPTURE_SHA}~1..${MAIN_ROOT_CAPTURE_SHA}). It has NEVER been reviewed by anyone — the writing session ended before its own gates ran, and /v-merge-all only absorbed it as a capture commit. Perform a standard hostile adversarial review: correctness, security, edge cases, N+1/unbounded queries, missing validation. Report CRITICAL/HIGH/MEDIUM/LOW with file:line."
  ```
  Steps 3-6 below (fix CRITICAL/HIGH before push, log MEDIUM/LOW, severity mapping) apply identically to this case.

1. Get the combined diff and the cross-cutting file list:
   ```bash
   N=<number of merged commits>
   git --no-pager diff "main~${N}..main" --name-only > "$REPO_ROOT/.v/tmp/merge-combined-files.txt"
   # cross-cutting = files that appeared in 2+ branch diffs (from the Step 2b file lists)
   ```
2. Run codex on the cross-cutting files (NOT the whole diff). Mirror the /v Step 5 invocation — explicit model, stdin from /dev/null (or it hangs):
   ```bash
   codex exec --model "${CODEX_REVIEW_MODEL:-gpt-5.3-codex}" --skip-git-repo-check </dev/null \
     "Review ONLY these files, which were modified by MULTIPLE parallel sessions and merged together: <list>. \
      Hostile cross-session focus: conflicting/duplicate imports, duplicate or shadowed function/class definitions, \
      incompatible interface or prop-shape changes between sessions, N+1 or query regressions introduced by the \
      combination, and any conflict that was auto-resolved by picking one branch's version (verify the dropped side \
      wasn't load-bearing). Report CRITICAL/HIGH/MEDIUM/LOW with file:line."
   ```
3. **If codex is unavailable/errs:** dispatch `logic-reviewer` via the subprocess helper instead — `bash ~/.claude/skills/v/references/v-dispatch-subagent.sh --agent logic-reviewer --prompt-file <cross-cutting-review-prompt> --artifact "$REPO_ROOT/.v/tmp/merge-xsession-review.md" --mode capture` — then read that artifact. Do NOT use `Agent(general-purpose)` (fork-broken).
4. For any CRITICAL/HIGH findings: fix before pushing, log in MERGE_ALL_REPORT. **If a finding traces to a wrongly-auto-resolved conflict, revert to the affected branch's version and re-verify (the branches are still intact per Step 3f).**
5. For MEDIUM/LOW findings: log in MERGE_ALL_REPORT as warnings, proceed with push.
6. Severity vocabulary maps to canonical P0–P3 per `~/.claude/skills/references/v-core-severity.md` (CRITICAL=P0, HIGH=P1, MEDIUM=P2, LOW=P3) — the CRITICAL/HIGH fix-before-push gate is the P0/P1 must-fix rule.

---

