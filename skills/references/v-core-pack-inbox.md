# Pack-Inbox Convention — Manual Batch Pack Execution

_Last reviewed: 2026-07-06 (scheduling machinery removed; `v-inbox` is now the sole interface)._

_Added 2026-07-06. Additive to, and does NOT replace, the generation-time convention in
[`v-core-prompt-pack.md`](v-core-prompt-pack.md) (`.v-prompt-packs/<full-skill-name>-<MM-DD>/`,
the parity-tested single source of truth for WHERE a producer writes its dated pack tree) or
[`v-runnable-pack-convention.md`](v-runnable-pack-convention.md) (the pack SHAPE `run-v-packs`
consumes). Read those first if you haven't — this file only adds a second, optional, stable
destination for packs an operator wants to find and run across all projects with one consistent
command instead of hunting per-project._

## Why a second location

`.v-prompt-packs/<slug>-<MM-DD>/` is generation-time and dated — a fresh directory per producer
run, meant for an operator who reviews the tree and runs `run-v-packs <dir>` (or pastes packs)
by hand, right away. It is NOT a stable target for a single cross-project command: that command
would have to discover which dated dirs exist per project and which are already fully drained.
Renaming or restructuring that convention is out of scope here — dozens of skills,
`v-core-prompt-pack.md`'s Unified folder convention, and `prompt-pack-output-dir-parity.test.ts`
depend on its exact shape.

Instead: a **stable, per-project, non-dated** directory that one operator command
(`v-inbox`) can point `run-v-packs` at directly, across every registered project, with no
discovery logic beyond "does it have pending packs."

## The convention

```
<project_root>/.v/packs/inbox/     ← stable per-project pack-inbox (gitignore: .v/)
  <name>.txt                       ← real pack files, same shape as any run-v-packs-consumed dir
  w1-<name>.txt  ...                 (wave-prefixed per v-runnable-pack-convention.md)
  99-verify.txt
  .done/                          ← created + owned by run-v-packs itself
  .needs-review/                  ← created + owned by run-v-packs itself
  .runlogs/                       ← created + owned by run-v-packs itself
```

- **Real files, never symlinks.** `run-v-packs`'s discovery (`hooks`-adjacent
  `run-v-packs-lib/10-discovery.sh`) uses `find … -type f`, which does **not** follow symlinks by
  default — a symlinked pack would silently never be discovered. Packs destined for the inbox
  must be copied in as real files.
- **Flat, same shape as any pack dir.** No dated subfolder inside the inbox — it is itself the
  `PACK_DIR` argument a plain `run-v-packs <inbox>` invocation takes. Wave-prefix rules, the `##
  Files` body schema, and everything else in `v-runnable-pack-convention.md` apply unchanged.
- **Additive, not a replacement.** A producer's PRIMARY output is still the dated
  `.v-prompt-packs/<slug>-<MM-DD>/` tree (self-validated exactly as documented in
  `v-core-prompt-pack.md`). Queuing into the inbox is an **optional second step** taken only when
  the operator wants to batch this pack tree in with everything else pending across their
  projects, run later via `v-inbox`, instead of an immediate `run-v-packs` / paste-in-a-session
  run. Copy (never move) the individual pack files — excluding `00-README.md`, which is a human
  map for the dated tree and carries no `/v` first line, so `run-v-packs` ignores it anyway —
  from the validated dated tree into `<project_root>/.v/packs/inbox/`.
- **Name collisions across queuing events.** Since the inbox accumulates packs from possibly
  several separate generation sessions over time, a producer queuing into a non-empty inbox MUST
  check for a basename collision before copying (`[ -e "$INBOX/$(basename "$f")" ]`) and, on
  collision, suffix the incoming copy with the source dated dir's `-MM-DD` tag
  (`<name>.MM-DD.txt`) rather than silently overwriting a still-pending pack.
- **Self-registration.** Any project that gets a non-empty `.v/packs/inbox/` is automatically
  registered (idempotent, deduped) into `~/.claude/runtime/pack-inbox-registry.txt` via
  `~/.claude/scripts/register-pack-inbox.sh <project_root>` — the same self-registering-registry
  pattern `stop-drain-deferred-merges.sh` uses for `v-drain-repos.txt`. No manual registration
  step. `v-inbox` (via its engine, `~/.claude/scripts/run-v-packs-inbox-nightly.sh`) reads that
  registry; it prunes any project whose inbox has gone empty (fully drained) at the end of each
  run.

## Producers that queue into the inbox

`v-prompt-pack-generate` (see its SKILL.md § Step 7 — Optional: queue for later execution) is
the primary producer. Any other skill wiring batch execution of its own packs (e.g. a future
`v-audit-consolidate` mode) should follow the same copy-in + register pattern rather than
inventing a second inbox shape.

## Running it

**`v-inbox` is the one consistent command** for finding and running queued packs across every
project — no per-project hunting, no scheduling, no launchd, no cron. It lives at
`~/.local/bin/v-inbox`, next to `run-v-packs`:

```bash
v-inbox                     # list pending packs per registered project (read-only)
v-inbox run                 # run ALL pending registered projects' inboxes now
v-inbox run <project_root>  # run just that one project's inbox now
```

`v-inbox` (no args) and `v-inbox run` are thin wrappers around the shared engine
(`~/.claude/scripts/run-v-packs-inbox-nightly.sh`) that walks the registry and writes a digest
(`~/.claude/runtime/pack-inbox-nightly-<date>.log` + `pack-inbox-nightly-latest.log`).
`v-inbox run <project_root>` skips the registry and calls `run-v-packs
"<project_root>/.v/packs/inbox" --once` directly — equivalent to running it by hand:

```bash
run-v-packs "$PROJECT_ROOT/.v/packs/inbox" --once     # one wave pass, exit 0 (drained) or 2 (work remains — expected)
```

There is no scheduled/unattended execution — nothing runs unless the operator types `v-inbox
run`.

## v-next signal

`v-next` (`references/signal-sources.md` § 5b) checks each project's `.v/packs/inbox/` for pack
files that are neither archived (`.done/`) nor parked (`.needs-review/`) as a "queued work
pending" signal — distinct from "no audit has run in N days."
