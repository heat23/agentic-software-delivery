#!/usr/bin/env bash
# p1a-consolidated-block-test.sh — P1-A consolidated Stop-gate report (2026-07-03).
#
# WHY: the Stop hook aggregated the artifact TRIO into one block, but three later gates each
# burned their OWN block→remediate round: the gauntlet-witness gate (activates only once the
# trio is present ⇒ always a round-2 block), LAYER-3 W59-F2 (only reached when BLOCKING_ISSUES
# is empty ⇒ round-3), and per-artifact structure errors surfaced one artifact at a time
# (forensic: one session took 4 sequential rounds; another spent most of its cost on remediation turns).
# P1-A makes the FIRST block enumerate everything: witness lookahead + W59-F2 lookahead +
# embedded artifact board. Gate semantics unchanged — only the first message is complete.
#
# COVERAGE (same extract-and-eval idiom as sessionlog-warn-gate-test.sh — executes the REAL
# blocks from the production hook, not a re-implementation):
#   1. P1A-LOOKAHEAD-WITNESS: trio-missing ⇒ BLOCKING_ISSUES gains the witness lookahead line.
#   2. impl-only / no-code-change ⇒ lookahead does NOT fire (no new-block regression).
#   3. _w59_f2_signature(): hostile+inline review file ⇒ rc 0; hostile-only ⇒ rc 1; missing ⇒ rc 1.
#   4. W59 aggregation lookahead: BLOCKING_ISSUES non-empty + signature ⇒ W59 line appended;
#      BLOCKING_ISSUES EMPTY + signature ⇒ NOT appended (LAYER-3 still owns the standalone case).
#   5. P1A-BOARD: block path embeds the board output (stubbed board script via V_ARTIFACT_BOARD).
#   6. LAYER-3 gate still calls the single-source predicate (drift guard).
#
# RED ORACLE: run with V_CRA_OVERRIDE=<pre-p1a snapshot> — the P1A awk ranges are absent there,
# so tests 1/3/4/5 FAIL against the snapshot (proven at ship time; see BITE_LEDGER).
set -u
HOOK="${V_CRA_OVERRIDE:-$HOME/.claude/hooks/check-review-artifact.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$HOOK" ] || { echo "NO hook missing: $HOOK"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK" 2>/dev/null' EXIT

echo "== P1-A :: consolidated first-block report (witness + W59 lookahead + board) =="

# ── 1+2: witness lookahead block (extracted verbatim) ────────────────────────
WL="$(awk '/=== P1A-LOOKAHEAD-WITNESS/,/=== end P1A-LOOKAHEAD-WITNESS/' "$HOOK")"
if [ -z "$WL" ]; then
  no "P1A-LOOKAHEAD-WITNESS block present in hook" "awk range empty (pre-P1A hook = RED)"
else
  ok "P1A-LOOKAHEAD-WITNESS block present in hook"
  run_wl() { # $1=IS_V $2=CODE_CHANGED $3=IMPL_ONLY $4=MISSING_PREFLIGHT -> echoes BLOCKING_ISSUES
    (
      set +eu
      IS_V_SESSION="$1"; CODE_CHANGED="$2"; IMPLEMENTATION_ONLY_MODE="$3"
      MISSING_PREFLIGHT="$4"; MISSING_REVIEW=0; MISSING_VERIFY=0
      BLOCKING_ISSUES="
  ❌ PRE_FLIGHT_REPORT not found (seed)"
      eval "$WL"
      printf '%s' "$BLOCKING_ISSUES"
    )
  }
  out=$(run_wl 1 1 0 1)
  printf '%s' "$out" | grep -q 'gauntlet-attestation witness will ALSO be required' \
    && ok "trio-missing ⇒ witness lookahead line appended to the FIRST block" \
    || no "witness lookahead did not fire on trio-missing" "$(printf '%s' "$out" | tail -1)"
  out=$(run_wl 1 1 1 1)
  printf '%s' "$out" | grep -q 'witness will ALSO be required' \
    && no "impl-only session must NOT get the witness lookahead" "fired under IMPLEMENTATION_ONLY_MODE=1" \
    || ok "impl-only session: witness lookahead correctly suppressed"
  out=$(run_wl 1 0 0 1)
  printf '%s' "$out" | grep -q 'witness will ALSO be required' \
    && no "no-code-change session must NOT get the witness lookahead" "fired under CODE_CHANGED=0" \
    || ok "no-code-change session: witness lookahead correctly suppressed"
fi

# ── 3+4: W59 predicate + aggregation lookahead ───────────────────────────────
W59="$(awk '/=== P1A-LOOKAHEAD-W59/,/=== end P1A-LOOKAHEAD-W59/' "$HOOK")"
if [ -z "$W59" ]; then
  no "P1A-LOOKAHEAD-W59 block present in hook" "awk range empty (pre-P1A hook = RED)"
else
  ok "P1A-LOOKAHEAD-W59 block present in hook"
  HOSTILE_INLINE="$WORK/ar-hostile-inline.md"
  cat > "$HOSTILE_INLINE" <<'EOF'
Model: haiku
Hostile adversarial focus: yes
Dispatch mode: orchestrator-inline
## Findings
EOF
  HOSTILE_ONLY="$WORK/ar-hostile-only.md"
  cat > "$HOSTILE_ONLY" <<'EOF'
Model: haiku
Hostile adversarial focus: yes
Dispatch mode: subagent (codex-adversarial-reviewer)
## Findings
EOF
  run_w59() { # $1=review-file $2=seed-blocking ("" = empty) -> echoes BLOCKING_ISSUES; rc = predicate rc
    (
      set +eu
      SESSION_ID="p1a-test-sid"; REVIEW_FILE="$1"; BLOCKING_ISSUES="$2"
      eval "$W59"
      printf '%s' "$BLOCKING_ISSUES"
    )
  }
  out=$(run_w59 "$HOSTILE_INLINE" "
  ❌ seed issue")
  printf '%s' "$out" | grep -q 'round-2 lookahead, W59-F2' \
    && ok "blocking + hostile-inline review ⇒ W59-F2 surfaced in the SAME first block" \
    || no "W59 lookahead did not fire while blocking" "$(printf '%s' "$out" | tail -1)"
  out=$(run_w59 "$HOSTILE_INLINE" "")
  printf '%s' "$out" | grep -q 'round-2 lookahead, W59-F2' \
    && no "W59 lookahead must NOT fire when BLOCKING_ISSUES is empty (LAYER-3 owns that case)" "appended on empty" \
    || ok "empty BLOCKING_ISSUES ⇒ lookahead silent; LAYER-3 still owns the standalone block"
  out=$(run_w59 "$HOSTILE_ONLY" "
  ❌ seed issue")
  printf '%s' "$out" | grep -q 'round-2 lookahead, W59-F2' \
    && no "hostile + PROPER subagent dispatch must NOT trip the signature" "false positive" \
    || ok "hostile + subagent-dispatched review: signature correctly negative"
  out=$(run_w59 "$WORK/does-not-exist.md" "
  ❌ seed issue")
  printf '%s' "$out" | grep -q 'round-2 lookahead, W59-F2' \
    && no "missing review file must NOT trip the signature" "false positive on absent file" \
    || ok "absent review file: signature correctly negative"
fi

# ── 5: board embed on the block path ─────────────────────────────────────────
BOARD_STUB="$WORK/board-stub.sh"
cat > "$BOARD_STUB" <<'EOF'
#!/usr/bin/env bash
echo "── v-artifact-validate-all: session $1 ──"
echo "  absent  PRE_FLIGHT_REPORT"
echo "  absent  AGENT_REVIEW"
echo "  absent  VERIFY_DONE_REPORT"
echo "── 0 ok, 0 invalid, 3 absent ──"
EOF
chmod +x "$BOARD_STUB"
# Extract from the P1A-BOARD marker through the CTX assembly line (one line past the end marker).
BD="$(awk '/=== P1A-BOARD/,/^  CTX="COMPLETION BLOCKED/' "$HOOK")"
if [ -z "$BD" ]; then
  no "P1A-BOARD block present in hook" "awk range empty (pre-P1A hook = RED)"
else
  ok "P1A-BOARD block present in hook"
  out=$(
    set +eu
    SESSION_ID="p1a-test-sid"; ARTIFACT_SEARCH_DIRS=("$WORK")
    BLOCKING_ISSUES="
  ❌ seed"; WARNINGS=""; WARN_SECTION=""
    V_ARTIFACT_BOARD="$BOARD_STUB"
    eval "$BD"
    printf '%s' "$CTX"
  )
  printf '%s' "$out" | grep -q 'FULL ARTIFACT BOARD' && printf '%s' "$out" | grep -q '3 absent' \
    && ok "block-path CTX embeds the artifact board output (all artifacts enumerated at once)" \
    || no "board not embedded in CTX" "$(printf '%s' "$out" | head -2)"
  # board script missing ⇒ degrade to plain message, never crash
  out=$(
    set +eu
    SESSION_ID="p1a-test-sid"; ARTIFACT_SEARCH_DIRS=("$WORK")
    BLOCKING_ISSUES="
  ❌ seed"; WARNINGS=""; WARN_SECTION=""
    V_ARTIFACT_BOARD="$WORK/missing-board.sh"
    eval "$BD"
    printf '%s' "$CTX"
  )
  printf '%s' "$out" | grep -q 'COMPLETION BLOCKED' \
    && ok "missing board script degrades to the plain block message (best-effort, no crash)" \
    || no "missing board script broke CTX assembly" "$(printf '%s' "$out" | head -2)"
fi

# ── 6: LAYER-3 drift guard — the gate itself calls the single-source predicate ──
L3="$(awk '/=== LAYER-3: W59-F2 hostile-dispatch gate ===/,/=== end LAYER-3 W59-F2 ===/' "$HOOK")"
printf '%s\n' "$L3" | grep -q '_w59_f2_signature' \
  && ok "LAYER-3 gate calls _w59_f2_signature (single source; lookahead cannot drift from the gate)" \
  || no "LAYER-3 does not use the shared predicate" "duplicated greps = drift risk (pre-P1A = RED)"

# ── 7: W-REMEDIATE-SIDECAR (2026-08-17) — GAUNTLET_STALE block points at v-remediate-stale.sh ──
# Recommendation #2: the block used to instruct "re-run the step behind each artifact... in a
# single round" as prose only, with no tool named. It now points at the batched-dispatch script.
WL2="$(awk '/_gauntlet_stale_marker=/,/^  fi$/' "$HOOK")"
printf '%s' "$WL2" | grep -q 'v-remediate-stale.sh' \
  && ok "GAUNTLET_STALE block points at v-remediate-stale.sh" \
  || no "GAUNTLET_STALE block missing the remediation-script pointer" ""

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
