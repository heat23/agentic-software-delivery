#!/usr/bin/env bash
# p1b-light-tier-test.sh — P1-B light-gauntlet tier (2026-07-03).
#
# Proves BOTH directions of the diff-shape gate against a REAL sandbox git repo:
#   qualifying: a 3-line schedule-guard change in routes/console.php + a real test → LIGHT=1
#   excluded:   the SAME 3-line size but on a signing PATH → LIGHT=0 (hard exclusion)
#               the SAME path class but signing CONTENT (hash_hmac) → LIGHT=0
#               >10 non-test lines → LIGHT=0 ; no accompanying test → LIGHT=0
#               controller path class → LIGHT=0 ; missing security lib → fail-closed LIGHT=0
# And the ENFORCEMENT side (extract-and-eval of the hook's P1B-LIGHT-TIER block, same idiom as
# sessionlog-warn-gate-test.sh):
#   MISSING_QA=1 + no QA_REPORT + LIGHT=1 classifier → QA waived (warning, not block)
#   PRESENT QA_REPORT (e.g. verdict: fail) → NEVER waived, even on a light diff
#
# RED ORACLE: V_CRA_OVERRIDE=check-review-artifact.sh.pre-p1b-bak lacks the P1B block → the
# enforcement tests FAIL (proven at ship time; see BITE_LEDGER). The classifier itself did not
# exist pre-P1B (script absence = trivially red).
set -u
# V_LIGHT_TIER_CLASSIFIER doubles as the red-oracle seam: point it at a pre-W-LIGHT2 copy of the
# classifier and the reachability section below must go RED. Mirrors V_CRA_OVERRIDE for the hook.
CLS="${V_LIGHT_TIER_CLASSIFIER:-$HOME/.claude/skills/v/references/v-classify-light-tier.sh}"
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$CLS" ] || { echo "NO classifier missing (pre-P1B = RED)"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# ── sandbox repo factory ──────────────────────────────────────────────────────
mkrepo() { # $1 = name → echoes repo path; a committed baseline with the dirs we mutate
  local r="$WORK/$1"
  mkdir -p "$r/routes" "$r/config" "$r/tests/Feature" "$r/app/Http/Controllers" "$r/app/Support" \
           "$r/resources/js/lib" "$r/resources/js/Pages" "$r/database/migrations"
  git -C "$r" init -q -b main 2>/dev/null || { git -C "$r" init -q; git -C "$r" checkout -q -b main; }
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  printf '<?php\n// schedule definitions\n$x = 1;\n' > "$r/routes/console.php"
  printf '<?php\nreturn ["queue" => "redis"];\n' > "$r/config/queue.php"
  printf '<?php\n// existing test\n' > "$r/tests/Feature/ScheduleTest.php"
  printf '<?php\nclass C {}\n' > "$r/app/Http/Controllers/HomeController.php"
  printf '<?php\n// helper\n' > "$r/app/Support/Helper.php"
  # W-LIGHT2 fixtures: the TS/JS + tooling surface the pre-W-LIGHT2 allow-list could never reach.
  printf 'export default { build: {} };\n' > "$r/vite.config.ts"
  printf '{\n  "name": "fx",\n  "scripts": { "build": "vite build" }\n}\n' > "$r/package.json"
  printf 'export const clean = (s: string) => s.trim();\n' > "$r/resources/js/lib/text.ts"
  printf 'export default function Home() { return null; }\n' > "$r/resources/js/Pages/Home.tsx"
  printf '<?php\n// migration\n' > "$r/database/migrations/2026_01_01_000000_create_x.php"
  printf '// existing spec\n' > "$r/resources/js/lib/text.test.ts"
  # Real projects gitignore .v/ (and the commit gate's own W5F-10 rule forbids committing gate
  # artifacts). Mirror that here, or a fixture that drops a PRE_FLIGHT under .v/ and runs
  # `git add -A` stages the artifact itself — the classifier then sees an unrecognised .md path
  # and correctly returns LIGHT=0, which reads as a product failure but is fixture contamination.
  printf '.v/\n' > "$r/.gitignore"
  git -C "$r" add -A; git -C "$r" commit -qm baseline
  printf '%s' "$r"
}

run_cls() { # $1=repo → classifier output (no session id ⇒ uncommitted-diff mode)
  ( cd "$1" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$1" bash "$CLS" 2>/dev/null )
}

echo "== P1-B :: light-tier classifier — qualifying direction =="
R=$(mkrepo q1)
cat >> "$R/routes/console.php" <<'EOF'
Schedule::command('backups:verify')
    ->daily()
    ->onOneServer();
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('runs backups:verify on one server only', function () {
    expect(collect(app(Schedule::class)->events())->first()->onOneServer)->toBeTrue();
});
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=1' \
  && ok "3-line onOneServer guard + real test → LIGHT=1" \
  || no "qualifying guard diff rejected" "$(printf '%s' "$out" | tr '\n' ' ')"

echo "== P1-B :: hard exclusions =="
R=$(mkrepo x1)  # signing PATH, same tiny size
printf '<?php\n$sig = 1;\n' > "$R/app/Support/signature-helper.php"  # untracked, security-shaped path
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('x', fn() => expect(true)->toBeTrue());
EOF
git -C "$R" add -N app/Support/signature-helper.php 2>/dev/null
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -qE 'security_path|path_class' \
  && ok "3-line change on a signing PATH → LIGHT=0 (hard-excluded regardless of size)" \
  || no "signing path not excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x2)  # allowed path class but signing CONTENT
cat >> "$R/config/queue.php" <<'EOF'
// verify inbound job payloads
$sig = hash_hmac('sha256', $payload, $secret);
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('y', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'security_content' \
  && ok "allowed path but hash_hmac diff CONTENT → LIGHT=0 (content scan bites)" \
  || no "security content not excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x3)  # W-LIGHT2: ceiling moved 10 → 30, so the boundary probe is now 31 lines
for i in $(seq 1 31); do echo "\$v$i = $i;" >> "$R/routes/console.php"; done
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('z', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'too_many_lines' \
  && ok "31-line diff → LIGHT=0 (line ceiling, W-LIGHT2 default 30)" \
  || no "line ceiling did not bite" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x3b)  # the ceiling is a KNOB, and lowering it must still bite (no hard-coded 30)
for i in $(seq 1 12); do echo "\$v$i = $i;" >> "$R/routes/console.php"; done
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('z', fn() => expect(true)->toBeTrue());
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$R" V_LIGHT_MAX_LINES=10 bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'too_many_lines' \
  && ok "V_LIGHT_MAX_LINES=10 restores the pre-W-LIGHT2 ceiling (knob is live)" \
  || no "V_LIGHT_MAX_LINES override ignored" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x3c)  # file-count ceiling: 5 non-test files > V_LIGHT_MAX_FILES default 4
echo '$a = 1;' >> "$R/routes/console.php"
echo '// c' >> "$R/config/queue.php"
echo '// v' >> "$R/vite.config.ts"
echo '// t' >> "$R/resources/js/lib/text.ts"
echo '// s' >> "$R/app/Support/Helper.php"
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('z', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'too_many_non_test_files' \
  && ok "5 non-test files → LIGHT=0 (file ceiling, default 4)" \
  || no "file ceiling did not bite" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x4)  # no accompanying test
cat >> "$R/routes/console.php" <<'EOF'
Schedule::command('x')->daily();
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'no_accompanying_test' \
  && ok "no test file → LIGHT=0 (real-test requirement)" \
  || no "missing test not rejected" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x5)  # controller path class
cat >> "$R/app/Http/Controllers/HomeController.php" <<'EOF'
public function ping() { return 'ok'; }
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('w', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'path_class_not_light' \
  && ok "controller change → LIGHT=0 (path class not light)" \
  || no "controller path not rejected" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x7)  # Console COMMAND (arbitrary logic) — L#5/CDX-10: only Kernel.php is light
mkdir -p "$R/app/Console/Commands"
printf '<?php\nclass Cmd { public function handle() { /* logic */ } }\n' > "$R/app/Console/Commands/DoThing.php"
git -C "$R" add -N app/Console/Commands/DoThing.php 2>/dev/null
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('u', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'path_class_not_light' \
  && ok "app/Console/Commands change → LIGHT=0 (only Kernel.php schedule wiring is light — L#5)" \
  || no "Console command wrongly light (L#5 regression)" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x8)  # CDX-5: security content smuggled in the TEST file
cat >> "$R/routes/console.php" <<'EOF'
Schedule::command('x')->daily();
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('t', function () { $sig = hash_hmac('sha256', $p, $secret); expect($sig)->not->toBeEmpty(); });
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'security_content_in_test_file' \
  && ok "security content in the TEST file → LIGHT=0 (CDX-5 smuggling channel closed)" \
  || no "test-file security content not excluded (CDX-5 regression)" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo x6)  # missing security lib → fail closed
cat >> "$R/routes/console.php" <<'EOF'
Schedule::command('x')->daily();
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('v', fn() => expect(true)->toBeTrue());
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID=p1b-test-sid REPO_ROOT="$R" V_SECURITY_PATTERN_LIB="$WORK/does-not-exist.sh" bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'security_pattern_lib_missing' \
  && ok "security-pattern lib missing → fail-CLOSED LIGHT=0" \
  || no "did not fail closed without the pattern lib" "$(printf '%s' "$out" | tr '\n' ' ')"

echo "== W-LIGHT2 :: reachability (the TS/JS + tooling surface that was unreachable) =="

R=$(mkrepo w1)  # all-TOOLING diff, NO test — the motivating shape (vite SSR flag + build script)
cat >> "$R/vite.config.ts" <<'EOF'
export const ssr = { noExternal: ['react-helmet-async'] };
EOF
printf '{\n  "name": "fx",\n  "scripts": { "build": "vite build && vite build --ssr" }\n}\n' > "$R/package.json"
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=1' && printf '%s' "$out" | grep -q '^CLASS=tooling' \
  && ok "vite.config.ts + package.json, no test → LIGHT=1 CLASS=tooling (was unreachable pre-W-LIGHT2)" \
  || no "tooling diff not reachable" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w2)  # APPCFG (non-UI TS lib) WITHOUT a test → still excluded under `auto`
cat >> "$R/resources/js/lib/text.ts" <<'EOF'
export const slug = (s: string) => s.toLowerCase();
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'no_accompanying_test_file_for_appcfg' \
  && ok "resources/js/lib change with NO test → LIGHT=0 (auto still demands a test for APPCFG)" \
  || no "appcfg-without-test was not excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w3)  # same change WITH a test → light
cat >> "$R/resources/js/lib/text.ts" <<'EOF'
export const slug = (s: string) => s.toLowerCase();
EOF
cat >> "$R/resources/js/lib/text.test.ts" <<'EOF'
it('slugs', () => expect(slug('A')).toBe('a'));
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=1' && printf '%s' "$out" | grep -q '^CLASS=appcfg' \
  && ok "resources/js/lib change WITH a test → LIGHT=1 CLASS=appcfg" \
  || no "appcfg-with-test not light" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w4)  # V_LIGHT_REQUIRE_TEST=0 relaxes the APPCFG test demand …
cat >> "$R/resources/js/lib/text.ts" <<'EOF'
export const slug = (s: string) => s.toLowerCase();
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$R" V_LIGHT_REQUIRE_TEST=0 bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=1' \
  && ok "V_LIGHT_REQUIRE_TEST=0 → APPCFG without a test becomes LIGHT=1 (knob is live)" \
  || no "REQUIRE_TEST=0 knob dead" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w5)  # … and =1 tightens it back over TOOLING, restoring pre-W-LIGHT2 strictness
cat >> "$R/vite.config.ts" <<'EOF'
export const ssr = { noExternal: ['react-helmet-async'] };
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$R" V_LIGHT_REQUIRE_TEST=1 bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'no_accompanying_test_file' \
  && ok "V_LIGHT_REQUIRE_TEST=1 → even a TOOLING diff needs a test (knob is live both ways)" \
  || no "REQUIRE_TEST=1 knob dead" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w6)  # garbage knob value must fail CLOSED, not silently default to permissive
cat >> "$R/vite.config.ts" <<'EOF'
export const ssr = {};
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$R" V_LIGHT_REQUIRE_TEST=yes bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'invalid_V_LIGHT_REQUIRE_TEST' \
  && ok "invalid V_LIGHT_REQUIRE_TEST → fail-CLOSED LIGHT=0" \
  || no "invalid knob value did not fail closed" "$(printf '%s' "$out" | tr '\n' ' ')"

echo "== W-LIGHT2 :: exclusions the widened allow-list newly has to state =="

R=$(mkrepo w7)  # UI is reachable by the new path list, so it must be explicitly excluded
cat >> "$R/resources/js/Pages/Home.tsx" <<'EOF'
export const label = 'hi';
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('z', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'user_facing_ui_hard_excluded' \
  && ok "resources/js/Pages/*.tsx → LIGHT=0 (UI owes UX_CRITIQUE + WORKFLOW_VERIFICATION)" \
  || no "UI not hard-excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w8)  # schema changes are never light
cat >> "$R/database/migrations/2026_01_01_000000_create_x.php" <<'EOF'
Schema::table('x', fn($t) => $t->string('y')->nullable());
EOF
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('z', fn() => expect(true)->toBeTrue());
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'migration_hard_excluded' \
  && ok "database/migrations change → LIGHT=0 (schema stop-list)" \
  || no "migration not hard-excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w9)  # UI pattern lib missing ⇒ cannot prove the diff is UI-free ⇒ fail CLOSED
cat >> "$R/vite.config.ts" <<'EOF'
export const ssr = {};
EOF
out=$( cd "$R" && CLAUDE_SESSION_ID="p1b-test-sid" REPO_ROOT="$R" \
       V_UI_PATTERN_LIB="$WORK/definitely-absent-ui-lib.sh" bash "$CLS" 2>/dev/null )
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'ui_pattern_lib_missing' \
  && ok "UI-pattern lib missing → fail-CLOSED LIGHT=0" \
  || no "missing UI lib did not fail closed" "$(printf '%s' "$out" | tr '\n' ' ')"

R=$(mkrepo w10)  # a TOOLING path is not a smuggling channel: signing CONTENT still bites
cat >> "$R/vite.config.ts" <<'EOF'
const sig = hash_hmac('sha256', payload, secret);
EOF
out=$(run_cls "$R")
printf '%s' "$out" | grep -q '^LIGHT=0' && printf '%s' "$out" | grep -q 'security_content' \
  && ok "signing CONTENT inside an allowed TOOLING path → LIGHT=0 (content scan still bites)" \
  || no "security content in tooling path not excluded" "$(printf '%s' "$out" | tr '\n' ' ')"

# ── W-UNTRACKED (2026-08-03): brand-new files must COUNT ────────────────────────────────────
# `git diff HEAD` and `git diff --cached` list only TRACKED paths, so a session that CREATES
# files had them INVISIBLE to this classifier and was scored on whatever tracked file it also
# touched. Reproduced live 2026-08-03: a 2-line config/app.php edit + 9 brand-new untracked
# app/Services/*.php returned LIGHT=1 (FILES=config/app.php, LINES=2) — and LIGHT waives QA,
# VERIFY_DONE, IMPACT_MAP *and* the gauntlet witness. That is the fast lane admitting a 10-file
# change. Direction check for the fix: adding untracked paths can only ADD files to the set, so
# it can only make the caps HARDER to clear — it can never promote a diff into this tier.
# RED ORACLE: V_LIGHT_TIER_CLASSIFIER=<pre-wuntracked bak> returns LIGHT=1 here.
echo "== W-UNTRACKED :: brand-new untracked files are counted, not invisible =="
R=$(mkrepo untracked1)
printf '<?php\nreturn ["a" => 1];\n' > "$R/config/queue.php"
cat >> "$R/tests/Feature/ScheduleTest.php" <<'EOF'
it('x', function () { expect(1)->toBe(1); });
EOF
mkdir -p "$R/app/Services"
for i in 1 2 3 4 5 6 7 8 9; do
  printf '<?php\nclass S%s { public function go(){ return %s; } }\n' "$i" "$i" > "$R/app/Services/S$i.php"
done
OUT=$(run_cls "$R")
printf '%s' "$OUT" | grep -q '^LIGHT=0' \
  && ok "9 brand-new untracked service files are SEEN → LIGHT=0 (fast lane not smuggled)" \
  || no "untracked files invisible — LIGHT=1 on a 10-file change" "$(printf '%s' "$OUT" | tr '\n' ' ')"

echo "== P1-B :: enforcement side (hook P1B-LIGHT-TIER block) =="
# W-LIGHT2: the waiver logic now spans TWO regions — the hoisted memo (_light_tier_is_active,
# shared by all four gates) and the QA call site. Eval both, in file order, or the QA block
# references an undefined function and every enforcement assertion below is vacuously green.
HOIST="$(awk '/=== W-LIGHT2 \(2026-08-03\): light-tier verdict, hoisted/,/=== end W-LIGHT2 hoist/' "$HOOK")"
P1B="$(awk '/=== P1B-LIGHT-TIER/,/=== end P1B-LIGHT-TIER/' "$HOOK")"
if [ -z "$HOIST" ]; then
  no "W-LIGHT2 hoist block present in hook" "awk range empty (pre-W-LIGHT2 hook = RED)"
elif [ -z "$P1B" ]; then
  no "P1B-LIGHT-TIER block present in hook" "awk range empty (pre-P1B hook = RED)"
else
  ok "P1B-LIGHT-TIER block present in hook"
  ok "W-LIGHT2 hoist block present in hook"
  P1B="$HOIST"$'\n'"$P1B"
  LIGHT_STUB="$WORK/light-stub.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=1"\necho "FILES=routes/console.php"\necho "LINES=3"\n' > "$LIGHT_STUB"
  HEAVY_STUB="$WORK/heavy-stub.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=0"\necho "REASON=x"\n' > "$HEAVY_STUB"
  run_p1b() { # $1=classifier-stub $2=QA_REPORT_FILE value → echoes "MISSING_QA=<n>|WARN=<y/n>"
    (
      set +eu
      SESSION_ID="p1b-test-sid"; REPO_ROOT="$WORK"; MISSING_QA=1; QA_REPORT_FILE="$2"; WARNINGS=""
      V_LIGHT_TIER_CLASSIFIER="$1"
      eval "$P1B"
      printf 'MISSING_QA=%s|WARN=%s' "$MISSING_QA" "$(printf '%s' "$WARNINGS" | grep -q 'LIGHT-TIER' && echo y || echo n)"
    )
  }
  out=$(run_p1b "$LIGHT_STUB" "")
  [ "$out" = "MISSING_QA=0|WARN=y" ] \
    && ok "no QA_REPORT + LIGHT=1 ⇒ QA waived with explicit warning" \
    || no "light-tier waiver did not fire" "$out"
  out=$(run_p1b "$HEAVY_STUB" "")
  [ "$out" = "MISSING_QA=1|WARN=n" ] \
    && ok "no QA_REPORT + LIGHT=0 ⇒ QA still required (no waiver)" \
    || no "heavy diff wrongly waived" "$out"
  QAF="$WORK/QA_REPORT_p1b-test-sid.md"; printf 'Model: haiku\nverdict: fail\n## QA Acceptance\n' > "$QAF"
  out=$(run_p1b "$LIGHT_STUB" "$QAF")
  [ "$out" = "MISSING_QA=1|WARN=n" ] \
    && ok "PRESENT QA_REPORT (verdict: fail) ⇒ NEVER waived, even with LIGHT=1 (fail is authoritative)" \
    || no "a real QA fail was overridden by light tier" "$out"
fi

echo "== W-LIGHT2 :: the memoized verdict all four gates share =="
if [ -z "$HOIST" ]; then
  no "hoist block evaluable" "awk range empty"
else
  L1="$WORK/l1.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=1"\necho "FILES=vite.config.ts"\necho "LINES=4"\necho "CLASS=tooling"\n' > "$L1"
  L0="$WORK/l0.sh"; printf '#!/usr/bin/env bash\necho "LIGHT=0"\necho "REASON=x"\n' > "$L0"
  run_memo() { ( set +eu; SESSION_ID=s; REPO_ROOT="$WORK"; V_LIGHT_TIER_CLASSIFIER="$1"
                 eval "$HOIST"; _light_tier_is_active && echo yes || echo no ) }
  [ "$(run_memo "$L1")" = "yes" ] && ok "_light_tier_is_active true on LIGHT=1" \
    || no "memo false on LIGHT=1" "$(run_memo "$L1")"
  [ "$(run_memo "$L0")" = "no" ]  && ok "_light_tier_is_active false on LIGHT=0" \
    || no "memo true on LIGHT=0" "$(run_memo "$L0")"
  [ "$(run_memo "$WORK/does-not-exist.sh")" = "no" ] \
    && ok "classifier absent → memo false (fail-SAFE: full gauntlet, never open)" \
    || no "missing classifier did not fail safe" "$(run_memo "$WORK/does-not-exist.sh")"
  # Memoization is not cosmetic: four gates consult this, and a non-memoized version would run the
  # classifier (which shells out to git many times) once per gate on every Stop.
  CNT="$WORK/calls.txt"; : > "$CNT"
  L1C="$WORK/l1c.sh"; printf '#!/usr/bin/env bash\necho x >> "%s"\necho "LIGHT=1"\necho "LINES=4"\n' "$CNT" > "$L1C"
  ( set +eu; SESSION_ID=s; REPO_ROOT="$WORK"; V_LIGHT_TIER_CLASSIFIER="$L1C"
    eval "$HOIST"; _light_tier_is_active; _light_tier_is_active; _light_tier_is_active ) >/dev/null 2>&1
  [ "$(grep -c . "$CNT" | tr -d ' ')" = "1" ] \
    && ok "three consults → ONE classifier run (memoized)" \
    || no "classifier ran more than once" "$(grep -c . "$CNT" | tr -d ' ') runs"
fi

echo "== W-LIGHT2 :: all four waivers are wired to the shared verdict =="
# Structural, deliberately: these four call sites are what make the tier a middle lane rather than
# a QA-only skip. If a future edit drops one, the tier silently reverts and nobody notices.
for probe in \
  "MISSING_VERIFY=0:VERIFY_DONE waiver" \
  "_GAUNTLET_LIGHT_WAIVED=1:gauntlet-witness waiver" \
  "MISSING_IMPACT=0:IMPACT_MAP waiver" \
  "MISSING_QA=0:QA waiver" ; do
  _pat="${probe%%:*}"; _name="${probe#*:}"
  grep -q "_light_tier_is_active" "$HOOK" && grep -B4 "^ *${_pat}$" "$HOOK" | grep -q '_light_tier_is_active' \
    && ok "$_name consults the shared light verdict" \
    || no "$_name not wired to _light_tier_is_active" "pattern $_pat"
done
# Scope guard: the two waivers whose artifact may EXIST must require it to be absent, so a present
# artifact carrying a FAIL verdict is never waived away.
grep -q 'MISSING_IMPACT" -eq 1 \] && \[ -z "$IMPACT_MAP_FILE" \] && _light_tier_is_active' "$HOOK" \
  && ok "IMPACT_MAP waiver requires the artifact to be ABSENT (present-but-invalid still blocks)" \
  || no "IMPACT_MAP waiver missing its absence guard" ""
grep -q 'MISSING_QA" -eq 1 \] && \[ -z "$QA_REPORT_FILE" \] && _light_tier_is_active' "$HOOK" \
  && ok "QA waiver requires the artifact to be ABSENT (a real QA fail still blocks)" \
  || no "QA waiver missing its absence guard" ""

echo "== W-LIGHT2 :: commit gate light lane (real hook, end-to-end) =="
PRECOMMIT="${V_PRECOMMIT_OVERRIDE:-$HOME/.claude/hooks/enforce-pre-commit-gates.sh}"
if [ ! -f "$PRECOMMIT" ]; then
  no "commit gate present" "$PRECOMMIT missing"
else
  SID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  mk_commit_repo() { # $1=name $2=light|heavy → repo with PRE_FLIGHT present, AGENT_REVIEW absent
    local r; r=$(mkrepo "$1"); mkdir -p "$r/.v/artifacts"
    { echo "# PRE_FLIGHT_REPORT"; echo "## Gates"; echo "| gate | status |"; echo "| tests | PASS |"
      echo "Overall Status: PASS"; head -c 1400 /dev/zero | tr '\0' 'x'; } > "$r/.v/artifacts/PRE_FLIGHT_REPORT_${SID}.md"
    if [ "$2" = light ]; then
      echo "export const ssr = {};" >> "$r/vite.config.ts"
    else
      echo '$evil = 1;' >> "$r/app/Http/Controllers/HomeController.php"
    fi
    git -C "$r" add -A >/dev/null 2>&1
    printf '%s' "$r"
  }
  run_precommit() { # $1=repo → hook stdout
    printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m wip"},"cwd":"%s","session_id":"%s"}' "$1" "$SID" \
      | ( cd "$1" && CLAUDE_SESSION_ID="$SID" bash "$PRECOMMIT" 2>/dev/null )
  }
  R=$(mk_commit_repo c1 light)
  out=$(run_precommit "$R")
  printf '%s' "$out" | grep -q 'AGENT_REVIEW' \
    && no "light diff still blocked at commit for a missing AGENT_REVIEW" "$(printf '%s' "$out" | head -c 160)" \
    || ok "light diff + PRE_FLIGHT, no AGENT_REVIEW → commit ALLOWED (order relaxed, not the requirement)"
  R=$(mk_commit_repo c2 heavy)
  out=$(run_precommit "$R")
  printf '%s' "$out" | grep -q 'AGENT_REVIEW' \
    && ok "heavy diff, no AGENT_REVIEW → commit still BLOCKED (lane does not leak)" \
    || no "heavy diff wrongly allowed through the light lane" "$(printf '%s' "$out" | head -c 160)"
fi

echo "== W-LIGHT2 :: [v-chore] escape is honored at Stop, not just at commit =="
CHORE="$(awk '/=== W-LIGHT2-CHORE/,/=== end W-LIGHT2-CHORE/' "$HOOK")"
if [ -z "$CHORE" ]; then
  no "W-LIGHT2-CHORE block present in hook" "awk range empty (pre-W-LIGHT2 hook = RED)"
else
  ok "W-LIGHT2-CHORE block present in hook"
  run_chore() { # $1=repo → "EXITED" if the block accepted completion, else "FELL-THROUGH"
    ( set +eu; SESSION_ID="chore-sid"; IMPLEMENTATION_ONLY_MODE=0
      REPO_ROOT="$1"; V_TMP_DIR_RESOLVED="$1/.v/tmp"
      eval "$CHORE"; echo "FELL-THROUGH" ) 2>/dev/null | tail -1
  }
  mk_chore_repo() { # $1=name $2=tag-every-commit? → repo with a baseline marker + 2 commits
    local r; r=$(mkrepo "$1"); mkdir -p "$r/.v/tmp"
    git -C "$r" rev-parse HEAD > "$r/.v/tmp/head-baseline-chore-sid.txt"
    echo a >> "$r/config/queue.php"; git -C "$r" add -A
    git -C "$r" commit -qm "[v-chore] bump tooling config"
    echo b >> "$r/config/queue.php"; git -C "$r" add -A
    if [ "$2" = yes ]; then git -C "$r" commit -qm "[v-ci-fix] repair the pipeline"
    else git -C "$r" commit -qm "feat: a real untagged feature"; fi
    printf '%s' "$r"
  }
  out=$(run_chore "$(mk_chore_repo ch1 yes)")
  [ "$out" != "FELL-THROUGH" ] \
    && ok "every session commit tagged → Stop accepts (escape is end-to-end, was commit-only)" \
    || no "all-tagged session still owed the gauntlet" "$out"
  out=$(run_chore "$(mk_chore_repo ch2 no)")
  [ "$out" = "FELL-THROUGH" ] \
    && ok "one untagged commit → NO escape (a tag cannot launder an untagged code commit)" \
    || no "untagged commit escaped the gauntlet" "$out"
  R=$(mkrepo ch3); mkdir -p "$R/.v/tmp"; git -C "$R" rev-parse HEAD > "$R/.v/tmp/head-baseline-chore-sid.txt"
  out=$(run_chore "$R")
  [ "$out" = "FELL-THROUGH" ] \
    && ok "zero session commits → NO escape (cannot be claimed by a session that committed nothing)" \
    || no "commitless session escaped" "$out"
fi

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
