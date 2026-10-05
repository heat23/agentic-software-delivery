# Commit Message Authoring (W40-B) — extracted from /v SKILL.md

> **Loaded by:** /v when authoring `git commit` Bash calls (end-of-session checkpointing). Inline /v SKILL.md has only a one-line stub.

When writing commit messages with the `git commit` Bash tool call, **prefer `git commit -F <file>` over heredoc** for any commit message that is more than one line. Heredoc-as-default fails routinely with `bash: eval: line N: unexpected EOF while looking for matching '` when the message contains apostrophes, backticks, or unbalanced quotes — the orchestrator then has to recover by writing the message to a file anyway. Skip the failure round-trip:

```bash
# Preferred for any multi-paragraph or quote-containing message:
cat > "$V_TMP_DIR/commit-msg-${SESSION_ID}.txt" << 'COMMIT_MSG'
fix(area): one-line summary

Body paragraph with technical details. Apostrophes and "quotes" are safe.

- Bullet 1
- Bullet 2
COMMIT_MSG
git commit -F "$V_TMP_DIR/commit-msg-${SESSION_ID}.txt"
```

A production session (2026-05-03) hit the heredoc EOF failure and self-recovered via this exact `-F file` pattern, but the failed Bash call was wasted. Use `-F` first.

## When -m is safe vs when -F is required (review-fix W40-B)

- ✅ `git commit -m "fix: typo"` — safe. ALL of: single-line, ASCII-only, no apostrophes, no backticks, no `$`, no double-quotes, no `'`. Use this for trivial 1-line fixes.
- ❌ `git commit -m "..."` — UNSAFE for ANY of: multi-paragraph body, apostrophes (`don't`), backticks (\`), em-dashes inside quotes, smart quotes (`'`), code snippets, file paths with spaces. Use `-F file` instead.

Heuristic: if the message has more than one line OR contains any non-alphanumeric punctuation beyond `:`/`-`/space/`(`/`)`, write to a file. The 50ms it takes to write a file is cheaper than recovering from a heredoc parse failure (which costs the full Bash tool round-trip + a retry).
