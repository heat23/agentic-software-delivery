#!/usr/bin/env bash
# v-run-waves.sh — batch-drive /v over a directory of wave/prompt .txt files, ONE FRESH
# `claude --print` session per prompt (fresh context each → the session-hygiene token win),
# waves SEQUENTIAL, prompts within a wave BOUNDED-PARALLEL, RESUMABLE.
#
# WHY a driver and not a skill: a skill runs in ONE session and cannot respawn itself, so looping
# prompts inside a skill accumulates every prompt's context (the quadratic cache_read blowup). A
# fresh session per prompt REQUIRES an external process loop — this script. Each prompt becomes its
# own `claude --print "/v <prompt>"` invocation = fresh context. /v's own worktree+lock machinery
# isolates concurrent same-repo sessions (each gets a worktree; merge-back is lock-serialized), so
# within-wave parallelism is SAFE for correctness — but keep --concurrency MODEST: each /v session
# is heavy (full suite + build + sub-agents, already internally multi-core), so 2–3 saturates a box.
#
# STATUS (2026-07-02): SECONDARY runner. `run-v-packs` is the CANONICAL pack runner and has a STRONGER
# completion gate — it archives a pack only on GAUNTLET_ATTESTED / self-check PASS, whereas this script marks a
# prompt `.done` on a bare successful `claude --print` exit (NO gauntlet attestation). Prefer run-v-packs unless
# you specifically need this script's fresh-context-per-prompt external loop; treat a `.done` here as "ran",
# NOT "gauntlet-verified".
#
# Layout:  <waves-dir>/<wave-NN>/<NN-name>.txt   (waves = sorted subdirs, prompts = sorted *.txt).
#          If <waves-dir> has NO subdirs, it is treated as a single wave of its *.txt files.
#          Zero-pad names (wave-01, 01-foo.txt) so lexical sort = intended order.
#
# Usage:
#   v-run-waves.sh <waves-dir> [options]
#     --repo <path>      repo to run /v in (default: $PWD)
#     --concurrency N    max parallel sessions per wave (default: cores-aware, modest 1–4)
#     --prefix STR       prepended to each prompt (default: "/v "); use --prefix "" if files already start with /v
#     --model M          model for every spawned session (default: env V_WAVES_MODEL, else sonnet).
#                        ND-0716: a bare `claude --print` reads the GLOBAL settings.json default
#                        (the operator's /model choice — possibly fable[1m], which refuses the /v
#                        role and no-ops), NOT the invoking session's model. So the driver ALWAYS
#                        pins a model. Values pass the sonnet-max allowlist (sonnet|haiku;
#                        V_MODEL_POLICY_OVERRIDE=1 for an explicit operator exception). If
#                        CLAUDE_FLAGS already carries --model, the driver does not add its own.
#     --dry-run          enumerate + show order/skip-state; launch nothing (verify BEFORE 100 heavy runs)
#     --force            ignore .done markers (re-run everything)
#     --stop-on-fail     stop the whole run on first failure (default: skip-and-continue)
#     --logs <dir>       per-prompt logs (default: <waves-dir>/.v-run-waves-logs/<runid>)
#     --timeout SECS     kill a session (SIGTERM, then SIGKILL after 5s grace) if it exceeds SECS
#                        wall-clock; 0/absent = no timeout (default — unchanged prior behavior).
#                        OPT-IN ONLY: a blunt default timeout previously caused a watchdog to kill
#                        PASSING long-running gauntlets in this ecosystem (see run-v-packs history),
#                        so this driver never enforces one unless the operator asks. Uses a portable
#                        sleep+kill watcher, not the `timeout`/`gtimeout` binaries (absent on macOS
#                        by default). A killed session is marked failed (no .done) like any other.
#   env: CLAUDE_BIN (default: claude), CLAUDE_FLAGS (extra flags, e.g. --dangerously-skip-permissions),
#        V_WAVES_TIMEOUT (default for --timeout when the flag is omitted)
#
# Resumable: a prompt that exits 0 writes <prompt>.done; re-running SKIPS done prompts (--force overrides).
# Exit: 0 = all attempted prompts passed (or all skipped); 1 = a prompt failed; 2 = usage/setup error.
set -uo pipefail

WAVES_DIR=""; REPO="$PWD"; CONCURRENCY=""; PREFIX="/v "; DRY_RUN=0; FORCE=0; STOP_ON_FAIL=0; LOGS=""; MODEL=""; TIMEOUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo needs a path}"; shift 2;;
    --concurrency) CONCURRENCY="${2:?--concurrency needs N}"; shift 2;;
    --model) MODEL="${2:?--model needs a value}"; shift 2;;
    --prefix) PREFIX="${2-}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    --stop-on-fail) STOP_ON_FAIL=1; shift;;
    --logs) LOGS="${2:?--logs needs a dir}"; shift 2;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2;;
    -h|--help) sed -n '2,51p' "$0"; exit 0;;
    -*) echo "v-run-waves: unknown option: $1" >&2; exit 2;;
    *) if [ -z "$WAVES_DIR" ]; then WAVES_DIR="$1"; else echo "v-run-waves: unexpected arg: $1" >&2; exit 2; fi; shift;;
  esac
done
[ -n "$WAVES_DIR" ] && [ -d "$WAVES_DIR" ] || { echo "v-run-waves: usage: v-run-waves.sh <waves-dir> [options]  (see --help)" >&2; exit 2; }
WAVES_DIR="${WAVES_DIR%/}"

CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CLAUDE_FLAGS="${CLAUDE_FLAGS:-}"

# ── ND-0716 model pin (parity with run-v-packs' PACK_MODEL) ──────────────────
# Default sonnet; validate through the CANONICAL sonnet-max allowlist (single source:
# the ND-MODEL-POLICY block in v-dispatch-subagent.sh) with a conservative inline
# fallback if that block is unavailable. CLAUDE_FLAGS-supplied --model (operator
# explicit) suppresses the driver's own pin unless --model was ALSO passed here.
MODEL_EXPLICIT=0; [ -n "$MODEL" ] && MODEL_EXPLICIT=1
MODEL="${MODEL:-${V_WAVES_MODEL:-sonnet}}"
if [ "$MODEL_EXPLICIT" -eq 0 ]; then
  case " $CLAUDE_FLAGS " in *" --model "*) MODEL="";; esac
fi
if [ -n "$MODEL" ]; then
  _POLICY_SRC="${V_DISPATCH_SUBAGENT_SCRIPT:-$HOME/.claude/skills/v/references/v-dispatch-subagent.sh}"
  [ -f "$_POLICY_SRC" ] && eval "$(sed -n '/# === ND-MODEL-POLICY/,/# === end ND-MODEL-POLICY ===/p' "$_POLICY_SRC" 2>/dev/null)"
  if ! type enforce_model_policy >/dev/null 2>&1; then
    enforce_model_policy() {  # conservative fallback — exact aliases only
      case "${1:-}" in ""|sonnet|haiku) return 0;; esac
      [ "${V_MODEL_POLICY_OVERRIDE:-0}" = "1" ] && { echo "v-run-waves: NOTICE — model '$1' allowed via V_MODEL_POLICY_OVERRIDE=1 (operator lane)" >&2; return 0; }
      echo "v-run-waves: ERROR — model '$1' rejected (sonnet-max policy; canonical policy block unavailable, conservative fallback active). Use sonnet|haiku or V_MODEL_POLICY_OVERRIDE=1." >&2
      return 2
    }
  fi
  enforce_model_policy "$MODEL" "v-run-waves --model" || exit 2
  CLAUDE_FLAGS="$CLAUDE_FLAGS --model $MODEL"
fi

if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "v-run-waves: '$CLAUDE_BIN' not found in PATH (set CLAUDE_BIN, or use --dry-run)" >&2; exit 2; }
fi
[ -d "$REPO" ] || { echo "v-run-waves: --repo is not a directory: $REPO" >&2; exit 2; }

# cores-aware default concurrency (MODEST — each /v session is heavy + internally parallel)
if [ -z "$CONCURRENCY" ]; then
  _ncpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  CONCURRENCY=$(( _ncpu / 6 )); [ "$CONCURRENCY" -lt 1 ] && CONCURRENCY=1; [ "$CONCURRENCY" -gt 4 ] && CONCURRENCY=4
fi
case "$CONCURRENCY" in ''|*[!0-9]*) echo "v-run-waves: --concurrency must be a positive integer" >&2; exit 2;; esac
[ "$CONCURRENCY" -ge 1 ] || CONCURRENCY=1

# --timeout: OPT-IN only (default 0 = disabled, unchanged prior behavior — see header doc).
TIMEOUT="${TIMEOUT:-${V_WAVES_TIMEOUT:-0}}"
case "$TIMEOUT" in ''|*[!0-9]*) echo "v-run-waves: --timeout must be a non-negative integer (seconds)" >&2; exit 2;; esac

RUNID="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
[ -n "$LOGS" ] || LOGS="$WAVES_DIR/.v-run-waves-logs/$RUNID"
[ "$DRY_RUN" -eq 0 ] && mkdir -p "$LOGS"

# discover waves (sorted subdirs; else the dir itself as a single wave)
WAVES=(); _have_subdir=0
for d in "$WAVES_DIR"/*/; do [ -d "$d" ] && { _have_subdir=1; break; }; done
if [ "$_have_subdir" -eq 1 ]; then
  while IFS= read -r d; do WAVES+=("$d"); done < <(find "$WAVES_DIR" -mindepth 1 -maxdepth 1 -type d -not -name '.*' | LC_ALL=C sort)
else
  WAVES=("$WAVES_DIR")
fi
[ "${#WAVES[@]}" -gt 0 ] || { echo "v-run-waves: no waves found under $WAVES_DIR" >&2; exit 2; }

PASSED=0; FAILED=0; SKIPPED=0; FAILED_LIST=""; STOP=0
_dry=""; [ "$DRY_RUN" -eq 1 ] && _dry=" | DRY-RUN"
rel() { printf '%s' "${1#"$WAVES_DIR"/}"; }

trap 'echo "" >&2; echo "v-run-waves: interrupted — killing in-flight sessions" >&2; kill $(jobs -p) 2>/dev/null || true; exit 130' INT TERM

b_pids=(); b_prompts=(); b_logs=(); b_watchdogs=()
reap_batch() {
  [ "${#b_pids[@]}" -gt 0 ] || return 0
  local i pid prompt rc wpid
  for i in "${!b_pids[@]}"; do
    pid="${b_pids[$i]}"; prompt="${b_prompts[$i]}"; wpid="${b_watchdogs[$i]:-}"
    if wait "$pid"; then
      touch "$prompt.done" 2>/dev/null || true
      PASSED=$((PASSED+1)); echo "  ✅ $(rel "$prompt")"
    else
      rc=$?
      FAILED=$((FAILED+1)); FAILED_LIST="$FAILED_LIST
    $(rel "$prompt")  (log: ${b_logs[$i]})"
      echo "  ❌ $(rel "$prompt")  (exit $rc; log: ${b_logs[$i]})"
      [ "$STOP_ON_FAIL" -eq 1 ] && STOP=1
    fi
    # Job finished (pass or fail) — the timeout watchdog (if any) is no longer needed. Kill it
    # before it fires late and reap it so it never lingers as an orphaned sleep.
    if [ -n "$wpid" ]; then kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; fi
  done
  b_pids=(); b_prompts=(); b_logs=(); b_watchdogs=()
}
launch() {
  local prompt="$1" log="$2" mpid wpid=""
  ( cd "$REPO" && exec "$CLAUDE_BIN" $CLAUDE_FLAGS --print "$PREFIX$(cat "$prompt")" ) >"$log" 2>"$log.err" &
  mpid=$!
  if [ "$TIMEOUT" -gt 0 ]; then
    # Portable timeout (no `timeout`/`gtimeout` dependency — absent on macOS by default):
    # a background watcher sleeps TIMEOUT seconds, then SIGTERMs the session if still alive,
    # then SIGKILLs after a 5s grace period. reap_batch kills this watcher once the main job
    # is reaped, so a fast-finishing job never waits out the full timeout window.
    #
    # IMPORTANT — redirect the whole subshell's stdout/stderr to the log file (not inherited):
    # without this, the watchdog (and its own `sleep 5` grace-period child) inherit the
    # DRIVER's original stdout/stderr. If the caller captures this script's output via
    # `$(...)` or pipes it (`| tee`), that's a pipe — and a pipe only reports EOF once every
    # fd referencing its write end is closed. Killing the watchdog after the main job dies
    # does NOT kill its already-forked `sleep 5` child (kill signals one pid, not its
    # descendants); that orphaned child would keep the pipe open for up to 5 more seconds
    # after the real work finished, stalling any caller capturing/piping this script's output.
    ( sleep "$TIMEOUT"
      if kill -0 "$mpid" 2>/dev/null; then
        echo "v-run-waves: TIMEOUT after ${TIMEOUT}s — sending SIGTERM to $mpid"
        kill -TERM "$mpid" 2>/dev/null
        sleep 5
        if kill -0 "$mpid" 2>/dev/null; then
          echo "v-run-waves: still alive after SIGTERM grace — sending SIGKILL to $mpid"
          kill -KILL "$mpid" 2>/dev/null
        fi
      fi
    ) >>"$log.err" 2>&1 <&- & wpid=$!
  fi
  b_pids+=("$mpid"); b_prompts+=("$prompt"); b_logs+=("$log"); b_watchdogs+=("$wpid")
}

_timeout_note="none"; [ "$TIMEOUT" -gt 0 ] && _timeout_note="${TIMEOUT}s"
echo "v-run-waves: ${#WAVES[@]} wave(s) under $WAVES_DIR | repo=$REPO | concurrency=$CONCURRENCY | model=${MODEL:-<CLAUDE_FLAGS-supplied>} | prefix='$PREFIX' | timeout=$_timeout_note$_dry"

for wave in "${WAVES[@]}"; do
  [ "$STOP" -eq 1 ] && break
  wave="${wave%/}"
  wname="$(rel "$wave")"; [ "$wname" = "$WAVES_DIR" ] && wname="(root)"
  PROMPTS=()
  while IFS= read -r p; do PROMPTS+=("$p"); done < <(find "$wave" -mindepth 1 -maxdepth 1 -type f -name '*.txt' -not -name '.*' | LC_ALL=C sort)
  echo ""
  echo "── wave: $wname  (${#PROMPTS[@]} prompt(s)) ─────────────────"
  [ "${#PROMPTS[@]}" -gt 0 ] || { echo "  (no .txt prompts)"; continue; }
  for prompt in "${PROMPTS[@]}"; do
    [ "$STOP" -eq 1 ] && break
    if [ "$FORCE" -eq 0 ] && [ -f "$prompt.done" ]; then
      SKIPPED=$((SKIPPED+1)); echo "  ⏭  $(rel "$prompt")  (done — skip)"; continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  ▶  $(rel "$prompt")  →  $CLAUDE_BIN --print \"${PREFIX}<contents>\""; continue
    fi
    log="$LOGS/$(printf '%s' "$wname/$(basename "$prompt")" | tr '/ ' '__').log"
    launch "$prompt" "$log"
    [ "${#b_pids[@]}" -ge "$CONCURRENCY" ] && reap_batch
  done
  reap_batch   # wave barrier — finish every prompt in this wave before the next wave starts
done

echo ""
echo "═══ v-run-waves summary ═══"
echo "  passed=$PASSED  failed=$FAILED  skipped=$SKIPPED  (concurrency=$CONCURRENCY)"
if [ "$DRY_RUN" -eq 1 ]; then echo "  (dry-run — nothing launched)"; exit 0; fi
[ -n "$FAILED_LIST" ] && printf '  failed prompts:%s\n' "$FAILED_LIST"
echo "  logs: $LOGS"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
