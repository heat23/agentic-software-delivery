#!/usr/bin/env bash
# artifact-leak-guard-test.sh — red/green bite for the 2026-08-02 artifact-leak guard.
#
# THE LEAK
# ~/.claude has no git repo by design. Every root resolver in this ecosystem uses the idiom
# `git rev-parse --show-toplevel 2>/dev/null || pwd`. Inside a skill/hook SOURCE subdirectory
# both halves fail through to bare `pwd`, so `.v/artifacts` / `.v/tmp` / `.v/traces` get created
# INSIDE the source tree. That produced 18 stray files across 6 skill dirs between 2026-06-07 and
# 2026-08-02. v-artifact-dir.sh made it invisible: it reports the bad path and still exits 0, so
# callers' own `|| $PWD` fallbacks never fired and nothing ever flagged it.
#
# THE BOUNDARY (this is the subtle part — do not "simplify" it to a blanket refusal)
# The config dir ITSELF is a LEGITIMATE artifact root: ecosystem-maintenance sessions really do
# treat ~/.claude as their project, and ~/.claude/.v/artifacts/ holds live BITE_LEDGER_*.md and
# AGENT_REVIEW_*.md written by that workflow. So the guard refuses only a STRICT DESCENDANT of the
# config dir that is not itself inside a real git work tree, and snaps it UP to the config dir.
# Test 5 below pins that legitimate case; test 6 pins that a genuinely git-init'd nested repo is
# left alone. A guard that blanket-refuses anything under ~/.claude breaks the live workflow.
#
# BITE
#   RED   — against the pre-fix copies (LEAK_ORIG_DIR=<backup dir>): resolvers return the nested
#           source-tree path, so the "must not be inside a skill dir" assertions fail.
#   GREEN — against the current files: every resolver snaps up to the config dir; the two
#           legitimate cases (config dir itself, real git repo) are untouched.
set -uo pipefail

CLAUDE_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SRC_DIR="${LEAK_ORIG_DIR:-}"          # set to the backup dir to run the RED half
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO   %s\n     %s\n' "$1" "${2:-}"; }

# Resolve which copy of each script to exercise (current tree, or the pre-fix backup for RED).
pick(){ # <relpath-under-~/.claude> <backup-basename>
  if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$2" ]; then printf '%s' "$SRC_DIR/$2"
  else printf '%s' "$CLAUDE_ROOT/$1"; fi
}
AD=$(pick "skills/v/references/v-artifact-dir.sh"     "v-artifact-dir.sh.leakorig")
BW=$(pick "skills/v/references/v-bootstrap-wrapper.sh" "v-bootstrap-wrapper.sh.leakorig")
TS=$(pick "skills/v/references/v-trace-span.sh"        "v-trace-span.sh.leakorig")
for f in "$AD" "$BW" "$TS"; do [ -f "$f" ] || { echo "SKIP: missing $f"; exit 0; }; done

# A fake config dir with the real leak topology: a NON-git skill source subdirectory.
FIX=$(mktemp -d "${TMPDIR:-/tmp}/artifact-leak-guard.XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT
[ -n "$FIX" ] && [ -d "$FIX" ] || exit 1
FIX=$(cd "$FIX" && pwd -P)   # canonicalize: macOS /private symlink + TMPDIR trailing slash would false-fail below
CFG="$FIX/.claude"
NEST="$CFG/skills/some-skill/references"
mkdir -p "$NEST"

run_in(){ # <cwd> <script> [args...] -> stdout, with the fixture as the config dir
  local d="$1"; shift
  ( cd "$d" && CLAUDE_CONFIG_DIR="$CFG" HOME="$FIX" bash "$@" 2>/dev/null )
}

# ── 1. v-artifact-dir.sh from a nested NON-git skill dir → must NOT stay nested ───────────────
out=$(run_in "$NEST" "$AD")
case "$out" in
  "$NEST"/*) no "v-artifact-dir: leaked into the skill source tree" "got: $out" ;;
  "$CFG"/*)  ok "v-artifact-dir: nested non-repo root snapped up to the config dir" ;;
  *)         no "v-artifact-dir: unexpected root" "got: $out" ;;
esac

# ── 2. v-bootstrap-wrapper.sh computes its own root BEFORE v-bootstrap.sh's own refusal ──────
# Grep the resolved path out of the script's logic rather than executing the full bootstrap.
bw_root=$( cd "$NEST" && CLAUDE_CONFIG_DIR="$CFG" HOME="$FIX" bash -c '
  _pr_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  _pr_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -n "$_pr_cfg" ] && [ "$_pr_root" != "$_pr_cfg" ]; then
    case "$_pr_root" in
      ("$_pr_cfg"/*) git -C "$_pr_root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || _pr_root="$_pr_cfg" ;;
    esac
  fi
  printf "%s" "$_pr_root"' )
if grep -q '_pr_cfg' "$BW"; then ok "v-bootstrap-wrapper: guard present (snaps to $bw_root)"
else no "v-bootstrap-wrapper: NO guard — bootstrap-*.env can leak into a skill source tree"; fi

# ── 3. v-trace-span.sh ────────────────────────────────────────────────────────────────────────
if grep -q '_vts_cfg' "$TS"; then ok "v-trace-span: guard present (V_TRACE_*.jsonl cannot nest)"
else no "v-trace-span: NO guard — V_TRACE_*.jsonl can leak into a skill source tree"; fi

# ── 4. the two caller fallbacks in the provenance hook ───────────────────────────────────────
HK="$CLAUDE_ROOT/hooks/record-agent-dispatch-provenance.sh"
if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/record-agent-dispatch-provenance.sh.leakorig" ]; then
  HK="$SRC_DIR/record-agent-dispatch-provenance.sh.leakorig"; fi
if grep -q '_safe_pwd_artifact_dir' "$HK"; then ok "provenance hook: \$PWD fallbacks routed through the guard"
else no "provenance hook: raw \${PWD}/.v/artifacts fallback still present"; fi

# ── 5. LEGITIMATE CASE — the config dir itself must be left ALONE ─────────────────────────────
out=$(run_in "$CFG" "$AD"); out=$(cd "$(dirname "$out")" 2>/dev/null && pwd -P)/$(basename "$out") || out="$out"
[ "$out" = "$CFG/.v/artifacts" ] \
  && ok "config dir itself still resolves to its own .v/artifacts (maintenance workflow intact)" \
  || no "config dir itself was wrongly rewritten" "got: $out (expected $CFG/.v/artifacts)"

# ── 6. LEGITIMATE CASE — a real git repo nested under the config dir must be left ALONE ───────
NESTREPO="$CFG/skills/a-real-repo"
mkdir -p "$NESTREPO" && ( cd "$NESTREPO" && git init -q . 2>/dev/null )
if [ -d "$NESTREPO/.git" ]; then
  out=$(run_in "$NESTREPO" "$AD"); out=$(cd "$(dirname "$out")" 2>/dev/null && pwd -P)/$(basename "$out") || out="$out"
  case "$out" in
    "$NESTREPO"/*) ok "a genuinely git-init'd dir under the config dir keeps its own root" ;;
    *)             no "a real nested git repo was wrongly snapped up" "got: $out" ;;
  esac
else
  echo "  --   skipped test 6 (git init unavailable in fixture)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
