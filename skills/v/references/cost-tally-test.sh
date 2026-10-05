#!/usr/bin/env bash
# cost-tally-test.sh — pins the canonical fleet tally (telemetry G4+G6, 2026-06-21).
# Bites the three failure modes the verify-done investigation hit:
#   (1) RECURSION: a tally that globs only top-level *.jsonl drops the subagent spend (the 67% pool). The
#       fixture's subagent dollars must appear in grand_total — neuter the */subagents/ glob -> RED.
#   (2) MODEL AUTHORITY: a transcript whose BODY self-tags "Model: haiku" but BILLS sonnet must count as sonnet.
#   (3) MISLABEL GUARD: a verify-done-identity transcript that Edited must be flagged !MISLABEL, not counted as
#       a clean read-only verify-done run (the exact orchestrator-fork-as-verify-done error).
# Re-run: bash <thisfile>
set -u
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TALLY="$HERE/cost-tally.py"
[ -f "$TALLY" ] || { echo "SKIP: missing cost-tally.py"; exit 0; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP" 2>/dev/null' EXIT
P="$TMP/proj"; mkdir -p "$P/SESS/subagents"

# Build synthetic transcripts with KNOWN cache_read tokens (1,000,000 each line -> easy $).
# helper: append an assistant usage line for <model> with optional <toolname>
line(){ # $1=file $2=model $3=tool(optional) $4=file_path(optional, for Edit/Write source-vs-artifact discrimination)
  local tool=""; [ -n "${3:-}" ] && tool=",{\"type\":\"tool_use\",\"name\":\"$3\",\"input\":{\"file_path\":\"${4:-}\"}}"
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0}},"content":[{"type":"text","text":"x"}%s]}}\n' "$2" "$tool" >> "$1"
}
envelope(){ printf '{"type":"user","message":{"role":"user","content":"Base directory for this skill: /x/.claude/skills/%s\\n\\nstuff"}}\n' "$2" >> "$1"; }

# MAIN: 2 sonnet lines = 2,000,000 cr * 0.3e-6 = $0.60
M="$P/SESS.jsonl"; line "$M" claude-sonnet-4-6; line "$M" claude-sonnet-4-6
# SUBAGENT 1: real verify-done (skill:v-verify-done, haiku, tool-clean) = 2,000,000 cr * 0.1e-6 = $0.20
A1="$P/SESS/subagents/vd.jsonl"; envelope "$A1" v-verify-done; line "$A1" claude-haiku-4-5; line "$A1" claude-haiku-4-5
# SUBAGENT 2: orchestrator FORK (skill:v, sonnet, edits) = $0.60, class orchestrator-fork
A2="$P/SESS/subagents/fork.jsonl"; envelope "$A2" v; line "$A2" claude-sonnet-4-6 Edit; line "$A2" claude-sonnet-4-6 Bash
# SUBAGENT 3: MISLABEL — verify-done identity + a body self-tag "Model: haiku", but BILLS sonnet AND edits
# SOURCE (app/Services/Foo.php — C3: a SOURCE edit, not an own-report write, is what proves the violation).
A3="$P/SESS/subagents/mislabel.jsonl"; envelope "$A3" v-verify-done
printf '{"type":"user","message":{"role":"user","content":"Model: haiku (self-tag)"}}\n' >> "$A3"
line "$A3" claude-sonnet-4-6 Edit app/Services/Foo.php; line "$A3" claude-sonnet-4-6 Edit app/Services/Foo.php
# SUBAGENT 4 (H3): NESTED at <sid>/subagents/workflows/wf_x/agent.jsonl — a single-level glob drops it (the
# bug that silently dropped ~8% of real fleet spend). 1 sonnet line = $0.30.
mkdir -p "$P/SESS/subagents/workflows/wf_x"
A4="$P/SESS/subagents/workflows/wf_x/agent.jsonl"; envelope "$A4" v-build; line "$A4" claude-sonnet-4-6 Read
# SUBAGENT 5 (M4): MIXED-model (opus then haiku). The opus $ must bucket under opus, not be overwritten to
# haiku by the last-seen model. opus 1M cr = $0.50 ; haiku 1M cr = $0.10.
A5="$P/SESS/subagents/mixed.jsonl"; envelope "$A5" some-agent; line "$A5" claude-opus-4-8; line "$A5" claude-haiku-4-5
# SUBAGENT 6 (C3, TEL-1 FP fix): a v-qa-reviewer that WROTE ONLY ITS OWN REPORT (QA_REPORT_abc.md) — read-only
# ON SOURCE. The own-report Write must NOT be counted as a source edit -> NOT flagged !MISLABEL, bucketed
# readonly. haiku 1M cr = $0.10.
A6="$P/SESS/subagents/qarep.jsonl"; envelope "$A6" v-qa-reviewer; line "$A6" claude-haiku-4-5 Write "QA_REPORT_abc.md"

OUT="$(python3 "$TALLY" "$P" 2>/dev/null)"

echo "== cost-tally :: canonical fleet tally =="
SUBN="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["files"]["subagents"])' 2>/dev/null)"
[ "$SUBN" = "6" ] && ok "H3 RECURSION: all 6 subagents scanned incl. the NESTED workflows/wf_x/agent.jsonl (files.subagents=6)" || no "subagents not fully recursed (got $SUBN, expect 6 — nested transcript dropped?)" "$OUT"
# grand_total = main 0.60 + vd 0.20 + fork 0.60 + mislabel 0.60 + nested 0.30 + mixed(opus 0.50 + haiku 0.10) + qarep 0.10 = 3.00
GT="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["grand_total"],2))' 2>/dev/null)"
[ "$GT" = "3.0" ] && ok "GRAND total includes ALL subagents incl. nested+mixed+qarep ($GT == 3.00)" || no "grand_total wrong (got $GT, expect 3.00)" "$OUT"
# M4: the mixed-model transcript's OPUS spend must bucket under opus, not be overwritten to the last-seen haiku.
OPUS="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(round(json.load(sys.stdin)["by_bucket_model"].get("subagents|opus",0),2))' 2>/dev/null)"
[ "$OPUS" = "0.5" ] && ok "M4: mixed-model transcript OPUS \$ bucketed under opus (\$0.50), not overwritten to haiku" || no "M4: opus \$ mis-attributed (subagents|opus=$OPUS, expect 0.50)" "$OUT"
# MODEL AUTHORITY: the mislabel transcript billed sonnet -> there must be sonnet, and its $ is in a sonnet bucket
printf '%s' "$OUT" | grep -q 'subagents|sonnet' && ok "MODEL AUTHORITY: sonnet billing counted from .message.model (not the haiku self-tag)" || no "sonnet billing missing" "$OUT"
# MISLABEL guard: the SOURCE-edited verify-done identity must be flagged, NOT counted as a clean readonly run
printf '%s' "$OUT" | grep -q 'verify-done!MISLABEL' && ok "MISLABEL guard: SOURCE-edited verify-done-identity flagged (the verify-done mislabel error is now impossible)" || no "mislabel not flagged for a source edit" "$OUT"
# C3 (TEL-1 FP fix): the report-only qa-reviewer (wrote ONLY QA_REPORT_abc.md) must NOT be flagged !MISLABEL
# and must bucket readonly — an own-report write is not a SOURCE edit (the 0%-precision false positive).
printf '%s' "$OUT" | grep -q 'qa-reviewer.*MISLABEL' && no "C3: report-only qa-reviewer WRONGLY flagged !MISLABEL (TEL-1 FP not fixed)" "$OUT" || ok "C3: report-only qa-reviewer NOT flagged !MISLABEL (own-report Write != source edit)"
printf '%s' "$OUT" | grep -q 'qa-reviewer|haiku|readonly' && ok "C3: report-only qa-reviewer bucketed readonly (not impl-or-edit)" || no "C3: report-only qa-reviewer not bucketed readonly" "$OUT"
# the fork must be classified orchestrator-fork, never verify-done
printf '%s' "$OUT" | grep -q 'skill:v|sonnet|orchestrator-fork' && ok "orchestrator fork classified as orchestrator-fork (not verify-done)" || no "fork misclassified" "$OUT"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
