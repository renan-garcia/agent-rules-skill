# Agent Configuration Source

This directory is the canonical, vendor-neutral source for AI agent behavior in
this repository.

- `rules/`: project conventions and path-scoped rules.
- `agents/`: reusable specialized agent definitions.
- `adapters/`: tool-specific overlays appended only to that tool's generated
  adapter.
- `hooks/`: shared hook scripts called by tool-specific adapters.
- `worktrees.json`: shared worktree setup (optional, Cursor only).

After changing files here, run:

```bash
bin/sync-agent-config
```

Generated adapters live under `.cursor/`, `.claude/`, `.codex/`, and `CLAUDE.md`.
Do not edit those copies directly — changes will be overwritten on next sync.

## Platform control

Generate only specific platforms:

```bash
bin/sync-agent-config --platforms cursor
bin/sync-agent-config --platforms cursor,claude
```

Or set the default in `.agents/config.json`:

```json
{ "platforms": ["cursor", "claude", "codex"] }
```
