#!/usr/bin/env bash
# worktree-app-setup-test.sh — regression harness for hooks/worktree-app-setup.sh.
# Proves a worktree gets .env + per-worktree cache/redis/DB isolation + storage dirs, and that
# the catastrophic guard refuses to munge MAIN's .env. Re-run: bash <thisfile>. SKIPs if no git.
set -uo pipefail
HOOK="$HOME/.claude/hooks/worktree-app-setup.sh"
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
[ -f "$HOOK" ] || { echo "SKIP: hook not found"; exit 0; }
PASS=0; FAIL=0
BASE=$(mktemp -d /tmp/wtapp-test.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

fresh_main(){ # $1=db_connection  → REPLY=repo path
  local R="$BASE/m$RANDOM$RANDOM"; mkdir -p "$R/database"; cd "$R" || return 1
  : > artisan  # mark as a Laravel app
  { echo "APP_ENV=local"; echo "CACHE_PREFIX=main"; echo "DB_CONNECTION=$1";
    [ "$1" = sqlite ] && echo "DB_DATABASE=$R/database/database.sqlite"; } > .env
  [ "$1" = sqlite ] && echo "seeddata" > "$R/database/database.sqlite"
  git init -q; git config user.email t@t.local; git config user.name t
  printf '.env\ndatabase/*.sqlite\n.worktrees/\nstorage/\n' > .gitignore
  echo x > keep.txt; git add -A; git commit -qm init >/dev/null 2>&1
  REPLY="$R"
}
add_wt(){ git -C "$1" worktree add -q "$1/.worktrees/$2" -b "b/$2" HEAD; printf '%s 123\n' "sid$2abcd1234" > "$1/.worktrees/$2/.claude-session-lock"; REPLY="$1/.worktrees/$2"; }

echo "═══ T1: sqlite repo → .env copied, cache/redis/DB isolated, storage dirs created ═══"
fresh_main sqlite; M=$REPLY; add_wt "$M" t1; W=$REPLY
bash "$HOOK" "$W" >/dev/null 2>&1
envf="$W/.env"
{ [ -f "$envf" ] \
  && grep -qE '^CACHE_PREFIX=wt_' "$envf" \
  && grep -qE '^REDIS_PREFIX=wt_' "$envf" \
  && grep -qE '^DB_DATABASE=.*/database/database-.*\.sqlite$' "$envf" \
  && ls "$W"/database/database-*.sqlite >/dev/null 2>&1 \
  && [ -d "$W/storage/framework/cache" ]; } \
  && ok "sqlite worktree fully provisioned + isolated" || no "sqlite provisioning ($(grep -E '^CACHE_PREFIX|^DB_DATABASE' "$envf" 2>/dev/null | tr '\n' ' '))"
# isolation must differ from main
grep -qE '^CACHE_PREFIX=main$' "$M/.env" && ok "main .env CACHE_PREFIX untouched (isolation is worktree-local)" || no "main .env was mutated"

echo "═══ T2: CATASTROPHIC GUARD — running on MAIN must NOT munge main's .env ═══"
fresh_main sqlite; M=$REPLY
before=$(cat "$M/.env")
bash "$HOOK" "$M" >/dev/null 2>&1   # WORKTREE_PATH == main
after=$(cat "$M/.env")
[ "$before" = "$after" ] && ok "main .env unchanged when hook is (mis)pointed at main" || no "GUARD FAILED — main .env mutated!"

echo "═══ T3: idempotent — .env already in worktree → not re-copied/clobbered ═══"
fresh_main sqlite; M=$REPLY; add_wt "$M" t3; W=$REPLY
bash "$HOOK" "$W" >/dev/null 2>&1
first=$(cat "$W/.env")
bash "$HOOK" "$W" >/dev/null 2>&1
second=$(cat "$W/.env")
[ "$first" = "$second" ] && ok "second run is a no-op (idempotent)" || no "idempotency broken"

echo "═══ T4: non-sqlite (mysql) → CACHE_PREFIX still set, no DB copy, warns ═══"
fresh_main mysql; M=$REPLY; add_wt "$M" t4; W=$REPLY
out=$(bash "$HOOK" "$W" 2>&1)
{ grep -qE '^CACHE_PREFIX=wt_' "$W/.env" && ! ls "$W/database/"*.sqlite >/dev/null 2>&1 && printf '%s' "$out" | grep -qi 'SHARE this dev DB'; } \
  && ok "mysql: cache isolated, no sqlite copy, shared-DB warning emitted" || no "mysql handling"

echo "═══ T5: RELATIVE DB_DATABASE resolves against main repo, run from a different CWD (SREV-001) ═══"
fresh_main sqlite; M=$REPLY
{ echo "APP_ENV=local"; echo "CACHE_PREFIX=main"; echo "DB_CONNECTION=sqlite"; echo "DB_DATABASE=database/database.sqlite"; } > "$M/.env"  # RELATIVE path
add_wt "$M" t5; W=$REPLY
( cd /tmp && bash "$HOOK" "$W" ) >/dev/null 2>&1   # run from a CWD that is NOT the repo
wtdb=$(ls "$W"/database/database-*.sqlite 2>/dev/null | head -1)
{ [ -n "$wtdb" ] && grep -q seeddata "$wtdb"; } && ok "relative DB resolved against main → worktree DB is the SEEDED copy, not empty" || no "relative DB not seeded (wtdb=$wtdb)"

echo "═══ T6: pre-existing BARE .env (no CACHE_PREFIX) gets isolated on run (SREV-002) ═══"
fresh_main sqlite; M=$REPLY; add_wt "$M" t6; W=$REPLY
printf 'APP_ENV=local\nDB_CONNECTION=sqlite\n' > "$W/.env"   # operator/partial-run left a bare .env
bash "$HOOK" "$W" >/dev/null 2>&1
grep -qE '^CACHE_PREFIX=wt_' "$W/.env" && ok "pre-existing bare .env got isolated (CACHE_PREFIX applied, not skipped)" || no "bare .env left un-isolated"

echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ]
