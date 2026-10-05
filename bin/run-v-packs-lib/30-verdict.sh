# run-v-packs-lib/30-verdict.sh — log→verdict classification: turn a finished pack's log into one verdict
# word, plus the SID extraction + telemetry capture that hang off the same final-result parsing.
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# Pure LEAF group: calls no other runner helper (not even die()); everything below reads globals late-bound
# at call time — LOG_DIR, REPO, V_PACK_TELEMETRY, V_WEDGE_IDLE_SEC, V_GAUNTLET_EVIDENCE_GATE — plus jq/grep.
# The one top-level statement (_AUTOGEN default, kept ${_AUTOGEN:-…}-guarded so a pre-set env still wins)
# runs at source time exactly as it did inline: before main(), after the runner's tunables block.
# ── SINGLE-SOURCE terminal-result text classes (FND-001, adversarial review 2026-07-12) ─────────────
# verdict() and 50-pack-exec.sh's _strand_is_stranded() must agree EXACTLY on which final-result texts
# mean ratelimit / auth-drop / no-task — a hand-maintained second copy drifted within hours of being
# written (missing `session (has )?expired`, `re-?authenticate`, the reset-time pattern, …), which would
# have burned bounded STRAND-RESUME attempts against auth/limit sessions. These three variables are the
# ONLY place the phrasings live; both consumers grep with them. Top-level assignment runs at source time
# (before main()), same as the _AUTOGEN default below. v-strand-resume-test.sh pins consumer parity.
_VD_RATELIMIT_RE="hit your (session|usage|weekly) limit|session limit . reset|resets [0-9]{1,2}:?[0-9]* ?[ap]m|upgrade to increase your usage"
_VD_AUTHDROP_RE="not logged in|please run [^ ]{0,3}/login|please (log|sign) ?in( again)?|session (has )?expired|authentication (failed|required|expired)|re-?authenticate"
_VD_NOTASK_RE="did( ?n.?.?t| not) (catch|receive) a task|no content followed the command|no task( was found| content)|no-op invocation|will not fabricate a task|Re-invoke with .{0,3}/v"
# ATTEST-MENTION (2026-09-18): a REFUSAL that NAMES the attestation token was read AS an attestation.
# Live false-completion (a security-hardening pack): the pack
# carried two CRITICAL hardening items. It was
# dispatched under a <local-command-caveat> wrapper plus a STRAND-RESUME message pressing it to skip
# confirmations, merge to main and print the completion tokens. The session CORRECTLY refused, and said so:
#   ... asks me to emit fixed "proof" tokens like `V-COMPLETION-SELFCHECK: PASS` or `GAUNTLET_ATTESTED`
#   — which would be fabricating evidence of a gate run that never happened.
# That sentence contains both literals. The session had also written its own sid-keyed read-only marker, so
# the readonly-done branch (which greps hay for the self-check token with NO num_turns gate) matched the
# REFUSAL and archived the pack to .done/ — packs_done: 15, packs_parked: 0, exit_code: 0, and the hardening
# stayed undone. The num_turns gate that guards the `done` branch could not help: num_turns was 1.
# Fleet sweep over all 487 pack logs found this shape SEVEN times (across several
# projects, plus this one) — every instance a real refusal recorded as a completion.
# The discriminator is whether the token is ASSERTED or merely MENTIONED. Measured over all 362 terminal-
# result token occurrences: 353 assert (unchanged), 9 are mentions (all 9 read and confirmed refusals or
# meta-discussion). NOTE the deliberate `fabricate|fabricating` / `fabricated` split — the past participle
# asserts AUTHENTICITY ("ran the real self-check (not fabricated): V-COMPLETION-SELFCHECK: PASS") and must
# NOT be treated as a mention; without the \b it also matches inside "fabricated" and false-parks 2 real
# passes (a w2 and a w3 pre-flight pack — both verified genuine).
_VD_MENTION_RE="(tokens?[[:space:]]+like|emit[a-z]*|print[a-z]*|fabricat(e|es|ing|ion|ions)[^a-z]|asks?[[:space:]]+me[[:space:]]+to|not[[:space:]]+going[[:space:]]+to|will[[:space:]]+not|won.t|refus[a-z]*|declin[a-z]*)"

# _attest_mention_only <text> <lowercase-token-ere> -> 0 (TRUE: every occurrence is a mere mention, do NOT
# treat as an attestation) | 1 (at least one clean assertion survives). Lowercases both sides so the match
# is case-insensitive without GNU-only `grep -i` interactions, then DELETES every
# "<meta-verb> ... <token>" span and asks whether any bare token is left. Pure bash + sed (no perl/python,
# no lookbehind) so it stays portable with the rest of this runner. Fails OPEN on empty input: no text
# means no mention, so the caller's existing grep decides.
# _attest_corpus <log> -> the log with TOOL-RESULT / user events removed.
# ATTEST-MENTION-4 (CRITICAL, 2026-09-18 QA): the parent path's positive signal greps the WHOLE log, and
# must, because a genuine attestation can legitimately sit in an earlier assistant turn OR — as every
# fixture in this repo's own suites does — as a bare trailing line after the result JSON. But the whole log
# ALSO contains tool results, and QA proved a live archive (a 99-verify pack) off a `cat` of the
# self-check SCRIPT, whose own COMMENTS contain both literals. Dropping `"type":"user"` lines removes the
# tool-result/prompt-echo surface while keeping assistant turns, the result event and bare fixture lines.
# Signal and veto both read THIS corpus, so the two can never disagree about scope.
# STRUCTURAL, not line-grep: these logs are JSONL whose single lines run to ~12 KB and routinely embed
# nested content of several types, so dropping any LINE containing '"type":"user"' also discarded the
# attestation riding on that same line — measured: 110 of 487 fleet packs lost their signal and false-parked.
# jq walks the events instead: assistant TEXT blocks + the terminal .result + bare non-JSON lines (how this
# repo's own fixtures emit the token).
#
# ATTEST-MENTION-6 (CRITICAL, 2026-09-18 re-review — this corrects an outright WRONG call): the first version
# excluded ALL tool_result/user content, on the belief that a token found there could only be a `cat` of a
# script whose comments contain the literal. QA refuted that with evidence: `v-gauntlet-attest.sh:787` emits
# the attestation on STDOUT, so a GENUINE attestation is necessarily delivered as a tool_result, and the
# assistant's prose wrap-up usually paraphrases ("gauntlet attested") rather than repeating the uppercase
# token. Blanket exclusion therefore discarded the DOMINANT LEGITIMATE signal: 52 of 56 tool-result cases
# structurally matched the real script's output. So user events are admitted, but ONLY for the script's own
# observable-proof block, matched LINE-ANCHORED. That anchoring is what separates stdout from source: the
# script's own line 787 reads `printf 'GAUNTLET_ATTESTED: yes\n'` and its line 33 reads
# `#   GAUNTLET_ATTESTED: yes`, and neither matches at line-start — so a `cat` of the script still does not
# attest, while its actual output does.
#
# ATTEST-MENTION-8 (CRITICAL, 2026-09-18 round-3 QA): line-anchoring alone was NOT enough. SKILL.md:832 carries
# the OBSERVABLE-PROOF block VERBATIM and UNINDENTED in a fenced code block — the same four lines, at true
# line-start, in the one file every /v session is told to read. A targeted `grep -A4 GAUNTLET_ATTESTED SKILL.md`
# lands it in a tool_result and the pack archives as `done` while hay says nothing was verified. Proven
# end-to-end; two sessions in this fleet already ran the equivalent self-diagnostic grep against another target.
# The discriminator is empirical, from all 524 anchored tool_result attestations on disk: a REAL invocation
# prints an ABSOLUTE path (`PRE_FLIGHT_REPORT: /abs/path/PRE_FLIGHT_REPORT_<sid>.md`) — 521 of 524 — while
# SKILL.md's illustration prints the literal placeholder `<absolute path>`. Requiring the NEXT line to be
# `PRE_FLIGHT_REPORT: /` admits every real attestation and rejects the documentation.
# (QA proposed keying on an `EXIT=` marker; checked and rejected — v-gauntlet-attest.sh emits no EXIT= line and
# none of the 524 real captures carries one.)
_attest_corpus(){
  jq -Rr 'fromjson? // empty
          | if .type=="assistant" then (.message.content[]? | select(.type=="text") | .text)
            elif .type=="result" then (.result // empty)
            elif .type=="user" then
              (.. | strings | select(test("(^|\n)GAUNTLET_ATTESTED: (yes|readonly)[ \t]*\r?\n[ \t]*PRE_FLIGHT_REPORT:[ \t]*/")))
            else empty end' "$1" 2>/dev/null
  grep -av '^[[:space:]]*{' "$1" 2>/dev/null
}

_attest_mention_only(){
  local low stripped
  # ATTEST-MENTION-2 (CRITICAL, 2026-09-18 adversarial review): `sed` is LINE-oriented and cannot bridge a
  # newline, so a refusal that names the tokens as a BULLET LIST (trigger phrase on one line, the tokens on
  # the next) slipped the veto completely — proven on BSD sed using the real incident's own text merely
  # re-wrapped. Flatten ALL whitespace to single spaces first so the proximity match sees one continuous
  # line. The window is also widened 100 -> 300 chars: a verbose refusal preamble between the trigger phrase
  # and the token defeated the old span too (the shipped bound is 250, not 300 — see the BSD cap below).
  # Both changes bias toward OVER-veto, which is the safe
  # direction here (a false park costs a re-run; a false archive ships unfinished security work).
  low="$(printf '%s' "$1" | tr '\n\r\t' '   ' | tr '[:upper:]' '[:lower:]')"
  # ABSENT != MENTION. If the token does not appear in this text at all there is nothing to veto, so say
  # "not mention-only" and let the caller's own positive signal decide. Getting this backwards false-parked
  # 4 legitimate packs whose attestation lived in an EARLIER assistant turn and was never restated in the
  # final message (a w1-review, a w3-review and two other packs across several projects
  # — all read and confirmed genuine): the noop branch greps the WHOLE log, so hay can legitimately be
  # token-free there. Empty text takes the same path.
  printf '%s' "$low" | grep -qE "$2" || return 1
  # BSD sed caps an ERE repetition bound at 255 ("RE error: maximum repetition exceeds 255") and, on
  # failure, emits NOTHING — which this function would then read as "no token survived" = mention-only,
  # silently vetoing EVERY pack in the fleet. 250 stays under the cap on both BSD and GNU. Verified by
  # running the real function on macOS /usr/bin/sed; the guard below makes any future sed failure loud
  # instead of a fleet-wide over-veto.
  # ATTEST-MENTION-5 (CRITICAL, 2026-09-18 re-review): the span used to exclude . ! ? so it could not cross a
  # SENTENCE boundary — the most ordinary way in English to write a two-part refusal. "I will not print the
  # token. It is GAUNTLET_ATTESTED." was NOT vetoed; the same text with a comma was. That defeated all four
  # call sites including the reconcile fix, at any distance, with no special formatting. The exclusion did no
  # useful work once the span became length-bounded and newline-flattened, so it is now `.` — strictly more
  # veto, which is the safe direction.
  stripped="$(printf '%s' "$low" | sed -E "s/${_VD_MENTION_RE}.{0,250}($2)//g" 2>/dev/null)" || stripped=""
  if [ -z "$stripped" ] && [ -n "$low" ]; then
    echo "  ⚠ _attest_mention_only: sed produced no output (regex/dialect failure) — treating as mention-only (fail-safe: parks rather than archives)" >&2
    return 0
  fi
  printf '%s' "$stripped" | grep -qE "$2" && return 1
  return 0
}

# ── verdict / classification (turn a finished pack's log into a single verdict word) ────────────────
# T-ACT: how did a timed-out pack die? Reads the sidecar the watchdog wrote. "active" = the session was
# still doing real work when the ceiling hit (legitimately slow — raise --timeout); anything else (including
# an empty legacy sidecar) = "wedged" (no log activity for V_WEDGE_IDLE_SEC before the kill).
_timeout_kind(){ # $1=name -> active | wedged
  case "$(head -1 "$LOG_DIR/$1.log.timedout" 2>/dev/null)" in active) echo active ;; *) echo wedged ;; esac
}

# T4-F3 (2026-07-02 wave-4 forensic): total output tokens across ALL models in the final result event.
# This is the "did the fork do real work?" signal for a num_turns==0 result: verdict()'s INVARIANT
# ("a session that changed the tree still spends main-loop turns") was DISPROVEN live —
# the /v fork burned 46K output tokens (wrote both pack deliverables, dispatched a reviewer, ran suites)
# while the parent main loop reported num_turns=0. The park stays correct (no terminal token → not done),
# but the triage must not call real work "STALLED on a Monitor notification".
_result_out_tokens(){ # $1=name -> integer total modelUsage output tokens (0 if none/unparsable)
  local t
  # CODEX-001: `| numbers` filters non-numeric values BEFORE add — jq's add STRING-CONCATENATES an
  # all-string list ("1"+"999" → "1999", all-digit, so the shell guard passed it through as a wrong
  # numeric). The schema is owned by an external CLI; a malformed field must degrade to IGNORED.
  t="$(grep -E '"type":[[:space:]]*"result"' "$LOG_DIR/$1.log" 2>/dev/null | tail -1 \
       | jq -r '([.modelUsage[]?.outputTokens | numbers] | add) // 0' 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) echo 0 ;; *) echo "$t" ;; esac
}
# V-FORK-1 (2026-07-06 forensics): /v is a `context: fork` skill — under `claude -p` the PARENT
# main loop reports num_turns=0 while the fork does 100% of the work (confirmed live on a 5-pack batch:
# every session, including a 72-min fully-attested run with a real commit and two merge-back attempts,
# ended num_turns=0; the parent transcripts carry zero assistant turns). The T4-F3 "invariant" (a session
# that changed the tree still spends main-loop turns) is therefore DEAD for fork-mode /v — 0 parent turns
# is now the NORM for real work, and verdict() could never again reach done/noop. Recover the REAL turn
# count from the fork's durable per-turn ledger: OP_TELEMETRY_<sid>.json under $REPO/.v/artifacts, written
# by the /v ecosystem keyed on the pinned SID. Trust rules: it is a TYPED per-turn JSON ledger (not
# echoable log prose), matched by the exact SID claude reported in this pack's own result event; a missing/
# unparsable/foreign-SID file yields 0 → verdict keeps the old 0-turn park (the safe default). Callers that
# recover turns this way must scope their token greps to the terminal result text (see verdict()) — the
# parent-turn gate was ALSO the echo-spoof guard, and hay-scoping replaces it.
_fork_turns(){ # $1=name -> integer fork turn count from the sid's OP_TELEMETRY ledger (0 if unavailable)
  local sid t; sid="$(sid_of "$1")"
  [ -n "$sid" ] || { echo 0; return; }
  t="$(jq -r --arg sid "$sid" '[.[]? | select(.sid==$sid) | .turns | length] | add // 0' \
        "$REPO/.v/artifacts/OP_TELEMETRY_${sid}.json" 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) echo 0 ;; *) echo "$t" ;; esac
}

_inconclusive_kind(){ # $1=name -> completed | fork-work | already-done | stalled
  local log="$LOG_DIR/$1.log" hay
  # R3: scope the phrase greps to the terminal result's .result text when a result event exists — the SAME
  # hay rule verdict() uses. This branch only runs at num_turns==0 (a result event is present on every path
  # that reaches it via verdict; the whole-log fallback covers direct callers on crashed logs), and a pack
  # PROMPT quoting 'V-COMPLETION-SELFCHECK: PASS' is echoed into the log's task event — an unscoped grep let
  # that echo dress a genuinely STALLED park up as "completed", steering the operator away from the one park
  # kind that needs interactive attention. (CODEX-002's ordering note below still holds within hay.)
  hay="$(grep -E '"type":[[:space:]]*"result"' "$log" 2>/dev/null | tail -1 | jq -r '.result // ""' 2>/dev/null)"
  [ -n "$hay" ] || hay="$(cat "$log" 2>/dev/null)"
  printf '%s' "$hay" | grep -qE 'V-COMPLETION-SELFCHECK:[[:space:]]*PASS' 2>/dev/null && { echo completed; return; }
  # CODEX-002: the STRUCTURAL fork-work signal (a typed field from the terminal result event) must be
  # judged BEFORE the already-done PROSE grep — the prose regex scans free text, and a pack prompt
  # containing ordinary phrasing like "if already implemented, say so" could be echoed into a result
  # summary, which would otherwise suppress exactly the deliverables-on-disk warning this triage exists
  # to surface. (`completed` stays first: its token is emitted only by /v's own terminal self-check.)
  [ "$(_result_out_tokens "$1")" -ge "${V_FORK_WORK_MIN_OUT:-1000}" ] 2>/dev/null && { echo fork-work; return; }
  printf '%s' "$hay" | grep -qiE 'already (done|implemented|committed|present|in place)|non-code completion|no code (was )?change|nothing (left )?to (do|implement|change|fix)|investigation-only|0 files changed|everything checks out' 2>/dev/null && { echo already-done; return; }
  echo stalled
}

# ── R-VERIFY (2026-07-04): claimed completion must be BACKED by real gate artifacts, not just a log token ──
# WHY (beyond the existing R2 echo-spoof fix in verdict(), which only stops a pack PROMPT's own text from
# being misread as the token): a GENUINE self-emitted "GAUNTLET_ATTESTED: yes" in the log proves /v's
# terminal self-check ran, but it does not prove the artifacts that check attested are still ON DISK by the
# time run-v-packs decides to archive — a worktree-teardown race, a merge that dropped `.v/`, or a bug in
# the attest script itself could all leave a log claiming success with nothing to back it. This is the same
# "the log's text is not proof; the artifact file is" principle the rest of the /v ecosystem enforces
# (v-gauntlet-attest.sh itself refuses to trust a log for exactly this reason). Checked in the durable
# `.v/artifacts/` copy (the completion self-check's relocation target) AND the repo root (pre-relocation
# location, in case the copy step hasn't run) — either counts.
# OPT-IN (V_PACK_VERIFY_ARTIFACTS=1, default OFF): `.v/artifacts/` existing in a repo does NOT reliably mean
# EVERY pack's own session followed the full-gauntlet artifact convention — a sibling worktree, an unrelated
# prior session, or a lighter completion path (TRIVIAL/Maintenance fast-paths) can legitimately leave that
# directory populated with only SOME of the 3 kinds, for reasons unrelated to THIS pack. A directory-existence
# heuristic can't safely tell "fabricated" apart from "this pack's completion path just doesn't produce all
# 3" — so this predicate defaults to a no-op (always verified) and only activates for an operator who has
# confirmed their repo's /v sessions consistently produce the durable-copy artifacts and wants the extra
# check. When active, it fails CLOSED (distrusts the "done" archive) only when ZERO of the 3 kinds are found
# for this exact sid anywhere searched — a much softer bar than "all 3", chosen to avoid false-parking a
# legitimate completion whose artifact set is merely partial for an unrelated reason.
_gauntlet_artifacts_verified(){ # $1=sid -> 0 (verified, unverifiable, or feature disabled) | 1 (provably ZERO evidence)
  local sid="$1" n
  [ "${V_PACK_VERIFY_ARTIFACTS:-0}" = 1 ] || return 0   # opt-in; default off (see header note above)
  [ -n "$sid" ] || return 0   # no sid to check against — can't assert absence, don't block
  [ -d "$REPO/.v/artifacts" ] || return 0   # convention not adopted in this repo — fail-open
  n="$(find "$REPO/.v/artifacts" "$REPO" -maxdepth 3 -type f \
        \( -iname "PRE_FLIGHT_REPORT*${sid}*" -o -iname "AGENT_REVIEW*${sid}*" -o -iname "VERIFY_DONE_REPORT*${sid}*" \) \
        2>/dev/null | wc -l | tr -d ' ')"
  [ "${n:-0}" -ge 1 ] && return 0
  return 1
}

# NO-HUMAN-4 (2026-07-04 autonomy audit): INDEPENDENT verdict backstop for the `done` archive decision.
# The problem the 3-reviewer audit found (FA-1/FA-3): verdict()==done rests on a whole-log GAUNTLET_ATTESTED
# substring (near-vacuous — that literal appears in SKILL.md's example block, injected into every /v run, and
# is trivially echoable as prose) PLUS delegation to the Stop hook; the runner never independently re-reads
# whether the gate artifacts actually PASSED. If the Stop hook ever fails open (jq missing, REPO_ROOT
# unresolved, a future non-blocking config), a session whose PRE_FLIGHT/VERIFY_DONE/QA records FAIL can still
# reach result:success → verdict done → archived as production-ready with NO backstop. This predicate is the
# runner's OWN check: it reads the pack sid's on-disk gate artifacts and REFUSES the done-archive when any of
# them EXPLICITLY records a failing verdict. STRICT STRENGTHENING — it blocks ONLY on a positively-matched FAIL;
# a PASS verdict, an absent artifact, or a malformed/unparseable one NEVER blocks, so it cannot false-reject a
# legitimately-passing pack (the residual same-UID fabricated-PASS, audit FA-2, is irreducible here — that needs
# out-of-band CI under a different trust domain). Verdict-line formats are the AUTHORITATIVE ones that
# hooks/lib/validation.sh enforces (keep in sync there): PRE_FLIGHT final non-empty line `Overall Status:
# PASS|FAIL`, VERIFY_DONE final non-empty line `Overall Verdict: PASS|FAIL`, QA col-0 `verdict: pass|fail|
# escalated`. Searches the durable `.v/artifacts/` copy AND the repo root, same as _gauntlet_artifacts_verified.
# Default ON (safe — only ever blocks a provably-failing pack); opt out with V_PACK_VERDICT_GATE=0.
_gauntlet_verdicts_not_failed(){ # $1=sid -> 0 (ok: pass / absent / unparseable) | 1 (an artifact says FAIL; reason on stdout)
  [ "${V_PACK_VERDICT_GATE:-1}" = 1 ] || return 0
  local sid="$1" f _last _reason=""
  [ -n "$sid" ] || return 0
  [ -d "$REPO/.v/artifacts" ] || [ -d "$REPO" ] || return 0
  # HR-1 (2026-07-04 hostile review, HIGH false-reject): check ONLY the FRESHEST copy of each artifact kind,
  # not every match OR'd together. The durable-copy hook (hooks/durable-artifact-copy.sh) mirrors artifacts to
  # .v/artifacts best-effort/fail-open, so a repo can hold BOTH a stale .v/artifacts FAIL and a fresh root PASS
  # (or vice versa) for one sid (documented desync class: check-review-artifact.sh find_session_artifact's
  # ORCHFIX-A1/A2). OR-ing across all matches would let a stale FAIL park a currently-passing pack forever. So
  # mirror find_session_artifact: pick newest-by-mtime (_newest_sid_artifact) and read ONLY that one.
  # HR-2 (same review, HIGH false-accept): iterate via `while read < <(find)` NOT `for f in $(find)` — an
  # unquoted command-substitution word-splits on a SPACE in $REPO's path (macOS iCloud/Documents), which
  # silently skipped every artifact and no-op'd the whole backstop.
  f="$(_newest_sid_artifact "PRE_FLIGHT_REPORT*${sid}*")"
  if [ -n "$f" ]; then
    _last="$(awk 'NF { last=$0 } END { print last }' "$f" 2>/dev/null)"
    printf '%s' "$_last" | grep -qE '^Overall Status:[[:space:]]+FAIL' && _reason="PRE_FLIGHT_REPORT says FAIL ($f)"
  fi
  f="$(_newest_sid_artifact "VERIFY_DONE_REPORT*${sid}*")"
  if [ -n "$f" ]; then
    _last="$(awk 'NF { last=$0 } END { print last }' "$f" 2>/dev/null)"
    printf '%s' "$_last" | grep -qE '^Overall Verdict:[[:space:]]+FAIL' && _reason="VERIFY_DONE_REPORT says FAIL ($f)"
  fi
  f="$(_newest_sid_artifact "QA_REPORT*${sid}*")"
  if [ -n "$f" ]; then
    grep -iqE '^verdict:[[:space:]]*[^a-zA-Z]*fail' "$f" 2>/dev/null && _reason="QA_REPORT verdict: fail ($f)"
  fi
  [ -z "$_reason" ] && return 0
  printf '%s' "$_reason"; return 1
}

# Phase-2 note (2026-07-06): the /v ecosystem relocated its planning/report families — including
# IMPLEMENTATION_REPORT — into <repo>/.v/artifacts/. This runner does NOT gate on IMPLEMENTATION_REPORT
# by name (that witness is validated by the pack session's OWN Stop hook, check-review-artifact.sh,
# which dual-searches .v/artifacts then root); the runner keys staged-handoff resolution on the
# commit-witness commits-<sid>.txt (already under .v/artifacts). So the relocation is transparent here.
# Every artifact this runner DOES read goes through the dual-search below, so it is location-agnostic.
# _newest_sid_artifact <iname-glob> -> path of the NEWEST-by-mtime match under $REPO/.v/artifacts + $REPO
# (maxdepth 3), or nothing. Space-safe (while-read, not $(find) word-splitting) and freshest-wins (a stale
# durable-copy mirror must never override a fresher root fix — mirrors check-review-artifact.sh's
# find_session_artifact). Portable mtime: GNU `stat -c %Y` then BSD `stat -f %m`, else 0. Internal to
# 30-verdict.sh (only _gauntlet_verdicts_not_failed calls it) — pinned by the structure test's seam parity.
_newest_sid_artifact(){ # $1=iname glob
  local pat="$1" best="" bestm=0 cur curm
  # QA-2 (2026-07-12 session-QA finding, same class as the drain's C-1 sidecar overmatch): the glob also
  # matches NON-CANONICAL suffix variants — v-dispatch-subagent's *.dispatch-runlog / *.dispatch-status
  # sidecars (whose free text echoes verdict lines of WHATEVER iteration they dispatched), *.stale.<pid>
  # displaced copies, and *.invalid quarantines. Newest-by-mtime can select one of those and
  # _gauntlet_verdicts_not_failed would then read a LOG's echo as the artifact's verdict. Only a canonical
  # .md artifact may win; v-merge-back's _qa_report_fail + the FND exclude regex already enforce the same
  # rule on their side (v-fnd-exclude-parity-test.sh pins the suffix family there).
  while IFS= read -r cur; do
    case "$cur" in *.dispatch-runlog|*.dispatch-status|*.stale.*|*.invalid|*.provenance) continue ;; esac
    [ -n "$cur" ] || continue
    curm="$(stat -c %Y "$cur" 2>/dev/null || stat -f %m "$cur" 2>/dev/null || echo 0)"
    case "$curm" in ''|*[!0-9]*) curm=0 ;; esac
    [ "$curm" -gt "$bestm" ] && { bestm="$curm"; best="$cur"; }
  done < <(find "$REPO/.v/artifacts" "$REPO" -maxdepth 3 -type f -iname "$pat" 2>/dev/null)
  [ -n "$best" ] && printf '%s' "$best"
}

verdict(){ # verdict <name> -> done | noop | inconclusive | timeout | partial | no-task | ratelimit | error | incomplete
  local log="$LOG_DIR/$1.log" res rl ok=0
  # Our watchdog killed a session that blew PACK_TIMEOUT (wedged — no clean result will ever come). Definitive:
  # only _watchdog drops this sidecar. Checked FIRST — before the empty-log guard (a killed session may have an
  # empty log) and before ratelimit (a wedged rate-limit stall must park, not loop).
  [ -f "${log}.timedout" ] && { echo timeout; return; }
  [ -s "$log" ] || { echo incomplete; return; }
  res="$(grep -E '"type":[[:space:]]*"result"' "$log" 2>/dev/null | tail -1)"
  # R2 (2026-07-02 second-pass audit): scope the limit/no-task phrase matches. These used to be UNANCHORED
  # whole-log greps checked before the result event was even read — the same echo-spoof class as the
  # GAUNTLET_ATTESTED fix above: a pack PROMPT whose text merely mentions "usage limit" or "no task content"
  # is echoed verbatim into the log by the initial task event, and a fully successful attested run was then
  # misclassified as ratelimit (6h wave-wide false stall) or no-task (endless re-run). When a terminal result
  # event exists, match ONLY its .result text (the final assistant message — the real limit notice/no-task
  # refusal always lands there). Only a log with NO result event (crash/kill mid-run) falls back to the
  # whole-log scan: its verdicts are non-terminal (kept + re-run / wait) so a rare spoof there cannot archive.
  local hay
  if [ -n "$res" ]; then hay="$(printf '%s' "$res" | jq -r '.result // ""' 2>/dev/null)"; else hay="$(cat "$log" 2>/dev/null)"; fi
  # Claude SESSION/USAGE LIMIT — arrives as a plain "success" result whose TEXT is the limit notice
  # ("You've hit your session limit · resets 6pm"), NOT a rate_limit_event. Treat as rate-limit so the
  # drain loop waits for the reset instead of falsely marking the pack partial/done. MUST be checked first.
  printf '%s' "$hay" | grep -qiE "$_VD_RATELIMIT_RE" 2>/dev/null && { echo ratelimit; return; }
  # AUTH-DROP (2026-07-07 forensic): a session whose 5-hour quota is exhausted (or whose token
  # lapses mid-run) returns a synthetic "success" result — subtype:success, is_error:false, num_turns:0 — whose
  # TEXT is the CLI auth notice "Not logged in · Please run /login". On the ok=1 path below this used to fall
  # straight through to `inconclusive` (line ~279) → PARKED to .needs-review/ and NEVER re-run, permanently
  # stranding a pack that never actually ran a turn. That is WRONG: nothing was attempted, the tree is unchanged
  # NOT because the work is futile but because the session never authenticated — re-running AFTER login/quota-reset
  # makes real progress. Classify as `ratelimit` (same family as the session-limit text above): KEPT, never
  # archived, bounded poll-and-retry. SOUND BY CONSTRUCTION — `ratelimit` can never mark a pack falsely done, so
  # even a spurious match only costs a retry (strictly safer than the inconclusive park it replaces). Scoped to the
  # terminal .result text (hay), same anti-echo-spoof rule as the limit check above.
  printf '%s' "$hay" | grep -qiE "$_VD_AUTHDROP_RE" 2>/dev/null && { echo ratelimit; return; }
  # /v received no task — its task-capture came back empty (transient when serial; SYSTEMATIC when parallel
  # sessions clobber the shared capture channel). Re-runnable, NEVER archive. These are the real /v phrasings.
  printf '%s' "$hay" | grep -qiE "$_VD_NOTASK_RE" 2>/dev/null && { echo no-task; return; }
  [ -n "$res" ] \
    && [ "$(printf '%s' "$res" | jq -r '.subtype // ""' 2>/dev/null)" = success ] \
    && [ "$(printf '%s' "$res" | jq -r '.is_error' 2>/dev/null)" = false ] && ok=1
  if [ "$ok" = 1 ]; then
    # READ-ONLY VERIFICATION lane (2026-07-07): a runner-tagged read-only pack ($logf.readonly) ships NO
    # commit and NO GAUNTLET_ATTESTED BY DESIGN, so it would else fall to inconclusive/partial and park
    # forever (deadlocking a later hardening wave). Archive it ONLY on a self-attested completion in the
    # TERMINAL result (hay) — /v emits V-COMPLETION-SELFCHECK: PASS for a read-only session only after proving
    # zero product-code + a findings artifact. Gated on the runner's own tag ⇒ can never fire for a code pack;
    # no attestation ⇒ falls through to the normal (parking) branches. See _archive_finished_pack readonly-done.
    # PRIMARY signal: the runner's name-keyed tag ($logf.readonly). FALLBACK (2026-07-07, forensic):
    # the SESSION-side sid-keyed marker $REPO/.v/tmp/pack-readonly-<sid>.marker — written by the read-only /v
    # session itself (its own completion self-check requires it) — so a read-only pack whose directive form the
    # runner's _pack_is_readonly text-detector MISSED (detector drift, e.g. the "READ-ONLY —" em-dash form) is
    # still recognized here instead of parking forever. Either signal must co-occur with the terminal
    # V-COMPLETION-SELFCHECK: PASS, which /v emits ONLY for a provably-zero-product-code session (the self-check
    # + Stop hook both recompute a zero diff) ⇒ neither path can fire for a code pack.
    local _ro_tag=0; [ -f "${log}.readonly" ] && _ro_tag=1
    if [ "$_ro_tag" = 0 ]; then
      local _rosid; _rosid="$(sid_of "$1" 2>/dev/null)"
      [ -n "$_rosid" ] && [ -f "$REPO/.v/tmp/pack-readonly-${_rosid}.marker" ] && _ro_tag=1
    fi
    if [ "$_ro_tag" = 1 ]; then
      # ATTEST-MENTION: the self-check token must be ASSERTED here, not merely named. This branch has no
      # num_turns gate by design (a read-only pack legitimately attests at 0 parent turns), so the mention
      # veto is the ONLY guard standing between a refusal that quotes the token and a .done/ archive.
      if printf '%s' "$hay" | grep -qiE 'V-COMPLETION-SELFCHECK:[[:space:]]*PASS' 2>/dev/null \
         && ! _attest_mention_only "$hay" 'v-completion-selfcheck:[[:space:]]*pass'; then
        echo readonly-done; return
      fi
    fi
    local nt ntsrc=parent; nt="$(printf '%s' "$res" | jq -r '.num_turns // empty' 2>/dev/null)"
    # V-FORK-1 (2026-07-06): 0 parent turns + a durable fork-turn ledger for this pack's own SID ⇒ the
    # session was a context:fork /v run whose work lived in the fork — use the fork's real turn count.
    # ntsrc=fork additionally switches the token checks below from whole-log greps to the terminal result
    # text (hay): the parent-turn gate doubled as the echo-spoof guard (a pack PROMPT quoting a token is
    # echoed into the log's task event, but never into the result string), so hay-scoping replaces it.
    if [ "$nt" = 0 ]; then
      local _ft; _ft="$(_fork_turns "$1")"
      if [ "${_ft:-0}" -gt 0 ] 2>/dev/null; then nt="$_ft"; ntsrc=fork; fi
    fi
    # the run exited cleanly — count it DONE if the FULL /v gauntlet attested...
    # ...but ONLY if the loop actually ran (num_turns != 0, parent- or fork-counted). A real attestation
    # requires the loop to dispatch review/verify and run v-gauntlet-attest.sh; at 0 turns the loop never
    # acted, so a GAUNTLET_ATTESTED token in the log can only be ECHOED/RELAYED content — a
    # <local-command-stdout> wrapper, or the result-string echo of a HANDOFF/merge-DEFERRED summary (live
    # false-positive: a branch merge-back-deferred, NOT on main, whose result string quoted
    # "GAUNTLET_ATTESTED: yes" was archived as done — exactly the false-completion the inconclusive park
    # exists to prevent). A 0-turn clean exit with NO fork ledger falls through to the inconclusive branch
    # below (parked for a human, never archived). A MISSING/non-numeric num_turns is NOT 0 → the token is
    # still honored (a real result always carries num_turns; the contract test pins missing→partial).
    # NOTE the residual shape (attested-but-DEFERRED archived as done) is accepted here BY DESIGN:
    # archive-on-attestation is the runner's contract; landing is independently tracked by _unlanded_branches
    # (exit 2) + the end-of-run drain + reconcile, and _gauntlet_verdicts_not_failed still refuses any
    # provably-FAILING artifact set.
    if [ "$nt" != 0 ]; then
      # ATTEST-MENTION: same veto. Scoped to hay (the terminal result) in BOTH paths — a refusal always
      # lands its explanation in the final message. The parent path keeps its whole-log grep as the
      # positive signal (a genuine attestation may sit in an earlier assistant turn and never be restated
      # in the result), so the veto fires ONLY when the terminal message itself discusses the token in
      # mention form and asserts it nowhere. Strictly narrowing: a log whose hay has no token is untouched.
      # ATTEST-MENTION-4 (CRITICAL, 2026-09-18 QA): SCOPE MISMATCH. The veto reads hay (the terminal
      # message) but the parent path's positive signal used to grep the WHOLE LOG — so a token appearing
      # anywhere in the transcript still attested even when hay vetoed. Proven live: a
      # 99-verify pack archived as `noop` because an earlier TOOL RESULT had cat'd the self-check script, whose
      # own COMMENTS contain both literals — nothing to do with that session's (declined) attestation.
      # Two from-scratch synthetic logs reached .done/ the same way. Fix: signal and veto now read the SAME
      # text (hay) on every path, so the mismatch cannot exist by construction. Cost, stated plainly: a
      # genuine attestation that appears ONLY in an earlier assistant turn and is never restated in the
      # final message no longer archives — it parks and re-runs. That is the safe direction.
      local _asrc
      if [ "$ntsrc" = fork ]; then _asrc="$hay"; else _asrc="$(_attest_corpus "$log")"; fi
      # SCOPE, stated precisely (measured, not assumed): the SIGNAL reads $_asrc (whole log minus
      # tool-result/user events) because a genuine attestation legitimately lives in an earlier assistant
      # turn or a bare fixture line. The VETO reads $hay only. That asymmetry is DELIBERATE: the veto is a
      # PROSE heuristic and $_asrc is a transcript full of shell code, where `print[a-z]*` matches every
      # `printf` — running the veto over $_asrc false-parked 110 of 487 fleet packs (measured). The spoof
      # CRITICAL-3 actually exploited was tool-result content, and _attest_corpus removes that surface from
      # the signal, which is where the fix belongs.
      # ATTEST-MENTION-7 (CRITICAL-5, 2026-09-18 round-3 review): signal and veto now read the SAME text.
      # Previously the signal read $_asrc (every assistant turn) while the veto read $hay (terminal message
      # only), so an early, honest "I will not fabricate the token" poisoned the signal with its own token
      # and no terminal-side veto could see it — proven end-to-end into .done/, with two live fleet matches.
      # Scoped to done/noop ONLY: `readonly-done` already uses hay for BOTH signal and veto, so it is
      # symmetric and must NOT be changed (a shared substitution there references an undefined corpus var
      # and emptied every verdict in the fleet — that attempt was reverted).
      # Safe to do now in a way it was not earlier: the veto-over-corpus measurement that showed 110
      # false-parks was taken against the ABANDONED line-grep corpus, which was full of shell code where
      # `print[a-z]*` matches every `printf`. The current jq corpus carries assistant prose, the terminal
      # result and the attest script's anchored stdout — no tool_use command text — so that contamination
      # is gone. Re-measured below rather than assumed.
      if printf '%s' "$_asrc" | grep -qE 'GAUNTLET_ATTESTED' 2>/dev/null \
         && ! _attest_mention_only "$_asrc" 'gauntlet_attested'; then
        echo done; return
      fi
    fi
    # ...OR if /v's OWN completion self-check PASSED for an already-done / no-op task: the fix was already
    # implemented + committed on main in an earlier pass (often via worktree + v-merge-all, which lands the
    # work but never writes GAUNTLET_ATTESTED in THIS pack's log), so re-running just no-ops. That is a
    # TERMINAL success — archive it instead of looping forever. Require BOTH the PASS self-check AND an
    # explicit already-done phrase so a genuine half-finished partial can never masquerade as complete.
    # R2: SAME num_turns!=0 gate as the done branch above — a real self-checked no-op needs the main loop to
    # have run the check (turns>0); at num_turns==0 both trigger phrases can only be ECHOED text (they are
    # literally co-located on one line of v-runnable-pack-convention.md:26, which a self-referential audit
    # pack quotes into its own log). A 0-turn PASS+phrase log falls to inconclusive below, where
    # _inconclusive_kind already triages it as "completed" — parked with the right message, never archived.
    # V-FORK-1: same hay-scoping rule as the done branch — fork-recovered turns must match tokens in the
    # terminal result text only (the two trigger phrases are co-located in v-runnable-pack-convention.md:26,
    # which a self-referential pack quotes into its own task event — whole-log greps would spoof).
    # ATTEST-MENTION: `noop` is an ARCHIVING verdict too (it moves the pack to .done/), so it is a bypass
    # of the veto above unless it carries the same guard — measured: without this, 2 of the 7 vetoed
    # refusals (a diagnosis pack and a 99-verify pack) simply fell
    # from readonly-done/done through to noop and archived anyway. Veto scoped to hay for the same reason.
    if [ "$nt" != 0 ]; then
      # ATTEST-MENTION-4: same scope unification as the done branch — hay for BOTH the fork and parent
      # paths. The whole-log ($_noop_src) grep is gone; it was the vector that archived a 99-verify pack off a
      # cat'd script's comments.
      local _nsrc
      if [ "$ntsrc" = fork ]; then _nsrc="$hay"; else _nsrc="$(_attest_corpus "$log")"; fi
      if printf '%s' "$_nsrc" | grep -qE 'V-COMPLETION-SELFCHECK:[[:space:]]*PASS' 2>/dev/null \
         && printf '%s' "$_nsrc" | grep -qiE 'already (done|implemented|committed|present|in place)|non-code completion|TRIVIAL_PASS|no code (was )?change|nothing (left )?to (do|implement|change|fix)' 2>/dev/null \
         && ! _attest_mention_only "$_nsrc" 'v-completion-selfcheck:[[:space:]]*pass'; then
        echo noop; return
      fi
    fi
    # INCONCLUSIVE — clean exit but the MAIN session did ZERO work (num_turns==0) and emitted NO terminal
    # token (not GAUNTLET_ATTESTED, not a self-checked no-op). Re-running is DETERMINISTICALLY futile — the
    # tree state is unchanged, so the next pass resolves to the same nothing. Two real causes, both non-
    # retryable: (a) the fix was already implemented+committed on main in a prior session, so /v's 0-file
    # completion runs the self-check which emits FAIL (no gauntlet artifacts to validate) → never a PASS
    # noop token; (b) the headless /v parked itself (e.g. "waiting for the Monitor event notification" —
    # an interactive wait that never fires under `-p`). A genuine PARTIAL (implemented but skipped review/
    # verify) instead has num_turns>0 and SHOULD keep retrying; this branch fires ONLY on num_turns==0 so it
    # never steals a retry from real half-done work. Parked (not archived — no proof of done) by run_pass_wave.
    # V-FORK-1 REWROTE the old invariant here: parent num_turns is 0 for EVERY context:fork /v session, real
    # work included — so this branch now fires only when BOTH the parent count is 0 AND no OP_TELEMETRY fork
    # ledger exists for the pack's own SID (nt was not recovered above). That residue is the genuinely-inert
    # class: the fork never ran a turn (no ledger), or telemetry is disabled/broken — in which case parking
    # (visible in .needs-review/, never archived, never lost) remains the safe default, exactly as before.
    # A missing/non-numeric num_turns falls through to `partial` below (retry — the safe default).
    if [ "$nt" = 0 ]; then echo inconclusive; return; fi
    echo partial; return
  fi
  rl="$(grep -E '"type":[[:space:]]*"rate_limit_event"' "$log" 2>/dev/null | tail -1 | jq -r '.rate_limit_info.status // ""' 2>/dev/null)"
  case "$rl" in ""|allowed) : ;; *) echo ratelimit; return ;; esac
  grep -qiE 'rate.?limit|quota|usage limit|overloaded|"error".*(429|rate)' "$log" 2>/dev/null && { echo ratelimit; return; }
  [ -n "$res" ] && { echo error; return; }
  echo incomplete
}

# ── TELEMETRY (2026-06-30): the fleet wrote ZERO session logs (one project's disk: 62 SESSION_LOG_MISSING holes,
# 0 valid SESSION_LOG_*.yaml) because run-v-packs never invoked /v-session-log — so per-session turn_count/
# cache_read/verdict that v-batch-health rolls up was never captured, and every manual /v-session-log fork
# hit the multi-unlogged exit-6 refusal. Fix: after each pack finishes, log it by its REAL session_id (which
# the fleet OWNS — we passed --session-id and claude echoes it back in the result JSON) via the pure-bash
# autogen. This is the concurrency-safe EXPLICIT-SID path (no fork ambiguity, no model tokens). FULLY ADDITIVE:
# it runs AFTER the verdict/archival decision, any failure is swallowed, and it never affects a pack's fate.
# Opt out with V_PACK_TELEMETRY=0.  _AUTOGEN overridable so the bite can inject a sentinel.
_AUTOGEN="${_AUTOGEN:-$HOME/.claude/skills/v-session-log/references/v-session-log-autogen.sh}"
sid_of(){ # sid_of <name> -> the session_id claude reported in the log's final result line ('' if none)
  local log="$LOG_DIR/$1.log" sid
  [ -s "$log" ] || return 0
  sid="$(grep -E '"type":[[:space:]]*"result"' "$log" 2>/dev/null | tail -1 | jq -r '.session_id // empty' 2>/dev/null)"
  # T4-F6 (2026-07-02): a watchdog-killed pack has NO result event, so its session was never telemetry-logged
  # (the wave-2 killed packs are exactly the sessions missing from the batch rollup). Every task/system EVENT
  # still carries the pinned sid — parse per JSONL line (structural field only, same AR-4 rule as the
  # reconcile path: a tool-result CONTENT string quoting a session_id must not win).
  [ -n "$sid" ] || sid="$(jq -Rr 'fromjson? | .session_id // empty' "$log" 2>/dev/null | grep -m1 -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
  printf '%s' "$sid"
}
capture_telemetry(){ # capture_telemetry <name> — log this finished pack's session by explicit SID (best-effort)
  [ "${V_PACK_TELEMETRY:-1}" = 1 ] || return 0
  [ -f "$_AUTOGEN" ] || return 0
  local name="$1" sid; sid="$(sid_of "$name")"
  printf '%s' "$sid" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || return 0
  # Cross-session catch-up from OUTSIDE the pack's own session → FORCE_CATCHUP bypasses the resolver's Bug-6
  # exit-7 guard; run in the pack's repo so the autogen roots at the right .v/artifacts. Never blocks the fleet.
  ( cd "${REPO:-.}" 2>/dev/null && V_SESSION_LOG_FORCE_CATCHUP=1 bash "$_AUTOGEN" "$sid" >/dev/null 2>&1 ) || true
}
