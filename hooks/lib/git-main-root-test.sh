#!/usr/bin/env bash
# git-main-root-test.sh — bite for the Trap 3 shared helper (handoff-3, C-2/C-3): resolve_main_root must
# find the MAIN checkout root from an external linked worktree via git-common-dir identity, never a
# path-prefix guess (the class that caused a stranded-worktree incident).
set -u
LIB="${V_GMR_LIB:-$HOME/.claude/hooks/lib/git-main-root.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$LIB" ] || { echo "NO git-main-root.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
# shellcheck source=git-main-root.sh
source "$LIB"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
MAIN="$WORK/main"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@example.com; git -C "$MAIN" config user.name t
: > "$MAIN/.gitkeep"; git -C "$MAIN" add -A; git -C "$MAIN" commit -qm init
MAIN_CANON="$(cd "$MAIN" && pwd -P)"

echo "== git-main-root.sh :: resolve_main_root =="

# GREEN-1: from the main root itself.
GOT="$(resolve_main_root "$MAIN")"
[ "$GOT" = "$MAIN_CANON" ] && ok "resolves main root from the main checkout itself" \
  || no "wrong result from main checkout" "got=$GOT want=$MAIN_CANON"

# GREEN-2: EXTERNAL linked worktree (mirrors ~/.claude/worktrees/<repo>/<slug> convention).
WT="$WORK/external-wt-dir/fix-slug-1234"
mkdir -p "$WORK/external-wt-dir"
git -C "$MAIN" worktree add -q -b fix/slug-1234 "$WT" >/dev/null 2>&1
GOT="$(resolve_main_root "$WT")"
[ "$GOT" = "$MAIN_CANON" ] && ok "resolves main root from an EXTERNAL linked worktree (not a path-prefix guess)" \
  || no "external worktree resolution wrong" "got=$GOT want=$MAIN_CANON"

# GREEN-3: an env-poisoned caller (exported GIT_DIR/GIT_COMMON_DIR from an unrelated repo) must not leak in.
OTHER="$WORK/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q -b main >/dev/null 2>&1
GOT="$(GIT_DIR="$OTHER/.git" GIT_COMMON_DIR="$OTHER/.git" bash -c "source '$LIB'; resolve_main_root '$WT'")"
[ "$GOT" = "$MAIN_CANON" ] && ok "env-clean: an inherited GIT_DIR/GIT_COMMON_DIR from another repo does not leak in" \
  || no "env poisoning leaked into resolution" "got=$GOT want=$MAIN_CANON"

# GREEN-4 (codex CDX-3 2026-07-02): GIT_CEILING_DIRECTORIES inherited from a caller must not
# abort discovery — it caps upward traversal, so resolving from a NESTED directory inside the
# worktree fails (rc=1) and every consumer silently no-ops (durable copy skipped, provenance
# falls back worktree-local — the exact class this helper exists to prevent).
NESTED="$WT/deep/nested"; mkdir -p "$NESTED"
GOT="$(GIT_CEILING_DIRECTORIES="$WT/deep" bash -c "source '$LIB'; resolve_main_root '$NESTED'")"
[ "$GOT" = "$MAIN_CANON" ] && ok "env-clean: an inherited GIT_CEILING_DIRECTORIES does not abort nested-dir resolution" \
  || no "GIT_CEILING_DIRECTORIES leaked in and broke resolution" "got='$GOT' want=$MAIN_CANON"

# GREEN-5 (codex CDX-2 2026-07-02): from inside a SUBMODULE checkout, git-common-dir is git
# METADATA (super/.git/modules/<name>) — returning it would aim durable copies at
# .git/modules/.../.v/artifacts, invisible to every artifact scan. Must resolve to the
# submodule's real working tree instead.
SUPER="$WORK/super"; SUBSRC="$WORK/subsrc"
mkdir -p "$SUPER" "$SUBSRC"
git -C "$SUBSRC" init -q -b main; git -C "$SUBSRC" config user.email t@example.com; git -C "$SUBSRC" config user.name t
git -C "$SUBSRC" commit -q --allow-empty -m init
git -C "$SUPER" init -q -b main; git -C "$SUPER" config user.email t@example.com; git -C "$SUPER" config user.name t
git -C "$SUPER" commit -q --allow-empty -m init
if git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$SUBSRC" sub >/dev/null 2>&1; then
  git -C "$SUPER" commit -qm add-sub
  SUB_CANON="$(cd "$SUPER/sub" && pwd -P)"
  GOT="$(resolve_main_root "$SUPER/sub")"
  [ "$GOT" = "$SUB_CANON" ] && ok "submodule checkout resolves to its working tree, not .git/modules metadata" \
    || no "submodule resolved to git metadata dir" "got=$GOT want=$SUB_CANON"
else
  no "could not create fixture submodule (git submodule add failed)" "environment issue, not a lib pass"
fi

# neg-1: not a git repo at all -> empty + non-zero.
NOGIT="$WORK/no-git"; mkdir -p "$NOGIT"
if ! resolve_main_root "$NOGIT" >/tmp/gmr-neg-out-$$.txt 2>/dev/null; then
  ok "non-repo directory -> failure (return 1), no crash"
else
  no "non-repo directory unexpectedly succeeded" "$(cat /tmp/gmr-neg-out-$$.txt 2>/dev/null)"
fi
rm -f /tmp/gmr-neg-out-$$.txt 2>/dev/null

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
