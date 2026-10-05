#!/usr/bin/env bash
# validate-audit-prompt-packs.sh — the runnable gate for the unified prompt-pack standard.
#
# Enforces the single wave-form standard defined in
# skills/references/v-runnable-pack-convention.md (§ Canonical form + § Pack body schema):
#   - a dated dir with a 00-README.md map + flat .txt wave packs
#   - every pack: first non-blank line is a /v invocation, .txt extension (legacy .md warns)
#   - implementation packs carry the load-bearing '## Files' H2 (v-build scope guard)
#   - packs are self-contained (no "see the audit/plan/sibling pack")
#   - no git commit/push instruction; no YAML frontmatter; stub (<10) / oversize (>3500) bounds
#   - per-pack BYTE cap: >25000 bytes = run-v-packs' PACK_MAX_BYTES ⇒ the runner never runs it
#   - wave-map <-> pack-file parity in 00-README.md (no phantom/orphan packs)
#   - '## Verified context' packs carry requires:/BLOCKED gates, the IMPLEMENTATION_REPORT witness,
#     per-claim [verified main@<sha>] truth stamps + the generation-time evidence line (F2 2026-07-05)
#   - exactly ONE 99-* final verify pack — HARD failure, was advisory (F2 2026-07-05)
#
# Scope note (F2 sync, 2026-07-05): audit-family packs share this SAME runnable contract — their
# emitted packs are remediation/IMPLEMENTATION packs with mandatory closing waves + a 99-verify.txt
# closer (_v-audit.md § pack emission; v-core-prompt-pack.md: all producer carve-outs retired
# 2026-07-05). The audit REPORT is read-only; the packs are not. So both hard gates apply here,
# identically to the convention's § Self-validate fence — the two are documented as interchangeable
# ("run the § Self-validate block ... or validate-audit-prompt-packs.sh") and MUST stay in parity.
#
# Usage:  validate-audit-prompt-packs.sh <PROMPT_DIR>
#         PROMPT_DIR=.v-prompt-packs/v-audit-seo-07-05 validate-audit-prompt-packs.sh
# Exit:   0 = PASS, 1 = ISSUES (each printed), 2 = bad invocation.
set -u
PROMPT_DIR="${1:-${PROMPT_DIR:-}}"
[ -n "$PROMPT_DIR" ] || { echo "usage: $0 <PROMPT_DIR>" >&2; exit 2; }
[ -d "$PROMPT_DIR" ] || { echo "no such dir: $PROMPT_DIR" >&2; exit 2; }

FAIL=0; note(){ FAIL=1; echo "  - $1"; }
[ -f "$PROMPT_DIR/00-README.md" ] || note "master 00-README.md missing"

packs=0; n99=0
while IFS= read -r f; do
  b=$(basename "$f"); case "$b" in 00-README.md|README.md) continue ;; esac
  first=$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)
  case "$first" in '/v '*|'/v-'*|'/v') : ;; *) note "$b first line is not a /v invocation"; continue ;; esac
  packs=$((packs+1)); case "$b" in 99-*) n99=$((n99+1)) ;; esac
  case "$b" in *.md) note "$b is a legacy .md pack — producers must emit .txt (runner still runs it, but new output must be .txt)" ;; esac
  lc=$(wc -l < "$f" | tr -d ' ')
  [ "$lc" -ge 10 ] || note "$b looks like a stub (<10 lines)"
  [ "$lc" -le 3500 ] || note "$b is $lc lines (>3500) — split into narrower packs"
  # RUNNER PARITY (2026-09-11): run-v-packs' is_pack()/oversized_packs() (run-v-packs-lib/10-discovery.sh)
  # reject any pack whose `wc -c` exceeds PACK_MAX_BYTES=25000 — it is SKIPPED, never run, and the only
  # runtime signal is a single ⚠ banner line (`--dry-run` still exits 0; a real run exits non-zero for this
  # ONLY when no other pack is runnable). The line bounds above cannot substitute: a 28-31KB pack is
  # ~250-320 lines, well inside them. Two live misses on 2026-09-11 — a 28,116-byte pack and two
  # 31KB packs each passed BOTH Step-5 checks. Predicate is byte-identical to the runner's
  # (`-gt` ⇒ exactly 25000 passes); re-read the constant there before changing this number.
  bytes=$(wc -c < "$f" | tr -d ' ')
  [ "${bytes:-0}" -le 25000 ] || note "$b is $bytes bytes (>25000 = run-v-packs PACK_MAX_BYTES) — the runner SKIPS it as a concatenated bundle, so it would never run; split into self-contained -part1/-part2 packs in consecutive waves"
  head -2 "$f" | grep -q '^---' && note "$b has YAML frontmatter (forbidden — first line must be /v)"
  # Body schema: implementation packs need the load-bearing '## Files' (read-only packs exempt)
  case "$b" in *review*|*pre-flight*|99-*) : ;;
    *) grep -qE '^##[[:space:]]+Files\b' "$f" || note "$b (implementation pack) missing required '## Files' section (v-build scope guard)" ;;
  esac
  # Self-contained: never send the cold agent to the source artifact
  grep -qiE 'see (the )?(audit|plan)( (json|report|file))?\b|per the (audit|plan)\b|refer to (the )?(audit|plan|00-README|README)|the audit (json|report)|as (described|shown) in (the plan|00-README|pack [0-9])' "$f" \
    && note "$b references an external artifact (audit/plan/sibling/README) — packs must be self-contained (inline it into ## Context)"
  # No commit/push instruction (same 4 shapes as the convention's self-validate + the vitest guard)
  grep -qiE '^[[:space:]]*git[[:space:]]+(commit|push)|commit( with)?:[[:space:]]*.?[[:space:]]*git|git[[:space:]]+add.*&&.*git[[:space:]]+commit|git[[:space:]]+(commit|push).*[[:space:]]-[a-z]*m' "$f" \
    && note "$b contains a git commit/push instruction (packs end 'leave staged; do not commit')"
  # Precondition-check-present + staged-handoff-witness + TRUTH-stamping (synced 2026-07-05 from the
  # convention's § Self-validate fence — R3 P0-1 phantom-context class + F2 false-"already landed" class).
  if grep -q '^## Verified context' "$f" 2>/dev/null; then
    grep -qi '^requires:' "$f" || note "$b has '## Verified context' but no machine-checkable 'requires:' precondition grep (R3 P0-1 phantom-context class)"
    grep -qi 'BLOCKED' "$f" || note "$b has '## Verified context' but no runtime precondition STOP+BLOCKED instruction for a drifted/missing anchor"
    if grep -qi 'leave staged' "$f" 2>/dev/null; then
      grep -qi 'IMPLEMENTATION_REPORT' "$f" || note "$b ends 'leave staged' (a runner-managed staged-handoff exit) but never instructs writing IMPLEMENTATION_REPORT_<sid>.md (the resolver witness the staged-handoff contract checks for)"
    fi
    while IFS= read -r vb; do
      [ -z "$vb" ] && continue
      printf '%s\n' "$vb" | grep -qE '\[verified main@[0-9a-f]{7,40}\]|UNVERIFIED' \
        || note "$b Verified-context claim lacks a generation-time truth stamp — every claim needs '[verified main@<sha>]' (from a real git show main:<path> grep) or an explicit '[UNVERIFIED — verify before relying]' downgrade (false-already-landed class, F2 2026-07-05): $vb"
    done < <(awk '/^## Verified context/{s=1;next} s&&/^## /{exit} s&&/^- /' "$f")
    grep -qE '^Generation-time verification:.*git show main:' "$f" \
      || note "$b has '## Verified context' but no 'Generation-time verification: … git show main:<path> …' evidence line under the heading (the recorded proof the claims were live-checked, not passed through on faith)"
  fi
done < <(find "$PROMPT_DIR" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) -not -path "$PROMPT_DIR/.*" 2>/dev/null | sort)
[ "$packs" -ge 1 ] || note "no packs found (a pack = .txt whose first line is /v)"
# HARD gate (F2 2026-07-05, was an advisory note — kept in parity with the convention's fence): a tree
# MUST contain exactly ONE 99-* final verify pack (zero ⇒ nothing re-asserts the waves landed; extras
# are silently ignored by the runner).
[ "$n99" -eq 1 ] || note "tree has $n99 '99-*' final verify pack(s) — exactly ONE is REQUIRED (hard gate; refuse to emit the tree without it)"

# wave-map <-> pack-file parity (phantom/orphan detection)
if [ -f "$PROMPT_DIR/00-README.md" ]; then
  readme_names=$(grep -oE '[A-Za-z0-9_.-]+\.(txt|md)' "$PROMPT_DIR/00-README.md" 2>/dev/null | sort -u | grep -vE '^(00-README\.md|README\.md)$')
  while IFS= read -r rn; do
    [ -z "$rn" ] && continue
    [ -n "$(find "$PROMPT_DIR" -maxdepth 2 -type f -name "$rn" 2>/dev/null | head -1)" ] \
      || note "wave-map names '$rn' in 00-README.md but no such pack file exists (phantom pack)"
  done <<< "$readme_names"
  while IFS= read -r f; do
    [ -z "$f" ] && continue; b=$(basename "$f")
    case "$b" in 00-README.md|README.md) continue ;; esac
    printf '%s\n' "$readme_names" | grep -qxF "$b" || note "$b exists on disk but is absent from 00-README.md's wave map (orphan pack)"
  done < <(find "$PROMPT_DIR" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) -not -path "$PROMPT_DIR/.*" 2>/dev/null | sort)
fi

if [ "$FAIL" = 0 ]; then echo "PACK TREE OK ($packs packs)"; exit 0
else echo "PACK TREE ISSUES ($PROMPT_DIR) — fix then re-validate"; exit 1; fi
