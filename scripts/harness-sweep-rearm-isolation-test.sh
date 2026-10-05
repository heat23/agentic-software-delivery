#!/usr/bin/env bash
# harness-sweep-rearm-isolation-test.sh
# Version: 1.0.0 (W-SWEEP-ISO, 2026-08-11)
#
# Guards the per-job `CLAUDE_STOP_REARM_DIR` isolation in harness-test-sweep.sh's `_run_one`.
#
# WHY. `hooks/lib/stop-rearm.sh:40` defaults its state dir to `$HOME/.claude/runtime/stop-rearm` —
# a fixed ABSOLUTE path, unlike the rest of this corpus which scopes fixtures under a mktemp'd repo.
# Three harnesses drive a rearm-using hook against the REAL $HOME with a fixed synthetic SID
# (orch-hardening-2026-06-23, uncommitted-changes-gate, dead-hook-session-scope), so they wrote into
# the operator's live runtime dir (stray files were observed there on 2026-08-11).
#
# HONEST SCOPE — PREVENTIVE, not a fix for observed flakiness. A 3-lens panel established that no
# CURRENT harness can flake from this: all three writers pass `stop_hook_active:false`, and
# rearm_gate gates its read/increment behind `active=true` (stop-rearm.sh:97), so they only clobber,
# never read a sibling's file. Synthetic SIDs also cannot collide with real session UUIDs. What the
# isolation closes is the LATENT case (a future harness using active=true with a shared SID) plus
# the production pollution itself. This harness guards that the isolation stays in place.
#
# THE MUTANT THIS MUST KILL. A naive assertion "CLAUDE_STOP_REARM_DIR is set" passes for an
# implementation that sets it to one CONSTANT for every job — which still shares one directory and
# fixes nothing. So the oracle below runs TWO harnesses concurrently through the real sweep and
# asserts each sees a dir no sibling wrote to. A constant-valued mutant still collides and stays RED.
#
# Exit: 0 = all pass, 1 = any fail.

set -uo pipefail
SWEEP="${SWEEP_UNDER_TEST:-$HOME/.claude/scripts/harness-test-sweep.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
[ -r "$SWEEP" ] || { echo "FAIL: sweep not found at $SWEEP"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT
FIX="$WORK/fixtures"; mkdir -p "$FIX"

echo "== W-SWEEP-ISO :: each sweep job gets its own stop-rearm dir =="

# Two fixture harnesses that both write into $CLAUDE_STOP_REARM_DIR and then check whether anyone
# else wrote there. Two sleeps guarantee the windows overlap, so this is deterministic rather than
# a hopeful race: both writes land before either read-back.
for n in a b; do
  cat > "$FIX/race-$n-test.sh" <<'EOF'
#!/usr/bin/env bash
D="${CLAUDE_STOP_REARM_DIR:-}"
[ -n "$D" ] || { echo "UNSET: sweep did not provide CLAUDE_STOP_REARM_DIR"; exit 1; }
mkdir -p "$D" 2>/dev/null || true
sleep 0.3
printf '%s\n' "$(basename "$0")" >> "$D/claim"
sleep 0.3
distinct=$(sort -u "$D/claim" 2>/dev/null | grep -c . || true)
[ "${distinct:-0}" -eq 1 ] || { echo "COLLISION: $(tr '\n' ' ' < "$D/claim")"; exit 1; }
EOF
  chmod +x "$FIX/race-$n-test.sh"
done

# Pre-set a SHARED dir before invoking the sweep. This reproduces exactly what the pre-fix
# `_run_one` left in place (it never touched the variable, so every job inherited one value).
# A correct implementation overrides this per job; the old one does not.
SHARED="$WORK/shared"; mkdir -p "$SHARED"
out=$(CLAUDE_STOP_REARM_DIR="$SHARED" HARNESS_SWEEP_JOBS=2 bash "$SWEEP" "$FIX" 2>&1); rc=$?

if printf '%s' "$out" | grep -q '2 passed, 0 failed'; then
  ok "both concurrent jobs saw a private stop-rearm dir (sweep rc=$rc)"
else
  no "jobs collided or did not run" "$(printf '%s' "$out" | tail -4)"
fi

# The shared dir handed in must stay untouched — proof the override actually happened rather
# than the jobs merely succeeding for some other reason.
if [ ! -e "$SHARED/claim" ]; then
  ok "the inherited shared dir was NOT written to (override is real, not incidental)"
else
  no "a job wrote into the inherited shared dir" "$(cat "$SHARED/claim" 2>/dev/null | tr '\n' ' ')"
fi

# --- mutation check: prove this oracle can actually fail --------------------------------------
# Build a mutant sweep whose _run_one sets the var to a CONSTANT (the shape a naive
# "is it set?" assertion would wrongly accept). The two jobs must then collide.
MUT="$WORK/mutant-sweep.sh"
sed 's|CLAUDE_STOP_REARM_DIR="\$RESDIR/rearm\.\$idx"|CLAUDE_STOP_REARM_DIR="$RESDIR/rearm.CONST"|' "$SWEEP" > "$MUT"
if ! grep -q 'rearm.CONST' "$MUT"; then
  no "mutation check could not be built" "the isolation line did not match the expected shape"
else
  mout=$(HARNESS_SWEEP_JOBS=2 bash "$MUT" "$FIX" 2>&1) || true
  if printf '%s' "$mout" | grep -q '2 passed, 0 failed'; then
    no "mutation check FAILED — a constant-valued dir still passed" "this oracle is vacuous"
  else
    ok "mutation check: a CONSTANT dir collides and is rejected (oracle is live)"
  fi
fi

printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
