#!/usr/bin/env bash
# rc4a-merge-deferred-durable-test.sh — telemetry-completeness audit 2026-06-26 (RC-4a).
#
# v-merge-back.sh writes merge-deferred-<sid>.md to .v/tmp then `exit 3` BEFORE the DUC consolidate sweep (~1011),
# so the marker lived ONLY in the sweepable .v/tmp — a concurrent sibling's teardown / `git clean` could delete it
# before the 6h integrity sweep saw it, and FIX-B's `.v/artifacts/merge-deferred-*.md` detector arm never matched a
# real file (dead code). FIX adds a durable .v/artifacts copy right after the deferred-marker write (mirrors the
# commit-witness durability copy at 994-998). RED on v-merge-back.sh.pre-rc4a-bak.
#
# COVERAGE NOTE (honest): the deferral branch sits behind a full worktree + foreign-WIP-on-main + active-sibling-lock
# setup (v-merge-back.sh:788-816) that is heavy/brittle to drive in a unit. This is a STRUCTURAL assertion that the
# producer writes the durable copy, co-located with the .v/tmp write and keyed by the same SID. The CONSUMER side
# (the integrity sweep reading .v/artifacts/merge-deferred-*.md) is behaviorally tested by fixb-silent-hole-deferred-
# test.sh + integrity-sweep-test.sh; the cp PATTERN it mirrors (994-998 commit-witness) is itself live in this file.
set -u
MB="${V_MERGEBACK_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/v-merge-back.sh}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok  %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  NO  %s — %s\n' "$1" "${2:-}"; }
[ -f "$MB" ] || { echo "NO v-merge-back.sh missing"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

# Isolate the FND-3 deferral block (from the merge-deferred .v/tmp write through `exit 3`).
DEFER="$(awk '/_DW="\$REPO_ROOT\/.v\/tmp\/merge-deferred/,/^      exit 3/' "$MB")"
[ -n "$DEFER" ] || { echo "NO deferral block not found"; echo "TOTAL: 0 passed, 1 failed"; exit 1; }

echo "== RC-4a :: the FND-3 deferral writes the merge-deferred marker to the DURABLE .v/artifacts too (structural) =="
printf '%s\n' "$DEFER" | grep -qE 'cp .*"\$_DW".*\.v/artifacts/merge-deferred-\$\{SESSION_ID\}' \
  && ok "RC-4a: deferral copies merge-deferred-<sid>.md to .v/artifacts before exit 3 (survives a swept .v/tmp)" \
  || no "RC-4a: deferred marker is .v/tmp-only -> vanishes if a sibling sweeps .v/tmp before the 6h sweep"

echo "== F-3 (2026-07-03) :: the deferral REFRESHES commits-<sid>.txt to post-rebase SHAs before exit 3 (structural) =="
# The rebase above the defer rewrites branch SHAs; without a refresh, an existing witness cites orphaned
# commits (observed live: a commits-<sid>.txt pointed at rev-list-unreachable objects after a re-run defer).
printf '%s\n' "$DEFER" | grep -qE 'rev-list "\$\{MAIN_BRANCH\}\.\.\$\{WORKTREE_BRANCH\}" > "\$_wc"' \
  && ok "F-3: defer path rewrites the commit witness from the post-rebase branch range" \
  || no "F-3: defer path leaves a stale pre-rebase commit witness (orphaned SHAs poison attribution)"

echo ""; echo "TOTAL: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
