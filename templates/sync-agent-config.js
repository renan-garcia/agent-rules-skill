#!/usr/bin/env node
/*
 * sync-agent-config (Node port)
 *
 * Generates platform adapters (.cursor/, .claude/, .codex/) from the canonical
 * source in .agents/.
 *
 * Usage:
 *   bin/sync-agent-config                          # all platforms
 *   bin/sync-agent-config --platforms cursor       # Cursor only
 *   bin/sync-agent-config --platforms cursor,claude
 *   bin/sync-agent-config --check                  # verify drift without writing
 *
 * Supported platforms: cursor, claude, codex, opencode
 *
 * Adapters whose canonical source was removed are pruned after a per-file
 * y/n/a/i/q confirmation (i persists the file in bin/sync-agent-config-options.json
 * and never asks again; EOF keeps files, so hooks/CI never delete silently);
 * --check lists them as drift instead.
 *
 * Alternative environment variable:
 *   AGENT_PLATFORMS=cursor,claude bin/sync-agent-config
 *
 * Optional project configuration file:
 *   .agents/config.json  ->  { "platforms": ["cursor", "claude", "codex", "opencode"] }
 *
 * This is a stdlib-only port of the reference Ruby implementation. It carries a
 * tiny hand-rolled parser/emitter for the flat frontmatter this skill uses, so
 * it needs no third-party YAML dependency.
 */

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const ARGV = process.argv.slice(2);
const CHECK = ARGV.includes("--check");
const CHANGED = [];

const ALL_PLATFORMS = ["cursor", "claude", "codex", "opencode"];

// ── Minimal YAML for flat frontmatter ────────────────────────────────────────

function coerceScalar(raw) {
  const text = raw.trim();
  if (text === "" || text === "~" || text === "null") return null;
  if (text === "true" || text === "True") return true;
  if (text === "false" || text === "False") return false;
  if (
    text.length >= 2 &&
    text[0] === text[text.length - 1] &&
    (text[0] === "'" || text[0] === '"')
  ) {
    return text.slice(1, -1);
  }
  if (/^-?\d+$/.test(text)) return parseInt(text, 10);
  return text;
}

// Parse the flat `key: value` (plus simple block lists) frontmatter the skill
// relies on. Not a general YAML parser — deliberately small.
function parseFrontmatter(text) {
  const data = {};
  const lines = text.split("\n");
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.trim() === "" || line.trimStart().startsWith("#")) {
      i += 1;
      continue;
    }
    const m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (!m) {
      i += 1;
      continue;
    }
    const key = m[1];
    const rest = m[2];
    if (rest.trim() === "") {
      const items = [];
      let j = i + 1;
      while (j < lines.length && /^\s*-\s+/.test(lines[j])) {
        items.push(coerceScalar(lines[j].replace(/^\s*-\s+/, "")));
        j += 1;
      }
      if (items.length) {
        data[key] = items;
        i = j;
        continue;
      }
      data[key] = null;
      i += 1;
      continue;
    }
    data[key] = coerceScalar(rest);
    i += 1;
  }
  return data;
}

function needsQuoting(value) {
  if (value === "") return true;
  if (value !== value.trim()) return true;
  if ("!&*?|>%@`#[]{},".includes(value[0])) return true;
  if (value.includes(": ") || value.endsWith(":")) return true;
  if (value.includes(" #")) return true;
  return false;
}

function emitScalar(value) {
  if (value === null || value === undefined) return "null";
  if (value === true) return "true";
  if (value === false) return "false";
  if (typeof value === "number") return String(value);
  const text = String(value);
  if (needsQuoting(text)) {
    return '"' + text.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
  }
  return text;
}

function emitYaml(data) {
  const out = [];
  for (const [key, value] of Object.entries(data)) {
    if (value !== null && typeof value === "object" && !Array.isArray(value)) {
      out.push(`${key}:`);
      for (const [subkey, subval] of Object.entries(value)) {
        out.push(`  ${subkey}: ${emitScalar(subval)}`);
      }
    } else if (Array.isArray(value)) {
      out.push(`${key}:`);
      for (const item of value) out.push(`- ${emitScalar(item)}`);
    } else {
      out.push(`${key}: ${emitScalar(value)}`);
    }
  }
  return out.join("\n");
}

// ── Platform resolution ──────────────────────────────────────────────────────

function valid(platforms) {
  return platforms.filter((p) => ALL_PLATFORMS.includes(p));
}

function fromConfig(file) {
  if (!fs.existsSync(file)) return null;
  let config;
  try {
    config = JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (e) {
    return null;
  }
  const platforms = config.platforms;
  if (platforms == null) return null;
  const list = Array.isArray(platforms) ? platforms : [platforms];
  return valid(list.map((p) => String(p).toLowerCase()));
}

function resolvePlatforms() {
  // 1. --platforms command-line flag
  const eq = ARGV.find((a) => a.startsWith("--platforms="));
  if (eq) {
    return valid(
      eq.slice("--platforms=".length).split(",").map((p) => p.trim().toLowerCase())
    );
  }
  const idx = ARGV.indexOf("--platforms");
  if (idx !== -1 && ARGV[idx + 1] && !ARGV[idx + 1].startsWith("--")) {
    return valid(ARGV[idx + 1].split(",").map((p) => p.trim().toLowerCase()));
  }

  // 2. Environment variable
  const env = process.env.AGENT_PLATFORMS;
  if (env) return valid(env.split(",").map((p) => p.trim().toLowerCase()));

  // 3. Project .agents/config.json file
  const project = fromConfig(path.join(ROOT, ".agents", "config.json"));
  if (project !== null) return project;

  // 4. Global installer config
  const home = process.env.HOME || require("os").homedir();
  const globalCfg = fromConfig(
    path.join(home, ".config", "agent-rules-skill", "config.json")
  );
  if (globalCfg !== null) return globalCfg;

  // 5. Default: all
  return ALL_PLATFORMS.slice();
}

const PLATFORMS = resolvePlatforms();

if (PLATFORMS.length === 0) {
  process.stderr.write(
    `No valid platform resolved (expected: ${ALL_PLATFORMS.join(", ")}).\n`
  );
  process.exit(1);
}

// ── Utilities ────────────────────────────────────────────────────────────────

function readFile(file) {
  return fs.readFileSync(file, "utf8");
}

function readMarkdown(file) {
  const content = readFile(file);
  const match = content.match(/^---\n([\s\S]*?)\n---\n/);
  if (!match) return [{}, content];
  const metadata = parseFrontmatter(match[1]) || {};
  return [metadata, content.slice(match[0].length)];
}

function metadataList(value) {
  let items;
  if (Array.isArray(value)) items = value.map((v) => String(v));
  else if (value == null) items = [];
  else items = String(value).split(",").map((v) => v.trim());
  return items.filter((v) => v !== "");
}

function compact(data) {
  const out = {};
  for (const [k, v] of Object.entries(data)) {
    if (v !== null && v !== undefined) out[k] = v;
  }
  return out;
}

function yamlFrontmatter(metadata) {
  return `---\n${emitYaml(metadata)}\n---\n\n`;
}

function writeFile(file, content, mode) {
  if (CHECK) {
    if (!(fs.existsSync(file) && readFile(file) === content)) CHANGED.push(file);
    return;
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  if (mode != null) fs.chmodSync(file, mode);
}

function jsonFile(data) {
  return JSON.stringify(data, null, 2) + "\n";
}

function tomlString(value) {
  return String(value == null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/"/g, '\\"');
}

function tomlMultiline(value) {
  return String(value == null ? "" : value)
    .trim()
    .split("'''")
    .join("'''\"'\"'''");
}

function adapterAppend(adapter, kind, basename) {
  const file = path.join(ROOT, ".agents", "adapters", adapter, kind, `${basename}.md`);
  if (!fs.existsSync(file)) return "";
  return `\n\n${readFile(file).trim()}\n`;
}

function withAdapterAppend(body, adapter, kind, basename) {
  const append = adapterAppend(adapter, kind, basename);
  if (append === "") return body;
  return body.replace(/\s+$/, "") + append;
}

function sortedGlob(dir, ext) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(ext))
    .sort()
    .map((f) => path.join(dir, f));
}

// String helpers matching Ruby lstrip/rstrip semantics.
function lstrip(s) {
  return s.replace(/^\s+/, "");
}

// ── Rules synchronization ────────────────────────────────────────────────────

const rulesDir = path.join(ROOT, ".agents", "rules");
const agentsDir = path.join(ROOT, ".agents", "agents");

for (const source of sortedGlob(rulesDir, ".md")) {
  const basename = path.basename(source, ".md");
  const [metadata, body] = readMarkdown(source);
  const globs = metadataList(metadata.globs);

  if (PLATFORMS.includes("cursor")) {
    const cursorMetadata = compact({ description: metadata.description });
    if (globs.length) cursorMetadata.globs = globs.join(",");
    cursorMetadata.alwaysApply = !!metadata.alwaysApply;

    writeFile(
      path.join(ROOT, ".cursor", "rules", `${basename}.mdc`),
      yamlFrontmatter(cursorMetadata) +
        withAdapterAppend(lstrip(body), "cursor", "rules", basename)
    );
  }

  if (PLATFORMS.includes("claude")) {
    const claudeMetadata = compact({ description: metadata.description });
    if (globs.length && !metadata.alwaysApply) claudeMetadata.paths = globs;

    writeFile(
      path.join(ROOT, ".claude", "rules", `${basename}.md`),
      yamlFrontmatter(claudeMetadata) +
        withAdapterAppend(lstrip(body), "claude", "rules", basename)
    );
  }

  if (PLATFORMS.includes("opencode")) {
    // opencode has no per-glob activation: rules are surfaced as plain
    // instruction files referenced from opencode.json (see below).
    writeFile(
      path.join(ROOT, ".opencode", "rules", `${basename}.md`),
      withAdapterAppend(lstrip(body), "opencode", "rules", basename)
    );
  }
}

// ── Agents synchronization ───────────────────────────────────────────────────

for (const source of sortedGlob(agentsDir, ".md")) {
  const basename = path.basename(source, ".md");
  const [metadata, body] = readMarkdown(source);
  const readonly = metadata.readonly === true;

  if (PLATFORMS.includes("cursor")) {
    const cursorContent =
      yamlFrontmatter({ ...metadata }) +
      withAdapterAppend(lstrip(body), "cursor", "agents", basename);
    writeFile(path.join(ROOT, ".cursor", "agents", `${basename}.md`), cursorContent);
  }

  if (PLATFORMS.includes("claude")) {
    const claudeMetadata = compact({
      name: metadata.name,
      description: metadata.description,
      model: readonly ? "sonnet" : "inherit",
    });
    if (readonly) {
      claudeMetadata.tools = "Read, Grep, Glob, Bash";
      claudeMetadata.disallowedTools = "Write, Edit, MultiEdit";
    }
    writeFile(
      path.join(ROOT, ".claude", "agents", `${basename}.md`),
      yamlFrontmatter(claudeMetadata) +
        withAdapterAppend(lstrip(body), "claude", "agents", basename)
    );
  }

  if (PLATFORMS.includes("codex")) {
    const codexBody = withAdapterAppend(lstrip(body), "codex", "agents", basename);
    const codexLines = [];
    codexLines.push(`name = "${tomlString(metadata.name)}"`);
    codexLines.push(`description = "${tomlString(metadata.description)}"`);
    if (readonly) codexLines.push('sandbox_mode = "read-only"');
    codexLines.push(`model_reasoning_effort = "${readonly ? "high" : "medium"}"`);
    codexLines.push("");
    codexLines.push("developer_instructions = '''");
    codexLines.push(tomlMultiline(codexBody));
    codexLines.push("'''");

    writeFile(
      path.join(ROOT, ".codex", "agents", `${basename}.toml`),
      codexLines.join("\n") + "\n"
    );
  }

  if (PLATFORMS.includes("opencode")) {
    const opencodeMetadata = compact({ description: metadata.description });
    opencodeMetadata.mode = "subagent";
    if (metadata.model) opencodeMetadata.model = metadata.model;
    if (readonly) opencodeMetadata.tools = { write: false, edit: false };

    writeFile(
      path.join(ROOT, ".opencode", "agents", `${basename}.md`),
      yamlFrontmatter(opencodeMetadata) +
        withAdapterAppend(lstrip(body), "opencode", "agents", basename)
    );
  }
}

// ── Hooks ────────────────────────────────────────────────────────────────────

const hooksDir = path.join(ROOT, ".agents", "hooks");
const hookScripts = sortedGlob(hooksDir, ".sh").filter(
  (f) => path.basename(f) !== "sync-on-edit.sh"
);
const hookCommand = hookScripts.length ? hookScripts[0] : null;
const syncHook = path.join(hooksDir, "sync-on-edit.sh");

const relativeSyncHook = fs.existsSync(syncHook)
  ? syncHook.slice(ROOT.length + 1)
  : null;
const relativeLinterHook = hookCommand ? hookCommand.slice(ROOT.length + 1) : null;

if (PLATFORMS.includes("cursor")) {
  const afterFileEdit = [];
  if (relativeSyncHook) afterFileEdit.push({ command: relativeSyncHook, timeout: 30 });
  if (relativeLinterHook) afterFileEdit.push({ command: relativeLinterHook, timeout: 60 });

  if (afterFileEdit.length) {
    writeFile(
      path.join(ROOT, ".cursor", "hooks.json"),
      jsonFile({ version: 1, hooks: { afterFileEdit } })
    );
  }
}

if (PLATFORMS.includes("claude") && (relativeSyncHook || relativeLinterHook)) {
  const claudeHooks = [];
  if (relativeSyncHook) {
    claudeHooks.push({
      matcher: "Write|Edit|MultiEdit",
      hooks: [
        {
          type: "command",
          command: `\${CLAUDE_PROJECT_DIR}/${relativeSyncHook}`,
          args: [],
          timeout: 30,
        },
      ],
    });
  }
  if (relativeLinterHook) {
    claudeHooks.push({
      matcher: "Write|Edit|MultiEdit",
      hooks: [
        {
          type: "command",
          command: `\${CLAUDE_PROJECT_DIR}/${relativeLinterHook}`,
          args: [],
          timeout: 60,
        },
      ],
    });
  }

  writeFile(
    path.join(ROOT, ".claude", "settings.json"),
    jsonFile({
      $schema: "https://json.schemastore.org/claude-code-settings.json",
      hooks: { PostToolUse: claudeHooks },
    })
  );
}

if (PLATFORMS.includes("codex") && (relativeSyncHook || relativeLinterHook)) {
  const codexHooks = [];
  if (relativeSyncHook) {
    codexHooks.push({
      matcher: "Edit|Write|apply_patch",
      hooks: [
        {
          type: "command",
          command: `"$(git rev-parse --show-toplevel)/${relativeSyncHook}"`,
          timeout: 30,
          statusMessage: "Syncing agent config",
        },
      ],
    });
  }
  if (relativeLinterHook) {
    codexHooks.push({
      matcher: "Edit|Write|apply_patch",
      hooks: [
        {
          type: "command",
          command: `"$(git rev-parse --show-toplevel)/${relativeLinterHook}"`,
          timeout: 60,
          statusMessage: "Running linter autocorrect",
        },
      ],
    });
  }

  writeFile(
    path.join(ROOT, ".codex", "hooks.json"),
    jsonFile({ hooks: { PostToolUse: codexHooks } })
  );
}

// ── Worktrees ────────────────────────────────────────────────────────────────

const worktreesSrc = path.join(ROOT, ".agents", "worktrees.json");
if (fs.existsSync(worktreesSrc) && PLATFORMS.includes("cursor")) {
  writeFile(path.join(ROOT, ".cursor", "worktrees.json"), readFile(worktreesSrc));
}

// ── opencode.json ────────────────────────────────────────────────────────────

if (PLATFORMS.includes("opencode") && sortedGlob(rulesDir, ".md").length) {
  const opencodeConfigPath = path.join(ROOT, "opencode.json");
  let opencodeConfig = {};
  if (fs.existsSync(opencodeConfigPath)) {
    try {
      opencodeConfig = JSON.parse(readFile(opencodeConfigPath));
    } catch (e) {
      opencodeConfig = {};
    }
  }
  if (opencodeConfig.$schema == null) {
    opencodeConfig.$schema = "https://opencode.ai/config.json";
  }

  const rulesGlob = ".opencode/rules/*.md";
  let instructions = opencodeConfig.instructions || [];
  if (!Array.isArray(instructions)) instructions = [instructions];
  if (!instructions.includes(rulesGlob)) instructions.push(rulesGlob);
  opencodeConfig.instructions = instructions;

  writeFile(opencodeConfigPath, jsonFile(opencodeConfig));
}

// ── AGENTS.md ────────────────────────────────────────────────────────────────

const AGENTS_MD_TEMPLATE = `# AGENTS.md

This is the portable project entrypoint for AI coding agents. Keep durable,
project-level behavior here and keep detailed, path-scoped rules in
\`.agents/rules/\`.

## Source Of Truth

- Edit canonical rules in \`.agents/rules/*.md\`.
- Edit canonical subagents in \`.agents/agents/*.md\`.
- Edit tool-specific overlays in \`.agents/adapters/<tool>/...\` when an
  instruction applies only to Cursor, Claude Code, or Codex.
- Edit shared hooks in \`.agents/hooks/*\`.
- Run \`bin/sync-agent-config\` after changing \`.agents/**\` to refresh adapters.
- Do not hand-edit generated adapters under \`.cursor/\`, \`.claude/\`, or \`.codex/\`.

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
- Run CI checks: \`bin/ci\`
- Regenerate agent adapters: \`bin/sync-agent-config\`
- Check adapter drift: \`bin/sync-agent-config --check\`

## Mandatory Workflow

<!-- TODO: adapt to the project's real workflow -->
- Read the matching file in \`.agents/rules/\` before editing a covered area.
- Add or update tests for every new feature, service, or significant change.
- Run the focused tests for the changed area before considering work complete.
- Do not call external services in specs/tests; stub external integrations.
- Comments, log messages, and commit messages must be in English.
- Do not hardcode secrets or log sensitive values.

## Rule Index

<!-- TODO: keep in sync with the rules created under .agents/rules/ -->

## Specialized Agents

<!-- TODO: describe the available subagents -->
`;

const agentsMd = path.join(ROOT, "AGENTS.md");
if (!CHECK && !fs.existsSync(agentsMd)) {
  fs.writeFileSync(agentsMd, AGENTS_MD_TEMPLATE);
  console.log(
    "AGENTS.md was missing — created from the default template. " +
      "Fill in the TODOs with the project's information."
  );
}

// ── CLAUDE.md ────────────────────────────────────────────────────────────────

if (PLATFORMS.includes("claude")) {
  writeFile(
    path.join(ROOT, "CLAUDE.md"),
    "@AGENTS.md\n\n" +
      "## Claude Code\n\n" +
      "- Tool-specific project rules are generated in `.claude/rules/` from `.agents/rules/`.\n" +
      "- Project subagents are generated in `.claude/agents/` from `.agents/agents/`.\n" +
      "- Project hooks are configured in `.claude/settings.json` and call scripts from `.agents/hooks/`.\n"
  );
}

// ── Hook permissions ─────────────────────────────────────────────────────────

if (!CHECK) {
  for (const f of sortedGlob(hooksDir, ".sh")) fs.chmodSync(f, 0o755);
}

// ── Stale adapter pruning ────────────────────────────────────────────────────
//
// Files inside the managed adapter directories whose canonical source no longer
// exists are offered for removal one by one: y = remove, n = keep, a = remove
// this and all remaining, i = ignore this file forever (persisted in
// bin/sync-agent-config-options.json), q = keep this and all remaining. On a
// TTY a single keypress answers (no Enter needed, case-insensitive); invalid
// keys re-prompt. EOF answers q, so non-interactive runs (hooks, CI) never
// delete anything. --check lists stale files as drift instead of prompting.

const OPTIONS_FILE = path.join(ROOT, "bin", "sync-agent-config-options.json");

// Namespaced by feature so future options can live alongside prune's.
function loadOptions() {
  if (!fs.existsSync(OPTIONS_FILE)) return {};
  try {
    return JSON.parse(readFile(OPTIONS_FILE));
  } catch (e) {
    return {};
  }
}

function saveOptions(options) {
  fs.mkdirSync(path.dirname(OPTIONS_FILE), { recursive: true });
  fs.writeFileSync(OPTIONS_FILE, jsonFile(options));
}

let stdinBuffer = "";
let stdinEof = false;

// Blocking line read from fd 0; returns null at EOF. Keeps leftover bytes so
// one read serving several prompts (piped stdin) is handled correctly.
function readStdinLine() {
  const chunk = Buffer.alloc(1024);
  while (true) {
    const nl = stdinBuffer.indexOf("\n");
    if (nl !== -1) {
      const line = stdinBuffer.slice(0, nl);
      stdinBuffer = stdinBuffer.slice(nl + 1);
      return line;
    }
    if (stdinEof) {
      if (stdinBuffer.length) {
        const line = stdinBuffer;
        stdinBuffer = "";
        return line;
      }
      return null;
    }
    let bytes = 0;
    try {
      bytes = fs.readSync(0, chunk, 0, chunk.length);
    } catch (e) {
      if (e.code === "EAGAIN") continue;
      stdinEof = true;
      continue;
    }
    if (bytes === 0) {
      stdinEof = true;
      continue;
    }
    stdinBuffer += chunk.toString("utf8", 0, bytes);
  }
}

// One answer from the user. On a TTY, reads a single raw keypress (echoed back
// with a newline so the transcript stays clean); otherwise reads a line, so
// piped stdin still works. EOF and Ctrl-C/Ctrl-D answer q (the safe default).
function readAnswer() {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
    const line = readStdinLine();
    return line === null ? "q" : line.trim().toLowerCase();
  }

  let char = null;
  try {
    process.stdin.setRawMode(true);
    const chunk = Buffer.alloc(8);
    const bytes = fs.readSync(0, chunk, 0, chunk.length);
    if (bytes > 0) char = chunk.toString("utf8", 0, bytes);
  } catch (e) {
    char = null;
  } finally {
    try {
      process.stdin.setRawMode(false);
    } catch (e) {
      // stdin already closed; nothing to restore
    }
  }
  if (char === null || char === "\u0003" || char === "\u0004") char = "q";
  const answer = char.trim().toLowerCase();
  process.stdout.write(`${/^[a-z]$/.test(answer) ? answer : ""}\n`);
  return answer;
}

const ruleNames = sortedGlob(rulesDir, ".md").map((f) => path.basename(f, ".md"));
const agentNames = sortedGlob(agentsDir, ".md").map((f) => path.basename(f, ".md"));

const managedDirs = [
  ["cursor", [".cursor", "rules"], ".mdc", ruleNames],
  ["cursor", [".cursor", "agents"], ".md", agentNames],
  ["claude", [".claude", "rules"], ".md", ruleNames],
  ["claude", [".claude", "agents"], ".md", agentNames],
  ["codex", [".codex", "agents"], ".toml", agentNames],
  ["opencode", [".opencode", "rules"], ".md", ruleNames],
  ["opencode", [".opencode", "agents"], ".md", agentNames],
];

const options = loadOptions();
const pruneOptions =
  options.prune && typeof options.prune === "object" && !Array.isArray(options.prune)
    ? options.prune
    : {};
const ignored = (Array.isArray(pruneOptions.ignored) ? pruneOptions.ignored : []).map(
  (p) => String(p)
);

const staleFiles = [];
for (const [platform, dir, ext, names] of managedDirs) {
  if (!PLATFORMS.includes(platform)) continue;
  for (const file of sortedGlob(path.join(ROOT, ...dir), ext)) {
    if (names.includes(path.basename(file, ext))) continue;
    if (ignored.includes(file.slice(ROOT.length + 1))) continue;
    staleFiles.push(file);
  }
}

if (!CHECK && staleFiles.length) {
  let removed = 0;
  let mode = "ask";

  for (const file of staleFiles) {
    const rel = file.slice(ROOT.length + 1);
    let answer;
    if (mode === "all") {
      answer = "y";
    } else if (mode === "quit") {
      answer = "n";
    } else {
      let response;
      while (true) {
        process.stdout.write(`Remove stale ${rel}? [y/n/a/i/q] `);
        response = readAnswer();
        if (["y", "n", "a", "i", "q"].includes(response)) break;
      }
      if (response === "a") mode = "all";
      if (response === "q") mode = "quit";
      answer = response === "a" ? "y" : response === "q" ? "n" : response;
    }

    if (answer === "i") {
      ignored.push(rel);
      pruneOptions.ignored = Array.from(new Set(ignored));
      options.prune = pruneOptions;
      saveOptions(options);
      console.log(`Ignored ${rel} — saved to bin/sync-agent-config-options.json.`);
      continue;
    }

    if (answer !== "y") continue;

    fs.unlinkSync(file);
    removed += 1;
    const dir = path.dirname(file);
    if (fs.existsSync(dir) && fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
  }

  if (removed > 0) console.log(`Removed ${removed} stale adapter file(s).`);
}

// ── Result ───────────────────────────────────────────────────────────────────

if (CHECK) {
  if (CHANGED.length === 0 && staleFiles.length === 0) {
    console.log(`Agent configuration is in sync. [platforms: ${PLATFORMS.join(", ")}]`);
  } else {
    console.log(
      `Agent configuration is out of sync: [platforms: ${PLATFORMS.join(", ")}]`
    );
    for (const p of CHANGED) console.log(`  ${p.slice(ROOT.length + 1)}`);
    for (const p of staleFiles) {
      console.log(`  ${p.slice(ROOT.length + 1)} (stale — no canonical source)`);
    }
    process.exit(1);
  }
} else {
  console.log(`Agent configuration synchronized. [platforms: ${PLATFORMS.join(", ")}]`);
}
