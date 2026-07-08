# Adapter-Specific Overlays

Use this directory only for behavior that belongs to one AI tool and should not
be copied into the canonical `.agents/rules/` or `.agents/agents/` files.

Supported append-only overlays:

```text
.agents/adapters/<tool>/rules/<rule-name>.md
.agents/adapters/<tool>/agents/<agent-name>.md
```

Supported tools:

- `cursor`
- `claude`
- `codex`

The sync script appends matching overlay content to the generated adapter file.
Keep each overlay self-contained with a heading that names the target tool.

## Example: Codex runtime notes

If your project uses asdf, add runtime-specific instructions only for Codex:

```
.agents/adapters/codex/agents/test-runner.md
```

```markdown
## Codex Runtime Notes

Invoke commands through asdf to use the project's tool versions:

- Run tests: `asdf exec bundle exec rspec`
```

This overlay is appended to `.codex/agents/test-runner.toml` only.
Cursor and Claude Code agents see the base instructions without it.
