#!/usr/bin/env python3
# cost-tally.py — THE canonical /v fleet cost+attribution tally (telemetry G4+G6, 2026-06-21).
#
# WHY THIS IS THE ONLY METHOD: the verify-done cost investigation produced THREE different totals from the
# SAME data and one catastrophic mislabel (a large "verify-done" cost that was actually the
# /v orchestrator fork) because every ad-hoc analysis (a) globbed only top-level *.jsonl and silently dropped
# the 67% of spend living in <sid>/subagents/, (b) classified agent identity by keyword-matching the prompt
# body (which hits "verify-done" in the orchestrator's 130KB SKILL.md boilerplate), and (c) trusted the report
# self-tag "Model: haiku" instead of the billed model. This script removes all three failure modes by
# construction. Run it; do not re-derive a tally by hand.
#
# RULES (G4 — non-negotiable, enforced below):
#  - MODEL is ALWAYS .message.model from the transcript usage records — NEVER a report self-tag or dispatch param.
#  - COVERAGE is ALWAYS top-level *.jsonl (main) PLUS */subagents/*.jsonl (subagents) — a partial glob is a bug.
#  - IDENTITY is the skill/agent the transcript IS, parsed deterministically from its dispatch envelope, then
#    cross-checked against the TOOL-WHITELIST (an Edit/Write/MultiEdit/Agent-bearing transcript is NOT a
#    read-only runner like v-verify-done-runner, regardless of what its prompt says).
#
# Output: deterministic JSON to stdout (AI-parseable). --pretty for a terse table too.
# Pricing is centralised here (confirmed via the claude-api skill 2026-06-04); tokens are the ground truth,
# dollars are derived — update PRICES here if rates change, never bake prices into producers.
import json, glob, os, re, sys, collections

PRICES = {  # $/token
    'opus':   dict(i=5e-6,  o=25e-6, cr=0.5e-6, cw5=6.25e-6, cw1=10e-6),
    'sonnet': dict(i=3e-6,  o=15e-6, cr=0.3e-6, cw5=3.75e-6, cw1=6e-6),
    'haiku':  dict(i=1e-6,  o=5e-6,  cr=0.1e-6, cw5=1.25e-6, cw1=2e-6),
    'other':  dict(i=3e-6,  o=15e-6, cr=0.3e-6, cw5=3.75e-6, cw1=6e-6),
}
def model_key(m):
    m = (m or '').lower()
    return 'opus' if 'opus' in m else 'sonnet' if 'sonnet' in m else 'haiku' if 'haiku' in m else 'other'
def cost(k, u):
    p = PRICES[k]; c = u.get('cache_creation') or {}
    return ((u.get('input_tokens', 0) or 0) * p['i'] + (u.get('output_tokens', 0) or 0) * p['o']
            + (u.get('cache_read_input_tokens', 0) or 0) * p['cr']
            + (c.get('ephemeral_5m_input_tokens', 0) or 0) * p['cw5']
            + (c.get('ephemeral_1h_input_tokens', 0) or 0) * p['cw1'])

SKILL_RE = re.compile(r'Base directory for this skill:\s*\S*/skills/([A-Za-z0-9_-]+)')
YOUARE_RE = re.compile(r'You are ([a-z0-9]+(?:-[a-z0-9]+)+)', re.I)  # M5: require a HYPHENATED agent token (codex-adversarial-reviewer / v-verify-done-runner), not bare articles/gerunds (a / autonomous / auditing)
EDIT_TOOLS = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit'}
DISPATCH_TOOLS = {'Agent', 'Task'}

# C3 (TEL-1 fix, 2026-06-21): an Edit/Write to the agent's OWN report/artifact is NOT a SOURCE edit. The
# read-only-on-SOURCE runners (v-qa-reviewer, v-workflow-verifier) are contractually permitted to Write their
# report (QA_REPORT / WORKFLOW_VERIFICATION / ...) and v-workflow-verifier writes tests/e2e specs. Counting
# those as 'edits' made !MISLABEL a 0%-precision false positive (128 flagged transcripts = 128 legitimate
# report-writes, 0 real source edits). A SOURCE edit targets a file that is NOT a gauntlet artifact, NOT under
# .v/, and NOT a tests/e2e spec / playwright config. A MISSING path is treated as non-source (never
# manufacture a !MISLABEL from an unknown target — keep the guard's precision at the cost of recall).
ARTIFACT_BASENAME_RE = re.compile(
    r'^(QA_REPORT|PRE_FLIGHT_REPORT|VERIFY_DONE_REPORT|WORKFLOW_VERIFICATION|UX_CRITIQUE|IMPACT_MAP'
    r'|AGENT_REVIEW|IMPLEMENTATION_REPORT|MERGE_ALL_REPORT|SESSION_LOG|HANDOFF|BLOCKED|TRIVIAL_PASS'
    r'|PLANNING_PASS|DISPATCH_PROVENANCE|MERGE_PENDING|GAUNTLET_SKIPPED|CYCLE_CAP_HANDOFF|BITE_LEDGER)', re.I)
def _is_artifact_write(path):
    if not path:
        return True  # unknown target -> cannot prove a SOURCE edit; do not manufacture a !MISLABEL
    if '/.v/' in path or path.startswith('.v/'):
        return True
    if 'tests/e2e/' in path or path.endswith('.spec.ts') or path.endswith('.spec.tsx') or 'playwright.config' in path:
        return True
    return bool(ARTIFACT_BASENAME_RE.search(os.path.basename(path)))

def classify(lines, tools, source_edits=0):
    """Deterministic identity + class. Identity from the dispatch envelope; class from the TOOL-WHITELIST
    (what the transcript actually DID), which overrides a misleading prompt body."""
    head = '\n'.join(lines[:40])  # M5: the dispatch-envelope identity marker can sit past line 8
    ident = 'unknown'
    m = SKILL_RE.search(head)
    if m:
        ident = 'skill:' + m.group(1)
    else:
        m = YOUARE_RE.search(head)
        if m:
            ident = 'agent:' + m.group(1)[:32]
    edits = sum(tools.get(t, 0) for t in EDIT_TOOLS)
    dispatches = sum(tools.get(t, 0) for t in DISPATCH_TOOLS)
    if ident == 'skill:v' or dispatches >= 3 or source_edits >= 10:  # review LOW: SOURCE edits (not report-writes) signal a heavy fork
        cls = 'orchestrator-fork'
    elif source_edits > 0:          # C3: a transcript that only WROTE ITS OWN REPORT is read-only-on-source
        cls = 'impl-or-edit'
    else:
        cls = 'readonly'
    # TOOL-WHITELIST cross-check: a transcript that edited/dispatched CANNOT be a declared read-only runner —
    # this is the exact guard that would have caught the "verify-done" cost mislabel (orchestrator forks with
    # 4,708 Edits swept into the verify-done bucket by a keyword scan). Matches skill: and agent: forms.
    _runner_markers = ('verify-done', 'pre-flight', 'qa-reviewer', 'ux-critique', 'workflow-verifier')
    if any(rm in ident for rm in _runner_markers) and (source_edits or dispatches):  # C3: SOURCE edits, not report-writes
        ident = ident + '!MISLABEL(edited/dispatched)'
    return ident, cls

def scan_one(fp):
    try:
        lines = open(fp, encoding='utf-8', errors='replace').read().splitlines()
    except OSError:
        return None
    tools = collections.Counter()
    source_edits = 0  # C3: edits to NON-artifact (source) paths only
    cat = collections.Counter()
    bymodel = collections.Counter()  # M4: per-model dollars (a transcript can switch model mid-run)
    model = None
    for ln in lines:
        if '"usage"' not in ln and '"tool_use"' not in ln:
            continue
        try:
            o = json.loads(ln)
        except ValueError:
            continue
        msg = o.get('message') or {}
        if isinstance(msg.get('content'), list):
            for b in msg['content']:
                if isinstance(b, dict) and b.get('type') == 'tool_use':
                    nm = b.get('name', '?')
                    tools[nm] += 1
                    if nm in EDIT_TOOLS:
                        _inp = b.get('input') or {}
                        _p = _inp.get('file_path') or _inp.get('notebook_path') or ''
                        if not _is_artifact_write(_p):
                            source_edits += 1
        u = msg.get('usage'); mdl = msg.get('model')
        if u and mdl:
            k = model_key(mdl); model = mdl
            _c = cost(k, u)
            cat['turns'] += 1; cat['$'] += _c; bymodel[k] += _c
            for f, key in (('input_tokens', 'in'), ('output_tokens', 'out'),
                           ('cache_read_input_tokens', 'cr'), ('cache_creation_input_tokens', 'cw')):
                cat[key] += u.get(f, 0) or 0
    ident, cls = classify(lines, tools, source_edits)
    # M4: bucket by the DOMINANT model (max $); expose per-model dollars so by_bucket_model is EXACT
    # (an opus-then-haiku transcript no longer mis-attributes its opus spend to haiku).
    dominant = max(bymodel, key=bymodel.get) if bymodel else 'other'
    return dict(model=dominant, model_raw=model, ident=ident, cls=cls,
                turns=cat['turns'], dollars=cat['$'], by_model=dict(bymodel),
                tok=dict(inp=cat['in'], out=cat['out'], cr=cat['cr'], cw=cat['cw']))

def tally(project_dir):
    main = sorted(glob.glob(os.path.join(project_dir, '*.jsonl')))
    # H3 (SME review 2026-06-21): transcripts nest at ANY depth under subagents/ — e.g.
    # <sid>/subagents/workflows/wf_*/agent-*.jsonl — so a single-level glob silently dropped ~8% of spend.
    # Recurse. (main is top-level *.jsonl, never under subagents/, so no overlap to dedup.)
    sub = sorted(glob.glob(os.path.join(project_dir, '**', 'subagents', '**', '*.jsonl'), recursive=True))
    out = dict(files=dict(main=len(main), subagents=len(sub), total=len(main) + len(sub)),
               by_bucket_model=collections.defaultdict(float),
               by_identity=collections.defaultdict(lambda: dict(dollars=0.0, n=0, turns=0)),
               main_dollars=0.0, subagent_dollars=0.0)
    for bucket, files in (('main', main), ('subagents', sub)):
        for fp in files:
            r = scan_one(fp)
            if not r or r['turns'] == 0:
                continue
            for _mk, _d in r['by_model'].items():   # M4: EXACT per-model attribution (not last-seen model)
                out['by_bucket_model'][f'{bucket}|{_mk}'] += _d
            if bucket == 'main':
                out['main_dollars'] += r['dollars']
            else:
                out['subagent_dollars'] += r['dollars']
                key = f'{r["ident"]}|{r["model"]}|{r["cls"]}'
                out['by_identity'][key]['dollars'] += r['dollars']
                out['by_identity'][key]['n'] += 1
                out['by_identity'][key]['turns'] += r['turns']
    out['grand_total'] = out['main_dollars'] + out['subagent_dollars']
    out['by_bucket_model'] = dict(sorted(out['by_bucket_model'].items(), key=lambda x: -x[1]))
    out['by_identity'] = dict(sorted(out['by_identity'].items(), key=lambda x: -x[1]['dollars'])[:25])
    return out

def main():
    pretty = '--pretty' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    project = args[0] if args else os.path.expanduser(
        '~/.claude/projects/-home-me-dev-project-a')
    if not os.path.isdir(project):
        print(json.dumps({'error': f'not a dir: {project}'})); sys.exit(2)
    out = tally(project)
    print(json.dumps(out, indent=2))
    if pretty:
        print('\n# MODEL RULE: dollars from .message.model only (never report self-tags).', file=sys.stderr)
        print(f"# files main={out['files']['main']} subagents={out['files']['subagents']} "
              f"(a partial glob that skips subagents drops the majority of spend)", file=sys.stderr)
        print(f"# GRAND ${out['grand_total']:,.0f}  main ${out['main_dollars']:,.0f}  "
              f"subagents ${out['subagent_dollars']:,.0f}", file=sys.stderr)
        for k, v in list(out['by_identity'].items())[:12]:
            print(f"#   ${v['dollars']:>8,.0f}  {k}  n={v['n']}", file=sys.stderr)

if __name__ == '__main__':
    main()
