# Anthropic Skill Authoring Standards (2026) — review reference

_Last reviewed: 2026-08-02 (ecosystem-wide skill audit: §1 body-length rules and §8 frontmatter table verified against the 54 skills on disk; the §8 `model` row was corrected in the same pass — `opus` removed as a valid value, `inherit` documented, and the manual-invoke-only scope of the field stated explicitly.)._

> **Loaded by:** v-skill-reviewer in `standard` and `thorough` modes when applying the **Anthropic compliance** lens. Quick mode reads only the §Pre-flight checklist.

Source authority: Anthropic 2026 Agent Skills authoring best practices (`platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices`), Claude Code Skills docs (`code.claude.com/docs/en/skills`), and the Dec 2025 engineering post "Equipping agents for the real world with Agent Skills." This reference distills the rules that matter for v-* skill review; it is not a substitute for reading the docs.

## §1 — Pre-flight checklist (quick mode runs this only)

| # | Check | Pass criterion | Fail = severity |
|---|---|---|---|
| 1 | Frontmatter parses | `python3 -c "import yaml; yaml.safe_load(open(p).read().split('---')[1])"` succeeds | P0 |
| 2 | `name:` slug | lowercase, hyphens only, ≤64 chars, no reserved words (`helper`, `utils`, `tools`, `anthropic-helper`, `claude-tools`) | P1 (P0 if exceeds 64) |
| 3 | `description:` length | ≤1,024 chars | P1 (truncated by runtime) |
| 4 | `description:` voice | third-person ("Use this skill when..." — NOT "I can help...") | P2 |
| 5 | `description:` triggers | contains 3+ trigger phrases / keywords for autonomous matching | P2 (degrades discovery) |
| 6 | SKILL.md body length | ≤500 lines target; <700 acceptable with documented exception | P2 (>700 without exception) |
| 7 | `references/` depth | one level deep; no nested subdirs | P1 (nested causes partial reads) |
| 8 | Backup/cruft files | no `.bak`, `.bak-<stamp>`, `.tmp` at skill-dir root. **`*.pre-*-bak` is EXEMPT** — frozen pre-fix oracle corpus, guarded by `v-bak-corpus-harness.test.ts`; moving one fails the suite | P3 (move to `.attic/`; never for `*.pre-*-bak`) |

## §2 — Description field (autonomous-matching critical)

Anthropic recommends three components in the description:

1. **What** the skill does — verb + object: "audits a SaaS codebase", "generates failing test skeletons", "routes user requests to sub-skills"
2. **When** to use it — trigger phrases the user might type ("audit my SEO", "find content gaps", "TDD this")
3. **When NOT to use it** — explicit "Do NOT use for X (use Y instead)" exclusions

**Third-person rule:** EVERY skill description must read as third-person narration ABOUT the skill, never first-person from the skill. `"Use this skill whenever..."` is correct. `"I can help you..."` is wrong.

**Trigger keywords:** Anthropic's autonomous matcher scores description against the user's prompt. Include the actual words a user would type. Example for `/v-tdd`: "TDD this", "write failing tests for", "red phase", "pest tests for", "vitest tests for" — these are the user's vocabulary, not the skill's.

**Char limit:** 1,024 hard cap (runtime truncates). Combined with `when_to_use:` optional field, capped at 1,536. Skills with `disable-model-invocation: true` are not used for autonomous matching, but the cap still applies for human-facing skill lists.

## §3 — Naming conventions

| Pattern | Example | Recommended? |
|---|---|---|
| Gerund (verb-ing) | `processing-pdfs`, `analyzing-spreadsheets` | Anthropic preferred |
| Action-oriented | `process-pdfs`, `v-build` | Acceptable if consistent across the collection |
| Noun phrase | `pdf-processor`, `seo-audit` | Acceptable if consistent |
| Vague | `helper`, `utils`, `tools`, `do-stuff` | **Avoid** |
| Reserved | `anthropic-helper`, `claude-tools` | **Avoid** |

For the v-* family: action-oriented (`v-build`, `v-plan`, `v-tdd`) is the established convention. Consistent across the collection = acceptable per Anthropic's "acceptable alternatives" clause. The root `v` itself is one character — vague by Anthropic's letter, but the description should compensate with strong trigger phrases.

## §4 — Three-layer architecture (progressive disclosure)

| Layer | What | Lives in | Loaded when | Token cost |
|---|---|---|---|---|
| Metadata | frontmatter (name, description, allowed-tools, hooks, model, context) | `SKILL.md` YAML | Pre-loaded for all installed skills | Tiny (per-skill) |
| Core instructions | SKILL.md body | `SKILL.md` markdown | On invocation (manual or autonomous match); stays resident until session ends | Heavy (every turn after load) |
| Bundled resources | scripts, prose details, templates | `references/*.{md,sh,py}` | On-demand via Read/Bash | Zero until accessed |

**Implication for reviewers:**
- SKILL.md body is the recurring tax. Every line is paid for every turn after invocation. Target <500 lines.
- Once a Skill is invoked, its SKILL.md stays in context. Compress by extracting conditional / rare-trigger content to references. Pre-emptive safety banners are the exception (must stay inline).
- Reference files don't recur. Length per file matters less; depth (nesting) matters more.

## §5 — References structure

**Anthropic rule:** keep references one level deep. `references/foo.md` is fine. `references/category/foo.md` causes the model to make partial reads instead of complete file loads.

**Acceptable layouts:**
```
skill/
├── SKILL.md
├── references/
│   ├── protocol-a.md
│   ├── protocol-b.md
│   ├── scaffold.sh
│   └── templates.md
└── .attic/                  # backups, historical files
```

**Violations:**
- `references/protocols/a.md` — nested, will cause partial reads
- `references/old-v1/foo.md` — nested archive; move to `.attic/`
- SKILL.md.bak in skill-dir root — discoverability noise; move to `.attic/`

## §6 — Prose vs scripts in references

| Use prose (.md) when | Use scripts (.sh, .py) when |
|---|---|
| Multiple approaches valid; judgment required | Operations fragile / error-prone, must be deterministic |
| Heuristic guidance; decisions context-dependent | Consistency critical (same inputs → same outputs) |
| Future maintainer needs to understand WHY | Exact step sequences must be followed |

**Always:**
- Forward slashes in file paths (`scripts/helper.py`), even on Windows
- Bundled scripts handle their own errors (try/catch, helpful messages); do NOT punt errors back to Claude

## §7 — Distinctions from adjacent primitives

| Primitive | Purpose | When v-* should use |
|---|---|---|
| Skill | Prompt template + bundled resources; loaded on invocation | Default for any specialized workflow |
| Sub-agent | Isolated context running a task with own tools | Use via `context: fork` in frontmatter OR via Agent tool dispatch; loses conversation history |
| Slash command (legacy) | Fixed behavior in `.claude/commands/` | DEPRECATED — Skills supersede; both filenames produce the same `/name` slash command |
| MCP server | External tool provider | Reference by fully qualified name (`GitHub:create_issue`); not auto-discovered |
| Hook | Deterministic event-bound automation | For enforcement that must fire regardless of model choice (Stop, PreToolUse, UserPromptSubmit) |

**Reviewer signal:** if a v-* skill's behavior is described as "the model must do X before Y" — that's either an instruction the model can skip, OR it should be a hook. Flag any "MUST happen first" rule that has no hook backstop.

**Caveat — `context: fork` + Agent-tool dispatch do NOT compose:** the row above lists `context: fork` and "Agent tool dispatch" as two alternate ways to get subagent isolation, which reads as if a skill could use both together. It cannot. A skill declared with `context: fork` is ITSELF running as a subagent (isolated context, own turn budget); per current Claude Code platform behavior (re-verified 2026-05-24), a subagent cannot dispatch further subagents via the Agent tool — the call either errors or silently degrades to inline execution under the calling model's own (potentially biased) reasoning. If a forked skill's workflow needs to spawn an independent read-only reviewer, use a `claude -p --agent <agent-name> "<prompt>" </dev/null` Bash subprocess instead (Bash works from a fork; the subprocess is a genuinely independent process). Flag any `context: fork` skill that also grants `Agent` in `allowed-tools` and describes dispatching a subagent through it — see `v-failure-catalog.md` F16.

## §8 — Frontmatter fields (2026 reference)

| Field | Purpose | Notes |
|---|---|---|
| `name` | Slug for invocation | See §3 |
| `description` | What + when + when-not | See §2 |
| `allowed-tools` | Whitelist of tools the skill may call | Granting tools the skill never uses is dead grant — flag |
| `hooks` | Skill-scoped hooks (UserPromptSubmit, Stop, etc.) | Different from settings.json hooks; only fire when this skill is active |
| `argument-hint` | UI hint for the user | Match the actual `accepts:` contract |
| `user-invocable` | Whether `/name` works for the user | False = skill is internal-only |
| `disable-model-invocation` | Block autonomous description-matching | True = skill only fires when explicitly invoked (Skill tool, sibling skill, /v) |
| `context` | `fork` = run in subagent with isolated context | Loses conversation history; gains isolated tool/turn budget |
| `model` | Model override — **honored only on a manually typed `/skill-name`; IGNORED under Skill-tool dispatch** | `sonnet` / `haiku` / `inherit`. `inherit` = run on the operator's session/CLI model (valid in frontmatter only — `claude -p --model inherit` is rejected by the CLI). `opus`/`fable`/any `[1m]` variant are NOT valid here: CLAUDE.md's sonnet-max policy bans them and `enforce_model_policy()` rejects them at the dispatch chokepoint. Convention: audit family → `inherit`; coding/implementation skills → explicit `sonnet`. See `references/v-core-model-routing.md`. |

## §9 — Anti-patterns Anthropic explicitly calls out

1. Skill descriptions in first person ("I can help...")
2. Descriptions with no trigger keywords (autonomous matcher can't score)
3. Naming vague (`helper`, `utils`) or reserved (`anthropic-*`, `claude-*`)
4. SKILL.md >500 lines with no extraction to references
5. Nested references (`references/category/foo.md`)
6. Bundled scripts that punt errors to Claude
7. Backslashes in file paths
8. Multi-paragraph docstrings in SKILL.md (Anthropic: "Default to writing no comments")
9. Pre-emptive completion summaries in SKILL.md (use the body for instructions, not narration)
10. Backup files (`.bak`, `.pre-*-bak`) in live skill-dir roots

## §10 — Reviewer outputs

For every reviewed skill, the SKILL_REVIEW_REPORT must include an Anthropic-compliance section that scores against §1 pre-flight checklist:

```markdown
### Anthropic 2026 Compliance
- [ ] Frontmatter parses cleanly
- [ ] name slug ≤64 chars, no reserved words
- [ ] description ≤1024 chars
- [ ] description third-person + trigger keywords present
- [ ] SKILL.md body ≤500 lines (or exception documented)
- [ ] references/ one level deep
- [ ] no backup files at skill-dir root
- [ ] no dead allowed-tools grant
```

Pre-flight failures are P0/P1 in the ranked findings.
