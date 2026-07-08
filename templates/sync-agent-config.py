#!/usr/bin/env python3
"""sync-agent-config (Python port)

Generates platform adapters (.cursor/, .claude/, .codex/) from the canonical
source in .agents/.

Usage:
  bin/sync-agent-config                          # all platforms
  bin/sync-agent-config --platforms cursor       # Cursor only
  bin/sync-agent-config --platforms cursor,claude
  bin/sync-agent-config --check                  # verify drift without writing

Supported platforms: cursor, claude, codex, opencode

Alternative environment variable:
  AGENT_PLATFORMS=cursor,claude bin/sync-agent-config

Optional project configuration file:
  .agents/config.json  ->  { "platforms": ["cursor", "claude", "codex", "opencode"] }

This is a stdlib-only port of the reference Ruby implementation. It carries a
tiny hand-rolled parser/emitter for the flat frontmatter this skill uses, so it
needs no third-party YAML dependency.
"""

import glob as globlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK = "--check" in sys.argv[1:]
CHANGED = []

ALL_PLATFORMS = ["cursor", "claude", "codex", "opencode"]


# ── Minimal YAML for flat frontmatter ─────────────────────────────────────────

def _coerce_scalar(raw):
    text = raw.strip()
    if text == "" or text in ("~", "null"):
        return None
    if text in ("true", "True"):
        return True
    if text in ("false", "False"):
        return False
    if len(text) >= 2 and text[0] == text[-1] and text[0] in ("'", '"'):
        return text[1:-1]
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    return text


def _parse_frontmatter(text):
    """Parse the flat `key: value` (plus simple block lists) frontmatter the
    skill relies on. Not a general YAML parser — deliberately small."""
    data = {}
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == "" or line.lstrip().startswith("#"):
            i += 1
            continue
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not m:
            i += 1
            continue
        key, rest = m.group(1), m.group(2)
        if rest.strip() == "":
            # Possible block sequence: following "- item" lines.
            items = []
            j = i + 1
            while j < len(lines) and re.match(r"^\s*-\s+", lines[j]):
                items.append(_coerce_scalar(re.sub(r"^\s*-\s+", "", lines[j])))
                j += 1
            if items:
                data[key] = items
                i = j
                continue
            data[key] = None
            i += 1
            continue
        data[key] = _coerce_scalar(rest)
        i += 1
    return data


def _needs_quoting(value):
    if value == "":
        return True
    if value != value.strip():
        return True
    if value[0] in "!&*?|>%@`#[]{},":
        return True
    if ": " in value or value.endswith(":"):
        return True
    if " #" in value:
        return True
    return False


def _emit_scalar(value):
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    text = str(value)
    if _needs_quoting(text):
        return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return text


def _emit_yaml(data):
    out = []
    for key, value in data.items():
        if isinstance(value, dict):
            out.append(f"{key}:")
            for subkey, subval in value.items():
                out.append(f"  {subkey}: {_emit_scalar(subval)}")
        elif isinstance(value, list):
            out.append(f"{key}:")
            for item in value:
                out.append(f"- {_emit_scalar(item)}")
        else:
            out.append(f"{key}: {_emit_scalar(value)}")
    return "\n".join(out)


# ── Platform resolution ───────────────────────────────────────────────────────

def _valid(platforms):
    return [p for p in platforms if p in ALL_PLATFORMS]


def _from_config(path):
    if not os.path.exists(path):
        return None
    try:
        with open(path) as fh:
            config = json.load(fh)
    except Exception:
        return None
    platforms = config.get("platforms")
    if platforms is None:
        return None
    return _valid([str(p).lower() for p in platforms])


def resolve_platforms():
    args = sys.argv[1:]

    # 1. --platforms command-line flag
    for arg in args:
        if arg.startswith("--platforms="):
            raw = arg[len("--platforms="):]
            return _valid([p.strip().lower() for p in raw.split(",")])
    if "--platforms" in args:
        idx = args.index("--platforms")
        if idx + 1 < len(args) and not args[idx + 1].startswith("--"):
            return _valid([p.strip().lower() for p in args[idx + 1].split(",")])

    # 2. Environment variable
    env = os.environ.get("AGENT_PLATFORMS")
    if env:
        return _valid([p.strip().lower() for p in env.split(",")])

    # 3. Project .agents/config.json file
    project = _from_config(os.path.join(ROOT, ".agents", "config.json"))
    if project is not None:
        return project

    # 4. Global installer config
    global_cfg = _from_config(os.path.expanduser("~/.config/agent-rules-skill/config.json"))
    if global_cfg is not None:
        return global_cfg

    # 5. Default: all
    return list(ALL_PLATFORMS)


PLATFORMS = resolve_platforms()

if not PLATFORMS:
    sys.stderr.write(
        "No valid platform resolved (expected: %s).\n" % ", ".join(ALL_PLATFORMS)
    )
    sys.exit(1)


# ── Utilities ─────────────────────────────────────────────────────────────────

def read_markdown(path):
    with open(path) as fh:
        content = fh.read()
    match = re.match(r"\A---\n(.*?)\n---\n", content, re.DOTALL)
    if not match:
        return {}, content
    metadata = _parse_frontmatter(match.group(1)) or {}
    return metadata, content[match.end():]


def metadata_list(value):
    if isinstance(value, list):
        items = [str(v) for v in value]
    elif value is None:
        items = []
    else:
        items = [v.strip() for v in str(value).split(",")]
    return [v for v in items if v != ""]


def compact(data):
    return {k: v for k, v in data.items() if v is not None}


def yaml_frontmatter(metadata):
    return "---\n%s\n---\n\n" % _emit_yaml(metadata)


def write_file(path, content, mode=None):
    if CHECK:
        if not (os.path.exists(path) and _read(path) == content):
            CHANGED.append(path)
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(content)
    if mode is not None:
        os.chmod(path, mode)


def _read(path):
    with open(path) as fh:
        return fh.read()


def json_file(data):
    return json.dumps(data, indent=2) + "\n"


def toml_string(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def toml_multiline(value):
    return str(value).strip().replace("'''", "'''\"'\"'''")


def adapter_append(adapter, kind, basename):
    path = os.path.join(ROOT, ".agents", "adapters", adapter, kind, "%s.md" % basename)
    if not os.path.exists(path):
        return ""
    return "\n\n%s\n" % _read(path).strip()


def with_adapter_append(body, adapter, kind, basename):
    append = adapter_append(adapter, kind, basename)
    if append == "":
        return body
    return body.rstrip() + append


def sorted_glob(pattern):
    return sorted(globlib.glob(pattern))


# ── Rules synchronization ─────────────────────────────────────────────────────

rules_dir = os.path.join(ROOT, ".agents", "rules")
agents_dir = os.path.join(ROOT, ".agents", "agents")

for source in sorted_glob(os.path.join(rules_dir, "*.md")):
    basename = os.path.basename(source)[:-len(".md")]
    metadata, body = read_markdown(source)
    globs = metadata_list(metadata.get("globs"))

    if "cursor" in PLATFORMS:
        cursor_metadata = compact({"description": metadata.get("description")})
        if globs:
            cursor_metadata["globs"] = ",".join(globs)
        cursor_metadata["alwaysApply"] = bool(metadata.get("alwaysApply"))

        write_file(
            os.path.join(ROOT, ".cursor", "rules", "%s.mdc" % basename),
            yaml_frontmatter(cursor_metadata)
            + with_adapter_append(body.lstrip(), "cursor", "rules", basename),
        )

    if "claude" in PLATFORMS:
        claude_metadata = compact({"description": metadata.get("description")})
        if globs and not metadata.get("alwaysApply"):
            claude_metadata["paths"] = globs

        write_file(
            os.path.join(ROOT, ".claude", "rules", "%s.md" % basename),
            yaml_frontmatter(claude_metadata)
            + with_adapter_append(body.lstrip(), "claude", "rules", basename),
        )

    if "opencode" in PLATFORMS:
        # opencode has no per-glob activation: rules are surfaced as plain
        # instruction files referenced from opencode.json (see below).
        write_file(
            os.path.join(ROOT, ".opencode", "rules", "%s.md" % basename),
            with_adapter_append(body.lstrip(), "opencode", "rules", basename),
        )


# ── Agents synchronization ────────────────────────────────────────────────────

for source in sorted_glob(os.path.join(agents_dir, "*.md")):
    basename = os.path.basename(source)[:-len(".md")]
    metadata, body = read_markdown(source)
    readonly = metadata.get("readonly") is True

    if "cursor" in PLATFORMS:
        cursor_content = yaml_frontmatter(dict(metadata)) + with_adapter_append(
            body.lstrip(), "cursor", "agents", basename
        )
        write_file(os.path.join(ROOT, ".cursor", "agents", "%s.md" % basename), cursor_content)

    if "claude" in PLATFORMS:
        claude_metadata = compact({
            "name": metadata.get("name"),
            "description": metadata.get("description"),
            "model": "sonnet" if readonly else "inherit",
        })
        if readonly:
            claude_metadata["tools"] = "Read, Grep, Glob, Bash"
            claude_metadata["disallowedTools"] = "Write, Edit, MultiEdit"
        write_file(
            os.path.join(ROOT, ".claude", "agents", "%s.md" % basename),
            yaml_frontmatter(claude_metadata)
            + with_adapter_append(body.lstrip(), "claude", "agents", basename),
        )

    if "codex" in PLATFORMS:
        codex_body = with_adapter_append(body.lstrip(), "codex", "agents", basename)
        codex_lines = []
        codex_lines.append('name = "%s"' % toml_string(metadata.get("name")))
        codex_lines.append('description = "%s"' % toml_string(metadata.get("description")))
        if readonly:
            codex_lines.append('sandbox_mode = "read-only"')
        codex_lines.append('model_reasoning_effort = "%s"' % ("high" if readonly else "medium"))
        codex_lines.append("")
        codex_lines.append("developer_instructions = '''")
        codex_lines.append(toml_multiline(codex_body))
        codex_lines.append("'''")

        write_file(
            os.path.join(ROOT, ".codex", "agents", "%s.toml" % basename),
            "\n".join(codex_lines) + "\n",
        )

    if "opencode" in PLATFORMS:
        opencode_metadata = compact({"description": metadata.get("description")})
        opencode_metadata["mode"] = "subagent"
        if metadata.get("model"):
            opencode_metadata["model"] = metadata.get("model")
        if readonly:
            opencode_metadata["tools"] = {"write": False, "edit": False}

        write_file(
            os.path.join(ROOT, ".opencode", "agents", "%s.md" % basename),
            yaml_frontmatter(opencode_metadata)
            + with_adapter_append(body.lstrip(), "opencode", "agents", basename),
        )


# ── Hooks ─────────────────────────────────────────────────────────────────────

hooks_dir = os.path.join(ROOT, ".agents", "hooks")
hook_scripts = [
    f for f in sorted_glob("%s/*.sh" % hooks_dir)
    if os.path.basename(f) != "sync-on-edit.sh"
]
hook_command = hook_scripts[0] if hook_scripts else None
sync_hook = os.path.join(hooks_dir, "sync-on-edit.sh")

relative_sync_hook = sync_hook[len(ROOT) + 1:] if os.path.exists(sync_hook) else None
relative_linter_hook = hook_command[len(ROOT) + 1:] if hook_command else None

if "cursor" in PLATFORMS:
    after_file_edit = []
    if relative_sync_hook:
        after_file_edit.append({"command": relative_sync_hook, "timeout": 30})
    if relative_linter_hook:
        after_file_edit.append({"command": relative_linter_hook, "timeout": 60})

    if after_file_edit:
        write_file(
            os.path.join(ROOT, ".cursor", "hooks.json"),
            json_file({"version": 1, "hooks": {"afterFileEdit": after_file_edit}}),
        )

if "claude" in PLATFORMS and (relative_sync_hook or relative_linter_hook):
    claude_hooks = []
    if relative_sync_hook:
        claude_hooks.append({
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/%s" % relative_sync_hook,
                "args": [],
                "timeout": 30,
            }],
        })
    if relative_linter_hook:
        claude_hooks.append({
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{
                "type": "command",
                "command": "${CLAUDE_PROJECT_DIR}/%s" % relative_linter_hook,
                "args": [],
                "timeout": 60,
            }],
        })

    write_file(
        os.path.join(ROOT, ".claude", "settings.json"),
        json_file({
            "$schema": "https://json.schemastore.org/claude-code-settings.json",
            "hooks": {"PostToolUse": claude_hooks},
        }),
    )

if "codex" in PLATFORMS and (relative_sync_hook or relative_linter_hook):
    codex_hooks = []
    if relative_sync_hook:
        codex_hooks.append({
            "matcher": "Edit|Write|apply_patch",
            "hooks": [{
                "type": "command",
                "command": '"$(git rev-parse --show-toplevel)/%s"' % relative_sync_hook,
                "timeout": 30,
                "statusMessage": "Syncing agent config",
            }],
        })
    if relative_linter_hook:
        codex_hooks.append({
            "matcher": "Edit|Write|apply_patch",
            "hooks": [{
                "type": "command",
                "command": '"$(git rev-parse --show-toplevel)/%s"' % relative_linter_hook,
                "timeout": 60,
                "statusMessage": "Running linter autocorrect",
            }],
        })

    write_file(
        os.path.join(ROOT, ".codex", "hooks.json"),
        json_file({"hooks": {"PostToolUse": codex_hooks}}),
    )


# ── Worktrees ─────────────────────────────────────────────────────────────────

worktrees_src = os.path.join(ROOT, ".agents", "worktrees.json")
if os.path.exists(worktrees_src) and "cursor" in PLATFORMS:
    write_file(os.path.join(ROOT, ".cursor", "worktrees.json"), _read(worktrees_src))


# ── opencode.json ─────────────────────────────────────────────────────────────

if "opencode" in PLATFORMS and sorted_glob(os.path.join(rules_dir, "*.md")):
    opencode_config_path = os.path.join(ROOT, "opencode.json")
    opencode_config = {}
    if os.path.exists(opencode_config_path):
        try:
            opencode_config = json.loads(_read(opencode_config_path))
        except Exception:
            opencode_config = {}
    opencode_config.setdefault("$schema", "https://opencode.ai/config.json")

    rules_glob = ".opencode/rules/*.md"
    instructions = opencode_config.get("instructions") or []
    if not isinstance(instructions, list):
        instructions = [instructions]
    if rules_glob not in instructions:
        instructions.append(rules_glob)
    opencode_config["instructions"] = instructions

    write_file(opencode_config_path, json_file(opencode_config))


# ── AGENTS.md ─────────────────────────────────────────────────────────────────

AGENTS_MD_TEMPLATE = """# AGENTS.md

This is the portable project entrypoint for AI coding agents. Keep durable,
project-level behavior here and keep detailed, path-scoped rules in
`.agents/rules/`.

## Source Of Truth

- Edit canonical rules in `.agents/rules/*.md`.
- Edit canonical subagents in `.agents/agents/*.md`.
- Edit tool-specific overlays in `.agents/adapters/<tool>/...` when an
  instruction applies only to Cursor, Claude Code, or Codex.
- Edit shared hooks in `.agents/hooks/*`.
- Run `bin/sync-agent-config` after changing `.agents/**` to refresh adapters.
- Do not hand-edit generated adapters under `.cursor/`, `.claude/`, or `.codex/`.

## Project Stack

<!-- TODO: describe the project stack -->
- Language / framework:
- Test suite:
- Database:
- Background jobs:
- Key libraries:

## Commands

<!-- TODO: list the essential commands -->
- Run tests:
- Run linter:
- Run CI checks: `bin/ci`
- Regenerate agent adapters: `bin/sync-agent-config`
- Check adapter drift: `bin/sync-agent-config --check`

## Mandatory Workflow

<!-- TODO: adapt to the project's real workflow -->
- Read the matching file in `.agents/rules/` before editing a covered area.
- Add or update tests for every new feature, service, or significant change.
- Run the focused tests for the changed area before considering work complete.
- Do not call external services in specs/tests; stub external integrations.
- Comments, log messages, and commit messages must be in English.
- Do not hardcode secrets or log sensitive values.

## Rule Index

<!-- TODO: keep in sync with the rules created under .agents/rules/ -->

## Specialized Agents

<!-- TODO: describe the available subagents -->
"""

agents_md = os.path.join(ROOT, "AGENTS.md")
if not CHECK and not os.path.exists(agents_md):
    with open(agents_md, "w") as fh:
        fh.write(AGENTS_MD_TEMPLATE)
    print(
        "AGENTS.md was missing — created from the default template. "
        "Fill in the TODOs with the project's information."
    )


# ── CLAUDE.md ─────────────────────────────────────────────────────────────────

if "claude" in PLATFORMS:
    write_file(
        os.path.join(ROOT, "CLAUDE.md"),
        "@AGENTS.md\n\n"
        "## Claude Code\n\n"
        "- Tool-specific project rules are generated in `.claude/rules/` from `.agents/rules/`.\n"
        "- Project subagents are generated in `.claude/agents/` from `.agents/agents/`.\n"
        "- Project hooks are configured in `.claude/settings.json` and call scripts from `.agents/hooks/`.\n",
    )


# ── Hook permissions ──────────────────────────────────────────────────────────

if not CHECK:
    for f in sorted_glob("%s/*.sh" % hooks_dir):
        os.chmod(f, 0o755)


# ── Result ────────────────────────────────────────────────────────────────────

if CHECK:
    if not CHANGED:
        print("Agent configuration is in sync. [platforms: %s]" % ", ".join(PLATFORMS))
    else:
        print("Agent configuration is out of sync: [platforms: %s]" % ", ".join(PLATFORMS))
        for path in CHANGED:
            print("  %s" % path[len(ROOT) + 1:])
        sys.exit(1)
else:
    print("Agent configuration synchronized. [platforms: %s]" % ", ".join(PLATFORMS))
