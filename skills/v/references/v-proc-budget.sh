#!/usr/bin/env bash
# v-proc-budget.sh — resolve a core/concurrency-aware paratest `--processes` budget.
#
# WHY: /v runs MANY concurrent sessions on one machine. A naive `pest --parallel`
# defaults to (logical-core-count) workers PER session → K sessions × cores → CPU
# oversubscription → the whole machine goes sluggish (owner report 2026-05-29 on a
# multi-core laptop). This helper bounds parallelism for the two
# regimes /v actually has:
#
#   V_PEST_PROCESSES_SCOPED — the SMALL per-session scoped runs that fire CONCURRENTLY
#       across sessions (Step-3.x pre-flight). Sized so (expected concurrency) × SCOPED
#       stays within the performance cores.
#   V_PEST_PROCESSES_FULL   — the HEAVY full suite, which runs SERIALIZED under the
#       cross-session suite lock (v-suite-lock.sh — only one at a time machine-/repo-wide),
#       so it gets more headroom.
#
# Pure resolver: sourcing it only EXPORTS those two vars (idempotent; no other effects).
# Every input is overridable via env so it is deterministic + unit-testable:
#   V_PEST_FORCE_CORES         — pretend this many performance cores (tests / odd hardware)
#   V_EXPECTED_SESSIONS        — how many /v sessions you expect to run at once (default 4)
#   V_PEST_PROCESSES           — hard override for BOTH budgets (you pick the number)
#   V_PEST_PROCESSES_SCOPED    — hard override for the scoped budget only
#   V_PEST_PROCESSES_FULL      — hard override for the full budget only
#   PARALLEL_SESSIONS_DETECTED=true — shrink the scoped budget one notch (live contention)
#   V_PROC_BUDGET_NO_AUTO=1    — source the functions WITHOUT auto-resolving (for tests)
#
# Caps: SCOPED ∈ [2,4], FULL ∈ [2,6]. Neither ever exceeds the performance-core count.

# --- performance-core detection (darwin → linux → portable fallback) ---
_vpb_perf_cores() {
  if [ -n "${V_PEST_FORCE_CORES:-}" ]; then printf '%s\n' "$V_PEST_FORCE_CORES"; return; fi
  local n=""
  # macOS: PERFORMANCE cores only — paratest workers pinned to efficiency cores are
  # slow yet still steal scheduler slots, so size to P-cores. Fall back to all physical.
  if command -v sysctl >/dev/null 2>&1; then
    n=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)
    [ -n "$n" ] || n=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
    [ -n "$n" ] || n=$(sysctl -n hw.ncpu 2>/dev/null || true)
  fi
  [ -n "$n" ] || { command -v nproc >/dev/null 2>&1 && n=$(nproc 2>/dev/null || true); }
  [ -n "$n" ] || n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=4 ;; esac   # last-ditch sane default
  printf '%s\n' "$n"
}

_vpb_clamp() {  # _vpb_clamp value lo hi
  local v="$1" lo="$2" hi="$3"
  case "$v" in ''|*[!0-9]*) v="$lo" ;; esac
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  printf '%s\n' "$v"
}

vpb_resolve() {
  local cores conc scoped full
  cores=$(_vpb_perf_cores)
  case "$cores" in ''|*[!0-9]*) cores=4 ;; esac
  [ "$cores" -lt 1 ] && cores=1

  conc="${V_EXPECTED_SESSIONS:-4}"
  case "$conc" in ''|*[!0-9]*) conc=4 ;; esac
  [ "$conc" -lt 1 ] && conc=1

  # SCOPED: share the performance cores across the sessions you expect at once.
  scoped=$(( cores / conc ))
  [ "$scoped" -lt 1 ] && scoped=1
  scoped=$(_vpb_clamp "$scoped" 2 4)
  # Never let the scoped cap exceed the cores themselves (tiny machines).
  [ "$scoped" -gt "$cores" ] && scoped="$cores"
  # Live contention signal → drop one notch BELOW the clamped value (the resolver's
  # only dynamic feedback). Applied after the clamp so the reduction is real, not
  # absorbed by it; floored at 2 so a scoped run always keeps ≥2 workers.
  # Accept BOTH conventions (QA-F4): bootstrap emits PARALLEL_SESSIONS_DETECTED=1 (numeric flag) while the
  # gather + docs use "true" — a "true"-only check silently ignored the live-contention signal, so this
  # burn-reducing throttle never fired under a parallel fleet (its designed scenario).
  if { [ "${PARALLEL_SESSIONS_DETECTED:-false}" = "true" ] || [ "${PARALLEL_SESSIONS_DETECTED:-}" = "1" ]; } && [ "$scoped" -gt 2 ]; then
    scoped=$(( scoped - 1 ))
  fi

  # FULL: serialized under the suite lock → most P-cores, but leave 2 for the
  # orchestrator + any concurrent scoped run, and cap at 6 (beyond that, paratest
  # worker boot + per-worker SQLite DB setup dominate; diminishing returns).
  full=$(( cores - 2 ))
  full=$(_vpb_clamp "$full" 2 6)
  [ "$full" -gt "$cores" ] && full="$cores"

  # Explicit operator overrides win, in order of specificity. NOTE: the per-budget
  # override env vars share the OUTPUT names — fine because the runner sources this
  # once (idempotent on re-source); unit tests vary inputs in fresh subshells.
  if [ -n "${V_PEST_PROCESSES:-}" ]; then
    case "$V_PEST_PROCESSES" in ''|*[!0-9]*) : ;; *) scoped="$V_PEST_PROCESSES"; full="$V_PEST_PROCESSES" ;; esac
  fi
  case "${V_PEST_PROCESSES_SCOPED:-}" in ''|*[!0-9]*) : ;; *) scoped="$V_PEST_PROCESSES_SCOPED" ;; esac
  case "${V_PEST_PROCESSES_FULL:-}" in ''|*[!0-9]*) : ;; *) full="$V_PEST_PROCESSES_FULL" ;; esac

  export V_PEST_PROCESSES_SCOPED="$scoped"
  export V_PEST_PROCESSES_FULL="$full"
}

# Source-time auto-resolve (skip with V_PROC_BUDGET_NO_AUTO=1 to unit-test the functions).
[ "${V_PROC_BUDGET_NO_AUTO:-0}" = "1" ] || vpb_resolve
