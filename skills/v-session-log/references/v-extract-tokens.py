#!/usr/bin/env python3
"""
Canonical session token extractor for v-session-log (C9 Phase 1).

Scans the session transcript tree for <SID> and emits structured output lines:
  SET token_cost.by_model: {"sonnet": ..., "haiku": ..., "opus": ...}
  SET token_cost.total: <int>               # input + cache_creation + output (NOT cache_read)
  SET token_cost.cache_read_tokens: <int>   # cache_read_input_tokens tracked separately
  SET token_cost.audit: {json}              # forensic metadata (files_scanned, messages_deduped, ...)

Deduplication: assistant messages with the same message.id (Anthropic API message ID)
are deduplicated — the LAST occurrence wins (streaming writes progressive partial counts;
the final line has the true totals). messages_deduped counts discarded duplicates.

Exclusion: the v-session-log generator's own LIVE, self-referential subagent transcript is
excluded (detected by the harness self-invocation preamble co-occurring with the skill's own
ANTI-BAIL banner text in the first few user turns — same guard intent as the validator's
_wperf10_transcript_is_session_log_generator). C-6 (2026-07-02): a bare path-substring match
here previously also excluded unrelated forks that merely MENTION a v-session-log file path in
their task (e.g. a maintenance fork fixing this very file) — narrowed to require the banner.

ACCOUNTING BOUNDARY (forensic 2026-07-10 #2 — the phantom output-token
discrepancy"): these totals are TRANSCRIPT-SCOPED — the parent <sid>.jsonl plus everything under
<sid>/subagents/ (Agent-TOOL dispatches, which DO persist). They DELIBERATELY EXCLUDE
`claude -p --agent` gate-runner/reviewer dispatches (pre-flight, verify-done, QA, codex): those
run with `--no-session-persistence` (v-dispatch-subagent.sh:505) and leave NO transcript on disk,
so they are structurally invisible here. Their spend is captured separately as `cost_usd` per row
in DISPATCH_PROVENANCE_<sid>.log. So a per-session output-token count that looks "low" relative to
a dollar figure that DID fold in dispatch cost is EXPECTED, not a fabrication — do not "reconcile"
the two by inflating this count. A future unified-cost view should ADD the provenance cost_usd sum
as its OWN field rather than trying to back-fill non-existent transcript tokens.

Usage:  python3 v-extract-tokens.py <SID> [<config_dir>]
Exit:   0 = success (at least one usable transcript found and emitted)
        1 = no usable transcript found for <SID>
"""

import glob
import json
import os
import re
import sys

# P0-batch hardening (forensic 2026-06-04): a wildcard/garbage SID turns the
# per-SID globs into a whole-projects-tree sweep — one session's log recorded tokens
# aggregated from hundreds of unrelated transcripts. The hazard is GLOB METACHARACTERS and
# trivially-short junk, not strict hexness (synthetic test SIDs are legitimate): require
# >=8 chars of lowercase alphanumerics/dashes only — a literal like that can only ever
# match its own session tree.
_SID_SHAPE = re.compile(r"^[0-9a-z][0-9a-z-]{7,}$")
# A single session tree is <sid>.jsonl + its subagents — dozens at the extreme. Hundreds
# means the glob escaped the SID scope; refuse rather than aggregate foreign sessions.
_MAX_FILES = 50


def _validate_sid(sid):
    """Exit 2 with a loud message when the SID cannot be a session id (glob metachars,
    too short, non-hex). This is what turned a per-SID scan into a whole-tree sweep."""
    if not isinstance(sid, str) or not _SID_SHAPE.match(sid):
        print(
            f"v-extract-tokens: REFUSING sid={sid!r} — not a session id (need >=8 leading "
            f"lowercase-hex chars, only [0-9a-f-], no glob metacharacters). A wildcard/garbage "
            f"SID sweeps the ENTIRE projects tree and aggregates every session's tokens "
            f"(forensic 2026-06-04: hundreds of files aggregated). Pass the exact session UUID.",
            file=sys.stderr,
        )
        sys.exit(2)


def _model_family(model_str):
    if not isinstance(model_str, str):
        return None
    m = model_str.lower()
    if "opus" in m:
        return "opus"
    if "sonnet" in m:
        return "sonnet"
    if "haiku" in m:
        return "haiku"
    return None


def _find_transcripts(sid, cfg):
    proj = os.path.join(cfg, "projects")
    paths = set(glob.glob(os.path.join(proj, "*", f"{sid}.jsonl")))
    paths.update(glob.glob(os.path.join(proj, "*", sid, "**", "*.jsonl"), recursive=True))
    return sorted(paths)


def _is_session_log_generator(path):
    """True if this transcript belongs to the v-session-log skill's own LIVE, self-referential
    run (the logging tool analyzing its own still-writing parent session) — not merely a fork
    whose task happens to mention a v-session-log file path.

    C-6 (handoff-3, 2026-07-02): the prior version matched a bare substring ("skills/v-session-log"
    or "skill: v-session-log" anywhere in the first few user turns). That also matched any
    UNRELATED fork doing real coding work that mentions a v-session-log file path in its task
    text (e.g. "fix skills/v-session-log/references/v-extract-tokens.py" — exactly the shape of
    a maintenance session on this very file). That fork's real, complete, billed token usage then
    silently vanished from the session's total (verified against a real transcript tree: a
    legitimate "log-writer" fork's real cache_read tokens were dropped this way).

    FIX: require the harness-injected self-invocation signature to co-occur with the skill's own
    ANTI-BAIL banner text (unique to v-session-log/SKILL.md's own body, line 1 after frontmatter)
    in the SAME early-turn text — this combination only appears when v-session-log is genuinely
    invoked as a forked Skill, never when a file path is merely referenced in passing. Identical
    guard intent to the validator's _wperf10_transcript_is_session_log_generator."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            checked = 0
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except ValueError:
                    continue
                if obj.get("type") != "user":
                    continue
                msg = obj.get("message") or {}
                content = msg.get("content") if isinstance(msg, dict) else None
                texts = []
                if isinstance(content, str):
                    texts.append(content)
                elif isinstance(content, list):
                    for it in content:
                        if isinstance(it, dict) and isinstance(it.get("text"), str):
                            texts.append(it["text"])
                for t in texts:
                    _mentions_path = "skills/v-session-log" in t or "skill: v-session-log" in t
                    _self_invocation_banner = "running INSIDE the forked skill" in t
                    if _mentions_path and _self_invocation_banner:
                        return True
                checked += 1
                if checked >= 4:
                    break
    except OSError:
        pass
    return False


def extract(sid, cfg):
    """Scan the session transcript tree for <sid> and return token accounting.

    Returns a dict with:
      by_model: {sonnet, haiku, opus} — input+cache_creation+output per recognized family
      total: int — sum of input+cache_creation+output across ALL turns (including 'other' family)
      cache_read_tokens: int — cache_read_input_tokens summed (tracked separately from total)
      files_scanned: int
      assistant_messages_count: int — turn count after dedup (keyed messages deduped by message.id; unkeyed
        messages without a message.id are counted as-is, not deduped — old-format/top-level events appear once
        per physical line so this is accurate in practice). Fork-aware (counts the parent + all subagents).
      messages_deduped: int — duplicate message.id lines discarded
      token_components_total: {input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}

    Returns None if no usable transcript is found.
    """
    # Keyed by message.id -> last-seen (fam, inp_combined, out, cc, raw_inp, cr)
    # inp_combined = input_tokens + cache_creation_input_tokens
    by_msg_id = {}
    unkeyed = []   # messages without a message.id (old Claude Code format / top-level events)
    files_scanned = 0
    files_used = []  # provenance: exactly which transcripts produced these numbers
    total_lines_with_id = 0  # for computing messages_deduped

    candidates = _find_transcripts(sid, cfg)
    if len(candidates) > _MAX_FILES:
        print(
            f"v-extract-tokens: REFUSING — {len(candidates)} transcript files matched "
            f"sid={sid!r} (cap {_MAX_FILES}). A single session tree is <sid>.jsonl + its "
            f"subagents; hundreds of matches means the scope escaped the SID (forensic "
            f"2026-06-04: hundreds of files aggregated into one session's log). Verify the SID.",
            file=sys.stderr,
        )
        sys.exit(2)

    for p in candidates:
        if _is_session_log_generator(p):
            continue
        try:
            with open(p, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except ValueError:
                        continue
                    if obj.get("type") != "assistant":
                        continue
                    msg = obj.get("message") or {}
                    usage = msg.get("usage") or {}
                    out = usage.get("output_tokens")
                    if not isinstance(out, int):
                        continue
                    fam = _model_family(msg.get("model"))
                    raw_inp = usage.get("input_tokens") or 0
                    cc = usage.get("cache_creation_input_tokens") or 0
                    cr = usage.get("cache_read_input_tokens") or 0
                    inp_combined = raw_inp + cc
                    entry = (fam, inp_combined, out, cc, raw_inp, cr)
                    msg_id = msg.get("id")
                    if msg_id:
                        total_lines_with_id += 1
                        by_msg_id[msg_id] = entry  # last write wins (streaming final state)
                    else:
                        unkeyed.append(entry)
            files_scanned += 1
            files_used.append(os.path.relpath(p, cfg) if p.startswith(cfg) else p)
        except OSError:
            continue

    all_entries = list(by_msg_id.values()) + unkeyed
    if not all_entries:
        return None

    messages_deduped = total_lines_with_id - len(by_msg_id)

    fam_totals = {}   # recognized family -> input+cache_creation+output
    comp_input = 0
    comp_output = 0
    comp_cc = 0
    comp_cr = 0

    for (fam, inp_combined, out, cc, raw_inp, cr) in all_entries:
        comp_input += raw_inp
        comp_output += out
        comp_cc += cc
        comp_cr += cr
        bucket = fam if fam else "other"
        fam_totals[bucket] = fam_totals.get(bucket, 0) + inp_combined + out

    # total = input + cache_creation + output across ALL turns (excludes cache_read).
    # cache_read_input_tokens are tracked separately — they are cheap prompt-cache reads
    # that are often 10–100x larger than total and would make the number misleading.
    total = comp_input + comp_cc + comp_output

    by_model = {k: fam_totals.get(k) for k in ("sonnet", "haiku", "opus")}
    # Include "other" key when unrecognized model families generated tokens (item 10).
    # This makes the "other" bucket visible in the by_model output so operators can
    # investigate unknown variants rather than have them silently inflate the total.
    if fam_totals.get("other"):
        by_model["other"] = fam_totals["other"]

    return {
        "by_model": by_model,
        "total": total,
        "cache_read_tokens": comp_cr,
        "files_scanned": files_scanned,
        "files": files_used,
        "assistant_messages_count": len(all_entries),
        "messages_deduped": messages_deduped,
        "token_components_total": {
            "input_tokens": comp_input,
            "output_tokens": comp_output,
            "cache_creation_input_tokens": comp_cc,
            "cache_read_input_tokens": comp_cr,
        },
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: v-extract-tokens.py <SID> [<config_dir>]", file=sys.stderr)
        sys.exit(1)

    sid = sys.argv[1]
    _validate_sid(sid)
    cfg = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(
            os.environ.get("HOME") or os.path.expanduser("~"), ".claude"
        )
    )

    result = extract(sid, cfg)
    if result is None:
        print(f"No usable transcript found for SID={sid!r}", file=sys.stderr)
        sys.exit(1)

    audit = {
        "files_scanned": result["files_scanned"],
        "files": result["files"][:20],  # provenance: which transcripts produced these numbers
        "assistant_messages_count": result["assistant_messages_count"],
        "messages_deduped": result["messages_deduped"],
        "token_components_total": result["token_components_total"],
    }

    print(f"SET token_cost.by_model: {json.dumps(result['by_model'])}")
    print(f"SET token_cost.total: {result['total']}")
    print(f"SET token_cost.cache_read_tokens: {result['cache_read_tokens']}")
    print(f"SET token_cost.turns: {result['assistant_messages_count']}")  # T-A: fork-aware turn count (subagents incl.) -> session.turn_count_end
    print(f"SET token_cost.audit: {json.dumps(audit)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
