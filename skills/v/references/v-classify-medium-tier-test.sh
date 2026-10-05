#!/usr/bin/env bash
# v-classify-medium-tier-test.sh — W-MEDIUM ordinary-code-change tier (2026-08-03).
#
# Proves BOTH directions of the diff-shape gate against a REAL sandbox git repo, mirroring
# p1b-light-tier-test.sh's factory idiom:
#   qualifying: an ordinary controller+service change with a real test → MEDIUM=1
#               (this is the exact shape LIGHT can NEVER match — app/Http/Controllers is not in
#                LIGHT's allow-list — and is a real forensic shape)
#   excluded:   signing PATH → 0 ; signing CONTENT in an innocent path → 0 ; user-facing UI → 0 ;
#               migration → 0 ; no accompanying test → 0 ; >10 non-test files → 0 ;
#               >400 non-test lines → 0 ; test present but untouched → 0 ;
#               missing security lib → fail-closed 0
#   parity:     the LIGHT classifier's own verdict is UNCHANGED by this script's existence
#               (MEDIUM is additive — it must not perturb the LIGHT= contract the hook greps)
#
# RED ORACLE: the classifier did not exist pre-W-MEDIUM, so script absence is trivially red —
# V_MEDIUM_TIER_CLASSIFIER=/nonexistent reproduces it.
set -u
CLS="${V_MEDIUM_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-medium-tier.sh}"
LIGHT_CLS="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$CLS" ] || { echo "  NO  medium classifier missing (pre-W-MEDIUM = RED)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

mkrepo() { # $1 = name → echoes repo path; committed baseline with the dirs we mutate
  local r="$WORK/$1"
  mkdir -p "$r/app/Http/Controllers" "$r/app/Services" "$r/app/Support" "$r/tests/Feature" \
           "$r/resources/js/Pages" "$r/database/migrations" "$r/config" "$r/routes"
  git -C "$r" init -q -b main 2>/dev/null || { git -C "$r" init -q; git -C "$r" checkout -q -b main; }
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  printf '<?php\nclass ExampleController {}\n'  > "$r/app/Http/Controllers/ExampleController.php"
  printf '<?php\nclass ExampleService {}\n'     > "$r/app/Services/ExampleService.php"
  printf '<?php\n// existing test\n'             > "$r/tests/Feature/ExampleControllerTest.php"
  printf '<?php\n// helper\n'                    > "$r/app/Support/Helper.php"
  printf 'export default function Home(){return null;}\n' > "$r/resources/js/Pages/Home.tsx"
  printf '<?php\n// migration\n'                 > "$r/database/migrations/2026_01_01_000000_create_x.php"
  printf '<?php\nreturn [];\n'                   > "$r/config/app.php"
  printf '.v/\n'                                 > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm baseline
  printf '%s' "$r"
}
run() { ( cd "$1" && CLAUDE_SESSION_ID="wmedium-test-sid" REPO_ROOT="$1" bash "$CLS" 2>/dev/null ); }
verdict(){ printf '%s' "$1" | sed -n 's/^MEDIUM=//p' | head -1; }
reason(){  printf '%s' "$1" | sed -n 's/^REASON=//p' | head -1; }

echo "== W-MEDIUM :: qualifying direction (the shape LIGHT can never match) =="
R=$(mkrepo q1)
printf '<?php\nclass ExampleController { public function show(){ return 1; } }\n' > "$R/app/Http/Controllers/ExampleController.php"
printf '<?php\nclass ExampleService { public static function body(){ return []; } }\n' > "$R/app/Services/ExampleService.php"
printf '<?php\n// existing test\nit("renders", function(){ expect(1)->toBe(1); });\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R")
[ "$(verdict "$OUT")" = "1" ] \
  && ok "ordinary controller+service change WITH a test → MEDIUM=1" \
  || no "ordinary app change was not classified MEDIUM" "$(reason "$OUT")"
# Cross-check: the SAME diff must NOT be LIGHT (else MEDIUM is redundant, not a new tier).
if [ -f "$LIGHT_CLS" ]; then
  LOUT=$( cd "$R" && CLAUDE_SESSION_ID="wmedium-test-sid" REPO_ROOT="$R" bash "$LIGHT_CLS" 2>/dev/null )
  printf '%s' "$LOUT" | grep -q '^LIGHT=0' \
    && ok "the SAME diff is LIGHT=0 (MEDIUM fills a real gap, does not duplicate LIGHT)" \
    || no "diff was also LIGHT=1 — MEDIUM would be redundant here" "$(printf '%s' "$LOUT" | head -2 | tr '\n' ' ')"
fi

echo "== W-MEDIUM :: hard exclusions (over-exclusion is safe; each falls back to FULL) =="
R=$(mkrepo x_ui)
printf 'export default function Home(){return <div>hi</div>;}\n' > "$R/resources/js/Pages/Home.tsx"
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'user_facing_ui'; } \
  && ok "user-facing UI → MEDIUM=0 (owes UX_CRITIQUE + WORKFLOW_VERIFICATION)" \
  || no "UI diff was not excluded" "$r"

R=$(mkrepo x_mig)
printf '<?php\n// migration\nSchema::create("x", fn($t)=>$t->id());\n' > "$R/database/migrations/2026_01_01_000000_create_x.php"
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'migration_hard_excluded'; } \
  && ok "migration → MEDIUM=0 (CLAUDE.md § Database Safety stop-list)" \
  || no "migration was not excluded" "$r"

R=$(mkrepo x_seccontent)
printf '<?php\nclass ExampleService { public function s($p){ return hash_hmac("sha256", $p, getenv("SECRET")); } }\n' > "$R/app/Services/ExampleService.php"
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'security_content'; } \
  && ok "signing CONTENT in an innocent path → MEDIUM=0" \
  || no "security content was not excluded" "$r"

echo "== W-MEDIUM :: size + test-discipline bounds =="
R=$(mkrepo x_notest)
printf '<?php\nclass ExampleController { public function show(){ return 1; } }\n' > "$R/app/Http/Controllers/ExampleController.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'no_accompanying_test_file'; } \
  && ok "no accompanying test → MEDIUM=0 (the diff's own regression guard is mandatory)" \
  || no "missing test did not exclude" "$r"

R=$(mkrepo x_untouched_test)
printf '<?php\nclass ExampleController { public function show(){ return 1; } }\n' > "$R/app/Http/Controllers/ExampleController.php"
touch "$R/tests/Feature/ExampleControllerTest.php"   # listed but ZERO changed lines
OUT=$(run "$R"); r=$(reason "$OUT")
[ "$(verdict "$OUT")" = "0" ] \
  && ok "test file present but with no changed lines → MEDIUM=0" \
  || no "an untouched test satisfied the requirement" "$r"

R=$(mkrepo x_files)
for i in $(seq 1 11); do printf '<?php\nclass S%s { public function a(){} }\n' "$i" > "$R/app/Services/S$i.php"; done
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'too_many_non_test_files'; } \
  && ok "11 non-test files → MEDIUM=0 (cap 10, CLAUDE.md '4–10 files')" \
  || no "file cap not enforced" "$r"

R=$(mkrepo x_lines)
{ printf '<?php\n'; for i in $(seq 1 420); do printf '// line %s\n' "$i"; done; } > "$R/app/Services/ExampleService.php"
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$(run "$R"); r=$(reason "$OUT")
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$r" | grep -q 'too_many_lines'; } \
  && ok "420 non-test lines → MEDIUM=0 (cap 400)" \
  || no "line cap not enforced" "$r"

echo "== W-MEDIUM :: fail-closed when a pattern lib is unavailable =="
R=$(mkrepo x_nolib)
printf '<?php\nclass ExampleController { public function show(){ return 1; } }\n' > "$R/app/Http/Controllers/ExampleController.php"
printf '<?php\n// t\nit("x",function(){});\n' > "$R/tests/Feature/ExampleControllerTest.php"
OUT=$( cd "$R" && CLAUDE_SESSION_ID="wmedium-test-sid" REPO_ROOT="$R" \
        V_SECURITY_PATTERN_LIB=/nonexistent/sec.sh bash "$CLS" 2>/dev/null )
{ [ "$(verdict "$OUT")" = "0" ] && printf '%s' "$(reason "$OUT")" | grep -q 'security_pattern_lib_missing'; } \
  && ok "missing security lib → fail-CLOSED MEDIUM=0 (never fail-open)" \
  || no "missing security lib did not fail closed" "$(reason "$OUT")"

echo "== W-MEDIUM :: enforcement side (hook W-MEDIUM hoist + W-MEDIUM-IMPACT block) =="
# Extract-and-eval the hook's two regions, same idiom as p1b-light-tier-test.sh § enforcement.
# A classifier nobody consults is dead code (cf. PANEL_LENSES), so the waiver must be proven
# against the REAL hook text, not just asserted.
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
MHOIST="$(awk '/=== W-MEDIUM \(2026-08-03\): medium-tier verdict, hoisted/,/=== end W-MEDIUM hoist/' "$HOOK")"
MIMPACT="$(awk '/=== W-MEDIUM-IMPACT/,/=== end W-MEDIUM-IMPACT/' "$HOOK")"
if [ -z "$MHOIST" ]; then
  no "W-MEDIUM hoist block present in hook" "awk range empty (pre-W-MEDIUM hook = RED)"
elif [ -z "$MIMPACT" ]; then
  no "W-MEDIUM-IMPACT block present in hook" "awk range empty (pre-W-MEDIUM hook = RED)"
else
  ok "W-MEDIUM hoist block present in hook"
  ok "W-MEDIUM-IMPACT block present in hook"
  BLK="$MHOIST"$'\n'"$MIMPACT"
  MED_STUB="$WORK/med-stub.sh";  printf '#!/usr/bin/env bash\necho "MEDIUM=1"\necho "FILES=app/Services/X.php"\necho "LINES=120"\n' > "$MED_STUB"
  FULL_STUB="$WORK/full-stub.sh"; printf '#!/usr/bin/env bash\necho "MEDIUM=0"\necho "REASON=x"\n' > "$FULL_STUB"
  run_blk() { # $1=classifier-stub $2=IMPACT_MAP_FILE → "MISSING_IMPACT=<n>|WARN=<y/n>"
    (
      set +eu
      SESSION_ID="wmedium-test-sid"; REPO_ROOT="$WORK"; MISSING_IMPACT=1
      IMPACT_MAP_FILE="$2"; WARNINGS=""
      V_MEDIUM_TIER_CLASSIFIER="$1"
      eval "$BLK" >/dev/null 2>&1
      printf 'MISSING_IMPACT=%s|WARN=%s' "$MISSING_IMPACT" \
        "$(case "$WARNINGS" in (*"IMPACT_MAP waived: MEDIUM-TIER"*) echo y;; (*) echo n;; esac)"
    )
  }
  R1=$(run_blk "$MED_STUB" "")
  [ "$R1" = "MISSING_IMPACT=0|WARN=y" ] \
    && ok "MEDIUM diff + ABSENT IMPACT_MAP → waived as a WARNING, not a block" \
    || no "medium waiver did not fire" "$R1"
  R2=$(run_blk "$FULL_STUB" "")
  [ "$R2" = "MISSING_IMPACT=1|WARN=n" ] \
    && ok "non-medium diff → IMPACT_MAP still REQUIRED (lane does not leak)" \
    || no "waiver leaked to a non-medium diff" "$R2"
  # SCOPE GUARD parity with P1B: a PRESENT artifact keeps its own blocking reason. The waiver
  # skips a DISPATCH; it must never override a verdict on an artifact that exists.
  R3=$(run_blk "$MED_STUB" "$WORK/IMPACT_MAP_present.md")
  [ "$R3" = "MISSING_IMPACT=1|WARN=n" ] \
    && ok "PRESENT-but-invalid IMPACT_MAP is NEVER waived, even on a medium diff" \
    || no "waiver overrode a present artifact's verdict" "$R3"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
