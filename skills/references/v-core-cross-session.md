# Cross-Session Learning (extracted from _v-core.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

## Cross-Session Learning

At the start of any build or implementation session (`v-build`, `/v` with a build path), check for prior session artifacts that indicate known problems:

```bash
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [ -z "$REPO_ROOT" ] || { [ -n "${HOME:-}" ] && [ "$REPO_ROOT" = "$HOME" ]; }; then
  echo "ERROR: Cannot detect a safe repo root. Pass PROJECT_ROOT= explicitly."
  exit 1
fi
case "${REPO_ROOT%/}" in
  /|/Users|/home|/root|/tmp|/var|/usr|/etc|/bin|/sbin|/opt|/private|/System|/Library|/Volumes|/dev|/proc|/sys)
    echo "ERROR: Refusing to use filesystem-level root as REPO_ROOT: $REPO_ROOT"
    exit 1
    ;;
esac
# Recent blockers (last 7 days)
BLOCKERS=$(find "$REPO_ROOT" -maxdepth 1 -name "BUILD_BLOCKER_*.md" -mtime -7 2>/dev/null | sort -r)
# Recent progress notes (incomplete prior sessions)
PROGRESS=$(find "$REPO_ROOT" -maxdepth 1 -name "PROGRESS_NOTE_*.md" -mtime -7 2>/dev/null | sort -r)
```

If found, read the most recent of each (up to 2 files total) before starting work. Extract:
- What failed and why (from BUILD_BLOCKER)
- What was attempted and what remains (from PROGRESS_NOTE)
- Any recommended approach or workaround

Apply this context to avoid repeating the same failure. If the current plan touches the same files or patterns that caused a prior blocker, flag it in the IMPLEMENTATION_REPORT `## Decisions` section: "Prior session [SID] hit [issue] on [file] — this session [approached differently / same approach with fix X]."

This is read-only — never modify or delete prior session artifacts.
