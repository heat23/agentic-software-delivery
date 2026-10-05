#!/usr/bin/env bash
# v-drain-undocumented-strand-test.sh — undocumented-strand record (forensic 2026-07-04, HIGH-3).
#
# A dead session that committed to its build branch but left NO HANDOFF and NO merge-deferred marker
# was misreported-by-omission — the drain processed it but nothing documented the strand. The drain
# now emits a durable merge-deferred-style record for such a strand before the land attempt.
#   T1: undocumented strand (commits ahead, dead lock, no HANDOFF/marker) → drain writes a record.
#   T2: the record names the branch + commit count + SID.
#   T3: an ALREADY-documented strand (existing marker) → no duplicate/overwrite.
#   T4 (red fixture): the pre-fix drain writes NO such record.
set -u
DRAIN="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh"
DRAIN_BAK="$HOME/.claude/skills/v/references/v-drain-deferred-merges.sh.pre-consent0704-bak"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
[ -f "$DRAIN" ] || { echo "SKIP: drain missing"; exit 0; }

SID="5484aaaa-1111-4111-8111-000000000001"; S8="${SID%%-*}"
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

mk_strand(){ # $1=root -> repo with an unmerged build branch, dead lock, no HANDOFF/marker
  local R="$1/repo" W="$1/wt"
  mkdir -p "$R"
  ( cd "$R" && git init -q -b main && echo base > app.php && G add -A && G commit -qm base ) >/dev/null 2>&1
  git -C "$R" worktree add -q "$W" -b "build/thing-${S8}" HEAD 2>/dev/null
  ( cd "$W" && echo feat > feat.php && G add feat.php && G commit -qm feat ) >/dev/null 2>&1
  # DEAD lock (pid 1 is alive but not a claude; use a guaranteed-dead pid)
  ( exit 0 ) & _dp=$!; wait "$_dp" 2>/dev/null || true
  printf '%s %s %s\n' "$SID" "$_dp" "$(date +%s)" > "$W/.claude-session-lock"
  mkdir -p "$R/.v/artifacts"
  # NO HANDOFF, NO merge-deferred, but a C-1 review artifact so the land isn't held for a different reason
  : > "$R/AGENT_REVIEW_${SID}.md"
  printf '%s\n' "$R"
}

# merge-back stub so the land attempt is a no-op (we only test the strand-record write)
mk_stub(){ cat > "$1" <<'S'
#!/usr/bin/env bash
exit 0
S
chmod +x "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── T1/T2: undocumented strand → record written, correctly populated ──
F1="$T/f1"; mkdir -p "$F1"; R1="$(mk_strand "$F1")"
STUB="$T/stub.sh"; mk_stub "$STUB"
OUT=$(V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN" "$R1" 2>&1)
MK="$R1/.v/artifacts/merge-deferred-${SID}.md"
if [ -f "$MK" ]; then
  ok "T1 undocumented strand → drain wrote a merge-deferred record"
  grep -q "UNDOCUMENTED STRAND" "$MK" && grep -q "build/thing-${S8}" "$MK" && grep -q "commits_ahead:   1" "$MK" \
    && ok "T2 record names the strand (UNDOCUMENTED STRAND + branch + commits_ahead=1)" \
    || no "T2 record content incomplete" "$(cat "$MK" 2>/dev/null | head -8 | tr '\n' '|')"
else
  no "T1 no strand record written" "$(printf '%s' "$OUT" | tail -3)"
fi

# ── T3: an ALREADY-documented strand → drain does not overwrite the existing marker ──
F3="$T/f3"; mkdir -p "$F3"; R3="$(mk_strand "$F3")"
PRE="$R3/.v/artifacts/merge-deferred-${SID}.md"
printf 'PRE-EXISTING MARKER CONTENT\n' > "$PRE"
V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN" "$R3" >/dev/null 2>&1
if grep -q "PRE-EXISTING MARKER CONTENT" "$PRE" 2>/dev/null; then
  ok "T3 existing marker is NOT overwritten (idempotent — documented strand left alone)"
else
  no "T3 drain clobbered an existing marker" "$(cat "$PRE" 2>/dev/null | head -2)"
fi

# ── T4 (red fixture): pre-fix drain writes NO strand record ──
if [ -f "$DRAIN_BAK" ]; then
  F4="$T/f4"; mkdir -p "$F4"; R4="$(mk_strand "$F4")"
  V_DRAIN_MERGEBACK="$STUB" bash "$DRAIN_BAK" "$R4" >/dev/null 2>&1
  # the pre-fix drain may still create markers via other paths; assert our specific UNDOCUMENTED text is absent
  if [ ! -f "$R4/.v/artifacts/merge-deferred-${SID}.md" ] || ! grep -q "UNDOCUMENTED STRAND" "$R4/.v/artifacts/merge-deferred-${SID}.md" 2>/dev/null; then
    ok "T4 red-fixture: pre-fix drain wrote no UNDOCUMENTED-STRAND record (the omission bug)"
  else
    no "T4 red-fixture vacuous: pre-fix drain already wrote the record"
  fi
else
  ok "T4 skipped: no pre-fix bak on disk"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
