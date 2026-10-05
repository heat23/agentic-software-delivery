#!/usr/bin/env bash
# PreToolUse hook: blocks `git commit` when mandatory gates are missing/invalid.
# Version: 5.0.0   ← bumped for HOOK-2 fix
#
# Changes in v5:
#   HOOK-2 (CRITICAL): FAIL detection now matches the W12-3 status-first table format
#     `| FAIL | <Gate> | <Notes> |` AND legacy `[FAIL]`/`❌`/`status: fail` patterns.
#     The previous v4 regex missed the W12-3 format — silently allowing commits with
#     failing pre-flight gates.
#   Also recognizes `Overall Status: FAIL` (with optional leading words) — previously
#     anchored to `^status:` which never matched the canonical "Overall Status:" line.
#
# Changes in v4:
#   AVF-002: Removed headless exit-0 bypass. Headless sessions still go through
#            all artifact gate checks (PRE_FLIGHT + AGENT_REVIEW).
#   AVF-004: Uses shared lib/validation.sh for structural artifact validation.
set -euo pipefail



# === R3 defensive: tolerate malformed JSON ===
# jq exiting non-zero on malformed input (rc 2 parse / rc 3 type-mismatch)
# propagates through command substitution and would otherwise crash this
# hook under set -e. Disable errexit only; -u (nounset) and pipefail remain.
# Existing 2>/dev/null + explicit empty-string fallbacks handle the
# now-undefined values gracefully.
set +e

# Resolve hooks/lib path robustly (works under any $HOME).
if [ -z "${HOOKS_LIB_DIR:-}" ]; then
  HOOKS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
fi

source "$HOOKS_LIB_DIR/require-jq.sh"
require_jq_or_deny

INPUT=$(cat)

# HOOKS_LIB_DIR was already resolved above (exported override honored, else derived from
# BASH_SOURCE). Do NOT re-derive it unconditionally here — that clobbered an exported value and
# made the hook impossible to load from a relocated/mutant copy, so the mutation gate could never
# exercise this commit-blocking enforcement at all (audit 2026-06-18, survivor S-2). The seam is
# now: caller exports HOOKS_LIB_DIR=<real lib> and points at the mutant copy via V_PRECOMMIT_OVERRIDE.

# Load headless detection (no longer bypasses gates — only used for context)
if [[ -f "$HOOKS_LIB_DIR/headless-detect.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/headless-detect.sh"
fi

# Load shared validation functions (AVF-004)
if [[ -f "$HOOKS_LIB_DIR/validation.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/validation.sh"
fi

# F1 (2026-07-05): shared artifact-resolution picker (gauntlet_find_artifact) — single
# source of truth with check-review-artifact.sh and v-gauntlet-attest.sh. See the
# function's header comment in gauntlet-witness.sh for the 3-way split-brain this closes.
if [[ -f "$HOOKS_LIB_DIR/gauntlet-witness.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/gauntlet-witness.sh"
fi

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# ── ORCHFIX-H2 (forensics 2026-07-02, F-2 — recurrence of the raw-git-landing class) ──
# A raw `git merge <sid-branch>` in the MAIN root bypasses v-merge-back.sh entirely: no commit
# witness (attribution collapsed across fleet logs), no durable artifact consolidation, no
# W-GATE verdict check, no post-merge re-verify, and nothing verifying the main root's sibling WIP
# is untouched by the merge. The prior remediation only removed the raw-merge HINT (advisory) — the
# mole returned interactively. Deny raw merges of /v SESSION branches only: the merged ref must
# carry an 8+ hex SID slug AND exist as a local branch, and the target must be the MAIN checkout
# (git-dir == git-common-dir; a merge inside a linked worktree is that session's own business).
# --abort/--continue/--quit always pass. Deliberate override: V_ALLOW_RAW_MERGE=1.
# KNOWN RESIDUAL (REV-4, adversarial review 2026-07-03): a dynamically-resolved ref
# (`git merge $(...)`, `git merge "$VAR"`) carries no literal hex slug in the command text and
# passes ungated — same accepted text-pattern-hook limitation as the W5F merge-commit catalogue.
# The fix targets the observed accidental/self-inflicted class (a literal raw merge of a session branch).
# PRECISION FIX (forensic 2026-07-09): the old trailing `merge\b` also matched
# `git merge-base` / `git merge-tree` / `git merge-file` (a hyphen IS a \b word boundary), so the
# READ-ONLY ancestry checks this guard's own remediation flow — and the forensics skills — rely on
# (`git merge-base --is-ancestor <sid-branch> main`) were denied whenever the command text carried
# an 8-hex slug in the main checkout. Require whitespace/`;`/EOL after `merge` so only the real
# merge subcommand matches; the extraction below mirrors the same shape.
if [ "${V_ALLOW_RAW_MERGE:-0}" != "1" ] \
   && echo "$COMMAND" | grep -qE '\bgit\s+(-[A-Za-z]\s+[^[:space:]]+\s+|--[A-Za-z0-9-]+(=[^[:space:]]+)?\s+)*merge([[:space:]]|;|$)' \
   && ! echo "$COMMAND" | grep -qE -- '--abort|--continue|--quit'; then
  _m_ref="$(printf '%s' "$COMMAND" | grep -oE '\bmerge([[:space:]]|;|$)[^;|&]*' | grep -oE '[A-Za-z0-9._/-]*[0-9a-f]{8}[A-Za-z0-9./-]*' | head -1)"
  if [ -n "$_m_ref" ]; then
    _m_dir="$(printf '%s' "$COMMAND" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+"?([^";|&[:space:]]+)"?.*/\1/p' | head -1)"
    [ -n "$_m_dir" ] || _m_dir="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
    [ -n "$_m_dir" ] || _m_dir="$PWD"
    _m_dir="${_m_dir/#\~/$HOME}"
    _m_gd="$(git -C "$_m_dir" rev-parse --git-dir 2>/dev/null || true)"
    _m_cd="$(git -C "$_m_dir" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$_m_gd" ] && [ "$_m_gd" = "$_m_cd" ] \
       && git -C "$_m_dir" show-ref --verify --quiet "refs/heads/${_m_ref}" 2>/dev/null; then
      _m_reason="MERGE BLOCKED (ORCHFIX-H2/raw-git-landing): merging /v session branch '${_m_ref}' with raw \`git merge\` in the MAIN checkout bypasses v-merge-back.sh — no commit witness is written (session-log attribution collapses: fleet logs recorded wrong commit counts), no durable artifact consolidation, no W-GATE verdict check, no post-merge re-verify. Land it through the sanctioned path instead:\n  bash ~/.claude/skills/v/references/v-merge-back.sh\n(If this is a deliberate non-/v merge, re-run with V_ALLOW_RAW_MERGE=1.)"
      jq -n --arg reason "$_m_reason" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
    fi
  fi
fi

# Only intercept git commit commands.
# W5G-2: tolerate global options between `git` and `commit` — `git -C <dir>
# commit`, `git -c k=v commit`, `git --git-dir=X commit` previously never
# matched at all, so the ENTIRE hook self-skipped for those shapes (a bypass
# one level above the staged-set computation this fix targets).
if ! echo "$COMMAND" | grep -qE '\bgit\s+(-[A-Za-z]\s+[^[:space:]]+\s+|--[A-Za-z0-9-]+(=[^[:space:]]+)?\s+)*commit\b'; then
  exit 0
fi

# Exempt specific operational commits that have their own quality gates:
#
# [v-merge-all] — state-capture commits before consolidation. Not new code delivery;
#   the merge-all session runs its own pre-flight AFTER merging (Step 4).
#
# [v-ci-fix] — targeted CI repair commits. These fix already-reviewed code that is
#   failing in CI. The CI pipeline itself is the quality gate; requiring pre-flight
#   artifacts would block the repair loop (diagnose → fix → commit → push → poll CI).
#
# [v-chore] — config/tooling/formatting-only commits (no production logic). These
#   have no test surface (e.g. .prettierignore, .gitignore, generated file baselines).
#
# Only these tags are exempted; all other checks (secrets, etc.) still apply.
if echo "$COMMAND" | grep -qE '\[v-merge-all\]|\[v-ci-fix\]|\[v-chore\]'; then
  exit 0
fi

# ── W5G-2 (forensic 2026-06-07): resolve the git TARGET repo from the command ──
# Production case: `cd <worktree> && git commit` committed gate artifacts from
# inside a worktree while this hook inspected the staged set of ITS OWN cwd
# (the main checkout, where nothing was staged) → the W5F-10 deny never saw
# them; the same files were correctly denied 30 min later from a main-root cwd.
# Resolve the repo the command actually targets: `git -C <dir>` wins (it scopes
# the git invocation itself), else the LAST `cd <dir>` preceding the first
# `git commit` in the command. Relative paths resolve against the hook cwd; a
# non-existent dir falls back to the hook cwd (pre-W5G behavior). No \b: BSD
# sed has no word-boundary escape (W71 portability lesson).
# SREV-003 (adversarial review 2026-06-07): `--work-tree=<dir>` names the working
# tree the staged set belongs to — resolve it FIRST (it outranks -C for index
# location when both appear, and was an uncovered bypass shape).
_w5g2_tgt=$(printf '%s\n' "$COMMAND" \
  | sed -nE 's/.*--work-tree=("([^"]+)"|'\''([^'\'']+)'\''|([^[:space:]]+)).*/\2\3\4/p' \
  | head -1)
if [ -z "$_w5g2_tgt" ]; then
  _w5g2_tgt=$(printf '%s\n' "$COMMAND" \
    | sed -nE 's/.*(^|[^[:alnum:]_])git[[:space:]]+-C[[:space:]]+("([^"]+)"|'\''([^'\'']+)'\''|([^[:space:]]+)).*/\3\4\5/p' \
    | head -1)
fi
if [ -z "$_w5g2_tgt" ]; then
  # Truncate each line at the first `git commit`, drop everything after that
  # line, then take the LAST command-position `cd <dir>`.
  _w5g2_pre=$(printf '%s\n' "$COMMAND" | awk '{ i=index($0,"git commit"); if (i>0) { print substr($0,1,i-1); exit } print }')
  _w5g2_tgt=$(printf '%s\n' "$_w5g2_pre" \
    | grep -oE '(^|[;&|][[:space:]]*)cd[[:space:]]+("[^"]+"|'\''[^'\'']+'\''|[^;&|[:space:]]+)' 2>/dev/null \
    | tail -1 | sed -E 's/^.*cd[[:space:]]+//' | sed -E 's/^["'\'']//; s/["'\'']$//')
fi
GIT_TGT="$PWD"
if [ -n "$_w5g2_tgt" ]; then
  case "$_w5g2_tgt" in
    "~") _w5g2_tgt="$HOME" ;;
    "~/"*) _w5g2_tgt="$HOME/${_w5g2_tgt#"~/"}" ;;
    /*) : ;;
    *) _w5g2_tgt="$PWD/$_w5g2_tgt" ;;
  esac
  if [ -d "$_w5g2_tgt" ]; then
    GIT_TGT="$_w5g2_tgt"
  fi
fi

if ! git -C "$GIT_TGT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

REPO_ROOT=$(git -C "$GIT_TGT" rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi

# ── W5F-10 (forensic 2026-06-06): gate artifacts must never be COMMITTED ─────────────
# Wave-1 packs committed gate artifacts into main three separate ways (one rewrote +
# committed an AGENT_REVIEW "to canonical hook-validated format"; one committed a pack's
# PRE_FLIGHT/AGENT_REVIEW; one carried a 16KB bare AGENT_REVIEW.md) — and
# the stale tracked copies then propagate into every new worktree as decoy artifacts (the
# W4B1 bare-artifact class). Artifacts are session telemetry: they live in `.v/artifacts/`
# (gitignored via .v/.gitignore), never in history. This deny fires when the about-to-be-
# committed set contains a gate-artifact-named file outside `.v/`. Placed AFTER the
# [v-merge-all]/[v-ci-fix]/[v-chore] tag exemptions above by design: merge-all's
# state-capture commits sweep the whole dirty tree and have their own lifecycle.
# Unambiguous /v artifact names match bare or suffixed; generic words (HANDOFF/BLOCKED/…)
# require the SID-suffix shape so a repo's own docs/BLOCKED.md can never false-match.
_W5F10_RE='(^|/)((PRE_FLIGHT_REPORT|AGENT_REVIEW|VERIFY_DONE_REPORT|QA_REPORT|QA_REMEDIATION|UX_CRITIQUE|WORKFLOW_VERIFICATION|IMPACT_MAP|DISPATCH_PROVENANCE|SESSION_LOG)(_[^/]*)?|(HANDOFF|BLOCKED|TRIVIAL_PASS|PLANNING_PASS|IMPLEMENTATION_REPORT)_[0-9a-f]{8}[^/]*)\.(md|yaml|yml|log)$'
# --diff-filter=d EXCLUDES deletions: committing the REMOVAL of a tracked artifact is the
# cleanup this rule exists to encourage — only adding/modifying artifact content is denied.
_w5f10_candidates=$(git -C "$GIT_TGT" diff --cached --name-only --diff-filter=d 2>/dev/null || true)
# Two ways a commit includes UNSTAGED working-tree content (FND-003 + the -a class):
#   (1) `git commit -a` / `--all` (incl. -am/-qa…) — all tracked-modified files. Short-opt
#       token must be single-dash + contain 'a' so `--amend` can never false-match.
#   (2) `git commit [-m msg] -- <pathspec>` — the working-tree version of the NAMED paths,
#       with nothing staged (the exact hole codex found). Add the HEAD
#       working-tree scan whenever EITHER form is present; the artifact-name regex below
#       filters to gate artifacts regardless, so widening the candidate set is safe.
if echo "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b[^;|&]*([[:space:]]-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|[[:space:]]--all([[:space:]]|$)|[[:space:]]--[[:space:]])'; then
  _w5f10_candidates="$_w5f10_candidates
$(git -C "$GIT_TGT" diff --name-only --diff-filter=d HEAD 2>/dev/null || true)"
fi
STAGED_ARTIFACTS=$(printf '%s\n' "$_w5f10_candidates" | awk 'NF' | sort -u \
  | grep -vE '(^|/)\.v/' | grep -E "$_W5F10_RE" | head -5 || true)
if [[ -n "$STAGED_ARTIFACTS" ]]; then
  REASON="COMMIT BLOCKED (W5F-10): gate artifact file(s) are in the commit set: $(printf '%s' "$STAGED_ARTIFACTS" | tr '\n' ' '). Session artifacts (PRE_FLIGHT_REPORT/AGENT_REVIEW/VERIFY_DONE/QA/SESSION_LOG/HANDOFF/…) are telemetry, not source — they belong in .v/artifacts/ (gitignored), never in git history. Committed copies become stale decoys in every future worktree (W4B1 class; observed 2026-06-06). Unstage them (git restore --staged <file>), move them to .v/artifacts/ if needed (bash ~/.claude/skills/v/references/v-artifact-consolidate.sh <SID>), then commit the source changes only."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# W70: canonical SID resolver (env + runtime-file fallback + stdin JSON)
source "$HOME/.claude/hooks/lib/resolve-sid.sh"
SESSION_ID=$(resolve_sid "$INPUT")
IMPLEMENTATION_ONLY_MODE="${CLAUDE_ECOSYSTEM_IMPLEMENTATION_ONLY:-0}"

if [[ "$IMPLEMENTATION_ONLY_MODE" = "1" ]]; then
  REASON="COMMIT BLOCKED: runner-managed implementation-only remediation sessions must not create commits. Let the external remediation runner manage unstaged changes and post-session gates."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# ── P12 (forensic 2026-06-20): commit-absorption guard ──────────────
# A session that ran `git add` into the SHARED index but did NOT commit leaves its files
# staged; the NEXT session's `git commit` sweeps them in. On 2026-06-20 a commit
# absorbed a sibling session's controller + config
# work — the commit message then LIED about what changed, and a revert/bisect of
# that commit would silently take the sibling work down with it. Block a commit whose
# set contains file(s) PROVABLY authored by ANOTHER session (in its writes-log, not ours).
# Reuses _w5f10_candidates (the staged set + the working-tree scan added for -a/--all/-- pathspec).
# Tagged [v-merge-all]/[v-ci-fix]/[v-chore] commits already exited above; ff-only merge-backs
# never reach a commit hook. Escape hatch: V_ALLOW_FOREIGN_COMMIT=1 for a deliberate cross-session commit.
if [ -n "$SESSION_ID" ] && [ "${V_ALLOW_FOREIGN_COMMIT:-0}" != "1" ] && [[ -f "$HOOKS_LIB_DIR/session-writes.sh" ]]; then
  # shellcheck disable=SC1090
  source "$HOOKS_LIB_DIR/session-writes.sh"
  # C-4a (round-3 2026-07-02): P12 defends a SHARED index — the absorption incident it
  # cites happened on the main root. In a LINKED worktree (git-dir != git-common-dir) whose CURRENT
  # BRANCH embeds THIS session's own full SID, the index is private: no sibling stages into it, so a
  # foreign-ledger match here can only FALSE-block (stale historical ledgers + the C-3 capture gap
  # stranded a finished, review-approved multi-file feature at commit). Skip P12 for that exact shape only;
  # the shared main root and any worktree NOT branded with this session's SID keep the full check.
  _p12_own_wt=0
  _p12_gd="$(git -C "$GIT_TGT" rev-parse --git-dir 2>/dev/null || true)"
  _p12_cd="$(git -C "$GIT_TGT" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$_p12_gd" ] && [ -n "$_p12_cd" ] && [ "$_p12_gd" != "$_p12_cd" ]; then
    case "$(git -C "$GIT_TGT" branch --show-current 2>/dev/null || true)" in
      *"$SESSION_ID"*) _p12_own_wt=1 ;;
    esac
    # ORCHFIX item 4 (P1, plan 2026-07-03 / SREV-015): the branch-name substring check above only
    # recognizes "my own worktree" when the FULL SID literally appears in the branch text — but this
    # ecosystem's real worktree-creation conventions (v-build-workflows.md, v-worktree-adopt-or-create.sh)
    # routinely name branches with just a descriptive slug or an 8-char short-SID (e.g. `fix/slug-a1atest`,
    # `build/example-feature-$SIDA`), never the full 36-char UUID. Every SID-less/short-SID-branch worktree
    # therefore fell through to _p12_own_wt=0 and got the repo-wide sibling-ledger scan even though its
    # index is JUST AS PRIVATE as a SID-branded one (git-dir != git-common-dir is what makes an index
    # private, not the branch's name) — reproduced in a production session (a SID-less-branch worktree commit blocked
    # by P12 despite committing only its own files). Add a second, independent proof of "my own worktree":
    # the worktree's OWN `.claude-session-lock` names THIS session's SID (the authoritative
    # adoption/ownership record — session-lock-parse.sh, already used by files_attributable_to_other_sessions
    # for liveness). This does not weaken the existing branch-name check; it only WIDENS recognition of a
    # session's own private worktree via a second, independently-verifiable signal.
    if [ "$_p12_own_wt" != 1 ]; then
      _p12_lock_lib="${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/session-lock-parse.sh"
      if [ -f "$_p12_lock_lib" ]; then
        # shellcheck disable=SC1090
        . "$_p12_lock_lib" 2>/dev/null
        if command -v _lock_sid >/dev/null 2>&1 && [ -f "$GIT_TGT/.claude-session-lock" ]; then
          _p12_lock_sid="$(_lock_sid "$GIT_TGT/.claude-session-lock" 2>/dev/null || true)"
          [ -n "$_p12_lock_sid" ] && [ -n "$SESSION_ID" ] && [ "$_p12_lock_sid" = "$SESSION_ID" ] && _p12_own_wt=1
        fi
      fi
    fi
  fi
  # P12-PATHSPEC-FP (audit 2026-06-21; comment corrected by SME review M3): _w5f10_candidates widens to the FULL
  # working tree on a `-- <pathspec>` commit (so the artifact check above can catch an artifact named via
  # pathspec). But `git commit -- <paths>` commits ONLY the named paths — so a sibling's dirty file that is NOT
  # named is not absorbed; reusing the widened set here false-blocked the very `git commit -- <your-files>`
  # remediation this gate's own message recommends. Scope P12 to the staged set, PLUS the working-tree scan ONLY
  # for a true -a/--all (which DOES sweep every tracked-modified file). RESIDUAL (deliberate, M3): `git commit --
  # <sibling-file>` that NAMES a foreign tracked-but-unstaged file DOES absorb it and is NOT caught here (the
  # named file isn't in `diff --cached`) — that is an explicit, consenting act covered by V_ALLOW_FOREIGN_COMMIT,
  # not the accidental shared-index absorption P12 exists to block. Do NOT add the working-tree scan for `-- pathspec`.
  _p12_set=$(git -C "$GIT_TGT" diff --cached --name-only --diff-filter=d 2>/dev/null || true)
  if echo "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b[^;|&]*([[:space:]]-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|[[:space:]]--all([[:space:]]|$))'; then
    _p12_set="$_p12_set
$(git -C "$GIT_TGT" diff --name-only --diff-filter=d HEAD 2>/dev/null || true)"
  fi
  _p12_set=$(printf '%s\n' "$_p12_set" | awk 'NF' | grep -vE '(^|/)\.v/' | sort -u || true)
  # ORCHFIX-E1 (P12-PATHSPEC-FP round 2 — forensics 2026-07-02): the 2026-06-21 fix above
  # removed the working-tree widening for `-- <pathspec>` commits but left the STAGED-set overreach:
  # `git commit -- <own-files>` still carried the sibling's staged-but-unnamed files in _p12_set and
  # blocked exactly the pathspec remediation this gate's own message recommends. The forced
  # workaround (unstage the sibling's index entries → commit → re-stage) is a live cross-session index
  # mutation WORSE than the risk P12 prevents. For a pathspec commit WITHOUT -a/--all, intersect the
  # set with the named paths. Glob-bearing pathspecs (*?[) keep the full staged set (a glob CAN sweep
  # a sibling's staged file). Deliberately NAMING a foreign file stays covered by V_ALLOW_FOREIGN_COMMIT
  # (M3 residual, unchanged).
  if echo "$COMMAND" | grep -qE '\bgit[[:space:]][^;|&]*\bcommit\b[^;|&]*[[:space:]]--[[:space:]]' \
     && ! echo "$COMMAND" | grep -qE '\bgit[[:space:]]+commit\b[^;|&]*([[:space:]]-[a-zA-Z]*a[a-zA-Z]*([[:space:]]|$)|[[:space:]]--all([[:space:]]|$))'; then
    _p12_spec="${COMMAND##*-- }"
    _p12_spec=$(printf '%s' "$_p12_spec" | tr -d '"'"'"'\\')
    if printf '%s' "$_p12_spec" | grep -q '[*?[]'; then
      : # glob pathspec — cannot prove which staged files it names; keep the full staged set
    else
      # REV-3 hardening (adversarial review 2026-07-03): whitespace TOKENIZING silently emptied
      # the set for any pathspec containing a spaced filename ("file with spaces.txt" split into
      # 3 tokens matching nothing → foreign check skipped ENTIRELY). Boundary-anchored SUBSTRING
      # containment instead: a staged file stays in the set iff the (quote-stripped) spec text
      # contains it at a token boundary. Fail direction is toward KEEPING files (→ the check
      # still runs → worst case the pre-fix false-block, never a skipped absorption check).
      _p12_spec_pad=" ${_p12_spec} "
      _p12_set=$(printf '%s\n' "$_p12_set" | while IFS= read -r _p12f; do
        [ -z "$_p12f" ] && continue
        case "$_p12_spec_pad" in
          (*" ${_p12f} "*|*"/${_p12f} "*) printf '%s\n' "$_p12f" ;;   # leading ( for bash 3.2 inside $(...)
        esac
      done)
    fi
  fi
  if [ "$_p12_own_wt" != 1 ] && [ -n "$_p12_set" ]; then
    _p12_foreign=$(cd "$GIT_TGT" 2>/dev/null && printf '%s\n' "$_p12_set" \
                     | files_attributable_to_other_sessions "$SESSION_ID" | head -8 || true)
    if [ -n "$_p12_foreign" ]; then
      REASON="COMMIT BLOCKED (P12/absorption): the commit set includes file(s) ANOTHER session authored: $(printf '%s' "$_p12_foreign" | tr '\n' ' '). On a shared index, one session's \`git add\` followed by another session's \`git commit\` sweeps the first session's staged work into your commit — on 2026-06-20 a commit absorbed a sibling's controller and config work, so the git history lied about what changed and a revert would have silently dropped unrelated work. Commit ONLY your own files with an explicit pathspec: git commit -- <your-files>. (If you truly intend to commit another session's work, re-run with V_ALLOW_FOREIGN_COMMIT=1.)"
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
    fi
  fi
fi

# ORCHFIX-C: this inline copy had DRIFTED from the Stop gate's (10 vs 40 extensions) and both
# omitted executable config — the exact yml-lands-ungated class. Single source now:
# hooks/lib/code-ext-pattern.sh (pattern + telemetry-artifact exemption). Fallback = same values.
if [ -f "$HOOKS_LIB_DIR/code-ext-pattern.sh" ]; then
  # shellcheck source=lib/code-ext-pattern.sh
  source "$HOOKS_LIB_DIR/code-ext-pattern.sh"
else
  CODE_EXT_PATTERN='\.(php|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|rb|go|rs|java|kt|kts|swift|c|cc|cpp|cxx|h|hh|hpp|cs|scala|ex|exs|sh|bash|zsh|sql|m|mm|dart|lua|pl|pm|r|clj|cljs|erl|hs|yml|yaml|json|neon|toml|lock)$|(^|/)Dockerfile[^/]*$|(^|/)Makefile$|(^|/)\.husky/[^/.]+$|(^|/)\.github/workflows/[^/]+$'
  CODE_EXT_EXEMPT='(^|/)(SESSION_LOG_[^/]*\.ya?ml(\.invalid)?|OP_TELEMETRY_[^/]*\.json|[A-Z][A-Z0-9_]*_(AUDIT|REPORT)_[^/]*\.json)$|(^|/)\.v/|(^|/)\.v-prompt-packs/|(^|/)\.audit[0-9]*/'
fi
STAGED_CODE=$(git -C "$GIT_TGT" diff --cached --name-only 2>/dev/null | grep -E "$CODE_EXT_PATTERN" | grep -vE "$CODE_EXT_EXEMPT" | head -1 || true)

# No staged code => no quality-gate check required for this commit
if [[ -z "$STAGED_CODE" ]]; then
  exit 0
fi

if [[ -z "$SESSION_ID" ]]; then
  REASON="COMMIT BLOCKED: session_id is missing, so session-bound gate validation cannot run. Retry in a session with a valid session ID."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

MAIN_ROOT=$(git -C "$GIT_TGT" worktree list 2>/dev/null | head -1 | awk '{print $1}')
MAIN_ROOT="${MAIN_ROOT:-$REPO_ROOT}"
# W5G-5/M-2 (forensic 2026-06-07): search `.v/artifacts` FIRST — W-perf6 moved
# artifacts there, and this hook's own W5F-10 deny message tells the model to
# consolidate them there. A production session got whipsawed: consolidate → this
# presence check said "PRE_FLIGHT missing" (root-only search) → model copied
# artifacts BACK to root to commit. Same .v-first order as the Stop hook.
ARTIFACT_SEARCH_DIRS=("$REPO_ROOT/.v/artifacts" "$REPO_ROOT")
if [[ "$MAIN_ROOT" != "$REPO_ROOT" ]]; then
  ARTIFACT_SEARCH_DIRS+=("$MAIN_ROOT/.v/artifacts" "$MAIN_ROOT")
fi

find_session_artifact() {
  # F1 (2026-07-05): delegates the actual picking algorithm to hooks/lib/gauntlet-witness.sh's
  # gauntlet_find_artifact() — single source of truth with check-review-artifact.sh and
  # v-gauntlet-attest.sh (newest-mtime-across-all-dirs-wins, W5G/W-perf6/CODEX-003, PLUS the
  # ORCHFIX-A1 canonical-name-preferred-over-suffixed-variant behavior this hook never had).
  # This hook still owns its own ARTIFACT_SEARCH_DIRS resolution above.
  local prefix="$1"
  # Lazy in-function source (F1 regression class, 2026-07-05): an awk/sed-extracted copy of
  # this function runs without the hook's top-level lib load; try the absolute default before
  # degrading to the legacy inline fallback. No-op in normal runs (lib already sourced).
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    source "${HOOKS_LIB_DIR:-$HOME/.claude/hooks/lib}/gauntlet-witness.sh" 2>/dev/null || true
  fi
  if ! type gauntlet_find_artifact >/dev/null 2>&1; then
    # Defense-in-depth fallback matching the pre-convergence behavior, in case
    # gauntlet-witness.sh is somehow unavailable (should be unreachable — sourced above).
    local _dir _newest="" _cands=()
    for _dir in "${ARTIFACT_SEARCH_DIRS[@]}"; do
      [ -z "$_dir" ] && continue
      while IFS= read -r _f; do
        [ -n "$_f" ] && _cands+=("$_f")
      done < <(find "$_dir" -maxdepth 1 -name "${prefix}_*${SESSION_ID}*.md" 2>/dev/null)
    done
    [ ${#_cands[@]} -eq 0 ] && return 1
    _newest=$(ls -t "${_cands[@]}" 2>/dev/null | head -1)
    [ -n "$_newest" ] || return 1
    echo "$_newest"
    return 0
  fi
  gauntlet_find_artifact "$prefix" "$SESSION_ID" "${ARTIFACT_SEARCH_DIRS[@]}"
}

PRE_FLIGHT=$(find_session_artifact "PRE_FLIGHT_REPORT" || true)
if [[ -z "$PRE_FLIGHT" ]]; then
  REASON="COMMIT BLOCKED: PRE_FLIGHT_REPORT for this session (${SESSION_ID}) is missing. Run /v-pre-flight first."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# AVF-004: Structural validation on PRE_FLIGHT
if type validate_artifact >/dev/null 2>&1; then
  if ! validate_artifact "$PRE_FLIGHT" "PRE_FLIGHT_REPORT" 2>/dev/null; then
    REASON="COMMIT BLOCKED: PRE_FLIGHT_REPORT for this session (${SESSION_ID}) failed structural validation (too small or missing required sections). Re-run /v-pre-flight."
    jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
  fi
fi

# HOOK-2 (CRITICAL fix): detect FAIL in BOTH the W12-3 status-first markdown table
# format `| FAIL | <Gate> | <Notes> |` AND legacy formats `❌`, `[FAIL]`,
# `status: fail`, `Overall Status: FAIL`.
#
# The W12-3 status-first table has cell `| FAIL |` with surrounding pipes. The
# regex below matches:
#   - `|` followed by optional whitespace, FAIL/FAILED, optional whitespace, `|`
#   - bracket form `[FAIL]`, `[FAILED]`
#   - emoji ❌ ✗
#   - any line containing `Status:` and `FAIL` (catches `Overall Status: FAIL`)
# ND-0716: `status:` lane bounded to fail/failed as a WHOLE token — the bare substring used to
# match `status: failed_non_blocking`, which gate-schema.md declares advisory-only ("No (warns
# only)"), false-blocking commits on a non-blocking gate result.
FAILED_GATES=$(grep -iE '\|[[:space:]]*(FAIL|FAILED)[[:space:]]*\||\[(FAIL|FAILED)\]|❌|✗|status:[[:space:]]*fail(ed)?([[:space:]]|$)' "$PRE_FLIGHT" 2>/dev/null \
               | grep -viE '^\s*#|\|[[:space:]]*PASS|\[PASS\]|✅' \
               | head -5 || true)

# Also look for the canonical W12-3 final line: `Overall Status: FAIL` (or PASS)
# and the bare `Status: fail` form for legacy reports.
OVERALL_FAIL=$(grep -iE '^(Overall[[:space:]]+)?Status:[[:space:]]*(FAIL|FAILED)([[:space:]]|$)' "$PRE_FLIGHT" 2>/dev/null | head -1 || true)

if [[ -n "$FAILED_GATES" ]] || [[ -n "$OVERALL_FAIL" ]]; then
  GATE_DETAIL=""
  if [[ -n "$FAILED_GATES" ]]; then
    GATE_DETAIL=$'\n\nFailed gate rows:\n'"$(echo "$FAILED_GATES" | sed 's/^/  /')"
  fi
  if [[ -n "$OVERALL_FAIL" ]]; then
    GATE_DETAIL+=$'\n\nOverall Status:\n  '"$OVERALL_FAIL"
  fi
  REASON="COMMIT BLOCKED: PRE_FLIGHT_REPORT has FAILED gates. Report: $(basename "$PRE_FLIGHT")${GATE_DETAIL}"$'\n\n'"Fix all failing gates, then re-run /v-pre-flight."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# === W-LIGHT2 (2026-08-03): light-tier lane at COMMIT time ===================================
# Observed trap this closes: a small change is blocked here for a missing PRE_FLIGHT, the session
# runs /v-pre-flight to satisfy it, that promotes it to a /v session, and the Stop hook then owes
# the FULL 6-artifact gauntlet — a ratchet where trying to commit a 14-line diff escalates it.
#
# On a light-tier diff the commit needs PRE_FLIGHT (the suite is the authoritative gate and it
# has already run by this point) but NOT AGENT_REVIEW — the review is still REQUIRED at Stop, so
# this relaxes the ORDER, not the requirement: commit the checkpoint, review before finishing.
#
# Verdict is diff-shape-derived by the same classifier the Stop hook uses, never model-asserted.
# Fails SAFE: classifier missing/unreadable ⇒ _lt_light stays 0 ⇒ AGENT_REVIEW required as before.
_lt_light=0
_LT_SCRIPT="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
if [[ -f "$_LT_SCRIPT" ]]; then
  # Capture to a variable FIRST, then match — do not pipe the classifier straight into `grep -q`.
  # This file runs under `set -o pipefail` (line 17): `grep -q` exits the moment it matches, the
  # classifier then dies of SIGPIPE (141), pipefail adopts that as the pipeline status, and the
  # `if` reads FALSE on exactly the runs where the pattern WAS found. Silent inversion — it fails
  # toward the full gauntlet, so nothing breaks loudly; the lane just never opens. Caught by
  # p1b-light-tier-test.sh's end-to-end commit-gate case, not by any syntax or unit check.
  _lt_out="$(CLAUDE_SESSION_ID="$SESSION_ID" REPO_ROOT="$REPO_ROOT" bash "$_LT_SCRIPT" 2>/dev/null || true)"
  if printf '%s\n' "$_lt_out" | grep -q '^LIGHT=1'; then
    _lt_light=1
  fi
fi

AGENT_REVIEW=$(find_session_artifact "AGENT_REVIEW" || true)
if [[ -z "$AGENT_REVIEW" && "$_lt_light" -eq 0 ]]; then
  REASON="COMMIT BLOCKED: AGENT_REVIEW for this session (${SESSION_ID}) is missing. Dispatch adversarial review (codex agent or superpowers fallback) before committing."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

# A PRESENT AGENT_REVIEW is validated on EVERY lane, light included — the light lane waives the
# requirement to HAVE one, never the checks on one that exists. Guarded on non-empty rather than
# short-circuiting with `exit 0`, because the broken-HEAD prevention check further down is NOT a
# review check and must still run for light-lane commits.
if [[ -n "$AGENT_REVIEW" ]]; then
  # AVF-004: Structural validation on AGENT_REVIEW
  if type validate_artifact >/dev/null 2>&1; then
    if ! validate_artifact "$AGENT_REVIEW" "AGENT_REVIEW" 2>/dev/null; then
      REASON="COMMIT BLOCKED: AGENT_REVIEW for this session (${SESSION_ID}) failed structural validation (too small or missing required sections). Re-run agent review."
      jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
      exit 0
    fi
  fi

  HOSTILE_REVIEW_REQUIRED=0
  if type review_requires_hostile_focus_from_paths >/dev/null 2>&1; then
    STAGED_PATHS=$(git -C "$GIT_TGT" diff --cached --name-only 2>/dev/null || true)
    if review_requires_hostile_focus_from_paths "$STAGED_PATHS"; then
      HOSTILE_REVIEW_REQUIRED=1
    fi
  fi

  if ! validate_review_semantics "$AGENT_REVIEW" 1 "$HOSTILE_REVIEW_REQUIRED" "$SESSION_ID"; then
    REASON="COMMIT BLOCKED: AGENT_REVIEW exists but is not semantically complete for this session (${SESSION_ID}). Re-run review and produce a completed artifact."
    jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
    exit 0
  fi
fi

# ── Broken-HEAD prevention (forensic 2026-06-19): a co-located UNIT test must not be committed
# without its source. A prior wave committed a test/spec to main while its source stranded on an
# unmerged worktree branch — red on a clean checkout (also the prior freshness P0). NARROW + FP-safe:
# only co-located unit tests (X.test|spec.{ts,tsx,js,jsx}) whose same-stem source X.{tsx,ts,jsx,js}
# (or X/index.{...}) is absent from BOTH the staged set AND the working tree. e2e/integration specs
# (no co-located source) are EXEMPT — they live under e2e/ paths. A test whose source EXISTS never
# fires (so behavioral-only gaps are out of scope; those are caught by the worktree gauntlet + the
# Phase-1 stranded-merge gate).
_p4_staged=$(git -C "$GIT_TGT" diff --cached --name-only 2>/dev/null || true)
_p4_added=$(git -C "$GIT_TGT" diff --cached --name-only --diff-filter=A 2>/dev/null || true)
_p4_orphans=""
while IFS= read -r _p4_f; do
  [ -n "$_p4_f" ] || continue
  case "$_p4_f" in
    # Exempt conventions whose source is NOT same-stem-same-dir (so the pairing heuristic can't apply
    # and would false-deny): e2e/integration specs (no co-located source), and __tests__/ layouts
    # (test in src/__tests__/Foo.test.tsx, source in src/Foo.tsx — a sibling dir).
    */e2e/*|e2e/*|*/__e2e__/*|*/__tests__/*|*/integration/*|*.integration.test.*|*.integration.spec.*) continue ;;
    *.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx) ;;
    *) continue ;;
  esac
  _p4_stem="${_p4_f%.*}"; _p4_stem="${_p4_stem%.test}"; _p4_stem="${_p4_stem%.spec}"
  _p4_found=0
  for _p4_cand in "${_p4_stem}.tsx" "${_p4_stem}.ts" "${_p4_stem}.jsx" "${_p4_stem}.js" \
                  "${_p4_stem}/index.tsx" "${_p4_stem}/index.ts" "${_p4_stem}/index.jsx" "${_p4_stem}/index.js"; do
    if printf '%s\n' "$_p4_staged" | grep -qxF "$_p4_cand" || [ -f "$GIT_TGT/$_p4_cand" ]; then _p4_found=1; break; fi
  done
  [ "$_p4_found" -eq 0 ] && _p4_orphans="${_p4_orphans}${_p4_orphans:+ }$_p4_f"
done <<P4EOF
$_p4_added
P4EOF
if [ -n "$_p4_orphans" ]; then
  REASON="COMMIT BLOCKED (broken-HEAD): co-located unit test(s) [${_p4_orphans}] are being ADDED but their same-stem source (.tsx/.ts/.jsx/.js or /index.*) is in NEITHER this commit NOR the working tree. A committed test whose source is absent is RED on a clean checkout / CI (forensic 2026-06-19: a prior wave committed a test to main while its source stranded on an unmerged worktree branch). Commit the source TOGETHER with its test (or land both in the same merge-back). If this is an e2e/integration spec with no co-located source, place it under an e2e/ path (those are exempt)."
  jq -n --arg reason "$REASON" '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$reason}}'
  exit 0
fi

exit 0
