#!/usr/bin/env bash
# stop-rearm.sh — shared re-arm state machine for blocking Stop hooks (W5G-1).
#
# Problem (forensic 2026-06-06/07, three production sessions):
# every blocking Stop hook exited 0 unconditionally when stop_hook_active=true
# ("prevent infinite loop"). That made the entire gauntlet FIRST-STOP-ONLY: after
# one block, the model's remediation was never re-verified. Observed fallout:
#   - one session ended with a 600B PRE_FLIGHT_REPORT — below the very F8-b size
#     gate that had blocked it earlier the same turn-chain;
#   - two sessions ended with session-owned UNSTAGED code changes that
#     uncommitted-changes-gate exists to catch (fixes dangling on a
#     shared main for hours under 12-way session concurrency);
#   - a hand-padded gate artifact was never re-inspected.
#
# Design: blocking Stop hooks now RE-RUN their checks on active stops and keep
# blocking while the model is making progress. They escape (allow, loudly) only
# on a genuine deadlock:
#   - the SAME violation fingerprint seen more than REARM_MAX_SAME times in a
#     row (the model is not progressing; more blocks would loop forever), or
#   - more than REARM_MAX_TOTAL blocks in one continuous active chain (guards
#     against a changing-fingerprint loop).
# A natural stop (stop_hook_active=false) starts a fresh chain, so user
# intervention always resets the budget. State is per hook × SID under
# ~/.claude/runtime/stop-rearm/ and is cleared on a clean pass.
#
# bash 3.2 compatible. All state operations are best-effort: this lib must
# never crash the calling hook (callers run with `set +e` semantics but we do
# not rely on that).
#
# API:
#   rearm_init  <hook> <sid> <active>      — once per hook run, after SID known
#   rearm_gate  <hook> <sid> <active> <msg> — at each block site;
#                                             rc 0 = proceed to block
#                                             rc 1 = DEADLOCK ESCAPE (caller
#                                                    allows the stop; warning
#                                                    already printed to stderr)
#   rearm_clear <hook> <sid>               — on a clean pass
#   rearm_state_file <hook> <sid>          — path helper (read-only consumers)

_REARM_DIR="${CLAUDE_STOP_REARM_DIR:-$HOME/.claude/runtime/stop-rearm}"
# Escape on the (N+1)th consecutive IDENTICAL block; default: 2 identical blocks
# shown, third identical occurrence escapes.
_REARM_MAX_SAME="${STOP_REARM_MAX_SAME:-2}"
# Hard ceiling on blocks per continuous active chain (changing fingerprints).
_REARM_MAX_TOTAL="${STOP_REARM_MAX_TOTAL:-4}"
# SREV-001 (adversarial review 2026-06-07): FLOOR the caps at their defaults.
# Raw env values could be persisted into settings.json's env block (the same
# vector check-review-artifact already hardens IMPL_ONLY against) — with
# MAX_SAME=0 the FIRST active block would "deadlock-escape", silently disabling
# every re-armed Stop gate. Raising the caps is safe; lowering is not.
case "$_REARM_MAX_SAME"  in (''|*[!0-9]*) _REARM_MAX_SAME=2 ;; esac
case "$_REARM_MAX_TOTAL" in (''|*[!0-9]*) _REARM_MAX_TOTAL=4 ;; esac
[ "$_REARM_MAX_SAME"  -ge 2 ] 2>/dev/null || _REARM_MAX_SAME=2
[ "$_REARM_MAX_TOTAL" -ge 4 ] 2>/dev/null || _REARM_MAX_TOTAL=4

# === F8 — CROSS-CHAIN ESCAPE MEMORY (2026-08-29) ============================================
# The escape budget above is PER CHAIN, and the escape path deletes the chain state file (the
# `rm -f "$_sf"` at the end of the escape block). So the next Stop starts a fresh chain with
# _same=0 and the IDENTICAL violation consumes its full budget again — forever. Nothing carried
# across chains: the only cross-chain counter, `_esc_n`, feeds the marker's NARRATION and no
# decision at all.
#
# Measured: one executor session, one fingerprint, 13 escapes on ONE identical block
# message over more than two hours. Every row reads same=3 against
# _REARM_MAX_SAME=2, i.e. 39 blocks on the same message. chain_s: 12 12 13 20 21 23 24 24 25 26
# 69 85 436 — short chains, so the session was not idling; it was re-attempting the same failing
# remediation and getting re-blocked.
#
# This threshold does NOT change the escape decision (see rearm_gate: rc stays 1 on escape). It
# only adds a DURABLE marker + a distinct stderr line telling the orchestrator that repeating the
# current remediation is not working. Raising the escape budget, or converting a livelock into an
# infinite block, would both be strictly worse.
#
# FLOOR AT 2, same rationale as SREV-001 above: ordinary multi-artifact remediation legitimately
# escapes once or twice, so a value of 0/1 would fire the livelock marker on healthy sessions.
_REARM_MAX_ESCAPES_SAME_FP="${STOP_REARM_MAX_ESCAPES_SAME_FP:-3}"
case "$_REARM_MAX_ESCAPES_SAME_FP" in (''|*[!0-9]*) _REARM_MAX_ESCAPES_SAME_FP=3 ;; esac
[ "$_REARM_MAX_ESCAPES_SAME_FP" -ge 2 ] 2>/dev/null || _REARM_MAX_ESCAPES_SAME_FP=3

_rearm_fp() {
  # Fingerprint of the violation message. shasum ships with macOS + linux
  # coreutils setups; cksum is the POSIX fallback. Collisions only weaken the
  # dedup heuristic, never correctness.
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1"-"$2}'
  fi
}

rearm_state_file() {
  printf '%s/%s-%s.state\n' "$_REARM_DIR" "${1:-hook}" "${2:-nosid}"
}

rearm_init() {
  # $1 hook  $2 sid  $3 stop_hook_active ("true"/"false")
  mkdir -p "$_REARM_DIR" 2>/dev/null || true
  # GC stale state from long-dead sessions (best-effort).
  find "$_REARM_DIR" -name '*.state' -mtime +2 -delete 2>/dev/null || true
  if [ "${3:-false}" != "true" ]; then
    # Natural stop = new chain: forget any previous block cycle.
    rm -f "$(rearm_state_file "${1:-hook}" "${2:-nosid}")" 2>/dev/null || true
  fi
}

rearm_clear() {
  rm -f "$(rearm_state_file "${1:-hook}" "${2:-nosid}")" 2>/dev/null || true
}

rearm_gate() {
  # $1 hook  $2 sid  $3 active  $4 message
  # rc 0 → caller emits its block (state recorded)
  # rc 1 → deadlock escape: caller must allow the stop (exit 0)
  local _hook="${1:-hook}" _sid="${2:-nosid}" _active="${3:-false}" _msg="${4:-}"
  local _sf _fp _prev_fp="" _same=0 _total=0 _chain_start="" _had_state=0 _fp_escapes=0
  mkdir -p "$_REARM_DIR" 2>/dev/null || true
  _sf="$(rearm_state_file "$_hook" "$_sid")"
  _fp="$(_rearm_fp "$_msg")"
  if [ "$_active" = "true" ] && [ -f "$_sf" ]; then
    _had_state=1
    _prev_fp=$(sed -n '1p' "$_sf" 2>/dev/null)
    _same=$(sed -n '2p' "$_sf" 2>/dev/null)
    _total=$(sed -n '3p' "$_sf" 2>/dev/null)
    # === W-CHAIN-S (2026-08-10) — line 4: epoch this CHAIN began. OBSERVATIONAL ONLY. ===
    # Read HERE, in the outer active+exists guard, NOT in the fingerprint-match branch below.
    # `_total` increments unconditionally and is NOT reset when the fingerprint changes; only
    # `_same` is. Carrying chain-start next to `_same` (where "is this the same problem" logic
    # already lives) is the natural mistake and would silently decouple chain_s from the chain
    # `_total` actually counts — diverging on exactly the `total`-path escapes, which are
    # 172 of 627 (27.4%) of recorded history. Two independent reviewers caught this; the
    # 2026-08-09..10 sample contains ZERO total-path escapes, so testing could not have.
    _chain_start=$(sed -n '4p' "$_sf" 2>/dev/null)
    case "$_same" in (''|*[!0-9]*) _same=0 ;; esac
    case "$_total" in (''|*[!0-9]*) _total=0 ;; esac
    # DIGIT-ONLY GUARD BEFORE ANY ARITHMETIC — this is a safety control, not tidiness.
    # An invalid token in $(( )) is FATAL to bash (verified on system bash 3.2.57):
    # `x=1e10; y=$(( 10 - x ))` aborts, and `2>/dev/null || true` does NOT rescue it because
    # this is not a `set -e` effect. Inside this sourced function that abort makes rearm_gate
    # return 1 — which is the CALLER'S CONTRACT FOR "DEADLOCK ESCAPE, ALLOW THE STOP"
    # (check-review-artifact.sh:162-167 does `return $?`). So a malformed epoch would SILENTLY
    # OPEN THE STOP GATE with no escapes.log line, no artifact and no stderr: strictly worse
    # than an escape, and the exact silent-bypass shape W5G-1 exists to prevent. Reproduced.
    case "$_chain_start" in (''|*[!0-9]*) _chain_start="" ;; esac
  fi
  # Fresh chain (no state file at all) ⇒ stamp the start. A chain that HAD state but no line 4
  # (a pre-upgrade 3-line file — 6 existed on disk when this shipped) stays UNKNOWN and reports
  # no chain_s. Never fabricate `now` there: it would report ~0s for a chain already running.
  # `|| echo ''` deliberately, NOT this file's own `|| echo unknown` idiom two lines below —
  # bash resolves the bare word `unknown` as an unset variable = 0 inside $(( )), which yields a
  # silently wrong multi-billion-second chain_s instead of an omission. Also reproduced.
  if [ "$_had_state" -eq 0 ]; then
    _chain_start=$(date +%s 2>/dev/null || echo '')
    case "$_chain_start" in (''|*[!0-9]*) _chain_start="" ;; esac
  fi
  _total=$(( _total + 1 ))
  if [ -n "$_prev_fp" ] && [ "$_fp" = "$_prev_fp" ]; then
    _same=$(( _same + 1 ))
  else
    _same=1
  fi
  if [ "$_active" = "true" ]; then
    if [ "$_same" -gt "$_REARM_MAX_SAME" ] || [ "$_total" -gt "$_REARM_MAX_TOTAL" ]; then
      # Deadlock escape. Loud, durable, and chain-resetting (a later natural
      # stop starts a fresh budget).
      printf '[stop-rearm] GATE DEADLOCK ESCAPE (%s, sid=%s): the same gate blocked %s time(s) (%s total in this chain) without resolution — allowing the stop so the session does not loop forever. THE UNDERLYING VIOLATION IS STILL PRESENT and was NOT waived:\n%s\n' \
        "$_hook" "$_sid" "$_same" "$_total" "$_msg" >&2
      # W-CHAIN-S: wall-clock seconds this escaping chain has been running. Emitted as a trailing
      # field so the one existing consumer of this file (v-w5g-forensic-test.sh:89, which only
      # tests `[ -s ]` for non-emptiness) is unaffected; no parser in the tree splits these fields.
      #
      # UNINTERPRETED ON PURPOSE. It answers "how long was this chain?" and NOTHING else. Do not
      # read a short chain_s as "the session was merely waiting, so the escape was harmless" —
      # that is a conclusion, not a measurement, and at present n there is no evidence for it.
      # Do NOT gate on this value. It exists so a LATER decision can be made on real data, after
      # the mistake of predicting escape behaviour from a too-narrow model (2026-08-09) .
      #
      # KNOWN LIMITATION: a forward system-clock jump inflates chain_s undetectably — a large
      # positive value is indistinguishable from a genuinely long chain. Accepted; the failure
      # direction (overstating a non-blocking observational field) is benign.
      _chain_s="n/a"
      if [ -n "$_chain_start" ]; then
        _now_s=$(date +%s 2>/dev/null || echo '')
        case "$_now_s" in (''|*[!0-9]*) _now_s="" ;; esac
        if [ -n "$_now_s" ]; then
          _chain_s=$(( _now_s - _chain_start ))
          # Backward clock skew yields a valid-but-negative RESULT; the digit guard above
          # validates the stored operand, not the computed value. Omit rather than mislead.
          [ "$_chain_s" -lt 0 ] 2>/dev/null && _chain_s="n/a"
        fi
      fi
      printf '%s|%s|%s|same=%s|total=%s|fp=%s|chain_s=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$_hook" "$_sid" "$_same" "$_total" "$_fp" "$_chain_s" \
        >> "$_REARM_DIR/escapes.log" 2>/dev/null || true
      # F13: also write a DURABLE artifact into the repo's .v/artifacts so the escape is visible to
      # v-batch-health + the integrity sweep. escapes.log lives outside ARTIFACT_SEARCH_DIRS, so an
      # escape silently MASKED the real violation (a fleet session's W5F-3 bug read as "stopped clean").
      #
      # F4-item3 (2026-07-05): this used to resolve to the CURRENT worktree's own toplevel
      # (`git rev-parse --show-toplevel`) — for a session isolated in a `.worktrees/*` linked
      # worktree, that is a THROWAWAY directory. worktree-remove.sh's artifact-rescue only globs
      # maxdepth-1 *.md files at the worktree root, never descending into `.v/artifacts/`, so this
      # marker was silently destroyed the moment the worktree was cleaned up — never visible to a
      # FUTURE session in the shared main checkout, defeating the whole point of a "next-session-
      # visible debt marker". Resolve the SHARED main repo root via git-common-dir instead (its
      # parent is the main checkout regardless of which worktree this hook is running in — the
      # same convention worktree-safety.sh / v-drain-deferred-merges.sh already use for their own
      # cross-worktree artifact lookups). For an inline session on main this is unchanged (main's
      # own toplevel IS its git-common-dir's parent already).
      _sr_root=""
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        _sr_gcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
        case "$_sr_gcd" in
          /*) : ;;
          # F8-ROOT (2026-09-05, cohort forensic): a RELATIVE --git-common-dir is relative to the
          # CWD, not to the toplevel. Prefixing the toplevel turned "../../.git" (cwd two levels
          # below the checkout) into "<toplevel>/../../.git" → the marker + escape file were aimed at
          # the checkout's PARENT: STOP_REARM_ESCAPE files landed in a home-level and a parent-level
          # .v/artifacts (Jul–Aug), and in the 09-01..09-03 cohort one session
          # (cwd two levels below its checkout) escaped 4× on one fingerprint with NO livelock marker and no
          # stderr line — mkdir on a root-level `.v` path failed and the whole F8 block was skipped. Bite:
          # stop-rearm-livelock-test.sh case 7.
          ?*) _sr_gcd="$(pwd -P 2>/dev/null || pwd)/$_sr_gcd" ;;
          *) _sr_gcd="" ;;
        esac
        if [ -n "$_sr_gcd" ]; then
          _sr_root="$(cd "$(dirname "$_sr_gcd")" 2>/dev/null && pwd)"
        fi
        # Fall back to the worktree's own toplevel only if git-common-dir resolution somehow failed
        # (never worse than the pre-fix behavior).
        [ -n "$_sr_root" ] || _sr_root="$(git rev-parse --show-toplevel 2>/dev/null || echo '')"
      fi   # SREV-004: skip the write (not $HOME) when not in a work-tree
      if [ -n "$_sr_root" ] && mkdir -p "$_sr_root/.v/artifacts" 2>/dev/null; then
        {
          printf '# STOP_REARM_ESCAPE — %s\n\n' "$_sid"
          printf -- '- Hook: %s\n- Same-fingerprint blocks: %s\n- Total blocks this chain: %s\n- Fingerprint: %s\n- When: %s\n\n' \
            "$_hook" "$_same" "$_total" "$_fp" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
          # W-ESCAPE-COUNT (2026-08-10): this file is written with a TRUNCATING `>` — ONE file per
          # SID, overwritten on every escape. That is deliberate (marker-reconcile.sh:351 ages these
          # files and v-drain-deferred-merges.sh:182 does a per-SID `[ -f ]` check; both want exactly
          # one), but it makes the artifact a LOSSY frequency signal: one session had 24 lines in
          # escapes.log and 1 file on disk. Counting these FILES as an escape metric under-reports by
          # ~10x — an error made during the 2026-08-10 audit itself (reported 3 escapes where the log
          # showed 31). State the true count and name the authoritative source so the next reader
          # cannot repeat it. Best-effort: a failed/garbled count degrades to omitting the line,
          # never to printing a wrong number. `|| true` not `|| echo 0` — grep -c already prints 0 on
          # no-match and the echo would append a SECOND line.
          _esc_n=$(grep -c "|${_sid}|" "$_REARM_DIR/escapes.log" 2>/dev/null || true)
          case "$_esc_n" in (''|*[!0-9]*) _esc_n="" ;; esac
          [ -n "$_esc_n" ] && printf -- '- Escape #%s for this session. THIS FILE HOLDS ONLY THE LATEST (it is overwritten each time) — do NOT count these files as an escape frequency. Full history: %s\n\n' \
            "$_esc_n" "$_REARM_DIR/escapes.log"
          printf '%s\n\n%s\n' \
            "⚠️ The Stop gate escaped a deadlock (the SAME gate blocked repeatedly in one chain). THE VIOLATION BELOW WAS NOT WAIVED — it was still present at the instant this file was written. That is NOT the same as unresolved: RE-CHECK THE GATE before treating this as an open defect. (W-ESCAPE-ACCURACY, 2026-08-09: measured over the 2026-08-02..09 corpus, 17 of 17 escapes were followed by a successful attestation — shortest gap 53 seconds — because the deadlock budget, STOP_REARM_MAX_SAME=2, is consumed by ordinary multi-artifact remediation rather than by a stuck session. Before that window, escapes genuinely did precede non-attestation, which is why the wording was absolute.) If the artifacts and witness now validate, this record is history. If they do not, fix the root cause." \
            "$_msg"
        } > "$_sr_root/.v/artifacts/STOP_REARM_ESCAPE_${_sid}.md" 2>/dev/null || true
      fi

      # === F8 — CROSS-CHAIN LIVELOCK MARKER (2026-08-29) ==================================
      # Count THIS fingerprint's escapes for THIS session from escapes.log — deliberately NOT a
      # new state file: escapes.log is already append-only, per-SID, carries fp=, and (unlike the
      # chain state file deleted two lines below) SURVIVES the chain reset that hides this loop.
      # The current escape row was appended above, so the count already includes it: `>= N` means
      # "this is the Nth escape on the same message".
      #
      # `|| true`, NEVER `|| echo 0` — with a PRESENT file and no match, grep -c already prints 0
      # and exits 1, so `|| echo 0` would emit a SECOND line ("0\n0"). That is the exact trap the
      # W-ESCAPE-COUNT comment above documents. The digit guard then absorbs every degenerate
      # case (missing file → empty; multi-line → non-digit) to 0, so an unreadable escapes.log
      # yields no marker, no crash, and an UNCHANGED return code.
      _fp_escapes=$(grep -c "|${_sid}|.*|fp=${_fp}|" "$_REARM_DIR/escapes.log" 2>/dev/null || true)
      case "$_fp_escapes" in (''|*[!0-9]*) _fp_escapes=0 ;; esac
      if [ "$_fp_escapes" -ge "$_REARM_MAX_ESCAPES_SAME_FP" ] && [ -n "$_sr_root" ] \
         && mkdir -p "$_sr_root/.v/artifacts" 2>/dev/null; then
        {
          printf '# STOP_LIVELOCK — %s\n\n' "$_sid"
          printf -- '- Hook: %s\n- Fingerprint: %s\n- Escapes on THIS fingerprint: %s (threshold %s)\n- When: %s\n- Full history: %s\n\n' \
            "$_hook" "$_fp" "$_fp_escapes" "$_REARM_MAX_ESCAPES_SAME_FP" \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)" "$_REARM_DIR/escapes.log"
          printf '%s\n\n' "🔁 THE REMEDIATION BEING ATTEMPTED IS NOT RESOLVING THIS. The same gate has now deadlock-escaped ${_fp_escapes} separate times on the SAME violation message in this session. Each escape deletes the re-arm chain state, so the identical violation consumes a fresh block budget every time and this can repeat indefinitely (measured: 13 escapes = 39 blocks on one message over more than two hours). DO SOMETHING DIFFERENT: change the approach, or — if the obstacle is genuinely outside your control — write BLOCKED_${_sid}.md naming the SPECIFIC obstacle and stop retrying. Repeating the same fix is the one option now ruled out by evidence."
          printf '%s\n\n%s\n' "The violation still present at the moment this file was written:" "$_msg"
        } > "$_sr_root/.v/artifacts/STOP_LIVELOCK_${_sid}.md" 2>/dev/null || true
        # Distinct wording (not the GATE DEADLOCK ESCAPE line above) so the orchestrator can tell
        # "one escape happened" from "your remediation is looping".
        printf '[stop-rearm] STOP LIVELOCK (%s, sid=%s): this is escape #%s on the SAME violation fingerprint (%s) — the remediation you are repeating is NOT resolving it. Change approach, or write BLOCKED_%s.md naming the specific obstacle instead of retrying. Marker: %s\n' \
          "$_hook" "$_sid" "$_fp_escapes" "$_fp" "$_sid" "$_sr_root/.v/artifacts/STOP_LIVELOCK_${_sid}.md" >&2
      fi
      # === end F8 ==========================================================================

      rm -f "$_sf" 2>/dev/null || true
      # RETURN CODE CONTRACT UNCHANGED (see the API block at the top): rc 1 = deadlock escape,
      # caller allows the stop. F8 adds a marker + stderr and NOTHING else. Returning 0 here would
      # convert a livelock into an INFINITE BLOCK — strictly worse than the bug being fixed.
      return 1
    fi
  fi
  # W-CHAIN-S: FIELD ORDER IS LOAD-BEARING — line1 fp, line2 same, line3 total, line4 chain_start.
  # `_total` and an epoch are BOTH pure-digit strings, so a transposed argument here is INVISIBLE
  # to the `case ... *[!0-9]*` sanitizer above and corrupts the escape decision: an epoch landing
  # in the `_total` slot passes validation and trips `[ _total -gt 4 ]` on the very next read —
  # a false escape, i.e. it breaks the one thing this change promised not to touch. Reproduced.
  # Pinned by hooks/lib/stop-rearm-chain-duration-test.sh (asserts line 3 stays small and line 4
  # is a plausible epoch), so a future edit cannot silently swap them.
  printf '%s\n%s\n%s\n%s\n' "$_fp" "$_same" "$_total" "$_chain_start" > "$_sf" 2>/dev/null || true
  return 0
}
