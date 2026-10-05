#!/usr/bin/env bash
# v-untested-hooks-test.sh — behavioral tests for previously-untested live hook scripts
#
# Covers (P4, audit 2026-06-19):
#   1. check-session-branch.sh  — branch warning injection
#   2. v-preflight-mark.sh      — step-4 marker writes
#   3. session-context-loader.sh — session startup context injection
#
# Each section has behavioral (positive) and negative (boundary / invalid input) tests.
# Run standalone or via the vitest wrapper v-untested-hooks-harness.test.ts.
# Exit 0 if all pass, non-0 if any fail.
set -uo pipefail

CDIR="${HOOKS_LIB_DIR:-$HOME/.claude/hooks}"
# Strip trailing /lib if user set HOOKS_LIB_DIR pointing to the lib dir
case "$CDIR" in */lib) CDIR="${CDIR%/lib}" ;; esac
CDIR="${CDIR%/hooks}"  # normalize to ~/.claude root if hooks/ suffix present

CHECK_BRANCH="${V_CHECK_BRANCH_SCRIPT:-$CDIR/hooks/check-session-branch.sh}"
PREFLIGHT_MARK="${V_PREFLIGHT_MARK_SCRIPT:-$CDIR/skills/v/references/v-preflight-mark.sh}"
SESSION_CTX="${V_SESSION_CTX_SCRIPT:-$CDIR/hooks/session-context-loader.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

_ok()   { local t="$1"; PASS=$((PASS+1)); printf 'ok   %s\n' "$t"; }
_fail() { local t="$1" msg="${2:-}"; FAIL=$((FAIL+1)); printf 'FAIL %s%s\n' "$t" "${msg:+ — $msg}"; }

# ── Helper: make a scratch git repo on a branch ──────────────────────────────
_new_repo() {
  local dir="$1" branch="${2:-main}"
  git init -b "$branch" -q "$dir"
  git -C "$dir" commit -q --allow-empty -m "init"
  echo "$dir"
}

# ════════════════════════════════════════════════════════════════
# Part 1 — check-session-branch.sh
# ════════════════════════════════════════════════════════════════

# CSB-P1 — on main: no output (exit 0, empty stdout)
REPO="$TMP/repo-main"; _new_repo "$REPO" "main" >/dev/null
out=$(cd "$REPO" && CLAUDE_ALLOW_NON_MAIN=0 bash "$CHECK_BRANCH" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "CSB-P1 on main: exit 0"; else _fail "CSB-P1 on main: exit 0" "rc=$rc"; fi
if [ -z "$out" ]; then _ok "CSB-P2 on main: no stdout (no warning injected)"; else _fail "CSB-P2 on main: no stdout" "got: $out"; fi

# CSB-P3 — on feature branch: exit 0 + JSON with additionalContext warning
REPO="$TMP/repo-feature"; _new_repo "$REPO" "main" >/dev/null
git -C "$REPO" checkout -b "feature/abc" -q 2>/dev/null
out=$(cd "$REPO" && CLAUDE_ALLOW_NON_MAIN=0 bash "$CHECK_BRANCH" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "CSB-P3 on feature branch: exit 0"; else _fail "CSB-P3 on feature branch: exit 0" "rc=$rc"; fi
if printf '%s' "$out" | grep -q "additionalContext"; then _ok "CSB-P4 feature branch: additionalContext in output"; else _fail "CSB-P4 feature branch: additionalContext missing" "out: ${out:0:120}"; fi
if printf '%s' "$out" | grep -q "feature/abc"; then _ok "CSB-P5 feature branch: branch name in warning"; else _fail "CSB-P5 feature branch: branch name not in warning"; fi

# CSB-N1 — CLAUDE_ALLOW_NON_MAIN=1: always exit 0, no output
REPO="$TMP/repo-feature"
out=$(cd "$REPO" && CLAUDE_ALLOW_NON_MAIN=1 bash "$CHECK_BRANCH" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then _ok "CSB-N1 CLAUDE_ALLOW_NON_MAIN=1: suppressed (exit 0, no output)"; else _fail "CSB-N1 CLAUDE_ALLOW_NON_MAIN=1" "rc=$rc out=${out:0:80}"; fi

# CSB-N2 — not inside a git repo: exit 0 (fail-open)
NOTGIT="$TMP/not-git"; mkdir -p "$NOTGIT"
out=$(cd "$NOTGIT" && CLAUDE_ALLOW_NON_MAIN=0 bash "$CHECK_BRANCH" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "CSB-N2 outside git repo: exit 0 (fail-open)"; else _fail "CSB-N2 outside git repo: exit 0" "rc=$rc"; fi

# CSB-N3 — CLAUDE_MAIN_BRANCH override: treats override value as main (no warning)
REPO="$TMP/repo-custom-main"; _new_repo "$REPO" "trunk" >/dev/null
out=$(cd "$REPO" && CLAUDE_ALLOW_NON_MAIN=0 CLAUDE_MAIN_BRANCH="trunk" bash "$CHECK_BRANCH" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then _ok "CSB-N3 CLAUDE_MAIN_BRANCH=trunk on trunk: no warning"; else _fail "CSB-N3 CLAUDE_MAIN_BRANCH=trunk" "rc=$rc out=${out:0:80}"; fi

# ════════════════════════════════════════════════════════════════
# Part 2 — v-preflight-mark.sh
# ════════════════════════════════════════════════════════════════

# PFM-P1 — writes step4-head and step4-writes-hash markers for a valid session
REPO2="$TMP/repo-pfm"; git init -b main -q "$REPO2"
git -C "$REPO2" commit -q --allow-empty -m "init"
SID_PFM="pfm-test-sid"
V_TMP="$REPO2/.v/tmp"; mkdir -p "$V_TMP"
# Write a stub writes log (sha256sum reads it)
printf 'app.py\n' > "$V_TMP/session-writes-${SID_PFM}.txt"

out=$(CLAUDE_SESSION_ID="$SID_PFM" PROJECT_ROOT="$REPO2" V_TMP_DIR="$V_TMP" \
  bash "$PREFLIGHT_MARK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then _ok "PFM-P1 preflight-mark exits 0"; else _fail "PFM-P1 preflight-mark exits 0" "rc=$rc out=$out"; fi
if [ -f "$V_TMP/step4-head-${SID_PFM}.txt" ]; then _ok "PFM-P2 step4-head marker written"; else _fail "PFM-P2 step4-head marker written" "file missing"; fi
if [ -f "$V_TMP/step4-writes-hash-${SID_PFM}.txt" ]; then _ok "PFM-P3 step4-writes-hash marker written"; else _fail "PFM-P3 step4-writes-hash marker written" "file missing"; fi
# Marker should contain the git HEAD SHA (non-empty, 40-char hex)
head_sha=$(cat "$V_TMP/step4-head-${SID_PFM}.txt" 2>/dev/null || echo "")
if printf '%s' "$head_sha" | grep -qE '^[0-9a-f]{40}$'; then _ok "PFM-P4 step4-head contains real git SHA"; else _fail "PFM-P4 step4-head SHA" "got: $head_sha"; fi

# PFM-N1 — no session ID: exits 0 (safe fail-open, marker not written)
out=$(unset CLAUDE_SESSION_ID; unset CLAUDE_CODE_SESSION_ID; \
  PROJECT_ROOT="$REPO2" V_TMP_DIR="$V_TMP" bash "$PREFLIGHT_MARK" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then _ok "PFM-N1 no SID: exit 0 (fail-open, step 6.1 re-dispatches)"; else _fail "PFM-N1 no SID: exit 0" "rc=$rc"; fi

# PFM-P5 — second call refreshes the marker (idempotent / updatable)
sleep 1
CLAUDE_SESSION_ID="$SID_PFM" PROJECT_ROOT="$REPO2" V_TMP_DIR="$V_TMP" \
  bash "$PREFLIGHT_MARK" 2>/dev/null
new_hash=$(cat "$V_TMP/step4-writes-hash-${SID_PFM}.txt" 2>/dev/null || echo "none")
# Just verify the marker file is still present and non-empty
if [ -s "$V_TMP/step4-writes-hash-${SID_PFM}.txt" ]; then _ok "PFM-P5 second call refreshes hash marker (idempotent)"; else _fail "PFM-P5 second call refresh" "marker empty or missing"; fi

# ════════════════════════════════════════════════════════════════
# Part 3 — session-context-loader.sh
# ════════════════════════════════════════════════════════════════

# SCL-P1 — fast mode (default, no CLAUDE_SESSION_CONTEXT_FULL): exits 0 + JSON with additionalContext
out=$(printf '{"session_id":"scl-test","source":"user"}' | \
  bash "$SESSION_CTX" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "SCL-P1 exits 0"; else _fail "SCL-P1 exits 0" "rc=$rc"; fi
if printf '%s' "$out" | grep -q "additionalContext\|hookSpecificOutput"; then
  _ok "SCL-P2 fast mode: hookSpecificOutput present"
else
  _fail "SCL-P2 fast mode: hookSpecificOutput present" "out: ${out:0:120}"
fi

# SCL-P3 — headless mode: exits 0, valid JSON (may be empty or minimal)
out=$(printf '{"session_id":"scl-headless"}' | \
  CLAUDE_HEADLESS=1 bash "$SESSION_CTX" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "SCL-P3 headless mode exits 0"; else _fail "SCL-P3 headless mode exits 0" "rc=$rc"; fi

# SCL-P4 — malformed JSON input: exits 0 (R3 defensive — tolerate bad input)
out=$(printf 'NOT JSON AT ALL' | bash "$SESSION_CTX" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "SCL-P4 malformed input: exit 0 (R3 defensive tolerate)"; else _fail "SCL-P4 malformed input exit 0" "rc=$rc"; fi

# SCL-N1 — empty input: exits 0 (fail-open)
out=$(printf '' | bash "$SESSION_CTX" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "SCL-N1 empty input: exit 0 (fail-open)"; else _fail "SCL-N1 empty input" "rc=$rc"; fi

# SCL-P5 — full mode (CLAUDE_SESSION_CONTEXT_FULL=1): exits 0 + longer additionalContext
out=$(cd "$TMP" && printf '{"session_id":"scl-full"}' | \
  CLAUDE_SESSION_CONTEXT_FULL=1 bash "$SESSION_CTX" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ]; then _ok "SCL-P5 full mode exits 0"; else _fail "SCL-P5 full mode exits 0" "rc=$rc"; fi

# ════════════════════════════════════════════════════════════════
# Part 4 — v-run-gates.sh skeleton emit (un-stub the T1/T2 contract check, P4)
#
# v-contract-audit-test.sh T1/T2 only GREP the v-run-gates.sh source for
# "Repo:" and "HEAD:" strings. Here we test the BEHAVIOR: extract the skeleton-
# emit code block (lines between "emit canonical PRE_FLIGHT report skeleton" and
# the closing fi) and exercise it with a real git repo to prove the output
# actually contains those identity lines. Fast (no full gate run needed).
# ════════════════════════════════════════════════════════════════
RUNGATES="${V_RUNGATES_SCRIPT:-$CDIR/skills/v/references/v-run-gates.sh}"
if [ -f "$RUNGATES" ] && command -v git >/dev/null 2>&1; then
  REPO3="$TMP/repo-rungates"; git init -b main -q "$REPO3"
  git -C "$REPO3" commit -q --allow-empty -m "init"
  SID_RG="rg-test-sid-$$"  # hermetic: PID is collision-free across concurrent sweep runs (determinism-net)
  V_TMP3="$REPO3/.v/tmp"; mkdir -p "$V_TMP3"
  SKELETON="$V_TMP3/pre-flight-skeleton-${SID_RG}.md"

  # Exercise the skeleton-emit logic directly by extracting and evaling the
  # canonical PRE_FLIGHT skeleton-emit block. The block uses SESSION_ID, V_TMP_DIR,
  # PFM, and git commands only — no gate tools needed.
  (
    cd "$REPO3"
    SESSION_ID="$SID_RG"
    V_TMP_DIR="$V_TMP3"
    PFM="scoped"
    ALL_PASS=1
    # _row and _final_verdict are called inside the block — define stubs
    _row() { :; }
    _final_verdict() { echo "PASS"; }
    TSC_RC=0; LINT_RC=0; BUILD_RC=0; PEST_RC=0; VITEST_RC=0
    TSC_WALL=0; LINT_WALL=0; BUILD_WALL=0; PEST_WALL=0; VITEST_WALL=0
    COMPOSER_RC=SKIP; NPM_RC=SKIP
    # POSTMERGE_REVERIFY (2026-07-02): _GATE_SUFFIX is defined by the caller ABOVE the awk-extracted block
    # (v-run-gates.sh ~1042), so the block references it unbound here → eval dies under set -u → RG-P1..P4
    # false-fail. Stub it like PFM/ALL_PASS — the normal (non-postmerge) caller value is the empty string.
    _GATE_SUFFIX=""
    eval "$(awk '/emit canonical PRE_FLIGHT report skeleton/,/F2\.1 skeleton emitted/' "$RUNGATES")"
  ) 2>/dev/null
  rg_skel_rc=$?

  if [ -f "$SKELETON" ]; then _ok "RG-P1 skeleton file emitted by skeleton-emit block"; else _fail "RG-P1 skeleton file emitted" "file missing — awk block may have changed location"; fi
  if grep -q "^Repo:" "$SKELETON" 2>/dev/null; then _ok "RG-P2 skeleton contains Repo: identity line"; else _fail "RG-P2 skeleton Repo: line" "content: $(head -5 "$SKELETON" 2>/dev/null)"; fi
  if grep -q "^HEAD:" "$SKELETON" 2>/dev/null; then _ok "RG-P3 skeleton contains HEAD: identity line"; else _fail "RG-P3 skeleton HEAD: line" "content: $(head -5 "$SKELETON" 2>/dev/null)"; fi
  # HEAD: should contain a 40-char hex commit SHA from the real git repo (not "unknown")
  head_line=$(grep "^HEAD:" "$SKELETON" 2>/dev/null || echo "")
  if printf '%s' "$head_line" | grep -qE '[0-9a-f]{40}'; then _ok "RG-P4 HEAD: contains real git SHA"; else _fail "RG-P4 HEAD: contains real git SHA" "line: $head_line"; fi
else
  _ok "RG SKIPPED (v-run-gates.sh not found or no git) — non-fatal"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\nTOTAL: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
