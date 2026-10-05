#!/usr/bin/env bash
# v-resolve-task-test.sh — behavioral harness for v-resolve-task.sh (Step -3 task resolution).
#
# WHY THIS EXISTS (testing-audit 2026-06-22): v-resolve-task.sh is the orchestrator's ENTRY POINT
# (resolves the user's task across 5 SID-scoped channels) and had ZERO dedicated behavioral coverage —
# only incidental channel-1 + SID-discard assertions in v-contract-audit-test.sh. Its safety properties
# carry real prod-incident history (cross-session contamination): the 2026-05-12 catastrophic cross-session
# leak (history.jsonl was PRIMARY → fixed to env-SID-PRIMARY, W25-F26), and the W25-F26b env-SID-
# authoritative guard (a parallel session's /v in the same 30s window must NOT override an env-resolved
# SID). This harness pins channel routing + the two contamination guards so a regression bites here
# instead of in a prod session a human has to read.
#
# Collision-free bite seam: $V_RESOLVE_TASK_SCRIPT swaps the script-under-test (unset → live). The bite
# (mutation-gate / this file's own proof) points it at a perl-mutated temp COPY — no in-place mutation
# of the live script, so it is safe to run under a concurrent sweep.
#
# Run: bash v-resolve-task-test.sh
set -u
command -v jq >/dev/null 2>&1 && HAVE_JQ=1 || HAVE_JQ=0

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="${V_RESOLVE_TASK_SCRIPT:-$HERE/v-resolve-task.sh}"
[ -f "$RT" ] || { echo "SKIP: script-under-test not found ($RT)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

# Fixed UUIDs (NOT seeded from date/RANDOM — determinism-net SID-hazard safe).
SID=a1111111-1111-4111-8111-111111111111
OTHER=b2222222-2222-4222-8222-222222222222

# run the resolver under an isolated HOME with the given env SID; echo stdout.
run_rt(){ # $1=home  $2=env_sid
  ( cd "$1" 2>/dev/null && env -i HOME="$1" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_CODE_SESSION_ID="$2" bash "$RT" 2>/dev/null )
}
# extract the ---TASK-SOURCE=X--- value (last one wins)
src_of(){ printf '%s' "$1" | sed -n 's/^---TASK-SOURCE=\(.*\)---$/\1/p' | tail -1; }
# write a PreToolUse SID-scoped capture (channels 1+2)
write_capture(){ # $1=home  $2=sid  $3=args  $4=prompt
  mkdir -p "$1/.claude/runtime"
  { echo "CAPTURED_AT=2026-06-22T12:00:00Z"
    echo "ARGS_LENGTH=${#3}"; echo "PROMPT_LENGTH=${#4}"
    echo "---ARGS-BEGIN---"; printf '%s\n' "$3"; echo "---ARGS-END---"
    echo "---PROMPT-BEGIN---"; printf '%s\n' "$4"; echo "---PROMPT-END---"
  } > "$1/.claude/runtime/last-skill-args-$2.txt"
}
# write a 2-line history.jsonl (line 1 dropped by the resolver's `tail -n +2`)
write_history(){ # $1=home  $2=jsonl-entry-for-line-2
  mkdir -p "$1/.claude"
  { printf '{"_dummy":"first line is dropped by tail -n +2"}\n'; printf '%s\n' "$2"; } > "$1/.claude/history.jsonl"
}

echo "== v-resolve-task :: channel routing + cross-session contamination guards =="

# T1 — Channel 1 (args) → TASK-SOURCE=args, body present
H=$(mktemp -d); write_capture "$H" "$SID" "fix the auth bug" ""
O=$(run_rt "$H" "$SID")
[ "$(src_of "$O")" = "args" ] && ok "T1 args channel -> source=args" || no "T1 args channel (got source='$(src_of "$O")')"
printf '%s' "$O" | grep -q "fix the auth bug" && ok "T1 args body surfaced" || no "T1 args body missing"
rm -rf "$H"

# T2 — Channel 2 (prompt, args empty) → TASK-SOURCE=prompt
H=$(mktemp -d); write_capture "$H" "$SID" "" "implement the dashboard"
O=$(run_rt "$H" "$SID")
[ "$(src_of "$O")" = "prompt" ] && ok "T2 prompt channel -> source=prompt" || no "T2 prompt channel (got '$(src_of "$O")')"
rm -rf "$H"

# T3 — routing priority: args beats prompt when BOTH present
H=$(mktemp -d); write_capture "$H" "$SID" "ARGS wins" "PROMPT loses"
O=$(run_rt "$H" "$SID")
[ "$(src_of "$O")" = "args" ] && ok "T3 priority args > prompt" || no "T3 priority (got '$(src_of "$O")')"
printf '%s' "$O" | grep -q "PROMPT loses" && no "T3 prompt body leaked despite args present" || ok "T3 prompt body correctly not routed"
rm -rf "$H"

# T4 — SID-SCOPING (W25-F9 contamination guard): a capture for ANOTHER sid must NOT be read.
H=$(mktemp -d); write_capture "$H" "$OTHER" "OTHER-SESSION-SECRET-TASK" ""   # only OTHER has a capture
O=$(run_rt "$H" "$SID")                                                       # current sid: no capture, no history
[ "$(src_of "$O")" = "empty" ] && ok "T4 SID-scoping: other-session capture NOT read (source=empty)" || no "T4 CONTAMINATION: read a non-SID-scoped capture (source='$(src_of "$O")')"
printf '%s' "$O" | grep -q "OTHER-SESSION-SECRET-TASK" && no "T4 LEAK: another session's task appeared in output" || ok "T4 no cross-session task leak"
rm -rf "$H"

# T5 — no channels populated → TASK-SOURCE=empty (Final Guard takes over)
H=$(mktemp -d); mkdir -p "$H/.claude/runtime"
O=$(run_rt "$H" "$SID")
[ "$(src_of "$O")" = "empty" ] && ok "T5 no input -> source=empty" || no "T5 empty (got '$(src_of "$O")')"
rm -rf "$H"

if [ "$HAVE_JQ" = "1" ]; then
  # T6 — Channel 3 history.jsonl: a SID-matching /v entry resolves via the history fallback
  H=$(mktemp -d)
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"/v build the feature\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{}}"
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" = "history-jsonl" ] && ok "T6 history channel (sid+vprefix) -> source=history-jsonl" || no "T6 history channel (got '$(src_of "$O")')"
  printf '%s' "$O" | grep -q "build the feature" && ok "T6 history task body surfaced (/v prefix stripped)" || no "T6 history body missing"
  rm -rf "$H"

  # T7 — W25-F26b (the 2026-05-12 catastrophic-incident guard): env-resolved SID is AUTHORITATIVE.
  # A parallel session's /v entry (DIFFERENT sid, recent <30s) must NOT override the env SID, must be
  # discarded (no leak), and must emit the W25-F26b-SID-MISMATCH-IGNORED marker.
  # H4-13 (PLAN_2026-07-02_orchestrator-hardening-4): canonicalize $H via `pwd -P` — run_rt's `env -i`
  # strips $PWD, so the resolver's own cwd resolves to the PHYSICAL path (macOS: /var/... ->
  # /private/var/...). The H4-13 project-scope filter now compares `.project` against that physical
  # path, so the fixture's `project` field must match it exactly, same-project or not.
  H=$(cd "$(mktemp -d)" && pwd -P); _now_ms=$(( $(date +%s) * 1000 ))
  write_history "$H" "{\"sessionId\":\"$OTHER\",\"display\":\"/v PARALLEL-SESSION-TASK\",\"project\":\"$H\",\"timestamp\":$_now_ms,\"pastedContents\":{}}"
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" = "empty" ] && ok "T7 W25-F26b: parallel-session /v ignored, env SID authoritative (source=empty)" || no "T7 CONTAMINATION: parallel session task routed (source='$(src_of "$O")')"
  printf '%s' "$O" | grep -q "PARALLEL-SESSION-TASK" && no "T7 LEAK: parallel session's task leaked into this session" || ok "T7 no parallel-session leak"
  printf '%s' "$O" | grep -q "SID-MISMATCH-IGNORED" && ok "T7 emits the W25-F26b-SID-MISMATCH-IGNORED marker" || no "T7 missing the SID-MISMATCH-IGNORED marker"
  rm -rf "$H"

  # PH = a dash-free contentHash (the W25-F14 _other_sid sed strips '.claimed-<hash>-', hash=[^-]+).
  PH=testpastehash01

  # T8 — Channel 6 paste-cache (W25-F22): a history entry's contentHash resolves to the HASH-MATCHED
  # paste-cache file (never latest-by-mtime — the 2026-05-11 cross-session leak).
  H=$(mktemp -d); mkdir -p "$H/.claude/paste-cache"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"/v Fix [Pasted text #1 +40 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"contentHash\":\"$PH\",\"content\":\"x\"}}}"
  printf 'THE-PASTED-BUG-REPORT-BODY\n' > "$H/.claude/paste-cache/$PH.txt"
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" = "paste-cache" ] && ok "T8 paste-cache: hash-keyed file resolved -> source=paste-cache" || no "T8 paste-cache (got '$(src_of "$O")')"
  printf '%s' "$O" | grep -q "THE-PASTED-BUG-REPORT-BODY" && ok "T8 pasted body surfaced" || no "T8 pasted body missing"
  rm -rf "$H"

  # T9 — W25-F14 SID-CLAIM: a paste already claimed by ANOTHER sid (<60s) must be SKIPPED, not read
  # (cross-session paste-cache leakage guard).
  H=$(mktemp -d); mkdir -p "$H/.claude/paste-cache"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"/v Fix [Pasted text #1 +40 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"contentHash\":\"$PH\",\"content\":\"x\"}}}"
  printf 'OTHER-SESSION-PASTE-SECRET\n' > "$H/.claude/paste-cache/$PH.txt"
  : > "$H/.claude/paste-cache/.claimed-$PH-$OTHER"   # another sid claimed it (fresh marker)
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" != "paste-cache" ] && ok "T9 W25-F14: paste claimed by another sid NOT read (source='$(src_of "$O")')" || no "T9 CONTAMINATION: read a paste claimed by another session"
  printf '%s' "$O" | grep -q "OTHER-SESSION-PASTE-SECRET" && no "T9 LEAK: another session's paste body surfaced" || ok "T9 no cross-session paste leak"
  printf '%s' "$O" | grep -q "W25-F14-PASTE-SKIPPED" && ok "T9 emits W25-F14-PASTE-SKIPPED" || no "T9 missing the PASTE-SKIPPED marker"
  rm -rf "$H"

  # T10 — history-inline FORMAT B (W25-F22b): a SMALL inline paste (content, NO contentHash) surfaces
  # the REAL task, not the '[Pasted text]' placeholder (production sessions hallucinated an
  # unrelated task while claiming success without this tier).
  H=$(mktemp -d); mkdir -p "$H/.claude/runtime"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"/v [Pasted text #1 +12 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"content\":\"REAL-INLINE-TASK-BODY\"}}}"
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" = "history-jsonl-inline" ] && ok "T10 inline FORMAT B -> source=history-jsonl-inline" || no "T10 inline (got '$(src_of "$O")')"
  printf '%s' "$O" | grep -q "REAL-INLINE-TASK-BODY" && ok "T10 real inline task surfaced (not the placeholder)" || no "T10 inline body missing"
  rm -rf "$H"

  # ── W71-F1 (forensic 2026-07-02, multi-terminal fleet): pastedContents can hold MULTIPLE
  # pastes (a stray earlier paste + the submitted one). Dereferencing .[0] routed a
  # SIBLING terminal's task into concurrent sessions,
  # and the "[Pasted text #N +M lines]" placeholder survived the strip regex, getting
  # persisted as a 26-byte "resolved task". T11-T14 pin the whole class.
  PH1=straypastehash01; PH2=ownpastehash0002

  # T11 — display references #2: the #2 paste must win, never the stray .[0] (#1)
  H=$(mktemp -d); mkdir -p "$H/.claude/paste-cache"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"[Pasted text #2 +12 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"contentHash\":\"$PH1\"},\"2\":{\"contentHash\":\"$PH2\"}}}"
  printf 'STRAY-SIBLING-TASK-BODY\n' > "$H/.claude/paste-cache/$PH1.txt"
  printf 'OWN-SUBMITTED-TASK-BODY\n' > "$H/.claude/paste-cache/$PH2.txt"
  O=$(run_rt "$H" "$SID")
  printf '%s' "$O" | grep -q "OWN-SUBMITTED-TASK-BODY" && ok "T11 display-referenced paste (#2) selected" || no "T11 referenced paste not selected"
  printf '%s' "$O" | grep -q "STRAY-SIBLING-TASK-BODY" && no "T11 CONTAMINATION: stray .[0] paste adopted (the 2026-07-02 wrong-task class)" || ok "T11 stray first paste not adopted"
  grep -q "OWN-SUBMITTED-TASK-BODY" "$H/.claude/runtime/v-resolved-task-$SID.txt" 2>/dev/null && ok "T11 persisted task is the referenced paste" || no "T11 persisted task wrong/missing"
  rm -rf "$H"

  # T12 — bare "[Pasted text #N +M lines]" with NO recoverable paste channel: never a task,
  # never persisted (the 26-byte v-resolved-task incident).
  H=$(mktemp -d); mkdir -p "$H/.claude/runtime"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"[Pasted text #2 +12 lines]\",\"project\":\"$H\",\"timestamp\":1}"
  O=$(run_rt "$H" "$SID")
  [ "$(src_of "$O")" = "empty" ] && ok "T12 placeholder-only display -> source=empty" || no "T12 placeholder routed as a task (source='$(src_of "$O")')"
  if [ -f "$H/.claude/runtime/v-resolved-task-$SID.txt" ] && grep -q "Pasted text" "$H/.claude/runtime/v-resolved-task-$SID.txt"; then
    no "T12 placeholder PERSISTED as resolved task"
  else
    ok "T12 placeholder not persisted"
  fi
  rm -rf "$H"

  # T13 — referenced paste claimed by ANOTHER sid: loud W25-F14 guidance, no silent
  # fall-through to a garbage channel (detection without a stop order is theatre).
  # Provenance-graded (W71-review M4): the hash here comes from THIS session's OWN
  # SID-scoped history entry, so the guidance is the SHARED (same-pack-two-terminals,
  # recover via Channel 5) variant — the hard BLOCKED stop order is reserved for
  # sid-free recovery strategies. Either way: never adopted, never persisted.
  H=$(mktemp -d); mkdir -p "$H/.claude/paste-cache"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"[Pasted text #1 +9 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"contentHash\":\"$PH1\"}}}"
  printf 'CLAIMED-BY-SIBLING-BODY\n' > "$H/.claude/paste-cache/$PH1.txt"
  : > "$H/.claude/paste-cache/.claimed-$PH1-$OTHER"
  O=$(run_rt "$H" "$SID")
  printf '%s' "$O" | grep -q "CLAIMED-BY-SIBLING-BODY" && no "T13 LEAK: sibling-claimed paste adopted" || ok "T13 sibling-claimed paste not adopted"
  printf '%s' "$O" | grep -qE "W25-F14-(SHARED|BLOCKED)" && ok "T13 emits explicit W25-F14 guidance (not silent empty)" || no "T13 missing the W25-F14 guidance"
  printf '%s' "$O" | grep -q "W25-F14-SHARED" && ok "T13 own-entry provenance gets the SHARED (Channel-5) variant, not the hard stop" || no "T13 wrong guidance variant for own-entry provenance"
  if [ -f "$H/.claude/runtime/v-resolved-task-$SID.txt" ] && grep -q "Pasted text" "$H/.claude/runtime/v-resolved-task-$SID.txt"; then
    no "T13 placeholder persisted under claim conflict"
  else
    ok "T13 nothing garbage persisted under claim conflict"
  fi
  rm -rf "$H"

  # T14 — inline FORMAT B with multiple entries: display-referenced inline entry wins over .[0]
  H=$(mktemp -d); mkdir -p "$H/.claude/runtime"
  write_history "$H" "{\"sessionId\":\"$SID\",\"display\":\"[Pasted text #2 +3 lines]\",\"project\":\"$H\",\"timestamp\":1,\"pastedContents\":{\"1\":{\"content\":\"STRAY-INLINE-BODY\"},\"2\":{\"content\":\"OWN-INLINE-BODY\"}}}"
  O=$(run_rt "$H" "$SID")
  printf '%s' "$O" | grep -q "OWN-INLINE-BODY" && ok "T14 display-referenced inline entry selected" || no "T14 referenced inline entry not selected"
  printf '%s' "$O" | grep -q "STRAY-INLINE-BODY" && no "T14 CONTAMINATION: stray .[0] inline entry adopted" || ok "T14 stray inline entry not adopted"
  rm -rf "$H"
else
  echo "  (skipped T6-T10 history/paste-channel tests — jq unavailable)"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
