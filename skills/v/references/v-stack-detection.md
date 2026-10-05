# Stack Detection Reference

## Detection Code

```bash
# Detect primary framework
[ -f composer.json ] && echo "PHP_FRAMEWORK: $(jq -r '.require // {} | keys[]' composer.json 2>/dev/null | grep -E 'laravel|symfony|slim' | head -1)"
[ -f package.json ] && echo "JS_FRAMEWORK: $(jq -r '.dependencies // {} | keys[]' package.json 2>/dev/null | grep -E 'next|nuxt|svelte|astro|remix|react|vue|angular' | head -1)"
[ -f pyproject.toml ] && echo "PY_FRAMEWORK: $(grep -E 'django|flask|fastapi|starlette' pyproject.toml 2>/dev/null | head -1)"
[ -f Cargo.toml ] && echo "RUST_DETECTED"
[ -f go.mod ] && echo "GO_DETECTED"
[ -f Gemfile ] && echo "RUBY_FRAMEWORK: $(grep -E 'rails|sinatra|hanami' Gemfile 2>/dev/null | head -1)"
```

## Stack Detection Mapping

| Stack Signal | DETECTED_STACK | Test Runner | Build Tool | Convention File |
|-------------|---------------|-------------|-----------|----------------|
| `laravel/framework` in composer.json | `laravel` | Pest/PHPUnit | Vite | `artisan` |
| `next` in package.json dependencies | `nextjs` | Jest/Vitest | Next CLI | `next.config.*` |
| `@sveltejs/kit` in package.json | `sveltekit` | Vitest/Playwright | Vite | `svelte.config.js` |
| `nuxt` in package.json | `nuxt` | Vitest | Nuxi | `nuxt.config.ts` |
| `django` in pyproject.toml/requirements | `django` | pytest | manage.py | `settings.py` |
| `fastapi` in pyproject.toml | `fastapi` | pytest | uvicorn | `main.py` |
| `rails` in Gemfile | `rails` | RSpec/Minitest | Rails CLI | `config/routes.rb` |
| `astro` in package.json | `astro` | Vitest | Astro CLI | `astro.config.mjs` |
| `remix` in package.json | `remix` | Vitest/Jest | Remix CLI | `remix.config.js` |
| None detected | `unknown` | Ask user | Ask user | Ask user |

## Stack Detection Rules

1. If `DETECTED_STACK` is `unknown`, ask using AskUserQuestion:
   ```yaml
   question: "What framework/stack is this project using?"
   header: "Stack"
   multiSelect: false
   options:
     - label: "Laravel (PHP)"
       description: "PHP backend with Laravel framework"
     - label: "Next.js / React"
       description: "React-based frontend or full-stack Next.js"
     - label: "SvelteKit / Nuxt / Astro"
       description: "Other JS meta-framework"
     - label: "Python (Django/FastAPI)"
       description: "Python web framework"
   ```

2. **Multi-stack/monorepo:** If multiple frameworks are detected (e.g., `laravel` + `nextjs`), set `DETECTED_STACK` as a comma-separated list (e.g., `laravel,nextjs`). Identify which stack the user's prompt targets based on the files mentioned or feature domain (backend logic → PHP stack, frontend/UI → JS stack). Pass the relevant stack to each sub-skill. If ambiguous, ask using AskUserQuestion:
   ```yaml
   question: "This project has both [X] and [Y] — which part does this change target?"
   header: "Target Stack"
   multiSelect: false
   options:
     - label: "[X] (backend)"
       description: "Changes target the backend stack"
     - label: "[Y] (frontend)"
       description: "Changes target the frontend stack"
     - label: "Both"
       description: "Changes span both stacks"
   ```

3. Pass `DETECTED_STACK` to every sub-skill invocation as context
4. All framework-specific behavior in downstream skills (test commands, build commands, file patterns) must branch on this value
5. Do NOT assume Laravel — the default is detection, not assumption
