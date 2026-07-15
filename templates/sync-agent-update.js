#!/usr/bin/env node
/*
 * sync-agent-update (Node port)
 *
 * Updates this project's vendored agent executables straight from the
 * agent-rules-skill repository (or a local checkout):
 *   bin/sync-agent-config          (port matching its shebang)
 *   bin/sync-agent-update          (itself)
 *   .agents/hooks/sync-on-edit.sh  (only when the project has it)
 *
 * Nothing is applied without a y/n confirmation (single keypress on a TTY;
 * EOF answers n, so non-interactive runs never write silently). Downloads are
 * verified against the source's SHA256SUMS when it is published. State lives
 * under the "update" namespace of bin/sync-agent-config-options.json.
 *
 * Stdlib-only port of the Ruby reference; requires global fetch (Node 18+ or
 * Bun).
 */

"use strict";

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SELF_PATH = __filename;
const OPTIONS_FILE = path.join(ROOT, "bin", "sync-agent-config-options.json");
const DEFAULT_REPO = "renan-garcia/agent-rules-skill";
const ARGV = process.argv.slice(2);

const USAGE = `sync-agent-update — update this project's vendored agent executables

Updates bin/sync-agent-config, bin/sync-agent-update (itself) and
.agents/hooks/sync-on-edit.sh from the agent-rules-skill repository.

Usage:
  bin/sync-agent-update                    # list changes and confirm with y/n
  bin/sync-agent-update --check            # dry-run; exit 1 when updates exist
  bin/sync-agent-update --yes              # apply without prompting
  bin/sync-agent-update --ref <tag|branch> # pin the source ref
  bin/sync-agent-update --repo owner/name  # update from a fork
  bin/sync-agent-update --source <dir|url> # alternate source (offline/tests)

The ref resolves from --ref, then the ref saved in
bin/sync-agent-config-options.json, then the repo's latest GitHub release.
Downloads are verified against the source's SHA256SUMS when published.
`;

const CHECK = ARGV.includes("--check");
const YES = ARGV.includes("--yes");

if (ARGV.includes("-h") || ARGV.includes("--help")) {
  process.stdout.write(USAGE);
  process.exit(0);
}

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function flagValue(name) {
  const eq = ARGV.find((a) => a.startsWith(`${name}=`));
  if (eq) return eq.slice(name.length + 1);
  const idx = ARGV.indexOf(name);
  if (idx !== -1 && ARGV[idx + 1] && !ARGV[idx + 1].startsWith("--")) {
    return ARGV[idx + 1];
  }
  return null;
}

// ── Options file (shared with bin/sync-agent-config) ────────────────────────

function jsonFile(data) {
  return JSON.stringify(data, null, 2) + "\n";
}

function loadOptions() {
  if (!fs.existsSync(OPTIONS_FILE)) return {};
  try {
    return JSON.parse(fs.readFileSync(OPTIONS_FILE, "utf8"));
  } catch (e) {
    return {};
  }
}

function saveOptions(options) {
  fs.mkdirSync(path.dirname(OPTIONS_FILE), { recursive: true });
  fs.writeFileSync(OPTIONS_FILE, jsonFile(options));
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

async function httpGet(url) {
  if (typeof fetch !== "function") {
    die("global fetch is required (Node 18+ or Bun).");
  }
  let res;
  try {
    res = await fetch(url, {
      redirect: "follow",
      headers: { "User-Agent": "sync-agent-update" },
    });
  } catch (e) {
    die(`Network error fetching ${url}: ${e.message}`);
  }
  if (res.status === 404) return null;
  if (!res.ok) die(`HTTP ${res.status} fetching ${url}`);
  return await res.text();
}

// ── Interaction ──────────────────────────────────────────────────────────────

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
// piped stdin still works. EOF and Ctrl-C/Ctrl-D answer n (the safe default).
function readAnswer() {
  if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== "function") {
    const line = readStdinLine();
    return line === null ? "n" : line.trim().toLowerCase();
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
  if (char === null || char === "\u0003" || char === "\u0004") char = "n";
  const answer = char.trim().toLowerCase();
  process.stdout.write(`${/^[a-z]$/.test(answer) ? answer : ""}\n`);
  return answer;
}

// The shebang of each installed executable selects the port to fetch; bun runs
// the Node port with the shebang rewritten after download.
function templateFor(file) {
  const shebang = fs.readFileSync(file, "utf8").split("\n", 1)[0] || "";
  const name = path.basename(file);
  if (shebang.includes("bun")) return [`templates/${name}.js`, "bun"];
  if (shebang.includes("node")) return [`templates/${name}.js`, null];
  if (shebang.includes("python")) return [`templates/${name}.py`, null];
  return [`templates/${name}`, null];
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const options = loadOptions();
  const updateOpts =
    options.update && typeof options.update === "object" && !Array.isArray(options.update)
      ? options.update
      : {};

  const source = flagValue("--source");
  const repo = flagValue("--repo") || updateOpts.repo || DEFAULT_REPO;
  let ref = flagValue("--ref") || updateOpts.ref || null;

  let fetchPath;
  let sourceLabel;
  if (source) {
    if (/^https?:\/\//.test(source)) {
      const base = source.replace(/\/$/, "");
      fetchPath = (p) => httpGet(`${base}/${p}`);
      sourceLabel = base;
    } else {
      const dir = path.resolve(source);
      if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) {
        die(`Invalid --source directory: ${source}`);
      }
      fetchPath = async (p) => {
        const f = path.join(dir, p);
        return fs.existsSync(f) ? fs.readFileSync(f, "utf8") : null;
      };
      sourceLabel = `${dir} (local)`;
    }
  } else {
    if (ref === null) {
      const body = await httpGet(`https://api.github.com/repos/${repo}/releases/latest`);
      if (body) {
        try {
          ref = JSON.parse(body).tag_name || null;
        } catch (e) {
          ref = null;
        }
      }
      if (!ref) {
        die(`No release found for ${repo}. Pass --ref <tag-or-branch> (e.g. --ref main).`);
      }
    }
    const base = `https://raw.githubusercontent.com/${repo}/${ref}`;
    fetchPath = (p) => httpGet(`${base}/${p}`);
    sourceLabel = `${repo}@${ref}`;
  }

  const syncTarget = path.join(ROOT, "bin", "sync-agent-config");
  if (!fs.existsSync(syncTarget)) {
    die("No bin/sync-agent-config found — this project does not look bootstrapped.");
  }

  const targets = [syncTarget, SELF_PATH];
  const hook = path.join(ROOT, ".agents", "hooks", "sync-on-edit.sh");
  if (fs.existsSync(hook)) targets.push(hook);

  const sumsRaw = await fetchPath("SHA256SUMS");
  const sums = {};
  if (sumsRaw) {
    for (const line of sumsRaw.split("\n")) {
      const m = line.trim().match(/^([0-9a-fA-F]{64})\s+\*?(.+)$/);
      if (m) sums[m[2]] = m[1].toLowerCase();
    }
  } else {
    process.stderr.write(
      `⚠️  SHA256SUMS not found at ${sourceLabel} — skipping integrity verification.\n`
    );
  }
  const hasSums = Object.keys(sums).length > 0;

  console.log(`Update source: ${sourceLabel}`);

  const changes = [];
  for (const file of targets) {
    const rel = file.slice(ROOT.length + 1);
    const [templatePath, transform] =
      path.basename(file) === "sync-on-edit.sh"
        ? ["templates/sync-on-edit.sh", null]
        : templateFor(file);

    let content = await fetchPath(templatePath);
    if (content === null) {
      die(`Missing ${templatePath} at ${sourceLabel} — aborting.`);
    }

    if (hasSums) {
      if (sums[templatePath]) {
        const digest = crypto.createHash("sha256").update(content).digest("hex");
        if (digest !== sums[templatePath]) {
          die(`Checksum mismatch for ${templatePath} — aborting.`);
        }
      } else {
        process.stderr.write(`⚠️  No checksum for ${templatePath} in SHA256SUMS.\n`);
      }
    }

    if (transform === "bun") content = content.replace("env node", "env bun");

    if (fs.readFileSync(file, "utf8") === content) {
      console.log(`  ${rel} — up to date`);
    } else {
      console.log(`  ${rel} — update available`);
      changes.push([file, rel, content]);
    }
  }

  if (changes.length === 0) {
    console.log(`Everything is up to date. [${sourceLabel}]`);
    return;
  }

  if (CHECK) {
    console.log(`${changes.length} update(s) available. Run bin/sync-agent-update to apply.`);
    process.exit(1);
  }

  if (!YES) {
    let answer;
    while (true) {
      process.stdout.write(`Apply ${changes.length} update(s)? [y/n] `);
      answer = readAnswer();
      if (["y", "n"].includes(answer)) break;
    }
    if (answer === "n") {
      console.log("No changes applied.");
      return;
    }
  }

  for (const [file, rel, content] of changes) {
    fs.writeFileSync(file, content);
    fs.chmodSync(file, 0o755);
    console.log(`✅ Updated ${rel}`);
  }

  updateOpts.updated_at = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
  if (!source) {
    updateOpts.repo = repo;
    updateOpts.ref = ref;
  }
  options.update = updateOpts;
  saveOptions(options);

  console.log(`Update complete. [${sourceLabel}]`);
}

main();
