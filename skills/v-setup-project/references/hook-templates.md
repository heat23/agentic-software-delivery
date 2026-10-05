# v-setup-project Hook Templates

_Last reviewed: 2026-07-06 (design-language consistency pass)_

Canonical bodies for the stack-specific PostToolUse hooks that Step 3 generates. Keep the main
`SKILL.md` limited to selection logic; copy the matching body from here when a hook's stack is
detected. Every hook is `chmod +x`'d after creation and registered in `.claude/settings.json`
(Step 5) **only if it was actually created**.

All three depend on `jq`. Per the SKILL's Error Handling: if `jq` is absent, still write the file
but prepend `# REQUIRES: jq — install with: brew install jq / apt install jq` and do NOT register it.

## Included Templates

- `ziggy-on-route-edit.sh` — Laravel + Ziggy
- `factory-reminder.sh` — Laravel + Factories
- `lint-on-edit.sh` — ESLint (TS/TSX)

> `detect-secrets-in-write.sh` is RETIRED (2026-08-03, owner request) — the canonical global hook
> no longer exists at `~/.claude/hooks/detect-secrets-in-write.sh` (moved to `.attic/*.disabled-2026-08-03`),
> so SKILL Step 3's copy step is now a documented no-op. Do not re-template it here.

## Template Bodies

### ziggy-on-route-edit.sh (Laravel + Ziggy)

Regenerates Ziggy routes after route file changes.

```bash
#!/bin/bash
# PostToolUse hook: Regenerate Ziggy routes after route file edits

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != *routes/*.php ]]; then
  exit 0
fi

# Regenerate Ziggy the project's way — bare `php artisan ziggy:generate` drops
# feature-gated routes and desyncs the committed ziggy.js (see v-scaffold § Inertia Page)
if [ -x scripts/ziggy-generate.sh ]; then
  scripts/ziggy-generate.sh 2>/dev/null
elif composer run-script --list 2>/dev/null | grep -q '^ *ziggy'; then
  composer ziggy 2>/dev/null
else
  php artisan ziggy:generate 2>/dev/null
fi
if [ $? -eq 0 ]; then
  echo "Ziggy routes regenerated after route file change."
fi
exit 0
```

### factory-reminder.sh (Laravel + Factories)

Warns when creating a model without a matching factory.

```bash
#!/bin/bash
# PostToolUse hook: Remind to create factory when new model is created

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Write" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]] || [[ "$FILE_PATH" != *app/Models/*.php ]]; then
  exit 0
fi

MODEL_NAME=$(basename "$FILE_PATH" .php)

if [[ "$MODEL_NAME" == "Model" ]] || [[ "$FILE_PATH" == *Concerns* ]]; then
  exit 0
fi

FACTORY_PATH="database/factories/${MODEL_NAME}Factory.php"
if [[ ! -f "$FACTORY_PATH" ]]; then
  echo "REMINDER: No factory found for $MODEL_NAME."
  echo "Create $FACTORY_PATH — every model must have a factory."
fi
exit 0
```

### lint-on-edit.sh (ESLint)

Runs ESLint on edited TS/TSX files.

```bash
#!/bin/bash
# PostToolUse hook: Run ESLint after TypeScript file edits

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

if [[ "$TOOL_NAME" != "Write" && "$TOOL_NAME" != "Edit" ]]; then
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [[ -z "$FILE_PATH" ]]; then
  exit 0
fi

if [[ "$FILE_PATH" != *.ts && "$FILE_PATH" != *.tsx ]]; then
  exit 0
fi

if ! command -v npx &> /dev/null; then
  exit 0
fi

RESULT=$(npx eslint --max-warnings=0 "$FILE_PATH" 2>&1)
if [ $? -ne 0 ]; then
  echo "ESLint issues in $FILE_PATH:"
  echo "$RESULT" | tail -20
fi
exit 0
```
