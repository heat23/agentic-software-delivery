#!/usr/bin/env bash
# c2-subprocess-ledger-test.sh — C2 (telemetry 2026-06-21, G1-1/G1-4). The /v fork dispatches reviewers/
# runners as `claude -p` SUBPROCESSES (subagents can't spawn subagents), a path the G1 PostToolUse=Agent
# hook structurally cannot see — so the unified DISPATCH_LEDGER missed most cross-process dispatches.
# v-dispatch-subagent.sh's emit_marker now ALSO appends a DISPATCH_LEDGER.jsonl row recording the ACTUAL
# billed model (model_used=SUBMODEL from .modelUsage) + the real dispatch_path (--mode). This unit-tests
# emit_marker in isolation (the same extract_fn idiom the stdin test uses). Re-run: bash <thisfile>
set -u
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
SRC="$HERE/v-dispatch-subagent.sh"
[ -f "$SRC" ] || { echo "SKIP: dispatcher missing"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
awk '/^emit_marker\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC" > "$WORK/emit.sh"
[ -s "$WORK/emit.sh" ] && ok "extracted emit_marker from the dispatcher" || { no "could not extract emit_marker" "awk"; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1; }

ART_DIR="$WORK/art"; mkdir -p "$ART_DIR"
ARTIFACT="$ART_DIR/QA_REPORT_c2c2c2c2.md"; printf 'verdict: pass\n' > "$ARTIFACT"
LEDGER="$ART_DIR/DISPATCH_LEDGER.jsonl"; PROV_LOG="$ART_DIR/DISPATCH_PROVENANCE_c2.log"
# Env emit_marker reads. SUBMODEL=opus is the ACTUAL billed model parsed from .modelUsage; MODEL=haiku is
# the (ignored-for-agents) request — proving model_used != model_requested is captured.
run_emit(){ # $1=status
  bash -c '
    set -u
    AGENT="v-qa-reviewer"; MODE="capture"; SUBMODEL="opus"; MODEL="haiku"; AGENT_PINNED_MODEL=""
    PROV_SID="c2c2c2c2-1111-4111-8111-111111111111"; COST="0.42"; DURATION="1234"
    ART_BASE="QA_REPORT_c2c2c2c2.md"; ARTIFACT="'"$ARTIFACT"'"; ART_DIR="'"$ART_DIR"'"; PROV_LOG="'"$PROV_LOG"'"
    # PROV_DIR: the real dispatcher ALWAYS sets this (v-dispatch-subagent.sh:291-294) before
    # emit_marker runs. W5G-4c (2026-07-10) added an unguarded $PROV_DIR reference inside the
    # ok-status archival branch; under `set -u` this fixture aborted THERE — before the PROV_LOG
    # and ledger writes below ever executed. That is why the three "not written"/"malformed JSON"
    # failures appeared: the harness was missing an env var the dispatcher always provides, not
    # the writer being broken (the JSON quote-sanitizer is fine; the file simply never existed).
    PROV_DIR="'"$ART_DIR"'"
    source "'"$WORK/emit.sh"'"
    emit_marker "'"$1"'"
  ' 2>/dev/null
}

echo "== C2 :: subprocess dispatch mirrored into DISPATCH_LEDGER with model_used =="
rm -f "$LEDGER" "$PROV_LOG"; run_emit ok
[ -s "$PROV_LOG" ] && ok "existing DISPATCH_PROVENANCE line still written (no regression)" || no "PROV_LOG not written" "$(ls "$ART_DIR")"
if [ -s "$LEDGER" ]; then
  jq -e . "$LEDGER" >/dev/null 2>&1 && ok "ledger row is valid JSON" || no "ledger row not valid JSON" "$(cat "$LEDGER")"
  [ "$(jq -r '.dispatch_path' "$LEDGER")" = "capture" ] && ok "dispatch_path = the subprocess --mode (capture) — NOT agent-tool" || no "dispatch_path wrong" "$(cat "$LEDGER")"
  [ "$(jq -r '.model_used' "$LEDGER")" = "opus" ] && ok "model_used = the ACTUAL billed submodel (opus), not the request (haiku)" || no "model_used wrong" "$(cat "$LEDGER")"
  [ "$(jq -r '.model_requested' "$LEDGER")" = "haiku" ] && ok "model_requested preserved (haiku) — intent vs actual both captured" || no "model_requested wrong" "$(cat "$LEDGER")"
  [ "$(jq -r '.agent_type' "$LEDGER")" = "v-qa-reviewer" ] && ok "agent_type recorded" || no "agent_type wrong" "$(cat "$LEDGER")"
else
  no "no DISPATCH_LEDGER row written by emit_marker (C2 wiring missing)" "$(ls "$ART_DIR")"
fi

# Negative control: a transient (retry) marker must NOT add a ledger row — one row per dispatch.
rm -f "$LEDGER"; run_emit transient
[ ! -s "$LEDGER" ] && ok "transient retry marker writes NO ledger row (one row per dispatch)" || no "transient leaked a duplicate ledger row" "$(cat "$LEDGER")"

# review MED (2026-06-21): a quote-bearing agent/model identifier must NOT malform the JSON row.
rm -f "$LEDGER"
bash -c '
  set -u
  AGENT="evil\"injected"; MODE="capture"; SUBMODEL="op\"us"; MODEL="hai\\ku"; AGENT_PINNED_MODEL=""
  PROV_SID="c2c2c2c2-1111-4111-8111-111111111111"; COST="0"; DURATION="0"
  ART_BASE="QA_REPORT_x.md"; ARTIFACT="'"$ARTIFACT"'"; ART_DIR="'"$ART_DIR"'"; PROV_LOG="'"$PROV_LOG"'"
  PROV_DIR="'"$ART_DIR"'"   # mirror the dispatcher (see the note in run_emit above)
  source "'"$WORK/emit.sh"'"
  emit_marker ok
' 2>/dev/null
{ [ -s "$LEDGER" ] && jq -e . "$LEDGER" >/dev/null 2>&1; } && ok "review MED: quote/backslash-bearing identifier -> still VALID JSON (escaped/stripped)" || no "review MED: quote injection malformed the ledger JSON" "$(cat "$LEDGER" 2>/dev/null)"

# Source guard: the dispatcher must contain the ledger-write (anti-silent-removal).
grep -q 'DISPATCH_LEDGER.jsonl' "$SRC" && ok "dispatcher source contains the unified-ledger write" || no "ledger write absent from dispatcher source" "grep miss"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
