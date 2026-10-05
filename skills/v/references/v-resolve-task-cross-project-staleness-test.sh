#!/usr/bin/env bash
# v-resolve-task-cross-project-staleness-test.sh — H4-13 (PLAN_2026-07-02_orchestrator-hardening-4)
#
# Ground truth: a fresh /v session's Step -3 resolved a STALE cross-project terminal snippet (a
# stale recap) via the history.jsonl "Strategy D" fallback (SID-free, most recent /v-prefixed
# line within 30s) — that fallback had NO project scope at all, so any /v-typed line anywhere on the
# machine in the last 30s qualified regardless of which project it belonged to. Fix: Strategy D now
# also requires the history entry's `project` field (the cwd it was typed from) to match the CURRENT
# project root, and rejects any candidate older than an existing session-start marker for this
# project. The session correctly refused in the incident, but burned the run getting there — this
# harness proves the refusal happens up front (source=empty) instead of resolving the wrong task.
set -u
command -v jq >/dev/null 2>&1 && HAVE_JQ=1 || HAVE_JQ=0
[ "$HAVE_JQ" = 1 ] || { echo "SKIP: jq unavailable"; echo "TOTAL: 0 passed, 0 failed (skipped)"; exit 0; }

HERE="$(cd "$(dirname "$0")" && pwd)"
RT="${V_RESOLVE_TASK_SCRIPT:-$HERE/v-resolve-task.sh}"
RT_BAK="$HERE/v-resolve-task.sh.pre-h4-bak"
[ -f "$RT" ] || { echo "SKIP: script-under-test not found ($RT)"; exit 0; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s\n' "$1"; }

SID=c3333333-3333-4333-8333-333333333333
write_history(){ mkdir -p "$1/.claude"; { printf '{"_dummy":"line1 dropped by tail -n +2"}\n'; printf '%s\n' "$2"; } > "$1/.claude/history.jsonl"; }
run_rt(){ # $1=script $2=cwd_project_dir $3=env_sid
  ( cd "$2" 2>/dev/null && env -i HOME="$2" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" \
      CLAUDE_CODE_SESSION_ID="$3" bash "$1" 2>/dev/null )
}
src_of(){ printf '%s' "$1" | sed -n 's/^---TASK-SOURCE=\(.*\)---$/\1/p' | tail -1; }

echo "== H4-13 :: Strategy D history fallback rejects cross-project stale entries =="

# T1: a /v-prefixed entry within the 30s window, but written from a DIFFERENT project (`project`
# field != cwd), with NO sessionId at all (isolates the NEW project-scope guard from the pre-existing
# SID-mismatch guard, which only fires when a sessionId is present). Must resolve to source=empty,
# NEVER surface the cross-project snippet.
# NOTE: `env -i` (used by run_rt below) strips $PWD, so the resolver's own cwd resolution reports the
# PHYSICAL path (macOS: /var/... -> /private/var/...). Canonicalize both fixture dirs via `pwd -P` so
# the `project` field written into history.jsonl matches what the script will actually see.
OTHER_PROJ=$(cd "$(mktemp -d)" && pwd -P)
H=$(cd "$(mktemp -d)" && pwd -P)
_now_ms=$(( $(date +%s) * 1000 ))
write_history "$H" "{\"display\":\"/v STALE-CROSS-PROJECT-SNIPPET-recap\",\"project\":\"$OTHER_PROJ\",\"timestamp\":$_now_ms,\"pastedContents\":{}}"
O=$(run_rt "$RT" "$H" "$SID")
[ "$(src_of "$O")" = "empty" ] \
  && ok "fixed: cross-project /v entry within 30s window -> source=empty (correctly rejected)" \
  || no "fixed: expected source=empty, got '$(src_of "$O")'"
printf '%s' "$O" | grep -q "STALE-CROSS-PROJECT-SNIPPET" \
  && no "fixed: LEAK — the cross-project snippet was surfaced" \
  || ok "fixed: no cross-project leak"

# T2: FP-safe control — the SAME shape but `project` DOES match the current cwd -> Strategy D
# legitimately resolves it (the mechanism must still work for the intended same-project case).
H2=$(cd "$(mktemp -d)" && pwd -P)
write_history "$H2" "{\"display\":\"/v SAME-PROJECT-TASK\",\"project\":\"$H2\",\"timestamp\":$_now_ms,\"pastedContents\":{}}"
O2=$(run_rt "$RT" "$H2" "$SID")
[ "$(src_of "$O2")" = "history-jsonl" ] \
  && ok "FP-safe: same-project /v entry within 30s window still resolves (source=history-jsonl)" \
  || no "FP-safe: same-project entry should still resolve" "got '$(src_of "$O2")'"
printf '%s' "$O2" | grep -q "SAME-PROJECT-TASK" && ok "FP-safe: same-project task body surfaced" \
  || no "FP-safe: same-project task body missing"

echo "-- RED: pre-edit backup has no project scope on Strategy D --"
if [ -f "$RT_BAK" ]; then
  H3=$(cd "$(mktemp -d)" && pwd -P)
  write_history "$H3" "{\"display\":\"/v STALE-CROSS-PROJECT-SNIPPET-recap\",\"project\":\"$OTHER_PROJ\",\"timestamp\":$_now_ms,\"pastedContents\":{}}"
  O3=$(run_rt "$RT_BAK" "$H3" "$SID")
  printf '%s' "$O3" | grep -q "STALE-CROSS-PROJECT-SNIPPET" \
    && ok "backup: cross-project snippet WAS surfaced (confirms the bug pre-fix)" \
    || no "backup: expected the pre-fix leak to reproduce" "got source='$(src_of "$O3")'"
  rm -rf "$H3"
else
  echo "  SKIP: no backup at $RT_BAK"
fi

rm -rf "$OTHER_PROJ" "$H" "$H2"
echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
