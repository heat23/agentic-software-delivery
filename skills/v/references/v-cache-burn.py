#!/usr/bin/env python3
"""v-cache-burn.py — the MISSING telemetry consumer: per-session MAIN-LOOP cache_read burn.

WHY (efficiency, 2026-06-24): cost-tally.py / gate-cost.py / v-telemetry-aggregate.sh all sum the
per-DISPATCH subprocess cost (claude -p reviewers) — a small slice. The DOMINANT spend is the
orchestrator's OWN main-loop cache_read: ~97% of all tokens, ~100K re-read EVERY turn x ~170 turns/
session. At fleet scale that is billions of cache_read tok/day — invisible until now because nothing reads
`usage.cache_read_input_tokens` out of the session transcripts. This does. Read-only.

Usage:
  v-cache-burn.py [TRANSCRIPT_DIR ...] [--top N] [--since-hours H] [--packs-per-day P]
Defaults to every project transcript dir under ~/.claude/projects. Pass --packs-per-day to
project the daily burn from the measured per-session average.
"""
import sys, os, glob, json, argparse, time

def session_usage(path):
    cr = cw = out = inp = turns = 0
    last = 0.0
    try:
        for line in open(path, encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            u = (o.get("message") or {}).get("usage") or {}
            if u:
                cr += u.get("cache_read_input_tokens") or 0
                cw += u.get("cache_creation_input_tokens") or 0
                out += u.get("output_tokens") or 0
                inp += u.get("input_tokens") or 0
                turns += 1
    except OSError:
        return None
    # RC-5 (2026-06-26): do NOT drop a zero-turn parent here. A /v FORK orchestrator's real turns live under
    # <sid>/subagents/, so the parent JSONL is frequently 0-turn; the caller accumulates the subagent burn and
    # then filters on the COMBINED turn count. (A genuinely empty transcript is filtered there, post-accumulation.)
    return dict(cr=cr, cw=cw, out=out, inp=inp, turns=turns, mtime=os.path.getmtime(path))

def default_dirs():
    base = os.path.expanduser("~/.claude/projects")
    # prefer real project dirs (skip the doubly-nested -claude-projects- artifacts)
    cand = [d for d in glob.glob(os.path.join(base, "*")) if os.path.isdir(d)]
    return cand

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*", help="transcript dir(s); default = all ~/.claude/projects/*")
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--since-hours", type=float, default=0, help="only sessions modified in the last H hours")
    ap.add_argument("--packs-per-day", type=float, default=0, help="project daily burn from the per-session avg")
    a = ap.parse_args()
    dirs = a.dirs or default_dirs()
    cutoff = (time.time() - a.since_hours * 3600) if a.since_hours else 0
    rows = []
    for d in dirs:
        for f in glob.glob(os.path.join(d, "*.jsonl")):
            if cutoff and os.path.getmtime(f) < cutoff:
                continue
            u = session_usage(f)
            if u is None:
                continue
            # RC-5 (2026-06-26): a /v session FORKS — the orchestrator's real turns + cache_read live under
            # <sid>/subagents/**.jsonl, NOT the parent transcript (often 0-turn). Accumulate them so a forked /v
            # session isn't undercounted by an order of magnitude (one observed fork: parent a few hundred turns vs subagents thousands),
            # and so a 0-parent-turn fork still surfaces at all.
            sid_full = os.path.basename(f)[:-6]
            for sf in glob.glob(os.path.join(d, sid_full, "subagents", "**", "*.jsonl"), recursive=True):
                su = session_usage(sf)
                if su:
                    for k in ("cr", "cw", "out", "inp", "turns"):
                        u[k] += su[k]
            if u["turns"]:
                u["sid"] = os.path.basename(f)[:8]
                rows.append(u)
    if not rows:
        print("no transcripts with usage data found under:", dirs)
        return 0
    tcr = sum(r["cr"] for r in rows); tcw = sum(r["cw"] for r in rows)
    tout = sum(r["out"] for r in rows); tturns = sum(r["turns"] for r in rows)
    denom = tcr + tcw + tout + sum(r["inp"] for r in rows)
    print("== v-cache-burn :: %d sessions ==" % len(rows))
    print("  cache_READ   : %8.0fM  (%.0f%% of all tokens — the burn)" % (tcr/1e6, 100*tcr/denom if denom else 0))
    print("  cache_CREATE : %8.0fM" % (tcw/1e6))
    print("  output       : %8.1fM" % (tout/1e6))
    print("  per session  : cache_read=%.1fM  turns=%.0f  cache_read/turn=%.0fK" %
          (tcr/len(rows)/1e6, tturns/len(rows), tcr/tturns/1e3 if tturns else 0))
    if a.packs_per_day:
        print("  PROJECTED    : %.2fB cache_read tok/day at %g packs/day" %
              (a.packs_per_day * tcr/len(rows) / 1e9, a.packs_per_day))
    rows.sort(key=lambda r: -r["cr"])
    print("  top %d sessions by cache_read:" % a.top)
    for r in rows[:a.top]:
        print("    %s  cache_read=%6.1fM  turns=%4d  cr/turn=%4.0fK  output=%4.0fK" %
              (r["sid"], r["cr"]/1e6, r["turns"], r["cr"]/r["turns"]/1e3, r["out"]/1e3))
    return 0

if __name__ == "__main__":
    sys.exit(main())
