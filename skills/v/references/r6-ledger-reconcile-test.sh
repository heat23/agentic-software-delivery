#!/usr/bin/env bash
# r6-ledger-reconcile-test.sh — R6 (post-batch live validation 2026-06-21): v-artifact-consolidate must
# append-MERGE a stray DISPATCH_LEDGER.jsonl (left at the repo ROOT / a worktree by a pre-fix run) into the
# canonical .v/artifacts ledger — de-duplicated, never losing a row — then remove the stray, so the R2
# dispatch_path derivation (which reads only MAIN/.v/artifacts) sees ALL of a session's provenance.
# Re-run: bash <thisfile>
set -u
command -v git >/dev/null 2>&1 || { echo "SKIP: git"; exit 0; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CONS="$HERE/v-artifact-consolidate.sh"
[ -f "$CONS" ] || { echo "SKIP: consolidate missing"; exit 0; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok  $1"; }
no(){ FAIL=$((FAIL+1)); echo "  NO  $1 — $2"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; mkdir -p "$R/.v/artifacts"
( cd "$R" && git init -q -b main && echo x>f && git add -A && git -c commit.gpgsign=false commit -qm base ) >/dev/null 2>&1
SID=0a0a0a0a-1111-4111-8111-00000000c006
CANON="$R/.v/artifacts/DISPATCH_LEDGER.jsonl"
STRAY="$R/DISPATCH_LEDGER.jsonl"
# canonical has rows A,B ; stray has B (dup), C, D (unique). Union must be A,B,C,D.
printf '{"parent_sid":"%s","agent_type":"A"}\n{"parent_sid":"%s","agent_type":"B"}\n' "$SID" "$SID" > "$CANON"
printf '{"parent_sid":"%s","agent_type":"B"}\n{"parent_sid":"%s","agent_type":"C"}\n{"parent_sid":"%s","agent_type":"security-reviewer"}\n' "$SID" "$SID" "$SID" > "$STRAY"

echo "== R6 :: stray root DISPATCH_LEDGER append-merged into canonical =="
( cd "$R" && bash "$CONS" "$SID" "$R/wt" "$R/wt/.v/artifacts" ) >/dev/null 2>&1
N=$(wc -l < "$CANON" 2>/dev/null | tr -d ' ')
[ "$N" = "4" ] && ok "canonical now holds the UNION (4 unique rows, dup collapsed)" || no "canonical row count=$N (expected 4 union)" "$(cat "$CANON")"
grep -q '"agent_type":"C"' "$CANON" && grep -q '"agent_type":"security-reviewer"' "$CANON" && ok "stray-only rows (C, security-reviewer) preserved into canonical" || no "stray rows lost" "$(cat "$CANON")"
grep -q '"agent_type":"A"' "$CANON" && ok "pre-existing canonical rows (A) retained" || no "canonical row A lost" "$(cat "$CANON")"
[ ! -f "$STRAY" ] && ok "stray root ledger removed after merge (no recurrence)" || no "stray still present" "$STRAY"
# the merged reviewer row makes R2's derivation reachable from canonical
grep -q '"agent_type":"security-reviewer"' "$CANON" && ok "merged reviewer row -> R2 dispatch_path now derivable from canonical" || no "reviewer row not in canonical" "$(cat "$CANON")"

echo "TOTAL: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
