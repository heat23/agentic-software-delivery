#!/usr/bin/env bash
# run-v-packs-dryrun-verifyonly-test.sh — bug found while doing the /v-forensics-pack-runner
# handoff's "real forward run" verification (HANDOFF_orchestrator-hardening-3.md, 2026-07-02):
# `--dry-run` against a pack directory containing ONLY a VERIFY pack (99-*, all other packs
# already landed) prints "no packs found" and exits — even though a REAL (non-dry) run on the
# identical directory correctly still runs the VERIFY pack (the real-run guard checks BOTH
# `count_left -eq 0` AND `verify_pack` is empty; the dry-run guard only checked `count_left`,
# which deliberately excludes VERIFY-wave packs by design — see list_all_packs()). Cosmetic (the
# real run is correct), but misleads an operator's dry-run sanity check into believing there is
# nothing left to do.
# Re-run: bash <thisfile>
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
PRE_BAK="${PRE_BAK:-$HOME/.local/bin/run-v-packs.pre-dryrun-verify-only-bak}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

command -v git >/dev/null 2>&1 || { echo "SKIP: git unavailable"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
[ -f "$RUNNER" ] || { echo "SKIP: $RUNNER missing"; exit 0; }

mk_fixture(){  # <root> -> a git repo whose pack dir has ONLY a VERIFY pack (all others "landed")
  local root="$1"
  mkdir -p "$root/packs"
  git -C "$root" init -q 2>/dev/null
  git -C "$root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
  printf '/v final verify\n\nbody\n' > "$root/packs/99-VERIFY.txt"
}

run_dry(){ # <runner_path> <fixture_root> -> stdout
  ( cd "$1" >/dev/null 2>&1; : ) 2>/dev/null   # no-op, keep style consistent with other tests
  bash "$1" "$2/packs" --dry-run 2>&1
}

echo "== run-v-packs --dry-run on a VERIFY-only pack dir must NOT say 'no packs found' =="

if [ -f "$PRE_BAK" ]; then
  ROOT_PRE=$(mktemp -d); mk_fixture "$ROOT_PRE"
  OUT_PRE=$(run_dry "$PRE_BAK" "$ROOT_PRE")
  if printf '%s' "$OUT_PRE" | grep -q "no packs found"; then
    ok "RED confirmed: pre-fix dry-run wrongly reports 'no packs found' for a VERIFY-only dir"
  else
    no "pre-fix backup did not reproduce the bug (investigate before trusting the fix)" "$OUT_PRE"
  fi
  rm -rf "$ROOT_PRE"
else
  echo "  SKIP: no pre-fix backup present (RED proof unavailable this run, GREEN below still holds)"
fi

ROOT_POST=$(mktemp -d); mk_fixture "$ROOT_POST"
OUT_POST=$(run_dry "$RUNNER" "$ROOT_POST")
if printf '%s' "$OUT_POST" | grep -q "no packs found"; then
  no "post-fix dry-run STILL wrongly reports 'no packs found' for a VERIFY-only dir" "$OUT_POST"
else
  ok "GREEN: post-fix dry-run correctly shows the VERIFY pack instead of 'no packs found'"
fi
if printf '%s' "$OUT_POST" | grep -q "VERIFY"; then
  ok "post-fix dry-run output mentions VERIFY (99-VERIFY.txt surfaced)"
else
  no "post-fix dry-run did not surface the VERIFY pack at all" "$OUT_POST"
fi
rm -rf "$ROOT_POST"

echo "== regression: dry-run on a dir with a normal wave pack + a VERIFY pack still works =="
ROOT_MIX=$(mktemp -d); mkdir -p "$ROOT_MIX/packs"
git -C "$ROOT_MIX" init -q 2>/dev/null
git -C "$ROOT_MIX" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
printf '/v wave1 task\n\nbody\n' > "$ROOT_MIX/packs/w1-thing.txt"
printf '/v final verify\n\nbody\n' > "$ROOT_MIX/packs/99-VERIFY.txt"
OUT_MIX=$(run_dry "$RUNNER" "$ROOT_MIX")
{ printf '%s' "$OUT_MIX" | grep -q "w1-thing" && printf '%s' "$OUT_MIX" | grep -q "VERIFY"; } \
  && ok "mixed dir (wave pack + VERIFY) still shows both in dry-run" \
  || no "mixed dir regression" "$OUT_MIX"
rm -rf "$ROOT_MIX"

echo "== regression: dry-run on a genuinely empty dir still says 'no packs found' =="
ROOT_EMPTY=$(mktemp -d); mkdir -p "$ROOT_EMPTY/packs"
git -C "$ROOT_EMPTY" init -q 2>/dev/null
git -C "$ROOT_EMPTY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init 2>/dev/null
OUT_EMPTY=$(run_dry "$RUNNER" "$ROOT_EMPTY")
printf '%s' "$OUT_EMPTY" | grep -q "no packs found" \
  && ok "genuinely empty dir still correctly reports 'no packs found'" \
  || no "genuinely-empty-dir case regressed" "$OUT_EMPTY"
rm -rf "$ROOT_EMPTY"

echo "== SUMMARY: $PASS ok / $FAIL failed =="
echo "TOTAL: $PASS passed, $FAIL failed"   # the form scripts/run-tests.sh counts
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
