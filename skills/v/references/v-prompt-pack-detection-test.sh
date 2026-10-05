#!/usr/bin/env bash
# v-prompt-pack-detection-test.sh — regression test for the F2 hardening (2026-07-05) added to
# v-prompt-pack-detection.md:
#
#   1. "Missing-final-verify guard" — a wave-form (`w<N>-*.txt`) pack tree with no `99-*` final
#      verify pack must be flagged WARNING, not silently presented as ready to run.
#   2. "Execution-time claim verification" — a session file's `## Verified context` / `requires:`
#      claim must be re-checked with a REAL `git show main:<path> | grep <symbol>` right before
#      execution, never trusted on faith. A stale/false claim must come back BLOCKED.
#   3. Branch-logic step 3/5 — a `99-*` final verify pack must never be considered "already run"
#      just because earlier waves show IMPLEMENTATION_REPORT/git-log evidence, and must never be
#      treated as optional.
#
# WHY (F2, forensic 2026-07-05): a real transcript showed a generated pack asserting
# "Verified context: app/Services/ExampleReader.php ... landed in wave-0 example-gateway" — text
# the generator (and, worse, the executing session) had no mechanism to actually check. The
# generator's own self-validate (v-runnable-pack-convention.md § Self-validate) only checks that a
# requires:/BLOCKED line is STRUCTURALLY present — it never re-checks the claim's TRUTH, and only
# runs once, at generation time (packs can sit unrun for days). This test proves the NEW
# execution-time gate actually catches a false claim with a live grep, and that the missing-99
# guard actually fires — by extracting the literal bash blocks out of the .md and running them
# for real, not just grepping for prose.
#
# SCOPE NOTE (honesty, not a test assertion): the actual pack GENERATOR
# (skills/v-prompt-pack-generate/SKILL.md), the runnable-pack convention doc
# (skills/references/v-runnable-pack-convention.md), and the runner (~/.local/bin/run-v-packs) are
# OUTSIDE this task's permitted edit scope (hooks/, hooks/lib/, skills/v/references/ only). This
# test therefore exercises the strongest in-scope substitute: the consumption-time gate in
# v-prompt-pack-detection.md, which runs every time /v picks up a pack — the only time that matters
# for staleness, since a pack can be generated fresh-and-true then executed stale days later.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$DIR/v-prompt-pack-detection.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

[ -f "$DOC" ] || { echo "FAIL: $DOC missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

echo "== v-prompt-pack-detection.md F2 hardening =="

# ── extract a fenced ```bash block by exact heading-line prefix (avoids regex-metachar issues
#    with headings like "(F2, 2026-07-05)") ──
extract_block() {
  local file="$1" heading="$2"
  awk -v heading="$heading" '
    index($0, heading) == 1 { found=1; next }
    found && $0 == "```bash" { inblock=1; next }
    found && inblock && $0 == "```" { exit }
    found && inblock { print }
  ' "$file"
}

# ── Part 1: static presence (proves the prose fix landed, not just the mechanism) ──
grep -q '^## Missing-final-verify guard' "$DOC" && ok "doc has Missing-final-verify guard section" || no "Missing-final-verify guard section absent"
grep -q '^## Execution-time claim verification' "$DOC" && ok "doc has Execution-time claim verification section" || no "Execution-time claim verification section absent"
grep -q 'git show "main:\$REQ_PATH"' "$DOC" && ok "doc's verification snippet uses a real git show main:<path>" || no "no real git show main:<path> verification snippet found"
grep -qi 'is NOT optional' "$DOC" && ok "doc states the 99-* verify pack is NOT optional" || no "missing NOT-optional 99-verify language"
grep -qi 'never marked "unexecuted-evidence-found"' "$DOC" && ok "doc guards against inferring 99-verify ran from earlier-wave evidence" || no "missing guard against false 99-verify completion inference"

# ── Part 2: Missing-final-verify guard — behavioral, extracted block run for real ──
GUARD_BLOCK="$(extract_block "$DOC" '## Missing-final-verify guard')"
[ -n "$GUARD_BLOCK" ] || no "could not extract Missing-final-verify guard bash block"

run_guard() { # $1 = synthetic pack dir -> prints WARNING or nothing
  local D="$1"
  eval "$GUARD_BLOCK" 2>/dev/null
}

TMP="$(mktemp -d)"
# Case A (RED-class proof): wave-prefixed pack, NO 99-* file -> must WARN.
D1="$TMP/wave-no-verify"; mkdir -p "$D1"; : > "$D1/00-README.md"; : > "$D1/w1-thing.txt"
out1="$(run_guard "$D1")"
printf '%s' "$out1" | grep -q 'WARNING' && ok "wave dir with no 99-* correctly WARNS (guard fires)" || no "wave dir with no 99-* did NOT warn (guard silent — regression)"

# Case B: wave-prefixed pack WITH 99-* file -> must NOT warn.
D2="$TMP/wave-with-verify"; mkdir -p "$D2"; : > "$D2/00-README.md"; : > "$D2/w1-thing.txt"; : > "$D2/99-verify.txt"
out2="$(run_guard "$D2")"
[ -z "$(printf '%s' "$out2" | grep 'WARNING')" ] && ok "wave dir WITH 99-* stays silent (no false positive)" || no "wave dir with 99-* wrongly warned"

# Case C: wave-0-only pack (no w<N>- prefix at all) -> must NOT warn (no wave assignment to be missing verify for).
D3="$TMP/wave0-only"; mkdir -p "$D3"; : > "$D3/00-README.md"; : > "$D3/unprefixed-thing.txt"
out3="$(run_guard "$D3")"
[ -z "$(printf '%s' "$out3" | grep 'WARNING')" ] && ok "wave-0-only dir (no w<N>- files) stays silent" || no "wave-0-only dir wrongly warned"

# ── RED-BEFORE proof: the ORIGINAL Detection bash block (pre-fix) has no concept of a missing
#    99-* pack at all — it only ever computes TOTAL_TXT and lists the dir. Prove the OLD logic
#    alone (extracted from the still-present "## Detection bash" section) would never warn on D1,
#    i.e. the bug this guard fixes is real and was previously silent. ──
OLD_BLOCK="$(extract_block "$DOC" '## Detection bash')"
run_old() { local D="$1" PROJECT_ROOT; PROJECT_ROOT="$(dirname "$D")"; eval "$OLD_BLOCK" 2>/dev/null; printf '%s' "$PROMPT_PACKS"; }
old_out="$(run_old "$D1")"
if ! printf '%s' "$old_out" | grep -qi 'WARNING\|missing'; then
  ok "RED-BEFORE confirmed: original Detection bash alone never flags a missing 99-* pack (the bug this guard fixes)"
else
  no "RED-BEFORE not reproduced — original Detection bash unexpectedly already flags missing 99-*"
fi
rm -rf "$TMP"

# ── Part 3: Execution-time claim verification — behavioral, extracted block run for real ──
CLAIM_BLOCK="$(extract_block "$DOC" '## Execution-time claim verification')"
[ -n "$CLAIM_BLOCK" ] || no "could not extract Execution-time claim verification bash block"

_cfg(){ git -C "$1" config user.email t@t; git -C "$1" config user.name t; git -C "$1" config commit.gpgsign false; }
repo="$(mktemp -d)"
git init -q "$repo" >/dev/null 2>&1; _cfg "$repo"
mkdir -p "$repo/app/Services"
cat > "$repo/app/Services/ExampleReader.php" <<'EOF'
<?php
class ExampleReader {
    public function readItems() { return true; }
}
EOF
git -C "$repo" add -A >/dev/null 2>&1
git -C "$repo" commit -qm base >/dev/null 2>&1
git -C "$repo" branch -M main >/dev/null 2>&1

run_claim() { # $1=PROJECT_ROOT $2=REQ_PATH $3=REQ_SYMBOL -> stdout of the block
  local PROJECT_ROOT="$1" REQ_PATH="$2" REQ_SYMBOL="$3"
  eval "$CLAIM_BLOCK" 2>/dev/null
}

# TRUE claim: symbol really is on main -> VERIFIED.
true_out="$(run_claim "$repo" "app/Services/ExampleReader.php" "readItems")"
printf '%s' "$true_out" | grep -q '^VERIFIED' && ok "true Verified-context claim against real main -> VERIFIED" || no "true claim wrongly not VERIFIED (out: $true_out)"

# FALSE claim (the R3 P0-1 phantom-context class): symbol claimed but never landed on main -> BLOCKED.
false_out="$(run_claim "$repo" "app/Services/ExampleReader.php" "readItemsNeverLanded")"
printf '%s' "$false_out" | grep -q '^BLOCKED' && ok "false/phantom Verified-context claim -> BLOCKED (does not proceed on faith)" || no "false claim NOT blocked — would have proceeded on an unverified claim (out: $false_out)"

# FALSE-PATH claim: the whole file never existed on main -> BLOCKED.
false_path_out="$(run_claim "$repo" "app/Services/NeverExisted.php" "anything")"
printf '%s' "$false_path_out" | grep -q '^BLOCKED' && ok "claim against a nonexistent file -> BLOCKED" || no "nonexistent-file claim NOT blocked (out: $false_path_out)"

# No-git-repo case: main cannot resolve at all -> BLOCKED (fails safe, never silently proceeds).
nogit="$(mktemp -d)"
nogit_out="$(run_claim "$nogit" "whatever.php" "whatever")"
printf '%s' "$nogit_out" | grep -q '^BLOCKED' && ok "unresolvable main (non-git dir) -> BLOCKED (fails safe)" || no "unresolvable main did NOT fail safe (out: $nogit_out)"

# ── RED-BEFORE proof for the claim-verification gate: the OLD behavior (structural-only check,
#    the shape the generator's own self-validate uses per v-runnable-pack-convention.md — grep for
#    a `requires:` line's mere PRESENCE) would ACCEPT the false claim above, since it never greps
#    main at all. This demonstrates the class of bug the new live-grep gate fixes. ──
naive_pack="$(mktemp -d)/pack.txt"
cat > "$naive_pack" <<'EOF'
/v continue the example-gateway work
## Verified context
- app/Services/ExampleReader.php: readItemsNeverLanded landed in wave-0 example-gateway
requires: app/Services/ExampleReader.php: readItemsNeverLanded
BLOCKED: stop if the above is not found
EOF
if grep -qi '^requires:' "$naive_pack"; then
  ok "RED-BEFORE confirmed: structural-only check (old self-validate shape) ACCEPTS the same false claim the new live-grep gate BLOCKS"
else
  no "RED-BEFORE not reproduced for claim verification"
fi
rm -rf "$repo" "$nogit" "$(dirname "$naive_pack")"

# ── Part 4: real .v-prompt-packs trees under ~/.claude (if any exist) actually have a 99-* file ──
REAL_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.v-prompt-packs"
if [ -d "$REAL_ROOT" ]; then
  any=0; missing=0
  for D in "$REAL_ROOT"/v-*; do
    [ -d "$D" ] || continue
    HAS_WAVE=$(find "$D" -maxdepth 1 -type f -name 'w[0-9]*-*.txt' 2>/dev/null | head -1)
    [ -n "$HAS_WAVE" ] || continue
    any=1
    HAS_99=$(find "$D" -maxdepth 1 -type f -name '99-*' 2>/dev/null | head -1)
    [ -n "$HAS_99" ] || { missing=1; echo "  NO  $(basename "$D") is wave-based but has no 99-* final verify pack"; }
  done
  if [ "$any" = 0 ]; then
    ok "no real wave-based pack directories exist under $REAL_ROOT (vacuously satisfied)"
  elif [ "$missing" = 0 ]; then
    ok "every real wave-based pack directory under $REAL_ROOT has a 99-* final verify pack"
  else
    no "at least one real wave-based pack directory under $REAL_ROOT is missing its 99-* final verify pack"
  fi
else
  ok "no $REAL_ROOT directory exists (nothing to check — vacuously satisfied)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
