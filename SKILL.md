---
name: agent-rules-skill
description: >-
  Bootstraps a vendor-neutral AI agent configuration structure (.agents/) for
  any project. Detects and migrates existing configs from Cursor (.cursor/rules/,
  .cursorrules), Claude Code (.claude/), Codex (.codex/), or opencode (.opencode/,
  opencode.json) into a single canonical source that generates adapters for all
  supported platforms via bin/sync-agent-config. Use when a project has no agent
  config, has only platform-specific config, or when you want to enable
  multi-platform support (Cursor + Claude Code + Codex + opencode) from an
  existing single-platform setup.
disable-model-invocation: true
---

# agent-rules-skill

Bootstrap and migration of vendor-neutral AI agent configuration for any project.

## When to use

- Project has no agent configuration at all
- Project has only `.cursor/rules/*.mdc` (Cursor-only)
- Project has only a monolithic `.cursorrules` file
- Project has only `.claude/` (Claude Code-only)
- Project has only `.codex/` (Codex-only)
- Project has only `.opencode/` / `opencode.json` (opencode-only)
- Migrating to multi-platform support from any single-platform setup

---

## Scope constraint — migrate only, never invent

**This skill migrates and restructures configuration that already exists. It must
NOT generate, infer, or fetch new rule content.** In particular:

- Do **not** author rules the source config did not already contain.
- Do **not** fetch or embed third-party library/framework documentation (e.g.
  pulling TanStack Router, React, or any library docs from the web, `context7`,
  `node_modules`, or training memory) as project rules.
- Do **not** expand a short source file into extra rules beyond the themes that
  are literally present in it.
- When the source is empty or missing (Case A), **ask the user** for the content
  instead of inventing conventions.

The only transformation allowed is **reorganizing existing content** across the
canonical format and adapters. If you think a rule is missing, surface it as a
suggestion to the user — do not write it yourself.

The output rule set must be traceable 1:1 to the source: every `.agents/rules/*.md`
must correspond to content that existed in the input. If it cannot be traced to
the source, it does not belong.

---

## Step 1 — Inventory the project

Before creating any file, read what already exists:

```
AGENTS.md              → existing portable entrypoint?
CLAUDE.md              → proxy pointing to AGENTS.md or own content?
.cursorrules           → legacy monolithic Cursor rules?
.cursor/rules/*.mdc    → organized Cursor rules?
.cursor/agents/*.md    → Cursor subagents?
.cursor/hooks.json     → Cursor hooks?
.claude/rules/*.md     → Claude Code rules?
.claude/agents/*.md    → Claude Code subagents?
.claude/settings.json  → Claude Code hooks?
.codex/agents/*.toml   → Codex subagents?
.codex/hooks.json      → Codex hooks?
.opencode/agents/*.md  → opencode subagents?
opencode.json          → opencode config (instructions, plugins)?
.agents/               → canonical source already exists?
```

If `.agents/` already exists with rules and agents, the project is already using
this architecture. Just run `bin/sync-agent-config` to regenerate adapters.

---

## Step 2 — Detect origin and migrate

### Case A: No configuration

Ask the user:
1. Project stack (language, framework, test suite, linter)
2. Key commands (run tests, run linter, build, CI)
3. Mandatory workflow (are there strong code structure rules?)

With the answers, create `.agents/` from scratch as described in Step 3.

### Case B: Monolithic `.cursorrules`

Read the entire file and split by theme/area into separate rules:
- Identify rule groups by folder/scope (`app/models`, `spec/`, etc.)
- Each group becomes a `.agents/rules/<theme>.md` with a `globs:` frontmatter
- Global rules without a scope → `.agents/rules/core.md` with `alwaysApply: true`
- Keep the original file until the sync is confirmed to be working

**Split only — do not add.** Every resulting rule must be a slice of the original
`.cursorrules` text. Do not enrich the split with library documentation, examples,
or best-practices the file did not contain (see "Scope constraint" above).

### Case C: Existing `.cursor/rules/*.mdc`

For each `.mdc` file:
1. Read frontmatter (`description`, `globs`, `alwaysApply`)
2. Create `.agents/rules/<basename>.md` with canonical frontmatter
3. Body content is identical

Canonical frontmatter (`.agents/rules/`):
```yaml
---
description: Brief description of the rule scope
alwaysApply: true          # or false
globs: app/models/**/*.rb  # omit if alwaysApply: true
---
```

### Case D: Existing `.claude/rules/*.md`

Same logic as Case C — Claude frontmatter uses `paths:` instead of `globs:`.
Convert:
```yaml
# Claude (source)           →  Canonical (.agents/rules/)
paths: [app/models/**]      →  globs: app/models/**
```

### Case E: Existing `.codex/agents/*.toml`

For each `.toml`:
1. Extract `name`, `description`, `sandbox_mode`, `developer_instructions`
2. Create `.agents/agents/<name>.md`:
   ```yaml
   ---
   name: <name>
   description: <description>
   model: <suggested-model>
   readonly: true   # if sandbox_mode == "read-only"
   ---
   <developer_instructions>
   ```
3. If the `.toml` had Codex-specific runtime notes (asdf, docker, etc.):
   - Extract that section
   - Create `.agents/adapters/codex/agents/<name>.md` with the Codex-specific content
   - Remove it from the main body

### Case F: Existing `.claude/agents/*.md`

Read Claude frontmatter (`tools`, `disallowedTools`) and convert:
- `disallowedTools: Write, Edit, MultiEdit` → `readonly: true` in canonical
- Everything else follows the canonical format

### Case G: Existing `.opencode/agents/*.md` or `opencode.json`

For each `.opencode/agents/*.md`:
1. Read frontmatter (`description`, `model`, `mode`, `tools`)
2. Create `.agents/agents/<name>.md`; if `tools` disables `write`/`edit`, set `readonly: true`
3. Body content is identical

If `opencode.json` has an `instructions` array pointing to rule files, migrate those
files into `.agents/rules/` (global ones as `alwaysApply: true`).

---

## Step 3 — Create the `.agents/` structure

### Required directories

```bash
mkdir -p .agents/rules
mkdir -p .agents/agents
mkdir -p .agents/adapters/cursor/rules
mkdir -p .agents/adapters/cursor/agents
mkdir -p .agents/adapters/claude/rules
mkdir -p .agents/adapters/claude/agents
mkdir -p .agents/adapters/codex/rules
mkdir -p .agents/adapters/codex/agents
mkdir -p .agents/adapters/opencode/rules
mkdir -p .agents/adapters/opencode/agents
mkdir -p .agents/hooks
```

### README files

Copy `templates/agents-README.md` from the package to `.agents/README.md`.
Copy `templates/adapters-README.md` to `.agents/adapters/README.md`.

### Canonical rules

Each file at `.agents/rules/<name>.md`:
```markdown
---
description: <objective description of the scope>
alwaysApply: false
globs: <glob pattern, e.g. app/models/**/*.rb>
---

# <Area Title>

<Rule content>
```

For global rules:
```markdown
---
description: Core project conventions and global standards
alwaysApply: true
---
```

See `examples/rule-core.md` and `examples/rule-scoped.md` in the package for reference.

### Canonical agents

Each file at `.agents/agents/<name>.md`:
```markdown
---
name: <kebab-case-name>
description: <when to invoke, 1-2 sentences>
model: <claude-sonnet-4-5 | composer-2.5-fast | etc>
readonly: true   # omit if the agent can edit files
---

<Agent instructions>
```

See `examples/agent-code-reviewer.md` in the package for reference.

### Linter hook (if the project has a linter)

Copy `templates/hook-linter.sh.template` to `.agents/hooks/linter-autocorrect.sh`.
Edit `LINT_CMD` and `FILE_EXTENSIONS` for the project's linter:

| Language | LINT_CMD | FILE_EXTENSIONS |
|----------|----------|-----------------|
| Ruby | `bundle exec rubocop --autocorrect --force-exclusion` | `rb` |
| TypeScript/JS | `npx eslint --fix` | `ts\|tsx\|js\|jsx` |
| Python | `black` | `py` |
| Go | `gofmt -w` | `go` |

### Worktrees (optional, Cursor only)

If the project requires worktree setup, create `.agents/worktrees.json`:
```json
{
  "setup-worktree-unix": ["<command 1>", "<command 2>"],
  "setup-worktree": ["<command 1 for Windows/cross-platform>"]
}
```

---

## Step 4 — Create AGENTS.md

Copy `templates/AGENTS.md.template` to `AGENTS.md` at the project root.
Fill in the TODO sections with real project information:
- **Project Stack** — language, framework, test suite, database, etc.
- **Commands** — real test, lint, CI commands
- **Mandatory Workflow** — project-specific process rules
- **Rule Index** — list the rules created in `.agents/rules/`
- **Specialized Agents** — list the agents created in `.agents/agents/`

---

## Step 5 — Install the sync script and automations

`bin/sync-agent-config` ships in three behaviourally identical ports: the Ruby
reference (`sync-agent-config`), a Node port (`sync-agent-config.js`), and a
Python 3 port (`sync-agent-config.py`). Copy the one matching the `runtime`
saved by the installer in `~/.config/agent-rules-skill/config.json` (falls back
to the Ruby reference when unset):

```bash
# runtime → template: ruby=sync-agent-config, node=sync-agent-config.js, python=sync-agent-config.py
runtime="$(python3 -c 'import json,os,sys;print(json.load(open(os.path.expanduser("~/.config/agent-rules-skill/config.json"))).get("runtime","ruby"))' 2>/dev/null || echo ruby)"
case "$runtime" in
  node)   src=sync-agent-config.js ;;
  python) src=sync-agent-config.py ;;
  *)      src=sync-agent-config    ;;
esac
cp "<package>/templates/$src" bin/sync-agent-config
chmod +x bin/sync-agent-config
```

The destination is always `bin/sync-agent-config`; the copied file's shebang
selects the interpreter. All ports accept `--platforms` / `--check` and read the
same installer preferences automatically.

### Auto-sync hook (all platforms)

Copy the hook that detects edits to `.agents/**` and triggers sync automatically:

```bash
cp <package>/templates/sync-on-edit.sh .agents/hooks/sync-on-edit.sh
chmod +x .agents/hooks/sync-on-edit.sh
```

The `sync-agent-config` script automatically includes it in all platform configs:

| Platform | Config file | Trigger |
|---|---|---|
| Cursor | `.cursor/hooks.json` | `afterFileEdit` |
| Claude Code | `.claude/settings.json` | `PostToolUse` (Write/Edit/MultiEdit) |
| Codex | `.codex/hooks.json` | `PostToolUse` (Edit/Write/apply_patch) |

The hook reads the edited file path from the JSON payload, checks if it is under
`.agents/`, and silently exits for any other file — so it never blocks unrelated edits.

### Git pre-commit hook (drift guard)

Install to block commits when adapters are out of sync:

```bash
cp <package>/templates/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

The hook only runs the check when a `.agents/**` file is staged — it has no impact
on commits that do not touch agent config.

---

## Step 6 — Run the sync

```bash
bin/sync-agent-config
```

This generates:
- `.cursor/rules/*.mdc` + `.cursor/agents/*.md` + `.cursor/hooks.json` (if cursor)
- `.claude/rules/*.md` + `.claude/agents/*.md` + `.claude/settings.json` + `CLAUDE.md` (if claude)
- `.codex/agents/*.toml` + `.codex/hooks.json` (if codex)
- `.opencode/rules/*.md` + `.opencode/agents/*.md` + `opencode.json` (if opencode)

To generate only specific platforms:
```bash
bin/sync-agent-config --platforms cursor,claude
```

To verify that generated adapters are in sync with `.agents/`:
```bash
bin/sync-agent-config --check
```

---

## Step 7 — Clean up old configs

After confirming the sync works and adapters are generated correctly:
- Remove `.cursorrules` if its content has been migrated to `.agents/rules/`
- Files under `.cursor/`, `.claude/`, `.codex/` are generated — do not edit manually

---

## Day-to-day maintenance

| Action | Where to edit | Command |
|--------|---------------|---------|
| New rule | `.agents/rules/<name>.md` | `bin/sync-agent-config` |
| New subagent | `.agents/agents/<name>.md` | `bin/sync-agent-config` |
| Cursor-only overlay | `.agents/adapters/cursor/...` | `bin/sync-agent-config` |
| Claude-only overlay | `.agents/adapters/claude/...` | `bin/sync-agent-config` |
| Codex-only overlay | `.agents/adapters/codex/...` | `bin/sync-agent-config` |
| opencode-only overlay | `.agents/adapters/opencode/...` | `bin/sync-agent-config` |
| Check for drift | — | `bin/sync-agent-config --check` |

**Golden rule:** always edit `.agents/**` — never touch the generated adapters.

---

## Reference: frontmatter mapping by platform

### Rules

| Canonical field | Cursor (`.mdc`) | Claude (`.md`) | opencode |
|---|---|---|---|
| `description` | `description` | `description` | — (body only) |
| `alwaysApply: true` | `alwaysApply: true` | (no `paths:`) | body → `.opencode/rules/`, referenced by `opencode.json` `instructions` |
| `alwaysApply: false` + `globs:` | `globs: <value>` + `alwaysApply: false` | `paths: [<value>]` | same as above (no per-glob activation; always included) |

Codex has no rule files — global conventions live in `AGENTS.md`, which Codex reads natively.

### Agents

| Canonical field | Cursor (`.md`) | Claude (`.md`) | Codex (`.toml`) | opencode (`.md`) |
|---|---|---|---|---|
| `name` | frontmatter directly | `name` | `name = "..."` | (filename) |
| `description` | `description` | `description` | `description = "..."` | `description` |
| `model` | `model` | `model: sonnet` (readonly) or `inherit` | — | `model` |
| `readonly: true` | `readonly: true` | `tools: Read,Grep,Glob,Bash` + `disallowedTools` | `sandbox_mode = "read-only"` | `tools: { write: false, edit: false }` |
| (mode) | — | — | — | `mode: subagent` |
| body | directly | directly | `developer_instructions = '''...'''` | directly |

---

## Expected final structure

```
<project>/
├── AGENTS.md                        ← portable entrypoint
├── CLAUDE.md                        ← generated (points to AGENTS.md)
├── bin/
│   └── sync-agent-config            ← sync script
├── .agents/
│   ├── README.md
│   ├── rules/
│   │   ├── core.md                  ← alwaysApply: true
│   │   └── <area>.md               ← specific globs
│   ├── agents/
│   │   └── <name>.md
│   ├── adapters/
│   │   ├── cursor/
│   │   ├── claude/
│   │   ├── codex/
│   │   └── opencode/
│   └── hooks/
│       ├── sync-on-edit.sh          ← auto-sync on .agents/** edit
│       └── linter-autocorrect.sh
├── .cursor/                         ← generated
├── .claude/                         ← generated
├── .codex/                          ← generated
├── .opencode/                       ← generated (rules/, agents/)
└── opencode.json                    ← generated/merged (instructions)
```
