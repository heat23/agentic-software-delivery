#!/usr/bin/env bash
# session-lock-format-test.sh — F3-item1/item2 (2026-07-05).
#
# F3-item1 ("locks must be written as SID PID EPOCH"): audited every current lock-writer in the
# ecosystem (worktree-create.sh, worktree-lifecycle.sh, v-worktree-adopt-or-create.sh) and found
# ALL THREE already emit the canonical positional 3-field "SID PID EPOCH" shape (established by the
# 2026-07-02 H-3 forensic fix, well before this session). No writer needed a code change. This test
# is a STATIC regression net so a future writer can't silently regress back to a 2-field/keyless
# shape: it greps every real writer site for the 3-token `printf`/`echo ... > .claude-session-lock`
# pattern.
#
# F3-item2 ("drain must treat a PID-less lock as stale-after-grace, gated by kill -0, not either
# alone"): functionally exercises hooks/lib/session-lock-parse.sh's `lock_alive()` — a lock with NO
# resolvable pid (legacy 2-field "SID EPOCH", or an unparseable line) must be ALIVE while young
# (grace period) and DEAD once older than dead_age_min (age alone is not "eternally valid"); a lock
# with a RESOLVABLE-but-dead pid must not be revived by a merely-fresh mtime (kill -0 is not
# ignored just because age looks generous) unless a live transcript backs it.
#
# Bite (item2 regression): if lock_alive() is edited to declare EVERY lock ALIVE unconditionally
# (or DEAD unconditionally), several assertions below flip.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LOCKLIB="${V_LOCKLIB_OVERRIDE:-$HERE/session-lock-parse.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s -- %s\n' "$1" "${2:-}"; }

echo "== item1 :: every real lock-writer emits 3-field 'SID PID EPOCH' =="
bash -n "$LOCKLIB" && ok "session-lock-parse.sh parses (bash -n)" || no "syntax error in $LOCKLIB"

# Enumerate every NON-backup, NON-test script that writes .claude-session-lock, and assert its
# write statement produces THREE space-separated tokens (grep-shape check on the literal
# printf/echo template — not a full interpreter, but catches a 2-field or key=value regression).
_writers=$(grep -rlE '(>[[:space:]]*"[^"]*\.claude-session-lock"|mv[^|]*\.claude-session-lock")' "$ROOT/hooks" "$ROOT/skills/v/references" --include='*.sh' 2>/dev/null \
  | grep -v '\.pre-\|\.bak\|-test\.sh\|\.attic' \
  | grep -v '/worktree-safety\.sh$' || true)   # worktree-safety.sh only renames a CORRUPT lock aside — it never establishes/writes the canonical format, so it is not an audit target here.
[ -n "$_writers" ] && ok "found >=1 lock-writer script to audit ($(printf '%s\n' "$_writers" | grep -c .) files)" \
  || no "no lock-writer scripts found — the audit glob may be stale" ""
_bad=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  # Every write line ends in `> .../.claude-session-lock` (direct) or via a `mv $TMP .../.claude-session-lock`
  # staged-write (worktree-create.sh/worktree-lifecycle.sh's atomic-write pattern), fed by a printf/echo whose
  # FORMAT/args produce 3 tokens. Accept either: (a) a printf with a 3-token '%s %s %s' format string, or
  # (b) an echo whose argument string is "$SID <space> ${PID-ish} <space> $(date ...)" shaped.
  if ! grep -E '(printf[^|]*%s[^|]*%s[^|]*%s|echo[[:space:]]+"\$[A-Za-z_]+[^"]*[[:space:]]\$\{?[A-Za-z0-9_:!.$-]*\}?[^"]*\$\(date)' "$_f" >/dev/null 2>&1; then
    _bad="$_bad $_f"
  fi
done <<< "$_writers"
if [ -z "$_bad" ]; then
  ok "every audited lock-writer's write statement is 3-field-shaped (SID PID EPOCH)"
else
  no "lock-writer(s) NOT 3-field-shaped -- possible format regression" "$_bad"
fi

echo "== item2 :: PID-less lock is stale-after-grace (kill -0 gated, not age alone) =="
TH=$(mktemp -d); trap 'rm -rf "$TH"' EXIT
mkdir -p "$TH/.claude/projects/p"

_run() {  # sources $LOCKLIB in a subshell scoped to $TH, prints A/B/C/D=ALIVE|DEAD
  ( CLAUDE_CONFIG_DIR="$TH/.claude"
    # shellcheck disable=SC1090
    . "$LOCKLIB"

    # A: PID-less 2-field "SID EPOCH" lock, FRESH (epoch = now) -> must be ALIVE (grace covers it).
    SID_A="11111111-1111-4111-8111-111111111111"
    printf '%s %s\n' "$SID_A" "$(date +%s)" > "$TH/lock-a"
    lock_alive "$TH/lock-a" 60 && echo "A=ALIVE" || echo "A=DEAD"

    # B: same PID-less shape, but epoch is far in the past (well beyond the 60-min dead_age_min
    # passed here) -> must be DEAD (age alone is not "eternally valid" -- the grace period expires).
    printf '%s %s\n' "$SID_A" "$(( $(date +%s) - 7200 ))" > "$TH/lock-b"
    lock_alive "$TH/lock-b" 60 && echo "B=ALIVE" || echo "B=DEAD"

    # C: RESOLVABLE pid that is definitively DEAD (fork+reap), lock mtime FRESH, NO transcript for
    # the sid -> must be DEAD (a fresh mtime alone must not revive a provably-dead pid -- kill -0 is
    # the authority once resolvable, corroborated only by transcript liveness, never bare age).
    ( exit 0 ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true
    printf '%s %s %s\n' "$SID_A" "$DEAD_PID" "$(date +%s)" > "$TH/lock-c"
    lock_alive "$TH/lock-c" 60 && echo "C=ALIVE" || echo "C=DEAD"

    # D: same dead pid, but a LIVE transcript for the sid exists -> must be ALIVE (transcript
    # liveness is a real, independent corroborating signal -- not "either kill-0 or age alone").
    : > "$TH/.claude/projects/p/${SID_A}.jsonl"
    lock_alive "$TH/lock-c" 60 && echo "D=ALIVE" || echo "D=DEAD"
  )
}

OUT="$(_run)"
printf '%s\n' "$OUT" | grep -q '^A=ALIVE$' \
  && ok "PID-less + fresh epoch -> ALIVE (grace period covers a just-written lock)" \
  || no "PID-less + fresh epoch should be ALIVE" "$OUT"
printf '%s\n' "$OUT" | grep -q '^B=DEAD$' \
  && ok "PID-less + epoch past dead_age_min -> DEAD (not treated as eternally valid)" \
  || no "PID-less + old epoch should be DEAD" "$OUT"
printf '%s\n' "$OUT" | grep -q '^C=DEAD$' \
  && ok "resolvable dead pid + fresh mtime + no transcript -> DEAD (kill -0 not overridden by bare age)" \
  || no "resolvable dead pid with no transcript should be DEAD" "$OUT"
printf '%s\n' "$OUT" | grep -q '^D=ALIVE$' \
  && ok "resolvable dead pid + LIVE transcript -> ALIVE (liveness check, not kill -0 alone)" \
  || no "dead pid + live transcript should be ALIVE (transcript corroboration)" "$OUT"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
