#!/usr/bin/env bash
# check-pack-conflicts-test.sh — BEHAVIORAL suite for check-pack-conflicts.sh (the pre-run pack
# DUPLICATE/CONFLICT lint, 2026-07-11).
#
# WHY: run-v-packs's FND-DUP guard de-dupes only identical bodies at DISPATCH time; nothing compared
# pack INSTRUCTIONS across a queue. A live scan of a real 4-batch queue found 24 same-wave/cross-batch
# '## Files' collisions that would have raced on merge. This suite pins the lint's whole contract:
# discovery + batch expansion, duplicate hashing, same-wave vs cross-wave vs cross-batch classification,
# glob strength, dir-mention weakness, multi-99, --quarantine, and --judge downgrade semantics.
# Portable bash 3.2/macOS: no assoc arrays, no mapfile.
set -uo pipefail
CHECKER="${CHECKER:-$HOME/.claude/scripts/check-pack-conflicts.sh}"
[ -f "$CHECKER" ] || { echo "FATAL: checker not found: $CHECKER"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

mkpack(){ # $1=path $2=files-section-body (one path per line; empty = no ## Files)
  mkdir -p "$(dirname "$1")"
  { echo "/v do the task named $(basename "$1")"
    echo
    echo "## Context"
    echo "Self-contained context for $(basename "$1")."
    if [ -n "$2" ]; then
      echo
      echo "## Files"
      printf '%s\n' "$2" | while IFS= read -r l; do [ -n "$l" ] && echo "- $l"; done
    fi
    echo
    echo "## Changes"
    echo "1. Do the thing."
  } > "$1"
}

echo "── (1) clean batch: disjoint scopes, distinct bodies → exit 0, zero findings ──"
B1="$TMP/clean"; mkdir -p "$B1"
mkpack "$B1/task-a.txt" 'app/Services/Alpha.php — new service'
mkpack "$B1/task-b.txt" 'app/Services/Beta.php — new service'
o="$(bash "$CHECKER" "$B1" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0 on a clean batch" || no "clean batch exited $rc" "$o"
printf '%s\n' "$o" | grep -q '0 hard finding' && ok "reports 0 hard findings" || no "unexpected findings" "$o"

echo "── (2) DUPLICATE: identical normalized body under a different filename → hard, exit 1 ──"
B2="$TMP/dup"; mkdir -p "$B2"
mkpack "$B2/original.txt" 'app/Services/Gamma.php — edit'
# same body under a different name, differing only in trailing whitespace + extra blank lines (leading
# whitespace would invalidate the /v first line — the convention's own is_pack rule)
{ sed 's/$/  /' "$B2/original.txt"; echo; echo; } > "$B2/copy-respaced.txt"
o="$(bash "$CHECKER" "$B2" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on duplicate" || no "duplicate exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'DUPLICATE' && ok "DUPLICATE finding reported (whitespace-normalized)" || no "no DUPLICATE line" "$o"

echo "── (3) SAME-WAVE COLLISION: two wave-0 packs declare the same file → hard, exit 1 ──"
B3="$TMP/wave"; mkdir -p "$B3"
mkpack "$B3/edit-routes-a.txt" 'routes/web.php — add route A
app/Http/Controllers/AController.php — new'
mkpack "$B3/edit-routes-b.txt" 'routes/web.php — add route B
app/Http/Controllers/BController.php — new'
o="$(bash "$CHECKER" "$B3" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on same-wave collision" || no "collision exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'SAME-WAVE COLLISION.*routes/web.php' && ok "collision names the shared file" || no "missing collision line" "$o"

echo "── (4) cross-WAVE same batch: same file in w1- and w2- packs → sequenced by design, exit 0 ──"
B4="$TMP/xwave"; mkdir -p "$B4"
mkpack "$B4/w1-first.txt"  'routes/web.php — add route'
mkpack "$B4/w2-second.txt" 'routes/web.php — extend route'
o="$(bash "$CHECKER" "$B4" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0: waves already sequence the overlap" || no "cross-wave flagged (exited $rc)" "$o"

echo "── (5) CROSS-BATCH overlap + batch expansion from a root dir → hard, exit 1 ──"
R5="$TMP/root5"; mkdir -p "$R5/batch-a" "$R5/batch-b"
echo "# map" > "$R5/batch-a/00-README.md"; echo "# map" > "$R5/batch-b/00-README.md"
mkpack "$R5/batch-a/task.txt" 'resources/js/app.tsx — tweak titles'
mkpack "$R5/batch-b/task.txt" 'resources/js/app.tsx — restructure layout'
o="$(bash "$CHECKER" "$R5" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on cross-batch overlap" || no "cross-batch exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'CROSS-BATCH OVERLAP.*resources/js/app.tsx' && ok "cross-batch finding names the file" || no "missing CROSS-BATCH line" "$o"
printf '%s\n' "$o" | grep -q '2 batch(es)' && ok "root expanded into 2 batches" || no "batch expansion wrong" "$(printf '%s\n' "$o" | head -1)"

echo "── (6) GLOB strength: content/blog/*.md vs an exact file in the same wave → hard ──"
B6="$TMP/glob"; mkdir -p "$B6"
mkpack "$B6/bulk-pass.txt"   'content/blog/*.md — retitle posts'
mkpack "$B6/single-post.txt" 'content/blog/some-post.md — rewrite'
o="$(bash "$CHECKER" "$B6" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on glob∩file same wave" || no "glob overlap exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'SAME-WAVE COLLISION.*content/blog.*(glob)' && ok "glob collision reported as glob" || no "missing glob collision" "$o"

echo "── (7) bare-DIR mention overlap → warning only, exit 0 ──"
B7="$TMP/dir"; mkdir -p "$B7"
mkpack "$B7/feat-a.txt" 'database/migrations/ — new migration
app/Models/Aaa.php — new model'
mkpack "$B7/feat-b.txt" 'database/migrations/ — new migration
app/Models/Bbb.php — new model'
o="$(bash "$CHECKER" "$B7" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "exit 0: dir mentions are warnings" || no "dir overlap exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'DIR-OVERLAP.*database/migrations' && ok "dir overlap warned" || no "missing DIR-OVERLAP warning" "$o"

echo "── (8) MULTI-99: two 99-* verify packs in one batch → hard, exit 1 ──"
B8="$TMP/multi99"; mkdir -p "$B8"
mkpack "$B8/task.txt" 'app/Services/Delta.php — edit'
printf '/v verify the batch\n\n## Goal\nVerify A.\n## Checks\n- check\n## Acceptance\n- pass\n' > "$B8/99-verify.txt"
printf '/v verify the batch again\n\n## Goal\nVerify B.\n## Checks\n- check\n## Acceptance\n- pass\n' > "$B8/99-verify-extra.txt"
o="$(bash "$CHECKER" "$B8" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "exit 1 on multiple 99-* packs" || no "multi-99 exited $rc" "$o"
printf '%s\n' "$o" | grep -q 'MULTI-99' && ok "MULTI-99 reported" || no "missing MULTI-99 line" "$o"

echo "── (9) no-'## Files' note: implementation pack noted; read-only pack exempt ──"
B9="$TMP/noscope"; mkdir -p "$B9"
mkpack "$B9/impl-no-files.txt" ''
printf '/v-pre-flight\n\n## Goal\nRun gates.\n## Checks\n- gates\n## Acceptance\n- pass\n' > "$B9/w1-pre-flight.txt"
o="$(bash "$CHECKER" "$B9" 2>&1)"; rc=$?
printf '%s\n' "$o" | grep -q 'impl-no-files' && ok "unscoped implementation pack noted" || no "implementation pack not noted" "$o"
printf '%s\n' "$o" | grep -q 'w1-pre-flight' && no "read-only pack wrongly noted as unscoped" "$o" || ok "read-only pack exempt from the note"
[ "$rc" -eq 0 ] && ok "notes alone do not fail the lint" || no "notes-only run exited $rc" "$o"

echo "── (10) --quarantine parks the exact-duplicate COPY, keeps the first, leaves near-dups alone ──"
B10="$TMP/quar"; mkdir -p "$B10"
mkpack "$B10/original.txt" 'app/Services/Epsilon.php — edit'
cp "$B10/original.txt" "$B10/zz-copy.txt"
o="$(bash "$CHECKER" --quarantine "$B10" 2>&1)"; rc=$?
[ -f "$B10/original.txt" ] && ok "first copy kept in place" || no "first copy was moved"
[ -f "$B10/.needs-review/zz-copy.txt" ] && ok "duplicate copy parked in .needs-review/" || no "duplicate not parked" "$(ls "$B10" "$B10/.needs-review" 2>/dev/null | tr '\n' ' ')"
printf '%s\n' "$o" | grep -q 'quarantined' && ok "quarantine action reported" || no "no quarantine message" "$o"

echo "── (11) --judge: stub LLM downgrades a COMPLEMENTARY cross-batch pair; CONFLICT verdict stays hard ──"
mkdir -p "$TMP/fakebin"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "VERDICT: COMPLEMENTARY — different concerns, safe sequentially"\n' > "$TMP/fakebin/claude-comp"
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "VERDICT: CONFLICT — contradictory instructions for the same file"\n' > "$TMP/fakebin/claude-conf"
chmod +x "$TMP/fakebin/claude-comp" "$TMP/fakebin/claude-conf"
R11="$TMP/root11"; mkdir -p "$R11/ba" "$R11/bb"
echo "# map" > "$R11/ba/00-README.md"; echo "# map" > "$R11/bb/00-README.md"
mkpack "$R11/ba/task.txt" 'config/app.php — set value A'
mkpack "$R11/bb/task.txt" 'config/app.php — set value B'
o="$(CLAUDE_BIN="$TMP/fakebin/claude-comp" bash "$CHECKER" --judge "$R11" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "COMPLEMENTARY verdict downgrades cross-batch to warning (exit 0)" || no "downgrade failed (exit $rc)" "$o"
printf '%s\n' "$o" | grep -q 'judge: COMPLEMENTARY' && ok "downgrade cites the judge verdict" || no "no judge citation" "$o"
o="$(CLAUDE_BIN="$TMP/fakebin/claude-conf" bash "$CHECKER" --judge "$R11" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "CONFLICT verdict stays hard (exit 1)" || no "CONFLICT verdict did not stay hard (exit $rc)" "$o"
printf '%s\n' "$o" | grep -q 'judge: CONFLICT' && ok "hard finding cites the judge verdict" || no "no judge citation on hard finding" "$o"

echo "── (12) DONE-* and hidden dirs are never scanned as batches ──"
R12="$TMP/root12"; mkdir -p "$R12/live" "$R12/DONE-old" "$R12/.hidden"
echo "# map" > "$R12/live/00-README.md"; echo "# map" > "$R12/DONE-old/00-README.md"; echo "# map" > "$R12/.hidden/00-README.md"
mkpack "$R12/live/task.txt" 'app/Services/Zeta.php — edit'
mkpack "$R12/DONE-old/task.txt" 'app/Services/Zeta.php — edit'   # would be a cross-batch hit if scanned
o="$(bash "$CHECKER" "$R12" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "DONE-*/hidden batches ignored (no phantom cross-batch)" || no "archived batch scanned (exit $rc)" "$o"
printf '%s\n' "$o" | grep -q '1 batch(es)' && ok "only the live batch counted" || no "batch count wrong" "$(printf '%s\n' "$o" | head -1)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
