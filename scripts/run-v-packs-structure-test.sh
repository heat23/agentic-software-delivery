#!/usr/bin/env bash
# run-v-packs-structure-test.sh — MODULARIZATION parity + structure guard for run-v-packs.
#
# WHY: run-v-packs is being split into run-v-packs-lib/*.sh in safe increments. The whole split is only safe
# because `source run-v-packs` (every run-v-packs-*-test.sh harness) must STILL define the entire function API
# transitively via the lib seam. This suite is the guard that keeps that contract true as more groups move out:
#   (1) sourcing the runner exposes main() + the full API (no group silently lost in a move).
#   (2) the lib seam is REAL — every extracted group lives in the lib, not duplicated inline: removing
#       the lib dir drops EXACTLY those functions and nothing else (catches a re-inline, a broken seam, or a
#       future extraction that forgets to delete the inline copy → two definitions drift).
#   (3) the in-file API (verdict/run_pack/drain_wave/land_wave/main …) survives with the lib absent — proving
#       only the moved group depends on the lib, so a lib-load failure degrades predictably, never silently.
#   (4) the SECTION INDEX map + the lib reference are present (the navigation contract the split exists to give).
#   (5) advisory: report functions over a size budget (informational — does NOT fail the suite).
# Portable bash 3.2/macOS: no arrays-of-arrays, no `mapfile`, no GNU-only tools.
set -uo pipefail
RUNNER="${RUNNER:-$HOME/.local/bin/run-v-packs}"
LIBDIR="${RUNNER}-lib"
[ -f "$RUNNER" ] || { echo "FATAL: runner not found: $RUNNER"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s — %s\n' "$1" "${2:-}"; }

# The functions that have been EXTRACTED into run-v-packs-lib/ (discovery + git-landing groups so far).
# Update this list when a new group is extracted; the parity assertions below then re-pin the new seam
# automatically. (Renamed from DISCOVERY_FNS in Phase 2 — now covers every extracted group, not just discovery.)
LIB_FNS="is_pack _wave_norm wave_of _scan list_all_packs list_packs_in_wave waves_present list_verify_packs verify_pack explain_rejected_candidates oversized_packs pack_name count_done _ack_ledger _ack_names _is_ack_quarantined _list_needs count_needs count_needs_ack count_left human_time _main_branch has_pending_landing _timeout_kind _result_out_tokens _fork_turns _inconclusive_kind _gauntlet_artifacts_verified _gauntlet_verdicts_not_failed _newest_sid_artifact _attest_corpus _attest_mention_only verdict sid_of capture_telemetry _archive_finished_pack reset_epoch reconcile_parked_by_sid reconcile_parked_by_proof reconcile_parked_readonly gc_merged_branches _drain_verdict_for _land_and_reconcile _unlanded_branches _rotate_pack_log _watchdog _pack_is_readonly _pack_prompt _strand_is_stranded _strand_resume_prompt run_pack _adopt_orphans _hb run_pass_wave drain_wave land_wave warn_skipped_lower_waves"
# The functions that remain INLINE in the runner (must survive with the lib absent). Since Phase 6 the
# inline set is exactly: die + main + main's own skeleton helpers (verbatim lifts of its former blocks).
INLINE_FNS="die main _parse_args _preflight_and_dirs _multi_batch_sequential _acquire_lock _arm_dispatch _clamp_concurrency _emit_run_banner _conflict_gate _dry_run_report _run_verify_pack _final_sweep _finish_report"

fns_when_sourced(){ # $1 = path to a runner file -> newline list of defined function names
  bash -c 'source "'"$1"'" >/dev/null 2>&1; declare -F | awk "{print \$3}" | sort'
}

echo "── (1) sourcing the installed runner exposes main() and the full API ──"
ALL="$(fns_when_sourced "$RUNNER")"
printf '%s\n' "$ALL" | grep -qx main && ok "main() is defined after source" || no "main() missing after source"
miss=""
for fn in $LIB_FNS $INLINE_FNS; do printf '%s\n' "$ALL" | grep -qx "$fn" || miss="$miss $fn"; done
[ -z "$miss" ] && ok "every expected function is defined (lib groups + inline)" || no "functions missing after source" "$miss"

echo "── (2)+(3) the lib seam is real: removing run-v-packs-lib/ drops EXACTLY the extracted groups ──"
cp "$RUNNER" "$TMP/run-v-packs"
if [ -d "$LIBDIR" ]; then cp -R "$LIBDIR" "$TMP/run-v-packs-lib"; fi
WITH="$(fns_when_sourced "$TMP/run-v-packs")"
rm -rf "$TMP/run-v-packs-lib"
WITHOUT="$(fns_when_sourced "$TMP/run-v-packs")"
# functions present WITH the lib but absent WITHOUT it == what the lib provides
GONE="$(comm -23 <(printf '%s\n' "$WITH") <(printf '%s\n' "$WITHOUT"))"
EXPECT_GONE="$(printf '%s\n' $LIB_FNS | sort)"
if [ "$GONE" = "$EXPECT_GONE" ]; then
  ok "lib provides exactly the extracted groups (seam sources them; no inline duplicate)"
else
  no "lib/inline split drifted" "removing lib changed: $(printf '%s' "$GONE" | tr '\n' ' ')"
fi
# the inline API must still stand with the lib gone (predictable degradation, not a silent wipe)
imiss=""
for fn in $INLINE_FNS; do printf '%s\n' "$WITHOUT" | grep -qx "$fn" || imiss="$imiss $fn"; done
[ -z "$imiss" ] && ok "inline API survives with the lib absent" || no "inline API vanished without lib" "$imiss"

echo "── (4) the SECTION INDEX map + the lib references are present in the runner ──"
grep -q 'SECTION INDEX' "$RUNNER" && ok "SECTION INDEX map present" || no "SECTION INDEX map missing"
grep -q 'run-v-packs-lib/10-discovery.sh' "$RUNNER" && ok "discovery lib referenced in the map" || no "discovery lib not referenced in the map"
grep -q 'run-v-packs-lib/20-git-landing.sh' "$RUNNER" && ok "git-landing lib referenced in the map" || no "git-landing lib not referenced in the map"
grep -q 'run-v-packs-lib/30-verdict.sh' "$RUNNER" && ok "verdict lib referenced in the map" || no "verdict lib not referenced in the map"
grep -q 'run-v-packs-lib/40-archive-reconcile.sh' "$RUNNER" && ok "archive-reconcile lib referenced in the map" || no "archive-reconcile lib not referenced in the map"
grep -q 'run-v-packs-lib/50-pack-exec.sh' "$RUNNER" && ok "pack-exec lib referenced in the map" || no "pack-exec lib not referenced in the map"
grep -q 'run-v-packs-lib/60-wave.sh' "$RUNNER" && ok "wave lib referenced in the map" || no "wave lib not referenced in the map"
# every lib function is either named or covered (list_*_packs / count_*) in the SECTION INDEX block
toc="$(awk '/SECTION INDEX/{f=1} f{print} /Entry point/{if(f)exit}' "$RUNNER")"
tmiss=""
for fn in $LIB_FNS; do
  case "$fn" in
    list_*)  printf '%s' "$toc" | grep -q 'list_\*' || tmiss="$tmiss $fn" ;;  # family token covers all list_* fns
    count_*) printf '%s' "$toc" | grep -q 'count_\*' || tmiss="$tmiss $fn" ;; # family token covers all count_* fns
    *)       printf '%s' "$toc" | grep -q "$fn"      || tmiss="$tmiss $fn" ;;
  esac
done
[ -z "$tmiss" ] && ok "SECTION INDEX names/covers every extracted-group function" || no "SECTION INDEX out of sync" "$tmiss"

echo "── (5) advisory: functions over the size budget (informational — never fails) ──"
BUDGET="${V_FN_LINE_BUDGET:-120}"
# count body lines per top-level `name(){` ... matching `^}` at column 0. Scans runner + lib files.
for src in "$RUNNER" "$LIBDIR"/*.sh; do
  [ -e "$src" ] || continue
  awk -v budget="$BUDGET" -v file="$src" '
    /^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ && !inbody { name=$0; sub(/\(\).*/,"",name); start=NR; inbody=1; next }
    inbody && /^\}/ { n=NR-start; if (n>budget) printf "  note %s:%d %s() is %d lines (> %d)\n", file, start, name, n, budget; inbody=0 }
  ' "$src"
done
echo "  (size notes are guidance for the NEXT extraction target; not a gate)"

echo
echo "── result: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]
