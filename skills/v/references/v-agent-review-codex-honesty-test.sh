#!/usr/bin/env bash
# v-agent-review-codex-honesty-test.sh — F4: codex dispatch honesty guidance present in v-agent-review.md.
#
# Forensic (R-3): the codex review degraded to an inline self-review
# but was labeled as a successful codex run. The root cause is a broken hand-rolled invocation
# (`echo "$P" | codex exec … </dev/null` — </dev/null clobbers the pipe), a W41-blocked `cat`
# retrieval, and dishonest provenance labeling. v-agent-review.md must carry all three counter-rules:
#   (1) positional-arg invocation / no pipe-clobber, (2) grep/tail/BashOutput retrieval not `cat`,
#   (3) honest orchestrator_inline labeling when codex output was never read.
# This guards against accidental removal of that load-bearing guidance. RED on the pre-F4 backup
# (the callout is absent), GREEN on the current doc.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
DOC="${V_AGENT_REVIEW_DOC:-$HERE/v-agent-review.md}"
BACKUP="$HERE/v-agent-review.md.pre-f4-codex-honesty-bak"

# Markers unique to the F4 callout — each encodes one of the three counter-rules.
MARKERS=(
  "Codex dispatch — invocation, retrieval, and HONEST labeling"   # section header
  "overrides the stdin pipe"                                       # rule 1: pipe-clobber
  "NEVER\`?.*echo \"\$PROMPT\" | codex exec"                       # rule 1: the banned form
  "Retrieval — codex auto-backgrounds"                            # rule 2: retrieval
  "BashOutput"                                                     # rule 2: correct retrieval tool
  "you did \*\*not\*\* obtain a codex review"                      # rule 3: honesty premise
  "orchestrator_inline"                                            # rule 3: the honest label
  "W22-CC2"                                                        # ties to the validate-log guard
)

check_doc() {  # $1 = path ; prints "PRESENT n/N" ; returns 0 if ALL present
  local path="$1" present=0 total="${#MARKERS[@]}" m
  for m in "${MARKERS[@]}"; do
    if grep -Eq "$m" "$path" 2>/dev/null; then present=$((present+1)); fi
  done
  echo "$present/$total"
  [ "$present" -eq "$total" ]
}

echo "== F4 :: codex dispatch honesty guidance in v-agent-review.md =="
echo "-- GREEN: current doc must contain ALL ${#MARKERS[@]} counter-rule markers --"
green_count=$(check_doc "$DOC"); green=$?
echo "   current: $green_count present (rc=$green)"
for m in "${MARKERS[@]}"; do
  grep -Eq "$m" "$DOC" 2>/dev/null && echo "   ok  $m" || echo "   NO  MISSING: $m"
done

echo ""
echo "-- RED: pre-F4 backup must be MISSING the callout (proves the guidance is new) --"
# The pre-F4 backup is an OPTIONAL RED-proving fixture; it isn't retained on every machine (these
# .pre-*-bak files get cleaned up). When it's absent the RED repro is unprovable, but the GREEN check
# (the live doc still carries ALL counter-rule markers — the thing that actually guards against
# accidental guidance removal) fully holds. So SKIP the RED half rather than FAIL for a non-reason
# (audit 2026-06-18 determinism fix — same class as 'SKIP: jq unavailable'; do NOT weaken GREEN).
RED_AVAILABLE=0
if [ -f "$BACKUP" ]; then
  red_count=$(check_doc "$BACKUP"); red=$?
  RED_AVAILABLE=1
  echo "   backup: $red_count present (rc=$red)"
else
  echo "   backup absent — SKIP RED repro (GREEN marker check still enforced)"; red=1
fi

echo ""
# GREEN (mandatory): all markers present on current (rc 0). RED (only when the backup fixture exists):
# backup missing at least one marker (rc non-0).
if [ "$green" -ne 0 ]; then
  echo "RESULT: FAIL — green=$green (want 0, all counter-rule markers present on the live doc)"; exit 1
elif [ "$RED_AVAILABLE" -eq 1 ] && [ "$red" -eq 0 ]; then
  echo "RESULT: FAIL — red=$red (backup unexpectedly carries the callout; RED repro invalid)"; exit 1
else
  if [ "$RED_AVAILABLE" -eq 1 ]; then
    echo "RESULT: PASS — GREEN current (all markers), RED backup (callout absent)"
  else
    echo "RESULT: PASS — GREEN current (all markers); RED skipped (backup fixture absent)"
  fi
  exit 0
fi
