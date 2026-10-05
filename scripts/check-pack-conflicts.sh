#!/usr/bin/env bash
# check-pack-conflicts.sh — cross-pack / cross-batch DUPLICATE + CONFLICT lint for /v prompt packs.
#
#   JUST RUN:   check-pack-conflicts.sh <pack-dir> [<pack-dir>...]
#
# WHY: run-v-packs de-duplicates only at DISPATCH time (FND-DUP: identical body / same wave-stripped
# name inside one run) and nothing anywhere compares pack INSTRUCTIONS across a queue. Two packs that
# declare overlapping '## Files' targets — the convention's own conflict rule (v-runnable-pack-convention.md
# § Wave assignment step 2: "Two items conflict if their file sets intersect") — sail through as two
# independent /v sessions and race/contradict each other. This script is the deterministic pre-run gate:
# it intersects DECLARED scopes (never infers from prose), so it is project-agnostic and O(cheap).
#
# WHAT IT CHECKS (a pack = .txt/.md whose first non-blank line is /v, depth ≤2, hidden dirs skipped):
#   • DUPLICATE     — two packs with an identical whitespace-normalized body (any batch, any wave).
#                     The runner would park the later one at dispatch; catching it here is free.
#   • SAME-WAVE COLLISION — two packs in the SAME batch + SAME wave declaring the same file in
#                     '## Files'. They run in PARALLEL → merge race. Hard finding: re-wave or merge.
#   • CROSS-BATCH OVERLAP — two packs in DIFFERENT batches declaring the same file. Batches have no
#                     ordering guarantee between them and may contradict each other. Hard finding:
#                     review the pair (use --judge), or consciously run the batches sequentially.
#   • MULTI-99      — more than one 99-* verify pack in one batch (only the first would run).
#   • DIR-OVERLAP   — a declared directory prefix (e.g. `database/migrations/`) overlapping another
#                     pack's declared file/dir in the same wave or across batches. WARNING only
#                     (two packs adding different files to one dir is normal).
#   Same-batch DIFFERENT-wave overlaps are NOT findings — waves exist precisely to sequence those.
#   Cross-wave is the convention's own fix for a collision; this lint only flags what waves can't order.
#
# MODES (all optional):
#   --judge        adjudicate each hard pair with a headless LLM call (model: V_CONFLICT_JUDGE_MODEL,
#                  default sonnet; binary: CLAUDE_BIN, default `claude`). Verdict per pair:
#                  DUPLICATE | CONFLICT | COMPLEMENTARY. A CROSS-BATCH pair judged COMPLEMENTARY is
#                  downgraded to a warning (safe when batches run sequentially); SAME-WAVE collisions
#                  are mechanical races and stay hard regardless of verdict (the judge advises the fix).
#   --quarantine   move each EXACT duplicate (all but the lexicographically-first copy) into its
#                  batch's .needs-review/ — the same recoverable parking run-v-packs uses. Identical
#                  bodies lose zero information; semantic near-dups are never auto-moved.
#
# BATCH EXPANSION: an argument dir whose immediate subdirs carry their own 00-README.md (batch roots,
# DONE-*/hidden skipped) is expanded into those batches — `check-pack-conflicts.sh .v-prompt-packs`
# just works. A dir with no batch subdirs (or with its own 00-README.md) is itself one batch. Root-level
# packs in an expanded dir are scanned as their own "(root)" batch so nothing is silently skipped.
#
# EXIT: 0 = no hard findings (warnings may exist), 1 = hard findings (fix before running packs),
#       2 = bad invocation. Read-only packs (w<N>-review / pre-flight / 99-*) legitimately declare no
#       '## Files'; implementation packs without one are listed as a note (invisible to overlap checks).
set -uo pipefail

usage(){ echo "usage: check-pack-conflicts.sh [--judge] [--quarantine] <pack-dir> [<pack-dir>...]" >&2; exit 2; }

JUDGE=0; QUARANTINE=0; NDIRS=0
DIRS=""
while [ $# -gt 0 ]; do case "$1" in
  --judge)      JUDGE=1 ;;
  --quarantine) QUARANTINE=1 ;;
  -h|--help)    awk 'NR==1{next}/^#/{sub(/^# ?/,"");print;next}{exit}' "$0"; exit 0 ;;
  -*)           echo "unknown flag: $1" >&2; usage ;;
  *)            [ -d "$1" ] || { echo "no such dir: $1" >&2; exit 2; }
                DIRS="${DIRS}$1
"; NDIRS=$((NDIRS+1)) ;;
esac; shift; done
[ "$NDIRS" -ge 1 ] || usage

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
META="$TMP/meta.tsv"      # id <TAB> batch <TAB> wave <TAB> abs-path <TAB> hash <TAB> scoped(0/1) <TAB> readonly(0/1)
FILES="$TMP/files.tsv"    # kind(f/d) <TAB> path <TAB> id
: >"$META"; : >"$FILES"

# ── discovery (parity with run-v-packs-lib/10-discovery.sh, self-contained for portability) ──────
is_pack(){ # $1=file
  local b first; b="$(basename "$1")"
  case "$b" in 00-README.md|README.md) return 1 ;; esac
  first="$(grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null)"
  case "$first" in '/v '*|'/v-'*|'/v') return 0 ;; *) return 1 ;; esac
}

wave_of_pack(){ # $1=path-relative-to-batch -> wave int (0 unordered, 9999 verify) — mirrors runner wave_of
  local b d n
  b="$(basename "$1" | tr '[:upper:]' '[:lower:]')"
  d="$(basename "$(dirname "$1")" | tr '[:upper:]' '[:lower:]')"
  case "$b" in 99-*|99_*) echo 9999; return ;; esac
  case "$d" in
    wave-[0-9]*|wave_[0-9]*) n="${d#wave}"; n="${n#[-_]}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;
    w[0-9]*)                 n="${d#w}";    n="${n%%[^0-9]*}";                echo "${n:-0}"; return ;;
  esac
  case "$b" in
    w[0-9]*[-_]*) n="${b#w}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;
    wave[-_0-9]*) n="${b#wave}"; n="${n#[-_]}"; n="${n%%[^0-9]*}"; echo "${n:-0}"; return ;;
  esac
  echo 0
}

is_readonly_pack(){ # read-only packs legitimately omit '## Files'
  case "$(basename "$1")" in *review*|*pre-flight*|99-*) return 0 ;; *) return 1 ;; esac
}

norm_hash(){ # whitespace-normalized body hash — catches re-emitted packs that differ only in formatting
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/ /g' "$1" \
    | grep -v '^$' | shasum 2>/dev/null | awk '{print $1}'
}

# Path-token grammar shared by both extraction passes: repo-relative paths (≥1 slash) and bare
# filenames with a code extension. __GLOB__ is the sentinel a glob is rewritten to (see below).
_PAT='[A-Za-z0-9_.@-]+(/[A-Za-z0-9_.@-]+)+/?|[A-Za-z0-9_@-]+\.(php|tsx|ts|jsx|js|mjs|md|json|yml|yaml|css|scss|sh|xml|sql|vue|txt|toml|env)'

extract_scope(){ # $1=pack $2=id — append declared '## Files' tokens to FILES (kind f=file, d=dir mention, g=glob)
  # Kinds carry different strength: f = exact file (hard on collision), g = a glob like content/blog/*.md
  # ("I edit every matching file" — as strong as f), d = a bare directory mention ("files live/land here" —
  # warning-only; two packs adding DIFFERENT new files to one dir is normal).
  # Dir tokens are parsed ONLY from the path part of each bullet (before the ' — ' description separator,
  # per the convention's `- path — what changes` format) so prose like "redirect/noindex to the slug" never
  # becomes a phantom dir. File tokens are parsed from the WHOLE line — descriptions legitimately name real
  # secondary edit targets ("…then add to resources/js/test/setup.ts mockRoutes").
  awk '/^##[[:space:]]+Files([[:space:]]|$)/{f=1;next} f&&/^##[[:space:]]/{exit} f{print}' "$1" \
  | while IFS= read -r line; do
      line="$(printf '%s' "$line" | sed -E 's#/\*[A-Za-z0-9_.*-]*#/__GLOB__#g' | tr -d '\`')"
      pathpart="${line%%—*}"
      printf '%s\n' "$line" | grep -oE "$_PAT" | sed -e 's/[.,;:]*$//' -e 's#^\./##' \
        | grep -vE '^[A-Za-z0-9-]+\.(com|org|net|io|dev|ai|co)(/|$)' | while IFS= read -r p; do
          [ -n "$p" ] || continue
          case "$p" in */) p="${p%/}" ;; esac
          case "${p##*/}" in
            __GLOB__) printf 'g\t%s\t%s\n' "${p%/__GLOB__}" "$2" ;;
            *.*)      printf 'f\t%s\t%s\n' "$p" "$2" ;;
          esac
        done
      printf '%s\n' "$pathpart" | grep -oE "$_PAT" | sed -e 's/[.,;:]*$//' -e 's#^\./##' \
        | grep -vE '^[A-Za-z0-9-]+\.(com|org|net|io|dev|ai|co)(/|$)' | while IFS= read -r p; do
          [ -n "$p" ] || continue
          case "$p" in */) p="${p%/}" ;; esac
          case "${p##*/}" in
            __GLOB__|*.*) : ;;                       # files/globs already emitted from the full line
            *) printf 'd\t%s\t%s\n' "$p" "$2" ;;
          esac
        done
    done | LC_ALL=C sort -u >>"$FILES"
}

scan_batch(){ # $1=batch-label $2=batch-abs — append every pack to META (+ scope rows to FILES)
  local label="$1" abs="$2" f rel id w h scoped ro
  find "$abs" -maxdepth 2 -type f \( -name '*.txt' -o -name '*.md' \) 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    rel="${f#"$abs"/}"
    case "$rel" in .*|*/.*) continue ;; esac
    is_pack "$f" || continue
    id="$label/$rel"
    w="$(wave_of_pack "$rel")"
    h="$(norm_hash "$f")"
    if grep -qE '^##[[:space:]]+Files([[:space:]]|$)' "$f" 2>/dev/null; then scoped=1; else scoped=0; fi
    if is_readonly_pack "$rel"; then ro=1; else ro=0; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$w" "$f" "$h" "$scoped" "$ro" >>"$META"
    [ "$scoped" = 1 ] && extract_scope "$f" "$id"
  done
  return 0
}

# ── expand args into batches ─────────────────────────────────────────────────────────────────────
NBATCH=0
OLDIFS="$IFS"; IFS='
'
for d in $DIRS; do
  abs="$(cd "$d" && pwd)" || exit 2
  nsub=0
  for sub in "$abs"/*/; do
    [ -d "$sub" ] || continue
    bn="$(basename "$sub")"
    case "$bn" in .*|DONE-*) continue ;; esac
    [ -f "${sub}00-README.md" ] || continue
    scan_batch "$bn" "${sub%/}"; nsub=$((nsub+1)); NBATCH=$((NBATCH+1))
  done
  if [ "$nsub" -eq 0 ] || [ -f "$abs/00-README.md" ]; then
    scan_batch "$(basename "$abs")" "$abs"; NBATCH=$((NBATCH+1))
  else
    # expanded root: scan any stray root-level packs as their own batch so nothing is silently skipped
    rootpacks=0
    for f in "$abs"/*.txt "$abs"/*.md; do
      [ -e "$f" ] || continue; is_pack "$f" && { rootpacks=1; break; }
    done
    [ "$rootpacks" = 1 ] && { scan_batch "$(basename "$abs")(root)" "$abs"; NBATCH=$((NBATCH+1)); }
  fi
done
IFS="$OLDIFS"

NPACKS="$(grep -c . "$META" 2>/dev/null)"
echo "check-pack-conflicts: $NBATCH batch(es), $NPACKS pack(s) scanned"
[ "$NPACKS" -gt 0 ] || { echo "  (no packs found — a pack is a .txt/.md whose first non-blank line is /v)"; exit 0; }

HARD="$TMP/hard"; WARN="$TMP/warn"; NOTES="$TMP/notes"; PAIRS="$TMP/pairs"
: >"$HARD"; : >"$WARN"; : >"$NOTES"; : >"$PAIRS"

# ── DUPLICATE: identical normalized body under different pack files (any batch/wave) ─────────────
awk -F'\t' '$5!=""{print $5 "\t" $1}' "$META" | LC_ALL=C sort | awk -F'\t' '
  $1==prev { dup[$1] = dup[$1] "\t" $2; next }
  { prev=$1; dup[$1]=$2 }
  END { for (h in dup) if (index(dup[h], "\t")) print dup[h] }
' | while IFS= read -r grp; do
  first="${grp%%	*}"; rest="${grp#*	}"
  printf 'DUPLICATE\t%s\t%s\n' "$first" "$rest" >>"$HARD"
done

# ── MULTI-99: more than one verify pack in one batch ─────────────────────────────────────────────
awk -F'\t' '$3==9999{print $2 "\t" $1}' "$META" | LC_ALL=C sort | awk -F'\t' '
  { n[$1]++; l[$1] = l[$1] (l[$1]?" + ":"") $2 }
  END { for (b in n) if (n[b]>1) printf "MULTI99\t%s\t%s\n", b, l[b] }
' >>"$HARD"

# ── scope overlaps: exact-file + glob collisions (hard) + dir-mention overlaps (warn) ────────────
# awk loads pack meta, then walks the declared-scope rows; emits classified pair rows. Pair ids are
# emitted in canonical (sorted) order so A↔B and B↔A collapse to one finding at the aggregate step.
awk -F'\t' '
  function emit(sev, x, y, p,   t) { if (x > y) { t=x; x=y; y=t } printf "%s\t%s\t%s\t%s\n", sev, x, y, p }
  function classify(x, y, p) {       # hard-scope pair: exact file or glob territory
    if (batch[x]!=batch[y])      emit("CROSS", x, y, p)
    else if (wave[x]==wave[y])   emit("WAVE",  x, y, p)
    # same batch, different wave: sequenced by design — not a finding
  }
  NR==FNR { batch[$1]=$2; wave[$1]=$3; next }
  $1=="f" { nf++; fpath[nf]=$2; fid[nf]=$3 }
  $1=="d" { nd++; dpath[nd]=$2; did[nd]=$3 }
  $1=="g" { ng++; gpath[ng]=$2; gid[ng]=$3 }
  END {
    # exact-file collisions
    for (i=1; i<=nf; i++) for (j=i+1; j<=nf; j++)
      if (fpath[i]==fpath[j] && fid[i]!=fid[j]) classify(fid[i], fid[j], fpath[i])
    # glob collisions: a glob claims every matching file, so glob∩file and glob∩glob are as strong as f∩f.
    # Report the glob itself (one finding per pair), not the per-file enumeration — a content/blog/* pack
    # would otherwise drown the report in every intersecting path.
    for (i=1; i<=ng; i++) {
      for (j=1; j<=nf; j++)
        if (gid[i]!=fid[j] && (fpath[j]==gpath[i] || index(fpath[j], gpath[i] "/")==1))
          classify(gid[i], fid[j], gpath[i] "/* (glob)")
      for (j=i+1; j<=ng; j++)
        if (gid[i]!=gid[j] && (gpath[i]==gpath[j] || index(gpath[j], gpath[i] "/")==1 || index(gpath[i], gpath[j] "/")==1))
          classify(gid[i], gid[j], gpath[i] "/* (glob)")
    }
    # bare-dir mentions: overlap with anything is a warning only
    for (i=1; i<=nd; i++) {
      for (j=1; j<=nf; j++) {
        if (did[i]==fid[j]) continue
        if (fpath[j]!=dpath[i] && index(fpath[j], dpath[i] "/")!=1) continue
        if (batch[did[i]]!=batch[fid[j]] || wave[did[i]]==wave[fid[j]]) emit("DIR", did[i], fid[j], dpath[i])
      }
      for (j=i+1; j<=nd; j++) {
        if (did[i]==did[j] || dpath[i]!=dpath[j]) continue
        if (batch[did[i]]!=batch[did[j]] || wave[did[i]]==wave[did[j]]) emit("DIR", did[i], did[j], dpath[i])
      }
      for (j=1; j<=ng; j++) {
        if (did[i]==gid[j]) continue
        if (dpath[i]!=gpath[j] && index(gpath[j], dpath[i] "/")!=1 && index(dpath[i], gpath[j] "/")!=1) continue
        if (batch[did[i]]!=batch[gid[j]] || wave[did[i]]==wave[gid[j]]) emit("DIR", did[i], gid[j], dpath[i])
      }
    }
  }
' "$META" "$FILES" | LC_ALL=C sort -u >"$PAIRS"

# aggregate pair rows: one finding per (kind, packA, packB) with the shared paths joined (capped at 5
# shown + a "+N more" tail — a long list reads as noise and the pair is the actionable unit anyway)
awk -F'\t' '
  { k=$1 "\t" $2 "\t" $3; n[k]++; if (n[k]<=5) p[k] = p[k] (p[k]?", ":"") $4 }
  END { for (k in p) { t=p[k]; if (n[k]>5) t = t " +" (n[k]-5) " more"; printf "%s\t%s\n", k, t } }
' "$PAIRS" | LC_ALL=C sort | while IFS="$(printf '\t')" read -r kind a b paths; do
  case "$kind" in
    WAVE)  printf 'WAVE\t%s\t%s\t%s\n'  "$a" "$b" "$paths" >>"$HARD" ;;
    CROSS) printf 'CROSS\t%s\t%s\t%s\n' "$a" "$b" "$paths" >>"$HARD" ;;
    DIR)   printf 'DIR\t%s\t%s\t%s\n'   "$a" "$b" "$paths" >>"$WARN" ;;
  esac
done

# ── notes: implementation packs with no declared scope are invisible to overlap detection ────────
awk -F'\t' '$6==0 && $7==0 {print $1}' "$META" >"$NOTES"

# ── optional judge: adjudicate each WAVE/CROSS pair with a headless LLM call ─────────────────────
judge_pair(){ # $1=idA $2=idB $3=shared-paths -> prints VERDICT token (COMPLEMENTARY on any failure = no downgrade harm: only CROSS downgrades and only on an explicit verdict)
  local fa fb out
  fa="$(awk -F'\t' -v id="$1" '$1==id{print $4}' "$META")"
  fb="$(awk -F'\t' -v id="$2" '$1==id{print $4}' "$META")"
  [ -f "$fa" ] && [ -f "$fb" ] || { echo "UNAVAILABLE"; return 0; }
  out="$( { printf 'You are adjudicating two AI work-order prompt packs queued for autonomous execution. Both DECLARE these overlapping target files: %s\n\nDecide their relationship:\n- DUPLICATE: the same task written twice (running both wastes a full session and risks a merge race)\n- CONFLICT: contradictory instructions for the same surface (running both produces a wrong result in either order)\n- COMPLEMENTARY: compatible work that merely needs sequencing\n\nReply with EXACTLY one line: VERDICT: <DUPLICATE|CONFLICT|COMPLEMENTARY> — <one-sentence reason>\n\n=== PACK A (%s) ===\n%s\n\n=== PACK B (%s) ===\n%s\n' \
      "$3" "$1" "$(head -c 6000 "$fa")" "$2" "$(head -c 6000 "$fb")"; } \
    | "${CLAUDE_BIN:-claude}" -p --model "${V_CONFLICT_JUDGE_MODEL:-sonnet}" 2>/dev/null )" || { echo "UNAVAILABLE"; return 0; }
  case "$out" in
    *"VERDICT: DUPLICATE"*)     echo "DUPLICATE" ;;
    *"VERDICT: CONFLICT"*)      echo "CONFLICT" ;;
    *"VERDICT: COMPLEMENTARY"*) echo "COMPLEMENTARY" ;;
    *)                          echo "UNAVAILABLE" ;;
  esac
}

if [ "$JUDGE" = 1 ] && grep -qE "^(WAVE|CROSS)$(printf '\t')" "$HARD" 2>/dev/null; then
  command -v "${CLAUDE_BIN:-claude}" >/dev/null || { echo "  ⚠ --judge: '${CLAUDE_BIN:-claude}' not on PATH — skipping adjudication (deterministic findings stand)"; JUDGE=0; }
fi
if [ "$JUDGE" = 1 ]; then
  JHARD="$TMP/jhard"; : >"$JHARD"
  while IFS= read -r line; do
    case "$line" in
      WAVE"$(printf '\t')"*|CROSS"$(printf '\t')"*)
        kind="${line%%	*}"; rest="${line#*	}"
        a="${rest%%	*}"; rest="${rest#*	}"
        b="${rest%%	*}"; paths="${rest#*	}"
        v="$(judge_pair "$a" "$b" "$paths")"
        if [ "$kind" = CROSS ] && [ "$v" = COMPLEMENTARY ]; then
          printf 'DIR\t%s\t%s\t%s (judge: COMPLEMENTARY — safe if the batches run sequentially)\n' "$a" "$b" "$paths" >>"$WARN"
        else
          printf '%s\t%s\t%s\t%s (judge: %s)\n' "$kind" "$a" "$b" "$paths" "$v" >>"$JHARD"
        fi ;;
      *) printf '%s\n' "$line" >>"$JHARD" ;;   # DUPLICATE/MULTI99 rows pass through unchanged
    esac
  done <"$HARD"
  mv -f "$JHARD" "$HARD"
fi

# ── report ───────────────────────────────────────────────────────────────────────────────────────
if grep -q . "$HARD" 2>/dev/null; then
  while IFS="$(printf '\t')" read -r kind a b rest; do
    case "$kind" in
      DUPLICATE) echo "  ✗ DUPLICATE: $a == $(printf '%s' "$b" | tr '\t' ' ')${rest:+ $rest} — identical body under different files; keep one (or --quarantine to park the copies)" ;;
      MULTI99)   echo "  ✗ MULTI-99: batch '$a' has multiple final verify packs ($b${rest:+ $rest}) — only the first would run; merge them into ONE 99-verify pack" ;;
      WAVE)      echo "  ✗ SAME-WAVE COLLISION: $a + $b both declare: $rest — they would run in PARALLEL and race on merge; move one to a later wave or merge the packs" ;;
      CROSS)     echo "  ✗ CROSS-BATCH OVERLAP: $a + $b both declare: $rest — batches are NOT ordered relative to each other; review for contradictions (--judge), or consciously run the batches sequentially" ;;
    esac
  done <"$HARD"
fi
NH="$(grep -c . "$HARD" 2>/dev/null)"
NW="$(grep -c . "$WARN" 2>/dev/null)"
if [ "$NW" -gt 0 ]; then
  while IFS="$(printf '\t')" read -r kind a b rest; do
    echo "  ⚠ DIR-OVERLAP: $a + $b share declared directory scope: $rest — usually fine (different files in one dir); check the pair if both edit the same file"
  done <"$WARN"
fi
if grep -q . "$NOTES" 2>/dev/null; then
  echo "  ⓘ $(grep -c . "$NOTES") implementation pack(s) declare no '## Files' scope — INVISIBLE to overlap detection (the convention requires the section; run validate-audit-prompt-packs.sh):"
  sed 's/^/      /' "$NOTES"
fi

# ── optional quarantine: park exact-duplicate copies (never the first; never semantic near-dups) ──
# "$(printf '\t')", not '\t': GNU grep reads \t in a pattern as a plain t, so it never matched on Linux.
if [ "$QUARANTINE" = 1 ] && grep -q "^DUPLICATE$(printf '\t')" "$HARD" 2>/dev/null; then
  grep "^DUPLICATE$(printf '\t')" "$HARD" | while IFS="$(printf '\t')" read -r _ first rest; do
    printf '%s\n' "$rest" | tr '\t' '\n' | sed 's/ (judge.*//' | while IFS= read -r dupid; do
      [ -n "$dupid" ] || continue
      df="$(awk -F'\t' -v id="$dupid" '$1==id{print $4}' "$META")"
      [ -f "$df" ] || continue
      qd="$(dirname "$df")/.needs-review"; mkdir -p "$qd"
      if mv -f "$df" "$qd/" 2>/dev/null; then
        echo "  ↪ quarantined exact duplicate: $dupid → $(basename "$(dirname "$qd")")/.needs-review/ (first copy '$first' keeps the task; mv it back to undo)"
      fi
    done
  done
fi

echo "── result: $NH hard finding(s), $NW warning(s) across $NBATCH batch(es) / $NPACKS pack(s) ──"
[ "$NH" -eq 0 ] || exit 1
exit 0
