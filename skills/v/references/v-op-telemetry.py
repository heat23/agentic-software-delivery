#!/usr/bin/env python3
"""v-op-telemetry.py — per-OPERATION wall-clock + cached/uncached token telemetry for /v.

WHY (efficiency, 2026-06-29): the existing scanners are per-SESSION — v-cache-burn.py (cache_read
rollup), cost-tally.py ($ by identity), v-batch-health.sh (batch), v-profile-trace.py (per-DISPATCH
spans). None answers "where did the WALL-CLOCK and the EXPENSIVE tokens go, operation by operation."
This does, from the SAME transcript data nothing new is instrumented:
  - per TOOL-CALL wall-clock — pair the assistant `tool_use` line ts with its `tool_result` line ts;
  - per DISPATCH wall-clock+cost — a /v session FORKS via subprocess, so each <sid>/subagents/**.jsonl
    is one dispatch op (its first->last span + canonical cost-tally $/identity);
  - per TURN cached/uncached/cache-write token split + $ — so the inversion (cache_read is ~97% of
    token VOLUME but a minority of $) is finally visible below the session level.

REUSE (single-sourced, NEVER duplicated): pricing from cost-tally.py (PRICES/cost/model_key, the
canonical table); transcript discovery + model-family + session-log-generator exclusion from
v-session-log/references/v-extract-tokens.py; the recursive subagent glob shape from v-cache-burn.py.

CAVEAT encoded in the output: tokens are billed PER TURN, not per tool call — wall-clock attributes
cleanly to individual tools, but token-per-tool would be an estimate (turn-tokens / tool-count). The
token grain here is the TURN; the wall-clock grain is the TOOL. Read-only.

Usage:
  v-op-telemetry.py [TRANSCRIPT_DIR ...] [--sid SID] [--since-hours H] [--top N] [--json] [--no-dedup]
Defaults to all ~/.claude/projects/* (like v-cache-burn). --sid scopes to one session tree.
"""
import sys, os, glob, json, argparse, time, importlib.util, math
from datetime import datetime

_REF = os.path.dirname(os.path.abspath(__file__))


def _load(path, name):
    """Load a hyphenated-filename helper module by path (so PRICES/discovery stay single-sourced)."""
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


# Canonical pricing (cost-tally) + discovery/family/exclusion (v-extract-tokens). Both are pure-function
# modules with a `__main__` guard, so importing has no side effects.
_ct = _load(os.path.join(_REF, "cost-tally.py"), "cost_tally")
_vx = _load(os.path.join(_REF, "..", "..", "v-session-log", "references", "v-extract-tokens.py"),
            "v_extract_tokens")


def _epoch_ms(ts):
    """ISO-8601 (Z or offset) -> epoch milliseconds; None on absence/garbage. Mirrors the
    `ts.replace("Z","+00:00")` idiom in v-batch-health.sh's inline python."""
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp() * 1000.0
    except ValueError:
        return None


def _usage_classes(u):
    """The four billable token classes out of one `message.usage` dict (cache-write split 5m/1h)."""
    c = u.get("cache_creation") or {}
    return dict(
        inp=u.get("input_tokens") or 0,                       # uncached input
        cr=u.get("cache_read_input_tokens") or 0,             # cached read (cheap, dominates VOLUME)
        cw=u.get("cache_creation_input_tokens") or 0,         # cache write (total)
        cw5=c.get("ephemeral_5m_input_tokens") or 0,          # cache write 5m TTL
        cw1=c.get("ephemeral_1h_input_tokens") or 0,          # cache write 1h TTL
        out=u.get("output_tokens") or 0,                      # output (expensive per token)
    )


def scan_transcript(path, dedup=True):
    """Walk ONE transcript file. Returns (turn_rows, tool_rows, span, friction) where span=(first_ms,last_ms)
    and friction={stop_blocks, automode_denials, first_ms} — gate-friction (TEL-1; SREV-002).

    turn_rows: one per assistant message carrying usage — {ts_ms, model, fam, inp, cr, cw, cw5, cw1,
      out, cost}. Deduped by `message.id` last-write-wins (streaming emits progressive partials; the
      final line holds the true totals) — same rule as v-extract-tokens. Unkeyed lines kept as-is.
    tool_rows: one per `tool_use` paired to its following `tool_result` — {tool, wall_ms, is_error}.
      Pairing is by the `toolu_...` id (assistant content[].id -> user content[].tool_use_id).
    """
    turns_by_id, turns_unkeyed = {}, []
    pending = {}      # tool_use_id -> (use_ts_ms, tool_name)
    tool_rows = []
    first_ms = last_ms = None
    stop_blocks = automode_denials = 0    # gate-friction (TEL-1): Stop-hook blocks + auto-mode denials
    # Item 22 (2026-07-03): structured stop_hook_summary counter — see the 2x-overcount note below.
    _structured_stop_blocks = 0
    _structured_stop_seen = False
    friction_ts = []                      # ts of friction events -> earliest = start of the remediation tail
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return [], [], (None, None), dict(stop_blocks=0, automode_denials=0, first_ms=None)
    with f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ts_ms = _epoch_ms(o.get("timestamp"))
            if ts_ms is not None:
                first_ms = ts_ms if first_ms is None else min(first_ms, ts_ms)
                last_ms = ts_ms if last_ms is None else max(last_ms, ts_ms)
            typ = o.get("type")
            msg = o.get("message") or {}
            content = msg.get("content") if isinstance(msg, dict) else None

            # Item 22 (forensic, 2026-07-03): STRUCTURED stop_hook_summary counter, preferred
            # when present. Ground truth confirmed on real transcripts: Claude Code emits ONE
            # {"type":"system","subtype":"stop_hook_summary","hookErrors":[...]} event per ACTUAL Stop
            # hook invocation (hookErrors non-empty = it blocked), but it ALSO surfaces the identical
            # "COMPLETION BLOCKED ..." text a SECOND time as a separate injected 'user' message
            # immediately preceding it in the transcript — a raw substring scan over both counts each
            # real block TWICE (a validated production transcript: 10 raw substring hits, 5
            # stop_hook_summary events with non-empty hookErrors — exactly 2x; the earlier pending
            # generator's `stop_blocks: 6` vs ground-truth 4 stop_hook_summary events / 3 blocking was
            # the same class). Count the structured event instead — it is 1:1 with the real Stop-hook
            # invocation, no matter how many injected message copies of its text Claude Code shows.
            if typ == "system" and o.get("subtype") == "stop_hook_summary":
                _structured_stop_seen = True
                if o.get("hookErrors"):
                    _structured_stop_blocks += 1
                    if ts_ms is not None:
                        friction_ts.append(ts_ms)

            # Legacy fallback (pre-stop_hook_summary transcripts, or any transcript format that never
            # emits the structured event): a Stop-hook block is HARNESS-INJECTED gate feedback — a
            # 'system' message, or a 'user' message that is NOT a tool_result. A real block is never a
            # tool_result, so a Bash output or file read that merely CONTAINS 'COMPLETION BLOCKED' (a
            # meta-repo session grepping a hook source, a command echoing it) is correctly EXCLUDED — the
            # naive "any non-assistant line" rule over-counted ~10 vs 6 on exactly such a session. Auto-mode
            # denials are counted separately below as is_error tool_results. (forensic: 6 real
            # injected blocks; the gate-fight consumed a majority of the run's cost.) The remaining residual is a user
            # literally PASTING the phrase as a typed message — rare, and accepted. ONLY used as the final
            # count when NO structured stop_hook_summary event was seen anywhere in this file (below).
            _is_tr = isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
            if typ in ("system", "user") and not _is_tr and "COMPLETION BLOCKED" in line:
                stop_blocks += 1
                if ts_ms is not None:
                    friction_ts.append(ts_ms)

            if typ == "assistant" and isinstance(msg, dict):
                u = msg.get("usage") or {}
                if isinstance(u.get("output_tokens"), int):
                    cl = _usage_classes(u)
                    fam = _vx._model_family(msg.get("model")) or "other"
                    k = _ct.model_key(msg.get("model"))
                    row = dict(ts_ms=ts_ms, model=msg.get("model"), fam=fam, cost=_ct.cost(k, u), **cl)
                    mid = msg.get("id")
                    if dedup and mid:
                        turns_by_id[mid] = row          # last write wins (streaming final state)
                    else:
                        turns_unkeyed.append(row)
                if isinstance(content, list):
                    for b in content:
                        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("id"):
                            pending[b["id"]] = (ts_ms, b.get("name", "?"))   # guard id-less blocks (malformed transcripts)

            elif typ == "user" and isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        # auto-mode denial (TEL-1): a denied tool call returns an is_error result carrying the
                        # classifier's refusal — distinct from a Stop-hook block, and counted here (not as a
                        # raw substring) so a pasted/quoted denial in plain user text is NOT miscounted.
                        if b.get("is_error"):
                            _bc = b.get("content")
                            try:
                                _bcs = _bc if isinstance(_bc, str) else (json.dumps(_bc) if _bc is not None else "")
                            except (TypeError, ValueError):
                                _bcs = ""   # fail-soft (logic-HIGH): a friction count never justifies crashing the
                                            # scan. _bc is a json.loads sub-value so this is belt-and-suspenders.
                            if "denied by the Claude Code auto mode classifier" in _bcs:
                                automode_denials += 1
                                if ts_ms is not None:
                                    friction_ts.append(ts_ms)
                        _tid = b.get("tool_use_id")
                        use = pending.pop(_tid, None) if _tid else None
                        if use:
                            use_ts, name = use
                            # out-of-order ts (clock skew / NTP) -> None (unmeasurable), never a NEGATIVE wall
                            # that would corrupt sums / sort keys / quantiles (SREV-001 / logic-MED).
                            wall = (ts_ms - use_ts) if (ts_ms is not None and use_ts is not None and ts_ms >= use_ts) else None
                            tool_rows.append(dict(tool=name, wall_ms=wall, is_error=bool(b.get("is_error"))))

    for _tid, (_uts, name) in pending.items():            # tool_use with no captured result
        tool_rows.append(dict(tool=name, wall_ms=None, is_error=False))
    turn_rows = list(turns_by_id.values()) + turns_unkeyed
    # Item 22: prefer the structured stop_hook_summary count (1:1 with real Stop-hook invocations)
    # whenever this file emitted ANY such event — it is never inflated by the duplicate injected-text
    # copy. Fall back to the legacy substring count only for transcripts with no structured events at
    # all (older format), so this never REGRESSES a caller that only ever had the legacy signal.
    _final_stop_blocks = _structured_stop_blocks if _structured_stop_seen else stop_blocks
    friction = dict(stop_blocks=_final_stop_blocks, automode_denials=automode_denials,
                    first_ms=(min(friction_ts) if friction_ts else None))
    return turn_rows, tool_rows, (first_ms, last_ms), friction


def scan_session(top_jsonl, d, dedup=True):
    """A /v session = the parent transcript + its <sid>/subagents/**/*.jsonl forks (v-cache-burn glob).
    Returns dict(sid, turns[], tools[], dispatches[]). Per-turn tokens and per-tool wall-clock aggregate
    ALL files; each subagent file is additionally one `dispatch` operation (span + canonical cost-tally).

    Dedup scope note (CODEX-002): message.id dedup is PER-FILE (scan_transcript makes a fresh map per
    call) rather than session-wide like v-extract-tokens. Safe because message IDs are API-issued per
    request and disjoint across the parent + each subagent — verified by the exact token reconciliation
    with v-extract-tokens. A crafted transcript repeating an id across two files is the only divergence."""
    sid_full = os.path.basename(top_jsonl)[:-6]
    turns, tools, dispatches = [], [], []
    friction = dict(stop_blocks=0, automode_denials=0, first_ms=None)

    def _merge_fr(fr):
        friction["stop_blocks"] += fr["stop_blocks"]
        friction["automode_denials"] += fr["automode_denials"]
        if fr["first_ms"] is not None and (friction["first_ms"] is None or fr["first_ms"] < friction["first_ms"]):
            friction["first_ms"] = fr["first_ms"]

    if not _vx._is_session_log_generator(top_jsonl):
        t, x, _span, fr = scan_transcript(top_jsonl, dedup)
        _merge_fr(fr)
        for r in t:
            r["phase"] = "main_loop"          # the orchestrator's OWN context re-read (the cache_read burn)
        turns += t
        tools += x
    sub = sorted(glob.glob(os.path.join(d, sid_full, "subagents", "**", "*.jsonl"), recursive=True))
    for sf in sub:
        if _vx._is_session_log_generator(sf):
            continue
        t, x, span, fr = scan_transcript(sf, dedup)
        _merge_fr(fr)
        for r in t:
            r["phase"] = "dispatch"           # work done inside a forked subagent
        turns += t
        tools += x
        # The dispatch op: IDENTITY from cost-tally.scan_one (its keyword-proof dispatch-envelope parse),
        # but $/turns from MY message.id-deduped per-turn rows (scan_one's dollars do NOT dedup streaming
        # and over-count ~2.5x) — so every $ figure in this tool is consistently deduped and reconciles
        # with v-extract-tokens. Wall-clock = the subagent transcript's first->last span (the fork has no
        # parent `Task` block to time against in this fork model).
        ident = _ct.scan_one(sf) or {}
        wall_ms = (span[1] - span[0]) if (span[0] is not None and span[1] is not None) else None
        if t:
            dispatches.append(dict(agent=ident.get("ident", "unknown"), model=ident.get("model"),
                                   cls=ident.get("cls"), cost=sum(rr["cost"] for rr in t),
                                   turns=len(t), wall_ms=wall_ms))
    # Remediation tail: turns at/after the FIRST friction event = work spent recovering from a gate block,
    # not making forward progress. (A coarse but honest cut — the tail also includes any real work
    # interleaved after the first block, which a thrashing session has little of.)
    fb = friction["first_ms"]
    rem = [r for r in turns if fb is not None and r.get("ts_ms") is not None and r["ts_ms"] >= fb]
    friction["remediation_turns"] = len(rem)
    friction["remediation_cost"] = sum(r.get("cost", 0) for r in rem)   # defensive (logic-MED)
    return dict(sid=sid_full, turns=turns, tools=tools, dispatches=dispatches, friction=friction)


# ---------------- aggregation + rendering ----------------

def _pct(part, whole):
    return (100.0 * part / whole) if whole else 0.0


def _quantile(vals, q):
    if not vals:
        return 0.0
    s = sorted(vals)
    # nearest-rank: index ceil(q*n)-1, so P90 of 10 values is the 9th, not the max (int(q*n) floor
    # made P90==max for n<=10). Clamped to [0, n-1].
    return s[min(len(s) - 1, max(0, math.ceil(q * len(s)) - 1))]


def _rollup(sessions):
    by_tool = {}            # tool -> list of wall_ms (non-None)
    tool_count = {}         # tool -> count (incl. unpaired)
    cls = dict(inp=0, cr=0, cw=0, cw5=0, cw1=0, out=0)
    dollars = 0.0
    by_agent = {}           # agent -> dict(n, turns, cost, wall_ms)
    by_phase = {}           # main_loop|dispatch -> dict(turns, cost, cr, out)  (coarse v1 — see by_phase note)
    per_session = []
    friction = dict(stop_blocks=0, automode_denials=0, remediation_turns=0, remediation_cost=0.0)
    for s in sessions:
        s_cost = 0.0
        s_cr = 0
        for r in s["turns"]:
            cls["inp"] += r["inp"]; cls["cr"] += r["cr"]; cls["cw"] += r["cw"]   # cw = cache_creation total (fallback)
            cls["cw5"] += r["cw5"]; cls["cw1"] += r["cw1"]; cls["out"] += r["out"]
            dollars += r["cost"]; s_cost += r["cost"]; s_cr += r["cr"]
            ph = by_phase.setdefault(r.get("phase", "main_loop"), dict(turns=0, cost=0.0, cr=0, out=0))
            ph["turns"] += 1; ph["cost"] += r["cost"]; ph["cr"] += r["cr"]; ph["out"] += r["out"]
        s_wall = 0.0
        for t in s["tools"]:
            tool_count[t["tool"]] = tool_count.get(t["tool"], 0) + 1
            if t["wall_ms"] is not None:
                by_tool.setdefault(t["tool"], []).append(t["wall_ms"])
                s_wall += t["wall_ms"]
        for dp in s["dispatches"]:
            a = by_agent.setdefault(dp["agent"], dict(n=0, turns=0, cost=0.0, wall_ms=0.0))
            a["n"] += 1; a["turns"] += dp["turns"]; a["cost"] += dp["cost"]
            if dp["wall_ms"] is not None:                  # a measured 0.0ms span is real, not "unavailable"
                a["wall_ms"] += dp["wall_ms"]
        per_session.append(dict(sid=s["sid"][:8], turns=len(s["turns"]), cost=s_cost,
                                wall_s=s_wall / 1000.0, cr=s_cr))
        fr = s.get("friction") or {}
        friction["stop_blocks"] += fr.get("stop_blocks", 0)
        friction["automode_denials"] += fr.get("automode_denials", 0)
        friction["remediation_turns"] += fr.get("remediation_turns", 0)
        friction["remediation_cost"] += fr.get("remediation_cost", 0.0)
    return dict(by_tool=by_tool, tool_count=tool_count, cls=cls, dollars=dollars,
                by_agent=by_agent, by_phase=by_phase, per_session=per_session, friction=friction)


# $ contribution per class (uses the canonical cost-tally PRICES, opus rates as the upper-bound lens
# would over-state; we instead weight each class by its share of the BLENDED realized $). Simpler and
# exact: recompute class $ from PRICES per family is not available post-aggregation, so we report the
# token VOLUME split precisely and the realized total $; the per-class $ is the volume share * a
# class-relative price weight. To stay exact we instead surface volume% + the realized $ total.
def _summary_dict(agg, sessions, top=8):
    """Compact, embeddable rollup for the SESSION_LOG (`--summary-json`). The FULL per-operation rows
    go to a separate detail file (`--json`); this is the headline view Claude reads inline."""
    c = agg["cls"]
    fr = agg.get("friction") or {}
    _cw = (c["cw5"] + c["cw1"]) or c["cw"]   # top-level cache_creation total as fallback when the 5m/1h split is absent
    vol = c["inp"] + c["cr"] + _cw + c["out"]
    tool_rows = []
    for tool, cnt in agg["tool_count"].items():
        w = agg["by_tool"].get(tool, [])
        tool_rows.append(dict(tool=tool, count=cnt, total_s=round(sum(w) / 1000.0, 1),
                              p90_ms=round(_quantile(w, 0.9)), max_ms=round(max(w) if w else 0)))
    tool_rows.sort(key=lambda r: -r["total_s"])
    disp = [dict(agent=a, n=v["n"], turns=v["turns"], dollars=round(v["cost"], 2),
                 wall_s=round(v["wall_ms"] / 1000.0, 1))
            for a, v in sorted(agg["by_agent"].items(), key=lambda kv: -kv[1]["cost"])]
    total_wall = sum(sum(w) for w in agg["by_tool"].values()) / 1000.0
    return dict(
        totals=dict(sessions=len(sessions),
                    operations=sum(agg["tool_count"].values()) + sum(a["n"] for a in agg["by_agent"].values()),
                    dollars=round(agg["dollars"], 2), tool_wall_clock_s=round(total_wall, 1),
                    cache_read_tokens=c["cr"], output_tokens=c["out"],
                    turns=sum(len(s["turns"]) for s in sessions)),
        by_tool_wallclock=tool_rows[:top],
        by_token_class=dict(cache_read=c["cr"], output=c["out"], input_uncached=c["inp"],
                            cache_write_5m=c["cw5"], cache_write_1h=c["cw1"],
                            cache_read_pct_of_volume=round(_pct(c["cr"], vol), 1),
                            cache_hit_ratio=round(_pct(c["cr"], vol) / 100.0, 3)),
        by_dispatch=disp[:top],
        by_phase=[dict(phase=k, turns=v["turns"], dollars=round(v["cost"], 2),
                       cache_read=v["cr"], output=v["out"])
                  for k, v in sorted(agg["by_phase"].items(), key=lambda kv: -kv[1]["cost"])],
        gate_friction=dict(stop_blocks=fr.get("stop_blocks", 0),
                           automode_denials=fr.get("automode_denials", 0),
                           remediation_turns=fr.get("remediation_turns", 0),
                           remediation_dollars=round(fr.get("remediation_cost", 0.0), 2),
                           remediation_pct_of_dollars=round(_pct(fr.get("remediation_cost", 0.0), agg["dollars"]), 1)),
        note="tokens are billed per TURN (deduped by message.id, matches v-extract-tokens); wall-clock is per TOOL-CALL (tool_use ts -> tool_result ts). cache_read is ~95% of token VOLUME but cheap — the $ live in output + cache_write. gate_friction = Stop-hook blocks + auto-mode denials and the $ spent remediating them (the churn lever).",
    )


def _render(agg, top, sessions):
    out = []
    n_ops = sum(agg["tool_count"].values()) + sum(a["n"] for a in agg["by_agent"].values())
    out.append("== v-op-telemetry :: %d sessions, %d operations, $%.2f ==" % (len(sessions), n_ops, agg["dollars"]))

    out.append("\n-- by tool type (wall-clock; ms) --")
    out.append("  %-22s %6s %10s %8s %8s %9s" % ("tool", "count", "total_s", "p50_ms", "p90_ms", "max_ms"))
    rows = []
    for tool, cnt in agg["tool_count"].items():
        w = agg["by_tool"].get(tool, [])
        rows.append((sum(w), tool, cnt, _quantile(w, 0.5), _quantile(w, 0.9), max(w) if w else 0))
    for total, tool, cnt, p50, p90, mx in sorted(rows, reverse=True)[:top]:
        out.append("  %-22s %6d %10.1f %8.0f %8.0f %9.0f" % (tool, cnt, total / 1000.0, p50, p90, mx))

    out.append("\n-- by token class (volume + cache-hit) --")
    c = agg["cls"]
    _cw = (c["cw5"] + c["cw1"]) or c["cw"]   # top-level cache_creation total as fallback when the 5m/1h split is absent
    vol = c["inp"] + c["cr"] + _cw + c["out"]
    for label, key in (("cache_read (cached)", "cr"), ("output", "out"),
                       ("input (uncached)", "inp"), ("cache_write 5m", "cw5"), ("cache_write 1h", "cw1")):
        out.append("  %-20s %12sM  %5.1f%% of volume" % (label, "%.1f" % (c[key] / 1e6), _pct(c[key], vol)))
    cr_share = _pct(c["cr"], vol)
    out.append("  cache-hit ratio: %.3f   (cache_read is %.0f%% of token VOLUME — but cheap; the $ live in output/cache_write)"
               % (cr_share / 100.0, cr_share))

    out.append("\n-- by dispatch (subagent identity) --")
    out.append("  %-42s %3s %7s %9s %8s" % ("agent", "n", "turns", "$", "wall_s"))
    for agent, a in sorted(agg["by_agent"].items(), key=lambda kv: -kv[1]["cost"])[:top]:
        out.append("  %-42s %3d %7d %9.2f %8.1f" % (agent[:42], a["n"], a["turns"], a["cost"], a["wall_ms"] / 1000.0))

    out.append("\n-- by phase (main-loop vs dispatch; coarse v1) --")
    out.append("  %-12s %7s %9s %14s %10s" % ("phase", "turns", "$", "cache_read_M", "output_K"))
    for ph, v in sorted(agg["by_phase"].items(), key=lambda kv: -kv[1]["cost"]):
        out.append("  %-12s %7d %9.2f %14.1f %10.0f" % (ph, v["turns"], v["cost"], v["cr"] / 1e6, v["out"] / 1e3))

    fr = agg.get("friction") or {}
    if fr.get("stop_blocks") or fr.get("automode_denials"):
        out.append("\n-- gate friction (the churn lever) --")
        out.append("  %d Stop-hook blocks · %d auto-mode denials · post-first-block: %d turns, $%.2f (%.0f%% of $)"
                   % (fr.get("stop_blocks", 0), fr.get("automode_denials", 0), fr.get("remediation_turns", 0),
                      fr.get("remediation_cost", 0.0), _pct(fr.get("remediation_cost", 0.0), agg["dollars"])))

    out.append("\n-- per session (top by $) --")
    out.append("  %-8s %6s %9s %8s %12s" % ("sid", "turns", "$", "wall_s", "cache_read_M"))
    for r in sorted(agg["per_session"], key=lambda r: -r["cost"])[:top]:
        out.append("  %-8s %6d %9.2f %8.1f %12.1f" % (r["sid"], r["turns"], r["cost"], r["wall_s"], r["cr"] / 1e6))
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dirs", nargs="*", help="transcript dir(s); default = all ~/.claude/projects/*")
    ap.add_argument("--sid", help="scope to one session tree (uses v-extract-tokens discovery)")
    ap.add_argument("--since-hours", type=float, default=0)
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--json", action="store_true", help="emit raw per-operation rows as JSON (the detail file)")
    ap.add_argument("--summary-json", action="store_true", help="emit the compact embeddable rollup as JSON (for the SESSION_LOG)")
    ap.add_argument("--no-dedup", action="store_true", help="do not dedup turns by message.id (match v-cache-burn/cost-tally)")
    a = ap.parse_args()
    dedup = not a.no_dedup
    cfg = os.path.join(os.environ.get("HOME") or os.path.expanduser("~"), ".claude")

    sessions = []
    if a.sid:
        _vx._validate_sid(a.sid)
        # group the sid's transcripts under their containing project dir, then scan as one session
        d = None
        for p in _vx._find_transcripts(a.sid, cfg):
            if p.endswith(f"{a.sid}.jsonl"):
                d = os.path.dirname(p)
                sessions.append(scan_session(p, d, dedup))
                break
        if not sessions:
            print("no top-level transcript for sid", a.sid); return 1
    else:
        dirs = a.dirs or [d for d in glob.glob(os.path.join(cfg, "projects", "*")) if os.path.isdir(d)]
        cutoff = (time.time() - a.since_hours * 3600) if a.since_hours else 0
        for d in dirs:
            for f in glob.glob(os.path.join(d, "*.jsonl")):
                if cutoff and os.path.getmtime(f) < cutoff:
                    continue
                s = scan_session(f, d, dedup)
                if s["turns"] or s["dispatches"]:
                    sessions.append(s)

    if not sessions:
        print("no transcripts with usage data found")
        return 0
    if a.json:
        print(json.dumps(sessions, indent=2))
        return 0
    agg = _rollup(sessions)
    if a.summary_json:
        print(json.dumps(_summary_dict(agg, sessions)))
        return 0
    print(_render(agg, a.top, sessions))
    return 0


if __name__ == "__main__":
    sys.exit(main())
