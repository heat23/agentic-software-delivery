#!/usr/bin/env bash
# v-trace-span.sh — append-only, fail-open span tracing for /v orchestration.
#
# Usage:
#   v-trace-span.sh start <sid> <span_id> [--repo ROOT] [--parent ID] [--runner NAME] [--mode MODE]
#   v-trace-span.sh end   <sid> <span_id> [--repo ROOT] [--status PASS|FAIL|...] [--artifact PATH]
#
# Contract:
#   - Never blocks /v. All failures exit 0.
#   - Writes JSONL to <repo>/.v/traces/V_TRACE_<sid>.jsonl.
#   - Mirrors best-effort to ~/.claude/runtime/v-trace-<sid>.jsonl.
#   - Does not read artifacts or scan transcripts; analysis happens later.

set -uo pipefail

EVENT="${1:-}"; SID="${2:-}"; SPAN_ID="${3:-}"
shift 3 2>/dev/null || true

REPO="${PROJECT_ROOT:-}"
PARENT="" RUNNER="" MODE="" STATUS="" ARTIFACT="" DETAIL="" SKIP_REASON="" DURATION_MS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 || break ;;
    --parent) PARENT="${2:-}"; shift 2 || break ;;
    --runner) RUNNER="${2:-}"; shift 2 || break ;;
    --mode) MODE="${2:-}"; shift 2 || break ;;
    --status) STATUS="${2:-}"; shift 2 || break ;;
    --artifact) ARTIFACT="${2:-}"; shift 2 || break ;;
    --detail) DETAIL="${2:-}"; shift 2 || break ;;
    --skip-reason) SKIP_REASON="${2:-}"; shift 2 || break ;;
    --duration-ms) DURATION_MS="${2:-}"; shift 2 || break ;;
    *) shift ;;
  esac
done

# Fail-open guardrail.
case "$EVENT" in start|end|instant) ;; *) exit 0 ;; esac
[ -n "$SID" ] && [ -n "$SPAN_ID" ] || exit 0

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd 2>/dev/null || echo "")"
  # LEAK-GUARD (2026-08-02): bare-pwd fallback wrote V_TRACE_*.jsonl into skill source trees
  # under the git-less config dir. Snap a nested non-repo root up; real projects unaffected.
  _vts_cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [ -n "$REPO" ] && [ -n "$_vts_cfg" ] && [ "$REPO" != "$_vts_cfg" ]; then
    case "$REPO" in
      "$_vts_cfg"/*) git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || REPO="$_vts_cfg" ;;
    esac
  fi
fi
[ -n "$REPO" ] || exit 0

TRACE_DIR="$REPO/.v/traces"
mkdir -p "$TRACE_DIR" 2>/dev/null || exit 0
TRACE_FILE="$TRACE_DIR/V_TRACE_${SID}.jsonl"
RUNTIME_DIR="${HOME:-}/.claude/runtime"
RUNTIME_FILE=""
if [ -n "$RUNTIME_DIR" ]; then
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
  RUNTIME_FILE="$RUNTIME_DIR/v-trace-${SID}.jsonl"
fi

python3 - "$TRACE_FILE" "$RUNTIME_FILE" "$EVENT" "$SID" "$SPAN_ID" "$PARENT" "$RUNNER" "$MODE" "$STATUS" "$ARTIFACT" "$DETAIL" "$SKIP_REASON" "$DURATION_MS" "$REPO" "$PWD" "$$" "$PPID" <<'PY' 2>/dev/null || true
import datetime
import json
import os
import sys
import time

trace_file, runtime_file = sys.argv[1], sys.argv[2]
(
    event, sid, span_id, parent, runner, mode, status, artifact, detail,
    skip_reason, duration_ms, repo, cwd, pid, ppid
) = sys.argv[3:18]

now = datetime.datetime.now(datetime.timezone.utc)
obj = {
    "schema_version": 1,
    "event": event,
    "sid": sid,
    "span_id": span_id,
    "phase": span_id.split(":", 1)[0],
    "parent_span_id": parent or None,
    "runner": runner or None,
    "mode": mode or None,
    "status": status or None,
    "artifact": artifact or None,
    "detail": detail or None,
    "skip_reason": skip_reason or None,
    "duration_ms": int(duration_ms) if str(duration_ms).isdigit() else None,
    "timestamp": now.isoformat(timespec="milliseconds").replace("+00:00", "Z"),
    "epoch_ms": int(time.time() * 1000),
    "repo_root": repo or None,
    "cwd": cwd or None,
    "pid": int(pid) if str(pid).isdigit() else None,
    "ppid": int(ppid) if str(ppid).isdigit() else None,
}
line = json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n"
for path in (trace_file, runtime_file):
    if not path:
        continue
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
PY

exit 0
