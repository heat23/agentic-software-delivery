# Conflict resolution + per-branch failure handling

Loaded on demand by `/v-merge-all` Step 3. Procedural guidance for resolving merge conflicts and
handling a branch that fails to merge. The hook-enforced prohibitions (never `--theirs`/`--ours`,
never `git stash`, never force-push) stay inline in SKILL.md § Gotchas — they are not repeated here.
Extracted from SKILL.md 2026-08-03.

### Conflict Resolution Strategy

**Priority order for conflict resolution:**
1. **Additive changes** (new files, new functions, new routes) — keep both
2. **Same file, different sections** — keep both (git usually auto-resolves these)
3. **Same file, adjacent lines** — read both intents, merge manually
4. **Same function modified differently** — first try to COMBINE both intents. Only if they truly can't coexist, keep one tentatively, record it in `CONFLICT_AUTORESOLVED` (per 3c-iv), and let Step 4f re-review + revert if the dropped side mattered. "Prefer the bigger branch" is NOT a safe default on its own — bigger ≠ correct.
5. **Structural conflicts** (incompatible refactors) — mark as `unresolved`, skip this branch, continue with others. Do not guess between two incompatible architectures.

**Config file conflicts** (package.json, tsconfig.json, composer.json):
- For dependency additions: union of both sets (keep all added deps)
- For config value changes: prefer the most recent branch's value
- For structural changes: prefer the branch that adds capability

### Failure Handling Per Branch

If a branch cannot be merged after the W17-2 autonomous resolver's 10-cycle cap:
1. Leave it unmerged
2. Log it as `status: failed` with the error
3. Continue with the next branch
4. The failed branch remains intact for manual resolution

**Do NOT abort the entire process because one branch fails.** Merge everything that can be merged.

---

