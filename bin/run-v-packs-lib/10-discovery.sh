# run-v-packs-lib/10-discovery.sh — pack discovery, wave parsing, and count/format helpers.
#
# SOURCED (never executed) by ~/.local/bin/run-v-packs via its lib seam. Keeping these here — instead of
# inline in the runner — lets the 1400-line entry point stay navigable while `source run-v-packs` (every
# run-v-packs-*-test.sh harness) still transitively defines every function. Do NOT add `set` flags or a
# shebang: this file inherits the runner's `set -uo pipefail` and its bash (4+ after the runner's 3.2
# re-exec, or stock 3.2 when a test sources it) — it must parse and run under BOTH, same as the runner.
# Globals referenced at call time (late-bound, set by the runner/tests before these run): PACK_ABS,
# PACK_MAX_BYTES, DONE_DIR, NEEDS_DIR. No functions in this file call die() or any other runner helper.

# ── pack discovery (wave-aware) ───────────────────────────────────────────────
# A pack = a .txt/.md file whose first non-blank line is a `/v` (or `/v-<skill>`) invocation,
# under the pack dir (depth ≤ 2 so wave-N/ subfolders are seen), excluding hidden dirs (.done/.runlogs/.bak).
is_pack(){ # $1=file -> 0 if it is a runnable /v pack
  local f="$1" b first sz
  b="$(basename "$f")"
  case "$b" in 00-README.md|README.md) return 1 ;; esac
  sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"; [ "${sz:-0}" -le "$PACK_MAX_BYTES" ] || return 1
  first="$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)"
  case "$first" in '/v '*|'/v-'*|'/v') return 0 ;; *) return 1 ;; esac
}

# Normalize a wave-prefixed name to lowercase for prefix parsing — W1-/Wave-1/WAVE-1 all become w…/wave-….
# Matches ONLY names that look wave-prefixed ([Ww] + digit, or the word wave in any case + [-_digit]) so
# ordinary uppercase names (Wrap-up.txt, Weekly-notes.md, a Waves/ dir) pass through untouched.
_wave_norm(){ case "$1" in
    [Ww][0-9]*|[Ww][Aa][Vv][Ee][-_0-9]*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
    *) printf '%s' "$1" ;;
  esac; }

wave_of(){ # $1=full path -> wave number (integer; 0 = unordered/first, 9999 = verify/last)
  # ${n%%[^0-9]*} keeps only the LEADING digit run, so a malformed prefix like w1x- yields 1, never a
  # non-integer label like "1x" (which sort -nu would collapse into wave 1 and silently drop packs).
  # R2/R3: tolerate an uppercase W1-/Wave-1/WAVE-1 prefix (a plausible human typo) — case-sensitive patterns
  # silently demoted W1-foo.txt to wave 0 (ran FIRST, before its dependencies). R3 caught that R2's Title-Case-
  # only normalize (`b="w${b#W}"`) turned WAVE-1 into the still-unmatched "wAVE-1" — lowercase the WHOLE name
  # instead (safe: wave_of only parses the prefix; it never returns the name). Shared with
  # warn_skipped_lower_waves so the runner and its ordering safety-net can never disagree on a wave prefix.
  local b d n; b="$(_wave_norm "$(basename "$1")")"; d="$(_wave_norm "$(basename "$(dirname "$1")")")"
  case "$b" in 99-*|99_*) echo 9999; return ;; esac                       # verify always last
  case "$d" in                                                            # subfolder wins
    wave-[0-9]*|wave_[0-9]*) n="${d#wave}"; n="${n#[-_]}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;
    w[0-9]*)                 n="${d#w}";    n="${n%%[^0-9]*}";              echo "${n:-0}"; return ;;
  esac
  case "$b" in                                                            # else filename prefix w<N>-/w<N>_
    w[0-9]*[-_]*) n="${b#w}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;
    wave[-_0-9]*) n="${b#wave}"; n="${n#[-_]}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;   # R3: wave1-/WAVE1- filename form
  esac
  echo 0
}

# Prune dot-entries (.done/.runlogs/.gitignore/.bak) by LITERAL relative-path test, not find -path: find -path
# runs the pattern through fnmatch, so a [ ? or * in PACK_ABS (e.g. a project dir named proj[2025]) would
# mis-parse "$PACK_ABS/.*" and the prune would silently fail (re-running archived .done/ work). Stripping the
# PACK_ABS prefix with ${f#"$PACK_ABS"/} is a literal match, then we glob only the safe relative remainder.
_scan(){ local f rel
  find "$PACK_ABS" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | while IFS= read -r f; do
    rel="${f#"$PACK_ABS"/}"
    case "$rel" in .*|*/.*) continue ;; esac     # dot-entry directly under root, or under any hidden subdir
    printf '%s\n' "$f"
  done
}
list_all_packs(){ local f; _scan | while IFS= read -r f; do is_pack "$f" || continue; [ "$(wave_of "$f")" = 9999 ] && continue; printf '%s\n' "$f"; done | sort; }
list_packs_in_wave(){ local target="$1" f; _scan | while IFS= read -r f; do is_pack "$f" || continue; [ "$(wave_of "$f")" = "$target" ] && printf '%s\n' "$f"; done | sort; }
waves_present(){ local f; _scan | while IFS= read -r f; do is_pack "$f" || continue; local w; w="$(wave_of "$f")"; [ "$w" = 9999 ] || echo "$w"; done | sort -nu; }
list_verify_packs(){ local f; _scan | while IFS= read -r f; do is_pack "$f" || continue; [ "$(wave_of "$f")" = 9999 ] && printf '%s\n' "$f"; done | sort; }
# The single VERIFY pack that runs last. Lexicographically-first of the 99-* packs (deterministic, NOT the old
# filesystem-order `break`). If the operator left MORE than one 99-* pack, only this one runs — main() warns
# loudly about the rest (see warn_multiple_verify_packs) so extras are never SILENTLY dropped.
verify_pack(){ list_verify_packs | head -1; }

# Per-candidate rejection reasons for the "no packs found" banner. Discovery is all-or-nothing from the
# operator's side: is_pack() silently returns 1, so a tree whose producer skipped the convention's
# self-validate (§ Self-validate the emitted tree) reports a bare "no packs found" with nothing to act on
# — observed live 2026-07-20, a tree of 15 well-formed packs that every single file opened with a
# `# Pack: <name>` markdown title above its `/v` line, costing a manual bisect to diagnose. Printing the
# actual first line of each rejected candidate turns that into a one-look fix. READMEs are skipped by
# design and are NOT reported as problems.
explain_rejected_candidates(){ local f b first sz shown=0
  _scan | while IFS= read -r f; do
    b="$(basename "$f")"
    case "$b" in 00-README.md|README.md) continue ;; esac
    is_pack "$f" && continue
    [ "$shown" = 0 ] && { echo "  rejected candidates (why each was not treated as a pack):"; shown=1; }
    sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
    if [ "${sz:-0}" -gt "$PACK_MAX_BYTES" ]; then
      printf '    %-34s %s bytes > %s limit — split into narrower packs\n' "$b" "${sz:-0}" "$PACK_MAX_BYTES"
    else
      first="$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)"
      if [ -z "$first" ]; then
        printf '    %-34s file is empty/blank\n' "$b"
      else
        printf '    %-34s first line is: %.60s\n' "$b" "$first"
        printf '    %-34s   → must start with "/v " (or "/v-<skill>"); no title/frontmatter above it\n' ""
      fi
    fi
  done
}
oversized_packs(){ local f sz; _scan | while IFS= read -r f; do
  case "$(basename "$f")" in 00-README.md|README.md) continue ;; esac
  sz="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"; [ "${sz:-0}" -gt "$PACK_MAX_BYTES" ] || continue
  case "$(grep -m1 -v '^[[:space:]]*$' "$f" 2>/dev/null)" in '/v '*|'/v-'*|'/v') printf '%s\t%s\n' "$sz" "$f" ;; esac
done; }

# Keep the path structure (do NOT flatten / to -): the log lives at $LOG_DIR/<rel-without-ext>.log, mirroring
# the pack tree. Flattening would map both wave-1/foo.txt and a flat wave-1-foo.txt to the same log name → the
# two runs clobber one log → verdict() reads the wrong result → a not-yet-attested pack could be mis-archived.
pack_name(){ printf '%s' "${1#"$PACK_ABS"/}" | sed -E 's/\.(txt|md)$//'; }
count_done(){ find "$DONE_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | wc -l | tr -d ' '; }

# ── parked-pack accounting + acknowledged quarantine (2026-07-13) ──────────────────────────────────
# A pack PARKED in .needs-review/ (0-turn strand / timeout, no terminal token) forces rc=2 on EVERY run so
# the operator triages it — correct the first time, pure noise once they have. When a park can't be finished
# headlessly (a stale-branch rebase, a dependency on unlanded work) the operator consciously HOLDS it for
# interactive completion; a permanent rc=2 then just trains them to ignore the runner's exit code. An
# `.acknowledged` ledger in .needs-review/ records that decision: each named pack is reported as
# "quarantined (acknowledged)" and dropped from the ACTIONABLE parked count — no rc=2, no "await your review"
# nag, no wave-barrier block, no DONE- rename that would bury the held work. A park NOT listed (e.g. a FRESH
# strand parked AFTER the ledger was written) still counts and still nags, so the autonomy invariant (never
# exit 0 with un-triaged work outstanding) holds. Remove a line to re-surface that pack. Ledger format: one
# pack basename (no .txt/.md) per line; blank lines and #-comments ignored; an inline "name  # note" is fine
# (the first whitespace token is the name).
_ack_ledger(){ printf '%s' "${NEEDS_DIR:-}/.acknowledged"; }
_ack_names(){ local L line; L="$(_ack_ledger)"; [ -f "$L" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; set -- $line; [ -n "${1:-}" ] && printf '%s\n' "$1"
  done < "$L"; }
_is_ack_quarantined(){ local b="${1##*/}"; b="${b%.txt}"; b="${b%.md}"; _ack_names | grep -Fxq "$b"; }
# parked pack FILES only — the README/QUARANTINE docs that share the .md extension are not packs (mirrors
# is_pack's 00-README.md/README.md exclusion; they were previously miscounted as parked, inflating rc=2).
_list_needs(){ find "$NEEDS_DIR" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | while IFS= read -r f; do
    case "$(basename "$f")" in 00-README.md|README.md|QUARANTINE-README.md) continue ;; esac; printf '%s\n' "$f"
  done; }
# ACTIONABLE parked packs (EXCLUDES acknowledged) — what rc=2 and every "needs attention" path key off.
count_needs(){ local n=0 f
  while IFS= read -r f; do [ -n "$f" ] || continue; _is_ack_quarantined "$f" || n=$((n+1)); done <<EOF
$(_list_needs)
EOF
  printf '%s' "$n"; }
# operator-ACKNOWLEDGED quarantine — reported separately, never actionable.
count_needs_ack(){ local n=0 f
  while IFS= read -r f; do [ -n "$f" ] || continue; _is_ack_quarantined "$f" && n=$((n+1)); done <<EOF
$(_list_needs)
EOF
  printf '%s' "$n"; }
count_left(){ list_all_packs | grep -c . ; }
human_time(){ date -r "$1" '+%H:%M' 2>/dev/null || date -d "@$1" '+%H:%M' 2>/dev/null || echo "$1"; }
