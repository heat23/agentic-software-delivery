#!/usr/bin/env bash
# worktree-php-setup-test.sh — regression harness for hooks/worktree-php-setup.sh (W62-F1 v3).
#
# Proves a worktree gets its OWN real, independent vendor (a CoW clone of main's) so that
# `./vendor/bin/<tool>` resolves __DIR__ to the WORKTREE and loads the WORKTREE autoloader/source
# — NOT main's. The pre-v3 "split symlink" left vendor/bin symlinked → main, which (because PHP
# resolves __DIR__ through symlinks, php.net #46260) ran main's binary + main's autoload, causing
# "Cannot redeclare class ComposerAutoloaderInit<lock-hash>" (the worktree shares main's lock so
# the autoloader class name collides) or silently testing main's code.
#
# Faithful model of how pest/phpunit load TWO autoloads: a "binary" in vendor/bin that loads its
# autoload __DIR__-relative (like the composer bin proxy / pest), plus a CWD-relative phpunit-style
# bootstrap. Each scenario uses its OWN pristine main repo (no cross-scenario contamination).
# Re-run anytime:  bash ~/.claude/skills/v/references/worktree-php-setup-test.sh
# Exit 0 = all pass. SKIPs (exit 0) if php/composer/git unavailable.
set -uo pipefail
HOOK="$HOME/.claude/hooks/worktree-php-setup.sh"
for bin in php composer git; do command -v "$bin" >/dev/null 2>&1 || { echo "SKIP: '$bin' not available"; exit 0; }; done
[ -f "$HOOK" ] || { echo "SKIP: hook not found at $HOOK"; exit 0; }
PASS=0; FAIL=0
BASE=$(mktemp -d /tmp/wtphp-test.XXXXXX); trap 'rm -rf "$BASE" 2>/dev/null' EXIT

# Build a pristine main repo (App\Marker => "MAIN"), commit, return its path via $REPLY.
fresh_main(){
  local R="$BASE/m$RANDOM$RANDOM"; mkdir -p "$R/app" "$R/vendor/bin"; cd "$R" || return 1
  echo '{ "name":"t/p","autoload":{"psr-4":{"App\\":"app/"}} }' > composer.json
  echo '<?php namespace App; class Marker { public static function where(){ return "MAIN:".__FILE__; } }' > app/Marker.php
  composer dump-autoload --no-interaction >/dev/null 2>&1 || return 1
  printf '#!/usr/bin/env php\n<?php\nrequire __DIR__."/../autoload.php";\n$b=getcwd()."/.bootstrap.php"; if(is_file($b)) require $b;\necho "MARKER=".\\App\\Marker::where().PHP_EOL;\n' > vendor/bin/fakepest
  echo '<?php require getcwd()."/vendor/autoload.php";' > .bootstrap.php
  git init -q; git config user.email t@t.local; git config user.name t
  printf 'vendor/\n.worktrees/\n' > .gitignore; git add -A; git commit -qm init >/dev/null 2>&1
  REPLY="$R"
}
# Add a worktree whose App\Marker says "WORKTREE"; return path via $REPLY.
add_wt(){ git -C "$1" worktree add -q "$1/.worktrees/$2" -b "b/$2" HEAD; echo '<?php namespace App; class Marker { public static function where(){ return "WORKTREE:".__FILE__; } }' > "$1/.worktrees/$2/app/Marker.php"; REPLY="$1/.worktrees/$2"; }
assert_fixed(){ # $1 label  $2 worktree
  local wt="$2" out v b ok=1
  v=$( [ -d "$wt/vendor" ] && [ ! -L "$wt/vendor" ] && echo Y || echo N )
  b=$( [ -e "$wt/vendor/bin" ] && [ ! -L "$wt/vendor/bin" ] && echo Y || echo N )
  out=$( cd "$wt" && php vendor/bin/fakepest 2>&1 )
  [ "$v" = Y ] || ok=0; [ "$b" = Y ] || ok=0
  echo "$out" | grep -q 'WORKTREE:' || ok=0
  echo "$out" | grep -qiE 'redeclare|fatal error' && ok=0
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "  PASS: $1 (real vendor+bin, ran WORKTREE code, no redeclare)"
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (vendor-real=$v bin-real=$b out=$(echo "$out" | tr '\n' ' ' | head -c 160))"; fi
}

echo "═══ T1: pre-existing PLAIN symlink vendor → hook self-corrects ═══"
fresh_main; M=$REPLY; add_wt "$M" t1; W=$REPLY; ln -s "$M/vendor" "$W/vendor"
bash "$HOOK" "$W" >/dev/null 2>&1; assert_fixed "plain-symlink" "$W"

echo "═══ T2: fresh worktree (no vendor) → hook clones ═══"
fresh_main; M=$REPLY; add_wt "$M" t2; W=$REPLY
bash "$HOOK" "$W" >/dev/null 2>&1; assert_fixed "fresh" "$W"

echo "═══ T3: idempotent re-run (already real vendor) → stays correct ═══"
bash "$HOOK" "$W" >/dev/null 2>&1; assert_fixed "idempotent-rerun" "$W"

echo "═══ T4: pre-existing OLD SPLIT (autoload.php+composer real, bin symlinked) → self-corrects ═══"
fresh_main; M=$REPLY; add_wt "$M" t4; W=$REPLY
mkdir -p "$W/vendor"; cp -R "$M/vendor/autoload.php" "$W/vendor/"; cp -R "$M/vendor/composer" "$W/vendor/"; ln -s "$M/vendor/bin" "$W/vendor/bin"
bash "$HOOK" "$W" >/dev/null 2>&1; assert_fixed "old-split" "$W"

echo "═══ T5: vendor-dir path-traversal in composer.json must NOT escape the worktree (rm -rf safety) ═══"
fresh_main; M=$REPLY; add_wt "$M" t5; W=$REPLY
# Hostile composer.json: a traversal vendor-dir must be rejected → defaults to 'vendor', and the
# sentinel one level above the worktree must survive (proves rm -rf can't escape).
python3 - "$M/composer.json" <<'PY'
import json,sys; p=sys.argv[1]; c=json.load(open(p)); c.setdefault("config",{})["vendor-dir"]="../../.."; json.dump(c,open(p,"w"))
PY
SENT="$M/.worktrees/SENTINEL_KEEP"; echo keep > "$SENT"
bash "$HOOK" "$W" >/dev/null 2>&1
if [ -f "$SENT" ]; then PASS=$((PASS+1)); echo "  PASS: traversal vendor-dir rejected; sentinel above worktree survived (no rm -rf escape)"
else FAIL=$((FAIL+1)); echo "  FAIL: sentinel deleted — vendor-dir traversal escaped the worktree!"; fi

echo "═══ Negative control (own repo): split WITHOUT the hook MUST redeclare (test stays faithful) ═══"
fresh_main; M=$REPLY; add_wt "$M" ctl; W=$REPLY
mkdir -p "$W/vendor"; cp -R "$M/vendor/autoload.php" "$W/vendor/"; cp -R "$M/vendor/composer" "$W/vendor/"; ln -s "$M/vendor/bin" "$W/vendor/bin"
# Capture into a var FIRST: under `set -o pipefail`, `if ( php… ) | grep` would return php's
# non-zero fatal exit even when grep matched, falsely reporting "no redeclare".
ctl_out=$( cd "$W" && php vendor/bin/fakepest 2>&1 )
if printf '%s' "$ctl_out" | grep -qiE 'redeclare|fatal'; then PASS=$((PASS+1)); echo "  PASS: control reproduces the redeclare (test models the real bug)"
else FAIL=$((FAIL+1)); echo "  FAIL: control did NOT redeclare — test no longer models the bug"; fi

echo "═══ RESULT: $PASS passed, $FAIL failed ═══"
[ "$FAIL" -eq 0 ]
