#!/usr/bin/env bash
# v-agent-review-subprocess-provenance-test.sh — 21 (forensic 2026-07-03, P1-4): "dispatch ledger
# structurally blind to subprocess dispatches". Ground truth: one session's DISPATCH_PROVENANCE file carried
# 1 line (an Agent-tool verify-done dispatch) while the transcript proved 2 additional subprocess
# review dispatches with NO provenance at all — `record-agent-dispatch-provenance.sh` only fires on
# Agent-tool PostToolUse, and `v-dispatch-subagent.sh` (`$HELPER`) only self-records dispatches that
# actually go THROUGH it; a reviewer invoked as a bare CLI subprocess directly inside a supervisor
# child script (codex today) needed its own hand-rolled provenance-append. This test pins that the
# codex-only inline pattern (v-agent-review.md:117-130 pre-fix) is now a GENERIC, reusable function
# (`_v_record_subprocess_provenance`) that ANY future raw-subprocess dispatch can call — and that the
# function, extracted verbatim from the doc, produces a well-formed DISPATCH_PROVENANCE line.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
DOC="${V_AGENT_REVIEW_DOC:-$DIR/v-agent-review.md}"
[ -f "$DOC" ] || { echo "SKIP: missing $DOC"; exit 0; }
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: no sha256 tool"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }

echo "== 21 :: generic subprocess-dispatch provenance pattern in v-agent-review.md =="

# --- marker checks (anti-dead-doc: the guidance is discoverable, not just the function body) ---
MARKERS=(
  "_v_record_subprocess_provenance"
  "GENERIC pattern for"
  "MUST call \`_v_record_subprocess_provenance\`"
  "P1-4"
)
for m in "${MARKERS[@]}"; do
  if grep -Fq "$m" "$DOC" 2>/dev/null; then ok "marker present: $m"; else no "marker MISSING: $m"; fi
done

# --- extract the real function body verbatim and execute it ---
FN=$(awk '/^_v_record_subprocess_provenance\(\) \{/{inf=1} inf{print} inf&&/^\}/{exit}' "$DOC")
if [ -z "$FN" ]; then
  no "could not extract _v_record_subprocess_provenance() body from $DOC"
  echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; exit 1
fi
ok "extracted _v_record_subprocess_provenance() from the real doc"
# the doc embeds it inside a heredoc with backslash-escaped $ (\$) for later shell expansion at
# dispatch time — un-escape so it is directly `source`-able bash here.
FN_UNESCAPED=$(printf '%s' "$FN" | sed 's/\\\$/$/g')

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ART="$T/AGENT_REVIEW_CODEX_test.md"
printf 'fake codex output\n' > "$ART"
LOG="$T/DISPATCH_PROVENANCE_test.log"

# shellcheck disable=SC1090
eval "$FN_UNESCAPED"
_v_record_subprocess_provenance "codex-adversarial-reviewer" "codex_cli" "gpt-5.3-codex" "ok" "4200" "$ART" "$LOG"

if [ -f "$LOG" ]; then
  ok "provenance log file created"
else
  no "provenance log file NOT created"
fi
LINE=$(cat "$LOG" 2>/dev/null)
case "$LINE" in
  DISPATCH\|ts=*\|agent=codex-adversarial-reviewer\|mode=codex_cli\|status=ok\|submodel=gpt-5.3-codex\|cost_usd=\|duration_ms=4200\|artifact=*\|sha256=*)
    ok "emitted line matches the DISPATCH_PROVENANCE schema (agent/mode/status/submodel/duration/artifact/sha256)" ;;
  *) no "emitted line does not match expected schema" "$LINE" ;;
esac
# sha256 must be the LAST field with no trailing content (hooks/lib/validation.sh anchors on
# `sha256=[0-9a-fA-F]{64}$` — a trailing field after it would silently break that gate).
if printf '%s' "$LINE" | grep -qE 'sha256=[0-9a-fA-F]{64}$'; then
  ok "sha256 is the LAST field on the line (validation.sh's \$-anchored regex stays intact)"
else
  no "sha256 is not the terminal field — would break validation.sh's anchored parsers" "$LINE"
fi
WANT_SHA=$(shasum -a 256 "$ART" 2>/dev/null | awk '{print $1}' || sha256sum "$ART" | awk '{print $1}')
case "$LINE" in *"sha256=$WANT_SHA") ok "sha256 matches the artifact's actual content hash" ;;
  *) no "sha256 does not match artifact content" "$LINE (want sha256=$WANT_SHA)" ;;
esac

# status=failed path
_v_record_subprocess_provenance "codex-adversarial-reviewer" "codex_cli" "gpt-5.5" "failed" "1000" "$ART" "$LOG"
tail -1 "$LOG" | grep -q 'status=failed' && ok "failed-status dispatch also recorded" || no "failed-status line missing"

# two appends -> two lines (append-only, never truncates)
[ "$(wc -l < "$LOG" | tr -d ' ')" = "2" ] && ok "log is append-only (2 calls -> 2 lines)" || no "log was not append-only" "$(wc -l < "$LOG")"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
