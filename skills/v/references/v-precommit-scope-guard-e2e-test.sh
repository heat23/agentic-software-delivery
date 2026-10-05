#!/usr/bin/env bash
# v-precommit-scope-guard-e2e-test.sh — TRUE end-to-end for the native pre-commit scope guard
# (P-MEGACOMMIT; forensic: one commit swept in dozens of files from many sessions). The component test calls the guard
# script directly; THIS installs it as a real `.git/hooks/pre-commit` and fires it through an actual
# `git commit`, proving git itself invokes it (the MANUAL-commit class the in-session P12 hook can't
# catch). Includes a built-in control: WITHOUT the hook, the same mega-commit succeeds.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
GUARD="${V_SCOPE_GUARD_OVERRIDE:-$HOME/.claude/skills/v/references/v-precommit-scope-guard.sh}"
[ -f "$GUARD" ] || { echo "SKIP: missing $GUARD"; echo "TOTAL: 0 passed, 0 failed"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

BASE="$(mktemp -d)"; trap 'rm -rf "$BASE" 2>/dev/null' EXIT
R="$BASE/repo"; mkdir -p "$R/app"
( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t \
  && echo seed > app/seed.php && git add app/seed.php && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
GCD="$(cd "$R" && git rev-parse --git-common-dir)"; case "$GCD" in /*) : ;; *) GCD="$R/$GCD" ;; esac
HOOKDIR="$GCD/hooks"; mkdir -p "$HOOKDIR"
# Pin the repo's hooks path so a machine/CI global core.hooksPath can't silently shadow our install
# (SREV-002) — local config, so it only affects git operations inside this temp repo.
( cd "$R" && git config core.hooksPath "$HOOKDIR" ) >/dev/null 2>&1
install_hook(){ cp "$GUARD" "$HOOKDIR/pre-commit"; chmod +x "$HOOKDIR/pre-commit"; }
head_sha(){ ( cd "$R" && git rev-parse HEAD ); }
# UUID4-shaped per-session writes-logs (SREV-004) — matches track-session-writes.sh's real filenames.
_sid(){ printf '%08x-0000-0000-0000-%012x' "$1" "$2"; }
stage_mega(){ # $1=prefix $2=base-index : 12 files each from a DISTINCT session (> default MAX 10)
  local i=0; while [ "$i" -lt 12 ]; do
    printf '%s%s\n' "$1" "$i" > "$R/app/$1$i.php"
    printf 'app/%s%s.php\n' "$1" "$i" > "$GCD/claude-session-writes-$(_sid $(( $2 + i )) $(( $2 + i ))).txt"
    i=$((i+1))
  done
  ( cd "$R" && git add app/"$1"*.php ) >/dev/null 2>&1
}

echo "== scope-guard e2e :: native .git/hooks/pre-commit fires on a REAL git commit =="

# (1) mega-commit (12 sessions) through a REAL git commit -> the native hook ABORTS git.
install_hook; stage_mega mega 1
BEFORE="$(head_sha)"
( cd "$R" && git -c commit.gpgsign=false commit -qm "a" ) >/dev/null 2>&1; RC=$?
AFTER="$(head_sha)"
{ [ "$RC" -ne 0 ] && [ "$BEFORE" = "$AFTER" ]; } \
  && ok "mega-commit (12 sessions) -> native pre-commit ABORTS git (rc=$RC, HEAD unchanged)" \
  || no "native hook did not abort the mega-commit" "rc=$RC head-moved=$([ "$BEFORE" != "$AFTER" ] && echo yes || echo no)"

# (2) BUILT-IN CONTROL/BITE: remove the hook -> the SAME staged mega-set commits successfully.
rm -f "$HOOKDIR/pre-commit"
BEFORE2="$(head_sha)"
( cd "$R" && git -c commit.gpgsign=false commit -qm "a" ) >/dev/null 2>&1
AFTER2="$(head_sha)"
[ "$BEFORE2" != "$AFTER2" ] \
  && ok "(control) no hook installed -> mega-commit SUCCEEDS — the bypassed class the guard closes" \
  || no "control mega-commit did not succeed without the hook" "HEAD unchanged"
( cd "$R" && git reset -q --hard "$BEFORE2" ) >/dev/null 2>&1   # undo, then reinstall
install_hook

# (3) a normally-scoped commit (1 session) -> the native hook ALLOWS it.
printf 'one\n' > "$R/app/one.php"; printf 'app/one.php\n' > "$GCD/claude-session-writes-$(_sid 9001 9001).txt"
( cd "$R" && git add app/one.php ) >/dev/null 2>&1
BEFORE3="$(head_sha)"
( cd "$R" && git -c commit.gpgsign=false commit -qm "scoped" ) >/dev/null 2>&1
AFTER3="$(head_sha)"
[ "$BEFORE3" != "$AFTER3" ] \
  && ok "normally-scoped 1-session commit -> ALLOWED by the native hook (no over-block)" \
  || no "scoped commit was wrongly blocked by the hook" "HEAD unchanged"

# (4) --no-verify bypass on a mega-set -> commits (the documented deliberate override).
stage_mega nv 100
BEFORE4="$(head_sha)"
( cd "$R" && git -c commit.gpgsign=false commit --no-verify -qm "override" ) >/dev/null 2>&1
AFTER4="$(head_sha)"
[ "$BEFORE4" != "$AFTER4" ] \
  && ok "git commit --no-verify -> bypasses the native hook (documented escape)" \
  || no "--no-verify did not bypass the native hook" "HEAD unchanged"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
