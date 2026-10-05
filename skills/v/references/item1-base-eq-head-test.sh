#!/usr/bin/env bash
# item1-base-eq-head-test.sh — ITEM1-BASE-EQ-HEAD auto-escalate/recover (2026-07-05).
#
# Forensic class (post-merge-back shape): when BASE_SHA_FOR_DIFF resolves
# to the SAME sha as HEAD (post-merge-back shape — fork base now equals HEAD), the scoped diff
# is empty by construction. Before this fix, v-run-gates.sh only marked the run
# PREFLIGHT_BLIND/INCONCLUSIVE and required a manual re-dispatch. Now it (a) recovers the durable
# session-start head baseline as the real diff base when usable, else (b) auto-escalates PFM to
# full so the degenerate case self-heals instead of requiring an operator retry loop.
#
# Executes the block EXTRACTED VERBATIM from the production script (same idiom as
# p1c-reverify-scope-test.sh). RED ORACLE: point SCRIPT at a pre-fix backup (no
# ITEM1-BASE-EQ-HEAD marker) → awk range empty → test 1 fails.
set -u
SCRIPT="${V_RUN_GATES_OVERRIDE:-$HOME/.claude/skills/v/references/v-run-gates.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$SCRIPT" ] || { echo "NO v-run-gates.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git required"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

BLOCK="$(awk '/=== ITEM1-BASE-EQ-HEAD/,/=== end ITEM1-BASE-EQ-HEAD/' "$SCRIPT")"

echo "== ITEM1 :: base==HEAD collapse -> durable-baseline recovery or full-escalation =="
if [ -z "$BLOCK" ]; then
  no "ITEM1-BASE-EQ-HEAD block present in v-run-gates.sh" "awk range empty (pre-fix = RED)"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "ITEM1-BASE-EQ-HEAD block present in v-run-gates.sh"

# Build a tiny real repo so `git rev-parse HEAD` / `git cat-file -e` resolve for real.
R="$WORK/repo"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && git symbolic-ref HEAD refs/heads/main \
    && echo a > f && git add -A && git commit -qm base \
    && OLD_SHA=$(git rev-parse HEAD) \
    && echo b > f && git add -A && git commit -qm head \
    && echo "$OLD_SHA" > "$WORK/old_sha.txt" ) >/dev/null 2>&1
OLD_SHA="$(cat "$WORK/old_sha.txt" 2>/dev/null || echo '')"
[ -n "$OLD_SHA" ] || { echo "NO could not build fixture repo"; echo "TOTAL: $PASS passed, $((FAIL+1)) failed"; exit 1; }

run_item1() { # $1=baseline-state(none|stale-equals-head|usable) $2=starting PFM → echoes "PFM BASE_SHA_FOR_DIFF"
  local d="$WORK/r$RANDOM"; mkdir -p "$d"
  local head_sha; head_sha="$(cd "$R" && git rev-parse HEAD)"
  case "$1" in
    usable)             echo "$OLD_SHA" > "$d/main-head-at-start-item1-sid.txt" ;;
    stale-equals-head)  echo "$head_sha" > "$d/main-head-at-start-item1-sid.txt" ;;
    none)               : ;;
  esac
  (
    cd "$R" || exit 1
    set +eu
    V_TMP_DIR="$d"; SESSION_ID="item1-sid"; PFM="$2"
    BASE_SHA_FOR_DIFF="$head_sha"
    eval "$BLOCK" 2>/dev/null
    printf '%s %s' "$PFM" "$BASE_SHA_FOR_DIFF"
  )
}

OUT="$(run_item1 usable full)"
[ "${OUT%% *}" = "full" ] && [ "${OUT#* }" = "$OLD_SHA" ] \
  && ok "usable durable head-baseline recovered as the real diff base (PFM stays as caller set it)" \
  || no "durable-baseline recovery did not fire" "$OUT"

OUT="$(run_item1 stale-equals-head scoped)"
[ "${OUT%% *}" = "full" ] \
  && ok "no usable baseline (baseline file also == HEAD) -> auto-escalate to full" \
  || no "did not auto-escalate on a fully degenerate base==HEAD==baseline" "$OUT"

OUT="$(run_item1 none scoped)"
[ "${OUT%% *}" = "full" ] \
  && ok "no baseline file at all -> auto-escalate to full" \
  || no "did not auto-escalate when no durable baseline file exists" "$OUT"

OUT="$(run_item1 none full)"
[ "${OUT%% *}" = "full" ] \
  && ok "already-full PFM with no baseline stays full (no-op, not a crash)" \
  || no "already-full case regressed" "$OUT"

# Non-degenerate case: BASE_SHA_FOR_DIFF != HEAD -> block must not fire at all.
OUT="$(
  d="$WORK/r$RANDOM"; mkdir -p "$d"
  cd "$R" || exit 1
  set +eu
  V_TMP_DIR="$d"; SESSION_ID="item1-sid"; PFM="scoped"
  BASE_SHA_FOR_DIFF="$OLD_SHA"
  eval "$BLOCK" 2>/dev/null
  printf '%s %s' "$PFM" "$BASE_SHA_FOR_DIFF"
)"
[ "${OUT%% *}" = "scoped" ] && [ "${OUT#* }" = "$OLD_SHA" ] \
  && ok "non-degenerate base (base != HEAD) left untouched" \
  || no "non-degenerate base was wrongly mutated" "$OUT"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
