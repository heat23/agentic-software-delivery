#!/usr/bin/env bash
# v-classify-trivial-worktree-scope-test.sh — A4 (forensic 2026-06-21): the trivial classifier must
# bind its changed-file set to THIS session's OWN commits (worktree build branch / commit witness), not
# the shared-main UNCOMMITTED diff. A production session committed a schema.ts feat to a build branch while
# `git diff HEAD` at main root saw only a sibling's auto-stashed test file -> classified "trivial
# test-only" -> gauntlet bypassed on a schema change. Bite: the .pre-a4-bak classifier is
# blind to the committed branch work (RED). Re-run: env -u CLAUDE_SESSION_ID bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CL="$HERE/v-classify-trivial.sh"; BAK="$CL.pre-a4-bak"
[ -f "$CL" ] || { echo "SKIP: classifier missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

# Build a repo whose SID-slug branch carries one COMMITTED file ($2), main HEAD clean. Echo REPO path.
build_repo(){
  local sid="$1" committed="$2" content="$3" R slug base
  R="$(mktemp -d)"; slug="${sid%%-*}"
  ( cd "$R" && git init -q -b main && mkdir -p docs resources/js/lib && printf 'x\n' > seed.txt
    git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
  ( cd "$R" && git checkout -q -b "build/feat-$slug"
    mkdir -p "$(dirname "$committed")" && printf '%s\n' "$content" > "$committed"
    git add -A && git -c commit.gpgsign=false commit -qm "feat work" ) >/dev/null 2>&1
  ( cd "$R" && git checkout -q main ) >/dev/null 2>&1   # main HEAD clean; work lives on the branch only
  printf '%s' "$R"
}
run(){ ( cd "$2" && CLAUDE_SESSION_ID="$3" REPO_ROOT="$2" CLAUDE_MAIN_BRANCH=main bash "$1" 2>/dev/null ); }

echo "== A4 :: trivial classifier scopes to the session's worktree-branch commits =="

# Case 1 — the original bug: a committed feat-on-source (.ts) must be SEEN -> non-trivial.
SID1=fea70000-1111-4111-8111-111111111111
R1="$(build_repo "$SID1" "resources/js/lib/schema.ts" "export const schema = { product: true };")"
OUT1="$(run "$CL" "$R1" "$SID1")"
printf '%s\n' "$OUT1" | grep -q '^TRIVIAL=0' && ok "A4: committed branch feat (schema.ts) -> TRIVIAL=0 (gauntlet enforced)" || no "A4: schema.ts classified trivial" "$OUT1"
printf '%s\n' "$OUT1" | grep -q 'schema.ts'   && ok "A4: classifier actually SAW the committed worktree-branch file" || no "A4: committed file not in scope" "$OUT1"

# Case 2 — no over-restriction: a genuinely-trivial committed docs change still passes.
SID2=fea70000-2222-4222-8222-222222222222
R2="$(build_repo "$SID2" "docs/notes.md" "one trivial doc line")"
OUT2="$(run "$CL" "$R2" "$SID2")"
printf '%s\n' "$OUT2" | grep -q '^TRIVIAL=1' && ok "A4: genuinely-trivial committed docs change still TRIVIAL=1 (no over-restriction)" || no "A4: over-restricted a trivial docs commit" "$OUT2"

# RED — the pre-A4 classifier is blind to committed branch work (sees no uncommitted change).
if [ -f "$BAK" ]; then
  OUTR="$(run "$BAK" "$R1" "$SID1")"
  printf '%s\n' "$OUTR" | grep -q 'schema.ts' \
    && no "RED: pre-A4 already sees the committed file?! bite not isolating A4" "$OUTR" \
    || ok "RED: pre-A4 is BLIND to the committed schema.ts (REASON=$(printf '%s' "$OUTR" | sed -n 's/^REASON=//p')) — bite proven"
else
  echo "  --  (.pre-a4-bak absent; RED phase skipped)"
fi

rm -rf "$R1" "$R2" 2>/dev/null
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
