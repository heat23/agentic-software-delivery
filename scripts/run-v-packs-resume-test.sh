#!/usr/bin/env bash
# run-v-packs-resume-test.sh — --resume / V_RESUME_PARKED un-park (forensic 2026-07-07).
#
# A batch whose CLOSING wave stranded resumable work (fork-did-real-work / timeout with uncommitted worktree)
# parked its pack in .needs-review/ and then sat at exit 2 FOREVER: the park blocks the wave barrier, and the
# re-run does not re-attempt a parked pack. --resume (env V_RESUME_PARKED=1) moves parked packs back into the
# queue at startup so THIS invocation re-attempts them; retry-continuity then adopts the dead prior worktree.
#   T1: --resume moves a parked pack .needs-review/ → queue root.
#   T2: default (no --resume) leaves the parked pack in .needs-review/ (opt-in; never silently re-wedges).
#   T3: collision — same-named pack already queued → parked copy is LEFT in place + reported, never clobbered.
set -u
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq"; exit 0; }
command -v claude >/dev/null 2>&1 || { echo "SKIP: claude CLI (preflight requires it for a non-dry run)"; exit 0; }
[ -f "$RUNNER" ] || { echo "SKIP: runner missing"; exit 0; }
G(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

mk_repo(){ # $1=root -> a git repo with packs/ containing .needs-review/parked.txt
  local R="$1/repo"
  mkdir -p "$R/packs/.needs-review"
  ( cd "$R" && git init -q -b main && echo x > f && G add -A && G commit -qm base ) >/dev/null 2>&1
  printf '/v close out the batch\n' > "$R/packs/.needs-review/w2-hardening.txt"
  printf '%s\n' "$R"
}

# Drive ONLY _preflight_and_dirs (which now performs the un-park) with the globals it reads.
drive(){ # $1=PACK_DIR $2=RESUME_PARKED -> stdout of _preflight_and_dirs
  bash -c '
    source "'"$RUNNER"'" >/dev/null 2>&1
    DRY=0; RESUME_PARKED="'"$2"'"; PACK_DIR="'"$1"'"
    _preflight_and_dirs 2>&1
  '
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ── T1: --resume un-parks ──
F1="$T/f1"; mkdir -p "$F1"; R1="$(mk_repo "$F1")"
OUT1="$(drive "$R1/packs" 1)"
if [ -f "$R1/packs/w2-hardening.txt" ] && [ ! -f "$R1/packs/.needs-review/w2-hardening.txt" ]; then
  ok "T1 --resume moved the parked pack back into the queue"
else
  no "T1 --resume did not un-park" "queue=$([ -f "$R1/packs/w2-hardening.txt" ] && echo yes || echo no) parked=$([ -f "$R1/packs/.needs-review/w2-hardening.txt" ] && echo yes || echo no) | $(printf '%s' "$OUT1" | grep -i resume | head -1)"
fi

# ── T2: default leaves it parked ──
F2="$T/f2"; mkdir -p "$F2"; R2="$(mk_repo "$F2")"
drive "$R2/packs" 0 >/dev/null 2>&1
if [ -f "$R2/packs/.needs-review/w2-hardening.txt" ] && [ ! -f "$R2/packs/w2-hardening.txt" ]; then
  ok "T2 default (no --resume) leaves the parked pack in .needs-review/ (opt-in only)"
else
  no "T2 default un-parked without opt-in" "queue=$([ -f "$R2/packs/w2-hardening.txt" ] && echo yes || echo no)"
fi

# ── T3: collision is not clobbered ──
F3="$T/f3"; mkdir -p "$F3"; R3="$(mk_repo "$F3")"
printf '/v ALREADY QUEUED COPY\n' > "$R3/packs/w2-hardening.txt"   # same name already in the queue
OUT3="$(drive "$R3/packs" 1)"
if [ -f "$R3/packs/.needs-review/w2-hardening.txt" ] \
   && grep -q 'ALREADY QUEUED COPY' "$R3/packs/w2-hardening.txt" \
   && printf '%s' "$OUT3" | grep -qi 'already present in the queue'; then
  ok "T3 name collision → parked copy left in place + reported, queued copy untouched"
else
  no "T3 collision mishandled" "$(printf '%s' "$OUT3" | grep -i resume | head -2 | tr '\n' '|')"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
