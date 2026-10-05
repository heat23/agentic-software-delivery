#!/usr/bin/env bash
# run-v-packs-inbox-nightly-test.sh — BITE test for the pack-inbox engine's core safety
# invariant: default (unset PACK_INBOX_NIGHTLY_EXECUTE — i.e. plain `v-inbox`) mode must NEVER
# invoke run-v-packs, only detect + digest + notify. This is the property the auto-mode
# classifier's "creates unsafe agent" denial forced into the design (see the script's own header)
# — this harness proves it holds and will catch a regression that silently makes execution the
# default again. (2026-07-06: the scheduled/launchd design this engine originally shipped under
# was dropped in favor of the manual `v-inbox` command; the safety invariant under test —
# detect-by-default, execute-only-when-armed — is unchanged and still load-bearing since `v-inbox
# run` is what sets PACK_INBOX_NIGHTLY_EXECUTE=1 now.)
#
# RED oracle: SCRIPT.pre-safedefault-bak is a reconstructed pre-fix snapshot where the EXECUTE gate
# is a no-op (the script always calls run-v-packs regardless of PACK_INBOX_NIGHTLY_EXECUTE) — the
# shape the very first draft of this script had before the classifier denial forced the redesign.
# Also covers: self-registering registry pruning (drained/empty inboxes drop out) and
# register-pack-inbox.sh's dedup idempotency.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/run-v-packs-inbox-nightly.sh}"
REGISTER="${REGISTER:-$HERE/register-pack-inbox.sh}"
BAK="$SCRIPT.pre-safedefault-bak"

[ -f "$SCRIPT" ]   || { echo "FATAL: script not found: $SCRIPT"; exit 2; }
[ -f "$REGISTER" ] || { echo "FATAL: register helper not found: $REGISTER"; exit 2; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fake HOME-shaped runtime dir + a fake project with a pending pack in its inbox. Prints only the
# runtime dir path (the one thing every call site actually consumes) — a prior version printed a
# second "project dir" line too, but `read -r VAR1 VAR2 <<<"$multiline"` only ever consumes the
# FIRST line into VAR1 (a here-string is fed to a single `read`, which stops at the first newline),
# so that second value was always silently empty/unused. Single-line output avoids the footgun.
setup_fixture() {
  local tag="$1"
  local runtime="$TMP/runtime-$tag" proj="$TMP/proj-$tag"
  mkdir -p "$runtime" "$proj/.v/packs/inbox"
  printf '/v do a thing\n\n## Files\nfoo.txt\n' > "$proj/.v/packs/inbox/task.txt"
  printf '%s\n' "$proj" > "$runtime/pack-inbox-registry.txt"
  printf '%s\n' "$runtime"
}

# Stub run-v-packs: records an invocation marker + prints a fake SELF-AUDIT SUMMARY line so the
# digest-parsing logic under test has something realistic to parse.
make_stub() {
  local bin_dir="$1" marker="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/run-v-packs" <<EOF
#!/usr/bin/env bash
echo "invoked \$*" >> "$marker"
echo "═══ SELF-AUDIT SUMMARY ═══"
echo "  packs: 1 done · 0 parked (.needs-review/) · 0 queued"
exit 0
EOF
  chmod +x "$bin_dir/run-v-packs"
}

echo "── (1) default mode (no EXECUTE) never invokes run-v-packs — the core safety invariant ──"
RUNTIME1="$(setup_fixture d1)"
MARK1="$TMP/marker-d1"
STUBBIN1="$TMP/stubbin-d1"; make_stub "$STUBBIN1" "$MARK1"
PATH="$STUBBIN1:$PATH" V_RUNTIME_DIR="$RUNTIME1" bash "$SCRIPT" >/dev/null 2>&1
if [ -f "$MARK1" ]; then no "default mode invoked run-v-packs (SHOULD NOT)" "$(cat "$MARK1")"; else ok "default mode never invoked run-v-packs"; fi
grep -q "detect-only" "$RUNTIME1/pack-inbox-nightly-latest.log" 2>/dev/null && ok "digest records detect-only mode" || no "digest missing detect-only marker"

echo "── (2) RED oracle: pre-safedefault-bak DOES invoke run-v-packs in default mode (proves the harness bites) ──"
if [ -f "$BAK" ]; then
  RUNTIME2="$(setup_fixture d2)"
  MARK2="$TMP/marker-d2"
  STUBBIN2="$TMP/stubbin-d2"; make_stub "$STUBBIN2" "$MARK2"
  PATH="$STUBBIN2:$PATH" V_RUNTIME_DIR="$RUNTIME2" bash "$BAK" >/dev/null 2>&1
  if [ -f "$MARK2" ]; then ok "RED oracle: pre-fix snapshot executes unconditionally (bite proven)"; else no "RED oracle did not bite — .pre-safedefault-bak did not invoke run-v-packs either"; fi
else
  echo "  --  (.pre-safedefault-bak absent; RED skipped)"
fi

echo "── (3) armed mode (PACK_INBOX_NIGHTLY_EXECUTE=1) DOES invoke run-v-packs ──"
RUNTIME3="$(setup_fixture d3)"
MARK3="$TMP/marker-d3"
STUBBIN3="$TMP/stubbin-d3"; make_stub "$STUBBIN3" "$MARK3"
PATH="$STUBBIN3:$PATH" V_RUNTIME_DIR="$RUNTIME3" PACK_INBOX_NIGHTLY_EXECUTE=1 bash "$SCRIPT" >/dev/null 2>&1
if [ -f "$MARK3" ] && grep -q "inbox" "$MARK3"; then ok "armed mode invoked run-v-packs against the project's inbox"; else no "armed mode did not invoke run-v-packs" "$([ -f "$MARK3" ] && cat "$MARK3" || echo '(no marker)')"; fi
grep -q "DIGEST" "$RUNTIME3/pack-inbox-nightly-latest.log" 2>/dev/null && ok "armed-mode digest written" || no "armed-mode digest missing"

echo "── (4) registry pruning: a project with an EMPTY inbox drops out of the registry ──"
RUNTIME4="$TMP/runtime-d4"; PROJ4="$TMP/proj-d4"
mkdir -p "$RUNTIME4" "$PROJ4/.v/packs/inbox"
printf '%s\n' "$PROJ4" > "$RUNTIME4/pack-inbox-registry.txt"
STUBBIN4="$TMP/stubbin-d4"; make_stub "$STUBBIN4" "$TMP/marker-d4"
PATH="$STUBBIN4:$PATH" V_RUNTIME_DIR="$RUNTIME4" bash "$SCRIPT" >/dev/null 2>&1
if grep -qxF "$PROJ4" "$RUNTIME4/pack-inbox-registry.txt" 2>/dev/null; then no "empty-inbox project was NOT pruned from registry"; else ok "empty-inbox project pruned from registry"; fi

echo "── (5) register-pack-inbox.sh: idempotent dedup ──"
RUNTIME5="$TMP/runtime-d5"; mkdir -p "$RUNTIME5"
PROJ5="$TMP/proj-d5"; mkdir -p "$PROJ5"
V_RUNTIME_DIR="$RUNTIME5" bash "$REGISTER" "$PROJ5" >/dev/null 2>&1
V_RUNTIME_DIR="$RUNTIME5" bash "$REGISTER" "$PROJ5" >/dev/null 2>&1
COUNT=$(grep -cxF "$PROJ5" "$RUNTIME5/pack-inbox-registry.txt" 2>/dev/null || echo 0)
[ "$COUNT" -eq 1 ] && ok "double-register is idempotent (1 line, not 2)" || no "expected 1 registry line, got $COUNT"

echo "── (5b) RED oracle: pre-nodedup-bak double-register produces 2 lines (proves check 5 bites) ──"
REGBAK="$REGISTER.pre-nodedup-bak"
if [ -f "$REGBAK" ]; then
  RUNTIME5B="$TMP/runtime-d5b"; mkdir -p "$RUNTIME5B"
  PROJ5B="$TMP/proj-d5b"; mkdir -p "$PROJ5B"
  V_RUNTIME_DIR="$RUNTIME5B" bash "$REGBAK" "$PROJ5B" >/dev/null 2>&1
  V_RUNTIME_DIR="$RUNTIME5B" bash "$REGBAK" "$PROJ5B" >/dev/null 2>&1
  COUNT5B=$(grep -cxF "$PROJ5B" "$RUNTIME5B/pack-inbox-registry.txt" 2>/dev/null || echo 0)
  [ "$COUNT5B" -eq 2 ] && ok "RED oracle: pre-fix register appends duplicates (bite proven)" || no "RED oracle did not bite — expected 2 lines from pre-nodedup-bak, got $COUNT5B"
else
  echo "  --  (.pre-nodedup-bak absent; RED skipped)"
fi

echo "── (6) execute mode prunes a project drained DURING this run (post-run re-check) ──"
RUNTIME6="$(setup_fixture d6)"
PROJ6="$TMP/proj-d6"
MARK6="$TMP/marker-d6"
STUBBIN6="$TMP/stubbin-d6"; mkdir -p "$STUBBIN6"
cat > "$STUBBIN6/run-v-packs" <<EOF
#!/usr/bin/env bash
echo "invoked \$*" >> "$MARK6"
rm -f "$PROJ6/.v/packs/inbox/"*.txt
echo "═══ SELF-AUDIT SUMMARY ═══"
echo "  packs: 1 done · 0 parked (.needs-review/) · 0 queued"
exit 0
EOF
chmod +x "$STUBBIN6/run-v-packs"
PATH="$STUBBIN6:$PATH" V_RUNTIME_DIR="$RUNTIME6" PACK_INBOX_NIGHTLY_EXECUTE=1 bash "$SCRIPT" >/dev/null 2>&1
if grep -qxF "$PROJ6" "$RUNTIME6/pack-inbox-registry.txt" 2>/dev/null; then no "project drained during this run was NOT pruned (pruned one cycle late)"; else ok "project drained during this run pruned immediately"; fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
