#!/usr/bin/env python3
"""Profile /v JSONL span traces.

Usage:
  v-profile-trace.py <repo_root> <sid>

Reads <repo_root>/.v/traces/V_TRACE_<sid>.jsonl and prints a compact JSON
summary. This is post-run analysis; it must not be invoked inside hot paths.
"""

from __future__ import annotations

import json
import os
import sys
from collections import Counter, defaultdict


def load_events(path: str) -> list[dict]:
    events: list[dict] = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if isinstance(obj, dict):
                    events.append(obj)
    except OSError:
        pass
    events.sort(key=lambda e: int(e.get("epoch_ms") or 0))
    return events


def interval_overlap(a: tuple[int, int], b: tuple[int, int]) -> int:
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def union_ms(intervals: list[tuple[int, int]]) -> int:
    if not intervals:
        return 0
    merged: list[list[int]] = []
    for start, end in sorted(intervals):
        if end < start:
            continue
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        else:
            merged[-1][1] = max(merged[-1][1], end)
    return sum(end - start for start, end in merged)


def profile(events: list[dict], sid: str, trace_file: str) -> dict:
    starts: dict[str, list[dict]] = defaultdict(list)
    spans: list[dict] = []
    stranded: list[dict] = []

    for event in events:
        kind = event.get("event")
        span_id = event.get("span_id")
        if not isinstance(span_id, str):
            continue
        if kind == "start":
            starts[span_id].append(event)
            continue
        if kind == "end":
            start = starts[span_id].pop(0) if starts.get(span_id) else None
            start_ms = int((start or event).get("epoch_ms") or 0)
            end_ms = int(event.get("epoch_ms") or 0)
            duration = event.get("duration_ms")
            if not isinstance(duration, int):
                duration = max(0, end_ms - start_ms) if start_ms and end_ms else None
            spans.append({
                "span_id": span_id,
                "phase": event.get("phase") or span_id.split(":", 1)[0],
                "runner": event.get("runner") or (start or {}).get("runner"),
                "mode": event.get("mode") or (start or {}).get("mode"),
                "status": event.get("status"),
                "artifact": event.get("artifact") or (start or {}).get("artifact"),
                "start_ms": start_ms or None,
                "end_ms": end_ms or None,
                "duration_ms": duration,
            })

    for span_id, pending in starts.items():
        for event in pending:
            stranded.append({
                "span_id": span_id,
                "phase": event.get("phase") or span_id.split(":", 1)[0],
                "started_at": event.get("timestamp"),
                "runner": event.get("runner"),
            })

    intervals = [
        (int(s["start_ms"]), int(s["end_ms"]))
        for s in spans
        if isinstance(s.get("start_ms"), int) and isinstance(s.get("end_ms"), int)
    ]
    first = min((a for a, _ in intervals), default=None)
    last = max((b for _, b in intervals), default=None)
    total_wall = (last - first) if first is not None and last is not None else 0
    active_wall = union_ms(intervals)
    phase_counts = Counter(str(s.get("phase") or "") for s in spans)
    duplicates = {k: v for k, v in phase_counts.items() if k and v > 1}

    preflight = [s for s in spans if "pre" in str(s.get("phase")) and "flight" in str(s.get("phase"))]
    reviews = [s for s in spans if "review" in str(s.get("phase")) or "codex" in str(s.get("runner"))]
    overlap = 0
    for p in preflight:
        if not isinstance(p.get("start_ms"), int) or not isinstance(p.get("end_ms"), int):
            continue
        for r in reviews:
            if not isinstance(r.get("start_ms"), int) or not isinstance(r.get("end_ms"), int):
                continue
            overlap += interval_overlap((p["start_ms"], p["end_ms"]), (r["start_ms"], r["end_ms"]))

    longest = sorted(
        [
            {
                "span_id": s["span_id"],
                "phase": s["phase"],
                "runner": s.get("runner"),
                "duration_ms": s.get("duration_ms"),
                "status": s.get("status"),
            }
            for s in spans
            if isinstance(s.get("duration_ms"), int)
        ],
        key=lambda s: int(s["duration_ms"]),
        reverse=True,
    )[:10]

    return {
        "sid": sid,
        "trace_file": trace_file,
        "events": len(events),
        "completed_spans": len(spans),
        "stranded_spans": stranded,
        "total_wall_ms": total_wall,
        "active_wall_ms": active_wall,
        # Without a complete dependency DAG, the observed first-start..last-end
        # span is the safest critical-path proxy for wall-clock profiling.
        "critical_path_ms": total_wall,
        "longest_spans": longest,
        "duplicates": duplicates,
        "overlap": {
            "preflight_review_overlap_ms": overlap,
            "preflight_and_review_overlapped": overlap > 0,
        },
    }


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: v-profile-trace.py <repo_root> <sid>", file=sys.stderr)
        return 2
    repo, sid = sys.argv[1], sys.argv[2]
    trace_file = os.path.join(repo, ".v", "traces", f"V_TRACE_{sid}.jsonl")
    events = load_events(trace_file)
    print(json.dumps(profile(events, sid, trace_file), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
