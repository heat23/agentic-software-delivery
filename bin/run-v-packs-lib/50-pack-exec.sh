# run-v-packs-lib/50-pack-exec.sh — single-pack execution: log rotation, the idle-watchdog timer,
# the parallel-safe headless `claude -p /v` dispatch (run_pack), and crash-recovery orphan adoption.
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# JOB CONTROL LIVES HERE (`&`, `wait`, `kill -0`, `pkill -P`, sidecar files): everything is inside
# function bodies, so sourcing this file has zero side effects — semantics at call time are identical
# to the former inline definitions. Calls lib siblings late-bound at call time — pack_name (10),
# verdict/_archive_finished_pack path via _adopt_orphans (30/40), capture_telemetry (30) — and reads
# runner globals (LOG_DIR, PACK_ABS, REPO, JOBS, MAXTURNS, PACK_MODEL, TIMEOUT_SECS, V_* tunables).
# Calls NO function that stays inline in the runner (not even die()).
# M-6 (2026-07-02 forensic): ROTATE a pack's log instead of truncating it. A re-run (PARTIAL retry,
# wave-stall retry, a second manual invocation) used to silently overwrite the PRIOR attempt's log —
# destroying forensic evidence of what happened on that earlier pass (a real run lost its run-1
# evidence exactly this way, forcing a needless full re-run to reconstruct what had already been
# learned). Keep ONE prior generation; a second rotation before this one is simply dropped
# (best-effort, never fails the run). Factored out of run_pack() so it's independently testable.
_rotate_pack_log(){ local logf="$1"; [ -s "$logf" ] && mv -f "$logf" "$logf.1" 2>/dev/null; return 0; }

# ── run a single pack (headless /v session) ───────────────────────────────────
# Run one pack PARALLEL-SAFE. The problem: concurrent headless /v sessions resolve their own session id, and
# when the per-process env isn't available they fall back to ~/.claude/runtime/current-session-id — a SINGLE
# global file every SessionStart overwrites (last-writer-wins). Under -jN, sessions then read each OTHER's
# task capture → "/v: no task content" → 0 turns, no work. Fix (verified): pin a unique --session-id per pack
# so CLAUDE_CODE_SESSION_ID inside the session is that id (contamination-proof — /v's resolver Strategy 1), AND
# pre-seed the task into that SID's last-user-prompt file (the resolver's Channel 4) so the task is found
# deterministically without depending on any hook firing, on history.jsonl, or on the clobbered shared file.
# No extra ( ) subshell: run_pack is already backgrounded (`run_pack &`), so cd is isolated and claude stays a
# DIRECT child (the INT/TERM trap's pkill -P reaches it).
# Watchdog: kill a headless /v session that blows the wall-clock ceiling (PACK_TIMEOUT). WHY: a WEDGED session
# — a failed subagent dispatch it keeps polling, a rate-limit stall, an interactive wait that never fires under
# -p — otherwise holds its parallel slot FOREVER and starves the whole run (observed live: packs stuck at 0
# turns for ~1h while the other slots idle). On timeout it stamps a marker verdict() reads (→ `timeout` →
# parked, never re-run) and kills claude + every subagent it spawned (pkill -P) so no orphan keeps burning
# quota. run_pack cancels it the instant claude finishes on its own (the common path), so it never fires for a
# healthy pack. Portable: no GNU `timeout` needed (macOS lacks it) — a plain backgrounded sleep is the timer.
_watchdog(){ # $1=claude pid  $2=logfile
  local cpid="$1" lf="$2" i
  sleep "$PACK_TIMEOUT" 2>/dev/null || return 0
  kill -0 "$cpid" 2>/dev/null || return 0   # claude already exited on its own (run_pack cancels us) → nothing to do
  # BOUNDARY GUARD (fixes a ceiling-adjacent false-timeout race): a pack finishing within ~1s of the ceiling is
  # NOT wedged, but at the wake instant claude may be a not-yet-reaped zombie that `kill -0` still reports alive.
  # Wait a grace second and re-check: a just-finishing process is reaped by then → return (its real verdict
  # stands, no sidecar); a genuinely-stuck one is still alive → park it. Costs +1s on the ceiling, worth it.
  sleep 1; kill -0 "$cpid" 2>/dev/null || return 0
  # A-GRACE (2026-07-12, closes the V-4 "killed 44s after its PRE_FLIGHT PASS was written" class for good):
  # a session whose log is STILL BEING WRITTEN at the ceiling is actively working, not wedged — killing it
  # discards a nearly-complete gauntlet and buys a full re-run (the ACTIVE auto-retry) at ~10x the cost of
  # just waiting. Grant bounded grace: while the log stays fresh (mtime within V_WEDGE_IDLE_SEC), keep
  # waiting in short slices, up to V_PACK_ACTIVE_GRACE_SEC total (default: half the ceiling — so worst case
  # 1.5x the configured wall clock). A session that goes idle mid-grace stops extending within one slice
  # (falls through to the wedged kill below); one that finishes during grace returns with its real verdict.
  # CODEX-002 (2026-07-12 adversarial review): every value entering $(( )) below is numerically
  # validated first — an identifier-shaped env override (V_WEDGE_IDLE_SEC=disabled) previously hit
  # set -u's "unbound variable" INSIDE arithmetic and silently killed this disowned watchdog, leaving
  # a wedged pack unkillable (the exact failure the watchdog exists to prevent). Mirrors the
  # ''|*[!0-9]*) numeric-guard idiom 30-verdict.sh already uses.
  local _gr_budget _gr_slice _gr_idle _gr_fresh=""
  _gr_idle="${V_WEDGE_IDLE_SEC:-300}"; case "$_gr_idle" in ''|*[!0-9]*) _gr_idle=300 ;; esac
  _gr_budget="${V_PACK_ACTIVE_GRACE_SEC:-$(( PACK_TIMEOUT / 2 ))}"; case "$_gr_budget" in ''|*[!0-9]*) _gr_budget=0 ;; esac
  _gr_slice="$_gr_idle"; [ "$_gr_slice" -gt 60 ] && _gr_slice=60
  [ "$_gr_slice" -ge 1 ] || _gr_slice=1
  while [ "$_gr_budget" -gt 0 ]; do
    _lmt="$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo 0)"
    case "$_lmt" in ''|*[!0-9]*) _lmt=0 ;; esac
    if [ $(( $(date +%s) - _lmt )) -le "$_gr_idle" ]; then _gr_fresh=1; else _gr_fresh=0; break; fi   # gone idle mid-grace → wedged kill below
    [ "$_gr_slice" -gt "$_gr_budget" ] && _gr_slice="$_gr_budget"
    sleep "$_gr_slice"; _gr_budget=$(( _gr_budget - _gr_slice ))
    kill -0 "$cpid" 2>/dev/null || return 0   # finished during grace → its real verdict stands, no sidecar
  done
  # Signal the timeout via a SIDECAR file, NOT the log: claude's redirect fd is still open on the log, so a write
  # there races/clobbers (a killed process' death-message overwrote the marker in testing). The sidecar is our
  # own file — race-free — and is written BEFORE the kill so it's guaranteed present if run_pack cancels us mid-kill.
  # (We're disown'd only to mute job-control noise; the INT/TERM trap's `pkill -P` still reaches us via the PPID
  # link — disown drops job-table tracking, not the parent-child process relationship.)
  # T-ACT (2026-07-01 forensic): record WHY it was killed. A session whose log was written within the last
  # V_WEDGE_IDLE_SEC (default 300) was ACTIVELY WORKING — legitimately slower than the ceiling (observed: two
  # concurrent full-suite gauntlets were killed in the FINAL MINUTE of a passing gauntlet), not wedged. One
  # with a stale log genuinely stalled (stuck dispatch / rate-limit wait). The verdict is the same (timeout →
  # park), but the reap message must not call active work "WEDGED" — that steers the operator to the wrong
  # remediation. Sidecar content: "active" | "wedged" (empty/legacy sidecar reads as wedged).
  # CODEX-001 (2026-07-12 adversarial review, causally reproduced): classify from the freshness
  # OBSERVED DURING the grace loop, not from a fresh stat at the classification instant. The grace
  # loop delays this checkpoint by up to its full budget, so a session that was verifiably active at
  # the ceiling (every grace check saw a fresh log) but whose writer stopped during the final slice
  # used to re-stat here and read WEDGED — a proven ~27% misclassification flake in the active-retry
  # fixture, and in production it would strip a legitimately-slow session of its ACTIVE auto-retry.
  # _gr_fresh: 1 = grace budget exhausted while STILL fresh → active by direct observation;
  # 0 = went idle mid-grace → wedged by direct observation; "" = grace disabled/never ran → fall
  # back to the original stat-based classification (pre-A-GRACE behavior, byte-identical).
  if [ "$_gr_fresh" = 1 ]; then
    printf 'active\n' > "$lf.timedout" 2>/dev/null || true
  elif [ "$_gr_fresh" = 0 ]; then
    printf 'wedged\n' > "$lf.timedout" 2>/dev/null || true
  else
    _lmt="$(stat -c %Y "$lf" 2>/dev/null || stat -f %m "$lf" 2>/dev/null || echo 0)"
    case "$_lmt" in ''|*[!0-9]*) _lmt=0 ;; esac
    if [ $(( $(date +%s) - _lmt )) -le "$_gr_idle" ]; then
      printf 'active\n' > "$lf.timedout" 2>/dev/null || true
    else
      printf 'wedged\n' > "$lf.timedout" 2>/dev/null || true
    fi
  fi
  pkill -P "$cpid" 2>/dev/null || true      # kill any subagents it spawned first
  kill -TERM "$cpid" 2>/dev/null || true
  for i in 1 2 3 4 5; do kill -0 "$cpid" 2>/dev/null || return 0; sleep 1; done
  kill -KILL "$cpid" 2>/dev/null || true    # ignored TERM → hard kill
}
# V-DISPATCH-CONTRACT (2026-07-06 forensics): compose the prompt as pack body + a runner-appended
# contract note. WHY: the runnable-pack convention pins every implementation pack to end "do NOT commit;
# leave changes staged" (operator owns ROOT commits) — but run-v-packs' landing layer consumes COMMITS
# (drain → v-merge-back → main), and /v's own in-session WORKTREE checkpoints are an explicitly exempted,
# legitimate commit path (audit-pack-no-commit-footer.test.ts scope note). A live 5-pack batch proved the
# ambiguity is fatal: 3 sessions obeyed the footer LITERALLY, skipped the worktree checkpoint+merge-back
# phase entirely, and left 100% of their work as staged-only strands that nothing could ever land (0/7
# packs landed). This appendix resolves the scope at dispatch time WITHOUT touching the pack files or the
# test-pinned producer templates. It also carries retry continuity (T-RETRY): a relaunched pack must adopt
# its own dead prior attempt's worktree instead of parking as a "duplicate dispatch" of itself (observed:
# all 3 retries no-opped against their own predecessor's worktree). Composed ONCE and used for BOTH the
# claude argv prompt and the resolver seed file, so the /v task capture sees the identical text.
# READ-ONLY pack detection (2026-07-07): an audit/verification pack that declares itself read-only
# ("READ-ONLY: do not edit source / report findings / review only") produces NO commit by design — it
# must NOT be pushed toward a worktree+commit contract, and it completes via a findings artifact, not a
# merge. Match the explicit READ-ONLY: directive form the audit-code producer emits, or an explicit
# machine marker. Precise-but-safe: a false-positive is HARMLESS downstream — /v's completion self-check
# AND the Stop hook both REFUSE the read-only completion for any session that actually wrote product code
# (they compute a zero-diff independently), so a mis-tagged code pack still runs the full gauntlet.
_pack_is_readonly(){ # $1=pack-file -> 0 if the pack declares itself read-only
  # Discriminators that appear in read-only audit/verification packs and NOT in code/fix packs (verified
  # against the v-audit-code producer's output): a READ-ONLY directive ("READ-ONLY:" / "READ-ONLY."), an
  # acceptance line asserting no source was modified, a read-only+verb phrase, or an explicit machine marker.
  # Precision matters BOTH ways: a false-NEGATIVE re-strands the pack (the deadlock this fixes), and a
  # false-POSITIVE would append the read-only "stay inline / do not commit" contract to a real code pack and
  # strand its work — so match directive forms, not a bare "read-only" mention.
  # R1 (broadened 2026-07-07, forensic): a directive is "read-only" immediately followed (after
  # optional whitespace) by ANY punctuation/dash separator — `:` `.` and CRUCIALLY the em-dash/en-dash/hyphen
  # the v-audit-code pack producer actually emits (`READ-ONLY — do not edit source`). The prior `[:.]`-only
  # form false-negatived every em-dash directive, re-stranding w1-pre-flight/99-verify (the exact deadlock
  # the read-only lane exists to close). Negated-class `[^[:alnum:][:space:]]` matches the multibyte dash as
  # one char under UTF-8 without embedding a fragile literal em-dash in the pattern. A bare mention
  # ("add a read-only flag") has a word/space after "read-only" ⇒ no match (verified). Directive-shaped
  # prose ("set it to read-only:") matches as before — harmless (the self-check/Stop hook refuse the
  # read-only completion for any session that wrote product code).
  # R2 (broadened 2026-07-07, forensic — a v-bug-hunt run): the v-bug-hunt producer
  # writes the directive as "Read-only <verification-noun>" ("Read-only pre-flight verification", "Read-only
  # adversarial review") with NO punctuation after "read-only", and asserts read-only-ness as "without
  # modifying source" + "do NOT fix here" (never the audit-code producer's "READ-ONLY:" / "No source
  # modified"). R1's punct-only + narrow verb list false-negatived BOTH w1 packs → the /v session
  # self-tagged read-only and emitted the read-only PASS, but the runner never wrote $logf.readonly, so the
  # readonly-done archive lane (which MUST gate on the runner's own tag, not the session-forgeable marker)
  # could not fire → re-stranded. Add: read-only + a verification noun/verb (incl. pre-flight/adversarial),
  # a "without modifying (the/any) source" assertion, and a "do NOT fix here" directive. Verified against
  # BOTH producers' full pack sets: every w1/99 read-only pack matches; every wN-hardening + wave-0 fix pack
  # stays code/full (a false-positive would append the "no commit" contract to a code pack and strand it).
  grep -qiE '(^|[^[:alnum:]])read-?only[[:space:]]*[^[:alnum:][:space:]]' "$1" 2>/dev/null && return 0
  grep -qiE 'read-?only[[:space:]]+(pre-?flight|adversarial|confirm|verif|review|audit|report|analy|assess|inspect|scan|do[[:space:]]*n)' "$1" 2>/dev/null && return 0
  grep -qiE '(without|with[[:space:]]+no|not)[[:space:]]+(modif|chang|edit|touch)[a-z]*[[:space:]]+((the|any)[[:space:]]+)?source' "$1" 2>/dev/null && return 0
  # R4 (broadened 2026-07-13, forensic — a w2-review pack): the acceptance line the review-dispatch
  # pack producer emits is "No source files were modified by this pack" — a noun phrase ("files were") sits
  # BETWEEN "source" and the verb, which the prior `no source (was |is )?<verb>` (verb immediately after
  # "source") false-negatived → the pack was never tagged read-only → it got the CODE dispatch contract
  # (hung on a background wait for its parallel reviewer dispatches, parked 0-turn) AND reconcile_parked_readonly
  # could never fire. Allow up to 4 intervening words and stem the verb so "no source [files were] modif/chang/
  # edit/touch…" all match. Backward-compatible ({0,4} permits zero → "no source edited" still matches). A
  # false-positive stays HARMLESS (self-check + Stop hook refuse the read-only completion for any session that
  # actually wrote product code), so the wider match cannot strand a real code pack.
  grep -qiE 'no source([[:space:]]+[a-z]+){0,4}[[:space:]]+(modif|chang|edit|touch)' "$1" 2>/dev/null && return 0
  grep -qiE 'do(es)?[[:space:]]*n.?.?t[[:space:]]+fix[[:space:]]+(here|in[[:space:]]+this|anything|it)' "$1" 2>/dev/null && return 0
  grep -qiE '<!--[[:space:]]*v-pack:[[:space:]]*read-?only' "$1" 2>/dev/null && return 0
  return 1
}
_pack_prompt(){ # $1=pack-file $2=pack-name -> stdout: pack body + dispatch-contract appendix
  cat "$1"
  printf '\n\n---\nRUN-V-PACKS DISPATCH CONTRACT (appended by the runner — scope clarifications, not a new task):\n'
  if _pack_is_readonly "$1"; then
    printf '%s\n' \
      "- READ-ONLY VERIFICATION PACK: this pack changes NO tracked source and produces NO commit by design." \
      "  Stay INLINE — do NOT create a session worktree, do NOT edit tracked source, do NOT commit or merge." \
      "  Run the requested gates/review and RECORD findings in a durable artifact (PRE_FLIGHT_REPORT_<sid>.md," \
      "  AGENT_REVIEW_<sid>.md, or a BLOCKED_<sid>.md capturing the findings for the next wave). When the audit" \
      "  is complete (all clean, or findings recorded), run /v's completion self-check — it recognizes a" \
      "  read-only verification session and PASSES without demanding the code-change gauntlet. Do NOT fabricate" \
      "  AGENT_REVIEW/QA/IMPACT_MAP/VERIFY_DONE for a zero-diff session just to satisfy a gate." \
      "- COMPLETION TOKEN IS MANDATORY (2026-07-07 forensic — the #1 way read-only packs strand here):" \
      "  the runner archives this pack ONLY when your session's TERMINAL message contains the exact line" \
      "  \`V-COMPLETION-SELFCHECK: PASS\` that the completion self-check emits. A natural-language summary of" \
      "  your findings — however complete, and even if the deliverable artifact is on disk — is NOT recognized:" \
      "  the pack PARKS to .needs-review/ and the next wave is BLOCKED. So ACTUALLY RUN the completion self-check" \
      "  as your final act (do not merely describe the outcome in prose), and surface its" \
      "  \`V-COMPLETION-SELFCHECK: PASS — read-only verification (<artifact>)\` line verbatim in your last message." \
      "  If /v ran your work in a fork (context:fork, parent closes at 0 turns), that token MUST appear in the" \
      "  PARENT's final message the runner reads — not only inside the fork transcript, which the archive gate" \
      "  does not consume for the read-only lane."
  else
    printf '%s\n' \
      "- LANDING: this pack runs under run-v-packs, whose landing layer consumes COMMITS (worktree checkpoint" \
      "  commits -> gauntlet -> v-merge-back -> main). Any 'do NOT commit; leave changes staged' line above" \
      "  scopes to the REPO ROOT working tree ONLY. Inside your /v session WORKTREE, follow /v's normal flow:" \
      "  checkpoint-commit your work in the worktree, run the full gauntlet, and merge back to main. Work left" \
      "  only STAGED (in any tree) cannot land and will strand — that is a FAILED pack, not compliance." \
      "- WORKTREE: audit-driven fixes require a session worktree (W25-F25, no exceptions) — never implement or" \
      "  stage deliverables at the repo root."
  fi
  # HEADLESS GAUNTLET DISCIPLINE (W-perf9; 2026-07-07 forensic — the DOMINANT strand cause).
  # Two packs stranded identically: the session dispatched gauntlet gates (codex/agent review, verify-done) with
  # run_in_background, then ENDED its turn with "I'll stop issuing calls now and wait for the background task
  # notifications." Under `claude -p` there is no interactive loop to deliver those notifications, so the turn
  # ended for good with the gauntlet HALF-DONE (num_turns:0, full session cost spent) — no VERIFY_DONE, a stub AGENT_REVIEW —
  # and the committed work was stranded ungated forever (the merge W-GATE requires VERIFY_DONE). This clause is
  # the source fix: it applies to EVERY pack (read-only or code) and is emitted for every dispatch/retry.
  printf '%s\n' \
    "- HEADLESS EXECUTION — RUN EVERY GATE SYNCHRONOUSLY (this is the #1 way work is lost here): you are running" \
    "  under \`claude -p\` (headless). Background-task completion notifications do NOT reliably re-invoke you in" \
    "  this mode. If you dispatch a gauntlet gate (pre-flight, codex/agent review, verify-done, QA) with" \
    "  run_in_background and then STOP your turn to 'wait for the notification', the SESSION ENDS right there with" \
    "  your gauntlet incomplete: no VERIFY_DONE_REPORT, possibly only a stub AGENT_REVIEW. Your committed work is" \
    "  then stranded ungated — the merge W-GATE refuses it and the pack is parked for manual repair. Therefore:" \
    "  dispatch every gate in the FOREGROUND and BLOCK on it (a Task WITHOUT run_in_background, or a synchronous" \
    "  Bash dispatch that waits for the gate's report file to exist), finish them one at a time, and NEVER end a" \
    "  turn with 'I'll wait for the background task' while any gate report is still owed. Complete the FULL" \
    "  gauntlet in-session (PRE_FLIGHT + AGENT_REVIEW + VERIFY_DONE at minimum), THEN merge back. An unfinished" \
    "  gauntlet is a FAILED pack, not a deferral."
  local prior="$LOG_DIR/$2.log.1" psid=""
  if [ -s "$prior" ] || [ -f "$LOG_DIR/$2.log.activeretries" ]; then
    [ -s "$prior" ] && psid="$(grep -E '"session_id"' "$prior" 2>/dev/null \
      | jq -Rr 'fromjson? | .session_id // empty' 2>/dev/null \
      | grep -m1 -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
    printf '%s\n' \
      "- RETRY CONTINUITY: a PRIOR attempt of THIS SAME pack already ran and was killed or parked${psid:+ (its session id: $psid)}." \
      "  If you find an existing worktree/branch for this same finding whose owning session is DEAD (its" \
      "  .claude-session-lock PID fails kill -0, or it has no lock), that is YOUR OWN prior attempt — NOT a live" \
      "  sibling. ADOPT it: re-key its session lock to your session id, verify its staged/committed work, finish" \
      "  the remaining gauntlet, COMMIT in that worktree, and merge back. Do NOT park it as a duplicate dispatch," \
      "  do NOT re-implement from scratch, and do NOT copy its files to the repo root."
  fi
}
# ── STRAND-RESUME (2026-07-12, forensic): bounded auto-resume of a stranded pack ──
# THE dominant unattended-run killer, observed live twice in one wave: a context:fork /v session does real
# work (suites green, checkpoint commit, reviewers dispatched in the BACKGROUND), then ends its turn on
# "Pausing here — waiting for the background dispatch notification". Under `claude -p` that notification is
# NEVER delivered — the CLI exits cleanly (num_turns=0), teardown kills the background reviewers, and the
# gauntlet strands: verdict() → inconclusive → parked to .needs-review/ for a HUMAN. Prompt-level discipline
# (the HEADLESS GAUNTLET DISCIPLINE preamble above) demonstrably gets ignored deep into long sessions, so
# ENFORCE at the runner: when the exit looks stranded — clean result event, num_turns==0, real fork output
# (≥ V_FORK_WORK_MIN_OUT tokens), NO terminal token — `claude --resume <sid>` with an explicit
# finish-the-gauntlet prompt, appending to the SAME log, up to V_PACK_STRAND_RESUME times (default 2). The
# resume holds only this pack's own wave slot (run_pack is already backgrounded) and gets its own watchdog.
# SAFE BY CONSTRUCTION: fires only when NO terminal token exists (can never re-run a completed gauntlet —
# verdict() reads the LAST result event, so a successful resume's GAUNTLET_ATTESTED wins); ratelimit/auth/
# no-task results are EXCLUDED (those want the wave-level wait/retry lanes, not a resume burned against a
# closed quota window); a watchdog .timedout kill is EXCLUDED (the timeout lane owns it). Disposal counters
# are untouched — a resume that still strands falls through to the normal inconclusive park, one attempt
# poorer but no worse. Disable with V_PACK_STRAND_RESUME=0.
_strand_is_stranded(){ # $1=logfile -> 0 iff last result is a clean 0-turn strand with real fork work and no terminal token
  local log="$1" res hay nt out
  [ -f "${log}.timedout" ] && return 1
  res="$(grep -E '"type":[[:space:]]*"result"' "$log" 2>/dev/null | tail -1)"; [ -n "$res" ] || return 1
  [ "$(printf '%s' "$res" | jq -r '.subtype // ""' 2>/dev/null)" = success ] || return 1
  [ "$(printf '%s' "$res" | jq -r '.is_error' 2>/dev/null)" = false ] || return 1
  nt="$(printf '%s' "$res" | jq -r '.num_turns // empty' 2>/dev/null)"; [ "$nt" = 0 ] || return 1
  hay="$(printf '%s' "$res" | jq -r '.result // ""' 2>/dev/null)"
  # terminal tokens — hay-scoped exactly like verdict()'s fork lane (anti echo-spoof)
  printf '%s' "$hay" | grep -qE 'GAUNTLET_ATTESTED|V-COMPLETION-SELFCHECK:[[:space:]]*PASS' 2>/dev/null && return 1
  # limit/auth/no-task shapes belong to their own verdict lanes. SINGLE-SOURCED from 30-verdict.sh's
  # _VD_*_RE constants (FND-001, adversarial review 2026-07-12: a hand-maintained copy here drifted
  # within hours — missing auth-expired/reset-time phrasings — and would have burned resume attempts
  # against limited sessions). FAIL CLOSED: constants unset (file sourced standalone without
  # 30-verdict.sh) ⇒ cannot verify the exclusions ⇒ do NOT resume.
  { [ -n "${_VD_RATELIMIT_RE:-}" ] && [ -n "${_VD_AUTHDROP_RE:-}" ] && [ -n "${_VD_NOTASK_RE:-}" ]; } || return 1
  printf '%s' "$hay" | grep -qiE "${_VD_RATELIMIT_RE}|${_VD_AUTHDROP_RE}|${_VD_NOTASK_RE}" 2>/dev/null && return 1
  out="$(printf '%s' "$res" | jq -r '([.modelUsage[]?.outputTokens | numbers] | add) // 0' 2>/dev/null)"
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  [ "$out" -ge "${V_FORK_WORK_MIN_OUT:-1000}" ] || return 1
  return 0
}
_strand_resume_prompt(){ # $1=attempt $2=max
  printf '%s' "STRAND-RESUME (automated by run-v-packs, attempt $1/$2): your previous turn ended by waiting for a background notification. This is a HEADLESS claude -p run — background-task and subagent completion notifications are NEVER delivered here, and your background dispatches were killed when that turn ended. Your implementation may already be complete on disk in your /v worktree. Finish the pack NOW without waiting on anything: (1) locate your worktree and session artifacts (.v/artifacts/*_<your-session-id>.md) and take stock of which gauntlet gates are done vs missing; (2) re-run every missing/incomplete gate as a BLOCKING FOREGROUND call (bash ~/.claude/skills/v/references/v-dispatch-subagent.sh <agent> — NEVER a backgrounded dispatch you then wait on). For AGENT_REVIEW use the skeleton generator (v-emit-agent-review-skeleton.sh) — it derives the hostile-focus verdict from v-hostile-required.sh; if HOSTILE_REQUIRED=1, dispatch the reviewer WITH hostile adversarial focus; (3) drive QA to 'verdict: pass', commit remaining work in the worktree, run v-merge-back.sh, then v-gauntlet-attest.sh, and print the GAUNTLET_ATTESTED line in your FINAL message. If the work is already fully merged to main, print the V-COMPLETION-SELFCHECK: PASS no-op tokens instead. NEVER end a turn on a promise to wait — end only on a terminal token."
}

run_pack(){
  local f="$1" name logf sid seed cpid wpid prompt; name="$(pack_name "$f")"; logf="$LOG_DIR/$name.log"; mkdir -p "$(dirname "$logf")"
  # NOTE: _pack_prompt reads the PRIOR rotated log ($logf.1) for retry continuity — compose BEFORE rotation
  # would read the wrong generation, so compose right after rotation (the just-rotated attempt becomes .1).
  _rotate_pack_log "$logf"
  # fresh: no stale result, timeout flag, or pid marker from a prior attempt of this SAME pack name (a
  # leftover .pid here would only exist if a previous crashed run's orphan for this pack was already
  # handled by _adopt_orphans before dispatch reached us — clearing it defensively costs nothing).
  # NOTE: $logf.activeretries is deliberately NOT cleared here — it counts consecutive ACTIVE (near-
  # completion) watchdog timeouts across relaunches of this pack, and must survive a retry to be useful;
  # it is cleared only when the pack is finally disposed (_archive_finished_pack).
  : > "$logf" 2>/dev/null || true; rm -f "$logf.timedout" "$logf.pid" 2>/dev/null || true
  prompt="$(_pack_prompt "$f" "$name")"
  # READ-ONLY TAG (2026-07-07): record whether this is a read-only verification pack. The name-keyed
  # $logf.readonly is the runner-side signal (verdict()/archive lane); the sid-keyed .v/tmp marker (written
  # below, once the sid is known) is the SESSION-side signal that /v's completion self-check + the Stop hook
  # read from inside the running session at $REPO. Reset on every (re)dispatch so a retry re-derives it.
  if _pack_is_readonly "$f"; then : > "$logf.readonly" 2>/dev/null || true; else rm -f "$logf.readonly" 2>/dev/null || true; fi
  # PR OPT-IN (2026-08-22, operator instruction): a pack may request permission to open a pull request
  # by declaring `Allow-PR:` / `PR-Mode:` / `PR-Target:` in its BODY. Only then do we export the two
  # signals that ~/.claude/hooks/block-pr-creation.sh v2.0.0 requires; every other pack session inherits
  # neither, so the hook's default deny stands unchanged. Deliberately a LOCAL, not a helper function:
  # scripts/run-v-packs-structure-test.sh pins an exhaustive LIB_FNS whitelist cross-checked against the
  # runner's SECTION INDEX, and a new lib function would turn it red. Value is the declared target (or 1).
  # NOTE: an env-assignment PREFIX cannot come from a variable — bash parses assignments before
  # expansion, so `$V cmd` runs a command literally named "FOO=bar". Hence an array handed to `env`,
  # which also keeps paths containing spaces intact. `exec env ... claude` still leaves claude as a
  # DIRECT child of run_pack (env execs in-place, same PID), so the INT/TERM `pkill -P` and the
  # watchdog kill both still reach it — the property the exec comment above is protecting.
  local _pr_decl _pr_tgt
  local -a _pr_env=()
  _pr_decl="$(grep -m1 -E '^[[:space:]]*(Allow-PR|PR-Mode|PR-Target)[[:space:]]*:[[:space:]]*[^[:space:]]' "$f" 2>/dev/null || true)"
  if [ -n "$_pr_decl" ]; then
    _pr_tgt="$(printf '%s' "$_pr_decl" | sed 's/^[^:]*:[[:space:]]*//' | awk '{print $1}')"
    _pr_env=( "V_PACK_ALLOW_PR=${_pr_tgt:-1}" "V_PACK_FILE=$f" )
  fi
  sid="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
  if [ -n "$sid" ]; then
    seed="$HOME/.claude/runtime/last-user-prompt-${sid}.txt"
    { mkdir -p "$HOME/.claude/runtime" && printf '%s\n' "$prompt" >"$seed"; } 2>/dev/null || seed=""
    if [ -f "$logf.readonly" ]; then
      mkdir -p "$REPO/.v/tmp" 2>/dev/null || true
      printf 'SID=%s\nPACK=%s\nreason=read-only verification pack (dispatched by run-v-packs)\n' "$sid" "$name" \
        > "$REPO/.v/tmp/pack-readonly-${sid}.marker" 2>/dev/null || true
    fi
    # `exec` so claude REPLACES the subshell → it is a DIRECT child of run_pack: the INT/TERM trap's `pkill -P`
    # AND the watchdog's kill both reach it (a non-exec wrapper subshell would orphan claude on kill).
    # V_WAIT_GATE=block (2026-07-12, H4-1b): in a headless pack session the Stop hook's WAIT-STRAND net
    # must BLOCK (not warn) a turn that ends on a promise to wait while the gauntlet is incomplete — a
    # warn is invisible under -p and the session simply exits stranded. Scoped here (pack sessions only);
    # interactive sessions keep the hook's soak default. A false block just costs one more poll loop and
    # is bounded by the watchdog.
    ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_SESSION_ID="$sid" V_WAIT_GATE=block exec env ${_pr_env[@]+"${_pr_env[@]}"} claude "${CLAUDE_ARGS[@]}" --session-id "$sid" "$prompt" ) >"$logf" 2>&1 &
    cpid=$!; printf '%s\n' "$cpid" >"$logf.pid" 2>/dev/null || true
    _watchdog "$cpid" "$logf" & wpid=$!; disown "$wpid" 2>/dev/null || true
    wait "$cpid" 2>/dev/null
    kill "$wpid" 2>/dev/null   # claude finished first → cancel the watchdog's pending timer
    rm -f "$logf.pid" 2>/dev/null || true   # CRASH RECOVERY: reaped normally — no orphan to detect on a future startup
    [ -n "$seed" ] && rm -f "$seed" 2>/dev/null || true
    # STRAND-RESUME (see header above): bounded in-slot continuation of a stranded 0-turn session.
    local _sr=0 _srmax="${V_PACK_STRAND_RESUME:-2}"
    while [ "$_sr" -lt "$_srmax" ] 2>/dev/null && _strand_is_stranded "$logf"; do
      _sr=$((_sr+1))
      echo "  ↻ $(date +%H:%M:%S) STRAND-RESUME $_sr/$_srmax: $name exited cleanly at 0 turns with real fork work but no terminal token — resuming sid ${sid%%-*}… to finish the gauntlet (same log)"
      ( cd "$REPO" && CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_SESSION_ID="$sid" V_WAIT_GATE=block exec env ${_pr_env[@]+"${_pr_env[@]}"} claude "${CLAUDE_ARGS[@]}" --resume "$sid" "$(_strand_resume_prompt "$_sr" "$_srmax")" ) >>"$logf" 2>&1 &
      cpid=$!; printf '%s\n' "$cpid" >"$logf.pid" 2>/dev/null || true
      # FND-003 (adversarial review 2026-07-12): a resume is a "finish the gauntlet" nudge, not a fresh
      # full-length session — give its watchdog HALF the pack ceiling so the compounded worst case
      # (1 original + V_PACK_STRAND_RESUME resumes) stays ~2× the ceiling, not ~3×+.
      PACK_TIMEOUT=$(( PACK_TIMEOUT / 2 )) _watchdog "$cpid" "$logf" & wpid=$!; disown "$wpid" 2>/dev/null || true
      wait "$cpid" 2>/dev/null
      kill "$wpid" 2>/dev/null
      rm -f "$logf.pid" 2>/dev/null || true
    done
  else
    ( cd "$REPO" && V_WAIT_GATE=block exec env ${_pr_env[@]+"${_pr_env[@]}"} claude "${CLAUDE_ARGS[@]}" "$prompt" ) >"$logf" 2>&1 &   # uuidgen absent → original path (no sid ⇒ no strand-resume)
    cpid=$!; printf '%s\n' "$cpid" >"$logf.pid" 2>/dev/null || true
    _watchdog "$cpid" "$logf" & wpid=$!; disown "$wpid" 2>/dev/null || true
    wait "$cpid" 2>/dev/null
    kill "$wpid" 2>/dev/null || true
    rm -f "$logf.pid" 2>/dev/null || true
  fi
}

# ── CRASH RECOVERY (2026-07-04): adopt orphaned claude sessions left by a runner that died mid-run ──────
# WHY: if run-v-packs itself is killed (host restart, OOM-kill, `kill -9` on the runner) while a pack's
# `claude` child is still running, that child can OUTLIVE the runner — bash gives no guarantee a background
# job receives SIGHUP when a non-interactive script's process dies (empirically: an orphaned claude process
# kept running after its launching shell was `kill -9`'d). The single-runner LOCK correctly refuses a SECOND
# concurrent run-v-packs, but once that lock is reclaimed as STALE (the old runner is provably dead — see
# main()'s lock-reclaim check), nothing previously stopped a fresh invocation from RE-LAUNCHING the same
# pack while the dead runner's orphaned claude session for it is still alive — a duplicate concurrent
# session on the exact same pack/sid (the same double-dispatch waste FND-DUP already closed for a single
# run, reopened across a crash boundary). run_pack() drops a per-pack pidfile ($LOG_DIR/<name>.log.pid) at
# launch and removes it on every normal reap path (see above); this can only ever find one here if a prior
# run-v-packs died before reaching that cleanup.
# SAFE BY CONSTRUCTION: called exactly once, in main(), AFTER the single-runner lock is held — so any pid a
# pidfile still names at this point CANNOT belong to a currently-running SIBLING runner (one would have
# refused our lock first). Confirms the pid is actually a `claude` process (never a recycled pid — same
# idiom the lock-reclaim check already uses) before treating it as a live orphan. Bounded wait
# (V_PACK_ORPHAN_GRACE_SEC, default 600s): if still alive after that, reaped the same subtree-safe way the
# per-pack watchdog does (pkill -P the subtree, then TERM, then KILL) so its pack can be picked up cleanly
# by the normal dispatch loop. If the orphan finishes (naturally or via reap) with a pack file still present
# in the queue, dispose it through the SAME _archive_finished_pack path the live reap loop uses — otherwise
# a genuinely-completed orphan would be silently re-run from scratch, wasting a duplicate full gauntlet.
_adopt_orphans(){
  local pf name cpid grace elapsed hb
  find "$LOG_DIR" -type f -name '*.log.pid' 2>/dev/null | while IFS= read -r pf; do
    name="${pf#"$LOG_DIR"/}"; name="${name%.log.pid}"
    cpid="$(head -1 "$pf" 2>/dev/null | tr -dc '0-9')"
    if [ -z "$cpid" ] || ! kill -0 "$cpid" 2>/dev/null || ! ps -o command= -p "$cpid" 2>/dev/null | grep -qi claude; then
      rm -f "$pf" 2>/dev/null   # stale (already dead) or the pid was recycled onto an unrelated process
      continue
    fi
    echo "⚠ CRASH RECOVERY: found a still-alive claude session (pid $cpid) for pack '$name' with no owning run-v-packs — a prior run likely crashed mid-pack. Waiting (never double-dispatching the same pack)…"
    grace="${V_PACK_ORPHAN_GRACE_SEC:-600}"; elapsed=0; hb=0
    while kill -0 "$cpid" 2>/dev/null && [ "$elapsed" -lt "$grace" ]; do
      sleep 5; elapsed=$((elapsed+5))
      if [ "$((elapsed % 60))" -eq 0 ] && [ "$hb" != "$elapsed" ]; then
        echo "  … still waiting on the orphaned session for '$name' (pid $cpid; ${elapsed}s/${grace}s grace)"; hb="$elapsed"
      fi
    done
    if kill -0 "$cpid" 2>/dev/null; then
      echo "  ⏱ orphan for '$name' (pid $cpid) still alive after ${grace}s grace — reaping it (subtree-safe) so its pack can be relaunched cleanly."
      pkill -P "$cpid" 2>/dev/null || true
      kill -TERM "$cpid" 2>/dev/null || true
      sleep 2; kill -0 "$cpid" 2>/dev/null && kill -KILL "$cpid" 2>/dev/null || true
      printf 'wedged\n' >"$LOG_DIR/$name.log.timedout" 2>/dev/null || true
    else
      echo "  ✓ orphan for '$name' finished on its own during the wait."
    fi
    rm -f "$pf" 2>/dev/null
    # If the crashed run never got to dispose this pack (its file is still sitting in the queue), do it now
    # via the SAME verdict-driven path the live reap loop uses — a completed orphan must not be silently
    # re-run from scratch, and a genuinely-parked one must not be left contradicting the queue either.
    local _of; _of="$(find "$PACK_ABS" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null \
                        | while IFS= read -r _c; do [ "$(pack_name "$_c")" = "$name" ] && printf '%s\n' "$_c" && break; done)"
    if [ -n "$_of" ]; then
      case "$(verdict "$name")" in
        done|noop|readonly-done|inconclusive|timeout) _archive_finished_pack "$name" "$_of" ;;
        *) : ;;   # partial/no-task/ratelimit/error/incomplete — leave it queued, normal dispatch retries it
      esac
      capture_telemetry "$name"
    fi
  done
}
