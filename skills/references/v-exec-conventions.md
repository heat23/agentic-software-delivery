# Convention Discovery (extracted from _v-exec.md)

_Last reviewed: 2026-07-05 (ecosystem review sweep)._

Before applying project-specific scaffolding, test helpers, or code generation rules, read convention sources in this order:
1. `CLAUDE.md`
2. skill- or directory-local convention files referenced by `CLAUDE.md`
3. existing nearby code patterns
4. shared skill defaults

If a documented repository convention conflicts with a generic skill default, prefer the documented repository convention.
If no convention source is found, fall back to generic defaults and record that assumption.
