# Verification Commands — copy-paste bash for every review lens

_Last reviewed: 2026-08-03 (deferred-findings closure: Lens 23's whole-catalog sweep widened from `v-*/` to `*/` + a SKILL.md existence guard, so non-`v-`-prefixed skills — `find-skills`, `interface-design` — are no longer silently excluded from the routing-reachability check; live-fired against the real catalog and confirmed it enumerates exactly the 54 live skills; prev 2026-08-02 SME content review)._

> **Loaded by:** v-skill-reviewer Workflow step 5 (bounded read-only shell checks). Each lens has corresponding commands. Substitute `<SKILL>` with the target SKILL.md path; `<NAME>` with the skill name; `<BASELINE>` with the .attic snapshot if available.

**Portability (mandatory):** every command in this file MUST run on macOS/BSD userland without GNU-only flags — this reviewer runs on darwin. `grep -P` (PCRE) is NOT supported by BSD `grep`; use `grep -E` (POSIX ERE) or `rg` instead. `rg`'s default regex engine does NOT support lookaround (`(?=`, `(?!`, `(?<=`); pass `--pcre2` explicitly if a command needs it, or rewrite to avoid lookaround. Prefer `rg` over GNU-`grep`-only flags (`-P`, `--perl-regexp`) throughout.

---

## Lens 1 — Routing + trigger fit

```bash
# Description content + length
awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' <SKILL>
awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print length; exit}' <SKILL>

# First-person voice check (red flags)
grep -nE '"I can help|"I will|"I am"' <SKILL>     # description in first person?

# Trigger keywords (grep -oP is GNU-only / unavailable on BSD grep — use -oE, ERE supports this pattern)
grep -oE "Trigger phrases:[^.]+" <SKILL> | head -3

# Cross-check /v routing — does /v actually invoke this skill?
grep -nE "invoke[s]? [/]?<NAME>|/<NAME>" ~/.claude/skills/v/SKILL.md
```

## Lens 2 — Contract / runtime compatibility

```bash
# Extract the contract block
awk '/^```yaml$/,/^```$/{if(/^contract:/) p=1; if(p) print}' <SKILL>

# Verify accepts: matches the Entry Point detection logic
grep -nA 5 '^\s*accepts:' <SKILL>

# V_DEPTH ownership — does the skill handle V_DEPTH=0 (standalone) AND V_DEPTH≥1 (called by /v-build)?
grep -nE 'V_DEPTH|standalone|invoked by .*v-build' <SKILL>
```

## Lens 3 — Artifact + Stop-hook correctness (F4 from failure catalog)

```bash
# What artifacts does the Stop hook accept?
grep -nE 'PRE_FLIGHT_REPORT|AGENT_REVIEW|VERIFY_DONE_REPORT|TRIVIAL_PASS|PLANNING_PASS|HANDOFF|IMPLEMENTATION_REPORT' \
  ~/.claude/hooks/check-review-artifact.sh | head -20

# What artifacts does the skill claim to produce?
grep -nE 'produces:|write[s]? `?[A-Z_]+_\$\{|write[s]? `?[A-Z_]+_\{' <SKILL>

# Cross-reference: every produced name must appear in the hook accept-list
for art in $(grep -oE '[A-Z_]+_\$\{?CLAUDE_SESSION_ID' <SKILL> | sort -u); do
  pat=$(echo "$art" | sed 's/_\${.*//')
  grep -qF "$pat" ~/.claude/hooks/check-review-artifact.sh || echo "ORPHAN ARTIFACT: $art (not in Stop hook)"
done
```

## Lens 4 — Autonomy + parallel-session safety (F5 SID-binding)

```bash
# Artifacts without SID
grep -nE '(BUILD_BLOCKER|PROGRESS_NOTE|HANDOFF|PLAN|AUDIT_REPORT)_\{[^}]*\}\.md' <SKILL> | grep -v 'CLAUDE_SESSION_ID'

# Hidden human-only steps
grep -nE 'AskUserQuestion|"ask the user|"confirm with|"wait for user|"manual approval' <SKILL>

# Unscoped shared files
grep -nE 'echo .* > /tmp/|/tmp/[a-z-]+\.txt' <SKILL>  # global /tmp files
grep -nE '\\.v/tmp/[a-z-]+\\.txt' <SKILL> | grep -v 'CLAUDE_SESSION_ID\|SID'
```

## Lens 5 — Progressive disclosure (Anthropic §4)

```bash
# Body line count vs Anthropic <500 target. `wc -l <SKILL>` counts the WHOLE file including the
# frontmatter YAML block — the Anthropic rule is about the BODY (post-frontmatter). Isolate the
# body the same way Lens 14 does (skip everything up to and including the second `---`):
awk '/^---$/{n++; next} n>=2' <SKILL> | wc -l
# Whole-file count, for reference only (do NOT use this against the 500-line target):
wc -l <SKILL>

# References depth (must be one level deep)
find $(dirname <SKILL>)/references -type d 2>/dev/null | wc -l   # should be 1 (the dir itself)
find $(dirname <SKILL>)/references -mindepth 2 -type d 2>/dev/null   # any output = violation

# Reference file sizes (no individual file should be >2x SKILL.md ideally)
wc -l $(dirname <SKILL>)/references/*.md 2>/dev/null

# Inline content that should be in references — heuristic: sections >100 lines that are pure protocol
awk '/^## /{if(prev_l){print NR-prev_l, prev_h}; prev_l=NR; prev_h=$0}END{print NR-prev_l, prev_h}' <SKILL> | sort -rn | head -5
```

## Lens 6 — Cross-skill reference integrity (F2 path drift, F15 stub-vs-detail)

```bash
# Every reference link the skill makes — verify the file exists
for ref in $(grep -oE 'references/[a-z0-9_.-]+\.md|\~/\.claude/skills/[a-z/_-]+\.md|\$\{CLAUDE_SKILL_DIR\}/[a-z0-9_./{},-]+' <SKILL> | sort -u); do
  # Resolve to filesystem path
  fp=$(echo "$ref" | sed "s|^references/|$(dirname <SKILL>)/references/|; s|^~/|$HOME/|; s|\${CLAUDE_SKILL_DIR}|$(dirname <SKILL>)|" | tr -d '"`')
  [ -e "$fp" ] || echo "MISSING REF: $ref → $fp"
done

# Section anchors — for every "see references/X.md § Y", verify Y exists in X.md
grep -nE 'references/[a-z-]+\.md\s*§\s*[A-Z]' <SKILL> | while read line; do
  ref=$(echo "$line" | grep -oE 'references/[a-z-]+\.md')
  anchor=$(echo "$line" | grep -oE '§\s*[A-Za-z0-9 -]+' | sed 's/§\s*//')
  fp="$(dirname <SKILL>)/$ref"
  if [ -f "$fp" ]; then
    grep -qF "$anchor" "$fp" || echo "MISSING ANCHOR: $line"
  fi
done
```

## Lens 7 — Test / eval coverage

```bash
# evals/ presence
[ -d "$(dirname <SKILL>)/evals" ] && echo "evals/ exists" || echo "evals/ MISSING (Anthropic recommends evals.json)"
# NOTE: evals.json's top level is an OBJECT ({"skill_name": ..., "evals": [...]}), not a bare
# array. `len(json.load(...))` on the object returns the KEY COUNT (2), not the eval-case count —
# always index into the "evals" list before taking len().
[ -f "$(dirname <SKILL>)/evals/evals.json" ] && python3 -c "import json; d=json.load(open('$(dirname <SKILL>)/evals/evals.json')); print(len(d.get('evals', d) if isinstance(d, dict) else d))" || echo "evals.json absent or invalid"

# Linter coverage — does CI lint this skill?
grep -rl "v-skill-reviewer\|<NAME>" ~/.claude/hooks/ ~/.github/workflows/ 2>/dev/null
```

## Lens 8 — Security / safety risk

```bash
# Destructive instructions
grep -nE 'rm -rf|truncate|forceDelete|DROP TABLE|--force|push --force' <SKILL>

# Broad cleanup
grep -nE 'find .* -delete|find .* -exec rm' <SKILL>

# Network calls without timeout
grep -nE 'curl |wget |fetch\(|http\.get' <SKILL> | grep -v 'timeout\|--max-time\|signal.*timeout'

# Unbounded test runs (F1 — must wrap in timeout)
grep -nE '\b(pest|vitest|jest|npx vitest|phpunit)\b' <SKILL> | grep -v 'timeout\|gtimeout\|\$TO\|\$V_TIMEOUT_CMD'
```

## Lens 9 — Human-intervention impact

```bash
# Count of AskUserQuestion + "ask the user" in current vs baseline (must NOT increase)
echo -n "current AskUserQuestion: " && grep -c "AskUserQuestion" <SKILL>
[ -n "<BASELINE>" ] && { echo -n "baseline AskUserQuestion: " && grep -c "AskUserQuestion" <BASELINE>; }

# "Stop and ask" patterns
grep -nE 'stop and ask|please [a-z]+ and re-invoke|cannot proceed' <SKILL>
```

## Lens 10 — Anthropic 2026 compliance (from anthropic-standards.md)

```bash
# Pre-flight checklist
python3 -c "
import yaml, sys
fm = yaml.safe_load(open(sys.argv[1]).read().split('---')[1])
desc = fm.get('description','')
name = fm.get('name','')
print('name slug ok:', len(name) <= 64 and all(c.islower() or c in '0123456789-' for c in name))
print('description chars:', len(desc))
print('third-person:', not any(p in desc for p in ['\"I can help', '\"I will help', '\"I am']))
print('trigger keywords:', 'Trigger phrases' in desc or any(k in desc.lower() for k in ['use this skill when', 'use whenever']))
" <SKILL>

# Reserved names
grep -nE '^name: (helper|utils|tools|anthropic-helper|claude-tools|do-stuff)$' <SKILL>

# Backup files in skill-dir root
# NOTE: `*.pre-*-bak` at a skill-dir root is the FROZEN PRE-FIX ORACLE CORPUS
# (~283 files, guarded by __tests__/v-bak-corpus-harness.test.ts via
# v/references/v-bak-corpus-test.sh). NEVER move, sweep, or .attic those —
# doing so fails the suite. Only NON-corpus backups are P3 findings.
find $(dirname <SKILL>) -maxdepth 1 \( -name "*.bak" -o -name "*.bak-*" -o -name "*.tmp" \) 2>/dev/null
```

## Lens 11 — Bash-state-persistence (F1)

```bash
# Variable set in one bash fence, used in another?
awk '/^```bash$/{in_block=1; block_n++; next} /^```$/{in_block=0; next} in_block && /^[A-Z_]+=/{
  match($0, /^[A-Z_]+/); var=substr($0, RSTART, RLENGTH)
  print "block " block_n " sets " var
}' <SKILL>

# Then grep for uses of those vars in OTHER blocks
# (Manual review — too complex for one-liner; flag for human attention)
```

## Lens 12 — Hook + banner redundancy (F3)

```bash
# Every MUST/NEVER directive in SKILL.md
grep -nE '^\*\*(MUST|NEVER|FORBIDDEN|MANDATORY|ABSOLUTE)' <SKILL>

# NOTE: "does ANY hook contain the word MUST/NEVER/FORBIDDEN" is a no-op check — nearly every
# hook file contains these words somewhere, so the loop below always returns most of the hooks
# directory regardless of which specific directive you're checking. This is NOT per-directive
# analysis. For each directive found above, extract a DISTINCTIVE term from ITS OWN text (the
# artifact name, action verb, or file path it mentions) and grep for THAT specific term instead:
DIRECTIVE_TERM="PRE_FLIGHT_REPORT"   # example — substitute the real distinctive term per directive
grep -lF "$DIRECTIVE_TERM" ~/.claude/hooks/*.sh
# A hit means a hook references the SAME concept — open the hit and confirm it ENFORCES (not just
# mentions) the rule before concluding "hook-backstopped." No hit → SOLE-DEFENSE; do not recommend
# compressing that banner.
```

## Lens 13 — `disable-model-invocation` consistency (F7)

```bash
grep -nE '^(disable-model-invocation|user-invocable|invoked-by):' <SKILL>
# Cross-check intent: who claims to invoke it?
grep -nE 'invoked.?by' <SKILL>
```

## Lens 14 — Dead `allowed-tools` grant (F8)

```bash
# Extract tools list from frontmatter
tools=$(awk -F: '/^allowed-tools:/{print $2}' <SKILL> | tr ',' '\n' | tr -d ' ')

# Extract the BODY (everything AFTER the second --- frontmatter delimiter)
# so we don't false-positive-match the allowed-tools line itself.
body=$(awk '/^---$/{n++; next} n>=2' <SKILL>)

# Also include references — a tool may be granted at the skill level
# but actually used in a reference file workflow step.
refs_body=""
if [ -d "$(dirname <SKILL>)/references" ]; then
  refs_body=$(cat "$(dirname <SKILL>)"/references/*.md 2>/dev/null)
fi

# Check each tool
for t in $tools; do
  [ -z "$t" ] && continue
  if echo "$body$refs_body" | grep -qF "$t"; then
    :  # used
  else
    echo "DEAD GRANT: $t (in allowed-tools but never referenced in body or references)"
  fi
done
```

**Why this matters:** the previous version greped the whole SKILL.md including the frontmatter `allowed-tools:` line itself — every tool always "matched" → no dead grants ever reported. Excluding the frontmatter is mandatory.

## Summary report skeleton (Workflow step 7)

After running the lens commands, populate this skeleton in the report:

```markdown
## Verification Results

| Lens | Command run | Result |
|---|---|---|
| 1 Routing | description length / first-person / triggers | <pass/fail + details> |
| 2 Contract | accepts / V_DEPTH ownership | ... |
| 3 Stop-hook | artifacts in accept-list | ... |
| 4 Autonomy | SID-binding / no /tmp leaks | ... |
| 5 Progressive disclosure | line count / refs depth | ... |
| 6 Reference integrity | all paths resolve / anchors exist | ... |
| 7 Eval coverage | evals.json present + valid | ... |
| 8 Safety | no rm -rf / unbounded curls / unbounded test runs | ... |
| 9 Human-touch | AskUserQuestion count not increased | ... |
| 10 Anthropic 2026 | pre-flight checklist | ... |
| 11 Bash-state | variable cross-call analysis | ... |
| 12 Hook+banner | MUSTs have backstops | ... |
| 13 Invocation | disable-model + user-invocable + invoked-by consistent | ... |
| 14 Tools | no dead grants | ... |
```

---

## Content & currency lenses (18-27) — added 2026-07-05

Command-backed: 18, 19, 21, 23. Lens 24 gained a command-backed stage-1 keyword+context scan 2026-08-02 (see below) but its stage-2 concrete-anchor judgment is still read-and-judge. Lenses 20, 22, 25 are read-and-judge (see catalog F25/F27/F30). `S` = the target skill dir; run over its `SKILL.md` + `references/*.md`.

```bash
S=~/.claude/skills/<target>

# Lens 18 (F23) — live-fire detection commands. Enumerate, then ACTUALLY RUN each against real input.
grep -rnE '\b(grep|rg|comm|awk|sed)\b' "$S" | grep -vE '^\s*#'
rg --type tsx x . 2>&1 | grep -qi 'unrecognized file type' && echo "INVALID rg tsx type present somewhere → -g '*.tsx'"

# Lens 19 (F24) — zero-outreach gate
grep -rniE 'cold (email|outreach)|book a demo|sales team|karma|reciprocal engagement|guest post|hand-pick|reach out to' "$S"
grep -rl 'v-core-solo-motion' "$S" || echo "MISSING zero-outreach gate citation (only required for growth/pricing/messaging/launch/beta skills)"

# Lens 21 (F26) — fabricated/stale framework APIs
grep -rnE 'Broadcast::(fake|assertBroadcasted)|Feature::percentage|Inertia::lazy|Lazy::make|BROADCAST_DRIVER|Kernel\.php|@tailwind\b|SoftDeletes|Laravel 12' "$S"

# Lens 23 (F28) — routing reachability (whole-catalog)
# Widened 2026-08-03 from `v-*/` to `*/` (with a SKILL.md existence guard) — the old pattern
# silently skipped every non-`v-`-prefixed skill dir (find-skills, interface-design), so a skill
# named outside the v- convention was never checked for routing reachability. The SKILL.md guard
# excludes references/, __tests__/, node_modules/, .attic/, archive/ for free (none carry a direct
# SKILL.md at that depth) — verified 2026-08-03 to enumerate exactly the 54 live skills, no extras.
for d in ~/.claude/skills/*/; do [ -f "$d/SKILL.md" ] || continue; n=$(basename "$d"); grep -rq "$n" ~/.claude/skills/v/SKILL.md ~/.claude/skills/references/v-orchestrator-map.md || echo "UNROUTED: $n"; done
```

```bash
# Lens 26 (F31) — prompt-pack format + body-schema conformance (pack-producing skills)
S=~/.claude/skills/<producer>
grep -rnE 'NN-\*\.md|[0-9][0-9]-\*\.md' "$S"                      # legacy shape in the producer's instructions
grep -rq '## Files' "$S" || echo "producer template never mandates ## Files (v-build scope guard)"
grep -rniE 'see (the )?(audit|plan)|refer to the (audit|plan|README)' "$S"  # non-self-contained template
~/.claude/scripts/validate-audit-prompt-packs.sh <an-emitted-PROMPT_DIR>    # full wave-form + body-schema gate
```

```bash
# Lens 27 (F32) — in-app actionability boundary (every v-audit-* skill and v-check)
S=~/.claude/skills/<audit-skill>
grep -rq 'In-App Actionability Boundary' "$S"/SKILL.md || echo "MISSING boundary citation"
# Off-stack instruction rows in the skill body or its references (each hit must be ban/boundary
# language or an in-app twin, never an instruction to flag the external capability's absence):
grep -rniE 'runbook|on.call|offsite|disaster recovery|high availab|failover|uptime (check|monitor|service)|pagerduty|uptimerobot|pingdom|status page' "$S"
grep -rniE '(sentry|rollbar|bugsnag|datadog|new relic).{0,40}(installed|configured|set ?up|missing|required)' "$S"
```

```bash
# Lens 24 (F29) — domain-completeness, two-stage (tightened 2026-08-02: a bare keyword hit is not
# evidence). Stage 1 is this command; stage 2 (does the context window carry a REAL actionable
# check, not just a matched anchor character) is still a human/model read of the grep output.
S=~/.claude/skills/<target>
grep -rniE -B10 -A10 'refund|dunning|stripe|entitlement|plan.limit|auto.?renew|negative.option|phpstan|larastan|pint|dependency|adr' "$S" 2>/dev/null \
  | grep -qE '[0-9]|`[^`]+`|::|->|/[A-Za-z0-9_.-]+/' \
  && echo "at least one charter-keyword hit is anchored (threshold/command/API/path present nearby)" \
  || echo "ALL charter-keyword hits are bare mentions — no threshold/command/API/path in any +/-10-line window (F29 keyword-present-no-check)"
```

## Lens 33 (F33) — decidable-instruction density

```bash
# Lens 33 (F33) — decidable-instruction density.
#
# SCOPE (recalibrated 2026-08-02 after the first library-wide run): scan EVERY bullet in the file.
# The original version scoped to '## What to Find' / '## Task(s)' / '## Checklist' headings — a
# library-wide sweep found only 5 of 339 files carry such a heading, so the lens found 0 hits and
# was effectively unfireable. This library's directive sections are actually named "Acceptance
# criteria", "Rules", "Constraints", "Verification Gates", "Anti-patterns", "Not for", "Best fit".
# Whitelisting heading LABELS will always drift; scan all bullets and use heading context only to
# escalate severity. Do NOT re-narrow this to a heading whitelist.
S=<SKILL-or-reference.md>
FILLER_RE='best practice|as appropriate|where relevant|consider( the)?|ensure (good|proper|appropriate)|handle (it )?correctly|follow (the )?convention|as needed|when appropriate|industry standard|appropriately|gracefully'
ANCHOR_RE='[0-9]|`[^`]+`|https?://|\$[A-Za-z_]|::|->|/[A-Za-z0-9_.-]+/|\.(php|ts|tsx|js|md|json|sh)\b'
BULLETS=$(grep -E '^[[:space:]]*[-*][[:space:]]' "$S")
TOTAL=$(printf '%s\n' "$BULLETS" | grep -c .)
ANCHORLESS=$(printf '%s\n' "$BULLETS" | grep -iE "$FILLER_RE" | grep -viE "$ANCHOR_RE")
echo "bullets: $TOTAL | filler+anchorless: $(printf '%s\n' "$ANCHORLESS" | grep -c .)"
printf '%s\n' "$ANCHORLESS"
#
# TRIAGE BEFORE REPORTING — measured false-positive classes (2026-08-02 sweep: 9772 bullets ->
# 28 filler hits -> 22 raw anchorless -> ~4 true positives). Discard a hit when the filler phrase is:
#   1. inside quoted/example text or a template placeholder ("we considered this in Step X",
#      "Edge cases I considered: <...>") — it is sample copy, not an instruction;
#   2. a TEST NAME (`it('handles X gracefully')`) — the vagueness is the scenario label, not a rule;
#   3. the OBJECT OF A PROHIBITION (v-differentiate bans generating "best practices"/"industry
#      standard" lists — the ban is decidable; the banned phrase is what matched);
#   4. under a descriptive heading (Characteristics, Don't use when) rather than a directive one;
#   5. in a duplicate tree — exclude .scriptable-work/, .attic/, archive/, *.pre-*-bak, __tests__/.
#
# SEVERITY: ratio >= 25% of a section's bullets -> P2 "filler-heavy section"; any single surviving
# anchorless bullet under a MUST/REQUIRED/MANDATORY/GATE heading or line -> P1 regardless of ratio.
#
# TWO OPERATIONAL TRAPS (both cost a real run in the 2026-08-02 sweep):
#   - NEVER pipe `grep -n`/`-H` output into the anchor test: the `file.md:123:` prefix contains
#     digits, `[0-9]` is an anchor, so every line reads as anchored and the lens silently returns 0.
#     Iterate per file and print the filename separately.
#   - This shell aliases `grep` to `ugrep -G`, which rejects some ERE this lens uses. Invoke
#     /usr/bin/grep explicitly when running the sweep, which is what an operator's script gets.
# Always re-read a flagged/cleared bullet in FULL before trusting the grep — a trailing
# parenthetical can supply an anchor a truncated window would miss.
```

## Lens 34 (F34) — description-collision / routing overlap

```bash
# Lens 34 (F34) — description-collision / routing overlap. Run once per reviewed skill against the
# whole catalog.
S=<SKILL.md>
NAME=$(basename "$(dirname "$S")")
DESC=$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$S")
PHRASES=$(echo "$DESC" | sed -E 's/^Use (when|whenever)[[:space:]]*//; s/\.$//; s/,? or /,/g; s/,? and /,/g' \
  | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | awk 'length($0)>=5' | head -3)
echo "$PHRASES" | while IFS= read -r p; do
  [ -z "$p" ] && continue
  for f in ~/.claude/skills/v*/SKILL.md; do
    [ "$(basename "$(dirname "$f")")" = "$NAME" ] && continue
    d=$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); gsub(/^"|"$/,""); print; exit}' "$f")
    echo "$d" | grep -qiF "$p" && echo "OVERLAP [$NAME vs $(basename "$(dirname "$f")")]: \"$p\""
  done
done
grep -qE 'Use instead' "$S" || echo "NOTE: $NAME has no 'Use instead' disambiguation section at all"
# Reporting rule: any single other-skill name appearing in >=2 distinct OVERLAP lines above, with no
# 'Use instead' pointer either direction, is a routing-collision finding.
```

## Lens 35 (F35) — external-standard citation accuracy

```bash
# Lens 35 (F35) — external-standard citation accuracy. Run per SKILL.md / reference
# that invokes a named standard. Stage 1 is mechanical (enumerate); stage 2 is NOT
# greppable — it needs a real source check, because the failure is a TRUE-looking
# citation of a REAL standard that says the opposite.
S=<skill-or-reference-path>
# Stage 1 — enumerate every external-standard citation with its surrounding rule
grep -nE -B2 -A2 '\b(NIST( SP)?( ?800-[0-9]+[A-Za-z]?)?|OWASP( Top 10)?( for LLM[ A-Za-z]*)?|WCAG( ?2\.[0-9])?( ?(A|AA|AAA))?|PCI[- ]?DSS|GDPR|CCPA|CPRA|SOC ?2|HIPAA|RFC ?[0-9]+|CIS Benchmark)\b' "$S"
# Stage 2 — for EACH hit: WebSearch the standard's CURRENT revision and confirm it
#   supports the rule. Standards reverse themselves (NIST SP 800-63B Rev.3 reversed
#   Rev.2 on password composition + rotation; Rev.4 (2025) reaffirmed Rev.3).
#   Record "<standard> <revision> (<year>)" in the finding. A bare "NIST guidelines"
#   with no revision is itself a P2 — unversioned citations rot silently.
# Stage 3 — flag any citation used to justify a rule the source PROHIBITS → P0.
grep -nE 'NIST guidelines|per NIST|OWASP recommends|WCAG requires' "$S"   # unversioned-citation smell
```
