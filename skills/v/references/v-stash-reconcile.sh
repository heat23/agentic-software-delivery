#!/usr/bin/env bash
# v-stash-reconcile.sh — safely bound the `v-merge-back auto-stash` stack (P11).
#
# Forensic 2026-06-20: v-merge-back stashes main's uncommitted WIP across an ff-merge, then
# restores via `git stash apply` + drop. When the apply CONFLICTS (overlapping shared-main WIP),
# the stash is deliberately LEFT for manual recovery ("your WIP is at SHA …"). Under a busy
# shared-main workflow this conflict path fires constantly and the auto-stashes ACCUMULATE — a
# production checkout accumulated hundreds, a deep stack that is itself a hazard (a bare `git stash pop` pops
# the wrong one; numeric indices shift; concurrent stashes corrupt).
#
# This tool reconciles that stack SAFELY: it drops ONLY auto-stashes whose every change is already
# present in HEAD or the working tree (redundant — zero recovery value), and KEEPS every stash that
# carries any unique content (real, recoverable WIP). It never touches a stash not created by
# v-merge-back. Default is a DRY RUN; pass --prune to actually drop the redundant ones.
#
# Usage:
#   v-stash-reconcile.sh [--repo DIR] [--prune]
#     (default)  DRY RUN: report redundant (safe-to-drop) vs unique (kept) counts + SHAs.
#     --prune    Drop ONLY the provably-redundant auto-stashes.
set -u
REPO="."; PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prune) PRUNE=1 ;;
    --repo)  shift; REPO="${1:-.}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) ;;
  esac
  shift
done
command -v git >/dev/null 2>&1 || { echo "git unavailable"; exit 2; }
G(){ git -C "$REPO" "$@"; }
G rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "not a git work tree: $REPO"; exit 2; }

AUTO_RE='v-merge-back auto-stash'
redundant_shas=""; red=0; unique=0; skipped=0

i=0
while idx_ref="stash@{$i}"; ref=$(G rev-parse "$idx_ref" 2>/dev/null); do
  cur=$i; i=$((i+1))
  msg=$(G log -1 --format='%s' "$idx_ref" 2>/dev/null)
  case "$msg" in *"$AUTO_RE"*) : ;; *) skipped=$((skipped+1)); continue ;; esac
  # All paths the stash carries: tracked changes (vs its base) + untracked (^3 parent, if any).
  files=$( { G stash show --name-only "stash@{$cur}" 2>/dev/null
             G ls-tree -r --name-only "${ref}^3" 2>/dev/null; } | awk 'NF' | sort -u )
  uniq_in_stash=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    sblob=$(G rev-parse -q --verify "${ref}:$f" 2>/dev/null)
    # SREV-002 (review 2026-06-20): untracked files live in the ^3 (untracked-files) parent, not the
    # ^0 tracked-changes tree, so `${ref}:$f` misses them → without this fall-back an untracked-only
    # stash whose content is already in the tree was always (over-conservatively) KEPT, never pruned.
    [ -n "$sblob" ] || sblob=$(G rev-parse -q --verify "${ref}^3:$f" 2>/dev/null)
    [ -n "$sblob" ] || { uniq_in_stash=1; break; }       # genuinely unreadable → conservatively keep
    hblob=$(G rev-parse -q --verify "HEAD:$f" 2>/dev/null)
    tblob=""; [ -f "$REPO/$f" ] && tblob=$(G hash-object "$f" 2>/dev/null)
    [ "$sblob" = "$hblob" ] && continue                   # content already committed
    [ "$sblob" = "$tblob" ] && continue                   # content already in working tree
    uniq_in_stash=1; break                                # unique → has recovery value
  done <<EOF
$files
EOF
  if [ -z "$files" ]; then
    # SREV-005 (review 2026-06-20): an empty auto-stash (zero tracked+untracked files) has no recovery
    # value — classify it redundant (prunable) rather than inflating the "unique/keep" count.
    red=$((red+1)); redundant_shas="$redundant_shas $ref"
  elif [ "$uniq_in_stash" = 0 ]; then
    red=$((red+1)); redundant_shas="$redundant_shas $ref"
  else
    unique=$((unique+1))
  fi
done

echo "v-merge-back auto-stashes: redundant=$red (safe to drop), unique=$unique (kept — recoverable WIP); non-auto stashes skipped=$skipped"

if [ "$PRUNE" != 1 ]; then
  echo "(dry run — re-run with --prune to drop the $red redundant auto-stash(es); the $unique unique ones are always kept)"
  exit 0
fi

dropped=0
for s in $redundant_shas; do
  # Resolve SHA→current index each time (indices shift as we drop).
  j=0
  while jr=$(G rev-parse "stash@{$j}" 2>/dev/null); do
    if [ "$jr" = "$s" ]; then
      G stash drop "stash@{$j}" >/dev/null 2>&1 && dropped=$((dropped+1))
      break
    fi
    j=$((j+1)); [ "$j" -gt 4000 ] && break
  done
done
echo "pruned $dropped redundant auto-stash(es); kept $unique with unique content"
