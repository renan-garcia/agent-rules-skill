# agent-rules-skill

Bootstrap vendor-neutral AI agent configuration for any project.

Creates and maintains a single source of truth in `.agents/` that generates
adapters for **Cursor**, **Claude Code**, **Codex**, and **opencode** via
`bin/sync-agent-config`.

## Installation

```bash
cd etc/agent-rules-skill
./install.sh
```

The interactive installer asks:
- **Scope** — global (per user), per-project, or symlink (dev)
- **Install targets** — which tools' `skills/` dir to install into: Cursor, Claude
  Code, opencode (multi-select). Codex has no `skills/` dir, so it is a generation
  target only.
- **Generation platforms** — which platforms `sync-agent-config` generates for:
  Cursor, Claude Code, Codex, opencode (multi-select, saved as your default)
- **Sync runtime** — which interpreter runs `bin/sync-agent-config`: `auto`
  (default — detects an available runtime), `ruby`, `node`, or `python`. All
  three ports are behaviourally identical; pick one whose runtime your machines
  already have.

To install into a tool without the interactive prompt (example for Cursor + opencode):

```bash
# Copy (static snapshot)
cp -r etc/agent-rules-skill ~/.cursor/skills/agent-rules-skill
cp -r etc/agent-rules-skill ~/.config/opencode/skills/agent-rules-skill

# Symlink (always uses the latest version from this repo — recommended during development)
ln -sf "$(pwd)/etc/agent-rules-skill" ~/.cursor/skills/agent-rules-skill
ln -sf "$(pwd)/etc/agent-rules-skill" ~/.config/opencode/skills/agent-rules-skill
```

Per-tool skill locations: Cursor `~/.cursor/skills/`, Claude Code `~/.claude/skills/`,
opencode `~/.config/opencode/skills/` (or `.opencode/skills/` per project).

## Usage

With the skill installed, open any project in Cursor and say:

> "Use the agent-rules-skill to bootstrap agent configuration in this project."

The skill detects whatever already exists — `.cursorrules`, `.cursor/rules/`,
`.claude/`, `.codex/`, `.opencode/` / `opencode.json`, or nothing — and migrates
everything into `.agents/`, then generates adapters for all selected platforms.

### What gets created

```
<project>/
├── AGENTS.md                  ← portable entrypoint (read by all agents)
├── CLAUDE.md                  ← generated proxy pointing to AGENTS.md
├── bin/
│   └── sync-agent-config      ← sync script
├── .agents/                   ← EDIT HERE (canonical source)
│   ├── rules/                 ← project rules with YAML frontmatter
│   ├── agents/                ← subagent definitions
│   ├── adapters/              ← tool-specific overlays (cursor/claude/codex)
│   └── hooks/                 ← shared hook scripts
├── .cursor/                   ← generated
├── .claude/                   ← generated
├── .codex/                    ← generated
├── .opencode/                 ← generated (rules/, agents/)
└── opencode.json              ← generated/merged (instructions)
```

## Day-to-day maintenance

**Always edit `.agents/**` — never touch the generated adapters directly.**

### Automatic sync (recommended)

The bootstrap sets up two automation layers so you rarely need to run anything manually:

| Trigger | What runs | Platform |
|---|---|---|
| Edit any `.agents/**` file | `bin/sync-agent-config` | Cursor (`afterFileEdit`), Claude Code (`PostToolUse`), Codex (`PostToolUse`) |
| `git commit` with staged `.agents/**` | `bin/sync-agent-config --check` | Any (git hook) |

The `sync-on-edit.sh` hook is registered in the Cursor, Claude Code, and Codex configs.
It reads the edited file path from the JSON payload, checks if it is under `.agents/`,
and silently runs the sync — exiting immediately for any other file.

**opencode** uses a JS/TS plugin model rather than shell hooks, so auto-sync is not
wired there. Rely on the git pre-commit hook (drift guard) and manual `bin/sync-agent-config`.

The pre-commit hook blocks commits only when the adapters are out of sync.

### Manual commands

```bash
# Force a full sync
bin/sync-agent-config

# Generate only specific platforms
bin/sync-agent-config --platforms cursor,claude

# Check if generated adapters are in sync (read-only)
bin/sync-agent-config --check
```

### Platform resolution order (first match wins)

1. `--platforms` CLI flag
2. `AGENT_PLATFORMS` environment variable
3. `.agents/config.json` in the project
4. `~/.config/agent-rules-skill/config.json` (saved by the installer)
5. Default: all platforms

## Package structure

```
agent-rules-skill/
├── SKILL.md                        ← Cursor agent skill (bootstrap + migration logic)
├── install.sh                      ← interactive installer (self-contained gum)
├── README.md                       ← this file
├── templates/
│   ├── sync-agent-config           ← sync script, Ruby reference (copy to bin/)
│   ├── sync-agent-config.js        ← sync script, Node port (equivalent)
│   ├── sync-agent-config.py        ← sync script, Python 3 port (equivalent)
│   ├── sync-on-edit.sh             ← shell hook: auto-sync on .agents/** edit (Cursor/Claude/Codex)
│   ├── pre-commit                  ← Git hook: block commits when adapters drift
│   ├── AGENTS.md.template          ← project entrypoint template
│   ├── CLAUDE.md.template          ← generated Claude proxy template
│   ├── agents-README.md            ← README for .agents/
│   ├── adapters-README.md          ← README for .agents/adapters/
│   └── hook-linter.sh.template     ← generic linter hook (Ruby/TS/Python/Go)
└── examples/
    ├── rule-core.md                ← global rule (alwaysApply: true)
    ├── rule-scoped.md              ← scoped rule with globs
    └── agent-code-reviewer.md      ← read-only subagent example
```

## Migration sources supported

| Existing config | What the skill does |
|---|---|
| Nothing | Guides creation from scratch (asks stack, commands, linter) |
| `.cursorrules` monolith | Splits into scoped rules under `.agents/rules/` |
| `.cursor/rules/*.mdc` | Converts `.mdc` frontmatter to canonical format |
| `.claude/rules/*.md` | Converts `paths:` to `globs:` in canonical format |
| `.codex/agents/*.toml` | Extracts `developer_instructions` → `.agents/agents/*.md`; isolates Codex-specific notes as overlays in `.agents/adapters/codex/` |
| `.opencode/agents/*.md` / `opencode.json` | Converts agent frontmatter (`tools` disabling write/edit → `readonly`); migrates `instructions` rule files into `.agents/rules/` |
| Mix of the above | Merges all sources into a single canonical `.agents/` |
