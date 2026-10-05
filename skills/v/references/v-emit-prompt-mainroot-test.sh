#!/usr/bin/env bash
# v-emit-prompt-mainroot-test.sh — MAINROOT EXCLUSION (forensic 2026-07-09).
# CLASS: bootstrap-marker-resolves-main-root — an inline session start legitimately writes
# head-baseline-<SID> into the MAIN checkout's .v/tmp; when $PROJECT_ROOT is env-skewed away from
# the main root, FIX-4's `!= "$PROJ"` guard no longer excludes the main checkout and the marker
# loop resolves WORKTREE_PATH to the MAIN repo root — producing a no-isolation verify-done that
# merge-back rejects (observed live: a wasted haiku dispatch + a re-run).
# RED oracle: v-emit-prompt.sh.pre-mainroot-bak resolves case 1 to the main root.
set -u
SCRIPT_DEFAULT="$HOME/.claude/skills/v/references/v-emit-prompt.sh"
SCRIPT="${V_EMIT_OVERRIDE:-$SCRIPT_DEFAULT}"
BAK="$SCRIPT_DEFAULT.pre-mainroot-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
[ -f "$SCRIPT" ] || { echo "NO v-emit-prompt.sh missing"; exit 1; }

TMP="$(mktemp -d)"
# Canonicalize (macOS mktemp returns /var/… which git resolves to /private/var/… — a TEXTUAL
# PROJ≠toplevel divergence that is itself an instance of the class under test; the fixture must
# isolate the marker-loop case, so pin every path to git's physical form).
TMP="$(cd "$TMP" && pwd -P)"
trap 'git -C "$TMP/main" worktree remove --force "$TMP/wt" 2>/dev/null; rm -rf "$TMP"' EXIT
MAIN="$TMP/main"; WTD="$TMP/wt"
SID="eeeeeeee-71dd-4555-8555-eeeeeeeeeeee"
mkdir -p "$MAIN"
( cd "$MAIN" && git init -q && git config user.email t@t && git config user.name t \
  && echo x > f && git add f && git commit -qm init ) >/dev/null 2>&1
# task-slug branch with NO SID in path/branch → the SID-scan misses, forcing the FIX-4 marker path.
git -C "$MAIN" worktree add -q "$WTD" -b build/task-slug-no-sid 2>/dev/null
mkdir -p "$MAIN/.v/tmp" "$WTD/.v/tmp"

emit(){ # $1=script $2=PROJECT_ROOT — returns stderr; prompt discarded
  ( cd "$2" && PROJECT_ROOT="$2" CLAUDE_SESSION_ID="$SID" CLAUDE_CODE_SESSION_ID="$SID" \
      WORKTREE_PATH="" bash "$1" v-verify-done 2>&1 >/dev/null ) || true
}

echo "== v-emit-prompt :: main-checkout exclusion in WORKTREE_PATH resolution =="

# Case 1 — env-skew repro: marker lives ONLY in the MAIN root's .v/tmp, PROJECT_ROOT points at
# the worktree. The main checkout must NOT be adopted as WORKTREE_PATH.
printf 'deadbeef\n' > "$MAIN/.v/tmp/head-baseline-${SID}.txt"
ERR="$(emit "$SCRIPT" "$WTD")"
if printf '%s' "$ERR" | grep -qF "bootstrap marker: $MAIN"; then
  no "C1: marker loop still resolves WORKTREE_PATH to the MAIN checkout"
else
  ok "C1: main checkout excluded from marker resolution (env-skew case)"
fi

# Case 2 — the legitimate case must still work: marker in the REAL worktree, PROJECT_ROOT=main.
rm -f "$MAIN/.v/tmp/head-baseline-${SID}.txt"
printf 'deadbeef\n' > "$WTD/.v/tmp/head-baseline-${SID}.txt"
ERR="$(emit "$SCRIPT" "$MAIN")"
if printf '%s' "$ERR" | grep -qF "bootstrap marker: $WTD"; then
  ok "C2: marker in the real worktree still resolves correctly"
else
  no "C2: legitimate worktree marker resolution broken (stderr: $(printf '%s' "$ERR" | grep -i marker | head -1))"
fi

# RED oracle — pre-fix script adopts the main root in case 1.
if [ -f "$BAK" ]; then
  printf 'deadbeef\n' > "$MAIN/.v/tmp/head-baseline-${SID}.txt"
  rm -f "$WTD/.v/tmp/head-baseline-${SID}.txt"
  ERR="$(emit "$BAK" "$WTD")"
  if printf '%s' "$ERR" | grep -qF "bootstrap marker: $MAIN"; then
    ok "RED: pre-fix script resolves WORKTREE_PATH to the MAIN checkout (bug reproduced)"
  else
    no "RED: pre-fix script did not adopt the main root — bite not isolating the class"
  fi
else
  echo "  --  RED oracle skipped ($BAK missing)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
